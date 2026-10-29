-- Street dressing for the EXISTING City, based on scaffold-3d-scene.lua / CityDetails.
-- References read: examples/18-physics-collision-3d.lua,
-- examples/25-surface-custom-light-scene/scripts/main.lua,
-- examples/07-minecraft-voxel-world/terrain/HouseGenerator.lua.
-- Build ONCE after BuildPlaces(), BEFORE details:Finish(). No UI, save IO or Update.
-- Existing solid buildings remain solid: the shop interiors are shallow display layers,
-- not enterable rooms. Artwork is an orthographic albedo, never a screenshot billboard.
local Config = require("Career.Config")
local Pedestrians = require("Career.Pedestrians")
local Parts = require("Parts")
local V = Vector3
local PREFIX = "street_"
local BREAKFAST = "image/career_breakfast_shopfront_albedo_20261029100357.png"
local REPAIR = "image/career_local_shopfront_albedo_20261029100354.png"
local SIGN = "image/career_breakfast_sign_albedo.png"
local NOODLE = "image/career_noodle_storefront_20261029115605.png"
local CONVENIENCE = "image/career_convenience_storefront_20261029115547.png"
local OFFICE = "image/career_office_lobby_front_20261029115544.png"
local BRICK = "uuid://DXjwQX_lcF60zC4F9y9yAyG_"
local METAL = "uuid://Cis1sX30rhdTXVgC4QEwquGW"
local FABRIC = "uuid://FsRPCfK_BAj7uc2vemxZwSA8"

---@class StreetVolume
---@field id string
---@field kind string
---@field x1 number
---@field x2 number
---@field z1 number
---@field z2 number
---@field y1 number
---@field y2 number
---@field collision boolean
---@field exception? string
---@class StreetFace
---@field id string
---@field path string
---@field geometry CustomGeometry
---@field material Material
---@field width number
---@field height number
---@field uv string
---@class CareerStreetDressing
---@field city CareerCity
---@field details CityDetails
---@field root Node
---@field owned Material[]
---@field textures Texture2D[]
---@field materials table<string,Material>
---@field batchKeys string[]
---@field volumes StreetVolume[]
---@field faces StreetFace[]
---@field collisions table[]
---@field surfaceSnapshot table[]
---@field probes table[]
---@field routeSnapshot string
---@field surfaceSignature string
---@field disposed boolean
---@field counters table<string,number>
---@field Dispose fun(self:CareerStreetDressing)
---@field Stats fun(self:CareerStreetDressing):table
---@field Validate fun(self:CareerStreetDressing):table
local Dressing = {}
Dressing.__index = Dressing
Dressing.Resources = {
    BREAKFAST, REPAIR, SIGN, NOODLE, CONVENIENCE, OFFICE, BRICK, METAL, FABRIC,
    "Techniques/PBR/PBRDiff.xml", "Techniques/PBR/PBRDiffNormal.xml",
    "Techniques/PBR/PBRNoTexture.xml", "Models/Cylinder.mdl", "Models/Torus.mdl",
}
Dressing.ResourceTypes = {
    [BREAKFAST]="Texture2D", [REPAIR]="Texture2D", [SIGN]="Texture2D",
    [NOODLE]="Texture2D", [CONVENIENCE]="Texture2D", [OFFICE]="Texture2D",
    [BRICK]="Material", [METAL]="Material", [FABRIC]="Material",
    ["Techniques/PBR/PBRDiff.xml"]="Technique",
    ["Techniques/PBR/PBRDiffNormal.xml"]="Technique",
    ["Techniques/PBR/PBRNoTexture.xml"]="Technique",
    ["Models/Cylinder.mdl"]="Model", ["Models/Torus.mdl"]="Model",
}

