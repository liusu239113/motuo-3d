-- 隔离生涯内存档中的真实交通测试，不写入玩家档。
local Routes=require("Career.TrafficRoutes")
local Traffic=require("Career.Traffic")
local Checks={}
function Checks.Run(session)
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
    -- 玩家站在车道内，交通不可穿过；玩家侧向进入也被同一OBB阻挡。
    car.s,car.speed=70,5; t:Place(car); t.time=0
    actor.x,actor.z=car.x,car.z+12
    for _=1,80 do t:Update(.1) end
    assert(Traffic.CircleFree(car,actor.x,actor.z,.32) and car.z<actor.z,"车必须让停行人")
    assert(not t:IsFree(car.x,car.z,.32),"车辆实体必须进入City碰撞域")
    local x,z=session.city:Move(car.x+5,car.z,-5,0,.32)
    assert(x>car.x+car.width/2+.3 and math.abs(z-car.z)<.01,"玩家不可侧穿车身")
    -- 停放车辆同样有占用，不因玩家远离而被交通穿过。
    actor.x,actor.z=-50,-50
    actor.bikeX,actor.bikeZ=car.x,car.z+10
    for _=1,80 do t:Update(.1) end
    assert(Traffic.CircleFree(car,actor.bikeX,actor.bikeZ,actor:VehicleRadius()))
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
    -- 临时取消测试模式的早退，才能证明Session生产Update确实被暂停拦截。
    local testMode=session.options.test
    session.options.test=false
    session.view:ShowDialog("交通暂停检查","",{})
    session:Update(.2)
    session.options.test=testMode
    assert(t.time==clock and all[1].s==s,"手机/暂停应冻结交通")
    session.view:ShowGame()
    session.city:SetSpace("hostel")
    t:Update(.2)
    assert(t.time==clock,"室内必须停模拟")
    assert(not t.root.enabledEffective,"室内不可显示动态交通")
    session.city:SetSpace("city")
    assert(t.root.enabledEffective,"出屋必须恢复动态交通")
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
