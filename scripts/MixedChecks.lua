-- 混合竞速隔离验收：只创建内存仿真与临时Scene，不写入玩家存档。
local Checks={}
function Checks.Run()
    local Data=require("MixedVehicles")
    local Rules=require("MixedRace")
    -- 未交付车型只测规则：隔离加载仿真源码，不改正式目录开放状态，也不开放购买。
    local catalog=require("Catalog")
    local logicalCatalog={Get=function(id)
        local entry=catalog.Get(id)
        if not entry then return nil end
        local copy={};for key,value in pairs(entry) do copy[key]=value end
        copy.available=true
        return copy
    end}
    local file=assert(cache:GetFile("Simulation.lua"))
    local lines={};while not file:IsEof() do lines[#lines+1]=file:ReadLine() end;file:Dispose()
    local environment=setmetatable({require=function(name)
        if name=="Catalog" then return logicalCatalog end
        return require(name)
    end},{__index=_G})
    local Sim=assert(load(table.concat(lines,"\n"),"MixedRulesSimulation","t",environment))()
    local Visual=require("MixedVisuals")
    local Formal=require("MixedAssets")
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
        local wheelRpm=sim.vehicle.maxSpeed*1.25*sim.vehicle.ratios[6]
        check(wheelRpm<sim.vehicle.redline*.9,v.id.."末挡为技能和氮气预留转速")
        sim:Reset(false);sim.speed=20
        Rules.Before(sim,.02,{skill=true,steer=0},map)
        check(sim.oddActive>0 and sim.oddCooldown==v.cooldown,v.id.."技能真实发动")
        local cooldown=sim.oddCooldown
        Rules.Before(sim,.02,{skill=true},map)
        check(sim.oddCooldown<cooldown,v.id.."长按不重复刷新")
        if Formal.IsReady(v.id) then
            local model=Visual.Build(scene,v.id)
            local parts=model:GetComponents("StaticModel",true)
            check(#parts>0,v.id.."必须使用正式MDL")
            check(model:GetVar("FormalModel"):GetString()==Formal.Vehicles[v.id].model,v.id.."禁止占位几何回退")
            local size=model:GetVar("VehicleSize"):GetVector3()
            check(math.abs(size.x-v.size[1])<.02 and math.abs(size.z-v.size[3])<.02,
                v.id.."正式源三角面实测尺寸匹配碰撞")
            for _,part in ipairs(parts) do
                local mat=part:GetMaterial()
                check(mat and mat:GetTexture(TU_DIFFUSE) and mat:GetTexture(TU_NORMAL),v.id.."完整原始D/N贴图")
            end
            if v.id=="helicopter" then
                local rotor=model:GetChild("Rotor",true)
                check(rotor~=nil,"正式主桨独立节点")
                local first=rotor.rotation
                Visual.Animate(model,v.id,.037,{oddActive=0})
                check(first~=rotor.rotation,"正式主桨真实转动")
            elseif v.id=="ebike" then
                local wheel=assert(model:GetChild("FrontWheel",true))
                local body=assert(model:GetChild("Body",true))
                local first=wheel.rotation
                local fixed=body.transform
                Visual.Animate(model,v.id,0,{distance=.207})
                check(first~=wheel.rotation,"电动车原网格车轮按里程旋转")
                check(body.transform==fixed,"电动车轮动画不转动车身")
            end
            model:Dispose()
        else
            check(catalog.Get(v.id).available==false,v.id.."正式资产未交付时禁止驾驶或几何占位")
        end
        -- 平直柏油千米计时只检查基础动力，不冒充六图综合胜率；技能按冷却发动。
        local run=Sim.New(map);run:SetVehicle(v.id);run:Reset(false)
        for _=1,4500 do
            run:Step(.02,{throttle=1,steer=0,skill=run.oddCooldown<=0})
            if run.z>=1000 then break end
        end
        check(run.z>=1000 and run.elapsed<90,v.id.."基础千米不掉队至停滞")
        print(string.format("[动力基线] %s 千米 %.2fs / 尾速 %.1fkm/h",v.id,run.elapsed,run.speed*3.6))
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
    local tracks=require("Tracks").List()
    for _,track in ipairs(tracks) do
        check(track.width>=16 and track.shoulder>=track.width*.5,"宽体赛道与路肩："..track.id)
        local topLow,topHigh=math.huge,0
        for _,v in ipairs(Data.List) do topLow=math.min(topLow,v.top);topHigh=math.max(topHigh,v.top) end
        check(topHigh/topLow<1.22,"基础极速差距限制，慢车保留技能赢法："..track.id)
    end
    local Race=require("Race")
    local Landscape=require("Landscape")
    local race=Race.New(Landscape,Sim.New(Landscape),{mixed=true,laps=1,quiet=true,rosterOffset=0})
    race:Start(1)
    local seen={}
    for _,r in ipairs(race.racers) do
        if not r.isPlayer then
            check(not seen[r.vehicleId],"同场对手种类不重复")
            seen[r.vehicleId]=true
            local entry=catalog.Get(r.vehicleId)
            check(entry and entry.available and math.abs(r.driveSim.vehicle.maxSpeed-entry.speedStat/3.6)<.001,
                "AI只用已交付正式车型及自身动力")
        end
    end
    race:Stop()
    local front=Rules.ContactResponse("tank",.8,3,.1)
    local rear=Rules.ContactResponse("tank",.8,-3,.1)
    local side,disrupt=Rules.ContactResponse("tank",.8,0,2)
    check(math.abs(front*.8-.98)<.001 and rear==1,"坦克正面压制不误用于尾撞")
    check(side<1 and disrupt>0,"坦克侧面受击失衡")
    local function racer(id,x,z)
        local drive=terrain(id);drive.x,drive.y,drive.z=x,0,z
        return {id=id..x..z,vehicleId=id,x=x,y=0,z=z,contactX=x,contactY=0,contactZ=z,
            lane=x,wantedLane=x,yaw=0,speed=25,boostTimer=2,isPlayer=false,driveSim=drive}
    end
    local function arena(source,targets)
        local rs={source};for _,r in ipairs(targets) do rs[#rs+1]=r end
        return {phase="racing",sim=source.driveSim,player=source,racers=rs,roadHalfWidth=8,
            events=0,Collision=function() end,Emit=function(self) self.events=self.events+1 end}
    end
    local tail=racer("centipede",0,0)
    local left,right,ahead,high=racer("ebike",-3,0),racer("ebike",3,-2),racer("ebike",0,4),racer("helicopter",0,-3)
    local field=arena(tail,{left,right,ahead,high})
    tail.driveSim.oddAttack=true;Rules.Attack(field,tail,tail.driveSim)
    check(left.speed<25 and right.speed<25 and field.events==2,"铁尾横扫同时击退两侧多个对手")
    check(ahead.speed==25 and high.speed==25,"铁尾不命中正前方和高空对手")
    check(left.boostTimer==0 and left.driveSim.speed==left.speed,"技能打断氮气并同步AI真实动力")
    local chair=racer("office",0,0);local a,b=racer("ebike",0,4),racer("ebike",0,-4)
    local spin=arena(chair,{a,b});chair.driveSim.oddAttack=true;Rules.Attack(spin,chair,chair.driveSim)
    check(a.speed<25 and b.speed<25,"转椅范围弹开前后多个对手")
    for _,kind in ipairs({"jellyfish","helicopter"}) do
        for _,mode in ipairs({"hit","dodge","height","shield","expired"}) do
            local source,target=racer(kind,0,0),racer("ebike",0,20)
            local test=arena(source,{target});source.driveSim.oddAttack=true
            Rules.Attack(test,source,source.driveSim)
            check(#test.mixedProjectiles==1 and target.speed==25,kind.."发射而非瞬间命中")
            if mode=="dodge" then target.x,target.contactX=7,7
            elseif mode=="height" then target.driveSim.oddAltitude=10
            elseif mode=="shield" then target.driveSim.oddShield=3
            elseif mode=="expired" then target.z,target.contactZ=100,100 end
            for _=1,50 do Rules.RaceStep(test,.02) end
            check(#test.mixedProjectiles==0,kind.."弹体命中或超时后释放")
            check(mode=="hit" and target.speed<25 or mode~="hit" and target.speed==25,
                kind.."三维弹道/横移躲避/高度分离/护盾/超时："..mode)
        end
    end
    check(require("ProfileChecks").Run().passed,"旧档和三局试驾事务")
    check(require("RewardedAdsChecks").Run().passed,"广告完成/关闭/拒绝/超时/重复回调")
    print(string.format("[混合验收] PASS %d项 / %d种规则 / 正式资产与未交付车型分离 / 存档和广告隔离回归",count,#Data.List))
    return true
end
return Checks
