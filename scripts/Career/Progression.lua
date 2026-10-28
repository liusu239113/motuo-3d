-- 长线成长配置与交易。所有买卖/排班/职业奖励仍经Store事务落盘。
-- 扩展字段向后兼容缺省值；不改变v1旧订单报价。
local Store=require("Career.Store")
local Progress={}
Progress.Equipment={
    {id="insulated_box",name="加固双单保温箱",price=28000,level=2,description="容量2份；保持独立箱体挂点"},
    {id="large_box",name="四单分隔配送箱",price=68000,level=3,description="容量4份；需先买双单箱"},
    {id="battery",name="长续航电池",price=120000,level=3,description="续航从35公里提升到65公里"},
    {id="raincoat",name="防风雨骑行服",price=16000,level=2,description="精力消耗降低15%"},
    {id="helmet",name="合格全盔与手套",price=45000,level=2,description="职业训练必需护具，可提前准备"},
}
Progress.Housing={
    {id="bridge",name="桥下落脚点",price=0,energy=70},
    {id="park",name="公园长椅",price=0,energy=75},
    {id="hostel",name="青年旅舍床位",price=3000,energy=90},
    {id="room",name="独立出租屋",price=6500,energy=100},
    {id="apartment",name="阳光小公寓",price=15000,energy=100},
}
Progress.Motorcycles={
    {id="sport",name="赤焰R1000 · 二手训练版",price=4600000},
    {id="cruiser",name="远行V1700",price=5800000},
    {id="rally",name="荒野Enduro",price=6600000},
    {id="sport_2",name="冰锋RR",price=8200000},
    {id="sport_3",name="银隼750",price=9800000},
    {id="cruiser_2",name="赤铜Classic",price=10800000},
    {id="cruiser_3",name="暗峰Muscle",price=12800000},
    {id="rally_2",name="雪脊Trail",price=13600000},
    {id="rally_3",name="沙隼Dakar",price=15800000},
}
Progress.Series={
    {id="rookie",name="新人杯",track="circuit",laps=2,fee=15000,reward=90000,required=0},
    {id="regional",name="区域公路联赛",track="lake",laps=2,fee=30000,reward=220000,required=3},
    {id="mountain",name="山地技术挑战",track="hairpin",laps=2,fee=50000,reward=380000,required=6},
    {id="coast",name="海岸职业巡回赛",track="coast",laps=3,fee=80000,reward=650000,required=9},
    {id="national",name="全国耐力系列赛",track="canyon",laps=3,fee=120000,reward=1000000,required=12},
    {id="final",name="年度冠军决战",track="forest",laps=3,fee=160000,reward=1600000,required=15},
}
local function extras(p)
    p.equipment=p.equipment or {}
    p.career=p.career or {starts=0,wins=0,points=0,season=1,pending=false,team="私人车手"}
    p.simulatedOrders=p.simulatedOrders or 0
    p.weeksWorked=p.weeksWorked or 0
end
function Progress.Level(p)
    local total=p.completedOrders+(p.simulatedOrders or 0)
    if total>=120 then return 4,"金牌骑手" elseif total>=40 then return 3,"熟练骑手" elseif total>=10 then return 2,"城市骑手" end
    return 1,"新手骑手"
end
function Progress.Capacity(p)
    local e=p.equipment or {}
    return e.large_box and 4 or e.insulated_box and 2 or 1
end
function Progress.Chapter(p)
    if p.flags.lifeWinner then return "终章 · 自己的人生，自己握把" end
    if p.flags.professional then return "第五章 · 从街头到发车格" end
    if p.flags.firstMotorcycle then return "第四章 · 人生第一辆摩托" end
    if p.cashCents>=5000000 then return "第三章 · 五万元的钥匙" end
    if p.flags.firstRest then return "第二章 · 在南城站稳脚跟" end
    return "第一章 · 兜里还剩50块"
end
function Progress.BuyEquipment(id)
    local item
    for _,e in ipairs(Progress.Equipment) do if e.id==id then item=e end end
    if not item then return false,"装备不存在" end
    return Store.Transaction(function(p)
        extras(p)
        if p.equipment[id] then return false,"已经拥有此装备" end
        if Progress.Level(p)<item.level then return false,"骑手等级不足" end
        if id=="large_box" and not p.equipment.insulated_box then return false,"先购买双单箱" end
        local ok,message=Store.ApplyCash(p,-item.price,"equipment","equipment:"..id)
        if not ok then return false,message end
        p.equipment[id]=true
        return true,"已购入"..item.name
    end)
end
function Progress.SetHousing(id)
    local item
    for _,h in ipairs(Progress.Housing) do if h.id==id then item=h end end
    if not item then return false,"住处不存在" end
    return Store.Transaction(function(p)
        if p.cashCents<item.price+1200 then return false,"至少留出今晚住宿和一顿饭的钱" end
        p.accommodation=id
        return true,"已选择"..item.name.."；每次过夜才扣费，不是永久买断"
    end)
