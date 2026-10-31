-- Racing instruments and route graphics live inside the UI render tree.
-- UI owns the frame, fonts, clipping, scale and DPR; no standalone NanoVG frame.
local UI = require("urhox-libs/UI")
local Instruments = {}
local WHITE, MUTED = {237, 244, 247, 255}, {139, 157, 169, 255}
local CYAN, AMBER = {91, 220, 233, 255}, {236, 174, 79, 255}

local function text(value, size, color, props)
    props = props or {}
    props.text, props.fontSize, props.fontColor = value, size, color
    props.pointerEvents, props.padding, props.lineHeight = "none", 0, 1
    return UI.Label(props)
end

---@class RaceDial : Widget
local Dial = UI.Widget:Extend("PursuitRaceDial")
function Dial:Init(props)
    props = props or {}
    props.padding, props.pointerEvents = 0, "none"
    UI.Widget.Init(self, props)
    self.ratio, self.displayRatio, self.elapsed = 0.0, 0.0, 0.0
    self.isSmall = props.small == true
    self.speedText, self.gearText, self.rpmText = "000", "N", "1.2"
    self.speedLabel = text("000", self.isSmall and 26 or 42, WHITE,
        {position = "absolute", left = "8%", top = "26%", width = "59%", height = "53%", fontWeight = "bold", textAlign = "right"})
    self.gearLabel = text("N", self.isSmall and 25 or 35, AMBER,
        {position = "absolute", left = "74%", top = "30%", width = "19%", height = "43%", textAlign = "center", fontWeight = "bold"})
    self.rpmLabel = text("1.2", self.isSmall and 7 or 9, MUTED,
        {position = "absolute", left = "8%", bottom = "6%", width = "37%", textAlign = "left"})
    self:AddChild(self.speedLabel); self:AddChild(self.gearLabel); self:AddChild(self.rpmLabel)
    self:AddChild(text("km/h", self.isSmall and 7 or 9, MUTED,
        {position = "absolute", left = "46%", bottom = "6%", width = "24%", textAlign = "center"}))
    self:AddChild(text("档位", self.isSmall and 6 or 8, MUTED,
        {position = "absolute", left = "73%", bottom = "8%", width = "20%", textAlign = "center"}))
end
function Dial:SetTelemetry(speed, gear, rpm, redline)
    local speedText = string.format("%03d", math.max(0, math.floor(speed or 0)))
    local gearText = gear == 0 and "N" or tostring(gear or 1)
    local rpmText = string.format("%.1f ×1000", (rpm or 1200) / 1000)
    if speedText ~= self.speedText then self.speedLabel:SetText(speedText); self.speedText = speedText end
    if gearText ~= self.gearText then self.gearLabel:SetText(gearText); self.gearText = gearText end
    if rpmText ~= self.rpmText then self.rpmLabel:SetText(rpmText); self.rpmText = rpmText end
    self.ratio = math.max(0, math.min(1, (rpm or 1200) / math.max(1, redline or 12500)))
end
function Dial:Update(dt)
    self.elapsed = self.elapsed + dt
    self.displayRatio = self.displayRatio + (self.ratio - self.displayRatio) * math.min(1, dt * 16)
end
function Dial:Render(vg)
    local l = self:GetAbsoluteLayout()
    if l.w < 1 or l.h < 1 then return end
    local x, y, w, h = l.x, l.y, l.w, l.h
    nvgSave(vg)
    nvgBeginPath(vg)
    nvgMoveTo(vg, x + 14, y); nvgLineTo(vg, x + w - 4, y); nvgLineTo(vg, x + w, y + 4)
    nvgLineTo(vg, x + w - 10, y + h); nvgLineTo(vg, x + 1, y + h); nvgLineTo(vg, x, y + 16); nvgClosePath(vg)
    nvgFillPaint(vg, nvgLinearGradient(vg, x, y, x, y + h, nvgRGBA(27, 41, 51, 245), nvgRGBA(5, 11, 17, 245)))
    nvgFill(vg); nvgStrokeColor(vg, nvgRGBA(126, 159, 176, 145)); nvgStrokeWidth(vg, 1); nvgStroke(vg)
    -- Fine carbon weave, deliberately subtle so the telemetry stays dominant.
    for i = 1, math.floor(w / 9) do
        nvgBeginPath(vg); nvgMoveTo(vg, x + i * 9, y + h * 0.29)
        nvgLineTo(vg, x + i * 9 - 9, y + h * 0.91)
        nvgStrokeColor(vg, nvgRGBA(102, 128, 142, 13)); nvgStrokeWidth(vg, 1); nvgStroke(vg)
    end
    local startX, top, stripW = x + w * 0.08, y + h * 0.12, w * 0.84
    for i = 1, 24 do
        local lit = i / 24 <= self.displayRatio
        local red = i >= 21
        local c = red and {242, 83, 70} or (i >= 18 and {236, 174, 79} or {91, 220, 233})
        nvgBeginPath(vg); nvgRoundedRect(vg, startX + (i - 1) * stripW / 24, top, stripW / 24 - 2, h * 0.095, 1)
        nvgFillColor(vg, lit and nvgRGBA(c[1], c[2], c[3], 255) or nvgRGBA(104, 130, 145, 46)); nvgFill(vg)
    end
    -- Gear well and a bright RPM/redline edge replace the previous generic text box.
    nvgBeginPath(vg); nvgRoundedRect(vg, x + w * 0.73, y + h * 0.28, w * 0.21, h * 0.46, 3)
    nvgFillColor(vg, nvgRGBA(3, 9, 14, 215)); nvgFill(vg)
    nvgStrokeColor(vg, nvgRGBA(123, 151, 162, 90)); nvgStroke(vg)
    nvgBeginPath(vg); nvgMoveTo(vg, x + 10, y + h - 2); nvgLineTo(vg, x + w * 0.69, y + h - 2)
    local shift = self.ratio > 0.90 and math.sin(self.elapsed * 24) > 0
    nvgStrokeColor(vg, shift and nvgRGBA(250, 83, 65, 255) or nvgRGBA(CYAN[1], CYAN[2], CYAN[3], 170))
    nvgStrokeWidth(vg, 2); nvgStroke(vg)
    nvgRestore(vg)
