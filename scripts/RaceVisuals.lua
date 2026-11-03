-- 基于scaffold-3d-scene的Scene持有/父子节点结构；本模块只表现，不参与Race仿真或碰撞。
-- AI仅真实整车StaticModel + 全盔Rider；绝不构造完整Bike/座舱/镜面/烟雾。
local Assets = require("VehicleAssets")
local Rider = require("Rider")
local RideEffects = require("RideEffects")
local SkillPresentation = require("SkillPresentation")
local ExplosionEffects = require("ExplosionEffects")
local ScenicAssetProps = require("ScenicAssetProps")
-- 官方资源库DLl_iWrIXFGnWp6MXMWm5rlt：连续直向金色箭头；BrMPQVbouuJ6tP9-opAx9Z5U：完整交通锥。
-- 不使用搜索描述中实际为掉头/转弯的箭头，不用Box拼装路标或门架。
local COURSE_ARROW = "uuid://D_WEUc5wpVo9pjy4U8VhVjVV"
local COURSE_ARROW_MATERIAL = "uuid://FjoMmROgqb4dDyqNZCf6eElx"
local COURSE_CONE = "uuid://CGp6ca4NUVz_7_-kG06v5Ayb"
local COURSE_CONE_MATERIAL = "uuid://Fba9ASA3ZLeE2_Fb_Md4QJfF"
local COURSE_RESOURCES = {COURSE_ARROW, COURSE_ARROW_MATERIAL, COURSE_CONE, COURSE_CONE_MATERIAL}
local COURSE_TYPES = {[COURSE_ARROW] = "Model", [COURSE_ARROW_MATERIAL] = "Material",
    [COURSE_CONE] = "Model", [COURSE_CONE_MATERIAL] = "Material"}
local Bike = require("Bike") -- 只取Cockpits配置，不调用Bike.New。
local MixedVisuals = require("MixedVisuals")
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
---@field fullRider? Rider
---@field stubRider table
---@field data? table
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
---@field activeExplosions Explosion[]
local RaceVisuals = {}
RaceVisuals.__index = RaceVisuals

