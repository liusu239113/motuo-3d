-- 赛道设施共用材质与分块网格，护栏位于路肩外，不另建一套车辆碰撞系统。
local Decor = {}
local P = require("Parts")
local Details = require("TrackDetails")
local V = Vector3
local HOUSE="uuid://D6f5ARUOv2X7EEmXLSrx1AM9"
local HOUSE_MATS={"uuid://Bu1-aXStY3WMbN0SDgV_0J8L","uuid://HntT6UQGaB9sTTQOuRq_XVBm",
    "uuid://HhdXudJoS_1n5psy_52upCCB","uuid://BYUaAXeDcr7-GOyrJkX2dGoW"}
Decor.Resources={HOUSE}
Decor.ResourceTypes={[HOUSE]="Model"}
for _,path in ipairs(HOUSE_MATS) do Decor.Resources[#Decor.Resources+1]=path;Decor.ResourceTypes[path]="Material" end

---@param root Node
---@param L table
---@param s number
---@param offset number
---@return Node?
---@param width? number
---@param depth? number
local function station(root,L,s,offset,width,depth)
    local p,yaw=L.RoadPoint(s)
    local a=math.rad(yaw)
    local x,z=p.x+math.cos(a)*offset,p.z-math.sin(a)*offset
    local y=L.TerrainHeight(x,z)
    local w,d=width or 10,depth or 12
    local safe=Details.Site(L,s,offset,w,d)
    if not safe then return nil end
    x,y,z=safe.x,safe.y,safe.z
    Details.Reserve(safe,math.sqrt(w*w+d*d)*.5)
    local n=root:CreateChild("赛道设施")
    n.position=V(x,y,z)
    n.rotation=Quaternion(0,yaw,0)
    return n
end

-- 既有设施也改成局部UV；栏杆竖面不再把纹理挤成一条XZ直线。
---@param g CustomGeometry
---@param L table
---@param a Vector3
---@param b Vector3
---@param c Vector3
---@param d Vector3
local function face(g,L,a,b,c,d)
    local n=(b-a):CrossProduct(c-a):Normalized()
    local u,v=(b-a):Length()/2,(c-a):Length()/2
    L.Vertex(g,a,n,Vector2(0,0));L.Vertex(g,b,n,Vector2(u,0));L.Vertex(g,c,n,Vector2(0,v))
    L.Vertex(g,c,n,Vector2(0,v));L.Vertex(g,b,n,Vector2(u,0));L.Vertex(g,d,n,Vector2(u,v))
end

-- 桩与横梁按材质合批，每144米一块，保留引擎空间剔除能力。
---@param g CustomGeometry
---@param L table
---@param p Vector3
---@param right Vector3
---@param width number
---@param height number
---@param depth number
local function box(g,L,p,right,width,height,depth)
    local forward=V(-right.z,0,right.x)
    local x,z=right*(width*.5),forward*(depth*.5)
    local y=V(0,height,0)
    local a,b,c,d=p-x-z,p-x+z,p+x-z,p+x+z
    local function quad(q,r,s,t) face(g,L,q,s,r,t) end
    quad(a,b,c,d);quad(a+y,c+y,b+y,d+y)
    face(g,L,a,b,a+y,b+y);face(g,L,c,c+y,d,d+y)
    face(g,L,a,a+y,c,c+y);face(g,L,b,d,b+y,d+y)
end

local function infrastructure(root,L,m,tick)
    local road=L.Roads[1]
    local circuit=L.activeId=="circuit"
    local forest=L.activeId=="forest"
    local length=L.RouteLength
    local chunks=math.ceil(length/144)
    for chunk=1,chunks do
        local lo,hi=(chunk-1)*144,math.min(length,chunk*144)
        local rail=L.Geometry(root,"合批防护栏与反光桩",m.rail)
        local reflect=L.Geometry(root,"合批反光标与制动距离牌",m.white)
        for segment=0,math.floor((hi-lo-1)/6) do
            local s=lo+segment*6
            local a,yaw=L.RoadPoint(s)
            local b,yawB=L.RoadPoint(math.min(s+6,hi))
            local r=V(math.cos(math.rad(yaw)),0,-math.sin(math.rad(yaw)))
            local rb=V(math.cos(math.rad(yawB)),0,-math.sin(math.rad(yawB)))
            local turn=math.abs((yawB-yaw+180)%360-180)
            for side=-1,1,2 do
                local offset=road.shoulder+(circuit and 4 or 1.1)
                local pa,pb=a+r*(side*offset),b+rb*(side*offset)
                local guarded=circuit or (not forest and (turn>1.6 or L.activeId=="alpine" or (L.activeId=="coast" and side==-1)))
                -- 每144米留出赛事救援间隙，所有桩脚采样真实地形并向下埋入。
                local ay=L.TerrainHeight(pa.x,pa.z)
                local by=L.TerrainHeight(pb.x,pb.z)
                local dry=L.WaterDepth(pa.x,pa.z)<=.01 and L.WaterDepth(pb.x,pb.z)<=.01
                local _,onA=L.Height(pa.x,pa.z)
                local _,onB=L.Height(pb.x,pb.z)
                local railA,railB=V(pa.x,ay,pa.z),V(pb.x,by,pb.z)
                if guarded and s-lo>7 and dry and not onA and not onB then
                    for _,h in ipairs({.53,.82}) do
                        local aa,bb=railA+V(0,h,0),railB+V(0,h,0)
                        face(rail,L,aa,bb,aa+V(0,.18,0),bb+V(0,.18,0))
                        face(rail,L,bb,aa,bb+V(0,.18,0),aa+V(0,.18,0))
                    end
                    box(rail,L,railA-V(0,.18,0),r,.12,1.25,.14)
                end
                if math.floor(s/6)%4==0 then
                    local q=a+r*(side*(road.shoulder+.6))
                    local y=L.TerrainHeight(q.x,q.z)
                    local _,onRoad=L.Height(q.x,q.z)
                    if not onRoad and L.WaterDepth(q.x,q.z)<=.01 then
                        box(reflect,L,V(q.x,y-.08,q.z),r,.14,.9,.18)
                        box(rail,L,V(q.x,y+.58,q.z),r,.15,.14,.19)
                    end
                end
            end
        end
        rail.drawDistance=330;reflect.drawDistance=230
        rail.castShadows=false;reflect.castShadows=false
        rail:GenerateTangents();rail:Commit();reflect:GenerateTangents();reflect:Commit()
        tick("赛事环境",chunk,chunks)
    end
end

local function startArea(root,L,m)
    local road=L.Roads[1]
    local p,yaw=L.RoadPoint(0)
    local start=root:CreateChild("起终点龙门与发车格")
    start.position=p;start.rotation=Quaternion(0,yaw,0)
    local w=road.shoulder+1.8
    for side=-1,1,2 do
        P.Add(start,"起终点支柱","Box",m.rail,V(side*w,3,0),V(.35,6,.35),nil,false)
    end
    P.Add(start,"起终点横梁","Box",m.dark,V(0,5.8,0),V(w*2+.5,.8,.45),nil,false)
    for i=-7,7 do
        P.Add(start,"起终点棋盘格","Box",i%2==0 and m.white or m.dark,V(i*(w*2/15),5.8,-.25),V(w*2/15,.45,.03),nil,false)
    end
    local grid=L.Geometry(root,"随路线贴地发车标线",m.white)
    -- 发车格逐角查询真实三角形高程，坡道与弯角不使用悬空平板。
    for row=0,4 do
        for side=-1,1,2 do
            local s=-8-row*6.8+(side==1 and 2 or 0)
            local lane=side*math.min(2.25,road.width-.8)
            local a=L.TrafficPose(s,lane-.55)+V(0,.025,0)
            local b=L.TrafficPose(s+.12,lane-.55)+V(0,.025,0)
            local c=L.TrafficPose(s,lane+.55)+V(0,.025,0)
            local d=L.TrafficPose(s+.12,lane+.55)+V(0,.025,0)
            L.Triangle(grid,a,b,c);L.Triangle(grid,c,b,d)
        end
    end
    for k=0,15 do
        local a=L.TrafficPose(0,-road.width+k*road.width/8)+V(0,.026,0)
        local b=L.TrafficPose(.5,-road.width+k*road.width/8)+V(0,.026,0)
        local c=L.TrafficPose(0,-road.width+(k+1)*road.width/8)+V(0,.026,0)
        local d=L.TrafficPose(.5,-road.width+(k+1)*road.width/8)+V(0,.026,0)
        if k%2==0 then L.Triangle(grid,a,b,c);L.Triangle(grid,c,b,d) end
    end
    grid:Commit()
    -- 每张图细节模块都做完整占地校验；湖图额外保留原维修区。
    if L.activeId~="lake" then return end
    local pit=station(root,L,80,road.shoulder+24,10,25)
    if not pit then return end
    pit.name="维修与赛事控制区"
    P.Add(pit,"服务间","Box",m.white,V(0,2.1,0),V(8,4.2,23),nil,false)
    P.Add(pit,"维修屋顶","Box",m.red,V(0,4.35,0),V(9,.35,24),nil,false)
    for z=-8,8,8 do
        P.Add(pit,"维修间车库卷门","Box",m.dark,V(-4.03,1.7,z),V(.05,3.1,5.8),nil,false)
        P.Add(pit,"维修编号板","Box",m.yellow,V(-4.08,3.65,z),V(.04,.45,2),nil,false)
    end
    for _,s in ipairs({65,125,185}) do
        local flag=station(root,L,s,-road.shoulder-5,2,2)
        if flag then
            P.Add(flag,"赛道旗杆","Cylinder",m.rail,V(0,2.5,0),V(.06,5,.06),nil,false)
            P.Add(flag,"赛事旗帜","Box",m.red,V(.55,4.4,0),V(1.1,.65,.025),nil,false)
        end
    end
end

local function kerbs(root,L,m)
    if L.activeId~="circuit" then return end
    local road=L.Roads[1]
    local red=L.Geometry(root,"红色路缘合批",m.red)
    local white=L.Geometry(root,"白色路缘合批",m.white)
    for i=1,#road.samples-1 do
        local p=road.samples[i]
        for side=-1,1,2 do
            L.Ribbon(math.floor(p.s/4)%2==0 and red or white,road,i,i,
                side==1 and road.width or -road.width-.8,side==1 and road.width+.8 or -road.width,.025,false)
        end
    end
    red:Commit();white:Commit()
end

local function existingScenery(root,L,m)
    -- 复用已有纹理岩石，模型包围盒参与完整占地避让，不新增下载资源。
    local rockA=assert(cache:GetResource("Model","uuid://As2_acelV1DosNkDmeMasF4T"))
    local rockB=assert(cache:GetResource("Model","uuid://DAxRITvZ1vC60um7M6gXY_Va"))
    local matA=assert(cache:GetResource("Material","uuid://ETwgwdlLT9yb0fm2NxmLlURS"))
    local matB=assert(cache:GetResource("Material","uuid://HDoGiRhCA1ZwjewmLbRqhTOq"))
    local models={rockA,rockB}
    local materials={matA,matB}
    local count=L.activeId=="circuit" and 8 or (L.activeId=="canyon" and 54 or 28)
    for i=1,count do
        local s=L.RouteLength*(i-.3)/count
        local side=i%2==0 and 1 or -1
        local offset=side*(L.Roads[1].shoulder+15+i%4*7)
        local p=L.TrafficPose(s,offset)
        local y,onRoad=L.Height(p.x,p.z)
        local k=i%2+1
        local model=assert(models[k]);local bounds=model.boundingBox
        local height=L.activeId=="canyon" and (5+i%5*2.8) or (1.3+i%3*.7)
        local scale=height/math.max(.01,bounds.size.y)
        local radius=.5*math.sqrt(bounds.size.x^2+bounds.size.z^2)*scale
        local safe=Details.Site(L,s,offset,radius*2,radius*2)~=nil
        if safe and not onRoad and L.WaterDepth(p.x,p.z)==0 then
            Details.Reserve(p,radius)
            local rock=root:CreateChild("既有纹理岩石")
            local y0=math.min(L.TerrainHeight(p.x-radius,p.z),L.TerrainHeight(p.x+radius,p.z),
                L.TerrainHeight(p.x,p.z-radius),L.TerrainHeight(p.x,p.z+radius),y)
            -- 四角最小地形高程决定埋深，防止大石块绕轴旋转后悬空。
            rock.position=V(p.x,y0-height*.32,p.z)
            rock.rotation=Quaternion(0,i*137.5,0)
            local mesh=rock:CreateChild("共享岩石网格")
            mesh:SetScale(scale)
            mesh.position=V(-bounds.center.x,-bounds.min.y,-bounds.center.z)*scale
            local obj=mesh:CreateComponent("StaticModel")
            obj:SetModel(model);obj:SetMaterial(materials[k]);obj.castShadows=false
            obj.drawDistance=L.activeId=="canyon" and 950 or 320
        end
    end
    if L.activeId=="lake" then
        local model=assert(cache:GetResource("Model",HOUSE))
        local bounds=model.boundingBox
        local scale=6/math.max(.01,bounds.size.y)
        local cottage=station(root,L,L.RouteLength*.74,L.Roads[1].shoulder+37,
            bounds.size.x*scale+.8,bounds.size.z*scale+.8)
        if not cottage then return end
        cottage.name="既有资源乡村驿舍"
        local mesh=cottage:CreateChild("共享木框架建筑")
        mesh:SetScale(scale);mesh.position=V(-bounds.center.x,-bounds.min.y,-bounds.center.z)*scale
        local obj=mesh:CreateComponent("StaticModel");obj:SetModel(model)
        for i,path in ipairs(HOUSE_MATS) do
            local mat=assert(cache:GetResource("Material",path))
            obj:SetMaterial(i-1,mat)
        end
        obj.castShadows=false;obj.drawDistance=650
    end
    if L.activeId=="coast" then
        -- 灯塔只落在完整陆地占地上，原来按固定分数外偏会把塔放进海里。
        local s=L.RouteLength*.27
        local offset=-L.Roads[1].shoulder-20
        local p,r,f,low=Details.Site(L,s,offset,8,8)
        if p and r and f and low then
            Details.Reserve(p,6)
            local beacon=root:CreateChild("海岬灯塔")
            beacon.position=p
            local base=L.Geometry(root,"灯塔贴地基础",m.rock)
            box(base,L,V(p.x,low-.25,p.z),r,8,p.y-low+.25,8)
            base:GenerateTangents();base:Commit()
            P.Add(beacon,"灯塔塔身",CylinderGeometry(1.7,2.4,12,16):ToModel(),m.white,V(0,6,0),nil,nil,false)
            P.Add(beacon,"灯塔红色环带",CylinderGeometry(1.86,1.99,1.8,16):ToModel(),m.red,V(0,8.2,0),nil,nil,false)
            P.Add(beacon,"灯室",CylinderGeometry(1.35,1.35,1.8,12):ToModel(),m.glass,V(0,12.7,0),nil,nil,false)
            P.Add(beacon,"灯塔顶",ConeGeometry(2,1.4,16):ToModel(),m.red,V(0,14.2,0),nil,nil,false)
        end
    end
end


---@param root Node
---@param L table
---@param m table
---@param tick fun(stage:string,current:integer,total:integer)
function Decor.Build(root,L,m,tick)
    Details.BeginReservations()
    infrastructure(root,L,m,tick)
    startArea(root,L,m)
    kerbs(root,L,m)
    existingScenery(root,L,m)
    Details.Build(root,L,m,tick)
end

return Decor
