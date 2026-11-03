-- Collision adapter only: immutable WorldData cells + City local rectangles +
-- Traffic shell snapshots + independent parking. No streamed visual dependency.
local C=require("Career.FootprintCollision")
local F=require("Career.VehicleFootprints")
local World=require("Career.WorldData")
local Housing=require("Career.HousingData")
local Environment=require("Career.CityEnvironment")
local Motion=require("Career.TrafficMotion")
local Q={}
-- 网格仅裁剪静态候选，最终仍走原多边形/连续扫掠；不合并、不缩小障碍。
-- 4m格：车辆/行人查询只波及贴身格，候选数比16m格少一个量级。
local CELL=4
local CELL_STRIDE=131072
local function cellKey(ix,iz) return ix*CELL_STRIDE+iz end
function Q.Index(city)
    local index={source=city.obstacles,count=#city.obstacles,cells={}}
    for _,o in ipairs(city.obstacles) do
        for ix=math.floor(o.x1/CELL),math.floor(o.x2/CELL) do
            for iz=math.floor(o.z1/CELL),math.floor(o.z2/CELL) do
                local id=cellKey(ix,iz)
                local list=index.cells[id] or {};list[#list+1]=o;index.cells[id]=list
            end
        end
    end
    city.collisionIndex=index
    return index
end
-- 静态矩形的窄相多边形随描述复用；弱键不阻止WorldData的128块缓存淘汰。
-- 核对四界，测试/室内若原地修改矩形也会失效；不缓存移动体或碰撞结果。
local rectangles=setmetatable({},{__mode="k"})
local function rect(o)
    local saved=rectangles[o]
    if saved and saved.x1==o.x1 and saved.x2==o.x2 and saved.z1==o.z1 and saved.z2==o.z2 then return saved end
    local shape=C.Box(o.x1,o.z1,o.x2,o.z2)
    rectangles[o]=shape
    return shape
end
local function boundsOverlap(shape,o,dx,dz)
    return math.max(shape.x2,shape.x2+dx)+C.SKIN>o.x1 and math.min(shape.x1,shape.x1+dx)-C.SKIN<o.x2
        and math.max(shape.z2,shape.z2+dz)+C.SKIN>o.z1 and math.min(shape.z1,shape.z1+dz)-C.SKIN<o.z2
end
local function collect(city,shape,dx,dz,mode,height,ignoreId,staticOnly)
    local result={}
    local function add(o)
        if boundsOverlap(shape,o,dx,dz) then result[#result+1]=rect(o) end
    end
    if city.space~="city" then
        local home=assert(Housing.Get(city.space))
        for _,o in ipairs(city.interior.obstacles[city.space]) do add(o) end
        -- Solid walls immediately outside the room's exact clear floor extents.
        add({x1=-home.width/2-10,x2=-home.width/2,z1=-home.depth/2-10,z2=home.depth/2+10})
        add({x1=home.width/2,x2=home.width/2+10,z1=-home.depth/2-10,z2=home.depth/2+10})
        add({z1=-home.depth/2-10,z2=-home.depth/2,x1=-home.width/2-10,x2=home.width/2+10})
        add({z1=home.depth/2,z2=home.depth/2+10,x1=-home.width/2-10,x2=home.width/2+10})
        return result
    end
    local x1,x2=math.min(shape.x1,shape.x1+dx),math.max(shape.x2,shape.x2+dx)
    local z1,z2=math.min(shape.z1,shape.z1+dz),math.max(shape.z2,shape.z2+dz)
    local index=rawget(city,"collisionIndex")
    if index then
        if index.source~=city.obstacles or index.count~=#city.obstacles then index=Q.Index(city) end
        -- 单格查询占绝大多数，此时逐格去重表纯属每次调用的临时分配，按需创建。
        local seen=nil
        for ix=math.floor((x1-C.SKIN)/CELL),math.floor((x2+C.SKIN)/CELL) do
            for iz=math.floor((z1-C.SKIN)/CELL),math.floor((z2+C.SKIN)/CELL) do
                local list=index.cells[cellKey(ix,iz)]
                if list then
                    if seen then
                        for _,o in ipairs(list) do if not seen[o] then seen[o]=true;add(o) end end
                    else
                        for _,o in ipairs(list) do add(o) end
                        seen={}
                        for _,o in ipairs(list) do seen[o]=true end
                    end
                end
            end
        end
    else for _,o in ipairs(city.obstacles) do add(o) end end
    if x1< -World.OLD_LIMIT or x2>World.OLD_LIMIT or z1< -World.OLD_LIMIT or z2>World.OLD_LIMIT then
        for ix=math.floor((x1-32)/World.CELL),math.floor((x2+32)/World.CELL) do
            for iz=math.floor((z1-32)/World.CELL),math.floor((z2+32)/World.CELL) do
                for _,o in ipairs(World.DescribeCell(ix,iz).obstacles) do
                    if height<(o.y2 or math.huge) and height+1.8>(o.y1 or -math.huge) then add(o) end
                end
            end
        end
    end
    -- Bridges are analytic WorldData objects, not in cell.obstacles. Ground
    -- traffic passes under the deck but cannot pass through the solid ramps.
    for _,d in ipairs(World.Districts) do if d.bridge then
        local bx,bz=d.x,d.z+96
        if x2>bx-26 and x1<bx+26 and z2>bz-68 and z1<bz+4 then
            local cx,cz=(shape.x1+shape.x2)/2,(shape.z1+shape.z2)/2
            local ground=World.Surface(cx,cz,"vehicle",0)
            local deck=World.Surface(cx,cz,"walk",height)
            local onDeck=mode=="walk" and deck>ground+.01 and math.abs(deck-height)<=.65
            if not onDeck then
                for _,side in ipairs({-1,1}) do
                    local enter=mode=="walk" and height<=.65 and cz<=bz-64+.65
                        and x1>=bx+side*20-2 and x2<=bx+side*20+2
                    if not enter then add({x1=bx+side*20-2,x2=bx+side*20+2,z1=bz-64,z2=bz-2}) end
                end
            end
            if height<3 then for _,side in ipairs({-1,1}) do add({x1=bx+side*14-.6,x2=bx+side*14+.6,z1=bz-.6,z2=bz+.6}) end end
        end
    end end
    if staticOnly then return result end
    -- Dynamic bodies are vertical intervals at real terrain/support heights,
    -- not an absolute-height early return (coastal ground can exceed 1m).
    if city.traffic and city.traffic.active then city.traffic:CollisionShapes(result,shape,dx,dz,mode,height) end
    local queryTop=height+1.8
    local function overlaps(y1,y2) return Motion.VerticalOverlap(height,queryTop,y1,y2) end
    local actor=city.actor
    local function circleMayTouch(x,z,r)
        return x+r+C.SKIN>=x1 and x-r-C.SKIN<=x2
            and z+r+C.SKIN>=z1 and z-r-C.SKIN<=z2
    end
    if actor then
        local function park(id,x,z,yaw)
            if id==ignoreId then return end
            local localShape=F.Get(id)
            if not circleMayTouch(x,z,localShape.reach) then return end
            local y1,y2=Motion.VehicleInterval(city,{vehicleId=id,x=x,z=z})
            if overlaps(y1,y2) then result[#result+1]=C.Pose(localShape,x,z,yaw) end
        end
        if not actor.mounted then park(actor.vehicleId,actor.bikeX,actor.bikeZ,actor.bikeYaw) end
        for id,p in pairs(actor.parking) do if id~=actor.vehicleId then park(id,p.x,p.z,p.yaw) end end
    end
    local crowd=city.crowd
    if crowd and not crowd.disposed and (not city.traffic or city.traffic.active) then
        for _,p in ipairs(crowd.people) do
            if p.active and circleMayTouch(p.x,p.z,p.radius) then
                local y1,y2=Motion.PersonInterval(city,p)
                if overlaps(y1,y2) then result[#result+1]=C.Circle(p.x,p.z,p.radius) end
            end
        end
    end
    if city.deliveryPeople then
        for _,p in ipairs(city.deliveryPeople.people) do
            if (p.active or p.hold>0) and circleMayTouch(p.x,p.z,.4) then
                local y1,y2=Motion.PersonInterval(city,p)
                if overlaps(y1,y2) then result[#result+1]=C.Circle(p.x,p.z,.4) end
            end
        end
    end
    return result
end
-- Broad-only proof for a not-yet-posed static vehicle query. Rotating the
-- local total AABB encloses every source part, but is NEVER a collision shape:
-- any candidate or world-edge uncertainty falls back to the exact posed shell.
-- Walk queries deliberately do not use this proof: bridge onDeck/entry tests
-- depend on the exact posed bounds centre and must retain their original path.
function Q.StaticBoundsClear(city,shape,x,z,yaw,mode,height)
    if mode~="vehicle" then return false end
    local a=math.rad(yaw or 0)
    local cs,sn=math.cos(a),math.sin(a)
    local ax,bx=shape.x1*cs,shape.x2*cs
    local az,bz=shape.z1*sn,shape.z2*sn
    local cx,dx=-shape.x1*sn,-shape.x2*sn
    local cz,dz=shape.z1*cs,shape.z2*cs
    -- Outward roundoff allowance only broadens the proof. It cannot reject a
    -- real gap: failing this proof still executes the unchanged exact query.
    local pad=1e-9*(1+math.abs(x)+math.abs(z)+(shape.reach or 0))
    local bounds={x1=x+math.min(ax,bx)+math.min(az,bz)-pad,x2=x+math.max(ax,bx)+math.max(az,bz)+pad,
        z1=z+math.min(cx,dx)+math.min(cz,dz)-pad,z2=z+math.max(cx,dx)+math.max(cz,dz)+pad}
    if bounds.x1< -World.LIMIT or bounds.x2>World.LIMIT or bounds.z1< -World.LIMIT or bounds.z2>World.LIMIT then return false end
    -- Analytic bridge collection reads the bounds centre/extent as well as
    -- overlap. Do not substitute even a conservative centre anywhere in that
    -- support domain; exact original posed bridge candidates remain mandatory.
    for _,d in ipairs(World.Districts) do
        if d.bridge and bounds.x2>d.x-26 and bounds.x1<d.x+26
            and bounds.z2>d.z+96-68 and bounds.z1<d.z+96+4 then return false end
    end
    local candidates=collect(city,bounds,0,0,mode,height,nil,true)
    return #candidates==0,candidates
end
-- One synchronous turn has a fixed centre/support layer and no interleaved
-- world updates. Collect the full rotation disc ONCE, including the original
-- per-interval sagitta box padding. Never cache this across movement/frames.
function Q.BeginTurn(city,x,z,shape,height,ignoreId)
    local pad=shape.reach*(1-math.cos(math.rad(.25)*.5))+.000001
    local envelope=C.Circle(x,z,shape.reach+math.sqrt(2)*pad)
    local candidates=collect(city,envelope,0,0,"vehicle",height,ignoreId,false)
    local disc=C.Circle(x,z,shape.reach)
    local clear=disc.x1>=-World.LIMIT and disc.x2<=World.LIMIT
        and disc.z1>=-World.LIMIT and disc.z2<=World.LIMIT
    if clear then
        for _,other in ipairs(candidates) do
            if not C.Free(disc,other,C.SKIN) then clear=false;break end
        end
    end
    return {x=x,z=z,candidates=candidates,clear=clear}
end
-- Each part's endpoint bounds + sagitta padding enclose the EXACT original
-- convex hull. A disjoint bound can skip construction, never reject a gap.
function Q.TurnFree(context,first,last,pad)
    local x,z=context.x,context.z
    for index,p in ipairs(first.parts) do
        local q=last.parts[index]
        local x1,x2=x+(math.min(p.x1,q.x1)-pad),x+(math.max(p.x2,q.x2)+pad)
        local z1,z2=z+(math.min(p.z1,q.z1)-pad),z+(math.max(p.z2,q.z2)+pad)
        if x1< -World.LIMIT or x2>World.LIMIT or z1< -World.LIMIT or z2>World.LIMIT then return false end
        -- Build lazily at most once per potentially touching strip. Other
        -- strips are a union, so their absence cannot affect this C.Free test.
        local swept=false
        for _,other in ipairs(context.candidates) do
            if x2+C.SKIN>other.x1 and other.x2+C.SKIN>x1
                and z2+C.SKIN>other.z1 and other.z2+C.SKIN>z1 then
                if not swept then swept=C.Pose(C.RotationPart(p,q,pad),x,z,0) end
                if not C.Free(swept,other,C.SKIN) then return false end
            end
        end
    end
    return true
end
-- 已经有当前坐标车壳的交通查询复用同一份只读姿态，不再次旋转相同顶点。
function Q.PosedFree(city,posed,shape,x,z,mode,height,ignoreId,staticOnly,candidates)
    if height==nil then height=city.space=="city" and city:Surface(x,z) or 0 end
    if posed.x1< -World.LIMIT or posed.x2>World.LIMIT or posed.z1< -World.LIMIT or posed.z2>World.LIMIT then return false end
    -- Preserve World bridge edge support / walk-height semantics, not its square
    -- expansion for ordinary walls. The walking footprint really is a circle.
    if city.space=="city" and mode=="walk" and World.NavigationLayer(x,z,height,mode)~="ground" then
        if not World.IsFree(x,z,shape.parts[1].radius or 0,mode,height) then return false end
    end
    -- 候选只能来自本次静态保守广相；动态查询始终重新收集。
    local obstacles=staticOnly and candidates or collect(city,posed,0,0,mode or "vehicle",height or 0,ignoreId,staticOnly)
    for _,other in ipairs(obstacles) do
        if not C.Free(posed,other,C.SKIN) then return false end
    end
    return true
end
function Q.ShapeFree(city,shape,x,z,yaw,mode,height,ignoreId,staticOnly)
    return Q.PosedFree(city,C.Pose(shape,x,z,yaw),shape,x,z,mode,height,ignoreId,staticOnly)
end
function Q.Move(city,x,z,dx,dz,shape,yaw,mode,height,ignoreId,staticOnly)
    if height==nil then height=city.space=="city" and city:Surface(x,z) or 0 end
    local blocked=false
    -- Continuous cast in each bounded displacement, followed by contact-normal
    -- sliding. No X/Z axis bias: oblique car flanks are smooth at any yaw.
    local count=math.max(1,math.ceil(math.sqrt(dx*dx+dz*dz)/.10))
    for _=1,count do
        local rx,rz=dx/count,dz/count
        for _=1,4 do
            if rx*rx+rz*rz<1e-16 then break end
            local posed=C.Pose(shape,x,z,yaw)
            local best,nx,nz=1,0,0
            for _,other in ipairs(collect(city,posed,rx,rz,mode or "vehicle",height or 0,ignoreId,staticOnly)) do
                local t,hx,hz=C.Sweep(posed,other,rx,rz)
                if t and t<best then best,nx,nz=t,hx,hz end
            end
            -- World boundary uses shape extents, never the diagonal radius.
            for _,edge in ipairs({{rx,World.LIMIT-posed.x2,1,0},{-rx,World.LIMIT+posed.x1,-1,0},
                {rz,World.LIMIT-posed.z2,0,1},{-rz,World.LIMIT+posed.z1,0,-1}}) do
                if edge[1]>0 and edge[2]/edge[1]<best then best=math.max(0,edge[2]/edge[1]);nx,nz=-edge[3],-edge[4] end
            end
            local fraction=math.max(0,best-1e-7)
            local tx,tz=x+rx*fraction,z+rz*fraction
            if city.space=="city" and mode=="walk" and World.NavigationLayer(x,z,height,mode)~="ground"
                and not World.IsFree(tx,tz,shape.parts[1].radius or 0,mode,height) then blocked=true;break end
            x,z=tx,tz
            if best>=1 then break end
            blocked=true
            local leftX,leftZ=rx*(1-best),rz*(1-best)
            local inward=math.min(0,leftX*nx+leftZ*nz)
            rx,rz=leftX-inward*nx,leftZ-inward*nz
        end
    end
    return x,z,blocked
end
function Q.Find(city,x,z,shape,yaw,mode,height,ignoreId)
    if Q.ShapeFree(city,shape,x,z,yaw,mode,height,ignoreId) then return x,z end
    for ring=1,100 do
        local distance=ring*.25
        for i=1,32 do
            local a=i*math.pi/16
            local px,pz=x+math.sin(a)*distance,z+math.cos(a)*distance
            if Q.ShapeFree(city,shape,px,pz,yaw,mode,height,ignoreId) then return px,pz end
        end
    end
    error("No collision-free nearby restore position; refusing invisible vehicle overlap")
end
function Q.SegmentFreeExact(city,ax,az,bx,bz,r,mode,height)
    local shape=C.Circle(0,0,r)
    if not Q.ShapeFree(city,shape,ax,az,0,mode,height,nil,true) then return false end
    local x,z,blocked=Q.Move(city,ax,az,bx-ax,bz-az,shape,0,mode,height,nil,true)
    return not blocked and math.abs(x-bx)+math.abs(z-bz)<.0001
end
function Q.SegmentFree(city,ax,az,bx,bz,r,mode,height)
    -- 静态直线只问能否完整通过，不做滑墙：一次完整连续扫掠与逐10cm扫掠等价。
    -- 桥层边缘仍走原逐步支撑检查，不能用直线捷径跨过桥栏或中途换层。
    for _,b in ipairs(World.Bridges) do
        if math.max(ax,bx)+r>b.x-26 and math.min(ax,bx)-r<b.x+26
            and math.max(az,bz)+r>b.z-68 and math.min(az,bz)-r<b.z+4 then
            return Q.SegmentFreeExact(city,ax,az,bx,bz,r,mode,height)
        end
    end
    local y=height or city:Surface(ax,az)
    local shape=C.Circle(ax,az,r)
    if math.min(ax,bx)-r< -World.LIMIT or math.max(ax,bx)+r>World.LIMIT
        or math.min(az,bz)-r< -World.LIMIT or math.max(az,bz)+r>World.LIMIT then return false end
    for _,other in ipairs(collect(city,shape,bx-ax,bz-az,mode or "vehicle",y,nil,true)) do
        if not C.Free(shape,other,C.SKIN) or C.Sweep(shape,other,bx-ax,bz-az) then return false end
    end
    return true
end
function Q.StaticBoundsChecks()
    local city={space="city",obstacles={},Surface=function() return 0 end}
    local source=C.Box(-.7,-2,.9,2)
    assert(Q.StaticBoundsClear(city,source,0,-30,37,"vehicle",0),"empty street failed bounds proof")
    assert(not Q.StaticBoundsClear(city,source,0,-30,37,"walk",0),"walk layer entered static bounds shortcut")
    assert(not Q.StaticBoundsClear(city,source,World.LIMIT,0,37,"vehicle",0),"world edge entered shortcut")
    for _,d in ipairs(World.Districts) do if d.bridge then
        assert(not Q.StaticBoundsClear(city,source,d.x,d.z+96,37,"vehicle",0),"bridge domain entered shortcut")
    end end
    local count,proved=0,0
    for _,o in ipairs({{x1=-2,x2=-1,z1=-32,z2=-28},{x1=.5,x2=.51,z1=-32,z2=-28},
        {x1=-.4,x2=.4,z1=-30.2,z2=-29.8}}) do
        city.obstacles={o};Q.Index(city)
        for _,x in ipairs({-3,-.75,0,.75,3}) do
            for _,yaw in ipairs({0,17,45,90,137,180,271}) do
                local old=Q.ShapeFree(city,source,x,-30,yaw,"vehicle",0,nil,true)
                local empty,candidates=Q.StaticBoundsClear(city,source,x,-30,yaw,"vehicle",0)
                local current=empty or Q.PosedFree(city,C.Pose(source,x,-30,yaw),source,x,-30,"vehicle",0,nil,true,candidates)
                assert(current==old and (not empty or old),"static broad proof changed exact occupancy")
                count=count+1;if empty then proved=proved+1 end
            end
        end
    end
    print(string.format("[静态懒姿态检查] PASS %d组精确原路径等价/%d空域证明/薄障碍/世界边/桥域回退/walk禁快路",count,proved))
    return true
end
return Q
