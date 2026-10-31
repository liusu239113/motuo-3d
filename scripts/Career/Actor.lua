-- 生涯城市角色：独立步行、电动车动力与停车位置。
-- 城市负责碰撞；Session负责输入、相机、电量与存档，不复用赛车速度参数。
local Visuals = require("Career.ActorVisuals")
local Vehicles = require("Career.VehicleData")
local Footprints = require("Career.VehicleFootprints")
local Collision = require("Career.FootprintCollision")
local V = Vector3

---@class CareerActorInput
---@field steer? number 右正，左负，[-1,1]
---@field throttle? number 前进正；负值先减速再低速倒退
---@field brake? boolean 制动优先，不允许制动同时加速
---@field reverseBrake? boolean 手游刹车持续持有：停稳0.45秒后进入低速倒车
---@field walkX? number 相机右向为正
---@field walkY? number 相机前向为正
---@field run? boolean
---@field speedFactor? number 低饱腹/精力的安全限速系数
---@field touchSteer? number 复用赛车转向条的步行转身输入
---@field touchWalk? boolean 触屏步行沿人物朝向，电脑兼容输入仍沿相机朝向

---@class CareerActorCity
---@field Move fun(self: CareerActorCity, x: number, z: number, dx: number, dz: number, radius: number): number, number
---@field Surface fun(self: CareerActorCity, x: number, z: number): number

---@class CareerActor
---@field scene Scene
---@field city CareerCity
---@field node Node 永久相机目标；步行跟人物，骑车跟车辆
---@field visuals CareerActorVisuals
---@field x number
---@field z number
---@field yaw number 度数，0为+Z
---@field speed number 米/秒；骑行倒退为负，步行为实际速度大小
---@field mounted boolean
---@field bikeX number 独立停放位置，不随步行移动
---@field bikeZ number
---@field bikeYaw number
---@field steer number
---@field disposed boolean
---@field collisionLogged boolean
---@field walkLogged boolean
---@field rideLogged boolean
local Actor = {}
Actor.__index = Actor

Actor.Resources = Visuals.Resources
Actor.ResourceTypes = Visuals.ResourceTypes
Actor.ProxyLabel = Visuals.ProxyLabel
Actor.AnimationLabel = Visuals.AnimationLabel
Actor.MAX_SPEED = 35 / 3.6 -- 电动车保留首日35km/h独立动力。
local REVERSE_SPEED = 1.6
local WALK_SPEED, RUN_SPEED = 1.8, 3.4
local WALK_RADIUS = 0.32
local MAP_LIMIT = require("Career.WorldData").LIMIT
local MOUNT_DISTANCE, STOP_SPEED = 3, 0.5
local MAX_STEP, MAX_TIME_STEP = 0.18, 1 / 60

---@param value number
---@param low number
---@param high number
---@return number
local function clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

---@param value number|nil
---@return number
local function axis(value)
    if type(value) ~= "number" or value ~= value then return 0 end
    return clamp(value, -1, 1)
end

---@param value number
---@return number
local function wrapYaw(value)
    return (value + 180) % 360 - 180
end

---@param value number
---@param target number
---@param amount number
---@return number
local function approach(value, target, amount)
    if value < target then return math.min(target, value + amount) end
    return math.max(target, value - amount)
end

-- Collision plan (metres, top view; +Z forward):
--      wall |  .32m walker circle   | local car-shell strips
--           |       O ->           |    /---------\
--           |    +mirror+          |   |           |
--           |    | bike | ->       |   |           |
--           |    | box  |          |    \---------/
-- Walk is a true circle; ride/parking is a directional union measured from
-- the rendered model, box and mirrors (VehicleFootprints shares their layout).
-- No enclosing diagonal circle and no axis-aligned vehicle-sized square.
-- City continuously casts each <=.10m displacement; <=1/60s dynamics steps,
-- and <=.25-degree swept rotation intervals prevent high-speed corner tunnelling.
-- Tangency slides, contact blocks inward travel, no speed accumulation into walls.
-- Mount/dismount ignore only the target vehicle, never unrelated parked vehicles.
-- No parallel Bullet movement, no gravity/jump in this flat locomotion domain.

---@param scene Scene
---@param city CareerCity
---@return CareerActor
function Actor.New(scene, city)
    local self = setmetatable({}, Actor)
    self:Init(scene, city)
    return self
end

