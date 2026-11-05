-- Pursuit race UI: restrained BrawlForge silhouettes, graphite metal, cyan/amber hierarchy.
-- Page styles are centralized; the UI library owns NanoVG frames, fonts, DPI and input.
local UI = require("urhox-libs/UI")
local RacingTheme = require("RacingTheme")
-- PhonePages/PhoneKit 只有 Widget 分页与文字测量，不加载生涯会话、档案或业务。
local PageText = require("Career.PhoneKit").Text
local Catalog = require("Catalog")
local MixedRace = require("MixedRace")
local SkillNames = require("SkillNames")
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

---@class HUD : ControlEditor, RouteSelect, RacingDialogs
---@field garageGMButton Button
---@field trialButton Button
---@field skillButton Button
---@field activeModal Modal?
---@field settingsReturn string
---@field OpenSettings fun(self:HUD)
---@field pausedCockpitVisible boolean?
---@field resultRewardText string?
---@field SetResultReward fun(self:HUD, text:string)
local HUD = {}
HUD.__index = HUD
local C = RacingTheme.Colors
local AMBER, WHITE = C.amber, C.white
local MUTED, STEEL = C.muted, C.steel
local DARK, BORDER = C.dark, C.border
local RED, GREEN = C.red, C.green
local function isWeaponFeedback(text)
    return type(text) == "string" and (text:find("锁定", 1, true) ~= nil or text:find("发射", 1, true) ~= nil)
end
require("RouteSelect").Install(HUD)
require("RacingDialogs").Install(HUD)
local MENUART = "image/highway_brawl_main_menu_20261104221739.png"
local LOGO = "image/highway_brawl_title_logo_20261104221559.png"
local KEYART = "image/vehicle_brawl_keyart_20261104212846.png"
local GARAGE = "image/vehicle_brawl_garage_20261104213013.png"
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
HUD.Resources, HUD.ResourceTypes = {MENUART, LOGO, KEYART, GARAGE, RacingTheme.FontPath, RacingTheme.HeroImage},
    {[MENUART] = "Texture2D", [LOGO] = "Texture2D", [KEYART] = "Texture2D", [GARAGE] = "Texture2D", [RacingTheme.FontPath] = "Font", [RacingTheme.HeroImage] = "Texture2D"}
