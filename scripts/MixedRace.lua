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
    sim.oddSkillResult,sim.oddSkillResultTimer="",0
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
    sim.oddSkillResult,sim.oddSkillResultTimer="已发动 · "..v.active,2
    print("[载具技能] "..v.id.." / "..v.skill)
    return true
end
function M.Before(sim,dt,controls,map)
    local v=Data.Get(sim.vehicleId)
    sim.oddPreviousAltitude=sim.oddAltitude or 0
    sim.oddSkillResultTimer=math.max(0,(sim.oddSkillResultTimer or 0)-dt)
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
    if id=="helicopter" and terrain=="wind" then
        drive=drive*.85;grip=grip*.72
    end
    if sim.oddDisrupt>0 then speed=speed*.84;grip=grip*.58 end
    if sim.oddHop>0 then grip=grip*.78 end
    if id=="frog" then speed=speed*(1+sim.oddCombo*.035) end
    if id=="toilet" and sim.oddActive>0 then grip=grip*.72 end
    if id=="loader" and (sim.crashCooldown or 0)>0 then drive=drive*.75 end
    sim.oddLaunch=math.max(0,(sim.oddLaunch or 0)-dt)
    if sim.oddLaunch>0 then altitude=altitude+math.sin(sim.oddLaunch/1.2*math.pi)*2.4;grip=grip*.5 end
    if sim.oddHitLock>0 then drive=drive*.82 end
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
                    local immune=sim.oddShield>0 or ((id=="hovercraft" or id=="jellyfish" or id=="helicopter") and o.kind=="oil")
                    if immune then sim.message,sim.messageTimer="防护生效 · 穿越障碍",1
                    elseif o.breakable and (id=="tank" or id=="beetle" or id=="loader") then
                        o.active=false;if o.node then o.node:SetEnabledRecursive(false) end
                        sim.message,sim.messageTimer="破障通过 · "..(v and v.name or id),1.5
                        sim.score=(sim.score or 0)+40
                    else
                        if o.kind=="oil" then sim.speed=sim.speed*.84;sim.oddDisrupt=1.5
                        else
                            local obstacleName=o.kind=="pendulum" and "悬锤" or o.kind=="airbarrier" and "空中挡板" or "赛道障碍"
                            sim:Impact("撞上"..obstacleName,7)
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
            sim.oddCombo=math.min(3,sim.oddCombo+1);sim.oddComboTimer=8
            sim.speed=math.min(sim.vehicle.maxSpeed*1.2,sim.speed+2)
        end
        local terrain=sim.oddTerrain
        local side=0
        if terrain=="wind" then side=math.sin((sim.elapsed or 0)*1.2)*dt*(v.id=="hovercraft" and 2.7 or v.id=="jellyfish" and 2 or v.id=="helicopter" and 2.4 or .65) end
        if v.id=="hovercraft" and terrain=="asphalt" then side=side+(sim.steer or 0)*dt*.7 end
        if v.id=="hovercraft" and sim.oddActive>0 then side=side+(sim.oddDashSide or 1)*dt*2.3 end
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
-- 近战按真实车体高度相交；铁尾覆盖后方及两侧，转椅覆盖周围，同一次释放可命中多个对手。
-- 空战弹体沿发射瞬间确定的三维方向直飞，不追踪；扫掠判定与画面使用同一坐标。
function M.Attack(race,source,sim)
    if not sim.oddAttack then return end
    sim.oddAttack=false
    local v=Data.Get(source.vehicleId);if not v then return end
    local range=({tank=10,beetle=14,centipede=6,loader=12,jellyfish=28,helicopter=32,office=6})[v.id]
    if not range then return end
    local area=v.id=="centipede" or v.id=="office"
    local ranged=v.id=="jellyfish" or v.id=="helicopter"
    ---@type RaceRacer?
    local best=nil
    local bestD=range*range
    local sourceBottom=source.y+(sim.oddAltitude or 0)
    for _,target in ipairs(race.racers) do
        if target~=source and not target.finished and not target.eliminated then
            local dx,dz=target.x-source.x,target.z-source.z
            local yaw=math.rad(source.yaw or 0)
            local forward=dx*math.sin(yaw)+dz*math.cos(yaw)
            local side=math.abs(dx*math.cos(yaw)-dz*math.sin(yaw))
            local d=dx*dx+dz*dz
            local targetSim=target.isPlayer and race.sim or target.driveSim
            local spec=Data.Get(target.vehicleId)
            local bottom=target.y+(targetSim and targetSim.oddAltitude or 0)
            local height=spec and spec.size[2] or 1.5
            local vertical=ranged or (bottom<sourceBottom+v.size[2] and bottom+height>sourceBottom)
            local direction=area and (v.id=="office" or forward<=1.2) or (not area and forward>0 and side<3.1)
            if d<=range*range and vertical and direction then
                if area then M.Hit(race,source,target,v)
                elseif d<bestD then best,bestD=target,d end
            end
        end
    end
    if area then return end
    if not best then
        if not ranged and v.id~="beetle" and v.id~="loader" then return end
        sim.oddActive,sim.oddCooldown,sim.oddSkillFlash=0,0,0
        sim.oddSkillResult,sim.oddSkillResultTimer="前方无有效目标 · 未消耗技能",2
        sim.message,sim.messageTimer=sim.oddSkillResult,2
        return
    end
    if ranged then
        sim.oddSkillResult,sim.oddSkillResultTimer="已发射 · 直线弹道，可被躲避",2
        sim.message,sim.messageTimer=sim.oddSkillResult,2
        local projectiles=race.mixedProjectiles or {};race.mixedProjectiles=projectiles
        local targetSim=best.isPlayer and race.sim or best.driveSim
        local targetSpec=Data.Get(best.vehicleId)
        local y=sourceBottom+v.size[2]*.5
        local targetY=best.y+(targetSim and targetSim.oddAltitude or 0)+(targetSpec and targetSpec.size[2] or 1.5)*.5
        local dx,dy,dz=best.x-source.x,targetY-y,best.z-source.z
        local length=math.max(.01,math.sqrt(dx*dx+dy*dy+dz*dz))
        projectiles[#projectiles+1]={kind=v.id,x=source.x,z=source.z,y=y,
            vx=dx/length*65,vy=dy/length*65,vz=dz/length*65,ttl=.8,source=source,target=best}
        return
    end
    M.Hit(race,source,best,v)
