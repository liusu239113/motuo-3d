-- 完整生产帧采样：只允许已注入内存存档的显式测试会话。
-- 不冻结交通/街坊/配送人，不省略相机/存档推进/地图刷新，不将CPU当作手机GPU帧率。
local Probe={}
---@param session CareerSession
function Probe.Install(session)
    assert(session.options.test and session.restoreTestStorage,"整帧采样必须隔离真实存档")
    local Store=require("Career.Store")
    assert(Store.Transaction(function(p)
        p.phase="working";p.flags.introSeen=true;p.time=9;p.activeOrders={}
        return true
    end))
    session.view:ClosePhone();session.view:ShowGame();session.view:ResetInput()
    session.actor.mounted=true;session.actor.visuals:SetMounted(true)
    local cross,legacy30,plain,terrace=false,false,false,false
    local turning,oldCity,jitter,measureUI=false,false,false,false
    local gcMode=""
    for _,arg in ipairs(GetArguments()) do
        if arg=="-careerframecross" then cross=true end
        if arg=="-careerframe30" then legacy30=true end
        if arg=="-careerframeplain" then plain=true end
        if arg=="-careerframeterrace" then terrace=true end
        if arg=="-careerframeturn" then turning=true end
        if arg=="-careerframeoldcity" then oldCity=true end
        if arg=="-careerframejitter" then jitter=true end
        if arg=="-careerframeui" then measureUI=true end
        local mode=arg:match("^%-careerframegc=(.+)$")
        if mode then
            assert(mode=="incremental" or mode=="generational","未知测试GC模式")
            gcMode=mode
        end
    end
    -- Explicit isolated-test switch only; normal runs never change GC mode.
    -- Lua exposes the previous mode, not its old tuning values. Restore mode
    -- with its runtime defaults after sampling, and state that limitation.
    local gcPrevious=""
    local gcStart,gcMaximum=0,0
    local function gcCount()
        local ok,value=pcall(collectgarbage,"count")
        if ok and type(value)=="number" then return value end
        return 0
    end
    local function gcSample()
        if gcMode~="" then gcMaximum=math.max(gcMaximum,gcCount()) end
    end
    local function gcRestore()
        if gcPrevious=="incremental" or gcPrevious=="generational" then
            local previous=gcPrevious
            gcPrevious=""
            local ok,result=pcall(collectgarbage,previous)
            print(string.format("[测试GC恢复] mode=%s accepted=%s return=%s；只恢复模式，API不提供原调优参数",previous,tostring(ok),tostring(result)))
        end
    end
    local function gcBegin()
        if gcMode=="" then return end
        gcStart=gcCount();gcMaximum=gcStart
        local runningOk,running=pcall(collectgarbage,"isrunning")
        local ok,previous
        if gcMode=="incremental" then ok,previous=pcall(collectgarbage,"incremental",150,100,8)
        else ok,previous=pcall(collectgarbage,"generational",20,100) end
        if ok and type(previous)=="string" then gcPrevious=previous end
        print(string.format("[测试GC开始] Lua=%s mode=%s accepted=%s return=%s start=%.3fKiB isrunning=%s/%s；仅隔离采样，非生产GC设置",
            tostring(_VERSION),gcMode,tostring(ok),tostring(previous),gcStart,tostring(runningOk),tostring(running)))
    end
    local function gcReport()
        if gcMode=="" then return end
        local ending=gcCount()
        gcMaximum=math.max(gcMaximum,ending)
        local ok,running=pcall(collectgarbage,"isrunning")
        print(string.format("[测试GC内存] mode=%s start=%.3fKiB end=%.3fKiB frameMax=%.3fKiB isrunning=%s/%s；每帧Update/PostUpdate后采样，非分配峰值或GPU内存",
            gcMode,gcStart,ending,gcMaximum,tostring(ok),tostring(running)))
        gcRestore()
    end
    local hz=legacy30 and 30 or 60
    local targetFrames=(cross and 30 or 6)*hz
    local x,z=cross and 3 or 240,cross and 430 or -35
    if terrace then x,z=304,610 end
    if oldCity then x,z=3,-45 end
    session.actor:Teleport(x,z,0)
    session.city.stream:Ensure(x,z,550)
    local startLoaded=session.city.stream.loaded
    session.yaw,session.pitch=0,14
    local inputFrame,turnFrames,turnCalls=0,0,0
    local frameDt=1/hz
    local costs={}
    ---@type fun()[]
    local restores={}
    local cleaned=false
    local function replace(owner,key,replacement)
        local previous=rawget(owner,key)
        owner[key]=replacement
        restores[#restores+1]=function()
            if rawget(owner,key)==replacement then rawset(owner,key,previous) end
        end
    end
    local function cleanup()
        if cleaned then return end
        cleaned=true
        for i=#restores,1,-1 do restores[i]() end
        gcRestore()
    end
    replace(session.view,"GetInput",function()
        -- 连续左右输入，不用每帧传送重置；因此测量包含正常碰撞、交通和相机跟随。
        local steer=turning and math.sin(inputFrame*frameDt*2.1)*.8 or 0
        if math.abs(steer)>.05 then turnFrames=turnFrames+1 end
        return {throttle=turning and .62 or 1,steer=steer,brake=false,walkX=0,walkY=0}
    end)
    local turnTo=session.actor.TurnTo
    replace(session.actor,"TurnTo",function(self,...)
        turnCalls=turnCalls+1
        return turnTo(self,...)
    end)
    local disposeWorld=session.DisposeWorld
    replace(session,"DisposeWorld",function(self,...)
        cleanup()
        return disposeWorld(self,...)
    end)
    local function timed(owner,key,label)
        if plain then return end
        local original=owner[key]
        replace(owner,key,function(...)
            local began=os.clock()
            local values=table.pack(pcall(original,...))
            local ms=(os.clock()-began)*1000
            if not values[1] then cleanup();error(values[2],0) end
            local c=costs[label] or {total=0,max=0,n=0}
            c.total,c.max,c.n=c.total+ms,math.max(c.max,ms),c.n+1
            costs[label]=c
            return table.unpack(values,2,values.n)
        end)
    end
    timed(session.city.stream,"Update","流式更新")
    timed(session.city.contacts,"Update","熟人街景")
    timed(session.deliveryPeople,"Update","配送人物")
    timed(session.deliveryMarkers,"Update","配送标记")
    timed(session.actor,"Update","玩家移动接地骑姿")
    timed(session.actor,"Move","玩家连续碰撞")
    timed(session.actor,"TurnTo","玩家连续转向")
    timed(require("Career.FootprintCollision"),"Hull","转向与其他凸包构造")
    timed(session.actor,"SyncVisuals","玩家显示同步")
    timed(require("Career.VehicleContact"),"Solve","全部车辆轮胎求解")
    if not plain then
        local contact=require("Career.VehicleContact")
        local solve=contact.Solve
        replace(contact,"Solve",function(city,id,...)
            local began=os.clock()
            local values=table.pack(pcall(solve,city,id,...))
            local ms=(os.clock()-began)*1000
            if not values[1] then cleanup();error(values[2],0) end
            local label="轮胎车型:"..id
            local c=costs[label] or {total=0,max=0,n=0}
            c.total,c.max,c.n=c.total+ms,math.max(c.max,ms),c.n+1
            costs[label]=c
            return table.unpack(values,2,values.n)
        end)
    end
    timed(require("Career.FootprintCollision"),"Pose","全部车壳坐标变换")
    timed(session.traffic.outer,"Step","外区车辆推进")
    timed(session.traffic.outer,"Walk","外区行人推进")
    timed(session.traffic.outer,"Fill","外区补充候选")
    timed(session.crowd,"Update","环境街坊")
    timed(session.crowd,"Snapshot","人群碰撞快照")
    timed(session.crowd,"SegmentFree","人群连续通行")
    timed(session.crowd,"Move","人群移动")
    timed(session.crowd,"Pose","人群骨骼插值")
    timed(session.traffic,"Update","完整交通")
    timed(session.view,"LayoutControls","触控布局")
    timed(session,"Refresh","HUD地图与业务刷新")
    timed(session,"SavePosition","位置快照")
    timed(session,"PostUpdate","生产相机与夜灯")
    timed(session.camera,"Update","第三人称相机")
    local frames,total,maxFrame=0,0,0
    local samples,combined={},{}
    local reported=false
    local lastMs=0
    local uiUpdateSamples,uiRenderSamples={},{}
    if measureUI then
        local UI=require("urhox-libs/UI")
        local function uiTimed(key,values)
            local originalUI=UI[key]
            replace(UI,key,function(...)
                local include=frames>0 and not reported and not cleaned
                local began=os.clock()
                local result=table.pack(pcall(originalUI,...))
                local ms=(os.clock()-began)*1000
                if not result[1] then cleanup();error(result[2],0) end
                if include then values[#values+1]=ms end
                return table.unpack(result,2,result.n)
            end)
        end
        uiTimed("Update",uiUpdateSamples)
        uiTimed("Render",uiRenderSamples)
    end
    local function distribution(label,values)
        if #values==0 then
            print("[生产CPU分布] "..label.." n=0；该窗口未收到回调，不能作为零开销证据")
            return
        end
        table.sort(values)
        local over16,over33,over50=0,0,0
        for _,ms in ipairs(values) do
            if ms>1000/60 then over16=over16+1 end
            if ms>1000/30 then over33=over33+1 end
            if ms>50 then over50=over50+1 end
        end
        local function percentile(q) return values[math.max(1,math.ceil(#values*q))] end
        print(string.format("[生产CPU分布] %s n=%d p50=%.3f p95=%.3f p99=%.3f max=%.3fms；>16.67ms=%d(%.2f%%) >33.33ms=%d(%.2f%%) >50ms=%d(%.2f%%)",
            label,#values,percentile(.5),percentile(.95),percentile(.99),values[#values],
            over16,over16/#values*100,over33,over33/#values*100,over50,over50/#values*100))
    end
    local function report(self)
        print(string.format("[生产整帧CPU] %dHz/%d帧 Update平均%.3fms 峰值%.3fms；骑行位置%.2f,%.2f；渲染%d批/%d图元；非手机FPS",
            hz,frames,total/frames,maxFrame,self.actor.x,self.actor.z,renderer.numBatches,renderer.numPrimitives))
        distribution("Update",samples)
        distribution("Update+PostUpdate",combined)
        if measureUI then
            distribution("UI.Update自动事件",uiUpdateSamples)
            distribution("UI.Render自动事件",uiRenderSamples)
            print("[UI采样边界] 首个生产Update开始后至末次PostUpdate后的下一Update前，分别统计自动回调；不假定UI与Session订阅顺序，不将CPU相加当呈现帧/GPU耗时")
        end
        if turning then
            assert(turnFrames>targetFrames*.7 and turnCalls>targetFrames,"转向采样未进入真实转向路径")
            print(string.format("[真实转向采样] 非零方向%d帧 / TurnTo %d次 / 长帧输入=%s；不以直行代替转向",turnFrames,turnCalls,tostring(jitter)))
        end
        if cross and not turning and not oldCity then
            local distance=math.sqrt((self.actor.x-x)^2+(self.actor.z-z)^2)
            print(string.format("[跨块生产采样] 行驶%.2fm / 新完成%d块 / 未完成job=%s",distance,self.city.stream.loaded-startLoaded,tostring(self.city.stream.job~=nil)))
            assert(distance>128 and self.city.stream.loaded>startLoaded,"跨块采样未实际行驶或未触发新建块，不能作为加载性能证据")
        end
        local labels={}
        for label in pairs(costs) do labels[#labels+1]=label end
        table.sort(labels)
        for _,label in ipairs(labels) do
            local c=costs[label]
            print(string.format("[生产整帧分项] %s 总%.3fms / 摊每帧%.3fms / 单次峰值%.3fms / %d次",
                label,c.total,c.total/frames,c.max,c.n))
        end
        print("[生产整帧采样完成] 业务内存档隔离；嵌套分项不可相加；含相机CPU但不含引擎其余工作/GPU，不能证明手机60帧")
        gcReport()
    end
    local original=session.Update
    replace(session,"Update",function(self,_dt)
        if not self.restoreTestStorage then cleanup();error("采样丢失内存存档隔离") end
        if reported then return end
        -- 等末次PostUpdate之后的NanoVGRender完成；不在PostUpdate里截断UI窗口。
        if frames==targetFrames then
            if #combined~=targetFrames then cleanup();error("生产Update/PostUpdate配对不完整") end
            reported=true
            local ok,err=pcall(report,self)
            cleanup()
            assert(ok,tostring(err))
            return
        end
        inputFrame=inputFrame+1
        frameDt=jitter and ({.016,.017,.0334,.016,.016,.1})[(inputFrame-1)%6+1] or 1/hz
        self.options.test=false
        local began=os.clock()
        local ok,err=pcall(original,self,frameDt)
        local ms=(os.clock()-began)*1000
        self.options.test=true
        if not ok then cleanup();error(err,0) end
        if not cleaned then
            frames,total,maxFrame=frames+1,total+ms,math.max(maxFrame,ms)
            samples[#samples+1]=ms
            lastMs=ms
            gcSample()
        end
    end)
    local postUpdate=session.PostUpdate
    replace(session,"PostUpdate",function(self,_dt)
        local began=os.clock()
        local ok,err=pcall(postUpdate,self,frameDt)
        local ms=(os.clock()-began)*1000
        if not ok then cleanup();error(err,0) end
        if not reported and not cleaned and #combined<frames then
            combined[#combined+1]=lastMs+ms
            gcSample()
        end
    end)
    session:Refresh()
    gcBegin()
    print(string.format("[采样路径] %s / %s / %s",oldCity and "老街活动交通" or terrace and "坡地住宅纵街" or "原城区跨块",turning and "连续左右转向" or "直行",plain and "低干扰总帧：不安装分项wrapper" or "分项计时"))
    print(string.format("[生产整帧采样就绪] 真实Session.Update/全部人车/相机/地图/存档推进；固定1/%ds输入；%d秒，不含GPU",hz,targetFrames/hz))
end
return Probe
