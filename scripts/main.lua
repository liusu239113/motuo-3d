-- 基于3D场景脚手架：九车竞速追逐、真实车库、手机多指与骑行电台。
local UI = require("urhox-libs/UI")
require "urhox-libs.Camera.ThirdPersonCamera"
local World = require("World")
local Landscape = require("Landscape")
local Tracks = require("Tracks")
local VehicleAssets = require("VehicleAssets")
local Bike = require("Bike")
local Rider = require("Rider")
local Sim = require("Simulation")
local HUD = require("HUD")
local MobileControls = require("MobileControls")
local RideAudio = require("RideAudio")
local RideLoader = require("RideLoader")
local Catalog = require("Catalog")
local Profile = require("Profile")
local Race = require("Race")
local RaceVisuals = require("RaceVisuals")
local RaceAudio = require("RaceAudio")
local Profile_ = require("RaceFrameProfile")
local CareerSession = require("Career.Session")
local CareerQuality = require("Career.AdaptiveQuality")
---@type CareerSession?
local career_ = nil
local careerMode_ = false
local careerRace_ = false
local careerRaceId_ = ""
local careerRaceCheck_,careerRaceCheckStage_,careerRaceCheckFrames_=false,0,0
local CareerProgress = require("Career.Progression")
local CareerStore = require("Career.Store")
local RewardedAds = require("RewardedAds")

---@type RideRace?
local race_ = nil
---@type RaceVisuals?
local raceVisuals_ = nil
---@type RaceAudio?
local raceAudio_ = nil
local selectedLaps_, selectedRider_ = 3, "green"
local selectedTrack_, loadedTrack_ = "circuit", ""
local boostFov_ = 0.0
local profileRetrySeconds_ = 0.0
local raceTest_, raceAutodrive_ = false, false
local trackTest_, trackCheckIndex_, trackCheckFrames_ = false, 1, 0
---@type World?
local previousTrackWorld_ = nil
---@type RideAudio?
local previousTrackAudio_ = nil
local raceCheckStage_, raceCheckFrames_, raceCheckElapsed_ = 0, 0, 0.0
local raceCheckCountdown_, raceCheckAI_, raceCheckPolice_ = 0.0, 0.0, 0.0

---@type Scene
local scene_ = nil
---@type ThirdPersonCameraInstance
local chase_ = nil
---@type Node
local helmetNode_ = nil
---@type Camera
local helmetCamera_ = nil
---@type Zone
local zone_ = nil
---@type World
local world_ = nil
---@type Bike
local bike_ = nil
---@type HUD
local hud_ = nil
---@type RideAudio
local sound_ = nil
---@type RideLoader
local loader_ = nil
---@type thread?
local preparation_ = nil
local sim_ = Sim.New()
local touch_ = MobileControls.New()
local screen_, selectedVehicle_, loadedVehicle_ = "menu", "sport", ""
local firstPerson_, ready_, pendingChallenge_ = true, false, false
local loadPhase_, loadingFrames_ = "idle", 0
local raceAssetsReady_ = false
local clock_, accumulator_, lastYaw_ = 0.0, 0.0, 0.0
local resultShown_, autoTest_, selfTest_, portrait_ = false, false, false, false
-- 竞速结算广告：只在自由竞速结算发放，生涯赛事走生涯现金通道，不混用金币。
local resultAdAvailable_, resultAdClaimed_ = false, false
local resultRewardPending_ = false -- 仅当前结果页已应用但未保存的奖励，不借用其他赛局pending
local testMode_, testShot_, testVehicle_, testRoute_ = "", "", "sport", -1.0
local careerReadyShot_,careerReadyFrames_="",0
local testScenery_, testNitroShot_ = false, false
local testFeature_, testFeatureDone_ = "", false
local testFeaturePhase_, testFeatureAirborne_ = "active", false
local testFeatureFrame_ = 1
local featureShotPhases_ = {"approach", "active", "late", "settled"}
local testShotDelay_ = 18
local captureFrames_, checkFrames_, checkStage_, preparationsStarted_ = 0, 0, 0, 0
local pendingActions_ = {spin180 = false, spin360 = false, nitro = false, skill = false}
-- 固定步复用输入快照，低帧率一帧多次子步也不重复分配临时表。
local rideInput_ = {steer = 0.0, throttle = 0.0, brake = false,
    wheelie = false, burnout = false, spin180 = false, spin360 = false}
local highQuality_, disableMirrors_, testProfile_ = false, false, false
-- 仅显式验收参数启用：固定车身倾斜/坡度，复现静止坡面上的蒙皮问题。
local testPose_, testLean_, testPitch_, testSteer_ = false, 0.0, 0.0, 0.0
local testTrick_ = ""
---@type Light
local sunlight_ = nil
local benchmark_, benchmarkWarmup_, benchmarkFrames_ = false, 0, 0
local benchmarkTimes_ = {}
-- 验收持有首次世界与六音源，逐次换车检查对象身份而非只检查数量。
---@type World?
local testWorld_ = nil
---@type RideAudio?
local testAudio_ = nil
---@type table<number, SoundSource>
local testSources_ = {}
local testedRiderTransforms_ = {sport = false, rally = false, cruiser = false}

local function ApplyQuality()
    renderer.dynamicInstancing = true
    -- 机关/锥标/护栏共608个共享网格实例；minInstances=1让它们全部走INSTANCED合批，
    -- 而不是每个实例一次draw。这是赛事场景最大的一笔draw削减。
    renderer.minInstances = 1
    renderer:SetShadowMapSize(highQuality_ and 2048 or 1024)
    renderer.textureFilterMode = FILTER_ANISOTROPIC
    renderer.textureAnisotropy = highQuality_ and 8 or 2
    if sunlight_ then
        -- 手机仅支持两级CSM，第二级须覆盖近路树和设施，而不是把预算写进被忽略的第三级。
        sunlight_.shadowCascade = highQuality_ and CascadeParameters(22, 120, 0, 0, 0.8)
            or CascadeParameters(14, 48, 0, 0, 0.8)
        sunlight_.shadowBias = BiasParameters(0.0003, 0.6)
    end
    if world_ then world_:SetQuality(highQuality_) end
    if bike_ then bike_:SetQuality(highQuality_) end
    if raceVisuals_ then
        raceVisuals_:SetQuality(highQuality_)
    end
    if helmetCamera_ then helmetCamera_.lodBias = highQuality_ and 1 or 0.7 end
    if chase_ then chase_:GetCamera().lodBias = highQuality_ and 1 or 0.7 end
    if hud_ then hud_:SetQuality(highQuality_ and "画质" or "流畅") end
end

local function ToggleQuality()
    highQuality_ = not highQuality_
    ApplyQuality()
    print("[画质] " .. (highQuality_ and "画质：远景细节与高精阴影" or "流畅：缩短阴影、植被LOD与低频后视画面"))
    return highQuality_ and "画质" or "流畅"
end

local function ClearActions()
    accumulator_ = 0
    for key in pairs(pendingActions_) do pendingActions_[key] = false end
end

local function SetScreen(screen)
    if screen~=screen_ then
        RewardedAds.Cancel()
        if screen~="result" then resultRewardPending_=false end
    end
    -- 设置层可直接覆盖实战界面，暂停时保留仪表位置用于所见即所得编辑。
    if screen == "pause" then
        hud_.pausedCockpitVisible = hud_.cockpit:IsVisible()
    end
    screen_ = screen
    ClearActions()
    hud_:SetScreen(screen)
    print("[流程] " .. screen)
end

local function CockpitActive()
    return firstPerson_ and (screen_ == "ride" or screen_ == "pause" or screen_ == "result"
        or (screen_ == "settings" and hud_ and hud_.settingsReturn == "pause"))
end

local function SetCamera()
    if not chase_ or not helmetCamera_ then return end
    renderer:SetNumViewports(1)
    -- 加载遮罩仍可见时就渲染实际驾驶视角，把首次材质编译留在准备阶段。
    local cockpit = CockpitActive() or (screen_ == "loading" and firstPerson_)
    renderer:SetViewport(0, Viewport:new(scene_, cockpit and helmetCamera_ or chase_:GetCamera()))
end

-- 换地图必须释放整套世界；不能把新道路投影接到旧Race采样或旧交通上。
-- UI、触摸管理器和主事件订阅继续保留，音频偏好在重建后恢复。
local audioPreferences_ = {music = true, effects = true, track = 1}
local function DisposeRideWorld()
    ready_ = false
    preparation_ = nil
    ClearActions()
    touch_:Reset()
    hud_:SetRace(nil)
    renderer:SetNumViewports(0)
    if sound_ then
        audioPreferences_.music, audioPreferences_.effects = sound_.musicEnabled, sound_.effectsEnabled
        audioPreferences_.track = sound_.trackIndex
        sound_:Stop(); sound_ = nil
    end
    if raceAudio_ then raceAudio_:Dispose(); raceAudio_ = nil end
    if raceVisuals_ then raceVisuals_:Dispose(); raceVisuals_ = nil end
    if race_ then race_:Stop(); race_ = nil end
    if chase_ then chase_:GetNode():Dispose(); chase_ = nil end
    if bike_ then bike_:Dispose(); bike_ = nil end
    if scene_ then scene_:Dispose(); scene_ = nil end
    world_, helmetNode_, helmetCamera_, zone_, sunlight_ = nil, nil, nil, nil, nil
    loadedVehicle_, loadedTrack_, raceAssetsReady_, boostFov_ = "", "", false, 0
end

local function LoadingError(message)
    loadPhase_ = "failed"
    print("[加载失败] " .. message)
    hud_:SetLoading("资源准备未完成", message, 0, "未进入驾驶 · 可重试", true)
end

