-- 显式隔离Session专项：Actor.Update真输入走/骑，不以摄影Teleport冒充可达。
local Environment=require("Career.CityEnvironment")
local World=require("Career.WorldData")
local Store=require("Career.Store")
local Config=require("Career.Config")
local UI=require("urhox-libs/UI")
local Pointer=require("urhox-libs/UI/Core/PointerEvent")
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
function Checks.Plan()
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
        actor:Teleport(0,-20,180) -- 仅fixture初始化；下列完整线路没有Teleport/改XZ。
        session.waypoint="coast_pier";session.manualWaypoint=true
        local startTarget=assert(session:Target())
        for i=2,#startTarget.route do
            local a,b=startTarget.route[i-1],startTarget.route[i]
            assert(city:StaticSegmentFree(a.x,a.z,b.x,b.z,.32,"walk",city:Surface(a.x,a.z)),"生产开局导航路线被挡")
        end
        local walk=travel(actor,Checks.Path,false)
        local reverse={};for i=#Checks.Path,1,-1 do reverse[#reverse+1]=Checks.Path[i] end
        travel(actor,reverse,false)
        actor.bikeX,actor.bikeZ,actor.bikeYaw=actor.x,actor.z,actor.yaw
        actor.mounted=true;actor.visuals:SetMounted(true);actor.speed=0
        local ride=travel(actor,Checks.Path,true)
        assert(walk>1200 and ride>1200,"不能只验入口到海滩")
        -- 栈桥尽头驶出必须被真实水域挡住，不能漂在海水Surface上。
        local x,z,blocked=city:MoveShape(-676,-660,-20,0,actor:Footprint(true),-90,"vehicle",.8,actor.vehicleId)
        assert(blocked and x>=-684 and math.abs(z+660)<.01,"栈桥尽头未阻水")
        actor.mounted=false;actor.visuals:SetMounted(false)
        local position=session:PositionSnapshot()
        position.x,position.z,position.yaw=-450,-450,0;position.mounted=false;position.groundHeight=4
        position.bikeX,position.bikeZ=-455,-455
        assert(Store.SetPosition(position));session:RestorePosition()
        near(actor.x,-450,"坡上恢复X");near(actor.z,-450,"坡上恢复Z");near(actor:GetPosition().y,4,"坡上读档高度丢失")
        session.waypoint="coast_pier";session.manualWaypoint=true
        local target=assert(session:Target(),"生产海岸导航缺失")
        local route=assert(target.route)
        for i=2,#route do assert(Environment.SegmentFree(route[i-1],route[i],.8),"生产导航切入海水") end
        -- 实际现场Interact与真实UI触摸：取消无写入，离开后确认重检，在原点免费过夜。
        actor.bikeX,actor.bikeZ=20,-20;actor:Teleport(0,-70,0);actor.speed=0
        view:ClosePhone();view:ShowGame()
        local before=Store.Get();local day,cash,revision=before.day,before.cashCents,before.revision
        session:Interact();assert(view.blocked);clickText(view,"先不休息")
        assert(Store.Get().revision==revision and Store.Get().day==day and Store.Get().cashCents==cash,"取消休息有副作用")
        session:Interact();actor:Teleport(0,-85,0);clickText(view,"确认在桥下休息")
        assert(Store.Get().day==day and Store.Get().cashCents==cash,"远离桥下仍能确认过夜")
        actor:Teleport(0,-70,0);session:Interact();clickText(view,"确认在桥下休息")
        assert(Store.Get().day==day+1 and Store.Get().cashCents==cash,"桥下现场免费过夜失败/扣款")
        clickText(view,"出发")
        local stream=city.stream
        stream:Ensure(-548,-548,550);local first=stream:Stats();local nodes=stream.root:GetNumChildren(true)
        stream:Ensure(-548,-548,550);local second=stream:Stats()
        assert(first.failed==0 and first.active<=80 and first.loaded==second.loaded and nodes==stream.root:GetNumChildren(true),"海滨流式重复增长/失败")
        stream:Unload("-3:-3");stream:Ensure(-548,-548,550)
        local after=stream:Stats()
        assert(after.failed==0 and after.active<=80 and after.loaded==second.loaded+1,"环境块重载失败")
        assert(cloud==0)
        print(string.format("[环境验收通过] Actor.Update开局步骑各%.1f/%.1fm，岸丘4m，地形%d面/最多%d每块，水域阻挡/栈桥/坡上恢复/桥下真实确认取消与免费过夜/31单不变/内存禁云",
            walk,ride,stats.terrainTriangles,stats.maxCellTerrainTriangles))
    end)
    local clean,cleanup=pcall(function()
        city.traffic,city.deliveryPeople,city.crowd=old.traffic,old.people,old.crowd
        view:ClosePhone();view:ShowGame();session:ApplySpace(old.space)
        actor.mounted=old.position.mounted;actor:RestoreVehicles(old.position);actor.visuals:SetMounted(actor.mounted)
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
