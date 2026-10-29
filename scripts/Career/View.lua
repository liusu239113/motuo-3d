-- 生涯专用视图：沿用钢灰琥珀主题；只发动作，不修改钱包或订单。
local UI = require("urhox-libs/UI")
local Theme = require("RacingTheme")
local Config = require("Career.Config")
local Map = require("Career.MapWidget")
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
local C = Theme.Colors
local function label(text,size,color,props) return Theme.Label(text,size or 12,color or C.white,props) end
local function btn(text,click,primary,props)
    props=props or {}
    local width=props.width or "100%"
    return Theme.Button(text,click,primary,width,props)
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
---@field phoneContent ScrollView
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
    self.controlWidth,self.controlHeight=0,0
    self.mountedControls=false
    self.lookPointer=-1
    self.lookX,self.lookY,self.lookDeltaX,self.lookDeltaY=0,0,0,0
    self.root=UI.Panel{width="100%",height="100%",padding=0,pointerEvents="box-none"}
    self.home=full{backgroundGradient=Theme.Gradient({25,34,40,255},{7,11,15,255}),padding=32,gap=12}
    self.home:AddChild(Theme.Kicker("ROAD TO THE GRID  /  从生活驶向赛场"))
    self.home:AddChild(label("公路狂飙",46,C.white,{fontWeight="bold"}))
    self.home:AddChild(label("从外卖骑手到职业车手",20,C.amber))
    self.home:AddChild(label("王二狗的故事，从兜里的50元开始。",13,C.muted))
    self.homeActions=UI.Panel{width=340,maxWidth="100%",gap=10,padding=0}
    self.home:AddChild(self.homeActions)
    self.home:AddChild(label("生涯现金与旧竞速金币分别保存。驾驶仅限游戏，请勿现实模仿。",10,C.muted,{whiteSpace="normal"}))
    self.game=full{visible=false,pointerEvents="box-none",padding=0}
    local safe=UI.SafeAreaView{width="100%",height="100%",nativeMenuInset=true,padding=12,pointerEvents="box-none"}
    self.status=label("",12,C.white)
    self.objective=label("",13,C.amber,{whiteSpace="normal",maxLines=3})
    self.hint=label("",11,C.white,{whiteSpace="normal",maxLines=2})
    self.map=Map.New("career-minimap")
    self.map.root:SetStyle{width=148,height=112}
    self.mapCaption=label("附近街区 · 南城老街",11,C.white,{id="career-minimap-caption",width="100%",maxLines=1})
    self.mapOpenHint=label("局部地图 · 点此查看全城",10,C.amber,{width="100%",maxLines=1})
    self.mapOpen=UI.Panel{id="career-minimap-open",width=170,minHeight=44,padding=6,gap=3,
        backgroundColor={8,14,18,155},pointerEvents="box-only",onClick=function()
            if not self:IsBlocking() then actions.phone("map") end
        end,children={self.mapCaption,self.map.root,self.mapOpenHint}}
    safe:AddChild(UI.Panel{width=270,maxWidth="44%",padding=8,gap=5,backgroundColor={10,16,21,210},pointerEvents="box-none",
        children={self.status,self.objective,self.hint,self.mapOpen}})
    self.speed=label("步行",14,C.white)
    safe:AddChild(UI.Panel{position="absolute",right=12,top=12,width=155,gap=8,padding=8,backgroundColor={10,16,21,210},
        children={self.speed,btn("暂停",actions.pause,false)}})
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
    self.mountButton=btn("上车",actions.mount,false,{id="career-mount",width=72,height=46,padding=0})
    self.interactButton=btn("交互",actions.interact,false,{id="career-interact",width=82,height=46,padding=0})
    self.actionTray=UI.Row{position="absolute",right=12,top="50%",gap=8,padding=0,pointerEvents="box-none",children={
        self.mountButton,self.interactButton,
        btn("手机",function() actions.phone("apps") end,true,{id="career-phone",width=64,height=46,padding=0})}}
    safe:AddChild(self.actionTray)
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
function View:CloseConversation()
    self.conversation:SetVisible(false)
    destroyChildren(self.conversationBody)
    self.blocked=self.overlay:IsVisible()
    self.controls:SetEnabled(self.game:IsVisible() and self.phonePage=="" and not self.blocked)
