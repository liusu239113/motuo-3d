-- 山地与性能回归，复用真实City/车辆轮廓，不改生产存档。
local Checks={}
local function geometryChecks()
    local Hills=require("Career.HillDistrict")
    local World=require("Career.WorldData")
    local hillTriangles,maxHillTriangles,maxInteriorError,maxQuantizationBound=0,0,0.0,0.0
    -- IEEE754 binary32 round-to-nearest：坐标误差<=0.5ULP。
    -- 裁片原来同属一个原格三角。XZ舍入后再投影Height，顶点和重心两次位移
    -- 各最多Lx*ex+Lz*ez；加Y舍入ey，得到严格局部Lipschitz上界。
    local function halfUlp(v)
        local a=math.abs(v)
        if a<2^-126 then return 2^-150 end
        return 2^(math.floor(math.log(a)/math.log(2))-24)
    end
    ---@type table<number,table<number,{x:number,z:number}>>
    local slopes={}
    for i=2,#Hills.X do
        slopes[i]={}
        for j=2,#Hills.Z do
            local l,r,n,f=Hills.X[i-1],Hills.X[i],Hills.Z[j-1],Hills.Z[j]
            local a,b,c,d=Hills.Height(l,n),Hills.Height(l,f),Hills.Height(r,n),Hills.Height(r,f)
            slopes[i][j]={x=math.max(math.abs(c-a),math.abs(d-b))/(r-l),
                z=math.max(math.abs(b-a),math.abs(d-c))/(f-n)}
        end
    end
    local function index(values,v)
        local lo,hi=2,#values
        while lo<hi do local mid=(lo+hi)//2;if v<=values[mid] then hi=mid else lo=mid+1 end end
        return lo
    end
    local function quantizationBound(a,b,c)
        local ex=math.max(halfUlp(a.x),halfUlp(b.x),halfUlp(c.x))
        local ez=math.max(halfUlp(a.z),halfUlp(b.z),halfUlp(c.z))
        local ey=math.max(halfUlp(a.y),halfUlp(b.y),halfUlp(c.y))
        local x1,x2=math.min(a.x,b.x,c.x)-ex,math.max(a.x,b.x,c.x)+ex
        local z1,z2=math.min(a.z,b.z,c.z)-ez,math.max(a.z,b.z,c.z)+ez
        local lx,lz=0.0,0.0
        for i=index(Hills.X,x1),index(Hills.X,x2) do
            for j=index(Hills.Z,z1),index(Hills.Z,z2) do
                local s=slopes[i][j];lx=math.max(lx,s.x);lz=math.max(lz,s.z)
            end
        end
        return 2*(lx*ex+lz*ez)+ey+1e-9
    end
    for ix=-2,1 do for iz=1,6 do
        local cell=World.DescribeCell(ix,iz)
        local triangles=0
        local builder={Triangle=function(_,mat,a,b,c)
            local cross=math.abs((b.x-a.x)*(c.z-a.z)-(b.z-a.z)*(c.x-a.x))
            if cross>1e-8 then triangles=triangles+1 end
            local lift=mat=="grass" and 0 or .055
            for _,v in ipairs({a,b,c}) do
                local expected=Hills.Height(v.x,v.z)+lift
                assert(math.abs(v.y-expected)<.00003,string.format(
                    "新滨江铺装顶点高度不同源 cell=%d,%d mat=%s xyz=%.9f,%.9f,%.9f expected=%.9f delta=%.9g",
                    ix,iz,mat,v.x,v.y,v.z,expected,v.y-expected))
            end
            if cross>1e-8 then
                local bound=quantizationBound(a,b,c)
                maxQuantizationBound=math.max(maxQuantizationBound,bound)
                local tolerance=math.max(.00003,bound)
                -- 量化界不能成为任意放宽通行几何的理由；0.5mm仍小于4mm碰撞skin。
                assert(tolerance<=.0005,"山地量化理论界超过0.5mm硬限，需细分/修复几何")
                -- 量化后的顶点不能以重算Y掩盖内部跨折线：再验重心和三边中点同面。
                for _,weights in ipairs({{1/3,1/3,1/3},{.5,.5,0},{0,.5,.5},{.5,0,.5}}) do
                    local x=a.x*weights[1]+b.x*weights[2]+c.x*weights[3]
                    local z=a.z*weights[1]+b.z*weights[2]+c.z*weights[3]
                    local y=a.y*weights[1]+b.y*weights[2]+c.y*weights[3]
                    local expected=Hills.Height(x,z)+lift
                    local delta=math.abs(y-expected)
                    maxInteriorError=math.max(maxInteriorError,delta)
                    assert(delta<=tolerance and delta<=.0005,string.format(
                        "山地裁片内部跨面 cell=%d,%d mat=%s xz=%.9f,%.9f y=%.9f expected=%.9f delta=%.9g bound=%.9g tolerance=%.9g",
                        ix,iz,mat,x,z,y,expected,delta,bound,tolerance))
                end
            end
        end,Quad=function() end,Box=function() end} --[[@as CityDetails]]
        Hills.RenderCell(builder,cell)
        assert(triangles<36000,"新山地单块三角超预算")
        hillTriangles=hillTriangles+triangles;maxHillTriangles=math.max(maxHillTriangles,triangles)
    end end
    print(string.format("[沿江几何专项] PASS %d三角/单块最大%d/片内最大实误差%.9g/最大理论量化界%.9g/硬限0.0005m；仅渲染同源专项，非全回归",hillTriangles,maxHillTriangles,maxInteriorError,maxQuantizationBound))
    return hillTriangles,maxHillTriangles
