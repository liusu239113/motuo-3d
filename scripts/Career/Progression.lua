-- 长线成长配置与交易。所有买卖/排班/职业奖励仍经Store事务落盘。
-- 扩展字段向后兼容缺省值；不改变v1旧订单报价。
local Store=require("Career.Store")
local Property=require("Career.Property")
local Config=require("Career.Config")
local Progress={}
Progress.Equipment={
    {id="insulated_box",name="加固双单保温箱",price=28000,level=2,description="容量2份；保持独立箱体挂点"},
    {id="large_box",name="四单分隔配送箱",price=68000,level=3,description="容量4份；需先买双单箱"},
    {id="battery",name="长续航电池",price=120000,level=3,description="续航从35公里提升到65公里"},
    {id="raincoat",name="防风雨骑行服",price=16000,level=2,description="精力消耗降低15%"},
    {id="helmet",name="合格全盔与手套",price=45000,level=2,description="职业训练必需护具，可提前准备"},
}
Progress.Housing=require("Career.HousingData").List
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
        if p.position.space and p.position.space~="city" then return false,"请先离开当前住处再换房" end
        local nightly=Property.NightlyCost(p,id)
        if nightly>0 and p.cashCents<nightly+1200 then return false,"至少留出今晚住宿和一顿饭的钱" end
        p.accommodation=id
        if Property.Owns(p,id) then return true,"已选择自有住房"..item.name.."；永久产权，每晚免房费" end
        return true,"已选择"..item.name.."；每次过夜才扣费，不是永久买断"
    end)
end
-- 买断只取得产权，不自动搬家/瞬移；保留当前空间和今晚选择，允许先买后入住。
---@param id string
---@return boolean, string
function Progress.BuyHome(id)
    return Store.Transaction(function(p)
        local allowed,reason=Property.CanBuy(p,id)
        if not allowed then return false,reason end
        local home=assert(require("Career.HousingData").Get(id))
        local price=assert(home.buyPriceCents)
        local ok,message=Store.ApplyCash(p,-price,"home_purchase",Property.PurchaseKey(id))
        if not ok then return false,message end
        Property.Normalize(p)
        p.ownedHomes[id]=true
        return true,string.format("已买断%s，支出%.2f元，永久产权已本地保存；此处每晚免房费。（游戏固定价，非现实房价）",home.name,price/100)
    end)
end
-- 纯查询：必须传入档案快照；不会Store.Get、补字段、写档或提前锁定报价。
-- UI确认后WorkWeek在事务内重新查询，不可拿旧预览作为付款授权。
---@param p CareerProfile
---@return table
function Progress.WorkWeekPreview(p)
    local rule=Config.WORK_WEEK
    local manual=math.max(0,p.completedOrders-(p.lastScheduleManualOrders or 0))
    local seconds=math.max(0,(p.activeSeconds or 0)-(p.lastScheduleSeconds or 0))
    local level=Progress.Level(p)
    local orders=level>=4 and rule.goldOrders or level>=3 and rule.skilledOrders or rule.cityOrders
    local average=level>=4 and rule.goldAverageCents or level>=3 and rule.skilledAverageCents or rule.cityAverageCents
    local gross=orders*average
    local housing=Property.NightlyCost(p,p.accommodation)*rule.days
    local costs=rule.livingCents+rule.perOrderCostCents*orders+housing
    local reason=""
    if p.day<rule.unlockDay or p.completedOrders<rule.requiredManualOrders or not p.flags.firstRest then
        reason="第10天起，亲送10单并休息过后开放周排班"
    elseif manual<rule.requiredManualOrders or seconds<rule.requiredActiveSeconds then
        reason=string.format("下次排班资格：新亲送%d/10单，活动%.0f/15分钟；亲送只作资格，不抵扣未来收入。",manual,seconds/60)
    elseif #p.activeOrders>0 then reason="先完成所有手头订单"
    elseif p.career and p.career.pending then reason="先完成已报名训练或赛事，再安排未来工作周"
    elseif p.position.space and p.position.space~="city" then reason="请先离开住处再安排未来工作周"
    elseif p.hunger<35 or p.energy<40 then reason="先吃饭休息，身体不适合排班"
    elseif p.cashCents+gross<costs then reason="该住处的排班支出超过现有现金与收入" end
    return {days=rule.days,fromDay=p.day,toDay=p.day+rule.days,level=level,
        manualOrders=manual,activeSeconds=seconds,requiredManualOrders=rule.requiredManualOrders,
        requiredActiveSeconds=rule.requiredActiveSeconds,remainingManualOrders=math.max(0,rule.requiredManualOrders-manual),
        remainingActiveSeconds=math.max(0,rule.requiredActiveSeconds-seconds),unlockDay=rule.unlockDay,
        simulatedOrders=orders,averageCents=average,grossCents=gross,livingCents=rule.livingCents,
        perOrderCostsCents=rule.perOrderCostCents*orders,housingCents=housing,costsCents=costs,netCents=gross-costs,
        ready=reason=="",reason=reason,
        description="完整模拟未来7天；此前亲送已即时结算，只作资格，不扣未来单量。每次排班后需重新亲送10单和活动15分钟。"}
