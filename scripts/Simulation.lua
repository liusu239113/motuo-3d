-- 街机自由骑行模型（含辅助起跳特技），不是轮胎/悬架高保真仿真；不依赖引擎，可用纯 Lua 自测。
-- 单位：米、秒；所有角度为度，+Z=0、+X=90；y 是车轮最低点。
-- 主流程先 World:Update(dt, sim, clock)，再 Step；本模块不更新/移动世界。
---@class RideSimulation
---@field oddAltitude number
---@field oddHopHeight? number 街机主动跳的最高离地偏移（米），不改世界里程或地面种类。
---@field oddActive number
---@field oddCooldown number
---@field oddSteam number
---@field oddSpring number
---@field oddDisrupt number
---@field oddShield number
---@field oddLaunch number
---@field oddPickups integer
---@field oddDriveScale number
---@field oddSpeedScale number
---@field oddGripScale number
---@field motorcycleActive number
---@field motorcycleCooldown number
---@field motorcycleSpeedScale number
---@field motorcycleDriveScale number
---@field motorcycleGripScale number
---@field motorcycleOffroadScale number
---@field motorcycleDamageScale number
---@field motorcycleRetained number
---@field motorcycleSkillName string
---@field motorcycleSkillResult string
---@field motorcycleSkillResultTimer number
---@field motorcyclePhase string
---@field motorcycleSkillAge number
---@field motorcycleSkillSerial number
---@field motorcycleGuard number
---@field motorcycleGuardFlash number
---@field motorcycleGuardBlocks number
---@field motorcycleDisruptScale number
---@field motorcycleCoastDragScale number
---@field speed number 以米每秒计，不能由Reset的0推断为integer。
---@field raceMode boolean 比赛仅接管规则，不改自由驾驶输入和转向。
---@field impactSerial number 每次有效碰撞递增，Race用于一次性宽限。
---@field recoverySerial number 每次脱困递增，Race拒绝瞬移里程。
---@field baseClass string
---@field crashCooldown number
local Sim = {}
local TrackFeatures = require("TrackFeatures")
local MixedRace = require("MixedRace")
local MotorcycleSkills = require("MotorcycleSkills")
Sim.__index = Sim
local RAD, DEG, GRAVITY = math.pi / 180, 180 / math.pi, 9.81
-- 中心纠偏仍限制在原来的量级，外圈释放街机弯道舵权；不能把6.5的满舵上限乘遍整段行程。
local STEER_IN_TIME, STEER_RETURN_TIME, MAX_LATERAL_ACCEL = 0.18, 0.10, 26
local VEHICLES = {
    sport = {name = "公路跑车", acceleration = 13.8, braking = 18, maxSpeed = 76,
        idle = 1300, redline = 12500, wheeliePower = 1.20, offroad = 0.58, steering = 1.0,
        ratios = {490, 350, 275, 225, 190, 160}},
    cruiser = {name = "巡航机车", acceleration = 10.2, braking = 15, maxSpeed = 57,
        idle = 950, redline = 7800, wheeliePower = 0.88, offroad = 0.64, steering = 0.78,
        ratios = {360, 265, 210, 173, 146, 128}},
    rally = {name = "拉力机车", acceleration = 12.4, braking = 16.5, maxSpeed = 65,
        idle = 1200, redline = 10500, wheeliePower = 1.08, offroad = 0.92, steering = 1.12,
        ratios = {470, 335, 260, 215, 182, 157}},
}
local FLAT = {
    Goals = {}, RouteLength = 0,
    RoadPoint = function(s) return {x = 0, y = 0, z = s}, 0 end,
    Height = function() return 0, true end,
    NearestRoad = function(x, z) return z, x end,
}
local function clamp(n, lo, hi) return math.max(lo, math.min(hi, n)) end
local function approach(n, target, amount)
    return n + clamp(target - n, -amount, amount)
end
local function wrap(yaw) return yaw % 360 end
local function angleDelta(a, b) return (a - b + 180) % 360 - 180 end
local function direction(yaw) return math.sin(yaw * RAD), math.cos(yaw * RAD) end
local function mix(a, b, t) return a + (b - a) * t end
local function loadLandscape()
    local ok, landscape = pcall(require, "Landscape")
    if ok and type(landscape) == "table" and landscape.RoadPoint then return landscape end
    return FLAT -- Landscape 尚未落盘时也能加载、运行自测。
end

---@param landscape table? 可注入纯 Lua 地图；正常 New() 自动 require Landscape。
function Sim.New(landscape)
    local self = setmetatable({}, Sim)
    self:Init(landscape or loadLandscape())
    return self
end
---@param landscape table
function Sim:Init(landscape)
    self.landscape = landscape
    self.vehicleId, self.baseClass = "sport", "sport"
    self.vehicle = VEHICLES.sport
    self.raceMode, self.impactSerial, self.recoverySerial = false, 0, 0
    self:Reset(false)
end

-- Variants share the tested base-class handling. Catalog can add cosmetics, not unbounded stats.
---@param id string
function Sim:SetVehicle(id)
    if type(id) ~= "string" then return false end
    local class = id:match("^(sport)") or id:match("^(cruiser)") or id:match("^(rally)")
    local name = ""
    local ok, catalog = pcall(require, "Catalog")
    if ok and type(catalog) == "table" then
        local getter = catalog.GetVehicle or catalog.Get
        local entry = type(getter) == "function" and getter(id) or nil
        if not entry and catalog.Vehicles then
            for _, candidate in ipairs(catalog.Vehicles) do
                if candidate.id == id then entry = candidate; break end
            end
        end
        if entry then
            if entry.available == false then return false end
            class, name = entry.baseClass or entry.class or class, entry.name or ""
        end
    end
    local vehicle = VEHICLES[class or ""]
    if not vehicle then return false end
    local entry = nil
    do
        local ok, catalog = pcall(require, "Catalog")
        if ok and type(catalog) == "table" and type(catalog.Get) == "function" then entry = catalog.Get(id) end
    end
    -- 每辆车不再只是同一套参数的换皮：极速/加速/耐久/越野/操控都按目录实值缩放。
    -- 使用独立副本，绝不改写共享 VEHICLES 基表。
    if entry then
        ---@type table<string, any>
        local stats = {}
        for key, value in pairs(VEHICLES[class] or {}) do stats[key] = value end
        vehicle = stats --[[@as table]]
        local baseAcceleration = ((VEHICLES[class] or {}).acceleration or vehicle.acceleration) --[[@as number]]
        if entry.speedStat then vehicle.maxSpeed = entry.speedStat / 3.6 end
        if entry.accelStat then vehicle.acceleration = baseAcceleration * entry.accelStat end
        if entry.offroadStat then vehicle.offroad = entry.offroadStat end
        if entry.handlingStat then vehicle.steering = entry.handlingStat end
        vehicle.durability = entry.durability or 64
        if require("MixedVehicles").Get(id) then
            -- 混合车不能沿用基础摩托的末挡速比上限，否则高极速坦克会被旧巡航档位卡在约208km/h。
            -- 按本车极速留出技能/氮气余量，复制速比避免污染同类车辆共享表。
            local ratios={}
            -- 末挡极速 = redline / ratio[6]；保留足够转速给技能/氮气，
            -- 回归夹具还会以1.25倍极速检查末挡余量。
            local targetTop=vehicle.maxSpeed*1.4
            local scale=vehicle.redline/(targetTop*vehicle.ratios[6])
            for i,ratio in ipairs(vehicle.ratios) do ratios[i]=ratio*scale end
            vehicle.ratios=ratios
        end
    else
        ---@type table<string, any>
        local stats = {}
        for key, value in pairs(VEHICLES[class] or {}) do stats[key] = value end
        vehicle = stats --[[@as table]]
        vehicle.durability = 64
    end
    self.vehicleId, self.baseClass, self.vehicle, self.vehicleName = id, class, vehicle, name ~= "" and name or vehicle.name
    self.rpm = clamp(self.rpm or vehicle.idle, vehicle.idle, vehicle.redline)
    self.speed = math.min(self.speed or 0, vehicle.maxSpeed)
    return true
end

function Sim:Reset(challenge)
    local point, yaw = self.landscape.RoadPoint(0)
    local forwardX, forwardZ = direction(yaw or 0)
    local offset = self.landscape.SpawnLaneOffset or 0
    self.x, self.z = point.x + forwardZ * offset, point.z - forwardX * offset
    self.y = self.landscape.Height(self.x, self.z)
    self.heading, self.yaw = yaw or 0, yaw or 0
    self.previousX, self.previousY, self.previousZ = self.x, self.y, self.z
    self.speed = 0.0
    self.steer, self.distance, self.elapsed = 0, 0, 0
    self.timeLimit = math.max(90, (self.landscape.RouteLength or 0) / 22 + 30)
    self.remaining, self.challenge = self.timeLimit, challenge == true and not self.raceMode
    self.impactSerial, self.recoverySerial = 0, 0
    self.hitShake, self.hitTimer = 0, 0
    self.raceBoost = 0
    self.featureState = TrackFeatures.NewBoostState()
    self.health, self.score, self.overtakes, self.nearMisses, self.topSpeed = 100, 0, 0, 0, 0
    self.crashCooldown, self.shiftTimer, self.logTimer = 0, 0, 0
    self.finished, self.success, self.wrecked = false, false, false
    local trackName = self.landscape.Track and self.landscape.Track.name or "当前路线"
    self.message, self.messageTimer = "自由驾驶 · " .. trackName .. " · 跟随导航探索", 4
    self.braking, self.throttle, self.manual, self.clutch = false, 0, false, false
    self.gear, self.rpm, self.clutchEngagement = 1, self.vehicle.idle, 1
    self.vehicleName = self.vehicleName or self.vehicle.name -- Reset 不改车型/variant名称。
    self.wheelie, self.wheelieAngle, self.pitch, self.lean = 0, 0, 0, 0
    self.burnout, self.spin, self.tireSmoke, self.wheelSpin = false, 0, 0, 0
    self.airborne, self.vY, self.airTime, self.airSpin = false, 0, 0, 0
    self.spinTarget, self.stuntAngle, self.stuntTimer, self.stuntCount = 0, 0, 0, 0
    self.stuntCooldown = 0
    self.groundTrickState, self.groundTrickFeedback = "", ""
    self.cornerAssist, self.roadCurvature, self.bendTimer, self.bendSpeed = 0, 0, 0, self.vehicle.maxSpeed
    self.stuntLabel, self.landingStable = "", true
    self.rampCooldown, self.groundY, self.groundSlope, self.groundVY = 0, self.y, 0, 0
    self.ramp = false
    self.onRoad, self.roadS, self.lateral = true, 0, 0
    self.atWorldEdge, self.waterDepth, self.waterTimer = false, 0, 0
    self.goalIndex, self.goalsDone, self.goalsTotal, self.goalLaps, self.goalArmed = 1, 0, 0, 0, true
    self.goalName, self.goalDistance, self.regionName = "探索山海", 0, "海岸公路"
    self.navHeading, self.targetYaw = self.heading, self.heading
    self.contacts, self.nextContacts, self.heldControls = {}, {}, {}
    MixedRace.Reset(self)
    self.surfaceCacheEnabled, self.surfaceValid = false, false
    self.surfaceWorld = self.landscape
    self.surfaceX, self.surfaceZ, self.surfaceY, self.surfaceRoad, self.surfaceRegion = 0, 0, 0, false, ""
    self:UpdateNavigation(self.x, self.z, nil, false)
