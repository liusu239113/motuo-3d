-- 常用手机信息结构；所有数据只读现有Profile，点击只发生产actions。
local UI=require("urhox-libs/UI")
local K=require("Career.PhoneKit")
local Config=require("Career.Config")
local Progress=require("Career.Progression")
local Engagements=require("Career.Engagements")
local C=K.C
local Apps={}
local INTRO={
    {text="二狗，车钥匙给你了。那辆9号以前是我追对象时留下的，壳子磕过，电池还能用。后架我给你装了保温箱。",self=false},
    {text="先把饭吃上，晚上桥下或者公园能落脚。送餐别急，停稳下车再拿。等你真攒够五万，咱去车行看看。",self=false},
    {text="这回，先把生活跑顺。",self=true},
}
local KINDS={opening="初始生活现金",delivery="配送到账",meal="早餐用餐",charge="街边充电",lodging="住宿过夜",housing="住宿过夜",
    accommodation="住宿过夜",equipment="骑手装备",motorcycle="购入摩托",training="护具与训练",
    race_entry="赛事报名",career_race="赛事奖金",scheduled_delivery="排班配送",scheduled_living="排班生活支出",
    engagement="联系人委托谢礼",team_signing="车队首轮合同奖金",team_sponsor="车队赞助",payment="生活支出",
    sponsor="车队赞助",fuel="摩托燃油",refuel="摩托燃油",home_purchase="房产买断"}
function Apps.LedgerName(entry) return KINDS[entry.kind] or entry.kind end
-- 今日真正发生的收支，不将开局本金包装为今天挣到的钱。
function Apps.Today(state)
    local income,expense=0,0
    for _,entry in ipairs(state.ledger) do
        if entry.day==state.day and entry.kind~="opening" then
            if entry.deltaCents>0 then income=income+entry.deltaCents
            elseif entry.deltaCents<0 then expense=expense-entry.deltaCents end
        end
    end
    return income,expense
