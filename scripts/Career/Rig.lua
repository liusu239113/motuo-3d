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
function Rig.New(parent)
    local self=setmetatable({},Rig)
    self:InitCareer(parent)
    return self
end
function Rig:InitCareer(parent)
    self.parent=parent
    self.vehicleId,self.classId,self.colorId="career_ebike","career","original"
    self.config={hip=V(0,.85,-.18),foot=V(.17,.27,.16),waist=18,spine=26,chest=32,head=0,
        kneeHint=V(.12,0,1),elbowHint=V(.8,-.6,-.3)}
    -- 车身纠正前后后，从实际顶点读到握把高度1.11～1.14m、前向约.35m。
    self.grip=V(.32,1.12,.36)
    self.node=parent:CreateChild("王二狗骨骼")
    self.mesh=self.node:CreateChild("王二狗模型")
    self.model=self.mesh:CreateComponent("AnimatedModel")
    local resource=cache:GetResource("Model",Rig.ModelPath)
    assert(resource,"王二狗骨骼模型未载入")
    self.model:SetModel(resource)
    self.model:RemoveAllAnimationStates()
    self.model.updateInvisible=true; self.model.animationLodBias=0; self.model.castShadows=true
    self.material=cache:GetResource("Material",Rig.MaterialPath):Clone()
    self.material:SetTexture(TU_DIFFUSE,cache:GetResource("Texture2D",Rig.DiffusePath))
    self.material:SetTexture(TU_NORMAL,cache:GetResource("Texture2D",Rig.NormalPath))
    self.model:SetMaterial(self.material)
    self.heightScale=1.76/resource.boundingBox.size.y
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
    print(string.format("[王二狗] 正式角色 %d骨，原始尺寸%s，等比身高1.76m",skeleton:GetNumBones(),resource.boundingBox.size:ToString()))
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
    -- 步幅限定在真实腿长内，抬脚前先降低髋点，避免直腿末端目标超伸。
    self.mesh.position=self.standOffset-V(0,.045*weight,0)
    for _,chain in ipairs(self.legs) do
        local swing=math.sin(phase)*chain.side
        local lift=math.max(0,math.cos(phase)*chain.side)*.07*weight
        self:SolveChain(chain,self.feet[chain.tip]+V(0,lift,swing*.14*weight),V(chain.side*.1,0,1),false)
        self:SetBodyRotation(chain.tip,0)
    end
    for _,chain in ipairs(self.arms) do
        local root=self:GetBonePosition(chain.upper)
        self:SolveChain(chain,root+V(chain.side*.06,-(chain.lengthA+chain.lengthB)*.94,-math.sin(phase)*chain.side*.16*weight),V(chain.side*.2,-.2,1),false)
    end
end
function Rig:SetVisible(visible) self.visible=visible; self.node:SetEnabledRecursive(visible) end
function Rig:Dispose()
    if self.disposed then return end
    self.disposed=true; self.node:Dispose(); self.material:Dispose()
end
return Rig
