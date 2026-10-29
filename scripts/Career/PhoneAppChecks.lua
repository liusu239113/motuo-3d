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
    UI.Layout(); view.phoneArea:Update(0); UI.Layout(); view.phoneContent:Update(0); UI.Layout()
end
---@param view CareerView
---@return Widget
local function find(view,id) return assert(view.phoneBody:FindById(id),"缺少真实手机组件 "..id) end
---@param view CareerView
local function tap(view,id)
    layout(view)
    local widget=find(view,id)
    local r=widget:GetAbsoluteLayoutForHitTest()
    assert(r.w>=44 and r.h>=44,"触摸目标小于44px "..id)
    local fixed=id=="career-phone-back" or id=="career-phone-close"
    if not fixed and view.phonePage~="apps" then
        local area=view.phoneContent:GetAbsoluteLayoutForHitTest()
        local _,scroll=view.phoneContent:GetScroll()
        view.phoneContent:SetScroll(0,math.max(0,scroll+r.y+r.h/2-area.y-area.h/2))
        r=widget:GetAbsoluteLayoutForHitTest()
        assert(r.y+r.h/2>area.y and r.y+r.h/2<area.y+area.h,"触摸目标被裁剪 "..id)
    end
    local scale=UI.GetScale()
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
        local before=Store.Get()
        tap(view,"career-engagement-breakfast_shift")
        assert(Store.Get().revision==before.revision and not Store.Get().engagements,"远处手机接取仍须现场再次授权")
        view:ClosePhone(); session:OpenPhone("delivery")
        tap(view,"career-online")
        assert(session.online and find(view,"career-delivery-offer"))
        tap(view,"career-accept")
        local active=assert(Delivery.GetActive())
        assert(find(view,"career-delivery-active") and active.status=="accepted")
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
-- page: apps/messages/chat/wallet/wallet-income/wallet-expense/wallet-detail/
-- delivery-offer/delivery-accepted/delivery-picked/life/progression；只用于主线程显式实拍入口。
---@param session CareerSession
function Checks.Shot(session,page)
    isolated(session)
    local allowed={apps=true,messages=true,chat=true,wallet=true,["wallet-income"]=true,["wallet-expense"]=true,
        ["wallet-detail"]=true,["delivery-offer"]=true,["delivery-accepted"]=true,["delivery-picked"]=true,life=true,progression=true}
    assert(allowed[page],"unknown phone shot "..tostring(page))
    local requested=false
    for _,arg in ipairs(GetArguments()) do if arg=="-careerappshot="..page then requested=true end end
    assert(requested,"phone shot requires explicit -careerappshot=<page>")
    local view,actor=session.view,assert(session.actor)
    view:CloseConversation(); view.overlay:SetVisible(false); view:ClosePhone(); view:ShowGame()
    fixture(); session.online=true; actor.speed=0
    local app=page:match("^wallet") and "wallet" or page:match("^delivery") and "delivery" or page=="chat" and "messages" or page
    if page=="delivery-accepted" or page=="delivery-picked" then
        local offer=assert(Delivery.GetOffer()); assert(Delivery.Accept(offer.id))
        if page=="delivery-picked" then
            local p=assert(Config.points[offer.pickupId]); assert(Delivery.Pickup(offer.id,p.x,p.z,{riding=false,speed=0}))
        end
    end
    session:Refresh(); session:OpenPhone(app); layout(view)
    if page=="chat" then tap(view,"career-chat-cousin")
    elseif page=="wallet-income" then tap(view,"career-wallet-filter-income")
    elseif page=="wallet-expense" then tap(view,"career-wallet-filter-expense")
    elseif page=="wallet-detail" then tap(view,"career-wallet-entry-5") end
    view.phoneContent:ScrollToTop(); layout(view)
    view.notice:SetText("")
    local state=Store.Get()
    local income,expense=Apps.Today(state)
    print(string.format("[手机应用实拍就绪] %s / 真实余额%.2f / %d笔真实流水 / 今日收入%.2f支出%.2f / completed=%d / story=%s / memory-only / 真组件与触摸可达",
        page,state.cashCents/100,#state.ledger,income/100,expense/100,state.completedOrders,tostring(state.flags.firstDeliveryStory)))
end
return Checks
