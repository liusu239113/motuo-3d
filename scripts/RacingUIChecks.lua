-- UI 回归：只读真实档案，购买回调用计数替身，不写玩家金币/解锁/按键存档。
-- 入口 require("RacingUIChecks").Run(hud)，需在 UI 初始化后调用。
local UI = require("urhox-libs/UI")
local PointerEvent = require("urhox-libs/UI/Core/PointerEvent")
local Routes = require("RouteSelect")
local Checks = {}
local function demand(ok, message) assert(ok, "[RacingUIChecks] " .. message) end
local function inside(child, parent, tolerance)
    return child.x >= parent.x - tolerance and child.y >= parent.y - tolerance
        and child.x + child.w <= parent.x + parent.w + tolerance
        and child.y + child.h <= parent.y + parent.h + tolerance
end
local function visit(widget, fn)
    fn(widget)
    for _, child in ipairs(widget:GetChildren()) do visit(child, fn) end
end
-- 保留真实字体/真实 Yoga 测量，逐张卡检查所有文字与卡内祖先，不要求离屏卡落在滚动视口内。
function Checks.Layout(hud, width, height)
    local oldRoot, oldScreen = UI.GetRoot(), hud.screen
    local panel = hud.trackSelection
    local saved = {width = panel.props.width or "auto", height = panel.props.height or "auto",
        left = panel.props.left, top = panel.props.top, right = panel.props.right, bottom = panel.props.bottom}
    hud:OpenTracks()
    local holder = UI.Panel {width = width, height = height, padding = 0}
    panel:Remove(); holder:AddChild(panel)
    panel:SetStyle({width = width, height = height, left = 0, top = 0, right = 0, bottom = 0})
    hud:LayoutTracks(width, height)
    YGNodeCalculateLayout(holder.node, width, height, YGDirectionLTR)
    local count = 0
    local ok, failure = pcall(function()
        local metrics = Routes.Metrics(width, height)
        demand(metrics.columns <= 3 and metrics.cardWidth >= 300, "必须最多三列且每列不挤压正文")
        for _, card in pairs(hud.trackCards) do
            local bounds = card:GetAbsoluteLayout()
            demand(bounds.w >= 299 and bounds.h > 210, "路线卡必须有可读宽高")
            visit(card, function(child)
                if child._className == "Label" then
                    count = count + 1
                    local r, parent = child:GetAbsoluteLayout(), child.parent
                    demand(r.w > 0 and r.h >= 16, "文字必须有正尺寸且不能压扁")
                    demand((child.props.fontSize or 0) >= 9, "路线正文不得缩至不可读")
                    while parent and parent ~= card.parent do
                        demand(inside(r, parent:GetAbsoluteLayout(), 2), "文字超出卡内祖先：" .. tostring(child.props.text))
                        parent = parent.parent
                    end
                end
            end)
        end
        demand(count >= 42, "必须检查六张卡的真实文字节点")
    end)
    panel:Remove(); holder:Destroy()
    hud.safeContent:AddChild(panel)
    panel:SetStyle(saved)
    UI.SetRoot(oldRoot)
    hud.layoutWidth, hud.layoutHeight = -1, -1
    hud:SetScreen(oldScreen)
    hud:LayoutResponsive(); UI.Layout()
    demand(ok, tostring(failure))
    print(string.format("[RacingUIChecks] PASS %.0fx%.0f / %d文字节点包含性", width, height, count))
    return count
end
local function renderModal(modal)
    UI.Layout()
    modal:RenderModalContent(UI.GetNVGContext())
end
local function clickAt(x, y)
    local scale = UI.GetScale()
    for _, kind in ipairs({PointerEvent.Types.PointerDown, PointerEvent.Types.PointerUp}) do
        local ending = kind == PointerEvent.Types.PointerUp
        local event = PointerEvent.new(kind, {pointerId = 890001, pointerType = PointerEvent.PointerTypes.Touch,
            isPrimary = true, x = x * scale, y = y * scale, button = PointerEvent.Button.Left,
            buttons = ending and PointerEvent.Buttons.None or PointerEvent.Buttons.Primary, pressure = ending and 0 or 0.5})
        UI.HandlePointerEvent(event)
    end
