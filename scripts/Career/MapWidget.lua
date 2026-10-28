-- Declarative street map: same Config landmarks as gameplay, no separate renderer/frame.
local UI = require("urhox-libs/UI")
local Theme = require("RacingTheme")
local Config = require("Career.Config")
local C = Theme.Colors

---@class CareerMapWidget
local MapWidget = {}
MapWidget.__index = MapWidget

local function percent(value)
    return string.format("%.4f%%", value)
end
local function mapX(x)
    return (math.max(-180, math.min(180, x or 0)) + 180) / 360 * 100
end
local function mapY(z)
    return (180 - math.max(-180, math.min(180, z or 0))) / 360 * 100
end
local function segment(parent, a, b, color, thickness)
    local x1, y1, x2, y2 = mapX(a.x), mapY(a.z), mapX(b.x), mapY(b.z)
    -- Config routes follow axis-aligned city streets; never imply an off-road shortcut.
    if math.abs(x1 - x2) > 0.01 and math.abs(y1 - y2) > 0.01 then return end
    if math.abs(x1 - x2) <= 0.01 then
        parent:AddChild(UI.Panel {position = "absolute", left = percent(x1), top = percent(math.min(y1, y2)),
            marginLeft = -thickness / 2, width = thickness, height = percent(math.abs(y2 - y1)),
            backgroundColor = color, pointerEvents = "none", padding = 0})
    else
        parent:AddChild(UI.Panel {position = "absolute", left = percent(math.min(x1, x2)), top = percent(y1),
            marginTop = -thickness / 2, height = thickness, width = percent(math.abs(x2 - x1)),
            backgroundColor = color, pointerEvents = "none", padding = 0})
    end
end

function MapWidget.New(id)
    local self = setmetatable({}, MapWidget)
    self:Init(id)
    return self
end
function MapWidget:Init(id)
    self.routeKey = ""
    self.lastX, self.lastZ, self.lastYaw = math.huge, math.huge, math.huge
    self.roads = UI.Panel {position = "absolute", top = 10, right = 10, bottom = 10, left = 10,
        padding = 0, pointerEvents = "none"}
    local roadColor = {92, 111, 120, 150}
    for _, x in ipairs({-100, 0, 100}) do
        segment(self.roads, {x = x, z = -180}, {x = x, z = 180}, roadColor, 3)
    end
    for _, z in ipairs({0, 100}) do
        segment(self.roads, {x = -180, z = z}, {x = 180, z = z}, roadColor, 3)
    end
    -- City boundary and outer ring share the world extent [-180,180].
    segment(self.roads, {x = -180, z = -180}, {x = 180, z = -180}, roadColor, 3)
    segment(self.roads, {x = -180, z = 180}, {x = 180, z = 180}, roadColor, 3)
    segment(self.roads, {x = -180, z = -180}, {x = -180, z = 180}, roadColor, 3)
    segment(self.roads, {x = 180, z = -180}, {x = 180, z = 180}, roadColor, 3)
    self.route = UI.Panel {position = "absolute", top = 0, right = 0, bottom = 0, left = 0,
        padding = 0, pointerEvents = "none"}
    self.roads:AddChild(self.route)
    for _, point in ipairs(Config.pointList) do
        self.roads:AddChild(UI.Panel {id = (id or "career-map") .. "-point-" .. point.id,
            position = "absolute", left = percent(mapX(point.x)), top = percent(mapY(point.z)),
            marginLeft = -3, marginTop = -3, width = 6, height = 6, padding = 0,
            backgroundColor = point.kind == "rest" and C.green or C.muted, pointerEvents = "none"})
    end
    self.destination = UI.Panel {position = "absolute", width = 12, height = 12, padding = 0,
        borderWidth = 2, borderColor = C.amber, backgroundColor = {226, 177, 101, 30},
        marginLeft = -6, marginTop = -6, visible = false, pointerEvents = "none"}
    self.heading = UI.Panel {position = "absolute", left = 3, top = -5, width = 2, height = 7,
        backgroundColor = C.cyan, pointerEvents = "none", padding = 0}
    self.player = UI.Panel {position = "absolute", left = "50%", top = "50%", width = 8, height = 8,
        marginLeft = -4, marginTop = -4, padding = 0, backgroundColor = C.cyan,
        borderWidth = 1, borderColor = {8, 15, 18, 255}, pointerEvents = "none", children = {self.heading}}
    self.roads:AddChild(self.destination)
    self.roads:AddChild(self.player)
    self.root = UI.Panel {id = id or "career-map", width = "100%", height = 160, padding = 0,
        backgroundColor = {10, 17, 21, 240}, overflow = "hidden", pointerEvents = "none", children = {
            self.roads,
            Theme.Label("N", 8, C.muted, {position = "absolute", top = 1, right = 4}),
        }}
end

---@param actor table?
---@param target table?
---@param order table?
function MapWidget:SetTelemetry(actor, target, order)
    actor, target, order = actor or {}, target or {}, order or {}
    local x, z, yaw = actor.x or 0, actor.z or 0, actor.yaw or 0
    if x ~= self.lastX or z ~= self.lastZ or yaw ~= self.lastYaw then
        self.player:SetStyle({left = percent(mapX(x)), top = percent(mapY(z)), rotate = yaw})
        self.lastX, self.lastZ, self.lastYaw = x, z, yaw
    end
    self.destination:SetVisible(type(target.x) == "number" and type(target.z) == "number")
    if type(target.x) == "number" and type(target.z) == "number" then
        self.destination:SetStyle({left = percent(mapX(target.x)), top = percent(mapY(target.z))})
    end
    local key = tostring(order.id or "") .. ":" .. tostring(order.status or "")
    if key ~= self.routeKey then
        for _, child in ipairs(self.route:GetChildren()) do child:Destroy() end
        self.routeKey = key
        local points = order.route or {}
        for i = 2, #points do segment(self.route, points[i - 1], points[i], C.amber, 3) end
    end
end

return MapWidget
