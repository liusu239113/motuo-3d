-- 独立王二狗骨架适配，复用已验证的两段IK算法，不改动旧赛车骑手。
local Rider=require("Rider")
local Locomotion=require("Career.Locomotion")
local V=Vector3
local ROOT="model/62a13e80-74a8-5078-b777-5530e5a4346e/"
local STEM="rig-1-4db698a0-fa75-4297-921d-cb4897aad9cb"
---@class CareerRig : Rider
---@field soleVertices table<string, table[]>
---@field fullSoleVertices table<string, table[]> 原始完整鞋顶点，仅用于等价性回归
---@field ground CareerCity?
---@field feet table<string, Vector3>
---@field soleOffsets table<string, number>
---@field walkPhase number
---@field walkWeight number
---@field walkRun number
---@field locomotion? CareerLocomotion
---@field standingPose? {ground:CareerCity?,left:number,right:number,position:Vector3,rotations:table<string,Quaternion>}
---@field standingBuilds? number
---@field standingRestores? number
---@field EnableOfficialLocomotion fun(self: CareerRig): CareerLocomotion
local Rig={}
Rig.__index=Rig
setmetatable(Rig,{__index=Rider})
Rig.ModelPath=ROOT.."Meshes/"..STEM..".mdl"
Rig.MaterialPath=ROOT.."Materials/"..STEM.."_00_tripo_material_8547aae4-7585-4381-9471-199ca2c0c6ae.xml"
Rig.DiffusePath=ROOT.."Textures/"..STEM.."_00_D.jpg"
Rig.NormalPath=ROOT.."Textures/"..STEM.."_00_N.jpg"
---@param parent Node
---@return CareerRig
function Rig.New(parent,asset)
    local self=setmetatable({},Rig)
    self:InitCareer(parent,asset)
    return self
