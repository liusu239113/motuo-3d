-- 真实车队合同：必须在车行显式签约；旧 career.team 只是展示，不会自动转为合同。
-- Sign/Claim 自带事务；OnRace 只修改赛事结算事务的草稿，禁止在其中再开事务。
-- 所有奖励均为固定整数分；签字不发钱，履约后才发首轮签约奖金/后续赞助奖。
local Config = require("Career.Config")
local Team = {}
local ID = "nancheng_speed"
local NAME = "南城极速车队"
local SPONSOR = "南城机车联合赞助"
local PREFIX = "team-contract:" .. ID .. ":round:"
local MAX_INTEGER = 9007199254740991
local REWARDS = {150000, 240000, 360000}

---@class CareerTeamRaceRecord
---@field round integer
---@field series integer
---@field place integer
---@field finished boolean
---@class CareerTeamContract
---@field version integer
---@field id string
---@field round integer 下一次领奖轮次；领取成功后加一，永不回退
---@field level integer 1至3级，满级后保留
---@field season integer 每完成三轮续约进入下一赛季
---@field signedAfterStart integer 签约前已报名的赛事不能回填进度
---@field finishes integer 本轮达到赛事等级要求的完赛数
---@field podiums integer 本轮达到赛事等级要求的领奖台数
---@field points integer 本轮有效完赛产生的合同积分，不引用历史总积分
---@field seenRaceIds table<string, CareerTeamRaceRecord> 跨轮次永久去重，DNF也占用赛事ID
---@class CareerTeamProfile: CareerProfile
---@field teamContract? CareerTeamContract

local function integer(value, minimum, maximum)
    return type(value) == "number" and value == value and value % 1 == 0
        and value >= minimum and value <= (maximum or MAX_INTEGER)
end

local function terms(round)
    local level = math.min(3, round)
    local season = 1 + math.floor((round - 1) / 3)
    return {
        level = level, season = season,
        requiredPoints = 9, requiredFinishes = 3, requiredPodiums = 1,
        -- 始终三场有效完赛；赛事等级/合同积分逐步提高，但最多海岸级、9分。
        minSeries = math.min(4, level + season - 1),
        requiredRoundPoints = math.min(9, 3 + (level - 1) * 2 + season - 1),
        rewardCents = REWARDS[level],
    }
end

local function rewardKey(round)
    return PREFIX .. string.format("%d", round)
end

local function raceSequence(id)
    if type(id) ~= "string" then return nil end
    local digits = id:match("^career%-race:(%d+)$")
    local sequence = digits and tonumber(digits)
    if not integer(sequence, 1) or id ~= "career-race:" .. string.format("%d", sequence) then return nil end
    return sequence
end

local function racePoints(place)
    return math.max(1, 4 - math.ceil(place / 3))
end

local function ready(c)
    local goal = terms(c.round)
    return c.finishes >= goal.requiredFinishes and c.podiums >= goal.requiredPodiums
        and c.points >= goal.requiredRoundPoints
end

