-- 街机混合竞速：能力改变真实动力/碰撞，不以模型动画代替效果。
local Data=require("MixedVehicles")
local Motorcycle=require("MotorcycleSkills")
local M={}
local function clamp(x,a,b) return math.max(a,math.min(b,x)) end
local function gap(a,b,length) return (a-b+length*.5)%length-length*.5 end
local function skillFor(id)
    local mixed=Data.Get(id)
    if mixed then
        return {id=mixed.id,name=mixed.skill,skill=mixed.skill,description=mixed.active,active=mixed.active,
            cooldown=mixed.cooldown,duration=mixed.duration,triggerDistance=0,
            speedScale=1,driveScale=1,gripScale=1,offroadScale=1,odd=true}
    end
    local motorcycle=Data.GetMotorcycleSkill(id)
    if motorcycle then
        return {id=motorcycle.id,name=motorcycle.name,skill=motorcycle.name,
            description=motorcycle.description,active=motorcycle.description,
            cooldown=motorcycle.cooldown,duration=motorcycle.duration,
            triggerDistance=motorcycle.triggerDistance,speedScale=motorcycle.speedScale,
            driveScale=motorcycle.driveScale,gripScale=motorcycle.gripScale,
            offroadScale=motorcycle.offroadScale,visual=motorcycle.visual,tactic=motorcycle.tactic,
            chargeTime=motorcycle.chargeTime,odd=false}
    end
    return nil
end
---@param id string
---@return table?
function M.GetSkill(id) return skillFor(id) end
function M.Reset(sim)
    sim.oddActive,sim.oddCooldown,sim.oddAltitude,sim.oddSkillFlash=0,0,0,0
    sim.oddLaunch,sim.oddHopDuration=0,.85
    sim.oddHopHeight,sim.oddNitroGift=nil,nil
    sim.oddSteam,sim.oddSpring,sim.oddCombo,sim.oddComboTimer=0,22,0,0
    sim.oddHop,sim.oddHitLock,sim.oddDisrupt,sim.oddShield=0,0,0,0
    sim.oddSkillHeld,sim.oddAttack=false,false
    sim.oddSpeedScale,sim.oddDriveScale,sim.oddGripScale=1,1,1
    Motorcycle.Reset(sim)
    sim.skillHitLock=0
    -- Five mixed vehicles expose one stable action contract to presentation.
    -- phase is a finite-state label, age is seconds since the valid activation,
    -- and serial changes only on a valid activation (never on a visual update).
    sim.oddPhase,sim.oddAge,sim.oddSerial="idle",0,0
    sim.oddHitTime,sim.oddHitAge,sim.oddHitSerial,sim.oddAttackSerial=0,0,0,0
    sim.oddAttackResolved=false
    sim.oddJetSide,sim.oddJetLateralSpeed,sim.oddJetDistance,sim.oddJetStep=1,0,0,0
    sim.oddDriftStep,sim.oddDriftSide=0,1
    sim.oddWindupSerial,sim.oddWoundRelease,sim.oddSpringMax,sim.oddWindupStart=0,0,22,22
    sim.oddLandingSerial,sim.oddLandingBoost=0,0
    -- Canonical vehicle frame: +Z forward, +X right, y is wheel/base contact.
    -- These are the stable closed-jaw mouth coordinates; presentation may replace
    -- them with measured oddGrabLocalX/Y/Z without changing the pure race rule.
    sim.oddGrabLocalX,sim.oddGrabLocalY,sim.oddGrabLocalZ=0,.78,1.72
    sim.oddSkillName="";sim.oddTerrain="asphalt";sim.oddPickups=0
    sim.oddSkillResult,sim.oddSkillResultTimer="",0
    sim.oddLockTarget,sim.oddLockTimer=nil,0
    sim.oddLockPending,sim.oddLockDuration,sim.oddLockDistance=false,0,0
    sim.oddGrabTarget,sim.oddGrabTimer,sim.oddGrabDuration=nil,0,1.5
    sim.oddGrabHolding,sim.oddGrabResolved=false,false
    sim.oddPreviousAltitude=0
    sim.oddContacts={};sim.oddCoinContacts={};sim.oddLastImpact=sim.impactSerial or 0
end
-- 同一赛道固定地形分段，生成和判定消费同一份s/lane数据。
-- 俯视：   +s --> [障碍 .8..1.4m]       [安全通道 >=3.6m]
--          左/中/右交替，不出现整条路封死；发车前120米无障碍。
-- 玩家和AI均用线段对扩张盒扫掠。上下分离避开低障碍；悬锤仍能打到低空载具。
-- 接触去重+1.2秒保护，重赛清除；擦边留 .08m 安全裕量，不能靠帧末采样穿障。
function M.CreateCourse(map)
    local list={};local length=map.RouteLength or 0
    if length<300 then return list end
    local half=map.Roads and map.Roads[1] and map.Roads[1].width or 8
    for i=1,math.floor((length-180)/72) do
        local s=120+i*72
        -- 飞坡入口和落地走廊不叠随机路障，宽车不会被迫撞侧壁。
        local blocked=false
        for _,ramp in ipairs(map.Ramps or {}) do
            -- 旧路肩坡台只有世界x/z；先投影里程，不能对缺失的s直接做减法。
            local rampS=ramp.s
            if type(rampS)~="number" and map.NearestRoad and ramp.x and ramp.z then
                rampS=map.NearestRoad(ramp.x,ramp.z)
            end
            if type(rampS)=="number" then
                local d=(s-rampS)%length
                local reserved=ramp.landingEndS and ramp.landingEndS-rampS or (ramp.length or 12)+25
                if d<reserved or d>length-30 then blocked=true end
            end
        end
        if not blocked then
        local p,yaw=map.RoadPoint(s)
        local lane=((i%3)-1)*math.min(3.6,half*.48)
        local a=math.rad(yaw)
        local kind=({"crate","barrel","barrel","barrier","pendulum","cone"})[(i-1)%6+1]
        list[#list+1]={id=i,s=s,lane=lane,x=p.x+math.cos(a)*lane,y=p.y,z=p.z-math.sin(a)*lane,
            yaw=yaw,kind=kind,halfWidth=.65,halfLength=.7,
            height=kind=="pendulum" and 4.2 or 1,phase=i*.83,
            breakable=kind~="pendulum",active=true}
        -- 侧视：地面车顶约1.5..2m；低空飞机占据2.5..4.6m。
        -- 单侧悬挂实物挡板覆盖飞行层，另一侧留完整宽车通路，不以空气墙封路。
        if i%6==0 then
            local airLane=lane==0 and half*.4 or lane
            list[#list+1]={id=10000+i,s=s,lane=airLane,x=p.x+math.cos(a)*airLane,
                y=p.y+2.3,z=p.z-math.sin(a)*airLane,yaw=yaw,kind="airbarrier",
                halfWidth=1.3,halfLength=.847163,height=1.684149,phase=0,breakable=false,active=true}
        end
        end
    end
    return list