end

---@param world table?
function Sim:Map(world)
    return world and world.landscape or self.landscape
end

---@param world table?
function Sim:Surface(x, z, world)
    local source = world or self.landscape
    -- 仅本子步、完全相同坐标与world复用最后一次精确采样；不做近似/量化或跨帧缓存。
    -- Move末尾/落地/导航常常查同一点，避免重复跑道路三角形求高；外部调用保持实时。
    if self.surfaceCacheEnabled and self.surfaceValid and self.surfaceWorld == source
        and self.surfaceX == x and self.surfaceZ == z then
        return self.surfaceY, self.surfaceRoad, self.surfaceRegion
    end
    local y, road, region
    if world and world.Surface then
        y, road, region = world:Surface(x, z)
    else
        y, road, region = self:Map(world).Height(x, z)
    end
    if type(y) == "table" then
        local surface = y
        y, road, region = surface.y or surface.height or 0, surface.road == true or surface.onRoad == true,
            surface.region or surface.regionName
    end
    local height, onRoad = y or 0, road == true
    if self.surfaceCacheEnabled then
        self.surfaceValid, self.surfaceWorld = true, source
        self.surfaceX, self.surfaceZ = x, z
        self.surfaceY, self.surfaceRoad, self.surfaceRegion = height, onRoad, region
    end
    return height, onRoad, region
end

-- 坡道入口为局部 z=0，顶端 z=length，宽度关于局部 x=0 对称。
--      +Y       顶端（速度足够则沿坡切线起飞）
--       |      /|
--       |_____/ |       侧边/反向驶离只下落，不提供额外起跳冲量。
--       +---------- +局部 Z
---@param ramp table
local function rampCoords(ramp, x, z)
    local sx, sz = direction(ramp.yaw or 0)
    local dx, dz = x - ramp.x, z - ramp.z
    return dx * sz - dz * sx, dx * sx + dz * sz
end
---@param world table?
function Sim:RampAt(x, z, world)
    if world and world.RampAt then return world:RampAt(x, z) end
    local map = self:Map(world)
    if map.RampAt then return map.RampAt(x, z) end
    return nil
end

-- 相对运动线段与扩张盒体求交，同时返回进入/退出时刻。
local function interval(a0, a1, extent, enter, leave)
    local delta = a1 - a0
    if math.abs(delta) < 1e-9 then return math.abs(a0) <= extent, enter, leave end
    local t0, t1 = (-extent - a0) / delta, (extent - a0) / delta
    if t0 > t1 then t0, t1 = t1, t0 end
    local first, last = math.max(enter, t0), math.min(leave, t1)
    return first <= last, first, last
end
function Sim.SweptHit(x0, x1, z0, z1, halfWidth, halfLength)
    local hit, enter, leave = interval(x0, x1, halfWidth, 0, 1)
    if not hit then return false, enter, leave end
    return interval(z0, z1, halfLength, enter, leave)
end

function Sim:Impact(reason, damage)
    if self.crashCooldown > 0 then return false end
    if MotorcycleSkills.Absorb(self, "撞击") then return false end
    local severity = damage or math.max(16, self.speed * 0.62)
    -- 耐久高的车更抗撞：同一次撞击掉的车况更少，撞后保留的动量也更多。
    local durability = (self.vehicle and self.vehicle.durability) or 64
    local motorcycleDamageScale = self.motorcycleDamageScale or 1
    local motorcycleRetained = self.motorcycleRetained or 1
    severity = severity * (1.28 - durability / 160) * motorcycleDamageScale
    -- 护航减少损失的动量，默认倍率1完整保留既有碰撞响应；仍有扣血/掉速/接触记录。
    local baseRetained = self.raceMode and clamp(0.75 - severity * 0.004, 0.55, 0.72) or 0.27
    local retained = 1 - (1 - baseRetained) * motorcycleRetained
    self.health = math.max(self.raceMode and 15 or 0, self.health - severity)
    self.speed, self.wheelieAngle = self.speed * retained, 0
    self.impactSerial = self.impactSerial + 1
    self.crashCooldown = self.raceMode and 2 or 2.2
    -- 撞击反馈：车身短促晃动+侧向偏，持续0.5秒后自然回正。
    self.hitShake, self.hitTimer = clamp(0.5 + severity * 0.012, 0.5, 1.0), 0.5
    self.message, self.messageTimer = reason or "发生碰撞 · 减速并保持车距", 3
    self.score = math.max(0, self.score - 100)
    self.wrecked = self.health <= 0
    if self.wrecked and self.challenge and not self.raceMode then self.finished = true end
    if self.wrecked and not self.challenge then
        self.message = "车辆损坏 · 使用脱困继续探索"
    end
    print(string.format("[驾驶] %s，车况 %.0f", self.message, self.health))
    return true
end

-- 路肩外侧真实阻挡：此前护栏只是装饰，车会直接穿过去。
-- 设计：主路沥青半宽 W，路肩外边界 S（已经包含 W），护栏位于 S+1.1 米。
--   ====沥青====|=净路肩=|  ||护栏||
-- 练习、支路及腾空不使用主路隐形墙；比赛越界仅在地面回推，绝不把腾空车辆拽回地面。
local BARRIER_MARGIN = 1.1
---@param world table?
function Sim:Barrier(dt, world)
    local map = self:Map(world)
    local road = map.Roads and map.Roads[1]
    if not road or not map.RoadPoint or not self.raceMode or self.airborne then return false end
    local halfWidth = road.width or 4.8
    local shoulder = road.shoulder or halfWidth
    local limit = math.max(halfWidth, shoulder) + (map.activeId == "circuit" and 4 or BARRIER_MARGIN)
    local mixed=require("MixedVehicles").Get(self.vehicleId)
    if mixed then limit=limit-mixed.size[1]*.5 end
    local _, lateral = map.NearestRoad(self.x, self.z)
    local excess = math.abs(lateral) - limit
    if excess <= 0 then self.barrierHold = 0; return false end
    -- 回推到硬边内侧，保留一点余量，避免下一帧又被判越界。
    local s = map.NearestRoad(self.x, self.z)
    local point, yaw, pitch = map.RoadPoint(s)
    local angle = math.rad(yaw or 0)
    local side = lateral >= 0 and 1 or -1
    local inside = limit - 0.35
    self.x, self.z = point.x + math.cos(angle) * inside * side, point.z - math.sin(angle) * inside * side
    self.y = self:Surface(self.x, self.z, world)
    self.previousX, self.previousY, self.previousZ = self.x, self.y, self.z
    -- 撞栏代价：非一次性帧扣血，而是挡停+短冷却；低速擦栏只轻微减速。
    local severity = math.min(40, 6 + self.speed * 0.85)
    self.speed = self.speed * 0.12
    self.yaw, self.heading = yaw or 0, yaw or 0
    self.wheelie, self.wheelieAngle, self.burnout, self.tireSmoke = 0, 0, false, 0
    if self.crashCooldown <= 0 then
        self:Impact("撞上护栏 · 减速回正", severity)
        self.impactSerial = self.impactSerial + 1
    end
    self.barrierHold = (self.barrierHold or 0) + dt
    if (self.barrierHold or 0) < 0.02 then
        self.message, self.messageTimer = "撞上护栏 · 减速回正", 2
        print("[护栏] 撞栏减速，横向回推到路面内")
    end
    return true
end

-- 脱困不刷新计时、目标、里程和分数；只回最近道路、恢复基本车况。
---@param world table?
function Sim:Recover(world)
    self.recoverySerial = self.recoverySerial + 1
    local map = self:Map(world)
    local s = map.NearestRoad(self.x, self.z)
    local point, yaw = map.RoadPoint(s)
    local forwardX, forwardZ = direction(yaw or 0)
    local offset = map.SpawnLaneOffset or 0
    self.x, self.z = point.x + forwardZ * offset, point.z - forwardX * offset
    self.y = self:Surface(self.x, self.z, world)
    self.heading, self.yaw, self.speed = yaw or 0, yaw or 0, 0
    self.previousX, self.previousY, self.previousZ = self.x, self.y, self.z
    self.airborne, self.vY, self.airSpin, self.spinTarget = false, 0, 0, 0
    self.airTime, self.stuntAngle, self.stuntTimer, self.stuntLabel, self.stuntCooldown = 0, 0, 0, "", 0
    self.wheelieAngle, self.wheelie, self.pitch, self.steer, self.lean = 0, 0, 0, 0, 0
    self.burnout, self.spin, self.tireSmoke = false, 0, 0
    self.groundTrickState, self.groundTrickFeedback = "", ""
    self.cornerAssist, self.roadCurvature, self.bendTimer, self.bendSpeed = 0, 0, 0, self.vehicle.maxSpeed
    self.ramp, self.rampCooldown, self.groundY, self.groundSlope, self.groundVY = false, 0.6, self.y, 0, 0
    self.health, self.wrecked, self.crashCooldown = math.max(40, self.health), false, 2.2
    self.atWorldEdge, self.waterDepth, self.waterTimer = false, 0, 0
    self.rpm, self.clutchEngagement, self.shiftTimer = self.vehicle.idle, 0, 0
    self.contacts, self.nextContacts = {}, {}
    self.message, self.messageTimer = "已回到最近公路 · 继续探索", 3
    self:UpdateNavigation(self.x, self.z, world, false)
end

