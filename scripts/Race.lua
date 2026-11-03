-- Closed-road race rules, independent of Scene/Vector3/input/traffic recycling.
-- Metres, seconds, degrees. New(map, sim) accepts a plain Lua map and driving adapter.
-- Contract: BeforeStep(dt,input) -> if phase=="racing": world:Update; sim:Step -> AfterStep(dt).
-- Countdown consumes complete frozen steps; its final AfterStep releases the green light.
-- Based on the existing Simulation fixed-step separation and collision examples 04/18.

local RaceAI = require("RaceAI")
local MixedRace = require("MixedRace")

-- 车型查询在热路径上每帧数百次；缓存到模块级，避免反复走require的package.loaded查找。
local MixedVehicles = require("MixedVehicles")

---@class ScenicRacePoint
---@field x number
---@field y number
---@field z number

---@class RaceMap
---@field activeId string?
---@field RouteLength number
---@field RoadPoint fun(s:number):ScenicRacePoint,number
---@field NearestRoad fun(x:number,z:number):number,number
---@field Height fun(x:number,z:number):number,boolean
---@field TrafficPose? fun(s:number,lane:number):ScenicRacePoint,number,number
---@field Roads? table[]

---@class RaceRacer:ScenicRacePoint
---@field id string
---@field name string
---@field isPlayer boolean
---@field vehicleId string
---@field colorId string
---@field index number
---@field x number
---@field y number
---@field z number
---@field yaw number
---@field pitch number
---@field lean number
---@field steer number
---@field speed number
---@field lane number
---@field wantedLane number
---@field s number Absolute signed main-road coordinate, never a recycled traffic distance.
---@field roadS number
---@field progress number Validated coordinate used for ranking.
---@field safeS number Last legal recovery coordinate.
---@field lastX number
---@field lastY number
---@field lastZ number
---@field contactX number
---@field contactY number
---@field contactZ number
---@field nextGate number Absolute coordinate of the next ordered gate.
---@field started boolean
---@field completedLaps number
---@field lap number
---@field rank number
---@field finished boolean
---@field eliminated boolean
---@field finishTime number
---@field eliminationTime number
---@field eliminationRank number
---@field status string
---@field nitro number
---@field boostTimer number
---@field boostLock boolean
---@field immunity number
---@field slipstream number
---@field collisionGraceUntil number
---@field graceDistance number
---@field lastTime number
---@field protectionUntil number
---@field danger number
---@field closeHold number
---@field wrongWay boolean
---@field offCourse boolean
---@field offCourseLast boolean
---@field invalidMoves number
---@field aggression number
---@field skill number
---@field speedFactor number
---@field acceleration number
---@field decisionTimer number
---@field mistakeTimer number
---@field mistakeGrace number
---@field mistakes number
---@field mistakeBias number
---@field missedGates number
---@field missedGate boolean 未过待门；只能返回正向穿越或脱困，不能追补。
---@field missedGateLogAt number
---@field hitShake number
---@field hitYaw number
---@field hitTimer number
---@field tumble number
---@field mistakeDuration number
---@field recoveryTimer number
---@field rubberBand number
---@field preferredLane number
---@field laneHold number
---@field blockedTime number
---@field trafficHits number
---@field avoidances number
---@field passes number
---@field targetSpeed number
---@field distanceDriven number
---@field trafficContacts table
---@field nextTrafficContacts table
---@field lastObstacle boolean
---@field aiLevel number 赛道等级，与玩家实时表现无关
---@field reactionTime number 正常决策间隔，单位秒
---@field paceTarget number 反应节奏锁存的目标速度
---@field paceTimer number 距离下次动力决策的时间
---@field nitroCooldown number 独立喷射冷却
---@field mistakeSeverity number 失误时的目标降速比例
---@field mistakeSpeed number 失误起点锁存的目标速度
---@field mistakeLane number 失误期间固定的走宽目标
---@field driveSim RideSimulation? 只用于独立传动状态，不更新第二套世界
---@field nitroPreview table? 独立传动预演缓存，不写回真实车手或玩家
---@field perception table 交通观察节奏、漏判与真实碰撞恢复状态
---@field driveAcceleration number 实际纵向加速度，单位米每平方秒

---@class RaceGate:ScenicRacePoint
---@field s number
---@field yaw number
---@field index number

---@class RaceEvent
---@field seq number
---@field kind string
---@field time number
---@field racerId string
---@field targetId string
---@field value number

---@class RaceRow
---@field id string
---@field name string
---@field position number
---@field status string
---@field elapsed number
---@field roadS number
---@field isPlayer boolean
---@field lap number
---@field progress number

---@class RacePursuit:ScenicRacePoint
---@field yaw number
---@field pitch number
---@field s number
---@field lane number
---@field speed number
---@field targetId string
---@field state string
---@field gap number
---@field danger number Seconds 0..6, not the HUD-normalised race.danger.
---@field active boolean

---@class RideRace
---@field map RaceMap
---@field sim RideSimulation
---@field options table
---@field phase string
---@field racers RaceRacer[]
---@field runners RaceRacer[]
---@field player RaceRacer
---@field ranking RaceRacer[]
---@field standings RaceRow[]
---@field results RaceRow[]
---@field result table?
---@field pursuit RacePursuit
---@field police RacePursuit
---@field checkpoints RaceGate[]
---@field samples RaceGate[]
---@field grid table<string,number[]>
---@field events RaceEvent[]
---@field eventSeq number
---@field elapsed number
---@field countdown number
---@field laps number
---@field startS number
---@field length number
---@field gateSpacing number
---@field gateCount number
---@field corridor number
---@field gateCorridor number Finite course boundary, shared by gates and player/AI validation.
---@field projectionPadding number Complete spatial-index search radius.
---@field roadHalfWidth number
---@field lastPlayerSpeed number
---@field stepOpen boolean
---@field lastImpact number
---@field lastRecovery number
---@field rng number
---@field nitroHeld boolean
---@field position number
---@field lap number
---@field nitro number
---@field danger number
---@field targetName string
---@field policeGap number
---@field remaining number
---@field protection number
---@field playerS number
---@field traffic table[]
---@field aiProfile table[]
---@field aiProfileStep number
---@field aiObstacles table[]
---@field nitroActive boolean
---@field nitroRemaining number
---@field nitroCooldown number
---@field nitroReason string
local Race = {}
Race.__index = Race
local abs, sqrt, min, max = math.abs, math.sqrt, math.min, math.max
local RAD, DEG = math.pi / 180, 180 / math.pi

-- Numerical design (not difficulty scaled by player throttle):
-- * 9 entrants, 1/2/3 laps; 85m ordered gates, <=.8m main-road projection samples.
-- * AI normal pace .94..1.0 of the selected class, eight stratified skills;
--   curvature budget21..25m/s², anticipatory braking, live traffic corridor selection.
--   No player-throttle scaling or rubber-band teleportation. Easy/hard are explicit options.
-- * 25s initial immunity, 8s continuously last warning, 6s collision grace.
--   Police starts 160m behind, accelerates at 8m/s², cap 1.04 selected bike max.
--   Actual proximity <=12m for a continuous 6s AND still last is necessary to arrest.
-- * Successor gets 10s immunity; near-danger drains .30s/s rather than resets.
-- * Side nudge: 3s cooldown, 2s received immunity, attacker retains .92, victim .72.
-- * Nitro: 100 resource, costs45, lasts exactly2.5s, +125% additional engine drive/+25% cap;
--   passive regeneration5/s, same-direction5..22m slipstream adds12/s. Finite coast-down.
Race.Rules = {countdown = 3, initialProtection = 25, lastWarning = 8, collisionGrace = 6,
    successorProtection = 10, policeStartGap = 160, captureDistance = 12, captureSeconds = 6,
    hitImmunity = 2, nitroCost = 45, nitroDuration = 2.5,
    gateBelow = 3, gateAbove = 10} -- sim.y (wheel/base contact), NOT visual oddAltitude.
-- Stock TrackFeatures ramps: rise<=2.15m, 20m long, half-grade lip (~.056).
-- At the certified 105m/s, vY~5.9m/s adds ~1.8m above the lip on flat road.
-- Real six-map downhill clearance audit peaks at 3.875m across 60 certified cases;
-- 10m leaves a finite flight corridor without accepting arbitrarily high crossings
-- or relaxing XZ/order/speed.

local function clamp(v, lo, hi) return max(lo, min(hi, v)) end
local function approach(v, goal, amount) return v + clamp(goal - v, -amount, amount) end
local function angle(a, b) return (a - b + 180) % 360 - 180 end
local function finite(v) return type(v) == "number" and v == v and abs(v) < math.huge end
local function laneKey(x, z) return math.floor(x / 32) .. ":" .. math.floor(z / 32) end
---@param a ScenicRacePoint
---@param b ScenicRacePoint
local function distance(a, b) return sqrt((a.x - b.x)^2 + (a.z - b.z)^2) end

---@param map RaceMap
---@param sim RideSimulation
---@param options table?
function Race.New(map, sim, options)
    local self = setmetatable({}, Race)
    self:Init(map, sim, options or {})
    return self
end