end
function M.Terrain(map,s,lane)
    -- 未交付可见分区时禁用对应效果，不能留下不可辨识的泥地/冰面减速。
    if map.mixedTerrainVisualsReady==false then return "asphalt" end
    local half=map.Roads and map.Roads[1] and map.Roads[1].width or 8
    -- 中央至少7米柏油通路，特殊地形沿两翼形成可选线路；物理与绘制共用采样。
    if math.abs(lane or 0)<half*.45 then return "asphalt" end
    local theme=map.Track and map.Track.theme or "circuit"
    local section=math.floor((s%math.max(1,map.RouteLength or 1))/145)%8
    if section==0 then return "asphalt" end
    if theme=="canyon" then return section==2 and "wind" or (section==4 and "gravel" or "dry") end
    if theme=="alpine" then return section==3 and "ice" or (section==5 and "gravel" or "asphalt") end
    if section==2 or section==6 then return "gravel" end
    if section==4 then return (theme=="coast" or theme=="lake") and "water" or "mud" end
    if section==5 then return "wind" end
    if section==7 then return "slime" end
    return "asphalt"
end
local ACTIONS={hovercraft=true,centipede=true,loader=true,buggy=true,cicada=true,
    ebike=true,jellyfish=true,jetboat=true,frog=true,skateboard=true,sled=true,cart=true,bathtub=true,office=true,toilet=true}
local function phase(sim,id)
    local age=(sim.oddAge or 0)+1e-8
    if id=="cicada" then
        if sim.oddActive>0 then return "wound_release" end
        return sim.oddSpring>0 and "wound" or "exhausted"
    end
    if id=="buggy" then
        if (sim.oddHop or 0)>0 then return sim.oddHop>(sim.oddHopDuration or 1.6)*.5 and "jump_rise" or "jump_fall" end
        if (sim.oddLandingBoost or 0)>0 then return "landing_boost" end
    end
    if sim.oddActive<=0 then
        return "idle"
    end
    if id=="centipede" then
        return age<.42 and "tail_windup" or age<.72 and "tail_sweep" or "tail_recover"
    elseif id=="loader" then
        return age<.36 and "scoop_windup" or age<.72 and "scoop_lift"
            or age<1.05 and "scoop_release" or "scoop_recover"
    end
    return id=="hovercraft" and "side_jet" or "dash"
end
local function activate(sim,v,controls)
    if sim.oddCooldown>0 or sim.oddDisrupt>0 or sim.oddActive>0 then return false end
    if ACTIONS[v.id] and (sim.finished or sim.wrecked or sim.eliminated or sim.paused
        or controls.brake or controls.burnout or controls.clutch
        or ((v.id=="buggy" or v.id=="frog" or v.id=="skateboard") and sim.airborne)
        or ((v.id=="buggy" or v.id=="skateboard") and (sim.oddHop or 0)>0)) then return false end
    if (v.id=="loader" or v.id=="jellyfish") and not sim.raceMode then
        sim.message,sim.messageTimer="练习中无竞速目标 · 未消耗技能",2
        sim.oddSkillResult,sim.oddSkillResultTimer=sim.message,2
        return false
    end
    sim.oddActive,sim.oddCooldown,sim.oddSkillFlash=v.duration,v.cooldown,.65
    sim.oddAttack=true
    if ACTIONS[v.id] then
        -- A waterball is committed only by launch(), after target validation.
        sim.oddAge=0
        if v.id~="jellyfish" then sim.oddSerial=(sim.oddSerial or 0)+1 end
        sim.oddAttackSerial=sim.oddSerial
        sim.oddAttackResolved=false
        sim.oddHitTime=v.id=="centipede" and .42 or v.id=="loader" and .36 or 0
        sim.oddHitAge=0
        sim.oddPhase=phase(sim,v.id)
    end
    if v.id=="cicada" then
        -- Winding restores at a finite rate during the one-second power penalty.
        -- No instant refill and no resource gains from rendering or holding the key.
        sim.oddWindupSerial,sim.oddWindupStart=sim.oddSerial,sim.oddSpring
    end
    if v.id=="frog" or v.id=="skateboard" or v.id=="buggy" then
        sim.oddHopDuration=v.id=="frog" and 2.4 or v.id=="buggy" and 1.6 or 1.5
        sim.oddHopHeight=v.id=="buggy" and 2.0 or 2.2
        sim.oddHop=sim.oddHopDuration
        sim.oddLandingBoost=0
        if v.id=="buggy" then sim.oddPhase="jump_rise" end
    end
    if v.id=="bathtub" or v.id=="office" then sim.oddShield=v.duration end
    if v.id=="ebike" then sim.oddNitroGift=15 end
    if v.id=="hovercraft" then
        local requested=controls.jetSide or controls.steer or 0
        sim.oddDashSide=math.abs(requested)>.1 and (requested>0 and 1 or -1) or ((sim.lateral or 0)>0 and -1 or 1)
        sim.oddJetSide,sim.oddJetDistance=sim.oddDashSide,0
    elseif v.id=="buggy" then
        sim.oddDashSide=(controls.steer or 0)<0 and -1 or 1
    end
    sim.message,sim.messageTimer=v.skill.." · 已发动",2
    sim.oddSkillResult,sim.oddSkillResultTimer="已发动 · "..v.active,2
    print("[载具技能] "..v.id.." / "..v.skill)
    return true
end
-- 街机主动跳只改变底盘离地偏移，y/里程仍走原动力；玩家与AI同一轨迹。
-- 侧视: bottom=2.0*sin(pi*t/1.6)；1m路障只在中段能越过。
--   0m ____/^^^^2m^^^^\____ 0m  -> 稳定着地2.2s动力，非免撞/非瞬移。
-- 擦顶相切仍碰撞，起跳太晚/落地压障仍吃原XYZ扫掠；护栏/高障碍不屏蔽。
local function buggyLanding(sim,stable)
    sim.oddLandingSerial=(sim.oddLandingSerial or 0)+1
    if stable then
        sim.oddCombo=math.min(3,sim.oddCombo+1);sim.oddComboTimer=6
        sim.oddLandingBoost=2.2
        sim.message,sim.messageTimer="弹射着陆 · 2.2秒有限加速",1.5
    else
        sim.oddLandingBoost=0
        sim.message,sim.messageTimer="落地侧偏 · 未获得着地加速",1.5
    end
