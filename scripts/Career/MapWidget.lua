-- Shared-world map, rendered entirely with UI panels. No separate NanoVG frame.
local UI = require("urhox-libs/UI")
local Theme = require("RacingTheme")
local World = require("Career.WorldData")
local Config = require("Career.Config")
local C = Theme.Colors
local GRID = 32 -- metres; geometry/routing are cached between window cells.
local ROAD_COLOR = {92, 111, 120, 150}
local ORDER_COLOR = {125, 145, 158, 140}

---@class CareerMapPosition
---@field x number
---@field z number

---@class CareerMapActor
---@field x? number
---@field z? number
---@field yaw? number

---@class CareerMapTarget : CareerMapPosition
---@field id? string

---@class CareerMapOrder
---@field id? string
---@field status? string
---@field route? CareerMapPosition[]

---@class CareerMapWidget
---@field root Panel
---@field viewport Panel
---@field roads Panel
---@field route Panel
---@field orderRoute Panel
---@field points Panel
---@field player Panel
---@field heading Panel
---@field destination Panel
---@field edge Panel
---@field edgeDistance Label
---@field scaleLabel Label
local MapWidget = {}
MapWidget.__index = MapWidget

---@param parent Widget
local function destroyChildren(parent)
    -- ClearChildren only detaches; Destroy also frees the old Yoga nodes.
    for i = parent:GetNumChildren(), 1, -1 do
        local child = parent:GetChildAt(i)
        if child then child:Destroy() end
    end
end

---@return Panel
local function layer()
    return UI.Panel {position = "absolute", top = 0, right = 0, bottom = 0, left = 0,
        padding = 0, borderWidth = 0, pointerEvents = "none"}
end

---@param value number
---@param lo number
---@param hi number
---@return number
local function clamp(value, lo, hi)
    return math.max(lo, math.min(hi, value))
end

-- Clip the actual segment, never its endpoints independently. In particular,
-- two off-screen endpoints on the same side must not become a false edge road.
-- Liang-Barsky handles axis-aligned streets and diagonal connectors equally.
---@param ax number
---@param az number
---@param bx number
---@param bz number
---@param minX number
---@param maxX number
---@param minZ number
---@param maxZ number
---@return number?, number?, number?, number?
local function clip(ax, az, bx, bz, minX, maxX, minZ, maxZ)
    local dx, dz = bx - ax, bz - az
    local p = {-dx, dx, -dz, dz}
    local q = {ax - minX, maxX - ax, az - minZ, maxZ - az}
    local first, last = 0, 1
    for i = 1, 4 do
        if math.abs(p[i]) < 0.000001 then
            if q[i] < 0 then return nil end
        else
            local t = q[i] / p[i]
            if p[i] < 0 then first = math.max(first, t) else last = math.min(last, t) end
            if first > last then return nil end
        end
    end
    return ax + first * dx, az + first * dz, ax + last * dx, az + last * dz
end

