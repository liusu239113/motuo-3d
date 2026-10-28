-- 确定性的道路空间车手；动力复用玩家的自动变速箱，路线与失误只影响自身表现。
-- 不依赖玩家名次、油门或距离，不回收车手，不前向瞬移。
local Simulation = require("Simulation")
local AI = {}
local abs, min, max, sqrt = math.abs, math.min, math.max, math.sqrt
local RAD, DEG = math.pi / 180, 180 / math.pi
local function clamp(v, a, b) return max(a, min(b, v)) end
local function approach(v, goal, amount) return v + clamp(goal - v, -amount, amount) end
local function angle(a, b) return (a - b + 180) % 360 - 180 end
local function gap(a, b, length) return (a - b + length * 0.5) % length - length * 0.5 end

-- Skill is stratified, not eight lucky random rolls. Difficulty changes pace/anticipation,
-- not collision immunity, checkpoint rules or teleportation. Selected bike sets the race class.
function AI.Configure(race, r, index)
    local setting = race.options.difficulty or "normal"
    local difficulty = setting == "easy" and -1 or (setting == "hard" and 1 or 0)
    r.skill = clamp(0.45 + ((index * 5) % 8) / 7 * 0.48 + difficulty * 0.06, 0.3, 1)
    -- 赛道等级决定整组AI的强度：第一关明显放水，后段逐级提高。
    local level = clamp(tonumber(race.options.aiLevel) or 0.72, 0.4, 1.0)
    r.aiLevel = level
    -- 常规上限按0.72+等级×0.26+技术×0.05计算，叠加明确的难度修正，总上限0.96。
    -- 这只是限速，不是实际可达极速；真实传动、气阻、弯速与失误仍会降低平均速度。
    local topFactor = 0.72 + level * 0.26
    r.speedFactor = clamp(topFactor + r.skill * 0.05 + difficulty * 0.03, 0.6, 0.96)
    r.acceleration = race.sim.vehicle.acceleration * (0.58 + level * 0.26 + r.skill * 0.10 + difficulty * 0.04)
    -- 每个AI有独立失误节奏：偶发弯心判断偏差、短暂收油与失误后重新找线。
    -- 失误只降低自身表现，不给碰撞免疫、不改检查点规则、不瞬移。
    r.mistakeTimer = 6 + race:Random() * 10
    r.mistakeGrace = 7 + r.skill * 7
    r.reactionTime = 0.30 + (1 - r.skill) * 0.38
    r.mistakeDuration, r.recoveryTimer, r.mistakeSeverity = 0, 0, 0
    r.mistakeLane, r.mistakeBias = r.lane, 0
    r.paceTarget, r.paceTimer, r.nitroCooldown = 0, 0, 0
    -- 每辆车只持有独立的传动状态；使用玩家选定车型，不按外观偷偷换更强引擎。
    if not r.isPlayer then
        local drive = Simulation.New(race.map)
        drive.vehicle, drive.vehicleId, drive.raceMode = race.sim.vehicle, race.sim.vehicleId, true
        drive.rpm = race.sim.vehicle.idle
        r.driveSim = drive
    end
    r.preferredLane = (index % 3 - 1) * 2.6
    r.laneHold, r.blockedTime, r.trafficHits, r.avoidances, r.passes = 0, 0, 0, 0, 0
    r.targetSpeed, r.distanceDriven = 0, 0
    r.trafficContacts, r.nextTrafficContacts = {}, {}
    r.lastObstacle = false
end

function AI.Build(race)
    -- Cached centre-line curvature uses positions, not the piecewise-constant sample yaw.
    -- It therefore sees the real 12m-radius hairpin without braking at every sample seam.
    local count = max(16, math.ceil(race.length / 5))
    local profile = {}
    for i = 1, count do
        local s = (i - 1) * race.length / count
        local a, b, c = race:Pose(s - 4, 0), race:Pose(s, 0), race:Pose(s + 4, 0)
        local u, v = math.atan(b.x - a.x, b.z - a.z), math.atan(c.x - b.x, c.z - b.z)
        local turn = angle(v * DEG, u * DEG) * RAD / 4
        profile[i] = {curvature = abs(turn), turn = turn, slope = (c.y - a.y) / 8}
    end
    race.aiProfile, race.aiProfileStep = profile, race.length / count
