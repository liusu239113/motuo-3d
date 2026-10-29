-- 住房交互协调：进出先保存事务，失败不换场；人物进入，电动车留在城市。
local Store=require("Career.Store")
local Data=require("Career.HousingData")
local Progress=require("Career.Progression")
---@class CareerHousingActions
---@field actor CareerActor
---@field city CareerCity
---@field view CareerView
---@field space string
---@field cityX number
---@field cityZ number
---@field cityYaw number
---@field yaw number
---@field pitch number
---@field waypoint string
---@field sun Light?
---@field moon Light?
---@field sky ProceduralSky?
---@field Refresh fun(self:CareerHousingActions)
---@field RefreshPhone fun(self:CareerHousingActions)
---@field Allowed fun(self:CareerHousingActions,id:string):boolean,string?
---@field Service fun(self:CareerHousingActions,id:string,callback:function)
---@field UpdateEnvironment fun(self:CareerHousingActions,hour:number)
local Actions={}
function Actions:PositionSnapshot()
    local a=assert(self.actor)
    return {x=a.x,z=a.z,yaw=a.yaw,mounted=a.mounted,bikeX=a.bikeX,bikeZ=a.bikeZ,bikeYaw=a.bikeYaw,
        space=self.space,cityX=self.cityX,cityZ=self.cityZ,cityYaw=self.cityYaw,
        activeVehicle=a.vehicleId,vehicleParking=a:ParkingSnapshot(),groundHeight=a.walkHeight}
end
function Actions:ApplySpace(space)
    self.space=space
    local city=self.city
    city:SetSpace(space)
    city:UpdateLights(Store.Get().time)
    self.actor.visuals:SetCityVisible(space=="city")
    self.actor.visuals:SetMounted(self.actor.mounted)
    if self.sun then self.sun.enabled=space=="city" end
    if self.moon then self.moon.enabled=space=="city" end
    if self.sky then self.sky.enabled=space=="city" end
end
function Actions:ChooseHousing(id)
    local _,message=Progress.SetHousing(id)
    self.view:Notice(message); self:RefreshPhone()
end
function Actions:EnterHousing(id)
    local home=Data.Get(id)
    if not home or not home.width or not self.actor or self.space~="city" then return false end
    local allowed,message=self:Allowed(home.point)
    if not allowed then self.waypoint=home.point; self.view:Notice(message); return false end
    local state=Store.Get()
    if state.accommodation~=id then
        self.view:ShowDialog(home.name,string.format("每晚%.2f元，选择和进门不收费。到床边确认休息才支付今晚房费。\n电动车会停在原处。",home.price/100),{
            {text="暂不入住"},{text="选择此住处",primary=true,onClick=function() self:ChooseHousing(id) end}})
        return false
    end
    local pos=self:PositionSnapshot()
    local sx,sz=Data.Spawn(id)
    pos.cityX,pos.cityZ,pos.cityYaw=pos.x,pos.z,pos.yaw
    pos.space=id; pos.x,pos.z,pos.yaw=sx,sz,0
    local ok,detail=Store.Transaction(function(p) p.position=pos; return true,"已进入"..home.name end)
    if not ok then self.view:Notice(detail); return false end
    self.cityX,self.cityZ,self.cityYaw=pos.cityX,pos.cityZ,pos.cityYaw
    self:ApplySpace(id)
    self.actor:Teleport(sx,sz,0); self.yaw,self.pitch=0,12
    self.view:ClosePhone(); self.view:ResetInput(); self:Refresh()
    self.view:Notice(detail.."，走到床边休息；门边可以离开")
    print("[生涯住房] 进屋 "..id.."，停车保留，未扣房费")
    return true
end
function Actions:LeaveHousing()
    if self.space=="city" or not self.actor then return false end
    local home=assert(Data.Get(self.space))
    local ex,ez=Data.Exit(self.space)
    if (self.actor.x-ex)^2+(self.actor.z-ez)^2>4 then self.view:Notice("请走到房门旁，再点击出门"); return false end
    local pos=self:PositionSnapshot()
    pos.space="city"; pos.x,pos.z,pos.yaw=pos.cityX or home.x,pos.cityZ or home.z,pos.cityYaw or 0
    local ok,message=Store.Transaction(function(p) p.position=pos; return true,"已回到城市，电动车仍在停车处" end)
    if not ok then self.view:Notice(message); return false end
    self:ApplySpace("city")
    local x,z=self.city:FindFree(pos.x,pos.z,.32)
    assert(z,"城市入口缺少Z坐标")
    self.actor:Teleport(x,z,pos.yaw); self.yaw=pos.yaw
    local stream=self.city.stream --[[@as CareerWorldStream]]
    stream:Ensure(x,z,550)
    self.view:ClosePhone(); self.view:ResetInput(); self:Refresh(); self.view:Notice(message)
    print("[生涯住房] 出门，停车坐标未改变")
    return true
end
function Actions:SleepHousing()
    local home=assert(Data.Get(Store.Get().accommodation))
    if not home.width then self:Service(home.point,function() return Store.Rest(home.id) end); return end
    if self.space~=home.id then
        self.waypoint=home.point; self.view:Notice("请前往"..home.name.."，进门后走到床边休息"); self:Refresh(); return
    end
    local bx,bz=Data.Bed(home.id)
    if (self.actor.x-bx)^2+(self.actor.z-bz)^2>2.25 or math.abs(self.actor.speed)>.35 then
        self.view:Notice("请停在床边1.5米内，再点击休息"); return
    end
    if #Store.Get().activeOrders>0 then self.view:Notice("请先完成手头配送，不能带单过夜"); return end
    self.view:ShowDialog("今晚住在"..home.name,string.format("确认支付%.2f元住宿费，休息至次日08:00？\n每次确认只结算一晚，不是永久买断。",home.price/100),{
        {text="先不睡"},{text="支付并休息",primary=true,onClick=function()
            local pos=self:PositionSnapshot()
            local located,reason=Store.SetPosition(pos)
            if not located then self.view:Notice(reason); return end
            local ok,message=Store.Rest(home.id)
            if not ok then self.view:Notice(message); return end
            self.view:ClosePhone(); self:UpdateEnvironment(Store.Get().time); self:Refresh()
            self:ShowMorning(message)
        end}})
end
function Actions:ShowMorning(message)
    local p=Store.Get()
    self.view:ShowDialog("第"..p.day.."天 · 又是新的一天",(message or "")..string.format("\n昨天收入%.2f元，支出%.2f元。\n现有现金%.2f元。",(p.lastDaySummary.incomeCents or 0)/100,
        (p.lastDaySummary.expenseCents or 0)/100,p.cashCents/100),{{text="收拾好，继续生活",primary=true}})
end
function Actions:InteriorTarget()
    local bx,bz=Data.Bed(self.space)
    local ex,ez=Data.Exit(self.space)
    local a=self.actor
    local bedDistance=math.sqrt((a.x-bx)^2+(a.z-bz)^2)
    local exitDistance=math.sqrt((a.x-ex)^2+(a.z-ez)^2)
    local bed=bedDistance<=exitDistance
    return {name=bed and "床边 · 休息" or "房门 · 出门",x=bed and bx or ex,z=bed and bz or ez,
        distance=bed and bedDistance or exitDistance,kind="interior",hint="走到床边休息，或到房门旁出门；电动车留在室外"}
end
function Actions:InteractHousing()
    local target=self:InteriorTarget()
    if target.name=="床边 · 休息" then self:SleepHousing() else self:LeaveHousing() end
end
function Actions.Install(target)
    for name,method in pairs(Actions) do if name~="Install" then target[name]=method end end
end
return Actions
