-- 命中爆炸特效：使用美术提供的透明爆炸贴图（PNG 带 alpha），
-- 不自行绘制形状。每次爆炸是一个面向相机的公告板，按帧放大+淡出。
local V = Vector3
local M = {}

local TEXTURE = "image/weapon_explosion_fire_smoke_20261103171243.png"
local TECHNIQUE = "Techniques/DiffUnlitAlpha.xml"
M.Resources = {TEXTURE, TECHNIQUE, "Models/Plane.mdl"}
M.ResourceTypes = {[TEXTURE] = "Texture2D", [TECHNIQUE] = "Technique", ["Models/Plane.mdl"] = "Model"}

local LIFETIME = 0.7
local START_SCALE = 1.4
local END_SCALE = 5.2

---@class Explosion
---@field node Node
---@field age number
---@field scale number
---@field baseScale number
---@field material Material
---@field disposed boolean

---@param parent Node
---@return Explosion
local function create(parent)
    -- 资源先确认成功，再分配实例，避免首次加载失败留下半成品node/material。
    local model = cache:GetResource("Model", "Models/Plane.mdl")
    local technique = cache:GetResource("Technique", TECHNIQUE)
    local texture = cache:GetResource("Texture2D", TEXTURE)
    local node = parent:CreateChild("Explosion", LOCAL)
    local drawable = node:CreateComponent("StaticModel")
    -- Plane是XZ平面；用真实美术透明图承载，不自行绘制爆炸形状。
    drawable:SetModel(model)
    local material = Material:new()
    material:SetTechnique(0, technique)
    material:SetTexture(TU_DIFFUSE, texture)
    material:SetShaderParameter("MatDiffColor", Variant(Color(1, 1, 1, 1)))
    material.cullMode = CULL_NONE
    drawable:SetMaterial(material)
    drawable.castShadows = false
    drawable.drawDistance = 320
    -- 初始尺寸严格为零；下一次有时间步时才开始放大。
    node.scale = V.ZERO
    return {node = node, age = 0, scale = 0, baseScale = START_SCALE, material = material, disposed = false}
end

---@param parent Node
---@param entry table {x,y,z,age,scale}
---@return Explosion
function M.Spawn(parent, entry)
    local explosion = create(parent)
    explosion.node.position = V(entry.x, entry.y, entry.z)
    explosion.age = math.max(0, entry.age or 0)
    explosion.baseScale = START_SCALE * (entry.scale or 1)
    explosion.scale = 0
    explosion.node.scale = V.ZERO
    return explosion
end

---@param explosion Explosion
function M.Dispose(explosion)
    if explosion.disposed then return end
    explosion.disposed = true
    explosion.node:Dispose()
    explosion.material:Dispose()
end

---@param explosions Explosion[]
function M.Clear(explosions)
    for index = #explosions, 1, -1 do
        M.Dispose(explosions[index])
        table.remove(explosions, index)
    end
end

---@param explosion Explosion
---@param dt number
---@param cameraOrPosition Camera|Vector3?
---@return boolean alive
function M.Update(explosion, dt, cameraOrPosition)
    if explosion.disposed then return false end
    explosion.age = explosion.age + math.max(0, dt)
    if explosion.age >= LIFETIME then
        M.Dispose(explosion)
        return false
    end
    local t = explosion.age / LIFETIME
    -- 快速放大后缓慢收尾，符合爆炸的视觉节奏。
    local size = explosion.baseScale * (1 + (END_SCALE / START_SCALE - 1) * (1 - (1 - t) * (1 - t)))
    explosion.scale = size
    explosion.node.scale = V(size, size, size)
    -- Plane的局部法线沿Y；相机参数可用时完整跟随pitch/yaw/roll。
    local camera = cameraOrPosition and cameraOrPosition.node and cameraOrPosition or nil
    if camera then
        explosion.node.worldRotation = camera.node.worldRotation * Quaternion(90, 0, 0)
    elseif cameraOrPosition then
        local position = explosion.node.worldPosition
        local dx, dz = cameraOrPosition.x - position.x, cameraOrPosition.z - position.z
        if dx * dx + dz * dz > 1e-6 then
            explosion.node.rotation = Quaternion(0, math.deg(math.atan(dx, dz)), 0)
        end
    end
    -- 后半段淡出；DiffUnlitAlpha会采样真实贴图的alpha并叠加此整体透明度。
    local alpha = t < 0.45 and 1 or (1 - (t - 0.45) / 0.55)
    explosion.material:SetShaderParameter("MatDiffColor", Variant(Color(1, 1, 1, alpha)))
    return true
end

return M
