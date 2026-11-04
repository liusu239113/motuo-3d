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
        gateSpacing = 85, roadHalfWidth = 4.8, corridor = 5.6, gateCorridor = 5.6, aiProfileStep = 5, aiProfile = {},
        aiObstacles = {}, racers = {}, traffic = {}, phase = "racing", elapsed = 0,
        rng = seed or 31, events = {}, eventSeq = 0}
    setmetatable(race, {__index = Race})
    for i = 1, 2000 do race.aiProfile[i] = {curvature = 0, turn = 0, slope = 0} end
    local r = {id = "ai1", isPlayer = false, finished = false, eliminated = false,
        x = 0, y = 0, z = 0, yaw = 0, s = 0, speed = 0, lane = 0, wantedLane = 0,
        boostTimer = 0, nitro = 100, slipstream = 0, immunity = 0,
        decisionTimer = 0, mistakes = 0, progress = 0, safeS = 0, invalidMoves = 0, nextGate = 85,
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
    local grid={}
    for i=1,#samples-1 do
        local a,b=samples[i],samples[i+1]
        for gx=math.floor((math.min(a.x,b.x)-35)/40),math.floor((math.max(a.x,b.x)+35)/40) do
          for gz=math.floor((math.min(a.z,b.z)-35)/40),math.floor((math.max(a.z,b.z)+35)/40) do
            local key=gx..":"..gz;grid[key]=grid[key] or {};grid[key][#grid[key]+1]=i
          end
        end
    end
    local function nearest(x,z)
        local list=grid[math.floor(x/40)..":"..math.floor(z/40)]
        local best,s,lateral,y=math.huge,0,0,samples[1].y
        local function test(i)
            local a,b=samples[i],samples[i+1]
            local dx,dz=b.x-a.x,b.z-a.z
            local t=math.max(0,math.min(1,((x-a.x)*dx+(z-a.z)*dz)/(dx*dx+dz*dz)))
            local ox,oz=x-a.x-dx*t,z-a.z-dz*t
            local dist=ox*ox+oz*oz
            if dist<best then
                best,s,lateral,y=dist,a.s+(b.s-a.s)*t,(ox*dz-oz*dx)/math.sqrt(dx*dx+dz*dz),a.y+(b.y-a.y)*t
            end
        end
        if list then for _,i in ipairs(list) do test(i) end else for i=1,#samples-1 do test(i) end end
        return s%length,lateral,y
    end
    return {RouteLength=length,Goals={},Roads={{width=track.width*.5,shoulder=track.shoulder}},
        RoadPoint=function(s) return pose(s,0) end, TrafficPose=pose,
        Height=function(x,z) local _,lane,y=nearest(x,z);return y,math.abs(lane)<=track.width*.5 end,
        NearestRoad=nearest}
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

-- 同场交通基准：真实Tracks路带、World的14辆交通初值/移动/回收规则，
-- physicalPlayer=true走真正Sim.Step，只提交0.8油门/刹车/方向及正常氮气；
-- false为明确标识的道路空间隔离对照。两者均有定时收油失误，不作为真人胜率保证。
-- 同场真实交通基准不运行警车淘汰，避免在100秒控制器测试中提前终止采样。
function Checks.TrafficRace(seconds,vehicleIds,seeds,physicalPlayer,trackIds)
    local rows={}
    local duration=seconds or 100
    for _,trackId in ipairs(trackIds or {"circuit","lake","coast","alpine","forest","canyon"}) do
      local track=assert(Tracks.Get(trackId))
      local map=trackMap(track)
      for _,id in ipairs(vehicleIds or {"sport"}) do
       for _,seed in ipairs(seeds or {31,4817,9011}) do
        local sim=Sim.New(map); assert(sim:SetVehicle(id))
        local race=Race.New(map,sim,{quiet=true,seed=seed,aiLevel=track.aiLevel,laps=9})
        race:Start(); race.phase="racing"
        local player=race.player
        local rng=seed
        local function random() rng=(rng*48271)%2147483647;return rng/2147483647 end
        local function placeCar(car,teleport)
            local p,yaw=map.TrafficPose(car.s,car.lane)
            car.x,car.y,car.z,car.yaw=p.x,p.y,p.z,yaw+(car.speed<0 and 180 or 0)
            if teleport then car.previousX,car.previousY,car.previousZ=p.x,p.y,p.z end
        end
        local sizes={{2.205,1.575,4.6},{2.456,1.793,4.7},{2.758,2.695,5.4}}
        if track.traffic then for i=1,14 do
            local size=sizes[(i-1)%3+1]
            local lane=i%3==0 and -2.4 or 2.4
            local car={s=90+i*94,lane=lane,speed=(lane<0 and -1 or 1)*(12+i*7%11),
                width=size[1],height=size[2],halfLength=size[3]*.5,passed=false}
            placeCar(car,true);race.traffic[#race.traffic+1]=car
        end end
        local world={traffic=race.traffic}
        local decision,mistake,nextMistake,nitroClock=0,0,11+random()*7,0
        local goalLane,goalSpeed=1.55,0
        local hits,boosts,passes,loses,mean,playerMistakes=0,0,0,0,0,0
        local side={}
        local peakGap,recoverySteps=0,0
        for frame=1,math.floor(duration/DT+.5) do
            race.elapsed=frame*DT
            for _,r in ipairs(race.racers) do
                r.contactX,r.contactY,r.contactZ=r.x,r.y,r.z
                race:Resources(r,DT)
            end
            for i,car in ipairs(race.traffic) do
                car.previousX,car.previousY,car.previousZ=car.x,car.y,car.z
                car.s=car.s+car.speed*DT
                local relative=(car.s-player.s+race.length*.5)%race.length-race.length*.5
                local teleport=relative< -145 or relative>1500
                if teleport then car.s=player.s+260+(i%6)*125;car.passed=false end
                placeCar(car,teleport)
            end
            AI.Snapshot(race)
            decision,mistake,nextMistake,nitroClock=decision-DT,math.max(0,mistake-DT),nextMistake-DT,nitroClock-DT
            if nextMistake<=0 then
                mistake=1.4+random()*.6; nextMistake=14+random()*9;playerMistakes=playerMistakes+1
            end
            if decision<=0 then
                decision=.45
                -- 正常玩家留弯道余量，不用AI技术/难度倍率；预瞄仅当前速度1.2秒。
                goalSpeed=sim.vehicle.maxSpeed*.88
                for j=0,math.ceil(math.max(60,player.speed*1.2)/race.aiProfileStep) do
                    local sample=race.aiProfile[(math.floor((player.s%race.length)/race.aiProfileStep)+j)%#race.aiProfile+1]
                    local safe=math.sqrt(15/math.max(.0001,sample.curvature)+2*10*math.max(0,j*race.aiProfileStep-player.speed*.45))
                    goalSpeed=math.min(goalSpeed,safe)
                end
                local best,bestScore=goalLane,math.huge
                for _,lane in ipairs({2.4,0,-2.4,race.roadHalfWidth-1,-race.roadHalfWidth+1}) do
                    local score=math.abs(lane-2.4)*.30+math.abs(lane-player.lane)*.5
                    for _,o in ipairs(race.aiObstacles) do
                        local d=(o.s-player.s+race.length*.5)%race.length-race.length*.5
                        if d> -4 and d<65 and math.abs(lane-o.lane)<o.halfWidth+.8 then score=score+100 end
                    end
                    if score<bestScore then best,bestScore=lane,score end
                end
                goalLane=best
                if mistake>0 then goalLane=math.max(-race.roadHalfWidth+.7,math.min(race.roadHalfWidth-.7,goalLane+.9)) end
            end
            local target=goalSpeed*(mistake>0 and .70 or 1)
            for _,o in ipairs(race.aiObstacles) do
                local d=(o.s-player.s+race.length*.5)%race.length-race.length*.5
                if d>0 and d<35 and math.abs(player.lane-o.lane)<o.halfWidth+.5 then
                    target=math.min(target,math.max(0,o.speed)+(math.max(0,d-o.halfLength-3))/.9)
                end
            end
            if nitroClock<=0 and mistake==0 and player.speed>12 and goalSpeed>player.speed+4 then
                local clear=true
                for _,o in ipairs(race.aiObstacles) do
                    local d=(o.s-player.s+race.length*.5)%race.length-race.length*.5
                    if d>0 and d<160 and math.abs(player.lane-o.lane)<o.halfWidth+1 then clear=false end
                end
                if clear and race:Boost(player) then boosts=boosts+1;nitroClock=19 end
            end
            if physicalPlayer then
                -- 真正玩家基线：只给油刹舵，绝不写s/lane/speed/位置。
                local look=math.max(10,sim.speed*.65)
                local aim=map.TrafficPose(player.s+look,goalLane)
                local desired=math.deg(math.atan(aim.x-sim.x,aim.z-sim.z))
                local error=(desired-sim.heading+180)%360-180
                local needed=math.max(-100,math.min(100,error*2.5))
                local lo,hi=0,1
                for _=1,12 do
                    local mid=(lo+hi)*.5
                    if math.abs(sim:TurnRate(mid))<math.abs(needed) then lo=mid else hi=mid end
                end
                local steer=(lo+hi)*.5*(needed<0 and -1 or 1)
                local before=sim.impactSerial
                sim:Step(DT,{throttle=mistake>0 and .10 or .80,
                    brake=sim.speed>target+1,steer=steer,boost=player.boostTimer>0 and 1 or 0},world)
                if sim.impactSerial>before then hits=hits+1;mistake=math.max(mistake,1.5) end
                race:TrackPlayer(DT)
            else
            local oldS,oldLane=player.s,player.lane
            player.lastX,player.lastY,player.lastZ=player.x,player.y,player.z
            local throttle=player.speed>target+.2 and 0 or (mistake>0 and .55 or .92)
            sim.speed=player.speed
            local active=player.boostTimer>0 and throttle>.8
            local power=sim:Powertrain(DT,{throttle=throttle,boost=active and 1 or 0})
            local sample=race.aiProfile[math.floor((player.s%race.length)/race.aiProfileStep)+1]
            local acc=power-.20-player.speed^2*.00115-9.81*sample.slope/math.sqrt(1+sample.slope^2)
            if player.speed>target+.2 then acc=math.min(acc,-math.min(sim.vehicle.braking,(player.speed-target)*2+1)) end
            player.speed=math.max(0,math.min(math.max(player.speed,sim.vehicle.maxSpeed*(active and 1.25 or 1)),player.speed+acc*DT))
            player.lane=oldLane+math.max(-2.9*DT,math.min(2.9*DT,goalLane-oldLane))
            local lateral=(player.lane-oldLane)/DT
            player.s=oldS+math.sqrt(math.max(0,player.speed^2-lateral^2))*DT/math.sqrt(1+sample.slope^2)
                /math.max(.45,math.abs(1-sample.turn*(player.lane+oldLane)*.5))
            race:Place(player)
            sim.x,sim.y,sim.z,sim.yaw,sim.heading,sim.speed=player.x,player.y,player.z,player.yaw,player.yaw,player.speed
            local oldImpact=sim.impactSerial
            sim.crashCooldown=math.max(0,sim.crashCooldown-DT)
            sim:Traffic(world,player.lastX,player.lastY,player.lastZ,0,1)
            if sim.impactSerial>oldImpact then hits=hits+1;mistake=math.max(mistake,1.5) end
            player.speed=sim.speed
            race:AdvanceGates(player,oldS,player.s,DT)
            if not player.finished then player.progress=math.min(player.s,player.nextGate-.001) end
            end
            for _,r in ipairs(race.racers) do if not r.isPlayer then AI.Update(race,r,DT) end end
            race:Contacts(DT);race:Rank()
            for _,r in ipairs(race.racers) do
                if not r.isPlayer then
                    local ahead=player.progress>r.progress
                    if side[r.id]~=nil and side[r.id]~=ahead then
                        if ahead then passes=passes+1 else loses=loses+1 end
                    end
                    side[r.id]=ahead
                    if r.perception.recovery>0 then recoverySteps=recoverySteps+1 end
                end
                r.boostTimer=math.max(0,r.boostTimer-DT)
                if r.boostTimer<1e-8 then r.boostTimer=0 end
            end
            mean=mean+player.speed
            peakGap=math.max(peakGap,player.progress-race.ranking[5].progress)
        end
        local aiHits,aiRecoveries,misses=0,0,0
        local speeds={}
        for _,r in ipairs(race.racers) do if not r.isPlayer then
            aiHits=aiHits+r.trafficHits;aiRecoveries=aiRecoveries+r.perception.recoveries;misses=misses+r.perception.misses
            speeds[#speeds+1]={id=r.id,progress=r.progress,mistakes=r.mistakes,hits=r.trafficHits}
        end end
        local row={track=trackId,vehicle=id,seed=seed,rank=player.rank,passes=passes,repasses=loses,
            playerHits=hits,aiHits=aiHits,recoveries=aiRecoveries,recoverySeconds=recoverySteps*DT,
            misses=misses,boosts=boosts,averageKmh=mean/(duration/DT)*3.6,playerMistakes=playerMistakes,opponents=speeds}
        rows[#rows+1]=row
        print(string.format("[TrafficRace] %s %s seed%d rank%d passes%d lost%d playerHit%d aiHit%d recovery%d/%.1fs misses%d playerMistakes%d avg%.2f mode=%s",
            trackId,id,seed,player.rank,passes,loses,hits,aiHits,aiRecoveries,recoverySteps*DT,misses,playerMistakes,row.averageKmh,physicalPlayer and "Sim.Step" or "route"))
        assert(aiRecoveries==aiHits,"每次真实交通碰撞必须进入恢复")
        assert(player.rank<9 and passes>0,trackId.."同车正常失误玩家应能超过部分AI")
       end
      end
    end
    return rows
end

function Checks.RampAvoidance()
    local cases=0
    for _,track in ipairs(Tracks.List()) do
      for _,side in ipairs({-1,1}) do
       for _,withLanding in ipairs({false,true}) do
        local race,r=trackFixture(track,"sport",31,1)
        local p=race.map.RoadPoint(110)
        local ramp={optional=true,s=110,lateral=side*2.4,length=24,width=2.6,height=.85,
            landingEndS=withLanding and 284 or nil,x=p.x,y=p.y,z=p.z,yaw=0}
        local endS=ramp.landingEndS or ramp.s+ramp.length
        race.map.Ramps={ramp}
        r.lane,r.wantedLane,r.preferredLane=ramp.lateral,ramp.lateral,ramp.lateral
        r.mistakeTimer=1000
        race:Place(r)
        local reached=false
        for _=1,2000 do
            local oldS=r.s
            tick(race,r)
            local overlaps=r.s+1>ramp.s and oldS-1<endS
            if overlaps then
                assert(math.abs(r.lane-ramp.lateral)>=ramp.width*.5+.30,
                    track.id.."AI不许穿坡或提前占回落地保留车道")
            end
            if r.s>endS+10 then reached=true;break end
        end
        assert(reached,track.id.."必须真实驶过坡旁，而非停住伪造避障")
        cases=cases+1
       end
      end
    end
    print("[RaceAIChecks] PASS 六图左右坡旁通过 "..cases.." cases，无穿坡/免费跳跃")
    return cases
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
    r.driveSim.raceBoost=1
    local lastBoost,lastSpeed=-1,-1
    local runner={node={SetEnabledRecursive=function() end},visual={},active=true,
        lean=0,poseClock=0,colorId="red",rider={model={inView=false}},
        effects={pitch=0,bob=0,Update=function(_,dt,boost,speed) lastBoost,lastSpeed=boost,speed end,
            Reset=function() end}}
    local visual=setmetatable({disposed=false,visible=true,clock=0,visibilityClock=0,leanSign=1,
        race={racers={r}},runners={[r.id]=runner},EnsurePolice=function() end,RefreshPose=function() end},{__index=Visuals})
    visual:Update(.02,{x=0,z=0})
    assert(lastBoost==1 and lastSpeed==r.speed,"AI实际Powertrain喷射必须传到effects:Update")
    r.driveSim.raceBoost=0
    visual:Update(.02,{x=0,z=0})
    assert(lastBoost==0 and r.boostTimer>0,"仍有授权时间但实际收油时不能假喷焰")
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
    print("[RaceAIChecks] PASS AI实际推力 -> RaceVisuals.Update -> effects；音频仅玩家(已报告)")
    return true
end

-- 单独轻量入口，不触发Run里的多图长时域；fake音源，无实际试听。
function Checks.Audio(audioModule)
    return require("AudioChecks").Race(audioModule)
end

-- 普通技能专项只运行真实动力、弯道和预演，不触发多图长时域测试。
function Checks.MotorcycleSkills()
    local Skills=require("MotorcycleSkills")
    local Data=require("MixedVehicles")
    local count=0
    local function check(ok,message)
        assert(ok,"[摩托AI技能] "..message);count=count+1
    end
    local function pair()
        local race,r=fixture(31,"sport",1,"hard")
        local other,b=fixture(31,"sport",1,"hard")
        r.speed,b.speed=20,20
        return race,r,other,b
    end
    do
        local race,r,other,b=pair()
        r.driveSim.motorcycleDriveScale=1.25
        AI.Drive(race,r,1000,DT);AI.Drive(other,b,1000,DT)
        check(r.speed>b.speed and r.driveAcceleration>b.driveAcceleration,"动力倍率必须增加真实加速度")
        r.driveSim.motorcycleDriveScale=1
        r.speed,b.speed=20,20
        r.driveSim.rpm,r.driveSim.gear,r.driveSim.shiftTimer=b.driveSim.rpm,b.driveSim.gear,b.driveSim.shiftTimer
        r.driveSim.clutchEngagement=b.driveSim.clutchEngagement
        AI.Drive(race,r,1000,DT);AI.Drive(other,b,1000,DT)
        check(math.abs(r.speed-b.speed)<1e-8,"倍率复位后恢复相同动力")
    end
    do
        local race,r,other,b=pair()
        local base=AI.CurveSpeed(race,r)
        r.driveSim.motorcycleSpeedScale=1.10
        check(math.abs(AI.CurveSpeed(race,r)-base*1.10)<1e-8,"直道限速必须读取技能倍率")
        r.speed,b.speed=base+.5,base+.5
        AI.Drive(race,r,1000,DT);AI.Drive(other,b,1000,DT)
        check(r.speed>b.speed,"真实动力上限不能仍用技能前速度")
        race.aiProfile[1]={curvature=.06,turn=.06,slope=0}
        r.driveSim.motorcycleSpeedScale=1
        local corner=AI.CurveSpeed(race,r)
        r.driveSim.motorcycleGripScale=1.28
        check(AI.CurveSpeed(race,r)>corner,"抓地技能必须影响弯道制动包络")
    end
    do
        local race,r,other,b=pair()
        r.lane,b.lane=5.2,5.2
        r.driveSim.motorcycleOffroadScale=1.20
        AI.Drive(race,r,1000,DT);AI.Drive(other,b,1000,DT)
        check(r.speed>b.speed,"越野倍率必须影响路肩实际动力")
        r.driveSim.motorcycleOffroadScale=10
        r.speed,b.speed=20,20
        b.driveSim.motorcycleOffroadScale=1/b.driveSim.vehicle.offroad
        r.driveSim.rpm,r.driveSim.gear,r.driveSim.shiftTimer=b.driveSim.rpm,b.driveSim.gear,b.driveSim.shiftTimer
        r.driveSim.clutchEngagement=b.driveSim.clutchEngagement
        AI.Drive(race,r,1000,DT);AI.Drive(other,b,1000,DT)
        check(math.abs(r.speed-b.speed)<1e-8,"越野有效通过性不得超过100%")
    end
    do
        local race,r,other,b=pair()
        r.mistakeDuration,b.mistakeDuration=1,1
        r.driveSim.motorcycleCoastDragScale=.65
        AI.Drive(race,r,1000,DT);AI.Drive(other,b,1000,DT)
        check(r.speed>b.speed and r.speed<20,"惯行减少收油损失但不能凭空加速")
    end
    do
        local race,r=fixture(39,"sport",1,"hard")
        r.speed=35
        local drive=r.driveSim
        drive.motorcycleDriveScale,drive.motorcycleSpeedScale=1.25,1.08
        drive.motorcycleGripScale,drive.motorcycleOffroadScale=1.12,1.1
        drive.motorcycleCoastDragScale=.65
        local gear,rpm,active,cooldown=drive.gear,drive.rpm,drive.motorcycleActive,drive.motorcycleCooldown
        AI.NitroSafe(race,r)
        local preview=r.nitroPreview.driveSim --[[@as RideSimulation]]
        check(preview~=drive and preview.motorcycleDriveScale==1.25 and preview.motorcycleSpeedScale==1.08
            and preview.motorcycleGripScale==1.12 and preview.motorcycleOffroadScale==1.1
            and preview.motorcycleCoastDragScale==.65,"氮气预演必须使用独立状态与同一倍率")
        check(drive.gear==gear and drive.rpm==rpm and drive.motorcycleActive==active
            and drive.motorcycleCooldown==cooldown,"预演不得推进真实挡位或消费技能")
    end
    for _,id in ipairs({"sport","sport_2","sport_3","rally","rally_2","rally_3","cruiser","cruiser_2","cruiser_3"}) do
        local race,r=fixture(31,id,1,"hard")
        local drive=r.driveSim
        local spec=assert(Data.GetMotorcycleSkill(id))
        drive.speed,drive.groundSlope=20,.06
        Skills.Before(drive,DT,{skill=true})
        check(drive.motorcycleActive==spec.duration and drive.motorcycleCooldown==spec.cooldown,id.." AI状态必须可发动独立技能")
        Skills.Before(drive,(spec.chargeTime or DT)+.00001,{skill=false})
        check(drive.motorcycleDriveScale==spec.driveScale and drive.motorcycleGripScale==spec.gripScale,
            id.."实际状态必须输出该车型倍率")
        AI.Drive(race,r,1000,DT)
        check(r.speed>0 and drive.motorcycleCooldown>0,id.."技能与真实传动必须共存")
    end
    print(string.format("[摩托AI技能] PASS / %d项 / 九车型状态、动力、极速、弯道、路肩、惯行及独立预演",count))
    return count
end

function Checks.Run()
    Checks.MotorcycleSkills()
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
    local observed,watcher=fixture(31)
    watcher.speed,watcher.nitroCooldown,watcher.perception.timer=35,1000,0
    observed.aiObstacles={{s=32,lane=0,speed=15,halfWidth=1,halfLength=2.3,y=0,bike=false}}
    AI.Plan(observed,watcher,DT)
    local timer,seen=watcher.perception.timer,#watcher.perception.observations
    observed.aiObstacles[1].s=100
    AI.Plan(observed,watcher,DT)
    check(watcher.perception.timer<timer and #watcher.perception.observations==seen,
        "观察间隔内不得重新全知采样交通")
    result.rampCases=Checks.RampAvoidance()
    result.realTracks = Checks.RealTracks(100,false,{1})
    passed("六图三车型100秒真实地图确定性长时域")
    result.passed = true
    print(string.format("[RaceAIChecks] %d项断言通过，单次失误损失%.2f米", result.assertions, loss))
    return result
end
return Checks
