-- Shared traffic shell geometry. Traffic following buffers remain behavioural
-- only; actual occupancy is the same visible model footprint as Actor/parking.
local C=require("Career.FootprintCollision")
local F=require("Career.VehicleFootprints")
local Assets=require("VehicleAssets")
local M={}
-- Side view (metres): [ground feet..head] / [bridge feet..head].
-- XZ overlap is relevant only where these world-space intervals overlap.
-- Elevated terrain is still ground, never a synthetic bridge layer.
function M.PersonInterval(city,person)
    local y=person.height or person.y
    if type(y)~="number" then y=city:WalkSurface(person.x,person.z,0) end
    return y,y+1.8
end
function M.VehicleInterval(city,car)
    local y=city:Surface(car.x,car.z)
    local spec=Assets.Vehicles[car.vehicleId or car.id]
    local height=car.bodyHeight or (car.riding and 2.3) or (spec and spec.targetSize.y) or 1.85
    return y,y+height
end
function M.VerticalOverlap(a1,a2,b1,b2)
    return a1<b2-C.SKIN and b1<a2-C.SKIN
end
function M.BlockerInterval(city,b)
    if b.y1~=nil and b.y2~=nil then return b.y1,b.y2 end
    return M.PersonInterval(city,b)
end
function M.BlockerOverlaps(city,car,b)
    -- 此接口也供前方跟车距离使用，只判断垂直层，不能按当前XZ相交范围裁剪。
    local y1,y2=M.VehicleInterval(city,car)
    local low,high=M.BlockerInterval(city,b)
    return M.VerticalOverlap(y1,y2,low,high)
end
-- Local geometry is immutable. Keep the fallback box too: spawn probes without
-- an asset id used to allocate it for both StaticFree and Shape on every query.
function M.Source(car)
    -- id-less resident riders deliberately use their measured rider+vehicle
    -- OBB. vehicleId identifies contact/art only for those two records; using
    -- its bare bike shell would omit the visible rider's knees and boots.
    local id=car.id or (not car.riding and car.vehicleId)
    if id then return F.Get(id) end
    if not car.boxSource or car.boxWidth~=car.width or car.boxLength~=car.length then
        car.boxSource=C.Box(-car.width/2,-car.length/2,car.width/2,car.length/2)
        car.boxWidth,car.boxLength=car.width,car.length
    end
    return car.boxSource
end
function M.Shape(car)
    local source=M.Source(car)
    if car.shapeX==car.x and car.shapeZ==car.z and car.shapeYaw==car.yaw and car.shell
        and car.shapeSource==source and car.shapeWidth==car.width and car.shapeLength==car.length then return car.shell end
    car.shell=C.Pose(source,car.x,car.z,car.yaw)
    car.shapeX,car.shapeZ,car.shapeYaw=car.x,car.z,car.yaw
    car.shapeSource,car.shapeWidth,car.shapeLength=source,car.width,car.length
    return car.shell
end
function M.CircleFree(car,x,z,r,city,height)
    local reach=car.length/2+car.width/2+r+C.SKIN
    if math.abs(car.x-x)>reach or math.abs(car.z-z)>reach then return true end
    if city then
        local low,high=M.VehicleInterval(city,car)
        local y=height or city:WalkSurface(x,z,0)
        if not M.VerticalOverlap(low,high,y,y+1.8) then return true end
    end
    return C.Free(M.Shape(car),C.Circle(x,z,r),C.SKIN)
end
function M.BlockerFree(car,b,city)
    local reach=car.length/2+car.width/2+b.radius+C.SKIN
    if math.abs(car.x-b.x)>reach or math.abs(car.z-b.z)>reach then return true end
    if city and not M.BlockerOverlaps(city,car,b) then return true end
    return C.Free(M.Shape(car),b.shape or C.Circle(b.x,b.z,b.radius),C.SKIN)
end
function M.Separate(a,b,city)
    local reachA=a.length/2+a.width/2
    local reachB=b.length/2+b.width/2
    if (a.x-b.x)^2+(a.z-b.z)^2>(reachA+reachB+.01)^2 then return true end
    if city then
        local a1,a2=M.VehicleInterval(city,a)
        local b1,b2=M.VehicleInterval(city,b)
        if not M.VerticalOverlap(a1,a2,b1,b2) then return true end
    end
    return C.Free(M.Shape(a),M.Shape(b),C.SKIN)
end
-- 缓存只活在一次同步交通Update内；地形不变，动态车辆/行人仍每次检查。
-- 保存true和false，按实际车壳源、位置、朝向及空间失效，不跨帧保存通行结论。
local staticScope={}
function M.BeginStaticScope(city)
    assert(not staticScope.city,"交通静态查询作用域不可重入")
    staticScope={city=city,space=city.space,entries={}}
end
function M.EndStaticScope()
    staticScope={}
end
function M.StaticFree(city,car)
    local source=M.Source(car)
    local entries=staticScope.city==city and staticScope.space==city.space and staticScope.entries
    local saved=entries and entries[car]
    if saved and saved.x==car.x and saved.z==car.z and saved.yaw==car.yaw and saved.source==source then
        return saved.free
    end
    local height=city:Surface(car.x,car.z)
    local same=car.shapeX==car.x and car.shapeZ==car.z and car.shapeYaw==car.yaw and car.shell
        and car.shapeSource==source and car.shapeWidth==car.width and car.shapeLength==car.length
    local clear,candidates=false,nil
    if not same then
        clear,candidates=require("Career.CityCollision").StaticBoundsClear(city,source,car.x,car.z,car.yaw,"vehicle",height)
    end
    local free=clear or city:StaticShapeFree(car.x,car.z,source,car.yaw,"vehicle",height,M.Shape(car),candidates)
    if entries then entries[car]={x=car.x,z=car.z,yaw=car.yaw,source=source,free=free} end
    return free
