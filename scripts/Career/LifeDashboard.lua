-- 生涯HUD：时间/天气、人物状态、导航各自成组，不用调试文字堆满左上角。
local UI=require("urhox-libs/UI")
local Theme=require("RacingTheme")
local Kit=require("Career.PhoneKit")
local Life=require("Career.LifeStatus")
local C=Theme.Colors
local Dashboard={}
Dashboard.__index=Dashboard
local function text(t,size,color,id)
    return Kit.Text(t,size,color,{id=id,fontWeight="bold"})
end
local function meter(id,title,color)
    local value=text(title.." —",11,C.white,id.."-value")
    local bar=UI.ProgressBar{id=id.."-bar",value=0,max=100,width="100%",height=5,
        showLabel=false,fillColor=color,borderWidth=0,borderRadius=0,padding=0,pointerEvents="none"}
    return UI.Panel{flexGrow=1,flexShrink=1,flexBasis=0,minWidth=0,padding=0,gap=4,children={value,bar}},value,bar
end
function Dashboard.New(actions)
    local self=setmetatable({},Dashboard)
    self:Init(actions)
    return self
end
function Dashboard:Init(actions)
    self.actions=actions
    self.clock=text("08:00",28,C.white,"career-hud-clock")
    self.clock:SetStyle{width=116}
    self.part=text("第1天 · 早晨",11,C.amber,"career-hud-day")
    self.weather=text("晴朗",11,C.cyan,"career-hud-weather")
    self.wallet=text("王二狗 · ¥50.00",11,C.white,"career-hud-wallet")
    self.speed=text("步行",18,C.white,"career-hud-speed")
    self.plan=text("",10,C.muted,"career-hud-plan")
    local food,foodValue,foodBar=meter("career-hud-hunger","饱腹",C.green)
    local energy,energyValue,energyBar=meter("career-hud-energy","精力",C.cyan)
    local battery,batteryValue,batteryBar=meter("career-hud-battery","电量",C.amber)
    self.foodValue,self.foodBar=foodValue,foodBar
    self.energyValue,self.energyBar=energyValue,energyBar
    self.batteryValue,self.batteryBar=batteryValue,batteryBar
    self.advice=text("身体状态良好",11,C.green,"career-hud-advice")
    self.lifeButton=Kit.Button("生活详情",function() actions.phone("life") end,"career-life-quick",true,
        {width="48%",flexGrow=1,flexShrink=1,fontSize=11})
    self.helpButton=Kit.Button("生活详情",function() actions.phone("life") end,"career-life-details",false,
        {width="48%",flexGrow=1,flexShrink=1,fontSize=11})
    -- 延续现有钢灰/琥珀BrawlForge衍生色板，不改变旧竞速主题。
    self.root=UI.Card{id="career-life-dashboard",position="absolute",right=12,top=12,width=300,
        padding=12,gap=7,pointerEvents="box-none",children={
            UI.Row{width="100%",padding=0,gap=8,alignItems="center",children={self.clock,
                UI.Panel{flexGrow=1,flexShrink=1,flexBasis=0,minWidth=0,padding=0,gap=2,children={self.part,self.weather}}}},
            self.wallet,
            UI.Row{width="100%",padding=0,gap=10,children={food,energy,battery}},
            self.advice,
            UI.Row{width="100%",padding=0,gap=6,children={self.lifeButton,self.helpButton}},self.speed,self.plan}}
end
function Dashboard:Update(p,actor)
    local advice=Life.Advice(p)
    self.clock:SetText(Life.Clock(p.time))
    self.part:SetText(string.format("第%d天 · %s",p.day,Life.Part(p.time)))
    self.weather:SetText(p.weatherLabel or "晴朗")
    self.wallet:SetText(string.format("王二狗  /  ¥%.2f",p.cashCents/100))
    self.foodValue:SetText(string.format("饱腹 %.0f",p.hunger))
    self.energyValue:SetText(string.format("精力 %.0f",p.energy))
    local electric=actor.vehicleId=="borrowed_ebike"
    local power=electric and p.battery or p.motorcycleFuel or 100
    self.batteryValue:SetText(string.format("%s %.0f%%",electric and "电量" or "燃油",power))
    self.foodBar:SetValue(p.hunger); self.energyBar:SetValue(p.energy);self.batteryBar:SetValue(power)
    self.foodBar:SetStyle{fillColor=p.hunger<30 and C.red or p.hunger<=55 and C.amber or C.green}
    self.energyBar:SetStyle{fillColor=p.energy<30 and C.red or p.energy<=45 and C.amber or C.cyan}
    local plan=Life.Plan(p)
    local alerts=Life.Alerts(p)
    local alert=alerts[1]
    self.advice:SetText(alert and alert.title or advice.title)
    self.advice:SetStyle{fontColor=alert and (alert.level>=2 and C.red or C.amber) or C.green}
    self.plan:SetText(actor.mounted and string.format("预计续航 %.1f km · 预留 ¥%.0f",plan.rangeMeters/1000,plan.reserveCents/100)
        or (plan.mealText.." · 今晚"..(plan.home.price==0 and "免费住处" or string.format("¥%.0f",plan.home.price/100))))
    local supply=alert and alert.key:match("^power")
    self.lifeButton:SetText(supply and "导航补给" or advice.action=="生活详情" and "导航吃饭" or advice.action)
    self.lifeButton.props.onClick=function()
        if p.currentSpace and p.currentSpace~="city" then self.actions.phone("life")
        else self.actions.setWaypoint(supply and alert.point or advice.point) end
    end
    self.speed:SetText(actor.mounted and string.format("%02.0f km/h  ·  %s",math.abs(actor.speed)*3.6,actor:VehicleName())
        or "步行探索 · 就近交互")
end
return Dashboard