end
---@param session CareerSession
local function prepareShot(session)
    assert(session.options.test and session.restoreTestStorage,"实拍必须隔离存档")
    local city=assert(session.city)
    local terrace,river,ride=false,false,false
    for _,arg in ipairs(GetArguments()) do
        if arg=="-careerterraceview" or arg=="-careerhillview=terrace" then terrace=true end
        if arg=="-careerhillview=river" then river=true end
        if arg=="-careerhillview=ride" then ride=true end
    end
    local x,z=ride and 304 or river and 400 or terrace and 308 or 3,
        ride and 1352 or river and 1208 or terrace and 664 or 1160
    local yaw,pitch=ride and 160 or river and -70 or 0,ride and 10 or river and 6 or terrace and 12 or 10
    city.stream:Ensure(x,z,550)
    session.actor.mounted=true;session.actor.visuals:SetMounted(true)
    -- 测试会话仍会自动向actor.yaw回正，相同yaw保证截图前后取景不漂移。
    session.actor:Teleport(x,z,yaw)
    session.yaw,session.pitch=yaw,pitch
    session.camera:SetModeConfig("ride",{distance=river and 150 or (ride or terrace) and 24 or 11,
        offset=Vector3(0,river and 14 or ride and 4 or 2,0),fov=65})
    session.camera:SetMode("ride");session.camera:Update(2,session.actor.node,session.yaw,session.pitch)
    session.traffic.active=false
    session.shotRenderFrames=0
    session.view:ClosePhone();session.view:ShowGame();session:Refresh()
    print("[山地实拍就绪] 正式流式桥面与河谷，非远景贴片")
