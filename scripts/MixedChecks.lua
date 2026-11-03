-- 混合竞速隔离验收：只创建内存仿真与临时Scene，不写入玩家存档。
local Checks={}
function Checks.Run()
    local Data=require("MixedVehicles")
    local Rules=require("MixedRace")
    local Sim=require("Simulation")
    local Visual=require("MixedVisuals")
    local map={RouteLength=2400,Roads={{width=8,shoulder=11.5}},Track={theme="lake"},Goals={},
        RoadPoint=function(s) return {x=0,y=0,z=s},0 end,
        Height=function() return 0,true end,
        NearestRoad=function(x,z) return z,x end}
    local count=0
    local function check(v,message) assert(v,"[混合验收] "..message);count=count+1 end
    local scene=Scene();scene:CreateComponent("Octree")
    for _,v in ipairs(Data.List) do
        local sim=Sim.New(map) --[[@as RideSimulation]]
        check(sim:SetVehicle(v.id),v.id.."动力配置")
        sim:Reset(false);sim.speed=20
        Rules.Before(sim,.02,{skill=true,steer=0},map)
        check(sim.oddActive>0 and sim.oddCooldown==v.cooldown,v.id.."技能真实发动")
        local cooldown=sim.oddCooldown
        Rules.Before(sim,.02,{skill=true},map)
        check(sim.oddCooldown<cooldown,v.id.."长按不重复刷新")
        local model=Visual.Build(scene,v.id)
        local bounds=BoundingBox()
        local parts=model:GetComponents("StaticModel",true)
        check(#parts>4,v.id.."必须具有独立多部件3D模型")
        for _,p in ipairs(parts) do bounds:Merge(p.worldBoundingBox) end
        check(math.abs(bounds.size.x-v.size[1])<.02 and math.abs(bounds.size.z-v.size[3])<.02,
            v.id.."模型尺寸与碰撞目录一致")
        check(math.abs(bounds.min.y)<.02,v.id.."车底贴地")
        Visual.Animate(model,v.id,2,sim);model:Dispose()
    end
    scene:Dispose()
    check(Rules.Terrain(map,650,0)=="asphalt" and Rules.Terrain(map,650,6)=="water","中路可绕行，翼侧涉水")
    local function terrain(id)
        local s=Sim.New(map) --[[@as RideSimulation]]
        s:SetVehicle(id);s:Reset(false);s.roadS=650;s.lateral=6;s.speed=25
        Rules.Before(s,.02,{},map);return s
    end
    check(terrain("jellyfish").oddSpeedScale>terrain("ebike").oddSpeedScale,"水母涉水优势")
    local beetle=terrain("beetle")
    for _=1,1000 do Rules.Before(beetle,.02,{},map) end
    check(beetle.oddSteam>.95,"锹甲持续奔跑积蒸汽")
    beetle.impactSerial=beetle.impactSerial+1;Rules.Before(beetle,.02,{},map)
    check(beetle.oddSteam<.01,"重击清空蒸汽")
    local cicada=terrain("cicada");cicada.oddSpring=0;Rules.Before(cicada,.02,{},map)
    local exhausted=cicada.oddSpeedScale
    Rules.Before(cicada,.02,{skill=true},map)
    check(cicada.oddSpring>21 and cicada.oddSpeedScale>exhausted,"木蝉耗尽与上弦有真实差异")
    local world={mixedObstacles={{id=1,x=0,y=0,z=20,yaw=0,kind="crate",halfWidth=.65,
        halfLength=.7,height=1,active=true,breakable=true}},mixedCoins={}}
    local tank=terrain("tank");tank.x,tank.y,tank.z=0,0,22
    Rules.Obstacles(tank,world,0,0,15)
    check(not world.mixedObstacles[1].active,"坦克连续扫掠破障")
    Rules.ResetCourse(world);check(world.mixedObstacles[1].active,"重赛恢复障碍")
    local heli=terrain("helicopter");heli.x,heli.y,heli.z=0,0,22
    local speed=heli.speed;Rules.Obstacles(heli,world,0,0,15)
    check(heli.speed==speed and world.mixedObstacles[1].active,"低空载具跨越低障碍")
    for _,o in ipairs(Rules.CreateCourse(map)) do
        check(o.s>120 and math.abs(o.lane)+o.halfWidth+2.7<8,"发车区与宽体安全通道")
    end
    check(require("ProfileChecks").Run().passed,"旧档和三局试驾事务")
    check(require("RewardedAdsChecks").Run().passed,"广告完成/关闭/拒绝/超时/重复回调")
    print(string.format("[混合验收] PASS %d项 / %d种独立3D载具 / 技能、地形、破障、存档和广告隔离回归",count,#Data.List))
    return true
end
return Checks
