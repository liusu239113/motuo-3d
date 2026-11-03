-- 基于第三人称角色脚手架的世界节点/模型节点分离结构。
-- 第三人称与头盔视角均保留原始车身；近景座舱只补控制件、双手及动态后视画面。
local P = require("Parts")
local RearMirrors = require("RearMirrors")
local Rider = require("Rider")
local RideEffects = require("RideEffects")
---@type VehicleAssetLibrary
local Assets = require("VehicleAssets")
local V = Vector3

---@class BikeCockpitConfig
---@field localOffset Vector3 相机相对Bike.visual的偏移（不跟随车把转向）
---@field pitch number 正值向下看
---@field fov number 垂直视野角度
---@field grip Vector3 右握把；左握把镜像X
---@field dash Vector3 仪表在Bike.visual的本地坐标
---@field dashSize Vector2 可读仪表面的实物宽高
---@field seatHeight number
---@field torsoTilt number
---@field accent Color
---@field dashboardAngle number

---@class Bike
local Bike = {}
Bike.__index = Bike

---@type table<string, BikeCockpitConfig>
Bike.Cockpits = {
    sport = {localOffset = V(0, 1.46, -0.35), pitch = 8, fov = 72,
        grip = V(0.34, 1.015, 0.31), dash = V(0, 1.105, 0.62), dashSize = Vector2(0.30, 0.15),
        seatHeight = 0.86, torsoTilt = 32, accent = Color(0.85, 0.10, 0.055), dashboardAngle = -22},
    cruiser = {localOffset = V(0, 1.65, -0.39), pitch = 5, fov = 72,
        grip = V(0.50, 1.39, 0.19), dash = V(0, 1.245, 0.45), dashSize = Vector2(0.23, 0.13),
        seatHeight = 0.86, torsoTilt = 12, accent = Color(0.10, 0.34, 0.36), dashboardAngle = -24},
    rally = {localOffset = V(0, 1.66, -0.39), pitch = 5, fov = 72,
        grip = V(0.42, 1.20, 0.36), dash = V(0, 1.245, 0.70), dashSize = Vector2(0.28, 0.15),
        seatHeight = 0.94, torsoTilt = 20, accent = Color(0.65, 0.48, 0.22), dashboardAngle = -22},
}

-- 归一化MDL实际接触点（2026-10-28量测），握把中心从外侧把端内收约7cm。
Bike.Cockpits.sport_2 = {localOffset = V(0, 1.80, -0.25), pitch = 8, fov = 72,
    grip = V(0.47, 1.243, 0.253), dash = V(0, 1.35, 0.51), dashSize = Vector2(0.30, 0.15),
    seatHeight = 1.203, torsoTilt = 32, accent = Color(0.10, 0.34, 0.85), dashboardAngle = -22}
Bike.Cockpits.sport_3 = {localOffset = V(0, 1.72, -0.25), pitch = 8, fov = 72,
    grip = V(0.47, 1.197, 0.263), dash = V(0, 1.30, 0.52), dashSize = Vector2(0.30, 0.15),
    seatHeight = 1.125, torsoTilt = 32, accent = Color(0.62, 0.64, 0.68), dashboardAngle = -22}
Bike.Cockpits.cruiser_2 = {localOffset = V(-0.09, 1.90, -0.34), pitch = 5, fov = 72,
    grip = V(0.64, 1.585, 0.118), dash = V(-0.09, 1.48, 0.35), dashSize = Vector2(0.23, 0.13),
    seatHeight = 1.00, torsoTilt = 12, accent = Color(0.62, 0.045, 0.025), dashboardAngle = -24}
Bike.Cockpits.cruiser_3 = {localOffset = V(0, 1.94, -0.38), pitch = 5, fov = 72,
    grip = V(0.479, 1.546, 0.283), dash = V(0, 1.41, 0.48), dashSize = Vector2(0.23, 0.13),
    seatHeight = 1.075, torsoTilt = 12, accent = Color(0.12, 0.32, 0.19), dashboardAngle = -24}