end
-- 每次周排班都需要新完成15分钟活动与10份亲送，不允许连点快进刷现金。
-- 亲送不再抵扣未来单量；手送越多不会少赚，历史积累超过周单量也照常模拟完整7天。
function Progress.WorkWeek()
    return Store.Transaction(function(p)
        local preview=Progress.WorkWeekPreview(p)
        if not preview.ready then return false,preview.reason end
        extras(p)
        local key="week:"..(p.weeksWorked+1)
        local ok,message=Store.ApplyCash(p,preview.grossCents,"scheduled_delivery",key..":income")
        if not ok then return false,message end
        local paid,detail=Store.ApplyCash(p,-preview.costsCents,"scheduled_living",key..":cost")
        if not paid then return false,detail end
        p.weeksWorked=p.weeksWorked+1
        p.simulatedOrders=p.simulatedOrders+preview.simulatedOrders
        p.lastScheduleManualOrders=p.completedOrders
        p.lastScheduleSeconds=p.activeSeconds or 0
        p.day=p.day+preview.days; p.time=8; p.hunger=65; p.energy=85; p.battery=80
        p.flags.weekSchedule=true
        p.lastDaySummary={day=p.day-1,incomeCents=preview.grossCents,expenseCents=preview.costsCents,balanceCents=p.cashCents}
        print(string.format("[Career.Progression] future week=%d manualQualification=%d simulated=%d netCents=%d",p.weeksWorked,preview.manualOrders,preview.simulatedOrders,preview.netCents))
        return true,string.format("未来7天排班结束：此前亲送%d单仅作资格、不抵未来收入；完整模拟%d单，收入%.2f元，餐食整备住宿%.2f元，新增净存%.2f元。",preview.manualOrders,preview.simulatedOrders,preview.grossCents/100,preview.costsCents/100,preview.netCents/100)
    end)
