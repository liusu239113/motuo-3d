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
    print("[阴影接触] "..tostring(session.sun.shadowBias.constantBias).."/"..tostring(session.sun.shadowBias.slopeScaledBias).."/"..tostring(session.sun.shadowBias.normalOffset))
    local clamped=actor.visuals.walker.reachClampedFrames or 0
    for i=0,63 do actor.visuals.walker:PoseWalk(i*math.pi/32,1) end
    assert((actor.visuals.walker.reachClampedFrames or 0)==clamped,"正常跨步不能超伸夹取")
    for _,phase in ipairs({0,math.pi/4,math.pi/2,math.pi*3/4,math.pi,math.pi*5/4,math.pi*3/2,math.pi*7/4}) do
        actor.visuals.walker:PoseWalk(phase,1)
        local _,feet=Checks.SkinBounds(actor.visuals.walker)
        assert(math.abs(math.min(feet.L_Foot.min.y,feet.R_Foot.min.y))<.006,"支撑鞋底必须贴地")
    end
    actor.visuals.walker:PoseWalk(0,0)
    Checks.SkinBounds(actor.visuals.walker)
    for _,c in ipairs(actor.visuals.walker.arms) do
        local rig=actor.visuals.walker
        assert(rig:GetBonePosition(c.lower).z<rig:GetBonePosition(c.upper).z-.03,"站姿肘部必须后弯")
    end
    actor.visuals.mountedRider:PoseRide(0)
    Checks.SkinBounds(actor.visuals.mountedRider)
    for _,c in ipairs(actor.visuals.mountedRider.arms) do
        local rig=actor.visuals.mountedRider
        local a,b,e=rig:GetBonePosition(c.upper),rig:GetBonePosition(c.tip),rig:GetBonePosition(c.lower)
        local t=(e.y-a.y)/(b.y-a.y)
        assert(e.z<a.z+(b.z-a.z)*t-.03,"骑姿肘部必须在肩腕连线后侧")
    end
    for _,p in ipairs({{0,-20,.055},{-50,-50,0},{-50,9,.069},{120,-25,.10}}) do
        assert(math.abs(session.city:Surface(p[1],p[2])-p[3])<.0001,"地表查询必须匹配视觉地面")
    end
    print("[接触诊断] 地表(0,-20)="..session.city:Surface(0,-20))
    local phase,weight,yaw=0,0,110
    local mounted=false
    for _,arg in ipairs(GetArguments()) do
        local value=arg:match("^%-contactphase=([%.%d]+)$")
        if value then phase=tonumber(value) or 0;weight=1 end
        value=arg:match("^%-contactyaw=([%-%d%.]+)$")
        if value then yaw=tonumber(value) or 110 end
        if arg=="-contactride" then mounted=true end
    end
    actor.mounted=mounted;actor.visuals:SetMounted(mounted)
    actor.bikeX,actor.bikeZ,actor.bikeYaw=0,-17,0
    actor:Teleport(mounted and 0 or 2,mounted and -17 or -20,0)
    -- Teleport内部会重算Pose，受控相位必须最后应用，暂停后才可复现实拍。
    if mounted then actor.visuals.mountedRider:PoseRide(0)
    else actor.visuals.walker:PoseWalk(phase,weight) end
    session.yaw,session.pitch=yaw,2
    session:UpdateEnvironment(12)
    session.camera:SetModeConfig("normal",{distance=3.8,offset=Vector3(0,1,0),fov=52})
    session.camera:SetModeConfig("ride",{distance=3.8,offset=Vector3(0,1,0),fov=52})
    session.camera:Update(1,actor.node,session.yaw,session.pitch)
    session.view:ShowGame(); session:Refresh()
    session.view:ShowDialog("接触诊断","",{});session.view.overlay:SetVisible(false)
end
return Checks
