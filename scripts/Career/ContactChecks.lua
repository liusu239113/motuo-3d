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
    for _,arg in ipairs(GetArguments()) do
        if arg=="-contactshot" then Checks.Shot(session);return end
        if arg=="-vehiclechecks" then Checks.Vehicles(session);Checks.Shot(session);return end
    end
    local actor=session.actor
    ---@type CareerRig
    local rig=actor.visuals.walker
    rig.ground=nil
    for _,weight in ipairs({0,.1,.25,.5,1}) do
        for _,run in ipairs({0,.5,1}) do
            local clamped=rig.reachClampedFrames or 0
            for i=0,31 do
                rig:PoseWalk(i*math.pi/16,weight,run)
                assert(math.abs(math.min(rig:SoleHeight("L_Foot"),rig:SoleHeight("R_Foot")))<.006,"慢走跑步支撑脚必须贴地")
            end
            assert((rig.reachClampedFrames or 0)==clamped,"各速度步态不能超伸")
        end
    end
    rig.ground=session.city
    actor.mounted=false;actor.visuals:SetMounted(false)
    actor:Teleport(0,-20,0)
    -- 身体位于人行道边缘，左右脚跨在不同高度，分别验证鞋底而不是仅查角色根。
    for _,x in ipairs({5.9,6.0,6.1,11.9,12.0,12.1}) do
        actor:Teleport(x,-20,0)
        rig:PoseWalk(0,0)
        for _,chain in ipairs(rig.legs) do
            local foot=actor.node.worldTransform*rig:GetBonePosition(chain.tip)
            local ground=session.city:Surface(foot.x,foot.z)
            assert(math.abs(rig:SoleHeight(chain.tip)+actor.node.position.y-ground)<.006,"跨路沿双脚须分别落地")
        end
    end
    for _,yaw in ipairs({0,90,180,270}) do
        local y,pitch=session.city:VehicleSurface(6,-20,yaw,.729281,-.617155)
        local rotation=Quaternion(0,yaw,0)*Quaternion(pitch,Vector3.RIGHT)
        for _,z in ipairs({-.617155,.729281}) do
            local p=Vector3(6,y,-20)+rotation*Vector3(0,0,z)
            assert(math.abs(p.y-session.city:Surface(p.x,p.z))<.001,"前后轮须分别落地")
        end
    end
    local visuals=actor.visuals
    for _,speed in ipairs({.18,.6,1.8,3.4,0}) do
        for _=1,60 do visuals:Update(1/60,speed,0,0,session.city:Surface(0,-20),-20,0) end
        if speed==3.4 then assert(visuals.runWeight>.99,"跑步应切换慢跑摆臂") end
        if speed==0 then assert(visuals.gaitWeight==0 and visuals.runWeight==0,"停止后必须完全回到站姿") end
    end
    for _,person in ipairs(session.traffic.pedestrians.people) do
        local npc=person.rig
        local clamped=npc.reachClampedFrames or 0
        for i=0,7 do
            npc:PoseWalk(i*math.pi/4,.8)
            assert(math.abs(math.min(npc:SoleHeight("L_Foot"),npc:SoleHeight("R_Foot")))<.006,"路人鞋底须贴在人行道上")
        end
        assert((npc.reachClampedFrames or 0)==clamped,"不同体型路人不可超伸")
    end
    for _,speed in ipairs({.18,.6,1.8,3.4}) do
        local w=math.sqrt(math.min(1,speed/1.8))
        local r=math.max(0,math.min(1,(speed-1.8)/1.6))
        local cycle=require("Career.Rig").CycleLength(w,r)
        rig.ground=nil
        rig:PoseWalk(.3,w,r)
        local a=rig:GetBonePosition("L_Foot")
        local travel=cycle*.08/(2*math.pi)
        rig:PoseWalk(.38,w,r)
        local b=rig:GetBonePosition("L_Foot")
        assert(math.abs((b.z-a.z)+travel)<.001,"支撑脚向后位移必须抵消前进距离")
    end
    rig.ground=nil
    print("[动态接触验收通过] 15组速度混合/八位路人/支撑脚滑移/跨路沿双脚/四方向前后轮/慢走起停与跑步切换")
    print("[阴影接触] "..tostring(session.sun.shadowBias.constantBias).."/"..tostring(session.sun.shadowBias.slopeScaledBias).."/"..tostring(session.sun.shadowBias.normalOffset))
    local clamped=actor.visuals.walker.reachClampedFrames or 0
    local hipLow,hipHigh=math.huge,-math.huge
    for i=0,63 do
        actor.visuals.walker:PoseWalk(i*math.pi/32,1)
        local y=actor.visuals.walker:GetBonePosition("Hip").y
        hipLow,hipHigh=math.min(hipLow,y),math.max(hipHigh,y)
    end
    assert(hipHigh-hipLow<.065,"步行髋部不能上下蹲跳")
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
    local front=actor.visuals.mountedRider:ReadPose()
    assert(front.leftGripError<.005 and front.rightGripError<.005,"修肘不能脱离握把")
    local Contact=require("Career.VehicleContact")
    for _,roll in ipairs({-10,-5,0,5,10}) do
        actor.visuals:SetMounted(true)
        actor.visuals:Update(1,35/3.6,roll/10,0,session.city:Surface(0,-20),-20,0)
        for _,w in ipairs(Contact.Wheels.borrowed_ebike) do
            local low=math.huge
            for _,p in ipairs(w.points) do
                local world=actor.visuals.bikeVisual.worldTransform*p --[[@as Vector3]]
                low=math.min(low,world.y-session.city:Surface(world.x,world.z))
            end
            assert(math.abs(low)<.001,"压弯前后胎底必须保持接地")
        end
    end
    Checks.Vehicles(session)
    actor.visuals:SetMounted(false)
    print("[接触验收通过] 64相位无超伸/八相位鞋底/站姿与骑姿后弯肘/握把/道路人行道公园查高/五角度压弯胎底")
    print("[接触诊断] 地表(0,-20)="..session.city:Surface(0,-20))
    Checks.Shot(session)
