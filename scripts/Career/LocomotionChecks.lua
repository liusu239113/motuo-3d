-- 真实官动采样验收。CPU断言不是视觉通过；Shot固定相位供独立8相位侧/正面实拍。
local Locomotion=require("Career.Locomotion")
local Checks={}
local function requireTest(session)
    assert(session.options and session.options.test==true and type(session.restoreTestStorage)=="function",
        "官方动画检查/摄影只允许隔离test storage，不能操作生产人物/存档")
end
---@param rig CareerRig
local function measure(rig)
    local height=1.76
    local hip=rig:GetBonePosition("Hip")
    local leftKnee,rightKnee=rig:GetBonePosition("L_Calf"),rig:GetBonePosition("R_Calf")
    local leftSole,rightSole=rig:SoleHeight("L_Foot"),rig:SoleHeight("R_Foot")
    return {hip=hip.y,height=height,hipRatio=hip.y/height,leftKnee=leftKnee.y,rightKnee=rightKnee.y,
        leftKneeRatio=leftKnee.y/height,rightKneeRatio=rightKnee.y/height,leftSole=leftSole,rightSole=rightSole,
        leftContact=leftSole<.018,rightContact=rightSole<.018}
end
-- 同一插值时刻，分别走原始97骨与24骨祖先闭包，直接比较仿射矩阵所有列。
-- 全部映射矩阵、髋位移及脚净空须相同；不是只比较最后截图或包围盒。
---@param motion CareerLocomotion
local function compareSourceSampling(motion)
    assert(#motion.allBones==97 and #motion.bones==24,"源骨闭包数量必须保持97->24")
    local report={samples=0,matrices=0,maxMatrixError=0,maxHipError=0,maxClearanceError=0}
    local probes={Vector3.ZERO,Vector3.RIGHT,Vector3.UP,Vector3.FORWARD}
    for _,name in ipairs({"idle","walk","run"}) do
        local clip=motion.clips[name]
        for phase=0,31 do
            local time=phase/32*clip.length
            local complete=motion:SampleSource(clip,time,true)
            local cropped=motion:SampleSource(clip,time)
            local count=0
            for _,source in pairs(Locomotion.Mapping) do
                count=count+1
                for _,point in ipairs(probes) do
                    local a=complete[source]*point
                    local b=cropped[source]*point
                    local error=(a-b):Length()
                    report.maxMatrixError=math.max(report.maxMatrixError,error)
                    assert(error<.0000001,"裁剪祖先闭包不能改变源矩阵: "..name.."/"..source)
                end
                report.matrices=report.matrices+1
            end
            assert(count==23,"官方动作必须保持23映射")
            local hipError=(complete.Bip001:Translation()-cropped.Bip001:Translation()):Length()
            local clearanceError=math.abs(motion:SourceClearance(complete)-motion:SourceClearance(cropped))
            report.maxHipError=math.max(report.maxHipError,hipError)
            report.maxClearanceError=math.max(report.maxClearanceError,clearanceError)
            assert(hipError<.0000001 and clearanceError<.0000001,"源骨裁剪不能改变髋位移/脚净空")
            report.samples=report.samples+1
        end
    end
    assert(report.samples==96 and report.matrices==2208,"源采样等价回归必须覆盖三动作32相位全部映射")
    return report
end
-- 独立旧路径：递归只调用自身，不能调用Rider.GetLocalBoneTransform（其递归会动态派发回新Rig）。
-- 保留旧路径每层重新GetSkeleton/GetBone、节点读取顺序以及矩阵乘法括号。
---@param rig CareerRig
---@param name string
---@return Matrix3x4
local function originalTransform(rig,name)
    local bind=rig.bind[name] --[[@as RiderBindPose]]
    local bone=rig.model:GetSkeleton():GetBone(name)
    assert(bone and bone.node,"Rider skeleton missing bone: "..name)
    local transform=bone.node.transform --[[@as Matrix3x4]]
    ---@type string?
    local parent=bind.parentName
    if parent then return originalTransform(rig,parent)*transform end
    return rig.node.transform*rig.mesh.transform*transform
end
-- 原鞋底循环与原FK，独立于新helper/祖先矩阵表；完整/去重列表均可对照。
---@param rig CareerRig
---@param name string
---@param complete? boolean
---@return number, table<string, Matrix3x4>
local function originalSole(rig,name,complete)
    ---@type table<string, Matrix3x4>
    local matrices={}
    local lowest=math.huge
    local vertices=complete and rig.fullSoleVertices[name] or rig.soleVertices[name]
    for _,v in ipairs(vertices) do
        local y=0
        for k=1,4 do
            if v.weights[k]>0 then
                local boneName=tostring(rig.boneNames[v.indices[k]+1])
                local m=matrices[boneName]
                if not m then
                    m=originalTransform(rig,boneName)*rig.model:GetSkeleton():GetBone(boneName).offsetMatrix --[[@as Matrix3x4]]
                    matrices[boneName]=m
                end
                y=y+(m*v.position).y*v.weights[k]
            end
        end
        lowest=math.min(lowest,y)
    end
    return lowest,matrices
end
local matrixFields={"m00","m01","m02","m03","m10","m11","m12","m13","m20","m21","m22","m23"}
---@param a Matrix3x4
---@param b Matrix3x4
---@param name string
local function exactMatrix(a,b,name)
    for _,field in ipairs(matrixFields) do
        -- 逐12元素完全相同，不以轴探针/epsilon隐藏乘法重结合或旧矩阵。
        assert(a[field]==b[field],"局部FK/蒙皮矩阵必须逐元素精确等价: "..name.."/"..field)
    end
end
-- 只在隔离检查里显式调用优化入口，不依赖给生产实例写同名方法的动态派发。
-- Rig:SoleHeight内部的localBoneTransform不经公开方法，计数仅代表公开FK输出/鞋底输出及实际蒙皮矩阵。
-- 骑姿IK中间公开查询另用测试代理接线并断言命中；官动内部查询不宣称全部截获。
---@param rig CareerRig
local function instrumentQueries(rig)
    ---@type fun(self:CareerRig,name:string):Matrix3x4
    local optimizedGet=rig.GetLocalBoneTransform
    ---@type fun(self:CareerRig,name:string,complete?:boolean,inspect?:boolean):(number,table<string,Matrix3x4>?)
    local optimizedSole=rig.SoleHeight
    local report={queries=0,soles=0,skinMatrices=0,ridePoses=0,poseMatrices=0,mutationMatrices=0,referenceMatrices=0,referenceSoles=0}
    ---@param self CareerRig
    ---@param name string
    ---@param label? string
    ---@return Matrix3x4
    local function observeTransform(self,name,label)
        local actual=optimizedGet(self,name)
        exactMatrix(actual,originalTransform(self,name),label or name)
        report.queries=report.queries+1
        return actual
    end
    ---@param self CareerRig
    ---@param name string
    ---@param complete? boolean
    ---@return number
    local function observeSole(self,name,complete)
        local actual,matrices=optimizedSole(self,name,complete,true)
        local expected,oldMatrices=originalSole(self,name,complete)
        local used=assert(matrices)
        assert(actual==expected,"原FK鞋底与查询内缓存鞋底必须精确相同: "..name)
        for bone,m in pairs(oldMatrices) do
            exactMatrix(assert(used[bone]),m,name.."/"..bone)
            report.skinMatrices=report.skinMatrices+1
        end
        for bone in pairs(used) do assert(oldMatrices[bone],"鞋底蒙皮影响骨集合改变") end
        report.soles=report.soles+1
        return actual
    end
    return report,observeTransform,observeSole
end
-- 完整骑姿A/B：原FK驱动所有IK vs 新FK驱动所有IK，再比较全部骨矩阵/双鞋底。
-- 连续转向、父节点远坐标/旋转/非均匀缩放；另改Rig根/mesh TRS/单骨旋转后立即重查。
---@param rig CareerRig
---@param report table
---@param observeTransform fun(self:CareerRig,name:string,label?:string):Matrix3x4
---@param observeSole fun(self:CareerRig,name:string,complete?:boolean):number
local function compareRideQueries(rig,report,observeTransform,observeSole)
    local previousGet=rawget(rig,"GetLocalBoneTransform")
    local oldPoseQueries,newPoseQueries=0,0
    local parentPosition,parentRotation,parentScale=rig.parent.position,Quaternion(rig.parent.rotation),rig.parent.scale
    local nodePosition,nodeRotation,nodeScale=rig.node.position,Quaternion(rig.node.rotation),rig.node.scale
    local meshPosition,meshRotation,meshScale=rig.mesh.position,Quaternion(rig.mesh.rotation),rig.mesh.scale
    local steer,lean=rig.lastSteer,rig.lastLean
    local ok,err=pcall(function()
        for i=0,31 do
            local angle=math.sin(i*.71)*35
            rig.lastLean=math.sin(i*.43)*55
            rig.parent:SetTransform(i%2==0 and Vector3(1400,42,-3100) or Vector3(-12000,350,8500),
                Quaternion(math.cos(i*.31)*35,i*137,rig.lastLean),Vector3(1.03,.97,1.01))
            rawset(rig,"GetLocalBoneTransform",originalTransform)
            ---@param self CareerRig
            ---@param name string
            local function legacyGet(self,name)
                oldPoseQueries=oldPoseQueries+1
                return originalTransform(self,name)
            end
            rawset(rig,"GetLocalBoneTransform",legacyGet)
            rig:PoseRide(angle)
            rawset(rig,"GetLocalBoneTransform",originalTransform)
            ---@type table<string, Matrix3x4>
            local expected={}
            for _,name in ipairs(rig.boneNames) do
                expected[name]=originalTransform(rig,name)
                report.referenceMatrices=report.referenceMatrices+1
            end
            local left=originalSole(rig,"L_Foot",true)
            local right=originalSole(rig,"R_Foot",true)
            report.referenceSoles=report.referenceSoles+2
            ---@param self CareerRig
            ---@param name string
            local function checkedGet(self,name)
                newPoseQueries=newPoseQueries+1
                return observeTransform(self,name,"ride/IK/"..name)
            end
            rawset(rig,"GetLocalBoneTransform",checkedGet)
            rig:PoseRide(angle)
            rawset(rig,"GetLocalBoneTransform",previousGet)
            for _,name in ipairs(rig.boneNames) do
                local actual=observeTransform(rig,name,"ride/"..name)
                exactMatrix(actual,expected[name],"ride/A-B/"..name)
                report.poseMatrices=report.poseMatrices+1
            end
            local leftActual=observeSole(rig,"L_Foot",true)
            local rightActual=observeSole(rig,"R_Foot",true)
            assert(leftActual==left and rightActual==right,
                "骑姿原/新IK的完整鞋底必须精确相同")
            report.ridePoses=report.ridePoses+1
        end
        -- 不允许只对最终稳定姿态自证；祖先/mesh/根改变后要马上命中新数据。
        rig.node:SetTransform(Vector3(.07,.02,-.03),Quaternion(7,19,-11),Vector3(.98,1.02,1.01))
        rig.mesh:SetTransform(rig.mesh.position+Vector3(.02,-.01,.03),Quaternion(3,-5,2)*meshRotation,meshScale)
        for _,name in ipairs({"Hip","Waist","L_Thigh","L_Calf","L_Foot","R_Thigh","R_Calf","R_Foot"}) do
            local bone=rig.model:GetSkeleton():GetBone(name)
            bone.node.rotation=Quaternion(7,-4,3)*bone.node.rotation
            for _,target in ipairs(rig.boneNames) do
                observeTransform(rig,target,"mutation/"..name.."/"..target)
                report.mutationMatrices=report.mutationMatrices+1
            end
            observeSole(rig,"L_Foot");observeSole(rig,"R_Foot")
        end
    end)
    rawset(rig,"GetLocalBoneTransform",previousGet)
    rig.parent:SetTransform(parentPosition,parentRotation,parentScale)
    rig.node:SetTransform(nodePosition,nodeRotation,nodeScale)
    rig.mesh:SetTransform(meshPosition,meshRotation,meshScale)
    rig.lastSteer,rig.lastLean=steer,lean
    report.legacyPoseDispatchQueries=oldPoseQueries
    report.optimizedPoseDispatchQueries=newPoseQueries
    assert(ok,tostring(err))
end
---@param session table
function Checks.Run(session)
    requireTest(session)
    local visuals=session.actor.visuals
    ---@type CareerRig
    local rig=visuals.walker
    ---@type CareerLocomotion
    local motion=visuals.locomotion
    local saved={phase=motion.phase,idleTime=motion.idleTime,speed=motion.speed,moving=motion.moving,running=motion.running,paused=motion.paused,ground=rig.ground}
    local report={poses=0,maxLengthError=0,minWalkHip=math.huge,maxWalkHip=-math.huge,minRunHip=math.huge,maxRunHip=-math.huge,
        flight=0,leftContacts=0,rightContacts=0,official=true,soleComparisons=0,maxSoleEquivalenceError=0}
    local queryReport,observeTransform,observeSole=instrumentQueries(rig)
    local ok,err=pcall(function()
        rig.ground=nil
        compareRideQueries(rig,queryReport,observeTransform,observeSole)
        assert(queryReport.ridePoses==32 and queryReport.poseMatrices==32*#rig.boneNames
            and queryReport.mutationMatrices==8*#rig.boneNames,
            "骑姿须覆盖32连续转向与8次单骨变更后的全部FK/矩阵输出")
        assert(queryReport.queries==queryReport.poseMatrices+queryReport.mutationMatrices+queryReport.optimizedPoseDispatchQueries
            and queryReport.soles==80 and queryReport.skinMatrices>0,
            "优化FK/鞋底观测必须具有非零公开输出及实际蒙皮矩阵覆盖")
        assert(queryReport.referenceMatrices==32*#rig.boneNames and queryReport.referenceSoles==64,
            "原始骑姿A/B必须确实运行并覆盖完整骨骼/双鞋底")
        assert(queryReport.legacyPoseDispatchQueries>0 and queryReport.optimizedPoseDispatchQueries>0,
            "原始与优化骑姿IK内部FK方法派发必须均有非零覆盖")
        assert(motion.clips.idle.animation.numTracks==97 and motion.clips.walk.animation.numTracks==98 and motion.clips.run.animation.numTracks==88,"官方资源版本/轨道不符，必须重新检查兼容性")
        assert(motion.clips.idle.keyframes==4947 and motion.clips.walk.keyframes==3626 and motion.clips.run.keyframes==2200,"不能用静态pose冒充官动关键帧")
        ---@type {position:Vector3,indices:integer[],weights:number[]}[][]
        local complete=rig:ReadSkinVertices()
        ---@type {position:Vector3,indices:integer[],weights:number[]}[][]
        local selected=rig:ReadSkinVertices(0)
        assert(#selected==1 and #complete==rig.model:GetModel():GetNumGeometryLodLevels(0)
            and #selected[1]==#complete[1],"指定LOD读取丢失顶点或默认不再返回全部LOD")
        local completeLod=assert(complete[1])
        local selectedLod=assert(selected[1])
        for i,v in ipairs(completeLod) do
            local chosen=selectedLod[i]
            assert((v.position-chosen.position):Length()<1e-9,"LOD0位置读取改变")
            for slot=1,4 do
                assert(v.indices[slot]==chosen.indices[slot] and v.weights[slot]==chosen.weights[slot],"LOD0蒙皮权重或骨索引改变")
            end
        end
        print(string.format("[初始化LOD读取检查] PASS 默认%d档/仅LOD0 %d顶点/逐点位置权重索引一致",#complete,#selected[1]))
        report.sourceEquivalence=compareSourceSampling(motion)
        for _,name in ipairs({"L_Foot","R_Foot"}) do
            assert(#rig.fullSoleVertices[name]>0 and #rig.soleVertices[name]>0,"当前模型必须有实际鞋部蒙皮顶点")
            assert(#rig.soleVertices[name]<=#rig.fullSoleVertices[name],"精确去重不能添加鞋顶点")
        end
        -- 源绑定输入时，手和前臂必须使用相同参考校准，不能产生额外折腕。
        for _,side in ipairs({"L_","R_"}) do
            local forearm,hand=side.."Forearm",side.."Hand"
            local sourceForearm="Bip001 "..side:sub(1,1).." Forearm"
            local sourceHand="Bip001 "..side:sub(1,1).." Hand"
            local a=motion.reference[sourceForearm]:Rotation()*motion.corrections[forearm]
            local b=motion.reference[sourceHand]:Rotation()*motion.corrections[hand]
            local localWrist=a:Inverse()*b
            for _,axis in ipairs({Vector3.RIGHT,Vector3.UP,Vector3.FORWARD}) do
                assert((localWrist*axis-rig.bind[hand].rotation*axis):Length()<.00002,"手腕校准必须与前臂一致")
            end
        end
        motion.paused=false
        for _,speed in ipairs({0,.6,1.8,2.6,3.4}) do
            local firstHand=Vector3.ZERO
            local handTravel=0
            for i=0,31 do
                motion:PoseNormalized(i/32,speed)
                local data=measure(rig)
                local torso=rig:GetBonePosition("NeckTwist01")-rig:GetBonePosition("Hip")
                local pitch=math.deg(math.atan(torso.z,torso.y))
                assert(pitch<=6+8*motion.running+.02 and pitch>=-6.02,"自然站走跑不能前趴或后仰")
                for _,chain in ipairs(rig.arms) do
                    local direction=(rig:GetBonePosition(chain.lower)-rig:GetBonePosition(chain.upper)):Normalized()
                    local swing=math.deg(math.atan(direction.z,-direction.y))
                    local lateral=math.deg(math.atan(direction.x*chain.side,math.sqrt(direction.y*direction.y+direction.z*direction.z)))
                    assert(swing>=-42.02 and swing<=38.02,"肘部不能抬到肩高后摆")
                    assert(lateral>=1.98 and lateral<=8+4*motion.running+.02,"站姿与摆臂不能横向架开")
                end
                for _,name in ipairs({"L_Foot","R_Foot"}) do
                    local original=rig:SoleHeight(name,true)
                    local deduplicated=rig:SoleHeight(name)
                    local error=math.abs(original-deduplicated)
                    report.maxSoleEquivalenceError=math.max(report.maxSoleEquivalenceError,error)
                    report.soleComparisons=report.soleComparisons+1
                    assert(error<.0000001,"精确去重不得改变真实鞋底最小值: "..name)
                end
                assert(data.leftSole>-.001 and data.rightSole>-.001,"真实鞋底不可穿地")
                if speed==0 or speed==1.8 then
                    assert(math.min(data.leftSole,data.rightSole)<.025,"Idle/Walk支撑鞋不应悬空")
                end
                if speed==1.8 then
                    report.minWalkHip=math.min(report.minWalkHip,data.hip)
                    report.maxWalkHip=math.max(report.maxWalkHip,data.hip)
                    assert(data.hipRatio>.40,"Walk不可整程半蹲；先检查源根单位/绑定轴")
                end
                if speed==3.4 then
                    report.minRunHip=math.min(report.minRunHip,data.hip)
                    report.maxRunHip=math.max(report.maxRunHip,data.hip)
                    assert(data.hipRatio>.36,"Run髋高异常，不能用IK掩盖重定向错误")
                    if data.leftSole>.025 and data.rightSole>.025 then report.flight=report.flight+1 end
                    if data.leftContact then report.leftContacts=report.leftContacts+1 end
                    if data.rightContact then report.rightContacts=report.rightContacts+1 end
                end
                for _,chains in ipairs({rig.legs,rig.arms}) do
                    for _,chain in ipairs(chains) do
                        local a,b,c=rig:GetBonePosition(chain.upper),rig:GetBonePosition(chain.lower),rig:GetBonePosition(chain.tip)
                        local error=math.max(math.abs((b-a):Length()-chain.lengthA),math.abs((c-b):Length()-chain.lengthB))
                        report.maxLengthError=math.max(report.maxLengthError,error)
                        assert(error<.00004,"官动重定向不得改变原始骨长: "..chain.tip)
                    end
                end
                for _,name in ipairs(rig.boneNames) do
                    local bone=rig.model:GetSkeleton():GetBone(name)
                    assert((bone.node.position-rig.bind[name].position):Length()<.000001,"不得复制源位移拉长骨骼")
                    assert((bone.node.scale-rig.bind[name].scale):Length()<.000001,"不得复制源缩放改变骨长")
                    assert(not bone.node.rotation:IsNaN(),"重定向不能产生NaN")
                end
                local hand=rig:GetBonePosition("L_Hand")
                if i==0 then firstHand=hand else handTravel=math.max(handTravel,(hand-firstHand):Length()) end
                if i%4==0 then
                    print(string.format("[官动相位] speed%.2f phase%.3f hip%.3fm/%.3fh kneeL/R%.3f/%.3fm soleL/R%.4f/%.4fm contact%s/%s",
                        speed,i/32,data.hip,data.hipRatio,data.leftKnee,data.rightKnee,data.leftSole,data.rightSole,tostring(data.leftContact),tostring(data.rightContact)))
                end
                report.poses=report.poses+1
            end
            if speed>=1.8 then assert(handTravel>.12,"真实clip不同相位必须有可观测摆臂，不以load成功验收") end
        end
        assert(report.soleComparisons==320,"原完整鞋与精确去重鞋必须覆盖160姿态双脚")
        assert(report.flight>0 and report.leftContacts>0 and report.rightContacts>0,"Run必须有双侧支撑及原clip腾空，而非原地蹲跳")
        assert(report.maxWalkHip-report.minWalkHip<.10,"Walk不可上下蹲跳")
        motion:Reset()
        motion:Update(.1,0,.06)
        assert(motion.phase>0,"必须使用整帧真实距离，不能吞末子步撞墙前的位移")
        local stoppedPhase=motion.phase
        motion:Update(.1,3.4,0)
        assert(motion.phase==stoppedPhase,"撞墙没有真实位移时不可踏步")
        motion:PoseNormalized(.31,3.4)
        motion:SetPaused(true)
        local phase,idleTime,moving,running=motion.phase,motion.idleTime,motion.moving,motion.running
        local hand=rig:GetBonePosition("L_Hand")
        motion:Update(.5,3.4,1.7)
        assert(motion.phase==phase and motion.idleTime==idleTime and motion.moving==moving and motion.running==running,"暂停必须冻结全部时间/混合权重")
        assert((hand-rig:GetBonePosition("L_Hand")):Length()<.000001,"暂停必须冻结真实骨骼")
        motion:SetPaused(false)
        motion:Update(0,0,0)
        assert(motion.phase==phase,"dt0不可推进动画")
        for _=1,30 do motion:Update(1/60,0,0) end
        assert(motion.moving==0 and motion.running==0,"停止后必须完整混回官方Idle")
    end)
    report.queryEquivalence=queryReport
    rig.ground=saved.ground
    motion.phase,motion.idleTime,motion.speed,motion.moving,motion.running,motion.paused=saved.phase,saved.idleTime,saved.speed,saved.moving,saved.running,saved.paused
    motion:Evaluate()
    visuals.phase,visuals.gaitWeight,visuals.runWeight=motion.phase*math.pi*2,motion.moving,motion.running
    assert(ok,tostring(err))
    print(string.format("[目标FK查询内复用等价] PASS %d公开FK/%d公开鞋底/%d实际蒙皮矩阵；骑姿%d/骑姿及变更矩阵%d；内部FK派发原/新%d/%d；12元素/鞋底精确相等；局部helper内部调用不计数",
        queryReport.queries,queryReport.soles,queryReport.skinMatrices,queryReport.ridePoses,queryReport.poseMatrices,
        queryReport.legacyPoseDispatchQueries,queryReport.optimizedPoseDispatchQueries))
    local equivalence=assert(report.sourceEquivalence)
    print(string.format("[官动精确缓存等价] PASS 源97->24骨 %d采样/%d映射矩阵，矩阵误差%.9g 髋误差%.9g 净空误差%.9g；鞋%d/%d->%d/%d顶点，%d鞋底对照最大误差%.9g",
        equivalence.samples,equivalence.matrices,equivalence.maxMatrixError,equivalence.maxHipError,equivalence.maxClearanceError,
        #rig.fullSoleVertices.L_Foot,#rig.fullSoleVertices.R_Foot,#rig.soleVertices.L_Foot,#rig.soleVertices.R_Foot,
        report.soleComparisons,report.maxSoleEquivalenceError))
    print(string.format("[官方走跑数据验收] PASS %d姿态 骨长误差%.7fm Walk髋%.3f..%.3f Run髋%.3f..%.3f 腾空%d 左右支撑%d/%d；视觉必须另看多相位实拍",
        report.poses,report.maxLengthError,report.minWalkHip,report.maxWalkHip,report.minRunHip,report.maxRunHip,report.flight,report.leftContacts,report.rightContacts))
    return report
end
-- -careeranimshot=idle|slow|walk|blend|run|front|side
-- -animphase=0..1 -animview=side|front|rear|threequarter，或-side/-front。
-- 不独立订阅Update、不使用渲染帧号；Session冻结后该真实clip相位保持稳定。
function Checks.Shot(session,mode)
    requireTest(session)
    local actor=session.actor
    local visuals=actor.visuals
    ---@type CareerLocomotion
    local motion=visuals.locomotion
    local phase=.125
    local view="side"
    local speed=mode=="idle" and 0 or mode=="slow" and .6 or mode=="walk" and 1.8 or mode=="blend" and 2.6 or 3.4
    if mode=="front" or mode=="rear" or mode=="threequarter" then view=mode end
    for _,arg in ipairs(GetArguments()) do
        local number=arg:match("^%-animphase=([%d%.]+)$")
        if number then phase=math.max(0,math.min(1,tonumber(number) or phase)) end
        local selected=arg:match("^%-animview=([%a]+)$")
        if selected then view=selected end
        if arg=="-side" then view="side" end
        if arg=="-front" then view="front" end
    end
    actor.mounted=false
    visuals:SetMounted(false)
    actor:Teleport(2,-20,0)
    session.yaw,session.pitch=view=="front" and 180 or view=="rear" and 0 or view=="threequarter" and 135 or 90,0
    session:UpdateEnvironment(12)
    session.camera:SetModeConfig("normal",{distance=3.1,offset=Vector3(0,.93,0),fov=44})
    session.camera:Update(1,actor.node,session.yaw,session.pitch)
    session.view:ShowGame();session:Refresh()
    session.view:ShowDialog("官方动作实拍","",{});session.view.overlay:SetVisible(false)
    for _,entry in pairs(visuals.vehicles) do entry.node:SetEnabledRecursive(false) end
    visuals.walkNode:SetEnabledRecursive(true)
    motion:PoseNormalized(phase,speed)
    motion:SetPaused(true)
    visuals.phase,visuals.gaitWeight,visuals.runWeight=motion.phase*math.pi*2,motion.moving,motion.running
    local d=measure(visuals.walker)
    local path=speed==0 and Locomotion.Paths.idle or speed<=1.8 and Locomotion.Paths.walk or Locomotion.Paths.run
    print(string.format("[官方动画实拍] mode%s view%s phase%.4f speed%.2f clip%s hip%.3f/%.3fh knee%.3f/%.3f sole%.4f/%.4f contact%s/%s frozen=true",
        tostring(mode),view,motion.phase,speed,path,d.hip,d.hipRatio,d.leftKnee,d.rightKnee,d.leftSole,d.rightSole,tostring(d.leftContact),tostring(d.rightContact)))
end
return Checks