---@param map RaceMap
---@param sim RideSimulation
---@param options table
function Race:Init(map, sim, options)
    assert(map and finite(map.RouteLength) and map.RouteLength >= 80, "Race needs a closed main road >=80m")
    assert(type(map.RoadPoint) == "function" and type(map.Height) == "function", "Race map needs RoadPoint/Height")
    self.map, self.sim, self.options = map, sim, options
    self.traffic, self.aiObstacles = options.traffic or {}, {}
    self.nitroActive, self.nitroRemaining, self.nitroCooldown, self.nitroReason = false, 0, 0, "等待发车"
    self.length, self.startS = map.RouteLength, 0
    self.laps = clamp(math.floor(tonumber(options.laps) or 2), 1, 9)
    self.roadHalfWidth = map.Roads and map.Roads[1] and (map.Roads[1].width or 4.8) or 4.8
    self.corridor = self.roadHalfWidth + 0.8
    -- Match Simulation.Barrier's finite drivable boundary. Circuit has 4m of
    -- runoff beyond the shoulder; ebike centres can legally reach 16.47m there,
    -- but the old shoulder-only gate rejected everything outside 13m.
    local shoulder = (map.Roads and map.Roads[1] and map.Roads[1].shoulder) or self.roadHalfWidth
    self.gateCorridor = max(self.corridor, max(self.roadHalfWidth, shoulder)
        + (map.activeId == "circuit" and 4 or 1.1))
    self.projectionPadding = max(12, self.gateCorridor + 1)
    self.gateCount = max(8, math.ceil(self.length / 85))
    self.gateSpacing = self.length / self.gateCount
    self.samples, self.checkpoints, self.grid = {}, {}, {}
    local count = math.ceil(self.length / 0.8)
    for i = 0, count do
        local s = self.length * i / count
        local p, yaw = map.RoadPoint(s)
        assert(finite(p.x) and finite(p.y) and finite(p.z), "Race road sample is not finite")
        self.samples[#self.samples + 1] = {s = s, x = p.x, y = p.y, z = p.z, yaw = yaw or 0, index = i + 1}
    end
    local first, last = assert(self.samples[1]), assert(self.samples[#self.samples])
    assert(sqrt((first.x - last.x)^2 + (first.z - last.z)^2) < 5, "Race main road must close")
    for i = 1, #self.samples - 1 do
        local a, b = self.samples[i], self.samples[i + 1]
        for gx = math.floor((min(a.x, b.x) - self.projectionPadding) / 32), math.floor((max(a.x, b.x) + self.projectionPadding) / 32) do
            for gz = math.floor((min(a.z, b.z) - self.projectionPadding) / 32), math.floor((max(a.z, b.z) + self.projectionPadding) / 32) do
                local key = gx .. ":" .. gz
                if not self.grid[key] then self.grid[key] = {} end
                table.insert(self.grid[key], i)
            end
        end
    end
    for i = 0, self.gateCount - 1 do
        local s = i * self.gateSpacing
        local p, yaw = map.RoadPoint(s)
        self.checkpoints[#self.checkpoints + 1] = {s = s, x = p.x, y = p.y, z = p.z, yaw = yaw or 0, index = i + 1}
    end
    self.events, self.eventSeq = {}, 0
    self.racers, self.ranking, self.standings, self.results = {}, {}, {}, {}
    self.runners = self.racers
    self.pursuit = {x = 0, y = 0, z = 0, yaw = 0, pitch = 0, s = -160, lane = 0,
        speed = 0, targetId = "", state = "protection", gap = 160, danger = 0, active = false}
    self.police = self.pursuit
    self.phase, self.elapsed, self.countdown = "idle", 0, 3
    self.lastPlayerSpeed, self.stepOpen = 0, false
    self.lastImpact, self.lastRecovery = 0, 0
    self.nitroHeld = false
    self.rng = math.floor(tonumber(options.seed) or 4817) % 2147483647
    self.position, self.lap, self.nitro, self.danger = 5, 1, 100, 0
    self.targetName, self.policeGap, self.remaining, self.protection, self.playerS = "", 160, 9, 25, -18
    self.result = nil
    RaceAI.Build(self)
end

-- Bind the LIVE World traffic array once after world/race reset; no copying or ownership.
---@param traffic table[]
function Race:SetTraffic(traffic)
    self.traffic = traffic or {}
end

function Race:Random()
    self.rng = (self.rng * 48271) % 2147483647
    return self.rng / 2147483647
end

---@param kind string
---@param racerId string?
---@param targetId string?
---@param value number?
function Race:Emit(kind, racerId, targetId, value)
    self.eventSeq = self.eventSeq + 1
    self.events[#self.events + 1] = {seq = self.eventSeq, kind = kind, time = self.elapsed,
        racerId = racerId or "", targetId = targetId or "", value = value or 0}
    if #self.events > 96 then table.remove(self.events, 1) end
end

---@param s number
---@param lane number
---@return ScenicRacePoint,number,number
function Race:Pose(s, lane)
    if self.map.TrafficPose then return self.map.TrafficPose(s, lane) end
    local p, yaw = self.map.RoadPoint(s)
    local radians = (yaw or 0) * RAD
    local x, z = p.x + math.cos(radians) * lane, p.z - math.sin(radians) * lane
    return {x = x, y = self.map.Height(x, z), z = z}, yaw or 0, 0
end

---@param r RaceRacer
function Race:Place(r)
    local p, yaw, pitch = self:Pose(r.s, r.lane)
    r.x, r.y, r.z, r.yaw, r.pitch = p.x, p.y, p.z, yaw, pitch or 0
    r.roadS = r.s % self.length
end

---@param laps number?
function Race:Start(laps)
    if laps then self.laps = clamp(math.floor(laps), 1, 9) end
    self.sim.raceMode = true
    self.sim:Reset(false)
    self.phase, self.elapsed, self.countdown = "countdown", 0, 3
    self.lastPlayerSpeed, self.stepOpen = 0, false
    self.rng = max(1, math.floor(tonumber(self.options.seed) or 4817) % 2147483647)
    self.racers, self.ranking, self.standings, self.results = {}, {}, {}, {}
    self.runners, self.result = self.racers, nil
    for _,p in ipairs(self.mixedProjectiles or {}) do if p.node then p.node:Dispose() end end
    self.mixedProjectiles={}
    self.mixedExplosions={}
    self.nitroHeld = false
    local names = {"凌风", "山猫", "霓虹", "白隼", "牧歌", "赤轮", "雾影", "雷鸟"}
    ---@type string[]
    local cars = self.options.mixed and require("MixedAssets").RaceIds() or self.options.vehicleIds or {"sport", "cruiser", "rally"}
    local rosterOffset=self.options.rosterOffset or 0
    if #cars == 0 then cars = {"sport", "cruiser", "rally"} end
    local rosterStep = self.options.mixed and 7 or 1
    local a, b = rosterStep, #cars
    while b ~= 0 do a, b = b, a % b end
    -- 保留原有互质池的顺序；否则顺序遍历，确保耗尽池前不重复且不消耗随机数。
    if a ~= 1 then rosterStep = 1 end
    for i = 1, 9 do
        local isPlayer = i == 5
        local aiIndex = i < 5 and i or i - 1
        local lane = i % 2 == 0 and -1.55 or 1.55
        local s = -6 - math.floor((i - 1) / 2) * 6
        ---@type RaceRacer
        local r = {id = isPlayer and "player" or "ai" .. aiIndex,
            name = isPlayer and "你" or names[aiIndex], isPlayer = isPlayer,
            vehicleId = isPlayer and self.sim.vehicleId or cars[((aiIndex - 1)*rosterStep+rosterOffset) % #cars + 1],
            colorId = ({"red", "blue", "yellow", "white", "green", "violet", "blue", "yellow", "violet"})[i],
            index = i, x = 0, y = 0, z = 0, yaw = 0, pitch = 0, lean = 0, steer = 0,
            speed = 0, lane = lane, wantedLane = lane, s = s, roadS = s % self.length,
            progress = s, safeS = s, lastX = 0, lastY = 0, lastZ = 0, contactX = 0, contactY = 0, contactZ = 0,
            nextGate = 0, started = false, completedLaps = 0, lap = 1, rank = i,
            missedGate = false, missedGateLogAt = -math.huge, missedGates = 0,
            finished = false, eliminated = false, finishTime = 0, eliminationTime = 0, eliminationRank = 0,
            status = "racing", nitro = 100, boostTimer = 0, boostLock = false,
            immunity = 0, slipstream = 0, collisionGraceUntil = 0,
            graceDistance = s - 100, lastTime = 0, protectionUntil = 25, danger = 0, closeHold = 0,
            wrongWay = false, offCourse = false, offCourseLast = false, invalidMoves = 0,
            aggression = 0.22 + self:Random() * 0.68, skill = 0.25 + self:Random() * 0.72,
            speedFactor = 0.74 + self:Random() * 0.12, acceleration = 6.5 + self:Random() * 2.5,
            decisionTimer = self:Random(), mistakeTimer = 10 + self:Random() * 15,
            hitShake = 0, hitYaw = 0, hitTimer = 0,
            mistakeDuration = 0, recoveryTimer = 0, rubberBand = 0,
            preferredLane = lane, laneHold = 0, blockedTime = 0, trafficHits = 0, avoidances = 0,
            passes = 0, targetSpeed = 0, distanceDriven = 0, trafficContacts = {}, nextTrafficContacts = {}, lastObstacle = false}
        RaceAI.Configure(self, r, aiIndex)
        self:Place(r)
        r.lastX, r.lastY, r.lastZ = r.x, r.y, r.z
        r.contactX, r.contactY, r.contactZ = r.x, r.y, r.z
        self.racers[#self.racers + 1] = r
        if isPlayer then self.player = r end
    end
    local p = self.player
    self.sim.x, self.sim.y, self.sim.z = p.x, p.y, p.z
    self.sim.heading, self.sim.yaw = p.yaw, p.yaw
    self.sim.previousX, self.sim.previousY, self.sim.previousZ = p.x, p.y, p.z
    self.sim:UpdateNavigation(p.x, p.z, nil, false)
    self.lastImpact, self.lastRecovery = self.sim.impactSerial, self.sim.recoverySerial
    self:Rank()
    local last = self:Last()
    local police = self.pursuit
    police.s, police.speed, police.lane = last.s - 160, 0, 0
    police.targetId, police.state, police.gap, police.danger, police.active = last.id, "protection", 160, 0, false
    local pp, yaw, pitch = self:Pose(police.s, police.lane)
    police.x, police.y, police.z, police.yaw, police.pitch = pp.x, pp.y, pp.z, yaw, pitch
    self:Emit("countdown", "", "", 3)
    self:Mirror()
    if not self.options.quiet then print(string.format("[竞速] 9车 / %d圈 / %.0fm主线 / %d检查点", self.laps, self.length, self.gateCount)) end
end

---@param sim RideSimulation?
---@param laps number?
function Race:Reset(sim, laps)
    if sim then self.sim = sim end
    self:Start(laps)
end

function Race:Stop()
    self.phase, self.stepOpen = "idle", false
    self.sim.raceMode, self.sim.raceBoost = false, 0
    self.pursuit.active, self.pursuit.state = false, "finished"
    self.nitroHeld = false
    self.nitroActive, self.nitroRemaining, self.nitroCooldown, self.nitroReason = false, 0, 0, "等待发车"
end

-- Spatial projection uses only the sampled closed MAIN road. Side roads/total odometer never count.
---@param x number
---@param z number
---@return number,number,number
function Race:Project(x, z)
    local list = self.grid[laneKey(x, z)]
    local bestD, bestS, bestLane = math.huge, 0, 0
    local function test(i)
        local a, b = self.samples[i], self.samples[i + 1]
        local dx, dz = b.x - a.x, b.z - a.z
        local len2 = dx * dx + dz * dz
        if len2 < 1e-8 then return end
        local t = clamp(((x - a.x) * dx + (z - a.z) * dz) / len2, 0, 1)
        local ox, oz = x - a.x - dx * t, z - a.z - dz * t
        local d = ox * ox + oz * oz
        if d < bestD then
            bestD, bestS = d, a.s + (b.s - a.s) * t
            bestLane = (ox * dz - oz * dx) / sqrt(len2)
        end
    end
    if list then
        for _, i in ipairs(list) do test(i) end
        -- The index is a complete superset for the finite course boundary. Keep
        -- a correctness fallback for a seam/cell edge or a future map with a
        -- larger legal ribbon; projection must never become cell-dependent.
        if bestD > self.projectionPadding * self.projectionPadding then
            for i = 1, #self.samples - 1 do test(i) end
        end
    else
        for i = 1, #self.samples - 1 do test(i) end
    end
    return bestS % self.length, bestLane, sqrt(bestD)
end

-- Gate collision design (top view, local yaw axes):
--                +forward (race direction)
--                    ^
--     -corridor -----+----- +corridor    gate is a finite CROSSING PLANE, not a circle
--           p0 o ---/---> o p1
-- Requires dot(p0-gate,f)<=0 AND dot(p1-gate,f)>0, inside lateral +/-corridor,
-- -3m <= height-road <=10m: finite flight corridor shared by ALL vehicle classes.
-- Reverse/tangent/edge outside the line cannot collect a gate. Visual oddAltitude
-- does not move sim.y, and must not be counted twice for helicopter/hopping vehicles.
-- Ordered absolute gate indices prevent U-turn farming and shortcut lap-wrap exploits.
-- Excursions between gates are allowed; missing a gate caps progress, never teleports.
---@param r RaceRacer
---@param reason string
function Race:MissGate(r, reason)
    if r.finished or r.eliminated then return end
    local first = not r.missedGate
    r.missedGate = true
    if not r.isPlayer then return end
    if not self.options.quiet and (first or self.elapsed >= r.missedGateLogAt + 5) then
        r.missedGateLogAt = self.elapsed
        local road = self.map.RoadPoint(r.nextGate)
        print(string.format("[竞速漏门] %s s=%.3f nextGate=%.3f started=%s completedLaps=%d altitude=%.3f oddAltitude=%.3f invalidMoves=%d",
            reason, r.s, r.nextGate, tostring(r.started), r.completedLaps,
            r.y - road.y, self.sim.oddAltitude or 0, r.invalidMoves))
    end
end

---@param r RaceRacer
---@param oldS number
---@param newS number
---@param dt number
function Race:AdvanceGates(r, oldS, newS, dt)
    if r.finished or r.eliminated or not finite(dt) or dt <= 0 then return end
    -- Always test the ACTUAL physical segment. Never invent on-road intermediate poses
    -- for a long host frame: that would award gates while a stunt/shortcut missed them.
    -- Offset ribbon normals can cross well before the centre-line station at tight
    -- bends. The window only selects the ordered absolute gate; the finite plane
    -- remains authoritative even if the nearest projection pauses at a sample seam.
    local window = min(self.gateSpacing * .45, max(8, self.gateCorridor * 2 + 1))
    local lastCrossing = -1
    ---@param t number
    local function completeLap(t)
        r.completedLaps = r.completedLaps + 1
        r.lap = min(self.laps, r.completedLaps + 1)
        if r.completedLaps >= self.laps then
            r.finished, r.status = true, "finished"
            r.finishTime = self.elapsed - dt + t * dt
            r.progress = self.laps * self.length
            self:Emit("finish", r.id)
        end
    end
    ---@param gateS number
    ---@return boolean
    local function isFinishGate(gateS)
        return gateS >= self.length - 0.01
            and abs(gateS / self.length - math.floor(gateS / self.length + 0.5)) < 1e-6
    end
    -- No catch-up: even an ordinary missed gate requires a real forward recrossing.
    while r.nextGate <= max(oldS, newS) + window and r.nextGate >= min(oldS, newS) - window do
        local gateS = r.nextGate
        local p, yaw = self.map.RoadPoint(gateS)
        local fx, fz = math.sin((yaw or 0) * RAD), math.cos((yaw or 0) * RAD)
        local side0 = (r.lastX - p.x) * fx + (r.lastZ - p.z) * fz
        local side1 = (r.x - p.x) * fx + (r.z - p.z) * fz
        if side0 > 1e-6 or side1 <= 0 or side1 <= side0 then break end
        local t = clamp(-side0 / max(1e-8, side1 - side0), 0, 1)
        -- A single high-speed segment can cross several gates, but never in the
        -- reverse temporal order (e.g. a chord through two arms of a hairpin).
        if t <= lastCrossing + 1e-8 then break end
        local cx, cz = r.lastX + (r.x - r.lastX) * t, r.lastZ + (r.z - r.lastZ) * t
        local lateral = (cx - p.x) * fz - (cz - p.z) * fx
        local cy = r.lastY + (r.y - r.lastY) * t
        -- Use the surface at the crossing, not centre-line y: runoff/shoulders
        -- can be lower, and the same altitude contract is used by TrackPlayer.
        local altitude = cy - self.map.Height(cx, cz)
        if abs(lateral) > self:GateCorridorFor(r) or altitude < -Race.Rules.gateBelow
            or altitude > Race.Rules.gateAbove then
            self:MissGate(r, "穿门超出有限走廊")
            break
        end
        r.missedGate = false
        if not r.started then r.started = true
        elseif isFinishGate(gateS) then completeLap(t)
        end
        r.nextGate = gateS + self.gateSpacing
        lastCrossing = t
        if r.finished then break end
    end
end

---@param r RaceRacer?
---@return number
function Race:GateCorridorFor(r)
    local corridor = self.gateCorridor or self.corridor
    if r then
        local spec = MixedVehicles.Get(r.vehicleId)
        if spec then corridor = corridor - spec.size[1] * .5 end
    end
    return corridor
end

-- Shared player/AI contract: position continuity authorises a swept gate test;
-- projection/path distance alone never awards a gate or a lap.
---@param r RaceRacer
---@param oldS number
---@param newS number
---@param dt number
---@param previousSpeed number
---@param recovered boolean?
---@param roadDistance number?
function Race:ValidateProgress(r, oldS, newS, dt, previousSpeed, recovered, roadDistance)
    if r.finished or r.eliminated or not finite(dt) or dt <= 0 then return end
    local traveled = sqrt((r.x - r.lastX)^2 + (r.z - r.lastZ)^2)
    local drive = r.isPlayer and self.sim or r.driveSim or self.sim
    local maximum = max(drive.vehicle.maxSpeed * 1.28, max(r.speed, previousSpeed) * 1.35 + 1) * dt + .5
    local physical = not recovered and finite(traveled) and traveled <= maximum
    local altitude = r.y - self.map.Height(r.x, r.z)
    local delta = newS - oldS
    local courseDistance = roadDistance or abs(r.lane)
    local onCourse = courseDistance <= self:GateCorridorFor(r)
        and altitude >= -Race.Rules.gateBelow and altitude <= Race.Rules.gateAbove
    r.wrongWay, r.offCourse = delta < -.03, not onCourse
    if physical then
        self:AdvanceGates(r, oldS, newS, dt)
        if not r.finished then r.progress = min(newS, r.nextGate - .001) end
        if onCourse and abs(delta) <= traveled * 2 + 1 then r.safeS = min(newS, r.nextGate - .5) end
    else
        if not recovered then r.invalidMoves = r.invalidMoves + 1 end
        r.progress = min(r.progress, newS, r.nextGate - .001)
    end
    local gateSpacing = self.gateSpacing or (self.length / math.max(1, self.gateCount or 1))
    if not r.finished and newS > r.nextGate + min(8, gateSpacing * .2) then
        self:MissGate(r, physical and "待门落后" or "非连续移动越门")
    end
    r.offCourseLast = not onCourse or not physical
end

---@param dt number
function Race:TrackPlayer(dt)
    local r, sim = self.player, self.sim
    if r.finished or r.eliminated then return end
    r.x, r.y, r.z = sim.x, sim.y, sim.z
    r.yaw, r.pitch, r.lean, r.steer, r.speed = sim.yaw, sim.pitch, sim.lean, sim.steer, sim.speed
    if not finite(r.x) or not finite(r.y) or not finite(r.z) then
        -- A genuinely invalid simulation pose, not an ordinary verge/grass excursion.
        self:RecoverPlayer(false)
        return
    end
    local projected, lane, roadDistance = self:Project(r.x, r.z)
    r.lane, r.roadS = lane, projected
    local recovered = sim.recoverySerial ~= self.lastRecovery
    self.lastRecovery = sim.recoverySerial
    local delta = (projected - r.s % self.length + self.length * 0.5) % self.length - self.length * 0.5
    local oldS = r.s
    r.s = r.s + delta
    self:ValidateProgress(r, oldS, r.s, dt, self.lastPlayerSpeed, recovered, roadDistance)
    if r.missedGate then
        sim.message = string.format("漏过检查点%d · 请返回检查点正向通过，或使用脱困回到待门前",
            math.floor(r.nextGate / self.gateSpacing + .5) % self.gateCount + 1)
        sim.messageTimer = 2
    elseif sim.message:find("漏过检查点", 1, true) == 1 then
        sim.message, sim.messageTimer = "检查点已通过 · 继续比赛", 2
    end
    r.lastX, r.lastY, r.lastZ = r.x, r.y, r.z
    self.lastPlayerSpeed = r.speed
end

---@param grantGrace boolean?
function Race:RecoverPlayer(grantGrace)
    local r, sim = self.player, self.sim
    if not r or r.finished or r.eliminated then return false end
    local before = r.progress
    sim:Recover(nil)
    -- Recovery returns to the last trusted coordinate. Nearest-road projection
    -- is never a forward placement authority after a shortcut or rejected jump.
    local anchor = r.missedGate and (r.nextGate - min(6, self.gateSpacing * .1))
        or min(r.safeS, r.nextGate - .5)
    local recoveryLane = r.missedGate and 0 or 1.55
    local p, yaw = self:Pose(anchor, recoveryLane)
    local origin, direction = self.map.RoadPoint(r.nextGate)
    local side = (p.x - origin.x) * math.sin((direction or 0) * RAD)
        + (p.z - origin.z) * math.cos((direction or 0) * RAD)
    if side >= -1e-6 and r.nextGate - anchor < min(6, self.gateSpacing * .1) then
        -- A lane normal at a sharp bend may put s=gate-.5 AFTER its plane.
        -- Fall back to the centre before it, never fabricate the missing crossing.
        anchor, recoveryLane = r.nextGate - min(6, self.gateSpacing * .1), 0
        p, yaw = self:Pose(anchor, recoveryLane)
    end
    sim.x, sim.y, sim.z, sim.heading, sim.yaw = p.x, p.y, p.z, yaw, yaw
    sim.previousX, sim.previousY, sim.previousZ = p.x, p.y, p.z
    sim:UpdateNavigation(p.x, p.z, nil, false)
    r.s, r.progress, r.safeS, r.x, r.y, r.z = anchor, min(before, r.safeS, anchor), min(r.safeS, anchor), p.x, p.y, p.z
    r.lastX, r.lastY, r.lastZ = p.x, p.y, p.z
    r.contactX, r.contactY, r.contactZ = p.x, p.y, p.z
    r.speed, r.yaw, r.lane, r.roadS = 0, yaw, recoveryLane, r.s % self.length
    r.offCourse, r.offCourseLast = false, false
    sim.groundY = p.y
    sim.message, sim.messageTimer = "已回到待检查点前 · 请沿赛道正向通过", 3
    -- Recovery preserves closeHold AND danger: repeated recover cannot buy six fresh seconds.
    self.lastRecovery = sim.recoverySerial
    if grantGrace then self:Collision(r) end
    return true
end

---@param r RaceRacer
---@param look number?
function Race:CurveSpeed(r, look)
    return RaceAI.CurveSpeed(self, r)
end

---@param r RaceRacer
---@param dt number
function Race:UpdateAI(r, dt)
    RaceAI.Update(self, r, dt)
end

---@param controls table?
function Race:NitroReason(controls)
    if self.phase == "countdown" or self.phase == "idle" then return "等待发车" end
    if self.phase ~= "racing" or self.player.finished or self.player.eliminated then return "已结束" end
    if self.player.boostTimer > 0 then return "喷射中" end
    if self.player.nitro < Race.Rules.nitroCost then return "氮气不足" end
    if self.sim.airborne then return "腾空中" end
    if (controls and controls.brake) or (not controls and self.sim.braking) then return "刹车中" end
    if (controls and controls.burnout) or self.sim.burnout then return "烧胎中" end
    return "可用"
end

---@param r RaceRacer
---@param controls table?
function Race:Boost(r, controls)
    if self.phase ~= "racing" or r.finished or r.eliminated
        or r.nitro < Race.Rules.nitroCost or r.boostTimer > 0 then return false end
    if r.isPlayer and self:NitroReason(controls) ~= "可用" then return false end
    r.nitro, r.boostTimer = r.nitro - Race.Rules.nitroCost, Race.Rules.nitroDuration
    self:Emit("boost", r.id)
    return true
end

---@param r RaceRacer
---@param dt number
function Race:Resources(r, dt)
    -- Boost time is consumed AFTER the authorised driving step, so a2.5s pulse is
    -- exactly125 fixed20ms steps (activation must not add an extra free frame).
    r.immunity = max(0, r.immunity - dt)
    if r.finished or r.eliminated then return end
    r.slipstream = 0
    if r.speed > 8 then
        for _, other in ipairs(self.racers) do
            if other ~= r and not other.eliminated and not other.finished then
                local delta = other.s - r.s
                if delta >= 5 and delta <= 22 and abs(other.lane - r.lane) < 1.25
                    and abs(angle(other.yaw, r.yaw)) < 30 and abs(other.y - r.y) < 2 then r.slipstream = 1; break end
            end
        end
    end
    if r.boostTimer <= 0 then r.nitro = min(100, r.nitro + dt * (5 + r.slipstream * 12)) end
end

-- 已移除贴身肘击/推撞：这版玩法不再允许主动攻击其他车手。
-- AI 之间的位置接触仍由 Race:Contacts 的物理扫掠处理，仅减速、不主动打人。
---@param attacker RaceRacer
function Race:Shove(attacker)
    return false
end

---@param r RaceRacer
function Race:Collision(r)
    if self.elapsed < r.protectionUntil then return end
    -- Grace requires 35m NEW validated forward progress since the last grant.
    -- Repeated wall tapping / repeated recovery while parked cannot refresh invulnerability.
    if r.progress >= r.graceDistance + 35 then
        r.collisionGraceUntil, r.graceDistance = self.elapsed + 6, r.progress
    end
end

-- Swept ordinary race contact: bikes are .6m wide x2m long x1.5m tall.
-- Relative segment p0----p1 tested against expanded +/- .65 lateral, +/-2.1 longitudinal;
-- Y uses the SAME interval, so jumps over opponents are not false contacts.
-- Continuous overlapping pair is protected by each rider's2s immunity, no per-frame stun.
---@param dt number
function Race:Contacts(dt)
    for i = 1, #self.racers - 1 do
        local a = self.racers[i]
        if not a.eliminated and not a.finished and a.immunity <= 0 then
            for j = i + 1, #self.racers do
                local b = self.racers[j]
                -- 先做一次距离粗筛：8车间毫无可能相撞的配对直接跳过，
                -- 避免每帧对全部36对做完整扫掠+车型查询。
                local gx, gz = b.x - a.x, b.z - a.z
                if not b.eliminated and not b.finished and b.immunity <= 0
                    and gx * gx + gz * gz < 144 then
                    local sx, sz = math.sin(a.yaw * RAD), math.cos(a.yaw * RAD)
                    local dx0, dz0 = b.contactX - a.contactX, b.contactZ - a.contactZ
                    local dx1, dz1 = b.x - a.x, b.z - a.z
                    local lx0, lx1 = dx0 * sz - dz0 * sx, dx1 * sz - dz1 * sx
                    local f0, f1 = dx0 * sx + dz0 * sz, dx1 * sx + dz1 * sz
                    local va=MixedVehicles.Get(a.vehicleId)
                    local vb=MixedVehicles.Get(b.vehicleId)
                    local halfWidth=va and va.size[1]*.5 or .3
                    local halfLength=va and va.size[3]*.5 or 1
                    local delta=(b.yaw-a.yaw)*RAD
                    halfWidth=halfWidth+(vb and vb.size[1]*.5 or .3)*abs(math.cos(delta))
                        +(vb and vb.size[3]*.5 or 1)*abs(math.sin(delta))+.05
                    halfLength=halfLength+(vb and vb.size[3]*.5 or 1)*abs(math.cos(delta))
                        +(vb and vb.size[1]*.5 or .3)*abs(math.sin(delta))+.1
                    local hit, enter, leave = self.sim.SweptHit(lx0, lx1, f0, f1, halfWidth, halfLength)
                    if hit then
                        local da=(a.isPlayer and self.sim or a.driveSim) --[[@as RideSimulation?]]
                        local db=(b.isPlayer and self.sim or b.driveSim) --[[@as RideSimulation?]]
                        local lift=(db and db.oddAltitude or 0)-(da and da.oddAltitude or 0)
                        local y0, y1 = b.contactY - a.contactY+lift, b.y - a.y+lift
                        local clearance=((va and va.size[2] or 1.5)+(vb and vb.size[2] or 1.5))*.5
                        local centre=((vb and vb.size[2] or 1.5)-(va and va.size[2] or 1.5))*.5
                        y0,y1=y0+centre,y1+centre
                        local dy = y1 - y0
                        if abs(dy) < 1e-8 then hit = abs(y0) <= clearance
                        else
                            local ta, tb = (-clearance - y0) / dy, (clearance - y0) / dy
                            if ta > tb then ta, tb = tb, ta end
                            hit = max(enter, ta) <= min(leave, tb)
                        end
                    end
                    if hit then
                        local retained = clamp(0.92 - abs(a.speed - b.speed) * 0.006, 0.64, 0.92)
                        a.speed, b.speed = a.speed * retained, b.speed * retained
                        if self.options.mixed then
                            local function response(r,forward,sideDistance)
                                local drive=r.isPlayer and self.sim or r.driveSim
                                if drive and (drive.oddShield or 0)>0 then return end
                                local scale,disrupt,offset=MixedRace.ContactResponse(r.vehicleId,retained,forward,sideDistance)
                                r.speed=r.speed*scale
                                if offset~=0 then
                                    local spec=MixedVehicles.Get(r.vehicleId)
                                    local margin=(spec and spec.size[1]*.5 or .3)+.15
                                    r.wantedLane=clamp(r.lane+offset,-self.roadHalfWidth+margin,self.roadHalfWidth-margin)
                                end
                                if drive then drive.oddDisrupt=max(drive.oddDisrupt or 0,disrupt) end
                            end
                            local bs,bc=math.sin(b.yaw*RAD),math.cos(b.yaw*RAD)
                            response(a,f1,lx1)
                            response(b,-dx1*bs-dz1*bc,-dx1*bc+dz1*bs)
                        end
                        a.immunity, b.immunity = 2, 2
                        -- 撞车表现：按相对位置分左右，给出车身猛晃/偏航，而不是只掉速度。
                        local side = ((b.x - a.x) * math.cos(a.yaw * RAD)
                            - (b.z - a.z) * math.sin(a.yaw * RAD)) >= 0 and 1 or -1
                        local strength = clamp(0.45 + abs(a.speed - b.speed) * 0.02, 0.45, 1.0)
                        a.hitShake, a.hitYaw, a.hitTimer = strength, -side * 16 * strength, 0.55
                        b.hitShake, b.hitYaw, b.hitTimer = strength * 1.15, side * 22 * strength, 0.70
                        if b.isPlayer then
                            -- 玩家被撞时移动端有更明显的可见反馈。
                            self.sim.hitShake, self.sim.hitTimer = 1.0, 0.6
                        elseif a.isPlayer then
                            self.sim.hitShake, self.sim.hitTimer = 0.7, 0.45
                        end
                        if a.isPlayer or b.isPlayer then
                            local player = a.isPlayer and a or b
                            self.sim.speed = player.speed
                            self.sim.health = max(15, self.sim.health - 6)
                            self.sim.crashCooldown = max(self.sim.crashCooldown, 2)
                        end
                        self:Collision(a); self:Collision(b)
                        self:Emit("contact", a.id, b.id)
                    end
                end
            end
        end
    end
end

---@return RaceRacer
function Race:Last()
    for i = #self.ranking, 1, -1 do
        local r = self.ranking[i]
        if not r.eliminated and not r.finished then return r end
    end
    return self.player
end

function Race:Rank()
    self.ranking = {}
    for _, r in ipairs(self.racers) do self.ranking[#self.ranking + 1] = r end
    table.sort(self.ranking, function(a, b)
        if a.finished ~= b.finished then return a.finished end
        if a.finished then
            if a.finishTime ~= b.finishTime then return a.finishTime < b.finishTime end
        elseif a.eliminated ~= b.eliminated then return not a.eliminated
        elseif a.eliminated then
            if a.eliminationRank ~= b.eliminationRank then return a.eliminationRank < b.eliminationRank end
        elseif abs(a.progress - b.progress) > 0.001 then return a.progress > b.progress end
        return a.index < b.index -- Total stable ordering, even when all start/finish simultaneously.
    end)
    self.standings = {}
    for position, r in ipairs(self.ranking) do
        r.rank = position
        self.standings[#self.standings + 1] = {id = r.id, name = r.name, position = position,
            status = r.status, elapsed = r.finished and r.finishTime or self.elapsed,
            roadS = r.roadS, isPlayer = r.isPlayer, lap = r.lap, progress = r.progress}
    end
end

---@param r RaceRacer
function Race:Eliminate(r)
    if r.eliminated or r.finished then return end
    local rank = 0
    for _, other in ipairs(self.racers) do if not other.eliminated then rank = rank + 1 end end
    r.eliminated, r.status, r.eliminationTime, r.eliminationRank = true, "eliminated", self.elapsed, rank
    r.speed, r.boostTimer = 0, 0
    if r.isPlayer then self.sim.speed = 0 end
    self:Emit("eliminated", r.id)
    self:Rank()
    local nextLast = self:Last()
    if nextLast ~= r and not nextLast.finished and not nextLast.eliminated then
        nextLast.protectionUntil = max(nextLast.protectionUntil, self.elapsed + 10)
        nextLast.lastTime, nextLast.closeHold = 0, 0
        self.pursuit.targetId = nextLast.id
        -- Only move the hunter backwards for fairness, never forward to a new target.
        self.pursuit.s = min(self.pursuit.s, nextLast.s - 80)
        self.pursuit.state = "protection"
    end
    if not self.options.quiet then print("[追车] 淘汰 " .. r.name .. "，下一位保护10秒") end
end

---@param dt number
function Race:UpdatePursuit(dt)
    if self.options.professional then
        self.pursuit.active,self.pursuit.state=false,"closed_course"
        return
    end
    local target = self:Last()
    local p = self.pursuit
    if target.finished or target.eliminated then p.active, p.state = false, "finished"; return end
    if p.targetId ~= target.id then
        p.targetId, target.closeHold = target.id, 0
    end
    for _, r in ipairs(self.racers) do
        if r ~= target then
            r.lastTime, r.closeHold = 0, 0
            r.danger = max(0, r.danger - dt * 0.3)
        end
    end
    local protected = self.elapsed < target.protectionUntil
    local grace = self.elapsed < target.collisionGraceUntil
    if protected then target.lastTime = 0
    else target.lastTime = target.lastTime + dt end
    local warned = target.lastTime >= 8
    local oldState = p.state
    p.active = not protected and warned
    p.state = protected and "protection" or (grace and "grace" or (warned and "chasing" or "watching"))
    if warned and target.lastTime < 10 and not protected and not grace then p.state = "warning" end
    if p.state == "warning" and oldState ~= "warning" then self:Emit("warning", target.id) end
    local gap = target.s - p.s
    if p.active then
        local top = self.sim.vehicle.maxSpeed * 1.04
        local _, yawA = self.map.RoadPoint(p.s - 4)
        local _, yawB = self.map.RoadPoint(p.s + max(8, p.speed * 0.4))
        local curvature = abs(angle(yawB or 0, yawA or 0)) * RAD / max(12, p.speed * 0.4 + 4)
        local curveCap = sqrt(22 / max(0.0001, curvature))
        p.speed = approach(p.speed, min(top, max(12, curveCap)), dt * 8)
        p.s = min(p.s + p.speed * dt, target.s - (grace and 14 or 5))
    else
        -- Protection/watch follow from behind; not a pursuit or a closeness accumulator.
        p.speed = approach(p.speed, target.speed, dt * 8)
        p.s = min(p.s + p.speed * dt, target.s - 160)
    end
    local pose, yaw, pitch = self:Pose(p.s, p.lane)
    -- Last20 route metres: leave the asphalt to reach a parked off-road target physically.
    -- Rendering MUST use police.x/y/z, not resample its road coordinate in this final approach.
    if p.active and gap < 24 and not grace then
        local dx, dz = target.x - p.x, target.z - p.z
        local d = sqrt(dx * dx + dz * dz)
        local step = min(max(0, d - 5), max(8, p.speed * 0.6) * dt)
        if d > 0.001 then
            p.x, p.z = p.x + dx / d * step, p.z + dz / d * step
            p.y, p.yaw, p.pitch = self.map.Height(p.x, p.z), math.atan(dx, dz) * DEG, 0
        end
    else p.x, p.y, p.z, p.yaw, p.pitch = pose.x, pose.y, pose.z, yaw, pitch end
    p.gap = distance(p, target)
    local close = p.active and not grace and not protected and p.gap <= 12 and abs(p.y - target.y) <= 3
    if close then
        target.closeHold, target.danger = target.closeHold + dt, min(6, target.danger + dt)
    else
        target.closeHold = 0
        target.danger = max(0, target.danger - dt * 0.3)
    end
    p.danger = target.danger
    if close and target.closeHold >= 6 - 1e-7 then self:Eliminate(target) end
end

function Race:Mirror()
    local r, p = self.player, self.pursuit
    self.position, self.lap, self.nitro = r.rank, r.lap, r.nitro
    self.danger, self.policeGap, self.playerS = p.danger / 6, p.gap, r.progress
    self.remaining, self.targetName = 0, ""
    for _, candidate in ipairs(self.racers) do
        if not candidate.finished and not candidate.eliminated then self.remaining = self.remaining + 1 end
        if candidate.id == p.targetId then self.targetName = candidate.name end
    end
    self.protection = max(0, r.protectionUntil - self.elapsed, r.collisionGraceUntil - self.elapsed)
    self.nitroActive = self.phase == "racing" and r.boostTimer > 0
    self.nitroRemaining, self.nitroCooldown = r.boostTimer, r.boostTimer
    self.nitroReason = self:NitroReason()
end

---@param reason string
function Race:Settle(reason)
    if self.phase == "finished" then return end
    self:Rank()
    self.phase, self.stepOpen = "finished", false
    self.pursuit.active, self.pursuit.state = false, "finished"
    self.results = {}
    for _, row in ipairs(self.standings) do
        self.results[#self.results + 1] = {id = row.id, name = row.name, position = row.position,
            status = row.status == "racing" and "dnf" or row.status, elapsed = row.elapsed,
            roadS = row.roadS, isPlayer = row.isPlayer, lap = row.lap, progress = row.progress}
    end
    self.result = {title = self.player.eliminated and "追车截停" or "竞速完成", reason = reason,
        position = self.player.rank, elapsed = self.player.finished and self.player.finishTime or self.elapsed,
        success = self.player.finished, laps = self.laps}
    self.sim.success, self.sim.raceBoost = self.player.finished, 0
    self:Emit("settled", "player")
    self:Mirror()
    if not self.options.quiet then print(string.format("[竞速] 稳定结算 第%d/9名，%.2f秒，%s", self.player.rank, self.elapsed, reason)) end
end

---@param action string
---@param value any
function Race:HandleInput(action, value)
    if action == "restart" then self:Start(type(value) == "number" and value or nil); return true end
    if action == "nitro" then self.nitroHeld = value ~= false; return true end
    if self.phase ~= "racing" then return false end
    if action == "recover" then return self:RecoverPlayer(true) end
    return false
end

---@param dt number
---@param controls table?
---@param traffic table[]?
---@return table
function Race:BeforeStep(dt, controls, traffic)
    if traffic then self:SetTraffic(traffic) end
    local drive = {}
    for key, value in pairs(controls or {}) do drive[key] = value end
    drive.boost = 0 -- no caller can bypass the100-point resource by writing boost directly.
    self.stepOpen = false
    if not finite(dt) or dt <= 0 then return drive end
    if self.phase == "countdown" then
        local old = math.ceil(self.countdown - 1e-8)
        self.countdown = max(0, self.countdown - dt)
        local current = math.ceil(self.countdown - 1e-8)
        if current > 0 and current ~= old then self:Emit("countdown", "", "", current) end
        drive.throttle, drive.brake, drive.steer = 0, true, 0
        self.stepOpen = true
        return drive
    end
    if self.phase ~= "racing" then return drive end
    self.stepOpen = true
    for _, r in ipairs(self.racers) do
        r.contactX, r.contactY, r.contactZ = r.x, r.y, r.z
        self:Resources(r, dt)
    end
    local held = drive.nitro == true or self.nitroHeld
    if held and not self.player.boostLock then
        self.player.boostLock = self:Boost(self.player, drive)
    elseif not held then self.player.boostLock = false end
    drive.boost = self.player.boostTimer > 0 and 1 or 0
    self:Mirror()
    if self.sim.impactSerial ~= self.lastImpact then
        self:Collision(self.player)
        self.lastImpact = self.sim.impactSerial
    end
    return drive
end

---@param dt number
function Race:AfterStep(dt)
    if not self.stepOpen then return end
    self.stepOpen = false
    if self.phase == "countdown" then
        if self.countdown <= 1e-8 then
            self.countdown, self.phase = 0, "racing"
            self:Emit("start")
        end
        return
    end
    if self.phase ~= "racing" or not finite(dt) or dt <= 0 then return end
    local frameStart = self.elapsed
    self.elapsed = frameStart + dt
    self:TrackPlayer(dt)
    if self.sim.impactSerial ~= self.lastImpact then
        self:Collision(self.player)
        self.player.immunity = max(self.player.immunity, 2)
        self.lastImpact = self.sim.impactSerial
        self:Emit("contact", "player")
    end
    -- World has updated its LIVE traffic before sim:Step; snapshot once, then plan all AI.
    -- 惰性加载：真实运行时才需要。受限验收环境可能没有该模块，降级为空实现。
    local prof = Race.FrameProfile
    if not prof then
        local ok, module = pcall(function() return require("RaceFrameProfile") end)
        prof = ok and type(module) == "table" and module.Begin and module
            or {Begin = function() end, End = function() end, Tick = function() end}
        Race.FrameProfile = prof
    end
    prof.Begin("snapshot")
    RaceAI.Snapshot(self)
    prof.End()
    -- 对手AI基于dt而不是固定物理步：每帧只跑一次。
    -- 原来慢帧会被拆成最多4个内部步，每步都重跑8车完整决策，
    -- 使aiUpdate从14ms膨胀到56ms——这正是帧越卡越卡的主因。
    local aiDt = min(dt, 0.08)
    self.elapsed = frameStart + aiDt
    prof.Begin("aiUpdate")
    for _, r in ipairs(self.racers) do self:UpdateAI(r, aiDt) end
    prof.End()
    prof.Begin("rank")
    self:Rank()
    prof.End()
    prof.Begin("pursuit")
    self:UpdatePursuit(aiDt)
    prof.End()
    for _, r in ipairs(self.racers) do
        r.hitTimer = max(0, (r.hitTimer or 0) - dt)
        if r.hitTimer <= 0 then r.hitShake, r.hitYaw = 0, 0 end
        -- 命中翻滚计时递减，视觉层据此衰减。
        r.tumble = max(0, (r.tumble or 0) - dt)
        r.boostTimer = max(0, r.boostTimer - dt)
        if r.boostTimer < 1e-8 then r.boostTimer = 0 end
    end
    if self.player.boostTimer <= 0 then self.sim.raceBoost = 0 end
    prof.Begin("contacts")
    self:Contacts(dt)
    prof.End()
    prof.Begin("raceStep")
    MixedRace.RaceStep(self,dt)
    prof.End()
    self:Rank()
    self:Mirror()
    if self.player.eliminated then self:Settle("保持末位且近距离追逐连续6秒，已被公平截停")
    elseif self.player.finished then self:Settle("全部顺序检查点及正向终点线已通过") end
end

function Race:GetState()
    return {phase = self.phase, countdown = self.countdown, elapsed = self.elapsed, laps = self.laps,
        racers = self.racers, player = self.player, pursuit = self.pursuit, ranking = self.ranking,
        standings = self.standings, results = self.results, result = self.result}
end

-- Pure Lua tests below use a circular injected map and the real driving module.
function Race.Test()
    local Sim = require("Simulation")
    local checks = 0
    local function check(ok, name) assert(ok, "[Race.Test] " .. name); checks = checks + 1 end
    local radius = 120
    local length = radius * math.pi * 2
    local map = {RouteLength = length, Goals = {}, SpawnLaneOffset = 0}
    map.RoadPoint = function(s)
        local t = s / radius
        return {x = radius * (1 - math.cos(t)), y = 0, z = radius * math.sin(t)}, t * DEG
    end
    map.Height = function() return 0, true end
    map.NearestRoad = function(x, z)
        local t = math.atan(z, radius - x)
        return (t * radius) % length, sqrt((x - radius)^2 + z*z) - radius
    end
    local sim = Sim.New(map)
    local race = Race.New(map, sim, {seed = 31, quiet = true})
    local function tick(seconds, controls, move)
        local n = max(1, math.floor(seconds / 0.02 + 0.5))
        for _ = 1, n do
            local drive = race:BeforeStep(0.02, controls or {})
            if race.phase == "racing" and move then sim:Step(0.02, drive) end
            race:AfterStep(0.02)
        end
    end
    local function moveTo(s, speed, dt)
        local r = race.player
        race:BeforeStep(dt or 0.02, {})
        local p, yaw = race:Pose(s, 1.55)
        sim.x, sim.y, sim.z, sim.yaw, sim.heading, sim.speed = p.x, p.y, p.z, yaw, yaw, speed or 30
        race:AfterStep(dt or 0.02)
    end
    race:Start()
    local x, z, aiS = sim.x, sim.z, race.racers[1].s
    tick(2.98, {throttle = 1, nitro = true}, true)
    check(race.phase == "countdown" and sim.x == x and sim.z == z and sim.elapsed == 0
        and race.racers[1].s == aiS and race.player.nitro == 100, "3秒倒计时冻结全部仿真与资源")
    tick(0.02, {throttle = 1}, true)
    check(race.phase == "racing" and sim.elapsed == 0 and race.elapsed == 0, "最后倒计时步不偷跑")
    check(#race.racers == 9 and race.laps == 2, "玩家+8独立AI及默认2圈")
    tick(24, {}, false)
    check(not race.player.eliminated and race.pursuit.state == "protection", "开局25秒保护")
    tick(3, {}, false)
    sim.speed, sim.crashCooldown = 30, 0
    sim:Impact("测试轻撞", 8)
    tick(0.02, {}, false)
    check(sim.speed >= 16.5 and sim.speed <= 21.6 and not sim.wrecked and not sim.finished
        and race.player.collisionGraceUntil > race.elapsed + 5.9 and not race.player.eliminated, "轻撞保留55..72%动量并给6秒宽限")
    tick(4, {}, false)
    check(not race.player.eliminated, "轻撞宽限内不抓")
    tick(85, {}, false)
    check(race.player.eliminated and race.phase == "finished", "长停最终必抓且稳定结算")
    local result, elapsed, eventSeq = race.results, race.elapsed, race.eventSeq
    tick(3, {}, true)
    check(race.results == result and race.elapsed == elapsed and race.eventSeq == eventSeq, "结算幂等且冻结排名")
    race:Reset(sim, 1)
    check(race.phase == "countdown" and race.laps == 1 and not race.player.eliminated
        and race.player.nitro == 100 and race.elapsed == 0 and #race.results == 0, "重置完整清状态并支持1圈")
    tick(3, {}, false)
    -- Disable autonomous actors only inside tests, to isolate gate validation from pursuit/combat.
    for _, r in ipairs(race.racers) do if not r.isPlayer then r.finished = true; r.finishTime = 10000 end end
    local previous = race.player.progress
    moveTo(200, 0)
    check(race.player.progress <= previous and not race.player.started and race.player.invalidMoves > 0, "高速瞬移不跳检查点")
    local trusted = race.player.progress
    sim.x, sim.z = 1000, 1000
    sim:Recover(nil)
    local recoveredSerial = sim.recoverySerial
    tick(0.02, {}, false)
    check(race.player.progress <= trusted + 0.01 and race.player.completedLaps == 0
        and sim.recoverySerial == recoveredSerial, "引擎脱困不授予前向里程且不二次瞬移")
    race:HandleInput("recover")
    local danger = 2
    race.player.danger = danger
    race:HandleInput("recover")
    check(race.player.danger == danger, "重复脱困保留危险值")
    race.elapsed, race.player.protectionUntil = 40, 0
    race:Collision(race.player)
    local graceUntil = race.player.collisionGraceUntil
    race.elapsed = 41
    race:Collision(race.player)
    check(race.player.collisionGraceUntil == graceUntil, "停驶反复轻撞不能续宽限")
    race.elapsed = 0 -- isolated gate tests below are not pursuit timing tests.
    local r = race.player
    local legalS = r.s
    race:BeforeStep(0.02, {})
    local shoulder = race:Pose(legalS + 0.5, race.corridor + 2)
    sim.x, sim.y, sim.z, sim.speed = shoulder.x, shoulder.y, shoulder.z, 30
    race:AfterStep(0.02)
    check(race.player.progress <= legalS + 0.01 and race.player.completedLaps == 0,
        "离开主路走廊切线不能获得里程或检查点")
    race:RecoverPlayer(false)
    -- Drive in short legal physical segments; all finish awards must use ordered crossing planes.
    local s = race.player.s
    for _ = 1, 100 do s = s - 0.5; moveTo(s, 30) end
    check(race.player.completedLaps == 0 and race.player.wrongWay, "逆行不记圈")
    for _ = 1, 1800 do
        if race.phase == "finished" then break end
        s = s + 0.6
        moveTo(s, 30)
    end
    check(race.player.finished and race.player.completedLaps == 1 and race.phase == "finished", "1圈所有检查点及正向过线完成")
    check(race.results[1].isPlayer and race.result and race.result.position == 1, "按有效进度/过线时间排名")
    for requestedLaps = 2, 3 do
        race:Start(requestedLaps)
        tick(3, {}, false)
        for _, opponent in ipairs(race.racers) do
            if not opponent.isPlayer then opponent.finished, opponent.finishTime = true, 10000 end
        end
        local routeS = race.player.s
        for _ = 1, math.ceil((requestedLaps * length + 40) / 1.2) do
            if race.phase == "finished" then break end
            routeS = routeS + 1.2
            moveTo(routeS, 60)
        end
        check(race.player.finished and race.player.completedLaps == requestedLaps,
            tostring(requestedLaps) .. "圈必须实际完整通过对应圈数")
    end
    race:Start(1)
    tick(3, {}, false)
    for _, opponent in ipairs(race.racers) do
        if not opponent.isPlayer then opponent.finished, opponent.finishTime = true, 10000 end
    end
    local startS = race.player.s
    race:RecoverPlayer(false)
    check(abs(race.player.s - startS) < 1 and race.player.s < 0, "起跑脱困保持负圈域，不跳到圈末")
    local recoveredS = race.player.s
    for _ = 1, 40 do recoveredS = recoveredS + 1.2; moveTo(recoveredS, 60) end
    check(race.player.started and race.player.completedLaps == 0 and not race.player.finished,
        "起跑脱困后短程前进不能凭空完成一圈")
    for _ = 1, math.ceil(length / 1.2) do
        if race.phase == "finished" then break end
        recoveredS = recoveredS + 1.2; moveTo(recoveredS, 60)
    end
    check(race.player.finished and race.player.completedLaps == 1, "脱困后仍能真实完整完成比赛")
    race:Start(3)
    tick(3, {}, false)
    check(race.laps == 3 and race.player.completedLaps == 0, "支持3圈并重置圈数")
    local victim = race:Last()
    check(not victim.isPlayer, "AI也能成为末位")
    for _, opponent in ipairs(race.racers) do opponent.protectionUntil = 0 end
    race.elapsed, victim.lastTime = 40, 8
    local pp = race:Pose(victim.s - 5, 0)
    race.pursuit.s, race.pursuit.x, race.pursuit.y, race.pursuit.z = victim.s - 5, pp.x, pp.y, pp.z
    for _ = 1, 299 do race.elapsed = race.elapsed + 0.02; race:UpdatePursuit(0.02) end
    check(not victim.eliminated and victim.closeHold > 5.9, "AI也必须接近连续满6秒，不能瞬抓")
    race.elapsed = race.elapsed + 0.02
    race:UpdatePursuit(0.02)
    local nextLast = race:Last()
    check(victim.eliminated and not nextLast.eliminated and nextLast.protectionUntil >= race.elapsed + 10
        and race.phase == "racing", "AI淘汰后换目标并保护10秒，不提前结算玩家")
    local a, b = race.player, race.racers[4]
    a.speed, b.speed, a.yaw, b.yaw = 30, 30, 0, 0
    a.x, a.y, a.z, b.x, b.y, b.z = 0, 0, 0, 1.5, 0, 2.9
    check(not race:Shove(a) and b.speed == 30 and b.immunity == 0, "本版已移除主动肘击，对手不会被推撞")
    sim.speed, sim.braking = 20, false
    check(race:Boost(a) and a.nitro == 55 and a.boostTimer == 2.5, "氮气耗45资源持续2.5秒")
    check(not race:Boost(a), "加速不能叠加")
    local held = {throttle = 1, boost = 100}
    local drive = race:BeforeStep(0.02, held)
    check(held.boost == 100 and drive.boost == 1, "输入不被修改且boost受资源授权")
    race:AfterStep(0.02)
    race.options.professional=true
    race.player.eliminated=false
    race.pursuit.active=true
    race:UpdatePursuit(120)
    check(not race.pursuit.active and not race.player.eliminated and race.pursuit.state=="closed_course",
        "职业封闭赛道禁用追逐淘汰，不改变独立追逐规则")
    race:Stop()
    check(not sim.raceMode and race.phase == "idle", "退出释放旧自由驾驶")
    -- Spatial projection tolerances must also survive a narrow hairpin (not just a circle).
    local map2 = {RouteLength = length, Goals = {}, SpawnLaneOffset = 0,
        Height = map.Height, NearestRoad = map.NearestRoad,
        RoadPoint = function(s)
            local t = s / radius
            local x, z = radius * (1 - math.cos(t)), radius * math.sin(t)
            return {x = x, y = 0, z = z}, t * DEG
        end}
    local fine = Race.New(map2, Sim.New(map2), {quiet = true})
    local p0 = fine:Pose(50, 3)
    local p1 = fine:Pose(50.6, 3)
    local projected0 = fine:Project(p0.x, p0.z)
    local projected1 = fine:Project(p1.x, p1.z)
    check(abs(projected1 - projected0 - 0.6) < 0.05, "细分路线投影在车道偏置下连续")

    -- Ordered-gate counterexamples are isolated from the long pursuit scenario above.
    -- Fixture only seeds the precondition; every verdict calls production AdvanceGates.
    -- Fixture: both poses are AFTER the missed plane. No kind of gate may be
    -- invented by continuous ground driving; only a real recrossing can release it.
    local gateSim = Sim.New(map)
    local gates = Race.New(map, gateSim, {seed = 31, quiet = true, professional = true})
    local function green(laps)
        gates:Start(laps)
        gates:BeforeStep(3, {})
        gates:AfterStep(3)
        check(gates.phase == "racing", "隔离门测试只消费冻结倒计时")
    end
    green(3)
    local spacing = gates.gateSpacing
    local window = min(8, spacing * .2)
    local function missedGate(gateS, oldS, started, laps)
        local runner = gates.player
        runner.nextGate, runner.started = gateS, started
        runner.completedLaps, runner.finished, runner.missedGates = laps or 0, false, 0
        local beforePose = gates:Pose(oldS, 1.55)
        local afterPose = gates:Pose(oldS + .6, 1.55)
        runner.lastX, runner.lastY, runner.lastZ = beforePose.x, beforePose.y, beforePose.z
        runner.x, runner.y, runner.z = afterPose.x, afterPose.y, afterPose.z
        gates:AdvanceGates(runner, oldS, oldS + .6, .02)
        return runner
    end
    for _, gap in ipairs({window - 1, window + 2, spacing * .25 + 2, spacing + window + 2}) do
        local rejected = missedGate(spacing, spacing + gap, true)
        check(rejected.nextGate == spacing and rejected.missedGates == 0
            and rejected.completedLaps == 0, "普通门不得追补，落后距离=" .. gap)
    end
    local startMiss = missedGate(0, window + 2, false)
    check(startMiss.nextGate == 0 and not startMiss.started and startMiss.missedGates == 0,
        "起点不得追补启动")
    for lapIndex = 1, 3 do
        local finishS = lapIndex * length
        local finishMiss = missedGate(finishS, finishS + window + 2, true, lapIndex - 1)
        check(finishMiss.nextGate == finishS and finishMiss.completedLaps == lapIndex - 1
            and finishMiss.missedGates == 0 and not finishMiss.finished,
            "绝对圈域终点不得追补：" .. lapIndex)
    end

    -- TrackPlayer integration: no gate fields are edited after seeding this missed-finish
    -- precondition. Off-road and re-entry must not consume finish; reverse then REAL
    -- forward crossing is the only way out. Poses are bounded explicit map fixtures,
    -- not a claim about Simulation.Step's throttle/steering dynamics.
    green(3)
    local function seed(signedS, lane, nextGate, completed)
        local runner = gates.player
        local pose, yaw = gates:Pose(signedS, lane)
        runner.s, runner.progress, runner.safeS = signedS, signedS, signedS
        runner.nextGate, runner.started, runner.completedLaps = nextGate, true, completed
        runner.lap, runner.finished, runner.eliminated = completed + 1, false, false
        runner.lastX, runner.lastY, runner.lastZ = pose.x, pose.y, pose.z
        runner.x, runner.y, runner.z = pose.x, pose.y, pose.z
        runner.offCourseLast = abs(lane) > gates.corridor
        gateSim.x, gateSim.y, gateSim.z, gateSim.yaw, gateSim.heading = pose.x, pose.y, pose.z, yaw, yaw
        gateSim.speed = 60
        gates.lastRecovery, gates.lastPlayerSpeed = gateSim.recoverySerial, 60
    end
    local function track(signedS, lane, dt)
        local pose, yaw = gates:Pose(signedS, lane or 1.55)
        gateSim.x, gateSim.y, gateSim.z, gateSim.yaw, gateSim.heading = pose.x, pose.y, pose.z, yaw, yaw
        gateSim.speed = 60
        gates.elapsed = gates.elapsed + (dt or .02)
        gates:TrackPlayer(dt or .02)
    end
    seed(length - 2, gates.gateCorridor + 2, length, 0)
    track(length + 2, gates.gateCorridor + 2, .1)
    check(gates.player.offCourse and gates.player.nextGate == length
        and gates.player.completedLaps == 0, "离轨越过终点外侧不吞终点门")
    track(length + 2, 1.55, .15)
    check(not gates.player.offCourse and gates.player.nextGate == length
        and gates.player.completedLaps == 0, "终点后回轨首步不追补终点")
    track(length + window + 2, 1.55, .2)
    track(length + window + 2.6)
    check(gates.player.nextGate == length and gates.player.completedLaps == 0
        and not gates.player.finished and (gates.player.missedGates or 0) == 0,
        "回轨后连续正常步骤也不能用相邻普通门追补吞掉终点")
    local cursor = length + window + 2.6
    while cursor > length - 2 do cursor = max(length - 2, cursor - .6); track(cursor) end
    check(gates.player.wrongWay and gates.player.nextGate == length
        and gates.player.completedLaps == 0, "逆向跨过未通过终点不授圈")
    while cursor < length + 2 do cursor = min(length + 2, cursor + .6); track(cursor) end
    check(gates.player.completedLaps == 1 and gates.player.nextGate > length
        and not gates.player.finished, "漏终点必须折返后正向真实过线才记首圈")

    -- Earn all laps from the negative grid domain. The second/third-lap recovery and
    -- backwards line crossings never seed completedLaps/nextGate, so modulo unwrap
    -- regressions cannot be hidden by repairing the fixture after each operation.
    green(3)
    local travelledS = gates.player.s
    local trackSteps = 0
    local function driveTo(goal)
        local forward = goal >= travelledS
        while abs(goal - travelledS) > .000001 and not gates.player.finished do
            travelledS = forward and min(goal, travelledS + 1.2) or max(goal, travelledS - 1.2)
            track(travelledS)
            trackSteps = trackSteps + 1
            assert(trackSteps < 2400, "[Race.Test] 多圈脱困反证超过有限步数预算")
        end
    end
    for lapIndex = 2, 3 do
        local lapStart = (lapIndex - 1) * length
        driveTo(lapStart + spacing * .55)
        check(gates.player.completedLaps == lapIndex - 1 and gates.player.started
            and gates.player.nextGate > lapStart and gates.player.nextGate < lapStart + length,
            "实际逐门行驶进入绝对第" .. lapIndex .. "圈")
        for repeatIndex = 1, 3 do
            local runner = gates.player
            local beforeS, beforeProgress, beforeGate = runner.s, runner.progress, runner.nextGate
            local serial = gateSim.recoverySerial
            check(gates:RecoverPlayer(false), "第" .. lapIndex .. "圈允许真实RecoverPlayer")
            check(gateSim.recoverySerial == serial + 1 and runner.completedLaps == lapIndex - 1
                and runner.nextGate == beforeGate and runner.s >= lapStart and runner.s < lapStart + length
                and abs(runner.s - beforeS) < 1 and runner.s <= beforeGate - .5
                and runner.progress <= beforeProgress and not runner.finished,
                "连续脱困保持圈域/未过门/可信进度：" .. lapIndex .. "/" .. repeatIndex)
            travelledS = runner.s
        end
        local nextGate = gates.player.nextGate
        driveTo(lapStart - 2)
        check(gates.player.wrongWay and gates.player.completedLaps == lapIndex - 1
            and gates.player.nextGate == nextGate and not gates.player.finished,
            "脱困后反向跨上圈终点不能减圈/重记圈：" .. lapIndex)
        driveTo(lapStart + 2)
        check(not gates.player.wrongWay and gates.player.completedLaps == lapIndex - 1
            and gates.player.nextGate == nextGate, "再次正向跨已通过线不得刷圈：" .. lapIndex)
    end
    driveTo(3 * length + 2)
    check(gates.player.finished and gates.player.completedLaps == 3
        and abs(gates.player.progress - 3 * length) < .000001,
        "多圈连续脱困及反向过线后仍须逐门完成第三圈")
    print(string.format("[Race.Test] %d项纯Lua竞速断言通过", checks))
    return true
end

-- Full regression entry; pure rules plus real Simulation.Step laps/flight matrix.
-- Kept in an existing Race test module to keep the gameplay module below 1500 lines.
function Race.RunChecks()
    assert(Race.Test())
    local checks = require("RaceSettlementChecks") --[[@as RaceSettlementCheckSuite]]
    return checks.RunGates()
end

return Race
