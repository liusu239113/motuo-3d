-- 生活提示只读取生涯真值；不扣款、不改存档，也不另造一套体力。
local Config=require("Career.Config")
local Housing=require("Career.HousingData")
local Life={}
function Life.Part(hour)
    return hour<5 and "凌晨" or hour<9 and "早晨" or hour<11 and "上午" or hour<14 and "午间"
        or hour<17 and "下午" or hour<19 and "黄昏" or hour<23 and "夜间" or "深夜"
end
function Life.Advice(p)
    local home=Housing.Get(p.accommodation) or Housing.List[1]
    if p.time>=23 then
        return {title="深夜收工",detail=#p.activeOrders>0 and "停止派新单，先完成手头配送，再去休息。" or "今天该收工了，去落脚点休息至次日08:00。",point=home.point,action="导航休息",urgent=true}
    elseif p.energy<30 then
        return {title="疲劳已影响移动",detail="精力低于30，不能奔跑，移动速度降低。完成配送后去休息。",point=home.point,action="导航休息",urgent=true}
    elseif p.hunger<30 then
        return {title="空腹已影响移动",detail="饱腹低于30，不能奔跑，移动速度降低。去早餐店补一餐。",point="breakfast",action="导航吃饭",urgent=true}
    elseif p.hunger<=55 then
        return {title="该补充饮食了",detail="建议饱腹55以下补一餐，不必等到体力不足。",point="breakfast",action="导航吃饭",urgent=false}
    elseif p.energy<=45 or p.time>=21 then
        return {title="安排今晚休息",detail="完成配送后回落脚点。桥下和公园免费，住房按晚收费。",point=home.point,action="导航休息",urgent=false}
    end
    local untilMeal=math.max(0,(p.hunger-55)/Config.HUNGER_PER_HOUR)
    return {title="身体状态良好",detail=string.format("按当前消耗，约%d游戏分钟后建议吃饭；也可以提前用餐。",math.floor(untilMeal*60)),point="breakfast",action="生活详情",urgent=false}
end
function Life.Clock(hour) return string.format("%02d:%02d",math.floor(hour),math.floor(hour*60)%60) end
return Life