end
function Rig:InitCareer(parent,asset)
    asset=asset or {model=Rig.ModelPath,material=Rig.MaterialPath,diffuse=Rig.DiffusePath,normal=Rig.NormalPath,height=1.76,name="王二狗"}
    self.parent=parent
    self.vehicleId,self.classId,self.colorId="career_ebike","career","original"
    self.config={hip=V(0,.85,-.18),foot=V(.17,.27,.16),waist=18,spine=26,chest=32,head=0,
        kneeHint=V(.12,0,1),elbowHint=V(.35,-.5,-1)}
    -- 车身纠正前后后，从实际顶点读到握把高度1.11～1.14m、前向约.35m。
    self.grip=V(.32,1.12,.36)
    self.node=parent:CreateChild(asset.name.."骨骼")
    self.mesh=self.node:CreateChild(asset.name.."模型")
    self.model=self.mesh:CreateComponent("AnimatedModel")
    local resource=cache:GetResource("Model",asset.model)
    assert(resource,"王二狗骨骼模型未载入")
    self.model:SetModel(resource)
    self.model:RemoveAllAnimationStates()
    self.model.updateInvisible=true; self.model.animationLodBias=0; self.model.castShadows=true
    self.material=cache:GetResource("Material",asset.material):Clone()
    self.material:SetTexture(TU_DIFFUSE,cache:GetResource("Texture2D",asset.diffuse))
    self.material:SetTexture(TU_NORMAL,cache:GetResource("Texture2D",asset.normal))
    self.model:SetMaterial(self.material)
    self.heightScale=asset.height/resource.boundingBox.size.y
    self.mesh:SetScale(self.heightScale)
    self.bind,self.arms,self.legs,self.boneNames={},{},{},{}
    self.warnedReach,self.initializing={},false
    self.visible,self.disposed,self.lastSteer,self.lastLean=true,false,0,0
    self.standingBuilds,self.standingRestores=0,0
    local skeleton=self.model:GetSkeleton()
    for index=0,skeleton:GetNumBones()-1 do
        local bone=skeleton:GetBone(index)
        bone.animated=false
        local parentBone=index~=bone.parentIndex and skeleton:GetBone(bone.parentIndex) or nil
        self.boneNames[#self.boneNames+1]=bone.name
        self.bind[bone.name]={position=bone.initialPosition,rotation=Quaternion(bone.initialRotation),scale=bone.initialScale,
            modelRotation=Quaternion.IDENTITY,parentName=parentBone and parentBone.name or nil}
        bone.node:SetTransform(bone.initialPosition,bone.initialRotation,bone.initialScale)
    end
    local left=self:GetBonePosition("L_Upperarm")
    local right=self:GetBonePosition("R_Upperarm")
    local side=right-left
    self.mesh.rotation=Quaternion(V(side.x,0,side.z):Normalized(),V.RIGHT)
    -- 骨架绑定已带轴向转换：仅按真实左右肩作小角度标定，不能按mesh包围盒盲目转90度。
    for _,name in ipairs(self.boneNames) do self.bind[name].modelRotation=self:GetLocalBoneTransform(name):Rotation() end
    print(string.format("[人物朝向校正] 原左肩%s 右肩%s yaw %.1f；校正脚尖%s",left:ToString(),right:ToString(),self.mesh.rotation:YawAngle(),(self:GetBonePosition("L_ToeBase")-self:GetBonePosition("L_Foot")):ToString()))
    assert(self.bind.Hip and self.bind.L_Hand and self.bind.R_Foot,"王二狗骨架命名不兼容")
    for _,side in ipairs({-1,1}) do
        local p=side==-1 and "L_" or "R_"
        self.arms[#self.arms+1]=self:CreateChain(p.."Upperarm",p.."Forearm",p.."Hand",side)
        self.legs[#self.legs+1]=self:CreateChain(p.."Thigh",p.."Calf",p.."Foot",side)
    end
    self.standOffset=V(0,-resource.boundingBox.min.y*self.heightScale,0)
    self.mesh.position=self.standOffset
    self.feet={L_Foot=self:GetBonePosition("L_Foot"),R_Foot=self:GetBonePosition("R_Foot")}
    self.soleVertices={L_Foot={},R_Foot={}}
    ---@type table[]
    local skin=assert(self:ReadSkinVertices(0)[1])
    for _,v in ipairs(skin) do
        for _,sideName in ipairs({"L_","R_"}) do
            local weight=0
            for k=1,4 do
                local name=self.boneNames[v.indices[k]+1]
                if (name==sideName.."Foot" or name==sideName.."ToeBase") and v.weights[k]>.2 then weight=1 end
            end
            if weight>0 then
                local list=self.soleVertices[sideName.."Foot"]
                list[#list+1]=v
            end
        end
    end
    -- 只合并position/四权重/四骨索引逐值完全相同的蒙皮点，保留全部不同点。
    -- 二进制double键无十进制舍入，不按距离近似、不降采样；按首次出现顺序保留。
    self.fullSoleVertices=self.soleVertices
    self.soleVertices={L_Foot={},R_Foot={}}
    for _,name in ipairs({"L_Foot","R_Foot"}) do
        local seen={}
        local unique=self.soleVertices[name]
        for _,v in ipairs(self.fullSoleVertices[name]) do
            local p=v.position
            local key=string.pack("dddddddBBBB",p.x,p.y,p.z,v.weights[1],v.weights[2],v.weights[3],v.weights[4],
                v.indices[1],v.indices[2],v.indices[3],v.indices[4])
            if not seen[key] then
                seen[key]=true
                unique[#unique+1]=v
            end
        end
    end
    -- 绑定态真实鞋底到踝点的距离，IK先给出接近正确的目标，再用蒙皮鞋底校正。
    self.soleOffsets={}
    for name,foot in pairs(self.feet) do self.soleOffsets[name]=foot.y-self:SoleHeight(name) end
    self.walkPhase,self.walkWeight,self.walkRun=0,0,0
    -- 只缓存鞋部顶点，不在每帧读回整个人物VB；矩阵按骨名在本次求值内复用。
    print(string.format("[城市角色] %s %d骨，原始尺寸%s，等比身高%.2fm",asset.name,skeleton:GetNumBones(),resource.boundingBox.size:ToString(),asset.height))
end
-- 查询内只复用Skeleton/绑定表/根Node引用；矩阵仍按原来的父到子括号顺序相乘。
-- matrices只由SoleHeight在一次无骨骼写入的求值内创建；不能提升到self/帧/IK事务。
-- IK的PointJoint/SetLocalBoneRotation会交替读写骨骼，每次公开查询必须重读整条祖先链。
---@param bind table<string, RiderBindPose>
---@param skeleton Skeleton
---@param node Node
---@param mesh Node
---@param name string
---@param matrices? table<string, Matrix3x4>
---@return Matrix3x4
local function localBoneTransform(bind,skeleton,node,mesh,name,matrices)
    if matrices and matrices[name] then return matrices[name] end
    local bone=skeleton:GetBone(name)
    local boneNode=bone and bone.node
    assert(boneNode,"Rider skeleton missing bone: "..name)
    local localTransform=boneNode.transform
    local parent=bind[name].parentName
    local transform=parent and localBoneTransform(bind,skeleton,node,mesh,parent,matrices)*localTransform
        or node.transform*mesh.transform*localTransform
    if matrices then matrices[name]=transform end
    return transform
end
---@param name string
---@return Matrix3x4
function Rig:GetLocalBoneTransform(name)
    return localBoneTransform(self.bind,self.model:GetSkeleton(),self.node,self.mesh,name)
end
---@param name string
---@param complete? boolean 仅等价性检查使用未去重完整鞋列表
---@param inspect? boolean 仅隔离回归取回本次实际蒙皮矩阵；默认严格保留单返回值
---@return number
---@return table<string, Matrix3x4>?
function Rig:SoleHeight(name,complete,inspect)
    ---@type table<string, Matrix3x4>
    local matrices={}
    ---@type table<string, Matrix3x4>
    local transforms={}
    local skeleton=self.model:GetSkeleton()
    local bind,node,mesh=self.bind,self.node,self.mesh
    local lowest=math.huge
    local vertices=complete and self.fullSoleVertices[name] or self.soleVertices[name]
    for _,v in ipairs(vertices) do
        local y=0
        for k=1,4 do
            if v.weights[k]>0 then
                local boneName=tostring(self.boneNames[v.indices[k]+1])
                local m=matrices[boneName]
                if not m then
                    m=localBoneTransform(bind,skeleton,node,mesh,boneName,transforms)*skeleton:GetBone(boneName).offsetMatrix --[[@as Matrix3x4]]
                    matrices[boneName]=m
                end
                y=y+(m*v.position).y*v.weights[k]
            end
        end
        lowest=math.min(lowest,y)
    end
    if inspect then return lowest,matrices end
    return lowest
end
function Rig:Reset()
    for _,name in ipairs(self.boneNames) do
        local b=self.bind[name]
        self.model:GetSkeleton():GetBone(name).node:SetTransform(b.position,b.rotation,b.scale)
    end
end
function Rig:PoseRide(steer)
    self.lastSteer=steer
    self:Reset()
    self.mesh.position=V.ZERO
    self.mesh.position=self.config.hip-self:GetBonePosition("Hip")
    self:ApplyPose(steer)
end
local function unit(value) return math.max(0,math.min(1,value or 0)) end

-- 一整圈为同一只脚两次落地。支撑占比从走路双支撑(.56)变为跑步腾空(.44)。
-- 步幅/支撑时间/距离驱动必须使用同一组数据；跑步不是把走路简单加速。
function Rig.Gait(weight,run)
    local w,r=unit(weight),unit(run)
    return (.30+.10*r)*w,.56-.12*r,(.075+.25*r)*w
end
function Rig.CycleLength(weight,run)
    local stride,duty=Rig.Gait(math.max(.01,unit(weight)),run)
    return 2*stride/duty
end

---@param phase number 弧度，左脚落地=0，右脚落地=pi
---@param weight number 慢走到正常步幅[0,1]
---@param run? number 正常走到跑步[0,1]
---@param side number 左=-1，右=1
---@return number, number, boolean, number, number
function Rig.FootCycle(phase,weight,run,side)
    local stride,duty,height=Rig.Gait(weight,run)
    local t=(phase/(2*math.pi)+(side==1 and .5 or 0))%1
    if t<duty then
        local u=t/duty
        -- heel strike -> flat plant -> toe off；脚底仍由真实蒙皮最低点校正。
        local pitch=(-10*math.max(0,1-u*5)+18*math.max(0,(u-.72)/.28))*unit(weight)
        return stride*(1-2*u),0,true,t,pitch
    end
    local u=(t-duty)/(1-duty)
    local smooth=u*u*(3-2*u)
    local lift=math.sin(u*math.pi)*height
    -- 跑步收小腿、抬膝前送；先收脚再伸腿落地，左右半周期交替。
    local pitch=(18*(1-u)-10*u+12*math.sin(u*math.pi))*unit(weight)
    return stride*(-1+2*smooth),lift,false,t,pitch
end

-- 只为主角启用；普通NPC仍走原有入口。不能让不兼容clip直接占用AnimatedModel。
-- 主角只旋转重定向，普通NPC仍保留原程序化入口。
---@return CareerLocomotion
function Rig:EnableOfficialLocomotion()
    if not self.locomotion then self.locomotion=Locomotion.New(self) end
    return self.locomotion
end
function Rig:PoseWalk(phase,weight,run)
    if self.locomotion then
        local speed=weight>0 and (.65+(1.8-.65)*unit(weight)+(3.4-1.8)*unit(run)) or 0
        self.locomotion:PoseNormalized(phase/(math.pi*2),speed)
        return
    end
    self:Reset()
    local w,r=unit(weight),unit(run)
    self.walkPhase,self.walkWeight,self.walkRun=phase,w,r
    local stride=Rig.Gait(w,r)
    local beat=math.sin(phase*2)
    self.mesh.position=self.standOffset
    -- Pelvis与Waist为兄弟。骨盆顺着前送腿转，胸肩反向抵消，头保持看前方。
    local pelvisYaw=math.cos(phase)*5*w
    local chestYaw=-math.cos(phase)*(5+5*r)*w
    self:SetBodyRotation("Pelvis",0,pelvisYaw,beat*1.2*w)
    ---@type Vector3[]
    local targets={}
    local soles,pitches={},{}
    local drop=.025*w+.025*r*w
    local hipZ=self:GetBonePosition("Hip").z
    for i,chain in ipairs(self.legs) do
        local z,lift,_,_,pitch=Rig.FootCycle(phase,w,r,chain.side)
        local foot=self.feet[chain.tip]
        local centerZ=foot.z+(hipZ-foot.z)*w
        local target=V(foot.x,self.soleOffsets[chain.tip]+lift,centerZ+z)
        local groundDelta=0
        if self.ground then
            local world=self.parent.worldTransform*target
            local ground=self.ground --[[@as CareerCity]]
            groundDelta=ground:WalkSurface(world.x,world.z,self.parent.worldPosition.y)-self.parent.worldPosition.y
        end
        targets[i]=target+V(0,groundDelta,0)
        soles[i],pitches[i]=lift+groundDelta,pitch
        local root=self:GetBonePosition(chain.upper)
        -- 以整段支撑最远处算髋高，不在每一步末端临时蹲下，不拉伸/平移腿骨。
        -- 留1.5cm给鞋底蒙皮及脚踝转动；不同身高/路沿两脚分别计算可达范围。
        local dx=foot.x-root.x
        local dz=math.abs(centerZ-root.z)+stride
        local reach=(chain.lengthA+chain.lengthB)*.975
        local vertical=math.sqrt(math.max(.01,reach*reach-dx*dx-dz*dz))
        drop=math.max(drop,root.y-(self.soleOffsets[chain.tip]+groundDelta-.015)-vertical)
    end
    local bob=(1-math.cos(phase*2))*(.004+.009*r)*w
    self.mesh.position=self.standOffset-V(0,drop+bob,0)
    self:SetBodyRotation("Waist",(3+8*r)*w,chestYaw*.35,beat*.7*w)
    self:SetBodyRotation("Spine01",(3+10*r)*w,chestYaw*.7,-beat*1.2*w)
    self:SetBodyRotation("Spine02",(2+10*r)*w,chestYaw,-beat*1.8*w)
    self:SetBodyRotation("NeckTwist01",(1+4*r)*w,chestYaw*.35)
    self:SetBodyRotation("NeckTwist02",w,chestYaw*.15)
    self:SetBodyRotation("Head",0,chestYaw*.1)
    for i,chain in ipairs(self.legs) do
        local target=targets[i]
        local hint=V(chain.side*.055,0,1)
        self:SolveChain(chain,target,hint,false)
        self:SetBodyRotation(chain.tip,pitches[i])
        -- 最多两次小校正；按真实鞋底而非脚踝，摆动脚净空也同样正确。
        for _=1,2 do
            local correction=soles[i]-self:SoleHeight(chain.tip)
            if math.abs(correction)<.0001 then break end
            local corrected=target+V(0,correction,0)
            target=corrected
            self:SolveChain(chain,target,hint,false)
            self:SetBodyRotation(chain.tip,pitches[i])
        end
    end
    for _,chain in ipairs(self.arms) do
        local root=self:GetBonePosition(chain.upper)
        -- 肩摆与同侧腿反相。用实测上/下臂长构造屈肘目标，跑步肘角约80~100度；
        -- 不是把手拉近肩膀后任由IK选反折方向。肘hint始终在肩腕连线后外侧。
        local swing=chain.side*math.cos(phase-.12)*(22+17*r)*w
        local flex=18+(68+10*math.sin(phase)*chain.side)*r*w+6*w
        local rotation=Quaternion(8*(1-w)-swing,V.RIGHT)
        local upper=rotation*V(chain.side*.045,-chain.lengthA,0):Normalized()*chain.lengthA
        local lower=rotation*(Quaternion(-flex,V.RIGHT)*V(0,-chain.lengthB,0))
        local target=root+upper+lower
        self:SolveChain(chain,target,V(chain.side*.18,-.08,-1),false)
        -- 手腕沿小臂，不把手指硬锁世界前向；twist保留绑定旋转。
    end
end
-- 驻足人物只改变上肢；地面双脚支撑值不变时复用精确站姿，避免每人20Hz重算鞋底蒙皮。
-- 缓存限定到本Rig/地面对象与两脚实际地表高度；跨路沿、抬高地表会重新求解，不近似采样。
function Rig:PoseStandingCached()
    local left,right=0,0
    if self.ground then
        local root=self.parent.worldPosition
        local a=self.parent.worldTransform*V(self.feet.L_Foot.x,self.soleOffsets.L_Foot,self.feet.L_Foot.z)
        local b=self.parent.worldTransform*V(self.feet.R_Foot.x,self.soleOffsets.R_Foot,self.feet.R_Foot.z)
        left=self.ground:WalkSurface(a.x,a.z,root.y)-root.y
        right=self.ground:WalkSurface(b.x,b.z,root.y)-root.y
    end
    local saved=self.standingPose
    if not saved or saved.ground~=self.ground or saved.left~=left or saved.right~=right then
        self:PoseWalk(0,0)
        local rotations={}
        for _,name in ipairs(self.boneNames) do
            rotations[name]=Quaternion(self.model:GetSkeleton():GetBone(name).node.rotation)
        end
        self.standingPose={ground=self.ground,left=left,right=right,position=Vector3(self.mesh.position),rotations=rotations}
        self.standingBuilds=(self.standingBuilds or 0)+1
        return
    end
    self.mesh.position=saved.position
    for _,name in ipairs(self.boneNames) do
        self.model:GetSkeleton():GetBone(name).node.rotation=saved.rotations[name]
    end
    self.walkPhase,self.walkWeight,self.walkRun=0,0,0
    self.standingRestores=(self.standingRestores or 0)+1
end
function Rig:SetVisible(visible) self.visible=visible; self.node:SetEnabledRecursive(visible) end
function Rig:Dispose()
    if self.disposed then return end
    self.disposed=true; self.node:Dispose(); self.material:Dispose()
end
return Rig
