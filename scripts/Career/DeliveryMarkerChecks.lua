-- 显式隔离验收；不构建/运行、不另建City，不替换session.deliveryMarkers。
-- Run只创建临时真实Markers池；Session.Refresh/Update在独立接线夹具上调用。
local Markers=require("Career.DeliveryMarkers")
local Config=require("Career.Config")
local Store=require("Career.Store")
local Delivery=require("Career.Delivery")
local World=require("Career.WorldData")
---@class CareerDeliveryMarkerChecks
---@field Run fun(session:CareerSession):boolean
---@field Shot fun(session:CareerSession,view:string)
local Checks={}
local function copy(v)
    if type(v)~="table" then return v end
    local result={}; for k,item in pairs(v) do result[k]=copy(item) end
    return result
end
local function same(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~="table" then return a==b end
    for k,v in pairs(a) do if not same(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
local function near(a,b,tolerance) assert(math.abs(a-b)<(tolerance or .00001),string.format("%.8f ~= %.8f",a,b)) end
---@param session CareerSession
local function isolated(session)
    assert(session.options and session.options.test==true and type(session.restoreTestStorage)=="function",
        "DeliveryMarkerChecks requires explicit test=true + restoreTestStorage memory isolation")
    assert(session.running and session.city and session.scene and session.actor,"Session world must be ready")
end
---@param templateId string
---@param status string
---@param sequence integer
---@return CareerOrder
local function order(templateId,status,sequence)
    local t=assert(Config.GetTemplate(templateId)); local distance=Config.RouteDistance(t.route)
    return {id="career-v1-"..sequence,sequence=sequence,templateId=t.id,title=t.title,
        pickupId=t.pickupId,dropoffId=t.dropoffId,status=status,route=copy(t.route),distanceMeters=distance,
        feeCents=t.tutorial and 500 or Config.FeeCents(distance),tutorial=t.tutorial,
        acceptedDay=1,acceptedTime=8,remainingHours=t.timeLimitHours,late=false}
end
---@param x number
---@param z number
---@return CareerActor
local function viewer(x,z) return {x=x,z=z} --[[@as CareerActor]] end
---@param pool CareerDeliveryMarkers
local function active(pool)
    local count=0; for _,s in ipairs(pool.slots) do if s.active then count=count+1 end end
    return count
end
---@param slot CareerDeliveryMarker
---@param expected Color
local function color(slot,expected)
    for _,n in ipairs({slot.arrow,slot.ring,slot.beam}) do
        local model=assert(n:GetComponent("StaticModel")) --[[@as StaticModel]]
        assert(model:GetModel() and model:GetNumGeometries()>0,"real render mesh missing")
        local mat=assert(model:GetMaterial())
        local diffuse=mat:GetShaderParameter("MatDiffColor"):GetColor()
        local emissive=mat:GetShaderParameter("MatEmissiveColor"):GetColor()
        near(diffuse.r,expected.r); near(diffuse.g,expected.g); near(diffuse.b,expected.b)
        near(diffuse.a,n==slot.beam and .19 or 1)
        near(emissive.r,expected.r*1.8); near(emissive.g,expected.g*1.8); near(emissive.b,expected.b*1.8)
    end
end
-- 碰撞不变性设计：光柱r=.42/高6m、地环r=1.12、箭头均为纯视觉。
-- 俯视 [中心]--.32m步行探针--1.2m车辆探针；地面/高层6m均不得新增阻挡。
-- 同时覆盖旧城墙中心、各外区实际障碍中心和所有POI；不要求原本被挡的点可走。
---@param city CareerCity
local function collisionSnapshot(city)
    local probes={}
    local function sample(x,z)
        for _,height in ipairs({0,6}) do
            for _,mode in ipairs({"walk","vehicle"}) do
                local r=mode=="walk" and .32 or 1.2
                probes[#probes+1]={x=x,z=z,r=r,height=height,mode=mode,
                    world=World.IsFree(x,z,r,mode,height),static=city:StaticFree(x,z,r,mode,height),
                    city=city:IsFree(x,z,r,mode,height)}
            end
        end
    end
    for _,p in ipairs(Config.pointList) do sample(p.x,p.z); sample(p.x+.32,p.z); sample(p.x+1.2,p.z) end
    for _,o in ipairs(city.obstacles) do sample((o.x1+o.x2)/2,(o.z1+o.z2)/2) end
    local cells={}
    for _,d in ipairs(World.Districts) do
        local ix,iz=math.floor(d.x/World.CELL),math.floor(d.z/World.CELL)
        local cell=World.DescribeCell(ix,iz)
        cells[#cells+1]={ix=ix,iz=iz,obstacles=copy(cell.obstacles)}
        for _,o in ipairs(cell.obstacles) do sample((o.x1+o.x2)/2,(o.z1+o.z2)/2) end
    end
    return function()
        for _,p in ipairs(probes) do
            assert(World.IsFree(p.x,p.z,p.r,p.mode,p.height)==p.world
                and city:StaticFree(p.x,p.z,p.r,p.mode,p.height)==p.static
                and city:IsFree(p.x,p.z,p.r,p.mode,p.height)==p.city,"markers changed logical collision")
        end
        for _,c in ipairs(cells) do assert(same(World.DescribeCell(c.ix,c.iz).obstacles,c.obstacles),"World obstacles changed") end
    end
end
---@param session CareerSession
---@return boolean
function Checks.Run(session)
    isolated(session)
    local city,scene=assert(session.city),assert(session.scene)
    local production=assert(session.deliveryMarkers,"Session.BuildWorld must create markers")
    assert(not production.disposed and production.city==city and production.root:GetParent()==city.root,"Session marker wiring broken")
    local previousSpace=city.space
    local beforeNodes=scene:GetNumChildren(true)
    local obstacles,obstacleData=city.obstacles,copy(city.obstacles)
    local profile=Store.Get() -- 已就绪的外层内存档；Run不调用Load/NewCareer/Transaction。
    ---@type CareerDeliveryMarkers?
    local pool=nil
    local ok,failure=pcall(function()
        city.space="city" -- 全城WalkSurface必须使用城市地表，不能在室内读出统一.085。
        local collisionUnchanged=collisionSnapshot(city)
        pool=Markers.New(city)
        local p=assert(pool)
        local slots,meshes,materials=p.slots,p.meshes,p.materials
        ---@type Object[]
        local resources={p.root}
        for _,mesh in ipairs(meshes) do resources[#resources+1]=mesh end
        for _,mat in ipairs(materials) do resources[#resources+1]=mat end
        for _,resource in ipairs(resources) do assert(resource:GetTypeName()~="","resource must be live before Dispose") end
        local warm=scene:GetNumChildren(true)
        assert(Markers.CAPACITY==5 and #slots==5 and #meshes==3 and #materials==10,"pool must have fixed five slots")
        assert(p.root:GetNumChildren(false)==5 and p.root:GetNumChildren(true)==25 and warm==beforeNodes+26,"unexpected marker node tree")
        local fixtures={order("noodle_office","accepted",1),order("shop_old","accepted",2),
            order("noodle_office","picked_up",3),order("old_home","picked_up",4)}
        local original=copy(fixtures)
        p:Sync(fixtures,{pointId="park"}); assert(active(p)==5,"four order targets plus navigation must fit")
        color(slots[1],Color(1,.65,.08)); color(slots[3],Color(.12,1,.72)); color(slots[5],Color(.25,.65,1))
        local overflow=copy(fixtures); overflow[5]=order("dealer_lunch","picked_up",5)
        for _=1,30 do p:Sync(overflow,{pointId="park"}); p:Sync(fixtures,{pointId="park"}) end
        assert(#p.slots==5 and p.slots==slots and p.meshes==meshes and p.materials==materials
            and scene:GetNumChildren(true)==warm,"Sync grew/replaced the fixed pool")
        p:Sync({fixtures[1],order("noodle_dealer","accepted",6)},{pointId="noodle"})
        assert(active(p)==1 and slots[1].pointId=="noodle","same point/order/navigation must deduplicate")
        p:Sync({fixtures[4],order("shop_old","picked_up",7)})
        assert(active(p)==1 and slots[1].pointId=="home_old","shared dropoff must deduplicate")
        color(slots[1],Color(.12,1,.72)) -- 同槽真正换材质，不只检查stage字符串。
        p:Sync({order("noodle_office","offered",8)},{pointId="not_exists"}); assert(active(p)==0,"inactive/unknown target accepted")
        p:Sync({fixtures[1]}); local s=slots[1]; local a=viewer(s.x,s.z)
        p:Update(0,a,false); assert(s.visible and s.root.enabledSelf and s.label:GetText():find("取餐",1,true),"pickup render/text missing")
        assert(s.label:GetFont() and s.label:GetFontSize()>0 and s.label:GetNumChars()>0,"Text3D font/glyphs missing")
        local arrow,ring,clock=s.arrow.position,s.ring.scale,p.clock
        p:Update(.1,a,true)
        assert(p.clock>clock and (s.arrow.position-arrow):Length()>.001 and (s.ring.scale-ring):Length()>.001,"animation changed metadata but not nodes")
        arrow,ring,clock=s.arrow.position,s.ring.scale,p.clock
        for _=1,30 do p:Update(.1,a,false) end
        near(p.clock,clock); near((s.arrow.position-arrow):Length(),0); near((s.ring.scale-ring):Length(),0)
        assert(s.root.enabledSelf,"pause must freeze, not hide outdoor marker")
        city.space="hostel"; p:Update(.1,a,false); assert(not s.visible and not s.root.enabledSelf,"indoor marker not hidden")
        city.space="city"; p:Update(0,a,false); assert(s.visible and s.root.enabledSelf,"return outdoors did not restore marker")
        p:Update(0,viewer(s.x+Markers.DRAW_DISTANCE+.01,s.z),false); assert(not s.root.enabledSelf,"far marker still enabled")
        p:Update(0,viewer(s.x+Markers.DRAW_DISTANCE,s.z),false); assert(s.root.enabledSelf,"draw-distance boundary excluded")
        p:Update(0,a,false); assert(s.root.enabledSelf,"near marker failed to return")
        -- 全部真实配置点，不Ensure外区、不复制城市、不移动真实Actor。
        for _,point in ipairs(Config.pointList) do
            p:Sync({},{pointId=point.id}); p:Update(0,viewer(point.x,point.z),false)
            local first=slots[1]
            assert(first.visible and first.root.enabledSelf,"configured target invisible: "..point.id)
            -- 引擎坐标为float32；公里级坐标采用两倍相对ULP，颜色/动画仍用原绝对精度。
            near(first.root.position.x,point.x,math.max(1,math.abs(point.x))*2^-22)
            near(first.root.position.z,point.z,math.max(1,math.abs(point.z))*2^-22)
            near(first.root.position.y,city:WalkSurface(point.x,point.z,0))
        end
        -- 只替身无关依赖；真实Session方法 -> 临时真实Markers -> 原City节点/地表。
        -- 不把临时池写入session；不调用真实View/Traffic/Actor更新或Save。
        local state=copy(profile); state.activeOrders=fixtures
        local updates=0
        local harness=setmetatable({options={test=true},running=true,actor=a,deliveryMarkers=p,
            city={UpdateStreaming=function() end,contacts={Update=function() end}},
            State=function() return state end,Target=function() return {pointId="park"} end,
            Pause=function() end,
            view={IsBlocking=function() return true end,UpdateSpeech=function() end,LayoutControls=function() end,
                controls={UpdateFeedback=function() end},phonePage="",conversation={IsVisible=function() return false end},
                Update=function() updates=updates+1 end}},getmetatable(session)) --[[@as CareerSession]]
        harness:Refresh(); assert(updates==1 and active(p)==5 and slots[1].pointId=="noodle","Session.Refresh did not Sync orders/target")
        near(p.clock,clock)
        city.space="hostel"; harness:Update(.1); assert(not slots[1].root.enabledSelf,"Session.Update not forwarding indoor visibility")
        city.space="city"; harness:Update(.1); assert(slots[1].root.enabledSelf,"Session.Update not restoring outdoor marker")
        near(p.clock,clock) -- test=true/阻塞UI均不得推进clock。
        p:Sync({}); p:Update(0,a,false)
        for _,slot in ipairs(slots) do assert(not slot.active and not slot.root.enabledSelf,"empty Sync left a node visible") end
        assert(same(fixtures,original) and same(Store.Get(),profile),"markers/checks mutated orders or Store")
        assert(city.obstacles==obstacles and same(city.obstacles,obstacleData),"city.obstacles changed")
        collisionUnchanged()
        -- 近门前距离只在地面步行且真实整段净空时走直线；不修改订单/原路网/2米授权。
        local office=assert(Config.points.office)
        local approachActor={x=office.x,z=office.z-7,walkHeight=0,mounted=false} --[[@as CareerActor]]
        local approach=setmetatable({actor=approachActor,city=city,space="city",manualWaypoint=true,
            waypoint="office",navigation={key="",route={}}},getmetatable(session)) --[[@as CareerSession]]
        assert(city:StaticSegmentFree(approachActor.x,approachActor.z,office.x,office.z,.32,"walk",0),"门前7米实景接近段应净空")
        near(assert(approach:Target()).distance,7)
        assert(not approach:Allowed("office"),"近门直线显示不得扩大2米交互圈")
        approachActor.mounted=true
        local routed=assert(approach:Target())
        ---@type CareerRoutePoint[]
        local routedPoints=assert(routed.route)
        near(routed.distance,Config.RouteDistance(routedPoints))
        assert(routed.distance>7,"骑行仍应显示原道路路线")
        approachActor.mounted=false;approachActor.walkHeight=6
        near(assert(approach:Target()).distance,routed.distance)
        approachActor.walkHeight=0;approachActor.z=office.z+7
        assert(not city:StaticSegmentFree(approachActor.x,approachActor.z,office.x,office.z,.32,"walk",0),"隔墙反例必须有实际低墙")
        local blocked=assert(approach:Target())
        ---@type CareerRoutePoint[]
        local blockedPoints=assert(blocked.route)
        near(blocked.distance,Config.RouteDistance(blockedPoints))
        assert(same(Store.Get(),profile),"接近段显示不得改订单金额/档案")
        for _,kind in ipairs({"RigidBody","CollisionShape","RigidBody2D","CollisionShape2D"}) do
            assert(#p.root:GetChildrenWithComponent(kind,true)==0 and not p.root:HasComponent(kind),"marker acquired collision component")
        end
        -- 仅在销毁阶段包装私有池的资源引用，记录真实Dispose调用；不改引擎userdata/共享资源。
        -- 不假定不同平台对已释放userdata的GetTypeName都会抛错。
        local released={}
        ---@param resource Object
        local function tracked(resource)
            return {Dispose=function()
                released[resource]=(released[resource] or 0)+1
                resource:Dispose()
            end}
        end
        p.root=tracked(p.root) --[[@as Node]]
        for i,mesh in ipairs(meshes) do meshes[i]=tracked(mesh) --[[@as Model]] end
        for i,mat in ipairs(materials) do materials[i]=tracked(mat) --[[@as Material]] end
        p:Dispose(); p:Dispose()
        assert(p.disposed and #p.slots==0 and #p.meshes==0 and #p.materials==0,"Dispose did not clear owned resources")
        for _,resource in ipairs(resources) do assert(released[resource]==1,"owned resource must receive exactly one explicit Dispose") end
        p:Sync(fixtures); p:Update(.1,a,true)
        assert(scene:GetNumChildren(true)==beforeNodes and #p.slots==0,"disposed pool resurrected/leaked nodes")
    end)
    -- finally：任何断言/Dispose失败也必须恢复space；不访问已Dispose的节点。
    city.space=previousSpace
    local released,releaseError=pcall(function() if pool then pool:Dispose() end end)
    local restored,restoreError=pcall(function()
        assert(session.deliveryMarkers==production and not production.disposed,"production markers were replaced/disposed")
        assert(scene:GetNumChildren(true)==beforeNodes,"temporary marker nodes leaked")
        assert(city.obstacles==obstacles and same(city.obstacles,obstacleData) and same(Store.Get(),profile),"Run changed caller state")
    end)
    if not ok then error(tostring(failure)..(not released and " / cleanup: "..tostring(releaseError) or "")
        ..(not restored and " / restore: "..tostring(restoreError) or ""),0) end
    assert(released,releaseError); assert(restored,restoreError)
    print("[配送光柱隔离验收通过] 五槽/去重/真实材质与节点动画/全城Y/暂停室内远距/Session接线夹具/碰撞不变/显式Dispose；非GPU实拍。")
    return true
end

-- 有意保留测试场景作图；调用者负责截图及Session.Dispose，不注册事件/自启动。
---@param session CareerSession
---@param view string pickup|dropoff
function Checks.Shot(session,view)
    isolated(session)
    assert(view=="pickup" or view=="dropoff","unknown beacon shot")
    local requested=false
    for _,arg in ipairs(GetArguments()) do if arg=="-careerbeaconshot="..view then requested=true end end
    assert(requested,"shot requires explicit -careerbeaconshot=pickup|dropoff")
    local city,actor,pool=assert(session.city),assert(session.actor),assert(session.deliveryMarkers)
    assert(session.camera and pool.city==city,"shot requires existing ThirdPersonCamera and production markers")
    -- 真实模板、完整CareerOrder，经既有内存Store事务安装；不伪造钱包或结算奖励。
    assert(Store.Transaction(function(p)
        p.activeOrders={order("noodle_office","accepted",p.nextOrderSequence)}
        p.nextOrderSequence=p.nextOrderSequence+1; p.phase="working"; return true
    end))
    session:ApplySpace("city"); session.online=false; session.manualWaypoint=false; session.waypoint=""
    session.view:CloseConversation(); session.view:ClosePhone(); session.view:ShowGame(); session.view:ResetInput()
    actor.mounted=false; actor.visuals:SetMounted(false); actor.speed,actor.steer=0,0
    if view=="dropoff" then
        local o=assert(Delivery.GetActive()); local point=assert(Config.points[o.pickupId])
        assert(Delivery.Pickup(o.id,point.x,point.z,{riding=false,speed=0}))
    end
    local o=assert(Delivery.GetActive()); local id=view=="pickup" and o.pickupId or o.dropoffId
    local point=assert(Config.points[id]); local x,z=city:FindFree(point.x,point.z-7,.32,"walk",0)
    assert(z,"shot requires valid Z"); actor:Teleport(x,z,0); actor:SyncVisuals(0)
    if session.traffic then session.traffic.active=false end
    session.navigation={key="",route={}}; session:Refresh(); session:UpdateEnvironment(9)
    session.yaw,session.pitch=0,12
    session.camera:SetModeConfig("normal",{distance=11,offset=Vector3(0,1.4,0),fov=60})
    session.camera:SetMode("normal"); session.camera:Update(2,actor.node,session.yaw,session.pitch)
    pool:Update(.1,actor,false); session.view.overlay:SetVisible(false)
    print("[配送光柱实拍就绪] "..view.." / "..id.." / memory-only / ThirdPersonCamera；由调用者截图并Dispose")
end
return Checks
