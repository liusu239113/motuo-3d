-- 固定生活人物委托。纯逻辑模块，不创建NPC模型，不触碰车队/赛事合同。
-- Session必须传实时现场ctx；UI只能向Session提交ID，不能缓存ctx或直接调用领奖。
-- Store.validate需调用Validate(p)，缺字段旧档不迁移、不补发；读取State绝不写档。
-- Delivery.Deliver同一事务中：ApplyCash -> settledOrders/completedOrders ->
-- OnDelivery(p, order) -> table.remove(activeOrders)；必须检查返回值，不可嵌套Transaction。
local Store = require("Career.Store")
local Config = require("Career.Config")
local Engagements = {}

---@class CareerEngagementContext
---@field x number Session当前角色世界坐标，米；不可用UI或存档坐标代替
---@field z number
---@field riding boolean 必须显式false
---@field speed number 实时m/s
---@field space string 必须city

local definitions = {
    {
        id="breakfast_shift", instanceId="engagement:v1:breakfast_shift",
        title="热早餐，要趁热送", npcId="station_master", npcName="早餐店站长",
        acceptPointId="breakfast", returnPointId="breakfast", rewardCents=1500,
        description="站长想看看你能否把新接的热早餐稳稳送到。做完后，回早餐店当面交接。",
        prerequisiteText="完成教学首单后，到老街早餐店找站长。",
        objectiveText="接取委托后新接3份早餐店订单，亲自取送且未迟到；旧已接单、教学单和排班模拟单不计。最后回早餐店交付。",
        letterTitle="站长的常跑名单",
        letterText="名字记进名单，不是因为你跑得快，而是你把三份热早餐准时送到了。以后路过店门，记得先吃饭，再赶路。——站长",
    },
    {
        id="cousin_reply", instanceId="engagement:v1:cousin_reply",
        title="给桥下的一个回信", npcId="cousin", npcName="桥下表哥",
        acceptPointId="bridge", returnPointId="bridge", rewardCents=800,
        description="表哥不催你赚钱，只想知道你已经认得城市里能落脚、能补给的地方。",
        prerequisiteText="交付站长委托，并至少休息过一晚，再到桥下找表哥。",
        objectiveText="接取后步行停稳，分别现场访问公园长椅和社区便利取货口（先后不限），再回桥下当面回信。访问不是住宿或消费。",
        letterTitle="钥匙还在你手里",
        letterText="你说公园能歇脚，便利店能补给，我就放心了。那辆旧9号不用急着还，先把今天过好。别把所有钱都押在明天。——表哥",
    },
    {
        id="mechanic_balance", instanceId="engagement:v1:mechanic_balance",
        title="有了摩托，也要过日子", npcId="mechanic", npcName="车行师傅",
        acceptPointId="dealer", returnPointId="dealer", rewardCents=2000,
        description="师傅希望你在训练之外仍能靠亲送维持生活，不让新车变成负担。",
        prerequisiteText="交付表哥的回信后，到车行找师傅。",
        objectiveText="合法购入任一摩托并通过入门训练（已有成果有效，无需重买重训）；接取后且通过训练后完成4份新的准时亲送，回车行时保留12元饭钱、饥饿≥35、精力≥40。用9号配送，不要求骑摩托送餐。",
        letterTitle="慢一点，生活不断线",
        letterText="你买了车、学了规矩，还记得换回9号认真送餐。能留出饭钱、照顾身体，才有底气把路走远。这点心意只给一次，别拿它替代日常收入。——师傅",
    },
}
-- 对外是数组而非函数；内部定义与公开副本隔离，UI误改文案不能改变奖金/规则。
local function copy(value)
    if type(value)~="table" then return value end
    local result={}
    for key,item in pairs(value) do result[key]=copy(item) end
    return result
end
Engagements.Definitions=copy(definitions)
---@type table<string, table>
local byId={}
---@type table<string, table>
local byInstance={}
for _,def in ipairs(definitions) do byId[def.id]=def; byInstance[def.instanceId]=def end

