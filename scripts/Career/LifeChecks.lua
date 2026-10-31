-- 小型隔离验收：仅本轮时间/生活HUD，不执行全城市、交通、路网回归。
local Store=require("Career.Store")
local Life=require("Career.LifeStatus")
local UI=require("urhox-libs/UI")
local Kit=require("Career.PhoneKit")
local Checks={}
---@param session CareerSession
function Checks.Run(session,shot)
    assert(session.options.test and session.restoreTestStorage,"生活验收必须内存隔离")
    if not shot or shot=="" then
        require("Career.HousingChecks").RunProperty()
        require("Career.MapOverlay").Checks()
        require("Career.TrafficChecks").Run(session)
    end
    assert(Store.NewCareer())
    assert(Store.Transaction(function(p) p.phase="working";p.flags.introSeen=true;return true end))
    local p=Store.Get()
    local basePlan=Life.Plan(p)
    assert(basePlan.reserveCents==1200 and basePlan.home.price==0,"开局计划只能预留下一餐，免费住处不虚扣")
    local sample=Store.Get()
    sample.hunger=63;sample.energy=57;sample.battery=10;sample.cashCents=1000;sample.accommodation="hostel"
    local lowPlan=Life.Plan(sample)
    assert(lowPlan.mealHours==1 and lowPlan.restHours==2,"计划按真实消耗率估算")
    assert(lowPlan.reserveCents==4400 and lowPlan.shortfallCents==3400,"下一餐+30元住宿+2元充电预算")
    local ownedSample=Store.Get()
    ownedSample.accommodation="room";ownedSample.ownedHomes={room=true}
    local ownedPlan=Life.Plan(ownedSample)
    assert(ownedPlan.nightlyCents==0 and ownedPlan.reserveCents==1200 and ownedPlan.ownedHome,"自有住房不应继续预留虚构房费")
    sample.equipment={raincoat=true}
    assert(Life.Plan(sample).restHours>lowPlan.restHours,"雨衣节省精力应反映到计划")
    sample.energy=29
    local monitor={day=0,seen={}}
    assert(Life.PollAlerts(monitor,sample).key=="energy-low","同级低状态按稳定顺序首次提醒")
    assert(not Life.PollAlerts(monitor,sample),"同级提醒不能连续刷屏")
    sample.time=sample.time+.05
    assert(Life.PollAlerts(monitor,sample).key=="power-critical","未展示的同级提醒应在冷却后展示，不能直接丢弃")
    assert(not Life.PollAlerts(monitor,sample),"已展示提醒同一天不重复")
    sample.hunger=10
    assert(Life.PollAlerts(monitor,sample).key=="hunger-critical","严重程度升级应立即提醒")
    assert(Store.Get().cashCents==p.cashCents,"计算计划和提醒不能扣款")
    local clock=p.time
    assert(Store.Advance(60,0))
    local advanced=Store.Get()
    assert(math.abs(advanced.time-clock-60*require("Career.Config").GAME_HOURS_PER_SECOND)<.000001,"活动时间推进")
    assert(advanced.energy<p.energy and advanced.hunger<p.hunger,"身体状态同步消耗")
    assert(Store.Transaction(function(d) d.hunger=29;d.energy=70;return true end))
    assert(Life.Advice(Store.Get()).point=="breakfast","饥饿提示吃饭")
    session.view:ClosePhone();session.view:ShowGame()
    session.actor.mounted=false;session.actor.speed=0;session.actor:Teleport(-25,-8,0)
    local before=Store.Get()
    session.view.actions.eat()
    local eaten=Store.Get()
    assert(eaten.cashCents==before.cashCents-1200 and eaten.hunger==84,"用餐准确扣款/恢复饱腹")
    assert(math.abs(eaten.time-before.time-.25)<.000001,"用餐15游戏分钟")
    assert(Store.Transaction(function(d) d.energy=29;return true end))
    assert(Life.Advice(Store.Get()).action=="导航休息","疲劳提示休息")
    local bridge=assert(require("Career.HousingData").Get("bridge"))
    local bridgePoint=assert(require("Career.Config").points.bridge)
    assert(bridgePoint.x==bridge.x and bridgePoint.z==bridge.z and bridge.x>12,"住房/导航必须同源且离开通车与步行道")
    assert(session.city:StaticFree(bridge.x,bridge.z,.32,"walk",0),"新休息入口不可被家具堵住")
    assert(not session.city:StaticFree(bridge.x,-73,.32,"walk",0),"路外床铺应有真实碰撞")
    assert(session.city:StaticSegmentFree(0,-78,0,-62,.32,"walk",0),"桥下原通车道被床铺截断")
    session.actor:Teleport(bridge.x,bridge.z,0)
    local day=Store.Get().day
    session.view.actions.rest("bridge")
    local rested=Store.Get()
    assert(rested.day==day+1 and rested.time==8 and rested.energy>=70,"免费过夜至次日08:00")
    session.view:ClosePhone();session.view:ShowGame()
    session:OpenPhone("life")
    local paused=Store.Get()
    local sky=assert(session.atmosphere)
    local beforeSky=assert(sky.state)
    local frozenU,frozenV=beforeSky.cloudU,beforeSky.cloudV
    local wasTest=session.options.test
    session.options.test=false
    local ok,message=pcall(function() session:Update(.1) end)
    session.options.test=wasTest
    assert(ok,message)
    local afterPause=Store.Get()
    assert(afterPause.time==paused.time and afterPause.energy==paused.energy and afterPause.hunger==paused.hunger,"手机暂停身体状态")
    assert(sky.state.cloudU==frozenU and sky.state.cloudV==frozenV,"手机冻结云层漂移，不能先重置再断言")
    local Atmosphere=require("Career.Atmosphere")
    local midnight=Atmosphere.Sample(1,24)
    local morning=Atmosphere.Sample(2,0)
    assert(midnight.cloudiness==morning.cloudiness and midnight.cloudU==morning.cloudU,"跨日天气连续")
    assert(Atmosphere.Sample(1,12).label=="晴朗" and Atmosphere.Sample(5,12).label=="阴天","天气样本可区分")
    assert(Atmosphere.Sample(5,23).cloudColor.r<Atmosphere.Sample(5,12).cloudColor.r,"阴夜云层必须压暗")
    session:ApplySpace("hostel")
    assert(not sky.root.enabled and not session.sky.enabled,"室内立即隐藏天空与云")
    session:ApplySpace("city")
    assert(sky.root.enabled and session.sky.enabled,"出门恢复天空与云")
    session.view:ClosePhone();session.view:ShowGame()
    local NightLighting=require("Career.NightLighting")
    local lamps=assert(session.nightLighting)
    local actorPosition=session.actor.node.worldPosition
    local vehiclePosition=session.actor.visuals.bikeVisual.worldPosition
    session.actor.node.worldPosition=vehiclePosition
    NightLighting.Update(lamps,session.actor,Atmosphere.Sample(1,12),false)
    assert(not lamps.head.enabled and not lamps.tail.enabled,"晴天正午不应开启车灯")
    NightLighting.Update(lamps,session.actor,Atmosphere.Sample(1,22),false)
    assert(lamps.head.enabled and lamps.tail.enabled,"夜间近车真实前后灯应开启")
    local parkedLight=lamps.headNode.worldPosition
    session.actor.node.worldPosition=vehiclePosition+Vector3(40,0,0)
    NightLighting.Update(lamps,session.actor,Atmosphere.Sample(1,22),false)
    assert(not lamps.head.enabled and not lamps.tail.enabled,"远离停车必须关闭局部照明")
    local lampDelta=lamps.headNode.worldPosition-parkedLight
    assert(lampDelta:LengthSquared()<.0001,"车灯不能跟步行人物飘走")
    session.actor.node.worldPosition=actorPosition
    NightLighting.Update(lamps,session.actor,Atmosphere.Sample(1,22),true)
    assert(not lamps.head.enabled and not lamps.tail.enabled,"室内车灯必须关闭")
    local Delivery=require("Career.Delivery")
    local offer=assert(Delivery.GetOffer())
    assert(Delivery.Accept(offer.id))
    session.actor.speed=0
    local beforeCall=Store.Get()
    local sound=assert(session.audio)
    for _,key in ipairs({"shop","residential","musicDay","ring"}) do assert(sound.sounds[key] and sound.sounds[key]:GetLength()>0,"新增音景素材必须实际可加载："..key) end
    assert(sound.phoneSource~=sound.sources.ring,"电话必须使用独立于玩法暂停的音源")
    session:CallCustomer(beforeCall.activeOrders[1].id)
    assert(session.customerCall and session.view.phonePage=="call" and session.view:IsBlocking(),"电话必须进入真实手机页并冻结玩法")
    for _=1,22 do session:Update(.1) end
    local connected=assert(session.customerCall)
    assert(connected.phase=="connected","独立电话时间应在游戏暂停时接通")
    local afterCall=Store.Get()
    assert(afterCall.cashCents==beforeCall.cashCents and afterCall.time==beforeCall.time
        and afterCall.activeOrders[1].remainingHours==beforeCall.activeOrders[1].remainingHours,"电话不扣款、不推进订单、不远程交单")
    session.view:ClosePhone()
    assert(not session.customerCall,"收起手机必须挂断电话")
    local callCount=session.callSequence
    session:CallCustomer("missing-order")
    assert(not session.customerCall and session.callSequence==callCount,"结束或错误订单不能拨号")
    local Calls=require("Career.CustomerCall")
    local delivered=beforeCall.activeOrders[1]
    delivered.status="picked"
    local point=assert(require("Career.Config").points[delivered.dropoffId])
    local lines={}
    for sequence=1,4 do
        local candidate=assert(Calls.Begin(delivered,{x=point.x,z=point.z,speed=0},sequence))
        assert(not lines[candidate.rider],"到门口对白需要四种不同内容")
        lines[candidate.rider]=true
    end
    assert(not Calls.Begin(delivered,{x=point.x,z=point.z,speed=1},1),"骑行不能拨号")
    print("[顾客电话验收通过] 订单绑定/冻结/接通/挂断/四种到门口对白/无远程交单")
    assert(Store.Transaction(function(d) d.time=23;d.energy=24;return true end))
    local advice=Life.Advice(Store.Get())
    assert(advice.action=="继续配送" and advice.point==offer.pickupId,"深夜带单不能快捷导航去睡觉")
    session:Refresh();session:OpenPhone("life")
    local phoneOrder=Store.Get()
    local phoneSky=assert(sky.state)
    local phoneU,phoneV=phoneSky.cloudU,phoneSky.cloudV
    session.options.test=false
    local phoneOK,phoneError=pcall(function() session:Update(.1) end)
    session.options.test=true
    assert(phoneOK,phoneError)
    local phoneAfter=Store.Get()
    assert(phoneAfter.time==phoneOrder.time and phoneAfter.energy==phoneOrder.energy and phoneAfter.hunger==phoneOrder.hunger
        and phoneAfter.activeOrders[1].remainingHours==phoneOrder.activeOrders[1].remainingHours,"手机冻结活动订单与人物")
    assert(sky.state.cloudU==phoneU and sky.state.cloudV==phoneV,"手机带单冻结天气")
    session.view:ClosePhone();session:Pause()
    local menu=Store.Get()
    local menuSky=assert(sky.state)
    local menuU,menuV=menuSky.cloudU,menuSky.cloudV
    session.options.test=false
    local menuOK,menuError=pcall(function() session:Update(.1) end)
    session.options.test=true
    assert(menuOK,menuError)
    local menuAfter=Store.Get()
    assert(menuAfter.time==menu.time and menuAfter.hunger==menu.hunger and menuAfter.energy==menu.energy
        and menuAfter.activeOrders[1].remainingHours==menu.activeOrders[1].remainingHours,"暂停菜单冻结人物与配送")
    assert(sky.state.cloudU==menuU and sky.state.cloudV==menuV,"暂停菜单冻结天气")
    session.view:ShowGame()
    assert(Store.Transaction(function(d) d.activeOrders={};return true end))
    local cases={day={day=1,time=12,hunger=65,energy=80},dusk={day=1,time=17.8,hunger=43,energy=47},
        night={day=1,time=22,hunger=60,energy=24},cloudy={day=5,time=12,hunger=65,energy=80},
        mixed={day=4,time=12,hunger=65,energy=80},cloudnight={day=5,time=23,hunger=60,energy=24},
        life={day=1,time=12,hunger=29,energy=48},low={day=1,time=23,hunger=24,energy=19}}
    local selected=cases[shot] or cases.day
    assert(Store.Transaction(function(d)
        d.day=selected.day;d.time=selected.time;d.hunger=selected.hunger;d.energy=selected.energy
        return true
    end))
    session.actor:Teleport(0,-20,0);session.yaw,session.pitch=0,-4
    session.waypoint="";session.manualWaypoint=false;session.navigation={key="",route={}}
    session:Refresh();session:UpdateEnvironment(Store.Get().time)
    if shot=="life" then session:OpenPhone("life")
    elseif shot=="atlas" then session.view:OpenWorldMap()
    elseif shot=="property" then session:OpenPhone("progression") end
    session.view.notice:SetText("")
    session.options.lifeAudit=true
    session.options.lifeRide=shot=="ride" or shot=="nightride"
    if session.options.lifeRide then
        session.actor.mounted=true;session.actor.visuals:SetMounted(true)
        session.actor:SyncVisuals(0)
        local rider=session.actor.visuals.mountedRider
        for _,steer in ipairs({0,-1,1}) do
            rider:PoseRide(steer)
            local pose=rider:ReadPose()
            assert(pose.leftGripError<.005 and pose.rightGripError<.005,"新人物骑姿必须真实握住两侧把手")
        end
        rider:PoseRide(0)
        session:Refresh()
    end
    if shot=="nightride" then
        assert(Store.Transaction(function(d) d.time=22;return true end));session:Refresh()
    elseif shot=="order" or shot=="call" then
        local orderOffer=assert(Delivery.GetOffer());assert(Delivery.Accept(orderOffer.id));session:Refresh()
        if shot=="call" then
            local callOrder=assert(Delivery.GetActive())
            session:CallCustomer(callOrder.id)
            for _=1,22 do session:Update(.1) end
        end
    elseif shot=="plan" then
        assert(Store.Transaction(function(d) d.hunger=63;d.energy=57;d.battery=20;d.accommodation="hostel";return true end))
        session:Refresh();session:OpenPhone("life")
        Kit.LayoutTree(session.view.phoneArea)
        session.view.phoneContent:ShowWidget("career-life-plan")
    end
    print("[生活时间验收通过] 活动消耗/用餐/过夜/手机与暂停冻结/带单导航/天气连续；实拍="..tostring(shot))
