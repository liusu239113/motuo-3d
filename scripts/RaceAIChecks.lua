-- 纯 Lua 确定性回归：require("RaceAIChecks").Run()，不操作实际 HUD 或活动比赛。
local AI = require("RaceAI")
local Race = require("Race")
local Sim = require("Simulation")
local Checks = {}
local DT = 0.02
local function flatMap()
    return {RouteLength = 10000, Goals = {}, Roads = {{width = 4.8, shoulder = 6}},
        RoadPoint = function(s) return {x = 0, y = 0, z = s}, 0 end,
        Height = function() return 0, true end,
        NearestRoad = function(x, z) return z, x end}
end

-- 用可控直线剖面隔离驾驶逻辑，仍调用真实配置、规划、动力、资源与喷射授权。
local function fixture(seed, vehicleId, level, difficulty)
    local map = flatMap()
    local sim = Sim.New(map)
    assert(sim:SetVehicle(vehicleId or "sport"))
    sim.raceMode = true
    local race = {sim = sim, map = map, options = {aiLevel = level or 0.72,
        difficulty = difficulty or "normal", quiet = true}, length = map.RouteLength,
        roadHalfWidth = 4.8, corridor = 5.6, aiProfileStep = 5, aiProfile = {},
        aiObstacles = {}, racers = {}, traffic = {}, phase = "racing", elapsed = 0,
        rng = seed or 31, events = {}, eventSeq = 0}
    setmetatable(race, {__index = Race})
    for i = 1, 2000 do race.aiProfile[i] = {curvature = 0, turn = 0, slope = 0} end
    local r = {id = "ai1", isPlayer = false, finished = false, eliminated = false,
        x = 0, y = 0, z = 0, yaw = 0, s = 0, speed = 0, lane = 0, wantedLane = 0,
        boostTimer = 0, nitro = 100, slipstream = 0, immunity = 0,
        decisionTimer = 0, mistakes = 0, progress = 0, nextGate = 85,
        lastX = 0, lastY = 0, lastZ = 0, mistakeDuration = 0, recoveryTimer = 0}
    AI.Configure(race, r, 1)
    race.racers = {r}
    -- 单元测试只隔离检查点结算，真实比赛仍完全使用Race的扫掠门线判定。
    race.AdvanceGates = function(_, racer) racer.nextGate = racer.s + 85 end
    return race, r
end

local function tick(race, r)
    race.elapsed = race.elapsed + DT
    race:Resources(r, DT)
    AI.Update(race, r, DT)
    r.boostTimer = math.max(0, r.boostTimer - DT)
    if r.boostTimer < 1e-8 then r.boostTimer = 0 end
end

