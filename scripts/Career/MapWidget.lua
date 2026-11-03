-- Shared-world map, rendered entirely with UI panels. No separate NanoVG frame.
local UI = require("urhox-libs/UI")
local Theme = require("RacingTheme")
local World = require("Career.WorldData")
local Expansion = require("Career.CityExpansion")
local Config = require("Career.Config")
local Environment = require("Career.CityEnvironment")
local C = Theme.Colors
local GRID = 32 -- metres; geometry/routing are cached between window cells.
local MIN_SPAN = 120
local ROAD_COLOR = {158, 165, 168, 210}
local ARTERIAL_COLOR = {212, 216, 218, 240}
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
---@field pointId? string
---@field name? string
---@field route? CareerMapPosition[]

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
---@field navigationPoints CareerMapPosition[]
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
    -- Zero means automatic legacy span. Fixed browsing is independent of overview:
    -- telemetry must never reset an explicitly selected centre/zoom.
    self.manualSpan = 0
    self.followActor = not self.overview
    self.focusX, self.focusZ = 0, 0
    self.detailed = false
    self.centerX, self.centerZ = 0, 0
    self.actorX, self.actorZ, self.actorYaw = 0, 0, 0
    self.gridX, self.gridZ = math.huge, math.huge
    self.geometryKey, self.routeKey = "", ""
    self.navigationKey = ""
    ---@type CareerMapPosition[]
    self.navigationPoints = {}
    ---@type table[]
    self.labelBoxes = {}
    self.targetKey, self.targetRouteKey, self.orderKey = "", "", ""
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

-- Span is metres across the SHORT side, so streets never stretch on wide screens.
---@param span number
function MapWidget:SetSpan(span)
    if span ~= span or span <= 0 or span == math.huge then return end
    self.manualSpan = clamp(span, MIN_SPAN, World.LIMIT * 2)
    self:Refresh()
end

---@param zoom number Absolute magnification relative to the constructor's default.
function MapWidget:SetZoom(zoom)
    if zoom ~= zoom or zoom <= 0 then return end
    self:SetSpan((self.overview and World.LIMIT * 2 or 480) / zoom)
end

---@param factor number >1 zooms in, <1 zooms out; centred on the current view.
function MapWidget:Zoom(factor)
    if factor ~= factor or factor <= 0 then return end
    self:SetSpan((self.manualSpan > 0 and self.manualSpan or self.span) / factor)
end

---@param x number World metres, east positive.
---@param z number World metres, north positive. Disables automatic actor following.
function MapWidget:SetCenter(x, z)
    if x ~= x or z ~= z then return end
    self.followActor = false
    self.focusX, self.focusZ = clamp(x, -World.LIMIT, World.LIMIT), clamp(z, -World.LIMIT, World.LIMIT)
    self:Refresh()
end

---@param dx number World metres, east positive.
---@param dz number World metres, north positive.
function MapWidget:Pan(dx, dz)
    local x = self.followActor and self.actorX or self.focusX
    local z = self.followActor and self.actorZ or self.focusZ
    self:SetCenter(x + dx, z + dz)
end

---@param dx number Fraction of viewport width, right positive.
---@param dy number Fraction of viewport height, down positive. No drag/scroll handler.
function MapWidget:PanByScreen(dx, dy)
    local scale = math.max(self.scale, 0.000001)
    self:Pan(dx * self.width / scale, -dy * self.height / scale)
end

---@param span? number Keep following actor; optional explicit span in metres.
function MapWidget:FocusPlayer(span)
    self.followActor = true
    if span then self:SetSpan(span) else self:Refresh() end
end

---@param enabled boolean Extra labels and real local-road layers, opt-in for the large map.
function MapWidget:SetDetailed(enabled)
    if self.detailed == enabled then return end
    self.detailed = enabled
    self.geometryKey = ""
    self:Refresh()
end

-- Restores the original constructor behaviour, including automatic local span.
function MapWidget:ResetView()
    self.manualSpan = 0
    self.followActor = not self.overview
    self.focusX, self.focusZ = 0, 0
    self:Refresh()
