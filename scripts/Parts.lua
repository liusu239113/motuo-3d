-- 基于 scaffold-3d-scene 的场景/材质结构，提供共享的几何体与材质。
local Parts = {}
local models = {}

function Parts.Material(r, g, b, roughness, metallic, emissive)
    local mat = Material:new()
    mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
    mat:SetShaderParameter("MatDiffColor", Variant(Color(r, g, b, 1)))
    mat:SetShaderParameter("Roughness", Variant(roughness or 0.6))
    mat:SetShaderParameter("Metallic", Variant(metallic or 0))
    if emissive then mat:SetShaderParameter("MatEmissiveColor", Variant(Color(r * emissive, g * emissive, b * emissive))) end
    return mat
end

function Parts.Add(parent, name, shape, mat, pos, scale, rotation, shadow)
    local node = parent:CreateChild(name)
    node.position = pos or Vector3.ZERO
    node.scale = scale or Vector3.ONE
    if rotation then node.rotation = rotation end
    local obj = node:CreateComponent("StaticModel")
    if type(shape) == "string" then
        if not models[shape] then models[shape] = cache:GetResource("Model", "Models/" .. shape .. ".mdl") end
        obj.model = models[shape]
    else
        obj.model = shape
    end
    obj.material = mat
    obj.castShadows = shadow ~= false
    return node
end

---@param parent Node
---@param mat Material
---@param a Vector3
---@param b Vector3
---@param radius number
function Parts.Bar(parent, mat, a, b, radius)
    local delta = b - a
    return Parts.Add(parent, "连杆", "Cylinder", mat, (a + b) * 0.5,
        Vector3(radius * 2, delta:Length(), radius * 2), Quaternion(Vector3.UP, delta:Normalized()))
end

return Parts
