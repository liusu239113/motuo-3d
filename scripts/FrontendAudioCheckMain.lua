-- Focused real Sound/Source lifecycle checks. No HUD, World, SDK or player storage.
assert(cache:AddResourceDir("/workspace/assets", false))
assert(cache:AddResourceDir("/workspace/scripts", false))
cache.searchPackagesFirst = false
local Frontend = require("FrontendAudio")
local frames_, stage_, assertions_ = 0, 0, 0
local completed_ = false
local sources_ = {}
local function check(value, message)
    assert(value, "[FrontendAudioCheck] " .. message)
    assertions_ = assertions_ + 1
end
local function activeMusic()
    local count = 0
    for _, slot in ipairs(Frontend.GetStatus().music) do
        if slot.source.playing and slot.source.gain > 0 then count = count + 1 end
    end
    return count
end
local function advance(count)
    for _ = 1, count do Frontend.Update(0.1) end
end
function Start()
    check(not Frontend.PlayUI("click"), "HUD-only call before Init is harmless")
    check(not Frontend.GetStatus().initialized, "PlayUI does not construct a scene")
    Frontend.Init({music = true, effects = true, track = 1}, "menu")
    local status = Frontend.GetStatus()
    check(status.initialized and not status.unlocked and #status.music == 2 and #status.ui == 4, "fixed 2+4 sources and initial lock")
    check(not Frontend.Ready("garage") and not Frontend.Ready("loading"), "first menu does not gate/download other tracks")
    for _, slot in ipairs(status.music) do sources_[#sources_ + 1] = slot.source end
    for _, slot in ipairs(status.ui) do sources_[#sources_ + 1] = slot.source end
    check(#status.scene:GetComponents("SoundSource", true) == 6, "actual Scene has exactly six sources")
    check(not package.loaded["HUD"] and not package.loaded["Profile"] and not package.loaded["World"], "no profile/world loaded")
    SubscribeToEvent("Update", "HandleFrontendAudioCheck")
end
function HandleFrontendAudioCheck()
    if completed_ then return end
    frames_ = frames_ + 1
    check(frames_ < 160, "bounded resource wait")
    if stage_ == 0 then
        for _, key in ipairs({"menu", "click", "page", "select", "confirm", "back", "unavailable"}) do
            if not Frontend.Ready(key) then return end
        end
        advance(10)
        check(activeMusic() == 0, "ready tracks never auto-play before gesture")
        Frontend.Unlock() -- Explicit test gesture, not production autoplay.
        advance(10)
        local status = Frontend.GetStatus()
        check(status.current == "menu" and activeMusic() == 1, "actual menu source starts after unlock")
        for _, slot in ipairs(status.music) do
            if slot.key == "menu" then
                check(slot.source.sound.name == Frontend.Music.menu.path, "real source binds menu Sound")
                check(slot.frequency == slot.source.sound:GetFrequency() and slot.frequency == 48000, "absolute Hz, no pitch-multiplier bug")
                check(slot.source.sound.looped and math.abs(slot.gain - Frontend.Music.menu.gain) < .001, "loop and fade endpoint")
            end
        end
        for _, kind in ipairs({"click", "page", "select", "confirm", "back", "unavailable"}) do
            advance(12)
            check(Frontend.PlayUI(kind), "generated UI clip plays " .. kind)
            local found = false
            for _, slot in ipairs(Frontend.GetStatus().ui) do
                if slot.source.playing then
                    check(not slot.source.sound.looped and slot.source.sound.name == Frontend.Effects[kind].path, "real one-shot Sound " .. kind)
                    found = true
                end
            end
            check(found, "actual playing UI source " .. kind)
            check(not Frontend.PlayUI(kind), "duplicate delivery cooldown " .. kind)
        end
        Frontend.SetEffectsEnabled(false)
        check(not Frontend.PlayUI("click"), "effects toggle blocks UI")
        for _, slot in ipairs(Frontend.GetStatus().ui) do check(not slot.source.playing and slot.source.gain == 0, "effects toggle stops actual sources") end
        check(activeMusic() == 1, "SFX toggle does not mute music")
        Frontend.SetEffectsEnabled(true)
        Frontend.SetMusicEnabled(false)
        check(activeMusic() == 0, "music mute stops both sources immediately")
        advance(10)
        check(activeMusic() == 0, "muted updates do not restart")
        Frontend.SetMusicEnabled(true)
        advance(10)
        check(activeMusic() == 1, "music enable resumes current screen")
        Frontend.SetScreen("garage")
        stage_ = 1
    elseif stage_ == 1 then
        if not Frontend.Ready("garage") then return end
        Frontend.Update(.1)
        check(activeMusic() == 2, "two real sources during menu/garage crossfade")
        advance(12)
        check(Frontend.GetStatus().current == "garage" and activeMusic() == 1, "garage replaces menu")
        Frontend.SetScreen("settings", "garage"); advance(2)
        check(Frontend.GetStatus().current == "garage", "garage settings keep garage track")
        Frontend.SetScreen("loading")
        Frontend.SetScreen("menu") -- resource completion must not play a stale screen
        stage_ = 2
    elseif stage_ == 2 then
        if not Frontend.Ready("loading") then return end
        advance(10)
        check(Frontend.GetStatus().current == "menu", "late loading Ready cannot steal current screen")
        Frontend.SetScreen("loading"); advance(10)
        check(Frontend.GetStatus().current == "loading" and activeMusic() == 1, "distinct loading track")
        local status = Frontend.GetStatus()
        local loaded = 0
        for path, sound in pairs(status.loaded) do
            loaded = loaded + 1
            check(sound.length > 0 and sound.frequency == 48000, "real decoded asset " .. path)
        end
        check(loaded == 9 and #status.music == 2 and #status.ui == 4, "all nine real assets cached, no source growth")
        for index, slot in ipairs(status.music) do check(slot.source == sources_[index], "music source reused") end
        for index, slot in ipairs(status.ui) do check(slot.source == sources_[index + 2], "UI source reused") end
        for _, screen in ipairs({"ride", "pause", "result", "career"}) do
            Frontend.SetScreen(screen); advance(2)
            check(activeMusic() == 0, "does not overlap radio/engine on " .. screen)
        end
        Frontend.SetScreen("settings", "pause"); advance(2)
        check(activeMusic() == 0, "race settings do not play frontend music")
        Frontend.SetScreen("menu"); advance(10)
        Frontend.SetSuspended(true)
        check(activeMusic() == 0 and not Frontend.PlayUI("click"), "focus loss suspends owned sources")
        Frontend.SetSuspended(false); advance(10)
        check(activeMusic() == 1, "focus restore resumes current screen")
        local device = GetAudio()
        print(string.format("[FrontendAudioCheck] output initialized=%s playing=%s (source checks are not a speaker audition)", tostring(device.initialized), tostring(device.playing)))
        Frontend.Stop(); Frontend.Stop(); Frontend.Update(.1)
        status = Frontend.GetStatus()
        check(not status.initialized and status.scene == nil and #status.music == 0 and #status.ui == 0, "idempotent Dispose clears Scene and all sources")
        check(not Frontend.PlayUI("confirm"), "no revival after Stop")
        completed_ = true
        print(string.format("[FrontendAudioCheck] PASS %d assertions / 9 actual Sounds / 2+4 reused real sources / 3 distinct tracks / no saves / frames=%d", assertions_, frames_))
        UnsubscribeFromEvent("Update")
    end
end
function Stop()
    Frontend.Dispose()
    check(completed_, "all audio lifecycle stages must complete")
end