end
function M.Before(sim,dt,controls,map)
    local v=Data.Get(sim.vehicleId)
    sim.oddPreviousAltitude=sim.oddAltitude or 0
    sim.oddSkillResultTimer=math.max(0,(sim.oddSkillResultTimer or 0)-dt)
    sim.skillHitLock=math.max(0,(sim.skillHitLock or 0)-dt)
    sim.oddHitLock=math.max(0,(sim.oddHitLock or 0)-dt)
    sim.oddLandingBoost=math.max(0,(sim.oddLandingBoost or 0)-dt)
    if not v then
        Motorcycle.Before(sim,dt,controls)
        sim.oddLaunch=math.max(0,(sim.oddLaunch or 0)-dt)
        local hop=sim.oddHop or 0
        sim.oddHop=math.max(0,hop-dt)
        local jump=hop>0 and math.sin(clamp(sim.oddHop/(sim.oddHopDuration or 1.25),0,1)*math.pi)*(sim.oddHopHeight or 1.35) or 0
        sim.oddAltitude=math.max(jump,sim.oddLaunch>0 and math.sin(sim.oddLaunch/1.2*math.pi)*2.4 or 0)
        sim.oddDisrupt=math.max(0,(sim.oddDisrupt or 0)-dt)
        sim.oddTerrain=(map.RouteLength or 0)>=300 and M.Terrain(map,sim.roadS or 0,sim.lateral or 0) or "asphalt"
        local rough=sim.oddTerrain~="asphalt" and sim.oddTerrain~="wind"
        sim.oddSpeedScale=rough and math.min(1,.88*sim.motorcycleOffroadScale) or 1
        sim.oddDriveScale=1
        sim.oddGripScale=sim.oddDisrupt>0 and .58 or 1
        if sim.oddDisrupt>0 then sim.oddSpeedScale=sim.oddSpeedScale*.84 end
        return
    end
    sim.oddSkillName=v.skill
    local previousActive=sim.oddActive
    if ACTIONS[v.id] and previousActive>0 then
        sim.oddAge=math.min(v.duration,(sim.oddAge or 0)+dt)
        if sim.oddHitTime>0 and not sim.oddAttackResolved then sim.oddHitAge=sim.oddAge end
    end
    sim.oddActive=math.max(0,sim.oddActive-dt);sim.oddCooldown=math.max(0,sim.oddCooldown-dt)
    sim.oddSkillFlash=math.max(0,sim.oddSkillFlash-dt)
    sim.oddDisrupt=math.max(0,sim.oddDisrupt-dt);sim.oddShield=math.max(0,sim.oddShield-dt)
    sim.oddComboTimer=math.max(0,sim.oddComboTimer-dt)
    if sim.oddComboTimer==0 then sim.oddCombo=0 end
    local held=controls.skill==true
    if held and not sim.oddSkillHeld then activate(sim,v,controls) end
    sim.oddSkillHeld=held
    local terrain=M.Terrain(map,sim.roadS or 0,sim.lateral or 0)
    sim.oddTerrain=terrain
    local speed,drive,grip=1.0,1.0,1.0
    local id=v.id
    local float=id=="hovercraft" or id=="jellyfish" or id=="helicopter"
    if terrain=="gravel" then
        if id=="helicopter" then speed=1
        elseif id=="tank" or id=="beetle" or id=="centipede" or id=="loader" or id=="buggy" or float then speed=1.035
        else speed=.87;grip=.88 end
    elseif terrain=="water" or terrain=="mud" or terrain=="slime" then
        if id=="helicopter" then speed=1
        elseif float or id=="bathtub" then speed=id=="jellyfish" and 1.16 or 1.07
        elseif id=="sled" then speed=1.03
        else speed=.82;grip=.8 end
    elseif terrain=="ice" then
        if id=="sled" then speed=1.17;grip=1.15
        elseif not float then grip=.68 end
    elseif terrain=="dry" and id=="jellyfish" then speed=.88
    end
    if id=="beetle" then
        if (sim.impactSerial or 0)~=sim.oddLastImpact then sim.oddSteam=0 end
        sim.oddSteam=clamp(sim.oddSteam+dt*((sim.speed or 0)>12 and .055 or -.08),0,1)
        speed=speed*(1+sim.oddSteam*.18)
    elseif id=="tank" and math.abs(sim.steer or 0)<.15 and (sim.speed or 0)>20 then speed=speed*1.08
    elseif id=="cicada" then
        if sim.oddActive>0 or previousActive>0 then
            local progress=clamp((sim.oddAge or 0)/v.duration,0,1)
            sim.oddSpring=(sim.oddWindupStart or 0)+((sim.oddSpringMax or 22)-(sim.oddWindupStart or 0))*progress
            if sim.oddActive<=0 then sim.oddSpring=math.max(0,sim.oddSpring-math.max(0,dt-previousActive)) end
        else sim.oddSpring=math.max(0,sim.oddSpring-dt) end
        sim.oddWoundRelease=sim.oddActive
        speed=speed*(sim.oddSpring>0 and 1.14 or .82)
        if sim.oddActive>0 then drive=drive*.65 end
    elseif id=="jetboat" then
        local slope=sim.groundSlope or 0
        speed=speed*(slope<-.015 and 1.18 or 1);drive=drive*(slope>.025 and .72 or 1)
        if (sim.speed or 0)<8 then drive=drive*.82 end
    elseif id=="hovercraft" then grip=grip*.92
    elseif id=="buggy" then speed=speed*(1+.035*sim.oddCombo)
    end
    if id=="frog" and sim.oddHop<=0 and (sim.speed or 0)>8 then
        sim.oddHop=.85;sim.oddHopDuration=.85;sim.oddHopHeight=.65
    end
    local wasHopping=sim.oddHop>0
    sim.oddHop=math.max(0,sim.oddHop-dt)
    if wasHopping and sim.oddHop<=0 then
        if id=="buggy" then buggyLanding(sim,math.abs(controls.steer or sim.steer or 0)<=.8 and sim.oddDisrupt<=0 and not sim.airborne)
        elseif id=="frog" or id=="skateboard" then
            if math.abs(controls.steer or 0)>.8 then
                sim.speed=sim.speed*.87;sim.oddDisrupt=.6;sim.message,sim.messageTimer="落地侧偏 · 提前回正方向",1.2
            else
                sim.oddCombo=math.min(3,sim.oddCombo+1);sim.oddComboTimer=5
                sim.speed=math.min(sim.vehicle.maxSpeed*1.12,sim.speed+1.4)
            end
        end
    end
    local altitude=id=="helicopter" and 2.5 or (id=="jellyfish" and 1.65 or (id=="hovercraft" and .2 or 0))
    if sim.oddHop>0 then
        local total=sim.oddHopDuration or .85
        altitude=math.max(altitude,math.sin(clamp(sim.oddHop/total,0,1)*math.pi)*(sim.oddHopHeight or (total>1 and 2.2 or .65)))
    end
    if sim.oddActive>0 then
        if id=="tank" or id=="ebike" or id=="jetboat" or id=="sled" or id=="toilet"
            or id=="cart" or id=="office" then
            drive=drive*1.7;speed=speed*1.18
        elseif id=="bathtub" then drive=drive*1.65;speed=speed*1.16 end
        if id=="toilet" then altitude=math.max(altitude,1.8) end
        if id=="office" then grip=grip*.9 end
    end
    if id=="helicopter" and terrain=="wind" then
        drive=drive*.85;grip=grip*.72
    end
    if sim.oddDisrupt>0 then speed=speed*.84;grip=grip*.58 end
    if sim.oddHop>0 then grip=grip*.78 end
    if id=="frog" or id=="skateboard" then speed=speed*(1+sim.oddCombo*.035) end
    if id=="buggy" and sim.oddLandingBoost>0 and not sim.airborne and sim.oddHop<=0
        and not controls.brake and not controls.burnout and sim.oddDisrupt<=0 then
        drive=drive*1.35;speed=speed*1.06;grip=grip*1.15
    end
    if id=="toilet" and sim.oddActive>0 then grip=grip*.72 end
    if id=="loader" and (sim.crashCooldown or 0)>0 then drive=drive*.75 end
    sim.oddLaunch=math.max(0,(sim.oddLaunch or 0)-dt)
    if sim.oddLaunch>0 then altitude=altitude+math.sin(sim.oddLaunch/1.2*math.pi)*2.4;grip=grip*.5 end
    if sim.oddHitLock>0 then drive=drive*.82 end
    sim.oddJetStep,sim.oddDriftStep=0,0
    if id=="hovercraft" and sim.oddActive>0 then
        sim.oddJetStep=(sim.oddJetSide or 1)*2.3*dt
    end
    sim.oddAltitude=altitude
    if ACTIONS[id] then sim.oddPhase=phase(sim,id) end
    sim.oddSpeedScale,sim.oddDriveScale,sim.oddGripScale=speed,drive,grip
    sim.oddLastImpact=sim.impactSerial or 0
