-- 正式MDL表现适配器；源模型、贴图和原始三角面共用于玩家、AI和车库。
local Assets = require("MixedAssets")
local Rider = require("Rider")
local V = Vector3
local M = {}

-- 正式MDL全部LOD0顶点在yaw=226.1/长2.1m归一化后的接触点。
-- 握把非对称：原模型左把低约5cm且后退6cm，不能镜像右把；车把仍属于静态Body。
M.RiderBindings = {
    ebike = {left=V(-.47,1.23,.322),right=V(.47,1.29,.385),origin=V(0,1.26,.444)},
}
M.Cockpits = {
    ebike = {localOffset=V(0,1.64,-.15),pitch=8,fov=72,seatHeight=.996,
        grip=M.RiderBindings.ebike.right,dash=V(0,1.33,.35),cameraCalibrated=true},
    tank = {localOffset=V(0,1.43,-.78),pitch=0,fov=72,seatHeight=1.20,
        grip=V(0,1.18,.30),dash=V(0,1.22,.16),cameraCalibrated=true},
    beetle = {localOffset=V(0,1.52,-.74),pitch=0,fov=72,seatHeight=1.28,
        grip=V(0,1.24,.36),dash=V(0,1.30,.20),cameraCalibrated=true},
    helicopter = {localOffset=V(0,1.52,-.72),pitch=0,fov=74,seatHeight=1.30,
        grip=V(0,1.28,.28),dash=V(0,1.25,.18),cameraCalibrated=true},
}

---@param parent Node 归一化车辆本地米坐标；不得传SourceTransform
---@param id string
---@return Rider?
function M.CreateRider(parent,id)
    local binding=M.RiderBindings[id]
    if not binding then return nil end
    return Rider.New(parent,id,binding.right,binding)
end

-- 源车把不独立转向，手腕始终贴在原网格握把；车架lean/pitch通过父节点继承。
---@param rig Rider?
---@param lean? number
function M.UpdateRiderBinding(rig,lean)
    if rig and not rig.disposed then rig:Update(0,false,lean or 0) end
end

---@param rig Rider?
function M.DisposeRider(rig)
    if rig then rig:Dispose() end
end

---@param color string|number[]
---@return string?
function M.RiderColorId(color)
    if type(color)=="string" then return Rider.Palettes[color] and color or nil end
    if type(color)~="table" then return nil end
    local best,bestDistance="red",math.huge
    for _,id in ipairs(Rider.ColorIds) do
        local rgb=Rider.Palettes[id].color
        local distance=0
        for i=1,3 do distance=distance+((color[i] or 0)-rgb[i])^2 end
        if distance<bestDistance then best,bestDistance=id,distance end
    end
    return best
end
local materials = {}
local measuredBounds = {}

---@param source Model
---@param id string
---@param rotation Quaternion
---@return BoundingBox
local function sourceBounds(source,id,rotation)
    if measuredBounds[id] then return measuredBounds[id] end
    local bounds=BoundingBox()
    for slot=0,source.numGeometries-1 do
        local geo=source:GetGeometry(slot,0)
        local vb,ib=geo:GetVertexBuffer(0),geo:GetIndexBuffer()
        local vertices,indices=vb:GetData(),ib:GetData()
        indices:Seek(geo.indexStart*ib.indexSize)
        for _=1,geo.indexCount do
            local index=ib.indexSize==2 and indices:ReadUShort() or indices:ReadUInt()
            vertices:Seek(index*vb.vertexSize+vb:GetElementOffset(SEM_POSITION))
            bounds:Merge(rotation*vertices:ReadVector3())
        end
    end
    measuredBounds[id]=bounds
    return bounds
end

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

-- 兼容车库Node入口；只改正式骑手的独立材质，绝不染整车图集。
---@param root Node
---@param color string|number[]
---@return boolean
function M.SetRiderColor(root,color)
    local id=M.RiderColorId(color)
    local rider=root:GetChild("ThirdPersonRider",true)
    if not id or not rider then return false end
    local model=rider:GetComponent("AnimatedModel",true)
    local texture=cache:GetResource("Texture2D",Rider.Palettes[id].diffuse)
    if not model or not texture then return false end
    model:GetMaterial():SetTexture(TU_DIFFUSE,texture)
    return true
end

