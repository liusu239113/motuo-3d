-- 确定性的道路空间车手；动力复用玩家的自动变速箱，路线与失误只影响自身表现。
-- 不依赖玩家名次、油门或距离，不回收车手，不前向瞬移。
local Simulation = require("Simulation")
local Mixed = require("MixedRace")
local function vehicleFor(race,r)
    return race.options.mixed and r.driveSim and r.driveSim.vehicle or race.sim.vehicle
end
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
    local level = clamp(tonumber(race.options.aiLevel) or 0.60, 0.4, 0.94)
    r.aiLevel = level
    r.skill = clamp(0.45 + ((index * 5) % 8) / 7 * 0.48
        + (level - 0.72) * 0.20 + difficulty * 0.06, 0.3, 0.95)
    -- 同层分支用同一参数；强度只来自赛前地图/难度，绝不读取玩家表现。
    r.speedFactor = clamp(0.48 + level * 0.20 + r.skill * 0.25 + difficulty * 0.02, 0.6, 0.93)
    local efficiency = clamp(0.36 + level * 0.24 + r.skill * 0.38 + difficulty * 0.025, 0.58, 0.96)
    r.acceleration = vehicleFor(race,r).acceleration * efficiency
    -- 高级图仍有真实断油、走宽和恢复窗口，不能用满级技术消除失误。
    r.mistakeTimer = 6 + race:Random() * 10
    r.mistakeGrace = 6 + level * 4 + r.skill * 4
    r.reactionTime = 0.26 + (1 - r.skill) * 0.28 + (1 - level) * 0.28 - difficulty * 0.03
    r.mistakeDuration, r.recoveryTimer, r.mistakeSeverity, r.mistakes = 0, 0, 0, 0
    r.mistakeLane, r.mistakeBias = r.lane, 0
    r.paceTarget, r.paceTimer, r.nitroCooldown = 0, 0, 0
    -- 每辆车只持有独立的传动状态；使用玩家选定车型，不按外观偷偷换更强引擎。
    if not r.isPlayer then
        local drive = Simulation.New(race.map)
        drive.vehicle, drive.vehicleId, drive.raceMode = race.sim.vehicle, race.sim.vehicleId, true
        drive.rpm = vehicleFor(race,r).idle
        if race.options.mixed then
            assert(drive:SetVehicle(r.vehicleId));drive:Reset(false)
            r.acceleration=drive.vehicle.acceleration*efficiency
        end
        r.driveSim = drive
        -- 预演使用独立变速箱，绝不推进实际挡位/RPM/换挡冷却。
        r.nitroPreview = {driveSim = Simulation.New(race.map)}
    end
    r.preferredLane = (index % 3 - 1) * 2.6
    r.laneHold, r.blockedTime, r.trafficHits, r.avoidances, r.passes = 0, 0, 0, 0, 0
    r.targetSpeed, r.distanceDriven = 0, 0
    -- 交通只在自身观察时钟上更新；不是20ms全知预测。漏看只延后反应，不关闭碰撞。
    r.perception = {timer = race:Random() * 0.35, age = 0, observations = {},
        period = 0.30 + (1-r.skill)*0.75 + (1-level)*0.30,
        missChance = 0.025 + (1-r.skill)*0.20, misses = 0, recovery = 0,
        recoveries = 0, recoverySeconds = 0}
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