end
function Checks.Vehicles(session)
    local Contact=require("Career.VehicleContact")
    local Vehicles=require("Career.VehicleData")
    local ids={Vehicles.EBIKE,table.unpack(Vehicles.Ids)}
    for _,id in ipairs({"sedan","suv","truck"}) do ids[#ids+1]=id end
    local count=0
    for _,id in ipairs(ids) do
        for _,yaw in ipairs({0,45,90,180,270}) do
            for _,x in ipairs({0,6,12}) do
                for _,lean in ipairs(#Contact.Wheels[id]==2 and {-10,0,10} or {0}) do
                    local y,pitch,roll=Contact.Solve(session.city,id,x,-20,yaw,lean)
                    local rotation=Quaternion(0,yaw,0)*Quaternion(pitch,Vector3.RIGHT)*Quaternion(roll,Vector3.FORWARD)
                    local maxGap,minGap=-math.huge,math.huge
                    for _,w in ipairs(Contact.Wheels[id]) do
                        local center=rotation*Vector3(w.x,0,w.z)
                        local ground=session.city:Surface(x+center.x,-20+center.z)
                        local low=math.huge
                        for _,p in ipairs(w.points) do low=math.min(low,y+(rotation*p).y-ground) end
                        minGap,maxGap=math.min(minGap,low),math.max(maxGap,low)
                    end
                    assert(minGap>-.0001 and minGap<.001,id.."胎面不能悬空或穿地")
                    if #Contact.Wheels[id]==2 then assert(maxGap<.001,string.format("%s前后两轮都须接地 x%.1f yaw%.1f lean%.1f pitch%.5f gap%.6f",id,x,yaw,lean,pitch,maxGap)) end
                    count=count+1
                end
            end
        end
        if id~="sedan" and id~="suv" and id~="truck" then
            local entry=session.actor.visuals:EnsureVehicle(id)
            local clamped=entry.rider.reachClampedFrames or 0
            entry.rider:PoseRide(0)
            local pose=entry.rider:ReadPose()
            print(string.format("[逐车骑姿] %s 左手%.5f 右手%.5f 夹取%d",id,pose.leftGripError,pose.rightGripError,(entry.rider.reachClampedFrames or 0)-clamped))
        end
    end
    print(string.format("[逐车胎面验收通过] 13款/%d组方向路沿压弯，刚性四轮不强求不共面路沿四点全贴",count))
end
function Checks.Shot(session)
    local actor=session.actor
    local rig=actor.visuals.walker
    local phase,weight,yaw,run=0,0,110,0
    local curb=false
    local mounted=false
    local vehicle="borrowed_ebike"
    local lean=0
    for _,arg in ipairs(GetArguments()) do
        local selected=arg:match("^%-contactvehicle=([%w_]+)$")
        if selected then vehicle=selected end
        local angle=arg:match("^%-contactlean=([%-%d%.]+)$")
        if angle then lean=tonumber(angle) or 0 end
        local value=arg:match("^%-contactphase=([%.%d]+)$")
        if value then phase=tonumber(value) or 0;weight=1 end
        value=arg:match("^%-contactyaw=([%-%d%.]+)$")
        if value then yaw=tonumber(value) or 110 end
        if arg=="-contactrun" then run=1;weight=1 end
        if arg=="-contactcurb" then curb=true end
        if arg=="-contactride" then mounted=true end
    end
    actor.mounted=mounted;actor.visuals:SetMounted(mounted)
    actor.bikeX,actor.bikeZ,actor.bikeYaw=curb and 6 or 0,-17,curb and 90 or 0
    actor:Teleport(curb and 6 or mounted and 0 or 2,mounted and -17 or -20,curb and 90 or 0)
    rig.ground=session.city
    -- Teleport内部会重算Pose，受控相位必须最后应用，暂停后才可复现实拍。
    if vehicle=="sedan" or vehicle=="suv" or vehicle=="truck" then
        local Contact=require("Career.VehicleContact")
        local root=require("VehicleAssets").Add(session.scene,vehicle,nil,"distant")
        if vehicle=="truck" then Contact.CompleteTruck(root) end
        local x=curb and 6 or 0
        local y,pitch,roll=Contact.Solve(session.city,vehicle,x,-17,curb and 90 or 0,0)
        root.position=Vector3(x,y,-17)
        root.rotation=Quaternion(0,curb and 90 or 0,0)*Quaternion(pitch,Vector3.RIGHT)*Quaternion(roll,Vector3.FORWARD)
        actor.visuals:SetCityVisible(false)
        actor.visuals.walkNode:SetEnabled(false)
        actor.node.position=Vector3(x,y,-17)
    else
        actor.visuals:SetVehicle(vehicle)
        actor.visuals:Update(1,35/3.6,lean/10,actor.bikeX,session.city:Surface(actor.bikeX,actor.bikeZ),actor.bikeZ,actor.bikeYaw)
        if mounted then actor.visuals.mountedRider:PoseRide(0)
        else actor.visuals.walker:PoseWalk(phase,weight,run) end
    end
    session.yaw,session.pitch=yaw,2
    session:UpdateEnvironment(12)
    session.camera:SetModeConfig("normal",{distance=3.8,offset=Vector3(0,1,0),fov=52})
    session.camera:SetModeConfig("ride",{distance=3.8,offset=Vector3(0,1,0),fov=52})
    session.camera:Update(1,actor.node,session.yaw,session.pitch)
    session.view:ShowGame(); session:Refresh()
    session.view:ShowDialog("接触诊断","",{});session.view.overlay:SetVisible(false)
end
return Checks