end
-- 排班是一段明确推进的游戏时间，不按真实离线时间结算。
-- 必须亲送10单及休息过、无活动订单；7天包含6个工作日和1天休息。
-- 1680/2070/241320分毛收入，扣42000分餐食+基础整备及6晚房费。
function Progress.WorkWeek()
    return Store.Transaction(function(p)
        extras(p)
        if p.completedOrders<10 or not p.flags.firstRest then return false,"先亲自完成10单并休息一晚，熟悉送餐后解锁周排班" end
        if #p.activeOrders>0 then return false,"先完成所有手头订单" end
        if p.hunger<35 or p.energy<40 then return false,"先吃饭休息，身体不适合排班" end
        local level=Progress.Level(p)
        local gross=level>=4 and 241320 or level>=3 and 207000 or 168000
        local housing=0
        for _,h in ipairs(Progress.Housing) do if h.id==p.accommodation then housing=h.price*6 end end
        local costs=42000+housing
        if p.cashCents+gross<costs then return false,"该住处的排班支出超过现有现金与收入" end
        local key="week:"..(p.weeksWorked+1)
        local ok,message=Store.ApplyCash(p,gross,"scheduled_delivery",key..":income")
        if not ok then return false,message end
        local paid,detail=Store.ApplyCash(p,-costs,"scheduled_living",key..":cost")
        if not paid then return false,detail end
        p.weeksWorked=p.weeksWorked+1
        p.simulatedOrders=p.simulatedOrders+math.floor(gross/650)
        p.day=p.day+7; p.time=8; p.hunger=65; p.energy=85; p.battery=80
        p.flags.weekSchedule=true
        p.lastDaySummary={day=p.day-1,incomeCents=gross,expenseCents=costs,balanceCents=p.cashCents}
        return true,string.format("7天排班结束：配送收入%.2f元，生活整备与住宿%.2f元，净存%.2f元。没有与亲跑订单重复结算。",gross/100,costs/100,(gross-costs)/100)
    end)
end
function Progress.BuyMotorcycle(id)
    local item
    for _,v in ipairs(Progress.Motorcycles) do if v.id==id then item=v end end
    if not item then return false,"车辆不存在" end
    return Store.Transaction(function(p)
        extras(p)
        if p.ownedMotorcycles[id] then return false,"已经拥有此车" end
        if not p.flags.firstMotorcycle and (id~="sport" or p.cashCents<5000000) then return false,"先攒够5万元，购买二手训练版作为第一辆摩托" end
        local ok,message=Store.ApplyCash(p,-item.price,"motorcycle","motorcycle:"..id)
        if not ok then return false,message end
        p.ownedMotorcycles[id]=true; p.flags.firstMotorcycle=true; p.flags.fiftyThousand=true
        return true,"你终于有了自己的摩托："..item.name.."。电动车仍保留用于配送。"
    end)
end
function Progress.Train()
    return Store.Transaction(function(p)
        extras(p)
        if not p.flags.firstMotorcycle then return false,"先购买人生第一辆摩托" end
        if p.flags.professional then return false,"已完成入门训练" end
        local cost=p.equipment.helmet and 155000 or 200000
        if p.cashCents<cost+200000 then return false,"训练护具后还需保留2000元生活周转金" end
        local ok,message=Store.ApplyCash(p,-cost,"training","training:license")
        if not ok then return false,message end
        p.equipment.helmet=true; p.flags.professional=true; p.career.team="南城新人训练营"
        p.day=p.day+3; p.time=8; p.energy=90; p.hunger=70
        return true,"完成三天入门安全与封闭场地训练。职业赛事入口已开放；旧竞速仍是独立模式。"
    end)
end
function Progress.EnterSeries(index)
    local series=Progress.Series[index]
    if not series then return false,"赛事不存在" end
    return Store.Transaction(function(p)
        extras(p)
        if not p.flags.professional then return false,"完成摩托购入与入门训练后才能报名" end
        if #p.activeOrders>0 then return false,"先完成配送订单" end
        if p.career.pending then return false,"已有一场已报名赛事，回到赛事中心继续" end
        if p.career.points<series.required then return false,"职业积分不足，先参加已开放赛事" end
        local id="career-race:"..(p.career.starts+1)
        local ok,message=Store.ApplyCash(p,-series.fee,"race_entry",id..":entry")
        if not ok then return false,message end
        p.career.starts=p.career.starts+1
        p.career.pending={id=id,series=index,vehicle="sport",track=series.track,laps=series.laps}
        return true,"报名成功，进入"..series.name
    end)
end
function Progress.SettleRace(place,finished)
    if type(place)~="number" or place%1~=0 or place<1 or place>9 or type(finished)~="boolean" then
        return false,"赛事名次或完赛状态无效"
    end
    return Store.Transaction(function(p)
        extras(p)
        local race=p.career.pending
        if not race then return false,"没有生涯待结算赛事" end
        local series=Progress.Series[race.series]
        local reward=finished and math.floor(series.reward*math.max(.1,(10-place)/9)) or 0
        local ok,message=Store.ApplyCash(p,reward,"career_race",race.id..":reward")
        if not ok then return false,message end
        if finished then p.career.points=p.career.points+math.max(1,4-math.ceil(place/3)) end
        if finished and place==1 then p.career.wins=p.career.wins+1 end
        if p.career.points>=9 then p.career.team="南城极速车队" end
        if race.series==6 and finished and place==1 then p.flags.lifeWinner=true; p.career.team="年度冠军车队" end
        p.career.pending=false; p.day=p.day+1; p.time=8; p.energy=65
        return true,finished and string.format("生涯赛事结算：第%d名，奖金%.2f元。职业积分%d。",place,reward/100,p.career.points)
            or "本场未完赛，不发奖金、不加积分。报名已结清，可重新报名。"
    end)
end
return Progress