local function ResetRideState()
    if raceAudio_ then raceAudio_:Reset(race_) end
    if race_ then race_:Stop() end
    assert(sim_:SetVehicle(selectedVehicle_), "车型尚未交付：" .. selectedVehicle_)
    sim_:Reset(false)
    hud_:SelectTrack(selectedTrack_, false)
    if pendingChallenge_ then
        local trackDef = Tracks.Get(selectedTrack_)
        local aiLevel = trackDef and trackDef.aiLevel or 0.72
        if not race_ then race_ = Race.New(Landscape, sim_, {laps = selectedLaps_, vehicleIds = Catalog.AvailableIds(), aiLevel = aiLevel}) end
        race_.options.vehicleIds = Catalog.AvailableIds()
        race_.options.mixed = not raceTest_ and not careerRace_
        race_.options.world = world_
        race_.options.rosterOffset = (race_.options.rosterOffset or 0)+5
        require("MixedRace").ResetCourse(world_)
        -- 换图时同步该赛道的AI强度，重赛不会沿用上一张图。
        race_.options.aiLevel = aiLevel
        race_.options.professional = careerRace_
        race_:Reset(sim_, selectedLaps_)
        race_:SetTraffic(careerRace_ and {} or world_.traffic)
        sim_.message, sim_.messageTimer = "E 专属技能 · Shift 氮气 · W/S 油刹 · A/D 转向", 6
        race_.player.colorId = selectedRider_
        if raceVisuals_ then
            raceVisuals_:SetQuality(highQuality_)
            raceVisuals_:Reset(race_)
        else raceVisuals_ = RaceVisuals.New(scene_, world_, race_, highQuality_) end
        raceVisuals_:SetVisible(true)
        raceVisuals_:Update(0, sim_)
        hud_:SetRace(race_)
        print(string.format("[比赛] %d圈 / %.3fkm每圈 / 8名AI / 车手%s", selectedLaps_, Landscape.RouteLength / 1000, selectedRider_))
        if raceTest_ then
            local stats = raceVisuals_:GetStats()
            assert(#race_.racers == 9 and stats.rivals == 8 and stats.riders == 8 and stats.police,
                "竞速实景应有8个独立AI、8名骨骼骑手及真实警车")
            print("[竞速实景验收] 9人名单、8AI模型、8骨骼车手、真实警车与赛道门架已就绪")
        end
    else
        if raceVisuals_ then raceVisuals_:SetVisible(false) end
        hud_:SetRace(nil)
    end
    if testRoute_ >= 0 and not pendingChallenge_ then
        local position, heading = Landscape.RoadPoint(testRoute_)
        local angle = math.rad(heading)
        sim_.x, sim_.z = position.x + math.cos(angle) * 2.4, position.z - math.sin(angle) * 2.4
        sim_.heading, sim_.yaw = heading, heading
        sim_.y = world_:Surface(sim_.x, sim_.z)
        sim_:UpdateNavigation(sim_.x, sim_.z, world_, false)
    end
    if testFeature_ ~= "" and not pendingChallenge_ then
        for _, feature in ipairs(Landscape.Features or {}) do
            if feature.kind == testFeature_ then
                local a = math.rad(feature.yaw)
                local previewRamp = testFeature_ == "ramp" and (testFeaturePhase_ == "approach" or testFeaturePhase_ == "sequence")
                local approach = previewRamp and 75 or 8
                sim_.x, sim_.z = feature.x - math.sin(a) * approach, feature.z - math.cos(a) * approach
                sim_.y = world_:Surface(sim_.x, sim_.z)
                sim_.heading, sim_.yaw, sim_.speed = feature.yaw, feature.yaw, 38
                sim_:UpdateNavigation(sim_.x, sim_.z, world_, false)
                print(string.format("[机关实拍] %s / %s / s=%.1f lane=%.2f", feature.kind, feature.id, feature.s, feature.lateral))
                break
            end
        end
    end
    world_:ResetTraffic(0)
    for _,car in ipairs(world_.traffic) do car.node:SetEnabledRecursive(not careerRace_) end
    if careerRace_ then world_.traffic={}; race_:SetTraffic(world_.traffic) end
    world_:Update(0, sim_.distance, clock_, sim_.x, sim_.z)
    if testTrick_ ~= "" then sim_.speed = 8 end
    accumulator_, resultShown_, lastYaw_, boostFov_ = 0.0, false, sim_.heading, 0.0
    resultAdAvailable_, resultAdClaimed_ = false, false
    if hud_ then hud_:SetResultAdOffer(false, false) end
    bike_:SetRiderColor(selectedRider_)
    sound_:SetVehicle(selectedVehicle_)
    bike_:UpdateState(0, sim_, firstPerson_, clock_)
    chase_:SetMode("normal")
    chase_:Update(1, bike_.node, lastYaw_, 9)
end

local function FinishRidePreparation()
    local ok, message = pcall(ResetRideState)
    if not ok then
        -- 比赛表现创建失败不应每帧重试并堆积半成品节点。
        if raceVisuals_ then raceVisuals_:Dispose(); raceVisuals_ = nil end
        if scene_ then
            for _, child in ipairs(scene_:GetChildren(false)) do
                if child.name == "RacePresentation" then child:Dispose() end
            end
        end
        if race_ then race_:Stop() end
        LoadingError(tostring(message))
        return
    end
    if not careerRace_ and not autoTest_ and testShot_=="" then
        local allowed,trialMessage=Catalog.ConsumeDriveTrial(selectedVehicle_)
        if not allowed then
            if race_ then race_:Stop() end
            LoadingError(trialMessage or "车辆体验次数不足");return
        end
        hud_:RefreshOwnership()
    end
    -- 发车入口只接受一次提交；防止就绪按钮重复点击重复扣次。
    loadPhase_="running"
    sound_:Unlock()
    if raceAudio_ then raceAudio_:Unlock() end
    hud_:SyncRadio(sound_:GetTrackTitle(), sound_.musicEnabled)
    SetScreen(portrait_ and "pause" or "ride")
    SetCamera()
    if testMode_ == "pause" or testMode_ == "pause-settings" then SetScreen("pause") end
    if testMode_ == "pause-settings" then hud_:OpenSettings() end
    if testMode_ == "result" then
        sim_.finished, sim_.success = true, true
        sim_.distance, sim_.score, sim_.topSpeed = 2500, 8500, 208
        sim_.goalsDone = sim_.goalsTotal
        resultShown_ = true
        SetScreen("result")
        hud_:ShowResult(sim_)
    end
end

local function RequireRaceProfile(allowCareer)
    if allowCareer and careerRace_ then return true end
    local ok,message=Profile.TryLoad(true)
    if ok then return true end
    hud_:ShowNotice("独立竞速进度不可用",(message or "读取失败")
        .."\n原档已保留。已暂停独立竞速、购买和金币奖励，王二狗生涯不受影响。")
    return false
end

local function StartRide(challenge)
    if screen_ == "loading" or not RequireRaceProfile(true) then return end
    -- 圈数由赛道固定；进入车库时就同步，不保留玩家自选。
    local track = Tracks.Get(selectedTrack_)
    if track then selectedLaps_ = math.max(1, math.min(9, track.laps or 3)) end
    pendingChallenge_ = challenge == true
    if pendingChallenge_ then firstPerson_ = false end
    SetScreen("garage")
    hud_.challenge = pendingChallenge_
    hud_:SelectLaps(selectedLaps_, false)
    hud_:SelectTrack(selectedTrack_, false)
    hud_:SelectVehicle(selectedVehicle_, false)
    SetCamera()
end

local function ConfirmVehicle(id)
    if screen_ == "loading" or not RequireRaceProfile(true) then return end
    local entry = Catalog.Get(id)
    if not entry or not entry.available or not VehicleAssets.Vehicles[id] then return end
    selectedVehicle_ = id
    if require("MixedVehicles").Get(id) then firstPerson_=false end
    if not careerRace_ and not autoTest_ and testShot_=="" and not Catalog.CanDrive(id) then
        hud_:ShowNotice("载具尚未解锁","使用金币永久购买，或完整观看一次广告获得该载具三局体验。")
        return
    end
    local track = assert(Tracks.Get(selectedTrack_))
    if not careerRace_ and not Profile.TrackUnlocked(track.id) and not autoTest_ and not trackTest_ and testShot_ == "" then
        hud_:ShowNotice("赛道尚未开放", "请在赛道选择中查看解锁条件，通关前置赛道或确认使用金币解锁后再出发。")
        return
    end
    if not careerRace_ then selectedLaps_ = track.laps end
    hud_:SelectLaps(selectedLaps_, false)
    if sound_ then sound_:Unlock() end
    if raceAudio_ then raceAudio_:Unlock() end
    SetScreen("loading")
    loadingFrames_ = 0
    local canReuse = ready_ and loadedVehicle_ == id and loadedTrack_ == selectedTrack_
        and (not pendingChallenge_ or raceAssetsReady_)
    loadPhase_ = canReuse and "reuse" or "download-pending"
    local track = assert(Tracks.Get(selectedTrack_))
    hud_:SetLoading("正在准备 · " .. entry.name,
        loadPhase_ == "reuse" and "复用已载入的赛道、车型与声音，仅重置本次旅程。"
            or (track.name .. " · 检查路线、场景、车辆和声音依赖。"),
        0, loadPhase_ == "reuse" and "无需重复下载或构建" or "开始后选车，再下载资源")
end

local function SettleCareerResult()
    if not careerRace_ or not race_ or race_.phase ~= "finished" then return true,"赛事报名已保留，可在车行继续" end
    local profile=CareerStore.Get()
    if not (profile.career and profile.career.pending) then return true,"赛事奖金已保存" end
    local pending=profile.career.pending
    if pending.training and not race_.player.finished then return true,"训练尚未通过，报名保留，可免费继续练习" end
    local ok,message
    if pending.training then ok,message=CareerProgress.CompleteTraining(race_.player.finished==true)
    else ok,message=CareerProgress.SettleRace(race_.player.rank or 9,race_.player.finished==true,careerRaceId_) end
    if ok then sim_.coinsEarned=0 else print("[生涯赛事保存失败] "..message) end
    return ok,message
end

---竞速结算双倍金币：只在自由竞速结算展示；生涯奖金走生涯现金，不并入金币。
---@param earned integer 本场已结算金币
local function OfferResultAdBonus(earned)
    resultAdAvailable_ = earned > 0 and not careerRace_
    resultAdClaimed_ = false
    if hud_ then hud_:SetResultAdOffer(resultAdAvailable_, false, "看广告 · 双倍金币") end
end

