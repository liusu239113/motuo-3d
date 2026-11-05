-- 本地进度：金币、已购车辆、已购车手配色、已解锁赛道。
-- 单独模块，只经 File 读写沙箱文本；不触碰渲染、仿真或世界构建。
local Profile = {}

local SAVE_PATH = "pursuit_profile.txt"
local SAVE_VERSION = 2

---@class PursuitProfile
---@field coins integer
---@field owned table<string, boolean>
---@field trials table<string, integer>
---@field ownedRiders table<string, boolean>
---@field unlockedTracks table<string, boolean>

-- 首发免费：一台入门仿赛 + 一台绿色车手配色 + 默认封闭赛道。
-- 玩家默认只有小电驴；其余载具都用金币解锁。
Profile.FREE_VEHICLE = "ebike"
Profile.FREE_RIDER = "green"
Profile.FREE_TRACK = "circuit"

---@type PursuitProfile
local data = nil
local pendingSave = false
---@type string?
local loadError = nil

-- 写入口只接受当前业务目录中的购买 ID；读取仍按 parse 的语法规则保留历史 ID。
-- 这些集合刻意不参与 defaults/parse，因此不会让旧档迁移时丢失已经下架的权益。
local KNOWN_VEHICLES = {
    sport = true, sport_2 = true, sport_3 = true,
    cruiser = true, cruiser_2 = true, cruiser_3 = true,
    rally = true, rally_2 = true, rally_3 = true,
}
for _,v in ipairs(require("MixedVehicles").List) do KNOWN_VEHICLES[v.id]=true end
local KNOWN_RIDERS = {red = true, blue = true, yellow = true, white = true, green = true, violet = true}
local KNOWN_TRACKS = {circuit = true, lake = true, alpine = true, coast = true, canyon = true, forest = true}

local function validId(value)
    return type(value) == "string" and value:match("^[A-Za-z0-9_-]+$") ~= nil
end

local function validKnownId(value, known)
    return validId(value) and known[value] == true
end

local function validNonNegativeInteger(value)
    return type(value) == "number" and value == value and value ~= math.huge
        and value ~= -math.huge and value >= 0 and value % 1 == 0
        and math.tointeger(value) ~= nil
end

local function validIntegerList(ids, known)
    if ids == nil then return true end
    if type(ids) ~= "table" or getmetatable(ids) ~= nil then return false end
    local count = 0
    local seen = {}
    for index, id in pairs(ids) do
        if not validNonNegativeInteger(index) or index < 1 or index > #ids
            or not validKnownId(id, known) or seen[id] then return false end
        seen[id] = true
        count = count + 1
    end
    return count == #ids
end

-- Get 保持旧调用语义返回实时对象；任何写入前仍验证完整内存快照，避免错误调用
-- 将 NaN/分数/非法键序列化成坏档并覆盖上一份正常存档。历史合法ID不按目录过滤。
local function validProfile(p)
    if type(p) ~= "table" or not validNonNegativeInteger(p.coins)
        or type(p.owned) ~= "table" or type(p.ownedRiders) ~= "table"
        or type(p.unlockedTracks) ~= "table" then return false end
    for _, set in ipairs({p.owned, p.ownedRiders, p.unlockedTracks}) do
        if type(set) ~= "table" or getmetatable(set) ~= nil then return false end
        for id, owned in pairs(set) do
            if not validId(id) or type(owned) ~= "boolean" then return false end
        end
    end
    if type(p.trials)~="table" or getmetatable(p.trials)~=nil then return false end
    for id,count in pairs(p.trials) do
        if not validId(id) or not validNonNegativeInteger(count) or count>9999 then return false end
    end
    return type(p.owned) == "table" and type(p.ownedRiders) == "table" and type(p.unlockedTracks) == "table"
end

