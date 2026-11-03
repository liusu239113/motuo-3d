-- 独立驾驶音频管理：只管理自己的音源，不修改全局音量，也不订阅游戏事件。
-- 加载阶段逐次调用 LoadOne；用户点击开始时调用 Unlock；每帧（含暂停）调用 Update。

---@class RideAudioState
---@field speed number 速度，单位米/秒
---@field rpm number 发动机转速
---@field throttle number 油门，范围 0 到 1
---@field braking boolean 是否制动
---@field health number 车况
---@field overtakes number 累计超车次数
---@field elapsed number 本局累计时间，用于识别重新开始
---@field finished boolean 是否结束
---@field vehicle? table 当前车型怠速与红线转速
---@field vehicleId? string
---@field burnout? boolean 是否烧胎
---@field paused? boolean
---@field featureState? table 只读成功加速带反馈：triggers/lastGain/feedbackTimer/feedbackPower

---@class RideAudio
---@field Resources string[] 静态资源清单，索引从 1 开始
---@field Count integer 静态资源数量
---@field scene Scene?
---@field node Node?
---@field sounds table<number, Sound?>
---@field sources table<number, SoundSource?>
---@field pitches table<number, number>
---@field musicEnabled boolean
---@field musicDuck? number 语音期间的音乐目标系数；不累乘源增益
---@field effectsEnabled boolean
---@field unlocked boolean
---@field stopped boolean
---@field trackIndex integer
---@field previousSim RideAudioState?
---@field previousHealth number
---@field previousOvertakes number
---@field previousElapsed number
---@field previousScreen string
---@field engineClass string
---@field engineProfile table?
---@field engineSounds table<string, Sound>
---@field engineSoundFailures table<string, boolean>
---@field engineLayerSource SoundSource?
---@field engineLayerSound Sound?
---@field engineLayerClass string
---@field outputWarningShown boolean
---@field padSource SoundSource? 独立短whoosh，不占用/改变原六通道
---@field padTimer number
---@field padGain number
---@field padSim RideAudioState?
---@field padState table?
---@field padSequence number
---@field padElapsed number
local RideAudio = {}
RideAudio.__index = RideAudio

-- 上传素材仅无损重封装为 OGG；音乐统一复用一个音源，不与驾驶音效混用。
RideAudio.Resources = {
    "audio/radio_01.ogg",
    "audio/sfx/motorcycle_engine_loop.mp3",
    "audio/sfx/highway_wind_loop.mp3",
    "audio/sfx/motorcycle_brake_loop.mp3",
    "audio/sfx/motorcycle_impact.mp3",
    "audio/sfx/motorcycle_pass.mp3",
    "audio/radio_02.ogg",
    "audio/night_ride.ogg",
    -- 三种独立发动机与电动车电机；混合载具按原型复用。
    "audio/sfx/race_engine_sport_inline4.mp3",
    "audio/sfx/race_engine_cruiser_vtwin.mp3",
    "audio/sfx/race_engine_rally_twin.mp3",
    "audio/sfx/career_ebike_motor.mp3",
}
RideAudio.Tracks = {
    {title = "骑行歌单 01", resource = 1},
    {title = "骑行歌单 02 · 长混音", resource = 7},
    {title = "夜驰 · 原创电台", resource = 8},
}
RideAudio.Count = #RideAudio.Resources
-- 独立录制的三种发动机；不改Resources 1..8索引、不新增基础音源。
RideAudio.EngineResources = {
    sport = "audio/sfx/race_engine_sport_inline4.mp3",
    cruiser = "audio/sfx/race_engine_cruiser_vtwin.mp3",
    rally = "audio/sfx/race_engine_rally_twin.mp3",
    -- 电动车/机械载具复用真实录音，但按下表使用独立音高与音量包络区分音色。
    electric = "audio/sfx/career_ebike_motor.mp3",
    heavy = "audio/sfx/motorcycle_engine_loop.mp3",
    turbine = "audio/sfx/race_engine_sport_inline4.mp3",
}

-- 每台载具 -> 声音原型 + 音高/音量个性。同一原型用不同基频和增益，听感可区分。
RideAudio.MixedEngineResources = {
    ebike      = "electric",
    tank       = "heavy",
    beetle     = "heavy",
    hovercraft = "turbine",
    centipede  = "heavy",
    buggy      = "rally",
    jellyfish  = "turbine",
    loader     = "heavy",
    cicada     = "rally",
    jetboat    = "turbine",
    frog       = "rally",
    skateboard = "rally",
    helicopter = "turbine",
    sled       = "sport",
    cart       = "rally",
    bathtub    = "cruiser",
    office     = "sport",
    toilet     = "sport",
}

