-- 米制常驻确定性世界；不创建引擎对象，不依赖Config/City/存档/网络。
-- 视觉块卸载不影响道路、目的地、静态碰撞与高度。
-- 接线：IsOld区域沿用原城；外域Surface/IsFree委托本模块。
-- SetLegacy复制旧城碰撞/地表，供不依赖视觉的全域查询与路线验证。
---@class CareerWorldPoint
---@field id string
---@field label string
---@field name string
---@field kind string
---@field x number
---@field z number
---@field district string
---@class CareerWorldRoad
---@field id string
---@field a table
---@field b table
---@field x1 number
---@field z1 number
---@field x2 number
---@field z2 number
---@field width number
---@field sidewalk number
---@field old boolean
---@field kind string
---@field nodes integer[]
---@class CareerWorldDistrict
---@field id string
---@field label string
---@field x number
---@field z number
---@field radius number
---@field style string
---@field density number
---@field bridge boolean
---@class CareerWorldCell
---@field ix number
---@field iz number
---@field x1 number
---@field x2 number
---@field z1 number
---@field z2 number
---@field grounds table[]
---@field hillGrounds? table[]
---@field buildings table[]
---@field trees table[]
---@field props table[]
---@field obstacles table[]
---@field bridges table[]
---@field points CareerWorldPoint[]
local World = {}
local Expansion = require("Career.CityExpansion")
local Environment = require("Career.CityEnvironment")
---@type CareerHillDistrict
local Hills = require("Career.HillDistrict")
-- 仅用于渲染与地图的接续几何；不插入既有订单使用的固定导航图。
---@type table[]
World.ExpansionRoads=Expansion.Roads
World.LIMIT, World.OLD_LIMIT, World.CELL = 15000, 195, 256
World.VIEW_DISTANCE, World.LOAD_DISTANCE, World.UNLOAD_DISTANCE = 450, 550, 850
World.CACHE_LIMIT, World.MAX_BUILDINGS, World.MAX_TREES = 128, 10, 16
---@type CareerWorldRoad[]
World.Roads = {}
---@type CareerWorldPoint[]
World.Points = {}
---@type table<string, CareerWorldPoint>
World.points = {}
World.Orders = {}
World.orderTemplates = World.Orders
---@type CareerWorldDistrict[]
World.Districts = {
    {id="east_market",label="东门市集",x=768,z=0,radius=384,style="market",density=.75,bridge=true},
    {id="west_garden",label="西苑生活区",x=-768,z=0,radius=384,style="residential",density=.6,bridge=true},
    {id="north_campus",label="北学府街",x=0,z=768,radius=384,style="campus",density=.48,bridge=true},
    {id="south_yards",label="南站工坊",x=0,z=-768,radius=384,style="industrial",density=.45,bridge=true},
    {id="canal_quarter",label="运河商埠",x=3072,z=3072,radius=576,style="market",density=.67,bridge=true},
    {id="cedar_town",label="杉林新镇",x=-3072,z=3072,radius=576,style="residential",density=.54,bridge=true},
    {id="east_tech",label="东岸科创园",x=6144,z=0,radius=576,style="office",density=.5,bridge=true},
    {id="west_works",label="西郊物流园",x=-6144,z=0,radius=576,style="industrial",density=.4,bridge=true},
    {id="north_lake",label="北湖花园",x=0,z=6144,radius=576,style="garden",density=.38,bridge=true},
    {id="south_station",label="南城客运区",x=0,z=-6144,radius=576,style="market",density=.6,bridge=true},
    {id="east_orchard",label="东郊果园镇",x=9216,z=-3072,radius=576,style="garden",density=.32,bridge=true},
    {id="west_village",label="西岭社区",x=-9216,z=-3072,radius=576,style="residential",density=.42,bridge=true},
}
local oldDistrict = {id="old_town",label="南城老街",x=0,z=0,radius=195,style="old",density=1,bridge=false}
local greenDistrict = {id="greenbelt",label="城郊绿带",x=0,z=0,radius=15000,style="greenbelt",density=.06,bridge=false}
-- 邻里只改变展示名称；id/样式/密度仍属绿带，不新增业务区或重算订单。
local neighborhoodDistrict = {id="greenbelt",label="南城邻里",x=0,z=0,radius=15000,style="greenbelt",density=.06,bridge=false}
---@type table<string, CareerWorldCell>
local cellCache = {}
---@type table<string, number>
local cacheAge = {}
local age, cacheCount = 0, 0
---@type table[]
local legacyObstacles, legacySurfaces = {}, {}
---@type table[]
local fixedBuildings, fixedProps, bridges = {}, {}, {}
---@type table<string, table[]>
local roadCells = {}
---@class CareerWorldGraphNode
---@field x number
---@field z number
---@field edges table<number, number>
---@type CareerWorldGraphNode[]
local nodes = {}
---@type table<string, number>
local nodeKeys = {}

-- 数值键：DescribeCell 每帧被外域碰撞裁剪调用，字符串键会持续产生GC垃圾。
local function key(x,z) return x*131072+z end
local function clamp(n,a,b) return math.max(a,math.min(b,n)) end
local function distance(x,z,tx,tz) return math.sqrt((tx-x)^2+(tz-z)^2) end
local function hash(x,z,salt)
    -- 整数哈希而非math.random，不扰动玩法随机序列。
    return ((x*73856093 ~ z*19349663 ~ salt*83492791) & 0x7fffffff)%100003/100003
end
---@param x number
---@param z number
---@return boolean
function World.IsOld(x,z) return math.abs(x)<=World.OLD_LIMIT and math.abs(z)<=World.OLD_LIMIT end
---@param x number
---@param z number
---@return CareerWorldDistrict
function World.District(x,z)
    if World.IsOld(x,z) then return oldDistrict end
    for _,d in ipairs(World.Districts) do
        if math.abs(x-d.x)<=d.radius and math.abs(z-d.z)<=d.radius then return d end
    end
    if math.abs(x)<=424 and math.abs(z)<=424 then return neighborhoodDistrict end
    return greenDistrict
