-- Opt-in production UI regression. Run ONLY against an already-ready test Session.
-- Nested in-memory Store + rejecting cloud adapter, restored in finally. No world
-- creation, Teleport/Ensure, runtime runner, synthetic wallet or replacement settlement.
local UI=require("urhox-libs/UI")
local PointerEvent=require("urhox-libs/UI/Core/PointerEvent")
local Store=require("Career.Store")
local Config=require("Career.Config")
local Delivery=require("Career.Delivery")
local Checks={}

---@param widget Widget
---@return Widget[]
local function tree(widget)
    local result={widget}
    for _,child in ipairs(widget:GetChildren()) do
        for _,item in ipairs(tree(child)) do result[#result+1]=item end
    end
    return result
end
---@param parent Widget
---@return Widget[]
local function descendants(parent)
    local result={}
    for _,child in ipairs(parent:GetChildren()) do
        for _,item in ipairs(tree(child)) do result[#result+1]=item end
    end
    return result
end
---@param widgets Widget[]
local function freed(widgets)
    for _,widget in ipairs(widgets) do
        assert(widget.node==nil and widget.parent==nil and widget:GetNumChildren()==0,
            "StreetInteractionChecks: stale tree not Destroyed: "..tostring(widget.props.id))
    end
end
---@param parent Widget
---@param text string
---@return Widget?
local function findText(parent,text)
    for _,widget in ipairs(tree(parent)) do
        if widget.props.text==text and widget.props.onClick then return widget end
    end
    return nil
end
---@param widget Widget
local function tapWidget(widget)
    UI.Layout()
    assert(widget.node~=nil and widget:IsVisible() and not widget.props.disabled,"button is not live/visible")
    local r=widget:GetAbsoluteLayoutForHitTest()
    assert(r.w>0 and r.h>0,"pointer test requires actual Yoga layout")
    local scale=UI.GetScale()
    local data={pointerId=791311,pointerType="touch",isPrimary=false,
        x=(r.x+r.w/2)*scale,y=(r.y+r.h/2)*scale,button=PointerEvent.Button.Left}
    local down=PointerEvent.new("PointerDown",data)
    UI.HandlePointerEvent(down)
    assert(down.target==widget,"PointerDown missed intended production button")
    local up=PointerEvent.new("PointerUp",data)
    UI.HandlePointerEvent(up)
    assert(up.target==widget,"PointerUp missed intended production button")
end
---@param view CareerView
---@param id string
local function tap(view,id)
    tapWidget(assert(view.root:FindById(id),"missing production button "..id))
end
---@param view CareerView
---@param text string
local function tapDialog(view,text)
    tapWidget(assert(findText(view.dialogBody,text),"missing modal button "..text))
end
---@param view CareerView
local function idle(view)
    assert(not view.blocked and not view:IsBlocking() and view.phonePage==""
        and not view.phone:IsVisible() and not view.conversation:IsVisible() and not view.overlay:IsVisible(),
        "closing an interaction must restore unblocked game input")
end
---@param before CareerProfile
---@param writes number
---@param currentWrites number
local function unchanged(before,writes,currentWrites)
    local after=Store.Get()
    assert(after.revision==before.revision and after.cashCents==before.cashCents
        and #after.ledger==#before.ledger and after.time==before.time and after.day==before.day
        and after.completedOrders==before.completedOrders and #after.activeOrders==#before.activeOrders
        and currentWrites==writes,"UI-only/rejected action performed an unauthorized transaction")
end

---@param session CareerSession
---@return boolean
function Checks.Run(session)
    assert(session.options and session.options.test==true and type(session.restoreTestStorage)=="function",
        "StreetInteractionChecks requires explicit test=true isolated Session")
    local actor=assert(session.actor,"actor must already be ready")
    local city=assert(session.city,"city must already be ready")
    local view=session.view
    assert(session.running and UI.GetRoot()==view.root,"ready production game UI must be mounted")
    idle(view)
    local station=assert(city.contacts:Get("station"),"station contact missing")
    local owner=assert(city.contacts:Get("breakfast_owner"),"breakfast owner missing")
    local cousin=assert(city.contacts:Get("cousin"),"bridge contact missing")
    local old={x=actor.x,z=actor.z,yaw=actor.yaw,speed=actor.speed,walkHeight=actor.walkHeight,
        mounted=actor.mounted,space=session.space,online=session.online,running=session.running,
        waypoint=session.waypoint,manualWaypoint=session.manualWaypoint,navigation=session.navigation,
        lastActor=view.lastActor,lastTarget=view.lastTarget,notice=view.notice.props.text,noticeTime=view.noticeTime,
        speech=view.speechText.props.text,speechTime=view.speechTime,speechVisible=view.speech:IsVisible(),
        mapDistrictId=view.mapDistrictId,mapPointPage=view.mapPointPage,mapPickerOpen=view.mapPickerOpen}
    -- Respond() legitimately updates the existing actors; restore their pose metadata too.
    local people={}
    for _,person in ipairs(city.contacts.people) do
        people[#people+1]={person=person,gesture=person.gesture,gestureTime=person.gestureTime,
            gestureDuration=person.gestureDuration,gestureWeight=person.gestureWeight,poseCount=person.poseCount}
    end
    ---@type table<string,string>
    local files={}
    local writes,cloudCalls,reads=0,0,0
    local restore=Store.UseTestStorage({
        read=function(path) reads=reads+1; return files[path],nil,files[path]==nil end,
        write=function(path,text) writes=writes+1; files[path]=text; return true end,
        cloud={Get=function() cloudCalls=cloudCalls+1; error("StreetInteractionChecks forbids cloud reads") end,
            Set=function() cloudCalls=cloudCalls+1; error("StreetInteractionChecks forbids cloud writes") end},
    })
    local passed,failure=pcall(function()
        assert(Store.NewCareer())
        session.space,session.online,session.running="city",false,true
        actor.mounted,actor.speed,actor.walkHeight=false,0,0
        -- Change isolated logical coordinates only. Neither engine nodes nor the real
        -- parked vehicle are moved; no streaming, saved profile load or collision edit.
        ---@param x number
        ---@param z number
        local function at(x,z)
            actor.x,actor.z,actor.speed,actor.walkHeight,actor.mounted=x,z,0,0,false
            session:Refresh()
        end
        ---@param person CareerStreetPerson
        local function near(person)
            at(person.x,person.z+1.2)
        end
        ---@param id string
        local function talk(id)
            assert(session:TalkTo(id),"production TalkTo rejected valid contact "..id)
            assert(view.blocked and view:IsBlocking() and view.conversation:IsVisible()
                and not view.phone:IsVisible() and not view.overlay:IsVisible() and view.phonePage=="",
                "conversation must be the exclusive blocking layer")
        end
        local baseline=#tree(view.root)
        local before=Store.Get()
        local startWrites=writes
        near(station)
        local stationPoses=station.poseCount
        talk("station")
        assert(station.poseCount>stationPoses,"TalkTo must trigger the real contact response")
        assert(assert(view.conversationBody:FindById("career-conversation-name")).props.text:find(station.name,1,true))
        assert(assert(view.conversationBody:FindById("career-conversation-line")).props.text~="")
        local stale=descendants(view.conversationBody)
        tap(view,"career-conversation-leave")
        freed(stale); idle(view); unchanged(before,startWrites,writes)
        -- Repeated open/leave must not accumulate Yoga nodes or debit meals implicitly.
        for _=1,3 do
            talk("station"); stale=descendants(view.conversationBody)
            tap(view,"career-conversation-leave"); freed(stale); idle(view)
            assert(#tree(view.root)==baseline,"conversation nodes grow across repeated leave")
        end
        unchanged(before,startWrites,writes)

        -- Orders opens the real delivery app; it does not auto-accept or charge.
        near(owner); talk("breakfast_owner")
        stale=descendants(view.conversationBody)
        tap(view,"career-conversation-orders")
        freed(stale)
        assert(view.phonePage=="delivery" and view.phone:IsVisible() and view:IsBlocking()
            and not view.blocked and not view.conversation:IsVisible() and not view.overlay:IsVisible())
        assert(Delivery.GetActive()==nil,"opening orders must not accept an order")
        local phoneTree=descendants(view.phoneContent)
        view:ClosePhone(); freed(phoneTree); idle(view)
        unchanged(before,startWrites,writes)

        -- Guards are exercised at actual production TalkTo, not copied test logic.
        at(station.x+3.01,station.z)
        assert(not session:TalkTo("station"),"contact beyond 3m must be rejected")
        assert(view.notice.props.text:find("靠近",1,true)); idle(view)
        near(station); actor.mounted=true
        assert(not session:TalkTo("station"),"mounted contact interaction must be rejected")
        actor.mounted=false; actor.speed=.36
        assert(not session:TalkTo("station"),"moving contact interaction must be rejected")
        actor.speed=0; actor.walkHeight=6
        assert(not session:TalkTo("station"),"bridge deck must not talk through to ground")
        actor.walkHeight=0
        near(cousin); actor.walkHeight=6
        assert(not session:TalkTo("cousin"),"underpass cousin must reject player overhead")
        actor.walkHeight=0
        unchanged(before,startWrites,writes); idle(view)

        -- Opening a valid conversation does not freeze authorization at old coordinates.
        near(owner); talk("breakfast_owner")
        stale=descendants(view.conversationBody)
        at(owner.x+12,owner.z+12)
        tap(view,"career-conversation-meal")
        freed(stale); idle(view); unchanged(before,startWrites,writes)
        assert(view.notice.props.text:find("靠近",1,true),"choice callback must recheck contact range")

        -- Contact is at (-22,-11.1), service is still original breakfast POI (-25,-8).
        -- A contact-near but POI-far position MUST NOT silently buy a meal.
        near(owner)
        assert(Config.DistanceTo("breakfast",actor.x,actor.z)>Config.INTERACTION_RADIUS)
        talk("breakfast_owner"); tap(view,"career-conversation-meal")
        idle(view); unchanged(before,startWrites,writes)
        assert(session.waypoint=="breakfast" and view.notice.props.text:find("2米",1,true),
            "meal authorization must still use original 2m breakfast POI")
        -- Pick a point inside BOTH independent circles without moving either source.
        local p=Config.points.breakfast
        at(p.x+.43*(owner.x-p.x),p.z+.43*(owner.z-p.z))
        assert(Config.DistanceTo("breakfast",actor.x,actor.z)<=Config.INTERACTION_RADIUS)
        assert((actor.x-owner.x)^2+(actor.z-owner.z)^2<=3^2,
            "meal fixture must remain inside both original POI and contact authorization circles")
        talk("breakfast_owner")
        local mealBefore=Store.Get()
        local mealWrites=writes
        stale=descendants(view.conversationBody)
        tap(view,"career-conversation-meal")
        freed(stale); idle(view)
        local mealAfter=Store.Get()
        assert(mealAfter.cashCents==mealBefore.cashCents-Config.MEAL_CENTS
            and mealAfter.revision==mealBefore.revision+1 and #mealAfter.ledger==#mealBefore.ledger+1
            and writes==mealWrites+1,"one real meal click must commit exactly one Store.Eat transaction")
        assert(mealAfter.ledger[#mealAfter.ledger].kind=="meal" and mealAfter.flags.firstMeal
            and math.abs(mealAfter.time-mealBefore.time-.25)<.000001)

        -- Actual pointer on HUD -> Session.Interact -> Delivery.Pickup -> merchant
        -- DeliveryResponse; no direct invocation of the visual response or fake payout.
        local orderBefore=Store.Get()
        assert(Delivery.Accept())
        local order=assert(Delivery.GetActive())
        assert(order.pickupId=="breakfast" and order.status=="accepted")
        at(p.x,p.z)
        local pickupBefore=Store.Get()
        local pickupWrites=writes
        local ownerPoses=owner.poseCount
        tap(view,"career-interact")
        local picked=assert(Delivery.GetActive())
        assert(picked.id==order.id and picked.status=="picked_up","HUD must execute real breakfast Pickup")
        assert(view.speech:IsVisible() and view.speechTime>0 and view.speechText.props.text:find("早餐店老板",1,true)
            and view.speechText.props.text:find("单号对上了",1,true),"successful breakfast pickup must respond in-world")
        assert(owner.poseCount>ownerPoses,"successful handover must trigger the real owner's response pose")
        local pickupAfter=Store.Get()
        assert(pickupAfter.revision==pickupBefore.revision+1 and writes==pickupWrites+1
            and pickupAfter.cashCents==pickupBefore.cashCents and #pickupAfter.ledger==#pickupBefore.ledger
            and pickupAfter.completedOrders==orderBefore.completedOrders,"pickup cannot pay delivery rewards")
        local responseText=view.speechText.props.text
        local responsePoses=owner.poseCount
        tap(view,"career-interact") -- Still at merchant: active order now needs its DROP-OFF.
        unchanged(pickupAfter,pickupWrites+1,writes)
        assert(assert(Delivery.GetActive()).status=="picked_up" and owner.poseCount==responsePoses
            and view.speechText.props.text==responseText,"duplicate pickup must neither repeat handover nor reward")
        assert(not Delivery.Pickup(order.id,p.x,p.z,{riding=false,speed=0}),"production Pickup must reject same order twice")
        unchanged(pickupAfter,pickupWrites+1,writes)
        -- Verify reward only on actual drop-off, once, through the same production HUD.
        local destination=assert(Config.points[order.dropoffId])
        at(destination.x,destination.z)
        local deliveredBefore=Store.Get()
        local deliveredWrites=writes
        tap(view,"career-interact")
        local delivered=Store.Get()
        assert(Delivery.GetActive()==nil and delivered.settledOrders[order.id]
            and delivered.cashCents==deliveredBefore.cashCents+order.feeCents
            and delivered.completedOrders==deliveredBefore.completedOrders+1
            and delivered.revision==deliveredBefore.revision+1 and writes==deliveredWrites+1)
        assert(not Delivery.Deliver(order.id,destination.x,destination.z,{riding=false,speed=0}))
        unchanged(delivered,deliveredWrites+1,writes)

        -- Both directions conversation <-> phone release obsolete trees and blocking.
        near(owner); talk("breakfast_owner")
        stale=descendants(view.conversationBody)
        session:OpenPhone("apps")
        freed(stale)
        assert(view.phone:IsVisible() and not view.conversation:IsVisible() and not view.overlay:IsVisible()
            and not view.blocked and view:IsBlocking())
        phoneTree=descendants(view.phoneContent)
        talk("breakfast_owner"); freed(phoneTree)
        stale=descendants(view.conversationBody)
        view:ShowDialog("隔离回归确认","仅检查生产弹窗生命周期，不执行事务。",{{text="继续街头回归"}})
        freed(stale)
        assert(view.overlay:IsVisible() and view.blocked and not view.conversation:IsVisible() and not view.phone:IsVisible())
        tapDialog(view,"继续街头回归"); idle(view)
        -- Phone confirmation intentionally RETAINS its page for cancel/return, but
        -- only the modal may be visible and interactive until it is dismissed.
        session:OpenPhone("apps"); phoneTree=descendants(view.phoneContent)
        view:ShowDialog("隔离回归确认","手机转弹窗必须隐藏手机且保留返回页。",{{text="继续街头回归"}})
        assert(not view.phone:IsVisible() and view.overlay:IsVisible() and view.blocked)
        for _,widget in ipairs(phoneTree) do assert(widget.node~=nil,"confirmation must preserve return page") end
        tapDialog(view,"继续街头回归")
        assert(view.phone:IsVisible() and view.phonePage=="apps" and not view.overlay:IsVisible()
            and not view.blocked and view:IsBlocking(),"modal dismissal must restore the retained phone page")
        view:ClosePhone(); freed(phoneTree); idle(view)
        view:ShowDialog("隔离回归确认","弹窗转手机不得留下覆盖层。",{{text="继续街头回归"}})
        session:OpenPhone("apps")
        assert(view.phone:IsVisible() and view.phonePage=="apps" and not view.overlay:IsVisible()
            and not view.conversation:IsVisible() and not view.blocked and view:IsBlocking())
        view:ClosePhone(); idle(view)
        unchanged(delivered,deliveredWrites+1,writes)
        assert(#tree(view.root)<=baseline+6,"UI descendants leaked across conversation/phone/modal switches")
        assert(cloudCalls==0 and reads==0,"test must not read a save or touch cloud")
        print("[街头交互验收通过] 真PointerDown/Up；交谈/离开/订单零收费；远距骑行桥上拒绝；按钮二次校验；原POI用餐单事务；真实早餐交接/重复拒奖/配送一次到账；旧树Destroy与手机弹窗互斥；内存禁云")
    end)
    local cleaned,cleanupFailure=pcall(function()
        view:CloseConversation(); view:ClosePhone(); view:ShowGame()
        actor.x,actor.z,actor.yaw,actor.speed,actor.walkHeight,actor.mounted=old.x,old.z,old.yaw,old.speed,old.walkHeight,old.mounted
        session.space,session.online,session.running=old.space,old.online,old.running
        session.waypoint,session.manualWaypoint,session.navigation=old.waypoint,old.manualWaypoint,old.navigation
        for _,item in ipairs(people) do
            local person=item.person --[[@as CareerStreetPerson]]
            person.gesture,person.gestureTime,person.gestureDuration=item.gesture,item.gestureTime,item.gestureDuration
            person.gestureWeight=item.gestureWeight
            city.contacts.life:Pose(person)
            person.poseCount=item.poseCount
        end
    end)
    restore() -- ALWAYS restore outer Store even when assertions or UI cleanup fail.
    local refreshed,refreshFailure=pcall(function()
        session:Refresh()
        view.lastActor,view.lastTarget=old.lastActor,old.lastTarget
        view.notice:SetText(old.notice or ""); view.noticeTime=old.noticeTime
        view.speechText:SetText(old.speech or ""); view.speechTime=old.speechTime; view.speech:SetVisible(old.speechVisible)
        view.mapDistrictId,view.mapPointPage,view.mapPickerOpen=old.mapDistrictId,old.mapPointPage,old.mapPickerOpen
    end)
    if not passed then error(failure,0) end
    if not cleaned then error(cleanupFailure,0) end
    if not refreshed then error(refreshFailure,0) end
    return true
end
return Checks
