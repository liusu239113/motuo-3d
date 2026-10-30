-- 手机重做验收与实拍。仅显式test=true会话；真实Yoga/触摸/生产actions；无真实档或云。
local UI=require("urhox-libs/UI")
local PointerEvent=require("urhox-libs/UI/Core/PointerEvent")
local Store=require("Career.Store")
local Delivery=require("Career.Delivery")
local Config=require("Career.Config")
local Progress=require("Career.Progression")
local Apps=require("Career.PhoneApps")
local Checks={}
---@param session CareerSession
local function isolated(session)
    assert(session.options and session.options.test==true and type(session.restoreTestStorage)=="function",
        "PhoneAppChecks requires explicit test=true memory-only Session")
    assert(session.running and session.actor and UI.GetRoot()==session.view.root,"手机验收需要已挂载游戏会话")
end
---@param view CareerView
local function layout(view)
    require("Career.PhoneKit").LayoutTree(view.phoneArea)
end
-- 全树而非首屏：以真实字体/字号测自然行高，检查父内容框与按钮文字。
-- ScrollView是有意的纵向裁剪；地图绘图内部的小标记不是手机文案卡片。
---@param view CareerView
function Checks.Audit(view,context)
    layout(view)
    local count=0
    local function inspect(widget)
        if not widget:IsVisible() or widget.props.visibility=="hidden" or widget.props.id=="career-phone-map" then return end
        local p=widget.props
        local kind=widget._className
        if (kind=="Label" or kind=="Button") and type(p.text)=="string" and p.text~="" then
            local r=widget:GetAbsoluteLayout()
            local name=tostring(p.id or p.text:sub(1,60))
            assert(r.w>0 and r.h>0,"文字布局为零 "..context.." / "..name)
            local pl,pr,pt,pb=p.paddingLeft or 0,p.paddingRight or 0,p.paddingTop or 0,p.paddingBottom or 0
            local width,height=r.w-pl-pr,r.h-pt-pb
            local size=UI.Theme.FontSize(p.fontSize)
            local multiline=kind=="Label" and p.whiteSpace=="normal"
            local measured=UI.MeasureTextFit(p.text,{fontSize=size,minFontSize=size,
                fontFace=UI.Theme.FontFace(p.fontFamily,p.fontWeight),width=math.max(1,width-2),
                multiline=multiline,lineHeight=p.lineHeight or (kind=="Label" and 1.4 or 1),letterSpacing=p.letterSpacing or 0})
            assert(measured.width>0 and measured.height>0,"字体测量未就绪 "..name)
            if not multiline then
                assert(measured.width<=width+1,"单行文案溢出 "..context.." / "..name.." measured="..measured.width.." available="..width)
            else
                -- NanoVG行断点bounds偶尔包含触发换行的一个字；不把它误认作实际越界。
                assert(measured.width<=width+size+1,"多行文案不可换行 "..context.." / "..name)
            end
            assert(measured.height<=height+1,"文字高度裁切 "..context.." / "..name.." measured="..measured.height.." available="..height)
            local rendered=kind=="Label" and require("Career.PhoneKit").RenderedTextMetrics(widget) or nil
            if rendered then
                assert(rendered.textHeight<=height+1,"真实Render文字高度裁切 "..context.." / "..name
                    .." rendered="..rendered.textHeight.." available="..height.." breakWidth="..rendered.breakWidth)
            end
            local parent=widget.parent
            if parent and parent._className~="ScrollView" then
                local b=parent:GetAbsoluteLayout()
                local q=parent.props
                assert(r.x>=b.x+(q.paddingLeft or 0)-1 and r.x+r.w<=b.x+b.w-(q.paddingRight or 0)+1,
                    "文字超出父内容宽度 "..context.." / "..name)
                assert(r.y>=b.y-1 and r.y+r.h<=b.y+b.h+1,string.format(
                    "文字超出父高度 %s / %s child=(%.6f,%.6f) parent=(%.6f,%.6f) propsH=%s parentH=%s padding=(%s,%s)",
                    context,name,r.y,r.h,b.y,b.h,tostring(p.height),tostring(q.height),tostring(p.paddingTop),tostring(p.paddingBottom)))
            end
            if kind=="Button" then assert(r.w>=44 and r.h>=44,"动作真实尺寸不足44 "..name) end
            count=count+1
        end
        for _,child in ipairs(widget:GetChildren()) do inspect(child) end
    end
    if view.phonePage=="apps" then inspect(view.phoneDesktop)
    else
        local selected=view.phoneContent:GetPage()
        local expected={}
        for _,unit in ipairs(view.phoneContent.units) do
            for widget in pairs(unit.members) do expected[widget]=true end
        end
        local visited={}
        local function visible(widget)
            if not widget:IsVisible() then return end
            assert(widget._className~="ScrollView","手机分页不能含ScrollView")
            local r=widget:GetAbsoluteLayout()
            local area=view.phoneContent:GetAbsoluteLayout()
            assert(r.x>=area.x-1 and r.x+r.w<=area.x+area.w+1 and r.y>=area.y-1 and r.y+r.h<=area.y+area.h+1,
                "分页控件必须完整处于内容区 "..tostring(widget.props.id or widget._className))
            visited[widget]=true
            for _,child in ipairs(widget:GetChildren()) do visible(child) end
        end
        for page=1,view.phoneContent:GetPageCount() do
            view.phoneContent:SetPage(page);layout(view)
            inspect(view.phoneContent)
            for _,child in ipairs(view.phoneContent:GetChildren()) do visible(child) end
        end
        for widget in pairs(expected) do assert(visited[widget],"分页遗漏源控件 "..tostring(widget.props.id or widget._className)) end
        -- Every UTF-8 continuation must reconstruct its original body exactly.
        local continuations={}
        for _,unit in ipairs(view.phoneContent.units) do
            if unit.widget~=unit.source then
                continuations[unit.source]=(continuations[unit.source] or "")..unit.widget.props.text
            end
        end
        for source,full in pairs(continuations) do assert(full==source.props.text,"分页正文丢字/重复/顺序错误") end
        view.phoneContent:SetPage(selected);layout(view)
        inspect(assert(view.phoneBody:FindById("career-phone-pagination")))
    end
    inspect(assert(view.phoneBody:FindById("career-phone-toolbar")))
    print(string.format("[手机全页文案验收] %s / %d项 / 真实字体测宽测高/父边界/无缩字",context,count))
    return count
