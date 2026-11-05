-- Production 41-bone Rider only. All anchors are metres in the vehicle visual frame.
-- No generated people, detached limbs, stretched bones or changes to vehicle skill logic.
local Rider=require("Rider")
local V=Vector3
local M={}

---@class MixedDriverProfile
---@field hip Vector3
---@field leftFoot Vector3 Desired ankle XZ, sole Y (NOT ankle Y)
---@field rightFoot Vector3
---@field leftHand Vector3 Wrist target
---@field rightHand Vector3
---@field yaw number
---@field pitch number
---@field height number
---@field footYaw number
---@field seat? Vector3 Actual buttock contact surface
---@field standing? boolean
---@field followJoint? string
---@field eye Vector3 Suggested first-person eye; does not change DrivingCamera
---@field visualHeight number Conservative whole person+vehicle framing height
---@field leftSole? Vector3[] Calibrated existing boot skin, foot-bone local
---@field rightSole? Vector3[]
---@field leftSoleOffset? number
---@field rightSoleOffset? number
---@field followPivot? Vector3
---@field followNode? Node
---@field followRest? Quaternion
---@field restLeftFoot? Vector3
---@field restRightFoot? Vector3
---@field maxFootError? number
---@field maxHandError? number

-- Seat heights measured on the formal source (not the old cockpit seatHeight guesses).
-- Hip is 9cm above the upholstered contact; feet below use boot-sole targets.
---@type table<string,MixedDriverProfile>
M.Profiles={
    skateboard={hip=V(0,1.04,0),leftFoot=V(0,.28,.32),rightFoot=V(0,.28,-.32),
        leftHand=V(-.04,1.38,.54),rightHand=V(-.03,1.38,-.54),yaw=90,pitch=8,height=1.78,footYaw=90,
        standing=true,eye=V(-.03,1.63,.12),visualHeight=2.02,
        -- 滑板不做跑步循环：双脚锁在板上，改用速度驱动的屈膝压板。
        crouchSpeed=.42,crouchFullSpeed=18,crouchBobBase=1.2},
    office={hip=V(0,1.14,.04),leftFoot=V(-.22,.50,.59),rightFoot=V(.22,.50,.59),
        leftHand=V(-.56,1.47,.37),rightHand=V(.56,1.47,.37),yaw=0,pitch=3,height=1.90,footYaw=0,
        seat=V(0,1.05,.04),followJoint="ChairSwivel",eye=V(0,1.79,.17),visualHeight=2.69},
    cart={hip=V(0,.94,-1.26),leftFoot=V(-.18,.025,-1.26),rightFoot=V(.18,.025,-1.36),
        leftHand=V(-.39,1.74,-.88),rightHand=V(.39,1.74,-.88),yaw=0,pitch=4,height=1.94,footYaw=0,
        standing=true,eye=V(0,1.78,-1.20),visualHeight=2.07,
        -- 推车跑：蹬踏相位按车速推进，步幅 0.30m、抬脚 0.14m、躯干起伏 1.8°。
        strideSpeed=.55,strideFullSpeed=20,strideBase=.30,strideLiftBase=.14,strideBobBase=1.8},
    sled={hip=V(0,.796,-.45),leftFoot=V(-.23,.30,.12),rightFoot=V(.23,.30,.12),
        leftHand=V(-.29,1.02,.13),rightHand=V(.29,1.02,.13),yaw=0,pitch=27,height=1.78,footYaw=0,
        seat=V(0,.706,-.45),eye=V(0,1.36,-.26),visualHeight=1.62},
    jetboat={hip=V(0,.53,-.41),leftFoot=V(-.28,.34,.10),rightFoot=V(.28,.34,.10),
        leftHand=V(-.29,.91,.14),rightHand=V(.29,.91,.14),yaw=0,pitch=12,height=1.78,footYaw=0,
        seat=V(0,.44,-.41),eye=V(0,1.16,-.26),visualHeight=1.48},
    buggy={hip=V(.28,1.437,-.45),leftFoot=V(.08,.90,.12),rightFoot=V(.46,.90,.12),
        leftHand=V(.06,1.60,.05),rightHand=V(.50,1.60,.05),yaw=0,pitch=16,height=1.72,footYaw=0,
        seat=V(.28,1.347,-.45),eye=V(.28,2.02,-.25),visualHeight=2.24},
    loader={hip=V(0,1.47,-.36),leftFoot=V(-.19,.91,.20),rightFoot=V(.19,.91,.20),
        leftHand=V(-.24,1.68,.03),rightHand=V(.24,1.68,.03),yaw=0,pitch=8,height=1.72,footYaw=0,
        seat=V(0,1.38,-.36),eye=V(0,2.08,-.24),visualHeight=2.40},
    hovercraft={hip=V(0,1.43,-.38),leftFoot=V(-.22,.84,.11),rightFoot=V(.22,.84,.11),
        leftHand=V(-.26,1.73,.03),rightHand=V(.26,1.73,.03),yaw=0,pitch=10,height=1.78,footYaw=0,
        seat=V(0,1.34,-.38),eye=V(0,2.04,-.24),visualHeight=2.34},
    bathtub={hip=V(0,.42,-.55),leftFoot=V(-.18,.19,.20),rightFoot=V(.18,.19,.20),
        leftHand=V(-.38,.86,-.24),rightHand=V(.38,.86,-.24),yaw=0,pitch=-8,height=1.78,footYaw=0,
        seat=V(0,.33,-.55),eye=V(0,1.05,-.48),visualHeight=1.30},
    toilet={hip=V(0,1.08,.34),leftFoot=V(-.39,.43,.81),rightFoot=V(.39,.43,.81),
        leftHand=V(-.29,1.20,.65),rightHand=V(.29,1.20,.65),yaw=0,pitch=3,height=1.78,footYaw=0,
        seat=V(0,.99,.34),eye=V(0,1.70,.42),visualHeight=2.15},
}
M.Ids={"skateboard","office","cart","sled","jetboat","buggy","loader","hovercraft","bathtub","toilet"}
---@param id string
---@return boolean
function M.Has(id) return M.Profiles[id]~=nil end

