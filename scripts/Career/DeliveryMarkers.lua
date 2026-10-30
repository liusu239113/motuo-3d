-- 基于三维场景脚手架的有界任务指引；只显示，不碰撞、不结算、不改POI或存档。
local Config=require("Career.Config")
local V=Vector3
---@class CareerDeliveryMarker
---@field root Node
---@field beam Node
---@field arrow Node
---@field ring Node
---@field label Text3D
---@field pointId string
---@field stage string
---@field active boolean
---@field visible boolean
---@field x number
---@field z number
---@field y number
---@field text string
local SlotType={}
---@class CareerDeliveryMarkers
---@field city CareerCity
---@field root Node
---@field slots CareerDeliveryMarker[]
---@field materials Material[]
---@field meshes Model[]
---@field clock number
---@field disposed boolean
---@field Sync fun(self:CareerDeliveryMarkers,orders:CareerOrder[],target?:table)
---@field Update fun(self:CareerDeliveryMarkers,dt:number,actor:CareerActor,enabled:boolean)
---@field Dispose fun(self:CareerDeliveryMarkers)
local Markers={}
Markers.__index=Markers
Markers.CAPACITY=5
Markers.DRAW_DISTANCE=430
local colors={pickup=Color(1,.65,.08),dropoff=Color(.12,1,.72),navigation=Color(.25,.65,1)}

local function material(color,alpha)
    local m=Material:new()
    m:SetTechnique(0,assert(cache:GetResource("Technique",alpha and "Techniques/PBR/PBRNoTextureAlpha.xml" or "Techniques/NoTextureUnlit.xml")))
    m:SetShaderParameter("MatDiffColor",Variant(Color(color.r,color.g,color.b,alpha or 1)))
    m:SetShaderParameter("MatEmissiveColor",Variant(Color(color.r*1.8,color.g*1.8,color.b*1.8)))
    m:SetShaderParameter("Roughness",Variant(1))
    m.cullMode=CULL_NONE
    return m
end
---@param parent Node
---@param name string
---@param model Model
---@param mat Material
---@return Node
local function object(parent,name,model,mat)
    local n=parent:CreateChild(name)
    local drawable=n:CreateComponent("StaticModel")
    drawable:SetModel(model);drawable:SetMaterial(mat)
    drawable.castShadows=false;drawable.drawDistance=Markers.DRAW_DISTANCE
    return n
end
---@param city CareerCity
---@return CareerDeliveryMarkers
function Markers.New(city)
    local self=setmetatable({},Markers)
    self:Init(city)
    return self
