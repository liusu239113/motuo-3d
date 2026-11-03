-- 混合竞速隔离验收：只创建内存仿真与临时Scene，不写入玩家存档。
---@class MixedCheckDrive:RideSimulation
---@field oddTerrain string
---@field oddSkillResult string
---@field oddSkillResultTimer number
---@field oddPreviousAltitude number
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
            check(math.abs(size.x-v.size[1])<.02 and math.abs(size.y-v.size[2])<.02
                and math.abs(size.z-v.size[3])<.02,
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
    local unpainted={RouteLength=map.RouteLength,Roads=map.Roads,Track=map.Track,mixedTerrainVisualsReady=false}
    for _,section in ipairs({2,4,5,7}) do
        check(Rules.Terrain(unpainted,section*145+1,6)=="asphalt","未交付地形贴图时禁用隐形惩罚")
    end
    check(Rules.Terrain(map,650,6)=="water","禁用未交付场景不改默认纯规则夹具平衡")
    local function terrain(id)
        local s=Sim.New(map) --[[@as MixedCheckDrive]]
        s:SetVehicle(id);s:Reset(false);s.roadS=650;s.lateral=6;s.speed=25
        Rules.Before(s,.02,{},map)
        -- 夹具代表已稳定飞行的一步，不把初始化0m→飞行高度当成本次垂直扫掠。
        s.oddPreviousAltitude=s.oddAltitude
        return s
    end
    check(terrain("jellyfish").oddSpeedScale>terrain("ebike").oddSpeedScale,"水母涉水优势")
    local windMap={RouteLength=2400,Roads=map.Roads,Track={theme="canyon"}}
    local wind=terrain("helicopter")
    wind.roadS,wind.lateral,wind.elapsed=320,6,1
    Rules.Before(wind,.02,{},windMap)
    check(wind.oddTerrain=="wind" and math.abs(wind.oddDriveScale-.85)<.0001
        and math.abs(wind.oddGripScale-.72)<.0001,"飞机风区有真实动力和抓地惩罚")
    wind.x,wind.z=0,0
    Rules.After(wind,.02,{},nil,0,0,0,false)
    check(math.abs(wind.x)>math.sin(1.2)*.02*.65,"飞机风区横漂大于原通用横漂")
    for _,section in ipairs({2,4,7}) do
        local air=terrain("helicopter");air.roadS=section*145+1
        Rules.Before(air,.02,{},map)
        check(air.oddSpeedScale<=1,"飞机免地表减速但不白得地形极速加成："..air.oddTerrain)
    end
    local beetle=terrain("beetle")
    for _=1,1000 do Rules.Before(beetle,.02,{},map) end
    check(beetle.oddSteam>.95,"锹甲持续奔跑积蒸汽")
    beetle.impactSerial=beetle.impactSerial+1;Rules.Before(beetle,.02,{},map)
    check(beetle.oddSteam<.01,"重击清空蒸汽")
    local cicada=terrain("cicada");cicada.oddSpring=0;Rules.Before(cicada,.02,{},map)
    local exhausted=cicada.oddSpeedScale
    Rules.Before(cicada,.02,{skill=true},map)
    check(cicada.oddSpring>21 and cicada.oddSpeedScale>exhausted,"木蝉耗尽与上弦有真实差异")
    -- 高度扫掠（米）：车体[bottom,bottom+H]；交通[carY,carY+1.8]。
    -- 水平从z=-10扫到+10穿过交通中心；垂直相切计接触，±.01m分别验证重叠/分离。
    -- 上方交通底面在自身顶面附近，避免旧固定1.45m高度把高/矮车型误判。
    for _,id in ipairs({"tank","beetle","ebike","helicopter"}) do
        local spec=assert(Data.Get(id))
        for _,altitude in ipairs({0,3}) do
            for _,offset in ipairs({-.01,0,.01}) do
                local drive=Sim.New(map);assert(drive:SetVehicle(id));drive:Reset(false)
                drive.x,drive.y,drive.z,drive.yaw,drive.speed=0,0,10,0,20
                drive.oddAltitude=altitude
                local carY=altitude+spec.size[2]+offset
                local car={x=0,y=carY,z=0,yaw=0,width=2,halfLength=2,height=1.8,passed=true}
                local before=drive.impactSerial
                drive:Traffic({traffic={car}},0,0,-10,0,1)
                check((drive.impactSerial>before)==(offset<=0),id.."真实车高扫掠："..altitude.."/"..offset)
                drive:Traffic({traffic={car}},0,0,-10,0,1)
                check(drive.impactSerial==before+(offset<=0 and 1 or 0),id.."连续接触不重复撞击")
            end
        end
    end
    local world={mixedObstacles={{id=1,x=0,y=0,z=20,yaw=0,kind="crate",halfWidth=.65,
        halfLength=.7,height=1,active=true,breakable=true}},mixedCoins={}}
    local tank=terrain("tank");tank.x,tank.y,tank.z=0,0,22
    Rules.Obstacles(tank,world,0,0,15)
    check(not world.mixedObstacles[1].active,"坦克连续扫掠破障")
    Rules.ResetCourse(world);check(world.mixedObstacles[1].active,"重赛恢复障碍")
    local heli=terrain("helicopter");heli.x,heli.y,heli.z=0,0,22
    local speed=heli.speed;Rules.Obstacles(heli,world,0,0,15)
    check(heli.speed==speed and world.mixedObstacles[1].active,"低空载具跨越低障碍")
    -- 侧视（米）：正式等比空障[2.3,3.984149]；飞机[2.5,2.5+机高]相交，矮车从下方通过。
    -- 俯视：z=15 -> 22扫过z=20，x=0正撞；x=6留出完整机宽，不是中心点越界即算安全。
    local airHeight,airHalfLength=1.684149,1.694325*.5
    local function airWorld()
        return {mixedObstacles={{id=901,x=0,y=2.3,z=20,yaw=0,kind="airbarrier",
            halfWidth=1.3,halfLength=airHalfLength,height=airHeight,active=true,breakable=false}},mixedCoins={}}
    end
    for _,case in ipairs({{id="helicopter",x=0,hit=true},{id="helicopter",x=6,hit=false},
        {id="ebike",x=0,hit=false}}) do
        local drive=terrain(case.id);drive.x,drive.y,drive.z=case.x,0,22
        local obstacle=airWorld()
        local oldSpeed,health,serial=drive.speed,drive.health,drive.impactSerial
        Rules.After(drive,.02,{},obstacle,case.x,0,15,false)
        check((drive.impactSerial>serial)==case.hit,case.id.."空障三维判定/侧移："..case.x)
        check(case.hit and drive.speed<oldSpeed and drive.health<health
            or not case.hit and drive.speed==oldSpeed and drive.health==health,"空障真实扣速扣车况而非仅提示")
        local onceSpeed,onceHealth,onceSerial=drive.speed,drive.health,drive.impactSerial
        drive.oddHitLock,drive.crashCooldown=0,0
        Rules.After(drive,.02,{},obstacle,case.x,0,15,false)
        check(drive.speed==onceSpeed and drive.health==onceHealth and drive.impactSerial==onceSerial,
            "连续接触由接触集合去重，不仅靠冷却")
    end
    -- 高速整步：起终点都离z=0窄空障20m，末帧12m粗筛不能代替整段包围盒。
    local fast=terrain("helicopter");fast.x,fast.y,fast.z=0,0,20
    local fastWorld=airWorld();fastWorld.mixedObstacles[1].z=0
    local fastSpeed,fastHealth,fastSerial=fast.speed,fast.health,fast.impactSerial
    Rules.After(fast,.02,{},fastWorld,0,0,-20,false)
    check(fast.impactSerial==fastSerial+1 and fast.speed<fastSpeed and fast.health<fastHealth,
        "高速-20到+20整步扫过空障仍真实扣速扣车况")
    -- 静止飞机与移动空障：X从-5扫到+5，前后均不交；Y仅末段相交则不能跨时间误撞。
    for _,mode in ipairs({"cross","different-time","static"}) do
        local still=terrain("helicopter");still.x,still.y,still.z=0,0,0
        local moving=airWorld()
        local obstacle=moving.mixedObstacles[1]
        obstacle.x,obstacle.z=5,0
        if mode~="static" then obstacle.previousX,obstacle.previousZ=-5,0 end
        if mode=="different-time" then
            obstacle.previousY,obstacle.y=12,still.oddAltitude+assert(Data.Get("helicopter")).size[2]-.01
        end
        local oldSpeed,oldHealth,oldSerial=still.speed,still.health,still.impactSerial
        Rules.After(still,.02,{},moving,0,0,0,false)
        check(mode=="cross" and still.impactSerial==oldSerial+1 and still.speed<oldSpeed and still.health<oldHealth
            or mode~="cross" and still.impactSerial==oldSerial and still.speed==oldSpeed and still.health==oldHealth,
            "移动空障相对XYZ同时扫掠及无previous静障兼容："..mode)
    end
    -- 垂直扫掠必须与水平入盒时间相交：同样的落高不能在帧末只看重叠。
    for _,case in ipairs({{from=0,to=6,hit=true},{from=10,to=2.3+airHeight-.01,hit=false}}) do
        local drive=terrain("ebike");drive.x,drive.y,drive.z=0,case.to,22
        local serial=drive.impactSerial
        Rules.After(drive,.02,{},airWorld(),0,case.from,15,false)
        check((drive.impactSerial>serial)==case.hit,"空障XYZ同时扫掠而非单独轴重叠")
    end
    local course=Rules.CreateCourse(map)
    local groundCount,airCount=0,0
    for _,o in ipairs(course) do
        if o.kind=="airbarrier" then
            airCount=airCount+1
            check(math.abs(o.y-2.3)<.001 and math.abs(o.height-airHeight)<.001
                and math.abs(o.halfWidth-1.3)<.001 and math.abs(o.halfLength-airHalfLength)<.001,
                "正式空障XYZ碰撞尺寸匹配真实MDL等比bounds")
            local paired=false
            for _,g in ipairs(course) do
                if g.kind~="airbarrier" and g.s==o.s and g.lane==o.lane then paired=true end
            end
            check(paired,"空障同侧叠在地面机关，不封死另一侧")
        else groundCount=groundCount+1 end
    end
    check(airCount>0 and airCount==math.floor(groundCount/6),"每六个地面机关追加空中障碍")
    for _,o in ipairs(course) do
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
    -- 单独加载真实Landscape源码保留六图/旧lake坡配置；不切换共享模块，不污染活动地图状态。
    local landscapeFile=assert(cache:GetFile("Landscape.lua"))
    local landscapeLines={}
    while not landscapeFile:IsEof() do landscapeLines[#landscapeLines+1]=landscapeFile:ReadLine() end
    landscapeFile:Dispose()
    local courseMap=assert(load(table.concat(landscapeLines,"\n"),"MixedCourseLandscape","t",
        setmetatable({},{__index=_G})))()
    local originalTrack,originalRamps=Landscape.activeId,Landscape.Ramps
    local legacyCount=0
    for _,track in ipairs(tracks) do
        assert(courseMap.SelectTrack(track.id))
        local planned=Rules.CreateCourse(courseMap)
        check(#planned>0,"六图真实配置CreateCourse无nil且生成机关："..track.id)
        for _,ramp in ipairs(courseMap.Ramps) do
            local rampS=ramp.s
            if type(rampS)~="number" and ramp.x and ramp.z then
                rampS=courseMap.NearestRoad(ramp.x,ramp.z)
                if track.id=="lake" then legacyCount=legacyCount+1 end
            end
            if type(rampS)=="number" then
                local reserved=ramp.landingEndS and ramp.landingEndS-rampS or (ramp.length or 12)+25
                for _,o in ipairs(planned) do
                    local d=(o.s-rampS)%courseMap.RouteLength
                    check(d>=reserved and d<=courseMap.RouteLength-30,
                        track.id.."正式空地机关避开真实坡入口/落地走廊")
                end
            end
        end
    end
    check(legacyCount>=2,"真实lake保留两座只有世界x/z的旧坡配置并执行投影")
    check(Landscape.activeId==originalTrack and Landscape.Ramps==originalRamps,
        "六图检查不改变共享Landscape地图及坡表身份")
    local invalidMap={RouteLength=map.RouteLength,Roads=map.Roads,RoadPoint=map.RoadPoint,Ramps={{}}}
    check(#Rules.CreateCourse(invalidMap)==#course,"无法投影的无效旧坡记录不误排机关")
    -- 只隔离车型登记和AI配置来覆盖任意长度；其余构造/发车仍执行真实Race源码。
    -- 虚构ID不进入动力/资产加载，也不修改共享MixedAssets或Catalog。
    local raceFile=assert(cache:GetFile("Race.lua"))
    local raceLines={};while not raceFile:IsEof() do raceLines[#raceLines+1]=raceFile:ReadLine() end;raceFile:Dispose()
    local AI=require("RaceAI")
    local pool={}
    local rosterRace=assert(load(table.concat(raceLines,"\n"),"MixedRosterRace","t",setmetatable({
        require=function(name)
            if name=="MixedAssets" then return {RaceIds=function() return pool end} end
            if name=="RaceAI" then return {Build=AI.Build,Configure=function() end} end
            return require(name)
        end},{__index=_G})))()
    local sample=rosterRace.New(Landscape,Sim.New(Landscape),{mixed=true,quiet=true,seed=4817})
    for size=0,64 do
        pool={};for i=1,size do pool[i]="roster_"..i end
        local effective=size==0 and {"sport","cruiser","rally"} or pool
        local n=#effective
        for _,offset in ipairs({0,1,5,n-1,n,n+5,-1}) do
            sample.options.rosterOffset=offset
            sample:Start()
            local rng=4817;for _=1,54 do rng=(rng*48271)%2147483647 end
            check(sample.rng==rng,"选车不得额外消耗随机流")
            local seen,roster={},{}
            local step=n%7~=0 and 7 or 1
            for _,r in ipairs(sample.racers) do
                if not r.isPlayer then
                    local index=#roster+1
                    if (index-1)%n==0 then seen={} end
                    check(not seen[r.vehicleId],"任意池长耗尽前不重复："..size)
                    check(r.vehicleId==effective[((index-1)*step+offset)%n+1],"offset确定性轮换且保留原互质池顺序")
                    seen[r.vehicleId]=true;roster[index]=r.vehicleId
                else check(r.vehicleId==sample.sim.vehicleId,"轮换不改变玩家车型") end
            end
            sample:Start()
            for _,r in ipairs(sample.racers) do
                if not r.isPlayer then check(r.vehicleId==roster[r.index<5 and r.index or r.index-1],"重赛同offset稳定重放") end
            end
        end
    end
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
    race.phase="racing"
    for _=1,100 do
        race.elapsed=race.elapsed+.02
        for _,r in ipairs(race.racers) do
            if not r.isPlayer then
                local before=r.distanceDriven
                AI.Update(race,r,.02)
                check(r.driveSim.distance==r.distanceDriven and r.distanceDriven>=before,
                    "正式AI动力里程逐步同步真实行程，不使用时间或路线坐标")
            end
        end
    end
    for _,r in ipairs(race.racers) do
        if not r.isPlayer then check(r.driveSim.distance>0,"正式AI轮转得到非零里程") end
    end
    -- Snapshot -> Observe提前40m识别空障，不用原abs(y差)<3丢掉高处相交盒。
    -- 真实source保留height：4m交通可触及飞机；1m地障应只被地面矮车观察。
    local airSource=airWorld().mixedObstacles[1]
    airSource.s,airSource.lane,airSource.z=40,0,40
    local raisedSource={id=902,x=0,y=3.2,z=40,s=40,lane=0,yaw=0,kind="airbarrier",
        halfWidth=1.3,halfLength=airHalfLength,height=airHeight,active=true}
    local lowSource={id=903,x=0,y=0,z=40,s=40,lane=0,yaw=0,kind="barrel",
        halfWidth=.65,halfLength=.7,height=1,active=true}
    local highSource={id=904,x=0,y=10,z=40,s=40,lane=0,yaw=0,kind="airbarrier",
        halfWidth=1.3,halfLength=airHalfLength,height=airHeight,active=true}
    local tallTraffic={x=0,y=0,z=40,s=40,lane=0,yaw=0,width=2,halfLength=2,height=4,speed=0}
    for _,id in ipairs({"helicopter","ebike"}) do
        local observer={vehicleId=id,driveSim=terrain(id),x=0,y=0,z=0,s=0,speed=25,skill=1,
            perception={timer=0,age=0,recovery=0,recoverySeconds=0,period=.5,missChance=0,misses=0,observations={}}}
        local watching={map=map,length=map.RouteLength,options={mixed=true,
            world={mixedObstacles={airSource,raisedSource,lowSource,highSource}}},
            traffic={tallTraffic},aiObstacles={},Random=function() return .5 end}
        AI.Snapshot(watching)
        AI.Observe(watching,observer,.02)
        local seen={}
        for _,o in ipairs(observer.perception.observations) do
            seen[o.source]=true
            check(o.s==40 and o.source.height~=nil,"提前观察保留真实source与高度，不伪造低矮交通")
            if o.source~=tallTraffic then check(o.mixed==true,"观察缓存保留mixed障碍标记") end
        end
        local flying=id=="helicopter"
        check((seen[airSource]==true)==flying and (seen[raisedSource]==true)==flying,
            id.."提前感知按立体相交过滤空障，不按绝对y差")
        check((seen[lowSource]==true)==not flying and not seen[highSource] and seen[tallTraffic],
            id.."高矮分离但不漏判真正相交的高交通")
    end
    -- 真实AI.Update -> Mixed.Before/After与玩家相同空障盒；隔离单车，无感知避让干扰。
    local function aiAir(id,lane,obstacles)
        local test={map=map,sim=Sim.New(map),length=map.RouteLength,elapsed=0,rng=4817,
            roadHalfWidth=8,corridor=8.8,options={mixed=true,quiet=true,world=obstacles},
            aiObstacles={},traffic={},AdvanceGates=function() end,
            Project=function(_,x,z) return map.NearestRoad(x,z) end}
        setmetatable(test,{__index=Race})
        AI.Build(test)
        local template=assert(race.racers[1])
        local r={} --[[@as table]]
        for key,value in pairs(template) do r[key]=value end
        r.vehicleId,r.isPlayer,r.finished,r.eliminated,r.index=id,false,false,false,1
        r.s,r.lane,r.wantedLane,r.speed,r.steer=19.9,lane,lane,25,0
        r.driveSim=terrain(id)
        AI.Configure(test,r,1)
        r.mistakeTimer,r.nitroCooldown=1000,1000
        test.racers={r};test:Place(r)
        AI.Update(test,r,.02)
        return r
    end
    for _,case in ipairs({{id="helicopter",lane=0,hit=true},{id="helicopter",lane=6,hit=false},
        {id="ebike",lane=0,hit=false}}) do
        local clean=aiAir(case.id,case.lane,nil)
        local blocked=aiAir(case.id,case.lane,airWorld())
        check(case.hit and blocked.speed<clean.speed and blocked.driveSim.health<clean.driveSim.health
            or not case.hit and blocked.speed==clean.speed and blocked.driveSim.health==clean.driveSim.health,
            "真实AI与玩家共用高矮空障碰撞响应："..case.id.."/"..case.lane)
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
        local empty=racer(kind,0,0)
        local emptyRace=arena(empty,{})
        Rules.Before(empty.driveSim,.02,{skill=true},map)
        Rules.Attack(emptyRace,empty,empty.driveSim)
        check(empty.driveSim.oddCooldown==0 and #(emptyRace.mixedProjectiles or {})==0,
            kind.."无目标不消耗冷却或空发弹体")
        check(type(empty.driveSim.oddSkillResult)=="string" and empty.driveSim.oddSkillResult~=""
            and empty.driveSim.oddSkillResultTimer>0,kind.."无目标给出可见技能反馈")
        local noTargetResult=empty.driveSim.oddSkillResult
        for _,mode in ipairs({"hit","dodge","height","shield","expired"}) do
            local source,target=racer(kind,0,0),racer("ebike",0,20)
            local test=arena(source,{target});source.driveSim.oddAttack=true
            Rules.Attack(test,source,source.driveSim)
            check(#test.mixedProjectiles==1 and target.speed==25,kind.."发射而非瞬间命中")
            check(type(source.driveSim.oddSkillResult)=="string" and source.driveSim.oddSkillResult~=""
                and source.driveSim.oddSkillResult~=noTargetResult and source.driveSim.oddSkillResultTimer>0,
                kind.."发射立即反馈而非只等命中")
            local firedResult=source.driveSim.oddSkillResult
            if mode=="dodge" then target.x,target.contactX=7,7
            elseif mode=="height" then target.driveSim.oddAltitude=10
            elseif mode=="shield" then target.driveSim.oddShield=3
            elseif mode=="expired" then target.z,target.contactZ=100,100 end
            for _=1,50 do Rules.RaceStep(test,.02) end
            check(#test.mixedProjectiles==0,kind.."弹体命中或超时后释放")
            check(mode=="hit" and target.speed<25 or mode~="hit" and target.speed==25,
                kind.."三维弹道/横移躲避/高度分离/护盾/超时："..mode)
            if mode=="hit" then
                check(source.driveSim.oddSkillResult~=firedResult and source.driveSim.oddSkillResultTimer>0,
                    kind.."真实命中结果回馈发射者动力状态")
                check(math.abs(target.speed-20)<.0001 and target.driveSim.oddDisrupt==3 and target.boostTimer==0,
                    kind.."命中实际减速20%且失衡3秒并打断氮气")
            else
                check(source.driveSim.oddSkillResult~=firedResult and source.driveSim.oddSkillResultTimer>0,
                    kind.."护盾或躲避也有终态反馈："..mode)
            end
        end
    end
    check(require("ProfileChecks").Run().passed,"旧档和三局试驾事务")
    check(require("RewardedAdsChecks").Run().passed,"广告完成/关闭/拒绝/超时/重复回调")
    print(string.format("[混合验收] PASS %d项 / %d种规则 / 正式资产与未交付车型分离 / 存档和广告隔离回归",count,#Data.List))
    return true
end
return Checks
