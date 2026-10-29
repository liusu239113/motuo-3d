-- 与原356m街网直接相接、可走可骑的确定性邻里街区。
-- 基于scaffold-3d-scene/CityDetails的所有权：此处只生成描述，WorldStream建节点。
-- 不修改POI、订单、存档与既有建筑低层足迹。
local Expansion = {}
Expansion.LIMIT=424
Expansion.RESERVED=440
Expansion.MAX_BUILDINGS_PER_CELL=14
Expansion.MAX_PROPS_PER_CELL=24
-- 用UrhoXCLI model-info实测，绝不猜测建筑尺寸。
Expansion.Models={
    {size={.798828125,.9980469346046448,.833984375},triangles=16790},
    {size={.755859375,.9980469048023224,.763671875},triangles=4492},
    {size={.517578125,.9980469048023224,.931640625},triangles=15130},
}
---@type table[]
Expansion.Roads={}
---@type table[]
Expansion.Buildings={}
---@type table[]
Expansion.Plazas={}
---@type table[]
Expansion.Props={}
local function road(id,name,x1,z1,x2,z2,width,sidewalk,kind)
    Expansion.Roads[#Expansion.Roads+1]={id="adjacent_"..id,name=name,x1=x1,z1=z1,x2=x2,z2=z2,
        width=width or 12,sidewalk=sidewalk or 4,kind=kind or "neighborhood",old=false}
end
-- 俯视设计，单位米：地面、渲染与净空检验共用此规划。
-- 384 +================ 外侧接续环街 ========================+
--     |   住宅 / 植栽庭院 / 贯通小巷 / 转角商铺               |
-- 240 |   +============= 邻里环街 ===================+        |
-- 195 |   |  旧城保护范围：不添加任何新落地实体        |        |
-- 178 |   |  只接通18个旧路口，不覆盖既有建筑与POI    |        |
--     |   |             (0,-20)开局                  |        |
--     |   +=========================================+        |
--     +======================================================+
-- 每个出口从±178精确开始，跨过±195流式保护边缝，没有草地断路。
for _,x in ipairs({-172,-100,0,100,172}) do
    road("north_"..x,"安居北街",x,178,x,384,12,6)
    road("south_"..x,"桥南生活街",x,-384,x,-178,12,6)
end
for _,z in ipairs({-172,0,100,172}) do
    road("east_"..z,"东邻里街",178,z,384,z,12,6)
    road("west_"..z,"西苑里街",-384,z,-178,z,12,6)
end
for _,r in ipairs({240,384}) do
    road("loop_n"..r,"邻里北环街",-384,r,384,r)
    road("loop_s"..r,"邻里南环街",-384,-r,384,-r)
    road("loop_e"..r,"邻里东环街",r,-384,r,384)
    road("loop_w"..r,"邻里西环街",-r,-384,-r,384)
