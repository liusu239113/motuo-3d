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
local Housing = require("Career.HousingData")
local Vehicles = require("Career.VehicleData")
local VehicleActions = require("Career.VehicleActions")
local CareerAudio = require("Career.Audio")
local Traffic = require("Career.Traffic")
local World = require("Career.WorldData")
local Engagements = require("Career.Engagements")
local Team = require("Career.Team")
local DeliveryPeople = require("Career.DeliveryPeople")
local DeliveryMarkers = require("Career.DeliveryMarkers")

-- 所有模式切换都由主入口显式持有，避免场景被GC提前回收。
---@class CareerSession
---@field deliveryPeople? CareerDeliveryPeople
---@field deliveryMarkers? CareerDeliveryMarkers
---@field PositionSnapshot fun(self:CareerSession):CareerPosition
---@field ApplySpace fun(self:CareerSession,space:string)
---@field ChooseHousing fun(self:CareerSession,id:string)
---@field EnterHousing fun(self:CareerSession,id:string):boolean
---@field LeaveHousing fun(self:CareerSession):boolean
---@field SleepHousing fun(self:CareerSession)
---@field ShowMorning fun(self:CareerSession,message:string)
---@field InteriorTarget fun(self:CareerSession):table
---@field InteractHousing fun(self:CareerSession)
---@field InteractionContext fun(self:CareerSession):CareerEngagementContext
---@field AcceptEngagement fun(self:CareerSession,id:string)
---@field ClaimEngagement fun(self:CareerSession,id:string)
---@field VisitEngagement fun(self:CareerSession,id:string)
---@field SignTeam fun(self:CareerSession,id:string)
---@field ClaimTeam fun(self:CareerSession)
---@field TalkTo fun(self:CareerSession,id:string):boolean
---@field DeliveryResponse fun(self:CareerSession,pointId:string,pickup:boolean)
local Session={}
Session.__index=Session
require("Career.HousingActions").Install(Session)
require("Career.EngagementActions").Install(Session)
require("Career.StreetActions").Install(Session)
function Session.New(options)
    local self=setmetatable({},Session)
    self:Init(options or {})
    return self