for _, path in ipairs(MobileControls.Resources) do
    HUD.Resources[#HUD.Resources + 1], HUD.ResourceTypes[path] = path, MobileControls.ResourceTypes[path]
end
for _, path in ipairs(GaragePreview.Resources) do
    HUD.Resources[#HUD.Resources + 1], HUD.ResourceTypes[path] = path, GaragePreview.ResourceTypes[path]
end

local label = RacingTheme.Label
local function playUI(kind)
    require("FrontendAudio").PlayUI(kind)
end
local function button(text, callback, primary, width, props)
    local kind = props and props.uiSound or (text:find("返回",1,true) and "back"
        or ((text:find("出发",1,true) or text:find("进入赛事",1,true) or text:find("再赛",1,true)) and "confirm" or "click"))
    return RacingTheme.Button(text, function(...)
        if kind ~= "manual" then playUI(kind) end
        if callback then return callback(...) end
    end, primary, width, props)
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
    return UI.Button {text = names[symbol] or "返回", variant = "secondary", width = 54, height = 54, padding = 0,
        paddingTop = 29, fontSize = 9, borderRadius = 6, borderWidth = 1,
        textColor = WHITE, borderColor = BORDER, backgroundColor = {9, 17, 24, 215},
        pressedBackgroundColor = {112, 79, 34, 240}, hoverBackgroundColor = {30, 48, 60, 235},
        onClick = action, children = {Symbol {position = "absolute", top = 3, left = 0, right = 0, height = 28,
            symbol = symbol, pointerEvents = "none"}}}
end

local WeaponReticle = UI.Widget:Extend("WeaponReticle")
function WeaponReticle:Render(vg)
    local l = self:GetAbsoluteLayout()
    local cx, cy = l.x + l.w * 0.5, l.y + l.h * 0.5
    local radius = math.min(l.w, l.h) * 0.34
    local progress = math.max(0, math.min(1, self.props.progress or 0))
    local edge = self.props.edge == true
    local color = self.props.locked and nvgRGBA(255, 74, 54, 245) or nvgRGBA(255, 196, 74, 245)
    nvgSave(vg)
    nvgBeginPath(vg)
    nvgCircle(vg, cx, cy, radius)
    nvgStrokeColor(vg, nvgRGBA(22, 30, 36, 180)); nvgStrokeWidth(vg, 1.5); nvgStroke(vg)
    if progress > 0 then
        nvgBeginPath(vg)
        nvgArc(vg, cx, cy, radius + 4, -math.pi * 0.5, -math.pi * 0.5 + math.pi * 2 * progress, NVG_CW)
        nvgStrokeColor(vg, color); nvgStrokeWidth(vg, 2.5); nvgStroke(vg)
    end
    nvgBeginPath(vg)
    local arm = radius + 8
    local gap = 7
    local length = 10
    -- 四角括号准星：每个角只画两条线，避免旧十字叠画造成中心重复。
    for _, s in ipairs({-1, 1}) do
        for _, t in ipairs({-1, 1}) do
            local x = cx + s * gap
            local y = cy + t * gap
            nvgMoveTo(vg, x, cy + t * arm)
            nvgLineTo(vg, x, cy + t * (arm - length))
            nvgMoveTo(vg, cx + s * arm, y)
            nvgLineTo(vg, cx + s * (arm - length), y)
        end
    end
    nvgStrokeColor(vg, color); nvgStrokeWidth(vg, 2); nvgStroke(vg)
    if edge then
        nvgBeginPath(vg)
        nvgMoveTo(vg, cx, cy - arm - 8); nvgLineTo(vg, cx - 5, cy - arm + 1); nvgLineTo(vg, cx + 5, cy - arm + 1)
        nvgClosePath(vg); nvgFillColor(vg, color); nvgFill(vg)
    end
    nvgRestore(vg)
end

-- 加速带的屏幕速度线只画在视野边缘。
local RoadRush = UI.Widget:Extend("RoadRushFeedback")
function RoadRush:Init(props)
    UI.Widget.Init(self, props)
    self.power, self.phase = 0, 0
end
function RoadRush:Render(vg)
    if self.power <= 0 then return end
    local l = self:GetAbsoluteLayout()
    nvgSave(vg)
    nvgIntersectScissor(vg, l.x, l.y, l.w, l.h)
    for i = 1, 18 do
        local a = i * 2.39996
        local phase = (self.phase * 2.6 + i * 0.173) % 1
        local rx, ry = math.cos(a), math.sin(a)
        local inner, outer = 0.72 + phase * 0.30, 0.82 + phase * 0.38
        nvgBeginPath(vg)
        nvgMoveTo(vg, l.x + l.w * (0.5 + rx * inner * 0.58), l.y + l.h * (0.5 + ry * inner * 0.62))
        nvgLineTo(vg, l.x + l.w * (0.5 + rx * outer * 0.58), l.y + l.h * (0.5 + ry * outer * 0.62))
        nvgStrokeWidth(vg, (i % 3 == 0 and 3 or 1.5) * self.power)
        nvgStrokeColor(vg, nvgRGBA(107, 255, 218, math.floor(190 * self.power * math.sin(phase * math.pi))))
        nvgStroke(vg)
    end
    nvgRestore(vg)
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
    UI.Init({theme = RacingTheme.Theme, scale = UI.Scale.DEFAULT})
    self:BuildRide(); self:BuildMenu(); self:BuildSettings(); self:BuildGarage(); self:BuildTracks(); self:BuildPauseAndResult(); self:BuildLoading()
    self.portrait = UI.Panel(fill({visible = false, backgroundColor = {9, 12, 15, 255},
        alignItems = "center", justifyContent = "center", padding = 24, gap = 12, children = {
            label("请横屏握持手机", 24), label("载具大乱斗 · 横屏竞速", 12, AMBER),
            label("左手转向 · 右手油刹 / 氮气 / 近身对抗", 11, MUTED, {textAlign = "center", whiteSpace = "normal"})}}))
    self.safeContent = UI.Panel {width = "100%", flexGrow = 1, flexShrink = 1, minHeight = 0, padding = 0,
        pointerEvents = "box-none", children = {self.menu, self.garage, self.trackSelection, self.game, self.pause, self.result, self.loading, self.settings}}
    self.menuBackdrop = UI.Panel(fill({backgroundImage = MENUART, backgroundFit = "cover", pointerEvents = "none"}))
    self.keyartBackdrop = UI.Panel(fill({backgroundImage = KEYART, backgroundFit = "cover", pointerEvents = "none"}))
    self.garageBackdrop = UI.Panel(fill({backgroundImage = GARAGE, backgroundFit = "cover", pointerEvents = "none", visible = false,
        children = {self.preview}}))
    self.pageBackdrop = UI.Panel(fill({pointerEvents = "none", backgroundColor = {9, 12, 15, 255}, children = {
        self.menuBackdrop, self.keyartBackdrop, self.garageBackdrop}}))
    self.root = UI.Panel {width = "100%", height = "100%", padding = 0, pointerEvents = "box-none", children = {
        self.pageBackdrop,
        UI.SafeAreaView {width = "100%", height = "100%", padding = 0, nativeMenuInset = true,
            pointerEvents = "box-none", children = {self.safeContent}}, self.cockpit, self.portrait}}
    UI.SetRoot(self.root)
    self:SelectVehicle(Profile.FREE_VEHICLE, false); self:SelectRider(Profile.FREE_RIDER, false); self:SelectLaps(3, false); self:SelectTrack(Profile.FREE_TRACK, false)
    self:SetScreen("menu"); self:LayoutResponsive(); self:RefreshRace()
    -- Art is optional during initial menu display; never block UI construction on a download.
    for _, path in ipairs({MENUART, LOGO, KEYART, GARAGE}) do
        cache:GetResourceAsync("Texture2D", path, function(resource)
            if not resource then print("[界面] 主视觉暂未就绪：" .. path) end
        end)
    end
    print("[竞速界面] 钢黑琥珀 / 27款载具 / 独立3D车库 / 混合技能竞速")
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
    self.featureRush = RoadRush(fill({pointerEvents = "none"}))
    self.featureTitle = label("", 15, {126, 255, 218, 255}, {width = "100%", height = 26,
        maxLines = 1, whiteSpace = "nowrap", textAlign = "center", fontWeight = "bold"})
    self.featureHint = label("", 9, WHITE, {width = "100%", height = 18,
        maxLines = 1, whiteSpace = "nowrap", textAlign = "center"})
    self.featurePanel = UI.Panel {position = "absolute", top = "22%", left = "50%", marginLeft = -125,
        width = 250, padding = 6, gap = 1, visible = false, pointerEvents = "none",
        backgroundColor = {7, 26, 27, 210}, borderWidth = 1, borderColor = {83, 231, 196, 165},
        borderRadius = 3, children = {self.featureTitle, self.featureHint}}
    self.weaponTarget = WeaponReticle {position = "absolute", width = 84, height = 84,
        visible = false, pointerEvents = "none", padding = 0, progress = 0, locked = false}
    self.skillButton = button("E · 专属技能",a.skill,true,154)
    self.skillButton:SetStyle({position="absolute",right=76,top=70,height=48,fontSize=12})
    -- 通用提示：无边框、紧贴保护/危险条上方，避免挡住前方视野中心。
    self.messagePanel = UI.Panel {position = "absolute", top = 46, left = "18%", width = "64%",
        padding = 0, pointerEvents = "none", children = {self.message}}
    self.game = UI.Panel(fill({visible = false, pointerEvents = "box-none", children = {
        self.skillButton,
        self.featureRush, self.rankPanel, self.trackMap, self.navPanel, self.instrumentPanel, self.rightTop, self.recoverPanel,
        self.dangerPanel, self.nitroPanel, self.countdownPanel, self.featurePanel, self.weaponTarget, self.messagePanel,
        self.controlLayer}}))
    self.cockpit = RaceInstruments.Dial {position = "absolute", left = 0, top = 0, width = 154, height = 76,
        small = true, visible = false}
    self.cockpitSpeed, self.cockpitGear, self.cockpitRPM = self.cockpit.speedLabel, self.cockpit.gearLabel, self.cockpit.rpmLabel
    self.radioTitle = label("骑行电台", 10, MUTED)
    self.radioToggle = button("播放", a.toggleRadio, false, 70)
end

function HUD:BuildMenu()
    -- 固定入口，不把菜单塞进滚动视口。短横屏只改为两行两列，字号不变。
    local entryStyle = {height = 56, fontSize = 18, minFontSize = 18, fontWeight = "bold", flexShrink = 0}
    local function entry(text, callback, primary)
        local props = {}
        for key, value in pairs(entryStyle) do props[key] = value end
        return button(text, callback, primary, "100%", props)
    end
    self.menuRaceButton = entry("进入赛事", function() self:OpenGarage(true) end, true)
    self.menuPracticeButton = entry("自由练习", function() self:OpenGarage(false) end, false)
    self.menuSettingsButton = entry("操作设置", function() self:OpenSettings() end, false)
    -- 剧情入口只显示锁定状态，不创建外卖场景或触碰历史存档。
    self.menuReturnHost = UI.Panel {width = "100%", height = 56, padding = 0, flexShrink = 0,
        children = {UI.Button{text="剧情模式 · 暂未开放",width="100%",height=56,disabled=true,fontSize=18}}}
    self.menuPrimaryRow = UI.Panel {width = "100%", padding = 0, gap = 10,
        children = {self.menuRaceButton, self.menuPracticeButton}}
    self.menuSecondaryRow = UI.Panel {width = "100%", padding = 0, gap = 10,
        children = {self.menuSettingsButton, self.menuReturnHost}}
    self.menuActions = UI.Column {width = "100%", padding = 0, gap = 10,
        children = {self.menuPrimaryRow, self.menuSecondaryRow}}
    -- 入口仅保留按钮，不用Card整块遮住背景。
    self.menuCard = UI.Column {width = "100%", padding = 0, gap = 0, children = {self.menuActions}}
    self.menuTitle = UI.Panel {width = "100%", height = 210, flexShrink = 0, padding = 0,
        backgroundImage = LOGO, backgroundFit = "contain", pointerEvents = "none"}
    self.menuHeading = UI.Column {width = "100%", padding = 0, gap = 0, flexShrink = 0,
        children = {self.menuTitle}}
    self.menuNote = label("虚拟竞速，请勿现实模仿", 14, MUTED, {width = "100%", height = 28,
        minFontSize = 14, maxLines = 1})
    self.menuColumn = UI.Column {width = 440, height = "100%", padding = 0, gap = 16,
        minWidth = 0, flexShrink = 1, justifyContent = "center",
        children = {self.menuHeading, self.menuCard, self.menuNote}}
    self.menu = UI.Panel(fill({padding = 24, children = {self.menuColumn}}))
    self.menuGrid, self.menuChildCount = false, 0
end

function HUD:LayoutMenu(width, height)
    -- 兼容 main.lua 的 menu:AddChild(returnButton)。搬入固定槽且保留原对象与 onClick，
    -- 避免追加按钮挤占菜单高度，也不触发返回/结算/存档等业务逻辑。
    local children = self.menu:GetChildren()
    if #children ~= self.menuChildCount then
        local appended = {}
        for _, child in ipairs(children) do
            if child._className == "Button" then appended[#appended + 1] = child end
        end
        for _, child in ipairs(appended) do
            local returnButton = child --[[@as Button]]
            returnButton:Remove()
            returnButton:SetText("返回生涯")
            returnButton:SetStyle({width = "100%", height = 56, fontSize = 18, minFontSize = 18,
                fontWeight = "bold", flexShrink = 0, variant = "secondary"})
            self.menuReturnHost:AddChild(returnButton)
        end
        self.menuChildCount = #self.menu:GetChildren()
    end
    -- 预算取安全区内的实际高度；不能让100%高子容器再叠加父级padding。
    local grid = height < 480
    local padding = height < 480 and 12 or (height < 600 and 16 or 24)
    local contentHeight = math.max(0, height - padding * 2)
    local gap = grid and 8 or 10
    local sectionGap = grid and 10 or 16
    local buttonHeight = contentHeight < 260 and 44 or 56
    local actionHeight = grid and buttonHeight * 2 + gap or buttonHeight * 4 + gap * 3
    local noteHeight = height >= 620 and 28 or 0
    local logoHeight = math.max(0, math.min(220, contentHeight - actionHeight
        - sectionGap * (noteHeight > 0 and 2 or 1) - noteHeight))
    local columnWidth = math.max(0, math.min(grid and 560 or 440, width - padding * 2))
    local entryWidth = grid and math.max(0, (columnWidth - gap - 2) * 0.5) or math.max(0,columnWidth - 2)
    self.menuGrid = grid
    self.menu:SetStyle({padding = padding})
    self.menuColumn:SetStyle({width = columnWidth, height = contentHeight, minHeight = 0, gap = sectionGap})
    self.menuHeading:SetHeight(logoHeight)
    self.menuTitle:SetHeight(logoHeight)
    self.menuCard:SetStyle({padding = 0, height = actionHeight, flexShrink = 0})
    self.menuActions:SetStyle({height = actionHeight, gap = gap, flexShrink = 0})
    for _, row in ipairs({self.menuPrimaryRow, self.menuSecondaryRow}) do
        row:SetStyle({flexDirection = grid and "row" or "column", gap = gap,
            height = grid and buttonHeight or buttonHeight * 2 + gap, flexShrink = 0})
        for _, child in ipairs(row:GetChildren()) do
            child:SetStyle({width = entryWidth, height = buttonHeight, minHeight = buttonHeight})
        end
    end
    for _, child in ipairs(self.menuReturnHost:GetChildren()) do
        child:SetStyle({height = buttonHeight, minHeight = buttonHeight})
    end
    self.menuNote:SetVisible(noteHeight > 0)
end

-- 操作编辑器独立成模块，直接复用驾驶按键。
require("ControlEditor").Install(HUD)

-- 只翻整页，不注册滚轮/拖动/滑动。原控件对象和回调留在分页树中。
local fixedPages = RacingTheme.FixedPages

function HUD:BuildGarage()
    local cards = UI.Column {width = "100%", gap = 5, padding = 0}
    -- 排序：已拥有/可驾驶的排前面，其余按价格从低到高，方便玩家看到先能买什么。
    local Profile = require("Profile")
    local ordered = {}
    for i, item in ipairs(Catalog.List) do ordered[i] = item end
    table.sort(ordered, function(a, b)
        local aOwned = Profile.Owns(a.id) or Profile.CanDrive(a.id)
        local bOwned = Profile.Owns(b.id) or Profile.CanDrive(b.id)
        if aOwned ~= bOwned then return aOwned end
        if aOwned then
            local pa, pb = a.price or 0, b.price or 0
            return pa < pb
        end
        local pa, pb = a.price or 0, b.price or 0
        if pa ~= pb then return pa < pb end
        return a.id < b.id
    end)
    for index, item in ipairs(ordered) do
        local v = item
        local badge = label(v.available == false and "准备中 · 不可驾驶" or (v.price and v.price > 0 and ("未拥有 · " .. v.price .. " 金币") or "点按选择"), 9, MUTED,
            {height = 18, maxLines = 1})
        self.vehicleBadges[v.id] = badge
        local card = RacingTheme.Card {width = "100%", minHeight = 79, padding = 10, gap = 2,
            clickable = true, hoverable = true, pointerEvents = "box-only",
            onClick = function() playUI("select"); self:SelectVehicle(v.id, true) end, children = {
                label(string.format("%02d  %s", index, v.name), 12, WHITE, {height = 23, fontWeight = "bold", maxLines = 1}),
                label(SkillNames.DisplayText(v.id, v.tag or v.class or ""), 9, MUTED, {height = 18, maxLines = 1}), badge}}
        self.vehicleCards[v.id] = card; cards:AddChild(card)
    end
    -- 分页必须同步选中新页的车型，而不是只换左侧文字、右侧仍留旧车。
    local pagesFrame, pages = fixedPages({cards}, 5)
    self.garageList, self.garagePages = pagesFrame, pages
    local setPage = pages.SetPage
    pages.SetPage = function(pager, index)
        local before = pager:GetPage()
        setPage(pager, index)
        if pager:GetPage() ~= before and self.screen == "garage" then
            playUI("page")
            self:SyncGaragePage(true)
        end
    end
    self.selectionMode = label("竞速 / 2 圈", 9, AMBER)
    self.vehicleName = label("", 22, WHITE, {fontWeight = "bold", maxLines = 1})
    -- 技能说明四段（被动/主动/持续冷却/短板）长度随车型变化，固定行数会截断。
    -- 放进可滚动容器，文本永远完整可达，不再依赖猜一个够用的 maxLines。
    self.vehicleDescription = label("", 11, MUTED, {width = "100%", whiteSpace = "normal"})
    self.vehicleSpecs = label("", 9, MUTED, {maxLines = 1})
    self.descriptionScroll = UI.ScrollView {width = "100%", flexGrow = 1, flexBasis = 0, minHeight = 48,
        flexShrink = 1, scrollY = true, showScrollbar = false,
        backgroundColor = {8, 12, 16, 176}, borderRadius = 2, padding = 6,
        contentContainerStyle = {padding = 0, paddingRight = 6},
        children = {self.vehicleDescription}}
    -- Full-backdrop overlay, not a separate right-column viewport. This shares the
    -- photo's dimensions even when SafeAreaView adds asymmetric device insets.
    self.preview = GaragePreview.New(fill())
    -- Row 的交叉轴是纵向，alignItems="stretch" 才能给这一列确定高度，
    -- ScrollView 靠它拿到非零视口，而不是靠已经失效的 height="100%"。
    self.previewColumn = UI.Column {flexGrow = 1, flexBasis = 0, flexShrink = 1, minWidth = 0, minHeight = 0,
        padding = 6, gap = 2, pointerEvents = "box-none", children = {
            self.vehicleName, self.descriptionScroll, self.vehicleSpecs}}
    self.garageList:SetStyle({width = 228, height = "100%", flexGrow = 0, flexBasis = "auto", flexShrink = 0})
    self.garageBody = UI.Row {width = "100%", flexGrow = 1, flexBasis = 0, flexShrink = 1, minHeight = 0,
        alignItems = "stretch",
        padding = 0, gap = 12, pointerEvents = "box-none", children = {self.garageList, self.previewColumn}}
    local colors = UI.Row {padding = 0, gap = 6}
    for _, rider in ipairs(RIDERS) do
        local r = rider
        local swatch = UI.Panel {width = 32, height = 32, padding = 5, borderWidth = 1, borderColor = BORDER, borderRadius = 3,
            backgroundColor = {18, 22, 27, 235}, onClick = function() playUI("select"); self:SelectRider(r.id, true) end,
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
        if not item then return end
        local profile,profileError = Profile.GetForDisplay()
        if profileError and not self.careerRace then
            playUI("unavailable")
            self:ShowNotice("竞速进度不可用",profileError.."\n原档已保留，未开启购买或比赛。")
            return
        end
        if item.available == false then
            playUI("unavailable")
            self:ShowNotice("车型尚未开放", "「" .. (item.name or item.id) .. "」的独立驾驶资源尚未交付，请选择其他座驾。")
        elseif not self.careerRace and not Catalog.CanFreeExperience(item.id) and not profile.owned[item.id] and (profile.trials[item.id] or 0)<=0 then
            playUI("click")
            if self.actions.buyVehicle then self.actions.buyVehicle(item.id) end
        elseif self.actions.confirmVehicle then
            playUI("confirm")
            self.actions.confirmVehicle(self.selectedVehicle)
        end
    end, true, 228, {uiSound = "manual"})
    self.coinLabel = label("金币 0", 13, AMBER, {fontWeight = "bold"})
    self.buyButton = button("购买 · 0 金币", function()
        local item = Catalog.Get(self.selectedVehicle)
        if item and self.actions.buyVehicle then self.actions.buyVehicle(item.id) end
    end, false, 150)
    self.buyButton:SetHeight(34)
    self.trialButton = button("看广告 · 体验三局",function()
        if self.actions.watchVehicleAd then self.actions.watchVehicleAd(self.selectedVehicle) end
    end,false,172)
    self.trialButton:SetHeight(34)
    self.garageGMButton = button("GM体验：关",function() self:ToggleGMExperience() end,false,116)
    self.garageGMButton:SetHeight(34)
    self.trackButton = button("赛道 · 环湖公路 ›", function() self:OpenTracks() end, false, 185)
    self.trackButton:SetHeight(36)
    self.garageFooter = RacingTheme.Card {width = "100%", padding = 12, gap = 12, flexDirection = "row", alignItems = "flex-end",
        justifyContent = "space-between", children = {self.riderOptions, self.lapOptions,
            UI.Column {padding = 0, gap = 6, alignItems = "flex-end", children = {
                UI.Row {padding = 0, gap = 8, alignItems = "center", children = {self.garageGMButton, self.coinLabel}},
                UI.Row {padding=0,gap=8,children={self.buyButton,self.trialButton}},
                self.confirmButton}}}}
    self.garage = UI.Panel(fill({visible = false, padding = 18, gap = 12, children = {
        UI.Row {padding = 0, alignItems = "center", justifyContent = "space-between", children = {
            UI.Column {padding = 0, gap = 2, children = {RacingTheme.Kicker("PADDOCK / 车库"),
                label("赛前整备", 21, WHITE, {fontWeight = "bold"}), self.selectionMode}},
            UI.Row {padding = 0, gap = 8, alignItems = "center", children = {self.trackButton, button("返回", function()
                self:SetScreen("menu"); if self.actions.backSelection then self.actions.backSelection() end
            end, false, 70)}}}}, self.garageBody, self.garageFooter}}))
end

local function help()
    return UI.Column {width = "100%", gap = 7, padding = 0, children = {
        PageText("驾驶与竞速", 12, AMBER),
        PageText("左右滑动转向，按住油门加速、刹车制动。点按氮气消耗45点，喷射2.5秒，尾焰与视野冲刺会明显放大。Q/侧键位为翘头，按住抬起前轮。多指互不抢占。", 11, MUTED),
        PageText("键盘 W/S 油刹，A/D 转向，Shift 氮气，C 视角，Q 翘头 / Z 烧胎按住，X 180° / V 360°点按起跳旋转。比赛与练习都可用。混合载具按 E 或右上专属技能键，冷却结束后可再次发动。", 11, MUTED),
        PageText("青色箭头带提供有限加速；橙黄飞坡可绕行，腾空后注意控制落地。", 11, MUTED),
        PageText("翘头自动配合油门；烧胎自动配合油刹。旋转可在平稳行驶至15km/h后辅助起跳，也可在腾空时点按。按键有接收反馈，不满足条件不会假装成功。虚拟竞速，请勿现实模仿。", 10, MUTED)}}
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
    self.careerPauseReturn = button("主菜单", a.menu, false, 160)
    self.careerPauseRestart = button("重新开始", a.restart, false, 130)
    self.resultRestart = button("再赛一次 →", a.restart, true, 160)
    self.resultReturn = button("返回主菜单", a.menu, false, 150)
    -- 结算页激励视频：仅竞速结算可用，点击后按钮变灰防止重复请求。
    self.resultAdBonus = button("看广告 · 双倍金币", function()
        if a.watchResultAd then a.watchResultAd() end
    end, false, 200)
    self.resultAdBonus:SetVisible(false)
    local pauseContent = UI.Column {width = "100%", padding = 0, gap = 10, children = {
        UI.Row {padding = 0, gap = 7, flexWrap = "wrap", children = {self.musicButton, self.effectsButton, self.qualityButton,
            button("按键布局 / 灵敏度", function() self:OpenSettings() end, false, 168)}},
        UI.Row {padding = 0, gap = 10, children = {self.score, self.health}}, self.radioTitle,
        UI.Row {padding = 0, gap = 7, children = {button("上一首", a.previousTrack, false, 90), self.radioToggle,
            button("下一首", a.nextTrack, false, 90)}}, help()}}
    local pauseFrame
    pauseFrame, self.pausePages = fixedPages({pauseContent})
    self.pause = UI.Panel(fill({visible = false, backgroundColor = {5, 8, 11, 225}, padding = 12,
        alignItems = "center", justifyContent = "center", children = {
            RacingTheme.Card {width = "92%", maxWidth = 680, height = "96%", padding = 18, gap = 12, children = {
                    RacingTheme.Kicker("RACE CONTROL / 赛事控制"),
                    UI.Row {padding = 0, justifyContent = "space-between", alignItems = "center", children = {
                        label("暂歇，调整节奏。", 22, WHITE, {fontWeight = "bold"}), button("继续竞速 →", a.pause, true, 140)}},
                    pauseFrame,
                    UI.Row {padding = 0, gap = 8, children = {self.careerPauseRestart, self.careerPauseReturn}}}}}}))
    self.resultTitle = PageText("竞速结算", 24, WHITE)
    self.resultStats = PageText("", 11, MUTED)
    local list = UI.Column {width = "100%", padding = 0, gap = 4}
    for i = 1, 9 do
        local row = label("", 11, MUTED, {width = "100%", height = 26, paddingHorizontal = 8,
            backgroundColor = {25, 31, 37, 160}, borderRadius = 2, visible = false})
        self.resultRows[i] = row; list:AddChild(row)
    end
    local resultFrame
    resultFrame, self.resultPages = fixedPages({UI.Column {width = "100%", padding = 0, gap = 9,
        children = {self.resultTitle, self.resultStats, list}}})
    self.result = UI.Panel(fill({visible = false, backgroundColor = {5, 8, 11, 230}, padding = 12,
        alignItems = "center", justifyContent = "center", children = {
            RacingTheme.Card {width = "92%", maxWidth = 660, height = "96%", padding = 18, gap = 12, children = {
                    RacingTheme.Kicker("FINISH LINE / 比赛结果"), resultFrame,
                    self.resultAdBonus,
                    UI.Row {padding = 0, gap = 8, children = {self.resultRestart, self.resultReturn}}}}}}))
end
---@param available boolean 是否展示激励视频入口
---@param busy? boolean 请求进行中，按钮置灰
---@param text? string 按钮文案
function HUD:SetResultAdOffer(available, busy, text)
    self.resultAdBonus:SetVisible(available == true)
    self.resultAdBonus:SetDisabled(available ~= true or busy == true)
    self.resultAdBonus:SetText(text or "看广告 · 双倍金币")
end

function HUD:SetCareerRace(enabled)
    self.careerRace = enabled == true
    self.careerPauseRestart:SetVisible(not enabled)
    self.careerPauseReturn:SetText(enabled and "返回生涯（保留报名）" or "主菜单")
    self.resultRestart:SetVisible(not enabled)
    self.resultReturn:SetText(enabled and "返回王二狗生涯" or "返回主菜单")
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
        UI.Column {width = "53%", maxWidth = 580, padding = 0, gap = 10, children = {
                label("VEHICLE BRAWL / RACE PREPARATION", 10, AMBER), self.loadTitle, self.loadDetail, self.loadBar, self.loadNumbers,
                label("奇葩载具同场，专属技能抢第一。", 11, MUTED), self.retry, self.enterRide}}}}))