---@param bounds BoundingBox?
local function helicopterPart(x,y,z,bounds)
    -- 四片原始桨叶有下垂，不能只按桨毂高度切，否则会留下静止的桨尖。
    local radius=math.sqrt((x-.023)^2+(z+.004)^2)
    if y<.194 and ((y>.080 and radius>.10) or y>.140) then return "Rotor" end
    -- 只移动完整、独立的发射筒连通件。旧中心阈值误带机身侧面和半只轮胎，
    -- 这里按整件边界排除机身、机翼挂架、起落架和跨左右的连接杆。
    if bounds and bounds.min.x>-.06 and bounds.max.x<.14
        and bounds.min.y>-.235 and bounds.max.y<-.14
        and (bounds.max.z<-.15 or bounds.min.z>.15) then return "WeaponPods" end
    return "Body"
end

---@param parent Node
---@param id string
---@return Node
function M.Build(parent, id)
    local c = assert(Assets.Vehicles[id], "正式模型尚未交付："..tostring(id))
    local source = assert(cache:GetResource("Model", c.model), c.model)
    local rotation = Quaternion(0, c.rotation, 0)
    local bounds = sourceBounds(source,id,rotation)
    local scale = c.targetLength / bounds.size.z
    local root = parent:CreateChild("Vehicle_"..id)
    local canonical = root:CreateChild("SourceTransform")
    canonical.rotation = rotation
    canonical:SetScale(scale)
    canonical.position = V(-bounds.center.x,-bounds.min.y,-bounds.center.z)*scale
    local mat = material(c)
    if id == "tank" or id == "beetle" then
        require("MixedArticulation").Build(canonical,id,source,mat)
    elseif id == "helicopter" or id == "ebike" then
        local offset=V(-bounds.center.x,-bounds.min.y,-bounds.center.z)
        ---@param p Vector3
        ---@return Vector3
        local function toFrame(p) return (rotation*p+offset)*scale end
        ---@param _ number
        ---@param _ number
        ---@param _ number
        ---@param piece BoundingBox?
        ---@return string
        local function ebikePart(_,_,_,piece)
            -- 实测前轮心z=.792/y=.265，后轮心z=-.704/y=.262米。
            -- 整个连通件必须落在轮域内；挡泥板、减震、排气和跨车架件保持静止。
            if piece and piece.min.x>-.115 and piece.max.x<.115 and piece.max.y<.54 then
                if piece.min.z>.52 and piece.max.z<1.06 then return "FrontWheel" end
                if piece.min.z>-.98 and piece.max.z<-.43 then return "RearWheel" end
            end
            return "Body"
        end
        local selector=id=="helicopter" and helicopterPart or ebikePart
        local parts = require("MixedMeshParts").Extract(source,id,selector,true,id=="ebike" and toFrame or nil)
        assert(parts.Body,"正式载具必须保留原始车体")
        if id=="helicopter" then assert(parts.Rotor,"正式直升机必须有独立原始桨叶") end
        if id=="ebike" then assert(parts.FrontWheel and parts.RearWheel,"正式电动车必须有独立原始车轮") end
        for name,part in pairs(parts) do
            local pivot = canonical:CreateChild(name)
            local mesh = pivot:CreateChild("OriginalMesh")
            if name == "Rotor" then
                local center = V(.023,.162,-.004)
                pivot.position = center
                mesh.position = -center
            elseif name=="FrontWheel" or name=="RearWheel" then
                local center=rotation:Inverse()*(V(0,name=="FrontWheel" and .265 or .262,
                    name=="FrontWheel" and .792 or -.704)/scale-offset)
                pivot.position=center
                mesh.position=-center
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
    if id=="tank" or id=="beetle" then
        require("MixedArticulation").Animate(root,id,time,state)
        return
    end
    if id=="ebike" then
        local distance=state and state.distance or 0
        local angle=distance/.264*180/math.pi%360
        local axis=Quaternion(0,Assets.Vehicles.ebike.rotation,0):Inverse()*V.RIGHT
        for _,name in ipairs({"FrontWheel","RearWheel"}) do
            local wheel=root:GetChild(name,true)
            if wheel then wheel.rotation=Quaternion(angle,axis) end
        end
        return
    end
    if id ~= "helicopter" then return end
    local rotor = root:GetChild("Rotor",true)
    if rotor then
        rotor.rotation = Quaternion(0,time*1600%360,0)
    end
    local pods=root:GetChild("WeaponPods",true)
    if pods then
        local active=state and (state.oddActive or 0)>0
        local recoil=active and math.max(0,math.sin(time*32))*.023 or 0
        pods.position=V(-recoil,0,0)
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
    -- 未单独标定的载具按真实模型高度推导眼位：略高于车顶并前移，
    -- 保证第一视角能看清路面而不是被自身车体挡住。
    local size=self.body:GetVar("VehicleSize"):GetVector3()
    local fallback={localOffset=V(0,math.max(1.1,size.y+0.25),size.z*0.06),pitch=4,fov=74,
        seatHeight=math.max(0.8,size.y*0.55),grip=V(.3,1,.4),dash=V(0,size.y*0.85,size.z*0.10)}
    local cockpit=M.Cockpits[id] or fallback
    self.cockpit=self.visual:CreateChild("Cockpit"); self.steering=self.cockpit:CreateChild("Steering")
    self.dashboardMarker=self.visual:CreateChild("Dashboard"); self.dashboardMarker.position=cockpit.dash
    self.Cockpit=cockpit
    self.firstPerson,self.disposed,self.leanSign=false,false,1
    ---@type StaticModel[]
    self.firstPersonMeshes={}
    -- 首视角去掉封闭驾驶舱/炮塔和头顶旋翼；前方独立巨颚、炮管、车轮
    -- 及武器挂架继续显示，保留操作时的空间感和真实关节动作。
    local hidden={Body=true,Turret=true,Rotor=true,DetailedBody=true}
    for _,draw in ipairs(self.body:GetComponents("StaticModel",true)) do
        if hidden[draw.node.name] or hidden[draw.node.parent.name]
            or (id=="ebike" and draw.node.parent.name=="Body") then
            self.firstPersonMeshes[#self.firstPersonMeshes+1]=draw
        end
    end
    self.riderRig=M.CreateRider(self.visual,id)
        or {visible=false,disposed=false,SetColor=function() return false end,SetVisible=function() end,
            Update=function() end,Dispose=function(rig) rig.disposed=true end}
    self.riderRig:SetColor("red")
    self.mirrors={SetQuality=function() end,Update=function() end,Dispose=function() end}
    self.effects={pitch=0,bob=0,Dispose=function() end}
end
function Adapter:SetRiderColor(color)
    local id=M.RiderColorId(color)
    return id and self.riderRig:SetColor(id) or false
end
function Adapter:SetFirstPerson(firstPerson)
    if self.disposed then return end
    self.firstPerson=firstPerson==true
    self.riderRig:SetVisible(not self.firstPerson)
    for _,draw in ipairs(self.firstPersonMeshes) do
        -- 只切绘制组件；不禁用Vehicle/SourceTransform和关节节点，
        -- 这样首视角和追尾视角之间切换不会丢失车轮/巨颚/旋翼状态。
        draw.enabled=not self.firstPerson
    end
    self.cockpit.enabled=false
end
function Adapter:SetQuality(_) end
function Adapter:UpdateMirrors(_,_) end
function Adapter:GetDashboardWorldPosition() return self.dashboardMarker.worldPosition end
function Adapter:GetCameraWorldPosition() return self.visual:LocalToWorld(self.Cockpit.localOffset) end
function Adapter:GetGrabWorldPosition()
    if self.vehicleId~="beetle" then return nil end
    return require("MixedArticulation").GetGrabWorldPosition(self.body)
end
function Adapter:UpdateState(_,sim,firstPerson,clock)
    if self.disposed then return end
    self.node.position=V(sim.x or 0,sim.y or 0,sim.z or 0)
    self.node.rotation=Quaternion(0,sim.heading or sim.yaw or 0,0)
    self.visual.position=V(0,sim.oddAltitude or 0,0)
    -- 空中旋转(spin180/spin360)必须真正体现在模型上，否则按键像"跳跃"。
    -- 被击中时叠加翻滚(tumble)，让碰撞有可见后果。
    local spin=sim.airSpin or 0
    local pitch=(sim.pitch or 0)*.5
    local lean=(sim.lean or 0)*.25
    local tumble=self.tumble or 0
    if tumble>0 then
        self.tumble=math.max(0,tumble-math.max(0.016,self.lastDt or 0.016))
        pitch=pitch+math.sin(tumble*22)*34*math.min(1,tumble)
        lean=lean+math.cos(tumble*19)*30*math.min(1,tumble)
    end
    self.visual.rotation=Quaternion(pitch,spin,lean)
    M.Animate(self.body,self.vehicleId,sim.elapsed or clock,sim)
    self.riderRig:Update(0,false,lean)
    if firstPerson ~= self.firstPerson then self:SetFirstPerson(firstPerson) end
end
function Adapter:Dispose()
    if self.disposed then return end
    self.disposed=true
    self.riderRig:Dispose()
    self.node:Dispose()
end
return M
