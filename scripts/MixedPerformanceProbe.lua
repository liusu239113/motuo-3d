-- 混合竞速有界CPU对照：真实赛道/正式机关/九车仿真，不加载Profile、Store或广告。
local Landscape=require("Landscape")
local Course=require("MixedCourse")
local Mixed=require("MixedRace")
local Simulation=require("Simulation")
local Race=require("Race")
local M={}
---@type Scene?
local scene_=nil
local function measure(label,count,fn)
    collectgarbage("collect")
    local start=os.clock()
    for i=1,count do fn(i) end
    local elapsed=(os.clock()-start)*1000
    print(string.format("[竞速CPU] %s count=%d total=%.3fms mean=%.3fms",label,count,elapsed,elapsed/count))
    return elapsed/count
end
-- 独立保留修前八角点算法，验证生产优化后每个真实球/链盒及previous坐标。
local function reference(part,origin,yaw,angle)
    local rotation=Quaternion(0,0,angle)
    local low=Vector3(math.huge,math.huge,math.huge)
    local high=Vector3(-math.huge,-math.huge,-math.huge)
    for _,x in ipairs({part.low.x,part.high.x}) do
        for _,y in ipairs({part.low.y,part.high.y}) do
            for _,z in ipairs({part.low.z,part.high.z}) do
                local point=rotation*Vector3(x,y,z)+Vector3(0,5.2,0)
                low=Vector3(math.min(low.x,point.x),math.min(low.y,point.y),math.min(low.z,point.z))
                high=Vector3(math.max(high.x,point.x),math.max(high.y,point.y),math.max(high.z,point.z))
            end
        end
    end
    local center=(low+high)*.5
    local a=math.rad(yaw)
    return {x=origin.x+math.cos(a)*center.x+math.sin(a)*center.z,
        y=origin.y+low.y,z=origin.z-math.sin(a)*center.x+math.cos(a)*center.z,
        halfWidth=(high.x-low.x)*.5,halfLength=(high.z-low.z)*.5,height=high.y-low.y}
end
local function checkBounds(world)
    local count=0
    for _,clock in ipairs({0,.02,.26,1.7,4.2,11.1}) do
        local before={}
        for _,swing in ipairs(world.mixedSwings) do for _,part in ipairs(swing.parts) do
            local r=part.record
            before[r]={x=r.x,y=r.y,z=r.z}
        end end
        Course.Update(world,clock)
        for _,swing in ipairs(world.mixedSwings) do
            local angle=math.sin(clock*1.7+swing.phase)*22
            for _,part in ipairs(swing.parts) do
                local expected=reference(part,swing.origin,swing.yaw,angle)
                local actual=part.record
                for _,key in ipairs({"x","y","z","halfWidth","halfLength","height"}) do
                    assert(math.abs(actual[key]-expected[key])<.0001,"机关bounds回归 "..key)
                    count=count+1
                end
                local s,lane=Landscape.NearestRoad(actual.x,actual.z)
                assert(math.abs(actual.s-s)<.0001 and math.abs(actual.lane-lane)<.0001,"道路投影必须保持真实值")
                local old=before[actual]
                assert(actual.previousX==old.x and actual.previousY==old.y and actual.previousZ==old.z,
                    "固定步previous必须保留同一时间区间")
                count=count+3
            end
        end
    end
    print(string.format("[竞速CPU] bounds/投影/previous PASS %d",count))