end
---@param view CareerView
---@return Widget
local function find(view,id) return assert(view.phoneBody:FindById(id),"缺少真实手机组件 "..id) end
---@param view CareerView
local function visibleTextLayout(view,id)
    layout(view)
    local label=find(view,id)
    local r=label:GetAbsoluteLayout()
    print(string.format("[手机文字布局] %s rect=(%.1f,%.1f,%.1f,%.1f)",id,r.x,r.y,r.w,r.h))
    assert(r.w>0 and r.h>0,"手机文字真实Yoga宽高必须大于0 "..id)
end
---@param view CareerView
local function tap(view,id)
    layout(view)
    local widget=find(view,id)
    local fixed=id=="career-phone-back" or id=="career-phone-close" or id=="career-phone-page-prev" or id=="career-phone-page-next"
    if not fixed and view.phonePage~="apps" then
        assert(view.phoneContent:ShowWidget(widget),"目标必须存在于真实分页计划 "..id)
        layout(view)
    end
    local r=widget:GetAbsoluteLayoutForHitTest()
    local scale=UI.GetScale()
    print(string.format("[手机触摸尺寸] %s hit=(%.9f,%.9f,%.9f,%.9f) physical=(%.9f,%.9f) scale=%.12f configuredH=%s minH=%s minW=%s",
        id,r.x,r.y,r.w,r.h,r.w*scale,r.h*scale,scale,tostring(widget.props.height),tostring(widget.props.minHeight),tostring(widget.props.minWidth)))
    assert(r.w>=44 and r.h>=44,"触摸目标小于44px "..id)
    if not fixed and view.phonePage~="apps" then
        local area=view.phoneContent:GetAbsoluteLayoutForHitTest()
        assert(r.x>=area.x-1 and r.x+r.w<=area.x+area.w+1 and r.y>=area.y-1 and r.y+r.h<=area.y+area.h+1,
            "触摸目标必须完整显示，不能切半 "..id)
    end
    local function event(kind)
        return PointerEvent.new(kind,{pointerId=791210,pointerType="touch",isPrimary=true,
            x=(r.x+r.w/2)*scale,y=(r.y+r.h/2)*scale,button=PointerEvent.Button.Left})
    end
    local down=event("PointerDown"); UI.HandlePointerEvent(down)
    local up=event("PointerUp"); UI.HandlePointerEvent(up)
    if down.target~=widget or up.target~=widget then
        local function description(target)
            if not target then return "nil" end
            local bounds=target:GetAbsoluteLayoutForHitTest()
            return string.format("%s#%s pe=%s rect=(%.1f,%.1f,%.1f,%.1f)",tostring(target._className),
                tostring(target.props.id),tostring(target.props.pointerEvents),bounds.x,bounds.y,bounds.w,bounds.h)
        end
        local sx,sy=view.phoneContent:GetScroll()
        local area=view.phoneContent:GetAbsoluteLayoutForHitTest()
        print(string.format("[手机触摸命中诊断] page=%s expected=%s down=%s up=%s scroll=(%.1f,%.1f) viewport=(%.1f,%.1f,%.1f,%.1f) scale=%.3f",
            view.phonePage,description(widget),description(down.target),description(up.target),sx,sy,area.x,area.y,area.w,area.h,scale))
        local ancestor=down.target
        for depth=1,7 do
            if not ancestor then break end
            print("[手机触摸命中祖先] "..depth.." "..description(ancestor))
            ancestor=ancestor.parent
        end
        error("实际触摸命中错误 "..id,0)
    end
