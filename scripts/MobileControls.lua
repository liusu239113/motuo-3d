-- 每个操作独立持有指针：转向、油门、刹车和特技互不抢占。
-- clutch/shift 字段只保留给旧入口过渡，不再创建对应可见控件。
local UI = require("urhox-libs/UI")
local RacingTheme = require("RacingTheme")
local SkillNames = require("SkillNames")
---@class MobileControls
---@field ResetLook fun(self:MobileControls)
---@field ConsumeLook fun(self:MobileControls):number,number
local Controls = {}
Controls.__index = Controls
local HOLDS = {"gas", "brake", "nitro", "clutch", "wheelie", "burnout"}
local PULSES = {"spin180", "spin360", "shiftUp", "shiftDown"}
local AMBER = {224, 164, 75, 255}
Controls.Images = {
    brake = "image/pursuit_brake_control_20261027183810.png",
    gas = "image/pursuit_throttle_control_20261027183808.png",
    nitro = "image/pursuit_nitro_control_20261027183806.png",
}
Controls.Resources = {Controls.Images.brake, Controls.Images.gas, Controls.Images.nitro}
Controls.ResourceTypes = {}
for _, path in ipairs(Controls.Resources) do Controls.ResourceTypes[path] = "Texture2D" end
-- 使用控件实际宽度归一化，不随分辨率/DPR改变手感；外圈仍保留完整左右满舵。
local STEER_TRAVEL, STEER_DEADZONE = 0.42, 0.12
-- 设置面板可调的灵敏度；默认值与旧手感完全一致。
local steerSensitivity, deadzone = 1.0, 0.12

function Controls.New()
    local self = setmetatable({}, Controls)
    self:Init()
    return self
end

function Controls:Init()
    self.enabled = false
    self.steer, self.throttle = 0.0, 0.0
    self.gas, self.brake, self.nitro, self.clutch, self.wheelie, self.burnout = false, false, false, false, false, false
    self.spin180, self.spin360, self.shiftUp, self.shiftDown = false, false, false, false
    self.pointers = {steer = -1, gas = -1, brake = -1, nitro = -1, clutch = -1, wheelie = -1,
        burnout = -1, spin180 = -1, spin360 = -1, shiftUp = -1, shiftDown = -1}
    ---@type table<string, Widget>
    self.widgets = {}
    ---@type table<string, boolean>
    self.visualPressed = {}
    self.visualSteer, self.visualSteeringWidth, self.visualSteeringHeld = math.huge, 0, false
    self.compactInitialized, self.compact = false, false
    self.steeringWidth = 206
    ---@type table<string, Label>
    self.captions = {}
    ---@type table<string, Label>
    self.details = {}
    ---@type table<string, table>
    self.actionStates = {}
    self.lineStyle = false
    self.flashes, self.visualKeys = {}, {}
    self.nitroQueued = false
    self.lookDx, self.lookDy, self.lookPointer = 0.0, 0.0, -1
    self.lookLastX, self.lookLastY = 0.0, 0.0
end

function Controls:Reset()
    self.steer, self.throttle = 0.0, 0.0
    self.flashes, self.nitroQueued = {}, false
    self:ResetLook()
    for key in pairs(self.pointers) do
        self.pointers[key] = -1
        if key ~= "steer" then self[key] = false end
    end
    self:Refresh()
end

-- LOOK只记录逻辑像素增量；相机模块决定角度和俯仰限制。
function Controls:ResetLook()
    self.lookDx, self.lookDy, self.lookPointer = 0.0, 0.0, -1
    self.lookLastX, self.lookLastY = 0.0, 0.0
end

function Controls:BeginLook(pointerId, x, y)
    if not self.enabled or pointerId < 0 or self.lookPointer ~= -1 then return false end
    for key, owner in pairs(self.pointers) do
        if owner == pointerId then return false end
    end
    self.lookPointer, self.lookLastX, self.lookLastY = pointerId, x, y
    return true
end

function Controls:MoveLook(pointerId, x, y)
    if pointerId ~= self.lookPointer then return end
    self.lookDx = self.lookDx + x - self.lookLastX
    self.lookDy = self.lookDy + y - self.lookLastY
    self.lookLastX, self.lookLastY = x, y
end