end
---@param session CareerSession
function Checks.Audit(session)
    local view=session.view
    Kit.LayoutTree(view.game)
    local d=view.dashboard
    local p=Store.Get()
    assert(d.clock.props.text==Life.Clock(p.time),"HUD时钟必须与存档一致")
    assert(d.foodBar:GetValue()==p.hunger and d.energyBar:GetValue()==p.energy,"HUD条形值必须与存档一致")
    local function bounds(widget)
        local b=widget:GetAbsoluteLayout()
        assert(b.w>0 and b.h>0,"HUD空布局 "..tostring(widget.props.id))
        local screen=view.root:GetAbsoluteLayout()
        assert(b.x>=screen.x and b.y>=screen.y and b.x+b.w<=screen.x+screen.w+1
            and b.y+b.h<=screen.y+screen.h+1,"HUD越出屏幕 "..tostring(widget.props.id))
        return b
    end
    local dashboard=bounds(d.root)
    local nav=view.navPanel:GetAbsoluteLayout()
    assert(nav.h<=0 or nav.x+nav.w<=dashboard.x or nav.y+nav.h<=dashboard.y,"导航不能遮盖独立状态")
    assert(d.root.props.borderWidth==0 and d.root.props.backgroundColor[4]==0
        and not d.root.props.backgroundGradient,"HUD不可恢复仪表舱底板")
    assert(view.actionTray.props.backgroundColor[4]==0 and not view.actionTray.props.backgroundGradient,
        "操作不能套入卡片底座")
    bounds(d.clock)
    assert((d.clock.props.fontSize or 0)*UI.GetScale()>=28,"独立时钟必须保持大字")
    for _,widget in ipairs({d.foodValue,d.energyValue,d.batteryValue}) do
        local r=bounds(widget)
        assert((widget.props.fontSize or 0)*UI.GetScale()>=17.99,"核心文字必须至少18物理像素")
        assert(r.x>=dashboard.x and r.y>=dashboard.y and r.x+r.w<=dashboard.x+dashboard.w+1
            and r.y+r.h<=dashboard.y+dashboard.h+1,"独立状态内容溢出 "..tostring(widget.props.id))
    end
    assert(view.deliveryStatus:IsVisible()==(view.lastActive==true),"无订单不显示派单说明")
    local phoneButton=view.menuButton
    for _,button in ipairs({view.pauseButton,view.mountButton,view.interactButton,phoneButton}) do
        if button:IsVisible() then
            local r=bounds(button)
            assert(r.w>=44 and r.h>=44,"HUD触摸目标不足44")
        end
    end
    local PointerEvent=require("urhox-libs/UI/Core/PointerEvent")
    local function tap(widget,held,pointerId)
        local r=widget:GetAbsoluteLayoutForHitTest()
        local scale=UI.GetScale()
        local function event(kind)
            return PointerEvent.new(kind,{pointerId=pointerId or 791230,pointerType="touch",isPrimary=true,
                x=(r.x+r.w/2)*scale,y=(r.y+r.h/2)*scale,button=PointerEvent.Button.Left})
        end
        local down=event("PointerDown");UI.HandlePointerEvent(down)
        assert(down.target==widget,"HUD触摸被遮挡 "..tostring(widget.props.id))
        if held then held() end
        local up=event("PointerUp");UI.HandlePointerEvent(up)
        assert(up.target==widget,"HUD抬手命中错误 "..tostring(widget.props.id))
    end
    local wasPhone=view.phonePage
    local wasMap=view.worldMap:IsVisible()
    local savedPage=view.phoneContent:GetPage()
    if wasPhone=="life" then require("Career.PhoneAppChecks").Audit(view,"life-dashboard") end
    view:CloseWorldMap()
    if wasPhone~="" then view:ClosePhone() end
    local oldWaypoint,oldManual=session.waypoint,session.manualWaypoint
    tap(phoneButton)
    assert(view.phonePage=="apps","独立手机入口未打开桌面")
    Kit.LayoutTree(view.phoneArea)
    local lifeApp=assert(view.phoneDesktop:FindById("career-app-life"))
    tap(lifeApp)
    assert(view.phonePage=="life","次要生活信息必须能从手机菜单进入")
    view:ClosePhone()
    assert(view.mapOpen:IsVisible() and view.map.root:IsVisible(),"小地图必须常驻，不能依赖活动订单")
    tap(view.mapOpen)
    assert(view.worldMap:IsVisible() and view:IsBlocking(),"小地图必须打开完整地图并冻结玩法")
    assert(view.phonePage=="","完整地图不能挤进手机滚动页")
    view:CloseWorldMap()
    assert(not view.worldMap:IsVisible() and not view:IsBlocking(),"关闭地图应恢复玩法")
    tap(view.pauseButton)
    assert(view:IsBlocking(),"暂停按钮触摸未打开菜单")
    view:ShowGame()
    local walletBefore=Store.Get().cashCents
    local function planTap(id)
        session:OpenPhone("life")
        Kit.LayoutTree(view.phoneArea)
        assert(view.phoneContent:ShowWidget(id),"分页中找不到生活动作 "..id)
        Kit.LayoutTree(view.phoneArea)
        local widget=assert(view.phoneBody:FindById(id))
        tap(widget)
    end
    planTap("career-plan-home")
    assert(session.waypoint==Life.Plan(p).home.point and view.phonePage=="","住处计划按钮必须导航并收起手机")
    planTap("career-plan-supply")
    assert(session.waypoint==(Life.Plan(p).electric and "charge" or "dealer") and view.phonePage=="","补给计划按钮必须导航并收起手机")
    planTap("career-plan-wallet")
    assert(view.phonePage=="wallet","收支卡必须打开真实钱包明细")
    assert(Store.Get().cashCents==walletBefore,"查看计划、导航和钱包不能扣款")
    view:ClosePhone()
    session:ShowMorning("休息结束，准备新一天。")
    Kit.LayoutTree(view.overlay)
    local morningPages=assert(view.dialogBody:FindById("career-dialog-pages"))
    local morningBounds=bounds(morningPages)
    local morningButton=view.dialogBody.children[#view.dialogBody.children]
    local buttonBounds=bounds(morningButton)
    assert(morningBounds.y+morningBounds.h<=buttonBounds.y+1,"晨间确认按钮必须在分页正文之外")
    tap(morningButton)
    assert(not view:IsBlocking(),"晨间确认必须能真实触摸关闭")
    local originalMounted=session.actor.mounted
    session.actor.mounted=true;view:SetControlMode(true)
    for _=1,3 do Kit.LayoutTree(view.game);view:LayoutControls() end
    Kit.LayoutTree(view.game)
    -- 模拟合法但与生活卡重叠的自定义踏板位置，只改本次控件，不写玩家方案。
    local layer=view.controlLayer:GetAbsoluteLayout()
    local card=d.root:GetAbsoluteLayout()
    view.controls.widgets.gas:SetStyle{left=card.x-layer.x,top=card.y-layer.y}
    Kit.LayoutTree(view.game);view:AvoidHUDControls();Kit.LayoutTree(view.game)
    for _,key in ipairs({"gas","brake","steering"}) do
        local widget=view.controls.widgets[key]
        local r=bounds(widget)
        for _,obstacle in ipairs({d.root,d.clock,d.speed,view.navPanel,view.pauseButton,view.menuButton,view.actionTray}) do
            local q=obstacle:GetAbsoluteLayout()
            assert(not obstacle:IsVisible() or q.h<=0 or r.x+r.w<=q.x or r.x>=q.x+q.w or r.y+r.h<=q.y or r.y>=q.y+q.h,"骑行控件遮盖HUD "..key)
        end
        tap(widget,function()
            assert(key=="steering" and view.controls.pointers.steer==791230
                or key~="steering" and view.controls[key],"踏板未持有触摸 "..key)
        end)
        assert(key=="steering" and view.controls.pointers.steer==-1 or key~="steering" and not view.controls[key],"踏板松手未释放")
    end
    tap(view.controls.widgets.gas,function()
        tap(view.controls.widgets.brake,function()
            assert(view.controls.gas and view.controls.brake,"双指必须能独立持有油门和刹车")
        end,791231)
        assert(view.controls.gas and not view.controls.brake,"松开刹车不能释放另一根手指的油门")
    end)
    assert(not view.controls.gas and not view.controls.brake,"双指松手必须全部释放")
    session.actor.mounted=originalMounted;view:SetControlMode(originalMounted)
    view.controlWidth,view.controlHeight=0,0
    session.waypoint,session.manualWaypoint=oldWaypoint,oldManual
    session:Refresh();view:LayoutControls();Kit.LayoutTree(view.game)
    if wasMap then view:OpenWorldMap()
    elseif wasPhone~="" then
        if wasPhone=="call" then
            local active=assert(require("Career.Delivery").GetActive())
            session:CallCustomer(active.id)
            for _=1,22 do session:Update(.1) end
        else session:OpenPhone(wasPhone) end
        Kit.LayoutTree(view.phoneArea);view.phoneContent:SetPage(savedPage)
    end
    print(string.format("[生活HUD渲染验收通过] screen %.0fx%.0f / 实际值一致 / 44尺寸 / 生活与暂停真实触摸 / 骑行避让与多指释放",view.root:GetLayout().w,view.root:GetLayout().h))
end
return Checks
