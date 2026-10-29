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

---@class CareerView
---@field phoneContent ScrollView
---@field phoneTitle Label
---@field phoneClock Label
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
    self.phonePage=""
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
    self.map.root:SetStyle{width=165,height=145}
    safe:AddChild(UI.Panel{width=300,maxWidth="48%",padding=10,gap=6,backgroundColor={10,16,21,210},pointerEvents="none",
        children={self.status,self.objective,self.hint,self.map.root}})
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
    self.phone=UI.SafeAreaView(Theme.Full{nativeMenuInset=true,visible=false,backgroundColor={3,6,9,150},alignItems="flex-end",justifyContent="center",padding=12})
    self.phoneBody=Phone.Create(self,actions)
    self.phone:AddChild(self.phoneBody)
    self.overlay=full{visible=false,backgroundColor={3,6,9,225},justifyContent="center",alignItems="center",padding=22}
    self.dialogBody=UI.Panel{width=520,maxWidth="100%",maxHeight="100%",padding=22,gap=14,
        backgroundColor=C.dark,borderColor=C.border,borderWidth=1}
    self.overlay:AddChild(self.dialogBody)
    self.notice=label("",12,C.amber,{position="absolute",top=12,left="30%",right="22%",whiteSpace="normal",textAlign="center",maxLines=3})
    self.root:AddChild(self.home); self.root:AddChild(self.game); self.root:AddChild(self.phone)
    self.root:AddChild(self.overlay); self.root:AddChild(self.notice)
end
function View:ShowHome(hasSave,message)
    self.home:SetVisible(true); self.game:SetVisible(false); self.phone:SetVisible(false); self.overlay:SetVisible(false)
    self.phonePage=""; self.blocked=true; self.controls:SetEnabled(false)
    self.homeActions:ClearChildren()
    self.homeActions:AddChild(btn(hasSave and "继续王二狗的生涯" or "开始生涯 · 身上只有50元",function() self.actions.startCareer(false) end,true,{id="career-start"}))
    if hasSave then self.homeActions:AddChild(btn("重新开始生涯",function() self.actions.startCareer(true) end,false)) end
    self.homeActions:AddChild(btn("独立竞速 / 旧存档",self.actions.legacy,false))
    if message then self.homeActions:AddChild(label(message,10,C.muted,{whiteSpace="normal"})) end
end
function View:ShowGame()
    self.home:SetVisible(false); self.game:SetVisible(true); self.overlay:SetVisible(false)
    self.controlWidth,self.controlHeight=0,0
    self.blocked=false; self.controls:SetEnabled(self.phonePage=="")
end
function View:ShowLoading(title,detail,fraction)
    self:ShowDialog(title,detail..string.format("\n已完成 %.0f%%",fraction*100),{})
