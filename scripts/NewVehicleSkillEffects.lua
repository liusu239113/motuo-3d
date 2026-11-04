-- 五款混合车的补充技能效果。基于 MotorcycleSkillEffects 固定节点池模式；不生成/替换机械车体。
-- +Z前、+X右、Y上，单位米。调用方持有本对象并驱动 Update；无事件订阅、无自动粒子时钟。
-- 只读 MixedRace 的 odd* 契约。frontAnchor/firstPersonAnchors 是真实发光轨迹的低视野锚点。
local Data = require("MixedVehicles")
local V = Vector3
---@class NewVehicleSkillEffects
---@field id string
---@field kind string
---@field signature string
---@field root Node
---@field frontAnchor Node
---@field firstPersonAnchors Node[]
---@field parts NewVehicleEffectPart[]
---@field materials Material[]
---@field eyeHeight number
---@field eyePosition Vector3
---@field anchorCenterX number
---@field bodyLength number
---@field halfWidth number
---@field lightweight boolean
---@field active boolean
---@field disposed boolean
---@field phase string
---@field amount number
---@field age number
---@field lastSerial number
---@field lastHitSerial number
---@field lastLandingSerial number
---@field hitFlash number
---@field landingFlash number
---@field seenState boolean
local Effects = {}
Effects.__index = Effects
Effects.Resources = {"Techniques/PBR/PBRNoTextureAlpha.xml"}
Effects.ResourceTypes = {[Effects.Resources[1]] = "Technique"}

local DEFINITIONS = {
    hovercraft = {kind="side_jet", color={.12,.78,1}, shape="jet", count=8},
    centipede = {kind="tail_sweep", color={1,.28,.09}, shape="sweep", count=7},
    buggy = {kind="drift_dash", color={1,.72,.22}, shape="streak", count=10},
    loader = {kind="scoop_lift", color={1,.58,.06}, shape="lift", count=8},
    cicada = {kind="windup_ribbon", color={.52,1,.32}, shape="coil", count=6},
}
---@type table<string, Model>
local models = {}
local owners = 0
local function clamp(x,a,b) return math.max(a,math.min(b,x)) end
local function unit(x) return clamp(x,0,1) end

