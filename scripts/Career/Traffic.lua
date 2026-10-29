-- 车道交通与玩家共用City.Move碰撞域，不引入第二套刚体移动。
local Routes=require("Career.TrafficRoutes")
local Assets=require("VehicleAssets")
local Pedestrians=require("Career.Pedestrians")
local Contact=require("Career.VehicleContact")
local OuterTraffic=require("Career.OuterTraffic")
local Motion=require("Career.TrafficMotion")
local Collision=require("Career.FootprintCollision")
---@class CityTraffic
---@field cars table[]
---@field IsFree fun(self:CityTraffic,x:number,z:number,r:number):boolean
---@field Update fun(self:CityTraffic,dt:number)
---@field Dispose fun(self:CityTraffic)
local Traffic={}
Traffic.__index=Traffic
Traffic.Resources=Assets.ResourcesFor(Assets.TrafficIds)
Traffic.ResourceTypes={}
for _,path in ipairs(Traffic.Resources) do Traffic.ResourceTypes[path]=Assets.ResourceTypes[path] end
for _,path in ipairs(Pedestrians.Resources) do Traffic.Resources[#Traffic.Resources+1]=path; Traffic.ResourceTypes[path]=Pedestrians.ResourceTypes[path] end

-- 碰撞示意（米，俯视）：
--       停止线 z=-12       路口中心0       停止线z=12
--           |      [-6..6车道交叉区]      |
--   车OBB半长L/2、半宽W/2；玩家圆r=.32/车辆圈r>=1.2。
--   每<=1/60秒先决定速度，再以<=.10m子步试探；OBB/圆不重叠才提交。
--   红黄灯以车头而非车心停线；已越线车辆清空路口，异向绿灯仍检查占用。
--   跟车用前后包围盒+2m余量；最后碰撞兜底处理玩家突然切入、掉头和斜向擦边。
--   静止玩家/停放车辆不会被推走。路人只走人行道，遇人让停，不扣钱或改玩家档。
local function localPoint(car,x,z)
    local a=math.rad(car.yaw)
    local dx,dz=x-car.x,z-car.z
    return dx*math.cos(a)-dz*math.sin(a),dx*math.sin(a)+dz*math.cos(a)
end
Traffic.CircleFree=Motion.CircleFree
Traffic.Separate=Motion.Separate
Traffic.Shape=Motion.Shape
---@param city CareerCity
---@param actor CareerActor
---@return CityTraffic
function Traffic.New(city,actor)
    local self=setmetatable({},Traffic)
    self:Init(city,actor)
    return self
end
function Traffic:Init(city,actor)
    self.city,self.actor=city,actor
    self.root=city.root:CreateChild("老街动态交通")
    -- 室内读档时，后创建的交通节点也必须继承城市层隐藏状态。
    self.root:SetEnabledRecursive(city.space=="city")
    self.cars={}
    self.time,self.active,self.disposed=0,true,false
    self.nearOld=math.abs(actor.x)<=OuterTraffic.OLD_MARGIN and math.abs(actor.z)<=OuterTraffic.OLD_MARGIN
    self.pedestrians=Pedestrians.New(self.root,city)
    local blockers=self:Blockers()
    for ri,route in ipairs(Routes.List) do
        for n=1,3 do
            local id=Assets.TrafficIds[(ri+n-2)%#Assets.TrafficIds+1]
            local node=Assets.Add(self.root,id,nil,"distant")
            if id=="truck" then Contact.CompleteTruck(node) end
            local size=node:GetVar("VehicleSize"):GetVector3()
            local car={id=id,node=node,route=route,routeId=ri,s=35+(n-1)*200+ri*7,x=0,z=0,yaw=0,speed=0,cruise=5.5+(ri+n)%3,length=size.z,width=size.x}
            local placed=false
            for _=1,80 do
                self:Place(car)
                if self:CanPlace(car,blockers) then placed=true; break end
                car.s=car.s+8
            end
            assert(placed,"交通生成点无可用空间")
            self.cars[#self.cars+1]=car
        end
    end
    -- 外区池是city.root的同级子树，不加入老街self.cars/self.pedestrians。
    self.outer=OuterTraffic.New(self)
    self.root:SetEnabledRecursive(city.space=="city")
    print(string.format("[老街交通] %d辆贴图车辆 / %d位独立便服行人 / 6个实体信号路口；不改玩家存档",#self.cars,#self.pedestrians.people))
end
function Traffic:Blockers()
    local a=self.actor
    local list={{x=a.x,z=a.z,radius=a.mounted and a:VehicleRadius() or .32,
        shape=Collision.Pose(a:Footprint(),a.x,a.z,a.yaw)}}
    local function park(id,x,z,yaw,radius)
        list[#list+1]={x=x,z=z,radius=radius,shape=require("Career.VehicleFootprints").At(id,x,z,yaw)}
    end
    if not a.mounted then park(a.vehicleId,a.bikeX,a.bikeZ,a.bikeYaw,a:VehicleRadius()) end
    for id,p in pairs(a.parking) do
        if id~=a.vehicleId then park(id,p.x,p.z,p.yaw,require("Career.VehicleData").Radii[id]) end
    end
    local people=self.city.deliveryPeople
    if people then
        for _,person in ipairs(people.people) do
            if person.active or person.hold>0 then list[#list+1]={x=person.x,z=person.z,radius=.4} end
        end
    end
    if self.city.crowd then
        for _,b in ipairs(self.city.crowd:GetBlockers()) do list[#list+1]=b end
    end
    return list
end
function Traffic:ApplyContact(car)
    if car.contactX==car.x and car.contactZ==car.z and car.contactYaw==car.yaw and car.contactSpace==self.city.space then return end
    local height,pitch,roll=Contact.Solve(self.city,car.id,car.x,car.z,car.yaw,0)
    car.node.position=Vector3(car.x,height,car.z)
    car.node.rotation=Quaternion(0,car.yaw,0)*Quaternion(pitch,Vector3.RIGHT)*Quaternion(roll,Vector3.FORWARD)
    car.contactX,car.contactZ,car.contactYaw,car.contactSpace=car.x,car.z,car.yaw,self.city.space
end
function Traffic:Place(car)
    car.x,car.z,car.yaw=Routes.Pose(car.route,car.s)
    self:ApplyContact(car)
end
function Traffic:CanPlace(car,blockers)
    if self.city.space=="city" and not OuterTraffic.StaticFree(self.city,car) then return false end
    if self.outer and not self.outer:Separate(car) then return false end
    for _,other in ipairs(self.cars) do if other~=car and not Traffic.Separate(car,other) then return false end end
    for _,b in ipairs(blockers) do if not Motion.BlockerFree(car,b) then return false end end
    for _,p in ipairs(self.pedestrians.people) do if not Traffic.CircleFree(car,p.x,p.z,p.radius) then return false end end
    return true
end
function Traffic:CollisionShapes(result,area,dx,dz)
    local function carList(cars)
        for _,car in ipairs(cars) do
            local reach=(car.length+car.width)/2
            if car.x+reach>=math.min(area.x1,area.x1+dx)-.01 and car.x-reach<=math.max(area.x2,area.x2+dx)+.01
                and car.z+reach>=math.min(area.z1,area.z1+dz)-.01 and car.z-reach<=math.max(area.z2,area.z2+dz)+.01 then
                result[#result+1]=Motion.Shape(car)
            end
        end
    end
    carList(self.cars)
    for _,p in ipairs(self.pedestrians.people) do result[#result+1]=Collision.Circle(p.x,p.z,p.radius) end
    if self.outer and not self.outer.disposed then
        carList(self.outer.cars)
        for _,p in ipairs(self.outer.people) do result[#result+1]=Collision.Circle(p.x,p.z,p.radius) end
    end
end
function Traffic:IsFree(x,z,r)
    if not self.active or self.city.space~="city" then return true end
    local shape=Collision.Circle(x,z,r)
    local others={}
    self:CollisionShapes(others,shape,0,0)
    for _,other in ipairs(others) do if not Collision.Free(shape,other,Collision.SKIN) then return false end end
    return true
end
function Traffic:CrossingBusy(car)
    for _,j in ipairs(Routes.Junctions) do
        if (car.route.axis=="ns" and car.route.road==j.x) or (car.route.axis=="ew" and car.route.road==j.z) then
            for _,other in ipairs(self.cars) do
                if other.route.axis~=car.route.axis and math.abs(other.x-j.x)<9+other.length/2 and math.abs(other.z-j.z)<9+other.length/2 then return true end
            end
        end
    end
    return false
end
function Traffic:Step(dt,blockers)
    self.time=self.time+dt
    self.city.signals:Update(self.time)
    for _,car in ipairs(self.cars) do
        local gap=math.huge
        if Routes.Signal(self.time,car.route.axis)~="green" or self:CrossingBusy(car) then gap=Routes.StopGap(car.route,car.s,car.length) end
        for _,other in ipairs(self.cars) do
            if other~=car then
                local u,v=localPoint(car,other.x,other.z)
                if v>0 and math.abs(u)<(car.width+other.width)/2+.5 then gap=math.min(gap,v-(car.length+other.length)/2-2) end
            end
        end
        for _,b in ipairs(blockers) do
            local u,v=localPoint(car,b.x,b.z)
            if v>=0 and math.abs(u)<car.width/2+b.radius+.5 then gap=math.min(gap,v-car.length/2-b.radius-1.4) end
        end
        local target=math.min(car.cruise,math.sqrt(math.max(0,gap)*5))
        -- 在掉头弧之前提前减到8km/h，车身不在路端瞬时翻转。
        local s=car.s%Routes.LENGTH
        if (s>Routes.STRAIGHT-12 and s<Routes.STRAIGHT+Routes.ARC) or s>2*Routes.STRAIGHT+Routes.ARC-12 then target=math.min(target,2.2) end
        local speed=car.speed<target and math.min(target,car.speed+1.8*dt) or math.max(target,car.speed-3.8*dt)
        local travel=math.min((car.speed+speed)*.5*dt,math.max(0,gap))
        car.speed=speed
        local count=math.max(1,math.ceil(travel/.1))
        for _=1,count do
            local old=car.s
            car.s=(car.s+travel/count)%Routes.LENGTH
            car.x,car.z,car.yaw=Routes.Pose(car.route,car.s)
            if not self:CanPlace(car,blockers) then
                car.s=old
                car.x,car.z,car.yaw=Routes.Pose(car.route,car.s)
                car.speed=0; break
            end
        end
    end
end
function Traffic:Update(dt)
    if not self.active or self.disposed or self.city.space~="city" or dt<=0 or dt~=dt then return end
    local duration=math.min(dt,.25)
    local blockers=self:Blockers()
    -- 老街保留15车/8人结构，离开±220m后时钟、位移、步态和胎面均冻结。
    -- 无追帧；重返后从原位继续。450m外不会继续大量采样老街轮胎。
    self.nearOld=math.abs(self.actor.x)<=OuterTraffic.OLD_MARGIN and math.abs(self.actor.z)<=OuterTraffic.OLD_MARGIN
    -- 仅冻结远景，不在220m边界突然隐去：全部老街实体离开450m视距后才递归隐藏。
    local dx,dz=math.max(0,math.abs(self.actor.x)-180),math.max(0,math.abs(self.actor.z)-180)
    local showOld=dx*dx+dz*dz<=450^2
    if self.root:IsEnabled()~=showOld then self.root:SetEnabledRecursive(showOld) end
    if self.nearOld then
        local count=math.max(1,math.ceil(duration*60))
        for _=1,count do self:Step(duration/count,blockers) end
        for _,car in ipairs(self.cars) do self:ApplyContact(car) end
        self.pedestrians:Update(duration,blockers)
    end
    self.outer:Update(duration,blockers)
end
function Traffic:Hint(x,z,yaw)
    local outer=self.outer --[[@as CareerOuterTraffic]]
    local outerHint=outer and outer:Hint(x,z,yaw)
    if outerHint then return outerHint end
    local axis=math.abs(math.cos(math.rad(yaw)))>=.7 and "ns" or "ew"
    local best=math.huge
    for _,j in ipairs(Routes.Junctions) do
        local across=axis=="ns" and math.abs(x-j.x) or math.abs(z-j.z)
        local forward=axis=="ns" and (j.z-z)*math.cos(math.rad(yaw)) or (j.x-x)*math.sin(math.rad(yaw))
        if across<6 and forward>7 and forward<45 then best=math.min(best,forward) end
    end
    if best==math.huge then return nil end
    local signal=Routes.Signal(self.time,axis)
    return signal=="green" and "前方绿灯 · 留意路口车辆和行人" or signal=="yellow" and "前方黄灯 · 减速，在停止线前等候" or "前方红灯 · 在白色停止线前等候"
end
function Traffic:Dispose()
    if self.disposed then return end
    self.disposed=true; self.active=false
    self.outer:Dispose()
    for _,p in ipairs(self.pedestrians.people) do p.rig:Dispose() end
    self.root:Dispose()
end
return Traffic
