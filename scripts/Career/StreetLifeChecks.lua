-- 显式隔离验收：不启动Runtime/不构建；Run(session)由主测试入口按需调用。
-- 只新建一个临时节点组与真实Rig，不造第二城市、不变更真实档、真实联系人或交通时钟。
local Contacts=require("Career.Contacts")
local Life=require("Career.StreetLife")
local Store=require("Career.Store")
local Config=require("Career.Config")
local Routes=require("Career.TrafficRoutes")
local Pedestrians=require("Career.Pedestrians") --[[@as CareerPedestrians]]
---@class CareerStreetLifeChecks
---@field Run fun(session:CareerSession):boolean
---@field Shot fun(session:CareerSession,view:string)
local Checks={}
local V=Vector3

local function near(a,b,epsilon,message)
    assert(math.abs(a-b)<epsilon,message or string.format("%.7f ~= %.7f",a,b))
end
local function angle(a,b) return math.abs((a-b+180)%360-180) end
local function segmentDistance(x,z,a,b)
    local dx,dz=b.x-a.x,b.z-a.z
    local length=dx*dx+dz*dz
    local t=length>0 and math.max(0,math.min(1,((x-a.x)*dx+(z-a.z)*dz)/length)) or 0
    return math.sqrt((x-a.x-t*dx)^2+(z-a.z-t*dz)^2)
end

---@param p CareerStreetPerson
local function grounded(p,city)
    near(p.node.position.y,city:Surface(p.x,p.z),.0001,"驻点根节点高度错误")
    for _,chain in ipairs(p.rig.legs) do
        local foot=p.node.worldTransform*p.rig:GetBonePosition(chain.tip)
        local ground=city:WalkSurface(foot.x,foot.z,p.node.position.y)
        near(p.rig:SoleHeight(chain.tip)+p.node.position.y,ground,.006,"真实鞋底顶点没有贴地："..p.id)
    end
end
---@param p CareerStreetPerson
local function limbs(p)
    local rig=p.rig
    for _,group in ipairs({rig.arms,rig.legs}) do
        for _,chain in ipairs(group) do
            local a,b,c=rig:GetBonePosition(chain.upper),rig:GetBonePosition(chain.lower),rig:GetBonePosition(chain.tip)
            near((b-a):Length(),chain.lengthA,.00002,"上臂/大腿被拉伸")
            near((c-b):Length(),chain.lengthB,.00002,"前臂/小腿被拉伸")
            if group==rig.arms then
                local direction=(c-a):Normalized()
                local bend=b-a-direction*(b-a):DotProduct(direction)
                local hint=V(chain.side*.12,-.1,-1)
                local perpendicular=hint-direction*hint:DotProduct(direction)
                assert(bend:DotProduct(perpendicular)>0,"手势反折/翻转肘部方向："..p.id)
            end
        end
    end
    for _,name in ipairs(rig.boneNames) do
        local bone=rig.model:GetSkeleton():GetBone(name)
        near((bone.node.position-rig.bind[name].position):Length(),0,.000001,"动作平移了骨骼")
        near((bone.node.scale-rig.bind[name].scale):Length(),0,.000001,"动作缩放了骨骼")
    end
end

-- 驻点原有障碍以副本检查，排除且仅排除本测试注册的自身AABB。
local function withoutSelf(city,p,x,z,radius)
    for _,o in ipairs(city.obstacles) do
        if o~=p.blocker and x>o.x1-radius and x<o.x2+radius and z>o.z1-radius and z<o.z2+radius then return false end
    end
    return true
end
local function obstacleHits(city,x,z,radius,sources)
    local entries={}
    for index,o in ipairs(city.obstacles) do
        if x>o.x1-radius and x<o.x2+radius and z>o.z1-radius and z<o.z2+radius then
            entries[#entries+1]=string.format("%s obstacle#%d AABB[x=%.4f..%.4f,z=%.4f..%.4f]",
                sources[o] or "legacy",index,o.x1,o.x2,o.z1,o.z2)
        end
    end
    return table.concat(entries,"; ")
