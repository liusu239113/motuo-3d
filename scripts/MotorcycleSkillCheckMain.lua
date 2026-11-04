-- 基于scaffold-3d-scene的隔离验收入口。只跑技能规则、临时Scene与生产表现；不调用游戏Start/Profile/SDK。
local Checks=require("MotorcycleSkillChecks")
local Effects=require("MotorcycleSkillEffects")
local Rules=require("MixedRace")
local Data=require("MixedVehicles")
local Bike=require("Bike")
local UI=require("urhox-libs/UI")
---@type Scene?
local scene_=nil
---@type Bike?
local bike_=nil
---@type MotorcycleSkillEffects[]
local effects_={}

function Start()
    assert(Checks.Run().passed)
    assert(require("RaceAIChecks").MotorcycleSkills()>0)
    local selected,first,age,onlyRules="",false,1.1,false
    for _,arg in ipairs(GetArguments()) do
        selected=arg:match("^%-motorcycle=(.+)$") or selected
        if arg=="-helmet" then first=true end
        if arg=="-rules-only" then onlyRules=true end
        age=tonumber(arg:match("^%-skill%-age=(.+)$")) or age
    end
    if onlyRules then print("[普通摩托总验收] PASS rules + AI，无存档/SDK调用");return end
    scene_=Scene();scene_:CreateComponent("Octree")
    local group=scene_:CreateChild("LightGroup")
    group:LoadXML(assert(cache:GetResource("XMLFile","LightGroup/Daytime.xml")):GetRoot())
    local zone=group:GetComponent("Zone",true)
    if zone then zone.depthFogEnable,zone.heightFogEnable=false,false end
    assert(Checks.Visuals(scene_).passed)
    -- 唯一的静态地面来自正式内置Plane；车辆始终调用生产Bike/VehicleAssets。
    local ground=scene_:CreateChild("SkillCheckGround")
    ground.scale=Vector3(200,1,200)
    local draw=ground:CreateComponent("StaticModel")
    draw.model=assert(cache:GetResource("Model","Models/Plane.mdl"))
    draw.material=require("Parts").Material(.14,.17,.20,.9,0)
    local cameraNode=scene_:CreateChild("Camera")
    local camera=cameraNode:CreateComponent("Camera")
    camera.nearClip,camera.farClip,camera.fov=.05,300,55
    UI.Init({theme="default-dark",scale=UI.Scale.DEFAULT})
    local captions={}
    local function state(id)
        local sim={vehicleId=id,x=0,y=0,z=0,heading=0,speed=24,steer=.25,throttle=1,rpm=7000}
        Rules.Reset(sim);Rules.Before(sim,.02,{skill=true,throttle=1},{RouteLength=0})
        Rules.Before(sim,age,{}, {RouteLength=0})
        return sim
    end
    if selected~="" then
        assert(Data.GetMotorcycleSkill(selected),"未知普通车型")
        bike_=Bike.New(scene_,selected)
        local sim=state(selected)
        bike_:UpdateState(.02,sim,first,age)
        if first then
            cameraNode.position=bike_:GetCameraWorldPosition()
            cameraNode.rotation=bike_.visual.worldRotation*Quaternion(bike_.Cockpit.pitch,0,0)
            camera.fov=bike_.Cockpit.fov
        else
            cameraNode.position=Vector3(3.3,2.5,-4.2)
            cameraNode:LookAt(Vector3(0,1.0,.2))
        end
        captions[#captions+1]=UI.Label{text=selected.." / "..assert(Data.GetMotorcycleSkill(selected)).name,
            position="absolute",left=18,top=16,fontSize=18,fontColor={240,240,240,255}}
    else
        -- 受控时间的九技能图鉴：完整正式车型+只读生产效果，便于同帧比较空间轮廓。
        local Assets=require("VehicleAssets")
        for index,id in ipairs(Checks.Ids) do
            local root=scene_:CreateChild("SkillGallery_"..id)
            root.position=Vector3(((index-1)%3-1)*4.0,0,math.floor((index-1)/3)*4.5)
            Assets.Add(root,id,nil,"balanced")
            local cockpit=Bike.GetCockpit(id)
            local effect=assert(Effects.New(root,id,cockpit.localOffset.y,Assets.Vehicles[id].targetSize.z))
            effect:Update(.02,state(id));effects_[#effects_+1]=effect
            captions[#captions+1]=UI.Label{text=id.." / "..assert(Data.GetMotorcycleSkill(id)).name,
                position="absolute",left=20+((index-1)%3)*265,top=18+math.floor((index-1)/3)*24,
                fontSize=13,fontColor={238,238,238,255}}
        end
        cameraNode.position=Vector3(12,12,-12)
        cameraNode:LookAt(Vector3(0,.6,4.4));camera.fov=46
    end
    renderer:SetViewport(0,Viewport:new(scene_,camera));renderer.hdrRendering=true
    UI.SetRoot(UI.Panel{width="100%",height="100%",pointerEvents="none",children=captions})
    print("[普通摩托总验收] PASS 规则 / AI / 九种表现 / 头盔投影 / 冻结 / 清理；截图为受控年龄="..age)
end
function Stop()
    if bike_ then bike_:Dispose();bike_=nil end
    for _,effect in ipairs(effects_) do effect:Dispose() end
    effects_={}
    UI.Shutdown()
    if scene_ then scene_:Dispose();scene_=nil end
end
