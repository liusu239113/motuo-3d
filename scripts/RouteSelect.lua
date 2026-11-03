-- Responsive route cards: text is in Yoga flow, never absolute into a fixed-height box.
local UI = require("urhox-libs/UI")
local Theme = require("RacingTheme")
local Profile = require("Profile")
local Tracks = require("Tracks")
local Instruments = require("RaceInstruments")
local C = Theme.Colors
---@class RouteSelect
---@field careerRace? boolean
---@field selectedTrack string
---@field trackCards table<string, Card>
---@field trackGraphics table<string, RouteGraphic>
---@field trackButton Button
---@field trackMap table
---@field actions table
---@field IsModalOpen fun(self:RouteSelect):boolean
---@field SetScreen fun(self:RouteSelect, screen:string)
local Routes = {}
local THEMES = {lake = "湖畔 / 连续弯道", alpine = "高山 / 发卡挑战", coast = "海岸 / 高速巡航",
    canyon = "峡谷 / 沙漠穿行", forest = "森林 / 拉力公路", circuit = "赛道 / 封闭竞速"}
local function list() return Tracks.List() end
function Routes.Requirement(track)
    local previous = Tracks.Get(track.requires or "")
    if previous then return "在「" .. previous.name .. "」夺冠可免费解锁" end
    return "赢取比赛金币，解锁新的公路旅程"
end
-- Pure metrics are also usable by static layout checks; fonts never shrink with viewport.
function Routes.Metrics(w, h)
    local padding = w < 920 and 12 or 20
    local inner = math.max(1, w - padding * 2)
    -- Keep multi-column rows atomic: PhonePages can split one vertical card,
    -- not two/three equally tall columns. Reserve header, footnote and pager
    -- space before choosing columns; short landscape uses full-width cards.
    local columns = h < 520 and 1 or (inner >= 960 and 3 or (inner >= 640 and 2 or 1))
    local mapHeight = h >= 650 and 78 or 62
    return {padding = padding, columns = columns, gap = 12, mapHeight = mapHeight,
        cardWidth = (inner - (columns - 1) * 12) / columns}
end
function Routes:BuildTracks()
    self.trackGrid = UI.Column {width = "100%", padding = 0, gap = 12}
    self.routeTitle = Theme.Label("选择赛道", 23, C.white, {fontWeight = "bold", height = 34})
    self.routeBalance = Theme.Label("", 11, C.amber, {height = 22, textAlign = "right"})
    self.routeSubtitle = Theme.Label("六条真实路线 · 选择后返回车库出发", 10, C.muted, {height = 20})
    self.routeHeader = UI.Row {width = "100%", padding = 0, gap = 12, alignItems = "center", children = {
        UI.Column {flexGrow = 1, flexBasis = 0, minWidth = 0, padding = 0, gap = 2,
            children = {Theme.Kicker("RACE / ROUTE COLLECTION", {height = 16}), self.routeTitle, self.routeSubtitle}},
        UI.Column {padding = 0, gap = 5, alignItems = "flex-end", children = {
            self.routeBalance, Theme.Button("返回车库", function() self:SetScreen("garage") end, false, 116)}}}}
    self.routeFrame, self.routeScroll = Theme.FixedPages({self.trackGrid}, 12)
    self.routeFootnote = Theme.Label("白点为发车位 · 路线与实景一致 · 未解锁赛道可查看条件", 10, C.muted,
        {width = "100%", height = 22})
    self.trackSelection = UI.Panel(Theme.Full({visible = false, padding = 20, gap = 10,
        backgroundGradient = Theme.Gradient({23, 29, 34, 255}, {9, 13, 17, 255}),
        children = {self.routeHeader, self.routeFrame, self.routeFootnote}}))
    self.routeColumns, self.routeMapHeight, self.trackSignature = 0, 62, ""
    self:RefreshTrackCards()
