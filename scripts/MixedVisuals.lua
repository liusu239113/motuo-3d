-- 正式MDL表现适配器；源模型、贴图和原始三角面共用于玩家、AI和车库。
local Assets = require("MixedAssets")
local Rider = require("Rider")
local V = Vector3
local M = {}
local newVehicleIds={hovercraft=true,centipede=true,buggy=true,loader=true,cicada=true}
local cockpitSources={
    hovercraft={seat=V(-.04,.075,-.01),control=V(.12,.10,-.15),accent=Color(.12,.55,.72)},
    centipede={seat=V(.16,.08,.02),control=V(.22,.10,-.08),accent=Color(.65,.12,.035)},
    buggy={seat=V(-.10,.11,0),control=V(-.02,.14,0),accent=Color(.04,.65,.72)},
    loader={seat=V(-.08,.16,0),control=V(.01,.27,0),accent=Color(.85,.43,.035)},
    cicada={seat=V(-.03,.12,0),control=V(.16,.04,0),accent=Color(.45,.65,.15)},
}

-- 混合车的首视角只在这里配置；source模型本身保持一整套正式三角面。
-- 电动车的前后轮心、轮半径和左右握把来自正式MDL/上传图复核后的归一化测量。
M.RiderBindings = {
    ebike = {left=V(-.47,1.23,.322),right=V(.47,1.29,.385),origin=V(0,1.26,.444)},
}
M.Cockpits = {
    ebike = {localOffset=V(0,1.64,-.15),pitch=8,fov=72,seatHeight=.996,
        grip=M.RiderBindings.ebike.right,leftGrip=M.RiderBindings.ebike.left,
        dash=V(0,1.33,.35),dashSize=Vector2(.30,.15),dashboardAngle=-22,
        accent=Color(.10,.34,.85),cameraCalibrated=true,
        rearCenter=V(0,.262,-.704),rearRadius=.262},
    tank = {localOffset=V(0,1.43,-.78),pitch=0,fov=72,seatHeight=1.20,
        grip=V(0,1.18,.30),dash=V(0,1.22,.16),dashSize=Vector2(.78,.25),
        dashboardAngle=-12,accent=Color(.22,.25,.28),cameraCalibrated=true},
    beetle = {localOffset=V(0,1.52,-.74),pitch=0,fov=72,seatHeight=1.28,
        grip=V(0,1.24,.36),dash=V(0,1.30,.20),dashSize=Vector2(.72,.24),
        dashboardAngle=-10,accent=Color(.42,.16,.04),cameraCalibrated=true},
    helicopter = {localOffset=V(0,1.52,-.72),pitch=0,fov=74,seatHeight=1.30,
        grip=V(0,1.28,.28),dash=V(0,1.25,.18),dashSize=Vector2(.86,.28),
        dashboardAngle=-8,accent=Color(.16,.22,.27),cameraCalibrated=true},
}

local function configureCockpitMaterials()
    local P = require("Parts")
    local m = {
        black=P.Material(.022,.028,.034,.86,0), rubber=P.Material(.018,.022,.025,.92,0),
        screen=P.Material(.008,.016,.021,.94,0), chrome=P.Material(.40,.43,.45,.42,.55),
        gold=P.Material(.42,.31,.13,.46,.45), control=P.Material(.11,.15,.18,.62,.32),
        accent=P.Material(.10,.34,.85,.48,.15,1.3), warning=P.Material(.85,.08,.025,.40,.12,1.8),
        paint=P.Material(.10,.34,.85,.58,.04), jacket=P.Material(.034,.042,.052,.95,0),
        glove=P.Material(.024,.027,.031,.92,0), armor=P.Material(.047,.052,.058,.72,0),
        stitch=P.Material(.24,.27,.28,.96,0), green=P.Material(.12,.63,.36,.5,0,.35),
        amber=P.Material(.92,.45,.06,.5,0,.4), white=P.Material(.77,.80,.79,.54,0),
        visor=P.Material(.035,.085,.12,.18,.5),
    }
    for _,key in ipairs({"black","rubber","screen","control"}) do
        m[key]:SetShaderParameter("MatSpecColor",Variant(Color(.025,.025,.025,16)))
    end
    m.chrome:SetShaderParameter("MatSpecColor",Variant(Color(.20,.20,.20,32)))
    return P,m