function Controls:EndLook(pointerId, cancelled)
    if pointerId ~= self.lookPointer then return end
    self.lookPointer = -1
    if cancelled then self.lookDx, self.lookDy = 0.0, 0.0 end
end

function Controls:ConsumeLook()
    local dx, dy = self.lookDx, self.lookDy
    self.lookDx, self.lookDy = 0.0, 0.0
    return dx, dy
end

-- 应用玩家保存的灵敏度与死区；保存值本身已做上下限约束。
---@param sensitivity number
---@param dead number
function Controls:SetFeel(sensitivity, dead)
    steerSensitivity = math.max(0.4, math.min(1.8, tonumber(sensitivity) or 1.0))
    deadzone = math.max(0.01, math.min(0.34, tonumber(dead) or 0.12))
end

-- 编辑和驾驶共享同一组实际尺寸，不再靠视觉 transform 缩放命中区。
function Controls:ButtonSize(key, scheme)
    local sizes = {
        steering = {self.steeringWidth, 96}, gas = {self.compact and 82 or 92, self.compact and 94 or 106},
        brake = {self.compact and 72 or 76, self.compact and 86 or 90},
        nitro = {self.compact and 74 or 80, self.compact and 78 or 84},
    }
    local size = sizes[key] or {self.compact and 62 or 68, self.compact and 64 or 70}
    local scale = scheme.scale[key] or 1
    return size[1] * scale, size[2] * scale
end

---@param editor table?
function Controls:SetEditor(editor)
    self:Reset()
    self.editor = editor
end

-- 位置始终表示安全区内按钮中心的比例；编辑直接操作这些实战控件。
---@param scheme ControlScheme
---@param width number
---@param height number
function Controls:ApplyScheme(scheme, width, height)
    self.scheme = scheme
    local w, h = math.max(1, width), math.max(1, height)
    for key, p in pairs(scheme.pos) do
        local widget = self.widgets[key]
        if widget then
            local bx, by = self:ButtonSize(key, scheme)
            local x = math.max(0, math.min(w - bx, p[1] * w - bx * 0.5 + (scheme.offsetX[key] or 0)))
            local y = math.max(0, math.min(h - by, p[2] * h - by * 0.5 + (scheme.offsetY[key] or 0)))
            widget:SetStyle({left = x, top = y, width = bx, height = by, scale = 1, transformOrigin = "top-left"})
        end
    end
    self:SetFeel(scheme.steeringSensitivity, scheme.steeringDeadzone)
    self:Refresh()
end

-- 挂入HUD现有安全区驾驶页；首子项优先级最低，原有技能/方向/踏板始终先命中。
-- 不使用全屏手势监听，只有明确标出的LOOK矩形可以取得环视手指。
---@param parent Widget
function Controls:MountLook(parent)
    local zone = UI.Panel {
        id = "drivingLook", position = "absolute", left = "64%", top = "26%",
        width = "16%", height = "13%", maxWidth = 138, maxHeight = 74,
        minWidth = 66, minHeight = 48, padding = 2, borderRadius = 8,
        -- 半透明小区域放在车头右侧空档，不能压住中央道路与车辆本体。
        backgroundColor = {9, 17, 24, 26}, borderWidth = 1, borderColor = {149, 174, 189, 45},
        pointerEvents = "box-only", visible = self.enabled,
        justifyContent = "center", alignItems = "center",
        onPointerDown = function(event)
            if event:IsTouch() then self:BeginLook(event.pointerId, event.x, event.y) end
        end,
        onPointerMove = function(event)
            if self.enabled and event:IsTouch() then self:MoveLook(event.pointerId, event.x, event.y) end
        end,
        onPointerUp = function(event) if event:IsTouch() then self:EndLook(event.pointerId, false) end end,
        onPointerCancel = function(event) if event:IsTouch() then self:EndLook(event.pointerId, true) end end,
        children = {
            UI.Label {text = "LOOK · 360°", fontSize = 11, fontWeight = "bold", fontColor = {224, 164, 75, 225},
                textAlign = "center", pointerEvents = "none"},
            UI.Label {text = "拖动环视 · 松手保持", fontSize = 7, fontColor = {214, 225, 231, 165},
                textAlign = "center", pointerEvents = "none"},
        },
    }
    self.lookWidget = zone
    parent:InsertChild(zone, 1)
    return zone
