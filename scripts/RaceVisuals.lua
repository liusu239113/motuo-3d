-- 基于scaffold-3d-scene的Scene持有/父子节点结构；本模块只表现，不参与Race仿真或碰撞。
-- AI仅真实整车StaticModel + 全盔Rider；绝不构造完整Bike/座舱/镜面/烟雾。
local Assets = require("VehicleAssets")
local Rider = require("Rider")
local RideEffects = require("RideEffects")
local Bike = require("Bike") -- 只取Cockpits配置，不调用Bike.New。
local Landscape = require("Landscape")
local P = require("Parts")
local V = Vector3

---@class RaceVisualRunner
---@field id string
---@field vehicleId string
---@field colorId string
---@field node Node
---@field visual Node
---@field body Node
---@field models StaticModel[]
---@field rider Rider|table
---@field poseClock number
---@field lean number
---@field effects RideEffects
---@field active boolean
---@field wasInView boolean
---@field poseRefreshes number
---@field detailTier string

---@class RaceRouteMarker
---@field node Node
---@field s number
---@field x number
---@field z number

---@class RaceVisuals
---@field scene Scene?
---@field world table
---@field race table
---@field root Node?
---@field rosterRoot Node
---@field routeRoot Node
---@field runners table<string, RaceVisualRunner>
---@field materials Material[]
---@field markers RaceRouteMarker[]
---@field policeNode Node?
---@field policeBody Node?
---@field policeRed Node?
---@field policeBlue Node?
---@field policeMissingLogged boolean
---@field disposed boolean
---@field visible boolean
---@field clock number
---@field visibilityClock number
---@field highQuality boolean
---@field leanSign number
---@field redMaterial Material
---@field blueMaterial Material
---@field whiteMaterial Material
---@field blackMaterial Material
---@field steelMaterial Material
---@field yellowMaterial Material
---@field greenMaterial Material
local RaceVisuals = {}
RaceVisuals.__index = RaceVisuals

