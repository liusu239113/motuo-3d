-- 街机混合竞速：能力改变真实动力/碰撞，不以模型动画代替效果。
local Data=require("MixedVehicles")
local M={}
local function clamp(x,a,b) return math.max(a,math.min(b,x)) end
local function gap(a,b,length) return (a-b+length*.5)%length-length*.5 end
function M.Reset(sim)
    sim.oddActive,sim.oddCooldown,sim.oddAltitude,sim.oddSkillFlash=0,0,0,0
    sim.oddLaunch,sim.oddHopDuration=0,.85
    sim.oddSteam,sim.oddSpring,sim.oddCombo,sim.oddComboTimer=0,22,0,0
    sim.oddHop,sim.oddHitLock,sim.oddDisrupt,sim.oddShield=0,0,0,0
    sim.oddSkillHeld,sim.oddAttack=false,false
    sim.oddSpeedScale,sim.oddDriveScale,sim.oddGripScale=1,1,1
    sim.oddSkillName="";sim.oddTerrain="asphalt";sim.oddPickups=0
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
        local p,yaw=map.RoadPoint(s)
        local lane=((i%3)-1)*math.min(3.6,half*.48)
        local a=math.rad(yaw)
        local kind=({"crate","oil","barrel","barrier","pendulum","cone"})[(i-1)%6+1]
        list[#list+1]={id=i,s=s,lane=lane,x=p.x+math.cos(a)*lane,y=p.y,z=p.z-math.sin(a)*lane,
            yaw=yaw,kind=kind,halfWidth=kind=="oil" and 1.3 or .65,halfLength=kind=="oil" and 2 or .7,
            height=kind=="pendulum" and 4.2 or (kind=="oil" and .12 or 1),phase=i*.83,
            breakable=kind~="pendulum" and kind~="oil",active=true}
    end
    return list
end
function M.Terrain(map,s,lane)
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
local function activate(sim,v,controls)
    if sim.oddCooldown>0 or sim.oddDisrupt>0 then return false end
    sim.oddActive,sim.oddCooldown,sim.oddSkillFlash=v.duration,v.cooldown,.65
    sim.oddAttack=true
    if v.id=="cicada" then sim.oddSpring=22 end
    if v.id=="frog" or v.id=="skateboard" then
        sim.oddHopDuration=v.id=="frog" and 2.4 or 1.5;sim.oddHop=sim.oddHopDuration
    end
    if v.id=="bathtub" or v.id=="office" then sim.oddShield=v.duration end
    if v.id=="ebike" then sim.oddNitroGift=15 end
    if v.id=="hovercraft" then
        local steer=controls.steer or 0
        sim.oddDashSide=math.abs(steer)>.1 and (steer>0 and 1 or -1) or ((sim.lateral or 0)>0 and -1 or 1)
    end
    sim.message,sim.messageTimer=v.skill.." · 已发动",2
    print("[载具技能] "..v.id.." / "..v.skill)
    return true
