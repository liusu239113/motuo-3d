-- 真实Profile源码的隔离回归；所有存档均为局部内存，不触碰玩家文件或云档。
local Checks = {}

function Checks.Run()
    local file = assert(cache:GetFile("Profile.lua"), "[ProfileChecks] 缺少Profile源资源")
    local lines = {}
    while not file:IsEof() do lines[#lines + 1] = file:ReadLine() end
    file:Dispose()
    local source = table.concat(lines, "\n")
    ---@type table<string, string>
    local files = {}
    local failWrite, failOpen, failRead, failCopy, failRename = false, false, false, false, false
    local failExists, failConstruct, failIsOpen, failClose, failDispose = false, false, false, false, false
    local throwWrite, failFlush, corruptTemp, corruptCommit = false, false, false, false
    local writes, mutations, readOpens, assertions = 0, 0, 0, 0
    local path = "pursuit_profile.txt"
    local valid = "version=1\ncoins=2300\nvehicle=sport,cruiser\nrider=green\ntrack=circuit,lake,coast\n"
    local function check(value, message)
        assert(value, "[ProfileChecks] " .. message)
        assertions = assertions + 1
    end
    local function isolated(name)
        assert(name == path or name == path .. ".pending" or name == path .. ".backup", "禁止访问玩家存档")
    end
    local environment = setmetatable({
        fileSystem = {
            FileExists = function(_, name)
                isolated(name)
                if failExists then error("模拟存在性查询异常") end
                return files[name] ~= nil
            end,
            Copy = function(_, from, to)
                isolated(from); isolated(to)
                mutations = mutations + 1
                if failCopy or files[from] == nil then return false end
                files[to] = files[from]; return true
            end,
            Rename = function(_, from, to)
                isolated(from); isolated(to)
                mutations = mutations + 1
                if failRename or files[from] == nil then return false end
                files[to], files[from] = files[from], nil
                if corruptCommit then files[to] = "模拟提交损坏\n" end
                return true
            end,
            Delete = function(_, name)
                isolated(name); mutations = mutations + 1; files[name] = nil; return true
            end,
        },
        File = function(name, mode)
            isolated(name)
            if mode == FILE_READ then
                readOpens = readOpens + 1
                if failConstruct then error("模拟File构造异常") end
            else
                mutations = mutations + 1
            end
            local opened = not failOpen and (mode == FILE_WRITE or files[name] ~= nil)
            -- FILE_WRITE打开即截断；统计打开而非仅统计WriteString，防止漏掉静默覆盖。
            if opened and mode == FILE_WRITE then files[name] = "" end
            return {
                IsOpen = function()
                    if mode == FILE_READ and failIsOpen then error("模拟IsOpen异常") end
                    return opened
                end,
                ReadString = function()
                    if failRead then error("模拟读盘异常") end
                    if corruptTemp and name == path .. ".pending" then return "模拟临时文件损坏\n" end
                    return files[name] or ""
                end,
                WriteString = function(_, text)
                    assert(opened and mode == FILE_WRITE)
                    writes = writes + 1
                    if throwWrite then files[name] = text:sub(1, 12); error("模拟写盘异常") end
                    if failWrite then files[name] = text:sub(1, 12); return false end
                    files[name] = text; return true
                end,
                Flush = function() if failFlush then error("模拟Flush异常") end end,
                Close = function() if mode == FILE_READ and failClose then error("模拟Close异常") end end,
                Dispose = function() if mode == FILE_READ and failDispose then error("模拟Dispose异常") end end,
            }
        end,
    }, {__index = _G})
    local function fresh()
        local chunk = assert(load(source, "@Profile.lua（内存回归）", "t", environment))
        return chunk()
    end
    local function seed(text)
        files[path], files[path .. ".pending"], files[path .. ".backup"] = text, "原临时档", valid
    end
    local function rejected(action, name)
        local called, result, message = pcall(action)
        check(called and result == false and type(message) == "string" and message ~= "", name .. "须返回false及错误而非抛错")
    end
    local function blocked(p, name)
        local original, pending, backup = files[path], files[path .. ".pending"], files[path .. ".backup"]
        local before = mutations
        rejected(p.TryLoad, name .. "加载")
        check(type(p.GetLoadError()) == "string", name .. "应记住加载错误")
        local view, message = p.GetForDisplay()
        check(message == p.GetLoadError() and view.coins == 0 and view.owned.sport
            and view.ownedRiders.green and view.unlockedTracks.circuit, name .. "应提供明确错误和默认展示占位")
        view.coins, view.owned.cruiser = 9999, true
        local again = p.GetForDisplay()
        check(again ~= view and again.coins == 0 and not again.owned.cruiser, name .. "占位修改不得污染后续视图")
        check(not pcall(p.Get) and not pcall(p.Coins), name .. "业务读取不能默认为新档")
        check(not pcall(p.Owns, "sport") and not pcall(p.OwnsRider, "green")
            and not pcall(p.TrackUnlocked, "circuit"), name .. "权益业务读取必须严格")
        rejected(p.Save, name .. "保存")
        rejected(function() return p.AddCoins(120) end, name .. "奖励")
        rejected(function() return p.Buy("rally", 0) end, name .. "购买车")
        rejected(function() return p.BuyRider("red", 0) end, name .. "购买配色")
        rejected(function() return p.UnlockTrack("alpine", 0) end, name .. "解锁赛道")
        rejected(function() return p.GrantRaceRewards(120, {"alpine"}) end, name .. "组合奖励权益")
        rejected(function() return p.GrantTrackUnlocks({"alpine"}) end, name .. "免费权益")
        rejected(p.ResetForTests, name .. "重置保护")
        check(not p.HasPendingSave(), name .. "不可创建待保存奖励")
        rejected(p.RetryPendingSave, name .. "无pending补存")
        rejected(function() return p.TryLoad(true) end, name .. "显式重试仍损坏")
        check(mutations == before and files[path] == original and files[path .. ".pending"] == pending
            and files[path .. ".backup"] == backup, name .. "不得打开写文件、备份、提交、删除或恢复任何文件")
    end

    -- 真正新档只存在内存；读取/展示不能提前写盘。
    local p = fresh()
    local initialMutations = mutations
    check(p.GetLoadError() == nil and p.TryLoad(), "无档可正常初始化")
    local firstView, firstError = p.GetForDisplay()
    check(firstError == nil and firstView == p.Get() and firstView.coins == 0, "合法展示与业务数据一致")
    check(mutations == initialMutations and files[path] == nil, "新档读取不写盘")
    check(p.TrackUnlocked("circuit"), "默认赛车场必须开放")
    for _, id in ipairs({"lake", "alpine", "coast", "canyon", "forest"}) do
        check(not p.TrackUnlocked(id), "新档不得额外开放 " .. id)
    end
    check(not p.UnlockTrack("lake", 1200) and p.Coins() == 0, "不足金币不能扣款或解锁")
    check(p.AddCoins(1800), "首次奖励成功保存")
    check(p.UnlockTrack("lake", 1200) and p.Coins() == 600 and p.TrackUnlocked("lake"), "购买扣准确金币")
    check(fresh().Coins() == 600 and fresh().TrackUnlocked("lake"), "新实例重读购买进度")

    -- 原写档器的完整五字段v1，以及CRLF/换序/空白/空集合/历史ID均需兼容。
    for _, text in ipairs({valid,
        "track= circuit, lake, coast \r\nrider= green \r\nvehicle= sport, cruiser \r\ncoins= 2300 \r\nversion= 1 \r\n",
        "version=1\ncoins=2300\nvehicle=cruiser\nrider=\ntrack=coast\n"}) do
        seed(text)
        local old = fresh()
        local before = mutations
        check(old.TryLoad() and old.Coins() == 2300 and old.Owns("cruiser") and old.TrackUnlocked("coast"), "合法旧档金币与权益保留")
        check(old.Owns("sport") and old.OwnsRider("green") and old.TrackUnlocked("circuit"), "合法旧档补齐免费项")
        check(mutations == before and files[path] == text, "合法旧档加载不迁移覆写")
    end
    seed("version=1\ncoins=2300\nvehicle=retired-bike_1\nrider=old_color-2\ntrack=old_route-3\n")
    local historical = fresh()
    check(historical.Owns("retired-bike_1") and historical.OwnsRider("old_color-2")
        and historical.TrackUnlocked("old_route-3"), "不得按当前商品目录删除合法历史ID")
    check(historical.Save(), "历史权益可往返保存")
    local historicalReload = fresh()
    check(historicalReload.Owns("retired-bike_1") and historicalReload.OwnsRider("old_color-2")
        and historicalReload.TrackUnlocked("old_route-3"), "历史ID序列化后不丢失")

    -- 合法整数边界不做业务上限猜测；保存及重读必须无损。
    for _, amount in ipairs({"0", "0002300", "9223372036854775807"}) do
        seed((valid:gsub("coins=2300", "coins=" .. amount)))
        local boundary = fresh()
        local expected = assert(math.tointeger(tonumber(amount)))
        check(boundary.TryLoad() and boundary.Coins() == expected, "合法整型金币边界可加载")
        check(boundary.Save() and fresh().Coins() == expected, "合法整型金币边界往返不丢精度")
        if expected==math.maxinteger then
            local original=files[path];local beforeMutations=mutations
            rejected(function() return boundary.AddCoins(120) end,"整数上限奖励")
            check(boundary.Coins()==expected and not boundary.HasPendingSave()
                and files[path]==original and mutations==beforeMutations,"奖励溢出不得归零、写盘或伪造待保存")
        end
    end
    seed(valid)
    local integerRewards=fresh()
    check(integerRewards.TryLoad(),"奖励参数校验准备合法旧档")
    for _,amount in ipairs({-1,.5,math.huge,-math.huge,0/0}) do
        local beforeMutations=mutations
        rejected(function() return integerRewards.AddCoins(amount) end,"非法奖励金额")
        check(integerRewards.Coins()==2300 and not integerRewards.HasPendingSave()
            and mutations==beforeMutations,"非法奖励不得改变已有余额")
    end

    -- 每种坏档都逐一验证所有写入口，备份即使合法也不自动恢复。
    ---@param pattern string
    ---@param replacement string
    ---@return string
    local function altered(pattern, replacement) return (valid:gsub(pattern, replacement)) end
    ---@type string[]
    local invalid = {"", "\n \t\n", "垃圾\n", "version=1\n", valid:sub(1, -2),
        altered("version=1", "version=2"), altered("version=1", "version=0"),
        altered("version=1", "version=1.0"), valid .. "coins=1\n", valid .. "version=1\n",
        valid .. "unknown=value\n", valid .. "broken line\n", valid .. "track=other\n",
        altered("coins=2300", "coins="), altered("coins=2300", "coins=abc"),
        altered("coins=2300", "coins=-1"), altered("coins=2300", "coins=1.5"),
        altered("coins=2300", "coins=1e3"), altered("coins=2300", "coins=0x10"),
        altered("coins=2300", "coins=NaN"), altered("coins=2300", "coins=inf"),
        altered("coins=2300", "coins=9223372036854775808"),
        altered("vehicle=sport,cruiser", "vehicle=sport,,cruiser"),
        altered("vehicle=sport,cruiser", "vehicle=sport,"),
        altered("vehicle=sport,cruiser", "vehicle=,sport"),
        altered("vehicle=sport,cruiser", "vehicle=sport, ,cruiser"),
        altered("rider=green", "rider=bad color"), altered("track=circuit,lake,coast", "track=../coast"),
        valid .. "\0", altered("coins=2300", "coins=23\00100"), altered("\n", "\r")}
    for _, key in ipairs({"version", "coins", "vehicle", "rider", "track"}) do
        invalid[#invalid + 1] = altered(key .. "=[^\n]*\n", "")
    end
    -- 逐字截断，包含保留尾部换行却缺少字段的截断；不只测试任意垃圾字符串。
    for length = 1, #valid - 1 do invalid[#invalid + 1] = valid:sub(1, length) end
    for index, text in ipairs(invalid) do
        seed(text)
        local bad = fresh()
        blocked(bad, "坏档" .. index)
        local reads = readOpens
        rejected(bad.TryLoad, "缓存失败")
        bad.GetForDisplay()
        check(readOpens == reads, "失败未force不能反复读盘")
    end
    -- 写入口本身也必须探测坏档，不依赖UI或调用方提前执行TryLoad。
    for _, method in ipairs({"Save", "AddCoins", "Buy", "BuyRider", "UnlockTrack", "ResetForTests"}) do
        seed("version=99\n")
        local direct = fresh()
        local before = mutations
        rejected(function() return direct[method](0, 0) end, "无预加载直接调用" .. method)
        check(mutations == before and files[path] == "version=99\n" and not direct.HasPendingSave(),
            "写入口须在任何内存奖励或磁盘修改前发现坏档")
    end

    -- 打开、读取及清理故障均变为可恢复的加载错误，而不是抛到页面。
    for _, failure in ipairs({"exists", "construct", "isopen", "open", "read", "close", "dispose"}) do
        seed(valid)
        failExists, failConstruct, failIsOpen = failure == "exists", failure == "construct", failure == "isopen"
        failOpen, failRead, failClose, failDispose = failure == "open", failure == "read", failure == "close", failure == "dispose"
        local unreadable = fresh()
        blocked(unreadable, "读盘故障" .. failure)
        failExists, failConstruct, failIsOpen = false, false, false
        failOpen, failRead, failClose, failDispose = false, false, false, false
        rejected(unreadable.TryLoad, "存储恢复仍需显式重试")
        local before = mutations
        check(unreadable.TryLoad(true) and unreadable.GetLoadError() == nil and unreadable.Coins() == 2300,
            "force可恢复" .. failure .. "失败")
        check(mutations == before and files[path] == valid, "重读恢复不能自动写档")
    end

    seed("version=99\n")
    local retry = fresh()
    rejected(retry.TryLoad, "未知版本首次失败")
    local before = mutations
    files[path] = nil
    rejected(function() return retry.TryLoad(true) end, "失败档被移走不得自动重开")
    check(files[path] == nil and mutations == before, "force缺档不创建任何文件")
    files[path] = valid
    rejected(retry.TryLoad, "修复文件后仍保留错误直到force")
    check(retry.TryLoad(true) and retry.GetLoadError() == nil and retry.Coins() == 2300, "force读取修复后的合法原档")
    local committed = retry.Get()
    local reads = readOpens
    files[path] = "version=99\n"
    check(retry.TryLoad(true) and retry.Get() == committed and retry.Coins() == 2300 and readOpens == reads,
        "force不能丢弃已加载数据或重读外部坏文件")

    -- 保留原有购买回滚、奖励补存；补充写异常、Flush、临时校验与提交校验故障。
    seed(valid)
    local old = fresh()
    check(old.Coins() == 2300, "故障测试从合法档开始")
    for _, failure in ipairs({"write", "open", "copy", "rename", "throw", "flush", "temp", "commit"}) do
        failWrite, failOpen, failCopy, failRename = failure == "write", failure == "open", failure == "copy", failure == "rename"
        throwWrite, failFlush, corruptTemp, corruptCommit = failure == "throw", failure == "flush", failure == "temp", failure == "commit"
        local bought, message = old.UnlockTrack("alpine", 2200)
        check(not bought and message and old.Coins() == 2300 and not old.TrackUnlocked("alpine"), failure .. "失败回滚扣款和解锁")
        check(files[path] == valid, failure .. "失败保留或恢复原主档")
        check(not old.Buy("rally", 1200) and old.Coins() == 2300 and not old.Owns("rally"), failure .. "车辆购买失败回滚")
        check(not old.BuyRider("red", 900) and old.Coins() == 2300 and not old.OwnsRider("red"), failure .. "配色购买失败回滚")
        check(old.TrackUnlocked("coast") and old.GetLoadError() == nil and not old.HasPendingSave(), "保存失败不能清空历史权益或伪装成加载失败")
        failWrite, failOpen, failCopy, failRename = false, false, false, false
        throwWrite, failFlush, corruptTemp, corruptCommit = false, false, false, false
        check(fresh().Coins() == 2300, "故障后新实例仍读到旧余额")
    end
    failWrite = true
    check(not old.AddCoins(120) and old.Coins() == 2420 and old.HasPendingSave(), "奖励失败保留待保存状态")
    check(fresh().Coins() == 2300, "奖励写失败磁盘仍是原余额")
    local waiting = old.Get()
    reads = readOpens
    check(old.TryLoad(true) and old.Get() == waiting and old.Coins() == 2420 and old.HasPendingSave() and readOpens == reads,
        "force不能丢失待保存奖励或清pending")
    failWrite = false
    check(old.RetryPendingSave() and not old.HasPendingSave(), "恢复存储后补存成功")
    check(old.RetryPendingSave() and fresh().Coins() == 2420, "重复补存不重复发币")

    -- 第一次保存提交后校验损坏，原先无档应删除失败主档，而非留下坏的新档。
    files[path], files[path .. ".pending"], files[path .. ".backup"] = nil, nil, nil
    local firstSave = fresh()
    check(firstSave.TryLoad(), "首次保存回滚先初始化内存新档")
    corruptCommit = true
    check(not firstSave.AddCoins(50) and files[path] == nil and firstSave.Coins() == 50 and firstSave.HasPendingSave(),
        "新档提交校验失败删除失败主档且保留内存奖励")
    corruptCommit = false
    check(firstSave.RetryPendingSave() and fresh().Coins() == 50, "首次保存故障恢复后补存一次奖励")

    -- 三类购买入口逐一拒绝负价、分数、非数值及未知/非字符串ID；不得污染金币/权益/磁盘。
    for _, entry in ipairs({{method = "Buy", id = "rally"}, {method = "BuyRider", id = "red"},
        {method = "UnlockTrack", id = "alpine"}}) do
        seed(valid)
        local boundary = fresh()
        check(boundary.TryLoad(), "购买边界加载合法旧档")
        local beforeMutations = mutations
        for _, price in ipairs({-1, .5, math.huge, -math.huge, 0/0, "100", false, {}, 1e30}) do
            rejected(function() return boundary[entry.method](entry.id, price) end, entry.method .. "非法价")
        end
        rejected(function() return boundary[entry.method](entry.id, nil) end, entry.method .. "nil价格")
        for _, id in ipairs({"", "missing-id", "../rally", "bad,id", "bad\nid", 12, false, {}, 0/0}) do
            rejected(function() return boundary[entry.method](id, 0) end, entry.method .. "非法ID")
        end
        rejected(function() return boundary[entry.method](nil, 0) end, entry.method .. "nil ID")
        check(boundary.Coins() == 2300 and not boundary.Owns("rally") and not boundary.OwnsRider("red")
            and not boundary.TrackUnlocked("alpine") and not boundary.HasPendingSave() and mutations == beforeMutations
            and files[path] == valid, entry.method .. "全部非法参数无内存或磁盘副作用")
        check(boundary[entry.method](entry.id, 100.0) and boundary.Coins() == 2200, entry.method .. "合法整值浮点价归一为integer")
    end

    -- 奖励与多后继赛道作为同一权益事务保留；任何已覆盖的存储故障都可只补存不重发。
    for _, failure in ipairs({"write", "open", "copy", "rename", "throw", "flush", "temp", "commit"}) do
        seed(valid)
        local transaction = fresh()
        check(transaction.TryLoad(), "组合奖励从合法档开始")
        failWrite, failOpen, failCopy, failRename = failure == "write", failure == "open", failure == "copy", failure == "rename"
        throwWrite, failFlush, corruptTemp, corruptCommit = failure == "throw", failure == "flush", failure == "temp", failure == "commit"
        local saved, message, applied = transaction.GrantRaceRewards(120, {"alpine", "forest"})
        check(not saved and type(message) == "string" and applied and transaction.HasPendingSave()
            and transaction.Coins() == 2420 and transaction.TrackUnlocked("alpine") and transaction.TrackUnlocked("forest"),
            failure .. "必须同时保留金币和免费解锁待保存权益")
        check(files[path] == valid, failure .. "组合奖励失败不得丢失原主档")
        failWrite, failOpen, failCopy, failRename = false, false, false, false
        throwWrite, failFlush, corruptTemp, corruptCommit = false, false, false, false
        check(transaction.RetryPendingSave() and not transaction.HasPendingSave(), failure .. "补存权益成功")
        check(transaction.RetryPendingSave() and transaction.Coins() == 2420, failure .. "重复补存不得重复加币")
        local reloaded = fresh()
        check(reloaded.Coins() == 2420 and reloaded.TrackUnlocked("alpine") and reloaded.TrackUnlocked("forest"),
            failure .. "重读同时保留金币与所有后继赛道")
    end
    seed(valid)
    local grants = fresh()
    check(grants.TryLoad(), "免费权益参数校验加载")
    local grantMutations = mutations
    for _, ids in ipairs({{"alpine", "unknown"}, {"alpine", "alpine"}, {[2] = "alpine"},
        {"alpine", extra = "forest"}, false, "alpine", {"bad,id"}}) do
        local saved, _, applied = grants.GrantRaceRewards(100, ids)
        check(saved == false and applied == false, "非法权益列表不能部分发金币或解锁")
        local unlocked, _, granted = grants.GrantTrackUnlocks(ids)
        check(unlocked == false and granted == false, "非法免费权益无副作用")
    end
    check(grants.Coins() == 2300 and not grants.TrackUnlocked("alpine") and not grants.HasPendingSave()
        and mutations == grantMutations, "权益校验在全部变更前完成")
    failWrite = true
    local unlocked, _, granted = grants.GrantTrackUnlocks({"alpine"})
    check(not unlocked and granted and grants.TrackUnlocked("alpine") and grants.Coins() == 2300
        and grants.HasPendingSave(), "单独免费权益失败仍能补存而不重发金币")
    failWrite = false
    check(grants.RetryPendingSave() and fresh().TrackUnlocked("alpine") and fresh().Coins() == 2300,
        "免费权益补存不增加金币")

    print(string.format("[ProfileChecks] PASS %d项，%d次内存写入，含严格旧格式/坏档禁写/加载重试/写入回滚/参数边界/组合权益，玩家档未访问", assertions, writes))
    return {passed = true, assertions = assertions}
end

-- 必须在HUD.New之前显式启用；只替换同一模块表的方法，不加载/替换玩家数据。
-- 返回幂等restore，调用方须在HUD构造或断言失败时同样执行。
---@return fun()
function Checks.BeginUnavailableProfile()
    ---@type table<string, any>
    local profile = require("Profile")
    local message = "隔离验收：竞速存档损坏，原档已保留"
    local names = {"TryLoad", "GetLoadError", "GetForDisplay", "HasPendingSave", "Get", "Coins", "Owns",
        "OwnsRider", "TrackUnlocked", "Save", "AddCoins", "Buy", "BuyRider", "UnlockTrack", "GrantRaceRewards", "GrantTrackUnlocks", "RetryPendingSave", "ResetForTests"}
    ---@type table<string, function>
    local methods = {}
    for _, name in ipairs(names) do methods[name] = profile[name] end
    local restored = false
    local function restore()
        if restored then return end
        restored = true
        for _, name in ipairs(names) do profile[name] = methods[name] end
    end
    local ok, failure = pcall(function()
        profile.TryLoad = function() return false, message end
        profile.GetLoadError = function() return message end
        profile.GetForDisplay = function()
            return {coins = 0, owned = {[profile.FREE_VEHICLE] = true},
                ownedRiders = {[profile.FREE_RIDER] = true}, unlockedTracks = {[profile.FREE_TRACK] = true}}, message
        end
        profile.HasPendingSave = function() return false end
        for _, name in ipairs({"Get", "Coins", "Owns", "OwnsRider", "TrackUnlocked", "Save", "AddCoins", "Buy",
            "BuyRider", "UnlockTrack", "GrantRaceRewards", "GrantTrackUnlocks", "RetryPendingSave", "ResetForTests"}) do
            profile[name] = function() error("[ProfileChecks] 坏档UI越界调用严格Profile API：" .. name, 2) end
        end
    end)
    if not ok then restore(); error(failure, 0) end
    return restore
end

-- 与BeginUnavailableProfile配合，验证真正HUD和main回调，不替换成假的业务入口。
---@param hud HUD
---@return table
function Checks.RunUnavailableUI(hud)
    local count = 0
    local function check(value, message)
        assert(value, "[ProfileChecks] " .. message)
        count = count + 1
    end
    local oldScreen, oldCareer = hud.screen, hud.careerRace
    local oldTrack, oldVehicle, oldRider = hud.selectedTrack, hud.selectedVehicle, hud.selectedRider
    local notice = hud.ShowNotice
    local ownNotice = rawget(hud, "ShowNotice")
    local notices = 0
    local function restore()
        hud.ShowNotice = ownNotice
        hud:CloseModal()
        -- 先在职业态恢复选中赛道，避免原赛道在占位档中不可选。
        hud:SetCareerRace(true)
        hud:SelectTrack(oldTrack, false)
        hud:SetCareerRace(oldCareer == true)
        hud:SelectVehicle(oldVehicle, false)
        hud:SelectRider(oldRider, false)
        hud:RefreshOwnership()
        hud:SetScreen(oldScreen)
    end
    local ok, failure = pcall(function()
        hud:SetCareerRace(false)
        hud:SetScreen("menu")
        check(hud.coinLabel:GetText() == "竞速进度不可用 · 原档已保留", "坏档HUD须显示不可用而非金币0")
        check(hud.routeBalance:GetText() == "竞速进度不可用 · 原档保留", "坏档赛道页须显示不可用余额")
        hud:SelectVehicle("sport", false)
        hud:SelectRider("green", false)
        hud:RefreshOwnership()
        hud:OpenTracks()
        hud:SetScreen("menu")
        check(hud.coinLabel:GetText() == "竞速进度不可用 · 原档已保留", "刷新及切页不能读严格余额或清掉错误提示")
        hud.ShowNotice = function(self, title, text)
            check(type(title) == "string" and type(text) == "string" and text:find("原档", 1, true), "拦截必须给出原档保留提示")
            notices = notices + 1
            return notice(self, title, text)
        end
        for _, entry in ipairs({
            {name = "start", value = true}, {name = "confirmVehicle", value = "sport"},
            {name = "buyVehicle", value = "rally"}, {name = "buyRider", value = "red"},
            {name = "unlockTrack", value = "lake"}, {name = "selectTrack", value = "forest"},
        }) do
            local action = hud.actions[entry.name]
            check(type(action) == "function", "缺少真实入口回调：" .. entry.name)
            local before = notices
            action(entry.value)
            check(notices == before + 1 and hud:IsModalOpen(), entry.name .. "须拦截并打开真实提示")
            check(hud.screen == "menu", entry.name .. "不得进入车库/加载或暗中切页")
            hud:CloseModal()
        end
        hud:SetCareerRace(true)
        check(hud:SelectTrack("forest", false) and hud.selectedTrack == "forest", "坏独立竞速档不能阻止职业比赛同步赛道")
    end)
    local restored, restoreError = pcall(restore)
    if not ok then error(failure, 0) end
    if not restored then error(restoreError, 0) end
    print(string.format("[ProfileChecks] 坏档真实HUD/入口隔离验收 PASS %d项，玩家档未访问", count))
    return {passed = true, assertions = count}
end

return Checks
