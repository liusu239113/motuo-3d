-- 沿线主题细节按里程分块、按材质合批；不增加车辆碰撞体或逐帧更新。
local Details = {}
local V=Vector3

---@class DetailContext
---@field root Node
---@field L table
---@field m table<string,Material>
---@field batches table<string,CustomGeometry>
---@field placed integer
---@field rejected integer
---@field boxes integer
---@field nodes integer
---@field occupied table[]
---@field triangles integer
---@field byMaterial table<string,integer>
---@field perChunk table<number,integer>
---@field budgetSkipped integer
---@field plants integer
---@field rocks integer
---@field logs integer
---@field shoreSites integer

-- 手写顶点仅用于多形状静态合批：不为每块石/每片草建立Model、Node或临时几何。
-- 192m一块，非索引顶点上限9600/块；全图最多90000三角形（含双面叶）。
local TRI_LIMIT, CHUNK_LIMIT = 90000, 3200

local function noise(a,b)
    local n=math.sin(a*127.1+b*311.7)*43758.5453
    return n-math.floor(n)
end

local function basis(yaw)
    local angle=math.rad(yaw)
    return V(math.cos(angle),0,-math.sin(angle)),V(math.sin(angle),0,math.cos(angle))
end

---@param ctx DetailContext
---@param material string
---@param s number
---@return CustomGeometry
local function batch(ctx,material,s)
    local key=math.floor(s/192)..":"..material
    if not ctx.batches[key] then
        local g=ctx.L.Geometry(ctx.root,"沿线合批_"..key,assert(ctx.m[material]))
        g.drawDistance=material=="rock" and 480 or (material=="green" and 185 or 330)
        g.castShadows=false
        g.shadowDistance=0
        ctx.batches[key]=g
        ctx.nodes=ctx.nodes+1
    end
    return ctx.batches[key]
end

---@param ctx DetailContext
---@param s number
---@param count integer
local function room(ctx,s,count)
    local chunk=math.floor(s/192)
    if ctx.triangles+count>TRI_LIMIT or (ctx.perChunk[chunk] or 0)+count>CHUNK_LIMIT then
        ctx.budgetSkipped=ctx.budgetSkipped+1
        return false
    end
    return true
end

-- 同一面共享切平面投影；不再用XZ投影竖壁（旧路径UV退化、法线贴图发黑）。
---@param ctx DetailContext
---@param material string
---@param s number
---@param a Vector3
---@param b Vector3
---@param c Vector3
---@param ua? Vector2
---@param ub? Vector2
---@param uc? Vector2
local function triangle(ctx,material,s,a,b,c,ua,ub,uc)
    local cross=(b-a):CrossProduct(c-a)
    if cross:LengthSquared()<1e-12 then return end
    local n=cross:Normalized()
    local ax,ay,az=math.abs(n.x),math.abs(n.y),math.abs(n.z)
    local function uv(p)
        if ay>=ax and ay>=az then return Vector2(p.x/2,p.z/2) end
        if ax>=az then return Vector2(p.z/2,p.y/2) end
        return Vector2(p.x/2,p.y/2)
    end
    local g=batch(ctx,material,s)
    ctx.L.Vertex(g,a,n,ua or uv(a));ctx.L.Vertex(g,b,n,ub or uv(b));ctx.L.Vertex(g,c,n,uc or uv(c))
    local chunk=math.floor(s/192)
    ctx.triangles=ctx.triangles+1
    ctx.perChunk[chunk]=(ctx.perChunk[chunk] or 0)+1
    ctx.byMaterial[material]=(ctx.byMaterial[material] or 0)+1
end

---@param ctx DetailContext
---@param material string
---@param s number
---@param a Vector3
---@param b Vector3
---@param c Vector3
---@param d Vector3
local function face(ctx,material,s,a,b,c,d)
    -- 连续局部UV避免非共面薄片两半使用不同的主轴。
    local u=(b-a):Length()/2
    local v=(c-a):Length()/2
    triangle(ctx,material,s,a,b,c,Vector2(0,0),Vector2(u,0),Vector2(0,v))
    triangle(ctx,material,s,c,b,d,Vector2(0,v),Vector2(u,0),Vector2(u,v))