---@param scene Scene
---@param city CareerCity
function Actor:Init(scene, city)
    assert(scene and city, "Actor.New requires scene and City")
    self.scene, self.city = scene, city
    city.actor=self -- independent parking is part of the same City query domain
    self.x, self.z, self.yaw, self.speed = 0, -20, 0, 0
    self.bikeX, self.bikeZ, self.bikeYaw = 1.5, -20, 0
    self.vehicleId=Vehicles.EBIKE
    self.parking={}
    self.mounted, self.disposed, self.steer = false, false, 0
    self.reverseHold=0
    ---@type number
    self.walkHeight=0
    self.walkDistance=0
    self.collisionLogged, self.walkLogged, self.rideLogged = false, false, false
    self.node = scene:CreateChild("CareerActorFollowTarget")
    self.node:SetVar("CareerAssetStatus", Variant(Actor.ProxyLabel))
    self.visuals = Visuals.New(scene, self.node, self.city)
    self:SyncVisuals(0)
    print(string.format("[CareerActor] 初始步行 x=%.1f z=%.1f yaw=0；车独立停在(%.1f,%.1f)，限速35km/h",
        self.x, self.z, self.bikeX, self.bikeZ))
end

function Actor:VehicleRadius() return Vehicles.Radii[self.vehicleId] end -- compatibility/broad phase only
function Actor:Footprint(mounted)
    if mounted==nil then mounted=self.mounted end
    return mounted and Footprints.Get(self.vehicleId) or Collision.Circle(0,0,WALK_RADIUS)
