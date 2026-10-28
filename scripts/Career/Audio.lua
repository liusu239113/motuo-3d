-- 生涯独立混音；不改旧竞速音源/全局音量。浏览器音频由手机触摸后解锁。
---@class CareerSoundscape
local Audio={}
Audio.__index=Audio
Audio.Paths={music="audio/night_ride.ogg",electric="audio/sfx/career_ebike_motor.mp3",
    engine="audio/sfx/motorcycle_engine_loop.mp3",steps="audio/sfx/career_step_single.wav",
    city="audio/sfx/career_city_ambience.mp3",tap="audio/sfx/career_ui_tap.mp3",order="audio/sfx/career_order_chime.mp3",
    brake="audio/sfx/motorcycle_brake_loop.mp3"}
Audio.Resources={}
for _,path in pairs(Audio.Paths) do Audio.Resources[#Audio.Resources+1]=path end
function Audio.New(scene)
    local self=setmetatable({},Audio)
    self:Init(scene)
    return self
end
function Audio:Init(scene)
    self.node=scene:CreateChild("生涯音乐与城市音效")
    self.sources,self.sounds={},{}
    self.musicEnabled,self.effectsEnabled,self.unlocked=true,true,false
    self.lastOrder=""
    self.stepDistance=0
    self.stepCount=0
    self.orderCount=0
    for key,path in pairs(Audio.Paths) do
        local sound=cache:GetResource("Sound",path)
        if sound and sound:GetLength()>0 then
            sound.looped=key~="tap" and key~="order" and key~="steps"
            self.sounds[key]=sound
            local source=self.node:CreateChild(key):CreateComponent("SoundSource")
            source.soundType=key=="music" and SOUND_MUSIC or SOUND_EFFECT
            source.declickEnabled=true; source.gain=0
            self.sources[key]=source
            print("[生涯音频] 已加载 "..key.." "..path)
        else print("[生涯音频错误] 缺少可播放素材 "..path) end
    end
end
function Audio:Unlock() self.unlocked=true end
function Audio:Once(key)
    if not self.unlocked or not self.effectsEnabled then return end
    local source,sound=self.sources[key],self.sounds[key]
    if source and sound then
        source:Play(sound,0,key=="tap" and .3 or key=="steps" and .62 or .55)
        if key=="steps" then self.stepCount=self.stepCount+1 end
        if key=="order" then self.orderCount=self.orderCount+1 end
    end
end
function Audio:Loop(key,gain,pitch,dt)
    local source,sound=self.sources[key],self.sounds[key]
    if not source or not sound then return end
    local target=self.unlocked and (key=="music" and self.musicEnabled or key~="music" and self.effectsEnabled) and gain or 0
    local level=source.gain+(target-source.gain)*(1-math.exp(-dt*7))
    if target==0 and level<.002 then source.gain=0; if source.playing then source:StopImmediate() end; return end
    if target>0 and not source.playing then source:Play(sound,sound:GetFrequency()*pitch,level) end
    source.gain=level; source.frequency=sound:GetFrequency()*pitch
end
function Audio:Update(dt,actor,blocked,indoor,controls,order)
    local moving=not blocked and math.abs(actor.speed) or 0
    local ride=actor.mounted and not blocked
    local electric=actor.vehicleId=="borrowed_ebike"
    self:Loop("music",blocked and .08 or .18,1,dt)
    self:Loop("city",indoor and .025 or blocked and .05 or .17,1,dt)
    local drive=math.max(0,controls.throttle or 0)
    self:Loop("electric",ride and electric and moving>.1 and (.06+math.min(1,moving/10)*.23+drive*.05) or 0,.75+math.min(1,moving/10)*.6,dt)
    self:Loop("engine",ride and not electric and (.11+drive*.1+math.min(1,moving/17)*.1) or 0,.7+math.min(1,moving/17)*.8+drive*.1,dt)
    -- 按实际行走距离触发单步，不循环整段录音；撞墙不走、松杆、手机与暂停都立即停脚步。
    if not actor.mounted and moving>.1 and self.effectsEnabled then
        self.stepDistance=self.stepDistance+moving*math.min(dt,.25)
        if self.stepDistance>=.625 then
            self.stepDistance=self.stepDistance%.625
            self:Once("steps")
        end
    else
        self.stepDistance=0
        if self.sources.steps then self.sources.steps:StopImmediate() end
    end
    self:Loop("brake",ride and controls.brake and moving>1 and .12 or 0,1,dt)
    local id=order and order.id or ""
    if id~="" and id~=self.lastOrder then self:Once("order") end
    self.lastOrder=id
end
function Audio:Stop()
    for _,source in pairs(self.sources) do source:StopImmediate() end
    self.node:Dispose()
end
return Audio