-- 原型基频倍率：低=沉厚机械，高=高转机械/涡轮。
RideAudio.EnginePitch = {
    sport = 1.00, cruiser = 0.72, rally = 0.86,
    electric = 1.35, heavy = 0.55, turbine = 1.55,
}

-- 车型声学配置：primary 使用已有发动机录音，layer 只为重型/飞行载具增加低频或气流层。
-- 所有值都是相对于录音原始采样率的倍率；实际传给 SoundSource 的仍是绝对 Hz。
RideAudio.VehicleEngineProfiles = {
    sport = {class = "sport", pitch = 1.00, gain = 1.00, layer = nil},
    sport_2 = {class = "sport", pitch = 1.06, gain = 0.98, layer = nil},
    sport_3 = {class = "sport", pitch = 1.12, gain = 0.96, layer = nil},
    cruiser = {class = "cruiser", pitch = 0.88, gain = 1.05, layer = "bass", layerGain = 0.16, layerPitch = 0.50},
    cruiser_2 = {class = "cruiser", pitch = 0.82, gain = 1.08, layer = "bass", layerGain = 0.19, layerPitch = 0.46},
    cruiser_3 = {class = "cruiser", pitch = 0.78, gain = 1.10, layer = "bass", layerGain = 0.21, layerPitch = 0.43},
    rally = {class = "rally", pitch = 0.94, gain = 1.00, layer = nil},
    rally_2 = {class = "rally", pitch = 0.98, gain = 1.00, layer = nil},
    rally_3 = {class = "rally", pitch = 1.03, gain = 0.98, layer = nil},
    ebike = {class = "electric", pitch = 1.35, gain = 1.12, layer = nil, electric = true},
    tank = {class = "heavy", pitch = 0.54, gain = 1.08, layer = "bass", layerGain = 0.34, layerPitch = 0.38, heavy = true},
    beetle = {class = "heavy", pitch = 0.63, gain = 1.02, layer = "mechanical", layerGain = 0.26, layerPitch = 0.48, heavy = true},
    centipede = {class = "heavy", pitch = 0.58, gain = 1.04, layer = "mechanical", layerGain = 0.31, layerPitch = 0.43, heavy = true},
    loader = {class = "heavy", pitch = 0.50, gain = 1.12, layer = "bass", layerGain = 0.30, layerPitch = 0.36, heavy = true},
    cicada = {class = "rally", pitch = 1.18, gain = 0.92, layer = "mechanical", layerGain = 0.18, layerPitch = 0.78},
    helicopter = {class = "turbine", pitch = 1.42, gain = 0.86, layer = "rotor", layerGain = 0.30, layerPitch = 0.72, airborne = true},
    hovercraft = {class = "turbine", pitch = 1.24, gain = 0.82, layer = "rotor", layerGain = 0.18, layerPitch = 0.62, airborne = true},
    jellyfish = {class = "turbine", pitch = 1.36, gain = 0.80, layer = "rotor", layerGain = 0.20, layerPitch = 0.68, airborne = true},
    jetboat = {class = "turbine", pitch = 1.58, gain = 0.92, layer = "rotor", layerGain = 0.15, layerPitch = 0.86},
    toilet = {class = "turbine", pitch = 1.50, gain = 0.90, layer = nil},
    bathtub = {class = "cruiser", pitch = 0.74, gain = 1.00, layer = "bass", layerGain = 0.22, layerPitch = 0.42},
    buggy = {class = "rally", pitch = 1.02, gain = 1.02, layer = nil},
    frog = {class = "rally", pitch = 0.97, gain = 0.96, layer = nil},
    skateboard = {class = "rally", pitch = 1.24, gain = 0.72, layer = "mechanical", layerGain = 0.10, layerPitch = 0.92},
    sled = {class = "sport", pitch = 0.90, gain = 0.78, layer = "mechanical", layerGain = 0.10, layerPitch = 0.56},
    cart = {class = "rally", pitch = 1.10, gain = 0.80, layer = "mechanical", layerGain = 0.12, layerPitch = 0.74},
    office = {class = "sport", pitch = 1.08, gain = 0.78, layer = "mechanical", layerGain = 0.11, layerPitch = 0.84},
}

local MUSIC, ENGINE, WIND, BRAKE, IMPACT, PASS = 1, 2, 3, 4, 5, 6
local SILENCE = 0.001
local PAD_WHOOSH_LENGTH = 0.48

local function Finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