end
function M.Before(sim,dt,controls,map)
    local v=Data.Get(sim.vehicleId)
    sim.oddHitLock=math.max(0,(sim.oddHitLock or 0)-dt)
    if not v then
        if (map.RouteLength or 0)<300 then
            sim.oddSpeedScale,sim.oddDriveScale,sim.oddGripScale=1,1,1;return
        end
        sim.oddLaunch=math.max(0,(sim.oddLaunch or 0)-dt)
        sim.oddAltitude=sim.oddLaunch>0 and math.sin(sim.oddLaunch/1.2*math.pi)*2.4 or 0
        sim.oddDisrupt=math.max(0,(sim.oddDisrupt or 0)-dt)
        sim.oddTerrain=M.Terrain(map,sim.roadS or 0,sim.lateral or 0)
        sim.oddSpeedScale=sim.oddTerrain=="asphalt" and 1 or .88
        sim.oddDriveScale=1
        sim.oddGripScale=sim.oddDisrupt>0 and .58 or 1
        if sim.oddDisrupt>0 then sim.oddSpeedScale=sim.oddSpeedScale*.84 end
        return
    end
    sim.oddSkillName=v.skill
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
        if id=="tank" or id=="beetle" or id=="centipede" or id=="loader" or id=="buggy" or float then speed=1.035
        else speed=.87;grip=.88 end
    elseif terrain=="water" or terrain=="mud" or terrain=="slime" then
        if float or id=="bathtub" then speed=id=="jellyfish" and 1.16 or 1.07
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
        sim.oddSpring=math.max(0,sim.oddSpring-dt)
        speed=speed*(sim.oddSpring>0 and 1.14 or .82)
        if sim.oddActive>0 then drive=drive*.65 end
    elseif id=="jetboat" then
        local slope=sim.groundSlope or 0
        speed=speed*(slope<-.015 and 1.18 or 1);drive=drive*(slope>.025 and .72 or 1)
        if (sim.speed or 0)<8 then drive=drive*.82 end
    elseif id=="hovercraft" then grip=grip*.92
    elseif id=="buggy" then speed=speed*(1+.055*sim.oddCombo)
    end
    if id=="frog" and sim.oddHop<=0 and (sim.speed or 0)>8 then sim.oddHop=.85;sim.oddHopDuration=.85 end
    local wasHopping=sim.oddHop>0
    sim.oddHop=math.max(0,sim.oddHop-dt)
    if wasHopping and sim.oddHop<=0 then
        if id=="frog" or id=="skateboard" then
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
        altitude=math.max(altitude,math.sin(clamp(sim.oddHop/total,0,1)*math.pi)*(total>1 and 2.2 or .65))
    end
    if sim.oddActive>0 then
        if id=="tank" or id=="ebike" or id=="jetboat" or id=="sled" or id=="toilet" then
            drive=drive*1.7;speed=speed*1.18
        elseif id=="buggy" then drive=drive*1.4;grip=grip*1.4
        elseif id=="cart" then drive=drive*1.35;speed=speed*1.1 end
        if id=="toilet" then altitude=math.max(altitude,1.8) end
    end
    if sim.oddDisrupt>0 then speed=speed*.84;grip=grip*.58 end
    if sim.oddHop>0 then grip=grip*.78 end
    if id=="frog" then speed=speed*(1+sim.oddCombo*.035) end
    if id=="toilet" and sim.oddActive>0 then grip=grip*.72 end
    if id=="loader" and (sim.crashCooldown or 0)>0 then drive=drive*.75 end
    sim.oddLaunch=math.max(0,(sim.oddLaunch or 0)-dt)
    if sim.oddLaunch>0 then altitude=altitude+math.sin(sim.oddLaunch/1.2*math.pi)*2.4;grip=grip*.5 end
    sim.oddAltitude=altitude
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
    return true
end
function M.Obstacles(sim,world,x0,y0,z0)
    if not world or not world.mixedObstacles then return end
    local v=Data.Get(sim.vehicleId)
    local hw=v and v.size[1]*.5 or .3
    local hl=v and v.size[3]*.5 or .95
    local altitude=sim.oddAltitude or 0
    local contacts={}
    for _,o in ipairs(world.mixedObstacles) do
        if o.active and math.abs(o.x-sim.x)<12 and math.abs(o.z-sim.z)<12 then
            local a=math.rad(o.yaw);local fx,fz=math.sin(a),math.cos(a)
            local ax,az=x0-o.x,z0-o.z;local bx,bz=sim.x-o.x,sim.z-o.z
            local hit=swept(ax*fz-az*fx,ax*fx+az*fz,bx*fz-bz*fx,bx*fx+bz*fz,o.halfWidth+hw,o.halfLength+hl)
            local height=sim.y+altitude-o.y
            if hit and height<o.height and height>-1.5 then
                contacts[o.id]=true
                if not sim.oddContacts[o.id] and (sim.oddHitLock or 0)<=0 then
                    local id=sim.vehicleId
                    local immune=sim.oddShield>0 or ((id=="hovercraft" or id=="jellyfish" or id=="helicopter") and o.kind=="oil")
                    if immune then sim.message,sim.messageTimer="防护生效 · 穿越障碍",1
                    elseif o.breakable and (id=="tank" or id=="beetle" or id=="loader") then
                        o.active=false;if o.node then o.node:SetEnabledRecursive(false) end
                        sim.message,sim.messageTimer="破障通过 · "..(v and v.name or id),1.5
                        sim.score=(sim.score or 0)+40
                    else
                        if o.kind=="oil" then sim.speed=sim.speed*.84;sim.oddDisrupt=1.5
                        else
                            sim:Impact("撞上"..(o.kind=="pendulum" and "悬锤" or "赛道障碍"),7)
                            sim.speed=sim.speed*(id=="tank" and .8 or .72)
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
    for _,coin in ipairs(world.mixedCoins or {}) do
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
            sim.oddCombo=math.min(3,sim.oddCombo+1);sim.oddComboTimer=8
            sim.speed=math.min(sim.vehicle.maxSpeed*1.2,sim.speed+2)
        end
        local terrain=sim.oddTerrain
        local side=0
        if terrain=="wind" then side=math.sin((sim.elapsed or 0)*1.2)*dt*(v.id=="hovercraft" and 2.7 or v.id=="jellyfish" and 2 or .65) end
        if v.id=="hovercraft" and terrain=="asphalt" then side=side+(sim.steer or 0)*dt*.7 end
        if v.id=="hovercraft" and sim.oddActive>0 then side=side+(sim.oddDashSide or 1)*dt*2.3 end
        local yaw=math.rad(sim.heading or 0)
        sim.x,sim.z=sim.x+math.cos(yaw)*side,sim.z-math.sin(yaw)*side
    end
    M.Obstacles(sim,world,x0,y0,z0)