end
-- Pure-data regression entry; no scene/save mutation or asset loading needed.
function M.CacheChecks()
    ---@type table<string,number>
    local car={x=10,z=20,yaw=17,width=2,length=4}
    local source=M.Source(car)
    local first=M.Shape(car)
    assert(M.Shape(car)==first and M.Source(car)==source,"identical traffic pose was rebuilt")
    local function exact()
        local wanted=C.Pose(M.Source(car),car.x,car.z,car.yaw)
        local actual=M.Shape(car)
        assert(actual.x1==wanted.x1 and actual.x2==wanted.x2 and actual.z1==wanted.z1 and actual.z2==wanted.z2,"cached bounds differ")
        for i,part in ipairs(wanted.parts) do for j,p in ipairs(part.points) do
            assert(actual.parts[i].points[j].x==p.x and actual.parts[i].points[j].z==p.z,"cached hull differs")
        end end
    end
    for _,field in ipairs({"x","z","yaw","width","length"}) do
        local before=M.Shape(car)
        car[field]=car[field]+.01
        assert(M.Shape(car)~=before,"traffic cache failed to invalidate "..field)
        exact()
    end
    assert(M.Source(car)~=source,"fallback box failed dimension invalidation")
    local city={Surface=function() return 0 end,StaticShapeFree=function(_,x,z,shape,yaw,mode,height,posed)
        assert(shape==M.Source(car) and posed==M.Shape(car),"static/dynamic shell cache split")
        return true
    end}
    assert(M.StaticFree(city,car))
    local rider={vehicleId="borrowed_ebike",riding=true,x=3,z=5,yaw=0,width=1.7,length=2.6}
    local riderSource=M.Source(rider)
    assert(riderSource~=F.Get(rider.vehicleId) and riderSource.x1==-.85 and riderSource.x2==.85
        and riderSource.z1==-1.3 and riderSource.z2==1.3,"resident rider lost its measured composite OBB")
    local riderShell=M.Shape(rider)
    assert(M.Source(rider)==riderSource and M.Shape(rider)==riderShell,"unchanged rider box/pose rebuilt")
    rider.x=rider.x+.001
    local moved=M.Shape(rider)
    assert(moved~=riderShell and riderShell.x1==3-.85 and moved.x1==rider.x-.85,"rider snapshot identity/content changed in place")
    local Collision=require("Career.CityCollision")
    Collision.StaticBoundsChecks()
    local emptyCity={space="city",obstacles={},Surface=function() return 0 end,
        StaticShapeFree=function(self,x,z,shape,yaw,mode,height,posed)
            return Collision.PosedFree(self,posed,shape,x,z,mode,height,nil,true)
        end}
    local lazy={x=0,z=-30,yaw=17,width=2,length=4}
    assert(M.StaticFree(emptyCity,lazy) and lazy.shell==nil,"empty static query eagerly allocated vehicle pose")
    local oldShell=M.Shape(lazy)
    lazy.x=.001
    assert(M.StaticFree(emptyCity,lazy) and lazy.shell==oldShell,"empty static proof mutated previous snapshot")
    local current=M.Shape(lazy)
    assert(current~=oldShell,"dynamic query did not invalidate lazy pose")
    local normal={id="sedan",vehicleId="truck",x=0,z=0,yaw=0,width=2,length=4}
    assert(M.Source(normal)==F.Get("sedan"),"id vehicle no longer uses its exact mesh footprint")
    local parked={vehicleId="borrowed_ebike",x=0,z=0,yaw=0}
    assert(M.Source(parked)==F.Get("borrowed_ebike"),"actor parking lost exact mesh footprint")
    -- 预置车壳以覆盖静态精确分支，true/false均只复用在本次Update。
    local checks=0
    local allowed=true
    local scopedCity={space="city",Surface=function() return 0 end,
        StaticShapeFree=function() checks=checks+1;return allowed end}
    M.Shape(car)
    M.BeginStaticScope(scopedCity)
    assert(M.StaticFree(scopedCity,car) and M.StaticFree(scopedCity,car) and checks==1,"同姿true未复用")
    allowed=false
    car.yaw=car.yaw+.01;M.Shape(car)
    assert(not M.StaticFree(scopedCity,car) and not M.StaticFree(scopedCity,car) and checks==2,"同姿false未复用/转向未失效")
    for _,field in ipairs({"x","z","width","length"}) do
        car[field]=car[field]+.01;M.Shape(car)
        assert(not M.StaticFree(scopedCity,car),"变化后错误复用旧通行结果")
    end
    assert(checks==6,"位置或车壳源变化未失效")
    M.EndStaticScope()
    allowed=true
    M.BeginStaticScope(scopedCity)
    assert(M.StaticFree(scopedCity,car) and checks==7,"静态结果跨帧泄漏")
    scopedCity.space="changed"
    assert(M.StaticFree(scopedCity,car) and checks==8,"空间变化未失效")
    M.EndStaticScope()
    local ok=pcall(require("Career.Traffic").Update,{active=true,disposed=false,city={space="city"},
        Blockers=function() return {} end,UpdateScoped=function() error("预期的交通推进测试异常") end},.017)
    assert(not ok,"交通推进错误被吞掉")
    M.BeginStaticScope(scopedCity);M.EndStaticScope()
    print("[交通缓存检查] PASS 同姿true/false/位移转向尺寸空间失效/不跨帧/异常释放/精确顶点/骑手OBB与普通车精确源")
    return true
end
return M
