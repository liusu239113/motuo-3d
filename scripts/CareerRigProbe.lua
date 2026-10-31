-- 人物骨架隔离验收：不加载城市，不读取存档；固定动作相位与正/侧面相机。
local Rig=require("Career.Rig")
local Motion=require("Career.Locomotion")
---@type Scene?
local scene_=nil
---@type CareerRig?
local rig_=nil
function Start()
    scene_=Scene()
    scene_:CreateComponent("Octree")
    local lights=scene_:CreateChild("LightGroup")
    assert(lights:LoadXML(cache:GetResource("XMLFile","LightGroup/Daytime.xml"):GetRoot()))
    local root=scene_:CreateChild("人物验收根")
    rig_=Rig.New(root)
    local motion=Motion.New(rig_)
    local phase,speed,view,mode=0,0,"front","motion"
    for _,arg in ipairs(GetArguments()) do
        phase=tonumber(arg:match("^%-phase=([%d%.]+)$")) or phase
        speed=tonumber(arg:match("^%-speed=([%d%.]+)$")) or speed
        view=arg:match("^%-view=(%a+)$") or view
        mode=arg:match("^%-pose=(%a+)$") or mode
    end
    for _,arg in ipairs(GetArguments()) do
        if arg=="-checks" then
            require("Career.LocomotionChecks").Run({options={test=true},restoreTestStorage=function() end,
                actor={visuals={walker=rig_,locomotion=motion}}})
        end
    end
    if mode=="bind" then rig_:Reset();rig_.mesh.position=rig_.standOffset
    else motion:PoseNormalized(phase,speed) end
    for _,name in ipairs({"Hip","Pelvis","Waist","Spine01","Spine02","NeckTwist01","Head","L_Clavicle","L_Upperarm","L_Forearm","L_Hand","R_Upperarm","R_Forearm","R_Hand","L_Thigh","L_Calf","L_Foot","L_ToeBase"}) do
        local source=Motion.Mapping[name]
        local reference=source and motion.reference[source]
        print(string.format("[骨架探针] %s 目标%s 源绑定%s",name,rig_:GetBonePosition(name):ToString(),reference and reference:Translation():ToString() or "无"))
    end
    local sourcePose=motion:SampleSource(speed>=3.4 and motion.clips.run or speed>0 and motion.clips.walk or motion.clips.idle,phase*(speed>=3.4 and motion.clips.run.length or speed>0 and motion.clips.walk.length or motion.clips.idle.length))
    local sourceTorso=sourcePose["Bip001 Neck"]:Translation()-sourcePose.Bip001:Translation()
    local targetTorso=rig_:GetBonePosition("NeckTwist01")-rig_:GetBonePosition("Hip")
    print(string.format("[躯干倾角] 源%.2f 目标%.2f",math.deg(math.atan(sourceTorso.z,sourceTorso.y)),math.deg(math.atan(targetTorso.z,targetTorso.y))))
    local cameraNode=scene_:CreateChild("验收相机")
    cameraNode.position=view=="side" and Vector3(3,.95,0) or view=="threequarter" and Vector3(2,.95,2.6) or Vector3(0,.95,3.3)
    cameraNode:LookAt(Vector3(0,.88,0))
    local camera=cameraNode:CreateComponent("Camera")
    camera.fov=40;camera.farClip=50
    renderer:SetViewport(0,Viewport:new(scene_,camera))
    print(string.format("[人物隔离实拍] pose=%s speed=%.2f phase=%.3f view=%s 鞋底=%.4f/%.4f",mode,speed,phase,view,rig_:SoleHeight("L_Foot"),rig_:SoleHeight("R_Foot")))
end
