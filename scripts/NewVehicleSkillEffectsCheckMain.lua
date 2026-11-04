-- 隔离验收：沿用 scaffold-3d-scene 的 Scene/Camera/Viewport 生命周期，不启动游戏/档案/SDK。
-- 直接运行 NewVehicleSkillEffectsCheckMain.lua；可加 -fx-id=loader -fx-age=.5 -fx-first 查看受控姿态。
local Effects=require("NewVehicleSkillEffects")
local Data=require("MixedVehicles")
local V=Vector3
---@type Scene?
local scene_=nil
---@type NewVehicleSkillEffects[]
local retained_={}
local count_=0
local function check(ok,message)
    assert(ok,"[NewVehicleSkillEffects] "..message)
    count_=count_+1
end
local PHASES={
    hovercraft={{.1,"side_jet"},{1.1,"side_jet"}},
    centipede={{.2,"tail_windup"},{.55,"tail_sweep"},{1.1,"tail_recover"}},
    buggy={{.1,"dash"},{1.1,"dash"}},
    loader={{.1,"scoop_windup"},{.5,"scoop_lift"},{.9,"scoop_release"},{1.2,"scoop_recover"}},
    cicada={{.1,"wound_release"},{.8,"wound_release"}},
}
local IDS={"hovercraft","centipede","buggy","loader","cicada"}
local function state(id,age,phase)
    local vehicle=assert(Data.Get(id))
    return {vehicleId=id,oddActive=math.max(.02,vehicle.duration-age),oddPhase=phase,oddAge=age,
        oddSerial=1,oddHitSerial=0,oddJetSide=1,oddJetLateralSpeed=2.3,oddDashSide=1,
        oddSpring=age*22,oddSpringMax=22,oddLandingSerial=0,oddLandingBoost=0,
        speed=24,steer=.4,oddAltitude=0,airborne=false}
end
-- Proxy rejects even writes to existing fields; effects may never mutate simulation.
local function readonly(values)
    return setmetatable({}, {__index=values,__newindex=function(_,key) error("sim write: "..tostring(key)) end})
end
local function number(value)
    return string.format("%.6f",value or 0)
end
local function vector(value)
    return number(value.x)..","..number(value.y)..","..number(value.z)
end
local function quaternion(value)
    return number(value.x)..","..number(value.y)..","..number(value.z)..","..number(value.w)
end
local function color(value)
    return number(value.r)..","..number(value.g)..","..number(value.b)..","..number(value.a)