-- 保持特技在动力入口统一辅助，不伪造UI的gas/brake所有权，也不改调用方输入。
-- 烧胎优先于翘头；真实刹车/离合/损坏/腾空始终拥有安全优先权。
---@param controls table
function Sim:GroundAssist(controls)
    local throttle, brake = clamp(controls.throttle or 0, 0, 1), controls.brake == true
    local state, feedback = "", ""
    if controls.wheelie or controls.burnout then
        if self.wrecked then feedback = "车辆损坏 · 脱困后再按特技"
        elseif self.airborne then feedback = "空中无法地面特技 · 落地后继续按住"
        elseif self.waterDepth > 0.25 then feedback = "涉水中无法特技 · 回到干燥路面"
        elseif controls.clutch or (controls.manual and self.gear == 0) then feedback = "动力已断开 · 接合后继续按住特技"
        elseif controls.burnout then
            brake = true -- 高速也先制动，降到9m/s后自动进入烧胎，不再要求第三根手指。
            throttle = self.speed < 9 and math.max(throttle, 0.90) or 0
            state = self.speed < 9 and "burnout" or "burnout-braking"
            feedback = self.speed < 9 and "烧胎中 · 松手结束" or "烧胎准备 · 自动制动减速中"
        elseif brake then feedback = "刹车优先 · 松刹车后继续按住翘头"
        elseif self.speed >= 31 then feedback = "车速过高无法翘头 · 减速到110km/h以下"
        elseif self.crashCooldown > 0 then feedback = "车身恢复中 · 稍后继续按住翘头"
        else
            throttle = math.max(throttle, 0.78)
            state = self.speed <= 2 and "wheelie-launch" or "wheelie"
            feedback = self.speed <= 2 and "翘头准备 · 辅助起步中" or "翘头中 · 松手放下前轮"
        end
    end
    if feedback ~= "" and (feedback ~= self.groundTrickFeedback or self.messageTimer <= 0) then
        self.message, self.messageTimer = feedback, 2
    end
    self.groundTrickState, self.groundTrickFeedback = state, feedback
    return throttle, brake
end

-- 正常入口不传 manual/clutch/shift*，默认自动变速；以下参数只为原纯 Lua 测试和旧调用兼容。
---@param controls table
function Sim:Powertrain(dt, controls)
    local vehicle = self.vehicle
    self.throttle, self.braking = self:GroundAssist(controls)
    self.raceBoost = self.raceMode and (controls.boost == true and 1 or clamp(tonumber(controls.boost) or 0, 0, 1)) or 0
    -- Race has already authorised/charged this pulse. A nitro tap is a launch/drive command,
    -- not a silent no-op when the rider momentarily releases the separate gas control.
    if self.raceBoost > 0 and not self.braking and not controls.burnout then
        self.throttle = math.max(self.throttle, 0.9)
    end
    self.clutch = controls.clutch == true
    self.manual = controls.manual == true
    self.shiftTimer = math.max(0, self.shiftTimer - dt)
    local oldGear = self.gear
    if self.manual then
        if controls.shiftUp then self.gear = math.min(6, self.gear + 1)
        elseif controls.shiftDown then self.gear = math.max(0, self.gear - 1) end
    elseif self.shiftTimer <= 0 and not self.clutch and not self.airborne then
        if self.gear == 0 then self.gear = 1
        elseif self.rpm > vehicle.redline * 0.88 and self.gear < 6 and self.clutchEngagement > 0.8
            and self.speed * vehicle.ratios[self.gear] > vehicle.redline * 0.82 then self.gear = self.gear + 1
        elseif self.gear > 1 and self.speed * vehicle.ratios[self.gear] < vehicle.redline * 0.34 then
            self.gear = self.gear - 1
        end
    end
    if self.gear ~= oldGear then self.shiftTimer = 0.18 end
    local disconnected = self.clutch or self.gear == 0 or self.shiftTimer > 0
    self.clutchEngagement = disconnected and 0 or approach(self.clutchEngagement, 1, dt * 4)
    local freeRpm = vehicle.idle + self.throttle * (vehicle.redline - vehicle.idle) * 0.96
    local wheelRpm = self.speed * (vehicle.ratios[self.gear] or 0)
    local launchRpm = vehicle.idle + self.throttle * vehicle.redline * 0.27
    local slipping = not self.airborne and self.speed < 9 and self.throttle > 0.4
        and (self.braking or controls.burnout == true)
    local coupledRpm = math.max(wheelRpm, slipping and freeRpm * 0.94 or launchRpm)
    local coupling = self.clutchEngagement * (self.airborne and 0.12 or 1)
    local target = mix(freeRpm, coupledRpm, coupling)
    self.rpm = clamp(approach(self.rpm, target, vehicle.redline * dt * 2.2), vehicle.idle, vehicle.redline)
    local power = 0.67 + 0.33 * math.sin(clamp(self.rpm / vehicle.redline, 0, 1) * math.pi)
    local gearing = 1 - math.max(0, self.gear - 1) * 0.058
    local limiter = clamp((vehicle.redline * 1.025 - wheelRpm) / (vehicle.redline * 0.10), 0, 1)
    local boostDrive = self.raceBoost * vehicle.acceleration * 1.25 * self.throttle * self.clutchEngagement
    return vehicle.acceleration * power * gearing * self.throttle * self.clutchEngagement * limiter + boostDrive
end

---@param controls table
function Sim:GroundTricks(dt, controls, drive)
    local canBurn = not self.airborne and not self.wrecked and self.waterDepth <= 0.25
        and self.speed < 9 and self.throttle > 0.4 and self.clutchEngagement > 0.5
        and (self.braking or controls.burnout == true)
    self.burnout = canBurn
    self.spin = approach(self.spin, canBurn and self.throttle or 0, dt * 5)
    self.tireSmoke = approach(self.tireSmoke, canBurn and self.throttle or 0, dt * 3)
    self.wheelSpin = (self.wheelSpin + (self.speed / 0.34 * DEG + self.spin * 1900) * dt) % 360
    local lift = self.groundTrickState == "wheelie" and self.speed > 2 and self.speed < 31
        and drive > 1 and not self.braking and not canBurn and not self.airborne
    if lift then
        -- 按住进入可保持的平衡角；不把长按设计成数秒后必翻。外部强制危险姿态仍走旧失稳惩罚。
        if self.wheelieAngle < 57 then
            self.wheelieAngle = approach(self.wheelieAngle, 36 * self.vehicle.wheeliePower,
                dt * 48 * self.vehicle.wheeliePower * self.throttle)
        else
            self.wheelieAngle = self.wheelieAngle + dt * 32 * self.vehicle.wheeliePower * self.throttle
        end
    else
        self.wheelieAngle = approach(self.wheelieAngle, 0, dt * (self.braking and 160 or 48))
    end
    if self.wheelieAngle > 72 then
        self:Impact("翘头过高 · 后翻失稳", 22)
        self.wheelieAngle = 0
    elseif self.wheelieAngle > 57 then
        self.message, self.messageTimer = "抬头过高 · 松油或刹车压下前轮", 1
    end
    self.wheelie = clamp(self.wheelieAngle / 65, 0, 1)
    if lift and self.wheelieAngle > 12 then self.score = self.score + dt * 14 end
end

function Sim:TakeOff(vY)
    self.airborne, self.vY, self.airTime = true, vY, 0
    self.airSpin, self.spinTarget, self.stuntAngle = 0, 0, 0
    self.stuntLabel, self.stuntTimer = "飞跃", 0
    self.ramp, self.rampCooldown = false, 0.65
end

-- 街机辅助跳：地面接触点 y=ground，先赋向上速度，再走同一重力/落地/XYZ扫掠。
--          最高约1.2m(180)/1.6m(360)
--                 .---.
--   轮胎 * ------'     '------ * 落地
--   _____|____________________|_____ ground
-- >=4m/s、车身稳定、非刹车/烧胎才弹跳；陡坡/悬空/碰撞恢复期不额外抬升。
-- 不提供无敌、不屏蔽汽车或地面；空中转速和水平弹道沿用原逻辑。
function Sim:RequestSpin(requested, ground, slope)
    local feedback = ""
    if self.wrecked then
        feedback = "车辆损坏 · 脱困后再点特技"
    elseif self.spinTarget ~= 0 then
        feedback = "特技进行中 · 落地后再试"
    elseif self.stuntCooldown > 0 then
        feedback = string.format("特技冷却中 · %.1f秒后再试", self.stuntCooldown)
    elseif not self.airborne then
        if self.speed < 4 then
            feedback = "加速到15km/h再点特技"
        elseif self.rampCooldown > 0 then
            feedback = string.format("特技冷却中 · %.1f秒后再试", self.rampCooldown)
        elseif self.crashCooldown > 0 or self.braking or self.burnout or self.waterDepth > 0.25
            or self.wheelieAngle > 12 or math.abs(self.y - ground) > 0.10
            or math.abs(slope) > 0.5 or math.abs(self.groundVY) > 3 then
            feedback = "先稳住车身 · 平稳骑行后再点特技"
        else
            -- 有限辅助弹跳，不是写实机车物理；360留出完整旋转所需的腾空时间。
            self:TakeOff(requested > 200 and 5.6 or 4.8)
        end
    end
    if feedback ~= "" then
        self.message, self.messageTimer = feedback, 2
        return false
    end
    self.spinTarget = requested * (self.steer < -0.1 and -1 or 1)
    self.stuntLabel = string.format("空中 %d°", requested)
    self.message, self.messageTimer = self.stuntLabel .. " · 街机特技", 2
    self.stuntCooldown = 1.8
    return true
end

function Sim:Land(ground)
    local impactSpeed = math.max(0, -self.vY)
    local id=self.vehicleId
    if id=="jellyfish" or id=="helicopter" then impactSpeed=impactSpeed*.35 end
    if id=="loader" and (impactSpeed>10 or math.abs(self.steer)>.7) then
        impactSpeed=impactSpeed+7
    end
    local completed = self.spinTarget ~= 0 and math.abs(self.airSpin - self.spinTarget) < 3
    self.landingStable = (self.spinTarget == 0 or completed) and impactSpeed < 17 and self.wheelieAngle < 45
    -- 180落地为街机转向辅助：下一地面步沿新heading正向行驶并减速，
    -- 不模拟倒骑惯性到轮胎抓地的高保真过渡；空中水平弹道始终不随旋转改变。
    self.heading = wrap(self.heading + self.airSpin)
    self.stuntAngle = self.airSpin
    self.airborne, self.y, self.vY, self.groundVY = false, ground, 0, 0
    self.airSpin, self.yaw, self.rampCooldown = 0, self.heading, 0.45
    if self.landingStable and completed then
        local reward = math.abs(self.spinTarget) > 200 and 600 or 300
        self.stuntCount = self.stuntCount + 1
        self.score = self.score + reward
        self.stuntLabel = string.format("空中 %d° · 稳定落地 +%d", math.floor(math.abs(self.spinTarget)), reward)
        self.message, self.messageTimer = self.stuntLabel, 3
        if math.abs(self.spinTarget) < 200 then self.speed = self.speed * 0.68 end
    elseif not self.landingStable then
        self.stuntLabel = "落地失稳"
        self:Impact("落地失稳 · 飞跃时留足旋转时间", math.max(12, (impactSpeed - 9) * 2))
    elseif self.airTime > 0.25 then
        self.score = self.score + 75
        self.stuntLabel, self.message, self.messageTimer = "平稳飞跃 +75", "平稳飞跃 +75", 2
    end
    self.stuntTimer, self.spinTarget, self.wheelieAngle = 2.5, 0, 0
