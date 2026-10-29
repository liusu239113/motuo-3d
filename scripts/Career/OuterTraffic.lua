-- 外区旁观交通：共享WorldData道路，固定6车/4人槽位，不建立全城实体或通用寻路。
-- 基于现有TrafficRoutes连续环线和Pedestrians距离驱动步态；老街数组不参与此池。
local World=require("Career.WorldData")
local Signals=require("Career.OuterSignals")
local Assets=require("VehicleAssets")
local Contact=require("Career.VehicleContact")
local Pedestrians=require("Career.Pedestrians")
local Rig=require("Career.Rig")
---@class OuterTrafficCar
---@field id string
---@field node Node
---@field length number
---@field width number
---@field x number
---@field z number
---@field yaw number
---@field s number
---@field speed number
---@field cruise number
---@field inUse boolean
---@field travelled number
---@field route table
---@field contactX? number
---@field contactZ? number
---@field contactYaw? number
---@class OuterTrafficPerson
---@field node Node
---@field rig CareerRig
---@field x number
---@field z number
---@field radius number
---@field s number
---@field direction number
---@field phase number
---@field gaitWeight number
---@field speed number
---@field yaw number
---@field turn number
---@field inUse boolean
---@field travelled number
---@field path number[]
---@field length number
---@class CareerOuterTraffic
---@field signals OuterSignalSystem
---@field time number
---@field root Node
---@field cars OuterTrafficCar[]
---@field people OuterTrafficPerson[]
---@field carPool OuterTrafficCar[]
---@field peoplePool OuterTrafficPerson[]
---@field lanes table[]
---@field disposed boolean
---@field active boolean
---@field steps number
---@field poseTime number
---@field recycled number
---@field Hint fun(self:CareerOuterTraffic,x:number,z:number,yaw:number):string?
---@field Gap fun(self:CareerOuterTraffic,car:OuterTrafficCar,blockers:table[]):number
---@field Separate fun(self:CareerOuterTraffic,car:table):boolean
---@field IsFree fun(self:CareerOuterTraffic,x:number,z:number,r:number):boolean
---@field Update fun(self:CareerOuterTraffic,dt:number,blockers:table[])
---@field Stats fun(self:CareerOuterTraffic):table
---@field Dispose fun(self:CareerOuterTraffic)
local Outer={}
Outer.__index=Outer
Outer.CAR_BUDGET,Outer.PEOPLE_BUDGET=6,4
Outer.OLD_MARGIN=220
Outer.CAR_RANGE,Outer.PEOPLE_RANGE=260,145

-- 碰撞设计（俯视，米；路宽W=12/16）：
-- 建筑 | 人行道4m | <-lane r=W/4 -- 中线 -- lane r=W/4-> | 人行道 | 建筑
--     行人圆 .32           车 OBB 长L / 宽B
-- 长直线>=140m，两端r=3/4m连续半圆，不在短小网格边上瞬间翻转。
-- OBB用沿车长的一串外包圆覆盖整个矩形查询City.StaticFree（含World静态域），
-- 与玩家/停车/行人用圆-OBB，与所有车辆用4轴SAT；位移子步<=.10m。
-- 擦边、长货车车角、路端掉头均提交前检测；失败留在原位，不穿墙/推玩家。
-- 仅12区中心路口有真实实体信号；其它路口保留东西向优先、已入场先清空。
-- 信号停车按异向有效半宽+5.6m的既有白线与车头计算，最终SAT兜底。
local function distance2(x,z,p) return (x-p.x)^2+(z-p.z)^2 end
local function localPoint(car,x,z)
    local a=math.rad(car.yaw)
    return (x-car.x)*math.cos(a)-(z-car.z)*math.sin(a),(x-car.x)*math.sin(a)+(z-car.z)*math.cos(a)
end
local function oldArea(x,z)
    return math.abs(x)<=Outer.OLD_MARGIN and math.abs(z)<=Outer.OLD_MARGIN
