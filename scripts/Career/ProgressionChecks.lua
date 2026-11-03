-- 成长经济短验收：显式Run()才执行，全内存、无场景、无File/云请求。
-- 与旧Checks.RunProgression并行补充；不要把只读路线图当成已加速或新奖励。
local Store=require("Career.Store")
local Config=require("Career.Config")
local Progress=require("Career.Progression")
local Delivery=require("Career.Delivery")
local Life=require("Career.LifeStatus")
local Property=require("Career.Property")
local Checks={}
local function same(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~="table" then return a==b end
    for key,value in pairs(a) do if not same(value,b[key]) then return false end end
    for key in pairs(b) do if a[key]==nil then return false end end
    return true
end
local function complete()
    local offer=assert(Delivery.GetOffer())
    assert(Delivery.Accept(offer.id))
    local from,to=assert(Config.points[offer.pickupId]),assert(Config.points[offer.dropoffId])
    assert(Delivery.Pickup(offer.id,from.x,from.z,{riding=false,speed=0}))
    assert(Delivery.Deliver(offer.id,to.x,to.z,{riding=false,speed=0}))
end
function Checks.Run()
    local files={}
    local writes,cloudCalls=0,0
    local failWrite=false
    local function noCloud() cloudCalls=cloudCalls+1; error("成长预算验收禁止访问云") end
    Store.WithTestStorage({read=function(path) return files[path],nil,files[path]==nil end,
        write=function(path,text)
            if failWrite then return false,"成长预算模拟写失败" end
            writes=writes+1; files[path]=text; return true
        end,cloud={Get=noCloud,Set=noCloud}},function()
        assert(Store.NewCareer())
        local original=Store.Get()
        local beforeWrites=writes
        local goal=Progress.NextGoal(original)
        local forecast=Progress.ProgressForecast(original)
        assert(goal.id=="tutorial" and forecast.targetCents==5000000 and #forecast.firstTwentyMinutes==3)
        assert(#forecast.equipmentSteps==5 and forecast.equipmentSteps[1].priceCents==28000
            and not forecast.equipmentSteps[1].required and forecast.equipmentSteps[1].rewardCents==0)
        assert(same(original,Store.Get()) and writes==beforeWrites,"查询不得迁移、发钱或写档")
        forecast.firstTwentyMinutes[1].title="mutated"
        assert(Progress.ProgressForecast(original).firstTwentyMinutes[1].title~="mutated")
        assert(#Config.orderTemplates==31,"现有31份报价模板不能增删")
        for _,template in ipairs(Config.orderTemplates) do
            local fee=template.tutorial and 500 or Config.FeeCents(Config.RouteDistance(template.route))
            assert(fee%1==0 and fee>=250 and fee<=1000)
        end
        -- 任意快照仅用于查询预算；事务中的亲送来源在下方走真实Delivery构造。
        local p=Store.Get()
        p.day=10; p.flags.firstRest=true; p.completedOrders=10; p.activeSeconds=900
        p.hunger=80; p.energy=80
        local low=Progress.WorkWeekPreview(p)
        assert(low.ready and low.simulatedOrders==240 and low.grossCents==139200
            and low.costsCents==24800 and low.netCents==114400)
        p.completedOrders=39
        local more=Progress.WorkWeekPreview(p)
        assert(more.netCents==low.netCents and more.simulatedOrders==240,"同档多亲送不能使未来收入变少")
        p.completedOrders=40
        local skilled=Progress.WorkWeekPreview(p)
        assert(skilled.simulatedOrders==300 and skilled.netCents==153400)
        p.completedOrders=120
        local gold=Progress.WorkWeekPreview(p)
        assert(gold.simulatedOrders==348 and gold.grossCents==215760 and gold.netCents==187720)
        p.completedOrders=1000
        assert(Progress.WorkWeekPreview(p).netCents==gold.netCents,"超过整周历史单量不能清空未来收入")
        p.lastScheduleManualOrders=990; p.lastScheduleSeconds=0
        assert(Progress.WorkWeekPreview(p).netCents==gold.netCents)
        p.lastScheduleManualOrders=991
        assert(not Progress.WorkWeekPreview(p).ready,"新亲送9单不能开周")
        p.lastScheduleManualOrders=990; p.activeSeconds=899.99
        assert(not Progress.WorkWeekPreview(p).ready,"活动不足900秒不能开周")
        p.activeSeconds=900
        p.career={pending={training=true}}
        assert(not Progress.WorkWeekPreview(p).ready,"已报名训练不能被排班推进时间")
        p.career=nil; p.position.space="hostel"
        assert(not Progress.WorkWeekPreview(p).ready)
        p.position.space="city"
        p.completedOrders=10; p.lastScheduleManualOrders=0; p.cashCents=5000
        for _,scenario in ipairs({
            {id="bridge",net=114400,weeks=27}, {id="hostel",net=93400,weeks=31},
            {id="room",net=68900,weeks=36}, {id="apartment",net=9400,weeks=62},
        }) do
            p.accommodation=scenario.id
            local preview=Progress.WorkWeekPreview(p)
            local plan=Progress.ProgressForecast(p)
            assert(preview.netCents==scenario.net and plan.estimatedWeeks==scenario.weeks,
                "真实住宿成本与首车周次预算不一致："..scenario.id)
            assert(plan.requiredNewManualOrders==(scenario.weeks-1)*10
                and plan.minimumActiveSeconds==(scenario.weeks-1)*900)
            for _,step in ipairs(plan.milestones) do assert(step.rewardCents==0,"里程碑不自动发新奖金") end
        end
        p.accommodation="room"; p.ownedHomes={room=true}
        assert(Progress.WorkWeekPreview(p).netCents==114400)
        local value=assert(Property.Value(p,"room"))
        assert(value.currentWeekSavingsCents==45500 and value.potentialWeekSavingsCents==45500
            and value.rentEquivalentNights==1231 and value.passiveIncomeCents==0)
        p.accommodation="bridge"
        assert(assert(Property.Value(p,"room")).currentWeekSavingsCents==0,"不住这套就不能宣称当周已省租")
        assert(assert(Property.Value(p,"apartment")).potentialWeekSavingsCents==105000)
        assert(assert(Property.Value(p,"hostel")).potentialWeekSavingsCents==0)
        p.flags.firstMotorcycle=true
        assert(Progress.ProgressForecast(p).completed and Progress.ProgressForecast(p).estimatedWeeks==0)
        assert(writes==beforeWrites and same(original,Store.Get()),"全部快照预算应只读")

        -- 真正事务：亲送来源/现金流水不伪造；写失败后下一次仍可完整领取同一未来周。
        for _=1,12 do complete() end
        assert(Store.Transaction(function(draft)
            draft.day=10; draft.flags.firstRest=true; draft.activeSeconds=900; draft.hunger=80; draft.energy=80
            return true
        end))
        local before=Store.Get(); local disk=files[Config.SAVE_PATH]
        failWrite=true; assert(not Progress.WorkWeek()); failWrite=false
        assert(same(before,Store.Get()) and disk==files[Config.SAVE_PATH],"写失败须回滚钱包/水位/周数")
        local preview=Progress.WorkWeekPreview(before)
        local ok,message=Progress.WorkWeek()
        assert(ok and message:find("未来7天") and message:find("不抵未来收入"))
        local after=Store.Get()
        assert(after.cashCents==before.cashCents+preview.netCents and after.simulatedOrders==240
            and after.completedOrders==12 and after.lastScheduleManualOrders==12
            and after.lastScheduleSeconds==900 and after.day==17 and after.weeksWorked==1)
        assert(after.financialKeys["week:1:income"] and after.financialKeys["week:1:cost"])
        assert(not Progress.WorkWeek() and same(after,Store.Get()),"防连点且失败不落盘")
        assert(Store.Load() and not Progress.WorkWeek(),"重载不重置新亲送/活动资格")
        assert(Progress.WorkWeekPreview(Store.Get()).remainingManualOrders==10
            and Progress.WorkWeekPreview(Store.Get()).remainingActiveSeconds==900)
        for _=1,10 do complete() end
        assert(not Progress.WorkWeek(),"新送10单仍需新活动时间")
        assert(Store.Advance(900,0) and Store.Eat())
        before=Store.Get(); preview=Progress.WorkWeekPreview(before)
        assert(preview.simulatedOrders==348 and Progress.WorkWeek())
        after=Store.Get()
        assert(after.weeksWorked==2 and after.simulatedOrders==588
            and after.cashCents==before.cashCents+preview.netCents)
        local scheduled=0
        for _,entry in ipairs(after.ledger) do
            assert(entry.deltaCents%1==0 and entry.balanceCents>=0)
            if entry.kind=="scheduled_delivery" or entry.kind=="scheduled_living" then scheduled=scheduled+1 end
        end
        assert(scheduled==4)
        -- 迟到提示无暗扣；生产Deliver仍按原报价真实入账。
        local offer=assert(Delivery.GetOffer()); assert(Delivery.Accept(offer.id))
        local from,to=assert(Config.points[offer.pickupId]),assert(Config.points[offer.dropoffId])
        assert(Delivery.Pickup(offer.id,from.x,from.z,{riding=false,speed=0}))
        assert(Store.Transaction(function(draft)
            draft.activeOrders[1].remainingHours=0; draft.activeOrders[1].late=false; return true
        end))
        assert(not Life.DeliveryFeedback(Store.Get().activeOrders[1]).late,"倒计时0是准时边界")
        assert(Store.Transaction(function(draft)
            draft.activeOrders[1].remainingHours=-.1; draft.activeOrders[1].late=false; return true
        end))
        before=Store.Get(); beforeWrites=writes
        local feedback=Life.DeliveryFeedback(before.activeOrders[1])
        assert(feedback.late and feedback.penaltyCents==0 and feedback.payableCents==offer.feeCents
            and not feedback.meetsOnTimeCondition and writes==beforeWrites)
        assert(Delivery.Deliver(offer.id,to.x,to.z,{riding=false,speed=0}))
        assert(Store.Get().cashCents==before.cashCents+offer.feeCents and not Delivery.Deliver(offer.id,to.x,to.z))
        assert(cloudCalls==0)
        print("[成长经济验收通过] 完整未来7天/多跑不少赚/历史超量/新资格防连点/整数分与写失败回滚/31报价数量/只读目标与27-62周预算/住房免租不生钱/迟到原价不暗扣")
    end)
    return true
end
return Checks