end
local function compareProbe(city,baseline,sources,x,z,radius,mode,label)
    local currentFree=city:StaticFree(x,z,radius,mode,0)
    local baselineFree=baseline:StaticFree(x,z,radius,mode,0)
    -- 不能用“baseline本来就堵”遮盖叠在同位置的新障碍：新增项逐个独立检查。
    for _,o in ipairs(city.obstacles) do
        if sources[o] and x>o.x1-radius and x<o.x2+radius and z>o.z1-radius and z<o.z2+radius then
            error(string.format("新增阻挡 %s sample=(%.4f,%.4f) r=%.3f baselineFree=%s / %s",
                label,x,z,radius,tostring(baselineFree),obstacleHits(city,x,z,radius,sources)))
        end
    end
    assert(currentFree==baselineFree,string.format("碰撞回归 %s sample=(%.4f,%.4f) r=%.3f currentFree=%s baselineFree=%s / current:%s / baseline:%s",
        label,x,z,radius,tostring(currentFree),tostring(baselineFree),obstacleHits(city,x,z,radius,sources),obstacleHits(baseline,x,z,radius,{})))
    return baselineFree
end
local function verticalClearance(city,path,radius,label)
    assert(path[1]==path[3],"垂直线路精确扫掠要求X恒定")
    local x,z1,z2=path[1],math.min(path[2],path[4]),math.max(path[2],path[4])
    -- 全连续线段与每个外扩AABB精确检测，不以.2m采样漏掉薄障碍。
    for index,o in ipairs(city.obstacles) do
        assert(not(x>o.x1-radius and x<o.x2+radius and z2>o.z1-radius and z1<o.z2+radius),
            string.format("%s连续扫掠撞障碍#%d x=%.4f z=%.4f..%.4f r=%.3f / AABB[%.4f..%.4f,%.4f..%.4f]",
                label,index,x,z1,z2,radius,o.x1,o.x2,o.z1,o.z2))
    end
    print(string.format("[街坊垂直线路精确扫掠] %s x=%.2f z=%.2f..%.2f r=%.2f 全段无障碍",label,x,z1,z2,radius))