end
function Markers:Init(city)
    self.city=city;self.root=city.root:CreateChild("取送餐任务光柱")
    self.slots,self.materials,self.meshes={},{},{}
    self.clock=0;self.disposed=false
    -- 12米外柱+不透明细芯，白天远处仍可辨认；地环与箭头对应真实门口。
    local beam=CylinderGeometry(.68,.68,12,12):ToModel()
    local core=CylinderGeometry(.10,.10,12,8):ToModel()
    local ring=TorusGeometry(1.35,.09,8,24):ToModel()
    local arrow=ConeGeometry(.46,.85,4):ToModel()
    self.meshes={beam,ring,arrow,core}
    local font=assert(cache:GetResource("Font","Fonts/NotoSerifSC-Game.otf"))
    for i=1,Markers.CAPACITY do
        local root=self.root:CreateChild("任务指引槽"..i)
        local c=colors.navigation
        local solid=material(c);local translucent=material(c,.34)
        self.materials[#self.materials+1]=solid;self.materials[#self.materials+1]=translucent
        local b=object(root,"半透明目标光柱",beam,translucent);b.position=V(0,6.04,0)
        local inner=object(root,"目标明亮细芯",core,solid);inner.position=V(0,6.04,0)
        local r=object(root,"目标地环",ring,solid);r.rotation=Quaternion(90,0,0);r.position=V(0,.06,0)
        local a=object(root,"目标下箭头",arrow,solid);a.rotation=Quaternion(180,0,0);a.position=V(0,2.8,0)
        local textNode=root:CreateChild("取送阶段和距离");textNode.position=V(0,3.45,0);textNode.scale=V(.65,.65,.65)
        local text=textNode:CreateComponent("Text3D")
        text:SetFont(font,30);text:SetAlignment(HA_CENTER,VA_CENTER);text.faceCameraMode=FC_ROTATE_XYZ
        text.color=c;text.drawDistance=200
        ---@type CareerDeliveryMarker
        local slot={root=root,beam=b,ring=r,arrow=a,label=text,pointId="",stage="",active=false,visible=false,x=0,z=0,y=0,text=""}
        self.slots[i]=slot
        root:SetEnabledRecursive(false)
    end
    print("[任务指引] 5槽复用；取餐琥珀/送达青绿/地点导航蓝；12米双层光柱与地环，无碰撞")
end
---@param orders CareerOrder[]
---@param target? table
function Markers:Sync(orders,target)
    if self.disposed then return end
    local wanted,seen={},{}
    for _,o in ipairs(orders) do
        if o.status=="accepted" or o.status=="picked_up" then
            local stage=o.status=="accepted" and "pickup" or "dropoff"
            local id=stage=="pickup" and o.pickupId or o.dropoffId
            if not seen[id] and Config.points[id] then
                seen[id]=true;wanted[#wanted+1]={id=id,stage=stage}
            end
        end
    end
    if target and Config.points[target.pointId] and not seen[target.pointId] then
        wanted[#wanted+1]={id=target.pointId,stage="navigation"}
    end
    for i,slot in ipairs(self.slots) do
        local goal=wanted[i]
        slot.active=goal~=nil
        if goal and (slot.pointId~=goal.id or slot.stage~=goal.stage) then
            local p=assert(Config.points[goal.id]);slot.pointId,slot.stage=goal.id,goal.stage
            slot.x,slot.z=p.x,p.z
            local c=colors[goal.stage]
            for j=1,2 do
                local mat=self.materials[(i-1)*2+j]
                mat:SetShaderParameter("MatDiffColor",Variant(Color(c.r,c.g,c.b,j==2 and .34 or 1)))
                mat:SetShaderParameter("MatEmissiveColor",Variant(Color(c.r*1.8,c.g*1.8,c.b*1.8)))
            end
            slot.label.color=c
        end
        if not goal then
            slot.pointId,slot.stage="",""
            slot.root:SetEnabledRecursive(false);slot.visible=false
        end
    end
end
---@param dt number
---@param actor CareerActor
---@param enabled boolean
function Markers:Update(dt,actor,enabled)
    if self.disposed then return end
    if enabled then self.clock=self.clock+math.max(0,math.min(dt,.1)) end
    for _,slot in ipairs(self.slots) do
        local distance=math.sqrt((actor.x-slot.x)^2+(actor.z-slot.z)^2)
        local visible=slot.active and self.city.space=="city" and distance<=Markers.DRAW_DISTANCE
        if slot.visible~=visible or slot.root.enabledSelf~=visible then
            slot.visible=visible;slot.root:SetEnabledRecursive(visible)
        end
        if visible then
            slot.y=self.city:WalkSurface(slot.x,slot.z,0)
            slot.root.position=V(slot.x,slot.y,slot.z)
            slot.arrow.position=V(0,2.8+math.sin(self.clock*3)*.18,0)
            local pulse=1+math.sin(self.clock*2.4)*.035
            slot.ring.scale=V(pulse,pulse,pulse)
            local title=slot.stage=="pickup" and "取餐" or slot.stage=="dropoff" and "送达" or "前往"
            local text=title.." · "..Config.points[slot.pointId].label.."\n"..math.floor(distance+.5).."米"
            if slot.text~=text then slot.text=text;slot.label:SetText(text) end
        end
    end
end
function Markers:Dispose()
    if self.disposed then return end
    self.disposed=true;self.root:Dispose()
    for _,mesh in ipairs(self.meshes) do mesh:Dispose() end
    for _,mat in ipairs(self.materials) do mat:Dispose() end
    self.slots,self.meshes,self.materials={},{},{}
end
return Markers
