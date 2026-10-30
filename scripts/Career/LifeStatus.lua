-- 生活提示只读取生涯真值；不扣款、不改存档，也不另造一套体力。
local Config=require("Career.Config")
local Housing=require("Career.HousingData")
local Life={}
local function restAdvice(p,home,title,detail,urgent)
    local order=p.activeOrders[1]
    if order then
        return {title=title,detail="先完成手头配送，再去休息；带单不能过夜。",
            point=order.status=="accepted" and order.pickupId or order.dropoffId,
            action="继续配送",urgent=urgent}
    end
    return {title=title,detail=detail,point=home.point,action="导航休息",urgent=urgent}
end
function Life.Part(hour)
    return hour<5 and "凌晨" or hour<9 and "早晨" or hour<11 and "上午" or hour<14 and "午间"
        or hour<17 and "下午" or hour<19 and "黄昏" or hour<23 and "夜间" or "深夜"
end
function Life.Advice(p)
    local home=Housing.Get(p.accommodation) or Housing.List[1]
    if p.time>=23 then
        return restAdvice(p,home,"深夜收工","今天该收工了，去落脚点休息至次日08:00。",true)
    elseif p.energy<30 then
        return restAdvice(p,home,"疲劳已影响移动","精力低于30，不能奔跑，移动速度降低。去落脚点休息。",true)
    elseif p.hunger<30 then
        return {title="空腹已影响移动",detail="饱腹低于30，不能奔跑，移动速度降低。去早餐店补一餐。",point="breakfast",action="导航吃饭",urgent=true}
    elseif p.hunger<=55 then
        return {title="该补充饮食了",detail="建议饱腹55以下补一餐，不必等到体力不足。",point="breakfast",action="导航吃饭",urgent=false}
    elseif p.energy<=45 or p.time>=21 then
        return restAdvice(p,home,"安排今晚休息","桥下和公园免费，住房按晚收费；休息至次日08:00。",false)
    end
    local untilMeal=math.max(0,(p.hunger-55)/Config.HUNGER_PER_HOUR)
    return {title="身体状态良好",detail=string.format("按当前消耗，约%d游戏分钟后建议吃饭；也可以提前用餐。",math.floor(untilMeal*60)),point="breakfast",action="生活详情",urgent=false}
end
-- 计划是按当前消耗估算，不是预约或自动付款；装备节能与生产Advance保持一致。
function Life.Plan(p)
    local home=Housing.Get(p.accommodation) or Housing.List[1]
    local energyRate=Config.ENERGY_PER_HOUR*(p.equipment and p.equipment.raincoat and .85 or 1)
    local mealHours=math.max(0,(p.hunger-55)/Config.HUNGER_PER_HOUR)
    local restHours=math.max(0,(p.energy-45)/energyRate)
    local restAt=math.max(p.time,math.min(21,p.time+restHours))
    local electric=(p.position.activeVehicle or "borrowed_ebike")=="borrowed_ebike"
    local power=electric and p.battery or (p.motorcycleFuel or 100)
    local supply=power<=25 and (electric and 200 or 2000) or 0
    local reserve=Config.MEAL_CENTS+home.price+supply
    local income,expense,orders=0,0,0
    for _,entry in ipairs(p.ledger) do
        if entry.day==p.day and entry.kind~="opening" then
            if entry.deltaCents>0 then income=income+entry.deltaCents
            else expense=expense-entry.deltaCents end
            if entry.kind=="delivery" then orders=orders+1 end
        end
    end
    local range=power/(electric and (p.equipment and p.equipment.battery and 100/65000 or Config.BATTERY_PER_METER) or 100/180000)
    return {home=home,mealHours=mealHours,restHours=restHours,restAt=restAt,
        mealAt=math.min(24,p.time+mealHours),reserveCents=reserve,
        remainingCents=p.cashCents-reserve,shortfallCents=math.max(0,reserve-p.cashCents),
        supplyCents=supply,electric=electric,power=power,rangeMeters=range,
        incomeCents=income,expenseCents=expense,orders=orders,
        mealText=mealHours==0 and "现在建议用餐" or (Life.Clock(math.min(24,p.time+mealHours)).."左右补一餐"),
        restText=restAt<=p.time and "完成配送后安排休息" or (Life.Clock(restAt).."前后准备收工")}
end
---@class CareerLifeAlert
---@field key string
---@field title string
---@field detail string
---@field point string
---@field level number
---@return CareerLifeAlert[]
function Life.Alerts(p)
    local result={}
    local function add(key,title,detail,point,level)
        result[#result+1]={key=key,title=title,detail=detail,point=point,level=level}
    end
    local home=Housing.Get(p.accommodation) or Housing.List[1]
    if p.hunger<15 then add("hunger-critical","饥饿严重","移动明显变慢，先去早餐店补给。","breakfast",3)
    elseif p.hunger<30 then add("hunger-low","空腹影响移动","无法奔跑，建议先吃饭再接下一单。","breakfast",2)
    elseif p.hunger<=55 then add("hunger-meal","该吃饭了","预留12元和15游戏分钟，不必等到空腹。","breakfast",1) end
    if p.energy<15 then add("energy-critical","精力严重不足","完成当前配送后休息，避免继续接单。",home.point,3)
    elseif p.energy<30 then add("energy-low","疲劳影响移动","无法奔跑，完成当前配送后休息。",home.point,2)
    elseif p.energy<=45 then add("energy-rest","安排休息","今晚住处已列在生活计划里。",home.point,1) end
    local plan=Life.Plan(p)
    if plan.power<=0 then add("power-empty",plan.electric and "车辆没电了" or "燃油耗尽",plan.electric and "去充电点补给，步行仍可移动。" or "去车行补给燃油。",plan.electric and "charge" or "dealer",3)
    elseif plan.power<=10 then add("power-critical",plan.electric and "电量告急" or "燃油告急","不要再安排远程行程，优先补给。",plan.electric and "charge" or "dealer",2)
    elseif plan.power<=25 then add("power-low","车辆需要补给","生活计划已预留本次补给开销。",plan.electric and "charge" or "dealer",1) end
    if p.time>=23 then add("late","深夜停止派单",#p.activeOrders>0 and "完成手头配送后收工，不能带单过夜。" or "到落脚点休息至次日08:00。",home.point,2)
    elseif p.time>=21 then add("evening","该安排今晚住处了","生活计划可查看住宿和下一餐预算。",home.point,1) end
    table.sort(result,function(a,b) if a.level==b.level then return a.key<b.key end return a.level>b.level end)
    return result
end
-- 同一天同一级提醒只出现一次；只标记实际展示的提醒，其余隔一段活动时间再展示。
-- 更严重的状态可越过冷却，手机/暂停不推进游戏时间，也就不会消耗提醒间隔。
function Life.PollAlerts(monitor,p)
    if monitor.day~=p.day then
        monitor.day=p.day;monitor.seen={};monitor.nextAt=0;monitor.lastLevel=0
    end
    local now=(p.day-1)*24+p.time
    for _,alert in ipairs(Life.Alerts(p)) do
        if not monitor.seen[alert.key] then
            if now<(monitor.nextAt or 0) and alert.level<=(monitor.lastLevel or 0) then return nil end
            monitor.seen[alert.key]=true
            monitor.nextAt=now+.04
            monitor.lastLevel=alert.level
            return alert
        end
    end
end
function Life.Clock(hour) return string.format("%02d:%02d",math.floor(hour),math.floor(hour*60)%60) end
return Life
