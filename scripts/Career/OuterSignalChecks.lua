-- 显式调用require("Career.OuterSignalChecks").Run(session)；不自动运行、不构建。
-- 必须Session.New({test=true})；独立city/actor/owner/Outer池夹具，finally释放。
local Signals=require("Career.OuterSignals")
local Outer=require("Career.OuterTraffic")
local Traffic=require("Career.Traffic")
local World=require("Career.WorldData")
local Store=require("Career.Store")
local Config=require("Career.Config")
local Checks={}
local function near(a,b,message)
    assert(math.abs(a-b)<.0001,message..string.format(" (%.6f / %.6f)",a,b))
end
local function same(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~="table" then return a==b end
    for k,v in pairs(a) do if not same(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
local function phaseTime(j,axis,phase)
    return (phase-j.offset-(axis=="ew" and Signals.HALF_CYCLE or 0))%Signals.CYCLE
end
local function routeAt(j,axis)
    local cross=axis=="ns" and j.z or j.x
    local width=axis=="ns" and j.nsWidth or j.ewWidth
    return {axis=axis,road=axis=="ns" and j.x or j.z,start=cross-110,finish=cross+110,
        radius=width/4,width=width,sidewalk=4,id="signal_check"}
end
---@param outer table
---@param route table
---@param length number
---@param sign number
---@param gap number
---@param j OuterSignalJunction
---@return OuterTrafficCar
local function carAt(outer,route,length,sign,gap,j)
    local cross=route.axis=="ns" and j.z or j.x
    local along=cross-sign*(Signals.StopOffset(j,route.axis)+length/2+gap)
    local straight=route.finish-route.start
    local s=sign==1 and along-route.start or straight+math.pi*route.radius+route.finish-along
    local x,z,yaw=Outer.Pose(route,s)
    ---@type OuterTrafficCar
    local car={id="signal_fixture",node=outer.root:CreateChild("停止线验收车"),length=length,width=1.85,
        route=route,s=s,x=x,z=z,yaw=yaw,speed=0,cruise=6,inUse=true,travelled=0}
    outer.carPool[#outer.carPool+1]=car
    return car
end
local function moveTo(car,j,sign,gap)
    local route=car.route
    local cross=route.axis=="ns" and j.z or j.x
    local along=cross-sign*(Signals.StopOffset(j,route.axis)+car.length/2+gap)
    local straight=route.finish-route.start
    car.s=sign==1 and along-route.start or straight+math.pi*route.radius+route.finish-along
    car.x,car.z,car.yaw=Outer.Pose(route,car.s)
    car.speed=0
end
local function advance(outer,seconds)
    for _=1,math.floor(seconds*100+.5) do outer:Step(.01,{}) end
end
-- 区域验收（米、俯视）：
--   车尾 [ OBB半长L/2 -- 车心 -- L/2 ]车头 | .20 | 白线上游边 .15 | 白线中心
--   红/黄/双全红：所有四个来向、4.8m与10m车，车头不越线且真正停稳。
--   绿：无冲突起步；异向已入场/长车尾部未清空让停，已越线车不因变红急停。
--   四角底座.4m外包与全部共享道路+完整步道不相交，不创建墙/空气碰撞。
--   每次只测独立夹具；不调用session:ApplySpace/Teleport、真实交通Fill或玩家存档。
---@param session CareerSession
function Checks.Run(session)
    assert(session.options.test==true and type(session.restoreTestStorage)=="function",
        "OuterSignalChecks requires Session.New({test=true}) memory storage")
    local sourceCity=assert(session.city)
    local sourceTraffic=assert(session.traffic)
    assert(not sourceTraffic.disposed,"session traffic disposed")
    local store=Store.Get()
    local profile=cjson.decode(cjson.encode(store))
    local oldTime=sourceTraffic.time
    local oldPhase=sourceCity.signals.phase
    local realOuter=assert(sourceTraffic.outer)
    local realTime,realSignalTime=realOuter.time,realOuter.signals.time
    local realVisuals=realOuter.signals.visuals
    local originalChildren=sourceCity.root:GetNumChildren(true)
    local originalDetails={meshes=sourceCity.details.meshCount,boxes=sourceCity.details.boxes,
        surfaces=#sourceCity.details.surfaces,obstacles=#sourceCity.obstacles}
    local holder=sourceCity.root:CreateChild("OuterSignalChecks_独立夹具")
    -- 只借用只读City查询/材质；自有root/space，无真实city.details写入。
    local city=setmetatable({root=holder,space="city",mats=sourceCity.mats,signals=sourceCity.signals},{__index=sourceCity})
    local actor={x=768,z=-40}
    local owner={city=city,actor=actor,cars={},pedestrians={people={}},active=true,nearOld=false,
        Separate=Traffic.Separate,CircleFree=Traffic.CircleFree}
    ---@type table?
    local fixture=nil
    local files={[Config.SAVE_PATH]=cjson.encode(profile)}
    local writes=0
    local started=os.clock()
    local ok,message=pcall(function()
        Store.WithTestStorage({read=function(path) return files[path],nil,files[path]==nil end,
            write=function(path,text) writes=writes+1; files[path]=text; return true end,
            cloud={Get=function() error("signal checks cloud access forbidden") end,
                Set=function() error("signal checks cloud access forbidden") end}},function()
            assert(Store.Load(),"cannot load isolated signal memory profile")
            fixture=Outer.New(owner)
            local outer=assert(fixture) --[[@as CareerOuterTraffic]]
            local signals=outer.signals
            assert(Outer.CAR_BUDGET==6 and Outer.PEOPLE_BUDGET==4,"outer budget changed")
            assert(#sourceTraffic.cars==15 and #sourceTraffic.pedestrians.people==8,"old budgets changed")
            assert(#Signals.Junctions==12,"only the twelve district centres are signalized")
            for _,j in ipairs(Signals.Junctions) do
                assert(Signals.Find(j.x,j.z)==j and not World.IsOld(j.x,j.z),"junction lookup/old protection")
                for i=0,839 do
                    local t=i*.05-j.offset
                    local ns,ew=Signals.Signal(t,"ns",j),Signals.Signal(t,"ew",j)
                    assert(not(ns~="red" and ew~="red"),"NS/EW green or yellow overlap")
                    assert(Signals.Signal(t+42,"ns",j)==ns and Signals.Signal(t+42,"ew",j)==ew,"cycle not deterministic")
                end
                for _,axis in ipairs({"ns","ew"}) do
                    assert(Signals.Signal(phaseTime(j,axis,0),axis,j)=="green","green boundary")
                    assert(Signals.Signal(phaseTime(j,axis,16),axis,j)=="yellow","yellow boundary")
                    assert(Signals.Signal(phaseTime(j,axis,19),"ns",j)=="red"
                        and Signals.Signal(phaseTime(j,axis,19),"ew",j)=="red","all-red boundary")
                    local expected=(axis=="ns" and j.ewWidth or j.nsWidth)/2+5.6+.15+.20
                    near(Signals.StopOffset(j,axis),expected,"WorldStream painted stop line mismatch")
                end
                for arm=1,4 do
                    local x,z=Signals.PolePose(j,arm)
                    for _,r in ipairs(World.Roads) do
                        local half=r.width/2+(r.sidewalk or 4)
                        local x1,x2=math.min(r.x1,r.x2),math.max(r.x1,r.x2)
                        local z1,z2=math.min(r.z1,r.z2),math.max(r.z1,r.z2)
                        if r.x1==r.x2 then x1,x2=x1-half,x2+half else z1,z2=z1-half,z2+half end
                        assert(not(x+.24>x1 and x-.24<x2 and z+.24>z1 and z-.24<z2),"pole/base intrudes road or walking corridor")
                    end
                    assert(World.IsFree(x,z,.25,"walk",0),"pole overlaps static building/bridge/prop")
                end
            end
            local j=assert(Signals.Find(768,0))
            for _,axis in ipairs({"ns","ew"}) do
                local route=routeAt(j,axis)
                for _,sign in ipairs({1,-1}) do
                    for _,length in ipairs({4.8,10}) do
                        local car=carAt(outer,route,length,sign,18,j)
                        outer.cars={car}
                        assert(Outer.StaticFree(city,car),"fixture must be on a real unobstructed road")
                        outer.time=phaseTime(j,axis,21); signals:SetTime(outer.time)
                        car.speed=6; advance(outer,6)
                        local gap=assert(Signals.Approach(j,route,car.s,length))
                        assert(gap>=-.0001 and gap<.05 and car.speed<.02,"red must stop actual bumper before white line")
                        local waiting=car.travelled
                        outer.time=phaseTime(j,axis,0); signals:SetTime(outer.time)
                        advance(outer,2)
                        assert(car.travelled>waiting+2,"green must accelerate from rest")
                        for _,phase in ipairs({16.05,19.05,40.05}) do
                            moveTo(car,j,sign,1.5); car.speed=3
                            outer.time=phaseTime(j,axis,phase); signals:SetTime(outer.time)
                            advance(outer,1.6)
                            local stopped=assert(Signals.Approach(j,route,car.s,length))
                            assert(stopped>=-.0001 and stopped<.05 and car.speed<.02,"yellow/all-red bumper stop failed")
                        end
                        -- 贴线与余量内不能误判成已入；真正越过线上游边缘允许清空。
                        moveTo(car,j,sign,-.10)
                        outer.time=phaseTime(j,axis,21); signals:SetTime(outer.time)
                        near(signals:StopGap(route,car.s,length),0,"margin region must still wait")
                        moveTo(car,j,sign,-.50); car.speed=3
                        assert(signals:StopGap(route,car.s,length)==math.huge,"already-entered car stopped in junction")
                        local entered=car.travelled
                        advance(outer,.4)
                        assert(car.travelled>entered+.5,"entered car failed to clear on red")
                        -- 掉头弧不应当被错误直线投影到路口停止线。
                        assert(Signals.Approach(j,route,route.finish-route.start+.5,length)==nil,"U-turn treated as straight approach")
                        car.node:Dispose(); table.remove(outer.carPool)
                    end
                end
            end
            local ns,ew=routeAt(j,"ns"),routeAt(j,"ew")
            local waiting=carAt(outer,ns,4.8,1,0,j)
            local clearing=carAt(outer,ew,10,1,-1,j)
            outer.cars={waiting,clearing}
            outer.time=phaseTime(j,"ns",0); signals:SetTime(outer.time)
            near(signals:Gap(waiting,outer.cars),0,"green must yield to committed cross traffic")
            moveTo(clearing,j,1,-(Signals.StopOffset(j,"ew")+clearing.length/2+1))
            assert(signals:Gap(waiting,outer.cars)==0,"long tail still occupies conflict box")
            moveTo(clearing,j,1,-(Signals.StopOffset(j,"ew")+clearing.length+30))
            assert(signals:Gap(waiting,outer.cars)==math.huge,"cleared tail keeps intersection locked")
            local hint=signals:Hint(j.x+3,j.z-30,0)
            assert(hint and hint:find("绿灯"),"hint does not match current light")
            -- 无灯交点不受到中心信号控制，保留Outer.Gap原来的EW优先规则。
            local unlit={x=j.x+192,z=j.z+192,nsWidth=12,ewWidth=12,nsSidewalk=4,ewSidewalk=4,offset=0}
            assert(not Signals.Find(unlit.x,unlit.z),"non-central junction accidentally signalized")
            waiting.route=routeAt(unlit,"ns"); clearing.route=routeAt(unlit,"ew")
            moveTo(waiting,unlit,1,8); moveTo(clearing,unlit,1,4)
            assert(signals:StopGap(waiting.route,waiting.s,waiting.length)==math.huge,"noncentral road received a red light")
            assert(outer:Gap(waiting,{})<math.huge,"unlit EW priority disappeared")
            -- 生命周期：邻近才加载、重复Update不增节点、离开卸载，重返不改时钟。
            outer.cars={}
            signals:Update(outer.time,j.x,j.z,true)
            local loaded=signals:Stats()
            assert(loaded.active==1 and signals.root:IsEnabled(),"nearby visual not created")
            local children=signals.root:GetNumChildren(true)
            for _=1,20 do signals:Update(outer.time,j.x,j.z,true) end
            assert(signals.root:GetNumChildren(true)==children and signals.loaded==loaded.loaded,"visual nodes accumulated")
            local visual=assert(signals.visuals[j.id])
            for _,head in ipairs(visual.heads) do
                local selected=Signals.Signal(outer.time,head.axis,j)
                for color,lens in pairs(head.lenses) do assert(lens.material==(color==selected and signals.colors[color] or signals.off),"visible lens disagrees with logical phase") end
            end
            signals:Update(outer.time,14000,14000,true)
            assert(signals:Stats().active==0 and signals.root:GetNumChildren(true)==0,"far visuals not disposed")
            signals:Update(outer.time,j.x,j.z,true)
            assert(signals.root:GetNumChildren(true)==children,"revisit grew signal geometry")
            -- Freeze使用真正Outer.Update的gate；不改session.options/actor/view/旧交通。
            outer.scanX,outer.scanZ=actor.x,actor.z; outer.scanTime=-100000
            local clock,steps,signalClock=outer.time,outer.steps,signals.time
            local function frozen(label)
                near(outer.time,clock,label.." traffic clock")
                near(outer.steps,steps,label.." simulation steps")
                near(signals.time,signalClock,label.." light clock")
            end
            owner.active=false; outer:Update(.2,{}); frozen("inactive/pause gate")
            owner.active=true; city.space="hostel"; holder:SetEnabledRecursive(false)
            outer:Update(.2,{}); frozen("indoor")
            assert(not signals.root:IsEnabled(),"indoor light remains visible")
            city.space="city"; holder:SetEnabledRecursive(true)
            outer:Update(0,{}); outer:Update(-.1,{}); outer:Update(0/0,{}); frozen("invalid dt")
            actor.x,actor.z=0,0; outer:Update(.1,{}); frozen("old-town outer freeze")
            assert(not signals.root:IsEnabled(),"old-town return keeps outer lights visible")
            actor.x,actor.z=j.x,j.z-40; outer.scanX,outer.scanZ=actor.x,actor.z
            outer:Update(.1,{})
            near(outer.time,clock+.1,"resume catches up wall time")
            near(signals.time,outer.time,"light/traffic clocks diverged")
            assert(writes==0 and same(Store.Get(),profile),"signal checks changed memory profile")
            outer:Dispose(); outer:Dispose()
            assert(signals.disposed and signals:Stats().active==0,"Dispose leaked signals")
            assert(holder:GetNumChildren(true)==0,"Dispose leaked independent traffic/signal nodes")
        end)
    end)
    -- Finally即使断言失败也只释放夹具，不尝试复写生产session的任何字段。
    local cleaned,cleanupError=pcall(function()
        if fixture then fixture:Dispose() end
        holder:Dispose()
    end)
    assert(cleaned,cleanupError)
    assert(same(Store.Get(),profile),"caller memory Store not restored")
    assert(sourceTraffic.time==oldTime and sourceCity.signals.phase==oldPhase,"legacy signal modified")
    assert(realOuter.time==realTime and realOuter.signals.time==realSignalTime and realOuter.signals.visuals==realVisuals,"production outer state modified")
    assert(sourceCity.root:GetNumChildren(true)==originalChildren,"fixture leaked nodes into caller city")
    assert(sourceCity.details.meshCount==originalDetails.meshes and sourceCity.details.boxes==originalDetails.boxes
        and #sourceCity.details.surfaces==originalDetails.surfaces and #sourceCity.obstacles==originalDetails.obstacles,"original city details accumulated")
    if not ok then error(message) end
    print(string.format("[外区中心信号验收通过] 12中心互斥/黄灯双全红/四向长短车车头停线/绿起步/已入清空/无灯让行/freeze/邻近加载卸载Dispose；独立内存与节点夹具；CPU %.3fs",os.clock()-started))
    return true
end
return Checks