end

-- 预热当前页、下一页和上一页，提交顺序就是后台优先级；不读取人物资源。
function HUD:SyncGaragePage(selectFirst)
    if self.screen ~= "garage" or self.portraitActive then return end
    local pager = self.garagePages
    local pageIndex = pager:GetPage()
    local ids, seen = {}, {}
    local function collect(index)
        for _, unit in ipairs(pager.pages[index] or {}) do
            for _, vehicle in ipairs(Catalog.List) do
                local card = self.vehicleCards[vehicle.id]
                if not seen[vehicle.id] and (unit.source == card or unit.members[card]) then
                    seen[vehicle.id] = true
                    ids[#ids + 1] = vehicle.id
                end
            end
        end
    end
    collect(pageIndex)
    if selectFirst and ids[1] then self:SelectVehicle(ids[1], true) end
    collect(pageIndex + 1)
    collect(pageIndex - 1)
    self.preview:Prewarm(ids)
end

function HUD:OpenGarage(challenge)
    self.challenge = challenge == true
    self:SelectLaps(self.selectedLaps, false)
    self:SetScreen("garage")
    if self.actions.start then self.actions.start(self.challenge) end
end
function HUD:ToggleGMExperience()
    if self.portraitActive or self:IsModalOpen() or UI.GetTopOverlay() then return end
    if self.screen=="settings" then
        if self:SettingsInputBlocked() then return end
        self:CancelSettingsInput()
    elseif self.screen~="garage" then return end
    if self.actions.toggleGMFreeExperience then self.actions.toggleGMFreeExperience() end
    self:RefreshGMButtons()
    if self.screen=="settings" then
        self.settingsHint:SetText(Catalog.IsGMFreeExperience() and "GM免费体验已开 · 正式车型免购买免扣次 · 重启关闭"
            or "GM免费体验已关 · 原购买与试驾权益不变")
    end
end
function HUD:RefreshGMButtons()
    local text=Catalog.IsGMFreeExperience() and "GM体验：开" or "GM体验：关"
    if self.garageGMButton then self.garageGMButton:SetText(text) end
    if self.gmFreeButton then self.gmFreeButton:SetText(text) end
end
function HUD:SelectVehicle(id, notify)
    self:RefreshGMButtons()
    local item = Catalog.Get(id)
    if not item then return end
    local profile,profileError = Profile.GetForDisplay()
    self.selectedVehicle = id
    for _, v in ipairs(Catalog.List) do
        local selected = v.id == id
        local owned = profile.owned[v.id] == true
        self.vehicleCards[v.id]:SetStyle({borderColor = selected and C.cyan or BORDER,
            backgroundGradient = RacingTheme.Gradient(selected and {39, 57, 61, 245} or {30, 37, 43, 235},
                selected and {20, 33, 39, 245} or {17, 21, 26, 235})})
        self.vehicleBadges[v.id]:SetText(v.available == false and "准备中 · 不可驾驶"
        or (not profileError and Catalog.CanFreeExperience(v.id) and "GM 免费体验 · 不扣次")
        or ((profile.trials[v.id] or 0)>0 and ("试驾剩余 "..profile.trials[v.id].." 局"))
            or (not owned and ("未拥有 · " .. tostring(v.price or 0) .. " 金币"))
            or (selected and "已选中" or "点按选择"))
        self.vehicleBadges[v.id]:SetFontColor(not owned and (selected and AMBER or MUTED) or (selected and AMBER or MUTED))
    end
    self.vehicleName:SetText(item.name or id)
    local skill = MixedRace.GetSkill(id)
    local skillText = skill and string.format("\n主动：%s · %s\n持续 %.1fs / 冷却 %.0fs", SkillNames.Active(id),
        SkillNames.DisplayText(id, skill.description), skill.duration, skill.cooldown) or ""
    local description = item.odd and ("被动："..SkillNames.Passive(id).." · "..(item.passiveDescription or "")..skillText.."\n短板："..(item.weakness or ""))
        or ((item.description or item.tag or "")..skillText)
    self.vehicleDescription:SetText(SkillNames.DisplayText(id, description))
    self.vehicleSpecs:SetText(string.format("极速 %s km/h  /  加速 %d  /  操控 %d  /  耐久 %d",
        tostring(item.speedStat or item.speed or "—"), math.floor(item.acceleration or 0),
        math.floor(item.handling or 0), math.floor(item.durability or 0)))
    local owned = profile.owned[id] == true
    local trials = profile.trials[id] or 0
    local free = not profileError and Catalog.CanFreeExperience(id)
    self.trialButton:SetVisible(not profileError and not free and not owned and item.available~=false)
    self.trialButton:SetDisabled(item.available==false or require("RewardedAds").IsBusy())
    local price = item.price or 0
    self.coinLabel:SetText(profileError and "竞速进度不可用 · 原档已保留" or "金币 " .. tostring(profile.coins))
    self.buyButton:SetVisible(not profileError and not free and not owned and price > 0 and item.available~=false)
    self.buyButton:SetText("购买 · " .. tostring(price) .. " 金币")
    self.buyButton:SetDisabled(profileError~=nil or item.available==false)
    self.confirmButton:SetDisabled(item.available==false or (profileError~=nil and not self.careerRace))
    self.confirmButton:SetText(profileError and not self.careerRace and "进度读取失败 · 暂不可出发" or item.available == false and "独立车型准备中"
        or (free and "GM 免费体验 · 出发 →") or (not owned and trials<=0 and ("未拥有 · " .. tostring(price) .. " 金币")) or (not owned and ("试驾剩余 "..trials.." 局 · 出发 →")) or "确认座驾 · 出发 →")
    if self.screen == "garage" then self.preview:Select(id, item.available) end
    if notify and self.actions.selectVehicle then self.actions.selectVehicle(id) end
end
function HUD:SelectRider(id, notify)
    if not self.riderButtons[id] then return end
    local profile = Profile.GetForDisplay()
    local owned = profile.ownedRiders[id] == true
    if not owned and notify and self.actions.buyRider then
        -- 未拥有时交给主流程购买；买成功后由主流程再次调用本函数同步画面。
        self.actions.buyRider(id)
        return
    end
    self.selectedRider = id
    for _, rider in ipairs(RIDERS) do if rider.id == id then self.preview:SetRiderColor(rider.color) end end
    for colorId, swatch in pairs(self.riderButtons) do
        local selectable = profile.ownedRiders[colorId] == true
        swatch:SetStyle({borderColor = colorId == id and AMBER or (selectable and BORDER or {92, 74, 52, 200}),
            borderWidth = colorId == id and 2 or 1,
            opacity = selectable and 1 or 0.55})
    end
    if notify and self.actions.selectRider then self.actions.selectRider(id) end
end
-- 购买成功后刷新配色与金币
function HUD:RefreshOwnership()
    local profile,profileError = Profile.GetForDisplay()
    self.trackSignature = ""
    self:RefreshTrackCards()
    self.coinLabel:SetText(profileError and "竞速进度不可用 · 原档已保留" or "金币 " .. tostring(profile.coins))
    for colorId, swatch in pairs(self.riderButtons) do
        local selectable = profile.ownedRiders[colorId] == true
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
    if self:IsModalOpen() then self:CloseModal() end
    local oldScreen = self.screen
    self.screen = screen
    if oldScreen == "garage" and screen ~= "garage" then
        self.preview:Dispose()
        self.garageWarmSignature = ""
    end
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
    local menuArt = screen == "menu" or (editing and self.settingsReturn == "menu")
    self.menuBackdrop:SetVisible(menuArt)
    self.keyartBackdrop:SetVisible(not menuArt and screen ~= "garage")
    self.garageBackdrop:SetVisible(screen == "garage")
    self.cockpit:SetVisible(false); self.enterRide:SetVisible(false)
    local riding = screen == "ride"
    if not riding then
        self.featureRush.power = 0
        self.featurePanel:SetVisible(false)
    end
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
        if portrait then
            self.cockpit:SetVisible(false)
            self.preview:Dispose()
            self.garageWarmSignature = ""
        elseif self.screen == "garage" then
            local item = Catalog.Get(self.selectedVehicle); self.preview:Select(self.selectedVehicle, item and item.available)
        end
    end
    self:LayoutResponsive()
end
function HUD:LayoutResponsive()
    local vw, vh = UI.GetViewportSize()
    local insets = UI.GetSafeAreaInsets()
    local safe = self.safeContent:GetAbsoluteLayout()
    local w = safe.w > 0 and safe.w or vw - insets.left - insets.right
    local h = safe.h > 0 and safe.h or vh - insets.top - insets.bottom
    if w ~= self.layoutWidth or h ~= self.layoutHeight or #self.menu:GetChildren() ~= self.menuChildCount then
        self:LayoutMenu(w, h)
    end
    if self.screen == "garage" and not self.portraitActive then
        local signature = tostring(self.garagePages:GetPage()) .. "/" .. tostring(self.garagePages:GetPageCount())
        if self.garageWarmSignature ~= signature then
            self.garageWarmSignature = signature
            self:SyncGaragePage(false)
        end
    end
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
    self.garage:SetStyle({padding = compact and 10 or 20})
    self.garageList:SetWidth(compact and 184 or 228)
    self.confirmButton:SetWidth(compact and 190 or 228)
    self.garageFooter:SetStyle({gap = compact and 9 or 16,flexWrap="wrap"})
    self.buyButton:SetWidth(compact and 132 or 150)
    self.trialButton:SetWidth(compact and 150 or 172)
    self.trackMap:SetStyle({width = compact and 126 or 152, height = compact and 95 or 122, top = compact and 77 or 89})
    self.rankPanel:SetWidth(compact and 126 or 152)
    self.navPanel:SetStyle({left = compact and 146 or 178, width = compact and 112 or 126})
    self.dangerPanel:SetStyle({top = compact and 85 or 8, width = compact and 208 or 244, marginLeft = compact and -104 or -122})
    self.messagePanel:SetStyle({top = compact and 126 or 46})
    self.instrumentPanel:SetStyle({width = compact and 198 or 228, height = compact and 98 or 112, marginLeft = compact and -99 or -114})
    self.nitroPanel:SetStyle({bottom = compact and 118 or 132, width = compact and 178 or 196, marginLeft = compact and -89 or -98})
    self:LayoutTracks(w, h)
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

function HUD:UpdateSkillFeedback(sim)
    local skill = MixedRace.GetSkill(sim.vehicleId)
    self.skillButton:SetVisible(skill ~= nil and self.screen == "ride")
    if not skill then return end
    local active = math.max(0, skill.odd and (sim.oddActive or 0) or (sim.motorcycleActive or 0))
    local cd = math.max(0, skill.odd and (sim.oddCooldown or 0) or (sim.motorcycleCooldown or 0))
    local disrupted = (sim.oddDisrupt or 0) > 0
    local blocked = sim.paused == true or sim.finished == true or sim.wrecked == true
        or (not skill.odd and (sim.airborne == true or sim.braking == true or sim.burnout == true))
    local status, tint, background = "就绪 · E", AMBER, {49, 38, 23, 240}
    -- 普通技能与混合odd*分别读取自身计时，氮气/加速带不触发技能外观。
    if active > 0 then
        local phase=not skill.odd and sim.motorcyclePhase or "active"
        local prefix=phase=="charge" and "蓄力" or phase=="guard" and "单次格挡" or phase=="suppressed" and "暂时抑制" or "持续"
        status, tint, background = string.format("%s %.1fs", prefix, active), C.cyan, {18, 58, 65, 245}
    elseif disrupted then
        status, tint, background = string.format("受干扰 %.1fs", sim.oddDisrupt), RED, {65, 28, 25, 245}
    elseif cd > 0 then
        status, tint, background = string.format("冷却 %.1fs", cd), MUTED, {28, 34, 40, 240}
    elseif blocked then
        status, tint, background = "暂不可用", RED, {65, 28, 25, 245}
    end
    local buttonText = SkillNames.Active(sim.vehicleId) .. " · " .. status
    if self.skillStatus ~= buttonText then self.skillButton:SetText(buttonText); self.skillStatus = buttonText end
    self.skillButton:SetDisabled(active > 0 or cd > 0 or disrupted or blocked)
    -- 禁用只阻止再次施放，不能把“正在生效”变成灰色不可读状态。
    local style = active > 0 and "active" or ((disrupted or blocked) and "blocked" or (cd > 0 and "cooldown" or "ready"))
    if self.skillStyle ~= style then
        self.skillStyle = style
        self.skillButton:SetStyle({textColor = tint, disabledTextColor = tint, borderColor = tint,
            backgroundColor = background, disabledBackgroundColor = background,
            backgroundGradient = false, disabledBackgroundGradient = false,
            variantBackgroundGradient = {}, variantDisabledBackgroundGradient = {},
            borderWidth = active > 0 and 2 or 1})
    end
end

function HUD:UpdateWeaponTarget(sim, camera)
    if not self.weaponTarget then return end
    local id = sim and sim.vehicleId or ""
    local homing = id == "tank" or id == "helicopter"
    local target = sim and sim.oddLockTarget
    local show = homing and target ~= nil and sim.oddLockPending == true
        and self.screen == "ride" and camera ~= nil
    if not show then self.weaponTarget:SetVisible(false); return end
    local screen = camera:WorldToScreenPoint(Vector3(target.x, target.y + (target.driveSim and target.driveSim.oddAltitude or 0) + 1.2, target.z))
    local scale = UI.GetScale()
    local width, height = graphics:GetWidth() / scale, graphics:GetHeight() / scale
    local margin = 48
    local edge = screen.x <= 0 or screen.x >= 1 or screen.y <= 0 or screen.y >= 1
    local x = math.max(margin, math.min(width - margin, screen.x * width))
    local y = math.max(margin, math.min(height - margin, screen.y * height))
    local duration = math.max(.01, sim.oddLockDuration or .55)
    local progress = math.max(0, math.min(1, 1 - (sim.oddLockTimer or duration) / duration))
    self.weaponTarget.props.progress = progress
    self.weaponTarget.props.locked = progress >= .999
    self.weaponTarget.props.edge = edge
    self.weaponTarget:SetStyle({left = x - 42, top = y - 42})
    self.weaponTarget:SetVisible(true)
end

function HUD:UpdateFeatureFeedback(sim)
    local state = sim.featureState or {}
    local driving = self.screen == "ride"
    local power = driving and math.max(0, math.min(1, state.feedbackPower or 0)) or 0
    self.featureRush.power, self.featureRush.phase = (state.lastGain or 0) > 0 and power or 0, sim.elapsed or 0
    if not driving then self.featurePanel:SetVisible(false); return end
    local motorcycle=(sim.motorcycleSkillResultTimer or 0)>0 and (sim.motorcycleSkillResult or "")~=""
    local result = motorcycle and (sim.motorcycleSkillResult or "") or (sim.oddSkillResult or "")
    local resultTimer=motorcycle and (sim.motorcycleSkillResultTimer or 0) or (sim.oddSkillResultTimer or 0)
    if resultTimer > 0 and result ~= "" and not isWeaponFeedback(result) then
        -- 复用现有反馈框，结果来自权威仿真；不靠技能计时/boost猜测命中。
        local skill = MixedRace.GetSkill(sim.vehicleId)
        local title = skill and SkillNames.Active(sim.vehicleId) or "技能交锋"
        local color = C.cyan
        if motorcycle and result:find("护盾已消耗",1,true) then title,color=SkillNames.Active(sim.vehicleId).." · 护盾已消耗",AMBER
        elseif not motorcycle and result:find("盾", 1, true) then title, color = "攻击被护盾挡住", AMBER
        elseif result:find("无", 1, true) then title, color = "前方无有效目标", RED
        elseif result:find("未命中", 1, true) or result:find("落空", 1, true) then title, color = "攻击未命中", RED
        elseif result:find("命中", 1, true) then title, color = "技能命中 · 对手失衡", GREEN
        elseif result:find("发射", 1, true) then title = sim.vehicleId == "helicopter" and "导弹已发射" or "技能已发射"
        elseif result:find("发动", 1, true) then title = title .. " · 已发动" end
        self.featureTitle:SetText(title)
        self.featureTitle:SetFontColor(color)
        self.featureHint:SetText(SkillNames.DisplayText(sim.vehicleId, result))
        self.featurePanel:SetStyle({borderColor = color, backgroundColor = {12, 23, 30, 240}})
        self.featurePanel:SetVisible(true)
        return
    end
    self.featurePanel:SetStyle({borderColor = {83, 231, 196, 165}, backgroundColor = {7, 26, 27, 210}})
    if power > 0 and (state.lastGain or 0) > 0 then
        self.featureTitle:SetText("加速带 · 冲刺")
        self.featureTitle:SetFontColor({126, 255, 218, 255})
        self.featureHint:SetText(string.format("+%.0f km/h  ·  不消耗氮气", state.lastGain * 3.6))
        self.featurePanel:SetVisible(true)
        return
    end
    if sim.airborne and (sim.airTime or 0) > 0.12 then
        self.featureTitle:SetText("腾空飞跃")
        self.featureTitle:SetFontColor(AMBER)
        self.featureHint:SetText("保持车身稳定 · 准备落地")
        self.featurePanel:SetVisible(true)
        return
    end
    local map = sim.landscape
    local nearest, distance = nil, math.huge
    if map and (map.RouteLength or 0) > 0 then
        for _, feature in ipairs(map.Features or {}) do
            local ahead = (feature.s - (sim.roadS or 0)) % map.RouteLength
            local facing = math.cos(math.rad((sim.heading or 0) - feature.yaw)) > 0.6
            if feature.kind == "ramp" and facing and ahead > 0 and ahead < 165 and ahead < distance then
                nearest, distance = feature, ahead
            end
        end
    end
    if nearest then
        self.featureTitle:SetText(string.format("飞坡  %.0f m  %s", distance, nearest.lateral < 0 and "↖" or "↗"))
        self.featureTitle:SetFontColor(AMBER)
        self.featureHint:SetText("对准黄箭头可飞跃 · 旁侧可绕行")
    end
    self.featurePanel:SetVisible(nearest ~= nil)
end

-- Existing main update signature remains valid. Preview animation runs through its Widget Update,
-- including before the driving scene exists; leaving garage disposes all render targets immediately.
function HUD:Update(dt, sim, firstPerson)
    self.firstPerson = firstPerson == true
    self:UpdateSkillFeedback(sim)
    self:UpdateFeatureFeedback(sim)
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
    self.message:SetText((sim.messageTimer or 0) > 0 and (not isWeaponFeedback(sim.message)) and SkillNames.DisplayText(sim.vehicleId, sim.message or "") or "")
    self.camera:SetText(firstPerson and "头盔视角" or "追尾视角")
    self.rpm:SetValue(math.min(1, (sim.rpm or 1200) / ((sim.vehicle and sim.vehicle.redline) or 11000)))
    self.rpmNumber:SetText(string.format("%.0f rpm", sim.rpm or 1200))
    self.region:SetText(sim.regionName or "环湖公路"); self.target:SetText(sim.goalName or "")
    self:RefreshRace()
    -- 特技按钮按真实能力显示：电动车是两轮车辆，可翘头/烧胎/空中旋转；
    -- 坦克、直升机等非两轮载具没有这些地面特技，隐藏避免按了没反应。
    local vehicleId = sim.vehicleId or ""
    local mixedSpec = require("MixedVehicles").Get(vehicleId)
    local twoWheeler = mixedSpec == nil or vehicleId == "ebike" or vehicleId == "skateboard"
    for _, key in ipairs({"wheelie", "burnout"}) do
        local widget = self.controlWidgets[key]
        if widget then widget:SetVisible(twoWheeler) end
    end
    for _, key in ipairs({"spin180", "spin360"}) do
        local widget = self.controlWidgets[key]
        if widget then widget:SetVisible(true) end
    end
    if not twoWheeler then
        self.controls:SetActionState("wheelie", {state = "ready", detail = ""})
        self.controls:SetActionState("burnout", {state = "ready", detail = ""})
    end
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
    local summary = (result.reason or "") .. string.format("\n排名 %02d / %02d    用时 %s", math.floor(result.position or race.position or 1), #rows, clock(result.elapsed or race.elapsed or 0))
    self.resultStats:SetText(summary .. (self.resultRewardText and "\n" .. self.resultRewardText or ""))
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
function HUD:SetResultReward(text)
    self.resultRewardText = text
    if self.screen == "result" and self.hasRace then self:RefreshResults() end
end
function HUD:ShowResult(sim)
    self.resultRewardText = nil
    self:SetScreen("result")
    if self.hasRace then self:RefreshResults(); return end
    for _, row in ipairs(self.resultRows) do row:SetVisible(false) end
    self.resultTitle:SetText("自由练习记录")
    self.resultStats:SetText(string.format("用时 %s\n里程 %.2f km    最高时速 %.0f km/h\n超车 %d    剩余车况 %.0f%%",
        clock(sim.elapsed), (sim.distance or 0) / 1000, sim.topSpeed or 0, sim.overtakes or 0, sim.health or 100))
end
function HUD:Dispose()
    self:CloseModal()
    self.controls:SetEnabled(false)
    self.preview:Dispose()
end

return HUD