-- 主流程在VehicleAssets登记police后调用；避免模块require时抢先索引尚未接好的资源。
---@return string[]
function RaceVisuals.GetResources()
    local ids = {"sport", "cruiser", "rally"}
    if Assets.Vehicles.police then ids[#ids + 1] = "police" end
    local paths = Assets.ResourcesFor(ids)
    for _, path in ipairs(Rider.Resources) do paths[#paths + 1] = path end
    -- 尾喷仅程序化几何；两条Technique均为合法纯色PBR，Loader按明确类型校验。
    for _, path in ipairs(RideEffects.Resources) do
        paths[#paths + 1] = path
        Assets.ResourceTypes[path] = "Technique"
    end
    return paths
end

---@param scene Scene
---@param world table
---@param race table
---@param highQuality? boolean
---@return RaceVisuals
function RaceVisuals.New(scene, world, race, highQuality)
    local self = setmetatable({}, RaceVisuals)
    self:Init(scene, world, race, highQuality)
    return self
end

---@param scene Scene
---@param world table
---@param race table
---@param highQuality? boolean
function RaceVisuals:Init(scene, world, race, highQuality)
    self.scene, self.world, self.race = scene, world, race
    self.root = scene:CreateChild("RacePresentation", LOCAL)
    self.rosterRoot = self.root:CreateChild("RaceRivals", LOCAL)
    self.routeRoot = self.root:CreateChild("RaceCourseFurniture", LOCAL)
    self.runners, self.materials, self.markers = {}, {}, {}
    self.policeNode, self.policeBody, self.policeRed, self.policeBlue = nil, nil, nil, nil
    self.policeMissingLogged, self.disposed, self.visible = false, false, true
    self.clock, self.visibilityClock = 0, 0
    self.highQuality = highQuality == true
    self.leanSign = (Quaternion(0, 0, 10) * V.UP).x > 0 and 1 or -1
    local function material(r, g, b, roughness, metallic, emissive)
        local mat = P.Material(r, g, b, roughness, metallic, emissive)
        self.materials[#self.materials + 1] = mat
        return mat
    end
    self.steelMaterial = material(0.26, 0.31, 0.36, 0.42, 0.65)
    self.blackMaterial = material(0.018, 0.025, 0.035, 0.88, 0)
    self.whiteMaterial = material(0.91, 0.94, 0.96, 0.82, 0)
    self.yellowMaterial = material(1, 0.68, 0.04, 0.60, 0.02, 0.22)
    self.greenMaterial = material(0.08, 0.90, 0.52, 0.48, 0.02, 1.25)
    self.redMaterial = material(0.96, 0.025, 0.015, 0.30, 0.05, 2.3)
    self.blueMaterial = material(0.025, 0.20, 1, 0.30, 0.05, 2.3)
    self:BuildCourse()
    self:Reset()
    print("[竞速表现] 轻量对手、真实骨骼车手、起终门架和路线标记已创建")
end

---@param data table
---@return RaceVisualRunner
function RaceVisuals:CreateRunner(data)
    local id, vehicleId = data.id, data.vehicleId
    assert(Assets.Vehicles[vehicleId], "Race rival asset unavailable: " .. tostring(vehicleId))
    local odd = require("MixedVehicles").Get(vehicleId) ~= nil
    local cockpit = odd and {grip=V(.3,1,.4),seatHeight=1} or Bike.GetCockpit(vehicleId)
    local node = self.rosterRoot:CreateChild("RaceRival_" .. id, LOCAL)
    local visual = node:CreateChild("RivalLean", LOCAL)
    local body = Assets.Add(visual, vehicleId, nil, "distant")
    -- 混合模型自带适配座位的驾驶员，不套用摩托骨骼及其握把验证。
    local rider = odd and {poseFailures=0,model={updateInvisible=true,animationLodBias=0,
        drawDistance=260,shadowDistance=65,inView=true}, SetColor=function() end,
        Update=function() end,Dispose=function() end} or Rider.New(visual, vehicleId, cockpit.grip)
    local colorId = data.colorId or "red"
    rider:SetColor(colorId)
    -- Rider是手动41骨pose，无动画clip；必须保留其updateInvisible=true契约。
    -- inView是上一渲染帧结果，不能作为首次提交/重新启用的前置条件。
    rider.model.updateInvisible = true
    rider.model.animationLodBias = 0
    rider.model.drawDistance = 260
    rider.model.shadowDistance = 65
    local models = body:GetComponents("StaticModel", true)
    for _, model in ipairs(models) do
        model.drawDistance, model.shadowDistance = 320, 75
        model.lodBias = 0.75
    end
    Assets.SetDetail(body, "distant")
    local effects = RideEffects.New(visual, Assets.Vehicles[vehicleId].targetSize, cockpit.seatHeight, true)
    local runner = {id = id, vehicleId = vehicleId, colorId = colorId, node = node,
        visual = visual, body = body, rider = rider, models = models, poseClock = 0, lean = 0,
        effects = effects, active = false, wasInView = false, poseRefreshes = 0, detailTier = "distant"}
    self:RefreshPose(runner, data, true)
    return runner
end

-- 只在初始化/距离重启/进入视野读回接触点，不把昂贵骨骼验证放到每帧。
-- 如果Rider的pcall回退绑定站姿，立刻重试完整事务，且记录真正失败而非静默站立。
---@param runner RaceVisualRunner
---@param data table
---@param verify boolean
function RaceVisuals:RefreshPose(runner, data, verify)
    if require("MixedVehicles").Get(runner.vehicleId) then return end
    local steer = (data.steer or 0) * math.max(4, 22 - math.abs(data.speed or 0) * 0.35)
    if runner.vehicleId ~= Rider.ClassFor(runner.vehicleId) then steer = 0 end
    local before = runner.rider.poseFailures or 0
    runner.rider:Update(steer, true, runner.lean)
    if (runner.rider.poseFailures or 0) > before then
        runner.rider:Update(steer, true, runner.lean)
    end
    runner.poseClock = 0
    runner.poseRefreshes = runner.poseRefreshes + 1
    if verify then
        local rig=runner.rider --[[@as Rider]]
        local pose = rig:ReadPose()
        assert((pose.hip - rig.config.hip):Length() < 0.002, "AI rider left saddle: " .. runner.id)
        assert(pose.leftGripError < 0.008 and pose.rightGripError < 0.008, "AI rider lost handlebar: " .. runner.id)
        assert((pose.leftFoot - V(-runner.rider.config.foot.x, runner.rider.config.foot.y,
            runner.rider.config.foot.z)):Length() < 0.004, "AI rider stood up: " .. runner.id)
        if runner.rider.classId == "sport" then assert(pose.chestTilt > 50, "AI sport rider lost tuck") end
    end
end

function RaceVisuals:EnsurePolice()
    if self.policeNode then return end
    if not Assets.Vehicles.police then
        if not self.policeMissingLogged then
            self.policeMissingLogged = true
            print("[竞速表现] 等待VehicleAssets.police真实警车资源登记，不创建假警车")
        end
        return
    end
    self.policeNode = self.root:CreateChild("RacePursuitPolice", LOCAL)
    self.policeBody = Assets.Add(self.policeNode, "police")
    for _, model in ipairs(self.policeBody:GetComponents("StaticModel", true)) do
        model.drawDistance, model.shadowDistance = 360, 85
    end
    -- 闪烁灯片是警车模型上的表现附件，车辆本体始终来自真实资产。
    local roof = Assets.Vehicles.police.targetSize.y + 0.025
    self.policeRed = P.Add(self.policeNode, "PursuitRedFlash", "Box", self.redMaterial,
        V(-0.30, roof, 0), V(0.26, 0.055, 0.12), nil, false)
    self.policeBlue = P.Add(self.policeNode, "PursuitBlueFlash", "Box", self.blueMaterial,
        V(0.30, roof, 0), V(0.26, 0.055, 0.12), nil, false)
end

-- 环境结构为PBR基础几何，并非车辆资产。没有碰撞体，碰撞/检查点通过Race统一判定。
---@param s number
---@param name string
---@return Node
function RaceVisuals:CourseAnchor(s, name)
    local point, yaw, pitch = Landscape.TrafficPose(s, 0)
    local node = self.routeRoot:CreateChild(name, LOCAL)
    node.position, node.rotation = point, Quaternion(pitch, yaw, 0)
    self.markers[#self.markers + 1] = {node = node, s = s, x = point.x, z = point.z}
    return node
end

---@param parent Node
---@param name string
---@param mat Material
---@param pos Vector3
---@param scale Vector3
---@param rotation? Quaternion
function RaceVisuals:CoursePart(parent, name, mat, pos, scale, rotation)
    local node = P.Add(parent, name, "Box", mat, pos, scale, rotation, false)
    local model = node:GetComponent("StaticModel")
    model.drawDistance = 300
    return node
end

function RaceVisuals:BuildCourse()
    local startS = self.race.startS or 0
    local halfWidth = self.race.roadHalfWidth or ((Landscape.Roads and Landscape.Roads[1]) and Landscape.Roads[1].width) or 4.8
    local towerX = halfWidth + 1.5
    local gantry = self:CourseAnchor(startS, "RaceStartFinishGantry")
    -- 门架最内缘在真实沥青边缘1m以外；高度净空5.2m，不参与碰撞。
    for _, side in ipairs({-1, 1}) do
        self:CoursePart(gantry, "GantryFoot", self.blackMaterial, V(side * towerX, 0.16, 0), V(1.0, 0.32, 1.5))
        for _, z in ipairs({-0.45, 0.45}) do
            self:CoursePart(gantry, "GantryTower", self.steelMaterial, V(side * towerX, 2.8, z), V(0.23, 5.6, 0.23))
        end
        for height = 1, 5 do
            self:CoursePart(gantry, "GantryTowerBrace", self.whiteMaterial,
                V(side * towerX, height, 0), V(0.16, 0.12, 1.05), Quaternion(32, 0, 0))
        end
    end
    for _, z in ipairs({-0.45, 0.45}) do
        self:CoursePart(gantry, "GantryCrossbeam", self.steelMaterial, V(0, 5.5, z), V(towerX * 2 + 0.30, 0.30, 0.25))
    end
    local boardWidth = math.min(towerX * 2 - 0.8, halfWidth * 2 + 0.4)
    local boardCell = boardWidth / 20
    self:CoursePart(gantry, "FinishBoard", self.blackMaterial, V(0, 5.15, 0), V(boardWidth, 0.65, 0.19))
    for i = 1, 20 do
        self:CoursePart(gantry, "FinishBoardChecker", i % 2 == 0 and self.whiteMaterial or self.blackMaterial,
            V((i - 10.5) * boardCell, 5.15, -0.11), V(boardCell, 0.52, 0.03))
    end
    -- 棋盘在实际沥青内，两侧各留0.15m，窄森林路也不越界。
    local gridWidth = halfWidth * 2 - 0.30
    local columns = math.max(2, math.floor(gridWidth / 0.50))
    local cell = gridWidth / columns
    for row = 1, 2 do
        for column = 1, columns do
            local s = startS + (row - 1.5) * 0.50
            local lane = (column - (columns + 1) * 0.5) * cell
            local point, yaw, pitch = Landscape.TrafficPose(s, lane)
            self:CoursePart(self.routeRoot, "RaceGridChecker", (row + column) % 2 == 0
                and self.whiteMaterial or self.blackMaterial, point + V(0, 0.025, 0),
                V(cell * 0.98, 0.018, 0.49), Quaternion(pitch, yaw, 0))
        end
    end
    local checkpoints = self.race.checkpoints or {}
    if #checkpoints > 0 then
        -- 每约180m一对检查点灯，保留比赛真实检查点而不为每个检测点堆模型。
        for index, checkpoint in ipairs(checkpoints) do
            if index > 1 and index % 2 == 0 then self:BuildCheckpoint(checkpoint.s, index) end
        end
    else
        for index = 1, 16 do self:BuildCheckpoint(startS + Landscape.RouteLength * index / 17, index) end
    end
end

---@param s number
---@param index integer
function RaceVisuals:BuildCheckpoint(s, index)
    local node = self:CourseAnchor(s, "RaceRouteMarker_" .. index)
    local halfWidth = self.race.roadHalfWidth or ((Landscape.Roads and Landscape.Roads[1]) and Landscape.Roads[1].width) or 4.8
    local postX = halfWidth + 1.0
    for _, side in ipairs({-1, 1}) do
        self:CoursePart(node, "CheckpointBase", self.blackMaterial, V(side * postX, 0.10, 0), V(0.5, 0.20, 0.65))
        self:CoursePart(node, "CheckpointPost", self.steelMaterial, V(side * postX, 0.95, 0), V(0.15, 1.70, 0.15))
        self:CoursePart(node, "CheckpointLamp", self.greenMaterial, V(side * postX, 1.65, 0), V(0.19, 0.48, 0.19))
    end
    -- 路面箭头始终沿路线+Z；由TrafficPose同时给出弯道朝向和坡度。
    self:CoursePart(node, "DirectionArrowStem", self.yellowMaterial, V(0, 0.028, -0.35), V(0.20, 0.018, 1.40))
    for _, side in ipairs({-1, 1}) do
        self:CoursePart(node, "DirectionArrowHead", self.yellowMaterial, V(side * 0.32, 0.028, 0.22),
            V(0.20, 0.018, 0.98), Quaternion(0, side * -43, 0))
    end
end

-- 同一Scene内重赛复用轻量节点；只有车型id变化才重建该名对手。
---@param race? table
function RaceVisuals:Reset(race)
    if self.disposed then return end
    if race then self.race = race end
    local present = {}
    for _, data in ipairs(self.race.runners or self.race.racers or {}) do
        if not data.isPlayer then
            present[data.id] = true
            local runner = self.runners[data.id]
            if runner and runner.vehicleId ~= data.vehicleId then
                runner.effects:Dispose(); runner.rider:Dispose(); runner.node:Dispose()
                self.runners[data.id] = nil
                runner = nil
            end
            if not runner then
                runner = self:CreateRunner(data)
                self.runners[data.id] = runner
            end
            runner.poseClock, runner.lean, runner.active, runner.wasInView = 0, 0, false, false
            runner.colorId = data.colorId or "red"
            runner.rider:SetColor(runner.colorId)
            runner.node:SetEnabledRecursive(true)
            runner.effects:Reset()
            runner.node.position = V(data.x, data.y + 0.015, data.z)
            runner.node.rotation = Quaternion(0, data.heading or data.yaw or 0, 0)
            runner.visual.rotation = Quaternion(data.pitch or 0, 0, 0)
            runner.visual.position = V.ZERO
            self:RefreshPose(runner, data, true)
        end
    end
    for id, runner in pairs(self.runners) do
        if not present[id] then
            runner.effects:Dispose(); runner.rider:Dispose(); runner.node:Dispose()
            self.runners[id] = nil
        end
    end
    self:EnsurePolice()
    self.clock, self.visibilityClock = 0, 1
    self:SetVisible(true)
end

-- 入口菜单/练习隐藏整套比赛表现；Update不得越过这个总开关重新启用对手。
---@param visible boolean
function RaceVisuals:SetVisible(visible)
    if self.disposed then return end
    self.visible = visible == true
    if self.root then self.root:SetEnabledRecursive(self.visible) end
    for _, runner in pairs(self.runners) do
        runner.node:SetEnabledRecursive(false)
        runner.active, runner.wasInView = false, false
        runner.effects:Reset()
    end
    if self.policeNode then self.policeNode:SetEnabledRecursive(false) end
    if self.visible then self:Update(0, self.race.sim) end
end

---@param high boolean
function RaceVisuals:SetQuality(high)
    self.highQuality = high == true
    self.visibilityClock = 1
end

-- 只在四分之一秒节拍及画质切换后选最近车辆，避免每帧换Model。
-- 最多三辆（流畅档两辆）近车使用分区材质，其余保持原单批次模型。
---@param px number
---@param pz number
function RaceVisuals:UpdateVehicleDetail(px, pz)
    local candidates = {}
    for _, data in ipairs(self.race.runners or self.race.racers or {}) do
        local runner = self.runners[data.id]
        if runner and not data.eliminated then
            local dx, dz = data.x - px, data.z - pz
            local radius = self.highQuality and 42 or 32
            if runner.detailTier == "balanced" then radius = radius + 10 end
            local distance2 = dx * dx + dz * dz
            if distance2 < radius * radius then
                -- 现任近景名额享有2m替换滞回，距离接近时不每0.25s互换。
                local priority = math.sqrt(distance2) - (runner.detailTier == "balanced" and 2 or 0)
                candidates[#candidates + 1] = {runner = runner, priority = priority}
            end
        end
    end
    table.sort(candidates, function(a, b)
        if a.priority == b.priority then return a.runner.id < b.runner.id end
        return a.priority < b.priority
    end)
    local selected = {}
    for index = 1, math.min(#candidates, self.highQuality and 3 or 2) do
        selected[candidates[index].runner.id] = true
    end
    for id, runner in pairs(self.runners) do
        local tier = selected[id] and "balanced" or "distant"
        if tier ~= runner.detailTier then
            Assets.SetDetail(runner.body, tier)
            runner.detailTier = tier
        end
    end
end

---@param dt number
---@param sim table?
function RaceVisuals:Update(dt, sim)
    if self.disposed or not self.visible then return end
    local frameTime = sim and sim.paused == true and 0 or math.max(0, dt)
    self.clock, self.visibilityClock = self.clock + frameTime, self.visibilityClock + frameTime
    local px, pz = sim and sim.x or 0, sim and sim.z or 0
    if self.visibilityClock >= 0.25 then self:UpdateVehicleDetail(px, pz) end
    for _, data in ipairs(self.race.runners or self.race.racers or {}) do
        local runner = self.runners[data.id]
        if runner then
            -- Race实际坐标包含绕行/驶离主线等真实位移。表现不得按s/lane再投影覆盖它。
            local position = V(data.x, data.y + 0.015, data.z)
            local dx, dz = position.x - px, position.z - pz
            local distance2 = dx * dx + dz * dz
            local visible = not data.eliminated and distance2 < 320 * 320
            local reactivated = visible and not runner.active
            if visible ~= runner.active or reactivated then
                runner.node:SetEnabledRecursive(visible)
                if visible then runner.effects:Reset() end
            end
            if visible then
                runner.node.position = position
                runner.node.rotation = Quaternion(0, data.heading or data.yaw or 0, 0)
                local target = math.max(-55, math.min(55, data.lean or 0))
                runner.lean = runner.lean + (target - runner.lean) * (1 - math.exp(-frameTime * 10))
                local boostPower = data.driveSim and data.driveSim.raceBoost or 0
                runner.effects:Update(frameTime, boostPower, data.speed or 0)
                -- AI被撞时车身猛晃并短暂偏航，恢复后由正常线路接管。
                local hit = (data.hitShake or 0) * (data.hitTimer or 0)
                local hitYaw = (data.hitYaw or 0) * (data.hitTimer or 0) * 0.12
                local hitRoll = math.sin(self.clock * 46 + (data.index or 0)) * 9 * hit
                runner.visual.rotation = Quaternion((data.pitch or 0) + runner.effects.pitch + hit * 4,
                    hitYaw, runner.lean * self.leanSign + hitRoll)
                runner.visual.position = V(0, runner.effects.bob, 0)
                if require("MixedVehicles").Get(runner.vehicleId) then
                    local drive = data.driveSim or {}
                    runner.visual.position = V(0, drive.oddAltitude or 0, 0)
                    runner.visual.rotation = Quaternion((data.pitch or 0)*.5, 0, runner.lean*.22+hitRoll)
                    require("MixedVisuals").Animate(runner.body,runner.vehicleId,self.clock,drive)
                end
                if runner.colorId ~= data.colorId and data.colorId then
                    runner.rider:SetColor(data.colorId); runner.colorId = data.colorId
                end
                runner.poseClock = runner.poseClock + frameTime
                local inView = runner.rider.model.inView
                local enteredView = inView and not runner.wasInView
                -- 近距30Hz/中距10Hz/远距4Hz只影响手动IK成本，不依赖inView启动。
                -- 屏外继续提交pose，重启/重入无条件立即完整刷新，避免一帧站姿。
                local interval = distance2 < 45 * 45 and 1 / 30 or (distance2 < 95 * 95 and 0.10 or 0.25)
                if reactivated or enteredView or runner.poseClock >= interval then
                    self:RefreshPose(runner, data, reactivated or enteredView)
                end
                runner.wasInView = inView
            else
                runner.wasInView = false
                runner.effects:Reset()
            end
            runner.active = visible
        end
    end
    self:EnsurePolice()
    for _,shot in ipairs(self.race.mixedProjectiles or {}) do
        if not shot.node then
            shot.node=P.Add(self.root,"SkillProjectile","Sphere",
                shot.kind=="jellyfish" and self.blueMaterial or self.greenMaterial,V.ZERO,
                shot.kind=="jellyfish" and V(.65,.65,.65) or V(.2,.2,1),nil,false)
        end
        shot.node.position=V(shot.x,shot.y,shot.z)
        local pitch=-math.deg(math.atan(shot.vy,math.sqrt(shot.vx*shot.vx+shot.vz*shot.vz)))
        shot.node.rotation=Quaternion(pitch,math.deg(math.atan(shot.vx,shot.vz)),0)
    end
    local police = self.race.pursuit or self.race.police
    if self.policeNode then
        local enabled = police ~= nil and police.active == true and self.race.phase ~= "idle"
        self.policeNode:SetEnabledRecursive(enabled)
        if enabled then
            -- 最后追捕阶段Race会驶离路线逼近路外目标；表现必须使用仿真真实坐标，
            -- 不能再按s/lane吸附回路面，避免画面警车与12m抓捕距离不一致。
            self.policeNode.position = V(police.x, police.y + 0.015, police.z)
            self.policeNode.rotation = Quaternion(police.pitch or 0, police.yaw or 0, 0)
            local flashing = police.state == "warning" or police.state == "chasing"
            local phase = math.floor(self.clock * 9) % 2 == 0
            if self.policeRed then self.policeRed.enabled = flashing and phase end
            if self.policeBlue then self.policeBlue.enabled = flashing and not phase end
        end
    end
    if self.visibilityClock >= 0.25 then
        self.visibilityClock = self.visibilityClock % 0.25
        for _, marker in ipairs(self.markers) do
            local dx, dz = marker.x - px, marker.z - pz
            marker.node:SetEnabledRecursive(dx * dx + dz * dz < 420 * 420)
        end
    end
end

---@return table
function RaceVisuals:GetStats()
    local rivals, rigs = 0, 0
    for _, runner in pairs(self.runners) do
        rivals, rigs = rivals + 1, rigs + 1
        assert(not runner.node.name:match("^Bike_"), "Lightweight rival cannot be named Bike_")
        assert(not runner.node:GetChild("HelmetCockpit", true), "Rival cannot allocate cockpit")
        assert(not runner.node:GetChild("BurnoutSmokePool", true), "Rival cannot allocate smoke")
    end
    return {rivals = rivals, riders = rigs, police = self.policeNode ~= nil, routeMarkers = #self.markers}
end

function RaceVisuals:Destroy()
    if self.disposed then return end
    self.disposed = true
    for _, runner in pairs(self.runners) do
        runner.effects:Dispose()
        runner.rider:Dispose()
    end
    self.runners = {}
    if self.root then self.root:Dispose() end
    for _, material in ipairs(self.materials) do material:Dispose() end
    self.materials, self.markers = {}, {}
    self.world, self.race = {}, {} -- 解除对World.scene/旧Race仿真的间接持有。
    self.root, self.scene, self.policeNode, self.policeBody = nil, nil, nil, nil
    self.policeRed, self.policeBlue = nil, nil
end

function RaceVisuals:Dispose() self:Destroy() end
return RaceVisuals
