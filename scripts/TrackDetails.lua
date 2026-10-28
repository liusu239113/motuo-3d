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
        g.drawDistance=material=="rock" and 580 or 360
        ctx.batches[key]=g
        ctx.nodes=ctx.nodes+1
    end
    return ctx.batches[key]
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
    local g=batch(ctx,material,s)
    local f=V(-r.z,0,r.x)
    local x,z=r*(width*.5),f*(depth*.5)
    local y=V(0,height,0)
    local a,b,c,d=p-x-z,p-x+z,p+x-z,p+x+z
    local function quad(q,t,u,v) ctx.L.Triangle(g,q,u,t);ctx.L.Triangle(g,u,v,t) end
    quad(a,b,c,d);quad(a+y,c+y,b+y,d+y)
    quad(a,a+y,b,b+y);quad(c,d,c+y,d+y)
    quad(a,c,a+y,c+y);quad(b,b+y,d,d+y)
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
            if onRoad or L.WaterDepth(q.x,q.z)>.01 or (L.activeId=="coast" and q.x<-325 and y<.3) then return nil end
            local terrain=L.TerrainHeight(q.x,q.z)
            low,high=math.min(low,terrain),math.max(high,terrain)
        end
    end
    if high-low>math.max(2.8,math.min(width,depth)*.27) then return nil end
    return V(center.x,high+.1,center.z),r,f,low,high
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

local function shelter(ctx,s,p,r,f,low,kind)
    foundation(ctx,s,p,r,9,12,low)
    box(ctx,"wood",s,p+f*1.5,r,7,3.1,7)
    box(ctx,kind=="rescue" and "red" or "dark",s,p+V(0,3.1,0)+f*1.2,r,8.4,.3,9.5)
    for side=-1,1,2 do
        box(ctx,"glass",s,p+r*(side*2)+f*(-2.03)+V(0,1.3,0),r,1.7,1.2,.05)
        box(ctx,"wood",s,p+r*(side*3.35)-f*4.3,r,.18,3.1,.18)
    end
    box(ctx,"dark",s,p-f*2.04,r,1.15,2.3,.06)
    box(ctx,"white",s,p+f*4.4+V(0,1.6,0),r,5,.55,.08)
    if kind=="rescue" then
        box(ctx,"red",s,p-f*2.1+V(0,2.1,0),r,1.2,.25,.05)
        box(ctx,"red",s,p-f*2.12+V(0,1.63,0),r,.25,1.2,.05)
    end
    for side=-1,1,2 do
        box(ctx,"wood",s,p+r*(side*2.6)-f*4.2+V(0,.45,0),r,2.1,.13,.65)
    end
end

local function viewpoint(ctx,s,p,r,f,low)
    foundation(ctx,s,p,r,11,17,low)
    for _,side in ipairs({-1,1}) do
        for z=-7,7,3.5 do box(ctx,"wood",s,p+r*(side*5.1)+f*z,r,.14,1.1,.14) end
        box(ctx,"wood",s,p+r*(side*5.1)+V(0,.95,0),r,.14,.15,15)
        box(ctx,"wood",s,p+r*(side*3.2)+V(0,.5,0),r,.7,.16,3.5)
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

local function paddock(ctx,s,p,r,f,low)
    foundation(ctx,s,p,r,13,25,low)
    box(ctx,"white",s,p+r*2,r,7,4,21)
    box(ctx,"red",s,p+r*2+V(0,4,0),r,8,.3,22)
    for z=-7,7,7 do
        box(ctx,"dark",s,p-r*1.52+f*z,r,.06,3.1,5.3)
        box(ctx,"yellow",s,p-r*1.56+f*z+V(0,3.35,0),r,.05,.4,2.1)
    end
    for z=-9,9,6 do box(ctx,"yellow",s,p-r*4.5+f*z,r,.35,.7,.35) end
end

local function forestYard(ctx,s,p,r,f,low)
    shelter(ctx,s,p,r,f,low,"forest")
    for row=0,2 do
        for col=0,3 do
            box(ctx,"wood",s,p+r*(5.5+row*.5)+f*(col*1.25-3),r,.5,.4,1.05)
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
    coast={{.16,-1,"view"},{.26,-1,"view"},{.38,-1,"shelter"},{.49,1,"view"},{.67,1,"shelter"},{.84,1,"shelter"}},
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
