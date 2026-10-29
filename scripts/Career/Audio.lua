-- 生涯独立混音：真实位移 + 鞋底支撑边沿，不从速度推算敲击节拍。
-- 生命周期由Session持有；不订阅Update、不改全局音量、不读写存档。
local World=require("Career.WorldData")
---@class CareerFootstepState
---@field x? number
---@field z? number
---@field distance number
---@field elapsed number
---@field leftArmed boolean
---@field rightArmed boolean
---@field lastFoot string
local FootstepStateType={}
---@class CareerAudioContext
---@field surface? string concrete/sand/wood；由CityEnvironment.SurfaceKind同源提供
---@field sea? number 0..1
---@field bridge? number 0..1
---@field urban? number 0..1
---@field traffic? number 0..1
---@field grounded? boolean false强制禁止落足音
---@field left? number 左鞋底到实际地表高度，米，不是骨骼踝点高度
---@field right? number 右鞋底到实际地表高度，米
local AudioContextType={}
---@class CareerSoundscape
---@field sources table<string,SoundSource>
---@field sounds table<string,Sound>
---@field stepState CareerFootstepState
---@field zones table[]
local Audio={}
Audio.__index=Audio
Audio.Paths={music="audio/night_ride.ogg",electric="audio/sfx/career_ebike_motor.mp3",
    engine="audio/sfx/motorcycle_engine_loop.mp3",steps="audio/sfx/career_step_concrete_natural.wav",
    sand="audio/sfx/career_step_sand_natural.wav",wood="audio/sfx/career_step_wood_natural.wav",
    city="audio/sfx/career_city_ambience.mp3",sea="audio/sfx/career_coastal_surf_bed.ogg",
    bridge="audio/sfx/career_bridge_wind_bed.ogg",traffic="audio/sfx/career_distant_traffic_bed.ogg",
    tap="audio/sfx/career_ui_tap.mp3",order="audio/sfx/career_order_chime.mp3",brake="audio/sfx/motorcycle_brake_loop.mp3"}