end

-- 指数响应的终值和步内平均值均解析计算；拆成不同dt也保留同一响应时间。
-- 平均舵量用于本步转弯，避免把帧末舵量当作整帧输入产生低帧率额外偏转。
function Sim:Steering(dt, target)
    local desired = clamp(target or 0, -1, 1)
    local response = desired == 0 and STEER_RETURN_TIME or STEER_IN_TIME
    local decay = math.exp(-dt / response)
    local average = desired + (self.steer - desired) * response * (1 - decay) / dt
    self.steer = desired + (self.steer - desired) * decay
    return average
end

-- 前视只调整限速，不改heading、不吸附车道；横移/逆行/越野仍由玩家自由控制。
-- Landscape 主路常见曲率约.003..01，最紧回头弯约.083（半径12米），不是旧限值隐含的500米大弯。
---@param world table?
function Sim:CornerAssist(dt, world, steering)
    local amount = math.abs(steering)
    self.cornerAssist = 0
    if amount <= 0.28 or self.airborne then
        self.bendTimer, self.bendSpeed, self.roadCurvature = 0, self.vehicle.maxSpeed, 0
        return
    end
    local blend = clamp((amount - 0.28) / 0.72, 0, 1)
    local target = mix(self.vehicle.maxSpeed, 24, blend * blend)
    self.bendTimer = self.bendTimer - dt
    if self.bendTimer <= 0 then
        self.bendTimer, self.roadCurvature = 0.15, 0
        local map = self:Map(world)
        if self.onRoad and map.RoadPoint and (map.RouteLength or 0) > 0 then
            local _, yaw = map.RoadPoint(self.roadS)
            local forward = math.cos(angleDelta(self.heading, yaw) * RAD) >= 0 and 1 or -1
            local span = clamp(self.speed * 0.4, 6, 24)
            for index = 0, 3 do
                local s = self.roadS + forward * index * span
                local a = map.RoadPoint(s - 4)
                local b = map.RoadPoint(s)
                local c = map.RoadPoint(s + 4)
                local u, v = math.atan(b.x - a.x, b.z - a.z), math.atan(c.x - b.x, c.z - b.z)
                local curvature = math.abs(angleDelta(v * DEG, u * DEG)) * RAD / 4
                -- 道路曲率给建议过弯速度；远处弯点保留制动距离，不能瞬间把车速写成目标值。
                local bendSpeed = math.sqrt(20 / math.max(curvature, 0.00001) + 2 * 8 * index * span)
                if bendSpeed < target then target = bendSpeed end
                self.roadCurvature = math.max(self.roadCurvature, curvature)
            end
        end
        self.bendSpeed = target
    end
    target = math.min(target, self.bendSpeed or target)
    self.cornerAssist = clamp((self.speed - target) * 2, 0, 8)
end

-- 小舵只用于纠偏；额外横向能力在中外圈连续展开，车型倍率在几何与限值里只算一次。
function Sim:TurnRate(steering)
    local amount = math.abs(steering)
    local t = clamp((amount - 0.10) / 0.90, 0, 1)
    local budget = 6.5 + (MAX_LATERAL_ACCEL - 6.5) * t * t * (3 - 2 * t)
    local geometric = 29 / (1 + self.speed * 0.10) * RAD * amount
    local safe = math.atan(budget * amount * 1.48 /
        math.max(0.01, self.speed * self.speed * self.vehicle.steering))
    return clamp(self.speed / 1.48 * math.tan(math.min(geometric, safe)) * DEG * self.vehicle.steering,
        0, 115) * (steering < 0 and -1 or 1)
end

---@param world table?
---@param controls table
---@param steering number? 本子步平均舵量；外部直接调用时使用当前舵量。
function Sim:Move(dt, controls, world, drive, steering)
    local oldX, oldY, oldZ = self.x, self.y, self.z
    local ground, road = self:Surface(self.x, self.z, world)
    local sx, sz = direction(self.heading)
    local ahead = self:Surface(self.x + sx, self.z + sz, world)
    local slope = clamp(ahead - ground, -3, 3)
    local ridingRamp=self:RampAt(self.x,self.z,world)
    if ridingRamp then
        -- 前轮前视超过唇口时仍取坡面切线，不把背部断崖当成下坡。
        local _,forward=rampCoords(ridingRamp,self.x,self.z)
        local along=sx*math.sin((ridingRamp.yaw or 0)*RAD)+sz*math.cos((ridingRamp.yaw or 0)*RAD)
        if forward>ridingRamp.length-1.1 and along>.7 then
            slope=(ridingRamp.exitGrade or ridingRamp.height/ridingRamp.length)*along
        end
    end
    self.onRoad, self.groundY, self.groundSlope = road, ground, slope
    self.rampCooldown = math.max(0, self.rampCooldown - dt)
    local requested = controls.spin360 and 360 or (controls.spin180 and 180 or 0)
    local wasAirborne = self.airborne
    if requested ~= 0 then self:RequestSpin(requested, ground, slope) end
    if self.airborne then
        -- 空中不凭油门/刹车改变水平动量，旋转也不把弹道变成圆弧。
        self.speed = math.max(0, self.speed - self.speed * self.speed * 0.00015 * dt)
        self.x, self.z = self.x + sx * self.speed * dt, self.z + sz * self.speed * dt
        self.y = self.y + self.vY * dt - GRAVITY * dt * dt * 0.5
        self.vY, self.airTime = self.vY - GRAVITY * dt, self.airTime + dt
    else
        -- 出公路必须明显掉速：仿赛/巡航在草地上严重打滑，拉力车保留大部分通过性。
        local offroad = math.min(1, self.vehicle.offroad * (self.motorcycleOffroadScale or 1))
        local traction = road and 1 or offroad
        local coast = self.throttle < 0.05 and (self.motorcycleCoastDragScale or 1) or 1
        local drag = (0.20 + self.speed * self.speed * 0.00115
            + (road and 0 or (4.6 * (1 - offroad * 0.55)))) * coast
        local engineBrake = self.throttle < 0.05 and self.clutchEngagement * math.min(1.8, self.speed * 0.12) * coast or 0
        local brake = (self.braking or self.burnout) and self.vehicle.braking or 0
        local acceleration = drive * traction - drag - brake - engineBrake
            - GRAVITY * slope / math.sqrt(1 + slope * slope)
        self:CornerAssist(dt, world, steering or self.steer)
        if self.cornerAssist > 0 then acceleration = math.min(acceleration, -self.cornerAssist) end
        if self.groundTrickState == "wheelie" and self.speed > 24 then
            -- 翘头保持在可控速度区；辅助/真实油门不会几秒后把车加到拒绝区而突然落轮。
            acceleration = math.min(acceleration, (24 - self.speed) * 2)
        end
        if self.burnout then acceleration = math.min(acceleration, -6) end
        if self.wrecked then acceleration = -self.vehicle.braking end
        local maximum = self.vehicle.maxSpeed * (1 + self.raceBoost * 0.25)
            * (self.oddSpeedScale or 1) * (self.motorcycleSpeedScale or 1)
            * (road and 1 or (0.44 + offroad * 0.52))
        -- Nitro ending / touching gravel must not instantly clamp away20km/h. Excess
        -- momentum coasts down with finite drag; this never increases the speed cap.
        if self.speed > maximum then acceleration = math.min(acceleration, -3.5 - (self.speed - maximum) * 0.45) end
        self.speed = clamp(self.speed + acceleration * dt, 0, math.max(maximum, self.speed))
        local grip = road and 1 or (0.50 + offroad * 0.42)
        local turn = self:TurnRate(steering or self.steer) * grip
        self.heading = wrap(self.heading + turn * dt * (1 - self.wheelie * 0.65))
        local fx, fz = direction(self.heading)
        local movement = self.speed * dt / math.sqrt(1 + slope * slope)
        self.x, self.z = self.x + fx * movement, self.z + fz * movement
        local ramps = (world and world.ramps) or self:Map(world).Ramps or {}
        local blocked,contact = TrackFeatures.BlockingFace(ramps,oldX,oldY,oldZ,self.x,oldY,self.z)
        if blocked then
            -- 连续碰撞停在接触面外侧，不把轮胎抬到侧壁顶部。
            local before=math.max(0,contact-.002/math.max(.001,movement))
            self.x,self.z=oldX+(self.x-oldX)*before,oldZ+(self.z-oldZ)*before
            self:Impact("碰到飞坡侧壁 · 从箭头入口上坡",math.min(25,5+self.speed*.35))
            self.speed=math.min(self.speed,2)
        end
        local nextGround = self:Surface(self.x, self.z, world)
        -- 兼容旧World测试的RampAt，同时扫描完整线段，避免一步跨完整坡漏起飞。
        local currentRamp = self:RampAt(oldX, oldZ, world) or self.ramp
        local candidates = ramps
        if currentRamp and #ramps==0 then candidates={currentRamp} end
        local ramp,lipTime=TrackFeatures.CrossLip(candidates,oldX,oldZ,self.x,self.z,self.heading,self.speed)
        local launched = false
        if ramp and not blocked and self.rampCooldown <= 0 then
            local grade=ramp.exitGrade or (ramp.height or 2)/(ramp.length or 10)
            local lipX=oldX+(self.x-oldX)*lipTime
            local lipZ=oldZ+(self.z-oldZ)*lipTime
            local lipY=TrackFeatures.RampHeight(ramp,lipX,lipZ) or (ramp.y or ground)+(ramp.height or 2)
            self:TakeOff(self.speed*grade/math.sqrt(1+grade*grade))
            -- 起跳点位于实际唇口，余下时间继续积分原重力弹道；不改水平位置。
            local remaining=dt*(1-lipTime)
            self.y=lipY+self.vY*remaining-GRAVITY*remaining*remaining*.5
            self.vY,self.airTime=self.vY-GRAVITY*remaining,remaining
            launched = true
        end
        if not launched then
            -- 从崖边/坡道侧边驶离：保留坡面竖直动量，由重力决定落地。
            if oldY - nextGround > math.max(0.12, self.speed * dt * 0.6) then
                self:TakeOff(self.groundVY)
            else
                self.y = nextGround
                self.groundVY = (nextGround - oldY) / dt
            end
        end
        if not self.airborne then self.ramp = self:RampAt(self.x, self.z, world) or false end
    end
    if self.airborne then
        -- 本步刚从坡道/崖边起飞时也消费这次点击，保留旧的起飞同帧空中操作。
        if not wasAirborne and self.spinTarget == 0 and requested ~= 0 then
            self:RequestSpin(requested, ground, slope)
        end
        if self.spinTarget ~= 0 then
            self.airSpin = approach(self.airSpin, self.spinTarget, dt * (math.abs(self.spinTarget) > 200 and 540 or 420))
            self.stuntAngle = self.airSpin
        end
        self.yaw = wrap(self.heading + self.airSpin)
        local landingGround = self:Surface(self.x, self.z, world)
        if self.y <= landingGround + 0.002 and self.vY <= 0 then self:Land(landingGround) end
    else
        self.yaw = self.heading
    end
    self.pitch = self.airborne and clamp(math.atan(self.vY, math.max(1, self.speed)) * DEG, -35, 35)
        or (math.atan(slope) * DEG + self.wheelieAngle)
    self.lean = -self.steer * clamp(self.speed * 1.1, 0, 36) * (self.airborne and 0.2 or 1)
    local dx, dz = self.x - oldX, self.z - oldZ
    local dy = self.y - oldY
    local traveled = math.sqrt(dx * dx + dz * dz + dy * dy)
    self.distance = self.distance + traveled
    self.score = self.score + traveled * (self.speed > 27.8 and 1.6 or 0.6)
    self.topSpeed = math.max(self.topSpeed, self.speed * 3.6) -- 保留旧 HUD 单位 km/h。
    return oldX, oldY, oldZ