local function routeSignature()
    local entries = {}
    for _, order in ipairs(Config.orderTemplates) do
        entries[#entries+1] = order.id
        for _, point in ipairs(order.route) do
            entries[#entries+1] = string.format("%.9f,%.9f",point.x,point.z)
        end
    end
    return table.concat(entries,"|")
end

local function surfaceSignature(details)
    local entries = {}
    for _, s in ipairs(details.surfaces) do
        entries[#entries+1] = string.format("%.9f,%.9f,%.9f,%.9f,%.9f",s.x,s.z,s.w,s.d,s.y)
    end
    return table.concat(entries,"|")
end

---@param city CareerCity
---@return CareerStreetDressing
function Dressing.New(city)
    local self = setmetatable({},Dressing)
    self:Init(city)
    return self
end

---@param city CareerCity
function Dressing:Init(city)
    self.city, self.details = city, city.details
    self.root = city.root:CreateChild("老街门面与桥下生活细节")
    self.owned, self.textures, self.materials = {}, {}, {}
    self.batchKeys, self.volumes, self.faces, self.collisions = {}, {}, {}, {}
    self.surfaceSnapshot, self.probes = {}, {}
    self.routeSnapshot = routeSignature()
    self.surfaceSignature = surfaceSignature(self.details)
    self.disposed = false
    self.counters = {boxes=0,quads=0,tubes=0,models=0,signs=0,drains=0,shopfronts=0,storeProps=0,canopies=0}
    for _, surface in ipairs(self.details.surfaces) do
        self.surfaceSnapshot[#self.surfaceSnapshot+1] = surface
    end
    for _, p in ipairs({{-25,-8},{-25,-12},{24,-8},{24,-13},{0,-70},{9,-70},{15,-75},
        {-70,9},{-70,12},{53,9},{53,12},{-45,44},{-45,47.5}}) do
        self.probes[#self.probes+1] = {x=p[1],z=p[2],y=self.details:Surface(p[1],p[2])}
    end
    -- Namespace batches so teardown can remove ONLY this module's geometry. Borrowed
    -- materials are not mutated/disposed; newly allocated materials are explicitly owned.
    for _, key in ipairs({"wood","concrete","stone","metal","trim","frame","recess","foliage","lamp","paint","yellow"}) do
        self.materials[key] = assert(city.mats[key],"StreetDressing: missing city material "..key)
        self.details.mats[PREFIX..key] = self.materials[key]
    end
    self:Textured("brick",BRICK,Color(.73,.63,.53),.92,0)
    self:Textured("steel",METAL,Color(.70,.72,.68),.47,.8)
    self:Textured("canvas",FABRIC,Color(.52,.26,.16),.96,0)
    self:Textured("canvasLight",FABRIC,Color(.91,.82,.61),.96,0)
    self:Own("teal",Parts.Material(.11,.26,.24,.79,.12))
    self:Own("enamel",Parts.Material(.68,.73,.67,.43,.18))
    self:Own("red",Parts.Material(.42,.13,.08,.80,0))
    self:Own("paper",Parts.Material(.76,.59,.35,.98,0))
    self:Own("screen",Parts.Material(.08,.26,.19,.6,0,.36))
    -- Acquire all art before building: missing required artwork is a hard failure.
    self:Artwork("breakfastArt",BREAKFAST)
    self:Artwork("repairArt",REPAIR)
    self:Artwork("breakfastSign",SIGN)
    self:Artwork("noodleArt",NOODLE)
    self:Artwork("convenienceArt",CONVENIENCE)
    self:Artwork("officeArt",OFFICE)
    self:Breakfast()
    self:DeliveryFrontages()
    self:OfficeLobby()
    self:Charging()
    self:Bridge()
    self:Drainage()
    for key in pairs(self.details.batches) do
        if key:find(":"..PREFIX,1,true) then self.batchKeys[#self.batchKeys+1] = key end
    end
    local report = self:Validate()
    assert(report.ok,"StreetDressing: "..table.concat(report.errors,"; "))
    local stats = self:Stats()
    print(string.format("[老街街面] 门面%d / 0..1UV图层%d / 合批%d / 实体碰撞%d / 排水细节%d；路面/导航未改",
        stats.shopfronts,stats.artworkFaces,stats.batches,stats.obstacles,stats.drains))
end

---@param key string
---@param material Material
function Dressing:Own(key,material)
    self.owned[#self.owned+1] = material
    self.materials[key] = material
    self.details.mats[PREFIX..key] = material
end

-- Reuse genuine color/normal maps, but match the vertex layout used by CityDetails.
-- Do not clone old editor shaders blindly, and do not modify cache-shared materials.
function Dressing:Textured(key,path,tint,roughness,metallic)
    local source = assert(cache:GetResource("Material",path),"StreetDressing: missing material "..path)
    local color = assert(source:GetTexture(TU_DIFFUSE),"StreetDressing: missing diffuse "..path)
    local normal = assert(source:GetTexture(TU_NORMAL),"StreetDressing: missing normal "..path)
    local material = Material:new()
    material:SetTechnique(0,assert(cache:GetResource("Technique","Techniques/PBR/PBRDiffNormal.xml")))
    material:SetTexture(TU_DIFFUSE,color)
    material:SetTexture(TU_NORMAL,normal)
    material:SetShaderParameter("MatDiffColor",Variant(tint))
    material:SetShaderParameter("Roughness",Variant(roughness))
    material:SetShaderParameter("Metallic",Variant(metallic))
    self:Own(key,material)
end

function Dressing:Artwork(key,path)
    local texture = assert(cache:GetResource("Texture2D",path),"StreetDressing: missing shopfront "..path)
    assert(texture.width>=512 and texture.height>=256,"StreetDressing: artwork unavailable/placeholder "..path)
    self.textures[#self.textures+1] = texture -- Borrowed cache resources: hold, never Dispose shared textures.
    local material = Material:new()
    material:SetTechnique(0,assert(cache:GetResource("Technique","Techniques/PBR/PBRDiff.xml")))
    material:SetTexture(TU_DIFFUSE,texture)
    material:SetShaderParameter("MatDiffColor",Variant(Color(.95,.94,.88)))
    material:SetShaderParameter("Roughness",Variant(.84))
    material:SetShaderParameter("Metallic",Variant(0))
    -- A little window light preserves visibility in shade, not a fullbright photograph.
    material:SetShaderParameter("MatEmissiveColor",Variant(Color(.035,.028,.018)))
    self:Own(key,material)
end

function Dressing:Box(mat,x,y,z,w,h,depth,yaw)
    self.details:Box(PREFIX..mat,x,y,z,w,h,depth,yaw)
    self.counters.boxes = self.counters.boxes+1
end
function Dressing:Quad(mat,a,b,c,d,tile)
    self.details:Quad(PREFIX..mat,a,b,c,d,tile)
    self.counters.quads = self.counters.quads+1
end

-- Collision design (top view, metres):
-- breakfast facade z<=-12.02 | FULL 6m walk [-12,-6] | road [-6,+6]
-- charge rear posts z<=-12.4 | existing charger only | no new POI obstruction
-- bridge furniture x>=14   | walk [6,12] | road [-6,6] | west actors untouched
-- Low solid volumes register their actual XZ projection. No canopy-sized invisible
-- obstacle: awnings are overhead (>2.7m), drainage is flush and has no step collider.
-- Tangencies use strict rectangle overlap; 2m POI circles use closest-point distance.
function Dressing:Volume(id,kind,x,y,z,w,h,depth,collision,exception)
    local volume = {id=id,kind=kind,x1=x-w/2,x2=x+w/2,z1=z-depth/2,z2=z+depth/2,
        y1=y-h/2,y2=y+h/2,collision=collision,exception=exception}
    self.volumes[#self.volumes+1] = volume
    if collision then
        self.city:Obstacle(x,z,w,depth)
        self.collisions[#self.collisions+1] = self.city.obstacles[#self.city.obstacles]
    end
end

function Dressing:Solid(id,mat,x,y,z,w,h,depth)
    self:Box(mat,x,y,z,w,h,depth)
    self:Volume(id,"solid",x,y,z,w,h,depth,true)
end

function Dressing:Tube(mat,a,b,diameter)
    local node = Parts.Bar(self.root,self.materials[mat],a,b,diameter/2)
    local draw = node:GetComponent("StaticModel")
    draw.drawDistance, draw.shadowDistance = 105,45
    self.counters.tubes = self.counters.tubes+1
end

function Dressing:Sign(text,x,y,z,yaw,height,color)
    local node = self.root:CreateChild("StreetSign_"..text)
    -- Text3D 的正面与门面网格法线不同；北立面字朝街道 +Z。
    local textYaw=yaw==180 and 0 or yaw
    node.position, node.rotation = V(x,y,z),Quaternion(0,textYaw,0)
    node:SetScale(height*2)
    local label = node:CreateComponent("Text3D")
    assert(label:SetFont(self.details.font,64),"StreetDressing: sign font rejected")
    label.text, label.color = text,color or Color(.93,.87,.68)
    label:SetAlignment(HA_CENTER,VA_CENTER)
    label.textAlignment, label.faceCameraMode = HA_CENTER,FC_NONE
    label.fixedScreenSize, label.castShadows = false,false
    label.drawDistance = 65
    self.counters.signs = self.counters.signs+1
    self.details.signs = self.details.signs+1
end

-- Dedicated single face: ONE complete door-and-two-window artwork, normalized UVs.
-- CityDetails:Quad intentionally has world-metre UVs; never use it for this layer.
function Dressing:Face(id,key,path,x,y,z,w,h,yaw)
    local node = self.root:CreateChild("StreetAlbedo_"..id)
    node.position, node.rotation = V(x,y,z),Quaternion(0,yaw,0)
    local geometry = node:CreateComponent("CustomGeometry")
    geometry:BeginGeometry(0,TRIANGLE_LIST)
    local function vertex(px,py,u,v)
        geometry:DefineVertex(V(px,py,0))
        geometry:DefineNormal(V(0,0,-1))
        geometry:DefineTexCoord(Vector2(u,v))
    end
    vertex(-w/2,-h/2,0,1); vertex(-w/2,h/2,0,0); vertex(w/2,-h/2,1,1)
    vertex(w/2,-h/2,1,1); vertex(-w/2,h/2,0,0); vertex(w/2,h/2,1,0)
    assert(geometry:GenerateTangents(),"StreetDressing: artwork tangent generation failed")
    geometry:Commit()
    local material = assert(self.materials[key])
    geometry:SetMaterial(material)
    geometry.castShadows, geometry.drawDistance = false,135
    self.faces[#self.faces+1] = {id=id,path=path,geometry=geometry,material=material,width=w,height=h,uv="0..1, once"}
    self.counters.shopfronts = self.counters.shopfronts+(id=="breakfast_sign" and 0 or 1)
end

-- The existing north face is z=-12.5 (yaw 180). No old shell/window is moved.
function Dressing:Breakfast()
    -- Continuous textured skin covers the old first-floor toy windows, but never the
    -- second floor or old roof. Its collider is EXACTLY the visible continuous panel.
    self:Solid("breakfast facade backing","brick",-25,1.51,-12.28,22.7,2.86,.40)
    self:Face("breakfast","breakfastArt",BREAKFAST,-25,1.55,-12.065,7.7,2.88,180)
    self:Face("repair","repairArt",REPAIR,-16.45,1.55,-12.065,5.1,2.88,180)
    -- Physical frame on top of the albedo: light catches edges, sills cast real shadows.
    for _, data in ipairs({{x=-25,w=7.7,mat="steel"},{x=-16.45,w=5.1,mat="teal"}}) do
        local left,right = data.x-data.w/2,data.x+data.w/2
        for _, x in ipairs({left,right}) do self:Box(data.mat,x,1.55,-12.045,.055,2.88,.04) end
        for _, y in ipairs({.14,2.96}) do self:Box(data.mat,data.x,y,-12.045,data.w,.055,.04) end
        -- Art's door occupies the middle 22%: mullions follow, not random subdivisions.
        for _, side in ipairs({-1,1}) do
            self:Box(data.mat,data.x+side*data.w*.111,1.56,-12.043,.045,2.78,.04)
            self:Box("steel",data.x+side*data.w*.305,.99,-12.045,data.w*.36,.055,.045)
        end
    end
    -- Main pickup ledge is a shallow metal return at the right window, not a street stall.
    self:Solid("pickup counter lip","steel",-22.67,1.02,-12.045,2.28,.075,.045)
    self:Sign("取 餐 口",-22.67,1.27,-12.014,180,.16,Color(.97,.89,.65))
    self:Sign("早 餐 现 做  ·  打 包 带 走",-25,2.69,-12.015,180,.15)
    -- Keep old sign behind a real new light-box fascia, instead of stacking floating text.
    self:Box("red",-25,3.28,-12.20,12.5,.85,.34)
    self:Box("steel",-25,3.72,-12.18,12.65,.055,.40)
    self:Box("red",-25,3.24,-12.021,11.95,.62,.012)
    self:Face("breakfast_sign","breakfastSign",SIGN,-25,3.26,-11.94,3.2,.72,180)
    self:Box("teal",-16.45,3.28,-12.20,5.15,.85,.34)
    self:Sign("老 街 修 配",-16.45,3.28,-12.015,180,.32)
    self:Sign("补胎  ·  配件  ·  便民维修",-16.45,2.76,-12.014,180,.13)
    -- West service bay: raised metal shutter, framed handwritten-style menu board,
    -- brick pier and meter box. It is not a third copy of the same shop artwork.
    self:Box("steel",-33.5,1.58,-12.064,4.5,2.82,.025)
    for i=1,20 do self:Box("metal",-33.5,.20+i*.132,-12.041,4.47,.023,.022) end
    self:Box("wood",-33.5,1.54,-12.027,1.65,1.56,.012)
    self:Box("recess",-33.5,1.54,-12.017,1.48,1.39,.008)
    self:Sign("今 日 早 点",-33.5,2.04,-12.006,180,.19)
    self:Sign("热豆浆   手工包子",-33.5,1.69,-12.006,180,.12)
    self:Sign("白粥   鸡蛋   油条",-33.5,1.39,-12.006,180,.12)
    self:Sign("06:00 — 11:00",-33.5,1.08,-12.006,180,.12)
    self:Box("teal",-33.5,3.28,-12.2,5.1,.85,.34)
    self:Sign("一 口 热 乎  ·  一 天 精 神",-33.5,3.26,-12.015,180,.21)
    self:Awning(-25,-12.08,11.8,1.16)
    self:Awning(-16.45,-12.08,5.12,.88)
    -- A narrow downpipe hugs each end pier, entirely behind the walk boundary.
    for _, x in ipairs({-36.22,-13.75}) do
        self:Tube("metal",V(x,.13,-12.12),V(x,3.68,-12.12),.09)
        self:Volume("facade downpipe","solid",x,1.90,-12.12,.09,3.55,.09,true)
        for _, y in ipairs({.6,2.2,3.4}) do self:Box("steel",x,y,-12.086,.14,.055,.07) end
    end
end

function Dressing:Awning(x,z,w,depth,direction,rise)
    local offset = depth*(direction or 1)
    local y = rise or 0
    local count = math.max(8,math.floor(w/.46))
    local strip = w/count
    for i=1,count do
        local l,r = x-w/2+(i-1)*strip,x-w/2+i*strip
        local mat = i%2==0 and "canvas" or "canvasLight"
        -- Both sides have correct normals; the real sloping cloth is not a flat box.
        self:Quad(mat,V(l,y+3.07,z),V(l,y+2.84,z+offset),V(r,y+3.07,z),V(r,y+2.84,z+offset),2)
        self:Quad(mat,V(r,y+3.067,z),V(r,y+2.837,z+offset),V(l,y+3.067,z),V(l,y+2.837,z+offset),2)
        self:Box(mat,(l+r)/2,y+2.80,z+offset,strip,.14,.035)
    end
    self:Tube("steel",V(x-w/2,y+2.85,z+offset),V(x+w/2,y+2.85,z+offset),.04)
    for _, side in ipairs({-1,1}) do
        local px = x+side*(w/2-.12)
        self:Tube("steel",V(px,y+2.76,z),V(px,y+2.85,z+offset),.035)
    end
    self:Volume("wall-mounted cloth awning","overhead",x,y+2.925,z+offset/2,w,.39,depth+.04,false)
    self.counters.canopies = self.counters.canopies+1
end

-- The three delivery stops now have a recognisable ground-floor frontage, NOT more
-- random buildings. LOD0 bounds were measured with model-info: at City's 18m height
-- the two existing shop buildings start around z=16.48 / 17.11. Narrow side returns
-- connect to them; every wall collider below is exactly its visible masonry Box.
--
-- top view, metres (south/front is -Z):
--     old building z>=16.48          office old shell z>=48
--       | real side returns |       [ stone return / glass image ] z=47.52
--       [ facade z=12.30 ]              (POI -45,44) -- route z44 --> x0
--       NO ground furniture z<12       no step / planter on this route
--       resident(-72.7,10.9)
--       (POIs z9)   pedestrian path z8.7, r=.32
--       full six-metre sidewalk [6,12] / lanes [-6,6]
-- Edge cases: sill projection stops at12.045, drain is flush; overhead awning is
-- >3.5m clear with NO XZ collider. No registered ground heights or routes change.
function Dressing:DeliveryFrontages()
    for _,shop in ipairs({
        {id="noodle",x=-70,key="noodleArt",path=NOODLE,wall="brick",frame="wood",back=17.15},
        {id="convenience",x=53,key="convenienceArt",path=CONVENIENCE,wall="concrete",frame="teal",back=17.70},
    }) do
        local x,z = shop.x,12.50
        self:Solid(shop.id.." visible backing",shop.wall,x,1.80,z,5.30,3.44,.40)
        self:Face(shop.id,shop.key,shop.path,x,1.80,12.285,5.10,3.40,0)
        for _,side in ipairs({-1,1}) do
            self:Solid(shop.id.." recessed wing",shop.wall,x+side*3.55,1.80,12.87,1.90,3.44,.40)
            local px=x+side*4.39
            local depth=shop.back-12.30
            self:Solid(shop.id.." masonry side return",shop.wall,px,1.80,12.30+depth/2,.22,3.44,depth)
            -- Front piers and stepped window plinths are outside the public walk.
            self:Box(shop.frame,x+side*2.60,1.80,12.262,.065,3.44,.055)
            self:Solid(shop.id.." wing plinth","stone",x+side*3.48,.19,12.38,1.60,.22,.60)
            self:Box("steel",x+side*3.48,.34,12.35,1.63,.055,.56)
        end
        -- Cap the narrow addition in real textured materials, not an opaque block
        -- projecting a fake entire-store collider onto the pedestrian route.
        self:Box("concrete",x,3.60,(12.30+shop.back)/2,9.12,.16,shop.back-12.20)
        self:Volume(shop.id.." first-floor lintel","overhead",x,3.60,(12.30+shop.back)/2,
            9.12,.16,shop.back-12.20,false)
        -- The art is 3:2, not the requested panorama. Preserve aspect and follow its
        -- real door/window layout: noodle centre door22%, convenience centre32%.
        local doorFraction=shop.id=="noodle" and .111 or .162
        for _,side in ipairs({-1,1}) do
            self:Box(shop.frame,x+side*5.10*doorFraction,1.46,12.251,.042,2.60,.055)
            self:Box("steel",x+side*1.61,.98,12.18,1.48,.075,.27)
        end
        self:Box(shop.frame,x,3.525,12.25,5.22,.055,.06)
        self:Box("stone",x,.105,12.29,5.22,.045,.44) -- shallow threshold, no new surface
        self:Grate(shop.id.." threshold drain",x,12.065,2.05,.075)
        self:Awning(x,12.37,8.9,1.12,-1,.88)
        -- Genuine weathered shop fabric + paper/metal wing notices; never repeat the
        -- breakfast or repair photograph to pretend it is a different business.
        self:Box("wood",x-3.48,1.70,12.642,1.17,1.70,.035)
        self:Box("recess",x-3.48,1.70,12.615,1.04,1.56,.020)
        if shop.id=="noodle" then
            self:Sign("现 煮 热 面",x-3.48,2.20,12.591,0,.17)
            self:Sign("牛肉面  鸡蛋面",x-3.48,1.88,12.591,0,.105)
            self:Sign("堂食  ·  打包",x-3.48,1.57,12.591,0,.12)
            self:Sign("取餐请核对尾号",x-3.48,1.22,12.591,0,.105)
            self:NoodleCounter(x+3.48,12.48)
        else
            self:Sign("邻 里 便 民",x-3.48,2.20,12.591,0,.17)
            self:Sign("饮水  ·  日用品",x-3.48,1.88,12.591,0,.11)
            self:Sign("取货请报尾号",x-3.48,1.55,12.591,0,.11)
            self:Sign("营业 07:00—23:00",x-3.48,1.23,12.591,0,.09)
            self:ShopRack(x+3.48,12.48)
        end
        -- Wall drainpipes end at actual feet; never put a detached pole in the POI.
        for _,side in ipairs({-1,1}) do
            local px=x+side*4.18
            self:Tube("metal",V(px,.13,12.39),V(px,3.43,12.39),.065)
            for _,py in ipairs({.55,2.55}) do self:Box("steel",px,py,12.34,.12,.045,.11) end
        end
    end
end

-- Small revolved wares use the SAME material/chunk batches as the facade. Profiles
-- are in metres, including hollow bowl/cup inner walls. No new asset per bottle.
function Dressing:Lathe(mat,x,y,z,profile,segments)
    local count=segments or 12
    for row=1,#profile-1 do
        local a,b=profile[row],profile[row+1]
        for i=1,count do
            local t0,t1=(i-1)*2*math.pi/count,i*2*math.pi/count
            local ar,br=math.max(.001,a[1]),math.max(.001,b[1])
            self:Quad(mat,V(x+br*math.cos(t0),y+b[2],z+br*math.sin(t0)),
                V(x+br*math.cos(t1),y+b[2],z+br*math.sin(t1)),
                V(x+ar*math.cos(t0),y+a[2],z+ar*math.sin(t0)),
                V(x+ar*math.cos(t1),y+a[2],z+ar*math.sin(t1)),2)
        end
    end
    self.counters.storeProps=self.counters.storeProps+1
end

function Dressing:NoodleCounter(x,z)
    -- A narrow pickup shelf attached to the wing, with visible legs (not a cube stall).
    self:Box("wood",x,.96,z,.96,.08,.63)
    for _,side in ipairs({-1,1}) do self:Box("steel",x+side*.39,.52,z,.045,.84,.52) end
    self:Volume("noodle side pickup shelf","solid",x,.54,z,.96,.92,.63,true)
    -- A real-profile stockpot, lid, and nested ceramic serving bowls.
    self:Lathe("steel",x-.20,1.00,z,{{.12,0},{.14,.02},{.14,.27},{.152,.28},{.152,.30},{.13,.30},{.13,.08}})
    self:Lathe("steel",x-.20,1.31,z,{{.15,0},{.14,.025},{.06,.045},{.018,.06},{.018,.10},{0,.10}})
    for _,side in ipairs({-1,1}) do
        self:Tube("metal",V(x-.20+side*.15,1.20,z),V(x-.20+side*.21,1.20,z),.025)
    end
    for i=1,3 do
        self:Lathe("enamel",x+.24,1.01+(i-1)*.038,z-.04,
            {{.052,0},{.055,.025},{.105,.11},{.109,.125},{.094,.125},{.043,.035},{0,.035}})
    end
    self:Sign("打 包 取 餐",x,1.72,12.222,0,.14)
end

function Dressing:ShopRack(x,z)
    -- Folded open crate: four slatted sides plus base, not a solid cuboid of goods.
    self:Box("wood",x,.20,z,.92,.06,.61)
    for _,side in ipairs({-1,1}) do
        for i=1,3 do
            self:Box("wood",x,.21+i*.085,z+side*.28,.92,.052,.035)
            self:Box("wood",x+side*.44,.21+i*.085,z,.035,.052,.59)
        end
        self:Box("steel",x+side*.44,.38,z-.28,.04,.40,.04)
        self:Box("steel",x+side*.44,.38,z+.28,.04,.40,.04)
    end
    self:Volume("convenience drink crate","solid",x,.36,z,.96,.52,.64,true)
    for i=1,6 do
        local bx=x-.30+((i-1)%3)*.30
        local bz=z-.135+math.floor((i-1)/3)*.27
        self:Lathe(i%2==0 and "teal" or "enamel",bx,.23,bz,
            {{.062,0},{.072,.03},{.072,.28},{.038,.34},{.026,.36},{.026,.43},{0,.43}},10)
        self:Lathe("paper",bx,.34,bz,{{.073,0},{.073,.13}},10)
    end
    self:Sign("瓶 装 饮 水",x,1.72,12.222,0,.14)
    -- Small wall meter cabinet and grille close the retail wing convincingly.
    self:Box("teal",x,2.44,12.255,.66,.47,.075)
    for i=1,5 do self:Box("steel",x,2.28+i*.055,12.209,.51,.016,.018) end
end

function Dressing:OfficeLobby()
    local x,z=-45,47.78
    self:Solid("office stone entrance wall","concrete",x,2.03,z,5.90,3.88,.44)
    self:Face("office","officeArt",OFFICE,x,2.02,47.545,5.70,3.80,0)
    for _,side in ipairs({-1,1}) do
        self:Solid("office side stone return","concrete",x+side*4.70,2.03,48.23,3.60,3.88,.44)
        self:Box("steel",x+side*2.39,1.88,47.517,.045,2.79,.055)
        self:Box("steel",x+side*.94,1.52,47.516,.038,2.80,.055)
        self:Solid("office side plinth","stone",x+side*4.65,.22,47.79,3.20,.28,.63)
        -- Tiled stone joint rhythm belongs to this single lobby, not copied towers.
        for i=1,4 do self:Box("steel",x+side*4.65,.42+i*.69,47.998,3.18,.012,.018) end
        self:Planter(x+side*4.90,47.25)
    end
    -- Closed glass entry's door handles physically project, aligned to the image.
    for _,side in ipairs({-1,1}) do
        self:Tube("steel",V(x+side*.10,1.05,47.475),V(x+side*.10,1.72,47.475),.023)
    end
    self:Box("stone",x,.105,47.70,5.75,.045,.70) -- threshold behind the unobstructed route
    self:Grate("office door drain",x,47.30,5.65,.18)
    -- Structural slab and soffit: no false ground collider below the canopy.
    self:Box("metal",x,4.10,46.96,13.35,.18,2.08)
    self:Box("steel",x,4.01,45.98,13.35,.045,.09)
    self:Box("lamp",x,3.993,46.62,5.3,.018,.09)
    self:Volume("office cantilever canopy","overhead",x,4.10,46.96,13.35,.18,2.08,false)
    self.counters.canopies=self.counters.canopies+1
    self:Box("teal",x+4.63,1.81,47.978,2.34,2.03,.025)
    self:Sign("星 桥 大 厦",x+4.63,2.51,47.958,0,.22)
    self:Sign("1F  门厅 · 物业",x+4.63,2.11,47.958,0,.15)
    self:Sign("2F  会议接待",x+4.63,1.77,47.958,0,.15)
    self:Sign("3—6F  办公区",x+4.63,1.44,47.958,0,.15)
    self:Sign("配送请在门厅交接",x+4.63,1.11,47.958,0,.13)
    self:Box("wood",x-4.62,1.83,47.98,2.38,1.83,.035)
    self:Box("paper",x-4.62,1.83,47.955,2.18,1.64,.015)
    self:Sign("欢 迎 来 访",x-4.62,2.33,47.935,0,.22,Color(.17,.22,.19))
    self:Sign("请在门厅核对收件人",x-4.62,1.88,47.935,0,.135,Color(.17,.22,.19))
    self:Sign("雨天小心  ·  保持通道",x-4.62,1.44,47.935,0,.13,Color(.17,.22,.19))
end

function Dressing:Planter(x,z)
    local base=self.details:Surface(x,z)
    self:Lathe("concrete",x,base,z,{{.19,0},{.24,.04},{.26,.52},{.28,.54},{.28,.58},{.24,.58},{.22,.45}},12)
    self:Lathe("recess",x,base+.49,z,{{.235,0},{0,0}},12)
    self:Volume("office entrance planter","solid",x,base+.29,z,.56,.58,.56,true)
    -- Low polygon leaves are individual tapered blades with genuine silhouettes.
    for i=1,9 do
        local angle=i*2.39996
        local dx,dz=math.cos(angle),math.sin(angle)
        local tip=V(x+dx*.34,base+.96+(i%3)*.14,z+dz*.34)
        local a=V(x-dz*.045,base+.54,z+dx*.045)
        local b=V(x+dz*.045,base+.54,z-dx*.045)
        local shoulder=V(x+dx*.20-dz*.038,base+.84,z+dz*.20+dx*.038)
        local edge=V(x+dx*.20+dz*.038,base+.84,z+dz*.20-dx*.038)
        self:Quad("foliage",a,shoulder,b,edge,1)
        self:Quad("foliage",b,edge,a,shoulder,1)
        local tipSide=tip+V(dz*.002,0,-dx*.002)
        self:Quad("foliage",shoulder,tip,edge,tipSide,1)
        self:Quad("foliage",edge,tipSide,shoulder,tip,1)
    end
end

function Dressing:Grate(id,x,z,width,depth)
    local y=self.details:Surface(x,z)+.002
    self:Quad("frame",V(x-width/2,y,z-depth/2),V(x-width/2,y,z+depth/2),
        V(x+width/2,y,z-depth/2),V(x+width/2,y,z+depth/2),2)
    local count=math.max(4,math.floor(width/.11))
    for i=1,count do
        local px=x-width/2+(i-.5)*width/count
        self:Quad("steel",V(px-.018,y+.001,z-depth/2),V(px-.018,y+.001,z+depth/2),
            V(px+.018,y+.001,z-depth/2),V(px+.018,y+.001,z+depth/2),2)
    end
    self:Volume(id,"flush",x,y,z,width,.004,depth,false)
    self.counters.drains=self.counters.drains+1
end

function Dressing:Charging()
    -- Existing pole at (24,-9), .65m square: all new screen/connector detail stays
    -- inside that pre-existing visual footprint; we do NOT add an invisible POI wall.
    self:Box("teal",24,1.47,-9.329,.53,.44,.012)
    self:Box("screen",24,1.49,-9.339,.37,.22,.008)
    for i=1,4 do self:Box("lamp",23.865+i*.052,1.49,-9.346,.028,.105,.005) end
    self:Sign("充 电",24,1.72,-9.348,0,.11)
    for _, x in ipairs({23.82,24.18}) do
        self:Box("frame",x,.91,-9.334,.10,.15,.014)
        self:Box("steel",x,.91,-9.345,.022,.071,.008)
    end
    -- Visible cable loop follows the side of the original pole, not a 2m blocking rail.
    self:Tube("frame",V(24.22,1.02,-9.18),V(24.25,.43,-9.18),.025)
    self:Tube("frame",V(24.25,.43,-9.18),V(24.08,.30,-9.18),.025)
    self:Tube("frame",V(24.08,.30,-9.18),V(24.02,.86,-9.18),.025)
    self:Volume("original charger surface detail","attached",24,1.0,-9.18,.60,1.5,.36,false,"existing charger")
    -- Rear service nook starts beyond the full six-metre walk, not beside the POI.
    self:Solid("charger service cabinet","teal",25.8,.88,-13.12,1.65,1.60,.70)
    self:Box("steel",25.8,1.70,-13.12,1.75,.055,.78)
    self:Box("steel",25.8,.12,-13.12,1.73,.065,.74)
    self:Box("frame",25.8,.88,-12.756,.035,1.43,.012)
    for i=1,5 do self:Box("steel",25.35,1.03+i*.095,-12.757,.54,.023,.016) end
    self:Box("metal",26.35,.86,-12.752,.05,.22,.026)
    self:Sign("便 民 充 电",24,2.78,-12.41,180,.28)
    self:Box("teal",24,2.78,-12.47,5.4,.55,.12)
    self:Sign("先停车  再插电",24,2.39,-12.405,180,.14)
    for _, x in ipairs({21.4,26.6}) do
        self:Solid("charging rear canopy post","metal",x,1.48,-12.55,.085,2.8,.085)
        self:Box("steel",x,.11,-12.55,.16,.06,.16)
    end
    self:Awning(24,-12.46,5.4,1.7)
end

-- A bucket/thermos is built from accurately scaled curved built-ins, not square boxes.
function Dressing:Round(id,mat,x,y,z,diameter,height)
    local node = Parts.Add(self.root,id,"Cylinder",self.materials[mat],V(x,y,z),V(diameter,height,diameter))
    local draw = node:GetComponent("StaticModel")
    draw.drawDistance,draw.shadowDistance = 95,40
    self.counters.models = self.counters.models+1
    return node
end
function Dressing:Rim(mat,x,y,z,diameter)
    -- Built-in torus bounds are 1.2776 x .2555 x 1.2776 metres (documented).
    local node = Parts.Add(self.root,"rolled metal rim","Torus",self.materials[mat],V(x,y,z),V(diameter/1.2776,.025/.2555,diameter/1.2776))
    local draw = node:GetComponent("StaticModel")
    draw.drawDistance,draw.shadowDistance = 85,35
    self.counters.models = self.counters.models+1
end

function Dressing:Bridge()
    -- Entire living nook stays east of x=14. No new obstacle in either 6m sidewalk,
    -- either lane, the bridge rest POI, or the west-side cousin's meeting area.
    local y = self.details:Surface(15,-75)
    local bx,bz = 15.3,-75.1
    for i=1,5 do self:Box("wood",bx,y+.46,bz-.28+i*.115,2.28,.068,.09) end
    for i=1,3 do self:Box("wood",bx,y+.68+i*.14,bz+.35,2.28,.095,.065) end
    for _, side in ipairs({-1,1}) do
        self:Box("metal",bx+side*.87,y+.24,bz,.09,.48,.60)
        self:Box("metal",bx+side*.87,y+.70,bz+.35,.065,.76,.065)
    end
    self:Volume("underpass timber bench","solid",bx,y+.53,bz+.04,2.28,1.06,.75,true)
    -- Low table actually has thin legs and a slatted top. Register the tangible top
    -- footprint only, not a giant rectangular living-area collider.
    local tx,tz = 16.0,-73.50
    self:Box("wood",tx,y+.61,tz,1.40,.085,.72)
    for _, side in ipairs({-1,1}) do
        self:Box("metal",tx+side*.55,y+.31,tz,.06,.62,.58)
    end
    self:Volume("underpass tea table","solid",tx,y+.33,tz,1.40,.66,.72,true)
    self:Round("tea flask","steel",15.68,y+.84,tz,.15,.36)
    self:Rim("metal",15.68,y+1.02,tz,.15)
    self:Box("frame",15.68,y+1.055,tz,.10,.06,.10)
    self:Tube("metal",V(15.78,y+.77,tz),V(15.78,y+.96,tz),.028)
    for _, x in ipairs({16.0,16.2}) do
        self:Round("enamel cup","enamel",x,y+.73,tz-.08,.10,.13)
        self:Rim("metal",x,y+.80,tz-.08,.105)
    end
    -- Wall-like shelf backing is only behind the small shelf; real bins, book stack,
    -- water pail and folded textile give the bridge a recognisable inhabited corner.
    local sx,sz = 26.25,-72.8
    for _, side in ipairs({-1,1}) do
        self:Solid("shelf upright","metal",sx+side*1.0,y+.84,sz,.065,1.60,.56)
    end
    for _, h in ipairs({.18,.78,1.48}) do
        self:Box("wood",sx,y+h,sz,2.08,.065,.59)
        self:Volume("storage shelf","solid",sx,y+h,sz,2.08,.065,.59,true)
    end
    self:Box("paper",sx-.50,y+1.00,sz,.72,.36,.45)
    self:Box("wood",sx+.45,y+.97,sz,.61,.30,.43)
    for i=1,4 do self:Box("enamel",sx-.50,y+1.20+i*.032,sz,.62,.025,.39) end
    self:Box("canvasLight",sx+.37,y+.89,sz,.62,.13,.39)
    self:Round("water pail","teal",23.8,y+.33,-73.4,.43,.50)
    self:Rim("steel",23.8,y+.59,-73.4,.44)
    self:Tube("steel",V(23.60,y+.48,-73.4),V(23.60,y+.78,-73.4),.025)
    self:Tube("steel",V(23.60,y+.78,-73.4),V(24.0,y+.78,-73.4),.025)
    self:Tube("steel",V(24.0,y+.78,-73.4),V(24.0,y+.48,-73.4),.025)
    self:Volume("water pail footprint","solid",23.8,y+.33,-73.4,.43,.50,.43,true)
    -- Column wraps, utility conduits and understated notice board integrate the bridge
    -- into the same street instead of scattering disconnected props along the lane.
    self:Box("teal",27.765,1.65,-70,.04,1.10,2.5)
    self:Sign("邻 里 歇 脚 处",27.73,1.82,-70,90,.23)
    self:Sign("热水自取  ·  垃圾带走",27.73,1.48,-70,90,.13)
    for _, z in ipairs({-69.1,-70.9}) do
        self:Tube("metal",V(27.72,.12,z),V(27.72,5.42,z),.055)
        self:Volume("bridge column conduit","solid",27.72,2.77,z,.055,5.3,.055,true)
    end
    self:Box("lamp",21.0,5.40,-70,3.4,.035,.18)
    self:Box("metal",21.0,5.46,-70,3.6,.08,.26)
    self:Volume("underpass ceiling light","overhead",21,5.43,-70,3.6,.12,.26,false)
end

function Dressing:Drainage()
    -- Flush inlays only: NO Details:Ground call, surface rectangles or sampled heights
    -- are altered. Gutter seams and open grate slots are visible from rider height.
    for _, x in ipairs({-45,-34,-16,16,28,43}) do
        local z = -5.75
        local y = self.details:Surface(x,z)+.002
        self:Quad("frame",V(x-.46,y,z-.20),V(x-.46,y,z+.20),V(x+.46,y,z-.20),V(x+.46,y,z+.20),2)
        for i=1,9 do
            local px = x-.44+i*.088
            self:Quad("steel",V(px-.017,y+.001,z-.18),V(px-.017,y+.001,z+.18),V(px+.017,y+.001,z-.18),V(px+.017,y+.001,z+.18),2)
        end
        for _, side in ipairs({-1,1}) do
            local pz = z+side*.19
            self:Quad("steel",V(x-.46,y+.001,pz-.015),V(x-.46,y+.001,pz+.015),V(x+.46,y+.001,pz-.015),V(x+.46,y+.001,pz+.015),2)
        end
        self:Volume("flush street gully","flush",x,y,z,.92,.004,.42,false)
        self.counters.drains = self.counters.drains+1
    end
    -- The opposite retail frontage gets the same continuous kerb language, not a
    -- second blank street. All are flush, including the office approach joint line.
    for _,x in ipairs({-83,-76,-63,-49,-35,-18,18,37,46,61,73,84}) do
        self:Grate("north retail kerb gully",x,5.76,.86,.36)
    end
    for x=-85,85,1.5 do
        if math.abs(x)>13 then
            local y=self.details:Surface(x,6.04)+.002
            self:Quad("stone",V(x,y,6.01),V(x,y,6.07),V(x+1.40,y,6.01),V(x+1.40,y,6.07),1)
        end
    end
    for x=-48,-8,1.25 do
        local y=self.details:Surface(x,45.46)+.002
        self:Quad("stone",V(x,y,45.435),V(x,y,45.485),V(x+1.19,y,45.435),V(x+1.19,y,45.485),1)
    end
    -- Expansion joints along the existing kerb line, without inventing a raised kerb.
    for _, range in ipairs({{-48,-13},{13,48}}) do
        for x=range[1],range[2],1.5 do
            local z,y = -6.04,self.details:Surface(x,-6.04)+.002
            self:Quad("stone",V(x,y,z-.035),V(x,y,z+.035),V(x+1.44,y,z-.035),V(x+1.44,y,z+.035),1)
        end
    end
end

local function overlaps(a1,a2,b1,b2) return a1<b2-.00001 and a2>b1+.00001 end
local function circleGap(v,x,z)
    local px = math.max(v.x1,math.min(v.x2,x))
    local pz = math.max(v.z1,math.min(v.z2,z))
    return math.sqrt((px-x)^2+(pz-z)^2)
end

local function sweptOverlap(v,ax,az,bx,bz,radius)
    -- Segment vs radius-expanded AABB (same conservative rule used by City:Move).
    local low,high=0,1
    local function slab(a,b,mn,mx)
        local delta=b-a
        if math.abs(delta)<.000001 then return a>mn and a<mx end
        local t1,t2=(mn-a)/delta,(mx-a)/delta
        low,high=math.max(low,math.min(t1,t2)),math.min(high,math.max(t1,t2))
        return low<high-.000001
    end
    return slab(ax,bx,v.x1-radius,v.x2+radius) and slab(az,bz,v.z1-radius,v.z2+radius)
end

-- Pure inspection; no runtime runner, filesystem, save profile, or input simulation.
function Dressing:Validate()
    local errors,warnings = {},{}
    if self.disposed then errors[#errors+1] = "module already disposed" end
    local unchangedRoute = self.routeSnapshot==routeSignature()
    local routeSegments,pedestrianSegments=0,0
    for _,order in ipairs(Config.orderTemplates) do routeSegments=routeSegments+math.max(0,#order.route-1) end
    pedestrianSegments=#Pedestrians.Paths
    if not unchangedRoute then errors[#errors+1] = "navigation coordinates changed" end
    if self.surfaceSignature~=surfaceSignature(self.details) then errors[#errors+1] = "ground rectangles changed" end
    if #self.details.surfaces~=#self.surfaceSnapshot then errors[#errors+1] = "ground registry size changed" end
    for i,surface in ipairs(self.surfaceSnapshot) do
        if self.details.surfaces[i]~=surface then errors[#errors+1] = "ground rectangle replaced" end
    end
    for _,p in ipairs(self.probes) do
        if math.abs(self.details:Surface(p.x,p.z)-p.y)>.000001 then errors[#errors+1] = "ground sample changed" end
    end
    for _, v in ipairs(self.volumes) do
        if v.x2<=v.x1 or v.z2<=v.z1 or v.y2<=v.y1 then errors[#errors+1] = "invalid bounds: "..v.id end
        if v.kind=="overhead" and (v.y1<2.7 or v.collision) then errors[#errors+1] = "overhead clearance: "..v.id end
        if v.collision then
            for _, road in ipairs({-172,-100,0,100,172}) do
                if overlaps(v.x1,v.x2,road-12,road+12) then errors[#errors+1] = "road/6m walk intrusion X: "..v.id end
            end
            for _, road in ipairs({-172,0,100,172}) do
                if overlaps(v.z1,v.z2,road-12,road+12) then errors[#errors+1] = "road/6m walk intrusion Z: "..v.id end
            end
            for _, point in ipairs(Config.pointList) do
                if circleGap(v,point.x,point.z)<Config.INTERACTION_RADIUS-.00001 then
                    errors[#errors+1] = "2m POI intrusion "..point.id..": "..v.id
                end
            end
            for _,order in ipairs(Config.orderTemplates) do
                for i=2,#order.route do
                    local a,b=order.route[i-1],order.route[i]
                    if sweptOverlap(v,a.x,a.z,b.x,b.z,1.5) then
                        errors[#errors+1]="order approach intrusion "..order.id..": "..v.id
                        break
                    end
                end
            end
            for i,path in ipairs(Pedestrians.Paths) do
                if sweptOverlap(v,path[1],path[2],path[3],path[4],.45) then
                    errors[#errors+1]="pedestrian path "..i..": "..v.id
                end
            end
            -- These legacy contacts are created AFTER StreetDressing; validate their
            -- actual fixed envelopes without require(Contacts) circular dependencies.
            for _,p in ipairs({{-28.6,-10.9},{-9.9,-73.3},{110.5,83.2},{-22,-11.1},
                {-19.1,-10.9},{-10,-66.5},{-11,-65.4},{-72.7,10.9}}) do
                if p[1]>v.x1-.45 and p[1]<v.x2+.45 and p[2]>v.z1-.45 and p[2]<v.z2+.45 then
                    errors[#errors+1]="legacy contact intrusion: "..v.id
                end
            end
        end
        if v.exception then warnings[#warnings+1] = v.id.." reuses the old pole; its legacy POI overlap is not fixed here" end
    end
    for _, face in ipairs(self.faces) do
        if face.geometry:GetNumVertices(0)~=6 or face.uv~="0..1, once" then errors[#errors+1] = "artwork UV/topology: "..face.id end
        local expected = {{0,1},{0,0},{1,1},{1,1},{0,0},{1,0}}
        for i,uv in ipairs(expected) do
            local vertex = face.geometry:GetVertex(0,i-1)
            if math.abs(vertex.texCoord.x-uv[1])>.000001 or math.abs(vertex.texCoord.y-uv[2])>.000001 then
                errors[#errors+1] = "artwork UV coordinates: "..face.id
                break
            end
        end
        if face.material:GetTexture(TU_DIFFUSE).name~=face.path then errors[#errors+1] = "artwork binding: "..face.id end
    end
    local expectedFaces={breakfast=BREAKFAST,repair=REPAIR,breakfast_sign=SIGN,
        noodle=NOODLE,convenience=CONVENIENCE,office=OFFICE}
    if #self.faces~=6 then errors[#errors+1] = "expected five storefront/lobby faces and one breakfast sign" end
    for _,face in ipairs(self.faces) do
        if expectedFaces[face.id]~=face.path then errors[#errors+1]="unexpected storefront: "..face.id end
        expectedFaces[face.id]=nil
        if face.id=="noodle" or face.id=="convenience" or face.id=="office" then
            local texture=face.material:GetTexture(TU_DIFFUSE)
            if math.abs(face.width/face.height-texture.width/texture.height)>.002 then
                errors[#errors+1]="new storefront aspect distorted: "..face.id
            end
        end
    end
    for id in pairs(expectedFaces) do errors[#errors+1]="missing storefront: "..id end
    warnings[#warnings+1] = "Solid legacy shell retained: displayed interior is albedo + shallow physical frame, not enterable geometry"
    warnings[#warnings+1] = "No runtime/screenshot validation performed by this module's implementation task"
    return {ok=#errors==0,errors=errors,warnings=warnings,volumes=self.volumes,faces=self.faces,
        unchangedRoute=unchangedRoute,groundSamples=#self.probes,minimumWalkWidth=6,poiRadius=Config.INTERACTION_RADIUS,
        routeSegments=routeSegments,pedestrianPaths=pedestrianSegments,routeClearance=1.5,pedestrianClearance=.45}
end

function Dressing:Stats()
    local triangles = 0.0
    for _,key in ipairs(self.batchKeys) do
        local batch = self.details.batches[key]
        if batch then triangles = triangles+batch.vertices/3 end
    end
    return {shopfronts=self.counters.shopfronts,artworkFaces=#self.faces,batches=#self.batchKeys,
        batchTriangles=triangles,artworkTriangles=#self.faces*2,boxes=self.counters.boxes,
        quads=self.counters.quads,models=self.counters.models,tubes=self.counters.tubes,
        signs=self.counters.signs,drains=self.counters.drains,obstacles=#self.collisions,
        storeProps=self.counters.storeProps,canopies=self.counters.canopies,
        ownedMaterials=#self.owned,borrowedArtworkTextures=#self.textures,perFrameRebuilds=0,
        groundRectanglesAdded=0,navigationChanges=0,disposed=self.disposed}
end

function Dressing:Dispose()
    if self.disposed then return end
    self.disposed = true
    self.root:Dispose()
    -- Only namespaced batches belong to us; never dispose shared City mats or meshes.
    for _,key in ipairs(self.batchKeys) do
        local batch = self.details.batches[key]
        if batch then batch.geometry.node:Dispose(); self.details.batches[key] = nil end
    end
    for key in pairs(self.materials) do self.details.mats[PREFIX..key] = nil end
    self.details.meshCount = self.details.meshCount-#self.batchKeys
    self.details.boxes = self.details.boxes-math.floor(self.counters.boxes)
    self.details.signs = self.details.signs-math.floor(self.counters.signs)
    for i=#self.city.obstacles,1,-1 do
        for _, obstacle in ipairs(self.collisions) do
            if self.city.obstacles[i]==obstacle then table.remove(self.city.obstacles,i); break end
        end
    end
    for _,material in ipairs(self.owned) do material:Dispose() end
    self.owned, self.textures, self.batchKeys, self.faces, self.collisions, self.materials = {},{},{},{},{},{}
end

return Dressing
