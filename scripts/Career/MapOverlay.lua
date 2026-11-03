-- Fixed city atlas; no ScrollView, drag, swipe or wheel navigation.
-- View owns mounting/input blocking/time pause. This component only browses data
-- and emits an existing Config point id; it never teleports or edits world/save data.
local UI = require("urhox-libs/UI")
local Theme = require("RacingTheme")
local Map = require("Career.MapWidget")
local World = require("Career.WorldData")
local Config = require("Career.Config")
local Environment = require("Career.CityEnvironment")
local Hills = require("Career.HillDistrict")
local C = Theme.Colors
local PAGE_SIZE = 3
local COMPACT_PAGE_SIZE = 1

---@class CareerMapOverlayRegion
---@field id string
---@field label string
---@field x number
---@field z number
---@field span number

---@class CareerMapOverlay
---@field root Panel
---@field safe SafeAreaView
---@field body Panel
---@field stage Panel
---@field sidebar Panel
---@field map CareerMapWidget
---@field title Label
---@field regionTitle Label
---@field selection Label
---@field pageTitle Label
---@field zoomIn Button
---@field zoomOut Button
---@field previousPage Button
---@field nextPage Button
---@field navigate Button
---@field rows Button[]
---@field regions CareerMapOverlayRegion[]
---@field places CareerPoint[]
---@field actor CareerMapActor
---@field target CareerMapTarget?
---@field active CareerMapOrder?
---@field onClose fun()?
---@field onWaypoint fun(id:string)?
local Overlay = {}
Overlay.__index = Overlay

local function text(value, size, color, props)
    return Theme.Label(value, size, color, props)
end
local function button(id, value, action, width, primary)
    return Theme.Button(value, action, primary == true, width or 44, {
        id = "career-atlas-" .. id, height = 46, minHeight = 46, minWidth = 46,
        flexShrink = 0, padding = 3, paddingHorizontal = 3, fontSize = 11,
    })
end
local function distance(value)
    return value >= 1000 and string.format("%.1f公里", value / 1000) or string.format("%.0f米", value)
end

---@param onClose? fun()
---@param onWaypoint? fun(id:string)
---@return CareerMapOverlay
function Overlay.New(onClose, onWaypoint)
    local self = setmetatable({}, Overlay)
    self:Init(onClose, onWaypoint)
    return self
end

