-- 基于三维场景脚手架的静态大世界；几何、导航和轮胎高度共用同一套采样。
local Landscape = {}
local Trees = require("ScenicTrees")
local Mesh = require("ScenicMesh")
local Tracks = require("Tracks")
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
    "Materials/SingleLayerWater.xml", "Techniques/PBR/PBRNoTexture.xml",
    "Techniques/PBR/PBRDiffNormal.xml", "ScenicTerrain.shader", "ScenicWater.shader",
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
    ["Materials/SingleLayerWater.xml"] = "Material",
    ["Techniques/PBR/PBRNoTexture.xml"] = "Technique",
    ["Techniques/PBR/PBRDiffNormal.xml"] = "Technique",
    ["ScenicTerrain.shader"] = "SurfaceShader",
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
    if theme == "circuit" then
        return 17.3 + bump(x,z,-240,190,800,850,0.5) + 0.22*sin(x/110)*cos(z/160)
    elseif theme == "coast" then
        local shore = -385 + 22*sin(z/170)
        local land = smooth(shore-90,shore+55,x)
        return -2 + land*(19 + bump(x,z,380,480,250,560,38) + bump(x,z,100,1150,300,280,20))
            + land*2.5*sin(z/100)*sin(x/150)
    elseif theme == "canyon" then
        local canyonAxis = -170 + 160*sin(z/240)
        local terraces = 22*smooth(115,165,abs(x-canyonAxis)) + 38*smooth(240,290,abs(x-canyonAxis))
        return 22 + terraces + bump(x,z,-730,730,160,330,115) + bump(x,z,770,900,180,280,130)
            + 3*sin(x/90)*cos(z/130)
    elseif theme == "alpine" then
        return 33 + 0.11*clamp(z,0,1350) + bump(x,z,-680,650,210,580,165)
            + bump(x,z,260,1140,350,250,230) + bump(x,z,800,700,280,600,215)
            + 8*sin(x/120)*cos(z/190)
    elseif theme == "forest" then
        return 25 + bump(x,z,-260,760,400,400,57) + bump(x,z,630,430,310,500,93)
            + 4*sin(x/100)*cos(z/140) + 1.2*sin((x+z)/38)
    end
    local h = 17 + 4.1 * sin(x / 123) * cos(z / 185) + 2.2 * sin(z / 58 + x / 88)
    h = h + bump(x, z, -610, 850, 340, 390, 91) + bump(x, z, 30, 920, 370, 360, 91)
        + bump(x, z, 770, 1020, 360, 420, 146) + bump(x, z, 520, 270, 240, 330, 35)
        + bump(x, z, -1020, 530, 400, 550, 230) + bump(x, z, 1150, 1230, 430, 430, 315)
        + bump(x, z, -750, -580, 590, 270, 190) + bump(x, z, 150, 1700, 720, 340, 325)
        + bump(x, z, 1420, -300, 520, 510, 205)
    local detail = 1.8 * sin(x / 31 + sin(z / 51)) * cos(z / 39) + 0.75 * sin((x + z) / 13)
    h = h + detail * smooth(40, 130, h)
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
        local a = math.rad(ramp.yaw)
        local forward = (x - ramp.x) * sin(a) + (z - ramp.z) * cos(a)
        return ramp.y + clamp(forward / ramp.length, 0, 1) * ramp.height, false
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
    local terrainBase = activeTrack.id=="canyon" and "sand" or "grass"
    if activeTrack.id=="canyon" then
        m.sand=textured("uuid://FA-0GUs_3oaHzyb-ntH1Nkwf",Color(0.88,0.74,0.55))
        m.soil=textured("uuid://B2-Y8QtOc5NdOQVWAmvW1aQ_",Color(0.78,0.59,0.42))
        m.rock=textured("uuid://Hg04wSbDi8KsIwqNpUJ0OiwN",Color(0.76,0.53,0.37))
    elseif activeTrack.id=="forest" then
        m.road=textured("uuid://B2-Y8QtOc5NdOQVWAmvW1aQ_",Color(0.45,0.40,0.30))
    end
    -- 单一材质逐像素计算连续坡度／高度混合，不再按三角形硬分色。
    local terrain = Material:new()
    assert(terrain:SetSurfaceShader("ScenicTerrain.shader"), "地形SurfaceShader载入失败")
    assert(terrain:SetSurfaceTexture("grass_color", m[terrainBase]:GetTexture(TU_DIFFUSE)))
    assert(terrain:SetSurfaceTexture("soil_color", m.soil:GetTexture(TU_DIFFUSE)))
    assert(terrain:SetSurfaceTexture("rock_color", m.rock:GetTexture(TU_DIFFUSE)))
    assert(terrain:SetSurfaceTexture("ground_normal", m.grass:GetTexture(TU_NORMAL)))
    assert(terrain:SetSurfaceTexture("rock_normal", m.rock:GetTexture(TU_NORMAL)))
    for _, sampler in ipairs({"grass_color", "soil_color", "rock_color", "ground_normal", "rock_normal"}) do
        local texture = assert(terrain:GetSurfaceTexture(sampler), "地形缺少绑定纹理：" .. sampler)
        print(string.format("[风景材质] %s = %s，%dx%d", sampler, texture.name, texture.width, texture.height))
    end
    print("[风景材质] 地形生成Technique = " .. terrain:GetTechnique(0).name)
    m.terrain = activeTrack.id=="canyon" and m.sand or (activeTrack.id=="alpine" and m.rock or terrain)
    local waterSource = assert(cache:GetResource("Material", "Materials/SingleLayerWater.xml"))
    local water = Material:new()
    assert(water:SetSurfaceShader("ScenicWater.shader"), "水面SurfaceShader载入失败")
    assert(water:SetSurfaceTexture("wave_normal", assert(waterSource:GetTexture(TU_NORMAL))))
    assert(water:SetSurfaceTexture("sky_environment", assert(cache:GetResource("TextureCube", "uuid://E4ehad-5axjv7Ml9zasxNx06"))))
    m.water = water
    m.road:SetShaderParameter("Roughness", Variant(0.91))
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
    -- 所有树共享同一份既有阔叶网格／材质，完全停用旧松树预制。
    -- 路边成簇栽植并留出12米通行走廊，湖岸和草甸保留开阔视野。
    Trees.Begin()
    local planted, nearCount = 0, 0
    local occupied = {}
    local function plant(x, z, height, yaw, shadow)
        if planted >= activeTrack.treeBudget then return end
        local y, onRoad = Landscape.Height(x, z)
        local _, _, _, distance = nearest(x, z, false)
        local meadow = activeTrack.id=="lake" and x > -160 and x < 140 and z > 740 and z < 1020
        local lake = activeTrack.id=="lake" and ((x + 190) / 170) ^ 2 + ((z - 190) / 190) ^ 2 < 1
        local sea = activeTrack.id=="coast" and x < -300
        local paddock = activeTrack.id=="circuit" and distance < 60
        local summit = activeTrack.id=="alpine" and y > 130
        local key = math.floor(x / 7) .. ":" .. math.floor(z / 7)
        if onRoad or distance < 12 or y < 13.5 or meadow or lake or sea or paddock or summit or occupied[key] then return end
        occupied[key] = true
        local near = distance <= 35
        Trees.Add(root, x, y - 0.06, z, height, yaw, shadow, near)
        planted = planted + 1
        if near then nearCount = nearCount + 1 end
    end
    for batch = 1, 40 do
        -- 将原有202棵预算优先移到两段可见林带，不增加总数，不在固定步修改LOD。
        local focus = activeTrack.id=="forest" or (activeTrack.id=="lake" and batch <= 20)
        local s = activeTrack.id~="lake" and ((batch-1)/40*mainRoad.length)
            or (batch <= 10 and (170 + (batch - 1) / 9 * 390)
            or (focus and (930 + (batch - 11) / 9 * 520) or ((batch - 21) / 20 * mainRoad.length)))
        local p, yaw = Landscape.RoadPoint(s)
        local angle = math.rad(yaw)
        for k = 1, focus and 8 or 4 do
            local i = batch * 11 + k
            local side = k % 2 == 0 and 1 or -1
            local row = math.floor((k - 1) / 2)
            local offset = side * (focus and (15 + row % 2 * 9 + noise(i, 3) * 4) or (25 + noise(i, 3) * 48))
            local along = focus and ((math.floor(row / 2) * 2 - 1) * 9 + (noise(i, 9) - 0.5) * 4)
                or (noise(i, 9) - 0.5) * 36
            local x = p.x + cos(angle) * offset + sin(angle) * along
            local z = p.z - sin(angle) * offset + cos(angle) * along
            plant(x, z, 7.8 + noise(i, 7) * 3.2, noise(i, 11) * 360, focus and k <= 4)
        end
        tick("写实森林", batch, 40)
    end
    print(string.format("[风景] %s: %d shared broadleaf trees (%d near road), budget %d; embedded LOD + static culling", activeTrack.id, planted, nearCount, activeTrack.treeBudget))
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