function Checks.Run()
    local result = {passed = false, assertions = 0, groups = {}}
    local function check(ok, message)
        assert(ok, "[RaceAIChecks] " .. message)
        result.assertions = result.assertions + 1
    end
    local function passed(name)
        result.groups[#result.groups + 1] = name
        print("[RaceAIChecks] PASS " .. name)
    end
    for _, id in ipairs({"sport", "cruiser", "rally", "sport_3"}) do
        for _, difficulty in ipairs({"easy", "normal", "hard"}) do
            local race, r = fixture(31, id, 1, difficulty)
            local player = Sim.New(race.map)
            player.vehicle, player.raceMode = race.sim.vehicle, true
            player.rpm = player.vehicle.idle
            r.mistakeTimer, r.nitroCooldown = 1000, 1000
            -- 同车型同速度同挡位的逐步动力比较，覆盖启动、换挡、高速和喷射结束。
            for frame = 1, 500 do
                if frame == 301 then
                    check(race:Boost(r) and r.nitro == 55 and r.boostTimer == 2.5, "喷射统一耗45并持续2.5秒")
                end
                local boosted = r.boostTimer > 0
                player.speed = r.speed
                local before, oldGear = r.speed, r.driveSim.gear
                local drive = player:Powertrain(DT, {throttle = 1, boost = boosted and 1 or 0})
                local expected = drive - 0.20 - before * before * 0.00115
                AI.Drive(race, r, 1000, DT)
                check(r.speed <= math.max(0, before + expected * DT) + 1e-8,
                    id .. "/" .. difficulty .. "每步加速不得超过玩家真实传动减气阻")
                check(r.driveSim.gear == player.gear and r.driveSim.shiftTimer == player.shiftTimer,
                    "AI必须经历玩家相同自动换挡断动力")
                check(r.speed <= math.max(before, player.vehicle.maxSpeed * (boosted and 1.25 or 1)) + 1e-8,
                    "AI不超玩家绝对车速上限且不瞬间吸附新上限")
                if frame == 301 then
                    check(r.speed - before <= player.vehicle.acceleration * 2.25 * DT,
                        "喷射第一步受同车真实加速度约束，不能跃升到1.2倍上限")
                end
                if oldGear ~= r.driveSim.gear then check(r.driveSim.clutchEngagement == 0, "换挡要断开动力") end
                r.boostTimer = math.max(0, r.boostTimer - DT)
                if r.boostTimer < 1e-8 then r.boostTimer = 0 end
            end
        end
    end
    passed("四车型三难度真实动力及氮气包络")

    -- 不把玩家速度强行同步给AI：独立实际跑60秒，普通持续油门应能追回起始20米差距。
    for _, id in ipairs({"sport", "cruiser", "rally"}) do
        local racing, opponent = fixture(111, id)
        local player = Sim.New(racing.map)
        player.vehicle, player.raceMode = racing.sim.vehicle, true
        player.rpm = player.vehicle.idle
        player.z = -20
        for _ = 1, 3000 do
            player:Step(DT, {throttle = 1, steer = 0})
            tick(racing, opponent)
        end
        check(player.z > opponent.s + 10, id .. "正常油门必须可追回20米起步差距")
        check(player.z > 1200 and opponent.s > 1000, "追赶不能靠AI停驶伪造")
    end
    passed("普通油门的独立实际追赶")

    local fuelRace, fuelRider = fixture(37)
    fuelRider.mistakeTimer, fuelRider.nitroCooldown, fuelRider.speed = 1000, 1000, 40
    check(fuelRace:Boost(fuelRider), "AI喷射必须经资源授权")
    local activeSteps = 0
    for _ = 1, 125 do
        if fuelRider.boostTimer > 0 then activeSteps = activeSteps + 1 end
        tick(fuelRace, fuelRider)
    end
    check(activeSteps == 125 and fuelRider.boostTimer == 0 and fuelRider.nitro == 55,
        "AI喷射125步内不能额外续时或免费回氮")
    tick(fuelRace, fuelRider)
    check(math.abs(fuelRider.nitro - 55.1) < 1e-8, "喷射结束后才按同玩家5每秒再生")
    passed("喷射资源时长与恢复")

    local race, r = fixture(17)
    r.speed, r.mistakeTimer, r.nitroCooldown = 52, 1000, 1000
    r.driveSim.gear, r.driveSim.rpm = 5, 10000
    race.aiProfile[25] = {curvature = 0.07, turn = 0.07, slope = 0}
    local target = AI.CurveSpeed(race, r)
    check(target < r.speed and target > 8, "入弯前120米必须提前收油制动")
    tick(race, r)
    check(r.speed < 52 and r.speed > 52 - race.sim.vehicle.braking * DT,
        "提前减速必须有限加速度，不能直接锁弯速")
    local pace = r.paceTarget
    race.aiProfile[25] = {curvature = 0, turn = 0, slope = 0}
    AI.Plan(race, r, DT)
    check(r.paceTarget == pace, "弯后重接油必须等待下一次反应节奏")
    passed("提前制动与反应节奏")

    local gated, eager = fixture(39, "sport", 1, "hard")
    eager.speed, eager.mistakeTimer = 45, 1000
    local originalRandom = gated.Random
    gated.Random = function() return 0 end
    AI.Plan(gated, eager, DT)
    check(eager.boostTimer > 0 and eager.nitro == 55 and eager.nitroCooldown >= 9,
        "满足直道条件的AI仍能正常喷射而不是完全禁用")
    local bendRace, cautious = fixture(39, "sport", 1, "hard")
    bendRace.Random = function() return 0 end
    cautious.speed, cautious.mistakeTimer = 45, 1000
    bendRace.aiProfile[45] = {curvature = 0.02, turn = 0.02, slope = 0}
    AI.Plan(bendRace, cautious, DT)
    check(cautious.boostTimer == 0 and cautious.nitro == 100,
        "喷射结束前就会入弯时不能只因眼前平直而开氮")
    gated.Random, bendRace.Random = originalRandom, originalRandom
    passed("长直道喷射授权与入弯禁喷")

    local baseline, clean = fixture(73)
    local flawed, errorRider = fixture(73)
    for _, pair in ipairs({{baseline, clean}, {flawed, errorRider}}) do
        local rr, rider = pair[1], pair[2]
        rider.speed, rider.mistakeTimer, rider.nitroCooldown = 45, 1000, 1000
        rider.driveSim.gear, rider.driveSim.rpm = 5, 8500
        rr:Place(rider)
    end
    errorRider.mistakeTimer = 0
    local largestLane = 0
    local recoverySeen = false
    for _ = 1, 200 do
        local oldS, oldLane = errorRider.s, errorRider.lane
        tick(baseline, clean); tick(flawed, errorRider)
        largestLane = math.max(largestLane, math.abs(errorRider.lane))
        recoverySeen = recoverySeen or errorRider.recoveryTimer > 0
        check(errorRider.s >= oldS and errorRider.s - oldS <= errorRider.speed * DT + 1e-6,
            "失误恢复不许回退或前向瞬移")
        check(math.abs(errorRider.lane - oldLane) <= (2.5 + errorRider.skill) * DT + 1e-6,
            "走宽与回线必须受横向速率限制")
    end
    local loss = clean.s - errorRider.s
    check(errorRider.mistakes == 1 and largestLane > 1 and recoverySeen,
        "失误必须真实走宽并进入恢复阶段，不只是计数")
    check(loss > 10 and errorRider.speed < clean.speed - 1,
        "单次失误至少产生10米可超越窗口，结束后不立即补回")
    result.mistakeDistanceLoss = loss
    passed("走宽断油与恢复的可超越窗口")

    local replayA, a = fixture(4817)
    local replayB, b = fixture(4817)
    replayA.player, replayB.player = {speed = 0, rank = 9, s = -500}, {speed = 120, rank = 1, s = 500}
    for frame = 1, 1800 do
        tick(replayA, a); tick(replayB, b)
        check(a.s == b.s and a.speed == b.speed and a.lane == b.lane and a.nitro == b.nitro
            and a.boostTimer == b.boostTimer and a.mistakes == b.mistakes,
            "同种子重放必须一致，玩家快慢与名次不得影响AI")
        if frame == 100 then
            check(a.speed > 0 and a.distanceDriven > 0, "AI必须实际驾驶前进")
        end
    end
    check(a.mistakes >= 1 and a.rubberBand == 0, "正常运行必须出现自身节奏失误且没有橡皮筋")
    passed("确定性重放与无玩家追赶作弊")
    local radius = 100
    local lapMap = flatMap()
    lapMap.RouteLength = radius * math.pi * 2
    lapMap.RoadPoint = function(s)
        local t = s / radius
        return {x = radius * (1 - math.cos(t)), y = 0, z = radius * math.sin(t)}, t * 180 / math.pi
    end
    local lapsRace = Race.New(lapMap, Sim.New(lapMap), {laps = 5, quiet = true})
    check(lapsRace.laps == 5, "赛道配置5圈不能被构造器静默截成3圈")
    lapsRace:Start(9)
    check(lapsRace.laps == 9, "开始比赛与配置必须统一支持9圈上限")
    lapsRace:Start(99)
    check(lapsRace.laps == 9, "过大圈数仍须限制在统一上限")
    passed("赛道圈数配置一致")
    result.passed = true
    print(string.format("[RaceAIChecks] %d项断言通过，单次失误损失%.2f米", result.assertions, loss))
    return result
end
return Checks
