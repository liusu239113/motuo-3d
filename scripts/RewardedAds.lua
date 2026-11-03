-- 激励视频广告统一入口：一次性完成状态、请求防抖、保守超时与页面生命周期隔离。
-- 只有回调 result.success == true 才发奖；返回值 false、提前关闭、超时一律按失败处理。
---@class SDK
---@field ShowRewardVideoAd fun(self:SDK, callback:fun(result:table)):boolean
local RewardedAds = {}

-- 激励视频时长由宿主决定，不能用“通常时长”推断成功。180秒只用于无回调时
-- 保守地结束本次请求为失败，避免默认15秒截断仍在播放的完整广告。
local DEFAULT_TIMEOUT = 180.0

---@class RewardedAdTicket
---@field elapsed number
---@field timeout number
---@field finish fun(result:table)
---@field done boolean
---@field generation integer
---@field isValid fun():boolean

---@type RewardedAdTicket?
local activeTicket = nil
local generationCounter = 0

local function finitePositive(value)
    return type(value) == "number" and value == value and value ~= math.huge
        and value ~= -math.huge and value > 0
end

local function getTimeout(options)
    if options and finitePositive(options.timeout) then return options.timeout end
    return DEFAULT_TIMEOUT
end

-- 回调属于外部页面；回调异常不能让广告锁永久保持，也不能改变一次性结算状态。
local function callSafely(callback, ...)
    if not callback then return true end
    local ok, errorMessage = pcall(callback, ...)
    if not ok then print("[RewardedAds] 回调异常: " .. tostring(errorMessage)) end
    return ok
end

local function contextIsValid(options)
    if not options.isValid then return true end
    local ok, valid = pcall(options.isValid)
    if not ok then
        print("[RewardedAds] 上下文校验异常，丢弃迟到回调")
        return false
    end
    return valid == true
end

---@param dt number
function RewardedAds.Update(dt)
    -- 只取帧开始时的请求快照；失败回调即使重入Show，新请求也不能被本帧继续计时。
    local ticket = activeTicket
    if not ticket then return end
    if not ticket.isValid() then
        RewardedAds.CancelGeneration(ticket.generation)
        return
    end
    if finitePositive(dt) then ticket.elapsed = ticket.elapsed + dt end
    if ticket.elapsed >= ticket.timeout then
        ticket.finish({ success = false, msg = "广告响应超时，请稍后重试" })
    end
end

function RewardedAds.IsBusy() return activeTicket ~= nil end

-- 当前请求的单调代号。主方也可以把它捕获进 isValid，而不依赖赛局对象是否仍存在。
---@return integer
function RewardedAds.GetGeneration() return generationCounter end

---@param value integer
---@return boolean
function RewardedAds.IsGenerationCurrent(value)
    return generationCounter == value
end

-- 取消只结束内部请求，不调用旧页面的 setBusy/onFailure/onSuccess/onReward。
-- 页面销毁或赛局重开时调用此接口，迟到SDK回调会被同一个 done 状态丢弃。
---@return boolean
function RewardedAds.Cancel()
    local ticket = activeTicket
    generationCounter = generationCounter + 1
    if not ticket then return false end
    ticket.done = true
    activeTicket = nil
    return true
end

---@param value integer
---@return boolean
function RewardedAds.CancelGeneration(value)
    local ticket = activeTicket
    if not ticket or ticket.generation ~= value then return false end
    return RewardedAds.Cancel()
end

---展示一次激励视频。失败不会发奖，只会恢复仍有效页面的按钮并回调 onFailure。
---@param options table { onReward:fun(), onSuccess?:fun(), onFailure?:fun(msg:string), setBusy?:fun(boolean), timeout?:number, isValid?:fun():boolean }
---@return boolean accepted
---@return integer? generation
function RewardedAds.Show(options)
    if type(options) ~= "table" then return false, nil end
    if activeTicket then return false, nil end
    -- 固定本次闭包，调用方之后修改 options 表不能把旧请求导向新赛局。
    local callbacks = {
        isValid = options.isValid, setBusy = options.setBusy,
        onReward = options.onReward, onSuccess = options.onSuccess, onFailure = options.onFailure,
    }
    if not contextIsValid(callbacks) then return false, nil end
    generationCounter = generationCounter + 1
    local thisGeneration = generationCounter

    ---@type RewardedAdTicket
    local ticket = {
        elapsed = 0,
        timeout = getTimeout(options),
        done = false,
        generation = thisGeneration,
        finish = function() end,
        isValid = function() return contextIsValid(callbacks) end,
    }

    local function stillValid()
        return generationCounter == thisGeneration and ticket.isValid()
    end

    local function finish(result)
        if ticket.done then return end
        ticket.done = true
        if activeTicket == ticket then activeTicket = nil end

        -- 生命周期失效时连按钮恢复也不能做；每个外部回调均可能重入或切换页面。
        if not stillValid() then return end
        callSafely(callbacks.setBusy, false)
        if not stillValid() then return end

        if type(result) == "table" and result.success == true then
            local rewarded = callSafely(callbacks.onReward)
            if rewarded and stillValid() then callSafely(callbacks.onSuccess) end
            return
        end
        local msg = type(result) == "table" and result.msg or "广告暂不可用，请稍后重试"
        print("[RewardedAds] 未完成: " .. tostring(msg))
        callSafely(callbacks.onFailure, tostring(msg))
    end

    ticket.finish = finish
    activeTicket = ticket
    local busySet = callSafely(callbacks.setBusy, true)
    if ticket.done then return false, thisGeneration end
    if not busySet or not stillValid() then
        RewardedAds.CancelGeneration(thisGeneration)
        return false, thisGeneration
    end

    local callbackFired = false
    local ok, accepted = pcall(function()
        return sdk:ShowRewardVideoAd(function(result)
            callbackFired = true
            finish(result)
        end)
    end)

    if not ok then
        -- SDK异常同样视为失败，不能因为报错把按钮永久锁死。
        print("[RewardedAds] 调用异常: " .. tostring(accepted))
        finish({ success = false, msg = "广告服务异常，请稍后重试" })
        return false, thisGeneration
    end

    -- SDK文档约定返回boolean；任何非true且未同步回调的结果都按未受理处理。
    if accepted ~= true and not callbackFired then
        finish({ success = false, msg = "广告暂不可用，请稍后重试" })
        return false, thisGeneration
    end
    return true, thisGeneration
end

return RewardedAds
