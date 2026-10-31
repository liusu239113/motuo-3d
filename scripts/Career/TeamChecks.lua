-- 显式调用 require("Career.TeamChecks").Run()；所有读写限定在内存适配器。
-- 无论断言/写盘失败，finally 都恢复原Store状态，不创建、不读取、不覆盖玩家真实存档。
local Store = require("Career.Store")
local Team = require("Career.Team")
local Progress = require("Career.Progression")
local Config = require("Career.Config")
local Checks = {}

-- 仅隔离验收夹具设置资格/现金，生产合同没有赠款或强制升分入口。
local function prepare(points, oldTeam)
    assert(Store.NewCareer())
    assert(Store.Transaction(function(p)
        local paid, message = Store.ApplyCash(p, 20000000, "test_fixture", "test:team-capital")
        if not paid then return false, message end
        p.ownedMotorcycles.sport = true
        p.flags.firstMotorcycle, p.flags.professional = true, true
        p.career = {starts = 0, wins = 0, points = points, season = 1, pending = false,
            team = oldTeam or "私人车手"}
        p.position.x, p.position.z = Config.points.dealer.x, Config.points.dealer.z
        p.position.mounted = false
        return true
    end))
end

-- 模拟主线程唯一的赛事结算事务：只调用一次OnRace，不依赖主线程是否已给Progress接线。
-- 报名仍走真实Progress入口；流水、职业积分、合同进度、pending同一事务提交或回滚。
local function settle(place, finished)
    return Store.Transaction(function(p)
        local race = p.career.pending
        if not race or race.training then return false, "没有待结算正式赛事" end
        local series = Progress.Series[race.series]
        local cents = finished and math.floor(series.reward * math.max(.1, (10 - place) / 9)) or 0
        local paid, message = Store.ApplyCash(p, cents, "career_race", race.id .. ":reward")
        if not paid then return false, message end
        if finished then p.career.points = p.career.points + math.max(1, 4 - math.ceil(place / 3)) end
        if finished and place == 1 then p.career.wins = p.career.wins + 1 end
        local updated, detail = Team.OnRace(p, race, place, finished)
        if not updated then return false, detail end
        p.career.pending = false
        return true
    end)
end

local function runRace(series, place, finished)
    assert(Progress.EnterSeries(series))
    local race = Store.Get().career.pending
    assert(settle(place, finished))
    assert(Team.Validate(Store.Get()))
    return race
end

local function sameContract(a, b)
    assert(a.teamContract.round == b.teamContract.round and a.teamContract.level == b.teamContract.level
        and a.teamContract.season == b.teamContract.season and a.teamContract.finishes == b.teamContract.finishes
        and a.teamContract.podiums == b.teamContract.podiums and a.teamContract.points == b.teamContract.points,
        "事务失败不应改变合同进度")
    assert(a.cashCents == b.cashCents and #a.ledger == #b.ledger and a.revision == b.revision,
        "事务失败不应改变钱包/流水/版本")
end

