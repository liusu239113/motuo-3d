-- 基于三维场景脚手架和现有 Landscape 材质，城市为固定米制世界，不跟随玩家平移。
local Details = require("Career.CityDetails")
local Landscape = require("Landscape")
local Parts = require("Parts")
local Config = require("Career.Config")
local Housing = require("Career.HousingData")
local Interior = require("Career.Interior")
---@class CareerCity
---@field SetSpace fun(self:CareerCity,id:string)
---@field UpdateLights fun(self:CareerCity,hour:number)
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
for _, path in ipairs(Landscape.Resources) do
    City.Resources[#City.Resources + 1] = path
    City.ResourceTypes[path] = Landscape.ResourceTypes[path]
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
    self.space="city"
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
    self:BuildBlocks()
    self:BuildPlaces()
    self.stats = self.details:Finish()
    self.interior=Interior.New(scene,self.mats)
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
                self:NightLight(x-7.8,4.2,z,5,12)
            end
        end
    end
end

-- 碰撞设计（俯视，米）：建筑实体AABB；移动圆r经AABB各边外扩r检测。
--   道路 -> 人行道 -> 门前交互圆(2m) -> [建筑实体]
-- 不把门前圆放进墙体；短步沿X/Z分轴滑移，最大步长0.1m，避免薄墙穿越。
-- 读档使用FindFree恢复到邻近空位；普通移动只沿切向滑移，边界±180减半径。
function City:Obstacle(x,z,w,depth)
    self.obstacles[#self.obstacles+1] = {x1=x-w/2,x2=x+w/2,z1=z-depth/2,z2=z+depth/2}
end

function City:Building(x,z,w,depth,floors,style,name,yaw)
    local d = self.details
    local h = floors*3.05+1.0
    local angle = math.rad(yaw or 0)
    local function p(px,pz) return x+px*math.cos(angle)+pz*math.sin(angle),z-px*math.sin(angle)+pz*math.cos(angle) end
    d:Box(style,x,h/2+.08,z,w,h,depth,yaw)
    d:Box("concrete",x,.35,z,w+.25,.55,depth+.25,yaw)
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
    root.position=Vector3(x,.085,z); root.rotation=Quaternion(0,yaw,0)
    local body=root:CreateChild("写实建筑")
    body:SetScale(scale)
    body.position=Vector3(-bounds.center.x*scale,-bounds.min.y*scale,-bounds.center.z*scale)
    local draw=body:CreateComponent("StaticModel")
    draw.model=model
    local mat=cache:GetResource("Material",asset.root.."Materials/"..asset.material):Clone()
    mat:SetTexture(TU_DIFFUSE,cache:GetResource("Texture2D",asset.root.."Textures/"..asset.stem.."_00_D.jpg"))
    mat:SetTexture(TU_NORMAL,cache:GetResource("Texture2D",asset.root.."Textures/"..asset.stem.."_00_N.jpg"))
    mat:SetShaderParameter("Metallic",Variant(0)); mat:SetShaderParameter("Roughness",Variant(.88))
    draw.material=mat; draw.castShadows=true; draw.drawDistance=400; draw.shadowDistance=85
    local angle=math.rad(yaw)
    local sx,sz=bounds.size.x*scale,bounds.size.z*scale
    self:Obstacle(x,z,math.abs(math.cos(angle))*sx+math.abs(math.sin(angle))*sz,
        math.abs(math.sin(angle))*sx+math.abs(math.cos(angle))*sz)
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
        -- 共享球网格作多层树冠，不用墙面贴纸代替立体绿化。
        local tree=self.root:CreateChild("公园树")
        tree.position=Vector3(pos[1],4.6,pos[2]); tree.scale=Vector3(4.5,4,4.5)
        local mesh=tree:CreateComponent("StaticModel")
        mesh.model=cache:GetResource("Model","Models/Sphere.mdl"); mesh.material=self.mats.foliage
        mesh.castShadows=true; mesh.drawDistance=200
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
    d:Ground("stone",0,-70,17,12,.08)
    d:Box("wood",2,.15,-73,2.1,.18,1.0)
    d:Box("trim",2,.35,-73.3,.7,.24,.4)
    d:Sign("桥下落脚点",0,2,-74,0,.38)
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
            self:NightLight(home.x,2.6,home.z,3,8)
        end
    end
    -- 充电桩和门厅标识与Config同源。
    d:Box("metal",24,.9,-9,.65,1.8,.65)
    d:Box("lamp",24,1.2,-9.35,.43,.36,.035)
    self:Obstacle(24,-9,.65,.65)
    for _,point in ipairs(Config.pointList) do
        local marker=self.root:CreateChild("CareerMarker_"..point.id)
        marker.position=Vector3(point.x,.085,point.z)
        self.markers[point.id]=marker
        d:Ground(point.kind=="rest" and "paint" or "yellow",point.x,point.z,1.5,1.5,.083)
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
    local on=hour>=18 or hour<6
    for _,light in ipairs(self.nightLights) do light.enabled=on end
end
function City:SetSpace(id)
    self.space=id
    self.root:SetEnabledRecursive(id=="city")
    self.interior:SetSpace(id)
end
function City:Surface(x,z) return .085 end

function City:IsFree(x,z,radius)
    if self.space~="city" then return self.interior:IsFree(x,z,radius) end
    if math.abs(x)>180-radius or math.abs(z)>180-radius then return false end
    for _,o in ipairs(self.obstacles) do
        if x>o.x1-radius and x<o.x2+radius and z>o.z1-radius and z<o.z2+radius then return false end
    end
    return true
end

function City:FindFree(x,z,radius)
    if self.space~="city" then return self.interior:FindFree(x,z,radius) end
    local limit=180-radius
    local px,pz=math.max(-limit,math.min(limit,x)),math.max(-limit,math.min(limit,z))
    if self:IsFree(px,pz,radius) then return px,pz end
    for distance=1,50 do
        for step=1,24 do
            local angle=step*math.pi/12
            local nx,nz=px+math.sin(angle)*distance,pz+math.cos(angle)*distance
            if self:IsFree(nx,nz,radius) then return nx,nz end
        end
    end
    return 0,-20
end

function City:Move(x,z,dx,dz,radius)
    if self.space~="city" then return self.interior:Move(x,z,dx,dz,radius) end
    local count=math.max(1,math.ceil(math.sqrt(dx*dx+dz*dz)/.1))
    local sx,sz=dx/count,dz/count
    for _=1,count do
        if self:IsFree(x+sx,z,radius) then x=x+sx end
        if self:IsFree(x,z+sz,radius) then z=z+sz end
    end
    return x,z
end

function City:GetMarker(id) return self.markers[id] end
function City:GetStats() return self.stats end
function City:Dispose() self.root:Dispose() end
return City
