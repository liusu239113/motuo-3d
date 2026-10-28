-- Real UI overlay stack, not a toast. Ownership/currency writes remain in the caller.
local UI = require("urhox-libs/UI")
local Theme = require("RacingTheme")
local Routes = require("RouteSelect")
local C = Theme.Colors
---@class RacingDialogs
---@field activeModal Modal?
---@field controls MobileControls
---@field screen string
---@field portraitActive boolean
local Dialogs = {}
-- Modal 的内容/页脚是独立 Yoga 子树，不属于 children；在业务层逐一释放，避免重复销毁。
local function disposeModal(modal)
    local content, footer = modal.contentContainer_, modal.footerWidget_
    modal.footerWidget_ = nil
    if content and content.node then
        content.parent = nil
        content:Destroy()
    end
    if footer and footer ~= content and footer.node then
        footer.parent = nil
        footer:Destroy()
    end
    if modal.node then modal:Destroy() end
end
function Dialogs:IsModalOpen()
    return self.activeModal ~= nil and self.activeModal:IsOpen()
end
function Dialogs:CloseModal()
    local modal = self.activeModal
    if modal then modal:Close() end
end
---@param track TrackDefinition
---@param currentCoins number
---@param onConfirm fun(trackId:string):boolean?, string?
function Dialogs:ShowTrackLock(track, currentCoins, onConfirm)
    self:CloseModal()
    local price = math.max(0, math.floor(tonumber(track.price) or 0))
    local coins = math.max(0, math.floor(tonumber(currentCoins) or 0))
    local missing = math.max(0, price - coins)
    local affordable = coins >= price and type(onConfirm) == "function"
    local submitted = false
    local vw, vh = UI.GetViewportSize()
    local insets = UI.GetSafeAreaInsets()
    local contentHeight = math.max(150, math.min(286, vh - insets.top - insets.bottom - 188))
    ---@type Button?
    local purchase = nil
    ---@type Modal
    local modal = UI.Modal {
        title = "解锁赛道", size = vw < 540 and "sm" or "md",
        closeOnOverlay = false, closeOnEscape = true, showCloseButton = true,
        onClose = function(closed)
            if self.activeModal == closed then self.activeModal = nil end
            if closed.parent then closed:Remove() end
            disposeModal(closed)
            -- 只有驾驶页且没有其他模态时才恢复驾驶输入。
            self.controls:SetEnabled(self.screen == "ride" and not self.portraitActive and not self:IsModalOpen())
            print("[赛道解锁] 关闭 " .. track.id)
        end,
    }
    local status = Theme.Label(missing > 0 and ("还差 " .. missing .. " 金币，可先参加已开放赛事。")
        or "余额充足，确认后扣除金币并永久解锁。", 11, missing > 0 and C.amber or C.cyan,
        {width = "100%", whiteSpace = "normal", maxLines = 3})
    local function accountRow(name, value, color)
        return UI.Row {width = "100%", height = 29, padding = 0, justifyContent = "space-between", pointerEvents = "none",
            children = {Theme.Label(name, 11, C.muted), Theme.Label(value .. " 金币", 12, color or C.white, {fontWeight = "bold"})}}
    end
    modal:AddContent(UI.ScrollView {width = "100%", height = contentHeight, padding = 0,
        scrollY = true, showScrollbar = true, children = {
            UI.Column {width = "100%", padding = 0, gap = 10, children = {
                Theme.Kicker("LOCKED / ROUTE ACCESS"),
                Theme.Label(track.name or track.id, 20, C.white, {width = "100%", fontWeight = "bold",
                    whiteSpace = "normal", maxLines = 2}),
                Theme.Card {width = "100%", padding = 12, gap = 0, pointerEvents = "none", children = {
                    accountRow("解锁价格", price, C.amber), accountRow("当前持有", coins),
                    accountRow("尚缺金额", missing, missing > 0 and C.red or C.cyan)}},
                status,
                Theme.Label("另一条解锁路线", 10, C.cyan, {fontWeight = "bold"}),
                Theme.Label(Routes.Requirement(track), 12, C.white, {width = "100%", whiteSpace = "normal", maxLines = 3}),
                Theme.Label("金币购买与前置夺冠满足任意一种即可；取消不会扣除金币。", 10, C.muted,
                    {width = "100%", whiteSpace = "normal", maxLines = 3}),
            }}}})
    purchase = Theme.Button(missing > 0 and "金币不足" or ("确认解锁 · " .. price), function()
        -- Latch before calling game code: repeated input can never double-purchase.
        if submitted or not affordable then return end
        submitted = true
        if purchase then purchase:SetDisabled(true) end
        print(string.format("[赛道解锁] 明确确认 %s / 价格%d / 余额%d", track.id, price, coins))
        local ok, message = onConfirm(track.id)
        if ok == false then
            status:SetText(message or "解锁未完成，请关闭后重试。")
            status:SetFontColor(C.red)
            -- Keep readable failure and a working Close button. Retry needs a fresh balance.
            if purchase then purchase:SetText("未完成 · 请关闭重试") end
            return
        end
        modal:Close()
    end, true, nil, {flexGrow = 1, flexBasis = 0, minWidth = 0, disabled = not affordable, fontSize = 10})
    modal:SetFooter(UI.Row {width = "100%", gap = 10, padding = 0, children = {
        Theme.Button("暂不解锁", function() modal:Close() end, false, 104, {fontSize = 10}), purchase}})
    self.activeModal = modal
    self.controls:SetEnabled(false)
    modal:Open()
    -- Modal's stock open animation starts at zero and doesn't hit-test until Update.
    -- Immediate opening is intentional: no one-frame click-through under a purchase dialog.
    modal.animProgress_ = 1
    print(string.format("[赛道解锁] 展示 %s / 价格%d / 余额%d / 还差%d", track.id, price, coins, missing))
    return modal
end
function Dialogs:ShowNotice(title, message)
    self:CloseModal()
    local vw, vh = UI.GetViewportSize()
    local modal = UI.Modal {title = title or "提示", size = vw < 540 and "sm" or "md",
        closeOnOverlay = false, closeOnEscape = true,
        onClose = function(closed)
            if self.activeModal == closed then self.activeModal = nil end
            if closed.parent then closed:Remove() end
            disposeModal(closed)
            self.controls:SetEnabled(self.screen == "ride" and not self.portraitActive and not self:IsModalOpen())
        end}
    modal:AddContent(UI.ScrollView {width = "100%", height = math.max(100, math.min(220, vh - 190)), padding = 0,
        children = {Theme.Label(message or "", 12, C.white,
            {width = "100%", whiteSpace = "normal", lineHeight = 1.4})}})
    modal:SetFooter(UI.Row {width = "100%", padding = 0, justifyContent = "flex-end", children = {
        Theme.Button("知道了", function() modal:Close() end, true, 112)}})
    self.activeModal = modal
    self.controls:SetEnabled(false)
    modal:Open(); modal.animProgress_ = 1
    print("[界面提示] " .. tostring(title) .. " / " .. tostring(message))
    return modal
end
function Dialogs.Install(target)
    for _, name in ipairs({"IsModalOpen", "CloseModal", "ShowTrackLock", "ShowNotice"}) do target[name] = Dialogs[name] end
end
return Dialogs
