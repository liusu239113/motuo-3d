-- 接触面回归：用真实顶点和inverse bind读回，不把模型包围盒或脚踝当鞋底。
local Checks={}
---@param rig CareerRig
function Checks.SkinBounds(rig)
    ---@type table[]
    local vertices=assert(rig:ReadSkinVertices()[1])
    ---@type Matrix3x4[]
    local matrices={}
    local sk=rig.model:GetSkeleton()
    for i,name in ipairs(rig.boneNames) do
        local transform=rig:GetLocalBoneTransform(name)*sk:GetBone(name).offsetMatrix --[[@as Matrix3x4]]
        matrices[i]=transform
    end
    local bounds=BoundingBox()
    local feet={L_Foot=BoundingBox(),R_Foot=BoundingBox()}
    for _,v in ipairs(vertices) do
        local pos=Vector3.ZERO
        local x,y,z=0,0,0
        local side=""
        for k=1,4 do
            local p=matrices[v.indices[k]+1]*v.position
            local w=v.weights[k]
            x,y,z=x+p.x*w,y+p.y*w,z+p.z*w
            local name=rig.boneNames[v.indices[k]+1]
            if w>.2 and (name=="L_Foot" or name=="L_ToeBase") then side="L_Foot" end
            if w>.2 and (name=="R_Foot" or name=="R_ToeBase") then side="R_Foot" end
        end
        pos=Vector3(x,y,z);bounds:Merge(pos)
        if side~="" then feet[side]:Merge(pos) end
    end
    print(string.format("[真实蒙皮接触] 模型%s 左鞋底%.5f 右鞋底%.5f Hip%s",bounds:ToString(),feet.L_Foot.min.y,feet.R_Foot.min.y,rig:GetBonePosition("Hip"):ToString()))
    for _,c in ipairs(rig.arms) do
        print(string.format("[真实肘部] %s 肩%s 肘%s 腕%s",c.tip,rig:GetBonePosition(c.upper):ToString(),rig:GetBonePosition(c.lower):ToString(),rig:GetBonePosition(c.tip):ToString()))
    end
    return bounds,feet
end
function Checks.Run(session)
    local actor=session.actor
    actor.visuals.walker:PoseWalk(0,0)
    Checks.SkinBounds(actor.visuals.walker)
    actor.visuals.walker:PoseWalk(math.pi/2,1)
    Checks.SkinBounds(actor.visuals.walker)
    actor.visuals.mountedRider:PoseRide(0)
    Checks.SkinBounds(actor.visuals.mountedRider)
    print("[接触诊断] 地表(0,-20)="..session.city:Surface(0,-20))
    for _,arg in ipairs(GetArguments()) do
        local phase=arg:match("^%-contactphase=([%.%d]+)$")
        if phase then actor.visuals.walker:PoseWalk(tonumber(phase) or 0,1) end
    end
    actor.mounted=false;actor.visuals:SetMounted(false)
    actor.bikeX,actor.bikeZ,actor.bikeYaw=0,-17,0
    actor:Teleport(2,-20,0)
    session.yaw,session.pitch=110,2
    session.camera:SetModeConfig("normal",{distance=3.8,offset=Vector3(0,1,0),fov=52})
    session.camera:Update(1,actor.node,session.yaw,session.pitch)
    session.view:ShowGame(); session:Refresh()
    session.view:ShowDialog("接触诊断","",{});session.view.overlay:SetVisible(false)
end
return Checks
