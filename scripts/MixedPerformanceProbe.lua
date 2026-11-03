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
end
function Stop()
    if scene_ then scene_:Dispose();scene_=nil end
end
return M
