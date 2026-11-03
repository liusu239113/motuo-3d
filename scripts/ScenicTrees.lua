-- 所有距离层级复用同一正式MDL、完整图集及导入LOD；不再生成树冠/树干顶点。
local Trees = {}
local MODEL = "model/7039feb0-0ede-50ca-8a45-7ee7becdc70d/Meshes/0f8cbb484ba64209884d33087fce835e.mdl"
local MATERIAL = "model/7039feb0-0ede-50ca-8a45-7ee7becdc70d/Materials/0f8cbb484ba64209884d33087fce835e_00_tripo_material_b8152344-c0aa-4c17-b5af-baf02cc19aa5.xml"
local DIFFUSE = "model/7039feb0-0ede-50ca-8a45-7ee7becdc70d/Textures/0f8cbb484ba64209884d33087fce835e_00_D.jpg"
local NORMAL = "model/7039feb0-0ede-50ca-8a45-7ee7becdc70d/Textures/0f8cbb484ba64209884d33087fce835e_00_N.jpg"
-- 同名Textures/*.xml是图片导入/压缩设置，交给构建器，不冒充XMLFile运行时预载。
Trees.Resources = {MODEL, MATERIAL, DIFFUSE, NORMAL, "Techniques/PBR/PBRDiffNormal.xml"}
Trees.ResourceTypes = {[MODEL] = "Model", [MATERIAL] = "Material", [DIFFUSE] = "Texture2D", [NORMAL] = "Texture2D",
    ["Techniques/PBR/PBRDiffNormal.xml"] = "Technique"}

---@type Model?
local sharedModel = nil
---@type Material?
local sharedMaterial = nil
---@type StaticModel[]
local drawables = {}
---@type boolean[]
local nearRoadTrees = {}
---@type StaticModel[]
local forestDrawables = {}
---@type boolean[]
local farForest = {}
local highQuality = false

---@class ScenicForestTree
---@field x number
---@field y number
---@field z number
---@field height number
---@field yaw number

---@class ScenicForestChunk
---@field far boolean
---@field trees ScenicForestTree[]

---@type table<string, ScenicForestChunk>
local forestChunks = {}
local middleTrees, distantTrees, chunkCount = 0, 0, 0
-- 18,878 / 16,046 / 12,270 / 8,495 为既有MDL导入LOD三角数。
-- 不再沿用46/22三角假冠统计；最坏成本按完整LOD0计算，实例数量另设硬上限。
Trees.MiddleTriangles, Trees.FarTriangles = 18878, 18878
Trees.CanopyInstanceLimit = 480
Trees.LowTriangleLimit = Trees.CanopyInstanceLimit * Trees.MiddleTriangles
local MAX_PER_CELL = 12

function Trees.Begin()
    drawables, nearRoadTrees, forestDrawables, farForest, forestChunks = {}, {}, {}, {}, {}
    middleTrees, distantTrees, chunkCount = 0, 0, 0
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
        drawable.lodBias = near and (high and .85 or .60) or (high and .45 or .25)
    end
    for i, drawable in ipairs(forestDrawables) do
        local far = farForest[i]
        drawable.drawDistance = far and (high and 560 or 420) or (high and 360 or 280)
        drawable.lodBias = far and .10 or .18
        drawable.castShadows = false
        drawable.shadowDistance = 0
    end
end

local function ensureResources()
    if not sharedModel then sharedModel = assert(cache:GetResource("Model", MODEL), "正式阔叶树模型未预载") end
    if not sharedMaterial then
        -- 完整实色JPG图集，不能误用alpha裁剪；只创建一次，全部实例共享。
        local mat = Material:new()
        mat:SetTechnique(0, assert(cache:GetResource("Technique", "Techniques/PBR/PBRDiffNormal.xml")))
        mat:SetTexture(TU_DIFFUSE, assert(cache:GetResource("Texture2D", DIFFUSE)))
        mat:SetTexture(TU_NORMAL, assert(cache:GetResource("Texture2D", NORMAL)))
        mat:SetShaderParameter("MatDiffColor", Variant(Color(.84, .91, .77, 1)))
        mat:SetShaderParameter("Metallic", Variant(0))
        mat:SetShaderParameter("Roughness", Variant(.96))
        sharedMaterial = mat
    end
end

---@param parent Node
---@param x number
---@param y number
---@param z number
---@param height number
---@param yaw number
---@return Node, StaticModel
local function instance(parent, x, y, z, height, yaw)
    ensureResources()
    local model, material = assert(sharedModel), assert(sharedMaterial)
    local bounds = model.boundingBox
    local scale = height / bounds.size.y
    local root = parent:CreateChild("正式完整阔叶树")
    root.position = Vector3(x, y, z)
    root.rotation = Quaternion(0, yaw, 0)
    local mesh = root:CreateChild("共享MDL与四级LOD")
    mesh:SetScale(scale)
    mesh.position = Vector3(-bounds.center.x, -bounds.min.y, -bounds.center.z) * scale
    local drawable = mesh:CreateComponent("StaticModel")
    drawable:SetModel(model)
    drawable:SetMaterial(material)
    assert(drawable:GetMaterial(0) == material, "树木图集材质绑定失效")
    return root, drawable
end

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
    local root, drawable = instance(parent, x, y, z, math.max(5, math.min(11, height)), yaw)
    drawables[#drawables + 1] = drawable
    nearRoadTrees[#nearRoadTrees + 1] = nearRoad == true
    drawable.castShadows = shadow
    local near = nearRoad == true
    drawable.drawDistance = near and (highQuality and 380 or 260) or (highQuality and 340 or 220)
    drawable.shadowDistance = highQuality and 85 or 45
    drawable.lodBias = near and (highQuality and .85 or .60) or (highQuality and .45 or .25)
    return root
end

-- 保留旧入队签名；evergreen/seed只是旧生态规划参数，不再把阔叶MDL伪造成针叶树。
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
    if middleTrees + distantTrees >= Trees.CanopyInstanceLimit then return false end
    local gx, gz = math.floor(x / 128), math.floor(z / 128)
    local key = gx .. ":" .. gz .. ":" .. tostring(far)
    local chunk = forestChunks[key]
    if not chunk then
        chunk = {far = far, trees = {}}
        forestChunks[key] = chunk
    end
    if #chunk.trees >= MAX_PER_CELL then return false end
    chunk.trees[#chunk.trees + 1] = {x = x, y = y, z = z, height = height, yaw = yaw}
    if far then distantTrees = distantTrees + 1 else middleTrees = middleTrees + 1 end
    return true
end

-- 分块只组织加载，不合并几何/放大drawable包围盒；每棵保留Octree视锥、距离剔除和模型LOD。
-- 同MDL同材质的可见实例由引擎动态实例化，不能声称所有LOD/灯光组合只有一次draw call。
---@param parent Node
---@param yieldChunk? fun()
function Trees.FlushCanopies(parent, yieldChunk)
    local keys = {}
    for key in pairs(forestChunks) do keys[#keys + 1] = key end
    table.sort(keys)
    local done = 0
    for _, key in ipairs(keys) do
        local chunk = forestChunks[key]
        local root = parent:CreateChild(chunk.far and "正式远林128m" or "正式中林128m")
        chunkCount = chunkCount + 1
        for _, tree in ipairs(chunk.trees) do
            local _, drawable = instance(root, tree.x, tree.y, tree.z, tree.height, tree.yaw)
            forestDrawables[#forestDrawables + 1] = drawable
            farForest[#farForest + 1] = chunk.far
            drawable.castShadows, drawable.shadowDistance = false, 0
            drawable.drawDistance = chunk.far and (highQuality and 560 or 420) or (highQuality and 360 or 280)
            drawable.lodBias = chunk.far and .10 or .18
            done = done + 1
            if yieldChunk and done % 12 == 0 then yieldChunk() end
        end
    end
    forestChunks = {}
end

---@return table
function Trees.Stats()
    local count = middleTrees + distantTrees
    return {high = #drawables, middle = middleTrees, far = distantTrees,
        lowTriangles = count * 18878, lowMinTriangles = count * 8495,
        chunks = chunkCount, lowDrawCalls = #forestDrawables,
        highMaxTriangles = #drawables * 18878, highMinTriangles = #drawables * 8495,
        canopyInstances = #forestDrawables, canopyLimit = Trees.CanopyInstanceLimit, proceduralTrees = 0}
end

return Trees