end
local function visible(node,on)
    -- 父enabled不保证子模型隐藏；只在实际状态变化时递归，不每帧遍历骨骼。
    if node:IsEnabled()~=on then node:SetEnabledRecursive(on) end
end
local function point(route,u,v)
    if route.axis=="ew" then return v,route.road-u end
    return route.road+u,v
end

-- 公开纯几何接口，测试可直接检查接缝/掉头连续性。
function Outer.Pose(route,distance)
    local straight=route.finish-route.start
    local arc=math.pi*route.radius
    local s=distance%(2*straight+2*arc)
    local u,v,yaw=route.radius,route.start+s,0
    if s>=straight and s<straight+arc then
        local a=(s-straight)/route.radius
        u,v,yaw=route.radius*math.cos(a),route.finish+route.radius*math.sin(a),-math.deg(a)
    elseif s>=straight+arc and s<2*straight+arc then
        u,v,yaw=-route.radius,route.finish-(s-straight-arc),180
    elseif s>=2*straight+arc then
        local a=math.pi+(s-2*straight-arc)/route.radius
        u,v,yaw=route.radius*math.cos(a),route.start+route.radius*math.sin(a),-math.deg(a)
    end
    local x,z=point(route,u,v)
    return x,z,yaw+(route.axis=="ew" and 90 or 0)
end

function Outer.StaticFree(city,car)
    local count=math.max(2,math.ceil(car.length/.8))
    local halfStep=car.length/count/2
    local radius=math.sqrt((car.width/2)^2+halfStep^2)+.08
    local a=math.rad(car.yaw)
    for i=1,count do
        local v=-car.length/2+(i-.5)*car.length/count
        if not city:StaticFree(car.x+math.sin(a)*v,car.z+math.cos(a)*v,radius,"vehicle",0) then return false end
    end
    return true
end

---@return CareerOuterTraffic
function Outer.New(owner)
    local self=setmetatable({},Outer)
    self:Init(owner)
    return self
end
function Outer:Init(owner)
    self.owner,self.city,self.actor=owner,owner.city,owner.actor
    self.root=self.city.root:CreateChild("附近外区交通池")
    self.root:SetEnabledRecursive(false)
    ---@type OuterTrafficCar[]
    self.cars={}
    ---@type OuterTrafficPerson[]
    self.people={}
    ---@type OuterTrafficCar[]
    self.carPool={}
    ---@type OuterTrafficPerson[]
    self.peoplePool={}
    self.lanes={}
    self.time,self.scanTime,self.poseTime=0,0,0
    self.scanX,self.scanZ=math.huge,math.huge
    self.active,self.disposed=false,false
    ---@type OuterSignalSystem
    self.signals=Signals.New(self)
    self.spawned,self.recycled,self.contactSolves,self.rejected,self.steps=0,0,0,0,0
    -- 接地显式使用共享WorldData，不依赖已stream的道路/建筑实体或老街surface缓存。
    self.ground={Surface=function(_,x,z) return World.Surface(x,z,"vehicle",0) end} --[[@as CareerCity]]
    ---@type Camera?
    self.camera=nil
end

-- 至少45/70米外且完整外包球在相机视锥外才出生/重用；无有效相机时宁缺不贴脸。
function Outer:Hidden(x,z,radius,minDistance)
    if distance2(x,z,self.actor)<minDistance^2 or not self.camera then return false end
    if (self.camera.node.worldPosition-Vector3(self.actor.x,self.camera.node.worldPosition.y,self.actor.z)):LengthSquared()>100^2 then return false end
    local height=World.Surface(x,z,"vehicle",0)
    return self.camera.frustum:IsInside(Sphere(Vector3(x,height+radius,z),radius+3))==OUTSIDE
end