end
function Actor:ParkedShapes(ignoreId)
    local list={}
    if not self.mounted and self.vehicleId~=ignoreId then list[#list+1]=Footprints.At(self.vehicleId,self.bikeX,self.bikeZ,self.bikeYaw) end
    for id,p in pairs(self.parking) do if id~=self.vehicleId and id~=ignoreId then list[#list+1]=Footprints.At(id,p.x,p.z,p.yaw) end end
    return list
end
function Actor:VehicleName() return Vehicles.Names[self.vehicleId] end
function Actor:MaxSpeed() return self.vehicleId==Vehicles.EBIKE and Actor.MAX_SPEED or 60/3.6 end
function Actor:ParkingSnapshot()
    local parks={}
    for id,p in pairs(self.parking) do parks[id]={x=p.x,z=p.z,yaw=p.yaw} end
    parks[self.vehicleId]={x=self.bikeX,z=self.bikeZ,yaw=self.bikeYaw}
    return parks
end
function Actor:RestoreVehicles(pos)
    self.parking={}
    for id,p in pairs(pos.vehicleParking or {}) do
        local x,z=self.city:FindShapeFree(p.x,p.z,Footprints.Get(id),p.yaw,"vehicle",0,id)
        self.parking[id]={x=x,z=z,yaw=p.yaw}
    end
    self.vehicleId=pos.activeVehicle or Vehicles.EBIKE
    local x,z=self.city:FindShapeFree(pos.bikeX,pos.bikeZ,self:Footprint(true),pos.bikeYaw,"vehicle",0,self.vehicleId)
    self.bikeX,self.bikeZ,self.bikeYaw=x,z,pos.bikeYaw
    self.parking[self.vehicleId]={x=x,z=z,yaw=pos.bikeYaw}
    self.visuals:SetVehicle(self.vehicleId)
    self.visuals:UpdateParking(self.parking,self.city)
end

---@param x number
---@param z number
---@param dx number
---@param dz number
---@param radius number
---@return number, number, boolean
function Actor:Move(x, z, dx, dz, radius, yaw, ignoreId)
    local distance = math.sqrt(dx * dx + dz * dz)
    local steps = math.max(1, math.ceil(distance / MAX_STEP))
    local stepX, stepZ = dx / steps, dz / steps
    local blocked = false
    local walking=radius==WALK_RADIUS
    local shape=walking and self:Footprint(false) or self:Footprint(true)
    for _ = 1, steps do
        local nextX,nextZ,hit=self.city:MoveShape(x,z,stepX,stepZ,shape,yaw or self.yaw,
            walking and "walk" or "vehicle",self.walkHeight,ignoreId)
        if walking then self.walkHeight=self.city:WalkSurface(nextX,nextZ,self.walkHeight) end
        if hit or math.abs(nextX-x-stepX)+math.abs(nextZ-z-stepZ)>.0001 then blocked=true end
        x,z=nextX,nextZ
    end
    return x,z,blocked
end

-- Turn the entire visible footprint, not just its centre. Each short angular
-- interval is enclosed by start/end hulls plus arc sagitta <=0.01mm. The query
-- therefore covers the continuous rotation rather than sparse yaw samples.
function Actor:TurnTo(x,z,fromYaw,toYaw)
    local delta=wrapYaw(toYaw-fromYaw)
    if math.abs(delta)<1e-8 then return fromYaw,false end
    local count=math.max(1,math.ceil(math.abs(delta)/.25))
    local shape=self:Footprint(true)
    -- Only a broad-phase success may skip narrow angular casts; failure never
    -- blocks a gap using this enclosing disc.
    if self.city:IsShapeFree(x,z,Collision.Circle(0,0,shape.reach),0,"vehicle",0,self.vehicleId) then
        return wrapYaw(toYaw),false
    end
    local accepted=fromYaw
    for i=1,count do
        local nextYaw=fromYaw+delta*i/count
        local first=Collision.Pose(shape,0,0,accepted)
        local last=Collision.Pose(shape,0,0,nextYaw)
        local parts={}
        local pad=shape.reach*(1-math.cos(math.rad(math.abs(delta/count))*.5))+.000001
        for index,p in ipairs(first.parts) do
            local points={}
            for _,v in ipairs(p.points) do
                for _,d in ipairs({{pad,pad},{-pad,pad},{pad,-pad},{-pad,-pad}}) do points[#points+1]={x=v.x+d[1],z=v.z+d[2]} end
            end
            for _,v in ipairs(last.parts[index].points) do
                for _,d in ipairs({{pad,pad},{-pad,pad},{pad,-pad},{-pad,-pad}}) do points[#points+1]={x=v.x+d[1],z=v.z+d[2]} end
            end
            parts[#parts+1]={points=Collision.Hull(points)}
        end
        if not self.city:IsShapeFree(x,z,Collision.Shape(parts),0,"vehicle",0,self.vehicleId) then return accepted,true end
        accepted=nextYaw
    end
    return wrapYaw(accepted),false
end

---@param dt number
---@param controls CareerActorInput
---@param cameraYaw? number 世界/相机朝向度数，省略=0；不累积人物自身yaw
function Actor:Update(dt, controls, cameraYaw)
    if self.disposed or dt ~= dt or dt <= 0 then return end
    local frameTime = math.min(dt, 0.25)
    local count = math.max(1, math.ceil(frameTime / MAX_TIME_STEP))
    local step = frameTime / count
    self.walkDistance=0
    for _ = 1, count do
        if self.mounted then
            self:RideStep(step, controls)
        else
            self:WalkStep(step, controls, cameraYaw or 0)
        end
    end
    self:SyncVisuals(frameTime)
end

---@param dt number
---@param controls CareerActorInput
---@param cameraYaw number
function Actor:WalkStep(dt, controls, cameraYaw)
    local right = axis(controls.walkX ~= nil and controls.walkX or controls.steer)
    local forward = axis(controls.walkY ~= nil and controls.walkY or controls.throttle)
    local magnitude = math.sqrt(right * right + forward * forward)
    local touch=controls.touchWalk==true
    if touch then self.yaw=wrapYaw(self.yaw+axis(controls.touchSteer)*120*dt) end
    if magnitude <= 0.08 then
        self.speed, self.steer = 0, 0
        return
    end
    local strength = math.min(1, magnitude)
    local angle = math.rad(touch and self.yaw or cameraYaw)
    local vx = (right * math.cos(angle) + forward * math.sin(angle)) / magnitude
    local vz = (forward * math.cos(angle) - right * math.sin(angle)) / magnitude
    local desiredSpeed = (controls.run and RUN_SPEED or WALK_SPEED) * strength * clamp(controls.speedFactor or 1,.4,1)
    local nextX, nextZ, blocked = self:Move(self.x, self.z,
        vx * desiredSpeed * dt, vz * desiredSpeed * dt, WALK_RADIUS)
    local movedX, movedZ = nextX - self.x, nextZ - self.z
    local distance=math.sqrt(movedX*movedX+movedZ*movedZ)
    self.walkDistance=self.walkDistance+distance
    self.speed = distance / dt
    self.x, self.z, self.steer = nextX, nextZ, 0
    local wantedYaw = math.deg(math.atan(vx, vz))
    if not touch then
        self.yaw = wrapYaw(self.yaw + wrapYaw(wantedYaw - self.yaw) * math.min(1, dt * 16))
    end
    if blocked then self:LogCollision() end
    if not self.walkLogged then
        self.walkLogged = true
        print("[CareerActor] 步行输入已驱动；相机相对移动，骨骼步态跟随实际速度")
    end
end

---@param dt number
---@param controls CareerActorInput
function Actor:RideStep(dt, controls)
    local throttle = axis(controls.throttle)
    local maxSpeed=self:MaxSpeed()
    local acceleration=self.vehicleId==Vehicles.EBIKE and 2.8 or 4.2
    self.steer = axis(controls.steer)
    local oldSpeed = self.speed
    if controls.brake then
        if controls.reverseBrake and self.speed<=.05 then
            self.reverseHold=self.reverseHold+dt
            self.speed=self.reverseHold>=.45 and approach(self.speed,-REVERSE_SPEED,1.8*dt) or 0
        else
            self.reverseHold=0
            self.speed = approach(self.speed, 0, 7.5 * dt)
        end
    elseif throttle > 0 then
        self.reverseHold=0
        self.speed = approach(self.speed, maxSpeed * throttle * clamp(controls.speedFactor or 1,.4,1),
            (self.speed < 0 and 5.5 or acceleration) * dt)
    elseif throttle < 0 then
        self.reverseHold=0
        self.speed = approach(self.speed, REVERSE_SPEED * throttle,
            (self.speed > 0 and 5.0 or 1.8) * dt)
    else
        self.reverseHold=0
        self.speed = approach(self.speed, 0, 1.0 * dt)
    end
    self.speed = clamp(self.speed, -REVERSE_SPEED, maxSpeed)
    -- Small bicycle-model turn radius, attenuated at road speed. Signed speed
    -- reverses steering naturally; no pivoting or leaning while parked.
    local steeringAngle = self.steer * (30 - 12 * math.min(1, math.abs(self.speed) / maxSpeed))
    local yawDelta = math.deg(self.speed / 1.45 * math.tan(math.rad(steeringAngle))) * dt
    local firstYaw,turnBlocked=self:TurnTo(self.x,self.z,self.yaw,self.yaw+yawDelta*.5)
    local middleYaw = math.rad(firstYaw)
    local distance = (oldSpeed + self.speed) * 0.5 * dt
    local nextX, nextZ, blocked = self:Move(self.x, self.z,
        math.sin(middleYaw) * distance, math.cos(middleYaw) * distance, self:VehicleRadius(),firstYaw,self.vehicleId)
    local finalYaw,endBlocked=self:TurnTo(nextX,nextZ,firstYaw,self.yaw+yawDelta)
    blocked=blocked or turnBlocked or endBlocked
    local moved = math.sqrt((nextX - self.x) ^ 2 + (nextZ - self.z) ^ 2)
    self.x, self.z = nextX, nextZ
    self.yaw = finalYaw
    if blocked then
        if math.abs(distance) > 0.00001 then
            self.speed = self.speed * math.min(1, moved / math.abs(distance))
        end
        if moved < 0.00001 then self.speed = 0 end
        self:LogCollision()
    end
    self.bikeX, self.bikeZ, self.bikeYaw = self.x, self.z, self.yaw
    if not self.rideLogged and math.abs(self.speed) > 0.1 then
        self.rideLogged = true
        print(string.format("[CareerActor] %s城市动力%.1fm/s²，限速%.0fkm/h，独立于赛道",self:VehicleName(),acceleration,maxSpeed*3.6))
    end
end

function Actor:LogCollision()
    if self.collisionLogged then return end
    self.collisionLogged = true
    print("[CareerActor] 城市碰撞/地图边界阻挡：子步扫段生效，保留切向移动")
end

---@param dt number
function Actor:SyncVisuals(dt)
    self.node.position = self:GetPosition()
    self.node.rotation = Quaternion(0, self.yaw, 0)
    self.visuals:Update(dt, self.speed, self.steer, self.bikeX,
        self.city:Surface(self.bikeX, self.bikeZ), self.bikeZ, self.bikeYaw,dt>0 and self.walkDistance or 0)
end

---@return boolean, string
function Actor:ToggleMount()
    if self.disposed then return false, "角色已释放" end
    if math.abs(self.speed) >= STOP_SPEED then
        print("[CareerActor] 上下车拒绝：速度必须低于0.5m/s")
        return false, "请先停稳再上下车（速度需低于0.5m/s）"
    end
    self.reverseHold=0
    if not self.mounted and self.walkHeight>1 then return false,"请先沿天桥坡道回到地面，再走到车旁" end
    if not self.mounted then
        local dx, dz = self.bikeX - self.x, self.bikeZ - self.z
        local distance = math.sqrt(dx * dx + dz * dz)
        if distance >= MOUNT_DISTANCE then
            print(string.format("[CareerActor] 上车拒绝：距停车%.2fm（必须小于3m），不会随地召回", distance))
            return false, "请走到停放的车旁3米内，不会随地召回车辆"
        end
        -- A nearby bike behind a wall is not reachable through that wall.
        if not self.city:IsShapeFree(self.bikeX,self.bikeZ,self:Footprint(true),self.bikeYaw,"vehicle",0,self.vehicleId) then
            return false,"车辆旁空间不足，请先移开其它障碍物"
        end
        local mountX, mountZ, blocked = self:Move(self.x, self.z, dx, dz, WALK_RADIUS,self.yaw,self.vehicleId)
        if blocked or math.abs(mountX - self.bikeX) + math.abs(mountZ - self.bikeZ) > 0.01 then
            return false, "车辆在障碍物另一侧，请绕到车旁"
        end
        self.x, self.z, self.yaw = self.bikeX, self.bikeZ, self.bikeYaw
        self.speed, self.steer, self.mounted = 0, 0, true
        self.visuals:SetMounted(true)
        self:SyncVisuals(0)
        print(string.format("[CareerActor] 上车成功(%.2f,%.2f)；%s", self.x, self.z, self:VehicleName()))
        return true, "已上车 · " .. self:VehicleName()
    end

    -- Step out past the real side / nose / cargo edge, not the enclosing disc.
    -- The traversed path ignores only this bike; the final walker must also
    -- clear its actual shell, so a tiny slot cannot be used as a dismount cheat.
    local heading = math.rad(self.bikeYaw)
    local footprint=self:Footprint(true)
    local exits={{footprint.x1-WALK_RADIUS-.08,0},{footprint.x2+WALK_RADIUS+.08,0},
        {0,footprint.z1-WALK_RADIUS-.08},{0,footprint.z2+WALK_RADIUS+.08}}
    for _, exit in ipairs(exits) do
        local dx = exit[1]*math.cos(heading)+exit[2]*math.sin(heading)
        local dz = exit[2]*math.cos(heading)-exit[1]*math.sin(heading)
        local newX,newZ,blocked=self:Move(self.bikeX,self.bikeZ,dx,dz,WALK_RADIUS,self.bikeYaw,self.vehicleId)
        local clearBike=Collision.Free(Collision.Circle(newX,newZ,WALK_RADIUS),Footprints.At(self.vehicleId,self.bikeX,self.bikeZ,self.bikeYaw),Collision.SKIN)
        if not blocked and clearBike and math.abs(newX - self.bikeX - dx) + math.abs(newZ - self.bikeZ - dz) < 0.01 then
            self.x, self.z, self.yaw = newX, newZ, self.bikeYaw
            self.speed, self.steer, self.mounted = 0, 0, false
            self.visuals:SetMounted(false)
            self:SyncVisuals(0)
            print(string.format("[CareerActor] 下车成功 人(%.2f,%.2f)，车留在(%.2f,%.2f)",
                self.x, self.z, self.bikeX, self.bikeZ))
            return true, "已停车下车，车辆留在原处"
        end
    end
    print("[CareerActor] 下车拒绝：四个完整出口路径均被墙/边界阻挡")
    return false, "两侧及前后都无法安全下车，请挪到空旷处停稳"
end

---@return Vector3
function Actor:GetPosition()
    local y=self.mounted and self.city:Surface(self.x,self.z) or self.city:WalkSurface(self.x,self.z,self.walkHeight)
    if not self.mounted then self.walkHeight=y end
    return V(self.x,y,self.z)
end

-- Explicit test/recovery hook only. Walking restores the PERSON alone; a
-- parked bike never teleports to the person. Mounted recovery moves its rider
-- and vehicle together. No input action calls this as a recall mechanic.
---@param x number
---@param z number
---@param yaw number
function Actor:Teleport(x, z, yaw, height)
    if self.disposed then return end
    self.walkHeight=height or 0
    self.yaw=wrapYaw(yaw)
    self.x,self.z=self.city:FindShapeFree(x,z,self:Footprint(),self.yaw,
        self.mounted and "vehicle" or "walk",self.walkHeight,self.mounted and self.vehicleId or nil)
    self.speed,self.steer=0,0
    self.walkDistance=0
    self.visuals:ResetGait()
    if self.mounted then
        self.bikeX, self.bikeZ, self.bikeYaw = self.x, self.z, self.yaw
    end
    self:SyncVisuals(0)
    print(string.format("[CareerActor] 仅测试/恢复 Teleport(%.2f,%.2f,%.1f)，mounted=%s",
        self.x, self.z, self.yaw, tostring(self.mounted)))
end

function Actor:Dispose()
    if self.disposed then return end
    self.disposed = true
    self.visuals:Dispose()
    local city=self.city --[[@as CareerCity]]
    if city.actor==self then city.actor=nil end
    self.node:Dispose()
    print("[CareerActor] 已释放人物、独立停放车与配送装备")
end

return Actor