end
-- 连续成长路线只复用亲送等级、现有装备、人物委托和钱包；不另建可领奖状态。
-- 返回独立快照，反复查询/回读旧档不会补发奖金，也不改变31份旧单报价。
---@param p CareerProfile
---@return table
function Progress.ProgressForecast(p)
    local week=Progress.WorkWeekPreview(p)
    local target=Config.FIRST_MOTORCYCLE_TARGET_CENTS
    local complete=p.flags.firstMotorcycle==true
    local gap=complete and 0 or math.max(0,target-p.cashCents)
    local milestones={}
    local equipmentSteps={}
    local lifeReserve=require("Career.LifeStatus").Plan(p).reserveCents
    for _,item in ipairs(Progress.Equipment) do
        local owned=p.equipment and p.equipment[item.id]==true or false
        local unlocked=Progress.Level(p)>=item.level and (item.id~="large_box" or (p.equipment and p.equipment.insulated_box==true))
        equipmentSteps[#equipmentSteps+1]={id=item.id,title=item.name,owned=owned,unlocked=unlocked==true,
            priceCents=item.price,reserveCents=lifeReserve,remainingCents=owned and 0 or math.max(0,item.price+lifeReserve-p.cashCents),
            description=item.description,required=false,rewardCents=0}
    end
    for _,cents in ipairs(Config.SAVINGS_STEPS_CENTS) do
        milestones[#milestones+1]={id="savings:"..cents,title=string.format("攒车小目标 · %.0f元",cents/100),
            currentCents=p.cashCents,targetCents=cents,remainingCents=math.max(0,cents-p.cashCents),
            done=p.cashCents>=cents,rewardCents=0}
    end
    -- 周次估算使用同一生产预览，考虑等级随模拟订单升级；不伪造亲送收入或领奖。
    local balance,totalSimulated,estimatedWeeks=p.cashCents,p.simulatedOrders or 0,0
    ---@type table<string, any>
    local estimateProfile={}
    for key,value in pairs(p) do estimateProfile[key]=value end
    while not complete and balance<target and estimatedWeeks<1000 do
        estimateProfile.completedOrders=p.completedOrders+estimatedWeeks*Config.WORK_WEEK.requiredManualOrders
        estimateProfile.simulatedOrders=totalSimulated
        estimateProfile.cashCents=balance
        local estimate=Progress.WorkWeekPreview(estimateProfile --[[@as CareerProfile]])
        if estimate.netCents<=0 then break end
        balance=balance+estimate.netCents
        totalSimulated=totalSimulated+estimate.simulatedOrders
        estimatedWeeks=estimatedWeeks+1
    end
    local reachable=complete or balance>=target
    local _,levelName=Progress.Level(p)
    return {targetId="first_motorcycle",targetCents=target,cashCents=p.cashCents,remainingCents=gap,
        motorcyclePriceCents=Progress.Motorcycles[1].price,trainingBudgetCents=200000,livingReserveCents=200000,
        completed=complete,level=week.level,levelName=levelName,week=week,milestones=milestones,equipmentSteps=equipmentSteps,
        estimatedWeeks=reachable and estimatedWeeks or nil,estimatedGameDays=reachable and estimatedWeeks*7 or nil,
        minimumActiveSeconds=reachable and (estimatedWeeks==0 and 0 or week.remainingActiveSeconds+math.max(0,estimatedWeeks-1)*900) or nil,
        requiredNewManualOrders=reachable and (estimatedWeeks==0 and 0 or week.remainingManualOrders+math.max(0,estimatedWeeks-1)*10) or nil,
        unlockDaysRemaining=math.max(0,Config.WORK_WEEK.unlockDay-p.day),
        assumptions="按当前住处、现有周排班和等级成长估算；每周仍需新的10份亲送、15分钟活动与生活条件。未计亲送净收支、装备购置、额外消费或委托奖金，不承诺实际达成时长；无需广告。",
        firstTwentyMinutes={
            {fromMinute=0,toMinute=5,pointId="breakfast",title="认路与第一份热早餐",detail="骑9号到早餐店，停稳下车取餐，再到旧宅交付教学单；配送费5元。"},
            {fromMinute=5,toMinute=15,pointId="breakfast",title="站长的三份新早餐",detail="教学后现场接站长委托，再接3份新早餐准时亲送；必须回早餐店交付，既有一次谢礼15元，不自动远程领奖。"},
            {fromMinute=15,toMinute=20,pointId="bridge",title="把生活和下一步安排清楚",detail="查看饭钱与免费落脚点，按需吃饭休息；随后回桥下接表哥回信。下一阶段累计亲送10单，攒280元双单箱；首车不是20分钟承诺。"},
        }}