-- 不在这里加载 Store，避免 Store 的存档校验 require Team 时出现循环依赖。
-- 校验纯读取，可直接接入 Store 的本地/云端 Load 与 persist 共用校验函数。
---@param p CareerTeamProfile
---@return boolean, string?
function Team.Validate(p)
    if type(p) ~= "table" then return false, "车队档案格式无效" end
    local c = p.teamContract
    if c == nil then
        -- v1旧档无新字段合法；但不能删除合同再重复领取已有车队奖金。
        if type(p.financialKeys) == "table" then
            for key, enabled in pairs(p.financialKeys) do
                if type(key) == "string" and key:sub(1, #PREFIX) == PREFIX and enabled then
                    return false, "车队奖金缺少对应合同"
                end
            end
        end
        return true
    end
    local career = p.career
    if type(c) ~= "table" or c.version ~= 1 or c.id ~= ID
        or not integer(c.round, 1, MAX_INTEGER - 1) or not integer(c.level, 1, 3)
        or not integer(c.season, 1) or not integer(c.signedAfterStart, 0)
        or not integer(c.finishes, 0) or not integer(c.podiums, 0) or not integer(c.points, 0)
        or type(c.seenRaceIds) ~= "table" or type(career) ~= "table"
        or not integer(career.starts, 0) or not integer(career.points, 9)
        or c.signedAfterStart > career.starts or type(p.flags) ~= "table" or p.flags.professional ~= true
        or type(p.financialKeys) ~= "table" or type(p.ledger) ~= "table" then
        return false, "车队合同字段或职业资格无效"
    end
    local goal = terms(c.round)
    if c.level ~= goal.level or c.season ~= goal.season then return false, "车队等级/赛季与履约轮次不一致" end
    ---@type table<number, table>
    local groups = {}
    for id, record in pairs(c.seenRaceIds) do
        local sequence = raceSequence(id)
        if not sequence or sequence <= c.signedAfterStart or sequence > career.starts
            or type(record) ~= "table" or not integer(record.round, 1, c.round)
            or not integer(record.series, 1, 6) or not integer(record.place, 1, 9)
            or type(record.finished) ~= "boolean" or p.financialKeys[id .. ":entry"] ~= true
            or p.financialKeys[id .. ":reward"] ~= true then
            return false, "车队赛事记录缺少有效报名/结算或字段无效"
        end
        local group = groups[record.round]
        if not group then
            group = {finishes = 0, podiums = 0, points = 0}
            groups[record.round] = group
        end
        if record.finished and record.series >= terms(record.round).minSeries then
            group.finishes = group.finishes + 1
            group.podiums = group.podiums + (record.place <= 3 and 1 or 0)
            group.points = group.points + racePoints(record.place)
        end
    end
    local current = groups[c.round] or {finishes = 0, podiums = 0, points = 0}
    if c.finishes ~= current.finishes or c.podiums ~= current.podiums or c.points ~= current.points then
        return false, "车队履约计数与赛事记录不一致"
    end
    -- 只遍历真实记录，绝不按不可信的 round 数值循环数万亿次。
    local paid = {}
    local paidCount = 0
    for _, entry in ipairs(p.ledger) do
        if type(entry) ~= "table" then return false, "车队流水格式无效" end
        local key = entry.id
        if type(key) == "string" and key:sub(1, #PREFIX) == PREFIX then
            local round = tonumber(key:sub(#PREFIX + 1))
            if not integer(round, 1, c.round - 1) or key ~= rewardKey(round) or paid[round]
                or p.financialKeys[key] ~= true or entry.deltaCents ~= terms(round).rewardCents
                or entry.kind ~= (round == 1 and "team_signing" or "team_sponsor") then
                return false, "车队奖金流水金额/轮次/去重信息无效"
            end
            paid[round] = true
            paidCount = paidCount + 1
        end
    end
    if paidCount ~= c.round - 1 then return false, "车队已领奖轮次缺少流水" end
    for key, enabled in pairs(p.financialKeys) do
        if type(key) == "string" and key:sub(1, #PREFIX) == PREFIX and enabled then
            local round = tonumber(key:sub(#PREFIX + 1))
            if not integer(round, 1, c.round - 1) or key ~= rewardKey(round) or not paid[round] then
                return false, "车队财务去重键没有对应奖金流水"
            end
        end
    end
    for round in pairs(paid) do
        local group = groups[round]
        local previousGoal = terms(round)
        if not group or group.finishes < 3 or group.podiums < 1 or group.points < previousGoal.requiredRoundPoints then
            return false, "车队历史奖金缺少完整履约赛事"
        end
    end
    return true
end

local function atDealer(p)
    local pos = p.position
    return type(pos) == "table" and (pos.space or "city") == "city" and pos.mounted == false
        and type(pos.x) == "number" and type(pos.z) == "number"
        and Config.DistanceTo("dealer", pos.x, pos.z) <= Config.INTERACTION_RADIUS
end

local function signReason(p)
    if not (p.flags and p.flags.professional) then return "先通过封闭场地训练，取得职业资格" end
    if not p.career or not integer(p.career.points, 9) then return "职业积分达到9分后才能签约" end
    if p.teamContract then return "已有正式合同，请先履约领取赞助奖" end
    if p.career.pending then return "先完成当前已报名训练或赛事" end
    if p.activeOrders and #p.activeOrders > 0 then return "先完成手头配送订单" end
    if not atDealer(p) then return "请停稳下车，到南城车行前台2米内签约" end
    return nil
end

-- 报价/状态只读：不新建合同、不改旧展示、不保存，也不偷偷加载 Store。
---@param p CareerTeamProfile
---@return table[]
function Team.Offers(p)
    local valid, detail = Team.Validate(p)
    local reason = not valid and detail or signReason(p)
    local goal = terms(1)
    return {{
        id = ID, name = NAME, sponsor = SPONSOR, available = valid and reason == nil,
        reason = reason or "达到门槛；在车行确认签约，履约前不发奖金",
        requiredPoints = 9, requiredFinishes = 3, requiredPodiums = 1,
        minSeries = goal.minSeries, requiredRoundPoints = goal.requiredRoundPoints,
        rewardCents = goal.rewardCents,
        description = "签约后新报名赛事才累计；至少3场有效完赛、1次领奖台，达标后领取一次固定奖金。",
    }}
end

---@param id string
---@return boolean, string
function Team.Sign(id)
    if id ~= ID then return false, "车队合同不存在" end
    return require("Career.Store").Transaction(function(p)
        local valid, detail = Team.Validate(p)
        if not valid then return false, detail end
        local reason = signReason(p)
        if reason then return false, reason end
        p.teamContract = {
            version = 1, id = ID, round = 1, level = 1, season = 1,
            signedAfterStart = p.career.starts, finishes = 0, podiums = 0, points = 0, seenRaceIds = {},
        }
        p.career.team = NAME
        print("[Career.Team] 显式签约；首轮履约后才发签约奖金")
        return true, "已签约南城极速：新报名赛事完赛3场且至少1次领奖台，回车行领取1500元签约奖金。"
    end)
end

-- 调用顺序：赛事 ApplyCash(:reward) 成功后，清空 career.pending 之前。
-- 返回 false 时外层赛事事务必须回滚；无合同/训练返回 true，不自动签约。
---@param p CareerTeamProfile
---@param race table
---@param place integer
---@param finished boolean
---@return boolean, string?
function Team.OnRace(p, race, place, finished)
    local valid, detail = Team.Validate(p)
    if not valid then return false, detail end
    if not p.teamContract or (type(race) == "table" and race.training) then return true end
    if type(race) ~= "table" or not integer(place, 1, 9) or type(finished) ~= "boolean"
        or not integer(race.series, 1, 6) then return false, "车队赛事名次/完赛状态无效" end
    local c = p.teamContract
    local sequence = raceSequence(race.id)
    local pending = p.career.pending
    if not sequence or sequence <= c.signedAfterStart or sequence ~= p.career.starts
        or type(pending) ~= "table" or pending.training or pending.id ~= race.id or pending.series ~= race.series
        or p.financialKeys[race.id .. ":entry"] ~= true or p.financialKeys[race.id .. ":reward"] ~= true then
        return false, "车队只能累计已支付报名并结算的当场赛事"
    end
    if c.seenRaceIds[race.id] then return false, "本场车队履约已经处理，不能重复累计" end
    c.seenRaceIds[race.id] = {round = c.round, series = race.series, place = place, finished = finished}
    if finished and race.series >= terms(c.round).minSeries then
        c.finishes = c.finishes + 1
        c.podiums = c.podiums + (place <= 3 and 1 or 0)
        c.points = c.points + racePoints(place)
    end
    -- 不在赛后自动给钱，也不把车队去重键混入 financialKeys 的财务流水。
    p.career.team = NAME
    return true, ready(c) and "本轮合同已达标，请回车行领取奖金并确认下一轮目标" or "已更新车队履约进度"
end

---@return boolean, string
function Team.Claim()
    return require("Career.Store").Transaction(function(p)
        local valid, detail = Team.Validate(p)
        if not valid then return false, detail end
        local c = p.teamContract
        if not c then return false, "尚未签约正式车队，请先到车行确认合同" end
        if not atDealer(p) then return false, "请到车行前台停稳下车，办理合同领奖与续约" end
        if p.career.pending then return false, "先完成当前已报名赛事，再办理领奖续约" end
        if not ready(c) then return false, "本轮未达标：需3场符合等级的完赛、至少1次领奖台并完成合同积分目标" end
        local goal = terms(c.round)
        local paid, message = require("Career.Store").ApplyCash(p, goal.rewardCents,
            c.round == 1 and "team_signing" or "team_sponsor", rewardKey(c.round))
        if not paid then return false, message end
        local nextRound = c.round + 1
        local nextGoal = terms(nextRound)
        c.round, c.level, c.season = nextRound, nextGoal.level, nextGoal.season
        c.finishes, c.podiums, c.points = 0, 0, 0
        p.career.team = NAME
        print(string.format("[Career.Team] 第%d轮奖金%d分已申请；落盘失败由Store整笔回滚", nextRound - 1, goal.rewardCents))
        return true, string.format("固定合同奖金%.2f元已入生涯钱包；晋升/续约为%d级，第%d赛季。下一轮：第%d站及以上赛事完赛3场、领奖台1次、合同积分%d。",
            goal.rewardCents / 100, c.level, c.season, nextGoal.minSeries, nextGoal.requiredRoundPoints)
    end)
end

---@param p CareerTeamProfile
---@return table
function Team.Status(p)
    local valid, detail = Team.Validate(p)
    if not valid then return {valid = false, signed = false, canClaim = false, text = detail} end
    local c = p.teamContract
    if not c then
        return {valid = true, signed = false, canClaim = false, name = "私人车手", level = 0, season = 0,
            round = 0, finishes = 0, podiums = 0, points = 0, rewardCents = 0,
            text = "尚未正式签约；职业积分9分后，到车行前台确认合同。旧档车队称号不代表签约。"}
    end
    local goal = terms(c.round)
    local completed = ready(c)
    return {valid = true, signed = true, id = c.id, name = NAME, sponsor = SPONSOR,
        level = c.level, season = c.season, round = c.round,
        finishes = c.finishes, podiums = c.podiums, points = c.points,
        requiredFinishes = 3, requiredPodiums = 1, minSeries = goal.minSeries,
        requiredRoundPoints = goal.requiredRoundPoints, rewardCents = goal.rewardCents,
        canClaim = completed, atDealer = atDealer(p),
        text = string.format("%s · %d级 · 第%d赛季/第%d轮\n第%d站及以上：完赛%d/3，领奖台%d/1，合同积分%d/%d。\n固定奖金%.2f元；%s",
            NAME, c.level, c.season, c.round, goal.minSeries, c.finishes, c.podiums, c.points,
            goal.requiredRoundPoints, goal.rewardCents / 100,
            completed and "已达标，回车行领取并续约" or "DNF/训练不累计；奖金不自动到账"),
    }
end

return Team