-- Select the real upward deck/seat triangle under a contact, using all retained original faces.
-- This reads source VB only during construction, never per-frame. No collision is introduced.
---@param parent Node
---@param x number
---@param z number
---@param low number
---@param high number
---@return number?
local function surface(parent,x,z,low,high)
    local best=low
    local found=false
    for _,draw in ipairs(parent:GetComponents("StaticModel",true)) do
        local model=draw:GetModel()
        local transform=parent.worldTransform:Inverse()*draw.node.worldTransform
        for slot=0,model.numGeometries-1 do
            local geo=model:GetGeometry(slot,0)
            local vb,ib=geo:GetVertexBuffer(0),geo:GetIndexBuffer()
            local vd,indices=vb:GetData(),ib:GetData()
            indices:Seek(geo.indexStart*ib.indexSize)
            for _=1,geo.indexCount//3 do
                local p={}
                for i=1,3 do
                    local index=ib.indexSize==2 and indices:ReadUShort() or indices:ReadUInt()
                    vd:Seek(index*vb.vertexSize+vb:GetElementOffset(SEM_POSITION))
                    p[i]=transform*vd:ReadVector3()
                end
                local a,b,c=p[1],p[2],p[3]
                local den=(b.z-c.z)*(a.x-c.x)+(c.x-b.x)*(a.z-c.z)
                if math.abs(den)>1e-8 then
                    local u=((b.z-c.z)*(x-c.x)+(c.x-b.x)*(z-c.z))/den
                    local v=((c.z-a.z)*(x-c.x)+(a.x-c.x)*(z-c.z))/den
                    local w=1-u-v
                    if u>=-.0001 and v>=-.0001 and w>=-.0001 then
                        local y=u*a.y+v*b.y+w*c.y
                        if y>=low and y<=high and y>best then best=y;found=true end
                    end
                end
            end
        end
    end
    return found and best or nil
end

---@param rig Rider
---@param name string
---@return Node
local function boneNode(rig,name) return assert(rig.model:GetSkeleton():GetBone(name)).node end

