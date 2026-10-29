-- 近邻西南海湾与老街桥下环境；米制，地形/碰撞/渲染共用此纯数据真源。
-- 基于scaffold-3d-scene/CityDetails分块所有权；不订阅帧，不改存档/订单。
local Environment={}
Environment.Bounds={x1=-1152,x2=-400,z1=-1152,z2=-400}
Environment.Connector={x1=-400,x2=-380,z1=-400,z2=-380}
Environment.SEA=.15
Environment.Resources={"uuid://FA-0GUs_3oaHzyb-ntH1Nkwf","Materials/SingleLayerWater.xml","image/career_bridge_sign.png"}
Environment.ResourceTypes={[Environment.Resources[1]]="Material",[Environment.Resources[2]]="Material",[Environment.Resources[3]]="Texture2D"}
-- 俯视：环街(-384,-384) -> 20m平接入口 -> 岸丘(-450,-450),y4
--       -> 60m缓坡 -> 沙滩(-548,-548),y.27 -> 沿岸栈道 -> 西向观景栈桥。
-- 海域x,z<-568，扣除8m宽栈桥；家具为可见实占矩形，坡不设AABB。
-- 擦边：水域/家具均开放边界，运动shape按自身精确外轮廓碰撞，不套车辆大圆。
-- 衔接：地面折点/对角线切分和Height共享profile；入口接平旧路，不移动旧楼。
Environment.Profile={{400,.055},{440,4.0},{470,4.0},{530,.32},{560,.24},{590,-1.5},{640,-2.5},{1152,-3}}
local profile=Environment.Profile
local seaEdge=560+(.24-Environment.SEA)/((.24+1.5)/30)
Environment.Pier={x1=-684,x2=-544,z1=-664,z2=-656}
Environment.Boardwalk={x1=-552,x2=-544,z1=-824,z2=-532}
Environment.Points={
    {id="coast_view",label="西南海岸观景台",name="西南海岸观景台",kind="scenery",x=-450,z=-450,district="greenbelt"},
    {id="coast_beach",label="西南海岸沙滩入口",name="西南海岸沙滩入口",kind="scenery",x=-548,z=-548,district="greenbelt"},
    {id="coast_pier",label="西南海岸观海栈桥",name="西南海岸观海栈桥",kind="scenery",x=-676,z=-660,district="greenbelt"},
}
Environment.ApproachRoutes={
    coast_view={{x=-384,z=-384},{x=-400,z=-400},{x=-450,z=-450}},
    coast_beach={{x=-384,z=-384},{x=-400,z=-400},{x=-450,z=-450},{x=-548,z=-548}},
    coast_pier={{x=-384,z=-384},{x=-400,z=-400},{x=-450,z=-450},{x=-548,z=-548},{x=-548,z=-660},{x=-676,z=-660}},
}
-- 不改旧路网：导航先沿邻里现有街到入口(-384,-384)，再依次追加此局部折线。
function Environment.ApproachRoute(id) return Environment.ApproachRoutes[id] end
-- World旧路网没有邻里环街：先导航至旧南门，再沿现有两段街中心去入口，禁斜切新楼。
function Environment.CityApproachRoute() return {{x=0,z=-172},{x=0,z=-384},{x=-384,z=-384}} end
Environment.Props={
    {id="coast_bench",kind="bench",x=-462,z=-447,w=2.3,d=.81,h=1.2},
    {id="coast_bench2",kind="bench",x=-447,z=-462,w=2.3,d=.81,h=1.2},
    {id="entry_sign",kind="sign",x=-405,z=-410,w=.12,d=.12,h=2.3,text="西南海岸 · 缓坡步道"},
    {id="beach_sign",kind="sign",x=-540,z=-553,w=.12,d=.12,h=2.3,text="沿岸栈道  /  观景栈桥"},
    {id="beach_bench",kind="bench",x=-534,z=-592,w=2.3,d=.81,h=1.2},
    {id="beach_bench2",kind="bench",x=-534,z=-732,w=2.3,d=.81,h=1.2},
    {id="beach_bin",kind="bin",x=-536,z=-610,w=.65,d=.65,h=1.05},
    {id="beach_bin2",kind="bin",x=-536,z=-746,w=.65,d=.65,h=1.05},
    {id="beach_shade",kind="shade",x=-525,z=-625,w=.16,d=.16,h=3.2},
    {id="beach_shade2",kind="shade",x=-525,z=-760,w=.16,d=.16,h=3.2},
    {id="rescue_ring",kind="rescue",x=-536,z=-650,w=.84,d=.24,h=2.2},
}
for i,p in ipairs({{-482,-453},{-453,-482},{-458,-485},{-485,-458},{-527,-575},{-522,-578},
    {-525,-703},{-520,-707},{-525,-796},{-519,-800}}) do
    Environment.Props[#Environment.Props+1]={id="coast_plant_"..i,kind="plant",x=p[1],z=p[2],w=.65,d=.65,h=1.3}
end
for i,p in ipairs({{-557,-590},{-557,-606},{-557,-708},{-557,-770},{-587,-557},{-612,-557}}) do
    Environment.Props[#Environment.Props+1]={id="shore_rock_"..i,kind="rock",x=p[1],z=p[2],w=2.0,d=1.6,h=.8}
end
local function inRect(b,x,z) return x>=b.x1 and x<=b.x2 and z>=b.z1 and z<=b.z2 end
local function overlap(a,b) return a.x1<b.x2 and a.x2>b.x1 and a.z1<b.z2 and a.z2>b.z1 end
function Environment.Contains(x,z) return inRect(Environment.Bounds,x,z) or inRect(Environment.Connector,x,z) end
function Environment.Reserved(rect) return overlap(rect,Environment.Bounds) or overlap(rect,Environment.Connector) end
function Environment.Height(x,z)
    local s=math.min(-x,-z)
    for i=2,#profile do
        local a,b=profile[i-1],profile[i]
        if s<=b[1] then return a[2]+(b[2]-a[2])*(s-a[1])/(b[1]-a[1]) end
    end
    return -3
end
function Environment.Surface(x,z)
    if inRect(Environment.Connector,x,z) then return .055 end
    if not inRect(Environment.Bounds,x,z) then return nil end
    if inRect(Environment.Pier,x,z) then return .42+math.min(1,math.max(0,(-x-552)/22))*.38 end
    if inRect(Environment.Boardwalk,x,z) then return math.max(.42,Environment.Height(x,z)+.04) end
    return Environment.Height(x,z)
end
function Environment.SurfaceKind(x,z)
    if not Environment.Contains(x,z) then return nil end
    if inRect(Environment.Pier,x,z) or inRect(Environment.Boardwalk,x,z) then return "wood" end
    if math.min(-x,-z)>=490 then return "sand" end
    return "concrete"
end
function Environment.AudioContext(x,z)
    local sea=Environment.Contains(x,z) and math.min(1,math.max(0,(math.min(-x,-z)-400)/130)) or 0
    local dx,dz=math.max(0,math.abs(x)-38),math.max(0,math.abs(z+70)-8.5)
    local bridge=math.max(0,1-math.sqrt(dx*dx+dz*dz)/12)
    local context={surface=Environment.SurfaceKind(x,z) or "concrete",sea=sea,bridge=bridge}
    if Environment.Contains(x,z) then context.urban=1-sea end
    return context
end
-- 静态水域按真实矩形并集扣掉栈桥；与渲染边缘一致，不随流式加载消失。
---@class CoastObstacle
---@field id string
---@field kind string
---@field x1 number
---@field x2 number
---@field z1 number
---@field z2 number
---@field y1 number
---@field y2 number
---@type CoastObstacle[]
Environment.StaticObstacles={
    {id="coast_water_north",kind="water",x1=-1152,x2=-seaEdge,z1=-656,z2=-seaEdge,y1=-10,y2=50},
    {id="coast_water_south",kind="water",x1=-1152,x2=-seaEdge,z1=-1152,z2=-664,y1=-10,y2=50},
    {id="coast_water_end",kind="water",x1=-1152,x2=-684,z1=-664,z2=-656,y1=-10,y2=50},
}
for _,p in ipairs(Environment.Props) do
    local y=assert(Environment.Surface(p.x,p.z))
    Environment.StaticObstacles[#Environment.StaticObstacles+1]={id=p.id,kind=p.kind,
        x1=p.x-p.w/2,x2=p.x+p.w/2,z1=p.z-p.d/2,z2=p.z+p.d/2,y1=y,y2=y+p.h}
end
function Environment.CollectObstacles(area,mode,height)
    local out={}
    for _,o in ipairs(Environment.StaticObstacles) do
        if overlap(area,o) and (height==nil or height<o.y2 and height+1.8>o.y1) then out[#out+1]=o end
    end
    return out
end
function Environment.IsFree(x,z,r,mode,height)
    local radius=r or .32
    local area={x1=x-radius,x2=x+radius,z1=z-radius,z2=z+radius}
    return #Environment.CollectObstacles(area,mode,height)==0
end
Environment.Free=Environment.IsFree
-- 导航线段同静态矩形做连续slab检测，不用离散采样跨过细家具。
function Environment.SegmentFree(a,b,r)
    local radius=r or .8
    for _,o in ipairs(Environment.StaticObstacles) do
        local lo,hi=0,1
        for _,v in ipairs({{a.x,b.x-a.x,o.x1-radius,o.x2+radius},{a.z,b.z-a.z,o.z1-radius,o.z2+radius}}) do
            if math.abs(v[2])<1e-10 then
                if v[1]<=v[3] or v[1]>=v[4] then lo,hi=1,0;break end
            else
                local s,t=(v[3]-v[1])/v[2],(v[4]-v[1])/v[2]
                lo,hi=math.max(lo,math.min(s,t)),math.min(hi,math.max(s,t))
            end
        end
        if lo<hi and hi>0 and lo<1 then return false end
    end
    return true
end
---@class CoastNavGraph
---@field nodes table[]
---@field edges table<number, table<number, number>>
---@field distances table<number, number>
---@field nextNode table<number, integer>
---@type table<string, CoastNavGraph>
local navigationGraphs={}
local navigationStats={builds=0,nodes=0,edges=0,buildSeconds=0,queries=0,segmentTests=0}
local function length(a,b) return math.sqrt((a.x-b.x)^2+(a.z-b.z)^2) end
local function tailProjection(x,z)
    local tail=Environment.CityApproachRoute()
    for i=2,#tail do
        local a,b=tail[i-1],tail[i]
        local dx,dz=b.x-a.x,b.z-a.z
        local t=math.max(0,math.min(1,((x-a.x)*dx+(z-a.z)*dz)/(dx*dx+dz*dz)))
        local px,pz=a.x+t*dx,a.z+t*dz
        if (px-x)^2+(pz-z)^2<36 then return tail,i,{x=px,z=pz} end
    end
    return nil
end
-- 所有固定边仅建一次，仍逐边执行原SegmentFree(.8)，不删角点/不稀疏采样。
function Environment.PrewarmNavigation()
    if navigationStats.builds>0 then return navigationStats end
    local started=os.clock()
    local base={}
    for _,p in ipairs(Environment.ApproachRoutes.coast_pier) do base[#base+1]={x=p.x,z=p.z} end
    for _,o in ipairs(Environment.StaticObstacles) do if o.kind~="water" then
        for _,xx in ipairs({o.x1-.81,o.x2+.81}) do for _,zz in ipairs({o.z1-.81,o.z2+.81}) do
            if Environment.Contains(xx,zz) and Environment.IsFree(xx,zz,.8) then base[#base+1]={x=xx,z=zz} end
        end end
    end end
    ---@type table<number, table<number, number>>
    local baseEdges={}
    local edgeCount=0
    for i=1,#base do baseEdges[i]={} end
    for i,a in ipairs(base) do for j=i+1,#base do
        if Environment.SegmentFree(a,base[j],.8) then
            local distance=length(a,base[j])
            baseEdges[i][j],baseEdges[j][i]=distance,distance;edgeCount=edgeCount+1
        end
    end end
    local targets={{id="coast_exit",x=-384,z=-384}}
    for _,p in ipairs(Environment.Points) do targets[#targets+1]=p end
    for _,target in ipairs(targets) do
        ---@type CoastNavGraph
        local graph={nodes={{x=target.x,z=target.z}},edges={{}},distances={[1]=0},nextNode={}}
        for i,p in ipairs(base) do
            graph.nodes[i+1]=p;graph.edges[i+1]={}
            for j,distance in pairs(baseEdges[i]) do graph.edges[i+1][j+1]=distance end
            if Environment.SegmentFree(target,p,.8) then
                local distance=length(target,p)
                graph.edges[1][i+1],graph.edges[i+1][1]=distance,distance
            end
        end
        local done={}
        for _=1,#graph.nodes do
            ---@type integer
            local best=0
            ---@type number
            local bestDistance=math.huge
            for i=1,#graph.nodes do
                if not done[i] and (graph.distances[i] or math.huge)<bestDistance then best,bestDistance=i,graph.distances[i] end
            end
            if best==0 then break end
            done[best]=true
            -- 固定索引顺序，等长路径保持稳定；反向最短路树不含动态起点。
            for i=1,#graph.nodes do
                local edge=graph.edges[best][i]
                if not done[i] and edge and bestDistance+edge<(graph.distances[i] or math.huge) then
                    graph.distances[i],graph.nextNode[i]=bestDistance+edge,best
                end
            end
        end
        navigationGraphs[target.id]=graph
    end
    navigationStats.builds,navigationStats.nodes,navigationStats.edges=1,#base,edgeCount
    navigationStats.buildSeconds=os.clock()-started
    print(string.format("[海岸导航预热] %d固定节点 / %d固定边 / 4目标反向树 / CPU %.6fs；动态仅连起点",
        #base,edgeCount,navigationStats.buildSeconds))
    return navigationStats
end
function Environment.NavigationStats() return navigationStats end
function Environment.NavigationRoute(id,x,z)
    if not Environment.Contains(x,z) then
        local approach=Environment.ApproachRoutes[id]
        if not approach then return nil end
        local tail,index,projection=tailProjection(x,z)
        if not tail then return nil end
        local route={{x=x,z=z},projection}
        for i=index,#tail do route[#route+1]=tail[i] end
        for i=2,#approach do route[#route+1]=approach[i] end
        return route
    end
    Environment.PrewarmNavigation()
    local graph=navigationGraphs[id]
    if not graph then return nil end
    local start={x=x,z=z}
    ---@type integer
    local best=0
    ---@type number
    local bestDistance=math.huge
    navigationStats.queries=navigationStats.queries+1
    for i,p in ipairs(graph.nodes) do
        navigationStats.segmentTests=navigationStats.segmentTests+1
        if Environment.SegmentFree(start,p,.8) then
            local candidate=length(start,p)+(graph.distances[i] or math.huge)
            if candidate<bestDistance then best,bestDistance=i,candidate end
        end
    end
    if best==0 then return nil end
    local route={start}
    local index=best
    while index do
        local p=graph.nodes[index]
        local last=route[#route]
        if index==1 or length(last,p)>.000000001 then route[#route+1]={x=p.x,z=p.z} end
        index=graph.nextNode[index]
    end
    return route
end
-- 返回完整局部退出路径至旧南门(0,-172)，主线程只须从末点接World.Route。
-- 位于接续街中段时直接逆向裁尾，不先倒退到海岸入口。
function Environment.ExitRoute(x,z)
    local route
    local tail=Environment.CityApproachRoute()
    if Environment.Contains(x,z) then
        route=Environment.NavigationRoute("coast_exit",x,z)
        if not route then return nil end
        for i=#tail-1,1,-1 do route[#route+1]={x=tail[i].x,z=tail[i].z} end
    else
        local projected,index,projection=tailProjection(x,z)
        if not projected then return nil end
        route={{x=x,z=z},projection}
        for i=index-1,1,-1 do route[#route+1]={x=tail[i].x,z=tail[i].z} end
    end
    return route
end
function Environment.SetupMaterials(mats)
    if mats.coast_sand then return end
    local sand=assert(cache:GetResource("Material",Environment.Resources[1]))
    local material=Material:new()
    material:SetTechnique(0,assert(cache:GetResource("Technique","Techniques/PBR/PBRDiffNormal.xml")))
    material:SetTexture(TU_DIFFUSE,assert(sand:GetTexture(TU_DIFFUSE)))
    material:SetTexture(TU_NORMAL,assert(sand:GetTexture(TU_NORMAL)))
    material:SetShaderParameter("MatDiffColor",Variant(Color(.86,.76,.58)))
    material:SetShaderParameter("Roughness",Variant(.96));material:SetShaderParameter("Metallic",Variant(0))
    mats.coast_sand=material
    mats.coast_water=assert(cache:GetResource("Material",Environment.Resources[2])):Clone()
    mats.coast_water:SetShaderParameter("WaterTint",Variant(Color(.20,.46,.64)))
    local sign=Material:new()
    sign:SetTechnique(0,assert(cache:GetResource("Technique","Techniques/PBR/PBRDiff.xml")))
    sign:SetTexture(TU_DIFFUSE,assert(cache:GetResource("Texture2D",Environment.Resources[3])))
    sign:SetShaderParameter("MatDiffColor",Variant(Color(1,1,1)))
    sign:SetShaderParameter("Roughness",Variant(.84))
    sign:SetShaderParameter("Metallic",Variant(0))
    sign:SetShaderParameter("MatEmissiveColor",Variant(Color(.07,.07,.07)))
    mats.coast_bridge_sign=sign
end
-- 返回精确地形三角形，纯数据可离线验证重心插值与Height，渲染不另算高度。
function Environment.TerrainTriangles(cell,emit)
    local b=Environment.Bounds
    local x1,x2=math.max(cell.x1,b.x1),math.min(cell.x2,b.x2)
    local z1,z2=math.max(cell.z1,b.z1),math.min(cell.z2,b.z2)
    if x1>=x2 or z1>=z2 then return 0 end
    local xs,zs={x1,x2},{z1,z2}
    local knots={490,seaEdge,568}
    for _,p in ipairs(profile) do knots[#knots+1]=p[1] end
    for x=math.ceil(x1/8)*8,x2-1,8 do xs[#xs+1]=x end
    for z=math.ceil(z1/8)*8,z2-1,8 do zs[#zs+1]=z end
    for _,s in ipairs(knots) do
        if -s>x1 and -s<x2 then xs[#xs+1]=-s end
        if -s>z1 and -s<z2 then zs[#zs+1]=-s end
    end
    table.sort(xs);table.sort(zs)
    local count=0
    local function point(x,z) return {x=x,z=z,y=Environment.Height(x,z)} end
    for i=2,#xs do for j=2,#zs do
        local l,r,n,f=xs[i-1],xs[i],zs[j-1],zs[j]
        if r>l and f>n then
            local a,b,c,e=point(l,n),point(l,f),point(r,n),point(r,f)
            local s=math.min(-(l+r)/2,-(n+f)/2)
            local mat=s>=490 and "coast_sand" or "grass"
            -- 同一格跨x=z折线时沿a-e切开；其余格沿b-c切开亦共面。
            if l==n and r==f then emit(mat,a,b,e);emit(mat,a,e,c)
            else emit(mat,a,b,c);emit(mat,c,b,e) end
            count=count+2
        end
    end end
    return count
end
local function sphere(d,mat,x,y,z,rx,ry,rz)
    for row=0,3 do for sector=0,7 do
        local function point(v,u)
            local phi=-math.pi/2+v*math.pi/4
            local theta=u*math.pi/4
            return Vector3(x+rx*math.cos(phi)*math.cos(theta),y+ry*math.sin(phi),z+rz*math.cos(phi)*math.sin(theta))
        end
        if row==0 then d:Triangle(mat,point(row,sector),point(row+1,sector),point(row+1,sector+1))
        elseif row==3 then d:Triangle(mat,point(row,sector),point(row+1,sector),point(row,sector+1))
        else d:Quad(mat,point(row,sector),point(row+1,sector),point(row,sector+1),point(row+1,sector+1)) end
    end end
end
function Environment.RenderCell(d,cell)
    local V=Vector3
    local count=Environment.TerrainTriangles(cell,function(mat,a,b,c)
        d:Triangle(mat,V(a.x,a.y,a.z),V(b.x,b.y,b.z),V(c.x,c.y,c.z))
    end)
    local function clipped(b,fn)
        local l,r,n,f=math.max(b.x1,cell.x1),math.min(b.x2,cell.x2),math.max(b.z1,cell.z1),math.min(b.z2,cell.z2)
        if l<r and n<f then fn(l,r,n,f) end
    end
    clipped(Environment.Connector,function(l,r,n,f) d:Quad("concrete",V(l,.055,n),V(l,.055,f),V(r,.055,n),V(r,.055,f)) end)
    clipped({x1=-1152,x2=-seaEdge,z1=-1152,z2=-seaEdge},function(l,r,n,f)
        d:Quad("coast_water",V(l,.15,n),V(l,.15,f),V(r,.15,n),V(r,.15,f))
    end)
    local function deck(rect)
        clipped(rect,function(l,r,n,f)
            for x=l,r-.001,2 do for z=n,f-.001,2 do
                local xx,zz=math.min(r,x+2),math.min(f,z+2)
                local function p(px,pz) return V(px,assert(Environment.Surface(px,pz)),pz) end
                d:Quad("wood",p(x,z),p(x,zz),p(xx,z),p(xx,zz),2)
            end end
        end)
    end
    deck(Environment.Boardwalk);deck(Environment.Pier)
    -- 栈桥下部横梁/支柱，让平台不是悬空贴片；水域本身承担栏外阻挡。
    for x=-682,-550,8 do
        if x>=cell.x1 and x<cell.x2 and -660>=cell.z1 and -660<cell.z2 then
            local y=assert(Environment.Surface(x,-660))
            d:Box("wood",x,y-.20,-660,.20,.28,8.2)
            for _,z in ipairs({-664.1,-655.9}) do
                -- 桩底埋入同源真实海床15cm，桩顶接甲板底；不按固定短柱悬在水中。
                local bottom=Environment.Height(x,z)-.15
                d:Box("wood",x,(bottom+y)/2,z,.22,y-bottom,.22)
                d:Box("metal",x,y+.55,z,.08,1.1,.08)
                d:Box("wood",x,y+1.05,z,8,.09,.10)
            end
        end
    end
    if -684>=cell.x1 and -684<cell.x2 and -660>=cell.z1 and -660<cell.z2 then
        d:Box("wood",-684,1.75,-660,.12,.10,8)
        d:Sign("观海平台 · 请勿翻越",-681,2.1,-660,90,.32)
    end
    for _,p in ipairs(Environment.Props) do
        if p.x>=cell.x1 and p.x<cell.x2 and p.z>=cell.z1 and p.z<cell.z2 then
            local y=assert(Environment.Surface(p.x,p.z))
            if p.kind=="bench" then
                d:Bench(p.x,p.z,0,y)
            elseif p.kind=="shade" then
                d:Box("wood",p.x,y+1.6,p.z,.16,3.2,.16)
                for _,side in ipairs({-1,1}) do
                    local a,b,c=V(p.x-2.4,y+2.5,p.z+side*2.4),V(p.x,y+3.2,p.z),V(p.x+2.4,y+2.5,p.z+side*2.4)
                    d:Triangle("street_canvasLight",a,b,c);d:Triangle("street_canvasLight",c,b,a)
                end
            elseif p.kind=="sign" then
                d:Box("wood",p.x,y+1.15,p.z,.12,2.3,.12)
                d:Box("street_teal",p.x,y+2.0,p.z,3,.55,.12)
                d:Sign(p.text,p.x,y+2.0,p.z+.075,180,.28)
                d:Sign(p.text,p.x,y+2.0,p.z-.075,0,.28)
            elseif p.kind=="rescue" then
                d:Box("wood",p.x,y+1.1,p.z,.16,2.2,.16)
                -- 环形截面直接合批，外径.84m、内径.54m；不是实心圆盘。
                for i=0,15 do
                    local a,b=i*math.pi/8,(i+1)*math.pi/8
                    local function q(angle,r,depth) return V(p.x+r*math.cos(angle),y+1.5+r*math.sin(angle),p.z+depth) end
                    local mat=i%4==0 and "trim" or "street_red"
                    d:Quad(mat,q(a,.42,-.11),q(b,.42,-.11),q(a,.27,-.11),q(b,.27,-.11))
                    d:Quad(mat,q(b,.42,.11),q(a,.42,.11),q(b,.27,.11),q(a,.27,.11))
                    d:Quad(mat,q(a,.42,.11),q(b,.42,.11),q(a,.42,-.11),q(b,.42,-.11))
                end
            elseif p.kind=="plant" then
                d:Box("wood",p.x,y+.38,p.z,.09,.76,.09)
                sphere(d,"foliage",p.x,y+.8,p.z,.325,.5,.325)
            elseif p.kind=="rock" then sphere(d,"stone",p.x,y+.26,p.z,1,.54,.8)
            else
                d:Box("street_teal",p.x,y+.50,p.z,.65,.95,.65)
                d:Box("metal",p.x,y+1.01,p.z,.68,.08,.68)
                d:Box("recess",p.x,y+.82,p.z-.331,.42,.18,.025)
            end
        end
    end
    return count
end
-- 原桥投影内补承重梁、桥侧轮廓/收坡边界，旧两桥墩和地面障碍不变。
function Environment.BuildCore(city)
    Environment.PrewarmNavigation()
    Environment.SetupMaterials(city.mats)
    local d=city.details
    for _,z in ipairs({-76,-64}) do
        d:Box("concrete",0,5.12,z,76,.66,.65)
        for x=-34,34,8 do d:Box("concrete",x,5.25,-70,.24,.40,12) end
        local edge=z+(z< -70 and -2.4 or 2.4)
        d:Box("metal",0,6.95,edge,76,.75,.20)
        for x=-36,36,4 do d:Box("trim",x,7.1,edge,.08,1.05,.12) end
    end
    for _,x in ipairs({-29,29}) do
        d:Box("concrete",x,5.15,-70,4.8,.60,15)
        d:Box("metal",x,1.0,-72.035,2.35,.40,.025)
    end
    for _,side in ipairs({-1,1}) do
        local l,r=math.min(side*24,side*38),math.max(side*24,side*38)
        local function y(x) return 6.56+(math.abs(x)-24)/14*1.44 end
        d:Quad("road",Vector3(l,y(l),-77.7),Vector3(l,y(l),-62.3),Vector3(r,y(r),-77.7),Vector3(r,y(r),-62.3))
        for _,z in ipairs({-77.7,-62.3}) do
            d:Quad("concrete",Vector3(l,6.55,z),Vector3(l,y(l),z),Vector3(r,6.55,z),Vector3(r,y(r),z))
        end
    end
    -- 纸板/睡袋位于原木板床，周围留足两个方向进出；(0,-70)两米交互圆全空。
    -- 原木床面y=.24；各层由底面向上叠放，不能把纸板和睡袋埋进床内。
    local paperTop=.24+.004+.035
    d:Box("street_paper",2,paperTop-.035/2,-73,2.35,.035,1.15)
    d:Box("street_canvas",2,paperTop+.20/2,-73.05,1.85,.20,.70)
    d:Box("street_canvasLight",2.72,paperTop+.20+.14/2,-73.05,.28,.14,.59)
    for x=1.25,2.6,.16 do d:Box("metal",x,paperTop+.20+.006,-73.34,.045,.012,.018) end
    d:Box("metal",0,5.30,-70,5.2,.12,.40)
    d:Box("lamp",0,5.22,-70,4.8,.035,.25)
    city:NightLight(0,4.9,-70,12,13)
    -- 双面大牌只悬空，不放新柱挡中心路；从南北导航接近均能看到桥下入口。
    for _,z in ipairs({-61.36,-78.64}) do
        d:Box("street_teal",0,4.30,z,11,.90,.12)
        local node=d.root:CreateChild("桥下实体入口字牌")
        node.position=Vector3(0,4.30,z+(z< -70 and -.075 or .075))
        node.rotation=Quaternion(0,z< -70 and 0 or 180,0)
        local geom=node:CreateComponent("CustomGeometry")
        geom:BeginGeometry(0,TRIANGLE_LIST)
        -- 独立0..1 UV，整张字牌只显示一次，不使用米制平铺UV。
        local function vertex(x,y,u,v)
            geom:DefineVertex(Vector3(x,y,0))
            geom:DefineNormal(Vector3(0,0,-1))
            geom:DefineTexCoord(Vector2(u,v))
        end
        vertex(-5.5,-.45,0,1);vertex(-5.5,.45,0,0);vertex(5.5,-.45,1,1)
        vertex(5.5,-.45,1,1);vertex(-5.5,.45,0,0);vertex(5.5,.45,1,0)
        assert(geom:GenerateTangents(),"桥下入口字牌切线生成失败")
        geom:Commit();geom:SetMaterial(city.mats.coast_bridge_sign)
        geom.castShadows=false;geom.drawDistance=140
    end
    print(string.format("[城市环境] 桥下原点(0,-70)不动 / 岸丘4m / %d件海岸设施 / 开放海湾752m / 分块8m地形",#Environment.Props))
end
return Environment
