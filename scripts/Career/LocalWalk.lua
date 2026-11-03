-- 有限局部人行道绕行，不是全城寻路；原始 path 不变。
-- 俯视（米）：原线起点 -> 侧路点 -> 侧路点 -> 回原线
--                           [占用圆/车辆OBB]
-- 最多3路点、18候选、前视7m/侧移2.3m；至少1秒才重规划一次。
-- 每条线完整扫掠静态墙+动态圆/OBB；占用改变则取消，失败安全等候。
-- 不瞬移、不推人、不做无界A*或每帧搜索。
local Motion=require("Career.TrafficMotion")
local Walk={}
Walk.REPLAN_SECONDS=1
Walk.MAX_WAYPOINTS=3
Walk.MAX_AHEAD=7
Walk.MAX_SIDE=2.3

local function point(p,s,offset)
    local ux,uz=(p.path[3]-p.path[1])/p.length,(p.path[4]-p.path[2])/p.length
    return p.path[1]+ux*s-uz*offset,p.path[2]+uz*s+ux*offset
end
local function projection(p,x,z)
    local ux,uz=(p.path[3]-p.path[1])/p.length,(p.path[4]-p.path[2])/p.length
    return (x-p.path[1])*ux+(z-p.path[2])*uz,-(x-p.path[1])*uz+(z-p.path[2])*ux
end
local function circleFree(ax,az,bx,bz,x,z,r)
    local dx,dz=bx-ax,bz-az
    local length2=dx*dx+dz*dz
    local t=length2>1e-12 and math.max(0,math.min(1,((x-ax)*dx+(z-az)*dz)/length2)) or 0
    return (ax+dx*t-x)^2+(az+dz*t-z)^2>=r*r
end
local function carFree(ax,az,bx,bz,car,r)
    local a=math.rad(car.yaw)
    local cs,sn=math.cos(a),math.sin(a)
    local u,v=(ax-car.x)*cs-(az-car.z)*sn,(ax-car.x)*sn+(az-car.z)*cs
    local du,dv=(bx-ax)*cs-(bz-az)*sn,(bx-ax)*sn+(bz-az)*cs
    -- 方形外扩保守覆盖圆-OBB圆角；移动车辆额外留短距离前向包络，停车不加前伸。
    local forward=math.max(0,car.speed or 0)*.35
    local lo,hi=0,1
    for _,axis in ipairs({{u,du,-car.width/2-r-.08,car.width/2+r+.08},
        {v,dv,-car.length/2-r-.08,car.length/2+r+.08+forward}}) do
        if math.abs(axis[2])<1e-10 then
            if axis[1]<=axis[3] or axis[1]>=axis[4] then return true end
        else
            local ta,tb=(axis[3]-axis[1])/axis[2],(axis[4]-axis[1])/axis[2]
            lo=math.max(lo,math.min(ta,tb)); hi=math.min(hi,math.max(ta,tb))
        end
    end
    return not (lo<=hi and hi>=0 and lo<=1)
end

function Walk.Reset(p)
    p.localWalk={points={},index=1,cooldown=0,plans=0,attempts=0,completed=0,waiting=0}
end

-- Dynamic inputs are the existing Traffic.Blockers snapshots and both existing pools.
-- Never City:IsFree here: it includes this pedestrian's own circle.
function Walk.SegmentFree(city,p,ax,az,bx,bz,blockers,groups,cars)
    local s1,o1=projection(p,ax,az)
    local s2,o2=projection(p,bx,bz)
    local low,high=p.minOffset or -2.3,p.maxOffset or 2.3
    if math.min(s1,s2)<-.001 or math.max(s1,s2)>p.length+.001
        or math.min(o1,o2)<low-.001 or math.max(o1,o2)>high+.001 then return false end
    local y1=city:WalkSurface(ax,az,p.height or 0)
    local ym=city:WalkSurface((ax+bx)/2,(az+bz)/2,y1)
    local y2=city:WalkSurface(bx,bz,ym)
    if not city:StaticSegmentFree(ax,az,bx,bz,.36,"walk",y1) then return false end
    -- Side view: the swept feet/head envelope must intersect a blocker before
    -- its XZ circle/OBB can stop us; a player on the deck cannot block below.
    local low,high=math.min(y1,ym,y2),math.max(y1,ym,y2)+1.8
    for _,b in ipairs(blockers) do
        if not circleFree(ax,az,bx,bz,b.x,b.z,p.radius+b.radius+.45) then
            local b1,b2=Motion.BlockerInterval(city,b)
            if Motion.VerticalOverlap(low,high,b1,b2) then return false end
        end
    end
    for _,group in ipairs(groups) do
        for _,other in ipairs(group) do
            if other~=p and not circleFree(ax,az,bx,bz,other.x,other.z,.9) then
                local b1,b2=Motion.PersonInterval(city,other)
                if Motion.VerticalOverlap(low,high,b1,b2) then return false end
            end
        end
    end
    for _,group in ipairs(cars) do
        for _,car in ipairs(group) do
            if not carFree(ax,az,bx,bz,car,.5) then
                local b1,b2=Motion.VehicleInterval(city,car)
                if Motion.VerticalOverlap(low,high,b1,b2) then return false end
            end
        end
    end
    return true
