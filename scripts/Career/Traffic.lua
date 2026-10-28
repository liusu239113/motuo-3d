-- 车道交通与玩家共用City.Move碰撞域，不引入第二套刚体移动。
local Routes=require("Career.TrafficRoutes")
local Assets=require("VehicleAssets")
local Pedestrians=require("Career.Pedestrians")
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
function Traffic.CircleFree(car,x,z,r)
    local u,v=localPoint(car,x,z)
    local dx=math.max(0,math.abs(u)-car.width/2)
    local dz=math.max(0,math.abs(v)-car.length/2)
    return dx*dx+dz*dz>=(r+.08)^2
end
-- 四个分离轴的OBB检测，不能用车心距离替代长货车碰撞。
function Traffic.Separate(a,b)
    for _,yaw in ipairs({a.yaw,a.yaw+90,b.yaw,b.yaw+90}) do
        local angle=math.rad(yaw)
        local nx,nz=math.sin(angle),math.cos(angle)
        local function extent(c)
            local t=math.rad(c.yaw)
            return math.abs(nx*math.sin(t)+nz*math.cos(t))*c.length/2+math.abs(nx*math.cos(t)-nz*math.sin(t))*c.width/2
        end
        if math.abs((b.x-a.x)*nx+(b.z-a.z)*nz)>extent(a)+extent(b)+.12 then return true end
    end
    return false
end
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
    self.root.enabled=city.space=="city"
    self.cars={}
    self.time,self.active,self.disposed=0,true,false
    self.pedestrians=Pedestrians.New(self.root,city)
    local blockers=self:Blockers()
    for ri,route in ipairs(Routes.List) do
        for n=1,3 do
            local id=Assets.TrafficIds[(ri+n-2)%#Assets.TrafficIds+1]
            local node=Assets.Add(self.root,id,nil,"distant")
            local size=node:GetVar("VehicleSize"):GetVector3()
            local car={node=node,route=route,routeId=ri,s=35+(n-1)*200+ri*7,x=0,z=0,yaw=0,speed=0,cruise=5.5+(ri+n)%3,length=size.z,width=size.x}
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
    print(string.format("[老街交通] %d辆贴图车辆 / %d位独立便服行人 / 6个实体信号路口；不改玩家存档",#self.cars,#self.pedestrians.people))
end
function Traffic:Blockers()
    local a=self.actor
    local list={{x=a.x,z=a.z,radius=a.mounted and a:VehicleRadius() or .32}}
    if not a.mounted then list[#list+1]={x=a.bikeX,z=a.bikeZ,radius=a:VehicleRadius()} end
    for id,p in pairs(a.parking) do
        if id~=a.vehicleId then list[#list+1]={x=p.x,z=p.z,radius=require("Career.VehicleData").Radii[id]} end
    end
    return list
end
function Traffic:Place(car)
    car.x,car.z,car.yaw=Routes.Pose(car.route,car.s)
    -- 轿车/SUV轴位由最低胎面顶点测得；货车底盘含低垂附件，暂保留中心查高。
    local front,rear=0,0
    if car.node.name:find("sedan") then front,rear=1.35029,-1.26928 end
    if car.node.name:find("suv") then front,rear=1.41184,-1.508415 end
    local height,pitch=self.city:Surface(car.x,car.z),0
    if front>0 then height,pitch=self.city:VehicleSurface(car.x,car.z,car.yaw,front,rear) end
    car.node.position=Vector3(car.x,height,car.z)
    car.node.rotation=Quaternion(0,car.yaw,0)*Quaternion(pitch or 0,Vector3.RIGHT)
end
function Traffic:CanPlace(car,blockers)
    for _,other in ipairs(self.cars) do if other~=car and not Traffic.Separate(car,other) then return false end end
    for _,b in ipairs(blockers) do if not Traffic.CircleFree(car,b.x,b.z,b.radius) then return false end end
    for _,p in ipairs(self.pedestrians.people) do if not Traffic.CircleFree(car,p.x,p.z,p.radius) then return false end end
    return true
end
function Traffic:IsFree(x,z,r)
    if not self.active or self.city.space~="city" then return true end
    for _,car in ipairs(self.cars) do if not Traffic.CircleFree(car,x,z,r) then return false end end
    for _,p in ipairs(self.pedestrians.people) do if (x-p.x)^2+(z-p.z)^2<(r+p.radius)^2 then return false end end
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
            self:Place(car)
            if not self:CanPlace(car,blockers) then
                car.s=old; self:Place(car); car.speed=0; break
            end
        end
    end
end
function Traffic:Update(dt)
    if not self.active or self.disposed or self.city.space~="city" or dt<=0 then return end
    local duration=math.min(dt,.25)
    local count=math.max(1,math.ceil(duration*60))
    local blockers=self:Blockers()
    for _=1,count do self:Step(duration/count,blockers) end
    -- 骨骼每个外层帧仅求解一次；车辆仍保留60Hz碰撞子步。
    self.pedestrians:Update(duration,blockers)
end
function Traffic:Hint(x,z,yaw)
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
    for _,p in ipairs(self.pedestrians.people) do p.rig:Dispose() end
    self.root:Dispose()
end
return Traffic
