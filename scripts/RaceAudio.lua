-- 独立竞速音频。六个效果通道 + 一个互斥语音通道；不修改RideAudio或全局音量。
---@class RaceAudio
---@field scene Scene?
---@field node Node?
---@field sounds table<number, Sound>
---@field sources table<number, SoundSource>
---@field unlocked boolean
---@field effectsEnabled boolean
---@field stopped boolean
---@field lastSeq number
---@field currentRace table?
---@field curseTimer number
---@field curseIndex integer
---@field lastSpeakerId string
---@field musicDuck number
local RaceAudio = {}
RaceAudio.__index = RaceAudio
RaceAudio.Resources = {
    "audio/sfx/pursuit_siren.mp3",
    "audio/sfx/race_countdown_beep.mp3",
    "audio/sfx/race_start_green.mp3",
    "audio/sfx/race_contact_metal.mp3",
    "audio/sfx/race_nitro_burst.mp3",
    "audio/sfx/race_finish_sting.mp3",
    -- 对手被撞/互撞时的短促抱怨语音，按车手随机取一条。
    "audio/sfx/race_rider_curse_1.mp3",
    "audio/sfx/race_rider_curse_2.mp3",
    "audio/sfx/race_rider_curse_3.mp3",
    "audio/sfx/race_rider_curse_4.mp3",
}
RaceAudio.Count = #RaceAudio.Resources
local SIREN, COUNTDOWN, START, CONTACT, BOOST, FINISH = 1, 2, 3, 4, 5, 6
local CURSE_FIRST, CURSE_COUNT = 7, 4
-- 冷却至少1.2秒且覆盖整段原速语音和尾部留白；playing再兜底音频线程延迟。
local CURSE_COOLDOWN, CURSE_GAP = 1.2, 0.18
local function finite(value) return type(value) == "number" and value == value and math.abs(value) < math.huge end

-- contact是无方向的车手互撞：优先target AI，target是玩家则取另一位AI。
-- 单人撞障碍的contact只有player，不得替附近无关AI发言；bash若恢复则仅受击AI发言。
---@param event table
---@param race table?
---@return table?
function RaceAudio.Speaker(event, race)
    if not race or (event.kind ~= "contact" and event.kind ~= "bash") then return nil end
    ---@type table?
    local target = nil
    ---@type table?
    local actor = nil
    for _, racer in ipairs(race.racers or {}) do
        if racer.id == event.targetId then target = racer end
        if racer.id == event.racerId then actor = racer end
    end
    if target and target.id ~= "player" and not target.isPlayer then return target end
    if event.kind == "contact" and actor and actor.id ~= "player" and not actor.isPlayer then return actor end
    return nil
end

---@param scene Scene
---@return RaceAudio
function RaceAudio.New(scene)
    local self = setmetatable({}, RaceAudio)
    self:Init(scene)
    return self
end

---@param scene Scene
function RaceAudio:Init(scene)
    self.scene = scene -- 明确持有Scene，不创建游离节点/临时Scene。
    self.node = scene:CreateChild("RaceAudioChannels", LOCAL)
    self.sounds, self.sources = {}, {}
    self.lastSeq = 0
    self.currentRace = nil
    self.unlocked, self.effectsEnabled, self.stopped = false, true, false
    self.curseTimer, self.curseIndex = 0, 0
    self.lastSpeakerId, self.musicDuck = "", 1
    for index = 1, RaceAudio.Count do self:LoadOne(index) end
    print("[竞速音频] 六效果通道及单语音通道准备完成，等待用户输入解锁")
end

---@param index integer
---@return boolean
function RaceAudio:LoadOne(index)
    if self.stopped or not self.node then return false end
    if index < 1 or index > RaceAudio.Count then return false end
    if self.sounds[index] then return true end
    local path = RaceAudio.Resources[index]
    if not path then return false end
    local sound = cache:GetResource("Sound", path)
    if not sound or sound:GetFrequency() <= 0 or sound:GetLength() <= 0 then
        print("[竞速音频] 资源不可用：" .. path)
        return false
    end
    sound:SetLooped(index == SIREN)
    -- 四段语音资源共享已有source；重试加载也不重建已经创建的通道。
    local channel = index >= CURSE_FIRST and CURSE_FIRST or index
    local source = self.sources[channel]
    if not source then
        source = self.node:CreateChild("RaceChannel_" .. channel, LOCAL):CreateComponent("SoundSource", LOCAL)
        source.soundType = SOUND_EFFECT
        source.gain = 0
        source.declickEnabled = true
        self.sources[channel] = source
    end
    self.sounds[index], self.sources[index] = sound, source
    return true
end

-- 由主流程用户点击开始时显式调用，与RideAudio.Unlock同一个手势内调用。
function RaceAudio:Unlock()
    if not self.stopped then self.unlocked = true end
end

---@param enabled boolean
function RaceAudio:SetEffectsEnabled(enabled)
    self.effectsEnabled = enabled
    if not enabled then self:Silence() end
end

