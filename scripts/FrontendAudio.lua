-- Frontend-only audio singleton. HUD calls PlayUI(kind); main owns Init/Update/Dispose.
-- Only the requested screen's music is loaded asynchronously: no three-track startup gate.
-- Two fixed music sources crossfade; four fixed UI sources + cooldown prevent source growth.
local FrontendAudio = {}

FrontendAudio.Music = {
    menu = {path = "audio/music_1793833337847.ogg", title = "Neon Starting Grid", gain = 0.24},
    garage = {path = "audio/music_1793833387218.ogg", title = "Workshop Pocket Groove", gain = 0.22},
    loading = {path = "audio/music_1793833433329.ogg", title = "Before the Green Light", gain = 0.23},
}
FrontendAudio.Effects = {
    click = {path = "audio/sfx/frontend_ui_click.ogg", gain = 0.38},
    page = {path = "audio/sfx/frontend_ui_page.ogg", gain = 0.34},
    select = {path = "audio/sfx/frontend_ui_select.ogg", gain = 0.42},
    confirm = {path = "audio/sfx/frontend_ui_confirm.ogg", gain = 0.46},
    back = {path = "audio/sfx/frontend_ui_back.ogg", gain = 0.35},
    unavailable = {path = "audio/sfx/frontend_ui_unavailable.ogg", gain = 0.34},
}
FrontendAudio.Resources = {}
FrontendAudio.ResourceTypes = {}
for _, key in ipairs({"menu", "garage", "loading"}) do
    local path = FrontendAudio.Music[key].path
    FrontendAudio.Resources[#FrontendAudio.Resources + 1] = path
    FrontendAudio.ResourceTypes[path] = "Sound"
end
for _, key in ipairs({"click", "page", "select", "confirm", "back", "unavailable"}) do
    local path = FrontendAudio.Effects[key].path
    FrontendAudio.Resources[#FrontendAudio.Resources + 1] = path
    FrontendAudio.ResourceTypes[path] = "Sound"
end

---@class FrontendMusicSlot
---@field source SoundSource
---@field key string
---@field gain number
---@class FrontendUISlot
---@field source SoundSource
---@field remaining number

---@type Scene?
local scene_ = nil
---@type FrontendMusicSlot[]
local music_ = {}
---@type FrontendUISlot[]
local ui_ = {}
---@type table<string, Sound>
local sounds_ = {}
---@type table<string, boolean>
local pending_ = {}
---@type table<string, boolean>
local failed_ = {}
---@type table<string, number>
local lastUI_ = {}
local generation_, clock_, lastAnyUI_ = 0, 0.0, -10.0
local screen_, target_, current_ = "", "", ""
local initialized_, unlocked_, musicEnabled_, effectsEnabled_, suspended_ = false, false, true, true, false
local FADE_SECONDS, SILENCE = 0.65, 0.0005

---@param value number
local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

-- Settings opened from the race must not turn into main-menu music.
---@param screen string
---@param settingsReturn? string
---@return string
function FrontendAudio.ScreenMusic(screen, settingsReturn)
    if screen == "menu" then return "menu" end
    if screen == "tracks" then return "garage" end
    if screen == "garage" or screen == "loading" then return screen end
    if screen == "settings" then
        if settingsReturn == "garage" or settingsReturn == "tracks" then return "garage" end
        if settingsReturn == "menu" or not settingsReturn then return "menu" end
    end
    return ""
end

---@param screen string
---@param settingsReturn? string
---@return boolean
function FrontendAudio.IsFrontend(screen, settingsReturn)
    return FrontendAudio.ScreenMusic(screen, settingsReturn) ~= ""
end

---@param slot FrontendMusicSlot
local function stopMusicSlot(slot)
    slot.source.gain = 0
    slot.source:StopImmediate()
    slot.key, slot.gain = "", 0
end

local function silenceMusic()
    for _, slot in ipairs(music_) do stopMusicSlot(slot) end
    current_ = ""
end

local function silenceUI()
    for _, slot in ipairs(ui_) do
        slot.source.gain = 0
        slot.source:StopImmediate()
        slot.remaining = 0
    end
end

---@param path string
---@param looped boolean
local function request(path, looped)
    if not initialized_ or sounds_[path] or pending_[path] or failed_[path] then return end
    pending_[path] = true
    local generation = generation_
    cache:GetResourceAsync("Sound", path, function(resource)
        -- A previous session's callback cannot revive disposed nodes or stale music.
        if not initialized_ or generation ~= generation_ then return end
        pending_[path] = nil
        local sound = resource --[[@as Sound?]]
        if not sound or sound:GetFrequency() <= 0 or sound:GetLength() <= 0 then
            failed_[path] = true
            print("[前端音频] 资源不可用，保持静音：" .. path)
            return
        end
        sound:SetLooped(looped)
        sounds_[path] = sound
        print(string.format("[前端音频] Ready %s / %.2fs / %.0fHz", path, sound:GetLength(), sound:GetFrequency()))
        -- Deliberately no Play here: Update checks the CURRENT screen and preferences.
    end)
end

---@param screen string
---@param settingsReturn? string
function FrontendAudio.Prewarm(screen, settingsReturn)
    local key = FrontendAudio.ScreenMusic(screen, settingsReturn)
    local entry = FrontendAudio.Music[key]
    if entry then request(entry.path, true) end
end

---@param screenOrKind string menu/garage/loading/tracks/settings, or a UI kind
---@return boolean
function FrontendAudio.Ready(screenOrKind)
    local entry = FrontendAudio.Music[FrontendAudio.ScreenMusic(screenOrKind)] or FrontendAudio.Effects[screenOrKind]
    return initialized_ and entry ~= nil and sounds_[entry.path] ~= nil
end

-- Safe before Init (standalone HUD fixtures create neither scenes nor audio devices).
-- Call only in an actual user input callback. It never cancels platform/user master mute.
function FrontendAudio.Unlock()
    if not initialized_ then return end
    if not unlocked_ then print("[前端音频] 首次真实交互解锁") end
    unlocked_ = true
    local ok, device = pcall(GetAudio)
    if ok and device and device.initialized and not device.playing then device:Play() end
end

---@param enabled boolean
function FrontendAudio.SetMusicEnabled(enabled)
    if musicEnabled_ == (enabled == true) then return end
    musicEnabled_ = enabled == true
    if not musicEnabled_ then silenceMusic() end
end

---@param enabled boolean
function FrontendAudio.SetEffectsEnabled(enabled)
    if effectsEnabled_ == (enabled == true) then return end
    effectsEnabled_ = enabled == true
    if not effectsEnabled_ then silenceUI() end
end

---@param suspended boolean
function FrontendAudio.SetSuspended(suspended)
    suspended_ = suspended == true
    if suspended_ then silenceMusic(); silenceUI() end
end

---@param screen string
---@param settingsReturn? string
function FrontendAudio.SetScreen(screen, settingsReturn)
    if not initialized_ then return end
    local target = FrontendAudio.ScreenMusic(screen, settingsReturn)
    local changed = target ~= target_
    screen_, target_ = screen, target
    if target_ == "" and changed then
        -- No tail into countdown/radio/engine, including career and race settings.
        silenceMusic()
        silenceUI()
    else
        FrontendAudio.Prewarm(screen, settingsReturn)
    end
    if changed then print("[前端音频] screen=" .. screen .. " target=" .. (target_ ~= "" and target_ or "off")) end
end

-- Does not queue late clicks. Unready clips are requested but never replayed on completion.
-- Global 35ms + per-kind 75ms cooldown also coalesces touch/mouse duplicate delivery.
---@param kind? string click/page/select/confirm/back/unavailable
---@return boolean
function FrontendAudio.PlayUI(kind)
    if not initialized_ then return false end
    FrontendAudio.Unlock()
    local key = kind or "click"
    local entry = FrontendAudio.Effects[key]
    if not entry or not effectsEnabled_ or suspended_ then return false end
    if clock_ - lastAnyUI_ < 0.035 or clock_ - (lastUI_[key] or -10) < 0.075 then return false end
    local sound = sounds_[entry.path]
    if not sound then request(entry.path, false); return false end
    ---@type FrontendUISlot?
    local available = nil
    for _, slot in ipairs(ui_) do
        if slot.remaining <= 0 then available = slot; break end
    end
    -- Bounded pool: drop a saturated burst instead of cutting a confirmation or spawning.
    if not available then return false end
    available.source:Play(sound, 0, entry.gain)
    available.remaining = sound:GetLength() + 0.02
    lastAnyUI_, lastUI_[key] = clock_, clock_
    return true
end

---@param dt number
function FrontendAudio.Update(dt)
    if not initialized_ then return end
    local frameTime = finite(dt) and math.max(0, math.min(dt, 0.25)) or 0
    clock_ = clock_ + frameTime
    for _, slot in ipairs(ui_) do
        if slot.remaining > 0 then
            slot.remaining = math.max(0, slot.remaining - frameTime)
            if slot.remaining <= 0 then slot.source.gain = 0; slot.source:StopImmediate() end
        end
    end
    if not unlocked_ or not musicEnabled_ or suspended_ or target_ == "" then return end
    local entry = FrontendAudio.Music[target_]
    local sound = entry and sounds_[entry.path]
    ---@type FrontendMusicSlot?
    local selected = nil
    for _, slot in ipairs(music_) do if slot.key == target_ then selected = slot; break end end
    if sound and not selected then
        -- Reuse an idle source first; rapid transitions replace the quieter of TWO slots.
        local replacement = assert(music_[1])
        for _, slot in ipairs(music_) do if slot.gain < replacement.gain then replacement = slot end end
        stopMusicSlot(replacement)
        replacement.key = target_
        replacement.source:Play(sound, 0, 0.001)
        replacement.gain = 0.001
        selected = replacement
        print("[前端音频] Play " .. assert(entry).title)
    end
    for _, slot in ipairs(music_) do
        local targetGain = slot == selected and sound and entry and entry.gain or 0
        local delta = frameTime / FADE_SECONDS * (entry and entry.gain or 0.24)
        if slot.gain < targetGain then slot.gain = math.min(targetGain, slot.gain + delta)
        else slot.gain = math.max(targetGain, slot.gain - delta) end
        slot.source.gain = slot.gain
        if slot.key ~= "" and targetGain == 0 and slot.gain <= SILENCE then stopMusicSlot(slot) end
    end
    current_ = selected and target_ or ""
end

---@class FrontendAudioPreferences
---@field music boolean
---@field effects boolean
---@field track integer

-- Main's adapter keeps radio preferences intact while frontend owns the music bus.
---@param dt number
---@param screen string
---@param settingsReturn string?
---@param preferences FrontendAudioPreferences?
---@param ride RideAudio?
---@param raceDuck number
---@return boolean
function FrontendAudio.SyncRide(dt, screen, settingsReturn, preferences, ride, raceDuck)
    FrontendAudio.SetScreen(screen, settingsReturn)
    local frontend = FrontendAudio.IsFrontend(screen, settingsReturn)
    if ride then
        if preferences then preferences.music, preferences.effects = ride.musicEnabled, ride.effectsEnabled end
        ride.musicDuck = frontend and 0 or raceDuck
        if frontend then
            local radio = ride.sources[1]
            if radio and (radio.playing or radio.gain > 0) then radio.gain = 0; radio:StopImmediate() end
        end
    end
    if preferences then
        FrontendAudio.SetMusicEnabled(preferences.music)
        FrontendAudio.SetEffectsEnabled(preferences.effects)
    end
    FrontendAudio.Update(dt)
    return frontend
end

---@param preferences FrontendAudioPreferences
---@param getRide fun():RideAudio?
---@param sync fun(title:string,enabled:boolean)
---@return fun():boolean, fun(direction:integer)
function FrontendAudio.BindRadio(preferences, getRide, sync)
    local tracks = require("RideAudio").Tracks
    return function()
        local ride = getRide()
        local enabled = not preferences.music
        if ride then enabled = ride:ToggleMusic() end
        preferences.music = enabled
        FrontendAudio.SetMusicEnabled(enabled)
        sync(ride and ride:GetTrackTitle() or tracks[preferences.track].title, enabled)
        return enabled
    end, function(direction)
        local ride = getRide()
        if not ride then
            preferences.track = (preferences.track - 1 + direction) % #tracks + 1
            sync(tracks[preferences.track].title, preferences.music)
            return
        end
        -- Browsing stations is allowed, but cannot start in-race radio over the menu.
        local enabled = ride.musicEnabled
        if target_ ~= "" then ride.musicEnabled = false end
        local title = ride:ChangeTrack(direction)
        ride.musicEnabled = enabled
        preferences.track = ride.trackIndex
        sync(title, enabled)
    end
end

-- Init owns a retained audio Scene independent from the disposable race world.
---@param preferences? FrontendAudioPreferences
---@param screen? string
---@param settingsReturn? string
function FrontendAudio.Init(preferences, screen, settingsReturn)
    if initialized_ then return end
    generation_ = generation_ + 1
    scene_ = Scene()
    scene_.threadedUpdate = false
    local node = scene_:CreateChild("FrontendAudio", LOCAL)
    music_, ui_, sounds_, pending_, failed_, lastUI_ = {}, {}, {}, {}, {}, {}
    clock_, lastAnyUI_, screen_, target_, current_ = 0, -10, "", "", ""
    unlocked_, suspended_, initialized_ = false, false, true
    for index = 1, 2 do
        local source = node:CreateChild("Music" .. index, LOCAL):CreateComponent("SoundSource", LOCAL)
        source.soundType, source.gain, source.declickEnabled = SOUND_MUSIC, 0, true
        music_[index] = {source = source, key = "", gain = 0}
    end
    for index = 1, 4 do
        local source = node:CreateChild("UI" .. index, LOCAL):CreateComponent("SoundSource", LOCAL)
        source.soundType, source.gain, source.declickEnabled = SOUND_EFFECT, 0, true
        ui_[index] = {source = source, remaining = 0}
    end
    for _, key in ipairs({"click", "page", "select", "confirm", "back", "unavailable"}) do
        request(FrontendAudio.Effects[key].path, false)
    end
    print("[前端音频] 初始化 2 music + 4 UI channels；音乐按页面异步准备")
    if preferences then
        FrontendAudio.SetMusicEnabled(preferences.music)
        FrontendAudio.SetEffectsEnabled(preferences.effects)
    end
    if screen then FrontendAudio.SetScreen(screen, settingsReturn) end
end

function FrontendAudio.Stop()
    if not initialized_ then return end
    initialized_, unlocked_ = false, false
    generation_ = generation_ + 1
    silenceMusic(); silenceUI()
    if scene_ then scene_:Dispose() end
    scene_ = nil
    music_, ui_, sounds_, pending_, failed_, lastUI_ = {}, {}, {}, {}, {}, {}
    screen_, target_, current_ = "", "", ""
    print("[前端音频] 已停止并释放全部前端音源")
end
function FrontendAudio.Dispose() FrontendAudio.Stop() end

-- Real source references are exposed only for focused verification, never replacements/mocks.
function FrontendAudio.GetStatus()
    local musicStatus, uiStatus, loaded = {}, {}, {}
    for _, slot in ipairs(music_) do
        musicStatus[#musicStatus + 1] = {key = slot.key, gain = slot.gain,
            playing = slot.source.playing, source = slot.source, frequency = slot.source:GetFrequency()}
    end
    for _, slot in ipairs(ui_) do
        uiStatus[#uiStatus + 1] = {playing = slot.source.playing, source = slot.source, remaining = slot.remaining}
    end
    for path, sound in pairs(sounds_) do
        loaded[path] = {length = sound:GetLength(), frequency = sound:GetFrequency(), looped = sound.looped}
    end
    return {initialized = initialized_, unlocked = unlocked_, musicEnabled = musicEnabled_, effectsEnabled = effectsEnabled_,
        suspended = suspended_, screen = screen_, target = target_, current = current_, music = musicStatus,
        ui = uiStatus, loaded = loaded, failed = failed_, pending = pending_, scene = scene_}
end

return FrontendAudio
