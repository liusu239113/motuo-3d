-- 隔离生涯内存档中的真实交通测试，不写入玩家档。
local Routes=require("Career.TrafficRoutes")
local Traffic=require("Career.Traffic")
local Collision=require("Career.FootprintCollision")
local Footprints=require("Career.VehicleFootprints")
local Riders=require("Career.TrafficRiders")
local Contact=require("Career.VehicleContact")
local Checks={}

-- Test only through isolated Session.New({test=true}); never a real player save.
function Checks.Riders(session)
    assert(session.options.test==true and type(session.restoreTestStorage)=="function","TrafficChecks requires isolated memory storage")
    local traffic=assert(session.traffic)
    assert(#traffic.cars==15,"riders must replace slots, not add a second city pool")
    local kinds,count={},0
    for _,car in ipairs(traffic.cars) do
        local visual=car.riding --[[@as TrafficRiderVisual?]]
        if visual then
            count=count+1;kinds[visual.kind]=true
            local rider=visual.rider
            assert(car.id==nil and car.vehicleId==visual.vehicleId,"composite collision must not retain a car/truck id")
            assert(car.node==visual.node and rider.parent==car.node and rider.node:IsEnabled(),"rider missing from traffic hierarchy")
            assert(rider.model:GetSkeleton():GetNumBones()==41 and rider.model.numAnimationStates==0,"must reuse actual posed skeleton, not a placeholder")
            local expected=visual.kind=="delivery" and require("Career.Rig").ModelPath or require("Rider").ModelPath
            assert(rider.model:GetModel()==cache:GetResource("Model",expected),"wrong rider asset (no default cartoon fallback)")
            local pose=rider:ReadPose()
            assert((pose.hip-rider.config.hip):Length()<.002 and pose.leftGripError<.005 and pose.rightGripError<.005,"rider detached from seat/handlebar")
            assert((pose.rightFoot-rider.config.foot):Length()<.002,"foot detached from existing footpeg target")
            assert(pose.head.y>pose.hip.y+.2 and pose.leftHand.y>pose.leftFoot.y+.3,"rider not in a real seated ride pose")
            if visual.kind=="delivery" then
                local cargo=assert(visual.cargo,"delivery rider requires independent visible food box")
                assert(cargo:IsEnabled() and cargo.parent==car.node,"delivery box must follow the same recycled traffic root")
            else assert(not visual.cargo,"ordinary motorcycle must not be a delivery clone") end
            local skin=Riders.SkinBounds(rider)
            assert(skin.min.y>.15 and skin.max.y<2.3 and skin.size.x<1.2,"skin exploded or boots intersect ground")
            assert((skin.min-visual.skinBounds.min):Length()<.00001 and (skin.max-visual.skinBounds.max):Length()<.00001,"cached posed envelope changed")
            assert(car.width<1.25 and car.length<3.1 and car.length>1.9,"rider retained oversized automobile collision")
            assert(math.abs(car.width-visual.width)<.00001 and math.abs(car.length-visual.length)<.00001,"following dimensions disagree with visible rider envelope")
            local localShape=Collision.Box(-car.width/2,-car.length/2,car.width/2,car.length/2)
            -- +/-6deg Contact pitch, yaw and seam/turn orientation must all fit.
            for _,pitch in ipairs({-6,0,6}) do
                local rot=Quaternion(pitch,Vector3.RIGHT)
                for _,bb in ipairs({skin,visual.bounds}) do
                    for _,x in ipairs({bb.min.x,bb.max.x}) do for _,y in ipairs({bb.min.y,bb.max.y}) do
                        for _,z in ipairs({bb.min.z,bb.max.z}) do
                            local p=rot*Vector3(x,y,z)
                            assert(p.x>=localShape.x1-.001 and p.x<=localShape.x2+.001 and p.z>=localShape.z1-.001 and p.z<=localShape.z2+.001,"posed rider escaped composite footprint")
                        end
                    end end
                end
            end
            local tyreMin,tyreMax=math.huge,-math.huge
            ---@type table[]
            local wheels=assert(Contact.Wheels[car.vehicleId])
            for _,wheel in ipairs(wheels) do
                local minimum=math.huge
                for _,p in ipairs(wheel.points) do
                    local world=car.node.worldTransform*p
                    minimum=math.min(minimum,world.y-session.city:Surface(world.x,world.z))
                end
                tyreMin,tyreMax=math.min(tyreMin,minimum),math.max(tyreMax,minimum)
            end
            assert(tyreMin>=-.002 and tyreMax<.015,"rider bike tyres must contact real City road (no floating or penetration)")
            local shape=Traffic.Shape(car)
            local posed=Collision.Pose(localShape,car.x,car.z,car.yaw)
            assert(math.abs(shape.x1-posed.x1)+math.abs(shape.x2-posed.x2)+math.abs(shape.z1-posed.z1)+math.abs(shape.z2-posed.z2)<.00001,"production TrafficMotion bypassed rider composite")
            assert(not traffic:IsFree(car.x,car.z,.1),"rider missing from production collision query")
            assert(visual.poseSolves==1,"resident riders should not add a per-frame IK clock")
            print(string.format("[NPC骑手验收] %s %.3fx%.3fm skinY[%.3f,%.3f] tyre[%.6f,%.6f] grip %.6f/%.6f",visual.kind,car.width,car.length,skin.min.y,skin.max.y,tyreMin,tyreMax,pose.leftGripError,pose.rightGripError))
        end
    end
    assert(count==Riders.BUDGET and kinds.motorcycle and kinds.delivery,"near-street traffic needs one ordinary motorcycle and one delivery rider")
end

-- 侧撞判定必须贴真实局部车壳，不能把后视镜的全车最大宽度投成整片墙。
-- 俯视：外侧O --> /斜侧壳|；接触后允许沿斜侧壳切向滑动，不允许向内侵入。
-- 同时证明三件事：完整输入段确实命中；返回点不重叠；从返回点再向
-- 车心推进2cm必进入同一可见壳。不能以远处提前停车或放宽bbox阈值过关。
local function checkShellContact(city,car,ax,az,dx,dz,label)
    local shell=Traffic.Shape(car)
    local start=Collision.Circle(ax,az,.32)
    assert(Collision.Free(start,shell,Collision.SKIN),label.."：输入起点不得落在车壳内")
    assert(Collision.Sweep(start,shell,dx,dz),label.."：完整输入必须真实命中车壳，不能验证绕开的宽路径")
    local x,z,blocked=city:Move(ax,az,dx,dz,.32,"walk",0)
    assert(blocked,label.."：City连续扫掠应报告实际碰撞")
    assert(Traffic.CircleFree(car,x,z,.32) and Collision.Free(Collision.Circle(x,z,.32),shell,Collision.SKIN),
        label.."：玩家终点不得穿入同源可见轮廓")
    local ix,iz=car.x-x,car.z-z
    local length=math.sqrt(ix*ix+iz*iz)
    assert(length>.02 and not Collision.Free(Collision.Circle(x+ix/length*.02,z+iz/length*.02,.32),shell,Collision.SKIN),
        label.."：返回点必须真正贴壳，不能远处空气墙提前拦停")
    -- 相同生产Move按0.1m输入逐段重放，每次提交都验证非穿透；不是仅看最终点。
    local count=math.max(1,math.ceil(math.sqrt(dx*dx+dz*dz)/.1))
    local px,pz=ax,az
    for _=1,count do
        local nx,nz=city:Move(px,pz,dx/count,dz/count,.32,"walk",0)
        assert(Collision.Free(Collision.Circle(nx,nz,.32),shell,Collision.SKIN),label.."：中间提交不得穿车")
        px,pz=nx,nz
    end
    assert(math.abs(px-x)+math.abs(pz-z)<.0001,label.."：长输入与连续小步必须得到相同接触点")
    return x,z
end
function Checks.Run(session)
    Checks.Riders(session)
    local t=session.traffic
    local actor=session.actor
    local all=t.cars
    local original={x=actor.x,z=actor.z,mounted=actor.mounted,bx=actor.bikeX,bz=actor.bikeZ}
    actor.x,actor.z,actor.bikeX,actor.bikeZ=-50,-50,-52,-50
    actor.mounted=false
    t.active=true
    for _,axis in ipairs({"ns","ew"}) do
        assert(Routes.Signal(16,axis)~="green" or axis=="ew")
    end
    for i=0,839 do
        local ns,ew=Routes.Signal(i*.05,"ns"),Routes.Signal(i*.05,"ew")
        assert(not(ns=="green" and ew=="green"),"交叉方向不可同时绿灯")
    end
    assert(Routes.Signal(16,"ns")=="yellow" and Routes.Signal(19,"ns")=="red")
    assert(Routes.Signal(20,"ew")=="red" and Routes.Signal(21,"ew")=="green")
    local car=all[4] -- 固定为中轴南北向车辆，单车验证停止线及恢复。
    local snapshots={}
    for i,c in ipairs(all) do snapshots[i]={s=c.s,speed=c.speed} end
    -- Exercise BOTH replacement slots using the same production red-light,
    -- player/parking/static and following path, not a parallel rider simulator.
    for _,riderCar in ipairs(all) do
        if riderCar.riding then
            t.cars={riderCar};riderCar.s,riderCar.speed=120,5;t:Place(riderCar)
            t.time=riderCar.route.axis=="ns" and 21 or 0
            local line=155-12-riderCar.length/2
            for _=1,100 do t:Update(.1) end
            assert(riderCar.s<=line+.001 and line-riderCar.s<.15,"rider front must stop at shared red line")
            local waitingRider=riderCar.s
            t.time=riderCar.route.axis=="ns" and 42 or 21
            for _=1,30 do t:Update(.1) end
            assert(riderCar.s>waitingRider+3,"rider must restart on green")
        end
    end
    t.cars=all
    for i,c in ipairs(all) do c.s,c.speed=snapshots[i].s,snapshots[i].speed;t:Place(c) end
    t.cars={car}
    car.s,car.speed=125,5
    t:Place(car); t.time=21
    local stop=155-12-car.length/2
    for _=1,100 do t:Update(.1) end
    assert(car.s<=stop+.001 and stop-car.s<.15,"红灯车头必须停在停止线外")
    local waiting=car.s
    t.time=42
    for _=1,30 do t:Update(.1) end
    assert(car.s>waiting+3,"绿灯须恢复行驶")
    -- 玩家站在车道内，交通不可穿过；玩家侧向输入由同源可见车壳扫掠阻挡。
    car.s,car.speed=70,5; t:Place(car); t.time=0
    actor.x,actor.z=car.x,car.z+12
    for _=1,80 do t:Update(.1) end
    assert(Traffic.CircleFree(car,actor.x,actor.z,.32) and car.z<actor.z,"车必须让停行人")
    assert(not t:IsFree(car.x,car.z,.32),"车辆实体必须进入City碰撞域")
    checkShellContact(session.city,car,car.x+5,car.z,-5,0,"真实玩家侧向输入")
    -- 停放车辆同样有占用，不因玩家远离而被交通穿过。
    actor.x,actor.z=-50,-50
    actor.bikeX,actor.bikeZ=car.x,car.z+10
    for _=1,80 do t:Update(.1) end
    assert(Collision.Free(Traffic.Shape(car),Footprints.At(actor.vehicleId,actor.bikeX,actor.bikeZ,actor.bikeYaw),Collision.SKIN),
        "交通不得穿过同源真实停放车辆占地")
    -- 前车静止时，后车保持间隔；不依赖模型渲染才有效。
    actor.bikeX,actor.bikeZ=-52,-50
    local leader=all[5]
    t.cars={car,leader}
    local oldRoute,oldId=leader.route,leader.routeId
    leader.route,leader.routeId=car.route,car.routeId
    car.s,car.speed=50,6; leader.s,leader.speed,leader.cruise=65,0,0
    t:Place(car);t:Place(leader);t.time=0
    for _=1,70 do t:Update(.1) end
    assert(Traffic.Separate(car,leader) and leader.s-car.s>(car.length+leader.length)/2+1.8,"跟车留出间隔")
    leader.route,leader.routeId,leader.cruise=oldRoute,oldId,5.5+(2+2)%3
    t.cars=all
    for i,c in ipairs(all) do c.s,c.speed=snapshots[i].s,snapshots[i].speed; t:Place(c) end
    actor.x,actor.z,actor.mounted=original.x,original.z,original.mounted
    actor.bikeX,actor.bikeZ=original.bx,original.bz
    t.time=0
    -- 多车连续模拟一整轮信号，逐步检验OBB互不重叠和行人不穿建筑。
    local travelled=0
    for _=1,460 do
        local s=all[1].s
        t:Update(.1)
        travelled=travelled+(all[1].s-s)%Routes.LENGTH
        for i,a in ipairs(all) do
            for j=i+1,#all do assert(Traffic.Separate(a,all[j]),"交通车重叠") end
        end
        for _,p in ipairs(t.pedestrians.people) do
            assert(session.city:StaticFree(p.x,p.z,.32),"行人路线穿建筑")
        end
    end
    assert(travelled>10,"连续运行不能全部堵死")
    local clock,s=t.time,all[1].s
    ---@type {car:table,s:number,position:Vector3,hip:Vector3}[]
    local frozenRiders={}
    for _,c in ipairs(all) do if c.riding then frozenRiders[#frozenRiders+1]={car=c,s=c.s,position=c.node.position,hip=c.riding.rider:GetBonePosition("Hip")} end end
    local function riderFrozen()
        for _,saved in ipairs(frozenRiders) do
            local c=saved.car
            local position=c.node.position --[[@as Vector3]]
            local hip=c.riding.rider:GetBonePosition("Hip") --[[@as Vector3]]
            assert(c.s==saved.s and (position-saved.position):Length()<.00001
                and (hip-saved.hip):Length()<.00001,"pause advanced rider movement/pose")
        end
    end
    -- 临时取消测试模式的早退，才能证明Session生产Update确实被暂停拦截。
    local testMode=session.options.test
    session.options.test=false
    session.view:ShowDialog("交通暂停检查","",{})
    session:Update(.2)
    session.options.test=testMode
    assert(t.time==clock and all[1].s==s,"手机/暂停应冻结交通")
    riderFrozen()
    session.view:ShowGame()
    session.city:SetSpace("hostel")
    t:Update(.2)
    assert(t.time==clock,"室内必须停模拟")
    assert(not t.root:IsEnabled(),"室内不可显示动态交通")
    riderFrozen()
    for _,saved in ipairs(frozenRiders) do assert(not saved.car.riding.rider.node:IsEnabled(),"indoor rider remains visible") end
    session.city:SetSpace("city")
    assert(t.root:IsEnabled(),"出屋必须恢复动态交通")
    for _,saved in ipairs(frozenRiders) do assert(saved.car.riding.rider.node:IsEnabled(),"rider not restored after leaving interior") end
    for i,c in ipairs(all) do c.s,c.speed=snapshots[i].s,0; t:Place(c) end
    t.time=0; session.city.signals:Update(0)
    print("[老街交通验收通过] 互斥信号/黄灯全红/停止线车头/绿灯起步/玩家避让/停车避让/实体侧撞/跟车/46秒多车无重叠/行人不穿楼/暂停室内冻结")
end
function Checks.Shot(session,seconds)
    local t=session.traffic
    t.active=true
    session.actor.mounted=false; session.actor.speed=0
    session.actor.bikeX,session.actor.bikeZ=-15,-18
    session.actor:Teleport(7.8,-18,0)
    -- 实拍将真实车辆置于中央路口的来车段，避免首车离镜头百余米。
    for i,car in ipairs(t.cars) do
        car.s=car.route.axis=="ns" and 126+(i%3)*14 or 112+(i%3)*16
        car.speed=0
        t:Place(car)
    end
    t.time=0
    for _,p in ipairs(t.pedestrians.people) do p.s=p.length*.75; t.pedestrians:Place(p) end
    for _=1,math.floor(seconds*10) do t:Update(.1) end
    session.city.signals:Update(t.time)
    session.yaw,session.pitch=15,12
    session.camera:SetModeConfig("normal",{distance=13,offset=Vector3(0,2,0),fov=65})
    session.camera:Update(1,session.actor.node,session.yaw,session.pitch)
    session:Refresh()
    session.view:ShowDialog("交通实拍","固定模拟秒数",{})
    session.view.overlay:SetVisible(false)
    print(string.format("[交通实拍] %.1fs 首车s%.2f 信号%s/%s",seconds,t.cars[1].s,Routes.Signal(t.time,"ns"),Routes.Signal(t.time,"ew")))
end
return Checks
