-- 近景复用既有图集树；中远景原生闭合树冠按192米分块静态合批，不新增外部资产。
local Trees = {}
local ROOT = "model/7039feb0-0ede-50ca-8a45-7ee7becdc70d/"
local STEM = "0f8cbb484ba64209884d33087fce835e"
local MATERIAL = ROOT .. "Materials/" .. STEM .. "_00_tripo_material_b8152344-c0aa-4c17-b5af-baf02cc19aa5.xml"
local MODEL = ROOT .. "Meshes/" .. STEM .. ".mdl"
local DIFFUSE = ROOT .. "Textures/" .. STEM .. "_00_D.jpg"
local NORMAL = ROOT .. "Textures/" .. STEM .. "_00_N.jpg"
Trees.Resources = {MODEL, MATERIAL, DIFFUSE, NORMAL,
    ROOT .. "Textures/" .. STEM .. "_00_D.xml", ROOT .. "Textures/" .. STEM .. "_00_N.xml",
    "Techniques/PBR/PBRDiffNormal.xml"}
Trees.ResourceTypes = {[MODEL] = "Model", [MATERIAL] = "Material", [DIFFUSE] = "Texture2D", [NORMAL] = "Texture2D",
    [ROOT .. "Textures/" .. STEM .. "_00_D.xml"] = "XMLFile",
    [ROOT .. "Textures/" .. STEM .. "_00_N.xml"] = "XMLFile",
    ["Techniques/PBR/PBRDiffNormal.xml"] = "Technique"}

---@type Model?
local sharedModel = nil
---@type Material?
local sharedMaterial = nil
---@type StaticModel[]
local drawables = {}
---@type boolean[]
local nearRoadTrees = {}
local highQuality = false

---@class ScenicForestTree
---@field x number
---@field y number
---@field z number
---@field height number
---@field yaw number
---@field seed number
---@field evergreen boolean

---@class ScenicForestChunk
---@field cx number
---@field cz number
---@field far boolean
---@field tone integer
---@field trees ScenicForestTree[]

---@type table<string, ScenicForestChunk>
local forestChunks = {}
---@type CustomGeometry[]
local forestDrawables = {}
---@type boolean[]
local farForest = {}
---@type Material[]
local crownMaterials = {}
---@type Material?
local barkMaterial = nil
local lowTriangles, middleTrees, distantTrees = 0, 0, 0
Trees.LowTriangleLimit = 50000
Trees.MiddleTriangles, Trees.FarTriangles = 46, 22

function Trees.Begin()
    drawables, nearRoadTrees = {}, {}
    forestChunks, forestDrawables, farForest = {}, {}, {}
    lowTriangles, middleTrees, distantTrees = 0, 0, 0
    renderer.dynamicInstancing = true
    renderer.minInstances = 2
end

---@param high boolean
function Trees.SetQuality(high)
    highQuality = high
    for i, drawable in ipairs(drawables) do
        local near = nearRoadTrees[i]
        drawable.drawDistance = near and (high and 380 or 260) or (high and 340 or 220)
        drawable.shadowDistance = high and 85 or 45
        drawable.lodBias = near and (high and 0.85 or 0.60) or (high and 0.45 or 0.25)
    end
    for i, drawable in ipairs(forestDrawables) do
        drawable.drawDistance = farForest[i] and (high and 1250 or 920) or (high and 740 or 560)
        drawable.shadowDistance = high and 65 or 35
    end
end