end

function Controls:SetEnabled(enabled)
    self.enabled = enabled
    self:Reset()
    if self.lookWidget then self.lookWidget:SetVisible(enabled) end
end

function Controls:Press(key, pointerId, x, width)
    if not self.enabled or pointerId < 0 or self.lookPointer == pointerId
        or self.pointers[key] == nil or self.pointers[key] ~= -1 then return false end
    -- 同一手指只能持有一个操作，其他手指彼此独立。
    for _, owner in pairs(self.pointers) do
        if owner == pointerId then return false end
    end
    self.pointers[key] = pointerId
    self.flashes[key] = 0.22 -- Keep a quick pulse visibly acknowledged after the finger lifts.
    if key == "steer" then
        self:Move(pointerId, x, width)
    else
        self[key] = true
        if key == "nitro" then self.nitroQueued = true end
        if key == "gas" then self.throttle = 1.0 end
    end
    self:Refresh()
    return true
end

function Controls:Move(pointerId, x, width)
    if not self.enabled or self.pointers.steer ~= pointerId or width <= 0 then return end
    local travel = STEER_TRAVEL / math.max(0.4, steerSensitivity)
    local raw = math.max(-1, math.min(1, (x - width * 0.5) / (width * travel)))
    local dead = math.max(0.01, math.min(0.34, deadzone))
    local amount = math.max(0, (math.abs(raw) - dead) / (1 - dead))
    -- 中心段保留原来的微调手感；中外段用连续斜率曲线展开，避免整段三次压缩导致弯道无舵可用。
    -- .18 处值/斜率连续，满行程仍是1；时间滤波仅由 Simulation 负责。
    local mapped = 0.20 * amount + 0.80 * amount^3
    if amount > 0.18 then
        local t = (amount - 0.18) / 0.82
        local start = 0.20 * 0.18 + 0.80 * 0.18^3
        local tangent = (0.20 + 2.40 * 0.18^2) * 0.82
        local finish = 0.80 * 0.82
        local span = 1 - start
        mapped = start + tangent * t + (3 * span - 2 * tangent - finish) * t^2
            + (-2 * span + tangent + finish) * t^3
    end
    self.steer = (raw < 0 and -1 or 1) * math.max(0, math.min(1, mapped))
    self:Refresh()
end

function Controls:Release(pointerId, cancelled)
    if pointerId < 0 then return end
    for key, owner in pairs(self.pointers) do
        if owner == pointerId then
            self.pointers[key] = -1
            if cancelled and key == "nitro" then self.nitroQueued = false end
            if key == "steer" then self.steer = 0.0 end
            -- 短点按松手后保留脉冲，直到主循环读取。
            for _, hold in ipairs(HOLDS) do
                if key == hold then self[key] = false end
            end
            if key == "gas" then self.throttle = 0.0 end
        end
    end
    self:Refresh()
end

-- 每帧汇总输入后调用一次；可使用返回快照，仅清单帧脉冲，不清保持键。
function Controls:ConsumeActions()
    local result = {steer = self.steer, throttle = self.throttle, gas = self.gas, brake = self.brake,
        clutch = self.clutch, wheelie = self.wheelie, burnout = self.burnout, nitro = self.nitro or self.nitroQueued,
        spin180 = self.spin180, spin360 = self.spin360, shiftUp = self.shiftUp, shiftDown = self.shiftDown}
    for _, key in ipairs(PULSES) do self[key] = false end
    self.nitroQueued = false
    self:Refresh()
    return result
end

local function shortDetail(detail)
    -- 按键内只显示短状态；完整限制原因仍由 HUD 中央提示与操作帮助说明。
    local phrases = {
        ["前轮抬起 · 松手放下"] = "抬轮中", ["车速过高 · 先减速"] = "先减速",
        ["点按起跳旋转"] = "点按旋转", ["腾空 · 点按旋转"] = "腾空旋转",
        ["损坏 · 先复位"] = "先复位", ["正在旋转"] = "旋转中", ["先加速至15"] = "先加速",
        ["先稳住车身"] = "稳住车身", ["就绪 · 耗45"] = "就绪",
        ["正在烧胎"] = "烧胎中",
    }
    if phrases[detail] then return phrases[detail] end
    -- 未知的长原因不塞进小按键，避免长文被截得只剩半句话。
    if utf8.len(detail) and utf8.len(detail) > 7 then return "暂不可用" end
    return detail
