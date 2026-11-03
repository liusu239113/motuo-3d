-- 命中爆炸特效：使用美术提供的透明爆炸贴图（PNG 带 alpha），
-- 不自行绘制形状。每次爆炸是一个面向相机的公告板，按帧放大+淡出。
local V = Vector3
local M = {}

local TEXTURE = "image/weapon_explosion_fire_smoke_20261103171243.png"
M.Resources = {TEXTURE}
M.ResourceTypes = {[TEXTURE] = "Texture2D"}

local LIFETIME = 0.55
local START_SCALE = 1.4
local END_SCALE = 5.2

---@class Explosion
---@field node Node
---@field age number
---@field scale number
---@field baseScale number
---@field material Material

---@param parent Node
---@return Explosion
local function create(parent)
    local node = parent:CreateChild("Explosion", LOCAL)
    local drawable = node:CreateComponent("StaticModel")
    -- 用双面四边形承载贴图；模型来自引擎内置平面，贴图是正式美术资源。
    drawable:SetModel(cache:GetResource("Model", "Models/Plane.mdl"))
    local material = Material:new()
    material:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
    local texture = cache:GetResource("Texture2D", TEXTURE)
    if texture then
        material:SetTexture(TU_DIFFUSE, texture)
    end
    material:SetShaderParameter("MatDiffColor", Variant(Color(1, 1, 1, 1)))
    material:SetShaderParameter("MatEmissiveColor", Variant(Color(1.1, 0.75, 0.4)))
    material.cullMode = CULL_NONE
    drawable:SetMaterial(material)
    drawable.castShadows = false
    drawable.drawDistance = 320
    return {node = node, age = 0, scale = START_SCALE, baseScale = START_SCALE, material = material}
end

---@param parent Node
---@param entry table {x,y,z,age,scale}
---@return Explosion
function M.Spawn(parent, entry)
    local explosion = create(parent)
    explosion.node.position = V(entry.x, entry.y, entry.z)
    explosion.baseScale = START_SCALE * (entry.scale or 1)
    return explosion
end

---@param explosion Explosion
---@param dt number
---@param cameraPosition Vector3
---@return boolean alive
function M.Update(explosion, dt, cameraPosition)
    explosion.age = explosion.age + dt
    if explosion.age >= LIFETIME then
        explosion.node:Dispose()
        explosion.material:Dispose()
        return false
    end
    local t = explosion.age / LIFETIME
    -- 快速放大后缓慢收尾，符合爆炸的视觉节奏。
    local size = explosion.baseScale * (1 - (1 - t) * (1 - t)) * (END_SCALE / START_SCALE)
    explosion.node.scale = V(size, size, size)
    -- 始终面向相机，避免从侧面看成一条线。
    local position = explosion.node.worldPosition
    local dx, dz = cameraPosition.x - position.x, cameraPosition.z - position.z
    if dx * dx + dz * dz > 1e-6 then
        explosion.node.rotation = Quaternion(0, math.deg(math.atan(dx, dz)), 0)
    end
    -- 后半段淡出。
    local alpha = t < 0.45 and 1 or (1 - (t - 0.45) / 0.55)
    local tint = explosion.material:GetShaderParameter("MatDiffColor"):GetColor()
    explosion.material:SetShaderParameter("MatDiffColor", Variant(Color(tint.r, tint.g, tint.b, alpha)))
    return true
end

return M