end
function View:ShowConversation(name,text,choices)
    self:ClosePhone(); self.overlay:SetVisible(false)
    self:ResetInput(); self.controls:SetEnabled(false); self.blocked=true
    self.speech:SetVisible(false); self.speechTime=0
    destroyChildren(self.conversationBody)
    self.conversationBody:AddChild(label("现场交谈 · "..name,17,C.amber,{id="career-conversation-name",fontWeight="bold"}))
    self.conversationBody:AddChild(label(text,13,C.white,{id="career-conversation-line",whiteSpace="normal",maxLines=4}))
    local options=UI.Row{id="career-conversation-options",width="100%",flexWrap="wrap",gap=6,padding=0}
    self.conversationBody:AddChild(options)
    for _,choice in ipairs(choices) do
        options:AddChild(btn(choice.text,function()
            self:CloseConversation()
            if choice.onClick then choice.onClick() end
        end,choice.primary,{id="career-conversation-"..choice.id,width="48%",flexGrow=1,flexShrink=1,
            height=44,padding=5,fontSize=12}))
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
    self:CloseConversation()
    self.home:SetVisible(false); self.game:SetVisible(true); self.overlay:SetVisible(false)
    self.controlWidth,self.controlHeight=0,0
    self.blocked=false; self.controls:SetEnabled(self.phonePage=="")
end
function View:ShowLoading(title,detail,fraction)
    self:ShowDialog(title,detail..string.format("\n已完成 %.0f%%",fraction*100),{})
end
function View:ShowDialog(title,text,buttons)
    self:CloseConversation(); self.speech:SetVisible(false); self.speechTime=0
    self:ResetInput(); self.controls:SetEnabled(false)
    self.blocked=true; self.phone:SetVisible(false); self.overlay:SetVisible(true)
    destroyChildren(self.dialogBody)
    self.dialogBody:AddChild(label(title,21,C.amber,{fontWeight="bold",whiteSpace="normal"}))
    self.dialogBody:AddChild(label(text,13,C.white,{whiteSpace="normal",maxLines=14}))
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
function View:IsBlocking() return self.blocked or self.phonePage~="" end
function View:ClosePhone()
    self.phone:SetVisible(false); self.phonePage=""; self:ResetInput()
    destroyChildren(self.phoneContent)
    destroyChildren(self.phoneDesktop)
    self.phoneContent:ScrollToTop()
    self.mapDistrictId=""; self.mapPointPage=1; self.mapPickerOpen=false
    PhoneApps.Reset(self)
    self.controls:SetEnabled(self.game:IsVisible() and not self.blocked)
