-- 现场委托、车队签约协调；手机只提交ID，实时位置来自当前角色。
local Store=require("Career.Store")
local Events=require("Career.Engagements")
local Team=require("Career.Team")
---@class CareerEngagementActions: CareerSession
local Actions={}
---@return CareerEngagementContext
function Actions:InteractionContext()
    local a=assert(self.actor)
    return {x=a.x,z=a.z,speed=a.speed,riding=a.mounted,space=self.space}
end
function Actions:AcceptEngagement(id)
    local definition
    for _,item in ipairs(Events.Definitions) do if item.id==id then definition=item end end
    if not definition then self.view:Notice("委托不存在"); return end
    local allowed,message=self:Allowed(definition.acceptPointId)
    if not allowed then self.waypoint=definition.acceptPointId; self.view:Notice(message); self:Refresh(); return end
    self.view:ShowDialog(definition.npcName.." · "..definition.title,definition.description.."\n"..definition.objectiveText,{
        {text="稍后再来"},
        {text="接受现场委托",primary=true,onClick=function()
            local _,detail=Events.Accept(id,self:InteractionContext())
            self.view:Notice(detail); self:RefreshPhone()
        end}})
end
function Actions:ClaimEngagement(instanceId)
    local state=Events.State(Store.Get())
    for _,item in ipairs(state.list) do
        if item.instanceId==instanceId then
            local allowed,message=self:Allowed(item.returnPointId)
            if not allowed then self.waypoint=item.returnPointId; self.view:Notice(message); self:Refresh(); return end
            local _,detail=Events.Claim(instanceId,self:InteractionContext())
            self.view:Notice(detail); self:RefreshPhone(); return
        end
    end
    self.view:Notice("委托已变更，请刷新手机")
end
function Actions:VisitEngagement(pointId)
    local allowed,message=self:Allowed(pointId)
    if not allowed then self.waypoint=pointId; self.view:Notice(message); return end
    local _,detail=Events.Visit(pointId,self:InteractionContext())
    self.view:Notice(detail); self:RefreshPhone()
end
function Actions:SignTeam(id)
    local allowed,message=self:Allowed("dealer")
    if not allowed then self.waypoint="dealer"; self.view:Notice(message); return end
    self.view:ShowDialog("正式车队合同","签约后，从新报名的正式赛事开始履约。训练、旧报名、未完赛不能替代完赛目标；每轮需回车行领取赞助，重复领取无效。",{
        {text="暂不签约"},
        {text="确认签约",primary=true,onClick=function()
            local present,reason=self:Allowed("dealer")
            if not present then self.view:Notice(reason); return end
            local located,problem=Store.SetPosition(self:PositionSnapshot())
            if not located then self.view:Notice(problem); return end
            local _,detail=Team.Sign(id); self.view:Notice(detail); self:RefreshPhone()
        end}})
end
function Actions:ClaimTeam()
    self:Service("dealer",function()
        local ok,message=Store.SetPosition(self:PositionSnapshot())
        if not ok then return false,message end
        return Team.Claim()
    end)
end
function Actions.Install(target)
    for name,method in pairs(Actions) do if name~="Install" then target[name]=method end end
end
return Actions
