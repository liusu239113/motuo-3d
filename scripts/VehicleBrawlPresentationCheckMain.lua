-- Isolated production wiring acceptance, based on FormalVehicleCheckMain/NewVehicleIntegrationCheckMain.
-- No main/World/Race simulation, profile reads/writes, ads, publish configuration or skill mutations.
assert(cache:AddResourceDir("/workspace/assets",false))
assert(cache:AddResourceDir("/workspace/scripts",false))
cache.searchPackagesFirst=false
local Visual=require("MixedVisuals")
local Assets=require("MixedAssets")
local Driver=require("MixedDriver")
local Rider=require("Rider")
local RV=require("RaceVisuals")
local UI=require("urhox-libs/UI")
local Preview=require("GaragePreview")
local V=Vector3
---@type Scene?
local scene_=nil
---@type table[]
local players_={}
---@type RaceVisuals?
local rivals_=nil
---@type GaragePreview?
local garage_=nil
local assertions_=0
local frames_=0
local completed_=false
local KEYART="image/vehicle_brawl_keyart_20261104212846.png"
local GARAGE="image/vehicle_brawl_garage_20261104213013.png"
local function check(ok,message)
    assert(ok,"[VehicleBrawlPresentation] "..message)
    assertions_=assertions_+1
end
---@param rig Rider
---@param id string
local function realRider(rig,id)
    check(rig.model~=nil and rig.node~=nil,id.." real AnimatedModel, not placeholder")
    check(rig.model:GetModel()==cache:GetResource("Model",Rider.ModelPath),id.." production Rider MDL")
    check(rig.model:GetSkeleton():GetNumBones()==41,id.." 41 production bones")
    rig:ValidatePose()
    check((rig.poseFailures or 0)==0,id.." ValidatePose transaction")
end
---@param rig Rider
---@param localReference Vector3
---@param label string
local function follows(rig,localReference,label)
    local hip=assert(rig.model:GetSkeleton():GetBone("Hip")):GetFinalWorldTransform():Translation()
    check((hip-rig.parent:LocalToWorld(localReference)):Length()<.003,label.." world hip follows vehicle")
end
local function state(x,y,z,heading,steer,pitch,lean,spin,altitude)
    return {x=x,y=y,z=z,heading=heading,steer=steer,pitch=pitch,lean=lean,airSpin=spin,
        oddAltitude=altitude,distance=.317,speed=18,airborne=y>0,oddActive=0,oddPhase="idle"}