Audio.Resources,Audio.ResourceTypes={},{}
for _,path in pairs(Audio.Paths) do Audio.Resources[#Audio.Resources+1]=path; Audio.ResourceTypes[path]="Sound" end
Audio.StepGain={concrete=.24,sand=.23,wood=.20}
local singles={steps=true,sand=true,wood=true,tap=true,order=true}
local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
local function unit(n) return finite(n) and math.max(0,math.min(1,n)) or 0 end
local function smooth(n) local t=unit(n); return t*t*(3-2*t) end
function Audio.NewStepState()
    return {distance=0,elapsed=0,leftArmed=false,rightArmed=false,lastFoot=""} --[[@as CareerFootstepState]]
end
function Audio.ResetSteps(state,x,z)
    state.x,state.z=x,z
    state.distance,state.elapsed=0,0
    state.leftArmed,state.rightArmed=false,false
    state.lastFoot=""
end
-- 单步接触设计（侧视，米）：
--       抬脚 > .028 -> armed       落足 <= .018 -> 一次接触边沿
--    鞋底 ___/\________       地表 __________________________
-- 仅在真实水平移动>=.14m、同脚已抬起、距上步>=.16s时发声；不以墙上接触当支撑。
-- 不累计空中、暂停、骑行或室内位移；传送/大dt重同步，不补发遗漏脚步。
---@param state CareerFootstepState
---@param dt number
---@param sample table x/z/left/right/grounded/enabled
---@return string? foot
function Audio.AdvanceStep(state,dt,sample)
    if not finite(sample.x) or not finite(sample.z) then Audio.ResetSteps(state); return nil end
    local x,z=sample.x,sample.z
    local previousX,previousZ=state.x,state.z
    state.x,state.z=x,z
    if not sample.enabled or sample.grounded~=true or not finite(dt) or dt<=0 or dt>.25
        or not previousX or not previousZ then
        Audio.ResetSteps(state,x,z); return nil
    end
    local moved=math.sqrt((x-previousX)^2+(z-previousZ)^2)
    if moved<=.00001 or moved>6*dt+.08 then Audio.ResetSteps(state,x,z); return nil end
    state.distance=math.min(1.7,state.distance+moved)
    state.elapsed=math.min(1,state.elapsed+dt)
    local contact
    for _,side in ipairs({"left","right"}) do
        local height=sample[side]
        local armed=side=="left" and state.leftArmed or side=="right" and state.rightArmed
        if finite(height) then
            if height>.028 then
                if side=="left" then state.leftArmed=true else state.rightArmed=true end
            elseif height>=-.045 and height<=.018 and armed then
                if side=="left" then state.leftArmed=false else state.rightArmed=false end
                if not contact and state.distance>=.14 and state.elapsed>=.16 and state.lastFoot~=side then contact=side end
            end
        end
    end
    if contact then state.distance,state.elapsed=0,0; state.lastFoot=contact end
    return contact
end

local function zoneWeight(zone,x,z)
    local dx=math.max(zone.x1-x,0,x-zone.x2)
    local dz=math.max(zone.z1-z,0,z-zone.z2)
    local distance=math.sqrt(dx*dx+dz*dz)
    return smooth(1-distance/math.max(.01,zone.fade or 24))
end
-- 纯区域权重；不虚构海岸。主线程传环境模块AudioContext时完全复用其同源区域。
function Audio.Environment(x,z,context,zones)
    context=context or {}
    local road=math.huge
    for _,r in ipairs(World.Roads) do
        local dx,dz=r.x2-r.x1,r.z2-r.z1
        local length=dx*dx+dz*dz
        local t=length>0 and math.max(0,math.min(1,((x-r.x1)*dx+(z-r.z1)*dz)/length)) or 0
        road=math.min(road,math.max(0,math.sqrt((x-r.x1-dx*t)^2+(z-r.z1-dz*t)^2)-r.width/2))
    end
    local traffic=smooth(1-road/75)
    local urban=World.District(x,z).density*traffic
    local mix={sea=0,bridge=zoneWeight({x1=-38,x2=38,z1=-78.5,z2=-61.5,fade=12},x,z),urban=urban,traffic=traffic,surface="concrete"}
    for _,zone in ipairs(zones or {}) do
        local weight=zoneWeight(zone,x,z)
        if zone.kind=="sand" or zone.kind=="wood" then
            if weight>=.999 then mix.surface=zone.kind end
        elseif mix[zone.kind]~=nil then mix[zone.kind]=math.max(mix[zone.kind],weight) end
    end
    for _,kind in ipairs({"sea","bridge","urban","traffic"}) do
        if context[kind]~=nil then mix[kind]=unit(context[kind]) end
    end
    if context.surface=="sand" or context.surface=="wood" or context.surface=="concrete" then mix.surface=context.surface end
    return mix
end
---@param scene Scene
---@return CareerSoundscape
function Audio.New(scene)
    local self=setmetatable({},Audio)
    self:Init(scene); return self
end
function Audio:Init(scene)
    self.node=scene:CreateChild("生涯音乐与分区音景")
    self.sources,self.sounds={},{}
    self.musicEnabled,self.effectsEnabled,self.unlocked=true,true,false
    self.lastOrder,self.lastSurface="","concrete"
    self.stepState=Audio.NewStepState()
    self.zones={}
    self.mix={sea=0,bridge=0,urban=0,traffic=0,surface="concrete"}
    self.mixElapsed=1
    self.stepDistance,self.stepCount,self.orderCount=0,0,0
    self.paused,self.disposed=false,false
    for key,path in pairs(Audio.Paths) do
        local sound=cache:GetResource("Sound",path)
        if sound and sound:GetLength()>0 then
            sound.looped=not singles[key]
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
function Audio:SetZones(zones) self.zones=zones or {}; self.mixElapsed=1 end
function Audio:StopSteps()
    for _,key in ipairs({"steps","sand","wood"}) do
        local source=self.sources[key]
        if source then source:StopImmediate(); source.gain=0 end
    end
end
function Audio:SetPaused(paused)
    self.paused=paused
    if paused then
        for _,source in pairs(self.sources) do source:StopImmediate(); source.gain=0 end
        Audio.ResetSteps(self.stepState)
        self.stepDistance=0
    end
end
function Audio:Once(key)
    if self.disposed or self.paused or not self.unlocked or not self.effectsEnabled then return end
    local source,sound=self.sources[key],self.sounds[key]
    if source and sound then
        source:Play(sound,0,key=="tap" and .18 or key=="steps" and Audio.StepGain.concrete or .35)
        if key=="steps" then self.stepCount=self.stepCount+1 end
        if key=="order" then self.orderCount=self.orderCount+1 end
    end
end
function Audio:Footstep(surface,foot)
    local kind=surface=="sand" and "sand" or surface=="wood" and "wood" or "concrete"
    local key=kind=="concrete" and "steps" or kind
    local source,sound=self.sources[key],self.sounds[key]
    if not source or not sound or not self.unlocked or not self.effectsEnabled or self.paused then return end
    -- 只作极轻的左右支撑定位，不用大幅随机pitch冒充多个素材。
    source:Play(sound,0,Audio.StepGain[kind],foot=="left" and -.055 or .055)
    self.lastSurface=kind; self.stepCount=self.stepCount+1
end
function Audio:Loop(key,gain,pitch,dt)
    local source,sound=self.sources[key],self.sounds[key]
    if not source or not sound then return end
    local enabled=not self.paused and self.unlocked and (key=="music" and self.musicEnabled or key~="music" and self.effectsEnabled)
    local target=enabled and math.max(0,gain) or 0
    local ambience=key=="sea" or key=="bridge" or key=="traffic" or key=="city"
    local rate=ambience and .9 or 7
    local level=source.gain+(target-source.gain)*(1-math.exp(-dt*rate))
    if target==0 and level<.0005 then source.gain=0; if source.playing then source:StopImmediate() end; return end
    if target>0 and not source.playing then source:Play(sound,sound:GetFrequency()*pitch,level) end
    source.gain=level; source.frequency=sound:GetFrequency()*pitch
end
-- 只读当前已求值的鞋底。无骨架或无地表时不假造支撑；context可接物理/FSM落足探针。
---@param actor CareerActor|table
---@param context CareerAudioContext
---@return table
function Audio.Support(actor,context)
    local result={x=actor.x,z=actor.z,grounded=false,left=context.left,right=context.right}
    if context.grounded==false or actor.mounted or actor.grounded==false or actor.onGround==false then return result end
    local visuals=actor.visuals
    local rig=visuals and visuals.walker
    local city=actor.city
    if rig and city and not rig.disposed then
        local root=rig.parent.worldPosition
        for _,side in ipairs({"left","right"}) do
            if result[side]==nil then
                local bone=side=="left" and "L_Foot" or "R_Foot"
                local localFoot=rig:GetBonePosition(bone) --[[@as Vector3]]
                local world=rig.parent:LocalToWorld(localFoot)
                result[side]=root.y+rig:SoleHeight(bone)-city:WalkSurface(world.x,world.z,root.y)
            end
        end
        local ground=city:WalkSurface(actor.x,actor.z,actor.walkHeight or root.y)
        result.grounded=math.abs(root.y-ground)<.12
    end
    if context.grounded~=nil then result.grounded=context.grounded==true end
    return result
end
---@param context? CareerAudioContext
function Audio:Update(dt,actor,blocked,indoor,controls,order,context)
    if self.disposed then return end
    context,controls=context or {},controls or {}
    local id=order and order.id or ""
    if blocked or not finite(dt) or dt<=0 or dt>.25 or not actor then
        self:SetPaused(true); self.lastOrder=id; return
    end
    self.paused=false
    local moving=math.abs(actor.speed or 0)
    local ride=actor.mounted and not indoor
    local electric=actor.vehicleId=="borrowed_ebike"
    self.mixElapsed=self.mixElapsed+dt
    if self.mixElapsed>=.25 then
        self.mix=Audio.Environment(actor.x,actor.z,context,self.zones); self.mixElapsed=0
    end
    if context.surface=="sand" or context.surface=="wood" or context.surface=="concrete" then self.mix.surface=context.surface end
    local mix=self.mix
    self:Loop("music",.12,1,dt)
    -- Equal-power crossfade from street bed to surf; distinct wind/traffic stems are localized.
    local outdoor=indoor and 0 or 1
    self:Loop("city",outdoor*.13*math.sqrt(mix.urban)*math.sqrt(1-mix.sea)*(.9-.35*mix.bridge),1,dt)
    self:Loop("sea",outdoor*.29*math.sqrt(mix.sea),1,dt)
    self:Loop("bridge",outdoor*.25*mix.bridge,1,dt)
    self:Loop("traffic",outdoor*.21*mix.traffic*(1-.78*mix.sea),1,dt)
    local drive=unit(controls.throttle)
    self:Loop("electric",ride and electric and moving>.1 and (.04+math.min(1,moving/10)*.17+drive*.04) or 0,.75+math.min(1,moving/10)*.6,dt)
    self:Loop("engine",ride and not electric and (.09+drive*.08+math.min(1,moving/17)*.08) or 0,.7+math.min(1,moving/17)*.8+drive*.1,dt)
    local sample=Audio.Support(actor,context)
    sample.enabled=not actor.mounted and not indoor and self.unlocked and self.effectsEnabled
    local foot=Audio.AdvanceStep(self.stepState,dt,sample)
    self.stepDistance=self.stepState.distance
    if foot then self:Footstep(mix.surface,foot) end
    if not sample.enabled or not sample.grounded or self.stepState.distance==0 and not foot then self:StopSteps() end
    self:Loop("brake",ride and controls.brake and moving>1 and .08 or 0,1,dt)
    if id~="" and id~=self.lastOrder then self:Once("order") end
    self.lastOrder=id
end
function Audio:Stop()
    if self.disposed then return end
    self:SetPaused(true); self.disposed=true
    self.node:Dispose(); self.sources,self.sounds={},{}
end
return Audio