local function finite(n)
    return type(n)=="number" and n==n and n>-math.huge and n<math.huge
end
local function integer(n,minimum)
    return finite(n) and n%1==0 and n>=minimum and n<=9007199254740991
end
local function stamp(day,time)
    return integer(day,1) and finite(time) and time>=0 and time<=24
end
local function atOrAfter(day,time,otherDay,otherTime)
    return day>otherDay or (day==otherDay and time>=otherTime)
end
local function rewardKey(def) return def.instanceId..":reward" end
local function flagKey(def) return "engagement_"..def.id end
local function deliveryTarget(def) return def.id=="breakfast_shift" and 3 or def.id=="mechanic_balance" and 4 or 0 end
local function count(map)
    local n=0
    for _ in pairs(map) do n=n+1 end
    return n
end
---@return table?
local function instance(p,id)
    return p.engagements and p.engagements.instances[byId[id].instanceId] or nil
end
local function claimed(p,id)
    local item=instance(p,id)
    return type(item)=="table" and item.claimed==true
end
local function ledgerEntry(p,key)
    for _,entry in ipairs(p.ledger or {}) do if entry.id==key then return entry end end
    return nil
end
local function ownsMotorcycle(p)
    for id,owned in pairs(p.ownedMotorcycles or {}) do
        local entry=ledgerEntry(p,"motorcycle:"..id)
        if owned==true and p.financialKeys["motorcycle:"..id]==true
            and entry and entry.kind=="motorcycle" and entry.deltaCents<0 then return true end
    end
    return false
end
local function trained(p)
    local entry=ledgerEntry(p,"training:license")
    return p.flags.professional==true and p.financialKeys["training:license"]==true
        and entry~=nil and entry.kind=="training" and entry.deltaCents<0
end
local function condition(id,text,current,target,pointId)
    return {id=id,text=text,current=current,target=target,done=current>=target,pointId=pointId}
end
local function prerequisites(p,def)
    if def.id=="breakfast_shift" then
        return {condition("tutorial","完成教学首单",p.flags.tutorialCompleted==true and 1 or 0,1,"breakfast")}
    elseif def.id=="cousin_reply" then
        return {condition("station","交付站长委托",claimed(p,"breakfast_shift") and 1 or 0,1,"breakfast"),
            condition("rest","至少休息一晚",p.flags.firstRest==true and 1 or 0,1,"bridge")}
    end
    return {condition("cousin","交付表哥回信",claimed(p,"cousin_reply") and 1 or 0,1,"bridge")}
end
local function allDone(items)
    for _,item in ipairs(items) do if not item.done then return false end end
    return true
end
local function objectives(p,def,item)
    local done=item and count(item.deliveryIds) or 0
    if def.id=="breakfast_shift" then
        return {condition("new_breakfast","接取后新接、准时亲送早餐店订单",done,3,"breakfast")}
    elseif def.id=="cousin_reply" then
        return {condition("park","接取后到公园长椅现场访问",item and item.visits.park and 1 or 0,1,"park"),
            condition("convenience","接取后到社区便利取货口现场访问",item and item.visits.convenience and 1 or 0,1,"convenience")}
    end
    return {condition("motorcycle","合法购入摩托（已有成果有效）",ownsMotorcycle(p) and 1 or 0,1,"dealer"),
        condition("training","通过入门训练（已有成果有效）",trained(p) and 1 or 0,1,"dealer"),
        condition("new_manual","接取后、通过训练后的新准时亲送",done,4,"breakfast"),
        condition("meal_cash","交付前保留饭钱（分，奖金不预支）",p.cashCents,1200),
        condition("hunger","交付时饥饿值",p.hunger,35,"breakfast"),
        condition("energy","交付时精力值",p.energy,40,"bridge")}
end

