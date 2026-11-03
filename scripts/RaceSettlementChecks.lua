-- 真实main业务接线短验收，不是完整实赛/UI/渲染验收。
-- main源码原样执行于局部_ENV，仅追加局部状态访问桥；不复制奖励/广告结算算法。
-- Profile文件与Career.Store均局部内存隔离，SDK仅局部桩；Start/比赛驾驶/Scene均不执行。
---@class RaceSettlementCheckSuite
---@field RunGates fun():table
local Checks = {}

local function source(name)
    local file = assert(cache:GetFile(name), "[RaceSettlementChecks] 缺少源码 " .. name)
    local lines = {}
    while not file:IsEof() do lines[#lines + 1] = file:ReadLine() end
    file:Dispose()
    return table.concat(lines, "\n")
end

local BRIDGE = [[
return {
    prepare = function(f)
        sim_,race_,hud_,bike_,sound_=f.sim,f.race,f.hud,f.bike,f.sound
        touch_=f.touch
        screen_,selectedTrack_,selectedLaps_="ride","lake",Tracks.Get("lake").laps
        ready_,pendingChallenge_,resultShown_=true,true,false
        careerMode_,careerRace_,careerRaceId_=false,f.career==true,f.careerId or ""
        accumulator_,profileRetrySeconds_=0,0
        portrait_=false
    end,
    tick = function(dt) HandleUpdate("Update", {GetFloat=function() return dt end}) end,
    watch = WatchResultAdBonus,
    screen = SetScreen,
    inspect = function()
        return {screen=screen_,shown=resultShown_,earned=sim_.coinsEarned,
            available=resultAdAvailable_,claimed=resultAdClaimed_}
    end,
}
]]

function Checks.Run()
    local mainSource, profileSource, adSource = source("main.lua"), source("Profile.lua"), source("RewardedAds.lua")
    local Store, Progress = require("Career.Store"), require("Career.Progression")
    local Tracks, Config = require("Tracks"), require("Career.Config")
    local lake = assert(Tracks.Get("lake"))
    -- Independent champion oracle: full per-lap reward, NOT Profile.RaceReward.
    local expectedReward = lake.laps * lake.reward
    local startingCoins = 2300
    local afterRace, afterAd = startingCoins + expectedReward, startingCoins + expectedReward * 2
    local assertions, sdkCalls, cloudCalls = 0, 0, 0
    local function check(value, message)
        assert(value, "[RaceSettlementChecks] " .. message)
        assertions = assertions + 1
    end
    local function forbidden() error("[RaceSettlementChecks] 禁止访问真实文件/SDK/云/场景", 2) end
    local function noCloud() cloudCalls = cloudCalls + 1; forbidden() end
    local function noop() end
    local function make(coins)
        local files, callbacks, logs = {}, {}, {}
        local failWrite, writes, rewardCalls, grantCalls = false, 0, 0, 0
        local path = "pursuit_profile.txt"
        local initial = "version=1\ncoins=" .. tostring(coins or 2300)
            .. "\nvehicle=sport\nrider=green\ntrack=circuit,lake\n"
        files[path] = initial
        local function safePath(name)
            check(name == path or name == path .. ".pending" or name == path .. ".backup", "Profile只访问允许的局部路径")
        end
        local fileSystemStub = {
            FileExists = function(_, name) safePath(name); return files[name] ~= nil end,
            Copy = function(_, from, to) safePath(from); safePath(to); files[to] = files[from]; return true end,
            Rename = function(_, from, to) safePath(from); safePath(to); files[to], files[from] = files[from], nil; return true end,
            Delete = function(_, name) safePath(name); files[name] = nil; return true end,
        }
        local profileEnv = setmetatable({fileSystem = fileSystemStub, sdk = {ShowRewardVideoAd = forbidden},
            File = function(name, mode)
                safePath(name)
                local opened = mode == FILE_WRITE or files[name] ~= nil
                if mode == FILE_WRITE then files[name] = "" end
                return {IsOpen = function() return opened end,
                    ReadString = function() return files[name] or "" end,
                    WriteString = function(_, text)
                        writes = writes + 1
                        if failWrite then files[name] = text:sub(1, 10); return false end
                        files[name] = text; return true
                    end, Flush = noop, Close = noop, Dispose = noop}
            end}, {__index = _G})
        local function freshProfile()
            return assert(load(profileSource, "@Profile.lua（主接线内存隔离）", "t", profileEnv))()
        end
        local profile = freshProfile()
        local realGrant, realAdd = profile.GrantRaceRewards, profile.AddCoins
        profile.GrantRaceRewards = function(...)
            grantCalls = grantCalls + 1
            return realGrant(...)
        end
        profile.AddCoins = function(...)
            rewardCalls = rewardCalls + 1
            return realAdd(...)
        end
        local ads = assert(load(adSource, "@RewardedAds.lua（主接线内存隔离）", "t", setmetatable({
            sdk = {ShowRewardVideoAd = function(_, callback)
                sdkCalls = sdkCalls + 1; callbacks[#callbacks + 1] = callback; return true
            end}, print = function(message) logs[#logs + 1] = message end,
            File = forbidden, fileSystem = {FileExists = forbidden},
        }, {__index = _G})))()
        local hud = {screen = "ride", offers = {}, notices = {}, resultText = "", results = 0, refreshes = 0,
            SetScreen = function(self, screen) self.screen = screen end,
            IsModalOpen = function() return false end,
            SetResultAdOffer = function(self, available, busy) self.offers[#self.offers + 1] = {available = available, busy = busy} end,
            SetResultReward = function(self, text) self.resultText = text end,
            ShowNotice = function(self, title, text) self.notices[#self.notices + 1] = {title = title, text = text} end,
            ShowResult = function(self) self.results = self.results + 1 end,
            RefreshOwnership = function(self) self.refreshes = self.refreshes + 1 end,
            UpdateLayout = noop, Update = noop}
        local touch = {ConsumeActions = function() return {} end, Reset = noop}
        local modules = {Profile = profile, RewardedAds = ads, Tracks = Tracks,
            ["Career.Store"] = Store, ["Career.Progression"] = Progress,
            Simulation = {New = function() return {} end}, MobileControls = {New = function() return touch end}}
        -- main未启动：其余依赖只读占位，访问未知方法仍会报错，不以自动noop掩盖业务越界。
        for _, name in ipairs({"urhox-libs/UI", "urhox-libs.Camera.ThirdPersonCamera", "World", "Landscape", "VehicleAssets",
            "Bike", "Rider", "HUD", "RideAudio", "RideLoader", "Catalog", "Race", "RaceVisuals", "RaceAudio", "Career.Session",
            "Career.AdaptiveQuality"}) do
            modules[name] = {}
        end
        local env = setmetatable({require = function(name)
            return assert(modules[name], "主接线验收禁止额外require " .. name)
        end, print = function(message) logs[#logs + 1] = message end,
            graphics = {GetWidth = function() return 1280 end, GetHeight = function() return 720 end},
            input = {GetKeyPress = function() return false end, GetKeyDown = function() return false end},
            sdk = {ShowRewardVideoAd = forbidden}, File = forbidden, fileSystem = {FileExists = forbidden},
            Scene = forbidden, SubscribeToEvent = forbidden, engine = {Exit = forbidden},
        }, {__index = _G})
        local bridge = assert(load(mainSource .. "\n" .. BRIDGE, "@main.lua（真实主接线隔离）", "t", env))()
        local fixture = {sim = {finished = true, coinsEarned = 0}, race = {phase = "finished", player = {rank = 1, finished = true}},
            hud = hud, touch = touch, bike = {UpdateState = noop}, sound = {Update = noop}}
        bridge.prepare(fixture)
        return {main = bridge, profile = profile, fresh = freshProfile, files = files, initial = initial,
            callbacks = callbacks, hud = hud, fixture = fixture, ads = ads, logs = logs,
            fail = function(value) failWrite = value end,
            counts = function() return writes, grantCalls, rewardCalls end}
    end
    local function persisted(f, expected)
        local reloaded = f.fresh()
        check(reloaded.Coins() == expected and reloaded.TrackUnlocked("alpine") and reloaded.TrackUnlocked("coast"),
            "新Profile实例必须同时重读正确金币及lake的两个后继赛道")
    end
    local careerFiles = {}
    Store.WithTestStorage({read = function(path) return careerFiles[path], nil, careerFiles[path] == nil end,
        write = function(path, text) careerFiles[path] = text; return true end,
        cloud = {Get = noCloud, Set = noCloud}}, function()
        check(Store.NewCareer(), "局部Store新档初始化")
        local initialCash = Store.Get().cashCents
        local f = make()
        f.main.tick(0)
        local state = f.main.inspect()
        check(state.shown and state.screen == "result" and state.earned == expectedReward and state.available,
            "真实HandleUpdate按lake配置的圈数与基础奖励结算且提供广告")
        check(f.profile.Coins() == afterRace and not f.profile.HasPendingSave(), "夺冠金币准确入账laps*base且无待补存")
        persisted(f, afterRace)
        local writes, grants = f.counts()
        f.main.tick(0); f.main.tick(.1)
        local afterWrites, afterGrants = f.counts()
        check(grants == 1 and afterGrants == 1 and afterWrites == writes and f.hud.results == 1,
            "真实主循环resultShown门闩阻止重复金币、权益和结果展示")
        check(Store.Get().cashCents == initialCash, "独立赛事不得污染Career现金")
        print(string.format("[主结算接线] lake夺冠 +%d金币（%d圈*%d）；alpine/coast同时持久化；重复Update仅一次",
            expectedReward, lake.laps, lake.reward))

        -- 实际WatchResultAdBonus -> 实际RewardedAds -> 实际Profile.AddCoins。
        local beforeCalls = sdkCalls
        f.main.watch(); f.main.watch()
        check(sdkCalls == beforeCalls + 1 and #f.callbacks == 1, "真实广告入口连点仅一次局部SDK请求")
        f.callbacks[1]({success = true}); f.callbacks[1]({success = true})
        state = f.main.inspect()
        check(f.profile.Coins() == afterAd and state.claimed and not state.available, "主广告成功只补发本场同额金币一次")
        persisted(f, afterAd)
        local _, _, addCalls = f.counts()
        check(addCalls == 1, "重复SDK回调不能二次执行主方AddCoins")
        check(Store.Get().cashCents == initialCash, "独立广告金币不得流入生涯")

        -- 广告奖励写失败仍只领一次；必须根据本次applied，而不是保存返回值标记领取。
        f = make(); f.main.tick(0); f.main.watch(); f.fail(true)
        f.callbacks[1]({success = true}); f.callbacks[1]({success = true})
        state = f.main.inspect()
        check(state.claimed and not state.available and f.profile.HasPendingSave() and f.profile.Coins() == afterAd,
            "广告本次applied=true且写失败必须标记已领、保留待补存")
        f.fail(false)
        for _ = 1, 52 do f.main.tick(.1) end
        local _, _, adAdds = f.counts()
        check(adAdds == 1 and not f.profile.HasPendingSave(), "广告待补存由主循环重试，不再次发币或播放")
        persisted(f, afterAd)

        -- 旧pending绝不是本次已应用凭证：首奖刚好填满上限，广告新增必须永久拒发。
        f = make(math.maxinteger - expectedReward); f.fail(true); f.main.tick(0)
        check(f.profile.Coins() == math.maxinteger and f.profile.HasPendingSave(), "先建立真实赛事旧pending且余额达到上限")
        f.main.watch(); f.callbacks[1]({success = true})
        state = f.main.inspect()
        check(not state.claimed and not state.available and f.profile.Coins() == math.maxinteger and f.profile.HasPendingSave(),
            "预存pending不能把广告上限拒发伪造为已领取")
        check(f.hud.notices[#f.hud.notices].title == "奖励未入账" and not f.hud.resultText:find("广告额外", 1, true),
            "旧pending场景主方必须展示广告未入账，不宣称广告奖励待保存")
        local rejectedAdText=f.hud.resultText
        f.fail(false)
        for _ = 1, 52 do f.main.tick(.1) end
        persisted(f, math.maxinteger)
        check(not f.profile.HasPendingSave(), "只补原场金币权益，广告拒发不污染pending")
        check(f.hud.resultText==rejectedAdText,"旧奖励补存不能把本次广告拒发改写为奖励已保存")
        print("[主结算接线] 广告applied=true写失败仅补存；旧pending+上限applied=false不得标记已领")

        -- 跨赛事保留旧pending，再由真实主循环拒发新奖励；即时提示与旧补存完成都不能冒领。
        f = make(math.maxinteger - expectedReward); f.fail(true); f.main.tick(0)
        check(f.profile.HasPendingSave() and f.profile.Coins()==math.maxinteger,"首场建立已应用待补存奖励")
        f.main.screen("menu")
        f.main.prepare(f.fixture);f.main.tick(0)
        state=f.main.inspect()
        check(state.earned==0 and not state.available and f.profile.HasPendingSave(),"第二场上限拒发不继承首场奖励状态")
        check(f.hud.resultText:find("本次奖励未入账",1,true) and not f.hud.resultText:find("待保存",1,true),
            "已有旧pending时本次永久拒发仍须明确未入账")
        local rejectedRaceText=f.hud.resultText
        f.fail(false)
        for _=1,52 do f.main.tick(.1) end
        check(not f.profile.HasPendingSave() and f.hud.resultText==rejectedRaceText,
            "只补首场存档，不把第二场拒发覆盖为奖励已保存")
        persisted(f,math.maxinteger)
        print("[主结算接线] 跨场旧pending+本场拒发：即时与5秒补存后均保持未入账")

        -- 写失败已应用：通过真实HandleUpdate的5秒补存分支，而非测试手工调用Retry。
        f = make(); f.fail(true); f.main.tick(0)
        state = f.main.inspect()
        check(state.earned == expectedReward and f.profile.Coins() == afterRace and f.profile.HasPendingSave()
            and f.profile.TrackUnlocked("alpine") and f.profile.TrackUnlocked("coast"), "写失败applied=true仍同时保留金币权益")
        check(f.files["pursuit_profile.txt"] == f.initial and f.hud.resultText:find("待保存", 1, true), "写失败主档保留且主方提示待保存")
        f.fail(false)
        for _ = 1, 52 do f.main.tick(.1) end
        local _, countGrants = f.counts()
        check(countGrants == 1 and f.profile.Coins() == afterRace and not f.profile.HasPendingSave(), "真实5秒补存不再次GrantRaceRewards")
        check(f.hud.resultText:find("已保存", 1, true), "主方补存成功更新结果提示")
        persisted(f, afterRace)
        print("[主结算接线] 写失败applied=true保留双后继+金币；真实5秒补存仅保存、不双奖")

        -- 永久拒发：上限已满，不能伪造pending、双倍广告或新赛道。
        f = make(math.maxinteger); f.main.tick(0)
        state = f.main.inspect()
        writes, grants = f.counts()
        check(state.earned == 0 and not state.available and not f.profile.HasPendingSave() and writes == 0 and grants == 1,
            "永久拒发applied=false不伪待补存、不提供广告、不写盘")
        check(f.profile.Coins() == math.maxinteger and not f.profile.TrackUnlocked("alpine") and not f.profile.TrackUnlocked("coast")
            and f.files["pursuit_profile.txt"] == f.initial, "奖励溢出拒发不得部分解锁或改原档")
        check(not f.hud.resultText:find("待保存", 1, true), "永久拒发主方提示不得声称已保留奖励")
        beforeCalls = sdkCalls; f.main.watch()
        check(sdkCalls == beforeCalls, "永久拒发不能进入SDK")
        print("[主结算接线] 上限永久拒发：零金币/零解锁/零写盘/无待补存/无广告")

        -- 真正Career.Store/Progress.EnterSeries/SettleRace；仅测试前置资格快照，奖励规则不替换。
        check(Store.Transaction(function(p)
            local funded, message = Store.ApplyCash(p, 995000, "test_seed", "test:race-qualification")
            if not funded then return false, message end
            p.flags.professional = true
            p.ownedMotorcycles.sport = true; p.raceVehicle = "sport"
            return true
        end), "隔离Store提供合法参赛前置")
        check(Progress.EnterSeries(1), "真实Career报名")
        local pending = assert(Store.Get().career).pending
        local beforeCash = Store.Get().cashCents
        f = make(); f.fixture.career = true; f.fixture.careerId = pending.id
        f.main.prepare(f.fixture); f.main.tick(0)
        state = f.main.inspect()
        local careerAfter = Store.Get()
        local careerResult = assert(careerAfter.career)
        writes, grants, addCalls = f.counts()
        check(careerAfter.cashCents == beforeCash + Progress.Series[1].reward and not careerResult.pending
            and careerResult.wins == 1, "主方生涯结算调用真实Progress且现金准确")
        check(state.earned == 0 and not state.available and f.profile.Coins() == 2300 and grants == 0 and addCalls == 0 and writes == 0,
            "生涯结算不得向Profile发金币或提供金币广告")
        check(not f.profile.TrackUnlocked("alpine") and not f.profile.TrackUnlocked("coast"), "生涯夺冠不得开放旧竞速赛道")
        beforeCalls = sdkCalls; f.main.watch(); f.main.tick(0)
        check(sdkCalls == beforeCalls and Store.Get().cashCents == careerAfter.cashCents, "生涯广告及重复帧不得重复结算现金")
        check(Store.Load() and Store.Get().cashCents == careerAfter.cashCents, "生涯现金可在局部存储重读")
        print("[主结算接线] career真实报名结算仅现金+90000分；旧金币/赛道/广告全部隔离")

        -- 主方SetScreen取消并遮断旧广告回调，不只测RewardedAds自身。
        f = make(); f.main.tick(0); f.main.watch()
        local offers, notices = #f.hud.offers, #f.hud.notices
        f.main.screen("menu")
        f.callbacks[1]({success = true})
        check(f.profile.Coins() == afterRace and #f.hud.offers == offers and #f.hud.notices == notices and not f.ads.IsBusy(),
            "真实主方切页Cancel后迟到广告不发币、不操作旧UI")
        check(cloudCalls == 0, "全程零真实或桩云请求")
    end)
    print(string.format("[RaceSettlementChecks] PASS %d项；真实main业务接线/局部Profile与Store/局部SDK %d次；未启动实赛或真实UI", assertions, sdkCalls))
    return {passed = true, assertions = assertions}
end
-- Production circuit/e-bike gate regression. This uses Landscape's real sampled
-- road and Simulation's real vehicle dimensions, but no Scene, HUD, Profile or
-- save path. It is intentionally separate from the synthetic circular sweep tests.
function Checks.RunCircuitGates()
    local Race, Sim, Landscape = require("Race"), require("Simulation"), require("Landscape")
    local previousTrack = Landscape.activeId
    local assertions = 0
    local function check(ok, message)
        assert(ok, "[Race.CircuitGateChecks] " .. message)
        assertions = assertions + 1
    end
    assert(Landscape.SelectTrack("circuit"), "无法选择真实circuit")
    local sim = Sim.New(Landscape)
    check(sim:SetVehicle("ebike"), "真实ebike车型可交付")
    local race = Race.New(Landscape, sim, {quiet = true, professional = true, mixed = true, laps = 2})
    race:Start()
    race:BeforeStep(3, {}); race:AfterStep(3)
    local player = race.player
    check(race.phase == "racing" and player.vehicleId == "ebike", "真实circuit/ebike进入冻结倒计时后的比赛")
    local gate = race.gateSpacing
    local speed = 192 / 3.6
    local dt = 0.04
    local legalLane = race:GateCorridorFor(player) - 0.04
    local illegalLane = race:GateCorridorFor(player) + 0.12
    check(math.abs(legalLane - 16.47) < 0.08 and illegalLane > 16.47,
        string.format("真实有限外侧带为13..16.47m（合法%.3fm/非法%.3fm）", legalLane, illegalLane))
    local function seed(s, lane, nextGate)
        local p, yaw = race:Pose(s, lane)
        local y = Landscape.Height(p.x, p.z)
        player.s, player.progress, player.safeS = s, s, s
        player.nextGate, player.started, player.completedLaps = nextGate, true, 0
        player.finished, player.eliminated, player.missedGate = false, false, false
        player.invalidMoves, player.offCourse = 0, false
        player.x, player.y, player.z = p.x, y, p.z
        player.lastX, player.lastY, player.lastZ = p.x, y, p.z
        sim.x, sim.y, sim.z, sim.heading, sim.yaw, sim.speed = p.x, y, p.z, yaw, yaw, speed
        race.lastPlayerSpeed = speed
    end
    local function cross(lane, from, to)
        local p0, yaw0 = race:Pose(from, lane)
        local p1 = race:Pose(to, lane)
        local y0, y1 = Landscape.Height(p0.x, p0.z), Landscape.Height(p1.x, p1.z)
        player.lastX, player.lastY, player.lastZ = p0.x, y0, p0.z
        sim.x, sim.y, sim.z, sim.heading, sim.yaw, sim.speed = p1.x, y1, p1.z, yaw0, yaw0, speed
        race.elapsed = race.elapsed + dt
        race:TrackPlayer(dt)
    end
    -- Screenshot reproduction: 192km/h crosses checkpoint 2 on the legal
    -- outer runoff, so it must not become a false missed checkpoint/rank 09.
    race.elapsed = 86.63 - dt
    seed(gate - 0.6, legalLane, gate)
    cross(legalLane, gate - 0.6, gate + 0.6)
    check(player.nextGate > gate and not player.missedGate and player.completedLaps == 0,
        "192km/h真实电动车在13..16.47m外侧正向跨检查点2")
    check(player.offCourse == false and player.invalidMoves == 0,
        "合法外侧通过不被标记离轨或非法跳跃")
    for _, other in ipairs(race.racers) do
        if other ~= player then other.progress, other.finished, other.eliminated = -100, false, false end
    end
    race:Rank()
    check(player.rank == 1, "合法外侧正向过门后排名可保持第1，不被错误压到09/09")
    -- Real movement smoke check: start one metre before the gate; subsequent
    -- crossing is produced solely by Sim.Step, not by post-step pose writes.
    seed(gate - 1, 15.0, gate)
    local serial = sim.recoverySerial
    local drive = race:BeforeStep(.02, {throttle = .8})
    sim:Step(.02, drive)
    race:TrackPlayer(.02)
    check(player.nextGate > gate and not player.missedGate and player.invalidMoves == 0
        and sim.recoverySerial == serial, "真实Sim.Step 192km/h外侧通行没有复位/写位置补门")
    -- Projection index must agree with an independent full-road scan at cell
    -- seams and both sides of every physical checkpoint, including the start wrap.
    local samples = race.samples
    local function brute(x, z)
        local best, s = math.huge, 0
        for i = 1, #samples - 1 do
            local a, b = samples[i], samples[i + 1]
            local dx, dz = b.x - a.x, b.z - a.z
            local den = dx * dx + dz * dz
            if den > 1e-8 then
                local t = math.max(0, math.min(1, ((x - a.x) * dx + (z - a.z) * dz) / den))
                local d = (x - a.x - dx * t)^2 + (z - a.z - dz * t)^2
                if d < best then best, s = d, a.s + (b.s - a.s) * t end
            end
        end
        return s % race.length
    end
    for _, checkpoint in ipairs(race.checkpoints) do
        for _, lane in ipairs({-16.4, 0, 16.4}) do
            local p = race:Pose(checkpoint.s + .17, lane)
            local indexed, expected = race:Project(p.x, p.z), brute(p.x, p.z)
            local error = math.abs((indexed - expected + race.length * .5) % race.length - race.length * .5)
            check(error < 1e-6, "真实全路门位投影候选与全扫描一致 " .. checkpoint.index)
        end
    end
    -- Both player and AI consume the same finite sweep/continuity validator.
    local opponent = assert((function()
        for _, candidate in ipairs(race.racers) do
            if not candidate.isPlayer then return candidate end
        end
    end)(), "真实竞速夹具必须包含AI")
    opponent.driveSim = Sim.New(Landscape)
    check(opponent.driveSim:SetVehicle("ebike"), "玩家AI比较使用相同真实车型")
    for _, lane in ipairs({15, illegalLane}) do
        seed(gate - .6, lane, gate)
        local a, b = race:Pose(gate - .6, lane), race:Pose(gate + .6, lane)
        opponent.lastX, opponent.lastY, opponent.lastZ = a.x, Landscape.Height(a.x, a.z), a.z
        opponent.x, opponent.y, opponent.z = b.x, Landscape.Height(b.x, b.z), b.z
        opponent.s, opponent.progress, opponent.safeS = gate + .6, gate - .6, gate - .6
        opponent.speed, opponent.lane = speed, lane
        opponent.nextGate, opponent.started, opponent.completedLaps = gate, true, 0
        opponent.finished, opponent.eliminated, opponent.missedGate, opponent.invalidMoves = false, false, false, 0
        opponent.vehicleId = "ebike"
        race:ValidateProgress(opponent, gate - .6, gate + .6, dt, speed, false)
        cross(lane, gate - .6, gate + .6)
        check(opponent.nextGate == player.nextGate and opponent.missedGate == player.missedGate
            and opponent.completedLaps == player.completedLaps, "玩家AI合法带与抄近路相同判定 " .. lane)
    end
    -- Deliberate shortcut: just beyond the physical centre boundary is rejected,
    -- and a complete loop cannot advance the blocked ordered gate.
    local missedGate = gate * 2
    seed(missedGate - 0.6, illegalLane, missedGate)
    cross(illegalLane, missedGate - 0.6, missedGate + 0.6)
    check(player.nextGate == missedGate and player.missedGate and player.offCourse,
        "16.47m外故意抄近路越过检查点仍漏门并保持待门")
    local cappedProgress = missedGate - .001
    for cursor = missedGate + 1, missedGate + race.length, 1 do
        local s = cursor
        local p, yaw = race:Pose(s, 0)
        player.lastX, player.lastY, player.lastZ = player.x, player.y, player.z
        sim.x, sim.y, sim.z, sim.heading, sim.yaw = p.x, p.y, p.z, yaw, yaw
        race.elapsed = race.elapsed + dt
        race:TrackPlayer(dt)
    end
    check(player.nextGate == missedGate and player.completedLaps == 0 and player.progress <= cappedProgress,
        "故意抄近路绕完整圈不能自动补门或增加有效进度")
    for _, other in ipairs(race.racers) do
        if other ~= player then other.progress = player.progress + 500 end
    end
    race:Rank()
    check(player.rank == #race.racers and player.progress < missedGate,
        "漏门时排名按封顶有效进度显示末位，不能把物理位置冒充完赛")
    -- Reverse crossing is never a gate event, including at the same high speed.
    local reverseGate = missedGate + race.gateSpacing
    seed(reverseGate + 0.6, 0, reverseGate)
    player.missedGate = true
    cross(0, reverseGate + 0.6, reverseGate - 0.6)
    check(player.nextGate == reverseGate and player.completedLaps == 0 and player.missedGate,
        "高速倒车穿过待门不计检查点/圈数")
    check(race:RecoverPlayer(false) and player.nextGate == reverseGate and player.s < reverseGate
        and player.completedLaps == 0 and player.missedGate,
        "漏门复位回到同一待门前，不自动授予门或圈")
    Landscape.SelectTrack(previousTrack)
    print(string.format("[Race.CircuitGateChecks] PASS %d项；真实circuit/ebike 192km/h 外侧/抄近路/排名/倒车/复位", assertions))
    return {passed = true, assertions = assertions}
end

-- Gate-only suite: no main/Profile/Store/SDK or player saves. Synthetic sweeps
-- are labelled separately from laps driven with throttle/brake/steer via Sim.Step.
function Checks.RunGates()
    local Race, Sim, F = require("Race"), require("Simulation"), require("TrackFeatures")
    local report = {passed = false, assertions = 0, laps = {}, flights = {}, boundaries = 0}
    local function check(ok, name)
        assert(ok, "[Race.RunChecks] " .. name)
        report.assertions = report.assertions + 1
    end
    local function circle(radius)
        local length = radius * math.pi * 2
        local map = {RouteLength = length, Goals = {}, SpawnLaneOffset = 0,
            Roads = {{width = 8, shoulder = 10}}, Ramps = {}, Features = {}}
        function map.RoadPoint(s)
            local a = s / radius
            return {x = radius * (1 - math.cos(a)), y = 0, z = radius * math.sin(a)}, math.deg(a)
        end
        function map.NearestRoad(x, z)
            return math.atan(z, radius - x) * radius % length, radius - math.sqrt((x - radius)^2 + z*z)
        end
        function map.RoadHeight() return 0, true end
        function map.RampAt(x, z)
            for _, ramp in ipairs(map.Ramps) do if F.RampHeight(ramp, x, z) then return ramp end end
        end
        function map.Height(x, z)
            local ramp = map.RampAt(x, z)
            return ramp and F.RampHeight(ramp, x, z) or 0, true
        end
        return map
    end
    local function fixture(id, map, laps)
        local sim = Sim.New(map)
        check(sim:SetVehicle(id), "真实车型 " .. id)
        local race = Race.New(map, sim, {quiet = true, professional = true, laps = laps or 1})
        race:Start()
        race:BeforeStep(3, {}); race:AfterStep(3)
        -- Remove opponents only to isolate gates from contacts/pursuit. No rule override.
        race.racers = {race.player}
        return race, sim
    end
    local function steerTo(sim, map, s, lane)
        local look = math.max(10, sim.speed * .65)
        local p, yaw = map.RoadPoint(s + look)
        local a = math.rad(yaw)
        local x, z = p.x + math.cos(a) * lane, p.z - math.sin(a) * lane
        local desired = math.deg(math.atan(x - sim.x, z - sim.z))
        local needed = math.max(-100, math.min(100, ((desired - sim.heading + 180) % 360 - 180) * 2.5))
        local lo, hi = 0, 1
        for _ = 1, 12 do
            local mid = (lo + hi) * .5
            if math.abs(sim:TurnRate(mid)) < math.abs(needed) then lo = mid else hi = mid end
        end
        return (lo + hi) * .5 * (needed < 0 and -1 or 1)
    end
    local function step(race, sim, target, lane)
        local drive = race:BeforeStep(.02, {throttle = sim.speed < target and .8 or 0,
            brake = sim.speed > target + .4, steer = steerTo(sim, race.map, race.player.s, lane or 0)})
        sim:Step(.02, drive)
        race:AfterStep(.02)
    end
    for _, id in ipairs({"helicopter", "ebike", "sport"}) do
        local map = circle(120)
        local race, sim = fixture(id, map)
        local player = race.player
        for _ = 1, 4000 do
            if race.phase == "finished" then break end
            step(race, sim, 30)
        end
        check(player.finished and player.started and player.completedLaps == 1
            and race.phase == "finished" and race.result and race.result.success,
            id .. " 油刹舵真实完整圈及终点结算")
        check(player.invalidMoves == 0 and not player.missedGate and player.missedGates == 0,
            id .. " 不靠瞬移/补门/里程计")
        if id == "helicopter" then check(sim.oddAltitude == 2.5, "直升机视觉悬浮未写入sim.y") end
        local result, time, seq = race.result, race.elapsed, race.eventSeq
        race:BeforeStep(.02, {}); race:AfterStep(.02)
        check(result == race.result and time == race.elapsed and seq == race.eventSeq, "终点结算幂等 " .. id)
        report.laps[#report.laps + 1] = {id = id, time = player.finishTime, s = player.s,
            nextGate = player.nextGate, completedLaps = player.completedLaps, invalidMoves = player.invalidMoves}
        print(string.format("[Race.RunChecks] real-lap %s %.2fs laps=%d invalid=%d", id, player.finishTime,
            player.completedLaps, player.invalidMoves))
    end
    -- Swept-plane boundary fixtures, not fabricated claims of Sim.Step driving.
    for _, id in ipairs({"helicopter", "ebike", "sport"}) do
        local race, sim = fixture(id, circle(120), 3)
        local runner = race.player
        local function seed(s, gate, height, lane, completed)
            local p, yaw = race:Pose(s, lane or 0)
            runner.s, runner.progress, runner.safeS = s, s, s
            runner.nextGate, runner.started, runner.completedLaps = gate, gate > 0, completed or 0
            runner.finished, runner.missedGate = false, false
            runner.x, runner.y, runner.z = p.x, p.y + height, p.z
            runner.lastX, runner.lastY, runner.lastZ = runner.x, runner.y, runner.z
            sim.x, sim.y, sim.z, sim.heading, sim.yaw, sim.speed = runner.x, runner.y, runner.z, yaw, yaw, 30
            race.lastPlayerSpeed = 30
        end
        local function track(s, height, lane)
            local p, yaw = race:Pose(s, lane or 0)
            sim.x, sim.y, sim.z, sim.heading, sim.yaw = p.x, p.y + height, p.z, yaw, yaw
            race.elapsed = race.elapsed + .02
            race:TrackPlayer(.02)
        end
        for _, height in ipairs({3, 3.01, 10, 10.01, -3, -3.01}) do
            local gate = race.gateSpacing
            seed(gate - .3, gate, height)
            track(gate + .3, height)
            local allowed = height >= -Race.Rules.gateBelow and height <= Race.Rules.gateAbove
            check((runner.nextGate > gate) == allowed and runner.completedLaps == 0,
                id .. " 有限高度边界 " .. height)
            check(runner.missedGate == not allowed and runner.offCourse == not allowed,
                id .. " 判门/在轨使用统一飞行高度 " .. height)
            report.boundaries = report.boundaries + 1
        end
        -- Miss an ordinary gate laterally, then finish a whole ground loop. It must
        -- stay blocked AND explain recovery, not silently auto-collect any gate.
        local gate, outside = race.gateSpacing, race.gateCorridor + .2
        seed(gate - .3, gate, 0, outside)
        track(gate + .3, 0, outside)
        check(runner.missedGate and runner.nextGate == gate and sim.message:find("脱困", 1, true),
            id .. " 横向漏门立即提示返回/脱困")
        local cursor, mergeLane = gate + .3, outside
        while mergeLane > 0 do
            cursor, mergeLane = cursor + .3, math.max(0, mergeLane - .2)
            track(cursor, 0, mergeLane)
        end
        for _ = 1, math.ceil(race.length / .6) do cursor = cursor + .6; track(cursor, 0, 0) end
        check(not runner.offCourse and runner.completedLaps == 0 and runner.nextGate == gate and runner.missedGate,
            id .. " 驶完一圈不能自动补门")
        local lapsBefore, gateBefore, serial = runner.completedLaps, runner.nextGate, sim.recoverySerial
        check(race:RecoverPlayer(false), id .. " 漏门脱困可用")
        local centre, yaw = race.map.RoadPoint(gateBefore)
        local forward = (sim.x - centre.x) * math.sin(math.rad(yaw))
            + (sim.z - centre.z) * math.cos(math.rad(yaw))
        check(forward < -1 and runner.s < gateBefore and runner.nextGate == gateBefore
            and runner.completedLaps == lapsBefore and sim.recoverySerial == serial + 1 and runner.missedGate,
            id .. " 脱困安全落在同一待门前，尚未奖励")
        for _ = 1, 300 do
            step(race, sim, 15)
            if not runner.missedGate then break end
        end
        check(not runner.missedGate and runner.nextGate > gateBefore and runner.completedLaps == lapsBefore,
            id .. " 脱困后真实Sim.Step正向穿过待门解除阻断")
        -- Missing START and each absolute FINISH also use recovery, never auto-award.
        for lap = 0, 3 do
            local finish = lap * race.length
            seed(finish - .3, finish, 10.01, 0, math.max(0, lap - 1))
            track(finish + .3, 10.01)
            check(runner.missedGate and runner.nextGate == finish and not runner.finished,
                id .. " 起终点越高拒绝 " .. lap)
            race:RecoverPlayer(false)
            check(runner.nextGate == finish and runner.s < finish and runner.missedGate,
                id .. " 起终点脱困不自动结算 " .. lap)
            for _ = 1, 300 do
                step(race, sim, 15)
                if not runner.missedGate then break end
            end
            check(not runner.missedGate and runner.nextGate > finish
                and runner.completedLaps == lap and runner.finished == (lap == 3),
                id .. " 真实恢复过起终点 " .. lap)
        end
    end
    -- Production F.Make/Sim.TakeOff/gravity/Land, at certified 105m/s; the
    -- plane is near the ballistic apex (>3m), not a manually assigned air pose.
    for _, id in ipairs({"helicopter", "ebike", "sport"}) do
        local map = circle(3000) -- gentle enough that a 105m/s ballistic tangent stays in the finite XZ ribbon
        local race, sim = fixture(id, map)
        local ramp = F.Make(map, race.gateSpacing - 55, 0, "ramp", "race_flight")
        map.Ramps = {ramp}
        local start = ramp.s - 1
        local p, yaw = race:Pose(start, 0)
        local runner = race.player
        runner.s, runner.progress, runner.safeS = start, start, start
        runner.nextGate, runner.started = race.gateSpacing, true
        runner.x, runner.y, runner.z, runner.lastX, runner.lastY, runner.lastZ = p.x, p.y, p.z, p.x, p.y, p.z
        sim.x, sim.y, sim.z, sim.heading, sim.yaw, sim.speed = p.x, p.y, p.z, yaw, yaw, 105
        race.lastPlayerSpeed = 105
        local peak, flew, crossed = 0, false, false
        for _ = 1, 250 do
            -- No position/speed writes after seeding the approach. Coasting conserves
            -- real launch momentum; flight steering is intentionally unavailable.
            local drive = race:BeforeStep(.02, {throttle = 0})
            sim:Step(.02, drive); race:AfterStep(.02)
            peak = math.max(peak, sim.y)
            flew = flew or sim.airborne
            if runner.nextGate > race.gateSpacing then crossed = true end
            if flew and not sim.airborne then break end
        end
        print(string.format("[Race.RunChecks] ramp-state %s flew=%s crossed=%s missed=%s invalid=%d peak=%.3f s=%.3f gate=%.3f",
            id, tostring(flew), tostring(crossed), tostring(runner.missedGate), runner.invalidMoves, peak, runner.s, runner.nextGate))
        check(flew and crossed and not runner.missedGate and runner.invalidMoves == 0,
            id .. " 真坡道弹道穿门不漏站")
        check(peak > 3.01 and peak < Race.Rules.gateAbove and not sim.airborne,
            id .. " 真实峰高大于旧3m上限且在有限10m走廊内并落地")
        report.flights[#report.flights + 1] = {id = id, peak = peak, crossed = crossed,
            nextGate = runner.nextGate, exitGrade = ramp.exitGrade}
        print(string.format("[Race.RunChecks] ramp %s peak=%.3fm grade=%.5f crossed=%s", id, peak,
            ramp.exitGrade, tostring(crossed)))
    end
    -- Audit the REAL six-map downhill ramps at all certified entry speeds.
    -- Reuses production map/triangle surface + Sim gravity, not a flat-road estimate.
    local landscape = require("Landscape")
    local previousTrack = landscape.activeId
    report.realRampCases, report.maxRealRampAltitude = 0, 0
    for _, trackId in ipairs({"circuit", "lake", "alpine", "coast", "canyon", "forest"}) do
        assert(landscape.SelectTrack(trackId))
        for _, ramp in ipairs(landscape.OptionalRamps) do
            for _, speed in ipairs({12, 30, 55, 80, 105}) do
                local sim = Sim.New(landscape)
                local x, z = F.Point(ramp, 0, -1)
                sim.x, sim.z, sim.y, sim.heading, sim.yaw, sim.speed = x, z,
                    landscape.Height(x, z), ramp.yaw, ramp.yaw, speed
                local peak, flew = 0, false
                for _ = 1, 450 do
                    sim:Step(.02, {throttle = 1})
                    local roadS = landscape.NearestRoad(sim.x, sim.z)
                    local road = landscape.RoadPoint(roadS)
                    peak = math.max(peak, sim.y - road.y)
                    flew = flew or sim.airborne
                    if flew and not sim.airborne then break end
                end
                check(flew and not sim.airborne and peak <= Race.Rules.gateAbove,
                    trackId .. " 实坡下坡弹道在10m走廊内 " .. speed)
                report.realRampCases = report.realRampCases + 1
                report.maxRealRampAltitude = math.max(report.maxRealRampAltitude, peak)
            end
        end
    end
    assert(landscape.SelectTrack(previousTrack))
    print(string.format("[Race.RunChecks] actual-map ramp audit %d cases maximum road-relative altitude %.3fm",
        report.realRampCases, report.maxRealRampAltitude))
    report.passed = true
    print(string.format("[Race.RunChecks] PASS %d assertions / %d real laps / %d boundary cases / %d real ramp flights",
        report.assertions, #report.laps, report.boundaries, #report.flights))
    return report
end

return Checks
