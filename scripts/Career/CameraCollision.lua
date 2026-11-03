-- 第三人称库的碰撞适配器：本城无Bullet刚体，使用真实可见三角形与同源地表。
-- 不手算/写相机位置，不改yaw；距离收缩/恢复仍全部由ThirdPersonCamera处理。
-- 侧视（米）：角色瞄准点 -> 相机射线；与地表或建筑的最近相交处留库内0.2m安全垫。
-- 忽略自己的人物/车辆、其他动态角色与Text3D；不把天桥下方误当最高桥面。
local Guard={}
local World=require("Career.WorldData")
-- A flat ground proof is not a walk-layer proof over a bridge. Exclude its
-- entire support domain before using FlatHeight; ramps/deck keep all 16+8
-- original samples with the actor's seed height, including below-deck rays.
local function flatRayHeight(city,x1,z1,x2,z2)
    if not city.FlatHeight then return nil end
    if city.space=="city" then
        for _,b in ipairs(World.Bridges) do
            if x1<=b.x+24 and x2>=b.x-24 and z1<=b.z+3 and z2>=b.z-65 then return nil end
        end
    end
    return city:FlatHeight(x1,z1,x2,z2)
end
---@param scene Scene
---@param city CareerCity
---@param actor CareerActor
function Guard.New(scene,city,actor)
    local octree=assert(scene:GetComponent("Octree"))
    local function dynamicFilter()
        -- Roots and ancestry are memoized for this ray only: streamed nodes,
        -- vehicle switches and dynamic ownership changes cannot leave stale keys.
        local known={}
        local function root(node) if node then known[node]=true end end
        root(actor.visuals.walkNode)
        local traffic=city.traffic
        if traffic then root(traffic.root);root(traffic.outer and traffic.outer.root) end
        root(city.contacts and city.contacts.root);root(city.crowd and city.crowd.root)
        root(city.deliveryPeople and city.deliveryPeople.root)
        for _,entry in pairs(actor.visuals.vehicles) do root(entry.node) end
        local function dynamic(node)
            if not node then return false end
            local cached=known[node]
            if cached~=nil then return cached end
            local result=dynamic(node.parent)
            known[node]=result
            return result
        end
        return dynamic
    end
    local physics={}
    ---@param ray Ray
    ---@param distance number
    function physics:RaycastSingle(ray,distance)
        local closest=distance
        local found=false
        -- 地表不依赖可见块/渲染背面；相机朝上时也不能钻入单面地板下方。
        local origin,direction=ray.origin,ray.direction
        local ex,ez=origin.x+direction.x*distance,origin.z+direction.z*distance
        local flat=flatRayHeight(city,math.min(origin.x,ex),math.min(origin.z,ez),math.max(origin.x,ex),math.max(origin.z,ez))
        local walkHeight=actor.walkHeight or 0
        for i=1,16 do
            local t=distance*i/16
            local x,y,z=origin.x+direction.x*t,origin.y+direction.y*t,origin.z+direction.z*t
            if y<(flat or city:WalkSurface(x,z,walkHeight))+.16 then
                local lo,hi=distance*(i-1)/16,t
                for _=1,8 do
                    local mid=(lo+hi)/2
                    local qx,qy,qz=origin.x+direction.x*mid,origin.y+direction.y*mid,origin.z+direction.z*mid
                    if qy<(flat or city:WalkSurface(qx,qz,walkHeight))+.16 then hi=mid else lo=mid end
                end
                closest,found=hi,true;break
            end
        end
        local dynamic=dynamicFilter()
        for _,hit in ipairs(octree:Raycast(ray,RAY_TRIANGLE,closest,DRAWABLE_GEOMETRY)) do
            if hit.drawable and hit.node and hit.distance>.08 and hit.distance<closest
                and hit.drawable:GetTypeName()~="Text3D" and not dynamic(hit.node) then
                closest,found=hit.distance,true
            end
        end
        return {body=found and true or nil,distance=closest}
    end
    -- ThirdPersonCamera只向scene请求PhysicsWorld，适配到本城真实Octree而不引入第二套物理。
    return {GetComponent=function(_,kind) if kind=="PhysicsWorld" then return physics end end} --[[@as Scene]]
