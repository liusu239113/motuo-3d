-- 独立竞速音频。只持有自己的六个通道；不修改RideAudio的六个旧音源或全局音量。
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
-- 相邻两次骂声至少间隔1.2秒，避免连环碰撞时四段语音叠在一起糊成噪音。
local CURSE_COOLDOWN = 1.2

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
    for index = 1, RaceAudio.Count do self:LoadOne(index) end
    print("[竞速音频] 独立六通道准备完成，等待用户输入解锁")
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
    sound.looped = index == SIREN
    local source = self.node:CreateChild("RaceChannel_" .. index, LOCAL):CreateComponent("SoundSource", LOCAL)
    source.soundType = SOUND_EFFECT
    source.gain = 0
    source.declickEnabled = true
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

-- 对手被撞：只在玩家附近的真实碰撞触发，按事件序号确定性地选一条语音。
---@param event table
function RaceAudio:Curse(event)
    if self.curseTimer > 0 then return end
    local who = tostring(event.targetId or "") .. tostring(event.racerId or "")
    local offset = 0
    for index = 1, #who do offset = offset + who:byte(index) end
    self.curseIndex = (offset + (event.seq or 0)) % CURSE_COUNT
    self:PlayOnce(CURSE_FIRST + self.curseIndex, 0.52)
    self.curseTimer = CURSE_COOLDOWN
end

function RaceAudio:Silence()
    for _, source in pairs(self.sources) do
        source.gain = 0
        source:StopImmediate()
    end
end

---@param index integer
---@param gain number
function RaceAudio:PlayOnce(index, gain)
    if self.stopped or not self.unlocked or not self.effectsEnabled then return end
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
    self.curseTimer = math.max(0, self.curseTimer - math.max(0, dt))
    local audible = active ~= false and self.unlocked and self.effectsEnabled
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
                        -- 玩家参与或就在附近时，被撞的一方会骂一句。
                        local near = player
                        if not near and sim and race.racers then
                            for _, racer in ipairs(race.racers) do
                                if racer.id == event.racerId or racer.id == event.targetId then
                                    local dx, dz = (racer.x or 0) - (sim.x or 0), (racer.z or 0) - (sim.z or 0)
                                    near = dx * dx + dz * dz < 60 * 60
                                    break
                                end
                            end
                        end
                        if near then self:Curse(event) end
                    elseif event.kind == "boost" and player then self:PlayOnce(BOOST, 0.43) end
                end
            end
        end
    end
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
    local gain = source.gain + (target - source.gain) * (1 - math.exp(-math.max(0, dt) * 7))
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
