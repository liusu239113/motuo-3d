-- Explicit isolated-session acceptance of the resident outer traffic pool.
-- WorldChecks owns roads/streaming/delivery/bridges; this file only checks traffic.
local Store=require("Career.Store")
local Config=require("Career.Config")
local Traffic=require("Career.Traffic")
local Outer=require("Career.OuterTraffic")
local World=require("Career.WorldData")
local Checks={}

local function shallow(source)
    local result={}
    for key,value in pairs(source) do result[key]=value end
    return result
end
local function restoreFields(target,source)
    for key in pairs(target) do if source[key]==nil then target[key]=nil end end
    for key,value in pairs(source) do target[key]=value end
end
local function same(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~="table" then return a==b end
    for k,v in pairs(a) do if not same(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
local function near(a,b,message)
    assert(math.abs(a-b)<.000001,message)
end
local function capture(items)
    local result={}
    for _,item in ipairs(items) do
        result[#result+1]={item=item,fields=shallow(item),position=item.node.position,
            rotation=item.node.rotation,enabled=item.node:IsEnabled()}
    end
    return result
end
local function restoreItems(snapshots)
    for _,saved in ipairs(snapshots) do
        restoreFields(saved.item,saved.fields)
        saved.item.node.position=saved.position
        saved.item.node.rotation=saved.rotation
        saved.item.node:SetEnabledRecursive(saved.enabled)
        if saved.item.rig then saved.item.rig:PoseWalk(saved.item.phase,saved.item.gaitWeight) end
    end
end
local function unchanged(items,snapshots,message)
    assert(#items==#snapshots,message.." count")
    for index,item in ipairs(items) do
        local saved=snapshots[index].fields
        assert(item==snapshots[index].item,message.." identity")
        for _,field in ipairs({"s","speed","x","z","yaw","phase","gaitWeight","direction","travelled","turn"}) do
            assert(item[field]==saved[field],message.." "..field)
        end
    end
end

-- Collision plan (metres, top view):
-- World building AABBs | sidewalk person circle r=.32 | lane car OBB (L x W)
-- Check the full OBB via Outer.StaticFree's enclosing-circle cover, not its centre;
-- then independent four-axis SAT (Traffic.Separate), player/parking circle-OBB,
-- pedestrian/static/circle separation. Test both spawn and each .1s advance.
-- Distant old-town entities retain pose/signal/IK clocks; no forced Hidden override.
local function validate(session)
    local traffic=assert(session.traffic)
    local outer=traffic.outer
    local city=assert(session.city)
    local blockers=traffic:Blockers()
    local stats=outer:Stats()
    assert(stats.carBudget==6 and stats.peopleBudget==4,"outer budgets must be 6 cars / 4 people")
    assert(stats.cars<=6 and stats.pooledCars<=6 and stats.people<=4 and stats.pooledPeople<=4,"outer pool exceeded its budget")
    for i,car in ipairs(outer.cars) do
        assert(car.inUse and car.node:IsEnabled(),"active outer car hidden/unowned")
        assert(not World.IsOld(car.x,car.z),"outer car entered protected old street")
        assert(Outer.StaticFree(city,car),"outer OBB overlaps actual City/World static domain")
        assert(not city:IsFree(car.x,car.z,.32,"walk",0),"outer car missing from production City collision domain")
        for j=i+1,#outer.cars do assert(Traffic.Separate(car,outer.cars[j]),"outer car-car OBB overlap") end
        for _,old in ipairs(traffic.cars) do assert(Traffic.Separate(car,old),"outer/old car OBB overlap") end
        for _,b in ipairs(blockers) do assert(Traffic.CircleFree(car,b.x,b.z,b.radius),"outer car overlaps stationary player/parking") end
        for _,p in ipairs(outer.people) do assert(Traffic.CircleFree(car,p.x,p.z,p.radius),"outer car overlaps pedestrian") end
    end
    for i,p in ipairs(outer.people) do
        assert(p.inUse and p.node:IsEnabled(),"active outer pedestrian hidden/unowned")
        assert(city:StaticFree(p.x,p.z,.36,"walk",0),"outer pedestrian walks through actual static obstacle")
        assert(not city:IsFree(p.x,p.z,.1,"walk",0),"outer pedestrian absent from production City collision domain")
        for _,b in ipairs(blockers) do
            assert((p.x-b.x)^2+(p.z-b.z)^2>=(p.radius+b.radius)^2,"outer pedestrian overlaps player/parking")
        end
        for j=i+1,#outer.people do
            local other=outer.people[j]
            assert((p.x-other.x)^2+(p.z-other.z)^2>=(p.radius+other.radius)^2,"outer pedestrian-pedestrian overlap")
        end
    end
    for _,pool in ipairs({outer.carPool,outer.peoplePool}) do
        for _,item in ipairs(pool) do if not item.inUse then assert(not item.node:IsEnabled(),"recycled pool node remains visible") end end
    end
end

---@param session CareerSession
function Checks.Run(session)
    assert(session.options.test==true and type(session.restoreTestStorage)=="function",
        "OuterChecks requires Session.New({test=true}) memory storage; never run on a real save")
    local actor,city,traffic,camera=assert(session.actor),assert(session.city),assert(session.traffic),assert(session.camera)
    local outer=assert(traffic.outer,"outer traffic not installed") --[[@as CareerOuterTraffic]]
    assert(not traffic.disposed and not outer.disposed,"traffic already disposed")
    local started=os.clock()
    local originalStore=Store.Get()
    local originalActor=shallow(actor)
    local originalOuter=shallow(outer)
    local signals=outer.signals --[[@as OuterSignalSystem]]
    local signalTime=signals.time
    -- Release removes array entries, so retain independent array snapshots.
    for _,field in ipairs({"cars","people","carPool","peoplePool","lanes"}) do originalOuter[field]=shallow(outer[field]) end
    local cars,people=capture(outer.carPool),capture(outer.peoplePool)
    local legacyCars,legacyPeople=capture(traffic.cars),capture(traffic.pedestrians.people)
    local previous={active=traffic.active,nearOld=traffic.nearOld,time=traffic.time,poseTime=traffic.pedestrians.poseTime,
        root=traffic.root:IsEnabled(),outerRoot=outer.root:IsEnabled(),space=session.space,
        citySpace=city.space,online=session.online,yaw=session.yaw,pitch=session.pitch,test=session.options.test,
        mode=camera:GetMode(),cameraPosition=camera:GetNode().position,cameraRotation=camera:GetNode().rotation,
        phonePage=session.view.phonePage,blocked=session.view.blocked,overlay=session.view.overlay:IsVisible()}
    local originalCamera=shallow(camera)
    local realCamera=camera:GetCamera()
    local cameraProps={aspectRatio=realCamera.aspectRatio,autoAspectRatio=realCamera.autoAspectRatio,fov=realCamera.fov}
    local originalNodes={}
    for _,item in ipairs(outer.carPool) do originalNodes[item.node]=true end
    for _,item in ipairs(outer.peoplePool) do originalNodes[item.node]=true end
    local files={[Config.SAVE_PATH]=cjson.encode(originalStore)}
    local maxCars,maxPeople,movedCars,movedPeople=0,0,0,0
    local ok,message=pcall(function()
        -- Restore the caller's exact Store through the standard nested-memory adapter.
        Store.WithTestStorage({read=function(path) return files[path],nil,files[path]==nil end,
            write=function(path,text) files[path]=text; return true end,
            cloud={Get=function() error("OuterChecks cloud access forbidden") end,Set=function() error("OuterChecks cloud access forbidden") end}},function()
            assert(Store.Load(),"cannot seed nested memory profile")
            session:ApplySpace("city")
            session.view:ClosePhone(); session.view:ShowGame(); session.view:ResetInput()
            session.online=false; traffic.active=true
            actor.mounted=false; actor.visuals:SetMounted(false); actor.parking={}
            -- Put the fixture on a real free sidewalk beside east-market roads.
            local x,z=city:FindFree(768,-18,.32,"walk",0)
            assert(math.abs(x-768)<60 and math.abs(z)<60,"east-market fixture fell back to old street")
            local bx,bz=city:FindFree(780,-18,actor:VehicleRadius(),"vehicle",0)
            assert(math.abs(bx-780)<60 and math.abs(bz)<60,"parking fixture not local")
            actor.bikeX,actor.bikeZ,actor.bikeYaw=bx,bz,90
            actor:Teleport(x,z,0)
            local function aim()
                -- Use the production camera controller BEFORE Update/Hidden. Real frustum,
                -- explicit aspect ratio: works even before the first headless rendered frame.
                camera:SetMode("normal")
                camera:Update(2,actor.node,0,10)
                realCamera.autoAspectRatio=false; realCamera.aspectRatio=16/9
                local cp=realCamera.node.worldPosition
                assert((cp-Vector3(actor.x,cp.y,actor.z)):LengthSquared()<100^2,"camera did not follow fixture")
                local behind=cp-realCamera.node.worldDirection*80
                assert(realCamera.frustum:IsInside(Sphere(behind,4))==OUTSIDE,"real camera frustum cannot reject behind-camera sphere")
                local viewport=assert(renderer:GetViewport(0),"no production viewport")
                assert(viewport:GetCamera()==realCamera,"Hidden uses another viewport camera")
            end
            aim()
            local frozenCars,frozenPeople=capture(traffic.cars),capture(traffic.pedestrians.people)
            local frozenTime,frozenPose=traffic.time,traffic.pedestrians.poseTime
            local function simulate(seconds)
                for _=1,math.floor(seconds*10+.5) do
                    traffic:Update(.1)
                    validate(session)
                    maxCars,maxPeople=math.max(maxCars,#outer.cars),math.max(maxPeople,#outer.people)
                end
                unchanged(traffic.cars,frozenCars,"far old cars must freeze")
                unchanged(traffic.pedestrians.people,frozenPeople,"far old pedestrians must freeze")
                near(traffic.time,frozenTime,"far old signals/clock advanced")
                near(traffic.pedestrians.poseTime,frozenPose,"far old IK clock advanced")
                assert(not traffic.nearOld,"far fixture incorrectly treated as old town")
            end
            simulate(30)
            assert(maxCars>=1 and maxPeople>=1,
                string.format("real traffic produced no outer entities after 30s: cars=%d people=%d; never bypass Hidden",maxCars,maxPeople))
            assert(#outer.cars>=1 and #outer.people>=1,"outer entities disappeared before freeze checks")
            for _,car in ipairs(outer.cars) do movedCars=movedCars+car.travelled end
            for _,p in ipairs(outer.people) do movedPeople=movedPeople+p.travelled end
            assert(movedCars>1 and movedPeople>1,"spawned traffic must actually advance, not just occupy pool slots")
            near(actor.x,x,"traffic pushed player x"); near(actor.z,z,"traffic pushed player z")
            near(actor.bikeX,bx,"traffic moved parking x"); near(actor.bikeZ,bz,"traffic moved parking z")

            local stoppedCars,stoppedPeople=capture(outer.cars),capture(outer.people)
            local stoppedTime,stoppedSteps,stoppedPose=outer.time,outer.steps,outer.poseTime
            local function frozen(label)
                unchanged(outer.cars,stoppedCars,label.." cars")
                unchanged(outer.people,stoppedPeople,label.." people")
                near(outer.time,stoppedTime,label.." clock")
                near(outer.steps,stoppedSteps,label.." steps")
                near(outer.poseTime,stoppedPose,label.." gait clock")
            end
            traffic.active=false; traffic:Update(.2); frozen("traffic inactive")
            traffic.active=true
            -- Disable test-mode early-return so the real Session pause gate is exercised.
            session.options.test=false
            session.view:ShowDialog("外区交通暂停验收","仅内存验收",{})
            session:Update(.2); frozen("production pause")
            assert(same(Store.Get().position,originalStore.position),"paused Session wrote fixture position")
            session.options.test=true; session.view:ShowGame()
            session:ApplySpace("hostel"); traffic:Update(.2); frozen("indoor")
            assert(not outer.root:IsEnabled(),"indoor outer nodes remain visible")
            session:ApplySpace("city"); aim()
            traffic:Update(0); frozen("zero dt")
            traffic:Update(-.1); frozen("negative dt")

            local knownCars,knownPeople={},{}
            for _,item in ipairs(outer.carPool) do knownCars[item.node]=true end
            for _,item in ipairs(outer.peoplePool) do knownPeople[item.node]=true end
            local warmNodes=outer.root:GetNumChildren(true)
            local recycled=outer.recycled
            local reusedCars,reusedPeople=false,false
            for _=1,3 do
                -- Going back to old town naturally recycles; no Release/Acquire/Fill fixture calls.
                actor:Teleport(0,-20,0); aim(); traffic:Update(.1)
                assert(#outer.cars==0 and #outer.people==0 and not outer.root:IsEnabled(),"old-town return must recycle outer pool")
                for _,pool in ipairs({outer.carPool,outer.peoplePool}) do
                    for _,item in ipairs(pool) do assert(not item.inUse and not item.node:IsEnabled(),"recycle must hide every slot") end
                end
                -- Refresh the old snapshots after the legitimate .1s old-town advance.
                frozenCars,frozenPeople=capture(traffic.cars),capture(traffic.pedestrians.people)
                frozenTime,frozenPose=traffic.time,traffic.pedestrians.poseTime
                actor:Teleport(x,z,0); aim(); simulate(3)
                assert(#outer.cars>=1 and #outer.people>=1,"real frustum refill failed on revisit")
                for _,item in ipairs(outer.cars) do if knownCars[item.node] then reusedCars=true end end
                for _,item in ipairs(outer.people) do if knownPeople[item.node] then reusedPeople=true end end
                assert(#outer.carPool<=6 and #outer.peoplePool<=4,"revisits grew pool without bound")
                assert(outer.root:GetNumChildren(true)<=warmNodes,"same-site revisit allocated growing model/skeleton node trees")
            end
            assert(outer.recycled>recycled and reusedCars and reusedPeople,"recycled nodes must be reused by actual Update spawning")
            for _,district in ipairs(World.Districts) do
                actor:Teleport(0,-20,0);aim();traffic:Update(.1)
                local dx,dz=city:FindFree(district.x,district.z-18,.32,"walk",0)
                actor.bikeX,actor.bikeZ=dx+18,dz
                actor:Teleport(dx,dz,0);aim()
                for _=1,30 do traffic:Update(.1) end
                assert(#outer.cars>0 and #outer.people>0,
                    string.format("外区%s真实视锥下未补足交通：%d车/%d人",district.id,#outer.cars,#outer.people))
                print(string.format("[逐区交通覆盖] %s %d车/%d行人（固定池复用，非全城同时实例化）",district.id,#outer.cars,#outer.people))
            end
            assert(same(Store.Get(),originalStore),"traffic-only acceptance changed the seeded profile")
        end)
    end)
    -- Finally: dispose only nodes created by this acceptance, then restore all callers'
    -- actor/parking, pool records, clocks, mode, camera projection, space and memory Store.
    local restored,restoreError=pcall(function()
        session.options.test=previous.test; traffic.active=false
        for _,item in ipairs(outer.peoplePool) do
            if not originalNodes[item.node] then item.rig:Dispose(); item.node:Dispose() end
        end
        for _,item in ipairs(outer.carPool) do if not originalNodes[item.node] then item.node:Dispose() end end
        restoreFields(outer,originalOuter)
        session:ApplySpace(previous.space)
        restoreFields(actor,originalActor)
        actor.visuals:SetMounted(actor.mounted); actor.visuals:UpdateParking(actor.parking,city); actor:SyncVisuals(0)
        restoreItems(cars); restoreItems(people); restoreItems(legacyCars); restoreItems(legacyPeople)
        traffic.time,traffic.nearOld,traffic.pedestrians.poseTime=previous.time,previous.nearOld,previous.poseTime
        city.signals:Update(previous.time)
        traffic.root:SetEnabledRecursive(previous.root); outer.root:SetEnabledRecursive(previous.outerRoot)
        signals:Update(signalTime,actor.x,actor.z,originalOuter.active and previous.space=="city")
        -- Parent recursive visibility can enable idle slots: restore per-slot visibility last.
        restoreItems(cars); restoreItems(people)
        session.online,session.yaw,session.pitch=previous.online,previous.yaw,previous.pitch
        restoreFields(camera,originalCamera)
        camera:GetNode().position=previous.cameraPosition; camera:GetNode().rotation=previous.cameraRotation
        realCamera.fov=cameraProps.fov; realCamera.aspectRatio=cameraProps.aspectRatio; realCamera.autoAspectRatio=cameraProps.autoAspectRatio
        session.view:ClosePhone(); session.view:ShowGame(); session.view:ResetInput()
        if previous.phonePage~="" then session:OpenPhone(previous.phonePage) end
        session.view.blocked=previous.blocked; session.view.overlay:SetVisible(previous.overlay)
        session:Refresh()
        traffic.active=previous.active
        assert(same(Store.Get(),originalStore),"outer acceptance failed to restore caller memory Store")
    end)
    traffic.active=previous.active; session.options.test=previous.test
    if not ok then error(message) end
    assert(restored,restoreError)
    print(string.format("[外区交通验收通过] 真实camera/frustum Update生成%d车/%d人；30s静态域/停车/玩家/车车OBB与行人无重叠，移动%.1fm/%.1fm；老街远处冻结、暂停/室内冻结、3次回收复用节点不增长；原内存档与actor/traffic/camera恢复；CPU %.3fs",
        maxCars,maxPeople,movedCars,movedPeople,os.clock()-started))
    return true
end
return Checks