end
local function swept(ax,az,bx,bz,hw,hl)
    local low,high=0,1
    for _,q in ipairs({{ax,bx-ax,hw},{az,bz-az,hl}}) do
        if math.abs(q[2])<1e-8 then if math.abs(q[1])>q[3] then return false end
        else
            local a,b=(-q[3]-q[1])/q[2],(q[3]-q[1])/q[2]
            if a>b then a,b=b,a end
            low,high=math.max(low,a),math.min(high,b)
            if low>high then return false end
        end
    end
    return true,low,high
end
-- 车头沿本车 +Z；正面推挤、侧撞和追尾分别响应，不能用绝对值把尾部当车头。
function M.ContactResponse(id,retained,forward,side)
    local v=Data.Get(id)
    if not v then return 1,0,0 end
    if (id=="tank" or id=="loader") and forward>math.abs(side)*1.2 then
        return .98/retained,0,0
    end
    if v.armor<55 then return .88,1.4,side>0 and -1.1 or 1.1 end
    if id=="tank" and math.abs(side)>math.abs(forward)*.6 then return .82,1.8,0 end
    return 1,0,0
end
function M.Obstacles(sim,world,x0,y0,z0)
    if not world or not world.mixedObstacles then return end
    local v=Data.Get(sim.vehicleId)
    local hw=v and v.size[1]*.5 or .3
    local hl=v and v.size[3]*.5 or .95
    local altitude=sim.oddAltitude or 0
    local bodyHeight=v and v.size[2] or 1.5
    local contacts={}
    local ownRadius=math.sqrt(hw*hw+hl*hl)
    local nearby=require("CourseSpatial").Query(world,"obstacles",x0,z0,sim.x,sim.z,ownRadius)
    for _,o in ipairs(nearby) do
        -- 整段运动包围盒作粗筛，不能仅看帧末12米，否则高速一步越过窄障碍会漏撞。
        local radius=math.sqrt(o.halfWidth*o.halfWidth+o.halfLength*o.halfLength)+ownRadius
        local previousX,previousY,previousZ=o.previousX or o.x,o.previousY or o.y,o.previousZ or o.z
        if o.active and math.min(previousX,o.x)<=math.max(x0,sim.x)+radius
            and math.max(previousX,o.x)>=math.min(x0,sim.x)-radius
            and math.min(previousZ,o.z)<=math.max(z0,sim.z)+radius
            and math.max(previousZ,o.z)>=math.min(z0,sim.z)-radius then
            local a=math.rad(o.yaw);local fx,fz=math.sin(a),math.cos(a)
            local ax,az=x0-previousX,z0-previousZ;local bx,bz=sim.x-o.x,sim.z-o.z
            local delta=math.rad((sim.heading or sim.yaw or 0)-o.yaw)
            local ownW=math.abs(math.cos(delta))*hw+math.abs(math.sin(delta))*hl
            local ownL=math.abs(math.cos(delta))*hl+math.abs(math.sin(delta))*hw
            local hit,enter,leave=swept(ax*fz-az*fx,ax*fx+az*fz,bx*fz-bz*fx,bx*fx+bz*fz,
                o.halfWidth+ownW,o.halfLength+ownL)
            if hit then
                local relativeY0=y0+(sim.oddPreviousAltitude or altitude)+bodyHeight*.5-previousY-o.height*.5
                local currentY=sim.y+altitude+bodyHeight*.5-o.y-o.height*.5
                local vertical,low,high=swept(relativeY0,0,currentY,0,(bodyHeight+o.height)*.5,1)
                hit=vertical and math.max(enter,low)<=math.min(leave,high)
            end
            if hit then
                contacts[o.id]=true
                if not sim.oddContacts[o.id] and (sim.oddHitLock or 0)<=0 then
                    local id=sim.vehicleId
                    local immune=sim.oddShield>0 or Motorcycle.Absorb(sim,"路障")
                        or ((id=="hovercraft" or id=="jellyfish" or id=="helicopter") and o.kind=="oil")
                    if immune then sim.message,sim.messageTimer="防护生效 · 穿越障碍",1
                    elseif o.breakable and (id=="tank" or id=="beetle" or id=="loader") then
                        o.active=false;if o.node then o.node:SetEnabledRecursive(false) end
                        sim.message,sim.messageTimer="破障通过 · "..(v and v.name or id),1.5
                        sim.score=(sim.score or 0)+40
                    else
                        if o.kind=="oil" then sim.speed=sim.speed*.84;sim.oddDisrupt=1.5*(sim.motorcycleDisruptScale or 1)
                        else
                            local obstacleName=o.kind=="pendulum" and "悬锤" or o.kind=="airbarrier" and "空中挡板" or "赛道障碍"
                            sim:Impact("撞上"..obstacleName,7)
                            sim.speed=sim.speed*(id=="tank" and .8 or (1-.28*(sim.motorcycleRetained or 1)))
                            sim.oddSteam=0
                        end
                        sim.oddHitLock=1.2
                    end
                end
            end
        end
    end
    sim.oddContacts=contacts
    local pickupRadius=sim.vehicleId=="cart" and (sim.oddActive>0 and 14 or 3.5) or 1.5
    for _,coin in ipairs(require("CourseSpatial").Query(world,"coins",sim.x,sim.z,sim.x,sim.z,pickupRadius)) do
        local dx,dz=sim.x-coin.x,sim.z-coin.z
        if coin.active and dx*dx+dz*dz<pickupRadius*pickupRadius then
            coin.active=false;if coin.node then coin.node.enabled=false end
            sim.oddPickups=(sim.oddPickups or 0)+5
            sim.message,sim.messageTimer="赛道金币 +5",1
        end
    end
end
function M.After(sim,dt,controls,world,x0,y0,z0,wasAirborne)
    local v=Data.Get(sim.vehicleId)
    if v then
        if v.id=="buggy" and wasAirborne and not sim.airborne then
            buggyLanding(sim,sim.landingStable~=false and (sim.oddHop or 0)<=0)
            sim.oddPhase=phase(sim,v.id)
        end
        local terrain=sim.oddTerrain
        local side=0
        if terrain=="wind" then side=math.sin((sim.elapsed or 0)*1.2)*dt*(v.id=="hovercraft" and 2.7 or v.id=="jellyfish" and 2 or v.id=="helicopter" and 2.4 or .65) end
        if v.id=="hovercraft" and terrain=="asphalt" then side=side+(sim.steer or 0)*dt*.7 end
        if v.id=="hovercraft" then
            local jet=sim.oddJetStep or 0
            side=side+jet
            sim.oddJetLateralSpeed=jet/math.max(dt,1e-6)
            sim.oddJetDistance=(sim.oddJetDistance or 0)+math.abs(jet)
            sim.oddJetStep=0
        elseif v.id=="buggy" then side=side+(sim.oddDriftStep or 0);sim.oddDriftStep=0 end
        local yaw=math.rad(sim.heading or 0)
        sim.x,sim.z=sim.x+math.cos(yaw)*side,sim.z-math.sin(yaw)*side
    end
    M.Obstacles(sim,world,x0,y0,z0)
    if not sim.raceMode and sim.oddAttack and v
        and (v.id=="helicopter" or v.id=="jellyfish" or v.id=="beetle" or v.id=="loader") then
        sim.oddAttack=false;sim.oddActive,sim.oddCooldown,sim.oddSkillFlash=0,0,0
        sim.oddSkillResult,sim.oddSkillResultTimer="练习中无竞速目标 · 未消耗技能",2
        sim.message,sim.messageTimer=sim.oddSkillResult,2
    end