end
-- 四条144m共享小巷两端均接街，不放阻车桩、隐藏闸门或车辆空气墙。
road("alley_e","梧桐巷",240,-86,384,-86,5,1,"alley")
road("alley_w","西苑支巷",-384,-86,-240,-86,5,1,"alley")
road("alley_n","北里支巷",52,240,52,384,5,1,"alley")
road("alley_s","桥南支巷",52,-384,52,-240,5,1,"alley")
-- 四条96m横巷形成进入小广场的真实通路。
road("court_e","东邻里庭巷",312,-144,312,-48,5,1,"alley")
road("court_w","西苑庭巷",-312,-144,-312,-48,5,1,"alley")
road("court_n","安居庭巷",24,312,120,312,5,1,"alley")
road("court_s","桥南庭巷",24,-312,120,-312,5,1,"alley")
local shopNames={"邻里杂货","鲜果小铺","街角书屋","家常小馆","花草小店","便民修配"}
local function building(id,x,z,index,yaw,shop,height)
    local spec=assert(Expansion.Models[index])
    local scale=(height or (index==3 and 20 or 18))/spec.size[2]
    local w,h,depth=spec.size[1]*scale,spec.size[2]*scale,spec.size[3]*scale
    local ex,ez=w,depth
    if yaw%180~=0 then ex,ez=depth,w end
    Expansion.Buildings[#Expansion.Buildings+1]={id="adjacent_"..id,x=x,z=z,w=w,d=depth,h=h,
        floors=index==3 and 6 or 4,yaw=yaw,asset=index,scale=scale,expansion=true,
        style="plaster",name=shop and shopNames[(#Expansion.Buildings%#shopNames)+1] or "邻里住宅",
        shop=shop or false,x1=x-ex/2-.05,x2=x+ex/2+.05,z1=z-ez/2-.05,z2=z+ez/2+.05}
end
-- 两圈有规划的连续沿街建筑，门前节奏28..56m；间隙是可走的巷口。
for i,z in ipairs({-144,-116,-56,-28,28,56,130,212}) do
    building("east_inner"..i,214,z,i%3==0 and 1 or 2,-90,i%2==0)
    building("west_inner"..i,-214,z,i%3==0 and 1 or 2,90,i%2==1)
end
for i,x in ipairs({-140,-64,-32,28,136}) do
    building("north_inner"..i,x,214,i%2==0 and 1 or 2,180,i%2==0)
    building("south_inner"..i,x,-214,i%2==0 and 1 or 2,0,i%2==1)
end
for i,z in ipairs({-322,-278,-144,-116,-56,-28,28,56,130,212,278,322}) do
    building("east_outer"..i,268,z,i%4==0 and 3 or 2,90,i%3==0)
    building("west_outer"..i,-268,z,i%4==0 and 3 or 2,-90,i%3==1)
end
for i,x in ipairs({-322,-278,-140,-64,-32,28,136,212,278,322}) do
    building("north_outer"..i,x,268,i%4==0 and 3 or 2,0,i%3==0)
    building("south_outer"..i,x,-268,i%4==0 and 3 or 2,180,i%3==1)
end
-- 外街另一侧用低层住宅收尾，不让街道直接切成整片空草地。
for i,p in ipairs({{408,-144,90},{408,130,90},{-408,-144,-90},{-408,130,-90},
    {-140,408,0},{136,408,0},{-140,-408,180},{136,-408,180}}) do
    building("edge_home"..i,p[1],p[2],2,p[3],false,15)
end
-- 共78栋现有真实模型，不非等比拉伸，不额外生成资产。
for _,p in ipairs({
    {id="east",name="梧桐小广场",x=338,z=-116},
    {id="west",name="西苑小庭",x=-338,z=-116},
    {id="north",name="安居小广场",x=72,z=338},
    {id="south",name="桥南小庭",x=72,z=-338},
}) do
    p.w,p.d=28,24
    Expansion.Plazas[#Expansion.Plazas+1]=p
    -- 广场四向至少留出5m贯通空间。
    for _,q in ipairs({{p.x,p.z-8},{p.x,p.z+8}}) do
        Expansion.Props[#Expansion.Props+1]={id=p.id.."_bench"..q[2],kind="bench",x=q[1],z=q[2],w=2.3,d=.81,h=1.2}
    end
    for _,side in ipairs({-1,1}) do
        Expansion.Props[#Expansion.Props+1]={id=p.id.."_tree"..side,kind="tree",x=p.x+side*10,z=p.z,w=1.8,d=1.8,h=5.4}
    end
end
-- 街边细节放在人行通带之后；树池与障碍同源，不把杆子隐藏在路口。
for _,side in ipairs({-1,1}) do
    for _,along in ipairs({-322,-278,28,56,130,212,278,322}) do
        Expansion.Props[#Expansion.Props+1]={id="edge_tree_"..side.."_"..along,kind="tree",
            x=side*365,z=along,w=1.8,d=1.8,h=5.4}
    end
end
function Expansion.RoadRect(r,margin)
    local half=r.width/2+(margin or 0)
    if r.x1==r.x2 then return {x1=r.x1-half,x2=r.x1+half,z1=math.min(r.z1,r.z2),z2=math.max(r.z1,r.z2)} end
    return {x1=math.min(r.x1,r.x2),x2=math.max(r.x1,r.x2),z1=r.z1-half,z2=r.z1+half}
end
function Expansion.Overlaps(a,b)
    return a.x1<b.x2 and a.x2>b.x1 and a.z1<b.z2 and a.z2>b.z1
end
function Expansion.Reserved(rect)
    return Expansion.Overlaps(rect,{x1=-440,x2=440,z1=-440,z2=440})
end
-- 只构建[-195,195]内的出口接缝，并在Finish前登记原有Surface查询。
-- 不在旧城添加任何落地实体，也不覆盖其余旧路面。
function Expansion.BuildSeams(d)
    local count=0
    for _,r in ipairs(Expansion.Roads) do
        local outer,inner=Expansion.RoadRect(r,r.sidewalk),Expansion.RoadRect(r)
        local function patch(rect,mat,y)
            local x1,x2=math.max(-195,rect.x1),math.min(195,rect.x2)
            local z1,z2=math.max(-195,rect.z1),math.min(195,rect.z2)
            if x1<x2 and z1<z2 then d:Ground(mat,(x1+x2)/2,(z1+z2)/2,x2-x1,z2-z1,y);count=count+1 end
        end
        if r.x1==r.x2 then
            patch({x1=outer.x1,x2=inner.x1,z1=outer.z1,z2=outer.z2},"concrete",.085)
            patch({x1=inner.x2,x2=outer.x2,z1=outer.z1,z2=outer.z2},"concrete",.085)
        else
            patch({x1=outer.x1,x2=outer.x2,z1=outer.z1,z2=inner.z1},"concrete",.085)
            patch({x1=outer.x1,x2=outer.x2,z1=inner.z2,z2=outer.z2},"concrete",.085)
        end
        patch(inner,"road",.055)
    end
    return count
end
function Expansion.Stats()
    local length,shops=0,0
    for _,r in ipairs(Expansion.Roads) do length=length+math.abs(r.x2-r.x1)+math.abs(r.z2-r.z1) end
    for _,b in ipairs(Expansion.Buildings) do if b.shop then shops=shops+1 end end
    return {roads=#Expansion.Roads,roadMeters=length,buildings=#Expansion.Buildings,shops=shops,
        plazas=#Expansion.Plazas,props=#Expansion.Props,span=848,streamCell=256,residentGeometry=false}
end
return Expansion