Bike.Cockpits.rally_2 = {localOffset = V(0, 1.85, -0.30), pitch = 5, fov = 72,
    grip = V(0.488, 1.386, 0.283), dash = V(0, 1.40, 0.55), dashSize = Vector2(0.28, 0.15),
    seatHeight = 1.095, torsoTilt = 20, accent = Color(0.78, 0.80, 0.82), dashboardAngle = -22}
Bike.Cockpits.rally_3 = {localOffset = V(0, 2.09, -0.28), pitch = 5, fov = 72,
    grip = V(0.445, 1.653, 0.347), dash = V(0, 1.64, 0.59), dashSize = Vector2(0.28, 0.15),
    seatHeight = 1.30, torsoTilt = 20, accent = Color(0.83, 0.65, 0.08), dashboardAngle = -22}

-- 新车型按实际MDL归一化侧面/握把位置独立标定，不把完整vehicleId覆盖成classId。
-- 类别默认配置只用于动作风格；座舱接触点以完整车型ID为准。
---@param vehicleId string
---@return BikeCockpitConfig
function Bike.GetCockpit(vehicleId)
    return assert(Bike.Cockpits[vehicleId] or Bike.Cockpits[Rider.ClassFor(vehicleId)],
        "Unsupported bike cockpit: " .. vehicleId)
end

---@param scene Scene
---@param vehicleId? string
---@return Bike
function Bike.New(scene, vehicleId)
    if require("MixedVehicles").Get(vehicleId) then return require("MixedVisuals").NewBike(scene,vehicleId) --[[@as Bike]] end
    local self = setmetatable({}, Bike)
    self:Init(scene, vehicleId or "sport")
    return self
end

---@param parent Node
---@param mat Material
---@param a Vector3
---@param b Vector3
---@param radius number
---@return Node
local function limb(parent, mat, a, b, radius)
    local delta = b - a
    return P.Add(parent, "Sleeve", "Sphere", mat, (a + b) * 0.5,
        V(radius * 2, radius * 2, delta:Length() + radius), Quaternion(Vector3.FORWARD, delta:Normalized()))
end

---@param node Node
---@param a Vector3
---@param b Vector3
---@param radius number
local function setLimb(node, a, b, radius)
    local delta = b - a
    node.position = (a + b) * 0.5
    node.rotation = Quaternion(Vector3.FORWARD, delta:Normalized())
    node.scale = V(radius * 2, radius * 2, delta:Length() + radius)
end

