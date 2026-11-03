-- 表哥人物链的生产接线专项；只在已建好的test Session调用，不启动/Ensure第二世界。
-- 真实HUD/对话/确认按钮PointerDown+Up -> Session -> 现有业务事务；不替换生产回调或伪造奖信。
local UI=require("urhox-libs/UI")
local Pointer=require("urhox-libs/UI/Core/PointerEvent")
local Store=require("Career.Store")
local Config=require("Career.Config")
local Delivery=require("Career.Delivery")
local Events=require("Career.Engagements")
local Checks={}
local activeTouches={}
local function find(widget,text)
    if widget.props.text==text and widget.props.onClick then return widget end
    for _,child in ipairs(widget:GetChildren()) do local found=find(child,text);if found then return found end end
end
local function tap(widget)
    UI.Layout()
    assert(widget and widget:IsVisible() and not widget.props.disabled,"人物链按钮必须真实可见")
    local r=widget:GetAbsoluteLayoutForHitTest()
    assert(r.w>0 and r.h>0,"人物链触摸必须使用真实Yoga布局")
    local data={pointerId=791612,pointerType="touch",isPrimary=false,button=Pointer.Button.Left,
        x=(r.x+r.w/2)*UI.GetScale(),y=(r.y+r.h/2)*UI.GetScale()}
    local down,up=Pointer.new("PointerDown",data),Pointer.new("PointerUp",data)
    activeTouches[791612]=data
    UI.HandlePointerEvent(down);UI.HandlePointerEvent(up)
    activeTouches[791612]=nil
    assert(down.target==widget and up.target==widget,"人物链按钮真实命中失败")
end
local function row(id)
    local state=Events.State(Store.Get())
    assert(state.valid,state.error)
    for _,item in ipairs(state.list) do if item.id==id then return item end end
    error("人物链缺少定义："..id)
