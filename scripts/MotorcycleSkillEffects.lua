-- 普通摩托技能表现：固定小节点池、共享几何；只读仿真，不决定伤害/命中/资源。
-- 原始整车不替换、不切片、不加装虚构机械；这些环/弧/波均为短时能量特效。
local Data=require("MixedVehicles")
local V=Vector3
---@class MotorcycleSkillEffects
local Effects={}
Effects.__index=Effects
Effects.Resources={"Techniques/PBR/PBRNoTextureAlpha.xml"}
Effects.ResourceTypes={[Effects.Resources[1]]="Technique"}

---@type table<string, Model>
local models={}
local COLORS={
    pulse={1,.24,.035},crescent={.20,.70,1},coil={.92,.85,.42},
    tread={.45,.95,.22},level={.75,.94,1},climb={1,.63,.08},
    armor={.22,.72,.67},guard={1,.46,.19},flywheel={.39,.87,.49},
}
---@return Model
local function shape(id)
    if models[id] then return models[id] end
    local model
    if id=="ring" then model=TorusGeometry(.5,.024,6,40):ToModel()
    elseif id=="arc" then
        local points={}
        for i=0,18 do
            local a=(-140+i*280/18)*math.pi/180
            points[#points+1]=V(math.sin(a)*.5,math.cos(a)*.5,0)
        end
        model=TubeGeometry(points,32,.026,6):ToModel()
    elseif id=="chevron" then model=TubeGeometry({V(-.42,0,-.22),V(0,0,.18),V(.42,0,-.22)},12,.028,6):ToModel()
    elseif id=="bracket" then model=TubeGeometry({V(-.4,-.35,0),V(-.5,.18,0),V(-.25,.45,0),V(.25,.45,0),V(.5,.18,0),V(.4,-.35,0)},24,.036,6):ToModel()
    else model=IcosahedronGeometry(.5,1):ToModel() end
    models[id]=model
    return model
end

---@class MotorcycleEffectPart
---@field node Node
---@field draw StaticModel

---@class MotorcycleSkillEffects
---@field root Node
---@field parts MotorcycleEffectPart[]
---@field materials Material[]
---@field kind string
---@field eyeHeight number
---@field bodyLength number
---@field lightweight boolean
---@field disposed boolean
---@field active boolean
---@field phase string
---@field amount number
---@field lastSerial number
---@field signature string
---@field frontAnchor Node
---@field Reset fun(self:MotorcycleSkillEffects)
---@field Dispose fun(self:MotorcycleSkillEffects)
---@field Update fun(self:MotorcycleSkillEffects,dt:number,sim:table)

---@param parent Node
---@param id string
---@param eyeHeight number 相机本地高度，前方特效位于下视野而非车尾
---@param length number 真实整车归一化长度
---@param lightweight? boolean
---@return MotorcycleSkillEffects?
function Effects.New(parent,id,eyeHeight,length,lightweight)
    local skill=Data.GetMotorcycleSkill(id)
    if not skill then return nil end
    local self=setmetatable({},Effects)
    self:Init(parent,skill,eyeHeight,length,lightweight==true)
    return self
end

---@param parent Node
---@param skill MotorcycleSkill
---@param eyeHeight number
---@param length number
---@param lightweight boolean
function Effects:Init(parent,skill,eyeHeight,length,lightweight)
    self.kind,self.eyeHeight,self.bodyLength,self.lightweight=skill.visual,eyeHeight,length,lightweight
    self.root=parent:CreateChild("MotorcycleSkill_"..skill.id,LOCAL)
    self.frontAnchor=self.root:CreateChild("FirstPersonVisibleField",LOCAL)
    self.frontAnchor.position=V(0,eyeHeight-.24,1.05)
    self.parts,self.materials={},{}
    self.disposed,self.active,self.amount,self.phase,self.lastSerial=false,false,0,"idle",0
    local c=assert(COLORS[self.kind])
    for _,alpha in ipairs({.82,.25}) do
        local mat=Material:new()
        mat:SetTechnique(0,assert(cache:GetResource("Technique",Effects.Resources[1])))
        mat:SetShaderParameter("MatDiffColor",Variant(Color(c[1],c[2],c[3],alpha)))
        mat:SetShaderParameter("MatEmissiveColor",Variant(Color(c[1]*2,c[2]*2,c[3]*2)))
        mat:SetShaderParameter("Roughness",Variant(1))
        mat.cullMode=CULL_NONE
        self.materials[#self.materials+1]=mat
    end
    -- 每种独立空间结构；约3..6个draw，远景只保留主图形。无每帧创建模型/材质。
    local plan={pulse={"ring","ring","ring"},crescent={"arc","arc","arc","arc"},
        coil={"ring","ring","chevron"},tread={"chevron","chevron","chevron","chevron"},
        level={"ring","ring","ring"},climb={"chevron","chevron","chevron"},
        armor={"bracket","bracket","arc"},guard={"ring","ring","ring","shell"},
        flywheel={"ring","ring","ring","chevron"}}
    local shapes=assert(plan[self.kind])
    self.signature=table.concat(shapes,"/")..":"..self.kind
    for i,id in ipairs(shapes) do
        local node=self.root:CreateChild("Energy_"..id.."_"..i,LOCAL)
        local draw=node:CreateComponent("StaticModel")
        local effectMaterial=id=="shell" and self.materials[2] or self.materials[1]
        draw:SetModel(shape(id));draw:SetMaterial(effectMaterial)
        draw.castShadows,draw.shadowDistance,draw.drawDistance=false,0,lightweight and 100 or 180
        self.parts[#self.parts+1]={node=node,draw=draw}
    end
    self.root:SetEnabledRecursive(false)
end

---@param dt number
---@param sim table
function Effects:Update(dt,sim)
    if self.disposed or dt<=0 or sim.paused then return end
    local active=(sim.motorcycleActive or 0)>0 and sim.motorcyclePhase~="suppressed"
    local flash=math.max(0,sim.motorcycleGuardFlash or 0)
    local show=active or flash>0
    if not show then
        if self.active then self.root:SetEnabledRecursive(false) end
        self.active,self.amount,self.phase=false,0,"idle"
        return
    end
    if not self.active then self.root:SetEnabledRecursive(true) end
    self.active,self.phase,self.lastSerial=true,sim.motorcyclePhase or "active",sim.motorcycleSkillSerial or 0
    local age=math.max(0,sim.motorcycleSkillAge or 0)
    local remain=math.max(0,sim.motorcycleActive or 0)
    local fade=flash>0 and math.min(1,flash/.2) or math.min(1,remain/.18)
    self.amount=fade
    local c=assert(COLORS[self.kind])
    self.materials[1]:SetShaderParameter("MatDiffColor",Variant(Color(c[1],c[2],c[3],.82*fade)))
    self.materials[2]:SetShaderParameter("MatDiffColor",Variant(Color(c[1],c[2],c[3],.14*fade)))
    local eye=self.eyeHeight-.24
    local front=1.05
    local steer=math.max(-1,math.min(1,sim.steer or 0))
    for i,part in ipairs(self.parts) do
        local node=part.node
        local phase=(age*1.8+(i-1)/#self.parts)%1
        node.enabled=not self.lightweight or i<=3
        node.rotation=Quaternion.IDENTITY
        local scale=1
        if self.kind=="pulse" then
            scale=.55+phase*.95
            node.position=V(0,eye,front+phase*1.7)
            node.scale=V(scale,scale*.62,scale)
        elseif self.kind=="crescent" then
            local side=i%2==0 and 1 or -1
            local low=i>2
            node.position=V(side*(low and .48 or .42),low and .14 or eye,low and .5 or front+.1)
            node.rotation=Quaternion(low and 90 or 0,0,side*(35+steer*20)+age*35)
            node.scale=V(.95,.95,.95)
        elseif self.kind=="coil" then
            local charge=self.phase=="charge"
            if i<3 then
                scale=charge and (1.15-age*.7) or (.72+phase*.9)
                node.position=V(0,eye,front+(charge and 0 or phase*1.8))
                node.rotation=Quaternion(0,charge and i*38 or 0,(i==1 and 1 or -1)*age*200)
                node.scale=V(scale,scale*.65,scale)
            else
                node.enabled=not charge
                node.position=V(0,.20,front+phase*.65)
                node.scale=V(1.15,1.15,1.15)
            end
        elseif self.kind=="tread" then
            -- 离地时该技能被规则抑制，不画假抓地火花。
            local side=i%2==0 and 1 or -1
            node.position=V(side*.55,i>2 and eye or .10,front+(i>2 and 0 or -.4)+phase*.6)
            node.rotation=Quaternion(i>2 and -35 or 0,side*90,0)
            node.scale=V(.6,.6,.6)
        elseif self.kind=="level" then
            node.position=V(0,eye,front)
            node.rotation=Quaternion(i==1 and 0 or (i==2 and 65 or -65),0,-steer*28)
            node.scale=V(1.30,1.30,.75)
        elseif self.kind=="climb" then
            local step=(i-1)*.28
            node.position=V(0,eye-.35+step+math.sin(age*7)*.035,front+step*.8)
            node.rotation=Quaternion(-35,0,0)
            node.scale=V(1.05-step*.35,1.05-step*.35,1.05-step*.35)
        elseif self.kind=="armor" then
            node.position=V(i==1 and -.48 or i==2 and .48 or 0,eye-(i==3 and .18 or 0),front)
            node.rotation=Quaternion(0,i==1 and -42 or i==2 and 42 or 0,i==3 and 180 or 0)
            node.scale=V(i==3 and 1.5 or .85,.95,.9)
        elseif self.kind=="guard" then
            local crack=flash>0 and (1-flash/.45) or 0
            node.position=V(0,eye,front+crack*.35)
            node.rotation=Quaternion(i==1 and 0 or i==2 and 68 or i==3 and -68 or 0,age*35,0)
            scale=i==4 and 1.45 or 1.35+crack*.85
            node.scale=V(scale,scale*.90,scale*.45)
        else
            -- 惯行使用纵向旋轮+横向惯性环，和前向格挡罩轮廓不同。
            node.position=V(i<3 and (i==1 and -.50 or .50) or 0,eye-(i<3 and .15 or 0),front)
            node.rotation=Quaternion(i==3 and 65 or i==4 and -35 or 0,i<3 and 68 or 0,age*(i%2==0 and 150 or -150))
            node.scale=V(i==3 and 1.45 or .90,i==3 and 1.45 or .90,.9)
        end
    end
end

function Effects:Reset()
    if self.disposed then return end
    self.active,self.amount,self.phase=false,0,"idle"
    self.root:SetEnabledRecursive(false)
end
function Effects:Dispose()
    if self.disposed then return end
    self:Reset();self.disposed=true
    self.root:Dispose()
    for _,mat in ipairs(self.materials) do mat:Dispose() end
    self.parts,self.materials={},{}
end
return Effects