-- 只生成一秒16kHz单声道PCM，整数周期确保接缝连续；不落盘、不生成音乐。
-- 录音保留发动机主体，PCM补履带链节/齿轮咬合/旋翼拍击，Sound在管理器中缓存。
---@param kind string
---@return Sound?
local function MechanicalLoop(kind)
    local rate, count = 16000, 16000
    local data = VectorBuffer()
    data:WriteFileID("RIFF"); data:WriteUInt(36 + count * 2); data:WriteFileID("WAVE")
    data:WriteFileID("fmt "); data:WriteUInt(16); data:WriteUShort(1); data:WriteUShort(1)
    data:WriteUInt(rate); data:WriteUInt(rate * 2); data:WriteUShort(2); data:WriteUShort(16)
    data:WriteFileID("data"); data:WriteUInt(count * 2)
    for index = 0, count - 1 do
        local t = index / rate
        local phase = t * math.pi * 2
        local sample = 0.0
        if kind == "bass" then
            local links = math.max(0, math.cos(phase * 24)) ^ 8
            sample = math.sin(phase * 64) * 0.42 + math.sin(phase * 128) * 0.20
                + links * (math.sin(phase * 464) * 0.20 + math.sin(phase * 832) * 0.13)
        elseif kind == "mechanical" then
            local gears = 0.3 + math.max(0, math.sin(phase * 18)) ^ 6 * 0.7
            sample = (math.sin(phase * 112) * 0.30 + math.sin(phase * 336) * 0.25
                + math.sin(phase * 896) * 0.16) * gears
        else
            local blades = (0.5 + 0.5 * math.cos(phase * 22)) ^ 3
            sample = (math.sin(phase * 88) * 0.50 + math.sin(phase * 176) * 0.22
                + math.sin(phase * 1078) * 0.10) * (0.20 + blades * 0.80)
        end
        data:WriteShort(math.floor(sample * 28000))
    end
    data:Seek(0)
    local sound = Sound()
    if not sound:LoadWav(data --[[@as Deserializer]]) then sound:Dispose(); return nil end
    sound.looped = true
    return sound
end

---@param value number
---@return number
local function Unit(value)
    return math.max(0, math.min(1, value))
end

-- 指数平滑与帧率无关，暂停时仍用真实帧时间淡出，而不是仿真步长。
---@param current number
---@param target number
---@param rate number
---@param dt number
---@return number
local function Smooth(current, target, rate, dt)
    return current + (target - current) * (1 - math.exp(-rate * dt))
end

-- 显式无声契约测试：假Sound/Source计数，绝不创建播放设备或读取/播放真实音频。
---@return table
function RideAudio.CheckPadFeedback()
    local counter = {plays = 0, stops = 0}
    local source = {gain = 0, frequency = 0,
        Play = function() counter.plays = counter.plays + 1 end,
        StopImmediate = function() counter.stops = counter.stops + 1 end}
    local sound = {GetFrequency = function() return 44100 end}
    local audio = setmetatable({}, RideAudio)
    audio.sources, audio.pitches = {}, {}
    audio.sounds = {[WIND] = sound --[[@as Sound]]}
    audio.padSource = source --[[@as SoundSource]]
    audio.unlocked, audio.effectsEnabled, audio.musicEnabled, audio.stopped = true, true, false, false
    audio.trackIndex = 1
    audio.padTimer, audio.padGain, audio.padSequence, audio.padElapsed = 0, 0, 0, 0
    audio.previousHealth, audio.previousOvertakes, audio.previousElapsed, audio.previousScreen = 100, 0, 0, "menu"
    local state = {triggers = 0, lastGain = 0, feedbackTimer = 0, feedbackPower = 0}
    local sim = {speed = 35, rpm = 5000, throttle = 0.5, braking = false, health = 100,
        overtakes = 0, elapsed = 1, finished = false, featureState = state}
    audio:Update(0.016, sim, "ride")
    state.triggers, state.lastGain, state.feedbackTimer = 1, 4.5, 1.35
    audio:Update(0.016, sim, "ride")
    assert(counter.plays == 1, "真实gain触发一次whoosh")
    for _ = 1, 45 do audio:Update(0.016, sim, "ride") end
    assert(counter.plays == 1 and audio.padTimer == 0, "连续帧不得重放，短包络必须结束")
    state.triggers, state.lastGain = 2, 0
    audio:Update(0.016, sim, "ride")
    state.triggers, state.lastGain, state.feedbackTimer = 3, 4.5, 0
    audio:Update(0.016, sim, "ride")
    assert(counter.plays == 1, "零gain或过期timer不得发声")
    state.triggers, state.feedbackTimer = 4, 1.35
    audio:Update(0.016, sim, "pause")
    audio:Update(0.016, sim, "ride")
    assert(counter.plays == 1, "暂停消费序号，恢复不得补播")
    state.triggers = 5
    audio:Update(0.016, sim, "ride")
    assert(counter.plays == 2 and audio.padTimer > 0, "下一真实触发应可重播")
    audio:ToggleEffects()
    assert(audio.padTimer == 0 and source.gain == 0, "关闭音效必须立即停whoosh")
    state.triggers = 6
    audio:Update(0.016, sim, "ride")
    audio:ToggleEffects()
    audio:Update(0.016, sim, "ride")
    assert(counter.plays == 2, "静音期间触发不得补播")
    state.triggers = 7
    audio:Update(0, sim, "ride")
    audio:Update(0.016, sim, "ride")
    assert(counter.plays == 2 and audio.padTimer == 0, "dt0不得触发，恢复不得补播")
    state.triggers = 8
    audio:Reset(sim)
    audio:Update(0.016, sim, "ride")
    assert(counter.plays == 2, "Reset不得重放已有序号")
    state.triggers = 9
    audio:Update(0.016, sim, "ride")
    assert(counter.plays == 3, "Reset后新序号仍可播放")
    sim.paused = true
    audio:Update(0.016, sim, "ride")
    assert(audio.padTimer == 0 and source.gain == 0, "sim.paused必须立即停whoosh")
    sim.paused, audio.unlocked, state.triggers = false, false, 10
    audio:Update(0.016, sim, "ride")
    audio.unlocked = true
    audio:Update(0.016, sim, "ride")
    assert(counter.plays == 3, "锁定期间序号不得解锁后补播")
    sim.elapsed, state.triggers = 0, 0
    audio:Update(0.016, sim, "ride")
    state.triggers = 1
    audio:Update(0.016, sim, "ride")
    assert(counter.plays == 4, "仿真原地重置后新序号必须可播")
    audio:Stop()
    audio:Stop()
    state.triggers = 2
    audio:Update(0.016, sim, "ride")
    assert(counter.plays == 4 and audio.padSource == nil and audio.padTimer == 0, "Stop必须幂等且永不复播")
    print("[加速带音效验收] 一次触发/零gain/过期/暂停/静音/dt0/Reset/Stop通过，无真实播放")
    return {passed = true, plays = counter.plays}