end
function M.Hit(race,source,best,v)
    local targetSim=best.isPlayer and race.sim or best.driveSim
    local sourceSim=source.isPlayer and race.sim or source.driveSim
    if targetSim and (targetSim.oddShield or 0)>0 then
        if sourceSim then sourceSim.oddSkillResult,sourceSim.oddSkillResultTimer="攻击被护盾挡住",2 end
        return false
    end
    if sourceSim then
        sourceSim.oddSkillResult,sourceSim.oddSkillResultTimer="技能命中 · 对手减速20%，失衡3秒",2.5
        sourceSim.message,sourceSim.messageTimer=sourceSim.oddSkillResult,2.5
    end
    best.speed=best.speed*.8;best.hitTimer,best.hitShake=1,.65
    best.boostTimer=0
    local side=best.lane>=source.lane and 1 or -1
    local spec=Data.Get(best.vehicleId)
    local margin=(spec and spec.size[1]*.5 or .3)+.15
    best.wantedLane=clamp(best.lane+side*1.4,-race.roadHalfWidth+margin,race.roadHalfWidth-margin)
    best.oddDisrupt=3
    if targetSim then
        targetSim.speed=best.speed;targetSim.oddDisrupt=3
        if v.id=="loader" or v.id=="beetle" then targetSim.oddLaunch=1.2 end
    end
    if best.isPlayer then
        race.sim.heading=(race.sim.heading+side*5)%360
        race.sim.message,race.sim.messageTimer=v.name.."技能命中 · 注意修正方向",2
    end
    race:Collision(best);race:Emit("vehicle-skill",source.id,best.id)
    return true
end
function M.RaceStep(race,dt)
    if race.phase~="racing" then return end
    local shots=race.mixedProjectiles or {}
    for i=#shots,1,-1 do
        local p=shots[i];local x0,y0,z0=p.x,p.y,p.z
        p.x,p.y,p.z=p.x+p.vx*dt,p.y+p.vy*dt,p.z+p.vz*dt
        p.ttl=p.ttl-dt
        local target=p.target
        local targetSim=target.isPlayer and race.sim or target.driveSim
        local spec=Data.Get(target.vehicleId)
        local radius=p.kind=="jellyfish" and .325 or .18
        local halfWidth=(spec and spec.size[1] or .6)*.5+radius
        local halfLength=(spec and spec.size[3] or 2)*.5+radius
        local halfHeight=(spec and spec.size[2] or 1.5)*.5
        local lift=(targetSim and targetSim.oddAltitude or 0)+halfHeight
        local ax,az=x0-(target.contactX or target.x),z0-(target.contactZ or target.z)
        local bx,bz=p.x-target.x,p.z-target.z
        local angle=math.rad(target.yaw or 0);local sx,sz=math.sin(angle),math.cos(angle)
        local hit,enter,leave=swept(ax*sz-az*sx,ax*sx+az*sz,bx*sz-bz*sx,bx*sx+bz*sz,halfWidth,halfLength)
        if hit then
            local ay,by=y0-(target.contactY or target.y)-lift,p.y-target.y-lift
            local overlap,low,high=swept(ay,0,by,0,halfHeight+radius,1)
            hit=overlap and math.max(enter,low)<=math.min(leave,high)
        end
        hit=hit and not target.finished and not target.eliminated
        if hit then M.Hit(race,p.source,target,Data.Get(p.kind)) end
        if not hit and (p.ttl<=0 or target.finished or target.eliminated) then
            local sourceSim=p.source.isPlayer and race.sim or p.source.driveSim
            if sourceSim then sourceSim.oddSkillResult,sourceSim.oddSkillResultTimer="攻击未命中 · 目标已躲避",2 end
        end
        if hit or p.ttl<=0 or target.finished or target.eliminated or p.source.eliminated then
            if p.node then p.node:Dispose() end
            table.remove(shots,i)
        end
    end
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
