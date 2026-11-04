-- 九辆普通摩托隔离验收；仅内存仿真，不初始化Profile、不读写真实存档、不调用SDK。
local Data=require("MixedVehicles")
local Rules=require("MixedRace")
local Motorcycle=require("MotorcycleSkills")
local Sim=require("Simulation")
local Race=require("Race")
local Checks={}
Checks.Ids={"sport","sport_2","sport_3","rally","rally_2","rally_3","cruiser","cruiser_2","cruiser_3"}
local MAP={Goals={},RouteLength=0,RoadPoint=function(s) return {x=0,y=0,z=s},0 end,
    Height=function() return 0,true end,NearestRoad=function(x,z) return z,x end}

function Checks.Run()
    local assertions=0
    local function check(ok,text) assert(ok,"[普通摩托技能验收] "..text);assertions=assertions+1 end
    check(Data.RunSkillRules().passed,"九个独立定义与平衡边界")
    local function drive(id,active,map)
        local sim=Sim.New(map or MAP)
        check(sim:SetVehicle(id),id.."目录可驾驶")
        sim:Reset(false);sim.speed=20;sim.throttle=1
        if active then Rules.Before(sim,.02,{skill=true,throttle=1},map or MAP) end
        return sim
    end
    for _,id in ipairs(Checks.Ids) do
        local skill=assert(Data.GetMotorcycleSkill(id))
        local sim=drive(id,true)
        check(sim.motorcycleActive==skill.duration and sim.motorcycleCooldown==skill.cooldown,id.."独立持续与冷却")
        local serial=sim.motorcycleSkillSerial
        Rules.Before(sim,.02,{skill=true,throttle=1},MAP)
        check(sim.motorcycleSkillSerial==serial and sim.motorcycleActive<skill.duration,id.."长按不刷新")
        local x,z,speed,health=sim.x,sim.z,sim.speed,sim.health
        Rules.Before(sim,.02,{},MAP)
        check(sim.x==x and sim.z==z and sim.speed==speed and sim.health==health,id.."规则无瞬移/直接提速/伤害")
        sim.airborne=true;Rules.Before(sim,.02,{},MAP)
        check(sim.motorcyclePhase=="suppressed" and sim.motorcycleDriveScale==1
            and sim.motorcycleSpeedScale==1,id.."离地抑制真实动力")
        sim.airborne=false;sim.oddDisrupt=1;Rules.Before(sim,.02,{},MAP)
        check(sim.motorcyclePhase=="suppressed",id.."失衡不绕过限制")
        Motorcycle.Reset(sim)
        check(sim.motorcycleActive==0 and sim.motorcycleGuard==0 and sim.motorcycleSkillSerial==0,id.."重赛清理")
        local blocked=drive(id,false);blocked.airborne=true
        Rules.Before(blocked,.02,{skill=true},MAP)
        check(blocked.motorcycleActive==0 and blocked.motorcycleCooldown==0,id.."空中按键不消耗")
        Rules.Before(blocked,.02,{skill=false},MAP);blocked.airborne=false
        Rules.Before(blocked,.02,{skill=true,brake=true},MAP)
        check(blocked.motorcycleCooldown==0,id.."刹车按键不消耗")
    end
    local charge=drive("sport_3",true)
    check(charge.motorcyclePhase=="charge" and charge.motorcycleDriveScale==.78,"银隼先真实蓄力")
    Rules.Before(charge,.66,{},MAP)
    check(charge.motorcyclePhase=="active" and charge.motorcycleDriveScale==1.25
        and charge.motorcycleSpeedScale==1.10,"蓄力后真实二段释放")
    local hill=drive("rally_3",true)
    check(hill.motorcycleDriveScale==1.08,"沙隼平路收益受限")
    hill.groundSlope=.1;Rules.Before(hill,.02,{},MAP)
    check(hill.motorcycleDriveScale==1.25,"沙隼上坡动力真实提高")
    for _,id in ipairs({"sport","sport_2","rally","rally_2","rally_3","cruiser","cruiser_3"}) do
        local base,active=drive(id,false),drive(id,true)
        for _=1,50 do
            base:Step(.02,{throttle=1}, {landscape=MAP,traffic={}})
            active:Step(.02,{throttle=1}, {landscape=MAP,traffic={}})
        end
        check(active.speed>base.speed,id.."真正消费动力而非仅倒计时")
    end
    -- 越野配置只改变map.Height的道路标记；没有隐藏地形或外部存档依赖。
    local rough={Goals={},RouteLength=0,RoadPoint=MAP.RoadPoint,
        Height=function() return 0,false end,NearestRoad=MAP.NearestRoad}
    local raw,grip=drive("rally",false,rough),drive("rally",true,rough)
    for _=1,70 do raw:Step(.02,{throttle=1});grip:Step(.02,{throttle=1}) end
    check(grip.speed>raw.speed+.3,"荒野越野抓地提升真实加速")
    local coastBase,coast=drive("cruiser_3",false),drive("cruiser_3",true)
    for _=1,40 do coastBase:Step(.02,{});coast:Step(.02,{}) end
    check(coast.speed>coastBase.speed+.2,"暗峰收油阻力真实减小")
    local damageBase,armor=drive("cruiser",false),drive("cruiser",true)
    damageBase:Impact("test",20);armor:Impact("test",20)
    check(armor.health>damageBase.health and armor.speed>damageBase.speed,"护航实际减伤保速")
    local guard=drive("cruiser_2",true)
    local before=guard.speed
    guard:Impact("test",20)
    check(guard.speed==before and guard.health==100 and guard.motorcycleGuardBlocks==1
        and guard.motorcycleActive==0 and guard.motorcycleCooldown>0,"首次Impact格挡立即消费")
    guard:Impact("test",20)
    check(guard.health<100 and guard.speed<before and guard.motorcycleGuardBlocks==1,"第二次撞击不能无限护盾")
    local function racer(id,player,x)
        local sim=drive(id,true)
        return {id=id,vehicleId=id,isPlayer=player,x=x,y=0,z=0,contactX=x,contactY=0,contactZ=0,
            yaw=0,speed=20,lane=x,wantedLane=x,immunity=0,driveSim=sim},sim
    end
    local function contact(id,active)
        local a,sim=racer(id,true,0)
        if not active then Motorcycle.Reset(sim) end
        local b=racer("sport",false,.4)
        local race=setmetatable({racers={a,b},sim=sim,options={mixed=false},
            Collision=function() end,Emit=function() end},Race)
        race:Contacts(.02)
        return a,sim
    end
    local base,baseSim=contact("cruiser",false)
    local protected,protectedSim=contact("cruiser",true)
    check(protected.speed>base.speed and protectedSim.health>baseSim.health,"普通竞速接触真实消费减伤保速")
    local momentum=contact("cruiser_3",true)
    local unassisted=contact("cruiser_3",false)
    check(momentum.speed>unassisted.speed,"普通竞速接触真实消费惯性")
    local blocked,blockedSim=contact("cruiser_2",true)
    check(blocked.speed==20 and blockedSim.health==100 and blockedSim.motorcycleGuardBlocks==1,"普通竞速接触消费单次护盾")
    local source,sourceSim=racer("tank",false,0)
    local target,targetSim=racer("rally_2",true,.4)
    local arena={sim=targetSim,roadHalfWidth=8,options={mixed=false},Collision=function() end,Emit=function() end}
    Rules.Hit(arena,source,target,assert(Data.Get("tank")))
    check(targetSim.oddDisrupt==1.5 and target.speed==16,"雪脊缩短真实技能干扰但不免减速")
    local targetGuard,targetGuardSim=racer("cruiser_2",true,.4)
    arena.sim=targetGuardSim
    Rules.Hit(arena,source,targetGuard,assert(Data.Get("tank")))
    check(targetGuard.speed==20 and targetGuardSim.motorcycleGuardBlocks==1
        and targetGuardSim.oddDisrupt==0,"单次护盾挡真实技能且立即消费")
    print(string.format("[普通摩托技能验收] PASS %d项 / 九车型独立 / 动力实效 / 蓄力 / 越野 / 爬坡 / 收油 / 减伤保速 / 单次护盾",assertions))
    return {passed=true,assertions=assertions}
