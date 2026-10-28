-- 生涯协调器：单一Update入口、独立场景、独立存档，不改旧竞速模拟器。
local UI = require("urhox-libs/UI")
require "urhox-libs.Camera.ThirdPersonCamera"
local Store = require("Career.Store")
local Delivery = require("Career.Delivery")
local Config = require("Career.Config")
local Actor = require("Career.Actor")
local City = require("Career.City")
local View = require("Career.View")
local Loader = require("RideLoader")
local Theme = require("RacingTheme")
local Progress = require("Career.Progression")

-- 所有模式切换都由主入口显式持有，避免场景被GC提前回收。
---@class CareerSession
local Session={}
Session.__index=Session
function Session.New(options)
    local self=setmetatable({},Session)
    self:Init(options or {})
    return self
end
function Session:Init(options)
    self.options=options
    self.running,self.loading,self.online,self.disposed=false,false,false,false
    self.yaw,self.pitch,self.timer=0,14,0
    self.waypoint=""
    ---@type Scene?
    self.scene=nil
    ---@type CareerActor?
    self.actor=nil
    ---@type CareerCity?
    self.city=nil
    ---@type ThirdPersonCameraInstance?
    self.camera=nil
    ---@type RideLoader?
    self.loader=nil
    ---@type thread?
    self.building=nil
    self.view=View.New({
        startCareer=function(fresh) self:StartCareer(fresh) end,
        legacy=function() self:LeaveForLegacy() end,
        pause=function() self:Pause() end,
        phone=function(page) self:OpenPhone(page) end,
        closePhone=function() self.view:ClosePhone() end,
        online=function(value) self.online=value; self:RefreshPhone() end,
        accept=function() self:Accept() end,
        selectOrder=function(id)
            local _,message=Store.Transaction(function(p)
                for index,order in ipairs(p.activeOrders) do
                    if order.id==id then table.remove(p.activeOrders,index); table.insert(p.activeOrders,1,order); return true end
                end
                return false,"订单不存在"
            end)
            self.view:Notice(message); self:RefreshPhone()
        end,
        mount=function() if self.actor then local _,message=self.actor:ToggleMount(); self.view:Notice(message); self:SavePosition() end end,
        interact=function() self:Interact() end,
        setWaypoint=function(id) self.waypoint=id; self:Refresh() end,
        eat=function() self:Service("breakfast",function() return Store.Eat() end) end,
        rest=function(id) self:Service(id,function() return Store.Rest(id) end) end,
        charge=function() self:Service("charge",function() return Store.Charge() end) end,
        aid=function() self:Service("breakfast",function() return Store.RequestAid() end) end,
        save=function() self:SaveCloud() end,
        progression=function() self:OpenPhone("progression") end,
        buyEquipment=function(id) self:Service("dealer",function() return Progress.BuyEquipment(id) end) end,
        housing=function(id) self:Service("dealer",function() return Progress.SetHousing(id) end) end,
        sleepHousing=function() local p=Store.Get(); self:Service("home_old",function() return Store.Rest(p.accommodation) end) end,
        workWeek=function() self:WorkWeek() end,
        buyMotorcycle=function(id) self:Service("dealer",function() return Progress.BuyMotorcycle(id) end) end,
        train=function() self:Service("dealer",function() return Progress.Train() end) end,
        race=function(index) self:EnterRace(index) end,
        loadCloud=function() self:LoadCloud() end,
        saveStatus=function() local status=Store.GetSaveStatus(); return "账号云档状态："..status.cloud.."。网页版刷新前请等待confirmed。" end,
    })
    self:Home()
end
function Session:Home(message)
    self.running=false; self.online=false
    self.view:ShowHome(Store.HasSave(),message)
    UI.SetRoot(self.view.root)
