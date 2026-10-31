-- 仅由 main 在世界 ready 数帧、横屏且 UI 已完成布局后调用：
-- local result = require("MobileChecks").Run(hud, controls, sound)
-- 不创建场景/节点/音源，不加载资源，不调用 Controls.Test/Press/Move/Release。
local UI = require("urhox-libs/UI")
local PointerEvent = require("urhox-libs/UI/Core/PointerEvent")
local Simulation = require("Simulation")
local Race = require("Race")
local Controls = require("MobileControls")
local Checks = {}

---@class MobileCheckSoundResult
---@field path string
---@field frequency number Hz，Sound 素材采样率，不是 SoundSource 的 pitch
---@field duration number 秒

---@class MobileCheckSourceState
---@field source SoundSource
---@field sample Sound?
---@field gain number
---@field frequency number
---@field pitch number?
---@field playing boolean

---@class MobileCheckResult
---@field passed boolean
---@field assertions integer
---@field groups string[]
---@field labels integer
---@field sounds MobileCheckSoundResult[]

---@class MobileCheckPointer
---@field x number 基准像素
---@field y number 基准像素
---@field isPrimary boolean

---@param hud HUD
---@param controls MobileControls
---@param sound RideAudio
---@return MobileCheckResult
function Checks.Run(hud, controls, sound)
    ---@type MobileCheckResult
    local result = {passed = false, assertions = 0, groups = {}, labels = 0, sounds = {}}
    local function check(condition, message)
        assert(condition, "[MobileChecks] " .. message)
        result.assertions = result.assertions + 1
    end
    local function passed(name)
        result.groups[#result.groups + 1] = name
        print("[MobileChecks] PASS " .. name)
    end
    local function near(a, b)
        return math.abs(a - b) < 0.01
    end
    -- 独立期望曲线，用于校验真实指针链路；不调用Controls的Press/Move绕过UI。
    local function expectedSteer(fraction)
        local raw = math.max(-1, math.min(1, (fraction - 0.5) / 0.42))
        local a = math.max(0, (math.abs(raw) - 0.12) / 0.88)
        local value = 0.20 * a + 0.80 * a^3
        if a > 0.18 then
            local t, start = (a - 0.18) / 0.82, 0.20 * 0.18 + 0.80 * 0.18^3
            local first, last = (0.20 + 2.40 * 0.18^2) * 0.82, 0.80 * 0.82
            value = start + first * t + (3 * (1 - start) - 2 * first - last) * t^2
                + (-2 * (1 - start) + first + last) * t^3
        end
        return (raw < 0 and -1 or 1) * math.max(0, math.min(1, value))
    end

    check(UI.GetRoot() == hud.root and UI.IsEnabled(), "必须使用已启用的实际 HUD 根控件")
    check(not UI.Input.HasActivePointer(), "请在没有真实手指按住时运行测试")
    check(not hud.portrait:IsVisible(), "请在横屏提示关闭、布局完成后运行")
    check(not sound.stopped, "必须传入尚未 Stop 的实际 RideAudio")
    local oldMusic, oldEffects = sound.musicEnabled, sound.effectsEnabled
    local oldTrackIndex = sound.trackIndex
    local oldMusicText, oldEffectsText = hud.musicButton.props.text, hud.effectsButton.props.text
    local oldRadioTitle, oldRadioToggleText = hud.radioTitle.props.text, hud.radioToggle.props.text
    -- Radio transport moved into the pause menu; resolve the actual visible buttons,
    -- rather than expecting the obsolete ride-overlay HUD fields.
    ---@type Button?
    local radioPrevious = nil
    ---@type Button?
    local radioNext = nil
    local function findRadioButtons(widget)
        for _, child in ipairs(widget:GetChildren()) do
            if child.props.text == "上一首" then radioPrevious = child --[[@as Button]] end
            if child.props.text == "下一首" then radioNext = child --[[@as Button]] end
            findRadioButtons(child)
        end
    end
    findRadioButtons(hud.pause)
    local previousButton = assert(radioPrevious, "[MobileChecks] 暂停页缺少实际上一首按钮")
    local nextButton = assert(radioNext, "[MobileChecks] 暂停页缺少实际下一首按钮")
    local oldPreviousText, oldNextText = previousButton.props.text, nextButton.props.text
    local oldRace, oldScreen = hud.race, hud.screen
    local oldFocus = UI.GetFocus()
    local oldNode, oldScene, oldUnlocked = sound.node, sound.scene, sound.unlocked
    local oldSounds, oldSources = sound.sounds, sound.sources
    ---@type table<number, SoundSource?>
    local originalSources = {}
    for index = 1, 6 do originalSources[index] = sound.sources[index] end
    ---@type table<number, Sound?>
    local originalSounds = {}
    for index = 1, 8 do originalSounds[index] = sound.sounds[index] end
    -- 高位 ID 仅用于本次同步测试；每个按下都必须经 Up/Cancel 解除 UI 内部捕获。
    local LEFT, RIGHT, THIRD = 730001, 730002, 730003
    ---@type table<number, MobileCheckPointer?>
    local active = {}
    ---@type PointerEvent[]
    local steerMoves = {}
    local steering = assert(controls.widgets.steering, "[MobileChecks] 缺少方向 zone") --[[@as Widget]]
    local gas = assert(controls.widgets.gas, "[MobileChecks] 缺少油门 zone") --[[@as Widget]]
    local brake = assert(controls.widgets.brake, "[MobileChecks] 缺少刹车 zone") --[[@as Widget]]
    local nitro = assert(controls.widgets.nitro, "[MobileChecks] 缺少氮气 zone") --[[@as Widget]]
    -- 本版已取消主动肘击；原拳套位置改为翘头，验证其真实占位与不再有攻击入口。
    check(controls.widgets.shove == nil, "[MobileChecks] 不应再存在拳套按钮")
    local wheelieZone = assert(controls.widgets.wheelie, "[MobileChecks] 缺少翘头 zone") --[[@as Widget]]
    ---@param event PointerEvent
    local function observeSteerMove(event)
        -- 滑出时 UI 会把 move 克隆给捕获者，不能只检查传入事件的 target。
        if event.pointerId == LEFT then
            local snapshot = event:Clone()
            -- PointerEvent.Clone 构造器会把 currentTarget 重置为 nil，显式保存派发现场。
            snapshot.currentTarget = event.currentTarget
            steerMoves[#steerMoves + 1] = snapshot
        end
    end
    steering:OnEvent("pointermove", observeSteerMove)

    ---@param kind string
    ---@param id number
    ---@param x number 基准像素；绝不能把这里的坐标直接当作物理像素传入 UI
    ---@param y number
    ---@param primary boolean
    ---@return PointerEvent
    local function send(kind, id, x, y, primary)
        local scale = UI.GetScale()
        check(scale > 0 and scale < math.huge, "UI.GetScale 必须为有限正数")
        local ending = kind == PointerEvent.Types.PointerUp or kind == PointerEvent.Types.PointerCancel
        local event = PointerEvent.new(kind, {
            pointerId = id, pointerType = PointerEvent.PointerTypes.Touch,
            isPrimary = primary, x = x * scale, y = y * scale,
            button = PointerEvent.Button.Left,
            buttons = ending and PointerEvent.Buttons.None or PointerEvent.Buttons.Primary,
            pressure = ending and 0 or 0.5,
        })
        -- 先登记，确保事件中途 assert 时 finally 仍能发送 cancel。
        if not ending then active[id] = {x = x, y = y, isPrimary = primary} end
        UI.HandlePointerEvent(event)
        if ending then active[id] = nil end
        return event
    end
    ---@param widget Widget
    local function rect(widget)
        local l = widget:GetAbsoluteLayout()
        check(l.w > 0 and l.h > 0 and l.x == l.x and l.y == l.y
            and l.w < math.huge and l.h < math.huge, "控件布局未完成或尺寸无效")
        return l
    end
    ---@param widget Widget
    local function point(widget, fx, fy)
        local l = rect(widget)
        return l.x + l.w * fx, l.y + l.h * fy
    end
    ---@param event PointerEvent
    ---@param widget Widget
    local function hit(event, widget, x, y)
        local l = rect(widget)
        check(event.target == widget and event.currentTarget == widget,
            "必须真实命中父 zone，不能命中子标签后靠冒泡碰巧触发")
        -- 当前 UI 的 screenToWidgetLocal 只撤销 transform，并不减布局原点。
        -- 这些 zone 没有祖先 transform，事件保留基准像素绝对坐标；Controls 回调
        -- 必须减 zone:GetAbsoluteLayout().x 后再映射转向，后续左右舵断言验证该链路。
        check(near(event.x, x) and near(event.y, y),
            "UI 必须把物理像素按 GetScale 还原为基准像素坐标")
        check(near(event.x - l.x, x - l.x) and near(event.y - l.y, y - l.y),
            "相对父 zone 的坐标必须包含实际绝对布局偏移")
    end
    ---@param widget Widget
    local function down(widget, id, fx, fy, primary)
        local x, y = point(widget, fx, fy)
        local event = send(PointerEvent.Types.PointerDown, id, x, y, primary)
        hit(event, widget, x, y)
        check(event:IsTouch() and event.isPrimary == primary, "触摸类型/主次手标记不能丢失")
        return x, y
    end
    local function finish(kind, id)
        local p = assert(active[id], "[MobileChecks] 缺少测试指针")
        return send(kind, id, p.x, p.y, p.isPrimary)
    end
    local function zero(message)
        local released = controls.steer == 0 and controls.throttle == 0
        for key, owner in pairs(controls.pointers) do
            if owner ~= -1 or (key ~= "steer" and controls[key] == true) then released = false end
        end
        check(released, message)
    end
    ---@param widget Widget
    local function click(widget)
        UI.Layout()
        local x, y = down(widget, THIRD, 0.5, 0.5, true)
        hit(finish(PointerEvent.Types.PointerUp, THIRD), widget, x, y)
    end
    local function radioSynced()
        local title = sound:GetTrackTitle()
        local expected = assert(sound.Tracks[sound.trackIndex], "[MobileChecks] 当前曲目索引无效")
        check(title == expected.title and hud.radioTitle.props.text == title, "电台曲目标题未随选曲同步")
        local text = sound.musicEnabled and "音乐 开" or "音乐 关"
        check(hud.radioToggle.props.text == (sound.musicEnabled and "暂停" or "播放") and hud.musicButton.props.text == text,
            "电台与暂停页音乐按钮文字必须同时同步")
    end
    local function sourcesUnchanged()
        local count = 0
        for index, source in pairs(sound.sources) do
            check(index >= 1 and index <= 6 and originalSources[index] == source,
                "只能复用原有六个 SoundSource：" .. tostring(index))
            count = count + 1
        end
        check(count == 6, "八个 Sound 必须仍然只有六个 SoundSource")
        for index = 1, 6 do
            check(sound.sources[index] == originalSources[index] and sound.sources[index] ~= nil,
                "切歌或开关不得重建原 SoundSource：" .. index)
        end
        check(sound.sources[7] == nil and sound.sources[8] == nil, "额外两首歌曲不得创建 SoundSource")
    end
    ---@return table<number, MobileCheckSourceState>
    local function snapshotEffects()
        ---@type table<number, MobileCheckSourceState>
        local states = {}
        for index = 2, 6 do
            local source = assert(sound.sources[index])
            states[index] = {source = source, sample = source.sound, gain = source.gain,
                frequency = source.frequency, pitch = sound.pitches[index], playing = source.playing}
        end
        return states
    end
    ---@param states table<number, MobileCheckSourceState>
    local function effectsUnchanged(states)
        for index = 2, 6 do
            local before = assert(states[index])
            local source = assert(sound.sources[index])
            check(source == before.source and source.sound == before.sample and source.gain == before.gain
                and source.frequency == before.frequency and source.playing == before.playing
                and sound.pitches[index] == before.pitch, "电台操作不得改变音效通道：" .. index)
        end
        sourcesUnchanged()
    end

    -- 用 pcall + 独立清理保证失败同样恢复现场，随后 assert 重新抛出失败。
    local ok, failure = pcall(function()
        hud:SetRace(nil)
        hud:SetScreen("ride")
        UI.Layout()
        zero("开始测试前输入必须为零")
        rect(steering); rect(gas); rect(brake)
        local viewportW, viewportH = UI.GetViewportSize()
        hud:UpdateCockpit(viewportW * 0.5, viewportH * 0.5, true, 88, 3, 6200)
        UI.Layout()
        local cockpit = rect(hud.cockpit)
        local expectedY = viewportH * 0.5 - 38
        -- Yoga 按物理像素栅格取整；GetAbsoluteLayout 是实际布局，不能按 props 精确到 .01 比较。
        -- 单个边界最多半物理像素，宽高是两个边界之差，允许一个物理像素；另含 .25 基准像素定位缓存。
        local pixel = 1 / UI.GetScale()
        local sizeTolerance, positionTolerance = pixel + 0.01, pixel * 0.5 + 0.26
        print(string.format("[MobileChecks] cockpit actual=(%.4f,%.4f %.4fx%.4f) expected=(%.4f,%.4f 154x76) props=(%.4f,%.4f) scale=%.4f tolerance(size=%.4f,pos=%.4f)",
            cockpit.x, cockpit.y, cockpit.w, cockpit.h, viewportW * 0.5 - 77, expectedY,
            hud.cockpit.props.left, hud.cockpit.props.top, UI.GetScale(), sizeTolerance, positionTolerance))
        check(math.abs(cockpit.w - 154) <= sizeTolerance and math.abs(cockpit.h - 76) <= sizeTolerance
            and math.abs(cockpit.x - (viewportW * 0.5 - 77)) <= positionTolerance
            and math.abs(cockpit.y - expectedY) <= positionTolerance,
            "赛车座舱154×76仪表必须以投影中心对齐（允许物理像素栅格取整）")
        for _, widget in ipairs({hud.cockpitSpeed, hud.cockpitGear, hud.cockpitRPM}) do
            local child = rect(widget)
            check(child.x >= cockpit.x and child.y >= cockpit.y
                and child.x + child.w <= cockpit.x + cockpit.w + 0.01
                and child.y + child.h <= cockpit.y + cockpit.h + 0.01,
                "座舱仪表读数必须完整落在仪表内，不能被行 padding 挤出")
        end
        hud.cockpit:SetVisible(false)
        UI.Layout()
        passed("实际 HUD / 布局 / 触摸入口就绪，仪表行无溢出")

        down(steering, LEFT, 0.5, 0.5, true)
        check(near(controls.steer, 0), "方向中心必须是零：不能把屏幕绝对 X 当作 zone 局部 X")
        local localX, localY = point(steering, 0.25, 0.5)
        hit(send(PointerEvent.Types.PointerMove, LEFT, localX, localY, true), steering, localX, localY)
        check(near(controls.steer, expectedSteer(0.25)),
            "四分之一位置必须按父 zone 局部坐标产生渐进非饱和左舵")
        finish(PointerEvent.Types.PointerCancel, LEFT)
        zero("局部坐标测试取消后必须回正")
        passed("父 zone 局部坐标：中心零舵与四分之一非饱和左舵")

        down(steering, LEFT, 0.5, 0.5, true)
        local smallX, smallY = point(steering, 0.60, 0.5)
        send(PointerEvent.Types.PointerMove, LEFT, smallX, smallY, true)
        check(math.abs(controls.steer - 0.028773304368) < 0.000001 and controls.steer > 0 and controls.steer < 0.035,
            "轻滑方向区宽度10%只应产生约2.9%小舵量")
        local gentle = Simulation.New({Goals = {}, RouteLength = 0,
            RoadPoint = function(s) return {x = 0, y = 0, z = s}, 0 end,
            Height = function() return 0, true end,
            NearestRoad = function(x, z) return z, x end})
        local gentleWorld = {traffic = {}, Surface = function() return 0, true, "高速轻滑验收" end}
        local startX, startZ = gentle.x, gentle.z
        gentle.heading, gentle.yaw, gentle.speed = 0, 0, 60
        for _ = 1, 50 do
            gentle:Step(0.02, {steer = controls.steer, throttle = 0}, gentleWorld)
        end
        check(math.abs(gentle.x - startX) < 0.15 and math.abs(gentle.heading) < 0.4
            and gentle.z - startZ > 40,
            "真实UI轻滑→仿真：216km/h持续1秒应稳定向前，不得突然大幅横移")
        print(string.format("[转向验收] 真实UI位移10%%，舵量=%.6f，初速216km/h，1秒横移=%.4fm、偏航=%.4f°、前进=%.2fm",
            controls.steer, gentle.x - startX, gentle.heading, gentle.z - startZ))
        finish(PointerEvent.Types.PointerCancel, LEFT)
        for _, edge in ipairs({{0.08, -1}, {0.92, 1}}) do
            down(steering, LEFT, edge[1], 0.5, true)
            check(near(controls.steer, edge[2]), "方向区两端仍必须能到完整左右舵")
            finish(PointerEvent.Types.PointerCancel, LEFT)
        end
        zero("低敏与完整行程测试结束必须回正")
        passed("真实UI轻滑低敏→高速稳定前进，两端保留完整左右舵")

        down(steering, LEFT, 0.12, 0.5, true)
        check(near(controls.steer, -0.892488102776) and controls.pointers.steer == LEFT, "左手位置应产生渐进左舵")
        local heldSteer = controls.steer
        down(gas, RIGHT, 0.5, 0.85, false)
        check(controls.gas and controls.pointers.gas == RIGHT and near(controls.steer, heldSteer)
            and controls.pointers.steer == LEFT, "非主指针油门与左手方向必须并行")
        passed("双指并行：左方向 + 右油门（isPrimary=false）")
        finish(PointerEvent.Types.PointerUp, RIGHT)
        check(not controls.gas and controls.pointers.gas == -1 and near(controls.steer, heldSteer)
            and controls.pointers.steer == LEFT, "释放右手必须保留左手方向")
        passed("释放右手不清除左手")

        local l = rect(steering)
        -- 明确离开方向 zone 的右上边界，但仍在实际屏幕内。
        local outsideX, outsideY = l.x + l.w + 30, l.y - 25
        local moveCount = #steerMoves
        send(PointerEvent.Types.PointerMove, LEFT, outsideX, outsideY, true)
        check(#steerMoves == moveCount + 1, "滑出 zone 后必须仍收到捕获 move")
        local captured = assert(steerMoves[moveCount + 1], "[MobileChecks] 缺少捕获 move")
        hit(captured, steering, outsideX, outsideY)
        check(controls.steer == 1 and controls.pointers.steer == LEFT,
            "滑出 zone 后仍由原左手控制并夹紧右满舵")
        finish(PointerEvent.Types.PointerUp, LEFT)
        zero("滑出后释放仍必须归零并解除所有权")
        passed("滑出控件的 move/up 捕获及局部坐标")

        down(steering, LEFT, 0.88, 0.5, true)
        down(gas, RIGHT, 0.5, 0.85, false)
        finish(PointerEvent.Types.PointerCancel, RIGHT)
        check(not controls.gas and near(controls.steer, 0.892488102776) and controls.pointers.steer == LEFT,
            "取消右手只应释放油门")
        finish(PointerEvent.Types.PointerCancel, LEFT)
        zero("cancel 必须回正并清除指针所有权")
        passed("PointerCancel 分手释放与回正")

        down(steering, LEFT, 0.12, 0.5, true)
        down(brake, RIGHT, 0.5, 0.85, false)
        check(controls.brake and not controls.gas and near(controls.steer, -0.892488102776)
            and controls.pointers.brake == RIGHT and controls.pointers.steer == LEFT,
            "刹车和转向必须支持非主指针并行")
        finish(PointerEvent.Types.PointerUp, RIGHT)
        check(not controls.brake and near(controls.steer, -0.892488102776), "松开刹车不得取消转向")
        finish(PointerEvent.Types.PointerCancel, LEFT)
        zero("刹车并行测试结束必须归零")
        passed("刹车 + 转向并行及独立释放")

        down(steering, LEFT, 0.12, 0.5, true)
        down(gas, RIGHT, 0.5, 0.85, false)
        down(nitro, THIRD, 0.5, 0.5, false)
        local held = controls:ConsumeActions()
        check(held.nitro and held.gas and near(held.steer, -0.892488102776),
            "方向、油门、氮气必须经真实UI支持三指并行")
        check(controls:ConsumeActions().nitro, "消费输入不能清除保持氮气")
        finish(PointerEvent.Types.PointerCancel, THIRD)
        check(not controls.nitro and controls.gas and near(controls.steer, -0.892488102776),
            "取消氮气必须保留方向与油门")
        down(wheelieZone, THIRD, 0.5, 0.5, false)
        check(controls.wheelie and controls.gas and controls.steer < 0, "翘头必须与油门/转向三指并行")
        finish(PointerEvent.Types.PointerUp, THIRD)
        check(not controls.wheelie and controls.gas and controls.steer < 0, "松开翘头不得影响双手输入")
        finish(PointerEvent.Types.PointerCancel, LEFT)
        finish(PointerEvent.Types.PointerCancel, RIGHT)
        zero("三指氮气和拳套测试后必须清空输入")
        passed("真实图片按钮三指并行、氮气保持、翘头独立释放")

        check(controls.widgets.wheelie ~= nil and controls.widgets.burnout ~= nil,
            "驾驶HUD必须恢复翘头和烧胎按钮，不能只保留隐藏输入字段")
        check(controls.widgets.clutch == nil and controls.widgets.shiftUp == nil and controls.widgets.shiftDown == nil,
            "实际 HUD 不应创建已移除的驾驶控件")
        check(hud.toolsPanel:IsVisible() and hud.toolTray:IsVisible(), "自由练习必须保留次要旋转特技")
        local flat = {Goals = {}, RouteLength = 0,
            RoadPoint = function(s) return {x = 0, y = 0, z = s}, 0 end,
            Height = function() return 0, true end,
            NearestRoad = function(x, z) return z, x end}
        local flatWorld = {traffic = {}, landscape = flat, Surface = function() return 0, true, "平地验收" end}
        local simulation = Simulation.New(flat)
        -- Preserve UI->gameplay coverage for the replacement actions, not just booleans.
        -- Race validates loop closure/checkpoints; reuse the actual closed main route.
        local raceMap = require("Landscape")
        local raceSim = Simulation.New(raceMap)
        local race = Race.New(raceMap, raceSim, {laps = 2, quiet = true})
        race:Start()
        race.phase = "racing"
        raceSim.speed, race.player.speed = 12, 12
        hud:SetRace(race)
        UI.Layout()
        check(hud.toolsPanel:IsVisible() and hud.toolTray:IsVisible(), "竞速也必须显示翘头、烧胎、180°和360°特技")
        for _, key in ipairs({"wheelie", "burnout"}) do
            down(assert(controls.widgets[key]), LEFT, 0.5, 0.5, true)
            local drive = race:BeforeStep(0.02, controls:ConsumeActions())
            check(drive[key] == true and controls[key], "比赛真实UI保持特技不得被规则屏蔽：" .. key)
            check(controls:ConsumeActions()[key], "消费输入不得取消特技保持：" .. key)
            finish(PointerEvent.Types.PointerCancel, LEFT)
            check(not controls[key], "取消指针必须释放特技：" .. key)
        end
        for _, key in ipairs({"spin180", "spin360"}) do
            down(assert(controls.widgets[key]), LEFT, 0.5, 0.5, true)
            finish(PointerEvent.Types.PointerUp, LEFT)
            local drive = race:BeforeStep(0.02, controls:ConsumeActions())
            check(drive[key] == true, "比赛实际旋转输入不得被规则吞掉：" .. key)
            check(not controls:ConsumeActions()[key], "比赛旋转只能消费一次：" .. key)
        end
        down(nitro, LEFT, 0.5, 0.5, true)
        local boostInput = race:BeforeStep(0.02, controls:ConsumeActions())
        check(boostInput.boost == 1 and race.player.nitro == 55 and race.player.boostTimer > 0,
            "真实氮气UI快照必须消耗45资源并启动Race加速")
        for _ = 1, 8 do race:BeforeStep(0.02, controls:ConsumeActions()) end
        check(race.player.nitro == 55 and controls.nitro, "同次保持不能重复消费45氮气")
        finish(PointerEvent.Types.PointerCancel, LEFT)
        race:BeforeStep(0.02, controls:ConsumeActions())
        check(not race.player.boostLock and not controls.nitro, "取消真实指针必须解除Race氮气保持锁")
        -- 不再有主动攻击：真实对手在同侧也无法被玩家推撞减速。
        local victim = assert(race.racers[1])
        check(victim ~= race.player and not victim.isPlayer, "验证对象必须是真实非玩家对手")
        race.player.x, race.player.y, race.player.z, race.player.yaw, race.player.speed = 0, 0, 0, 0, 12
        victim.x, victim.y, victim.z, victim.yaw, victim.speed, victim.immunity = 1, 0, 0, 0, 12, 0
        down(wheelieZone, LEFT, 0.5, 0.5, true)
        race:BeforeStep(0.02, controls:ConsumeActions())
        finish(PointerEvent.Types.PointerUp, LEFT)
        check(victim.speed == 12 and victim.immunity == 0, "翘头不得对对手造成任何推撞减速")
        race.player.boostTimer, race.player.boostLock, race.player.nitro = 0, false, 100
        raceSim.braking, raceSim.burnout, raceSim.airborne = false, false, false
        down(nitro, LEFT, 0.5, 0.5, true)
        finish(PointerEvent.Types.PointerUp, LEFT)
        check(not controls.nitro, "快速点按抬手后应解除保持，但保留一次排队激活")
        local fastTap = controls:ConsumeActions()
        check(fastTap.nitro and not controls:ConsumeActions().nitro, "帧间氮气快点必须恰好排队一次")
        local fastDrive = race:BeforeStep(0.02, fastTap)
        check(fastDrive.boost == 1 and race.player.nitro == 55, "真实氮气快点必须启动动力且仅扣45点")
        down(nitro, LEFT, 0.5, 0.5, true)
        finish(PointerEvent.Types.PointerCancel, LEFT)
        check(not controls:ConsumeActions().nitro, "系统取消应丢弃未消费氮气请求，不能误喷射")
        hud:SetRace(nil)
        hud:SetScreen("ride")
        UI.Layout()
        check(hud.toolsPanel:IsVisible(), "恢复练习必须恢复旋转特技")
        zero("真实UI→Race验证结束必须释放所有捕获")
        passed("真实图片UI→Race：45氮气资源、保持锁、翘头不伤对手与比赛特技可见")

        -- 从实际Landscape路点找普通弯和最紧回头弯，测试驾驶输入而非把车贴回中心线。
        local landscape = require("Landscape")
        local function delta(a, b) return (a - b + 180) % 360 - 180 end
        local ordinaryS, tightS, maximumCurvature = 0, 0, 0
        for s = 8, landscape.RouteLength - 8, 4 do
            local a, b, c = landscape.RoadPoint(s - 4), landscape.RoadPoint(s), landscape.RoadPoint(s + 4)
            local curvature = math.abs(delta(math.deg(math.atan(c.x - b.x, c.z - b.z)),
                math.deg(math.atan(b.x - a.x, b.z - a.z)))) * math.pi / 180 / 4
            if curvature > maximumCurvature then tightS, maximumCurvature = s, curvature end
            if ordinaryS == 0 and curvature > 0.009 and curvature < 0.012 then ordinaryS = s end
        end
        check(ordinaryS > 0 and maximumCurvature > 0.04,
            "必须从真实地图找到半径约100米普通弯与半径数十米以内回头弯，不能空测直道")
        for _, id in ipairs({"sport", "cruiser", "rally"}) do
            for _, bend in ipairs({{ordinaryS, 32, 90}, {tightS, 14, 75}}) do
                local route = Simulation.New(landscape)
                route:SetVehicle(id)
                local start = bend[1] - 24
                local p, yaw = landscape.RoadPoint(start)
                route.x, route.z, route.y, route.heading, route.yaw, route.speed = p.x, p.z, p.y, yaw, yaw, bend[2]
                route:UpdateNavigation(route.x, route.z, nil, false)
                local traveled, maxLateral, maxSteer, usedAssist = 0, 0, 0, false
                local roadWorld = {landscape = landscape, traffic = {}}
                down(steering, LEFT, 0.5, 0.5, true)
                down(gas, RIGHT, 0.5, 0.85, false)
                for _ = 1, 600 do
                    local lookahead = math.max(5, math.min(14, route.speed * 0.48))
                    local target = landscape.RoadPoint(route.roadS + lookahead)
                    local desiredYaw = math.deg(math.atan(target.x - route.x, target.z - route.z))
                    local desiredTurn = 2 * route.speed * math.sin(delta(desiredYaw, route.heading) * math.pi / 180)
                        / lookahead * 180 / math.pi
                    local low, high = 0.0, 1.0
                    for _ = 1, 12 do
                        local mid = (low + high) * 0.5
                        if route:TurnRate(mid) < math.abs(desiredTurn) then low = mid else high = mid end
                    end
                    local sign = desiredTurn < 0 and -1 or 1
                    local lo, hi = 0.5, 0.92
                    for _ = 1, 12 do
                        local mid = (lo + hi) * 0.5
                        if expectedSteer(mid) < (low + high) * 0.5 then lo = mid else hi = mid end
                    end
                    local x, y = point(steering, 0.5 + sign * ((lo + hi) * 0.5 - 0.5), 0.5)
                    send(PointerEvent.Types.PointerMove, LEFT, x, y, true)
                    local before = route.distance
                    route:Step(0.02, controls:ConsumeActions(), roadWorld)
                    traveled = traveled + route.distance - before
                    maxLateral, maxSteer = math.max(maxLateral, math.abs(route.lateral)), math.max(maxSteer, math.abs(controls.steer))
                    usedAssist = usedAssist or route.cornerAssist > 0
                    if traveled >= bend[3] then break end
                end
                check(traveled >= bend[3] and maxLateral < 4.8 and route.health == 100,
                    id .. " 真实道路中外行程应驶过普通弯/回头弯，不能靠吸附道路或无限降低车速通过")
                check(maxSteer > 0.28 and route.speed > 9, id .. " 道路弯道必须实际用到中外舵并保持可骑速度")
                print(string.format("[弯道验收] %s s=%.1f 初速=%.1fkm/h 路程=%.1fm 最大偏离=%.3fm 最大舵=%.3f 末速=%.1fkm/h 辅助=%s κmax=%.4f",
                    id, bend[1], bend[2] * 3.6, traveled, maxLateral, maxSteer, route.speed * 3.6, tostring(usedAssist), maximumCurvature))
                finish(PointerEvent.Types.PointerCancel, LEFT)
                finish(PointerEvent.Types.PointerCancel, RIGHT)
                local heading = route.heading
                for _ = 1, 35 do route:Step(0.02, controls:ConsumeActions(), roadWorld) end
                check(math.abs(route.steer) < 0.001 and math.abs(delta(route.heading, heading)) < 4,
                    id .. " 弯道松手必须平滑回正，无反向蛇形或残留满舵")
            end
        end
        zero("三车型真实道路转向测试后必须释放全部指针")
        passed("真实Landscape曲率→三车型普通山路弯/最紧回头弯→UI滑动+油门→Sim道路内转弯/松手回正")
        for _, key in ipairs({"spin180", "spin360"}) do
            simulation:Reset(false)
            simulation.speed = 6 -- 21.6 km/h；普通自由骑行，不依赖坡道或挑战模式。
            down(assert(controls.widgets[key]), LEFT, 0.5, 0.5, true)
            finish(PointerEvent.Types.PointerUp, LEFT)
            local pulse = controls:ConsumeActions()
            check(pulse[key] == true, "短点按后必须保留脉冲：" .. key)
            check(controls:ConsumeActions()[key] == false, "脉冲必须且只能消费一次：" .. key)
            simulation:Step(0.02, pulse, flatWorld)
            local degrees = key == "spin180" and 180 or 360
            check(simulation.airborne and simulation.y > 0 and simulation.vY > 0
                and simulation.spinTarget == degrees and not simulation.challenge,
                key .. " 实际 UI 点按结果必须在普通模式平地产生辅助起跳和目标旋转")
            simulation:Reset(false)
            simulation.speed = 2
            down(assert(controls.widgets[key]), LEFT, 0.5, 0.5, true)
            finish(PointerEvent.Types.PointerUp, LEFT)
            simulation:Step(0.02, controls:ConsumeActions(), flatWorld)
            check(not simulation.airborne and simulation.y == 0 and simulation.spinTarget == 0
                and simulation.message == "加速到15km/h再点特技" and simulation.messageTimer > 0,
                key .. " 低速点按必须不跳转且保留明确加速提示供 HUD 显示")
        end
        passed("常驻腾跃180°/360°真实UI事件→单次脉冲→普通模式平地起跳/低速提示")

        -- 遍历真实图片、几何和短标签的命中区域；中文标签负责辨识，不替代真实图片。
        local function graphics(zone, key, expectedImage)
            local count, found = 0, expectedImage == nil
            local function visit(widget)
                for _, child in ipairs(widget:GetChildren()) do
                    check(child.props.pointerEvents == "none", key .. " 图片/几何/标签子控件必须穿透指针")
                    if child.props.text ~= nil then
                        check(type(child.props.text) == "string" and child.props.text ~= "", key .. " 操作说明不能是空标签")
                    end
                    if child.props.backgroundImage == expectedImage and expectedImage then found = true end
                    local visual = UI.GetVisualRect(child)
                    check(visual.w > 0 and visual.h > 0, key .. " 图形子控件布局无效")
                    local x, y = visual.x + visual.w / 2, visual.y + visual.h / 2
                    local event = send(PointerEvent.Types.PointerDown, LEFT, x, y, true)
                    hit(event, zone, x, y)
                    check(controls.pointers[key] == LEFT, key .. " 图形位置必须真实命中父zone")
                    if key ~= "steer" then check(controls[key] == true, key .. " 图形位置未按下操作") end
                    -- 按下反馈会把按钮向下平移2px；Cancel派发先撤销该变换，
                    -- 再由回调复原样式，因此必须在派发前记录预期局部坐标。
                    local cancelX = x - (zone.props.translateX or 0)
                    local cancelY = y - (zone.props.translateY or 0)
                    hit(finish(PointerEvent.Types.PointerCancel, LEFT), zone, cancelX, cancelY)
                    if key == "spin180" or key == "spin360" then
                        check(controls:ConsumeActions()[key] == true, key .. " 图形位置必须产生脉冲")
                        check(controls:ConsumeActions()[key] == false, key .. " 图形脉冲只能消费一次")
                    end
                    zero("图形子控件取消后必须归零：" .. key)
                    count = count + 1
                    visit(child)
                end
            end
            visit(zone)
            check(found and count > 0, key .. " 必须验证真实图形且不可空通过")
            result.labels = result.labels + count -- Legacy report field now counts visual child hit sites.
            passed(key .. " 全部图形位置命中父zone（" .. count .. " 个）")
        end
        graphics(steering, "steer")
        graphics(gas, "gas", Controls.Images.gas)
        graphics(brake, "brake", Controls.Images.brake)
        graphics(nitro, "nitro", Controls.Images.nitro)
        graphics(assert(controls.widgets.wheelie), "wheelie")
        graphics(assert(controls.widgets.burnout), "burnout")
        graphics(assert(controls.widgets.spin180), "spin180")
        graphics(assert(controls.widgets.spin360), "spin360")

        down(steering, LEFT, 0.12, 0.5, true)
        down(gas, RIGHT, 0.5, 0.85, false)
        down(nitro, THIRD, 0.5, 0.5, false)
        local moveX, moveY = point(steering, 0.88, 0.5)
        local blockedPoints = {}
        for _, zone in ipairs({steering, gas, brake, nitro,
            assert(controls.widgets.wheelie), assert(controls.widgets.burnout),
            assert(controls.widgets.spin180), assert(controls.widgets.spin360)}) do
            local x, y = point(zone, 0.5, 0.5)
            blockedPoints[#blockedPoints + 1] = {zone = zone, x = x, y = y}
        end
        -- Queue a real fast-tap pulse while leaving steer/gas/nitro held.
        finish(PointerEvent.Types.PointerUp, RIGHT)
        down(wheelieZone, RIGHT, 0.5, 0.5, false)
        down(gas, RIGHT, 0.5, 0.85, false)
        check(controls.wheelie and controls.nitro and controls.gas and controls.pointers.steer == LEFT,
            "暂停前必须实际存在氮气保持、翘头保持和双手输入")
        hud:SetScreen("pause")
        UI.Layout()
        check(hud.pause:IsVisible() and not controls.enabled, "暂停页必须显示并禁用操控")
        zero("暂停必须清除已按住的双手输入")
        -- 暂停隐藏操控区后Yoga布局可归零，因此使用按下时的实际屏幕位置。
        send(PointerEvent.Types.PointerMove, LEFT, moveX, moveY, true)
        zero("暂停后旧捕获 move 不得恢复转向")
        finish(PointerEvent.Types.PointerCancel, LEFT)
        finish(PointerEvent.Types.PointerCancel, RIGHT)
        finish(PointerEvent.Types.PointerCancel, THIRD)
        for _, p in ipairs(blockedPoints) do
            local event = send(PointerEvent.Types.PointerDown, THIRD, p.x, p.y, false)
            check(event.target ~= p.zone, "暂停遮罩必须阻止点击穿透驾驶 zone")
            zero("暂停时新触摸不得产生驾驶输入")
            finish(PointerEvent.Types.PointerCancel, THIRD)
        end
        passed("暂停清空、旧捕获禁用、新触摸遮挡")

        hud:SetScreen("ride")
        UI.Layout()
        check(controls.enabled and not hud.pause:IsVisible(), "恢复骑行必须重新启用操控")
        down(steering, LEFT, 0.88, 0.5, true)
        down(gas, RIGHT, 0.5, 0.85, false)
        check(near(controls.steer, 0.892488102776) and controls.gas, "恢复后双指必须重新可用")
        finish(PointerEvent.Types.PointerCancel, RIGHT)
        finish(PointerEvent.Types.PointerCancel, LEFT)
        zero("恢复可用性测试后输入必须归零")
        passed("恢复后双指重新可用")

        check(sound.Count == 8 and #sound.Resources == 8, "必须检查完整的八项音频清单")
        sourcesUnchanged()
        for index = 1, 8 do
            local sample = assert(sound.sounds[index], "[MobileChecks] 未载入 Sound " .. index)
            local path = assert(sound.Resources[index], "[MobileChecks] 音频资源路径缺失：" .. index)
            local frequency, duration = sample:GetFrequency(), sample:GetLength()
            check(frequency > 0 and frequency < math.huge, "Sound 采样率无效：" .. index)
            check(duration > 0 and duration < math.huge, "Sound 时长无效：" .. index)
            if index <= 6 then
                local source = assert(sound.sources[index], "[MobileChecks] 缺少 SoundSource " .. index)
                check(source.soundType == (index == 1 and SOUND_MUSIC or SOUND_EFFECT), "音轨分组错误：" .. index)
            else
                check(sound.sources[index] == nil, "额外歌曲只保留 Sound，不能另建音源：" .. index)
            end
            result.sounds[index] = {path = path, frequency = frequency, duration = duration}
            print(string.format("[MobileChecks] PASS Sound %d/8 %s：%.0f Hz，%.3f s", index,
                path, frequency, duration))
        end
        check(#sound.Tracks == 3 and sound.Tracks[1].resource == 1
            and sound.Tracks[2].resource == 7 and sound.Tracks[3].resource == 8,
            "三首曲目必须依次对应资源 1、7、8")
        for _, track in ipairs(sound.Tracks) do
            local sample = assert(sound.sounds[track.resource])
            check(sample:IsCompressed() and sample:IsLooped(), "三首音乐都必须是有效压缩循环 Sound：" .. track.title)
            check(type(track.title) == "string" and #track.title > 0, "曲目标题不可为空")
        end
        passed("八个 Sound 有效、三曲压缩循环、仅六个原 SoundSource")

        hud:SetScreen("pause")
        UI.Layout()
        radioSynced()
        rect(hud.radioTitle)
        rect(previousButton); rect(nextButton); rect(hud.radioToggle)
        local function radioToggle()
            local before, effectsBefore, trackBefore = sound.musicEnabled, sound.effectsEnabled, sound.trackIndex
            local effectsState = snapshotEffects()
            click(hud.radioToggle)
            check(sound.musicEnabled == not before and sound.effectsEnabled == effectsBefore
                and sound.trackIndex == trackBefore, "电台开关只能切换音乐，不能联动音效或选曲")
            radioSynced()
            effectsUnchanged(effectsState)
            if not sound.musicEnabled then
                check(assert(sound.sources[1]).gain == 0, "电台关闭音乐必须立即静音")
            end
        end
        ---@param direction integer
        local function changeTrack(direction)
            local before = sound.trackIndex
            local musicBefore, effectsBefore = sound.musicEnabled, sound.effectsEnabled
            local expected = (before - 1 + direction) % 3 + 1
            local effectsState = snapshotEffects()
            click(direction == 1 and nextButton or previousButton)
            check(sound.trackIndex == expected, "实际上一首/下一首按钮未正确切换或边界未循环")
            check(sound.musicEnabled == musicBefore and sound.effectsEnabled == effectsBefore,
                "切歌不能改变音乐/音效开关，静音选曲不得取消静音")
            radioSynced()
            effectsUnchanged(effectsState)
            local musicSource = assert(sound.sources[1])
            if not musicBefore then
                check(musicSource.gain == 0 and not musicSource.playing, "静音切歌不得启动音乐或恢复音量")
            elseif musicSource.playing then
                -- -nosound 或尚未解锁时不强求 playing；若播放则必须是所选 Sound。
                local track = assert(sound.Tracks[expected])
                local selected = assert(sound.sounds[track.resource])
                check(musicSource.sound == selected and near(musicSource.frequency, selected:GetFrequency()),
                    "复用的音乐音源必须绑定所选歌曲及其采样率")
            end
            zero("电台按钮不得触发驾驶输入")
        end
        if not sound.musicEnabled then radioToggle() end
        -- 从任意原曲目走完整圈，必然覆盖 3 -> 1 与 1 -> 3 两个边界。
        for _ = 1, 3 do changeTrack(1) end
        check(sound.trackIndex == oldTrackIndex, "下一首三次必须回到原曲目")
        for _ = 1, 3 do changeTrack(-1) end
        check(sound.trackIndex == oldTrackIndex, "上一首三次必须回到原曲目")
        passed("实际电台按钮：三曲上一首/下一首、双向边界循环、标题同步、音乐音源复用")
        radioToggle()
        for _ = 1, 3 do changeTrack(1) end
        for _ = 1, 3 do changeTrack(-1) end
        radioToggle()
        check(sound.trackIndex == oldTrackIndex and sound.musicEnabled, "恢复音乐不得改变静音期间所选曲目")
        passed("实际电台开关：静音双向切歌不复播、不改音效、恢复文字同步")
        -- 在资源 7/8 上分别切换音效，防止误把新增歌曲当作音效通道 7/8。
        for target = 2, 3 do
            for _ = 1, 2 do
                if sound.trackIndex ~= target then changeTrack(1) end
            end
            check(sound.trackIndex == target, "必须实际选中新增歌曲后检查音效开关")
            hud:SetScreen("pause")
            UI.Layout()
            local musicSource = assert(sound.sources[1])
            local musicGain, musicSample = musicSource.gain, musicSource.sound
            local musicFrequency, musicPlaying = musicSource.frequency, musicSource.playing
            local before = sound.effectsEnabled
            for _ = 1, 2 do
                local effectsBefore = sound.effectsEnabled
                click(hud.effectsButton)
                check(sound.effectsEnabled == not effectsBefore and sound.musicEnabled and sound.trackIndex == target,
                    "新增歌曲播放时音效开关只应影响音效")
                check(musicSource.gain == musicGain and musicSource.sound == musicSample
                    and musicSource.frequency == musicFrequency and musicSource.playing == musicPlaying,
                    "音效开关不得中断或更改新增歌曲")
                sourcesUnchanged()
                radioSynced()
            end
            check(sound.effectsEnabled == before, "新增歌曲音效开关测试后必须恢复原值")
            -- Keep the pause page visible: radio transport is intentionally pause-only.
        end
        passed("新增两曲下实际切换音效仅作用于原通道 2..6")

        hud:SetScreen("pause")
        UI.Layout()
        local function music()
            local before, effectsBefore, trackBefore = sound.musicEnabled, sound.effectsEnabled, sound.trackIndex
            local effectsState = snapshotEffects()
            click(hud.musicButton)
            check(sound.musicEnabled == not before and sound.effectsEnabled == effectsBefore
                and sound.trackIndex == trackBefore, "音乐按钮只能切换音乐，不能联动音效或选曲")
            effectsUnchanged(effectsState)
            radioSynced()
            if not sound.musicEnabled then
                check(assert(sound.sources[1]).gain == 0, "关闭音乐必须立即静音")
            end
        end
        local function effects()
            local before, musicBefore, trackBefore = sound.effectsEnabled, sound.musicEnabled, sound.trackIndex
            local musicSource = assert(sound.sources[1])
            local musicGain, musicSample = musicSource.gain, musicSource.sound
            local musicFrequency, musicPlaying = musicSource.frequency, musicSource.playing
            click(hud.effectsButton)
            check(sound.effectsEnabled == not before and sound.musicEnabled == musicBefore
                and sound.trackIndex == trackBefore, "音效按钮只能切换音效，不能联动音乐或选曲")
            check(musicSource.gain == musicGain and musicSource.sound == musicSample
                and musicSource.frequency == musicFrequency and musicSource.playing == musicPlaying,
                "音效开关不得改变音乐音量、曲目或播放状态")
            sourcesUnchanged()
            radioSynced()
            check(hud.effectsButton.props.text == (sound.effectsEnabled and "音效 开" or "音效 关"), "音效按钮文字未同步")
            if not sound.effectsEnabled then
                for index = 2, 6 do
                    check(assert(sound.sources[index]).gain == 0, "关闭音效必须静音全部五条音效：" .. index)
                end
            end
        end
        if not sound.musicEnabled then music() end
        if not sound.effectsEnabled then effects() end
        -- 真正覆盖 开/开 -> 关/开 -> 关/关 -> 开/关 -> 开/开 四种组合。
        music(); effects(); music(); effects()
        -- 不要求 source.playing 为 true：-nosound/设备未解锁也必须允许上述测试通过。
        check(not sound.stopped and sound.node == oldNode and sound.scene == oldScene
            and sound.unlocked == oldUnlocked and sound.sounds == oldSounds and sound.sources == oldSources,
            "测试不得 Stop/Dispose/重建实际音频或改变用户解锁状态")
        for index = 1, 8 do
            local sample = assert(sound.sounds[index])
            local original = assert(result.sounds[index], "[MobileChecks] 缺少原始音频检查结果")
            check(sample == originalSounds[index] and near(sample:GetFrequency(), original.frequency)
                and near(sample:GetLength(), original.duration), "切换不得替换或改写 Sound 素材：" .. index)
        end
        passed("实际音频按钮独立开关四种组合（兼容 -nosound）")
    end)

    local cleaned, cleanupFailure = pcall(function()
        -- 逐个真实 cancel；不能仅 Reset，否则 UI 内部 pressedWidgets 仍遗留捕获。
        for _, id in ipairs({LEFT, RIGHT, THIRD}) do
            if active[id] then finish(PointerEvent.Types.PointerCancel, id) end
        end
        steering:OffEvent("pointermove", observeSteerMove)
        if sound.trackIndex ~= oldTrackIndex then sound:ChangeTrack(oldTrackIndex - sound.trackIndex) end
        if sound.musicEnabled ~= oldMusic then sound:ToggleMusic() end
        if sound.effectsEnabled ~= oldEffects then sound:ToggleEffects() end
        hud:SyncRadio(sound:GetTrackTitle(), sound.musicEnabled)
        hud.musicButton:SetText(oldMusicText)
        hud.effectsButton:SetText(oldEffectsText)
        hud.radioTitle:SetText(oldRadioTitle)
        hud.radioToggle:SetText(oldRadioToggleText)
        previousButton:SetText(oldPreviousText)
        nextButton:SetText(oldNextText)
        hud:SetRace(oldRace)
        hud:SetScreen(oldScreen)
        UI.Layout()
        UI.SetFocus(oldFocus)
        zero("清理后输入和指针所有权必须为零")
        check(not UI.Input.HasActivePointer(), "清理后UI内部不可遗留测试指针捕获")
        check(hud.screen == oldScreen and hud.race == oldRace
            and controls.enabled == (oldScreen == "ride" and not hud.portraitActive)
            and hud.game:IsVisible() == (oldScreen == "ride" or oldScreen == "pause" or oldScreen == "result")
            and hud.pause:IsVisible() == (oldScreen == "pause")
            and hud.menu:IsVisible() == (oldScreen == "menu")
            and hud.result:IsVisible() == (oldScreen == "result")
            and hud.loading:IsVisible() == (oldScreen == "loading"),
            "清理后必须恢复原HUD页面、真实Race引用与操控显隐")
        check(sound.musicEnabled == oldMusic and sound.effectsEnabled == oldEffects and sound.trackIndex == oldTrackIndex,
            "清理后必须恢复原曲目及音频开关")
        check(hud.musicButton.props.text == oldMusicText and hud.effectsButton.props.text == oldEffectsText
            and hud.radioTitle.props.text == oldRadioTitle and hud.radioToggle.props.text == oldRadioToggleText
            and previousButton.props.text == oldPreviousText and nextButton.props.text == oldNextText,
            "清理后必须恢复所有原按钮文字及电台标题")
        sourcesUnchanged()
    end)
    assert(ok, tostring(failure) .. (cleaned and "" or "；清理失败：" .. tostring(cleanupFailure)))
    assert(cleaned, "[MobileChecks] 清理失败：" .. tostring(cleanupFailure))
    passed("恢复原HUD页面/Race、零输入、音频原设置及焦点")
    result.passed = true
    print(string.format("[MobileChecks] 全部通过：%d 类，%d 条断言，%d 个图形命中点，%d 个 Sound",
        #result.groups, result.assertions, result.labels, #result.sounds))
    return result
end

return Checks