end

-- 扫掠碰撞设计（米；不是渲染节点包围盒）：
-- 俯视：         汽车局部 +Z               侧视：汽车 [y,y+height]
--            +----------------+           载具 [y+altitude,y+altitude+ownH]
--            |  宽 width      |           ownH来自正式车型规则；上下分离不碰撞。
--            | 半长 halfLength|
--            +----------------+
-- 运动线段 p0 ---> p1；在汽车 yaw 局部坐标，用摩托半宽 .29、半长 .95
-- 的朝向投影扩张汽车盒。XYZ 三个轴共享同一进入/退出区间，不能只查帧末高度。
-- 擦边=盒外 .10..85m；高速/对向/横穿均扫掠。连续接触只扣一次，离开再撞
-- 才重新触发，并有2.2秒全局保护。World重生车辆必须同步previousX/Z/Y。
---@param world table?
function Sim:Traffic(world, x0, y0, z0, alpha0, alpha1)
    if not world or not world.traffic then return end
    -- 两张接触集合交替复用；仍按上一子步接触判定，连续接触不重复扣血。
    local active = self.nextContacts
    for car in pairs(active) do active[car] = nil end
    for _, car in ipairs(world.traffic) do
        if car.x and car.z then
            local cx0 = mix(car.previousX or car.x, car.x, alpha0)
            local cz0 = mix(car.previousZ or car.z, car.z, alpha0)
            local cx1 = mix(car.previousX or car.x, car.x, alpha1)
            local cz1 = mix(car.previousZ or car.z, car.z, alpha1)
            local cy = car.y or self:Surface(car.x, car.z, world)
            local cy0 = mix(car.previousY or cy, cy, alpha0)
            local cy1 = mix(car.previousY or cy, cy, alpha1)
            local sx, sz = direction(car.yaw or 0)
            local rx0, rz0 = x0 - cx0, z0 - cz0
            local rx1, rz1 = self.x - cx1, self.z - cz1
            local lx0, lz0 = rx0 * sz - rz0 * sx, rx0 * sx + rz0 * sz
            local lx1, lz1 = rx1 * sz - rz1 * sx, rx1 * sx + rz1 * sz
            local delta = (self.yaw - (car.yaw or 0)) * RAD
            local carWidth = car.width or (car.halfWidth and car.halfWidth * 2) or 1.85
            local mixed=require("MixedVehicles").Get(self.vehicleId)
            local ownW=mixed and mixed.size[1]*.5 or .29
            local ownL=mixed and mixed.size[3]*.5 or .95
            local halfWidth = carWidth * 0.5 + math.abs(math.cos(delta)) * ownW + math.abs(math.sin(delta)) * ownL
            local halfLength = (car.halfLength or 2.125) + math.abs(math.cos(delta)) * ownL + math.abs(math.sin(delta)) * ownW
            local hit, enter, leave = Sim.SweptHit(lx0, lx1, lz0, lz1, halfWidth, halfLength)
            local height = car.height or 1.8
            local ownH=mixed and mixed.size[2] or 1.45
            if hit then
                hit = interval(y0 + (self.oddAltitude or 0) + ownH * .5 - cy0 - height * 0.5,
                    self.y + (self.oddAltitude or 0) + ownH * .5 - cy1 - height * 0.5, (height + ownH) * 0.5, enter, leave)
            end
            if hit then
                active[car] = true
                if not self.contacts[car] then self:Impact() end
            end
            if not car.passed and lz0 <= 0 and lz1 > 0 and not hit
                and math.cos((self.heading - (car.yaw or 0)) * RAD) > 0.5
                and self.speed > math.abs(car.speed or 0) and math.abs(lx1) < halfWidth + 8
                and math.abs(self.y - cy1) < 2 then
                car.passed = true
                self.overtakes, self.score = self.overtakes + 1, self.score + 50
                local gap = math.abs(lx1) - halfWidth
                if gap > 0.1 and gap < 0.85 and self.speed > 16.67 and self.crashCooldown <= 0 then
                    self.nearMisses, self.score = self.nearMisses + 1, self.score + 200
                    self.message, self.messageTimer = "精准超越 +250", 2
                else
                    self.message, self.messageTimer = "安全超车 +50", 1.5
                end
            end
        end
    end
    self.nextContacts, self.contacts = self.contacts, active
end

-- 目标圆区域采用线段最近点，避免高速穿过漏记；按顺序到访，里程不能代替目标。
local function segmentDistance(x0, z0, x1, z1, x, z)
    local dx, dz = x1 - x0, z1 - z0
    local length2 = dx * dx + dz * dz
    local t = length2 > 0 and clamp(((x - x0) * dx + (z - z0) * dz) / length2, 0, 1) or 0
    local rx, rz = x0 + dx * t - x, z0 + dz * t - z
    return math.sqrt(rx * rx + rz * rz)
end
---@param world table?
function Sim:UpdateNavigation(oldX, oldZ, world, collect)
    local map = self:Map(world)
    self.roadS, self.lateral = map.NearestRoad(self.x, self.z)
    local ground, road, region = self:Surface(self.x, self.z, world)
    self.groundY, self.onRoad = ground, road
    self.regionName = region or (road and "山海公路" or "山野探索")
    local goals = world and world.Goals or map.Goals or {}
    self.goalsTotal = #goals
    local goal = goals[self.goalIndex]
    if not goal then
        self.goalName, self.goalDistance = "自由探索", 0
        self.navHeading, self.targetYaw = self.heading, self.heading
        return
    end
    local distance = math.sqrt((self.x - goal.x)^2 + (self.z - goal.z)^2)
    local radius = goal.radius or 15
    if not self.goalArmed and distance > radius + 2 then self.goalArmed = true end
    if collect and not self.raceMode and self.goalArmed and not self.airborne and not self.wrecked
        and self.y - ground < 3 and segmentDistance(oldX, oldZ, self.x, self.z, goal.x, goal.z) <= radius then
        self.goalsDone, self.goalIndex = self.goalsDone + 1, self.goalIndex + 1
        self.score, self.goalArmed = self.score + 350, false
        self.message, self.messageTimer = "已到达 " .. goal.name .. " +350", 3
        print("[导航] " .. self.message)
        if self.goalIndex > #goals then
            self.goalLaps = self.goalLaps + 1
            if self.challenge and self.remaining > 0 and self.health > 0 then
                self.success, self.finished = true, true
                self.score = self.score + self.remaining * 100
                self.message = "路线挑战完成 · 全部目标已到访"
            else
                self.message = "山海环游完成 · 继续下一圈探索"
            end
            self.goalIndex = 1
        end
        goal = goals[self.goalIndex]
        distance = math.sqrt((self.x - goal.x)^2 + (self.z - goal.z)^2)
    end
    self.goalName, self.goalDistance = goal.name, distance
    self.navHeading = wrap(math.atan(goal.x - self.x, goal.z - self.z) * DEG)
    self.targetYaw = self.navHeading
end

---@param world table?
function Sim:WorldLimits(dt, world)
    local map = self:Map(world)
    local bounds = map.Bounds
    self.atWorldEdge = false
    if bounds then
        local outside = math.max(bounds.minX - self.x, self.x - bounds.maxX,
            bounds.minZ - self.z, self.z - bounds.maxZ, 0)
        self.atWorldEdge = outside > 0
        if outside > 50 then
            self:Recover(world)
            self.message, self.messageTimer = "已离开可骑地形 · 安全返回公路", 4
            return true
        elseif outside > 0 then
            self.message, self.messageTimer = "世界边缘 · 请掉头或使用脱困", 1
        end
    end
    -- 地图显式声明水域才能判定，不能把任何低海拔路段误认为湖泊。
    self.waterDepth = 0
    if map.WaterDepth then
        self.waterDepth = math.max(0, map.WaterDepth(self.x, self.z) or 0)
    elseif map.IsWater and map.WaterLevel and map.IsWater(self.x, self.z) and not self.onRoad then
        self.waterDepth = math.max(0, map.WaterLevel - self.groundY)
    end
    if self.waterDepth > 0.25 and not self.airborne
        and self.vehicleId~="hovercraft" and self.vehicleId~="jellyfish" and self.vehicleId~="helicopter" then
        self.speed = math.max(0, self.speed - dt * (5 + self.waterDepth * 14))
        self.message, self.messageTimer = "涉水失速 · 使用脱困返回公路", 1
        self.waterTimer = self.waterDepth > 1.2 and (self.waterTimer + dt) or 0
        if self.waterTimer >= 5 then
            self:Recover(world)
            self.message, self.messageTimer = "深水滞留5秒 · 已安全返回公路", 4
            return true
        end
    else
        self.waterTimer = 0
    end
    -- Only an actual fall below the navigable world is an immediate automatic reset.
    if self.y < -120 then
        self:Recover(world)
        self.message, self.messageTimer = "掉出世界 · 已安全返回公路", 4
        return true
    end
    return false
