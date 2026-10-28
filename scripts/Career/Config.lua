-- 首日纯逻辑配置；世界坐标单位为米，Y 由 City 决定，不创建节点/事件/UI。
local Config = {}

Config.SAVE_PATH = "career_profile_v1.json"
Config.SAVE_VERSION = 1
Config.CLOUD_KEY = "career/profile/v1"
Config.INITIAL_CASH_CENTS = 5000
Config.MEAL_CENTS = 1200
Config.AID_THRESHOLD_CENTS = 3000
Config.CAPACITY = 1
Config.START_HOUR = 8
-- 15 现实分钟代表 2 游戏小时；菜单暂停由入口停止调用 Update 实现。
Config.GAME_HOURS_PER_SECOND = 2 / 900
Config.AUTOSAVE_SECONDS = 30
Config.INTERACTION_RADIUS = 2
Config.STOP_SPEED = 0.35 -- m/s，不是 km/h
Config.BATTERY_PER_METER = 100 / 35000
Config.HUNGER_PER_HOUR = 8
Config.ENERGY_PER_HOUR = 6

---@class CareerPoint
---@field id string
---@field label string
---@field name? string
---@field kind string
---@field x number
---@field z number

---@type CareerPoint[]
Config.pointList = {
    { id = "breakfast", label = "老街早餐店", kind = "merchant", x = -25, z = -8 },
    { id = "home_old", label = "旧宅门厅", kind = "delivery", x = -108, z = 80 },
    { id = "park", label = "公园长椅", kind = "rest", x = 108, z = -25 },
    { id = "bridge", label = "桥下落脚点", kind = "rest", x = 0, z = -70 },
    { id = "charge", label = "街边充电点", kind = "charge", x = 22, z = -8 },
    { id = "dealer", label = "车行前台", kind = "dealer", x = 108, z = 80 },
}
---@type table<string, CareerPoint>
Config.points = {}
for _, point in ipairs(Config.pointList) do
    point.name = point.label
    Config.points[point.id] = point
end

---@class CareerRoutePoint
---@field x number
---@field z number
---@class CareerOrderTemplate
---@field id string
---@field title string
---@field pickupId string
---@field dropoffId string
---@field route CareerRoutePoint[]
---@field timeLimitHours number
---@field tutorial boolean

-- 路网由 City 的 z=0/100 横路、x=-100/0/100 竖路组成。
-- 固定可通行折线报价，不按玩家绕圈里程或穿楼直线报价。
---@type CareerOrderTemplate[]
Config.orderTemplates = {
    { id = "tutorial", title = "第一份热早餐", pickupId = "breakfast", dropoffId = "home_old",
        route = { {x=-25,z=-8}, {x=-25,z=0}, {x=-100,z=0}, {x=-100,z=80}, {x=-108,z=80} }, timeLimitHours = 1.5, tutorial = true },
    { id = "old_home", title = "旧宅早餐配送", pickupId = "breakfast", dropoffId = "home_old",
        route = { {x=-25,z=-8}, {x=-25,z=0}, {x=-100,z=0}, {x=-100,z=80}, {x=-108,z=80} }, timeLimitHours = 1, tutorial = false },
    { id = "dealer_lunch", title = "车行前台便餐", pickupId = "breakfast", dropoffId = "dealer",
        route = { {x=-25,z=-8}, {x=-25,z=0}, {x=100,z=0}, {x=100,z=80}, {x=108,z=80} }, timeLimitHours = 1, tutorial = false },
    { id = "park_lunch", title = "公园门口便餐", pickupId = "breakfast", dropoffId = "park",
        route = { {x=-25,z=-8}, {x=-25,z=0}, {x=100,z=0}, {x=100,z=-25}, {x=108,z=-25} }, timeLimitHours = 1, tutorial = false },
}

---@param route CareerRoutePoint[]
---@return number
function Config.RouteDistance(route)
    local result = 0
    for i = 2, #route do
        local a, b = route[i - 1], route[i]
        result = result + math.sqrt((b.x - a.x)^2 + (b.z - a.z)^2)
    end
    return result
end

---@param distanceMeters number
---@return integer
function Config.FeeCents(distanceMeters)
    return math.floor(math.max(250, math.min(1000, 250 + 150 * distanceMeters / 1000)) + 0.5)
end

---@param id string
---@return CareerOrderTemplate?
function Config.GetTemplate(id)
    for _, template in ipairs(Config.orderTemplates) do
        if template.id == id then return template end
    end
    return nil
end

---@param pointId string
---@param x number
---@param z number
---@return number
function Config.DistanceTo(pointId, x, z)
    local point = Config.points[pointId]
    if not point then return math.huge end
    return math.sqrt((point.x - x)^2 + (point.z - z)^2)
end

return Config
