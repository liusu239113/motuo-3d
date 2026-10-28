-- 生涯专用视图：沿用钢灰琥珀主题；只发动作，不修改钱包或订单。
local UI = require("urhox-libs/UI")
local Theme = require("RacingTheme")
local Config = require("Career.Config")
local Map = require("Career.MapWidget")
local Progress = require("Career.Progression")
local C = Theme.Colors
local function label(text,size,color,props) return Theme.Label(text,size or 12,color or C.white,props) end
local function btn(text,click,primary,props) return Theme.Button(text,click,primary,"100%",props) end
local function full(props) return UI.Panel(Theme.Full(props)) end
local function money(cents) return string.format("¥ %.2f",cents/100) end

---@class CareerView
local View = {}
View.__index = View
function View.New(actions)
    local self=setmetatable({},View)
    self:Init(actions)
    return self
end
function View:Init(actions)
    self.actions=actions
    self.phonePage=""
    self.blocked=false
    self.input={left=false,right=false,forward=false,back=false,brake=false}
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
        children={self.speed,btn("暂停 / P",actions.pause,false)}})
    local movement=UI.Panel{position="absolute",bottom=14,left=12,width=190,height=130,padding=0,pointerEvents="box-none"}
    local function held(text,key,x,y)
        return btn(text,function() end,false,{position="absolute",left=x,top=y,width=56,height=52,padding=0,
            onPointerDown=function() self.input[key]=true end,
            onPointerUp=function() self.input[key]=false end,
            onPointerCancel=function() self.input[key]=false end})
    end
    movement:AddChild(held("前 / W","forward",60,0))
    movement:AddChild(held("左 / A","left",0,60))
    movement:AddChild(held("后 / S","back",60,60))
    movement:AddChild(held("右 / D","right",120,60))
    safe:AddChild(movement)
    safe:AddChild(UI.Panel{position="absolute",right=12,bottom=14,width=150,gap=8,padding=0,children={
        btn("手机 / Tab",function() actions.phone("apps") end,true,{id="career-phone"}),
        btn("交互 / E",actions.interact,false,{id="career-interact"}),
        btn("上 / 下车 F",actions.mount,false,{id="career-mount"})}})
    safe:AddChild(label("空格制动 · Shift快走 · 鼠标右键拖动视角",10,C.muted,
        {position="absolute",bottom=12,left="30%",right="22%",textAlign="center",whiteSpace="normal"}))
    self.game:AddChild(safe)
    self.phone=full{visible=false,backgroundColor={3,6,9,150},alignItems="flex-end",justifyContent="center",padding=14}
    self.phoneBody=UI.Panel{width=380,maxWidth="90%",height="94%",padding=16,gap=10,borderWidth=2,borderRadius=18,
        borderColor=C.border,backgroundColor={16,22,28,255}}
    self.phoneTitle=label("王二狗的手机",16,C.white,{fontWeight="bold"})
    self.phoneBody:AddChild(UI.Row{width="100%",padding=0,gap=8,children={self.phoneTitle,
        Theme.Button("关闭",actions.closePhone,false,70,{marginLeft="auto",height=34})}})
    self.phoneContent=UI.ScrollView{width="100%",flexGrow=1,flexBasis=0,minHeight=0,padding=0}
    self.phoneBody:AddChild(self.phoneContent)
    self.phoneBody:AddChild(label("停车使用手机 · 游戏时间暂停",10,C.muted))
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
    self.phonePage=""; self.blocked=true
    self.homeActions:ClearChildren()
    self.homeActions:AddChild(btn(hasSave and "继续王二狗的生涯" or "开始生涯 · 身上只有50元",function() self.actions.startCareer(false) end,true,{id="career-start"}))
    if hasSave then self.homeActions:AddChild(btn("重新开始生涯",function() self.actions.startCareer(true) end,false)) end
    self.homeActions:AddChild(btn("独立竞速 / 旧存档",self.actions.legacy,false))
    if message then self.homeActions:AddChild(label(message,10,C.muted,{whiteSpace="normal"})) end
end
function View:ShowGame()
    self.home:SetVisible(false); self.game:SetVisible(true); self.overlay:SetVisible(false)
    self.blocked=false
end
function View:ShowLoading(title,detail,fraction)
    self:ShowDialog(title,detail..string.format("\n已完成 %.0f%%",fraction*100),{})
