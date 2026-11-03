-- 正式MDL表现适配器；源模型、贴图和原始三角面共用于玩家、AI和车库。
local Assets = require("MixedAssets")
local V = Vector3
local M = {}
local materials = {}

local function material(c)
    if materials[c.material] then return materials[c.material] end
    local mat = assert(cache:GetResource("Material", c.material), c.material):Clone()
    mat:SetTechnique(0, assert(cache:GetResource("Technique", "Techniques/PBR/PBRDiffNormal.xml")))
    local diffuse = assert(cache:GetResource("Texture2D", c.diffuse), c.diffuse)
    local normal = assert(cache:GetResource("Texture2D", c.normal), c.normal)
    mat:SetTexture(TU_DIFFUSE, diffuse)
    mat:SetTexture(TU_NORMAL, normal)
    mat:SetShaderParameter("MatDiffColor", Variant(Color(1,1,1,1)))
    mat:SetShaderParameter("Metallic", Variant(.18))
    mat:SetShaderParameter("Roughness", Variant(.52))
    mat:SetShaderParameter("MatEmissiveColor", Variant(V.ZERO))
    materials[c.material] = mat
    return mat
end

-- 没有驾驶员的封闭座舱不伪造几何小人；保留调用兼容，后续接正式驾驶员骨骼。
function M.SetRiderColor(_, _) return false end

local function helicopterPart(x,y,_)
    -- 来自LOD0真实三角面投影：旋翼平面下界0.126，尾梁位于-X；雷达罩不随桨叶旋转。
    if y > .126 and y < .194 and x > -.40 then return "Rotor" end
    return "Body"
end

---@param parent Node
---@param id string
---@return Node
function M.Build(parent, id)
    local c = assert(Assets.Vehicles[id], "正式模型尚未交付："..tostring(id))
    local source = assert(cache:GetResource("Model", c.model), c.model)
    local rotation = Quaternion(0, c.rotation, 0)
    local bounds = BoundingBox()
    local box = source.boundingBox
    for _,x in ipairs({box.min.x,box.max.x}) do
        for _,y in ipairs({box.min.y,box.max.y}) do
            for _,z in ipairs({box.min.z,box.max.z}) do bounds:Merge(rotation*V(x,y,z)) end
        end
    end
    local scale = c.targetLength / bounds.size.z
    local root = parent:CreateChild("Vehicle_"..id)
    local canonical = root:CreateChild("SourceTransform")
    canonical.rotation = rotation
    canonical:SetScale(scale)
    canonical.position = V(-bounds.center.x,-bounds.min.y,-bounds.center.z)*scale
    local mat = material(c)
    if id == "helicopter" then
        local parts = require("MixedMeshParts").Extract(source,id,helicopterPart)
        assert(parts.Rotor and parts.Body,"正式直升机必须有独立原始桨叶")
        for name,part in pairs(parts) do
            local pivot = canonical:CreateChild(name)
            local mesh = pivot:CreateChild("OriginalMesh")
            if name == "Rotor" then
                local center = V(.023,.162,-.004)
                pivot.position = center
                mesh.position = -center
            end
            local draw = mesh:CreateComponent("StaticModel")
            draw:SetModel(part.model)
            draw:SetMaterial(mat)
            draw.castShadows = true
            draw.lodBias = 2
        end
    else
        local mesh = canonical:CreateChild("DetailedBody")
        local draw = mesh:CreateComponent("StaticModel")
        draw:SetModel(source)
        draw:SetMaterial(mat)
        draw.castShadows = true
        draw.lodBias = 2
    end
    local size = bounds.size*scale
    root:SetVar("VehicleId",Variant(id))
    root:SetVar("VehicleSize",Variant(size))
    root:SetVar("FormalModel",Variant(c.model))
    print(string.format("[正式载具] %s 原MDL+完整D/N，等比尺寸%.3f/%.3f/%.3fm",id,size.x,size.y,size.z))
    return root
end

function M.Animate(root, id, time, state)
    if id ~= "helicopter" then return end
    local rotor = root:GetChild("Rotor",true)
    if rotor then
        local active = state and (state.oddActive or 0)>0
        rotor.rotation = Quaternion(0,time*(active and 2200 or 1600)%360,0)
    end
end

-- 保留Bike公开生命周期；混合车不套摩托座舱。
local Adapter = {}; Adapter.__index = Adapter
function M.NewBike(scene,id)
    local self=setmetatable({},Adapter); self:Init(scene,id); return self
end
function Adapter:Init(scene,id)
    self.vehicleId=id; self.node=scene:CreateChild("Bike_"..id)
    self.visual=self.node:CreateChild("VehicleMotion"); self.body=M.Build(self.visual,id)
    self.cockpit=self.visual:CreateChild("Cockpit"); self.steering=self.cockpit:CreateChild("Steering")
    self.dashboardMarker=self.visual:CreateChild("Dashboard"); self.dashboardMarker.position=V(0,1,.4)
    self.Cockpit={localOffset=V(0,2.6,-.3),pitch=8,fov=72,seatHeight=1,grip=V(.3,1,.4)}
    self.firstPerson,self.disposed,self.leanSign=false,false,1
    self.riderRig={visible=true,SetColor=function() return false end,Update=function() end,Dispose=function() end}
    self.mirrors={SetQuality=function() end,Update=function() end,Dispose=function() end}
    self.effects={pitch=0,bob=0,Dispose=function() end}
end
function Adapter:SetRiderColor(color) return M.SetRiderColor(self.body,color) end
function Adapter:SetFirstPerson(_) self.firstPerson=false; self.cockpit.enabled=false end
function Adapter:SetQuality(_) end
function Adapter:UpdateMirrors(_,_) end
function Adapter:GetDashboardWorldPosition() return self.dashboardMarker.worldPosition end
function Adapter:GetCameraWorldPosition() return self.visual:LocalToWorld(self.Cockpit.localOffset) end
function Adapter:UpdateState(_,sim,_,clock)
    if self.disposed then return end
    self.node.position=V(sim.x,sim.y,sim.z)
    self.node.rotation=Quaternion(0,sim.heading or sim.yaw,0)
    self.visual.position=V(0,sim.oddAltitude or 0,0)
    self.visual.rotation=Quaternion((sim.pitch or 0)*.5,0,(sim.lean or 0)*.25)
    M.Animate(self.body,self.vehicleId,sim.elapsed or clock,sim)
    self:SetFirstPerson(false)
end
function Adapter:Dispose()
    if self.disposed then return end
    self.disposed=true; self.node:Dispose()
end
return M