function AI.CurveSpeed(race, r, boosting)
    -- 预演可请求喷射包络，不需要先扣氮或篡改实际boostTimer。
    local top = vehicleFor(race,r).maxSpeed * (r.speedFactor + ((boosting or r.boostTimer > 0) and 0.25 or 0))
        *(r.driveSim and r.driveSim.oddSpeedScale or 1)
    local level = r.aiLevel or 0.72
    local budget = (12 + level * 6 + r.skill * 2)*(race.options.mixed and vehicleFor(race,r).steering or 1)
        *(r.driveSim and r.driveSim.oddGripScale or 1)
    local braking = vehicleFor(race,r).braking * (0.65 + r.skill * 0.12)
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
    drive.vehicle, drive.speed = vehicleFor(race,r), r.speed
    local mistake = r.mistakeDuration > 0
    local recovery = r.recoveryTimer > 0 or (r.perception and r.perception.recovery > 0)
    local slowing = r.speed > target + 0.2
    local throttle = slowing and 0 or (mistake and 0 or (recovery and 0.42 or 1))
    -- 刹车、走宽与恢复时不能靠喷射自动补回0.9油门，剩余喷射时间照常消耗。
    -- 急弯/突发危险可以提前断开已授权喷射动力，但不能返还资源或延长计时。
    local index = math.floor((r.s % race.length) / race.aiProfileStep) + 1
    local sample = race.aiProfile[index]
    local boosted = r.boostTimer > 0 and not slowing and not mistake and not recovery
        and sample.curvature <= 0.012 and abs(r.lane) <= race.roadHalfWidth - 0.65
    local power = drive:Powertrain(dt, {throttle = throttle, boost = boosted and 1 or 0})*(drive.oddDriveScale or 1)
    local efficiency = clamp(r.acceleration / vehicleFor(race,r).acceleration, 0, 1)
    local onRoad = abs(r.lane) <= race.roadHalfWidth
    local traction = onRoad and 1 or vehicleFor(race,r).offroad
    local drag = 0.20 + r.speed * r.speed * 0.00115
        + (onRoad and 0 or 4.6 * (1 - vehicleFor(race,r).offroad * 0.55))
    local engineBrake = throttle < 0.05 and drive.clutchEngagement * min(1.8, r.speed * 0.12) or 0
    local slope = sample.slope or 0
    local acceleration = power * efficiency * traction - drag - engineBrake
        - 9.81 * slope / sqrt(1 + slope * slope)
    local braking = vehicleFor(race,r).braking * (0.65 + r.skill * 0.12)
    if slowing then acceleration = min(acceleration, -min(braking, (r.speed - target) * 2 + 1)) end
    local cap = vehicleFor(race,r).maxSpeed * (r.speedFactor + (boosted and 0.25 or 0))
        * (onRoad and 1 or 0.44 + vehicleFor(race,r).offroad * 0.52)*(drive.oddSpeedScale or 1)
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
    if race.options.mixed and race.options.world then
        for _,o in ipairs(race.options.world.mixedObstacles or {}) do
            if o.active then
                obstacles[#obstacles+1]={source=o,s=o.s,lane=o.lane,speed=0,
                    halfWidth=o.halfWidth,halfLength=o.halfLength,y=o.y,bike=false,mixed=true}
            end
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
local function eachObstacle(race, r, visit, sensed)
    local perception = r.perception
    local obstacles = sensed and perception and perception.observations or race.aiObstacles
    for _, o in ipairs(obstacles) do
        if abs(o.y - r.y) < 6 then visit(o) end
    end
    -- 可选坡是静态可见路障；不模拟AI飞跃，不准免费穿过或领取玩家加速带。
    for _, ramp in ipairs(race.map.Ramps or {}) do
        if ramp.optional and ramp.s then
            local reserved=max(ramp.length or 12,(ramp.landingEndS or (ramp.s+(ramp.length or 12)))-ramp.s)
            -- 整段坡/落地车道保留；只取当前附近的局部截面，避免174m长障碍的
            -- 中点离车太远而晚避让，或越过中点后误以为已可回线。
            local start=gap(ramp.s,r.s,race.length)
            local first,last=max(start,-8),min(start+reserved,max(75,r.speed*2.8))
            if last>=first then
                visit({source=ramp,s=r.s+(first+last)*0.5,lane=ramp.lateral or 0,
                    speed=0,halfWidth=(ramp.width or 2.8)*0.5,halfLength=(last-first)*0.5,
                    y=ramp.y or r.y,bike=false,ramp=true})
            end
        end
    end
    for _, other in ipairs(race.racers) do
        if other ~= r and not other.finished and not other.eliminated then
            local spec=require("MixedVehicles").Get(other.vehicleId)
            visit({source = other, s = other.s, lane = other.lane,
                destination = other.wantedLane, speed = other.speed, halfWidth = spec and spec.size[1]*.5 or .30,
                halfLength = spec and spec.size[3]*.5 or 1, y = other.y, bike = true})
        end
    end
end

