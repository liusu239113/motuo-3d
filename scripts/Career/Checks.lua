-- 验收只在显式-careerchecks运行，内存存储注入隔离真实玩家生涯。
local Store=require("Career.Store")
local Delivery=require("Career.Delivery")
local Config=require("Career.Config")
local Checks={}
function Checks.RunLogic()
    local files={}
    local failWrite=false
    Store.WithTestStorage({
        read=function(path) return files[path],nil,files[path]==nil end,
        write=function(path,text) if failWrite then return false,"模拟磁盘失败" end; files[path]=text; return true end,
    },function()
        assert(Store.NewCareer())
        local p=Store.Get()
        assert(p.cashCents==5000 and not next(p.ownedMotorcycles) and p.vehicle.borrowed)
        local offer=assert(Delivery.GetOffer())
        assert(offer.feeCents==500 and offer.distanceMeters==171)
        assert(Delivery.Accept(offer.id))
        assert(not Delivery.Accept(offer.id))
        assert(not Delivery.Deliver(offer.id,-108,80))
        assert(not Delivery.Pickup(offer.id,0,0))
        assert(not Delivery.Pickup(offer.id,-25,-8,{riding=true,speed=0}))
        assert(not Delivery.Pickup(offer.id,-25,-8,{riding=false,speed=1}))
        assert(Delivery.Pickup(offer.id,-25,-8,{riding=false,speed=0}))
        assert(not Delivery.Pickup(offer.id,-25,-8))
        assert(Store.Save()); assert(Store.Load())
        assert(Delivery.GetActive().status=="picked_up")
        assert(not Delivery.Deliver(offer.id,-100,80))
        failWrite=true
        assert(not Delivery.Deliver(offer.id,-108,80))
        assert(Store.Get().cashCents==5000 and Delivery.GetActive())
        failWrite=false
        assert(Delivery.Deliver(offer.id,-108,80))
        assert(Store.Get().cashCents==5500)
        assert(not Delivery.Deliver(offer.id,-108,80))
        assert(Store.Load()); assert(not Delivery.Deliver(offer.id,-108,80))
        assert(Store.Get().cashCents==5500)
        assert(Store.Eat()); assert(Store.Get().cashCents==4300)
        assert(Store.Rest("bridge")); assert(Store.Get().day==2)
        local before=Store.Get().cashCents
        failWrite=true; assert(not Store.Pay(100,"test")); assert(Store.Get().cashCents==before); failWrite=false
        assert(Config.FeeCents(0)==250 and Config.FeeCents(10000)==1000)
        local text=files[Config.SAVE_PATH]; files[Config.SAVE_PATH]="bad-json"
        assert(not Store.Load()); assert(files[Config.SAVE_PATH]=="bad-json")
        files[Config.SAVE_PATH]=text; assert(Store.Load())
        print("[生涯逻辑验收通过] 50元开局/借车/171m教学5元/远程与骑乘拒绝/先取后送/结算幂等/读档/磁盘失败回滚/吃饭/次日/坏档保护")
    end)
    return true
end
function Checks.RunWorld(session)
    Checks.RunLogic()
    local city=assert(session.city)
    for _,point in ipairs(Config.pointList) do
        assert(city:IsFree(point.x,point.z,.32),"门前点被建筑堵塞："..point.id)
        assert(city:GetMarker(point.id),"缺少实体marker")
    end
    for _,template in ipairs(Config.orderTemplates) do
        for i=2,#template.route do
            local a,b=template.route[i-1],template.route[i]
            local x,z=city:Move(a.x,a.z,b.x-a.x,b.z-a.z,.32)
            assert(math.abs(x-b.x)+math.abs(z-b.z)<.01,"配送路线穿楼："..template.id)
        end
    end
    local actor=assert(session.actor)
    assert(not actor.mounted)
    assert(actor:ToggleMount())
    for _=1,120 do actor:Update(1/60,{throttle=1,steer=0},0) end
    assert(actor.speed>1 and actor.speed<=35/3.6)
    for _=1,120 do actor:Update(1/60,{brake=true},0) end
    assert(actor:ToggleMount())
    local bx,bz=actor.bikeX,actor.bikeZ
    for _=1,60 do actor:Update(1/60,{walkX=1,walkY=0},0) end
    assert(actor.bikeX==bx and actor.bikeZ==bz,"步行不得召车")
    session:RestorePosition()
    session.view:ShowGame()
    session:OpenPhone("delivery")
    local time=Store.Get().time
    session:Update(.1)
    assert(Store.Get().time==time,"手机未冻结时间")
    session.view:ClosePhone()
    session:Refresh()
    print("[生涯城市验收通过] 全部交互点/路线可达/实际骑行动力/上下车/独立停车/手机暂停")
end
return Checks