---@param onClose? fun()
---@param onWaypoint? fun(id:string)
function Overlay:Init(onClose, onWaypoint)
    self.onClose, self.onWaypoint = onClose, onWaypoint
    self.actor = {x = 0, z = 0, yaw = 0}
    self.regionIndex, self.page, self.selectedId = 1, 1, ""
    self.pageSize = PAGE_SIZE
    self.layoutWidth, self.layoutHeight = 0, 0
    self.places, self.rows, self.regions = {}, {}, {}
    self.regions[1] = {id = "old_town", label = World.District(0, 0).label, x = 0, z = 0, span = 1000}
    self.regions[2] = {id = "hills", label = "山城 · 滨江坡路", x = 0, z = 1120, span = 1600}
    for _, region in ipairs(World.Districts) do
        self.regions[#self.regions + 1] = {id = region.id, label = region.label,
            x = region.x, z = region.z, span = region.radius * 2 + 160}
    end
    local coast = Environment.Bounds
    self.regions[#self.regions + 1] = {id = "coast", label = "西南海岸", x = (coast.x1 + coast.x2) / 2,
        z = (coast.z1 + coast.z2) / 2, span = math.max(coast.x2 - coast.x1, coast.z2 - coast.z1) + 180}
    self.regions[#self.regions + 1] = {id = "greenbelt", label = "城郊 · 最近地点", x = 0, z = 0, span = 4000}

    self.map = Map.New("career-atlas-map", true)
    self.map:SetDetailed(true)
    self.map.root:SetStyle({position = "absolute", left = 0, right = 0, top = 0, bottom = 0,
        width = "100%", height = "100%", flexShrink = 1})
    self.title = text("南城地图", 16, C.white, {id = "career-atlas-title", flexGrow = 1, flexShrink = 1, maxLines = 1})
    local header = UI.Row {width = "100%", height = 46, minHeight = 46, gap = 8, alignItems = "center", padding = 0,
        paddingRight=2/math.max(.1,UI.GetScale()),
        children = {self.title, button("close", "关闭", function() self:Close() end, 68)}}

    self.zoomIn = button("zoom-in", "+", function() self:Zoom(2) end)
    self.zoomOut = button("zoom-out", "-", function() self:Zoom(.5) end)
    local zoom = UI.Row {position = "absolute", left = 8, top = 8, gap = 4, padding = 0,
        paddingRight=2/math.max(.1,UI.GetScale()),pointerEvents = "box-none",
        children = {self.zoomIn, self.zoomOut,
            button("city", "全城", function() self:ShowCity() end, 56),
            button("me", "本人", function() self:FocusPlayer() end, 56)}}
    -- All direction buttons pan the view centre, not the actor. +Z is north/up.
    local directions = UI.Panel {position = "absolute", right = 8, bottom = 22,
        width = 148, height = 148, padding = 0, gap = 4, alignItems = "center", pointerEvents = "box-none",
        children = {
            button("north", "北", function() self:Pan(0, -.3) end),
            UI.Row {gap = 4, padding = 0, pointerEvents = "box-none", children = {
                button("west", "西", function() self:Pan(-.3, 0) end),
                button("centre", "定位", function() self:FocusPlayer() end),
                button("east", "东", function() self:Pan(.3, 0) end),
            }},
            button("south", "南", function() self:Pan(0, .3) end),
        }}
    self.stage = UI.Panel {id = "career-atlas-stage", flexGrow = 1, flexShrink = 1, flexBasis = 0,
        minWidth = 0, minHeight = 0, padding = 0, overflow = "hidden", pointerEvents = "auto",
        children = {self.map.root, zoom, directions}}

    self.regionTitle = text("", 12, C.cyan, {id = "career-atlas-region", width="auto",flexBasis=0,minWidth=0,flexGrow = 1, flexShrink = 1,
        textAlign = "center", maxLines = 1, verticalAlign = "middle"})
    -- 分数缩放时独立端点取整可能使末按钮超出父行；保留真实右内边距，不放宽边界验收。
    local roundingInset=2/math.max(.1,UI.GetScale())
    local regionPicker = UI.Row {width="100%",height = 46, minHeight = 46, alignItems = "center", gap = 3, padding = 0,paddingRight=roundingInset,
        children = {
            button("region-prev", "<区", function() self:ChangeRegion(-1) end),
            self.regionTitle,
            button("region-next", "区>", function() self:ChangeRegion(1) end),
        }}
    local list = UI.Panel {id = "career-atlas-places", gap = 0, padding = 0, flexShrink = 0}
    for i = 1, PAGE_SIZE do
        local index = i
        local row = button("place-" .. i, "", function() self:SelectRow(index) end, "100%")
        self.rows[i] = row
        list:AddChild(row)
    end
    self.pageTitle = text("1 / 1", 10, C.muted, {id = "career-atlas-page",width="auto",flexBasis=0,minWidth=0,flexShrink=1,flexGrow = 1,
        textAlign = "center", verticalAlign = "middle"})
    self.previousPage = button("page-prev", "上页", function() self:ChangePage(-1) end, 54)
    self.nextPage = button("page-next", "下页", function() self:ChangePage(1) end, 54)
    local pages = UI.Row {width="100%",height = 46, minHeight = 46, gap = 4, padding = 0,paddingRight=roundingInset,
        children = {self.previousPage, self.pageTitle, self.nextPage}}
    self.selection = text("选择地点查看详情", 10, C.amber, {id = "career-atlas-selection",
        position = "absolute", left = 4, right = 4, bottom = 4, height = 18,
        minHeight = 18, maxLines = 1, verticalAlign = "middle", visible = false})
    self.navigate = button("navigate", "导航到所选地点", function() self:Navigate() end, "100%", true)
    self.sidebar = UI.Panel {id = "career-atlas-sidebar", width = 238, flexShrink = 0, padding = 2, gap = 2,
        backgroundColor = {19, 27, 32, 255}, overflow = "hidden", children = {
            regionPicker, list, pages, self.navigate,
        }}
    -- The informational line belongs on the map, not absolutely over the
    -- sidebar's final navigation button. Its 18px must never cover a touch target.
    self.stage:AddChild(self.selection)
    self.body = UI.Panel {id = "career-atlas-body", width = "100%", flexGrow = 1, flexShrink = 1,
        flexBasis = 0, minHeight = 0, padding = 0, gap = 6, flexDirection = "row", overflow = "hidden",
        children = {self.stage, self.sidebar}}
    self.safe = UI.SafeAreaView {width = "100%", height = "100%", nativeMenuInset = true,
        padding = 8, gap = 6, overflow = "hidden", children = {header, self.body}}
    self.root = UI.Panel {id = "career-map-overlay", position = "absolute", left = 0, top = 0, right = 0, bottom = 0,
        width = "100%", height = "100%", visible = false, padding = 0, overflow = "hidden", pointerEvents = "auto",
        backgroundColor = {8, 14, 18, 255}, children = {self.safe}}
    self.root.Update = function()
        if self:IsVisible() then self:RefreshLayout() end
    end
    self:RefreshPlaces()
end

-- Called by normal UI Update; tests can call this after UI.Layout, then layout
-- once more and call map.root:Update() to resolve numeric segment geometry.
function Overlay:RefreshLayout()
    local layout = self.body:GetLayout()
    if layout.w <= 0 or layout.h <= 0 then return end
    if layout.w == self.layoutWidth and layout.h == self.layoutHeight then return end
    self.layoutWidth, self.layoutHeight = layout.w, layout.h
    local portrait = layout.w < 620 and layout.h > layout.w
    self.body:SetStyle({flexDirection = portrait and "column" or "row"})
    local sidebarHeight = portrait and math.min(310, math.max(196, layout.h - 100)) or layout.h
    self.sidebar:SetStyle({width = portrait and "100%" or math.min(238, math.max(204, layout.w * .32)),
        height = sidebarHeight, padding = 2, gap = 2})
    -- Fixed chrome: 3 x 46px controls + 4px padding + 3 x 2px gaps.
    -- Select fewer REAL place rows before layout rather than clipping the last
    -- navigation button or squeezing any button below the 44px touch minimum.
    local available = sidebarHeight - 148 - 2 / math.max(.1, UI.GetScale())
    local size = math.max(COMPACT_PAGE_SIZE, math.min(PAGE_SIZE, math.floor(available / 46)))
    if self.pageSize ~= size then
        local first = (self.page - 1) * self.pageSize
        self.pageSize = size
        self.page = math.floor(first / size) + 1
        self:RefreshRows()
    end
    self.selection:SetVisible(layout.h >= 230)
end

---@return boolean
function Overlay:IsVisible() return self.root:IsVisible() end

---@param actor? CareerMapActor City coordinates (View must substitute city entry when indoors).
---@param target? CareerMapTarget Session.Target; its route is used without recalculation.
---@param active? CareerMapOrder
function Overlay:Open(actor, target, active)
    local position = actor or {}
    self.actor = {x = position.x or 0, z = position.z or 0, yaw = position.yaw or 0}
    self.target, self.active = target, active
    self.root:SetVisible(true)
    self.map:SetTelemetry(self.actor, target, active)
    local current = World.District(self.actor.x or 0, self.actor.z or 0)
    local regionId = Hills.Contains(self.actor.x or 0,self.actor.z or 0) and "hills"
        or Environment.Contains(self.actor.x or 0, self.actor.z or 0) and "coast" or current.id
    for i, region in ipairs(self.regions) do if region.id == regionId then self.regionIndex = i; break end end
    self.page, self.selectedId = 1, ""
    self.map:FocusPlayer(1000)
    self:RefreshPlaces()
    self:RefreshControls()
end

function Overlay:Close()
    if not self:IsVisible() then return end
    self.root:SetVisible(false)
    if self.onClose then self.onClose() end
end

function Overlay:RefreshControls()
    local view = self.map:GetView()
    self.zoomIn:SetDisabled(view.span <= view.minSpan)
    self.zoomOut:SetDisabled(view.span >= view.maxSpan)
    self.title:SetText("南城地图 · " .. distance(view.span) .. (view.followActor and " · 本人" or " · 浏览"))
end

---@param factor number
function Overlay:Zoom(factor) self.map:Zoom(factor); self:RefreshControls() end
---@param dx number Fraction of viewport width.
---@param dy number Fraction of viewport height, down positive.
function Overlay:Pan(dx, dy) self.map:PanByScreen(dx, dy); self:RefreshControls() end
function Overlay:ShowCity() self.map:ResetView(); self:RefreshControls() end
function Overlay:FocusPlayer() self.map:FocusPlayer(1000); self:RefreshControls() end

---@param direction integer
function Overlay:ChangeRegion(direction)
    self.regionIndex = (self.regionIndex - 1 + direction) % #self.regions + 1
    local region = self.regions[self.regionIndex]
    self.map:SetCenter(region.id == "greenbelt" and (self.actor.x or 0) or region.x,
        region.id == "greenbelt" and (self.actor.z or 0) or region.z)
    self.map:SetSpan(region.span)
    self.page, self.selectedId = 1, ""
    self:RefreshPlaces()
    self:RefreshControls()
end

function Overlay:RefreshPlaces()
    local region = self.regions[self.regionIndex]
    self.places = {}
    for _, point in ipairs(Config.pointList) do
        local inCoast = Environment.Contains(point.x, point.z)
        if region.id == "hills" and point.id:match("^hills_")
            or region.id == "coast" and inCoast
            or region.id == "greenbelt"
            or region.id ~= "hills" and region.id ~= "coast" and region.id ~= "greenbelt" and not inCoast
                and World.District(point.x, point.z).id == region.id then
            self.places[#self.places + 1] = point
        end
    end
    local x, z = self.actor.x or 0, self.actor.z or 0
    table.sort(self.places, function(a, b)
        local ad, bd = (a.x - x)^2 + (a.z - z)^2, (b.x - x)^2 + (b.z - z)^2
        return ad == bd and a.id < b.id or ad < bd
    end)
    -- Greenbelt has no invented businesses: expose only four nearest REAL places.
    if region.id == "greenbelt" then while #self.places > 4 do table.remove(self.places) end end
    self.regionTitle:SetText(region.label)
    self:RefreshRows()
end

---@param direction integer
function Overlay:ChangePage(direction)
    local pages = math.max(1, math.ceil(#self.places / self.pageSize))
    self.page = math.max(1, math.min(pages, self.page + direction))
    self:RefreshRows()
end

function Overlay:RefreshRows()
    local pages = math.max(1, math.ceil(#self.places / self.pageSize))
    self.page = math.max(1, math.min(pages, self.page))
    self.previousPage:SetDisabled(self.page <= 1)
    self.nextPage:SetDisabled(self.page >= pages)
    self.pageTitle:SetText(self.page .. " / " .. pages)
    for i, row in ipairs(self.rows) do
        local point = i <= self.pageSize and self.places[(self.page - 1) * self.pageSize + i] or nil
        row:SetVisible(i <= self.pageSize)
        local label = point and point.label or "本页无更多地点"
        local region = self.regions[self.regionIndex]
        if point and label:sub(1, #region.label) == region.label and #label > #region.label then
            label = label:sub(#region.label + 1) -- Region title already supplies the real district prefix.
        end
        row:SetText(label)
        row:SetDisabled(not point)
        row:SetStyle({borderColor = point and point.id == self.selectedId and C.amber or C.border})
    end
    local selected = Config.points[self.selectedId]
    self.navigate:SetDisabled(not selected or not self.onWaypoint)
    if selected then
        self.selection:SetText("直线 " .. distance(Config.DistanceTo(selected.id, self.actor.x or 0, self.actor.z or 0))
            .. " · " .. selected.label)
    else self.selection:SetText("点地点放大查看，再点导航") end
end

---@param index integer
function Overlay:SelectRow(index)
    if index < 1 or index > self.pageSize then return end
    local point = self.places[(self.page - 1) * self.pageSize + index]
    if not point then return end
    self.selectedId = point.id
    self.map:SetCenter(point.x, point.z)
    self.map:SetSpan(480)
    self:RefreshRows()
    self:RefreshControls()
end

function Overlay:Navigate()
    local point = Config.points[self.selectedId]
    if not point or not self.onWaypoint then return end
    local callback = self.onWaypoint
    -- Close first so View's blocker is released before production navigation refresh.
    self:Close()
    callback(point.id)
end

-- Explicit isolated UI fixture. Does not initialise/shutdown UI, build the world,
-- touch Store/cloud, advance time or retain the temporary root. Call after UI.Init.
-- Logical sizes are deliberate: test dimensions do not depend on physical DPR.
---@return table
function Overlay.Checks()
    local PointerEvent = require("urhox-libs/UI/Core/PointerEvent")
    local savedRoot = UI.GetRoot()
    local fixture = UI.Panel {width = 1024, height = 600, padding = 0, pointerEvents = "box-none"}
    local closed, chosen, taps = 0, "", 0
    local atlas = Overlay.New(function() closed = closed + 1 end, function(id) chosen = id end)
    fixture:AddChild(atlas.root)
    local function settle()
        for _ = 1, 4 do
            UI.Layout()
            atlas:RefreshLayout()
            atlas.map.root:Update(0)
        end
        UI.Layout()
    end
    local function tap(id)
        settle()
        local widget = assert(atlas.root:FindById("career-atlas-" .. id), "atlas missing button: " .. id)
        assert(widget:IsVisible() and not widget.props.disabled, "atlas button unavailable: " .. id)
        local r = widget:GetAbsoluteLayoutForHitTest()
        local bounds = atlas.root:GetAbsoluteLayoutForHitTest()
        assert(r.w >= 44 and r.h >= 44, "atlas touch target below 44px: " .. id)
        assert(r.x >= bounds.x and r.y >= bounds.y and r.x + r.w <= bounds.x + bounds.w + .1
            and r.y + r.h <= bounds.y + bounds.h + .1, "atlas button clipped: " .. id)
        local parent=widget.parent
        while parent and parent~=atlas.root do
            local p=parent:GetAbsoluteLayoutForHitTest()
            assert(r.x>=p.x-.1 and r.y>=p.y-.1 and r.x+r.w<=p.x+p.w+.1 and r.y+r.h<=p.y+p.h+.1,
                string.format("atlas button clipped by ancestor %s: %s child=(%.6f,%.6f %.6fx%.6f) parent=(%.6f,%.6f %.6fx%.6f)",
                    tostring(parent.props.id),id,r.x,r.y,r.w,r.h,p.x,p.y,p.w,p.h))
            parent=parent.parent
        end
        local function event(kind)
            return PointerEvent.new(kind, {pointerId = 791202, pointerType = "touch", isPrimary = false,
                x = (r.x + r.w / 2) * UI.GetScale(), y = (r.y + r.h / 2) * UI.GetScale(),
                button = PointerEvent.Button.Left})
        end
        local down, up = event("PointerDown"), event("PointerUp")
        UI.HandlePointerEvent(down); UI.HandlePointerEvent(up)
        assert(down.target == widget and up.target == widget, "atlas actual hit mismatch: " .. id)
        taps = taps + 1
    end
    ---@param widget Widget
    ---@return number
    local function count(widget)
        local total = 1
        assert(not widget.GetScroll, "atlas must not contain any scrolling container")
        for _, child in ipairs(widget:GetChildren()) do total = total + count(child) end
        return total
    end
    local report = {sizes = 0, buttons = 0, maxWidgets = 0}
    local ok, failure = pcall(function()
        UI.SetRoot(fixture)
        for _, size in ipairs({{1024, 600}, {640, 360}, {640, 300}, {640, 280}, {390, 844}}) do
            fixture:SetStyle({width = size[1], height = size[2]})
            atlas:Open({x = 0, z = -20, yaw = 35}, nil, nil)
            settle()
            local viewport = atlas.map.viewport:GetLayout()
            assert(viewport.w > 80 and viewport.h > 80, "atlas map viewport collapsed")
            local initial = atlas.map.span
            tap("zoom-in"); assert(atlas.map.span == initial / 2, "atlas zoom in ineffective")
            tap("zoom-out"); assert(atlas.map.span == initial, "atlas zoom out ineffective")
            tap("east")
            local centre = atlas.map:GetView()
            assert(not centre.followActor and centre.x > 0, "atlas east must pan, never move actor")
            atlas.map:SetTelemetry({x = 30, z = -20}, nil, nil)
            assert(atlas.map:GetView().x == centre.x, "overview Refresh reset manual centre")
            tap("north"); assert(atlas.map:GetView().z > centre.z, "atlas north/Z sign wrong")
            tap("west"); tap("south"); tap("centre"); tap("me")
            assert(atlas.map.followActor, "atlas return-to-player ineffective")
            tap("city"); assert(atlas.map.span == World.LIMIT * 2 and atlas.map.centerX == 0,
                "atlas full-city reset ineffective")
            tap("region-next"); tap("region-prev")
            assert(atlas.regions[atlas.regionIndex].id == "old_town", "atlas region controls ineffective")
            tap("page-next"); assert(atlas.page == 2, "atlas fixed pagination ineffective")
            tap("page-prev"); assert(atlas.page == 1, "atlas previous page ineffective")
            local seen={}
            while true do
                for i,row in ipairs(atlas.rows) do
                    assert(row:IsVisible()==(i<=atlas.pageSize),"atlas compact place mask differs from page stride")
                    local point=atlas.places[(atlas.page-1)*atlas.pageSize+i]
                    if i<=atlas.pageSize and point then seen[point.id]=true end
                end
                if atlas.nextPage.props.disabled then break end
                tap("page-next")
            end
            for _,point in ipairs(atlas.places) do assert(seen[point.id],"atlas compact pagination lost real place "..point.id) end
            while atlas.page>1 do tap("page-prev") end
            local stale = atlas.map.roads:GetChildren()
            local oldRoad = stale[1]
            tap("place-1")
            assert(Config.points[atlas.selectedId] and atlas.map.span == 480, "atlas selection must use real Config point")
            if oldRoad then assert(oldRoad.node == nil and oldRoad.parent == nil, "atlas old road Yoga node leaked") end
            settle()
            local key = atlas.map.geometryKey
            local children = atlas.map.roads:GetNumChildren()
            atlas.map:SetTelemetry({x = 30, z = -20}, nil, nil)
            assert(atlas.map.geometryKey == key and atlas.map.roads:GetNumChildren() == children,
                "atlas steady telemetry rebuilt static map")
            local stable = count(atlas.root)
            for _ = 1, 3 do
                atlas:ChangePage(1); atlas:ChangePage(-1)
                atlas:ChangeRegion(1); atlas:ChangeRegion(-1)
                atlas:SelectRow(1); settle()
                assert(count(atlas.root) == stable, "atlas repeated paging/selection grows UI tree")
            end
            report.maxWidgets = math.max(report.maxWidgets, stable)
            local selected = atlas.selectedId
            tap("navigate")
            assert(chosen == selected and not atlas:IsVisible(), "atlas navigation callback or close missing")
            atlas:Open({x = 0, z = -20}, nil, nil); settle(); tap("close")
            assert(not atlas:IsVisible(), "atlas close button ineffective")
            for _,targetId in ipairs({"hills_river_south","hills_river_north"}) do
                atlas:Open({x=0,z=-20},nil,nil);settle()
                tap("region-next")
                assert(atlas.regions[atlas.regionIndex].id=="hills" and #atlas.places==2,
                    "山城区域未展示两个真实滨江地点")
                local targetIndex=0
                for i,point in ipairs(atlas.places) do if point.id==targetId then targetIndex=i end end
                assert(targetIndex>0,"山城地图遗漏真实地点："..targetId)
                local targetPage=(targetIndex-1)//atlas.pageSize+1
                while atlas.page<targetPage do tap("page-next") end
                tap("place-"..((targetIndex-1)%atlas.pageSize+1))
                assert(atlas.selectedId==targetId,"山城触摸选点错误")
                tap("navigate")
                assert(chosen==targetId and not atlas:IsVisible(),"山城导航回调未指向真实地点")
            end
            report.sizes, report.buttons = report.sizes + 1, taps
        end
        ---@type {a:CareerMapPosition,b:CareerMapPosition}[]
        local captured={}
        local rectangles=0
        local probe=Map.New("career-map-coverage",false)
        probe.width,probe.height,probe.scale,probe.span=600,400,.5,800
        probe.centerX,probe.centerZ=World.Bridges[1].x,World.Bridges[1].z
        probe.Segment=function(_,_,a,b)
            captured[#captured+1]={a=a,b=b}
        end
        probe.PlaceLabel=function() return true end
        probe.GroundRect=function() rectangles=rectangles+1 end
        probe:RebuildWalkGeometry()
        local roadSegments=0
        for _,route in ipairs(require("Career.HillDistrict").Routes) do roadSegments=roadSegments+#route.points-1 end
        assert(#captured>=#World.Bridges*3+roadSegments,"地图漏画真实桥面或双侧坡道")
        for i,b in ipairs(World.Bridges) do
            local deck=captured[roadSegments+(i-1)*3+1]
            assert(deck.a.x==b.x-b.halfSpan and deck.b.x==b.x+b.halfSpan
                and deck.a.z==b.z and deck.b.z==b.z,"地图桥面偏离真实世界")
        end
        rectangles=0
        probe:RebuildFootprints()
        assert(rectangles>0,"远区地图建筑占地仍为空")
        probe.root:Destroy()
        print(string.format("[地图同源覆盖] PASS %d座步行桥/双坡道/海岸连接/外区建筑；不依赖可见块",#World.Bridges))
        local phone = Map.New("career-atlas-legacy-fixture", true)
        fixture:AddChild(phone.root)
        phone:SetTelemetry({x = 0, z = 6144}, nil, nil)
        UI.Layout(); phone.root:Update(0); UI.Layout()
        assert(phone.span == 30000 and phone.centerX == 0 and phone.centerZ == 0 and not phone.detailed,
            "legacy phone overview default changed")
        -- 每尺寸：旧地点导航、关闭按钮、两个滨江地点导航各关闭一次。
        assert(closed == report.sizes*4, "atlas close callback duplicated or omitted")
    end)
    -- Restore before Destroy; never dispose the caller's root or global UI context.
    UI.SetRoot(savedRoot)
    fixture:Destroy()
    if savedRoot then UI.Layout() end
    assert(ok, failure)
    print(string.format("[CareerAtlasChecks] %d logical sizes / %d button taps / bounded tree max %d",
        report.sizes, report.buttons, report.maxWidgets))
    return report
end

return Overlay
