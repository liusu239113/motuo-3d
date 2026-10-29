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
    local wasTest=session.options.test
    session.options.test=false
    local ok,message=pcall(function() session:Update(.1) end)
    session.options.test=wasTest
    assert(ok,message)
    assert(Store.Get().time==paused.time and Store.Get().energy==paused.energy,"手机暂停时间与精力")
    local sky=assert(session.atmosphere)
    local Atmosphere=require("Career.Atmosphere")
    local frozen=Atmosphere.Sample(paused.day,paused.time)
    session:UpdateEnvironment(paused.time)
    assert(sky.state.cloudU==frozen.cloudU and sky.state.cloudV==frozen.cloudV,"手机冻结云层漂移")
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
    print("[生活时间验收通过] 活动消耗/12元15分钟用餐/免费过夜/手机冻结/饥饿疲劳提示；实拍="..tostring(shot))
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
    if view.phonePage=="life" then require("Career.PhoneAppChecks").Audit(view,"life-dashboard") end
    print(string.format("[生活HUD渲染验收通过] screen %.0fx%.0f / 地图与时间卡分区 / 实际值一致 / 44触摸",view.root:GetLayout().w,view.root:GetLayout().h))
end
return Checks
