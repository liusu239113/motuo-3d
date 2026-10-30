-- 官方 DefaultMale 关键帧 -> 王二狗41骨。不是程序化步态，也不对不兼容骨架硬播。
-- 参考官方 StandardLocomotion / NormalLocomotionPolar 的 Idle/Walk/Run 混合语义。
-- 所有源P/R/S先按源骨架FK求值；只传递绑定空间旋转和髋部竖向位移。
-- 目标骨骼position/scale永远保留绑定值；Root含的厘米比例只计算一次。
local V=Vector3
---@class CareerClipKey
---@field time number
---@field position Vector3
---@field rotation Quaternion
---@field scale Vector3

---@class CareerClipTrack
---@field mask number
---@field keys CareerClipKey[]

---@class CareerOfficialClip
---@field animation Animation
---@field length number
---@field tracks table<string, CareerClipTrack>
---@field keyframes integer

---@class CareerSourceBone
---@field name string
---@field parent? string
---@field position Vector3
---@field rotation Quaternion
---@field scale Vector3
---@field transform Matrix3x4

---@class CareerLocomotion
---@field rig CareerRig
---@field source Model
---@field bones CareerSourceBone[]
---@field allBones CareerSourceBone[] 原始97骨，仅用于完整采样对照
---@field reference table<string, Matrix3x4>
---@field corrections table<string, Quaternion>
---@field clips table<string, CareerOfficialClip>
---@field phase number
---@field idleTime number
---@field speed number
---@field moving number
---@field running number
---@field rootRatio number
---@field sourceHipY number
---@field evaluations integer
---@field paused boolean
---@field lastGroundShift number
---@field lastClearance number
---@field PoseNormalized fun(self: CareerLocomotion, phase: number, speed: number)
---@field Update fun(self: CareerLocomotion, dt: number, speed: number, distance?: number)
---@field Reset fun(self: CareerLocomotion)
---@field Evaluate fun(self: CareerLocomotion)
---@field SetPaused fun(self: CareerLocomotion, paused: boolean)
local Motion={}
Motion.__index=Motion
Motion.SourceModel="uuid://EcfK-SEU8-omvBdjwrIJkc55"
Motion.Paths={idle="uuid://HIPCWSBd61v8PRI972Yksxzh",walk="uuid://HhyjGZvHN9uF8lRsGnN_J7jc",run="uuid://FshxoWge4mzIJ-wmBu0GK6Vs"}
Motion.WalkSpeed,Motion.RunSpeed=1.8,3.4
Motion.Resources={Motion.SourceModel,Motion.Paths.idle,Motion.Paths.walk,Motion.Paths.run}
Motion.ResourceTypes={[Motion.SourceModel]="Model",[Motion.Paths.idle]="Animation",[Motion.Paths.walk]="Animation",[Motion.Paths.run]="Animation"}
-- 源与目标骨架的名称、绑定轴向及手臂A字姿势均不同。
-- 已检查的两套骨架中，Waist/Pelvis均为同级骨骼；不能把Waist当成Pelvis的子骨骼。
local mapping={Hip="Bip001",Pelvis="Bip001 Pelvis",Waist="Bip001 Spine",Spine01="Bip001 Spine1",Spine02="Bip001 Spine2",
    NeckTwist01="Bip001 Neck",Head="Bip001 Head"}
local children={Waist="Spine01",Spine01="Spine02",Spine02="NeckTwist01"}
local inheritedAlignment={L_Hand="L_Forearm",R_Hand="R_Forearm"}
for _,side in ipairs({"L","R"}) do
    for _,pair in ipairs({{"Thigh","Thigh"},{"Calf","Calf"},{"Foot","Foot"},{"ToeBase","Toe0"},
        {"Clavicle","Clavicle"},{"Upperarm","UpperArm"},{"Forearm","Forearm"},{"Hand","Hand"}}) do
        mapping[side.."_"..pair[1]]="Bip001 "..side.." "..pair[2]
    end
    -- 手掌继承前臂的绑定校准，不能与前臂使用不同的全局参考姿势。
    -- 锁骨属于体型比例：保留目标肩线，只传动作增量，不强压成源模型肩线。
    for _,pair in ipairs({{"Thigh","Calf"},{"Calf","Foot"},{"Upperarm","Forearm"},{"Forearm","Hand"}}) do
        children[side.."_"..pair[1]]=side.."_"..pair[2]
    end