-- 只接受已验证、真正参与事件的非玩家发言者；不截断在播台词、不排队补播。
---@param event table
---@param speaker table
---@return boolean
function RaceAudio:Curse(event, speaker)
    local source = self.sources[CURSE_FIRST]
    if self.stopped or not self.unlocked or not self.effectsEnabled or self.curseTimer > 0
        or not speaker or speaker.id == "player" or speaker.isPlayer or not source or source.playing then return false end
    if event.kind ~= "contact" and event.kind ~= "bash" then return false end
    if speaker.id ~= event.racerId and speaker.id ~= event.targetId then return false end
    if event.kind == "bash" and speaker.id ~= event.targetId then return false end
    local who, offset = tostring(speaker.id), 0
    for index = 1, #who do offset = offset + who:byte(index) end
    self.curseIndex = offset % CURSE_COUNT
    local sound = self.sounds[CURSE_FIRST + self.curseIndex]
    if not sound then return false end
    source:Play(sound, 0, 0.52)
    self.curseTimer = math.max(CURSE_COOLDOWN, sound:GetLength() + CURSE_GAP)
    self.lastSpeakerId = who
    self.musicDuck = 0.4
    return true
end

-- 由主混音方乘入音乐目标gain，不改用户音乐开关/基础音量；勿逐帧乘当前gain。
function RaceAudio:GetMusicDuck() return self.musicDuck or 1 end

function RaceAudio:Silence()
    -- sources[7..10]是同一对象别名，只停止一次。
    for index = SIREN, CURSE_FIRST do
        local source = self.sources[index]
        if source then source.gain = 0; source:StopImmediate() end
    end
    self.curseTimer, self.lastSpeakerId, self.musicDuck = 0, "", 1
end

---@param index integer
---@param gain number
function RaceAudio:PlayOnce(index, gain)
    if self.stopped or not self.unlocked or not self.effectsEnabled or index >= CURSE_FIRST then return end
    local source, sound = self.sources[index], self.sounds[index]
    if source and sound then source:Play(sound, 0, gain) end
end

-- 只读Race.events，不清队列。seq基线在静音/暂停仍推进，恢复不补播历史音效。
---@param dt number 真实帧时间
---@param sim table?
---@param race table?
---@param active? boolean 默认true；主流程暂停/菜单时传false
function RaceAudio:Update(dt, sim, race, active)
    if self.stopped then return end
    if self.currentRace ~= race then
        self:Silence()
        self.currentRace, self.lastSeq = race, 0
    end
    local frameTime = finite(dt) and math.max(0, dt) or 0
    self.curseTimer = math.max(0, self.curseTimer - frameTime)
    local audible = active ~= false and frameTime > 0 and self.unlocked and self.effectsEnabled
        and not (sim and sim.paused)
    if not audible then self:Silence() end
    if race then
        for _, event in ipairs(race.events or {}) do
            if event.seq > self.lastSeq then
                self.lastSeq = event.seq
                if audible then
                    local player = event.racerId == "player" or event.targetId == "player"
                    if event.kind == "countdown" then self:PlayOnce(COUNTDOWN, 0.48)
                    elseif event.kind == "start" then self:PlayOnce(START, 0.60)
                    elseif event.kind == "finish" and (player or not event.racerId) then self:PlayOnce(FINISH, 0.58)
                    elseif event.kind == "contact" or event.kind == "bash" then
                        if player then self:PlayOnce(CONTACT, 0.42) end
                        local speaker = RaceAudio.Speaker(event, race)
                        -- 距离按真正发言者判断，不能取另一位靠近玩家的碰撞参与者。
                        if speaker and sim and finite(speaker.x) and finite(speaker.z)
                            and finite(sim.x) and finite(sim.z) then
                            local dx, dz = speaker.x - sim.x, speaker.z - sim.z
                            if dx * dx + dz * dz < 60 * 60 then self:Curse(event, speaker) end
                        end
                    elseif event.kind == "boost" and player then self:PlayOnce(BOOST, 0.43) end
                end
            end
        end
    end
    local voice = self.sources[CURSE_FIRST]
    local duckTarget = 1.0
    if audible and voice and voice.playing then duckTarget = 0.4 end
    local duck = self.musicDuck or 1
    self.musicDuck = duckTarget < duck and duckTarget or duck + (duckTarget - duck) * (1 - math.exp(-frameTime * 5))
    local source, sound = self.sources[SIREN], self.sounds[SIREN]
    if not source or not sound then return end
    local police = race and (race.pursuit or race.police)
    local target = 0
    if audible and race and race.phase == "racing" and police and police.active
        and (police.state == "warning" or police.state == "chasing") then
        local distance = math.abs(police.gap or 100)
        if sim and police.x and police.z then
            local dx, dz = police.x - (sim.x or 0), police.z - (sim.z or 0)
            distance = math.sqrt(dx * dx + dz * dz)
        end
        target = 0.32 * math.max(0, 1 - distance / 140)
    end
    local gain = source.gain + (target - source.gain) * (1 - math.exp(-frameTime * 7))
    if not audible or (target == 0 and gain < 0.001) then
        source.gain = 0
        if source.playing then source:Stop() end
    elseif not source.playing and target > 0 then
        source:Play(sound, 0, gain)
    else
        source.gain = gain
    end
end

-- 同实例Race的seq不会重置；Reset只清播放，避免重播上一局队列。
---@param race? table
function RaceAudio:Reset(race)
    self:Silence()
    self.currentRace = race or self.currentRace
    if self.currentRace then self.lastSeq = self.currentRace.eventSeq or self.lastSeq end
end

function RaceAudio:Stop()
    if self.stopped then return end
    self:Silence()
    self.stopped, self.unlocked = true, false
    if self.node then self.node:Dispose() end
    self.node, self.scene, self.currentRace = nil, nil, nil
    self.sources, self.sounds = {}, {}
end

function RaceAudio:Destroy() self:Stop() end
function RaceAudio:Dispose() self:Stop() end
return RaceAudio