end
function Session:StartCareer(fresh,confirmed)
    if self.loading then return end
    if fresh and Store.HasSave() and not confirmed then
        self.view:ShowDialog("重新开始？","这会替换当前王二狗生涯。旧竞速档不受影响。",{
            {text="保留当前生涯",onClick=function() self:Home() end},
            {text="确认重开 · 从50元开始",primary=true,onClick=function() self:StartCareer(true,true) end}})
        return
    end
    local ok,message
    if fresh then ok,message=Store.NewCareer() else ok,message=Store.Load() end
    if not ok then self.view:ShowDialog("未进入生涯",message,{{text="返回主页",onClick=function() self:Home() end}}); return end
    if self.actor then self:DisposeWorld() end
    self.loading=true
    self.view.home:SetVisible(false)
    self.view:ShowLoading("准备南城老街","正在校验城市、人物、车辆和材质。",0)
    local resources,types={},{}
    for _,module in ipairs({City,Actor}) do
        for _,path in ipairs(module.Resources) do resources[#resources+1]=path; types[path]=module.ResourceTypes[path] end
    end
    self.loader=Loader.New({},function(title,detail,fraction) self.view:ShowLoading(title,detail,fraction) end,
        function() self.building=coroutine.create(function() self:BuildWorld() end) end,
        function(detail) self.loading=false; self.view:ShowDialog("资源未准备好",detail,{{text="返回主页",onClick=function() self:Home() end}}) end,
        resources,types)
    self.loader:Start()
end
function Session:BuildWorld()
    self.scene=Scene()
    self.scene:CreateComponent("Octree")
    local lg=self.scene:CreateChild("LightGroup")
    assert(lg:LoadXML(cache:GetResource("XMLFile","LightGroup/Daytime.xml"):GetRoot()))
    local zone=lg:GetComponent("Zone",true)
    zone.boundingBox=BoundingBox(Vector3(-1000,-1000,-1000),Vector3(1000,1000,1000))
    zone.depthFogStart,zone.depthFogEnd=150,450
    zone.fogColor=Color(.6,.68,.72)
    local light=lg:GetComponent("Light",true)
    light.castShadows=true; light.shadowCascade=CascadeParameters(18,80,0,0,.8)
    light.shadowBias=BiasParameters(.0003,.6)
    self.view:ShowLoading("建设南城老街","道路、住宅、写字楼和生活地点。",.3)
    coroutine.yield()
    self.city=City.New(self.scene)
    self.view:ShowLoading("装配人物与车辆","独立停车位置与配送箱挂点。",.8)
    coroutine.yield()
    self.actor=Actor.New(self.scene,self.city)
    self:RestorePosition()
    self.camera=ThirdPersonCamera.Create(self.scene,{
        modes={normal={distance=5.8,offset=Vector3(0,1.35,0),fov=55},ride={distance=6.4,offset=Vector3(0,1.3,0),fov=60}},
        transitionSpeed=8,farClip=450})
    renderer:SetNumViewports(1)
    renderer:SetViewport(0,Viewport:new(self.scene,self.camera:GetCamera()))
    renderer.dynamicInstancing=true; renderer:SetShadowMapSize(1024)
    self.camera:Update(1,self.actor.node,self.yaw,self.pitch)
    self.loading,self.running=false,true
    self.view:ShowGame()
    self:Refresh()
    if Store.Get().phase=="opening" then self:Intro() end
    if self.options.test then
        require("Career.Checks").RunWorld(self)
    end
    print("[生涯] 场景与主流程已接通")
end
function Session:Intro()
    self.view:ShowDialog("第一章 · 兜里还剩50块","王二狗，工作没了，房租也续不起。\n表哥把一串旧钥匙塞进你手里：\n“这辆战损9号以前追对象留下的。车还能跑，外卖箱给你装好了。先吃上饭，再想别的。”\n今晚能睡的地方，是桥洞和公园长椅。",{
        {text="接过钥匙 · 先把生活跑顺",primary=true,onClick=function()
            local ok,message=Store.Transaction(function(p) p.phase="working"; p.flags.introSeen=true; return true end)
            if not ok then self.view:Notice(message) end
            self:OpenPhone("messages")
        end}})
end
function Session:State()
    local state=Store.Get(); state.online=self.online; return state
end
function Session:Target()
    if not self.actor then return nil end
    local order=Delivery.GetActive()
    local id=self.waypoint
    if order then id=order.status=="accepted" and order.pickupId or order.dropoffId end
    local point=Config.points[id]
    if not point then return nil end
    return {name=point.label,x=point.x,z=point.z,pointId=point.id,kind=point.kind,
        distance=Config.DistanceTo(id,self.actor.x,self.actor.z),
        hint=order and (order.status=="accepted" and "停车下车，靠近店门按E取餐" or "停车下车，靠近门厅按E交付") or "到点后停车下车，按E交互"}
end
function Session:Refresh()
    if not self.actor then return end
    self.view:Update(self:State(),self.actor,self:Target(),Delivery.GetActive(),Delivery.GetOffer(),.2)
end
function Session:RefreshPhone()
    if self.view.phonePage~="" then self.view:BuildPhone(self:State(),Delivery.GetOffer(),Delivery.GetActive()) end
    self:Refresh()
end
function Session:OpenPhone(page)
    if not self.running or not self.actor then return end
    if math.abs(self.actor.speed)>.35 then self.view:Notice("请先停车，再打开手机"); return end
    self.view:OpenPhone(page,self:State(),Delivery.GetOffer(),Delivery.GetActive())
end
function Session:Accept()
    if not self.online then self.view:Notice("先上线听单"); return end
    self:SavePosition()
    local _,message=Delivery.Accept()
    self.view:Notice(message); self:RefreshPhone()
end
function Session:Allowed(id)
    if not self.actor then return false,"尚未进入城市" end
    if self.actor.mounted or math.abs(self.actor.speed)>.35 then return false,"请停稳下车后交互" end
    if Config.DistanceTo(id,self.actor.x,self.actor.z)>Config.INTERACTION_RADIUS then return false,"请先前往"..Config.points[id].label.."（2米内）" end
    return true
end
function Session:Service(id,callback)
    local allowed,message=self:Allowed(id)
    if not allowed then self.waypoint=id; self.view:Notice(message); self:Refresh(); return end
    self:SavePosition()
    local ok,detail=callback()
    self.view:Notice(detail)
    self:RefreshPhone()
    if ok and (id=="bridge" or id=="park") then
        self.view:ClosePhone()
        local state=Store.Get()
        self.view:ShowDialog("第"..state.day.."天 · 又是新的一天",string.format("昨天收入 %.2f元，支出 %.2f元。\n现在现金 %.2f元。休息好了，今天继续。",
            (state.lastDaySummary.incomeCents or 0)/100,(state.lastDaySummary.expenseCents or 0)/100,state.cashCents/100),{{text="出发",primary=true}})
    end
end
function Session:Interact()
    if not self.actor then return end
    local order=Delivery.GetActive()
    if order then
        self:SavePosition()
        local context={riding=self.actor.mounted,speed=self.actor.speed}
        local ok,message
        if order.status=="accepted" then ok,message=Delivery.Pickup(order.id,self.actor.x,self.actor.z,context)
        else ok,message=Delivery.Deliver(order.id,self.actor.x,self.actor.z,context) end
        self.view:Notice(message); self:RefreshPhone()
        if ok and not Delivery.GetActive() then self.waypoint="breakfast" end
        return
    end
    local nearest,dist="",math.huge
    for _,p in ipairs(Config.pointList) do
        local d=Config.DistanceTo(p.id,self.actor.x,self.actor.z)
        if d<dist then nearest,dist=p.id,d end
    end
    if dist>2 then self.view:Notice("靠近商家、门厅、充电点或住处，再按E"); return end
    if nearest=="breakfast" then self:OpenPhone("life")
    elseif nearest=="bridge" or nearest=="park" then self:Service(nearest,function() return Store.Rest(nearest) end)
    elseif nearest=="charge" then self:Service(nearest,function() return Store.Charge() end)
    elseif nearest=="dealer" then self:OpenPhone("progression")
    else self.view:Notice("这里没有待交付外卖") end
end
function Session:WorkWeek()
    if not self.actor or self.actor.mounted or math.abs(self.actor.speed)>.35 then self.view:Notice("请下车停稳后安排工作"); return end
    self.view:ShowDialog("确认推进7个游戏日？","第10天起，每周需新的10份亲送及15分钟活动。\n模拟订单均价5.80～6.20元，扣除餐食、整备和7晚住宿。亲送收入不重复结算。",{
        {text="继续亲自跑单"},
        {text="确认7天排班",primary=true,onClick=function()
            self:SavePosition(); local _,message=Progress.WorkWeek(); self.view:Notice(message); self:RefreshPhone()
        end}})
end
function Session:EnterRace(index)
    local allowed,message=self:Allowed("dealer")
    if not allowed then self.waypoint="dealer"; self.view:Notice(message); return end
    local p=Store.Get()
    if not (p.career and p.career.pending) then
        local ok,detail=Progress.EnterSeries(index)
        if not ok then self.view:Notice(detail); return end
    end
    local pending=Store.Get().career.pending
    if self.options.race then
        self:SavePosition()
        local saved,detail=Store.Save()
        if not saved then self.view:Notice(detail); return end
        self.view:ClosePhone(); self:DisposeWorld()
        self.options.race(pending)
    end
end
function Session:SavePosition()
    if not self.actor then return end
    local a=self.actor
    Store.SetPosition{x=a.x,z=a.z,yaw=a.yaw,mounted=a.mounted,bikeX=a.bikeX,bikeZ=a.bikeZ,bikeYaw=a.bikeYaw}
end
function Session:RestorePosition()
    if not self.actor then return end
    local p=Store.Get().position
    local a=self.actor
    a.bikeX,a.bikeZ,a.bikeYaw=p.bikeX,p.bikeZ,p.bikeYaw
    a.mounted=p.mounted; a.visuals:SetMounted(p.mounted)
    a:Teleport(p.x,p.z,p.yaw); self.yaw=p.yaw
end
function Session:SaveCloud()
    self:SavePosition()
    local _,message=Store.SaveCloud(function(_,detail) if not self.disposed then self.view:Notice(detail); self:RefreshPhone() end end)
    self.view:Notice(message)
end
function Session:LoadCloud()
    self.view:ShowDialog("读取账号云档？","云端进度将替换当前本地生涯。请确认云端是你想继续的进度。",{
        {text="取消",onClick=function() self:RefreshPhone() end},
        {text="确认读取云档",primary=true,onClick=function()
            local _,message=Store.LoadCloud(function(ok,detail)
                if self.disposed then return end
                if ok then self:RestorePosition() end
                self.view:Notice(detail); self:RefreshPhone()
            end)
            self.view:Notice(message)
        end}})
end
function Session:Pause()
    if not self.running then return end
    self:SavePosition()
    local _,message=Store.Save()
    self.view:ShowDialog("暂时歇一歇",message.."\n完整手机与暂停期间不推进时间和订单。",{
        {text="继续生活",primary=true},
        {text="保存到账号云端",onClick=function() self:SaveCloud() end},
        {text="回到生涯主页",onClick=function() self:DisposeWorld(); self:Home() end}})
end
function Session:Update(dt)
    if self.disposed then return end
    if self.loading then
        if self.building then
            local ok,message=coroutine.resume(self.building)
            if not ok then
                self.building=nil; self.loading=false; self:DisposeWorld()
                self.view:ShowDialog("城市准备失败",tostring(message),{{text="返回主页",onClick=function() self:Home() end}})
                print("[生涯错误] "..tostring(message))
                if self.options.test then error(message) end
            elseif coroutine.status(self.building)=="dead" then self.building=nil end
        elseif self.loader then self.loader:Update() end
        return
    end
    if not self.running or not self.actor then return end
    if input:GetKeyPress(KEY_ESCAPE) then
        if self.view.phonePage~="" then self.view:ClosePhone()
        elseif not self.view:IsBlocking() then self:Pause() end
        return
    end
    if self.view:IsBlocking() then return end
    if input:GetKeyPress(KEY_TAB) then self:OpenPhone("apps"); return end
    if input:GetKeyPress(KEY_P) then self:Pause(); return end
    if input:GetKeyPress(KEY_F) then self.view.actions.mount(); return end
    if input:GetKeyPress(KEY_E) then self:Interact(); return end
    if input:GetMouseButtonDown(MOUSEB_RIGHT) then
        self.yaw=self.yaw+input.mouseMoveX*.18
        self.pitch=math.max(-15,math.min(65,self.pitch+input.mouseMoveY*.15))
    elseif self.actor.mounted then
        self.yaw=self.yaw+((self.actor.yaw-self.yaw+180)%360-180)*math.min(1,dt*2.5)
    end
    local x,z=self.actor.x,self.actor.z
    local controls=self.view:GetInput()
    local state=Store.Get()
    if self.actor.mounted and state.battery<=0 then controls.throttle=0; controls.brake=true end
    self.actor:Update(dt,controls,self.yaw)
    local distance=self.actor.mounted and math.sqrt((self.actor.x-x)^2+(self.actor.z-z)^2) or 0
    self:SavePosition()
    local ok,message=Delivery.Update(dt,distance)
    if not ok and message~="存档忙" then self.view:Notice(message) end
    self.timer=self.timer+dt
    if self.timer>=.2 then self.timer=0; self:Refresh() end
end
function Session:PostUpdate(dt)
    if not self.camera or not self.actor then return end
    self.camera:SetMode(self.actor.mounted and "ride" or "normal")
    self.camera:Update(dt,self.actor.node,self.yaw,self.pitch)
end
function Session:LeaveForLegacy()
    if self.running then self:SavePosition(); Store.Save() end
    self:DisposeWorld()
    if self.options.legacy then self.options.legacy() end
end
function Session:DisposeWorld()
    self.running,self.loading=false,false
    if self.loader then self.loader:Cancel(); self.loader=nil end
    self.building=nil
    renderer:SetNumViewports(0)
    if self.actor then self.actor:Dispose(); self.actor=nil end
    if self.scene then self.scene:Dispose(); self.scene=nil end
    self.city,self.camera=nil,nil
end
function Session:Dispose()
    if self.disposed then return end
    if self.running then self:SavePosition(); Store.Save() end
    self.disposed=true; self:DisposeWorld(); self.view:Dispose()
end
return Session