end
-- 近战使用真实车体高度；导弹先锁定再起飞，持续预测拦截同一目标。
-- 扫掠：前一帧目标盒 -> 当前目标盒；导弹每个子步与同一时间段的扩张盒相交。
--   发射点 -- 抬升弧线 -- 持续转弯追踪 --> [目标半宽/半高 + 弹体半径]
-- 护盾可挡，终点/淘汰取消；正常变道不直接判定为“闪避成功”。
local RANGES={tank=300,beetle=5.5,centipede=6,loader=12,jellyfish=28,helicopter=300,office=6}
local function driveFor(race,racer)
    return racer.isPlayer and race.sim or racer.driveSim
end
local function centerY(race,racer)
    local drive=driveFor(race,racer)
    local spec=Data.Get(racer.vehicleId)
    return racer.y+(drive and drive.oddAltitude or 0)+(spec and spec.size[2] or 1.5)*.5
end
local function feedback(sim,text,time)
    if not sim then return end
    sim.oddSkillResult,sim.oddSkillResultTimer=text,time or 2
    sim.message,sim.messageTimer=text,time or 2
end
local function grabMouthWorld(race,source,sim)
    local yaw=math.rad(source.yaw or 0)
    local x=sim.oddGrabLocalX or 0
    local y=sim.oddGrabLocalY or .78
    local z=sim.oddGrabLocalZ or 1.72
    local altitude=sim.oddAltitude or 0
    return source.x+math.cos(yaw)*x+math.sin(yaw)*z,
        source.y+altitude+y,
        source.z-math.sin(yaw)*x+math.cos(yaw)*z
end
local function grabSurfaceGap(race,source,sim,target)
    local mx,my,mz=grabMouthWorld(race,source,sim)
    local spec=Data.Get(target.vehicleId)
    local drive=driveFor(race,target)
    local halfWidth=(spec and spec.size[1] or .6)*.5
    local halfLength=(spec and spec.size[3] or 2)*.5
    local height=spec and spec.size[2] or 1.5
    local yaw=math.rad(target.yaw or 0)
    local dx,dz=mx-target.x,mz-target.z
    local localX=dx*math.cos(yaw)-dz*math.sin(yaw)
    local localZ=dx*math.sin(yaw)+dz*math.cos(yaw)
    local bottom=target.y+(drive and drive.oddAltitude or 0)
    local closestX=clamp(localX,-halfWidth,halfWidth)
    local closestZ=clamp(localZ,-halfLength,halfLength)
    local closestY=clamp(my,bottom,bottom+height)
    local worldX=target.x+math.cos(yaw)*closestX+math.sin(yaw)*closestZ
    local worldZ=target.z-math.sin(yaw)*closestX+math.cos(yaw)*closestZ
    local distance=math.sqrt((mx-worldX)^2+(my-closestY)^2+(mz-worldZ)^2)
    return distance,localX,localZ,my-bottom,halfWidth,halfLength,height
end
local function selectGrabTarget(race,source,sim,range)
    local best,bestDistance=nil,range+.001
    local yaw=math.rad(source.yaw or 0)
    local ownX,ownY,ownZ=grabMouthWorld(race,source,sim)
    for _,target in ipairs(race.racers) do
        if target~=source and not target.finished and not target.eliminated then
            local spec=Data.Get(target.vehicleId)
            local drive=driveFor(race,target)
            local halfWidth=(spec and spec.size[1] or .6)*.5
            local halfLength=(spec and spec.size[3] or 2)*.5
            local dx,dz=target.x-ownX,target.z-ownZ
            local forward=dx*math.sin(yaw)+dz*math.cos(yaw)
            local side=dx*math.cos(yaw)-dz*math.sin(yaw)
            local distance,localX,localZ,localY,_,_,height=grabSurfaceGap(race,source,sim,target)
            -- Mouth must face the target's rear/front surface: side or rear catches
            -- are rejected before the 0.30m surface-distance test.
            local targetBottom=target.y+(drive and drive.oddAltitude or 0)
            local targetCenterForward=localZ
            local vertical=localY>=-.30 and localY<=height+.30
            if forward>=0 and forward<=range+halfLength and math.abs(side)<=halfWidth+.30
                and targetCenterForward>=-halfLength-.30 and vertical and distance<=.30
                and distance<bestDistance then
                best,bestDistance=target,distance
            end
        end
    end
    return best,bestDistance
end
local function selectTarget(race,source,range,ranged)
    local best,bestD=nil,range*range+.001
    local yaw=math.rad(source.yaw or 0)
    local sourceSpec=Data.Get(source.vehicleId)
    local sourceDrive=driveFor(race,source)
    local bottom=source.y+(sourceDrive and sourceDrive.oddAltitude or 0)
    for _,target in ipairs(race.racers) do
        if target~=source and not target.finished and not target.eliminated then
            local dx,dz=target.x-source.x,target.z-source.z
            local forward=dx*math.sin(yaw)+dz*math.cos(yaw)
            local side=math.abs(dx*math.cos(yaw)-dz*math.sin(yaw))
            local d=dx*dx+dz*dz
            local targetDrive=driveFor(race,target)
            local spec=Data.Get(target.vehicleId)
            local targetBottom=target.y+(targetDrive and targetDrive.oddAltitude or 0)
            local vertical=ranged or (targetBottom<bottom+(sourceSpec and sourceSpec.size[2] or 1.5)
                and targetBottom+(spec and spec.size[2] or 1.5)>bottom)
            local direction=forward>0 and side<(ranged and math.max(8,forward*1.75) or 3.1)
            if d<bestD and direction and vertical then best,bestD=target,d end
        end
    end
    return best,math.sqrt(bestD)
