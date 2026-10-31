-- 生活委托纯逻辑验收。只有显式Run()才运行，内存Store.UseTestStorage先隔离再读档。
-- 不加载Session/场景/真实文件/云API；不替换生产函数，不创建NPC模型。
local Store=require("Career.Store")
local Config=require("Career.Config")
local Delivery=require("Career.Delivery")
local Progress=require("Career.Progression")
local Engagements=require("Career.Engagements")
local Checks={}

local function context(id)
    local point=assert(Config.points[id])
    return {x=point.x,z=point.z,speed=0,riding=false,space="city"}
end
local function row(id)
    local state=Engagements.State(Store.Get())
    assert(state.valid,state.error)
    for _,item in ipairs(state.list) do if item.id==id then return item end end
    error("缺少任务展示："..id)
end
local function instance(p,id)
    return p.engagements.instances["engagement:v1:"..id]
end
local function deliveryCount(id)
    local n=0
    for _ in pairs(instance(Store.Get(),id).deliveryIds) do n=n+1 end
    return n
end
local function findActive(id)
    for _,order in ipairs(Store.Get().activeOrders) do if order.id==id then return order end end
    error("缺少活动订单："..id)
end
local function acceptOrder()
    local offer=assert(Delivery.GetOffer())
    assert(Delivery.Accept(offer.id))
    local from=assert(Config.points[offer.pickupId])
    assert(Delivery.Pickup(offer.id,from.x,from.z,{riding=false,speed=0}))
    return offer.id
end
-- 与Delivery.Deliver相同的事务顺序，单独测试hook，不依赖主线程是否已完成接线。
-- 真实Delivery.Accept/Pickup构造订单；不凭空伪造亲送成果，不嵌套事务。
local function settle(id)
    return Store.Transaction(function(p)
        local order,index
        for i,item in ipairs(p.activeOrders) do if item.id==id then order,index=item,i; break end end
        if not order or order.status~="picked_up" or p.settledOrders[id] then return false,"不能重复交付" end
        local ok,message=Store.ApplyCash(p,order.feeCents,"delivery","delivery:"..id)
        if not ok then return false,message end
        p.settledOrders[id]=true; p.completedOrders=p.completedOrders+1
        if order.tutorial then p.flags.tutorialCompleted=true end
        p.flags.firstDelivery=true
        local credited,detail=Engagements.OnDelivery(p,order)
        if not credited then return false,detail end
        -- 同一事务重复通知无额外计数，确保按来源ID去重而不是最大序号。
        local repeated,reason=Engagements.OnDelivery(p,order)
        if not repeated then return false,reason end
        table.remove(p.activeOrders,index)
        p.phase="working"
        return true
    end)
end
local function deliver() local id=acceptOrder(); assert(settle(id)); return id end
-- 模板会随世界扩展；只假定有早餐店订单，不把某个sequence绑定到某个商家。
local function acceptBreakfast()
    for _=1,64 do
        local id=acceptOrder()
        if findActive(id).pickupId=="breakfast" then return id end
        local p=Store.Get()
        local before=p.engagements and deliveryCount("breakfast_shift") or 0
        assert(settle(id))
        if p.engagements then assert(deliveryCount("breakfast_shift")==before,"其他商家不计早餐委托") end
    end
    error("64次报价内缺少早餐店模板")
end
local function grant(cents,key)
    assert(Store.Transaction(function(p) return Store.ApplyCash(p,cents,"test_fixture",key) end))
end
local function validateCopy(mutator)
    local p=Store.Get()
    mutator(p)
    assert(not Engagements.Validate(p),"损坏的委托档案必须拒绝")
end