end
---@param p CareerProfile
---@return table
function Progress.NextGoal(p)
    local function goal(id,title,detail,pointId,current,target,action)
        return {id=id,title=title,detail=detail,pointId=pointId,point=pointId,current=current,target=target,
            remaining=math.max(0,target-current),action=action,rewardCents=0}
    end
    local order=p.activeOrders[1]
    if order then
        return goal("delivery:"..order.id,order.status=="accepted" and "先取好手头餐品" or "先送好手头餐品",
            "每份订单独立取送；迟到仍按原配送费结算，但不计准时人物委托。",
            order.status=="accepted" and order.pickupId or order.dropoffId,0,1,"delivery")
    end
    if p.career and p.career.pending then
        return goal("career_pending","完成已报名项目","先完成当前训练或赛事，不能同时推进排班。","dealer",0,1,"career")
    end
    if not p.flags.tutorialCompleted then
        return goal("tutorial","第一笔自己挣的钱","先完成教学早餐，认识取餐、交付和5元到账；不需广告。","breakfast",0,1,"delivery")
    end
    if p.hunger<=55 or p.energy<=45 or p.time>=21 then
        local advice=require("Career.LifeStatus").Advice(p)
        return goal("life","先把今天过稳",advice.detail,advice.point,0,1,"life")
    end
    local engagement=require("Career.Engagements").NextGoal(p)
    if engagement and (engagement.id~="mechanic_balance" or p.flags.professional) then return engagement end
    local equipment=p.equipment or {}
    if p.completedOrders<10 then
        return goal("rider_10","成为城市骑手","累计10份亲送开放双单箱；模拟单不代替这项新人目标。","breakfast",p.completedOrders,10,"delivery")
    end
    if not p.flags.firstMotorcycle and p.day<Config.WORK_WEEK.unlockDay
        and p.cashCents<Config.FIRST_MOTORCYCLE_TARGET_CENTS and not equipment.insulated_box then
        local reserve=require("Career.LifeStatus").Plan(p).reserveCents
        return goal("equipment:insulated_box","装稳第一只双单箱",
            "双单箱280元，需另留下一餐和今晚住宿预算；容量变2，每单原价不变，不要求购买才能攒首车。",
            "breakfast",math.max(0,p.cashCents-reserve),Progress.Equipment[1].price,"equipment")
    end
    if not p.flags.firstRest then
        return goal("first_rest","有一个能落脚的晚上","先休息一晚，桥下与公园免费；人物回信与后续排班都需要休息经历。","bridge",0,1,"life")
    end
    if not p.flags.firstMotorcycle then
        local week=Progress.WorkWeekPreview(p)
        if p.cashCents>=Config.FIRST_MOTORCYCLE_TARGET_CENTS then
            return goal("first_motorcycle","去看属于自己的第一辆摩托","5万元已备齐：二手训练版46000元，护具课程预算2000元，生活周转2000元。","dealer",p.cashCents,Config.FIRST_MOTORCYCLE_TARGET_CENTS,"motorcycle")
        end
        if p.day<week.unlockDay then
            return goal("week_unlock","站稳日常，再安排未来7天","第10天开放排班；不必反复空睡，先做好亲送、熟人回访与日常补给。","breakfast",p.day,week.unlockDay,"delivery")
        end
        local forecast=Progress.ProgressForecast(p)
        for _,step in ipairs(forecast.milestones) do
            if not step.done then
                local detail=string.format("距本段还差%.2f元；当前住处未来7天净存%.2f元。",step.remainingCents/100,week.netCents/100)
                return goal(step.id,step.title,detail..(week.ready and "资格已齐，可查看完整排班预览。" or week.reason),
                    "breakfast",p.cashCents,step.targetCents,week.ready and "workWeek" or "delivery")
            end
        end
    end
    if not p.flags.professional then
        return goal("training","从城市街头到封闭训练场","换回9号完成日常配送；车行报名训练并保留2000元周转金。","dealer",0,1,"training")
    end
    return goal("career_series","下一场职业赛","到车行查看已开放赛事与车队合同；住房、装备与收藏按自己的节奏选择。","dealer",p.career and p.career.points or 0,18,"career")
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
        if #p.activeOrders>0 then return false,"先送完外卖再参加训练" end
        if p.career.pending then return false,"已有训练或赛事报名，请继续当前项目" end
        local cost=p.equipment.helmet and 155000 or 200000
        if p.cashCents<cost+200000 then return false,"训练护具后还需保留2000元生活周转金" end
        local ok,message=Store.ApplyCash(p,-cost,"training","training:license")
        if not ok then return false,message end
        p.equipment.helmet=true; p.career.team="南城新人训练营"
        p.career.pending={id="training:license",series=1,vehicle="sport",track="circuit",laps=1,training=true}
        return true,"已报名封闭场地训练：完成1圈顺序检查点，学会刹车与复位。通过后才获得职业资格。"
    end)
