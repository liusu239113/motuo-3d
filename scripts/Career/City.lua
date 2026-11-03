-- 基于三维场景脚手架和现有 Landscape 材质，城市为固定米制世界，不跟随玩家平移。
local Details = require("Career.CityDetails")
local Landscape = require("Landscape")
local Parts = require("Parts")
local Config = require("Career.Config")
local Housing = require("Career.HousingData")
local Interior = require("Career.Interior")
local Signals = require("Career.TrafficSignals")
local World = require("Career.WorldData")
local Stream = require("Career.WorldStream")
local StreetDressing = require("Career.StreetDressing")
local Footprints = require("Career.BuildingFootprints")
local Expansion = require("Career.CityExpansion")
local Environment = require("Career.CityEnvironment")
local Collision = require("Career.CityCollision")
local Footprint = require("Career.FootprintCollision")
local DisplayLod = require("Career.BuildingLod")
---@class CareerCity
---@field actor? CareerActor
---@field contacts CareerContacts
---@field deliveryPeople? CareerDeliveryPeople
---@field crowd? CareerCrowd
---@field streetDressing CareerStreetDressing
---@field stream CareerWorldStream
---@field FindFree fun(self:CareerCity,x:number,z:number,radius:number,mode?:string,height?:number):number,number
---@field SetSpace fun(self:CareerCity,id:string)
---@field UpdateLights fun(self:CareerCity,hour:number)
---@field WalkSurface fun(self:CareerCity,x:number,z:number,height?:number):number
local City = {}
City.__index = City
local architecture={
    {root="model/e799bc6c-0cef-5148-978f-9a41183cc268/",stem="c531d52ef7284ea8ae32f415bfe4b98e",material="c531d52ef7284ea8ae32f415bfe4b98e_00_tripo_material_55e20983-baca-4902-adac-b025ebed4e62.xml"},
    {root="model/62f2b98b-631d-5438-94ed-5ed78d3984b0/",stem="94b007f45c784751825b3e1b8e1e624a",material="94b007f45c784751825b3e1b8e1e624a_00_tripo_material_4516bc36-b2c8-41bf-8f41-8eed1211e086.xml"},
    {root="model/ea4b7cae-42e1-5651-8edf-6ccadbbd2046/",stem="863a459ef93647c88fe260263a9b2a1d",material="863a459ef93647c88fe260263a9b2a1d_00_tripo_material_6416e276-d70d-40dd-8b35-835c0187af3e.xml"},
}
City.Resources, City.ResourceTypes = {}, {}
for _,asset in ipairs(architecture) do
    for path,kind in pairs({[asset.root.."Meshes/"..asset.stem..".mdl"]="Model",
        [asset.root.."Materials/"..asset.material]="Material",
        [asset.root.."Textures/"..asset.stem.."_00_D.jpg"]="Texture2D",
        [asset.root.."Textures/"..asset.stem.."_00_N.jpg"]="Texture2D"}) do
        City.Resources[#City.Resources+1]=path; City.ResourceTypes[path]=kind
    end
end
for _,path in ipairs(DisplayLod.Resources) do
    City.Resources[#City.Resources+1]=path;City.ResourceTypes[path]="Model"
end
for _, path in ipairs(Landscape.Resources) do
    City.Resources[#City.Resources + 1] = path
    City.ResourceTypes[path] = Landscape.ResourceTypes[path]
end

for _, path in ipairs(StreetDressing.Resources) do
    City.Resources[#City.Resources+1]=path
    City.ResourceTypes[path]=StreetDressing.ResourceTypes[path]
end
for _,path in ipairs(Environment.Resources) do
    City.Resources[#City.Resources+1]=path
    City.ResourceTypes[path]=Environment.ResourceTypes[path]
end
-- 城市绿化复用赛道已用的写实阔叶树模型，不再用代码绘制的球体树冠。
local Trees=require("ScenicTrees")
for _,path in ipairs(Trees.Resources) do
    if not City.ResourceTypes[path] then
        City.Resources[#City.Resources+1]=path
        City.ResourceTypes[path]=Trees.ResourceTypes[path]
    end
end

---@param scene Scene
---@return CareerCity
function City.New(scene)
    local self = setmetatable({}, City)
    self:Init(scene)
    return self
end

function City:Init(scene)
    self.root = scene:CreateChild("南城老街生涯城区")
    self.obstacles, self.markers, self.buildings = {}, {}, 0
    self.buildingFootprints={}
    self.displayBuildings={}
    self.displayBuildingTick=0
    self.disposed=false
    self.space="city"
    ---@type CityTraffic?
    self.traffic=nil
    ---@type boolean?
    self.lightsOn=nil
    ---@type Light[]
    self.nightLights={}
    -- 从森林/沙漠赛事回来仍使用老街沥青与城市色板，不继承上一张赛道的地表替换。
    assert(Landscape.SelectTrack("circuit"))
    local base = Landscape.CreateMaterials()
    self.mats = {
        road = base.road, grass = base.grass, wood = base.wood,
        paint = base.white, yellow = base.yellow,
        concrete = base.rock, stone = base.soil, plaster = base.soil,
        recess = base.dark, metal = base.rail, trim = base.white, frame = base.dark,
        foliage = base.green,
        glass = Parts.Material(.09,.19,.23,.27,.36),
        windowWarm = Parts.Material(.39,.29,.15,.62,0,.08),
        lamp = Parts.Material(.9,.8,.57,.4,0,.15),
        brick = base.red,
    }
    self.details = Details.New(self.root, self.mats)
    -- 所有静态装饰统一交由分块批次构建。
    self:BuildRoads()
    self.expansionSeams=Expansion.BuildSeams(self.details)
    self:BuildBlocks()
    Trees.Begin()
    self:BuildPlaces()
    self.streetDressing=StreetDressing.New(self)
    Environment.BuildCore(self)
    self.contacts=require("Career.Contacts").New(self)
    Collision.Index(self)
    self.signals=Signals.New(self.root,self.details)
    self.stats = self.details:Finish()
    World.SetLegacy(self.obstacles,self.details.surfaces)
    self.interior=Interior.New(scene,self.mats)
    self.stream=Stream.New(self)
    self.stats.buildings, self.stats.obstacles = self.buildings, #self.obstacles
    print(string.format("[生涯城市] %d栋建筑 / %d批次 / %.0f三角面 / %d招牌 / %d碰撞区域",
        self.buildings, self.stats.batches, self.stats.triangles, self.stats.signs, #self.obstacles))
end

function City:BuildRoads()
    local d = self.details
    d:Ground("stone",0,0,390,390,0)
    -- 12米双向路，6米人行道。外环中心±172，车道外缘178，留出地图边界余量。
    for _, x in ipairs({-172,-100,0,100,172}) do
        d:Ground("road",x,0,12,356,.055)
        for _, side in ipairs({-1,1}) do d:Ground("concrete",x+side*9,0,6,356,.065) end
        for z=-166,166,8 do
            if math.abs(z)>12 and math.abs(z-100)>12 and math.abs(z+172)>12 and math.abs(z-172)>12 then
                d:Ground("yellow",x,z,.11,3,.068)
            end
        end
    end
    for _, z in ipairs({-172,0,100,172}) do
        d:Ground("road",0,z,356,12,.058)
        for _, side in ipairs({-1,1}) do d:Ground("concrete",0,z+side*9,356,6,.069) end
        for x=-166,166,8 do
            local clear = true
            for _, rx in ipairs({-172,-100,0,100,172}) do if math.abs(rx-x)<12 then clear=false end end
            if clear then d:Ground("yellow",x,z,3,.11,.074) end
        end
        for _, x in ipairs({-100,0,100}) do
            d:Ground("road",x,z,25,25,.076)
            for n=-3,3 do
                d:Ground("paint",x+n*1.0,z-9,.5,3,.08)
                d:Ground("paint",x+n*1.0,z+9,.5,3,.08)
            end
        end
    end
    for _, x in ipairs({-100,0,100}) do
        for z=-145,145,42 do
            if math.abs(z)>18 and math.abs(z-100)>18 and not (x==0 and z< -40) then
                d:Lamp(x-9.4,z,90)
                self:NightLight(x-8.15,6.12,z,30,22)
            end
        end
    end
end

-- Collision plan (metres, top view): road -> sidewalk -> [visible solid shell].
-- Walk uses a true circle; ride/parking uses oriented triangle-derived strips.
-- Continuous casts + contact-normal sliding cover tiny posts and oblique corners;
-- <=.10m substeps remain for dynamics. No enclosing vehicle disc / square radius.
-- FindFree is recovery-only; ordinary input never searches or teleports.
function City:Obstacle(x,z,w,depth)
    self.obstacles[#self.obstacles+1] = {x1=x-w/2,x2=x+w/2,z1=z-depth/2,z2=z+depth/2}
end

function City:Building(x,z,w,depth,floors,style,name,yaw)
    local d = self.details
    local h = floors*3.05+1.0
    local angle = math.rad(yaw or 0)
    local function p(px,pz) return x+px*math.cos(angle)+pz*math.sin(angle),z-px*math.sin(angle)+pz*math.cos(angle) end
    d:Box(style,x,h/2+.08,z,w,h,depth,yaw)
    -- 地基向下穿入地面，不能把整栋楼悬在统一的8.5cm摆放平面。
    d:Box("concrete",x,.25,z,w+.25,.60,depth+.25,yaw)
    d:Box("trim",x,h+.12,z,w+.45,.26,depth+.45,yaw)
    d:Box("recess",x,h+.32,z,w-.6,.16,depth-.6,yaw)
    local cols = math.max(2,math.floor(w/4))
    for floor=1,floors do
        for col=1,cols do
            local px = (col-(cols+1)/2)*(w-3)/cols
            local wx,wz = p(px,-depth/2-.04)
            d:Window(wx,floor*3.05-1.2,wz,yaw or 0,1.45,1.65,(col+floor)%5==0)
            if style=="plaster" and floor>1 and col%2==0 then d:Balcony(wx,floor*3.05-1.2,wz,yaw or 0,col%4==0) end
            local bx,bz = p(px,depth/2+.04)
            d:Window(bx,floor*3.05-1.2,bz,(yaw or 0)+180,1.45,1.65,false)
        end
    end
    local fx,fz = p(0,-depth/2-.12)
    d:Box("recess",fx,1.25,fz,1.8,2.5,.12,yaw)
    local sx,sz=p(0,-depth/2-.22)
    d:Box("metal",sx,3.05,sz,math.min(w-1,12),1,.24,yaw)
    d:Sign(name,sx,3.05,sz-.02,(yaw or 0),.46)
    local roofX,roofZ=p(w*.25,depth*.2)
    d:Box("trim",roofX,h+.6,roofZ,2.2,.9,1.2,yaw)
    if (yaw or 0)%180==0 then self:Obstacle(x,z,w+.3,depth+.3)
    else self:Obstacle(x,z,depth+.3,w+.3) end
    self.buildings=self.buildings+1
end

function City:DetailedBuilding(index,x,z,w,depth,height,yaw,name)
    local asset=architecture[index]
    local model=cache:GetResource("Model",asset.root.."Meshes/"..asset.stem..".mdl")
    local bounds=model.boundingBox
    -- 模型只在预留地块内等比缩放，按旋转后的精确包围盒生成碰撞。
    local scale=math.min(w/bounds.size.x,depth/bounds.size.z,height/bounds.size.y)
    local root=self.root:CreateChild(name)
    root.position=Vector3(x,self:Surface(x,z),z); root.rotation=Quaternion(0,yaw,0)
    local body=root:CreateChild("写实建筑")
    body:SetScale(scale)
    body.position=Vector3(-bounds.center.x*scale,-bounds.min.y*scale,-bounds.center.z*scale)
    local draw=body:CreateComponent("StaticModel")
    draw.model=model
    self.displayBuildings[#self.displayBuildings+1]={draw=draw,levels=DisplayLod.Levels(model),x=x,z=z,level=1,near=45,mid=110,far=220}
    local mat=cache:GetResource("Material",asset.root.."Materials/"..asset.material):Clone()
    mat:SetTexture(TU_DIFFUSE,cache:GetResource("Texture2D",asset.root.."Textures/"..asset.stem.."_00_D.jpg"))
    mat:SetTexture(TU_NORMAL,cache:GetResource("Texture2D",asset.root.."Textures/"..asset.stem.."_00_N.jpg"))
    mat:SetShaderParameter("Metallic",Variant(0)); mat:SetShaderParameter("Roughness",Variant(.88))
    draw.material=mat; draw.castShadows=true; draw.drawDistance=400; draw.shadowDistance=85
    -- 低层实占条带仍取原模型；显示简化不参与碰撞和尺寸计算。
    -- 俯视：低墙/地基 [实占条带]；高处外挑屋檐不投成地面整块空气墙。
    -- 每条来自LOD0三角形与地面0..3.2m的裁剪，填满两侧墙之间的楼内。
    -- 地台与碰撞共用同一条带；保留低层墙脚、5cm可见地基唇，不全局缩障碍。
    local strips=Footprints.ForModel(model,scale)
    local records={}
    for _,rect in ipairs(strips) do
        local cx,cz=(rect.x1+rect.x2)/2,(rect.z1+rect.z2)/2
        local a=math.rad(yaw)
        local wx,wz=x+cx*math.cos(a)+cz*math.sin(a),z-cx*math.sin(a)+cz*math.cos(a)
        self.details:Box("concrete",wx,.08,wz,rect.x2-rect.x1,.24,rect.z2-rect.z1,yaw)
        local world=Footprints.WorldRect(rect,x,z,yaw)
        self.obstacles[#self.obstacles+1]=world
        records[#records+1]=world
    end
    self.buildingFootprints[#self.buildingFootprints+1]={name=name,model=model.name,node=body,draw=draw,
        bounds=bounds,scale=scale,x=x,z=z,yaw=yaw,strips=strips,obstacles=records}
    self.buildings=self.buildings+1
end

function City:BuildBlocks()
    -- 商业沿街和住宅留出连续步行通道；不以随机撒楼挤占导航折线。
    for i,x in ipairs({-140,-117,-70,-43,25,53,133,151}) do
        if i==3 or i==4 or i==5 or i==6 then
            self:DetailedBuilding(i%2==0 and 2 or 1,x,24,19,23,18,0,"沿街商住楼"..i)
        else
            self:Building(x,22,18,20,2+(i%3),i%2==0 and "plaster" or "brick",
                ({"街角面馆","日用百货","城南书店","老街五金","社区便利","修车铺","洗衣店","晨光餐馆"})[i],0)
        end
    end
    for i,x in ipairs({-142,-121,-72,-46,32,60,134,153}) do
        if i%2==0 then self:DetailedBuilding(3,x,139,18,23,20,180,"旧城公寓组"..i)
        else self:Building(x,139,17,22,3+(i%3),"plaster","南城公寓 "..i,180) end
    end
    for i,z in ipairs({-135,-104,-43,48,77,130}) do
        self:Building(-139,z,20,22,3+(i%2),"plaster","老街居民楼 "..i,90)
    end
    for i,z in ipairs({-133,-100,40,69,133}) do
        self:Building(139,z,22,23,4+(i%3),"stone","南城商务楼 "..i,-90)
    end
    self:Building(-25,-22,23,19,2,"brick","老 街 早 餐",180)
    self:Building(-123,80,24,24,5,"plaster","安居里 · 1号楼",90)
    self:Building(125,80,26,24,2,"stone","南 城 机 车",-90)
    self:Building(34,-34,30,18,4,"stone","南城创意办公",180)
    self:Building(-45,62,32,28,7,"stone","星桥写字楼",0)
    self:Building(51,58,35,30,8,"glass","南城商务中心",0)
end

function City:BuildPlaces()
    local d=self.details
    -- 公园入口、长椅与树池；交互点(108,-25)保持可达。
    d:Ground("grass",132,-42,42,46,.09)
    d:Ground("stone",120,-25,26,3,.10)
    d:Bench(110,-28,0)
    d:Sign("南城口袋公园",117,2.2,-20,0,.42)
    for _,pos in ipairs({{116,-51},{137,-28},{145,-52},{121,-62}}) do
        d:Box("stone",pos[1],.25,pos[2],3,.5,3)
        d:Bar("wood",Vector3(pos[1],.5,pos[2]),Vector3(pos[1],4,pos[2]),.32)
        -- 写实阔叶树模型（与赛道同一套资产），替换原代码绘制的球体树冠。
        Trees.Add(self.root,pos[1],.09,pos[2],8.5+pos[1]%3,pos[1]*13,true,false)
        self:Obstacle(pos[1],pos[2],.6,.6)
        d.trees=d.trees+1
    end
    -- 高架桥位于南片区，桥下通行，不放隐形横墙。
    d:Box("concrete",0,6,-70,76,1.1,17)
    for _,x in ipairs({-29,29}) do
        d:Box("concrete",x,2.7,-70,2.4,5.4,4)
        self:Obstacle(x,-70,2.4,4)
    end
    for _,z in ipairs({-78.5,-61.5}) do d:Box("metal",0,6.9,z,76,.7,.18) end
    -- 车道x[-6,6]、人行道[6,12]保持畅通；生活区在桥墩内侧x[14,25]。
    -- 两米交互圆(20,-68)与床/桌/水桶均分离，床有真实实占碰撞。
    local home=assert(Housing.Get("bridge"))
    d:Ground("stone",home.x,-70,12,12,.08)
    d:Box("wood",home.x,.15,-73,2.1,.18,1.0)
    d:Box("trim",home.x,.35,-73.3,.7,.24,.4)
    self:Obstacle(home.x,-73,2.35,1.15)
    d:Sign("桥下落脚点",home.x,2,-74,0,.38)
    d:Ground("concrete",-25,44,48,3,.078)
    for _,point in ipairs(Config.pointList) do
        if point.id=="noodle" or point.id=="convenience" or point.id=="office" then
            d:Sign(point.label,point.x,2.5,point.z,0,.34)
        end
    end
    for _,home in ipairs(Housing.List) do
        if home.width then
            d:Sign(home.name..string.format(" · %.0f元/晚",home.price/100),home.x,2.4,home.z,0,.32)
            d:Ground("paint",home.x,home.z,2.2,2.2,.084)
            self:NightLight(home.x,2.6,home.z,8,10)
        end
    end
    -- 充电桩和门厅标识与Config同源。
    d:Box("metal",24,.9,-9,.65,1.8,.65)
    d:Box("lamp",24,1.2,-9.35,.43,.36,.035)
    self:Obstacle(24,-9,.65,.65)
    for _,point in ipairs(Config.pointList) do
        if math.abs(point.x)<=180 and math.abs(point.z)<=180 then
            local marker=self.root:CreateChild("CareerMarker_"..point.id)
            marker.position=Vector3(point.x,.085,point.z)
            self.markers[point.id]=marker
            d:Ground(point.kind=="rest" and "paint" or "yellow",point.x,point.z,1.5,1.5,.083)
        end
    end
end

function City:NightLight(x,y,z,brightness,range)
    local node=self.root:CreateChild("夜间路灯")
    node.position=Vector3(x,y,z)
    local light=node:CreateComponent("Light")
    light.lightType=LIGHT_POINT; light.color=Color(1,.78,.46)
    light.range=range; light.brightness=brightness; light.castShadows=false; light.enabled=false
    self.nightLights[#self.nightLights+1]=light
end
function City:UpdateLights(hour)
    local on=hour>=17 or hour<7
    if self.lightsOn==on then return end
    self.lightsOn=on
    for _,light in ipairs(self.nightLights) do light.enabled=on end
    self.mats.lamp:SetShaderParameter("MatEmissiveColor",Variant(Color(on and 2 or .08,on and 1.55 or .06,on and .8 or .04)))
end
function City:SetSpace(id)
    self.space=id
    self.lightsOn=nil
    self.root:SetEnabledRecursive(id=="city")
    self.stream:SetVisible(id=="city")
    self.interior:SetSpace(id)
end
-- 地形在一帧内不变，而碰撞/接地每帧会查询上千次；按0.25m量化缓存，跨帧清空。
-- 量化误差远小于轮胎半径与接地容差，且不改变任何后续碰撞判定。
local SURFACE_QUANT=4
-- 每帧开始时由 Session 调用，丢弃上一帧的地形查询结果。
function City:BeginFrameCache()
    self.surfaceCache={}
    self.walkCache={}
end
function City:Surface(x,z)
    if self.space~="city" then return .085 end
    local cache=self.surfaceCache
    local key
    if cache then
        key=math.floor(x*SURFACE_QUANT)*100003+math.floor(z*SURFACE_QUANT)
        local hit=cache[key]
        if hit~=nil then return hit end
    end
    local value=self:ComputeSurface(x,z)
    if cache then cache[key]=value end
    return value
end
---@param x number
---@param z number
---@return number
function City:ComputeSurface(x,z)
    local environment=Environment.Surface(x,z)
    if environment~=nil then return environment end
    local hill=require("Career.HillDistrict").Surface(x,z)
    if hill~=nil then return hill end
    if World.IsOld(x,z) then return self.details:Surface(x,z) end
    return math.max(self.details:Surface(x,z),World.Surface(x,z,"vehicle",0))
end
function City:WalkSurface(x,z,height)
    if self.space~="city" then return .085 end
    local environment=Environment.Surface(x,z)
    if environment~=nil then return environment end
    if require("Career.HillDistrict").Contains(x,z) then return World.Surface(x,z,"walk",height or 0) end
    if World.IsOld(x,z) then return self.details:Surface(x,z) end
    return math.max(self.details:Surface(x,z),World.Surface(x,z,"walk",height or 0))
end
function City:FlatHeight(x1,z1,x2,z2)
    return require("Career.FlatSurface").Height(self,x1,z1,x2,z2)
end
function City:UpdateStreaming(x,z)
    if self.space=="city" then
        self.stream:Update(x,z)
        self.displayBuildingTick=self.displayBuildingTick+1
        if self.displayBuildingTick%8==0 then DisplayLod.Update(self.displayBuildings,x,z) end
    end
end

-- 侧视接触设计（米）： rear<0 --- 车根0 --- front>0。
-- 前后触地点分别采样；前轮上坎先抬车头，后轮仍落旧路面，停车跨坎同样适用。
-- 地表最高仅10cm，两次投影迭代处理俯仰后的轮距收缩，不改变XZ碰撞域。
---@param x number
---@param z number
---@param yaw number
---@param front number
---@param rear number
---@return number, number
function City:VehicleSurface(x,z,yaw,front,rear)
    local a=math.rad(yaw)
    local pitch,y=0,self:Surface(x,z)
    for _=1,2 do
        local projection=math.cos(math.rad(pitch))
        local fh=self:Surface(x+math.sin(a)*front*projection,z+math.cos(a)*front*projection)
        local rh=self:Surface(x+math.sin(a)*rear*projection,z+math.cos(a)*rear*projection)
        pitch=-math.deg(math.asin(math.max(-1,math.min(1,(fh-rh)/(front-rear)))))
        y=(rh*front-fh*rear)/(front-rear)
    end
    return y,pitch
end

function City:IsFree(x,z,radius,mode,height)
    return Collision.ShapeFree(self,Footprint.Circle(0,0,radius),x,z,0,mode,height)
end
function City:StaticFree(x,z,radius,mode,height)
    return Collision.ShapeFree(self,Footprint.Circle(0,0,radius),x,z,0,mode,height,nil,true)
end

-- Oriented visible-shell footprint API. The circle API remains available for
-- pedestrians, navigation checks and older callers; no vehicle radius leaks in.
function City:IsShapeFree(x,z,shape,yaw,mode,height,ignoreId)
    return Collision.ShapeFree(self,shape,x,z,yaw,mode,height,ignoreId)
end
function City:StaticShapeFree(x,z,shape,yaw,mode,height,posed,candidates)
    if posed then return Collision.PosedFree(self,posed,shape,x,z,mode,height,nil,true,candidates) end
    return Collision.ShapeFree(self,shape,x,z,yaw,mode,height,nil,true)
end
function City:MoveShape(x,z,dx,dz,shape,yaw,mode,height,ignoreId)
    return Collision.Move(self,x,z,dx,dz,shape,yaw,mode,height,ignoreId)
end
function City:FindShapeFree(x,z,shape,yaw,mode,height,ignoreId)
    return Collision.Find(self,x,z,shape,yaw,mode,height,ignoreId)
end

---@param x number
---@param z number
---@param radius number
---@param mode? string
---@param height? number
---@return number,number
function City:FindFree(x,z,radius,mode,height)
    return Collision.Find(self,x,z,Footprint.Circle(0,0,radius),0,mode,height)
end

-- Every segment is a continuous rounded-circle / polygon cast. Thin poles and
-- vehicle corners cannot fall between samples; oblique tangency remains free.
function City:StaticSegmentFree(ax,az,bx,bz,radius,mode,height)
    return Collision.SegmentFree(self,ax,az,bx,bz,radius,mode,height)
end

function City:Move(x,z,dx,dz,radius,mode,height)
    return Collision.Move(self,x,z,dx,dz,Footprint.Circle(0,0,radius),0,mode,height)
end

function City:GetMarker(id) return self.markers[id] end
function City:GetStats() return self.stats end
function City:Dispose()
    if self.disposed then return end
    self.disposed=true
    self.stream:Dispose()
    self.contacts:Dispose()
    local dressing=self.streetDressing --[[@as CareerStreetDressing]]
    dressing:Dispose()
    self.root:Dispose()
    for _,entry in ipairs(self.displayBuildings) do DisplayLod.Release(entry.levels) end
    self.displayBuildings={}
end
return City