end

---@param dt number
---@param controls table
---@param world table?
function Sim:Step(dt, controls, world)
    if self.finished or dt <= 0 or dt ~= dt or dt == math.huge then return end
    controls = controls or {}
    -- 输入为pulse；只在本次调用首个子步消费，避免低帧率多次换挡或重复发动特技。
    -- 持续输入复用实例缓冲，不给每个子步分配一张临时表，也不修改调用方controls。
    local held = self.heldControls
    held.throttle, held.steer, held.brake = controls.throttle, controls.steer, controls.brake
    held.clutch, held.wheelie = controls.clutch, controls.wheelie
    held.burnout, held.manual, held.boost = controls.burnout, controls.manual, controls.boost
    held.skill = controls.skill
    local count = math.max(1, math.ceil(dt / 0.02))
    local step = dt / count
    self.previousX, self.previousY, self.previousZ = self.x, self.y, self.z
    for index = 1, count do
        if self.finished then break end
        self.surfaceCacheEnabled, self.surfaceValid = true, false
        self.hitTimer = math.max(0, (self.hitTimer or 0) - step)
        if self.hitTimer <= 0 then self.hitShake = 0 end
        local input = index == 1 and controls or held
        self.elapsed = self.elapsed + step
        self.remaining = math.max(0, self.timeLimit - self.elapsed)
        self.messageTimer = math.max(0, self.messageTimer - step)
        self.crashCooldown = math.max(0, self.crashCooldown - step)
        self.stuntTimer = math.max(0, self.stuntTimer - step)
        self.stuntCooldown = math.max(0, self.stuntCooldown - step)
        if self.stuntTimer == 0 and not self.airborne then self.stuntLabel, self.stuntAngle = "", 0 end
        MixedRace.Before(self,step,input,self:Map(world))
        local steering = self:Steering(step, input.steer)
            * (self.oddGripScale or 1) * (self.motorcycleGripScale or 1)
        local drive = self:Powertrain(step, input)
            * (self.oddDriveScale or 1) * (self.motorcycleDriveScale or 1)
        self:GroundTricks(step, input, drive)
        local wasAirborne=self.airborne
        local x0, y0, z0 = self:Move(step, input, world, drive, steering)
        MixedRace.After(self,step,input,world,x0,y0,z0,wasAirborne)
        local feature,gain=TrackFeatures.StepBoost(self,self:Map(world),step,x0,y0,z0,wasAirborne)
        if feature and gain>0 then
            self.message,self.messageTimer="方向加速带 · 免费提速",1.8
            print(string.format("[道路机关] %s 提速 %.1fm/s，带冷却8秒",feature.id,gain))
        end
        self:Traffic(world, x0, y0, z0, (index - 1) / count, index / count)
        if not self.finished then
            -- 护栏先于世界边界：正常赛道上越界会撞栏回推，而不是直接瞬移回起点。
            local barrier = self:Barrier(step, world)
            local recovered = self:WorldLimits(step, world)
            if barrier then self:UpdateNavigation(x0, z0, world, false)
            elseif not recovered then self:UpdateNavigation(x0, z0, world, true) end
        end
        if self.raceMode then
            self.challenge, self.wrecked = false, false
            if self.crashCooldown <= 0 then self.health = math.min(100, self.health + step * 5) end
        end
        if self.challenge and not self.raceMode and self.remaining <= 0 and not self.success then
            self.finished = true
            self.message, self.messageTimer = "路线挑战超时 · 目标未全部到访", 4
        end
        self.surfaceCacheEnabled = false
    end
    self.logTimer = self.logTimer + dt
    if self.logTimer >= 15 then
        self.logTimer = 0
        print(string.format("[驾驶] %s %.0fkm/h 档%d %.0frpm 世界(%.0f,%.0f) 目标%s",
            self.vehicleId, self.speed * 3.6, self.gear, self.rpm, self.x, self.z, self.goalName))
    end
end

