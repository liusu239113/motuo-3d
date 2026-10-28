-- 既有资源库阔叶树，完整树冠与原始颜色／法线图；不生成新模型。
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

function Trees.Begin()
    drawables, nearRoadTrees = {}, {}
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

return Trees