end
Motion.Mapping=mapping
local function clamp(v,a,b) return math.max(a,math.min(b,v)) end
---@param path string
---@return CareerOfficialClip
local function readClip(path)
    local animation=assert(cache:GetResource("Animation",path),"官方动作未预热: "..path)
    ---@type CareerOfficialClip
    local clip={animation=animation,length=animation.length,tracks={},keyframes=0}
    assert(clip.length>.1 and animation.numTracks>20,"官方动作轨道/时长异常: "..path)
    for index=0,animation.numTracks-1 do
        local track=animation:GetTrack(index)
        ---@type CareerClipTrack
        local copy={mask=track.channelMask,keys={}}
        for k=0,track:GetNumKeyFrames()-1 do
            local key=track:GetKeyFrame(k)
            ---@type CareerClipKey
            local frame={time=key.time,position=key.position,rotation=Quaternion(key.rotation),scale=key.scale}
            copy.keys[#copy.keys+1]=frame
            clip.keyframes=clip.keyframes+1
        end
        clip.tracks[track.name]=copy
    end
    for _,name in pairs(mapping) do assert(clip.tracks[name],"官方动作缺少必要轨道: "..name) end
    print(string.format("[官方动作] %s %.6fs %d轨 %d真实关键帧",path,clip.length,animation.numTracks,clip.keyframes))
    return clip
end
---@param track CareerClipTrack
---@param time number
---@return CareerClipKey, CareerClipKey, number
local function interval(track,time)
    local keys=track.keys
    local lo,hi=1,#keys
    local first,last=assert(keys[1]),assert(keys[hi])
    if time<=first.time then return first,first,0 end
    if time>=last.time then return last,last,0 end
    while hi-lo>1 do
        local mid=(lo+hi)//2
        if keys[mid].time<=time then lo=mid else hi=mid end
    end
    local a,b=assert(keys[lo]),assert(keys[hi])
    return a,b,(time-a.time)/(b.time-a.time)
end
---@param rig CareerRig
---@return CareerLocomotion
function Motion.New(rig)
    local self=setmetatable({},Motion)
    self:Init(rig)
    return self
end
---@param rig CareerRig
function Motion:Init(rig)
    self.rig=rig
    self.source=assert(cache:GetResource("Model",Motion.SourceModel),"官方动作参考骨架缺失")
    self.bones,self.reference,self.corrections={},{},{}
    local skeleton=self.source:GetSkeleton()
    for i=0,skeleton:GetNumBones()-1 do
        local b=skeleton:GetBone(i)
        local parent=i~=b.parentIndex and skeleton:GetBone(b.parentIndex).name or nil
        local localTransform=Matrix3x4(b.initialPosition,b.initialRotation,b.initialScale)
        local transform=parent and self.reference[parent]*localTransform or localTransform
        self.bones[#self.bones+1]={name=b.name,parent=parent,position=b.initialPosition,rotation=Quaternion(b.initialRotation),scale=b.initialScale,transform=transform}
        self.reference[b.name]=transform
    end
    assert(skeleton:GetNumBones()==97 and rig.model:GetSkeleton():GetNumBones()==41,"检查过的官方97骨->王二狗41骨资源已变化，请重新审计")
    -- 仅去掉映射骨骼祖先闭包以外的骨骼，不改父链、求值顺序或插值公式。
    -- 原97骨描述仍保留供隔离检查逐相位对照，正常帧只求值24骨。
    self.allBones=self.bones
    ---@type table<string, CareerSourceBone>
    local byName={}
    for _,bone in ipairs(self.allBones) do byName[bone.name]=bone end
    ---@type table<string, boolean>
    local required={}
    local mappings=0
    for _,source in pairs(mapping) do
        mappings=mappings+1
        ---@type string?
        local name=source
        while name and not required[name] do
            required[name]=true
            name=assert(byName[name],"源骨架祖先链不完整").parent
        end
    end
    self.bones={}
    for _,bone in ipairs(self.allBones) do
        if required[bone.name] then self.bones[#self.bones+1]=bone end
    end
    assert(mappings==23 and #self.allBones==97 and #self.bones==24,"官方动作23映射/24骨祖先闭包已变化，请重新审计")
    rig:Reset()
    rig.mesh.position=rig.standOffset
    ---@type table<string, Quaternion>
    local alignments={}
    for _,target in ipairs(rig.boneNames) do
        local source=mapping[target]
        if source then
            assert(rig.bind[target] and self.reference[source],"重定向骨骼映射不完整: "..target)
            local sourceBind=self.reference[source]:Rotation()
            local targetBind=rig:GetLocalBoneTransform(target):Rotation()
            local align=Quaternion.IDENTITY
            local child=children[target]
            if child then
                local targetDirection=rig:GetBonePosition(child)-rig:GetBonePosition(target)
                local sourceChild=assert(mapping[child])
                local sourceDirection=self.reference[sourceChild]:Translation()-self.reference[source]:Translation()
                align=Quaternion(targetDirection:Normalized(),sourceDirection:Normalized())
            elseif inheritedAlignment[target] then
                align=assert(alignments[inheritedAlignment[target]],"前臂校准必须先于手掌")
            end
            alignments[target]=align
            -- 全局绑定校准；手腕沿前臂参考，消除仅因参考姿势不同产生的折腕。
            local correction=sourceBind:Inverse()*align*targetBind
            self.corrections[target]=correction:Normalized()
        end
    end
    self.sourceHipY=self.reference.Bip001:Translation().y
    local targetHipY=rig:GetBonePosition("Hip").y-rig.standOffset.y
    self.rootRatio=targetHipY/self.sourceHipY
    assert(self.sourceHipY>.8 and self.sourceHipY<1.1 and self.rootRatio>.8 and self.rootRatio<1.1,"厘米/米或目标身高发生重复缩放")
    self.clips={idle=readClip(Motion.Paths.idle),walk=readClip(Motion.Paths.walk),run=readClip(Motion.Paths.run)}
    self.phase,self.idleTime,self.speed,self.moving,self.running=0,0,0,0,0
    self.evaluations,self.paused,self.lastGroundShift,self.lastClearance=0,false,0,0
    self:Evaluate()
    print(string.format("[官方动作兼容] 97->41骨，显式23映射/绑定轴校准/原骨长FK；世界髋比例%.6f；骑姿IK独立",self.rootRatio))
end
---@param clip CareerOfficialClip
---@param time number
---@param complete? boolean 仅隔离回归使用原始97骨求值
---@return table<string, Matrix3x4>
function Motion:SampleSource(clip,time,complete)
    ---@type table<string, Matrix3x4>
    local pose={}
    local bones=complete and self.allBones or self.bones
    for _,b in ipairs(bones) do
        local p,q,s=b.position,b.rotation,b.scale
        local track=clip.tracks[b.name]
        if track and #track.keys>0 then
            local a,z,t=interval(track,time)
            if (track.mask & CHANNEL_POSITION)~=0 then p=a.position+(z.position-a.position)*t end
            if (track.mask & CHANNEL_ROTATION)~=0 then q=a.rotation:Slerp(z.rotation,t) end
            if (track.mask & CHANNEL_SCALE)~=0 then s=a.scale+(z.scale-a.scale)*t end
        end
        local transform=Matrix3x4(p,q,s)
        pose[b.name]=b.parent and pose[b.parent]*transform or transform
    end
    return pose
end
-- 接触仅调整整个可视根高度：绝不改膝、腕目标，不会把旧的正弦IK混回官动。
-- 源脚跟/脚尖双探针保留动画真实腾空（不能每相位都强行把最低鞋拉回地面）。
---@param pose table<string, Matrix3x4>
---@return number
function Motion:SourceClearance(pose)
    local low=math.huge
    for _,side in ipairs({"L","R"}) do
        local foot="Bip001 "..side.." Foot"
        local toe="Bip001 "..side.." Toe0"
        local clearance=math.min(pose[foot]:Translation().y-self.reference[foot]:Translation().y,
            pose[toe]:Translation().y-self.reference[toe]:Translation().y)
        low=math.min(low,math.max(0,clearance))
    end
    return low*self.rootRatio
end
-- 目标中段脊柱比源骨架长近一倍。按髋到颈的实际轴线限制慢跑前倾，
-- 上身所有后代共同修正，不能单独扶正胸口却把肩、肘、腕留在旧全局位置。
function Motion:RelaxTorso()
    local rig=self.rig
    local torso=rig:GetBonePosition("NeckTwist01")-rig:GetBonePosition("Hip")
    local pitch=math.deg(math.atan(torso.z,torso.y))
    local limit=6+8*self.running
    local correction=clamp(pitch,-6,limit)-pitch
    if math.abs(correction)<.001 then return end
    ---@type table<string, Quaternion>
    local rotations={}
    for _,name in ipairs(rig.boneNames) do rotations[name]=rig:GetLocalBoneTransform(name):Rotation() end
    ---@type table<string, boolean>
    local upperBody={Waist=true}
    for _,name in ipairs(rig.boneNames) do
        local parent=rig.bind[name].parentName
        if parent and upperBody[parent] then upperBody[name]=true end
        if upperBody[name] then
            local weight=name=="Head" and 0 or name=="NeckTwist02" and .33 or name=="NeckTwist01" and .67 or 1
            rig:SetLocalBoneRotation(name,Quaternion(correction*weight,V.RIGHT)*rotations[name])
        end
    end
end
function Motion:Evaluate()
    local rig=self.rig
    local idle=self:SampleSource(self.clips.idle,self.idleTime%self.clips.idle.length)
    local walk=self:SampleSource(self.clips.walk,self.phase*self.clips.walk.length)
    local run=self:SampleSource(self.clips.run,self.phase*self.clips.run.length)
    rig:Reset()
    rig.mesh.position=rig.standOffset
    local blend=self.moving
    local running=self.running
    for _,target in ipairs(rig.boneNames) do
        ---@type string?
        local source=mapping[target]
        if source then
            local move=walk[source]:Rotation():Slerp(run[source]:Rotation(),running)
            local rotation=idle[source]:Rotation():Slerp(move,blend)
            rig:SetLocalBoneRotation(target,rotation*self.corrections[target])
        end
    end
    self:RelaxTorso()
    local walkY=walk.Bip001:Translation().y
    local runY=run.Bip001:Translation().y
    local idleY=idle.Bip001:Translation().y
    local rootY=idleY+((walkY+(runY-walkY)*running)-idleY)*blend
    rig.mesh.position=rig.standOffset+V(0,(rootY-self.sourceHipY)*self.rootRatio,0)
    local idleAir=self:SourceClearance(idle)
    local walkAir=self:SourceClearance(walk)
    local runAir=self:SourceClearance(run)
    local clearance=idleAir+((walkAir+(runAir-walkAir)*running)-idleAir)*blend
    local shift=-math.huge
    for _,name in ipairs({"L_Foot","R_Foot"}) do
        local foot=rig:GetBonePosition(name)
        local groundDelta=0
        if rig.ground then
            local world=rig.parent.worldTransform*foot
            groundDelta=rig.ground:WalkSurface(world.x,world.z,rig.parent.worldPosition.y)-rig.parent.worldPosition.y
        end
        shift=math.max(shift,groundDelta-rig:SoleHeight(name))
    end
    rig.mesh.position=rig.mesh.position+V(0,shift+clearance,0)
    self.lastGroundShift,self.lastClearance=shift,clearance
    self.evaluations=self.evaluations+1
    rig.walkPhase,rig.walkWeight,rig.walkRun=self.phase*math.pi*2,self.moving,self.running
end
---@param dt number
---@param speed number
---@param distance? number
function Motion:Update(dt,speed,distance)
    -- Session暂停时不调用；dt=0也严格冻结phase、Idle呼吸、权重和骨骼。
    if self.paused or dt<=0 then return end
    local velocity=distance~=nil and math.abs(distance)/dt or math.abs(speed)
    self.speed=velocity
    local moving=clamp(velocity/.65,0,1)
    local running=clamp((velocity-Motion.WalkSpeed)/(Motion.RunSpeed-Motion.WalkSpeed),0,1)
    local alpha=1-math.exp(-dt*18)
    self.moving=self.moving+(moving-self.moving)*alpha
    self.running=self.running+(running-self.running)*alpha
    if moving==0 and self.moving<.001 then self.moving,self.running=0,0 end
    if moving>0 then
        -- 真实位移驱动归一化周期，堵墙distance=0不踏步。Walk=1.2s，Run=.8s。
        local cycle=Motion.WalkSpeed*self.clips.walk.length
            +(Motion.RunSpeed*self.clips.run.length-Motion.WalkSpeed*self.clips.walk.length)*self.running
        self.phase=(self.phase+(distance~=nil and math.abs(distance) or velocity*dt)/cycle)%1
    end
    self.idleTime=self.idleTime+dt
    self:Evaluate()
end
---@param phase number 归一化[0,1)
---@param speed number
function Motion:PoseNormalized(phase,speed)
    self.phase=phase%1
    self.idleTime=self.phase*self.clips.idle.length
    self.speed=math.max(0,speed)
    self.moving=clamp(self.speed/.65,0,1)
    self.running=clamp((self.speed-Motion.WalkSpeed)/(Motion.RunSpeed-Motion.WalkSpeed),0,1)
    self:Evaluate()
end
function Motion:Reset()
    self.phase,self.idleTime,self.speed,self.moving,self.running=0,0,0,0,0
    self:Evaluate()
end
function Motion:SetPaused(paused) self.paused=paused end
return Motion
