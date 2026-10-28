-- 生涯城市角色：独立步行、电动车动力与停车位置。
-- 城市负责碰撞；Session负责输入、相机、电量与存档，不复用赛车速度参数。
local Visuals = require("Career.ActorVisuals")
local V = Vector3

---@class CareerActorInput
---@field steer? number 右正，左负，[-1,1]
---@field throttle? number 前进正；负值先减速再低速倒退
---@field brake? boolean 制动优先，不允许制动同时加速
---@field walkX? number 相机右向为正
---@field walkY? number 相机前向为正
---@field run? boolean

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
Actor.MAX_SPEED = 35 / 3.6 -- First-day city e-bike physics: 35km/h, NOT racing stats.
local REVERSE_SPEED = 1.6
local WALK_SPEED, RUN_SPEED = 1.8, 3.4
local WALK_RADIUS, BIKE_RADIUS = 0.32, 1.20
local MAP_LIMIT = 180
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
--
--          building / inflated City AABB
--          +-------------------------+
--          |                         |
--          +-------------------------+
--        O -> ->   tangency slides; inward displacement is blocked
--        |<-r->|
--  walker: circle r=.32; vehicle: conservative circle r=1.20, enclosing
--  the inspected sport debug proxy (length2.15m,width.997m; corner radius1.185).
--  No Bullet movement in parallel: ALL XZ displacement passes through City.Move.
--  Segment <=.18m and time <=1/60s, including parking exits; dt<=.25s avoids
--  catching up huge paused/stalled frames. Edges clamp at +/- (180-radius).
--  Boundaries: zero input does not rotate/move; diagonal walk normalized;
--  thin walls/corners use City sweep; blocked vehicle loses speed, no wall turbo;
--  dismount tries full unobstructed paths, refuses if every exit is blocked;
--  grounded at Surface, no artificial jump/ceiling/gravity in this flat city.

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
    self.x, self.z, self.yaw, self.speed = 0, -20, 0, 0
    self.bikeX, self.bikeZ, self.bikeYaw = 1.5, -20, 0
    self.mounted, self.disposed, self.steer = false, false, 0
    self.collisionLogged, self.walkLogged, self.rideLogged = false, false, false
    self.node = scene:CreateChild("CareerActorFollowTarget")
    self.node:SetVar("CareerAssetStatus", Variant(Actor.ProxyLabel))
    self.visuals = Visuals.New(scene, self.node)
    self:SyncVisuals(0)
    print(string.format("[CareerActor] 初始步行 x=%.1f z=%.1f yaw=0；车独立停在(%.1f,%.1f)，限速35km/h",
        self.x, self.z, self.bikeX, self.bikeZ))
end

---@param x number
---@param z number
---@param dx number
---@param dz number
---@param radius number
---@return number, number, boolean
function Actor:Move(x, z, dx, dz, radius)
    local distance = math.sqrt(dx * dx + dz * dz)
    local steps = math.max(1, math.ceil(distance / MAX_STEP))
    local stepX, stepZ = dx / steps, dz / steps
    local blocked = false
    for _ = 1, steps do
        local nextX, nextZ = self.city:Move(x, z, stepX, stepZ, radius)
        nextX = clamp(nextX, -MAP_LIMIT + radius, MAP_LIMIT - radius)
        nextZ = clamp(nextZ, -MAP_LIMIT + radius, MAP_LIMIT - radius)
        if math.abs(nextX - x - stepX) + math.abs(nextZ - z - stepZ) > 0.0001 then
            blocked = true
        end
        x, z = nextX, nextZ
    end
    return x, z, blocked
end

