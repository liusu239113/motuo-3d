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
        assert(Store.Eat())
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
        assert(not Store.Get().flags.professional and Store.Get().career.pending.training)
        assert(not Progress.EnterSeries(1) and not Progress.CompleteTraining(false))
        assert(Progress.CompleteTraining(true) and Store.Get().flags.professional)
        assert(not Progress.CompleteTraining(true) and not Progress.Train())
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
        assert(not Progress.SelectMotorcycle("rally"))
        assert(Progress.SelectMotorcycle("sport") and Store.Get().raceVehicle=="sport")
        local firstStory=assert(Progress.NextStory(Store.Get()))
        assert(Progress.MarkStory(firstStory.id))
        assert(Progress.NextStory(Store.Get()).id~=firstStory.id)
        assert(Profile.Coins()==oldCoins,"生涯不得改变旧竞速金币")
        print("[生涯成长验收通过] 10单升级/双单与四单倒序独立结算/按晚住宿/代表班次防连点/5万元首购/训练/六站职业/未完赛零奖励/结算回滚与幂等/终章/旧金币隔离")
    end)
end
function Checks.RunCloudTimeout()
    local files={}
    local calls={}
    local stub={Set=function(_,key,value,events) calls.save=events; calls.snapshot=value end,
        Get=function(_,key,events) calls.load=events end}
    Store.WithTestStorage({read=function(path) return files[path],nil,files[path]==nil end,
        write=function(path,text) files[path]=text; return true end,cloud=stub},function()
        assert(Store.NewCareer())
        local callbacks=0
        assert(Store.SaveCloud(function(ok) assert(not ok); callbacks=callbacks+1 end))
        assert(not Store.Pay(1,"test"))
        Store.UpdateCloud(21)
        assert(callbacks==1 and Store.GetSaveStatus().cloud=="unconfirmed")
        assert(Store.Pay(1,"test"))
        calls.save.ok()
        assert(callbacks==1 and Store.Get().cashCents==4999 and Store.GetSaveStatus().cloud=="unconfirmed")
        assert(Store.LoadCloud(function(ok) assert(not ok); callbacks=callbacks+1 end))
        Store.UpdateCloud(21)
        assert(Store.Pay(1,"test"))
        calls.load.ok({[Config.CLOUD_KEY]=calls.snapshot})
        assert(callbacks==2 and Store.Get().cashCents==4998)
        print("[云回调保护验收通过] 保存/读取超时解锁，迟到回包不确认旧版本、不覆盖新进度（回调桩测试）")
    end)
end
function Checks.PrepareRace()
    assert(Store.NewCareer())
    grant(5000000,"test:race-capital")
    assert(Progress.BuyMotorcycle("sport"))
    assert(Progress.Train())
    assert(Progress.CompleteTraining(true))
    assert(Progress.EnterSeries(1))
    return Store.Get().career.pending
