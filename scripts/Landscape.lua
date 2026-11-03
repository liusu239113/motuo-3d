-- 基于三维场景脚手架的静态大世界；几何、导航和轮胎高度共用同一套采样。
local Landscape = {}
local Trees = require("ScenicTrees")
local Mesh = require("ScenicMesh")
local Tracks = require("Tracks")
local TrackFeatures = require("TrackFeatures")
local activeTrack = assert(Tracks.Get("lake"))
local V = Vector3
local abs, sin, cos, sqrt = math.abs, math.sin, math.cos, math.sqrt
local CELL, STEP = 64, 8
local MIN_X, MAX_X, MIN_Z, MAX_Z = -1280, 1280, -768, 1536
local TILE = 256

---@class ScenicSample
---@field x number
---@field y number
---@field z number
---@field s number
---@field rx number
---@field rz number

---@class ScenicRoad
---@field name string
---@field samples ScenicSample[]
---@field length number
---@field width number
---@field shoulder number
---@field main boolean

---@class ScenicSegment
---@field a ScenicSample
---@field b ScenicSample
---@field road ScenicRoad
---@field index integer

Landscape.Bounds = {minX = MIN_X, maxX = MAX_X, minZ = MIN_Z, maxZ = MAX_Z}
Landscape.WaterLevel = 11.8
Landscape.SpawnLaneOffset = 2.4
Landscape.Ramps = {}
---@type TrackFeature[]
Landscape.Features = {}
---@type TrackFeature[]
Landscape.OptionalRamps = {}
Landscape.Regions = {
    {name = "翡翠湖岸", x = -185, z = 180, radius = 330, color = {89, 184, 178}},
    {name = "白水河谷", x = -375, z = 475, radius = 205, color = {104, 181, 202}},
    {name = "冷杉森林", x = -390, z = 835, radius = 270, color = {103, 154, 104}},
    {name = "金色高山草甸", x = -35, z = 870, radius = 230, color = {215, 188, 116}},
    {name = "云岭观景台", x = 720, z = 875, radius = 300, color = {163, 182, 208}},
    {name = "牧场回程", x = 355, z = 170, radius = 280, color = {161, 188, 111}},
}
Landscape.Resources = {
    "uuid://EFSiAWPsKtpGQpTAGBbflyyK", "uuid://B2-Y8QtOc5NdOQVWAmvW1aQ_",
    "uuid://Hg04wSbDi8KsIwqNpUJ0OiwN", "uuid://GMR70cPvbaF6F8SvtDto--G_",
    "uuid://DdH4-Su6Cppk8qaKI2AiCLs-",
    "Materials/SingleLayerWater.xml", "Techniques/PBR/PBRNoTexture.xml",
    "Techniques/PBR/PBRDiffNormal.xml", "ScenicTerrain.shader", "ScenicWater.shader",
    "ScenicRoad.shader", "ScenicProps.shader",
    "uuid://FA-0GUs_3oaHzyb-ntH1Nkwf", "uuid://As2_acelV1DosNkDmeMasF4T",
    "uuid://ETwgwdlLT9yb0fm2NxmLlURS", "uuid://DAxRITvZ1vC60um7M6gXY_Va",
    "uuid://HDoGiRhCA1ZwjewmLbRqhTOq",
    "uuid://E4ehad-5axjv7Ml9zasxNx06",
}
Landscape.ResourceTypes = {
    ["uuid://FA-0GUs_3oaHzyb-ntH1Nkwf"] = "Material",
    ["uuid://As2_acelV1DosNkDmeMasF4T"] = "Model",
    ["uuid://ETwgwdlLT9yb0fm2NxmLlURS"] = "Material",
    ["uuid://DAxRITvZ1vC60um7M6gXY_Va"] = "Model",
    ["uuid://HDoGiRhCA1ZwjewmLbRqhTOq"] = "Material",
    ["uuid://EFSiAWPsKtpGQpTAGBbflyyK"] = "Material",
    ["uuid://B2-Y8QtOc5NdOQVWAmvW1aQ_"] = "Material",
    ["uuid://Hg04wSbDi8KsIwqNpUJ0OiwN"] = "Material",
    ["uuid://GMR70cPvbaF6F8SvtDto--G_"] = "Material",
    ["uuid://DdH4-Su6Cppk8qaKI2AiCLs-"] = "Material",
    ["Materials/SingleLayerWater.xml"] = "Material",
    ["Techniques/PBR/PBRNoTexture.xml"] = "Technique",
    ["Techniques/PBR/PBRDiffNormal.xml"] = "Technique",
    ["ScenicTerrain.shader"] = "SurfaceShader",
    ["ScenicRoad.shader"] = "SurfaceShader",
    ["ScenicProps.shader"] = "SurfaceShader",
    ["ScenicWater.shader"] = "SurfaceShader",
    ["uuid://E4ehad-5axjv7Ml9zasxNx06"] = "TextureCube",
}
for _, path in ipairs(Trees.Resources) do
    Landscape.Resources[#Landscape.Resources + 1] = path
    Landscape.ResourceTypes[path] = Trees.ResourceTypes[path]
end

---@type ScenicRoad[]
local roads = {}
---@type ScenicSegment[]
local segments = {}
---@type table<string, ScenicSegment[]>
local roadGrid = {}
---@type table<string, ScenicSegment[]>
local gradeGrid = {}
---@type table<string, number>
local terrainCache = {}
---@type table<string, Vector3>
local normalCache = {}
local bridgeStart, bridgeEnd = 0, 0
---@type StaticModel[]
local nearTerrain = {}
---@type StaticModel[]
local farTerrain = {}

---@param high boolean
function Landscape.SetQuality(high)
    Trees.SetQuality(high)
    for _, model in ipairs(nearTerrain) do model.drawDistance = high and 2200 or 1700 end
    for _, model in ipairs(farTerrain) do model.drawDistance = high and 3100 or 2200 end
end

local function clamp(v, a, b) return math.max(a, math.min(b, v)) end
local function smooth(a, b, x)
    local t = clamp((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)
end
local function hash(x, z) return math.floor(x / CELL) .. ":" .. math.floor(z / CELL) end
local function noise(a, b)
    local q = sin(a * 127.1 + b * 311.7) * 43758.5453
    return q - math.floor(q)
end
local function bump(x, z, cx, cz, sx, sz, height)
    return height * math.exp(-((x - cx) / sx) ^ 2 - ((z - cz) / sz) ^ 2)
end

-- Tracks owns the exact same sampler used by the UI preview; no second road approximation.
---@param points number[][]
---@param closed boolean
---@param name string
---@param width number
---@param shoulder number
---@return ScenicRoad
local function makeRoad(points, closed, name, width, shoulder)
    local samples, length = Tracks.Sample(points, closed)
    local road = {name=name,samples=samples,length=length,width=width,shoulder=shoulder,main=closed}
    roads[#roads+1] = road
    return road
end

---@type ScenicRoad
local mainRoad = {name="",samples={},length=1,width=4.8,shoulder=6.5}
Landscape.RouteLength = 1
Landscape.Roads = roads
Landscape.activeId = "lake"
Landscape.Track = activeTrack

---@param s number
---@return Vector3, number
function Landscape.RoadPoint(s)
    local wrapped = s % mainRoad.length
    local index = math.min(#mainRoad.samples - 1, math.floor(wrapped / mainRoad.length * (#mainRoad.samples - 1)) + 1)
    local a, b = mainRoad.samples[index], mainRoad.samples[index + 1]
    local t = (wrapped - a.s) / (b.s - a.s)
    local point = V(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t)
    -- 初始化样条时尚无曲面查询；正式导航返回交叉口最上层的真实三角形高程。
    if Landscape.RoadHeight then
        local surfaceY = Landscape.RoadHeight(point.x, point.z)
        if surfaceY then point.y = surfaceY end
    end
    return point, math.deg(math.atan(b.x - a.x, b.z - a.z))
end

local function buildRoadIndex()
for _, road in ipairs(roads) do
    for i = 1, #road.samples - 1 do
        local a, b = road.samples[i], road.samples[i + 1]
        ---@type ScenicSegment
        local seg = {a = a, b = b, road = road, index = i}
        segments[#segments + 1] = seg
        local padding = 58
        for gx = math.floor((math.min(a.x, b.x) - padding) / CELL), math.floor((math.max(a.x, b.x) + padding) / CELL) do
            for gz = math.floor((math.min(a.z, b.z) - padding) / CELL), math.floor((math.max(a.z, b.z) + padding) / CELL) do
                local key = gx .. ":" .. gz
                if not roadGrid[key] then roadGrid[key] = {} end
                table.insert(roadGrid[key], seg)
            end
        end
        -- 土方只需每约14米一个投影线段，避免每个地形顶点搜索全部密集路面三角形。
        if (i - 1) % 6 == 0 then
            local endIndex = math.min(#road.samples, i + 6)
            local coarse = {a = a, b = road.samples[endIndex], road = road, index = i}
            local ga, gb = coarse.a, coarse.b
            for gx = math.floor((math.min(ga.x, gb.x) - 166) / CELL), math.floor((math.max(ga.x, gb.x) + 166) / CELL) do
                for gz = math.floor((math.min(ga.z, gb.z) - 166) / CELL), math.floor((math.max(ga.z, gb.z) + 166) / CELL) do
                    local key = gx .. ":" .. gz
                    if not gradeGrid[key] then gradeGrid[key] = {} end
                    table.insert(gradeGrid[key], coarse)
                end
            end
        end
    end
end
end

---@param x number
---@param z number
---@param onlyMain boolean
---@return ScenicSegment, number, number, number
local function nearest(x, z, onlyMain)
    local list = roadGrid[hash(x, z)] or segments
    ---@type ScenicSegment
    local best = segments[1]
    local bestD, bestT, bestLat = math.huge, 0, 0
    for _, seg in ipairs(list) do
        if not onlyMain or seg.road.main then
            local a, b = seg.a, seg.b
            local dx, dz = b.x - a.x, b.z - a.z
            local t = clamp(((x - a.x) * dx + (z - a.z) * dz) / (dx * dx + dz * dz), 0, 1)
            local ox, oz = x - (a.x + dx * t), z - (a.z + dz * t)
            local d = ox * ox + oz * oz
            if d < bestD then
                best, bestD, bestT = seg, d, t
                bestLat = (ox * dz - oz * dx) / sqrt(dx * dx + dz * dz)
            end
        end
    end
    -- 偏离主路时，当前格内可能只有支路，必须补做主路线的全局查找。
    if bestD > 58*58 then
        for i = 1, #mainRoad.samples - 1 do
            local a, b = mainRoad.samples[i], mainRoad.samples[i + 1]
            local dx, dz = b.x - a.x, b.z - a.z
            local t = clamp(((x - a.x) * dx + (z - a.z) * dz) / (dx * dx + dz * dz), 0, 1)
            local ox, oz = x - a.x - dx * t, z - a.z - dz * t
            local d = ox * ox + oz * oz
            if d < bestD then
                best, bestD, bestT = segments[i], d, t
                bestLat = (ox * dz - oz * dx) / sqrt(dx * dx + dz * dz)
            end
        end
    end
    return best, bestT, bestLat, sqrt(bestD)
end

-- Original lake junction grading is preserved, but only created for that course.
local function setupLake()
    local p1 = Landscape.RoadPoint(mainRoad.length * 0.354)
    local p2 = Landscape.RoadPoint(mainRoad.length * 0.531)
    local p3 = Landscape.RoadPoint(mainRoad.length * 0.665)
    makeRoad({{p1.x,p1.y,p1.z},{-390,93,1015},{-190,112,1100},{25,119,1000},{p2.x,p2.y,p2.z}},
        false,"林海观景支路",2.7,3.9)
    makeRoad({{p3.x,p3.y,p3.z},{495,94,635},{625,117,770},{710,142,935},{805,153,1020}},
        false,"云岭登山公路",2.7,3.9)
    buildRoadIndex()
    for roadIndex = 2,#roads do
        for _,sample in ipairs(roads[roadIndex].samples) do
            local seg,t,_,distance = nearest(sample.x,sample.z,true)
            local influence = 1-smooth(10,32,distance)
            local y=seg.a.y+(seg.b.y-seg.a.y)*t
            sample.y=sample.y+(y-sample.y)*influence
        end
    end
    -- Never flatten the main route to a junction's height: that old operation made 35% grades
    -- at the edge of a 48m platform. Only the branch yields to the continuous main carriageway.
    for roadIndex=2,#roads do
        for _,sample in ipairs(roads[roadIndex].samples) do
            local seg,t,_,distance=nearest(sample.x,sample.z,true)
            local influence=1-smooth(8,65,distance)
            local y=seg.a.y+(seg.b.y-seg.a.y)*t
            sample.y=sample.y+(y-sample.y)*influence
        end
        -- The old summit spur also had a 29% grade immediately beyond its merge.
        -- Bound its longitudinal change to 18%; this does not alter main-course AI stations.
        local samples=roads[roadIndex].samples
        for i=2,#samples do
            local a,b=samples[i-1],samples[i]
            local rise=(b.s-a.s)*.18
            b.y=clamp(b.y,a.y-rise,a.y+rise)
        end
    end
end

---@param x number
---@param z number
---@return number, number
function Landscape.NearestRoad(x, z)
    local seg, t, lateral = nearest(x, z, true)
    return seg.a.s + (seg.b.s - seg.a.s) * t, lateral
end

-- 固定机关在半径radius内摆动：初始化裁出所有可能最近的原道路段。
-- 三角不等式保证候选完整；越界回到通用查询，交叉口仍逐段求真实最近点。
---@param x number
---@param z number
---@param radius number
---@return fun(px:number,pz:number):number,number
function Landscape.CreateRoadProjector(x,z,radius)
    local _,_,_,distance=nearest(x,z,true)
    local limit=(distance+radius*2+.001)^2
    local candidates={}
    for _,seg in ipairs(segments) do
        if seg.road.main then
            local a,b=seg.a,seg.b
            local dx,dz=b.x-a.x,b.z-a.z
            local length2=dx*dx+dz*dz
            local t=clamp(((x-a.x)*dx+(z-a.z)*dz)/length2,0,1)
            if (x-a.x-dx*t)^2+(z-a.z-dz*t)^2<=limit then
                candidates[#candidates+1]={a=a,b=b,dx=dx,dz=dz,length2=length2,length=sqrt(length2)}
            end
        end
    end
    return function(px,pz)
        if (px-x)^2+(pz-z)^2>radius*radius then return Landscape.NearestRoad(px,pz) end
        local bestD,bestS,bestLane=math.huge,0,0
        for _,seg in ipairs(candidates) do
            local a=seg.a
            local t=clamp(((px-a.x)*seg.dx+(pz-a.z)*seg.dz)/seg.length2,0,1)
            local ox,oz=px-(a.x+seg.dx*t),pz-(a.z+seg.dz*t)
            local d=ox*ox+oz*oz
            if d<bestD then
                bestD,bestS,bestLane=d,a.s+(seg.b.s-a.s)*t,(ox*seg.dz-oz*seg.dx)/seg.length
            end
        end
        return bestS,bestLane
    end
end
local function setupFeatures()
local bridgeS = Landscape.NearestRoad(-345, 468)
bridgeStart, bridgeEnd = bridgeS - 52, bridgeS + 52
Landscape.Bridge = {s = bridgeS, startS = bridgeStart, endS = bridgeEnd}
local laybyPoint, laybyYaw = Landscape.RoadPoint(180)
local laybyAngle = math.rad(laybyYaw)
Landscape.Laybys = {{x = laybyPoint.x + cos(laybyAngle) * 10.2,
    z = laybyPoint.z - sin(laybyAngle) * 10.2, y = laybyPoint.y - 0.11, yaw = laybyYaw}}
local layby = Landscape.Laybys[1]
Landscape.Ramps[1] = {x = layby.x - sin(laybyAngle) * 6, z = layby.z - cos(laybyAngle) * 6,
    y = layby.y, yaw = laybyYaw, length = 8, width = 2.8, height = 1.55}
local jumpPoint, jumpYaw = Landscape.RoadPoint(mainRoad.length * 0.52)
local jumpAngle = math.rad(jumpYaw)
local jump = {x = jumpPoint.x + cos(jumpAngle) * 17, z = jumpPoint.z - sin(jumpAngle) * 17,
    y = jumpPoint.y - 0.11, yaw = jumpYaw}
Landscape.Laybys[#Landscape.Laybys + 1] = jump
Landscape.Ramps[2] = {x = jump.x - sin(jumpAngle) * 4, z = jump.z - cos(jumpAngle) * 4,
    y = jump.y, yaw = jumpYaw, length = 7, width = 4, height = 1.8}
end

---@param x number
---@param z number
---@return string
function Landscape.RegionAt(x, z)
    local bestName, bestD = "云岭山野", math.huge
    for _, region in ipairs(Landscape.Regions) do
        local d = ((x - region.x) ^ 2 + (z - region.z) ^ 2) / region.radius ^ 2
        if d < bestD then bestName, bestD = region.name, d end
    end
    return bestName
end

---@param z number
---@return number
function Landscape.RiverX(z)
    return -210 - 0.48 * (z - 200) + 24 * sin((z - 200) / 96)
end

local function naturalHeight(x, z)
    local theme = activeTrack.theme
    -- C2连续值噪声，不给每个顶点独立随机高度；最短波长仍大于8米地形格。
    -- 细节先进入既有gradedHeight的160米缓坡，精确路下界/桥河床逻辑不动。
    local function field(px, pz, size, seed)
        local u, v = px / size, pz / size
        local ix, iz = math.floor(u), math.floor(v)
        local a, b = u - ix, v - iz
        local fx, fz = a*a*a*(a*(a*6-15)+10), b*b*b*(b*(b*6-15)+10)
        local lo = noise(ix + seed, iz) * (1-fx) + noise(ix + 1 + seed, iz) * fx
        local hi = noise(ix + seed, iz + 1) * (1-fx) + noise(ix + 1 + seed, iz + 1) * fx
        return (lo * (1-fz) + hi * fz) * 2 - 1
    end
    if theme == "circuit" then
        -- 场内跑道、维修区仍近乎平整。
        return 17.3 + bump(x,z,-240,190,800,850,0.5) + 0.22*sin(x/110)*cos(z/160)
            + field(x,z,185,37)*0.16
    end
    local wx = x + 62 * field(x,z,290,11)
    local wz = z + 57 * field(x,z,310,29)
    local broad = field(wx,wz,215,53)
    local folded = field(wx + 21*broad,wz,91,71)
    -- sqrt软化abs脊顶避免尖刺；侵蚀沟随大尺度地貌弯曲而非均匀细正弦。
    local ridge = 0.64 - sqrt(folded*folded + 0.055)
    local channels = field(wx*0.72 + wz*0.31,wz*1.18,57,97)
    local erosion = -smooth(0.15,0.9,channels) * (0.45 + 0.55*smooth(-0.6,0.5,broad))
    local grain = field(wx,wz,27,131)
    local relief = broad*0.52 + ridge*0.76 + erosion*0.31
    if theme == "coast" then
        local shore = -385 + 22*sin(z/170)
        local land = smooth(shore-90,shore+55,x)
        local inland = smooth(shore+35,shore+170,x)
        return -2 + land*(19 + bump(x,z,380,480,250,560,38) + bump(x,z,100,1150,300,280,20))
            + land*(inland*(7*relief + 0.7*grain) + 0.35*broad)
    elseif theme == "canyon" then
        local canyonAxis = -170 + 160*sin(z/240) + 18*field(x,z,205,151)
        local wallDistance = abs(x-canyonAxis)
        local terraces = 22*smooth(105,175,wallDistance) + 38*smooth(230,305,wallDistance)
        local walls = smooth(65,235,wallDistance)
        return 22 + terraces + bump(x,z,-730,730,160,330,115) + bump(x,z,770,900,180,280,130)
            + walls*(21*relief + 1.6*grain) + (1-walls)*1.2*broad
    elseif theme == "alpine" then
        local h = 33 + 0.11*clamp(z,0,1350) + bump(x,z,-680,650,210,580,165)
            + bump(x,z,260,1140,350,250,230) + bump(x,z,800,700,280,600,215)
        -- 支脊/侵蚀槽高处明显；32米远山网格仍能保留215/91米轮廓。
        local exposed = smooth(75,285,h)
        return h + (9+24*exposed)*relief + (0.65+1.25*exposed)*grain
    elseif theme == "forest" then
        return 25 + bump(x,z,-260,760,400,400,57) + bump(x,z,630,430,310,500,93)
            + 9*relief + 0.95*grain
    end
    local h = 17 + bump(x, z, -610, 850, 340, 390, 91) + bump(x, z, 30, 920, 370, 360, 91)
        + bump(x, z, 770, 1020, 360, 420, 146) + bump(x, z, 520, 270, 240, 330, 35)
        + bump(x, z, -1020, 530, 400, 550, 230) + bump(x, z, 1150, 1230, 430, 430, 315)
        + bump(x, z, -750, -580, 590, 270, 190) + bump(x, z, 150, 1700, 720, 340, 325)
        + bump(x, z, 1420, -300, 520, 510, 205)
    h = h + (6 + 16*smooth(35,220,h))*relief + (0.5+smooth(40,160,h))*grain
    local lake = sqrt(((x + 190) / 161) ^ 2 + ((z - 190) / 181) ^ 2)
    h = h * smooth(0.82, 1.23, lake) + 10.95 * (1 - smooth(0.82, 1.23, lake))
    if z > 270 and z < 790 then
        local d = abs(x - Landscape.RiverX(z))
        local strength = (1 - smooth(12, 53, d)) * smooth(270, 330, z) * (1 - smooth(710, 790, z))
        h = h + (10.95 - h) * strength
    end
    return h
end

local function gradedHeight(x, z)
    local h = naturalHeight(x, z)
    local candidates = gradeGrid[hash(x, z)]
    if not candidates then return h end
    ---@type ScenicSegment
    local seg = candidates[1]
    local bestDistance, t = math.huge, 0
    for _, candidate in ipairs(candidates) do
        local a, b = candidate.a, candidate.b
        local dx, dz = b.x - a.x, b.z - a.z
        local u = clamp(((x - a.x) * dx + (z - a.z) * dz) / (dx * dx + dz * dz), 0, 1)
        local d = (x - a.x - dx * u) ^ 2 + (z - a.z - dz * u) ^ 2
        if d < bestDistance then seg, t, bestDistance = candidate, u, d end
    end
    local distance = sqrt(bestDistance)
    local s = seg.a.s + (seg.b.s - seg.a.s) * t
    -- 桥下保留真正的河谷，不把桥面下面填成一堵山墙。
    local bridge = seg.road.main and s > bridgeStart + 8 and s < bridgeEnd - 8
    if distance < 160 and not bridge then
        local elevation = seg.a.y + (seg.b.y - seg.a.y) * t - 0.11
        -- 路侧先留出可骑草坡，土方在160米内平缓接回自然山体，不形成54米处的陡墙。
        local influence = 1 - smooth(seg.road.shoulder + 10, 160, distance)
        h = h + (elevation - h) * influence
    end
    -- 湖河内部保留浅床，避免160米土方把水面抬埋；岸外连续接回草坡。
    -- 公路边8米保留土方支撑，14米外恢复浅床；最后仍执行精确路面下界，防止网格穿路。
    if activeTrack.id == "lake" then
    local lakeRadius = sqrt(((x + 190) / 161) ^ 2 + ((z - 190) / 181) ^ 2)
    local lakeMask = 1 - smooth(0.96, 1.28, lakeRadius)
    local riverWidth = 11 + sin(z / 58) * 2
    local riverMask = (1 - smooth(riverWidth + 8, 58, abs(x - Landscape.RiverX(z))))
        * smooth(290, 310, z) * (1 - smooth(750, 780, z))
    local waterMask = math.max(lakeMask, riverMask) * (bridge and 1 or smooth(8, 14, distance))
    h = h + (math.min(h, 10.95) - h) * waterMask
    elseif activeTrack.id == "coast" then
        local mask = (1-smooth(-420,-330,x))*smooth(mainRoad.shoulder+10,35,distance)
        h = h + (math.min(h,-1.3)-h)*mask
    end
    for _, bay in ipairs(Landscape.Laybys) do
        local a = math.rad(bay.yaw)
        local dx, dz = x - bay.x, z - bay.z
        local lateral, forward = dx * cos(a) - dz * sin(a), dx * sin(a) + dz * cos(a)
        local influence = (1 - smooth(6, 17, abs(lateral))) * (1 - smooth(15, 26, abs(forward)))
        h = h + (bay.y - h) * influence
    end
    -- 每个8米地形三角形可能跨过整条路，必须连路外一格顶点也精确压到路面之下。
    -- 桥段同样取下界：保留低河床，但禁止桥两端的自然山体穿过桥面。
    local exactCandidates = roadGrid[hash(x, z)]
    if exactCandidates then
        local nearestD, exactY = math.huge, h
        for _, candidate in ipairs(exactCandidates) do
            local a, b = candidate.a, candidate.b
            if abs(x - a.x) < 23 and abs(z - a.z) < 23 then
                local dx, dz = b.x - a.x, b.z - a.z
                local u = clamp(((x - a.x) * dx + (z - a.z) * dz) / (dx * dx + dz * dz), 0, 1)
                local d = (x - a.x - dx * u) ^ 2 + (z - a.z - dz * u) ^ 2
                if d < nearestD then nearestD, exactY = d, a.y + (b.y - a.y) * u end
            end
        end
        if nearestD < 21 ^ 2 then
            local clearance = 0.5 * (1 - smooth(14, 21, sqrt(nearestD)))
            h = math.min(h, exactY - clearance)
        end
    end
    return h
end

local function gridHeight(ix, iz, step)
    local key = ix .. ":" .. iz .. ":" .. step
    local h = terrainCache[key]
    if h == nil then h = gradedHeight(ix * step, iz * step); terrainCache[key] = h end
    return h
end

-- 碰撞示意：每个格子 a--c / b--d，三角形为 a,b,c 与 c,b,d，叉积朝上。
-- 目的：轮胎查询与显示网格完全一致；含负坐标、格缝和三角对角线，不用双线性近似。
---@param x number
---@param z number
---@return number
function Landscape.TerrainHeight(x, z)
    local step = (x >= MIN_X and x <= MAX_X and z >= MIN_Z and z <= MAX_Z) and STEP or 32
    local ix, iz = math.floor(x / step), math.floor(z / step)
    local tx, tz = x / step - ix, z / step - iz
    local a, b = gridHeight(ix, iz, step), gridHeight(ix, iz + 1, step)
    local c, d = gridHeight(ix + 1, iz, step), gridHeight(ix + 1, iz + 1, step)
    if tx + tz <= 1 then return a + (c - a) * tx + (b - a) * tz end
    return d + (b - d) * (1 - tx) + (c - d) * (1 - tz)
end

---@param p ScenicSample
---@param lateral number
---@return Vector3
local function edge(p, lateral) return V(p.x + p.rx * lateral, p.y, p.z + p.rz * lateral) end
Landscape.Edge = edge

---@param x number
---@param z number
---@param a Vector3
---@param b Vector3
---@param c Vector3
---@return number?
local function triangleHeight(x, z, a, b, c)
    local det = (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
    if abs(det) < 0.000001 then return nil end
    local u = ((b.z - c.z) * (x - c.x) + (c.x - b.x) * (z - c.z)) / det
    local v = ((c.z - a.z) * (x - c.x) + (a.x - c.x) * (z - c.z)) / det
    if u < -0.000001 or v < -0.000001 or u + v > 1.000001 then return nil end
    return a.y * u + b.y * v + c.y * (1 - u - v)
end

---@param x number
---@param z number
---@return number?, boolean
function Landscape.RoadHeight(x, z)
    local list = roadGrid[hash(x, z)]
    if not list then return nil, false end
    ---@type number?
    local highest = nil
    ---@type number?
    local mainY = nil
    local mainAsphalt = false
    local asphalt = false
    for _, seg in ipairs(list) do
        local a, b, w, shoulder = seg.a, seg.b, seg.road.width, seg.road.shoulder
        if abs(x - a.x) < shoulder + 4 and abs(z - a.z) < shoulder + 4 then
            for band = 1, 3 do
                local lo = band == 1 and -w or (band == 2 and -shoulder or w)
                local hi = band == 1 and w or (band == 2 and -w or shoulder)
                local p, q, r, t = edge(a, lo), edge(b, lo), edge(a, hi), edge(b, hi)
                local y = triangleHeight(x, z, p, q, r) or triangleHeight(x, z, r, q, t)
                if y then
                    if highest == nil or y > highest then highest = y end
                    if seg.road.main then mainY=y;mainAsphalt=mainAsphalt or band==1 end
                    asphalt = asphalt or band == 1
                end
            end
        end
    end
    if mainY then return mainY,mainAsphalt end
    return highest, asphalt
end

-- 交通车已知路线里程，直接以O(1)采样自身路带的精确三角形；
-- 不再为每辆车的每个固定步反复搜索三次重叠路段。
---@param s number
---@param lane number
---@return Vector3, number, number
function Landscape.TrafficPose(s, lane)
    local wrapped = s % mainRoad.length
    local index = math.min(#mainRoad.samples - 1, math.floor(wrapped / mainRoad.length * (#mainRoad.samples - 1)) + 1)
    local a, b = mainRoad.samples[index], mainRoad.samples[index + 1]
    local t = (wrapped - a.s) / (b.s - a.s)
    local x = a.x + (b.x - a.x) * t + (a.rx + (b.rx - a.rx) * t) * lane
    local z = a.z + (b.z - a.z) * t + (a.rz + (b.rz - a.rz) * t) * lane
    local p, q = edge(a, -mainRoad.width), edge(b, -mainRoad.width)
    local r, u = edge(a, mainRoad.width), edge(b, mainRoad.width)
    local y = triangleHeight(x, z, p, q, r) or triangleHeight(x, z, r, q, u) or (a.y + (b.y - a.y) * t)
    local yaw = math.deg(math.atan(b.x - a.x, b.z - a.z))
    local pitch = -math.deg(math.atan((b.y - a.y) / math.max(0.001, b.s - a.s)))
    return V(x, y, z), yaw, pitch
end

-- 楔形碰撞：入口高度为地面，向局部正前方线性抬高；只在宽度内提供可骑顶面。
---@param x number
---@param z number
---@return table?
function Landscape.RampAt(x, z)
    for _, ramp in ipairs(Landscape.Ramps) do
        local a = math.rad(ramp.yaw)
        local dx, dz = x - ramp.x, z - ramp.z
        local lateral, forward = dx * cos(a) - dz * sin(a), dx * sin(a) + dz * cos(a)
        if abs(lateral) <= ramp.width * 0.5 and forward >= -0.00001 and forward <= ramp.length + 0.00001 then return ramp end
    end
    return nil
end

---@param x number
---@param z number
---@return number, boolean
function Landscape.Height(x, z)
    local ramp = Landscape.RampAt(x, z)
    if ramp then
        return TrackFeatures.RampHeight(ramp, x, z) or ramp.y, ramp.optional == true
    end
    local roadY, road = Landscape.RoadHeight(x, z)
    if roadY then return roadY, road end
    return Landscape.TerrainHeight(x, z), false
end

---@param x number
---@param z number
---@return number
function Landscape.WaterDepth(x, z)
    if not activeTrack.water then return 0 end
    if activeTrack.id == "coast" then
        if x > -330 then return 0 end
        local y,road = Landscape.Height(x,z)
        return road and 0 or math.max(0,Landscape.WaterLevel-y)
    end
    local lake = ((x + 190) / 160) ^ 2 + ((z - 190) / 180) ^ 2 <= 1
    local river = z >= 310 and z <= 750 and abs(x - Landscape.RiverX(z)) < 11 + sin(z / 58) * 2
    if not lake and not river then return 0 end
    local y, road = Landscape.Height(x, z)
    if road then return 0 end
    return math.max(0, Landscape.WaterLevel - y)
end

local lakeRegions = Landscape.Regions
local roadTasks = 0
Landscape.Goals, Landscape.Laybys = {}, {}
Landscape.BuildStages = {}
Landscape.Bridge = {s=0,startS=0,endS=0}

-- A selection is a data transaction; the caller must dispose/rebuild World before resuming physics.
-- Invalid IDs are rejected without altering the active track. No cached height/grid survives a switch.
---@param id string
---@return boolean, string?
function Landscape.SelectTrack(id)
    local track = Tracks.Get(id)
    if not track then return false,"Unknown track: "..tostring(id) end
    activeTrack = track
    Landscape.activeId,Landscape.Track = id,track
    roads,segments,roadGrid,gradeGrid,terrainCache,normalCache = {},{},{},{},{},{}
    nearTerrain,farTerrain = {},{}
    Landscape.Ramps,Landscape.Laybys,Landscape.Goals,Landscape.Regions = {},{},{},{}
    bridgeStart,bridgeEnd = -100,-100
    Landscape.Bridge = {s=0,startS=0,endS=0}
    mainRoad = makeRoad(track.points,true,track.name,track.width*0.5,track.shoulder)
    Landscape.RouteLength,Landscape.Roads = mainRoad.length,roads
    Landscape.SpawnLaneOffset = math.min(2.4,mainRoad.width*0.5)
    Landscape.WaterLevel = id=="coast" and 0 or 11.8
    if id=="lake" then setupLake();setupFeatures() else buildRoadIndex() end
    for i,fraction in ipairs({0.105,0.224,0.375,0.505,0.711,0.875}) do
        local s=mainRoad.length*fraction
        local p=Landscape.RoadPoint(s)
        Landscape.Goals[i]={name=track.goalNames[i],x=p.x,z=p.z,radius=24,s=s}
        Landscape.Regions[i]={name=track.goalNames[i],x=p.x,z=p.z,radius=220,color=track.accent}
    end
    if id=="lake" then Landscape.Regions=lakeRegions end
    -- 原道路/桥/水域查询准备完毕后才放置机关。
    -- 机关不改主路points、自然地形、土方、材质或森林。
    Landscape.Features, Landscape.OptionalRamps = TrackFeatures.Plan(Landscape)
    for _, ramp in ipairs(Landscape.OptionalRamps) do
        Landscape.Ramps[#Landscape.Ramps + 1] = ramp
    end
    roadTasks=0
    for _,road in ipairs(roads) do roadTasks=roadTasks+math.ceil((#road.samples-1)/48) end
    -- Keep the table identity: legacy World.BuildStages may already reference these stage records.
    local stageDefs={{name="连续山坡",total=90},{name="远景山脉",total=121},
        {name="曲线公路",total=roadTasks},{name="湖泊河流",total=2},{name="写实森林",total=40}}
    for i,stage in ipairs(stageDefs) do
        if Landscape.BuildStages[i] then
            Landscape.BuildStages[i].name,Landscape.BuildStages[i].total=stage.name,stage.total
        else Landscape.BuildStages[i]=stage end
    end
    print(string.format("[Tracks] %s selected: %.1fm / %.1fm full width / %d roads",id,mainRoad.length,track.width,#roads))
    return true
end

assert(Landscape.SelectTrack("lake"))

---@param parent Node
---@param name string
---@param material Material
---@return CustomGeometry
local function geometry(parent, name, material)
    local n = parent:CreateChild(name)
    local g = n:CreateComponent("CustomGeometry")
    g:BeginGeometry(0, TRIANGLE_LIST)
    g:SetMaterial(material)
    g.castShadows = false
    return g
end

---@param g CustomGeometry
---@param p Vector3
---@param n Vector3
---@param uv Vector2
local function vertex(g, p, n, uv)
    g:DefineVertex(p); g:DefineNormal(n); g:DefineTexCoord(uv)
end

---@param g CustomGeometry
---@param a Vector3
---@param b Vector3
---@param c Vector3
local function flatTriangle(g, a, b, c)
    local normal = (b - a):CrossProduct(c - a):Normalized()
    vertex(g, a, normal, Vector2(a.x / 4, a.z / 4))
    vertex(g, b, normal, Vector2(b.x / 4, b.z / 4))
    vertex(g, c, normal, Vector2(c.x / 4, c.z / 4))
end
Landscape.Geometry, Landscape.Vertex, Landscape.Triangle = geometry, vertex, flatTriangle

---@param path string
---@param tint Color
---@return Material
local function textured(path, tint)
    local source = cache:GetResource("Material", path)
    assert(source, "风景材质未预载：" .. path)
    -- 官方原材质有旧版编辑器着色器；只复用真实纹理，显式匹配标准位置／法线／切线／UV布局。
    local m = Material:new()
    m:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRDiffNormal.xml"))
    local diffuse = assert(source:GetTexture(TU_DIFFUSE), "风景缺少真实颜色纹理：" .. path)
    local normal = assert(source:GetTexture(TU_NORMAL), "风景缺少法线纹理：" .. path)
    m:SetTexture(TU_DIFFUSE, diffuse)
    m:SetTexture(TU_NORMAL, normal)
    m:SetShaderParameter("MatDiffColor", Variant(tint))
    m:SetShaderParameter("Roughness", Variant(0.94))
    m:SetShaderParameter("Metallic", Variant(0))
    return m
end

---@return table<string, Material>
function Landscape.CreateMaterials()
    local m = {
        grass = textured("uuid://EFSiAWPsKtpGQpTAGBbflyyK", Color(0.59, 0.70, 0.48)),
        soil = textured("uuid://B2-Y8QtOc5NdOQVWAmvW1aQ_", Color(0.65, 0.62, 0.51)),
        rock = textured("uuid://Hg04wSbDi8KsIwqNpUJ0OiwN", Color(0.67, 0.72, 0.71)),
        road = textured("uuid://GMR70cPvbaF6F8SvtDto--G_", Color(0.28, 0.31, 0.33)),
    }
    local terrainBase = "grass"
    if activeTrack.id=="canyon" then
        m.sand=textured("uuid://FA-0GUs_3oaHzyb-ntH1Nkwf",Color(0.88,0.74,0.55))
        terrainBase="sand"
    elseif activeTrack.id=="coast" then
        m.soil=textured("uuid://FA-0GUs_3oaHzyb-ntH1Nkwf",Color(0.80,0.74,0.60))
    elseif activeTrack.id=="forest" then
        m.road=textured("uuid://B2-Y8QtOc5NdOQVWAmvW1aQ_",Color(0.45,0.40,0.30))
    end
    -- 单一材质逐像素计算连续坡度／高度混合，不再按三角形硬分色。
    local terrain = Material:new()
    assert(terrain:SetSurfaceShader("ScenicTerrain.shader"), "地形SurfaceShader载入失败")
    assert(terrain:SetSurfaceTexture("grass_color", m[terrainBase]:GetTexture(TU_DIFFUSE)))
    assert(terrain:SetSurfaceTexture("soil_color", m.soil:GetTexture(TU_DIFFUSE)))
    assert(terrain:SetSurfaceTexture("rock_color", m.rock:GetTexture(TU_DIFFUSE)))
    assert(terrain:SetSurfaceTexture("ground_normal", m[terrainBase]:GetTexture(TU_NORMAL)))
    assert(terrain:SetSurfaceTexture("rock_normal", m.rock:GetTexture(TU_NORMAL)))
    local palettes={
        lake={Vector3(.92,.96,.90),Vector3(.96,.94,.90),Vector3(.96,.97,.95),Vector4(0,0,0,0)},
        alpine={Vector3(.91,.94,.88),Vector3(.96,.95,.92),Vector3(.98,.98,.98),Vector4(0,0,1,0)},
        coast={Vector3(.95,.97,.91),Vector3(1.0,.98,.94),Vector3(.97,.96,.93),Vector4(0,0,0,1)},
        canyon={Vector3(1.0,.97,.93),Vector3(1.0,.96,.91),Vector3(1.0,.95,.90),Vector4(1,0,0,0)},
        forest={Vector3(.89,.94,.87),Vector3(.95,.93,.89),Vector3(.94,.96,.92),Vector4(0,1,0,0)},
        circuit={Vector3(.94,.97,.92),Vector3(.98,.97,.94),Vector3(.97,.97,.95),Vector4(0,0,0,0)},
    }
    local palette=assert(palettes[activeTrack.id])
    terrain:SetShaderParameter("grass_tint",Variant(palette[1]))
    terrain:SetShaderParameter("earth_tint",Variant(palette[2]))
    terrain:SetShaderParameter("stone_tint",Variant(palette[3]))
    terrain:SetShaderParameter("biome",Variant(palette[4]))
    for _, sampler in ipairs({"grass_color", "soil_color", "rock_color", "ground_normal", "rock_normal"}) do
        local texture = assert(terrain:GetSurfaceTexture(sampler), "地形缺少绑定纹理：" .. sampler)
        print(string.format("[风景材质] %s = %s，%dx%d", sampler, texture.name, texture.width, texture.height))
    end
    print("[风景材质] 地形生成Technique = " .. terrain:GetTechnique(0).name)
    m.terrain = terrain
    -- 绑定真实骨料纹理，路面有米级修补、近景细颗粒与粗糙度变化，不再是一张灰色平板。
    local road=Material:new()
    assert(road:SetSurfaceShader("ScenicRoad.shader"),"路面SurfaceShader载入失败")
    assert(road:SetSurfaceTexture("surface_color",m.road:GetTexture(TU_DIFFUSE)))
    assert(road:SetSurfaceTexture("surface_normal",m.road:GetTexture(TU_NORMAL)))
    road:SetShaderParameter("road_tint",Variant(activeTrack.id=="forest" and Vector3(.58,.45,.30) or Vector3(.31,.32,.34)))
    road:SetShaderParameter("dirt_road",Variant(activeTrack.id=="forest" and 1.0 or 0.0))
    m.road=road
    -- 道路、设施共用现有颜色／法线贴图；三面投影避免箱体竖面UV拉伸。
    local function prop(source,tint,roughness,metallic,specular,wood)
        local material=Material:new()
        assert(material:SetSurfaceShader("ScenicProps.shader"),"沿线材质载入失败")
        assert(material:SetSurfaceTexture("surface_color",source:GetTexture(TU_DIFFUSE)))
        assert(material:SetSurfaceTexture("surface_normal",source:GetTexture(TU_NORMAL)))
        material:SetShaderParameter("tint",Variant(tint))
        material:SetShaderParameter("finish",Variant(Vector4(roughness,metallic,specular,wood or 0)))
        return material
    end
    local rockTint=activeTrack.id=="canyon" and Vector3(.87,.60,.39) or Vector3(.76,.77,.72)
    m.rock=prop(m.rock,rockTint,.94,0,.18,0)
    local timber=textured("uuid://DdH4-Su6Cppk8qaKI2AiCLs-",Color(1,1,1))
    m.wood=prop(timber,Vector3(.83,.68,.46),.95,0,.14,1)
    m.rail=prop(m.soil,Vector3(.72,.75,.74),.66,.65,.32,0)
    m.red=prop(m.soil,Vector3(.61,.18,.09),.90,0,.18,0)
    m.white=prop(m.soil,Vector3(1.25,1.26,1.13),.93,0,.17,0)
    m.dark=prop(m.soil,Vector3(.11,.13,.13),.97,0,.10,0)
    m.green=prop(m.grass,Vector3(.42,.62,.25),.98,0,.12,0)
    m.yellow=prop(m.soil,Vector3(1.2,.88,.28),.91,0,.17,0)
    local waterSource = assert(cache:GetResource("Material", "Materials/SingleLayerWater.xml"))
    local water = Material:new()
    assert(water:SetSurfaceShader("ScenicWater.shader"), "水面SurfaceShader载入失败")
    assert(water:SetSurfaceTexture("wave_normal", assert(waterSource:GetTexture(TU_NORMAL))))
    assert(water:SetSurfaceTexture("sky_environment", assert(cache:GetResource("TextureCube", "uuid://E4ehad-5axjv7Ml9zasxNx06"))))
    water:SetShaderParameter("coast_water",Variant(activeTrack.id=="coast" and 1.0 or 0.0))
    m.water = water
    return m
end

local function terrainNormal(x, z, step)
    local ix, iz = math.floor(x / step), math.floor(z / step)
    local key = ix .. ":" .. iz .. ":" .. step
    local normal = normalCache[key]
    if normal then return normal end
    local n = V(gridHeight(ix - 1, iz, step) - gridHeight(ix + 1, iz, step), 2 * step,
        gridHeight(ix, iz - 1, step) - gridHeight(ix, iz + 1, step)):Normalized()
    normalCache[key] = n
    return n
end

---@param root Node
---@param x number
---@param z number
---@param size number
---@param step number
---@param far boolean
---@param mats table<string, Material>
---@param yieldPart fun()
local function terrainTile(root, x, z, size, step, far, mats, yieldPart)
    local count = math.floor(size / step)
    -- 与TerrainHeight保持完全相同的a,b,c／c,b,d对角线，轮下地形不减面。
    local function height(px, pz)
        return gridHeight(math.floor(px / step), math.floor(pz / step), step)
    end
    local function normal(px, pz) return terrainNormal(px, pz, step) end
    local function include(ix, iz)
        local px, pz = x + ix * step, z + iz * step
        return px < MIN_X or px >= MAX_X or pz < MIN_Z or pz >= MAX_Z
    end
    local drawable = Mesh.Grid(root, far and "远山连续曲面" or "可骑山坡", x, z, count, step,
        height, normal, mats.terrain, far and include or nil, function(row)
            if not far and row % 8 == 7 then yieldPart() end
        end)
    if drawable then
        drawable.drawDistance = far and 2200 or 1700
        local list = far and farTerrain or nearTerrain
        list[#list + 1] = drawable
    end
end

---@param road ScenicRoad
---@param index integer
---@param lateral number
---@param lift number
---@return Vector3
local function roadVertex(road, index, lateral, lift)
    local p = edge(road.samples[index], lateral)
    if not road.main then
        local seg,t,_,distance=nearest(p.x,p.z,true)
        if distance<=mainRoad.shoulder then
            local y=seg.a.y+(seg.b.y-seg.a.y)*t
            return V(p.x,y+lift,p.z)
        end
    end
    return V(p.x, p.y + lift, p.z)
end

---@param g CustomGeometry
---@param road ScenicRoad
---@param first integer
---@param last integer
---@param lo number
---@param hi number
---@param lift number
---@param dashed boolean
local function roadRibbon(g, road, first, last, lo, hi, lift, dashed)
    for i = first, last do
        if not dashed or math.floor(road.samples[i].s / 6) % 2 == 0 then
            local a, b = roadVertex(road, i, lo, lift), roadVertex(road, i + 1, lo, lift)
            local c, d = roadVertex(road, i, hi, lift), roadVertex(road, i + 1, hi, lift)
            flatTriangle(g, a, b, c); flatTriangle(g, c, b, d)
        end
    end
end
Landscape.Ribbon = roadRibbon

---@param root Node
---@param mats table<string, Material>
---@param paint Material
---@param yellow Material
---@param tick fun(stage:string,current:integer,total:integer)
local function buildRoads(root, mats, paint, yellow, tick)
    local done = 0
    for _, road in ipairs(roads) do
        for first = 1, #road.samples - 1, 48 do
            local last = math.min(#road.samples - 1, first + 47)
            local roadSurface = geometry(root, road.name, mats.road)
            roadRibbon(roadSurface, road, first, last, -road.width, road.width, 0, false)
            roadSurface:GenerateTangents(); roadSurface:Commit()
            local verge = geometry(root, "碎石路肩", mats.soil)
            roadRibbon(verge, road, first, last, -road.shoulder, -road.width, 0, false)
            roadRibbon(verge, road, first, last, road.width, road.shoulder, 0, false)
            verge:GenerateTangents(); verge:Commit()
            local lines = geometry(root, "连续弯曲边线", paint)
            if activeTrack.id~="forest" then
            for side = -1, 1, 2 do
                local center = side * (road.width - 0.22)
                roadRibbon(lines, road, first, last, center - 0.075, center + 0.075, 0.016, false)
            end
            end
            lines:Commit()
            if road.main and activeTrack.id~="forest" and activeTrack.id~="circuit" then
                local center = geometry(root, "弯道中心标线", yellow)
                roadRibbon(center, road, first, last, -0.08, 0.08, 0.018, true)
                center:Commit()
            end
            done = done + 1
            tick("曲线公路", done, roadTasks)
        end
    end
end

---@param root Node
---@param mats table<string, Material>
---@param tick fun(stage:string,current:integer,total:integer)
local function buildWater(root, mats, tick)
    if activeTrack.id=="coast" then
        local sea=geometry(root,"开放海岸水面",mats.water)
        local a,b,c,d=V(-3000,0,-2300),V(-3000,0,3000),V(-325,0,-2300),V(-325,0,3000)
        flatTriangle(sea,a,b,c);flatTriangle(sea,c,b,d)
        sea:GenerateTangents();sea:Commit()
        tick("湖泊河流",1,2);tick("湖泊河流",2,2);return
    elseif activeTrack.id~="lake" then
        tick("湖泊河流",1,2);tick("湖泊河流",2,2);return
    end
    local lake = geometry(root, "翡翠湖水面", mats.water)
    local center = V(-190, Landscape.WaterLevel, 190)
    for i = 0, 95 do
        local a, b = i / 96 * math.pi * 2, (i + 1) / 96 * math.pi * 2
        flatTriangle(lake, center, V(-190 + 160 * sin(a), center.y, 190 + 180 * cos(a)),
            V(-190 + 160 * sin(b), center.y, 190 + 180 * cos(b)))
    end
    lake:GenerateTangents(); lake:Commit(); tick("湖泊河流", 1, 2)
    local river = geometry(root, "蜿蜒白水河", mats.water)
    for z = 310, 746, 4 do
        local widthA = 11 + sin(z / 58) * 2
        local widthB = 11 + sin((z + 4) / 58) * 2
        local a, b = V(Landscape.RiverX(z) - widthA, center.y, z), V(Landscape.RiverX(z + 4) - widthB, center.y, z + 4)
        local c, d = V(Landscape.RiverX(z) + widthA, center.y, z), V(Landscape.RiverX(z + 4) + widthB, center.y, z + 4)
        flatTriangle(river, a, b, c); flatTriangle(river, c, b, d)
    end
    river:GenerateTangents(); river:Commit(); tick("湖泊河流", 2, 2)
end

---@param scene Scene
---@param root Node
---@param tick fun(stage:string,current:integer,total:integer)
local function buildForest(scene, root, tick)
    Trees.Begin()
    local id = activeTrack.id
    -- 每个全程1/40区间独立配额：近路既有树预算不变，中远景480棵完整MDL上限。
    -- 不再按46/22三角冠层估算性能；保留分布覆盖并收紧实例视距/LOD。
    local ecology = {
        lake = {middle = 5, far = 6, width = 155},
        forest = {middle = 6, far = 6, width = 145},
        alpine = {middle = 4, far = 5, width = 170},
        coast = {middle = 3, far = 4, width = 125},
        circuit = {middle = 2, far = 3, width = 140},
        canyon = {middle = 0, far = 0, width = 0},
    }
    local config = assert(ecology[id])
    local planted, nearCount = 0, 0
    ---@type table<string, table[]>
    local occupied = {}
    -- 避让示意（俯视）：冠半径r [树] -- >=r+4m -- [路肩|车道|路肩]。
    -- 所有主/支路均参与；冠缘8方向检查水面，根部取显示网格同组三角形高度。
    -- 相邻7米格检查实际圆距，不只检查同格，避免格缝重叠/临水半冠。
    local function plant(x, z, height, yaw, tier, seed)
        local _, _, _, distance = nearest(x, z, false)
        local y = Landscape.TerrainHeight(x, z)
        local evergreen = id == "alpine" or (id == "forest" and noise(seed,53) < 0.68)
            or (id == "lake" and (y > 100 or noise(seed,53) < 0.35))
        if tier == 0 and id == "alpine" and y > 145 then return false end
        -- 全层级都是同一完整MDL，统一按原模型对角半径/高度0.546保守避让。
        local radius = height * .55
        local clearance = math.max(12,mainRoad.shoulder + radius + 4)
        local meadow = id=="lake" and x > -160 and x < 140 and z > 740 and z < 1020
        local lake = id=="lake" and ((x+190)/(162+radius+3))^2 + ((z-190)/(182+radius+3))^2 < 1
        local river = id=="lake" and z > 303-radius and z < 757+radius
            and abs(x-Landscape.RiverX(z)) < 16+radius
        local sea = id=="coast" and x-radius < -304
        local paddock = id=="circuit" and distance < 72+radius
        if x < MIN_X+radius or x > MAX_X-radius or z < MIN_Z+radius or z > MAX_Z-radius
            or distance < clearance or Landscape.RoadHeight(x,z) or meadow or lake or river or sea or paddock
            or (activeTrack.water and y < Landscape.WaterLevel+0.85) then return false end
        for k = 0, 7 do
            local a = k/8*math.pi*2
            local px, pz = x+cos(a)*radius,z+sin(a)*radius
            if Landscape.WaterDepth(px,pz)>0 or Landscape.RoadHeight(px,pz) then return false end
        end
        local dx = (Landscape.TerrainHeight(x+3,z)-Landscape.TerrainHeight(x-3,z))/6
        local dz = (Landscape.TerrainHeight(x,z+3)-Landscape.TerrainHeight(x,z-3))/6
        local slope = sqrt(dx*dx+dz*dz)
        local slopeLimit = evergreen and 0.92 or 0.65
        if slope > slopeLimit then return false end
        -- 高山林线240..375米渐稀，针叶高度同时降低；不再130米以上全禁。
        if id=="alpine" then
            local alpineMask = (1-smooth(240,375,y))*(1-0.5*smooth(0.5,0.92,slope))
            if noise(seed,61)>alpineMask then return false end
            height = height*(1-0.42*smooth(185,355,y))
        end
        local gx,gz = math.floor(x/7),math.floor(z/7)
        local spacing = tier == 0 and 5.2 or 4.6
        for ox = -1,1 do
            for oz = -1,1 do
                for _, p in ipairs(occupied[(gx+ox)..":"..(gz+oz)] or {}) do
                    if (p.x-x)^2+(p.z-z)^2 < math.max(spacing,p.spacing)^2 then return false end
                end
            end
        end
        if tier == 0 then
            if planted >= activeTrack.treeBudget then return false end
            Trees.Add(root,x,y-0.08,z,height,yaw,planted%3==0,true)
            planted,nearCount=planted+1,nearCount+1
        elseif not Trees.AddCanopy(x,y-0.13,z,height,yaw,evergreen,tier==2,seed) then
            return false
        end
        local key = gx..":"..gz
        if not occupied[key] then occupied[key]={} end
        occupied[key][#occupied[key]+1] = {x=x,z=z,spacing=spacing}
        return true
    end
    for batch = 1,40 do
        local highQuota = math.floor(activeTrack.treeBudget*batch/40)-math.floor(activeTrack.treeBudget*(batch-1)/40)
        local quotas = {highQuota,config.middle,config.far}
        for tier = 0,2 do
            local quota,added = quotas[tier+1],0
            for attempt = 1,quota*10 do
                if added>=quota then break end
                local seed = batch*1009 + tier*313 + attempt*17
                -- 交错准随机站位覆盖整个区间；林带是有缺口的簇，不是道路两排等距行道树。
                local fraction = (attempt*0.61803398875 + noise(batch,tier+17)*0.63)%1
                local s = ((batch-1+fraction)/40)*mainRoad.length
                local p,yaw = Landscape.RoadPoint(s)
                local angle = math.rad(yaw)
                local side = attempt%2==0 and 1 or -1
                local offset = tier==0 and (mainRoad.shoulder+10+noise(seed,3)*18)
                    or (tier==1 and (mainRoad.shoulder+25+noise(seed,3)*38)
                    or (74+noise(seed,3)*(config.width-74)))
                if id=="circuit" then offset=(tier==2 and 102 or 84)+noise(seed,3)*30 end
                local x,z = p.x+cos(angle)*side*offset,p.z-sin(angle)*side*offset
                local height = tier==0 and (7.3+noise(seed,7)*3.6) or (8.4+noise(seed,7)*8.6)
                if id=="coast" then height=height*0.78 end
                if plant(x,z,height,noise(seed,11)*360,tier,seed) then added=added+1 end
            end
        end
        -- 生成只发生在加载阶段；按192米空间块统一提交，不把同一块拆成40份。
        if batch==40 then Trees.FlushCanopies(root,function() tick("写实森林",39,40) end) end
        tick("写实森林",batch,40)
    end
    local stats = Trees.Stats()
    print(string.format("[正式森林] %s near=%d/%d middle=%d far=%d instances=%d/%d canopyLOD0<=%d canopyLOD3=%d chunks=%d；逐实例剔除，共享MDL材质，0程序树冠",
        id,nearCount,activeTrack.treeBudget,stats.middle,stats.far,stats.canopyInstances,stats.canopyLimit,
        stats.lowTriangles,stats.lowMinTriangles,stats.chunks))
end

---@param scene Scene
---@param root Node
---@param mats table<string, Material>
---@param paint Material
---@param yellow Material
---@param tick fun(stage:string,current:integer,total:integer)
function Landscape.Build(scene, root, mats, paint, yellow, tick)
    nearTerrain, farTerrain = {}, {}
    Mesh.vertexCount, Mesh.indexCount, Mesh.tileCount = 0, 0, 0
    print(string.format("[风景] 主线%.1f米，主支路%d条，近地形8米采样", Landscape.RouteLength, #roads))
    local done = 0
    for z = MIN_Z, MAX_Z - TILE, TILE do
        for x = MIN_X, MAX_X - TILE, TILE do
            terrainTile(root, x, z, TILE, STEP, false, mats, function()
                tick("连续山坡", done, 90)
            end)
            done = done + 1; tick("连续山坡", done, 90)
        end
    end
    done = 0
    for z = -2304, 2816, 512 do
        for x = -2816, 2304, 512 do
            terrainTile(root, x, z, 512, 32, true, mats, function() end)
            done = done + 1; tick("远景山脉", done, 121)
        end
    end
    print(string.format("[风景性能] indexed地形%d块，%d顶点／%d索引；原非索引需%d顶点，减少%.1f%%，单一连续混合材质",
        Mesh.tileCount, Mesh.vertexCount, Mesh.indexCount, Mesh.indexCount, (1 - Mesh.vertexCount / Mesh.indexCount) * 100))
    buildRoads(root, mats, paint, yellow, tick)
    buildWater(root, mats, tick)
    buildForest(scene, root, tick)
end

return Landscape