end

---@return table
function MapWidget:GetView()
    return {x = self.followActor and self.actorX or self.focusX,
        z = self.followActor and self.actorZ or self.focusZ,
        span = self.manualSpan > 0 and self.manualSpan or self.span,
        zoom = (self.overview and World.LIMIT * 2 or 480) / self.span,
        followActor = self.followActor, minSpan = MIN_SPAN, maxSpan = World.LIMIT * 2}
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
    local padding = self.followActor and GRID or 0
    local halfW, halfH = self.width / (2 * self.scale) + padding, self.height / (2 * self.scale) + padding
    local minX, maxX = math.max(-World.LIMIT, self.centerX - halfW), math.min(World.LIMIT, self.centerX + halfW)
    local minZ, maxZ = math.max(-World.LIMIT, self.centerZ - halfH), math.min(World.LIMIT, self.centerZ + halfH)
    if minX > maxX or minZ > maxZ then return end
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

-- Text gets its own collision budget; true markers are never displaced to fit text.
---@param text string
---@param x number
---@param y number
---@param color table
---@param size number
---@return boolean
function MapWidget:PlaceLabel(text, x, y, color, size)
    local count = utf8.len(text) or #text
    local width = math.min(self.width, math.max(40, count * size * 1.3 + 10))
    local height = size * 1.6 + 4
    for _, offset in ipairs({7, -height - 7, 22, -height - 22}) do
        local left, top = clamp(x - width / 2, 0, math.max(0, self.width - width)), y + offset
        local free = top >= 0 and top + height <= self.height
        for _, box in ipairs(self.labelBoxes) do
            if left < box.x + box.w + 4 and left + width + 4 > box.x
                and top < box.y + box.h + 3 and top + height + 3 > box.y then free = false; break end
        end
        if free then
            self.labelBoxes[#self.labelBoxes + 1] = {x = left, y = top, w = width, h = height}
            self.points:AddChild(Theme.Label(text, size, color, {position = "absolute", left = left, top = top,
                width = width, height = height, textAlign = "center", verticalAlign = "middle", maxLines = 1,
                backgroundColor = {10, 17, 21, 215}, pointerEvents = "none"}))
            return true
        end
    end
    return false
end

---@param x number
---@param z number
---@param width number
---@param depth number
---@param color table
function MapWidget:GroundRect(x, z, width, depth, color)
    local left, top = self:Project(x - width / 2, z + depth / 2)
    local right, bottom = self:Project(x + width / 2, z - depth / 2)
    left, top, right, bottom = math.max(0, left), math.max(0, top), math.min(self.width, right), math.min(self.height, bottom)
    if right <= left or bottom <= top then return end
    self.roads:AddChild(UI.Panel {position = "absolute", left = left, top = top, width = right - left,
        height = bottom - top, padding = 0, borderWidth = 0, backgroundColor = color, pointerEvents = "none"})
end

-- 普通雷达与全屏地图共用同一图层，避免只有某个入口能看到步行连接。
function MapWidget:RebuildWalkGeometry()
    if self.span>6000 then return end
    local color={117,181,155,240}
    local hills=require("Career.HillDistrict")
    local river=hills.River
    self:GroundRect((river.x1+river.x2)/2,(river.z1+river.z2)/2,river.x2-river.x1,river.z2-river.z1,{23,57,70,230})
    for _,route in ipairs(hills.Routes) do
        ---@type CareerMapPosition[]
        local points=route.points
        for i=2,#points do
            self:Segment(self.roads,assert(points[i-1]),assert(points[i]),{205,183,118,255},clamp(16*self.scale,2,8))
        end
        if self.detailed then
            local x,y=self:Project(0,1280)
            if x>=0 and x<=self.width and y>=0 and y<=self.height then self:PlaceLabel("北岭跨谷公路",x,y,C.amber,10) end
        end
    end
    for _,bridge in ipairs(World.Bridges) do
        local b=bridge --[[@as {id:string,x:number,z:number,halfSpan:number,width:number}]]
        self:Segment(self.roads,{x=b.x-b.halfSpan,z=b.z},{x=b.x+b.halfSpan,z=b.z},color,clamp(b.width*self.scale,2,6))
        for _,side in ipairs({-1,1}) do
            self:Segment(self.roads,{x=b.x+side*20,z=b.z-68},{x=b.x+side*20,z=b.z},color,clamp(b.width*self.scale,2,6))
        end
        local x,y=self:Project(b.x,b.z)
        -- 小雷达只画连接，不堆长禁行文案；详细全图才显示步行层名称。
        if self.detailed and self.span<=1800 and x>=0 and x<=self.width and y>=0 and y<=self.height then
            self:PlaceLabel("步行连接",x,y,color,9)
        end
    end
    for _,points in pairs(Environment.ApproachRoutes) do
        ---@type CareerMapPosition[]
        local route=points
        for i=2,#route do self:Segment(self.roads,assert(route[i-1]),assert(route[i]),color,2) end
    end
    local deck=Environment.Boardwalk
    self:Segment(self.roads,{x=(deck.x1+deck.x2)/2,z=deck.z1},{x=(deck.x1+deck.x2)/2,z=deck.z2},color,clamp(8*self.scale,2,7))
end

function MapWidget:RebuildFootprints()
    -- 窄条雷达的长边可能覆盖数公里：建筑层按实际世界窗口做LOD，避免横宽比放大扫描量。
    if self.span>1200 or math.max(self.width,self.height)/self.scale>1800 then return end
    local padding=self.followActor and GRID or 0
    local halfW,halfH=self.width/(2*self.scale)+padding,self.height/(2*self.scale)+padding
    -- 只描述可见窗口及一格邻接，不扫描30公里全域；沿用WorldData自身有界缓存。
    local minX,maxX=math.max(-World.LIMIT,self.centerX-halfW),math.min(World.LIMIT,self.centerX+halfW)
    local minZ,maxZ=math.max(-World.LIMIT,self.centerZ-halfH),math.min(World.LIMIT,self.centerZ+halfH)
    for ix=math.floor(minX/World.CELL)-1,math.floor(maxX/World.CELL)+1 do
        for iz=math.floor(minZ/World.CELL)-1,math.floor(maxZ/World.CELL)+1 do
            for _,o in ipairs(World.DescribeCell(ix,iz).obstacles) do
                if o.kind=="building" then
                    self:GroundRect((o.x1+o.x2)/2,(o.z1+o.z2)/2,o.x2-o.x1,o.z2-o.z1,{43,53,58,200})
                end
            end
        end
    end
end

function MapWidget:RebuildDetailGeometry()
    self.labelBoxes = {}
    self:RebuildFootprints()
    -- 建筑占地来自全部可见WorldData块，不再只显示开局邻里。
    if self.span <= 1800 then
        for _, plaza in ipairs(Expansion.Plazas) do
            self:GroundRect(plaza.x, plaza.z, plaza.w, plaza.d, {45, 73, 65, 210})
        end
        -- Water uses the same obstacle rectangles as collision (pier gap retained).
        for _, water in ipairs(Environment.StaticObstacles) do
            if water.kind == "water" then
                self:GroundRect((water.x1 + water.x2) / 2, (water.z1 + water.z2) / 2,
                    water.x2 - water.x1, water.z2 - water.z1, {23, 57, 70, 230})
            end
        end
    end
    for _, road in ipairs(World.Roads) do
        -- 192m district street spacing: only reveal at a legible projected spacing.
        if road.kind == "arterial" or self.scale * 192 >= 7 then
            local color = road.kind == "arterial" and ARTERIAL_COLOR or ROAD_COLOR
            self:Segment(self.roads, road.a, road.b, color, clamp(road.width * self.scale, 1.5, 9))
        end
    end
    if self.span <= 6000 then
        for _, road in ipairs(Expansion.Roads) do
            self:Segment(self.roads, {x = road.x1, z = road.z1}, {x = road.x2, z = road.z2},
                road.kind == "alley" and C.steel or ROAD_COLOR, clamp(road.width * self.scale, 1.5, 9))
        end
    end
    self:RebuildWalkGeometry()
    -- District centres and names are sourced directly from WorldData.
    local districts = {World.District(0, 0)}
    for _, district in ipairs(World.Districts) do districts[#districts + 1] = district end
    for _, district in ipairs(districts) do
        local x, y = self:Project(district.x, district.z)
        if x >= 0 and x <= self.width and y >= 0 and y <= self.height then
            self.points:AddChild(UI.Panel {id = self.id .. "-district-" .. district.id,
                position = "absolute", left = x - 3, top = y - 3, width = 6, height = 6,
                padding = 0, borderWidth = 1, borderColor = C.cyan, pointerEvents = "none"})
            self:PlaceLabel(district.label, x, y, C.cyan, 11)
        end
    end
    if self.span <= 6000 then
        local colors = {rest = C.green, charge = C.cyan, merchant = C.amber, scenery = C.green,
            housing = C.steel, dealer = C.amber, delivery = C.white}
        -- Active destination labels have priority over all other POI labels.
        local target = self.target
        if target then
            local x, y = self:Project(target.x, target.z)
            if x >= 0 and x <= self.width and y >= 0 and y <= self.height then
                local point = Config.points[target.pointId or target.id or ""]
                self:PlaceLabel(point and point.label or target.name or "目的地", x, y, C.amber, 11)
            end
        end
        for _, point in ipairs(Config.pointList) do
            local x, y = self:Project(point.x, point.z)
            if x >= 0 and x <= self.width and y >= 0 and y <= self.height then
                local color = colors[point.kind] or C.muted
                self.points:AddChild(UI.Panel {id = self.id .. "-point-" .. point.id, position = "absolute",
                    left = x - 3, top = y - 3, width = 6, height = 6, padding = 0,
                    borderWidth = 1, borderColor = {10, 17, 21, 255}, backgroundColor = color, pointerEvents = "none"})
                if self.span <= 1800 and (not target or point.id ~= (target.pointId or target.id)) then
                    self:PlaceLabel(point.label, x, y, color, 10)
                end
            end
        end
    end
    if self.span <= 1000 then
        local names = {}
        for _, road in ipairs(Expansion.Roads) do
            local x, y = self:Project((road.x1 + road.x2) / 2, (road.z1 + road.z2) / 2)
            if not names[road.name] and x >= 0 and x <= self.width and y >= 0 and y <= self.height then
                if self:PlaceLabel(road.name, x, y, C.muted, 9) then names[road.name] = true end
            end
        end
        for _, plaza in ipairs(Expansion.Plazas) do
            local x, y = self:Project(plaza.x, plaza.z)
            if x >= 0 and x <= self.width and y >= 0 and y <= self.height then self:PlaceLabel(plaza.name, x, y, C.green, 9) end
        end
    end
end

function MapWidget:RebuildGeometry()
    destroyChildren(self.roads)
    destroyChildren(self.points)
    if self.detailed then self:RebuildDetailGeometry(); return end
    self.labelBoxes={}
    if not self.overview then self:RebuildFootprints() end
    for _, road in ipairs(World.Roads) do
        if not self.overview or road.kind == "arterial" then
            local thickness = self.overview and 2 or clamp(road.width * self.scale, 2, 7)
            self:Segment(self.roads, road.a, road.b, ROAD_COLOR, thickness)
        end
    end
    if not self.overview then
        -- 邻里接续道路只补局部可见几何；历史订单路线仍来自原共享路网。
        for _,road in ipairs(Expansion.Roads) do
            local thickness=clamp(road.width*self.scale,2,7)
            self:Segment(self.roads,{x=road.x1,z=road.z1},{x=road.x2,z=road.z2},ROAD_COLOR,thickness)
        end
        self:RebuildWalkGeometry()
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
        -- Session.Target already owns coast/exit routing. Preserve its authoritative
        -- polyline rather than asking the older World graph to invent a shortcut.
        local key = self.targetKey .. ":" .. self.targetRouteKey .. ":" .. math.floor(self.actorX / GRID) .. ":" .. math.floor(self.actorZ / GRID)
        if key ~= self.navigationKey then
            self.navigationKey = key
            if target.route then
                self.navigationPoints = target.route
            else
                local result, reason = World.Route(self.actorX, self.actorZ, target.x, target.z)
                self.navigationPoints = result or {} --[[@as CareerMapPosition[]?]]
                if not result and not self.routeWarning then
                    print("[CareerMap] Navigation unavailable: " .. tostring(reason))
                    self.routeWarning = true
                end
                if result then self.routeWarning = false end
            end
        end
        for i = 2, #self.navigationPoints do
            local a, b = self.navigationPoints[i - 1], self.navigationPoints[i]
            if a and b then self:Segment(self.route, a, b, C.amber, 3) end
        end
    else
        self.navigationKey, self.navigationPoints = "", {}
        self.routeWarning = false
    end
end

function MapWidget:UpdateMarkers()
    local shiftX = self.followActor and (self.centerX - self.actorX) * self.scale or 0
    local shiftY = self.followActor and (self.actorZ - self.centerZ) * self.scale or 0
    -- Smooth panning within a 32m cell: only styles change, never the UI tree.
    for _, panel in ipairs({self.roads, self.orderRoute, self.route, self.points}) do
        panel:SetStyle({translateX = shiftX, translateY = shiftY})
    end
    local px, py = self:Project(self.actorX, self.actorZ)
    self.player:SetVisible(self.hasTelemetry and (self.followActor or px >= 0 and px <= self.width and py >= 0 and py <= self.height))
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
        self.edgeDistance:SetText("图外 · 直线 " .. distanceText(distance))
        self.edgeDistance:SetVisible(true)
    end
end

function MapWidget:Refresh()
    if self.width <= 0 or self.height <= 0 then return end
    local gx, gz = math.floor(self.actorX / GRID), math.floor(self.actorZ / GRID)
    -- Old street detail, transition belt, then wider outer-city navigation.
    local radius = math.max(math.abs(self.actorX), math.abs(self.actorZ))
    self.span = self.manualSpan > 0 and self.manualSpan or (self.overview and World.LIMIT * 2
        or (radius <= World.OLD_LIMIT + GRID and 480 or (radius < 1200 and 800 or 1200)))
    self.scale = math.min(self.width, self.height) / self.span
    self.centerX, self.centerZ = self.followActor and gx * GRID or self.focusX, self.followActor and gz * GRID or self.focusZ
    local viewKey = table.concat({self.width, self.height, self.span, self.centerX, self.centerZ,
        tostring(self.followActor), tostring(self.detailed), self.detailed and self.targetKey or ""}, ":")
    if viewKey ~= self.geometryKey then
        self.geometryKey = viewKey
        self:RebuildGeometry()
        local mode = self.span >= World.LIMIT * 2 and "全城" or self.span > 1800 and "城区" or "街巷"
        self.scaleLabel:SetText((self.detailed and mode or (self.overview and "全城" or "局部")) .. " · " .. distanceText(self.span))
    end
    local key = viewKey .. ":" .. gx .. ":" .. gz .. ":" .. self.targetKey .. ":" .. self.targetRouteKey .. ":" .. self.orderKey
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
        self.target = {x = target.x, z = target.z, id = target.id, pointId = target.pointId,
            name = target.name, route = target.route}
        self.targetKey = tostring(target.pointId or target.id or "") .. ":" .. target.x .. ":" .. target.z
        self.targetRouteKey = target.route and orderKey({route = target.route}) or ""
    else
        self.target, self.targetKey, self.targetRouteKey = nil, "", ""
    end
    self.order = order or {}
    self.orderKey = orderKey(self.order)
    self.hasTelemetry = true
    local layout = self.viewport:GetLayout()
    if layout.w > 0 and layout.h > 0 then self.width, self.height = layout.w, layout.h end
    self:Refresh()
end

return MapWidget