end

local function addInstrumentPanel(parent, config, materials, label)
    local P= require("Parts")
    local panel=parent:CreateChild(label.."InstrumentPanel")
    panel.position=config.dash
    panel.rotation=Quaternion(config.dashboardAngle or 0,0,0)
    local s=config.dashSize
    P.Add(panel,"Bezel",RoundedBoxGeometry(s.x+.05,s.y+.05,.055,3,.025):ToModel(),materials.black,V(0,0,0),V.ONE)
    P.Add(panel,"ReadableFace",RoundedBoxGeometry(s.x,s.y,.012,3,.012):ToModel(),materials.screen,V(0,0,-.035),V.ONE)
    P.Add(panel,"StatusBar","Box",materials.accent,V(0,s.y*.30,-.044),V(s.x*.72,.012,.004),nil,false)
    P.Add(panel,"WarningLamp","Sphere",materials.warning,V(s.x*.34,-s.y*.22,-.046),V(.025,.025,.025),nil,false)
    local anchor=panel:CreateChild("DashboardProjectionAnchor")
    anchor.position=V(0,-.01,-.05)
    return panel,anchor
end

local function buildGenericControls(self,id)
    local P=self.parts
    local c=self.Cockpit
    self.cockpit=self.visual:CreateChild("Cockpit")
    self.steering=self.cockpit:CreateChild("DrivingControls")
    self.steering.position=V(0,c.grip.y,c.grip.z)
    self.dashboard,self.dashboardMarker=addInstrumentPanel(self.cockpit,c,self.materials,id)
    local knob=self.steering:CreateChild("PrimaryControl")
    if id=="tank" then
        P.Add(knob,"TankSteeringYoke",RoundedBoxGeometry(.52,.06,.12,3,.02):ToModel(),self.materials.chrome,V(0,.02,.05),V.ONE)
        P.Add(knob,"GearLever","Cylinder",self.materials.gold,V(.22,.14,.10),V(.035,.16,.035),Quaternion(0,0,0))
        P.Add(knob,"TriggerGuard","Box",self.materials.warning,V(0,.05,.14),V(.12,.05,.025),nil,false)
    elseif id=="beetle" then
        P.Add(knob,"MandibleGrip","Cylinder",self.materials.chrome,V(0,.02,.05),V(.045,.30,.045),Quaternion(0,0,90))
        P.Add(knob,"SteamValve","Sphere",self.materials.gold,V(.20,.12,.10),V(.09,.09,.09))
        P.Add(knob,"ClampButton","Box",self.materials.warning,V(-.20,.10,.12),V(.08,.035,.025),nil,false)
    elseif not newVehicleIds[id] then
        P.Add(knob,"CyclicStick","Cylinder",self.materials.chrome,V(0,-.03,.06),V(.035,.28,.035))
        P.Add(knob,"CyclicGrip","Sphere",self.materials.rubber,V(0,.13,.06),V(.10,.08,.10))
        P.Add(knob,"CollectiveLever","Box",self.materials.control,V(.23,.03,.08),V(.08,.25,.06))
    end
    self.firstPersonMeshes={}
    local hidden={Turret=true,Rotor=true}
    for _,draw in ipairs(self.body:GetComponents("StaticModel",true)) do
        local parent=draw.node.parent
        if hidden[draw.node.name] or (parent and hidden[parent.name]) then
            self.firstPersonMeshes[#self.firstPersonMeshes+1]=draw
        end
    end
end

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
    elseif newVehicleIds[id] then
        require("NewVehicleArticulation").Build(canonical,id,source,mat)
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
    if newVehicleIds[id] then
        assert((size-c.targetSize):Length()<.005,"新车实测范围与碰撞配置不一致："..id)
    end
    local cockpitSource=cockpitSources[id]
    if cockpitSource then
        local seat=canonical:LocalToWorld(cockpitSource.seat)
        local controls=canonical:LocalToWorld(cockpitSource.control)
        local seatLocal=root:WorldToLocal(seat)
        local controlLocal=root:WorldToLocal(controls)
        M.Cockpits[id]={localOffset=seatLocal+V(0,.62,-.08),pitch=5,fov=76,
            seatHeight=seatLocal.y,grip=controlLocal,
            -- 与坦克/锹甲同一观感比例：仪表低于眼位约0.2m、前伸约1m，避免贴近镜头遮满视野。
            dash=V(0,seatLocal.y+.41,seatLocal.z+math.min(1.02,c.targetLength*.33)),
            dashSize=Vector2(.46,.14),
            dashboardAngle=-12,accent=cockpitSource.accent,cameraCalibrated=true}
    end
    root:SetVar("VehicleId",Variant(id))
    root:SetVar("VehicleSize",Variant(size))
    root:SetVar("FormalModel",Variant(c.model))
    print(string.format("[正式载具] %s 原MDL+完整D/N，等比尺寸%.3f/%.3f/%.3fm",id,size.x,size.y,size.z))
    return root
end

-- 关节名到节点的缓存：Animate每帧调用，逐帧GetChild递归是赛事表现最大开销之一。
-- 缓存以车辆根节点为键，弱表引用，节点销毁后自动失效。
local jointCache = setmetatable({}, {__mode = "k"})
---@param root Node
---@param name string
---@return Node?
local function joint(root, name)
    local map = jointCache[root]
    if not map then map = {}; jointCache[root] = map end
    local node = map[name]
    if node then return node end
    node = root:GetChild(name, true)
    map[name] = node
    return node
end
local ebikeWheelAxis = Quaternion(0, Assets.Vehicles.ebike.rotation, 0):Inverse() * V.RIGHT

function M.Animate(root, id, time, state)
    if id=="tank" or id=="beetle" then
        require("MixedArticulation").Animate(root,id,time,state)
        return
    end
    if newVehicleIds[id] then
        require("NewVehicleArticulation").Animate(root,id,time,state)
        return
    end
    if id=="ebike" then
        local distance=state and state.distance or 0
        local angle=distance/.264*180/math.pi%360
        for _,name in ipairs({"FrontWheel","RearWheel"}) do
            local wheel=joint(root,name)
            if wheel then wheel.rotation=Quaternion(angle,ebikeWheelAxis) end
        end
        return
    end
    if id ~= "helicopter" then return end
    local rotor = joint(root,"Rotor")
    if rotor then
        rotor.rotation = Quaternion(0,time*1600%360,0)
    end
    local pods=joint(root,"WeaponPods")
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
    local size=self.body:GetVar("VehicleSize"):GetVector3()
    local fallback={localOffset=V(0,math.max(1.1,size.y+0.25),size.z*0.06),pitch=4,fov=74,
        seatHeight=math.max(0.8,size.y*0.55),grip=V(.3,1,.4),dash=V(0,size.y*.85,size.z*.10),
        dashSize=Vector2(.72,.24),dashboardAngle=-10,accent=Color(.16,.22,.27)}
    self.Cockpit=M.Cockpits[id] or fallback
    self.firstPerson,self.disposed,self.leanSign=false,false,1
    self.parts,self.materials=configureCockpitMaterials()
    if id=="ebike" then
        -- 普通摩托的构建函数在这里延迟require，避免 Bike -> MixedVisuals 循环require。
        local Bike=require("Bike")
        self.cockpit=self.visual:CreateChild("Cockpit")
        self.steering=self.cockpit:CreateChild("Steering")
        self.steering.position=V(0,self.Cockpit.grip.y,self.Cockpit.grip.z+.09)
        self.classId="ebike"
        self.hands,self.rpmBars={},{}
        self.spin,self.visualClock,self.rearSpin=0,0,0
        self.mirrors=require("RearMirrors").New(scene,self.node,self.Cockpit.localOffset.y)
        self.dashboard=self.cockpit:CreateChild("DashboardAnchor")
        self.dashboard.position=self.Cockpit.dash
        self.dashboard.rotation=Quaternion(self.Cockpit.dashboardAngle,0,0)
        Bike.BuildCockpit(self --[[@as Bike]])
        -- BuildCockpit按右握把镜像生成；左侧整体补偿原模型实测的-6cm高/-6.3cm后移。
        local delta=M.RiderBindings.ebike.left-V(-self.Cockpit.grip.x,self.Cockpit.grip.y,self.Cockpit.grip.z)
        for _,name in ipairs({"LeftMirror","LeftGlove","ClutchLever"}) do
            local part=self.steering:GetChild(name)
            if part then part.position=part.position+delta end
        end
        for _,hand in ipairs(self.hands) do
            if hand.side==-1 then
                hand.grip=hand.grip+delta
                hand.elbow=hand.elbow+delta
                for _,part in ipairs({hand.forearm,hand.cuff,hand.stripe}) do
                    if part then part.position=part.position+delta end
                end
            end
        end
        -- 原始车把保持可见。附加座舱只有手/仪表/镜，绝不旋转原握把。
        ---@diagnostic disable-next-line: param-type-mismatch
        Bike.BuildSmoke(self --[[@as Bike]])
        self.effects={pitch=0,bob=0,Dispose=function() end}
    else
        buildGenericControls(self,id)
        self.mirrors=require("RearMirrors").New(scene,self.node,self.Cockpit.localOffset.y)
        self.effects={pitch=0,bob=0,Dispose=function() end}
    end
    self.skillEffects=require("NewVehicleSkillEffects").New(self.visual,id,self.Cockpit.localOffset.y,size.z)
    if self.skillEffects then
        -- 首视角边缘效果按真实座舱眼位放置，不能假定车心原点。
        self.skillEffects:SetEyePosition(self.Cockpit.localOffset)
    end
    local riderRig=M.CreateRider(self.visual,id)
    self.riderRig=riderRig
        or {visible=false,disposed=false,SetColor=function() return false end,SetVisible=function() end,
            Update=function() end,Dispose=function(rig) rig.disposed=true end}
    self.riderRig:SetColor("red")
    ---@type StaticModel[]
    self.firstPersonMeshes=self.firstPersonMeshes or {}
    self.visualClock=self.visualClock or 0
    self.spin=self.spin or 0
    -- 后视相机不穿过宽体车尾；跟随高度但不跟随驾驶控制旋转。
    self.rearCameraHeight=self.Cockpit.localOffset.y
    self.rearCameraZ=-size.z*.5-.20
    self.mirrors.cameraNode.position=V(0,self.rearCameraHeight,self.rearCameraZ)
    local RearMirrors=require("RearMirrors")
    for _,draw in ipairs(self.cockpit:GetComponents("StaticModel",true)) do
        draw.viewMask=RearMirrors.COCKPIT_MASK
        draw.castShadows=false
    end
    self:SetFirstPerson(false)
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
    self.cockpit:SetEnabledRecursive(self.firstPerson)
end
function Adapter:SetQuality(high)
    if self.disposed then return end
    self.mirrors:SetQuality(high==true)
    for _,draw in ipairs(self.body:GetComponents("StaticModel",true)) do draw.lodBias=high and 2 or 1 end
end
function Adapter:UpdateMirrors(dt,active)
    if self.disposed then return end
    self.mirrors:Update(dt,active and self.firstPerson)
end
function Adapter:GetDashboardWorldPosition() return self.dashboardMarker.worldPosition end
function Adapter:GetCameraWorldPosition() return self.visual:LocalToWorld(self.Cockpit.localOffset) end
function Adapter:GetGrabWorldPosition()
    if self.vehicleId~="beetle" then return nil end
    return require("MixedArticulation").GetGrabWorldPosition(self.body)
end
function Adapter:UpdateState(dt,sim,firstPerson,clock)
    if self.disposed then return end
    local step=sim.paused==true and 0 or math.max(0,dt)
    self.visualClock=self.visualClock+step
    self.node.position=V(sim.x or 0,sim.y or 0,sim.z or 0)
    self.node.rotation=Quaternion(0,sim.heading or sim.yaw or 0,0)
    local spin=sim.airSpin or 0
    -- Simulation正pitch为抬头，UrhoX正X旋转朝下；保留完整角度。
    local pitch=-(sim.pitch or sim.wheelieAngle or 0)
    local lean=(sim.lean or 0)*.25
    local tumble=self.tumble or 0
    if tumble>0 then
        self.tumble=math.max(0,tumble-step)
        pitch=pitch+math.sin(tumble*22)*34*math.min(1,tumble)
        lean=lean+math.cos(tumble*19)*30*math.min(1,tumble)
    end
    self.visual.rotation=Quaternion(pitch,spin,lean)
    local lift=0
    if self.vehicleId=="ebike" and (sim.wheelieAngle or 0)>0 and not sim.airborne then
        -- 侧视：后轮圆心 Q*C 的高度 + lift = radius，轮胎下缘严格贴地。
        -- 不用.72近似臂长，不把前轮再压入路面；空中仍由Simulation.y控制。
        local c=self.Cockpit
        local rotation=self.visual.rotation
        local rearCenter=rotation*c.rearCenter
        local rearRadius=c.rearRadius
        lift=rearRadius-rearCenter.y
    end
    self.visual.position=V(0,(sim.oddAltitude or 0)+lift,0)
    M.Animate(self.body,self.vehicleId,sim.elapsed or clock or self.visualClock,sim)
    if self.skillEffects then self.skillEffects:Update(step,sim) end
    if self.vehicleId=="ebike" then
        -- 里程只驱动滚动；烧胎只额外驱动后轮，刹住的前轮保持原角。
        self.rearSpin=((self.rearSpin or 0)+(sim.burnout and 1900 or 0)*step)%360
        self.spin=self.rearSpin
        local rear=self.body:GetChild("RearWheel",true)
        if rear then
                rear.rotation=Quaternion(((sim.distance or 0)/.264*180/math.pi+self.rearSpin)%360,ebikeWheelAxis)
        end
        for _,hand in ipairs(self.hands) do
            local pull=hand.side==1 and (sim.braking==true or sim.brake==true)
                or (hand.side==-1 and sim.clutch==true)
            hand.lever.rotation=Quaternion(0,pull and -hand.side*12 or 0,0)
        end
        if step>0 then require("Bike").UpdateSmoke(self --[[@as Bike]],step,math.max(sim.tireSmoke or 0,sim.burnout and 1 or 0)) end
    else
        self.steering.rotation=Quaternion(0,(sim.steer or 0)*8,0)
    end
    self.mirrors.cameraNode.position=V(0,self.rearCameraHeight+(sim.oddAltitude or 0),self.rearCameraZ)
    self.riderRig:Update(0,false,lean)
    if firstPerson ~= self.firstPerson then self:SetFirstPerson(firstPerson) end
    for i,bar in ipairs(self.rpmBars or {}) do
        local redline=sim.vehicle and sim.vehicle.redline or 11000
        bar.enabled=self.firstPerson and i<=math.ceil(math.max(0,math.min(1,(sim.rpm or 0)/redline))*8)
    end
end
function Adapter:Dispose()
    if self.disposed then return end
    self.disposed=true
    self.mirrors:Dispose()
    self.effects:Dispose()
    if self.skillEffects then self.skillEffects:Dispose() end
    self.riderRig:Dispose()
    for _,particle in ipairs(self.smoke or {}) do particle.node:Dispose();particle.mat:Dispose() end
    self.node:Dispose()
    for _,mat in pairs(self.materials) do mat:Dispose() end
end
return M