end
-- AI only requests a rising edge when an observed tactical opportunity exists.
-- Target identity/rank never changes its cooldown, range or hit test.
function M.ShouldUseSkill(race,source)
    local sim=driveFor(race,source)
    local rescueSkill=Data.GetMotorcycleSkill(source.vehicleId)
    local selfRescue=rescueSkill and rescueSkill.tactic=="stability"
    if not sim or source.finished or source.eliminated or race.phase~="racing"
        or (source.mistakeDuration or 0)>0 or (source.recoveryTimer or 0)>0
        or ((sim.oddDisrupt or 0)>0 and not selfRescue) or (sim.skillHitLock or 0)>0 then return false end
    local v=Data.Get(source.vehicleId)
    local cooldown=v and sim.oddCooldown or sim.motorcycleCooldown
    local active=v and sim.oddActive or sim.motorcycleActive
    if (cooldown or 0)>0 or (active or 0)>0 or sim.oddLockPending or (sim.oddGrabTimer or 0)>0 then return false end
    if v and RANGES[v.id] then
        if v.id=="beetle" then return selectGrabTarget(race,source,sim,.30)~=nil end
        if v.id=="loader" then
            local yaw=math.rad(source.yaw or 0)
            for _,target in ipairs(race.racers) do
                local dx,dz=target.x-source.x,target.z-source.z
                local forward=dx*math.sin(yaw)+dz*math.cos(yaw)
                local side=math.abs(dx*math.cos(yaw)-dz*math.sin(yaw))
                if target~=source and not target.finished and not target.eliminated
                    and forward>0 and forward<=RANGES.loader and side<3.1
                    and math.abs(centerY(race,target)-centerY(race,source))<v.size[2] then return true end
            end
            return false
        end
        if v.id=="centipede" or v.id=="office" then
            for _,target in ipairs(race.racers) do
                if target~=source and not target.finished and not target.eliminated then
                    local dx,dz=target.x-source.x,target.z-source.z
                    local yaw=math.rad(source.yaw or 0)
                    local forward=dx*math.sin(yaw)+dz*math.cos(yaw)
                    if dx*dx+dz*dz<=RANGES[v.id]^2 and (v.id=="office" or forward<=1.2)
                        and math.abs(centerY(race,target)-centerY(race,source))<v.size[2] then return true end
                end
            end
            return false
        end
        local target=selectTarget(race,source,RANGES[v.id],v.id=="tank" or v.id=="helicopter" or v.id=="jellyfish")
        if not target then return false end
        local targetSim=driveFor(race,target)
        return not targetSim or ((targetSim.oddShield or 0)<=0 and (targetSim.skillHitLock or 0)<=0)
    end
    local skill=Data.GetMotorcycleSkill(source.vehicleId)
    local distance=skill and skill.triggerDistance or 40
    local front=false
    local yaw=math.rad(source.yaw or 0)
    for _,target in ipairs(race.racers) do
        if target~=source and not target.finished and not target.eliminated then
            local dx,dz=target.x-source.x,target.z-source.z
            local forward=dx*math.sin(yaw)+dz*math.cos(yaw)
            local side=math.abs(dx*math.cos(yaw)-dz*math.sin(yaw))
            if forward>0 and forward<distance and side<5 then front=true;break end
        end
    end
    local obstacle=false
    local observations=source.perception and source.perception.observations or race.aiObstacles or {}
    for _,o in ipairs(observations) do
        local d=gap(o.s,source.s,race.length)
        if d>0 and d<distance and math.abs(o.lane-source.lane)<(o.halfWidth or 1)+1 then obstacle=true;break end
    end
    local sample=race.aiProfile and race.aiProfile[math.floor((source.s%race.length)/race.aiProfileStep)+1]
    local curve=sample and sample.curvature or 0
    if skill then return Motorcycle.ShouldUse(skill,sim,source.speed,front,obstacle,curve) end
    if v and v.id=="cicada" then return (sim.oddSpring or 0)<5 and not obstacle end
    if v and v.id=="buggy" then
        return source.speed>8 and not sim.airborne and (sim.oddHop or 0)<=0
            and (obstacle or front) and curve<.018
    end
    if v and v.id=="hovercraft" then
        if not obstacle then return false end
        local half=race.roadHalfWidth-v.size[1]*.5-.2
        local side=(source.wantedLane or source.lane)-source.lane
        if math.abs(side)<.1 then side=source.lane>0 and -1 or 1 end
        sim.oddAIJetSide=side>0 and 1 or -1
        return math.abs(source.lane+sim.oddAIJetSide*2.3*v.duration)<=half
    end
    if v and (v.id=="bathtub" or v.id=="frog" or v.id=="skateboard") then return obstacle end
    return v~=nil and source.speed>8 and front and not obstacle and curve<.012
end
local function launch(race,source,sim,target,v)
    local y=centerY(race,source)
    local angle=math.rad(source.yaw or 0)
    local muzzle=v.size[3]*.5+.35
    local x,z=source.x+math.sin(angle)*muzzle,source.z+math.cos(angle)*muzzle
    local dx,dy,dz=target.x-x,centerY(race,target)-y,target.z-z
    local length=math.max(.01,math.sqrt(dx*dx+dy*dy+dz*dz))
    local homing=v.id=="helicopter" or v.id=="tank"
    local speed=homing and math.max(100,(source.speed or 0)+65) or 65
    -- 水球仍是近程直射；导弹携带独立目标、寿命与续航，不以旧0.8秒限制射程。
    local projectiles=race.mixedProjectiles or {};race.mixedProjectiles=projectiles
    projectiles[#projectiles+1]={kind=v.id,x=x,y=y,z=z,vx=dx/length*speed,
        vy=homing and v.id=="helicopter" and speed*.25 or dy/length*speed,vz=dz/length*speed,
        ttl=homing and 8 or .8,age=0,speed=speed,homing=homing,distance=0,
        source=source,target=target}
    if v.id=="jellyfish" then
        sim.oddSerial=(sim.oddSerial or 0)+1
        sim.oddAttackSerial=sim.oddSerial
        sim.oddAge,sim.oddPhase=0,"bubble_cast"
    end
    sim.oddLockTimer=0
    sim.oddLockPending=false
    feedback(sim,homing and "锁定完成 · 导弹已发射，持续追踪" or "水球已发射 · 直线弹道",2.5)
    print(string.format("[载具武器] %s 锁定%s 距离%.0fm 追踪=%s",source.id,target.id,length,tostring(homing)))
    race:Emit("weapon-fire",source.id,target.id)
