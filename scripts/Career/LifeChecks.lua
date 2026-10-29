-- 小型隔离验收：仅本轮时间/生活HUD，不执行全城市、交通、路网回归。
local Store=require("Career.Store")
local Life=require("Career.LifeStatus")
local UI=require("urhox-libs/UI")
local Kit=require("Career.PhoneKit")
local Checks={}
---@param session CareerSession
function Checks.Run(session,shot)
    assert(session.options.test and session.restoreTestStorage,"生活验收必须内存隔离")
    assert(Store.NewCareer())
    assert(Store.Transaction(function(p) p.phase="working";p.flags.introSeen=true;return true end))
    local p=Store.Get()
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
    session.actor:Teleport(0,-70,0)
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
    local Delivery=require("Career.Delivery")
    local offer=assert(Delivery.GetOffer())
    assert(Delivery.Accept(offer.id))
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
    if shot=="life" then session:OpenPhone("life") end
    session.view.notice:SetText("")
    session.options.lifeAudit=true
    session.options.lifeRide=shot=="ride"
    if session.options.lifeRide then
        session.actor.mounted=true;session.actor.visuals:SetMounted(true);session:Refresh()
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
    local nav=bounds(view.navPanel)
    assert(nav.x+nav.w<=dashboard.x or nav.y+nav.h<=dashboard.y,"地图不能遮盖人物状态卡")
    for _,button in ipairs({d.lifeButton,d.helpButton,view.pauseButton,view.mountButton,view.interactButton}) do
        local r=bounds(button)
        assert(r.w>=44 and r.h>=44,"HUD触摸目标不足44")
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
    if wasPhone=="life" then require("Career.PhoneAppChecks").Audit(view,"life-dashboard");view:ClosePhone() end
    local oldWaypoint,oldManual=session.waypoint,session.manualWaypoint
    tap(d.lifeButton)
    assert(session.waypoint==Life.Advice(p).point,"快捷按钮真实导航失败")
    tap(d.helpButton)
    assert(view.phonePage=="life","生活详情触摸未打开手机")
    view:ClosePhone()
    tap(view.pauseButton)
    assert(view:IsBlocking(),"暂停按钮触摸未打开菜单")
    view:ShowGame()
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
        for _,obstacle in ipairs({d.root,view.navPanel,view.pauseButton,view.actionTray}) do
            local q=obstacle:GetAbsoluteLayout()
            assert(r.x+r.w<=q.x or r.x>=q.x+q.w or r.y+r.h<=q.y or r.y>=q.y+q.h,"骑行控件遮盖HUD "..key)
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
    if wasPhone=="life" then session:OpenPhone("life") end
    print(string.format("[生活HUD渲染验收通过] screen %.0fx%.0f / 实际值一致 / 44尺寸 / 生活与暂停真实触摸 / 骑行避让与多指释放",view.root:GetLayout().w,view.root:GetLayout().h))
end
return Checks
