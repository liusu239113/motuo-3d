-- Isolated driver acceptance, no main/Profile/save modifications. Single contact-sheet render.
assert(cache:AddResourceDir("/workspace/assets",false))
assert(cache:AddResourceDir("/workspace/scripts",false))
local Driver=require("MixedDriver")
local Visual=require("MixedVisuals")
local V=Vector3
---@type Scene?
local scene_=nil
---@type Rider[]
local rigs_={}
local count_=0
local function check(ok,message) assert(ok,"[MixedDriverCheck] "..message);count_=count_+1 end
function Start()
    scene_=Scene();scene_:CreateComponent("Octree")
    local lg=scene_:CreateChild("LightGroup")
    lg:LoadXML(cache:GetResource("XMLFile","LightGroup/Daytime.xml"):GetRoot())
    local zone=lg:GetComponent("Zone",true)
    zone.depthFogEnable=false
    for i,id in ipairs(Driver.Ids) do
        local root=scene_:CreateChild("Check_"..id)
        local vehicle=Visual.Build(root,id)
        local ok,rig=pcall(Driver.New,root,id)
        check(ok,id.." constructor "..tostring(rig))
        check(rig~=nil,id.." no empty driver")
        ---@cast rig MixedDriver
        rigs_[#rigs_+1]=rig
        rig:ValidatePose()
        local reference=rig:ReadPose()
        for _,q in ipairs({Quaternion(0,0,0),Quaternion(-30,178,27),Quaternion(31,-179,-29)}) do
            root:SetTransform(V(1400,50,-3000),q,V.ONE)
            rig:Update(22,false,30)
            local p=rig:ReadPose()
            check((p.leftFoot-reference.leftFoot):Length()<.0001,id.." front foot inherits parent no drift")
            check((p.rightFoot-reference.rightFoot):Length()<.0001,id.." rear foot inherits parent no drift")
            check(p.poseFailures==0,id.." IK transaction success")
            rig:ValidatePose()
        end
        root:SetTransform(V.ZERO,Quaternion.IDENTITY,V.ONE)
        rig:SetVisible(false);rig:Update(-22,false,-30);rig:SetVisible(true)
        rig:ValidatePose()
        check(rig:SetColor("blue"),id.." production palette")
        rig:SetColor(i%2==0 and "yellow" or "red")
        if id=="office" then
            local swivel=vehicle:GetChild("ChairSwivel",true)
            local initial=swivel.rotation
            swivel.rotation=Quaternion(0,95,0)
            rig:Update(0)
            rig:ValidatePose()
            check(math.abs(rig.node.rotation:YawAngle())>90,"office follows true swivel")
            swivel.rotation=initial;rig:Update(0)
        end
        -- 5 columns, 2 rows in ONE scene, no repeated per-vehicle renderer launches.
        root.position=V(((i-1)%5)*3.65,0,((i-1)//5)*4.5)
        root.rotation=Quaternion(0,35,0)
        local p=rig:ReadPose()
        print(string.format("[MixedDriverCheck] %s hip=%s foot=%s/%s soleError=%.5f/%.5f handError=%.5f/%.5f head=%.3f",id,
            p.hip:ToString(),p.leftFoot:ToString(),p.rightFoot:ToString(),p.leftSoleError,p.rightSoleError,
            p.leftGripError,p.rightGripError,p.head.y))
    end
    check(not Driver.Has("tank") and not Driver.Has("helicopter") and not Driver.Has("beetle"),"protected vehicles absent")
    local cameraNode=scene_:CreateChild("Camera")
    cameraNode.position=V(7.3,15,-14)
    cameraNode:LookAt(V(7.3,.9,2.3))
    local camera=cameraNode:CreateComponent("Camera")
    camera.orthographic=true;camera.orthoSize=11.2;camera.farClip=100
    renderer:SetViewport(0,Viewport:new(scene_,camera))
    print(string.format("[MixedDriverCheck] PASS %d assertions / %d real production drivers",count_,#rigs_))
end
