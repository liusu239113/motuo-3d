-- 显式隔离验收；不构建/运行、不另建City，不替换session.deliveryMarkers。
-- Run只创建临时真实Markers池；Session.Refresh/Update在独立接线夹具上调用。
local Markers=require("Career.DeliveryMarkers")
local Config=require("Career.Config")
local Store=require("Career.Store")
local Delivery=require("Career.Delivery")
local World=require("Career.WorldData")
---@class CareerDeliveryMarkerChecks
---@field Run fun(session:CareerSession):boolean
---@field Support fun(session:CareerSession):boolean
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
        near(diffuse.a,n==slot.beam and .34 or 1)
        near(emissive.r,expected.r*1.8); near(emissive.g,expected.g*1.8); near(emissive.b,expected.b*1.8)
    end
end
-- 碰撞不变性设计：光柱r=.68/高12m、地环r=1.35、箭头均为纯视觉。
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
-- 真实Session入口、真实城市Surface；仅联系人候选/显示回调为计数夹具，不生成新城。
-- 独立内存Store finally恢复，订单仍用真实模板/Delivery授权，绝不直接改结算结果。
function Checks.Support(session)
    isolated(session)
    local liveCity=assert(session.city)
    local realCity=setmetatable({space="city"},{__index=liveCity}) --[[@as CareerCity]]
    local files={}
    Store.WithTestStorage({read=function(path) return files[path],nil,files[path]==nil end,
        write=function(path,text) files[path]=text;return true end,
        cloud={Get=function() error("支撑专项禁云") end,Set=function() error("支撑专项禁云") end}},function()
        assert(Store.NewCareer())
        local coast=assert(Config.points.coast_view)
        local actor={x=coast.x,z=coast.z,walkHeight=realCity:Surface(coast.x,coast.z),mounted=false,speed=0} --[[@as CareerActor]]
        near(actor.walkHeight,4)
        local talks,dialogs,notices,saves=0,0,0,0
        local city=setmetatable({contacts={Nearest=function() return {id="support_fixture",name="岸坡联系人"},0 end}},{__index=realCity})
        local harness=setmetatable({actor=actor,city=city,space="city",running=true,online=false,options={test=true},
            waypoint="coast_view",manualWaypoint=true,navigation={key="",route={}},
            view={Notice=function() notices=notices+1 end,ShowDialog=function() dialogs=dialogs+1 end},
            TalkTo=function() talks=talks+1;return true end,SavePosition=function() saves=saves+1 end,
            RefreshPhone=function() end,DeliveryResponse=function() end,OfferAdTip=function() end},getmetatable(session)) --[[@as CareerSession]]
        assert(harness:Allowed("coast_view"),"海岸4m真实地面2m内必须可交互")
        harness:Interact();assert(dialogs==1,"海岸4m景点被绝对高度拒绝")
        actor.x=coast.x+4;actor.walkHeight=realCity:Surface(actor.x,actor.z)
        assert(not harness:Allowed("coast_view"),"海岸地面不得扩大2m授权")
        assert(harness:State().contactName=="岸坡联系人","海岸4m真实地面未展示联系人")
        harness:Interact();assert(talks==1,"海岸4m真实地面不能现场交谈")
        local groundedHeight=actor.walkHeight
        actor.walkHeight=groundedHeight+.2
        assert(not harness:Allowed("coast_view"),"离地20cm不得交互")
        assert(harness:State().contactName==nil,"悬空姿态不应展示可交谈提示")
        harness:Interact();assert(talks==1 and dialogs==1,"悬空姿态不得远程交谈或打开景点")
        actor.walkHeight=groundedHeight
        -- 在岸坡使用真实Actor.Move一步，float/连续坡面不会被5cm贴脚容差误拒绝。
        local mover=setmetatable({city=realCity,walkHeight=groundedHeight,yaw=0},getmetatable(session.actor)) --[[@as CareerActor]]
        local x,z,blocked=mover:Move(actor.x,actor.z,.1,.1,.32)
        assert(not blocked,"海岸贴脚一步实际碰撞被挡")
        actor.x,actor.z,actor.walkHeight=x,z,mover.walkHeight
        near(actor.walkHeight,realCity:Surface(x,z),.0001)
        assert(harness:State().contactName=="岸坡联系人","真实Actor.Move后地形float误拒绝")
        -- 真实Contacts.Nearest与StreetActions.TalkTo，联系人为局部纯数据夹具；不声称海岸已有NPC。
        local person={id="support_fixture",name="岸坡联系人",point="coast_view",x=actor.x,z=actor.z}
        local responds,conversations=0,0
        local contactClass=require("Career.Contacts")
        local lifeClass=require("Career.StreetLife")
        local contacts=setmetatable({city=realCity,disposed=false,
            life=setmetatable({city=realCity,disposed=false,people={person},byId={support_fixture=person}},lifeClass),
            Respond=function() responds=responds+1 end},contactClass)
        city.contacts=contacts
        harness.view.ShowConversation=function() conversations=conversations+1 end
        assert(contacts:Nearest(actor,3)==person,"真实Contacts应允许4m地面候选")
        local talk=require("Career.StreetActions").TalkTo
        assert(talk(harness,"support_fixture") and responds==1 and conversations==1,"真实StreetActions拒绝海岸4m地面")
        actor.walkHeight=actor.walkHeight+.2
        assert(not contacts:Nearest(actor,3),"真实Contacts不得把离地者作为可谈候选")
        assert(not talk(harness,"support_fixture") and responds==1,"真实StreetActions不得隔高度交谈")
        actor.walkHeight=realCity:Surface(actor.x,actor.z)
        -- 2m有效取送点：即使高度不足旧+1m阈值，也必须阻止悬空取/送。
        local meal=order("noodle_office","accepted",1)
        assert(Store.Transaction(function(p) p.activeOrders={meal};p.nextOrderSequence=2;return true end))
        local pickup=assert(Config.points[meal.pickupId])
        actor.x,actor.z=pickup.x,pickup.z
        local y=realCity:Surface(actor.x,actor.z)
        for _,dy in ipairs({.2,6}) do
            actor.walkHeight=y+dy
            local revision=Store.Get().revision
            harness:Interact()
            assert(Store.Get().revision==revision and assert(Delivery.GetActive()).status=="accepted" and saves==0,
                "悬空取餐不得SavePosition或推进订单")
        end
        actor.walkHeight=y;actor.x=pickup.x+2.01
        harness:Interact();assert(assert(Delivery.GetActive()).status=="accepted","2m外不得取餐")
        actor.x=pickup.x;actor.walkHeight=realCity:Surface(actor.x,actor.z);harness:Interact()
        assert(assert(Delivery.GetActive()).status=="picked_up","真实地面原地2m取餐应保持可用")
        local drop=assert(Config.points[meal.dropoffId]);actor.x,actor.z=drop.x,drop.z
        actor.walkHeight=realCity:Surface(actor.x,actor.z)+.2
        local before=Store.Get();harness:Interact()
        assert(Store.Get().revision==before.revision and assert(Delivery.GetActive()).status=="picked_up","悬空送餐不得结算")
        actor.walkHeight=realCity:Surface(actor.x,actor.z);harness:Interact()
        assert(not Delivery.GetActive(),"真实地面2m送达应保持可用")
        assert(notices>0 and saves>0,"支撑专项未经过真实交互分支")
    end)
    print("[支撑层交互专项通过] 海岸4m State/Interact/Allowed、真实Actor.Move贴坡、悬空取送拒绝、原2m授权；仅隔离内存")
    return true