end
function Apps.Threads(state)
    local events=Engagements.State(state)
    local journal=Progress.StoryLog(state)
    ---@type table[]
    local threads={
        {id="cousin",name="表哥",initial="哥",summary=INTRO[2].text,time="第1天 · 留言",messages=INTRO,items={},letters={}},
        {id="station_master",name="早餐店站长",initial="站",summary="驻点委托与回信",time="现场联系人",messages={},items={},letters={}},
        {id="mechanic",name="车行师傅",initial="修",summary="驻点委托与回信",time="现场联系人",messages={},items={},letters={}},
        {id="journal",name="我的生涯记录",initial="记",summary=#journal>0 and journal[#journal].title or "还没有已读经历，先把第一单跑好。",
            time="已读经历",messages={},items={},letters={},journal=journal},
    }
    for _,thread in ipairs(threads) do
        local parts={thread.id}
        for _,item in ipairs(events.list) do
            if item.npcId==thread.id then
                thread.items[#thread.items+1]=item
                thread.summary=item.title.." · "..(({locked="尚未解锁",available="可现场接取",active="进行中",ready="待当面交付",claimed="已交付"})[item.status])
                parts[#parts+1]=item.id..":"..item.status..":"..item.progressText
            end
        end
        for _,letter in ipairs(events.letters) do
            for _,item in ipairs(thread.items) do
                if letter.instanceId==item.instanceId then
                    thread.letters[#thread.letters+1]=letter
                    thread.summary=letter.title; thread.time=K.Stamp(letter.day,letter.time)
                    parts[#parts+1]=letter.id
                end
            end
        end
        for _,story in ipairs(thread.journal or {}) do parts[#parts+1]=story.id end
        thread.signature=table.concat(parts,"|")
        thread.unreadCount=thread.id=="cousin" and 2 or #thread.letters+#(thread.journal or {})
        for _,item in ipairs(thread.items) do if item.status=="available" or item.status=="ready" then thread.unreadCount=thread.unreadCount+1 end end
    end
    return threads
end
---@param view CareerView
function Apps.Reset(view)
    view.phoneChatId=""; view.phoneLedgerId=""; view.phoneWalletFilter="all"
    view.phoneReadThreads=view.phoneReadThreads or {}
end
---@param view CareerView
function Apps.Back(view)
    if view.phonePage=="messages" and view.phoneChatId~="" then
        view.phoneChatId=""; view.phoneContent:ScrollToTop(); view:BuildPhone(view.phoneAppState,view.phoneAppOffer,view.phoneAppActive)
    elseif view.phonePage=="wallet" and view.phoneLedgerId~="" then
        view.phoneLedgerId=""; view.phoneContent:ScrollToTop(); view:BuildPhone(view.phoneAppState,view.phoneAppOffer,view.phoneAppActive)
    else view.actions.phone("apps") end
end
---@param view CareerView
local function rebuild(view)
    view.phoneContent:ScrollToTop()
    view:BuildPhone(view.phoneAppState,view.phoneAppOffer,view.phoneAppActive)
end
local function avatar(thread,size)
    return UI.Avatar{name=thread.name,initials=thread.initial,size=size or 38,shape="rounded",pointerEvents="none",
        backgroundColor=thread.id=="cousin" and {64,133,106,255} or {86,119,141,255}}
end
local function bubble(content,text,isSelf,id,name)
    local row=UI.Row{id=id,width="100%",padding=0,gap=6,justifyContent=isSelf and "flex-end" or "flex-start",alignItems="flex-start"}
    local person={id=isSelf and "self" or "npc",name=name,initial=isSelf and "我" or name=="表哥" and "哥" or "信"}
    if not isSelf then row:AddChild(avatar(person,28)) end
    row:AddChild(K.Card(id.."-bubble",{width="78%",padding=8,borderRadius=9,
        backgroundColor=isSelf and {191,227,199,255} or C.white,children={K.Text(text,11,C.ink)}}))
    if isSelf then row:AddChild(avatar(person,28)) end
    content:AddChild(row)
end
-- 联系人姓名/摘要/时间是信息文案，使用同源自然测高；不截正文、
-- 不再用固定24px行盒或省略算法掩盖字体实际行高与窄屏换行。
local function listLine(text,size,color,id,weight)
    return K.Text(text:gsub("[\r\n]+"," "),size,color,{id=id,width="100%",
        fontWeight=weight or "normal"})
end
local function listTime(thread)
    local last=thread.letters[#thread.letters]
    if last then return "第"..last.day.."天" end
    if thread.id=="cousin" then return "第1天" end
    return thread.id=="journal" and "经历" or "驻点"
end
---@param view CareerView
function Apps.Messages(view,content,state)
    local threads=Apps.Threads(state)
    local selected
    for _,thread in ipairs(threads) do if thread.id==view.phoneChatId then selected=thread end end
    if not selected then
        content:AddChild(K.Heading("消息","剧情联系人 · 会话与现场委托","career-message-heading"))
        local list=K.Card("career-message-conversations",{padding=0,gap=0,overflow="hidden"})
        content:AddChild(list)
        for _,thread in ipairs(threads) do
            local item=thread
            local unread=view.phoneReadThreads[item.id]~=item.signature and item.unreadCount or 0
            -- 当前UI命中先递归子树，不能仅依赖父级box-only；装饰子容器显式穿透。
            local info=UI.Panel{flexGrow=1,flexShrink=1,flexBasis=0,minWidth=0,padding=0,pointerEvents="none",children={
                listLine(item.name,12,C.ink,"career-chat-name-"..item.id,"bold")}}
            local side=UI.Panel{width=34,minWidth=34,padding=0,gap=2,alignItems="flex-end",pointerEvents="none",children={
                listLine(listTime(item),8,C.muted,"career-chat-time-"..item.id)}}
            if unread>0 then side:AddChild(UI.Badge{id="career-chat-unread-"..item.id,content=unread,size="sm",variant="error",pointerEvents="none"}) end
            list:AddChild(UI.Panel{id="career-chat-"..item.id,width="100%",minHeight=78,padding=8,gap=7,
                borderBottomWidth=1,borderBottomColor=C.line,pointerEvents="box-only",
                onClick=function()
                    view.phoneChatId=item.id; view.phoneReadThreads[item.id]=item.signature; rebuild(view)
                end,children={UI.Row{width="100%",padding=0,gap=7,alignItems="center",pointerEvents="none",
                    children={avatar(item),info,side}},
                    listLine(item.summary,10,C.muted,"career-chat-summary-"..item.id)}})
        end
        content:AddChild(K.Text("未读只在本次游玩中标记；这里不是联网真人聊天。",9,C.muted,{id="career-message-scope"}))
        return
    end
    view.phoneReadThreads[selected.id]=selected.signature
    view.phoneTitle:SetText("联系人")
    view.phoneBack:SetText("会话")
    content:AddChild(UI.Row{id="career-chat-header",width="100%",padding=0,gap=8,alignItems="center",children={
        avatar(selected,32),K.Text(selected.name.."\n剧情记录 · 非实时通讯",10,C.muted,
            {id="career-chat-header-info",flexGrow=1,flexShrink=1,flexBasis=0,minWidth=0})}})
    content:AddChild(K.Text(selected.time,9,C.muted,{textAlign="center"}))
    for index,message in ipairs(selected.messages) do
        bubble(content,message.text,message.self,"career-chat-bubble-"..index,selected.name)
    end
    for _,letter in ipairs(selected.letters) do
        content:AddChild(K.Text(K.Stamp(letter.day,letter.time).." · "..letter.title,9,C.muted,{textAlign="center"}))
        bubble(content,letter.text,false,"career-chat-letter-"..letter.id,selected.name)
    end
    for _,story in ipairs(selected.journal or {}) do
        content:AddChild(K.Card("career-chat-story-"..story.id,{children={K.Tag("已发生 · 已读经历"),
            K.Text(story.title,12,C.ink,{fontWeight="bold"}),K.Text(story.text,11,C.ink)}}))
    end
    if selected.id=="journal" and #selected.journal==0 then
        content:AddChild(K.Card("career-chat-empty",{children={K.Text("还没有已读经历",13),K.Text(selected.summary,11,C.muted)}}))
    end
    for _,event in ipairs(selected.items) do
        local item=event
        local card=K.Card("career-chat-engagement-"..item.id)
        content:AddChild(card)
        card:AddChild(K.Tag(({locked="尚未解锁",available="可现场接取",active="进行中",ready="待当面交付",claimed="已交付"})[item.status]))
        card:AddChild(K.Text(item.title,13,C.ink,{fontWeight="bold"}))
        card:AddChild(K.Text(item.description,11,C.muted))
        card:AddChild(K.Text(item.objectiveText,11,C.muted,{id="career-chat-objective-"..item.id}))
        card:AddChild(K.Text(item.progressText,10,C.ink,{id="career-chat-progress-"..item.id}))
        card:AddChild(K.Text("一次性谢礼 "..K.Money(item.rewardCents).." · 到驻点当面办理",10,C.green))
        if item.status=="available" then
            card:AddChild(K.Button("现场接取",function() view.actions.acceptEngagement(item.id) end,"career-engagement-"..item.id,true))
        elseif item.status=="ready" then
            card:AddChild(K.Button("返回交付",function() view.actions.claimEngagement(item.instanceId) end,"career-claim-"..item.id,true))
        end
        if item.status~="claimed" then
            local point=item.nextPointId or item.acceptPointId
            card:AddChild(K.Text("导航地点\n"..Config.points[point].label,11,C.muted))
            card:AddChild(K.Button("设为导航",function() view.actions.setWaypoint(point); view.actions.closePhone() end,
                "career-chat-navigate-"..item.id,false))
            if item.status=="active" and point~=item.returnPointId then
                card:AddChild(K.Button("确认访问",function() view.actions.visitEngagement(point) end,
                    "career-chat-visit-"..item.id,false))
            end
        end
    end
    -- 只有业务引导，不伪造发信/对方已读/自动回复。
    if selected.id=="cousin" then
        content:AddChild(K.Text("快捷办理 · 不发送聊天消息",9,C.muted))
        content:AddChild(K.Button("吃饭与落脚",function() view.actions.phone("life") end,"career-chat-quick-life",false))
    elseif selected.id=="mechanic" then
        content:AddChild(K.Button("查看车手生涯",function() view.actions.phone("progression") end,"career-chat-quick-career",false))
    elseif selected.id=="station_master" then
        content:AddChild(K.Button("打开外卖工作台",function() view.actions.phone("delivery") end,"career-chat-quick-delivery",false))
    end
end
---@param view CareerView
function Apps.Wallet(view,content,state)
    local selected
    for _,entry in ipairs(state.ledger) do if entry.id==view.phoneLedgerId then selected=entry end end
    if selected then
        view.phoneBack:SetText("账单")
        content:AddChild(K.Heading("账单详情",Apps.LedgerName(selected),"career-wallet-detail"))
        content:AddChild(K.Card("career-wallet-detail-card",{children={
            K.Tag(selected.kind=="opening" and "初始本金" or selected.deltaCents>=0 and "收入 · 已入账" or "支出 · 已记账"),
            K.Text(string.format("%+.2f",selected.deltaCents/100),26,selected.deltaCents>0 and C.green or C.ink,{fontWeight="bold"}),
            K.Text(K.Stamp(selected.day,selected.time),11,C.muted),
            K.Text("账后余额  "..K.Money(selected.balanceCents),12),
            K.Text("流水类型  "..Apps.LedgerName(selected),10,C.muted),K.Text("流水编号\n"..selected.id,10,C.muted,{id="career-wallet-detail-id"}),
            K.Text("来自本局真实现金流水；仅查看，不可转账、充值或修改。",10,C.muted)}}))
        content:AddChild(K.Button("返回收支明细",function() view.phoneLedgerId=""; rebuild(view) end,"career-wallet-detail-back",false))
        return
    end
    content:AddChild(K.Heading("钱包","生活现金 · 与独立竞速金币分开","career-wallet-heading"))
    local income,expense=Apps.Today(state)
    local card=K.Card("career-wallet-balance-card",{padding=13,gap=9,backgroundColor={23,89,67,255},children={
        K.Text("可用余额（元）",10,{191,222,207,255}),
        K.Text(K.Money(state.cashCents),27,C.white,{id="career-wallet-balance",fontWeight="bold"}),
        K.Text("王二狗 · 生涯现金",9,{191,222,207,255}),
        UI.Row{width="100%",paddingTop=8,borderTopWidth=1,borderTopColor={84,143,113,255},children={
            K.Stat("今日收入",K.Money(income),C.white),K.Stat("今日支出",K.Money(expense),C.white)}}}})
    content:AddChild(card)
    content:AddChild(K.Text("今日按第"..state.day.."天流水汇总，不含开局本金。",9,C.muted,{id="career-wallet-today-note"}))
    content:AddChild(K.Text("收支明细",13,C.ink,{fontWeight="bold"}))
    local filters=UI.Row{id="career-wallet-filters",width="100%",padding=0,gap=4}
    for _,filter in ipairs({{"all","全部"},{"income","收入"},{"expense","支出"}}) do
        local key=filter[1]
        filters:AddChild(K.Button(filter[2],function() view.phoneWalletFilter=key; rebuild(view) end,
            "career-wallet-filter-"..key,view.phoneWalletFilter==key,{width="31%",flexGrow=1,flexShrink=1,flexBasis=0}))
    end
    content:AddChild(filters)
    local list=K.Card("career-wallet-ledger",{padding=0,gap=0})
    content:AddChild(list)
    local count=0
    for i=#state.ledger,1,-1 do
        local entry=state.ledger[i]
        local filter=view.phoneWalletFilter
        if filter=="all" or filter=="income" and entry.deltaCents>0 and entry.kind~="opening"
            or filter=="expense" and entry.deltaCents<0 then
            count=count+1
            local detail=entry
            list:AddChild(UI.Panel{id="career-wallet-entry-"..i,width="100%",minHeight=86,padding=8,gap=4,
                pointerEvents="box-only",borderBottomWidth=1,borderBottomColor=C.line,
                onClick=function() view.phoneLedgerId=detail.id; rebuild(view) end,children={
                    K.Text(Apps.LedgerName(entry),12,C.ink,{fontWeight="bold"}),
                    K.Text(string.format("%+.2f",entry.deltaCents/100),13,entry.deltaCents>0 and C.green or C.ink,
                        {id="career-wallet-entry-amount-"..i,fontWeight="bold"}),
                    K.Text(K.Stamp(entry.day,entry.time),9,C.muted),
                    K.Text(entry.kind=="opening" and "本金 · 非配送收入" or "已记账 · 点开详情",9,C.muted)}})
        end
    end
    if count==0 then list:AddChild(K.Text("暂无"..(view.phoneWalletFilter=="income" and "收入" or "支出").."记录\n完成配送或发生消费后会在这里显示。",11,C.muted,
        {id="career-wallet-empty",padding=12})) end
    content:AddChild(K.Text("共"..count.."笔 · 点击账单可查看真实编号与账后余额",9,C.muted,{id="career-wallet-count"}))
    local archive=K.Card("career-wallet-storage",{children={K.Text("存档与备份",12,C.ink,{fontWeight="bold"}),
        K.Text(view.actions.saveStatus and view.actions.saveStatus() or "本地保存不等于云端确认。",9,C.muted),
        K.Text("保存会写本地并尝试账号云同步；读取云档需再次确认。",10,C.muted),
        K.Button("保存与同步",view.actions.save,"career-wallet-save",true),
        K.Button("读取云档",view.actions.loadCloud,"career-wallet-load",false)}})
    content:AddChild(archive)
end
local function routeRow(number,title,point,highlight)
    return UI.Row{width="100%",padding=0,gap=7,alignItems="flex-start",children={
        K.Text(number,10,highlight and C.green or C.muted,{width=28,flexShrink=0,textAlign="center",borderRadius=14,backgroundColor=C.pale}),
        UI.Panel{flexGrow=1,flexShrink=1,flexBasis=0,minWidth=0,padding=0,gap=2,children={
            K.Text(title,9,highlight and C.green or C.muted),K.Text(Config.points[point].label,11,C.ink,{fontWeight="bold"})}}}}
end
local function offerCard(content,offer,actions,stacked)
    local card=K.Card(stacked and "career-delivery-stack-offer" or "career-delivery-offer")
    content:AddChild(card)
    card:AddChild(K.Tag(offer.tutorial and "新手教学单 · 固定5元" or "新订单 · 接单锁价",C.orange))
    card:AddChild(K.Text(offer.title,14,C.ink,{fontWeight="bold"}))
    card:AddChild(K.Text(K.Money(offer.feeCents),25,C.orange,{id="career-delivery-quote",fontWeight="bold"}))
    card:AddChild(K.Text(string.format("路线 %.0f米 · 配送时限 %.0f游戏分钟",offer.distanceMeters,offer.remainingHours*60),9,C.muted))
    card:AddChild(routeRow("取","到店取餐",offer.pickupId,true))
    card:AddChild(routeRow("送","送到顾客",offer.dropoffId,false))
    card:AddChild(K.Button(stacked and "加接订单" or "接单",actions.accept,stacked and "career-accept-stack" or "career-accept",true))
end
---@param view CareerView
function Apps.Delivery(view,content,state,offer,active)
    local World=require("Career.WorldData")
    local position=view.lastActor or state.position
    content:AddChild(K.Heading("骑手工作台",World.District(position.x,position.z).label.."站","career-delivery-heading"))
    local income=Apps.Today(state)
    content:AddChild(K.Card("career-delivery-status-card",{padding=8,gap=6,children={
        UI.Row{width="100%",padding=0,gap=5,alignItems="center",children={
            K.Text(state.online and "正在听单" or "休息中",11,C.green,
                {id="career-delivery-online-label",flexGrow=1,flexShrink=1,flexBasis=0,minWidth=0,fontWeight="bold"}),
            K.Button(state.online and "停止听单" or "上线听单",function() view.actions.online(not state.online) end,"career-online",not state.online,{width=86})}},
        UI.Row{width="100%",padding=0,children={K.Stat("已完成",state.completedOrders.."单"),K.Stat("今日总收入",K.Money(income))}}}}))
    if active then
        local picked=active.status~="accepted"
        local card=K.Card("career-delivery-active")
        content:AddChild(card)
        card:AddChild(K.Tag(picked and "2 / 2 · 配送中" or "1 / 2 · 待取餐",picked and C.green or C.orange))
        card:AddChild(K.Text(active.title,14,C.ink,{fontWeight="bold"}))
        card:AddChild(UI.ProgressBar{id="career-delivery-progress",value=picked and .7 or .25,height=4,borderRadius=2,fillColor=C.green,backgroundColor=C.line,showLabel=false})
        card:AddChild(K.Text(string.format("剩余 %.0f 游戏分钟",math.max(0,active.remainingHours*60)),13,C.orange,{id="career-delivery-countdown"}))
        card:AddChild(K.Text("锁定报酬  "..K.Money(active.feeCents),12,C.green,{id="career-delivery-locked-fee"}))
        card:AddChild(routeRow(picked and "已" or "取",picked and "已取餐" or "当前目标 · 到店取餐",active.pickupId,not picked))
        card:AddChild(routeRow("送",picked and "当前目标 · 送达顾客" or "下一步 · 送达顾客",active.dropoffId,picked))
        card:AddChild(K.Button("导航到当前任务",function() view.actions.setWaypoint(picked and active.dropoffId or active.pickupId); view.actions.closePhone() end,"career-order-navigation",true))
        local orderId=active.id
        card:AddChild(K.Button("联系顾客",function() view.actions.callCustomer(orderId) end,"career-order-call",false))
        card:AddChild(K.Button(picked and "交付外卖" or "到店取餐",view.actions.interact,"career-order-interact",false))
        card:AddChild(K.Text("必须到真实取送点停稳、下车后交接；按钮仍核对现场位置。",9,C.muted))
        if #state.activeOrders>1 then
            content:AddChild(K.Text("配送队列 · "..#state.activeOrders.." / "..Progress.Capacity(state),13,C.ink,{fontWeight="bold"}))
            for index,order in ipairs(state.activeOrders) do
                local id=order.id
                local row=K.Card("career-delivery-order-"..index,{children={K.Tag(order.id==active.id and "当前任务" or "可切换任务"),
                    K.Text(order.title,12),K.Text((order.status=="accepted" and "待取餐" or "待送达").." · "..K.Money(order.feeCents),10,C.muted),
                    K.Button("切换此订单",function() view.actions.selectOrder(id) end,"career-order-select-"..index,false)}})
                content:AddChild(row)
            end
        end
        if state.online and offer and #state.activeOrders<Progress.Capacity(state) then offerCard(content,offer,view.actions,true) end
        content:AddChild(K.Text("临时导航去补给不取消订单；回到本页可切回订单导航。",9,C.muted))
    elseif state.online and offer then offerCard(content,offer,view.actions,false)
    else
        content:AddChild(K.Card("career-delivery-empty",{children={K.Text(state.online and "暂时没有可接订单" or "准备好，再出发",15,C.ink,{fontWeight="bold"}),
            K.Text(state.online and "当前区域或时段没有合适报价。可检查时间、身体状态或前往其他区域。" or "上线后在此查看真实报价，接单后显示取餐与送达进度。",11,C.muted)}}))
    end
    content:AddChild(K.Text("普通单配送费2.50～10.00元，接单锁价，绕路不加价。长途订单预留更多时限；当日来不及完成不派发。",9,C.muted))
end
---@param view CareerView
function Apps.Call(view,content)
    local call=view.phoneCall
    view.phoneTitle:SetText("顾客电话")
    content:AddChild(K.Heading("订单顾客",call and call.place or "本次通话已结束","career-call-heading"))
    if not call then return end
    content:AddChild(K.Text(call.phase=="ringing" and "正在呼叫……" or "已接通 · 游戏内模拟通话",17,C.green,{id="career-call-phase"}))
    if call.phase=="connected" then
        content:AddChild(K.Card("career-call-rider",{children={K.Text("王二狗",12,C.green),K.Text(call.rider,16,C.ink,{id="career-call-rider-line"})}}))
        content:AddChild(K.Card("career-call-customer",{children={K.Text("顾客",12,C.blue),K.Text(call.customer,16,C.ink,{id="career-call-customer-line"})}}))
    end
    content:AddChild(K.Button("挂断并返回订单",function() view.actions.endCall(); view.actions.phone("delivery") end,"career-call-hangup",true))
    content:AddChild(K.Text("不拨打真实号码，不代替现场交接。正式人声待确认声线后接入，当前为铃声与对白文字。",11,C.muted))
end
return Apps