---@param scene Scene
---@param vehicleId string
function Bike:Init(scene, vehicleId)
    local classId = Rider.ClassFor(vehicleId)
    assert(Bike.Cockpits[classId], "Unsupported bike class: " .. vehicleId)
    assert(Assets.Vehicles[vehicleId], "Bike asset not available: " .. vehicleId)
    self.vehicleId, self.classId = vehicleId, classId
    self.Cockpit = Bike.GetCockpit(vehicleId)
    self.node = scene:CreateChild("Bike_" .. vehicleId)
    self.visual = self.node:CreateChild("LeanAndStunt")
    self.body = Assets.Add(self.visual, vehicleId)
    self.cockpit = self.visual:CreateChild("HelmetCockpit")
    self.steering = self.cockpit:CreateChild("SteeringAssembly")
    self.steering.position = V(0, self.Cockpit.grip.y, self.Cockpit.grip.z + 0.09)
    self.dashboard = self.cockpit:CreateChild("DashboardAnchor")
    self.dashboard.position = self.Cockpit.dash
    self.dashboard.rotation = Quaternion(self.Cockpit.dashboardAngle, 0, 0)
    self.spin, self.lean, self.steerAngle, self.visualClock = 0, 0, 0, 0
    self.firstPerson = false
    self.wheels = {}
    self.hands = {}
    self.rpmBars = {}
    self.disposed = false
    ---@type RearMirrors
    self.mirrors = RearMirrors.New(scene, self.node, self.Cockpit.localOffset.y)
    self.leanSign = (Quaternion(0, 0, 10) * V(0, 1, 0)).x > 0 and 1 or -1
    local a = self.Cockpit.accent
    self.materials = {
        paint = P.Material(a.r, a.g, a.b, 0.58, 0.04),
        black = P.Material(0.022, 0.028, 0.034, 0.86, 0),
        rubber = P.Material(0.018, 0.022, 0.025, 0.92, 0),
        jacket = P.Material(0.034, 0.042, 0.052, 0.95, 0),
        glove = P.Material(0.024, 0.027, 0.031, 0.92, 0),
        armor = P.Material(0.047, 0.052, 0.058, 0.72, 0),
        stitch = P.Material(0.24, 0.27, 0.28, 0.96, 0),
        chrome = P.Material(0.40, 0.43, 0.45, 0.42, 0.55),
        gold = P.Material(0.42, 0.31, 0.13, 0.46, 0.45),
        white = P.Material(0.77, 0.80, 0.79, 0.54),
        visor = P.Material(0.035, 0.085, 0.12, 0.18, 0.5),
        screen = P.Material(0.008, 0.016, 0.021, 0.94),
        green = P.Material(0.12, 0.63, 0.36, 0.5, 0, 0.35),
        amber = P.Material(0.92, 0.45, 0.06, 0.5, 0, 0.4),
    }
    for _, key in ipairs({"black", "rubber", "jacket", "glove", "armor", "stitch", "screen"}) do
        self.materials[key]:SetShaderParameter("MatSpecColor", Variant(Color(0.025, 0.025, 0.025, 16)))
    end
    self.materials.chrome:SetShaderParameter("MatSpecColor", Variant(Color(0.20, 0.20, 0.20, 32)))
    self.tailMat = P.Material(0.65, 0.015, 0.008, 0.4, 0, 1)
    self:BuildCockpit()
    self:BuildRider()
    self:BuildSmoke()
    self.effects = RideEffects.New(self.visual, Assets.Vehicles[vehicleId].targetSize, self.Cockpit.seatHeight)
    -- 只把附加近景控制件划入专用mask；真实车身不分层、不全局隐藏。
    for _, drawable in ipairs(self.cockpit:GetComponents("StaticModel", true)) do
        drawable.viewMask = RearMirrors.COCKPIT_MASK
        -- 近眼手部细件不单独投射阴影，避免几十次小物件阴影绘制。
        drawable.castShadows = false
    end
    self:SetFirstPerson(false)
    print("[摩托] " .. Assets.Vehicles[vehicleId].label .. "：原始车身保留，程序化近景手套/仪表与低频后视摄像头已创建")
end