-- 现场授权区域（与城市marker共用，不创建碰撞体）：
--       outside | [ x/z圆，r=Config.INTERACTION_RADIUS=2m ] | outside
-- Session实时角色点 -> 圆内(含边界) + city + 步行 + |speed|<=0.35m/s -> 允许。
-- 室内、骑乘、缺失/NaN/无限值或刚好在圆外均拒绝；UI旧ctx不得复用。
local function canInteract(pointId,ctx)
    if type(ctx)~="table" or not finite(ctx.x) or not finite(ctx.z)
        or not finite(ctx.speed) or type(ctx.riding)~="boolean" or type(ctx.space)~="string" then
        return false,"委托交互必须由Session提供实时位置与停稳状态"
    end
    if ctx.space~="city" then return false,"请先出门，再与委托人物交谈" end
    if ctx.riding or math.abs(ctx.speed)>Config.STOP_SPEED then return false,"请停稳下车后交谈" end
    if Config.DistanceTo(pointId,ctx.x,ctx.z)>Config.INTERACTION_RADIUS then
        return false,"请靠近"..Config.points[pointId].label.."（2米内）"
    end
    return true
end

-- 只验证，不补字段、不改草稿；Store所有落盘/读档路径均应调用此函数。
-- 来源记录/流水/完成状态互相校验，删除实例后不能利用同一稳定奖金键再次领取。
---@param p table
---@return boolean, string?
function Engagements.Validate(p)
    if type(p)~="table" then return false,"生活委托档案无效" end
    local e=p.engagements
    if e==nil then
        for key,enabled in pairs(p.financialKeys or {}) do
            if enabled and type(key)=="string" and key:match("^engagement:v1:") then return false,"委托奖金缺少实例" end
        end
        for _,def in ipairs(definitions) do
            if p.flags and p.flags[flagKey(def)] then return false,"委托状态缺少实例" end
        end
        return true
    end
    if type(e)~="table" or e.version~=1 or type(e.instances)~="table"
        or type(e.credited)~="table" or type(e.letters)~="table"
        or type(p.flags)~="table" or type(p.financialKeys)~="table" or type(p.settledOrders)~="table"
        or type(p.ledger)~="table" or not integer(p.nextOrderSequence,1) or not stamp(p.day,p.time) then
        return false,"生活委托字段或版本无效"
    end
    local expectedCredits,expectedLetters={},{}
    for instanceId,item in pairs(e.instances) do
        local def=byInstance[instanceId]
        if not def or type(item)~="table" or item.instanceId~=instanceId or item.definitionId~=def.id
            or not stamp(item.acceptedDay,item.acceptedTime) or not atOrAfter(p.day,p.time,item.acceptedDay,item.acceptedTime)
            or not integer(item.minOrderSequence,1) or item.minOrderSequence>p.nextOrderSequence
            or type(item.deliveryIds)~="table" or type(item.visits)~="table" or type(item.claimed)~="boolean" then
            return false,"生活委托实例无效"
        end
        if not allDone(prerequisites(p,def)) then return false,"生活委托缺少前置" end
        if count(item.deliveryIds)>deliveryTarget(def) then return false,"生活委托配送数量无效" end
        for orderId,enabled in pairs(item.deliveryIds) do
            local sequence=type(orderId)=="string" and tonumber(orderId:match("^career%-v1%-(%d+)$")) or nil
            local entry=type(orderId)=="string" and ledgerEntry(p,"delivery:"..orderId) or nil
            if enabled~=true or not integer(sequence,1) or orderId~="career-v1-"..string.format("%.0f",sequence)
                or sequence<item.minOrderSequence or sequence>=p.nextOrderSequence
                or p.settledOrders[orderId]~=true or p.financialKeys["delivery:"..orderId]~=true
                or not entry or entry.kind~="delivery" or expectedCredits[orderId]
                or not atOrAfter(entry.day,entry.time,item.acceptedDay,item.acceptedTime) then
                return false,"生活委托亲送来源无效或重复"
            end
            expectedCredits[orderId]=instanceId
        end
        for pointId,enabled in pairs(item.visits) do
            if def.id~="cousin_reply" or (pointId~="park" and pointId~="convenience") or enabled~=true then
                return false,"生活委托访问来源无效"
            end
        end
        if item.claimed then
            local entry=ledgerEntry(p,rewardKey(def))
            local letter=e.letters[instanceId]
            if not stamp(item.claimedDay,item.claimedTime)
                or not atOrAfter(item.claimedDay,item.claimedTime,item.acceptedDay,item.acceptedTime)
                or not atOrAfter(p.day,p.time,item.claimedDay,item.claimedTime)
                or p.flags[flagKey(def)]~=true or p.financialKeys[rewardKey(def)]~=true
                or not entry or entry.kind~="engagement" or entry.deltaCents~=def.rewardCents
                or entry.day~=item.claimedDay or entry.time~=item.claimedTime
                or type(letter)~="table" or letter.id~=instanceId..":letter" or letter.instanceId~=instanceId
                or letter.npcName~=def.npcName or letter.title~=def.letterTitle or letter.text~=def.letterText
                or letter.day~=item.claimedDay or letter.time~=item.claimedTime then
                return false,"生活委托领奖、信件与流水不一致"
            end
            -- 身体/饭钱条件只在交付时判断，后续正常消费/消耗不使已完成存档失效。
            if count(item.deliveryIds)~=deliveryTarget(def)
                or (def.id=="cousin_reply" and not (item.visits.park and item.visits.convenience)) then
                return false,"已交付生活委托缺少成果"
            end
            expectedLetters[instanceId]=true
        elseif item.claimedDay~=nil or item.claimedTime~=nil or p.financialKeys[rewardKey(def)]
            or p.flags[flagKey(def)] or e.letters[instanceId]~=nil then
            return false,"未交付委托不能有奖金或信件"
        end
    end
    for _,def in ipairs(definitions) do
        if not e.instances[def.instanceId] and (p.financialKeys[rewardKey(def)] or p.flags[flagKey(def)]) then
            return false,"生活委托奖励缺少实例"
        end
    end
    for key,enabled in pairs(p.financialKeys) do
        if enabled and type(key)=="string" and key:match("^engagement:v1:") then
            local instanceId=key:match("^(engagement:v1:[%w_]+):reward$")
            if not instanceId or not expectedLetters[instanceId] then return false,"未知生活委托奖金键" end
        end
    end
    for orderId,instanceId in pairs(e.credited) do
        if expectedCredits[orderId]~=instanceId then return false,"生活委托来源去重表不一致" end
    end
    for orderId,instanceId in pairs(expectedCredits) do
        if e.credited[orderId]~=instanceId then return false,"生活委托缺少来源去重键" end
    end
    for instanceId in pairs(e.letters) do
        if not expectedLetters[instanceId] then return false,"生活委托包含未知或未领取信件" end
    end
    return true
