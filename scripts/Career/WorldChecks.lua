-- 显式 -careerchecks 内的世界验收；只使用嵌套内存档，不读写真实 PlayerProfile。
-- 基于现有 Career.Checks/HousingChecks 的隔离与 finally 恢复模式，不创建第二套城市。
local Store=require("Career.Store")
local Config=require("Career.Config")
local Delivery=require("Career.Delivery")
local World=require("Career.WorldData")
local Checks={}
local WALK_RADIUS,DT,WALK_SPEED=.32,.1,1.8

local function near(a,b,epsilon,message)
    assert(math.abs(a-b)<(epsilon or .001),message or string.format("%.6f ~= %.6f",a,b))
end
local function passed(message) print("[世界验收通过] "..message) end
---@param session CareerSession
local function isolated(session)
    assert(session.options and session.options.test==true and type(session.restoreTestStorage)=="function",
        "WorldChecks 只允许 Session.New({test=true}) 的隔离 Session")
    assert(session.actor and session.city and session.city.stream and session.scene,"世界尚未就绪")
end
local function districtById(id)
    for _,d in ipairs(World.Districts) do if d.id==id then return d end end
    error("未知外区："..tostring(id))
end
local function signature(cell)
    -- 只比较描述数据，不把易变的 Node/材质句柄当成逻辑碰撞源。
    local values={cell.ix,cell.iz,#cell.buildings,#cell.trees,#cell.obstacles,#cell.grounds}
    for _,o in ipairs(cell.obstacles) do
        values[#values+1]=string.format("%s:%.9f:%.9f:%.9f:%.9f:%.9f:%.9f",
            o.kind,o.x1,o.x2,o.z1,o.z2,o.y1,o.y2)
    end
    return table.concat(values,"|")
end
local function exactRoute(route,from,to,label)
    assert(route and #route>=2,"缺少路线："..label)
    near(route[1].x,from.x,.001,label.." 起点X")
    near(route[1].z,from.z,.001,label.." 起点Z")
    near(route[#route].x,to.x,.001,label.." 终点X")
    near(route[#route].z,to.z,.001,label.." 终点Z")
    for i=2,#route do
        assert(World.SegmentFree(route[i-1],route[i],WALK_RADIUS),label.." 全段扫掠穿障碍，段"..i)
    end
    return Config.RouteDistance(route)
end

local function logicalWorld(city)
    assert(World.LIMIT==15000 and World.LIMIT*2==30000,"世界应为±15000米、跨度30公里")
    local edge=World.LIMIT-WALK_RADIUS
    for _,p in ipairs({{x=edge,z=0},{x=-edge,z=0},{x=0,z=edge},{x=0,z=-edge}}) do
        assert(World.IsFree(p.x,p.z,WALK_RADIUS),"边界内主干道应可达")
        assert(city:StaticFree(p.x,p.z,WALK_RADIUS),"City 与世界边界内判断不同源")
    end
    for _,p in ipairs({{x=15000,z=0},{x=-15000,z=0},{x=0,z=15000},{x=0,z=-15000}}) do
        assert(not World.IsFree(p.x,p.z,WALK_RADIUS),"角色半径不能越界")
        assert(not city:StaticFree(p.x,p.z,WALK_RADIUS),"City 不能放行世界边界")
    end
    local span=assert(World.Route(-14998,0,14998,0))
    near(exactRoute(span,{x=-14998,z=0},{x=14998,z=0},"东西贯通"),29996,.001)
    assert(not World.Route(15001,0,0,0),"越界路线必须拒绝")
    passed("bounds ±15000m / 29996m真实共享路网全段精确扫掠（不是0.1m遍历）")

    assert(#World.Districts==12,"必须有12个外区")
    local old={x=0,z=-20}
    for _,d in ipairs(World.Districts) do
        assert(World.District(d.x,d.z).id==d.id,"分区中心归属错误："..d.id)
        local points=0
        for _,p in ipairs(World.Points) do if p.district==d.id then
            points=points+1
            assert(Config.points[p.id] and Config.points[p.id].x==p.x and Config.points[p.id].z==p.z,
                "POI 必须与 Config 同源："..p.id)
            assert(World.IsFree(p.x,p.z,WALK_RADIUS,"walk",0),"外区POI被静态障碍堵塞："..p.id)
            assert(city:StaticFree(p.x,p.z,WALK_RADIUS,"walk",0),"City静态POI不可达："..p.id)
            -- 每一个新区POI都验证从老街的完整共享Route，不仅检查终点或稀疏样本。
            local route=assert(World.Route(old.x,old.z,p.x,p.z),"老街到外区无路："..p.id)
            exactRoute(route,old,p,p.id)
        end end
        assert(points>=4,"外区缺少取餐/收餐/充电/休息点："..d.id)
        passed(d.id.." / "..points.."个静态POI可达 / 老街共享Route全段SegmentFree")
    end
    for _,t in ipairs(World.Orders) do
        local from,to=assert(Config.points[t.pickupId]),assert(Config.points[t.dropoffId])
        exactRoute(t.route,from,to,t.id)
        assert(Config.GetTemplate(t.id)==t,"外区报价模板不是同源对象："..t.id)
    end
    passed(#World.Orders.."个外区订单模板完整路线精确扫掠，无真实Ensure全12区")
end

local function legacyQuotes()
    local expected={
        {"tutorial",171,500,1.5,{{-25,-8},{-25,0},{-100,0},{-100,80},{-108,80}}},
        {"old_home",171,276,1,{{-25,-8},{-25,0},{-100,0},{-100,80},{-108,80}}},
        {"dealer_lunch",221,283,1,{{-25,-8},{-25,0},{100,0},{100,80},{108,80}}},
        {"park_lunch",166,275,1,{{-25,-8},{-25,0},{100,0},{100,-25},{108,-25}}},
        {"noodle_office",168,275,1,{{-70,9},{-70,0},{0,0},{0,44},{-45,44}}},
        {"shop_old",250,288,1,{{53,9},{53,0},{-100,0},{-100,80},{-108,80}}},
        {"noodle_dealer",267,290,1,{{-70,9},{-70,0},{100,0},{100,80},{108,80}}},
    }
    for index,e in ipairs(expected) do
        local t=assert(Config.GetTemplate(e[1]))
        assert(Config.orderTemplates[index]==t and #t.route==#e[5],"旧模板顺序/拐点数被改："..e[1])
        near(Config.RouteDistance(t.route),e[2],.001)
        near(t.timeLimitHours,e[4],.001)
        assert(t.tutorial==(index==1),"旧教学标记被改")
        for n,p in ipairs(e[5]) do near(t.route[n].x,p[1]); near(t.route[n].z,p[2]) end
        assert(Store.Transaction(function(p)
            p.flags.tutorialCompleted=index~=1
            p.nextOrderSequence=index==1 and 1 or index
            return true
        end))
        local offer=assert(Delivery.GetOffer())
        assert(offer.templateId==e[1] and offer.distanceMeters==e[2] and offer.feeCents==e[3],
            "旧模板实际报价改变："..e[1])
        passed(string.format("旧报价 %s / %dm / %d分 / 原拐点与时限不变",e[1],offer.distanceMeters,offer.feeCents))
    end
end

-- 真实 Actor:Move -> City:Move -> 静态同源碰撞；1.8m/s、dt=.1。
-- 这是碰撞/桥层步行验收，不冒称使用 Actor:Update 测过加速或骑行动力。
-- 仅起点可fixture Teleport；沿程禁止Teleport/FindFree直接写终点。
---@param actor CareerActor
local function walkPath(actor,route,onStep)
    local frames,total=0,0
    for index=2,#route do
        local goal=route[index]
        while true do
            local dx,dz=goal.x-actor.x,goal.z-actor.z
            local remaining=math.sqrt(dx*dx+dz*dz)
            if remaining<.00001 then break end
            local length=math.min(WALK_SPEED*DT,remaining)
            local x,z,blocked=actor:Move(actor.x,actor.z,dx/remaining*length,dz/remaining*length,WALK_RADIUS)
            local moved=math.sqrt((x-actor.x)^2+(z-actor.z)^2)
            assert(not blocked and math.abs(moved-length)<.0001,"Actor实际步行被阻挡，段"..index)
            actor.x,actor.z=x,z
            actor.yaw=math.deg(math.atan(dx,dz)); actor.speed=moved/DT
            frames,total=frames+1,total+moved
            assert(frames<2200,"实际步行超过有限帧预算")
            if onStep then onStep() end
        end
    end
    actor.speed,actor.steer=0,0
    actor:SyncVisuals(0)
    return frames,total
end

local function farSave(session,d)
    local a=assert(session.actor)
    local x,z=d.x+32,d.z-20
    a.mounted=false; a.visuals:SetMounted(false)
    a.bikeX,a.bikeZ,a.bikeYaw=d.x,d.z-20,73
    a:Teleport(x,z,37)
    session.cityX,session.cityZ,session.cityYaw=x,z,37
    local pos=session:PositionSnapshot()
    assert(Store.SetPosition(pos) and Store.Save() and Store.Load(),"远区人物停车存档失败")
    local loaded=Store.Get().position
    near(loaded.x,x); near(loaded.z,z); near(loaded.bikeX,d.x); near(loaded.bikeZ,d.z-20)
    -- 真实 RestorePosition 必须退出室内并保留远坐标，而非 fallback 老街(0,-20)。
    session:ApplySpace("hostel")
    a:Teleport(0,0,0); a.bikeX,a.bikeZ=1.5,-20
    session:RestorePosition()
    assert(session.space=="city" and session.city.space=="city")
    near(a.x,x); near(a.z,z); near(a.yaw,37)
    near(a.bikeX,d.x); near(a.bikeZ,d.z-20); near(a.bikeYaw,73)
    local park=a:ParkingSnapshot()[a.vehicleId]
    near(park.x,d.x); near(park.z,d.z-20)
    passed(d.id.." 远坐标人物+独立停车 Save/Load/Session.RestorePosition，不回老街，space正确")
end

local function localDelivery(session,d)
    local a=assert(session.actor)
    local template=assert(Config.GetTemplate("world_"..d.id.."_local"))
    local from,to=assert(Config.points[template.pickupId]),assert(Config.points[template.dropoffId])
    local expectedDistance=Config.RouteDistance(template.route)
    assert(expectedDistance>=128 and expectedDistance<250,"本地验收单必须保持短路线预算")
    a.mounted=false; a.visuals:SetMounted(false); a:Teleport(from.x,from.z,0)
    assert(Store.SetPosition(session:PositionSnapshot()))
    assert(Store.Transaction(function(p)
        p.flags.tutorialCompleted=true; p.nextOrderSequence=2; p.activeOrders={}; p.phase="working"
        return true
    end))
    local offer=assert(Delivery.GetOffer())
    assert(offer.templateId==template.id,"外区当前位置应真实派发本地单，而非注入活动订单")
    local cash,completed=Store.Get().cashCents,Store.Get().completedOrders
    assert(Delivery.Accept(offer.id))
    assert(not Delivery.Deliver(offer.id,a.x,a.z,{riding=false,speed=0}),"先送后取不能放行")
    assert(Delivery.Pickup(offer.id,a.x,a.z,{riding=a.mounted,speed=a.speed}))
    assert(not Delivery.Deliver(offer.id,a.x,a.z,{riding=false,speed=0}),"取餐点不能远程结算")
    local route=assert(World.Route(a.x,a.z,to.x,to.z))
    exactRoute(route,from,to,template.id)
    local frames,meters=walkPath(a,route,function() assert(Delivery.Update(DT,0)) end)
    near(meters,expectedDistance,.001)
    local minFrames=math.ceil(expectedDistance/(WALK_SPEED*DT)-.00001)
    assert(frames>=minFrames and frames<=minFrames+#route,"真实路线步行不应跳段/瞬移")
    assert(Config.DistanceTo(to.id,a.x,a.z)<.001)
    assert(Delivery.Deliver(offer.id,a.x,a.z,{riding=a.mounted,speed=a.speed}))
    assert(not Delivery.GetActive() and Store.Get().cashCents==cash+offer.feeCents)
    assert(Store.Get().completedOrders==completed+1)
    assert(not Delivery.Deliver(offer.id,a.x,a.z,{riding=false,speed=0}),"不能重复到账")
    assert(Store.Save() and Store.Load())
    assert(Store.Get().settledOrders[offer.id] and Store.Get().cashCents==cash+offer.feeCents)
    passed(string.format("%s 本地订单真实派发/Accept/Pickup/Actor.Move实走%.2fm %d帧/Deliver/持久化幂等；dt=.1、1.8m/s，非Actor.Update动力测试",d.id,meters,frames))

    -- 真实 Session 入口回归：带单在外区补给，不应被配送分支无条件截断。
    assert(Store.Transaction(function(p) p.battery=20; p.hunger=20; p.time=8; return true end))
    local nextOffer=assert(Delivery.GetOffer())
    assert(Delivery.Accept(nextOffer.id))
    local pickup=assert(Config.points[nextOffer.pickupId])
    a:Teleport(pickup.x,pickup.z,0)
    assert(Delivery.Pickup(nextOffer.id,a.x,a.z,{riding=false,speed=0}))
    local charge=assert(Config.points["world_"..d.id.."_charge"])
    a:Teleport(charge.x,charge.z,0)
    local beforeCash,beforeTime=Store.Get().cashCents,Store.Get().activeOrders[1].remainingHours
    session:Interact()
    assert(Store.Get().battery==100 and Store.Get().cashCents==beforeCash-200,"带单外区现场充电入口被截断")
    near(Store.Get().activeOrders[1].remainingHours,beforeTime-.5,.001,"充电没有消耗订单时间")
    a:Teleport(from.x,from.z,0)
    beforeCash,beforeTime=Store.Get().cashCents,Store.Get().activeOrders[1].remainingHours
    session:Interact()
    assert(Store.Get().hunger>20 and Store.Get().cashCents==beforeCash-1200,"带单外区用餐入口被截断")
    near(Store.Get().activeOrders[1].remainingHours,beforeTime-.25,.001,"用餐没有消耗订单时间")
    local rest=assert(Config.points["world_"..d.id.."_rest"])
    a:Teleport(rest.x,rest.z,0)
    local beforeDay=Store.Get().day
    session:Interact()
    assert(Store.Get().day==beforeDay and Delivery.GetActive(),"带单不应允许过夜清除时限")
    passed("外区带单 Session.Interact 充电/用餐及订单扣时真实接线，休息仍拒绝过夜")
end

local function bridgeTrip(session,d)
    local a,city=assert(session.actor),assert(session.city)
    local bridge=assert(World.Bridges[1])
    for _,b in ipairs(World.Bridges) do if b.id==d.id.."_bridge" then bridge=b end end
    assert(bridge.id==d.id.."_bridge","选区缺少桥")
    -- 俯视：左坡 x=-20,z=-65 -> z=0 | 桥面 x=-20..20 | 右坡 z=0 -> -65。
    -- 侧视：地面0.085 -> 坡顶6.085 -> 桥面 -> 地面；路面与桥面XZ重叠。
    -- 覆盖桥下不吸附、半径0.32入口、车辆1.2禁入、桥侧不能跌落、桥上读档高度。
    near(city:WalkSurface(bridge.x,bridge.z,0),city:Surface(bridge.x,bridge.z),.001,"桥下地面误上桥")
    assert(city:StaticFree(bridge.x,bridge.z,WALK_RADIUS,"walk",0),"桥下道路不应变成隐形墙")
    assert(not city:StaticFree(bridge.x-20,bridge.z-32,1.2,"vehicle",0),"车辆不能进入桥坡")
    local vx,vz=city:Move(bridge.x-20,bridge.z-66,0,40,1.2,"vehicle",0)
    assert(vz<bridge.z-63 and math.abs(vx-(bridge.x-20))<.001,"车辆扫掠穿入桥坡")
    a.mounted=false; a.visuals:SetMounted(false)
    a:Teleport(bridge.x-20,bridge.z-65,0)
    local peak=0
    local frames,meters=walkPath(a,{{x=a.x,z=a.z},{x=bridge.x-20,z=bridge.z},
        {x=bridge.x,z=bridge.z}},function() peak=math.max(peak,a.walkHeight) end)
    near(peak,bridge.y,.001,"Actor未沿坡真正走上桥")
    near(a.walkHeight,bridge.y,.001); near(a:GetPosition().y,bridge.y,.001)
    assert(not a:ToggleMount(),"桥上不能远程上车")
    assert(not city:StaticFree(bridge.x,bridge.z+1.9,WALK_RADIUS,"walk",bridge.y),"桥侧栏杆应阻挡人物")
    assert(Store.SetPosition(session:PositionSnapshot()) and Store.Save() and Store.Load())
    near(assert(Store.Get().position.groundHeight),bridge.y,.001)
    a:Teleport(bridge.x,bridge.z,0,0)
    near(a.walkHeight,city:Surface(bridge.x,bridge.z),.001)
    session:RestorePosition()
    near(a.x,bridge.x); near(a.z,bridge.z); near(a.walkHeight,bridge.y,.001)
    near(a.node.position.y,bridge.y,.001,"桥上恢复相机目标高度丢失")
    local downFrames,downMeters=walkPath(a,{{x=a.x,z=a.z},{x=bridge.x+20,z=bridge.z},
        {x=bridge.x+20,z=bridge.z-65}})
    assert(a.walkHeight<.2,"Actor沿右坡下桥未回地面")
    passed(string.format("%s 桥下不吸附/车辆坡道扫掠拒绝/Actor.Move上坡跨桥下坡%.2fm %d帧/桥上存档恢复height与NodeY/侧栏杆",d.id,meters+downMeters,frames+downFrames))
end

-- 逐区调用真实报价入口，不注入活动订单，不触碰现场人物或云档。
function Checks.Coverage(session)
    isolated(session)
    local files={}
    Store.WithTestStorage({read=function(path) return files[path],nil,files[path]==nil end,
        write=function(path,text) files[path]=text;return true end,
        cloud={Get=function() error("覆盖验收禁止云读取") end,Set=function() error("覆盖验收禁止云写入") end}},function()
        assert(Store.NewCareer())
        for _,district in ipairs(World.Districts) do
            for sequence=2,3 do
                assert(Store.Transaction(function(p)
                    p.flags.tutorialCompleted=true;p.phase="working";p.time=8;p.nextOrderSequence=sequence
                    p.position.x=district.x;p.position.z=district.z;p.position.space="city"
                    return true
                end))
                local offer=assert(Delivery.GetOffer(),"远区没有真实报价："..district.id)
                local pickup=assert(Config.points[offer.pickupId])
                assert(World.District(pickup.x,pickup.z).id==district.id,"远区误派老街单")
                local cross=assert(Config.GetTemplate("world_"..district.id.."_cross"))
                local eligible=cross.timeLimitHours<=16
                local expected=sequence==3 and eligible and cross.id or "world_"..district.id.."_local"
                assert(offer.templateId==expected,"当地报价未遵守位置/当天可完成时限过滤："..district.id.."/"..offer.templateId)
                assert(session.city:StaticFree(pickup.x,pickup.z,.32,"walk",0),"真实取餐门口被挡")
            end
            local cross=assert(Config.GetTemplate("world_"..district.id.."_cross"))
            passed(string.format("%s 当地报价可派发；跨区时限%.2f游戏小时，08点%s",district.id,cross.timeLimitHours,
                cross.timeLimitHours<=16 and "可派发" or "按当天可完成规则过滤"))
        end
    end)
end

-- 独立纯逻辑专项，无Session/Store读写、无引擎节点；主会话可单独调用，不触发世界长测。
function Checks.NavigationPlan()
    local function templates()
        local values={}
        assert(#Config.orderTemplates==31,"订单模板数改变")
        for _,t in ipairs(Config.orderTemplates) do
            values[#values+1]=t.id..":"..tostring(t.timeLimitHours)..":"..tostring(t.tutorial)
            local meters=Config.RouteDistance(t.route)
            values[#values+1]=string.format("%.9f:%d",meters,Config.FeeCents(meters))
            for _,p in ipairs(t.route) do values[#values+1]=string.format("%.9f:%.9f",p.x,p.z) end
        end
        return table.concat(values,"|")
    end
    local before=templates()
    local bridge=assert(World.Bridges[1])
    local layer="bridge:"..bridge.id
    assert(World.NavigationLayer(bridge.x,bridge.z,bridge.y)==layer)
    assert(World.NavigationLayer(bridge.x,bridge.z,0)=="ground","桥下同XZ不能吸附桥层")
    assert(World.NavigationLayer(bridge.x,bridge.z,bridge.y,"vehicle")=="ground")
    assert(World.NavigationLayer(-450,-450,4)=="ground","海岸4m地面不是桥层")
    local ground=assert(World.Route(bridge.x,bridge.z,bridge.x,bridge.z-80))
    local compatible=assert(World.NavigationRoute(bridge.x,bridge.z,bridge.x,bridge.z-80))
    assert(#ground==#compatible,"省略height必须保持旧接口路线")
    for i,p in ipairs(ground) do near(p.x,compatible[i].x);near(p.z,compatible[i].z) end
    local cases={{0,0,bridge.y},{-20,-32,.085+32/62*6},{20,-32,.085+32/62*6},
        {-20,-63,.085+1/62*6},{-20,-64,.085},{19,-12,.085+52/62*6}}
    for _,start in ipairs(cases) do for _,side in ipairs({-1,1}) do
        local x,z=bridge.x+start[1],bridge.z+start[2]
        local tx,tz=bridge.x+side*64,bridge.z-74.6
        local route=assert(World.NavigationRoute(x,z,tx,tz,start[3]))
        near(route[1].x,x);near(route[1].z,z);near(route[1].y,start[3])
        assert(route[1].layer==layer,"坡上低于.65m起点也应认实际坡层")
        local height=start[3]
        local changed=false
        for i=2,#route do
            local a,b=route[i-1],route[i]
            if a.layer~=b.layer then
                assert(not changed and a.layer==layer and b.layer=="ground","非法换层")
                near(a.z,bridge.z-64);near(b.z,bridge.z-66)
                near(math.abs(a.x-bridge.x),20);near(a.x,b.x)
                changed=true
            end
            -- 仅逐0.1m复核有限桥层与坡脚；远端地面段用精确扫掠，避免长路线帧遍历。
            if a.layer==layer then
                local n=math.max(1,math.ceil(math.sqrt((a.x-b.x)^2+(a.z-b.z)^2)/.1))
                for step=1,n do
                    local px,pz=a.x+(b.x-a.x)*step/n,a.z+(b.z-a.z)*step/n
                    assert(World.IsFree(px,pz,.32,"walk",height),"导航桥段偏离实际支撑/碰撞")
                    local nextHeight=World.Surface(px,pz,"walk",height)
                    assert(math.abs(nextHeight-height)<=.1,"导航高度突降或隔层吸附")
                    height=nextHeight
                end
                near(height,b.y,.001)
            else assert(World.SegmentFree(a,b,.32),"导航地面段穿入坡道/实体") end
        end
        assert(changed,"桥上导航未通过坡脚换层")
        near(route[#route].x,tx);near(route[#route].z,tz)
    end end
    assert(not World.NavigationRoute(bridge.x,bridge.z,bridge.x,bridge.z-80,bridge.y+2),"不支持的悬空高度应拒绝")
    assert(not World.NavigationRoute(bridge.x,bridge.z,bridge.x,bridge.z-80,0,layer),"错误层和高度不得静默降层")
    assert(before==templates(),"动态导航修改31单固定路线/时限/报价")
    passed("独立桥层导航：同XZ分层、坡中/低坡/桥顶双侧下桥、0.1m真实支撑、31模板报价签名不变；未访问Store")
    return true
end

function Checks.Run(session)
    isolated(session)
    Checks.NavigationPlan()
    local started=os.clock()
    local a,city=assert(session.actor),assert(session.city)
    local traffic=assert(session.traffic)
    local previous={active=traffic.active,online=session.online,yaw=session.yaw,pitch=session.pitch,
        waypoint=session.waypoint,cityX=session.cityX,cityZ=session.cityZ,cityYaw=session.cityYaw}
    local files={}
    traffic.active=false; session.online=false
    local ok,message=pcall(function()
        Store.WithTestStorage({read=function(path) return files[path],nil,files[path]==nil end,
            write=function(path,text) files[path]=text; return true end},function()
            assert(Store.NewCareer())
            session:ApplySpace("city")
            logicalWorld(city)
            legacyQuotes()
            local far=districtById("east_tech")
            farSave(session,far)
            localDelivery(session,far)
            local nearDistrict=districtById("east_market")
            -- 两外区+老城各仅一次完整加载，重复Ensure验证幂等而非重复建550m城市。
            Checks.Stream(session,far,nearDistrict)
        end)
    end)
    -- WithTestStorage 已先恢复调用方档案，再用生产恢复入口还原人物/停车/空间。
    -- 即使断言失败，也不可让后续tests吃到外区fixture或嵌套内存档。
    local restored,restoreError=pcall(function()
        session:RestorePosition()
        session.online=previous.online
        session.waypoint=previous.waypoint
        session.cityX,session.cityZ,session.cityYaw=previous.cityX,previous.cityZ,previous.cityYaw
        session.yaw,session.pitch=previous.yaw,previous.pitch
        session.view:ClosePhone(); session.view:ShowGame(); session.view:ResetInput()
        session:UpdateEnvironment(Store.Get().time); session:Refresh()
        a.speed,a.steer=0,0; a:SyncVisuals(0)
    end)
    traffic.active=previous.active
    if not ok then error(message) end
    assert(restored,restoreError)
    passed(string.format("隔离内存档及Session人物/停车/space/交通恢复；本机验收CPU %.3fs（非手机性能结论）",os.clock()-started))
    return true
end

-- Stream.Stats 接口由 WorldStream 作者提供；不以 Lua GC 内存代替真实节点计数。
function Checks.Stream(session,far,nearDistrict)
    local city=assert(session.city)
    local stream=city.stream
    local function settle(x,z)
        -- 最多80块；逐Update卸旧块，随后Ensure只为当前一个选区补齐首屏。
        for _=1,80 do stream:Update(x,z) end
    end
    local function sample(d)
        settle(d.x,d.z)
        stream:Ensure(d.x,d.z,550)
        local first=stream:Stats()
        local nodes,sceneNodes=stream.root:GetNumChildren(true),session.scene:GetNumChildren(true)
        assert(first.failed==0 and first.pending==0,"流式块构建失败或预热未完成")
        assert(first.active==first.cells and first.cells>0 and first.cells<=first.maxActive,"真实加载cell数量失控")
        assert(first.loaded-first.unloaded==first.active,"流式加载/卸载计数不平衡")
        assert(stream.root:GetNumChildren(false)==first.cells,"流式块根节点与Stats数量不一致")
        assert(first.batches>0 and first.triangles>0,"未生成真实流式几何")
        -- 32m候选格的四角/负坐标仍覆盖实时550m圆，缓存不得漏掉边缘块。
        local gridX,gridZ=math.floor(d.x/32)*32,math.floor(d.z/32)*32
        for _,offset in ipairs({{.01,.01},{31.99,.01},{.01,31.99},{31.99,31.99}}) do
            local px,pz=gridX+offset[1],gridZ+offset[2]
            local found={}
            for _,c in ipairs(stream:Candidates(px,pz)) do found[c.ix..":"..c.iz]=true end
            for ix=math.floor((px-550)/256),math.floor((px+550)/256) do
                for iz=math.floor((pz-550)/256),math.floor((pz+550)/256) do
                    local dx=math.max(ix*256-px,0,px-(ix+1)*256)
                    local dz=math.max(iz*256-pz,0,pz-(iz+1)*256)
                    if dx*dx+dz*dz<=550^2 then
                        assert(found[ix..":"..iz],"候选缓存遗漏550m边缘块")
                    end
                end
            end
        end
        first=stream:Stats()
        -- 同一位置重复Ensure/Update必须不增长，避免为测试重复建两轮城市。
        local planBuilds=first.planBuilds
        stream:Ensure(d.x,d.z,550)
        for _=1,300 do stream:Update(d.x,d.z) end
        local second=stream:Stats()
        assert(second.planBuilds==planBuilds,"静止300帧不应重复分配排序流式候选表")
        for _,field in ipairs({"cells","active","batches","triangles","buildings","models","obstacles","signs","trees","loaded","unloaded"}) do
            assert(type(first[field])=="number","WorldStream.Stats 缺少 "..field)
            near(first[field],second[field],.5,"重复预热Stats增长："..field)
        end
        near(nodes,stream.root:GetNumChildren(true),.5,"重复预热流式Nodes增长")
        near(sceneNodes,session.scene:GetNumChildren(true),.5,"重复预热场景Nodes增长")
        passed(string.format("%s Ensure550/重复预热 Nodes=%d cells=%d batches=%d triangles=%d 稳定",d.id,nodes,
            second.cells,second.batches,second.triangles))
    end
    local function probe(d)
        local ix,iz=math.floor(d.x/World.CELL),math.floor(d.z/World.CELL)
        local cell=World.DescribeCell(ix,iz)
        local wall=assert(cell.obstacles[1],"fixture区无实际障碍")
        return {ix=ix,iz=iz,signature=signature(cell),x=(wall.x1+wall.x2)/2,z=(wall.z1+wall.z2)/2,
            gate=assert(World.points["world_"..d.id.."_kitchen"])}
    end
    local probes={probe(far),probe(nearDistrict)}
    sample(far)
    local beforeUnload=stream:Stats().unloaded
    sample(nearDistrict)
    assert(stream:Stats().unloaded>beforeUnload,"远区切换没有释放旧块")
    bridgeTrip(session,nearDistrict)
    sample({id="old_town",x=0,z=-20})
    -- 老街实体/报价/碰撞从未被流式层覆盖或追加。
    assert(city:StaticFree(-25,-8,WALK_RADIUS) and city:GetMarker("breakfast"))
    assert(not city:StaticFree(-25,-22,WALK_RADIUS),"老街早餐店实体碰撞丢失")
    for _,p in ipairs(probes) do
        assert(signature(World.DescribeCell(p.ix,p.iz))==p.signature,"卸载重生成改变逻辑描述")
        assert(not World.IsFree(p.x,p.z,WALK_RADIUS) and not city:StaticFree(p.x,p.z,WALK_RADIUS))
        session:ApplySpace("hostel"); session:ApplySpace("city")
        assert(signature(World.DescribeCell(p.ix,p.iz))==p.signature,"空间切换改变逻辑描述")
        assert(not city:StaticFree(p.x,p.z,WALK_RADIUS),"卸载/空间切换后建筑碰撞消失")
        assert(city:StaticFree(p.gate.x,p.gate.z,WALK_RADIUS)==World.IsFree(p.gate.x,p.gate.z,WALK_RADIUS))
    end
    assert(World.CacheStats().cells<=World.CacheStats().limit,"描述LRU缓存无界增长")
    passed("两外区逐Update卸载/老城回归/室内外切换，DescribeCell签名与门前/建筑碰撞同源，LRU有界")
end

function Checks.Shot(session,id)
    isolated(session)
    local requested=false
    for _,arg in ipairs(GetArguments()) do
        if arg=="-careerworld="..id or arg=="-careerworldshot="..id then requested=true end
    end
    assert(requested,"世界实拍必须显式传-careerworld或-careerworldshot=<districtId>，不能从真实玩家会话调用")
    local d=districtById(id)
    local a,city=assert(session.actor),assert(session.city)
    -- 只改 Session 已持有的隔离档；不改真实玩家Profile，不伪造场景或离屏绘图。
    assert(Store.Transaction(function(p) p.phase="working"; p.time=12; p.activeOrders={}; return true end))
    session:ApplySpace("city"); session.online=false; session.waypoint=""
    session.traffic.active=false
    city.stream:Ensure(d.x,d.z,550)
    for _=1,32 do city.stream:Update(d.x,d.z) end
    a.mounted=false; a.visuals:SetMounted(false)
    a.bikeX,a.bikeZ,a.bikeYaw=d.x-4,d.z-18,0
    a:Teleport(d.x,d.z-18,0); a.speed,a.steer=0,0; a:SyncVisuals(0)
    session:UpdateEnvironment(12)
    session.view:ClosePhone(); session.view:ShowGame(); session.view:ResetInput()
    session.yaw,session.pitch=25,14
    session.camera:SetModeConfig("normal",{distance=11,offset=Vector3(0,1.5,0),fov=62})
    session.camera:SetMode("normal")
    session.camera:Update(2,a.node,session.yaw,session.pitch)
    session:Refresh()
    local view="street"
    for _,arg in ipairs(GetArguments()) do
        local selected=arg:match("^%-careerworldview=(.+)$")
        if selected then view=selected end
    end
    if view=="bridge" then
        local b=assert(World.Bridges[1])
        for _,item in ipairs(World.Bridges) do if item.id==d.id.."_bridge" then b=item end end
        a:Teleport(b.x,b.z,0,b.y); a:SyncVisuals(0)
        session.yaw,session.pitch=120,18
        session.camera:SetModeConfig("normal",{distance=8,offset=Vector3(0,1.2,0),fov=62})
        session.camera:Update(2,a.node,session.yaw,session.pitch)
        session:Refresh()
    elseif view=="traffic" then
        session.traffic.active=true
        for _=1,300 do session.traffic:Update(.1) end
        local stats=session.traffic.outer:Stats()
        assert(stats.cars>0 and stats.people>0,"交通实拍必须有真实生成的车与行人")
        session.traffic.active=false
        session.yaw,session.pitch=180,18
        session.camera:SetModeConfig("normal",{distance=15,offset=Vector3(0,1.5,0),fov=65})
        session.camera:Update(2,a.node,session.yaw,session.pitch)
        passed(string.format("外区交通实拍%d车/%d人，真实Update生成后冻结",stats.cars,stats.people))
    elseif view=="signal_red" or view=="signal_green" then
        local Signals=require("Career.OuterSignals")
        local junction=assert(Signals.Find(d.x,d.z),"信号实拍必须位于受控中心")
        local seconds=((view=="signal_green" and 5 or 24)-junction.offset)%Signals.CYCLE
        local signals=session.traffic.outer.signals --[[@as OuterSignalSystem]]
        signals:Update(seconds,d.x,d.z,true)
        a:Teleport(d.x+3,d.z-29,0); a:SyncVisuals(0)
        session.yaw,session.pitch=0,12
        session.camera:SetModeConfig("normal",{distance=12,offset=Vector3(0,1.5,0),fov=62})
        session.camera:Update(2,a.node,session.yaw,session.pitch)
        session:Refresh()
        passed("实体信号受控实拍 "..view.." / 南北"..Signals.Signal(seconds,"ns",junction)
            .." / 东西"..Signals.Signal(seconds,"ew",junction).." / 非墙钟猜帧")
    elseif view=="map" or view=="messages" or view=="progression" then
        session:OpenPhone(view)
        if view=="map" then
            for _,arg in ipairs(GetArguments()) do
                local region=arg:match("^%-careerworldmap=(.+)$")
                if region then
                    session.view.mapDistrictId=region
                    session.view.mapPickerOpen=region=="picker"
                    session:RefreshPhone()
                end
            end
        end
    elseif view~="street" then error("未知实拍视图："..view) end
    if view~="map" and view~="messages" and view~="progression" then session.view.overlay:SetVisible(false) end
    passed(string.format("实拍就绪 %s / %s / 人物(%.1f,%.1f)停稳 / Ensure550 / 正午 / 真实街区，仅隔离Session",id,view,a.x,a.z))
end
return Checks