local function WatchResultAdBonus()
    if not resultAdAvailable_ or resultAdClaimed_ then return end
    if not hud_ or hud_.screen ~= "result" then return end
    if not RequireRaceProfile() then return end
    local earned = math.floor(sim_ and sim_.coinsEarned or 0)
    if earned <= 0 then return end

    local bonusSim,bonusRace=sim_,race_
    RewardedAds.Show {
        isValid=function() return sim_==bonusSim and race_==bonusRace and not careerMode_ and screen_=="result" end,
        setBusy = function(busy)
            hud_:SetResultAdOffer(resultAdAvailable_, busy, busy and "广告加载中…" or "看广告 · 双倍金币")
        end,
        onReward = function()
            -- 与首次结算同额补发；本次applied独立于其他未保存奖励的全局pending。
            local saved, message, applied = Profile.AddCoins(earned)
            resultRewardPending_ = applied and not saved
            if not applied then
                resultAdAvailable_ = false
                hud_:SetResultAdOffer(false,false)
                hud_:SetResultReward(message or "金币未变更")
                hud_:ShowNotice("奖励未入账",message or "无法增加金币，原余额未修改")
                return
            end
            resultAdClaimed_, resultAdAvailable_ = true, false
            hud_:RefreshOwnership()
            hud_:SetResultAdOffer(false, false)
            local resultHUD = hud_ --[[@as HUD]]
            resultHUD:SetResultReward(string.format("本场金币 %d · 广告额外 +%d · 余额 %d 金币%s",
                earned, earned, Profile.Coins(), saved and " · 已保存" or " · 待保存，请勿退出"))
            if not saved then hud_:ShowNotice("奖励待保存", (message or "保存失败") .. "\n系统会自动重试，不需要再看广告。") end
            print(string.format("[广告奖励] 竞速结算双倍 +%d，余额 %d", earned, Profile.Coins()))
        end,
        onFailure = function(msg)
            hud_:SetResultAdOffer(resultAdAvailable_, false, "看广告 · 双倍金币")
            hud_:ShowNotice("广告未完成", (msg or "广告暂不可用") .. "\n奖励未发放，可稍后再试。")
        end,
    }
end

local function ReturnToCareer()
    local ok,message=SettleCareerResult()
    if not ok then hud_:ShowNotice("结算尚未保存",message.."\n请稍后再次点击返回生涯，未重复扣报名费。"); return end
    if loader_ then loader_:Cancel(); loader_=nil end
    hud_:CloseModal()
    DisposeRideWorld(); touch_:SetEnabled(false); hud_.root:SetVisible(false)
    careerMode_,careerRace_=true,false
    hud_:SetCareerRace(false)
    career_:Home(message)
end

local function RestartRide()
    -- 生涯每次报名只结算一次；结果页回生涯再报名，不能复用已结算门票刷奖金。
    if careerRace_ then ReturnToCareer(); return end
    if not ready_ or screen_ == "loading" then return end
    ConfirmVehicle(selectedVehicle_)
end

local function PauseRide()
    if screen_ == "ride" then SetScreen("pause")
    elseif screen_ == "pause" and not portrait_ then SetScreen("ride") end
    SetCamera()
end

local function MainMenu()
    if careerRace_ then ReturnToCareer(); return end
    if sound_ then sound_:Unlock() end
    if raceAudio_ then raceAudio_:Silence() end
    if race_ then race_:Stop() end
    if raceVisuals_ then raceVisuals_:SetVisible(false) end
    hud_:SetRace(nil)
    SetScreen("menu")
    if chase_ then chase_:SetMode("showroom") end
    SetCamera()
end

local function ToggleCamera()
    if not ready_ or screen_ ~= "ride" then return end
    if require("MixedVehicles").Get(selectedVehicle_) then
        sim_.message,sim_.messageTimer="混合载具使用第三人称视角",2;return
    end
    firstPerson_ = not firstPerson_
    bike_:UpdateState(0, sim_, CockpitActive(), clock_)
    SetCamera()
end

-- 三车型共用同一套实骨骼、相机与复用验收，防止新增车型漏测。
---@param id string
local function ValidateSelectedVehicle(id)
    assert(preparationsStarted_ == 1 and loadedVehicle_ == id and bike_.vehicleId == id,
        "选车验收：世界只能构建一次，当前车型应为 " .. id)
    assert(sim_.vehicleId == id, "选车验收：仿真车型未同步")
    -- 同时检查场景实际节点，不能只看当前bike引用而漏掉失败构造的残留。
    local bikeNodeCount = 0
    for _, child in ipairs(scene_:GetChildren(false)) do
        if child.name:match("^Bike_") then
            bikeNodeCount = bikeNodeCount + 1
            assert(child == bike_.node, "选车验收：存在非当前车型的残留节点")
        end
    end
    assert(bikeNodeCount == 1, "选车验收：场景直接Bike_*节点必须恰好一个，无换车残留")
    if not testWorld_ then
        testWorld_, testAudio_ = world_, sound_
        for i = 1, 6 do testSources_[i] = assert(sound_.sources[i], "选车验收：缺少驾驶音源") end
    end
    assert(world_ == testWorld_ and sound_ == testAudio_, "换车不得重建世界或音频管理器")
    local sourceCount = 0
    for i, source in pairs(sound_.sources) do
        sourceCount = sourceCount + 1
        assert(source == testSources_[i], "换车不得替换或新增音源")
    end
    assert(sourceCount == 6, "驾驶音源必须恰好六个")
    print(string.format("[车型节点验收] %s：场景直接Bike_*=%d，仅当前%s；世界构建=%d，复用音源=%d",
        id, bikeNodeCount, bike_.node.name, preparationsStarted_, sourceCount))
    -- 走真实视角切换入口，检查主视口、实车与骑手/近景座舱显隐。
    local originalFirstPerson = firstPerson_
    if firstPerson_ then ToggleCamera() end
    assert(not firstPerson_ and not bike_.firstPerson and bike_.riderRig.visible
        and not bike_.cockpit.enabled and bike_.body.enabled, "追尾视角显隐错误")
    assert(renderer:GetViewport(0):GetCamera() == chase_:GetCamera(), "追尾主相机未切换")
    for _, angle in ipairs({-22, 0, 22}) do
        bike_.riderRig:Update(angle, true)
        bike_.riderRig:ValidatePose()
    end
    bike_.riderRig:Update(0, true)
    if not testedRiderTransforms_[id] then
        -- 包括真实顶点权重蒙皮边界，不再把手腕对位通过当成网格正常。
        bike_.riderRig:TestTransforms()
        testedRiderTransforms_[id] = true
    end
    ToggleCamera()
    assert(firstPerson_ and bike_.firstPerson and not bike_.riderRig.visible
        and bike_.cockpit.enabled and bike_.body.enabled, "头盔视角显隐错误")
    assert(renderer:GetViewport(0):GetCamera() == helmetCamera_, "头盔主相机未切换")
    assert((helmetNode_.position - bike_.Cockpit.localOffset):Length() < 0.0001,
        "头盔眼位未使用当前车型配置")
    if not originalFirstPerson then ToggleCamera() end
    print("[骑手验收] " .. id .. "：-22/0/+22度实骨骼ValidatePose与头盔/追尾切换通过")
end

local function ToggleRadio()
    if not sound_ then return false end
    local enabled = sound_:ToggleMusic()
    hud_:SyncRadio(sound_:GetTrackTitle(), enabled)
    return enabled
end

local function ChangeRadio(direction)
    if not sound_ then return end
    local title = sound_:ChangeTrack(direction)
    hud_:SyncRadio(title, sound_.musicEnabled)
end

function CreateScene()
    scene_ = Scene()
    -- 骑手骨骼每帧由脚本在主线程手动改写；关闭场景线程更新，避免
    -- worker 线程读取骨骼矩阵时与脚本写入并发，导致间歇性蒙皮撕裂。
    scene_.threadedUpdate = false
    scene_:CreateComponent("Octree")
    local group = scene_:CreateChild("山湖日光")
    assert(group:LoadXML(cache:GetResource("XMLFile", "LightGroup/Daytime.xml"):GetRoot()), "日光预设载入失败")
    zone_ = group:GetComponent("Zone", true)
    zone_.boundingBox = BoundingBox(-8000, 8000)
    -- 每图独立的自然日光与远景雾；保留真实天空IBL，不用均匀补光抹平地形。
    local atmospheres={
        lake={fog=Color(.67,.75,.78),start=290,finish=1800,sun=Color(1,.94,.82),power=2.25,ambient=.36,dir=Vector3(.52,-.69,.38)},
        alpine={fog=Color(.69,.76,.82),start=340,finish=2100,sun=Color(1,.96,.89),power=2.35,ambient=.34,dir=Vector3(.60,-.64,.34)},
        coast={fog=Color(.68,.77,.80),start=360,finish=2000,sun=Color(1,.94,.82),power=2.45,ambient=.38,dir=Vector3(.40,-.72,.48)},
        canyon={fog=Color(.76,.69,.58),start=300,finish=1850,sun=Color(1,.89,.73),power=2.40,ambient=.32,dir=Vector3(.56,-.62,.44)},
        forest={fog=Color(.64,.72,.70),start=190,finish=1450,sun=Color(1,.95,.83),power=2.00,ambient=.32,dir=Vector3(.48,-.69,.38)},
        circuit={fog=Color(.69,.76,.80),start=380,finish=2000,sun=Color(1,.96,.88),power=2.30,ambient=.37,dir=Vector3(.44,-.75,.35)},
    }
    local atmosphere=assert(atmospheres[Landscape.activeId])
    zone_.fogColor = atmosphere.fog
    zone_.depthFogStart, zone_.depthFogEnd = atmosphere.start, atmosphere.finish
    zone_.depthFogEnable = true
    zone_.depthFogDensity = .75
    zone_.vignetteEnabled, zone_.vignetteIntensity = true, 0.12
    zone_.autoExposureEnabled = false
    zone_.tonemapMode = TONEMAP_MODE_ACES
    zone_.bloomThreshold, zone_.bloomWeight = 1.6, 0.045
    sunlight_ = group:GetComponent("Light", true)
    sunlight_.node.direction, sunlight_.color = atmosphere.dir, atmosphere.sun
    sunlight_.brightness, sunlight_.castShadows = atmosphere.power, true
    local skyMaterial = Material:new()
    skyMaterial:SetTechnique(0, cache:GetResource("Technique", "Techniques/DiffSkybox.xml"))
    skyMaterial:SetTexture(TU_DIFFUSE, cache:GetResource("TextureCube", "uuid://E4ehad-5axjv7Ml9zasxNx06"))
    local skybox = scene_:CreateChild("照片全景天空"):CreateComponent("Skybox")
    skybox:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    skybox:SetMaterial(skyMaterial)
    zone_.ambientSource, zone_.ambientIntensity = AMBIENT_SKYBOX, atmosphere.ambient
    zone_.envTextureSpecIntensity = 0.10
    renderer.hdrRendering = true
    ApplyQuality()
    print("[场景] 照片天空与匹配IBL，移动前向渲染／默认流畅档")
end

