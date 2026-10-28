-- 独立王二狗骨架适配，复用已验证的两段IK算法，不改动旧赛车骑手。
local Rider=require("Rider")
local V=Vector3
local ROOT="model/b2849c2afd734d59aaf285fcb69b2b1a/"
local STEM="rig-1-e41d7bfb-0916-49c9-bbcf-cb2d5f522d14"
---@class CareerRig : Rider
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
    print(string.format("[城市角色] %s %d骨，原始尺寸%s，等比身高%.2fm",asset.name,skeleton:GetNumBones(),resource.boundingBox.size:ToString(),asset.height))
end
function Rig:Reset()
    for _,name in ipairs(self.boneNames) do
        local b=self.bind[name]
        self.model:GetSkeleton():GetBone(name).node:SetTransform(b.position,b.rotation,b.scale)
    end
end
function Rig:PoseRide(steer)
    self:Reset()
    self.mesh.position=V.ZERO
    self.mesh.position=self.config.hip-self:GetBonePosition("Hip")
    self:ApplyPose(steer)
end
function Rig:PoseWalk(phase,weight)
    self:Reset()
    local w=math.max(0,math.min(1,weight))
    -- 完整跨步1.20m；支撑半周期匀速向后，摆动半周期前送并抬脚。
    -- 髋点随跨步降低而不是缩短步幅；膝向前、肘向后，禁止反关节。
    local stride=.30*w
    self.mesh.position=self.standOffset
    ---@type Vector3[]
    local targets={}
    local drop=.025*w
    for i,chain in ipairs(self.legs) do
        local t=((phase/(2*math.pi))+(chain.side==1 and .5 or 0))%1
        local z,lift
        if t<.5 then
            z=stride*(1-4*t); lift=0
        else
            local u=(t-.5)*2
            local smooth=u*u*(3-2*u)
            z=stride*(-1+2*smooth);lift=math.sin(u*math.pi)*.13*w
        end
        local target=self.feet[chain.tip]+V(0,lift,z)
        targets[i]=target
        local root=self:GetBonePosition(chain.upper)
        local dx,dz=target.x-root.x,target.z-root.z
        local reach=(chain.lengthA+chain.lengthB)*.985
        local vertical=math.sqrt(math.max(.01,reach*reach-dx*dx-dz*dz))
        drop=math.max(drop,root.y-target.y-vertical)
    end
    self.mesh.position=self.standOffset-V(0,drop,0)
    self:SetBodyRotation("Waist",4*w,math.sin(phase)*2*w)
    self:SetBodyRotation("Spine01",3*w,-math.sin(phase)*3*w)
    self:SetBodyRotation("Spine02",2*w,-math.sin(phase)*4*w)
    for i,chain in ipairs(self.legs) do
        self:SolveChain(chain,targets[i],V(chain.side*.08,0,1),false)
        self:SetBodyRotation(chain.tip,0)
    end
    for _,chain in ipairs(self.arms) do
        local root=self:GetBonePosition(chain.upper)
        local swing=math.cos(phase)*chain.side*.24*w
        local reach=(chain.lengthA+chain.lengthB)*.95
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
