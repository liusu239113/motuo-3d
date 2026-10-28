-- 单单配送状态机。无节点、无渲染、无 Update 订阅；入口活动时才调用 Update。
local Delivery = {}
local Store = require "Career.Store"
local Config = require "Career.Config"
local Progress = require "Career.Progression"

---@class CareerInteractionContext
---@field riding? boolean
---@field speed? number m/s

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end

---@param p CareerProfile
---@return CareerOrder?
local function offerFor(p)
    if #p.activeOrders >= Progress.Capacity(p) or p.time >= 23 then return nil end
    local template = Config.orderTemplates[1]
    if p.flags.tutorialCompleted then
        -- 单机确定性订单供给，并非真人抢单；不需要随机数/系统时钟。
        local index = 2 + ((p.nextOrderSequence - 2) % (#Config.orderTemplates - 1))
        template = Config.orderTemplates[index]
    end
    local distance = Config.RouteDistance(template.route)
    return {
        id = "career-v1-" .. p.nextOrderSequence, sequence = p.nextOrderSequence,
        templateId = template.id, title = template.title,
        pickupId = template.pickupId, dropoffId = template.dropoffId,
        route = copy(template.route), distanceMeters = distance,
        feeCents = template.tutorial and 500 or Config.FeeCents(distance), tutorial = template.tutorial,
        status = "offered", acceptedDay = p.day, acceptedTime = p.time,
        remainingHours = template.timeLimitHours, late = false,
    }
end

---@return CareerOrder?
function Delivery.GetOffer() return offerFor(Store.Get()) end

---@return CareerOrder?
function Delivery.GetActive() return Store.Get().activeOrders[1] end

---@param offerId? string
---@return boolean, string
function Delivery.Accept(offerId)
    return Store.Transaction(function(p)
        if #p.activeOrders >= Progress.Capacity(p) then return false, string.format("配送箱已满（%d份），请先完成一单",Progress.Capacity(p)) end
        local offer = offerFor(p)
        if not offer then return false, "当前没有可接订单，请休息后再上线" end
        if offerId and offerId ~= offer.id then return false, "订单已变更，请刷新后接单" end
        if p.settledOrders[offer.id] then return false, "该订单已结算" end
        offer.status = "accepted"
        p.activeOrders[#p.activeOrders + 1] = offer
        p.nextOrderSequence = p.nextOrderSequence + 1
        p.phase = "pickup"
        print("[Career.Delivery] accepting " .. offer.id .. " feeCents=" .. offer.feeCents)
        return true, "已接单，请到" .. Config.points[offer.pickupId].label .. "取餐"
    end)
end

-- 交互区设计（不是物理碰撞体）：
--   x/z 平面圆心=City可到达marker，半径2m；Y不参与，因为City负责门厅可通达。
--     outside -- [ circle r=2m : player ] -- outside
--   距离恰等于2m允许，>2m拒绝；缺失/NaN坐标拒绝；骑乘或速度>0.35m/s拒绝。
--   必须先 accepted 到店取餐，再 picked_up 到收餐点交付；远处重复按钮不结算。
---@param pointId string
---@param x number
---@param z number
---@param context? CareerInteractionContext
---@return boolean, string?
local function canInteract(pointId, x, z, context)
    if type(x) ~= "number" or type(z) ~= "number" or x ~= x or z ~= z
        or math.abs(x) == math.huge or math.abs(z) == math.huge then return false, "缺少有效角色位置" end
    local state = context or {}
    if state.riding == true then return false, "请停车下车后步行交互" end
    local speed = state.speed or 0
    if type(speed) ~= "number" or speed ~= speed or math.abs(speed) > Config.STOP_SPEED then
        return false, "请停稳后交互"
    end
    if Config.DistanceTo(pointId, x, z) > Config.INTERACTION_RADIUS then return false, "请靠近交互点（2米内）" end
    return true
end

---@param orderId string
---@param x number
---@param z number
---@param context? CareerInteractionContext
---@return boolean, string
function Delivery.Pickup(orderId, x, z, context)
    return Store.Transaction(function(p)
        local order, orderIndex
        for index,item in ipairs(p.activeOrders) do
            if item.id==orderId then order,orderIndex=item,index; break end
        end
        if not order then return false, "找不到此活动订单" end
        if order.status ~= "accepted" then return false, "已取餐，不能重复领取" end
        local allowed, message = canInteract(order.pickupId, x, z, context)
        if not allowed then return false, message end
        order.status = "picked_up"
        p.phase = "delivery"
        print("[Career.Delivery] picked up " .. order.id)
        return true, "已取餐，请送往" .. Config.points[order.dropoffId].label
    end)
end

---@param orderId string
---@param x number
---@param z number
---@param context? CareerInteractionContext
---@return boolean, string
function Delivery.Deliver(orderId, x, z, context)
    return Store.Transaction(function(p)
        if p.settledOrders[orderId] then return false, "此订单已结算，不能重复到账" end
        local order, orderIndex
        for index,item in ipairs(p.activeOrders) do
            if item.id==orderId then order,orderIndex=item,index; break end
        end
        if not order then return false, "找不到此活动订单" end
        if order.status ~= "picked_up" then return false, "请先到店取餐" end
        local allowed, message = canInteract(order.dropoffId, x, z, context)
        if not allowed then return false, message end
        -- 首日不做迟到扣款；迟到标记仍持久保存，不暗扣、不重载倒计时。
        local paid, paymentMessage = Store.ApplyCash(p, order.feeCents, "delivery", "delivery:" .. order.id)
        if not paid then return false, paymentMessage end
        p.settledOrders[order.id] = true
        p.completedOrders = p.completedOrders + 1
        if order.tutorial then p.flags.tutorialCompleted = true end
        p.flags.firstDelivery = true
        table.remove(p.activeOrders, orderIndex)
        p.phase = "working"
        print("[Career.Delivery] delivering " .. order.id .. " feeCents=" .. order.feeCents)
        return true, string.format("交付成功，配送费%.2f元已入账", order.feeCents / 100)
    end)
end

---@param dt number 现实活动秒；暂停/完整手机打开时入口不调用
---@param distanceMeters? number 本帧实际骑行米数，不能传总里程；用于电耗，不影响订单报价
---@return boolean, string?
function Delivery.Update(dt, distanceMeters) return Store.Advance(dt, distanceMeters) end

return Delivery