end
function Controls:SetActionState(key, state)
    -- Display-only contract. Never gate ownership or change the gameplay resource here.
    self.actionStates[key] = state or {}
    if self.captions[key] and state.label then self.captions[key]:SetText(SkillNames.Label(state.label)) end
    if self.details[key] and state.detail then self.details[key]:SetText(shortDetail(state.detail)) end
    self:Refresh()
end
function Controls:UpdateFeedback(dt)
    for key, remaining in pairs(self.flashes) do
        self.flashes[key] = math.max(0, remaining - dt)
    end
    self:Refresh()
end

function Controls:Refresh()
    -- ConsumeActions runs every frame. Only a changed visual state dirties Yoga.
    if self.widgets.stick and (self.visualSteer ~= self.steer or self.visualSteeringWidth ~= self.steeringWidth) then
        self.widgets.stick:SetStyle({translateX = self.steer * (self.steeringWidth * 0.5 - 37)})
        self.visualSteer, self.visualSteeringWidth = self.steer, self.steeringWidth
    end
    local steeringHeld = self.pointers.steer ~= -1
    if self.widgets.steering and self.visualSteeringHeld ~= steeringHeld then
        self.widgets.steering:SetStyle({borderColor = steeringHeld and AMBER or {180, 209, 216, 85}})
        self.visualSteeringHeld = steeringHeld
    end
    for key, widget in pairs(self.widgets) do
        if self.pointers[key] ~= nil and key ~= "steer" then
            local pressed = self.pointers[key] ~= -1
            local flash = (self.flashes[key] or 0) > 0
            local state = self.actionStates[key] or {}
            local status = state.state or "ready"
            local visual = status .. (pressed and ":down" or (flash and ":tap" or ":up"))
            if self.visualKeys[key] ~= visual then
                local active, blocked = status == "active", status == "blocked" or status == "empty"
                local material = RacingTheme.ControlSurface(pressed or flash, active, blocked)
                -- Visual depth stays inside the existing rectangle. No translation of the input surface.
                widget:SetStyle(material)
                self.visualKeys[key], self.visualPressed[key] = visual, pressed
                if self.details[key] then self.details[key]:SetFontColor(blocked and {244, 140, 120, 255}
                    or (active and {116, 239, 247, 255} or {162, 184, 195, 255})) end
            end
        end
    end
end

-- Only geometric marks here; the four driving actions use authored transparent images.
-- Render is inside the UI frame, so layout and pointer coordinates share UI.Scale.DEFAULT.
local ControlMark = UI.Widget:Extend("PursuitControlMark")
function ControlMark:Render(vg)
    local l = self:GetAbsoluteLayout()
    local cx, cy = l.x + l.w * 0.5, l.y + l.h * 0.5
    nvgBeginPath(vg)
    if self.props.mark == "steer" then
        nvgMoveTo(vg, cx - 20, cy - 6); nvgLineTo(vg, cx - 28, cy); nvgLineTo(vg, cx - 20, cy + 6)
        nvgMoveTo(vg, cx + 20, cy - 6); nvgLineTo(vg, cx + 28, cy); nvgLineTo(vg, cx + 20, cy + 6)
    elseif self.props.mark == "wheelie" or self.props.mark == "burnout" then
        local raised = self.props.mark == "wheelie"
        nvgCircle(vg, cx - 10, cy + 7, 6); nvgCircle(vg, cx + 11, cy + (raised and -4 or 7), 6)
        nvgMoveTo(vg, cx - 10, cy + 7); nvgLineTo(vg, cx - 3, cy - 4)
        nvgLineTo(vg, cx + 8, cy - (raised and 9 or 4)); nvgLineTo(vg, cx + 11, cy + (raised and -4 or 7))
        if not raised then
            nvgMoveTo(vg, cx - 18, cy - 2); nvgLineTo(vg, cx - 23, cy - 7)
            nvgMoveTo(vg, cx - 14, cy - 5); nvgLineTo(vg, cx - 16, cy - 12)
        end
    else
        nvgArc(vg, cx, cy, math.min(l.w, l.h) * 0.29, -2.4, 2.4, NVG_CW)
        nvgMoveTo(vg, cx - 12, cy + 4); nvgLineTo(vg, cx - 11, cy + 13); nvgLineTo(vg, cx - 3, cy + 9)
        if self.props.mark == "spin360" then
            nvgMoveTo(vg, cx + 6, cy - 9); nvgLineTo(vg, cx + 14, cy - 10); nvgLineTo(vg, cx + 13, cy - 2)
        end
    end
    nvgStrokeColor(vg, nvgRGBA(220, 224, 226, 210)); nvgStrokeWidth(vg, 2); nvgStroke(vg)