-- 打开、读取及清理都可能抛错；已有文件的任何读取失败都不能伪装成新档。
---@param path string
---@return string?
local function readText(path)
    ---@type File?
    local file = nil
    local ok, text = pcall(function()
        file = File(path, FILE_READ)
        if not file or not file:IsOpen() then return nil end
        return file:ReadString()
    end)
    local cleaned = true
    if file then
        local closed = pcall(function() file:Close() end)
        local disposed = pcall(function() file:Dispose() end)
        cleaned = closed and disposed
    end
    if ok and cleaned and type(text) == "string" then return text end
    return nil
end

---@return PursuitProfile
local function defaults()
    return {
        coins = 0,
        owned = {[Profile.FREE_VEHICLE] = true},
        trials = {},
        ownedRiders = {[Profile.FREE_RIDER] = true},
        unlockedTracks = {[Profile.FREE_TRACK] = true},
    }
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- 存档迁移标记：解析时回收了旧档里 0 金币白拿的赤焰 R1000，需要立刻回写磁盘。
local revokedSport = false

---@param text string
---@return PursuitProfile?, string?
local function parse(text)
    -- 已核验的v1写档器始终输出五字段及末尾换行；不把缺行/半行当旧格式迁移。
    if text == "" or text:sub(-1) ~= "\n" then return nil, "竞速存档为空或已截断；原档已保留" end
    local normalized = text:gsub("\r\n", "\n")
    if normalized:find("\r") or normalized:find("[%z\1-\8\11\12\14-\31\127]") then
        return nil, "竞速存档含无效字符；原档已保留"
    end
    ---@type table<string, string>
    local fields = {}
    ---@type table<string, boolean>
    local allowed = {version = true, coins = true, vehicle = true, rider = true, track = true, trials=true}
    for line in normalized:gmatch("[^\n]+") do
        if trim(line) ~= "" then
            local key, value = line:match("^([%w_]+)=(.*)$")
            if not key or not allowed[key] or fields[key] ~= nil then
                return nil, "竞速存档字段无效或重复；原档已保留"
            end
            fields[key] = trim(value)
        end
    end
    for _, key in ipairs({"version", "coins", "vehicle", "rider", "track"}) do
        if fields[key] == nil then return nil, "竞速存档缺少字段：" .. key .. "；原档已保留" end
    end
    if fields.version ~= "1" and fields.version ~= tostring(SAVE_VERSION) then return nil, "不支持的竞速存档版本；原档已保留" end
    if fields.version=="2" and fields.trials==nil then return nil,"试驾存档字段缺失，原档已保留" end
    if not fields.coins:match("^%d+$") then return nil, "竞速存档金币无效；原档已保留" end
    local coins = math.tointeger(tonumber(fields.coins))
    if not coins or coins < 0 then return nil, "竞速存档金币超出范围；原档已保留" end
    local p = defaults()
    p.coins = coins
    for token in ((fields.trials or "")..","):gmatch("(.-),") do
        if token~="" then
            local id,count=token:match("^([%w_-]+):(%d+)$")
            local n=count and math.tointeger(tonumber(count))
            if not id or not n or n<0 or n>9999 or p.trials[id]~=nil then return nil,"试驾次数无效，原档已保留" end
            p.trials[id]=n
        end
    end
    for _, key in ipairs({"vehicle", "rider", "track"}) do
        local value = fields[key]
        local target = key == "vehicle" and p.owned or (key == "rider" and p.ownedRiders or p.unlockedTracks)
        if value ~= "" then
            for token in (value .. ","):gmatch("(.-),") do
                local id = trim(token)
                if not id:match("^[A-Za-z0-9_-]+$") then
                    return nil, "竞速存档权益列表无效；原档已保留"
                end
                -- 不按当前目录过滤：合法的历史ID必须保留，免费项由defaults补齐。
                target[id] = true
            end
        end
    end
    -- 存档迁移：sport（赤焰 R1000）曾以 0 金币售出，旧档里点过购买就会被记成已拥有。
    -- 现在它是 500 金币付费车，旧档中这份未付费的权益一律回收。
    if p.owned.sport then
        p.owned.sport = nil
        revokedSport = true
    end
    return p
end