end

---@param ctx DetailContext
---@param material string
---@param s number
---@param a Vector3
---@param b Vector3
---@param radius number
---@param topRadius? number
---@param segments? integer
local function cylinder(ctx,material,s,a,b,radius,topRadius,segments)
    local n=segments or 7
    if not room(ctx,s,n*4) then return end
    local axis=(b-a):Normalized()
    local ref=math.abs(axis.y)>.9 and V(1,0,0) or V(0,1,0)
    local r=axis:CrossProduct(ref):Normalized()
    local f=r:CrossProduct(axis)
    for i=0,n-1 do
        local t0,t1=i/n*math.pi*2,(i+1)/n*math.pi*2
        local u=r*math.cos(t0)+f*math.sin(t0)
        local v=r*math.cos(t1)+f*math.sin(t1)
        local p,q=a+u*radius,a+v*radius
        local j,k=b+u*(topRadius or radius),b+v*(topRadius or radius)
        -- 绕轴外向，树皮U沿圆周/V沿长轴，端面使用平面投影。
        local len=(b-a):Length()/2
        local u0,u1=i/n*radius*math.pi,(i+1)/n*radius*math.pi
        triangle(ctx,material,s,p,j,q,Vector2(u0,0),Vector2(u0,len),Vector2(u1,0))
        triangle(ctx,material,s,q,j,k,Vector2(u1,0),Vector2(u0,len),Vector2(u1,len))
        triangle(ctx,material,s,a,p,q)
        triangle(ctx,material,s,b,k,j)
    end
end

---@param ctx DetailContext
---@param material string
---@param s number
---@param p Vector3
---@param r Vector3
---@param width number
---@param height number
---@param depth number
local function box(ctx,material,s,p,r,width,height,depth)
    if not room(ctx,s,12) then return end
    local f=V(-r.z,0,r.x)
    local x,z=r*(width*.5),f*(depth*.5)
    local y=V(0,height,0)
    local a,b,c,d=p-x-z,p-x+z,p+x-z,p+x+z
    face(ctx,material,s,a,c,b,d);face(ctx,material,s,a+y,b+y,c+y,d+y)
    face(ctx,material,s,a,a+y,b,b+y);face(ctx,material,s,c,d,c+y,d+y)
    face(ctx,material,s,a,c,a+y,c+y);face(ctx,material,s,b,b+y,d,d+y)
    ctx.boxes=ctx.boxes+1
end

-- 占地示意：路肩外缘 | 至少3米净空 | 旋转后的完整矩形占地。
-- 目的：每个占地九点都必须在干地、路外；再检查包围圆，防止跨到另一段赛道。
-- 边界：海边低于海平面、折返夹缝、地形高差过大或与已有设施相叠均舍弃。
---@param L table
---@param s number
---@param offset number
---@param width number
---@param depth number
---@return Vector3?, Vector3?, Vector3?, number?, number?
function Details.Site(L,s,offset,width,depth)
    local p,yaw=L.RoadPoint(s)
    local r,f=basis(yaw)
    local center=p+r*offset
    local radius=math.sqrt(width*width+depth*depth)*.5
    local ns=L.NearestRoad(center.x,center.z)
    local nearest=L.RoadPoint(ns)
    local distance=math.sqrt((center.x-nearest.x)^2+(center.z-nearest.z)^2)
    if distance<L.Roads[1].shoulder+radius+3 then return nil end
    local low,high=math.huge,-math.huge
    for ix=-1,1 do
        for iz=-1,1 do
            local q=center+r*(ix*width*.5)+f*(iz*depth*.5)
            local y,onRoad=L.Height(q.x,q.z)
            if onRoad or L.WaterDepth(q.x,q.z)>.01 then return nil end
            -- Height的第二返回只表示沥青，不包括碎石路肩/支路肩。
            if L.RoadHeight and L.RoadHeight(q.x,q.z)~=nil then return nil end
            if L.RampAt and L.RampAt(q.x,q.z) then return nil end
            local terrain=L.TerrainHeight(q.x,q.z)
            if L.activeId=="coast" and terrain<(L.WaterLevel or 0)+.3 then return nil end
            for _,bay in ipairs(L.Laybys or {}) do
                if (q.x-bay.x)^2+(q.z-bay.z)^2<22^2 then return nil end
            end
            low,high=math.min(low,terrain),math.max(high,terrain)
        end
    end
    if high-low>math.max(2.8,math.min(width,depth)*.27) then return nil end
    return V(center.x,high+.1,center.z),r,f,low,high
