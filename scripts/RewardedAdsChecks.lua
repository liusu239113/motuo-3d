-- 隔离执行真实RewardedAds源码；SDK、计时、UI均为本函数局部内存对象。
-- Run既不require正式RewardedAds，也不替换_G.sdk，不触达真实SDK/FakeAd/存档。
local Checks = {}

local function readSource()
    local file = assert(cache:GetFile("RewardedAds.lua"), "[RewardedAdsChecks] 缺少源码资源")
    local lines = {}
    while not file:IsEof() do lines[#lines + 1] = file:ReadLine() end
    file:Dispose()
    return table.concat(lines, "\n")
end

function Checks.Run()
    local source = readSource()
    local assertions, sdkCalls = 0, 0
    local function check(value, message)
        assert(value, "[RewardedAdsChecks] " .. message)
        assertions = assertions + 1
    end
    local function fixture(mode)
        local callbacks, events = {}, {}
        local alive = true
        local rewards, successes, failures, starts, stops = 0, 0, 0, 0, 0
        local environment = setmetatable({
            print = function() end,
            sdk = {ShowRewardVideoAd = function(_, callback)
                sdkCalls = sdkCalls + 1
                callbacks[#callbacks + 1] = callback
                if mode == "throw" then error("模拟SDK异常") end
                if mode == "syncfail" then callback({success = false, msg = "embed manual close"}); return false end
                if mode == "syncsuccess" then callback({success = true}); return true end
                if mode == "reject" then return false end
                if mode == "nilreturn" then return nil end
                return true
            end},
        }, {__index = _G})
        local ads = assert(load(source, "@RewardedAds.lua（内存回归）", "t", environment))()
        local options = {
            isValid = function() return alive end,
            setBusy = function(busy)
                if busy then starts = starts + 1 else stops = stops + 1 end
                check(alive, "失效UI不得恢复按钮")
                events[#events + 1] = busy and "busy" or "idle"
            end,
            onReward = function() rewards = rewards + 1; check(alive, "不得给旧赛局发奖"); events[#events + 1] = "reward" end,
            onSuccess = function() successes = successes + 1; check(alive, "不得通知旧赛局成功") end,
            onFailure = function(msg)
                failures = failures + 1
                check(alive and type(msg) == "string" and msg ~= "", "失败必须携带信息且不得操作失效UI")
            end,
        }
        return {
            ads = ads, options = options, callbacks = callbacks, events = events,
            invalidate = function() alive = false end,
            counts = function() return rewards, successes, failures, starts, stops end,
        }
    end
    local function counts(f, reward, success, failure, start, stop, name)
        local r, s, x, a, b = f.counts()
        check(r == reward and s == success and x == failure and a == start and b == stop, name)
    end

    -- 默认15秒会截断完整广告：15/30/60/179秒均不能自行判失败或发奖。
    for _, elapsed in ipairs({15, 30, 60, 179}) do
        local f = fixture()
        local accepted, generation = f.ads.Show(f.options)
        check(accepted and generation and f.ads.IsBusy(), "请求受理后持有唯一generation")
        f.ads.Update(elapsed)
        counts(f, 0, 0, 0, 1, 0, tostring(elapsed) .. "秒仍等待平台回调")
        f.callbacks[1]({success = true, msg = "embed success"})
        f.callbacks[1]({success = true})
        f.callbacks[1]({success = false})
        check(not f.ads.IsBusy(), "完成释放全局锁")
        counts(f, 1, 1, 0, 1, 1, "完整观看仅发奖一次并恢复按钮一次")
        check(f.events[1] == "busy" and f.events[2] == "idle" and f.events[3] == "reward", "奖励前按钮状态已恢复")
    end

    local f = fixture()
    f.ads.Show(f.options)
    local calls = sdkCalls
    check(f.ads.Show(f.options) == false and sdkCalls == calls, "快速连点不得再请求SDK")
    f.ads.Update(180)
    counts(f, 0, 0, 1, 1, 1, "180秒无回调只失败恢复UI")
    f.callbacks[1]({success = true})
    f.ads.Update(1000)
    counts(f, 0, 0, 1, 1, 1, "超时后迟到成功不能发奖")
    check(not f.ads.IsBusy(), "watchdog不能永久卡锁")

    for _, mode in ipairs({"reject", "syncfail", "throw", "nilreturn"}) do
        f = fixture(mode)
        f.ads.Show(f.options)
        counts(f, 0, 0, 1, 1, 1, mode .. "失败路径只恢复一次")
        check(not f.ads.IsBusy(), mode .. "请求拒绝或异常不能卡锁")
        f.callbacks[1]({success = true})
        counts(f, 0, 0, 1, 1, 1, mode .. "结束后迟到成功无效")
    end
    f = fixture("syncsuccess")
    check(f.ads.Show(f.options), "同步成功回调合法")
    counts(f, 1, 1, 0, 1, 1, "同步成功不重复完成")

    -- 严格boolean成功；不能从msg/extra、真值、过去的时长推断发奖。
    for _, result in ipairs({false, 2, "success", {}, {success = false, msg = "embed success"},
        {success = 1}, {success = "true"}, {success = false, extra = '{"finished":true}'}}) do
        f = fixture(); f.ads.Show(f.options)
        f.callbacks[1](result)
        counts(f, 0, 0, 1, 1, 1, "异常或非true结果不得发奖")
    end
    f = fixture(); f.ads.Show(f.options); f.callbacks[1](nil)
    counts(f, 0, 0, 1, 1, 1, "nil结果应恢复而非报索引错误")

    -- 无效timeout回退默认值；显式正数timeout仍支持精确内存故障注入。
    for _, timeout in ipairs({0, -1, math.huge, -math.huge, 0/0, "15", false}) do
        f = fixture(); f.options.timeout = timeout; f.ads.Show(f.options)
        f.ads.Update(179)
        check(f.ads.IsBusy(), "非法timeout不能使广告过早结束或永不超时")
        f.ads.Update(1)
        counts(f, 0, 0, 1, 1, 1, "非法timeout回退180秒")
    end
    f = fixture(); f.options.timeout = 2; f.ads.Show(f.options); f.ads.Update(2)
    counts(f, 0, 0, 1, 1, 1, "显式短timeout只产生失败")
    f = fixture(); f.ads.Show(f.options)
    for _, dt in ipairs({0, -1, math.huge, -math.huge, 0/0, false, "180"}) do f.ads.Update(dt) end
    f.ads.Update(nil)
    check(f.ads.IsBusy(), "非法dt不得污染计时或触发超时")
    f.ads.Cancel()

    -- 页面已经失效：不能调用旧UI任何回调，包括setBusy(false)。
    for _, path in ipairs({"callback", "timeout", "cancel"}) do
        f = fixture(); f.ads.Show(f.options); f.invalidate()
        if path == "callback" then f.callbacks[1]({success = true})
        elseif path == "timeout" then f.ads.Update(180)
        else check(f.ads.Cancel(), "显式取消有效请求") end
        f.callbacks[1]({success = true})
        check(not f.ads.IsBusy(), "页面失效释放锁")
        counts(f, 0, 0, 0, 1, 0, path .. "路径不操作失效UI或旧赛局")
    end
    f = fixture(); f.invalidate(); calls = sdkCalls
    check(not f.ads.Show(f.options) and calls == sdkCalls and not f.ads.IsBusy(), "请求前上下文失效不触SDK或UI")
    f = fixture(); f.options.isValid = function() error("模拟对象已释放") end; calls = sdkCalls
    check(not f.ads.Show(f.options) and sdkCalls == calls, "isValid异常按失效关闭")
    f = fixture(); f.options.isValid = nil
    check(f.ads.Show(f.options), "isValid是可选项，既有调用兼容")
    f.callbacks[1]({success = true}); counts(f, 1, 1, 0, 1, 1, "可选上下文成功")

    -- 取消后新请求：旧generation不能取消新请求，旧回调不能解锁新锁。
    f = fixture()
    local _, first = f.ads.Show(f.options)
    check(f.ads.CancelGeneration(first) and not f.ads.CancelGeneration(first), "按generation取消幂等")
    local _, second = f.ads.Show(f.options)
    check(second ~= first and f.ads.IsGenerationCurrent(second), "新请求使用新generation")
    check(not f.ads.CancelGeneration(first), "旧generation不得取消新请求")
    f.callbacks[1]({success = true})
    check(f.ads.IsBusy(), "取消请求的迟到成功不得释放新请求锁")
    counts(f, 0, 0, 0, 2, 0, "取消后迟到回调无任何旧UI副作用")
    f.callbacks[2]({success = true})
    counts(f, 1, 1, 0, 2, 1, "新请求独立发奖")

    -- options对象复用不能把旧广告的回调替换为新赛局回调。
    f = fixture(); f.ads.Show(f.options)
    local redirected = 0
    f.options.onReward = function() redirected = redirected + 1 end
    f.callbacks[1]({success = true})
    check(redirected == 0, "冻结options闭包避免对象复用重定向")
    counts(f, 1, 1, 0, 1, 1, "原有效回调继续结算一次")

    -- 回调重入/异常同样不能卡锁或在页面变化后继续发奖。
    f = fixture()
    local originalBusy = f.options.setBusy
    f.options.setBusy = function(busy) originalBusy(busy); if not busy then f.ads.Cancel() end end
    f.ads.Show(f.options); f.callbacks[1]({success = true})
    counts(f, 0, 0, 0, 1, 1, "恢复按钮时切页面后不得继续奖励")
    f = fixture(); f.options.onReward = function() error("模拟奖励异常") end
    f.ads.Show(f.options); f.callbacks[1]({success = true})
    check(not f.ads.IsBusy(), "奖励抛错也必须解除广告锁")
    counts(f, 0, 0, 0, 1, 1, "奖励异常不能伪造onSuccess")
    f = fixture(); f.options.onFailure = function() error("模拟失败提示异常") end
    f.ads.Show(f.options); f.callbacks[1]({success = false})
    check(not f.ads.IsBusy(), "失败提示抛错也必须解除广告锁")
    f = fixture(); f.options.setBusy = function() error("模拟UI销毁") end; calls = sdkCalls
    check(not f.ads.Show(f.options) and not f.ads.IsBusy() and sdkCalls == calls, "初始UI异常不发起无主请求")

    -- 超时onFailure中启动新请求，Update不得把当前帧dt重复算到新请求。
    f = fixture()
    f.options.onFailure = function() f.ads.Show({}) end
    f.ads.Show(f.options); f.ads.Update(180)
    check(f.ads.IsBusy() and #f.callbacks == 2, "超时回调重入新请求保持独立计时")
    f.ads.Update(179); check(f.ads.IsBusy(), "新请求不能继承旧帧180秒")
    f.callbacks[1]({success = true}); check(f.ads.IsBusy(), "旧超时回调不能清新锁")
    f.ads.Cancel()

    print(string.format("[RewardedAdsChecks] PASS %d项，%d次局部SDK桩调用，真实SDK未访问", assertions, sdkCalls))
    return {passed = true, assertions = assertions}
end

return Checks