end
local function deliverOne()
    local offer=assert(Delivery.GetOffer())
    assert(Delivery.Accept(offer.id))
    local pickup,dropoff=assert(Config.points[offer.pickupId]),assert(Config.points[offer.dropoffId])
    assert(Delivery.Pickup(offer.id,pickup.x,pickup.z,{riding=false,speed=0}))
    assert(Delivery.Deliver(offer.id,dropoff.x,dropoff.z,{riding=false,speed=0}))
    return offer
end
local function stories()
    for _=1,12 do
        local story=Progress.NextStory(Store.Get())
        if not story then break end
        assert(Progress.MarkStory(story.id))
    end
end
-- 所有余额、流水与经历都由现有业务成功产生，不造钱包行或完成数。
local function fixture()
    assert(Store.NewCareer())
    assert(Store.Transaction(function(p) p.phase="working"; p.flags.introSeen=true; return true end))
    deliverOne(); deliverOne(); deliverOne()
    assert(Store.Eat()); stories()
    local p=Store.Get()
    assert(#p.ledger==5 and p.completedOrders==3 and p.flags.firstDeliveryStory)
    return p
end
---@param session CareerSession
function Checks.Run(session)
    isolated(session)
    local view,actor=session.view,assert(session.actor)
    assert(view.phonePage=="" and not view.blocked,"请在无弹窗的游戏态运行手机验收")
    local oldScrollX,oldScrollY=view.phoneContent:GetScroll()
    local old={x=actor.x,z=actor.z,speed=actor.speed,mounted=actor.mounted,online=session.online,
        space=session.space,waypoint=session.waypoint,manual=session.manualWaypoint,navigation=session.navigation,
        notice=view.notice.props.text,noticeTime=view.noticeTime,lastActor=view.lastActor,lastTarget=view.lastTarget,
        phonePage=view.phonePage,chatId=view.phoneChatId,ledgerId=view.phoneLedgerId,walletFilter=view.phoneWalletFilter,
        readThreads=view.phoneReadThreads,appState=view.phoneAppState,appOffer=view.phoneAppOffer,appActive=view.phoneAppActive,
        mapDistrictId=view.mapDistrictId,mapPointPage=view.mapPointPage,mapPickerOpen=view.mapPickerOpen,
        scrollX=oldScrollX,scrollY=oldScrollY}
    view.phoneReadThreads={}
    local files,writes,cloud={},0,0
    local restore=Store.UseTestStorage({read=function(path) return files[path],nil,files[path]==nil end,
        write=function(path,text) files[path]=text; writes=writes+1; return true end,
        cloud={Get=function() cloud=cloud+1; error("phone checks forbid cloud reads") end,
            Set=function() cloud=cloud+1; error("phone checks forbid cloud writes") end}})
    local ok,failure=pcall(function()
        assert(Store.NewCareer())
        actor.x,actor.z,actor.speed,actor.mounted=300,-180,0,false
        session.online=false; session.space="city"; session:Refresh()
        local baseline=Store.Get()
        require("Career.MapPhoneChecks").RunLayout(view,session:State(),Delivery.GetOffer(),nil,function(page)
            Checks.Audit(view,"多尺寸/"..page)
            if page=="wallet" then
                tap(view,"career-wallet-filter-income")
                assert(find(view,"career-wallet-empty"),"多分辨率筛选应保留真实开局空态")
                Checks.Audit(view,"多尺寸/wallet-income")
                tap(view,"career-wallet-filter-expense")
                tap(view,"career-wallet-filter-all")
                tap(view,"career-wallet-entry-1")
                Checks.Audit(view,"多尺寸/wallet-detail")
                tap(view,"career-phone-back")
                assert(view.phonePage=="wallet" and view.phoneLedgerId=="","多分辨率详情返回没有回明细")
            elseif page=="messages" then
                for _,id in ipairs({"cousin","station_master","mechanic","journal"}) do
                    tap(view,"career-chat-"..id); Checks.Audit(view,"多尺寸/chat-"..id)
                    tap(view,"career-phone-back")
                end
            elseif page=="legacy-map" then
                local World=require("Career.WorldData")
                local districts={World.District(0,0)}
                for _,d in ipairs(World.Districts) do districts[#districts+1]=d end
                districts[#districts+1]=World.District(World.LIMIT-1,World.LIMIT-1)
                for _,d in ipairs(districts) do
                    tap(view,"career-map-region-toggle")
                    Checks.Audit(view,"多尺寸/map-picker-"..d.id)
                    tap(view,"career-map-region-"..d.id)
                    Checks.Audit(view,"多尺寸/map-"..d.id)
                    local nextPage=view.phoneBody:FindById("career-map-next")
                    if nextPage and not nextPage.props.disabled then
                        tap(view,"career-map-next"); Checks.Audit(view,"多尺寸/map-"..d.id.."-page2")
                    end
                end
            elseif page=="progression" then
                local before=Store.Get()
                -- 最贵装备与最贵车辆都走真实按钮；人物远离车行，必须现场拒绝而不扣款。
                tap(view,"career-equipment-battery")
                tap(view,"career-motorcycle-rally_3")
                assert(Store.Get().revision==before.revision and Store.Get().cashCents==before.cashCents,
                    "远处装备/最贵车辆按钮不可绕过现场授权")
                Checks.Audit(view,"多尺寸/progression-bottom")
            end
        end)
        view.phoneReadThreads={}
        session:OpenPhone("wallet")
        assert(find(view,"career-wallet-balance").props.text=="¥50.00")
        tap(view,"career-wallet-filter-income")
        assert(find(view,"career-wallet-empty") and Apps.Today(Store.Get())==0,"开局本金不能包装为收入")
        tap(view,"career-wallet-filter-all"); tap(view,"career-wallet-entry-1")
        assert(view.phoneLedgerId=="opening" and find(view,"career-wallet-detail-id").props.text:find("opening",1,true))
        tap(view,"career-phone-back")
        assert(view.phoneLedgerId=="" and view.phonePage=="wallet","账单返回应回明细")
        tap(view,"career-phone-back"); tap(view,"career-app-messages")
        assert(find(view,"career-message-conversations"):GetNumChildren()==4,"消息必须是真会话列表，不是堆Label")
        assert(find(view,"career-chat-unread-cousin"))
        tap(view,"career-chat-cousin")
        assert(view.phoneChatId=="cousin" and find(view,"career-chat-bubble-1") and find(view,"career-chat-bubble-3"))
        visibleTextLayout(view,"career-chat-header-info")
        local left=find(view,"career-chat-bubble-1").props.justifyContent
        local right=find(view,"career-chat-bubble-3").props.justifyContent
        assert(left=="flex-start" and right=="flex-end","既有剧情须有左右气泡")
        tap(view,"career-phone-back")
        assert(view.phoneChatId=="" and not view.phoneBody:FindById("career-chat-unread-cousin"),"本次打开已读不能仍显示未读")
        tap(view,"career-chat-cousin"); tap(view,"career-chat-quick-life")
        assert(view.phonePage=="life","快捷业务引导未打开生活")
        assert(Store.Get().revision==baseline.revision and writes==1,"消息阅读与钱包筛选不得写档")
        view:ClosePhone()
        local real=fixture()
        local income,expense=Apps.Today(real)
        assert(income>0 and expense==Config.MEAL_CENTS)
        session:Refresh(); session:OpenPhone("wallet")
        tap(view,"career-wallet-filter-income")
        assert(find(view,"career-wallet-ledger"):GetNumChildren()==3,"收入筛选必须只有真实配送记录")
        tap(view,"career-wallet-filter-expense")
        assert(find(view,"career-wallet-ledger"):GetNumChildren()==1,"支出筛选必须只有实际用餐")
        tap(view,"career-wallet-entry-5")
        assert(view.phoneLedgerId==real.ledger[5].id and find(view,"career-wallet-detail-card"))
        tap(view,"career-phone-back"); tap(view,"career-phone-back"); tap(view,"career-app-messages")
        tap(view,"career-chat-journal")
        assert(find(view,"career-chat-story-firstDeliveryStory"),"已有真实story log不可丢失")
        tap(view,"career-phone-back"); tap(view,"career-chat-station_master")
        Checks.Audit(view,"联系人可接取长文")
        local before=Store.Get()
        tap(view,"career-engagement-breakfast_shift")
        assert(Store.Get().revision==before.revision and not Store.Get().engagements,"远处手机接取仍须现场再次授权")
        view:ClosePhone(); session:OpenPhone("delivery")
        tap(view,"career-online")
        assert(session.online and find(view,"career-delivery-offer"))
        visibleTextLayout(view,"career-delivery-online-label")
        tap(view,"career-accept")
        local active=assert(Delivery.GetActive())
        assert(find(view,"career-delivery-active") and active.status=="accepted")
        Checks.Audit(view,"配送待取餐长文")
        -- 不改人物位置，真实按钮在远处不能代取餐或产生到账。
        local accepted=Store.Get()
        tap(view,"career-order-interact")
        assert(assert(Delivery.GetActive()).status=="accepted" and Store.Get().cashCents==accepted.cashCents)
        tap(view,"career-order-navigation")
        assert(view.phonePage=="" and session.waypoint==active.pickupId and not session.manualWaypoint)
        local p=assert(Config.points[active.pickupId])
        assert(Delivery.Pickup(active.id,p.x,p.z,{riding=false,speed=0}))
        session:OpenPhone("delivery")
        assert(find(view,"career-order-interact").props.text:find("交付",1,true),"已取餐必须切换送达状态")
        Checks.Audit(view,"配送已取餐长文")
        tap(view,"career-phone-close")
        assert(view.phonePage=="" and view.phoneContent:GetNumChildren()==0 and cloud==0)
        print(string.format("[手机应用验收通过] 真触摸会话/已读/左右气泡/真实剧情/业务引导/钱包初始空态/收支筛选/账单详情/听单/接单/取送导航；现场二次授权；内存写入%d次，云0次",writes))
    end)
    local cleaned,reason=pcall(function()
        view:CloseConversation(); view.overlay:SetVisible(false); view.blocked=false; view:ClosePhone()
        actor.x,actor.z,actor.speed,actor.mounted=old.x,old.z,old.speed,old.mounted
        session.online,session.space,session.waypoint=old.online,old.space,old.waypoint
        session.manualWaypoint,session.navigation=old.manual,old.navigation
    end)
    -- 恢复Store之后才刷新HUD；即使刷新报错，也必须把UI会话字段逐一恢复，
    -- 防止验收的未读/筛选/地图选择或fixture快照泄露回调用者。
    local restored,restoreFailure=pcall(restore)
    local refreshed,refreshFailure=pcall(function() session:Refresh() end)
    view.phonePage,view.phoneChatId,view.phoneLedgerId=old.phonePage,old.chatId,old.ledgerId
    view.phoneWalletFilter,view.phoneReadThreads=old.walletFilter,old.readThreads
    view.phoneAppState,view.phoneAppOffer,view.phoneAppActive=old.appState,old.appOffer,old.appActive
    view.mapDistrictId,view.mapPointPage,view.mapPickerOpen=old.mapDistrictId,old.mapPointPage,old.mapPickerOpen
    view.lastActor,view.lastTarget=old.lastActor,old.lastTarget
    local uiRestored,uiFailure=pcall(function()
        view.phoneContent:SetScroll(old.scrollX,old.scrollY)
        view.notice:SetText(old.notice or ""); view.noticeTime=old.noticeTime
    end)
    if not ok then error(failure,0) end
    if not cleaned then error(reason,0) end
    if not restored then error(restoreFailure,0) end
    if not refreshed then error(refreshFailure,0) end
    if not uiRestored then error(uiFailure,0) end
    return true
end
-- 原有page均支持-middle/-bottom后缀；另有chat-station/chat-mechanic/chat-journal、
-- map-picker/map-region-<真实区ID>、progression-equipment/progression-expensive锚点。
-- 参数直接复用主线程-careerappshot入口，不改Session或main。
---@param session CareerSession
function Checks.Shot(session,page)
    isolated(session)
    local requestedPage=page
    local position="top"
    local base,suffix=page:match("^(.-)%-(middle)$")
    if not base then base,suffix=page:match("^(.-)%-(bottom)$") end
    if base then page,position=base,suffix end
    local allowed={apps=true,messages=true,chat=true,["chat-cousin"]=true,["chat-station"]=true,["chat-mechanic"]=true,["chat-journal"]=true,
        wallet=true,["wallet-income"]=true,["wallet-expense"]=true,["wallet-detail"]=true,
        ["delivery-offer"]=true,["delivery-accepted"]=true,["delivery-picked"]=true,life=true,progression=true,
        ["progression-equipment"]=true,["progression-expensive"]=true,map=true,["map-coast"]=true,["map-picker"]=true}
    local mapRegion=page:match("^map%-region%-(.+)$")
    if mapRegion then
        local World=require("Career.WorldData")
        local regions={World.District(0,0),World.District(World.LIMIT-1,World.LIMIT-1)}
        for _,d in ipairs(World.Districts) do regions[#regions+1]=d end
        for _,d in ipairs(regions) do if d.id==mapRegion then allowed[page]=true end end
    end
    assert(allowed[page],"unknown phone shot "..tostring(requestedPage))
    local requested=false
    for _,arg in ipairs(GetArguments()) do if arg=="-careerappshot="..requestedPage then requested=true end end
    assert(requested,"phone shot requires explicit -careerappshot=<page>")
    local view,actor=session.view,assert(session.actor)
    view:CloseConversation(); view.overlay:SetVisible(false); view:ClosePhone(); view:ShowGame()
    fixture(); session.online=true; actor.speed=0
    local app=page:match("^wallet") and "wallet" or page:match("^delivery") and "delivery"
        or page:match("^chat") and "messages" or page:match("^progression") and "progression"
        or page:match("^map") and "map" or page
    if page=="delivery-accepted" or page=="delivery-picked" then
        local offer=assert(Delivery.GetOffer()); assert(Delivery.Accept(offer.id))
        if page=="delivery-picked" then
            local p=assert(Config.points[offer.pickupId]); assert(Delivery.Pickup(offer.id,p.x,p.z,{riding=false,speed=0}))
        end
    end
    session:Refresh(); session:OpenPhone(app)
    if app=="map" then
        assert(view.worldMap:IsVisible() and view:IsBlocking() and view.phonePage=="",
            "地图实拍必须来自新的全屏地图入口")
        UI.Layout()
        print("[全屏地图实拍就绪] "..requestedPage.." / 正式地图入口；不执行旧手机地图断言")
        view.notice:SetText("")
        return
    end
    layout(view)
    if app=="messages" and page~="messages" then
        local contact=({chat="cousin",["chat-cousin"]="cousin",["chat-station"]="station_master",
            ["chat-mechanic"]="mechanic",["chat-journal"]="journal"})[page]
        tap(view,"career-chat-"..assert(contact))
    elseif page=="wallet-income" then tap(view,"career-wallet-filter-income")
    elseif page=="wallet-expense" then tap(view,"career-wallet-filter-expense")
    elseif page=="wallet-detail" then tap(view,"career-wallet-entry-5")
    elseif page=="map-picker" then tap(view,"career-map-region-toggle")
    elseif mapRegion then
        tap(view,"career-map-region-toggle"); tap(view,"career-map-region-"..mapRegion)
    end
    Checks.Audit(view,"实拍/"..requestedPage)
    view.phoneContent:ScrollToTop(); layout(view)
    local anchor=page=="progression-equipment" and "career-equipment-battery-card"
        or page=="progression-expensive" and "career-motorcycle-rally_3-card"
        or page=="map-coast" and "career-map-coast" or nil
    if anchor then
        assert(view.phoneContent:ShowWidget(anchor),"实拍锚点不在真实分页中 "..anchor)
    elseif position=="middle" then
        view.phoneContent:SetPage(math.max(1,math.ceil(view.phoneContent:GetPageCount()/2)))
    elseif position=="bottom" then view.phoneContent:SetPage(view.phoneContent:GetPageCount()) end
    layout(view)
    if app=="messages" and page~="messages" then visibleTextLayout(view,"career-chat-header-info") end
    if app=="delivery" then visibleTextLayout(view,"career-delivery-online-label") end
    local garage=view.phoneBody:FindById("career-garage-description")
    if garage then
        local emitted=0
        local function report()
            local r=garage:GetAbsoluteLayout()
            local metrics=garage.multilineMetrics_
            local valid=require("Career.PhoneKit").RenderedTextMetrics(garage)
            print(string.format("[手机车库Render诊断] layout=(%.6f,%.6f,%.6f,%.6f) propsH=%s renderH=%s breakW=%s cacheW=%s valid=%s autoHeight=%s align=%s",
                r.x,r.y,r.w,r.h,tostring(garage.props.height),tostring(metrics and metrics.textHeight),
                tostring(metrics and metrics.breakWidth),tostring(garage.lastMultilineWidth_),tostring(valid~=nil),
                tostring(garage.autoHeight_),tostring(garage.props.verticalAlign)))
        end
        report() -- Shot就绪前不保证已Render；明确打印nil，不伪造渲染证据。
        local inherited=garage.Update
        garage.Update=function(self,dt)
            if inherited then inherited(self,dt) end
            if self.multilineMetrics_ and emitted<2 then emitted=emitted+1; report() end
        end
    end
    view.notice:SetText("")
    local state=Store.Get()
    local income,expense=Apps.Today(state)
    print(string.format("[手机应用实拍就绪] %s / 真实余额%.2f / %d笔真实流水 / 今日收入%.2f支出%.2f / completed=%d / story=%s / memory-only / 真组件与触摸可达",
        requestedPage,state.cashCents/100,#state.ledger,income/100,expense/100,state.completedOrders,tostring(state.flags.firstDeliveryStory)))
end
return Checks