end
function View:OpenPhone(page,state,offer,active)
    self:CloseConversation(); self.overlay:SetVisible(false); self.blocked=false
    self.speech:SetVisible(false); self.speechTime=0
    if self.phonePage=="" then
        self.mapDistrictId=""; self.mapPointPage=1; self.mapPickerOpen=false
    end
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
    content:AddChild(label("当前区 · "..current.label,12,C.cyan,{id="career-map-current",whiteSpace="normal"}))
    if state.currentSpace and state.currentSpace~="city" then
        content:AddChild(label("室内 · 按城市入口定位与计距；请先到房门旁出门，再沿城市导航前往。",11,C.amber,
            {id="career-map-indoor",whiteSpace="normal"}))
    end
    local chooser=btn("",function() end,false,{id="career-map-region-toggle",height=44,padding=4})
    content:AddChild(chooser)
    -- 有界折叠按钮组避免 Dropdown 浮层在窄手机屏上越界；每次仅创建14个真实区域按钮。
    local picker=UI.Panel{id="career-map-regions",width="100%",padding=0,gap=4,visible=self.mapPickerOpen}
    content:AddChild(picker)
    local points=UI.Panel{id="career-map-points",width="100%",padding=0,gap=7}
    content:AddChild(points)
    local function updateChooser()
        chooser:SetText((self.mapPickerOpen and "收起区域 · " or "选择区域 · ")..selected.label
            ..(selected.id==current.id and "（当前区）" or ""))
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
        points:AddChild(label(selected.label.." · "..#matches.."处"..(selected.id==current.id and " · 当前区" or ""),13,C.amber,
            {id="career-map-selected",whiteSpace="normal"}))
        points:AddChild(label(selected.id=="greenbelt"
            and "绿带无固定服务点：以下为距你最近的4处真实地点，按所属区标注。"
            or "按距你远近排列；距离为直线参考，不是道路里程。",10,C.muted,
            {id="career-map-distance-note",whiteSpace="normal"}))
        if selected.id=="greenbelt" then
            points:AddChild(label("跨区距离按你当前城市位置计算（室内按入口）；不代表绿带内有店。",10,C.muted,{whiteSpace="normal"}))
        end
        local first=(self.mapPointPage-1)*MAP_PAGE_SIZE+1
        for index=first,math.min(#matches,first+MAP_PAGE_SIZE-1) do
            local point=assert(matches[index])
            local id=point.id
            local district=World.District(point.x,point.z)
            local distance=math.sqrt((point.x-pos.x)^2+(point.z-pos.z)^2)
            local row=btn("",function() self.actions.setWaypoint(id); self.actions.closePhone() end,false,
                {id="career-map-poi-"..id,height=60,padding=5,gap=2,justifyContent="center",alignItems="stretch"})
            row:AddChild(label(point.label,11,C.white,{whiteSpace="normal",maxLines=2}))
            row:AddChild(label((district.id~=current.id and "跨区 · "..district.label.." · " or "本区 · ")
                .."直线 "..mapDistance(distance),10,C.muted,{id="career-map-distance-"..id,whiteSpace="normal"}))
            points:AddChild(row)
        end
        if pages>1 then
            points:AddChild(label(string.format("地点 %d/%d 页 · 每页最多%d处",self.mapPointPage,pages,MAP_PAGE_SIZE),10,C.muted,
                {id="career-map-pagination"}))
            local nav=UI.Row{width="100%",gap=5,padding=0}
            local function turn(delta)
                self.mapPointPage=self.mapPointPage+delta
                refreshPoints()
            end
            nav:AddChild(btn("上一页",function() turn(-1) end,false,{id="career-map-prev",width="48%",height=44,
                disabled=self.mapPointPage==1,padding=0}))
            nav:AddChild(btn("下一页",function() turn(1) end,false,{id="career-map-next",width="48%",height=44,
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
        picker:AddChild(btn(choice.label..(choice.id==current.id and " · 当前区" or ""),function()
            selected=choice; self.mapDistrictId=choice.id; self.mapPointPage=1; self.mapPickerOpen=false
            updateChooser(); refreshPoints(); self.phoneContent:ScrollToTop()
        end,false,{id="career-map-region-"..choice.id,height=44,padding=2,fontSize=11}))
    end
    updateChooser(); refreshPoints()
    content:AddChild(label("全城概览 · 30公里跨度",12,C.amber,{id="career-map-overview-title"}))
    local map=Map.New("career-phone-map",true)
    map.root:SetStyle{width="100%",height=220}
    content:AddChild(map.root)
    local target=self.lastTarget
    if state.currentSpace and state.currentSpace~="city" then target=nil end
    map:SetTelemetry(pos,target,active)
    content:AddChild(label("全城道路连通，亲自骑行探索；主屏小地图跟随当前位置。",11,C.muted,{whiteSpace="normal"}))
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
    local modern=page~="apps" and page~="map"
    local target=content
    local function section(title)
        target=PhoneKit.Card(nil)
        content:AddChild(target)
        target:AddChild(PhoneKit.Text(title,13,PhoneKit.C.ink,{fontWeight="bold"}))
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
    self.phoneContent:SetStyle{backgroundColor=modern and PhoneKit.C.paper or {0,0,0,0},borderRadius=10}
    self.phoneTitle:SetText(({apps="王二狗的手机",delivery="外卖骑手",map="南城地图",wallet="钱包",messages="消息",life="生活",progression="生涯发展"})[page] or "手机")
    self.phoneClock:SetText(string.format("%02d:%02d",math.floor(state.time),math.floor(state.time*60)%60))
    if page=="apps" then
        Phone.Desktop(content,state,a,self.phoneHeight)
    elseif page=="delivery" then
        PhoneApps.Delivery(self,content,state,offer,active)
    elseif page=="map" then
        self:BuildMapPhone(content,state,active)
    elseif page=="wallet" then
        PhoneApps.Wallet(self,content,state)
    elseif page=="messages" then
        PhoneApps.Messages(self,content,state)
    elseif page=="progression" then
        text(Progress.Chapter(state),17,C.amber)
        local level,name=Progress.Level(state)
        text(string.format("%s Lv.%d · 携带容量%d份",name,level,Progress.Capacity(state)),13)
        text("装备、买车与职业报名需到南城车行；住房可在手机选择，再去对应入口入住。",11,C.muted)
        button("导航到南城车行",function() a.setWaypoint("dealer"); a.closePhone() end,true)
        section("骑手装备")
        for _,item in ipairs(Progress.Equipment) do
            local id=item.id
            text(item.description,10,C.muted)
            button((state.equipment and state.equipment[id] and "已拥有 · " or "购入 · ")..item.name..string.format(" ¥%.0f / Lv.%d",item.price/100,item.level),function() a.buyEquipment(id) end,false)
        end
        section("改善住处 · 按晚付费")
        text("旅舍、出租屋、公寓各有入口和室内。进门不收费，到床边确认休息才支付一晚。",10,C.muted)
        for _,item in ipairs(Progress.Housing) do
            local id=item.id
            button((state.accommodation==id and "当前 · " or "选择 · ")..item.name..string.format(" ¥%.0f/晚",item.price/100),function() a.housing(id) end,false)
        end
        local home=assert(Housing.Get(state.accommodation))
        button("导航到当前住处",function() a.setWaypoint(home.point); a.closePhone() end,false)
        if home.width then button("到门口进入住处",a.enterHousing,false) end
        button("到休息点过夜",a.sleepHousing,false)
        section("工作周 · 解锁后可选")
        text("第10天起开放，每周需重新亲送10单并活动15分钟。亲送与模拟收入不重复，房费按7晚另算。",11,C.muted)
        button("查看并确认7天排班",a.workWeek,false)
        section("人生第一辆摩托")
        text("现金达到5万元后首购二手训练版：46000元；另备2000元护具训练、2000元周转。",11,C.muted)
        for _,item in ipairs(Progress.Motorcycles) do
            local id=item.id
            if state.ownedMotorcycles[id] then
                button((state.raceVehicle==id and "当前参赛 · " or "选为参赛车 · ")..item.name,function() a.selectMotorcycle(id) end,false)
            else button("购买 · "..item.name..string.format(" ¥%.0f",item.price/100),function() a.buyMotorcycle(id) end,false) end
        end
        section("城市车库 · 到车行取车")
        text("摩托城市限速60km/h，电动车35km/h。换车不召回：原车留在停车处；接单前需换回带箱9号。燃油独立于电量，摩托共享油量。",11,C.muted)
        button("城市用车 · 9号电动车",function() a.cityVehicle("borrowed_ebike") end,false)
        for _,item in ipairs(Progress.Motorcycles) do
            if state.ownedMotorcycles[item.id] then
                local id=item.id
                button("城市用车 · "..item.name,function() a.cityVehicle(id) end,false)
            end
        end
        button(string.format("车行摩托补给 · 20元（油量%.0f%%）",state.motorcycleFuel or 100),a.refuel,false)
        button("报名并进入封闭训练 · 护具课程2000元",a.train,true)
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
            button(series.name..string.format(" · 报名¥%.0f / 需%d积分",series.fee/100,series.required),function() a.race(n) end,false)
        end
        if state.career and state.career.pending then button("继续已报名的赛事",function() a.race(state.career.pending.series) end,true) end
        if state.flags.lifeWinner then
            text("王二狗：从桥洞到自己的住处，从战损电动车到冠军发车格。人生没有白跑的路。\n年度冠军达成，仍可继续配送、改善生活、收藏车辆和参加比赛。",14,C.amber)
        end
    elseif page=="life" then
        section("今天的身体状态")
        text(string.format("饱腹 %.0f%% · 精力 %.0f%% · 电量 %.0f%%",state.hunger,state.energy,state.battery),13,C.amber)
        text("生活服务需要走到对应地点，停车下车。可从地图设置导航。",11,C.muted)
        section("吃饭与补给")
        button("早餐店用餐 · 12元",a.eat,false)
        button("桥下免费休息至次日",function() a.rest("bridge") end,false)
        button("公园长椅免费休息至次日",function() a.rest("park") end,false)
        section("今晚住哪里")
        local home=assert(Housing.Get(state.accommodation))
        text("当前住处："..home.name..string.format(" · %.0f元/晚",home.price/100),12,C.cyan)
        button("导航到当前住处",function() a.setWaypoint(home.point); a.closePhone() end,false)
        if state.currentSpace and state.currentSpace~="city" then button("到房门旁出门",a.leaveHousing,false)
        elseif home.width then button("到门口进入住处",a.enterHousing,false) end
        button("走到床边 / 休息点过夜",a.sleepHousing,false)
        button("街边充电 · 2元",a.charge,false)
        button("低现金基础帮助（不发现金）",a.aid,false)
        section("声音与偏好")
        button("背景音乐 · "..(state.musicEnabled and "开启" or "关闭"),a.toggleMusic,false,"career-music")
        button("车辆 / 脚步 / 环境音 · "..(state.effectsEnabled and "开启" or "关闭"),a.toggleEffects,false,"career-effects")
        if a.progression then button("装备 / 住房 / 生涯发展",a.progression,true) end
    end
end
function View:Update(state,actor,target,active,offer,dt)
    self.lastActor,self.lastTarget=actor,target
    self:SetControlMode(actor.mounted)
    self:LayoutControls()
    local indoor=state.currentSpace and state.currentSpace~="city"
    self.mountButton:SetVisible(not indoor)
    self.map.root:SetVisible(not indoor)
    self.mapOpen:SetVisible(not indoor)
    self.mapCaption:SetText("附近街区 · "..World.District(actor.x,actor.z).label)
    self.interactButton:SetText(indoor and (target and target.name=="床边 · 休息" and "休息" or "出门")
        or active and (active.status=="accepted" and "取餐" or "送达") or state.contactName and "交谈" or "交互")
    self.status:SetText(string.format("王二狗  %s  第%d天 %02d:%02d\n饱腹 %.0f · 精力 %.0f · 电量 %.0f%%",money(state.cashCents),state.day,
        math.floor(state.time),math.floor(state.time*60)%60,state.hunger,state.energy,state.battery))
    self.objective:SetText(target and (target.name..string.format(" · %.0f米",target.distance)) or "打开右下角手机 → 外卖骑手 → 上线听单")
    local need=math.min(state.hunger,state.energy)
    self.hint:SetText(need<30 and "饥饿或疲劳已降低速度：去早餐店用餐，或去住处休息。"
        or state.time>=23 and "深夜已停止派新单，请完成配送后休息。"
        or state.trafficHint
        or state.contactName and ("附近 · "..state.contactName.."，点击右侧交谈")
        or target and target.hint or "先活下去，再跑出自己的路。")
    self.speed:SetText(actor.mounted and string.format("%s  %.0f km/h",actor:VehicleName(),math.abs(actor.speed)*3.6)
        or "步行 · 车辆停在原处")
    if actor.vehicleId~="borrowed_ebike" then
        self.speed:SetText(self.speed.props.text..string.format("\n摩托燃油 %.0f%%",state.motorcycleFuel or 100))
    end
    self.map:SetTelemetry(actor,target,active)
    self.noticeTime=math.max(0,(self.noticeTime or 0)-(dt or .2))
    if self.noticeTime==0 then self.notice:SetText("") end
end
function View:LayoutControls()
    local area=self.controlLayer:GetAbsoluteLayout()
    if area.w<=60 or area.h<=60 then return end
    if area.w~=self.controlWidth or area.h~=self.controlHeight then
        self.controlWidth,self.controlHeight=area.w,area.h
        self.controls:SetCompact(area.w<920 or area.h<470)
        self.controls:ApplyScheme(ControlSettings.Current(),area.w,area.h)
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
    self.controls:SetActionState("brake",{label="刹车 / 倒车",detail="停稳按住倒车"})
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
