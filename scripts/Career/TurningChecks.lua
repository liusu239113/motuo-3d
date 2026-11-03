-- Isolated old/new continuous-turn regression. No player transforms or storage writes.
local Actor=require("Career.Actor")
local C=require("Career.FootprintCollision")
local Q=require("Career.CityCollision")
local F=require("Career.VehicleFootprints")
local Checks={}
local function wrap(yaw) return (yaw+180)%360-180 end
-- Intentionally retain the pre-optimization algorithm, including every strip's
-- endpoint point expansion. Do not call RotationPart/TurnFree as the oracle.
local function reference(actor,x,z,fromYaw,toYaw)
    local delta=wrap(toYaw-fromYaw)
    if math.abs(delta)<1e-8 then return fromYaw,false end
    local count=math.max(1,math.ceil(math.abs(delta)/.25))
    local shape=actor:Footprint(true)
    if actor.city:IsShapeFree(x,z,C.Circle(0,0,shape.reach),0,"vehicle",actor.city:Surface(x,z),actor.vehicleId) then
        return wrap(toYaw),false
    end
    local accepted=fromYaw
    for i=1,count do
        local nextYaw=fromYaw+delta*i/count
        local first=C.Pose(shape,0,0,accepted)
        local last=C.Pose(shape,0,0,nextYaw)
        local parts={}
        local pad=shape.reach*(1-math.cos(math.rad(math.abs(delta/count))*.5))+.000001
        for index,p in ipairs(first.parts) do
            local points={}
            for _,v in ipairs(p.points) do
                for _,d in ipairs({{pad,pad},{-pad,pad},{pad,-pad},{-pad,-pad}}) do points[#points+1]={x=v.x+d[1],z=v.z+d[2]} end
            end
            for _,v in ipairs(last.parts[index].points) do
                for _,d in ipairs({{pad,pad},{-pad,pad},{pad,-pad},{-pad,-pad}}) do points[#points+1]={x=v.x+d[1],z=v.z+d[2]} end
            end
            parts[#parts+1]={points=C.Hull(points)}
        end
        if not actor.city:IsShapeFree(x,z,C.Shape(parts),0,"vehicle",actor.city:Surface(x,z),actor.vehicleId) then return accepted,true end
        accepted=nextYaw
    end
    return wrap(accepted),false
end
local function fixture(obstacles,crowd,delivery,parking)
    local city={space="city",obstacles=obstacles or {},surfaceCalls=0,
        crowd={people=crowd or {},disposed=false},deliveryPeople={people=delivery or {}}}
    city.Surface=function(self,_x,_z) self.surfaceCalls=self.surfaceCalls+1;return 0 end
    city.WalkSurface=function(_self,_x,_z,height) return height or 0 end
    city.IsShapeFree=function(self,x,z,shape,yaw,mode,height,ignoreId)
        return Q.ShapeFree(self,shape,x,z,yaw,mode,height,ignoreId)
    end
    if parking then city.actor={mounted=true,vehicleId="borrowed_ebike",parking=parking} end
    Q.Index(city)
    return city
end
local function probe(city,id)
    return setmetatable({city=city,vehicleId=id,mounted=true},Actor)
end
-- Top view (metres): r=.004 skin; visible shell / mirror / cargo against
-- [thin wall], parallel tight walls, or a parked shell. A same-XZ person at
-- Y=6 must not block a ground turn; Y=0 must block if its real circle touches.
-- All tests retain .25-degree casts, actual mesh strip geometry and arc pad.
---@param session CareerSession
function Checks.Run(session)
    assert(session.options.test and session.restoreTestStorage,"转向检查必须隔离真实存档")
    local tested,blocked,free,oldHulls,newHulls=0,0,0,0,0
    local oldSeconds,newSeconds,oldQueries,newQueries=0,0,0,0
    local hull,shapeFree,beginTurn=C.Hull,Q.ShapeFree,Q.BeginTurn
    local currentCount,currentQueries=0,0
    local function counted(points) currentCount=currentCount+1;return hull(points) end
    local function query(...)
        currentQueries=currentQueries+1
        return shapeFree(...)
    end
    local function begin(...)
        currentQueries=currentQueries+1
        return beginTurn(...)
    end
    local function measure(fn,actor,x,z,a,b)
        currentCount,currentQueries=0,0
        C.Hull,Q.ShapeFree,Q.BeginTurn=counted,query,begin
        local started=os.clock()
        local ok,yaw,hit=pcall(fn,actor,x,z,a,b)
        local seconds=os.clock()-started
        C.Hull,Q.ShapeFree,Q.BeginTurn=hull,shapeFree,beginTurn
        assert(ok,tostring(yaw))
        return yaw,hit,currentCount,seconds,currentQueries
    end
    local ok,reason=pcall(function()
        for _,id in ipairs({"borrowed_ebike","sport"}) do
            local shape=F.Get(id) -- expensive model read is outside timing/counts
            local cases={
                {name="road",city=fixture()},
                {name="side-wall",city=fixture({{x1=shape.x2+.035,x2=shape.x2+.055,z1=-6,z2=6}})},
                {name="narrow-gap",city=fixture({
                    {x1=shape.x1-.08,x2=shape.x1-.04,z1=-6,z2=6},
                    {x1=shape.x2+.04,x2=shape.x2+.08,z1=-6,z2=6}})},
                {name="nose-thin-wall",city=fixture({{x1=-5,x2=5,z1=shape.z2+.008,z2=shape.z2+.009}})},
                {name="parked",city=fixture(nil,nil,nil,{sedan={x=1.5,z=.5,yaw=37}})},
                {name="ground-person",city=fixture(nil,{{x=shape.x2+.34,z=0,radius=.30,height=0,active=true}})},
                {name="bridge-person",city=fixture(nil,{{x=0,z=0,radius=.30,height=6,active=true}})},
                {name="delivery",city=fixture(nil,nil,{{x=shape.x2+.43,z=0,y=0,active=true,hold=0}})},
            }
            for _,case in ipairs(cases) do
                local actor=probe(case.city,id)
                for _,from in ipairs({0,37,179.9,-179.9}) do
                    for _,delta in ipairs({-8,-2.1,-.251,.251,2.1,8}) do
                        local expected,eh,oh,ot,oq=measure(reference,actor,0,0,from,from+delta)
                        local actual,ah,nh,nt,nq=measure(Actor.TurnTo,actor,0,0,from,from+delta)
                        assert(nq==1,"一次TurnTo重复收集候选")
                        assert(eh==ah and math.abs(wrap(expected-actual))<1e-8,
                            string.format("转向不等价 %s/%s from=%.4f delta=%.4f old=%.9f/%s new=%.9f/%s",
                                id,case.name,from,delta,expected,tostring(eh),actual,tostring(ah)))
                        tested=tested+1
                        if ah then blocked=blocked+1 else free=free+1 end
                        oldHulls,newHulls=oldHulls+oh,newHulls+nh
                        oldSeconds,newSeconds=oldSeconds+ot,newSeconds+nt
                        oldQueries,newQueries=oldQueries+oq,newQueries+nq
                    end
                end
            end
            -- Real frame-time turn sizes, including the ceil(dt*60) thresholds.
            for _,dt in ipairs({1/60,.017,1/30,.0334,.1}) do
                local steps=math.ceil(dt/(1/60))
                local delta=math.deg((35/3.6)/1.45*math.tan(math.rad(18)))*dt/steps*.5
                local actor=probe(cases[2].city,id)
                local a,hit=reference(actor,0,0,0,delta)
                local b,newHit=Actor.TurnTo(actor,0,0,0,delta)
                assert(hit==newHit and math.abs(wrap(a-b))<1e-8,"真实dt转向不等价")
                tested=tested+1
            end
        end
        -- A corner's circular arc rises above both endpoints: endpoint-only
        -- bounds would miss this .4-micrometre obstacle. Keep original padding.
        local corner=C.Box(-.1,-.01,.1,2)
        local axis=math.deg(math.atan(.1,2))
        local high=math.sqrt(4.01)
        local arcCity=fixture({{x1=-.0000002,x2=.0000002,z1=high-.0000002,z2=high+.0000002}})
        local arcActor=probe(arcCity,"borrowed_ebike")
        arcActor.Footprint=function() return corner end
        local a,hit=reference(arcActor,0,0,axis-.125,axis+.125)
        local b,newHit=Actor.TurnTo(arcActor,0,0,axis-.125,axis+.125)
        assert(hit and newHit and math.abs(a-b)<1e-8,"弧线外凸/薄障碍被首末界遗漏")
        tested=tested+1
        local edgeActor=probe(fixture(),"borrowed_ebike")
        for _,position in ipairs({{14999,0},{-14999,0},{0,14999},{0,-14999}}) do
            for _,delta in ipairs({-2.1,2.1}) do
                local expected,oldHit=reference(edgeActor,position[1],position[2],0,delta)
                local actual,newEdgeHit=Actor.TurnTo(edgeActor,position[1],position[2],0,delta)
                assert(oldHit==newEdgeHit and math.abs(expected-actual)<1e-8,"世界边界转向不等价")
                tested=tested+1
            end
        end
        assert(blocked>0 and free>0,"转向回归未覆盖允许/阻挡")
        assert(oldHulls>0 and newHulls<oldHulls,"转向候选早拒绝未减少Hull构造")
        assert(newQueries<oldQueries,"转向候选复用未降低查询次数")
    end)
    C.Hull,Q.ShapeFree,Q.BeginTurn=hull,shapeFree,beginTurn
    assert(ok,tostring(reason))
    print(string.format("[转向等价回归] PASS %d cases / blocked=%d free=%d / Hull %d -> %d / queries %d -> %d / CPU %.3f -> %.3fms；同机CPU非手机FPS",
        tested,blocked,free,oldHulls,newHulls,oldQueries,newQueries,oldSeconds*1000,newSeconds*1000))
    return {cases=tested,oldHulls=oldHulls,newHulls=newHulls,oldQueries=oldQueries,newQueries=newQueries,
        oldSeconds=oldSeconds,newSeconds=newSeconds}
end
return Checks
