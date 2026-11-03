-- 显式隔离Session专项：Actor.Update真输入走/骑，不以摄影Teleport冒充可达。
local Environment=require("Career.CityEnvironment")
local World=require("Career.WorldData")
local Store=require("Career.Store")
local Config=require("Career.Config")
local UI=require("urhox-libs/UI")
local Pointer=require("urhox-libs/UI/Core/PointerEvent")
---@class EnvironmentCheckTarget
---@field route table[]
local Checks={}
local function near(a,b,label,tolerance) assert(math.abs(a-b)<(tolerance or .00001),label or "环境数值不一致") end
local function isolated(session)
    assert(session.options and session.options.test==true and type(session.restoreTestStorage)=="function","环境验收只可在隔离内存Session执行")
end
local function clickText(view,text)
    local function find(w)
        if w.props.text==text and w.props.onClick then return w end
        for _,child in ipairs(w:GetChildren()) do local found=find(child);if found then return found end end
    end
    UI.Layout()
    local widget=assert(find(view.dialogBody),"缺生产按钮 "..text)
    local r=widget:GetAbsoluteLayout();assert(r.w>0 and r.h>0)
    local scale=UI.GetScale()
    local data={pointerId=790201,pointerType="touch",x=(r.x+r.w/2)*scale,y=(r.y+r.h/2)*scale,button=Pointer.Button.Left}
    UI.HandlePointerEvent(Pointer.new("PointerDown",data));UI.HandlePointerEvent(Pointer.new("PointerUp",data))
