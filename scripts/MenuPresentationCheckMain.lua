-- Fast real-HUD fixture, based on VehicleBrawlPresentationCheckMain + GMChecks isolation.
-- No main/World, race simulation, real profile/control files, SDK calls or production edits.
-- Entry: MenuPresentationCheckMain.lua -menu-check-screen=menu|loading|garage (default menu).
-- Checks finish without exiting/changing the target screen, so external screenshots see that screen.
assert(cache:AddResourceDir("/workspace/assets", false))
assert(cache:AddResourceDir("/workspace/scripts", false))
cache.searchPackagesFirst = false
local UI = require("urhox-libs/UI")
local RacingTheme = require("RacingTheme")
local Catalog = require("Catalog")
local SkillNames = require("SkillNames")
local MixedRace = require("MixedRace")
---@type HUD?
local hud_ = nil
---@type fun()?
local restoreProfile_ = nil
---@type fun()?
local restoreControls_ = nil
---@type fun():number,string?
local storage_ = function() return 0, nil end
local initialWrites_ = 0
---@type string?
local initialProfile_ = nil
local target_, frames_, assertions_ = "menu", 0, 0
local phoneInsets_ = false
local readyFrames_ = 0
local finished_, stopped_ = false, false
local MENUART = "image/highway_brawl_main_menu_20261104221739.png"
local LOGO = "image/highway_brawl_title_logo_20261104221559.png"
local KEYART = "image/vehicle_brawl_keyart_20261104212846.png"
local GARAGE = "image/vehicle_brawl_garage_20261104213013.png"

local function check(ok, message)
    assert(ok, "[MenuPresentation] " .. message)
    assertions_ = assertions_ + 1
end