end
function View:ShowDialog(title,text,buttons)
    self:ResetInput(); self.controls:SetEnabled(false)
    self.blocked=true; self.overlay:SetVisible(true)
    self.dialogBody:ClearChildren()
    self.dialogBody:AddChild(label(title,21,C.amber,{fontWeight="bold",whiteSpace="normal"}))
    self.dialogBody:AddChild(label(text,13,C.white,{whiteSpace="normal",maxLines=14}))
    for _,item in ipairs(buttons) do
        self.dialogBody:AddChild(btn(item.text,function()
            self.overlay:SetVisible(false); self.blocked=false
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
    self.controls:SetEnabled(self.game:IsVisible() and not self.blocked)
end
function View:OpenPhone(page,state,offer,active)
    self:ResetInput(); self.controls:SetEnabled(false); self.phonePage=page or "apps"; self.phone:SetVisible(true)
    self:BuildPhone(state,offer,active)
end
function View:BuildPhone(state,offer,active)
    self.phoneContent:ClearChildren()
    local content=UI.Panel{width="100%",padding=0,gap=11}
    self.phoneContent:AddChild(content)
    local a=self.actions
    local function text(t,size,color) content:AddChild(label(t,size,color,{whiteSpace="normal"})) end
    local function button(t,fn,primary,id) content:AddChild(btn(t,fn,primary,{id=id})) end
    local page=self.phonePage
    content:SetStyle{padding=page=="apps" and 0 or 9,borderRadius=10,
        backgroundColor=page=="apps" and {0,0,0,0} or {8,19,27,238}}
    if page~="apps" then button("← 应用首页",function() a.phone("apps") end,false) end
    self.phoneTitle:SetText(({apps="王二狗的手机",delivery="外卖骑手",map="南城地图",wallet="钱包",messages="消息",life="生活",progression="生涯发展"})[page] or "手机")
    self.phoneClock:SetText(string.format("%02d:%02d",math.floor(state.time),math.floor(state.time*60)%60))
    if page=="apps" then
        Phone.Desktop(content,state,a)
    elseif page=="delivery" then
        local pos=self.lastActor or state.position
        text(World.District(pos.x,pos.z).label.."站 · "..(state.online and "正在听单" or "尚未上线"),14,C.amber)
        text("配送费2.50～10.00元，接单时报价锁定。绕路不会多拿钱；长途单预留更多时间，来不及当日完成则不派发。",11,C.muted)
        button(state.online and "停止听单" or "上线听单",function() a.online(not state.online) end,not state.online,"career-online")
        if active then
            text(active.title,18)
            text((active.status=="accepted" and "前往取餐：" or "前往送达：")..Config.points[active.status=="accepted" and active.pickupId or active.dropoffId].label,13)
            text("报酬 "..money(active.feeCents)..string.format(" · 剩余 %.0f 游戏分钟",math.max(0,active.remainingHours*60)),12,C.amber)
            if Progress.Capacity(state)>#state.activeOrders and state.online and offer then
                text("可叠加配送："..offer.title.." · "..money(offer.feeCents),12,C.amber)
                button("再接一单（独立结算）",a.accept,true)
            end
            for _,order in ipairs(state.activeOrders) do
                local id=order.id
                button("切换任务 · "..order.title.." / "..(order.status=="accepted" and "待取餐" or "待送达"),function() a.selectOrder(id) end,false)
            end
            button("导航到当前任务",function() a.setWaypoint(active.status=="accepted" and active.pickupId or active.dropoffId); a.closePhone() end,true)
            button(active.status=="accepted" and "到店取餐（需下车到点）" or "交付外卖（需下车到点）",a.interact,false)
        elseif state.online and offer then
            text(offer.title,18)
            text(Config.points[offer.pickupId].label.." → "..Config.points[offer.dropoffId].label,13)
            text(money(offer.feeCents)..string.format(" · 路线 %.0f 米",offer.distanceMeters),17,C.amber)
            if offer.tutorial then text("新手教学单 · 固定5元，不是普通距离报价。",11,C.muted) end
            button("抢单 / 接单",a.accept,true,"career-accept")
        else text("上线后接收本地城市配送订单。",12,C.muted) end
    elseif page=="map" then
        local map=Map.New("career-phone-map",true); map.root:SetStyle{width="100%",height=220}
        content:AddChild(map.root)
        if state.currentSpace and state.currentSpace~="city" then
            local pos=state.position
            map:SetTelemetry({x=pos.cityX,z=pos.cityZ,yaw=pos.cityYaw},nil,active)
            text("你正在室内，地图标记为进入住处的位置。请先走到房门旁出门，再按城市导航前往目的地。",11,C.amber)
        else
            map:SetTelemetry(self.lastActor or state.position,self.lastTarget,active)
        end
        text("全城30公里跨度 · 路线连通，各区需要亲自骑行探索。",12,C.amber)
        text("主屏小地图跟随当前位置；本页为全城概览。外区只派附近商家的订单。",11,C.muted)
        for _,district in ipairs(World.Districts) do
            text(district.label,14,C.cyan)
        end
        for _,point in ipairs(Config.pointList) do
            local id=point.id; button(point.label,function() a.setWaypoint(id); a.closePhone() end,false)
        end
    elseif page=="wallet" then
        text(money(state.cashCents),28,C.amber)
        text("生活现金 · 不与独立竞速金币兑换",11,C.muted)
        text(string.format("已完成%d单 · 首辆摩托目标 ¥50,000",state.completedOrders),12)
        for i=#state.ledger,math.max(1,#state.ledger-15),-1 do
            local e=state.ledger[i]
            text(string.format("第%d天  %s  %+.2f元",e.day,e.kind,e.deltaCents/100),11,e.deltaCents>=0 and C.green or C.muted)
        end
        button("保存本地并同步账号云档",a.save,true)
        button("读取账号云档（需确认）",a.loadCloud,false)
        text(a.saveStatus and a.saveStatus() or "本地保存不等于云端确认。",10,C.muted)
    elseif page=="messages" then
        text("表哥",18,C.amber)
        text("二狗，车钥匙给你了。那辆9号以前是我追对象时留下的，壳子磕过，电池还能用。后架我给你装了保温箱。",13)
        text("先把饭吃上，晚上桥下或者公园能落脚。送餐别急，停稳下车再拿。等你真攒够五万，咱去车行看看。",13)
        text("王二狗：这回，先把生活跑顺。",13,C.cyan)
        button("用餐 / 休息 / 充电",function() a.phone("life") end,false)
        local events=Engagements.State(state)
        text("街区联系人 · 现场委托",17,C.amber)
        text("到联系人驻点接受，亲自行动后返回交付；模拟排班不计入委托。",11,C.muted)
        for _,item in ipairs(events.list) do
            local id,instanceId=item.id,item.instanceId
            text(item.npcName.." · "..item.title,14,C.cyan)
            text(item.description,11,C.muted)
            text(item.progressText,12,C.white)
            if item.status=="available" then
                button("现场接取 · "..item.title,function() a.acceptEngagement(id) end,true,"career-engagement-"..id)
            elseif item.status=="locked" then text(item.prerequisiteText,10,C.muted)
            elseif item.status=="ready" then
                button("返回交付 · 奖励"..money(item.rewardCents),function() a.claimEngagement(instanceId) end,true,"career-claim-"..id)
            elseif item.status=="claimed" then text("已交付 · 回信已保存",11,C.green) end
            if item.status~="claimed" then
                local point=item.nextPointId or item.acceptPointId
                button("导航到"..Config.points[point].label,function() a.setWaypoint(point); a.closePhone() end,false)
                if item.status=="active" and point~=item.returnPointId then
                    button("到场联系 / 确认访问",function() a.visitEngagement(point) end,false)
                end
            end
        end
        for _,letter in ipairs(events.letters) do
            text(letter.npcName.." · "..letter.title,14,C.amber)
            text(letter.text,12,C.white)
        end
        local journal=Progress.StoryLog(state)
        if #journal>0 then text("王二狗的路 · 已读经历",17,C.amber) end
        for _,story in ipairs(journal) do text(story.title,14,C.cyan); text(story.text,12,C.white) end
    elseif page=="progression" then
        text(Progress.Chapter(state),17,C.amber)
        local level,name=Progress.Level(state)
        text(string.format("%s Lv.%d · 携带容量%d份",name,level,Progress.Capacity(state)),13)
        text("装备、买车与职业报名需到南城车行；住房可在手机选择，再去对应入口入住。",11,C.muted)
        button("导航到南城车行",function() a.setWaypoint("dealer"); a.closePhone() end,true)
        text("骑手装备",16,C.cyan)
        for _,item in ipairs(Progress.Equipment) do
            local id=item.id
            text(item.description,10,C.muted)
            button((state.equipment and state.equipment[id] and "已拥有 · " or "购入 · ")..item.name..string.format(" ¥%.0f / Lv.%d",item.price/100,item.level),function() a.buyEquipment(id) end,false)
        end
        text("改善住处 · 按晚付费",16,C.cyan)
        text("旅舍、出租屋、公寓各有入口和室内。进门不收费，到床边确认休息才支付一晚。",10,C.muted)
        for _,item in ipairs(Progress.Housing) do
            local id=item.id
            button((state.accommodation==id and "当前 · " or "选择 · ")..item.name..string.format(" ¥%.0f/晚",item.price/100),function() a.housing(id) end,false)
        end
        local home=assert(Housing.Get(state.accommodation))
        button("导航到当前住处",function() a.setWaypoint(home.point); a.closePhone() end,false)
        if home.width then button("到门口进入住处",a.enterHousing,false) end
        button("到休息点过夜",a.sleepHousing,false)
        text("工作周 · 解锁后可选",16,C.cyan)
        text("第10天起开放，每周需重新亲送10单并活动15分钟。亲送与模拟收入不重复，房费按7晚另算。",11,C.muted)
        button("查看并确认7天排班",a.workWeek,false)
        text("人生第一辆摩托",16,C.cyan)
        text("现金达到5万元后首购二手训练版：46000元；另备2000元护具训练、2000元周转。",11,C.muted)
        for _,item in ipairs(Progress.Motorcycles) do
            local id=item.id
            if state.ownedMotorcycles[id] then
                button((state.raceVehicle==id and "当前参赛 · " or "选为参赛车 · ")..item.name,function() a.selectMotorcycle(id) end,false)
            else button("购买 · "..item.name..string.format(" ¥%.0f",item.price/100),function() a.buyMotorcycle(id) end,false) end
        end
        text("城市车库 · 到车行取车",16,C.cyan)
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
        text("车队与赞助 · 正式合同",16,C.cyan)
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
        text("职业赛事",16,C.cyan)
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
        text(string.format("饱腹 %.0f%% · 精力 %.0f%% · 电量 %.0f%%",state.hunger,state.energy,state.battery),13,C.amber)
        text("生活服务需要走到对应地点，停车下车。可从地图设置导航。",11,C.muted)
        button("早餐店用餐 · 12元",a.eat,false)
        button("桥下免费休息至次日",function() a.rest("bridge") end,false)
        button("公园长椅免费休息至次日",function() a.rest("park") end,false)
        local home=assert(Housing.Get(state.accommodation))
        text("当前住处："..home.name..string.format(" · %.0f元/晚",home.price/100),12,C.cyan)
        button("导航到当前住处",function() a.setWaypoint(home.point); a.closePhone() end,false)
        if state.currentSpace and state.currentSpace~="city" then button("到房门旁出门",a.leaveHousing,false)
        elseif home.width then button("到门口进入住处",a.enterHousing,false) end
        button("走到床边 / 休息点过夜",a.sleepHousing,false)
        button("街边充电 · 2元",a.charge,false)
        button("低现金基础帮助（不发现金）",a.aid,false)
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
    self.interactButton:SetText(indoor and (target and target.name=="床边 · 休息" and "休息" or "出门")
        or active and (active.status=="accepted" and "取餐" or "送达") or "交互")
    self.status:SetText(string.format("王二狗  %s  第%d天 %02d:%02d\n饱腹 %.0f · 精力 %.0f · 电量 %.0f%%",money(state.cashCents),state.day,
        math.floor(state.time),math.floor(state.time*60)%60,state.hunger,state.energy,state.battery))
    self.objective:SetText(target and (target.name..string.format(" · %.0f米",target.distance)) or "打开右下角手机 → 外卖骑手 → 上线听单")
    local need=math.min(state.hunger,state.energy)
    self.hint:SetText(need<30 and "饥饿或疲劳已降低速度：去早餐店用餐，或去住处休息。"
        or state.time>=23 and "深夜已停止派新单，请完成配送后休息。"
        or state.trafficHint
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