end
local function pose(effect)
    local result={effect.phase,number(effect.amount),number(effect.hitFlash),tostring(effect.root.enabled)}
    for _,part in ipairs(effect.parts) do
        local n=part.node
        result[#result+1]=vector(n.position).."/"..quaternion(n.rotation).."/"..vector(n.scale).."/"..tostring(n.enabled)
    end
    for _,mat in ipairs(effect.materials) do
        result[#result+1]=color(mat:GetShaderParameter("MatDiffColor"):GetColor())
        result[#result+1]=color(mat:GetShaderParameter("MatEmissiveColor"):GetColor())
    end
    return table.concat(result,"|")
end
---@param scene Scene
local function runChecks(scene)
    local signatures={}
    local parent=scene:CreateChild("IndependentEffectChecks",LOCAL)
    local children=parent:GetNumChildren()
    check(Effects.New(parent,"sport",1.8,3)==nil,"unknown id rejected")
    check(parent:GetNumChildren()==children,"unknown id allocates nothing")
    for _,id in ipairs(IDS) do
        local vehicle=assert(Data.Get(id))
        local eye=vehicle.size[2]+.25
        local fullCount=0
        for _,lightweight in ipairs({false,true}) do
            local effect=assert(Effects.New(parent,id,eye,vehicle.size[3],lightweight))
            check(not effect.active and not effect.root.enabled,id.." initial hidden")
            if not lightweight then
                fullCount=#effect.parts
                check(not signatures[effect.signature],id.." unique silhouette")
                signatures[effect.signature]=true
            else check(#effect.parts<fullCount,id.." lightweight pool smaller") end
            local poolCount=effect.root:GetNumChildren(true)
            effect:Update(.02,readonly({speed=0,oddActive=0,oddPhase="wound",oddSpring=22}))
            check(not effect.active and not effect.root.enabled,id.." parked idle hidden")
            local before=""
            for _,sample in ipairs(PHASES[id]) do
                local sim=state(id,sample[1],sample[2])
                effect:Update(.02,readonly(sim))
                check(effect.active and effect.amount>0 and effect.phase==sample[2],id.." phase "..sample[2])
                local visibleFront=0
                for _,part in ipairs(effect.parts) do
                    if part.group=="front" and part.node.enabled then visibleFront=visibleFront+1 end
                end
                check(visibleFront>0,id.." front effect visible")
                local current=pose(effect)
                if before~="" then check(before~=current,id.." age changes pose") end
                before=current
                effect:Update(0,readonly({oddActive=0,oddAge=999,oddHitSerial=99}))
                check(current==pose(effect),id.." dt zero freezes pose/material/state")
                effect:Update(.5,readonly({paused=true,oddActive=0,oddAge=999}))
                check(current==pose(effect),id.." paused freezes pose/material/state")
            end
            if id=="centipede" or id=="loader" then
                local sim=state(id,.5,id=="centipede" and "tail_sweep" or "scoop_lift")
                effect:Update(.02,readonly(sim))
                check(effect.hitFlash==0,id.." no invented hit")
                sim.oddHitSerial=1;effect:Update(.02,readonly(sim))
                check(effect.hitFlash>0,id.." real hit observed")
                effect:Update(.25,readonly(sim))
                check(effect.hitFlash==0,id.." same hit not retriggered")
            elseif id=="hovercraft" then
                local sim=state(id,.4,"side_jet")
                sim.oddJetSide=-1;effect:Update(.02,readonly(sim))
                check(effect.parts[1].node.position.x>0 and effect.frontAnchor.position.x>0,"jet opposite left dodge")
                sim.oddJetSide=1;effect:Update(.02,readonly(sim))
                check(effect.parts[1].node.position.x<0 and effect.frontAnchor.position.x<0,"jet opposite right dodge")
            elseif id=="buggy" then
                effect:Update(.02,readonly({oddActive=0,oddPhase="landing_boost",oddLandingBoost=.5,oddLandingSerial=1,speed=24}))
                check(effect.active,"landing boost has effect")
                effect:Update(.02,readonly({oddActive=0,oddPhase="landing_boost",oddLandingBoost=.5,speed=0}))
                check(not effect.active,"parked landing boost hidden")
                local sim=state(id,.5,"dash");sim.airborne=true
                effect:Update(.02,readonly(sim))
                for _,part in ipairs(effect.parts) do
                    if part.group=="particle" then check(not part.node.enabled,"airborne wheel smoke disabled") end
                end
            end
            check(effect.root:GetNumChildren(true)==poolCount,id.." fixed node pool")
            local cameraNode=parent:CreateChild("ProjectionCamera",LOCAL)
            cameraNode.position=V(0,eye,vehicle.size[3]*.06)
            cameraNode.rotation=Quaternion(4,0,0)
            local camera=cameraNode:CreateComponent("Camera");camera.fov=74;camera.aspectRatio=16/9
            effect:Update(.02,readonly(state(id,.5,PHASES[id][1][2])))
            for _,anchor in ipairs(effect.firstPersonAnchors) do
                local projected=camera:WorldToScreenPoint(anchor.worldPosition)
                check(projected.x>.05 and projected.x<.95 and projected.y>.05 and projected.y<.95,id.." first person anchor projection")
                check(math.abs(anchor.worldPosition.x)>.5,id.." central corridor open")
            end
            cameraNode:Dispose()
            effect:Update(.02,readonly({oddActive=0,oddPhase="idle",oddSpring=22,speed=0}))
            check(not effect.active and not effect.root.enabled,id.." end hides all")
            effect:Update(.02,readonly(state(id,.3,PHASES[id][1][2])))
            effect:Reset();check(not effect.active and effect.lastSerial==0,id.." reset clears history")
            effect:Update(.02,readonly(state(id,.3,PHASES[id][1][2])))
            effect:Update(0,readonly({finished=true,paused=true}))
            check(not effect.active and not effect.root.enabled,id.." terminal cleanup while paused")
            effect:Dispose();effect:Dispose();effect:Update(.02,{})
            check(effect.disposed and #effect.parts==0 and #effect.materials==0,id.." dispose idempotent")
        end
    end
    -- All module-shared meshes have now been released; recreation must remain safe.
    local fresh=assert(Effects.New(parent,"cicada",1.75,2.8))
    fresh:Update(.02,readonly(state("cicada",.4,"wound_release")))
    check(fresh.active,"recreate after shared mesh release")
    fresh:Dispose();parent:Dispose()
    print("[NewVehicleSkillEffects] PASS "..count_.." assertions / five IDs / phase contract / read-only / pause / anchors / cleanup")
end
function Start()
    scene_=Scene();scene_:CreateComponent("Octree")
    runChecks(scene_)
    local selected,age,first="",.55,false
    for _,arg in ipairs(GetArguments()) do
        selected=arg:match("^%-fx%-id=(.+)$") or selected
        age=tonumber(arg:match("^%-fx%-age=(.+)$")) or age
        if arg=="-fx-first" then first=true end
    end
    local cameraNode=scene_:CreateChild("Camera",LOCAL)
    local camera=cameraNode:CreateComponent("Camera");camera.nearClip=.05;camera.farClip=100;camera.fov=65
    local light=scene_:CreateChild("LightGroup",LOCAL)
    light:LoadXML(assert(cache:GetResource("XMLFile","LightGroup/Daytime.xml")):GetRoot())
    for i,id in ipairs(IDS) do
        if selected=="" or selected==id then
            local vehicle=assert(Data.Get(id))
            local root=scene_:CreateChild("Gallery_"..id,LOCAL)
            root.position=selected=="" and V((i-3)*4.5,0,0) or V.ZERO
            local eye=vehicle.size[2]+.25
            local effect=assert(Effects.New(root,id,eye,vehicle.size[3]))
            local phase=PHASES[id][1][2]
            for _,sample in ipairs(PHASES[id]) do if age>=sample[1] then phase=sample[2] end end
            effect:Update(.02,state(id,age,phase));retained_[#retained_+1]=effect
            if first then
                cameraNode.position=V(0,eye,vehicle.size[3]*.06)
                cameraNode.rotation=Quaternion(4,0,0);camera.fov=74
            end
        end
    end
    if not first then cameraNode.position=V(0,8,-13);cameraNode:LookAt(V(0,.8,0)) end
    renderer:SetViewport(0,Viewport:new(scene_,camera))
    if #GetArguments()==0 then engine:Exit() end
end
function Stop()
    for _,effect in ipairs(retained_) do effect:Dispose() end
    retained_={}
    if scene_ then scene_:Dispose();scene_=nil end
end
