-- 生涯专用视图：沿用钢灰琥珀主题；只发动作，不修改钱包或订单。
local UI = require("urhox-libs/UI")
local Theme = require("RacingTheme")
local Config = require("Career.Config")
local Map = require("Career.MapWidget")
local MapOverlay = require("Career.MapOverlay")
local Progress = require("Career.Progression")
local MobileControls = require("MobileControls")
local ControlSettings = require("ControlSettings")
local Housing = require("Career.HousingData")
local WalkStick = require("Career.WalkStick")
local Phone = require("Career.Phone")
local PhoneApps = require("Career.PhoneApps")
local PhoneKit = require("Career.PhoneKit")
local Engagements = require("Career.Engagements")
local Team = require("Career.Team")
local World = require("Career.WorldData")
local Dashboard = require("Career.LifeDashboard")
local Life = require("Career.LifeStatus")
local LoadingScreen = require("Career.LoadingScreen")
local LineIcon = require("Career.LineIcon")
local C = Theme.Colors
local function label(text,size,color,props) return Theme.Label(text,size or 12,color or C.white,props) end
local function btn(text,click,primary,props)
    props=props or {}
    local width=props.width or "100%"
    return Theme.Button(text,click,primary,width,props)
end
local function hudTouchHeight(size)
    local pixels=UI.Theme.FontSize(size)
    local measured=UI.MeasureTextFit("手机上车交互",{fontSize=pixels,minFontSize=pixels,
        fontFace=UI.Theme.FontFace(nil,"normal"),width=1000,multiline=false,lineHeight=1.4})
    return math.max(PhoneKit.TouchSize(),math.ceil(measured.height or 0)+4)
end
local function hudButton(text,click,id,width)
    local size=math.max(18,18/math.max(.1,UI.GetScale()))
    local touch=hudTouchHeight(size)
    return UI.Button{id=id,text=text,onClick=click,width=width or 80,height=touch,minWidth=touch,minHeight=touch,
        padding=0,paddingHorizontal=0,paddingVertical=0,hoverPadding=0,pressedPadding=0,fontSize=size,
        textColor=C.white,backgroundColor={0,0,0,0},backgroundGradient=false,
        hoverBackgroundColor={0,0,0,70},hoverBackgroundGradient=false,
        pressedBackgroundColor={0,0,0,110},pressedBackgroundGradient=false,
        variantBackgroundGradient={},variantHoverBackgroundGradient={},variantPressedBackgroundGradient={},
        borderWidth=0,borderRadius=0,boxShadow=false,pressedBoxShadow=false}
end
local function full(props) return UI.Panel(Theme.Full(props)) end
local function money(cents) return string.format("¥ %.2f",cents/100) end
---@param parent Widget
local function destroyChildren(parent)
    -- ClearChildren 只脱离父节点；地图切区/切页必须释放旧 Yoga 子树。
    for i=parent:GetNumChildren(),1,-1 do
        local child=parent:GetChildAt(i)
        if child then child:Destroy() end
    end
end
local function mapPosition(state,actor)
    local pos=state.position
    if state.currentSpace and state.currentSpace~="city" then
        return {x=pos.cityX or 0,z=pos.cityZ or -20,yaw=pos.cityYaw or 0}
    end
    return actor or pos