end

---@param p table 已由Store验证的档案副本；不传则取Store.Get()
---@return table
function Engagements.State(p)
    p=p or Store.Get()
    local valid,message=Engagements.Validate(p)
    local state={valid=valid,error=message,list={},letters={},completedCount=0}
    if not valid then return state end
    for _,def in ipairs(definitions) do
        local item=instance(p,def.id)
        local row=copy(def)
        row.prerequisites=prerequisites(p,def)
        row.objectives=objectives(p,def,item)
        row.accepted=item~=nil
        row.claimed=item~=nil and item.claimed
        row.canAccept=not row.accepted and allDone(row.prerequisites)
        row.canClaim=item~=nil and not item.claimed and allDone(row.objectives)
        row.status=row.claimed and "claimed" or row.canClaim and "ready" or row.accepted and "active" or row.canAccept and "available" or "locked"
        row.nextPointId=def.acceptPointId
        if row.accepted and not row.claimed then
            row.nextPointId=def.returnPointId
            for _,objective in ipairs(row.objectives) do
                if not objective.done and objective.pointId then row.nextPointId=objective.pointId; break end
            end
        end
        local lines={}
        for _,objective in ipairs(row.objectives) do
            lines[#lines+1]=string.format("%s：%g/%g",objective.text,objective.current,objective.target)
        end
        row.objectives[#row.objectives+1]=condition("return","回"..Config.points[def.returnPointId].label.."当面交付",row.claimed and 1 or 0,1,def.returnPointId)
        row.progressText=row.status=="locked" and def.prerequisiteText or row.claimed and "已当面交付；一次性奖金与信件已保存" or table.concat(lines,"\n")
        if row.canClaim then row.progressText=row.progressText.."\n条件已齐，请回现场交付（手机不能远程领奖）" end
        if row.claimed then
            state.completedCount=state.completedCount+1
            state.letters[#state.letters+1]=copy(p.engagements.letters[def.instanceId])
        end
        state.list[#state.list+1]=row
    end
    return state
end

-- 纯查询给主HUD/手机复用当前人物链；必须传快照，不回退Store.Get、不补实例或领奖。
---@param p CareerProfile
---@return table?
function Engagements.NextGoal(p)
    if not Engagements.Validate(p) then return nil end
    local state=Engagements.State(p)
    for _,row in ipairs(state.list) do
        if not row.claimed and row.status~="locked" then
            local current,target=0,1
            if row.accepted and not row.canClaim then
                for _,objective in ipairs(row.objectives) do
                    if not objective.done then current,target=objective.current,objective.target; break end
                end
            end
            return {id=row.id,title=row.title,detail=row.canAccept and row.objectiveText or row.progressText,
                pointId=row.nextPointId,point=row.nextPointId,current=current,target=target,
                remaining=math.max(0,target-current),action="engagement",stage=row.status,
                instanceId=row.instanceId,rewardCents=row.rewardCents,
                rewardNote="既有人物委托一次谢礼，必须完成条件并到现场交付；查询不发钱"}
        end
    end
    return nil
end

---@param id string Definitions中的id，不能用实例ID接取
---@param ctx CareerEngagementContext 必填；由Session实时生成
---@return boolean, string
function Engagements.Accept(id,ctx)
    local def=byId[id]
    if not def then return false,"委托不存在" end
    local allowed,message=canInteract(def.acceptPointId,ctx)
    if not allowed then return false,message end
    return Store.Transaction(function(p)
        local valid,detail=Engagements.Validate(p)
        if not valid then return false,detail end
        if instance(p,id) then return false,"此固定人物委托已接取，不能重复领取" end
        if not allDone(prerequisites(p,def)) then return false,def.prerequisiteText end
        p.engagements=p.engagements or {version=1,instances={},credited={},letters={}}
        p.engagements.instances[def.instanceId]={instanceId=def.instanceId,definitionId=id,
            acceptedDay=p.day,acceptedTime=p.time,minOrderSequence=p.nextOrderSequence,
            deliveryIds={},visits={},claimed=false}
        local checked,reason=Engagements.Validate(p)
        if not checked then return false,reason end
        print("[Career.Engagements] accepted "..def.instanceId.." orderWatermark="..p.nextOrderSequence)
        return true,"已接取："..def.title.."。"..def.objectiveText
    end)
end

---@param pointId string park 或 convenience
---@param ctx CareerEngagementContext 必填；现场访问不自动住宿/消费/领奖
---@return boolean, string
function Engagements.Visit(pointId,ctx)
    if pointId~="park" and pointId~="convenience" then return false,"这里不是委托访问点" end
    local allowed,message=canInteract(pointId,ctx)
    if not allowed then return false,message end
    return Store.Transaction(function(p)
        local valid,detail=Engagements.Validate(p)
        if not valid then return false,detail end
        local item=instance(p,"cousin_reply")
        if not item or item.claimed then return false,"没有进行中的表哥回信委托" end
        if item.visits[pointId] then return false,"已经记录此次现场访问" end
        item.visits[pointId]=true
        local checked,reason=Engagements.Validate(p)
        if not checked then return false,reason end
        print("[Career.Engagements] visited "..pointId)
        return true,"已记下"..Config.points[pointId].label.."；两处都到过后回桥下回信"
    end)
end

-- 仅供Delivery.Deliver事务内部，绝不调用Store.Get/Transaction/ApplyCash。
-- order必须仍是p.activeOrders内的同一picked_up对象，并且本次手送流水已写入草稿。
-- 无任务/不合条件/已计来源均成功忽略；无效委托档案返回false，由调用者整体回滚。
---@param p table Store事务草稿
---@param order table Delivery本次现场交付的原订单对象
---@return boolean, string?
function Engagements.OnDelivery(p,order)
    local valid,message=Engagements.Validate(p)
    if not valid then return false,message end
    if not p.engagements then return true end
    if type(order)~="table" or order.status~="picked_up" or order.tutorial~=false
        or order.simulated==true or order.late~=false or not finite(order.remainingHours) or order.remainingHours<0
        or not integer(order.sequence,1) or order.id~="career-v1-"..string.format("%.0f",order.sequence) then return true end
    local active=false
    for _,candidate in ipairs(p.activeOrders) do if candidate==order then active=true; break end end
    local template=Config.GetTemplate(order.templateId)
    local entry=ledgerEntry(p,"delivery:"..order.id)
    if not active or not template or template.tutorial or order.pickupId~=template.pickupId or order.dropoffId~=template.dropoffId
        or p.settledOrders[order.id]~=true or p.financialKeys["delivery:"..order.id]~=true
        or not entry or entry.kind~="delivery" or entry.deltaCents~=order.feeCents
        or entry.day~=p.day or entry.time~=p.time or p.engagements.credited[order.id] then return true end
    for _,def in ipairs(definitions) do
        local item=instance(p,def.id)
        if item and not item.claimed and count(item.deliveryIds)<deliveryTarget(def)
            and order.sequence>=item.minOrderSequence and order.sequence<p.nextOrderSequence
            and stamp(order.acceptedDay,order.acceptedTime)
            and atOrAfter(order.acceptedDay,order.acceptedTime,item.acceptedDay,item.acceptedTime)
            and ((def.id=="breakfast_shift" and order.pickupId=="breakfast")
                or (def.id=="mechanic_balance" and ownsMotorcycle(p) and trained(p))) then
            item.deliveryIds[order.id]=true
            p.engagements.credited[order.id]=def.instanceId
            print("[Career.Engagements] credited "..order.id.." -> "..def.instanceId)
            return Engagements.Validate(p)
        end
    end
    return true
end

---@param instanceId string State(p).list[].instanceId；不是任务id
---@param ctx CareerEngagementContext 必填，由Session现场再次验证而非手机缓存
---@return boolean, string
function Engagements.Claim(instanceId,ctx)
    local def=byInstance[instanceId]
    if not def then return false,"委托实例不存在" end
    local allowed,message=canInteract(def.returnPointId,ctx)
    if not allowed then return false,message end
    return Store.Transaction(function(p)
        local valid,detail=Engagements.Validate(p)
        if not valid then return false,detail end
        local item=instance(p,def.id)
        if not item then return false,"尚未接取此人物委托" end
        if item.claimed or p.financialKeys[rewardKey(def)] then return false,"此委托已交付，奖金和信件只发一次" end
        if not allDone(objectives(p,def,item)) then return false,"委托条件尚未完成，请查看每项目标与进度" end
        local paid,reason=Store.ApplyCash(p,def.rewardCents,"engagement",rewardKey(def))
        if not paid then return false,reason end
        item.claimed=true; item.claimedDay=p.day; item.claimedTime=p.time
        p.flags[flagKey(def)]=true
        p.engagements.letters[instanceId]={id=instanceId..":letter",instanceId=instanceId,npcName=def.npcName,
            title=def.letterTitle,text=def.letterText,day=p.day,time=p.time}
        local checked,why=Engagements.Validate(p)
        if not checked then return false,why end
        print("[Career.Engagements] claimed "..instanceId.." rewardCents="..def.rewardCents)
        return true,string.format("已向%s交付；一次性谢礼%.2f元，收到《%s》",def.npcName,def.rewardCents/100,def.letterTitle)
    end)
end

return Engagements
