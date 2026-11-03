-- 生产城市有界CPU采样；独立场景，不创建Session、不读取或写入玩家档。
local City=require("Career.City")
local Actor=require("Career.Actor")
local Traffic=require("Career.Traffic")
local Contact=require("Career.VehicleContact")
local Collision=require("Career.FootprintCollision")
local Footprints=require("Career.VehicleFootprints")
local Motion=require("Career.TrafficMotion")
---@type Scene?
local scene_=nil
---@type (fun())?
local cleanup_=nil
local function measure(label,count,fn)
    collectgarbage("collect")
    local start=os.clock()
    for i=1,count do fn(i) end
    local elapsed=os.clock()-start
    print(string.format("[城市CPU采样] %s %d次 %.6fs / 平均%.3fms",label,count,elapsed,elapsed/count*1000))
    return elapsed
end
-- 独立保存修改前全部碰撞分支及调用顺序，不为参考路径增加部件预扫描或临时表。
-- 此参考只用于隔离采样入口，不替换正常游戏逻辑。
local productionFree=Collision.Free
local function referenceEdges(poly,callback)
    for i,a in ipairs(poly.points) do
        local b=poly.points[i%#poly.points+1]
        local dx,dz=b.x-a.x,b.z-a.z
        local length=math.sqrt(dx*dx+dz*dz)
        if length>1e-9 then callback(dz/length,-dx/length,a,b,length) end
    end
end
local function referenceProject(part,nx,nz)
    if part.radius then
        local d=part.x*nx+part.z*nz
        return d-part.radius,d+part.radius
    end
    local low,high=math.huge,-math.huge
    for _,v in ipairs(part.points) do
        local value=v.x*nx+v.z*nz
        low,high=math.min(low,value),math.max(high,value)
    end
    return low,high
end
local function referenceCirclePoly(circle,poly,pad)
    local inside,best=true,math.huge
    referenceEdges(poly,function(nx,nz,a,b,length)
        if (circle.x-a.x)*nx+(circle.z-a.z)*nz>0 then inside=false end
        local t=math.max(0,math.min(1,((circle.x-a.x)*(b.x-a.x)+(circle.z-a.z)*(b.z-a.z))/(length*length)))
        best=math.min(best,(circle.x-a.x-(b.x-a.x)*t)^2+(circle.z-a.z-(b.z-a.z)*t)^2)
    end)
    return not inside and best>=(circle.radius+pad)^2-1e-9
end
local function referencePartFree(a,b,pad)
    if a.x1 and b.x1 and (a.x2+pad<b.x1 or b.x2+pad<a.x1
        or a.z2+pad<b.z1 or b.z2+pad<a.z1) then return true end
    if a.radius and b.radius then return (a.x-b.x)^2+(a.z-b.z)^2>=(a.radius+b.radius+pad)^2-1e-9 end
    if a.radius then return referenceCirclePoly(a,b,pad) end
    if b.radius then return referenceCirclePoly(b,a,pad) end
    local separate=false
    local function axis(nx,nz)
        local al,ah=referenceProject(a,nx,nz)
        local bl,bh=referenceProject(b,nx,nz)
        if ah+pad<=bl+1e-9 or bh+pad<=al+1e-9 then separate=true end
    end
    referenceEdges(a,axis);referenceEdges(b,axis)
    return separate
end
local function referenceFree(a,b,pad)
    pad=pad or 0
    if a.x2+pad<=b.x1 or b.x2+pad<=a.x1 or a.z2+pad<=b.z1 or b.z2+pad<=a.z1 then return true end
    for _,pa in ipairs(a.parts) do for _,pb in ipairs(b.parts) do
        if not referencePartFree(pa,pb,pad) then return false end
    end end
    return true
end
local function collisionChecks()
    local source=Collision.Shape({{points={{x=-1,z=-2},{x=1,z=-2},{x=1,z=2},{x=-1,z=2},{x=-1,z=2}}}})
    local sources={source,Collision.Box(-.5,-1,.5,1),Footprints.Get("sedan"),Footprints.Get("truck"),Footprints.Get("borrowed_ebike")}
    local tested=0
    for _,first in ipairs(sources) do for _,second in ipairs(sources) do
        for _,yaw in ipairs({0,17,37,90,143}) do
            local a=Collision.Pose(first,0,0,yaw)
            for i=1,36 do
                local b=Collision.Pose(second,math.sin(i*1.7)*4,math.cos(i*2.3)*5,(i*31)%360)
                for _,pad in ipairs({0,.004,.02}) do
                    assert(productionFree(a,b,pad)==referenceFree(a,b,pad),"SAT早退改变复合车壳判定")
                    assert(productionFree(b,a,pad)==referenceFree(b,a,pad),"SAT早退改变反向车壳判定")
                    tested=tested+2
                end
            end
        end
    end end
    for _,gap in ipairs({-.000000001,0,.000000001,.003999999,.004,.004000001}) do
        local a=Collision.Box(-1,-1,1,1)
        local b=Collision.Box(1+gap,-1,3+gap,1)
        assert(productionFree(a,b,.004)==referenceFree(a,b,.004),"SKIN切边判定改变")
        tested=tested+1
    end
    print(string.format("[碰撞SAT等价] PASS %d组 双向/五车型/多朝向/退化边/4mm边界",tested))
end
local function runProbe()
    local restores={}
    cleanup_=function()
        for i=#restores,1,-1 do restores[i]() end
        restores={}
        Collision.Free=productionFree
        if scene_ then scene_:Dispose();scene_=nil end
    end
    local reference=false
    for _,arg in ipairs(GetArguments()) do if arg=="-collisionreference" then reference=true end end
    if reference then Collision.Free=referenceFree end
    print("[城市CPU路径] "..(reference and "原始SAT全轴" or "优化SAT早退"))
    require("Career.TrafficChecks").FixedTicks()
    Motion.CacheChecks()
    Contact.SupportChecks()
    require("Career.Crowd").CacheChecks()
    scene_=Scene();scene_:CreateComponent("Octree")
    local city=City.New(scene_)
    local actor=Actor.New(scene_,city)
    local traffic=Traffic.New(city,actor);city.traffic=traffic
    local calls=0
    local surface=city.Surface
    city.Surface=function(self,x,z) calls=calls+1;return surface(self,x,z) end
    for _,id in ipairs({"borrowed_ebike","sedan","truck"}) do
        calls=0
        measure("胎面/"..id,30,function() Contact.Solve(city,id,3,-35,0,0) end)
        print(string.format("[城市CPU采样] %s 30次胎面共%d次真实Surface查询",id,calls))
    end
    calls=0
    measure("停站人物含停放车视觉",30,function() actor:Update(1/30,{walkX=0,walkY=0},0) end)
    print("[城市CPU采样] 停站Surface查询 "..calls)
    calls=0
    local costs={}
    local function timed(owner,key,label)
        local original=owner[key]
        local previous=rawget(owner,key)
        restores[#restores+1]=function() rawset(owner,key,previous) end
        owner[key]=function(...)
            local start=os.clock()
            local result=table.pack(original(...))
            local cost=costs[label] or {seconds=0,count=0}
            cost.seconds,cost.count=cost.seconds+os.clock()-start,cost.count+1
            costs[label]=cost
            return table.unpack(result,1,result.n)
        end
    end
    timed(traffic,"Step","车辆移动与精确碰撞")
    timed(traffic.pedestrians,"Update","行人移动与骨骼")
    timed(city,"StaticShapeFree","静态车壳查询（含在车辆移动中）")
    timed(Contact,"Solve","最终轮胎求解")
    local trace={}
    measure("老街15车8人真实Update",30,function()
        traffic:Update(1/30)
        local state={time=traffic.time,carry=traffic.tickCarry,cars={},people={}}
        for i,car in ipairs(traffic.cars) do state.cars[i]={car.s,car.x,car.z,car.yaw,car.speed} end
        for i,p in ipairs(traffic.pedestrians.people) do
            local walk=p.localWalk
            local points={}
            for j,point in ipairs(walk.points) do points[j]={x=point.x,z=point.z} end
            state.people[i]={p.s,p.x,p.z,p.yaw,p.phase,p.gaitWeight,p.direction,
                walk.index,walk.cooldown,walk.plans,walk.attempts,walk.waiting,points}
        end
        trace[#trace+1]=state
    end)
    for i=#restores,1,-1 do restores[i]() end
    restores={}
    print("[交通逐帧状态] "..require("cjson").encode(trace))
    print("[城市CPU采样] 老街Surface查询 "..calls)
    for label,cost in pairs(costs) do
        print(string.format("[城市CPU分项] %s %.3fms/帧，%d次调用",label,cost.seconds/30*1000,cost.count))
    end
    -- 对照同一生产城市的原逐顶点求解：平地、路沿、外区、海岸坡面及不同朝向。
    local compared=0
    for _,id in ipairs({"borrowed_ebike","sedan","truck","cruiser","sport"}) do
        for _,p in ipairs({{3,-35},{6,-35},{8.7,-35},{12,-35},{768,-30},{-450,-450},{-495,-495}}) do
            for _,yaw in ipairs({0,37,90}) do
                for _,lean in ipairs({-12,0,12}) do
                    local h,a,b=Contact.Solve(city,id,p[1],p[2],yaw,lean)
                    local eh,ea,eb=Contact.SolveExact(city,id,p[1],p[2],yaw,lean)
                    assert(math.abs(h-eh)<.000001 and math.abs(a-ea)<.000001 and math.abs(b-eb)<.000001,
                        "平面快路改变胎面解 "..id.." "..p[1]..","..p[2].." lean="..lean)
                    compared=compared+1
                end
            end
        end
    end
    print(string.format("[胎面等价回归] PASS %d真实地表/朝向/车型；flat=%d exact=%d",compared,Contact.flatHits,Contact.exactSolves))
    collisionChecks()
    local isolated={options={test=true},restoreTestStorage=function() end,city=city}
    require("Career.TrafficChecks").Layers(isolated)
    require("Career.NavigationChecks").Run(isolated)
    traffic:Dispose();city.traffic=nil;actor:Dispose();city:Dispose()
    Collision.Free=productionFree
    print("[城市CPU采样] 完成；同机CPU对照，不是手机FPS或GPU耗时")
end
function Start()
    local ok,err=pcall(runProbe)
    if cleanup_ then cleanup_();cleanup_=nil end
    assert(ok,tostring(err))
end
function Stop()
    if cleanup_ then cleanup_();cleanup_=nil end
    if scene_ then scene_:Dispose();scene_=nil end
end
