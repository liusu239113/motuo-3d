-- Opt-in production regression; no build/runtime, save load, cloud or second City.
-- Run requires an already-ready test Session. All fixture transactions are nested
-- memory-only; the real Session.Interact and Delivery settlement remain unmodified.
local UI=require("urhox-libs/UI")
local Store=require("Career.Store")
local Config=require("Career.Config")
local Delivery=require("Career.Delivery")
local People=require("Career.DeliveryPeople")
local Vehicles=require("Career.VehicleData")
local function same(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~="table" then return a==b end
    for key,value in pairs(a) do if not same(value,b[key]) then return false end end
    for key in pairs(b) do if a[key]==nil then return false end end
    return true
end
---@class CareerDeliveryPeopleChecks
---@field Run fun(session:CareerSession):boolean
---@field Shot fun(session:CareerSession,view:string)
local Checks={}
local V=Vector3

local function near(a,b,tolerance,message)
    assert(math.abs(a-b)<tolerance,message or string.format("%.8f ~= %.8f",a,b))
end
local function copy(value)
    if type(value)~="table" then return value end
    local result={}
    for key,item in pairs(value) do result[key]=copy(item) end
    return result
end
---@param templateId string
---@param sequence integer
---@param status string
---@return CareerOrder
local function order(templateId,sequence,status)
    local template=assert(Config.GetTemplate(templateId),"missing production order template "..templateId)
    local distance=Config.RouteDistance(template.route)
    return {id="career-v1-"..sequence,sequence=sequence,templateId=template.id,title=template.title,
        pickupId=template.pickupId,dropoffId=template.dropoffId,route=copy(template.route),distanceMeters=distance,
        feeCents=template.tutorial and 500 or Config.FeeCents(distance),tutorial=template.tutorial,
        status=status,acceptedDay=1,acceptedTime=8,remainingHours=template.timeLimitHours,late=false}
end
---@param orders CareerOrder[]
local function installOrders(orders)
    -- Authorized fixture only: never seed cash, ledgers, settlement keys or rewards.
    assert(Store.Transaction(function(p)
        p.equipment=p.equipment or {}; p.equipment.large_box=true
        p.activeOrders=copy(orders); p.phase="working"
        for _,item in ipairs(orders) do p.nextOrderSequence=math.max(p.nextOrderSequence,item.sequence+1) end
        return true
    end))
end
---@param pool CareerDeliveryPeople
---@param orders CareerOrder[]
---@param actor? table
local function sync(pool,orders,actor)
    ---@type CareerDeliveryPeopleOrder[]
    local snapshot={}
    for _,item in ipairs(orders) do
        snapshot[#snapshot+1]={id=item.id,status=item.status,pickupId=item.pickupId,dropoffId=item.dropoffId,route=item.route}
    end
    pool:Sync(snapshot,actor)
end
---@param p CareerDeliveryPerson
local function pose(p,city)
    local rig=p.rig --[[@as CareerRig]]
    assert(rig and rig.model:GetModel() and rig.model:GetSkeleton():GetNumBones()>0,"pool must own actual Rig bones")
    assert(#rig.soleVertices.L_Foot>0 and #rig.soleVertices.R_Foot>0,"missing actual skinned sole vertices")
    near(p.node.position.y,city:WalkSurface(p.x,p.z,p.node.position.y),.006,"NPC root not on production walk surface")
    for _,chain in ipairs(rig.legs) do
        local foot=p.node.worldTransform*rig:GetBonePosition(chain.tip)
        local ground=city:WalkSurface(foot.x,foot.z,p.node.position.y)
        near(rig:SoleHeight(chain.tip)+p.node.position.y,ground,.006,"NPC actual sole floats or penetrates ground")
    end
    for _,group in ipairs({rig.arms,rig.legs}) do
        for _,chain in ipairs(group) do
            local a,b,c=rig:GetBonePosition(chain.upper),rig:GetBonePosition(chain.lower),rig:GetBonePosition(chain.tip)
            near((b-a):Length(),chain.lengthA,.00002,"delivery gesture stretched upper limb")
            near((c-b):Length(),chain.lengthB,.00002,"delivery gesture stretched lower limb")
            if group==rig.arms then
                local direction=(c-a):Normalized()
                local bend=b-a-direction*(b-a):DotProduct(direction)
                local hint=V(chain.side*.12,-.1,-1)
                assert(bend:DotProduct(hint-direction*hint:DotProduct(direction))>0,"delivery gesture flipped elbow")
            end
        end
    end
    for _,name in ipairs(rig.boneNames) do
        local bone=rig.model:GetSkeleton():GetBone(name)
        near((bone.node.position-rig.bind[name].position):Length(),0,.000001,"delivery gesture translated bind bone")
        near((bone.node.scale-rig.bind[name].scale):Length(),0,.000001,"delivery gesture scaled bind bone")
    end
end
local function frozen(p)
    return {clock=p.clock,yaw=p.yaw,gestureTime=p.gestureTime,gestureWeight=p.gestureWeight,
        poseCount=p.poseCount,hold=p.hold,hand=p.rig:GetBonePosition("R_Hand")}
end
local function samePose(p,before,message)
    assert(p.clock==before.clock and p.yaw==before.yaw and p.gestureTime==before.gestureTime
        and p.gestureWeight==before.gestureWeight and p.poseCount==before.poseCount and p.hold==before.hold,message)
    near((p.rig:GetBonePosition("R_Hand")-before.hand):Length(),0,.000001,message)
end
local function nearActor(p)
    return {x=p.x+1.5,z=p.z,mounted=false,walkHeight=p.node.position.y}
end

-- Collision design (metres, top view):
-- incoming route -- [2m approach segment, walking r=.32] -- marker centre
--                                  NPC disk r=.4 to the SIDE, not in the lane
-- Check real static surroundings, exact marker, and each production last/first
-- route segment at .05m spacing, including both endpoints. Do NOT incorrectly
-- demand the entire 2m interaction disk be empty: the NPC intentionally stands
-- inside its edge. Boundary probes cover the actual dynamic disk separately.
---@param p CareerDeliveryPerson
---@param city CareerCity
local function trafficBlocker(p,city)
    local traffic=assert(city.traffic,"production traffic must already be ready")
    local found=false
    for _,blocker in ipairs(traffic:Blockers()) do
        if math.abs(blocker.x-p.x)<.000001 and math.abs(blocker.z-p.z)<.000001
            and math.abs(blocker.radius-p.radius)<.000001 then found=true; break end
    end
    assert(found,"production Traffic.Blockers omitted active/held delivery entity: "..p.pointId)
    local height=p.y+6
    assert(city.deliveryPeople:IsFree(p.x,p.z,.32,"walk",height),"ground delivery entity blocks another height layer")
    -- 高层可能没有桥面，本来就被World拒绝；比较同一真实City带池/不带池，不能把无桥空中当可走区域。
    local expected=city:StaticFree(p.x,p.z,.32,"walk",height)
    assert(city:IsFree(p.x,p.z,.32,"walk",height)==expected,
        "City.IsFree delivery entity changes another height layer")
end
local function safe(p,city,pool,orders)
    trafficBlocker(p,city)
    local height=p.node.position.y
    assert(city:StaticFree(p.x,p.z,p.radius or .4,"walk",height),"NPC stood inside real static obstacle")
    assert(not pool:IsFree(p.x,p.z,.32),"active delivery NPC has no dynamic blocker")
    assert(not city:IsFree(p.x,p.z,.32,"walk",height),"City.IsFree does not consult City.deliveryPeople")
    assert(pool:IsFree(p.x,p.z,.32)==false,"pool centre must remain blocked independent of visual LOD")
    local radius=p.radius or .4
    assert(not pool:IsFree(p.x+radius+.32-.001,p.z,.32,"walk",height),"dynamic disk inside edge is not blocked")
    -- Other occupants may legitimately block an outside probe; test the centre's
    -- own geometric boundary only when no other active/held NPC overlaps it.
    local outside=p.x+radius+.32+.01
    local another=false
    for _,other in ipairs(pool.people) do
        if other~=p and (other.active or (other.hold or 0)>0)
            and (outside-other.x)^2+(p.z-other.z)^2<((other.radius or .4)+.32)^2 then another=true end
    end
    if not another then assert(pool:IsFree(outside,p.z,.32,"walk",height),"dynamic disk expands past actual radius") end
    for _,item in ipairs(orders) do
        local pickup=item.status=="accepted"
        if (pickup and item.pickupId or item.dropoffId)==p.pointId then
            local marker=assert(Config.points[p.pointId])
            local adjacent=pickup and item.route[2] or item.route[#item.route-1]
            local dx,dz=adjacent.x-marker.x,adjacent.z-marker.z
            local length=math.sqrt(dx*dx+dz*dz)
            assert(length>0,"production approach route has zero-length endpoint")
            for step=0,40 do
                local d=math.min(2,length)*step/40
                local x,z=marker.x+dx/length*d,marker.z+dz/length*d
                assert(pool:IsFree(x,z,.32,"walk",city:WalkSurface(x,z,height)),
                    string.format("NPC obstructs 2m marker approach %s at (%.3f,%.3f)",p.pointId,x,z))
            end
        end
    end
end

---@param widget Widget
---@return Widget[]
local function buttons(widget)
    local result={}
    for _,child in ipairs(widget:GetChildren()) do
        if child.props.onClick then result[#result+1]=child end
        for _,button in ipairs(buttons(child)) do result[#result+1]=button end
    end
    return result
end
---@param session CareerSession
local function conversationLayout(session)
    local city,actor=assert(session.city),assert(session.actor)
    local owner=assert(city.contacts:Get("breakfast_owner"))
    actor.x,actor.z=owner.x,owner.z+1.1
    assert(session:TalkTo("breakfast_owner"),"real contact conversation fixture rejected")
    UI.Layout()
    local body=session.view.conversationBody:GetAbsoluteLayout()
    local choices=buttons(session.view.conversationBody)
    assert(#choices>=3,"real breakfast conversation choices missing")
    ---@type {x:number,y:number,w:number,h:number}[]
    local rects={}
    for _,button in ipairs(choices) do
        local r=button:GetAbsoluteLayoutForHitTest() --[[@as {x:number,y:number,w:number,h:number}]]
        assert(button:IsVisible() and r.w>0 and r.h>=43.9,"conversation touch target must be at least 44 logical pixels")
        assert(r.x>=body.x-.5 and r.y>=body.y-.5 and r.x+r.w<=body.x+body.w+.5
            and r.y+r.h<=body.y+body.h+.5,"conversation button escapes its safe panel")
        rects[#rects+1]={x=r.x,y=r.y,w=r.w,h=r.h}
    end
    local columns=false
    for i=1,#rects do
        for j=i+1,#rects do
            local a,b=rects[i],rects[j]
            assert(not(a.x<b.x+b.w-.1 and b.x<a.x+a.w-.1 and a.y<b.y+b.h-.1 and b.y<a.y+a.h-.1),
                "conversation choices overlap")
            if math.abs(a.y-b.y)<1 and math.abs(a.x-b.x)>1 then columns=true end
        end
    end
    assert(columns,"production conversation choices did not wrap into two columns")
    session.view:CloseConversation()
end

---@param session CareerSession
---@return boolean
function Checks.Run(session)
    assert(session.options and session.options.test==true and type(session.restoreTestStorage)=="function",
        "DeliveryPeopleChecks requires an explicit test=true isolated Session")
    local city,actor,scene=assert(session.city),assert(session.actor),assert(session.scene)
    local view=session.view
    assert(session.running and city.space=="city" and session.space=="city" and UI.GetRoot()==view.root,
        "requires ready outdoor production Session/UI")
    assert(not view:IsBlocking() and view.phonePage=="","close phone/conversation/modal before Run")
    assert(session.deliveryPeople and city.deliveryPeople==session.deliveryPeople,"production pool not connected to Session/City")
    -- Normalize only the already-ready OUTER test profile before measuring scene
    -- nodes, so a stale lazily-created production target cannot look like a leak.
    session:Refresh()
    local old={pool=session.deliveryPeople,cityPool=city.deliveryPeople,citySpace=city.space,
        x=actor.x,z=actor.z,yaw=actor.yaw,speed=actor.speed,mounted=actor.mounted,walkHeight=actor.walkHeight,
        space=session.space,running=session.running,online=session.online,waypoint=session.waypoint,
        manualWaypoint=session.manualWaypoint,navigation=session.navigation,lastActor=view.lastActor,lastTarget=view.lastTarget,
        notice=view.notice.props.text,noticeTime=view.noticeTime,speech=view.speechText.props.text,
        speechTime=view.speechTime,speechVisible=view.speech:IsVisible(),mapDistrictId=view.mapDistrictId,
        mapPointPage=view.mapPointPage,mapPickerOpen=view.mapPickerOpen}
    local contacts={}
    for _,person in ipairs(city.contacts.people) do
        local state={}
        for key,value in pairs(person) do if type(value)~="table" and key~="node" and key~="rig" then state[key]=value end end
        contacts[#contacts+1]={person=person,state=state,rotation=Quaternion(person.node.rotation),
            visible=person.node.enabledSelf,rigVisible=person.rig.visible}
    end
    local beforeNodes,beforeObstacles=scene:GetNumChildren(true),#city.obstacles
    local files={}
    local writes,reads,cloudCalls=0,0,0
    local rejectWrite=false
    local restore=Store.UseTestStorage({
        read=function(path) reads=reads+1; return files[path],nil,files[path]==nil end,
        write=function(path,text)
            writes=writes+1
            if rejectWrite then return false,"DeliveryPeopleChecks deliberate memory write failure" end
            files[path]=text; return true
        end,
        cloud={Get=function() cloudCalls=cloudCalls+1; error("DeliveryPeopleChecks forbids cloud reads") end,
            Set=function() cloudCalls=cloudCalls+1; error("DeliveryPeopleChecks forbids cloud writes") end},
    })
    ---@type CareerDeliveryPeople?
    local pool=nil
    local ok,failure=pcall(function()
        assert(Store.NewCareer()) -- Explicit new inner memory profile; NEVER Store.Load/Get before this.
        pool=People.New(city)
        local testPool=assert(pool)
        session.deliveryPeople,city.deliveryPeople=testPool,testPool
        actor.mounted,actor.speed,actor.walkHeight=false,0,0
        session.online=false
        session.navigation={key="",route={}} -- keep outer navigation table itself untouched
        local profile=Store.Get()
        local startWrites=writes
        local fixtures={order("noodle_office",1,"accepted"),order("shop_old",2,"accepted"),
            order("noodle_office",3,"picked_up"),order("old_home",4,"picked_up")}
        sync(testPool,fixtures)
        local stats=testPool:Stats()
        assert(stats.capacity==4 and stats.created==4 and stats.active==4 and stats.unplaced==0
            and stats.overflow==0 and #testPool.slots==4,"four valid distinct old-street targets must fit four real slots")
        local heldRigs,nodes={},{}
        for _,p in ipairs(testPool.people) do
            heldRigs[#heldRigs+1]=p.rig; nodes[#nodes+1]=p.node
            testPool:Update(.1,nearActor(p),true)
            safe(p,city,testPool,fixtures); pose(p,city)
        end
        local warmNodes=scene:GetNumChildren(true)
        local binds,poses=stats.binds,testPool:Stats().poses
        for _=1,40 do sync(testPool,copy(fixtures)) end
        assert(testPool:Stats().binds==binds and testPool:Stats().poses==poses
            and scene:GetNumChildren(true)==warmNodes,"unchanged Sync rebinds/poses or grows nodes")
        local first=assert(testPool:Get("noodle"))
        sync(testPool,{fixtures[1],order("noodle_dealer",5,"accepted"),order("noodle_office",6,"accepted")})
        assert(testPool:Get("noodle")==first and testPool:Stats().active==1,"same-point orders must share one person")
        sync(testPool,{order("old_home",7,"picked_up"),order("shop_old",8,"picked_up")})
        assert(testPool:Stats().active==1 and testPool:Get("home_old"),"same recipient must share one person")
        sync(testPool,{order("tutorial",9,"accepted"),order("dealer_lunch",10,"picked_up")})
        assert(not testPool:Get("breakfast") and not testPool:Get("dealer") and testPool:Stats().external==2
            and testPool:Stats().active==0,"breakfast/dealer must reuse contacts, not duplicate pool people")
        local overflow=copy(fixtures)
        overflow[#overflow+1]=order("park_lunch",11,"picked_up")
        sync(testPool,overflow)
        assert(testPool:Stats().created==4 and testPool:Stats().active<=4 and testPool:Stats().overflow>=1
            and scene:GetNumChildren(true)==warmNodes,"fifth target must not create an unbounded fifth actor")
        -- Churn different points repeatedly, retaining node identities and all four rigs.
        for _=1,12 do
            sync(testPool,fixtures); sync(testPool,{order("park_lunch",12,"picked_up")}); sync(testPool,{})
        end
        assert(testPool:Stats().created==4 and scene:GetNumChildren(true)==warmNodes,"recycling grew the pool node tree")
        for i,p in ipairs(testPool.people) do assert(p.node==nodes[i] and p.rig==heldRigs[i],"slot recycling replaced a Rig/node") end
        assert(same(Store.Get(),profile) and writes==startWrites,"pool Sync/Update mutated Store")

        -- Visit EVERY unique configured endpoint, including outer districts, using
        -- the same real City. Collect all placement failures before rejecting so
        -- one old-street pass cannot conceal an untested outer-city target.
        local seen,missing={},{ }
        for _,template in ipairs(Config.orderTemplates) do
            for _,pickup in ipairs({true,false}) do
                local id=pickup and template.pickupId or template.dropoffId
                if not seen[id] then
                    seen[id]=true
                    local item=order(template.id,100,pickup and "accepted" or "picked_up")
                    sync(testPool,{item},{x=0,z=-20,mounted=false,walkHeight=0})
                    local result=testPool:Stats()
                    local person=testPool:Get(id)
                    if People.ContactIds[id] then
                        assert(not person and result.external==1,"configured existing contact was duplicated: "..id)
                    elseif not person then
                        missing[#missing+1]=id
                        print("[配送实体站位未通过] "..id.." unplaced="..table.concat(result.unplacedIds,",")
                            .." overflow="..table.concat(result.overflowIds,","))
                    else
                        testPool:Update(.1,nearActor(person),true)
                        safe(person,city,testPool,{item}); pose(person,city)
                        print(string.format("[配送实体站位检查] %s (%.3f,%.3f) static/marker/route/Rig",id,person.x,person.z))
                    end
                end
            end
        end
        assert(#missing==0,"configured targets without safe entity placement: "..table.concat(missing,","))
        sync(testPool,{})
        assert(same(Store.Get(),profile) and writes==startWrites,"all-point checks mutated Store")

        -- A non-current parked vehicle must participate in NEW Bind placement.
        -- Only a detached actor table is changed; never move the real parked bike.
        sync(testPool,{fixtures[1]},{x=0,z=-20,vehicleId=Vehicles.EBIKE,parking={}})
        local parkedCandidate=assert(testPool:Get("noodle"))
        local parkedX,parkedZ=parkedCandidate.x,parkedCandidate.z
        local parkedId=""
        ---@type number
        local parkedRadius=0
        for _,id in ipairs(Vehicles.Ids) do
            local radius=Vehicles.Radii[id]
            if id~=Vehicles.EBIKE and type(radius)=="number" then parkedId,parkedRadius=id,radius; break end
        end
        assert(parkedId~="" and parkedRadius>0,"parking fixture needs a valid non-current VehicleData radius")
        local parkingViewer={x=0,z=-20,mounted=false,walkHeight=0,vehicleId=Vehicles.EBIKE,
            parking={[parkedId]={x=parkedX,z=parkedZ,yaw=0}}}
        sync(testPool,{},parkingViewer) -- clear prior target; force a fresh Bind
        sync(testPool,{fixtures[1]},parkingViewer)
        local avoided=assert(testPool:Get("noodle"),"parked non-current vehicle left no valid alternate stand")
        assert((avoided.x-parkedX)^2+(avoided.z-parkedZ)^2>=(parkedRadius+avoided.radius)^2,
            "new Bind overlaps a non-current parked vehicle")
        testPool:Update(.1,nearActor(avoided),true); safe(avoided,city,testPool,{fixtures[1]}); pose(avoided,city)
        sync(testPool,{},{x=0,z=-20,vehicleId=Vehicles.EBIKE,parking={}})

        sync(testPool,{fixtures[1]})
        local merchant=assert(testPool:Get("noodle"))
        testPool:Update(.1,nearActor(merchant),true)
        local rest=merchant.rig:GetBonePosition("R_Hand")
        local beforePoses=merchant.poseCount
        assert(testPool:Respond("noodle",true),"active merchant did not respond")
        assert(merchant.poseCount>beforePoses and (merchant.rig:GetBonePosition("R_Hand")-rest):Length()>.015,
            "merchant response must change real hand immediately, not just text/metadata")
        local clamped=merchant.rig.reachClampedFrames or 0
        for _=1,25 do testPool:Update(.1,nearActor(merchant),true); pose(merchant,city) end
        assert((merchant.rig.reachClampedFrames or 0)==clamped,"handover IK clamped beyond anatomical reach")
        -- A new pending order at this same merchant cancels the previous visual
        -- departure hold; far-LOD checks below concern pose clocks, not exit time.
        sync(testPool,{order("noodle_office",101,"accepted")})
        assert(merchant.hold==0 and merchant.active,"new same-point work did not cancel pickup exit hold")
        local paused=frozen(merchant)
        for _=1,30 do testPool:Update(.1,nearActor(merchant),false) end
        samePose(merchant,paused,"phone/pause advanced clock, turn, gesture or bones")
        assert(merchant.node.enabledSelf,"phone/pause must freeze without hiding outdoor NPC")
        city.space="hostel"
        testPool:Update(.1,nearActor(merchant),true)
        assert(not merchant.node.enabledSelf,"indoor delivery NPC not hidden")
        samePose(merchant,paused,"indoor NPC animation advanced")
        city.space="city"
        testPool:Update(.1,nearActor(merchant),true)
        assert(merchant.node.enabledSelf,"return outdoors did not restore NPC")
        testPool:Update(.1,{x=merchant.x+1000,z=merchant.z+1000},true)
        local far=frozen(merchant)
        for _=1,30 do testPool:Update(.1,{x=merchant.x+1000,z=merchant.z+1000},true) end
        assert(not merchant.node.enabledSelf,"distant delivery NPC not hidden")
        samePose(merchant,far,"distant NPC continued animation/IK")
        assert(not testPool:IsFree(merchant.x,merchant.z,.32),"far-hidden NPC changed logical collision")
        assert(not testPool:Get("not_exists") and not testPool:Respond("not_exists",false),"unknown target accepted")
        sync(testPool,{})

        -- Production Session.Interact only: successful transactions cause real
        -- response; rejection (authorization AND memory commit failure) cannot.
        local function at(pointId)
            local point=assert(Config.points[pointId])
            actor.x,actor.z,actor.speed,actor.walkHeight,actor.mounted=point.x,point.z,0,0,false
            session:Refresh()
        end
        local function unchanged(before,writeCount)
            assert(same(Store.Get(),before) and writes==writeCount,"rejected/duplicate handoff mutated wallet/order/profile")
        end
        assert(Delivery.Accept()) -- Real first order, not an invented payout fixture.
        session:Refresh()
        local tutorial=assert(Delivery.GetActive())
        local owner=assert(city.contacts:Get("breakfast_owner"))
        at(tutorial.pickupId)
        local ownerPoses=owner.poseCount
        local before=Store.Get(); local count=writes
        session:Interact()
        assert(assert(Delivery.GetActive()).status=="picked_up" and owner.poseCount>ownerPoses
            and not testPool:Get("breakfast"),"real breakfast pickup did not reuse/respond existing owner")
        assert(Store.Get().cashCents==before.cashCents and writes==count+1,"pickup rewarded money or double-committed")
        at(tutorial.dropoffId)
        local recipient=assert(testPool:Get(tutorial.dropoffId),"real pickup did not sync recipient entity")
        testPool:Update(.1,nearActor(recipient),true)
        local recipientPoses=recipient.poseCount
        before=Store.Get(); count=writes
        session:Interact()
        local after=Store.Get()
        assert(after.cashCents==before.cashCents+tutorial.feeCents and after.completedOrders==before.completedOrders+1
            and after.settledOrders[tutorial.id] and #after.ledger==#before.ledger+1
            and after.revision==before.revision+1 and writes==count+1,"delivery must settle exactly once")
        assert(recipient.poseCount>recipientPoses and testPool:Get(tutorial.dropoffId)==recipient
            and recipient.hold>5.9 and not recipient.active and view.speech:IsVisible(),
            "successful production deliver must respond same real recipient and retain it six seconds")
        trafficBlocker(recipient,city)
        pose(recipient,city)
        local delivered=after; count=writes
        session:Interact()
        assert(not Delivery.Deliver(tutorial.id,actor.x,actor.z,{riding=false,speed=0}),"duplicate settlement accepted")
        unchanged(delivered,count)
        assert(recipient.poseCount>recipientPoses and recipient.hold>5.9,"duplicate interact discarded retained recipient")
        local held=frozen(recipient)
        for _=1,20 do testPool:Update(.1,nearActor(recipient),false) end
        samePose(recipient,held,"pause consumed recipient exit hold")
        for _=1,59 do testPool:Update(.1,nearActor(recipient),true) end
        assert(testPool:Get(tutorial.dropoffId)==recipient and recipient.hold>0,"recipient left before six active seconds")
        for _=1,2 do testPool:Update(.1,nearActor(recipient),true) end
        assert(not testPool:Get(tutorial.dropoffId) and not recipient.node.enabledSelf,"recipient did not exit after six seconds")
        assert(scene:GetNumChildren(true)==warmNodes,"recipient retirement destroyed/recreated fixed pool nodes")

        installOrders({order("noodle_office",20,"accepted")})
        at("noodle")
        merchant=assert(testPool:Get("noodle"))
        testPool:Update(.1,nearActor(merchant),true)
        local function rejected(x,z,mounted,speed,height,failCommit)
            actor.x,actor.z,actor.mounted,actor.speed,actor.walkHeight=x,z,mounted,speed,height
            local state=Store.Get(); local n=writes; local bones=frozen(merchant)
            local speech=view.speechText.props.text
            rejectWrite=failCommit
            session:Interact()
            rejectWrite=false
            unchanged(state,n+(failCommit and 1 or 0))
            samePose(merchant,bones,"failed pickup caused entity response")
            assert(view.speechText.props.text==speech,"failed pickup emitted success speech")
        end
        local p=Config.points.noodle
        rejected(p.x+3,p.z,false,0,0,false)
        rejected(p.x,p.z,true,0,0,false)
        rejected(p.x,p.z,false,.36,0,false)
        rejected(p.x,p.z,false,0,6,false)
        rejected(p.x,p.z,false,0,0,true)
        at("noodle")
        before=Store.Get(); count=writes; beforePoses=merchant.poseCount
        session:Interact()
        assert(assert(Delivery.GetActive()).status=="picked_up" and merchant.poseCount>beforePoses
            and Store.Get().cashCents==before.cashCents and writes==count+1,"real generic merchant handoff not connected")
        assert(testPool:Get("noodle")==merchant and merchant.hold>5.9 and not merchant.active
            and merchant.visible and merchant.node.enabledSelf,
            "successful generic pickup merchant must remain visible for its six-second response")
        trafficBlocker(merchant,city)
        -- Retained merchants have no priority over four newly needed real targets.
        local merchantPressure={fixtures[2],fixtures[3],fixtures[4],order("park_lunch",31,"picked_up")}
        sync(testPool,merchantPressure)
        assert(testPool:Stats().active==4 and testPool:Stats().created==4 and not testPool:Get("noodle"),
            "retained pickup merchant must relinquish its slot to four active targets")
        at("office")
        recipient=assert(testPool:Get("office"))
        testPool:Update(.1,nearActor(recipient),true)
        local state=Store.Get(); local speech=view.speechText.props.text
        local bones=frozen(recipient); count=writes
        rejectWrite=true; session:Interact(); rejectWrite=false
        unchanged(state,count+1); samePose(recipient,bones,"failed delivery commit responded/rewarded recipient")
        assert(view.speechText.props.text==speech and recipient.hold==0,"failed delivery began success exit hold")
        -- Failed authorization on the actual delivery branch as well as pickup.
        actor.mounted=true; count=writes; session:Interact(); actor.mounted=false
        unchanged(state,count); samePose(recipient,bones,"mounted delivery responded")
        actor.speed=.36; session:Interact(); actor.speed=0
        unchanged(state,count); samePose(recipient,bones,"moving delivery responded")
        actor.walkHeight=6; session:Interact(); actor.walkHeight=0
        unchanged(state,count); samePose(recipient,bones,"bridge-level delivery responded")
        actor.x=p.x+15; actor.z=p.z+15; session:Interact()
        unchanged(state,count); samePose(recipient,bones,"remote delivery responded")
        at("office"); before=Store.Get(); count=writes; recipientPoses=recipient.poseCount
        local generic=assert(Delivery.GetActive())
        session:Interact(); after=Store.Get()
        assert(after.cashCents==before.cashCents+generic.feeCents and after.completedOrders==before.completedOrders+1
            and after.revision==before.revision+1 and #after.ledger==#before.ledger+1 and writes==count+1
            and recipient.poseCount>recipientPoses and recipient.hold>5.9,"generic delivery must respond only on committed single settlement")
        delivered=after; count=writes; recipientPoses=recipient.poseCount
        session:Interact()
        assert(not Delivery.Deliver(generic.id,actor.x,actor.z,{riding=false,speed=0}))
        unchanged(delivered,count)
        assert(recipient.poseCount==recipientPoses,"duplicate completion repeated entity handover")
        -- Ready targets take priority over an inactive six-second hold.
        local pressure={fixtures[1],fixtures[2],fixtures[4],order("park_lunch",30,"picked_up")}
        sync(testPool,pressure)
        assert(testPool:Stats().active==4 and testPool:Stats().created==4 and not testPool:Get("office"),
            "retained recipient starved new active targets instead of relinquishing its slot")
        sync(testPool,{})

        -- Two real picked-up orders share ONE recipient. The first success must
        -- not start a departure timer while another delivery still needs them.
        local sharedOrders={order("noodle_office",40,"picked_up"),order("noodle_office",41,"picked_up")}
        installOrders(sharedOrders)
        at("office")
        local shared=assert(testPool:Get("office"))
        testPool:Update(.1,nearActor(shared),true)
        before=Store.Get(); count=writes; recipientPoses=shared.poseCount
        session:Interact()
        after=Store.Get()
        assert(#after.activeOrders==1 and after.activeOrders[1].id==sharedOrders[2].id
            and after.settledOrders[sharedOrders[1].id] and not after.settledOrders[sharedOrders[2].id]
            and after.cashCents==before.cashCents+sharedOrders[1].feeCents
            and after.completedOrders==before.completedOrders+1 and writes==count+1,
            "first same-point delivery must settle only its own order")
        assert(testPool:Get("office")==shared and shared.active and shared.hold==0
            and shared.poseCount>recipientPoses,"first shared delivery started premature exit hold")
        local firstDelivered=Store.Get(); count=writes
        assert(not Delivery.Deliver(sharedOrders[1].id,actor.x,actor.z,{riding=false,speed=0}))
        unchanged(firstDelivered,count)
        for _=1,20 do testPool:Update(.1,nearActor(shared),true) end
        assert(testPool:Get("office")==shared and shared.active and shared.hold==0,
            "shared recipient lost the remaining order during two-second wait")
        before=Store.Get(); count=writes; recipientPoses=shared.poseCount
        session:Interact(); after=Store.Get()
        assert(#after.activeOrders==0 and after.settledOrders[sharedOrders[2].id]
            and after.cashCents==before.cashCents+sharedOrders[2].feeCents
            and after.completedOrders==before.completedOrders+1 and after.revision==before.revision+1
            and writes==count+1,"last shared order did not settle exactly once")
        assert(testPool:Get("office")==shared and not shared.active and shared.hold>5.9
            and shared.visible and shared.poseCount>recipientPoses,
            "last shared delivery must start a NEW full six-second exit hold")
        testPool:Update(.7,nearActor(shared),true)
        local finalHold=shared.hold
        local finalPose=shared.poseCount
        delivered=Store.Get(); count=writes
        session:Interact()
        assert(not Delivery.Deliver(sharedOrders[2].id,actor.x,actor.z,{riding=false,speed=0}))
        session:Refresh()
        unchanged(delivered,count)
        near(shared.hold,finalHold,.000001,"duplicate shared delivery renewed the six-second timer")
        assert(shared.poseCount==finalPose,"duplicate shared delivery repeated recipient response")
        conversationLayout(session)
        assert(reads==0 and cloudCalls==0,"checks read a save or touched cloud")
        testPool:Dispose(); testPool:Dispose()
        for _,rig in ipairs(heldRigs) do assert(rig.disposed,"pool did not explicitly dispose held Rig/material") end
        assert(not testPool:Get("office") and testPool:Stats().disposed,"disposed pool API still live")
        assert(scene:GetNumChildren(true)==beforeNodes and #city.obstacles==beforeObstacles,"pool Dispose leaked nodes/static blockers")
    end)
    -- Every stage is independent: an assertion/Dispose/UI failure must NEVER
    -- prevent restoring outer Store or real Session/City identities.
    local errors={}
    local function cleanup(fn)
        local worked,detail=pcall(fn)
        if not worked then errors[#errors+1]=tostring(detail) end
    end
    cleanup(function() if pool then pool:Dispose() end end)
    session.deliveryPeople,city.deliveryPeople=old.pool,old.cityPool
    city.space=old.citySpace
    actor.x,actor.z,actor.yaw,actor.speed,actor.mounted,actor.walkHeight=old.x,old.z,old.yaw,old.speed,old.mounted,old.walkHeight
    session.space,session.running,session.online=old.space,old.running,old.online
    session.waypoint,session.manualWaypoint,session.navigation=old.waypoint,old.manualWaypoint,old.navigation
    for _,saved in ipairs(contacts) do
        cleanup(function()
            local person=saved.person --[[@as CareerStreetPerson]]
            for key,value in pairs(saved.state) do person[key]=value end
            city.contacts.life:Pose(person)
            person.poseCount=saved.state.poseCount
            person.node.rotation=saved.rotation
            person.node:SetEnabledRecursive(saved.visible); person.rig.visible=saved.rigVisible
        end)
    end
    cleanup(restore) -- outer Store restored even if any cleanup above failed
    cleanup(function()
        view:CloseConversation(); view:ClosePhone(); view:ShowGame()
        session:Refresh()
        view.lastActor,view.lastTarget=old.lastActor,old.lastTarget
        view.notice:SetText(old.notice or ""); view.noticeTime=old.noticeTime
        view.speechText:SetText(old.speech or ""); view.speechTime=old.speechTime; view.speech:SetVisible(old.speechVisible)
        view.mapDistrictId,view.mapPointPage,view.mapPickerOpen=old.mapDistrictId,old.mapPointPage,old.mapPickerOpen
        assert(scene:GetNumChildren(true)==beforeNodes and #city.obstacles==beforeObstacles,"Run failed to restore real nodes/obstacles")
    end)
    if not ok then error(tostring(failure)..(#errors>0 and " / cleanup: "..table.concat(errors,"; ") or ""),0) end
    assert(#errors==0,table.concat(errors,"; "))
    print("[配送实体隔离验收通过] 生产Interact取送/失败零回应零奖励/一次结算；真实Rig骨长鞋底姿势；静态安全与2m接近通道；共享4槽回收；暂停远距室内；6秒退场；嵌套内存禁云。未代替GPU自然度实拍验收。")
    return true
end

-- Controlled real-scene staging only; caller owns capture and test Session Dispose.
-- Pickup shows the real accepted merchant; recipient/handover progress through
-- actual Session.Interact commits, never a visual-only fake handoff.
-- This intentionally leaves the isolated test session staged for the caller to shoot.
---@param session CareerSession
---@param view string pickup/recipient/handover/handover0/handover1/handover2
function Checks.Shot(session,view)
    assert(session.options and session.options.test==true and type(session.restoreTestStorage)=="function",
        "handoff shot requires explicit test=true memory Session")
    local phase=view:match("^handover([012])$")
    local handover=view=="handover" or phase~=nil
    assert(view=="pickup" or view=="recipient" or handover,"unknown handoff shot view")
    local requested=false
    for _,arg in ipairs(GetArguments()) do if arg=="-careerhandoffshot="..view then requested=true end end
    assert(requested,"handoff shot requires explicit -careerhandoffshot=<view>")
    local city,actor,pool=assert(session.city),assert(session.actor),assert(session.deliveryPeople)
    assert(city.deliveryPeople==pool and session.camera,"handoff shot requires production City pool and ThirdPersonCamera")
    session:ApplySpace("city"); session.online=false; session.waypoint=""; session.manualWaypoint=false
    if session.traffic then session.traffic.active=false end
    session.view:CloseConversation(); session.view:ClosePhone(); session.view:ShowGame()
    installOrders({order("noodle_office",50,"accepted")})
    actor.mounted=false; actor.visuals:SetMounted(false)
    actor.speed,actor.steer=0,0
    local function at(pointId)
        local p=assert(Config.points[pointId])
        assert(city:StaticFree(p.x,p.z,.32,"walk",0),"shot marker not statically reachable")
        session.navigation={key="",route={}}
        actor:Teleport(p.x,p.z,180); actor.speed,actor.steer=0,0; actor:SyncVisuals(0)
        session.navigation={key="",route={}}
        session:Refresh()
    end
    at("noodle")
    local person=assert(pool:Get("noodle"),"shot merchant not placed")
    for _=1,20 do pool:Update(.05,actor,true) end
    if view~="pickup" then
        session:Interact(); assert(assert(Delivery.GetActive()).status=="picked_up")
        at("office"); person=assert(pool:Get("office"))
        for _=1,20 do pool:Update(.05,actor,true) end
        if handover then
            local count=person.poseCount
            session:Interact()
            assert(not Delivery.GetActive() and person.poseCount>count and person.hold>5.9,
                "handover shot must execute real successful recipient delivery")
            if phase then
                -- Identical world/body clock and camera across all three shots;
                -- only the existing successful response's gesture envelope changes.
                local u=({["0"]=.04,["1"]=.5,["2"]=.82})[phase]
                person.gestureTime=person.gestureDuration*u
                person.gestureWeight=math.sin(u*math.pi)^.65
                pool:Pose(person)
                pose(person,city)
                print(string.format("[配送交接固定相位] %s clock=%.3f t=%.3f weight=%.3f hold=%.3f",
                    view,person.clock,person.gestureTime,person.gestureWeight,person.hold))
            end
        end
    end
    -- The same production camera library used by Session; no hand-rolled orbit.
    local yaw=math.deg(math.atan(person.x-actor.x,person.z-actor.z))
    actor:Teleport(actor.x,actor.z,yaw); actor.speed,actor.steer=0,0; actor:SyncVisuals(0)
    session.navigation={key="",route={}}
    session:Refresh()
    local cameraYaw=yaw+180 -- look from the street side, not from inside the facade
    session.yaw,session.pitch=cameraYaw,10
    session.camera:SetModeConfig("normal",{distance=4.8,offset=V(0,1.25,0),fov=58})
    session.camera:SetMode("normal"); session.camera:Update(2,actor.node,cameraYaw,10)
    session:UpdateEnvironment(9)
    session.view.overlay:SetVisible(false); session.view:ResetInput()
    pool:Update(.1,actor,false) -- test auto-Update is frozen by the production Session
    print(string.format("[配送交接实拍就绪] %s / %s / (%.2f,%.2f) / production Rig + ThirdPersonCamera / memory-only / fixed phase frozen",view,person.pointId,person.x,person.z))
end
return Checks