end

function Controls:CreateSteering()
    local stick = UI.Panel {position = "absolute", left = "50%", top = 23, marginLeft = -25,
        width = 50, height = 50, padding = 0, borderRadius = 25, pointerEvents = "none",
        backgroundGradient = {direction = "to-bottom", from = {76, 80, 84, 210}, to = {24, 27, 30, 220}},
        borderWidth = 1, borderColor = {194, 200, 205, 160}}
    local zone = UI.Panel {
        id = "steering", width = self.steeringWidth, height = 96, padding = 0, borderRadius = 48,
        backgroundColor = {10, 13, 16, 100}, borderWidth = 1, borderColor = {180, 189, 196, 85},
        pointerEvents = "box-only",
        onPointerDown = function(event, widget)
            if not event:IsTouch() and not event:IsPrimaryButton() then return end
            if self.editor then self.editor.down("steering", event, widget); return end
            local rect = widget:GetAbsoluteLayout()
            self:Press("steer", event.pointerId, event.x - rect.x, rect.w)
        end,
        onPointerMove = function(event, widget)
            if self.editor then self.editor.move(event); return end
            local rect = widget:GetAbsoluteLayout()
            self:Move(event.pointerId, event.x - rect.x, rect.w)
        end,
        onPointerUp = function(event)
            if self.editor then self.editor.up(event, false) else self:Release(event.pointerId) end
        end,
        onPointerCancel = function(event)
            if self.editor then self.editor.up(event, true) else self:Release(event.pointerId, true) end
        end,
        children = {
            UI.Panel {position = "absolute", left = 20, right = 20, top = 48, height = 1,
                backgroundColor = {196, 202, 206, 70}, pointerEvents = "none"},
            ControlMark {position = "absolute", left = 0, top = 0, right = 0, bottom = 0,
                mark = "steer", pointerEvents = "none"}, stick,
        },
    }
    local steeringText = UI.Label {position = "absolute", left = 0, right = 0, bottom = 5, height = 16,
        text = "转向 · 左右滑动", fontSize = 9, fontColor = {214, 225, 231, 255}, textAlign = "center", pointerEvents = "none"}
    zone:AddChild(steeringText)
    self.widgets.stick, self.widgets.steering = stick, zone
    self.visualSteer, self.visualSteeringWidth, self.visualSteeringHeld = math.huge, 0, false
    return zone
end