end
-- 对已载入的真实赛道使用连续合法过线步长，不直接设置finished或赠送结果。
function Checks.DriveRace(race,sim)
    assert(race.laps==2 and race.options.professional and #race.traffic==0)
    for _=1,151 do
        race:BeforeStep(.02,{})
        race:AfterStep(.02)
    end
    local s=race.player.s
    for _=1,math.ceil((race.length*2+80)/1.2) do
        if race.phase=="finished" then break end
        race:BeforeStep(.02,{})
        local pose,yaw=race:Pose(s+1.2,1.55)
        s=s+1.2
        sim.x,sim.y,sim.z,sim.yaw,sim.heading,sim.speed=pose.x,pose.y,pose.z,yaw,yaw,60
        race:AfterStep(.02)
    end
    assert(race.player.finished and race.player.completedLaps==2 and not race.pursuit.active)
    print("[生涯赛道验收] 真实赛道两圈顺序检查点完赛，关闭追逐和交通")
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
function Checks.RunDeliveryTrip(session)
    local files={}
    local actor=assert(session.actor)
    Store.WithTestStorage({read=function(path) return files[path],nil,files[path]==nil end,
        write=function(path,text) files[path]=text; return true end},function()
        assert(Store.NewCareer())
        actor.mounted=false; actor.visuals:SetMounted(false); actor:Teleport(0,-20,0)
        session.online=true
        session:Accept()
        local order=assert(Delivery.GetActive())
        local function walkTo(x,z)
            for _=1,1800 do
                local dx,dz=x-actor.x,z-actor.z
                if dx*dx+dz*dz<.04 then
                    actor:Update(.1,{walkX=0,walkY=0},0)
                    return
                end
                local length=math.sqrt(dx*dx+dz*dz)
                actor:Update(.1,{walkX=dx/length,walkY=dz/length},0)
                assert(Delivery.Update(.1,0))
            end
            error("实际步行路线被阻挡")
        end
        local pickup=Config.points[order.pickupId]
        walkTo(pickup.x,pickup.z)
        session:Interact()
        assert(Delivery.GetActive().status=="picked_up")
        for index=2,#order.route do walkTo(order.route[index].x,order.route[index].z) end
        session:Interact()
        assert(not Delivery.GetActive() and Store.Get().cashCents==5500)
        assert(Store.Save() and Store.Load() and Store.Get().completedOrders==1)
        print("[首单实走验收通过] 实际步行动力到早餐店/生产交互取餐/沿街171米/门厅交付/到账与读档，无中途瞬移")
    end)
    session.online=false
    session:RestorePosition()
    session.view:ShowGame(); session:Refresh()
end
-- 通过UI真实分发触摸事件，不直接调用控件回调；全过程沿用Session的隔离档。
function Checks.RunMobile(session)
    local UI=require("urhox-libs/UI")
    local PointerEvent=require("urhox-libs/UI/Core/PointerEvent")
    local Settings=require("ControlSettings")
    local view,actor=session.view,assert(session.actor)
    local c=view.controls
    view:ClosePhone(); view:ShowGame()
    actor.mounted=false; actor.visuals:SetMounted(false)
    actor.bikeX,actor.bikeZ,actor.bikeYaw=1.5,-20,0
    actor:Teleport(0,-20,0)
    session:Refresh(); UI.Layout(); view:LayoutControls(); UI.Layout()
    assert(c.scheme==Settings.Current(),"生涯必须读取赛车的当前操作方案")
    assert(not c.widgets.nitro and not c.widgets.wheelie,"配送不应堆放赛车特技按钮")
    local function send(kind,id,x,y)
        local scale=UI.GetScale()
        local e=PointerEvent.new(kind,{pointerId=id,pointerType="touch",isPrimary=id==760001,
            x=x*scale,y=y*scale,button=PointerEvent.Button.Left})
        UI.HandlePointerEvent(e)
        return e
    end
    local function down(widget,id,fx)
        local r=widget:GetAbsoluteLayout()
        local x,y=r.x+r.w*(fx or .5),r.y+r.h*.5
        assert(send("PointerDown",id,x,y).target==widget,"触屏未命中实际组件："..tostring(widget.props.id))
        return x,y
    end
    local function up(id,x,y) send("PointerUp",id,x,y) end
    local stick=view.walkStick.root
    local sx,sy=down(stick,760001,.5)
    send("PointerMove",760001,sx+35,sy-35)
    assert(view.walkStick.x>.2 and view.walkStick.y>.2,"二维摇杆必须支持斜向移动")
    local x0,z0=actor.x,actor.z
    actor:Update(.2,view:GetInput(),0)
    assert(actor.x>x0 and actor.z>z0,"摇杆未驱动实际人物斜向行走")
    local lookX,lookY=down(view.lookArea,760005,.6)
    send("PointerMove",760005,lookX+12,lookY+6)
    assert(view.walkStick.x>.2,"右手转视角不能抢走左手摇杆")
    up(760005,lookX+12,lookY+6); view:ConsumeLook()
    up(760001,sx+35,sy-35)
    actor:Update(.1,view:GetInput(),0)
    assert(actor.speed==0 and view.walkStick.x==0 and view.walkStick.y==0,"松摇杆必须停步")
    actor:Teleport(0,-20,0); session:Refresh()
    local mx,my=down(view.mountButton,760003); up(760003,mx,my)
    assert(actor.mounted and view.mountedControls,"点击上车必须同步切换赛车踏板语义")
    UI.Layout(); view:LayoutControls(); UI.Layout()
    local gx,gy=down(c.widgets.gas,760002)
    sx,sy=down(c.widgets.steering,760001,.9)
    assert(c.gas and c.steer>.5,"骑行转向与油门支持多指")
    up(760001,sx,sy)
    for _=1,30 do actor:Update(.05,view:GetInput(),0) end
    up(760002,gx,gy)
    assert(actor.speed>1 and actor.speed<=35/3.6,"复用油门必须驱动电动车而非赛车极速")
    local bx,by=down(c.widgets.brake,760004)
    for _=1,60 do actor:Update(.05,view:GetInput(),0) end
    assert(actor.speed<0 and actor.speed>=-1.6,"持续刹车必须停稳后低速倒车")
    up(760004,bx,by)
    for _=1,40 do actor:Update(.05,view:GetInput(),0) end
    assert(actor.speed==0,"松开倒车后必须停稳")
    mx,my=down(view.mountButton,760003); up(760003,mx,my)
    assert(not actor.mounted and not view.mountedControls)
    UI.Layout(); view:LayoutControls(); UI.Layout()
    local parkedX,parkedZ=actor.bikeX,actor.bikeZ
    sx,sy=down(stick,760001)
    send("PointerMove",760001,sx,sy+45)
    actor:Update(.2,view:GetInput(),0)
    assert(actor.speed>0 and actor.bikeX==parkedX and actor.bikeZ==parkedZ,"摇杆后移不能移动停车")
    up(760001,sx,sy+45)
    actor:Update(.1,view:GetInput(),0)
    local phone=assert(view.root:FindById("career-phone"))
    local px,py=down(phone,760003); up(760003,px,py)
    assert(view.phonePage=="apps" and not c.enabled and view.walkStick.y==0,"手机必须清空摇杆")
    up(760001,sx,sy); view:ClosePhone()
    assert(c.enabled and not c.gas,"关手机不能恢复旧油门")
    local lx,ly=down(view.lookArea,760005,.5)
    send("PointerMove",760005,lx+24,ly+12)
    local dx,dy=view:ConsumeLook()
    assert(math.abs(dx-24)<.01 and math.abs(dy-12)<.01,
        string.format("空白画面拖动必须驱动触屏视角，实际增量%.6f/%.6f",dx,dy))
    send("PointerCancel",760005,lx+24,ly+12)
    assert(view.lookPointer==-1)
    sx,sy=down(stick,760001)
    send("PointerMove",760001,sx-35,sy)
    send("PointerCancel",760001,sx-35,sy)
    assert(view.walkStick.x==0 and view.walkStick.pointer==-1,"取消触摸不能留下卡摇杆")
    session:Pause(); assert(not c.enabled and not c.gas)
    view:ShowGame(); session:RestorePosition(); session:Refresh()
    print("[生涯触屏验收通过] 复用赛车组件与操作方案/真实UI多指/步行转向前进后退/上下车/油门刹车/手机暂停清输入/拖屏视角/取消触摸")
end
function Checks.RunWorld(session)
    Checks.RunLogic()
    Checks.RunProgression()
    Checks.RunCloudTimeout()
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
    -- 世界测试不假定玩家存档是步行态；使用固定空旷测试点，结束后恢复原停车位置。
    actor.mounted=false; actor.visuals:SetMounted(false)
    actor.bikeX,actor.bikeZ,actor.bikeYaw=1.5,-20,0
    actor:Teleport(0,-20,0)
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
    Checks.RunMobile(session)
    require("Career.HousingChecks").Run(session)
    for _,arg in ipairs(GetArguments()) do
        if arg=="-careertripchecks" then Checks.RunDeliveryTrip(session) end
        if arg=="-careerpose=ride" then
            if not actor.mounted then assert(actor:ToggleMount()) end
            session:Refresh()
            actor:SyncVisuals(1)
            local pose=actor.visuals.mountedRider:ReadPose()
            print(string.format("[生涯握把验收] 左%.4fm 右%.4fm Hip=%s Head=%s",pose.leftGripError,pose.rightGripError,pose.hip:ToString(),pose.head:ToString()))
            assert(pose.leftGripError<.005 and pose.rightGripError<.005,"双手必须实际到握把，不靠超伸夹取")
            session.yaw,session.pitch=90,8
            for _,option in ipairs(GetArguments()) do
                local angle=option:match("^%-careerangle=([%-%.%d]+)$")
                if angle then session.yaw=tonumber(angle) or 90 end
            end
            session.camera:SetModeConfig("normal",{distance=3.1,offset=Vector3(0,1.0,0),fov=48})
            session.camera:SetModeConfig("ride",{distance=3.1,offset=Vector3(0,1.0,0),fov=48})
            session.camera:Update(1,actor.node,session.yaw,session.pitch)
            session.view:ShowDialog("骑姿实拍","侧面检查手、坐垫、脚踏与配送箱",{})
            session.view.overlay:SetVisible(false)
        end
        if arg=="-careernight" then require("Career.HousingChecks").NightShot(session) end
        local home=arg:match("^%-careerhousing=(.+)$")
        if home then require("Career.HousingChecks").Shot(session,home) end
        local page=arg:match("^%-careerpage=(.+)$")
        if page then
            if page=="delivery" then session.online=true end
            session:OpenPhone(page)
        end
    end
    print("[生涯城市验收通过] 全部交互点/路线可达/实际骑行动力/上下车/独立停车/手机暂停")
end
return Checks
