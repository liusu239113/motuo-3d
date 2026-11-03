-- 北岭有限沿江闭环。纯数据/局部导航，不扩World旧报价图，不生成任何引擎对象。
-- 阶段1为单层高度场：滨江路 |x|>=48，不从中央16m机动车桥下穿行。
local Roads={Routes={},Points={
    {id="hills_river_south",label="南岸滨江休息点",name="南岸滨江休息点",kind="scenery",x=192,z=1208,district="north_campus"},
    {id="hills_river_north",label="北岸望江台",name="北岸望江台",kind="scenery",x=-192,z=1352,district="north_campus"},
}}
Roads.Entries={{x=0,z=576},{x=0,z=960},{x=0,z=1536}}
local south={{304,960},{304,1040},{336,1072},{352,1088},{352,1120},{336,1136},
    {224,1160},{192,1184},{176,1192},{176,1200},{184,1208},{200,1208},
    {432,1208},{448,1200},{464,1184},{464,960},{304,960}}
local north={{0,1536},{160,1536},{240,1512},{272,1488},{272,1456},{240,1432},
    {80,1368},{64,1360},{64,1352},{80,1352},{192,1352},{304,1352},{304,1536},{160,1536}}
local function route(id,name,points,side)
    local out={id=id,name=name,width=12,sidewalk=2,points={},hill=true}
    for _,p in ipairs(points) do out.points[#out.points+1]={x=p[1]*side,z=p[2]} end
    Roads.Routes[#Roads.Routes+1]=out
end
for _,side in ipairs({-1,1}) do
    route("river_south_loop_"..side,"南岸回头弯",south,side)
    route("river_south_bank_"..side,"南岸滨江路",{{48,1208},{184,1208},{192,1208},{200,1208},{432,1208}},side)
    route("river_north_loop_"..side,"北岸盘山路",north,side)
    route("river_north_bank_"..side,"北岸滨江路",{{48,1352},{64,1352},{80,1352},{192,1352},{304,1352}},side)
end
local function clamp(v,a,b) return math.max(a,math.min(b,v)) end
local function blend(v,a,b) return clamp((v-a)/(b-a),0,1) end
-- 先切出连续低位台地，再在其上铺折线路；不是浮在山上的第二层道路。
function Roads.Grade(x,z,natural,level)
    local ax=math.abs(x)
    if z>=960 and z<=1232 then
        local weight=blend(ax,24,40)*(1-blend(ax,480,512))
        local y=z<=1192 and level*(1192-z)/232 or z<=1218 and 0 or -14*(z-1218)/14
        return natural+(y-natural)*weight
    end
    if z>=1328 and z<=1632 then
        local weight=blend(ax,24,40)*(1-blend(ax,320,352))
        local y=z<1342 and -14+14*(z-1328)/14 or z<=1362 and 0
            or z<=1536 and 12*(z-1362)/174 or 12
        -- 北端回头路留16m同高肩，不让转弯轮胎踩入紧贴路缘的山壁。
        weight=weight*(1-blend(z,1552,1632))
        return natural+(y-natural)*weight
    end
    return natural
end
-- 所有铺装均投影原始地形三角形；以圆接头覆盖折线外角，12m道路+2m步行带。
Roads.Patches={}
local function polygon(a,b,r)
    local dx,dz=b.x-a.x,b.z-a.z
    local length=math.sqrt(dx*dx+dz*dz)
    local nx,nz=-dz/length*r,dx/length*r
    return {{x=a.x+nx,z=a.z+nz},{x=a.x-nx,z=a.z-nz},
        {x=b.x-nx,z=b.z-nz},{x=b.x+nx,z=b.z+nz}}
end
-- 先合并共线重叠段、去重接头；镜像/滨江支路不重复生成同一片铺装。
local strips,joints,lines={},{},{}
local function pointKey(p) return string.format("%.6f:%.6f",p.x,p.z) end
local function joint(p) joints[pointKey(p)]=p end
for _,r in ipairs(Roads.Routes) do
    for i=2,#r.points do
        local a,b=r.points[i-1],r.points[i]
        if a.x==b.x or a.z==b.z then
            local vertical=a.x==b.x
            local key=(vertical and "x" or "z")..(vertical and a.x or a.z)
            local line=lines[key] or {vertical=vertical,fixed=vertical and a.x or a.z,spans={}}
            local lo,hi=vertical and a.z or a.x,vertical and b.z or b.x
            line.spans[#line.spans+1]={math.min(lo,hi),math.max(lo,hi)};lines[key]=line
        else strips[#strips+1]={a=a,b=b} end
    end
    for i,p in ipairs(r.points) do
        local a,b=r.points[i-1],r.points[i+1]
        if not a or not b or math.abs((p.x-a.x)*(b.z-p.z)-(p.z-a.z)*(b.x-p.x))>1e-8 then joint(p) end
    end
end
for _,line in pairs(lines) do
    table.sort(line.spans,function(a,b) return a[1]<b[1] end)
    local merged={}
    for _,span in ipairs(line.spans) do
        local last=merged[#merged]
        if last and span[1]<=last[2] then last[2]=math.max(last[2],span[2])
        else merged[#merged+1]={span[1],span[2]} end
    end
    for _,span in ipairs(merged) do
        local a=line.vertical and {x=line.fixed,z=span[1]} or {x=span[1],z=line.fixed}
        local b=line.vertical and {x=line.fixed,z=span[2]} or {x=span[2],z=line.fixed}
        strips[#strips+1]={a=a,b=b}
    end
end
for _,material in ipairs({"road","concrete"}) do
    local radius=material=="road" and 6 or 8
    for _,s in ipairs(strips) do Roads.Patches[#Roads.Patches+1]={material=material,poly=polygon(s.a,s.b,radius)} end
    for _,p in pairs(joints) do
        local poly={}
        for i=0,7 do local a=i*math.pi/4;poly[#poly+1]={x=p.x+math.cos(a)*radius,z=p.z+math.sin(a)*radius} end
        Roads.Patches[#Roads.Patches+1]={material=material,poly=poly}
    end
end
for _,p in ipairs(Roads.Patches) do
    local rect={x1=math.huge,x2=-math.huge,z1=math.huge,z2=-math.huge}
    for _,v in ipairs(p.poly) do
        rect.x1,rect.x2=math.min(rect.x1,v.x),math.max(rect.x2,v.x)
        rect.z1,rect.z2=math.min(rect.z1,v.z),math.max(rect.z2,v.z)
    end
    p.rect=rect
end
local patchCells={}
for _,p in ipairs(Roads.Patches) do
    local r=p.rect
    for ix=math.floor(r.x1/32),math.floor(r.x2/32) do for iz=math.floor(r.z1/32),math.floor(r.z2/32) do
        local key=ix..":"..iz
        local list=patchCells[key] or {};list[#list+1]=p;patchCells[key]=list
    end end
end
function Roads.Candidates(rect)
    local result,seen={},{}
    for ix=math.floor(rect.x1/32),math.floor(rect.x2/32) do for iz=math.floor(rect.z1/32),math.floor(rect.z2/32) do
        for _,p in ipairs(patchCells[ix..":"..iz] or {}) do
            if not seen[p] and p.rect.x1<rect.x2 and p.rect.x2>rect.x1 and p.rect.z1<rect.z2 and p.rect.z2>rect.z1 then
                seen[p]=true;result[#result+1]=p
            end
        end
    end end
    table.sort(result,function(a,b) return a.material=="road" and b.material~="road" end)
    return result
end
-- 凸多边形差集：每次只将尚未覆盖的碎片交给下一片，路口和圆接头不重复铺面。
function Roads.Partition(poly,candidates,emit)
    local remaining={poly}
    for _,patch in ipairs(candidates) do
        local nextPieces={}
        for _,piece in ipairs(remaining) do
            local inside=piece
            for i,a in ipairs(patch.poly) do
                if #inside<3 then break end
                local b=patch.poly[i%#patch.poly+1]
                local yes,no={},{}
                for k,p in ipairs(inside) do
                    local q=inside[k%#inside+1]
                    local sp=(b.x-a.x)*(p.z-a.z)-(b.z-a.z)*(p.x-a.x)
                    local sq=(b.x-a.x)*(q.z-a.z)-(b.z-a.z)*(q.x-a.x)
                    local ip,iq=sp>=-1e-9,sq>=-1e-9
                    if ip then yes[#yes+1]=p else no[#no+1]=p end
                    if ip~=iq then
                        local t=sp/(sp-sq)
                        local v={x=p.x+(q.x-p.x)*t,z=p.z+(q.z-p.z)*t,y=p.y+(q.y-p.y)*t}
                        yes[#yes+1]=v;no[#no+1]=v
                    end
                end
                if #no>=3 then nextPieces[#nextPieces+1]=no end
                inside=yes
            end
            if #inside>=3 then emit(inside,patch.material) end
        end
        remaining=nextPieces
        if #remaining==0 then break end
    end
    return remaining
end
-- 常驻有限图：折线相交处才连接。无跨河捷径，不将不同台地以直线硬连。
---@class HillGraphPoint
---@field x number
---@field z number
---@class HillGraphNode: HillGraphPoint
---@field edges table<number,number>
---@class HillGraphSegment
---@field a HillGraphPoint
---@field b HillGraphPoint
---@field length number
---@field nodes table[]
---@type {nodes:HillGraphNode[],segments:HillGraphSegment[]}
local graph={nodes={},segments={}}
local function node(x,z)
    for i,n in ipairs(graph.nodes) do if math.abs(n.x-x)+math.abs(n.z-z)<1e-6 then return i end end
    graph.nodes[#graph.nodes+1]={x=x,z=z,edges={}}
    return #graph.nodes
end
function Roads.BuildGraph(routes)
    graph={nodes={},segments={}}
    for _,r in ipairs(routes) do for i=2,#r.points do
        local a,b=r.points[i-1],r.points[i]
        local length=math.sqrt((b.x-a.x)^2+(b.z-a.z)^2)
        if length>1e-6 then graph.segments[#graph.segments+1]={a=a,b=b,length=length} end
    end end
    for _,s in ipairs(graph.segments) do node(s.a.x,s.a.z);node(s.b.x,s.b.z) end
    for i,s in ipairs(graph.segments) do for j=i+1,#graph.segments do
        ---@type HillGraphSegment
        local t=graph.segments[j]
        local dx,dz=s.b.x-s.a.x,s.b.z-s.a.z
        local ex,ez=t.b.x-t.a.x,t.b.z-t.a.z
        local det=dx*ez-dz*ex
        if math.abs(det)>1e-8 then
            local ox,oz=t.a.x-s.a.x,t.a.z-s.a.z
            local u,v=(ox*ez-oz*ex)/det,(ox*dz-oz*dx)/det
            if u>=0 and u<=1 and v>=0 and v<=1 then node(s.a.x+dx*u,s.a.z+dz*u) end
        end
    end end
    for _,s in ipairs(graph.segments) do
        local points={}
        local dx,dz=s.b.x-s.a.x,s.b.z-s.a.z
        for id,n in ipairs(graph.nodes) do
            local t=((n.x-s.a.x)*dx+(n.z-s.a.z)*dz)/(s.length*s.length)
            if t>=-1e-8 and t<=1+1e-8 and math.abs((n.x-s.a.x)*dz-(n.z-s.a.z)*dx)<1e-5 then
                points[#points+1]={id=id,t=t}
            end
        end
        table.sort(points,function(a,b) return a.t<b.t end)
        for i=2,#points do
            local a,b=points[i-1].id,points[i].id
            local cost=(points[i].t-points[i-1].t)*s.length
            graph.nodes[a].edges[b]=cost;graph.nodes[b].edges[a]=cost
        end
        s.nodes=points
    end
end
local function attach(x,z,connect)
    local best={distance=8^2}
    for _,s in ipairs(graph.segments) do
        local dx,dz=s.b.x-s.a.x,s.b.z-s.a.z
        local t=clamp(((x-s.a.x)*dx+(z-s.a.z)*dz)/(s.length*s.length),0,1)
        local px,pz=s.a.x+dx*t,s.a.z+dz*t
        local distance=(px-x)^2+(pz-z)^2
        if distance<=best.distance and (not connect or connect(x,z,px,pz)) then
            best={x=px,z=pz,t=t,segment=s,distance=distance}
        end
    end
    return best.segment and best or nil
end
function Roads.Route(x,z,tx,tz,surface,connect)
    local start,finish=attach(x,z,connect),attach(tx,tz,connect)
    if not start or not finish then return nil end
    local dist,previous,done={},{},{}
    for _,p in ipairs(start.segment.nodes) do dist[p.id]=math.abs(start.t-p.t)*start.segment.length end
    for _=1,#graph.nodes do
        local best,cost=0,math.huge
        for id,value in pairs(dist) do if not done[id] and value<cost then best,cost=id,value end end
        if best==0 then break end
        done[best]=true
        for id,length in pairs(graph.nodes[best].edges) do
            if not dist[id] or cost+length<dist[id] then dist[id]=cost+length;previous[id]=best end
        end
    end
    local last,cost=0,math.huge
    for _,p in ipairs(finish.segment.nodes) do
        local candidate=(dist[p.id] or math.huge)+math.abs(finish.t-p.t)*finish.segment.length
        if candidate<cost then last,cost=p.id,candidate end
    end
    if last==0 then return nil end
    local reverse={last}
    while previous[last] do last=previous[last];reverse[#reverse+1]=last end
    local result={}
    local function add(px,pz)
        local p=result[#result]
        if not p or math.abs(p.x-px)+math.abs(p.z-pz)>1e-6 then result[#result+1]={x=px,z=pz,y=surface(px,pz),layer="ground"} end
    end
    add(x,z);add(start.x,start.z)
    if start.segment==finish.segment then add(finish.x,finish.z)
    else
        for i=#reverse,1,-1 do local n=graph.nodes[reverse[i]];add(n.x,n.z) end
        add(finish.x,finish.z)
    end
    add(tx,tz)
    return result
end
return Roads