---@param order CareerMapOrder
---@return string
local function orderKey(order)
    local parts = {tostring(order.id or ""), tostring(order.status or "")}
    for _, p in ipairs(order.route or {}) do
        parts[#parts + 1] = tostring(p.x) .. "," .. tostring(p.z)
    end
    return table.concat(parts, ":")
end

---@param distance number
---@return string
local function distanceText(distance)
    if distance >= 1000 then return string.format("%.1f公里", distance / 1000) end
    return string.format("%.0f米", distance)
end

---@param id? string
---@param overview? boolean Full-city view; the phone caller opts in with true.
---@return CareerMapWidget
function MapWidget.New(id, overview)
    local self = setmetatable({}, MapWidget)
    self:Init(id, overview)
    return self
end

---@param id? string
---@param overview? boolean
function MapWidget:Init(id, overview)
    self.id = id or "career-map"
    self.overview = overview == true
    self.width, self.height, self.scale = 0, 0, 1
    self.span = self.overview and World.LIMIT * 2 or 480
    self.centerX, self.centerZ = 0, 0
    self.actorX, self.actorZ, self.actorYaw = 0, 0, 0
    self.gridX, self.gridZ = math.huge, math.huge
    self.geometryKey, self.routeKey = "", ""
    self.targetKey, self.orderKey = "", ""
    self.hasTelemetry = false
    self.routeWarning = false
    ---@type CareerMapTarget?
    self.target = nil
    ---@type CareerMapOrder
    self.order = {}

    self.roads, self.points, self.route, self.orderRoute = layer(), layer(), layer(), layer()
    self.destination = UI.Panel {position = "absolute", width = 12, height = 12, padding = 0,
        borderWidth = 2, borderColor = C.amber, backgroundColor = {226, 177, 101, 30},
        marginLeft = -6, marginTop = -6, visible = false, pointerEvents = "none"}
    self.heading = UI.Panel {position = "absolute", left = 3, top = -5, width = 2, height = 7,
        backgroundColor = C.cyan, pointerEvents = "none", padding = 0}
    self.player = UI.Panel {id = self.id .. "-player", position = "absolute", width = 8, height = 8,
        marginLeft = -4, marginTop = -4, padding = 0, backgroundColor = C.cyan,
        borderWidth = 1, borderColor = {8, 15, 18, 255}, visible = false,
        pointerEvents = "none", children = {self.heading}}
    self.edge = Theme.Label(">", 16, C.amber, {position = "absolute", width = 18, height = 20,
        textAlign = "center", verticalAlign = "middle", marginLeft = -9, marginTop = -10,
        transformOrigin = "center", visible = false, pointerEvents = "none"})
    self.edgeDistance = Theme.Label("", 8, C.amber,
        {position = "absolute", left = 5, bottom = 1, visible = false, pointerEvents = "none"})
    self.scaleLabel = Theme.Label(self.overview and "全城 · 30公里" or "局部 · 480米", 8, C.muted,
        {position = "absolute", right = 5, bottom = 1, pointerEvents = "none"})
    self.viewport = UI.Panel {position = "absolute", top = 10, right = 10, bottom = 14, left = 10,
        overflow = "hidden", padding = 0, borderWidth = 0, pointerEvents = "none", children = {
            self.roads, self.orderRoute, self.route, self.points, self.destination, self.player, self.edge,
        }}
    self.root = UI.Panel {id = self.id, width = "100%", height = 160, padding = 0,
        backgroundColor = {10, 17, 21, 240}, overflow = "hidden", pointerEvents = "none", children = {
            self.viewport, self.edgeDistance, self.scaleLabel,
            Theme.Label("N", 8, C.muted, {position = "absolute", top = 1, right = 4}),
        }}
    -- The phone may supply telemetry only once, before Yoga has laid out the map.
    -- Resize refreshes numeric line lengths/rotation without depending on another telemetry call.
    self.root.Update = function()
        local layout = self.viewport:GetLayout()
        if layout.w > 0 and layout.h > 0 and (layout.w ~= self.width or layout.h ~= self.height) then
            self.width, self.height = layout.w, layout.h
            if self.hasTelemetry then self:Refresh() end
        end
    end
end

---@param x number
---@param z number
---@return number, number
function MapWidget:Project(x, z)
    -- Projection deliberately does not clamp. Off-screen POIs are culled, not relocated.
    return self.width / 2 + (x - self.centerX) * self.scale,
        self.height / 2 - (z - self.centerZ) * self.scale
end

---@param parent Widget
---@param a CareerMapPosition
---@param b CareerMapPosition
---@param color table
---@param thickness number
function MapWidget:Segment(parent, a, b, color, thickness)
    local padding = self.overview and 0 or GRID
    local halfW, halfH = self.width / (2 * self.scale) + padding, self.height / (2 * self.scale) + padding
    local minX, maxX = self.centerX - halfW, self.centerX + halfW
    local minZ, maxZ = self.centerZ - halfH, self.centerZ + halfH
    if self.overview then
        minX, maxX = math.max(-World.LIMIT, minX), math.min(World.LIMIT, maxX)
        minZ, maxZ = math.max(-World.LIMIT, minZ), math.min(World.LIMIT, maxZ)
    end
    local ax, az, bx, bz = clip(a.x, a.z, b.x, b.z, minX, maxX, minZ, maxZ)
    if not ax or not az or not bx or not bz then return end
    local x1, y1 = self:Project(ax, az)
    local x2, y2 = self:Project(bx, bz)
    local dx, dy = x2 - x1, y2 - y1
    local length = math.sqrt(dx * dx + dy * dy)
    if length < 0.01 then return end
    if math.abs(dx) < 0.001 then
        parent:AddChild(UI.Panel {position = "absolute", left = x1 - thickness / 2,
            top = math.min(y1, y2), width = thickness, height = math.abs(dy),
            backgroundColor = color, pointerEvents = "none", padding = 0, borderWidth = 0})
    elseif math.abs(dy) < 0.001 then
        parent:AddChild(UI.Panel {position = "absolute", left = math.min(x1, x2),
            top = y1 - thickness / 2, width = math.abs(dx), height = thickness,
            backgroundColor = color, pointerEvents = "none", padding = 0, borderWidth = 0})
    else
        -- UI rotate is in degrees, about transformOrigin (verified in UI/Core/UI.lua).
        -- Length is computed in actual layout pixels, so non-square phone maps stay accurate.
        parent:AddChild(UI.Panel {position = "absolute", left = (x1 + x2 - length) / 2,
            top = (y1 + y2 - thickness) / 2, width = length, height = thickness,
            rotate = math.atan(dy, dx) * 180 / math.pi, transformOrigin = "center",
            backgroundColor = color, pointerEvents = "none", padding = 0, borderWidth = 0})
    end
end

function MapWidget:RebuildGeometry()
    destroyChildren(self.roads)
    destroyChildren(self.points)
    for _, road in ipairs(World.Roads) do
        if not self.overview or road.kind == "arterial" then
            local thickness = self.overview and 2 or clamp(road.width * self.scale, 2, 7)
            self:Segment(self.roads, road.a, road.b, ROAD_COLOR, thickness)
        end
    end
    local padding = self.overview and 0 or GRID * self.scale
    if not self.overview then
        -- Config merges the original street/house entrances with World.Points.
        for _, point in ipairs(Config.pointList) do
            local x, y = self:Project(point.x, point.z)
            if x >= -padding and x <= self.width + padding and y >= -padding and y <= self.height + padding then
                self.points:AddChild(UI.Panel {id = self.id .. "-point-" .. point.id,
                    position = "absolute", left = x - 3, top = y - 3,
                    width = 6, height = 6, padding = 0, borderWidth = 0,
                    backgroundColor = point.kind == "rest" and C.green or C.muted, pointerEvents = "none"})
            end
        end
    else
        -- At 30km scale use one target per district, not dozens of coincident POIs.
        -- Always retain its true marker; suppress only colliding text labels.
        local districts = {World.District(0, 0)}
        for _, district in ipairs(World.Districts) do districts[#districts + 1] = district end
        ---@type table[]
        local labels = {}
        for _, district in ipairs(districts) do
            local x, y = self:Project(district.x, district.z)
            if x >= 0 and x <= self.width and y >= 0 and y <= self.height then
                self.points:AddChild(UI.Panel {id = self.id .. "-district-" .. district.id,
                    position = "absolute", left = x - 2, top = y - 2, width = 4, height = 4,
                    padding = 0, borderWidth = 0, backgroundColor = C.muted, pointerEvents = "none"})
                for _, offset in ipairs({5, -17, 20, -32}) do
                    local left, top = clamp(x - 30, 0, math.max(0, self.width - 60)), y + offset
                    local free = top >= 0 and top + 13 <= self.height
                    for _, box in ipairs(labels) do
                        if left < box.x + 62 and left + 62 > box.x and top < box.y + 15 and top + 15 > box.y then
                            free = false
                            break
                        end
                    end
                    if free then
                        labels[#labels + 1] = {x = left, y = top}
                        self.points:AddChild(Theme.Label(district.label, 8, C.muted, {
                            position = "absolute", left = left, top = top,
                            width = 60, height = 13, textAlign = "center", pointerEvents = "none",
                        }))
                        break
                    end
                end
            end
        end
    end
end

function MapWidget:RebuildRoutes()
    destroyChildren(self.orderRoute)
    destroyChildren(self.route)
    -- Saved order geometry is historical/priced geometry, not the player's navigation.
    local previous = self.order.route or {}
    for i = 2, #previous do self:Segment(self.orderRoute, previous[i - 1], previous[i], ORDER_COLOR, 2) end
    local target = self.target
    if target then
        local result, reason = World.Route(self.actorX, self.actorZ, target.x, target.z)
        local points = result --[[@as CareerMapPosition[]?]]
        if points then
            for i = 2, #points do self:Segment(self.route, points[i - 1], points[i], C.amber, 3) end
            self.routeWarning = false
        elseif not self.routeWarning then
            -- No fabricated straight-line route if the shared road graph has no path.
            print("[CareerMap] Navigation unavailable: " .. tostring(reason))
            self.routeWarning = true
        end
    else
        self.routeWarning = false
    end
end

function MapWidget:UpdateMarkers()
    local shiftX = self.overview and 0 or (self.centerX - self.actorX) * self.scale
    local shiftY = self.overview and 0 or (self.actorZ - self.centerZ) * self.scale
    -- Smooth panning within a 32m cell: only styles change, never the UI tree.
    for _, panel in ipairs({self.roads, self.orderRoute, self.route, self.points}) do
        panel:SetStyle({translateX = shiftX, translateY = shiftY})
    end
    local px, py = self:Project(self.actorX, self.actorZ)
    self.player:SetVisible(self.overview and px >= 0 and px <= self.width and py >= 0 and py <= self.height or not self.overview)
    self.player:SetStyle({left = px + shiftX, top = py + shiftY, rotate = self.actorYaw})
    local target = self.target
    self.destination:SetVisible(false)
    self.edge:SetVisible(false)
    self.edgeDistance:SetVisible(false)
    if not target then return end
    local rawX, rawY = self:Project(target.x, target.z)
    local x, y = rawX + shiftX, rawY + shiftY
    if x >= 0 and x <= self.width and y >= 0 and y <= self.height then
        self.destination:SetVisible(true)
        self.destination:SetStyle({left = x, top = y})
    else
        -- This is explicitly an edge chevron, never an ordinary nearby target marker.
        local dx, dy = x - self.width / 2, y - self.height / 2
        local inset = math.min(12, self.width / 4, self.height / 4)
        local tx = math.abs(dx) > 0.000001 and (self.width / 2 - inset) / math.abs(dx) or math.huge
        local ty = math.abs(dy) > 0.000001 and (self.height / 2 - inset) / math.abs(dy) or math.huge
        local factor = math.min(tx, ty)
        self.edge:SetStyle({left = self.width / 2 + dx * factor, top = self.height / 2 + dy * factor,
            rotate = math.atan(dy, dx) * 180 / math.pi})
        self.edge:SetVisible(true)
        local distance = math.sqrt((target.x - self.actorX)^2 + (target.z - self.actorZ)^2)
        self.edgeDistance:SetText("图外目标 · " .. distanceText(distance))
        self.edgeDistance:SetVisible(true)
    end
end

function MapWidget:Refresh()
    if self.width <= 0 or self.height <= 0 then return end
    local gx, gz = math.floor(self.actorX / GRID), math.floor(self.actorZ / GRID)
    -- Old street detail, transition belt, then wider outer-city navigation.
    local radius = math.max(math.abs(self.actorX), math.abs(self.actorZ))
    self.span = self.overview and World.LIMIT * 2 or (radius <= World.OLD_LIMIT + GRID and 480 or (radius < 1200 and 800 or 1200))
    self.scale = math.min(self.width, self.height) / self.span
    self.centerX, self.centerZ = self.overview and 0 or gx * GRID, self.overview and 0 or gz * GRID
    local viewKey = table.concat({self.width, self.height, self.span, self.centerX, self.centerZ}, ":")
    if viewKey ~= self.geometryKey then
        self.geometryKey = viewKey
        self:RebuildGeometry()
        self.scaleLabel:SetText(self.overview and "全城 · 30公里" or "局部 · " .. distanceText(self.span))
    end
    local key = viewKey .. ":" .. gx .. ":" .. gz .. ":" .. self.targetKey .. ":" .. self.orderKey
    if key ~= self.routeKey then
        self.routeKey = key
        self:RebuildRoutes()
    end
    self.gridX, self.gridZ = gx, gz
    self:UpdateMarkers()
end

---@param actor? CareerMapActor
---@param target? CareerMapTarget
---@param order? CareerMapOrder
function MapWidget:SetTelemetry(actor, target, order)
    local position = actor or {}
    self.actorX, self.actorZ, self.actorYaw = position.x or 0, position.z or 0, position.yaw or 0
    if target and type(target.x) == "number" and type(target.z) == "number" then
        self.target = {x = target.x, z = target.z, id = target.id}
        self.targetKey = tostring(target.id or "") .. ":" .. target.x .. ":" .. target.z
    else
        self.target, self.targetKey = nil, ""
    end
    self.order = order or {}
    self.orderKey = orderKey(self.order)
    self.hasTelemetry = true
    local layout = self.viewport:GetLayout()
    if layout.w > 0 and layout.h > 0 then self.width, self.height = layout.w, layout.h end
    self:Refresh()
end

return MapWidget
