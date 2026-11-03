-- 无底板HUD：独立时钟、三项状态与车速；日期、天气、生活建议只在手机查看。
local UI=require("urhox-libs/UI")
local Theme=require("RacingTheme")
local Kit=require("Career.PhoneKit")
local Life=require("Career.LifeStatus")
local LineIcon=require("Career.LineIcon")
local C=Theme.Colors
local Dashboard={}
Dashboard.__index=Dashboard
local function text(t,size,color,id)
    local value=Kit.Text(t,size,color,{id=id,fontWeight="normal",whiteSpace="nowrap",
        textStroke={width=1,color={0,0,0,220}},
        textShadow={offsetX=0,offsetY=2,blur=0,color={0,0,0,230}}})
    value:SetStyle{lineHeight=1}
    return value
end
local function meter(id,title,color,kind)
    local value=text("—",18,C.white,id.."-value")
    value:SetStyle{paddingLeft=26}
    value:AddChild(LineIcon{kind=kind,position="absolute",left=0,top=2,width=22,height=22,color=color,pointerEvents="none"})
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
    self.clock:SetStyle{position="absolute",left=12,top=12,width=150,flexShrink=0}
    self.speed=text("",32,C.white,"career-hud-speed")
    self.speed:SetStyle{position="absolute",bottom=22,left="44%",width=200,textAlign="center"}
    local food,foodValue,foodBar=meter("career-hud-hunger","饱腹",C.green,"food")
    local energy,energyValue,energyBar=meter("career-hud-energy","精力",C.cyan,"energy")
    local battery,batteryValue,batteryBar=meter("career-hud-battery","电量",C.amber,"battery")
    self.foodValue,self.foodBar=foodValue,foodBar
    self.energyValue,self.energyBar=energyValue,energyBar
    self.batteryValue,self.batteryBar=batteryValue,batteryBar
    self.meters=UI.Row{width="100%",padding=0,gap=22,children={food,energy,battery}}
    self.root=UI.Panel{id="career-life-dashboard",position="absolute",right=174,top=18,width=380,
        padding=0,backgroundColor={0,0,0,0},borderWidth=0,pointerEvents="none",children={self.meters}}
end
local function lineHeight(widget,size)
    local p=widget.props
    -- 字号单位是pt，不是Yoga像素。使用真实字体行高，并保留描边/阴影与端点取整空间。
    local pixels=UI.Theme.FontSize(size)
    -- 速度初始为空/隐藏，不能用空串测量后把较短行高缓存到骑行态。
    local sample=(p.text and p.text~="") and p.text or "000 km/h 汉字"
    local measured=UI.MeasureTextFit(sample,{fontSize=pixels,minFontSize=pixels,
        fontFace=UI.Theme.FontFace(p.fontFamily,p.fontWeight),width=1000,multiline=false,lineHeight=p.lineHeight or 1.35})
    return math.ceil(math.max(pixels*(p.lineHeight or 1.35),measured.height or 0))+4
end
local function measuredWidth(sample,size,face)
    local pixels=UI.Theme.FontSize(size)
    local measured=UI.MeasureTextFit(sample,{fontSize=pixels,minFontSize=pixels,
        fontFace=face,width=10000,multiline=false,lineHeight=1.35})
    return math.ceil(measured.width or 0)+4