local CAPTIONS = {gas = "油门", brake = "刹车", nitro = "氮气", wheelie = "翘头", burnout = "烧胎", spin180 = "180°", spin360 = "360°"}
local DETAILS = {gas = "按住加速", brake = "按住制动", nitro = "就绪 · 耗45", wheelie = "按住抬轮", burnout = "按住原地", spin180 = "点按起跳旋转", spin360 = "点按起跳旋转"}
function Controls:CreateHold(key, text, width, height)
    local image = not self.lineStyle and Controls.Images[key] or nil
    local graphicProps = {position = "absolute", top = 3, left = 5, right = 5, bottom = 31, padding = 0, pointerEvents = "none"}
    ---@type Widget?
    local graphic = nil
    if image then
        graphicProps.backgroundImage, graphicProps.backgroundFit = image, "contain"
        graphic = UI.Panel(graphicProps)
    else
        graphicProps.mark = key
        if self.lineStyle then
            graphicProps.kind = key
            graphic = require("Career.LineIcon")(graphicProps)
        else graphic = ControlMark(graphicProps) end
    end
    -- 明确给出宽度，禁止 Label 把长状态当作 autoWidth 自动换行并向上顶住标题。
    local caption = UI.Label {position = "absolute", left = 0, width = "100%", bottom = 19, height = 17,
        paddingHorizontal = 3, text = SkillNames.Label(CAPTIONS[key] or (text ~= "" and text or key)),
        fontSize = 10, fontWeight = "bold", lineHeight = 1, maxLines = 1, whiteSpace = "nowrap",
        fontColor = {239, 245, 247, 255}, textAlign = "center", pointerEvents = "none"}
    local detail = UI.Label {position = "absolute", left = 0, width = "100%", bottom = 2, height = 15,
        paddingHorizontal = 3, text = DETAILS[key] or "点按", fontSize = 8, lineHeight = 1,
        maxLines = 1, whiteSpace = "nowrap", fontColor = {162, 184, 195, 255},
        textAlign = "center", pointerEvents = "none"}
    local hold = UI.Panel {id = key, width = width or 76, height = height or 80, padding = 0,
        borderRadius = 8, backgroundColor = {9, 17, 24, 210}, borderWidth = 1,
        borderColor = {149, 174, 189, 140}, pointerEvents = "box-only",
        onPointerDown = function(event, widget)
            if not event:IsTouch() and not event:IsPrimaryButton() then return end
            if self.editor then self.editor.down(key, event, widget) else self:Press(key, event.pointerId, 0, 1) end
        end,
        onPointerMove = function(event) if self.editor then self.editor.move(event) end end,
        onPointerUp = function(event)
            if self.editor then self.editor.up(event, false) else self:Release(event.pointerId) end
        end,
        onPointerCancel = function(event)
            if self.editor then self.editor.up(event, true) else self:Release(event.pointerId, true) end
        end,
        children = {graphic, caption, detail}}
    self.widgets[key], self.captions[key], self.details[key] = hold, caption, detail
    self.visualPressed[key], self.visualKeys[key] = nil, nil
    return hold
end

function Controls:CreatePulse(key, text, width)
    -- Press generates exactly one pulse; releasing a quick tap cannot erase it.
    return self:CreateHold(key, text, width or 74, 66)
end

function Controls:CreatePedal(key)
    return self:CreateHold(key, "", key == "gas" and 92 or 76, key == "gas" and 106 or 90)
end

function Controls:SetCompact(compact)
    if self.compactInitialized and self.compact == compact then return end
    self.compactInitialized, self.compact = true, compact
    self.steeringWidth = compact and 164 or 192
    if self.widgets.steering then self.widgets.steering:SetStyle({width = self.steeringWidth, height = 96}) end
    if self.widgets.gas then self.widgets.gas:SetStyle({width = compact and 82 or 92, height = compact and 94 or 106}) end
    if self.widgets.brake then self.widgets.brake:SetStyle({width = compact and 72 or 76, height = compact and 86 or 90}) end
    if self.widgets.nitro then self.widgets.nitro:SetStyle({width = compact and 74 or 80, height = compact and 78 or 84}) end
    for _, key in ipairs({"wheelie", "burnout", "spin180", "spin360"}) do
        if self.widgets[key] then self.widgets[key]:SetStyle({width = compact and 62 or 68, height = compact and 64 or 70}) end
    end
    self:Refresh()
end