end
local function checkSpatial(world)
    local Spatial=require("CourseSpatial")
    local a,b={mixedObstacles={},mixedCoins={}},{mixedObstacles={},mixedCoins={}}
    for _,o in ipairs(world.mixedObstacles) do
        local first,second={},{}
        for key,value in pairs(o) do if key~="node" then first[key]=value;second[key]=value end end
        a.mixedObstacles[#a.mixedObstacles+1]=first;b.mixedObstacles[#b.mixedObstacles+1]=second
    end
    for _,coin in ipairs(world.mixedCoins) do
        a.mixedCoins[#a.mixedCoins+1]={x=coin.x,y=coin.y,z=coin.z,active=true}
        b.mixedCoins[#b.mixedCoins+1]={x=coin.x,y=coin.y,z=coin.z,active=true}
    end
    Spatial.Build(b)
    local function drive(id,o,indexed,span)
        local sim={vehicleId=id,x=o.x+span,y=o.y,z=o.z+span,heading=37,speed=30,health=100,impactSerial=0}
        function sim:Impact() self.impactSerial=self.impactSerial+1;self.health=self.health-7 end
        Mixed.Reset(sim)
        sim.oddAltitude=id=="helicopter" and 2.5 or 0;sim.oddPreviousAltitude=sim.oddAltitude
        Mixed.Obstacles(sim,indexed,o.x-span,o.y,o.z-span)
        return sim
    end
    local count=0
    for i,o in ipairs(world.mixedObstacles) do
        for _,id in ipairs({"beetle","helicopter"}) do
            for _,w in ipairs({a,b}) do
                for _,r in ipairs(w.mixedObstacles) do r.active=true end
                for _,c in ipairs(w.mixedCoins) do c.active=true end
            end
            local span=i%7==0 and 70 or 8
            local first,second=drive(id,o,a,span),drive(id,o,b,span)
            assert(first.speed==second.speed and first.health==second.health
                and first.impactSerial==second.impactSerial and first.oddPickups==second.oddPickups,
                "空间索引改变碰撞结果："..tostring(o.id).."/"..id)
            for key in pairs(first.oddContacts) do assert(second.oddContacts[key],"空间索引漏碰撞") end
            for key in pairs(second.oddContacts) do assert(first.oddContacts[key],"空间索引多碰撞") end
            count=count+1
        end
    end
    print(string.format("[竞速CPU] 空间索引/全扫描等价 PASS %d / 所有真实障碍、地面/飞行、高速跨格",count))
end
function Start()
    assert(Landscape.SelectTrack("circuit"))
    scene_=Scene()
    scene_:CreateComponent("Octree")
    local world={root=scene_:CreateChild("真实机关CPU对照"),landscape=Landscape}
    Course.Build(world)
    print(string.format("[竞速CPU] circuit %.1fm swings=%d obstacles=%d coins=%d",
        Landscape.RouteLength,#world.mixedSwings,#world.mixedObstacles,#world.mixedCoins))
    checkBounds(world)
    local calls=0
    local nearest=Landscape.NearestRoad
    Landscape.NearestRoad=function(x,z) calls=calls+1;return nearest(x,z) end
    measure("Course.Update",30,function(i) Course.Update(world,i*.02) end)
    print("[竞速CPU] Course.NearestRoad calls="..calls)
    Landscape.NearestRoad=nearest
    local sim=Simulation.New(Landscape)
    assert(sim:SetVehicle("beetle"))
    local p,yaw=Landscape.TrafficPose(20,0)
    sim.x,sim.y,sim.z,sim.heading=p.x,p.y,p.z,yaw
    measure("九车Obstacle",30,function()
        for _=1,9 do Mixed.Obstacles(sim,world,p.x,p.y,p.z) end
    end)
    local race=Race.New(Landscape,sim,{mixed=true,world=world,traffic={},laps=2,seed=4817})
    race:Start()
    for _=1,151 do race:BeforeStep(.02,{});race:AfterStep(.02) end
    assert(#race.racers==9 and race.phase=="racing","必须真实九车发车")
    local input={throttle=1,steer=0,brake=0}
    local clock=0
    measure("完整固定步九车",40,function()
        clock=clock+.02
        local drive=race:BeforeStep(.02,input)
        Course.Update(world,clock)
        sim:Step(.02,drive,world)
        race:AfterStep(.02)
    end)
    print("[竞速CPU] COMPLETE / CPU对照，不是手机FPS或GPU计时")
    checkSpatial(world)
    require("CourseWorldChecks").Run(world)
    local Assets=require("VehicleAssets")
    local ids=require("Catalog").AvailableIds()
    local stages=0
    Assets.PrepareDetails(ids,function() stages=stages+1 end)
    assert(stages==#ids,"预热进度必须覆盖全部正式车型")
    print("[竞速CPU] 正式车型预热 PASS "..stages)
end
function Stop()
    if scene_ then scene_:Dispose();scene_=nil end
end
return M