end
local function mapDistricts()
    local districts={World.District(0,0)} -- 老街不是 World.Districts 的外区条目。
    for _,district in ipairs(World.Districts) do districts[#districts+1]=district end
    districts[#districts+1]=World.District(World.LIMIT-1,World.LIMIT-1)
    return districts
end
local function mapDistance(distance)
    return distance>=1000 and string.format("%.1f公里",distance/1000) or string.format("%.0f米",distance)
end
local MAP_PAGE_SIZE=6

---@class CareerView
---@field phoneContent CareerPhonePages
---@field phoneCall? table
---@field phoneDesktop Panel
---@field phoneBack Button
---@field phoneTitle Label
---@field phoneClock Label
---@field phoneChatId string
---@field phoneLedgerId string
---@field phoneWalletFilter string
---@field phoneReadThreads table<string,string>
---@field phoneAppState table
---@field phoneAppOffer table?
---@field phoneAppActive table?
local View = {}
View.__index = View
function View.New(actions)
    local self=setmetatable({},View)
    self:Init(actions)
    return self
end
function View:Init(actions)
    self.actions=actions
    for key,action in pairs(actions) do
        if type(action)=="function" and key~="sound" and key~="saveStatus" then
            actions[key]=function(...)
                if actions.sound then actions.sound() end
                return action(...)
            end
        end
    end
    PhoneApps.Reset(self)
    self.phonePage=""
    -- 只属于本次手机会话，不写入 Store/云档；切页保留，收起后重新定位。
    self.mapDistrictId=""
    self.mapPointPage=1
    self.mapPickerOpen=false
    self.blocked=false
    -- 与原竞速共用组件、图片、多指归属和玩家操作方案；实例分开，避免覆盖旧HUD的控件引用。
    self.controls=MobileControls.New()
    self.controls.lineStyle=true
    self.controlWidth,self.controlHeight=0,0
    self.mountedControls=false
    self.lookPointer=-1
    self.lookX,self.lookY,self.lookDeltaX,self.lookDeltaY=0,0,0,0
    self.root=UI.Panel{width="100%",height="100%",padding=0,pointerEvents="box-none"}
    self.home=full{backgroundImage=Theme.HeroImage,backgroundFit="cover",backgroundColor={9,13,17,255},padding=32,gap=12}
    self.home:AddChild(full{pointerEvents="none",backgroundGradient={type="linear",direction="to-right",
        from={3,7,10,210},to={3,7,10,0}}})
    self.home:AddChild(Theme.Kicker("ROAD TO THE GRID  /  从生活驶向赛场"))
    self.home:AddChild(label("公路狂飙",46,C.white,{fontWeight="bold"}))
    self.home:AddChild(label("从外卖骑手到职业车手",20,C.amber))
    self.home:AddChild(label("王二狗的故事，从兜里的50元开始。",13,C.muted))
    self.homeActions=UI.Panel{width=340,maxWidth="100%",gap=10,padding=0}
    self.home:AddChild(self.homeActions)
    self.home:AddChild(label("生涯现金与旧竞速金币分别保存。驾驶仅限游戏，请勿现实模仿。",10,C.muted,{whiteSpace="normal"}))
    self.game=full{visible=false,pointerEvents="box-none",padding=0}
    local safe=UI.SafeAreaView{width="100%",height="100%",nativeMenuInset=true,padding=12,pointerEvents="box-none"}
    self.hudSafe=safe
    self.dashboard=Dashboard.New()
    self.objective=PhoneKit.Text("",20,C.white,{id="career-hud-objective",fontWeight="normal",
        textStroke={width=1,color={0,0,0,230}},textShadow={offsetX=0,offsetY=2,blur=0,color={0,0,0,230}}})
    self.hint=PhoneKit.Text("",10,C.white,{id="career-hud-hint"})
    self.deliveryStatus=PhoneKit.Text("",18,C.amber,{id="career-hud-delivery",fontWeight="normal",
        textStroke={width=1,color={0,0,0,230}},textShadow={offsetX=0,offsetY=2,blur=0,color={0,0,0,230}}})
    self.map=Map.New("career-minimap")
    self.map.root:SetStyle{width="100%",height=88,padding=0,borderWidth=0,borderRadius=0,
        backgroundColor={7,12,16,190},backgroundGradient=false,boxShadow=false}
    self.map.scaleLabel:SetVisible(false)
    self.map.edgeDistance:SetVisible(false)
    self.mapCaption=PhoneKit.Text("附近街区 · 南城老街",10,C.white,{id="career-minimap-caption"})
    self.mapOpenHint=PhoneKit.Text("点开全城地图",9,C.cyan,{id="career-map-open-hint"})
    self.mapOpen=UI.Panel{id="career-minimap-open",width="100%",minHeight=44,padding=0,gap=3,
        pointerEvents="box-only",onClick=function()
            if self.lastActor and math.abs(self.lastActor.speed)>.35 then self:Notice("请先停稳再打开地图"); return end
            if not self:IsBlocking() then self:OpenWorldMap() end
        end,children={self.mapCaption,self.map.root,self.mapOpenHint}}
    self.navText=UI.Panel{width="100%",padding=0,gap=10,pointerEvents="box-none",
        children={self.objective,self.deliveryStatus,self.hint}}
    self.navPanel=UI.Panel{id="career-navigation-card",position="absolute",left=12,top=12,width=192,padding=0,gap=5,
        backgroundColor={0,0,0,0},pointerEvents="box-none",children={self.mapOpen,self.navText}}
    self.pauseButton=hudButton("Ⅱ",actions.pause,"career-hud-pause",52)
    self.pauseButton:SetStyle{position="absolute",right=12,top=12}
    self.menuButton=hudButton("手机",function() actions.phone("apps") end,"career-phone",80)
    self.menuButton:SetStyle{position="absolute",right=74,top=12}
    self.menuButton:SetStyle{paddingLeft=24}
    self.menuButton:AddChild(LineIcon{kind="phone",position="absolute",left=0,top="25%",width=22,height="50%",pointerEvents="none"})
    -- 空白画面支持单指拖动视角，其他手指仍可独立持有转向与踏板。
    self.lookArea=UI.Panel(Theme.Full{pointerEvents="box-only",
        onPointerDown=function(event)
            if self:IsBlocking() or self.lookPointer~=-1 or (not event:IsTouch() and not event:IsPrimaryButton()) then return end
            self.lookPointer=event.pointerId; self.lookX,self.lookY=event.x,event.y
        end,
        onPointerMove=function(event)
            if self.lookPointer~=event.pointerId then return end
            self.lookDeltaX=self.lookDeltaX+event.x-self.lookX
            self.lookDeltaY=self.lookDeltaY+event.y-self.lookY
            self.lookX,self.lookY=event.x,event.y
        end,
        onPointerUp=function(event) if self.lookPointer==event.pointerId then self.lookPointer=-1 end end,
        onPointerCancel=function(event) if self.lookPointer==event.pointerId then self.lookPointer=-1; self.lookDeltaX,self.lookDeltaY=0,0 end end})
    self.game:AddChild(self.lookArea)
    self.controlLayer=UI.Panel(Theme.Full{pointerEvents="box-none"})
    for _,widget in ipairs({self.controls:CreateSteering(),self.controls:CreatePedal("brake"),self.controls:CreatePedal("gas")}) do
        widget:SetStyle{position="absolute",left=0,top=0}
        self.controlLayer:AddChild(widget)
    end
    self.walkStick=WalkStick.New(function() return self:IsBlocking() or self.mountedControls end)
    self.controlLayer:AddChild(self.walkStick.root)
    safe:AddChild(self.controlLayer)
    safe:AddChild(self.navPanel)
    safe:AddChild(self.dashboard.root)
    safe:AddChild(self.dashboard.clock)
    safe:AddChild(self.dashboard.speed)
    safe:AddChild(self.pauseButton)
    safe:AddChild(self.menuButton)
    self.mountButton=hudButton("上车",actions.mount,"career-mount",80)
    self.interactButton=hudButton("交互",actions.interact,"career-interact",80)
    for _,item in ipairs({{button=self.mountButton,kind="bike"},{button=self.interactButton,kind="interact"}}) do
        item.button:SetStyle{paddingLeft=24}
        item.button:AddChild(LineIcon{kind=item.kind,position="absolute",left=0,top="25%",width=22,height="50%",pointerEvents="none"})
    end
    self.actionTray=UI.Row{position="absolute",right=12,top="50%",gap=24,padding=0,
        backgroundColor={0,0,0,0},pointerEvents="box-none",children={self.mountButton,self.interactButton}}
    safe:AddChild(self.actionTray)
    -- 生涯只留大字操作名称，删除踏板上的重复教程小字；竞速模式不受影响。
    for _,key in ipairs({"gas","brake"}) do
        self.controls.captions[key]:SetStyle{fontSize=18,height=30}
        self.controls.details[key]:SetVisible(false)
    end
    self.controlHint=label("左右滑动转向 · 按住前进 · 松手停步 · 滑动画面看四周",10,C.muted,
        {position="absolute",bottom=12,left="28%",right="24%",textAlign="center",whiteSpace="normal",pointerEvents="none"})
    safe:AddChild(self.controlHint)
    self.game:AddChild(safe)
    self.phone=UI.SafeAreaView(Theme.Full{nativeMenuInset=true,visible=false,backgroundColor={3,6,9,150},alignItems="flex-end",justifyContent="center",
        paddingLeft=12,paddingRight=12,paddingTop=8,paddingBottom=8})
    -- 百分比宽高容器先获得SafeAreaView内容尺寸；无需更改UI.Scale.DEFAULT。
    self.phoneArea=UI.Panel{width="100%",height="100%",padding=0,alignItems="flex-end",justifyContent="center",pointerEvents="box-none"}
    self.phoneBody=Phone.Create(self,actions)
    self.phoneArea:AddChild(self.phoneBody)
    self.phone:AddChild(self.phoneArea)
    self.phoneWidth,self.phoneHeight=0,0
    self.phoneArea.Update=function(area)
        local bounds=area:GetLayout()
        Phone.Layout(self,bounds.w,bounds.h)
    end
    self.overlay=full{visible=false,backgroundColor={3,6,9,225},justifyContent="center",alignItems="center",padding=22}
    self.dialogBody=UI.Panel{width=520,maxWidth="100%",maxHeight="100%",padding=22,gap=14,
        backgroundColor=C.dark,borderColor=C.border,borderWidth=1}
    self.overlay:AddChild(self.dialogBody)
    self.notice=label("",12,C.amber,{position="absolute",top=12,left="30%",right="22%",whiteSpace="normal",textAlign="center",maxLines=3})
    self.root:AddChild(self.home); self.root:AddChild(self.game); self.root:AddChild(self.phone)
    self.root:AddChild(self.overlay); self.root:AddChild(self.notice)
    self.loadingScreen=LoadingScreen.New()
    self.root:AddChild(self.loadingScreen.root)
    self.worldMap=MapOverlay.New(function() self:CloseWorldMap() end,function(id)
        self.actions.setWaypoint(id)
        self:CloseWorldMap()
    end)
    self.root:AddChild(self.worldMap.root)
    self.conversation=UI.SafeAreaView(Theme.Full{nativeMenuInset=true,visible=false,padding=18,
        justifyContent="flex-end",alignItems="center",backgroundColor={0,0,0,25}})
    self.conversationBody=UI.Panel{id="career-conversation",width=620,maxWidth="92%",maxHeight="88%",
        padding=12,gap=6,backgroundColor={10,16,21,238},borderColor=C.border,borderWidth=1}
    self.conversation:AddChild(self.conversationBody)
    self.root:AddChild(self.conversation)
    self.speech=UI.Panel{id="career-street-speech",position="absolute",bottom="20%",left="24%",right="24%",
        visible=false,padding=10,backgroundColor={10,16,21,220},pointerEvents="none"}
    self.speechText=label("",13,C.white,{whiteSpace="normal",maxLines=3,textAlign="center"})
    self.speech:AddChild(self.speechText); self.root:AddChild(self.speech)
    self.speechTime=0
end
function View:OpenWorldMap()
    self:ClosePhone();self:CloseConversation()
    self.overlay:SetVisible(false);self.speech:SetVisible(false);self.notice:SetText("")
    self.blocked=true;self:ResetInput();self.controls:SetEnabled(false)
    local mapTarget=self.lastTarget
    if self.lastIndoor then mapTarget=nil end
    self.worldMap:Open(self.lastMapPosition or {x=0,z=-20,yaw=0},mapTarget,self.lastOrder)
end
function View:CloseWorldMap()
    self.worldMap:Close()
    self.blocked=self.overlay:IsVisible() or self.conversation:IsVisible()
    self:ResetInput()
    self.controls:SetEnabled(self.game:IsVisible() and self.phonePage=="" and not self.blocked)
end
function View:CloseConversation()
    self.conversation:SetVisible(false)
    destroyChildren(self.conversationBody)
    self.blocked=self.overlay:IsVisible()
    self.controls:SetEnabled(self.game:IsVisible() and self.phonePage=="" and not self.blocked)
end
function View:ShowConversation(name,text,choices)
    self:CloseWorldMap()
    self:ClosePhone(); self.overlay:SetVisible(false)
    self:ResetInput(); self.controls:SetEnabled(false); self.blocked=true
    self.speech:SetVisible(false); self.speechTime=0
    destroyChildren(self.conversationBody)
    self.conversationBody:AddChild(label("现场交谈 · "..name,17,C.amber,{id="career-conversation-name",fontWeight="bold"}))
    self.conversationBody:AddChild(label(text,13,C.white,{id="career-conversation-line",whiteSpace="normal",maxLines=4}))
    local options=UI.Row{id="career-conversation-options",width="100%",flexWrap="wrap",gap=6,padding=0,
        paddingBottom=2/math.max(.1,UI.GetScale())}
    self.conversationBody:AddChild(options)
    for _,choice in ipairs(choices) do
        local touch=PhoneKit.TouchSize()
        local pixels=UI.Theme.FontSize(12)
        local measured=UI.MeasureTextWidth(choice.text,pixels,UI.Theme.FontFace(nil,"bold"))
        -- 按真实文案保留最小宽度；竖屏容不下并排按钮时整项换行，不缩字或截断。
        options:AddChild(btn(choice.text,function()
            self:CloseConversation()
            if choice.onClick then choice.onClick() end
        end,choice.primary,{id="career-conversation-"..choice.id,width="48%",flexGrow=1,flexShrink=0,
            height=touch,minHeight=touch,minWidth=math.max(touch,math.ceil(measured)+36),padding=5,fontSize=12,minFontSize=12}))
    end
    self.conversation:SetVisible(true)
end
function View:Say(name,text)
    self.speechText:SetText(name.."："..text)
    self.speech:SetVisible(true); self.speechTime=5
end
function View:UpdateSpeech(dt)
    if self.speechTime<=0 or self:IsBlocking() then return end
    self.speechTime=math.max(0,self.speechTime-dt)
    if self.speechTime==0 then self.speech:SetVisible(false) end
end
function View:ShowHome(hasSave,message)
    self.loadingScreen:Hide()
    self:CloseWorldMap()
    self:CloseConversation(); self.speech:SetVisible(false); self.speechTime=0
    self:ClosePhone()
    self.home:SetVisible(true); self.game:SetVisible(false); self.phone:SetVisible(false); self.overlay:SetVisible(false)
    self.phonePage=""; self.blocked=true; self.controls:SetEnabled(false)
    destroyChildren(self.homeActions)
    self.homeActions:AddChild(btn(hasSave and "继续王二狗的生涯" or "开始生涯 · 身上只有50元",function() self.actions.startCareer(false) end,true,{id="career-start"}))
    if hasSave then self.homeActions:AddChild(btn("重新开始生涯",function() self.actions.startCareer(true) end,false)) end
    self.homeActions:AddChild(btn("独立竞速 / 旧存档",self.actions.legacy,false))
    if message then self.homeActions:AddChild(label(message,10,C.muted,{whiteSpace="normal"})) end
end
function View:ShowGame()
    self.loadingScreen:Hide()
    self:CloseWorldMap()
    self:CloseConversation()
    self.home:SetVisible(false); self.game:SetVisible(true); self.overlay:SetVisible(false)
    self.controlWidth,self.controlHeight=0,0
    self.blocked=false; self.controls:SetEnabled(self.phonePage=="")
end
function View:ShowLoading(title,detail,fraction,numbers)
    if not self.loadingScreen.root:IsVisible() then
        self:CloseWorldMap(); self:CloseConversation(); self:ClosePhone()
        self:ResetInput(); self.controls:SetEnabled(false)
        self.overlay:SetVisible(false); self.speech:SetVisible(false); self.notice:SetText("")
        self.speechTime=0; self.blocked=true
        if self.actions.endCall then self.actions.endCall() end
        print("[生涯加载] 固定背景与状态区已打开；后续进度只更新已有控件")
    end
    self.loadingScreen:Show(title,detail,fraction,numbers)
end
function View:ShowDialog(title,text,buttons,forceScroll)
    self.loadingScreen:Hide()
    self:CloseWorldMap()
    self:CloseConversation(); self.speech:SetVisible(false); self.speechTime=0
    self:ResetInput(); self.controls:SetEnabled(false)
    if self.actions.endCall then self.actions.endCall() end
    self.blocked=true; self.phone:SetVisible(false); self.overlay:SetVisible(true)
    destroyChildren(self.dialogBody)
    local _,lineBreaks=text:gsub("\n","")
    local scrollable=forceScroll or #text>220 or lineBreaks>=7
    self.dialogBody:SetStyle{height=scrollable and "90%" or "auto"}
    self.dialogBody:AddChild(PhoneKit.Text(title,21,C.amber,{fontWeight="bold",flexShrink=0}))
    if scrollable then
        local content=require("Career.PhonePages"){id="career-dialog-pages",width="100%",flexGrow=1,flexBasis=0,minHeight=0,
            padding=0,overflow="hidden"}
        content:AddChild(PhoneKit.Text(text,13,C.white,{id="career-dialog-text"}))
        self.dialogBody:AddChild(content)
        local previous=PhoneKit.Button("上一页",function() content:SetPage(content:GetPage()-1) end,"career-dialog-prev",false,{width=90})
        local following=PhoneKit.Button("下一页",function() content:SetPage(content:GetPage()+1) end,"career-dialog-next",false,{width=90})
        local pageLabel=PhoneKit.Text("1 / 1",12,C.white,{width="auto",flexBasis=0,minWidth=0,flexShrink=1,
            flexGrow=1,height=PhoneKit.TouchSize(),verticalAlign="middle",textAlign="center"})
        local pager=UI.Row{width="100%",padding=0,gap=8,flexShrink=0,alignItems="center",children={previous,pageLabel,following}}
        self.dialogBody:AddChild(pager)
        content:AttachPager(previous,following,pageLabel,pager)
        content:Paginate()
    else
        self.dialogBody:AddChild(PhoneKit.Text(text,13,C.white,{id="career-dialog-text"}))
    end
    for _,item in ipairs(buttons) do
        self.dialogBody:AddChild(btn(item.text,function()
            self.overlay:SetVisible(false); self.blocked=false
            self.phone:SetVisible(self.phonePage~="")
            self.controls:SetEnabled(self.game:IsVisible() and self.phonePage=="")
            if item.onClick then item.onClick() end
        end,item.primary))
    end
end
function View:Notice(text)
    self.notice:SetText(text or ""); self.noticeTime=5
    print("[生涯提示] "..tostring(text))
end
function View:IsBlocking() return self.blocked or self.phonePage~="" or self.worldMap:IsVisible() end
function View:ClosePhone()
    if self.actions.endCall then self.actions.endCall() end
    self.phone:SetVisible(false); self.phonePage=""; self:ResetInput()
    destroyChildren(self.phoneContent)
    destroyChildren(self.phoneDesktop)
    self.phoneContent:ScrollToTop()
    self.mapDistrictId=""; self.mapPointPage=1; self.mapPickerOpen=false
    PhoneApps.Reset(self)
    self.controls:SetEnabled(self.game:IsVisible() and not self.blocked)
end
function View:OpenPhone(page,state,offer,active)
    if page=="map" then self:OpenWorldMap();return end
    self:CloseWorldMap()
    self:CloseConversation(); self.overlay:SetVisible(false); self.blocked=false
    self.speech:SetVisible(false); self.speechTime=0
    if self.phonePage=="" then
        self.mapDistrictId=""; self.mapPointPage=1; self.mapPickerOpen=false
    end
    if self.phonePage=="call" and page~="call" and self.actions.endCall then self.actions.endCall() end
    if self.phonePage~=(page or "apps") then self.phoneContent:ScrollToTop() end
    self:ResetInput(); self.controls:SetEnabled(false); self.phonePage=page or "apps"; self.phone:SetVisible(true)
    self:BuildPhone(state,offer,active)
end
-- 地图主体只在切页时创建；切区/分页只重建小型地点树，概览与区域选择器不重建。
function View:BuildMapPhone(content,state,active)
    local pos=mapPosition(state,self.lastActor)
    local current=World.District(pos.x,pos.z)
    local districts=mapDistricts()
    local selected=current
    for _,district in ipairs(districts) do
        if district.id==self.mapDistrictId then selected=district; break end
    end
    self.mapDistrictId=selected.id
    local k=PhoneKit
    content:AddChild(k.Heading("南城地图","按城市位置计距 · 导航不传送","career-map-heading"))
    content:AddChild(k.Text("当前区 · "..current.label,12,k.C.green,{id="career-map-current"}))
    if state.currentSpace and state.currentSpace~="city" then
        content:AddChild(k.Text("室内 · 按城市入口定位与计距；请先到房门旁出门，再沿城市导航前往。",11,k.C.orange,
            {id="career-map-indoor"}))
    end
    local selection=k.Card("career-map-selection-card")
    local selectedName=k.Text("",13,k.C.ink,{id="career-map-selection-name",fontWeight="bold"})
    selection:AddChild(selectedName)
    local chooser=k.Button("选择区域",function() end,"career-map-region-toggle",false)
    selection:AddChild(chooser); content:AddChild(selection)
    local coast=k.Card("career-map-coast",{children={k.Text("海滨步道",13,k.C.ink,{fontWeight="bold"}),
        k.Text("观景台、沙滩与栈桥 · 随时可查，不受区域分页影响。",10,k.C.muted)}})
    for _,place in ipairs(require("Career.CityEnvironment").Points) do
        local id=place.id
        coast:AddChild(k.Text(place.label,12,k.C.ink,{id="career-map-coast-title-"..id,fontWeight="bold"}))
        coast:AddChild(k.Text("直线 "..mapDistance(math.sqrt((place.x-pos.x)^2+(place.z-pos.z)^2)),10,k.C.muted))
        coast:AddChild(k.Button("前往海滨",function() self.actions.setWaypoint(id); self.actions.closePhone() end,
            "career-map-coast-"..id,false))
    end
    -- 12个外区加老街/绿带；标题可完整换行，动作只用短文字。
    local picker=UI.Panel{id="career-map-regions",width="100%",padding=0,gap=7,visible=self.mapPickerOpen}
    content:AddChild(picker)
    content:AddChild(coast)
    local points=UI.Panel{id="career-map-points",width="100%",padding=0,gap=9}
    content:AddChild(points)
    local function updateChooser()
        selectedName:SetText("所选区域\n"..selected.label..(selected.id==current.id and " · 当前区" or ""))
        chooser:SetText(self.mapPickerOpen and "收起区域" or "选择区域")
        picker:SetVisible(self.mapPickerOpen)
    end
    local function refreshPoints()
        destroyChildren(points)
        ---@type CareerPoint[]
        local matches={}
        for _,point in ipairs(Config.pointList) do
            if selected.id=="greenbelt" or World.District(point.x,point.z).id==selected.id then
                matches[#matches+1]=point
            end
        end
        table.sort(matches,function(left,right)
            local a=(left.x-pos.x)^2+(left.z-pos.z)^2
            local b=(right.x-pos.x)^2+(right.z-pos.z)^2
            return a==b and left.id<right.id or a<b
        end)
        if selected.id=="greenbelt" then
            while #matches>4 do table.remove(matches) end
        end
        local pages=math.max(1,math.ceil(#matches/MAP_PAGE_SIZE))
        self.mapPointPage=math.max(1,math.min(self.mapPointPage,pages))
        points:AddChild(k.Text(selected.label.." · "..#matches.."处"..(selected.id==current.id and " · 当前区" or ""),13,k.C.green,
            {id="career-map-selected",fontWeight="bold"}))
        points:AddChild(k.Text(selected.id=="greenbelt"
            and "绿带无固定服务点：以下为距你最近的4处真实地点，按所属区标注。"
            or "按距你远近排列；距离为直线参考，不是道路里程。",10,k.C.muted,
            {id="career-map-distance-note"}))
        if selected.id=="greenbelt" then
            points:AddChild(k.Text("跨区距离按你当前城市位置计算（室内按入口）；不代表绿带内有店。",10,k.C.muted))
        end
        local first=(self.mapPointPage-1)*MAP_PAGE_SIZE+1
        for index=first,math.min(#matches,first+MAP_PAGE_SIZE-1) do
            local point=assert(matches[index])
            local id=point.id
            local district=World.District(point.x,point.z)
            local distance=math.sqrt((point.x-pos.x)^2+(point.z-pos.z)^2)
            local card=k.Card("career-map-place-card-"..id)
            card:AddChild(k.Text(point.label,13,k.C.ink,{id="career-map-place-title-"..id,fontWeight="bold"}))
            card:AddChild(k.Text((district.id~=current.id and "跨区 · "..district.label.."\n" or "本区 · ")
                .."直线 "..mapDistance(distance),10,k.C.muted,{id="career-map-distance-"..id}))
            card:AddChild(k.Button("设为导航",function() self.actions.setWaypoint(id); self.actions.closePhone() end,
                "career-map-poi-"..id,true))
            points:AddChild(card)
        end
        if pages>1 then
            points:AddChild(k.Text(string.format("地点 %d/%d 页 · 每页最多%d处",self.mapPointPage,pages,MAP_PAGE_SIZE),10,k.C.muted,
                {id="career-map-pagination"}))
            local nav=UI.Row{width="100%",gap=5,padding=0}
            local function turn(delta)
                self.mapPointPage=self.mapPointPage+delta
                refreshPoints()
            end
            nav:AddChild(k.Button("上一页",function() turn(-1) end,"career-map-prev",false,{width="48%",
                disabled=self.mapPointPage==1,padding=0}))
            nav:AddChild(k.Button("下一页",function() turn(1) end,"career-map-next",false,{width="48%",
                disabled=self.mapPointPage==pages,padding=0}))
            points:AddChild(nav)
        end
    end
    chooser.props.onClick=function()
        self.mapPickerOpen=not self.mapPickerOpen
        updateChooser()
    end
    for _,district in ipairs(districts) do
        local choice=district
        picker:AddChild(k.ActionCard("career-map-region-"..choice.id,choice.label,
            choice.id==current.id and "当前区 · 你所在的城市区域" or "切换地点列表，不会移动人物",nil,"查看地点",function()
            selected=choice; self.mapDistrictId=choice.id; self.mapPointPage=1; self.mapPickerOpen=false
            updateChooser(); refreshPoints(); self.phoneContent:ScrollToTop()
        end,false))
    end
    updateChooser(); refreshPoints()
    content:AddChild(k.Text("全城概览 · 30公里跨度",12,k.C.green,{id="career-map-overview-title"}))
    local map=Map.New("career-phone-map",true)
    map.root:SetStyle{width="100%",height=220}
    content:AddChild(map.root)
    local target=self.lastTarget
    if state.currentSpace and state.currentSpace~="city" then target=nil end
    map:SetTelemetry(pos,target,active)
    content:AddChild(k.Text("全城道路连通，亲自骑行探索；主屏小地图跟随当前位置。",11,k.C.muted))
end
function View:BuildPhone(state,offer,active)
    print("[生涯手机] 构建页面 "..self.phonePage)
    destroyChildren(self.phoneContent)
    destroyChildren(self.phoneDesktop)
    local page=self.phonePage
    local desktop=page=="apps"
    self.phoneDesktop:SetVisible(desktop)
    self.phoneContent:SetVisible(not desktop)
    self.phoneBack:SetVisible(not desktop)
    local content=UI.Panel{width="100%",padding=0,gap=desktop and 4 or 11}
    if desktop then
        content:SetStyle{height="100%",minHeight=0}
        self.phoneDesktop:AddChild(content)
    else self.phoneContent:AddChild(content) end
    local a=self.actions
    self.phoneAppState,self.phoneAppOffer,self.phoneAppActive=state,offer,active
    self.phoneBack:SetText("首页")
    local modern=page~="apps"
    local target=content
    local function section(title)
        target=UI.Panel{width="100%",padding=0,gap=9}
        content:AddChild(target)
        target:AddChild(PhoneKit.Text(title,13,PhoneKit.C.ink,{fontWeight="bold"}))
    end
    local function action(id,title,description,terms,caption,fn,primary)
        target:AddChild(PhoneKit.ActionCard(id,title,description,terms,caption,fn,primary))
    end
    local function text(t,size,color)
        target:AddChild(modern and PhoneKit.Text(t,size and math.min(size,16) or 11,
            color==C.amber and PhoneKit.C.green or color==C.muted and PhoneKit.C.muted or PhoneKit.C.ink)
            or label(t,size,color,{whiteSpace="normal"}))
    end
    local function button(t,fn,primary,id)
        target:AddChild(modern and PhoneKit.Button(t,fn,id,primary) or btn(t,fn,primary,{id=id,minHeight=44}))
    end
    content:SetStyle{padding=desktop and 0 or modern and 8 or 9,borderRadius=10,
        backgroundColor=desktop and {0,0,0,0} or modern and PhoneKit.C.paper or {8,19,27,238}}
    UI.Widget.SetStyle(self.phoneContent,{backgroundColor=modern and PhoneKit.C.paper or {0,0,0,0},borderRadius=10})
    self.phoneTitle:SetText(({apps="手机桌面",delivery="外卖骑手",map="南城地图",wallet="钱包",messages="消息",life="生活",progression="生涯发展"})[page] or "手机")
    self.phoneClock:SetText(string.format("%02d:%02d",math.floor(state.time),math.floor(state.time*60)%60))
    if page=="apps" then
        Phone.Desktop(content,state,a,self.phoneHeight)
    elseif page=="call" then
        PhoneApps.Call(self,content)
    elseif page=="delivery" then
        PhoneApps.Delivery(self,content,state,offer,active)
    elseif page=="map" then
        self:BuildMapPhone(content,state,active)
    elseif page=="wallet" then
        PhoneApps.Wallet(self,content,state)
    elseif page=="messages" then
        PhoneApps.Messages(self,content,state)
    elseif page=="property-confirm" then
        local property=require("Career.Property").Get(state,self.purchaseHomeId or "")
        if property then
            self.phoneTitle:SetText("买断确认")
            text(property.name,18)
            text(string.format("一次买断 ¥%.0f\n购后至少保留 ¥%.0f 生活费",property.buyPriceCents/100,property.reserveCents/100),15)
            local value=require("Career.Property").Value(state,property.id)
            text("游戏内固定定价，非现实房价。取得永久产权后，对应住处免每晚房费；不会自动入住或移动人物。",13)
            if value then text(value.detail..string.format("\n按租金折合约%d晚；不是快速回本投资，也没有被动收入。",value.rentEquivalentNights or 0),12,C.muted) end
            button("确认买断",function() a.confirmBuyHome(property.id) end,true,"career-property-confirm")
            button("先不买",function() a.phone("progression") end,false,"career-property-cancel")
        end
    elseif page=="progression" then
        text(Progress.Chapter(state),17,C.amber)
        local goal=Progress.NextGoal(state)
        action("career-next-goal",goal.title,goal.detail,nil,"导航到下一步",function()
            if goal.pointId then a.setWaypoint(goal.pointId);a.closePhone() end
        end,true)
        local forecast=Progress.ProgressForecast(state)
        text(string.format("首车资金 %.2f / %.2f 元",state.cashCents/100,forecast.targetCents/100),13,C.amber)
        text(forecast.assumptions,11,C.muted)
        local level,name=Progress.Level(state)
        text(string.format("%s Lv.%d · 携带容量%d份",name,level,Progress.Capacity(state)),13)
        text("装备、买车与职业报名需到南城车行；住房可在手机选择，再去对应入口入住。",11,C.muted)
        button("导航到南城车行",function() a.setWaypoint("dealer"); a.closePhone() end,true)
        section("骑手装备")
        for _,item in ipairs(Progress.Equipment) do
            local id=item.id
            local owned=state.equipment and state.equipment[id]
            action("career-equipment-"..id,item.name,item.description,
                string.format("价格 ¥%.0f\n要求 Lv.%d · %s",item.price/100,item.level,owned and "已拥有" or "到南城车行办理"),
                owned and "已拥有" or "购入装备",function() a.buyEquipment(id) end,false)
        end
        section("选择住处 · 产权与住宿分开")
        text("旅舍、出租屋、公寓各有入口和室内。进门不收费，到床边休息才支付当晚费用；自有房免房费。",10,C.muted)
        local Property=require("Career.Property")
        for _,item in ipairs(Progress.Housing) do
            local id=item.id
            local owned=Property.Owns(state,id)
            action("career-housing-"..id,item.name,"选择后到对应入口入住；不会移动人物。",
                string.format("%s · %s",owned and "自有房 · 免房费" or string.format("¥%.0f / 晚",item.price/100),state.accommodation==id and "当前住处" or "可选择"),
                "选择住处",function() a.housing(id) end,false)
        end
        section("买一套自己的房")
        text(Property.PRICE_NOTE,12,C.muted)
        for _,property in ipairs(Property.List(state)) do
            local id=property.id
            action("career-property-"..id,property.name,property.owned and "永久产权已登记；选择该住处后免每晚房费。" or "买断后永久拥有；仍需亲自前往入口入住。",
                string.format("游戏买断价 ¥%.0f · %s",property.buyPriceCents/100,property.owned and "已拥有" or "未购入"),
                property.owned and "选择自有房" or "查看买断",function() if property.owned then a.housing(id) else a.buyHome(id) end end,false)
        end
        local home=assert(Housing.Get(state.accommodation))
        button("导航到当前住处",function() a.setWaypoint(home.point); a.closePhone() end,false)
        if home.width then button("到门口进入住处",a.enterHousing,false) end
        button("到休息点过夜",a.sleepHousing,false)
        section("工作周 · 解锁后可选")
        text("第10天起开放，每周需重新亲送10单并活动15分钟。亲送仅作资格，安排的是未来完整7天，过往亲送不再抵扣模拟单。",11,C.muted)
        local week=Progress.WorkWeekPreview(state)
        text(string.format("未来7天：%d单 · 收入%.2f元 · 总成本%.2f元 · 净存%.2f元",week.simulatedOrders,week.grossCents/100,week.costsCents/100,week.netCents/100),12,C.amber)
        button("查看并确认7天排班",a.workWeek,false)
        section("人生第一辆摩托")
        text("现金达到5万元后首购二手训练版：46000元；另备2000元护具训练、2000元周转。",11,C.muted)
        for _,item in ipairs(Progress.Motorcycles) do
            local id=item.id
            local owned=state.ownedMotorcycles[id]
            action("career-motorcycle-"..id,item.name,
                owned and (state.raceVehicle==id and "当前参赛车辆" or "已拥有 · 可选为参赛车")
                    or "首辆摩托需先攒够5万元，并购买二手训练版。",
                string.format("价格 ¥%.0f\n到南城车行停稳下车办理",item.price/100),
                owned and "选为参赛车" or "购买车辆",function()
                    if owned then a.selectMotorcycle(id) else a.buyMotorcycle(id) end
                end,false)
        end
        section("城市车库 · 到车行取车")
        target:AddChild(PhoneKit.Text("摩托城市限速60km/h，电动车35km/h。换车不召回：原车留在停车处；接单前需换回带箱9号。燃油独立于电量，摩托共享油量。",11,PhoneKit.C.muted,
            {id="career-garage-description"}))
        action("career-city-ebike","9号电动车","带保温箱的配送用车；需到车行切换。",nil,"切换用车",
            function() a.cityVehicle("borrowed_ebike") end,false)
        for _,item in ipairs(Progress.Motorcycles) do
            if state.ownedMotorcycles[item.id] then
                local id=item.id
                action("career-city-"..id,item.name,"城市用车 · 原车留在停车处。",nil,"切换用车",function() a.cityVehicle(id) end,false)
            end
        end
        action("career-refuel","摩托燃油补给","到南城车行停稳下车补给。",
            string.format("费用 ¥20\n当前油量 %.0f%%",state.motorcycleFuel or 100),"补给燃油",a.refuel,false)
        action("career-training","封闭场地训练","护具课程；完成训练才获得职业资格。",
            string.format("课程费用 ¥%.0f\n另需保留 ¥2000 生活周转金",state.equipment and state.equipment.helmet and 1550 or 2000),
            "报名训练",a.train,true)
        section("车队与赞助 · 正式合同")
        local contract=Team.Status(state)
        text(contract.text,12,C.white)
        if contract.signed then
            if contract.canClaim then button("到车行领取本轮赞助",a.claimTeam,true,"career-team-claim") end
        else
            for _,offer in ipairs(Team.Offers(state)) do
                local id=offer.id
                text(offer.name.." / "..offer.sponsor,13,C.amber)
                text(offer.description,11,C.muted)
                button("到车行查看并签约",function() a.signTeam(id) end,false,"career-team-sign")
            end
        end
        section("职业赛事")
        text(string.format("积分 %d · 冠军 %d · %s",state.career and state.career.points or 0,state.career and state.career.wins or 0,state.career and state.career.team or "尚未加入车队"),12)
        for index,series in ipairs(Progress.Series) do
            local n=index
            action("career-series-"..series.id,series.name,"到南城车行报名；职业资格与积分仍由现场核验。",
                string.format("报名费 ¥%.0f\n要求 %d 积分 · %d 圈",series.fee/100,series.required,series.laps),
                "报名赛事",function() a.race(n) end,false)
        end
        if state.career and state.career.pending then button("继续已报名的赛事",function() a.race(state.career.pending.series) end,true) end
        if state.flags.lifeWinner then
            text("王二狗：从桥洞到自己的住处，从战损电动车到冠军发车格。人生没有白跑的路。\n年度冠军达成，仍可继续配送、改善生活、收藏车辆和参加比赛。",14,C.amber)
        end
    elseif page=="life" then
        section("生活仪表盘")
        local advice=Life.Advice(state)
        local function navigate(point)
            a.setWaypoint(point);a.closePhone()
            if state.currentSpace and state.currentSpace~="city" then
                self:Notice("导航已保留：先到房门出门，出门后继续前往目的地。")
            end
        end
        target:AddChild(PhoneKit.Card("career-life-summary",{children={
            PhoneKit.Text(Life.Clock(state.time),30,PhoneKit.C.ink,{id="career-life-clock",fontWeight="bold"}),
            PhoneKit.Text(string.format("第%d天 · %s · %s",state.day,Life.Part(state.time),state.weatherLabel or "晴朗"),11,PhoneKit.C.blue),
            PhoneKit.Text(advice.title,15,advice.urgent and PhoneKit.C.red or PhoneKit.C.green,{id="career-life-advice",fontWeight="bold"}),
            PhoneKit.Text(advice.detail,11,PhoneKit.C.muted),
            PhoneKit.Button(advice.action=="继续配送" and "继续当前配送" or advice.point=="breakfast" and "导航去吃饭" or "导航去休息",function()
                navigate(advice.point)
            end,"career-life-navigate",true)}}))
        local plan=Life.Plan(state)
        section("今天的生活计划")
        target:AddChild(PhoneKit.Card("career-life-plan",{children={
            PhoneKit.Text(plan.mealText,15,PhoneKit.C.orange,{id="career-plan-meal",fontWeight="bold"}),
            PhoneKit.Text("下一餐 ¥12 · 耗时15游戏分钟 · 不会自动扣款",11,PhoneKit.C.muted),
            PhoneKit.Text(plan.restText,14,PhoneKit.C.blue,{id="career-plan-rest",fontWeight="bold"}),
            PhoneKit.Text(plan.home.name..string.format(" · %s · 精力至少%d",plan.ownedHome and "自有房免房费" or string.format("¥%.0f/晚",plan.nightlyCents/100),plan.home.energy),11,PhoneKit.C.muted),
            PhoneKit.Text(string.format("建议预留 ¥%.2f\n预留后余额 ¥%.2f",plan.reserveCents/100,plan.remainingCents/100),13,
                plan.shortfallCents>0 and PhoneKit.C.red or PhoneKit.C.green,{id="career-plan-budget",fontWeight="bold"}),
            PhoneKit.Text(plan.shortfallCents>0 and string.format("还差 ¥%.2f。可选免费桥下/公园，或查看基础帮助条件。",plan.shortfallCents/100)
                or "预算包含下一餐、当前住处；车辆低于25%时另预留补给。",11,PhoneKit.C.muted),
            PhoneKit.Button("导航到今晚住处",function() navigate(plan.home.point) end,"career-plan-home",false)}}))
        section("本日收支 · 实际流水")
        target:AddChild(PhoneKit.Card("career-life-day-ledger",{children={
            PhoneKit.Text(string.format("完成 %d 单 · 收入 ¥%.2f",plan.orders,plan.incomeCents/100),14,PhoneKit.C.green,{id="career-plan-income",fontWeight="bold"}),
            PhoneKit.Text(string.format("支出 ¥%.2f · 净收入 ¥%.2f",plan.expenseCents/100,(plan.incomeCents-plan.expenseCents)/100),12,PhoneKit.C.ink),
            PhoneKit.Button("打开钱包明细",function() a.phone("wallet") end,"career-plan-wallet",false)}}))
        local alerts=Life.Alerts(state)
        if #alerts>0 then
            section("当前需要留意")
            for index,alert in ipairs(alerts) do
                target:AddChild(PhoneKit.Card("career-life-alert-"..index,{children={
                    PhoneKit.Text(alert.title,13,alert.level>=2 and PhoneKit.C.red or PhoneKit.C.orange,{fontWeight="bold"}),
                    PhoneKit.Text(alert.detail,11,PhoneKit.C.muted)}}))
            end
        end
        section("人物状态 · 不是车辆电量")
        for _,stat in ipairs({{id="hunger",name="饱腹",value=state.hunger,color=PhoneKit.C.orange,
                detail="低于30不能奔跑；55以下建议补一餐。"},
            {id="energy",name="精力 / 体力",value=state.energy,color=PhoneKit.C.blue,
                detail="低于30不能奔跑；45以下安排过夜休息。"}}) do
            target:AddChild(PhoneKit.Card("career-life-stat-"..stat.id,{children={
                PhoneKit.Text(string.format("%s  %.0f / 100",stat.name,stat.value),14,stat.color,{fontWeight="bold"}),
                UI.ProgressBar{value=stat.value,max=100,width="100%",height=7,showLabel=false,fillColor=stat.color},
                PhoneKit.Text(stat.detail,11,PhoneKit.C.muted)}}))
        end
        text("游戏活动15现实分钟≈2游戏小时；手机、暂停时冻结时间与订单。用餐和过夜会按规则推进游戏时间。",11,C.muted)
        section("吃饭与补给")
        action("career-life-meal","早餐店用餐","花12元吃一餐，耗时15游戏分钟。饱腹+55、精力+8，最多100。",nil,"用餐 / 导航",a.eat,false)
        action("career-life-bridge","桥下落脚点","免费睡至次日08:00，精力至少恢复到70；不能带单过夜。",nil,"休息 / 导航",function() a.rest("bridge") end,false)
        action("career-life-park","公园长椅","免费睡至次日08:00，精力至少恢复到75；不能带单过夜。",nil,"休息 / 导航",function() a.rest("park") end,false)
        section("今晚住哪里")
        local home=assert(Housing.Get(state.accommodation))
        text("当前住处："..home.name..(plan.ownedHome and " · 自有房免房费" or string.format(" · %.0f元/晚",plan.nightlyCents/100)),12,C.cyan)
        button("导航到当前住处",function() navigate(home.point) end,false)
        if state.currentSpace and state.currentSpace~="city" then button("到房门旁出门",a.leaveHousing,false)
        elseif home.width then button("到门口进入住处",a.enterHousing,false) end
        button("到点过夜",a.sleepHousing,false)
        section("车辆续航与补给")
        target:AddChild(PhoneKit.Card("career-life-range",{children={
            PhoneKit.Text(string.format("%s %.0f%% · 预计剩余 %.1f km",plan.electric and "电量" or "燃油",plan.power,plan.rangeMeters/1000),14,PhoneKit.C.blue,{id="career-plan-range",fontWeight="bold"}),
            PhoneKit.Text("按当前游戏里程消耗估算；只展示，不赠送电量或燃油。",11,PhoneKit.C.muted),
            PhoneKit.Button(plan.electric and "导航到充电点" or "导航到车行",function()
                navigate(plan.electric and "charge" or "dealer")
            end,"career-plan-supply",false)}}))
        action("career-life-charge","街边充电","到充电点停稳下车。","费用 ¥2 · 耗时30游戏分钟","充电",a.charge,false)
        action("career-life-aid","低现金基础帮助","满足条件才可领取基础补给，不发放现金。",nil,"申请帮助",a.aid,false)
        local subsidyCents=state.adSubsidyCents or 0
        action("career-life-ad-subsidy","每日广告补贴",
            state.adSubsidyClaimed and "今天的补贴已领取，明天再来。" or "完整观看一段广告，领取一次性生活补贴；失败不发放、不扣任何资源。",
            string.format("今日一次\n补贴 ¥%.2f",subsidyCents/100),
            state.adSubsidyClaimed and "今日已领取" or "看广告领取",a.adSubsidy,false)
        section("声音与偏好")
        -- 短屏scale<1时子项端点取整可超过自动父高度1～2px；尾部留2物理px真实内边距。
        target:SetStyle{paddingBottom=2/math.max(.1,UI.GetScale())}
        action("career-music","背景音乐",state.musicEnabled and "当前开启" or "当前关闭",nil,
            state.musicEnabled and "关闭音乐" or "开启音乐",a.toggleMusic,false)
        action("career-effects","车辆 / 脚步 / 环境音",state.effectsEnabled and "当前开启" or "当前关闭",nil,
            state.effectsEnabled and "关闭音效" or "开启音效",a.toggleEffects,false)
        if a.progression then button("查看生涯发展",a.progression,true) end
    end
    Phone.Paginate(self)
end
function View:Update(state,actor,target,active,offer,dt)
    self.lastActor,self.lastTarget=actor,target
    self.lastOrder=active
    self.lastMapPosition=mapPosition(state,actor)
    self.lastOnline=state.online==true
    self.lastActive=active~=nil
    self:SetControlMode(actor.mounted)
    local indoor=state.currentSpace and state.currentSpace~="city"
    self.lastIndoor=indoor==true
    self.mountButton:SetVisible(not indoor)
    local nearbyService=false
    for _,point in ipairs(Config.pointList) do
        if (point.kind=="charge" or point.kind=="rest" or point.kind=="merchant")
            and Config.DistanceTo(point.id,actor.x,actor.z)<=Config.INTERACTION_RADIUS then nearbyService=true; break end
    end
    self.interactButton:SetVisible(indoor or nearbyService or state.contactName~=nil or target~=nil and target.distance<12)
    self.map.root:SetVisible(true)
    self.mapOpen:SetVisible(true)
    self.mapCaption:SetText("附近街区 · "..World.District(actor.x,actor.z).label)
    self.interactButton:SetText(indoor and (target and target.name=="床边 · 休息" and "休息" or "出门")
        or active and nearbyService and target and target.distance>=12 and "交互"
        or active and (active.status=="accepted" and "取餐" or "送达") or state.contactName and "交谈" or "交互")
    self.dashboard:Update(state,actor)
    self.objective:SetText(target and (target.name.." · "..mapDistance(target.distance))
        or state.nextGoal and ("下一步 · "..state.nextGoal.title) or "手机查看下一步目标")
    self.objective:SetVisible(true)
    if active then
        local minutes=math.ceil(math.abs(active.remainingHours)*60)
        self.deliveryStatus:SetText(string.format("%s · %s%d分钟",active.status=="accepted" and "取餐" or "送达",
            active.remainingHours<0 and "超时" or "剩余",minutes))
        self.deliveryStatus:SetStyle{fontColor=active.remainingHours<.25 and C.red or C.cyan}
    else
        self.deliveryStatus:SetText(state.time>=23 and "深夜已停止派单 · 先安排休息"
            or state.online and (offer and string.format("可接新单 · ¥%.2f",offer.feeCents/100) or "听单中 · 暂无附近订单") or "未上线 · 手机外卖页可接单")
        self.deliveryStatus:SetStyle{fontColor=C.cyan}
    end
    self.hint:SetText(state.trafficHint
        or state.contactName and ("附近 · "..state.contactName.."，点击交谈")
        or target and target.hint or "停稳后可查看手机、接单与补给。")
    local mapTarget=target
    if indoor then mapTarget=nil end
    self.map:SetTelemetry(self.lastMapPosition,mapTarget,active)
    self.map.edgeDistance:SetVisible(false)
    self:LayoutControls()
    self.noticeTime=math.max(0,(self.noticeTime or 0)-(dt or .2))
    if self.noticeTime==0 then self.notice:SetText("") end
end
function View:LayoutControls()
    local area=self.controlLayer:GetAbsoluteLayout()
    if area.w~=area.w or area.h~=area.h or area.w==math.huge or area.h==math.huge or area.w<=60 or area.h<=60 then return end
    local bounds=self.hudSafe:GetAbsoluteLayout()
    local w,h=bounds.w,bounds.h
    -- 首次ShowGame时安全区尚未参与Yoga，非有限尺寸不能进入字号/宽度缓存。
    if w~=w or h~=h or w==math.huge or h==math.huge or w<=60 or h<=60 then return end
    local size=math.max(18,18/math.max(.1,UI.GetScale()))
    local short=h<440 and w>h
    local navWidth=short and math.min(w-24,math.max(350,w*.65))
        or math.min(290*size/18,math.max(150,w*.34),math.max(1,w-24))
    local styleKey=string.format("%.2f:%.2f:%.2f",w,h,size)
    self.dashboard:Layout(w,h)
    if self.hudStyleKey~=styleKey then
        self.hudStyleKey=styleKey
        -- 短横屏将地图与正文分栏；文字有实际行宽，底部仍留给步行/驾驶操作。
        self.navPanel:SetStyle{width=navWidth,gap=10,top=self.dashboard.navigationTop or 76,
            flexDirection=short and "row" or "column",alignItems="flex-start"}
        self.mapOpen:SetStyle{width=short and 96 or "100%",flexShrink=0}
        self.navText:SetStyle{width=short and "auto" or "100%",flexGrow=short and 1 or 0,
            flexBasis=short and 0 or "auto",minWidth=0,flexShrink=0,
            paddingBottom=2/math.max(.1,UI.GetScale())}
        self.notice:SetStyle{left=12,right=12,top=h*.70,fontSize=size}
        local touchSize=hudTouchHeight(size)
        self.pauseButton:SetStyle{top=12,right=12,width=touchSize,height=touchSize,minWidth=touchSize,minHeight=touchSize}
        self.menuButton:SetStyle{top=12,right=touchSize+28,width=80,fontSize=size,height=touchSize,minHeight=touchSize}
        for _,button in ipairs({self.mountButton,self.interactButton}) do
            button:SetStyle{fontSize=size,minFontSize=size,height=touchSize,minHeight=touchSize}
        end
        -- 短横屏动作放在导航右侧，右下留出完整摇杆/踏板矩形，而不是逼操作控件出屏。
        self.actionTray:SetStyle{top=short and (self.dashboard.actionTop or 76) or math.max(150,h-190),gap=w<600 and 8 or 24}
        self.objective:SetStyle{fontSize=size*1.1,minFontSize=size*1.1,lineHeight=1}
        self.deliveryStatus:SetStyle{fontSize=size,minFontSize=size,lineHeight=1}
        self.map.root:SetStyle{height=h<440 and 64 or 88}
        self.mapCaption:SetVisible(false)
        self.mapOpenHint:SetVisible(false)
        self.mapOpen:SetVisible(true)
        self.hint:SetVisible(false)
        self.controlHint:SetVisible(false)
    end
    local dash=self.dashboard.root:GetLayout()
    local nav=self.navPanel:GetLayout()
    self.objective:SetVisible(true)
    self.deliveryStatus:SetVisible(self.lastActive==true)
    -- 正文首Render/文案更新会改变导航自然高度，不能只按状态栏高度缓存避让。
    local signature=string.format("%.1f:%.1f:%.1f:%.1f:%.1f:%s:%s:%s",w,h,dash.h,nav.w,nav.h,
        tostring(self.mountedControls),tostring(self.lastTarget~=nil),tostring(self.interactButton:IsVisible()))
    local layoutChanged=self.hudLayoutSignature~=signature
    self.hudLayoutSignature=signature
    local sizeChanged=area.w~=self.controlWidth or area.h~=self.controlHeight
    if sizeChanged then
        self.controlWidth,self.controlHeight=area.w,area.h
        self.controls:SetCompact(area.w<920 or area.h<470)
        self.controls:ApplyScheme(ControlSettings.Current(),area.w,area.h)
    end
    if layoutChanged or sizeChanged then
        if self.mountedControls then
            -- 生涯独立摆位，不覆盖保存的竞速方案；驾驶操作靠屏幕下沿。
            for _,key in ipairs({"gas","brake","steering"}) do
                local widget=self.controls.widgets[key]
                local width,height=self.controls:ButtonSize(key,ControlSettings.Current())
                local x=key=="steering" and 12 or key=="gas" and area.w-width-12 or area.w-width-116
                widget:SetStyle{left=math.max(0,x),top=math.max(0,area.h-height-16)}
            end
        else
            self.walkStick.root:SetStyle{left=22,top=math.max(0,area.h-182)}
        end
        UI.Layout()
        self:AvoidHUDControls()
    end
end
-- 只调整本次生涯画面的冲突位置，不改写玩家保存的竞速操作方案。
function View:AvoidHUDControls()
    local area=self.controlLayer:GetAbsoluteLayout()
    local reserved={}
    local function reserve(widget)
        if not widget:IsVisible() then return end
        local b=widget:GetAbsoluteLayout()
        if b.w<=0 or b.h<=0 then return end
        reserved[#reserved+1]={x=b.x-area.x,y=b.y-area.y,w=b.w,h=b.h}
    end
    reserve(self.navPanel);reserve(self.dashboard.root);reserve(self.dashboard.clock);reserve(self.dashboard.speed)
    reserve(self.pauseButton);reserve(self.menuButton);reserve(self.actionTray)
    local function overlaps(x,y,w,h,r)
        return x<r.x+r.w+6 and x+w>r.x-6 and y<r.y+r.h+6 and y+h>r.y-6
    end
    local widgets=self.mountedControls and {self.controls.widgets.gas,self.controls.widgets.brake,self.controls.widgets.steering}
        or {self.walkStick.root}
    for _,widget in ipairs(widgets) do
        local b=widget:GetAbsoluteLayout()
        local x,y,w,h=b.x-area.x,b.y-area.y,b.w,b.h
        if w>0 and h>0 then
            local xs,ys={x,0,math.max(0,area.w-w)},{y,0,math.max(0,area.h-h)}
            for _,r in ipairs(reserved) do
                xs[#xs+1]=r.x-w-8;xs[#xs+1]=r.x+r.w+8
                ys[#ys+1]=r.y-h-8;ys[#ys+1]=r.y+r.h+8
            end
            local bestX,bestY,best=x,y,math.huge
            for _,cx in ipairs(xs) do for _,cy in ipairs(ys) do
                if cx>=0 and cy>=0 and cx+w<=area.w and cy+h<=area.h then
                    local free=true
                    for _,r in ipairs(reserved) do if overlaps(cx,cy,w,h,r) then free=false;break end end
                    local distance=(cx-x)^2+(cy-y)^2
                    if free and distance<best then bestX,bestY,best=cx,cy,distance end
                end
            end end
            if best<math.huge and (math.abs(bestX-x)>.1 or math.abs(bestY-y)>.1) then
                widget:SetStyle{left=bestX,top=bestY}
            end
            reserved[#reserved+1]={x=bestX,y=bestY,w=w,h=h}
        end
    end
end
function View:SetControlMode(mounted)
    if self.controlModeReady and self.mountedControls==mounted then return end
    self.controlModeReady=true; self.mountedControls=mounted
    self:ResetInput()
    self.walkStick.root:SetVisible(not mounted)
    self.controls.widgets.steering:SetVisible(mounted)
    self.controls.widgets.gas:SetVisible(mounted)
    self.controls.widgets.brake:SetVisible(mounted)
    -- 可见性改变会令隐藏控件暂时没有布局，重新布置当前模式，不复用隐藏前的缓存。
    self.controlWidth,self.controlHeight=0,0
    self.controls:SetActionState("gas",{label="油门",detail="按住加速"})
    self.controls:SetActionState("brake",{label="刹车",detail="停稳按住倒车"})
    self.mountButton:SetText(mounted and "下车" or "上车")
    self.controlHint:SetText(mounted and "左右滑动转向 · 右侧油门 / 刹车 · 停稳后下车取送"
        or "左下摇杆自由移动 · 松手停步 · 右侧滑动画面看四周")
end
function View:ConsumeLook()
    local x,y=self.lookDeltaX,self.lookDeltaY
    self.lookDeltaX,self.lookDeltaY=0,0
    return x,y,self.lookPointer~=-1
end
function View:GetInput()
    local function down(key) return input:GetKeyDown(key) end
    local x=((down(KEY_D) or down(KEY_RIGHT)) and 1 or 0)-((down(KEY_A) or down(KEY_LEFT)) and 1 or 0)
    local y=((down(KEY_W) or down(KEY_UP)) and 1 or 0)-((down(KEY_S) or down(KEY_DOWN)) and 1 or 0)
    local c=self.controls
    local sx,sy=self.walkStick.x,self.walkStick.y
    return {steer=math.max(-1,math.min(1,x+c.steer)),throttle=math.max(-1,math.min(1,y+c.throttle)),
        walkX=math.max(-1,math.min(1,x+sx)),walkY=math.max(-1,math.min(1,y+sy)),
        touchSteer=0,touchWalk=false,run=down(KEY_SHIFT) or math.sqrt(sx*sx+sy*sy)>.94,
        reverseBrake=c.brake,brake=down(KEY_SPACE) or c.brake}
end
function View:ResetInput()
    self.controls:Reset()
    if self.walkStick then self.walkStick:Reset() end
    self.lookPointer=-1; self.lookDeltaX,self.lookDeltaY=0,0
end
function View:Dispose() self.controls:SetEnabled(false); self:ResetInput(); self.root:Destroy() end
return View