function Bike:BuildCockpit()
    local m, c = self.materials, self.Cockpit
    local origin = self.steering.position
    local chrome = self.classId == "cruiser" and m.chrome or m.black
    P.Add(self.steering, "UpperYoke", RoundedBoxGeometry(0.36, 0.035, 0.11, 3, 0.015):ToModel(), m.chrome, V(0, -0.025, 0.02))
    for side = -1, 1, 2 do
        P.Add(self.steering, "ForkAdjuster", "Cylinder", m.gold, V(side * 0.13, 0.002, 0.025), V(0.052, 0.018, 0.052))
        local grip = V(side * c.grip.x, c.grip.y, c.grip.z) - origin
        local path
        if self.classId == "cruiser" then
            path = {V(0, -0.06, 0.04), V(side * 0.20, 0.015, 0.045), grip + V(-side * 0.10, 0, 0.09), grip + V(side * 0.07, 0, -0.035)}
        elseif self.classId == "rally" then
            path = {V(0, -0.025, 0.025), V(side * 0.18, 0.02, 0.02), grip + V(-side * 0.12, 0, 0.03), grip + V(side * 0.07, 0, 0)}
        else
            path = {V(side * 0.13, -0.025, 0.035), V(side * 0.23, -0.02, 0.01), grip + V(-side * 0.08, 0, 0.02), grip + V(side * 0.07, 0, -0.01)}
        end
        P.Add(self.steering, "BentHandlebar", TubeGeometry(path, 24, 0.014, 10):ToModel(), chrome)
        P.Add(self.steering, "RubberGrip", "Cylinder", m.rubber, grip, V(0.05, 0.145, 0.05), Quaternion(0, 0, 90))
        P.Add(self.steering, "BarEndWeight", "Cylinder", m.chrome, grip + V(side * 0.09, 0, 0), V(0.055, 0.025, 0.055), Quaternion(0, 0, 90))
        for j = 1, 7 do
            P.Add(self.steering, "GripRib", "Cylinder", m.black, grip + V((j - 4) * 0.017, 0, 0), V(0.052, 0.004, 0.052), Quaternion(0, 0, 90))
        end
        P.Add(self.steering, "SwitchPod", RoundedBoxGeometry(0.075, 0.065, 0.075, 2, 0.014):ToModel(), m.black, grip + V(-side * 0.105, 0.006, 0))
        P.Add(self.steering, "KillOrIndicatorSwitch", "Box", side == 1 and m.paint or m.green, grip + V(-side * 0.11, 0.043, -0.012), V(0.032, 0.013, 0.024))
        P.Add(self.steering, "Reservoir", RoundedBoxGeometry(0.075, 0.045, 0.06, 2, 0.009):ToModel(), m.black, grip + V(-side * 0.16, 0.047, 0.06))
        P.Add(self.steering, "ReservoirCap", "Box", m.chrome, grip + V(-side * 0.16, 0.074, 0.06), V(0.065, 0.008, 0.053))
        local lever = self.steering:CreateChild(side == 1 and "FrontBrakeLever" or "ClutchLever")
        lever.position = grip + V(-side * 0.10, 0, 0.07)
        local leverPath = {V(0, 0, 0), V(side * 0.07, 0.006, 0.018), V(side * 0.16, 0, -0.008), V(side * 0.19, 0, -0.025)}
        P.Add(lever, "CurvedLever", TubeGeometry(leverPath, 18, 0.008, 8):ToModel(), m.chrome)
        P.Add(lever, "LeverBall", "Sphere", m.chrome, V(side * 0.19, 0, -0.025), V(0.026, 0.026, 0.026))
        local hose = {grip + V(-side * 0.12, -0.01, 0.07), V(side * 0.16, -0.18, 0.17), V(side * 0.09, -0.32, 0.30)}
        P.Add(self.steering, "HydraulicCable", TubeGeometry(hose, 20, 0.005, 6):ToModel(), m.rubber)
        if self.classId == "rally" then
            local shield = {grip + V(-side * 0.12, 0, 0.12), grip + V(0, 0.035, 0.15), grip + V(side * 0.12, 0, 0.08)}
            P.Add(self.steering, "HandguardBrace", TubeGeometry(shield, 18, 0.012, 8):ToModel(), m.chrome)
            P.Add(self.steering, "Handguard", "Sphere", m.paint, grip + V(0, 0.028, 0.15), V(0.21, 0.09, 0.042))
        end
        -- 巡航直接覆盖原整车圆镜的后表面，不在前方再立第二对镜杆/镜壳。
        local mirrorPos = self.classId == "cruiser" and V(side * 0.58, 1.59, 0.20) - origin
            or V(side * (c.grip.x + 0.06), c.grip.y + 0.25, c.grip.z + 0.23) - origin
        if self.classId ~= "cruiser" then
            P.Bar(self.steering, m.black, grip + V(-side * 0.12, 0.01, 0.06), mirrorPos, 0.009)
        end
        -- 平面镜片位于镜壳后，不拿压扁球体的高光冒充后视画面。
        local mirror = self.steering:CreateChild(side == 1 and "RightMirror" or "LeftMirror")
        mirror.position = mirrorPos
        mirror.rotation = Quaternion(-10, side * -6, 0)
        if self.classId == "cruiser" then
            self.mirrors:AddFace(mirror, V(0, 0, -0.065), 0.17, 0.16)
        else
            P.Add(mirror, "MirrorHousing", RoundedBoxGeometry(0.196, 0.106, 0.027, 3, 0.012):ToModel(), m.black)
            self.mirrors:AddFace(mirror, V(0, 0, -0.015), 0.174, 0.087)
        end
        local glove = self.steering:CreateChild(side == 1 and "RightGlove" or "LeftGlove")
        glove.position = grip
        -- 仍为程序化手套，不宣称下载角色模型。分离皮革、硬质护甲、缝线材质。
        P.Add(glove, "GlovePalm", RoundedBoxGeometry(0.103, 0.052, 0.095, 3, 0.022):ToModel(), m.glove, V(0, 0.024, -0.018))
        P.Add(glove, "BackHandPanel", RoundedBoxGeometry(0.088, 0.018, 0.061, 3, 0.009):ToModel(), m.jacket, V(0, 0.051, -0.019))
        for finger = 1, 4 do
            local x = (finger - 2.5) * 0.023
            P.Add(glove, "KnuckleArmor", RoundedBoxGeometry(0.021, 0.015, 0.026, 2, 0.006):ToModel(), m.armor,
                V(x, 0.055, 0.010))
            P.Add(glove, "FingerTop", "Sphere", m.glove, V(x, 0.023, 0.033), V(0.021, 0.036, 0.056), Quaternion(18, 0, 0))
            P.Add(glove, "FingerUnderGrip", "Sphere", m.glove, V(x, -0.018, 0.018), V(0.021, 0.022, 0.043), Quaternion(-35, 0, 0))
            P.Add(glove, "FingerFlexSeam", "Box", m.stitch, V(x, 0.036, 0.040), V(0.015, 0.002, 0.002), nil, false)
        end
        local seam = {V(-0.043, 0.051, -0.057), V(-0.046, 0.052, -0.023), V(-0.034, 0.050, 0.013)}
        P.Add(glove, "LeatherEdgeStitch", TubeGeometry(seam, 10, 0.0016, 4):ToModel(), m.stitch)
        P.Add(glove, "WrappedThumb", "Sphere", m.glove, V(-side * 0.049, -0.009, -0.012), V(0.029, 0.033, 0.067), Quaternion(0, side * -28, 0))
        P.Add(glove, "WristClosure", RoundedBoxGeometry(0.093, 0.045, 0.031, 2, 0.010):ToModel(), m.glove, V(0, 0.002, -0.077))
        P.Add(glove, "WristClosureTab", "Box", m.armor, V(side * 0.035, 0.023, -0.076), V(0.025, 0.006, 0.023), nil, false)
        local elbow = V(side * 0.40, c.grip.y - 0.12, c.grip.z - 0.43)
        local target = V(side * c.grip.x, c.grip.y, c.grip.z)
        local forearm = limb(self.cockpit, m.jacket, elbow, target - V(0, 0, 0.04), 0.054)
        local cuff = limb(self.cockpit, m.glove, target - V(0, 0, 0.13), target - V(0, 0, 0.055), 0.049)
        local stripe = limb(self.cockpit, m.stitch, elbow + V(0, 0.048, 0), target + V(0, 0.025, -0.11), 0.0025)
        self.hands[#self.hands + 1] = {side = side, forearm = forearm, cuff = cuff, stripe = stripe, elbow = elbow, grip = target, lever = lever}
    end
    -- 原车把属于单体MDL，不能单独隐藏：近景不再叠第二套横把/三角台/油壶。
    -- 保留覆盖在真实握把附近的手套、离合/刹车动作和后视镜安装。
    local duplicateParts = {UpperYoke = true, ForkAdjuster = true, BentHandlebar = true,
        RubberGrip = true, BarEndWeight = true, GripRib = true, SwitchPod = true,
        KillOrIndicatorSwitch = true, Reservoir = true, ReservoirCap = true, HydraulicCable = true,
        Handguard = true, HandguardBrace = true}
    for _, part in ipairs(self.steering:GetChildren(false)) do
        if duplicateParts[part.name] then part:Dispose() end
    end
    local s = c.dashSize
    local frame = RoundedBoxGeometry(s.x + 0.045, s.y + 0.04, 0.045, 3, 0.025):ToModel()
    P.Add(self.dashboard, "InstrumentBezel", frame, self.classId == "cruiser" and m.chrome or m.black)
    P.Add(self.dashboard, "DarkReadableFace", RoundedBoxGeometry(s.x, s.y, 0.012, 3, 0.014):ToModel(), m.screen, V(0, 0, -0.026))
    for i = 1, 8 do
        self.rpmBars[i] = P.Add(self.dashboard, "RPMBar", "Box", i > 6 and m.amber or m.green,
            V((i - 4.5) * 0.027, s.y * 0.35, -0.034), V(0.018, 0.008, 0.004), nil, false)
    end
    if self.classId == "rally" then
        P.Add(self.cockpit, "RallyNavigationMount", "Box", m.black, c.dash + V(0, -0.14, 0.06), V(0.10, 0.12, 0.05))
    end
    -- 父HUD投影此精确前表面锚点，作为速度数字中心。
    self.dashboardMarker = self.dashboard:CreateChild("SpeedProjectionAnchor")
    self.dashboardMarker.position = V(0, -0.01, -0.038)
    -- 不再创建假油箱/油箱盖：原始车身在第一人称同样可见。
end

function Bike:BuildRider()
    self.riderRig = Rider.New(self.visual, self.vehicleId, self.Cockpit.grip)
    -- 保留对第三人称容器的外部兼容引用，实际网格为单个AnimatedModel。
    self.rider = self.riderRig.node
    P.Add(self.visual, "BrakeLamp", "Box", self.tailMat,
        V(0, self.Cockpit.seatHeight + 0.04, -0.98), V(0.18, 0.035, 0.018), nil, false)
end

-- 一次分配固定小粒子池；烟雾保留世界位置，不随车瞬移，每帧只改位置/透明度。
function Bike:BuildSmoke()
    self.smokeRoot = self.node:CreateChild("BurnoutSmokePool")
    self.smoke = {}
    self.smokeCursor, self.smokeAccumulator = 1, 0
    local model = SphereGeometry(0.5, 12, 8):ToModel()
    for i = 1, 18 do
        local mat = Material:new()
        mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
        mat:SetShaderParameter("MatDiffColor", Variant(Color(0.58, 0.61, 0.64, 0)))
        mat:SetShaderParameter("Roughness", Variant(1.0))
        local node = P.Add(self.smokeRoot, "TyreSmoke", model, mat, V(0, -5, 0), V.ONE, nil, false)
        node.enabled = false
        self.smoke[i] = {node = node, mat = mat, age = 2.0, life = 1.4, position = V.ZERO, velocity = V.ZERO}
    end
end

---@param dt number
---@param intensity number
function Bike:UpdateSmoke(dt, intensity)
    self.smokeAccumulator = self.smokeAccumulator + math.min(1, intensity) * dt * 16
    if self.smokeAccumulator >= 1 then
        self.smokeAccumulator = self.smokeAccumulator % 1
        local particle = self.smoke[self.smokeCursor]
        self.smokeCursor = self.smokeCursor % #self.smoke + 1
        particle.age = 0
        particle.position = self.node:LocalToWorld(V(0, 0.10, -0.76))
        particle.velocity = self.node.worldRotation * V(math.sin(self.spin) * 0.24, 0.45, -0.30)
        particle.node.enabled = true
    end
    for _, particle in ipairs(self.smoke) do
        particle.age = particle.age + dt
        if particle.age < particle.life then
            local t = particle.age / particle.life
            particle.position = particle.position + particle.velocity * dt
            particle.node.worldPosition = particle.position
            local size = 0.14 + t * 0.68
            particle.node:SetWorldScale(V(size, size * 0.85, size))
            local alpha = math.min(1, t * 8) * (1 - t) * 0.36
            particle.mat:SetShaderParameter("MatDiffColor", Variant(Color(0.58, 0.61, 0.64, alpha)))
        else
            particle.node.enabled = false
        end
    end
end

---@param colorId string
---@return boolean
function Bike:SetRiderColor(colorId)
    return self.riderRig:SetColor(colorId)
end

---@param firstPerson boolean
function Bike:SetFirstPerson(firstPerson)
    self.firstPerson = firstPerson
    self.riderRig:SetVisible(not firstPerson)
    self.body:SetEnabledRecursive(true)
    self.cockpit:SetEnabledRecursive(firstPerson)
end

---@param high boolean
function Bike:SetQuality(high)
    self.mirrors:SetQuality(high == true)
    -- 玩家近景保留分区材质；流畅档只降低模型LOD偏好，不换回混合材质。
    Assets.SetDetail(self.body, high == true and "hero" or "balanced")
end

---@param dt number
---@param active boolean 主流程只在ride且首视角时开启，暂停/菜单/追尾均停更
function Bike:UpdateMirrors(dt, active)
    self.mirrors:Update(dt, active and self.firstPerson and not self.disposed)
end

function Bike:Dispose()
    if self.disposed then return end
    self.disposed = true
    self.mirrors:Dispose()
    self.effects:Dispose()
    self.riderRig:Dispose()
    self.node:Dispose()
end

---@return Vector3
function Bike:GetDashboardWorldPosition()
    return self.dashboardMarker.worldPosition
end

---@return Vector3
function Bike:GetCameraWorldPosition()
    return self.visual:LocalToWorld(self.Cockpit.localOffset)
end

---@param dt number
---@param sim table 世界x/y/z为米；heading、wheelieAngle、airSpin为度
---@param firstPerson boolean
---@param clock number
function Bike:UpdateState(dt, sim, firstPerson, clock)
    if self.disposed then return end
    local frameTime = sim.paused == true and 0 or math.max(0, dt)
    self.visualClock = self.visualClock + frameTime
    local speed, steer = sim.speed or 0, sim.steer or 0
    -- raceBoost为Simulation动力实际授权强度，不是按键、氮气储量或臆造倒计时。
    -- 加速带是独立的成功gain脉冲，既不借用raceBoost授权，也不改变氮气储量/动力。
    local featureState = sim.featureState
    local padPower = featureState and featureState.feedbackPower or 0
    self.effects:Update(frameTime, sim.raceBoost or 0, speed, padPower)
    self.node.position = V(sim.x or 0, sim.y or 0, sim.z or 0)
    self.node.rotation = Quaternion(0, sim.heading or 0, 0)
    -- 车身倾角随车速逐步建立，外圈输入允许明确压弯，低速不倒车。
    -- 仍绕轮胎接地点的纵向轴旋转，不缩放人物或把躯干压扁冒充压弯。
    local leanLimit = self.classId == "sport" and 52 or self.classId == "rally" and 44 or 36
    local leanAmount = math.abs(steer)
    local leanShape = (steer < 0 and -1 or 1) * (0.35 * leanAmount + 0.65 * math.sqrt(leanAmount))
    local targetLean = leanShape * leanLimit * math.min(1, math.abs(speed) / 15)
        * (1 - (sim.wheelie or 0) * 0.75) * self.leanSign
    self.lean = self.lean + (targetLean - self.lean) * (1 - math.exp(-frameTime / 0.15))
    self.steerAngle = self.steerAngle + (steer * math.max(4, 22 - math.abs(speed) * 0.35) - self.steerAngle) * math.min(1, frameTime * 12)
    -- 新六车的握把属于单体MDL，不能独立转动。手与近景控制件保持真实把位，
    -- 转弯仍由世界yaw与整车lean表现，不让手臂离开静态模型上的握把。
    if self.vehicleId ~= self.classId then self.steerAngle = 0 end
    local brake = sim.brake or sim.braking or false
    local wheelie = sim.wheelieAngle or 0
    local spin = sim.airSpin or 0
    -- pitch由Simulation含地形坡度/抬头合成；stuntAngle仅是累计偏航记录，不能当俯仰角。
    local pitch = -(sim.pitch or wheelie) + (brake and math.abs(speed) > 2 and 1.5 or 0)
    -- 撞击晃动：短促左右摇摆并绕纵轴侧偏，0.5秒内衰减回正；不改变仿真朝向与路线。
    local shake = (sim.hitShake or 0) * (sim.hitTimer or 0)
    local shakeRoll = math.sin(self.visualClock * 42) * 7 * shake
    local shakeYaw = math.sin(self.visualClock * 27 + 1.1) * 4 * shake
    self.visual.rotation = Quaternion(pitch + self.effects.pitch + shake * 3.5, spin + shakeYaw, self.lean + shakeRoll)
    -- 世界Y由Simulation给出车轮最低点；抬头时补偿绕后轮触地点的升高。
    local lift = wheelie > 0 and math.sin(math.rad(math.min(85, wheelie))) * 0.72 or 0
    self.visual.position = V(0, lift + math.sin(self.visualClock * 27)
        * math.min(math.abs(speed) / 55, 1) * 0.003 + self.effects.bob, 0)
    self.steering.rotation = Quaternion(0, self.steerAngle, 0)
    local origin = self.steering.position
    for _, hand in ipairs(self.hands) do
        local target = origin + self.steering.rotation * (hand.grip - origin)
        setLimb(hand.forearm, hand.elbow, target - V(0, 0, 0.04), 0.054)
        setLimb(hand.cuff, target - V(0, 0, 0.13), target - V(0, 0, 0.055), 0.049)
        setLimb(hand.stripe, hand.elbow + V(0, 0.048, 0), target + V(0, 0.025, -0.11), 0.0025)
        local pull = hand.side == 1 and (brake and 1 or 0) or (sim.clutch and 1 or 0)
        hand.lever.rotation = Quaternion(0, -hand.side * pull * 12, 0)
    end
    if firstPerson ~= self.firstPerson then self:SetFirstPerson(firstPerson) end
    local redline = (sim.vehicle and sim.vehicle.redline) or 11000
    local rpmRatio = math.min(1, math.max(0, (sim.rpm or 1200) / redline))
    for i, bar in ipairs(self.rpmBars) do bar.enabled = self.firstPerson and i <= math.ceil(rpmRatio * 8) end
    self.riderRig:Update(self.steerAngle, false, self.lean / self.leanSign)
    self.tailMat:SetShaderParameter("MatEmissiveColor", Variant(Color(brake and 3.2 or 0.7, 0.012, 0.006)))
    self.spin = (self.spin + (sim.burnout and 22 or speed) / 0.36 * frameTime * 180 / math.pi) % 360
    if frameTime > 0 then self:UpdateSmoke(frameTime, math.max(sim.tireSmoke or 0, sim.burnout and 1 or 0)) end
end

-- 保留旧直路调用，兼容尚未迁移到绝对世界坐标的入口。
function Bike:Update(dt, x, yaw, speed, steer, brake, firstPerson, clock)
    self:UpdateState(dt, {x = x, y = 0.065, z = 0, heading = yaw, speed = speed, steer = steer, brake = brake}, firstPerson, clock)
end

return Bike