local function arguments()
    local result = {}
    local raw = GetArguments()
    -- Normal engine binding returns string[]; tolerate hosts forwarding a raw command string.
    if type(raw) == "string" then
        for value in raw:gmatch("%S+") do result[#result + 1] = value end
    else
        for _, value in ipairs(raw) do result[#result + 1] = value end
    end
    for index, value in ipairs(result) do
        if value == "-menu-check-phone-insets" then phoneInsets_ = true end
        local selected = value:match("^%-menu%-check%-screen=(.*)$")
        if value == "-menu-check-screen" then selected = result[index + 1] or "" end
        if selected then
            selected = selected:gsub('^["\']', ''):gsub('["\']$', '')
            check(selected == "menu" or selected == "loading" or selected == "garage",
                "-menu-check-screen must be menu/loading/garage, got " .. selected)
            target_ = selected
        end
    end
end

-- HUD layout can query ControlSettings.Current even outside the editor. Use its real
-- source/defaults in a private sandbox, not player files or production-method substitutes.
local function isolateControls()
    local file = assert(cache:GetFile("ControlSettings.lua"))
    local lines = {}
    while not file:IsEof() do lines[#lines + 1] = file:ReadLine() end
    file:Dispose()
    local env = setmetatable({
        fileSystem = {FileExists = function(_, path)
            assert(path == "pursuit_controls.txt", "[MenuPresentation] unexpected settings path")
            return false
        end},
        File = function() error("[MenuPresentation] control fixture must not open any real file") end,
    }, {__index = _G})
    local isolated = assert(load(table.concat(lines, "\n"), "Menu isolated ControlSettings", "t", env))()
    local settings = require("ControlSettings")
    local previous = {}
    for key, value in pairs(isolated) do previous[key], settings[key] = settings[key], value end
    local restored = false
    return function()
        if restored then return end
        restored = true
        for key in pairs(isolated) do settings[key] = previous[key] end
    end
end

---@param widget Widget
---@param visit fun(widget:Widget)
local function walk(widget, visit)
    visit(widget)
    for _, child in ipairs(widget:GetChildren()) do walk(child, visit) end
end

local function verifyStorage()
    local writes, text = storage_()
    check(writes == initialWrites_ and text == initialProfile_, "HUD checks must not mutate even the isolated profile")
    check(not package.loaded["World"] and not package.loaded["main"], "fixture must never load World/main")
end

---@param hud HUD
local function checkArt(hud)
    check(UI.GetRoot() == hud.root, "must inspect HUD.New's real mounted tree")
    for _, path in ipairs({MENUART, LOGO, KEYART, GARAGE}) do
        local found = false
        for _, resource in ipairs(require("HUD").Resources) do if resource == path then found = true end end
        check(found and require("HUD").ResourceTypes[path] == "Texture2D", "registered actual HUD art " .. path)
        local texture = assert(cache:GetResource("Texture2D", path), "[MenuPresentation] missing art " .. path)
        check(texture.width > 0 and texture.height > 0, "art loads " .. path)
    end
    check(hud.menuTitle.props.backgroundImage == LOGO and hud.menuTitle.props.backgroundFit == "contain", "real menu title uses contained LOGO")
    check(hud.menuBackdrop.props.backgroundImage == MENUART and hud.menuBackdrop.props.backgroundFit == "cover", "real menu uses new cover background")
    check(hud.menuBackdrop ~= hud.keyartBackdrop and hud.menuBackdrop ~= hud.garageBackdrop, "menuBackdrop is independent")
    check(hud.menuBackdrop.parent == hud.pageBackdrop and hud.keyartBackdrop.parent == hud.pageBackdrop
        and hud.garageBackdrop.parent == hud.pageBackdrop, "independent backdrops are mounted siblings")
    check(hud.menuCard.props.backgroundColor == nil, "real menuCard has no backgroundColor")
    check(hud.menuCard.props.backgroundGradient == nil and hud.menuCard.props.backgroundImage == nil, "menuCard has no replacement opaque card fill")
end

---@param hud HUD
---@param screen string
local function checkScreen(hud, screen)
    check(hud.screen == screen, "HUD:SetScreen retains " .. screen)
    check(hud.menu:IsVisible() == (screen == "menu") and hud.loading:IsVisible() == (screen == "loading")
        and hud.garage:IsVisible() == (screen == "garage"), "real page visibility " .. screen)
    check(hud.pageBackdrop:IsVisible(), "page backdrop is visible " .. screen)
    check(hud.menuBackdrop:IsVisible() == (screen == "menu"), "independent menuBackdrop visibility " .. screen)
    check(hud.keyartBackdrop:IsVisible() == (screen == "loading"), "keyart visibility " .. screen)
    check(hud.garageBackdrop:IsVisible() == (screen == "garage"), "garage backdrop visibility " .. screen)
    check(not hud.portrait:IsVisible(), "use landscape capture dimensions; portrait guard would cover target")
end

---@param hud HUD
local function checkLoadingTree(hud)
    check(hud.keyartBackdrop.props.backgroundImage == KEYART, "loading retains real keyart background")
    -- Inspect real containers, not BuildLoading source text/a mocked hand-built page.
    -- Buttons and the progress bar intentionally keep their functional surface colors.
    walk(hud.loading, function(widget)
        if widget._className == "Panel" or widget._className == "Column" or widget._className == "Row" then
            check(widget.props.backgroundColor == nil and widget.props.backgroundGradient == nil
                and widget.props.backgroundImage == nil, "loading containers must not add a black backing: " .. widget._className)
        end
    end)
    local ancestor = hud.loading.parent
    while ancestor do
        check(ancestor.props.backgroundColor == nil and ancestor.props.backgroundGradient == nil,
            "loading ancestor must not obscure keyart: " .. ancestor._className)
        ancestor = ancestor.parent
    end
end

---@param hud HUD
local function checkAllDescriptions(hud)
    local report = SkillNames.RunRules(Catalog.List)
    check(report.passed and report.vehicles == 27 and report.shortNames == 54, "SkillNames.RunRules covers all 27/54")
    -- Keep actual HUD:SetScreen/SelectVehicle and the actual text tree. Suppress ONLY
    -- preview selection while testing text so this loop never loads all 27 models.
    local preview = hud.preview
    local oldSelect, oldPrewarm = rawget(preview, "Select"), rawget(preview, "Prewarm")
    local skipped = 0
    preview.Select = function() skipped = skipped + 1 end
    preview.Prewarm = function() end
    local ok, failure = pcall(function()
        hud:SetScreen("garage")
        UI.Layout()
        checkScreen(hud, "garage")
        local count = 0
        for _, item in ipairs(Catalog.List) do
            hud:SelectVehicle(item.id, false)
            check(hud.selectedVehicle == item.id and hud.vehicleName:GetText() == item.name, "actual SelectVehicle " .. item.id)
            local skill = assert(MixedRace.GetSkill(item.id))
            local active = SkillNames.Active(item.id)
            local skillText = string.format("\n主动：%s · %s\n持续 %.1fs / 冷却 %.0fs", active,
                SkillNames.DisplayText(item.id, skill.description), skill.duration, skill.cooldown)
            local expected = item.odd and ("被动：" .. SkillNames.Passive(item.id) .. " · " .. (item.passiveDescription or "") .. skillText .. "\n短板：" .. (item.weakness or ""))
                or ((item.description or item.tag or "") .. skillText)
            expected = SkillNames.DisplayText(item.id, expected)
            local text = hud.vehicleDescription:GetText()
            check(text == expected, "full untruncated garage explanation uses short active name: " .. item.id)
            check(text:find("主动：" .. active .. " · ", 1, true) ~= nil, "active heading short name " .. item.id)
            walk(hud.garage, function(widget)
                local value = widget.props.text
                if type(value) == "string" then
                    for _, other in ipairs(Catalog.List) do
                        check(not value:find(assert(other.skillName), 1, true), "real garage tree retains full long name " .. other.id .. " after " .. item.id)
                    end
                end
            end)
            count = count + 1
        end
        check(count == 27 and skipped == 28, "all 27 real selections checked with preview loading suppressed")
        hud.garagePages:Paginate()
        local first = hud.garagePages:GetPage()
        if hud.garagePages:GetPageCount() > first then
            hud.garagePages:SetPage(first + 1)
            local selected = hud.vehicleCards[hud.selectedVehicle]
            local page = hud.garagePages.pages[hud.garagePages:GetPage()]
            local found = false
            for _, unit in ipairs(page) do
                if unit.source == selected or unit.members[selected] then found = true end
            end
            check(found, "翻页后实际选中车型必须属于新页而不是旧页")
        end
    end)
    -- Finally restore the instance method even on a failed assertion; no production edits.
    rawset(preview, "Select", oldSelect)
    rawset(preview, "Prewarm", oldPrewarm)
    if not ok then error(failure, 0) end
    hud:SetScreen("loading")
    hud:SelectVehicle("skateboard", false)
    check(not preview.active and preview.previewScene == nil, "text-only checks did not build any vehicle")
    print("[MenuPresentation] descriptions PASS / all 27 SelectVehicle / 54 short names / full explanations / no long-name residue / no 27-model load")
end

---@param hud HUD
local function checkGarage(hud)
    local preview = hud.preview
    check(preview.state == "ready" and preview.vehicleId == "skateboard", "real asynchronous skateboard preview is ready")
    local scene = assert(preview.previewScene)
    local content = assert(assert(preview.displayEntry).content)
    local body = assert(content:GetChild("Vehicle_skateboard"))
    check(#body:GetComponents("StaticModel", true) > 0, "skateboard has real StaticModels")
    check(body:GetVar("FormalModel"):GetString() == require("MixedAssets").Vehicles.skateboard.model, "preview uses formal skateboard")
    check(preview.riderRig == nil and #scene:GetComponents("AnimatedModel", true) == 0, "garage is vehicle-only, no AnimatedModel/driver")
    check(math.abs(content.position.y) < .0001, "skateboard canonical ground remains 0m")
    check(preview.previewTexture ~= nil and preview.previewSurface ~= nil, "real garage RT allocated")
end

local function cleanup()
    local ok, failure = pcall(function()
        if hud_ then hud_:Dispose(); hud_ = nil end
        UI.Shutdown()
    end)
    if restoreControls_ then local restore = restoreControls_; restoreControls_ = nil; restore() end
    if restoreProfile_ then local restore = restoreProfile_; restoreProfile_ = nil; restore() end
    if not ok then error(failure, 0) end
end

function Start()
    local ok, failure = pcall(function()
        arguments()
        restoreProfile_, storage_ = require("GMChecks").Begin()
        restoreControls_ = isolateControls()
        initialWrites_, initialProfile_ = storage_()
        UI.Init({theme = RacingTheme.Theme, scale = UI.Scale.DEFAULT})
        -- All business actions are intentionally no-ops; never launch a world, save,
        -- purchase, trial or advertisement through the real HUD's callbacks.
        local actions = setmetatable({}, {__index = function() return function() end end})
        local controls = require("MobileControls").New()
        hud_ = require("HUD").New(actions, controls)
        local hud = assert(hud_)
        if phoneInsets_ then
            -- 模拟手机胶囊和底部手势区实际占高，而非仅改变窗口纵横比。
            local safe = assert(hud.safeContent.parent)
            safe:SetStyle({paddingTop = 54, paddingBottom = 24, paddingLeft = 20, paddingRight = 12})
        end
        hud:SetScreen("menu"); UI.Layout()
        hud:LayoutResponsive(); UI.Layout()
        checkArt(hud); checkScreen(hud, "menu")
        hud:SetScreen("loading"); UI.Layout()
        checkScreen(hud, "loading"); checkLoadingTree(hud)
        checkAllDescriptions(hud)
        hud:SetScreen(target_); UI.Layout()
        checkScreen(hud, target_)
        verifyStorage()
        SubscribeToEvent("Update", "HandleMenuPresentationCheck")
        print("[MenuPresentation] real HUD tree ready / target=" .. target_ .. " / waiting for rendered frames and garage resources if needed")
    end)
    if not ok then stopped_ = true; cleanup(); error(failure, 0) end
end

function HandleMenuPresentationCheck()
    if stopped_ or finished_ then return end
    local ok, failure = pcall(function()
        frames_ = frames_ + 1
        local hud = assert(hud_)
        hud:LayoutResponsive(); UI.Layout()
        checkScreen(hud, target_)
        if target_ == "menu" then
            local bounds = hud.safeContent:GetAbsoluteLayout()
            for _, widget in ipairs({hud.menuRaceButton, hud.menuPracticeButton, hud.menuSettingsButton, hud.menuReturnHost}) do
                local box = widget:GetAbsoluteLayout()
                check(box.h >= 43 and box.x >= bounds.x - 1 and box.y >= bounds.y - 1
                    and box.x + box.w <= bounds.x + bounds.w + 1
                    and box.y + box.h <= bounds.y + bounds.h + 1, "全部菜单入口必须完整落在真实安全区")
            end
        end
        check(frames_ < 1800, "resource/render wait exceeded 1800 Update frames")
        if target_ == "garage" then
            check(hud.preview.state ~= "failed" and hud.preview.state ~= "unavailable", "skateboard resource preparation failed")
            if hud.preview.state ~= "ready" then return end
            checkGarage(hud)
            readyFrames_ = readyFrames_ + 1
            if readyFrames_ < 3 then return end
        else
            check(not hud.preview.active and hud.preview.previewScene == nil, "menu/loading must not load a 3D vehicle")
        end
        if frames_ < 3 then return end
        verifyStorage()
        finished_ = true
        print(string.format("[MenuPresentation] PASS %d assertions / screen=%s / frame=%d / real HUD+MobileControls / no World/main / memory-only profile / target retained for screenshot",
            assertions_, target_, frames_))
        -- No engine:Exit, menu reset or isolation restoration here. Screenshots must
        -- retain the requested tree; isolation stays active until Stop, including input.
    end)
    if not ok then stopped_ = true; UnsubscribeFromEvent("Update"); cleanup(); error(failure, 0) end
end

function Stop()
    stopped_ = true
    UnsubscribeFromEvent("Update")
    cleanup()
end
