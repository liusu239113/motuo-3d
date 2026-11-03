-- 真实main业务接线短验收，不是完整实赛/UI/渲染验收。
-- main源码原样执行于局部_ENV，仅追加局部状态访问桥；不复制奖励/广告结算算法。
-- Profile文件与Career.Store均局部内存隔离，SDK仅局部桩；Start/比赛驾驶/Scene均不执行。
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
            "Bike", "Rider", "HUD", "RideAudio", "RideLoader", "Catalog", "Race", "RaceVisuals", "RaceAudio", "Career.Session"}) do
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
        check(state.shown and state.screen == "result" and state.earned == 102 and state.available,
            "真实HandleUpdate按lake固定3圈34金币结算且提供广告")
        check(f.profile.Coins() == 2402 and not f.profile.HasPendingSave(), "夺冠金币准确入账102且无待补存")
        persisted(f, 2402)
        local writes, grants = f.counts()
        f.main.tick(0); f.main.tick(.1)
        local afterWrites, afterGrants = f.counts()
        check(grants == 1 and afterGrants == 1 and afterWrites == writes and f.hud.results == 1,
            "真实主循环resultShown门闩阻止重复金币、权益和结果展示")
        check(Store.Get().cashCents == initialCash, "独立赛事不得污染Career现金")
        print("[主结算接线] lake夺冠 +102金币；alpine/coast同时持久化；重复Update仅一次")

        -- 实际WatchResultAdBonus -> 实际RewardedAds -> 实际Profile.AddCoins。
        local beforeCalls = sdkCalls
        f.main.watch(); f.main.watch()
        check(sdkCalls == beforeCalls + 1 and #f.callbacks == 1, "真实广告入口连点仅一次局部SDK请求")
        f.callbacks[1]({success = true}); f.callbacks[1]({success = true})
        state = f.main.inspect()
        check(f.profile.Coins() == 2504 and state.claimed and not state.available, "主广告成功只补发本场102金币一次")
        persisted(f, 2504)
        local _, _, addCalls = f.counts()
        check(addCalls == 1, "重复SDK回调不能二次执行主方AddCoins")
        check(Store.Get().cashCents == initialCash, "独立广告金币不得流入生涯")

        -- 广告奖励写失败仍只领一次；必须根据本次applied，而不是保存返回值标记领取。
        f = make(); f.main.tick(0); f.main.watch(); f.fail(true)
        f.callbacks[1]({success = true}); f.callbacks[1]({success = true})
        state = f.main.inspect()
        check(state.claimed and not state.available and f.profile.HasPendingSave() and f.profile.Coins() == 2504,
            "广告本次applied=true且写失败必须标记已领、保留待补存")
        f.fail(false)
        for _ = 1, 52 do f.main.tick(.1) end
        local _, _, adAdds = f.counts()
        check(adAdds == 1 and not f.profile.HasPendingSave(), "广告待补存由主循环重试，不再次发币或播放")
        persisted(f, 2504)

        -- 旧pending绝不是本次已应用凭证：首奖刚好填满上限，广告新增必须永久拒发。
        f = make(math.maxinteger - 102); f.fail(true); f.main.tick(0)
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
        f = make(math.maxinteger - 102); f.fail(true); f.main.tick(0)
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
        check(state.earned == 102 and f.profile.Coins() == 2402 and f.profile.HasPendingSave()
            and f.profile.TrackUnlocked("alpine") and f.profile.TrackUnlocked("coast"), "写失败applied=true仍同时保留金币权益")
        check(f.files["pursuit_profile.txt"] == f.initial and f.hud.resultText:find("待保存", 1, true), "写失败主档保留且主方提示待保存")
        f.fail(false)
        for _ = 1, 52 do f.main.tick(.1) end
        local _, countGrants = f.counts()
        check(countGrants == 1 and f.profile.Coins() == 2402 and not f.profile.HasPendingSave(), "真实5秒补存不再次GrantRaceRewards")
        check(f.hud.resultText:find("已保存", 1, true), "主方补存成功更新结果提示")
        persisted(f, 2402)
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
        check(f.profile.Coins() == 2402 and #f.hud.offers == offers and #f.hud.notices == notices and not f.ads.IsBusy(),
            "真实主方切页Cancel后迟到广告不发币、不操作旧UI")
        check(cloudCalls == 0, "全程零真实或桩云请求")
    end)
    print(string.format("[RaceSettlementChecks] PASS %d项；真实main业务接线/局部Profile与Store/局部SDK %d次；未启动实赛或真实UI", assertions, sdkCalls))
    return {passed = true, assertions = assertions}
end
return Checks
