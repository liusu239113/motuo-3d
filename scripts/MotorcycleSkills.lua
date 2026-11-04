-- 普通摩托纯规则状态；不创建场景、不读档、不调用SDK。MixedRace和AI共用。
local Data = require("MixedVehicles")
local M = {}

local function neutral(sim)
    sim.motorcycleSpeedScale,sim.motorcycleDriveScale,sim.motorcycleGripScale,sim.motorcycleOffroadScale=1,1,1,1
    sim.motorcycleDamageScale,sim.motorcycleRetained,sim.motorcycleDisruptScale,sim.motorcycleCoastDragScale=1,1,1,1
end
function M.Reset(sim)
    sim.motorcycleActive,sim.motorcycleCooldown,sim.motorcycleSkillHeld=0,0,false
    sim.motorcycleSkillName,sim.motorcycleSkillResult,sim.motorcycleSkillResultTimer="","",0
    sim.motorcyclePhase,sim.motorcycleSkillAge,sim.motorcycleSkillSerial="idle",0,0
    sim.motorcycleGuard,sim.motorcycleGuardFlash,sim.motorcycleGuardBlocks=0,0,0
    neutral(sim)
end

function M.Before(sim,dt,controls)
    if dt<=0 or sim.paused then return end
    local skill=Data.GetMotorcycleSkill(sim.vehicleId)
    sim.motorcycleActive=math.max(0,(sim.motorcycleActive or 0)-dt)
    sim.motorcycleCooldown=math.max(0,(sim.motorcycleCooldown or 0)-dt)
    sim.motorcycleSkillResultTimer=math.max(0,(sim.motorcycleSkillResultTimer or 0)-dt)
    sim.motorcycleGuardFlash=math.max(0,(sim.motorcycleGuardFlash or 0)-dt)
    local held=controls.skill==true
    local stability=skill and skill.tactic=="stability"
    local blocked=sim.airborne or controls.brake or controls.burnout or controls.clutch or sim.wrecked or sim.finished
        or ((sim.oddDisrupt or 0)>0 and not stability)
    if skill and held and not sim.motorcycleSkillHeld and sim.motorcycleCooldown<=0
        and sim.motorcycleActive<=0 and not blocked then
        sim.motorcycleActive,sim.motorcycleCooldown=skill.duration,skill.cooldown
        sim.motorcycleSkillSerial=(sim.motorcycleSkillSerial or 0)+1
        sim.motorcycleGuard=skill.shieldCharges or 0
        if stability then sim.oddDisrupt=0 end
        if skill.nitroGift and sim.raceMode then sim.oddNitroGift=(sim.oddNitroGift or 0)+skill.nitroGift end
        if skill.hopDuration then
            sim.oddHopDuration,sim.oddHopHeight,sim.oddHop=skill.hopDuration,skill.hopHeight,skill.hopDuration
        end
        sim.motorcycleSkillResult,sim.motorcycleSkillResultTimer=skill.name.." · 已发动",2
        sim.message,sim.messageTimer=sim.motorcycleSkillResult,2
        print("[摩托独立技能] "..sim.vehicleId.." / "..skill.name)
    end
    sim.motorcycleSkillHeld=held
    sim.motorcycleSkillName=skill and skill.name or ""
    neutral(sim)
    sim.motorcyclePhase="idle"
    if not skill or sim.motorcycleActive<=0 then sim.motorcycleGuard=0;return end
    sim.motorcycleSkillAge=skill.duration-sim.motorcycleActive
    -- 冷却/持续仍消耗；离地、刹车或失衡不凭空提供推进。稳向车可在失衡时自救。
    if blocked then sim.motorcyclePhase="suppressed";return end
    sim.motorcyclePhase="active"
    sim.motorcycleSpeedScale,sim.motorcycleDriveScale=skill.speedScale,skill.driveScale
    sim.motorcycleGripScale,sim.motorcycleOffroadScale=skill.gripScale,skill.offroadScale
    sim.motorcycleDamageScale,sim.motorcycleRetained=skill.damageScale or 1,skill.lossScale or 1
    sim.motorcycleDisruptScale,sim.motorcycleCoastDragScale=skill.disruptScale or 1,skill.coastDragScale or 1
    if skill.id=="sport" then
        local heat=math.min(1,sim.motorcycleSkillAge/.35)
        sim.motorcycleDriveScale=1+(skill.driveScale-1)*heat
        sim.motorcycleSpeedScale=1+(skill.speedScale-1)*heat
    elseif skill.tactic=="corner" then
        local turning=math.abs(controls.steer or sim.steer or 0)>.15
        sim.motorcycleDriveScale=turning and skill.driveScale or 1.08
        sim.motorcycleSpeedScale=turning and 1.02 or skill.speedScale
    elseif skill.chargeTime and sim.motorcycleSkillAge<skill.chargeTime then
        sim.motorcyclePhase="charge"
        sim.motorcycleDriveScale,sim.motorcycleSpeedScale=.78,1
    elseif skill.hopDuration and (sim.oddHop or 0)>0 then
        sim.motorcyclePhase="hop"
    elseif skill.shieldCharges then sim.motorcyclePhase="guard" end
end

-- 所有真实伤害入口调用。一次格挡立即消费；渲染只能读取flash/blocks，不能回写命中。
function M.Absorb(sim,kind)
    if not sim or (sim.motorcycleActive or 0)<=0 or (sim.motorcycleGuard or 0)<=0
        or sim.motorcyclePhase=="suppressed" then return false end
    sim.motorcycleGuard=0
    sim.motorcycleActive=0
    sim.motorcyclePhase="spent"
    sim.motorcycleGuardFlash=.45
    sim.motorcycleGuardBlocks=(sim.motorcycleGuardBlocks or 0)+1
    sim.motorcycleSkillResult,sim.motorcycleSkillResultTimer="拒绝内耗 · 已挡住"..(kind or "撞击").."，护盾已消耗",2
    sim.message,sim.messageTimer=sim.motorcycleSkillResult,2
    neutral(sim)
    return true
end

-- 返回实际保留速度比例与扣血倍率；普通比赛与混合比赛中的摩托使用同一规则。
function M.Contact(sim,retained)
    if not sim or not Data.GetMotorcycleSkill(sim.vehicleId) then return retained,1 end
    if M.Absorb(sim,"车辆撞击") then return 1,0 end
    return 1-(1-retained)*(sim.motorcycleRetained or 1),sim.motorcycleDamageScale or 1
end

function M.ShouldUse(skill,sim,speed,front,obstacle,curve)
    local tactic=skill.tactic
    if tactic=="straight" then return speed>8 and not obstacle and curve<.012 end
    if tactic=="charge" then return speed<14 or (front and not obstacle and curve<.012) end
    if tactic=="corner" then return speed>6 and curve>.008 and not obstacle end
    if tactic=="hop" then return speed>6 and (obstacle or front) and curve<.018 end
    if tactic=="stability" then return (sim.oddDisrupt or 0)>0 or (speed>6 and (curve>.008 or obstacle)) end
    if tactic=="delivery" then return speed>3 and not obstacle and (front or speed<30) end
    if tactic=="armor" or tactic=="guard" then return speed>4 and (front or obstacle) end
    return speed>6 and (front or obstacle or (sim.throttle or 0)<.05)
end

return M