function SetupCameraAndViewport()
    renderer:SetNumViewports(1)
    if not chase_ then
        chase_ = ThirdPersonCamera.Create(scene_, {
            modes = {
                normal = {distance = 5.4, offset = Vector3(0, 1.45, 0), fov = 66},
                fast = {distance = 6.1, offset = Vector3(0, 1.45, 0), fov = 74},
                showroom = {distance = 4.8, offset = Vector3(-0.8, 1.0, 0), fov = 48},
                profile = {distance = 3.5, offset = Vector3(0, 1.0, 0), fov = 42},
            }, initialMode = "normal", transitionSpeed = 5, farClip = 2600, nearClip = 0.07})
    end
    helmetNode_ = bike_.visual:CreateChild("骑手眼位")
    helmetNode_.position = bike_.Cockpit.localOffset
    helmetNode_.rotation = Quaternion(bike_.Cockpit.pitch, 0, 0)
    helmetCamera_ = helmetNode_:CreateComponent("Camera")
    helmetCamera_.nearClip, helmetCamera_.farClip, helmetCamera_.fov = 0.025, 2600, bike_.Cockpit.fov
    bike_:UpdateState(0, sim_, firstPerson_, clock_)
    chase_:Update(1, bike_.node, sim_.heading, 9)
    ApplyQuality()
    SetCamera()
end

local function BeginPreparation()
    local fullBuild = not ready_ or loadedTrack_ ~= selectedTrack_
    if fullBuild then
        DisposeRideWorld()
        assert(Landscape.SelectTrack(selectedTrack_), "赛道不存在：" .. selectedTrack_)
        sim_ = Sim.New(Landscape)
        preparationsStarted_ = preparationsStarted_ + 1
        print("[地图] 重建世界 " .. selectedTrack_ .. "；路线、交通、仿真和比赛采样一并更新")
    end
    loadPhase_ = "building"
    local function stage(title, detail, done, total)
        hud_:SetLoading(title, detail, total > 0 and done / total or 0,
            string.format("本阶段 %d / %d 项 · 场景准备，非下载进度", done, total))
        coroutine.yield()
    end
    preparation_ = coroutine.create(function()
        if fullBuild then
            CreateScene()
            stage("准备环境", "照片天空与自然日光已就绪", 1, 1)
            world_ = World.New(scene_, function(kind, done, count)
                stage("准备" .. kind, assert(Tracks.Get(selectedTrack_)).name .. " · 分帧构建赛道与环境", done, count)
            end)
        end
        if bike_ then
            helmetNode_, helmetCamera_ = nil, nil
            bike_:Dispose()
            bike_ = nil
            loadedVehicle_ = ""
        end
        -- 仅保护同步车型构造，不把任何stage/coroutine.yield包进pcall。
        -- 记录既有节点身份，失败时只清理本次新建的同名车根，不误删其他对象。
        local buildingVehicle = selectedVehicle_
        local rootName = "Bike_" .. buildingVehicle
        ---@type table<Node, boolean>
        local existingRoots = {}
        for _, child in ipairs(scene_:GetChildren(false)) do
            if child.name == rootName then existingRoots[child] = true end
        end
        local ok, result = pcall(Bike.New, scene_, buildingVehicle)
        if not ok then
            for _, child in ipairs(scene_:GetChildren(false)) do
                if child.name == rootName and not existingRoots[child] then child:Dispose() end
            end
            -- 原协程恢复入口会转交LoadingError，保留世界与六音源供重试复用。
            error(tostring(result), 0)
        end
        bike_ = result --[[@as Bike]]
        stage("准备所选车型", "车身、握把双手与专属仪表座舱已就绪", 1, 2)
        SetupCameraAndViewport()
        stage("准备所选车型", "第一视角与追尾相机已就绪", 2, 2)
        if fullBuild then
            sound_ = RideAudio.New(scene_)
            -- 加载失败也可能释放本管理器；先恢复偏好，避免重试保存默认值。
            sound_.trackIndex = audioPreferences_.track
            if not audioPreferences_.music then sound_:ToggleMusic() end
            if not audioPreferences_.effects then sound_:ToggleEffects() end
            for i = 1, RideAudio.Count do
                assert(sound_:LoadOne(i), "声音资源未载入：" .. RideAudio.Resources[i])
                stage("准备骑行声音", "保留上传歌单、原创电台和独立驾驶音效", i, RideAudio.Count)
            end
            raceAudio_ = RaceAudio.New(scene_)
            raceAudio_:SetEffectsEnabled(audioPreferences_.effects)
        end
        if pendingChallenge_ then
            VehicleAssets.PrepareDetails(Catalog.AvailableIds(),function(id,i,total) stage("准备对手车型",assert(Catalog.Get(id)).name.." · 车辆外观准备中",i,total) end)
            raceAssetsReady_ = true
        end
        loadedVehicle_, loadedTrack_, ready_, loadPhase_ = selectedVehicle_, selectedTrack_, true, "ready"
        print("[加载] 赛道与所选车型全部就绪：" .. loadedTrack_ .. " / " .. loadedVehicle_)
    end)
end