end

---@param scene Scene
---@return RideAudio
function RideAudio.New(scene)
    local self = setmetatable({}, RideAudio)
    self:Init(scene)
    return self
end

---@private
---@param scene Scene
function RideAudio:Init(scene)
    self.scene = scene
    self.node = scene:CreateChild("驾驶音频", LOCAL)
    self.sounds = {}
    self.sources = {}
    self.pitches = {}
    self.musicEnabled = true
    self.trackIndex = 1
    self.effectsEnabled = true
    self.unlocked = false
    self.stopped = false
    self.previousSim = nil
    self.previousHealth = 100
    self.previousOvertakes = 0
    self.previousElapsed = 0
    self.previousScreen = "menu"
    self.engineClass, self.engineSounds = "", {}
    self.engineProfile, self.engineSoundFailures = nil, {}
    self.engineLayerClass, self.engineLayerSound = "", nil
    self.outputWarningShown = false
    self.engineLayerSource = self.node:CreateChild("VehicleMechanicalLayer", LOCAL):CreateComponent("SoundSource", LOCAL)
    self.engineLayerSource.soundType, self.engineLayerSource.gain, self.engineLayerSource.declickEnabled = SOUND_EFFECT, 0, true
    self.padSource = self.node:CreateChild("PadWhoosh", LOCAL):CreateComponent("SoundSource", LOCAL)
    self.padSource.soundType, self.padSource.gain, self.padSource.declickEnabled = SOUND_EFFECT, 0, true
    self.padTimer, self.padGain, self.padSequence, self.padElapsed = 0, 0, 0, 0
    self.padSim, self.padState = nil, nil
    print("[音频] 管理器已创建，等待逐项加载与用户解锁")
end

-- 每次最多读取一项；成功或已加载返回 true，越界、失败或已停止返回 false。
-- 单项失败不会阻塞其他音轨；调用方可记录失败并继续下一项，也可稍后重试。
---@param index number
---@return boolean
function RideAudio:LoadOne(index)
    if self.stopped or not self.node then return false end
    if not Finite(index) or index < 1 or index > RideAudio.Count or index ~= math.floor(index) then return false end
    if self.sounds[index] and (index > PASS or self.sources[index]) then return true end
    local path = self.Resources[index]
    if not path then return false end
    local sound = self.sounds[index] or cache:GetResource("Sound", path)
    if not sound or sound:GetFrequency() <= 0 or sound:GetLength() <= 0 then
        print("[音频] 资源加载失败：" .. path)
        return false
    end

    -- 循环标记属于 Sound，而非 SoundSource；撞击和超车必须保持单次播放。
    sound.looped = index <= BRAKE or index > PASS
    self.sounds[index] = sound
    -- 额外歌曲只保留压缩 Sound，切歌复用主音乐通道，不叠加音乐音源。
    if index > PASS then
        for key, enginePath in pairs(RideAudio.EngineResources) do
            if enginePath == path then self.engineSounds[key] = sound end
        end
        print("[音频] 已准备循环资源：" .. path)
        return true
    end
    local trackNode = self.node:CreateChild("音轨" .. index, LOCAL)
    local source = trackNode:CreateComponent("SoundSource", LOCAL)
    source.soundType = index == MUSIC and SOUND_MUSIC or SOUND_EFFECT
    source.gain = 0
    source.declickEnabled = true
    self.sounds[index] = sound
    self.sources[index] = source
    self.pitches[index] = 1
    print("[音频] 已加载 " .. index .. "/" .. RideAudio.Count .. "：" .. path)
    return true