end
-- 复用真实城市和库，验证抬头瞬间、桥上下层与室内地表；无人物传送/存档写入。
---@param session CareerSession
function Guard.Checks(session)
    assert(session.options.test and session.restoreTestStorage,"相机检查只允许隔离会话")
    local ThirdPersonCamera=require("urhox-libs.Camera.ThirdPersonCamera")
    local World=require("Career.WorldData")
    local city,actor=session.city,session.actor
    local oldSpace=city.space
    local target=Node()
    local fixture={visuals=actor.visuals,walkHeight=0} --[[@as CareerActor]]
    local camera=ThirdPersonCamera.Create(Guard.New(session.scene,city,fixture),{
        modes={normal={distance=7.8,offset=Vector3(0,1.35,0),fov=60}},
        collisionApproachSpeed=1000000})
    local bridge=World.Bridges[1]
    local count=0
    local began=os.clock()
    local ok,reason=pcall(function()
        for _,p in ipairs({{240,-44,0,"city"},{768,96,0,"city"},
            {bridge.x,bridge.z,bridge.y,"city"},{0,0,.085,"room"}}) do
            city.space=p[4]
            fixture.walkHeight=p[3]
            target.position=Vector3(p[1],p[3],p[2])
            for _,yaw in ipairs({0,90,180,270}) do
                camera:Update(1,target,yaw,20)
                -- 从完整相机距离一帧转到负pitch，不能先穿地再慢慢收回。
                camera:Update(1/60,target,yaw,-15)
                local pos=camera:GetNode().position
                assert(pos.y>city:WalkSurface(pos.x,pos.z,fixture.walkHeight)+.1,"相机首帧穿入地面/桥面")
                count=count+1
            end
        end
    end)
    city.space=oldSpace
    camera:GetNode():Dispose();target:Dispose()
    assert(ok,tostring(reason))
    print(string.format("[相机分层验收] PASS %d组负pitch首帧/四向/桥上桥下/室内，CPU %.6fs；真实墙体另作实拍",count,os.clock()-began))
    return true
end
-- Compares the fast ray with the original sampled path through the same
-- adapter, including dynamic exclusions/reparenting and an overlapping bridge.
-- Uses plain data only; Guard.Checks(session) remains the real-library check.
function Guard.CacheChecks()
    local floor,flatCalls,surfaceCalls=0,0,0
    local dynamicRoot={}
    local actor={visuals={walkNode={},vehicles={}},walkHeight=0}
    local city={space="room",traffic={root=dynamicRoot},
        FlatHeight=function() flatCalls=flatCalls+1;return floor end,
        WalkSurface=function() surfaceCalls=surfaceCalls+1;return floor end}
    local static={}
    local node={parent=dynamicRoot}
    local hits={}
    local drawable={GetTypeName=function() return "StaticModel" end}
    local octree={Raycast=function() return hits end}
    local scene={GetComponent=function() return octree end}
    local physics=Guard.New(scene --[[@as Scene]],city --[[@as CareerCity]],actor --[[@as CareerActor]]):GetComponent("PhysicsWorld")
    local function ray(x,z)
        return {origin={x=x,y=2,z=z},direction={x=0,y=-.5,z=1}} --[[@as Ray]]
    end
    local r=ray(0,0)
    local fast=physics:RaycastSingle(r,7)
    assert(fast.body and surfaceCalls==0 and flatCalls==1,"flat ray did not use proof")
    city.FlatHeight=function() return nil end
    local slow=physics:RaycastSingle(r,7)
    assert(fast.distance==slow.distance and fast.body==slow.body,"flat ray changed collision distance")
    hits={{drawable=drawable,node=node,distance=1},{drawable=drawable,node=static,distance=2}}
    assert(physics:RaycastSingle(r,7).distance==2,"dynamic body occludes static wall")
    node.parent=static
    assert(physics:RaycastSingle(r,7).distance==1,"ancestry cache survived reparenting across rays")
    hits={};city.space="city"
    city.FlatHeight=function() error("bridge domain must not use flat ground proof") end
    local bridge=World.Bridges[1]
    surfaceCalls=0
    assert(physics:RaycastSingle(ray(bridge.x,bridge.z),7).body and surfaceCalls>0,"bridge ray skipped original support sampling")
    print("[相机缓存检查] PASS 常高精确等价/动态过滤/换父节点失效/桥域回退原采样")
    return true
end
return Guard
