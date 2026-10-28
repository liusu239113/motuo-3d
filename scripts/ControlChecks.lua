-- 只由父入口在横屏、HUD 布局完成且无人触摸时显式调用：
-- local result = require("ControlChecks").Run(hud, controls)
-- 测试真实 UI 指针链路；存档全部留在独立模块的内存文件系统，不读取或改写玩家原档。
local UI = require("urhox-libs/UI")
local PointerEvent = require("urhox-libs/UI/Core/PointerEvent")
local Settings = require("ControlSettings")
local Checks = {}

---@class ControlCheckResult
---@field passed boolean
---@field assertions integer
---@field groups string[]
---@field saves integer
---@field reloads integer

---@class ControlCheckPointer
---@field x number
---@field y number
---@field primary boolean

---@class ControlCheckStore
---@field files table<string, string>
---@field writes integer
---@field reads integer

-- 用资源缓存读取文本脚本，不能使用沙箱已移除的 loadfile/dofile。
-- ReadString 读取的是带终止符的序列化字符串，源码必须逐行读取。
local function readSettingsSource()
    local file = assert(cache:GetFile("ControlSettings.lua"), "[ControlChecks] 缺少 ControlSettings.lua 源资源")
    local ok, source = pcall(function()
        assert(file:IsOpen(), "[ControlChecks] 无法打开操作设置源资源")
        local lines = {}
        while not file:IsEof() do lines[#lines + 1] = file:ReadLine() end
        return table.concat(lines, "\n")
    end)
    file:Dispose()
    assert(ok, tostring(source))
    return source
end

-- 每次 load 都建立全新闭包，确实走业务模块的 Save / load / parseScheme，
-- 而非自己重写一份序列化器或借用已缓存的 Current() 冒充重读。
---@param source string
---@param store ControlCheckStore
local function newSettings(source, store)
    local environment = setmetatable({
        fileSystem = {FileExists = function(_, path) return store.files[path] ~= nil end},
        File = function(path, mode)
            assert(path == "pursuit_controls.txt", "[ControlChecks] 出现未隔离的存档路径")
            assert(mode == FILE_READ or mode == FILE_WRITE, "[ControlChecks] 意外的文件模式")
            local opened = mode == FILE_WRITE or store.files[path] ~= nil
            if mode == FILE_READ then store.reads = store.reads + 1 end
            return {
                IsOpen = function() return opened end,
                ReadString = function()
                    assert(opened and mode == FILE_READ, "[ControlChecks] 非法读取内存文件")
                    return store.files[path] or ""
                end,
                WriteString = function(_, text)
                    assert(opened and mode == FILE_WRITE, "[ControlChecks] 非法写入内存文件")
                    store.files[path] = text
                    store.writes = store.writes + 1
                    return true
                end,
                Close = function() opened = false end,
            }
        end,
    }, {__index = _G})
    -- 标准 Lua 5.4 load 的显式环境只覆盖此子模块，不修改全局 File/fileSystem。
    local chunk, failure = load(source, "@ControlSettings.lua（回归隔离）", "t", environment)
    assert(chunk, "[ControlChecks] 无法加载操作设置源文件：" .. tostring(failure))
    return chunk()
end

local function shallow(source)
    local copy = {}
    for key, value in pairs(source or {}) do copy[key] = value end
    return copy
end

---@param hud HUD
---@param controls MobileControls
---@return ControlCheckResult
function Checks.Run(hud, controls)
    ---@type ControlCheckResult
    local result = {passed = false, assertions = 0, groups = {}, saves = 0, reloads = 0}
    local function check(condition, message)
        assert(condition, "[ControlChecks] " .. message)
        result.assertions = result.assertions + 1
    end
    local function passed(name)
        result.groups[#result.groups + 1] = name
        print("[ControlChecks] PASS " .. name)
    end
    local function near(a, b, tolerance) return math.abs(a - b) <= (tolerance or 0.00001) end
    check(UI.GetRoot() == hud.root and UI.IsEnabled(), "必须传入启用中的实际 HUD")
    check(hud.controls == controls, "HUD 与测试必须共用实际 MobileControls")
    check(not UI.Input.HasActivePointer(), "真实手指按住时不能运行测试")
    check(not hud.portraitActive and not hud.portrait:IsVisible(), "请在横屏提示关闭后运行")
    check(not hud.dragSlot, "不能打断玩家正在进行的布局拖动")
    check(hud.screen ~= "garage", "请先退出车库，避免页面切换销毁真实车库预览")
    for _, owner in pairs(controls.pointers) do check(owner == -1, "开始测试前操控指针必须释放") end

    local source = readSettingsSource()
    ---@type ControlCheckStore
    local store = {files = {}, writes = 0, reads = 0}
    local isolated = newSettings(source, store)
    check(#isolated.All() == 1 and isolated.ActiveIndex() == 1 and store.reads == 0,
        "空白内存文件系统必须自行生成默认方案，不依赖玩家原档")
    local originalFunctions = {}
    for name, value in pairs(Settings) do
        if type(value) == "function" then originalFunctions[name] = value end
    end
    -- HUD/ControlEditor 的闭包已捕获共享 Settings 表；只借调导出函数，
    -- 原函数的 schemes / activeIndex 闭包完全不执行，因此原方案内容和引用都不动。
    local function install(module)
        for name in pairs(originalFunctions) do
            check(type(module[name]) == "function", "隔离模块缺少原导出函数：" .. name)
            Settings[name] = module[name]
        end
    end

    local oldScreen, oldFocus, oldEditor = hud.screen, UI.GetFocus(), controls.editor
    local oldSettingsAction, oldScheme, oldEnabled = hud.actions.settings, controls.scheme, controls.enabled
    local oldSchemeButtons = shallow(hud.settingsSchemeButtons)
    local oldButtonCount = #hud.settingsSchemeButtons
    local oldFields = {}
    local fieldNames = {"settingsSlot", "settingsReturn", "settingsToolsOpen", "refreshingSettings",
        "dragSlot", "dragPointer", "dragOffsetX", "dragOffsetY", "dragRectX", "dragRectY", "dragRectW", "dragRectH",
        "dragWidth", "dragHeight", "dragPreviewX", "dragPreviewY", "controlWidth", "controlHeight", "pendingControlLayout"}
    for _, name in ipairs(fieldNames) do oldFields[name] = hud[name] end
    -- 仅保存会被本测试修改的编辑树和驾驶按键，所有回调保留原函数引用。
    local snapshots = {}
    local function snapshot(widget)
        snapshots[#snapshots + 1] = {widget = widget, props = shallow(widget.props), state = shallow(widget.state)}
        for _, child in ipairs(widget:GetChildren()) do snapshot(child) end
    end
    snapshot(hud.settings)
    snapshot(hud.controlLayer)
    local oldVisualKeys, oldVisualPressed = shallow(controls.visualKeys), shallow(controls.visualPressed)
    local oldFlashes = shallow(controls.flashes)
    local oldVisualSteer, oldVisualWidth, oldVisualHeld = controls.visualSteer, controls.visualSteeringWidth, controls.visualSteeringHeld

    local FIRST, SECOND, CLICK = 740001, 740002, 740003
    ---@type table<number, ControlCheckPointer>
    local active = {}
    local function send(kind, id, x, y, primary)
        local ending = kind == PointerEvent.Types.PointerUp or kind == PointerEvent.Types.PointerCancel
        local scale = UI.GetScale()
        check(scale > 0 and scale < math.huge, "UI 缩放必须是有限正数")
        local event = PointerEvent.new(kind, {
            pointerId = id, pointerType = PointerEvent.PointerTypes.Touch, isPrimary = primary,
            x = x * scale, y = y * scale, button = PointerEvent.Button.Left,
            buttons = ending and PointerEvent.Buttons.None or PointerEvent.Buttons.Primary,
            pressure = ending and 0 or 0.5,
        })
        -- 必须先登记：回调内部断言失败时 finally 仍能发送真实 Cancel 清掉 UI 捕获。
        if not ending then active[id] = {x = x, y = y, primary = primary} end
        UI.HandlePointerEvent(event)
        if ending then active[id] = nil end
        return event
    end
    local function finish(kind, id)
        local pointer = assert(active[id], "[ControlChecks] 缺少测试指针")
        return send(kind, id, pointer.x, pointer.y, pointer.primary)
    end
    ---@param widget Widget
    local function rect(widget)
        local r = widget:GetAbsoluteLayout()
        check(r.w > 0 and r.h > 0 and r.x == r.x and r.y == r.y and r.w < math.huge and r.h < math.huge,
            "控件必须完成有限正尺寸布局")
        return {x = r.x, y = r.y, w = r.w, h = r.h}
    end
    ---@param widget Widget
    local function down(widget, id, fx, fy, primary)
        UI.Layout()
        local r = rect(widget)
        local x, y = r.x + r.w * fx, r.y + r.h * fy
        local event = send(PointerEvent.Types.PointerDown, id, x, y, primary)
        check(event.target == widget and event.currentTarget == widget,
            "必须真实命中所测控件，不能直接调用 props 回调冒充 UI 事件")
        check(near(event.x, x, 0.01) and near(event.y, y, 0.01), "物理坐标必须正确还原为 UI 基准坐标")
        return x, y
    end
    ---@param widget Widget
    local function click(widget)
        down(widget, CLICK, 0.5, 0.5, true)
        local event = finish(PointerEvent.Types.PointerUp, CLICK)
        check(event.target == widget, "按钮抬手必须由实际 UI 捕获者接收")
        UI.Layout()
    end
    local function findButton(widget, text)
        if widget.props.text == text and widget.props.onClick then return widget end
        for _, child in ipairs(widget:GetChildren()) do
            local found = findButton(child, text)
            if found then return found end
        end
        return nil
    end
    local function zero(message)
        local empty = controls.steer == 0 and controls.throttle == 0 and not controls.nitroQueued
        for key, owner in pairs(controls.pointers) do
            if owner ~= -1 or (key ~= "steer" and controls[key] == true) then empty = false end
        end
        check(empty, message)
    end
    local function sameRect(a, b, message)
        local tolerance = 1 / UI.GetScale() + 0.30
        check(near(a.x, b.x, tolerance) and near(a.y, b.y, tolerance)
            and near(a.w, b.w, tolerance) and near(a.h, b.h, tolerance), message)
    end
    local function layout()
        UI.Layout(); hud:UpdateLayout(); UI.Layout()
    end
    local function open()
        hud:OpenSettings(); layout()
        check(hud.screen == "settings" and controls.editor ~= nil and not controls.enabled,
            "编辑页必须接管同一组实战按键，并禁用驾驶输入")
        check(hud.controlLayer:IsVisible() and hud.settings:IsVisible(), "编辑层和真实操控层必须同时可见")
        for _, key in ipairs(Settings.Keys) do
            check(hud.controlWidgets[key] == controls.widgets[key], "编辑与驾驶不能各建一套按键：" .. key)
        end
        zero("打开编辑页后不得残留驾驶输入")
    end
    local function reload()
        local before = store.reads
        local fresh = newSettings(source, store)
        fresh.All()
        check(store.reads == before + 1, "重读必须由全新模块真实打开已写入的内存文件")
        result.reloads = result.reloads + 1
        return fresh
    end
    local function compareSchemes(actual, expected)
        check(actual.name == expected.name, "方案名称往返不一致")
        for _, key in ipairs(Settings.Keys) do
            check(near(actual.pos[key][1], expected.pos[key][1], 0.000051)
                and near(actual.pos[key][2], expected.pos[key][2], 0.000051), "中心位置保存后重读失败：" .. key)
            check(near(actual.offsetX[key], expected.offsetX[key], 0.051)
                and near(actual.offsetY[key], expected.offsetY[key], 0.051), "兼容偏移保存后重读失败：" .. key)
            check(near(actual.scale[key], expected.scale[key], 0.0051), "按键尺寸保存后重读失败：" .. key)
        end
        check(near(actual.steeringSensitivity, expected.steeringSensitivity, 0.0051)
            and near(actual.steeringDeadzone, expected.steeringDeadzone, 0.00051)
            and near(actual.nitroSensitivity, expected.nitroSensitivity, 0.0051), "全部灵敏度/死区必须完整往返")
    end

    local ok, failure = pcall(function()
        install(isolated)
        -- 不调用真实入口的 settings 回调，避免改变主循环暂停标志或触发游戏流程。
        hud.actions.settings = function(enabled) hud:SetScreen(enabled and "settings" or hud.settingsReturn) end
        local fixture = Settings.Current()
        fixture.name, fixture.scale.gas = "回归方案一", 0.90
        fixture.steeringSensitivity, fixture.steeringDeadzone, fixture.nitroSensitivity = 1.27, 0.19, 1.23
        fixture.offsetX.spin180, fixture.offsetY.spin180 = 13.4, -8.2
        check(Settings.Save(), "初始内存方案必须可保存")
        hud:SetScreen("pause"); layout(); open()
        local area = rect(hud.controlLayer)
        check(area.w > 600 and area.h > 350, "测试需要足以容纳编辑面板的横屏安全区")
        local gas = assert(controls.widgets.gas)
        local brake = assert(controls.widgets.brake)
        local steering = assert(controls.widgets.steering)
        local complete = assert(findButton(hud.settingsChrome, "完成"), "[ControlChecks] 缺少实际完成按钮")

        -- 以非中心抓取点拖动，检查拖动偏移、中心归一化和实战尺寸，不仅检查 props。
        local start = rect(gas)
        local x, y = down(gas, FIRST, 0.35, 0.65, true)
        check(hud.dragSlot == "gas" and hud.dragPointer == FIRST, "实际按下必须开始油门布局拖动")
        local targetX, targetY = area.x + area.w * 0.54, area.y + area.h * 0.70
        local left, top = targetX - start.w * 0.35, targetY - start.h * 0.65
        local before = store.writes
        send(PointerEvent.Types.PointerMove, FIRST, targetX, targetY, true)
        layout()
        local preview = rect(gas)
        sameRect(preview, {x = left, y = top, w = start.w, h = start.h}, "拖动预览必须遵循真实抓取偏移和原尺寸")
        check(store.writes == before, "拖动中不能误保存未提交预览")
        zero("编辑拖动不能启动油门或其他驾驶输入")
        finish(PointerEvent.Types.PointerUp, FIRST); layout()
        check(hud.dragSlot == nil and store.writes == before + 1, "松手必须结束拖动并自动保存一次")
        local saved = Settings.Current().pos.gas
        check(near(saved[1], (left - area.x + start.w / 2) / area.w)
            and near(saved[2], (top - area.y + start.h / 2) / area.h), "存档必须记录安全区中心比例而非左上角或物理像素")
        local edited = rect(gas)
        click(complete); layout()
        check(hud.screen == "pause" and controls.editor == nil, "真实完成按钮必须退出编辑并返回原暂停页")
        hud:SetScreen("ride"); layout()
        sameRect(rect(gas), edited, "完成后驾驶页必须保持编辑位置与尺寸")
        local newFile = reload()
        compareSchemes(newFile.Current(), Settings.Current())
        -- 真正换用重读的闭包，再应用至实际 HUD，避免只比较文件文本。
        isolated = newFile; install(isolated); hud:ApplySettings(); layout()
        sameRect(rect(gas), edited, "重读已保存方案后实际驾驶位置不得改变")
        down(gas, FIRST, 0.5, 0.5, true)
        check(controls.gas and controls.throttle == 1 and controls.pointers.gas == FIRST,
            "编辑后同位置必须在驾驶页真实命中油门")
        finish(PointerEvent.Types.PointerUp, FIRST)
        zero("驾驶同位置验证松手后必须清空输入")
        check(x ~= targetX or y ~= targetY, "拖放必须有真实非零移动")
        passed("真实UI拖放→松手保存→完成→重读→驾驶同位置同尺寸命中")

        hud:SetScreen("pause"); layout(); open()
        area = rect(hud.controlLayer)
        for _, edge in ipairs({{x = area.x - 120, y = area.y - 120, far = false},
            {x = area.x + area.w + 120, y = area.y + area.h + 120, far = true}}) do
            local size = rect(gas)
            down(gas, FIRST, 0.5, 0.5, true)
            send(PointerEvent.Types.PointerMove, FIRST, edge.x, edge.y, true); layout()
            local expected = {x = area.x + (edge.far and area.w - size.w or 0),
                y = area.y + (edge.far and area.h - size.h or 0), w = size.w, h = size.h}
            sameRect(rect(gas), expected, "拖出安全区时整个按钮必须夹紧在边界内")
            finish(PointerEvent.Types.PointerUp, FIRST); layout()
            sameRect(rect(gas), expected, "松手重新应用方案后边界位置不得跳变")
            local position = Settings.Current().pos.gas
            check(near(position[1], (expected.x - area.x + size.w / 2) / area.w, 0.00001)
                and near(position[2], (expected.y - area.y + size.h / 2) / area.h, 0.00001),
                "边界存档必须保留按钮半尺寸，不能简单写成0或1")
        end
        passed("真实捕获拖出屏幕：左上/右下边界夹取与落点保存")

        local committed = rect(gas)
        local px, py = Settings.Current().pos.gas[1], Settings.Current().pos.gas[2]
        local writesBeforeCancel = store.writes
        down(gas, FIRST, 0.5, 0.5, true)
        send(PointerEvent.Types.PointerMove, FIRST, area.x + area.w * 0.50, area.y + area.h * 0.68, true); layout()
        check(not near(rect(gas).x, committed.x, 2), "取消用例必须先真实改变预览位置")
        finish(PointerEvent.Types.PointerCancel, FIRST); layout()
        sameRect(rect(gas), committed, "PointerCancel 必须恢复拖动前已提交的布局")
        check(hud.dragSlot == nil and store.writes == writesBeforeCancel
            and Settings.Current().pos.gas[1] == px and Settings.Current().pos.gas[2] == py,
            "取消不能写档、改中心比例或遗留拖动所有权")
        passed("真实PointerCancel恢复布局、保留原方案、不写档")

        down(gas, FIRST, 0.5, 0.5, true)
        local firstX, firstY = area.x + area.w * 0.54, area.y + area.h * 0.72
        send(PointerEvent.Types.PointerMove, FIRST, firstX, firstY, true); layout()
        local owned = rect(gas)
        local writesBeforeSecond = store.writes
        down(brake, SECOND, 0.5, 0.5, false)
        check(hud.dragSlot == "gas" and hud.dragPointer == FIRST, "第二指针按其他按钮不能抢占编辑所有权")
        send(PointerEvent.Types.PointerMove, SECOND, area.x + 15, area.y + area.h / 2, false); layout()
        sameRect(rect(gas), owned, "第二指针移动不能改变第一指针预览")
        finish(PointerEvent.Types.PointerUp, SECOND)
        check(hud.dragSlot == "gas" and hud.dragPointer == FIRST and store.writes == writesBeforeSecond,
            "第二指针抬手不能提交或结束第一指针拖动")
        send(PointerEvent.Types.PointerMove, FIRST, firstX + 20, firstY - 10, true)
        finish(PointerEvent.Types.PointerUp, FIRST); layout()
        check(hud.dragSlot == nil and store.writes == writesBeforeSecond + 1,
            "只有原指针抬手才能完成并保存拖动")
        zero("双指编辑不能泄漏到驾驶输入")
        passed("第二指针不抢占、不移动、不提前提交，原指针可继续拖动")

        click(hud.settingsToolbarButton)
        check(hud.settingsTools:IsVisible(), "真实工具栏按钮必须展开方案/灵敏度面板")
        local original = Settings.Current()
        local originalIndex = Settings.ActiveIndex()
        click(assert(findButton(hud.settingsTools, "复制当前"), "[ControlChecks] 缺少复制当前按钮"))
        local copy = Settings.Current()
        check(#Settings.All() == 2 and Settings.ActiveIndex() ~= originalIndex and copy ~= original,
            "实际复制按钮必须创建并激活新方案")
        check(copy.pos ~= original.pos and copy.offsetX ~= original.offsetX
            and copy.offsetY ~= original.offsetY and copy.scale ~= original.scale, "复制方案的所有可变容器都必须深拷贝")
        for _, key in ipairs(Settings.Keys) do
            check(copy.pos[key] ~= original.pos[key] and copy.pos[key][1] == original.pos[key][1]
                and copy.pos[key][2] == original.pos[key][2] and copy.scale[key] == original.scale[key]
                and copy.offsetX[key] == original.offsetX[key] and copy.offsetY[key] == original.offsetY[key],
                "逐按键位置子表独立且数值完整复制：" .. key)
        end
        check(copy.steeringSensitivity == original.steeringSensitivity
            and copy.steeringDeadzone == original.steeringDeadzone and copy.nitroSensitivity == original.nitroSensitivity,
            "复制必须包括全部手感数值")
        local originalGasX, originalGasY = original.pos.gas[1], original.pos.gas[2]
        Settings.SetPosition("gas", 0.61, 0.73)
        copy.scale.gas, copy.offsetX.gas, copy.offsetY.gas = 1.10, 6.3, -4.8
        check(original.pos.gas[1] == originalGasX and original.pos.gas[2] == originalGasY
            and original.scale.gas == 0.90 and original.offsetX.gas == 0 and original.offsetY.gas == 0,
            "改变副本的位置、尺寸、偏移不能反向改动来源方案")
        passed("真实复制方案按钮、逐层深拷贝、修改副本不污染来源")

        -- 用非整数百分数作为回填哨兵；RefreshSettings 的 SetValue 不能触发反写取整。
        copy.steeringSensitivity, copy.steeringDeadzone = 1.333, 0.173
        hud:RefreshSettings(); layout()
        check(near(hud.settingsSensitivity:GetValue(), 133.3) and near(hud.settingsDeadzone:GetValue(), 17.3),
            "选中方案的灵敏度/死区必须回填实际滑杆")
        check(copy.steeringSensitivity == 1.333 and copy.steeringDeadzone == 0.173,
            "回填滑杆不得误调用手势修改回调反写方案")
        local function slider(sliderWidget, value, key)
            local r = rect(sliderWidget)
            local props = sliderWidget.props
            local x = r.x + props.thumbSize / 2 + (value - props.min) / (props.max - props.min) * (r.w - props.thumbSize)
            local y = r.y + r.h / 2
            local beforeSaves = store.writes
            down(sliderWidget, FIRST, 0.5, 0.5, true)
            send(PointerEvent.Types.PointerMove, FIRST, x, y, true)
            check(near(sliderWidget:GetValue(), value) and near(Settings.Current()[key], value / 100),
                "真实滑杆手势必须更新实际方案：" .. key)
            check(store.writes == beforeSaves, "滑杆拖动中不能提前保存")
            finish(PointerEvent.Types.PointerUp, FIRST)
            check(store.writes == beforeSaves + 1, "滑杆松手必须自动保存一次：" .. key)
        end
        slider(hud.settingsSensitivity, 146, "steeringSensitivity")
        slider(hud.settingsDeadzone, 9, "steeringDeadzone")
        click(assert(hud.settingsSchemeButtons[originalIndex]))
        check(Settings.ActiveIndex() == originalIndex and near(hud.settingsSensitivity:GetValue(), 127)
            and near(hud.settingsDeadzone:GetValue(), 19), "实际切回来源方案必须恢复它自己的两个滑杆值")
        click(assert(hud.settingsSchemeButtons[2]))
        check(Settings.ActiveIndex() == 2 and near(hud.settingsSensitivity:GetValue(), 146)
            and near(hud.settingsDeadzone:GetValue(), 9), "实际切回副本必须恢复已保存的独立滑杆值")
        check(Settings.Save(), "最终内存方案必须保存成功")
        local roundtrip = reload()
        check(#roundtrip.All() == 2 and roundtrip.ActiveIndex() == 2, "多方案数量与激活索引必须保存后重读一致")
        for index, scheme in ipairs(Settings.All()) do compareSchemes(roundtrip.All()[index], scheme) end
        isolated = roundtrip; install(isolated); hud:RefreshSettings(); hud:ApplySettings(); layout()
        check(near(hud.settingsSensitivity:GetValue(), 146) and near(hud.settingsDeadzone:GetValue(), 9),
            "全新模块重读后 HUD 滑杆仍须回填正确")
        check(store.files.pursuit_controls == nil and type(store.files["pursuit_controls.txt"]) == "string",
            "往返必须写入指定内存文件而非旁路直接传递方案表")
        passed("滑杆回填无反写、真实拖动松手保存、方案切换、全新模块完整存读往返")

        click(hud.settingsToolbarButton)
        click(complete); hud:SetScreen("ride"); layout()
        down(steering, FIRST, 0.5, 0.5, true)
        check(controls.steer == 0, "重读的手感设置下方向中心仍必须是零")
        local r = rect(steering)
        send(PointerEvent.Types.PointerMove, FIRST, r.x + r.w * 0.52, r.y + r.h / 2, true)
        check(controls.steer == 0, "重读的9%死区必须作用于实际方向控件")
        send(PointerEvent.Types.PointerMove, FIRST, r.x + r.w * 0.92, r.y + r.h / 2, true)
        check(controls.steer == 1 and controls.pointers.steer == FIRST,
            "重读后实际驾驶方向仍可到达满舵且持有原指针")
        finish(PointerEvent.Types.PointerCancel, FIRST)
        zero("所有回归组结束后不得残留驾驶输入")
        passed("重读配置重新应用到真实MobileControls方向与死区")
    end)

    -- 每步清理独立 pcall：即使某个 UI 恢复步骤失败，也必须继续恢复共享函数和业务回调。
    local cleanupErrors = {}
    local function cleanup(action)
        local restored, reason = pcall(action)
        if not restored then cleanupErrors[#cleanupErrors + 1] = tostring(reason) end
    end
    for _, id in ipairs({FIRST, SECOND, CLICK}) do
        cleanup(function() if active[id] then finish(PointerEvent.Types.PointerCancel, id) end end)
    end
    cleanup(function()
        if hud.dragSlot then hud:EndDragSettingButton(nil, true) end
        hud:SetScreen(oldScreen)
        controls:SetEditor(oldEditor)
        controls:SetEnabled(oldEnabled)
        if oldScheme then
            controls:ApplyScheme(oldScheme, hud.controlLayer:GetAbsoluteLayout().w, hud.controlLayer:GetAbsoluteLayout().h)
        end
    end)
    cleanup(function()
        -- 删除测试复制方案期间懒创建的按钮，原按钮对象及表引用保留不变。
        for index = #hud.settingsSchemeButtons, oldButtonCount + 1, -1 do
            hud.settingsSchemeButtons[index]:Remove()
            hud.settingsSchemeButtons[index]:Destroy()
            hud.settingsSchemeButtons[index] = nil
        end
        for index, widget in pairs(oldSchemeButtons) do hud.settingsSchemeButtons[index] = widget end
        for _, item in ipairs(snapshots) do
            item.widget:SetStyle(shallow(item.props))
            for key in pairs(item.widget.props) do
                if item.props[key] == nil then item.widget.props[key] = nil end
            end
            if item.widget.state then
                for key in pairs(item.widget.state) do item.widget.state[key] = nil end
                for key, value in pairs(item.state) do item.widget.state[key] = value end
            end
        end
        for _, name in ipairs(fieldNames) do hud[name] = oldFields[name] end
        controls.scheme = oldScheme
        controls.visualKeys, controls.visualPressed, controls.flashes = oldVisualKeys, oldVisualPressed, oldFlashes
        controls.visualSteer, controls.visualSteeringWidth, controls.visualSteeringHeld = oldVisualSteer, oldVisualWidth, oldVisualHeld
        UI.Layout(); UI.SetFocus(oldFocus)
    end)
    -- 无论上面是否失败，以下两项都必须执行；不会调用原 Settings 闭包加载玩家存档。
    cleanup(function() for name, value in pairs(originalFunctions) do Settings[name] = value end end)
    cleanup(function() hud.actions.settings = oldSettingsAction end)
    cleanup(function()
        zero("finally 后输入和全部操控指针必须清空")
        check(hud.screen == oldScreen and controls.editor == oldEditor and controls.enabled == oldEnabled,
            "finally 必须恢复原页面、编辑回调与操控启用状态")
        check(hud.actions.settings == oldSettingsAction and controls.scheme == oldScheme,
            "finally 必须恢复原业务回调和原方案对象引用")
        for name, value in pairs(originalFunctions) do check(Settings[name] == value, "原设置函数必须原样恢复：" .. name) end
        check(UI.GetFocus() == oldFocus and not UI.Input.HasActivePointer(), "finally 必须恢复焦点且不遗留真实输入捕获")
    end)
    local cleanupFailure = table.concat(cleanupErrors, "；")
    assert(ok, tostring(failure) .. (#cleanupErrors > 0 and ("；清理失败：" .. cleanupFailure) or ""))
    assert(#cleanupErrors == 0, "[ControlChecks] 清理失败：" .. cleanupFailure)
    passed("pcall/finally恢复原方案引用、屏幕、控件、所有回调与焦点；原玩家存档零访问")
    result.saves, result.passed = store.writes, true
    print(string.format("[ControlChecks] 全部通过：%d 类，%d 条断言，%d 次内存保存，%d 次新模块重读",
        #result.groups, result.assertions, result.saves, result.reloads))
    return result
end

return Checks