end

---@private
---@param index number
function RideAudio:SilenceTrack(index)
    local source = self.sources[index]
    if source then
        source.gain = 0
        source:StopImmediate()
    end
end

-- 淡入淡出仅修改本管理器的音源；循环只启动一次，不逐帧重置播放位置。
---@private
---@param index number
---@param targetGain number
---@param targetPitch number
---@param dt number
function RideAudio:UpdateLoop(index, targetGain, targetPitch, dt)
    local source = self.sources[index]
    local soundIndex = index == MUSIC and self.Tracks[self.trackIndex].resource or index
    local sound = self.sounds[soundIndex]
    if not source or not sound then return end
    local allowed = self.unlocked and not self.stopped
        and (index == MUSIC and self.musicEnabled or index ~= MUSIC and self.effectsEnabled)
    if not allowed or not Finite(dt) or dt <= 0 then
        self:SilenceTrack(index)
        return
    end
    local gain = Smooth(source.gain, Unit(targetGain), index == MUSIC and 2.5 or 8, dt)
    local pitch = Smooth(self.pitches[index] or 1, math.max(0.2, math.min(3, targetPitch)), 7, dt)
    self.pitches[index] = pitch
    if targetGain == 0 and gain < SILENCE then
        source.gain = 0
        if source.playing then source:StopImmediate() end
        return
    end

    -- frequency 是绝对采样率（Hz），绝不能直接传入 pitch 倍率。
    local frequency = sound:GetFrequency() * pitch
    if not source.playing and targetGain > 0 then source:Play(sound, frequency, gain) end
    source.gain, source.frequency = gain, frequency
end

---@private
---@param index number
---@param gain number
---@param pitch number
function RideAudio:PlayOnce(index, gain, pitch)
    if not self.unlocked or not self.effectsEnabled or self.stopped then return end
    local source = self.sources[index]
    local sound = self.sounds[index]
    if source and sound then
        -- 独立通道允许撞击与超车同时发声；同类事件复用通道，避免累积音源。
        source:Play(sound, sound:GetFrequency() * pitch, gain)
    end
end

-- 加速带只借用已加载的风噪Sound，独立source做一次短扫频，不触碰Wind/氮气通道或Sound.looped。
-- SoundSource.frequency是绝对Hz；已有循环素材在0.48秒包络末尾强制停止，不逐帧Play。
function RideAudio:SilencePad()
    self.padTimer, self.padGain = 0, 0
    if self.padSource then
        self.padSource.gain = 0
        self.padSource:StopImmediate()
    end
end

---@param dt number
---@param sim RideAudioState?
---@param audible boolean
function RideAudio:UpdatePadFeedback(dt, sim, audible)
    local state = sim and sim.featureState
    local sequence = state and state.triggers or 0
    local elapsed = sim and sim.elapsed or 0
    local sameRun = self.padSim == sim and self.padState == state
        and elapsed >= self.padElapsed and sequence >= self.padSequence
    local triggered = sameRun and sequence > self.padSequence
        and state ~= nil and (state.lastGain or 0) > 0 and (state.feedbackTimer or 0) > 0
    -- 无论静音、锁定、暂停，先消费真实触发序号；恢复后不补播历史事件。
    self.padSim, self.padState = sim, state
    self.padSequence, self.padElapsed = sequence, elapsed
    if not sameRun or not audible or dt <= 0 then self:SilencePad(); return end
    local source, sound = self.padSource, self.sounds[WIND]
    if not source or not sound then self:SilencePad(); return end
    if triggered then
        self.padTimer = PAD_WHOOSH_LENGTH
        self.padGain = 0.30 + Unit((state.lastGain or 0) / 10) * 0.13
        source:Play(sound, sound:GetFrequency() * 1.65, self.padGain * 0.18)
    elseif self.padTimer > 0 then
        self.padTimer = math.max(0, self.padTimer - math.max(0, dt))
        if self.padTimer <= 0 then self:SilencePad(); return end
        local phase = 1 - self.padTimer / PAD_WHOOSH_LENGTH
        source.gain = self.padGain * math.min(1, phase * 9 + 0.18) * (1 - phase) ^ 1.5
        source.frequency = sound:GetFrequency() * (1.65 - phase * 0.80)
    end
