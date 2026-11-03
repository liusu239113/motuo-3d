-- 近场增量人群：基于3D角色脚手架的Node/AnimatedModel所有权；不接管主角/交通。
-- 写实便服41骨 + 共享官动相位表，固定24槽上限；旧8+4人保持独立。
local World=require("Career.WorldData")
local Routes=require("Career.TrafficRoutes")
local C=require("Career.FootprintCollision")
local TrafficMotion=require("Career.TrafficMotion")
local Pedestrians=require("Career.Pedestrians")
local Motion=require("Career.Locomotion")
local Environment=require("Career.CityEnvironment")
---@class CareerCrowdFrame
---@field position Vector3
---@field rotations table<string,Quaternion>
---@class CareerCrowdPoseBank
---@field walk CareerCrowdFrame[]
---@field idle CareerCrowdFrame[]
---@field names string[]
---@field rotation Quaternion
---@field scale number
---@field resource Model
---@field material Material
---@class CareerCrowdPerson
---@field bank CareerCrowdPoseBank
---@field node Node
---@field mesh Node
---@field model AnimatedModel
---@field bones table<string,Node>
---@field x number
---@field z number
---@field radius number
---@field height number
---@field yaw number
---@field s number
---@field speed number
---@field direction number
---@field phase number
---@field idle number
---@field blend number
---@field moved number
---@field poseElapsed number
---@field active boolean
---@field route? table
---@field pending boolean
---@field localWalk table
local CrowdPersonType={}
---@class CareerCrowdBind
---@field position Vector3
---@field rotation Quaternion
---@field scale Vector3
local CrowdBindType={}
---@class CareerCrowd
---@field city CareerCity
---@field root Node
---@field pool CareerCrowdPerson[]
---@field people CareerCrowdPerson[]
---@field routes table[]
---@field obstacles table[]
---@field shapes table[]
---@field clips table
---@field reference table<string,CareerCrowdBind>
---@field disposed boolean
---@field enabled boolean
local Crowd={}
Crowd.__index=Crowd
Crowd.BUDGET,Crowd.HARD_LIMIT=20,24
Crowd.RANGE,Crowd.RECYCLE,Crowd.SPAWN_MIN=92,125,24
Crowd.MAX_POSES,Crowd.MAX_CREATES,Crowd.MAX_MOVES=6,2,12
Crowd.Resources,Crowd.ResourceTypes={},{}
for _,path in ipairs(Motion.Resources) do
    Crowd.Resources[#Crowd.Resources+1]=path;Crowd.ResourceTypes[path]=Motion.ResourceTypes[path]
end
for _,path in ipairs(Pedestrians.Resources) do
    Crowd.Resources[#Crowd.Resources+1]=path;Crowd.ResourceTypes[path]=Pedestrians.ResourceTypes[path]
end
local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
local function d2(x,z,p) return (x-p.x)^2+(z-p.z)^2 end
local function wrap(yaw) return (yaw+180)%360-180 end
local function point(route,s,offset)
    local ux,uz=(route.path[3]-route.path[1])/route.length,(route.path[4]-route.path[2])/route.length
    return route.path[1]+ux*s-uz*(offset or 0),route.path[2]+uz*s+ux*(offset or 0)
end
local Rig=require("Career.Rig")
---@type table<number,CareerCrowdPoseBank>
local poseBanks={}
-- 两套便服共享离线相位表；运行中只插值骨骼，不逐人重复蒙皮鞋底与IK。
---@return CareerCrowdPoseBank
local function poseBank(index,parent)
    if poseBanks[index] then return poseBanks[index] end
    local rig=Rig.New(parent,Pedestrians.Specs[index])
    local motion=rig:EnableOfficialLocomotion()
    ---@type CareerCrowdPoseBank
    local bank={walk={},idle={},names=rig.boneNames,rotation=Quaternion(rig.mesh.rotation),
        scale=rig.heightScale,resource=rig.model.model,material=rig.material:Clone()}
    for _,mode in ipairs({"idle","walk"}) do
        local count=mode=="walk" and 16 or 8
        for i=1,count do
            motion:PoseNormalized((i-1)/count,mode=="walk" and Motion.WalkSpeed or 0)
            local frame={position=rig.mesh.position,rotations={}}
            for _,name in ipairs(bank.names) do
                frame.rotations[name]=Quaternion(rig.model:GetSkeleton():GetBone(name).node.rotation)
            end
            bank[mode][i]=frame
        end
    end
    rig:Dispose();poseBanks[index]=bank
    return bank
end
---@param frames CareerCrowdFrame[]
---@param phase number
---@return CareerCrowdFrame,CareerCrowdFrame,number
local function bankFrames(frames,phase)
    local t=(phase%1)*#frames
    local index=math.floor(t)+1
    return assert(frames[index]),assert(frames[index%#frames+1]),t-math.floor(t)
end

-- 俯视，米；半径.30仅代表可见成年躯干，不将玩家/车辆包成整圈大空气墙。
-- 建筑 |<--- 人行道4/6m --->|路缘|车道|；路径止于交叉道路外缘+.8m。
-- [障碍]前置局部绕行最多两折点、侧移<=1m；每条边连续StaticSegmentFree。
-- 横穿仅已有老街斑马线：等相同行进轴绿灯+整条清空窗口+车辆扫掠预测。
-- 擦边/无法绕过/当前段被占据=>原地等待；不投影回线、不穿楼/瞬移绕障碍。
---@param city CareerCity
---@param parent? Node
---@param options? table
---@return CareerCrowd
function Crowd.New(city,parent,options)
    local self=setmetatable({},Crowd)
    self:Init(city,parent or city.root,options or {}); return self
end
function Crowd:Init(city,parent,options)
    self.city=city
    self.root=parent:CreateChild("附近有界成年行人池")
    self.budget=math.max(0,math.min(Crowd.HARD_LIMIT,math.floor(options.budget or Crowd.BUDGET)))
    self.pool,self.people,self.routes,self.obstacles,self.shapes={},{},{},{},{}
    self.disposed,self.enabled,self.primed=false,false,false
    self.elapsed,self.scanElapsed,self.moveCursor,self.poseCursor=0,1,1,1
    self.created,self.reused,self.retired,self.poseCount,self.moveCount,self.waitCount=0,0,0,0,0,0
    self.clips={walk={length=1.2},idle={length=3.6}}
    self.roads={}
    for _,road in ipairs(World.Roads) do self.roads[#self.roads+1]=road end
    for _,road in ipairs(World.ExpansionRoads) do self.roads[#self.roads+1]=road end
    self.spawnElapsed,self.spawnCursor=0,0
    print(string.format("[街道人群] 写实便服41骨/共享官动相位表；增量池%d/硬上限%d",self.budget,Crowd.HARD_LIMIT))
end
function Crowd:Create()
    if #self.pool>=self.budget then return nil end
    local bank=poseBank(#self.pool%#Pedestrians.Specs+1,self.root)
    local node=self.root:CreateChild("写实便服成人"..(#self.pool+1))
    local mesh=node:CreateChild("便服原骨架")
    local model=mesh:CreateComponent("AnimatedModel")
    model.model=bank.resource;model:SetMaterial(bank.material)
    model.castShadows=false;model.drawDistance=Crowd.RANGE+5;model.updateInvisible=false
    mesh:SetScale(bank.scale);mesh.rotation=bank.rotation
    local bones={}
    for _,name in ipairs(bank.names) do
        local bone=model:GetSkeleton():GetBone(name)
        if bone and bone.node then bones[name]=bone.node;bone.animated=false end
    end
    ---@type CareerCrowdPerson
    local p={bank=bank,node=node,mesh=mesh,model=model,bones=bones,x=0,z=0,radius=.30,height=0,yaw=0,s=0,speed=1.13+(#self.pool%4)*.075,
        direction=1,phase=(#self.pool*.381)%1,idle=0,blend=0,moved=0,poseElapsed=0,active=false,pending=false,
        localWalk={points={},index=1,cooldown=0}}
    p.bank=bank
    node:SetEnabledRecursive(false)
    self.pool[#self.pool+1]=p; self.created=self.created+1
    return p
end
---@param p CareerCrowdPerson
function Crowd:Pose(p)
    local bank=p.bank
    local wa,wb,wt=bankFrames(bank.walk,p.phase)
    local ia,ib,it=bankFrames(bank.idle,p.idle/self.clips.idle.length)
    for _,name in ipairs(bank.names) do
        local bone=p.bones[name]
        if bone then
            local walk=wa.rotations[name]:Slerp(wb.rotations[name],wt)
            local idle=ia.rotations[name]:Slerp(ib.rotations[name],it)
            bone.rotation=idle:Slerp(walk,p.blend)
        end
    end
    ---@type Vector3
    local wp=wa.position+(wb.position-wa.position)*wt
    ---@type Vector3
    local ip=ia.position+(ib.position-ia.position)*it
    p.mesh.position=ip+(wp-ip)*p.blend
    p.poseElapsed=0; self.poseCount=self.poseCount+1
end
-- 相机缺失时不补人；保守的包围球必须完整离开视锥，不能在玩家转头时贴脸刷出。
function Crowd:Hidden(x,z,actor,camera)
    if d2(x,z,actor)<Crowd.SPAWN_MIN^2 or not camera then return false end
    local ground=self.city:WalkSurface(x,z,0)
    return camera.frustum:IsInside(Sphere(Vector3(x,ground+1, z),2.2))==OUTSIDE
end
function Crowd:AddRoute(path,id,crossing)
    if #self.routes>=48 then return end
    local length=math.sqrt((path[3]-path[1])^2+(path[4]-path[2])^2)
    if length>=8 then self.routes[#self.routes+1]={path=path,length=length,id=id,crossing=crossing} end
end
function Crowd:Scan(actor)
    self.routeX,self.routeZ=actor.x,actor.z
    self.routes={}
    -- 海岸路线来自环境真源矩形，不复制另一套岸线坐标；只走木板中心/沙滩干地。
    local board,pier=Environment.Boardwalk,Environment.Pier
    if Environment.Contains(actor.x,actor.z) then
        local bx=(board.x1+board.x2)/2
        local pz=(pier.z1+pier.z2)/2
        self:AddRoute({bx,board.z1+4,bx,board.z2-4},"coast_boardwalk")
        self:AddRoute({pier.x1+4,pz,pier.x2-4,pz},"coast_pier")
        self:AddRoute({board.x2+7,board.z1+6,board.x2+7,board.z2-8},"coast_sand")
    end
    -- 固定已有8条完全已审查的老街人行道，增量槽位可在同一道路两侧分散。
    for i,path in ipairs(Pedestrians.Paths) do
        local mx,mz=(path[1]+path[3])*.5,(path[2]+path[4])*.5
        if d2(mx,mz,actor)<150^2 then self:AddRoute(path,"old"..i) end
    end
    for i,j in ipairs(Routes.Junctions) do
        if d2(j.x,j.z,actor)<100^2 then
            for _,side in ipairs({-1,1}) do
                self:AddRoute({j.x+side*9,j.z-28,j.x+side*9,j.z+28},"cross"..i..":"..side,{axis="ns",enter=19.6,exit=36.4})
                self:AddRoute({j.x-28,j.z+side*9,j.x+28,j.z+side*9},"crossEW"..i..":"..side,{axis="ew",enter=19.6,exit=36.4})
            end
        end
    end
    local roads=self.roads
    local candidates={}
    for _,r in ipairs(roads) do
        local ns=r.x1==r.x2
        local cross=ns and r.x1 or r.z1
        local along=ns and actor.z or actor.x
        local start=math.max(ns and math.min(r.z1,r.z2) or math.min(r.x1,r.x2),along-68)
        local finish=math.min(ns and math.max(r.z1,r.z2) or math.max(r.x1,r.x2),along+68)
        local across=ns and actor.x or actor.z
        if math.abs(across-cross)<75 and finish-start>8 and r.kind~="alley" then
            candidates[#candidates+1]={road=r,ns=ns,cross=cross,start=start,finish=finish,distance=math.abs(across-cross)}
        end
    end
    table.sort(candidates,function(a,b) return a.distance<b.distance end)
    for index=1,math.min(12,#candidates) do
        local candidate=candidates[index]
        ---@type CareerWorldRoad
        local r=candidate.road
        local ns=candidate.ns
        for _,side in ipairs({-1,1}) do
            local cross=candidate.cross+side*(r.width/2+(r.sidewalk or 4)*.53)
            local cuts={{candidate.start,candidate.finish}}
            for _,other in ipairs(roads) do
                local perpendicular=ns and other.z1==other.z2 or not ns and other.x1==other.x2
                local low=ns and math.min(other.x1,other.x2) or math.min(other.z1,other.z2)
                local high=ns and math.max(other.x1,other.x2) or math.max(other.z1,other.z2)
                if perpendicular and cross>=low and cross<=high then
                    local at=ns and other.z1 or other.x1
                    local half=other.width/2+.8
                    local nextCuts={}
                    for _,segment in ipairs(cuts) do
                        if at+half<=segment[1] or at-half>=segment[2] then nextCuts[#nextCuts+1]=segment
                        else
                            if at-half-segment[1]>=8 then nextCuts[#nextCuts+1]={segment[1],at-half} end
                            if segment[2]-at-half>=8 then nextCuts[#nextCuts+1]={at+half,segment[2]} end
                        end
                    end
                    cuts=nextCuts
                end
            end
            for n,segment in ipairs(cuts) do
                local a,b=segment[1]+.5,segment[2]-.5
                local path=ns and {cross,a,cross,b} or {a,cross,b,cross}
                self:AddRoute(path,r.id..":"..side..":"..n)
            end
        end
    end
end
-- Actor parking is independent of the moving traffic tables. Retain only one
-- exact posed shell per owned vehicle; teleport/restore/switch/yaw edits all
-- invalidate through Motion.Shape's full numeric pose + source-identity key.
function Crowd:VehicleShape(id,x,z,yaw)
    self.vehicleShapes=self.vehicleShapes or {}
    local car=self.vehicleShapes[id]
    if not car then car={vehicleId=id};self.vehicleShapes[id]=car end
    car.x,car.z,car.yaw=x,z,yaw
    return TrafficMotion.Shape(car),car
end
-- Moving traffic freezes source/pose/height inputs, never a mutable car pose.
-- In XZ, rotate the WHOLE local source AABB (including mirrors/rider OBB):
--       [local parts] --yaw--> [conservative bounds] <-- relative walker sweep
-- Only rejection uses these bounds. A hit still needs the exact posed shell
-- and its original AABB test before any support query or narrow collision.
local function snapshotBounds(source,x,z,yaw)
    local angle=math.rad(yaw or 0)
    local cs,sn=math.cos(angle),math.sin(angle)
    local ax,bx=source.x1*cs,source.x2*cs
    local az,bz=source.z1*sn,source.z2*sn
    local cx,dx=-source.x1*sn,-source.x2*sn
    local cz,dz=source.z1*cs,source.z2*cs
    -- Extremising each linear term encloses every polygon vertex. For circle
    -- parts |cos|+|sin| >= 1, so the rotated enclosing square also encloses the
    -- unchanged radius. Outward pad dwarfs double rounding at project scales
    -- (including the tiny libm norm error at axis-aligned angles).
    local pad=1e-9*(1+math.abs(x)+math.abs(z)+(source.reach or 0))
    return {x1=x+math.min(ax,bx)+math.min(az,bz)-pad,
        x2=x+math.max(ax,bx)+math.max(az,bz)+pad,
        z1=z+math.min(cx,dx)+math.min(cz,dz)-pad,
        z2=z+math.max(cx,dx)+math.max(cz,dz)+pad}
end
local function snapshotShape(entry)
    if entry.shape then return entry.shape end -- explicit test/fixture shapes too
    if entry.person then
        local p=entry.person
        entry.shape=C.Circle(p.x,p.z,p.radius)
    else
        entry.shape=C.Pose(entry.vehicleSource,entry.vehicle.x,entry.vehicle.z,entry.vehicleYaw)
    end
    return entry.shape
end
local function snapshotPose(car)
    return {x=car.x,z=car.z,vehicleId=car.vehicleId,id=car.id,bodyHeight=car.bodyHeight,riding=car.riding}
end
-- 车轮/后视镜/箱体用环境代理同一可见足迹；车辆与停车姿态复用同源缓存。
function Crowd:Snapshot(actor)
    self.shapes={}
    local function add(shape,y1,y2,vx,vz,car,vehicle,bounds)
        self.shapes[#self.shapes+1]={shape=shape,y1=y1,y2=y2,vx=vx or 0,vz=vz or 0,car=car,vehicle=vehicle,bounds=bounds}
    end
    local traffic=self.city.traffic
    for _,group in ipairs({traffic and traffic.cars or {},traffic and traffic.outer and traffic.outer.cars or {}}) do
        for _,car in ipairs(group) do
            if d2(car.x,car.z,actor)<150^2 then
                local angle=math.rad(car.yaw)
                -- Freeze collision source and numeric state: later traffic movement
                -- cannot mutate this frame's shell, height query, or relative sweep.
                local source=TrafficMotion.Source(car)
                local pose=snapshotPose(car)
                -- Reuse only a fully valid immutable shell, with exactly the
                -- same numeric/source/dimension key as TrafficMotion.Shape.
                local cached=car.shapeX==car.x and car.shapeZ==car.z and car.shapeYaw==car.yaw
                    and car.shapeSource==source and car.shapeWidth==car.width and car.shapeLength==car.length and car.shell
                local bounds=not cached and snapshotBounds(source,pose.x,pose.z,car.yaw) or nil
                add(cached or nil,nil,nil,math.sin(angle)*(car.speed or 0),math.cos(angle)*(car.speed or 0),true,pose,bounds)
                local entry=self.shapes[#self.shapes]
                entry.vehicleSource,entry.vehicleYaw=source,car.yaw
            end
        end
    end
    local function park(id,x,z,yaw)
        local shape,car=self:VehicleShape(id,x,z,yaw)
        add(shape,nil,nil,0,0,false,snapshotPose(car))
    end
    if actor.ParkedShapes then
        if not actor.mounted then park(actor.vehicleId,actor.bikeX,actor.bikeZ,actor.bikeYaw) end
        for id,p in pairs(actor.parking or {}) do if id~=actor.vehicleId then park(id,p.x,p.z,p.yaw) end end
    end
    if actor.mounted then
        local shape,car=self:VehicleShape(actor.vehicleId,actor.x,actor.z,actor.yaw)
        add(shape,nil,nil,0,0,false,snapshotPose(car))
    else
        local y1=self.city:WalkSurface(actor.x,actor.z,actor.walkHeight or 0)
        add(C.Circle(actor.x,actor.z,.32),y1,y1+1.8)
    end
    for _,group in ipairs({traffic and traffic.pedestrians and traffic.pedestrians.people or {},traffic and traffic.outer and traffic.outer.people or {},self.city.deliveryPeople and self.city.deliveryPeople.people or {}}) do
        for _,p in ipairs(group) do
            if p.active~=false and p.inUse~=false and finite(p.x) and finite(p.z) and d2(p.x,p.z,actor)<125^2 then
                -- 冻结原高度选择语义和圆的精确四界；宽相命中前不建圆、不查缺省地面。
                -- 只延迟准备工作，不缓存通行结论，也不持有活人物作为求值来源。
                local person={x=p.x,z=p.z,radius=p.radius or .30,height=p.height or p.y}
                local y=person.height
                local low=type(y)=="number" and y or nil
                local bounds={x1=person.x-person.radius,x2=person.x+person.radius,
                    z1=person.z-person.radius,z2=person.z+person.radius}
                add(nil,low,low and low+1.8 or nil,0,0,false,nil,bounds)
                self.shapes[#self.shapes].person=person
            end
        end
    end
end
-- One synchronous Move has immutable terrain but may test several local edges.
-- Exact numeric keys include the incoming support seed: same XZ below a bridge
-- is NOT the same query as on its deck. Never retain this across moves/frames.
local function walkSurface(city,x,z,height,samples)
    if not samples then return city:WalkSurface(x,z,height) end
    local zs=samples[x]
    if not zs then zs={};samples[x]=zs end
    local hs=zs[z]
    if not hs then hs={};zs[z]=hs end
    local seed=height==nil and "nil" or height
    local y=hs[seed]
    if y==nil then y=city:WalkSurface(x,z,height);hs[seed]=y end
    return y
end
---@param p CareerCrowdPerson
function Crowd:SegmentFree(p,ax,az,bx,bz,predict,samples)
    if not self.city:StaticSegmentFree(ax,az,bx,bz,p.radius,"walk",p.height) then return false end
    local mx,mz=(ax+bx)*.5,(az+bz)*.5
    local y1=walkSurface(self.city,ax,az,p.height,samples)
    local ym=walkSurface(self.city,mx,mz,y1,samples)
    local y2=walkSurface(self.city,bx,bz,ym,samples)
    if math.abs(y2-y1)>.32+math.sqrt((bx-ax)^2+(bz-az)^2)*.18 then return false end
    local shape=false
    local sx1,sx2,sz1,sz2=ax-p.radius,ax+p.radius,az-p.radius,az+p.radius
    local dx,dz=bx-ax,bz-az
    -- Swept support envelope includes the middle of a ramp, not absolute Y tiers.
    local low,high=math.min(y1,ym,y2),math.max(y1,ym,y2)+1.8
    local function mayTouch(other,rx,rz,pad)
        return math.max(sx2,sx2+rx)+pad>=other.x1
            and math.min(sx1,sx1+rx)-pad<=other.x2
            and math.max(sz2,sz2+rz)+pad>=other.z1
            and math.min(sz1,sz1+rz)-pad<=other.z2
    end
    for _,entry in ipairs(self.shapes) do
        local time=predict or .25
        local rx,rz=dx-entry.vx*time,dz-entry.vz*time
        -- Relative motion includes approaching vehicles, even on zero-length
        -- spawn probes. A conservative hit is NOT yet an exact-AABB hit.
        local candidate=entry.shape or entry.bounds
        if mayTouch(candidate,rx,rz,.025) then
            local other=snapshotShape(entry)
            if other==candidate or mayTouch(other,rx,rz,.025) then
                if entry.y1==nil then
                    if entry.vehicle then
                        entry.y1,entry.y2=TrafficMotion.VehicleInterval(self.city,entry.vehicle)
                    elseif entry.person then
                        entry.y1,entry.y2=TrafficMotion.PersonInterval(self.city,entry.person)
                    end
                end
                local ey=entry.y1 or self.city:Surface((other.x1+other.x2)/2,(other.z1+other.z2)/2)
                if TrafficMotion.VerticalOverlap(low,high,ey,entry.y2 or ey+1.8) then
                    if not shape then shape=C.Circle(ax,az,p.radius) end
                    if not C.Free(shape,other,.025) or C.Sweep(shape,other,rx,rz,.025) then return false end
                end
            end
        end
    end
    local x1,x2=math.min(ax,bx)-p.radius-.04,math.max(ax,bx)+p.radius+.04
    local z1,z2=math.min(az,bz)-p.radius-.04,math.max(az,bz)+p.radius+.04
    for _,other in ipairs(self.people) do
        if other~=p and other.active and other.x+other.radius>=x1 and other.x-other.radius<=x2
            and other.z+other.radius>=z1 and other.z-other.radius<=z2 then
            local oy1,oy2=TrafficMotion.PersonInterval(self.city,other)
            if TrafficMotion.VerticalOverlap(low,high,oy1,oy2) then
                if not shape then shape=C.Circle(ax,az,p.radius) end
                local body=C.Circle(other.x,other.z,other.radius)
                if not C.Free(shape,body,.04) or C.Sweep(shape,body,dx,dz,.04) then return false end
            end
        end
    end
    return true
end
function Crowd:CanCross(p,samples)
    local route=p.route
    if not route or not route.crossing then return true end
    local traffic=self.city.traffic
    if not traffic or not traffic.active or not finite(traffic.time) then return false end
    local axis=route.crossing.axis
    local crossing=route.crossing
    local required=(crossing.exit-crossing.enter)/p.speed+1.1
    if Routes.Signal(traffic.time,axis)~="green" or Routes.Signal(traffic.time+required,axis)~="green" then return false end
    local ax,az=point(route,p.direction==1 and crossing.enter or crossing.exit)
    local bx,bz=point(route,p.direction==1 and crossing.exit or crossing.enter)
    return self:SegmentFree(p,ax,az,bx,bz,required,samples)
end
function Crowd:Acquire(actor,camera,prime)
    if #self.people>=self.budget or #self.routes==0 then return false end
    local p
    for _,slot in ipairs(self.pool) do if not slot.active then p=slot; break end end
    if not p then p=self:Create() end
    if not p then return false end
    for attempt=1,math.min(prime and 64 or 12,#self.routes*3) do
        self.spawnCursor=self.spawnCursor+1
        local candidate=self.spawnCursor
        local route=self.routes[(candidate+self.created*7+self.reused*3-1)%#self.routes+1]
        do
            local s=route.length*((candidate*.381966)%1)
            if route.crossing then s=attempt%2==0 and 4 or route.length-4 end
            local x,z=point(route,s)
            p.height=self.city:WalkSurface(x,z,0)
            local hidden=prime and d2(x,z,actor)>=9^2 or self:Hidden(x,z,actor,camera)
            if d2(x,z,actor)<=Crowd.RANGE^2 and hidden and self:SegmentFree(p,x,z,x,z) then
                p.x,p.z,p.s,p.route=x,z,s,route
                p.direction=route.crossing and (s<route.length/2 and 1 or -1) or (attempt+#self.pool)%2==0 and 1 or -1
                ---@type number[]
                local path=route.path
                p.yaw=math.deg(math.atan((path[3]-path[1])*p.direction,(path[4]-path[2])*p.direction))
                p.active,p.pending,p.moved=true,false,0
                p.localWalk={points={},index=1,cooldown=0}
                p.node.position=Vector3(x,p.height,z); p.node.rotation=Quaternion(0,p.yaw,0)
                p.node:SetEnabledRecursive(true); self:Pose(p)
                self.people[#self.people+1]=p; self.reused=self.reused+1
                return true
            end
        end
    end
    return false
end
-- 只能在loading遮罩撤下前调用一次；不是运行中补刷可见人物的后门。
function Crowd:Prime(actor)
    if self.primed or self.disposed or self.elapsed>0 or self.city.space~="city" then return false end
    self.primed=true
    -- 两套官动相位表均在加载遮罩内完成；不能等首次走出老街才同步建Rig/读蒙皮。
    for index=1,#Pedestrians.Specs do poseBank(index,self.root) end
    self:Snapshot(actor); self:Scan(actor)
    for _=1,self.budget do if not self:Acquire(actor,nil,true) then break end end
    return #self.people>0
end
function Crowd:Retire(index)
    local p=self.people[index]
    p.active=false; p.node:SetEnabledRecursive(false); p.route=nil
    table.remove(self.people,index); self.retired=self.retired+1
end
function Crowd:Move(p,dt)
    local route=p.route
    if not route then return end
    local samples={}
    local state=p.localWalk
    state.cooldown=math.max(0,state.cooldown-dt)
    local crossing=route.crossing
    local entry=crossing and (p.direction==1 and crossing.enter or crossing.exit) or 0
    local distance=p.speed*dt
    local target=state.points[state.index]
    local desired=math.max(0,math.min(route.length,p.s+p.direction*distance))
    if crossing and (p.direction==1 and p.s<=entry+.001 and desired>entry or p.direction==-1 and p.s>=entry-.001 and desired<entry) then
        if not self:CanCross(p,samples) then desired=entry; p.pending=true else p.pending=false end
    end
    local tx,tz=point(route,desired)
    if target then tx,tz=target.x,target.z end
    local dx,dz=tx-p.x,tz-p.z
    local remaining=math.sqrt(dx*dx+dz*dz)
    if remaining<.001 then
        if p.pending then self.waitCount=self.waitCount+1; return end
        if target then state.index=state.index+1
        else
            p.direction=-p.direction; p.pending=false
            -- 每次到端点尝试接相同坐标的斑马线；不跳跃到另一条道路。
            if not route.crossing then
                for _,nextRoute in ipairs(self.routes) do
                    if nextRoute.crossing then
                        for _,s in ipairs({0,nextRoute.length}) do
                            local x,z=point(nextRoute,s)
                            if (x-p.x)^2+(z-p.z)^2<.03^2 then p.route,p.s,p.direction,p.pending=nextRoute,s,s==0 and 1 or -1,true; break end
                        end
                    end
                end
            end
        end
        return
    end
    local step=math.min(distance,remaining)
    local nx,nz=p.x+dx/remaining*step,p.z+dz/remaining*step
    if self:SegmentFree(p,p.x,p.z,nx,nz,nil,samples) then
        p.x,p.z=nx,nz
        local ux,uz=(route.path[3]-route.path[1])/route.length,(route.path[4]-route.path[2])/route.length
        p.s=math.max(0,math.min(route.length,(nx-route.path[1])*ux+(nz-route.path[2])*uz))
        local yaw=math.deg(math.atan(dx,dz))
        p.yaw=wrap(p.yaw+math.max(-150*dt,math.min(150*dt,wrap(yaw-p.yaw))))
        p.height=walkSurface(self.city,nx,nz,p.height,samples)
        p.node.position=Vector3(nx,p.height,nz); p.node.rotation=Quaternion(0,p.yaw,0)
        p.moved=p.moved+step
        p.phase=(p.phase+step/(Motion.WalkSpeed*self.clips.walk.length))%1
        self.moveCount=self.moveCount+1
        if target and step>=remaining-.001 then state.index=state.index+1 end
    else
        self.waitCount=self.waitCount+1
        state.points={}; state.index=1
        -- 前方静态/行人局部绕行仅4候选，最多两折点，留在人行道窄走廊。
        if state.cooldown<=0 and not route.crossing then
            state.cooldown=1.5
            local finish=math.max(0,math.min(route.length,p.s+p.direction*3))
            for _,offset in ipairs({.7,-.7,1,-1}) do
                local ax,az=point(route,p.s,offset)
                local bx,bz=point(route,finish,offset)
                local cx,cz=point(route,finish)
                if self:SegmentFree(p,p.x,p.z,ax,az,nil,samples) and self:SegmentFree(p,ax,az,bx,bz,nil,samples) and self:SegmentFree(p,bx,bz,cx,cz,nil,samples) then
                    state.points={{x=ax,z=az},{x=bx,z=bz},{x=cx,z=cz}}; break
                end
            end
        end
    end
end
function Crowd:Update(dt,actor,enabled,camera)
    if self.disposed then return end
    self.enabled=enabled~=false and self.city.space=="city" and (not self.city.traffic or self.city.traffic.active)
    if self.city.space~="city" then
        if self.root.enabledSelf then self.root:SetEnabledRecursive(false) end
        return
    end
    if not self.root.enabledSelf then self.root:SetEnabledRecursive(true) end
    -- City切回室外会递归启用整棵树；退休槽不属于活动people，必须重新隐藏。
    for _,p in ipairs(self.pool) do
        if not p.active and p.node.enabledSelf then p.node:SetEnabledRecursive(false) end
    end
    if not self.enabled or not finite(dt) or dt<=0 or dt>.25 or not actor or not finite(actor.x) or not finite(actor.z) then return end
    self.elapsed=self.elapsed+dt; self.scanElapsed=self.scanElapsed+dt
    self:Snapshot(actor)
    if self.scanElapsed>=1 then
        self.scanElapsed=0
        if not self.routeX or (actor.x-self.routeX)^2+(actor.z-self.routeZ)^2>=16^2 then self:Scan(actor) end
        for i=#self.people,1,-1 do
            local p=self.people[i]
            if d2(p.x,p.z,actor)>Crowd.RECYCLE^2 and self:Hidden(p.x,p.z,actor,camera) then self:Retire(i) end
        end
    end
    -- 失败补人每半秒才重试，每次最多12候选；不每帧重复64次碰撞查询。
    self.spawnElapsed=self.spawnElapsed+dt
    if self.spawnElapsed>=.5 then
        self.spawnElapsed=0
        for _=1,Crowd.MAX_CREATES do if not self:Acquire(actor,camera) then break end end
    end
    local count=#self.people
    -- 预算随自适应画质档位缩放：弱设备少走几人、少解几副姿态，人数不减少。
    local quality=require("Career.AdaptiveQuality").Current()
    local maxMoves=math.max(2,math.floor(Crowd.MAX_MOVES*quality.npcScale))
    local maxPoses=math.max(2,math.floor(Crowd.MAX_POSES*quality.npcScale))
    for _,p in ipairs(self.people) do p.poseElapsed=math.min(.2,p.poseElapsed+dt); p.idle=p.idle+dt end
    for _=1,math.min(maxMoves,count) do
        local index=(self.moveCursor-1)%math.max(1,count)+1
        local p=self.people[index]
        self.moveCursor=index+1
        if d2(p.x,p.z,actor)<=Crowd.RANGE^2 then self:Move(p,math.min(.1,dt*math.max(1,count/maxMoves))) end
    end
    local evaluated=0
    for offset=0,count-1 do
        if evaluated>=maxPoses then break end
        local index=(self.poseCursor+offset-1)%math.max(1,count)+1
        local p=self.people[index]
        local distance=d2(p.x,p.z,actor)
        local period=distance<28^2 and .05 or .15
        if distance<=Crowd.RANGE^2 and p.poseElapsed>=period then
            local target=p.moved>.00001 and 1 or 0
            p.blend=p.blend+(target-p.blend)*(1-math.exp(-p.poseElapsed*12))
            if target==0 and p.blend<.005 then p.blend=0 end
            p.moved=0; self:Pose(p); evaluated=evaluated+1
        end
    end
    self.poseCursor=(self.poseCursor+maxPoses-1)%math.max(1,count)+1
end
-- 交通应读取同一people/x/z/radius小圆。玩家可不接实体阻挡，优先行人主动避让。
function Crowd:GetBlockers()
    local list={}
    if self.disposed or self.city.space~="city" or self.city.traffic and not self.city.traffic.active then return list end
    for _,p in ipairs(self.people) do
        if p.active then
            local y1,y2=TrafficMotion.PersonInterval(self.city,p)
            list[#list+1]={x=p.x,z=p.z,radius=p.radius,height=y1,y1=y1,y2=y2}
        end
    end
    return list
end
function Crowd:IsFree(x,z,r,height)
    if self.disposed or self.city.space~="city" or self.city.traffic and not self.city.traffic.active then return true end
    -- Pure horizontal rejection first; preserve exact support-height intervals
    -- for the handful of potentially overlapping people, including bridge decks.
    local y=height
    for _,p in ipairs(self.people) do
        if p.active and d2(x,z,p)<(r+p.radius)^2 then
            if y==nil then y=self.city:WalkSurface(x,z,0) end
            local y1,y2=TrafficMotion.PersonInterval(self.city,p)
            if TrafficMotion.VerticalOverlap(y,y+1.8,y1,y2) then return false end
        end
    end
    return true
end
function Crowd:Stats()
    return {active=#self.people,pool=#self.pool,budget=self.budget,created=self.created,reused=self.reused,retired=self.retired,
        poses=self.poseCount,moves=self.moveCount,waits=self.waitCount,maxPoses=Crowd.MAX_POSES,maxMoves=Crowd.MAX_MOVES}
end
function Crowd:Dispose()
    if self.disposed then return end
    self.disposed=true; self.enabled=false
    self.root:Dispose(); self.pool,self.people,self.routes,self.shapes,self.vehicleShapes={},{},{},{},{}
end
-- Explicit plain-data fixture; no person pool/scene/save is created. The
-- vehicle asset shell is the same immutable resource already used in gameplay.
function Crowd.CacheChecks()
    ---@type number
    local calls=0
    ---@type string[]
    local queries={}
    local city={space="city",Surface=function(_,x,z) calls=calls+1;queries[#queries+1]=string.format("S %.17g %.17g",x,z);return 0 end,
        WalkSurface=function(_,x,z,height) calls=calls+1;queries[#queries+1]=string.format("W %.17g %.17g %.17g",x,z,height or 0);return height or 0 end,
        StaticSegmentFree=function() return true end}
    local crowd=setmetatable({city=city,people={},shapes={},disposed=false},Crowd)
    local actor={x=0,z=0,mounted=false,walkHeight=0,vehicleId="borrowed_ebike",bikeX=30,bikeZ=30,bikeYaw=0,
        ParkedShapes=true,parking={}}
    crowd:Snapshot(actor)
    local parked=crowd.shapes[1].shape
    crowd:Snapshot(actor)
    assert(crowd.shapes[1].shape==parked,"stationary parked shell rebuilt")
    actor.bikeYaw=.01;crowd:Snapshot(actor)
    assert(crowd.shapes[1].shape~=parked,"park yaw edit ignored")
    local p={x=0,z=0,radius=.30,height=0,active=true} --[[@as CareerCrowdPerson]]
    crowd.shapes={};crowd.people={{x=100,z=100,radius=.30,active=true} --[[@as CareerCrowdPerson]]}
    calls=0
    assert(crowd:IsFree(0,0,.32) and calls==0,"remote people queried support height")
    crowd.people={p}
    assert(crowd:IsFree(0,0,.32,6) and not crowd:IsFree(0,0,.32,0),"bridge occupancy interval lost")
    -- Relative sweep must include an approaching vehicle even if its current
    -- shell does not overlap the short pedestrian segment.
    local vehicle={x=0,z=3,width=1,length=1,yaw=0}
    local entry={shape=TrafficMotion.Shape(vehicle),vehicle=vehicle,vx=0,vz=-10}
    crowd.shapes={entry}
    assert(not crowd:SegmentFree(p,0,0,0,.1,.3),"approaching vehicle lost by broad phase")
    assert(entry.y1==0 and entry.y2==1.85,"vehicle height was not resolved on broad hit")
    p.height=6
    assert(crowd:SegmentFree(p,0,0,0,.1,.3),"ground vehicle blocks bridge person")
    -- Exact query memo includes the layer seed, including nil vs false/zero;
    -- changing the world between calls must never see the prior Move's cache.
    local supportCalls=0
    local support={WalkSurface=function(_,x,z,height) supportCalls=supportCalls+1;return height or 0 end}
    local samples={}
    assert(walkSurface(support,1,2,0,samples)==0 and walkSurface(support,1,2,0,samples)==0 and supportCalls==1,"same-call support query rebuilt")
    assert(walkSurface(support,1,2,6,samples)==6 and supportCalls==2,"same-XZ bridge seed aliased ground")
    assert(walkSurface(support,1,2,6,{})==6 and supportCalls==3,"support memo survived call boundary")
    -- Independent pre-lazy reference: eager TrafficMotion.Shape and the old
    -- exact-AABB/height/narrow path. Neither calls snapshotBounds/Vehicle.
    local function eagerSnapshot(target,who)
        target.shapes={}
        local function add(shape,y1,y2,vx,vz,car)
            target.shapes[#target.shapes+1]={shape=shape,y1=y1,y2=y2,vx=vx or 0,vz=vz or 0,vehicle=car}
        end
        local traffic=target.city.traffic
        for _,group in ipairs({traffic and traffic.cars or {},traffic and traffic.outer and traffic.outer.cars or {}}) do
            for _,car in ipairs(group) do
                if d2(car.x,car.z,who)<150^2 then
                    local angle=math.rad(car.yaw)
                    add(TrafficMotion.Shape(car),nil,nil,math.sin(angle)*(car.speed or 0),math.cos(angle)*(car.speed or 0),car)
                end
            end
        end
        local function park(id,x,z,yaw)
            local shell,car=target:VehicleShape(id,x,z,yaw)
            add(shell,nil,nil,0,0,car)
        end
        if who.ParkedShapes then
            if not who.mounted then park(who.vehicleId,who.bikeX,who.bikeZ,who.bikeYaw) end
            for id,pos in pairs(who.parking or {}) do if id~=who.vehicleId then park(id,pos.x,pos.z,pos.yaw) end end
        end
        if who.mounted then park(who.vehicleId,who.x,who.z,who.yaw)
        else
            local y=target.city:WalkSurface(who.x,who.z,who.walkHeight or 0)
            add(C.Circle(who.x,who.z,.32),y,y+1.8)
        end
        for _,group in ipairs({traffic and traffic.pedestrians and traffic.pedestrians.people or {},traffic and traffic.outer and traffic.outer.people or {},target.city.deliveryPeople and target.city.deliveryPeople.people or {}}) do
            for _,person in ipairs(group) do
                if person.active~=false and person.inUse~=false and finite(person.x) and finite(person.z) and d2(person.x,person.z,who)<125^2 then
                    local low,high=TrafficMotion.PersonInterval(target.city,person)
                    add(C.Circle(person.x,person.z,person.radius or .30),low,high)
                end
            end
        end
    end
    local function eagerSegment(target,person,ax,az,bx,bz,predict)
        local town=target.city
        if not town:StaticSegmentFree(ax,az,bx,bz,person.radius,"walk",person.height) then return false end
        local y1=town:WalkSurface(ax,az,person.height)
        local ym=town:WalkSurface((ax+bx)*.5,(az+bz)*.5,y1)
        local y2=town:WalkSurface(bx,bz,ym)
        if math.abs(y2-y1)>.32+math.sqrt((bx-ax)^2+(bz-az)^2)*.18 then return false end
        local shape=false
        local dx,dz=bx-ax,bz-az
        local low,high=math.min(y1,ym,y2),math.max(y1,ym,y2)+1.8
        for _,item in ipairs(target.shapes) do
            local rx,rz=dx-item.vx*(predict or .25),dz-item.vz*(predict or .25)
            local other=item.shape
            if math.max(ax+person.radius,ax+person.radius+rx)+.025>=other.x1
                and math.min(ax-person.radius,ax-person.radius+rx)-.025<=other.x2
                and math.max(az+person.radius,az+person.radius+rz)+.025>=other.z1
                and math.min(az-person.radius,az-person.radius+rz)-.025<=other.z2 then
                if item.y1==nil and item.vehicle then item.y1,item.y2=TrafficMotion.VehicleInterval(town,item.vehicle) end
                local ey=item.y1 or town:Surface((other.x1+other.x2)/2,(other.z1+other.z2)/2)
                if TrafficMotion.VerticalOverlap(low,high,ey,item.y2 or ey+1.8) then
                    if not shape then shape=C.Circle(ax,az,person.radius) end
                    if not C.Free(shape,other,.025) or C.Sweep(shape,other,rx,rz,.025) then return false end
                end
            end
        end
        local x1,x2=math.min(ax,bx)-person.radius-.04,math.max(ax,bx)+person.radius+.04
        local z1,z2=math.min(az,bz)-person.radius-.04,math.max(az,bz)+person.radius+.04
        for _,other in ipairs(target.people) do
            if other~=person and other.active and other.x+other.radius>=x1 and other.x-other.radius<=x2
                and other.z+other.radius>=z1 and other.z-other.radius<=z2 then
                local oy1,oy2=TrafficMotion.PersonInterval(town,other)
                if TrafficMotion.VerticalOverlap(low,high,oy1,oy2) then
                    if not shape then shape=C.Circle(ax,az,person.radius) end
                    local body=C.Circle(other.x,other.z,other.radius)
                    if not C.Free(shape,body,.04) or C.Sweep(shape,body,dx,dz,.04) then return false end
                end
            end
        end
        return true
    end
    local function encloses(bounds,shell)
        assert(bounds.x1<=shell.x1 and bounds.x2>=shell.x2 and bounds.z1<=shell.z1 and bounds.z2>=shell.z2,
            "lazy broad envelope omitted exact shell")
    end
    local function sameShell(a,b)
        assert(a.x1==b.x1 and a.x2==b.x2 and a.z1==b.z1 and a.z2==b.z2 and #a.parts==#b.parts,"snapshot exact bounds changed")
        for i,part in ipairs(a.parts) do
            local ref=b.parts[i]
            if part.radius then
                assert(part.x==ref.x and part.z==ref.z and part.radius==ref.radius,"snapshot circle changed")
            else
                assert(#part.points==#ref.points,"snapshot vertex count changed")
                for j,v in ipairs(part.points) do assert(v.x==ref.points[j].x and v.z==ref.points[j].z,"snapshot vertex changed") end
            end
        end
    end
    -- Every measured asset, both rider-composite OBB semantics and anonymous
    -- boxes; axis/tiny/oblique/wrapped yaw, moving/zero sweep, both height tiers.
    local ids={"borrowed_ebike"}
    for id in pairs(require("VehicleAssets").Vehicles) do ids[#ids+1]=id end
    ids[#ids+1]="rider";ids[#ids+1]="box"
    local comparisons=0
    for _,id in ipairs(ids) do
        for _,yaw in ipairs({-540,-180,-90,-.000001,0,.01,37,89.999999,90,179.9,720.25}) do
            local car={id=id~="rider" and id~="box" and id or nil,vehicleId=id=="rider" and "sport" or nil,
                riding=id=="rider",x=-3,z=-31,yaw=yaw,width=2.7,length=5.8,speed=11,bodyHeight=2.3}
            city.traffic={cars={car},outer={cars={{x=70,z=70,yaw=12,width=1,length=2,speed=0}},
                people={{x=-1,z=-26,radius=.31,height=6,active=true}}},
                pedestrians={people={{x=-4,z=-28,radius=.3,height=0,active=true}}}}
            city.deliveryPeople={people={{x=-2,z=-25,radius=.32,height=0,active=true}}}
            local who={x=80,z=0,mounted=false,walkHeight=0}
            local lazy=setmetatable({city=city,people={},shapes={}},Crowd)
            local old=setmetatable({city=city,people={},shapes={}},Crowd)
            lazy:Snapshot(who)
            assert(lazy.shapes[1].shape==nil,"Snapshot eagerly posed moving vehicle")
            if id=="rider" then
                assert(lazy.shapes[1].vehicleSource==car.boxSource and car.boxSource.x2==car.width/2,
                    "resident rider lost measured composite OBB")
            end
            eagerSnapshot(old,who)
            assert(#lazy.shapes==#old.shapes,"Snapshot omitted/reordered entities")
            for i,item in ipairs(lazy.shapes) do
                local ref=old.shapes[i]
                encloses(item.shape or item.bounds,ref.shape)
                assert(item.vx==ref.vx and item.vz==ref.vz and item.y1==ref.y1 and item.y2==ref.y2,"Snapshot numeric state changed")
            end
            for _,height in ipairs({0,6}) do
                p.height=height
                for _,prediction in ipairs({0,.25,3}) do
                    for _,edge in ipairs({{-3,-31,-3,-31},{-10,-31,4,-31},{-3,-40,-3,-22},
                        {-8,-35,1,-27},{-3,-36,-2.9,-35.9},{40,40,41,40},
                        {-4,-28,-1,-26},{-2,-25,-2,-25}}) do
                        calls=0;queries={}
                        local actual=lazy:SegmentFree(p,edge[1],edge[2],edge[3],edge[4],prediction)
                        local lazyCalls,lazyQueries=calls,table.concat(queries,"|")
                        calls=0;queries={}
                        local expected=eagerSegment(old,p,edge[1],edge[2],edge[3],edge[4],prediction)
                        assert(actual==expected and calls==lazyCalls and table.concat(queries,"|")==lazyQueries,
                            "lazy/eager result or support-query order differs")
                        comparisons=comparisons+1
                    end
                end
            end
            for i,item in ipairs(lazy.shapes) do if item.shape then sameShell(item.shape,old.shapes[i].shape) end end
        end
    end
    -- A remote sweep must allocate no shell or vehicle support query. Freeze
    -- before/after materialisation and after a NEW Snapshot changes all poses.
    local car={x=0,z=3,yaw=0,width=1,length=1,speed=-10,bodyHeight=1.85,riding=true,vehicleId="sport"}
    city.traffic={cars={car}};city.deliveryPeople=nil
    local who={x=80,z=0,mounted=false,walkHeight=0}
    local lazy=setmetatable({city=city,people={},shapes={}},Crowd)
    local old=setmetatable({city=city,people={},shapes={}},Crowd)
    lazy:Snapshot(who);eagerSnapshot(old,who)
    local saved=lazy.shapes
    local exact=old.shapes[1].shape
    local cached=setmetatable({city=city,people={},shapes={}},Crowd)
    cached:Snapshot(who)
    assert(cached.shapes[1].shape==exact,"valid traffic shell cache not reused")
    car.width=1.1;cached:Snapshot(who)
    assert(not cached.shapes[1].shape,"traffic dimension/source edit ignored")
    car.width=1
    local frozen={x=0,z=3,width=1,length=1,yaw=0,bodyHeight=1.85,riding=true,vehicleId="sport"}
    old.shapes[1].vehicle=frozen
    p.height=0;calls=0
    assert(lazy:SegmentFree(p,40,40,41,40,.3) and calls==3 and not saved[1].shape,
        "remote sweep posed shell/queried vehicle height")
    car.x,car.z,car.yaw,car.width,car.length,car.bodyHeight,car.speed,car.riding=50,50,123,4,8,9,2,false
    TrafficMotion.Shape(car) -- source/key replacement must not touch saved source
    assert(not lazy:SegmentFree(p,0,0,0,.1,.3) and not eagerSegment(old,p,0,0,0,.1,.3),"frozen approaching vehicle lost")
    assert(saved[1].y1==0 and saved[1].y2==1.85,"snapshot height read changed live vehicle")
    sameShell(saved[1].shape,exact)
    local materialised=saved[1].shape
    lazy:SegmentFree(p,0,0,0,.1,.3)
    assert(saved[1].shape==materialised,"lazy shell rebuilt on repeated query")
    lazy:Snapshot(who)
    assert(lazy.shapes~=saved,"snapshot storage reused")
    sameShell(snapshotShape(saved[1]),exact)
    -- Mutation BEFORE the first near query, including a subsequent Snapshot.
    car.x,car.z,car.yaw,car.width,car.length,car.riding,car.vehicleId=0,3,17,1,2,true,"sport"
    lazy:Snapshot(who);saved=lazy.shapes
    local unposed=C.Pose(TrafficMotion.Source(car),car.x,car.z,car.yaw)
    assert(not saved[1].shape,"uncached pose unexpectedly eager")
    car.x,car.z,car.yaw,car.width=60,60,-90,7
    lazy:Snapshot(who)
    sameShell(snapshotShape(saved[1]),unposed)
    -- Conservative false positives must not add a height lookup. Circle parts
    -- also exercise the enclosure proof beyond today's polygon-only vehicles.
    local triangle=C.Shape({{points={{x=0,z=0},{x=4,z=0},{x=0,z=4}}}})
    local b=snapshotBounds(triangle,0,0,45)
    local shell=C.Pose(triangle,0,0,45)
    assert(b.x2>shell.x2+.3,"fixture requires a loose conservative corner")
    lazy.shapes={{vehicleSource=triangle,vehicleYaw=45,vehicle={x=0,z=0},bounds=b,vx=0,vz=0}}
    calls=0
    assert(lazy:SegmentFree(p,shell.x2+.4,0,shell.x2+.4,0,0) and calls==3,
        "conservative-only hit queried vehicle support")
    for _,yaw in ipairs({0,.000001,45,90,137,180,270}) do
        local circle=C.Circle(2,-3,.7)
        encloses(snapshotBounds(circle,-100,400,yaw),C.Pose(circle,-100,400,yaw))
    end
    lazy.shapes={{shape=C.Box(-.6,1,.6,4),vx=0,vz=0}}
    assert(not lazy:SegmentFree(p,0,0,0,3),"direct-shape fixture no longer supported")
    -- 缺省高度懒求值有意改变查询时机；单独核对少查/只查一次，最终壳、
    -- 区间和通行结果仍与独立eager参考逐项一致。地形在同步快照有效期内不变。
    local personQueries=0
    local personCity={space="city",StaticSegmentFree=function() return true end,
        Surface=function() return 0 end,
        WalkSurface=function(_,x,z,height)
            if x==0 and z==2 and height==0 then personQueries=personQueries+1 end
            if height and height~=0 then return height end
            return x*.1+z*.02
        end}
    local personLazy=setmetatable({city=personCity,people={},shapes={}},Crowd)
    local personOld=setmetatable({city=personCity,people={},shapes={}},Crowd)
    local observer={x=80,z=0,mounted=false,walkHeight=0}
    for _,input in ipairs({{}, {y=6}, {height=0,y=6}, {height=false,y=6},
        {height="invalid",y=6}, {height=-2}, {y=false}, {height=12}}) do
        local external={x=0,z=2,radius=.31,height=input.height,y=input.y,active=true}
        personCity.traffic={pedestrians={people={external}}}
        personQueries=0
        personLazy:Snapshot(observer)
        local item=personLazy.shapes[2]
        assert(not item.shape and personQueries==0,"外部行人快照提前建圆或查缺省高度")
        assert(personLazy:SegmentFree(p,40,40,41,40) and not item.shape and personQueries==0,
            "远处行人被宽相排除后仍创建几何或查询地面")
        eagerSnapshot(personOld,observer)
        local ref=personOld.shapes[2]
        local missing=type(external.height or external.y)~="number"
        assert(personQueries==(missing and 1 or 0),"eager缺省高度测试前提改变")
        local resolvedQueries=0
        for _,height in ipairs({0,6,12}) do
            p.height=height
            for _,edge in ipairs({{0,0,0,3},{0,2,0,2},{-.5,2,.5,2},{0,0,0,1},{40,40,41,40}}) do
                personQueries=0
                local actual=personLazy:SegmentFree(p,edge[1],edge[2],edge[3],edge[4])
                local lazyCount=personQueries
                personQueries=0
                local expected=eagerSegment(personOld,p,edge[1],edge[2],edge[3],edge[4])
                -- 扣除两条路径相同的路点地表查询，只计外部行人的缺省高度准备。
                resolvedQueries=resolvedQueries+lazyCount-personQueries
                assert(actual==expected,"外部行人懒圆改变同层/跨层/坡面扫掠判定")
                comparisons=comparisons+1
            end
        end
        assert(item.shape and item.y1==ref.y1 and item.y2==ref.y2,"外部行人冻结区间改变")
        sameShell(item.shape,ref.shape)
        assert(resolvedQueries==(missing and 1 or 0),"同一快照多条边重复查询缺省地面")
    end
    -- 原人物在首次命中前修改，随后再建新快照；旧条目必须继续用冻结输入。
    local external={x=0,z=2,radius=.31,active=true}
    personCity.traffic={pedestrians={people={external}}}
    personLazy:Snapshot(observer);eagerSnapshot(personOld,observer)
    local frozenPeople=personLazy.shapes
    local frozenRef=personOld.shapes[2]
    external.x,external.z,external.height,external.y,external.radius=30,30,6,12,.8
    personLazy:Snapshot(observer)
    local freshPeople=personLazy.shapes
    personLazy.shapes=frozenPeople
    p.height=0;personQueries=0
    assert(not personLazy:SegmentFree(p,0,0,0,3) and not eagerSegment(personOld,p,0,0,0,3),
        "旧行人快照读取了后来修改的位置/半径/高度")
    sameShell(frozenPeople[2].shape,frozenRef.shape)
    assert(frozenPeople[2].y1==frozenRef.y1 and frozenPeople[2].y2==frozenRef.y2 and personQueries==1,
        "旧行人快照缺省地面未使用冻结XZ")
    personLazy.shapes=freshPeople
    assert(personLazy:SegmentFree(p,0,0,0,3) and not freshPeople[2].shape,"新行人快照未看见新位置")
    personLazy:Snapshot(observer);eagerSnapshot(personOld,observer)
    assert(personLazy.shapes[2].y1==6 and personLazy.shapes[2].y2==7.8,"数值高度选择未保持height优先")
    p.height=0
    -- Live self.people order still matters within a frame (do not snapshot it).
    lazy.shapes={};old.shapes={}
    local person={x=0,z=2,radius=.3,height=0,active=true} --[[@as CareerCrowdPerson]]
    lazy.people={person};old.people={person}
    assert(not lazy:SegmentFree(p,0,0,0,3) and not eagerSegment(old,p,0,0,0,3),"same-frame person collision lost")
    person.x=10
    assert(lazy:SegmentFree(p,0,0,0,3) and eagerSegment(old,p,0,0,0,3),"same-frame person movement stale")
    print(string.format("[人群缓存检查] PASS 原缓存检查 + %d eager对照/懒车壳/包络/旧快照/骑手OBB/直接shape/同帧顺序",comparisons))
    return true
end
return Crowd
