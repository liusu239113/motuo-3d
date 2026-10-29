-- 隔离输入/接触回归；不替换正式玩家、城市或停车表。
-- 换车定点验收仅通过Store.WithTestStorage写内存，绝不写真实存档。
-- 夹具持有独立角色和节点；Run即使断言失败也释放全部可见对象。
-- Shot只保留独立夹具，供真实引擎摄影。
local Actor=require("Career.Actor")
local City=require("Career.City")
local Traffic=require("Career.Traffic")
local Assets=require("VehicleAssets")
local C=require("Career.FootprintCollision")
local F=require("Career.VehicleFootprints")
local Parts=require("Parts")
local Checks={}
local shots={}
local liveFixtures={}
local function close(a,b,epsilon) return math.abs(a-b)<(epsilon or .0001) end
local function fixture(scene)
    local root=scene:CreateChild("隔离白车窄隙验收")
    local city=setmetatable({root=root,space="city",obstacles={},
        Surface=function() return .055 end,WalkSurface=function() return .055 end},City)
    local t=setmetatable({city=city,cars={},pedestrians={people={}},active=true},Traffic)
    city.traffic=t
    local actor=Actor.New(scene,city)
    actor.parking={}; actor.bikeX,actor.bikeZ=40,40
    local f={root=root,city=city,traffic=t,actor=actor,scene=scene}
    liveFixtures[#liveFixtures+1]=f
    function f:Car(x,z,yaw,id)
        id=id or "sedan"
        local node=Assets.Add(self.root,id,nil,"distant")
        local size=node:GetVar("VehicleSize"):GetVector3()
        local car={id=id,node=node,x=x,z=z,yaw=yaw,width=size.x,length=size.z,speed=0}
        node.position=Vector3(x,.055,z);node.rotation=Quaternion(0,yaw,0)
        self.traffic.cars[#self.traffic.cars+1]=car
        return car
    end
    function f:Wall(x1,z1,x2,z2)
        self.city.obstacles[#self.city.obstacles+1]={x1=x1,z1=z1,x2=x2,z2=z2}
        Parts.Add(self.root,"可见窄隙边墙","Box",Parts.Material(.24,.26,.28,.9,0),
            Vector3((x1+x2)/2,.45,(z1+z2)/2),Vector3(x2-x1,.9,z2-z1),nil,true)
    end
    function f:Reset(x,z,yaw,mounted)
        local a=self.actor
        a.mounted=mounted;a.x,a.z,a.yaw,a.speed=x,z,yaw,0
        a.bikeX,a.bikeZ,a.bikeYaw=mounted and x or 40,mounted and z or 40,yaw
        a.parking={};a.walkHeight=0;a.walkDistance=0
        a.visuals:SetMounted(mounted);a:SyncVisuals(0)
        assert(self.city:IsShapeFree(x,z,a:Footprint(),yaw,mounted and "vehicle" or "walk",0,mounted and a.vehicleId or nil),"Fixture must start outside visible geometry")
    end
    function f:Drive(seconds,controls,cameraYaw,dt)
        local a=self.actor
        dt=dt or .05
        for _=1,math.ceil(seconds/dt) do
            a:Update(dt,controls,cameraYaw or 0)
            assert(self.city:IsShapeFree(a.x,a.z,a:Footprint(),a.yaw,a.mounted and "vehicle" or "walk",a.walkHeight,a.mounted and a.vehicleId or nil),
                "Actor.Update entered a car/wall/parked-bike shell")
        end
    end
    function f:Dispose()
        if self.disposed then return end
        self.disposed=true;self.actor:Dispose();self.root:Dispose()
    end
    return f
end
local function gap(scene,mounted,yaw)
    local f=fixture(scene)
    yaw=yaw or 0
    local bike=F.Get("borrowed_ebike")
    local width=mounted and bike.x2-bike.x1 or .64
    local gapWidth=width+.10 -- five centimetres each side, NOT an existing wide street
    local sedan=F.Get("sedan")
    local side=sedan.x1-gapWidth/2
    if mounted then side=side-(bike.x1+bike.x2)/2 end
    local a=math.rad(yaw)
    local function world(x,z) return x*math.cos(a)+z*math.sin(a),-x*math.sin(a)+z*math.cos(a) end
    f:Car(0,0,yaw)
    if yaw==0 then
        f:Wall(sedan.x1-gapWidth-.25,-8,sedan.x1-gapWidth,8)
    else
        -- Two independently reusable visible cars create the same physical gap
        -- at arbitrary yaw; no axis-aligned enclosing-box wall can close it.
        local x,z=world(sedan.x1-gapWidth-sedan.x2,0)
        f:Car(x,z,yaw)
    end
    local x,z=world(side,-6)
    f:Reset(x,z,yaw,mounted)
    local controls=mounted and {throttle=.22,steer=0} or {walkY=1,walkX=0}
    f:Drive(mounted and 9 or 7,controls,yaw)
    local along=f.actor.x*math.sin(a)+f.actor.z*math.cos(a)
    local across=f.actor.x*math.cos(a)-f.actor.z*math.sin(a)
    assert(along>4.5,"Real input must pass both ends of the white car through the narrow visible gap")
    assert(math.abs(across-side)<.015,"Passing must stay in the narrow gap, not detour into the wide road")
    f.gapWidth,f.progress,f.side,f.yaw=gapWidth,along,side,yaw
    return f
end
local function contact(scene,mounted,yaw,approach)
    local f=fixture(scene)
    yaw=yaw or 0
    f:Car(0,0,yaw)
    local a=math.rad(yaw)
    local u,v,heading= -5,0,90+yaw
    if approach=="front" then u,v,heading=0,7,180+yaw end
    if approach=="rear" then u,v,heading=0,-7,yaw end
    local x,z=u*math.cos(a)+v*math.sin(a),-u*math.sin(a)+v*math.cos(a)
    f:Reset(x,z,heading,mounted)
    f:Drive(6,mounted and {throttle=1} or {walkY=1},heading,.25)
    local oldX,oldZ=f.actor.x,f.actor.z
    f:Drive(1,mounted and {throttle=1} or {walkY=1},heading,.25)
    local inward=(f.actor.x-oldX)*math.sin(math.rad(heading))+(f.actor.z-oldZ)*math.cos(math.rad(heading))
    assert(inward<.12,string.format("Sustained contact advanced into shell %s yaw %.1f %s by %.4fm",tostring(mounted),yaw,approach or "side",inward))
    if mounted then assert(math.abs(f.actor.speed)<.4,"Blocked vehicle must not accumulate wall turbo; tapered shell may slide tangentially") end
    return f
end
-- 生产Switch定点验收：只注入资源是否ready与下载器回调；业务入口、
-- 实际模型Footprint、City形状查询、Store事务均为生产实现。
function Checks.RunSwitch(session)
    assert(session.options and session.options.test,"换车验收只允许隔离测试会话")
    assert(cache:GetResource("Model",Assets.Vehicles.sport.model),"换车验收所需sport真实模型尚未就绪")
    local Store=require("Career.Store")
    local Actions=require("Career.VehicleActions")
    local Vehicles=require("Career.VehicleData")
    local Loader=require("RideLoader")
    local resourceCache=cache
    local originalNew=Loader.New
    local f=fixture(session.scene)
    local files={}
    local failWrite,pending=false,false
    local pendingRequest={}
    local restores,snapshots,queries=0,0,0
    local fake={actor=f.actor,city=f.city,options={test=true},disposed=false,
        view={Notice=function() end,ClosePhone=function() end,ResetInput=function() end,
            ShowGame=function() end,ShowLoading=function() end,controls={SetEnabled=function() end}}}
    function fake:Allowed() return true,"" end
    function fake:PositionSnapshot()
        snapshots=snapshots+1
        local p=Store.Get().position
        p.x,p.z,p.yaw=self.actor.x,self.actor.z,self.actor.yaw
        p.mounted=false;p.space="city"
        p.activeVehicle=self.actor.vehicleId
        p.bikeX,p.bikeZ,p.bikeYaw=self.actor.bikeX,self.actor.bikeZ,self.actor.bikeYaw
        p.vehicleParking=self.actor:ParkingSnapshot()
        return p
    end
    function fake:RestorePosition()
        restores=restores+1
        local p=Store.Get().position
        self.actor.vehicleId=p.activeVehicle
        self.actor.bikeX,self.actor.bikeZ,self.actor.bikeYaw=p.bikeX,p.bikeZ,p.bikeYaw
        self.actor.parking=p.vehicleParking
    end
    function fake:Refresh() end
    local oldQuery=f.city.IsShapeFree
    f.city.IsShapeFree=function(city,...)
        queries=queries+1
        return oldQuery(city,...)
    end
    local ok,message=xpcall(function()
        -- 只在本次同步隔离检查期间代理全局cache；每个路径都在finally还原。
        cache=setmetatable({Exists=function() return not pending end,
            GetResource=function(_,...)return resourceCache:GetResource(...)end},
            {__index=function(_,key)return resourceCache[key]end})
        Loader.New=function(_,progress,completed,failed)
            pendingRequest={completed=completed,failed=failed}
            return {Start=function() end}
        end
        Store.WithTestStorage({read=function(path)return files[path],nil,files[path]==nil end,
            write=function(path,text)if failWrite then return false,"换车验收模拟写失败" end;files[path]=text;return true end},function()
            local function reset()
                f.city.obstacles={}
                assert(Store.NewCareer())
                assert(Store.Transaction(function(p)p.phase="working";p.ownedMotorcycles.sport=true;p.activeOrders={};return true end))
                local a=f.actor
                a.vehicleId=Vehicles.EBIKE;a.mounted=false;a.x,a.z,a.yaw=100,70,0
                a.bikeX,a.bikeZ,a.bikeYaw=104,70,0;a.parking={}
                pending=false;failWrite=false;restores,snapshots,queries=0,0,0
            end
            local base=Vehicles.Parking
            local shape=F.Get("sport")
            reset()
            -- 真实车型两侧只留4cm；旧外接圆会错误拒绝，不能改成空旷交车位。
            f.city.obstacles={{x1=base.x+shape.x1-.14,x2=base.x+shape.x1-.04,z1=base.z-2,z2=base.z+2},
                {x1=base.x+shape.x2+.04,x2=base.x+shape.x2+.14,z1=base.z-2,z2=base.z+2}}
            assert(not f.city:IsFree(base.x,base.z,Vehicles.Radii.sport),"夹具必须复现旧整车圆空气墙")
            assert(Actions.Switch(fake,"sport"),"生产换车必须接受贴真实模型的窄交车位")
            assert(Store.Get().position.bikeZ==base.z and restores==1,"不能跳到远处宽车位掩盖空气墙")
            local oldBike=Store.Get().position.vehicleParking[Vehicles.EBIKE]
            assert(oldBike.x==104 and oldBike.z==70,"交新车必须保留原车停车")
            reset()
            f.actor.bikeX,f.actor.bikeZ=base.x,base.z -- 首位被实车占用
            assert(Actions.Switch(fake,"sport"))
            assert(Store.Get().position.bikeZ==base.z-4,"首位被占用应继续试其它独立车位")
            reset()
            f.actor.x,f.actor.z=base.x,base.z -- 不在停车表的玩家本人也占地
            assert(Actions.Switch(fake,"sport") and Store.Get().position.bikeZ==base.z-4,"不得把新车交到玩家身体内")
            reset()
            f.actor.parking.sport={x=110,z=65,yaw=90}
            assert(Actions.Switch(fake,"sport"))
            local parked=Store.Get().position.vehicleParking.sport
            assert(parked.x==110 and parked.z==65 and parked.yaw==90,"已交付车型不能随换车召回")
            reset()
            f.actor.parking.sport={x=110,z=65,yaw=90}
            f.city.obstacles={{x1=109,x2=111,z1=64,z2=66}}
            local revision=Store.Get().revision
            assert(not Actions.Switch(fake,"sport") and Store.Get().revision==revision and restores==0,"旧车被占用应拒绝且不改档")
            reset();failWrite=true
            revision=Store.Get().revision
            assert(not Actions.Switch(fake,"sport") and Store.Get().revision==revision and f.actor.vehicleId==Vehicles.EBIKE and restores==0,"保存失败不能提前切车")
            failWrite=false
            reset();pending=true
            revision=Store.Get().revision
            assert(Actions.Switch(fake,"sport") and snapshots==0 and queries==0,"资源未ready前不得取旧快照或读模型占地")
            pendingRequest.failed("模拟下载失败")
            assert(Store.Get().revision==revision and f.actor.vehicleId==Vehicles.EBIKE and restores==0,"下载失败必须完整保留原车原档")
            reset();pending=true
            assert(Actions.Switch(fake,"sport"))
            f.actor.x,f.actor.z=101,71;f.actor.bikeX=103
            pending=false;pendingRequest.completed()
            assert(Store.Get().position.x==101 and Store.Get().position.vehicleParking[Vehicles.EBIKE].x==103,"下载完成必须提交最新人物与停车快照")
            local committed=Store.Get().revision
            pendingRequest.completed()
            assert(Store.Get().revision==committed and restores==1,"重复完成回调不得再次提交")
            reset();pending=true
            assert(Actions.Switch(fake,"sport"))
            assert(Store.Transaction(function(p)p.ownedMotorcycles.sport=nil;return true end))
            revision=Store.Get().revision
            pending=false;pendingRequest.completed()
            assert(Store.Get().revision==revision and restores==0,"下载期间所有权变化必须重新校验")
        end)
    end,debug.traceback)
    cache=resourceCache;Loader.New=originalNew
    f:Dispose()
    assert(ok,message)
    print("[生产换车碰撞验收通过] 窄交车位/原车占位/玩家占位/保留旧停车与朝向/被占拒绝/写失败原子/下载前零形状查询/下载失败原子/下载后新快照/回调幂等/所有权重验；内存档隔离")
end
function Checks.Run(session)
    assert(session.options and session.options.test,"碰撞验收只允许隔离测试会话")
    local count=0
    liveFixtures={}
    local owned={}
    local function own(f,finished)
        owned[#owned+1]=f;count=count+1
        if finished then f:Dispose() end
        return f
    end
    local ok,message=xpcall(function()
        -- Analytic corner: old squared-radius code rejects this true rounded gap.
        assert(C.Free(C.Circle(-.25,-.25,.32),C.Box(0,0,1,1)),"Walking corner must be circular, not an inflated square")
        local t=C.Sweep(C.Circle(-2,.5,.32),C.Box(0,0,.001,1),5,0)
        assert(t and t>0 and t<1,"Continuous cast must catch a 1mm post between endpoints")
        for _,yaw in ipairs({0,37,90,143,180,270}) do
            own(gap(session.scene,true,yaw),true)
            own(gap(session.scene,false,yaw),true)
            for _,side in ipairs({"side","front","rear"}) do
                own(contact(session.scene,true,yaw,side),true)
                own(contact(session.scene,false,yaw,side),true)
            end
        end
        -- Too narrow for the measured bike but wide enough for walking. Not a
        -- global shrink: the box/mirror envelope remains physically present.
        local f=own(fixture(session.scene))
        local sedan,bike=F.Get("sedan"),F.Get("borrowed_ebike")
        local width=.50 -- below the measured bike shell, not only its sparse widest mirror
        f:Car(0,0,0);f:Wall(sedan.x1-width-.3,-3,sedan.x1-width,3)
        local side=sedan.x1-width/2-(bike.x1+bike.x2)/2
        f:Reset(side,-6,0,true);f:Drive(8,{throttle=.22})
        assert(f.actor.z< -1,"An under-width slot must block the complete bike including mirrors/cargo")
        -- Parked bike is a real independent obstacle; tangent walking close to
        -- its real side is allowed, stepping inward is stopped.
        f=own(fixture(session.scene));f:Reset(bike.x1-.32-.035,-3,0,false)
        f.actor.bikeX,f.actor.bikeZ,f.actor.bikeYaw=0,0,0
        f.actor:SyncVisuals(0)
        f:Drive(3.5,{walkY=1},0)
        assert(f.actor.z>3,"Walk must pass a parked bike 3.5cm beyond its visible side")
        f:Reset(-3,0,90,false);f.actor.bikeX,f.actor.bikeZ,f.actor.bikeYaw=0,0,0
        f:Drive(3,{walkY=1},90)
        assert(f.actor.x<-.3,"Independent parked bike must block walking inward at the local shell, not the distant mirror's global X minimum")
        -- Mount/dismount use target-only exclusion, not disabling all parking.
        f.actor.x,f.actor.z=bike.x1-.32-.08,0;f.actor.speed=0
        assert(f.actor:ToggleMount(),"Mount next to real bike shell must work")
        assert(f.actor:ToggleMount(),"Dismount should step out beyond the actual side")
        -- Static tiny pole and high initial speed still go through real Update.
        f=own(fixture(session.scene));f:Wall(-4,0,4,.001);f:Reset(0,-5,0,true)
        f.actor.speed=Actor.MAX_SPEED
        f:Drive(1,{throttle=1},0,.25)
        assert(f.actor.z<0,"High-speed Actor.Update must not cross a thin static barrier")
        -- Rotation-only sweep checks the whole turn, not endpoint yaw samples.
        local x,z=-3,0
        f=own(fixture(session.scene));f:Car(0,0,0);f:Reset(x,z,0,true)
        for _=1,20 do f.actor:Update(.1,{throttle=.4,steer=1}) end
        assert(f.city:IsShapeFree(f.actor.x,f.actor.z,f.actor:Footprint(),f.actor.yaw,"vehicle",0,f.actor.vehicleId))
    end,debug.traceback)
    for _,f in ipairs(liveFixtures) do f:Dispose() end
    liveFixtures={}
    assert(ok,message)
    Checks.RunSwitch(session)
    print(string.format("[CollisionChecks PASS] %d isolated real-input fixtures; visible white-car 5cm-per-side gap / walking circle / 6 yaw / fore-aft-side contact / cargo+mirror rejection / parked bike / mount / high-speed swept static post; no save writes",count))
end
function Checks.Shot(session,name)
    assert(session.options and session.options.test,"碰撞实拍只允许隔离测试会话")
    name=name or "ride-gap"
    for _,old in ipairs(shots) do old:Dispose() end
    shots={}
    local f
    if name=="contact" then f=contact(session.scene,true,0,"side")
    elseif name=="walk-gap" then f=gap(session.scene,false,0)
    elseif name=="yaw-gap" then f=gap(session.scene,true,37)
    elseif name=="parked" then
        f=fixture(session.scene)
        local bike=F.Get("borrowed_ebike")
        f:Reset(bike.x1-.32-.035,-3,0,false)
        f.actor.bikeX,f.actor.bikeZ,f.actor.bikeYaw=0,0,0
        f:Drive(1.65,{walkY=1},0)
    else f=gap(session.scene,true,0) end
    shots[#shots+1]=f
    -- After the PASS path, use INPUT to return to the tightest side contact
    -- station for photography; no teleport to a conveniently empty wide path.
    if name=="ride-gap" or name=="yaw-gap" or name=="cargo" then
        f.actor.speed=0
        local heading=math.rad(f.yaw or 0)
        local along=f.actor.x*math.sin(heading)+f.actor.z*math.cos(heading)
        local arrived=false
        for _=1,600 do
            if along<=.05 then arrived=true;break end
            f:Drive(.05,{throttle=-.55,steer=0},f.yaw or 0)
            along=f.actor.x*math.sin(heading)+f.actor.z*math.cos(heading)
        end
        assert(arrived,"摄影倒车输入未在30秒内返回窄隙中央，拒绝无限循环")
        f.actor.speed=0;f.actor:SyncVisuals(0)
    elseif name=="walk-gap" then
        local remaining=f.actor.z
        f:Drive(math.max(0,remaining)/1.8,{walkY=-1},0)
    end
    Parts.Add(f.root,"实拍窄通道地面","Box",session.city.mats.road,Vector3(-2,0,0),Vector3(15,.08,22),nil,false)
    session.city.root:SetEnabledRecursive(false)
    session.actor.visuals:SetCityVisible(false)
    session.actor.visuals.walkNode:SetEnabledRecursive(false)
    session.yaw,session.pitch=(f.yaw or 0)+20,31
    session.camera:SetMode("normal")
    session.camera:SetModeConfig("normal",{distance=8,offset=Vector3(0,1,0),fov=60})
    session.shotCameraTarget=f.actor.node
    session.camera:Update(1,f.actor.node,session.yaw,session.pitch)
    session:Refresh()
    session.view:ShowDialog("白车窄隙 · 隔离实拍",name,{})
    session.view.overlay:SetVisible(false)
    local report={name=name,gapWidth=f.gapWidth,clearancePerSide=f.gapWidth and .05 or nil,
        progress=f.progress,x=f.actor.x,z=f.actor.z,yaw=f.actor.yaw,mounted=f.actor.mounted,
        source="actual Actor.Update input; referenced visible LOD0 shell strips",skin=C.SKIN,saveWrites=0}
    print("[CollisionShot] "..require("cjson").encode(report))
    return report
end
return Checks
