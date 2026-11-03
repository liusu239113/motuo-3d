-- 生涯协调器：单一Update入口、独立场景、独立存档，不改旧竞速模拟器。
-- 临时分项计时：定位骑行卡顿来源后整段删除。
local perfOrder_ = {"stream","contacts","people","markers","ui","crowd","traffic","audio","save","refresh"}
local perfAcc_, perfFrames_, perfSeconds_, perfLast_ = {}, 0, 0, 0
local function perfMark(name)
    local now = os.clock()
    if perfLast_ > 0 then perfAcc_[name] = (perfAcc_[name] or 0) + (now - perfLast_) end
    perfLast_ = now
end
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
local Environment = require("Career.CityEnvironment")
local Crowd = require("Career.Crowd")
local Atmosphere = require("Career.Atmosphere")
local Life = require("Career.LifeStatus")
local Calls = require("Career.CustomerCall")
local NightLighting = require("Career.NightLighting")
local RewardedAds = require("RewardedAds")

-- 所有模式切换都由主入口显式持有，避免场景被GC提前回收。
---@class CareerSession
---@field actor? CareerActor
---@field city? CareerCity
---@field deliveryPeople? CareerDeliveryPeople
---@field deliveryMarkers? CareerDeliveryMarkers
---@field nightLighting? CareerNightLighting
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
---@field CallCustomer fun(self:CareerSession,id:string)
---@field EndCustomerCall fun(self:CareerSession)
---@field BuyHome fun(self:CareerSession,id:string):boolean,string
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
    self.callSequence=0
    ---@type table?
    self.customerCall=nil
    self.yaw,self.pitch,self.timer=0,14,0
    self.storyTimer=0
    self.environmentTimer=0
    self.lifeMonitor={day=0,seen={}}
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
    ---@type CareerAtmosphere?
    self.atmosphere=nil
    ---@type CareerNightLighting?
    self.nightLighting=nil
    self.environmentHour=-1
    ---@type ThirdPersonCameraInstance?
    self.camera=nil
    ---@type Node?
    self.shotCameraTarget=nil
    ---@type CityTraffic?
    self.traffic=nil
    ---@type CareerCrowd?
    self.crowd=nil
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
        toggleEffects=function()
            if self.audio then
                self.audio.effectsEnabled=not self.audio.effectsEnabled
                if not self.audio.effectsEnabled then CareerAudio.StopPhone(self.audio) end
                self:RefreshPhone()
            end
        end,
        startCareer=function(fresh) self:StartCareer(fresh) end,
        legacy=function() self:LeaveForLegacy() end,
        pause=function() self:Pause() end,
        phone=function(page) self:OpenPhone(page) end,
        closePhone=function() self.view:ClosePhone() end,
        callCustomer=function(id) self:CallCustomer(id) end,
        endCall=function() self:EndCustomerCall() end,
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
        adSubsidy=function() self:ClaimAdSubsidy() end,
        save=function() self:SaveCloud() end,
        progression=function() self:OpenPhone("progression") end,
        buyEquipment=function(id) self:Service("dealer",function() return Progress.BuyEquipment(id) end) end,
        housing=function(id) self:ChooseHousing(id) end,
        buyHome=function(id)
            local property=require("Career.Property").Get(Store.Get(),id)
            if not property or not property.canBuy then self.view:Notice(property and property.reason or "房产不存在"); return end
            self.view.purchaseHomeId=id
            self:OpenPhone("property-confirm")
        end,
        confirmBuyHome=function(id) self:BuyHome(id);self:OpenPhone("progression") end,
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
        saveStatus=function()
            local status=Store.GetSaveStatus()
            return (status.pendingSave and "本地进度待保存，请勿退出。" or "")
                .."账号云档状态："..status.cloud.."。网页版刷新前请等待confirmed。"
        end,
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
    self.lifeMonitor={day=0,seen={}}
    self.view.home:SetVisible(false)
    self.view:ShowLoading("准备南城老街","正在校验城市、人物、车辆和材质。",0)
    local resources,types={},{}
    for _,module in ipairs({City,Actor,Traffic,Crowd,Atmosphere}) do
        for _,path in ipairs(module.Resources) do resources[#resources+1]=path; types[path]=module.ResourceTypes[path] end
    end
    for _,path in ipairs(require("Career.Phone").Resources) do resources[#resources+1]=path; types[path]="Texture2D" end
    local vehiclePaths,vehicleTypes=VehicleActions.Resources(Store.Get())
    for _,path in ipairs(vehiclePaths) do resources[#resources+1]=path; types[path]=vehicleTypes[path] end
    self.loader=Loader.New(CareerAudio.Resources,function(title,detail,fraction,numbers) self.view:ShowLoading(title,detail,fraction,numbers) end,
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
    require("Career.AdaptiveQuality").AttachSunlight(light)
    require("Career.AdaptiveQuality").AttachScene(self.scene)
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
    capture.resolution=32; capture.minCaptureInterval=12
    zone.envTextureDiffIntensity=1; zone.envTextureSpecIntensity=1
    self.atmosphere=Atmosphere.New(self.scene,self.sky,light,moon,zone)
    renderer.hdrRendering=true
    self.environmentHour=-1
    self:UpdateEnvironment(Store.Get().time)
    self.view:ShowLoading("建设南城老街","道路、住宅、写字楼和生活地点。",.3)
    coroutine.yield()
    self.city=City.New(self.scene)
    self.view:ShowLoading("装配人物与车辆","独立停车位置与配送箱挂点。",.8)
    coroutine.yield()
    self.actor=Actor.New(self.scene,self.city)
    self.nightLighting=NightLighting.New(self.scene)
    self.audio=CareerAudio.New(self.scene)
    self.audio:Unlock()
    self.environmentHour=-1
    self:UpdateEnvironment(Store.Get().time)
    self:RestorePosition()
    self.traffic=assert(Traffic.New(self.city,self.actor))
    self.city.traffic=self.traffic
    self.crowd=Crowd.New(self.city,self.city.root)
    self.city.crowd=self.crowd
    self.deliveryPeople=DeliveryPeople.New(self.city)
    self.city.deliveryPeople=self.deliveryPeople
    self.deliveryPeople:Sync(Store.Get().activeOrders,self.actor)
    self.deliveryMarkers=DeliveryMarkers.New(self.city)
    self.camera=ThirdPersonCamera.Create(require("Career.CameraCollision").New(self.scene,self.city,self.actor),{
        modes={normal={distance=5.8,offset=Vector3(0,1.35,0),fov=55},ride={distance=6.4,offset=Vector3(0,1.3,0),fov=60},indoor={distance=3.1,offset=Vector3(0,1.2,0),fov=65}},
        transitionSpeed=8,farClip=450,collisionApproachSpeed=1000000})
    renderer:SetNumViewports(1)
    renderer:SetViewport(0,Viewport:new(self.scene,self.camera:GetCamera()))
    renderer.dynamicInstancing=true; renderer:SetShadowMapSize(1024)
    self.camera:Update(1,self.actor.node,self.yaw,self.pitch)
    self.crowd:Prime(self.actor)
    self.loading,self.running=false,true
    self.view:ShowGame()
    self:Refresh()
    if Store.Get().phase=="opening" then self:Intro() end
    if self.options.test then
        local contact,worldShot,streetShot,handoffShot=false,"","",""
        local storyChecks,optimizeChecks,streetChecks,handoffChecks=false,false,false,false
        local legacyChecks=false
        local qualityChecks,beaconShot,phoneShot,motionShot=false,"","",""
        local appQuality,animQuality,cityQuality=false,false,false
        local collisionQuality,environmentQuality,soundCrowdQuality=false,false,false
        local collisionPhase="all"
        local appShot,animShot,cityShot="","",""
        local collisionShot,environmentShot,crowdShot="","",""
        local cityReview,reviewFast=false,false
        local lifeChecks,lifeShot=false,""
        for _,arg in ipairs(GetArguments()) do
            if arg=="-careercityreview" then cityReview=true end
            if arg=="-careerreviewfast" then reviewFast=true end
            if arg=="-careerlifechecks" then lifeChecks=true end
            local life=arg:match("^%-careerlifeshot=(.+)$")
            if life then lifeShot=life end
            if arg=="-careeroptimize" then optimizeChecks=true end
            if arg=="-careerlegacychecks" then legacyChecks=true end
            if arg=="-careerstorychecks" then storyChecks=true end
            if arg=="-careercontact" then contact=true end
            if arg=="-careerstreet" then streetChecks=true end
            if arg=="-careerhandoff" then handoffChecks=true end
            if arg=="-careerquality" then qualityChecks=true end
            if arg=="-careerappquality" then appQuality=true end
            if arg=="-careeranimquality" then animQuality=true end
            if arg=="-careercityquality" then cityQuality=true end
            if arg=="-careercollisionquality" then collisionQuality=true end
            if arg=="-careerenvironmentquality" then environmentQuality=true end
            if arg=="-careersoundcrowdquality" then soundCrowdQuality=true end
            local collisionPart=arg:match("^%-careercollisionphase=(.+)$")
            if collisionPart then collisionPhase=collisionPart end
            local collision=arg:match("^%-careercollisionshot=(.+)$")
            if collision then collisionShot=collision end
            local environment=arg:match("^%-careerenvironmentshot=(.+)$")
            if environment then environmentShot=environment end
            local crowd=arg:match("^%-careercrowdshot=(.+)$")
            if crowd then crowdShot=crowd end
            local app=arg:match("^%-careerappshot=(.+)$")
            if app then appShot=app end
            local anim=arg:match("^%-careeranimshot=(.+)$")
            if anim then animShot=anim end
            local expansion=arg:match("^%-careercityshot=(.+)$")
            if expansion then cityShot=expansion end
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
        local frameProbe,hillChecks,hillShot,turnChecks,perfChecks,trafficChecks=false,false,false,false,false,false
        for _,arg in ipairs(GetArguments()) do
            if arg=="-careerframeprobe" then frameProbe=true end
            if arg=="-careerhillchecks" then hillChecks=true end
            if arg=="-careerhillshot" then hillChecks,hillShot=true,true end
            if arg=="-careerturnchecks" then turnChecks=true end
            if arg=="-careerperfchecks" then perfChecks=true end
            if arg=="-careertrafficchecks" then trafficChecks=true end
        end
        if perfChecks then
            require("Career.TrafficChecks").FixedTicks()
            require("Career.TrafficMotion").CacheChecks()
            require("Career.OuterTraffic").CacheChecks()
            require("Career.Crowd").CacheChecks()
            require("Career.CameraCollision").CacheChecks()
            require("Career.CameraCollision").Checks(self)
            require("Career.VehicleContact").PerformanceChecks({city=assert(self.city)})
            require("Career.TurningChecks").Run(self)
            require("Career.TrafficChecks").Layers(self)
            require("Career.SoundCrowdChecks").Layers(self)
            print("[性能优化安全回归] PASS 缓存/相机/转向/上下层碰撞")
        elseif trafficChecks then require("Career.TrafficChecks").Run(self)
        elseif turnChecks then require("Career.TurningChecks").Run(self)
        elseif hillChecks then require("Career.HillDistrictChecks").Run(self,hillShot)
        elseif frameProbe then require("Career.FramePerformanceProbe").Install(self)
        elseif reviewFast then require("Career.ReviewWorldChecks").Run(self)
        elseif cityReview then
            require("Career.LifeChecks").Run(self,"")
            require("Career.LocomotionChecks").Run(self)
            require("Career.DeliveryMarkerChecks").Run(self)
            require("Career.WorldChecks").Coverage(self)
            require("Career.OuterChecks").Run(self)
            print("[城市整改专项通过] 生活/新人物/光柱/远区真实交通；不代表真机帧率验收")
        elseif lifeChecks or lifeShot~="" then require("Career.LifeChecks").Run(self,lifeShot)
        elseif appShot~="" then require("Career.PhoneAppChecks").Shot(self,appShot)
        elseif animShot~="" then require("Career.LocomotionChecks").Shot(self,animShot)
        elseif cityShot~="" then require("Career.CityExpansionChecks").Shot(self,cityShot)
        elseif collisionShot~="" then require("Career.CollisionChecks").Shot(self,collisionShot)
        elseif environmentShot~="" then require("Career.CityEnvironmentChecks").Shot(self,environmentShot)
        elseif crowdShot~="" then require("Career.SoundCrowdChecks").Shot(self,crowdShot)
        elseif appQuality or animQuality or cityQuality or collisionQuality or environmentQuality or soundCrowdQuality then
            self.view:ClosePhone();self.view:ShowGame()
            if collisionQuality then
                assert(collisionPhase=="all" or collisionPhase=="switch","未知碰撞专项阶段")
                if collisionPhase=="switch" then require("Career.CollisionChecks").RunSwitch(self)
                else require("Career.CollisionChecks").Run(self) end
            end
            if environmentQuality then require("Career.CityEnvironmentChecks").Run(self) end
            if soundCrowdQuality then require("Career.SoundCrowdChecks").Run(self) end
            if appQuality then require("Career.PhoneAppChecks").Run(self) end
            if animQuality then require("Career.LocomotionChecks").Run(self) end
            if cityQuality then require("Career.CityExpansionChecks").Run(self) end
            print("[城市体验专项完成] 指定专项已执行；具体结果见各模块断言")
        elseif phoneShot~="" then
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
        elseif legacyChecks then require("Career.Checks").RunWorld(self,{legacyOnly=true})
        else require("Career.Checks").RunWorld(self) end
    end
    print("[生涯] 场景与主流程已接通")
end
function Session:UpdateEnvironment(hour)
    if self.city then self.city:UpdateLights(hour) end
    self.environmentHour=hour
    if self.atmosphere then
        local p=Store.Get()
        local position=self.camera and self.camera:GetCamera().node.worldPosition
        local sample=Atmosphere.Apply(self.atmosphere,p.day,hour,position,self.space~="city")
        if self.nightLighting then NightLighting.Update(self.nightLighting,self.actor,sample,self.space~="city") end
    end
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
---@field nextGoal table
-- Interaction support is relative to the actual terrain, never absolute sea level.
-- A bridge layer (including its low ramp) or an unsupported/airborne pose cannot
-- authorise ground services; the 5cm tolerance only covers surface float jitter.
---@param self CareerSession
---@return boolean
local function groundSupported(self)
    local actor,city=self.actor,self.city
    if not actor or not city then return false end
    return World.HasGroundSupport(actor.x,actor.z,actor.walkHeight,city:Surface(actor.x,actor.z))
end
-- State提示与Interact分派共用：nextPointId是导航建议，不是先后不限目标的授权集合。
---@param item table
---@param pointId string
---@return boolean
local function pendingVisit(item,pointId)
    if item.status~="active" or pointId==item.returnPointId then return false end
    if item.nextPointId==pointId then return true end
    if item.id=="cousin_reply" then
        for _,objective in ipairs(item.objectives) do
            -- State.objectives尾项含return提示，不是访问授权；当前真源没有kind字段，
            -- 用真实访问目标id限定两处，不把以后追加的展示条件当成可访问点。
            if (objective.id=="park" or objective.id=="convenience")
                and not objective.done and objective.pointId==pointId then return true end
        end
    end
    return false
end
---@return CareerSessionState
function Session:State()
    local state=Store.Get(); state.online=self.online; state.currentSpace=self.space
    state.nextGoal=Progress.NextGoal(state)
    -- 生活页展示今日补贴是否已领，避免玩家点开才发现重复。
    state.adSubsidyClaimed=Store.AdSubsidyClaimed(state.day)
    state.adSubsidyCents=Config.AD_SUBSIDY_CENTS
    local weather=Atmosphere.Sample(state.day,state.time)
    state.weatherLabel,state.weatherCloudiness=weather.label,weather.cloudiness
    state.musicEnabled=self.audio and self.audio.musicEnabled
    state.effectsEnabled=self.audio and self.audio.effectsEnabled
    state.trafficHint=self.traffic and self.actor and self.space=="city" and self.traffic:Hint(self.actor.x,self.actor.z,self.actor.yaw) or nil
    if self.city and self.actor and self.space=="city" and not self.actor.mounted and groundSupported(self)
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
                        or pendingVisit(item,nearest) then talk=false end
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
    local mode=self.actor.mounted and "vehicle" or "walk"
    local layer=World.NavigationLayer(self.actor.x,self.actor.z,self.actor.walkHeight,mode)
    local grid=layer~="ground" and 1 or 16
    local key=table.concat({id,mode,layer,math.floor(self.actor.x/grid),math.floor(self.actor.z/grid)},":")
    if self.navigation.key~=key then
        self.navigation.key=key
        local approach=Environment.ApproachRoute(id)
        local localRoute=approach and Environment.NavigationRoute(id,self.actor.x,self.actor.z)
        if localRoute then self.navigation.route=localRoute
        elseif approach then
            local tail=Environment.CityApproachRoute()
            local entry=tail[1]
            local route=World.NavigationRoute(self.actor.x,self.actor.z,entry.x,entry.z,self.actor.walkHeight,layer) or {}
            local function append(steps)
                for _,step in ipairs(steps) do
                    local previous=route[#route]
                    if not previous or math.abs(previous.x-step.x)+math.abs(previous.z-step.z)>.001 then
                        route[#route+1]={x=step.x,z=step.z,y=step.y,layer=step.layer}
                    end
                end
            end
            append(tail)
            append(approach)
            self.navigation.route=route
        else
            local exit=Environment.ExitRoute(self.actor.x,self.actor.z)
            if exit then
                local route=exit
                local entry=route[#route]
                for _,step in ipairs(World.NavigationRoute(entry.x,entry.z,point.x,point.z,entry.y,"ground") or {}) do
                    local previous=route[#route]
                    if not previous or math.abs(previous.x-step.x)+math.abs(previous.z-step.z)>.001 then
                        route[#route+1]={x=step.x,z=step.z,y=step.y,layer=step.layer}
                    end
                end
                self.navigation.route=route
            else self.navigation.route=World.NavigationRoute(self.actor.x,self.actor.z,point.x,point.z,self.actor.walkHeight,layer) or {} end
        end
    end
    local route=self.navigation.route
    local directDistance=Config.DistanceTo(id,self.actor.x,self.actor.z)
    -- 交互圈保留精确距离；近门前有真实净空的步行接近段不再绕道路吸附点计距。
    -- 只改显示；锁定配送费、订单路线和2米交互授权不变，隔墙/车上/高层仍用路网。
    local walkApproach=directDistance<=20 and not self.actor.mounted and layer=="ground" and groundSupported(self)
        and self.city and self.city:StaticSegmentFree(self.actor.x,self.actor.z,point.x,point.z,.32,"walk",self.actor.walkHeight)
    local distance=(layer=="ground" and groundSupported(self) and directDistance<=Config.INTERACTION_RADIUS or walkApproach) and directDistance
        or (#route>1 and Config.RouteDistance(route) or directDistance)
    return {name=point.label,x=point.x,z=point.z,pointId=point.id,kind=point.kind,route=route,
        distance=distance,
        hint=navigatingOrder and (order.status=="accepted" and "停车下车，靠近店门点击取餐" or "停车下车，靠近门厅点击送达")
            or order and "地点导航 · 配送继续计时，外卖页可切回订单" or "到点后停车下车，点击交互"}
end
function Session:Refresh()
    if not self.actor then return end
    local state=self:State()
    self:UpdateEnvironment(state.time)
    if self.deliveryPeople then
        self.deliveryPeople:Sync(state.activeOrders,self.actor)
    end
    local target=self:Target()
    if self.deliveryMarkers then
        self.deliveryMarkers:Sync(state.activeOrders,target)
        self.deliveryMarkers:Update(0,self.actor,false)
    end
    local offer=Delivery.GetOffer()
    self.audioOffer=self.online and offer or nil
    self.view:Update(state,self.actor,target,state.activeOrders[1],offer,.2)
end
function Session:RefreshPhone()
    if self.view.phonePage~="" then self.view:BuildPhone(self:State(),Delivery.GetOffer(),Delivery.GetActive()) end
    self:Refresh()
end
function Session:OpenPhone(page)
    if not self.running or not self.actor then return end
    if math.abs(self.actor.speed)>.35 then self.view:Notice("请先停车，再打开手机"); return end
    self.view:OpenPhone(page,self:State(),Delivery.GetOffer(),Delivery.GetActive())
    if self.audio then self.audio:SetPaused(true) end
end
function Session:CallCustomer(id)
    if not self.running or not self.actor then return end
    if self.space~="city" then self.view:Notice("请先出门，再联系订单顾客。"); return end
    local order=Calls.Find(Store.Get().activeOrders,id)
    local call,message=Calls.Begin(order,self.actor,self.callSequence+1)
    if not call then self.view:Notice(message); return end
    self:EndCustomerCall()
    self.callSequence=self.callSequence+1
    self.customerCall=call
    self.view.phoneCall=call
    self:OpenPhone("call")
    if self.audio then self.audio:Unlock(); CareerAudio.PhoneRing(self.audio) end
    print("[顾客电话] 开始订单="..id.." 变体="..call.index)
end
function Session:EndCustomerCall()
    if self.customerCall then print("[顾客电话] 挂断订单="..self.customerCall.orderId) end
    self.customerCall=nil
    if self.view then self.view.phoneCall=nil end
    if self.audio then CareerAudio.StopPhone(self.audio) end
end
---交付成功后的可选小费：金额等基本单配送费，只有完整看完广告才入账。
---@param order CareerOrder 已结算订单
---@param pointId string
function Session:OfferAdTip(order,pointId)
    if not order or not order.feeCents then return end
    if Store.AdTipClaimed and Store.AdTipClaimed(order.id) then return end
    local cents=math.max(1,math.floor(order.feeCents))
    local orderId=order.id
    local feedback=Life.DeliveryFeedback(order)
    local tipText=feedback.late and "这单晚了一点，配送费仍按原报价到账；这次追加小费可自愿领取。"
        or "顾客：「这一单准时又稳，给你加个小费。」"
    self.view:ShowDialog("顾客追加了小费",tipText.."\n看一段广告，即可领取与本次配送费等额的小费。\n\n不看也没关系，配送费已经到账，不影响任何进度。",{
        {text="先不领",onClick=function() self.view:Notice("小费未领取，配送费已入账。") end},
        {text="看广告领小费",primary=true,onClick=function() self:ClaimAdTip(orderId,cents) end}})
end

---@param orderId string
---@param cents integer
function Session:ClaimAdTip(orderId,cents)
    local scene=self.scene
    RewardedAds.Show {
        isValid=function() return not self.disposed and self.running and self.scene==scene end,
        onReward = function()
            local ok,message=Store.ClaimAdTip(orderId,cents)
            self.view:Notice(ok and message or "小费已领取过，不再重复发放")
            self:RefreshPhone()
        end,
        onFailure = function(msg)
            self.view:Notice("广告未完成，小费没有发放："..tostring(msg))
        end,
    }
end

---每日一次的生活补贴入口，失败不发、不扣任何资源。
function Session:ClaimAdSubsidy()
    local state=Store.Get()
    if Store.AdSubsidyClaimed(state.day) then self.view:Notice("今日补贴已经领过了，明天再来"); return end
    local cents=Config.AD_SUBSIDY_CENTS
    local scene,day=self.scene,state.day
    RewardedAds.Show {
        isValid=function() return not self.disposed and self.running and self.scene==scene and Store.Get().day==day end,
        onReward = function()
            local ok,message=Store.ClaimAdSubsidy(cents)
            self.view:Notice(ok and message or "今日补贴已领取")
            self:RefreshPhone()
        end,
        onFailure = function(msg)
            self.view:Notice("广告未完成，今日补贴没有发放："..tostring(msg))
        end,
    }
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
    if not groundSupported(self) then return false,"请先沿坡道回到地面并站稳" end
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
    if not groundSupported(self) then self.view:Notice("请先沿坡道回到地面并站稳后交互"); return end
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
        self:SavePosition()
        local context={riding=self.actor.mounted,speed=self.actor.speed}
        local ok,message
        if order.status=="accepted" then ok,message=Delivery.Pickup(order.id,self.actor.x,self.actor.z,context)
        else ok,message=Delivery.Deliver(order.id,self.actor.x,self.actor.z,context) end
        if ok then self.manualWaypoint=false end
        self.view:Notice(message)
        if ok then self:DeliveryResponse(orderPoint,order.status=="accepted") end
        -- 交付成功才提供激励视频小费：金额与本单配送费等额，失败不发、每天可领。
        if ok and order.status~="accepted" then self:OfferAdTip(order,orderPoint) end
        self:RefreshPhone()
        if ok and not Delivery.GetActive() then self.waypoint="breakfast" end
        return
    end
    if not order and dist>2 and not self.actor.mounted and math.abs(self.actor.speed)<=.35 and groundSupported(self) then
        local contact=self.city.contacts:Nearest(self.actor,3)
        if contact then self:TalkTo(contact.id); return end
    end
    if dist>2 then self.view:Notice("靠近商家、门厅、充电点或住处，再点击交互"); return end
    if self.actor.mounted or math.abs(self.actor.speed)>.35 then self.view:Notice("请停稳下车后交互"); return end
    local eventState=Engagements.State(Store.Get())
    for _,item in ipairs(eventState.list) do
        if pendingVisit(item,nearest) then
            self:VisitEngagement(nearest); return
        end
        if item.status=="ready" and item.returnPointId==nearest then
            self:ClaimEngagement(item.instanceId); return
        end
    end
    if nearest=="breakfast" then
        local contact=self.city.contacts:Nearest(self.actor,3)
        if not contact or not self:TalkTo(contact.id) then self:OpenPhone("messages") end
    elseif nearest=="bridge" then
        self.view:ShowDialog("桥下落脚点","桥梁下方的纸板和睡袋可以临时过夜。\n免费休息至次日08:00；手头有未送完的餐时不能过夜。",{
            {text="先不休息"},
            {text="看看表哥的消息",onClick=function() self:OpenPhone("messages") end},
            {text="确认在桥下休息",primary=true,onClick=function()
                self:Service("bridge",function() return Store.Rest("bridge") end)
            end}})
    elseif nearest=="park" then self:Service(nearest,function() return Store.Rest(nearest) end)
    elseif nearest=="charge" then self:Service(nearest,function() return Store.Charge() end)
    elseif nearest=="home_old" then self:OpenPhone("life")
    elseif nearest=="dealer" then
        local contact=self.city.contacts:Nearest(self.actor,3)
        if not contact or not self:TalkTo(contact.id) then self:OpenPhone("progression") end
    elseif Config.points[nearest].kind=="scenery" then
        local hill=nearest:match("^hills_")~=nil
        self.view:ShowDialog(Config.points[nearest].label,hill
            and "这里是山城滨江路。半山住宅街经缓坡与折线弯道接到江岸，中央公路桥通向北岸。\n请沿车道和护栏内步道通行；江水区域不能进入。这里只提供游览，不扣费、不推进一天。"
            or "海岸入口、沙滩与栈桥都可沿步道到达。\n可以下车步行看海；护栏外的深水不能通行。这里不会自动推进一天或收取费用。",{
            {text="继续逛逛",primary=true},
            {text="查看区域地图",onClick=function() self:OpenPhone("map") end}})
    elseif Config.points[nearest].kind=="charge" then self:Service(nearest,function() return Store.Charge() end)
    elseif Config.points[nearest].kind=="rest" then self:Service(nearest,function() return Store.Rest("park") end)
    elseif Config.points[nearest].kind=="merchant" then self:Service(nearest,function() return Store.Eat() end)
    else self.view:Notice("这里没有待交付外卖") end
end
function Session:WorkWeek()
    if self.space~="city" then self.view:Notice("请先出门再安排工作周"); return end
    if not self.actor or self.actor.mounted or math.abs(self.actor.speed)>.35 then self.view:Notice("请下车停稳后安排工作"); return end
    local preview=Progress.WorkWeekPreview(Store.Get())
    self.view:ShowDialog("确认推进7个游戏日？",string.format("安排未来完整7天：%d份模拟单。\n收入 %.2f元，餐食、整备和住宿共 %.2f元，预计净存 %.2f元。\n每周资格需新的10份亲送及15分钟活动；过往亲送不抵扣未来模拟单，也不会重复发放亲送收入。",preview.simulatedOrders,preview.grossCents/100,preview.costsCents/100,preview.netCents/100),{
        {text="继续亲自跑单"},
        {text="确认7天排班",primary=true,onClick=function()
            self:SavePosition(); local _,message=Progress.WorkWeek(); self.view:Notice(message); self:RefreshPhone()
        end}})
end
function Session:EnterRace(index)
    local allowed,message=self:Allowed("dealer")
    if not allowed then self.waypoint="dealer"; self.view:Notice(message); return end
    local p=Store.Get()
    if #p.activeOrders>0 then self.view:Notice("请先完成配送订单，再继续已报名项目"); return end
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
    if self.traffic then self.traffic:ReconcileParking() end
    a.mounted=p.mounted; a.visuals:SetMounted(p.mounted)
    self.cityX,self.cityZ,self.cityYaw=p.cityX or p.x,p.cityZ or p.z,p.cityYaw or p.yaw
    self:ApplySpace(p.space or "city")
    local x,z
    if p.mounted then
        -- 已由RestoreVehicles静态规划的活动车位不可再被瞬时交通挪动。
        x,z=a.bikeX,a.bikeZ
    else
        x,z=self.city:FindShapeFree(p.x,p.z,a:Footprint(false),p.yaw,"walk",p.groundHeight,a.vehicleId)
    end
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
-- 暂停页内的画面与性能设置：自动按设备推荐，也可手动锁档。
function Session:QualityDialog()
    local Quality=require("Career.AdaptiveQuality")
    local current=Quality.auto and "自动（按设备推荐）" or Quality.Current().name
    local function apply(level)
        Quality.Set(level)
        if self.view.Notice then self.view:Notice("画质已切到："..Quality.Current().name) end
        print("[画面设置] "..Quality.Current().name.."档：可见距离×"..Quality.Current().draw.." 阴影×"..Quality.Current().shadow)
        self:QualityDialog()
    end
    self.view:ShowDialog("画面与性能",
        string.format("当前：%s\n自动模式会按实测帧时自动升降档，优先保证流畅；手动可固定档位。",current),
        {
            {text="自动（推荐）",primary=Quality.auto,onClick=function() Quality.SetAuto(true); self:QualityDialog() end},
            {text="高",primary=(not Quality.auto) and Quality.level==3,onClick=function() apply(3) end},
            {text="中",primary=(not Quality.auto) and Quality.level==2,onClick=function() apply(2) end},
            {text="低",primary=(not Quality.auto) and Quality.level==1,onClick=function() apply(1) end},
            {text="返回",onClick=function() self:Pause() end},
        },true)
end
function Session:Pause()
    if not self.running then return end
    if self.audio then self.audio:SetPaused(true);CareerAudio.StopPhone(self.audio) end
    self:SavePosition()
    local _,message=Store.Save()
    self.view:ShowDialog("暂时歇一歇",message.."\n完整手机与暂停期间不推进时间和订单。",{
        {text="继续生活",primary=true},
        {text="画面与性能",onClick=function() self:QualityDialog() end},
        {text="保存到账号云端",onClick=function() self:SaveCloud() end},
        {text="回到生涯主页",onClick=function()
            if not self:SaveBeforeLeave() then return end
            self:DisposeWorld(); self:Home()
        end}})
end
function Session:Update(dt)
    if self.disposed then return end
    if self.traffic and (self.loading or not self.running or self.view:IsBlocking() or self.options.test) then
        require("Career.RoadReactions").ResetWaiting(self.traffic)
    end
    if self.audio then
        self.audio:SetPaused(self.loading or not self.running or self.view:IsBlocking() or self.options.test==true)
        if self.loading or not self.running then CareerAudio.StopPhone(self.audio) end
    end
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
    perfLast_ = os.clock()
    if self.customerCall then
        if self.view.phonePage~="call" then self:EndCustomerCall()
        elseif Calls.Advance(self.customerCall,dt) then
            if self.audio then CareerAudio.StopPhone(self.audio) end
            self:RefreshPhone()
            print("[顾客电话] 已接通订单="..self.customerCall.orderId)
        end
    end
    if self.city then self.city:UpdateStreaming(self.actor.x,self.actor.z) end
    perfMark("stream")
    self.city.contacts:Update(dt,self.actor,self.environmentHour,
        self.space=="city" and not self.view:IsBlocking() and not self.options.test)
    perfMark("contacts")
    if self.deliveryPeople then
        self.deliveryPeople:Update(dt,self.actor,not self.view:IsBlocking() and not self.options.test)
    end
    perfMark("people")
    if self.deliveryMarkers then
        self.deliveryMarkers:Update(dt,self.actor,not self.view:IsBlocking() and not self.options.test)
    end
    perfMark("markers")
    self.view:UpdateSpeech(dt)
    self.view:LayoutControls()
    self.view.controls:UpdateFeedback(dt)
    perfMark("ui")
    local blocked=self.view:IsBlocking()
    if self.crowd and (blocked or self.space~="city" or self.options.test) then
        self.crowd:Update(dt,self.actor,false,self.camera and self.camera:GetCamera())
    end
    if self.audio and (blocked or self.options.test) then
        self.audio:Update(dt,self.actor,true,self.space~="city",self.view:GetInput(),self.audioOffer,
            Environment.AudioContext(self.actor.x,self.actor.z))
    end
    if input:GetKeyPress(KEY_ESCAPE) then
        if self.view.worldMap:IsVisible() then self.view:CloseWorldMap()
        elseif self.view.phonePage~="" then self.view:ClosePhone()
        elseif self.view.conversation:IsVisible() then self.view:CloseConversation()
        elseif not self.view:IsBlocking() then self:Pause() end
        return
    end
    if self.view:IsBlocking() then
        self.actor.reverseHold=0
        return
    end
    if not self.options.test and math.abs(self.actor.speed)<.35 then
        self.storyTimer=self.storyTimer+dt
        local story=self.storyTimer>=.5 and Progress.NextStory(Store.Get()) or nil
        if self.storyTimer>=.5 then self.storyTimer=0 end
        if story then
            if self.audio then self.audio:SetPaused(true) end
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
    local state=Store.MotionState()
    -- 环境由每0.2秒的Refresh统一更新，不与移动循环重复捕获天空。
    local need=math.min(state.hunger,state.energy)
    controls.speedFactor=need<15 and .45 or need<30 and .7 or 1
    if need<30 then controls.run=false end
    if state.time>=23 then controls.speedFactor=math.min(controls.speedFactor,.7) end
    local electric=self.actor.vehicleId==Vehicles.EBIKE
    if self.actor.mounted and (electric and state.battery<=0 or not electric and (state.motorcycleFuel or 100)<=0) then
        controls.throttle=0; controls.brake=true; controls.reverseBrake=false
    end
    self.actor:Update(dt,controls,self.yaw)
    if self.crowd and self.space=="city" then
        self.crowd:Update(dt,self.actor,true,self.camera and self.camera:GetCamera())
    end
    perfMark("crowd")
    if self.traffic then
        self.traffic:Update(dt)
        require("Career.RoadReactions").Update(self.traffic,dt,self.audio)
    end
    perfMark("traffic")
    if self.audio then
        self.audio.musicHour=state.time
        self.audio:Update(dt,self.actor,false,self.space~="city",controls,self.audioOffer,
            Environment.AudioContext(self.actor.x,self.actor.z))
    end
    perfMark("audio")
    local distance=self.actor.mounted and math.sqrt((self.actor.x-x)^2+(self.actor.z-z)^2) or 0
    self:SavePosition()
    local wasPending=Store.GetSaveStatus().pendingSave
    local ok,message=Delivery.Update(dt,distance)
    if not ok and message~="存档忙" then self.view:Notice(message)
    elseif ok and wasPending and not Store.GetSaveStatus().pendingSave then
        self.view:Notice("本地进度已补存成功；账号云存档仍需单独确认")
    end
    perfMark("save")
    self.timer=self.timer+dt
    if self.timer>=.2 then
        self.timer=0; self:Refresh()
        if self.view.noticeTime<=0 then
            local alert=Life.PollAlerts(self.lifeMonitor,Store.Get())
            if alert then self.view:Notice(alert.title.." · "..alert.detail) end
        end
    end
    perfMark("refresh")
    perfFrames_ = perfFrames_ + 1
    perfSeconds_ = perfSeconds_ + dt
    if perfSeconds_ >= 5 then
        local out = {}
        for i,name in ipairs(perfOrder_) do
            out[i] = string.format("%s=%.1f", name, (perfAcc_[name] or 0) * 1000 / perfFrames_)
        end
        print(string.format("[分项计时] 帧数=%d %s | ms/帧", perfFrames_, table.concat(out, " ")))
        perfAcc_, perfFrames_, perfSeconds_ = {}, 0, 0
    end
end
function Session:PostUpdate(dt)
    if not self.camera or not self.actor then return end
    if self.options.test and self.shotRenderFrames then
        self.shotRenderFrames=self.shotRenderFrames+1
        if self.shotRenderFrames==10 then
            print(string.format("[城市渲染采样] batches=%d primitives=%d；当前视口实测，非手机GPU耗时",renderer.numBatches,renderer.numPrimitives))
        end
    end
    if self.options.test and self.shotCameraTarget then
        self.camera:Update(dt,self.shotCameraTarget,self.yaw,self.pitch)
        return
    end
    self.camera:SetMode(self.space~="city" and "indoor" or self.actor.mounted and "ride" or "normal")
    self.camera:Update(dt,self.actor.node,self.yaw,self.pitch)
    if self.atmosphere then
        self.atmosphere.root.worldPosition=self.camera:GetCamera().node.worldPosition
        if self.nightLighting then NightLighting.Update(self.nightLighting,self.actor,self.atmosphere.state,self.space~="city") end
    end
end
function Session:SaveBeforeLeave()
    if not self.running or self.options.test then return true end
    self:SavePosition()
    local ok,message=Store.Save()
    if not ok then
        self.view:ShowDialog("进度尚未保存",message.."\n未离开当前生涯；可继续生活，或稍后再次保存。",{
            {text="留在当前生涯",primary=true}})
    end
    return ok
end
function Session:LeaveForLegacy()
    if not self:SaveBeforeLeave() then return end
    self:DisposeWorld()
    if self.options.legacy then self.options.legacy() end
end
function Session:DisposeWorld()
    RewardedAds.Cancel()
    self:EndCustomerCall()
    self.running,self.loading=false,false
    self.view.controls:SetEnabled(false); self.view:ResetInput()
    if self.loader then self.loader:Cancel(); self.loader=nil end
    self.building=nil
    self.shotCameraTarget=nil
    renderer:SetNumViewports(0)
    if self.crowd then self.crowd:Dispose(); self.crowd=nil end
    if self.traffic then self.traffic:Dispose(); self.traffic=nil end
    if self.city then self.city.traffic=nil; self.city.deliveryPeople=nil; self.city.crowd=nil end
    if self.deliveryPeople then self.deliveryPeople:Dispose(); self.deliveryPeople=nil end
    if self.deliveryMarkers then self.deliveryMarkers:Dispose(); self.deliveryMarkers=nil end
    if self.audio then self.audio:Stop(); self.audio=nil end
    if self.nightLighting then NightLighting.Dispose(self.nightLighting);self.nightLighting=nil end
    if self.actor then self.actor:Dispose(); self.actor=nil end
    if self.city then self.city:Dispose(); self.city=nil end
    if self.atmosphere then self.atmosphere:Dispose(); self.atmosphere=nil end
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
