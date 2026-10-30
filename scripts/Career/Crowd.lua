-- 近场增量人群：基于3D角色脚手架的Node/AnimatedModel所有权；不接管主角/交通。
-- 写实便服41骨 + 共享官动相位表，固定24槽上限；旧8+4人保持独立。
local World=require("Career.WorldData")
local Routes=require("Career.TrafficRoutes")
local C=require("Career.FootprintCollision")
local Footprints=require("Career.VehicleFootprints")
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
-- 车轮/后视镜/箱体用环境代理同一可见足迹；车辆缓存每次Update只建一次。
function Crowd:Snapshot(actor)
    self.shapes={}
    local traffic=self.city.traffic
    for _,group in ipairs({traffic and traffic.cars or {},traffic and traffic.outer and traffic.outer.cars or {}}) do
        for _,car in ipairs(group) do
            if d2(car.x,car.z,actor)<150^2 then
                local shape=TrafficMotion.Shape(car)
                local angle=math.rad(car.yaw)
                self.shapes[#self.shapes+1]={shape=shape,vx=math.sin(angle)*(car.speed or 0),vz=math.cos(angle)*(car.speed or 0),car=true}
            end
        end
    end
    if actor.ParkedShapes then
        for _,shape in ipairs(actor:ParkedShapes()) do self.shapes[#self.shapes+1]={shape=shape,vx=0,vz=0} end
    end
    self.shapes[#self.shapes+1]={shape=actor.mounted and Footprints.At(actor.vehicleId,actor.x,actor.z,actor.yaw) or C.Circle(actor.x,actor.z,.32),vx=0,vz=0}
    for _,group in ipairs({traffic and traffic.pedestrians and traffic.pedestrians.people or {},traffic and traffic.outer and traffic.outer.people or {},self.city.deliveryPeople and self.city.deliveryPeople.people or {}}) do
        for _,p in ipairs(group) do
            if p.active~=false and p.inUse~=false and finite(p.x) and finite(p.z) and d2(p.x,p.z,actor)<125^2 then
                self.shapes[#self.shapes+1]={shape=C.Circle(p.x,p.z,p.radius or .30),vx=0,vz=0}
            end
        end
    end
end
---@param p CareerCrowdPerson
function Crowd:SegmentFree(p,ax,az,bx,bz,predict)
    if not self.city:StaticSegmentFree(ax,az,bx,bz,p.radius,"walk",p.height) then return false end
    local mx,mz=(ax+bx)*.5,(az+bz)*.5
    local y1=self.city:WalkSurface(ax,az,p.height)
    local ym=self.city:WalkSurface(mx,mz,y1)
    local y2=self.city:WalkSurface(bx,bz,ym)
    if math.abs(y2-y1)>.32+math.sqrt((bx-ax)^2+(bz-az)^2)*.18 then return false end
    local shape=C.Circle(ax,az,p.radius)
    local dx,dz=bx-ax,bz-az
    for _,entry in ipairs(self.shapes) do
        local time=predict or .25
        if not C.Free(shape,entry.shape,.025) or C.Sweep(shape,entry.shape,dx-entry.vx*time,dz-entry.vz*time,.025) then return false end
    end
    for _,other in ipairs(self.people) do
        if other~=p and other.active then
            local body=C.Circle(other.x,other.z,other.radius)
            if not C.Free(shape,body,.04) or C.Sweep(shape,body,dx,dz,.04) then return false end
        end
    end
    return true
end
function Crowd:CanCross(p)
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
    return self:SegmentFree(p,ax,az,bx,bz,required)
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
    local state=p.localWalk
    state.cooldown=math.max(0,state.cooldown-dt)
    local crossing=route.crossing
    local entry=crossing and (p.direction==1 and crossing.enter or crossing.exit) or 0
    local distance=p.speed*dt
    local target=state.points[state.index]
    local desired=math.max(0,math.min(route.length,p.s+p.direction*distance))
    if crossing and (p.direction==1 and p.s<=entry+.001 and desired>entry or p.direction==-1 and p.s>=entry-.001 and desired<entry) then
        if not self:CanCross(p) then desired=entry; p.pending=true else p.pending=false end
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
    if self:SegmentFree(p,p.x,p.z,nx,nz) then
        p.x,p.z=nx,nz
        local ux,uz=(route.path[3]-route.path[1])/route.length,(route.path[4]-route.path[2])/route.length
        p.s=math.max(0,math.min(route.length,(nx-route.path[1])*ux+(nz-route.path[2])*uz))
        local yaw=math.deg(math.atan(dx,dz))
        p.yaw=wrap(p.yaw+math.max(-150*dt,math.min(150*dt,wrap(yaw-p.yaw))))
        p.height=self.city:WalkSurface(nx,nz,p.height)
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
                if self:SegmentFree(p,p.x,p.z,ax,az) and self:SegmentFree(p,ax,az,bx,bz) and self:SegmentFree(p,bx,bz,cx,cz) then
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
    if not self.root.enabledSelf then
        self.root:SetEnabledRecursive(true)
        for _,p in ipairs(self.pool) do if not p.active then p.node:SetEnabledRecursive(false) end end
    end
    if not self.enabled or not finite(dt) or dt<=0 or dt>.25 or not actor or not finite(actor.x) or not finite(actor.z) then return end
    self.elapsed=self.elapsed+dt; self.scanElapsed=self.scanElapsed+dt
    self:Snapshot(actor)
    if self.scanElapsed>=1 then
        self.scanElapsed=0; self:Scan(actor)
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
    for _,p in ipairs(self.people) do p.poseElapsed=math.min(.2,p.poseElapsed+dt); p.idle=p.idle+dt end
    for _=1,math.min(Crowd.MAX_MOVES,count) do
        local index=(self.moveCursor-1)%math.max(1,count)+1
        local p=self.people[index]
        self.moveCursor=index+1
        if d2(p.x,p.z,actor)<=Crowd.RANGE^2 then self:Move(p,math.min(.1,dt*math.max(1,count/Crowd.MAX_MOVES))) end
    end
    local evaluated=0
    for offset=0,count-1 do
        if evaluated>=Crowd.MAX_POSES then break end
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
    self.poseCursor=(self.poseCursor+Crowd.MAX_POSES-1)%math.max(1,count)+1
end
-- 交通应读取同一people/x/z/radius小圆。玩家可不接实体阻挡，优先行人主动避让。
function Crowd:GetBlockers()
    local list={}
    if self.disposed or self.city.space~="city" or self.city.traffic and not self.city.traffic.active then return list end
    for _,p in ipairs(self.people) do if p.active then list[#list+1]={x=p.x,z=p.z,radius=p.radius,height=p.height} end end
    return list
end
function Crowd:IsFree(x,z,r,height)
    if self.disposed or self.city.space~="city" or self.city.traffic and not self.city.traffic.active then return true end
    for _,p in ipairs(self.people) do
        if p.active and (not height or math.abs(height-p.height)<1.2) and d2(x,z,p)<(r+p.radius)^2 then return false end
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
    self.root:Dispose(); self.pool,self.people,self.routes,self.shapes={},{},{},{}
end
return Crowd