end
function View:ShowDialog(title,text,buttons)
    self:ResetInput()
    self.blocked=true; self.overlay:SetVisible(true)
    self.dialogBody:ClearChildren()
    self.dialogBody:AddChild(label(title,21,C.amber,{fontWeight="bold",whiteSpace="normal"}))
    self.dialogBody:AddChild(label(text,13,C.white,{whiteSpace="normal",maxLines=14}))
    for _,item in ipairs(buttons) do
        self.dialogBody:AddChild(btn(item.text,function()
            self.overlay:SetVisible(false); self.blocked=false
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
end
function View:OpenPhone(page,state,offer,active)
    self:ResetInput(); self.phonePage=page or "apps"; self.phone:SetVisible(true)
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
    if page~="apps" then button("← 应用首页",function() a.phone("apps") end,false) end
    self.phoneTitle:SetText(({apps="王二狗的手机",delivery="外卖骑手",map="南城地图",wallet="钱包",messages="消息",life="生活",progression="生涯发展"})[page] or "手机")
    if page=="apps" then
        text(string.format("第%d天  %02d:%02d",state.day,math.floor(state.time),math.floor(state.time*60)%60),14,C.amber)
        for _,app in ipairs({{"delivery","外卖骑手 · 听单抢单"},{"map","地图 · 商家与住处"},{"wallet","钱包 · 每一笔收支"},{"messages","消息 · 表哥"},{"life","生活 · 吃饭休息充电"}}) do
            local id=app[1]; button(app[2],function() a.phone(id) end,id=="delivery","career-app-"..id)
        end
    elseif page=="delivery" then
        text("南城老街站 · "..(state.online and "正在听单" or "尚未上线"),14,C.amber)
        text("配送费2.50～10.00元，接单时报价锁定。绕路不会多拿钱。",11,C.muted)
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
        local map=Map.New("career-phone-map"); map.root:SetStyle{width="100%",height=220}
        content:AddChild(map.root); map:SetTelemetry(self.lastActor or state.position,self.lastTarget,active)
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
    elseif page=="progression" then
        text(Progress.Chapter(state),17,C.amber)
        local level,name=Progress.Level(state)
        text(string.format("%s Lv.%d · 携带容量%d份",name,level,Progress.Capacity(state)),13)
        text("装备、住房手续、买车与职业报名需到南城车行前台。",11,C.muted)
        button("导航到南城车行",function() a.setWaypoint("dealer"); a.closePhone() end,true)
        text("骑手装备",16,C.cyan)
        for _,item in ipairs(Progress.Equipment) do
            local id=item.id
            text(item.description,10,C.muted)
            button((state.equipment and state.equipment[id] and "已拥有 · " or "购入 · ")..item.name..string.format(" ¥%.0f / Lv.%d",item.price/100,item.level),function() a.buyEquipment(id) end,false)
        end
        text("改善住处 · 按晚付费",16,C.cyan)
        text("首版租住服务统一从旧宅门厅进入，地图中可导航。",10,C.muted)
        for _,item in ipairs(Progress.Housing) do
            local id=item.id
            button((state.accommodation==id and "当前 · " or "选择 · ")..item.name..string.format(" ¥%.0f/晚",item.price/100),function() a.housing(id) end,false)
        end
        button("前往旧宅门厅过夜",function() a.setWaypoint("home_old"); a.closePhone() end,false)
        button("在门厅办理当前住处过夜",a.sleepHousing,false)
        text("工作周 · 解锁后可选",16,C.cyan)
        text("先亲送10单并休息过。一次推进7游戏日，收入与生活支出分笔记账。",11,C.muted)
        button("查看并确认7天排班",a.workWeek,false)
        text("人生第一辆摩托",16,C.cyan)
        text("现金达到5万元后首购二手训练版：46000元；另备2000元护具训练、2000元周转。",11,C.muted)
        for _,item in ipairs(Progress.Motorcycles) do
            local id=item.id
            button((state.ownedMotorcycles[id] and "已拥有 · " or "购买 · ")..item.name..string.format(" ¥%.0f",item.price/100),function() a.buyMotorcycle(id) end,false)
        end
        button("三天入门训练与护具 · 总计2000元",a.train,true)
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
        button("街边充电 · 2元",a.charge,false)
        button("低现金基础帮助（不发现金）",a.aid,false)
        if a.progression then button("装备 / 住房 / 生涯发展",a.progression,true) end
    end
end
function View:Update(state,actor,target,active,offer,dt)
    self.lastActor,self.lastTarget=actor,target
    self.status:SetText(string.format("王二狗  %s  第%d天 %02d:%02d\n饱腹 %.0f · 精力 %.0f · 电量 %.0f%%",money(state.cashCents),state.day,
        math.floor(state.time),math.floor(state.time*60)%60,state.hunger,state.energy,state.battery))
    self.objective:SetText(target and (target.name..string.format(" · %.0f米",target.distance)) or "打开右下角手机 → 外卖骑手 → 上线听单")
    self.hint:SetText(target and target.hint or "先活下去，再跑出自己的路。")
    self.speed:SetText(actor.mounted and string.format("9号电动车  %.0f km/h",math.abs(actor.speed)*3.6) or "步行 · 车辆停在原处")
    self.map:SetTelemetry(actor,target,active)
    self.noticeTime=math.max(0,(self.noticeTime or 0)-(dt or .2))
    if self.noticeTime==0 then self.notice:SetText("") end
end
function View:GetInput()
    local function down(key) return input:GetKeyDown(key) end
    local x=((down(KEY_D) or down(KEY_RIGHT) or self.input.right) and 1 or 0)-((down(KEY_A) or down(KEY_LEFT) or self.input.left) and 1 or 0)
    local y=((down(KEY_W) or down(KEY_UP) or self.input.forward) and 1 or 0)-((down(KEY_S) or down(KEY_DOWN) or self.input.back) and 1 or 0)
    return {steer=x,throttle=y,walkX=x,walkY=y,run=down(KEY_SHIFT),brake=down(KEY_SPACE)}
end
function View:ResetInput() for key in pairs(self.input) do self.input[key]=false end end
function View:Dispose() self:ResetInput(); self.root:Destroy() end
return View