end

-- 只清事件基线和短冲刺音，不重建原六通道。无sim时下一次Update仅建基线。
---@param sim? RideAudioState
function RideAudio:Reset(sim)
    if self.stopped then return end
    self:SilencePad()
    self.padSim, self.padState = sim, sim and sim.featureState or nil
    self.padSequence = self.padState and self.padState.triggers or 0
    self.padElapsed = sim and sim.elapsed or 0
    self.previousSim = sim
    self.previousHealth = sim and sim.health or 100
    self.previousOvertakes = sim and sim.overtakes or 0
    self.previousElapsed = sim and sim.elapsed or 0
end

-- 必须直接在用户点击开始（或等价输入）回调中调用；加载与构造绝不自动播放。
-- 幂等调用；先解锁后加载同样有效，后续 Update 会启动已就绪的音轨。
function RideAudio:Unlock()
    if self.stopped then return end
    local firstUnlock = not self.unlocked
    self.unlocked = true
    -- 仅在手势入口尝试恢复已初始化设备；不重设音频模式，不取消用户或平台静音。
    local ok, device = pcall(GetAudio)
    if ok and device then
        if device.initialized and not device.playing then device:Play() end
        if not device.initialized and not self.outputWarningShown then
            print("[音频] 输出设备尚未初始化；音源解锁成功不等于扬声器已有声音")
            self.outputWarningShown = true
        end
    end
    if firstUnlock and self.musicEnabled then self:UpdateLoop(MUSIC, 0.06, 1, 1) end
    if firstUnlock then print("[音频] 用户已解锁声音") end
end

---@return string
function RideAudio:GetTrackTitle()
    return self.Tracks[self.trackIndex].title
end