---@type table<string,{left:Vector3[],right:Vector3[]}>
local bootCache={}
-- Full weighted skin, not a guessed 8cm ankle-to-sole offset (this pack is only ~8mm).
-- Shared by height: player/AI/garage creation must not repeatedly decode the production skin.
---@param rig Rider
---@return Vector3[],Vector3[]
local function bootSamples(rig)
    local key=tostring(rig.heightScale)
    local cached=bootCache[key]
    if cached then return cached.left,cached.right end
    local left,right={},{}
    local skin={}
    for i,name in ipairs(rig.boneNames) do
        local b=rig.model:GetSkeleton():GetBone(name)
        skin[i]=rig:GetLocalBoneTransform(name)*b.offsetMatrix
    end
    ---@type table[]
    local sourceVertices=assert(rig:ReadSkinVertices(0)[1])
    for _,v in ipairs(sourceVertices) do
        local side=""
        for i=1,4 do
            local name=assert(rig.boneNames[v.indices[i]+1])
            if v.weights[i]>.45 and (name:find("Foot") or name:find("Toe")) then side=name:sub(1,1);break end
        end
        if side~="" then
            local p=V.ZERO
            for i=1,4 do p=p+(skin[v.indices[i]+1]*v.position)*v.weights[i] end
            local samples=side=="L" and left or right
            samples[#samples+1]=(rig:GetLocalBoneTransform(side.."_Foot"):Inverse()*p)*rig.heightScale
        end
    end
    assert(#left>20 and #right>20,"Formal driver boots not found in existing skin")
    bootCache[key]={left=left,right=right}
    return left,right
end

---@param rig Rider
---@param p MixedDriverProfile
---@param side number
---@return Quaternion
local function footRotation(rig,p,side)
    return Quaternion(p.footYaw,V.UP)*rig.bind[side==-1 and "L_Foot" or "R_Foot"].modelRotation
end
---@param samples Vector3[]?
---@param rotation Quaternion
---@return number
local function soleOffset(samples,rotation)
    if not samples then return -.008 end
    local y=math.huge
    for _,sample in ipairs(samples) do y=math.min(y,(rotation*sample).y) end
    return y
end

---@param rig Rider
---@param p MixedDriverProfile
local function applyPose(rig,p)
    -- Body sideways on skateboard. The fixed pelvis/feet are in vehicle frame; head faces travel.
    -- 跑步/压板循环只在这里偏移踝目标，骨骼长度与座位接触点不变。
    local stride=p.stridePhase or 0
    local strideAmount=p.strideAmount or 0
    local bob=p.strideBob or 0
    boneNode(rig,"Hip").rotation=rig.bind.Hip.rotation
    rig:SetBodyRotation("Pelvis",0,p.yaw)
    rig:SetBodyRotation("Waist",p.pitch+bob,p.yaw)
    rig:SetBodyRotation("Spine01",p.pitch+2+bob,p.yaw)
    rig:SetBodyRotation("Spine02",p.pitch+4+bob,p.yaw)
    local headYaw=p.standing and p.yaw*.16 or p.yaw
    rig:SetBodyRotation("NeckTwist01",0,headYaw)
    rig:SetBodyRotation("NeckTwist02",0,headYaw)
    rig:SetBodyRotation("Head",0,headYaw)
    for _,chain in ipairs(rig.legs) do
        local sole=chain.side==-1 and p.leftFoot or p.rightFoot
        local rotation=footRotation(rig,p,chain.side)
        local offset=(chain.side==-1 and p.leftSoleOffset or p.rightSoleOffset) or -.008
        local ankle=V(sole.x,sole.y-offset+.003,sole.z)
        if strideAmount>0 then
            -- 左右腿反相：一条前摆时另一条后蹬，抬脚发生在向前摆动的一半。
            local theta=stride+(chain.side==-1 and 0 or math.pi)
            local swing=math.sin(theta)
            local lift=math.max(0,swing)
            ankle=ankle+V(0,lift*p.strideLift or 0,swing*strideAmount)
        end
        local hint=Quaternion(p.yaw,V.UP)*V(chain.side*.12,.06,1)
        rig:SolveChain(chain,ankle,hint,true)
        rig:SetLocalBoneRotation(chain.tip,rotation)
    end
    for _,chain in ipairs(rig.arms) do
        local target=chain.side==-1 and p.leftHand or p.rightHand
        local hint=Quaternion(p.yaw,V.UP)*V(chain.side*.8,-.35,-.25)
        rig:SolveChain(chain,target,hint,true)
        local bind=rig.bind[chain.tip].modelRotation
        local direction=Quaternion(p.yaw,V.UP)*V(0,-.35,1):Normalized()
        rig:SetLocalBoneRotation(chain.tip,Quaternion(bind*V.UP,direction)*bind)
    end
end

---@class MixedDriver : Rider
---@field driverProfile MixedDriverProfile
---@field ReadPose fun(self:MixedDriver):table
---@field ValidatePose fun(self:MixedDriver)
---@field state? table 每帧仿真状态（speed/deltaTime），只驱动表现，不改物理
local Driver={}
Driver.__index=Driver
setmetatable(Driver,{__index=Rider})

-- A chair skill rotates upholstery about its real pivot, not the full vehicle root.
-- Apply exactly that rigid delta to the metre-scale driver node; never inherit source scale.
function Driver:SyncJoint()
    local p=self.driverProfile
    local joint=p.followNode
    if not joint or not p.followPivot or not p.followRest then return end
    local q=self.parent.worldRotation:Inverse()*joint.worldRotation*p.followRest:Inverse()
    self.node.rotation=q
    self.node.position=p.followPivot-q*p.followPivot
end
---@param steerAngle number
---@param force? boolean
---@param lean? number
function Driver:Update(steerAngle,force,lean)
    if self.disposed then return end
    self.node:SetTransform(V.ZERO,Quaternion.IDENTITY,V.ONE)
    local p=self.driverProfile
    if p.strideSpeed then
        -- 相位由真实里程推进：停下来循环也停，速度越快蹬得越快。
        local dt=self.state and self.state.deltaTime or 0
        local speed=math.max(0,self.state and self.state.speed or 0)
        p.stridePhase=(p.stridePhase or 0)+speed*dt*p.strideSpeed
        -- 车速决定步幅：低速小步快倒，高速迈开腿。
        local t=math.min(1,speed/(p.strideFullSpeed or 22))
        p.strideAmount=p.strideBase*(0.45+0.55*t)
        p.strideLift=p.strideLiftBase*(0.45+0.55*t)
        p.strideBob=math.sin((p.stridePhase or 0)*2)*(p.strideBobBase or 0)
    elseif p.crouchSpeed then
        -- 滑板不迈步：双脚锁板，用速度驱动的重心起伏表现压板发力。
        local dt=self.state and self.state.deltaTime or 0
        local speed=math.max(0,self.state and self.state.speed or 0)
        p.crouchPhase=(p.crouchPhase or 0)+speed*dt*p.crouchSpeed
        local t=math.min(1,speed/(p.crouchFullSpeed or 18))
        p.strideAmount=0
        p.strideLift=0
        p.strideBob=math.sin(p.crouchPhase)*(p.crouchBobBase or 1.2)*(0.4+0.6*t)
    end
    -- Controls are original static meshes. Board balance is independent of fictitious handlebars.
    Rider.Update(self,0,force,lean)
    self:SyncJoint()
end

---@return table
function Driver:ReadPose()
    local p=self.driverProfile
    local result={vehicleId=self.vehicleId,hip=self:GetBonePosition("Hip"),head=self:GetBonePosition("Head"),
        leftHand=self:GetBonePosition("L_Hand"),rightHand=self:GetBonePosition("R_Hand"),
        leftFoot=self:GetBonePosition("L_Foot"),rightFoot=self:GetBonePosition("R_Foot"),
        standing=p.standing==true,boneCount=#self.boneNames,poseFailures=self.poseFailures or 0,
        seat=p.seat,bodyYaw=p.yaw}
    -- Undo ONLY the chair delta for comparison to configured anchors. Parent yaw/lean/air-spin
    -- never enters these vehicle-local IK targets in the first place.
    local inverse=self.node.transform:Inverse()
    local l,r=inverse*result.leftFoot,inverse*result.rightFoot
    local lh,rh=inverse*result.leftHand,inverse*result.rightHand
    result.leftGripError=(lh-p.leftHand):Length()
    result.rightGripError=(rh-p.rightHand):Length()
    result.leftFootError=math.sqrt((l.x-p.leftFoot.x)^2+(l.z-p.leftFoot.z)^2)
    result.rightFootError=math.sqrt((r.x-p.rightFoot.x)^2+(r.z-p.rightFoot.z)^2)
    result.leftSole=l.y+soleOffset(p.leftSole,footRotation(self,p,-1))
    result.rightSole=r.y+soleOffset(p.rightSole,footRotation(self,p,1))
    result.leftSoleError=result.leftSole-p.leftFoot.y
    result.rightSoleError=result.rightSole-p.rightFoot.y
    result.hipError=(inverse*result.hip-self.config.hip):Length()
    local thighs=self:GetBonePosition("R_Thigh")-self:GetBonePosition("L_Thigh")
    result.stanceYaw=math.deg(math.atan(thighs.z,thighs.x))
    return result
end
function Driver:ValidatePose()
    local p=self:ReadPose()
    assert(p.poseFailures==0,"Driver pose transaction failed: "..self.vehicleId)
    assert(p.boneCount==41,"Driver must use production 41-bone character")
    assert(p.hipError<.002,"Driver hip detached from seat/stance")
    assert(p.leftGripError<.006 and p.rightGripError<.006,"Driver hands missed real controls: "..self.vehicleId)
    assert(p.leftFootError<.003 and p.rightFootError<.003,"Driver ankles missed supports")
    assert(math.abs(p.leftSoleError-.003)<.003 and math.abs(p.rightSoleError-.003)<.003,"Driver boot soles penetrated support")
    if self.vehicleId=="skateboard" then
        assert(math.abs(p.leftFoot.z-p.rightFoot.z)>.55,"Skateboard must have one foot ahead of the other")
        assert(math.abs(p.stanceYaw)>75,"Skateboard must be sideways, not motorcycle sitting pose")
    end
end

---@param parent Node Vehicle visual in metres, never SourceTransform
---@param id string
---@param config? table Optional {height=metres,colorId=palette}; anchors may be explicitly overridden.
---@return MixedDriver?
function M.New(parent,id,config)
    local profile=M.Profiles[id]
    if not profile then return nil end -- Protected tank/helicopter/beetle and organic machines untouched.
    ---@type table<string,any>
    local p={}
    for k,v in pairs(profile) do p[k]=v end
    for k,v in pairs(config or {}) do if k~="colorId" then p[k]=v end end
    ---@cast p MixedDriverProfile
    if id=="skateboard" then
        local left=assert(surface(parent,p.leftFoot.x,p.leftFoot.z,.14,.36),"Missing real skateboard front deck support")
        local right=assert(surface(parent,p.rightFoot.x,p.rightFoot.z,.14,.36),"Missing real skateboard rear deck support")
        p.leftFoot=V(p.leftFoot.x,left,p.leftFoot.z);p.rightFoot=V(p.rightFoot.x,right,p.rightFoot.z)
        p.hip=V(0,(left+right)*.5+.765,0)
    end
    if p.followJoint then
        p.followNode=parent:GetChild(p.followJoint,true)
        assert(p.followNode,"Missing driver support joint "..p.followJoint)
        p.followPivot=parent:WorldToLocal(p.followNode.worldPosition)
        p.followRest=parent.worldRotation:Inverse()*p.followNode.worldRotation
    end
    local pose={hip=p.hip,foot=p.rightFoot,waist=p.pitch,spine=p.pitch+2,chest=p.pitch+4,
        head=0,kneeHint=V(.12,0,1),elbowHint=V(.8,-.35,-.25),height=p.height}
    local rig=Rider.NewConfigured(parent,id,pose,function(r) applyPose(r,p) end)
    -- Acquire sole samples from the bind pose, then solve final exact sole contacts.
    for _,name in ipairs(rig.boneNames) do
        local b=rig.bind[name];boneNode(rig,name):SetTransform(b.position,b.rotation,b.scale)
    end
    p.leftSole,p.rightSole=bootSamples(rig)
    p.leftSoleOffset=soleOffset(p.leftSole,footRotation(rig,p,-1))
    p.rightSoleOffset=soleOffset(p.rightSole,footRotation(rig,p,1))
    setmetatable(rig,Driver)
    ---@cast rig MixedDriver
    rig.driverProfile=p
    rig:Update(0,true)
    rig:ValidatePose()
    if config and config.colorId then rig:SetColor(config.colorId) end
    print(string.format("[MixedDriver] %s production41 bones, hip=%s soles=%.3f/%.3f",id,p.hip:ToString(),p.leftFoot.y,p.rightFoot.y))
    return rig
end
return M