---@param id string
---@return Model
local function shape(id)
    if models[id] then return models[id] end
    local model
    if id=="puff" then model=IcosahedronGeometry(.5,1):ToModel()
    elseif id=="jet" then model=SphereGeometry(.5,8,6):ToModel()
    elseif id=="streak" then model=TubeGeometry({V(0,0,-.5),V(.04,.02,0),V(0,0,.5)},8,.025,4):ToModel()
    else
        local points={}
        for i=0,16 do
            local t=i/16
            if id=="sweep" then
                -- Horizontal arc is behind/beside the vehicle, never a filled screen-facing disk.
                local a=(-70+t*140)*math.pi/180
                points[#points+1]=V(math.sin(a),0,-math.cos(a))
            elseif id=="lift" then
                points[#points+1]=V(0,math.sin(t*math.pi*.72)*.8,t)
            else
                local a=t*math.pi*3
                points[#points+1]=V(math.cos(a)*.34,math.sin(a)*.34,t-.5)
            end
        end
        model=TubeGeometry(points,32,id=="coil" and .016 or .023,5):ToModel()
    end
    models[id]=model
    return model
end

---@class NewVehicleEffectPart
---@field node Node
---@field draw StaticModel
---@field group string
---@field index integer
---@field side number

---@param parent Node 未缩放的车辆表现父节点，与 MotorcycleSkillEffects 相同
---@param id string 只接受 hovercraft/centipede/buggy/loader/cicada；其它返回nil且不创建对象
---@param eyeHeight number 与相机 localOffset.y 相同
---@param length number 归一化真实车长
---@param lightweight? boolean 远端缩减节点数，保留技能轮廓及首视角锚点
---@return NewVehicleSkillEffects?
function Effects.New(parent,id,eyeHeight,length,lightweight)
    if not DEFINITIONS[id] then return nil end
    local self=setmetatable({},Effects)
    self:Init(parent,id,eyeHeight,length,lightweight==true)
    return self
end

---@param parent Node
---@param id string
---@param eyeHeight number
---@param length number
---@param lightweight boolean
function Effects:Init(parent,id,eyeHeight,length,lightweight)
    local definition=assert(DEFINITIONS[id])
    local vehicle=assert(Data.Get(id))
    self.id,self.kind,self.signature=id,definition.kind,id..":"..definition.shape.."/particles/edge"
    self.eyeHeight,self.bodyLength=math.max(.5,eyeHeight),math.max(.5,length)
    self.eyePosition=V(0,self.eyeHeight,0)
    self.anchorCenterX=.55
    self.halfWidth=vehicle.size[1]*self.bodyLength/vehicle.size[3]*.5
    self.lightweight,self.disposed=lightweight,false
    self.parts,self.materials,self.firstPersonAnchors={},{},{}
    self.active,self.amount,self.phase,self.age=false,0,"idle",0
    self.lastSerial,self.lastHitSerial,self.lastLandingSerial=0,0,0
    self.hitFlash,self.landingFlash,self.seenState=0,0,false
    self.root=parent:CreateChild("NewVehicleSkill_"..id,LOCAL)
    -- Empty carrier: only its lateral children emit. |x|>=.5 leaves the central road corridor open.
    self.frontAnchor=self.root:CreateChild("FirstPersonVisibleField",LOCAL)
    self.frontAnchor.position=V(self.anchorCenterX,self.eyeHeight-.36,1.4)
    for _,side in ipairs({-1,1}) do
        local anchor=self.frontAnchor:CreateChild(side<0 and "LeftSkillEdge" or "RightSkillEdge",LOCAL)
        anchor.position=V(side*.55-self.anchorCenterX,0,0)
        self.firstPersonAnchors[#self.firstPersonAnchors+1]=anchor
    end
    local c=definition.color
    local technique=assert(cache:GetResource("Technique",Effects.Resources[1]))
    for i=1,3 do
        local mat=Material:new()
        mat:SetTechnique(0,technique)
        mat.cullMode,mat.occlusion=CULL_NONE,false
        mat:SetShaderParameter("Roughness",Variant(1))
        mat:SetShaderParameter("Metallic",Variant(0))
        mat:SetShaderParameter("MatSpecColor",Variant(Color(0,0,0,1)))
        local smoke=i==2 and id=="buggy"
        mat:SetShaderParameter("MatDiffColor",Variant(smoke and Color(.48,.44,.38,0) or Color(c[1],c[2],c[3],0)))
        mat:SetShaderParameter("MatEmissiveColor",Variant(Color(0,0,0)))
        self.materials[#self.materials+1]=mat
    end
    local count=lightweight and math.ceil(definition.count*.5) or definition.count
    for i=1,count do
        local geometry=definition.shape
        local group="body"
        if id=="hovercraft" and i>2 then geometry,group="puff","particle"
        elseif id=="centipede" and i>3 then geometry,group="streak","hit"
        elseif id=="buggy" and i>2 then geometry,group="puff","particle"
        elseif id=="loader" and i>4 then geometry,group="streak","hit"
        elseif id=="cicada" and i>4 then geometry,group="puff","particle" end
        self:AddPart(self.root,geometry,group,i,i%2==0 and 1 or -1)
    end
    for i,anchor in ipairs(self.firstPersonAnchors) do
        self:AddPart(anchor,definition.shape,"front",i,i==1 and -1 or 1)
    end
    owners=owners+1
    self.root:SetEnabledRecursive(false)
end

-- Eye position is in the same unscaled vehicle-parent frame as New(). Setter updates anchors
-- immediately without advancing skill time, enabling effects, or touching body-space emitters.
---@param position Vector3 实际 Cockpit.localOffset；未调用时保持原先(0,eyeHeight,0)布局
function Effects:SetEyePosition(position)
    if self.disposed then return end
    self.eyePosition=V(position.x,position.y,position.z)
    self.eyeHeight=position.y
    self:PlaceEyeAnchors()
end

function Effects:PlaceEyeAnchors(centerX)
    local eye=self.eyePosition
    local center=centerX or eye.x+self.anchorCenterX
    self.frontAnchor.position=V(center,eye.y-.36,eye.z+1.4)
    for i,anchor in ipairs(self.firstPersonAnchors) do
        local side=i==1 and -1 or 1
        anchor.position=V(eye.x+side*.55-center,0,0)
    end
end

---@param parent Node
---@param geometry string
---@param group string
---@param index integer
---@param side number
function Effects:AddPart(parent,geometry,group,index,side)
    local node=parent:CreateChild("FX_"..group.."_"..index,LOCAL)
    local draw=node:CreateComponent("StaticModel")
    draw:SetModel(shape(geometry))
    local material=self.materials[1]
    if group=="particle" then material=self.materials[2]
    elseif group=="hit" then material=self.materials[3] end
    draw:SetMaterial(material)
    draw.castShadows,draw.shadowDistance,draw.drawDistance=false,0,self.lightweight and 100 or 180
    draw.occluder,draw.occludee=false,false
    self.parts[#self.parts+1]={node=node,draw=draw,group=group,index=index,side=side}
end

-- Compatibility for callers that only have oddActive/oddAge; authoritative oddPhase wins if supplied.
---@param sim table
---@return string
function Effects:ReadPhase(sim)
    if sim.oddPhase then return sim.oddPhase end
    if self.id=="centipede" then return self.age<.42 and "tail_windup" or self.age<.72 and "tail_sweep" or "tail_recover" end
    if self.id=="loader" then return self.age<.36 and "scoop_windup" or self.age<.72 and "scoop_lift" or self.age<1.05 and "scoop_release" or "scoop_recover" end
    return self.id=="cicada" and "wound_release" or self.id=="hovercraft" and "side_jet" or "dash"
end

---@param dt number
---@param sim table 仅读取，不保存sim引用，不修改资源、速度、命中或机械节点
function Effects:Update(dt,sim)
    if self.disposed then return end
    -- Terminal cleanup overrides a paused frame; all other zero-step/paused calls are strict no-ops.
    if sim.finished or sim.wrecked then self:Reset();return end
    if dt<=0 or sim.paused then return end
    self.age=math.max(0,sim.oddAge or 0)
    local phase=self:ReadPhase(sim)
    local remaining=math.max(0,sim.oddActive or 0)
    local landing=self.id=="buggy" and phase=="landing_boost" and (sim.oddLandingBoost or 0)>0
        and math.abs(sim.speed or 0)>.1
    local show=remaining>0 and phase~="idle" and phase~="suppressed" and phase~="wound" and phase~="exhausted"
    local serial,hitSerial,landingSerial=sim.oddSerial or 0,sim.oddHitSerial or 0,sim.oddLandingSerial or 0
    local sameAction=self.seenState and serial==self.lastSerial
    self.hitFlash=math.max(0,self.hitFlash-dt)
    self.landingFlash=math.max(0,self.landingFlash-dt)
    -- Serial counters are observed even while hidden, so old hits cannot replay when re-enabled.
    if sameAction and hitSerial>self.lastHitSerial and (show or landing) then self.hitFlash=.18 end
    if self.seenState and landingSerial>self.lastLandingSerial and (show or landing) then self.landingFlash=.22 end
    if not sameAction then self.hitFlash,self.landingFlash=0,0 end
    self.lastSerial,self.lastHitSerial,self.lastLandingSerial=serial,hitSerial,landingSerial
    self.seenState=true
    if not show and not landing then self:Hide();return end
    if not self.active then self.root:SetEnabledRecursive(true) end
    self.active,self.phase=true,phase
    self.amount=unit((landing and sim.oddLandingBoost or remaining)/.16)
    local c=assert(DEFINITIONS[self.id]).color
    for i,mat in ipairs(self.materials) do
        local smoke=i==2 and self.id=="buggy"
        local alpha=self.amount*(i==2 and .18 or i==3 and .85*unit(self.hitFlash/.18) or .68)
        local r,g,b=smoke and .48 or c[1],smoke and .44 or c[2],smoke and .38 or c[3]
        mat:SetShaderParameter("MatDiffColor",Variant(Color(r,g,b,alpha)))
        local glow=smoke and 0 or self.amount*(i==2 and .35 or 1.4)
        mat:SetShaderParameter("MatEmissiveColor",Variant(Color(r*glow,g*glow,b*glow)))
    end
    local direction=(sim.oddJetSide or sim.oddDashSide or 1)<0 and -1 or 1
    -- oddJetSide is movement direction; the nozzle/exhaust points to its opposite side.
    self:PlaceEyeAnchors(self.eyePosition.x+(self.id=="hovercraft" and -direction*.55 or self.anchorCenterX))
    for _,part in ipairs(self.parts) do
        part.node.enabled=true
        part.node.rotation=Quaternion.IDENTITY
        if part.group=="front" then self:PoseFront(part,sim,direction)
        else self:PoseBody(part,sim,direction) end
    end
end

---@param part NewVehicleEffectPart
---@param sim table
---@param direction number
function Effects:PoseFront(part,sim,direction)
    local node,side=part.node,part.side
    local t=self.age
    local pulse=.85+.15*math.sin(t*26)
    if self.id=="hovercraft" then
        node.enabled=side==-direction
        node.position=V(-direction*.06,-.04,0)
        node.scale=V(.34*pulse,.075,.16)
    elseif self.id=="centipede" then
        local sweep=self.phase=="tail_sweep"
        node.position=V(side*.02,-.06,0)
        node.rotation=Quaternion(0,side*(sweep and (t-.42)*220 or -30),0)
        node.scale=V(.30,self.phase=="tail_windup" and .35 or .65,.23)
    elseif self.id=="buggy" then
        node.position=V(side*.04,-.06,-(t*2%1)*.18)
        node.rotation=Quaternion(0,-side*12,0)
        node.scale=V(.7,.6,.55*pulse)
    elseif self.id=="loader" then
        local lift=unit((t-.36)/.36)
        node.position=V(side*.04,-.14+lift*.09,.02)
        node.rotation=Quaternion(0,side*10,0)
        node.scale=V(.4,self.phase=="scoop_windup" and .12 or .28,.42)
    else
        local spring=unit((sim.oddSpring or 0)/math.max(.01,sim.oddSpringMax or 22))
        node.position=V(0,-.05,0)
        node.rotation=Quaternion(0,0,(side*t*1000)%360)
        node.scale=V(.28,.28,.24+spring*.16)
    end
end

---@param part NewVehicleEffectPart
---@param sim table
---@param direction number
function Effects:PoseBody(part,sim,direction)
    local node,i,side=part.node,part.index,part.side
    local t,half=self.age,self.bodyLength*.5
    local p=(t*2.8+i*.173)%1
    local envelope=math.max(.03,math.sin(p*math.pi))
    if self.id=="hovercraft" then
        local width=self.halfWidth+.08
        local strength=.75+.25*unit(math.abs(sim.oddJetLateralSpeed or 0)/2.3)
        if part.group=="body" then
            node.position=V(-direction*(width+.22),.36,(i==1 and -.4 or .3)*half)
            node.scale=V((.85+.12*math.sin(t*40+i))*strength,.16,.22)
        else
            node.position=V(-direction*(width+.2+p*.95),.22+p*.22,((i%3)-1)*half*.5-p*.3)
            node.scale=V(.26*envelope,.13*envelope,.20*envelope)
        end
    elseif self.id=="centipede" then
        local sweep=unit((t-.42)/.30)
        local recover=self.phase=="tail_recover"
        local radius=1.1+sweep*.85
        if part.group=="hit" then
            node.enabled=self.hitFlash>0
            node.position=V(side*(self.halfWidth+.4),.30+(.18-self.hitFlash)*2,-half*.7)
            node.rotation=Quaternion(0,side*65,i*38)
            node.scale=V(.8,.8,.25+unit(self.hitFlash/.18)*.5)
        else
            local windup=self.phase=="tail_windup"
            node.position=V(0,.23+i*.045,-half*.6)
            node.rotation=Quaternion(0,(windup and -38 or -38+sweep*116)+(i-2)*8,0)
            node.scale=V(radius,1,windup and .45 or radius*.75)
            node.enabled=not recover or i==1
            if recover then node.scale=V(radius*.75,.45,radius*.55) end
        end
    elseif self.id=="buggy" then
        if part.group=="particle" then
            node.enabled=not sim.airborne and (sim.oddAltitude or 0)<.45 and math.abs(sim.speed or 0)>.1
            local drift=clamp(sim.steer or 0,-1,1)
            node.position=V(side*(self.halfWidth+.12)+drift*p*.5,.12+p*.28,-half*.68-p*1.6)
            local size=(.18+p*.45)*envelope
            node.scale=V(size,.55*size,size)
        else
            node.position=V(side*(self.halfWidth+.08),.18,-half*.5-p*.7)
            node.rotation=Quaternion(0,-side*7,0)
            node.scale=V(1,1,1.2+p+unit(self.landingFlash/.22)*.5)
        end
    elseif self.id=="loader" then
        local lift=unit((t-.36)/.36)
        local release=unit((t-.72)/.33)
        if part.group=="hit" then
            node.enabled=self.hitFlash>0
            node.position=V(side*(self.halfWidth+.10),.25+(.18-self.hitFlash)*3,half+.2)
            node.rotation=Quaternion(-42,side*24,0)
            node.scale=V(.65,.65,.6)
        else
            node.position=V(side*(self.halfWidth*.83+.06),.15+release*.15,half*.80)
            node.scale=V(.65,.14+lift*.9,.55+lift*.7)
            node.rotation=Quaternion(-release*22,side*(i>2 and 12 or 0),0)
            node.enabled=self.phase~="scoop_recover" or i<=2
        end
    else
        local spring=unit((sim.oddSpring or 0)/math.max(.01,sim.oddSpringMax or 22))
        if part.group=="particle" then
            node.position=V(side*(self.halfWidth+.12),.4+p*.5,-half*.3)
            node.scale=V(.10*envelope,.10*envelope,.10*envelope)
        else
            node.position=V(side*(self.halfWidth+.05),.5+(i>2 and .28 or 0),-.12)
            node.rotation=Quaternion(0,0,(side*t*(800+spring*300)+i*70)%360)
            node.scale=V(.6,.6,.35+spring*.65)
        end
    end
end

-- Hide keeps serial baselines, avoiding replay of already-observed hits after a normal idle frame.
function Effects:Hide()
    self.active,self.amount,self.phase=false,0,"idle"
    self.hitFlash,self.landingFlash=0,0
    self.root:SetEnabledRecursive(false)
end
function Effects:Reset()
    if self.disposed then return end
    self:Hide()
    self.age,self.lastSerial,self.lastHitSerial,self.lastLandingSerial=0,0,0,0
    self.seenState=false
end
function Effects:Dispose()
    if self.disposed then return end
    self:Reset()
    self.disposed=true
    self.root:Dispose()
    for _,material in ipairs(self.materials) do material:Dispose() end
    self.parts,self.materials,self.firstPersonAnchors={},{},{}
    owners=owners-1
    -- Module-shared geometry outlives every referencing instance, then is explicitly released.
    if owners==0 then
        for _,model in pairs(models) do model:Dispose() end
        models={}
    end
end
return Effects
