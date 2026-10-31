-- 邻里街区验收：只读规划/城市静态查询；不读写档案，不创建第二套城市。
-- Run由主线程-careercityquality调用；Shot由-careercityshot=<方向>显式调用。
local Expansion=require("Career.CityExpansion")
local World=require("Career.WorldData")
local Config=require("Career.Config")
local FootprintCollision=require("Career.FootprintCollision")
local Checks={}
local function near(a,b,label)
    assert(math.abs(a-b)<.00001,label or "数值不一致")
end
local function routeHash()
    local entries={}
    for _,t in ipairs(World.Orders) do
        entries[#entries+1]=t.id
        -- 必须显式格式化：Lua5.4/5.5对浮点的默认字符串精度不同。
        -- 时限来自既有基线，不能把table.concat的默认转换当作稳定序列化。
        entries[#entries+1]=string.format("%.9f",t.timeLimitHours)
        for _,p in ipairs(t.route) do entries[#entries+1]=string.format("%.6f,%.6f",p.x,p.z) end
    end
    local text=table.concat(entries,"|")
    local hash=2166136261
    for i=1,#text do hash=((hash ~ text:byte(i))*16777619)&0xffffffff end
    return hash,#text
end
local function rectangle(p)
    return {x1=p.x-p.w/2,x2=p.x+p.w/2,z1=p.z-p.d/2,z2=p.z+p.d/2}
end
local function gap(rect,x,z)
    return math.sqrt((x-math.max(rect.x1,math.min(rect.x2,x)))^2+(z-math.max(rect.z1,math.min(rect.z2,z)))^2)
end
local function swept(v,ax,az,bx,bz,r)
    local lo,hi=0,1
    for _,s in ipairs({{ax,bx-ax,v.x1-r,v.x2+r},{az,bz-az,v.z1-r,v.z2+r}}) do
        if math.abs(s[2])<1e-9 then
            if s[1]<=s[3] or s[1]>=s[4] then return false end
        else
            local a,b=(s[3]-s[1])/s[2],(s[4]-s[1])/s[2]
            lo,hi=math.max(lo,math.min(a,b)),math.min(hi,math.max(a,b))
        end
    end
    return lo<hi and hi>0 and lo<1
end
-- 准确保留七张旧城单的折线和报价，以及24张既有外区单完整坐标签名。
-- 签名来自修改前git HEAD的WorldData，在独立Lua解释器中逐点比较过。
local function legacyOrders()
    local expected={
        {"tutorial",171,500,1.5,{{-25,-8},{-25,0},{-100,0},{-100,80},{-108,80}}},
        {"old_home",171,276,1,{{-25,-8},{-25,0},{-100,0},{-100,80},{-108,80}}},
        {"dealer_lunch",221,283,1,{{-25,-8},{-25,0},{100,0},{100,80},{108,80}}},
        {"park_lunch",166,275,1,{{-25,-8},{-25,0},{100,0},{100,-25},{108,-25}}},
        {"noodle_office",168,275,1,{{-70,9},{-70,0},{0,0},{0,44},{-45,44}}},
        {"shop_old",250,288,1,{{53,9},{53,0},{-100,0},{-100,80},{-108,80}}},
        {"noodle_dealer",267,290,1,{{-70,9},{-70,0},{100,0},{100,80},{108,80}}},
    }
    for i,e in ipairs(expected) do
        local t=assert(Config.orderTemplates[i]);assert(t.id==e[1] and #t.route==#e[5],"旧单顺序/节点改变")
        near(Config.RouteDistance(t.route),e[2]);near(t.timeLimitHours,e[4])
        near(i==1 and 500 or Config.FeeCents(e[2]),e[3],"旧单报价改变")
        for n,p in ipairs(e[5]) do near(t.route[n].x,p[1]);near(t.route[n].z,p[2]) end
    end
    -- 修改前git基线经Lua5.4/5.5各自逐点核对后，以相同固定格式重新序列化。
    -- 两种解释器均得3803字节/FNV2567365835，不沿用隐式数字转字符串的旧hash。
    local hash,bytes=routeHash()
    print(string.format("[邻里订单签名] Lua=%s templates=%d got=%u expected=2567365835 bytes=%d expectedBytes=3803",
        _VERSION,#World.Orders,hash,bytes))
    assert(#World.Orders==24 and hash==2567365835 and bytes==3803,
        string.format("既有外区单完整route/时限改变：got=%u bytes=%d templates=%d",hash,bytes,#World.Orders))
    for _,t in ipairs(World.Orders) do
        local length=Config.RouteDistance(t.route)
        assert(Config.FeeCents(length)==math.floor(math.max(250,math.min(1000,250+150*length/1000))+.5))
        for i=2,#t.route do assert(World.SegmentFree(t.route[i-1],t.route[i],1.2),"旧外区单被挡 "..t.id) end
    end
end
function Checks.Plan()
    legacyOrders()
    local stats=Expansion.Stats()
    assert(stats.roads==34 and stats.baseBuildings==78 and stats.plazas==4)
    assert(stats.infillBuildings>=150 and stats.infillBuildings<=220,"固定沿街补楼数量越界")
    assert(stats.modelTriangles<=1800000 and stats.maxCellModelTriangles<=185000,"邻里真实模型LOD0预算超限")
    assert(stats.assetCounts[2]>=stats.buildings*.8,"补楼必须以4492面低层真实资产为主")
    assert(World.District(240,-44).id=="greenbelt" and World.District(240,-44).label=="南城邻里")
    assert(World.District(24,240).label=="南城邻里" and World.District(0,0).id=="old_town")
    -- 单个视野的几何不变量：两侧真实楼体形成街墙，不能用总数掩盖眼前空地。
    for _,side in ipairs({-1,1}) do
        for _,cross in ipairs({214,268}) do
            local north,south=0,0
            for _,b in ipairs(Expansion.Buildings) do
                if b.x>=30 and b.x<=150 then
                    if math.abs(b.z-side*cross)<.01 then north=north+1 end
                end
                if b.z>=-65 and b.z<=65 then
                    if math.abs(b.x-side*cross)<.01 then south=south+1 end
                end
            end
            assert(north>=2,"南北截图前方未形成双侧街墙")
            assert(south>=2,"东西截图前方未形成双侧街墙")
        end
    end
    assert(World.ExpansionRoads==Expansion.Roads,"地图扩展几何非同源")
    local solids={}
    for _,b in ipairs(Expansion.Buildings) do
        ---@type number[]
        local size=Expansion.Models[b.asset].size
        near(b.w/size[1],b.h/size[2],"模型非等比X/Y")
        near(b.h/size[2],b.d/size[3],"模型非等比Y/Z")
        solids[#solids+1]=b
        assert(not Expansion.Overlaps(b,{x1=-195,x2=195,z1=-195,z2=195}),"新楼侵入旧城")
    end
    for _,a in ipairs(Expansion.Buildings) do if a.infill then
        local envelope={x1=a.x1-1,x2=a.x2+1,z1=a.z1-1,z2=a.z2+1}
        for _,b in ipairs(Expansion.Buildings) do if a~=b then
            assert(not Expansion.Overlaps(envelope,{x1=b.x1-.99,x2=b.x2+.99,z1=b.z1-.99,z2=b.z2+.99}),
                "补楼侧巷不足2m "..a.id.." / "..b.id)
        end end
    end end
    for _,p in ipairs(Expansion.Props) do solids[#solids+1]=rectangle(p) end
    for _,p in ipairs(Expansion.Plazas) do
        local horizontal={x1=p.x-p.w/2,x2=p.x+p.w/2,z1=p.z-2.5,z2=p.z+2.5}
        local vertical={x1=p.x-2.5,x2=p.x+2.5,z1=p.z-p.d/2,z2=p.z+p.d/2}
        for _,prop in ipairs(Expansion.Props) do
            assert(not Expansion.Overlaps(rectangle(prop),horizontal)
                and not Expansion.Overlaps(rectangle(prop),vertical),"广场十字5m入口被家具堵塞 "..p.id.." / "..prop.id)
        end
    end
    for _,o in ipairs(solids) do
        for _,r in ipairs(Expansion.Roads) do
            assert(not Expansion.Overlaps(o,Expansion.RoadRect(r,r.sidewalk)),"新障碍侵占道路/步道 "..r.id)
        end
        for _,p in ipairs(Config.pointList) do assert(gap(o,p.x,p.z)>=2,"新障碍侵占旧POI "..p.id) end
        for _,t in ipairs(Config.orderTemplates) do
            for i=2,#t.route do
                local a,b=t.route[i-1],t.route[i]
                assert(not swept(o,a.x,a.z,b.x,b.z,1.5),"新障碍侵占订单 "..t.id)
            end
        end
    end
    local maxBuildings,maxProps=0,0
    for ix=-2,1 do for iz=-2,1 do
        local c=World.DescribeCell(ix,iz)
        maxBuildings,maxProps=math.max(maxBuildings,#c.buildings),math.max(maxProps,#c.props)
        local expansionCount=0
        for _,b in ipairs(c.buildings) do if b.expansion then expansionCount=expansionCount+1 end end
        assert(expansionCount<=24,"邻里每格硬限24栋失效")
        assert(#c.buildings<=Expansion.MAX_BUILDINGS_PER_CELL,"邻里单块楼数无界")
        assert(#c.props<=Expansion.MAX_PROPS_PER_CELL,"邻里单块小件无界")
        for _,b in ipairs(c.buildings) do if b.expansion then
            local found=false
            for _,o in ipairs(c.obstacles) do
                if o.kind=="building" and math.abs(o.x1-b.x1)<.00001 and math.abs(o.x2-b.x2)<.00001
                    and math.abs(o.z1-b.z1)<.00001 and math.abs(o.z2-b.z2)<.00001 then found=true end
            end
            assert(found,"新楼可见地基/逻辑障碍不同源 "..b.id)
        end end
    end end
    stats.maxCellBuildings,stats.maxCellProps=maxBuildings,maxProps
    stats.worldOrderHash=routeHash()
    return stats
end
-- 从开局坐标出发的四个实际可达线路，不用传送代替路程。
-- 主线程Run验证生产扫掠：行人r=.32圆，车辆用可见模型同源分条轮廓。
-- 这是几何移动验收，不是Actor.Update动力输入；后者由环境完整步骑专项覆盖。
Checks.Paths={
    east={{0,-20},{0,0},{240,0},{240,-86},{312,-86},{312,-116},{338,-116}},
    west={{0,-20},{0,0},{-240,0},{-240,-86},{-312,-86},{-312,-116},{-338,-116}},
    north={{0,-20},{0,240},{52,240},{52,312},{72,312},{72,338}},
    south={{0,-20},{0,-240},{52,-240},{52,-312},{72,-312},{72,-338}},
}
local function hit(rect,x,z,r)
    return x>rect.x1-r and x<rect.x2+r and z>rect.z1-r and z<rect.z2+r
end
-- 查询失败时只读完整阻挡来源，不移除静态几何，不将路径跳到终点。
local function obstruction(city,x,z,r,mode)
    local report={string.format("StaticFree=%s IsFree=%s WorldFree=%s old=%s traffic=%s deliveryPeople=%s",
        tostring(city:StaticFree(x,z,r,mode,0)),tostring(city:IsFree(x,z,r,mode,0)),
        tostring(World.IsFree(x,z,r,mode,0)),tostring(World.IsOld(x,z)),
        tostring(city.traffic~=nil),tostring(city.deliveryPeople~=nil))}
    for i,o in ipairs(city.obstacles) do
        if hit(o,x,z,r) then
            report[#report+1]=string.format("city.obstacles[%d] kind=%s rect=[%.6f,%.6f,%.6f,%.6f]",
                i,tostring(o.kind or "legacy solid"),o.x1,o.x2,o.z1,o.z2)
        end
    end
    for ix=math.floor((x-r-32)/256),math.floor((x+r+32)/256) do
        for iz=math.floor((z-r-32)/256),math.floor((z+r+32)/256) do
            for i,o in ipairs(World.DescribeCell(ix,iz).obstacles) do
                if hit(o,x,z,r) then
                    report[#report+1]=string.format("WorldCell(%d,%d).obstacles[%d] kind=%s rect=[%.6f,%.6f,%.6f,%.6f]",
                        ix,iz,i,tostring(o.kind),o.x1,o.x2,o.z1,o.z2)
                end
            end
        end
    end
    for _,p in ipairs(city.contacts.people) do
        if (p.x-x)^2+(p.z-z)^2<(r+1)^2 then
            report[#report+1]=string.format("nearContact=%s at(%.6f,%.6f),独立联系人不直接参与City.IsFree",
                tostring(p.id),p.x,p.z)
        end
    end
    return table.concat(report," ; ")
end
local function movePath(city,path,actor,vehicle,name)
    local x,z=path[1][1],path[1][2]
    local meters=0
    local mode=vehicle and "vehicle" or "walk"
    local shape=vehicle and require("Career.VehicleFootprints").Get(actor.vehicleId) or FootprintCollision.Circle(0,0,.32)
    local ignoreId=vehicle and actor.vehicleId or nil
    ---@type number?
    local previousYaw=nil
    print(string.format("[邻里路径开始] name=%s mode=%s footprint=%s ignoreOnly=%s start=(%.6f,%.6f) segments=%d",
        name,mode,vehicle and "模型同源轮廓" or "行人圆r.32",tostring(ignoreId),x,z,#path-1))
    for i=2,#path do
        local b=path[i]
        local dx,dz=b[1]-x,b[2]-z
        local length=math.sqrt(dx*dx+dz*dz)
        local yaw=math.deg(math.atan(dx,dz))
        if vehicle and previousYaw~=nil then
            local accepted,blocked=actor:TurnTo(x,z,previousYaw,yaw)
            assert(not blocked and math.abs((accepted-yaw+180)%360-180)<.00001,
                string.format("邻里真实轮廓转角被挡 path=%s segment=%d at(%.6f,%.6f)",name,i,x,z))
        end
        previousYaw=yaw
        local count=math.max(1,math.ceil(length/.18))
        local sx,sz=dx/count,dz/count
        for step=1,count do
            local nx,nz=city:MoveShape(x,z,sx,sz,shape,yaw,mode,0,ignoreId)
            if math.abs(nx-(x+sx))>=.00001 or math.abs(nz-(z+sz))>=.00001 then
                local detail=string.format("[邻里移动被挡] path=%s mode=%s footprint=%s ignoreOnly=%s segment=%d step=%d/%d from=(%.9f,%.9f) delta=(%.9f,%.9f) expected=(%.9f,%.9f) actual=(%.9f,%.9f) goal=(%.6f,%.6f) StaticShapeFree=%s IsShapeFree=%s %s",
                    name,mode,vehicle and "模型同源轮廓" or "行人圆r.32",tostring(ignoreId),i,step,count,x,z,sx,sz,x+sx,z+sz,nx,nz,b[1],b[2],
                    tostring(city:StaticShapeFree(x+sx,z+sz,shape,yaw,mode,0)),
                    tostring(city:IsShapeFree(x+sx,z+sz,shape,yaw,mode,0,ignoreId)),
                    obstruction(city,x+sx,z+sz,vehicle and shape.reach or .32,mode))
                print(detail);error(detail)
            end
            x,z=nx,nz
            local y=city:Surface(x,z)
            assert(y>=.05 and y<=.11,string.format("道路地面断层 path=%s segment=%d point=(%.6f,%.6f) y=%.9f",name,i,x,z,y))
        end
        meters=meters+length
    end
    return meters
end
local function isolated(session)
    assert(session.options and session.options.test==true and type(session.restoreTestStorage)=="function",
        "邻里验收/实拍只允许持有隔离内存存储的Session")
end
function Checks.Run(session)
    isolated(session)
    local city=assert(session.city)
    local actor=assert(session.actor)
    local vehicleShape=require("Career.VehicleFootprints").Get(actor.vehicleId)
    local stats=Checks.Plan()
    local traffic,people,crowd,space=city.traffic,city.deliveryPeople,city.crowd,city.space
    city.traffic,city.deliveryPeople,city.crowd=nil,nil,nil
    local ok,message=pcall(function()
        assert(space=="city","请在城市空间执行邻里验收")
        local peds=require("Career.Pedestrians")
        for _,b in ipairs(Expansion.Buildings) do
            for _,p in ipairs(peds.Paths) do assert(not swept(b,p[1],p[2],p[3],p[4],.45),"旧8path被侵占") end
            for _,p in ipairs({{-28.6,-10.9},{-9.9,-73.3},{110.5,83.2},{-22,-11.1},
                {-19.1,-10.9},{-10,-66.5},{-11,-65.4},{-72.7,10.9}}) do
                assert(gap(b,p[1],p[2])>=.45,"旧联系人净空改变")
            end
        end
        for _,name in ipairs({"east","west","north","south"}) do
            local path=assert(Checks.Paths[name])
            local walk=movePath(city,path,actor,false,name)
            local ride=movePath(city,path,actor,true,name)
            near(walk,ride)
            print(string.format("[邻里验收] %s 行人/模型同源车辆轮廓连续扫掠各 %.1fm，City.MoveShape全子步及真实转角，仅ignore目标车；非Actor.Update动力输入",name,walk))
        end
        for _,r in ipairs(Expansion.Roads) do
            local count=math.ceil((math.abs(r.x2-r.x1)+math.abs(r.z2-r.z1))/.5)
            for i=0,count do
                local t=i/count
                local x,z=r.x1+(r.x2-r.x1)*t,r.z1+(r.z2-r.z1)*t
                local yaw=math.deg(math.atan(r.x2-r.x1,r.z2-r.z1))
                assert(city:StaticShapeFree(x,z,vehicleShape,yaw,"vehicle",0),"街段同源车辆轮廓净空 "..r.id)
                local y=city:Surface(x,z)
                assert(y>=.05 and y<=.11,"街段地面断层 "..r.id)
                if not World.IsOld(x,z) then near(y,World.Surface(x,z),"地面视觉/逻辑高度不一致") end
            end
        end
        local stream=city.stream
        stream:Ensure(0,-20,550)
        local first=stream:Stats()
        local nodes=stream.root:GetNumChildren(true)
        stream:Ensure(0,-20,550)
        local second=stream:Stats()
        assert(first.failed==0 and first.pending==0 and first.active<=80,"邻里流式未就绪/无界")
        assert(nodes==stream.root:GetNumChildren(true) and first.loaded==second.loaded,"重复预热节点增长")
        assert(first.models>=#Expansion.Buildings,"首屏550m未包含全部相邻真实模型")
        stats.loadedModels,stats.loadedNodes=first.models,nodes
    end)
    city.traffic,city.deliveryPeople,city.crowd=traffic,people,crowd
    assert(ok,message)
    print(string.format("[邻里模型预算] 原78+补%d=%d楼 / 4492面资产%d栋 / 最坏LOD0总%d面 / 每格最多%d面、%d楼；程序几何另限36k面/格",
        stats.infillBuildings,stats.buildings,stats.assetCounts[2],stats.modelTriangles,stats.maxCellModelTriangles,stats.maxCellBuildings))
    print(string.format("[邻里验收通过] %d街段/%.0fm中心线/%d楼/%d商铺/%d小广场；单块最多%d楼；旧31单完整route/费保留",
        stats.roads,stats.roadMeters,stats.buildings,stats.shops,stats.plazas,stats.maxCellBuildings))
    return stats
end
function Checks.Shot(session,id)
    isolated(session)
    local allowed=false
    for _,arg in ipairs(GetArguments()) do if arg=="-careercityshot="..id then allowed=true end end
    assert(allowed,"必须显式-careercityshot=<方向>")
    local positions={east={240,-44,0},west={-240,-44,0},north={24,240,90},south={24,-240,90},
        start={0,-20,25},plaza={338,-116,155}}
    local p=assert(positions[id],"街区实拍方向不存在")
    local a,city=assert(session.actor),assert(session.city)
    session:ApplySpace("city");session.online=false;session.waypoint=""
    session.traffic.active=false
    city.stream:Ensure(p[1],p[2],550)
    a.mounted=false;a.visuals:SetMounted(false)
    a.bikeX,a.bikeZ,a.bikeYaw=p[1]-2,p[2]-2,p[3]
    a:Teleport(p[1],p[2],p[3]);a.speed,a.steer=0,0;a:SyncVisuals(0)
    session:UpdateEnvironment(12)
    session.yaw,session.pitch=p[3],12
    session.camera:SetModeConfig("normal",{distance=7.8,offset=Vector3(0,1.4,0),fov=60})
    session.camera:SetMode("normal");session.camera:Update(2,a.node,session.yaw,session.pitch)
    session.view:ClosePhone();session.view:ShowGame();session.view:ResetInput();session:Refresh()
    session.view.overlay:SetVisible(false)
    print(string.format("[邻里实拍就绪] %s (%.1f,%.1f) 当前城市真实街面/正午/450m视距，无假背景",id,p[1],p[2]))
end
return Checks