end
local function reachable(contacts,city,baseline,sources,paths)
    -- 直接读取生产Pedestrians.people.path，不维护易漂移的第二份路径配置。
    assert(#paths==8,"生产老街行人应有8条路径")
    -- 第7条旧百货实体右边缘-107.85，人物中心-106.8扣r=.32还余.73m。
    -- 第8条保持x91.3/z20..65；先精确检验两条生产静态全集，之后再逐样本baseline对照。
    assert(paths[7][1]==-106.8 and paths[7][3]==-106.8 and paths[7][2]==25 and paths[7][4]==60,"第7线路修复坐标漂移")
    assert(paths[8][1]==91.3 and paths[8][3]==91.3 and paths[8][2]==20 and paths[8][4]==65,"第8线路不应被改")
    verticalClearance(city,paths[7],.32,"path#7")
    verticalClearance(city,paths[8],.32,"path#8")
    for pathIndex,path in ipairs(paths) do
        local count=math.ceil(math.sqrt((path[3]-path[1])^2+(path[4]-path[2])^2)/.2)
        local legacyBlocked=0
        for step=0,count do
            local f=step/count
            local x,z=path[1]+(path[3]-path[1])*f,path[2]+(path[4]-path[2])*f
            local free=compareProbe(city,baseline,sources,x,z,.32,"walk","ped path#"..pathIndex.." step#"..step)
            if not free then
                legacyBlocked=legacyBlocked+1
                if legacyBlocked==1 then
                    print(string.format("[街坊路线baseline] path#%d (%.2f,%.2f)->(%.2f,%.2f) 首个原有阻挡sample=(%.4f,%.4f) r=.32 / %s",
                        pathIndex,path[1],path[2],path[3],path[4],x,z,obstacleHits(baseline,x,z,.32,{})))
                end
            end
        end
        assert(legacyBlocked==0,string.format("生产行人线路仍有原障碍 path#%d blockedSamples=%d；不得把baseline阻挡冒称新线路可通",pathIndex,legacyBlocked))
        print(string.format("[街坊路线对照] path#%d samples=%d baselineBlocked=%d 新增阻挡=0 / 逐样本StaticFree一致",pathIndex,count+1,legacyBlocked))
    end
    for _,p in ipairs(contacts.people) do
        assert(withoutSelf(city,p,p.x,p.z,.45),"人物自身之外静态空间不安全："..p.id)
        for _,point in ipairs(Config.pointList) do
            assert((point.x-p.x)^2+(point.z-p.z)^2>(2+.6)^2,"驻点侵占原POI2m交互圆")
        end
        for _,template in ipairs(Config.orderTemplates) do
            for i=2,#template.route do
                assert(segmentDistance(p.x,p.z,template.route[i-1],template.route[i])>.4+1.2,
                    "驻点侵占旧配送骑行路线："..p.id)
            end
        end
        -- 聊天两人彼此相向，不能把接近线穿过另一人；只选全段安全且最近者为自身的方向。
        local approach=V.FORWARD
        local found=false
        for offset=0,7 do
            local direction=Quaternion(0,p.homeYaw+offset*45,0)*V.FORWARD
            local free=true
            for step=9,18 do
                local sample=p.node.position+direction*(step*.1)
                if not city:StaticFree(sample.x,sample.z,.32,"walk",0) then free=false end
            end
            local target=p.node.position+direction*.9
            if free and contacts:Nearest({x=target.x,z=target.z},1.1)==p then approach=direction; found=true; break end
        end
        assert(found,"无安全且不穿另一街坊的驻点接近线："..p.id)
        local from=p.node.position+approach*1.8
        local x,z=from.x,from.z
        for _=1,9 do x,z=city:Move(x,z,-approach.x*.1,-approach.z*.1,.32,"walk",p.node.position.y) end
        near(math.sqrt((x-p.x)^2+(z-p.z)^2),.9,.002,"City.Move无法走到驻点前.9m")
        local nearest=contacts:Nearest({x=x,z=z},1.1)
        assert(nearest==p,"最近街坊查询与实际位置不同源："..p.id)
    end
    -- 真实TrafficRoutes.Pose覆盖每条直线和两端弧，不推进真实车、不修改s/speed。
    for routeIndex,route in ipairs(Routes.List) do
        for step=0,math.ceil(Routes.LENGTH/.25) do
            local x,z=Routes.Pose(route,step*.25)
            compareProbe(city,baseline,sources,x,z,1.2,"vehicle","vehicle route#"..routeIndex.." step#"..step)
        end
    end
end

---@param contacts CareerContacts
local function poses(contacts,city)
    for _,p in ipairs(contacts.people) do
        local source=p.rig.model:GetModel()
        assert(source and p.rig.model:GetSkeleton():GetNumBones()>0,"没有真实模型/骨骼节点")
        assert(#p.rig.soleVertices.L_Foot>0 and #p.rig.soleVertices.R_Foot>0,"缺失鞋底真实顶点")
        local clamped=p.rig.reachClampedFrames or 0
        for _,kind in ipairs({"talk","greet","nod","handover"}) do
            assert(contacts:Respond(p.id,kind))
            local wrist=p.rig:GetBonePosition("R_Hand")
            -- Respond须在没有后续Update、对话已冻结时立即改变实际手腕。
            p.rig:PoseWalk(0,0)
            assert((wrist-p.rig:GetBonePosition("R_Hand")):Length()>.015,"Respond没有当帧真实手势")
            contacts.life:Pose(p)
            for _=1,25 do
                contacts:Update(.1,{x=p.x+1.5,z=p.z+1.5,mounted=false},8,true)
                grounded(p,city); limbs(p)
            end
        end
        assert((p.rig.reachClampedFrames or 0)==clamped,"驻足手势不应IK超伸")
    end
end

---@param contacts CareerContacts
local function timing(contacts,city)
    local p=assert(contacts:Get("station"))
    local actor={x=p.x+2,z=p.z,mounted=false,walkHeight=p.node.position.y}
    p.yaw,p.node.rotation=0,Quaternion.IDENTITY
    local before=p.node.rotation*V.FORWARD
    contacts:Update(.1,actor,8,true)
    assert(p.yaw>0 and p.yaw<=Life.TURN_SPEED*.1+.001,"近距离转身必须限速且朝向+X")
    local turned=p.node.rotation*V.FORWARD
    assert(turned.x>before.x,"真实节点没有朝向玩家")
    for _=1,20 do contacts:Update(.1,actor,8,true) end
    near(angle(p.yaw,90),0,.01,"近距朝向没有收敛至玩家")
    local clock,yaw,hand,count=p.clock,p.yaw,p.rig:GetBonePosition("R_Hand"),p.poseCount
    assert(contacts:BeginGesture("station","greet"))
    hand=p.rig:GetBonePosition("R_Hand"); count=p.poseCount
    for _=1,30 do contacts:Update(.1,{x=p.x-2,z=p.z,mounted=false},18,false) end
    near(p.clock,clock,.000001,"手机/暂停推进动作时钟")
    near(p.yaw,yaw,.000001,"手机/暂停仍转身")
    near((p.rig:GetBonePosition("R_Hand")-hand):Length(),0,.000001,"手机/暂停仍修改姿势")
    assert(p.poseCount==count and p.node.enabledSelf,"暂停不应隐藏人物或重新求姿势")
    city.space="hostel"
    contacts:Update(.1,actor,8,true)
    assert(not p.node.enabledSelf and p.clock==clock,"室内没有隐藏并冻结")
    city.space="city"
    contacts:Update(.1,actor,8,true)
    assert(p.node.enabledSelf,"返回街区人物没有恢复")
    local nearCount=p.poseCount
    for _=1,20 do contacts:Update(.05,actor,8,true) end
    local nearDelta=p.poseCount-nearCount
    local midCount=p.poseCount
    for _=1,20 do contacts:Update(.05,{x=p.x+45,z=p.z,mounted=false},8,true) end
    assert(p.poseCount-midCount<=5 and nearDelta>=15,"远近骨骼更新未正确降频")
    contacts:Update(.1,{x=1200,z=1200,mounted=false},8,true)
    local farClock,farCount=p.clock,p.poseCount
    for _=1,20 do contacts:Update(.1,{x=1200,z=1200,mounted=false},8,true) end
    assert(not p.node.enabledSelf and p.clock==farClock and p.poseCount==farCount,"远距未隐藏/仍求骨骼")
    assert(not contacts:Get("not_exists") and not contacts:Respond("not_exists"))
    assert(not contacts:BeginGesture("station","invalid"))
    assert(not contacts:Nearest({x=0/0,z=0}))
end

---@param session CareerSession
---@return boolean
function Checks.Run(session)
    assert(session.options and session.options.test==true and type(session.restoreTestStorage)=="function",
        "StreetLifeChecks仅允许test=true的隔离Session")
    local city=assert(session.city)
    local scene=assert(session.scene)
    local beforeNodes=scene:GetNumChildren(true)
    local beforeObstacles=#city.obstacles
    local scratch=scene:CreateChild("StreetLifeChecks隔离节点")
    -- 生产原障碍baseline：仅剔除本轮联系人与StreetDressing自身注册项。
    -- 不重建建筑、不按“前N个”猜障碍归属，按对象identity严格分组。
    local additions={}
    for _,p in ipairs(city.contacts.people) do additions[p.blocker]="contact:"..p.id end
    if city.streetDressing then
        for index,o in ipairs(city.streetDressing.collisions) do additions[o]="dressing#"..index end
    end
    local baselineObstacles={}
    for _,o in ipairs(city.obstacles) do if not additions[o] then baselineObstacles[#baselineObstacles+1]=o end end
    local baseline=setmetatable({root=scratch,obstacles=baselineObstacles,space="city"},{__index=city}) --[[@as CareerCity]]
    -- 测试生产新增环境但不重复生产人物：旧联系人blocker剔除、临时真实人物稍后注册。
    local liveBlockers={}
    for _,p in ipairs(city.contacts.people) do liveBlockers[p.blocker]=true end
    local obstacles={}
    for _,o in ipairs(city.obstacles) do if not liveBlockers[o] then obstacles[#obstacles+1]=o end end
    local baseObstacleCount=#obstacles
    local fixture=setmetatable({root=scratch,obstacles=obstacles,space="city",traffic=nil},{__index=city}) --[[@as CareerCity]]
    -- 不让fixture IsFree读取真实动态交通；StaticFree/Move仍执行完整生产扫掠。
    fixture.IsFree=function(self,x,z,radius,mode,height) return self:StaticFree(x,z,radius,mode,height) end
    ---@type CareerContacts?
    local contacts=nil
    local files={}
    local ok,err=pcall(function()
        Store.WithTestStorage({read=function(path) return files[path],nil,files[path]==nil end,
            write=function(path,text) files[path]=text; return true end},function()
            assert(Store.NewCareer())
            local before=Store.Get()
            contacts=Contacts.New(fixture)
            local testContacts=assert(contacts)
            assert(#testContacts.people==8 and #fixture.obstacles==baseObstacleCount+8,"角色数量无界/碰撞数不匹配")
            for _,p in ipairs(testContacts.people) do additions[p.blocker]="test-contact:"..p.id end
            ---@type number[][]
            local paths=Pedestrians.Paths
            -- 保存旧第3条出错位置的可复现证据；新线路必须全程可通，不接受baseline也堵。
            local oldPath={18,-8.7,74,-8.7}
            local oldBlocked=0
            for step=0,280 do
                local x=oldPath[1]+(oldPath[3]-oldPath[1])*step/280
                if not baseline:StaticFree(x,oldPath[2],.32,"walk",0) then
                    oldBlocked=oldBlocked+1
                    if oldBlocked==1 then print(string.format("[原第3线路证据] sample=(%.4f,-8.7000) / %s",x,obstacleHits(baseline,x,-8.7,.32,{}))) end
                end
            end
            assert(oldBlocked>0,"原第3线路充电桩baseline证据丢失，请重新审查线路修复")
            assert(paths[3][2]==-7.7 and paths[3][4]==-7.7,"第3线路必须有据避开旧充电桩")
            for _,person in ipairs(session.traffic.pedestrians.people) do
                local matched=false
                for _,path in ipairs(paths) do if person.path==path then matched=true; break end end
                assert(matched,"生产行人未使用导出的同源Paths")
            end
            reachable(testContacts,fixture,baseline,additions,paths)
            poses(testContacts,fixture)
            timing(testContacts,fixture)
            local after=Store.Get()
            assert(after.cashCents==before.cashCents and after.time==before.time and after.revision==before.revision,
                "街坊外观/响应不应触发存档、发钱或时间推进")
            local held={}
            for _,p in ipairs(testContacts.people) do held[#held+1]=p.rig end
            testContacts:Dispose(); testContacts:Dispose()
            assert(#fixture.obstacles==baseObstacleCount and not testContacts:Get("station"),"释放后碰撞/API残留")
            for _,rig in ipairs(held) do assert(rig.disposed,"没有显式释放持有的Rig/材质") end
            assert(scratch:GetNumChildren(true)==0,"释放后仍残留联系人节点")
        end)
    end)
    if contacts then contacts:Dispose() end
    scratch:Dispose()
    assert(scene:GetNumChildren(true)==beforeNodes and #city.obstacles==beforeObstacles,"测试未还原真实节点/障碍数量")
    assert(ok,tostring(err))
    print("[街坊生活验收通过] 隔离内存/8真实骨骼节点/鞋底顶点/限速朝向/手势即时回应/肘向骨长/暂停室内/远距降频/原POI和路线/完整车辆轨迹/Dispose；未冒充GPU视觉自然度验收")
    return true
end
-- 固定视角/动作相位的真实场景实拍入口；不在此处启动Runtime或保存截图。
---@param session CareerSession
---@param view string breakfast/conversation/bridge/gesture0/gesture1/gesture2
function Checks.Shot(session,view)
    assert(session.options and session.options.test==true and type(session.restoreTestStorage)=="function",
        "街坊实拍只允许test=true的隔离Session内存档")
    local requested=false
    for _,arg in ipairs(GetArguments()) do
        if arg=="-careerstreetshot="..view then requested=true end
    end
    assert(requested,"街坊实拍需显式-careerstreetshot=<view>")
    assert(view=="breakfast" or view=="conversation" or view=="bridge" or view:match("^gesture[012]$"),"未知街坊实拍视图")
    local city,actor=assert(session.city),assert(session.actor)
    local contacts=city.contacts
    session:ApplySpace("city"); session.online=false; session.waypoint=""
    session.traffic.active=false
    assert(Store.Transaction(function(p) p.phase="working"; p.time=9; p.activeOrders={}; return true end))
    actor.mounted=false; actor.visuals:SetMounted(false)
    actor.bikeX,actor.bikeZ=-14,-18
    local x,z,yaw,pitch,distance=-25,-7.8,180,12,9
    if view=="bridge" then x,z,yaw,pitch,distance=-9.5,-69.7,-70,10,8 end
    if view=="conversation" or view:match("^gesture") then
        local station=assert(contacts:Get("station"))
        local forward=Quaternion(0,station.homeYaw,0)*V.FORWARD
        x,z=station.x+forward.x*1.5,station.z+forward.z*1.5
        yaw,pitch,distance=-30,8,4.8
    end
    assert(city:StaticFree(x,z,.32,"walk",0),"实拍人物fixture必须可达")
    actor:Teleport(x,z,yaw); actor.speed,actor.steer=0,0; actor:SyncVisuals(0)
    session:UpdateEnvironment(9)
    session.view:ClosePhone(); session.view:ShowGame(); session.view:ResetInput()
    -- 不依赖墙钟等待：固定60个显式步，随后test模式接线冻结生产自动Update。
    for _,p in ipairs(contacts.people) do
        p.clock,p.poseElapsed,p.gesture,p.gestureWeight=0,0,"",0
        p.yaw=p.homeYaw; p.node.rotation=Quaternion(0,p.yaw,0)
    end
    for _=1,60 do contacts:Update(.05,actor,9,true) end
    local stage=view:match("^gesture([012])$")
    if stage then
        local p=assert(contacts:Get("station"))
        assert(contacts:BeginGesture("station","greet",2.2))
        p.clock=3
        local u=({["0"]=.04,["1"]=.5,["2"]=.82})[stage]
        p.gestureTime=p.gestureDuration*u; p.gestureWeight=math.sin(u*math.pi)^.65
        contacts.life:Pose(p)
        print(string.format("[街坊固定手势] %s t=%.3f weight=%.3f 真实腕%s",view,p.gestureTime,p.gestureWeight,p.rig:GetBonePosition("R_Hand"):ToString()))
    end
    session.yaw,session.pitch=yaw,pitch
    session.camera:SetModeConfig("normal",{distance=distance,offset=V(0,1.45,0),fov=60})
    session.camera:SetMode("normal")
    session.camera:Update(2,actor.node,yaw,pitch)
    session:Refresh()
    if view=="conversation" then
        assert(session:TalkTo("station"),"实拍必须3m内打开真实现场交谈")
    else session.view.overlay:SetVisible(false) end
    contacts:Update(.1,actor,9,false)
    print(string.format("[街坊实拍就绪] %s 人物(%.2f,%.2f) / 正午前 / 隔离内存 / 生产街区与骨骼 / 固定相位后冻结",view,x,z))
end
return Checks
