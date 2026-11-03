-- 基于三维场景脚手架：绝对世界坐标、分阶段构建，世界不随玩家移动。
local P = require("Parts")
local Landscape = require("Landscape")
local Assets = require("VehicleAssets")
local Decor = require("TrackDecor")
local TrackFeatures = require("TrackFeatures")
local V = Vector3

---@class ScenicTraffic
---@field node Node
---@field x number
---@field y number
---@field z number
---@field yaw number
---@field previousX number
---@field previousY number
---@field previousZ number
---@field speed number
---@field s number
---@field lane number
---@field halfLength number
---@field halfWidth number
---@field width number
---@field height number
---@field passed boolean
---@field previousRel number
---@field models StaticModel[]

---@class World
---@field scene Scene
---@field root Node
---@field traffic ScenicTraffic[]
local World = {}
World.__index = World
World.Resources, World.ResourceTypes = {}, {}
for _, path in ipairs(Landscape.Resources) do
    World.Resources[#World.Resources + 1] = path
    World.ResourceTypes[path] = Landscape.ResourceTypes[path]
end
for _,path in ipairs(Decor.Resources) do
    World.Resources[#World.Resources+1]=path
    World.ResourceTypes[path]=Decor.ResourceTypes[path]
end
for _, path in ipairs(Assets.ResourcesFor(Assets.TrafficIds)) do
    World.Resources[#World.Resources + 1] = path
    World.ResourceTypes[path] = Assets.ResourceTypes[path]
end
for _, shape in ipairs({"Box", "Cylinder", "Sphere"}) do
    local path = "Models/" .. shape .. ".mdl"
    World.Resources[#World.Resources + 1] = path
    World.ResourceTypes[path] = "Model"
end
World.BuildStages = {}
World.BuildTaskCount = 0
for _, stage in ipairs(Landscape.BuildStages) do World.BuildStages[#World.BuildStages + 1] = stage end
for _, stage in ipairs({{name = "桥梁与驿站", total = 6}, {name = "精细交通", total = 14},
    {name="赛事环境",total=math.ceil(Landscape.RouteLength/144)}}) do
    World.BuildStages[#World.BuildStages + 1] = stage
end
for _, stage in ipairs(World.BuildStages) do World.BuildTaskCount = World.BuildTaskCount + stage.total end

function World.GetBuildStages()
    World.BuildStages[#World.BuildStages].total=math.ceil(Landscape.RouteLength/144)
    World.BuildTaskCount=0
    for _,stage in ipairs(World.BuildStages) do World.BuildTaskCount=World.BuildTaskCount+stage.total end
    return World.BuildStages
end

---@param scene Scene
---@param onProgress? fun(stage:string,current:integer,total:integer)
---@return World
function World.New(scene, onProgress)
    local self = setmetatable({}, World)
    self:Init(scene, onProgress)
    return self
end

---@param s number
---@return number
function World.Center(s)
    local p = Landscape.RoadPoint(s)
    return p.x
end
---@param s number
---@return number
function World.Heading(s)
    local _, yaw = Landscape.RoadPoint(s)
    return yaw
end

---@param scene Scene
---@param onProgress? fun(stage:string,current:integer,total:integer)
function World:Init(scene, onProgress)
    World.GetBuildStages()
    self.scene = scene
    self.trackId=Landscape.activeId
    self.root = scene:CreateChild(Landscape.Track.name.."比赛世界")
    self.landscape = Landscape
    self.Goals, self.Regions = Landscape.Goals, Landscape.Regions
    self.ramps = Landscape.Ramps
    self.features = Landscape.Features
    self.traffic = {}
    self.clock, self.visibilityTimer = 0, 0
    self.mats = Landscape.CreateMaterials()
    local m = self.mats
    m.white = m.white or P.Material(0.86, 0.87, 0.78, 0.92)
    m.yellow = m.yellow or P.Material(0.91, 0.66, 0.17, 0.86)
    m.rail = m.rail or P.Material(0.53, 0.58, 0.59, 0.66, 0.65)
    m.dark = m.dark or P.Material(0.035, 0.045, 0.052, 0.94)
    m.glass = P.Material(0.075, 0.15, 0.19, 0.32, 0.1)
    m.red = m.red or P.Material(0.53, 0.13, 0.065, 0.90)
    m.wood = m.wood or P.Material(0.29, 0.21, 0.13, 0.94)
    m.green = m.green or P.Material(0.055, 0.23, 0.14, 0.96)
    m.lamp = P.Material(0.95, 0.88, 0.61, 0.27, 0, 0.35)
    m.brake = P.Material(0.85, 0.035, 0.015, 0.3, 0, 0.3)
    -- 机关专用哑光PBR配色，不改已验收的场景材质，不增加外部资产。
    m.boostBand = P.Material(0.015, 0.52, 0.57, 0.85, 0)
    m.boostArrow = P.Material(0.88, 1.0, 0.96, 0.82, 0)
    m.rampDeck = P.Material(0.28, 0.31, 0.34, 0.88, 0.12)
    m.rampYellow = P.Material(1.0, 0.76, 0.035, 0.90, 0, 0.08)
    m.rampBlack = P.Material(0.018, 0.022, 0.026, 0.96, 0)
    local function tick(stage, current, total)
        if onProgress then onProgress(stage, current, total) end
    end
    Landscape.Build(scene, self.root, m, m.white, m.yellow, tick)
    self:BuildBridge(); tick("桥梁与驿站", 1, 6)
    for i = 1, #self.ramps do self:BuildRamp(i) end
    tick("桥梁与驿站", 2, 6)
    self:BuildBoostBands(); tick("桥梁与驿站", 3, 6)
    self:BuildStations(); tick("桥梁与驿站", 4, 6)
    self:BuildRoadFurniture(); tick("桥梁与驿站", 5, 6)
    self:BuildMeadow(); tick("桥梁与驿站", 6, 6)
    Decor.Build(self.root,Landscape,m,tick)
    self:CreateTraffic(tick)
    require("MixedCourse").Build(self)
    self:SetQuality(false)
    self:ResetTraffic(0)
    print(string.format("[场景] 静态主线%.0f米，%d个导航目标，%d个跳台，%d辆交通车", Landscape.RouteLength, #self.Goals, #self.ramps, #self.traffic))
end

---@param x number
---@param z number
---@return number, boolean, string
function World:Surface(x, z)
    local y, road = Landscape.Height(x, z)
    return y, road, Landscape.RegionAt(x, z)
end

---@param x number
---@param z number
---@return table?
function World:RampAt(x, z) return Landscape.RampAt(x, z) end

-- 桥梁顶面直接使用主路的曲面；桥面高程没有额外偏移，因此仿真和画面完全一致。
function World:BuildBridge()
    if Landscape.activeId~="lake" then return end
    local m = self.mats
    local bridge = Landscape.Bridge
    local railOffset = Landscape.Roads[1].shoulder + 1.1
    local root = self.root:CreateChild("白水河谷曲线高架桥")
    local rail = Landscape.Geometry(root, "连续桥梁栏杆", m.rail)
    local deck = Landscape.Geometry(root, "桥梁侧腹梁", m.rock)
    for s = bridge.startS, bridge.endS - 2, 2 do
        local a, yawA = Landscape.RoadPoint(s)
        local b, yawB = Landscape.RoadPoint(s + 2)
        local ra, rb = math.rad(yawA), math.rad(yawB)
        for side = -1, 1, 2 do
            local pa = a + V(math.cos(ra), 0, -math.sin(ra)) * (side * railOffset)
            local pb = b + V(math.cos(rb), 0, -math.sin(rb)) * (side * railOffset)
            for _, y in ipairs({0.56, 1.02}) do
                Landscape.Triangle(rail, pa + V(0, y, 0), pb + V(0, y, 0), pa + V(0, y + 0.13, 0))
                Landscape.Triangle(rail, pa + V(0, y + 0.13, 0), pb + V(0, y, 0), pb + V(0, y + 0.13, 0))
                Landscape.Triangle(rail, pa + V(0, y + 0.13, 0), pb + V(0, y, 0), pa + V(0, y, 0))
                Landscape.Triangle(rail, pb + V(0, y + 0.13, 0), pb + V(0, y, 0), pa + V(0, y + 0.13, 0))
            end
            Landscape.Triangle(deck, pa, pa - V(0, 1.05, 0), pb)
            Landscape.Triangle(deck, pb, pa - V(0, 1.05, 0), pb - V(0, 1.05, 0))
            Landscape.Triangle(deck, pb, pa - V(0, 1.05, 0), pa)
            Landscape.Triangle(deck, pb - V(0, 1.05, 0), pa - V(0, 1.05, 0), pb)
        end
    end
    rail:Commit(); deck:GenerateTangents(); deck:Commit()
    for s = bridge.startS + 5, bridge.endS - 4, 10 do
        local p, yaw = Landscape.RoadPoint(s)
        local a = math.rad(yaw)
        for side = -1, 1, 2 do
            local q = p + V(math.cos(a), 0, -math.sin(a)) * (side * railOffset)
            P.Add(root, "桥栏立柱", "Box", m.rail, q + V(0, 0.56, 0), V(0.12, 1.12, 0.16), Quaternion(0, yaw, 0), false)
        end
    end
    for s = bridge.startS + 18, bridge.endS - 12, 28 do
        local p, yaw = Landscape.RoadPoint(s)
        local ground = Landscape.TerrainHeight(p.x, p.z)
        local height = math.max(2, p.y - ground - 0.3)
        P.Add(root, "河谷桥墩", "Box", m.rock, V(p.x, p.y - height * 0.5 - 0.3, p.z), V(2.2, height, 3.2), Quaternion(0, yaw, 0), false)
        P.Add(root, "桥墩盖梁", "Box", m.rock, p - V(0, 0.48, 0), V(railOffset * 2, 0.7, 2.2), Quaternion(0, yaw, 0), false)
    end
end

---@param index integer
function World:BuildRamp(index)
    local r = self.ramps[index] --[[@as table]]
    if not r then return end
    local m = self.mats
    if r.optional then self:BuildOptionalRamp(r --[[@as TrackFeature]]); return end
    local root = self.root:CreateChild(index == 1 and "路肩坡道运输车" or "草甸飞跃台")
    root.position = V(r.x, r.y, r.z)
    root.rotation = Quaternion(0, r.yaw, 0)
    -- 侧视示意：入口(0,0)________/ 末端(length,height)。可骑顶面无缝从地面起坡。
    -- 运输车的车身与驾驶室在末端以后，宽度2.8米，完全位于路肩，不堵主路。
    local h, w, length = r.height, r.width * 0.5, r.length
    local g = Landscape.Geometry(root, "真实可骑楔形", index == 1 and m.rail or m.wood)
    Landscape.Triangle(g, V(-w, 0, 0), V(-w, h, length), V(w, 0, 0))
    Landscape.Triangle(g, V(w, 0, 0), V(-w, h, length), V(w, h, length))
    Landscape.Triangle(g, V(-w, 0, 0), V(-w, 0, length), V(-w, h, length))
    Landscape.Triangle(g, V(w, 0, 0), V(w, h, length), V(w, 0, length))
    Landscape.Triangle(g, V(-w, h, length), V(-w, 0, length), V(w, h, length))
    Landscape.Triangle(g, V(w, h, length), V(-w, 0, length), V(w, 0, length))
    g:GenerateTangents(); g:Commit()
    for side = -1, 1, 2 do
        P.Bar(root, m.yellow, V(side * (w - 0.04), 0.03, 0), V(side * (w - 0.04), h + 0.03, length), 0.035)
    end
    if index ~= 1 then return end
    P.Add(root, "运输车驾驶室", "Box", m.red, V(0, 1.4, length + 1.5), V(2.45, 2.45, 2.5))
    P.Add(root, "挡风玻璃", "Box", m.glass, V(0, 1.95, length + 2.76), V(2.1, 0.79, 0.035), nil, false)
    P.Add(root, "运输车底盘", "Box", m.dark, V(0, 0.55, length - 0.1), V(2.25, 0.32, 5.7))
    local wheel = CylinderGeometry(0.47, 0.47, 0.27, 18):ToModel()
    for _, z in ipairs({length - 2.5, length + 1.6}) do
        for side = -1, 1, 2 do
            P.Add(root, "运输车轮胎", wheel, m.dark, V(side * 1.1, 0.47, z), nil, Quaternion(0, 0, 90))
        end
    end
    for side = -1, 1, 2 do
        P.Add(root, "运输车车灯", "Box", m.lamp, V(side * 0.81, 0.98, length + 2.78), V(0.36, 0.24, 0.03), nil, false)
        P.Add(root, "路肩锥标", ConeGeometry(0.2, 0.75, 12):ToModel(), m.yellow, V(side * 2.15, 0.375, 3), nil, nil, false)
    end
end

-- 顶面直接使用机关数据中的逐米横截面，Height查询沿同一对角线插值。
-- 两侧/背面封口是真实楔形，不用旋转方盒；标线不扩大有效车道。
---@param r TrackFeature
function World:BuildOptionalRamp(r)
    local root = self.root:CreateChild("可选飞坡_" .. r.id)
    local m = self.mats
    local g = Landscape.Geometry(root, "可见高楔形坡面", m.rampDeck)
    local marks = Landscape.Geometry(root, "黄黑飞坡警示黄", m.rampYellow)
    local dark = Landscape.Geometry(root, "黄黑飞坡警示黑", m.rampBlack)
    local function point(lateral, forward, y)
        local x,z = TrackFeatures.Point(r,lateral,forward)
        return V(x,y,z)
    end
    local function surface(lateral,forward,lift)
        local x,z = TrackFeatures.Point(r,lateral,forward)
        return V(x,(TrackFeatures.RampHeight(r,x,z) or r.y)+(lift or 0),z)
    end
    local function quad(geom,a,b,c,d)
        Landscape.Triangle(geom,a,b,c);Landscape.Triangle(geom,c,b,d)
    end
    local w = r.width*.5
    for i = 1,#r.rows-1 do
        local a,b = r.rows[i],r.rows[i+1]
        local p,q = point(-w,a.forward,a.left),point(-w,b.forward,b.left)
        local c,d = point(w,a.forward,a.right),point(w,b.forward,b.right)
        quad(g,p,q,c,d)
        for _,side in ipairs({-1,1}) do
            local x0,z0=TrackFeatures.Point(r,side*w,a.forward)
            local x1,z1=TrackFeatures.Point(r,side*w,b.forward)
            local base0=V(x0,Landscape.RoadHeight(x0,z0) or r.y,z0)
            local base1=V(x1,Landscape.RoadHeight(x1,z1) or r.y,z1)
            local top0,top1=side<0 and p or c,side<0 and q or d
            -- 黄黑侧腹板与真实侧壁同范围，不扩大坡体，不加伸入绕行线的护栏。
            local panel=i%2==0 and marks or dark
            if side<0 then quad(panel,base0,base1,top0,top1)
            else quad(panel,base1,base0,top1,top0) end
            local lo=side<0 and -w or w-.16
            local hi=side<0 and -w+.16 or w
            quad(marks,surface(lo,a.forward,.018),surface(lo,b.forward,.018),
                surface(hi,a.forward,.018),surface(hi,b.forward,.018))
        end
    end
    local last=r.rows[#r.rows]
    local a,b=point(-w,r.length,last.left),point(w,r.length,last.right)
    local x0,z0=TrackFeatures.Point(r,-w,r.length)
    local x1,z1=TrackFeatures.Point(r,w,r.length)
    local c=V(x0,Landscape.RoadHeight(x0,z0) or r.y,z0)
    local d=V(x1,Landscape.RoadHeight(x1,z1) or r.y,z1)
    quad(dark,a,c,b,d)
    -- 宽唇口棋盘带、高侧板轮廓，视觉上明确是有高度的跳台，不是青色加速贴片。
    for i=0,7 do
        local lo=-w+r.width*i/8
        local hi=-w+r.width*(i+1)/8
        quad(i%2==0 and marks or dark,surface(lo,r.length-.65,.026),surface(lo,r.length,.026),
            surface(hi,r.length-.65,.026),surface(hi,r.length,.026))
    end
    for _,forward in ipairs({4,9,14}) do
        Landscape.Triangle(marks,surface(-.8,forward,.024),surface(0,forward+2.4,.024),surface(-.25,forward,.024))
        Landscape.Triangle(marks,surface(.25,forward,.024),surface(0,forward+2.4,.024),surface(.8,forward,.024))
    end
    -- 路面预告跟随原路，不沿坡朝向把标线画到弯外；只占可选坡入口线。
    local function roadPoint(station,lateral,lift)
        local p,yaw=Landscape.RoadPoint(station)
        local angle=math.rad(yaw)
        local x,z=p.x+math.cos(angle)*lateral,p.z-math.sin(angle)*lateral
        return V(x,(Landscape.RoadHeight(x,z) or p.y)+lift,z)
    end
    for _,offset in ipairs({-64,-44,-28,-16}) do
        local s=r.s+offset
        quad(dark,roadPoint(s,r.lateral-w,.027),roadPoint(s+1.8,r.lateral-w,.027),
            roadPoint(s,r.lateral+w,.027),roadPoint(s+1.8,r.lateral+w,.027))
        for i=0,5 do
            local lo=r.lateral-w+i*r.width/6
            local hi=lo+r.width/12
            quad(marks,roadPoint(s,lo,.035),roadPoint(s+1.8,lo,.035),
                roadPoint(s,hi,.035),roadPoint(s+1.8,hi,.035))
        end
        Landscape.Triangle(marks,roadPoint(s+3,r.lateral-.65,.035),
            roadPoint(s+5,r.lateral,.035),roadPoint(s+3,r.lateral+.65,.035))
    end
    -- 两块路肩立式跳台图标牌（100m/45m前）；没有跨路门架、支柱或横梁。
    local side=r.lateral<0 and -1 or 1
    for _,offset in ipairs({-100,-45}) do
        local p,yaw=Landscape.RoadPoint(r.s+offset)
        local angle=math.rad(yaw)
        local lateral=side*(Landscape.Roads[1].width+1.35)
        local x,z=p.x+math.cos(angle)*lateral,p.z-math.sin(angle)*lateral
        local y=Landscape.RoadHeight(x,z) or Landscape.TerrainHeight(x,z)
        local right=V(math.cos(angle),0,-math.sin(angle))
        local forward=V(math.sin(angle),0,math.cos(angle))
        local center=V(x,y+2.6,z)
        local function sign(u,v,front) return center+right*u+V(0,v,0)-forward*front end
        P.Add(root,"飞坡预告路肩立柱","Box",m.rampBlack,V(x,y+1.2,z),V(.13,2.4,.13),Quaternion(0,yaw,0),false)
        -- 双面黄底黑框；面向来车的黑色升坡+抛物线图标，不依赖小字可读性。
        local tl,tr,bl,br=sign(-1.05,.82,0),sign(1.05,.82,0),sign(-1.05,-.82,0),sign(1.05,-.82,0)
        quad(dark,bl,tl,br,tr);quad(dark,br,tr,bl,tl)
        local l,t,rr,bm=-.94,.71,.94,-.71
        quad(marks,sign(l,bm,.012),sign(l,t,.012),sign(rr,bm,.012),sign(rr,t,.012))
        Landscape.Triangle(dark,sign(-.78,-.39,.024),sign(.05,.22,.024),sign(.05,-.39,.024))
        for i=0,5 do
            local u0,u1=.10+i*.115,.10+(i+1)*.115
            local v0,v1=.28+.48*(i/6)-.66*(i/6)^2,.28+.48*((i+1)/6)-.66*((i+1)/6)^2
            quad(dark,sign(u0,v0-.045,.025),sign(u0,v0+.045,.025),sign(u1,v1-.045,.025),sign(u1,v1+.045,.025))
        end
        -- 牌底箭头指向路中绕行通道，保留不飞跃的明确选择。
        local direction=-side
        Landscape.Triangle(dark,sign(-direction*.55,-.55,.025),sign(direction*.62,-.55,.025),sign(direction*.23,-.34,.025))
    end
    g:GenerateTangents();g:Commit();marks:GenerateTangents();marks:Commit();dark:GenerateTangents();dark:Commit()
    g.drawDistance,marks.drawDistance,dark.drawDistance=520,520,520
    g.castShadows,g.shadowDistance=true,150
end

-- 薄贴地彩色车道与正向箭头，无盒体凸起、无外部纹理或动态动画。
function World:BuildBoostBands()
    local m=self.mats
    for _,f in ipairs(self.features) do
        if f.kind=="boost" then
            local root=self.root:CreateChild("方向加速带_"..f.id)
            local base=Landscape.Geometry(root,"加速带青色底纹",m.boostBand)
            local arrows=Landscape.Geometry(root,"醒目正向箭头",m.boostArrow)
            local border=Landscape.Geometry(root,"加速带入口边界",m.white)
            local function p(x,z,lift)
                local wx,wz=TrackFeatures.Point(f,x,z)
                return V(wx,(Landscape.RoadHeight(wx,wz) or f.y)+lift,wz)
            end
            local function quad(g,lo,hi,a,b,lift)
                Landscape.Triangle(g,p(lo,a,lift),p(lo,b,lift),p(hi,a,lift))
                Landscape.Triangle(g,p(hi,a,lift),p(lo,b,lift),p(hi,b,lift))
            end
            local w=f.width*.5
            for z=0,f.length-1 do quad(base,-w,w,z,z+1,.028) end
            for z=0,f.length-1 do
                quad(border,-w,-w+.1,z,z+1,.04);quad(border,w-.1,w,z,z+1,.04)
            end
            quad(border,-w,w,0,.18,.04)
            for _,z in ipairs({1,3.5,6}) do
                Landscape.Triangle(arrows,p(-1.45,z,.046),p(0,z+2,.046),p(-.6,z,.046))
                Landscape.Triangle(arrows,p(.6,z,.046),p(0,z+2,.046),p(1.45,z,.046))
            end
            base:GenerateTangents();base:Commit();arrows:Commit();border:Commit()
            base.drawDistance,arrows.drawDistance,border.drawDistance=380,380,380
        end
    end
end

function World:BuildStations()
    if Landscape.activeId~="lake" then return end
    local m = self.mats
    for i, s in ipairs({25, Landscape.RouteLength * 0.865}) do
        local p, yaw = Landscape.RoadPoint(s)
        local a = math.rad(yaw)
        local right = V(math.cos(a), 0, -math.sin(a))
        local pos = p + right * (i == 1 and -24 or 24)
        local ground = Landscape.TerrainHeight(pos.x, pos.z)
        local root = self.root:CreateChild(i == 1 and "湖岸出发驿站" or "山间牧场")
        root.position = V(pos.x, ground, pos.z)
        root.rotation = Quaternion(0, yaw, 0)
        P.Add(root, "木屋主体", "Box", m.wood, V(0, 1.65, 0), V(9.2, 3.3, 6.6), nil, false)
        local roof = ConvexGeometry({V(-5.2, 0, -3.9), V(5.2, 0, -3.9), V(0, 2.1, -3.9),
            V(-5.2, 0, 3.9), V(5.2, 0, 3.9), V(0, 2.1, 3.9)}):ToModel()
        P.Add(root, "斜屋顶", roof, m.red, V(0, 3.2, 0), nil, nil, false)
        for _, x in ipairs({-2.8, 2.8}) do
            P.Add(root, "驿站窗户", "Box", m.glass, V(x, 1.9, -3.33), V(1.8, 1.2, 0.04), nil, false)
            P.Add(root, "窗沿", "Box", m.white, V(x, 1.25, -3.38), V(2, 0.12, 0.16), nil, false)
        end
        P.Add(root, "入口门", "Box", m.dark, V(0, 1.16, -3.34), V(1.3, 2.32, 0.05), nil, false)
        for _, x in ipairs({-4.1, 4.1}) do
            P.Add(root, "门廊立柱", "Cylinder", m.wood, V(x, 1.55, -5), V(0.18, 3.1, 0.18), nil, false)
        end
        P.Add(root, "门廊顶", "Box", m.red, V(0, 3.05, -4.2), V(9.4, 0.17, 2.5), nil, false)
    end
    local signPoint, yaw = Landscape.RoadPoint(35)
    local a = math.rad(yaw)
    local q = signPoint + V(math.cos(a), 0, -math.sin(a)) * 9
    local base = Landscape.TerrainHeight(q.x, q.z)
    P.Add(self.root, "出发路牌立柱", "Cylinder", m.rail, V(q.x, base + 1.3, q.z), V(0.12, 2.6, 0.12), nil, false)
    P.Add(self.root, "风景线路牌", "Box", m.green, V(q.x, base + 2.6, q.z), V(3.1, 1.1, 0.13), Quaternion(0, yaw, 0), false)
    for side = -1, 1, 2 do
        P.Bar(self.root, m.white, V(q.x + side * 0.45, base + 2.6, q.z - 0.08), V(q.x + side * 0.9, base + 2.6, q.z - 0.08), 0.026)
    end
end

function World:BuildRoadFurniture()
    if Landscape.activeId~="lake" then return end
    local m = self.mats
    for s = 40, Landscape.RouteLength - 1, 36 do
        local p, yaw = Landscape.RoadPoint(s)
        local a = math.rad(yaw)
        for side = -1, 1, 2 do
            local q = p + V(math.cos(a), 0, -math.sin(a)) * (side * (Landscape.Roads[1].shoulder + 0.6))
            local y = Landscape.TerrainHeight(q.x, q.z)
            P.Add(self.root, "沿线里程桩", "Box", m.white, V(q.x, y + 0.47, q.z), V(0.12, 0.94, 0.18), Quaternion(0, yaw, 0), false)
            P.Add(self.root, "桩顶反光面", "Box", m.dark, V(q.x, y + 0.77, q.z), V(0.13, 0.14, 0.19), Quaternion(0, yaw, 0), false)
        end
    end
    -- 护栏只覆盖桥梁与少数外侧弯道，其他路肩均可自由驶入山坡。
    for _, s in ipairs({400, 960, 1560, 2160, 2640}) do
        local p, yaw = Landscape.RoadPoint(s)
        local a = math.rad(yaw)
        local root = self.root:CreateChild("山路弯道预告")
        local pos = p + V(math.cos(a), 0, -math.sin(a)) * -9
        root.position = V(pos.x, Landscape.TerrainHeight(pos.x, pos.z), pos.z)
        root.rotation = Quaternion(0, yaw, 0)
        P.Add(root, "标牌杆", "Cylinder", m.rail, V(0, 1.1, 0), V(0.08, 2.2, 0.08), nil, false)
        P.Add(root, "弯道预告牌", "Box", m.yellow, V(0, 2.15, 0), V(1.05, 1.05, 0.07), Quaternion(0, 0, 45), false)
        P.Add(root, "转向图案", "Box", m.dark, V(0, 2.15, -0.045), V(0.14, 0.59, 0.02), Quaternion(0, 0, -24), false)
    end
end

function World:BuildMeadow()
    if Landscape.activeId~="lake" then return end
    local m = self.mats
    local root = self.root:CreateChild("草甸花丛与湖岸岩石")
    local rockModel = IcosahedronGeometry(1, 2):ToModel()
    for i = 1, 32 do
        local a = i * 2.39996
        local x, z = -190 + math.cos(a) * (170 + i % 4 * 5), 190 + math.sin(a) * (190 + i % 3 * 5)
        local y, road = Landscape.Height(x, z)
        if not road then
            local scale = 0.6 + i % 4 * 0.35
            P.Add(root, "湖岸圆石", rockModel, m.rock, V(x, y + scale * 0.15, z), V(scale * 1.6, scale, scale * 1.2), Quaternion(0, i * 37, 0), false)
        end
    end
    local gold = P.Material(0.58, 0.55, 0.24, 0.95)
    local flowers = Landscape.Geometry(root, "高山草甸花叶合批", gold)
    for i = 1, 360 do
        local x = -165 + ((i * 73.71) % 340)
        local z = 760 + ((i * 39.27) % 240)
        local y, road = Landscape.Height(x, z)
        local _, lateral = Landscape.NearestRoad(x, z)
        if not road and math.abs(lateral) > 9 then
            local h = 0.18 + (i % 5) * 0.09
            Landscape.Triangle(flowers, V(x - 0.1, y, z), V(x, y + h, z), V(x + 0.1, y, z))
            Landscape.Triangle(flowers, V(x + 0.1, y, z), V(x, y + h, z), V(x - 0.1, y, z))
        end
    end
    flowers:Commit()
end

---@param tick fun(stage:string,current:integer,total:integer)
function World:CreateTraffic(tick)
    if not Landscape.Track.traffic then tick("精细交通",14,14);return end
    for i = 1, 14 do
        local id = Assets.TrafficIds[(i - 1) % #Assets.TrafficIds + 1]
        local root = Assets.Add(self.root, id)
        local size = root:GetVar("VehicleSize"):GetVector3()
        local models = root:GetComponents("StaticModel", true)
        ---@type ScenicTraffic
        local car = {node = root, x = 0, y = 0, z = 0, yaw = 0, previousX = 0, previousY = 0, previousZ = 0,
            speed = 0, s = 0, lane = 2.4, halfLength = size.z * 0.5, halfWidth = size.x * 0.5, width = size.x,
            height = size.y, passed = false, previousRel = 0, models = models}
        self.traffic[#self.traffic + 1] = car
        for _, model in ipairs(models) do
            model.shadowDistance = 45
            model.drawDistance = 340
        end
        tick("精细交通", i, 14)
    end
end

---@param car ScenicTraffic
---@param teleport boolean
function World:PlaceCar(car, teleport)
    local p, yaw, forwardPitch = Landscape.TrafficPose(car.s, car.lane)
    local x, y, z = p.x, p.y, p.z
    local pitch = car.speed < 0 and -forwardPitch or forwardPitch
    car.x, car.y, car.z = x, y, z
    car.yaw = yaw + (car.speed < 0 and 180 or 0)
    car.node.position = V(x, y, z)
    car.node.rotation = Quaternion(pitch, car.yaw, 0)
    if teleport then car.previousX, car.previousY, car.previousZ = x, y, z end
end

---@param distance number
function World:ResetTraffic(distance)
    for i, car in ipairs(self.traffic) do
        car.lane = i % 3 == 0 and -2.4 or 2.4
        car.speed = (car.lane < 0 and -1 or 1) * (12 + i * 7 % 11)
        car.s = distance + 90 + i * 94
        car.passed = false
        car.previousRel = car.s - distance
        self:PlaceCar(car, true)
    end
end

---@param high boolean
function World:SetQuality(high)
    self.highQuality = high
    Landscape.SetQuality(high)
    for _, car in ipairs(self.traffic) do
        for _, model in ipairs(car.models) do
            model.drawDistance = high and 480 or 340
            model.shadowDistance = high and 90 or 45
            model.lodBias = high and 0.8 or 0.5
        end
    end
end

---@param dt number
---@param distance number
---@param clock number
---@param playerX? number
---@param playerZ? number
function World:Update(dt, distance, clock, playerX, playerZ)
    self.clock = clock
    require("MixedCourse").Update(self,clock)
    local route = Landscape.RouteLength
    local reference = distance
    if playerX ~= nil and playerZ ~= nil then reference = Landscape.NearestRoad(playerX, playerZ) end
    -- 视距／阴影视距交给引擎空间剔除处理；
    -- 交通固定步不再递归开关整棵导入车辆层级。
    for _, car in ipairs(self.traffic) do
        car.previousX, car.previousY, car.previousZ = car.x, car.y, car.z
        local nextS = car.s + car.speed * dt
        car.s = nextS
        local relative = (car.s - reference + route * 0.5) % route - route * 0.5
        local teleport = false
        if relative < -145 or relative > 1500 then
            car.s = reference + 260 + ((_ % 6) * 125)
            car.passed = false
            teleport = true
        end
        car.previousRel = relative
        self:PlaceCar(car, teleport)
    end
end

return World
