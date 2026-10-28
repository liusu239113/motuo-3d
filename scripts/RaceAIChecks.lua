-- 纯 Lua 确定性回归：require("RaceAIChecks").Run()，不操作实际 HUD 或活动比赛。
local AI = require("RaceAI")
local Race = require("Race")
local Sim = require("Simulation")
local Tracks = require("Tracks")
local Catalog = require("Catalog")
local Checks = {}
local DT = 0.02
local function flatMap()
    return {RouteLength = 10000, Goals = {}, Roads = {{width = 4.8, shoulder = 6}},
        RoadPoint = function(s) return {x = 0, y = 0, z = s}, 0 end,
        Height = function() return 0, true end,
        NearestRoad = function(x, z) return z, x end}
end

-- 用可控直线剖面隔离驾驶逻辑，仍调用真实配置、规划、动力、资源与喷射授权。
local function fixture(seed, vehicleId, level, difficulty, riderIndex)
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
    AI.Configure(race, r, riderIndex or 1)
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

-- 使用Tracks的实际2.4m样本；插值/法线/三角形高程与Landscape.TrafficPose一致。
-- 不require Landscape（它需要引擎对象），不读Profile或任何玩家存档。
local function trackMap(track)
    local samples, length = track.samples, track.length
    local function edge(p, lane)
        return {x = p.x + p.rx * lane, y = p.y, z = p.z + p.rz * lane}
    end
    local function triangle(x, z, a, b, c)
        local den = (b.z-c.z)*(a.x-c.x)+(c.x-b.x)*(a.z-c.z)
        if math.abs(den) < 1e-10 then return nil end
        local u = ((b.z-c.z)*(x-c.x)+(c.x-b.x)*(z-c.z))/den
        local v = ((c.z-a.z)*(x-c.x)+(a.x-c.x)*(z-c.z))/den
        if u >= -1e-6 and v >= -1e-6 and u+v <= 1.000001 then return a.y*u+b.y*v+c.y*(1-u-v) end
        return nil
    end
    local function pose(s, lane)
        local wrapped = s % length
        local index = math.min(#samples-1, math.floor(wrapped/length*(#samples-1))+1)
        local a,b = samples[index],samples[index+1]
        local t = (wrapped-a.s)/(b.s-a.s)
        local x = a.x+(b.x-a.x)*t+(a.rx+(b.rx-a.rx)*t)*lane
        local z = a.z+(b.z-a.z)*t+(a.rz+(b.rz-a.rz)*t)*lane
        local p,q,r,u = edge(a,-track.width*.5),edge(b,-track.width*.5),
            edge(a,track.width*.5),edge(b,track.width*.5)
        local y = triangle(x,z,p,q,r) or triangle(x,z,r,q,u) or (a.y+(b.y-a.y)*t)
        return {x=x,y=y,z=z}, math.deg(math.atan(b.x-a.x,b.z-a.z)),
            -math.deg(math.atan((b.y-a.y)/math.max(.001,b.s-a.s)))
    end
    return {RouteLength=length,Goals={},Roads={{width=track.width*.5,shoulder=track.shoulder}},
        RoadPoint=function(s) return pose(s,0) end, TrafficPose=pose,
        -- Sim初始化只在起点查询；AI的正式位置始终通过TrafficPose精确取路带。
        Height=function() return samples[1].y,true end, NearestRoad=function() return 0,0 end}
end

local function trackFixture(track, vehicleId, seed, index, difficulty)
    local map = trackMap(track)
    local sim = Sim.New(map)
    assert(sim:SetVehicle(vehicleId))
    local race = Race.New(map, sim, {seed=seed,aiLevel=track.aiLevel,laps=9,
        difficulty=difficulty or "normal",quiet=true})
    race:Start()
    local r = race.racers[index or 1]
    assert(not r.isPlayer)
    -- 单车计时剖面隔离交通/追捕，只移除其它参赛者，不替换真实门线/动力/资源。
    race.racers,race.runners,race.phase = {r},{r},"racing"
    return race,r
end

-- 默认180秒×六图×三基础档×1/4/8号AI；full=true时覆盖全部九车型。
-- 每步双实例重放（玩家表现刻意相反），不能用“同种子首帧”冒充确定性。
function Checks.RealTracks(seconds, full, riderIndices)
    local duration = seconds or 180
    local rows = {}
    local indices = riderIndices or {1,4,8}
    local vehicles = full and Catalog.AvailableIds() or {"sport","cruiser","rally"}
    for _, trackId in ipairs({"circuit","lake","coast","alpine","forest","canyon"}) do
        local track = assert(Tracks.Get(trackId))
        -- 所有车型/重放实例共享不可变真实地图与Race空间索引，避免重复上万点初始化。
        local map=trackMap(track)
        local template=Race.New(map,Sim.New(map),{quiet=true,laps=9})
        local function create(vehicleId,index)
            local sim=Sim.New(map)
            assert(sim:SetVehicle(vehicleId))
            local race={}
            for key,value in pairs(template) do race[key]=value end
            setmetatable(race,{__index=Race})
            race.sim,race.options=sim,{seed=4817,aiLevel=track.aiLevel,quiet=true}
            race.pursuit={}
            race.events,race.eventSeq={},0
            race:Start()
            local r=race.racers[index<=4 and index or index+1]
            race.racers,race.runners,race.phase={r},{r},"racing"
            return race,r
        end
        for _, vehicleId in ipairs(vehicles) do
          for _, riderIndex in ipairs(indices) do
            local race,r = create(vehicleId,riderIndex)
            local replay,b = create(vehicleId,riderIndex)
            race.player.speed,race.player.rank,race.player.s = 0,9,-500
            replay.player.speed,replay.player.rank,replay.player.s = 120,1,500
            local boosts, active, powered, sumSpeed, shifts = 0,0,0,0,0
            local straightStarts, gentleStarts, lastBoost, lastMistake = 0,0,-100,0
            local minCurvature,maxCurvature = math.huge,0
            for _, p in ipairs(race.aiProfile) do
                minCurvature,maxCurvature = math.min(minCurvature,p.curvature),math.max(maxCurvature,p.curvature)
            end
            for _ = 1, math.floor(duration/DT+.5) do
                local oldNitro,oldTimer,oldS,gear = r.nitro,r.boostTimer,r.s,r.driveSim.gear
                tick(race,r); tick(replay,b)
                assert(r.s==b.s and r.speed==b.speed and r.lane==b.lane and r.nitro==b.nitro
                    and r.boostTimer==b.boostTimer and r.mistakes==b.mistakes and race.rng==replay.rng,
                    "真实图逐步重放/玩家表现独立性失败")
                assert(not r.finished and not r.eliminated and r.s>=oldS and r.rubberBand==0,
                    "长时域测试不得冻结、回收或橡皮筋")
                assert(r.speed<=race.sim.vehicle.maxSpeed*1.25+1e-8,"同车125%绝对上界")
                assert(r.nitro>=0 and r.nitro<=100,"氮资源界限")
                sumSpeed = sumSpeed+r.speed
                if r.driveSim.gear~=gear then shifts=shifts+1 end
                if r.boostTimer>0 then active=active+DT end
                if r.driveSim.raceBoost>0 then
                    powered=powered+DT
                    local sample=race.aiProfile[math.floor((oldS%race.length)/race.aiProfileStep)+1]
                    assert(sample.curvature<=.012 and r.mistakeDuration<=0 and r.recoveryTimer<=0,
                        "急弯/失误/恢复不许保留实际喷射动力")
                end
                if r.nitro<oldNitro-1 then
                    boosts=boosts+1
                    assert(oldTimer==0 and math.abs(r.nitro-(math.min(100,oldNitro+5*DT)-45))<1e-7,
                        "真实图发动必须扣45而不是测试伪造喷射")
                    assert(math.abs(r.boostTimer-(2.5-DT))<1e-8 and race.elapsed-lastBoost>=16,
                        "真实图喷射不得续时或无冷却连发")
                    local p = race.aiProfile[math.floor((oldS%race.length)/race.aiProfileStep)+1]
                    assert(p.curvature<=.012 and r.mistakeDuration<=0 and r.recoveryTimer<=0,
                        "急弯/失误/恢复时禁喷")
                    if p.curvature<.001 then straightStarts=straightStarts+1 else gentleStarts=gentleStarts+1 end
                    assert(race.events[#race.events].kind=="boost" and race.events[#race.events].racerId==r.id,
                        "每次真实喷射必须发出带AI身份的boost事件")
                    lastBoost=race.elapsed
                elseif oldTimer>0 then
                    assert(r.nitro==oldNitro and math.abs(r.boostTimer-math.max(0,oldTimer-DT))<1e-7,
                        "活动脉冲不得额外再生或延长")
                end
                if r.mistakes>lastMistake then
                    assert(r.driveSim.raceBoost==0,"失误必须中断喷射动力而不是补油")
                    lastMistake=r.mistakes
                end
            end
            local row = {track=trackId,vehicle=vehicleId,rider=riderIndex,seconds=duration,boosts=boosts,
                averageKmh=sumSpeed/(duration/DT)*3.6,mistakes=r.mistakes,shifts=shifts,
                activeSeconds=active,poweredSeconds=powered,straightStarts=straightStarts,gentleStarts=gentleStarts,
                laps=r.s/race.length,minCurvature=minCurvature,maxCurvature=maxCurvature}
            rows[#rows+1]=row
            print(string.format("[RealTracks] %s %-10s AI%d %ds boosts=%d straight=%d gentle=%d avg=%.2fkm/h mistakes=%d shifts=%d powered=%.2fs laps=%.2f curvature=%.6f..%.6f",
                trackId,vehicleId,riderIndex,duration,boosts,straightStarts,gentleStarts,row.averageKmh,r.mistakes,shifts,powered,row.laps,minCurvature,maxCurvature))
            assert(boosts>=2 and powered>2.5 and r.mistakes>=2 and shifts>=2,
                trackId.."/"..vehicleId.."/AI"..riderIndex.."真实图必须自然喷射、换挡并保留失误")
          end
        end
    end
    return rows
end

-- 注入表现依赖的只读spy：调用真正的Update，不创建Scene/渲染/音频设备。
-- 引擎内可直接Feedback()；纯Lua调用方可用隔离环境加载原模块后传入。
-- 不篡改package.loaded/引擎全局，不宣称已完成截图/实机听感验收。
function Checks.Feedback(visuals, audioModule)
    local Visuals=visuals or require("RaceVisuals")
    local Audio=audioModule or require("RaceAudio")
    local race,r=fixture(31)
    r.speed=35
    assert(race:Boost(r))
    local lastBoost,lastSpeed=-1,-1
    local runner={node={SetEnabledRecursive=function() end},visual={},active=true,
        lean=0,poseClock=0,colorId="red",rider={model={inView=false}},
        effects={pitch=0,bob=0,Update=function(_,dt,boost,speed) lastBoost,lastSpeed=boost,speed end,
            Reset=function() end}}
    local visual=setmetatable({disposed=false,visible=true,clock=0,visibilityClock=0,leanSign=1,
        race={racers={r}},runners={[r.id]=runner},EnsurePolice=function() end,RefreshPose=function() end},{__index=Visuals})
    visual:Update(.02,{x=0,z=0})
    assert(lastBoost==1 and lastSpeed==r.speed,"AI boostTimer必须传到真正的effects:Update")
    r.boostTimer=0
    visual:Update(.02,{x=0,z=0})
    assert(lastBoost==0,"喷射计时结束必须撤销视觉授权")
    local played=0
    local audio=setmetatable({stopped=false,currentRace=race,lastSeq=0,curseTimer=0,
        unlocked=true,effectsEnabled=true,sources={},sounds={},PlayOnce=function() played=played+1 end},{__index=Audio})
    audio:Update(.02,{},race,true)
    assert(audio.lastSeq==race.eventSeq and played==0,"现有音频只播放玩家boost，AI事件静音")
    race:Emit("boost","player")
    audio:Update(.02,{},race,true)
    assert(played==1,"玩家喷射音效链路仍保留")
    print("[RaceAIChecks] PASS AI boostTimer -> RaceVisuals.Update -> effects；音频仅玩家(已报告)")
    return true
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
    local gearBefore,rpmBefore = eager.driveSim.gear,eager.driveSim.rpm
    check(AI.NitroSafe(gated,eager) and eager.driveSim.gear==gearBefore and eager.driveSim.rpm==rpmBefore,
        "安全预演不得修改真实挡位或RPM")
    AI.Plan(gated, eager, DT)
    check(eager.boostTimer > 0 and eager.nitro == 55 and eager.nitroCooldown >= 9,
        "满足直道条件的AI仍能正常喷射而不是完全禁用")
    local bendRace, cautious = fixture(39, "sport", 1, "hard")
    cautious.speed, cautious.mistakeTimer = 45, 1000
    bendRace.aiProfile[18] = {curvature = 0.04, turn = 0.04, slope = 0}
    AI.Plan(bendRace, cautious, DT)
    check(cautious.boostTimer == 0 and cautious.nitro == 100,
        "喷射结束前就会入弯时不能只因眼前平直而开氮")
    for _, level in ipairs({.42,.60,.77,.92}) do
        local low,rider = fixture(31,"cruiser",level)
        rider.speed,rider.nitro,rider.mistakeTimer = 12,45,1000
        AI.Plan(low,rider,DT)
        check(rider.boostTimer==2.5 and rider.nitro==0,"每层级低速出弯45点即可发动，不要求23m/s或85%极速")
    end
    for _, kind in ipairs({"sharp","braking","traffic","oncoming","merge","shoulder","mistake","recovery","hit","empty","cooldown"}) do
        local dangerous,rider = fixture(33,"sport",.92)
        rider.speed,rider.mistakeTimer = 35,1000
        if kind=="sharp" then dangerous.aiProfile[1].curvature=.04
        elseif kind=="braking" then rider.speed=85; dangerous.aiProfile[16].curvature=.07
        elseif kind=="traffic" or kind=="oncoming" then
            dangerous.aiObstacles={{s=65,lane=0,speed=kind=="traffic" and 15 or -20,
                halfWidth=1,halfLength=2.2,y=0,bike=false}}
        elseif kind=="merge" then rider.wantedLane=3; rider.decisionTimer=1
        elseif kind=="shoulder" then rider.lane=dangerous.roadHalfWidth+.1
        elseif kind=="mistake" then rider.mistakeDuration=1; rider.mistakeSpeed=20
        elseif kind=="recovery" then rider.recoveryTimer=1
        elseif kind=="hit" then rider.hitTimer=1
        elseif kind=="empty" then rider.nitro=44.99
        elseif kind=="cooldown" then rider.nitroCooldown=1 end
        AI.Plan(dangerous,rider,DT)
        check(rider.boostTimer==0,"危险状态禁喷: "..kind)
    end
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

    local circuit,lake,coast,alpine,forest,canyon = assert(Tracks.Get("circuit")),assert(Tracks.Get("lake")),
        assert(Tracks.Get("coast")),assert(Tracks.Get("alpine")),assert(Tracks.Get("forest")),assert(Tracks.Get("canyon"))
    check(circuit.aiLevel<lake.aiLevel and lake.aiLevel<coast.aiLevel and coast.aiLevel<forest.aiLevel
        and coast.aiLevel==alpine.aiLevel and forest.aiLevel==canyon.aiLevel,"解锁层级递进且同层分支公平")
    for _, id in ipairs(Catalog.AvailableIds()) do
      for index=1,8 do
       for _, difficulty in ipairs({"easy","normal","hard"}) do
        local oldSpeed,oldAcceleration,oldReaction,oldGrace = 0,0,10,0
        for _, level in ipairs({circuit.aiLevel,lake.aiLevel,coast.aiLevel,forest.aiLevel,999}) do
            local rr,rider = fixture(31,id,level,difficulty,index)
            check(rider.speedFactor>=oldSpeed and rider.acceleration>=oldAcceleration
                and rider.reactionTime<=oldReaction and rider.mistakeGrace>=oldGrace,"同车型同车手等级参数必须单调")
            check(rider.speedFactor<=.96 and rider.acceleration<=rr.sim.vehicle.acceleration*.97+1e-9
                and rider.skill<=.95 and rider.reactionTime>=.25 and rider.mistakeGrace<=13.6,
                "恶意超大等级也受硬上界，失误有有限间隔")
            oldSpeed,oldAcceleration,oldReaction,oldGrace = rider.speedFactor,rider.acceleration,rider.reactionTime,rider.mistakeGrace
        end
       end
      end
    end
    -- 在同一真实赛道的每个剖面点比较等级，避免把不同地图的平均速度当难度证据。
    for _, track in ipairs(Tracks.List()) do
        local rr,rider = trackFixture(track,"sport",31,1)
        rider.speed=40
        for i=1,#rr.aiProfile,11 do
            rider.s=(i-1)*rr.aiProfileStep
            local previous=0
            for _, level in ipairs({.42,.60,.77,.92}) do
                local setting={options={aiLevel=level},sim=rr.sim,map=rr.map,Random=function() return .5 end}
                local candidate={isPlayer=true,lane=0,boostTimer=0,speed=40,s=rider.s}
                AI.Configure(setting,candidate,1)
                local speed=AI.CurveSpeed(rr,candidate)
                check(speed>=previous-1e-9,"真实图同剖面弯速/预判必须随等级非递减")
                previous=speed
            end
        end
    end
    passed("六图解锁层级、分支公平与全车型全车手三难度硬上界")
    result.realTracks = Checks.RealTracks(100,false,{1})
    passed("六图三车型100秒真实地图确定性长时域")
    result.passed = true
    print(string.format("[RaceAIChecks] %d项断言通过，单次失误损失%.2f米", result.assertions, loss))
    return result
end
return Checks