function AI.Observe(race,r,dt)
    local p=assert(r.perception)
    p.age,p.timer=p.age+dt,p.timer-dt
    p.recovery=max(0,p.recovery-dt)
    if p.recovery>0 then p.recoverySeconds=p.recoverySeconds+dt end
    if p.timer>0 then return end
    p.timer,p.age=p.period,0
    for i=#p.observations,1,-1 do p.observations[i]=nil end
    local horizon=28+r.speed*(0.55+r.skill*0.45)
    for _,o in ipairs(race.aiObstacles) do
        local d=gap(o.s,r.s,race.length)
        if d>-8 and d<horizon and abs(o.y-r.y)<3 then
            -- 视野内也可能短暂漏判；急近车辆仍留有反应但不会凭空瞬移躲开。
            if race:Random()<p.missChance and d>6 then p.misses=p.misses+1
            else
                local bias=(race:Random()-.5)*(1-r.skill)*12
                p.observations[#p.observations+1]={source=o.source,s=o.s+bias,lane=o.lane,
                    speed=o.speed,halfWidth=o.halfWidth,halfLength=o.halfLength,y=o.y,bike=false}
            end
        end
    end
end

-- 喷射安全区（路线空间，米）：
--   当前lane ------ wantedLane（含车宽/车距）
--   o ===== 2.5秒实际可达行程 ===== | 反应距离 | 刹车到下一弯
-- 预演完整脉冲，沿途查制动包络；不是把整段路都按理论boost极速判死。
-- 急弯(半径<83m)、路肩、走宽/恢复、贴车/对向会车都不能发动。
function AI.NitroSafe(race, r)
    if r.speed < 8 or abs(r.lane) > race.roadHalfWidth - 0.65
        or abs(r.wantedLane - r.lane) > 0.6 or (r.hitTimer or 0) > 0 then return false end
    local clear = true
    local duration = 2.5
    local reach = r.speed * duration + 0.5 * vehicleFor(race,r).acceleration * 2.25 * duration^2
    eachObstacle(race, r, function(o)
        local d = gap(o.s, r.s, race.length)
        local relativeEnd = d + o.speed * duration - reach
        local margin = o.halfWidth + 0.30 + 0.65
        local low, high = min(r.lane, r.wantedLane) - margin, max(r.lane, r.wantedLane) + margin
        local crossing = o.lane >= low and o.lane <= high
        if o.destination then crossing = crossing
            or (min(o.lane, o.destination) <= high and max(o.lane, o.destination) >= low) end
        if crossing and min(d, relativeEnd) < o.halfLength + 8
            and max(d, relativeEnd) > -o.halfLength - 5 then clear = false end
    end)
    if not clear then return false end
    local preview = assert(r.nitroPreview)
    local live, drive = assert(r.driveSim), assert(preview.driveSim)
    drive.vehicle, drive.raceMode = vehicleFor(race,r), true
    drive.gear, drive.rpm = live.gear, live.rpm
    drive.shiftTimer, drive.clutchEngagement = live.shiftTimer, live.clutchEngagement
    preview.speed, preview.s, preview.lane = r.speed, r.s, r.lane
    preview.speedFactor, preview.acceleration = r.speedFactor, r.acceleration
    preview.skill, preview.aiLevel, preview.reactionTime = r.skill, r.aiLevel, r.reactionTime
    preview.boostTimer, preview.mistakeDuration, preview.recoveryTimer = duration, 0, 0
    local startSpeed, peakSpeed = r.speed, r.speed
    -- 至少1.2秒有效加速，之后允许提前收油/有限刹车；资源计时仍消耗完整2.5秒。
    -- 后半段不要求“永远满喷”，但任何弯点都必须有实际制动距离，不允许突然锁速。
    for frame = 1, 25 do
        local sample = race.aiProfile[math.floor((preview.s % race.length) / race.aiProfileStep) + 1]
        local target = AI.CurveSpeed(race, preview, preview.boostTimer > 0)
        local boostCap = vehicleFor(race,r).maxSpeed * (r.speedFactor + 0.25)
        local restricted = sample.curvature > 0.012 or target < min(boostCap, preview.speed - 0.2) - 1e-6
        if restricted then
            if frame <= 12 then return false end
            -- 制动包络仍按当前可用喷射上限计算，不能把“收油”误当瞬间掉到普通限速。
            local braking = vehicleFor(race,r).braking * (0.65 + r.skill * 0.12)
            if preview.speed > target + braking * 0.1 + 1 then return false end
            target = min(target, preview.speed - 0.25)
        end
        AI.Drive(race, preview, target, 0.1)
        peakSpeed = max(peakSpeed, preview.speed)
        local scale = max(0.45, abs(1 - (sample.turn or 0) * r.lane))
        preview.s = preview.s + preview.speed * 0.1 / sqrt(1 + (sample.slope or 0)^2) / scale
    end
    return peakSpeed > startSpeed + 2
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
    end, true)
    return score
