-- 车道交通与玩家共用City.Move碰撞域，不引入第二套刚体移动。
local Routes=require("Career.TrafficRoutes")
local Assets=require("VehicleAssets")
local Pedestrians=require("Career.Pedestrians")
local Contact=require("Career.VehicleContact")
local OuterTraffic=require("Career.OuterTraffic")
local Motion=require("Career.TrafficMotion")
local Riders=require("Career.TrafficRiders")
local Collision=require("Career.FootprintCollision")
local DisplayLod=require("Career.BuildingLod")
---@class CityTraffic
---@field cars table[]
---@field IsFree fun(self:CityTraffic,x:number,z:number,r:number):boolean
---@field Update fun(self:CityTraffic,dt:number)
---@field Dispose fun(self:CityTraffic)
local Traffic={}
Traffic.__index=Traffic
-- 临时交通分项计时：定位卡顿来源后整段删除。
local tpOrder_={"blockers","ticks","contact","peds","lods","outer"}
local tpAcc_,tpFrames_,tpSeconds_,tpLast_={},0,0,0
local function tpMark(name)
    local now=os.clock()
    if tpLast_>0 then tpAcc_[name]=(tpAcc_[name] or 0)+(now-tpLast_) end
    tpLast_=now
end
Traffic.Resources=Assets.ResourcesFor(Assets.TrafficIds)
Traffic.ResourceTypes={}
for _,path in ipairs(Traffic.Resources) do Traffic.ResourceTypes[path]=Assets.ResourceTypes[path] end
for _,pack in ipairs({Pedestrians,Riders}) do
    for _,path in ipairs(pack.Resources) do
        if not Traffic.ResourceTypes[path] then Traffic.Resources[#Traffic.Resources+1]=path end
        Traffic.ResourceTypes[path]=pack.ResourceTypes[path]
    end
end

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

Traffic.PersonInterval=Motion.PersonInterval
Traffic.VehicleInterval=Motion.VehicleInterval
Traffic.VerticalOverlap=Motion.VerticalOverlap
function Traffic:BlockerOverlaps(car,b) return Motion.BlockerOverlaps(self.city,car,b) end
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
    self.tickCarry=0
    print("[老街交通时钟] 固定60Hz累计步；保留不足一步余时，不限追步；离开老街清余，碰撞仍逐<=0.10m检测")
    self.nearOld=math.abs(actor.x)<=OuterTraffic.OLD_MARGIN and math.abs(actor.z)<=OuterTraffic.OLD_MARGIN
    self.pedestrians=Pedestrians.New(self.root,city)
    local blockers=self:Blockers()
    for ri,route in ipairs(Routes.List) do
        for n=1,3 do
            local id=Assets.TrafficIds[(ri+n-2)%#Assets.TrafficIds+1]
            -- Only two existing slots near the central street; no extra city instances.
            -- id stays nil on rider records intentionally: TrafficMotion then uses
            -- their measured composite OBB in every caller (also Crowd/LocalWalk).
            local riderId=ri==2 and n==1 and Riders.MOTORCYCLE or ri==4 and n==1 and Riders.DELIVERY or nil
            ---@type TrafficRiderVisual?
            local riding=riderId and Riders.Add(self.root,riderId) or nil
            local node=riding and riding.node or Assets.Add(self.root,id,nil,"distant")
            if not riding and id=="truck" then Contact.CompleteTruck(node) end
            local size=riding and Vector3(riding.width,0,riding.length) or node:GetVar("VehicleSize"):GetVector3()
            local car={id=not riding and id or nil,vehicleId=riderId or id,riding=riding,node=node,route=route,routeId=ri,
                s=riding and (ri==2 and 117 or 137) or 35+(n-1)*200+ri*7,x=0,z=0,yaw=0,speed=0,
                cruise=riding and 5.5 or 5.5+(ri+n)%3,length=size.z,width=size.x}
            local placed=false
            for _=1,80 do
                self:Place(car)
                if self:CanPlace(car,blockers) then placed=true; break end
                car.s=car.s+8
            end
            assert(placed,"交通生成点无可用空间")
            car.displayLods={}
            if not riding then
                DisplayLod.Vehicle(node,car.displayLods,car.x,car.z)
                DisplayLod.Update(car.displayLods,actor.x,actor.z)
            end
            self.cars[#self.cars+1]=car
        end
    end
    -- 外区池是city.root的同级子树，不加入老街self.cars/self.pedestrians。
    self.outer=OuterTraffic.New(self)
    self.root:SetEnabledRecursive(city.space=="city")
    print(string.format("[老街交通] %d个车辆槽（13汽车+1摩托骑手+1配送骑手） / %d位独立便服行人；外区6汽车不扩容；不改玩家存档",#self.cars,#self.pedestrians.people))
end
function Traffic:Blockers()
    local a=self.actor
    local low,high
    if a.mounted then low,high=Traffic.VehicleInterval(self.city,{x=a.x,z=a.z,vehicleId=a.vehicleId})
    else low,high=Traffic.PersonInterval(self.city,{x=a.x,z=a.z,height=self.city:WalkSurface(a.x,a.z,a.walkHeight)}) end
    local list={{x=a.x,z=a.z,radius=a.mounted and a:VehicleRadius() or .32,height=low,y1=low,y2=high,
        shape=Collision.Pose(a:Footprint(),a.x,a.z,a.yaw)}}
    local function park(id,x,z,yaw,radius)
        local y1,y2=Traffic.VehicleInterval(self.city,{x=x,z=z,vehicleId=id})
        list[#list+1]={x=x,z=z,radius=radius,height=y1,y1=y1,y2=y2,shape=require("Career.VehicleFootprints").At(id,x,z,yaw)}
    end
    if not a.mounted then park(a.vehicleId,a.bikeX,a.bikeZ,a.bikeYaw,a:VehicleRadius()) end
    for id,p in pairs(a.parking) do
        if id~=a.vehicleId then park(id,p.x,p.z,p.yaw,require("Career.VehicleData").Radii[id]) end
    end
    local people=self.city.deliveryPeople
    if people then
        for _,person in ipairs(people.people) do
            if person.active or person.hold>0 then
                local y1,y2=Traffic.PersonInterval(self.city,person)
                list[#list+1]={x=person.x,z=person.z,radius=.4,height=y1,y1=y1,y2=y2}
            end
        end
    end
    if self.city.crowd then
        for _,b in ipairs(self.city.crowd:GetBlockers()) do list[#list+1]=b end
    end
    return list
end
function Traffic:ApplyContact(car)
    if car.contactX==car.x and car.contactZ==car.z and car.contactYaw==car.yaw and car.contactSpace==self.city.space then return end
    local height,pitch,roll=Contact.Solve(self.city,car.vehicleId or car.id,car.x,car.z,car.yaw,0)
    car.node.position=Vector3(car.x,height,car.z)
    car.node.rotation=Quaternion(0,car.yaw,0)*Quaternion(pitch,Vector3.RIGHT)*Quaternion(roll,Vector3.FORWARD)
    car.contactX,car.contactZ,car.contactYaw,car.contactSpace=car.x,car.z,car.yaw,self.city.space
end
function Traffic:Place(car)
    car.x,car.z,car.yaw=Routes.Pose(car.route,car.s)
    self:ApplyContact(car)
end
-- 静态城市几何在一次城市生命周期内不变，而老街车辆位姿由 Pose(route,s) 唯一决定，
-- 因此同一路线位置的静态通畅结论可长期复用；位姿与路线不一致时（外部摆放）不缓存。
local STATIC_CACHE_STEP=0.5
local staticCalls_,staticHits_=0,0
local function routeStaticKey(car)
    if not car.route or car.s==nil then return nil end
    local s=car.s%Routes.LENGTH
    local ok,x,z,yaw=pcall(Routes.Pose,car.route,s)
    if not ok or car.x~=x or car.z~=z or car.yaw~=yaw then return nil end
    return math.floor(s/STATIC_CACHE_STEP+.5)
end
function Traffic:StaticFree(car)
    staticCalls_=staticCalls_+1
    local key=routeStaticKey(car)
    if not key then return Motion.StaticFree(self.city,car) end
    local cache=car.staticFreeCache
    if not cache then cache={};car.staticFreeCache=cache end
    local free=cache[key]
    if free==nil then
        free=Motion.StaticFree(self.city,car)
        cache[key]=free
    else
        staticHits_=staticHits_+1
    end
    return free
end
function Traffic:CanPlace(car,blockers)
    -- 远车只沿路线推进：静态墙和行人判定只对玩家附近的车做（路线固定，不会驶离车道）。
    local actor=self.actor
    local near=not actor or (car.x-actor.x)^2+(car.z-actor.z)^2<=70^2
    if near and self.city.space=="city" and not self:StaticFree(car) then return false end
    if self.outer and not self.outer:Separate(car) then return false end
    for _,other in ipairs(self.cars) do if other~=car and not Traffic.Separate(car,other) then return false end end
    for _,b in ipairs(blockers) do if not Motion.BlockerFree(car,b,self.city) then return false end end
    if near then
        for _,p in ipairs(self.pedestrians.people) do if not Traffic.CircleFree(car,p.x,p.z,p.radius,self.city,p.height) then return false end end
    end
    return true
end
function Traffic:CollisionShapes(result,area,dx,dz,mode,height)
    local x,z=(area.x1+area.x2)/2,(area.z1+area.z2)/2
    local low=height or self.city:Surface(x,z)
    local high=low+1.8
    local function overlaps(y1,y2) return Traffic.VerticalOverlap(low,high,y1,y2) end
    local function carList(cars)
        for _,car in ipairs(cars) do
            local reach=(car.length+car.width)/2
            if car.x+reach>=math.min(area.x1,area.x1+dx)-.01 and car.x-reach<=math.max(area.x2,area.x2+dx)+.01
                and car.z+reach>=math.min(area.z1,area.z1+dz)-.01 and car.z-reach<=math.max(area.z2,area.z2+dz)+.01 then
                local y1,y2=Traffic.VehicleInterval(self.city,car)
                if overlaps(y1,y2) then result[#result+1]=Motion.Shape(car) end
            end
        end
    end
    local function peopleList(people)
        for _,p in ipairs(people) do
            if p.x+p.radius>=math.min(area.x1,area.x1+dx)-.01 and p.x-p.radius<=math.max(area.x2,area.x2+dx)+.01
                and p.z+p.radius>=math.min(area.z1,area.z1+dz)-.01 and p.z-p.radius<=math.max(area.z2,area.z2+dz)+.01 then
                local y1,y2=Traffic.PersonInterval(self.city,p)
                if overlaps(y1,y2) then result[#result+1]=Collision.Circle(p.x,p.z,p.radius) end
            end
        end
    end
    carList(self.cars)
    peopleList(self.pedestrians.people)
    if self.outer and not self.outer.disposed then
        carList(self.outer.cars)
        peopleList(self.outer.people)
    end
end
function Traffic:IsFree(x,z,r,height)
    if not self.active or self.city.space~="city" then return true end
    local shape=Collision.Circle(x,z,r)
    local others={}
    self:CollisionShapes(others,shape,0,0,"walk",height)
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
            if v>=0 and math.abs(u)<car.width/2+b.radius+.5 and self:BlockerOverlaps(car,b) then gap=math.min(gap,v-car.length/2-b.radius-1.4) end
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
-- One fixed tick remains the original Step (same signal/gap ordering and
-- <=.10m collision substeps). Only the rendering-frame partition is changed.
-- Fractional time is retained, never rounded up into a second 8.5ms step for
-- a 17ms frame. Near-old freezing deliberately discards only its <1tick carry.
-- 30Hz逻辑步：帧率低时同样的真实时间只需一半的补跑次数，
-- 车流速度仍走真实时间轴；Step内部仍按0.1m做碰撞子步，精度不变。
local FIXED_TICK=1/30
-- 低帧率时必须补足真实时间：补不够会让整条街的车变成龟速（世界变慢）。
-- 只设一个足够宽松的上限防止极端卡顿时雪崩，正常15~60FPS都在真实时间轴上。
local function maxTicksPerFrame(duration)
    local need = math.ceil((duration or 0) / FIXED_TICK) + 1
    return math.max(need, require("Career.AdaptiveQuality").TrafficTicks())
end
function Traffic:AdvanceTicks(duration,blockers,nearOld)
    if not nearOld then self.tickCarry=0;return 0 end
    local remaining=(self.tickCarry or 0)+duration
    local count=0
    local limit=math.min(maxTicksPerFrame(duration),24)
    while remaining>=FIXED_TICK and count<limit do
        self:Step(FIXED_TICK,blockers)
        remaining=remaining-FIXED_TICK
        count=count+1
    end
    if remaining>=FIXED_TICK then remaining=FIXED_TICK end
    self.tickCarry=remaining
    return count
end
function Traffic:Update(dt)
    if not self.active or self.disposed or self.city.space~="city" or dt<=0 or dt~=dt then return end
    local duration=math.min(dt,.25)
    tpLast_=os.clock()
    local blockers=self:Blockers()
    tpMark("blockers")
    Motion.BeginStaticScope(self.city)
    local ok,message=pcall(self.UpdateScoped,self,duration,blockers)
    Motion.EndStaticScope()
    if not ok then error(message,0) end
    tpFrames_=tpFrames_+1
    tpSeconds_=tpSeconds_+duration
    if tpSeconds_>=5 then
        local out={}
        for i,name in ipairs(tpOrder_) do out[i]=string.format("%s=%.1f",name,(tpAcc_[name] or 0)*1000/tpFrames_) end
        print(string.format("[交通分项] 帧数=%d %s | 静态查询=%d 命中=%d | ms/帧",tpFrames_,table.concat(out," "),staticCalls_,staticHits_))
        tpAcc_,tpFrames_,tpSeconds_={},0,0
        staticCalls_,staticHits_=0,0
    end
end
-- 即使推进抛错也由Update释放同步静态缓存；不吞掉原错误。
function Traffic:UpdateScoped(duration,blockers)
    -- 老街保留15车/8人结构，离开±220m后时钟、位移、步态和胎面均冻结。
    -- 无追帧；重返后从原位继续。450m外不会继续大量采样老街轮胎。
    self.nearOld=math.abs(self.actor.x)<=OuterTraffic.OLD_MARGIN and math.abs(self.actor.z)<=OuterTraffic.OLD_MARGIN
    -- 仅冻结远景，不在220m边界突然隐去：全部老街实体离开450m视距后才递归隐藏。
    local dx,dz=math.max(0,math.abs(self.actor.x)-180),math.max(0,math.abs(self.actor.z)-180)
    local showOld=dx*dx+dz*dz<=450^2
    if self.root:IsEnabled()~=showOld then self.root:SetEnabledRecursive(showOld) end
    tpLast_=os.clock()
    self:AdvanceTicks(duration,blockers,self.nearOld)
    tpMark("ticks")
    if self.nearOld then
        -- 远车不做轮胎接地解算（四次地形采样）：沿用上次高度直接摆位，位置仍随路线更新。
        local ax,az=self.actor.x,self.actor.z
        for _,car in ipairs(self.cars) do
            if (car.x-ax)^2+(car.z-az)^2<=70^2 then
                self:ApplyContact(car)
            elseif car.node then
                car.node.position=Vector3(car.x,car.contactY or car.node.position.y,car.z)
                car.node.rotation=Quaternion(0,car.yaw,0)
            end
        end
        tpMark("contact")
        self.pedestrians:Update(duration,blockers)
        tpMark("peds")
    end
    -- 只切显示网格，不停碰撞或移动；屏外老街仍保留原有位置/车型。
    for _,car in ipairs(self.cars) do
        for _,entry in ipairs(car.displayLods or {}) do entry.x,entry.z=car.x,car.z end
        DisplayLod.Update(car.displayLods or {},self.actor.x,self.actor.z)
    end
    tpMark("lods")
    self.outer:Update(duration,blockers)
    tpMark("outer")
end
-- Explicit restore hook. Saved static parking has priority over ephemeral NPCs.
-- Validate a bounded plan first, commit only when every old-street slot has a
-- safe route point. Unrelated legal traffic remains in place; outer pool slots
-- are recycled (not spawned into view) after a successful restore.
function Traffic:ReconcileParking()
    if self.disposed or self.city.space~="city" then return false end
    local blockers=self:Blockers()
    local cars,people,rejectedCars,rejectedPeople={},{},{},{}
    local function carFree(car)
        if not Motion.StaticFree(self.city,car) then return false end
        for _,b in ipairs(blockers) do if not Motion.BlockerFree(car,b,self.city) then return false end end
        for _,other in ipairs(cars) do if not Motion.Separate(car,other,self.city) then return false end end
        return true
    end
    local function personFree(p)
        local y1,y2=Motion.PersonInterval(self.city,p)
        if not self.city:StaticFree(p.x,p.z,p.radius,"walk",y1) then return false end
        for _,b in ipairs(blockers) do
            local low,high=Motion.BlockerInterval(self.city,b)
            if Motion.VerticalOverlap(y1,y2,low,high)
                and not Collision.Free(Collision.Circle(p.x,p.z,p.radius),b.shape or Collision.Circle(b.x,b.z,b.radius),Collision.SKIN) then return false end
        end
        for _,car in ipairs(cars) do if not Motion.CircleFree(car,p.x,p.z,p.radius,self.city,y1) then return false end end
        for _,other in ipairs(people) do
            local low,high=Motion.PersonInterval(self.city,other)
            if Motion.VerticalOverlap(y1,y2,low,high) and (p.x-other.x)^2+(p.z-other.z)^2<(p.radius+other.radius+Collision.SKIN)^2 then return false end
        end
        return true
    end
    local function copy(record)
        local result={}
        for k,v in pairs(record) do result[k]=v end
        return result
    end
    for _,car in ipairs(self.cars) do
        local probe=copy(car);probe.source=car
        if carFree(probe) then cars[#cars+1]=probe else rejectedCars[#rejectedCars+1]=probe end
    end
    for _,probe in ipairs(rejectedCars) do
        local start=probe.s
        local found=false
        for n=1,80 do
            probe.s=(start+n*Routes.LENGTH/80)%Routes.LENGTH
            probe.x,probe.z,probe.yaw=Routes.Pose(probe.route,probe.s)
            if carFree(probe) then cars[#cars+1]=probe;found=true;break end
        end
        assert(found,"No safe traffic slot during parking reconciliation; parking retained")
    end
    for _,p in ipairs(self.pedestrians.people) do
        local probe=copy(p);probe.source=p
        if personFree(probe) then people[#people+1]=probe else rejectedPeople[#rejectedPeople+1]=probe end
    end
    for _,probe in ipairs(rejectedPeople) do
        local found=false
        for n=0,47 do
            probe.s=probe.length*n/47
            local f=probe.s/probe.length
            probe.x,probe.z=probe.path[1]+(probe.path[3]-probe.path[1])*f,probe.path[2]+(probe.path[4]-probe.path[2])*f
            if personFree(probe) then people[#people+1]=probe;found=true;break end
        end
        assert(found,"No safe pedestrian slot during parking reconciliation; parking retained")
    end
    for _,probe in ipairs(cars) do
        local car=probe.source
        if car.s~=probe.s then
            car.s,car.x,car.z,car.yaw,car.speed=probe.s,probe.x,probe.z,probe.yaw,0
            self:ApplyContact(car)
        end
    end
    for _,probe in ipairs(people) do
        local p=probe.source
        if p.x~=probe.x or p.z~=probe.z then
            p.s=probe.s; self.pedestrians:Place(p)
            require("Career.LocalWalk").Reset(p)
            p.gaitWeight=0
        end
    end
    local outer=self.outer --[[@as CareerOuterTraffic?]]
    if outer and not outer.disposed then
        for i=#outer.cars,1,-1 do outer:ReleaseCar(i) end
        for i=#outer.people,1,-1 do outer:ReleasePerson(i) end
    end
    -- Incremental crowd slots can safely retire while the restore screen is up;
    -- otherwise a person initially inside a saved shell cannot sweep out of it.
    local crowd=self.city.crowd
    if crowd then
        local parked=self.actor:ParkedShapes()
        if self.actor.mounted then parked[#parked+1]=Collision.Pose(self.actor:Footprint(),self.actor.x,self.actor.z,self.actor.yaw) end
        for i=#crowd.people,1,-1 do
            local p=crowd.people[i]
            local low,high=Motion.PersonInterval(self.city,p)
            local collides=false
            for _,shape in ipairs(parked) do
                local y=self.city:Surface((shape.x1+shape.x2)/2,(shape.z1+shape.z2)/2)
                if Motion.VerticalOverlap(low,high,y,y+1.85) and not Collision.Free(Collision.Circle(p.x,p.z,p.radius),shape,Collision.SKIN) then collides=true;break end
            end
            if collides then crowd:Retire(i) end
        end
    end
    print(string.format("[停车恢复让位] 老街%d车/%d人重定位；外区动态池已回收；静态停车未移动",#rejectedCars,#rejectedPeople))
    return true
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
    for _,car in ipairs(self.cars) do
        Riders.Dispose(car.riding)
        for _,entry in ipairs(car.displayLods or {}) do DisplayLod.Release(entry.levels) end
    end
    for _,p in ipairs(self.pedestrians.people) do p.rig:Dispose() end
    self.root:Dispose()
end
return Traffic