local function serialize(p)
    local trials={}
    for id,count in pairs(p.trials or {}) do trials[#trials+1]=id..":"..count end
    table.sort(trials)
    local function join(set)
        local ids = {}
        for id, owned in pairs(set) do if owned then ids[#ids + 1] = id end end
        table.sort(ids)
        return table.concat(ids, ",")
    end
    return table.concat({
        "version=" .. SAVE_VERSION,
        "coins=" .. tostring(math.floor(p.coins or 0)),
        "vehicle=" .. join(p.owned),
        "rider=" .. join(p.ownedRiders),
        "track=" .. join(p.unlockedTracks),
        "trials="..table.concat(trials,","),
    }, "\n") .. "\n"
end

-- force只重试已失败的加载；绝不丢弃成功加载的数据或尚待补存的奖励。
---@param force? boolean
---@return boolean, string?
function Profile.TryLoad(force)
    if force ~= nil and type(force) ~= "boolean" then return false, "加载重试参数必须为布尔值" end
    if data then return true end
    if loadError and not force then return false, loadError end
    local retrying = loadError ~= nil
    local called, loaded, message = pcall(function()
        if not fileSystem:FileExists(SAVE_PATH) then
            -- 原先失败的主档被移走也不代表玩家确认重开。
            if retrying then return nil, "竞速存档仍不可用；未创建新档，请恢复原档后重试" end
            return defaults()
        end
        local text = readText(SAVE_PATH)
        if text == nil then return nil, "读取竞速进度失败，原档未修改，请稍后重试" end
        return parse(text)
    end)
    if not called then
        loadError = "读取竞速进度异常，原档未修改，请稍后重试"
        return false, loadError
    end
    if not loaded then
        loadError = message or "竞速存档无效；原档已保留"
        return false, loadError
    end
    data, loadError = loaded, nil
    -- 回收了旧档白拿的赤焰 R1000 后立刻回写，避免每次启动重复迁移。
    if revokedSport then
        revokedSport = false
        pendingSave = true
        Profile.Save()
        print("[竞速进度] 已回收旧存档中 0 金币获得的赤焰 R1000，现需 500 金币购买")
    end
    return true
end

-- 查询已记录的错误，不额外读盘；首次探测请使用TryLoad/GetForDisplay。
---@return string?
function Profile.GetLoadError() return loadError end

-- 只供UI读取。错误占位每次独立创建，既不缓存为data，也不授予保存权限。
---@return PursuitProfile, string?
function Profile.GetForDisplay()
    local ok, message = Profile.TryLoad()
    if not ok then return defaults(), message end
    return Profile.Get(), nil
end

-- 试驾只在实际发车前扣除，打开车库、下载失败和预览都不扣次数。
function Profile.Trials(id)
    if not validKnownId(id,KNOWN_VEHICLES) then return 0 end
    return Profile.Get().trials[id] or 0
end
function Profile.CanDrive(id) return Profile.Owns(id) or Profile.Trials(id)>0 end
function Profile.GrantTrials(id)
    if not validKnownId(id,KNOWN_VEHICLES) then return false,"未知载具",false end
    local loaded,message=Profile.TryLoad();if not loaded then return false,message,false end
    local p=Profile.Get()
    if not validProfile(p) then return false,"进度无效，未发放试驾",false end
    if p.owned[id] then return false,"已永久拥有，无需观看广告",false end
    if (p.trials[id] or 0)>9996 then return false,"试驾次数已达上限",false end
    p.trials[id]=(p.trials[id] or 0)+3
    pendingSave=true
    local saved,err=Profile.Save()
    return saved,err,true
end
function Profile.ConsumeTrial(id)
    if not validKnownId(id,KNOWN_VEHICLES) then return false,"未知载具" end
    local loaded,message=Profile.TryLoad();if not loaded then return false,message end
    local p=Profile.Get()
    if not validProfile(p) then return false,"竞速进度无效" end
    if p.owned[id] then return true end
    local count=p.trials[id] or 0
    if count<=0 then return false,"请使用金币解锁，或完整观看广告获得三局体验" end
    p.trials[id]=count-1
    local saved,err=Profile.Save()
    if not saved then p.trials[id]=count;return false,err or "试驾次数保存失败，未扣次" end
    return true
end

---@return PursuitProfile
function Profile.Get()
    local ok, message = Profile.TryLoad()
    if not ok then error(message or "竞速存档不可用", 2) end
    return data
end

---@return boolean, string?
function Profile.Save()
    local loaded, loadMessage = Profile.TryLoad()
    if not loaded then return false, loadMessage end
    if not validProfile(data) then return false, "竞速进度内存数据无效，原档未修改" end
    local encoded, text = pcall(serialize, data)
    if not encoded then return false, "竞速进度编码失败，原档未修改" end
    local temp, backup = SAVE_PATH .. ".pending", SAVE_PATH .. ".backup"
    ---@type File?
    local file = nil
    local called, written = pcall(function()
        file = File(temp, FILE_WRITE)
        if not file or not file:IsOpen() then return false end
        local ok = file:WriteString(text)
        file:Flush()
        return ok
    end)
    local cleaned = true
    if file then
        local closed = pcall(function() file:Close() end)
        local disposed = pcall(function() file:Dispose() end)
        cleaned = closed and disposed
    end
    if not called or not written or not cleaned or readText(temp) ~= text then
        return false, "保存进度失败，原档已保留"
    end
    local existsCalled, hadOld = pcall(function() return fileSystem:FileExists(SAVE_PATH) end)
    if not existsCalled then return false, "无法确认竞速原档，未提交进度" end
    if hadOld then
        local copied, copyResult = pcall(function() return fileSystem:Copy(SAVE_PATH, backup) end)
        if not copied or not copyResult then return false, "无法备份竞速进度，原档已保留" end
    end
    local renamed, renameResult = pcall(function() return fileSystem:Rename(temp, SAVE_PATH) end)
    if renamed and not renameResult then return false, "无法提交竞速进度，原档已保留" end
    if not renamed or readText(SAVE_PATH) ~= text then
        -- Rename 抛错时也可能已产生副作用，因此同样尝试恢复；恢复异常不能冒泡到奖励入口。
        local restored, restoreResult = pcall(function()
            if hadOld then return fileSystem:Copy(backup, SAVE_PATH) end
            return fileSystem:Delete(SAVE_PATH)
        end)
        if not restored or not restoreResult then return false, "竞速进度提交失败，备份仍保留，请勿退出并重试" end
        return false, "竞速进度校验失败，已尝试恢复备份"
    end
    pendingSave = false
    return true
end

-- 奖励保存失败保留待保存状态，主循环重试；不重复加币或再次消耗广告。
function Profile.HasPendingSave() return pendingSave end
---@return boolean, string?
function Profile.RetryPendingSave()
    if loadError then return false, loadError end
    if not pendingSave then return true end
    return Profile.Save()
end

---@return integer
function Profile.Coins() return Profile.Get().coins end

---@param vehicleId string
---@return boolean
function Profile.Owns(vehicleId)
    if not validId(vehicleId) then return false end
    return Profile.Get().owned[vehicleId] == true
end

---@param riderId string
---@return boolean
function Profile.OwnsRider(riderId)
    if not validId(riderId) then return false end
    return Profile.Get().ownedRiders[riderId] == true
end

---@param trackId string
---@return boolean
function Profile.TrackUnlocked(trackId)
    if not validId(trackId) then return false end
    return Profile.Get().unlockedTracks[trackId] == true
end

---@param amount integer
---@return boolean saved
---@return string? message
---@return boolean applied 本次奖励是否已进入内存；不能用其他奖励的pending代替此结果
function Profile.AddCoins(amount)
    if not validNonNegativeInteger(amount) then return false, "奖励金币必须为非负整数", false end
    local loaded, message = Profile.TryLoad()
    if not loaded then return false, message, false end
    local p = Profile.Get()
    if not validProfile(p) then return false, "竞速进度内存数据无效，原档未修改", false end
    local delta=math.tointeger(amount)
    if p.coins>math.maxinteger-delta then return false,"金币已达到可保存上限，原余额未修改",false end
    p.coins = p.coins + delta
    pendingSave = true
    local saved, saveMessage = Profile.Save()
    return saved, saveMessage, true
end

---@param vehicleId string
---@param price integer
---@return boolean, string
function Profile.Buy(vehicleId, price)
    if not validKnownId(vehicleId, KNOWN_VEHICLES) then return false, "未知车辆，购买未执行" end
    if not validNonNegativeInteger(price) then return false, "车辆价格必须为非负整数" end
    local loaded, message = Profile.TryLoad()
    if not loaded then return false, message or "竞速存档不可用" end
    local p = Profile.Get()
    if not validProfile(p) then return false, "竞速进度内存数据无效，原档未修改" end
    local cost = math.tointeger(price)
    if p.owned[vehicleId] then return false, "已拥有" end
    if p.coins < cost then return false, "金币不足" end
    p.coins = p.coins - cost
    p.owned[vehicleId] = true
    local saved, saveMessage = Profile.Save()
    if not saved then
        p.coins = p.coins + cost
        p.owned[vehicleId] = nil
        return false, saveMessage or "保存购买失败，请重试"
    end
    return true, "已购买"
end

---@param riderId string
---@param price integer
---@return boolean, string
function Profile.BuyRider(riderId, price)
    if not validKnownId(riderId, KNOWN_RIDERS) then return false, "未知车手配色，购买未执行" end
    if not validNonNegativeInteger(price) then return false, "车手配色价格必须为非负整数" end
    local loaded, message = Profile.TryLoad()
    if not loaded then return false, message or "竞速存档不可用" end
    local p = Profile.Get()
    if not validProfile(p) then return false, "竞速进度内存数据无效，原档未修改" end
    local cost = math.tointeger(price)
    if p.ownedRiders[riderId] then return false, "已拥有" end
    if p.coins < cost then return false, "金币不足" end
    p.coins = p.coins - cost
    p.ownedRiders[riderId] = true
    local saved, saveMessage = Profile.Save()
    if not saved then
        p.coins = p.coins + cost
        p.ownedRiders[riderId] = nil
        return false, saveMessage or "保存购买失败，请重试"
    end
    return true, "已购买"
end

-- 解锁赛道按“通关前一站”或金币购买，由调用方决定规则与价格。
---@param trackId string
---@param price integer
---@return boolean, string
function Profile.UnlockTrack(trackId, price)
    if not validKnownId(trackId, KNOWN_TRACKS) then return false, "未知赛道，解锁未执行" end
    if not validNonNegativeInteger(price) then return false, "赛道价格必须为非负整数" end
    local loaded, message = Profile.TryLoad()
    if not loaded then return false, message or "竞速存档不可用" end
    local p = Profile.Get()
    if not validProfile(p) then return false, "竞速进度内存数据无效，原档未修改" end
    local cost = math.tointeger(price)
    if p.unlockedTracks[trackId] then return false, "已解锁" end
    if p.coins < cost then return false, "金币不足" end
    p.coins = p.coins - cost
    p.unlockedTracks[trackId] = true
    local saved, saveMessage = Profile.Save()
    if not saved then
        p.coins = p.coins + cost
        p.unlockedTracks[trackId] = nil
        return false, saveMessage or "保存解锁失败，请重试"
    end
    return true, "已解锁"
end

-- 将一场比赛的金币及免费解锁放在同一个内存事务中提交。
-- saved=false 且 applied=true 表示内存奖励已应用、但磁盘待补存；只调用 RetryPendingSave，不能再次发奖。
---@param amount integer
---@param unlockTrackIds? string[]
---@return boolean saved, string? message, boolean applied
function Profile.GrantRaceRewards(amount, unlockTrackIds)
    if not validNonNegativeInteger(amount) then return false, "比赛奖励必须为非负整数", false end
    if not validIntegerList(unlockTrackIds, KNOWN_TRACKS) then return false, "免费解锁赛道列表无效", false end
    local loaded, loadMessage = Profile.TryLoad()
    if not loaded then return false, loadMessage or "竞速存档不可用", false end
    local p = Profile.Get()
    if not validProfile(p) then return false, "竞速进度内存数据无效，原档未修改", false end
    local delta = math.tointeger(amount)
    if p.coins > math.maxinteger - delta then
        return false, "金币已达到可保存上限，原余额未修改", false
    end
    for index = 1, unlockTrackIds and #unlockTrackIds or 0 do
        local id = unlockTrackIds[index]
        p.unlockedTracks[id] = true
    end
    p.coins = p.coins + delta
    pendingSave = true
    local saved, saveMessage = Profile.Save()
    if saved then return true, nil, true end
    -- Save 保留 pendingSave；内存状态不可回滚，否则重试会丢失已授予权益。
    return false, saveMessage or "保存比赛奖励失败，请稍后重试", true
end

-- 单独补记免费权益，供主方已有金币结算但解锁保存失败的旧流程迁移使用。
-- 不加金币；失败时保留内存权益并允许 RetryPendingSave。
---@param unlockTrackIds string[]
---@return boolean saved, string? message, boolean applied
function Profile.GrantTrackUnlocks(unlockTrackIds)
    if type(unlockTrackIds) ~= "table" or not validIntegerList(unlockTrackIds, KNOWN_TRACKS) or #unlockTrackIds == 0 then
        return false, "免费解锁赛道列表无效", false
    end
    local loaded, loadMessage = Profile.TryLoad()
    if not loaded then return false, loadMessage or "竞速存档不可用", false end
    local p = Profile.Get()
    if not validProfile(p) then return false, "竞速进度内存数据无效，原档未修改", false end
    local changed = false
    for index = 1, #unlockTrackIds do
        local id = unlockTrackIds[index]
        if not p.unlockedTracks[id] then p.unlockedTracks[id] = true; changed = true end
    end
    if not changed then
        if pendingSave then
            local saved, saveMessage = Profile.RetryPendingSave()
            return saved, saveMessage, true
        end
        return true, nil, true
    end
    pendingSave = true
    local saved, saveMessage = Profile.Save()
    if saved then return true, nil, true end
    return false, saveMessage or "保存免费解锁失败，请稍后重试", true
end

-- 通关奖励：名次越高给得越多；被抓/未完成也有少量参与奖励。
---@param place integer 1..9
---@param laps integer
---@param trackReward integer 该赛道单圈基础奖励
---@return integer reward
---@return string? message
function Profile.RaceReward(place, laps, trackReward)
    if place == nil then place = 9 end
    if laps == nil then laps = 1 end
    if trackReward == nil then trackReward = 120 end
    if not validNonNegativeInteger(place) or place < 1 or place > 9
        or not validNonNegativeInteger(laps) or laps < 1
        or not validNonNegativeInteger(trackReward) or trackReward < 1 then
        return 0, "比赛奖励参数必须为有效名次及正整数圈数、基础奖励"
    end
    local count, perLap = math.tointeger(laps), math.tointeger(trackReward)
    if perLap > math.maxinteger // count then return 0, "比赛奖励超出整数上限" end
    local base = count * perLap
    local byPlace = {100, 78, 64, 54, 46, 40, 35, 31, 28}
    local percent = byPlace[math.tointeger(place)]
    -- 分段整数计算避免 base*percent 或浮点舍入越过64位上限。
    local reward = (base // 100) * percent + ((base % 100) * percent + 50) // 100
    return math.max(20, assert(math.tointeger(reward))), nil
end

-- 测试或换档时显式重置；正常流程不调用，也不允许绕过已有坏档保护。
---@return boolean, string?
function Profile.ResetForTests()
    local loaded, message = Profile.TryLoad()
    if not loaded then return false, message end
    data = defaults()
    return Profile.Save()
end

return Profile