end
function Progress.CompleteTraining(finished)
    return Store.Transaction(function(p)
        extras(p)
        if not (p.career.pending and p.career.pending.training) then return false,"没有待完成的训练" end
        if #p.activeOrders>0 then return false,"请先完成配送订单，再结算训练" end
        if not finished then return false,"训练未通过，报名保留，可以免费重练" end
        p.flags.professional=true; p.career.pending=false
        p.day=p.day+3; p.time=8; p.energy=90; p.hunger=70
        return true,"封闭场地训练通过！已掌握顺序检查点与完赛规则，三天课程结束，职业资格开放。"
    end)
end
function Progress.SelectMotorcycle(id)
    return Store.Transaction(function(p)
        if not p.ownedMotorcycles[id] then return false,"先购买这辆摩托" end
        if p.career and p.career.pending then return false,"先完成已报名项目再换车" end
        p.raceVehicle=id
        return true,"已选择生涯参赛车辆；配送仍使用电动车"
    end)
end
function Progress.NextStory(p)
    local stories={
        {id="firstDeliveryStory",ready=p.completedOrders>=1,title="第一笔自己挣的钱",text="王二狗盯着到账提醒看了很久。钱不多，但这顿饭，终于能靠自己挣。\n表哥：别小看第一单。记住店门和楼号，明天就能少走弯路。"},
        {id="riderStory",ready=p.completedOrders>=10,title="老街站，记住了你的名字",text="站长把你的名字写进常跑骑手名单。双单保温箱开放购买，之后每一份都要分别取餐、送达。\n王二狗：先把车箱装稳，再慢慢把生活过稳。"},
        {id="hostelStory",ready=p.flags.stayed_hostel,title="今夜，有一张干净的床",text=require("Career.HousingData").Get("hostel").story},
        {id="roomStory",ready=p.flags.stayed_room,title="一扇能关上的门",text=require("Career.HousingData").Get("room").story},
        {id="apartmentStory",ready=p.flags.stayed_apartment,title="窗边的阳光",text=require("Career.HousingData").Get("apartment").story},
        {id="fiveManStory",ready=p.cashCents>=5000000 and not p.flags.firstMotorcycle,title="五万元的钥匙",text="你反复核对钱包：五万，真的攒到了。\n表哥：南城车行那辆二手训练版还在，46000元。别把钱全花光，护具训练2000，留2000周转。\n这一次，你不是借车的人了。去车行前台看看吧。"},
        {id="ownBikeStory",ready=p.flags.firstMotorcycle,title="人生第一辆摩托",text="交接钥匙时，你想起那辆陪你跑街串巷的战损9号。它没有离开，配送还要靠它。\n师傅：先带好护具，去封闭场地完成训练，再谈比赛。"},
        {id="licenseStory",ready=p.flags.professional,title="从取餐口到发车格",text="第一次完整通过顺序检查点，你知道赛道不只是更快。刹车、线路、耐心，每一样都要重新学。\n新人杯已经开放。职业奖金存入生涯钱包，不兑换独立竞速金币。"},
        {id="teamStory",ready=p.career and p.career.points>=9,title="南城极速的邀请",text="车队递来一张名片：我们看过你的比赛，稳定比一时快更难。\n王二狗：我不怕慢，只怕再也不往前走。\n职业积分已达到车队签约门槛，下一站海岸巡回赛。"},
        {id="winnerStory",ready=p.flags.lifeWinner,title="终章 · 每一段路都算数",text="年度冠军的领奖台上，王二狗没有忘记桥下的那张旧垫子。\n从50元、战损电动车和第一只外卖箱，到属于自己的住处和冠军发车格。\n故事告一段落，生活继续：你仍可以配送、改善住处、收藏摩托和挑战赛事。"},
    }
    for _,story in ipairs(stories) do if story.ready and not p.flags[story.id] then return story end end