end

local function plan(city,p,blockers,groups,cars)
    local state=p.localWalk
    state.attempts=state.attempts+1
    local s=math.max(0,math.min(p.length,(projection(p,p.x,p.z))))
    -- 同步规划期间占用不变。首条侧移边只依赖offset，与ahead无关；false也复用。
    local firstEdges={}
    local firstPoints={}
    for _,ahead in ipairs({2.5,4.5,Walk.MAX_AHEAD}) do
        local finish=math.max(0,math.min(p.length,s+p.direction*ahead))
        if math.abs(finish-s)>1 then
            for _,amount in ipairs({1.1,1.7,Walk.MAX_SIDE}) do
                for _,side in ipairs({1,-1}) do
                    local offset=amount*side
                    if offset>=(p.minOffset or -2.3) and offset<=(p.maxOffset or 2.3) then
                        if firstEdges[offset]==nil then
                            local ax,az=point(p,s,offset)
                            firstPoints[offset]={x=ax,z=az}
                            firstEdges[offset]=Walk.SegmentFree(city,p,p.x,p.z,ax,az,blockers,groups,cars)
                        end
                        if firstEdges[offset] then
                            local first=firstPoints[offset]
                            local ax,az=first.x,first.z
                            local bx,bz=point(p,finish,offset)
                            if Walk.SegmentFree(city,p,ax,az,bx,bz,blockers,groups,cars) then
                                local cx,cz=point(p,finish,0)
                                if Walk.SegmentFree(city,p,bx,bz,cx,cz,blockers,groups,cars) then
                                    state.points={{x=ax,z=az},{x=bx,z=bz},{x=cx,z=cz}}
                                    state.index=1; state.plans=state.plans+1
                                    return true
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return false
end

function Walk.Advance(city,p,dt,blockers,groups,cars)
    if not p.localWalk then Walk.Reset(p) end
    local state=p.localWalk
    state.cooldown=math.max(0,state.cooldown-dt)
    local distance=p.speed*math.min(dt,.25)
    local moved=0
    -- SegmentFree 对整段做连续扫掠（静态墙+动态圆/OBB），把一段路拆成多个
    -- 10cm 子段只是重复同一次扫掠判定，不提高精度；一帧一次即可。
    local count=1
    for _=1,count do
        local target=state.points[state.index]
        local tx,tz
        if target then tx,tz=target.x,target.z
        else
            local nextS=math.max(0,math.min(p.length,p.s+p.direction*distance/count))
            tx,tz=point(p,nextS,0)
        end
        local dx,dz=tx-p.x,tz-p.z
        local remaining=math.sqrt(dx*dx+dz*dz)
        local step=math.min(distance/count,remaining)
        if remaining<1e-7 then
            if target then
                state.index=state.index+1
                if state.index>#state.points then state.points={}; state.index=1; state.completed=state.completed+1 end
            end
        else
            local nx,nz=p.x+dx/remaining*step,p.z+dz/remaining*step
            if Walk.SegmentFree(city,p,p.x,p.z,nx,nz,blockers,groups,cars) then
                p.x,p.z=nx,nz
                p.s=math.max(0,math.min(p.length,(projection(p,nx,nz))))
                p.yaw=math.deg(math.atan(dx,dz))
                moved=moved+step
                if target and step>=remaining-1e-7 then
                    state.index=state.index+1
                    if state.index>#state.points then state.points={}; state.index=1; state.completed=state.completed+1 end
                end
            else
                state.points={}; state.index=1
                state.waiting=state.waiting+dt
                if state.cooldown<=0 then
                    state.cooldown=Walk.REPLAN_SECONDS
                    plan(city,p,blockers,groups,cars)
                end
                break
            end
        end
    end
    return moved
end
-- 不替换生产检测函数；用同一静态扫掠接口计数首边失败与成功重试。
function Walk.CacheChecks()
    local calls=0
    local city={WalkSurface=function() return 0 end,
        StaticSegmentFree=function() calls=calls+1;return false end}
    local p={path={0,0,0,20},length=20,x=0,z=5,s=5,direction=1,radius=.32,height=0}
    Walk.Reset(p)
    assert(not plan(city,p,{},{},{}) and calls==6,"失败首边仍按三个前视距离重复检查")
    assert(not plan(city,p,{},{},{}) and calls==12,"绕行通行结论跨规划缓存")
    city.StaticSegmentFree=function() calls=calls+1;return true end
    assert(plan(city,p,{},{},{}) and calls==15 and #p.localWalk.points==3,"首个合法绕行改变或跨规划沿用false")
    ---@type {x:number,z:number}[]
    local points=p.localWalk.points
    assert(points[1].x==-1.1 and points[1].z==5 and points[2].x==-1.1 and points[2].z==7.5
        and points[3].x==0 and points[3].z==7.5,"原候选顺序或路点改变")
    print("[局部绕行缓存检查] PASS 六首边/false复用/跨规划失效/首个合法候选与三路点不变")
    return true
end
return Walk