end

-- 预留由Decor已放置的设施/既有模型，构建结束清空，不跨图残留。
local reservations={}
function Details.BeginReservations() reservations={} end
---@param p Vector3
---@param radius number
function Details.Reserve(p,radius)
    reservations[#reservations+1]={x=p.x,z=p.z,radius=radius}
end

---@param ctx DetailContext
---@param p Vector3
---@param radius number
local function clearOfFacilities(ctx,p,radius)
    for _,other in ipairs(ctx.occupied) do
        if (p.x-other.x)^2+(p.z-other.z)^2<(radius+other.radius+1.5)^2 then return false end
    end
    return true
end

---@param ctx DetailContext
---@param s number
---@param side number
---@param width number
---@param depth number
local function site(ctx,s,side,width,depth)
    for _,extra in ipairs({0,8,18}) do
        local p,r,f,low=Details.Site(ctx.L,s,side*(ctx.L.Roads[1].shoulder+math.sqrt(width*width+depth*depth)*.5+6+extra),width,depth)
        if p and r and f and low then
            local radius=math.sqrt(width*width+depth*depth)*.5
            local clear=true
            for _,other in ipairs(ctx.occupied) do
                if (p.x-other.x)^2+(p.z-other.z)^2<(radius+other.radius+4)^2 then clear=false;break end
            end
            if clear then
                ctx.occupied[#ctx.occupied+1]={x=p.x,z=p.z,radius=radius}
                ctx.placed=ctx.placed+1
                return p,r,f,low
            end
        end
    end
    ctx.rejected=ctx.rejected+1
    return nil
end

-- 岩层：地表下埋裙边 -> 不规则宽肩 -> 偏移窄顶。每块42tri，没有方盒假石。
-- 每个底环点独立采TerrainHeight，坡面不悬空；层理UV沿真实面投影。
---@param ctx DetailContext
---@param s number
---@param p Vector3
---@param r Vector3
---@param width number
---@param height number
---@param depth number
---@param seed number
---@param material? string
local function stone(ctx,s,p,r,width,height,depth,seed,material)
    if not room(ctx,s,42) then return end
    local f=V(-r.z,0,r.x)
    local rings={}
    for tier=1,3 do
        local ring={}
        for i=1,7 do
            local angle=(i-1)/7*math.pi*2
            local jitter=.77+noise(seed+i,3)*.3
            local taper=tier==1 and 1 or (tier==2 and .89 or .52)
            local shift=tier==3 and .16 or 0
            local q=p+r*((math.cos(angle)*jitter*taper+shift)*width*.5)
                +f*(math.sin(angle)*jitter*taper*depth*.5)
            local ground=ctx.L.TerrainHeight(q.x,q.z)
            local y=tier==1 and ground-.2 or p.y+height*(tier==2 and .38 or (.84+noise(seed+i,5)*.16))
            ring[i]=V(q.x,y,q.z)
        end
        rings[tier]=ring
    end
    local mat=material or "rock"
    for tier=1,2 do
        for i=1,7 do
            local j=i%7+1
            face(ctx,mat,s,rings[tier][i],rings[tier+1][i],rings[tier][j],rings[tier+1][j])
        end
    end
    local top=p+r*(width*.07)+V(0,height*.94,0)
    local bottom=V(p.x,ctx.L.TerrainHeight(p.x,p.z)-.22,p.z)
    for i=1,7 do
        local j=i%7+1
        triangle(ctx,mat,s,top,rings[3][j],rings[3][i])
        triangle(ctx,mat,s,bottom,rings[1][i],rings[1][j])
    end
    ctx.rocks=ctx.rocks+1
end

-- 有限顶点的弯曲尖叶，双面显式反法线，不改共享材质cullMode。
---@param ctx DetailContext
---@param s number
---@param base Vector3
---@param direction Vector3
---@param height number
---@param width number
local function blade(ctx,s,base,direction,height,width)
    local right=V(-direction.z,0,direction.x)*width
    local bend=base+direction*(height*.27)+V(0,height*.58,0)
    local tip=base+direction*(height*.7)+V(0,height,0)
    local a,b=base-right,base+right
    local c,d=bend-right*.62,bend+right*.62
    face(ctx,"green",s,a,c,b,d);face(ctx,"green",s,b,d,a,c)
    triangle(ctx,"green",s,c,tip,d);triangle(ctx,"green",s,d,tip,c)
end

---@param ctx DetailContext
---@param s number
---@param p Vector3
---@param seed number
---@param fern boolean
local function plant(ctx,s,p,seed,fern)
    -- 蕨5枚弓形羽叶×3对小羽片；草/低灌丛5片折叶，不用矩形牌或矩形灌木。
    local cost=fern and 90 or 30
    if not room(ctx,s,cost) then return end
    for k=1,5 do
        local angle=k*2.39996+noise(seed,7)*math.pi*2
        local dir=V(math.cos(angle),0,math.sin(angle))
        local height=(fern and .55 or .28)+noise(seed+k,9)*(fern and .35 or .45)
        if not fern then
            blade(ctx,s,p,dir,height,.045+noise(seed+k,8)*.035)
        else
            local across=V(-dir.z,0,dir.x)
            for segment=1,3 do
                local t=segment/4
                local center=p+dir*(t*.85)+V(0,math.sin(t*math.pi*.85)*height,0)
                local reach=(1-t)*.33
                for side=-1,1,2 do
                    local tip=center+across*(side*reach)+dir*.16+V(0,-.025,0)
                    local a,b=center-dir*.055,center+dir*.075
                    triangle(ctx,"green",s,a,tip,b);triangle(ctx,"green",s,b,tip,a)
                end
            end
            blade(ctx,s,p,dir,height,.018)
        end
    end
    ctx.plants=ctx.plants+1
end

---@param ctx DetailContext
---@param s number
---@param p Vector3
---@param r Vector3
---@param f Vector3
---@param width number
---@param depth number
---@param rise number
---@param material string
local function roof(ctx,s,p,r,f,width,depth,rise,material)
    if not room(ctx,s,102) then return end
    local a,b=p-r*(width*.5)-f*(depth*.5),p+r*(width*.5)-f*(depth*.5)
    local c,d=a+f*depth,b+f*depth
    local front,back=p-f*(depth*.5)+V(0,rise,0),p+f*(depth*.5)+V(0,rise,0)
    face(ctx,material,s,a,c,front,back);face(ctx,material,s,front,back,b,d)
    triangle(ctx,"wood",s,a,front,b);triangle(ctx,"wood",s,c,d,back)
    cylinder(ctx,"wood",s,a,b,.09,.09,6);cylinder(ctx,"wood",s,c,d,.09,.09,6)
    cylinder(ctx,"wood",s,a,c,.08,.08,6);cylinder(ctx,"wood",s,b,d,.08,.08,6)
end

---@param ctx DetailContext
---@param s number
---@param p Vector3
---@param r Vector3
---@param width number
---@param depth number
---@param low number
local function foundation(ctx,s,p,r,width,depth,low)
    box(ctx,"rock",s,V(p.x,low-.25,p.z),r,width,p.y-low+.25,depth)
end

---@param ctx DetailContext
---@param s number
---@param p Vector3
---@param r Vector3
---@param f Vector3
---@param low number
---@param kind string
local function shelter(ctx,s,p,r,f,low,kind)
    foundation(ctx,s,p,r,9,12,low)
    box(ctx,"wood",s,p+f*1.5,r,7,3.1,7)
    roof(ctx,s,p+V(0,3.1,0)+f*1.2,r,f,8.4,9.5,1.45,kind=="rescue" and "red" or "dark")
    for side=-1,1,2 do
        box(ctx,"glass",s,p+r*(side*2)+f*(-2.03)+V(0,1.3,0),r,1.7,1.2,.05)
        cylinder(ctx,"wood",s,p+r*(side*3.35)-f*4.3,p+r*(side*3.35)-f*4.3+V(0,3.1,0),.1,.085,7)
    end
    box(ctx,"dark",s,p-f*2.04,r,1.15,2.3,.06)
    box(ctx,"white",s,p+f*4.4+V(0,1.6,0),r,5,.55,.08)
    if kind=="rescue" then
        box(ctx,"red",s,p-f*2.1+V(0,2.1,0),r,1.2,.25,.05)
        box(ctx,"red",s,p-f*2.12+V(0,1.63,0),r,.25,1.2,.05)
    end
    for side=-1,1,2 do
        local seat=p+r*(side*2.6)-f*4.2
        box(ctx,"wood",s,seat+V(0,.45,0),r,2.1,.13,.65)
        for leg=-1,1,2 do box(ctx,"wood",s,seat+r*(leg*.8),r,.13,.45,.45) end
    end
end

---@param ctx DetailContext
---@param s number
---@param p Vector3
---@param r Vector3
---@param f Vector3
---@param low number
local function viewpoint(ctx,s,p,r,f,low)
    foundation(ctx,s,p,r,11,17,low)
    for _,side in ipairs({-1,1}) do
        for z=-7,7,3.5 do box(ctx,"wood",s,p+r*(side*5.1)+f*z,r,.14,1.1,.14) end
        box(ctx,"wood",s,p+r*(side*5.1)+V(0,.95,0),r,.14,.15,15)
        local seat=p+r*(side*3.2)
        box(ctx,"wood",s,seat+V(0,.5,0),r,.7,.16,3.5)
        for leg=-1,1,2 do box(ctx,"wood",s,seat+f*(leg*1.25),r,.55,.5,.15) end
    end
    for x=-4,4,4 do box(ctx,"wood",s,p+r*x+f*7.5,r,.14,1.1,.14) end
    box(ctx,"wood",s,p+f*7.5+V(0,.95,0),r,10.4,.15,.14)
    box(ctx,"green",s,p-f*5+V(0,1.05,0),r,2,.7,.12)
    box(ctx,"wood",s,p-f*5,r,.13,1.4,.14)
end

---@param ctx DetailContext
---@param s number
---@param p Vector3
---@param r Vector3
---@param f Vector3
---@param low number
local function stand(ctx,s,p,r,f,low)
    foundation(ctx,s,p,r,14,38,low)
    for row=0,4 do
        local q=p+r*(row*2-4)
        box(ctx,"rock",s,q,r,2,row*.75+.4,34)
        box(ctx,row%2==0 and "red" or "white",s,q+V(0,row*.75+.45,0),r,1.2,.28,32)
    end
    for _,z in ipairs({-16,0,16}) do box(ctx,"rail",s,p+r*5.5+f*z,r,.18,6,.18) end
    box(ctx,"rail",s,p+V(0,6,0),r,14.5,.2,38)
    box(ctx,"white",s,p-r*6.9+V(0,1.6,0),r,.12,.9,30)
end

---@param ctx DetailContext
---@param s number
---@param p Vector3
---@param r Vector3
---@param f Vector3
---@param low number
local function paddock(ctx,s,p,r,f,low)
    foundation(ctx,s,p,r,13,25,low)
    box(ctx,"white",s,p+r*2,r,7,4,21)
    roof(ctx,s,p+r*2+V(0,4,0),r,f,8,22,1.2,"red")
    for z=-7,7,7 do
        box(ctx,"dark",s,p-r*1.52+f*z,r,.06,3.1,5.3)
        box(ctx,"yellow",s,p-r*1.56+f*z+V(0,3.35,0),r,.05,.4,2.1)
    end
    for z=-9,9,6 do box(ctx,"yellow",s,p-r*4.5+f*z,r,.35,.7,.35) end
end

---@param ctx DetailContext
---@param s number
---@param p Vector3
---@param r Vector3
---@param f Vector3
---@param low number
local function forestYard(ctx,s,p,r,f,low)
    shelter(ctx,s,p,r,f,low,"forest")
    for row=0,2 do
        for col=0,3 do
            local q=p+r*(5.5+row*.5)+f*(col*1.25-3)
            local ground=ctx.L.TerrainHeight(q.x,q.z)
            local a=V(q.x,ground+.23,q.z)-f*.53
            cylinder(ctx,"wood",s,a,a+f*1.06,.24,.20,8)
            ctx.logs=ctx.logs+1
        end
    end
end

local function landmark(ctx,s,side,kind)
    local w,d=11,17
    if kind=="stand" then w,d=14,38
    elseif kind=="paddock" then w,d=13,25
    elseif kind=="forest" then w,d=16,14
    elseif kind=="rescue" or kind=="shelter" then w,d=9,12 end
    local p,r,f,low=site(ctx,s,side,w,d)
    if not p then return end
    if kind=="stand" then stand(ctx,s,p,r,f,low)
    elseif kind=="paddock" then paddock(ctx,s,p,r,f,low)
    elseif kind=="view" then viewpoint(ctx,s,p,r,f,low)
    elseif kind=="forest" then forestYard(ctx,s,p,r,f,low)
    else shelter(ctx,s,p,r,f,low,kind) end
end

-- 低矮灌丛、蕨叶及石堆不用额外高模树；每块仅两个共享材质几何。
local function roadside(ctx,s,index)
    local theme=ctx.L.activeId
    local side=index%2==0 and 1 or -1
    local p,r,f=Details.Site(ctx.L,s,side*(ctx.L.Roads[1].shoulder+7+(index%3)*3),4.5,5)
    if not p or not r or not f then return end
    if theme=="forest" or theme=="coast" then
        for k=1,3 do
            local q=p+r*(k-2)*1.05+f*((k%2)*1.4-.7)
            local y=ctx.L.TerrainHeight(q.x,q.z)
            local h=.35+(index+k)%4*.17
            box(ctx,"green",s,V(q.x,y-.08,q.z),r,.65,h,1.05)
            if theme=="forest" then
                local g=batch(ctx,"green",s)
                local base=V(q.x,y+.1,q.z)
                for leaf=-1,1,2 do
                    local a,b,c=base,base+r*(leaf*.65)+V(0,.32,0),base+f*.45+V(0,.23,0)
                    ctx.L.Triangle(g,a,b,c);ctx.L.Triangle(g,c,b,a)
                end
            end
        end
    elseif theme=="alpine" or theme=="canyon" then
        for k=1,3 do
            local q=p+f*(k-2)*1.45+r*((k%2)*.6)
            local y=ctx.L.TerrainHeight(q.x,q.z)
            box(ctx,"rock",s,V(q.x,y-.25,q.z),r,1.2+k*.2,.6+(index+k)%3*.35,1.3)
        end
        if theme=="canyon" and index%3==0 then
            box(ctx,"wood",s,p,r,.2,1.9,.2)
            box(ctx,"green",s,p+V(0,.6,0),r,.85,.18,.2)
        end
    end
end

local function marker(ctx,s,side,sector)
    local p,r,f=Details.Site(ctx.L,s,side*(ctx.L.Roads[1].shoulder+8),3,2)
    if not p or not r or not f then return end
    for leg=-1,1,2 do
        local q=p+r*(leg*.9)
        local y=ctx.L.TerrainHeight(q.x,q.z)
        box(ctx,"rail",s,V(q.x,y-.12,q.z),r,.1,p.y-y+2.6,.1)
    end
    box(ctx,"dark",s,p+V(0,1.5,0),r,2.7,1,.16)
    for stripe=1,sector do
        box(ctx,"white",s,p+r*((stripe-(sector+1)*.5)*.48)-f*.09+V(0,1.72,0),r,.22,.55,.03)
    end
end

local function walls(ctx)
    local theme=ctx.L.activeId
    if theme~="alpine" and theme~="canyon" then return end
    local count=theme=="alpine" and 16 or 24
    for k=1,count do
        local s=ctx.L.RouteLength*(k-.35)/count
        local side=k%2==0 and 1 or -1
        local width,depth=theme=="canyon" and 11 or 6,theme=="canyon" and 24 or 17
        local p,r,f,low=site(ctx,s,side,width,depth)
        if p and r and f and low then
            local h=theme=="canyon" and (7+k%4*2.5) or (3.5+k%3*1.2)
            for tier=0,2 do
                box(ctx,"rock",s,V(p.x,low-.3+tier*h*.3,p.z)+r*(side*tier*.35),r,
                    width*(1-tier*.18),h*(1-tier*.2),depth*(1-tier*.1))
            end
        end
    end
end

local plans={
    alpine={{.11,-1,"shelter"},{.27,1,"view"},{.43,-1,"view"},{.52,1,"rescue"},{.68,1,"view"},{.88,-1,"shelter"}},
    coast={{.12,1,"shelter"},{.26,-1,"view"},{.38,-1,"shelter"},{.49,1,"view"},{.67,1,"shelter"},{.84,1,"shelter"}},
    canyon={{.09,1,"shelter"},{.25,-1,"view"},{.43,1,"shelter"},{.58,-1,"view"},{.76,1,"shelter"},{.9,-1,"view"}},
    forest={{.12,-1,"forest"},{.29,1,"shelter"},{.44,-1,"forest"},{.6,1,"view"},{.75,1,"forest"},{.9,-1,"shelter"}},
    circuit={{.04,-1,"stand"},{.12,1,"paddock"},{.28,-1,"stand"},{.45,1,"paddock"},{.64,-1,"stand"},{.83,1,"paddock"}},
}

---@param root Node
---@param L table
---@param m table<string,Material>
---@param tick fun(stage:string,current:integer,total:integer)
function Details.Build(root,L,m,tick)
    if L.activeId=="lake" then return end
    ---@type DetailContext
    local ctx={root=root,L=L,m=m,batches={},placed=0,rejected=0,boxes=0,nodes=0,occupied={}}
    local chunks=math.ceil(L.RouteLength/144)
    for _,plan in ipairs(plans[L.activeId] or {}) do landmark(ctx,L.RouteLength*plan[1],plan[2],plan[3]) end
    for k=1,12 do marker(ctx,L.RouteLength*(k-.25)/12,k%2==0 and 1 or -1,(k-1)%3+1) end
    walls(ctx)
    local step=L.activeId=="circuit" and 75 or 34
    for k=1,math.floor(L.RouteLength/step) do
        roadside(ctx,k*step,k)
        if k%12==0 then tick("赛事环境",math.min(chunks,math.floor(k*step/144)),chunks) end
    end
    for _,g in pairs(ctx.batches) do g:GenerateTangents();g:Commit() end
    print(string.format("[沿线细节] %s %d处设施与岩壁 / %d处避让 / %d合批节点 / %d基础体；无逐帧遍历",
        L.activeId,ctx.placed,ctx.rejected,ctx.nodes,ctx.boxes))
    Details.LastBuild={id=L.activeId,placed=ctx.placed,rejected=ctx.rejected,nodes=ctx.nodes,boxes=ctx.boxes}
end

return Details