end
---@param session CareerSession
---@return boolean
function Checks.Run(session)
    isolated(session)
    Checks.Support(session)
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
        assert(Markers.CAPACITY==5 and #slots==5 and #meshes==4 and #materials==10,"pool must have fixed five slots")
        assert(p.root:GetNumChildren(false)==5 and p.root:GetNumChildren(true)==30 and warm==beforeNodes+31,"unexpected marker node tree")
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
            UpdateEnvironment=function() end,
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
        local approachActor={x=office.x,z=office.z-7,walkHeight=city:Surface(office.x,office.z-7),mounted=false} --[[@as CareerActor]]
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
        -- office处凭空height=6不是桥层；NavigationLayer只认真实支撑，不能把伪高层当桥顶反证。
        -- 改用真实外区天桥，同XZ切换桥下/桥顶且不手动清缓存，验证层key及坡脚接续。
        local bridge=assert(World.Bridges[1])
        approachActor.mounted=false;approachActor.x,approachActor.z=bridge.x,bridge.z
        approach.waypoint="world_east_market_lobby"
        approachActor.walkHeight=city:Surface(bridge.x,bridge.z)
        assert(World.NavigationLayer(bridge.x,bridge.z,approachActor.walkHeight)=="ground")
        local under=assert(approach:Target());local underKey=approach.navigation.key
        local underRoute=assert(under.route)
        assert(#underRoute>1 and underRoute[1].layer~="bridge:"..bridge.id,"桥下同XZ不得导航上桥")
        approachActor.walkHeight=bridge.y
        assert(World.NavigationLayer(bridge.x,bridge.z,bridge.y)=="bridge:"..bridge.id)
        local above=assert(approach:Target());local aboveRoute=assert(above.route)
        assert(approach.navigation.key~=underKey and #aboveRoute>1 and aboveRoute[1].layer=="bridge:"..bridge.id,
            "桥顶必须换导航缓存层，不复用同XZ地面路线")
        near(aboveRoute[1].y,bridge.y)
        local ramp=false
        for i=2,#aboveRoute do
            local a,b=aboveRoute[i-1],aboveRoute[i]
            if a.layer~="ground" and b.layer=="ground" then
                near(a.z,bridge.z-64);near(b.z,bridge.z-66);near(math.abs(a.x-bridge.x),20)
                ramp=true
            end
        end
        local destination=assert(Config.points[approach.waypoint])
        assert(ramp and above.distance>Config.DistanceTo(destination.id,bridge.x,bridge.z)+20,
            "真实桥顶必须沿坡道返回地面，不能直落同XZ")
        near(above.distance,Config.RouteDistance(aboveRoute))
        approachActor.walkHeight=city:Surface(bridge.x,bridge.z)
        near(assert(approach:Target()).distance,under.distance)
        approach.waypoint="office";approachActor.x=office.x
        approachActor.walkHeight=city:Surface(office.x,office.z+7);approachActor.z=office.z+7
        assert(not city:StaticSegmentFree(approachActor.x,approachActor.z,office.x,office.z,.32,"walk",0),"隔墙反例必须有实际低墙")
        local blocked=assert(approach:Target())
        ---@type CareerRoutePoint[]
        local blockedPoints=assert(blocked.route)
        -- 楼体内部反例可能完全无路网接入；沿用原逻辑的无路线直线兜底，不伪造可走路线。
        local blockedExpected=#blockedPoints>1 and Config.RouteDistance(blockedPoints) or 7
        near(blocked.distance,blockedExpected)
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