end
function Routes:RefreshTrackCards()
    local entries = list()
    local profile,profileError = Profile.GetForDisplay()
    local signature = {tostring(self.routeColumns),tostring(profileError),tostring(self.careerRace)}
    for _, entry in ipairs(entries) do
        signature[#signature + 1] = entry.id .. tostring(profile.unlockedTracks[entry.id]) .. tostring(entry.price)
    end
    local key = table.concat(signature, "/")
    self.routeBalance:SetText(profileError and "竞速进度不可用 · 原档保留" or "持有金币  " .. tostring(profile.coins))
    if self.trackSignature == key then return end
    self.trackSignature, self.trackCount = key, #entries
    -- Restore source widgets before rebuilding; page masks must not reference removed rows.
    self.routeScroll:RestoreSource()
    for i = self.trackGrid:GetNumChildren(), 1, -1 do
        local child = self.trackGrid:GetChildAt(i)
        if child then child:Destroy() end
    end
    self.trackCards, self.trackGraphics, self.trackBadges = {}, {}, {}
    local columns = math.max(1, self.routeColumns)
    -- Do not allocate an unattached initial Row (it owns a native Yoga node).
    -- A single column is a genuine vertical card list, safely fragmentable at
    -- sibling boundaries on very short screens; horizontal rows stay whole.
    local row = self.trackGrid
    for index, track in ipairs(entries) do
        local entry = track
        if columns > 1 and (index - 1) % columns == 0 then
            row = UI.Row {width = "100%", gap = 12, padding = 0, alignItems = "stretch"}
            self.trackGrid:AddChild(row)
        end
        local unlocked = self.careerRace or profile.unlockedTracks[entry.id] == true
        -- Locked maps stay legible. A dedicated badge and the two-line condition explain their state.
        local graphic = Instruments.Route {width = "100%", height = self.routeMapHeight,
            padding = 0, backgroundColor = {8, 14, 18, 255}, borderRadius = 1, pointerEvents = "none"}
        graphic:SetRoute(entry.preview or {}, entry.accent or C.cyan)
        local title = Theme.Label(string.format("%02d  %s", index, entry.name), 12, C.white,
            {flexGrow = 1, flexBasis = 0, minWidth = 0, height = 24, fontWeight = "bold", maxLines = 1})
        local state = unlocked and (entry.id == self.selectedTrack and "已选择" or "可参赛") or "未解锁"
        local stateBadge = Theme.Label(state, 9, unlocked and C.cyan or C.amber,
            {height = 24, width = 58, textAlign = "center", fontWeight = "bold",
                backgroundColor = unlocked and {31, 56, 60, 255} or {60, 47, 29, 255}})
        local footer = unlocked and "点按选择此赛道" or string.format("金币解锁  %d  /  或前置夺冠", entry.price or 0)
        local condition = unlocked and "返回车库确认座驾后出发" or Routes.Requirement(entry)
        local card = Theme.Card {width = columns == 1 and "100%" or nil,
            flexGrow = columns == 1 and 0 or 1, flexBasis = columns == 1 and "auto" or 0, minWidth = 0,
            padding = 10, gap = 4, clickable = true, hoverable = true, pointerEvents = "box-only",
            onClick = function()
                if self:IsModalOpen() then return end
                local current,readError=Profile.GetForDisplay()
                if readError and not self.careerRace then
                    if self.actions.unlockTrack then self.actions.unlockTrack(entry.id) end
                    return
                end
                if self.careerRace or current.unlockedTracks[entry.id] then
                    self:SelectTrack(entry.id, true); self:SetScreen("garage")
                elseif self.actions.unlockTrack then
                    print("[赛道界面] 查看锁定条件 " .. entry.id)
                    self.actions.unlockTrack(entry.id)
                end
            end,
            children = {
                UI.Row {width = "100%", padding = 0, gap = 5, pointerEvents = "none", children = {title, stateBadge}},
                graphic,
                UI.Row {width = "100%", height = 18, padding = 0, justifyContent = "space-between", pointerEvents = "none", children = {
                    Theme.Label(THEMES[entry.theme] or "公路竞速", 9, C.cyan, {height = 18}),
                    Theme.Label(string.format("%.2f km", (entry.length or 0) / 1000), 10, C.white, {height = 18})}},
                Theme.Label(entry.description or "", 10, C.muted, {height = 36, width = "100%",
                    whiteSpace = "normal", maxLines = 2, lineHeight = 1.25}),
                Theme.Label(string.format("%d 圈   /   基础收益 %d 金币", entry.laps or 3, entry.reward or 100), 10, C.white,
                    {height = 20, width = "100%", maxLines = 1}),
                UI.Column {width = "100%", padding = {5, 0, 0, 0}, gap = 1, pointerEvents = "none",
                    borderTopWidth = 1, borderTopColor = C.border, children = {
                        Theme.Label(footer, 10, unlocked and C.cyan or C.amber, {height = 20, width = "100%", fontWeight = "bold"}),
                        Theme.Label(condition, 9, C.muted, {height = 18, width = "100%", maxLines = 1})}},
            }}
        self.trackBadges[entry.id] = stateBadge
        self.trackCards[entry.id], self.trackGraphics[entry.id] = card, graphic
        row:AddChild(card)
    end
    local remainder = #entries % columns
    if remainder > 0 then
        for _ = remainder + 1, columns do row:AddChild(UI.Panel {flexGrow = 1, flexBasis = 0, padding = 0, pointerEvents = "none"}) end
    end
    -- Route labels keep the authored font size even when a page changes width.
    -- Reflow/pagination, never text auto-fit, is responsible for making them fit.
    local function fixedFonts(widget)
        if widget._className == "Label" then widget.props.minFontSize = widget.props.fontSize end
        for _, child in ipairs(widget:GetChildren()) do fixedFonts(child) end
    end
    fixedFonts(self.trackGrid)
    self:UpdateTrackSelectionStyle()
end
function Routes:UpdateTrackSelectionStyle()
    local profile = Profile.GetForDisplay()
    for id, card in pairs(self.trackCards) do
        local selected = id == self.selectedTrack
        local badge = self.trackBadges and self.trackBadges[id] --[[@as Label?]]
        if badge then badge:SetText((self.careerRace or profile.unlockedTracks[id]) and (selected and "已选择" or "可参赛") or "未解锁") end
        card:SetStyle({borderColor = selected and C.cyan or C.border,
            backgroundGradient = Theme.Gradient(selected and {34, 53, 57, 255} or {30, 37, 43, 255},
                selected and {20, 32, 37, 255} or {16, 21, 26, 255})})
    end
end
function Routes:LayoutTracks(w, h)
    local metrics = Routes.Metrics(w, h)
    local changed = self.routeColumns ~= metrics.columns
    self.routeColumns, self.routeMapHeight = metrics.columns, metrics.mapHeight
    self.trackSelection:SetStyle({padding = metrics.padding})
    if changed then self:RefreshTrackCards() end
    for _, graphic in pairs(self.trackGraphics) do graphic:SetHeight(metrics.mapHeight) end
    self.routeTitle:SetFontSize(23)
    self.routeSubtitle:SetVisible(w >= 650)
    self.routeFootnote:SetStyle({whiteSpace = w < 600 and "normal" or "nowrap", height = w < 600 and 36 or 22})
    print(string.format("[赛道排版] %.0fx%.0f / %d列 / 固定按钮分页", w, h, metrics.columns))
end
function Routes:OpenTracks()
    self:RefreshTrackCards()
    self:SelectTrack(self.selectedTrack, false)
    self:SetScreen("tracks")
end
function Routes:SelectTrack(id, notify)
    local selected = Tracks.Get(id)
    local profile = Profile.GetForDisplay()
    if not selected or not self.careerRace and not profile.unlockedTracks[id] then return false end
    self.selectedTrack = id
    self:UpdateTrackSelectionStyle()
    self.trackButton:SetText("赛道 · " .. selected.name .. " ›")
    self.trackMap.points, self.trackMap.routeReady, self.trackMap.routeLength = {}, false, 0
    if notify and self.actions.selectTrack then self.actions.selectTrack(id) end
    print("[赛道界面] 选择 " .. id .. (notify and " → 通知入口" or " / 同步"))
    return true
end
function Routes.Install(target)
    for _, method in ipairs({"BuildTracks", "RefreshTrackCards", "UpdateTrackSelectionStyle", "LayoutTracks", "OpenTracks", "SelectTrack"}) do
        target[method] = Routes[method]
    end
end
return Routes
