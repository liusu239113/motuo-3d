-- 轻量生活HUD：一行时间与入口、一行真实状态；详细预算只在手机中显示。
local UI=require("urhox-libs/UI")
local Theme=require("RacingTheme")
local Kit=require("Career.PhoneKit")
local Life=require("Career.LifeStatus")
local C=Theme.Colors
local Dashboard={}
Dashboard.__index=Dashboard
local function text(t,size,color,id)
    return Kit.Text(t,size,color,{id=id,fontWeight="normal"})
end
local function meter(id,title,color)
    local value=text(title.." —",11,C.white,id.."-value")
    local bar=UI.ProgressBar{id=id.."-bar",value=0,max=100,width="100%",height=3,
        showLabel=false,fillColor=color,borderWidth=0,borderRadius=0,padding=0,pointerEvents="none"}
    return UI.Panel{flexGrow=1,flexShrink=1,flexBasis=0,minWidth=0,padding=0,gap=2,children={value,bar}},value,bar
end
local function shortcut(title,callback,id)
    return Kit.Button(title,callback,id,false,{width=48,minWidth=44,fontSize=11,
        backgroundColor={24,31,35,145},textColor=C.white})
end
function Dashboard.New(actions)
    local self=setmetatable({},Dashboard);self:Init(actions);return self
end
function Dashboard:Init(actions)
    self.actions=actions
    self.clock=text("08:00",22,C.white,"career-hud-clock");self.clock:SetStyle{width=78}
    self.part=text("第1天 · 早晨",10,C.amber,"career-hud-day")
    self.weather=text("晴朗",10,C.white,"career-hud-weather")
    self.wallet=text("",11,C.white,"career-hud-wallet");self.wallet:SetVisible(false)
    self.plan=text("",10,C.muted,"career-hud-plan");self.plan:SetVisible(false)
    self.speed=text("",16,C.white,"career-hud-speed")
    local food,foodValue,foodBar=meter("career-hud-hunger","饱腹",C.green)
    local energy,energyValue,energyBar=meter("career-hud-energy","精力",C.cyan)
    local battery,batteryValue,batteryBar=meter("career-hud-battery","电量",C.amber)
    self.foodValue,self.foodBar=foodValue,foodBar
    self.energyValue,self.energyBar=energyValue,energyBar
    self.batteryValue,self.batteryBar=batteryValue,batteryBar
    self.advice=text("",10,C.amber,"career-hud-advice")
    self.lifeButton=shortcut("吃饭",function() actions.phone("life") end,"career-life-quick")
    self.helpButton=shortcut("生活",function() actions.phone("life") end,"career-life-details")
    self.root=UI.Panel{id="career-life-dashboard",position="absolute",right=12,top=12,width=306,
        padding=8,gap=5,backgroundColor={12,18,23,145},pointerEvents="box-none",children={
            UI.Row{width="100%",padding=0,gap=4,alignItems="center",children={self.clock,
                UI.Panel{flexGrow=1,flexShrink=1,flexBasis=0,minWidth=0,padding=0,gap=1,children={self.part,self.weather}},
                self.lifeButton,self.helpButton}},
            UI.Row{width="100%",padding=0,gap=10,children={food,energy,battery}},self.advice,self.speed,self.wallet,self.plan}}
end
function Dashboard:Update(p,actor)
    local advice=Life.Advice(p)
    self.clock:SetText(Life.Clock(p.time))
    self.part:SetText(string.format("第%d天 · %s",p.day,Life.Part(p.time)))
    self.weather:SetText(p.weatherLabel or "晴朗")
    self.wallet:SetText(string.format("王二狗 / ¥%.2f",p.cashCents/100))
    self.foodValue:SetText(string.format("饱腹 %.0f",p.hunger))
    self.energyValue:SetText(string.format("精力 %.0f",p.energy))
    local electric=actor.vehicleId=="borrowed_ebike"
    local power=electric and p.battery or p.motorcycleFuel or 100
    self.batteryValue:SetText(string.format("%s %.0f%%",electric and "电量" or "燃油",power))
    self.foodBar:SetValue(p.hunger);self.energyBar:SetValue(p.energy);self.batteryBar:SetValue(power)
    local alerts=Life.Alerts(p)
    local alert=alerts[1] --[[@as CareerLifeAlert?]]
    self.advice:SetText(alert and alert.title or "")
    self.advice:SetVisible(alert~=nil and alert.level>=2)
    local supply=alert and alert.key:match("^power")
    self.lifeButton:SetText(supply and "补给" or advice.action=="继续配送" and "配送" or advice.point=="breakfast" and "吃饭" or "休息")
    self.lifeButton.props.onClick=function()
        if p.currentSpace and p.currentSpace~="city" then self.actions.phone("life")
        else self.actions.setWaypoint(supply and alert.point or advice.point) end
    end
    self.speed:SetText(actor.mounted and string.format("%02.0f km/h",math.abs(actor.speed)*3.6) or "")
    self.speed:SetVisible(actor.mounted)
end
return Dashboard