-- 主流程在VehicleAssets登记police后调用；避免模块require时抢先索引尚未接好的资源。
---@return string[]
function RaceVisuals.GetResources()
    local ids = require("MixedAssets").RaceIds()
    if Assets.Vehicles.police then ids[#ids + 1] = "police" end
    local paths = Assets.ResourcesFor(ids)
    for _, path in ipairs(Rider.Resources) do
        paths[#paths + 1] = path
        Assets.ResourceTypes[path] = Rider.ResourceTypes[path]
    end
    -- 每项按明确类型预载；真实图片是Texture2D，纹理xml导入设置不登记运行时根。
    for _, path in ipairs(SkillPresentation.Resources) do
        paths[#paths + 1] = path
        Assets.ResourceTypes[path] = assert(SkillPresentation.ResourceTypes[path])
    end
    -- 命中爆炸贴图必须提前预载，否则首次爆炸会同步加载卡帧。
    for _, path in ipairs(ExplosionEffects.Resources) do
        paths[#paths + 1] = path
        Assets.ResourceTypes[path] = assert(ExplosionEffects.ResourceTypes[path])
    end
    for _, path in ipairs(COURSE_RESOURCES) do
        paths[#paths + 1] = path
        Assets.ResourceTypes[path] = assert(COURSE_TYPES[path])
    end
    -- 保留普通氮气已有表现，与载具专属技能没有关系。
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
    local isRiderBoundMixed = vehicleId == "ebike"
    local cockpit = isRiderBoundMixed and MixedVisuals.Cockpits.ebike
        or (odd and {grip=V(.3,1,.4),seatHeight=1} or Bike.GetCockpit(vehicleId))
    local node = self.rosterRoot:CreateChild("RaceRival_" .. id, LOCAL)
    local visual = node:CreateChild("RivalLean", LOCAL)
    local body = Assets.Add(visual, vehicleId, nil, "distant")
    -- 电动车使用正式整车与同一套41骨Rider；其它混合车保持轻量无驾驶员表现。
    local rider = isRiderBoundMixed and assert(MixedVisuals.CreateRider(visual, vehicleId),
        "AI ebike formal rider creation failed")
        or (odd and {poseFailures=0,model={updateInvisible=true,animationLodBias=0,
        drawDistance=260,shadowDistance=65,inView=true}, SetColor=function() end,
        Update=function() end,Dispose=function() end} or Rider.New(visual, vehicleId, cockpit.grip))
    local colorId = data.colorId or "red"
    rider:SetColor(colorId)
    -- Formal Rider is the only rider-bound mixed visual; it inherits RivalLean lean/pitch.
    if odd and not isRiderBoundMixed then MixedVisuals.SetRiderColor(body,colorId) end
    -- Rider是手动41骨pose，无动画clip；必须保留其updateInvisible=true契约。
    -- inView是上一渲染帧结果，不能作为首次提交/重新启用的前置条件。
    -- 骑手是8个41骨蒙皮模型；阴影pass会让它们各画两遍，远端几乎看不出差别。
    -- 只有玩家自己的骑手保留投影，对手一律不投射阴影。
    rider.model.updateInvisible = true
    rider.model.animationLodBias = 0
    rider.model.castShadows = false
    rider.model.drawDistance = 180
    rider.model.shadowDistance = 0
    local models = body:GetComponents("StaticModel", true)
    for _, model in ipairs(models) do
        model.castShadows = false
        model.shadowDistance = 0
        model.drawDistance = 240
        model.lodBias = 0.75
    end
    Assets.SetDetail(body, "distant")
    local effects = RideEffects.New(visual, Assets.Vehicles[vehicleId].targetSize, cockpit.seatHeight, true)
    local runner = {id = id, vehicleId = vehicleId, colorId = colorId, node = node,
        visual = visual, body = body, rider = rider, models = models, poseClock = 0, lean = 0,
        effects = effects, active = false, wasInView = false, poseRefreshes = 0, detailTier = "distant"}
    -- 完整骑手保留引用；远处时换成空壳，切回近处再恢复，绝不重复创建骨骼。
    -- 封闭座舱车型本来就是空壳，没有可切换的完整骑手。
    if rider ~= nil and rider.model ~= nil and rider.node ~= nil then
        runner.fullRider = rider --[[@as Rider]]
    end
    runner.stubRider = {poseFailures = 0, disposed = false, colorId = colorId,
        model = {updateInvisible = true, animationLodBias = 0, drawDistance = 260,
            shadowDistance = 0, inView = false},
        SetColor = function(self, color) self.colorId = color or self.colorId; return true end,
        SetVisible = function() end, Update = function() end,
        Dispose = function() end}
    self:RefreshPose(runner, data, true)
    return runner
end

-- 只在初始化/距离重启/进入视野读回接触点，不把昂贵骨骼验证放到每帧。
-- 如果Rider的pcall回退绑定站姿，立刻重试完整事务，且记录真正失败而非静默站立。
---@param runner RaceVisualRunner
---@param data table
---@param verify boolean
function RaceVisuals:RefreshPose(runner, data, verify)
    if require("MixedVehicles").Get(runner.vehicleId) and runner.vehicleId ~= "ebike" then return end
    local steer = (data.steer or 0) * math.max(4, 22 - math.abs(data.speed or 0) * 0.35)
    if runner.vehicleId == "ebike" or runner.vehicleId ~= Rider.ClassFor(runner.vehicleId) then steer = 0 end
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

-- 表现节点不带碰撞；检查点判定仍由Race维护，路标与检测共用同一s。
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

-- 资源库完整网格，按包围盒等比缩放；无基础几何、无网格生成或截取。
---@param parent Node
---@param name string
---@param modelPath string
---@param materialPath string
---@param position Vector3
---@param heightOrLength number
---@param arrow boolean
---@return Node
function RaceVisuals:CourseAsset(parent, name, modelPath, materialPath, position, heightOrLength, arrow)
    local model = assert(cache:GetResource("Model", modelPath), "赛事指引模型未预载：" .. modelPath)
    local material = ScenicAssetProps.MaterialFor(materialPath)
    local bounds = model.boundingBox
    local dimension = arrow and math.max(bounds.size.x, bounds.size.z) or bounds.size.y
    assert(dimension > .0001, "赛事指引包围盒无效")
    local scale = heightOrLength / dimension
    local anchor = parent:CreateChild(name, LOCAL)
    anchor.position = position
    -- 官方TopView核对：连续箭头原始朝+X；yaw -90后朝赛道局部+Z。
    local rotation = arrow and Quaternion(0, -90, 0) or Quaternion.IDENTITY
    local mesh = anchor:CreateChild("正式共享网格", LOCAL)
    mesh.rotation = rotation
    mesh:SetScale(scale)
    mesh.position = rotation * V(-bounds.center.x, -bounds.min.y, -bounds.center.z) * scale
    local drawable = mesh:CreateComponent("StaticModel")
    drawable:SetModel(model); drawable:SetMaterial(material)
    drawable.drawDistance, drawable.castShadows = 320, false
    return anchor
end

function RaceVisuals:BuildCourse()
    -- 仅复用World真正存在的门架；即使环境代理移除它/留下空节点，起终指引仍独立保留。
    local existing = self.world.root and self.world.root:GetChild("起终点龙门与发车格", true)
    local hasGantry = existing and #existing:GetComponents("StaticModel", true) > 0
    print(hasGantry and "[竞速指引] 复用World起终点门架；正式检查点箭头与锥标"
        or "[竞速指引] World无门架；以正式锥标和箭头标识起终点，不创建占位门架")
    -- 不依赖门架节点存在与否：起终点恒有两枚1.4米正式锥标和两组顺行金箭头。
    self:BuildCheckpoint(self.race.startS or 0, 0)
    local checkpoints = self.race.checkpoints or {}
    if #checkpoints > 0 then
        for index, checkpoint in ipairs(checkpoints) do
            -- 起终点已标记，避免同一点重叠；所有其余玩法检查点均可见，不隔点删指引。
            local distance = math.abs((checkpoint.s - (self.race.startS or 0) + Landscape.RouteLength * .5)
                % Landscape.RouteLength - Landscape.RouteLength * .5)
            if distance > 3 then self:BuildCheckpoint(checkpoint.s, index) end
        end
    else
        for index = 1, 16 do self:BuildCheckpoint((self.race.startS or 0) + Landscape.RouteLength * index / 17, index) end
    end
end

---@param s number
---@param index integer
function RaceVisuals:BuildCheckpoint(s, index)
    local node = self:CourseAnchor(s, index == 0 and "RaceStartFinishGuide" or "RaceCheckpoint_" .. index)
    local halfWidth = self.race.roadHalfWidth or ((Landscape.Roads and Landscape.Roads[1]) and Landscape.Roads[1].width) or 4.8
    -- 锥标在沥青外；脚点单独采样地形，不把两侧坡度当中心路面高程。
    local road = Landscape.Roads and Landscape.Roads[1]
    local postX = math.max(halfWidth, road and road.shoulder or halfWidth) + .8
    for _, side in ipairs({-1, 1}) do
        local point = Landscape.TrafficPose(s, side * postX)
        local y = Landscape.Height(point.x, point.z)
        local foot = V(point.x, y, point.z)
        self:CourseAsset(node, "CheckpointOfficialCone", COURSE_CONE, COURSE_CONE_MATERIAL,
            node:WorldToLocal(foot), index == 0 and 1.4 or 1.1, false)
    end
    -- 双箭头沿路线+Z；两处连续指引增强高速识别，局部采样坡度防止长平面跨坡悬空。
    for _, offset in ipairs({-2.5, .5}) do
        local point, yaw, pitch = Landscape.TrafficPose(s + offset, 0)
        local arrow = self:CourseAsset(node, "CheckpointOfficialForwardArrow", COURSE_ARROW, COURSE_ARROW_MATERIAL,
            node:WorldToLocal(point + V(0, .035, 0)), 2.4, true)
        arrow.worldRotation = Quaternion(pitch, yaw, 0)
    end
end

-- 同一Scene内重赛复用轻量节点；只有车型id变化才重建该名对手。
---@param race? table
function RaceVisuals:Reset(race)
    if self.disposed then return end
    self:ClearExplosions()
    if race then self.race = race end
    local present = {}
    for _, data in ipairs(self.race.runners or self.race.racers or {}) do
        if not data.isPlayer then
            present[data.id] = true
            local runner = self.runners[data.id]
            if runner and runner.vehicleId ~= data.vehicleId then
                if runner.fullRider then runner.fullRider:Dispose() end
                runner.effects:Dispose(); runner.node:Dispose()
                self.runners[data.id] = nil
                runner = nil
            end
            if not runner then
                runner = self:CreateRunner(data)
                self.runners[data.id] = runner
            end
            runner.poseClock, runner.lean, runner.active, runner.wasInView = 0, 0, false, false
            runner.colorId = data.colorId or "red"
            -- 颜色只作用于当前生效的骑手，避免恢复远景时丢掉配色。
            if runner.fullRider then runner.fullRider:SetColor(runner.colorId) end
            runner.rider:SetColor(runner.colorId)
            runner.node:SetEnabledRecursive(true)
            runner.effects:Reset()
            runner.node.position = V(data.x, data.y + 0.015, data.z)
            runner.node.rotation = Quaternion(0, data.heading or data.yaw or 0, 0)
            runner.visual.rotation = Quaternion(data.pitch or 0, 0, 0)
            runner.visual.position = V.ZERO
            runner.data = data
            -- 重赛时先恢复真实fullRider再验收；远景stub没有ReadPose契约。
            if runner.fullRider and runner.rider ~= runner.fullRider then
                runner.rider = runner.fullRider
                runner.fullRider:SetVisible(true)
            end
            self:RefreshPose(runner, data, true)
        end
    end
    for id, runner in pairs(self.runners) do
        if not present[id] then
            if runner.fullRider then runner.fullRider:Dispose() end
            runner.effects:Dispose(); runner.node:Dispose()
            self.runners[id] = nil
        end
    end
    self:EnsurePolice()
    self.clock, self.visibilityClock = 0, 1
    self:SetVisible(true)
    self:ReportBudget()
end

-- 对手渲染预算只统计一次，便于真实设备日志定位掉帧来源；不进入逐帧路径。
function RaceVisuals:ReportBudget()
    if self.budgetReported then return end
    self.budgetReported = true
    local draws, triangles, riders, shadows = 0, 0, 0, 0
    local rivals = 0
    ---@param draw StaticModel
    local function measure(draw)
        if not draw.enabled then return end
        draws = draws + 1
        if draw.castShadows then shadows = shadows + 1 end
        local model = draw:GetModel()
        if not model then return end
        for slot = 0, model.numGeometries - 1 do
            local geometry = model:GetGeometry(slot, 0)
            if geometry then
                triangles = triangles + (geometry.indexCount > 0 and geometry.indexCount or geometry.vertexCount) // 3
            end
        end
    end
    for _, runner in pairs(self.runners) do
        rivals = rivals + 1
        if runner.rider and runner.rider.model then
            riders = riders + 1
            measure(runner.rider.model)
        end
        for _, draw in ipairs(runner.body:GetComponents("StaticModel", true)) do measure(draw) end
        if runner.effects and runner.effects.root then
            for _, draw in ipairs(runner.effects.root:GetComponents("StaticModel", true)) do measure(draw) end
        end
    end
    print(string.format("[对手预算] %d名AI / %d骑手 / draws=%d triangles=%d 投影部件=%d",
        rivals, riders, draws, triangles, shadows))
end

-- 一次性命中反馈在暂停/隐藏/重赛/切场景时主动释放，避免恢复后重播旧爆炸。
function RaceVisuals:ClearExplosions()
    self.activeExplosions = self.activeExplosions or {}
    ExplosionEffects.Clear(self.activeExplosions)
    local pending = self.race and self.race.mixedExplosions
    if pending then
        for index = #pending, 1, -1 do table.remove(pending, index) end
    end
end

-- 入口菜单/练习隐藏整套比赛表现；Update不得越过这个总开关重新启用对手。
---@param visible boolean
function RaceVisuals:SetVisible(visible)
    if self.disposed then return end
    self.visible = visible == true
    if not self.visible then self:ClearExplosions() end
    if self.root then self.root:SetEnabledRecursive(self.visible) end
    for _, runner in pairs(self.runners) do
        runner.node:SetEnabledRecursive(false)
        runner.active, runner.wasInView = false, false
        runner.effects:Reset()
    end
    if self.policeNode then self.policeNode:SetEnabledRecursive(false) end
    if self.visible then self.visibilityClock = 1; self:Update(0, self.race.sim) end
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
    -- 骑手是8个41骨蒙皮模型，是赛事模式最大的固定开销。
    -- 只有近处少数对手重建骑手，远处只留车体；按0.25秒节拍切换，不逐帧增删。
    local riderLimit = self.highQuality and 3 or 2
    local riderSelected = {}
    for index = 1, math.min(#candidates, riderLimit) do
        riderSelected[candidates[index].runner.id] = true
    end
    for id, runner in pairs(self.runners) do
        local needRider = riderSelected[id] == true
        if not needRider and runner.rider == runner.fullRider then
            -- 交出骑手：隐藏完整骨骼骑手，用同名空壳占位，避免逐帧判断nil。
            runner.fullRider.node:SetEnabledRecursive(false)
            runner.rider = runner.stubRider
        elseif needRider and runner.fullRider and runner.rider ~= runner.fullRider then
            runner.rider = runner.fullRider
            runner.fullRider:SetVisible(true)
            self:RefreshPose(runner, runner.data or {}, true)
        end
    end
end

---@param dt number
---@param sim table?
---@param camera Camera?
function RaceVisuals:Update(dt, sim, camera)
    if self.disposed or not self.visible then return end
    local frameTime = sim and sim.paused == true and 0 or math.max(0, dt)
    -- 入口暂停传dt=0；只清理瞬时爆炸，不推动仿真或弹体。
    if frameTime <= 0 then self:ClearExplosions() end
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
                    -- 被技能击中时叠加可见翻滚，让"被打中"有明确反馈。
                    local tumble = (data.tumble or 0)
                    local tumblePitch = tumble > 0 and math.sin(tumble * 24) * 38 * math.min(1, tumble) or 0
                    local tumbleRoll = tumble > 0 and math.cos(tumble * 20) * 32 * math.min(1, tumble) or 0
                    runner.visual.rotation = Quaternion((data.pitch or 0)*.5 + tumblePitch, data.airSpin or 0,
                        runner.lean*.22 + hitRoll + tumbleRoll)
                    require("MixedVisuals").Animate(runner.body,runner.vehicleId,self.clock,drive)
                end
                if runner.colorId ~= data.colorId and data.colorId then
                    runner.colorId = data.colorId
                    if runner.fullRider then runner.fullRider:SetColor(runner.colorId) end
                    runner.rider:SetColor(runner.colorId)
                end
                runner.poseClock = runner.poseClock + frameTime
                -- 只有当前持完整骑手的对手才解算骨骼；远景车体仍照常移动。
                if runner.rider == runner.fullRider then
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
                end
            else
                runner.wasInView = false
                runner.effects:Reset()
            end
            runner.active = visible
        end
    end
    self:EnsurePolice()
    -- 暂停时不创建/移动弹体；位置和朝向只来自MixedRace，同样适用于玩家和AI。
    if self.root and not (sim and sim.paused) then
        for _, shot in ipairs(self.race.mixedProjectiles or {}) do
            SkillPresentation.UpdateShot(self.root, shot)
        end
        -- 命中爆炸：MixedRace记录弹着点，这里生成真实贴图的爆炸并逐帧推进。
        local explosions = self.race.mixedExplosions
        if explosions then
            self.activeExplosions = self.activeExplosions or {}
            for index = #explosions, 1, -1 do
                local entry = explosions[index]
                self.activeExplosions[#self.activeExplosions + 1] = ExplosionEffects.Spawn(self.root, entry)
                table.remove(explosions, index)
            end
            for i = #self.activeExplosions, 1, -1 do
                if not ExplosionEffects.Update(self.activeExplosions[i], frameTime, camera) then
                    table.remove(self.activeExplosions, i)
                end
            end
        end
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
        -- 远景时 runner.rider 是空壳，完整骑手必须单独释放，否则换图会泄漏骨骼模型。
        if runner.fullRider then runner.fullRider:Dispose() end
        runner.rider:Dispose()
    end
    self.runners = {}
    -- 主动释放每个爆炸的material和node；不能只依赖root销毁，避免重赛/切场景残留引用。
    self.activeExplosions = self.activeExplosions or {}
    ExplosionEffects.Clear(self.activeExplosions)
    SkillPresentation.Clear(self.race.mixedProjectiles or {})
    if self.root then self.root:Dispose() end
    for _, material in ipairs(self.materials) do material:Dispose() end
    self.materials, self.markers = {}, {}
    self.world, self.race = {}, {} -- 解除对World.scene/旧Race仿真的间接持有。
    self.root, self.scene, self.policeNode, self.policeBody = nil, nil, nil, nil
    self.policeRed, self.policeBlue = nil, nil
end

function RaceVisuals:Dispose() self:Destroy() end
return RaceVisuals