-- 切歌只替换音乐通道；静音时允许选曲，但不会自动取消静音。
---@param direction integer
---@return string
function RideAudio:ChangeTrack(direction)
    if self.stopped then return self:GetTrackTitle() end
    self.trackIndex = (self.trackIndex - 1 + direction) % #self.Tracks + 1
    self:SilenceTrack(MUSIC)
    self.pitches[MUSIC] = 1
    if self.unlocked and self.musicEnabled then self:UpdateLoop(MUSIC, 0.18, 1, 0.04) end
    print("[电台] " .. self.trackIndex .. "/" .. #self.Tracks .. " " .. self:GetTrackTitle())
    return self:GetTrackTitle()
end

---@return boolean
function RideAudio:ToggleMusic()
    if self.stopped then return self.musicEnabled end
    self.musicEnabled = not self.musicEnabled
    if not self.musicEnabled then self:SilenceTrack(MUSIC) end
    print("[音频] 音乐" .. (self.musicEnabled and "开启" or "关闭"))
    return self.musicEnabled
end

---@return boolean
function RideAudio:ToggleEffects()
    if self.stopped then return self.effectsEnabled end
    self.effectsEnabled = not self.effectsEnabled
    if not self.effectsEnabled then
        for index = ENGINE, PASS do self:SilenceTrack(index) end
        self:SilenceEngineLayer()
        self:SilencePad()
    end
    print("[音频] 音效" .. (self.effectsEnabled and "开启" or "关闭"))
    return self.effectsEnabled
end

-- 车型切换只替换ENGINE槽的Sound，六个基础source对象保持原身份；失败继续使用旧声音。
---@param vehicleId string
---@return boolean
function RideAudio:SetVehicle(vehicleId)
    if self.stopped or not self.sources[ENGINE] or type(vehicleId) ~= "string" then return false end
    local profile = RideAudio.VehicleEngineProfiles[vehicleId]
    local key = profile and profile.class or RideAudio.EngineFor(vehicleId)
    profile = profile or {class = key, pitch = RideAudio.EnginePitch[key] or 1, gain = 1}
    local path = RideAudio.EngineResources[key]
    if not path then return false end
    local sound = self.engineSounds[key]
    if not sound then
        sound = cache:GetResource("Sound", path)
        if sound and sound:GetFrequency() > 0 and sound:GetLength() > 0 then
            sound.looped = true
            self.engineSounds[key] = sound
        else
            self.engineSoundFailures[key] = true
            if self.engineClass == "" then print("[车型音频] 主发动机资源不可用：" .. path) end
            return false
        end
    end
    if self.engineClass ~= key then
        self:SilenceTrack(ENGINE)
        self.sounds[ENGINE] = sound
        self.pitches[ENGINE] = 1
        self.engineClass = key
        print("[车型音频] " .. tostring(vehicleId) .. " -> " .. key .. " / " .. path)
    end
    self.engineProfile = profile
    self:UpdateEngineLayer(profile)
    return true
end

-- 生成/缓存与主发动机独立的履带、齿轮或旋翼层；生成失败只禁用层，不影响主发动机。
---@param profile table
function RideAudio:UpdateEngineLayer(profile)
    local kind = profile.layer
    if not kind then
        self:SilenceEngineLayer()
        if self.engineLayerSound then self.engineLayerSound:Dispose() end
        self.engineLayerClass, self.engineLayerSound = "", nil
        return
    end
    if self.engineLayerClass ~= kind or not self.engineLayerSound then
        self:SilenceEngineLayer()
        local old = self.engineLayerSound
        if old then old:Dispose() end
        local ok, generated = pcall(MechanicalLoop, kind)
        if not ok or not generated or generated:GetFrequency() <= 0 or generated:GetLength() <= 0 then
            self.engineLayerClass, self.engineLayerSound = "", nil
            print("[车型音频] 机械层生成失败：" .. kind .. "，保留主发动机")
            return
        end
        self.engineLayerClass, self.engineLayerSound = kind, generated
        print("[车型音频] 已启用独立机械层：" .. kind)
    end
end

function RideAudio:SilenceEngineLayer()
    local source = self.engineLayerSource
    if source then source.gain = 0; source:StopImmediate() end
end

---@param targetGain number
---@param pitch number
---@param dt number
function RideAudio:UpdateEngineLayerLoop(targetGain, pitch, dt)
    local source, sound = self.engineLayerSource, self.engineLayerSound
    if not source or not sound then return end
    if not self.unlocked or self.stopped or not self.effectsEnabled or not Finite(dt) or dt <= 0
        or targetGain <= 0 then
        self:SilenceEngineLayer()
        return
    end
    local gain = Smooth(source.gain, Unit(targetGain), 8, dt)
    local frequency = sound:GetFrequency() * math.max(0.2, math.min(3, pitch))
    if not source.playing then source:Play(sound, frequency, gain) end
    source.gain, source.frequency = gain, frequency
end

-- 车型到引擎声音原型的回退映射；完整 vehicleId 优先由 VehicleEngineProfiles 区分。
---@param vehicleId string
---@return string
function RideAudio.EngineFor(vehicleId)
    local profile = RideAudio.VehicleEngineProfiles[vehicleId]
    if profile then return profile.class end
    local mixed = RideAudio.MixedEngineResources[vehicleId]
    if mixed then return mixed end
    local classId = type(vehicleId) == "string" and vehicleId:match("^(%a+)") or "sport"
    return RideAudio.EngineResources[classId] and classId or "sport"
end

-- screen 使用主流程已有的 menu / ride / pause / result；未知界面按非驾驶处理。
-- 必须在仿真更新之后调用，才能读取本帧健康值、超车计数和结算前的最后一次撞击。
---@param dt number 真实帧时间，暂停时不要传 0
---@param sim RideAudioState?
---@param screen string
function RideAudio:Update(dt, sim, screen)
    if self.stopped then return end
    -- sim.vehicleId由仿真提供，不把完整车型id改成class。
    local vehicleId = sim and sim.vehicleId
    if vehicleId then self:SetVehicle(vehicleId) end
    local frameTime = Finite(dt) and math.max(0, dt) or 0
    local riding = sim ~= nil and screen == "ride" and not sim.finished and sim.paused ~= true
    local speed = sim and math.max(0, sim.speed) or 0
    local speedRatio = Unit(speed / 61.1)
    local vehicle = sim and sim.vehicle
    local idle, redline = vehicle and vehicle.idle or 1200, vehicle and vehicle.redline or 11000
    local rpmRatio = sim and Unit((sim.rpm - idle) / math.max(1, redline - idle)) or 0
    local throttle = sim and Unit(sim.throttle) or 0
    local effectsActive = frameTime > 0 and self.unlocked and self.effectsEnabled and riding
    if not effectsActive then
        for index = ENGINE, PASS do self:SilenceTrack(index) end
        self:SilenceEngineLayer()
    end
    local windGain = effectsActive and speedRatio ^ 1.5 * 0.30 or 0
    local brakeGain = effectsActive and sim and
        (sim.burnout and 0.24 or (sim.braking and Unit(speed / 18) * 0.25 or 0)) or 0
    self:UpdatePadFeedback(frameTime, sim, effectsActive)

    local engineProfile = self.engineProfile or {pitch = RideAudio.EnginePitch[self.engineClass] or 1, gain = 1}
    local engineGain = effectsActive and (0.12 + rpmRatio * 0.15 + throttle * 0.13 + speedRatio * 0.035) * (engineProfile.gain or 1) or 0
    local enginePitch = (0.68 + rpmRatio * 0.70 + throttle * 0.12 + speedRatio * 0.12) * (engineProfile.pitch or 1)
    if engineProfile.electric then
        -- 电机无燃烧怠速：起步立即可听，速度决定电机音高，松油后随滚行轻声滑降。
        engineGain = effectsActive and (0.025 + throttle * 0.34 + speedRatio * 0.20) * (engineProfile.gain or 1) or 0
        enginePitch = (0.56 + speedRatio * 0.92 + throttle * 0.24) * (engineProfile.pitch or 1)
    end
    self:UpdateLoop(ENGINE, engineGain, enginePitch, frameTime)
    local layerGain = effectsActive and (engineProfile.layerGain or 0) * (0.30 + speedRatio * 0.55 + throttle * 0.25) or 0
    local layerPitch = (engineProfile.layerPitch or 1) * (0.78 + speedRatio * 0.52 + throttle * 0.12)
    self:UpdateEngineLayerLoop(layerGain, layerPitch, frameTime)
    self:UpdateLoop(WIND, windGain, 0.80 + speedRatio * 0.30, frameTime)
    self:UpdateLoop(BRAKE, brakeGain, 0.85 + speedRatio * 0.20, frameTime)

    ---@type number
    local musicGain = 0.0
    if self.unlocked and self.musicEnabled then
        musicGain = riding and 0.18 or (screen == "result" and 0.085 or 0.055)
    end
    self:UpdateLoop(MUSIC, musicGain*Unit(self.musicDuck or 1), 1, frameTime)

    if sim then
        -- 更换仿真实例、时间回退、血量恢复或计数归零都只重建基线，不误播事件。
        local sameRun = self.previousSim == sim
            and sim.elapsed >= self.previousElapsed
            and sim.health <= self.previousHealth
            and sim.overtakes >= self.previousOvertakes
        local eventFrame = frameTime > 0 and sim.paused ~= true
            and (screen == "ride" or (screen == "result" and self.previousScreen == "ride"))
        if sameRun and eventFrame then
            if sim.health < self.previousHealth then
                local damageRatio = Unit((self.previousHealth - sim.health) / 65)
                self:PlayOnce(IMPACT, 0.40 + damageRatio * 0.22, 1)
            end
            if sim.overtakes > self.previousOvertakes then
                -- 同帧多个超车合并为一次；下一帧基线已更新，不会按累计次数重播。
                self:PlayOnce(PASS, 0.32, 0.94 + speedRatio * 0.12)
            end
        end
        -- 即使静音、锁定或暂停也消费计数，恢复声音时不补播历史事件。
        self.previousSim = sim
        self.previousHealth = sim.health
        self.previousOvertakes = sim.overtakes
        self.previousElapsed = sim.elapsed
    else
        self.previousSim = nil
    end
    self.previousScreen = screen
end

-- 终止并释放自己创建的节点，幂等；应在 scene:Dispose() 前调用。
-- Stop 后不会自行复播；如需重建管理器，重新调用 RideAudio.New(scene)。
function RideAudio:Stop()
    if self.stopped then return end
    self.stopped = true
    self.unlocked = false
    self:SilencePad()
    for index = 1, RideAudio.Count do self:SilenceTrack(index) end
    self.sources = {}
    self.sounds = {}
    self.pitches = {}
    self.engineSounds, self.engineClass = {}, ""
    self.engineProfile, self.engineSoundFailures = nil, {}
    if self.engineLayerSound then self.engineLayerSound:Dispose() end
    self.engineLayerSound, self.engineLayerClass = nil, ""
    self.engineLayerSource = nil
    if self.node then self.node:Dispose() end
    self.padSource, self.padSim, self.padState = nil, nil, nil
    self.padSequence, self.padElapsed = 0, 0
    self.node = nil
    self.scene = nil
    self.previousSim = nil
    print("[音频] 已停止并释放所有驾驶音源")
end

---@return table
function RideAudio:GetStatus()
    local output = {available = false, initialized = false, playing = false}
    local ok, device = pcall(GetAudio)
    if ok and device then
        output.available, output.initialized, output.playing = true, device.initialized == true, device.playing == true
        output.effectGain = device:GetMasterGain(SOUND_EFFECT)
        output.musicGain = device:GetMasterGain(SOUND_MUSIC)
    end
    local engine, layer = self.sources[ENGINE], self.engineLayerSource
    return {
        stopped = self.stopped, unlocked = self.unlocked, effectsEnabled = self.effectsEnabled,
        output = output, engineClass = self.engineClass, vehicleProfile = self.engineProfile,
        engine = {loaded = self.sounds[ENGINE] ~= nil, frequency = engine and engine:GetFrequency() or 0,
            gain = engine and engine.gain or 0, playing = engine and engine.playing or false},
        mechanical = {loaded = self.engineLayerSound ~= nil, kind = self.engineLayerClass,
            frequency = layer and layer:GetFrequency() or 0, gain = layer and layer.gain or 0,
            playing = layer and layer.playing or false},
    }
end

return RideAudio
