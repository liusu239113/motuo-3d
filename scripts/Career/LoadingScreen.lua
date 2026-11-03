-- 加载专用固定层：进度更新只改已有Label/ProgressBar，不重建弹窗或重算自然高度。
local UI=require("urhox-libs/UI")
local RacingTheme=require("RacingTheme")
local C=RacingTheme.Colors
---@class CareerLoadingScreen
---@field root Panel
---@field body Panel
---@field title Label
---@field detail Label
---@field numbers Label
---@field percent Label
---@field bar ProgressBar
local Loading={}
Loading.__index=Loading
---@return CareerLoadingScreen
function Loading.New()
    local self=setmetatable({},Loading)
    self:Init()
    return self
end
function Loading:Init()
    self.title=RacingTheme.Label("准备南城老街",20,C.white,{id="career-load-title",width="100%",height=52,
        minFontSize=20,lineHeight=1,whiteSpace="nowrap",verticalAlign="middle"})
    self.detail=RacingTheme.Label("正在检查本地资源",11,C.muted,{id="career-load-detail",width="100%",height=48,
        minFontSize=11,lineHeight=1.2,whiteSpace="normal",maxLines=2})
    self.numbers=RacingTheme.Label("等待资源清单",11,C.amber,{id="career-load-numbers",width="78%",height=32,
        minFontSize=11,lineHeight=1,whiteSpace="nowrap",verticalAlign="middle"})
    self.percent=RacingTheme.Label("0%",13,C.white,{id="career-load-percent",position="absolute",right=0,top=0,
        width="22%",height=32,textAlign="right",minFontSize=13,lineHeight=1,verticalAlign="middle"})
    self.bar=UI.ProgressBar{id="career-load-bar",width="100%",height=4,minHeight=4,value=0,max=1,
        fillColor=C.amber,borderRadius=0,showLabel=false}
    self.body=UI.Panel{id="career-load-body",position="absolute",left="5%",right="5%",bottom="6%",
        height=164,padding=0,gap=8,pointerEvents="none",children={self.title,self.detail,self.bar,
            UI.Panel{width="100%",height=32,padding=0,children={self.numbers,self.percent}}}}
    self.root=UI.Panel(RacingTheme.Full{id="career-loading",visible=false,backgroundColor={9,13,17,255},
        backgroundImage=RacingTheme.HeroImage,backgroundFit="cover",children={
            UI.Panel(RacingTheme.Full{pointerEvents="none",backgroundGradient=RacingTheme.Gradient({3,7,10,45},{3,7,10,240})}),
            self.body}})
end
function Loading:Show(title,detail,fraction,numbers)
    self.root:SetVisible(true)
    self.title:SetText(title or "正在准备")
    self.detail:SetText(detail or "")
    local valid=type(fraction)=="number" and fraction==fraction and math.abs(fraction)<math.huge
    local value=valid and math.max(0,math.min(1,fraction)) or 0
    self.bar:SetValue(value)
    self.percent:SetText(string.format("%.0f%%",value*100))
    self.numbers:SetText(numbers or "当前阶段")
end
function Loading:Hide() self.root:SetVisible(false) end
return Loading
