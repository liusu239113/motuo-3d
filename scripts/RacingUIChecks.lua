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
    local labels = 0
    for _, size in ipairs({{854,480}, {1280,720}, {1568,705}}) do
        labels = labels + Checks.Layout(hud, size[1], size[2])
    end
    Checks.Dialogs(hud)
    local controls = Checks.Controls(hud)
    Checks.Features(hud)
    print("[RacingUIChecks] 全部通过；ControlChecks请单独继续执行")
    return {passed = true, labels = labels, resolutions = 3, controls = controls}
end
return Checks