---@return boolean
function Checks.Run()
    local files = {}
    local failWrite = false
    local restore = Store.UseTestStorage({
        read = function(path) return files[path], nil, files[path] == nil end,
        write = function(path, text)
            if failWrite then return false, "模拟磁盘失败" end
            files[path] = text
            return true
        end,
    })
    local passed, failure = pcall(function()
        assert(Store.NewCareer())
        local legacy = Store.Get()
        assert(legacy.teamContract == nil and Team.Validate(legacy))
        assert(not Team.Status(legacy).signed and not Team.Offers(legacy)[1].available)
        assert(not Team.Sign("nancheng_speed"), "新手无资格不可签约")
        assert(not Team.Sign("unknown") and not Team.Claim())
        assert(Store.Load() and Store.Get().teamContract == nil)

        prepare(8, "年度冠军车队")
        local original = Store.Get()
        local offered = Team.Offers(original)[1]
        assert(offered.id == "nancheng_speed" and not offered.available and not Team.Status(original).signed)
        assert(original.teamContract == nil and original.career.team == "年度冠军车队",
            "旧称号不能自动生成合同，也不能被只读查询覆盖")
        assert(not Team.Sign(offered.id), "必须达到9积分")
        assert(Store.Transaction(function(p) p.career.points = 9; p.flags.professional = false; return true end))
        assert(not Team.Sign(offered.id), "积分不能替代真实训练资格")
        assert(Store.Transaction(function(p) p.flags.professional = true; p.position.x = 0; return true end))
        assert(not Team.Sign(offered.id), "不能远程签约")
        assert(Store.Transaction(function(p) p.position.x = Config.points.dealer.x; p.position.mounted = true; return true end))
        assert(not Team.Sign(offered.id), "必须下车签约")
        assert(Store.Transaction(function(p) p.position.mounted = false; return true end))
        assert(Progress.EnterSeries(1))
        assert(not Team.Sign(offered.id), "已报名赛事不能中途签约回填")
        assert(settle(1, true))
        assert(Store.Get().teamContract == nil, "未签约完赛不自动授予合同")

        original = Store.Get()
        failWrite = true
        assert(not Team.Sign(offered.id))
        failWrite = false
        assert(Store.Get().teamContract == nil and Store.Get().cashCents == original.cashCents)
        assert(Team.Offers(Store.Get())[1].available)
        assert(Team.Sign(offered.id))
        local signed = Store.Get()
        assert(signed.cashCents == original.cashCents and #signed.ledger == #original.ledger,
            "显式签字只建立合同，不赠送现金")
        assert(signed.teamContract.signedAfterStart == 1 and signed.teamContract.round == 1)
        assert(not Team.Sign(offered.id) and not Team.Claim())
        assert(Store.Save() and Store.Load() and Team.Status(Store.Get()).signed)

        -- 训练即使上报成功也不计完赛，不消耗正式赛事ID。
        assert(Store.Transaction(function(p)
            return Team.OnRace(p, {id = "training:license", training = true}, 1, true)
        end))
        assert(Team.Status(Store.Get()).finishes == 0)

        local dnf = runRace(1, 1, false)
        local c = Store.Get().teamContract
        assert(c.finishes == 0 and c.podiums == 0 and c.points == 0 and c.seenRaceIds[dnf.id])
        assert(not Team.Claim(), "DNF不能凑履约场次，也不能领奖")
        assert(Store.Load() and Store.Get().teamContract.seenRaceIds[dnf.id])
        local beforeDuplicate = Store.Get()
        assert(not Store.Transaction(function(p) return Team.OnRace(p, dnf, 1, true) end),
            "DNF的同一赛事ID不能改成完赛来刷进度")
        sameContract(beforeDuplicate, Store.Get())

        for _ = 1, 3 do runRace(1, 4, true) end
        assert(Team.Status(Store.Get()).finishes == 3 and Team.Status(Store.Get()).podiums == 0)
        assert(not Team.Status(Store.Get()).canClaim and not Team.Claim(), "3完赛但无领奖台不可领奖")

        assert(Progress.EnterSeries(1))
        local race = Store.Get().career.pending
        local beforeRace = Store.Get()
        local oldText = files[Config.SAVE_PATH]
        failWrite = true
        assert(not settle(1, true))
        failWrite = false
        local afterFailure = Store.Get()
        sameContract(beforeRace, afterFailure)
        assert(afterFailure.career.pending.id == race.id and not afterFailure.financialKeys[race.id .. ":reward"]
            and not afterFailure.teamContract.seenRaceIds[race.id] and files[Config.SAVE_PATH] == oldText,
            "赛后存盘失败必须连奖励/合同去重/pending整笔回滚")
        assert(settle(1, true))
        assert(Team.Status(Store.Get()).canClaim)
        local beforeReplay = Store.Get()
        assert(not Store.Transaction(function(p) return Team.OnRace(p, race, 1, true) end))
        assert(not Store.Transaction(function(p) return Team.OnRace(p, race, 0, true) end))
        assert(not Store.Transaction(function(p) return Team.OnRace(p, race, 1, 1) end))
        sameContract(beforeReplay, Store.Get())
        assert(Store.Load() and Team.Status(Store.Get()).canClaim)

        local beforeClaim = Store.Get()
        failWrite = true
        assert(not Team.Claim())
        failWrite = false
        sameContract(beforeClaim, Store.Get())
        assert(Store.Load() and Team.Status(Store.Get()).canClaim,
            "领奖存盘失败后读档仍应保留待领奖状态")
        assert(Team.Claim())
        local claimed = Store.Get()
        assert(claimed.cashCents == beforeClaim.cashCents + 150000 and claimed.cashCents % 1 == 0)
        assert(claimed.teamContract.round == 2 and claimed.teamContract.level == 2)
        assert(claimed.teamContract.finishes == 0 and claimed.teamContract.podiums == 0 and claimed.teamContract.points == 0)
        assert(claimed.financialKeys["team-contract:nancheng_speed:round:1"] == true and Team.Validate(claimed))
        assert(not Team.Claim() and not Team.Sign(offered.id), "不能反复领奖/重签刷首轮奖金")
        assert(Store.Load() and not Team.Claim())
        assert(not Store.Transaction(function(p) return Team.OnRace(p, race, 1, true) end),
            "旧轮次赛事ID不能重复用于下一轮")
        assert(Store.Get().teamContract.finishes == 0)

        -- 等级提高后刷新人杯不算合同，但正常职业赛事仍可以结算。
        runRace(1, 1, true)
        assert(Team.Status(Store.Get()).finishes == 0 and not Team.Claim())
        for _ = 1, 3 do runRace(2, 1, true) end
        local amount = Store.Get().cashCents
        assert(Team.Claim() and Store.Get().cashCents == amount + 240000)
        assert(Team.Status(Store.Get()).minSeries == 3 and Team.Status(Store.Get()).requiredRoundPoints == 7)
        for _ = 1, 3 do runRace(3, 1, true) end
        assert(Team.Claim())
        assert(Team.Status(Store.Get()).level == 3 and Team.Status(Store.Get()).season == 2)
        assert(Team.Status(Store.Get()).minSeries == 4 and Team.Status(Store.Get()).requiredRoundPoints == 8)
        for _ = 1, 3 do runRace(4, 1, true) end
        assert(Team.Claim())
        for _ = 1, 3 do runRace(4, 1, true) end
        assert(Team.Claim())
        local capped = Team.Status(Store.Get())
        assert(capped.level == 3 and capped.minSeries == 4 and capped.requiredRoundPoints == 8)
        for _ = 1, 3 do runRace(4, 1, true) end
        assert(Team.Claim())
        capped = Team.Status(Store.Get())
        assert(capped.season == 3 and capped.minSeries == 4 and capped.requiredRoundPoints == 9
            and capped.rewardCents == 360000 and capped.requiredFinishes == 3 and capped.requiredPodiums == 1,
            "后续续约积分/赛事门槛递增，但满级目标与奖金合理封顶")
        assert(Store.Save() and Store.Load() and Team.Validate(Store.Get()))

        -- 整数分/流水/历史履约校验：只破坏Get返回的深拷贝，不写任何存档。
        local broken = Store.Get()
        broken.teamContract.finishes = .5
        assert(not Team.Validate(broken))
        broken = Store.Get(); broken.teamContract.finishes = 1
        assert(not Team.Validate(broken), "计数必须可由有效赛事重算")
        broken = Store.Get(); broken.teamContract.level = 1
        assert(not Team.Validate(broken))
        broken = Store.Get(); broken.teamContract.round = 999999999999
        assert(not Team.Validate(broken), "畸形超大轮次必须快速拒绝")
        broken = Store.Get()
        for _, entry in ipairs(broken.ledger) do
            if entry.kind == "team_signing" then entry.deltaCents = entry.deltaCents + .5 end
        end
        assert(not Team.Validate(broken), "奖金不得使用小数分或篡改固定金额")
        broken = Store.Get(); broken.financialKeys["team-contract:nancheng_speed:round:1"] = false
        assert(not Team.Validate(broken))
        broken = Store.Get(); broken.teamContract = nil
        assert(not Team.Validate(broken), "删合同不能重复领取有流水的签约奖金")
        broken = Store.Get()
        local id = next(broken.teamContract.seenRaceIds)
        broken.financialKeys[id .. ":reward"] = nil
        assert(not Team.Validate(broken), "合同赛事必须有对应财务结算记录")
        assert(Team.Validate(Store.Get()), "纯读异常数据校验不得污染存档")
        print("[车队合同验收通过] 旧档无自动签约/9积分与训练/车行显式签约/签字零现金/3完赛+领奖台/DNF与赛事ID去重/赛后与领奖失败回滚/整数分固定奖金/晋升续约封顶/存读档及历史流水一致性")
    end)
    restore()
    if not passed then error(failure, 0) end
    return true
end

return Checks