end

function AI.Plan(race, r, dt)
    AI.Observe(race,r,dt)
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
    local hazard = false
    local horizon = max(75, r.speed * 2.8)
    eachObstacle(race, r, function(o)
        local d = gap(o.s, r.s, race.length)
        local margin = o.halfWidth + 0.30 + (o.bike and 0.42 or 0.50)
        if d > -o.halfLength - 1 and d < horizon and abs(o.lane - r.lane) < margin then
            if r.speed > o.speed + 0.5 or d < 12 then hazard = true end
        end
    end, true)
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
    end, true)
    -- 无油门或名次相关的橡皮筋；失误实质降低目标速度并断油，恢复期间也不能立即满动力。
    r.rubberBand = 0
    if r.mistakeDuration > 0 then target = min(target, r.mistakeSpeed) end
    local level = r.aiLevel or 0.60
    r.nitroCooldown = max(0, r.nitroCooldown - dt)
    -- 不抽“每帧中奖”随机数：在人的决策节奏上择机，低档/入门车也能出弯加速。
    if not hazard and r.mistakeDuration <= 0 and r.recoveryTimer <= 0
        and r.nitroCooldown <= 0 and r.nitro >= 45 and r.boostTimer <= 0
        and r.perception.recovery <= 0 and target >= r.speed - 0.2 then
        r.nitroCooldown = r.reactionTime -- 不安全时也限频，避免每20ms重跑完整预演。
        if AI.NitroSafe(race, r) and race:Boost(r) then
            r.nitroCooldown = 16 + (1 - level) * 10 + (1 - r.skill) * 2
            r.paceTarget = AI.CurveSpeed(race, r)
            target = r.paceTarget -- 已完成安全预演；真正增速仍只来自Drive/Powertrain。
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
        if not obstacle.mixed and dx * dx + dz * dz < 1600 then
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
                    local p=assert(r.perception)
                    p.recovery,p.recoveries=1.2+(1-r.skill)*1.2,p.recoveries+1
                    p.timer,r.decisionTimer,r.paceTimer=0,0,0
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
    if race.options.mixed then
        local drive=assert(r.driveSim)
        drive.x,drive.y,drive.z,drive.heading=r.x,r.y,r.z,r.yaw
        drive.roadS,drive.lateral,drive.speed,drive.steer=r.s,r.lane,r.speed,r.steer or 0
        drive.elapsed=race.elapsed;drive.groundSlope=(race.aiProfile[math.floor((r.s%race.length)/race.aiProfileStep)+1] or {}).slope or 0
        local useSkill=(drive.oddCooldown or 0)<=0 and (r.speed>10 or r.vehicleId=="cicada")
            and (math.floor(race.elapsed*2+r.index)%7==0)
        Mixed.Before(drive,dt,{skill=useSkill,steer=r.steer or 0},race.map)
        if drive.oddNitroGift then r.nitro=math.min(100,r.nitro+drive.oddNitroGift);drive.oddNitroGift=nil end
        r.speed=drive.speed
    end
    AI.Mistake(race, r, dt)
    local target = AI.Plan(race, r, dt)
    AI.Drive(race, r, target, dt)
    local oldLane, oldS = r.lane, r.s
    if not race.options.mixed then
        r.lane = approach(r.lane, r.wantedLane, min(r.speed * dt * 0.45, dt * (2.5 + r.skill)))
    else
        local own=require("MixedVehicles").Get(r.vehicleId)
        local agility=(own and own.grip or 1)*(r.driveSim and r.driveSim.oddGripScale or 1)
        r.lane=approach(r.lane,r.wantedLane,min(r.speed*dt*.45,dt*(2.5+r.skill)*agility))
    end
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
    if race.options.mixed then
        local drive=assert(r.driveSim)
        drive.x,drive.y,drive.z,drive.heading,drive.speed=r.x,r.y,r.z,r.yaw,r.speed
        Mixed.After(drive,dt,{},race.options.world,r.lastX,r.lastY,r.lastZ,false)
        local _,lane=race:Project(drive.x,drive.z)
        r.lane=clamp(lane,-race.corridor+1,race.corridor-1)
        r.x,r.y,r.z=drive.x,drive.y,drive.z
        r.speed=drive.speed
    end
    race:AdvanceGates(r, oldS, r.s, dt)
    if not r.finished then r.progress = min(r.s, r.nextGate - 0.001) end
    r.safeS = r.progress
end

return AI
