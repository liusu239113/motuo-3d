-- 无底板HUD：独立时钟、三项状态与车速；日期、天气、生活建议只在手机查看。
local UI=require("urhox-libs/UI")
local Theme=require("RacingTheme")
local Kit=require("Career.PhoneKit")
local Life=require("Career.LifeStatus")
local C=Theme.Colors
local Dashboard={}
Dashboard.__index=Dashboard
local function text(t,size,color,id)
    return Kit.Text(t,size,color,{id=id,fontWeight="normal",whiteSpace="nowrap",
        textStroke={width=1,color={0,0,0,220}},
        textShadow={offsetX=0,offsetY=2,blur=0,color={0,0,0,230}}})
end
local function meter(id,title,color)
    local value=text(title.." —",18,C.white,id.."-value")
    local bar=UI.ProgressBar{id=id.."-bar",value=0,max=100,width="100%",height=4,
        showLabel=false,fillColor=color,backgroundColor={0,0,0,130},borderWidth=0,
        borderRadius=0,padding=0,pointerEvents="none"}
    local body=UI.Panel{flexGrow=1,flexShrink=1,flexBasis=0,minWidth=0,padding=0,gap=5,
        backgroundColor={0,0,0,0},children={value,bar}}
    return body,value,bar
end
function Dashboard.New()
    local self=setmetatable({},Dashboard);self:Init();return self
end
function Dashboard:Init()
    self.clock=text("08:00",30,C.white,"career-hud-clock")
    self.clock:SetStyle{width=150,flexShrink=0}
    self.speed=text("",32,C.white,"career-hud-speed")
    self.speed:SetStyle{position="absolute",bottom=22,left="44%",width=200,textAlign="center"}
    local food,foodValue,foodBar=meter("career-hud-hunger","饱腹",C.green)
    local energy,energyValue,energyBar=meter("career-hud-energy","精力",C.cyan)
    local battery,batteryValue,batteryBar=meter("career-hud-battery","电量",C.amber)
    self.foodValue,self.foodBar=foodValue,foodBar
    self.energyValue,self.energyBar=energyValue,energyBar
    self.batteryValue,self.batteryBar=batteryValue,batteryBar
    self.root=UI.Panel{id="career-life-dashboard",position="absolute",right=12,top=12,width=380,
        padding=0,gap=18,backgroundColor={0,0,0,0},borderWidth=0,pointerEvents="none",children={
            self.clock,UI.Row{width="100%",padding=0,gap=22,children={food,energy,battery}}}}
end
function Dashboard:Layout()
    -- 短屏密度缩放不能把核心数字再次缩成小字，至少保留18物理像素。
    local size=math.max(18,18/math.max(.1,UI.GetScale()))
    self.root:SetStyle{width=380*size/18}
    self.clock:SetStyle{fontSize=size*1.65,width=size*8,height=size*2.1}
    for _,value in ipairs({self.foodValue,self.energyValue,self.batteryValue}) do
        value:SetStyle{fontSize=size,height=size*1.5}
    end
    self.speed:SetStyle{fontSize=size*1.8,width=size*11,height=size*2.4}
end
function Dashboard:Update(p,actor)
    self.clock:SetText(Life.Clock(p.time))
    self.foodValue:SetText(string.format("饱腹 %.0f",p.hunger))
    self.energyValue:SetText(string.format("精力 %.0f",p.energy))
    local electric=actor.vehicleId=="borrowed_ebike"
    local power=electric and p.battery or p.motorcycleFuel or 100
    self.batteryValue:SetText(string.format("%s %.0f%%",electric and "电量" or "燃油",power))
    self.foodBar:SetValue(p.hunger);self.energyBar:SetValue(p.energy);self.batteryBar:SetValue(power)
    -- 低状态直接染色原有数值和短条，不另弹警告卡。
    for _,stat in ipairs({{value=p.hunger,label=self.foodValue,bar=self.foodBar,color=C.green},
        {value=p.energy,label=self.energyValue,bar=self.energyBar,color=C.cyan},
        {value=power,label=self.batteryValue,bar=self.batteryBar,color=C.amber}}) do
        local color=stat.value<30 and C.red or stat.color
        stat.label:SetStyle{fontColor=stat.value<30 and C.red or C.white}
        stat.bar:SetStyle{fillColor=color}
    end
    self.speed:SetText(actor.mounted and string.format("%02.0f km/h",math.abs(actor.speed)*3.6) or "")
    self.speed:SetVisible(actor.mounted)
end
return Dashboard
