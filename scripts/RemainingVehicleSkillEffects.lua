-- Nine independent skill silhouettes, NOT vehicle meshes. Same fixed-pool contract as NewVehicleSkillEffects.
-- +Z forward / metres. Tube trails and tiny translucent particles only; no collision, autonomous clock or hits.
local Data=require("MixedVehicles")
local V=Vector3
---@class RemainingVehicleEffectPart
---@field node Node
---@field draw StaticModel
---@field group string
---@field index integer
---@field side number
---@field geometry string
---@class RemainingVehicleSkillEffects
---@field id string
---@field kind string
---@field signature string
---@field root Node
---@field frontAnchor Node
---@field firstPersonAnchors Node[]
---@field parts RemainingVehicleEffectPart[]
---@field materials Material[]
---@field eyePosition Vector3
---@field eyeHeight number
---@field bodyLength number
---@field halfWidth number
---@field lightweight boolean
---@field disposed boolean
---@field active boolean
---@field age number
---@field phase string
---@field amount number
---@field lastSerial number
---@field seenState boolean
---@field previousHop number
---@field landingFlash number
---@field hitFlash number Always zero; no local hit invention.
local R={}
R.__index=R
R.Resources={"Techniques/PBR/PBRNoTextureAlpha.xml"}
R.ResourceTypes={[R.Resources[1]]="Technique"}
local DEFS={
    jellyfish={kind="bubble_cast",shape="bubble",color={.28,.70,1},accent={.86,.38,1},count=10},
    jetboat={kind="tail_jet",shape="streak",color={.12,.72,1},accent={.7,.95,1},count=12},
    frog={kind="hop_ripple",shape="ripple",color={.32,1,.24},accent={.83,1,.35},count=8},
    skateboard={kind="ollie_score",shape="score",color={1,.30,.66},accent={1,.83,.23},count=10},
    sled={kind="blade_trail",shape="blade",color={.36,.9,1},accent={.85,.98,1},count=10},
    cart={kind="magnet_orbit",shape="orbit",color={1,.69,.08},accent={1,.94,.36},count=10},
    bathtub={kind="bubble_shield",shape="bubble",color={.34,.94,.87},accent={1,.54,.88},count=10},
    office={kind="chair_cyclone",shape="spiral",color={.64,.43,1},accent={.48,.88,1},count=8},
    toilet={kind="flush_rocket",shape="flame",color={1,.28,.045},accent={.38,.77,1},count=12},
}
---@type table<string, Model>
local meshes={}
local owners=0
local function unit(x) return math.max(0,math.min(1,x)) end
function R.Has(id) return DEFS[id]~=nil end

