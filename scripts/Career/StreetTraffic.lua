-- 全城街面车流：在扩张区每条道路上循环行驶的表现层车辆。
-- 只按路线做解析运动，不做逐帧碰撞/接地判定（道路上没有静态障碍），
-- 因此几十辆车的每帧开销只有几十次浮点运算和节点赋值，不会拖慢主循环。
local Assets = require("VehicleAssets")
local Expansion = require("Career.CityExpansion")

local StreetTraffic = {}
StreetTraffic.__index = StreetTraffic
StreetTraffic.POOL = 36

---@param parent Node
---@param city CareerCity
---@return CareerStreetTraffic
function StreetTraffic.New(parent, city)
    local self = setmetatable({ cars = {}, city = city }, StreetTraffic)
    self.root = parent:CreateChild("全城街面车流")
    city.streetTraffic = self
    local roads = Expansion.Roads
    if #roads == 0 then return self end
    local ids = Assets.TrafficIds
    for i = 1, StreetTraffic.POOL do
        local road = roads[(i - 1) % #roads + 1]
        local id = ids[(i - 1) % #ids + 1]
        local node = Assets.Add(self.root, id, nil, "distant")
        node:SetEnabledRecursive(true)
        local draw = node:GetComponent("StaticModel")
        if not draw then
            local mesh = node:GetChild("DetailedBody")
            draw = mesh and mesh:GetComponent("StaticModel") or nil
        end
        if draw then
            draw.castShadows = false
            draw.drawDistance = 220
            draw.shadowDistance = 0
        end
        local dx, dz = road.x2 - road.x1, road.z2 - road.z1
        local length = math.abs(dx) + math.abs(dz)
        local vertical = math.abs(dx) < math.abs(dz)
        -- 双向车道：按序号交替方向并偏到右侧车道。
        local lane = ((i % 2 == 0) and 1 or -1) * 3.2
        self.cars[#self.cars + 1] = {
            node = node, road = road, length = math.max(1, length),
            s = (i * 7.3) % math.max(1, length), dir = (i % 2 == 0) and 1 or -1,
            speed = 7 + (i % 5), current = 7 + (i % 5), vertical = vertical, lane = lane,
            radius = 1.15,
        }
    end
    self:Update(0)
    print(string.format("[全城车流] %d辆分布于%d条道路；纯解析运动，不做逐帧碰撞", #self.cars, #roads))
    return self
end

-- 玩家碰撞用：把查询范围内的街面车作为圆形占位加入碰撞列表。
-- 只做玩家与本车的一次距离判断，不做车车/静态判定，开销可忽略。
---@param result table
---@param area table
---@param dx number
---@param dz number
---@param mode string
---@param height number
function StreetTraffic:AppendShapes(result, area, dx, dz, mode, height)
    local x1, x2 = math.min(area.x1, area.x1 + dx), math.max(area.x2, area.x2 + dx)
    local z1, z2 = math.min(area.z1, area.z1 + dz), math.max(area.z2, area.z2 + dz)
    for _, car in ipairs(self.cars) do
        local p = car.node.position
        local r = car.radius
        if p.x + r >= x1 and p.x - r <= x2 and p.z + r >= z1 and p.z - r <= z2 then
            result[#result + 1] = require("Career.FootprintCollision").Circle(p.x, p.z, r)
        end
    end
end

---@param dt number
function StreetTraffic:Update(dt)
    local city = self.city
    for _, car in ipairs(self.cars) do
        local target = car.speed
        if self.actor then
            local dxp, dzp = self.actor.x - car.node.position.x, self.actor.z - car.node.position.z
            if dxp * dxp + dzp * dzp < 14 * 14 then target = 0 end
        end
        car.current = car.current or car.speed
        car.current = car.current + (target - car.current) * math.min(1, dt * 4)
        car.s = car.s + car.dir * car.current * dt
        if car.s >= car.length then car.s, car.dir = car.length, -1
        elseif car.s <= 0 then car.s, car.dir = 0, 1 end
        local road = car.road
        local t = car.s / car.length
        local x = road.x1 + (road.x2 - road.x1) * t
        local z = road.z1 + (road.z2 - road.z1) * t
        if car.vertical then x = x + car.lane else z = z + car.lane end
        local y = city and city:Surface(x, z) or 0
        car.node.position = Vector3(x, y, z)
        local forward = car.vertical and (car.dir * (road.z2 - road.z1) >= 0 and 0 or 180)
            or (car.dir * (road.x2 - road.x1) >= 0 and 90 or -90)
        car.node.rotation = Quaternion(0, forward, 0)
    end
end

function StreetTraffic:Dispose()
    if self.root then self.root:Dispose(); self.root = nil end
    self.cars = {}
end

return StreetTraffic
