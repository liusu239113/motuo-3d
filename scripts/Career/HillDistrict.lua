-- 山城北侧接续区：同源分片线性山地、河谷、机动车桥与台地道路。
-- 参考平行山脊/河谷和上下台地关系，不声称复刻重庆街道或真实比例。
-- 侧视（米）：老街0 -> 160m缓坡 -> 台地12 -> 跨谷桥12 -> 台地12 -> 缓坡0。
-- z:            440       600          1152 .. 1408       1536       1792
-- 谷底-14，水面-8；桥净宽16m，栏杆在±8.1m，支柱在±11m，不堵车道。
-- 河岸/桥栏用真实可见矩形碰撞；水域扣除整条桥，不以禁行标签代替道路。
---@class CareerHillDistrict
---@field Points table[]
---@field NavigationEntries {x:number,z:number}[]
---@field LocalRoute fun(x:number,z:number,tx:number,tz:number):table[]?
local Hills={}
local HillRoads=require("Career.HillRoads")
Hills.Points=HillRoads.Points
Hills.NavigationEntries=HillRoads.Entries
Hills.Bounds={x1=-512,x2=512,z1=440,z2=1792}
Hills.River={x1=-512,x2=512,z1=1232,z2=1328}
Hills.Routes={
    {id="north_valley_drive",name="北岭跨谷公路",points={{x=0,z=440},{x=0,z=600},{x=0,z=1152},{x=0,z=1408},{x=0,z=1536},{x=0,z=1792}}},
}
Hills.Roads={}
-- 台地俯视（左右镜像，米）：
-- z960  旧街x0 ===== 坡道 ===== 下台地x304 ===== 坡道 ===== 上台地x464
--                              | 住宅12m |               | 住宅22m |
-- z576  旧街x0 ===== 坡道 ======+=========================+
-- 横坡最大12/144=8.33%、10/96=10.42%；纵街128m降12m，均在既有6°接地范围内。
-- 住宅足迹全部位于常高平台，路面连续；基础实体不伸进10m车道或两侧2m步行带。
for _,side in ipairs({-1,1}) do
    for _,x in ipairs({304,464}) do
        local id="terrace_loop_"..side.."_"..x
        Hills.Routes[#Hills.Routes+1]={id=id,name=x==304 and "半山里街" or "岭上环街",
            points={{x=0,z=576},{x=side*x,z=576},{x=side*x,z=960},{x=0,z=960}}}
        Hills.Roads[#Hills.Roads+1]={id=id,x1=side*x,x2=side*x,z1=576,z2=960,width=10,sidewalk=2}
    end
end
for _,z in ipairs({576,960}) do
    Hills.Roads[#Hills.Roads+1]={id="terrace_cross_"..z,x1=-464,x2=464,z1=z,z2=z,width=12,sidewalk=2}
end
Hills.X={-512,-496,-480,-464,-448,-432,-384,-352,-336,-320,-304,-288,-272,-256,-192,-128,-16,-8.4,-8,0,8,8.4,16,128,192,256,272,288,304,320,336,352,384,432,448,464,480,496,512}
Hills.Z={440,480,520,560,576,600,640,704,768,832,896,960,1024,1088,1152,1192,1232,1280,1328,1368,1408,1472,1536,1600,1664,1728,1792}
for _,r in ipairs(HillRoads.Routes) do Hills.Routes[#Hills.Routes+1]=r end
HillRoads.BuildGraph(Hills.Routes)
-- 仅插入真实折坡断点；不把全山细分成8m×8m网格，避免流式构建放大。
do
    for _,axis in ipairs({"X","Z"}) do
        local values=Hills[axis]
        local seen={}
        for _,v in ipairs(values) do seen[v]=true end
        for _,v in ipairs(axis=="X" and {-312,-48,-40,-24,24,40,48,312} or {1218,1342,1362,1552,1632}) do
            if not seen[v] then values[#values+1]=v;seen[v]=true end
        end
        table.sort(values)
    end
end
local function contains(b,x,z) return x>=b.x1 and x<=b.x2 and z>=b.z1 and z<=b.z2 end
local function overlap(a,b) return a.x1<b.x2 and a.x2>b.x1 and a.z1<b.z2 and a.z2>b.z1 end
function Hills.Contains(x,z) return contains(Hills.Bounds,x,z) end
function Hills.Reserved(rect) return overlap(Hills.Bounds,rect) end
local function smoothRange(v,a,b) return math.max(0,math.min(1,(v-a)/(b-a))) end
function Hills.Plateau(z)
    local outer=12*math.min(smoothRange(z,440,600),1-smoothRange(z,1536,1792))
    -- 北学府既有服务口/旧步行桥保持0m，不搬动订单终点；上下台地以缓坡接这个谷间街区。
    local campus=math.min(smoothRange(z,576,704),1-smoothRange(z,960,1088))
    return outer*(1-math.max(0,campus))
end
-- 18栋总量不变：入口/南岸/北岸各6栋，楼基外缘不占12m车道+2m步道。
-- 平台半宽8m，仅相邻格点过渡；各楼中心距最近直街/滨江路24m以上。
Hills.HomePads={}
for _,side in ipairs({-1,1}) do
    for index,p in ipairs({{280,632,1},{280,664,1},{280,696,1},
        {280,1032,2},{328,1104,2},{400,1184,2},
        {328,1384,3},{328,1416,3},{328,1448,3}}) do
        local x,z=side*p[1],p[2]
        local level=12*smoothRange(math.abs(x),128,272)+10*smoothRange(math.abs(x),336,432)
        local y=HillRoads.Grade(x,z,Hills.Plateau(z)+level,level)
        Hills.HomePads[#Hills.HomePads+1]={x=x,z=z,row=p[3],index=index,y=y,
            h=14+((index+(side>0 and 1 or 0))%3)*3,yaw=side*90}
    end
end
do
    for _,axis in ipairs({"X","Z"}) do
        local values=Hills[axis]
        local seen={}
        for _,v in ipairs(values) do seen[v]=true end
        for _,p in ipairs(Hills.HomePads) do
            local center=axis=="X" and p.x or p.z
            for _,delta in ipairs({-8,8}) do
                local v=center+delta
                if not seen[v] then values[#values+1]=v;seen[v]=true end
            end
        end
        table.sort(values)
    end
end
local function authored(x,z)
    local edge=math.min(1,(512-math.abs(x))/64)
    local base=Hills.Plateau(z)*edge
    if z>=1152 and z<=1408 then
        local valley=math.min(smoothRange(z,1152,1232),1-smoothRange(z,1328,1408))
        base=base-(base+14)*math.max(0,valley)
    end
    -- 非对称低缓丘：宽平脊、左右不同脊心与高度，不再以68m线性尖峰形成金字塔。
    -- 仍只求原有稀疏格点，显示/接地使用同一组分片线性三角形。
    local ax=math.abs(x)
    local center=x<0 and 336 or 384
    local function eased(t) return t*t*(3-2*t) end
    local ridge=eased(smoothRange(ax,128,center-48))*(1-eased(smoothRange(ax,center+48,512)))
    local along=math.min(smoothRange(z,440,600),1-smoothRange(z,1536,1792))
    local natural=base+ridge*math.max(0,along)*(x<0 and 30 or 38)
    -- 外侧街区切成真实台地，台地之间保留可骑行斜面；北学府中心±128m不动。
    local level=12*smoothRange(ax,128,272)+10*smoothRange(ax,336,432)
    local terrace=Hills.Plateau(z)+level
    local blend=math.min(smoothRange(z,480,560),1-smoothRange(z,1024,1152),1-smoothRange(ax,480,512))
    local shaped=natural+(terrace-natural)*math.max(0,blend)
    local graded=HillRoads.Grade(x,z,shaped,level)
    -- 先切坡后压实楼基。平台仅在紧邻原格节点内过渡，不能跨宽格把楼基高度泄漏进车道。
    for _,p in ipairs(Hills.HomePads) do
        local wx=1-smoothRange(math.abs(x-p.x),8,10)
        local wz=1-smoothRange(math.abs(z-p.z),8,10)
        local weight=wx*wz
        if weight>0 then graded=graded+(p.y-graded)*weight end
    end
    return graded
end
-- 地形固定不变，格点高程只算一次；每次轮胎采样只做二分定位和线性插值。
local heights={}
for i,x in ipairs(Hills.X) do
    heights[i]={}
    for j,z in ipairs(Hills.Z) do heights[i][j]=authored(x,z) end
end
local function interval(values,n)
    local low,high=2,#values
    while low<high do
        local mid=(low+high)//2
        if n<=values[mid] then high=mid else low=mid+1 end
    end
    return values[low-1],values[low],low
end
-- 保留闭区间交界两侧的原格子，不每次从整个山区的第一格开始扫。
local function cellRange(values,a,b)
    local _,_,first=interval(values,a)
    local _,edge,last=interval(values,b)
    if edge==b then last=math.min(last+1,#values) end
    return first,last
end
-- 与下方Quad同一对角线：a(l,n),b(l,f),c(r,n),d(r,f)，绝非另一个光滑高度函数。
function Hills.Height(x,z)
    local l,r,i=interval(Hills.X,x)
    local n,f,j=interval(Hills.Z,z)
    local u,v=(x-l)/(r-l),(z-n)/(f-n)
    local a,b,c,d=heights[i-1][j-1],heights[i-1][j],heights[i][j-1],heights[i][j]
    if u+v<=1 then return a+(c-a)*u+(b-a)*v end
    return d+(b-d)*(1-u)+(c-d)*(1-v)
end
-- 对整个包络证明同一个仿射平面，供轮胎迭代重复查询；斜坡不退化成常高。
---@return {x:number,z:number,base:number}?
function Hills.Plane(x1,z1,x2,z2)
    if not Hills.Contains(x1,z1) or not Hills.Contains(x2,z2) then return nil end
    if x1<=8 and x2>=-8 and z1<=1408 and z2>=1152 then return nil end
    local l,r,i=interval(Hills.X,(x1+x2)/2)
    local n,f,j=interval(Hills.Z,(z1+z2)/2)
    local a,b,c,d=heights[i-1][j-1],heights[i-1][j],heights[i][j-1],heights[i][j]
    local ax,az,base=0.0,0.0,0.0
    if ((x1+x2)/2-l)/(r-l)+((z1+z2)/2-n)/(f-n)<=1 then
        ax,az=(c-a)/(r-l),(b-a)/(f-n);base=a-ax*l-az*n
    else ax,az=(d-b)/(r-l),(d-c)/(f-n);base=d-ax*r-az*f end
    local xi1,xi2=cellRange(Hills.X,x1,x2)
    local zj1,zj2=cellRange(Hills.Z,z1,z2)
    for xi=xi1,xi2 do
        local left,right=Hills.X[xi-1],Hills.X[xi]
        local a,b=heights[xi-1],heights[xi]
        for zj=zj1,zj2 do
            local near,far=Hills.Z[zj-1],Hills.Z[zj]
            if math.abs(a[zj-1]-(ax*left+az*near+base))>1e-10
                or math.abs(a[zj]-(ax*left+az*far+base))>1e-10
                or math.abs(b[zj-1]-(ax*right+az*near+base))>1e-10
                or math.abs(b[zj]-(ax*right+az*far+base))>1e-10 then return nil end
        end
    end
    return {x=ax,z=az,base=base+.055}
end
function Hills.FlatHeight(x1,z1,x2,z2)
    if not Hills.Contains(x1,z1) or not Hills.Contains(x2,z2) then return nil end
    if x1>=-8 and x2<=8 and z1>=1152 and z2<=1408 then return 12.055 end
    if x1<=8 and x2>=-8 and z1<=1408 and z2>=1152 then return nil end
    local value=Hills.Height(x1,z1)
    -- 严格证明每个相交原始网格的四个顶点都同高；不以少数采样猜测平地。
    local i1,i2=cellRange(Hills.X,x1,x2)
    local j1,j2=cellRange(Hills.Z,z1,z2)
    for i=i1,i2 do
        for j=j1,j2 do
            if heights[i-1][j-1]~=value or heights[i-1][j]~=value
                or heights[i][j-1]~=value or heights[i][j]~=value then return nil end
        end
    end
    return value+.055
end
function Hills.Surface(x,z)
    if not Hills.Contains(x,z) then return nil end
    if math.abs(x)<=8 and z>=1152 and z<=1408 then return 12.055 end
    return Hills.Height(x,z)+.055
end
-- 接近段只允许车道/步道8m范围；每25cm核对坡度和可见实体，不能横穿住宅基座。
local function connector(ax,az,bx,bz)
    if not Hills.Contains(ax,az) or not Hills.Contains(bx,bz) then return false end
    local length=math.sqrt((bx-ax)^2+(bz-az)^2)
    if length>8.000001 then return false end
    local rect={x1=math.min(ax,bx)-.35,x2=math.max(ax,bx)+.35,z1=math.min(az,bz)-.35,z2=math.max(az,bz)+.35}
    local obstacles=Hills.Obstacles(rect)
    for _,b in ipairs(Hills.Buildings) do if overlap(b,rect) then obstacles[#obstacles+1]=b end end
    local steps=math.max(1,math.ceil(length/.25))
    local previous=assert(Hills.Surface(ax,az))
    for i=0,steps do
        local x,z=ax+(bx-ax)*i/steps,az+(bz-az)*i/steps
        local y=assert(Hills.Surface(x,z))
        if i>0 and math.abs(y-previous)>length/steps*.11+.000001 then return false end
        for _,o in ipairs(obstacles) do
            if x>o.x1-.35 and x<o.x2+.35 and z>o.z1-.35 and z<o.z2+.35
                and y+1.8>(o.y1 or o.foundationY or -math.huge) and y<(o.y2 or o.baseY+o.h) then return false end
        end
        previous=y
    end
    return true
end
function Hills.LocalRoute(x,z,tx,tz)
    return HillRoads.Route(x,z,tx,tz,Hills.Surface,connector)
end
Hills.Buildings={}
do
    -- 复用已实测的第二套建筑，等比缩放，不覆盖模型或另加外挂窗片。
    local size={.755859375,.9980469048023224,.763671875}
    for _,p in ipairs(Hills.HomePads) do
        local scale=p.h/size[2]
        local w,depth=size[1]*scale,size[3]*scale
        local base=p.y+.055
        Hills.Buildings[#Hills.Buildings+1]={id="hills_home_"..p.x.."_"..p.z,
            x=p.x,z=p.z,w=w,d=depth,h=p.h,floors=math.floor(p.h/3),yaw=p.yaw,asset=2,expansion=true,hill=true,
            style="plaster",name=p.row==3 and "岭上错层住宅" or "半山里临街住宅",baseY=base,foundationY=base-1.4,
            x1=p.x-depth/2-.05,x2=p.x+depth/2+.05,z1=p.z-w/2-.05,z2=p.z+w/2+.05}
    end
end
-- 动态显示导航从实际山路回到原主干道；不更改历史订单模板/报价所用的Route图。
function Hills.ExitRoute(x,z)
    if z<568 or z>968 then return nil end
    local junction=z<768 and 576 or 960
    local lane=0
    if math.abs(z-576)<=8 then junction=576
    elseif math.abs(z-960)<=8 then junction=960
    else
        for _,center in ipairs({-464,-304,304,464}) do
            if math.abs(x-center)<=7 then lane=center;break end
        end
        if lane==0 then return nil end
    end
    if math.abs(x)>480 or math.abs(x)<16 then return nil end
    local route={}
    local function add(px,pz) route[#route+1]={x=px,z=pz,y=Hills.Surface(px,pz),layer="ground"} end
    add(x,z)
    if lane~=0 then add(lane,z);add(lane,junction)
    else add(x,junction) end
    add(0,junction)
    return route
end
function Hills.Obstacles(cell)
    local list={}
    local function add(x1,x2,z1,z2,y1,y2,kind)
        local o={x1=x1,x2=x2,z1=z1,z2=z2,y1=y1,y2=y2,kind=kind}
        if overlap(o,cell) then list[#list+1]=o end
    end
    -- 栏杆连续且有实体宽度；上下地形通过自身缓坡接近，不允许从桥侧跌进河中。
    for _,side in ipairs({-1,1}) do
        add(side<0 and -8.4 or 8,side<0 and -8 or 8.4,1152,1408,11.5,13.35,"valley_rail")
        add(side<0 and -512 or 8.4,side<0 and -8.4 or 512,1232,1328,-30,120,"river")
        for _,z in ipairs({1200,1360}) do add(side*11-.7,side*11+.7,z-.9,z+.9,-15,11.5,"valley_pier") end
    end
    -- 河岸护栏距12m车道外缘6m；低路距中轴桥至少40m，绝不制造桥下重叠支撑。
    for _,side in ipairs({-1,1}) do
        local x1,x2=side<0 and -480 or 40,side<0 and -40 or 480
        add(x1,x2,1219.8,1220.2,-2.2,1.15,"bank_rail")
        add(side<0 and -320 or 40,side<0 and -40 or 320,1339.8,1340.2,-2.2,1.15,"bank_rail")
        -- 台地前缘真实挡墙位于住宅背侧，不占304/464m车道；地脚与墙顶共用高度场。
        for _,x in ipairs({260,356}) do
            for z=600,688,8 do
                local wx=side*x
                local low=Hills.Height(wx-side*2,z)
                local high=Hills.Height(wx+side*2,z)
                add(wx-.18,wx+.18,z,z+8,math.min(low,high)-1,math.max(low,high)+.4,"terrace_wall")
            end
        end
    end
    return list
end
function Hills.Buildable(rect)
    if not Hills.Reserved(rect) then return true end
    -- 仅完整常高台地放既有楼体；不把刚性模型悬在斜坡/河面上。
    return rect.z1>=768 and rect.z2<=960 and rect.x1>=-128 and rect.x2<=128
end
-- 将任意铺装矩形裁到原地形三角面；不能只用矩形四角跨山脊连成另一张平面。
---@param d {Triangle:fun(self:any,material:string,a:Vector3,b:Vector3,c:Vector3)}
function Hills.RenderPatch(d,rect,material,offset,patches)
    local V=Vector3
    local count=0
    local i1,i2=cellRange(Hills.X,math.max(rect.x1,Hills.Bounds.x1),math.min(rect.x2,Hills.Bounds.x2))
    local j1,j2=cellRange(Hills.Z,math.max(rect.z1,Hills.Bounds.z1),math.min(rect.z2,Hills.Bounds.z2))
    for i=i1,i2 do for j=j1,j2 do
        local l,r=math.max(rect.x1,Hills.X[i-1]),math.min(rect.x2,Hills.X[i])
        local n,f=math.max(rect.z1,Hills.Z[j-1]),math.min(rect.z2,Hills.Z[j])
        if l<r and n<f then
            local localPatches={}
            for _,p in ipairs(patches or {}) do
                local b=p.rect
                if b.x1<r and b.x2>l and b.z1<f and b.z2>n then localPatches[#localPatches+1]=p end
            end
            local function emit(poly)
                local function clip(input,axis,bound,greater)
                    local out={}
                    for k,p in ipairs(input) do
                        local q=input[k%#input+1]
                        local a,b=p[axis],q[axis]
                        local insideA,insideB=greater and a>=bound or not greater and a<=bound,greater and b>=bound or not greater and b<=bound
                        if insideA then out[#out+1]=p end
                        if insideA~=insideB then
                            local t=(bound-a)/(b-a)
                            out[#out+1]={x=p.x+(q.x-p.x)*t,z=p.z+(q.z-p.z)*t,y=p.y+(q.y-p.y)*t}
                        end
                    end
                    return out
                end
                for _,edge in ipairs({{"x",l,true},{"x",r,false},{"z",n,true},{"z",f,false}}) do poly=clip(poly,edge[1],edge[2],edge[3]) end
                local function draw(shape,mat)
                    local lift=(offset or 0)+(patches and mat~="grass" and .055 or 0)
                    local vertices={}
                    for k,p in ipairs(shape) do
                        -- Vector3的XZ是float。先确定实际提交坐标，再按同一高度场重算Y；
                        -- 不能把double交点的Y与量化后的XZ拼成不同源顶点。
                        -- 原始格边均为精确二进制数；单调舍入不越格，靠对角线时以Height的规范侧为准。
                        local v=V(p.x,0,p.z)
                        v.y=Hills.Height(v.x,v.z)+lift
                        vertices[k]=v
                    end
                    for k=3,#vertices do
                        d:Triangle(mat,vertices[1],vertices[k-1],vertices[k]);count=count+1
                    end
                end
                if patches then
                    for _,remaining in ipairs(HillRoads.Partition(poly,localPatches,draw)) do draw(remaining,material) end
                else draw(poly,material) end
            end
            local x1,x2,z1,z2=Hills.X[i-1],Hills.X[i],Hills.Z[j-1],Hills.Z[j]
            local y1,y2=heights[i-1],heights[i]
            emit({{x=x1,z=z1,y=y1[j-1]+(offset or 0)},{x=x1,z=z2,y=y1[j]+(offset or 0)},
                {x=x2,z=z1,y=y2[j-1]+(offset or 0)}})
            emit({{x=x2,z=z1,y=y2[j-1]+(offset or 0)},{x=x1,z=z2,y=y1[j]+(offset or 0)},
                {x=x2,z=z2,y=y2[j]+(offset or 0)}})
        end
    end end
    return count
end
---@param d CityDetails
function Hills.RenderCell(d,cell)
    if not Hills.Reserved(cell) then return 0 end
    local V=Vector3
    local count=0
    -- 所有路面/步道先差集分区，单个原始三角形只提交一次，不层叠圆接头。
    local patches=HillRoads.Candidates(cell)
    for _,s in ipairs(cell.hillGrounds or {}) do
        patches[#patches+1]={material=s.material,rect=s,poly={{x=s.x1,z=s.z1},{x=s.x2,z=s.z1},
            {x=s.x2,z=s.z2},{x=s.x1,z=s.z2}}}
    end
    for _,range in ipairs({{cell.x1,math.min(cell.x2,-8)},{math.max(cell.x1,8),cell.x2}}) do
        if range[1]<range[2] then
            count=count+Hills.RenderPatch(d,{x1=range[1],x2=range[2],z1=cell.z1,z2=cell.z2},"grass",0,patches)
        end
    end
    local l,r=math.max(cell.x1,-8),math.min(cell.x2,8)
    if l<r then count=count+Hills.RenderPatch(d,{x1=l,x2=r,z1=cell.z1,z2=cell.z2},"grass",0) end
    -- 已有主干道随台地上升；跨谷段是带侧梁与桥墩的实体桥，不是悬空路面贴片。
    for j=2,#Hills.Z do
        local n,f=math.max(cell.z1,Hills.Z[j-1]),math.min(cell.z2,Hills.Z[j])
        local l,r=math.max(cell.x1,-8),math.min(cell.x2,8)
        if l<r and n<f then
            local function p(x,z,offset) return V(x,assert(Hills.Surface(x,z))+(offset or 0),z) end
            d:Quad("road",p(l,n),p(l,f),p(r,n),p(r,f))
            for _,side in ipairs({-1,1}) do
                local x=side*7.6
                if x>=l and x<r then d:Quad("paint",p(x-.06,n,.012),p(x-.06,f,.012),p(x+.06,n,.012),p(x+.06,f,.012)) end
            end
            if l<=0 and r>=0 then d:Quad("yellow",p(-.06,n,.013),p(-.06,f,.013),p(.06,n,.013),p(.06,f,.013)) end
            if n>=1152 and f<=1408 then
                d:Box("concrete",(l+r)/2,11.6,(n+f)/2,r-l,.8,f-n)
            end
        end
    end
    local river=Hills.River
    local l,r,n,f=math.max(cell.x1,river.x1),math.min(cell.x2,river.x2),math.max(cell.z1,river.z1),math.min(cell.z2,river.z2)
    if l<r and n<f then d:Quad("coast_water",V(l,-8,n),V(l,-8,f),V(r,-8,n),V(r,-8,f)) end
    for _,o in ipairs(Hills.Obstacles(cell)) do
        if o.kind~="river" then
            local a,b,c,e=math.max(cell.x1,o.x1),math.min(cell.x2,o.x2),math.max(cell.z1,o.z1),math.min(cell.z2,o.z2)
            d:Box((o.kind=="valley_rail" or o.kind=="bank_rail") and "metal" or "concrete",(a+b)/2,(o.y1+o.y2)/2,(c+e)/2,b-a,o.y2-o.y1,e-c)
        end
    end
    return count
end
return Hills