---@param dt number
---@param controls CareerActorInput
---@param cameraYaw? number 世界/相机朝向度数，省略=0；不累积人物自身yaw
function Actor:Update(dt, controls, cameraYaw)
    if self.disposed or dt ~= dt or dt <= 0 then return end
    local frameTime = math.min(dt, 0.25)
    local count = math.max(1, math.ceil(frameTime / MAX_TIME_STEP))
    local step = frameTime / count
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
    if magnitude <= 0.08 then
        self.speed, self.steer = 0, 0
        return
    end
    local strength = math.min(1, magnitude)
    local angle = math.rad(cameraYaw)
    local vx = (right * math.cos(angle) + forward * math.sin(angle)) / magnitude
    local vz = (forward * math.cos(angle) - right * math.sin(angle)) / magnitude
    local desiredSpeed = (controls.run and RUN_SPEED or WALK_SPEED) * strength
    local nextX, nextZ, blocked = self:Move(self.x, self.z,
        vx * desiredSpeed * dt, vz * desiredSpeed * dt, WALK_RADIUS)
    local movedX, movedZ = nextX - self.x, nextZ - self.z
    self.speed = math.sqrt(movedX * movedX + movedZ * movedZ) / dt
    self.x, self.z, self.steer = nextX, nextZ, 0
    local wantedYaw = math.deg(math.atan(vx, vz))
    self.yaw = wrapYaw(self.yaw + wrapYaw(wantedYaw - self.yaw) * math.min(1, dt * 16))
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
    self.steer = axis(controls.steer)
    local oldSpeed = self.speed
    if controls.brake then
        self.speed = approach(self.speed, 0, 7.5 * dt)
    elseif throttle > 0 then
        self.speed = approach(self.speed, Actor.MAX_SPEED * throttle,
            (self.speed < 0 and 5.5 or 2.8) * dt)
    elseif throttle < 0 then
        self.speed = approach(self.speed, REVERSE_SPEED * throttle,
            (self.speed > 0 and 5.0 or 1.8) * dt)
    else
        self.speed = approach(self.speed, 0, 1.0 * dt)
    end
    self.speed = clamp(self.speed, -REVERSE_SPEED, Actor.MAX_SPEED)
    -- Small bicycle-model turn radius, attenuated at road speed. Signed speed
    -- reverses steering naturally; no pivoting or leaning while parked.
    local steeringAngle = self.steer * (30 - 12 * math.min(1, math.abs(self.speed) / Actor.MAX_SPEED))
    local yawDelta = math.deg(self.speed / 1.45 * math.tan(math.rad(steeringAngle))) * dt
    local middleYaw = math.rad(self.yaw + yawDelta * 0.5)
    local distance = (oldSpeed + self.speed) * 0.5 * dt
    local nextX, nextZ, blocked = self:Move(self.x, self.z,
        math.sin(middleYaw) * distance, math.cos(middleYaw) * distance, BIKE_RADIUS)
    local moved = math.sqrt((nextX - self.x) ^ 2 + (nextZ - self.z) ^ 2)
    self.x, self.z = nextX, nextZ
    self.yaw = wrapYaw(self.yaw + yawDelta)
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
        print("[CareerActor] 城市骑行输入已驱动；独立动力2.8m/s²，35km/h封顶，不读取274km/h赛车参数")
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
        self.city:Surface(self.bikeX, self.bikeZ), self.bikeZ, self.bikeYaw)
end

---@return boolean, string
function Actor:ToggleMount()
    if self.disposed then return false, "角色已释放" end
    if math.abs(self.speed) >= STOP_SPEED then
        print("[CareerActor] 上下车拒绝：速度必须低于0.5m/s")
        return false, "请先停稳再上下车（速度需低于0.5m/s）"
    end
    if not self.mounted then
        local dx, dz = self.bikeX - self.x, self.bikeZ - self.z
        local distance = math.sqrt(dx * dx + dz * dz)
        if distance >= MOUNT_DISTANCE then
            print(string.format("[CareerActor] 上车拒绝：距停车%.2fm（必须小于3m），不会随地召回", distance))
            return false, "请走到停放的车旁3米内，不会随地召回车辆"
        end
        -- A nearby bike behind a wall is not reachable through that wall.
        local mountX, mountZ, blocked = self:Move(self.x, self.z, dx, dz, WALK_RADIUS)
        if blocked or math.abs(mountX - self.bikeX) + math.abs(mountZ - self.bikeZ) > 0.01 then
            return false, "车辆在障碍物另一侧，请绕到车旁"
        end
        self.x, self.z, self.yaw = self.bikeX, self.bikeZ, self.bikeYaw
        self.speed, self.steer, self.mounted = 0, 0, true
        self.visuals:SetMounted(true)
        self:SyncVisuals(0)
        print(string.format("[CareerActor] 上车成功(%.2f,%.2f)；%s", self.x, self.z, Actor.ProxyLabel))
        return true, "已上车 · " .. Actor.ProxyLabel
    end

    -- Exit centres clear the bike's enclosing circle + walker radius. Test
    -- both sides, then fore/aft; follow each complete path with City.Move.
    -- No teleport through wall, no arbitrary map-wide search/vehicle recall.
    local heading = math.rad(self.bikeYaw)
    local exitDistance = BIKE_RADIUS + WALK_RADIUS + 0.10
    for _, exit in ipairs({{-1, 0}, {1, 0}, {0, -1}, {0, 1}}) do
        local dx = (exit[1] * math.cos(heading) + exit[2] * math.sin(heading)) * exitDistance
        local dz = (exit[2] * math.cos(heading) - exit[1] * math.sin(heading)) * exitDistance
        local newX, newZ, blocked = self:Move(self.bikeX, self.bikeZ, dx, dz, WALK_RADIUS)
        if not blocked and math.abs(newX - self.bikeX - dx) + math.abs(newZ - self.bikeZ - dz) < 0.01 then
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
    return V(self.x, self.city:Surface(self.x, self.z), self.z)
end

-- Explicit test/recovery hook only. Walking restores the PERSON alone; a
-- parked bike never teleports to the person. Mounted recovery moves its rider
-- and vehicle together. No input action calls this as a recall mechanic.
---@param x number
---@param z number
---@param yaw number
function Actor:Teleport(x, z, yaw)
    if self.disposed then return end
    local radius = self.mounted and BIKE_RADIUS or WALK_RADIUS
    self.x, self.z = self:Move(clamp(x, -MAP_LIMIT + radius, MAP_LIMIT - radius),
        clamp(z, -MAP_LIMIT + radius, MAP_LIMIT - radius), 0, 0, radius)
    self.yaw, self.speed, self.steer = wrapYaw(yaw), 0, 0
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
    self.node:Dispose()
    print("[CareerActor] 已释放人物、独立停放车与配送装备")
end

return Actor