-- 完全确定性的纯Lua测试；不创建Scene/Vector3/引擎对象，不依赖实际Landscape。
function Sim.Test()
    local checks = 0
    local function check(condition, name)
        assert(condition, "[自测失败] " .. name)
        checks = checks + 1
    end
    local flat = {Goals = {}, RouteLength = 0, RoadPoint = FLAT.RoadPoint,
        Height = FLAT.Height, NearestRoad = FLAT.NearestRoad}
    local world = {traffic = {}, landscape = flat}
    local gas = {throttle = 1, steer = 0}
    local function advance(sim, seconds, controls, environment)
        for _ = 1, math.floor(seconds / 0.02 + 0.5) do sim:Step(0.02, controls or gas, environment or world) end
    end
    local sim = Sim.New(flat)
    advance(sim, 2, {throttle = 1, clutch = true})
    check(sim.speed == 0 and sim.rpm > 10000 and sim.clutchEngagement == 0, "离合分离可空转但不能驱动")
    advance(sim, 3)
    check(sim.speed > 15 and sim.clutchEngagement == 1 and sim.distance > 15, "离合接合后起步")
    local speed = sim.speed
    advance(sim, 0.5, {throttle = 0, clutch = true})
    check(sim.speed < speed and sim.speed > speed - 3, "离合分离保留滑行动量")
    advance(sim, 5, {brake = true})
    check(sim.speed == 0 and sim.rpm >= sim.vehicle.idle, "刹停而非倒车")
    sim:Reset(false)
    sim:Step(0.02, {manual = true, shiftDown = true, throttle = 1}, world)
    advance(sim, 1, {manual = true, throttle = 1})
    check(sim.gear == 0 and sim.speed == 0 and sim.rpm > 5000, "手动N挡动力断开")
    sim:Step(0.12, {manual = true, shiftUp = true}, world)
    check(sim.gear == 1, "大步长换挡pulse只消费一次")
    for _ = 1, 10 do sim:Step(0.02, {manual = true, shiftUp = true}, world) end
    check(sim.gear == 6, "手动挡上界6")
    for _ = 1, 10 do sim:Step(0.02, {manual = true, shiftDown = true}, world) end
    check(sim.gear == 0, "手动挡下界N")
    sim:Reset(false)
    advance(sim, 15)
    check(sim.gear >= 2 and sim.speed > 35 and sim.rpm <= sim.vehicle.redline, "自动变速及转速限制")
    local sportSpeed = sim.speed
    check(sim:SetVehicle("cruiser") and not sim:SetVehicle("unknown"), "车型选择校验")
    sim:Reset(false)
    advance(sim, 15)
    check(sim.vehicleId == "cruiser" and sim.speed < sportSpeed, "车型差异与Reset保留选择")
    sim:SetVehicle("rally")
    sim:Reset(false)
    advance(sim, 3, {throttle = 1, steer = 1})
    check(math.abs(sim.x) > 7.55 and math.abs(sim.heading) > 30, "自由转向不夹紧道路")
    local stoppedYaw = sim.heading
    sim.speed = 0
    advance(sim, 1, {steer = 1, spin360 = true})
    check(sim.heading == stoppedYaw and sim.airSpin == 0 and not sim.airborne
        and sim.message == "加速到15km/h再点特技", "低速不能原地旋转且给明确加速提示")
    -- 平地自由骑行单次点击：真实离地、完成指定角度、沿原弹道前进，非原地转模型。
    for _, degrees in ipairs({180, 360}) do
        sim:Reset(false)
        sim.speed = 4 -- 边界值4m/s可发动；提示向上取整为15km/h。
        local spinControls = degrees == 180 and {spin180 = true} or {spin360 = true}
        sim:Step(0.02, spinControls, world)
        check(sim.airborne and sim.y > 0 and sim.vY > 0 and sim.spinTarget == degrees
            and sim.stuntCooldown > 0 and not sim.manual and not sim.clutch,
            string.format("平地%d辅助起跳且保持自动变速", degrees))
        local firstSpin, firstVY = sim.airSpin, sim.vY
        sim:Step(0.02, spinControls, world)
        check(sim.spinTarget == degrees and sim.airSpin > firstSpin and sim.vY < firstVY
            and sim.message == "特技进行中 · 落地后再试" and sim.stuntCount == 0,
            string.format("%d空中重复点击不重置腾空或旋转且有反馈", degrees))
        local maxY = sim.y
        for _ = 1, 100 do
            sim:Step(0.02, {}, world)
            maxY = math.max(maxY, sim.y)
            if not sim.airborne then break end
        end
        check(not sim.airborne and sim.y == 0 and sim.landingStable and sim.health == 100
            and sim.stuntCount == 1 and sim.stuntAngle == degrees and sim.z > 3
            and maxY > 1 and math.abs(angleDelta(sim.heading, degrees)) < 0.01,
            string.format("平地%d完整旋转稳定落地奖励", degrees))
        sim.speed = 8
        sim:Step(0.02, spinControls, world)
        check(not sim.airborne and sim.spinTarget == 0 and sim.stuntCount == 1
            and sim.message:find("特技冷却中", 1, true) ~= nil,
            string.format("%d落地冷却重复点击不重发且有反馈", degrees))
        advance(sim, 1, gas)
        sim:Step(0.02, spinControls, world)
        check(sim.airborne and sim.spinTarget == degrees, string.format("%d冷却结束可再次发动", degrees))
    end
    sim:Reset(false)
    sim.speed = 3.99
    sim:Step(0.12, {spin360 = true}, world)
    check(not sim.airborne and sim.stuntCount == 0 and sim.stuntCooldown == 0
        and sim.message == "加速到15km/h再点特技", "低于4m/s拒绝特技且不耗冷却")
    sim:Reset(false)
    sim.speed = 8
    sim:Step(0.12, {spin360 = true}, world)
    check(sim.airborne and sim.airSpin > 60 and sim.airTime > 0.1
        and sim.message == "空中 360° · 街机特技", "大步长特技pulse只消费一次并保留发动反馈")
    local heldBuffer, contactsA, contactsB = sim.heldControls, sim.contacts, sim.nextContacts
    sim:Step(0.12, {}, world)
    check(sim.heldControls == heldBuffer and (sim.contacts == contactsA or sim.contacts == contactsB)
        and (sim.nextContacts == contactsA or sim.nextContacts == contactsB), "子步输入和接触集合复用避免临时table")
    sim:Reset(false)
    sim.speed = 12
    sim:Step(0.02, {brake = true, spin180 = true}, world)
    check(not sim.airborne and sim.stuntCooldown == 0
        and sim.message == "先稳住车身 · 平稳骑行后再点特技", "刹车中拒绝辅助跳并说明车身不稳")
    local surfaceCalls, surfaceLevel = 0, 0
    local measuredWorld = {traffic = {}, landscape = flat,
        Surface = function()
            surfaceCalls = surfaceCalls + 1
            return surfaceLevel, true, "测试地面"
        end}
    sim:Reset(false)
    sim.speed = 10
    sim:Step(0.02, {}, measuredWorld)
    check(surfaceCalls == 3 and sim.regionName == "测试地面", "同子步导航复用末位置精确Surface采样")
    surfaceCalls = 0
    surfaceLevel = 0.05
    sim:Step(0.02, {}, measuredWorld)
    check(surfaceCalls == 3 and sim.y == surfaceLevel, "Surface缓存不跨子步并保留实时地面碰撞")
    surfaceLevel = 0.10
    check(sim:Surface(sim.x, sim.z, measuredWorld) == 0.10, "Step外Surface调用不读陈旧缓存")
    local hill = {traffic = {}, landscape = flat, Surface = function(_, x) return math.max(0, x * 0.10), math.abs(x) < 5, "山地" end}
    sim:Reset(false)
    sim.heading, sim.yaw = 90, 90
    advance(sim, 5, gas, hill)
    check(sim.x > 15 and sim.y > 1.5 and not sim.onRoad and sim.regionName == "山地", "越野上山且y贴地")
    local rallyOffroad = sim.speed
    sim:SetVehicle("sport")
    sim:Reset(false)
    sim.heading, sim.yaw = 90, 90
    advance(sim, 5, gas, hill)
    check(rallyOffroad > sim.speed, "拉力车越野动力优势")
    sim:Reset(false)
    advance(sim, 1, {throttle = 1, brake = true})
    check(sim.burnout and sim.spin > 0.8 and sim.tireSmoke > 0.8 and sim.speed < 1, "刹车加油门烧胎")
    sim:Reset(false)
    advance(sim, 1, {throttle = 1, burnout = true})
    check(sim.burnout and sim.speed < 1, "显式烧胎")
    advance(sim, 1, {throttle = 1, clutch = true, burnout = true})
    check(not sim.burnout and sim.tireSmoke == 0, "离合切断后不能烧胎")
    sim:Reset(false)
    sim.speed = 10
    advance(sim, 0.8, {throttle = 1, wheelie = true})
    check(sim.wheelieAngle > 15, "低中速动力翘头")
    advance(sim, 0.3, {throttle = 1, wheelie = true, brake = true})
    check(sim.wheelieAngle == 0, "刹车制止翘头")
    sim:Reset(false)
    sim.speed = 8
    advance(sim, 2.2, {throttle = 0.7, wheelie = true})
    -- 强制处于危险抬头角，验证过高不是无代价动画。
    sim.wheelieAngle, sim.speed, sim.crashCooldown = 72, 15, 0
    sim:Step(0.02, {throttle = 1, wheelie = true}, world)
    check(sim.health < 100 and sim.wheelieAngle == 0, "翘头过高造成失稳损伤")
    local ramp = {x = 0, z = 5, y = 0, yaw = 0, length = 10, width = 4, height = 4}
    local jumpWorld = {traffic = {}, landscape = flat,
        RampAt = function(_, x, z) if math.abs(x) <= 2 and z >= 5 and z <= 15 then return ramp end end,
        Surface = function(_, x, z)
            return math.abs(x) <= 2 and z >= 5 and z <= 15 and (z - 5) * 0.4 or 0, true
        end}
    sim:Reset(false)
    sim.z, sim.y, sim.speed, sim.groundVY = 14.9, 3.96, 30, 10
    sim:Step(0.02, {clutch = true, spin180 = true}, jumpWorld)
    check(sim.airborne and sim.spinTarget == 180 and sim.airSpin > 0 and sim.vY > 5,
        "坡道起飞同帧点击仍沿用空中旋转而非丢失请求")
    sim:Reset(false)
    sim.speed = 30
    for _ = 1, 100 do
        sim:Step(0.02, {clutch = true}, jumpWorld)
        if sim.airborne then break end
    end
    check(sim.airborne and sim.vY > 5 and sim.y >= 4, "沿坡道末端触发真实飞跃")
    local takeoffYaw = sim.heading
    sim:Step(0.02, {spin180 = true}, jumpWorld)
    advance(sim, 0.5, {steer = 1}, jumpWorld)
    check(sim.airborne and sim.airSpin == 180 and sim.heading == takeoffYaw, "空中180视觉转向不弯曲弹道")
    for _ = 1, 200 do
        sim:Step(0.02, {}, jumpWorld)
        if not sim.airborne then break end
    end
    check(not sim.airborne and sim.y == 0 and sim.vY == 0 and math.abs(angleDelta(sim.heading, takeoffYaw + 180)) < 0.01
        and sim.stuntCount == 1, "180稳定落地改变朝向并奖励")
    sim:Reset(false)
    sim.y, sim.speed = 6, 20
    sim:TakeOff(6)
    sim:Step(0.02, {spin360 = true}, world)
    for _ = 1, 200 do sim:Step(0.02, {}, world) if not sim.airborne then break end end
    check(not sim.airborne and sim.stuntCount == 1 and math.abs(angleDelta(sim.heading, 0)) < 0.01
        and sim.stuntAngle == 360, "360完整一周稳定落地")
    sim:Reset(false)
    sim.y, sim.speed = 0.05, 10
    sim:TakeOff(-3)
    sim:Step(0.02, {spin360 = true}, world)
    check(not sim.airborne and not sim.landingStable and sim.health < 100 and sim.stuntCount == 0, "旋转未完成落地惩罚")
    local goalsWorld = {traffic = {}, landscape = flat, Goals = {
        {name = "第一站", x = 0, z = 10, radius = 1}, {name = "第二站", x = 0, z = 20, radius = 1}}}
    sim:Reset(true)
    sim.distance, sim.speed = 100000, 25
    sim:Step(0.02, gas, goalsWorld)
    check(not sim.finished and sim.goalsDone == 0 and sim.goalName == "第一站", "挑战不能以累计里程直接获胜")
    advance(sim, 1, {clutch = true}, goalsWorld)
    check(sim.success and sim.finished and sim.goalsDone == 2, "挑战按序到访全部目标获胜")
    sim:Reset(false)
    sim.speed = 25
    advance(sim, 1, {clutch = true}, goalsWorld)
    check(not sim.finished and sim.goalLaps == 1 and sim.goalIndex == 1, "自由模式目标循环不结束")
    local single = {traffic = {}, landscape = flat, Goals = {{name = "站点", x = 0, z = 0, radius = 2}}}
    sim:Reset(false)
    advance(sim, 1, {}, single)
    check(sim.goalsDone == 1, "停在目标圈不能无限刷目标")
    sim:Reset(true)
    sim.timeLimit = 0.05
    advance(sim, 0.1, {}, goalsWorld)
    check(sim.finished and not sim.success and sim.remaining == 0, "挑战超时")
    check(Sim.SweptHit(0, 0, -20, 20, 1.2, 3), "高速扫掠")
    check(not Sim.SweptHit(2, 2, -20, 20, 1.2, 3), "安全横向间距")
    local car = {x = 0, z = 5, y = 0, previousX = 0, previousZ = 5,
        halfLength = 2.125, width = 1.85, height = 1.8, yaw = 0, speed = 0}
    local trafficWorld = {traffic = {car}, landscape = flat}
    sim:Reset(false)
    sim.x, sim.y, sim.z = 0, 4, 10
    sim:Traffic(trafficWorld, 0, 4, 0, 0, 1)
    check(sim.health == 100, "整条扫掠高于车顶不碰撞")
    sim:Reset(false)
    sim.x, sim.y, sim.z = 0, 0, 15
    sim:Traffic(trafficWorld, 0, 3.5, 0, 0, 1)
    check(sim.health < 100, "扫掠中途下降到车身高度触发碰撞")
    sim:Reset(false)
    sim.x, sim.y, sim.z = 0, 12, 10
    sim:Traffic(trafficWorld, 0, 0, 0, 0, 1)
    check(sim.health == 100, "起飞后横向进入时高度已分离，不因起点高度误撞")
    sim:Reset(false)
    sim.yaw, sim.heading, sim.x, sim.z = 90, 90, 4, 5
    car.yaw = 90
    sim:Traffic(trafficWorld, -4, 0, 5, 0, 1)
    check(sim.health < 100, "旋转90度汽车局部盒碰撞")
    car.yaw = 0
    sim:Reset(false)
    car.previousX, car.x, car.previousZ, car.z = -5, 5, 0, 0
    sim:Step(0.1, {}, trafficWorld)
    check(sim.health < 100, "运动汽车横穿静止摩托仍扫掠碰撞")
    car.previousX, car.x, car.previousZ, car.z = 0, 0, 5, 5
    sim:Reset(false)
    sim.speed = 70
    advance(sim, 0.10, {clutch = true}, trafficWorld)
    check(sim.health < 100 and sim.speed < 25, "交通扫掠碰撞减速扣血")
    local hp = sim.health
    sim.speed, sim.x, sim.z = 0, 0, 5
    advance(sim, 3, {brake = true}, trafficWorld)
    check(sim.health == hp, "持续接触超过保护时间也不重复扣血")
    sim:Reset(false)
    sim.y, sim.speed = 5, 70
    sim:TakeOff(0)
    advance(sim, 0.12, {}, trafficWorld)
    check(sim.health == 100, "飞越汽车高度分离不碰撞")
    sim:Reset(false)
    sim.y, sim.speed = 4, 70
    sim:TakeOff(-10)
    sim:Traffic(trafficWorld, 0, 0, 0, 0, 1)
    check(sim.health == 100, "XYZ必须共享交集时刻，不能用不同时间的轴重叠")
    sim:Reset(false)
    sim.health, sim.x, sim.z, sim.y = 0, 80, 12, 20
    sim:TakeOff(2)
    sim:Recover(world)
    check(sim.x == 0 and sim.z == 12 and sim.y == 0 and not sim.airborne and sim.airSpin == 0
        and sim.speed == 0 and sim.health >= 40, "脱困回最近道路清空空中状态")
    check(sim.goalName == "自由探索" and sim.goalsTotal == 0, "无目标地图保持有效导航字段")
    sim:Reset(false)
    sim.speed = 20
    sim:Step(0.75, {clutch = true}, world)
    check(math.abs(sim.elapsed - 0.75) < 1e-6, "大步长完整推进而非悄悄截断")
    local deterministic = Sim.New(flat)
    deterministic.speed = 20
    for _ = 1, 38 do deterministic:Step(0.75 / 38, {clutch = true}, world) end
    check(math.abs(deterministic.speed - sim.speed) < 1e-9 and math.abs(deterministic.z - sim.z) < 1e-9,
        "子步长与同等固定步序列完全确定")
    local laneMap = {Goals = {}, RouteLength = 200, SpawnLaneOffset = 2.4,
        RoadPoint = function(s) return {x = s, y = 3, z = 0}, 90 end,
        Height = function(_, z) return 3 + z * 0.1, true end,
        NearestRoad = function(x, _) return x, 0 end}
    local laneSim = Sim.New(laneMap)
    check(math.abs(laneSim.x) < 1e-6 and math.abs(laneSim.z + 2.4) < 1e-6
        and math.abs(laneSim.y - 2.76) < 1e-6, "出生车道偏置按yaw向右并重采高度")
    laneSim.x, laneSim.z = 15, 20
    laneSim:Recover({landscape = laneMap})
    check(math.abs(laneSim.x - 15) < 1e-6 and math.abs(laneSim.z + 2.4) < 1e-6, "脱困回最近路段安全车道")
    local limitedMap = {Goals = {}, RouteLength = 0, RoadPoint = FLAT.RoadPoint,
        Height = FLAT.Height, NearestRoad = FLAT.NearestRoad,
        Bounds = {minX = -100, maxX = 100, minZ = -100, maxZ = 100},
        WaterDepth = function(x) return x < -50 and 2 or (x < -20 and 0.8 or 0) end}
    local limitedWorld = {landscape = limitedMap, traffic = {}}
    local limited = Sim.New(limitedMap)
    limited.x = 110
    limited:Step(0.02, {}, limitedWorld)
    check(limited.atWorldEdge and limited.x == 110, "世界边缘提示但不夹回道路")
    limited.x = 151
    limited:Step(0.02, {}, limitedWorld)
    check(limited.x == 0 and not limited.atWorldEdge, "超出可骑范围50m才安全脱困")
    limited.x, limited.speed, limited.crashCooldown = -30, 10, 0
    limited:Step(0.02, {clutch = true}, limitedWorld)
    check(limited.waterDepth == 0.8 and limited.speed < 9.8 and limited.x == -30, "浅水失速提示但非公路夹紧")
    limited.x = -60
    limited:Step(0.02, {}, limitedWorld)
    check(limited.x == -60 and limited.waterTimer > 0, "深水不会一接触就瞬移")
    advance(limited, 5, {}, limitedWorld)
    check(limited.x == 0 and limited.speed == 0, "深水滞留5秒才安全脱困")
    -- 转向回归：小幅纠偏、高速变道、低速掉头分别验收，不能用一刀切倍率掩盖问题。
    local gentleInput = 0.028773304368 -- 手机中心向右轻滑控件宽度10%的实际映射。
    local gentle = Sim.New(flat)
    gentle.speed = 60
    gentle:Step(0.02, {steer = gentleInput, clutch = true}, world)
    check(gentle.steer > 0 and gentle.steer < gentleInput * 0.15,
        "小舵量也按响应时间渐入而非一个子步瞬间到位")
    advance(gentle, 0.98, {steer = gentleInput, clutch = true})
    check(gentle.x > 0.02 and gentle.x < 0.15 and gentle.heading > 0 and gentle.heading < 0.3,
        "高速轻滑一秒仅微调车道且保留有效控制")
    local moderate = Sim.New(flat)
    moderate.speed = 60
    advance(moderate, 1, {steer = 0.393624237763, clutch = true})
    check(moderate.x > gentle.x * 5 and moderate.x < 2 and moderate.heading < 5,
        "中舵能响应道路弯道，但一秒不会突然横跨数条车道")
    for _, id in ipairs({"sport", "cruiser", "rally"}) do
        local fast = Sim.New(flat)
        fast:SetVehicle(id)
        fast.speed, fast.steer = fast.vehicle.maxSpeed, 1
        local before = fast.heading
        fast:Step(0.02, {steer = 1, clutch = true}, world)
        local lateralAcceleration = fast.speed * angleDelta(fast.heading, before) * RAD / 0.02
        check(lateralAcceleration > 25.8 and lateralAcceleration <= MAX_LATERAL_ACCEL + 0.000001
            and fast.cornerAssist > 0 and fast.speed < fast.vehicle.maxSpeed,
            id .. " 高速满舵可用但有界且持续弯中有限减速，不再锁死6.5")
    end
    local low = Sim.New(flat)
    low.speed = 5
    advance(low, 3, {steer = 1, clutch = true})
    check(low.heading > 170 and low.heading < 195 and low.x < 9 and math.abs(low.z) < 2,
        "低速5m/s满舵三秒完成可用的小半径掉头")
    local release = Sim.New(flat)
    release.speed = 60
    advance(release, 0.3, {steer = 0.393624237763, clutch = true})
    local heldSteer, heldHeading = release.steer, release.heading
    release:Step(0.02, {clutch = true}, world)
    check(release.steer > 0 and release.steer < heldSteer,
        "松手后模拟舵平滑回正，不瞬间跳零也不继续保持")
    advance(release, 0.48, {clutch = true})
    check(math.abs(release.steer) < 0.0025 and angleDelta(release.heading, heldHeading) < 0.3,
        "松手半秒回到中心且残余偏转有限")
    local settledHeading = release.heading
    advance(release, 0.5, {clutch = true})
    check(math.abs(release.steer) < 0.00002 and angleDelta(release.heading, settledHeading) < 0.002,
        "回正后不持续漂移舵量或反向过冲")
    local function laneChange(dt)
        local lane = Sim.New(flat)
        lane.speed = 60
        for _, phase in ipairs({{0.8, 0.42}, {0.8, -0.42}, {0.6, 0}}) do
            for _ = 1, math.floor(phase[1] / dt + 0.5) do
                lane:Step(dt, {steer = phase[2], clutch = true}, world)
            end
        end
        return lane
    end
    local reference = laneChange(1 / 120)
    check(reference.x > 2.5 and reference.x < 3.2 and math.abs(angleDelta(reference.heading, 0)) < 0.4
        and math.abs(reference.steer) < 0.002 and reference.z > 120,
        "高速左右渐进反打完成约一条车道变道并恢复直行")
    for _, dt in ipairs({1 / 60, 1 / 30, 0.1}) do
        local lane = laneChange(dt)
        check(math.abs(lane.x - reference.x) < 0.03 and math.abs(lane.z - reference.z) < 0.12
            and math.abs(angleDelta(lane.heading, reference.heading)) < 0.01
            and math.abs(lane.steer - reference.steer) < 1e-10,
            string.format("变道在dt=%.4f秒时轨迹和回正一致", dt))
    end
    -- 单独验证滤波解析积分；不能只测最终舵量而漏掉低帧率整步用末值的偏差。
    local filterA, filterB = Sim.New(flat), Sim.New(flat)
    local integratedA = filterA:Steering(0.4, 0.2) * 0.4
    local integratedB = 0.0
    for _ = 1, 40 do integratedB = integratedB + filterB:Steering(0.01, 0.2) * 0.01 end
    check(math.abs(filterA.steer - filterB.steer) < 1e-12 and math.abs(integratedA - integratedB) < 1e-12,
        "不同dt下入舵终值与整段平均转向量均一致")
    local returnA = filterA:Steering(0.4, 0) * 0.4
    local returnB = 0.0
    for _ = 1, 40 do returnB = returnB + filterB:Steering(0.01, 0) * 0.01 end
    check(math.abs(filterA.steer - filterB.steer) < 1e-12 and math.abs(returnA - returnB) < 1e-12,
        "不同dt下松手回正终值与残余转向量均一致")
    sim:Reset(false)
    advance(sim, 100)
    check(not sim.finished and sim.elapsed > 90 and sim.speed <= sim.vehicle.maxSpeed, "自由模式不限时且速度有界")
    print(string.format("[自测] %d 项自由驾驶确定性断言全部通过", checks))
    return true