-- 每棵树直接绑定共享材质，不经过会丢失匿名材质的节点克隆路径。
---@param parent Node
---@param x number
---@param y number
---@param z number
---@param height number
---@param yaw number
---@param shadow boolean
---@param nearRoad? boolean
---@return Node
function Trees.Add(parent, x, y, z, height, yaw, shadow, nearRoad)
    if not sharedModel then sharedModel = assert(cache:GetResource("Model", MODEL), "阔叶树模型未预载") end
    if not sharedMaterial then
        local mat = Material:new()
        mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRDiffNormal.xml"))
        -- 图集为JPG实色，没有透明通道；不用叶片裁剪，以免误删完整树冠。
        mat:SetTexture(TU_DIFFUSE, assert(cache:GetResource("Texture2D", DIFFUSE)))
        mat:SetTexture(TU_NORMAL, assert(cache:GetResource("Texture2D", NORMAL)))
        mat:SetShaderParameter("MatDiffColor", Variant(Color(0.84, 0.91, 0.77, 1)))
        mat:SetShaderParameter("Metallic", Variant(0))
        mat:SetShaderParameter("Roughness", Variant(0.96))
        sharedMaterial = mat
    end
    local model = sharedModel
    local bounds = model.boundingBox
    local scale = math.max(5, math.min(11, height)) / bounds.size.y
    local root = parent:CreateChild("完整树冠阔叶树")
    root.position = Vector3(x, y, z)
    root.rotation = Quaternion(0, yaw, 0)
    local mesh = root:CreateChild("图集树冠")
    mesh:SetScale(scale)
    mesh.position = Vector3(-bounds.center.x, -bounds.min.y, -bounds.center.z) * scale
    local drawable = mesh:CreateComponent("StaticModel")
    drawable:SetModel(model)
    drawable:SetMaterial(sharedMaterial)
    assert(drawable:GetMaterial(0) == sharedMaterial, "阔叶材质绑定失效")
    local near = nearRoad == true
    drawable.drawDistance = near and (highQuality and 380 or 260) or (highQuality and 340 or 220)
    drawable.shadowDistance = highQuality and 85 or 45
    drawable.castShadows = shadow
    -- 官方model-info确认内嵌四级LOD：18,878／16,046／12,270／8,495三角形。
    -- 近路树较晚降级，远树提前降级；仅初始化和切画质时设置，不逐帧修改。
    drawable.lodBias = near and (highQuality and 0.85 or 0.60) or (highQuality and 0.45 or 0.25)
    drawables[#drawables + 1] = drawable
    nearRoadTrees[#nearRoadTrees + 1] = near
    return root
end

-- 软化、不对称的连续冠廓；不是叠圆锥，也不需要透明卡片／逐帧朝向。
local function random(a, b)
    local q = math.sin(a * 127.1 + b * 311.7) * 43758.5453
    return q - math.floor(q)
end

---@param color Color
---@return Material
local function matte(color)
    local material = Material:new()
    material:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
    material:SetShaderParameter("MatDiffColor", Variant(color))
    material:SetShaderParameter("Metallic", Variant(0))
    material:SetShaderParameter("Roughness", Variant(1.0))
    return material
end

local function forestMaterials()
    if barkMaterial then return end
    barkMaterial = matte(Color(0.24, 0.21, 0.16))
    for tone = 1, 3 do
        local t = (tone - 1) * 0.025
        crownMaterials[tone] = matte(Color(0.19 + t, 0.285 + t, 0.17 + t * 0.6))
        crownMaterials[tone + 3] = matte(Color(0.12 + t, 0.235 + t, 0.18 + t * 0.8))
    end
end

-- 调用方已按冠半径检查所有路带/水域，并用真正的8米TerrainHeight落根。
-- 三角形上限在入队前检查；远树22、中树46，包含6三角树干，无隐藏额外几何。
---@param x number
---@param y number
---@param z number
---@param height number
---@param yaw number
---@param evergreen boolean
---@param far boolean
---@param seed number
---@return boolean
function Trees.AddCanopy(x, y, z, height, yaw, evergreen, far, seed)
    local triangles = far and Trees.FarTriangles or Trees.MiddleTriangles
    if lowTriangles + triangles > Trees.LowTriangleLimit then return false end
    local gx, gz = math.floor(x / 192), math.floor(z / 192)
    local tone = math.min(3, 1 + math.floor(random(gx, gz) * 3)) + (evergreen and 3 or 0)
    -- 同一空间块的混交林共用低饱和冠色，避免按树种再拆drawcall。
    local key = gx .. ":" .. gz .. ":" .. tostring(far)
    local chunk = forestChunks[key]
    if not chunk then
        chunk = {cx = gx * 192 + 96, cz = gz * 192 + 96, far = far, tone = tone, trees = {}}
        forestChunks[key] = chunk
    end
    chunk.trees[#chunk.trees + 1] = {x = x, y = y, z = z, height = height, yaw = yaw,
        evergreen = evergreen, seed = seed}
    lowTriangles = lowTriangles + triangles
    if far then distantTrees = distantTrees + 1 else middleTrees = middleTrees + 1 end
    return true
end

---@param geometry CustomGeometry
---@param a Vector3
---@param b Vector3
---@param c Vector3
local function triangle(geometry, a, b, c)
    local normal = (b - a):CrossProduct(c - a):Normalized()
    geometry:DefineVertex(a); geometry:DefineNormal(normal)
    geometry:DefineVertex(b); geometry:DefineNormal(normal)
    geometry:DefineVertex(c); geometry:DefineNormal(normal)
end

---@param geometry CustomGeometry
---@param chunk ScenicForestChunk
---@param tree ScenicForestTree
local function crown(geometry, chunk, tree)
    ---@type integer
    local sides = chunk.far and 4 or 5
    ---@type integer
    local rings = chunk.far and 2 or 4
    local height = tree.height
    local radius = height * (tree.evergreen and 0.205 or 0.29)
    local phase = math.rad(tree.yaw)
    local leanX = (random(tree.seed, 72) - 0.5) * height * 0.11
    local leanZ = (random(tree.seed, 73) - 0.5) * height * 0.11
    local px, pz = tree.x - chunk.cx, tree.z - chunk.cz
    ---@type Vector3[][]
    local points = {}
    for ring = 1, rings do
        local t = (ring - 1) / (rings - 1)
        local level = tree.evergreen and (0.28 + t * 0.47) or (0.45 + t * 0.40)
        local width = tree.evergreen and (1.0 - t * 0.59) or (0.83 + 0.25 * math.sin(t * math.pi))
        local row = {}
        for i = 1, sides do
            local angle = phase + (i - 1) / sides * math.pi * 2
            local r = radius * width * (0.77 + random(tree.seed + ring * 13, i * 11) * 0.42)
            local y = tree.y + height * (level + (random(tree.seed + i, ring * 9) - 0.5) * 0.065)
            row[i] = Vector3(px + math.cos(angle) * r + leanX * t,
                y, pz + math.sin(angle) * r * (0.85 + random(tree.seed, 4) * 0.25) + leanZ * t)
        end
        points[ring] = row
    end
    local bottom = Vector3(px, tree.y + height * (tree.evergreen and 0.19 or 0.34), pz)
    local top = Vector3(px + leanX, tree.y + height, pz + leanZ)
    for i = 1, sides do
        local next = i % sides + 1
        triangle(geometry, bottom, points[1][i], points[1][next])
        for ring = 1, rings - 1 do
            local a, b = points[ring][i], points[ring][next]
            local c, d = points[ring + 1][i], points[ring + 1][next]
            triangle(geometry, a, c, b); triangle(geometry, b, c, d)
        end
        triangle(geometry, points[rings][i], top, points[rings][next])
    end
end

---@param geometry CustomGeometry
---@param chunk ScenicForestChunk
---@param tree ScenicForestTree
local function trunk(geometry, chunk, tree)
    local radius = tree.height * 0.018
    for i = 1, 3 do
        local angle = math.rad(tree.yaw) + (i - 1) * math.pi * 2 / 3
        local next = angle + math.pi * 2 / 3
        local a = Vector3(tree.x - chunk.cx + math.cos(angle) * radius, tree.y,
            tree.z - chunk.cz + math.sin(angle) * radius)
        local b = Vector3(tree.x - chunk.cx + math.cos(next) * radius, tree.y,
            tree.z - chunk.cz + math.sin(next) * radius)
        local c = Vector3(a.x, tree.y + tree.height * 0.65, a.z)
        local d = Vector3(b.x, c.y, b.z)
        triangle(geometry, a, c, b); triangle(geometry, b, c, d)
    end
end

-- 每批只提交一次；局部坐标保留小包围盒，Octree + drawDistance接管剔除。
---@param parent Node
---@param yieldChunk? fun()
function Trees.FlushCanopies(parent, yieldChunk)
    forestMaterials()
    local keys = {}
    for key in pairs(forestChunks) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local chunk = forestChunks[key]
        local node = parent:CreateChild(chunk.far and "远林冠层192m" or "中景林簇192m")
        node.position = Vector3(chunk.cx, 0, chunk.cz)
        local geometry = node:CreateComponent("CustomGeometry")
        geometry:SetNumGeometries(2)
        geometry:BeginGeometry(0, TRIANGLE_LIST)
        for _, tree in ipairs(chunk.trees) do crown(geometry, chunk, tree) end
        geometry:BeginGeometry(1, TRIANGLE_LIST)
        for _, tree in ipairs(chunk.trees) do trunk(geometry, chunk, tree) end
        local requiredBark = assert(barkMaterial)
        local requiredCrown = assert(crownMaterials[chunk.tone])
        geometry:SetMaterial(0, requiredCrown)
        geometry:SetMaterial(1, requiredBark)
        geometry:Commit()
        geometry.castShadows = not chunk.far
        forestDrawables[#forestDrawables + 1] = geometry
        farForest[#farForest + 1] = chunk.far
        if yieldChunk and #forestDrawables%8==0 then yieldChunk() end
    end
    forestChunks = {}
    Trees.SetQuality(highQuality)
end

---@return table
function Trees.Stats()
    return {high = #drawables, middle = middleTrees, far = distantTrees, lowTriangles = lowTriangles,
        chunks = #forestDrawables, lowDrawCalls = #forestDrawables * 2,
        highMaxTriangles = #drawables * 18878, highMinTriangles = #drawables * 8495}
end

return Trees