end

-- 引擎对象专项：只创建临时Scene与效果，不创建正式游戏/档案/SDK会话。
function Checks.Visuals(scene)
    local Effects=require("MotorcycleSkillEffects")
    local Bike=require("Bike")
    local count=0
    for _,id in ipairs(Checks.Ids) do
        local sim={vehicleId=id,speed=24,steer=.25,throttle=1}
        Rules.Reset(sim);Rules.Before(sim,.02,{skill=true,throttle=1},MAP)
        local cockpit=Bike.GetCockpit(id)
        local root=scene:CreateChild("EffectCheck_"..id)
        local effect=assert(Effects.New(root,id,cockpit.localOffset.y,2.2))
        effect:Update(.02,sim)
        assert(effect.active and effect.amount>0 and #effect.parts>=3,"未开启独立效果 "..id)
        local pos=effect.parts[1].node.position
        local active,cd,x,z=sim.motorcycleActive,sim.motorcycleCooldown,sim.x,sim.z
        effect:Update(0,{motorcycleActive=0})
        assert(effect.active and effect.parts[1].node.position==pos,"暂停未冻结 "..id)
        assert(sim.motorcycleActive==active and sim.motorcycleCooldown==cd and sim.x==x and sim.z==z,"表现写入仿真 "..id)
        local cameraNode=scene:CreateChild("CheckHelmet")
        cameraNode.position=cockpit.localOffset
        cameraNode.rotation=Quaternion(cockpit.pitch,0,0)
        local camera=cameraNode:CreateComponent("Camera");camera.fov=72;camera.nearClip=.05
        local p=camera:WorldToScreenPoint(effect.frontAnchor.worldPosition)
        assert(p.x>.05 and p.x<.95 and p.y>.05 and p.y<.95,"第一人称前场不可见 "..id)
        effect:Update(.02,{motorcycleActive=0,motorcycleGuardFlash=0})
        assert(not effect.active and not effect.root.enabled,"结束效果残留 "..id)
        effect:Dispose();effect:Dispose()
        assert(effect.disposed and #effect.materials==0,"释放不幂等 "..id)
        cameraNode:Dispose();root:Dispose();count=count+8
    end
    print(string.format("[普通摩托表现验收] PASS %d项 / 九种结构 / 第一人称投影 / 暂停 / 不回写 / 结束清理 / Dispose",count))
    return {passed=true,assertions=count}
end
return Checks