end
Instruments.Dial = Dial

-- Preview points must come from Tracks.List().preview, the same curve as gameplay.
---@class RouteGraphic : Widget
local Route = UI.Widget:Extend("PursuitRouteGraphic")
function Route:Init(props)
    UI.Widget.Init(self, props)
    self.points, self.accent = {}, AMBER
    self.minX, self.minZ, self.spanX, self.spanZ = 0.0, 0.0, 1.0, 1.0
end
function Route:SetRoute(points, accent)
    self.points, self.accent = points or {}, accent or AMBER
    local minX, minZ, maxX, maxZ = math.huge, math.huge, -math.huge, -math.huge
    for _, p in ipairs(self.points) do
        minX, minZ, maxX, maxZ = math.min(minX, p.x), math.min(minZ, p.z), math.max(maxX, p.x), math.max(maxZ, p.z)
    end
    if #self.points > 0 then
        self.minX, self.minZ = minX, minZ
        self.spanX, self.spanZ = math.max(1, maxX - minX), math.max(1, maxZ - minZ)
    end
end
function Route:Render(vg)
    local l = self:GetAbsoluteLayout()
    self:RenderFullBackground(vg)
    if #self.points < 2 or l.w < 12 or l.h < 12 then return end
    local c, pad = self.accent, 13
    nvgSave(vg); nvgIntersectScissor(vg, l.x, l.y, l.w, l.h)
    -- Blueprint grid is decorative; the outlined course is always actual route data.
    for i = 1, 5 do
        nvgBeginPath(vg); nvgMoveTo(vg, l.x + l.w * i / 6, l.y); nvgLineTo(vg, l.x + l.w * i / 6, l.y + l.h)
        nvgStrokeWidth(vg, 1); nvgStrokeColor(vg, nvgRGBA(c[1], c[2], c[3], 13)); nvgStroke(vg)
    end
    local scale = math.min((l.w - pad * 2) / self.spanX, (l.h - pad * 2) / self.spanZ)
    local x, y = l.x + (l.w - self.spanX * scale) * 0.5, l.y + (l.h - self.spanZ * scale) * 0.5
    nvgBeginPath(vg)
    for i, p in ipairs(self.points) do
        local px, py = x + (p.x - self.minX) * scale, y + (self.spanZ - p.z + self.minZ) * scale
        if i == 1 then nvgMoveTo(vg, px, py) else nvgLineTo(vg, px, py) end
    end
    nvgStrokeWidth(vg, 7); nvgStrokeColor(vg, nvgRGBA(c[1], c[2], c[3], 22)); nvgStroke(vg)
    nvgStrokeWidth(vg, 2.4); nvgStrokeColor(vg, nvgRGBA(c[1], c[2], c[3], 245)); nvgStroke(vg)
    local p = self.points[1]
    local sx, sy = x + (p.x - self.minX) * scale, y + (self.spanZ - p.z + self.minZ) * scale
    nvgBeginPath(vg); nvgCircle(vg, sx, sy, 4)
    nvgFillColor(vg, nvgRGBA(241, 246, 248, 255)); nvgFill(vg)
    nvgStrokeWidth(vg, 2); nvgStrokeColor(vg, nvgRGBA(9, 14, 20, 255)); nvgStroke(vg)
    nvgRestore(vg)
end
Instruments.Route = Route
return Instruments