end

function AI.CurveSpeed(race, r)
    -- 与玩家同为最高车速加25%上限；实际增速仍须经传动、换挡与气阻，不能跳到新上限。
    local top = race.sim.vehicle.maxSpeed * (r.speedFactor + (r.boostTimer > 0 and 0.25 or 0))
    local level = r.aiLevel or 0.72
    local budget = 12 + level * 6 + r.skill * 2
    local braking = race.sim.vehicle.braking * (0.65 + r.skill * 0.12)
    -- 反应距离先从可用制动距离扣除；入弯前收油，不等到弯心突然锁速。
    local reaction = r.speed * r.reactionTime + 5
    local horizon = max(75, r.speed * r.speed / (2 * braking) + reaction + 15)
    local profile, step = race.aiProfile, race.aiProfileStep
    local start = math.floor((r.s % race.length) / step)
    for k = 0, math.ceil(horizon / step) do
        local sample = profile[(start + k) % #profile + 1]
        local d = max(0, k * step - step - reaction)
        local safe = sqrt(budget / max(0.0001, sample.curvature))
        top = min(top, sqrt(safe * safe + 2 * braking * d))
    end
    return max(8, top)
end

-- 收油失误与恢复分开：先真实减速，再缓慢重新接油；高水平也有可利用的失误窗口。
function AI.Mistake(race, r, dt)
    local wasMistaking = r.mistakeDuration > 0
    r.mistakeDuration = max(0, r.mistakeDuration - dt)
    if wasMistaking and r.mistakeDuration <= 0 then
        r.recoveryTimer = 1.0 + (1 - r.skill) * 0.9
        r.paceTimer, r.decisionTimer = 0, 0
    else r.recoveryTimer = max(0, r.recoveryTimer - dt) end
    r.mistakeTimer = r.mistakeTimer - dt
    if r.mistakeTimer <= 0 and r.mistakeDuration <= 0 and r.recoveryTimer <= 0 then
        r.mistakeSeverity = 0.18 + (1 - r.skill) * 0.14
        r.mistakeSpeed = r.speed * (1 - r.mistakeSeverity)
        r.mistakeDuration = 1.35 + (1 - r.skill) * 1.2
        r.mistakeTimer = r.mistakeDuration + r.mistakeGrace + race:Random() * 7
        r.mistakes = (r.mistakes or 0) + 1
        local index = math.floor((r.s % race.length) / race.aiProfileStep) + 1
        local turn = race.aiProfile[index].turn or 0
        local side = abs(turn) > 0.001 and (turn > 0 and -1 or 1) or (race:Random() < 0.5 and -1 or 1)
        r.mistakeBias = side * (1.1 + race:Random() * 0.7)
        r.mistakeLane = clamp(r.lane + r.mistakeBias, -race.roadHalfWidth + 0.7, race.roadHalfWidth - 0.7)
        r.paceTimer, r.decisionTimer = 0, 0
        race:Emit("ai-mistake", r.id)
    end
end

-- 只复用玩家的动力入口，不跑第二套世界/碰撞/导航，更不会改动玩家的传动状态。
function AI.Drive(race, r, target, dt)
    local drive = assert(r.driveSim)
    drive.vehicle, drive.speed = race.sim.vehicle, r.speed
    local mistake = r.mistakeDuration > 0
    local recovery = r.recoveryTimer > 0
    local slowing = r.speed > target + 0.2
    local throttle = slowing and 0 or (mistake and 0 or (recovery and 0.42 or 1))
    -- 刹车、走宽与恢复时不能靠喷射自动补回0.9油门，剩余喷射时间照常消耗。
    local boosted = r.boostTimer > 0 and not slowing and not mistake and not recovery
    local power = drive:Powertrain(dt, {throttle = throttle, boost = boosted and 1 or 0})
    local efficiency = clamp(r.acceleration / race.sim.vehicle.acceleration, 0, 1)
    local onRoad = abs(r.lane) <= race.roadHalfWidth
    local traction = onRoad and 1 or race.sim.vehicle.offroad
    local drag = 0.20 + r.speed * r.speed * 0.00115
        + (onRoad and 0 or 4.6 * (1 - race.sim.vehicle.offroad * 0.55))
    local engineBrake = throttle < 0.05 and drive.clutchEngagement * min(1.8, r.speed * 0.12) or 0
    local index = math.floor((r.s % race.length) / race.aiProfileStep) + 1
    local slope = race.aiProfile[index].slope or 0
    local acceleration = power * efficiency * traction - drag - engineBrake
        - 9.81 * slope / sqrt(1 + slope * slope)
    local braking = race.sim.vehicle.braking * (0.65 + r.skill * 0.12)
    if slowing then acceleration = min(acceleration, -min(braking, (r.speed - target) * 2 + 1)) end
    local cap = race.sim.vehicle.maxSpeed * (r.speedFactor + (boosted and 0.25 or 0))
        * (onRoad and 1 or 0.44 + race.sim.vehicle.offroad * 0.52)
    if r.speed > cap then acceleration = min(acceleration, -3.5 - (r.speed - cap) * 0.45) end
    r.speed = clamp(r.speed + acceleration * dt, 0, max(r.speed, min(target, cap)))
    r.driveAcceleration = acceleration
end

function AI.Snapshot(race)
    local obstacles = race.aiObstacles
    for i = #obstacles, 1, -1 do obstacles[i] = nil end
    for _, car in ipairs(race.traffic) do
        if type(car.x) == "number" and type(car.z) == "number" then
            local s, lane = car.s, car.lane
            if s == nil or lane == nil then s, lane = race:Project(car.x, car.z) end
            local _, yaw = race.map.RoadPoint(s)
            local aligned = math.cos(angle(car.yaw or yaw, yaw) * RAD)
            obstacles[#obstacles + 1] = {source = car, s = s, lane = lane,
                speed = abs(car.speed or 0) * aligned, halfWidth = (car.width or 1.9) * 0.5,
                halfLength = car.halfLength or 2.2, y = car.y or 0, bike = false}
        end
    end
end

-- Avoidance geometry in route space (metres):
--              +s
--       car [width/2 + .30 bike + .45 clearance]
--              |  longitudinal half-length + bike1 +2m buffer
--     bike o --+----> choose a clear lateral corridor BEFORE braking to a stop.
-- Same/opposing traffic use signed relative speed and wrapped physical gap. Racers on
-- different laps still collide physically. Adjacent bikes reserve their destination lane.
-- A changing lane must also clear traffic currently beside/behind it, not just the endpoint.
local function eachObstacle(race, r, visit)
    for _, o in ipairs(race.aiObstacles) do
        if abs(o.y - r.y) < 6 then visit(o) end
    end
    for _, other in ipairs(race.racers) do
        if other ~= r and not other.finished and not other.eliminated then
            visit({source = other, s = other.s, lane = other.lane,
                destination = other.wantedLane, speed = other.speed, halfWidth = 0.30,
                halfLength = 1, y = other.y, bike = true})
        end
    end
end

local function laneScore(race, r, candidate, horizon)
    local score = abs(candidate - r.preferredLane) * 0.18 + abs(candidate - r.lane) * 0.22
    local laneTime = abs(candidate - r.lane) / (2.5 + r.skill) + 0.32
    eachObstacle(race, r, function(o)
        local d = gap(o.s, r.s, race.length)
        if abs(d) > horizon then return end
        local margin = o.halfWidth + 0.30 + (o.bike and 0.48 or 0.55)
        local closing = r.speed - o.speed
        local arrival = closing > 0.1 and (d - o.halfLength - 2) / closing or 99
        local atLaneChange = d - closing * min(laneTime, 1.5)
        local beside = abs(d) < o.halfLength + 4 or abs(atLaneChange) < o.halfLength + 4
        local crosses = candidate >= min(r.lane, o.lane) - margin
            and candidate <= max(r.lane, o.lane) + margin
            and o.lane >= min(r.lane, candidate) - margin and o.lane <= max(r.lane, candidate) + margin
        if beside and crosses then score = score + 600 end
        if abs(candidate - o.lane) < margin then
            if d > -o.halfLength - 3 and (d < 12 or arrival < 3.5) then
                score = score + 160 + max(0, 4 - arrival) * 45
            elseif d > 0 then score = score + 18 / max(1, d / 8) end
        end
        if o.bike and o.destination and abs(candidate - o.destination) < 0.8 and abs(d) < 12 then
            score = score + 35 -- reservation, not mutual parking priority.
        end
    end)
    return score
end

function AI.Plan(race, r, dt)
    r.laneHold = max(0, r.laneHold - dt)
    r.decisionTimer = r.decisionTimer - dt
    r.paceTimer = r.paceTimer - dt
    -- 正常加油/找线按人的反应节奏采样；紧急避障与前方制动包络始终保留安全优先权。
    local safeTarget = AI.CurveSpeed(race, r)
    if r.paceTimer <= 0 then
        r.paceTimer = r.reactionTime
        r.paceTarget = safeTarget
    end
    local target = min(r.paceTarget, safeTarget)
    local hazard, nearest = false, math.huge
    local horizon = max(75, r.speed * 2.8)
    eachObstacle(race, r, function(o)
        local d = gap(o.s, r.s, race.length)
        local margin = o.halfWidth + 0.30 + (o.bike and 0.42 or 0.50)
        if d > -o.halfLength - 1 and d < horizon and abs(o.lane - r.lane) < margin then
            if d < nearest then nearest = d end
            if r.speed > o.speed + 0.5 or d < 12 then hazard = true end
        end
    end)
    if r.decisionTimer <= 0 then
        r.decisionTimer = r.reactionTime
        local bound = max(2, race.roadHalfWidth - 0.65)
        local shoulder = min(race.corridor - 0.35,
            race.map.Roads and race.map.Roads[1] and (race.map.Roads[1].shoulder or bound) - 0.5 or bound)
        local outer = hazard and max(bound, shoulder) or bound
        local candidates = {r.wantedLane, -bound, -2.4, 0, 2.4, bound, r.preferredLane, -outer, outer}
        local best, bestScore = r.wantedLane, laneScore(race, r, r.wantedLane, horizon)
        for _, lane in ipairs(candidates) do
            local candidate = clamp(lane, -outer, outer)
            local score = laneScore(race, r, candidate, horizon)
                + (abs(candidate) > bound + 0.1 and 5 or 0)
            if r.laneHold > 0 and abs(candidate - r.wantedLane) > 0.2 then score = score + 14 end
            if score < bestScore - 0.05 then best, bestScore = candidate, score end
        end
        if r.mistakeDuration > 0 and not hazard
            and laneScore(race, r, r.mistakeLane, horizon) < 100 then
            -- 目标相对失误起点固定；有并行车辆时优先避让，不故意往邻车身上撞。
            best = r.mistakeLane
        end
        if abs(best - r.wantedLane) > 0.25 then
            if hazard then r.avoidances = r.avoidances + 1 end
            r.wantedLane, r.laneHold = best, 0.9 + (1 - r.skill) * 0.5
        end
    end
    -- Longitudinal control remains active while changing lanes, never accelerates THROUGH a car.
    eachObstacle(race, r, function(o)
        local d = gap(o.s, r.s, race.length)
        local margin = o.halfWidth + 0.30 + (o.bike and 0.32 or 0.40)
        if d > 0 and d < horizon and abs(o.lane - r.lane) < margin then
            local clear = max(0, d - o.halfLength - 2.5)
            local follow = max(0, o.speed) + clear / (o.bike and 0.65 or 1.0)
            if o.speed < 0 then follow = max(0, clear / 1.0 - abs(o.speed) * 0.4) end
            target = min(target, follow)
        end
    end)
    -- 无油门或名次相关的橡皮筋；失误实质降低目标速度并断油，恢复期间也不能立即满动力。
    r.rubberBand = 0
    if r.mistakeDuration > 0 then target = min(target, r.mistakeSpeed) end
    local level = r.aiLevel or 0.72
    r.nitroCooldown = max(0, r.nitroCooldown - dt)
    local straight = true
    local boostTop = race.sim.vehicle.maxSpeed * (r.speedFactor + 0.25)
    local start = math.floor((r.s % race.length) / race.aiProfileStep)
    local boostHorizon = max(90, boostTop * (2.5 + r.reactionTime))
    for k = 0, math.ceil(boostHorizon / race.aiProfileStep) do
        local sample = race.aiProfile[(start + k) % #race.aiProfile + 1]
        if sample.curvature * boostTop * boostTop > (12 + level * 6 + r.skill * 2) * 0.7 then
            straight = false; break
        end
    end
    if not hazard and straight and r.mistakeDuration <= 0 and r.recoveryTimer <= 0
        and r.nitroCooldown <= 0 and r.nitro >= 55 and r.boostTimer <= 0
        and r.speed > 24 and level >= 0.72 and target > r.speed + 2
        and target > race.sim.vehicle.maxSpeed * 0.85 and race:Random() < dt * (0.08 + level * 0.16) then
        if race:Boost(r) then
            r.nitroCooldown = 9 + race:Random() * 9
            r.paceTarget = AI.CurveSpeed(race, r)
            target = min(r.paceTarget, target + race.sim.vehicle.maxSpeed * 0.25)
        end
    end
    r.targetSpeed = target
    r.blockedTime = target < 3 and r.blockedTime + dt or 0
    return target
end

function AI.TrafficContacts(race, r)
    local active = r.nextTrafficContacts
    for car in pairs(active) do active[car] = nil end
    for _, obstacle in ipairs(race.aiObstacles) do
        local car = obstacle.source
        local dx, dz = r.x - car.x, r.z - car.z
        if dx * dx + dz * dz < 1600 then
            local yaw = (car.yaw or 0) * RAD
            local sx, sz = math.sin(yaw), math.cos(yaw)
            local delta = (r.yaw - (car.yaw or 0)) * RAD
            local w = obstacle.halfWidth + abs(math.cos(delta)) * 0.30 + abs(math.sin(delta)) * 0.95
            local l = obstacle.halfLength + abs(math.cos(delta)) * 0.95 + abs(math.sin(delta)) * 0.30
            local ox, oz = r.lastX - (car.previousX or car.x), r.lastZ - (car.previousZ or car.z)
            local hit = race.sim.SweptHit(ox * sz - oz * sx, dx * sz - dz * sx,
                ox * sx + oz * sz, dx * sx + dz * sz, w, l)
            if hit and abs(r.y - (car.y or r.y)) < (car.height or 1.8) then
                active[car] = true
                if not r.trafficContacts[car] then
                    r.speed = r.speed * 0.66
                    r.trafficHits, r.laneHold = r.trafficHits + 1, 0
                    race:Collision(r)
                    race:Emit("traffic-contact", r.id)
                end
            end
        end
    end
    r.nextTrafficContacts, r.trafficContacts = r.trafficContacts, active
end

function AI.Update(race, r, dt)
    if r.isPlayer or r.finished or r.eliminated then return end
    r.lastX, r.lastY, r.lastZ = r.x, r.y, r.z
    AI.Mistake(race, r, dt)
    local target = AI.Plan(race, r, dt)
    AI.Drive(race, r, target, dt)
    local oldLane, oldS = r.lane, r.s
    r.lane = approach(r.lane, r.wantedLane, min(r.speed * dt * 0.45, dt * (2.5 + r.skill)))
    -- 走宽、换线和上坡都消耗实际行程，不把更长的外线仍当中心线免费前进。
    local sample = race.aiProfile[math.floor((r.s % race.length) / race.aiProfileStep) + 1]
    local lateralSpeed = (r.lane - oldLane) / max(dt, 0.00001)
    local pathScale = max(0.45, abs(1 - (sample.turn or 0) * (r.lane + oldLane) * 0.5))
    local forwardSpeed = sqrt(max(0, r.speed * r.speed - lateralSpeed * lateralSpeed))
        / sqrt(1 + (sample.slope or 0)^2) / pathScale
    r.s = r.s + forwardSpeed * dt
    race:Place(r)
    local traveled = sqrt((r.x - r.lastX)^2 + (r.z - r.lastZ)^2)
    r.distanceDriven = r.distanceDriven + traveled
    r.steer = clamp((r.lane - oldLane) / max(dt, 0.00001) * 0.24, -1, 1)
    r.lean = -r.steer * min(28, r.speed * 0.5)
    AI.TrafficContacts(race, r)
    race:AdvanceGates(r, oldS, r.s, dt)
    if not r.finished then r.progress = min(r.s, r.nextGate - 0.001) end
    r.safeS = r.progress
end

return AI
