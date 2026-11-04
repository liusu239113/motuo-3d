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
    local skill=Data.GetMotorcycleSkill(sim.vehicleId)
    sim.motorcycleActive=math.max(0,(sim.motorcycleActive or 0)-dt)
    sim.motorcycleCooldown=math.max(0,(sim.motorcycleCooldown or 0)-dt)
    sim.motorcycleSkillResultTimer=math.max(0,(sim.motorcycleSkillResultTimer or 0)-dt)
    sim.motorcycleGuardFlash=math.max(0,(sim.motorcycleGuardFlash or 0)-dt)
    local held=controls.skill==true
    local blocked=(sim.oddDisrupt or 0)>0 or sim.airborne or controls.brake or controls.burnout or sim.wrecked or sim.finished
    if skill and held and not sim.motorcycleSkillHeld and sim.motorcycleCooldown<=0
        and sim.motorcycleActive<=0 and not blocked then
        sim.motorcycleActive,sim.motorcycleCooldown=skill.duration,skill.cooldown
        sim.motorcycleSkillSerial=(sim.motorcycleSkillSerial or 0)+1
        sim.motorcycleGuard=skill.shieldCharges or 0
        sim.motorcycleSkillResult,sim.motorcycleSkillResultTimer=skill.name.." · 已发动",2
        print("[摩托独立技能] "..sim.vehicleId.." / "..skill.name)
    end
    sim.motorcycleSkillHeld=held
    sim.motorcycleSkillName=skill and skill.name or ""
    neutral(sim)
    sim.motorcyclePhase="idle"
    if not skill or sim.motorcycleActive<=0 then sim.motorcycleGuard=0;return end
    sim.motorcycleSkillAge=skill.duration-sim.motorcycleActive
    -- 冷却/持续仍消耗；离地、刹车或失衡不凭空提供推进，视觉同时显示暂停生效。
    if blocked then sim.motorcyclePhase="suppressed";return end
    sim.motorcyclePhase="active"
    sim.motorcycleSpeedScale,sim.motorcycleDriveScale=skill.speedScale,skill.driveScale
    sim.motorcycleGripScale,sim.motorcycleOffroadScale=skill.gripScale,skill.offroadScale
    sim.motorcycleDamageScale,sim.motorcycleRetained=skill.damageScale or 1,skill.lossScale or 1
    sim.motorcycleDisruptScale,sim.motorcycleCoastDragScale=skill.disruptScale or 1,skill.coastDragScale or 1
    if skill.chargeTime and sim.motorcycleSkillAge<skill.chargeTime then
        sim.motorcyclePhase="charge"
        sim.motorcycleDriveScale,sim.motorcycleSpeedScale=.78,1
    elseif skill.tactic=="hill" then
        sim.motorcycleDriveScale=(sim.groundSlope or 0)>.025 and skill.driveScale or 1.08
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
    sim.motorcycleSkillResult,sim.motorcycleSkillResultTimer="赤铜格挡 · 已挡住"..(kind or "撞击").."，护盾已消耗",2
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
    if tactic=="straight" or tactic=="charge" then return speed>8 and front and not obstacle and curve<.012 end
    if tactic=="corner" then return speed>6 and curve>.008 and not obstacle end
    if tactic=="rough" then return speed>6 and ((sim.oddTerrain or "asphalt")~="asphalt" or sim.onRoad==false) end
    if tactic=="stability" then return speed>6 and (curve>.008 or sim.oddTerrain=="ice" or sim.oddTerrain=="slime") end
    if tactic=="hill" then return speed>6 and (sim.groundSlope or 0)>.025 and not obstacle end
    if tactic=="armor" or tactic=="guard" then return speed>4 and (front or obstacle) end
    return speed>6 and (front or (sim.throttle or 0)<.05)
end

return M