---@return boolean
function Checks.Run()
    local files={}
    local failWrite=false
    local writes=0
    local cloudCalls=0
    local function cloudForbidden()
        cloudCalls=cloudCalls+1
        error("委托测试禁止请求真实云或云桩")
    end
    local restore=Store.UseTestStorage({
        read=function(path) return files[path],nil,files[path]==nil end,
        write=function(path,text)
            writes=writes+1
            if failWrite then return false,"委托验收模拟写失败" end
            files[path]=text
            return true
        end,
        cloud={Get=cloudForbidden,Set=cloudForbidden},
    })
    local ok,message=pcall(function()
        assert(Store.NewCareer())
        local original=Store.Get()
        assert(original.engagements==nil and Engagements.Validate(original))
        local beforeWrites=writes
        assert(Engagements.State(original).list[1].status=="locked")
        assert(writes==beforeWrites and Store.Get().engagements==nil,"只读State不能迁移或写档")
        assert(Store.Load() and Store.Get().engagements==nil,"无委托字段的v1旧档必须兼容")

        for _,bad in ipairs({"unknown","engagement:v1:breakfast_shift","","teamContract"}) do
            assert(not Engagements.Accept(bad,context("breakfast")))
            assert(not Engagements.Claim(bad,context("breakfast")))
        end
        assert(not Engagements.Accept(nil,context("breakfast")))
        assert(not Engagements.Visit("dealer",context("dealer")))
        assert(not Engagements.Accept("cousin_reply",context("bridge")))
        assert(not Engagements.Accept("mechanic_balance",context("dealer")))
        assert(not Engagements.Accept("breakfast_shift",context("breakfast")),"教学未完成不能接站长委托")
        assert(not Engagements.Claim("engagement:v1:breakfast_shift",context("breakfast")))
        deliver() -- 教学首单只能解锁，不可以追补委托进度。
        assert(row("breakfast_shift").status=="available")
        assert(Store.Rest("bridge"))
        assert(Store.Transaction(function(p) p.equipment={insulated_box=true,large_box=true}; return true end))
        -- 接委托之前已接的同店订单，哪怕之后准时亲送，也不能计入。
        local old=acceptOrder()
        for _,badContext in ipairs({{},context("bridge"),
            {x=-25,z=-8,speed=0,riding=true,space="city"},
            {x=-25,z=-8,speed=.351,riding=false,space="city"},
            {x=-25,z=-8,speed=0,riding=false,space="hostel"},
            {x=-25,z=-8,speed=math.huge,riding=false,space="city"},
            {x=0/0,z=-8,speed=0,riding=false,space="city"}}) do
            assert(not Engagements.Accept("breakfast_shift",badContext --[[@as CareerEngagementContext]]),"缺省或非法现场状态不能远程接委托")
        end
        assert(not Engagements.Accept("breakfast_shift",nil),"不传现场ctx必须拒绝")
        local before=Store.Get(); local disk=files[Config.SAVE_PATH]
        failWrite=true; assert(not Engagements.Accept("breakfast_shift",context("breakfast"))); failWrite=false
        assert(Store.Get().engagements==nil and Store.Get().revision==before.revision and files[Config.SAVE_PATH]==disk)
        -- 半径边界2m与速度边界允许，超出则拒绝。
        local edge=context("breakfast"); edge.x=edge.x+2; edge.speed=.35
        assert(Engagements.Accept("breakfast_shift",edge))
        assert(not Engagements.Accept("breakfast_shift",context("breakfast")))
        assert(instance(Store.Get(),"breakfast_shift").minOrderSequence==before.nextOrderSequence)
        assert(settle(old) and deliveryCount("breakfast_shift")==0,"旧已接单不能在接取后追补")
        assert(Store.Load() and deliveryCount("breakfast_shift")==0)
        assert(not Engagements.Claim(row("breakfast_shift").instanceId,context("breakfast")))

        -- 两份新早餐单倒序亲送，不能用最大订单ID作水位去重。
        local a,b=acceptBreakfast(),acceptBreakfast()
        assert(findActive(a).pickupId=="breakfast" and findActive(b).pickupId=="breakfast")
        assert(Store.Transaction(function(p)
            assert(Engagements.OnDelivery(p,findActive(a)),"拷贝订单回调必须无害忽略")
            for _,order in ipairs(p.activeOrders) do
                assert(Engagements.OnDelivery(p,order),"无结算流水的活动单不得计数")
            end
            return true
        end))
        assert(deliveryCount("breakfast_shift")==0)
        local saved=Store.Get(); disk=files[Config.SAVE_PATH]
        failWrite=true; assert(not settle(b)); failWrite=false
        assert(Store.Get().cashCents==saved.cashCents and Store.Get().revision==saved.revision
            and not Store.Get().settledOrders[b] and deliveryCount("breakfast_shift")==0 and files[Config.SAVE_PATH]==disk,
            "配送落盘失败必须原子回滚现金/订单/来源")
        assert(settle(b) and settle(a) and deliveryCount("breakfast_shift")==2)
        assert(not settle(b) and deliveryCount("breakfast_shift")==2)
        -- 纯粹增加排班/计数不触发来源，假order/拷贝订单/无流水也不能推进。
        assert(Store.Transaction(function(p)
            p.simulatedOrders=(p.simulatedOrders or 0)+1000
            assert(Engagements.OnDelivery(p,{id="scheduled:1",status="picked_up",late=false,remainingHours=1,tutorial=false}))
            return true
        end))
        assert(deliveryCount("breakfast_shift")==2)
        local late=acceptBreakfast()
        assert(findActive(late).pickupId=="breakfast")
        assert(Store.Transaction(function(p)
            for _,order in ipairs(p.activeOrders) do if order.id==late then order.late=true; order.remainingHours=-.1 end end
            return true
        end))
        assert(settle(late) and deliveryCount("breakfast_shift")==2,"迟到单即使正常拿配送费也不计委托")
        local inconsistentLate=acceptBreakfast()
        assert(Store.Transaction(function(p)
            for _,order in ipairs(p.activeOrders) do if order.id==inconsistentLate then order.late=false; order.remainingHours=-.1 end end
            return true
        end))
        assert(settle(inconsistentLate) and deliveryCount("breakfast_shift")==2,"remainingHours负数也必须拒计")
        assert(settle(acceptBreakfast()))
        assert(deliveryCount("breakfast_shift")==3 and row("breakfast_shift").status=="ready")
        local ready=Store.Get()
        local outside=context("breakfast"); outside.x=outside.x+2.001
        assert(not Engagements.Claim(row("breakfast_shift").instanceId,outside))
        assert(not Engagements.Claim(row("breakfast_shift").instanceId,nil),"手机直接领奖必须拒绝")
        failWrite=true; assert(not Engagements.Claim(row("breakfast_shift").instanceId,context("breakfast"))); failWrite=false
        assert(Store.Get().cashCents==ready.cashCents and not instance(Store.Get(),"breakfast_shift").claimed)
        assert(Engagements.Claim(row("breakfast_shift").instanceId,context("breakfast")))
        assert(Store.Get().cashCents==ready.cashCents+1500 and #Engagements.State(Store.Get()).letters==1)
        local afterClaim=Store.Get()
        assert(not Engagements.Claim(row("breakfast_shift").instanceId,context("breakfast")))
        assert(not Engagements.Accept("breakfast_shift",context("breakfast")))
        assert(Store.Load() and not Engagements.Claim(row("breakfast_shift").instanceId,context("breakfast")))
        assert(Store.Get().cashCents==afterClaim.cashCents and Store.Get().revision==afterClaim.revision)

        assert(not Engagements.Visit("park",context("park")),"接取前访问不留待补记")
        assert(Engagements.Accept("cousin_reply",context("bridge")))
        assert(not Engagements.Visit("park",context("bridge")))
        failWrite=true; assert(not Engagements.Visit("park",context("park"))); failWrite=false
        assert(not instance(Store.Get(),"cousin_reply").visits.park)
        assert(Engagements.Visit("convenience",context("convenience")))
        assert(not Engagements.Visit("convenience",context("convenience")))
        assert(not Engagements.Claim(row("cousin_reply").instanceId,context("bridge")))
        assert(Store.Load() and instance(Store.Get(),"cousin_reply").visits.convenience)
        assert(Engagements.Visit("park",context("park")))
        assert(row("cousin_reply").status=="ready")
        assert(not Engagements.Claim(row("cousin_reply").instanceId,context("park")))
        assert(Engagements.Claim(row("cousin_reply").instanceId,context("bridge")))
        assert(not Engagements.Visit("park",context("park")))
        assert(#Engagements.State(Store.Get()).letters==2)

        assert(Engagements.Accept("mechanic_balance",context("dealer")))
        assert(not Engagements.Claim(row("mechanic_balance").instanceId,context("dealer")))
        local beforeTraining=deliveryCount("mechanic_balance")
        deliver()
        assert(deliveryCount("mechanic_balance")==beforeTraining,"未通过训练的亲送不算维持生活成果")
        grant(6000000,"test:engagement-motorcycle")
        assert(Progress.BuyMotorcycle("sport"))
        assert(Progress.Train())
        assert(not Progress.CompleteTraining(false))
        deliver()
        assert(deliveryCount("mechanic_balance")==0,"只报名未通过训练不计")
        assert(Progress.CompleteTraining(true))
        local first,second=acceptOrder(),acceptOrder()
        assert(settle(second) and settle(first) and deliveryCount("mechanic_balance")==2)
        deliver(); deliver()
        assert(deliveryCount("mechanic_balance")==4 and row("mechanic_balance").canClaim)
        assert(Store.Transaction(function(p) p.hunger=34; return true end))
        assert(not Engagements.Claim(row("mechanic_balance").instanceId,context("dealer")))
        assert(Store.Transaction(function(p) p.hunger=65; p.energy=39; return true end))
        assert(not Engagements.Claim(row("mechanic_balance").instanceId,context("dealer")))
        assert(Store.Transaction(function(p) p.energy=80; return true end))
        local balance=Store.Get().cashCents
        assert(Store.Pay(balance-1199,"test_fixture","test:engagement-low-cash"))
        assert(not Engagements.Claim(row("mechanic_balance").instanceId,context("dealer")),"不能用未领取奖金预支饭钱")
        grant(1,"test:engagement-one-cent")
        assert(row("mechanic_balance").canClaim)
        assert(Engagements.Claim(row("mechanic_balance").instanceId,context("dealer")))
        local finished=Engagements.State(Store.Get())
        assert(finished.completedCount==3 and #finished.letters==3 and Store.Get().cashCents==3200)
        assert(not Engagements.Claim(row("mechanic_balance").instanceId,context("dealer")))
        assert(Store.Load() and Engagements.State(Store.Get()).completedCount==3)
        -- 奖励分录严格为整数分，各自稳定键只有一笔，不触碰teamContract。
        local rewards=0
        for _,entry in ipairs(Store.Get().ledger) do
            if entry.kind=="engagement" then rewards=rewards+1; assert(entry.deltaCents%1==0) end
        end
        assert(rewards==3 and Store.Get().teamContract==nil)
        local state=Engagements.State(Store.Get()); state.list[1].rewardCents=999999; state.letters[1].title="modified"
        assert(Engagements.State(Store.Get()).letters[1].title~="modified","UI只能修改展示副本")
        -- 领奖后正常吃饭消耗不应使已交付状态失效。
        assert(Store.Transaction(function(p) p.hunger=0; p.energy=0; return true end))
        assert(Engagements.Validate(Store.Get()))
        validateCopy(function(p) instance(p,"breakfast_shift").minOrderSequence=0 end)
        validateCopy(function(p) p.engagements.version=9 end)
        validateCopy(function(p) p.engagements.credited["career-v1-999"]=row("breakfast_shift").instanceId end)
        validateCopy(function(p) p.engagements.letters["fake"]={} end)
        validateCopy(function(p) p.engagements.letters["engagement:v1:breakfast_shift"].text="篡改" end)
        validateCopy(function(p) p.engagements.instances["engagement:v1:breakfast_shift"]=nil end)
        validateCopy(function(p) p.engagements=nil end)
        validateCopy(function(p) instance(p,"mechanic_balance").claimed=false end)
        ---@diagnostic disable-next-line: param-type-mismatch
        assert(not Engagements.Validate(false))
        assert(not Engagements.Validate({engagements={}}))

        -- 已买车/已通过训练的老玩家可接受师傅任务，不要求不可重复的购车/训练再做一次。
        local p=Store.Get()
        p.engagements.instances["engagement:v1:mechanic_balance"]=nil
        for orderId,owner in pairs(p.engagements.credited) do
            if owner=="engagement:v1:mechanic_balance" then p.engagements.credited[orderId]=nil end
        end
        p.engagements.letters["engagement:v1:mechanic_balance"]=nil
        p.flags.engagement_mechanic_balance=nil
        local replacement={}
        local running=0
        for _,entry in ipairs(p.ledger) do
            if entry.id~="engagement:v1:mechanic_balance:reward" then
                running=running+entry.deltaCents; entry.balanceCents=running
                replacement[#replacement+1]=entry
            end
        end
        p.ledger=replacement; p.cashCents=running
        p.financialKeys["engagement:v1:mechanic_balance:reward"]=nil
        assert(Engagements.Validate(p))
        files[Config.SAVE_PATH]=cjson.encode(p)
        assert(Store.Load())
        assert(Engagements.Accept("mechanic_balance",context("dealer")))
        local objectives=row("mechanic_balance").objectives
        assert(objectives[1].done and objectives[2].done and objectives[3].current==0)
        assert(not Engagements.Claim(row("mechanic_balance").instanceId,context("dealer")),"旧亲送仍不可用于新委托")

        -- 真正生产Delivery.Deliver接线回归：不调用上面的settle替身。
        assert(Store.NewCareer())
        local function realDeliver(id)
            for _,order in ipairs(Store.Get().activeOrders) do
                if order.id==id then
                    local target=assert(Config.points[order.dropoffId])
                    return Delivery.Deliver(id,target.x,target.z,{riding=false,speed=0})
                end
            end
            return Delivery.Deliver(id,0,0,{riding=false,speed=0})
        end
        assert(realDeliver(acceptOrder())) -- 教学走生产入口，只解锁不追补。
        assert(Engagements.Accept("breakfast_shift",context("breakfast")))
        local eligible=0
        for _=1,64 do
            local id=acceptOrder()
            local order=findActive(id)
            if order.pickupId=="breakfast" then
                if eligible==0 then
                    local cash=Store.Get().cashCents
                    failWrite=true; assert(not realDeliver(id)); failWrite=false
                    assert(Store.Get().cashCents==cash and deliveryCount("breakfast_shift")==0,
                        "生产Deliver失败时委托/现金必须一起回滚")
                end
                eligible=eligible+1
            end
            assert(realDeliver(id))
            assert(deliveryCount("breakfast_shift")==eligible,"生产Delivery.Deliver必须调用委托hook")
            assert(not realDeliver(id),"生产Deliver不能重复结算")
            if eligible==3 then break end
        end
        assert(eligible==3 and row("breakfast_shift").canClaim)
        assert(Engagements.Claim(row("breakfast_shift").instanceId,context("breakfast")))
        assert(Store.Load() and row("breakfast_shift").claimed)
        assert(cloudCalls==0)
        print("[生活委托验收通过] 三条前置人物链/现场授权/新亲送与倒序来源去重/旧单模拟单迟到拒计/回访回信/训练后维生/整数分一次奖信/写失败原子回滚/旧档兼容/生产Deliver接线/全内存无云")
    end)
    restore() -- finally：成功/断言失败都恢复原Store状态，不读写玩家真实档。
    if not ok then error(message) end
    return true
end

return Checks