end
local function click(widget)
    local rect = widget:GetAbsoluteLayout()
    demand(rect.w > 0 and rect.h > 0, "点击目标须完成真实布局")
    clickAt(rect.x + rect.w * 0.5, rect.y + rect.h * 0.5)
end
-- 菜单专项只构建 BuildMenu，不调用 HUD.New / Profile.Load / CareerSession。
-- 真实 Yoga、字体与指针分发；业务入口全部用计数替身，不碰玩家档案。
-- UI 初始化后可单独运行 require("RacingUIChecks").Menu(854, 480)。
function Checks.Menu(width, height)
    local HUD = require("HUD")
    local oldRoot = UI.GetRoot()
    local calls = {race = 0, practice = 0, settings = 0, career = 0, laps = 0}
    local fixture = setmetatable({screen = "menu", selectedLaps = 3, actions = {
        start = function(challenge)
            if challenge then calls.race = calls.race + 1 else calls.practice = calls.practice + 1 end
        end,
    }}, {__index = HUD})
    fixture.SetScreen = function(self, screen) self.screen = screen end
    fixture.SelectLaps = function(_, laps)
        demand(laps == 3, "赛事与练习须保留既有圈数")
        calls.laps = calls.laps + 1
    end
    fixture.OpenSettings = function() calls.settings = calls.settings + 1 end
    fixture:BuildMenu()
    -- 模拟 main.lua 事后追加返回入口，验证不改 main 仍能接入固定布局。
    local returnCallback = function() calls.career = calls.career + 1 end
    local returnButton = UI.Button {text = "← 返回王二狗生涯", width = 230, height = 42, onClick = returnCallback}
    fixture.menu:AddChild(returnButton)
    local holder = UI.Panel {width = width, height = height, padding = 0, children = {fixture.menu}}
    UI.SetRoot(holder)
    local textCount = 0
    local ok, failure = pcall(function()
        fixture:LayoutMenu(width, height)
        UI.Layout()
        demand(returnButton.parent == fixture.menuReturnHost and returnButton.props.onClick == returnCallback,
            "返回入口须复用原对象与原业务回调")
        demand(#fixture.menu:GetChildren() == 1, "追加返回入口不得挤占菜单外层高度")
        -- 连续两次真实渲染后再测量，捕捉字体加载/自适应换行造成的涨高。
        for _ = 1, 2 do
            visit(fixture.menu, function(widget)
                if widget:IsVisible() and (widget._className == "Label" or widget._className == "Button") then
                    widget:Render(UI.GetNVGContext())
                end
            end)
            UI.Layout()
        end
        visit(fixture.menu, function(widget)
            demand(widget._className ~= "ScrollView" and type(widget.GetScroll) ~= "function",
                "入口菜单不得有任何滚动容器")
            local text = widget.props.text
            if text then
                demand(not text:find("[A-Za-z]"), "菜单不得保留英文装饰：" .. text)
                demand(not text:find("九人竞速", 1, true) and not text:find("真实公路", 1, true),
                    "右侧无意义小字必须移除")
            end
        end)
        local function visibleBounds(widget)
            if not widget:IsVisible() then return end
            local bounds = widget:GetAbsoluteLayout()
            demand(bounds.w > 0 and bounds.h > 0, "可见菜单节点必须有完整尺寸")
            if widget.parent then
                local parentBounds = widget.parent:GetAbsoluteLayout()
                demand(inside(bounds, parentBounds, 2), string.format("菜单节点超出祖先：%s / %.1f,%.1f %.1fx%.1f / 父 %.1f,%.1f %.1fx%.1f",
                    tostring(widget.props.text or widget._className), bounds.x, bounds.y, bounds.w, bounds.h,
                    parentBounds.x, parentBounds.y, parentBounds.w, parentBounds.h))
            end
            if widget._className == "Label" or widget._className == "Button" then
                local props = widget.props
                local size = props.fontSize or 0
                local pixels = UI.Theme.FontSize(size)
                local textWidth = UI.MeasureTextWidth(props.text or "", pixels,
                    UI.Theme.FontFace(props.fontFamily, props.fontWeight), props.letterSpacing)
                local contentWidth = bounds.w - (props.paddingLeft or 0) - (props.paddingRight or 0)
                demand(size >= 14 and (props.minFontSize or 0) >= size, "菜单文字不得自动缩小为小字")
                demand(textWidth > 0 and textWidth <= contentWidth + 1, "真实字体完整文案不得横向越界：" .. tostring(props.text))
                demand(bounds.h >= pixels, "菜单文字高度不能被压扁")
                textCount = textCount + 1
            end
            for _, child in ipairs(widget:GetChildren()) do visibleBounds(child) end
        end
        visibleBounds(fixture.menu)
        local entries = {fixture.menuRaceButton, fixture.menuPracticeButton, fixture.menuSettingsButton, returnButton}
        local before = {}
        for index, entry in ipairs(entries) do
            demand(entry:IsVisible() and entry.props.fontSize == 18 and entry:GetAbsoluteLayout().h >= 55,
                "四个必要入口须始终完整显示且保持18pt大字与56高触摸区：" .. tostring(entry.props.text)
                    .. " / " .. tostring(entry:GetAbsoluteLayout().h))
            before[index] = entry:GetAbsoluteLayout()
        end
        for index, first in ipairs(before) do
            for other = index + 1, #before do
                local second = before[other]
                demand(first.x + first.w <= second.x + 1 or second.x + second.w <= first.x + 1
                    or first.y + first.h <= second.y + 1 or second.y + second.h <= first.y + 1,
                    "固定菜单入口不得重叠")
            end
        end
        for _, entry in ipairs(entries) do click(entry) end
        demand(calls.race == 1 and calls.practice == 1 and calls.settings == 1 and calls.career == 1 and calls.laps == 2,
            "赛事/自由练习/操作设置/返回生涯须各分发一次既有回调")
        for index, entry in ipairs(entries) do
            local after = entry:GetAbsoluteLayout()
            demand(after.x == before[index].x and after.y == before[index].y, "点击入口不得改变固定位置")
        end
        demand(fixture.menuGrid == (height < 440), "短横屏须切换固定两行而非缩字或滚动")
    end)
    UI.SetRoot(oldRoot)
    holder:Destroy()
    UI.Layout()
    demand(ok, tostring(failure))
    print(string.format("[RacingUIChecks] PASS 固定大字菜单 %.0fx%.0f / %d文字 / 四入口回调 / 无滚动越界", width, height, textCount))
    return textCount
end

function Checks.Dialogs(hud)
    local oldScreen = hud.screen
    hud:OpenTracks()
    local calls = 0
    local track = {id = "ui_check_only", name = "回归赛道", price = 1200, requires = "circuit"}
    local oldUnlock = hud.actions.unlockTrack
    local underneath = 0
    hud.actions.unlockTrack = function() underneath = underneath + 1 end
    local ok, failure = pcall(function()
        local modal = hud:ShowTrackLock(track, 200, function() calls = calls + 1; return true end)
        renderModal(modal)
        demand(hud:IsModalOpen() and UI.GetTopOverlay() == modal, "解锁必须处于真实模态栈")
        local footer = modal.footerWidget_:GetChildren()
        local purchase = footer[2] --[[@as Button]]
        demand(purchase:IsDisabled(), "金币不足必须禁用购买")
        click(purchase)
        demand(calls == 0, "不足时不能触发购买回调")
        local card = hud.trackCards.lake
        if card then click(card) end
        demand(underneath == 0 and hud.screen == "tracks", "遮罩必须阻断底层路线卡点击")
        click(footer[1])
        demand(not hud:IsModalOpen() and UI.GetTopOverlay() ~= modal, "取消必须移除覆盖且不购买")
        modal = hud:ShowTrackLock(track, 2000, function(id)
            demand(id == track.id, "确认回调参数必须是赛道id")
            calls = calls + 1
            return false, "测试失败提示，不写金币"
        end)
        renderModal(modal)
        footer = modal.footerWidget_:GetChildren()
        purchase = footer[2] --[[@as Button]]
        demand(not purchase:IsDisabled() and calls == 0, "够钱不能在展示时自动购买")
        click(purchase)
        demand(calls == 1 and purchase:IsDisabled(), "明确确认后只调用一次且锁定重复点击")
        click(purchase)
        demand(calls == 1, "连点不可重复扣款")
        hud:CloseModal()
        demand(not hud:IsModalOpen() and UI.GetTopOverlay() ~= modal, "失败后仍可关闭且清除覆盖")
        modal = hud:ShowTrackLock(track, 2000, function() calls = calls + 1; return true end)
        renderModal(modal)
        click(modal.footerWidget_:GetChildren()[2])
        demand(calls == 2 and not hud:IsModalOpen(), "成功确认应关闭弹窗")
        hud:ShowTrackLock(track, 100, function() calls = calls + 1; return true end)
        hud:SetScreen("menu")
        demand(not hud:IsModalOpen(), "换页必须清除弹窗")
        local notice = hud:ShowNotice("测试提示", "金币不足，还差1000金币。")
        renderModal(notice)
        demand(UI.GetTopOverlay() == notice, "通用提示也必须是模态")
        hud:CloseModal()
    end)
    hud:CloseModal()
    hud.actions.unlockTrack = oldUnlock
    hud:SetScreen(oldScreen); UI.Layout()
    demand(ok, tostring(failure))
    print("[RacingUIChecks] PASS 覆盖阻断/不足禁购买/明确确认/重复点击/关闭/换页/通用提示")
    return true
end
function Checks.Controls(hud)
    local controls, oldScreen = hud.controls, hud.screen
    local saved = {}
    for key, detail in pairs(controls.details) do
        saved[key] = {text = detail:GetText(), state = controls.actionStates[key]}
    end
    hud:SetScreen("ride"); UI.Layout(); hud:ApplySettings(); UI.Layout()
    local checked = 0
    local ok, failure = pcall(function()
        local samples = {"前轮抬起 · 松手放下", "车速过高 · 先减速", "竞速专用", "喷射 2.5s", "这是一条非常长的不可用原因，不能挤压标题"}
        for key, detail in pairs(controls.details) do
            for _, text in ipairs(samples) do
                controls:SetActionState(key, {state = "blocked", detail = text})
                UI.Layout()
                -- 连续真实渲染两次，捕捉 Label 首帧自动换行涨高的回归。
                detail:Render(UI.GetNVGContext()); UI.Layout()
                detail:Render(UI.GetNVGContext()); UI.Layout()
                local d = detail:GetAbsoluteLayout()
                local caption = controls.captions[key]:GetAbsoluteLayout()
                local owner = controls.widgets[key]:GetAbsoluteLayout()
                demand(not detail.autoWidth_ and detail.props.whiteSpace == "nowrap", "状态必须使用明确宽度单行布局")
                demand(math.abs(d.h - 15) < 2, "长状态经过渲染后不得涨高")
                demand(caption.y + caption.h <= d.y + 1, "标题和状态不能重叠：" .. key)
                demand(inside(d, owner, 2) and inside(caption, owner, 2), "标题与状态须包含在真实按钮内")
                checked = checked + 1
            end
        end
        for _, control in ipairs(hud.rightTop:GetChildren()) do
            demand(control.props.variant == "secondary", "相机暂停须为次级按钮")
        end
        demand(hud.recoverButton.props.variant == "secondary", "复位须为次级按钮")
    end)
    for key, previous in pairs(saved) do
        controls.actionStates[key] = previous.state
        controls.details[key]:SetText(previous.text)
    end
    hud:SetScreen(oldScreen); UI.Layout()
    demand(ok, tostring(failure))
    print(string.format("[RacingUIChecks] PASS 驾驶长状态不涨高/标题状态分离/次级功能按钮：%d组", checked))
    return checked
end
function Checks.Features(hud)
    local oldScreen = hud.screen
    hud:SetScreen("ride")
    local fixture = {featureState = {feedbackPower = 1, lastGain = 4.5}, elapsed = 1,
        airborne = false, airTime = 0, roadS = 0, heading = 0,
        landscape = {RouteLength = 2000, Features = {{kind = "ramp", s = 100, lateral = 3, yaw = 0}}}}
    local ok, failure = pcall(function()
        hud:UpdateFeatureFeedback(fixture); UI.Layout()
        demand(hud.featureRush.power == 1 and hud.featurePanel:IsVisible(), "真实加速带脉冲须显示速度线和提示")
        demand(hud.featureTitle:GetText() == "加速带 · 冲刺", "加速带不可冒充氮气")
        demand(hud.featureHint:GetText():find("16", 1, true) ~= nil, "提示必须显示真实速度增益")
        hud.featureRush:Render(UI.GetNVGContext())
        for _, widget in ipairs({hud.featureTitle, hud.featureHint}) do
            widget:Render(UI.GetNVGContext()); UI.Layout()
            demand(inside(widget:GetAbsoluteLayout(), hud.featurePanel:GetAbsoluteLayout(), 2), "机关提示文字不能越界")
        end
        fixture.featureState.feedbackPower = 0
        hud:UpdateFeatureFeedback(fixture)
        demand(hud.featureRush.power == 0 and hud.featureTitle:GetText():find("飞坡", 1, true), "结束冲刺后显示真实前方飞坡距离")
        fixture.airborne, fixture.airTime = true, 0.3
        hud:UpdateFeatureFeedback(fixture)
        demand(hud.featureTitle:GetText() == "腾空飞跃", "真实空中状态须有飞跃反馈")
        hud:SetScreen("pause"); hud:UpdateFeatureFeedback(fixture)
        demand(not hud.featurePanel:IsVisible() and hud.featureRush.power == 0, "暂停页面隐藏冲刺反馈")
    end)
    hud:SetScreen(oldScreen)
    hud:UpdateFeatureFeedback({featureState = {}, elapsed = 0, airborne = false})
    UI.Layout()
    demand(ok, tostring(failure))
    print("[RacingUIChecks] PASS 加速带冲刺/真实增益/飞坡预告/腾空/暂停反馈")
    return true
end
function Checks.Run(hud)
    demand(not hud:IsModalOpen(), "回归前须关闭已有业务弹窗")
    local labels, menuLabels = 0, 0
    for _, size in ipairs({{854,480}, {640,360}, {568,320}, {640,280}, {748,400}, {1280,720}, {1568,705}}) do
        menuLabels = menuLabels + Checks.Menu(size[1], size[2])
    end
    for _, size in ipairs({{854,480}, {1280,720}, {1568,705}}) do
        labels = labels + Checks.Layout(hud, size[1], size[2])
    end
    Checks.Dialogs(hud)
    local controls = Checks.Controls(hud)
    Checks.Features(hud)
    print("[RacingUIChecks] 全部通过；ControlChecks请单独继续执行")
    return {passed = true, labels = labels, resolutions = 3, controls = controls, menuLabels = menuLabels, menuResolutions = 7}
end
return Checks