end
---@param session CareerSession
function Checks.Run(session,shot)
    assert(session.options.test and session.restoreTestStorage)
    for _,arg in ipairs(GetArguments()) do
        if arg=="-careerhillgeometryonly" then
            geometryChecks()
            return
        end
        if arg=="-careerhillviewonly" then
            assert(shot,"hillviewonly只允许隔离实拍，不可冒充回归通过")
            prepareShot(session)
            return
        end
    end
    local streamReport=require("Career.WorldStreamChecks").Run()
    assert(streamReport.passed)
    print(string.format("[流式切片验收] PASS %d断言",streamReport.assertions))
    local Hills=require("Career.HillDistrict")
    local Contact=require("Career.VehicleContact")
    local Footprints=require("Career.VehicleFootprints")
    local Collision=require("Career.CityCollision")
    local World=require("Career.WorldData")
    local city=session.city
    local Geometry=require("Career.FootprintCollision")
    local riverOnly=false
    local terraceVehicles={"borrowed_ebike"}
    for _,arg in ipairs(GetArguments()) do
        if arg=="-careerriveronly" then riverOnly=true end
        local id=arg:match("^%-careerterracevehicle=(.+)$")
        if id then assert(id=="sedan" or id=="truck" or id=="borrowed_ebike");terraceVehicles={id} end
    end
    local count,terraceSteps=0,0
    if not riverOnly then
    local poseComparisons=0
    -- 独立旧算法：逐点旋转后交给Shape重新扫描，不调用优化后的Pose。
    local function originalPose(source,x,z,yaw)
        local angle=math.rad(yaw)
        local cs,sn=math.cos(angle),math.sin(angle)
        local function point(v) return {x=x+v.x*cs+v.z*sn,z=z-v.x*sn+v.z*cs} end
        local parts={}
        for _,part in ipairs(source.parts) do
            if part.radius then
                local p=point(part);p.radius=part.radius;parts[#parts+1]=p
            else
                local vertices={}
                for _,v in ipairs(part.points) do vertices[#vertices+1]=point(v) end
                parts[#parts+1]={points=vertices}
            end
        end
        return Geometry.Shape(parts)
    end
    local shapes={Footprints.Get("borrowed_ebike"),Footprints.Get("sedan"),Footprints.Get("truck"),
        Geometry.Circle(.3,-.7,.32),Geometry.Shape({{x=.3,z=-.7,radius=.32},
            {points={{x=-2,z=-1},{x=2,z=-1},{x=0,z=3}}}})}
    for _,source in ipairs(shapes) do
        for _,p in ipairs({{0,0},{3,610},{-199.75,198.125},{14990,-14990}}) do
            for _,yaw in ipairs({0,17,45,90,179,271.25}) do
                local posed=Geometry.Pose(source,p[1],p[2],yaw)
                local reference=originalPose(source,p[1],p[2],yaw)
                for _,key in ipairs({"x1","x2","z1","z2","reach"}) do
                    assert(math.abs(posed[key]-reference[key])<1e-9,"单遍车壳变换整体界不一致 "..key)
                end
                for index,part in ipairs(posed.parts) do
                    local other=reference.parts[index]
                    for _,key in ipairs({"x1","x2","z1","z2"}) do assert(part[key]==other[key],"车壳部件界不一致") end
                    if part.radius then assert(part.x==other.x and part.z==other.z and part.radius==other.radius)
                    else
                        assert(#part.points==#other.points)
                        for k,v in ipairs(part.points) do assert(v.x==other.points[k].x and v.z==other.points[k].z,"真实车壳顶点改变") end
                    end
                end
                poseComparisons=poseComparisons+1
            end
        end
    end
    local Motion=require("Career.TrafficMotion")
    local reuseComparisons=0
    for _,id in ipairs({"borrowed_ebike","sedan","truck"}) do
        local car={id=id,x=3,z=610,yaw=0,length=6,width=3}
        for _,p in ipairs({{3,610},{-25,-22},{-3,1280},{352,1100}}) do
            for _,yaw in ipairs({0,37,90,180}) do
                car.x,car.z,car.yaw=p[1],p[2],yaw
                local source=Footprints.Get(id)
                local reference=Collision.ShapeFree(city,source,car.x,car.z,yaw,"vehicle",city:Surface(car.x,car.z),nil,true)
                assert(Motion.StaticFree(city,car)==reference,"静态/动态共享姿态改变碰撞结果")
                local shell=Motion.Shape(car)
                assert(Motion.Shape(car)==shell,"未移动姿态没有复用")
                car.x=car.x+.001
                assert(Motion.Shape(car)~=shell,"移动1mm后车壳姿态未失效")
                reuseComparisons=reuseComparisons+1
            end
        end
    end
    local resized={x=0,z=0,yaw=0,length=2,width=1}
    local before=Motion.Shape(resized)
    resized.width=2
    local after=Motion.Shape(resized)
    assert(before~=after and after.x2-after.x1==2,"同坐标改变车宽未使姿态失效")
    resized.length=3
    local longer=Motion.Shape(resized)
    assert(after~=longer and longer.z2-longer.z1==3,"同坐标改变车长未使姿态失效")
    resized.id="sedan"
    local sedan=Motion.Shape(resized)
    resized.id="truck"
    assert(Motion.Shape(resized)~=sedan,"同坐标切换源车型未使姿态失效")
    print(string.format("[车壳变换与复用] PASS %d组旧逐点算法/顶点/部件界/整体界/reach；%d组静态等价与1mm失效；尺寸/车型失效",poseComparisons,reuseComparisons))
    local Crowd=require("Career.Crowd")
    local function originalCrowd(self,p,ax,az,bx,bz,predict)
        if not self.city:StaticSegmentFree(ax,az,bx,bz,p.radius,"walk",p.height) then return false end
        local y1=self.city:WalkSurface(ax,az,p.height)
        local ym=self.city:WalkSurface((ax+bx)/2,(az+bz)/2,y1)
        local y2=self.city:WalkSurface(bx,bz,ym)
        if math.abs(y2-y1)>.32+math.sqrt((bx-ax)^2+(bz-az)^2)*.18 then return false end
        local shape=Geometry.Circle(ax,az,p.radius)
        local dx,dz=bx-ax,bz-az
        local low,high=math.min(y1,ym,y2),math.max(y1,ym,y2)+1.8
        for _,entry in ipairs(self.shapes) do
            local time=predict or .25
            local ey=entry.y1 or self.city:Surface((entry.shape.x1+entry.shape.x2)/2,(entry.shape.z1+entry.shape.z2)/2)
            if Motion.VerticalOverlap(low,high,ey,entry.y2 or ey+1.8)
                and (not Geometry.Free(shape,entry.shape,.025) or Geometry.Sweep(shape,entry.shape,dx-entry.vx*time,dz-entry.vz*time,.025)) then return false end
        end
        for _,other in ipairs(self.people) do
            if other~=p and other.active then
                local oy1,oy2=Motion.PersonInterval(self.city,other)
                local body=Geometry.Circle(other.x,other.z,other.radius)
                if Motion.VerticalOverlap(low,high,oy1,oy2)
                    and (not Geometry.Free(shape,body,.04) or Geometry.Sweep(shape,body,dx,dz,.04)) then return false end
            end
        end
        return true
    end
    local pedestrian={radius=.30,height=0} --[[@as CareerCrowdPerson]]
    local fixture={city={StaticSegmentFree=function() return true end,
        WalkSurface=function() return 0 end,Surface=function() return 0 end},shapes={},people={}} --[[@as CareerCrowd]]
    local crowdComparisons=0
    for _,distance in ipairs({-.001,0,.001,.624999,.625,.625001,2,12}) do
        for _,height in ipairs({0,1.8,6}) do
            for _,velocity in ipairs({-20,0,20}) do
                for _,endpoint in ipairs({{0,0},{0,1},{1,0},{-2,-3}}) do
                    fixture.shapes={{shape=Geometry.Circle(distance,1,.30),y1=height,y2=height+1.8,vx=velocity,vz=-velocity}}
                    local other={x=-distance,z=-.4,radius=.32,height=height,active=true} --[[@as CareerCrowdPerson]]
                    fixture.people={other}
                    local fast=Crowd.SegmentFree(fixture,pedestrian,0,0,endpoint[1],endpoint[2],.75)
                    local reference=originalCrowd(fixture,pedestrian,0,0,endpoint[1],endpoint[2],.75)
                    assert(fast==reference,"街坊整段宽相改变预测碰撞/分层结果")
                    crowdComparisons=crowdComparisons+1
                end
            end
        end
    end
    print(string.format("[街坊预测宽相] PASS %d组原算法对照，含接触阈值/静止/逆向高速/跨层/斜向整段",crowdComparisons))
    local comparisons=0
    for _,id in ipairs({"borrowed_ebike","sedan","truck"}) do
        for _,yaw in ipairs({0,17,45,90,179}) do
            local shape=Geometry.Pose(Footprints.Get(id),0,0,yaw)
            for _,delta in ipairs({-.2,0,.003,.005,.03,.3}) do
                local other=Geometry.Box(shape.x2+delta,-.2,shape.x2+delta+.2,.2)
                local fast=Geometry.Free(shape,other,Geometry.SKIN)
                local ft,fx,fz=Geometry.Sweep(shape,other,.5,.03)
                local bounds={}
                for i,part in ipairs(shape.parts) do bounds[i]=part.x1;part.x1=nil end
                local exact=Geometry.Free(shape,other,Geometry.SKIN)
                local et,ex,ez=Geometry.Sweep(shape,other,.5,.03)
                for i,part in ipairs(shape.parts) do part.x1=bounds[i] end
                assert(fast==exact,"部件宽相改变真实车壳窄相结果")
                assert(ft==et and fx==ex and fz==ez,"部件宽相改变完整连续扫掠时刻或法线")
                comparisons=comparisons+1
            end
        end
    end
    print(string.format("[车壳部件宽相] PASS %d组原始窄相对照，4mm间距不变",comparisons))
    for _,id in ipairs({"borrowed_ebike","sedan","truck"}) do
        for _,p in ipairs({{3,800},{-3,1280},{3,520},{190,1000},{3,610},{3,670},{-3,1480},{160,1520}}) do
            for _,yaw in ipairs({0,37,90,180}) do
                local h,a,b=Contact.Solve(city,id,p[1],p[2],yaw,0)
                local eh,ea,eb=Contact.SolveExact(city,id,p[1],p[2],yaw,0)
                assert(math.abs(h-eh)<.000001 and math.abs(a-ea)<.000001 and math.abs(b-eb)<.000001,
                    "山地平面证明改变了原轮胎求解 "..id)
            end
        end
    end
    print("[山地轮胎快路] PASS 96组同原逐点求解；常高/斜平面/跨折线分别验证")
    local terraceOnly=false
    for _,arg in ipairs(GetArguments()) do if arg=="-careerterraceonly" then terraceOnly=true end end
    for _,id in ipairs(terraceOnly and {} or {"borrowed_ebike","sedan","truck"}) do
        local shape=Footprints.Get(id)
        for _,direction in ipairs({-1,1}) do
            local x,z=direction>0 and 3 or -3,direction>0 and 441 or 1791
            local yaw=direction>0 and 0 or 180
            for _=1,1350 do
                local y=city:Surface(x,z)
                local nx,nz,hit=city:MoveShape(x,z,0,direction,shape,yaw,"vehicle",y,id)
                assert(not hit and math.abs(nz-z-direction)<.0001,"山地公路出现阻车墙 "..id.." z="..z)
                x,z=nx,nz
                if count%50==0 then
                    local h,p,r=Contact.Solve(city,id,x,z,yaw,0)
                    assert(h==h and p==p and r==r and math.abs(h-city:Surface(x,z))<2,"轮胎未随山地道路接地")
                end
                count=count+1
            end
        end
    end
    for _,road in ipairs(Hills.Roads) do
        for _,id in ipairs(terraceVehicles) do
            local shape=Footprints.Get(id)
            local flatCity={Surface=function() return 0 end} --[[@as CareerCity]]
            local flatRoot=Contact.SolveExact(flatCity,id,0,0,0,0)
            for _,direction in ipairs({-1,1}) do
                local ax,az=direction>0 and road.x1 or road.x2,direction>0 and road.z1 or road.z2
                local bx,bz=direction>0 and road.x2 or road.x1,direction>0 and road.z2 or road.z1
                local length=math.sqrt((bx-ax)^2+(bz-az)^2)
                local dx,dz=(bx-ax)/length,(bz-az)/length
                local yaw=math.deg(math.atan(dx,dz))
                local x,z=ax,az
                for step=1,math.floor(length) do
                    local tx,tz=ax+dx*step,az+dz*step
                    local nx,nz,hit=city:MoveShape(x,z,tx-x,tz-z,shape,yaw,"vehicle",city:Surface(x,z),id)
                    assert(not hit and math.abs(nx-tx)+math.abs(nz-tz)<.0001,
                        "台地道路不通 "..road.id.." "..id.." "..step)
                    assert(math.abs(city:Surface(nx,nz)-city:Surface(x,z))<.26,"台地路面出现台阶")
                    x,z=nx,nz;terraceSteps=terraceSteps+1
                    if step%64==0 then
                        local h,p,r=Contact.Solve(city,id,x,z,yaw,0)
                        local eh,ep,er=Contact.SolveExact(city,id,x,z,yaw,0)
                        assert(math.abs(h-eh)+math.abs(p-ep)+math.abs(r-er)<.00001,"新台地轮胎快路不等价")
                        assert(math.abs(h-city:Surface(x,z)-flatRoot)<.18,
                            string.format("新坡路接地偏离平地胎面基准 %s %s step=%d delta=%.5f",id,road.id,step,h-city:Surface(x,z)-flatRoot))
                    end
                end
            end
        end
    end
    end
    -- 阶段1新增沿江路/折线坡道：真实City车壳扫掠与胎面接地，不以折线存在代替可驾驶。
    local riverSteps,riverRoutes=0,0
    local function drive(route,id)
        local shape=Footprints.Get(id)
        for i=2,#route do
            local a,b=route[i-1],route[i]
            local length=math.sqrt((b.x-a.x)^2+(b.z-a.z)^2)
            if length>.000001 then
                local yaw=math.deg(math.atan(b.x-a.x,b.z-a.z))
                local steps=math.ceil(length)
                local x,z=a.x,a.z
                for step=1,steps do
                    local tx,tz=a.x+(b.x-a.x)*step/steps,a.z+(b.z-a.z)*step/steps
                    local nx,nz,hit=city:MoveShape(x,z,tx-x,tz-z,shape,yaw,"vehicle",city:Surface(x,z),id)
                    assert(not hit and math.abs(nx-tx)+math.abs(nz-tz)<.0001,
                        string.format("沿江导航阻车 %s seg%d %.2f %.2f",id,i,tx,tz))
                    local rise=math.abs(city:Surface(nx,nz)-city:Surface(x,z))
                    assert(rise<.26,"沿江导航跳层/台阶")
                    if step%48==0 then
                        local h,p,r=Contact.Solve(city,id,nx,nz,yaw,0)
                        assert(h==h and math.abs(h-city:Surface(nx,nz))<2 and math.abs(p)<=6.001 and math.abs(r)<=6.001,
                            "沿江导航胎面脱离高度场")
                    end
                    x,z=nx,nz;riverSteps=riverSteps+1
                end
            end
        end
        riverRoutes=riverRoutes+1
    end
    for _,road in ipairs(require("Career.HillRoads").Routes) do
        for _,id in ipairs(terraceVehicles) do
            drive(road.points,id)
            local reverse={}
            for i=#road.points,1,-1 do reverse[#reverse+1]=road.points[i] end
            drive(reverse,id)
        end
    end
    local destinations={{x=0,z=-20},Hills.Points[1],Hills.Points[2]}
    for i,a in ipairs(destinations) do for j,b in ipairs(destinations) do
        if i~=j then
            local route=assert(World.NavigationRoute(a.x,a.z,b.x,b.z,city:Surface(a.x,a.z),"ground"),"滨江点双向导航为空")
            assert(route[1].x==a.x and route[1].z==a.z and route[#route].x==b.x and route[#route].z==b.z,
                "滨江导航丢失真实首尾")
            for _,p in ipairs(route) do
                if Hills.Contains(p.x,p.z) then
                    assert(p.layer=="ground" and math.abs(p.y-city:Surface(p.x,p.z))<.0001,"滨江导航高度/层失配")
                end
            end
            for _,id in ipairs(terraceVehicles) do drive(route,id) end
        end
    end end
    assert(not Hills.LocalRoute(320,800,192,1208),"局部导航吸附超过8m")
    assert(not Hills.LocalRoute(Hills.Buildings[1].x,Hills.Buildings[1].z,192,1208),"局部导航穿住宅基座")
    print(string.format("[沿江闭环验收] PASS %d双向路由/%d真实车壳米步；老街去返/两岸互访/8m合法吸附",riverRoutes,riverSteps))
    for _,b in ipairs(Hills.Buildings) do
        for _,x in ipairs({b.x1,b.x2}) do for _,z in ipairs({b.z1,b.z2}) do
            assert(math.abs(assert(Hills.Surface(x,z))-b.baseY)<.00001,"住宅足迹不在常高台地")
        end end
        local cell=World.DescribeCell(math.floor(b.x/256),math.floor(b.z/256))
        local found=false
        for _,o in ipairs(cell.obstacles) do
            if o.kind=="building" and math.abs((o.x1+o.x2)/2-b.x)<.001
                and math.abs((o.z1+o.z2)/2-b.z)<.001 then
                assert(o.y1==b.foundationY and o.y2==b.baseY+b.h,"模型与基础碰撞高度不同源")
                found=true
            end
        end
        assert(found and not city:StaticFree(b.x,b.z,.32,"walk",b.baseY),"山地楼体无实体碰撞")
    end
    for _,p in ipairs({{-464,820},{304,760},{464,900},{-304,900},{200,576},{-200,960}}) do
        local route=assert(World.NavigationRoute(p[1],p[2],0,0,city:Surface(p[1],p[2]),"ground"))
        assert(#route>=3 and route[1].x==p[1] and route[1].z==p[2],"台地导航未从真实街道起步")
        local exit=assert(Hills.ExitRoute(p[1],p[2]))
        for i=2,#exit do
            local a,b=exit[i-1],exit[i]
            assert(city:StaticSegmentFree(a.x,a.z,b.x,b.z,.32,"walk",a.y),"台地导航穿墙或切坡角")
        end
    end
    print(string.format("[坡地街区验收] PASS %d车型双向米步；%d住宅足迹/模型基础碰撞；6处原路网导航接续",terraceSteps,#Hills.Buildings))
    -- 差集面积守恒：重复路口片不得重复画，圆接头不得吞掉未覆盖地面。
    local Roads=require("Career.HillRoads")
    local function area(poly)
        local sum=0
        for i,a in ipairs(poly) do local b=poly[i%#poly+1];sum=sum+a.x*b.z-a.z*b.x end
        return math.abs(sum)/2
    end
    local partitionCases=0
    for _,r in ipairs(Roads.Routes) do for _,p in ipairs(r.points) do
        local rect={x1=p.x-12,x2=p.x+12,z1=p.z-12,z2=p.z+12}
        local poly={{x=rect.x1,z=rect.z1,y=0},{x=rect.x2,z=rect.z1,y=0},
            {x=rect.x2,z=rect.z2,y=0},{x=rect.x1,z=rect.z2,y=0}}
        local sum=0
        local remaining=Roads.Partition(poly,Roads.Candidates(rect),function(shape) sum=sum+area(shape) end)
        for _,shape in ipairs(remaining) do sum=sum+area(shape) end
        assert(math.abs(sum-576)<.0001,"沿江铺装差集重复/缺面")
        partitionCases=partitionCases+1
    end end
    -- 渲染出的每个地形/铺装顶点与同一个高度场一致，并控制每块纯山地三角数。
    local hillTriangles,maxHillTriangles=geometryChecks()
    print(string.format("[沿江铺装验收] PASS %d路口面积守恒/%d三角/单块最大%d；高度同源",partitionCases,hillTriangles,maxHillTriangles))
    -- 验证旧横路描述没有被山地裁掉，并逐顶点核对显示铺装和逻辑高度同源。
    local patches,vertices=0,0
    for ix=-2,1 do for iz=1,6 do
        local cell=World.DescribeCell(ix,iz)
        for _,s in ipairs(cell.hillGrounds or {}) do
            if s.material=="road" then
                patches=patches+1
                local builder={Triangle=function(_,_,a,b,c)
                    for _,p in ipairs({a,b,c}) do
                        -- 引擎Vector3存为float；80m高程的量化误差可达数微米。
                        assert(math.abs(p.y-Hills.Height(p.x,p.z)-s.y)<.00002,"山路渲染偏离原始地形平面")
                        vertices=vertices+1
                    end
                end}
                assert(Hills.RenderPatch(builder,s,s.material,s.y)>0)
            end
        end
    end end
    assert(patches>10 and vertices>100,"旧北区横路未恢复铺装")
    -- 所有同高铺装必须先在描述层裁掉重叠，不能靠深度偏置掩盖闪烁。
    for ix=-2,1 do for iz=2,3 do
        local grounds=World.DescribeCell(ix,iz).hillGrounds or {}
        for i,a in ipairs(grounds) do for j=i+1,#grounds do
            local b=grounds[j]
            assert(not (a.x1<b.x2-1e-7 and a.x2>b.x1+1e-7 and a.z1<b.z2-1e-7 and a.z2>b.z1+1e-7),
                "台地铺装共面重叠")
        end end
    end end
    print(string.format("[山路同源铺装] PASS %d路面片/%d顶点；原横路及人行道保留",patches,vertices))
    local Store=require("Career.Store")
    local files={}
    Store.WithTestStorage({read=function(path) return files[path],nil,files[path]==nil end,
        write=function(path,text) files[path]=text;return true end},function()
        assert(Store.NewCareer())
        for _,height in ipairs({-14,12.055,80}) do
            local position=Store.Get().position
            position.groundHeight=height
            assert(Store.SetPosition(position));assert(Store.Save());assert(Store.Load())
            assert(math.abs(Store.Get().position.groundHeight-height)<.00001,"山地高度存读丢失")
        end
    end)
    local map=require("Career.MapOverlay").Checks()
    assert(map.sizes==5)
    print("[山地存档与地图] PASS 负高度/桥面/高处三档存读；地图五尺寸真实触摸")
    assert(city:Surface(0,1280)>12 and Hills.Height(0,1280)<-13,"桥面和河谷没有实际高差")
    -- 视觉整改主动将68m尖峰削为30/38m不对称宽脊；验真实高差且禁止重新出现70m金字塔。
    local west,east=city:Surface(-352,1664),city:Surface(384,1664)
    assert(west>18 and west<32 and east>22 and east<38 and east-west>3,"非对称低缓丘高差/削峰不符")
    assert(city:Surface(192,1208)<.06 and city:Surface(-192,1352)<.06,"沿江低位道路未真实切坡")
    for _,p in ipairs(World.Points) do
        if p.district=="north_campus" then assert(math.abs(city:Surface(p.x,p.z)-.055)<.001,"旧服务点被山地抬走") end
    end
    -- 连续整段直线查询对照旧10cm算法，窄柱、切角、桥层仍不漏。
    local equivalent=0
    for _,p in ipairs({{240,-40,240,160},{210,-140,210,-20},{-450,-450,-480,-480},
        {0,500,0,560},{768,96,800,96},{-140,-30,-120,-10}}) do
        for _,r in ipairs({.32,.8}) do
            local y=city:Surface(p[1],p[2])
            assert(Collision.SegmentFree(city,p[1],p[2],p[3],p[4],r,"walk",y)
                ==Collision.SegmentFreeExact(city,p[1],p[2],p[3],p[4],r,"walk",y),"整段连续扫掠与旧算法不等价")
            equivalent=equivalent+1
        end
    end
    print(string.format("[山地道路验收] PASS %d车型双向米步/桥谷26m高差/山脊/旧服务口；%d组连续扫掠对照",count,equivalent))
    if shot then prepareShot(session) end
end
return Checks
