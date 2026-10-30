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
    local value=text(title.." —",10,C.white,id.."-value")
    local bar=UI.ProgressBar{id=id.."-bar",value=0,max=100,width="100%",height=3,
        showLabel=false,fillColor=color,borderWidth=0,borderRadius=0,padding=0,pointerEvents="none"}
    local body=UI.Panel{flexGrow=1,flexShrink=1,flexBasis=0,minWidth=0,padding=0,gap=3,children={value,bar}}
    return body,value,bar
end
local function shortcut(title,callback,id)
    local button=Kit.Button(title,callback,id,false,{width=46,minWidth=44,height=40,minHeight=40,fontSize=10,
        backgroundColor={25,34,40,230},textColor=C.white})
    -- 轻量仪表舱内的分段按键：保留44px命中区，不再像独立弹窗。
    local touchSize=Kit.TouchSize()
    button:SetStyle{width=46,minWidth=touchSize,height=touchSize,minHeight=touchSize,padding=0,borderRadius=4,borderWidth=1,
        borderColor={105,143,151,180},backgroundGradient={direction="to-bottom",from={46,64,70,235},to={20,29,34,245}},
        boxShadow={{x=0,y=1,blur=0,color={0,0,0,80}}}}
    return button
end
function Dashboard.New(actions)
    local self=setmetatable({},Dashboard);self:Init(actions);return self
end
function Dashboard:Init(actions)
    self.actions=actions
    self.clock=text("08:00",22,C.white,"career-hud-clock");self.clock:SetStyle{width=88,minWidth=88,flexShrink=0,whiteSpace="nowrap"}
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
    self.root=UI.Panel{id="career-life-dashboard",position="absolute",right=12,top=12,width=296,
        padding=8,gap=6,backgroundGradient={direction="to-bottom",from={22,31,37,235},to={8,13,17,225}},
        borderWidth=1,borderColor={102,137,145,190},borderRadius=5,
        boxShadow={{x=0,y=3,blur=0,color={0,0,0,95}}},pointerEvents="box-none",children={
            UI.Row{width="100%",padding=0,gap=5,alignItems="center",children={self.clock,
                UI.Panel{flexGrow=1,flexShrink=1,flexBasis=0,minWidth=0,padding=0,gap=1,children={self.part,self.weather}},
                self.lifeButton,self.helpButton}},
            UI.Panel{width="100%",height=1,padding=0,backgroundColor={126,169,175,80},pointerEvents="none"},
            UI.Row{width="100%",padding=0,gap=9,children={food,energy,battery}},self.advice,self.speed,self.wallet,self.plan}}
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