end
function Progress.StoryLog(p)
    local titles={
        {"firstDeliveryStory","第一笔自己挣的钱","五元早餐单不多，却让王二狗靠自己吃上下一顿饭。"},
        {"riderStory","老街记住了你的名字","十份亲送以后，双单装备开放。每一份餐，都要独立负责。"},
        {"hostelStory","今夜有一张干净的床",require("Career.HousingData").Get("hostel").story},
        {"roomStory","一扇能关上的门",require("Career.HousingData").Get("room").story},
        {"apartmentStory","窗边的阳光",require("Career.HousingData").Get("apartment").story},
        {"fiveManStory","五万元的钥匙","首辆二手训练摩托46000元；护具课程与生活周转金，一样不能少。"},
        {"ownBikeStory","人生第一辆摩托","旧9号没有被丢下。城市生活与赛场梦想，从此分别握在两串钥匙上。"},
        {"licenseStory","从取餐口到发车格","亲自通过封闭训练后，职业资格开放；奖金进入生涯现金，不改变旧竞速金币。"},
        {"teamStory","南城极速的邀请","九积分是邀请，不是自动入队。到车行明确签约，完成真实赛事目标，再领取赞助。"},
        {"winnerStory","每一段路都算数","从桥下旧垫子到冠军发车格，王二狗记得每一单、每一晚和每一次重新出发。"},
    }
    local log={}
    for _,entry in ipairs(titles) do
        if p.flags[entry[1]] then log[#log+1]={id=entry[1],title=entry[2],text=entry[3]} end
    end
    return log
end
function Progress.MarkStory(id)
    return Store.Transaction(function(p)
        local story=Progress.NextStory(p)
        if not story or story.id~=id then return false,"此剧情尚未触发或已阅读" end
        p.flags[id]=true; return true,"已记下这一段经历"
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
        p.career.pending={id=id,series=index,vehicle=p.raceVehicle or "sport",track=series.track,laps=series.laps}
        return true,"报名成功，进入"..series.name
    end)
end
function Progress.SettleRace(place,finished,expectedRaceId)
    if type(place)~="number" or place%1~=0 or place<1 or place>9 or type(finished)~="boolean" then
        return false,"赛事名次或完赛状态无效"
    end
    return Store.Transaction(function(p)
        extras(p)
        local race=p.career.pending
        if not race then return false,"没有生涯待结算赛事" end
        if #p.activeOrders>0 then return false,"请先完成配送订单，再结算赛事" end
        if expectedRaceId and expectedRaceId~=race.id then return false,"赛事结果已过期，不能结算另一场报名" end
        if race.training then return false,"训练必须通过训练资格入口结算" end
        local series=Progress.Series[race.series]
        local reward=finished and math.floor(series.reward*math.max(.1,(10-place)/9)) or 0
        local ok,message=Store.ApplyCash(p,reward,"career_race",race.id..":reward")
        if not ok then return false,message end
        if finished then p.career.points=p.career.points+math.max(1,4-math.ceil(place/3)) end
        if finished and place==1 then p.career.wins=p.career.wins+1 end
        local tracked,detail=require("Career.Team").OnRace(p,race,place,finished)
        if not tracked then return false,detail end
        if race.series==6 and finished and place==1 then p.flags.lifeWinner=true end
        p.career.pending=false; p.day=p.day+1; p.time=8; p.energy=65
        return true,finished and string.format("生涯赛事结算：第%d名，奖金%.2f元。职业积分%d。",place,reward/100,p.career.points)
            or "本场未完赛，不发奖金、不加积分。报名已结清，可重新报名。"
    end)
end
return Progress
