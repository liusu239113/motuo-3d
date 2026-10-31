-- 本地进度：金币、已购车辆、已购车手配色、已解锁赛道。
-- 单独模块，只经 File 读写沙箱文本；不触碰渲染、仿真或世界构建。
local Profile = {}

local SAVE_PATH = "pursuit_profile.txt"
local SAVE_VERSION = 1

---@class PursuitProfile
---@field coins integer
---@field owned table<string, boolean>
---@field ownedRiders table<string, boolean>
---@field unlockedTracks table<string, boolean>

-- 首发免费：一台入门仿赛 + 一台绿色车手配色 + 默认封闭赛道。
Profile.FREE_VEHICLE = "sport"
Profile.FREE_RIDER = "green"
Profile.FREE_TRACK = "circuit"

---@type PursuitProfile
local data = nil

---@return PursuitProfile
local function defaults()
    return {
        coins = 0,
        owned = {[Profile.FREE_VEHICLE] = true},
        ownedRiders = {[Profile.FREE_RIDER] = true},
        unlockedTracks = {[Profile.FREE_TRACK] = true},
    }
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

---@param text string
---@return PursuitProfile
local function parse(text)
    local p = defaults()
    for line in (text or ""):gmatch("[^\r\n]+") do
        local key, value = line:match("^([%w_]+)=(.*)$")
        if key == "version" then
            -- 版本不是本版则保持默认，不迁移未知格式。
            if (tonumber(trim(value)) or 0) ~= SAVE_VERSION then return defaults() end
        elseif key == "coins" then
            p.coins = math.max(0, math.floor(tonumber(trim(value)) or 0))
        elseif key == "vehicle" or key == "rider" or key == "track" then
            local target = key == "vehicle" and p.owned or (key == "rider" and p.ownedRiders or p.unlockedTracks)
            for id in trim(value):gmatch("[^,]+") do target[trim(id)] = true end
        end
    end
    -- 免费项始终保留，避免旧档或手改导致连默认车都开不了。
    p.owned[Profile.FREE_VEHICLE] = true
    p.ownedRiders[Profile.FREE_RIDER] = true
    p.unlockedTracks[Profile.FREE_TRACK] = true
    return p
end

local function serialize(p)
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
    }, "\n") .. "\n"
end

---@return PursuitProfile
function Profile.Get()
    if not data then
        local text = nil
        -- 首次运行没有存档时不要触发引擎的“打开失败”错误日志。
        local file = fileSystem:FileExists(SAVE_PATH) and File(SAVE_PATH, FILE_READ) or nil
        if file and file:IsOpen() then
            text = file:ReadString()
            file:Close()
        end
        data = parse(text)
    end
    return data
end

---@return boolean, string?
function Profile.Save()
    local p = Profile.Get()
    local file = File(SAVE_PATH, FILE_WRITE)
    if not file or not file:IsOpen() then return false, "无法写入进度文件" end
    local written = file:WriteString(serialize(p))
    file:Close()
    file:Dispose()
    if not written then return false, "保存进度失败，请重试" end
    return true
end

---@return integer
function Profile.Coins() return Profile.Get().coins end

---@param vehicleId string
---@return boolean
function Profile.Owns(vehicleId) return Profile.Get().owned[vehicleId] == true end

---@param riderId string
---@return boolean
function Profile.OwnsRider(riderId) return Profile.Get().ownedRiders[riderId] == true end

---@param trackId string
---@return boolean
function Profile.TrackUnlocked(trackId) return Profile.Get().unlockedTracks[trackId] == true end

---@param amount integer
function Profile.AddCoins(amount)
    local p = Profile.Get()
    p.coins = math.max(0, p.coins + math.floor(amount or 0))
    Profile.Save()
end

---@param vehicleId string
---@param price integer
---@return boolean, string
function Profile.Buy(vehicleId, price)
    local p = Profile.Get()
    if p.owned[vehicleId] then return false, "已拥有" end
    if p.coins < price then return false, "金币不足" end
    p.coins = p.coins - price
    p.owned[vehicleId] = true
    local saved, message = Profile.Save()
    if not saved then
        p.coins = p.coins + price
        p.owned[vehicleId] = nil
        return false, message or "保存购买失败，请重试"
    end
    return true, "已购买"
end

---@param riderId string
---@param price integer
---@return boolean, string
function Profile.BuyRider(riderId, price)
    local p = Profile.Get()
    if p.ownedRiders[riderId] then return false, "已拥有" end
    if p.coins < price then return false, "金币不足" end
    p.coins = p.coins - price
    p.ownedRiders[riderId] = true
    local saved, message = Profile.Save()
    if not saved then
        p.coins = p.coins + price
        p.ownedRiders[riderId] = nil
        return false, message or "保存购买失败，请重试"
    end
    return true, "已购买"
end

-- 解锁赛道按“通关前一站”或金币购买，由调用方决定规则与价格。
---@param trackId string
---@param price integer
---@return boolean, string
function Profile.UnlockTrack(trackId, price)
    local p = Profile.Get()
    if p.unlockedTracks[trackId] then return false, "已解锁" end
    if p.coins < price then return false, "金币不足" end
    p.coins = p.coins - price
    p.unlockedTracks[trackId] = true
    local saved, message = Profile.Save()
    if not saved then
        p.coins = p.coins + price
        p.unlockedTracks[trackId] = nil
        return false, message or "保存解锁失败，请重试"
    end
    return true, "已解锁"
end

-- 通关奖励：名次越高给得越多；被抓/未完成也有少量参与奖励。
---@param place integer 1..9
---@param laps integer
---@param trackReward integer 该赛道单圈基础奖励
---@return integer
function Profile.RaceReward(place, laps, trackReward)
    local base = math.max(1, math.floor(trackReward or 120)) * math.max(1, math.floor(laps or 1))
    local byPlace = {1.0, 0.78, 0.64, 0.54, 0.46, 0.40, 0.35, 0.31, 0.28}
    local factor = byPlace[math.max(1, math.min(9, math.floor(place or 9)))] or 0.25
    return math.max(20, math.floor(base * factor + 0.5))
end

-- 测试或换档时显式重置；正常流程不调用。
function Profile.ResetForTests()
    data = defaults()
    Profile.Save()
end

return Profile
