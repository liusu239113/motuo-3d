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

---@class RideAudio
---@field Resources string[] 静态资源清单，索引从 1 开始
---@field Count integer 静态资源数量
---@field scene Scene?
---@field node Node?
---@field sounds table<number, Sound?>
---@field sources table<number, SoundSource?>
---@field pitches table<number, number>
---@field musicEnabled boolean
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
---@field engineSounds table<string, Sound>
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
}

local MUSIC, ENGINE, WIND, BRAKE, IMPACT, PASS = 1, 2, 3, 4, 5, 6
local SILENCE = 0.001

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
    print("[音频] 管理器已创建，等待逐项加载与用户解锁")
end

-- 每次最多读取一项；成功或已加载返回 true，越界、失败或已停止返回 false。
-- 单项失败不会阻塞其他音轨；调用方可记录失败并继续下一项，也可稍后重试。
---@param index number
---@return boolean
function RideAudio:LoadOne(index)
    if self.stopped or not self.node then return false end
    if index < 1 or index > RideAudio.Count or index ~= math.floor(index) then return false end
    if self.sounds[index] then return true end
    local path = self.Resources[index]
    if not path then return false end
    local sound = cache:GetResource("Sound", path)
    if not sound or sound:GetFrequency() <= 0 or sound:GetLength() <= 0 then
        print("[音频] 资源加载失败：" .. path)
        return false
    end

    -- 循环标记属于 Sound，而非 SoundSource；撞击和超车必须保持单次播放。
    sound.looped = index <= BRAKE or index > PASS
    self.sounds[index] = sound
    -- 额外歌曲只保留压缩 Sound，切歌复用主音乐通道，不叠加音乐音源。
    if index > PASS then
        print("[电台] 已准备曲目：" .. path)
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
    local gain = Smooth(source.gain, targetGain, index == MUSIC and 2.5 or 8, dt)
    local pitch = Smooth(self.pitches[index] or 1, targetPitch, 7, dt)
    self.pitches[index] = pitch
    if targetGain == 0 and gain < SILENCE then
        source.gain = 0
        if source.playing then source:Stop() end
        return
    end
    if not self.unlocked then return end

    -- frequency 是绝对采样率（Hz），绝不能直接传入 pitch 倍率。
    local frequency = sound:GetFrequency() * pitch
    if not source.playing and targetGain > 0 then
        source:Play(sound, frequency, gain)
    else
        source.gain = gain
        source.frequency = frequency
    end
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

-- 必须直接在用户点击开始（或等价输入）回调中调用；加载与构造绝不自动播放。
-- 幂等调用；先解锁后加载同样有效，后续 Update 会启动已就绪的音轨。
function RideAudio:Unlock()
    if self.stopped or self.unlocked then return end
    self.unlocked = true
    if self.musicEnabled then self:UpdateLoop(MUSIC, 0.06, 1, 1) end
    print("[音频] 用户已解锁声音")
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
    end
    print("[音频] 音效" .. (self.effectsEnabled and "开启" or "关闭"))
    return self.effectsEnabled
end

-- 车型切换只替换ENGINE槽的Sound，六个source对象保持原身份；失败继续使用旧声音。
---@param vehicleId string
---@return boolean
function RideAudio:SetVehicle(vehicleId)
    -- 尚未LoadOne(ENGINE)时不可提前占用sounds[2]，否则旧Loader会误认为source也已就绪。
    if self.stopped or not self.sources[ENGINE] then return false end
    local classId = vehicleId:match("^(%a+)") or vehicleId
    if self.engineClass == classId then return true end
    local path = RideAudio.EngineResources[classId]
    if not path then return false end
    local sound = self.engineSounds[classId] or cache:GetResource("Sound", path)
    if not sound or sound:GetFrequency() <= 0 or sound:GetLength() <= 0 then return false end
    sound.looped = true
    self.engineSounds[classId] = sound
    self:SilenceTrack(ENGINE)
    self.sounds[ENGINE] = sound
    self.pitches[ENGINE] = 1
    self.engineClass = classId
    print("[车型音频] " .. classId .. " / " .. path .. " / 复用ENGINE音源")
    return true
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
    local frameTime = math.max(0, dt)
    local riding = sim ~= nil and screen == "ride" and not sim.finished
    local speed = sim and math.max(0, sim.speed) or 0
    local speedRatio = Unit(speed / 61.1)
    local vehicle = sim and sim.vehicle
    local idle, redline = vehicle and vehicle.idle or 1200, vehicle and vehicle.redline or 11000
    local rpmRatio = sim and Unit((sim.rpm - idle) / math.max(1, redline - idle)) or 0
    local throttle = sim and Unit(sim.throttle) or 0
    local effectsActive = self.unlocked and self.effectsEnabled and riding

    local engineGain = effectsActive and (0.10 + rpmRatio * 0.15 + throttle * 0.12) or 0
    local windGain = effectsActive and speedRatio ^ 1.5 * 0.30 or 0
    local brakeGain = effectsActive and sim and
        (sim.burnout and 0.24 or (sim.braking and Unit(speed / 18) * 0.25 or 0)) or 0
    self:UpdateLoop(ENGINE, engineGain, 0.68 + rpmRatio * 0.78 + throttle * 0.10, frameTime)
    self:UpdateLoop(WIND, windGain, 0.80 + speedRatio * 0.30, frameTime)
    self:UpdateLoop(BRAKE, brakeGain, 0.85 + speedRatio * 0.20, frameTime)

    ---@type number
    local musicGain = 0.0
    if self.unlocked and self.musicEnabled then
        musicGain = riding and 0.18 or (screen == "result" and 0.085 or 0.055)
    end
    self:UpdateLoop(MUSIC, musicGain, 1, frameTime)

    if sim then
        -- 更换仿真实例、时间回退、血量恢复或计数归零都只重建基线，不误播事件。
        local sameRun = self.previousSim == sim
            and sim.elapsed >= self.previousElapsed
            and sim.health <= self.previousHealth
            and sim.overtakes >= self.previousOvertakes
        local eventFrame = screen == "ride" or (screen == "result" and self.previousScreen == "ride")
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
    for index = 1, RideAudio.Count do self:SilenceTrack(index) end
    self.sources = {}
    self.sounds = {}
    self.pitches = {}
    self.engineSounds, self.engineClass = {}, ""
    if self.node then self.node:Dispose() end
    self.node = nil
    self.scene = nil
    self.previousSim = nil
    print("[音频] 已停止并释放所有驾驶音源")
end

return RideAudio