end
function M.Attack(race,source,sim)
    if not sim.oddAttack then return end
    local v=Data.Get(source.vehicleId);if not v then sim.oddAttack=false;return end
    local range=RANGES[v.id];if not range then sim.oddAttack=false;return end
    if v.id=="centipede" or v.id=="loader" then
        -- Keyframe contract: rear disc r=6m, front cut z<=1.2m for the tail;
        -- loader front cone reaches 12m with |side|<3.1m. Height must overlap.
        -- Both sample current geometry at the keyframe, never the activation pose.
        if source.finished or source.eliminated or sim.oddDisrupt>0 then
            sim.oddAttack=false;sim.oddAttackResolved=true;return
        end
        if sim.oddAttackResolved or (sim.oddAge or 0)+1e-8<(sim.oddHitTime or 0) then return end
        if sim.oddActive<=0 then sim.oddAttack=false;sim.oddAttackResolved=true;return end
        sim.oddAttackResolved=true
        sim.oddAttack=false
        sim.oddHitAge=sim.oddAge
    end
    if v.id=="loader" then
        local yaw=math.rad(source.yaw or 0)
        local best,bestForward=nil,range+1
        for _,target in ipairs(race.racers) do
            local dx,dz=target.x-source.x,target.z-source.z
            local forward=dx*math.sin(yaw)+dz*math.cos(yaw)
            local side=math.abs(dx*math.cos(yaw)-dz*math.sin(yaw))
            if target~=source and not target.finished and not target.eliminated
                and forward>0 and forward<=range and side<3.1
                and math.abs(centerY(race,target)-centerY(race,source))<v.size[2]
                and forward<bestForward then best,bestForward=target,forward end
        end
        if best then M.Hit(race,source,best,v,true)
        else feedback(sim,"铲斗挑空 · 12米内无有效目标") end
        return
    end
    sim.oddAttack=false
    if v.id=="centipede" or v.id=="office" then
        local yaw=math.rad(source.yaw or 0)
        for _,target in ipairs(race.racers) do
            local dx,dz=target.x-source.x,target.z-source.z
            local forward=dx*math.sin(yaw)+dz*math.cos(yaw)
            if target~=source and not target.finished and not target.eliminated
                and dx*dx+dz*dz<=range*range and (v.id=="office" or forward<=1.2)
                and math.abs(centerY(race,target)-centerY(race,source))<v.size[2] then
                M.Hit(race,source,target,v,true)
            end
        end
        return
    end
    local ranged=v.id=="tank" or v.id=="helicopter" or v.id=="jellyfish"
    local best,distance=selectTarget(race,source,range,ranged)
    if v.id=="beetle" then
        -- 无目标也完整空挥；命中推迟到闭钳关键帧，必须通过真实钳口表面判定。
        local grabTarget=selectGrabTarget(race,source,sim,.30)
        sim.oddGrabTarget,sim.oddGrabTimer,sim.oddGrabDuration=grabTarget,1.5,1.5
        sim.oddGrabHolding,sim.oddGrabResolved=false,false
        feedback(sim,grabTarget and "双钳张开 · 前伸夹击" or "双钳空挥 · 靠近钳口0.3米再夹击",1.5)
        return
    end
    if not best then
        sim.oddActive,sim.oddCooldown,sim.oddSkillFlash=0,0,0
        sim.oddLockTarget,sim.oddLockTimer,sim.oddLockPending=nil,0,false
        feedback(sim,"前方无有效目标 · 未消耗技能")
        return
    end
    if ranged then
        if v.id=="tank" or v.id=="helicopter" then
            sim.oddLockTarget,sim.oddLockTimer,sim.oddLockPending=best,.55,true
            sim.oddLockDuration,sim.oddLockDistance=.55,distance
            feedback(sim,string.format("正在锁定 %s · %.0f米",best.name or "对手",distance),.7)
            race:Emit("weapon-lock",source.id,best.id)
        else launch(race,source,sim,best,v) end
        return
    end
    M.Hit(race,source,best,v)
end
function M.Hit(race,source,best,v,areaAttack)
    local targetSim=driveFor(race,best)
    local sourceSim=driveFor(race,source)
    if (not areaAttack and sourceSim and (sourceSim.skillHitLock or 0)>0)
        or (targetSim and (targetSim.skillHitLock or 0)>0) then
        feedback(sourceSim,"技能命中保护中")
        return false
    end
    if targetSim and ((targetSim.oddShield or 0)>0 or Motorcycle.Absorb(targetSim,"对手技能")) then
        feedback(sourceSim,"攻击被护盾挡住")
        return false
    end
    feedback(sourceSim,"技能命中 · 对手减速20%，失衡3秒",2.5)
    if sourceSim and (v.id=="centipede" or v.id=="loader") then
        sourceSim.oddHitSerial=(sourceSim.oddHitSerial or 0)+1
    end
    best.speed=best.speed*.8;best.hitTimer,best.hitShake=1,.65
    best.boostTimer=0
    if sourceSim then sourceSim.skillHitLock=.18 end
    if targetSim then targetSim.skillHitLock=1.0 end
    local explosive=v.id=="tank" or v.id=="helicopter" or v.id=="jellyfish"
    if explosive then
        race.mixedExplosions=race.mixedExplosions or {}
        race.mixedExplosions[#race.mixedExplosions+1]={x=best.x,y=centerY(race,best),z=best.z,age=0,
            scale=v.id=="jellyfish" and 1 or 1.35}
    end
    if race.options and race.options.mixed and v.id~="beetle" then
        best.tumble=(v.id=="tank" or v.id=="centipede") and 1.1 or .55
    end
    local side=best.lane>=source.lane and 1 or -1
    local spec=Data.Get(best.vehicleId)
    local margin=(spec and spec.size[1]*.5 or .3)+.15
    best.wantedLane=clamp(best.lane+side*1.4,-race.roadHalfWidth+margin,race.roadHalfWidth-margin)
    local disruptDuration=3*(targetSim and targetSim.motorcycleDisruptScale or 1)
    best.oddDisrupt=disruptDuration
    if targetSim then
        targetSim.speed=best.speed;targetSim.oddDisrupt=disruptDuration
        if v.id=="loader" then targetSim.oddLaunch=1.2 end
    end
    if best.isPlayer then
        race.sim.heading=(race.sim.heading+side*5)%360
        race.sim.message,race.sim.messageTimer=v.name.."技能命中 · 注意修正方向",2
    end
    race:Collision(best);race:Emit("vehicle-skill",source.id,best.id)
    if explosive then race:Emit("weapon-hit",source.id,best.id) end
    return true
end
local function updateLock(race,source,sim,dt)
    if not sim then return end
    local id=source.vehicleId
    if id~="tank" and id~="helicopter" then return end
    if source.finished or source.eliminated then
        sim.oddLockTarget,sim.oddLockTimer,sim.oddLockPending=nil,0,false;return
    end
    if sim.oddLockPending then
        local target=sim.oddLockTarget
        local distance=target and math.sqrt((target.x-source.x)^2+(target.z-source.z)^2) or math.huge
        if not target or target.finished or target.eliminated or distance>RANGES[id]+25 then
            sim.oddLockTarget,sim.oddLockTimer,sim.oddLockPending=nil,0,false
            sim.oddCooldown,sim.oddActive=0,0
            feedback(sim,"锁定中断 · 目标离开射程，未消耗技能");return
        end
        sim.oddLockDistance=distance
        sim.oddLockTimer=math.max(0,sim.oddLockTimer-dt)
        if sim.oddLockTimer<=0 then launch(race,source,sim,target,Data.Get(id)) end
    elseif (sim.oddCooldown or 0)<=0 then
        local target,distance=selectTarget(race,source,RANGES[id],true)
        sim.oddLockTarget,sim.oddLockDistance=target,distance
    else
        local tracking=false
        for _,shot in ipairs(race.mixedProjectiles or {}) do if shot.source==source then tracking=true;break end end
        if not tracking then sim.oddLockTarget=nil end
    end
