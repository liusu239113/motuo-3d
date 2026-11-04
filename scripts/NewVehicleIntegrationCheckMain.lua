-- 基于3D场景脚手架的五车集成验收；不加载主入口、档案、广告或玩家存档。
-- 资源根在脚本解析前加入，模块 require 才能找到 scripts/ 与 assets/。
assert(cache:AddResourceDir("/workspace/assets"))
assert(cache:AddResourceDir("/workspace/scripts"))
local Assets=require("MixedAssets")
-- 只在本次验收进程内开放，未通过前不写回仓库配置。
for _,id in ipairs(Assets.NewIds) do
    local config=assert(Assets.Vehicles[id],"未登记新车："..tostring(id))
    config.delivered=true
end
local Visual=require("MixedVisuals")
local Art=require("NewVehicleArticulation")
local V=Vector3
---@type Scene?
local scene_=nil
---@type table[]
local owners_={}
local count_=0
local function check(ok,message)
    assert(ok,"[五车集成] "..message)
    count_=count_+1
end
local function measure(id)
    local c=assert(Assets.Vehicles[id])
    local model=assert(cache:GetResource("Model",c.model))
    local bounds=BoundingBox()
    local rotation=Quaternion(0,c.rotation,0)
    for slot=0,model.numGeometries-1 do
        local geo=model:GetGeometry(slot,0)
        local vb,ib=geo:GetVertexBuffer(0),geo:GetIndexBuffer()
        local vertices,indices=vb:GetData(),ib:GetData()
        indices:Seek(geo.indexStart*ib.indexSize)
        for _=1,geo.indexCount do
            local index=ib.indexSize==2 and indices:ReadUShort() or indices:ReadUInt()
            vertices:Seek(index*vb.vertexSize+vb:GetElementOffset(SEM_POSITION))
            bounds:Merge(rotation*vertices:ReadVector3())
        end
    end
    local size=bounds.size*(c.targetLength/bounds.size.z)
    print(string.format("[五车实测] %s yaw=%.6f oriented=%.9f/%.9f/%.9f target=%.9f/%.9f/%.9f",id,c.rotation,
        bounds.size.x,bounds.size.y,bounds.size.z,size.x,size.y,size.z))
    return size
end
local function phases(id)
    if id=="centipede" then return {{.2,"tail_windup"},{.55,"tail_sweep"},{1.1,"tail_recover"}} end
    if id=="loader" then return {{.2,"scoop_windup"},{.55,"scoop_lift"},{.9,"scoop_release"},{1.3,"scoop_recover"}} end
    if id=="cicada" then return {{.2,"wound_release"},{.7,"wound_release"}} end
    return {{.2,id=="hovercraft" and "side_jet" or "dash"},{.7,id=="hovercraft" and "side_jet" or "dash"}}
end
local function drive(id,age,phase)
    return {vehicleId=id,x=0,y=0,z=0,heading=0,distance=.317,steer=.35,speed=24,
        oddAge=age,oddPhase=phase,oddActive=math.max(.01,2-age),oddSerial=1,oddHitSerial=0,
        oddJetSide=1,oddJetLateralSpeed=2.3,oddJetDistance=.5,oddSpring=age*22,oddSpringMax=22,
        oddAltitude=id=="hovercraft" and .2 or 0,oddLandingSerial=0,oddLandingBoost=0}
