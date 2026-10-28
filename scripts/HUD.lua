-- Pursuit UI: default-dark customized to restrained steel-black / amber.
-- Available style skills were checked: cosmic/cartoon/pixel are intentionally not applied.
-- UI owns NanoVG frames, fonts, DPI and input. Custom Widgets never start another frame.
local UI = require("urhox-libs/UI")
local Catalog = require("Catalog")
local Profile = require("Profile")
local ControlSettings = require("ControlSettings")
local GaragePreview = require("GaragePreview")
local MobileControls = require("MobileControls")
local RaceInstruments = require("RaceInstruments")
-- Tracks may arrive after this UI change; never invent route geometry as a fallback.
local function trackList()
    local ok, tracks = pcall(require, "Tracks")
    if not ok or type(tracks) ~= "table" then return {} end
    if type(tracks.List) == "function" then return tracks.List() end
    return type(tracks.List) == "table" and tracks.List or {}
end

---@class HUD : ControlEditor
---@field settingsReturn string
---@field OpenSettings fun(self:HUD)
---@field pausedCockpitVisible boolean?
local HUD = {}
HUD.__index = HUD
local AMBER, WHITE = {224, 164, 75, 255}, {233, 234, 235, 255}
local MUTED, STEEL = {154, 163, 172, 255}, {107, 128, 143, 255}
local DARK, BORDER = {15, 18, 22, 240}, {172, 185, 195, 55}
local RED, GREEN = {227, 82, 67, 255}, {145, 192, 164, 255}
local KEYART = "image/pursuit_loading_keyart_20261027183804.png"
local GARAGE = "image/pursuit_garage_backdrop_20261027183801.png"
-- 绿色为默认免费配色，其余需用比赛金币购买。
local RIDERS = {
    {id = "red", color = {168, 46, 37, 255}, price = 900},
    {id = "blue", color = {44, 87, 146, 255}, price = 1200},
    {id = "yellow", color = {212, 164, 48, 255}, price = 1600},
    {id = "white", color = {215, 219, 218, 255}, price = 2000},
    {id = "green", color = {61, 117, 84, 255}, price = 0},
    {id = "violet", color = {111, 75, 137, 255}, price = 2600},
}
HUD.Riders = RIDERS
HUD.Resources, HUD.ResourceTypes = {KEYART, GARAGE}, {[KEYART] = "Texture2D", [GARAGE] = "Texture2D"}
for _, path in ipairs(MobileControls.Resources) do
    HUD.Resources[#HUD.Resources + 1], HUD.ResourceTypes[path] = path, MobileControls.ResourceTypes[path]
end
for _, path in ipairs(GaragePreview.Resources) do
    HUD.Resources[#HUD.Resources + 1], HUD.ResourceTypes[path] = path, GaragePreview.ResourceTypes[path]
end

local function label(text, size, color, extra)
    local props = extra or {}
    props.text, props.fontSize, props.fontColor, props.pointerEvents = text, size, color or WHITE, "none"
    return UI.Label(props)
end
local function button(text, callback, primary, width)
    return UI.Button {text = text, onClick = callback, width = width, height = 44, fontSize = 12,
        padding = 0, borderRadius = 4, borderWidth = 1,
        borderColor = primary and {255, 201, 116, 180} or BORDER,
        backgroundColor = primary and AMBER or {27, 32, 38, 225},
        hoverBackgroundColor = primary and {240, 185, 101, 255} or {42, 48, 55, 245},
        pressedBackgroundColor = primary and {174, 116, 43, 255} or {18, 22, 27, 255},
        disabledBackgroundColor = {34, 38, 43, 245}, disabledTextColor = {135, 143, 151, 255},
        textColor = primary and {16, 18, 21, 255} or WHITE}
end
local function bar(color, height)
    return UI.ProgressBar {value = 0, width = "100%", height = height or 3, showLabel = false,
        fillColor = color or AMBER, backgroundColor = {123, 133, 143, 60}, borderWidth = 0,
        borderRadius = 1, padding = 0, pointerEvents = "none"}
end
local function fill(props)
    props = props or {}
    props.position, props.top, props.left, props.right, props.bottom = "absolute", 0, 0, 0, 0
    props.padding = props.padding or 0
    return props
end
local function clock(seconds)
    local centiseconds = math.floor(math.max(0, tonumber(seconds) or 0) * 100)
    return string.format("%02d:%02d.%02d", math.floor(centiseconds / 6000), math.floor(centiseconds / 100) % 60, centiseconds % 100)
end

-- Functional symbols, not emoji/text stand-ins for the authored driving controls.
local Symbol = UI.Widget:Extend("PursuitSymbol")
function Symbol:Render(vg)
    local l = self:GetAbsoluteLayout()
    local x, y = l.x + l.w * 0.5, l.y + l.h * 0.5
    nvgBeginPath(vg)
    if self.props.symbol == "pause" then
        nvgRect(vg, x - 7, y - 8, 4, 16); nvgRect(vg, x + 3, y - 8, 4, 16)
        nvgFillColor(vg, nvgRGBA(233, 234, 235, 255)); nvgFill(vg)
    elseif self.props.symbol == "camera" then
        nvgRoundedRect(vg, x - 11, y - 7, 22, 15, 2)
        nvgMoveTo(vg, x - 5, y - 7); nvgLineTo(vg, x - 3, y - 11); nvgLineTo(vg, x + 5, y - 11)
        nvgMoveTo(vg, x + 5, y); nvgCircle(vg, x, y, 4)
        nvgStrokeColor(vg, nvgRGBA(233, 234, 235, 255)); nvgStrokeWidth(vg, 1.5); nvgStroke(vg)
    else
        nvgArc(vg, x, y, 9, -2.5, 2.4, NVG_CW)
        nvgMoveTo(vg, x - 10, y + 2); nvgLineTo(vg, x - 8, y + 10); nvgLineTo(vg, x - 1, y + 7)
        nvgStrokeColor(vg, nvgRGBA(233, 234, 235, 255)); nvgStrokeWidth(vg, 1.5); nvgStroke(vg)
    end
end
local function iconButton(symbol, action)
    local names = {camera = "视角", pause = "暂停", recover = "复位"}
    return UI.Button {text = names[symbol] or "返回", width = 54, height = 54, padding = 0,
        paddingTop = 29, fontSize = 9, borderRadius = 6, borderWidth = 1,
        textColor = WHITE, borderColor = BORDER, backgroundColor = {9, 17, 24, 215},
        pressedBackgroundColor = {112, 79, 34, 240}, hoverBackgroundColor = {30, 48, 60, 235},
        onClick = action, children = {Symbol {position = "absolute", top = 3, left = 0, right = 0, height = 28,
            symbol = symbol, pointerEvents = "none"}}}
end

-- Sample only the actual Landscape route once; no fake/oval map and no per-frame map rebuild.
local TrackMap = UI.Widget:Extend("PursuitTrackMap")
function TrackMap:Init(props)
    UI.Widget.Init(self, props)
    self.points, self.markers, self.playerX, self.playerZ = {}, {}, 0.0, 0.0
    self.minX, self.minZ, self.spanX, self.spanZ = 0.0, 0.0, 1.0, 1.0
    self.routeReady, self.routeLength = false, 0
end
function TrackMap:Prepare(map)
    if self.routeReady or not map or not map.RoadPoint or (map.RouteLength or 0) <= 0 then return end
    local minX, minZ, maxX, maxZ = math.huge, math.huge, -math.huge, -math.huge
    for i = 0, 160 do
        local p = map.RoadPoint(map.RouteLength * i / 160)
        self.points[#self.points + 1] = {x = p.x, z = p.z}
        minX, minZ, maxX, maxZ = math.min(minX, p.x), math.min(minZ, p.z), math.max(maxX, p.x), math.max(maxZ, p.z)
    end
    self.minX, self.minZ, self.spanX, self.spanZ = minX, minZ, math.max(1, maxX - minX), math.max(1, maxZ - minZ)
    self.routeReady, self.routeLength = true, map.RouteLength
end
function TrackMap:Render(vg)
    self:RenderFullBackground(vg)
    local l = self:GetAbsoluteLayout()
    if not self.routeReady or l.w <= 12 or l.h <= 12 then return end
    local scale = math.min((l.w - 24) / self.spanX, (l.h - 24) / self.spanZ)
    local x, y = l.x + (l.w - self.spanX * scale) * 0.5, l.y + (l.h - self.spanZ * scale) * 0.5
    nvgSave(vg); nvgIntersectScissor(vg, l.x, l.y, l.w, l.h)
    nvgBeginPath(vg)
    for i, p in ipairs(self.points) do
        if i == 1 then nvgMoveTo(vg, x + (p.x - self.minX) * scale, y + (self.spanZ - p.z + self.minZ) * scale)
        else nvgLineTo(vg, x + (p.x - self.minX) * scale, y + (self.spanZ - p.z + self.minZ) * scale) end
    end
    nvgClosePath(vg); nvgStrokeWidth(vg, 5); nvgStrokeColor(vg, nvgRGBA(8, 11, 14, 240)); nvgStroke(vg)
    nvgStrokeWidth(vg, 2); nvgStrokeColor(vg, nvgRGBA(169, 177, 183, 185)); nvgStroke(vg)
    local start = self.points[1]
    nvgBeginPath(vg); nvgRect(vg, x + (start.x - self.minX) * scale - 3, y + (self.spanZ - start.z + self.minZ) * scale - 3, 6, 6)
    nvgFillColor(vg, nvgRGBA(235, 235, 235, 220)); nvgFill(vg)
    for _, marker in ipairs(self.markers) do
        if not marker.isPlayer and not marker.eliminated then
            nvgBeginPath(vg); nvgCircle(vg, x + (marker.x - self.minX) * scale, y + (self.spanZ - marker.z + self.minZ) * scale, marker.police and 3.8 or 2.5)
            nvgFillColor(vg, marker.police and nvgRGBA(227, 82, 67, 255) or nvgRGBA(132, 166, 185, 230)); nvgFill(vg)
        end
    end
    nvgBeginPath(vg); nvgCircle(vg, x + (self.playerX - self.minX) * scale, y + (self.spanZ - self.playerZ + self.minZ) * scale, 4.5)
    nvgFillColor(vg, nvgRGBA(224, 164, 75, 255)); nvgFill(vg)
    nvgStrokeWidth(vg, 1.5); nvgStrokeColor(vg, nvgRGBA(12, 15, 18, 255)); nvgStroke(vg)
    nvgRestore(vg)
end

function HUD.New(actions, controls)
    local self = setmetatable({}, HUD)
    self:Init(actions, controls)
    return self
end
function HUD:Init(actions, controls)
    self.actions, self.controls = actions, controls
    self.timer, self.layoutWidth, self.layoutHeight = 0.0, 0, 0
    self.screen, self.selectedVehicle, self.challenge = "menu", "sport", true
    self.selectedRider, self.selectedLaps, self.selectedTrack = "red", 2, "lake"
    self.trackCards, self.trackGraphics = {}, {}
    self.portraitActive, self.firstPerson, self.qualityName = false, true, "流畅"
    self.cockpitX, self.cockpitY = math.huge, math.huge
    self.cockpitSpeedText, self.cockpitGearText, self.cockpitRPMText = "000", "N", "1200 rpm"
    ---@type table
    self.race = {}
    self.hasRace, self.resultKey = false, ""
    ---@type table<string, Panel>
    self.vehicleCards = {}
    ---@type table<string, Label>
    self.vehicleBadges = {}
    ---@type table<string, Panel>
    self.riderButtons = {}
    ---@type Button[]
    self.lapButtons = {}
    ---@type Label[]
    self.resultRows = {}
    UI.Init({theme = "default-dark", scale = UI.Scale.DEFAULT})
    self:BuildRide(); self:BuildMenu(); self:BuildSettings(); self:BuildGarage(); self:BuildTracks(); self:BuildPauseAndResult(); self:BuildLoading()
    self.portrait = UI.Panel(fill({visible = false, backgroundColor = {9, 12, 15, 255},
        alignItems = "center", justifyContent = "center", padding = 24, gap = 12, children = {
            label("请横屏握持手机", 24), label("公路追逐 · 横屏竞速", 12, AMBER),
            label("左手转向 · 右手油刹 / 氮气 / 近身对抗", 11, MUTED, {textAlign = "center", whiteSpace = "normal"})}}))
    self.safeContent = UI.Panel {width = "100%", flexGrow = 1, flexShrink = 1, minHeight = 0, padding = 0,
        pointerEvents = "box-none", children = {self.menu, self.garage, self.trackSelection, self.game, self.pause, self.result, self.loading, self.settings}}
    self.keyartBackdrop = UI.Panel(fill({backgroundImage = KEYART, backgroundFit = "cover", pointerEvents = "none"}))
    self.garageBackdrop = UI.Panel(fill({backgroundImage = GARAGE, backgroundFit = "cover", pointerEvents = "none", visible = false,
        children = {self.preview}}))
    self.pageBackdrop = UI.Panel(fill({pointerEvents = "none", backgroundColor = {9, 12, 15, 255}, children = {
        self.keyartBackdrop, self.garageBackdrop}}))
    self.root = UI.Panel {width = "100%", height = "100%", padding = 0, pointerEvents = "box-none", children = {
        self.pageBackdrop,
        UI.SafeAreaView {width = "100%", height = "100%", padding = 0, nativeMenuInset = true,
            pointerEvents = "box-none", children = {self.safeContent}}, self.cockpit, self.portrait}}
    UI.SetRoot(self.root)
    self:SelectVehicle(Profile.FREE_VEHICLE, false); self:SelectRider(Profile.FREE_RIDER, false); self:SelectLaps(3, false); self:SelectTrack(Profile.FREE_TRACK, false)
    self:SetScreen("menu"); self:LayoutResponsive(); self:RefreshRace()
    -- Art is optional during initial menu display; never block UI construction on a download.
    for _, path in ipairs({KEYART, GARAGE}) do
        cache:GetResourceAsync("Texture2D", path, function(resource)
            if not resource then print("[界面] 主视觉暂未就绪：" .. path) end
        end)
    end
    print("[竞速界面] 钢黑琥珀 / 九款独立车型 / 真实3D车库 / 多指图片操控")
end

function HUD:BuildRide()
    local a, c = self.actions, self.controls
    self.speed = label("000", 30, WHITE, {height = 38, lineHeight = 1, width = 78, textAlign = "center"})
    self.gear = label("N", 17, AMBER, {width = 22, textAlign = "center"})
    self.distance, self.score, self.health = label("0.00 km", 9, MUTED), label("得分 000000", 10), label("车况 100%", 10)
    self.message = label("", 12, WHITE, {textAlign = "center", maxLines = 2, whiteSpace = "normal", width = "100%"})
    self.time, self.camera, self.overtakes = label("00:00.00", 12), label("头盔视角", 9, MUTED), label("0", 9)
    self.rpmNumber, self.stuntState = label("1200 rpm", 9, MUTED), label("", 9, MUTED)
    self.region, self.objectives = label("环湖公路", 9, MUTED), label("", 9, MUTED)
    self.target, self.navigation = label("", 10, WHITE), label("", 9, AMBER)
    self.rpm, self.route = bar(AMBER, 3), bar(STEEL, 2)
    self.rank = label("01", 32, AMBER, {height = 40, lineHeight = 1, fontWeight = "bold"})
    self.rankTotal = label("/ 09", 11, MUTED, {alignSelf = "flex-end", marginBottom = 6})
    self.lap = label("01 / 02", 16, WHITE, {fontWeight = "bold"})
    self.remaining = label("9 人在赛", 9, MUTED)
    self.rankPanel = UI.Panel {position = "absolute", top = 8, left = 12, width = 152, padding = 8,
        borderRadius = 4, backgroundColor = {10, 13, 16, 175}, pointerEvents = "none", children = {
            UI.Row {padding = 0, gap = 7, children = {self.rank, self.rankTotal}}, self.remaining}}
    self.trackMap = TrackMap {position = "absolute", left = 12, top = 89, width = 152, height = 122,
        padding = 0, backgroundColor = {10, 13, 16, 145}, borderWidth = 1, borderColor = BORDER,
        borderRadius = 4, pointerEvents = "none"}
    self.navPanel = UI.Panel {position = "absolute", top = 8, left = 178, width = 126, padding = 8, gap = 3,
        backgroundColor = {10, 13, 16, 145}, borderRadius = 4, pointerEvents = "none", children = {
            label("LAP / 圈数", 8, MUTED), self.lap, self.time, self.route}}
    self.instrumentPanel = RaceInstruments.Dial {position = "absolute", bottom = 12, left = "50%", marginLeft = -114,
        width = 228, height = 112, visible = false}
    self.rightTop = UI.Row {position = "absolute", top = 8, right = 12, gap = 6, padding = 0,
        pointerEvents = "box-none", children = {iconButton("camera", a.camera), iconButton("pause", a.pause)}}
    self.recoverButton = iconButton("recover", function() if a.recover then a.recover() end end)
    self.recoverPanel = UI.Panel {position = "absolute", top = 68, right = 12, padding = 0,
        pointerEvents = "box-none", children = {self.recoverButton}}
    -- 所有驾驶按键改成独立的绝对定位块：位置由“操作设置”里的方案直接决定，
    -- 拖动设置面板里的按钮就等于移动这里真实的按键，不再有第二套布局。
    self.controlLayer = UI.Panel(fill({pointerEvents = "box-none"}))
    self.controlWidgets = {}
    local function place(key, widget)
        self.controlWidgets[key] = widget
        self.controlLayer:AddChild(widget)
    end
    place("steering", c:CreateSteering())
    place("nitro", c:CreateHold("nitro", "氮气", 80, 84))
    place("wheelie", c:CreateHold("wheelie", "翘头", 80, 84))
    place("brake", c:CreatePedal("brake"))
    place("gas", c:CreatePedal("gas"))
    place("burnout", c:CreateHold("burnout", "烧胎", 68, 70))
    place("spin180", c:CreatePulse("spin180", "旋转180°", 68))
    place("spin360", c:CreatePulse("spin360", "旋转360°", 68))
    for _, widget in pairs(self.controlWidgets) do
        widget:SetStyle({position = "absolute", left = 0, top = 0})
    end
    -- 兼容旧代码引用：特技面板合并进统一控制层。
    self.leftControls = self.controlLayer
    self.rightControls = self.controlLayer
    self.toolTray = self.controlLayer
    self.toolsPanel = self.controlLayer
    self.nitroBar, self.dangerBar = bar({91, 220, 233, 255}, 5), bar(RED, 4)
    self.nitroValue = label("氮气就绪 · 100%", 10, {91, 220, 233, 255})
    self.nitroHint = label("点按喷射2.5秒 · 耗45", 8, MUTED)
    self.nitroPanel = UI.Panel {position = "absolute", bottom = 132, left = "50%", marginLeft = -98,
        width = 196, padding = 7, gap = 3, backgroundColor = {7, 17, 25, 210}, borderRadius = 6,
        borderWidth = 1, borderColor = {91, 220, 233, 80}, pointerEvents = "none", children = {self.nitroValue, self.nitroBar, self.nitroHint}}
    self.dangerText = label("", 10, WHITE, {width = "100%", textAlign = "center", maxLines = 2, whiteSpace = "normal"})
    self.dangerPanel = UI.Panel {position = "absolute", top = 8, left = "50%", marginLeft = -122,
        width = 244, padding = 7, gap = 4, backgroundColor = {10, 13, 16, 175}, borderRadius = 4,
        pointerEvents = "none", children = {self.dangerText, self.dangerBar}}
    self.countdown = label("", 64, AMBER, {width = "100%", height = 85, textAlign = "center", fontWeight = "bold", lineHeight = 1})
    self.countdownPanel = UI.Panel {position = "absolute", top = "32%", left = "35%", width = "30%",
        padding = 0, pointerEvents = "none", children = {self.countdown}}
    self.game = UI.Panel(fill({visible = false, pointerEvents = "box-none", children = {
        self.rankPanel, self.trackMap, self.navPanel, self.instrumentPanel, self.rightTop, self.recoverPanel,
        self.dangerPanel, self.nitroPanel, self.countdownPanel,
        UI.Panel {position = "absolute", top = "56%", left = "25%", width = "50%", padding = 0, pointerEvents = "none", children = {self.message}},
        self.controlLayer}}))
    self.cockpit = RaceInstruments.Dial {position = "absolute", left = 0, top = 0, width = 154, height = 76,
        small = true, visible = false}
    self.cockpitSpeed, self.cockpitGear, self.cockpitRPM = self.cockpit.speedLabel, self.cockpit.gearLabel, self.cockpit.rpmLabel
    self.radioTitle = label("骑行电台", 10, MUTED)
    self.radioToggle = button("播放", a.toggleRadio, false, 70)
end

function HUD:BuildMenu()
    self.menu = UI.Panel(fill({padding = 28, gap = 8, children = {
        UI.Row {padding = 0, justifyContent = "space-between", children = {
            label("P U R S U I T", 13, AMBER, {letterSpacing = 2}), label("ROAD RACING / 公路追逐", 9, MUTED)}},
        UI.ScrollView {width = "52%", maxWidth = 580, flexGrow = 1, flexBasis = 0, flexShrink = 1, padding = 0, children = {
            UI.Column {width = "100%", padding = 0, paddingVertical = 22, gap = 10, children = {
                label("公路追逐", 42, WHITE, {fontWeight = "bold", lineHeight = 1.1}),
                label("甩开追车，争夺终点。", 14, MUTED),
                UI.Panel {width = 44, height = 2, padding = 0, backgroundColor = AMBER},
                label("9 位车手 · 氮气突围 · 近身对抗", 10, MUTED),
                button("开始竞速   →", function() self:OpenGarage(true) end, true, 250),
                button("自由练习", function() self:OpenGarage(false) end, false, 250),
                button("操作设置", function() self:OpenSettings() end, false, 250),
                label("选择机车、车手与圈数后出发", 10, MUTED),
            }}}},
        label("仅限虚拟竞速体验  /  横屏 · 双手操控", 9, MUTED),
    }}))
end

-- 操作编辑器独立成模块，直接复用驾驶按键。
require("ControlEditor").Install(HUD)

function HUD:BuildGarage()
    local cards = UI.Column {width = "100%", gap = 5, padding = 0}
    for index, item in ipairs(Catalog.List) do
        local v = item
        local badge = label(v.available == false and "准备中 · 不可驾驶" or (v.price and v.price > 0 and ("未拥有 · " .. v.price .. " 金币") or "点按选择"), 8, MUTED)
        self.vehicleBadges[v.id] = badge
        local card = UI.Panel {width = "100%", height = 62, minHeight = 62, padding = 7, gap = 2,
            borderRadius = 3, borderWidth = 1, borderColor = BORDER, backgroundColor = {17, 21, 26, 215},
            onClick = function() self:SelectVehicle(v.id, true) end, children = {
                label(string.format("%02d  %s", index, v.name), 11, WHITE, {fontWeight = "bold", maxLines = 1}),
                label(v.tag or v.class or "", 8, MUTED, {maxLines = 1}), badge}}
        self.vehicleCards[v.id] = card; cards:AddChild(card)
    end
    self.selectionMode = label("竞速 / 2 圈", 9, AMBER)
    self.vehicleName = label("", 22, WHITE, {fontWeight = "bold", maxLines = 1})
    self.vehicleDescription = label("", 10, MUTED, {width = "100%", whiteSpace = "normal", maxLines = 2})
    self.vehicleSpecs = label("", 9, MUTED, {maxLines = 1})
    -- Full-backdrop overlay, not a separate right-column viewport. This shares the
    -- photo's dimensions even when SafeAreaView adds asymmetric device insets.
    self.preview = GaragePreview.New(fill())
    self.previewColumn = UI.Column {flexGrow = 1, flexBasis = 0, flexShrink = 1, minWidth = 0, height = "100%",
        padding = 6, gap = 2, pointerEvents = "box-none", children = {
            self.vehicleName, self.vehicleDescription,
            UI.Panel {flexGrow = 1, flexBasis = 0, padding = 0, pointerEvents = "none"}, self.vehicleSpecs}}
    self.garageList = UI.ScrollView {width = 228, height = "100%", padding = 0, scrollY = true,
        flexShrink = 0, showScrollbar = true, children = {cards}}
    self.garageBody = UI.Row {width = "100%", flexGrow = 1, flexBasis = 0, flexShrink = 1, minHeight = 0,
        padding = 0, gap = 12, pointerEvents = "box-none", children = {self.garageList, self.previewColumn}}
    local colors = UI.Row {padding = 0, gap = 6}
    for _, rider in ipairs(RIDERS) do
        local r = rider
        local swatch = UI.Panel {width = 32, height = 32, padding = 5, borderWidth = 1, borderColor = BORDER, borderRadius = 3,
            backgroundColor = {18, 22, 27, 235}, onClick = function() self:SelectRider(r.id, true) end,
            children = {UI.Panel {width = "100%", height = "100%", padding = 0, borderRadius = 2,
                backgroundColor = r.color, pointerEvents = "none"}}}
        self.riderButtons[r.id] = swatch; colors:AddChild(swatch)
    end
    -- 圈数由赛道定义固定，玩家不再自选；这里只显示当前赛道圈数。
    local laps = UI.Row {padding = 0, gap = 6}
    local lapLabel = label("", 13, WHITE, {fontWeight = "bold"})
    self.lapFixedLabel = lapLabel
    laps:AddChild(lapLabel)
    self.riderOptions = UI.Column {padding = 0, gap = 3, children = {label("车手配色", 8, MUTED), colors}}
    self.lapOptions = UI.Column {padding = 0, gap = 3, children = {label("圈数", 8, MUTED), laps}}
    self.confirmButton = button("确认座驾 · 出发 →", function()
        local item = Catalog.Get(self.selectedVehicle)
        if item and item.available ~= false and self.actions.confirmVehicle then self.actions.confirmVehicle(self.selectedVehicle) end
    end, true, 228)
    self.coinLabel = label("金币 0", 13, AMBER, {fontWeight = "bold"})
    self.buyButton = button("购买 · 0 金币", function()
        local item = Catalog.Get(self.selectedVehicle)
        if item and self.actions.buyVehicle then self.actions.buyVehicle(item.id) end
    end, false, 150)
    self.buyButton:SetHeight(34)
    self.trackButton = button("赛道 · 环湖公路 ›", function() self:OpenTracks() end, false, 185)
    self.trackButton:SetHeight(36)
    self.garageFooter = UI.Row {width = "100%", padding = 0, gap = 12, alignItems = "flex-end",
        justifyContent = "space-between", children = {self.riderOptions, self.lapOptions,
            UI.Column {padding = 0, gap = 6, alignItems = "flex-end", children = {
                UI.Row {padding = 0, gap = 8, alignItems = "center", children = {self.coinLabel, self.buyButton}},
                self.confirmButton}}}}
    self.garage = UI.Panel(fill({visible = false, padding = 18, gap = 8, children = {
        UI.Row {padding = 0, alignItems = "center", justifyContent = "space-between", children = {
            UI.Column {padding = 0, gap = 2, children = {label("车库 / GARAGE", 17, WHITE, {fontWeight = "bold"}), self.selectionMode}},
            UI.Row {padding = 0, gap = 8, alignItems = "center", children = {self.trackButton, button("返回", function()
                self:SetScreen("menu"); if self.actions.backSelection then self.actions.backSelection() end
            end, false, 70)}}}}, self.garageBody, self.garageFooter}}))
end

function HUD:BuildTracks()
    self.trackGrid = UI.Column {width = "100%", padding = 0, gap = 10}
    self.trackSelection = UI.Panel(fill({visible = false, padding = 20, gap = 10,
        backgroundColor = {6, 12, 19, 247}, children = {
            UI.Row {padding = 0, justifyContent = "space-between", alignItems = "center", children = {
                UI.Column {padding = 0, gap = 3, children = {label("选择赛道 / ROUTE SELECT", 20, WHITE, {fontWeight = "bold"}),
                    label("六条真实路线 · 选择后返回车库确认出发", 10, MUTED)}},
                button("返回车库", function() self:SetScreen("garage") end, false, 110)}},
            UI.ScrollView {width = "100%", flexGrow = 1, flexBasis = 0, flexShrink = 1, minHeight = 0,
                padding = 0, children = {self.trackGrid}},
            label("白点为发车位置 · 轮廓与比赛实际道路一致", 9, MUTED)}}))
    self:RefreshTrackCards()
end
function HUD:RefreshTrackCards()
    local list = trackList()
    if #list == 0 then
        if self.trackGrid:GetNumChildren() == 0 then
            self.trackGrid:AddChild(label("赛道目录准备中 · 暂沿用当前公路", 13, MUTED))
        end
        return
    end
    if self.trackCount == #list then return end
    self.trackGrid:ClearChildren()
    self.trackCards, self.trackGraphics = {}, {}
    self.trackCount = #list
    local rows = {}
    for _ = 1, math.ceil(#list / 3) do
        local row = UI.Row {width = "100%", padding = 0, gap = 10}
        rows[#rows + 1] = row; self.trackGrid:AddChild(row)
    end
    local themes = {lake = "湖畔 · 连续弯道", alpine = "高山 · 发卡挑战", coast = "海岸 · 高速巡航", canyon = "峡谷 · 沙漠穿行", forest = "森林 · 拉力公路", circuit = "赛道 · 封闭竞速"}
    for index, track in ipairs(list) do
        local entry = track
        local accent = entry.accent or AMBER
        local graphic = RaceInstruments.Route {width = "100%", height = 94, padding = 0,
            backgroundColor = {4, 12, 20, 220}, borderRadius = 4, pointerEvents = "none"}
        graphic:SetRoute(entry.preview or {}, accent)
        local unlocked = Profile.TrackUnlocked(entry.id)
        local card = UI.Button {flexGrow = 1, flexBasis = 0, flexShrink = 1, minWidth = 0, height = 178, padding = 0, text = "",
            borderRadius = 7, borderWidth = 1, borderColor = BORDER, backgroundColor = {14, 26, 37, 255},
            hoverBackgroundColor = {27, 44, 55, 255}, pressedBackgroundColor = {65, 64, 43, 255},
            onClick = function()
                if Profile.TrackUnlocked(entry.id) then
                    self:SelectTrack(entry.id, true); self:SetScreen("garage")
                elseif self.actions.unlockTrack then self.actions.unlockTrack(entry.id) end
            end,
            children = {UI.Column {position = "absolute", left = 8, right = 8, top = 7, bottom = 7,
                padding = 0, gap = 3, pointerEvents = "none", children = {
                    UI.Row {padding = 0, justifyContent = "space-between", children = {
                        label(string.format("%02d  %s", index, entry.name or entry.id), 12, WHITE, {fontWeight = "bold"}),
                        label(string.format("%.2f km", (entry.length or 0) / 1000), 9, accent)}}, graphic,
                    label(themes[entry.theme] or entry.theme or "公路", 9, accent, {maxLines = 1}),
                    label(entry.description or "", 8, MUTED, {width = "100%", maxLines = 1}),
                    label(string.format("%d圈 · 收益%d金币", entry.laps or 3, entry.reward or 100), 8, MUTED, {maxLines = 1}),
                    label(unlocked and "可参赛" or string.format("未解锁 · %d金币", entry.price or 0), 8,
                        unlocked and accent or {214, 148, 96, 255}, {maxLines = 1})}}}}
        self.trackCards[entry.id], self.trackGraphics[entry.id] = card, graphic
        rows[math.floor((index - 1) / 3) + 1]:AddChild(card)
    end
end
function HUD:OpenTracks()
    self:RefreshTrackCards()
    self:SelectTrack(self.selectedTrack, false)
    self:SetScreen("tracks")
end
function HUD:SelectTrack(id, notify)
    local selected = nil ---@type table?
    for _, item in ipairs(trackList()) do if item.id == id then selected = item; break end end
    if not selected then
        -- Do not manufacture playable ids when the map module has not landed yet.
        if not notify then self.selectedTrack = id end
        return false
    end
    if not Profile.TrackUnlocked(id) then
        -- 未解锁不得切到该赛道；调用方负责提示或购买。
        return false
    end
    self.selectedTrack = id
    for trackId, card in pairs(self.trackCards) do
        card:SetStyle({borderColor = trackId == id and AMBER or BORDER, borderWidth = trackId == id and 2 or 1,
            backgroundColor = trackId == id and {52, 47, 34, 255} or {14, 26, 37, 255}})
    end
    self.trackButton:SetText("赛道 · " .. (selected.name or id) .. " ›")
    -- Invalidate the racing minimap when the actual world/route changes.
    self.trackMap.points, self.trackMap.routeReady, self.trackMap.routeLength = {}, false, 0
    if notify and self.actions.selectTrack then self.actions.selectTrack(id) end
    print("[赛道界面] 选择 " .. id .. (notify and " → 通知入口" or " / 同步"))
    return true
end

local function help()
    return UI.Column {width = "100%", gap = 7, padding = 0, children = {
        label("驾驶与竞速", 12, AMBER),
        label("左右滑动转向，按住油门加速、刹车制动。点按氮气消耗45点，喷射2.5秒，尾焰与视野冲刺会明显放大。Q/侧键位为翘头，按住抬起前轮。多指互不抢占。", 11, MUTED,
            {width = "100%", whiteSpace = "normal", maxLines = 6}),
        label("键盘 W/S 油刹，A/D 转向，Shift 氮气，C 视角，Q 翘头 / Z 烧胎按住，X 180° / V 360°点按起跳旋转。比赛与练习都可用。本版不提供撞人攻击。", 11, MUTED,
            {width = "100%", whiteSpace = "normal", maxLines = 5}),
        label("翘头自动配合油门；烧胎自动配合油刹。旋转可在平稳行驶至15km/h后辅助起跳，也可在腾空时点按。按键有接收反馈，不满足条件不会假装成功。虚拟竞速，请勿现实模仿。", 10, MUTED,
            {width = "100%", whiteSpace = "normal", maxLines = 4})}}
end
function HUD:BuildPauseAndResult()
    local a = self.actions
    self.musicButton = button("音乐 开", function()
        if a.music then self.musicButton:SetText(a.music() and "音乐 开" or "音乐 关") end
    end, false, 100)
    self.effectsButton = button("音效 开", function()
        if a.effects then self.effectsButton:SetText(a.effects() and "音效 开" or "音效 关") end
    end, false, 100)
    self.qualityButton = button("画质 · 流畅", function() if a.quality then self:SetQuality(a.quality() or self.qualityName) end end, false, 112)
    self.qualityButton:SetDisabled(type(a.quality) ~= "function")
    self.pause = UI.Panel(fill({visible = false, backgroundColor = {5, 8, 11, 225}, padding = 12,
        alignItems = "center", justifyContent = "center", children = {
            UI.Column {width = "92%", maxWidth = 680, height = "96%", padding = 16, gap = 10,
                borderRadius = 5, borderWidth = 1, borderColor = BORDER, backgroundColor = DARK, children = {
                    UI.Row {padding = 0, justifyContent = "space-between", alignItems = "center", children = {
                        label("已暂停", 23), button("继续竞速 →", a.pause, true, 140)}},
                    UI.ScrollView {width = "100%", flexGrow = 1, flexBasis = 0, flexShrink = 1, padding = 0, children = {
                        UI.Column {width = "100%", padding = 0, gap = 10, children = {
                            UI.Row {padding = 0, gap = 7, flexWrap = "wrap", children = {self.musicButton, self.effectsButton, self.qualityButton,
                                button("按键布局 / 灵敏度", function() self:OpenSettings() end, false, 168)}},
                            UI.Row {padding = 0, gap = 10, children = {self.score, self.health}},
                            self.radioTitle,
                            UI.Row {padding = 0, gap = 7, children = {button("上一首", a.previousTrack, false, 90), self.radioToggle, button("下一首", a.nextTrack, false, 90)}}, help()}}}},
                    UI.Row {padding = 0, gap = 8, children = {button("重新开始", a.restart, false, 130), button("主菜单", a.menu, false, 130)}}}}}}))
    self.resultTitle = label("竞速结算", 24, WHITE, {maxLines = 2, whiteSpace = "normal", width = "100%"})
    self.resultStats = label("", 11, MUTED, {maxLines = 5, whiteSpace = "normal", width = "100%"})
    local list = UI.Column {width = "100%", padding = 0, gap = 4}
    for i = 1, 9 do
        local row = label("", 11, MUTED, {width = "100%", height = 26, paddingHorizontal = 8,
            backgroundColor = {25, 31, 37, 160}, borderRadius = 2, visible = false})
        self.resultRows[i] = row; list:AddChild(row)
    end
    self.result = UI.Panel(fill({visible = false, backgroundColor = {5, 8, 11, 230}, padding = 12,
        alignItems = "center", justifyContent = "center", children = {
            UI.Column {width = "92%", maxWidth = 660, height = "96%", padding = 16, gap = 10,
                backgroundColor = DARK, borderWidth = 1, borderColor = BORDER, borderRadius = 5, children = {
                    label("RACE CLASSIFICATION / 比赛结果", 9, AMBER),
                    UI.ScrollView {width = "100%", padding = 0, flexGrow = 1, flexBasis = 0, flexShrink = 1, children = {
                        UI.Column {width = "100%", padding = 0, gap = 9, children = {self.resultTitle, self.resultStats, list}}}},
                    UI.Row {padding = 0, gap = 8, children = {button("再赛一次 →", a.restart, true, 160), button("返回主菜单", a.menu, false, 150)}}}}}}))
end
function HUD:BuildLoading()
    local a = self.actions
    self.loadTitle = label("正在准备竞速", 24)
    self.loadDetail = label("正在检查本地缓存", 11, MUTED, {whiteSpace = "normal", maxLines = 4, width = "100%"})
    self.loadNumbers = label("等待资源清单", 10, AMBER, {whiteSpace = "normal", maxLines = 2, width = "100%"})
    self.loadBar = bar(AMBER, 5)
    self.retry = button("重试", a.retry, true, 150); self.retry:SetVisible(false)
    self.enterRide = button("资源就绪 · 出发 →", a.enter, true, 240); self.enterRide:SetVisible(false)
    self.loading = UI.Panel(fill({visible = false, padding = 28, justifyContent = "flex-end", children = {
        UI.Column {width = "53%", maxWidth = 580, padding = 16, gap = 10, borderRadius = 4,
            backgroundColor = {10, 13, 17, 205}, children = {
                label("PURSUIT / RACE PREPARATION", 10, AMBER), self.loadTitle, self.loadDetail, self.loadBar, self.loadNumbers,
                label("握稳车把。氮气突围，甩开追车。", 11, MUTED), self.retry, self.enterRide}}}}))
end

function HUD:OpenGarage(challenge)
    self.challenge = challenge == true
    self:SelectLaps(self.selectedLaps, false)
    self:SetScreen("garage")
    if self.actions.start then self.actions.start(self.challenge) end
end
function HUD:SelectVehicle(id, notify)
    local item = Catalog.Get(id)
    if not item then return end
    self.selectedVehicle = id
    for _, v in ipairs(Catalog.List) do
        local selected = v.id == id
        local owned = Profile.Owns(v.id)
        self.vehicleCards[v.id]:SetStyle({borderColor = selected and AMBER or BORDER,
            backgroundColor = selected and {59, 46, 29, 235} or {17, 21, 26, 215}, borderWidth = 1})
        self.vehicleBadges[v.id]:SetText(v.available == false and "准备中 · 不可驾驶"
            or (not owned and ("未拥有 · " .. tostring(v.price or 0) .. " 金币"))
            or (selected and "已选中" or "点按选择"))
        self.vehicleBadges[v.id]:SetFontColor(not owned and (selected and AMBER or MUTED) or (selected and AMBER or MUTED))
    end
    self.vehicleName:SetText(item.name or id)
    self.vehicleDescription:SetText(item.description or item.tag or "")
    self.vehicleSpecs:SetText(string.format("极速 %s km/h  /  加速 %d  /  操控 %d  /  耐久 %d",
        tostring(item.speedStat or item.speed or "—"), math.floor(item.acceleration or 0),
        math.floor(item.handling or 0), math.floor(item.durability or 0)))
    local owned = Profile.Owns(id)
    local price = item.price or 0
    self.coinLabel:SetText("金币 " .. tostring(Profile.Coins()))
    self.buyButton:SetVisible(not owned and price > 0)
    self.buyButton:SetText("购买 · " .. tostring(price) .. " 金币")
    self.buyButton:SetDisabled(Profile.Coins() < price)
    self.confirmButton:SetDisabled(item.available == false or not owned)
    self.confirmButton:SetText(item.available == false and "独立车型准备中"
        or (not owned and ("未拥有 · " .. tostring(price) .. " 金币")) or "确认座驾 · 出发 →")
    if self.screen == "garage" then self.preview:Select(id, item.available) end
    if notify and self.actions.selectVehicle then self.actions.selectVehicle(id) end
end
function HUD:SelectRider(id, notify)
    if not self.riderButtons[id] then return end
    local owned = Profile.OwnsRider(id)
    if not owned and notify and self.actions.buyRider then
        -- 未拥有时交给主流程购买；买成功后由主流程再次调用本函数同步画面。
        self.actions.buyRider(id)
        return
    end
    self.selectedRider = id
    for _, rider in ipairs(RIDERS) do if rider.id == id then self.preview:SetRiderColor(rider.color) end end
    for colorId, swatch in pairs(self.riderButtons) do
        local selectable = Profile.OwnsRider(colorId)
        swatch:SetStyle({borderColor = colorId == id and AMBER or (selectable and BORDER or {92, 74, 52, 200}),
            borderWidth = colorId == id and 2 or 1,
            opacity = selectable and 1 or 0.55})
    end
    if notify and self.actions.selectRider then self.actions.selectRider(id) end
end
-- 购买成功后刷新配色与金币
function HUD:RefreshOwnership()
    self.trackCount = 0
    self:RefreshTrackCards()
    self.coinLabel:SetText("金币 " .. tostring(Profile.Coins()))
    for colorId, swatch in pairs(self.riderButtons) do
        local selectable = Profile.OwnsRider(colorId)
        swatch:SetStyle({borderColor = colorId == self.selectedRider and AMBER or (selectable and BORDER or {92, 74, 52, 200}),
            borderWidth = colorId == self.selectedRider and 2 or 1,
            opacity = selectable and 1 or 0.55})
    end
end
function HUD:SelectLaps(count, notify)
    -- 圈数由赛道固定；这里只记录并同步显示，玩家不能再自选。
    self.selectedLaps = math.max(1, math.min(9, math.floor(count)))
    local track = nil
    for _, item in ipairs(trackList()) do if item.id == self.selectedTrack then track = item; break end end
    local reward = track and track.reward or 100
    if self.lapFixedLabel then self.lapFixedLabel:SetText(string.format("%d 圈 · 收益 %d", self.selectedLaps, reward)) end
    self.selectionMode:SetText(self.challenge and ("竞速 / " .. self.selectedLaps .. " 圈 · 九人同场") or "自由练习 / 无淘汰")
    if notify and self.actions.selectLaps then self.actions.selectLaps(self.selectedLaps) end
end
function HUD:SetRace(race)
    self.race, self.hasRace, self.resultKey = race or {}, race ~= nil and race.phase ~= "idle", ""
    self:RefreshRace()
end
function HUD:SetQuality(name)
    self.qualityName = name or "流畅"; self.qualityButton:SetText("画质 · " .. self.qualityName)
end
function HUD:SyncRadio(title, enabled)
    self.radioTitle:SetText(title or "骑行电台"); self.radioToggle:SetText(enabled and "暂停" or "播放")
    self.musicButton:SetText(enabled and "音乐 开" or "音乐 关")
end
function HUD:SetScreen(screen)
    local oldScreen = self.screen
    self.screen = screen
    if oldScreen == "garage" and screen ~= "garage" then self.preview:Dispose() end
    self.menu:SetVisible(screen == "menu"); self.garage:SetVisible(screen == "garage"); self.trackSelection:SetVisible(screen == "tracks")
    local editing = screen == "settings"
    if oldScreen == "settings" and not editing then
        if self.dragSlot then self:EndDragSettingButton(nil, true) end
        self.controls:SetEditor(nil)
    end
    self.game:SetVisible(screen == "ride" or screen == "pause" or screen == "result" or editing)
    self.pause:SetVisible(screen == "pause"); self.result:SetVisible(screen == "result"); self.loading:SetVisible(screen == "loading")
    if self.settings then self.settings:SetVisible(editing) end
    self.pageBackdrop:SetVisible(screen == "menu" or screen == "garage" or screen == "loading" or screen == "tracks"
        or (editing and self.settingsReturn == "menu"))
    self.keyartBackdrop:SetVisible(screen ~= "garage"); self.garageBackdrop:SetVisible(screen == "garage")
    self.cockpit:SetVisible(false); self.enterRide:SetVisible(false)
    local riding = screen == "ride"
    self.controlLayer:SetVisible(riding or editing)
    if riding or editing then self.pendingControlLayout = true end
    self.rightTop:SetVisible(riding or editing); self.recoverPanel:SetVisible(riding or editing)
    self.rightTop:SetStyle({pointerEvents = editing and "none" or "box-none"})
    self.recoverPanel:SetStyle({pointerEvents = editing and "none" or "box-none"})
    self.instrumentPanel:SetVisible((riding or editing) and not self.firstPerson)
    self.controls:SetEnabled(riding and not self.portraitActive)
    if screen == "garage" and not self.portraitActive then
        local item = Catalog.Get(self.selectedVehicle)
        self.preview:Select(self.selectedVehicle, item and item.available)
    end
    self:LayoutResponsive()
end
function HUD:SetLoading(stage, detail, progress, numbers, failed)
    self.loadTitle:SetText(stage or "正在准备竞速"); self.loadDetail:SetText(detail or "")
    self.loadBar:SetValue(math.max(0, math.min(1, progress or 0))); self.loadNumbers:SetText(numbers or "")
    self.retry:SetVisible(failed == true); if failed then self.enterRide:SetVisible(false) end
end
function HUD:SetPortrait(portrait)
    self.portrait:SetVisible(portrait)
    if self.portraitActive ~= portrait then
        self.portraitActive = portrait; self.controls:SetEnabled(self.screen == "ride" and not portrait)
        if portrait then self.cockpit:SetVisible(false); self.preview:Dispose()
        elseif self.screen == "garage" then
            local item = Catalog.Get(self.selectedVehicle); self.preview:Select(self.selectedVehicle, item and item.available)
        end
    end
    self:LayoutResponsive()
end
function HUD:LayoutResponsive()
    local vw, vh = UI.GetViewportSize()
    local insets = UI.GetSafeAreaInsets()
    local w, h = vw - insets.left - insets.right, vh - insets.top - insets.bottom
    if w == self.layoutWidth and h == self.layoutHeight then
        -- 尺寸没变也可能刚显示驾驶层，仍需要把按键摆到方案位置。
        if self.pendingControlLayout then
            self.pendingControlLayout = false
            self:ApplySettings()
        end
        return
    end
    self.layoutWidth, self.layoutHeight = w, h
    self.pendingControlLayout = true
    local compact = w < 920 or h < 470
    self.controls:SetCompact(compact)
    self.menu:SetStyle({padding = compact and 18 or 30})
    self.garage:SetStyle({padding = compact and 10 or 20})
    self.garageList:SetWidth(compact and 184 or 228)
    self.confirmButton:SetWidth(compact and 190 or 228)
    self.garageFooter:SetStyle({gap = compact and 9 or 16})
    self.trackMap:SetStyle({width = compact and 126 or 152, height = compact and 95 or 122, top = compact and 77 or 89})
    self.rankPanel:SetWidth(compact and 126 or 152)
    self.navPanel:SetStyle({left = compact and 146 or 178, width = compact and 112 or 126})
    self.dangerPanel:SetStyle({top = compact and 85 or 8, width = compact and 208 or 244, marginLeft = compact and -104 or -122})
    self.instrumentPanel:SetStyle({width = compact and 198 or 228, height = compact and 98 or 112, marginLeft = compact and -99 or -114})
    self.nitroPanel:SetStyle({bottom = compact and 118 or 132, width = compact and 178 or 196, marginLeft = compact and -89 or -98})
    self.trackSelection:SetStyle({padding = compact and 12 or 20})
    for _, card in pairs(self.trackCards) do card:SetHeight(compact and 151 or 178) end
    for _, graphic in pairs(self.trackGraphics) do graphic:SetHeight(compact and 69 or 94) end
    if self.pendingControlLayout then
        self.pendingControlLayout = false
        self:ApplySettings()
    end
end

function HUD:RefreshRace()
    local race = self.race
    self.hasRace = race.phase ~= nil and race.phase ~= "idle"
    local active = self.hasRace
    self.rankPanel:SetVisible(active); self.nitroPanel:SetVisible(active); self.dangerPanel:SetVisible(active)
    self.rank:SetText(string.format("%02d", math.floor(race.position or 1)))
    self.rankTotal:SetText(string.format("/ %02d", #(race.racers or race.standings or {})))
    self.lap:SetText(active and string.format("%02d / %02d", math.min(math.floor(race.lap or 1), math.floor(race.laps or self.selectedLaps)), math.floor(race.laps or self.selectedLaps)) or "自由练习")
    local player = race.player
    -- Race progress/playerS are validated traveled meters, not a normalized fraction.
    -- Use the authoritative lap length even before the minimap has sampled Landscape.
    local routeLength = race.length or self.trackMap.routeLength or 0
    local totalLength = routeLength * (race.laps or self.selectedLaps)
    local traveled = (player and player.progress) or race.playerS or 0
    local progress = active and totalLength > 0 and traveled / totalLength or 0
    self.route:SetValue(math.max(0, math.min(1, progress)))
    self.time:SetText(clock(race.elapsed or 0))
    self.remaining:SetText(string.format("%d 人在赛", math.floor(race.remaining or 9)))
    self:RefreshActionFeedback()
    local danger = math.max(0, math.min(1, race.danger or 0))
    self.dangerBar:SetValue(danger)
    local protection, gap = race.protection or 0, race.policeGap
    if protection > 0 then
        self.dangerText:SetText(string.format("保护中  %.1fs", protection)); self.dangerText:SetFontColor(GREEN)
    elseif danger > 0 then
        self.dangerText:SetText("追捕危险  " .. string.format("%03d%%", math.floor(danger * 100)) .. (gap and string.format(" / %.0fm", math.abs(gap)) or ""))
        self.dangerText:SetFontColor(RED)
    else
        self.dangerText:SetText("追车目标  " .. (race.targetName or "—") .. (gap and string.format(" / %.0fm", math.abs(gap)) or ""))
        self.dangerText:SetFontColor(MUTED)
    end
    local count = race.phase == "countdown" and math.ceil(race.countdown or 0) or 0
    self.countdown:SetText(count > 0 and tostring(count) or (race.phase == "racing" and (race.elapsed or 0) < 0.85 and "GO" or ""))
    if active and race.player then
        self.trackMap.playerX, self.trackMap.playerZ = race.player.x or 0, race.player.z or 0
    end
    self.trackMap.markers = {}
    for _, racer in ipairs(race.racers or {}) do
        self.trackMap.markers[#self.trackMap.markers + 1] = racer
    end
    local police = race.pursuit or race.police
    if police and police.active then
        self.trackMap.markers[#self.trackMap.markers + 1] = {x = police.x or 0, z = police.z or 0, police = true}
    end
end

function HUD:RefreshActionFeedback()
    local race = self.race
    local player = race.player or {}
    local amount = math.max(0, math.min(100, race.nitro or player.nitro or 0))
    local remaining = race.nitroRemaining or player.boostTimer or 0
    local active = race.nitroActive == true or (race.nitroActive == nil and remaining > 0)
    local cooldown = race.nitroCooldown or 0
    local reason = race.nitroReason or (amount >= 45 and "可用" or "氮气不足")
    local state, title, detail = "ready", "氮气就绪", "点按喷射2.5秒 · 耗45"
    if not self.hasRace then state, title, detail = "blocked", "竞速专用", "自由练习不消耗氮气"
    elseif active then
        state, title, detail = "active", "正在喷射", string.format("剩余 %.1fs · 脉冲结束后可再用", remaining)
    elseif cooldown > 0 then state, title, detail = "cooldown", "氮气冷却", string.format("冷却 %.1fs", cooldown)
    elseif reason == "氮气不足" or amount < 45 then state, title, detail = "empty", "氮气不足", "至少45点 · 行驶 / 尾流补充"
    elseif reason ~= "可用" then state, title, detail = "blocked", reason, "解除限制后再点按"
    elseif player.boostLock and self.controls.nitro then state, title, detail = "cooldown", "松手再喷", "本次喷射已完成 · 松开后再点按" end
    self.nitroValue:SetText(string.format("%s · %03d%%", title, math.floor(amount)))
    self.nitroHint:SetText(detail)
    self.nitroBar:SetValue(amount / 100)
    self.nitroValue:SetFontColor(state == "active" and {116, 239, 247, 255} or ((state == "empty" or state == "blocked") and RED or AMBER))
    local short = state == "active" and string.format("喷射 %.1fs", remaining)
        or (state == "cooldown" and (cooldown > 0 and string.format("冷却 %.1fs", cooldown) or "松手再喷")
            or (state == "ready" and "就绪 · 耗45" or title))
    self.controls:SetActionState("nitro", {state = state, label = "氮气", detail = short, value = amount / 100})
    -- 翘头按钮本身由 Update 依据实际车速/抬轮角统一刷新状态。
end

-- Existing main update signature remains valid. Preview animation runs through its Widget Update,
-- including before the driving scene exists; leaving garage disposes all render targets immediately.
function HUD:Update(dt, sim, firstPerson)
    self.firstPerson = firstPerson == true
    self.controls:UpdateFeedback(dt)
    self.redline = (sim.vehicle and sim.vehicle.redline) or 12500
    self.instrumentPanel:SetTelemetry((sim.speed or 0) * 3.6, sim.gear or 0, sim.rpm or 1200, (sim.vehicle and sim.vehicle.redline) or 12500)
    self.instrumentPanel:SetVisible((self.screen == "ride" or self.screen == "settings") and (not self.firstPerson or not self.cockpit:IsVisible()) and not self.portraitActive)
    self:LayoutResponsive()
    self.timer = self.timer + dt
    if self.timer < 0.1 then return end
    self.timer = self.timer % 0.1
    if not self.trackMap.routeReady then self.trackMap:Prepare(sim.landscape or require("Landscape")) end
    self.speed:SetText(string.format("%03d", math.floor((sim.speed or 0) * 3.6)))
    self.gear:SetText(sim.gear == 0 and "N" or tostring(sim.gear or 1))
    self.distance:SetText(string.format("%.2f km", (sim.distance or 0) / 1000))
    self.score:SetText(string.format("得分 %06d", math.floor(sim.score or 0)))
    self.overtakes:SetText(tostring(sim.overtakes or 0)); self.health:SetText(string.format("车况 %.0f%%", sim.health or 100))
    self.health:SetFontColor((sim.health or 100) < 35 and RED or WHITE)
    self.message:SetText((sim.messageTimer or 0) > 0 and (sim.message or "") or "")
    self.camera:SetText(firstPerson and "头盔视角" or "追尾视角")
    self.rpm:SetValue(math.min(1, (sim.rpm or 1200) / ((sim.vehicle and sim.vehicle.redline) or 11000)))
    self.rpmNumber:SetText(string.format("%.0f rpm", sim.rpm or 1200))
    self.region:SetText(sim.regionName or "环湖公路"); self.target:SetText(sim.goalName or "")
    self:RefreshRace()
    self.controls:SetActionState("wheelie", {state = (sim.wheelieAngle or 0) > 8 and "active"
        or ((sim.speed or 0) >= 31 and "blocked" or "ready"),
        detail = (sim.wheelieAngle or 0) > 8 and "前轮抬起 · 松手放下"
            or ((sim.speed or 0) >= 31 and "车速过高 · 先减速" or "按住抬轮")})
    self.controls:SetActionState("burnout", {state = sim.burnout and "active" or "ready", detail = sim.burnout and "正在烧胎" or "按住原地"})
    local spinDetail, spinState = "点按起跳旋转", "ready"
    if sim.wrecked then spinDetail, spinState = "损坏 · 先复位", "blocked"
    elseif (sim.spinTarget or 0) ~= 0 then spinDetail, spinState = "正在旋转", "active"
    elseif (sim.stuntCooldown or 0) > 0 then spinDetail, spinState = string.format("冷却 %.1fs", sim.stuntCooldown), "cooldown"
    elseif sim.airborne then spinDetail = "腾空 · 点按旋转"
    elseif (sim.speed or 0) < 4 then spinDetail, spinState = "先加速至15", "blocked"
    elseif (sim.rampCooldown or 0) > 0 then spinDetail, spinState = string.format("冷却 %.1fs", sim.rampCooldown), "cooldown"
    elseif sim.braking or sim.burnout or (sim.crashCooldown or 0) > 0 or (sim.wheelieAngle or 0) > 12 then spinDetail, spinState = "先稳住车身", "blocked" end
    for _, key in ipairs({"spin180", "spin360"}) do
        self.controls:SetActionState(key, {state = spinState, detail = spinDetail})
    end
    if not self.hasRace then
        self.time:SetText(clock(sim.elapsed or 0)); self.trackMap.playerX, self.trackMap.playerZ = sim.x or 0, sim.z or 0
    end
    if self.screen == "result" and self.hasRace then self:RefreshResults() end
end

-- The original cockpit projection API is kept unchanged for main/Bike integration.
function HUD:UpdateCockpit(screenX, screenY, visible, speed, gear, rpm)
    local w, h = UI.GetViewportSize()
    local show = visible == true and self.screen == "ride" and not self.portraitActive
        and screenX ~= nil and screenY ~= nil and screenX >= 77 and screenX <= w - 77 and screenY >= 38 and screenY <= h - 38
    local wasVisible = self.cockpit:IsVisible(); self.cockpit:SetVisible(show)
    self.instrumentPanel:SetVisible(self.screen == "ride" and not self.portraitActive and (not self.firstPerson or not show))
    if not show then return end
    if not wasVisible or math.abs(screenX - self.cockpitX) > 0.25 or math.abs(screenY - self.cockpitY) > 0.25 then
        self.cockpit:SetStyle({left = screenX - 77, top = screenY - 38}); self.cockpitX, self.cockpitY = screenX, screenY
    end
    self.cockpit:SetTelemetry(speed, gear, rpm, self.redline or 12500)
end
function HUD:RefreshResults()
    local race, result = self.race, self.race.result or {}
    -- Race:Rank maps racer.finishTime to row.elapsed; Settle copies that frozen row.
    -- Do not read raw racer.finishTime/time from the public classification payload.
    local rows = race.results or race.standings or {}
    self.resultTitle:SetText(result.title or "竞速结算")
    self.resultStats:SetText((result.reason or "") .. string.format("\n排名 %02d / %02d    用时 %s", math.floor(result.position or race.position or 1), #rows, clock(result.elapsed or race.elapsed or 0)))
    for i, row in ipairs(self.resultRows) do
        local entry = rows[i]
        row:SetVisible(entry ~= nil)
        if entry then
            local status = entry.status == "eliminated" and "已淘汰" or (entry.status == "finished" and clock(entry.elapsed) or "未完赛")
            row:SetText(string.format("%02d    %s%s    /    %s", math.floor(entry.position or i), entry.isPlayer and "玩家 · " or "", entry.name or entry.id or "车手", status))
            row:SetFontColor(entry.isPlayer and AMBER or MUTED)
        end
    end
end
function HUD:ShowResult(sim)
    self:SetScreen("result")
    if self.hasRace then self:RefreshResults(); return end
    for _, row in ipairs(self.resultRows) do row:SetVisible(false) end
    self.resultTitle:SetText("自由练习记录")
    self.resultStats:SetText(string.format("用时 %s\n里程 %.2f km    最高时速 %.0f km/h\n超车 %d    剩余车况 %.0f%%",
        clock(sim.elapsed), (sim.distance or 0) / 1000, sim.topSpeed or 0, sim.overtakes or 0, sim.health or 100))
end
function HUD:Dispose()
    self.controls:SetEnabled(false)
    self.preview:Dispose()
end

return HUD