end
local function updateGrab(race,source,sim,dt)
    if not sim or (sim.oddGrabTimer or 0)<=0 then return end
    local duration=sim.oddGrabDuration or 1.5
    sim.oddGrabTimer=math.max(0,sim.oddGrabTimer-dt)
    local elapsed=duration-sim.oddGrabTimer
    local target=sim.oddGrabTarget
    if source.finished or source.eliminated or not target or target.finished or target.eliminated then
        sim.oddGrabHolding=false;return
    end
    if elapsed>=.48 and not sim.oddGrabResolved then
        local distance,_,_,localY,halfWidth,_,height=grabSurfaceGap(race,source,sim,target)
        local yaw=math.rad(source.yaw or 0)
        local dx,dz=target.x-source.x,target.z-source.z
        local forward=dx*math.sin(yaw)+dz*math.cos(yaw)
        local side=dx*math.cos(yaw)-dz*math.sin(yaw)
        sim.oddGrabResolved=true
        if distance<=.30 and forward>0 and math.abs(side)<=halfWidth+.30 and localY>=-.30 and localY<=height+.30 then
            sim.oddGrabHolding=M.Hit(race,source,target,Data.Get("beetle"))
            if sim.oddGrabHolding then feedback(sim,"双钳夹住对手 · 松钳后抛开",1.5) end
        else feedback(sim,"夹击落空 · 钳口未贴近目标",1.5) end
    end
    if sim.oddGrabHolding and elapsed<1.08 then
        -- 两车同向夹持：按真实钳口+目标半长留距，以有限速度拉近，不瞬移14米目标。
        local yaw=math.rad(source.yaw or 0)
        local spec=Data.Get(target.vehicleId)
        local offset=1.9+(spec and spec.size[3] or 2)*.35
        local tx,tz=source.x+math.sin(yaw)*offset,source.z+math.cos(yaw)*offset
        local blend=math.min(1,dt*10)
        target.x,target.z=target.x+(tx-target.x)*blend,target.z+(tz-target.z)*blend
        target.speed=source.speed*.9
        local targetSim=driveFor(race,target)
        if targetSim then
            targetSim.x,targetSim.z,targetSim.speed=target.x,target.z,target.speed
            targetSim.oddDisrupt=math.max(targetSim.oddDisrupt or 0,.6)
        end
    elseif sim.oddGrabHolding then
        sim.oddGrabHolding=false
        local targetSim=driveFor(race,target)
        if targetSim then targetSim.oddLaunch=.65 end
        target.tumble=.55
    end
end
local function advanceShot(race,p,dt)
    local target=p.target
    if not target or target.finished or target.eliminated or p.source.eliminated then return false,true end
    local targetSim=driveFor(race,target)
    local spec=Data.Get(target.vehicleId)
    local radius=p.homing and .8 or .325
    local hw=(spec and spec.size[1] or .6)*.5+radius
    local hl=(spec and spec.size[3] or 2)*.5+radius
    local hh=(spec and spec.size[2] or 1.5)*.5
    local lift=(targetSim and targetSim.oddAltitude or 0)+hh
    local angle=math.rad(target.yaw or 0);local sx,sz=math.sin(angle),math.cos(angle)
    local prevX,prevY,prevZ=target.contactX or target.x,target.contactY or target.y,target.contactZ or target.z
    -- 120Hz弹道子步只做数值运算，防低帧率穿透与高转速轨迹折返。
    local steps=math.max(1,math.ceil(dt*120));local step=dt/steps
    for n=1,steps do
        local a,b=(n-1)/steps,n/steps
        local tx0,ty0,tz0=prevX+(target.x-prevX)*a,prevY+(target.y-prevY)*a+lift,prevZ+(target.z-prevZ)*a
        local tx,ty,tz=prevX+(target.x-prevX)*b,prevY+(target.y-prevY)*b+lift,prevZ+(target.z-prevZ)*b
        local x0,y0,z0=p.x,p.y,p.z
        p.age=(p.age or 0)+step
        if p.homing then
            local dx,dy,dz=tx-p.x,ty-p.y,tz-p.z
            local distance=math.sqrt(dx*dx+dy*dy+dz*dz)
            local targetSpeed=target.speed or 0
            p.speed=math.min(math.max(155,targetSpeed+105),(p.speed or 100)+step*160)
            local lead=math.min(.65,distance/math.max(1,p.speed))*math.min(1,distance/18)
            local heading=math.rad(target.yaw or 0)
            dx,dz=dx+math.sin(heading)*targetSpeed*lead,dz+math.cos(heading)*targetSpeed*lead
            -- 首0.25秒抬升离架，然后平滑切入预测点，尾迹体现追踪弧线。
            if p.kind=="helicopter" then dy=dy+math.max(0,1-p.age/.4)*5 end
            local len=math.max(.001,math.sqrt(dx*dx+dy*dy+dz*dz))
            local oldLen=math.max(.001,math.sqrt(p.vx*p.vx+p.vy*p.vy+p.vz*p.vz))
            local ux,uy,uz=p.vx/oldLen,p.vy/oldLen,p.vz/oldLen
            local nx,ny,nz=dx/len,dy/len,dz/len
            local dot=clamp(ux*nx+uy*ny+uz*nz,-1,1)
            local turn=math.acos(dot)
            local blend=turn<.0001 and 1 or math.min(1,math.rad(300)*step/turn)
            local vx,vy,vz=ux+(nx-ux)*blend,uy+(ny-uy)*blend,uz+(nz-uz)*blend
            local norm=math.max(.001,math.sqrt(vx*vx+vy*vy+vz*vz))
            p.vx,p.vy,p.vz=vx/norm*p.speed,vy/norm*p.speed,vz/norm*p.speed
        end
        p.x,p.y,p.z=p.x+p.vx*step,p.y+p.vy*step,p.z+p.vz*step
        p.distance=(p.distance or 0)+math.sqrt(p.vx*p.vx+p.vy*p.vy+p.vz*p.vz)*step
        local ax,az=x0-tx0,z0-tz0;local bx,bz=p.x-tx,p.z-tz
        local hit,enter,leave=swept(ax*sz-az*sx,ax*sx+az*sz,bx*sz-bz*sx,bx*sx+bz*sz,hw,hl)
        if hit then
            local vertical,low,high=swept(y0-ty0,0,p.y-ty,0,hh+radius,1)
            if vertical and math.max(enter,low)<=math.min(leave,high) then return true,false end
        end
    end
    p.ttl=p.ttl-dt
    return false,p.ttl<=0 or p.distance>1500
end
function M.RaceStep(race,dt)
    if race.phase~="racing" then return end
    local shots=race.mixedProjectiles or {}
    for i=#shots,1,-1 do
        local p=shots[i]
        local hit,expired=advanceShot(race,p,dt)
        if hit then M.Hit(race,p.source,p.target,Data.Get(p.kind)) end
        if expired and not hit then feedback(driveFor(race,p.source),"追踪结束 · 目标离场或超出续航") end
        if hit or expired then
            if p.node then p.node:Dispose();p.node=nil end
            table.remove(shots,i)
        end
    end
    if race.sim.oddNitroGift then
        race.player.nitro=math.min(100,race.player.nitro+race.sim.oddNitroGift);race.sim.oddNitroGift=nil
    end
    for _,r in ipairs(race.racers) do
        local sim=driveFor(race,r)
        if sim then
            updateLock(race,r,sim,dt)
            updateGrab(race,r,sim,dt)
            if not r.finished and not r.eliminated then M.Attack(race,r,sim) end
        end
    end
end
function M.ResetCourse(world)
    for _,o in ipairs(world.mixedObstacles or {}) do o.active=true;if o.node then o.node:SetEnabledRecursive(true) end end
    for _,o in ipairs(world.mixedCoins or {}) do o.active=true;if o.node then o.node.enabled=true end end
end
return M