-- Geometry is created once per module pool lifetime, never in Update. All curves are hollow.
---@param key string
---@return Model
local function mesh(key)
    if meshes[key] then return meshes[key] end
    ---@type Model
    local result
    if key=="spark" then result=IcosahedronGeometry(.5,0):ToModel()
    else
        local points={}
        local radius=key=="bubble" and .5 or 1
        local count=key=="bubble" and 48 or 24
        for i=0,count do
            local t=i/count
            local a=t*math.pi*2
            if key=="bubble" then
                -- Two perpendicular great circles in ONE drawable, not a filled shield sphere.
                local b=(t*2%1)*math.pi*2
                points[#points+1]=t<.5 and V(math.cos(b)*radius,math.sin(b)*radius,0)
                    or V(math.cos(b)*radius,0,math.sin(b)*radius)
            elseif key=="ripple" or key=="orbit" then
                points[#points+1]=V(math.cos(a),key=="orbit" and math.sin(a*2)*.13 or 0,math.sin(a))
            elseif key=="spiral" then
                local r=.35+t*.65
                points[#points+1]=V(math.cos(a*2)*r,t,math.sin(a*2)*r)
            elseif key=="flame" then
                local r=(1-t)*.28
                points[#points+1]=V(math.cos(a*2)*r,-t,math.sin(a*2)*r)
            elseif key=="arc" then
                points[#points+1]=V((t-.5)*.8,math.sin(t*math.pi*7)*.08,t-.5)
            elseif key=="score" then
                points[#points+1]=V((t-.5)*.4,.01*math.sin(a),t-.5)
            elseif key=="blade" then
                points[#points+1]=V(math.sin(t*math.pi)*.06,t*t*.12,t-.5)
            else points[#points+1]=V(math.sin(t*math.pi)*.025,0,t-.5) end
        end
        result=TubeGeometry(points,count,key=="bubble" and .013 or key=="flame" and .034 or .019,4):ToModel()
    end
    meshes[key]=result
    return result
end

---@param parent Node
---@param id string
---@param eyeHeight number
---@param length number
---@param lightweight? boolean
---@return RemainingVehicleSkillEffects?
function R.New(parent,id,eyeHeight,length,lightweight)
    if not R.Has(id) then return nil end
    local self=setmetatable({},R)
    self:Init(parent,id,eyeHeight,length,lightweight==true)
    return self
end
function R:Init(parent,id,eyeHeight,length,lightweight)
    local d=assert(DEFS[id])
    local data=assert(Data.Get(id))
    self.id,self.kind,self.signature=id,d.kind,id..":"..d.kind.."/"..d.shape.."/360-low-edge"
    self.bodyLength,self.halfWidth=math.max(.5,length),data.size[1]*math.max(.5,length)/data.size[3]*.5
    self.eyeHeight,self.eyePosition=eyeHeight,V(0,eyeHeight,0)
    self.lightweight,self.disposed=lightweight,false
    self.parts,self.materials,self.firstPersonAnchors={},{},{}
    self.active,self.amount,self.age,self.phase=false,0,0,"idle"
    self.lastSerial,self.seenState,self.previousHop=0,false,0
    self.hitFlash,self.landingFlash=0,0
    self.root=parent:CreateChild("RemainingVehicleSkill_"..id,LOCAL)
    self.frontAnchor=self.root:CreateChild("FirstPersonVisibleField",LOCAL)
    local technique=assert(cache:GetResource("Technique",R.Resources[1]))
    for index=1,3 do
        local material=Material:new()
        material:SetTechnique(0,technique)
        material.cullMode,material.occlusion=CULL_NONE,false
        material:SetShaderParameter("Roughness",Variant(1))
        material:SetShaderParameter("Metallic",Variant(0))
        material:SetShaderParameter("MatSpecColor",Variant(Color(0,0,0,1)))
        material:SetShaderParameter("MatDiffColor",Variant(Color(0,0,0,0)))
        material:SetShaderParameter("MatEmissiveColor",Variant(Color(0,0,0)))
        self.materials[#self.materials+1]=material
    end
    local count=lightweight and math.ceil(d.count*.5) or d.count
    for i=1,count do
        local geometry=d.shape
        if id=="jellyfish" and i<=2 then geometry="arc"
        elseif id=="jetboat" and i>2 then geometry="spark"
        elseif id=="frog" and i>3 then geometry="spark"
        elseif id=="skateboard" and i>4 then geometry="spark"
        elseif id=="sled" and i>4 then geometry="spark"
        elseif id=="cart" and i>2 then geometry="bubble"
        elseif id=="toilet" and i>4 then geometry="spark" end
        self:AddPart(self.root,geometry,"body",i,i%2==0 and 1 or -1)
    end
    -- An eye-relative perimeter gives visible LOW-edge cues through a full 360-degree look.
    -- Anchors at 22.5+45n degrees; radius 1.6m, y=-.58m. No filled sphere/disc over the road.
    -- AI needs only four edge cues; the world-space body silhouette is still complete.
    local bearings=lightweight and 4 or 8
    for i=1,bearings do
        local anchor=self.frontAnchor:CreateChild("EyePerimeter_"..i,LOCAL)
        local angle=math.rad(22.5+(i-1)*360/bearings)
        anchor.position=V(math.sin(angle)*1.6,-.58,math.cos(angle)*1.6)
        anchor.rotation=Quaternion(0,22.5+(i-1)*360/bearings,0)
        self.firstPersonAnchors[#self.firstPersonAnchors+1]=anchor
        self:AddPart(anchor,d.shape,"front",i,i%2==0 and 1 or -1)
    end
    self.frontAnchor.position=self.eyePosition
    owners=owners+1
    self.root:SetEnabledRecursive(false)
end
function R:AddPart(parent,geometry,group,index,side)
    local node=parent:CreateChild("FX_"..group.."_"..index,LOCAL)
    local draw=node:CreateComponent("StaticModel")
    draw:SetModel(mesh(geometry))
    draw:SetMaterial(self.materials[geometry=="spark" and 3 or index%2==0 and 2 or 1])
    draw.castShadows,draw.shadowDistance,draw.drawDistance=false,0,self.lightweight and 100 or 180
    draw.occluder,draw.occludee=false,false
    self.parts[#self.parts+1]={node=node,draw=draw,group=group,index=index,side=side,geometry=geometry}
end
---@param position Vector3 Actual unscaled Cockpit.localOffset, not model-space source coordinates.
function R:SetEyePosition(position)
    if self.disposed then return end
    self.eyePosition,self.eyeHeight=V(position.x,position.y,position.z),position.y
    self.frontAnchor.position=self.eyePosition
end
---@param dt number
---@param sim table Read only; no held references, simulation writes or invented hits.
function R:Update(dt,sim)
    if self.disposed then return end
    if sim.finished or sim.wrecked or sim.eliminated then self:Reset();return end
    if dt<=0 or sim.paused then return end
    local remaining=math.max(0,sim.oddActive or 0)
    local shield=sim.oddShield
    local show=remaining>0 and sim.oddPhase~="suppressed"
    if self.id=="jellyfish" and sim.oddAttack then show=false end
    if self.id=="bathtub" and shield~=nil and shield<=0 then show=false end
    if not show then self:Hide();self.previousHop=0;return end
    local serial=sim.oddSerial or 0
    if not self.seenState or serial~=self.lastSerial then
        self.previousHop,self.landingFlash=0,0
    end
    self.landingFlash=math.max(0,self.landingFlash-dt)
    local hop=math.max(0,sim.oddHop or 0)
    if (self.id=="frog" or self.id=="skateboard") and self.previousHop>0 and hop<=0 then
        self.landingFlash=.28 -- observed hop->ground transition only, never a hit flash
    end
    self.previousHop,self.seenState,self.lastSerial=hop,true,serial
    self.age,self.amount=math.max(0,sim.oddAge or 0),unit(remaining/.16)
    self.phase=self:ReadPhase(sim)
    self.active=true
    self.root:SetEnabledRecursive(true)
    local d=assert(DEFS[self.id])
    for index,material in ipairs(self.materials) do
        local c=index==2 and d.accent or d.color
        local alpha=self.amount*(index==3 and .40 or .68)
        material:SetShaderParameter("MatDiffColor",Variant(Color(c[1],c[2],c[3],alpha)))
        local glow=index==3 and .8 or 1.25
        material:SetShaderParameter("MatEmissiveColor",Variant(Color(c[1]*glow,c[2]*glow,c[3]*glow)))
    end
    for _,part in ipairs(self.parts) do
        part.node.enabled=true
        part.node.rotation=Quaternion.IDENTITY
        if part.group=="front" then self:PoseFront(part,sim) else self:PoseBody(part,sim) end
    end
end
function R:ReadPhase(sim)
    if self.id=="frog" or self.id=="skateboard" then
        if self.landingFlash>0 then return self.id=="frog" and "hop_land" or "ollie_land" end
        if self.age<.12 then return self.id=="frog" and "hop_charge" or "ollie_pop" end
        local total=sim.oddHopDuration or (self.id=="frog" and 2.4 or 1.5)
        if (sim.oddHop or 0)>0 then return (sim.oddHop or 0)>total*.5 and "jump_rise" or "jump_fall" end
        return "jump_recover"
    end
    if self.id=="jellyfish" then return self.age<.18 and "bubble_charge" or "bubble_cast" end
    if self.id=="toilet" then return self.age<.16 and "flush_ignition" or "rocket_burn" end
    return assert(DEFS[self.id]).kind
end
---@param part RemainingVehicleEffectPart
---@param sim table
function R:PoseFront(part,sim)
    local node,i,side=part.node,part.index,part.side
    local t=self.age
    local p=(t*2.5+i*.137)%1
    local pulse=.88+.12*math.sin(t*26+i)
    -- Compact cues never grow past .27m around their low perimeter anchor.
    node.position=V(0,0,0)
    if self.id=="jellyfish" then
        node.position=V(0,p*.12,p*.18)
        node.scale=V(.25,.25,.25)
        node.rotation=Quaternion(0,t*190+i*45,0)
    elseif self.id=="jetboat" then
        node.position=V(side*.03,-.04,-p*.14)
        node.scale=V(1,1,.42*pulse)
    elseif self.id=="frog" then
        node.scale=V(.19*pulse,.8,.19*pulse)
        node.position=V(0,(self.phase=="hop_charge" and -.03 or .02)*pulse,0)
    elseif self.id=="skateboard" then
        node.scale=V(.7,.8,.39+unit(self.landingFlash/.28)*.12)
        node.rotation=Quaternion(0,side*22,0)
    elseif self.id=="sled" then
        node.scale=V(.8,.9,.51*pulse)
        node.position=V(0,-.03,-p*.12)
    elseif self.id=="cart" then
        node.scale=V(.18,.55,.18)
        node.rotation=Quaternion(20,t*180+i*40,0)
    elseif self.id=="bathtub" then
        node.scale=V(.32,.32,.32)
        node.position=V(0,.04*math.sin(t*4+i),0)
        node.rotation=Quaternion(t*40,i*35,0)
    elseif self.id=="office" then
        node.scale=V(.18,.25,.18)
        node.rotation=Quaternion(0,-t*620+i*45,0)
    else
        node.scale=V(.40,.26*pulse,.40)
        node.rotation=Quaternion(-35,0,side*12)
    end
end
---@param part RemainingVehicleEffectPart
---@param sim table
function R:PoseBody(part,sim)
    local node,i,side=part.node,part.index,part.side
    local t,half,width=self.age,self.bodyLength*.5,self.halfWidth+.12
    local p=(t*2.4+i*.173)%1
    local pulse=.88+.12*math.sin(t*32+i)
    local altitude=math.max(0,sim.oddAltitude or 0)
    if self.id=="jellyfish" then
        if i<=2 then
            node.position=V(side*width,.46,half*.60)
            node.scale=V(.7,.8,.62)
            node.rotation=Quaternion(0,side*28,math.sin(t*28)*10)
        else
            -- Straight forward motion alongside the launch corridor; not fake impact/explosion.
            local travel=math.max(0,t-.18)*5.5+(i-3)*.24
            node.position=V(side*(width*.65),.42,half*.75+travel)
            local s=.20+.035*(i%3)
            node.scale=V(s,s,s)
            node.rotation=Quaternion(t*85,i*40,0)
        end
    elseif self.id=="jetboat" then
        node.position=V(side*(width*.65+p*.25),.14+p*.17,-half-.15-p*2.2)
        if i<=2 then node.scale=V(1.8,1.8,2.2*pulse)
        else node.scale=V(.12,.09,.22+(1-p)*.22) end
    elseif self.id=="frog" then
        if i<=3 then
            local charge=self.phase=="hop_charge"
            local scale=charge and (.65+i*.13-t*.5) or .7+((t*1.5+i*.28)%1)*1.4
            node.position=V(0,.10-altitude+(i-1)*.018,-half*.12)
            node.scale=V(scale,.8,scale*.8)
            node.enabled=charge or self.landingFlash>0 or (sim.oddHop or 0)>.05
        else
            node.position=V(side*(width*.9+p*.20),.10+p*.36,-half*.45-p*.6)
            node.scale=V(.09,.16,.09)
        end
    elseif self.id=="skateboard" then
        local landed=self.landingFlash>0 or ((sim.oddHop or 0)<=0 and t>.2)
        node.position=V(side*(width*.70+p*.20),landed and .07-altitude or .12,-half*.35-p*.75)
        node.rotation=Quaternion(landed and 0 or -25,side*14,0)
        node.scale=i<=4 and V(1,1,(landed and 1.3 or .65)*pulse) or V(.06,.08,.17)
    elseif self.id=="sled" then
        node.position=V(side*width,.055+p*.045,-half*.4-p*1.8)
        node.rotation=Quaternion(0,side*3,0)
        node.scale=i<=4 and V(1,1,1.65*pulse) or V(.065,.08,.10)
    elseif self.id=="cart" then
        if i<=2 then
            node.position=V(0,.35+i*.12,0)
            node.rotation=Quaternion(i*12,t*160+i*60,0)
            node.scale=V(width*1.28,.8,half*1.15)
        else
            -- Gold hollow coin-shaped light motes spiral IN. No pickup counter or hit is fabricated.
            local radius=width+.65*(1-p)
            local a=t*4+i*2.399
            node.position=V(math.cos(a)*radius,.45+p*.45,math.sin(a)*(half+.4)*(1-p*.55))
            node.rotation=Quaternion(0,t*500+i*45,90)
            node.scale=V(.18,.18,.055)
        end
    elseif self.id=="bathtub" then
        local a=i*2.399+t*.75
        local r=width+.14*math.sin(t*3+i)
        node.position=V(math.cos(a)*r,.33+(i%3)*.30+.05*math.sin(t*4+i),math.sin(a)*(half+.12))
        node.rotation=Quaternion(t*35,i*51,0)
        local size=.37+(i%3)*.07
        node.scale=V(size,size,size)
    elseif self.id=="office" then
        node.position=V(0,.08+(i%3)*.22,0)
        node.rotation=Quaternion(0,(-t*570+i*91)%360,0)
        local radius=width*(.85+(i%3)*.15)
        node.scale=V(radius,.65,radius)
    else
        if i<=2 then
            node.position=V(side*.24,.15,-half*.24)
            node.rotation=Quaternion(18,0,side*12)
            node.scale=V(.80,1.05*pulse,.80)
        elseif i<=4 then
            node.position=V(side*width,.16,-half*.5)
            node.rotation=Quaternion(55,0,0)
            node.scale=V(.6,.70,.6)
        else
            node.position=V(side*(.28+p*.24),.10-p*.9,-half*.35-p*.75)
            node.scale=V(.10,.22+.19*(1-p),.10)
        end
    end
end
function R:Hide()
    if self.disposed then return end
    self.active,self.amount,self.phase=false,0,"idle"
    self.hitFlash,self.landingFlash=0,0
    self.root:SetEnabledRecursive(false)
end
function R:Reset()
    if self.disposed then return end
    self:Hide()
    self.age,self.lastSerial,self.seenState,self.previousHop=0,0,false,0
end
function R:Dispose()
    if self.disposed then return end
    self:Reset()
    self.disposed=true
    self.root:Dispose()
    for _,material in ipairs(self.materials) do material:Dispose() end
    self.parts,self.materials,self.firstPersonAnchors={},{},{}
    owners=owners-1
    -- Shared models are NOT cache resources. Release only after the last living owner.
    if owners==0 then
        for _,model in pairs(meshes) do model:Dispose() end
        meshes={}
    end
end
return R