-- Roads是数据不是实体；每秒/跨64m才刷新最多8条附近长lane，已有车辆路线不重写。
function Outer:Scan()
    self.scanX,self.scanZ=self.actor.x,self.actor.z
    local candidates={}
    for _,road in ipairs(World.Roads) do
        if not road.old then
            local ns=math.abs(road.x2-road.x1)<.01
            local ew=math.abs(road.z2-road.z1)<.01
            if ns or ew then
                local axis=ns and "ns" or "ew"
                local center=ns and road.x1 or road.z1
                local lo=math.min(ns and road.z1 or road.x1,ns and road.z2 or road.x2)+10
                local hi=math.max(ns and road.z1 or road.x1,ns and road.z2 or road.x2)-10
                local along=ns and self.actor.z or self.actor.x
                local across=ns and self.actor.x or self.actor.z
                local nearest=math.max(lo,math.min(hi,along))
                local d2=(along-nearest)^2+(across-center)^2
                if d2<190^2 and hi-lo>=140 then
                    local middle=math.max(lo+70,math.min(hi-70,math.floor(along/128+.5)*128))
                    local start,finish=math.max(lo,middle-160),math.min(hi,middle+160)
                    -- 两条贯穿原点的主干道截掉老街，避免外区车驶进原15车测试域。
                    if math.abs(center)<Outer.OLD_MARGIN then
                        if along>=0 then start=math.max(start,Outer.OLD_MARGIN+10)
                        else finish=math.min(finish,-Outer.OLD_MARGIN-10) end
                    end
                    if finish-start>=140 then
                        candidates[#candidates+1]={axis=axis,road=center,start=start,finish=finish,
                            radius=road.width/4,width=road.width,sidewalk=road.sidewalk or 4,id=road.id,d2=d2}
                    end
                end
            end
        end
    end
    table.sort(candidates,function(a,b) return a.d2<b.d2 end)
    self.lanes={}
    for i=1,math.min(8,#candidates) do self.lanes[i]=candidates[i] end
end

-- 裁出两个交叉路之间的同侧步道，绝不把无信号过街当成人行道。
function Outer.SidewalkPath(route,at)
    local lo,hi=route.start+12,route.finish-12
    for _,road in ipairs(World.Roads) do
        local perpendicular=route.axis=="ns" and road.z1==road.z2 or route.axis=="ew" and road.x1==road.x2
        if perpendicular then
            local cross=route.axis=="ns" and road.z1 or road.x1
            local a=route.axis=="ns" and math.min(road.x1,road.x2) or math.min(road.z1,road.z2)
            local b=route.axis=="ns" and math.max(road.x1,road.x2) or math.max(road.z1,road.z2)
            if route.road>=a-1 and route.road<=b+1 then
                local clearance=road.width/2+(road.sidewalk or 4)+2
                if math.abs(at-cross)<clearance then return nil end
                if cross<at then lo=math.max(lo,cross+clearance)
                else hi=math.min(hi,cross-clearance) end
            end
        end
    end
    if hi-lo<24 then return nil end
    return lo,hi
end

function Outer:CarFree(car,blockers)
    if oldArea(car.x,car.z) or not Outer.StaticFree(self.city,car) then return false end
    for _,other in ipairs(self.cars) do if other~=car and not self.owner.Separate(car,other) then return false end end
    for _,other in ipairs(self.owner.cars) do if not self.owner.Separate(car,other) then return false end end
    for _,b in ipairs(blockers) do if not self.owner.CircleFree(car,b.x,b.z,b.radius) then return false end end
    for _,p in ipairs(self.people) do if not self.owner.CircleFree(car,p.x,p.z,p.radius+.15) then return false end end
    for _,p in ipairs(self.owner.pedestrians.people) do if not self.owner.CircleFree(car,p.x,p.z,p.radius) then return false end end
    return true
end
function Outer:PersonFree(x,z,ignore,blockers)
    if oldArea(x,z) or not self.city:StaticFree(x,z,.36,"walk",0) then return false end
    for _,b in ipairs(blockers) do if distance2(x,z,b)<(.32+b.radius+.45)^2 then return false end end
    for _,p in ipairs(self.people) do if p~=ignore and distance2(x,z,p)<.9^2 then return false end end
    for _,p in ipairs(self.owner.pedestrians.people) do if distance2(x,z,p)<.9^2 then return false end end
    for _,car in ipairs(self.cars) do if not self.owner.CircleFree(car,x,z,.5) then return false end end
    for _,car in ipairs(self.owner.cars) do if not self.owner.CircleFree(car,x,z,.5) then return false end end
    return true
end
function Outer:IsFree(x,z,r)
    if self.disposed then return true end
    for _,car in ipairs(self.cars) do if not self.owner.CircleFree(car,x,z,r) then return false end end
    for _,p in ipairs(self.people) do if distance2(x,z,p)<(r+p.radius)^2 then return false end end
    return true
end
function Outer:Separate(car)
    for _,other in ipairs(self.cars) do if not self.owner.Separate(car,other) then return false end end
    for _,p in ipairs(self.people) do if not self.owner.CircleFree(car,p.x,p.z,p.radius) then return false end end
    return true
end

function Outer:ReleaseCar(index)
    local car=table.remove(self.cars,index)
    visible(car.node,false); car.speed=0; car.inUse=false
    self.recycled=self.recycled+1
end
function Outer:ReleasePerson(index)
    local p=table.remove(self.people,index)
    visible(p.node,false); p.inUse=false
    self.recycled=self.recycled+1
end
---@param id string
---@return OuterTrafficCar?
function Outer:AcquireCar(id)
    for _,car in ipairs(self.carPool) do if not car.inUse and car.id==id then car.inUse=true; return car end end
    if #self.carPool>=Outer.CAR_BUDGET then return nil end
    local node=Assets.Add(self.root,id,nil,"distant")
    if id=="truck" then Contact.CompleteTruck(node) end
    node:SetEnabledRecursive(false)
    local size=node:GetVar("VehicleSize"):GetVector3()
    ---@type OuterTrafficCar
    local car={id=id,node=node,length=size.z,width=size.x,x=0,z=0,yaw=0,s=0,speed=0,cruise=6.5,inUse=true,travelled=0,route={}}
    self.carPool[#self.carPool+1]=car
    return car
end
---@return OuterTrafficPerson?
function Outer:AcquirePerson()
    for _,p in ipairs(self.peoplePool) do if not p.inUse then p.inUse=true; return p end end
    if #self.peoplePool>=Outer.PEOPLE_BUDGET then return nil end
    local index=#self.peoplePool+1
    local node=self.root:CreateChild("外区便服行人"..index)
    local rig=Rig.New(node,Pedestrians.Specs[(index-1)%#Pedestrians.Specs+1])
    node:SetEnabledRecursive(false)
    rig.ground=self.city; rig.model.drawDistance=110; rig.model.shadowDistance=30
    ---@type OuterTrafficPerson
    local p={node=node,rig=rig,x=0,z=0,radius=.32,s=0,direction=1,phase=index,gaitWeight=0,speed=.95+index*.06,yaw=0,turn=0,inUse=true,travelled=0,path={},length=1}
    self.peoplePool[index]=p
    return p
end
function Outer:ApplyContact(car)
    if car.contactX==car.x and car.contactZ==car.z and car.contactYaw==car.yaw then return end
    local height,pitch,roll=Contact.Solve(self.ground,car.id,car.x,car.z,car.yaw,0)
    car.node.position=Vector3(car.x,height,car.z)
    car.node.rotation=Quaternion(0,car.yaw,0)*Quaternion(pitch,Vector3.RIGHT)*Quaternion(roll,Vector3.FORWARD)
    car.contactX,car.contactZ,car.contactYaw=car.x,car.z,car.yaw
    self.contactSolves=self.contactSolves+1
end
function Outer:Fill(blockers)
    -- 每次只做有限候选探测。找不到安全隐藏点时保持缺额，不强行生成。
    for slot=1,Outer.CAR_BUDGET do
        if #self.cars>=Outer.CAR_BUDGET then break end
        local id=Assets.TrafficIds[(slot-1)%#Assets.TrafficIds+1]
        for _,cached in ipairs(self.carPool) do if not cached.inUse then id=cached.id; break end end
        ---@type VehicleAssetConfig
        local spec=Assets.Vehicles[id]
        local placed=false
        for _,route in ipairs(self.lanes) do
            local length=2*(route.finish-route.start)+2*math.pi*route.radius
            for n=1,20 do
                local s=((n-1)/20+slot*.071)*length
                local x,z,yaw=Outer.Pose(route,s)
                if distance2(x,z,self.actor)<220^2 and self:Hidden(x,z,4,70) then
                    local probe={x=x,z=z,yaw=yaw,length=spec.targetLength,width=spec.targetSize.x+.05}
                    if self:CarFree(probe,blockers) then
                        local car=self:AcquireCar(id)
                        if car then
                            car.route,car.s,car.x,car.z,car.yaw=route,s,x,z,yaw
                            car.speed,car.cruise=0,5.8+(slot%3)*.65
                            -- 校验实际包围盒，而不是只信配置近似值。
                            if self:CarFree(car,blockers) then
                                self.cars[#self.cars+1]=car
                                car.contactX=nil; self:ApplyContact(car); visible(car.node,true)
                                self.spawned=self.spawned+1; placed=true
                            else car.inUse=false; self.rejected=self.rejected+1 end
                        end
                    else self.rejected=self.rejected+1 end
                end
                if placed then break end
            end
            if placed then break end
        end
        if not placed then break end
    end
    for slot=1,Outer.PEOPLE_BUDGET do
        if #self.people>=Outer.PEOPLE_BUDGET then break end
        local placed=false
        for _,route in ipairs(self.lanes) do
            for _,side in ipairs({-1,1}) do
                local offset=side*(route.width/2+route.sidewalk/2)
                for n=1,10 do
                    local at=route.start+12+(route.finish-route.start-24)*(n-.5)/10
                    local start,finish=Outer.SidewalkPath(route,at)
                    local x,z=point(route,offset,at)
                    if start and finish and distance2(x,z,self.actor)<125^2 and self:Hidden(x,z,1.5,45) and self:PersonFree(x,z,nil,blockers) then
                        -- 整段地表/静态碰撞先检查；玩家/车辆等动态障碍只令行人让停。
                        local clear=true
                        for sample=start,finish,2 do
                            local sx,sz=point(route,offset,sample)
                            if not self.city:StaticFree(sx,sz,.36,"walk",0) then clear=false; break end
                        end
                        local p=clear and self:AcquirePerson() or nil
                        if p then
                            local ax,az=point(route,offset,start)
                            local bx,bz=point(route,offset,finish)
                            p.path={ax,az,bx,bz}; p.length=finish-start; p.s=at-start
                            p.direction=slot%2==0 and 1 or -1
                            p.x,p.z,p.gaitWeight,p.turn=x,z,0,0
                            p.yaw=math.deg(math.atan((bx-ax)*p.direction,(bz-az)*p.direction))
                            p.node.position=Vector3(x,World.Surface(x,z,"walk",0),z)
                            p.node.rotation=Quaternion(0,p.yaw,0)
                            p.rig:PoseWalk(p.phase,0); visible(p.node,true)
                            self.people[#self.people+1]=p; self.spawned=self.spawned+1; placed=true
                        end
                    end
                    if placed then break end
                end
                if placed then break end
            end
            if placed then break end
        end
        if not placed then break end
    end
end

function Outer:Gap(car,blockers)
    local gap=self.signals:Gap(car,self.cars)
    for _,other in ipairs(self.cars) do
        if other~=car then
            local u,v=localPoint(car,other.x,other.z)
            if v>0 and math.abs(u)<(car.width+other.width)/2+.6 then
                local a=math.rad(other.yaw-car.yaw)
                local extent=math.abs(math.cos(a))*other.length/2+math.abs(math.sin(a))*other.width/2
                gap=math.min(gap,v-car.length/2-extent-2)
            end
            -- 只对真实相交的lane让行；非信号路口，已入场优先于等待车。
            if car.route.axis~=other.route.axis then
                local ns=car.route.axis=="ns" and car or other
                local ew=car.route.axis=="ew" and car or other
                local cx,cz=ns.route.road,ew.route.road
                local across,forward=localPoint(car,cx,cz)
                local oa,of=localPoint(other,cx,cz)
                local stop=other.route.width/2+2+car.length/2
                local occupied=math.abs(other.x-cx)<other.length/2+car.route.width/2+1 and math.abs(other.z-cz)<other.length/2+car.route.width/2+1
                if not Signals.Find(cx,cz) and math.abs(across)<car.route.width/2 and math.abs(oa)<other.route.width/2 and forward>=stop-.02
                    and (occupied or (car.route.axis=="ns" and of>0 and of<35)) then
                    gap=math.min(gap,math.max(0,forward-stop))
                end
            end
        end
    end
    for _,b in ipairs(blockers) do
        local u,v=localPoint(car,b.x,b.z)
        if v>=0 and math.abs(u)<car.width/2+b.radius+.5 then gap=math.min(gap,v-car.length/2-b.radius-1.4) end
    end
    return math.max(0,gap)
end
function Outer:Step(dt,blockers)
    if self.disposed or dt<=0 or dt~=dt or dt==math.huge then return end
    self.steps=self.steps+1
    self.time=self.time+dt
    self.signals:SetTime(self.time)
    for _,car in ipairs(self.cars) do
        local gap=self:Gap(car,blockers)
        local target=math.min(car.cruise,math.sqrt(gap*5))
        local straight=car.route.finish-car.route.start
        local arc=math.pi*car.route.radius
        local length=2*straight+2*arc
        local s=car.s%length
        if (s>straight-14 and s<straight+arc) or s>2*straight+arc-14 then target=math.min(target,2.2) end
        local speed=car.speed<target and math.min(target,car.speed+1.8*dt) or math.max(target,car.speed-3.8*dt)
        local travel=math.min((car.speed+speed)*.5*dt,gap)
        -- 最后一次位移被停止线截断时同步归零，下一帧不保留虚假的爬行速度。
        car.speed=travel>=gap-Signals.EPSILON and 0 or speed
        local count=math.max(1,math.ceil(travel/.1))
        for _=1,count do
            local old=car.s
            car.s=(car.s+travel/count)%length
            car.x,car.z,car.yaw=Outer.Pose(car.route,car.s)
            if not self:CarFree(car,blockers) then
                car.s=old; car.x,car.z,car.yaw=Outer.Pose(car.route,old); car.speed=0; break
            end
            car.travelled=car.travelled+travel/count
        end
    end
end
function Outer:Walk(dt,blockers)
    self.poseTime=self.poseTime+dt
    local poseReady=self.poseTime>=1/20
    if poseReady then self.poseTime=self.poseTime%(1/20) end
    for _,p in ipairs(self.people) do
        local candidate=math.max(0,math.min(p.length,p.s+p.direction*p.speed*dt))
        local f=candidate/p.length
        local x,z=p.path[1]+(p.path[3]-p.path[1])*f,p.path[2]+(p.path[4]-p.path[2])*f
        local moved=0
        if p.turn>0 then
            p.turn=math.max(0,p.turn-dt)
            local target=math.deg(math.atan((p.path[3]-p.path[1])*p.direction,(p.path[4]-p.path[2])*p.direction))
            local difference=(target-p.yaw+180)%360-180
            p.yaw=p.yaw+math.max(-120*dt,math.min(120*dt,difference))
        elseif self:PersonFree(x,z,p,blockers) then
            moved=math.abs(candidate-p.s); p.s=candidate; p.x,p.z=x,z
            if candidate==0 or candidate==p.length then p.direction=-p.direction; p.turn=1.6 end
        end
        p.travelled=p.travelled+moved
        local target=moved>.0001 and .8 or 0
        p.gaitWeight=p.gaitWeight+(target-p.gaitWeight)*(1-math.exp(-dt*14))
        if target==0 and p.gaitWeight<.001 then p.gaitWeight=0 end
        p.phase=(p.phase+moved*2*math.pi/Rig.CycleLength(p.gaitWeight,0))%(2*math.pi)
        p.node.position=Vector3(p.x,World.Surface(p.x,p.z,"walk",0),p.z)
        p.node.rotation=Quaternion(0,p.yaw,0)
        if poseReady and distance2(p.x,p.z,self.actor)<110^2 then p.rig:PoseWalk(p.phase,p.gaitWeight) end
    end
end
function Outer:Update(dt,blockers)
    if self.disposed or self.city.space~="city" or not self.owner.active or dt<=0 or dt~=dt or dt==math.huge then return end
    self.active=not oldArea(self.actor.x,self.actor.z)
    -- City:SetSpace会递归启用子节点，故每次恢复只让inUse槽位可见。
    visible(self.root,self.active)
    for _,car in ipairs(self.carPool) do visible(car.node,car.inUse and self.active) end
    for _,p in ipairs(self.peoplePool) do visible(p.node,p.inUse and self.active) end
    self.signals:Update(self.time,self.actor.x,self.actor.z,self.active)
    if not self.active then
        for i=#self.cars,1,-1 do self:ReleaseCar(i) end
        for i=#self.people,1,-1 do self:ReleasePerson(i) end
        return
    end
    local viewport=renderer:GetViewport(0)
    self.camera=viewport and viewport:GetCamera() or nil
    local duration=math.min(dt,.25)
    self.scanTime=self.scanTime+duration
    for i=#self.cars,1,-1 do
        local c=self.cars[i]
        if distance2(c.x,c.z,self.actor)>Outer.CAR_RANGE^2 then self:ReleaseCar(i) end
    end
    for i=#self.people,1,-1 do
        local p=self.people[i]
        if distance2(p.x,p.z,self.actor)>Outer.PEOPLE_RANGE^2 then self:ReleasePerson(i) end
    end
    if self.scanTime>=1 or (self.actor.x-self.scanX)^2+(self.actor.z-self.scanZ)^2>64^2 then
        self.scanTime=0; self:Scan(); self:Fill(blockers)
    end
    local count=math.max(1,math.ceil(duration*60))
    for _=1,count do self:Step(duration/count,blockers) end
    for _,car in ipairs(self.cars) do self:ApplyContact(car) end
    self:Walk(duration,blockers)
end
function Outer:Hint(x,z,yaw)
    if self.disposed then return nil end
    return self.signals:Hint(x,z,yaw)
end
function Outer:Stats()
    return {cars=#self.cars,people=#self.people,carBudget=Outer.CAR_BUDGET,peopleBudget=Outer.PEOPLE_BUDGET,
        pooledCars=#self.carPool,pooledPeople=#self.peoplePool,lanes=#self.lanes,active=self.active,disposed=self.disposed,
        time=self.time,spawned=self.spawned,recycled=self.recycled,rejected=self.rejected,contactSolves=self.contactSolves,
        steps=self.steps,legacyFrozen=not self.owner.nearOld,signalized=true,
        signalJunctions=#Signals.Junctions,signals=self.signals:Stats(),signalCoverage="district-centres-only"}
end
function Outer:Dispose()
    if self.disposed then return end
    self.disposed=true; self.active=false
    self.signals:Dispose()
    for _,p in ipairs(self.peoplePool) do p.rig:Dispose() end
    self.root:Dispose()
    self.cars,self.people,self.carPool,self.peoplePool,self.lanes={},{},{},{},{}
    self.camera=nil
end
return Outer