end
---@param scene Scene
local function playerChecks(scene)
    -- Use the public Bike route used by production, not a manually assembled rider.
    local player=require("Bike").New(scene,"skateboard")
    players_[#players_+1]=player
    local rig=player.riderRig
    realRider(rig,"player skateboard")
    check(Visual.HasRider("skateboard"),"skateboard registered by HasRider")
    local reference=rig:ReadPose()
    for _,sample in ipairs({state(0,0,0,0,0,0,0,0,0),state(14,1.8,-9,83,1,22,48,175,.7),
        state(-11,.6,8,-137,-1,-18,-44,-179,.2)}) do
        player:UpdateState(.02,sample,false,.25)
        rig:ValidatePose()
        check((rig:ReadPose().hip-reference.hip):Length()<.0002,"player steering/jump local hip stable")
        check((rig:ReadPose().leftFoot-reference.leftFoot):Length()<.0002,"player front foot stays on board")
        check((rig:ReadPose().rightFoot-reference.rightFoot):Length()<.0002,"player rear foot stays on board")
        follows(rig,reference.hip,"player steering/jump")
        check((player.node.worldPosition-V(sample.x,sample.y,sample.z)):Length()<.0001,"player consumes actual jump position")
        check(math.abs(player.visual.position.y-sample.oddAltitude)<.0001,"player consumes airborne altitude")
    end
    player:UpdateState(.02,state(-40,0,0,25,0,0,0,0,0),true,.3)
    check(player.firstPerson and not rig.visible and not rig.node.enabledSelf,"first person hides complete player")
    check(player.body.enabled,"first person preserves board")
    player:SetFirstPerson(false)
    check(not player.firstPerson and rig.visible and rig.node.enabled,"third person restores complete player")
    realRider(rig,"restored player skateboard")
    player:SetRiderColor("blue")
    check(rig.colorId=="blue","player real rider color")
    return player
end
---@param scene Scene
local function aiChecks(scene)
    local root=scene:CreateChild("IntegrationRacePresentation")
    local racers={}
    -- A minimal presentation-only owner, as in the existing integration fixture.
    local visuals=setmetatable({scene=scene,root=root,rosterRoot=root:CreateChild("RaceRivals"),
        runners={},markers={},materials={},world={},race={racers=racers},clock=0,visibilityClock=0,
        highQuality=false,leanSign=1,disposed=false,visible=true,EnsurePolice=function() end},RV)
    rivals_=visuals
    check(#Driver.Ids==10,"exact ten open-vehicle driver profiles")
    for i,id in ipairs(Driver.Ids) do
        local data={id="integration_"..id,vehicleId=id,colorId=i%2==0 and "yellow" or "red",index=i,
            x=((i-1)%5)*3.7,y=0,z=((i-1)//5)*4.7,heading=25,pitch=0,lean=0,speed=18,steer=.7,
            driveSim={distance=.317,oddActive=0,oddAltitude=0}}
        racers[#racers+1]=data
        local runner=visuals:CreateRunner(data)
        visuals.runners[data.id]=runner
        local rig=assert(runner.fullRider)
        realRider(rig,"AI "..id)
        check(runner.rider==rig and rig.parent==runner.visual,id.." actual runner fullRider binding")
        check(runner.body:GetVar("FormalModel"):GetString()==Assets.Vehicles[id].model,id.." AI formal vehicle MDL")
        check(not runner.node:GetChild("Cockpit",true) and not runner.node:GetChild("BurnoutSmokePool",true),id.." lightweight AI")
        local before=runner.poseRefreshes
        runner.node:SetTransform(V(data.x,2.1,data.z),Quaternion(0,127,0),V.ONE)
        runner.visual:SetTransform(V(0,.6,0),Quaternion(-20,174,12),V.ONE)
        visuals:RefreshPose(runner,data,true)
        check(runner.poseRefreshes>before,id.." production RefreshPose executed")
        follows(rig,rig:ReadPose().hip,"AI "..id.." turned airborne")
    end
    visuals:SetVisible(false)
    for _,runner in pairs(visuals.runners) do check(not runner.node.enabled,runner.vehicleId.." AI hidden") end
    visuals:SetVisible(true)
    visuals:Update(.05,{x=0,z=0})
    for _,runner in pairs(visuals.runners) do
        check(runner.active and runner.fullRider.node.enabled,runner.vehicleId.." AI visible restored")
        realRider(runner.fullRider,"AI restored "..runner.vehicleId)
    end
    local stats=visuals:GetStats()
    check(stats.rivals==10 and stats.riders==10 and stats.activeRiders==10,"ten actual active AI riders counted")
    local office=assert(visuals.runners.integration_office)
    local officeData=assert(racers[2])
    officeData.driveSim.oddActive,officeData.driveSim.oddAge=1,.17
    visuals:Update(.01,{x=0,z=0})
    check(math.abs(office.fullRider.node.rotation:YawAngle())>20,"AI office rider follows actual spinning seat each frame")
    local held=office.fullRider.node.rotation
    officeData.driveSim.paused=true
    officeData.driveSim.oddAge=7
    visuals:Update(.5,{x=0,z=0,paused=true})
    check(office.fullRider.node.rotation==held,"AI office paused swivel cannot advance")
    officeData.driveSim.paused=false;officeData.driveSim.oddActive=0
    visuals:Update(.01,{x=0,z=0})
    print("[VehicleBrawlPresentation] AI PASS 10 CreateRunner / RefreshPose / SetVisible restore / GetStats=10/10/10 / office seat sync+pause")
end
---@param scene Scene
---@param camera Camera
---@param index integer
---@param rect IntRect
local function viewport(scene,camera,index,rect)
    local view=Viewport:new(scene,camera,rect)
    local path=view:GetRenderPath():Clone()
    assert(path:Load(assert(cache:GetResource("XMLFile","RenderPaths/Forward.xml"))))
    view:SetRenderPath(path)
    renderer:SetViewport(index,view)
end
---@param scene Scene
---@param name string
---@param pos Vector3
---@param target Vector3
local function camera(scene,name,pos,target)
    local node=scene:CreateChild(name);node.position=pos;node:LookAt(target)
    local c=node:CreateComponent("Camera");c.nearClip,c.farClip,c.fov=.025,36,42
    return c
end
local function garageChecks()
    local preview=Preview.New({position="absolute",left=0,top=0,width="100%",height="100%"})
    garage_=preview
    preview.vehicleId,preview.active="skateboard",true
    local panel=UI.Panel{position="absolute",left="50%",top="50%",width="50%",height="50%",
        backgroundImage=GARAGE,backgroundFit="cover",children={preview}}
    UI.SetRoot(UI.Panel{width="100%",height="100%",children={panel}})
    UI.Layout()
    -- This integration fixture already preloaded the original source for player/AI.
    -- Exercise the same formal assembly + activation hooks; asynchronous DWP and
    -- cold/hot switching have a dedicated GaragePreviewPerformanceCheckMain fixture.
    preview:EnsureCache()
    local entry=assert(preview.previewCache:Request("skateboard",preview.generation))
    preview:BuildVehicle(entry)
    entry.state="ready"
    preview:Activate(entry)
    check(preview.riderRig==nil,"garage vehicle-only preview has no riderRig")
    local previewScene=assert(preview.previewScene)
    check(#previewScene:GetComponents("AnimatedModel",true)==0,"garage has zero AnimatedModels")
    local content=assert(assert(preview.displayEntry).content)
    local body=assert(content:GetChild("Vehicle_skateboard"))
    check(body:GetVar("FormalModel"):GetString()==Assets.Vehicles.skateboard.model,"garage actual BuildScene formal board")
    preview.turntable.rotation=Quaternion.IDENTITY
    local vehicleBounds=BoundingBox()
    local drawables=body:GetComponents("StaticModel",true)
    check(#drawables>0,"garage retains real vehicle StaticModels")
    for _,draw in ipairs(drawables) do vehicleBounds:Merge(draw.worldBoundingBox) end
    check(math.abs(vehicleBounds.max.y-preview.vehicleHeight)<.003,"garage framing uses vehicle-only bounds above canonical ground")
    check(math.abs(content.position.y)<.0001,"garage canonical mixed vehicle ground remains zero")
    check(preview.vehicleHeight>0,"garage vehicle-only height is nonzero")
    check(preview.previewSurface~=nil and preview.previewTexture~=nil,"garage actual render target allocated")
    ---@type Vector3
    local offset=content.position
    local initialAngle=preview.angle
    local staticCount=#previewScene:GetComponents("StaticModel",true)
    for step=1,12 do
        preview:Update(1/12)
        check((content.position-offset):Length()<.00001,"garage Update cannot erase vehicle centering")
        check(math.abs(content.position.y)<.0001,"garage rotating canonical ground remains zero")
        check(preview.riderRig==nil,"garage rotation "..step.." must not create driver")
        check(#previewScene:GetComponents("AnimatedModel",true)==0,"garage rotation "..step.." has zero AnimatedModels")
        check(#previewScene:GetComponents("StaticModel",true)==staticCount,"garage rotation cannot add placeholder driver geometry")
    end
    check(preview.angle~=initialAngle,"garage twelve Updates actually rotate the vehicle")
    print(string.format("[VehicleBrawlPresentation] garage PASS vehicle-only bbox=%.4f/%.4f/%.4f height=%.4f offset=%s Update12 no driver",
        vehicleBounds.size.x,vehicleBounds.size.y,vehicleBounds.size.z,preview.vehicleHeight,offset:ToString()))
end
local function hudChecks()
    local HUD=require("HUD") -- module metadata only; never HUD.New/Profile.Load/Save.
    for _,path in ipairs({KEYART,GARAGE}) do
        local found=false
        for _,registered in ipairs(HUD.Resources) do if registered==path then found=true end end
        check(found and HUD.ResourceTypes[path]=="Texture2D","HUD.Resources actual background "..path)
        local texture=assert(cache:GetResource("Texture2D",path))
        check(texture.width>0 and texture.height>0,"HUD new background loads "..path)
        print(string.format("[VehicleBrawlPresentation] HUD PASS %s %dx%d",path,texture.width,texture.height))
    end
end
function Start()
    scene_=Scene();scene_:CreateComponent("Octree")
    local lg=scene_:CreateChild("LightGroup")
    lg:LoadXML(assert(cache:GetResource("XMLFile","LightGroup/Daytime.xml")):GetRoot())
    local zone=assert(lg:GetComponent("Zone",true))
    zone.depthFogEnable,zone.heightFogEnable=false,false
    local light=lg:GetComponent("Light",true)
    if light then light.brightness=2.2;light.castShadows=false end
    renderer.hdrRendering=true
    UI.Init({theme="default-dark",scale=UI.Scale.DEFAULT})
    hudChecks()
    local player=playerChecks(scene_)
    aiChecks(scene_)
    garageChecks()
    local w,h=graphics:GetWidth(),graphics:GetHeight()
    local mx,my=w//2,h//2
    renderer:SetNumViewports(3)
    local playerCam=camera(scene_,"PlayerReview",V(-36.5,2.8,-4.0),V(-40,1,0))
    viewport(scene_,playerCam,0,IntRect(0,0,mx,my))
    local aiCam=camera(scene_,"AIOpenVehicleReview",V(7.4,11,-14),V(7.4,1,2.3))
    aiCam.orthographic=true;aiCam.orthoSize=11;aiCam.farClip=40
    viewport(scene_,aiCam,1,IntRect(mx,0,w,my))
    local first=require("Bike").New(scene_,"skateboard");players_[#players_+1]=first
    first:UpdateState(.02,state(50,0,0,0,0,0,0,0,0),true,0)
    local eye=first.Cockpit.localOffset
    check((eye-Driver.Profiles.skateboard.eye):Length()<.0001,"actual skateboard camera matches standing eye")
    local eyeNode=first.visual:CreateChild("ActualFirstPersonEye")
    eyeNode.position=eye;eyeNode.rotation=Quaternion(first.Cockpit.pitch,V.RIGHT)
    local eyeCam=eyeNode:CreateComponent("Camera")
    eyeCam.nearClip,eyeCam.farClip,eyeCam.fov=.025,30,first.Cockpit.fov
    eyeCam.autoAspectRatio=false;eyeCam.aspectRatio=mx/(h-my)
    viewport(scene_,eyeCam,2,IntRect(0,my,mx,h))
    local p=eyeCam:WorldToScreenPoint(first:GetDashboardWorldPosition())
    check(p.x>.1 and p.x<.9 and p.y>.50 and p.y<.97,"actual standing-eye dashboard visible below sightline")
    local left=eyeCam:WorldToScreenPoint(first.visual:LocalToWorld(first.Cockpit.dash-V(first.Cockpit.dashSize.x*.5,0,0)))
    local right=eyeCam:WorldToScreenPoint(first.visual:LocalToWorld(first.Cockpit.dash+V(first.Cockpit.dashSize.x*.5,0,0)))
    check(math.abs(right.x-left.x)<.55,"first-person instrument width does not fill screen")
    check(not first.riderRig.node.enabled and first.body.enabled,"real first-person hidden rider / board retained")
    print(string.format("[VehicleBrawlPresentation] first PASS eye=%s dashProjection=%.4f/%.4f width=%.4f",eye:ToString(),p.x,p.y,math.abs(right.x-left.x)))
    -- Isolate review cameras to the exact production model set, not pooled skill meshes
    -- or disabled player cockpit drawables belonging to a different tile.
    for _,draw in ipairs(scene_:GetComponents("StaticModel",true)) do draw.viewMask=4 end
    for _,draw in ipairs(scene_:GetComponents("AnimatedModel",true)) do draw.viewMask=4 end
    for _,draw in ipairs(player.body:GetComponents("StaticModel",true)) do draw.viewMask=2 end
    player.riderRig.model.viewMask=2;playerCam.viewMask=2
    for _,runner in pairs(rivals_.runners) do
        for _,draw in ipairs(runner.body:GetComponents("StaticModel",true)) do draw.viewMask=1 end
        runner.fullRider.model.viewMask=1
    end
    aiCam.viewMask=1
    for _,draw in ipairs(first.body:GetComponents("StaticModel",true)) do draw.viewMask=8 end
    for _,draw in ipairs(first.cockpit:GetComponents("StaticModel",true)) do draw.viewMask=8 end
    eyeCam.viewMask=8
    local single=false
    for _,arg in ipairs(GetArguments()) do if arg=="-presentation-single" then single=true end end
    if single then
        -- Same production rigs, but only ONE skin-texture render view. No showroom RT.
        garage_:Dispose()
        first:Dispose()
        player:UpdateState(0,state(7.4,0,-3,25,0,0,0,0,0),false,0)
        for _,draw in ipairs(player.body:GetComponents("StaticModel",true)) do draw.viewMask=1 end
        player.riderRig.model.viewMask=1
        aiCam.orthoSize=13;aiCam.viewMask=1
        aiCam.node.position=V(7.4,12,-15);aiCam.node:LookAt(V(7.4,.9,1))
        renderer:SetNumViewports(1)
        viewport(scene_,aiCam,0,IntRect(0,0,w,h))
        UI.SetRoot(UI.Panel{width="100%",height="100%",pointerEvents="none"})
        print("[VehicleBrawlPresentation] SINGLE VIEW production player+10AI; garage RT disposed; first-person disposed")
    end
    completed_=true
    SubscribeToEvent("Update","HandlePresentationCheck")
    print(string.format("[VehicleBrawlPresentation] PASS %d assertions / real player skateboard + 10 AI + garage + 2 HUD images",assertions_))
end
---@param _ string
---@param _ UpdateEventData
function HandlePresentationCheck(_,_)
    frames_=frames_+1
    -- Deterministic resting presentation; integration turn/jump samples were explicitly asserted.
    if frames_==20 and completed_ then
        check(garage_.riderRig==nil,"rendered garage remains vehicle-only")
        if garage_.previewScene then
            check(#garage_.previewScene:GetComponents("AnimatedModel",true)==0,"rendered garage has zero AnimatedModels")
            check(garage_.previewTexture~=nil and garage_.previewSurface~=nil,"rendered garage retains RT")
        end
        print(string.format("[VehicleBrawlPresentation] rendered PASS frame=%d assertions=%d",frames_,assertions_))
    end
end
function Stop()
    UnsubscribeFromEvent("Update")
    local aiRigs={}
    if rivals_ then
        for _,runner in pairs(rivals_.runners) do aiRigs[#aiRigs+1]=runner.fullRider end
        rivals_:Dispose();rivals_:Dispose()
        for _,rig in ipairs(aiRigs) do check(rig.disposed,"AI Dispose releases real rider") end
    end
    for _,player in ipairs(players_) do
        local rig=player.riderRig
        player:Dispose();player:Dispose()
        check(rig.disposed,"player Dispose releases real rider")
    end
    if garage_ then
        check(garage_.riderRig==nil,"garage lifecycle never created driver")
        garage_:Dispose();garage_:Dispose()
        check(garage_.previewScene==nil and garage_.previewTexture==nil and garage_.previewSurface==nil,
            "garage Dispose clears vehicle scene and RT")
    end
    UI.Shutdown()
    if scene_ then scene_:Dispose();scene_=nil end
    print(string.format("[VehicleBrawlPresentation] lifecycle PASS %d AI + %d player + garage disposed / total=%d",#aiRigs,#players_,assertions_))
end
