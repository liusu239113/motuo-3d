-- 激励视频广告统一入口：一次性完成状态、请求防抖、超时兜底与按钮状态恢复。
-- 只有回调 result.success == true 才发奖；返回值 false、提前关闭、超时一律按失败处理。
local RewardedAds = {}

local DEFAULT_TIMEOUT = 15.0

-- 每次展示一条唯一记录，由 Update 驱动超时；不额外订阅 Update，避免与主循环争用事件。
---@class RewardedAdTicket
---@field elapsed number
---@field timeout number
---@field finish fun(result:table)

---@type RewardedAdTicket[]
local tickets = {}
local inFlight = false

local function removeTicket(ticket)
    for index = #tickets, 1, -1 do
        if tickets[index] == ticket then table.remove(tickets, index) end
    end
end

---@param dt number
function RewardedAds.Update(dt)
    if #tickets == 0 then return end
    local step = math.max(0, dt or 0)
    for index = #tickets, 1, -1 do
        local ticket = tickets[index]
        ticket.elapsed = ticket.elapsed + step
        if ticket.elapsed >= ticket.timeout then
            table.remove(tickets, index)
            ticket.finish({ success = false, msg = "广告响应超时，请稍后重试" })
        end
    end
end

function RewardedAds.IsBusy() return inFlight end

---展示一次激励视频。失败不会发奖，只会恢复按钮并回调 onFailure。
---@param options table { onReward:fun(), onSuccess?:fun(), onFailure?:fun(msg:string), setBusy?:fun(boolean), timeout?:number }
function RewardedAds.Show(options)
    options = options or {}
    if inFlight then return false end
    inFlight = true

    local done = false
    local callbackFired = false
    ---@type RewardedAdTicket
    local ticket = { elapsed = 0, timeout = options.timeout or DEFAULT_TIMEOUT, finish = function() end }

    local function finish(result)
        if done then return end
        done = true
        inFlight = false
        removeTicket(ticket)
        if options.setBusy then options.setBusy(false) end

        if result and result.success == true then
            if options.onReward then options.onReward() end
            if options.onSuccess then options.onSuccess() end
            return
        end
        local msg = result and result.msg or "广告暂不可用，请稍后重试"
        print("[RewardedAds] 未完成: " .. tostring(msg))
        if options.onFailure then options.onFailure(msg) end
    end

    ticket.finish = finish
    tickets[#tickets + 1] = ticket
    if options.setBusy then options.setBusy(true) end

    local ok, accepted = pcall(function()
        return sdk:ShowRewardVideoAd(function(result)
            callbackFired = true
            finish(result)
        end)
    end)

    if not ok then
        -- SDK 异常同样视为失败，不能因为报错把按钮永久锁死。
        print("[RewardedAds] 调用异常: " .. tostring(accepted))
        finish({ success = false, msg = "广告服务异常，请稍后重试" })
        return false
    end

    if accepted == false and not callbackFired then
        finish({ success = false, msg = "广告暂不可用，请稍后重试" })
        return false
    end
    return true
end

return RewardedAds
