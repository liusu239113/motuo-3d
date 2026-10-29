-- 现场交谈只协调既有服务/委托，不复制金额结算，不写新存档字段。
local Config=require("Career.Config")
local Store=require("Career.Store")
local Events=require("Career.Engagements")
---@class CareerStreetActions: CareerSession
local Actions={}
local function canTalk(self,person)
    local actor=self.actor
    if not actor or not self.running or self.space~="city" then return false,"请先回到街上" end
    if actor.mounted or math.abs(actor.speed)>.35 then return false,"请停稳下车再交谈" end
    if actor.walkHeight>1 then return false,"请先回到地面" end
    if (actor.x-person.x)^2+(actor.z-person.z)^2>9 then return false,"请靠近正在交谈的人（3米内）" end
    return true
end
local function speech(id,state)
    if id=="station" then
        return state.flags.tutorialCompleted and "路熟了也别赶。餐拿稳，车停好再上楼。今天想接着跑，还是找我聊聊站里的事？"
            or "二狗，先别慌。手机上线就能接第一单；接到以后到这儿来，我带你核对餐袋。停车、下车，再拿餐。"
    elseif id=="breakfast_owner" then
        return "热的都装好了，豆浆袋别压着。想吃饭就在这儿吃，送餐的单子咱一份份核对。"
    elseif id=="cousin" then
        return state.flags.tutorialCompleted and "第一单跑下来了吧？挣得不多也是自己挣的。车有电就能接着跑，晚上累了就先歇。"
            or "钥匙和保温箱都给你了。这辆9号磕碰多，但能陪你起步。别空着肚子硬撑，先把今天过好。"
    elseif id=="breakfast_waiting" then
        return "今天这锅包子刚出笼。我等两袋带回去，你送餐别着急，袋子扎紧就不容易洒。"
    elseif id=="bridge_chat_a" or id=="bridge_chat_b" then
        return "刚跟街坊聊到你呢。天热就来桥下歇口气，水喝够了再赶路，挣生活也得顾着自己。"
    elseif id=="phone_neighbor" then
        return "在等家里回消息呢。这条街绕几回就熟了，找不到门牌的时候，停下来问一句比乱跑强。"
    end
    return "车跟人一样，先养顺了再拼速度。送餐攒钱、练车、下场比赛，都得一步一步来。"
end
function Actions:TalkTo(id)
    if not self.city or not self.actor then return false end
    local person=self.city.contacts:Get(id)
    if not person then self.view:Notice("这位联系人暂时不在这里"); return false end
    local allowed,message=canTalk(self,person)
    if not allowed then self.view:Notice(message); return false end
    self.city.contacts:Respond(id,"talk")
    local function present(action)
        return function()
            -- 对话打开后再次校验现场，不能携带旧坐标远程吃饭/接受委托。
            local valid,reason=canTalk(self,person)
            if not valid then self.view:Notice(reason); return end
            action()
        end
    end
    local choices={}
    local resident=id=="breakfast_waiting" or id=="bridge_chat_a" or id=="bridge_chat_b" or id=="phone_neighbor"
    local state=Store.Get()
    local eventState=Events.State(state)
    for _,item in ipairs(resident and {} or eventState.list) do
        if item.acceptPointId==person.point and item.status=="available" then
            local eventId=item.id
            choices[#choices+1]={id="engagement",text="问问有什么事需要帮忙",primary=true,
                onClick=present(function() self:AcceptEngagement(eventId) end)}
            break
        elseif item.returnPointId==person.point and item.status=="ready" then
            local instance=item.instanceId
            choices[#choices+1]={id="engagement",text="说说上次托付的事",primary=true,
                onClick=present(function() self:ClaimEngagement(instance) end)}
            break
        end
    end
    if not resident and person.point=="breakfast" then
        choices[#choices+1]={id="meal",text="先吃顿饭 · 12元",onClick=present(function()
            self:Service("breakfast",function() return Store.Eat() end)
        end)}
        choices[#choices+1]={id="orders",text="打开外卖App接着跑",primary=#choices==0,
            onClick=present(function() self:OpenPhone("delivery") end)}
    elseif not resident and person.point=="bridge" then
        choices[#choices+1]={id="rest",text="在桥下歇一晚",onClick=present(function()
            self:Service("bridge",function() return Store.Rest("bridge") end)
        end)}
        choices[#choices+1]={id="letters",text="看看表哥留下的消息",onClick=present(function() self:OpenPhone("messages") end)}
    elseif not resident then
        choices[#choices+1]={id="career",text="聊聊车和比赛",onClick=present(function() self:OpenPhone("progression") end)}
    end
    choices[#choices+1]={id="leave",text="先忙着，我再转转"}
    self.view:ShowConversation(person.name,speech(id,state),choices)
    print("[街头交谈] "..id.." / "..person.point.." / 现场重检 / 不自动收费")
    return true
end
function Actions:DeliveryResponse(pointId,pickup)
    if not self.city or not self.actor then return end
    if pointId=="breakfast" then
        self.city.contacts:Respond("breakfast_owner","handover")
        self.view:Say("早餐店老板",pickup and "单号对上了。热餐拿好，袋口我给你扎紧了。" or "辛苦了，路上慢点。")
    elseif pickup then
        self.view:Say(Config.points[pointId].label,"餐已经核对好了，拿稳再走。")
    else
        self.view:Say("收餐人","收到了，谢谢你跑这一趟。")
    end
end
function Actions.Install(target)
    for name,method in pairs(Actions) do if name~="Install" then target[name]=method end end
end
return Actions