local function BeginDownload()
    loadPhase_ = "downloading"
    if loader_ then loader_:Cancel() end
    local resources, types = {}, {}
    for _, path in ipairs(World.Resources) do resources[#resources + 1] = path end
    for path, kind in pairs(World.ResourceTypes or {}) do types[path] = kind end
    for _, path in ipairs(VehicleAssets.GetResources(selectedVehicle_)) do resources[#resources + 1] = path end
    for _, path in ipairs(RaceVisuals.GetResources()) do resources[#resources + 1] = path end
    for path, kind in pairs(VehicleAssets.ResourceTypes or {}) do types[path] = kind end
    for _, path in ipairs(Rider.Resources) do resources[#resources + 1] = path end
    for path, kind in pairs(Rider.ResourceTypes) do types[path] = kind end
    for _, path in ipairs(HUD.Resources or {}) do resources[#resources + 1] = path end
    for path, kind in pairs(HUD.ResourceTypes or {}) do types[path] = kind end
    -- 比赛对手跨车型选用，不依赖普通交通的循环资源清单。
    if pendingChallenge_ then
        local ids = Catalog.AvailableIds()
        ids[#ids + 1] = "police"
        for _, path in ipairs(VehicleAssets.ResourcesFor(ids)) do resources[#resources + 1] = path end
        for path, kind in pairs(VehicleAssets.ResourceTypes) do types[path] = kind end
    end
    for _, path in ipairs(RaceAudio.Resources) do resources[#resources + 1] = path; types[path] = "Sound" end
    for _, path in pairs(RideAudio.EngineResources) do resources[#resources + 1] = path; types[path] = "Sound" end
    loader_ = RideLoader.New(RideAudio.Resources,
        function(title, detail, fraction, numbers) hud_:SetLoading(title, detail, fraction, numbers) end,
        BeginPreparation, LoadingError, resources, types)
    loader_:Start()
end

local function RetryLoading()
    if loadPhase_ ~= "failed" then return end
    if not ready_ then DisposeRideWorld() end
    preparation_ = nil
    loadPhase_, loadingFrames_ = "download-pending", 0
    hud_:SetLoading("重新检查资源", "已有下载缓存继续复用，失败项将重新校验。", 0, "正在重试")
end

function Start()
    graphics.windowTitle = "公路狂飙"
    input.mouseMode = MM_ABSOLUTE;Catalog.SetGMFreeExperience(false)
    ---@type fun()?
    local restoreUnavailableProfile=nil
    ---@type fun()?, fun():integer,string
    local restoreGM,gmStorage=nil,nil
    for _,arg in ipairs(GetArguments()) do
        if arg=="-gmchecks" then restoreGM,gmStorage=require("GMChecks").Begin() end
        if arg=="-profilebadchecks" then
            restoreUnavailableProfile=require("ProfileChecks").BeginUnavailableProfile()
        end
    end
    local hudCreated,hudOrError=pcall(function()
        return HUD.New({start = StartRide, pause = PauseRide, menu = MainMenu, camera = ToggleCamera,
        watchResultAd = WatchResultAdBonus,
        toggleGMFreeExperience = function() return require("MixedGarage").ToggleGM(hud_) end,
        skill = function() if screen_=="ride" then pendingActions_.skill=true end end,
        watchVehicleAd = function(id)
            if screen_~="garage" or not RequireRaceProfile() or Catalog.CanFreeExperience(id) or Profile.Owns(id) then return end
            require("MixedGarage").WatchTrial(hud_,id,function()
                return screen_=="garage" and selectedVehicle_==id
            end)
        end,
        selectVehicle = function(id)
            if screen_ ~= "loading" and Catalog.Get(id) then
                if selectedVehicle_~=id then RewardedAds.Cancel();hud_.trialButton:SetDisabled(false) end
                selectedVehicle_ = id
            end
        end,
        selectRider = function(id)
            if screen_ == "loading" then return end
            selectedRider_ = id; if bike_ then bike_:SetRiderColor(id) end
        end,
        selectLaps = function(count) if screen_ ~= "loading" then selectedLaps_ = count end end,
        selectTrack = function(id)
            if screen_ == "loading" or not Tracks.Get(id) or not RequireRaceProfile(true) then return end
            if not careerRace_ and not Profile.TrackUnlocked(id) then return end
            selectedTrack_ = id
            selectedLaps_ = assert(Tracks.Get(id)).laps
            hud_:SelectLaps(selectedLaps_, false)
            print("[地图] 初选 " .. id .. "，确认出发后重建，不提前替换当前世界")
        end,
        buyVehicle = function(id)
            if not RequireRaceProfile() then return end
            local item = Catalog.Get(id)
            if not item or item.available==false then return end
            if Catalog.CanFreeExperience(id) then hud_:SelectVehicle(id,false);return end
            local ok, message = Profile.Buy(id, item.price or 0)
            hud_:RefreshOwnership()
            hud_:SelectVehicle(id, false)
            hud_.selectionMode:SetText(ok and ("已购买 " .. item.name) or message)
            if not ok then
                local missing = math.max(0, (item.price or 0) - Profile.Coins())
                hud_:ShowNotice("车辆尚未解锁", string.format("%s\n需要 %d 金币 · 当前 %d 金币\n%s", item.name or id,
                    item.price or 0, Profile.Coins(), missing > 0 and ("还差 " .. missing .. " 金币，可先参加已开放的赛车场赚取奖励。") or message))
            end
            print("[商店] " .. (item.name or id) .. "：" .. message .. "，余额 " .. tostring(Profile.Coins()))
        end,
        buyRider = function(id)
            if not RequireRaceProfile() then return end
            local price = 0
            for _, rider in ipairs(HUD.Riders) do if rider.id == id then price = rider.price or 0 end end
            local ok, message = Profile.BuyRider(id, price)
            hud_:RefreshOwnership()
            if ok then hud_:SelectRider(id, false) end
            hud_.selectionMode:SetText(ok and "已购买车手配色" or message)
            if not ok then
                local missing = math.max(0, price - Profile.Coins())
                hud_:ShowNotice("车手配色尚未解锁", string.format("需要 %d 金币 · 当前 %d 金币\n%s", price, Profile.Coins(),
                    missing > 0 and ("还差 " .. missing .. " 金币。") or message))
            end
            print("[商店] 配色 " .. id .. "：" .. message .. "，余额 " .. tostring(Profile.Coins()))
        end,
        unlockTrack = function(id)
            if not RequireRaceProfile() then return end
            local track = Tracks.Get(id)
            if not track or screen_ == "loading" then return end
            hud_:ShowTrackLock(track, Profile.Coins(), function()
                -- 显示条件不等于授权购买；只在弹窗明确确认后扣款，余额以确认时为准。
                local ok, message = Profile.UnlockTrack(id, track.price or 0)
                hud_:RefreshOwnership()
                if ok then hud_:SelectTrack(id, true) end
                hud_.selectionMode:SetText(ok and ("已解锁 " .. (track.name or id)) or message)
                print("[赛道] 确认解锁 " .. id .. "：" .. message .. "，余额 " .. tostring(Profile.Coins()))
                return ok, message
            end)
        end,
        confirmVehicle = ConfirmVehicle, backSelection = MainMenu,
        enter = function() if loadPhase_ == "await-enter" then FinishRidePreparation() end end,
        restart = RestartRide, music = ToggleRadio, toggleRadio = ToggleRadio,
        previousTrack = function() ChangeRadio(-1) end, nextTrack = function() ChangeRadio(1) end,
        effects = function()
            local enabled = sound_ and sound_:ToggleEffects() or false
            if raceAudio_ then raceAudio_:SetEffectsEnabled(enabled) end
            return enabled
        end,
        recover = function()
            if ready_ then
                if pendingChallenge_ and race_ then race_:HandleInput("recover") else sim_:Recover(world_) end
                touch_:Reset(); ClearActions()
            end
        end,
        quality = ToggleQuality,
        settings = function(open)
            if open then
                if screen_ == "ride" then SetScreen("pause") end
                SetScreen("settings")
            else SetScreen(hud_.settingsReturn or "menu") end
            SetCamera()
        end,
        retry = RetryLoading}, touch_)
    end)
    if not hudCreated then
        if restoreGM then restoreGM() end
        if restoreUnavailableProfile then restoreUnavailableProfile() end
        error(hudOrError)
    end
    hud_=hudOrError --[[@as HUD]]
    if restoreUnavailableProfile then
        local ok,message=pcall(function() require("ProfileChecks").RunUnavailableUI(hud_) end)
        restoreUnavailableProfile()
        if not ok then error(message) end
        hud_:RefreshOwnership()
    end
    local autoStart, challenge = false, false
    for _, arg in ipairs(GetArguments()) do
        if arg == "-mixedchecks" then assert(require("MixedChecks").Run()) end
        if arg == "-autotest" then autoTest_ = true end
        if arg == "-benchmark" then benchmark_ = true; autoTest_ = true end
        if arg == "-quality-high" then highQuality_ = true end
        if arg == "-nomirrors" then disableMirrors_ = true end
        if arg == "-controlchecks" then assert(require("ControlChecks").Run(hud_, touch_).passed) end
        if arg == "-profilechecks" then assert(require("ProfileChecks").Run().passed) end
        if arg == "-careerlogicchecks" then
            local checks=require("Career.Checks")
            checks.RunLogic(); checks.RunProgression(); checks.RunCloudTimeout()
        end
        if arg == "-featurechecks" then assert(require("FeatureChecks").Run().passed) end
        if arg == "-featuremapchecks" then assert(require("FeatureChecks").RealMaps(Landscape).passed) end
        if arg == "-padfeedbackchecks" then
            assert(require("RideEffects").CheckPadFeedback().passed)
            assert(RideAudio.CheckPadFeedback().passed)
        end
        if arg == "-uichecks" then
            local pending = true
            UI.RegisterGlobalComponent("RacingUICheckOnce", {Render = function()
                if not pending then return end
                pending = false
                -- 复用UI已开始的NanoVG帧，真实字体测量和Modal布局不另开渲染帧。
                assert(require("RacingUIChecks").Run(hud_).passed)
            end})
        end
        if arg == "-aichecks" then assert(require("RaceAIChecks").Run().passed) end
        if arg == "-trackchecks" then assert(require("TrackChecks").Run(Tracks.List())) end
        if arg == "-selftest" then selfTest_ = true; assert(Sim.Test()); assert(MobileControls.Test()) end
        if arg == "-ride" then autoStart = true end
        if arg == "-challenge" or arg == "-race" then autoStart, challenge = true, true; firstPerson_ = false end
        if arg == "-tracktest" then trackTest_, autoStart, challenge, firstPerson_ = true, true, true, false end
        if arg == "-racetest" then
            raceTest_, autoStart, challenge, firstPerson_ = true, true, true, false
            assert(Race.Test()); assert(Sim.TestRace()); assert(Sim.Test()); assert(MobileControls.Test())
        end
        if arg == "-raceautodrive" then raceAutodrive_, autoTest_, autoStart, challenge, firstPerson_ = true, true, true, true, false end
        local trackId = arg:match("^%-track=(.+)$")
        if trackId and Tracks.Get(trackId) then selectedTrack_ = trackId end
        local laps = arg:match("^%-laps=(%d+)$")
        if laps then selectedLaps_ = math.max(1, math.min(9, tonumber(laps) or 3)) end
        if arg == "-chase" then firstPerson_ = false end
        if arg == "-testprofile" then testProfile_ = true; firstPerson_ = false end
        if arg == "-testgarage" then testMode_ = "garage" end
        if arg == "-testtracks" then testMode_ = "tracks" end
        if arg == "-testtracklock" then testMode_ = "track-lock" end
        if arg == "-testsettings" then testMode_ = "settings" end
        if arg == "-testpause" then testMode_ = "pause" end
        if arg == "-testpausesettings" then testMode_ = "pause-settings" end
        if arg == "-testresult" then testMode_ = "result" end
        if arg == "-testraceresult" then testMode_ = "race-result" end
        if arg == "-testloading" then testMode_ = "loading"; autoStart = true end
        if arg == "-testscenery" then testScenery_ = true end
        local feature = arg:match("^%-testfeature=(.+)$")
        if feature == "boost" or feature == "ramp" then testFeature_ = feature end
        local featurePhase = arg:match("^%-testfeaturephase=(.+)$")
        if featurePhase == "approach" or featurePhase == "active" or featurePhase == "late" or featurePhase == "settled" or featurePhase == "sequence" then
            testFeaturePhase_ = featurePhase
        end
        if arg == "-testnitroshot" then testNitroShot_ = true end
        local shotDelay=arg:match("^%-testshotdelay=(%d+)$")
        if shotDelay then testShotDelay_=math.max(18,math.min(1800,tonumber(shotDelay) or 18)) end
        local shot = arg:match("^%-testshot=(.+)$")
        if shot then testShot_ = shot end
        local vehicle = arg:match("^%-vehicle=(.+)$")
        if vehicle and VehicleAssets.Vehicles[vehicle] then testVehicle_ = vehicle end
        local route = arg:match("^%-route=(.+)$")
        if route then testRoute_ = tonumber(route) or -1 end
        local lean = arg:match("^%-testlean=(.+)$")
        local pitch = arg:match("^%-testpitch=(.+)$")
        local steerAngle = arg:match("^%-teststeer=(.+)$")
        if lean then testPose_ = true; testLean_ = math.max(-55, math.min(55, tonumber(lean) or 0)) end
        if pitch then testPose_ = true; testPitch_ = math.max(-40, math.min(40, tonumber(pitch) or 0)) end
        if steerAngle then testPose_ = true; testSteer_ = math.max(-22, math.min(22, tonumber(steerAngle) or 0)) end
        local trick = arg:match("^%-testtrick=(.+)$")
        if trick == "wheelie" or trick == "burnout" then testTrick_ = trick; firstPerson_ = false end
    end
    -- 启动参数只设置初选；即使初选巡航，也要等确认后才下载。
    selectedVehicle_ = testVehicle_
    if trackTest_ then selectedTrack_ = Tracks.List()[1].id end
    hud_:SelectTrack(selectedTrack_, false)
    hud_:SelectVehicle(selectedVehicle_, false)
    SubscribeToEvent("Update", "HandleUpdate")
    SubscribeToEvent("PostUpdate", "HandlePostUpdate")
    SubscribeToEvent("InputFocus", "HandleInputFocus")
    if testShot_ ~= "" then SubscribeToEvent("PostRenderUpdate", "CaptureTestFrame") end
    if selfTest_ then
        StartRide(false)
        assert(screen_ == "garage" and loader_ == nil and preparation_ == nil, "打开车库不得开始下载")
        -- 未购买也允许浏览和预览；只有实际出发才校验权益，自测不能购买或改写玩家进度。
        hud_:SelectVehicle("cruiser", true)
        assert(selectedVehicle_ == "cruiser" and hud_.selectedVehicle == "cruiser"
            and loader_ == nil and preparation_ == nil and not ready_, "初选巡航不得开始下载或构建")
        local trials=Profile.Trials("cruiser")
        local badge=trials>0 and ("试驾剩余 "..trials.." 局") or Profile.Owns("cruiser") and "已选中"
            or ("未拥有 · "..tostring(Catalog.Get("cruiser").price or 0).." 金币")
        assert(hud_.vehicleBadges.cruiser:GetText()==badge,"巡航预览必须显示实际购买/试驾权益")
        hud_:SelectVehicle("rally", true)
        assert(selectedVehicle_ == "rally" and loader_ == nil and preparation_ == nil, "切换车型卡不得开始下载")
        hud_:SelectVehicle(testVehicle_, true)
        MainMenu()
        print("[流程验收] 开始→车库→初选巡航→切换车型均不下载，等待确认才准备")
    end
    if testMode_ == "settings" then hud_:OpenSettings()
    elseif testMode_ == "garage" then StartRide(false)
    elseif testMode_ == "tracks" or testMode_ == "track-lock" then
        hud_:OpenTracks()
        if testMode_ == "track-lock" then
            hud_:ShowTrackLock(assert(Tracks.Get("lake")), 0, function()
                error("锁图截图不得购买或写入玩家存档")
            end)
        end
    elseif autoStart then StartRide(challenge); ConfirmVehicle(testVehicle_) end
    -- 剧情暂未开放：不创建外卖会话，不读取或覆盖旧剧情存档。
    careerMode_,careerRace_=false,false
    hud_:SetCareerRace(false)
    hud_.root:SetVisible(true)
    UI.SetRoot(hud_.root)
    if restoreGM then
        local ok,message=pcall(function()
            local checks=require("GMChecks");assert(checks.Run(hud_,gmStorage))
            for _,arg in ipairs(GetArguments()) do
                if arg=="-gmdrivechecks" then checks.RunDrive(hud_,gmStorage,restoreGM);return end
            end
            restoreGM()
        end)
        if not ok then restoreGM();error(message) end
    end
    print("[公路狂飙] 默认混合赛车；剧情模式暂未开放；旧存档保留")
end

-- 仅显式-racetest启用，走真实页面入口验证暂停、缓存重赛和模式切换。
local function CheckRaceFlow()
    if not raceTest_ or not race_ or not raceVisuals_ then return end
    raceCheckFrames_ = raceCheckFrames_ + 1
    if raceCheckStage_ == 0 and screen_ == "ride" and race_.phase == "countdown" then
        raceCheckElapsed_, raceCheckCountdown_ = race_.elapsed, race_.countdown
        raceCheckAI_, raceCheckPolice_ = race_.racers[1].s, race_.pursuit.s
        PauseRide()
        raceCheckStage_, raceCheckFrames_ = 1, 0
    elseif raceCheckStage_ == 1 and raceCheckFrames_ >= 5 then
        assert(screen_ == "pause" and race_.elapsed == raceCheckElapsed_ and race_.countdown == raceCheckCountdown_
            and race_.racers[1].s == raceCheckAI_ and race_.pursuit.s == raceCheckPolice_, "暂停必须冻结倒计时、AI和追车")
        PauseRide()
        raceCheckStage_ = 2
    elseif raceCheckStage_ == 2 and screen_ == "ride" and race_.elapsed > 1 then
        raceCheckElapsed_, raceCheckCountdown_ = race_.elapsed, race_.countdown
        raceCheckAI_, raceCheckPolice_ = race_.racers[1].s, race_.pursuit.s
        PauseRide()
        raceCheckStage_, raceCheckFrames_ = 3, 0
    elseif raceCheckStage_ == 3 and raceCheckFrames_ >= 5 then
        assert(race_.elapsed == raceCheckElapsed_ and race_.racers[1].s == raceCheckAI_
            and race_.pursuit.s == raceCheckPolice_, "暂停必须冻结比赛时间、对手与警车")
        PauseRide()
        testWorld_, testAudio_ = world_, sound_
        RestartRide()
        assert(loadPhase_ == "reuse", "同车重赛必须命中缓存复用")
        raceCheckStage_ = 4
    elseif raceCheckStage_ == 4 and screen_ == "ride" then
        assert(world_ == testWorld_ and sound_ == testAudio_ and preparationsStarted_ == 1,
            "重赛不得重新构建世界或驾驶音频")
        assert(race_.phase == "countdown" and race_.elapsed == 0 and race_.player.nitro == 100,
            "重赛必须清空时间、危险值并恢复氮气")
        MainMenu(); StartRide(false); ConfirmVehicle(selectedVehicle_)
        raceCheckStage_ = 5
    elseif raceCheckStage_ == 5 and screen_ == "ride" then
        assert(not sim_.raceMode and not raceVisuals_.root.enabled and not hud_.hasRace,
            "自由练习不得保留AI或追逐规则")
        MainMenu(); StartRide(true); ConfirmVehicle(selectedVehicle_)
        raceCheckStage_ = 6
    elseif raceCheckStage_ == 6 and screen_ == "ride" then
        assert(sim_.raceMode and raceVisuals_.root.enabled and race_.phase == "countdown"
            and world_ == testWorld_ and preparationsStarted_ == 1, "练习切竞速必须恢复比赛且复用世界")
        raceCheckStage_ = 7
        print("[竞速流程验收] 倒计时与比赛暂停冻结、同车重赛、练习切竞速、世界复用通过")
    elseif raceCheckStage_ == 7 and screen_ == "result" then
        assert(race_.phase == "finished" and #race_.results == 9 and race_.player.eliminated,
            "停驶被追捕后必须进入九人结算页")
        raceCheckStage_ = 8
        print("[竞速流程验收] 实际停驶追捕与九人结算通过")
    end
end

-- 六图验收走真实选图/加载/发车入口，不直接给现有世界替换路线表。
local function CheckTrackFlow()
    if not trackTest_ or screen_ ~= "ride" or not race_ then return end
    trackCheckFrames_ = trackCheckFrames_ + 1
    if trackCheckFrames_ < 12 then return end
    local entry = assert(Tracks.List()[trackCheckIndex_])
    assert(selectedTrack_ == entry.id and loadedTrack_ == entry.id and Landscape.activeId == entry.id,
        "选图、已加载世界与Landscape身份不一致")
    assert(world_.landscape == Landscape and sim_.landscape == Landscape
        and math.abs(race_.length - entry.length) < 0.1, "赛道切换后仿真或比赛仍使用旧路线")
    assert(hud_.trackMap.routeReady and math.abs(hud_.trackMap.routeLength - entry.length) < 0.1,
        "小地图未重新采样选中赛道")
    assert(raceVisuals_ and raceVisuals_:GetStats().rivals == 8, "切图后必须仍有八名真实对手")
    assert((#world_.traffic > 0) == entry.traffic, "封闭赛场与公路交通规则不一致")
    if previousTrackWorld_ then
        assert(world_ ~= previousTrackWorld_ and sound_ ~= previousTrackAudio_, "换图必须释放并重建世界和音源")
        assert(previousTrackAudio_ and previousTrackAudio_.stopped, "换图不得留下上一地图音源")
    end
    print(string.format("[六图流程验收] %s %.1fm 世界=%d 交通=%d AI=8 小地图=正确",
        entry.id, race_.length, preparationsStarted_, #world_.traffic))
    if trackCheckIndex_ == #Tracks.List() then
        assert(preparationsStarted_ == #Tracks.List(), "每图必须且只能创建一次世界")
        print("[六图流程验收] 六次选图→完整重建→新比赛→新小地图全部通过")
        engine:Exit()
        return
    end
    previousTrackWorld_, previousTrackAudio_ = world_, sound_
    trackCheckIndex_, trackCheckFrames_ = trackCheckIndex_ + 1, 0
    MainMenu(); StartRide(true)
    hud_:SelectTrack(Tracks.List()[trackCheckIndex_].id, true)
    ConfirmVehicle(selectedVehicle_)
    assert(loadPhase_ == "download-pending", "同车换图不得误用旧世界缓存")
end

---@param eventType string
---@param eventData UpdateEventData
function HandleUpdate(eventType, eventData)
    local rawDt = eventData:GetFloat("TimeStep")
    if careerMode_ then CareerStore.UpdateCloud(rawDt) end
    local dt = math.min(rawDt, 0.1)
    -- 广告超时兜底由主循环统一驱动；生涯模式暂停竞速逻辑但广告仍需要超时恢复。
    RewardedAds.Update(dt)
    if Profile.HasPendingSave() then
        profileRetrySeconds_=profileRetrySeconds_+dt
        if profileRetrySeconds_>=5 then
            profileRetrySeconds_=0
            local saved=Profile.RetryPendingSave()
            if saved then
                print("[竞速进度] 待保存奖励已成功补存")
                if resultRewardPending_ and not careerMode_ and hud_ and hud_.screen=="result" then
                    hud_:SetResultReward(string.format("奖励已保存 · 余额 %d 金币",Profile.Coins()))
                end
                resultRewardPending_=false
            end
        end
    else profileRetrySeconds_=0 end
    if careerMode_ and career_ then
        CareerQuality.Update(rawDt)
        career_:Update(dt)
        return
    end
    -- 暂停/设置/模态会提前返回，但循环声和短音包络仍必须消费静音状态。
    if screen_~="ride" or hud_:IsModalOpen() then
        if sound_ then sound_:Update(dt,sim_ --[[@as RideAudioState]],"pause") end
        if raceAudio_ then raceAudio_:Update(dt,sim_,pendingChallenge_ and race_ or nil,false) end
    end
    clock_ = clock_ + dt
    local portrait = graphics:GetHeight() > graphics:GetWidth()
    if portrait ~= portrait_ then
        portrait_ = portrait
        hud_:SetPortrait(portrait)
        if portrait and screen_ == "ride" then SetScreen("pause") end
    end
    if screen_ == "loading" then
        loadingFrames_ = loadingFrames_ + 1
        if loader_ and loadPhase_ == "downloading" then loader_:Update() end
        -- 先绘制遮罩，避免本地缓存同步命中时用户看不到准备阶段。
        if loadPhase_ == "download-pending" and loadingFrames_ > 2 then BeginDownload()
        elseif loadPhase_ == "reuse" and loadingFrames_ > 2 then FinishRidePreparation()
        elseif loadPhase_ == "building" and preparation_ then
            local ok, message = coroutine.resume(preparation_)
            if not ok then LoadingError(tostring(message)); preparation_ = nil end
        elseif loadPhase_ == "ready" then
            if autoTest_ or selfTest_ or raceTest_ or trackTest_ or careerRaceCheck_ or testShot_ ~= "" then FinishRidePreparation()
            else
                loadPhase_ = "await-enter"
                hud_:SetLoading(assert(Tracks.Get(loadedTrack_)).name .. "已准备好", "点击出发，在真实触摸中启用声音。", 1, "全部资源可用 · 双手握稳")
                hud_.enterRide:SetVisible(true)
            end
        end
        return
    end
    hud_:UpdateLayout()
    if careerRaceCheck_ and ready_ and race_ then
        if careerRaceCheckStage_==0 and screen_=="ride" then
            careerRaceCheckFrames_=careerRaceCheckFrames_+1
            if careerRaceCheckFrames_>=5 then
                assert(selectedLaps_==2 and #world_.traffic==0)
                require("Career.Checks").DriveRace(race_,sim_)
                careerRaceCheckStage_=1
            end
        elseif careerRaceCheckStage_==1 and screen_=="result" then
            local p=CareerStore.Get()
            assert(p.career and not p.career.pending and p.career.points>0)
            local cash=p.cashCents
            RestartRide()
            assert(careerMode_ and not careerRace_ and not scene_ and not ready_)
            assert(CareerStore.Get().cashCents==cash)
            print("[生涯主入口验收通过] 真实加载/职业圈数/合法完赛/自动结算/结果返回/无免费重赛/释放赛道")
            engine:Exit(); return
        end
    end
    if hud_:IsModalOpen() then
        if input:GetKeyPress(KEY_ESCAPE) then hud_:CloseModal() end
        -- 模态期间键盘与触摸一致冻结，不允许Enter确认底层页面或W继续驾驶。
        return
    end
    if screen_ == "settings" then
        if input:GetKeyPress(KEY_ESCAPE) or input:GetKeyPress(KEY_P) then hud_:CloseSettings() end
        return
    end
    if input:GetKeyPress(KEY_RETURN) and screen_ == "menu" then StartRide(true); return end
    if not ready_ then return end
    if selfTest_ and screen_ == "ride" then
        checkFrames_ = checkFrames_ + 1
        if checkStage_ == 0 and checkFrames_ >= 5 then
            checkStage_ = -1
            ValidateSelectedVehicle(testVehicle_)
            assert(require("MobileChecks").Run(hud_, touch_, sound_).passed)
            HandleInputFocus("InputFocus", {GetBool = function(_, field) return field == "Minimized" end} --[[@as InputFocusEventData]])
            assert(screen_ == "pause" and not touch_.gas and touch_.steer == 0, "失焦暂停失效")
            PauseRide()
            checkStage_ = 1
        elseif checkStage_ == 1 and checkFrames_ >= 30 then
            RestartRide(); checkStage_ = 2; return
        elseif checkStage_ == 2 then
            assert(preparationsStarted_ == 1 and sim_.elapsed < 0.2, "重开不应重复构建或保留进度")
            assert(not touch_.gas and not touch_.brake and touch_.steer == 0)
            ValidateSelectedVehicle(testVehicle_)
            checkStage_ = 3
            print("[手机验收] 失焦、恢复、缓存重开仅构建一次通过")
        elseif checkStage_ == 3 and checkFrames_ >= 60 then
            StartRide(false); hud_:SelectVehicle("rally", true); ConfirmVehicle("rally")
            checkStage_ = 4; return
        elseif checkStage_ == 4 then
            ValidateSelectedVehicle("rally")
            StartRide(false)
            local previousLoader, previousPhase = loader_, loadPhase_
            hud_:SelectVehicle("cruiser", true)
            assert(selectedVehicle_ == "cruiser" and loader_ == previousLoader and loadPhase_ == previousPhase,
                "已载入世界中的巡航卡片也不得提前下载")
            ConfirmVehicle("cruiser")
            assert(screen_ == "loading" and loadPhase_ == "download-pending", "确认巡航后才应进入加载流程")
            checkStage_ = 5; return
        elseif checkStage_ == 5 then
            ValidateSelectedVehicle("cruiser")
            assert(sim_.elapsed < 0.2, "巡航出发不得保留上一旅程进度")
            StartRide(false); hud_:SelectVehicle("sport", true); ConfirmVehicle("sport")
            checkStage_ = 6; return
        elseif checkStage_ == 6 then
            ValidateSelectedVehicle("sport")
            assert(sim_.elapsed < 0.2, "切回仿赛不得保留上一旅程进度")
            local oldQuality = highQuality_
            ToggleQuality(); assert(highQuality_ ~= oldQuality)
            ToggleQuality(); assert(highQuality_ == oldQuality)
            checkStage_ = 7
            print("[选车验收] " .. testVehicle_ .. "→拉力→巡航→仿赛，仅重建车型；世界一次、六音源身份复用、三车型±22度实骨骼与双视角、画质双向切换通过")
        end
    end
    if input:GetKeyPress(KEY_P) or input:GetKeyPress(KEY_ESCAPE) then PauseRide() end
    if input:GetKeyPress(KEY_C) then ToggleCamera() end
    if input:GetKeyPress(KEY_R) and screen_ == "ride" then RestartRide(); return end
    if screen_ == "ride" then
        local steer = touch_.steer
        if input:GetKeyDown(KEY_A) or input:GetKeyDown(KEY_LEFT) then steer = -1 end
        if input:GetKeyDown(KEY_D) or input:GetKeyDown(KEY_RIGHT) then steer = 1 end
        local throttle = touch_.throttle or (touch_.gas and 1 or 0)
        if input:GetKeyDown(KEY_W) or input:GetKeyDown(KEY_UP) then throttle = 1 end
        local brake = touch_.brake or input:GetKeyDown(KEY_S) or input:GetKeyDown(KEY_DOWN) or input:GetKeyDown(KEY_SPACE)
        local pulses = touch_:ConsumeActions()
        for key in pairs(pendingActions_) do pendingActions_[key] = pendingActions_[key] or pulses[key] == true end
        pendingActions_.skill = pendingActions_.skill or input:GetKeyPress(KEY_E)
        pendingActions_.nitro = pendingActions_.nitro or input:GetKeyPress(KEY_SHIFT)
        pendingActions_.spin180 = pendingActions_.spin180 or input:GetKeyPress(KEY_X)
        pendingActions_.spin360 = pendingActions_.spin360 or input:GetKeyPress(KEY_V)
        local nitro = touch_.nitro or input:GetKeyDown(KEY_SHIFT)
        if autoTest_ and not raceAutodrive_ then throttle = 0.7; steer = math.sin(sim_.elapsed * 0.6) * 0.09 end
        if testFeature_ ~= "" then throttle, steer = 0.8, 0 end
        if raceAutodrive_ then
            local route = Landscape.NearestRoad(sim_.x, sim_.z)
            local target = Landscape.RoadPoint(route + math.max(10, sim_.speed * 0.55))
            local desired = math.deg(math.atan(target.x - sim_.x, target.z - sim_.z))
            local delta = (desired - sim_.heading + 180) % 360 - 180
            steer = math.max(-1, math.min(1, delta / 30))
            throttle, brake = math.abs(delta) > 35 and 0.25 or 0.8, math.abs(delta) > 60 and sim_.speed > 20
        end
        -- 结算实拍专用参数只加速固定步数量，追捕规则和判定阈值不变。
        -- dt已在上面钳到0.1秒，最多5步；不会出现一帧跑几十步的死循环。
        accumulator_ = accumulator_ + dt * (testMode_ == "race-result" and 20 or 1)
        accumulator_ = math.min(accumulator_, 0.1)
        while accumulator_ >= 0.02 do
            rideInput_.steer, rideInput_.throttle, rideInput_.brake = steer, throttle, brake
            rideInput_.wheelie = touch_.wheelie or input:GetKeyDown(KEY_Q) or testTrick_ == "wheelie"
            rideInput_.burnout = touch_.burnout or input:GetKeyDown(KEY_Z) or testTrick_ == "burnout"
            rideInput_.spin180, rideInput_.spin360 = pendingActions_.spin180, pendingActions_.spin360
            rideInput_.skill = pendingActions_.skill or (autoTest_ and require("MixedVehicles").Get(selectedVehicle_)~=nil and (sim_.oddCooldown or 0)<=0)
            rideInput_.nitro = nitro or pendingActions_.nitro
            if pendingChallenge_ and race_ then
                Profile_.Begin("raceBefore")
                local drive = race_:BeforeStep(0.02, rideInput_)
                Profile_.End()
                if race_.phase == "racing" then
                    Profile_.Begin("worldUpdate")
                    world_:Update(0.02, sim_.distance, race_.elapsed, sim_.x, sim_.z)
                    Profile_.End()
                    Profile_.Begin("simStep")
                    sim_:Step(0.02, drive, world_)
                    Profile_.End()
                end
                Profile_.Begin("raceAfter")
                race_:AfterStep(0.02)
                Profile_.End()
            else
                world_:Update(0.02, sim_.distance, clock_, sim_.x, sim_.z)
                sim_:Step(0.02, rideInput_, world_)
            end
            for key in pairs(pendingActions_) do pendingActions_[key] = false end
            accumulator_ = accumulator_ - 0.02
            local finished = sim_.finished or (pendingChallenge_ and race_ and race_.phase == "finished")
            if finished then accumulator_ = 0; break end
        end
        local finished = sim_.finished or (pendingChallenge_ and race_ and race_.phase == "finished")
        if finished and not resultShown_ then
            resultShown_ = true
            resultRewardPending_=false
            local careerResultMessage=""
            if careerRace_ and race_ and race_.player then
                local _,message=SettleCareerResult()
                careerResultMessage=message
            elseif pendingChallenge_ and race_ and race_.player then
                -- 名次越高金币越多；被抓按末位结算，仍给参与奖励。
                local place = race_.player.rank or 9
                local track = Tracks.Get(selectedTrack_)
                local reward = Profile.RaceReward(place, selectedLaps_, track and track.reward or 120)+math.floor(sim_.oddPickups or 0)
                local unlocks={}
                if place==1 then
                    for _,item in ipairs(Tracks.List()) do
                        if item.requires==selectedTrack_ and not Profile.TrackUnlocked(item.id) then unlocks[#unlocks+1]=item.id end
                    end
                end
                local saved, saveMessage, applied = Profile.GrantRaceRewards(reward,unlocks)
                resultRewardPending_=applied and not saved
                if not saved then
                    careerResultMessage=(saveMessage or "奖励未入账")
                        ..(applied and "；奖励待保存，请勿退出，系统将自动重试。" or "；本次奖励未入账，原余额未修改。")
                end
                sim_.coinsEarned = applied and reward or 0
                print(string.format("[奖励] 第%d名 · %s · +%d金币，余额 %d", place,
                    track and track.name or selectedTrack_, sim_.coinsEarned, Profile.Coins()))
                if applied and #unlocks>0 then
                    local message="夺冠解锁下一赛道"..(saved and " · 已保存" or " · 权益待保存，请勿退出")
                    careerResultMessage=(careerResultMessage~="" and careerResultMessage.."\n" or "")..message
                    print("[解锁] "..message)
                end
                hud_:RefreshOwnership()
            end
            SetScreen("result")
            hud_:ShowResult(sim_)
            OfferResultAdBonus(math.floor(sim_.coinsEarned or 0))
            if careerResultMessage~="" then
                hud_:SetResultReward(careerResultMessage..(careerRace_ and "\n奖金计入生涯现金，不发放旧竞速金币。" or ""))
            elseif not careerRace_ and (sim_.coinsEarned or 0)>0 then
                hud_:SetResultReward(string.format("本场金币 +%d · 余额 %d 金币",sim_.coinsEarned,Profile.Coins()))
            end
        end
    end
    Profile_.Begin("bikeUpdate")
    bike_:UpdateState(screen_ == "ride" and dt or 0, sim_, CockpitActive(), clock_)
    Profile_.End()
    if testPose_ and screen_ == "ride" then
        -- 改真实Bike父节点，保持握把和骑手一起变换；不是单独摆一张人物预览。
        bike_.visual.rotation = Quaternion(-testPitch_, 0, testLean_ * bike_.leanSign)
        bike_.steering.rotation = Quaternion(0, testSteer_, 0)
        bike_.riderRig:Update(testSteer_, true, testLean_)
    end
    if pendingChallenge_ and raceVisuals_ then
        Profile_.Begin("raceVisuals")
        raceVisuals_:Update(screen_ == "ride" and dt or 0, sim_)
        Profile_.End()
    end
    if raceAudio_ then
        Profile_.Begin("raceAudio")
        raceAudio_:Update(dt, sim_, pendingChallenge_ and race_ or nil, screen_ == "ride" or screen_ == "result")
        Profile_.End()
    end
    sound_.musicDuck=raceAudio_ and raceAudio_:GetMusicDuck() or 1
    Profile_.Begin("sound")
    sound_:Update(dt, sim_ --[[@as RideAudioState]], screen_)
    Profile_.End()
    Profile_.Begin("hud")
    hud_:Update(dt, sim_, firstPerson_)
    Profile_.End()
    CheckRaceFlow()
    CheckTrackFlow()
    Profile_.Tick(dt)
end

---@param eventType string
---@param eventData InputFocusEventData
function HandleInputFocus(eventType, eventData)
    if not eventData:GetBool("Focus") or eventData:GetBool("Minimized") then
        if careerMode_ and career_ then
            career_.view:ResetInput()
            if career_.running and not career_.view:IsBlocking() then career_:Pause() end
            return
        end
        touch_:Reset(); ClearActions()
        if screen_ == "ride" then SetScreen("pause") end
        print("[手机操作] 失去焦点，清空所有持续操作与特技脉冲")
    end
end

---@param eventType string
---@param eventData PostUpdateEventData
function HandlePostUpdate(eventType, eventData)
    if careerMode_ and career_ then
        career_:PostUpdate(math.min(eventData:GetFloat("TimeStep"),.1))
        return
    end
    if screen_ == "settings" then return end
    if not ready_ or not bike_ or not chase_ or not helmetCamera_ then return end
    local dt = math.min(eventData:GetFloat("TimeStep"), 0.1)
    if benchmark_ and screen_ == "ride" then
        benchmarkWarmup_ = benchmarkWarmup_ + 1
        if benchmarkWarmup_ > 60 then
            benchmarkFrames_ = benchmarkFrames_ + 1
            benchmarkTimes_[benchmarkFrames_] = eventData:GetFloat("TimeStep") * 1000
            -- 引擎日志自带毫秒墙钟时间戳，外部相邻采样差才是实际帧耗时。
            print(string.format("[渲染采样] %d batches=%d primitives=%d", benchmarkFrames_, renderer.numBatches, renderer.numPrimitives))
            if benchmarkFrames_ == 180 then
                table.sort(benchmarkTimes_)
                local sum = 0
                for _, time in ipairs(benchmarkTimes_) do sum = sum + time end
                print(string.format("[渲染性能] 档位=%s 仿真TimeStep mean=%.2fms p95=%.2fms；实际墙钟帧时以[渲染采样]日志时间戳计算，batches=%d primitives=%d",
                    highQuality_ and "画质" or "流畅", sum / 180, benchmarkTimes_[171],
                    renderer.numBatches, renderer.numPrimitives))
                engine:Exit()
                return
            end
        end
    end
    if testProfile_ then
        chase_:SetMode("profile")
        chase_:Update(1, bike_.node, sim_.heading - 90, 3)
    elseif screen_ == "menu" or screen_ == "garage" then
        chase_:Update(dt, bike_.node, sim_.heading - 145 + math.sin(clock_ * 0.1) * 3, 7)
    else
        local delta = (sim_.heading - lastYaw_ + 180) % 360 - 180
        lastYaw_ = lastYaw_ + delta * math.min(1, dt * 5)
        chase_:SetMode(sim_.speed > 38 and "fast" or "normal")
        chase_:Update(dt, bike_.node, lastYaw_, 9)
        -- 两种来源独立授权表现：氮气真实推力、加速带真实增益脉冲；不回写仿真。
        if screen_ == "ride" then
            local padPower = sim_.featureState and sim_.featureState.feedbackPower or 0
            local targetBoost = math.max(math.max(0, math.min(1, sim_.raceBoost or 0)) * 9,
                math.max(0, math.min(1, padPower)) * 7)
            boostFov_ = boostFov_ + (targetBoost - boostFov_) * (1 - math.exp(-dt * 12))
        end
        local chaseCamera = chase_:GetCamera()
        chaseCamera.fov = chaseCamera.fov + boostFov_
        helmetCamera_.fov = bike_.Cockpit.fov + math.min(6, sim_.speed * 0.1) + boostFov_
    end
    bike_:UpdateMirrors(dt, screen_ == "ride" and firstPerson_ and not disableMirrors_)
    local position = helmetCamera_:WorldToScreenPoint(bike_:GetDashboardWorldPosition())
    local scale = UI.GetScale()
    local visible = CockpitActive() and screen_ == "ride" and position.x > 0 and position.x < 1 and position.y > 0 and position.y < 1
    hud_:UpdateCockpit(position.x * graphics:GetWidth() / scale, position.y * graphics:GetHeight() / scale,
        visible, sim_.speed * 3.6, sim_.gear, sim_.rpm)
end

-- 只对显式隔离验收启用。资源下载/校验帧数不定，必须等场景真正就绪再拍，
-- 不能用固定全局帧号把加载页当作动作或应用截图。
function CaptureCareerReadyFrame()
    if not careerMode_ or not career_ or not career_.options.test
        or career_.loading or not career_.running or not career_.actor then return end
    if careerReadyShot_=="" and not career_.options.lifeAudit then return end
    careerReadyFrames_=careerReadyFrames_+1
    local required=career_.options.lifeAudit and 24 or 8
    if careerReadyFrames_~=required then return end
    if career_.options.lifeAudit then require("Career.LifeChecks").Audit(career_) end
    if careerReadyShot_=="" then return end
    local image=Image()
    local captured=graphics:TakeScreenShot(image)
    local saved=captured and image:SavePNG(careerReadyShot_)
    image:Dispose()
    assert(saved,"就绪场景实拍未写出图片："..careerReadyShot_)
    print("[生涯就绪实拍完成] "..careerReadyShot_.." / ready后"..required.."渲染帧 / 内存档")
    engine:Exit()
end

function CaptureTestFrame()
    -- 完整选车自测优先；全部通过后才开始截图计帧，避免首车型截图提前退出。
    if selfTest_ and checkStage_ ~= 7 then return end
    if testMode_ == "loading" then
        if screen_ ~= "loading" or loadPhase_ ~= "building" then return end
    elseif screen_ == "loading" then return end
    if testMode_ == "race-result" and screen_ ~= "result" then return end
    if testNitroShot_ then
        local nitroVisible=false
        if race_ and race_.phase=="racing" then
            for _,racer in ipairs(race_.racers) do
                if not racer.isPlayer and racer.driveSim and racer.driveSim.raceBoost > 0.5 then
                    local dx,dz=racer.x-sim_.x,racer.z-sim_.z
                    if dx*dx+dz*dz<70*70 then nitroVisible=true;break end
                end
            end
        end
        if not nitroVisible then return end
    end
    local featurePhase = testFeaturePhase_ == "sequence" and featureShotPhases_[testFeatureFrame_] or testFeaturePhase_
    if testFeature_ ~= "" then
        if testFeatureDone_ or screen_ ~= "ride" then return end
        -- 发车页面切换当帧的帧缓冲仍可能是加载页，至少经过一次实际驾驶更新再截接近画面。
        if featurePhase == "approach" and sim_.elapsed < 0.1 then return end
        local featureState = sim_.featureState
        if testFeature_ == "ramp" then
            if sim_.airborne then testFeatureAirborne_ = true end
            if featurePhase == "settled" then
                if not testFeatureAirborne_ or sim_.airborne then return end
            elseif featurePhase ~= "approach" then
                local minimumAir = featurePhase == "late" and 0.50 or 0.18
                if not sim_.airborne or sim_.airTime < minimumAir or sim_.y - sim_.groundY < 0.65 then return end
            end
        elseif featurePhase ~= "approach" then
            if featureState.triggers < 1 then return end
            if featurePhase == "settled" then
                if (featureState.feedbackTimer or 0) > 0 or sim_.elapsed < 1.8 then return end
            else
                local threshold = featurePhase == "late" and 0.55 or 1.20
                if (featureState.feedbackTimer or 0) > threshold then return end
            end
        end
        testFeatureDone_ = true
        print(string.format("[机关实拍触发] %s/%s airborne=%s airTime=%.2f y=%.3f speed=%.2f pad=%.2f nitro=%.2f fov=%.2f",
            testFeature_, featurePhase, tostring(sim_.airborne), sim_.airTime or 0, sim_.y, sim_.speed,
            featureState.feedbackPower or 0, sim_.raceBoost or 0, boostFov_))
    end
    if testTrick_ ~= "" and sim_.elapsed < 3 then return end
    if testScenery_ then hud_.root:SetVisible(false) end
    captureFrames_ = captureFrames_ + 1
    local frameTarget = testMode_ == "loading" and 5 or ((testNitroShot_ or testFeature_ ~= "") and 1 or testShotDelay_)
    if captureFrames_ ~= frameTarget then return end
    if testTrick_ ~= "" then
        if testTrick_ == "wheelie" then
            assert(sim_.wheelieAngle > 15, "实拍验收：单键翘头没有抬起前轮")
        else
            assert(sim_.burnout and sim_.tireSmoke > 0.1, "实拍验收：单键烧胎没有进入冒烟状态")
        end
        print(string.format("[实拍特技] %s speed=%.2f wheelie=%.2f smoke=%.2f", testTrick_, sim_.speed, sim_.wheelieAngle, sim_.tireSmoke))
    end
    local image = Image()
    local output = testFeaturePhase_ == "sequence" and testShot_:gsub("%.png$", "-" .. featurePhase .. ".png") or testShot_
    if graphics:TakeScreenShot(image) then print("[验收] 截图 " .. tostring(image:SavePNG(output)) .. " / " .. output) end
    image:Dispose()
    if testFeature_ ~= "" and testFeaturePhase_ == "sequence" and testFeatureFrame_ < #featureShotPhases_ then
        testFeatureFrame_ = testFeatureFrame_ + 1
        testFeatureDone_, captureFrames_ = false, 0
        return
    end
    engine:Exit()
end

function Stop()
    RewardedAds.Cancel();Catalog.SetGMFreeExperience(false)
    if career_ then career_:Dispose(); career_=nil end
    if loader_ then loader_:Cancel() end
    touch_:SetEnabled(false)
    if sound_ then sound_:Stop() end
    if raceAudio_ then raceAudio_:Dispose() end
    if raceVisuals_ then raceVisuals_:Dispose() end
    if race_ then race_:Stop() end
    if hud_ then hud_:Dispose() end
    UnsubscribeFromAllEvents()
    UI.Shutdown()
    if chase_ then chase_:GetNode():Dispose() end
    if bike_ then bike_:Dispose() end
    if scene_ then scene_:Dispose() end
end
