-- 当前订单的游戏内模拟电话；不调用真实号码，不远程交单，不改钱包或订单。
local Calls={}
---@type string[]
Calls.RiderLines={
    "您好，您的外卖已经送到门口了，方便下来取一下吗？",
    "您好，我是送餐骑手，餐给您带到了，麻烦到门口取一下。",
    "您好，外卖到了。我在入口旁边等您，您慢慢来，注意看路。",
    "您好，您的餐已经送到，袋子给您放稳了，请到门口接一下。",
}
---@type string[]
Calls.CustomerLines={
    "好的，我这就下来，辛苦了。",
    "收到了，麻烦等我一下，马上到。",
    "好的，我看到您了，谢谢。",
    "稍等，我拿一下钥匙就下来，谢谢您。",
}
---@param orders table[]
---@param id string
---@return table?
function Calls.Find(orders,id)
    for _,order in ipairs(orders) do if order.id==id then return order end end
    return nil
end
function Calls.Begin(order,actor,sequence)
    if not order then return nil,"订单已结束，不能拨打该顾客电话。" end
    if math.abs(actor.speed or 0)>.35 then return nil,"先靠边停稳再联系顾客。" end
    local index=(sequence-1)%#Calls.RiderLines+1
    local picked=order.status~="accepted"
    local point=require("Career.Config").points[order.dropoffId]
    local near=point and (actor.x-point.x)^2+(actor.z-point.z)^2<=25^2
    local rider=not picked and "您好，我是接了您订单的骑手，正在到店取餐，想跟您确认一下收餐入口。"
        or not near and "您好，您的外卖已经取到，正在配送途中，到了入口我会再联系您。"
        or Calls.RiderLines[index]
    ---@type string[]
    local customerLines=Calls.CustomerLines
    local customer=not picked and "好的，送到订单上的入口就行，到门口联系我。"
        or not near and "好的，路上注意安全，到门口再联系。" or customerLines[index]
    return {orderId=order.id,elapsed=0,phase="ringing",rider=rider,customer=customer,
        place=point and point.label or "订单收餐点",index=index},"正在拨打顾客电话。"
end
function Calls.Advance(call,dt)
    if not call then return false end
    local before=call.phase
    call.elapsed=call.elapsed+math.max(0,math.min(.25,dt))
    if call.elapsed>=2 then call.phase="connected" end
    return before~=call.phase
end
return Calls
