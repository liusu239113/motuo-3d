-- 基于场景脚手架的独立室内层：共享CityDetails材质批次，不订阅输入和事件。
local Data=require("Career.HousingData")
local Details=require("Career.CityDetails")
local Parts=require("Parts")
local V=Vector3
---@class CareerInterior
local Interior={}
Interior.__index=Interior
function Interior.New(scene,mats)
    local self=setmetatable({},Interior); self:Init(scene,mats); return self
end
function Interior:Init(scene,mats)
    self.root=scene:CreateChild("生涯住房室内层")
    self.active="city"
    self.rooms={}
    self.obstacles={}
    self.mats={wood=mats.wood,metal=mats.metal,glass=mats.glass,trim=mats.trim,
        floor=mats.concrete,wall=Parts.Material(.69,.67,.60,.92,0),
        linen=Parts.Material(.79,.78,.70,.95,0),blanket=Parts.Material(.10,.23,.29,.95,0),
        leather=Parts.Material(.24,.29,.27,.88,0),dark=mats.recess,
        light=Parts.Material(.95,.79,.48,.7,0,1.5)}
    for _,home in ipairs(Data.List) do if home.width then self:Build(home) end end
    self.root:SetEnabledRecursive(false)
end
-- 碰撞俯视（米）：四周边界减r=.32；家具独立AABB，床边留≥1.0m过道。
--   后墙 + [床][床]       [柜] +
--        |       过道         |
--        |   床边交互圆       |
--   前墙 +------ 出入口 ------+
-- 出门需要到门边点击，不以越界瞬移；步进≤.1m防止穿床/桌，门点不落在墙内。
function Interior:Solid(home,d,mat,x,y,z,w,h,depth)
    d:Box(mat,x,y,z,w,h,depth)
    local list=self.obstacles[home.id]
    list[#list+1]={x1=x-w/2,x2=x+w/2,z1=z-depth/2,z2=z+depth/2}
end
function Interior:Bed(home,d,x,z,width)
    self:Solid(home,d,"wood",x,.28,z,width,.44,2.15)
    d:Box("linen",x,.58,z,width+.06,.20,2.08)
    d:Box("blanket",x,.71,z-.25,width+.08,.10,1.42)
    d:Box("linen",x,.76,z+.75,width*.76,.18,.43)
    d:Box("wood",x,.7,z+1.09,width+.1,1.1,.1)
    for _,side in ipairs({-1,1}) do d:Box("trim",x+side*(width/2-.08),.09,z-.85,.08,.18,.08) end
end
function Interior:Build(home)
    local root=self.root:CreateChild(home.name)
    self.rooms[home.id]=root; self.obstacles[home.id]={}
    local d=Details.New(root,self.mats)
    local w,h=home.width,home.depth
    d:Ground(home.id=="hostel" and "floor" or "wood",0,0,w,h,.085)
    -- 正面低墙是剖视遮挡处理，相机仍由ThirdPersonCamera管理，不另算位置。
    d:Box("wall",0,1.5,h/2,w+.2,3,.16)
    for _,side in ipairs({-1,1}) do
        d:Box("wall",side*w/2,1.5,0,.16,3,h)
        d:Box("wood",side*w/2,.16,0,.08,.14,h)
        d:Box("wall",side*(w/4+.4),.46,-h/2,w/2-.8,.75,.14)
    end
    d:Box("dark",0,.09,-h/2+.6,1.35,.02,1)
    d:Sign("出门 · 点击交互",0,1.15,-h/2+.1,0,.16)
    local bedX=-w/2+1.1
    self:Bed(home,d,bedX,1.7,home.id=="apartment" and 1.7 or 1.1)
    if home.id=="hostel" then
        self:Bed(home,d,bedX,-1.1,1.1)
        self:Solid(home,d,"metal",w/2-.45,.95,2,.7,1.8,1.4)
        for n=1,3 do
            d:Box("trim",w/2-.81,1.3,1.5+(n-1)*.5,.02,.18,.03)
        end
        d:Sign("06床 · 王二狗",bedX,1.5,2.8,0,.15)
    else
        self:Solid(home,d,"wood",w/2-.65,.85,2.8,1.1,1.7,1.25)
        d:Box("trim",w/2-.65,.85,2.15,.02,1.45,.025)
        self:Solid(home,d,"wood",w/2-.85,.72,-.8,1.4,.08,.85)
        for _,sx in ipairs({-1,1}) do
            for _,sz in ipairs({-1,1}) do d:Box("metal",w/2-.85+sx*.58,.38,-.8+sz*.32,.045,.68,.045) end
        end
        d:Box("linen",w/2-.85,.78,-.8,.50,.035,.35)
        d:Box("metal",w/2-.5,.92,-.6,.16,.28,.16)
        self:Solid(home,d,"wood",w/2-1.1,.4,-1.85,.65,.72,.6)
        d:Box("blanket",w/2-1.1,.8,-1.85,.68,.10,.62)
    end
    if home.id=="apartment" then
        self:Solid(home,d,"leather",2,.4,3.7,2.5,.7,.85)
        d:Box("leather",2,.85,4,2.6,.75,.2)
        for _,sx in ipairs({-1,1}) do d:Box("leather",2+sx*1.2,.7,3.7,.18,.6,.85) end
        self:Solid(home,d,"wood",1.6,.35,2,1.4,.65,.7)
        d:Box("linen",1.6,.7,2,.3,.04,.22)
        self:Solid(home,d,"trim",-1.6,.5,-4.75,3.2,.95,.5)
        d:Box("metal",-1.4,1,-4.75,.65,.04,.42)
        d:Box("glass",0,1.85,5.4,3.6,1.6,.025)
        for _,side in ipairs({-1,1}) do d:Box("blanket",side*2,1.9,5.3,.35,1.9,.14) end
    else d:Box("glass",.6,1.9,h/2-.1,1.7,1.25,.03) end
    d:Box("light",0,2.75,0,1.1,.07,.45)
    d:Sign(home.name..string.format(" · %.0f元/晚",home.price/100),0,2.15,h/2-.15,0,.2)
    local lightNode=root:CreateChild("室内暖灯")
    lightNode.position=V(0,2.4,0)
    local light=lightNode:CreateComponent("Light")
    light.lightType=LIGHT_POINT; light.range=14; light.brightness=5; light.color=Color(1,.83,.62); light.castShadows=false
    local zone=root:CreateComponent("Zone")
    zone.boundingBox=BoundingBox(V(-20,-5,-20),V(20,15,20)); zone.priority=100
    zone.ambientSource=AMBIENT_COLOR; zone.ambientColor=Color(.30,.32,.35)
    zone.depthFogEnable=false
    d:Finish()
    print("[生涯住房] 室内构建完成："..home.id.."，独立家具碰撞与暖灯")
end
function Interior:SetSpace(id)
    self.active=id
    self.root:SetEnabledRecursive(id~="city")
    for key,root in pairs(self.rooms) do root:SetEnabledRecursive(key==id) end
end
function Interior:IsFree(x,z,radius)
    local home=assert(Data.Get(self.active))
    if math.abs(x)>home.width/2-radius or math.abs(z)>home.depth/2-radius then return false end
    for _,o in ipairs(self.obstacles[self.active]) do
        if x>o.x1-radius and x<o.x2+radius and z>o.z1-radius and z<o.z2+radius then return false end
    end
    return true
end
function Interior:Move(x,z,dx,dz,radius)
    local count=math.max(1,math.ceil(math.sqrt(dx*dx+dz*dz)/.1))
    for _=1,count do
        if self:IsFree(x+dx/count,z,radius) then x=x+dx/count end
        if self:IsFree(x,z+dz/count,radius) then z=z+dz/count end
    end
    return x,z
end
function Interior:FindFree(x,z,radius)
    if self:IsFree(x,z,radius) then return x,z end
    return Data.Spawn(self.active)
end
return Interior