end
-- 单独纯数据入口：不创建Session、不访问Store；封边保留4m原地形，只把不可通边界做实。
function Checks.BoundaryPlan()
    assert(#Environment.BoundaryWalls==188,"两条752m边应有188节8m墙")
    local water=0
    for _,o in ipairs(Environment.StaticObstacles) do if o.kind=="water" then water=water+1 end end
    assert(water==3,"不得删除水域保护")
    local boxes={}
    local recorder={Box=function(_,mat,x,y,z,w,h,d)
        if mat=="concrete" then boxes[#boxes+1]={x1=x-w/2,x2=x+w/2,z1=z-d/2,z2=z+d/2,y1=y-h/2,y2=y+h/2} end
    end}
    assert(Environment.RenderBoundary(recorder,{x1=-1200,x2=-350,z1=-1200,z2=-350})==188)
    assert(#boxes==188,"可见墙节数和静态碰撞不一致")
    for i,wall in ipairs(Environment.BoundaryWalls) do
        for _,field in ipairs({"x1","x2","z1","z2","y1","y2"}) do near(wall[field],boxes[i][field],"封边视觉/碰撞轮廓不同源") end
        local cx,cz=(wall.x1+wall.x2)/2,(wall.z1+wall.z2)/2
        local cell=World.DescribeCell(math.floor(cx/256),math.floor(cz/256))
        local found=false
        for _,o in ipairs(cell.obstacles) do if o==wall then found=true end end
        assert(found,"逻辑碰撞不得依赖可见块加载")
        assert(wall.y1<=-.2 and wall.y2>=1.1,"墙未封住外侧0m地面")
        assert(not Environment.IsFree(cx,cz,.32,"walk",0),"墙内必须阻挡")
        local a,b={x=cx-2,z=cz},{x=cx+2,z=cz}
        if wall.z1< -1152 then a,b={x=cx,z=cz-2},{x=cx,z=cz+2} end
        assert(not Environment.SegmentFree(a,b,.32) and not Environment.SegmentFree(b,a,.32),"远边封墙必须双向阻挡")
    end
    -- 覆盖两条远边的坡顶4m、坡中、坡脚、接缝、海床和拐角，不能从任一方向跨突变。
    for _,s in ipairs({440,450,470,480,512,530,560,640,768,1024,1151.9}) do
        for _,axis in ipairs({"x","z"}) do
            local x,z=axis=="x" and -1152 or -s,axis=="z" and -1152 or -s
            local y=Environment.Height(x,z)
            assert(not World.IsFree(x,z,.32,"walk",y),"真实高度封边失效")
            assert(not World.IsFree(x,z,1.2,"vehicle",y),"车辆不能越封边")
        end
    end
    -- 靠城两边仍连续；仅允许5.5cm路缘，没有新增4m跳高或挡住原20m入口。
    for _,p in ipairs({{-400,-450},{-450,-400},{-400,-400},{-384,-384}}) do
        near(Environment.Surface(p[1],p[2]),.055,"入口地表必须平接")
        assert(Environment.IsFree(p[1],p[2],1.2),"原入口不得新增阻挡")
    end
    local a,b={x=-384,z=-384},{x=-430,z=-430}
    assert(Environment.SegmentFree(a,b,1.2) and Environment.SegmentFree(b,a,1.2),"保留入口双向可达")
    near(Environment.Surface(-450,-450),4,"不能削平岸丘掩盖边界问题")
    print("[海岸边界验收通过] 188节可见墙/逻辑AABB同源，4m岸丘及水域保护保留，双向封边与入口通行；未访问Store")
    return true
end
-- 主会话可在test Session单独调用；真实City碰撞入口，有限位移，无人物/停车/档案修改。
function Checks.BoundaryCollision(session)
    isolated(session)
    Checks.BoundaryPlan()
    local city=assert(session.city)
    assert(city.space=="city","边界碰撞检查要求city空间")
    for _,axis in ipairs({"x","z"}) do for _,direction in ipairs({-1,1}) do
        local x,z=axis=="x" and -1152+direction*2 or -450,axis=="z" and -1152+direction*2 or -450
        local dx,dz=axis=="x" and -direction*4 or 0,axis=="z" and -direction*4 or 0
        local height=Environment.Surface(x,z) or city:Surface(x,z)
        for _,mode in ipairs({"walk","vehicle"}) do
            local radius=mode=="walk" and .32 or 1.2
            local px,pz,blocked=city:Move(x,z,dx,dz,radius,mode,height)
            assert(blocked,"生产City.Move放行封边 "..mode)
            assert((axis=="x" and px+1152 or pz+1152)*direction>.2,"生产碰撞越过可见墙外轮廓")
        end
    end end
    print("[海岸边界真实碰撞通过] City.Move两轴双向、步行/车辆有限扫掠；未改人物/停车/存档")
    return true
end
function Checks.Plan()
    Checks.BoundaryPlan()
    local stats=require("Career.CityExpansionChecks").Plan()
    local triangles,maxCell=0,0
    for ix=-5,-2 do for iz=-5,-2 do
        local cell=World.DescribeCell(ix,iz)
        local n=Environment.TerrainTriangles(cell,function(_,a,b,c)
            for _,q in ipairs({{.2,.3,.5},{.7,.2,.1},{1/3,1/3,1/3}}) do
                local x,z=a.x*q[1]+b.x*q[2]+c.x*q[3],a.z*q[1]+b.z*q[2]+c.z*q[3]
                near(a.y*q[1]+b.y*q[2]+c.y*q[3],Environment.Height(x,z),"地形重心与Surface不共面")
            end
        end)
        triangles=triangles+n;maxCell=math.max(maxCell,n)
        for _,s in ipairs(cell.grounds) do
            assert(not Environment.Reserved(s),"旧平面覆盖岸坡或海水")
        end
        for _,b in ipairs(cell.buildings) do
            local w,depth=b.w,b.d;if b.yaw%180~=0 then w,depth=depth,w end
            assert(not Environment.Reserved({x1=b.x-w/2,x2=b.x+w/2,z1=b.z-depth/2,z2=b.z+depth/2}),"海岸覆盖既有楼")
        end
    end end
    assert(maxCell<4000 and #Environment.Props==27,"环境块预算/家具数改变")
    for _,p in ipairs(Environment.Points) do assert(Environment.IsFree(p.x,p.z,1.2),"海岸景点不净空") end
    for _,start in ipairs({{-450,-450},{-548,-548},{-676,-660},{-548,-800},{0,-350},{-250,-384}}) do
        for _,p in ipairs(Environment.Points) do
            local route=assert(Environment.NavigationRoute(p.id,start[1],start[2]),"海岸局部导航缺失")
            for i=2,#route do assert(Environment.SegmentFree(route[i-1],route[i],.8),"导航切入水域或家具") end
            if start[2]==-384 then for _,q in ipairs(route) do assert(q.z<=-380,"沿途导航不应倒回南门") end end
        end
    end
    local navigation=Environment.PrewarmNavigation()
    local builds=navigation.builds
    local samples={{-450,-450},{-548,-548},{-676,-660},{-548,-800},{-530,-700},{-480,-520},{-405,-405}}
    local started=os.clock()
    for i=1,100 do
        local p=samples[(i-1)%#samples+1]
        local route=assert(Environment.NavigationRoute("coast_pier",p[1],p[2]))
        for n=2,#route do assert(Environment.SegmentFree(route[n-1],route[n],.8),"缓存导航段失去精确净空") end
    end
    print(string.format("[海岸导航缓存验收] 首建CPU %.6fs / %d固定节点 / %d边 / 100次动态查询及全路径复核CPU %.6fs（非手机性能结论）",
        navigation.buildSeconds,navigation.nodes,navigation.edges,os.clock()-started))
    assert(Environment.NavigationStats().builds==builds,"动态导航重复建图")
    for _,p in ipairs({{-450,-450},{-676,-660},{0,-350},{-250,-384}}) do
        local route=assert(Environment.ExitRoute(p[1],p[2]))
        near(route[#route].x,0);near(route[#route].z,-172)
        for i=2,#route do assert(Environment.SegmentFree(route[i-1],route[i],.8),"退出导航穿过实物") end
        if p[1]==-250 then for _,q in ipairs(route) do assert(q.x>=-250,"tail回城不应先倒退海岸口") end end
    end
    near(Environment.Surface(-450,-450),4)
    assert(not Environment.IsFree(-600,-600,.32,"walk",.15),"真实水域须阻挡")
    assert(Environment.IsFree(-620,-660,1.2,"vehicle",.8),"真实栈桥须通行")
    stats.terrainTriangles,stats.maxCellTerrainTriangles=triangles,maxCell
    return stats
end
-- 路线从真实开局街到现有环街，再经平接入口、上坡、下坡、栈道、栈桥。
Checks.Path={{x=0,z=-20},{x=0,z=-384},{x=-384,z=-384},{x=-400,z=-400},
    {x=-450,z=-450},{x=-548,z=-548},{x=-548,z=-660},{x=-676,z=-660}}
local function travel(actor,path,mounted)
    local total=0
    for i=2,#path do
        local goal=path[i]
        local began=false
        for step=1,80000 do
            local dx,dz=goal.x-actor.x,goal.z-actor.z
            local left=math.sqrt(dx*dx+dz*dz)
            if left<.03 then actor.speed=0;break end
            local oldX,oldZ=actor.x,actor.z
            if mounted then
                local wanted=math.deg(math.atan(dx,dz))
                if not began then actor.yaw=actor:TurnTo(actor.x,actor.z,actor.yaw,wanted);began=true end
                near(((actor.yaw-wanted+180)%360)-180,0,"骑行转角被挡",.001)
                -- 2m/s目标，使用真实动力Update，临近目标精确截短本帧，绝不写位置。
                local dt=math.min(1/30,left/2)
                actor:Update(dt,{throttle=2/actor:MaxSpeed(),steer=0},actor.yaw)
            else
                local dt=math.min(1/30,left/3.4)
                actor:Update(dt,{walkX=dx/left,walkY=dz/left,run=true},0)
            end
            local moved=math.sqrt((actor.x-oldX)^2+(actor.z-oldZ)^2)
            assert(moved>.00000001,string.format("Actor.Update被挡 mounted=%s segment=%d step=%d from=(%.6f,%.6f) goal=(%.2f,%.2f) height=%.4f",
                tostring(mounted),i,step,oldX,oldZ,goal.x,goal.z,actor.walkHeight))
            total=total+moved
            local y=actor:GetPosition().y
            near(y,actor.city:Surface(actor.x,actor.z),"鞋底/轮胎未支撑坡面",.0001)
            assert(step<80000,"Actor连续输入超时")
        end
        print(string.format("[环境连续行进] %s segment%d 到(%.2f,%.2f) y=%.3f",mounted and "骑" or "步",i,actor.x,actor.z,actor:GetPosition().y))
    end
    return total
end
---@param session CareerSession
function Checks.Run(session)
    isolated(session)
    local phase="all"
    for _,arg in ipairs(GetArguments()) do
        local value=arg:match("^%-careerenvironmentphase=(.+)$")
        if value then phase=value end
    end
    assert(({all=true,["walk-out"]=true,["walk-back"]=true,["ride-out"]=true,["ride-back"]=true,["bridge-stream"]=true})[phase],"未知环境验收phase "..phase)
    local actor,city,view=session.actor,session.city,session.view
    local old={position=session:PositionSnapshot(),space=session.space,online=session.online,running=session.running,
        yaw=session.yaw,pitch=session.pitch,waypoint=session.waypoint,manual=session.manualWaypoint,
        traffic=city.traffic,people=city.deliveryPeople,crowd=city.crowd,speed=actor.speed,steer=actor.steer}
    local files,cloud={},0
    local restore=Store.UseTestStorage({read=function(path) return files[path],nil,files[path]==nil end,
        write=function(path,text) files[path]=text;return true end,
        cloud={Get=function() cloud=cloud+1;error("环境验收禁云") end,Set=function() cloud=cloud+1;error("环境验收禁云") end}})
    local ok,failure=pcall(function()
        local stats=Checks.Plan()
        assert(Store.NewCareer());session:ApplySpace("city");session.running=true;session.online=false
        city.traffic,city.deliveryPeople,city.crowd=nil,nil,nil
        actor.parking={};actor.mounted=false;actor.visuals:SetMounted(false)
        actor.bikeX,actor.bikeZ=20,-20
        local reverse={};for i=#Checks.Path,1,-1 do reverse[#reverse+1]=Checks.Path[i] end
        local distances={}
        local function movement(name,mounted,back)
            local path=back and reverse or Checks.Path
            local start=path[1]
            actor.mounted=mounted;actor.visuals:SetMounted(mounted)
            actor.bikeX,actor.bikeZ=mounted and start.x or 20,mounted and start.z or -20
            actor.bikeYaw=back and 90 or 180
            -- 每个独立phase只在起点设置夹具；之后全长由生产Actor.Update输入驱动。
            actor:Teleport(start.x,start.z,actor.bikeYaw,city:Surface(start.x,start.z))
            actor.speed=0
            session.waypoint=back and "bridge" or "coast_pier";session.manualWaypoint=true
            local target=assert(session:Target()) --[[@as EnvironmentCheckTarget]]
            for i=2,#target.route do
                local a,b=target.route[i-1],target.route[i]
                assert(city:StaticSegmentFree(a.x,a.z,b.x,b.z,.32,"walk",city:Surface(a.x,a.z)),"生产导航路线被挡 "..name)
            end
            print(string.format("[环境phase开始] %s 起点(%.2f,%.2f)，全程Actor.Update/真实视觉，不传送跨段",name,start.x,start.z))
            local started=os.clock()
            local distance=travel(actor,path,mounted)
            assert(distance>1219 and distance<1221,"未覆盖完整城到栈桥路线 "..name)
            distances[name]=distance
            print(string.format("[环境phase通过] %s / 连续%.2fm / CPU %.3fs / Plan与31单不变；仅本phase，不代表其余phase通过",
                name,distance,os.clock()-started))
        end
        if phase=="all" or phase=="walk-out" then movement("walk-out",false,false) end
        if phase=="all" or phase=="walk-back" then movement("walk-back",false,true) end
        if phase=="all" or phase=="ride-out" then movement("ride-out",true,false) end
        if phase=="all" or phase=="ride-back" then movement("ride-back",true,true) end
        if phase=="all" or phase=="bridge-stream" then
        print("[环境phase开始] bridge-stream / 水域栈桥、坡上恢复、桥下交互、流式重载")
        -- 栈桥尽头驶出必须被真实水域挡住，不能漂在海水Surface上。
        local x,z,blocked=city:MoveShape(-676,-660,-20,0,actor:Footprint(true),-90,"vehicle",.8,actor.vehicleId)
        assert(blocked and x>=-684 and math.abs(z+660)<.01,"栈桥尽头未阻水")
        actor.mounted=false;actor.visuals:SetMounted(false)
        local position=session:PositionSnapshot()
        position.x,position.z,position.yaw=-450,-450,0;position.mounted=false;position.groundHeight=4
        position.bikeX,position.bikeZ=-455,-455
        -- PositionSnapshot含车辆停车真源；移动夹具车位必须同步活动车记录，不能伪造不一致档。
        local active=position.activeVehicle or require("Career.VehicleData").EBIKE
        position.vehicleParking=position.vehicleParking or {}
        position.vehicleParking[active]={x=position.bikeX,z=position.bikeZ,yaw=position.bikeYaw}
        assert(Store.SetPosition(position));session:RestorePosition()
        near(actor.x,-450,"坡上恢复X");near(actor.z,-450,"坡上恢复Z");near(actor:GetPosition().y,4,"坡上读档高度丢失")
        actor.parking={}
        actor.bikeX,actor.bikeZ,actor.bikeYaw=-450,-450,0
        actor:Teleport(-449,-450,0,4)
        assert(actor:ToggleMount(),"地表海拔4m不应被误认成天桥禁止上车")
        actor:SyncVisuals(.2)
        actor.visuals:Update(.2,8,1,actor.bikeX,4,actor.bikeZ,actor.bikeYaw,0)
        assert(actor.visuals.lean<0,"右转压弯必须朝弯内")
        assert(actor:ToggleMount(),"高地车辆必须能正常下车")
        session.waypoint="coast_pier";session.manualWaypoint=true
        local target=assert(session:Target(),"生产海岸导航缺失") --[[@as EnvironmentCheckTarget]]
        local route=assert(target.route)
        for i=2,#route do assert(Environment.SegmentFree(route[i-1],route[i],.8),"生产导航切入海水") end
        -- 实际现场Interact与真实UI触摸：取消无写入，离开后确认重检，在路外免费过夜。
        local bridge=assert(require("Career.HousingData").Get("bridge"))
        actor.bikeX,actor.bikeZ=20,-20;actor:Teleport(bridge.x,bridge.z,0);actor.speed=0
        view:ClosePhone();view:ShowGame()
        local before=Store.Get();local day,cash,revision=before.day,before.cashCents,before.revision
        session:Interact();assert(view.blocked);clickText(view,"先不休息")
        assert(Store.Get().revision==revision and Store.Get().day==day and Store.Get().cashCents==cash,"取消休息有副作用")
        session:Interact();actor:Teleport(0,-85,0);clickText(view,"确认在桥下休息")
        assert(Store.Get().day==day and Store.Get().cashCents==cash,"远离桥下仍能确认过夜")
        actor:Teleport(bridge.x,bridge.z,0);session:Interact();clickText(view,"确认在桥下休息")
        assert(Store.Get().day==day+1 and Store.Get().cashCents==cash,"桥下现场免费过夜失败/扣款")
        clickText(view,"出发")
        local stream=city.stream
        stream:Ensure(-548,-548,550);local first=stream:Stats();local nodes=stream.root:GetNumChildren(true)
        stream:Ensure(-548,-548,550);local second=stream:Stats()
        assert(first.failed==0 and first.active<=80 and first.loaded==second.loaded and nodes==stream.root:GetNumChildren(true),"海滨流式重复增长/失败")
        stream:Unload("-3:-3");stream:Ensure(-548,-548,550)
        local after=stream:Stats()
        assert(after.failed==0 and after.active<=80 and after.loaded==second.loaded+1,"环境块重载失败")
        print(string.format("[环境phase通过] bridge-stream / 岸丘4m恢复、水域阻挡、桥下真实确认取消与免费过夜、流式重载 / 地形%d面、每块最多%d面；仅本phase",
            stats.terrainTriangles,stats.maxCellTerrainTriangles))
        end
        assert(cloud==0)
        if phase=="all" then
            print(string.format("[环境全部phase通过] 步出%.2fm/步返%.2fm/骑出%.2fm/骑返%.2fm + bridge-stream / 31单不变 / 内存禁云",
                distances["walk-out"],distances["walk-back"],distances["ride-out"],distances["ride-back"]))
        end
    end)
    local clean,cleanup=pcall(function()
        city.traffic,city.deliveryPeople,city.crowd=old.traffic,old.people,old.crowd
        view:ClosePhone();view:ShowGame();session:ApplySpace("city")
        actor.mounted=old.position.mounted;actor:RestoreVehicles(old.position);actor.visuals:SetMounted(actor.mounted)
        session:ApplySpace(old.space)
        actor:Teleport(old.position.x,old.position.z,old.position.yaw,old.position.groundHeight)
        actor.speed,actor.steer=old.speed,old.steer
        session.online,session.running=old.online,old.running
        session.yaw,session.pitch,session.waypoint,session.manualWaypoint=old.yaw,old.pitch,old.waypoint,old.manual
    end)
    restore()
    if not ok then error(failure,0) end
    if not clean then error(cleanup,0) end
    session:Refresh()
    return true
end
function Checks.Shot(session,name)
    isolated(session)
    local allowed=false
    for _,arg in ipairs(GetArguments()) do if arg=="-careerenvironmentshot="..name then allowed=true end end
    assert(allowed,"环境摄影必须显式参数")
    local positions={bridge={0,-57,180,8},coast={-450,-450,-135,10},beach={-548,-588,-135,9},pier={-676,-660,-90,8}}
    local p=assert(positions[name],"未知环境摄影点")
    local a,city=session.actor,session.city
    session:ApplySpace("city");session.online=false;session.waypoint=""
    if session.traffic then session.traffic.active=false end
    city.stream:Ensure(p[1],p[2],550)
    a.mounted=false;a.visuals:SetMounted(false);a.bikeX,a.bikeZ=p[1]+6,p[2]+6
    a:Teleport(p[1],p[2],p[3],Environment.Surface(p[1],p[2]) or 0);a.speed,a.steer=0,0
    session:UpdateEnvironment(12);session.yaw,session.pitch=p[3],p[4]
    session.camera:SetModeConfig("normal",{distance=7.8,offset=Vector3(0,1.4,0),fov=60})
    session.camera:SetMode("normal");session.camera:Update(2,a.node,session.yaw,session.pitch)
    session.view:ClosePhone();session.view:ShowGame();session.view:ResetInput();session:Refresh();session.view.overlay:SetVisible(false)
    print(string.format("[环境摄影就绪] %s (%.1f,%.1f) 仅摄影传送；可达性由独立Actor.Update专项验收",name,p[1],p[2]))
end
return Checks