end
local function playerChecks(scene,id)
    local bike=Visual.NewBike(scene,id)
    owners_[#owners_+1]=bike
    local size=bike.body:GetVar("VehicleSize"):GetVector3()
    check((size-Assets.Vehicles[id].targetSize):Length()<.005,id.."实测尺寸同步碰撞")
    local canonical=assert(bike.body:GetChild("SourceTransform"))
    check(math.abs(canonical.scale.x-canonical.scale.y)<1e-6 and math.abs(canonical.scale.y-canonical.scale.z)<1e-6,id.."原车等比缩放")
    check(bike.skillEffects~=nil,id.."玩家接入独立效果")
    local cameraNode=scene:CreateChild("RealEye_"..id)
    cameraNode:SetParent(bike.visual)
    cameraNode.position=bike.Cockpit.localOffset
    cameraNode.rotation=Quaternion(bike.Cockpit.pitch,V.RIGHT)
    local camera=cameraNode:CreateComponent("Camera")
    camera.fov,camera.aspectRatio,camera.nearClip=bike.Cockpit.fov,16/9,.025
    local state=drive(id,0,"idle");state.oddActive=0
    bike:UpdateState(.02,state,true,0)
    check(bike.firstPerson and bike.body.enabled and #bike.body:GetComponents("StaticModel",true)>0,
        id.."首视角保留正式车体 fp="..tostring(bike.firstPerson).." body="..tostring(bike.body.enabled)
        .." draws="..tostring(#bike.body:GetComponents("StaticModel",true)))
    local dashboard=camera:WorldToScreenPoint(bike:GetDashboardWorldPosition())
    check(dashboard.x>0 and dashboard.x<1 and dashboard.y>0 and dashboard.y<1,id.."实际座舱仪表可投影")
    for _,sample in ipairs(phases(id)) do
        state=drive(id,sample[1],sample[2])
        bike:UpdateState(.02,state,true,sample[1])
        check(bike.skillEffects.active and bike.skillEffects.phase==sample[2],id.."真实适配器消费阶段"..sample[2])
        local visible=0
        for _,anchor in ipairs(bike.skillEffects.firstPersonAnchors) do
            local p=camera:WorldToScreenPoint(anchor.worldPosition)
            if p.x>.03 and p.x<.97 and p.y>.03 and p.y<.97 then visible=visible+1 end
        end
        check(visible==2,id.."实际眼位双侧技能锚点可见")
    end
    local transforms={}
    for _,name in ipairs(Art.GetConfig(id).joints) do transforms[name]=assert(bike.body:GetChild(name,true)).transform end
    state.paused=true
    bike:UpdateState(.8,state,true,99)
    for _,name in ipairs(Art.GetConfig(id).joints) do check(assert(bike.body:GetChild(name,true)).transform==transforms[name],id.."暂停关节冻结"..name) end
    state=drive(id,0,"idle");state.oddActive=0;state.oddSpring=0;state.speed=0;state.distance=0;state.steer=0
    bike:UpdateState(.02,state,false,1)
    check(not bike.firstPerson and not bike.skillEffects.active,id.."换视角和技能结束清理")
    check(bike.body:GetVar("FormalModel"):GetString()==Assets.Vehicles[id].model,id.."玩家使用正式MDL")
    return bike,cameraNode,camera
end
local function aiChecks(scene)
    local RV=require("RaceVisuals")
    local root=scene:CreateChild("IsolatedNewVehicleRivals")
    local racers={}
    for i,id in ipairs(Assets.NewIds) do
        racers[#racers+1]={id="fixture_"..id,vehicleId=id,colorId="red",index=i,x=i*5,y=0,z=0,
            heading=0,speed=24,steer=.35,driveSim=drive(id,.55,phases(id)[1][2])}
    end
    local visuals=setmetatable({scene=scene,root=root,rosterRoot=root:CreateChild("RaceRivals"),
        runners={},markers={},materials={},world={},race={racers=racers},clock=0,visibilityClock=0,
        highQuality=false,leanSign=1,disposed=false,visible=true,EnsurePolice=function() end},RV)
    visuals:Reset();visuals:Update(.02,{x=0,z=0})
    for _,data in ipairs(racers) do
        local runner=assert(visuals.runners[data.id])
        check(runner.body:GetVar("FormalModel"):GetString()==Assets.Vehicles[data.vehicleId].model,data.vehicleId.."AI正式模型")
        check(runner.skillEffects and runner.skillEffects.active,data.vehicleId.."AI实际接线技能效果")
        check(not runner.node:GetChild("Cockpit",true),data.vehicleId.."AI不分配玩家座舱")
        data.x=1000
    end
    visuals:Update(.02,{x=0,z=0})
    for _,runner in pairs(visuals.runners) do check(not runner.active and not runner.skillEffects.active,runner.vehicleId.."远距清理") end
    for i,data in ipairs(racers) do data.x=i*5 end
    visuals:Update(.02,{x=0,z=0})
    for _,runner in pairs(visuals.runners) do check(runner.active and runner.skillEffects.active,runner.vehicleId.."远距恢复") end
    visuals:SetVisible(false)
    for _,runner in pairs(visuals.runners) do check(not runner.skillEffects.active,runner.vehicleId.."隐藏清理") end
    visuals:Dispose();visuals:Dispose()
end
local function garageChecks(id)
    local UI=require("urhox-libs/UI")
    local preview=require("GaragePreview").New({width=800,height=500})
    preview.vehicleId,preview.active=id,true
    preview:BuildScene(id)
    local body=assert(preview.turntable:GetChild("Vehicle_"..id))
    check(body:GetVar("FormalModel"):GetString()==Assets.Vehicles[id].model,id.."车库正式模型")
    local fixed={}
    Visual.Animate(body,id,0,{oddActive=0})
    for _,name in ipairs(Art.GetConfig(id).joints) do fixed[name]=assert(body:GetChild(name,true)).transform end
    for _,yaw in ipairs({0,90,180,270,360}) do
        preview.turntable.rotation=Quaternion(0,yaw,0)
        Visual.Animate(body,id,yaw,{oddActive=0})
        for _,name in ipairs(Art.GetConfig(id).joints) do check(assert(body:GetChild(name,true)).transform==fixed[name],id.."转台360不驱动停车关节"..name) end
    end
    preview:Dispose();preview:Dispose();preview:Destroy()
end
local function run()
    local selected,view,age,measureOnly="hovercraft","iso",0,false
    for _,arg in ipairs(GetArguments()) do
        selected=arg:match("^%-new%-vehicle=(.+)$") or selected
        view=arg:match("^%-new%-view=(.+)$") or view
        age=tonumber(arg:match("^%-new%-age=(.+)$")) or age
        if arg=="-measure-only" then measureOnly=true end
    end
    for _,id in ipairs(Assets.NewIds) do
        if Assets.Vehicles[id] then
            xpcall(function()
                measure(id)
            end,function(message)
                print("[五车实测错误] "..id.." "..tostring(message))
                print(debug.traceback("",2))
                return message
            end)
        else print("[五车实测错误] 未登记 "..tostring(id)) end
    end
    if measureOnly then engine:Exit();return end
    scene_=Scene();scene_:CreateComponent("Octree")
    local group=scene_:CreateChild("LightGroup")
    group:LoadXML(assert(cache:GetResource("XMLFile","LightGroup/Daytime.xml")):GetRoot())
    local zone=group:GetComponent("Zone",true)
    if zone then zone.depthFogEnable,zone.heightFogEnable=false,false end
    local UI=require("urhox-libs/UI");UI.Init({theme="default-dark",scale=UI.Scale.DEFAULT})
    for _,id in ipairs(Assets.NewIds) do
        local bike=playerChecks(scene_,id)
        bike.node:SetEnabledRecursive(false)
        garageChecks(id)
    end
    aiChecks(scene_)
    local catalog=require("Catalog")
    local pool={};for _,id in ipairs(Assets.RaceIds()) do pool[id]=true end
    for _,id in ipairs(Assets.NewIds) do check(catalog.Get(id).available and pool[id],id.."车库开放和竞速池") end
    local bike=Visual.NewBike(scene_,selected);owners_[#owners_+1]=bike
    local sample=phases(selected)[1]
    for _,candidate in ipairs(phases(selected)) do if age>=candidate[1] then sample=candidate end end
    local state=drive(selected,age,sample[2]);if age==0 then state.oddActive=0;state.oddPhase="idle";state.oddSpring=0 end
    bike:UpdateState(.02,state,view=="first",0)
    local cameraNode=scene_:CreateChild("ReviewCamera")
    local camera=cameraNode:CreateComponent("Camera")
    camera.nearClip,camera.farClip,camera.fov=.025,100,42
    if view=="first" then
        cameraNode:SetParent(bike.visual);cameraNode.position=bike.Cockpit.localOffset
        cameraNode.rotation=Quaternion(bike.Cockpit.pitch,V.RIGHT);camera.fov=bike.Cockpit.fov
    else
        local positions={iso=V(5,3.8,-5.5),side=V(6,1.8,0),front=V(0,2,6),rear=V(0,2,-6),top=V(0,7,-.01)}
        cameraNode.position=positions[view] or positions.iso
        cameraNode:LookAt(V(0,Assets.Vehicles[selected].targetSize.y*.45,0))
    end
    renderer:SetViewport(0,Viewport:new(scene_,camera))
    print("[五车集成] PASS "..count_.." / 玩家+AI+真实车库 / 实际眼位+双视角 / 360+冻结+清理")
end
function Start()
    local ok,err=xpcall(run,function(message)
        return tostring(message).."\n"..debug.traceback("",2)
    end)
    if not ok then
        print("[五车集成错误] "..tostring(err))
        engine:Exit()
    end
end
function Stop()
    for _,owner in ipairs(owners_) do owner:Dispose() end
    owners_={}
    if scene_ then scene_:Dispose();scene_=nil end
end
