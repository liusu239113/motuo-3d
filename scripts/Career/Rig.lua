-- 独立王二狗骨架适配，复用已验证的两段IK算法，不改动旧赛车骑手。
local Rider=require("Rider")
local V=Vector3
local ROOT="model/b2849c2afd734d59aaf285fcb69b2b1a/"
local STEM="rig-1-e41d7bfb-0916-49c9-bbcf-cb2d5f522d14"
---@class CareerRig : Rider
---@field soleVertices table<string, table[]>
---@field ground CareerCity?
local Rig={}
Rig.__index=Rig
setmetatable(Rig,{__index=Rider})
Rig.ModelPath=ROOT.."Meshes/"..STEM..".mdl"
Rig.MaterialPath=ROOT.."Materials/"..STEM.."_00_tripo_material_f6f61c31-14b2-4a13-a6ed-039b59564bd7.xml"
Rig.DiffusePath=ROOT.."Textures/"..STEM.."_00_D.jpg"
Rig.NormalPath=ROOT.."Textures/"..STEM.."_00_N.png"
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
    local skin=assert(self:ReadSkinVertices()[1])
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
    -- 只缓存鞋部顶点，不在每帧读回整个人物VB；矩阵按骨名在本次求值内复用。
    print(string.format("[城市角色] %s %d骨，原始尺寸%s，等比身高%.2fm",asset.name,skeleton:GetNumBones(),resource.boundingBox.size:ToString(),asset.height))
end
function Rig:SoleHeight(name)
    ---@type table<string, Matrix3x4>
    local matrices={}
    local lowest=math.huge
    for _,v in ipairs(self.soleVertices[name]) do
        local y=0
        for k=1,4 do
            if v.weights[k]>0 then
                local boneName=tostring(self.boneNames[v.indices[k]+1])
                local m=matrices[boneName]
                if not m then
                    m=self:GetLocalBoneTransform(boneName)*self.model:GetSkeleton():GetBone(boneName).offsetMatrix --[[@as Matrix3x4]]
                    matrices[boneName]=m
                end
                y=y+(m*v.position).y*v.weights[k]
            end
        end
        lowest=math.min(lowest,y)
    end
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
function Rig.CycleLength(weight,run)
    return 4*(.30+.08*math.max(0,math.min(1,run or 0)))*math.max(.01,weight)
end
function Rig:PoseWalk(phase,weight,run)
    self:Reset()
    local w=math.max(0,math.min(1,weight))
    local r=math.max(0,math.min(1,run or 0))
    -- 慢走、常速和慢跑共用实际距离驱动；步幅和循环长度必须同源。
    -- 支撑脚向后匀速，摆动脚前送；左右脚分别查询地面，跨路沿时不整人抬起。
    local stride=(.30+.08*r)*w
    self.mesh.position=self.standOffset
    ---@type Vector3[]
    local targets={}
    local soleTargets={}
    local drop=.025*w
    local hipZ=self:GetBonePosition("Hip").z
    for i,chain in ipairs(self.legs) do
        local t=((phase/(2*math.pi))+(chain.side==1 and .5 or 0))%1
        local z,lift
        if t<.5 then
            z=stride*(1-4*t); lift=0
        else
            local u=(t-.5)*2
            local smooth=u*u*(3-2*u)
            z=stride*(-1+2*smooth);lift=math.sin(u*math.pi)*(.09+.07*r)*w
        end
        local foot=self.feet[chain.tip]
        -- 脚踝绑定点偏在髋后，行走以髋为跨步中心，避免每次后蹬都被迫蹲身。
        local target=foot+V(0,lift,z+(hipZ-foot.z)*w)
        local groundDelta=0
        if self.ground then
            local world=self.parent.worldTransform*target
            local ground=self.ground --[[@as CareerCity]]
            groundDelta=ground:WalkSurface(world.x,world.z,self.parent.worldPosition.y)-self.parent.worldPosition.y
        end
        local grounded=target+V(0,groundDelta,0)
        targets[i]=grounded
        soleTargets[i]=lift+groundDelta
        local root=self:GetBonePosition(chain.upper)
        local dx,dz=grounded.x-root.x,grounded.z-root.z
        local reach=(chain.lengthA+chain.lengthB)*.985
        local vertical=math.sqrt(math.max(.01,reach*reach-dx*dx-dz*dz))
        drop=math.max(drop,root.y-grounded.y-vertical)
    end
    self.mesh.position=self.standOffset-V(0,drop,0)
    self:SetBodyRotation("Waist",(4+7*r)*w,math.sin(phase)*2*w)
    self:SetBodyRotation("Spine01",(3+3*r)*w,-math.sin(phase)*3*w)
    self:SetBodyRotation("Spine02",2*w,-math.sin(phase)*4*w)
    for i,chain in ipairs(self.legs) do
        self:SolveChain(chain,targets[i],V(chain.side*.08,0,1),false)
        self:SetBodyRotation(chain.tip,0)
        local correction=soleTargets[i]-self:SoleHeight(chain.tip)
        if math.abs(correction)>.0001 then
            self:SolveChain(chain,targets[i]+V(0,correction,0),V(chain.side*.08,0,1),false)
            self:SetBodyRotation(chain.tip,0)
        end
    end
    for _,chain in ipairs(self.arms) do
        local root=self:GetBonePosition(chain.upper)
        local swing=math.cos(phase)*chain.side*(.24+.05*r)*w
        local reach=(chain.lengthA+chain.lengthB)*(.95-.14*r*w)
        local target=root+V(chain.side*.035,-math.sqrt(math.max(.01,reach*reach-swing*swing)),swing+.025)
        self:SolveChain(chain,target,V(chain.side*.12,-.1,-1),false)
    end
end
function Rig:SetVisible(visible) self.visible=visible; self.node:SetEnabledRecursive(visible) end
function Rig:Dispose()
    if self.disposed then return end
    self.disposed=true; self.node:Dispose(); self.material:Dispose()
end
return Rig