end
function M.Attack(race,source,sim)
    if not sim.oddAttack then return end
    sim.oddAttack=false
    local v=Data.Get(source.vehicleId);if not v then return end
    local range=({tank=10,beetle=14,centipede=7,loader=12,jellyfish=28,helicopter=32,office=6})[v.id]
    if not range then return end
    local best,bestD=nil,range*range
    for _,target in ipairs(race.racers) do
        if target~=source and not target.finished and not target.eliminated then
            local dx,dz=target.x-source.x,target.z-source.z
            local yaw=math.rad(source.yaw or 0)
            local forward=dx*math.sin(yaw)+dz*math.cos(yaw)
            local side=math.abs(dx*math.cos(yaw)-dz*math.sin(yaw))
            local area=v.id=="centipede" or v.id=="office"
            local d=dx*dx+dz*dz
            if d<bestD and (area or (forward>0 and side<3.1)) then best,bestD=target,d end
        end
    end
    if not best then return end
    local targetSim=best.isPlayer and race.sim or best.driveSim
    if targetSim and (targetSim.oddShield or 0)>0 then return end
    best.speed=best.speed*.8;best.hitTimer,best.hitShake=1,.65
    local side=best.lane>=source.lane and 1 or -1
    best.wantedLane=clamp(best.lane+side*1.4,-race.roadHalfWidth+.8,race.roadHalfWidth-.8)
    best.oddDisrupt=3
    if targetSim then
        targetSim.oddDisrupt=3
        if v.id=="loader" or v.id=="beetle" then targetSim.oddLaunch=1.2 end
    end
    if best.isPlayer then
        race.sim.speed=best.speed
        race.sim.heading=(race.sim.heading+side*5)%360
        race.sim.message,race.sim.messageTimer=v.name.."技能命中 · 注意修正方向",2
    end
    race:Collision(best);race:Emit("vehicle-skill",source.id,best.id)
end
function M.RaceStep(race,dt)
    if race.phase~="racing" then return end
    if race.sim.oddNitroGift then
        race.player.nitro=math.min(100,race.player.nitro+race.sim.oddNitroGift);race.sim.oddNitroGift=nil
    end
    M.Attack(race,race.player,race.sim)
    for _,r in ipairs(race.racers) do
        if not r.isPlayer and r.driveSim then M.Attack(race,r,r.driveSim) end
    end
end
function M.ResetCourse(world)
    for _,o in ipairs(world.mixedObstacles or {}) do o.active=true;if o.node then o.node:SetEnabledRecursive(true) end end
    for _,o in ipairs(world.mixedCoins or {}) do o.active=true;if o.node then o.node.enabled=true end end
end
return M