end

-- Race extensions have a separate suite so legacy steering/stunts stay independently verifiable.
function Sim.TestRace()
    local checks = 0
    local function check(ok, name) assert(ok, "[Sim.TestRace] " .. name); checks = checks + 1 end
    local sim = Sim.New(FLAT)
    check(sim:SetVehicle("sport_test_variant") and sim.baseClass == "sport" and sim.vehicle.maxSpeed == 76,
        "variant前缀映射基础性能")
    sim.raceMode = true
    sim:Reset(true)
    check(not sim.challenge, "竞赛不启用旧challenge结算")
    sim.speed, sim.crashCooldown = 50, 0
    sim:Impact("竞速接触", 16)
    check(sim.speed >= 27.5 and sim.speed <= 36 and sim.health >= 15 and not sim.finished,
        "竞赛碰撞保留动量")
    sim:Step(4, {}, nil)
    check(sim.health > 84 and not sim.wrecked, "竞赛车况可恢复")
    sim.health, sim.crashCooldown = 1, 0
    sim:Impact("重接触", 90)
    check(sim.health == 15 and not sim.wrecked and not sim.finished, "重撞不会旧式报废结算")
    sim.speed, sim.gear, sim.rpm, sim.clutchEngagement = sim.vehicle.maxSpeed, 6, sim.vehicle.redline, 1
    sim:Step(1.5, {throttle = 1, boost = 999}, nil)
    check(sim.speed > sim.vehicle.maxSpeed and sim.speed <= sim.vehicle.maxSpeed * 1.25,
        "boost增速但仍受125%硬上限")
    local boostedSpeed = sim.speed
    sim:Step(0.02, {throttle = 1, boost = 0}, nil)
    check(sim.speed < boostedSpeed and sim.speed > boostedSpeed - 0.5, "氮气结束平滑滑行而非硬夹速度")
    local serial = sim.recoverySerial
    sim:Recover(nil)
    check(sim.recoverySerial == serial + 1 and sim.speed == 0, "脱困serial可供Race拒绝瞬移")
    print(string.format("[Sim.TestRace] %d项竞速驾驶断言通过", checks))
    return true
end

return Sim