end
function Session:Init(options)
    self.options=options
    ---@type fun()?
    self.restoreTestStorage=nil
    if options.test then
        local files={}
        self.restoreTestStorage=Store.UseTestStorage({read=function(path) return files[path],nil,files[path]==nil end,
            write=function(path,text) files[path]=text; return true end,
            cloud={Get=function() error("隔离验收禁止访问账号云档") end,Set=function() error("隔离验收禁止访问账号云档") end}})
    end
    self.running,self.loading,self.online,self.disposed=false,false,false,false
    self.yaw,self.pitch,self.timer=0,14,0
    self.waypoint=""
    self.manualWaypoint=false
    self.navigation={key="",route={}}
    self.space="city"
    self.cityX,self.cityZ,self.cityYaw=0,-20,0
    ---@type Scene?
    self.scene=nil
    ---@type CareerActor?
    self.actor=nil
    ---@type CareerCity?
    self.city=nil
    ---@type Zone?
    self.zone=nil
    ---@type Light?
    self.sun=nil
    ---@type Light?
    self.moon=nil
    ---@type ProceduralSky?
    self.sky=nil
    self.environmentHour=-1
    ---@type ThirdPersonCameraInstance?
    self.camera=nil
    ---@type CityTraffic?
    self.traffic=nil
    ---@type CareerDeliveryPeople?
    self.deliveryPeople=nil
    ---@type CareerDeliveryMarkers?
    self.deliveryMarkers=nil
    ---@type CareerSoundscape?
    self.audio=nil
    ---@type RideLoader?
    self.loader=nil
    ---@type thread?
    self.building=nil
    self.view=View.New({
        sound=function() if self.audio then self.audio:Unlock(); self.audio:Once("tap") end end,
        toggleMusic=function() if self.audio then self.audio.musicEnabled=not self.audio.musicEnabled; self:RefreshPhone() end end,
        toggleEffects=function() if self.audio then self.audio.effectsEnabled=not self.audio.effectsEnabled; self:RefreshPhone() end end,
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
            self.manualWaypoint=false
            self.view:Notice(message); self:RefreshPhone()
        end,
        mount=function()
            if self.space~="city" then self.view:Notice("电动车停在室外，请先出门"); return end
            if self.actor then local _,message=self.actor:ToggleMount(); self.view:ResetInput(); self.view:Notice(message); self:SavePosition(); self:Refresh() end
        end,
        interact=function() self:Interact() end,
        setWaypoint=function(id)
            if not Config.points[id] then self.view:Notice("导航地点不存在"); return end
            local order=Delivery.GetActive()
            local orderPoint=order and (order.status=="accepted" and order.pickupId or order.dropoffId)
            self.waypoint=id; self.manualWaypoint=id~=orderPoint
            if order and self.manualWaypoint then self.view:Notice("已切换地点导航；订单继续计时，可在外卖页切回订单导航") end
            self:Refresh()
        end,
        eat=function() self:Service("breakfast",function() return Store.Eat() end) end,
        rest=function(id) self:Service(id,function() return Store.Rest(id) end) end,
        charge=function() self:Service("charge",function() return Store.Charge() end) end,
        aid=function() self:Service("breakfast",function() return Store.RequestAid() end) end,
        save=function() self:SaveCloud() end,
        progression=function() self:OpenPhone("progression") end,
        buyEquipment=function(id) self:Service("dealer",function() return Progress.BuyEquipment(id) end) end,
        housing=function(id) self:ChooseHousing(id) end,
        sleepHousing=function() self:SleepHousing() end,
        enterHousing=function() self:EnterHousing(Store.Get().accommodation) end,
        leaveHousing=function() self:LeaveHousing() end,
        workWeek=function() self:WorkWeek() end,
        buyMotorcycle=function(id) self:Service("dealer",function() return Progress.BuyMotorcycle(id) end) end,
        selectMotorcycle=function(id) self:Service("dealer",function() return Progress.SelectMotorcycle(id) end) end,
        cityVehicle=function(id) return VehicleActions.Switch(self,id) end,
        refuel=function() self:Service("dealer",function() return Store.Refuel() end) end,
        train=function()
            self:Service("dealer",function()
                local p=Store.Get()
                if p.career and p.career.pending and p.career.pending.training then return true,"训练报名已保留" end
                return Progress.Train()
            end)
            local p=Store.Get()
            if p.career and p.career.pending and p.career.pending.training then self:EnterRace(1) end
        end,
        race=function(index) self:EnterRace(index) end,
        acceptEngagement=function(id) self:AcceptEngagement(id) end,
        claimEngagement=function(id) self:ClaimEngagement(id) end,
        visitEngagement=function(id) self:VisitEngagement(id) end,
        signTeam=function(id) self:SignTeam(id) end,
        claimTeam=function() self:ClaimTeam() end,
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
    self.waypoint=""; self.manualWaypoint=false; self.navigation={key="",route={}}
    self.loading=true
    self.view.home:SetVisible(false)
    self.view:ShowLoading("准备南城老街","正在校验城市、人物、车辆和材质。",0)
    local resources,types={},{}
    for _,module in ipairs({City,Actor,Traffic}) do
        for _,path in ipairs(module.Resources) do resources[#resources+1]=path; types[path]=module.ResourceTypes[path] end
    end
    for _,path in ipairs(require("Career.Phone").Resources) do resources[#resources+1]=path; types[path]="Texture2D" end
    local vehiclePaths,vehicleTypes=VehicleActions.Resources(Store.Get())
    for _,path in ipairs(vehiclePaths) do resources[#resources+1]=path; types[path]=vehicleTypes[path] end
    self.loader=Loader.New(CareerAudio.Resources,function(title,detail,fraction) self.view:ShowLoading(title,detail,fraction) end,
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
    zone.boundingBox=BoundingBox(Vector3(-16000,-1000,-16000),Vector3(16000,1000,16000))
    zone.depthFogStart,zone.depthFogEnd=150,450
    zone.fogColor=Color(.6,.68,.72)
    local light=lg:GetComponent("Light",true)
    -- 两级阴影优先保证鞋底、轮胎的近景接触，降低深度偏移造成的脱离。
    light.castShadows=true; light.shadowCascade=CascadeParameters(8,65,0,0,.85)
    light.shadowBias=BiasParameters(.0001,.25,0)
    self.zone,self.sun=zone,light
    -- 太阳落到地平线以下后不再照地面；独立冷色月光保证手游夜跑的基础可读性。
    local moonNode=self.scene:CreateChild("南城夜间月光")
    moonNode.direction=Vector3(.35,-.8,.25)
    local moon=moonNode:CreateComponent("Light")
    moon.lightType=LIGHT_DIRECTIONAL; moon.color=Color(.55,.67,1)
    moon.brightness=0; moon.castShadows=false
    self.moon=moon
    self.sky=self.scene:CreateChild("南城昼夜天空"):CreateComponent("ProceduralSky")
    self.sky.sunLight=light
    self.sky.skyCurve=.2
    local capture=lg:CreateComponent("SkyLightCapture")
    capture.resolution=64; capture.minCaptureInterval=2
    zone.envTextureDiffIntensity=1; zone.envTextureSpecIntensity=1
    renderer.hdrRendering=true
    self.environmentHour=-1
    self:UpdateEnvironment(Store.Get().time)
    self.view:ShowLoading("建设南城老街","道路、住宅、写字楼和生活地点。",.3)
    coroutine.yield()
    self.city=City.New(self.scene)
    self.view:ShowLoading("装配人物与车辆","独立停车位置与配送箱挂点。",.8)
    coroutine.yield()
    self.actor=Actor.New(self.scene,self.city)
    self.audio=CareerAudio.New(self.scene)
    self.audio:Unlock()
    self.environmentHour=-1
    self:UpdateEnvironment(Store.Get().time)
    self:RestorePosition()
    self.traffic=assert(Traffic.New(self.city,self.actor))
    self.city.traffic=self.traffic
    self.deliveryPeople=DeliveryPeople.New(self.city)
    self.city.deliveryPeople=self.deliveryPeople
    self.deliveryPeople:Sync(Store.Get().activeOrders,self.actor)
    self.deliveryMarkers=DeliveryMarkers.New(self.city)
    self.camera=ThirdPersonCamera.Create(self.scene,{
        modes={normal={distance=5.8,offset=Vector3(0,1.35,0),fov=55},ride={distance=6.4,offset=Vector3(0,1.3,0),fov=60},indoor={distance=3.1,offset=Vector3(0,1.2,0),fov=65}},
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
        local contact,worldShot,streetShot,handoffShot=false,"","",""
        local storyChecks,optimizeChecks,streetChecks,handoffChecks=false,false,false,false
        local qualityChecks,beaconShot,phoneShot,motionShot=false,"","",""
        for _,arg in ipairs(GetArguments()) do
            if arg=="-careeroptimize" then optimizeChecks=true end
            if arg=="-careerstorychecks" then storyChecks=true end
            if arg=="-careercontact" then contact=true end
            if arg=="-careerstreet" then streetChecks=true end
            if arg=="-careerhandoff" then handoffChecks=true end
            if arg=="-careerquality" then qualityChecks=true end
            local motion=arg:match("^%-contactmotion=(.+)$")
            if motion then motionShot=motion end
            local beacon=arg:match("^%-careerbeaconshot=(.+)$")
            if beacon then beaconShot=beacon end
            local phone=arg:match("^%-careerphoneshot=(.+)$")
            if phone then phoneShot=phone end
            local handoff=arg:match("^%-careerhandoffshot=(.+)$")
            if handoff then handoffShot=handoff end
            local street=arg:match("^%-careerstreetshot=(.+)$")
            if street then streetShot=street end
            local district=arg:match("^%-careerworldshot=(.+)$")
            if district then worldShot=district end
        end
        if phoneShot~="" then
            self.view:ClosePhone();self.view:ShowGame();self:OpenPhone(phoneShot)
            print("[手机实拍就绪] "..phoneShot.." / 隔离内存 / 真实页面")
        elseif motionShot~="" then require("Career.ContactChecks").Shot(self)
        elseif beaconShot~="" then require("Career.DeliveryMarkerChecks").Shot(self,beaconShot)
        elseif qualityChecks then
            self.view:ClosePhone();self.view:ShowGame()
            require("Career.DeliveryMarkerChecks").Run(self)
            require("Career.NavigationChecks").Run(self)
            require("Career.MapPhoneChecks").RunLayout(self.view,self:State(),Delivery.GetOffer(),Delivery.GetActive())
            require("Career.ContactChecks").Run(self)
            print("[游玩体验专项验收通过] 走跑/光柱/绕障/建筑足迹/手机桌面")
        elseif handoffChecks then
            self.view:ClosePhone(); self.view:ShowGame()
            require("Career.DeliveryPeopleChecks").Run(self)
        elseif handoffShot~="" then require("Career.DeliveryPeopleChecks").Shot(self,handoffShot)
        elseif streetChecks then
            self.view:ClosePhone(); self.view:ShowGame()
            require("Career.StreetInteractionChecks").Run(self)
            require("Career.StreetLifeChecks").Run(self)
            print("[老街品质验收通过] 街面/人物/现场交谈/原事务")
        elseif streetShot~="" then
            local checks=require("Career.StreetLifeChecks") --[[@as CareerStreetLifeChecks]]
            checks.Shot(self,streetShot)
        elseif optimizeChecks then
            self.view:ClosePhone(); self.view:ShowGame()
            require("Career.WorldChecks").Run(self)
            require("Career.MapPhoneChecks").Run(self)
            require("Career.OuterSignalChecks").Run(self)
            print("[本轮优化验收通过] 流式缓存/分区地图/外区信号")
        elseif storyChecks then
            self.view:ClosePhone(); self.view:ShowGame()
            require("Career.TeamChecks").Run()
            require("Career.EngagementChecks").Run()
            require("Career.StoryChecks").Run(self)
        elseif worldShot~="" then require("Career.WorldChecks").Shot(self,worldShot)
        elseif contact then require("Career.ContactChecks").Run(self)
        else require("Career.Checks").RunWorld(self) end
    end
    print("[生涯] 场景与主流程已接通")
end
function Session:UpdateEnvironment(hour)
    if self.city then self.city:UpdateLights(hour) end
    if not self.sky or not self.sun or not self.zone then return end
    local step=math.floor(hour*12)/12
    if step==self.environmentHour then return end
    self.environmentHour=step
    local a=(step-6)/12*math.pi
    local height=math.sin(a)
    local day=math.max(0,math.min(1,(height+.08)/.4))
    local dusk=math.exp(-((height-.02)/.16)^2)
    self.sun.node.direction=Vector3(-math.cos(a),-height,.35)
    self.sun.color=Color(1,.55,.3):Lerp(Color(1,.94,.84),day)
    self.sun.brightness=3*day
    if self.moon then self.moon.brightness=.65*(1-day) end
    local horizon=Color(.16,.21,.32):Lerp(Color(.66,.77,.9),day):Lerp(Color(.92,.57,.35),dusk*.7)
    self.sky.skyTopColor=Color(.08,.12,.24):Lerp(Color(.25,.47,.8),day)
    self.sky.skyHorizonColor=horizon; self.sky.groundHorizonColor=horizon
    self.sky.groundBottomColor=Color(.1,.11,.15):Lerp(Color(.35,.33,.28),day)
    self.zone.fogColor=horizon
end
function Session:Intro()
    self.view:ShowDialog("第一章 · 兜里还剩50块","王二狗，工作没了，房租也续不起。\n表哥把一串旧钥匙塞进你手里：\n“这辆战损9号以前追对象留下的。车还能跑，外卖箱给你装好了。先吃上饭，再想别的。”\n今晚能睡的地方，是桥洞和公园长椅。",{
        {text="接过钥匙 · 先把生活跑顺",primary=true,onClick=function()
            local ok,message=Store.Transaction(function(p) p.phase="working"; p.flags.introSeen=true; return true end)
            if not ok then self.view:Notice(message) end
            self:OpenPhone("messages")
        end}})
end
---@class CareerSessionState: CareerProfile
---@field contactName? string
---@field trafficHint? string
---@return CareerSessionState
function Session:State()
    local state=Store.Get(); state.online=self.online; state.currentSpace=self.space
    state.musicEnabled=self.audio and self.audio.musicEnabled
    state.effectsEnabled=self.audio and self.audio.effectsEnabled
    state.trafficHint=self.traffic and self.actor and self.space=="city" and self.traffic:Hint(self.actor.x,self.actor.z,self.actor.yaw) or nil
    if self.city and self.actor and self.space=="city" and not self.actor.mounted and self.actor.walkHeight<=1
        and math.abs(self.actor.speed)<=.35 and not Delivery.GetActive() then
        local person=self.city.contacts:Nearest(self.actor,3)
        if person then
            local nearest,distance="",math.huge
            for _,point in ipairs(Config.pointList) do
                local d=Config.DistanceTo(point.id,self.actor.x,self.actor.z)
                if d<distance then nearest,distance=point.id,d end
            end
            local talk=distance>2 or nearest=="breakfast" or nearest=="dealer"
            if distance<=2 then
                for _,item in ipairs(Engagements.State(state).list) do
                    if item.status=="ready" and item.returnPointId==nearest
                        or item.status=="active" and item.nextPointId==nearest and nearest~=item.returnPointId then talk=false end
                end
            end
            if talk then state.contactName=person.name end
        end
    end
    return state
end
function Session:Target()
    if not self.actor then return nil end
    if self.space~="city" then return self:InteriorTarget() end
    local order=Delivery.GetActive()
    local orderPoint=order and (order.status=="accepted" and order.pickupId or order.dropoffId)
    local id=self.manualWaypoint and Config.points[self.waypoint] and self.waypoint or orderPoint or self.waypoint
    local navigatingOrder=order and id==orderPoint
    local point=Config.points[id]
    if not point then return nil end
    local key=id..":"..math.floor(self.actor.x/16)..":"..math.floor(self.actor.z/16)
    if self.navigation.key~=key then
        self.navigation.key=key
        self.navigation.route=World.Route(self.actor.x,self.actor.z,point.x,point.z) or {}
    end
    local route=self.navigation.route
    local directDistance=Config.DistanceTo(id,self.actor.x,self.actor.z)
    -- 交互圈保留精确距离；近门前有真实净空的步行接近段不再绕道路吸附点计距。
    -- 只改显示；锁定配送费、订单路线和2米交互授权不变，隔墙/车上/高层仍用路网。
    local walkApproach=directDistance<=20 and not self.actor.mounted and self.actor.walkHeight<=1
        and self.city and self.city:StaticSegmentFree(self.actor.x,self.actor.z,point.x,point.z,.32,"walk",0)
    local distance=(directDistance<=Config.INTERACTION_RADIUS or walkApproach) and directDistance
        or (#route>1 and Config.RouteDistance(route) or directDistance)
    return {name=point.label,x=point.x,z=point.z,pointId=point.id,kind=point.kind,route=route,
        distance=distance,
        hint=navigatingOrder and (order.status=="accepted" and "停车下车，靠近店门点击取餐" or "停车下车，靠近门厅点击送达")
            or order and "地点导航 · 配送继续计时，外卖页可切回订单" or "到点后停车下车，点击交互"}
end
function Session:Refresh()
    if not self.actor then return end
    local state=self:State()
    if self.deliveryPeople then
        self.deliveryPeople:Sync(state.activeOrders,self.actor)
    end
    local target=self:Target()
    if self.deliveryMarkers then
        self.deliveryMarkers:Sync(state.activeOrders,target)
        self.deliveryMarkers:Update(0,self.actor,false)
    end
    self.view:Update(state,self.actor,target,Delivery.GetActive(),Delivery.GetOffer(),.2)
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
    if self.space~="city" then self.view:Notice("请先出门，再上线接单"); return end
    if not self.online then self.view:Notice("先上线听单"); return end
    self:SavePosition()
    local ok,message=Delivery.Accept()
    if ok then self.manualWaypoint=false end
    self.view:Notice(message); self:RefreshPhone()
end
function Session:Allowed(id)
    if not self.actor then return false,"尚未进入城市" end
    if not self.running then return false,"当前不在可交互的生涯场景" end
    if self.space~="city" then return false,"请先出门再使用城市服务" end
    if self.actor.mounted or math.abs(self.actor.speed)>.35 then return false,"请停稳下车后交互" end
    if not Config.points[id] then return false,"目的地不存在" end
    if self.actor.walkHeight>1 then return false,"请先沿天桥坡道回到地面" end
    if Config.DistanceTo(id,self.actor.x,self.actor.z)>Config.INTERACTION_RADIUS then return false,"请先前往"..Config.points[id].label.."（2米内）" end
    return true
end
function Session:Service(id,callback)
    local allowed,message=self:Allowed(id)
    if not allowed then self.waypoint=id; self.manualWaypoint=true; self.view:Notice(message); self:Refresh(); return end
    self:SavePosition()
    local ok,detail=callback()
    self.view:Notice(detail)
    self:RefreshPhone()
    if ok and (id=="bridge" or id=="park" or id=="home_old" or Config.points[id].kind=="rest") then
        self.view:ClosePhone()
        local state=Store.Get()
        self.view:ShowDialog("第"..state.day.."天 · 又是新的一天",string.format("昨天收入 %.2f元，支出 %.2f元。\n现在现金 %.2f元。休息好了，今天继续。",
            (state.lastDaySummary.incomeCents or 0)/100,(state.lastDaySummary.expenseCents or 0)/100,state.cashCents/100),{{text="出发",primary=true}})
    end
end
function Session:Interact()
    if not self.actor then return end
    if self.space~="city" then self:InteractHousing(); return end
    for _,home in ipairs(Housing.List) do
        if home.width and Config.DistanceTo(home.point,self.actor.x,self.actor.z)<=2 then self:EnterHousing(home.id); return end
    end
    local nearest,dist="",math.huge
    for _,p in ipairs(Config.pointList) do
        local d=Config.DistanceTo(p.id,self.actor.x,self.actor.z)
        if d<dist then nearest,dist=p.id,d end
    end
    local order=Delivery.GetActive()
    local nearby=dist<=Config.INTERACTION_RADIUS and Config.points[nearest] or nil
    local service=nearby and (nearby.kind=="charge" or nearby.kind=="rest" or nearby.kind=="merchant")
    local orderPoint=order and (order.status=="accepted" and order.pickupId or order.dropoffId)
    if order and order.status~="accepted" and order.pickupId=="breakfast"
        and Config.DistanceTo(order.pickupId,self.actor.x,self.actor.z)<=2 then
        self.view:Notice("这份餐已经取好了，请按导航送到顾客处；补给可在手机中选择")
        return
    end
    -- 当前取送点保持配送优先；其他现场补给允许带单使用，由 Store 扣除订单时间。
    if order and (not service or Config.DistanceTo(orderPoint,self.actor.x,self.actor.z)<=Config.INTERACTION_RADIUS) then
        if self.actor.walkHeight>1 then self.view:Notice("请先回到地面再取送餐"); return end
        self:SavePosition()
        local context={riding=self.actor.mounted,speed=self.actor.speed}
        local ok,message
        if order.status=="accepted" then ok,message=Delivery.Pickup(order.id,self.actor.x,self.actor.z,context)
        else ok,message=Delivery.Deliver(order.id,self.actor.x,self.actor.z,context) end
        if ok then self.manualWaypoint=false end
        self.view:Notice(message)
        if ok then self:DeliveryResponse(orderPoint,order.status=="accepted") end
        self:RefreshPhone()
        if ok and not Delivery.GetActive() then self.waypoint="breakfast" end
        return
    end
    if not order and dist>2 and not self.actor.mounted and math.abs(self.actor.speed)<=.35 and self.actor.walkHeight<=1 then
        local contact=self.city.contacts:Nearest(self.actor,3)
        if contact then self:TalkTo(contact.id); return end
    end
    if dist>2 then self.view:Notice("靠近商家、门厅、充电点或住处，再点击交互"); return end
    if self.actor.mounted or math.abs(self.actor.speed)>.35 then self.view:Notice("请停稳下车后交互"); return end
    local eventState=Engagements.State(Store.Get())
    for _,item in ipairs(eventState.list) do
        if item.status=="active" and item.nextPointId==nearest and nearest~=item.returnPointId then
            self:VisitEngagement(nearest); return
        end
        if item.status=="ready" and item.returnPointId==nearest then
            self:ClaimEngagement(item.instanceId); return
        end
    end
    if nearest=="breakfast" then
        local contact=self.city.contacts:Nearest(self.actor,3)
        if not contact or not self:TalkTo(contact.id) then self:OpenPhone("messages") end
    elseif nearest=="bridge" then self:OpenPhone("messages")
    elseif nearest=="park" then self:Service(nearest,function() return Store.Rest(nearest) end)
    elseif nearest=="charge" then self:Service(nearest,function() return Store.Charge() end)
    elseif nearest=="home_old" then self:OpenPhone("life")
    elseif nearest=="dealer" then
        local contact=self.city.contacts:Nearest(self.actor,3)
        if not contact or not self:TalkTo(contact.id) then self:OpenPhone("progression") end
    elseif Config.points[nearest].kind=="charge" then self:Service(nearest,function() return Store.Charge() end)
    elseif Config.points[nearest].kind=="rest" then self:Service(nearest,function() return Store.Rest("park") end)
    elseif Config.points[nearest].kind=="merchant" then self:Service(nearest,function() return Store.Eat() end)
    else self.view:Notice("这里没有待交付外卖") end
end
function Session:WorkWeek()
    if self.space~="city" then self.view:Notice("请先出门再安排工作周"); return end
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
    if not self.actor or self.options.test then return end
    return Store.SetPosition(self:PositionSnapshot())
end
function Session:RestorePosition()
    if not self.actor then return end
    local p=Store.Get().position
    local a=self.actor
    self.city:SetSpace("city")
    a:RestoreVehicles(p)
    a.mounted=p.mounted; a.visuals:SetMounted(p.mounted)
    self.cityX,self.cityZ,self.cityYaw=p.cityX or p.x,p.cityZ or p.z,p.cityYaw or p.yaw
    self:ApplySpace(p.space or "city")
    local x,z=self.city:FindFree(p.x,p.z,p.mounted and a:VehicleRadius() or .32,p.mounted and "vehicle" or "walk",p.groundHeight)
    assert(z,"存档恢复缺少Z坐标")
    a:Teleport(x,z,p.yaw,p.groundHeight); self.yaw=p.yaw
    if self.space=="city" then
        local stream=self.city.stream --[[@as CareerWorldStream]]
        stream:Ensure(x,z,550)
    end
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
    if self.city then self.city:UpdateStreaming(self.actor.x,self.actor.z) end
    self.city.contacts:Update(dt,self.actor,self.environmentHour,
        self.space=="city" and not self.view:IsBlocking() and not self.options.test)
    if self.deliveryPeople then
        self.deliveryPeople:Update(dt,self.actor,not self.view:IsBlocking() and not self.options.test)
    end
    if self.deliveryMarkers then
        self.deliveryMarkers:Update(dt,self.actor,not self.view:IsBlocking() and not self.options.test)
    end
    self.view:UpdateSpeech(dt)
    self.view:LayoutControls()
    self.view.controls:UpdateFeedback(dt)
    if self.audio then self.audio:Update(dt,self.actor,self.view:IsBlocking(),self.space~="city",self.view:GetInput(),self.online and Delivery.GetOffer() or nil) end
    if input:GetKeyPress(KEY_ESCAPE) then
        if self.view.phonePage~="" then self.view:ClosePhone()
        elseif self.view.conversation:IsVisible() then self.view:CloseConversation()
        elseif not self.view:IsBlocking() then self:Pause() end
        return
    end
    if self.view:IsBlocking() then
        self.actor.reverseHold=0
        return
    end
    if not self.options.test and math.abs(self.actor.speed)<.35 then
        local story=Progress.NextStory(Store.Get())
        if story then
            self.view:ShowDialog(story.title,story.text,{{text="记住这一刻 · 继续",primary=true,onClick=function()
                local _,message=Progress.MarkStory(story.id); self.view:Notice(message)
            end}})
            return
        end
    end
    if input:GetKeyPress(KEY_TAB) then self:OpenPhone("apps"); return end
    if input:GetKeyPress(KEY_P) then self:Pause(); return end
    if input:GetKeyPress(KEY_F) then self.view.actions.mount(); return end
    if input:GetKeyPress(KEY_E) then self:Interact(); return end
    local lookX,lookY,looking=self.view:ConsumeLook()
    if looking or lookX~=0 or lookY~=0 then
        self.yaw=self.yaw+lookX*.22
        self.pitch=math.max(-15,math.min(65,self.pitch+lookY*.18))
    elseif input:GetMouseButtonDown(MOUSEB_RIGHT) then
        self.yaw=self.yaw+input.mouseMoveX*.18
        self.pitch=math.max(-15,math.min(65,self.pitch+input.mouseMoveY*.15))
    elseif self.actor.mounted or math.abs(self.view.controls.steer)>.001 or self.view.controls.gas or self.view.controls.brake then
        self.yaw=self.yaw+((self.actor.yaw-self.yaw+180)%360-180)*math.min(1,dt*2.5)
    end
    if self.options.test then return end
    local x,z=self.actor.x,self.actor.z
    local controls=self.view:GetInput()
    local state=Store.Get()
    self:UpdateEnvironment(state.time)
    local need=math.min(state.hunger,state.energy)
    controls.speedFactor=need<15 and .45 or need<30 and .7 or 1
    if need<30 then controls.run=false end
    if state.time>=23 then controls.speedFactor=math.min(controls.speedFactor,.7) end
    local electric=self.actor.vehicleId==Vehicles.EBIKE
    if self.actor.mounted and (electric and state.battery<=0 or not electric and (state.motorcycleFuel or 100)<=0) then
        controls.throttle=0; controls.brake=true; controls.reverseBrake=false
    end
    self.actor:Update(dt,controls,self.yaw)
    if self.traffic then self.traffic:Update(dt) end
    local distance=self.actor.mounted and math.sqrt((self.actor.x-x)^2+(self.actor.z-z)^2) or 0
    self:SavePosition()
    local ok,message=Delivery.Update(dt,distance)
    if not ok and message~="存档忙" then self.view:Notice(message) end
    self.timer=self.timer+dt
    if self.timer>=.2 then self.timer=0; self:Refresh() end
end
function Session:PostUpdate(dt)
    if not self.camera or not self.actor then return end
    self.camera:SetMode(self.space~="city" and "indoor" or self.actor.mounted and "ride" or "normal")
    self.camera:Update(dt,self.actor.node,self.yaw,self.pitch)
end
function Session:LeaveForLegacy()
    if self.running and not self.options.test then self:SavePosition(); Store.Save() end
    self:DisposeWorld()
    if self.options.legacy then self.options.legacy() end
end
function Session:DisposeWorld()
    self.running,self.loading=false,false
    self.view.controls:SetEnabled(false); self.view:ResetInput()
    if self.loader then self.loader:Cancel(); self.loader=nil end
    self.building=nil
    renderer:SetNumViewports(0)
    if self.traffic then self.traffic:Dispose(); self.traffic=nil end
    if self.city then self.city.traffic=nil; self.city.deliveryPeople=nil end
    if self.deliveryPeople then self.deliveryPeople:Dispose(); self.deliveryPeople=nil end
    if self.deliveryMarkers then self.deliveryMarkers:Dispose(); self.deliveryMarkers=nil end
    if self.audio then self.audio:Stop(); self.audio=nil end
    if self.actor then self.actor:Dispose(); self.actor=nil end
    if self.city then self.city:Dispose(); self.city=nil end
    if self.scene then self.scene:Dispose(); self.scene=nil end
    self.city,self.camera,self.zone,self.sun,self.moon,self.sky=nil,nil,nil,nil,nil,nil
end
function Session:Dispose()
    if self.disposed then return end
    if self.running and not self.options.test then self:SavePosition(); Store.Save() end
    self.disposed=true; self:DisposeWorld(); self.view:Dispose()
    if self.restoreTestStorage then self.restoreTestStorage(); self.restoreTestStorage=nil end
end
return Session