end
---@param obstacles table[]
---@param surfaces? table[]
function World.SetLegacy(obstacles,surfaces)
    legacyObstacles,legacySurfaces={},{}
    for _,o in ipairs(obstacles) do
        legacyObstacles[#legacyObstacles+1]={x1=o.x1,z1=o.z1,x2=o.x2,z2=o.z2}
    end
    for _,s in ipairs(surfaces or {}) do
        legacySurfaces[#legacySurfaces+1]={x=s.x,z=s.z,w=s.w,d=s.d,y=s.y}
    end
end

local function addRoad(id,x1,z1,x2,z2,width,kind,old)
    local r={id=id,a={x=x1,z=z1},b={x=x2,z=z2},x1=x1,z1=z1,x2=x2,z2=z2,
        width=width,sidewalk=old and 6 or 4,old=old or false,kind=kind,nodes={}}
    World.Roads[#World.Roads+1]=r
    return r
end
-- 老街道路只作逻辑图；WorldStream绝不重画保护正方形内部。
for _,x in ipairs({-172,-100,0,100,172}) do addRoad("old_x"..x,x,-178,x,178,12,"old",true) end
for _,z in ipairs({-172,0,100,172}) do addRoad("old_z"..z,-178,z,178,z,12,"old",true) end
addRoad("meridian",0,-15000,0,15000,16,"arterial",false)
addRoad("equator",-15000,0,15000,0,16,"arterial",false)
for _,r in ipairs({3072,6144,9216,12288}) do
    addRoad("ring_n"..r,-r,r,r,r,16,"arterial",false)
    addRoad("ring_s"..r,-r,-r,r,-r,16,"arterial",false)
    addRoad("ring_e"..r,r,-r,r,r,16,"arterial",false)
    addRoad("ring_w"..r,-r,-r,-r,r,16,"arterial",false)
end
for _,d in ipairs(World.Districts) do
    for n=-math.floor(d.radius/192),math.floor(d.radius/192) do
        local o=n*192
        addRoad(d.id.."_x"..n,d.x+o,d.z-d.radius,d.x+o,d.z+d.radius,12,"local",false)
        addRoad(d.id.."_z"..n,d.x-d.radius,d.z+o,d.x+d.radius,d.z+o,12,"local",false)
    end
    if d.bridge then
        bridges[#bridges+1]={id=d.id.."_bridge",x=d.x,z=d.z+96,y=6.085,
            halfSpan=22,halfWidth=2,rampLength=64,rampOffset=20,width=4}
    end
end

local function roadRect(r,margin)
    local half=r.width/2+(margin or 0)
    if r.x1==r.x2 then
        return {x1=r.x1-half,x2=r.x1+half,z1=math.min(r.z1,r.z2),z2=math.max(r.z1,r.z2)}
    end
    return {x1=math.min(r.x1,r.x2),x2=math.max(r.x1,r.x2),z1=r.z1-half,z2=r.z1+half}
end
local function overlap(a,b)
    return a.x1<b.x2 and a.x2>b.x1 and a.z1<b.z2 and a.z2>b.z1
end
local function contains(r,x,z) return x>=r.x1 and x<=r.x2 and z>=r.z1 and z<=r.z2 end
for _,r in ipairs((function()
    local all={}
    for _,v in ipairs(World.Roads) do all[#all+1]=v end
    for _,v in ipairs(Expansion.Roads) do all[#all+1]=v end
    for _,v in ipairs(Hills.Roads) do all[#all+1]=v end
    return all
end)()) do
    local rect=roadRect(r,r.sidewalk)
    for ix=math.floor(rect.x1/256),math.floor(rect.x2/256) do
        for iz=math.floor(rect.z1/256),math.floor(rect.z2/256) do
            local k=key(ix,iz)
            local list=roadCells[k] or {}
            list[#list+1]=r
            roadCells[k]=list
        end
    end
end

---@param d CareerWorldDistrict
---@param suffix string
---@param label string
---@param kind string
---@param dx number
---@param dz number
local function point(d,suffix,label,kind,dx,dz)
    ---@type CareerWorldPoint
    local p={id="world_"..d.id.."_"..suffix,label=d.label..label,name=d.label..label,
        kind=kind,x=d.x+dx,z=d.z+dz,district=d.id}
    World.Points[#World.Points+1]=p; World.points[p.id]=p
    return p
end
for index,d in ipairs(World.Districts) do
    point(d,"kitchen","食堂取餐口","merchant",-64,21.4)
    point(d,"lobby","公寓收餐厅","delivery",64,21.4)
    point(d,"charge","公共充电站","charge",-28,-18)
    point(d,"rest","街心休息点","rest",32,-20)
    for _,side in ipairs({-1,1}) do
        fixedBuildings[#fixedBuildings+1]={id=d.id..(side<0 and "_kitchen" or "_lobby"),
            x=d.x+side*64,z=d.z+36,w=28,d=26,h=side<0 and 10.15 or 19.3,
            floors=side<0 and 3 or 6,yaw=0,style=side<0 and "brick" or "plaster",
            name=d.label..(side<0 and " · 社区食堂" or " · 公寓"),asset=side>0 and (index%3+1) or nil}
    end
    fixedProps[#fixedProps+1]={kind="charge",x=d.x-26,z=d.z-18,w=.7,d=.7,h=1.6}
    fixedProps[#fixedProps+1]={kind="bench",x=d.x+32,z=d.z-22,w=2.3,d=.8,h=1.35}
end

-- 所有交叉/同轴重叠路段精确切分为有限常驻道路图。
local function node(x,z)
    local k=key(x,z)
    local id=nodeKeys[k]
    if id then return id end
    nodes[#nodes+1]={x=x,z=z,edges={}}; id=#nodes; nodeKeys[k]=id
    return id
end
local function onRoad(r,x,z)
    return x>=math.min(r.x1,r.x2) and x<=math.max(r.x1,r.x2)
        and z>=math.min(r.z1,r.z2) and z<=math.max(r.z1,r.z2)
        and (r.x1==r.x2 and x==r.x1 or r.z1==r.z2 and z==r.z1)
end
for _,r in ipairs(World.Roads) do node(r.x1,r.z1);node(r.x2,r.z2) end
for i,r in ipairs(World.Roads) do
    for j=i+1,#World.Roads do
        local s=World.Roads[j]
        if (r.x1==r.x2)~=(s.x1==s.x2) then
            local x=r.x1==r.x2 and r.x1 or s.x1
            local z=r.z1==r.z2 and r.z1 or s.z1
            if onRoad(r,x,z) and onRoad(s,x,z) then node(x,z) end
        end
    end
end
for _,r in ipairs(World.Roads) do
    for id,n in ipairs(nodes) do if onRoad(r,n.x,n.z) then r.nodes[#r.nodes+1]=id end end
    table.sort(r.nodes,function(a,b)
        return nodes[a].x+nodes[a].z<nodes[b].x+nodes[b].z
    end)
    for i=2,#r.nodes do
        local a,b=assert(r.nodes[i-1]),assert(r.nodes[i])
        local left,right=assert(nodes[a]),assert(nodes[b])
        local length=distance(left.x,left.z,right.x,right.z)
        left.edges[b]=length;right.edges[a]=length
    end
end
World.GraphStats={nodes=#nodes,roads=#World.Roads}

-- 矩形相减：地面、沥青和人行道都裁掉旧城保护范围。
local function subtract(rect,cut)
    if not overlap(rect,cut) then return {rect} end
    local out={}
    local x1,x2=math.max(rect.x1,cut.x1),math.min(rect.x2,cut.x2)
    local z1,z2=math.max(rect.z1,cut.z1),math.min(rect.z2,cut.z2)
    if rect.x1<x1 then out[#out+1]={x1=rect.x1,x2=x1,z1=rect.z1,z2=rect.z2} end
    if x2<rect.x2 then out[#out+1]={x1=x2,x2=rect.x2,z1=rect.z1,z2=rect.z2} end
    if rect.z1<z1 then out[#out+1]={x1=x1,x2=x2,z1=rect.z1,z2=z1} end
    if z2<rect.z2 then out[#out+1]={x1=x1,x2=x2,z1=z2,z2=rect.z2} end
    return out
end
local protected={x1=-195,x2=195,z1=-195,z2=195}
local function ground(cell,rect,material,y,cuts)
    local clipped={x1=math.max(rect.x1,cell.x1),x2=math.min(rect.x2,cell.x2),
        z1=math.max(rect.z1,cell.z1),z2=math.min(rect.z2,cell.z2)}
    if clipped.x1>=clipped.x2 or clipped.z1>=clipped.z2 then return end
    local pieces=subtract(clipped,protected)
    for _,region in ipairs({Environment.Bounds,Environment.Connector}) do
        local nextPieces={}
        for _,p in ipairs(pieces) do for _,q in ipairs(subtract(p,region)) do nextPieces[#nextPieces+1]=q end end
        pieces=nextPieces
    end
    for _,cut in ipairs(cuts or {}) do
        local nextPieces={}
        for _,p in ipairs(pieces) do for _,q in ipairs(subtract(p,cut)) do nextPieces[#nextPieces+1]=q end end
        pieces=nextPieces
    end
    for _,p in ipairs(pieces) do
        p.material,p.y=material,y
        -- 山区仍保留全部道路/人行道/铺装描述，按同源三角面投影，不删除横路。
        if Hills.Reserved(p) then
            cell.hillGrounds=cell.hillGrounds or {}
            local inside={x1=math.max(p.x1,Hills.Bounds.x1),x2=math.min(p.x2,Hills.Bounds.x2),
                z1=math.max(p.z1,Hills.Bounds.z1),z2=math.min(p.z2,Hills.Bounds.z2),material=material,y=material=="grass" and 0 or .055}
            if material~="grass" then
                -- 全部山区步行铺装与逻辑支撑同高：后铺的路/院地先裁掉旧片，避免共面闪烁。
                local nextGrounds={}
                for _,old in ipairs(cell.hillGrounds) do
                    for _,piece in ipairs(subtract(old,inside)) do
                        piece.material,piece.y=old.material,old.y
                        nextGrounds[#nextGrounds+1]=piece
                    end
                end
                nextGrounds[#nextGrounds+1]=inside
                cell.hillGrounds=nextGrounds
            end
            for _,outside in ipairs(subtract(p,Hills.Bounds)) do
                outside.material,outside.y=material,y
                cell.grounds[#cell.grounds+1]=outside
            end
        else cell.grounds[#cell.grounds+1]=p end
    end
end
local function obstacle(cell,x,z,w,d,y1,y2,kind)
    cell.obstacles[#cell.obstacles+1]={x1=x-w/2,x2=x+w/2,z1=z-d/2,z2=z+d/2,
        y1=y1 or 0,y2=y2 or 30,kind=kind or "solid"}
end
local function building(cell,b,cuts)
    cell.buildings[#cell.buildings+1]=b
    local w,d=b.w,b.d
    if b.yaw%180~=0 then w,d=d,w end
    -- 包含地基15cm外扩；高于人物的屋檐不算地面碰撞。
    obstacle(cell,b.x,b.z,w+(b.expansion and .1 or .3),d+(b.expansion and .1 or .3),
        b.foundationY or 0,(b.baseY or 0)+b.h,"building")
    if b.expansion then
        -- 真正的门前/侧院铺装，不让每栋矗立在整片棕土地上；裁掉所有机动车道。
        ground(cell,{x1=b.x-w/2-2.1,x2=b.x+w/2+2.1,z1=b.z-d/2-2.1,z2=b.z+d/2+2.1},"concrete",.085,cuts)
    else
        ground(cell,{x1=b.x-w/2-3,x2=b.x+w/2+3,z1=b.z-d/2-3,z2=b.z+d/2+3},"concrete",.085)
    end
end
local function owner(cell,x,z) return math.floor(x/256)==cell.ix and math.floor(z/256)==cell.iz end
local function reserved(rect)
    if Hills.Reserved(rect) and not Hills.Buildable(rect) then return true end
    if Environment.Reserved(rect) then return true end
    if overlap(rect,protected) then return true end
    for _,d in ipairs(World.Districts) do
        if overlap(rect,{x1=d.x-110,x2=d.x+110,z1=d.z-64,z2=d.z+64}) then return true end
    end
    for _,b in ipairs(bridges) do
        if overlap(rect,{x1=b.x-27,x2=b.x+27,z1=b.z-70,z2=b.z+7}) then return true end
    end
    return false
end
local function clearRoad(rect,list)
    for _,r in ipairs(list) do if overlap(rect,roadRect(r,r.sidewalk+2)) then return false end end
    return true
end

---@param ix number
---@param iz number
---@return CareerWorldCell
function World.DescribeCell(ix,iz)
    ix,iz=math.floor(ix),math.floor(iz)
    local k=key(ix,iz)
    age=age+1
    local cached=cellCache[k]
    if cached then cacheAge[k]=age;return cached end
    ---@type CareerWorldCell
    local cell={ix=ix,iz=iz,x1=math.max(-15000,ix*256),x2=math.min(15000,(ix+1)*256),
        z1=math.max(-15000,iz*256),z2=math.min(15000,(iz+1)*256),grounds={},buildings={},trees={},props={},obstacles={},bridges={},points={}}
    if cell.x1>=cell.x2 or cell.z1>=cell.z2 then return cell end
    -- 完全空旷的块也必须具有连续、已裁剪的地面。
    ground(cell,cell,"grass",0)
    -- 邻里内院先铺连续石地，外街后保留植栽过渡。
    -- 不再出现195..384m草地护城河，也不增加全城常驻几何。
    ground(cell,{x1=-368,x2=368,z1=-368,z2=368},"stone",.025)
    local list=roadCells[k] or {}
    local cuts={}
    for _,r in ipairs(list) do if not r.old then cuts[#cuts+1]=roadRect(r,0) end end
    -- 台地住宅的公共院地接纵街人行带；裁掉车道，避免同高铺装重叠闪烁。
    for _,side in ipairs({-1,1}) do
        for _,range in ipairs({{272,336},{432,480}}) do
            ground(cell,{x1=side<0 and -range[2] or range[1],x2=side<0 and -range[1] or range[2],
                z1=736,z2=928},"concrete",.055,cuts)
        end
    end
    for _,r in ipairs(list) do
        if not r.old then
            local outer,inner=roadRect(r,r.sidewalk),roadRect(r,0)
            for _,strip in ipairs(subtract(outer,inner)) do ground(cell,strip,"concrete",.085,cuts) end
            ground(cell,inner,"road",.055)
        end
    end
    -- 新楼障碍与可见地基共用实测、正交旋转后的AABB；视觉块卸载不删碰撞。
    for _,b in ipairs(Expansion.Buildings) do if owner(cell,b.x,b.z) then building(cell,b,cuts) end end
    for _,b in ipairs(Hills.Buildings) do if owner(cell,b.x,b.z) then building(cell,b,cuts) end end
    for _,p in ipairs(Expansion.Plazas) do
        ground(cell,{x1=p.x-p.w/2,x2=p.x+p.w/2,z1=p.z-p.d/2,z2=p.z+p.d/2},"concrete",.085,cuts)
        -- 3m入口接到真实共享巷道，不生成孤立广场。
        if p.id=="east" or p.id=="west" then
            ground(cell,{x1=math.min(p.x,312*(p.x>0 and 1 or -1)),x2=math.max(p.x,312*(p.x>0 and 1 or -1)),
                z1=p.z-1.5,z2=p.z+1.5},"concrete",.085,cuts)
        else
            ground(cell,{x1=p.x-1.5,x2=p.x+1.5,z1=math.min(p.z,312*(p.z>0 and 1 or -1)),
                z2=math.max(p.z,312*(p.z>0 and 1 or -1))},"concrete",.085,cuts)
        end
    end
    for _,p in ipairs(Expansion.Props) do
        if owner(cell,p.x,p.z) then
            cell.props[#cell.props+1]=p
            obstacle(cell,p.x,p.z,p.w,p.d,0,p.h,p.kind)
        end
    end
    for _,b in ipairs(fixedBuildings) do if owner(cell,b.x,b.z) then building(cell,b) end end
    for _,p in ipairs(fixedProps) do
        if owner(cell,p.x,p.z) then
            cell.props[#cell.props+1]=p
            obstacle(cell,p.x,p.z,p.w,p.d,0,p.h,p.kind)
        end
    end
    for _,p in ipairs(World.Points) do
        if owner(cell,p.x,p.z) then
            cell.points[#cell.points+1]=p
            ground(cell,{x1=p.x-2,x2=p.x+2,z1=p.z-2,z2=p.z+2},"stone",.085)
        end
    end
    for _,b in ipairs(bridges) do
        if owner(cell,b.x,b.z) then cell.bridges[#cell.bridges+1]=b end
        for _,side in ipairs({-1,1}) do
            ground(cell,{x1=b.x+side*20-2,x2=b.x+side*20+2,z1=b.z-68,z2=b.z-64},"concrete",.085)
        end
    end
    -- 64m地块形成局部紧凑街区，不全图密集铺楼；绿带仅沿路有少量工坊。
    for lx=0,3 do
        for lz=0,3 do
            local gx,gz=ix*4+lx,iz*4+lz
            local x,z=gx*64+32,gz*64+32
            local d=World.District(x,z)
            local density=d.density
            local nearRoad=false
            for _,r in ipairs(list) do
                local rr=roadRect(r,90)
                if contains(rr,x,z) then nearRoad=true;break end
            end
            if d.id=="greenbelt" then density=nearRoad and .11 or 0 end
            local value=hash(gx,gz,7)
            local w=20+math.floor(hash(gx,gz,13)*9)
            local depth=22+math.floor(hash(gx,gz,23)*9)
            local rect={x1=x-18,x2=x+18,z1=z-18,z2=z+18}
            if d.id~="old_town" and nearRoad and value<density and #cell.buildings<World.MAX_BUILDINGS
                and not Expansion.Reserved(rect) and not reserved(rect) and clearRoad(rect,list)
                and rect.x1>=-14998 and rect.x2<=14998 and rect.z1>=-14998 and rect.z2<=14998 then
                local floors=d.style=="industrial" and 2 or d.style=="office" and 6 or 2+math.floor(hash(gx,gz,31)*4)
                local yaw=hash(gx,gz,37)<.5 and 0 or 180
                local style=d.style=="industrial" and "brick" or d.style=="office" and "stone" or "plaster"
                building(cell,{id="parcel_"..gx.."_"..gz,x=x,z=z,w=w,d=depth,h=floors*3.05+1,
                    floors=floors,yaw=yaw,style=style,name=(d.id=="greenbelt" and "郊野工坊" or d.label).." "..((gx*7+gz*11)%99+1)})
            end
            -- 每地块两处确定性候选树位，避开道路、服务前庭、桥坡与楼体。
            for t=1,2 do
                local tx=x+(hash(gx,gz,40+t)*2-1)*21
                local tz=z+(hash(gx,gz,50+t)*2-1)*21
                local tr={x1=tx-2.5,x2=tx+2.5,z1=tz-2.5,z2=tz+2.5}
                local free=not Expansion.Reserved(tr) and not reserved(tr) and clearRoad(tr,list)
                for _,o in ipairs(cell.obstacles) do if overlap(tr,o) then free=false;break end end
                if free and #cell.trees<World.MAX_TREES and hash(gx,gz,60+t)<(d.id=="greenbelt" and .34 or .48)
                    and tr.x1>=cell.x1 and tr.x2<=cell.x2 and tr.z1>=cell.z1 and tr.z2<=cell.z2 then
                    local h=4+hash(gx,gz,70+t)*3
                    cell.trees[#cell.trees+1]={x=tx,z=tz,h=h,r=1.8+hash(gx,gz,80+t)}
                    obstacle(cell,tx,tz,.48,.48,0,h,"tree")
                end
            end
        end
    end
    for _,o in ipairs(Environment.CollectObstacles(cell)) do cell.obstacles[#cell.obstacles+1]=o end
    for _,o in ipairs(Hills.Obstacles(cell)) do cell.obstacles[#cell.obstacles+1]=o end
    if cacheCount>=World.CACHE_LIMIT then
        local oldestKey,oldestAge="",math.huge
        for ck,ca in pairs(cacheAge) do if ca<oldestAge then oldestKey,oldestAge=ck,ca end end
        cellCache[oldestKey],cacheAge[oldestKey]=nil,nil
        cacheCount=cacheCount-1
    end
    cellCache[k],cacheAge[k]=cell,age;cacheCount=cacheCount+1
    return cell
end

-- 碰撞设计（米）：地面建筑AABB/树干0.48m；角色半径外扩AABB。
-- 天桥俯视：        x=-22  -18      道路x=0       +18  +22
--                       | 坡道 |      16m           | 坡道 |
-- z=桥中心          +===+====== 可步行桥面 =========+===+  y=6.085
--                       |      |                    |   |
-- z=桥中心-64           + 入口 +                    +入口+  y=.085
-- 坡道是4m宽实心楔体，62m升6m；桥栏阻止高处侧落，不在桥下生成横墙。
-- 支柱在车道外，车辆不能进入坡道。步行必须带上一子步height，
-- 每子步<=.1m，避免人在桥下被全局最高Surface瞬移到桥上。
local function bridgeHeight(b,x,z)
    local dx,dz=x-b.x,z-b.z
    if math.abs(dx)<=22 and math.abs(dz)<=2 then return b.y end
    if math.abs(math.abs(dx)-20)<=2 and dz>=-64 and dz<=-2 then
        return .085+(dz+64)/62*6
    end
    return nil
end
local function groundHeight(x,z)
    if World.IsOld(x,z) then
        local y=0
        for _,s in ipairs(legacySurfaces) do
            if math.abs(x-s.x)<=s.w/2 and math.abs(z-s.z)<=s.d/2 then y=math.max(y,s.y) end
        end
        return y
    end
    local cell=World.DescribeCell(math.floor(x/256),math.floor(z/256))
    local y=0
    for _,s in ipairs(cell.grounds) do if contains(s,x,z) then y=math.max(y,s.y) end end
    return y
end
---@param x number
---@param z number
---@param mode? string 默认vehicle；步行传walk
---@param height? number 上一子步步行高度，不使用全局可变桥层
---@return number
function World.Surface(x,z,mode,height)
    local terrain=Environment.Surface(x,z)
    if terrain~=nil then return terrain end
    local hill=Hills.Surface(x,z)
    local groundY=hill or groundHeight(x,z)
    if mode~="walk" or height==nil then return groundY end
    for _,b in ipairs(bridges) do
        if math.abs(x-b.x)<=24 and z>=b.z-65 and z<=b.z+3 then
            local h=bridgeHeight(b,x,z)
            if h and math.abs(height-h)<=.65 then return math.max(groundY,h) end
        end
    end
    return groundY
end
local function hit(o,x,z,r)
    return x>o.x1-r and x<o.x2+r and z>o.z1-r and z<o.z2+r
end
local function bridgeFree(x,z,r,mode,height)
    local elevated=mode=="walk" and (height or 0)>groundHeight(x,z)+.65
    if Hills.Contains(x,z) then elevated=false end
    local supported=false
    for _,b in ipairs(bridges) do
        local dx,dz=x-b.x,z-b.z
        if math.abs(dx)<25+r and dz> -67-r and dz<4+r then
            local top=bridgeHeight(b,x,z)
            if mode=="walk" and height~=nil and top and math.abs(top-height)<=.65 then
                supported=true
                -- 圆形角色沿桥面/坡面并集内缩，不在接缝生成横向空气墙。
                for _,offset in ipairs({{r,0},{-r,0},{0,r},{0,-r}}) do
                    local sample=bridgeHeight(b,x+offset[1],z+offset[2])
                    if not sample and top>.65 then return false end
                end
            else
                -- 实心坡道挡住地面移动；桥面下保留通道。
                for _,side in ipairs({-1,1}) do
                    local ramp={x1=b.x+side*20-2,x2=b.x+side*20+2,z1=b.z-64,z2=b.z-2}
                    local entering=mode=="walk" and height~=nil and height<=.65 and dz<=-64
                        and math.abs(dx-side*20)<=2-r
                    if hit(ramp,x,z,r) and not entering then return false end
                end
            end
            -- 地面支柱是真实障碍，但不挡住桥面上的行人。
            if not top or not height or height<3 then
                for _,side in ipairs({-1,1}) do
                    if hit({x1=b.x+side*14-.6,x2=b.x+side*14+.6,z1=b.z-.6,z2=b.z+.6},x,z,r) then return false end
                end
            end
        end
    end
    return not elevated or supported
end
---@param x number
---@param z number
---@param radius? number
---@param mode? string 默认vehicle；只有walk允许上桥
---@param height? number 上一子步步行高度
---@return boolean
function World.IsFree(x,z,radius,mode,height)
    local r=math.max(0,radius or .32)
    if x~=x or z~=z or math.abs(x)>15000-r or math.abs(z)>15000-r then return false end
    if Environment.Surface(x,z)==nil and not bridgeFree(x,z,r,mode or "vehicle",height) then return false end
    if math.abs(x)<195+r and math.abs(z)<195+r then
        for _,o in ipairs(legacyObstacles) do if hit(o,x,z,r) then return false end end
    end
    -- 同时查询邻格：圆半径触及隔壁墙不能从256m接缝钻过；LRU淘汰后确定性重建。
    for ix=math.floor((x-r-32)/256),math.floor((x+r+32)/256) do
        for iz=math.floor((z-r-32)/256),math.floor((z+r+32)/256) do
            local cell=World.DescribeCell(ix,iz)
            for _,o in ipairs(cell.obstacles) do
                if hit(o,x,z,r) and ((height or 0)<o.y2 and (height or 0)+1.8>o.y1) then return false end
            end
        end
    end
    return true
end

-- 精确轴对齐扫掠矩形，不用稀疏采样跳过树干。
local function segmentFree(a,b,r)
    if a.x~=b.x and a.z~=b.z then return false end
    local area={x1=math.min(a.x,b.x)-r,x2=math.max(a.x,b.x)+r,
        z1=math.min(a.z,b.z)-r,z2=math.max(a.z,b.z)+r}
    for ix=math.floor((area.x1-32)/256),math.floor((area.x2+32)/256) do
        for iz=math.floor((area.z1-32)/256),math.floor((area.z2+32)/256) do
            for _,o in ipairs(World.DescribeCell(ix,iz).obstacles) do if overlap(area,o) then return false end end
        end
    end
    for _,o in ipairs(legacyObstacles) do if overlap(area,o) then return false end end
    for _,br in ipairs(bridges) do
        for _,side in ipairs({-1,1}) do
            if overlap(area,{x1=br.x+side*20-2,x2=br.x+side*20+2,z1=br.z-64,z2=br.z-2}) then return false end
        end
        for _,side in ipairs({-1,1}) do
            if overlap(area,{x1=br.x+side*14-.6,x2=br.x+side*14+.6,z1=br.z-.6,z2=br.z+.6}) then return false end
        end
    end
    return true
end
World.SegmentFree=segmentFree
local function append(route,p)
    local last=route[#route]
    if not last or last.x~=p.x or last.z~=p.z then route[#route+1]={x=p.x,z=p.z} end
end
local function connector(x,z,tx,tz)
    local a,b={x=x,z=z},{x=tx,z=tz}
    for _,corner in ipairs({{x=x,z=tz},{x=tx,z=z}}) do
        if segmentFree(a,corner,1.2) and segmentFree(corner,b,1.2) then
            local path={a};append(path,corner);append(path,b)
            return path
        end
    end
    return nil
end
local function attach(x,z)
    local candidates={}
    for _,r in ipairs(World.Roads) do
        local px=clamp(x,math.min(r.x1,r.x2),math.max(r.x1,r.x2))
        local pz=clamp(z,math.min(r.z1,r.z2),math.max(r.z1,r.z2))
        candidates[#candidates+1]={road=r,x=px,z=pz,cost=math.abs(px-x)+math.abs(pz-z)}
    end
    table.sort(candidates,function(a,b) return a.cost<b.cost end)
    for i=1,math.min(20,#candidates) do
        local c=candidates[i]
        local path=connector(x,z,c.x,c.z)
        if path then
            c.path=path;c.links={}
            local ids=c.road.nodes
            for n=2,#ids do
                local a,b=nodes[ids[n-1]],nodes[ids[n]]
                if c.x>=math.min(a.x,b.x) and c.x<=math.max(a.x,b.x)
                    and c.z>=math.min(a.z,b.z) and c.z<=math.max(a.z,b.z) then
                    c.links[ids[n-1]]=distance(c.x,c.z,a.x,a.z)
                    c.links[ids[n]]=distance(c.x,c.z,b.x,b.z)
                    break
                end
            end
            return c
        end
    end
    return nil
end
local function push(heap,id,cost)
    local i=#heap+1
    heap[i]={id=id,cost=cost}
    while i>1 do
        local parent=math.floor(i/2)
        if heap[parent].cost<=cost then break end
        heap[i],heap[parent]=heap[parent],heap[i];i=parent
    end
end
local function pop(heap)
    local first=heap[1]
    local tail=table.remove(heap)
    if #heap>0 then
        heap[1]=tail
        local i=1
        while i*2<=#heap do
            local child=i*2
            if child<#heap and heap[child+1].cost<heap[child].cost then child=child+1 end
            if heap[i].cost<=heap[child].cost then break end
            heap[i],heap[child]=heap[child],heap[i];i=child
        end
    end
    return first
end
---@param x number|table
---@param z number|table
---@param tx? number
---@param tz? number
---@return table[]|nil, string|nil
function World.Route(x,z,tx,tz)
    -- 同时支持四数坐标与两个{x,z}点参数。
    if type(x)=="table" and type(z)=="table" then x,z,tx,tz=x.x,x.z,z.x,z.z end
    if type(x)~="number" or type(z)~="number" or type(tx)~="number" or type(tz)~="number"
        or x~=x or z~=z or tx~=tx or tz~=tz or math.abs(x)>15000 or math.abs(z)>15000
        or math.abs(tx)>15000 or math.abs(tz)>15000 then return nil,"outside world bounds" end
    local start,finish=attach(x,z),attach(tx,tz)
    if not start or not finish then return nil,"no unobstructed road access" end
    if start.road==finish.road then
        local result={}
        for _,p in ipairs(start.path) do append(result,p) end
        append(result,finish)
        for i=#finish.path-1,1,-1 do append(result,finish.path[i]) end
        return result
    end
    local heap,dist,previous,done={},{},{},{}
    for id,cost in pairs(start.links) do dist[id]=cost;push(heap,id,cost) end
    while #heap>0 do
        local item=pop(heap)
        local id=item.id
        if not done[id] then
            done[id]=true
            for nextId,cost in pairs(nodes[id].edges) do
                local nd=item.cost+cost
                if not dist[nextId] or nd<dist[nextId] then
                    dist[nextId]=nd;previous[nextId]=id;push(heap,nextId,nd)
                end
            end
        end
    end
    local endId,best=0,math.huge
    for id,cost in pairs(finish.links) do
        if dist[id] and dist[id]+cost<best then endId,best=id,dist[id]+cost end
    end
    if endId==0 then return nil,"disconnected road graph" end
    local reverse={endId}
    local cursor=endId
    while previous[cursor] do cursor=previous[cursor];reverse[#reverse+1]=cursor end
    local result={}
    for _,p in ipairs(start.path) do append(result,p) end
    for i=#reverse,1,-1 do append(result,nodes[reverse[i]]) end
    append(result,finish)
    for i=#finish.path-1,1,-1 do append(result,finish.path[i]) end
    -- 合并同轴连续段，但保留所有直角转弯供地图显示。
    local compact={}
    for _,p in ipairs(result) do
        local a,b=compact[#compact-1],compact[#compact]
        if a and b and (a.x==b.x and b.x==p.x or a.z==b.z and b.z==p.z) then compact[#compact]=p
        else compact[#compact+1]=p end
    end
    return compact
end

-- 动态显示导航独立于 Route：Route 仍只服务既有31单模板/报价，绝不插入桥层边。
-- 层判定只认本桥的实际支撑高度；海岸4m地面仍是ground，桥下同XZ也不吸到桥面。
---@param x number
---@param z number
---@param height? number 当前脚底高度；省略时兼容旧地面导航
---@param mode? string vehicle强制ground，其余按步行高度判断
---@return string
function World.NavigationLayer(x,z,height,mode)
    if mode=="vehicle" or height==nil then return "ground" end
    -- 绝大多数查询不在桥附近；先用常驻桥边界筛选，不为缓存key逐帧生成地块描述。
    for _,b in ipairs(bridges) do
        local top=bridgeHeight(b,x,z)
        if top and math.abs(top-height)<=.65 then
            local groundY=World.Surface(x,z,"vehicle",0)
            -- 坡脚与地面同高时仍可从明确入口退出；不把桥下0m误投到低坡。
            if height>groundY+.01 or math.abs(top-groundY)<=.01 and math.abs(top-height)<=.01 then
                return "bridge:"..b.id
            end
        end
    end
    return "ground"
end
-- Shared interaction support, independent of absolute altitude. Callers supply
-- their own city's Surface result (including interior .085 floors); bridge/ramp
-- is never a ground-service layer, and unsupported poses cannot authorise actions.
---@param x number
---@param z number
---@param height number
---@param groundHeight number
---@return boolean
function World.HasGroundSupport(x,z,height,groundHeight)
    return type(height)=="number" and type(groundHeight)=="number"
        and height==height and groundHeight==groundHeight and math.abs(height-groundHeight)<=.05
        and World.NavigationLayer(x,z,height,"walk")=="ground"
end
local function navigationAppend(route,p)
    local last=route[#route]
    if not last or last.x~=p.x or last.z~=p.z or last.y~=p.y or last.layer~=p.layer then
        route[#route+1]={x=p.x,z=p.z,y=p.y,layer=p.layer}
    end
end
local function navigationLength(route)
    local total=0
    for i=2,#route do
        local a,b=route[i-1],route[i]
        total=total+math.sqrt((b.x-a.x)^2+(b.z-a.z)^2+((b.y or 0)-(a.y or 0))^2)
    end
    return total
end
local function hillNavigation(x,z,tx,tz)
    if not Hills.LocalRoute or not Hills.NavigationEntries
        or not Hills.Contains(x,z) and not Hills.Contains(tx,tz) then return nil end
    local direct=Hills.LocalRoute(x,z,tx,tz)
    if direct then return direct end
    local starts,finishes={},{}
    for _,entry in ipairs(Hills.NavigationEntries) do
        local outgoing=Hills.LocalRoute(x,z,entry.x,entry.z)
        local incoming=Hills.LocalRoute(entry.x,entry.z,tx,tz)
        if outgoing then starts[#starts+1]={entry=entry,path=outgoing} end
        if incoming then finishes[#finishes+1]={entry=entry,path=incoming} end
    end
    if #starts==0 and #finishes==0 then return nil end
    if #starts==0 then starts[1]={entry={x=x,z=z},path={}} end
    if #finishes==0 then finishes[1]={entry={x=tx,z=tz},path={}} end
    local best,bestLength=nil,math.huge
    for _,a in ipairs(starts) do for _,b in ipairs(finishes) do
        local middle=World.Route(a.entry.x,a.entry.z,b.entry.x,b.entry.z)
        if middle then
            local route={}
            for _,p in ipairs(a.path) do navigationAppend(route,p) end
            for _,p in ipairs(middle) do
                navigationAppend(route,{x=p.x,z=p.z,y=World.Surface(p.x,p.z,"vehicle",0),layer="ground"})
            end
            for _,p in ipairs(b.path) do navigationAppend(route,p) end
            local length=navigationLength(route)
            if length<bestLength then best,bestLength=route,length end
        end
    end end
    return best
end
-- 桥层有限连接图（米，与bridgeHeight/bridgeFree共用边界）：
-- deck z=0:      (-20,6.085) =========== (+20,6.085)
--                    |                       |
-- ramp z=-2:     (-20,6.085)              (+20,6.085)
-- ramp z=-64:    (-20,.085)               (+20,.085)
-- ground z=-66:  (-20,.085)               (+20,.085) -> 原地面路网
-- 只有两个坡脚能换层；不以同XZ地面投影作捷径。坡上起点可向上跨桥或原坡返回。
---@param x number
---@param z number
---@param tx number
---@param tz number
---@param height? number 当前步行脚底高度，不是全局海拔阈值
---@param layer? string ground或NavigationLayer返回的bridge:<id>；vehicle调用方显式ground
---@return table[]|nil, string|nil
function World.NavigationRoute(x,z,tx,tz,height,layer)
    if type(x)~="number" or type(z)~="number" or type(tx)~="number" or type(tz)~="number"
        or x~=x or z~=z or tx~=tx or tz~=tz or math.abs(x)>World.LIMIT or math.abs(z)>World.LIMIT
        or math.abs(tx)>World.LIMIT or math.abs(tz)>World.LIMIT
        or height~=nil and (type(height)~="number" or height~=height or math.abs(height)==math.huge) then return nil,"invalid navigation coordinates" end
    local resolved=layer or World.NavigationLayer(x,z,height)
    if resolved=="ground" then
        -- 显式ground用于骑行；自动步行不能把一个无支撑的高处坐标静默降到地面。
        if not layer and height and math.abs(height-World.Surface(x,z,"vehicle",0))>.65 then
            return nil,"unsupported navigation height"
        end
        local hillsRoute=hillNavigation(x,z,tx,tz)
        if hillsRoute then return hillsRoute end
        local exit=Hills.ExitRoute(x,z)
        if exit then
            local entry=exit[#exit]
            local tail=World.Route(entry.x,entry.z,tx,tz)
            if not tail then return nil,"no terrace road access" end
            for _,p in ipairs(tail) do
                navigationAppend(exit,{x=p.x,z=p.z,y=World.Surface(p.x,p.z,"vehicle",0),layer="ground"})
            end
            return exit
        end
        return World.Route(x,z,tx,tz)
    end
    for _,b in ipairs(bridges) do if resolved=="bridge:"..b.id then
        local top=bridgeHeight(b,x,z)
        if not top or height and math.abs(top-height)>.65 or not World.IsFree(x,z,.32,"walk",top) then
            return nil,"unsupported bridge start"
        end
        local bestRoute,bestLength={},math.huge
        local startSide=x<b.x and -1 or 1
        for _,side in ipairs({-1,1}) do
            local footX,footZ=b.x+side*20,b.z-66
            local groundRoute=World.Route(footX,footZ,tx,tz)
            if groundRoute then
                local route={}
                local function bridgePoint(px,pz)
                    navigationAppend(route,{x=px,z=pz,y=assert(bridgeHeight(b,px,pz)),layer=resolved})
                end
                bridgePoint(x,z)
                if z<b.z-2 then
                    bridgePoint(b.x+startSide*20,z)
                    if side~=startSide then
                        bridgePoint(b.x+startSide*20,b.z-2)
                        bridgePoint(b.x+startSide*20,b.z)
                        bridgePoint(footX,b.z)
                        bridgePoint(footX,b.z-2)
                    end
                else
                    -- 先在4m宽桥面中心线上横移，再转入坡道；不切内侧空角。
                    bridgePoint(x,b.z)
                    bridgePoint(footX,b.z)
                    bridgePoint(footX,b.z-2)
                end
                bridgePoint(footX,b.z-64)
                for _,p in ipairs(groundRoute) do
                    navigationAppend(route,{x=p.x,z=p.z,y=World.Surface(p.x,p.z,"vehicle",0),layer="ground"})
                end
                local cost=navigationLength(route)
                if cost<bestLength then bestRoute,bestLength=route,cost end
            end
        end
        if #bestRoute==0 then return nil,"no unobstructed bridge ramp access" end
        return bestRoute
    end end
    return nil,"unknown navigation layer"
end

-- 只追加新模板，不重排/重写旧单。1游戏小时450现实秒，
-- 平均12km/h每游戏小时1500m；路程时限再加半游戏小时取送余量。
for i,d in ipairs(World.Districts) do
    local nextDistrict=World.Districts[i%#World.Districts+1]
    for _,trip in ipairs({{d,"社区热餐"},{nextDistrict,"跨区便当"}}) do
        local pickup=World.points["world_"..d.id.."_kitchen"]
        local dropoff=World.points["world_"..trip[1].id.."_lobby"]
        local route=World.Route(pickup.x,pickup.z,dropoff.x,dropoff.z)
        assert(route,"WorldData: fixed destination lost road access")
        local length=0
        for n=2,#route do length=length+distance(route[n-1].x,route[n-1].z,route[n].x,route[n].z) end
        World.Orders[#World.Orders+1]={id="world_"..d.id.."_"..(#World.Orders%2==0 and "local" or "cross"),
            title=d.label..trip[2],pickupId=pickup.id,dropoffId=dropoff.id,route=route,
            timeLimitHours=math.max(1,length/1500+.5),tutorial=false}
    end
end
World.Bridges=bridges
function World.CacheStats() return {cells=cacheCount,limit=World.CACHE_LIMIT,roads=#World.Roads,nodes=#nodes} end
return World