function Controls.Test()
    local previousSensitivity, previousDeadzone = steerSensitivity, deadzone
    local c = Controls.New()
    c:SetFeel(1, .12)
    c:SetEnabled(true)
    -- 同一百分比手指位移在紧凑/普通控件上等效；中心微抖不应让摩托突然偏航。
    for _, width in ipairs({180, 206, 218}) do
        assert(c:Press("steer", 11, width * 0.5, width) and c.steer == 0)
        c:Move(11, width * 0.54, width)
        assert(c.steer == 0, "中心4%宽度微抖在死区内")
        c:Move(11, width * 0.60, width)
        local gentle = c.steer
        assert(gentle > 0.02 and gentle < 0.04, "轻滑10%宽度只产生约3%舵量")
        c:Move(11, width * 0.40, width)
        assert(math.abs(c.steer + gentle) < 1e-12, "渐进曲线左右对称")
        c:Move(11, width * 0.75, width)
        assert(math.abs(c.steer - 0.393624237763) < 1e-9, "四分之一滑动展开为约39%可用弯道舵量")
        local previous = 0.0
        for index = 1, 20 do
            c:Move(11, width * (0.5 + index * 0.025), width)
            assert(c.steer >= previous and c.steer <= 1, "外圈转向单调且有界")
            previous = c.steer
        end
        assert(c.steer == 1, "大幅推到外圈仍保留右满舵")
        c:Move(11, 0, width)
        assert(c.steer == -1, "大幅推到外圈仍保留左满舵")
        c:Release(11)
        assert(c.steer == 0, "松手立即清目标舵量，由模拟平滑回正")
    end
    assert(c:Press("steer", 11, 210, 218) and c.steer > 0.8)
    assert(c:Press("gas", 22, 0, 1) and c.gas and c.throttle == 1 and c.steer > 0.8)
    assert(c:Press("wheelie", 33, 0, 1) and c.wheelie)
    assert(not c:Press("burnout", 33, 0, 1), "同一手指不能同时归属两个区域")
    assert(not c:Press("steer", 44, 0, 218), "第二根手指不能抢占方向")
    c:Release(33)
    assert(not c.wheelie and c.gas and c.steer > 0.8, "松特技保留转向与油门")
    c:Release(22)
    assert(not c.gas and c.throttle == 0 and c.steer > 0.8, "右手松开不能取消左手")
    c:Move(11, 0, 218)
    assert(c.steer == -1, "拖出方向区后仍由原手指控制")
    c:Release(11)
    assert(c.steer == 0)
    assert(c:Press("wheelie", 44, 0, 1) and c:Press("burnout", 55, 0, 1))
    assert(c:Press("spin180", 66, 0, 1) and c.spin180)
    c:Release(66)
    assert(c.spin180, "快速点按在读取前不得丢失")
    local frame = c:ConsumeActions()
    assert(frame.spin180 and not c.spin180 and c.wheelie and c.burnout, "只消费脉冲，不清保持输入")
    assert(not c:ConsumeActions().spin180, "下帧不能重放旋转脉冲")
    assert(c:Press("spin360", 66, 0, 1) and c.spin360)
    assert(not c:Press("spin360", 77, 0, 1))
    c:Release(66)
    assert(c:ConsumeActions().spin360 and not c.spin360)
    c:Release(44)
    assert(not c.wheelie, "松开翘头")
    assert(c:Press("nitro", 101, 0, 1) and c:Press("wheelie", 102, 0, 1))
    c:Release(102)
    local combat = c:ConsumeActions()
    assert(combat.nitro and c.nitro and not c.wheelie, "氮气保持、翘头松手即停")
    c:Release(101)
    assert(not c.nitro and c.burnout, "松氮气不影响其他持续操作")
    assert(c:Press("nitro", 120, 0, 1))
    c:Release(120)
    assert(not c.nitro and c:ConsumeActions().nitro, "快速氮气点按松手后仍消费一次")
    assert(not c:ConsumeActions().nitro, "快速点按下一帧不能重放")
    assert(c:Press("nitro", 122, 0, 1))
    c:Release(122, true)
    assert(not c:ConsumeActions().nitro, "取消手势不能遗留待喷射点按")
    assert(c:Press("nitro", 121, 0, 1))
    c:Reset()
    assert(not c.nitroQueued and not c:ConsumeActions().nitro, "暂停与失焦Reset清掉未消费点按")
    c:SetEnabled(true)
    assert(c:Press("gas", 22, 0, 1) and c:Press("brake", 33, 0, 1))
    assert(c:Press("spin360", 99, 0, 1))
    c:Release(55)
    assert(c:Press("nitro", 101, 0, 1) and c:Press("wheelie", 102, 0, 1))
    c:SetEnabled(false)
    assert(not c.gas and not c.brake and not c.wheelie and not c.burnout and not c.nitro)
    assert(c.steer == 0 and c.throttle == 0 and not c.spin360)
    for _, owner in pairs(c.pointers) do assert(owner == -1) end
    assert(not c:Press("gas", 100, 0, 1))
    c:SetFeel(previousSensitivity, previousDeadzone)
    print("[手机操作自测] 中心低敏/渐进满舵/多宽度一致，多指独立，保持键释放，旋转单帧脉冲，暂停清空通过")
    return true
end

return Controls
