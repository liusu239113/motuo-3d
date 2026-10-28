-- 验收只在显式-careerchecks运行，内存存储注入隔离真实玩家生涯。
local Store=require("Career.Store")
local Delivery=require("Career.Delivery")
local Config=require("Career.Config")
local Progress=require("Career.Progression")
local Profile=require("Profile")
local Checks={}
-- 仅内存验收可注入启动资金，生产流程没有此入口。
local function grant(cents,key)
    assert(Store.Transaction(function(p) return Store.ApplyCash(p,cents,"test_fixture",key) end))
end
local function completeOrder()
    local offer=assert(Delivery.GetOffer())
    assert(Delivery.Accept(offer.id))
    local pickup,dropoff=Config.points[offer.pickupId],Config.points[offer.dropoffId]
    assert(Delivery.Pickup(offer.id,pickup.x,pickup.z))
    assert(Delivery.Deliver(offer.id,dropoff.x,dropoff.z))
end
function Checks.RunProgression()
    local files={}
    local failWrite=false
    local oldCoins=Profile.Coins()
    Store.WithTestStorage({read=function(path) return files[path],nil,files[path]==nil end,
        write=function(path,text) if failWrite then return false,"模拟磁盘失败" end; files[path]=text; return true end},function()
        assert(Store.NewCareer())
        assert(not Progress.BuyEquipment("insulated_box"))
        assert(not Progress.BuyMotorcycle("sport"))
        assert(not Progress.EnterSeries(1))
        for _=1,10 do completeOrder() end
        assert(Progress.Level(Store.Get())==2)
        grant(400000,"test:equipment")
        assert(Progress.BuyEquipment("insulated_box"))
        assert(not Progress.BuyEquipment("insulated_box"))
        local a=assert(Delivery.GetOffer()); assert(Delivery.Accept(a.id))
        local b=assert(Delivery.GetOffer()); assert(Delivery.Accept(b.id))
        assert(a.id~=b.id and #Store.Get().activeOrders==2 and not Delivery.Accept())
        for _,order in ipairs({b,a}) do
            local pickup,dropoff=Config.points[order.pickupId],Config.points[order.dropoffId]
            assert(Delivery.Pickup(order.id,pickup.x,pickup.z))
            assert(Delivery.Deliver(order.id,dropoff.x,dropoff.z))
        end
        assert(Store.Get().completedOrders==12 and #Store.Get().activeOrders==0)
        assert(Progress.SetHousing("hostel"))
        local cash=Store.Get().cashCents
        local ok,message=Store.Rest("hostel")
        assert(ok and Store.Get().cashCents==cash-3000 and not message:find("免费"))
        assert(not Progress.WorkWeek(),"不能新手期直接跳周")
        for _=1,8 do assert(Store.Rest("bridge")) end
        assert(not Progress.WorkWeek(),"亲送足但活动时间不足不能排班")
        assert(Store.Advance(900,0))
        local before=Store.Get()
        assert(Progress.WorkWeek())
        local after=Store.Get()
        assert(after.day==before.day+7 and after.weeksWorked==1 and after.simulatedOrders==228)
        assert(after.cashCents==before.cashCents+228*580-17600-228*30)
        assert(not Progress.WorkWeek(),"不能连续点击重复排班")
        assert(Store.Load() and Store.Get().weeksWorked==1)
        for _=1,28 do completeOrder() end
        assert(Progress.Level(Store.Get())>=3)
        assert(Progress.BuyEquipment("large_box") and Progress.Capacity(Store.Get())==4)
        ---@type CareerOrder[]
        local orders={}
        for _=1,4 do local order=assert(Delivery.GetOffer()); assert(Delivery.Accept(order.id)); orders[#orders+1]=order end
        assert(not Delivery.Accept())
        for i=4,1,-1 do
            local order=orders[i]; local from,to=Config.points[order.pickupId],Config.points[order.dropoffId]
            assert(Delivery.Pickup(order.id,from.x,from.z)); assert(Delivery.Deliver(order.id,to.x,to.z))
            assert(#Store.Get().activeOrders==i-1)
        end
        grant(4999999-Store.Get().cashCents,"test:threshold")
        assert(not Progress.BuyMotorcycle("sport"),"未到5万元不可首购")
        grant(1,"test:one-cent")
        failWrite=true; assert(not Progress.BuyMotorcycle("sport")); failWrite=false
        assert(Store.Get().cashCents==5000000 and not Store.Get().ownedMotorcycles.sport)
        assert(Progress.BuyMotorcycle("sport"))
        assert(Store.Get().cashCents==400000 and Store.Get().ownedMotorcycles.sport)
        assert(Progress.Train() and Store.Get().cashCents==200000)
        assert(not Progress.Train())
        assert(Progress.EnterSeries(1))
        assert(Store.Get().cashCents==185000 and Store.Get().career.pending.laps==2)
        assert(not Progress.EnterSeries(1))
        assert(Store.Save() and Store.Load() and Store.Get().career.pending)
        assert(not Progress.SettleRace(0,true))
        failWrite=true; assert(not Progress.SettleRace(1,true)); failWrite=false
        assert(Store.Get().career.pending and Store.Get().cashCents==185000)
        assert(Progress.SettleRace(1,true))
        assert(Store.Get().cashCents==275000 and Store.Get().career.points==3)
        assert(not Progress.SettleRace(1,true),"同一场不可重复获奖")
        assert(Progress.EnterSeries(1)); local noFinish=Store.Get().cashCents
        assert(Progress.SettleRace(9,false))
        assert(Store.Get().cashCents==noFinish and Store.Get().career.points==3)
        for index=2,6 do assert(Progress.EnterSeries(index)); assert(Progress.SettleRace(1,true)) end
        assert(Store.Get().flags.lifeWinner and Store.Get().career.wins==6)
        assert(Store.Load() and Store.Get().flags.lifeWinner)
        assert(Profile.Coins()==oldCoins,"生涯不得改变旧竞速金币")
        print("[生涯成长验收通过] 10单升级/双单与四单倒序独立结算/按晚住宿/代表班次防连点/5万元首购/训练/六站职业/未完赛零奖励/结算回滚与幂等/终章/旧金币隔离")
    end)
end
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
    Checks.RunProgression()
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