end
function Dashboard:Layout(width,height)
    -- 数字不缩字：窄屏把状态整行移到顶栏下方，避免与手机/暂停和时钟相撞。
    local scale=math.max(.1,UI.GetScale())
    local size=math.max(18,18/scale)
    local w=width or 1280
    if w~=w or w==math.huge or w<=60 then return end
    -- 先比较测量输入，稳定窗口不再每帧进入字体排版器；数字内容不影响固定样本文宽。
    local clockFace=UI.Theme.FontFace(self.clock.props.fontFamily,self.clock.props.fontWeight)
    local meterFace=UI.Theme.FontFace(self.foodValue.props.fontFamily,"normal")
    local speedFace=UI.Theme.FontFace(self.speed.props.fontFamily,self.speed.props.fontWeight)
    local inputKey=table.concat({tostring(w),tostring(height or 720),tostring(scale),
        tostring(UI.Theme.FontSize(size)),clockFace,meterFace,speedFace},":")
    if self.layoutInputKey==inputKey then return end
    self.layoutInputKey=inputKey
    local short=height and height<440 and w>height
    local clockWidth=measuredWidth("00:00",size*1.65,clockFace)
    local inlineWidth=w-(clockWidth+24)-174
    local meterWidth=0
    local meterWidths={}
    for i,sample in ipairs({"100","100","100%"}) do
        local measured=26+measuredWidth(sample,size,UI.Theme.FontFace(self.foodValue.props.fontFamily,"normal"))
        meterWidths[i]=measured
        meterWidth=meterWidth+measured
    end
    local inline=short and inlineWidth>=meterWidth+16
    local compact=not inline and w<760*size/18
    local desired=inline and inlineWidth or compact and math.max(1,w-(short and 224 or 24))
        or math.max(380*size/18,meterWidth+44)
    local stacked=not inline and desired<meterWidth+(compact and 16 or 44)
    -- 宽屏状态栏宽度固定，车速仍需随安全区宽度重新居中。
    local key=string.format("%.2f:%.2f:%.2f:%.2f:%s:%s:%s",w,height or 720,size,desired,tostring(compact),tostring(stacked),tostring(inline))
    if self.layoutKey==key then return end
    self.layoutKey=key
    local valueHeight=lineHeight(self.foodValue,size)
    local clockHeight=lineHeight(self.clock,size*1.65)
    local top=compact and clockHeight+24 or 18
    self.root:SetStyle{width=desired,right=compact and (short and 212 or 12) or 174,top=top}
    self.meters:SetStyle{flexDirection=stacked and "column" or "row",gap=(compact or inline) and 8 or 22}
    for i,body in ipairs(self.meters:GetChildren()) do
        -- 燃油百分比比两项生活数值更宽，不能把顶栏总宽按三等份再截字。
        body:SetStyle{flexBasis=stacked and "auto" or meterWidths[i]}
    end
    self.clock:SetStyle{fontSize=size*1.65,minFontSize=size*1.65,width=clockWidth,height=clockHeight}
    for _,value in ipairs({self.foodValue,self.energyValue,self.batteryValue}) do
        value:SetStyle{fontSize=size,minFontSize=size,height=valueHeight,width="100%",flexShrink=0}
    end
    local speedFont=UI.Theme.FontSize(size*1.8)
    local speedTextWidth=UI.MeasureTextWidth("000 km/h",speedFont,
        UI.Theme.FontFace(self.speed.props.fontFamily,self.speed.props.fontWeight))
    local speedWidth=math.min(math.max(size*11,speedTextWidth+4),math.max(1,w-24))
    local speedHeight=lineHeight(self.speed,size*1.8)
    local speedTop=compact and short and 12 or math.max(12,(height or 720)-22-speedHeight)
    self.speed:SetStyle{fontSize=size*1.8,minFontSize=size*1.8,width=speedWidth,
        height=speedHeight,left=math.max(12,(w-speedWidth)/2),top=speedTop,bottom="auto"}
    self.navigationTop=math.max(12+clockHeight,top+(valueHeight+9)*(stacked and 3 or 1)+(stacked and 16 or 0))+12
    self.actionTop=compact and short and top or self.navigationTop
end
function Dashboard:Update(p,actor)
    self.clock:SetText(Life.Clock(p.time))
    self.foodValue:SetText(string.format("%.0f",p.hunger))
    self.energyValue:SetText(string.format("%.0f",p.energy))
    local electric=actor.vehicleId=="borrowed_ebike"
    local power=electric and p.battery or p.motorcycleFuel or 100
    self.batteryValue:SetText(string.format("%.0f%%",power))
    self.batteryValue:GetChildAt(1):SetStyle{kind=electric and "battery" or "fuel"}
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