end
---@param session CareerSession 已ready的显式test=true隔离会话
---@return boolean
function Checks.Run(session)
    assert(session.options.test==true and type(session.restoreTestStorage)=="function",
        "EngagementWorldChecks仅允许已ready的内存隔离Session")
    local actor,city,view=assert(session.actor),assert(session.city),session.view
    assert(session.running and session.space=="city" and UI.GetRoot()==view.root
        and not view:IsBlocking() and not session.customerCall,"需在无触摸/手机/对话的城市游戏态调用")
    assert(not UI.Input.HasActivePointer(),"不得打断真实触摸")
    local old={x=actor.x,z=actor.z,yaw=actor.yaw,speed=actor.speed,mounted=actor.mounted,walkHeight=actor.walkHeight,
        steer=actor.steer,reverseHold=actor.reverseHold,walkDistance=actor.walkDistance,
        bikeX=actor.bikeX,bikeZ=actor.bikeZ,bikeYaw=actor.bikeYaw,trafficActive=session.traffic and session.traffic.active,
        focus=UI.GetFocus(),
        waypoint=session.waypoint,manualWaypoint=session.manualWaypoint,navigation=session.navigation,online=session.online,
        notice=view.notice.props.text,noticeTime=view.noticeTime,speech=view.speechText.props.text,
        speechTime=view.speechTime,speechVisible=view.speech:IsVisible()}
    local people={}
    for _,person in ipairs(city.contacts.people) do
        people[#people+1]={person=person,gesture=person.gesture,gestureTime=person.gestureTime,
            gestureDuration=person.gestureDuration,gestureWeight=person.gestureWeight,poseCount=person.poseCount}
    end
    local files={}
    local writes,reads,cloudCalls=0,0,0
    local function noCloud() cloudCalls=cloudCalls+1;error("人物链接线验收禁止云请求") end
    local restore=Store.UseTestStorage({read=function(path) reads=reads+1;return files[path],nil,files[path]==nil end,
        write=function(path,text) writes=writes+1;files[path]=text;return true end,cloud={Get=noCloud,Set=noCloud}})
    local passed,failure=pcall(function()
        assert(Store.NewCareer())
        session.online=false
        actor.mounted,actor.speed=false,0
        actor.visuals:SetMounted(false)
        -- 明确的测试落点夹具，不声称实走路线；真实Teleport与Surface保证贴地容差。
        -- 不改停车/交通/订单计时；每个真实取送/回访仍由HUD触摸与Session现场授权执行。
        local function atXY(x,z)
            actor:Teleport(x,z,0,city:Surface(x,z))
            actor.walkHeight=city:Surface(actor.x,actor.z)
            actor:SyncVisuals(0)
            session:Refresh();UI.Layout()
        end
        local function at(id)
            local point=assert(Config.points[id])
            atXY(point.x,point.z)
        end
        local function hud() tap(assert(view.root:FindById("career-interact"))) end
        local function dialog(text) tap(assert(find(view.dialogBody,text),"缺少确认："..text)) end
        local function choice() tap(assert(view.conversationBody:FindById("career-conversation-engagement"))) end
        local function talkOverlap(contactId)
            local person=assert(city.contacts:Get(contactId))
            local point=assert(Config.points[person.point])
            atXY(point.x+(person.x-point.x)*.43,point.z+(person.z-point.z)*.43)
            assert(Config.DistanceTo(person.point,actor.x,actor.z)<=Config.INTERACTION_RADIUS)
            assert(session:TalkTo(contactId) and view.conversation:IsVisible())
        end
        local function sendOrder()
            local offer=assert(Delivery.GetOffer())
            assert(Delivery.Accept(offer.id))
            at(offer.pickupId);hud()
            assert(assert(Delivery.GetActive()).status=="picked_up","HUD未调用真实取餐")
            at(offer.dropoffId);hud()
            assert(Store.Get().settledOrders[offer.id] and not Delivery.GetActive(),"HUD未调用真实交付")
            -- 明确拒绝可选广告，既不发小费也不访问SDK；正式交付费早已入账。
            if view.overlay:IsVisible() then dialog("先不领") end
            assert(not view:IsBlocking())
            return offer
        end
        sendOrder() -- 教学成果来自真实Session.Interact，不直接写tutorialCompleted。
        at("bridge");hud();dialog("确认在桥下休息");dialog("出发")
        assert(Store.Get().flags.firstRest,"休息经历必须来自原服务事务")
        talkOverlap("station");choice();dialog("接受现场委托")
        assert(row("breakfast_shift").accepted)
        for _=1,64 do
            sendOrder()
            if row("breakfast_shift").canClaim then break end
        end
        assert(row("breakfast_shift").canClaim,"真实新早餐单应使站长委托可交付")
        at("breakfast");hud()
        assert(row("breakfast_shift").claimed and row("cousin_reply").canAccept)

        -- 联系人3米与事务POI2米是两层授权：表哥身旁可说话，但不等于可远程接任务。
        local cousin=assert(city.contacts:Get("cousin"))
        atXY(cousin.x,cousin.z+1.2)
        assert(Config.DistanceTo("bridge",actor.x,actor.z)>2)
        hud();assert(view.conversation:IsVisible());choice()
        assert(not row("cousin_reply").accepted and not view.overlay:IsVisible(),"POI外不能直接接受回信")
        assert(session.waypoint=="bridge")
        talkOverlap("cousin");choice()
        local before=Store.Get();local beforeWrites=writes
        dialog("稍后再来")
        assert(not row("cousin_reply").accepted and Store.Get().revision==before.revision and writes==beforeWrites)
        talkOverlap("cousin");choice()
        at("park");dialog("接受现场委托")
        assert(not row("cousin_reply").accepted,"确认时离开桥下，必须使用实时ctx拒绝")
        talkOverlap("cousin");choice();dialog("接受现场委托")
        assert(row("cousin_reply").accepted and not row("cousin_reply").canClaim)
        local accepted=Store.Get()
        local cash,day,time,ledger=accepted.cashCents,accepted.day,accepted.time,#accepted.ledger
        -- 尚未访问两处就回桥下：原休息对话而非提前发信，取消不能推进时间。
        at("bridge");hud();dialog("先不休息")
        assert(not row("cousin_reply").claimed and Store.Get().cashCents==cash)
        -- 不依赖nextPoint排序：先便利店再公园，两个HUD都必须访问而非误买饭/休息。
        at("convenience");hud()
        assert(Store.Get().engagements.instances["engagement:v1:cousin_reply"].visits.convenience)
        assert(not row("cousin_reply").canClaim)
        at("park");hud()
        assert(row("cousin_reply").canClaim)
        local visited=Store.Get()
        assert(visited.cashCents==cash and visited.day==day and visited.time==time and #visited.ledger==ledger,
            "回访只能记成果，不能误触用餐/过夜/收支")
        -- 手机的既有claim action也不能远程领奖；真正交付由桥下HUD完成。
        at("park");view.actions.claimEngagement(row("cousin_reply").instanceId)
        assert(not row("cousin_reply").claimed and Store.Get().cashCents==cash)
        at("bridge");before=Store.Get();beforeWrites=writes;hud()
        local finished=Store.Get()
        assert(row("cousin_reply").claimed and finished.cashCents==cash+800
            and finished.revision==before.revision+1 and writes==beforeWrites+1
            and #finished.ledger==ledger+1 and Events.State(finished).completedCount==2
            and #Events.State(finished).letters==2,"桥下HUD交付须原子入账800分及一封回信")
        local entry=finished.ledger[#finished.ledger]
        assert(entry.id=="engagement:v1:cousin_reply:reward" and entry.kind=="engagement" and entry.deltaCents==800)
        assert(finished.day==day and finished.time==time,"交付回信不能偷偷过夜")
        beforeWrites=writes
        view.actions.claimEngagement(row("cousin_reply").instanceId)
        assert(Store.Get().revision==finished.revision and writes==beforeWrites,"重复Session交付不能重发奖金/信件")
        assert(actor.bikeX==old.bikeX and actor.bikeZ==old.bikeZ and actor.bikeYaw==old.bikeYaw
            and (not session.traffic or session.traffic.active==old.trafficActive) and not session.customerCall,
            "现场夹具不得挪停车、改交通开关或创建电话")
        assert(reads==0 and cloudCalls==0,"专项不读取任何存档或请求云")
        print("[EngagementWorldChecks] PASS 真实HUD取送/站长三新单/表哥3米交谈与2米授权/触摸取消和确认时重检/便利店+公园HUD零消费回访/桥下HUD800分一次奖信/重复拒奖/内存禁云")
    end)
    local cleaned,cleanupFailure=pcall(function()
        for id,data in pairs(activeTouches) do
            UI.HandlePointerEvent(Pointer.new("PointerCancel",data));activeTouches[id]=nil
        end
        view:ResetInput();view:CloseConversation();view:ClosePhone();view:ShowGame()
        actor.mounted=false
        actor:Teleport(old.x,old.z,old.yaw,old.walkHeight)
        actor.x,actor.z,actor.yaw,actor.speed,actor.mounted,actor.walkHeight=old.x,old.z,old.yaw,old.speed,old.mounted,old.walkHeight
        actor.steer,actor.reverseHold,actor.walkDistance=old.steer,old.reverseHold,old.walkDistance
        actor.visuals:SetMounted(old.mounted);actor:SyncVisuals(0)
        session.waypoint,session.manualWaypoint,session.navigation,session.online=old.waypoint,old.manualWaypoint,old.navigation,old.online
        for _,item in ipairs(people) do
            local person=item.person --[[@as CareerStreetPerson]]
            person.gesture,person.gestureTime,person.gestureDuration,person.gestureWeight=item.gesture,item.gestureTime,item.gestureDuration,item.gestureWeight
            city.contacts.life:Pose(person);person.poseCount=item.poseCount
        end
    end)
    restore()
    local refreshed,refreshFailure=pcall(function()
        session:Refresh()
        view.notice:SetText(old.notice or "");view.noticeTime=old.noticeTime
        view.speechText:SetText(old.speech or "");view.speechTime=old.speechTime;view.speech:SetVisible(old.speechVisible)
        UI.Layout();UI.SetFocus(old.focus)
    end)
    if not passed then error(failure,0) end
    if not cleaned then error(cleanupFailure,0) end
    if not refreshed then error(refreshFailure,0) end
    return true
end
return Checks
