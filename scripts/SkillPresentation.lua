-- 基于scaffold-3d-scene的父子节点表现层；只读弹体仿真，不实现伤害、追踪或boost。
-- 正式资源 b68c50c6-9177-5315-b53c-3080ad11b4aa，ZIP SHA256:
-- 958ae17a7138c29eac8962208c29c7af807dce24e8e0aaa3526da465c85f4e2f
local Skill = {}
local MODEL = "model/b68c50c6-9177-5315-b53c-3080ad11b4aa/Meshes/3e646daa3cdc44148f0153b1fb5bd7b9.mdl"
local MATERIAL = "model/b68c50c6-9177-5315-b53c-3080ad11b4aa/Materials/3e646daa3cdc44148f0153b1fb5bd7b9_00_tripo_material_c5aca450-1758-4cd6-a448-d9b8f219a1b9.xml"
-- Textures/*xml是构建期导入设置，不作为独立运行时资源预载；只登记真实图片。
local DIFFUSE_IMAGE = "model/b68c50c6-9177-5315-b53c-3080ad11b4aa/Textures/3e646daa3cdc44148f0153b1fb5bd7b9_00_D.jpg"
local NORMAL_IMAGE = "model/b68c50c6-9177-5315-b53c-3080ad11b4aa/Textures/3e646daa3cdc44148f0153b1fb5bd7b9_00_N.jpg"
local TECHNIQUE = "Techniques/PBR/PBRDiffNormal.xml"
local TRAIL_TECHNIQUE = "Techniques/NoTextureUnlit.xml"
Skill.Resources = {MODEL, MATERIAL, DIFFUSE_IMAGE, NORMAL_IMAGE, TECHNIQUE, TRAIL_TECHNIQUE}
Skill.ResourceTypes = {[MODEL] = "Model", [MATERIAL] = "Material",
    [DIFFUSE_IMAGE] = "Texture2D", [NORMAL_IMAGE] = "Texture2D", [TECHNIQUE] = "Technique", [TRAIL_TECHNIQUE] = "Technique"}
---@type Material?
local trailMaterial = nil
local function getTrailMaterial()
    if trailMaterial then return trailMaterial end
    local material = Material:new()
    material:SetTechnique(0, assert(cache:GetResource("Technique", TRAIL_TECHNIQUE)))
    material:SetShaderParameter("MatDiffColor", Variant(Color(1, .72, .34, 1)))
    material.cullMode = CULL_NONE
    trailMaterial = material
    return material
end

---@class SkillProjectilePresentation
---@field kind string
---@field node? Node
---@field trail? RibbonTrail
---@field x number
---@field y number
---@field z number
---@field vx number
---@field vy number
---@field vz number

-- model-info: Min(-.0751953,-.0634766,-.499023), Max(.0751953,.0634766,.499023).
-- LOD0顶点截面确认：尾翼位于-Z，尖头为+Z；原网格前向已经正确，无需扭转。
-- 长度1m、含翼宽约.151m，严格等比缩放，不削翼、不套Sphere或另造尾焰。
---@param parent Node
---@param shot SkillProjectilePresentation
function Skill.UpdateShot(parent, shot)
    -- 坦克炮弹与直升机导弹都使用正式导弹网格；水母仍不需要视觉弹体。
    if shot.kind ~= "helicopter" and shot.kind ~= "tank" then return end
    if not shot.node then
        local model = assert(cache:GetResource("Model", MODEL), "正式导弹网格未预载")
        local material = assert(cache:GetResource("Material", MATERIAL), "正式导弹材质未预载")
        local bounds = model.boundingBox
        assert(bounds.size.z > .001, "正式导弹长轴无效")
        -- 坦克炮弹比导弹粗短一些，仍是同一正式网格等比缩放。
        local scale = (shot.kind == "tank" and 1.5 or 1.0) / bounds.size.z
        local root = parent:CreateChild("SkillProjectile_Missile", LOCAL)
        local mesh = root:CreateChild("正式导弹_含尾翼", LOCAL)
        mesh:SetScale(scale)
        mesh.position = -bounds.center * scale
        local drawable = mesh:CreateComponent("StaticModel")
        drawable:SetModel(model)
        drawable:SetMaterial(material)
        drawable.drawDistance, drawable.shadowDistance = 220, 0
        drawable.castShadows = false
        shot.node = root
        local trail = root:CreateComponent("RibbonTrail")
        trail:SetMaterial(getTrailMaterial())
        trail:SetTrailType(TT_FACE_CAMERA)
        trail:SetWidth(0.16)
        trail:SetStartColor(Color(1, .72, .34, .95))
        trail:SetEndColor(Color(1, .14, .02, 0))
        trail:SetStartScale(1)
        trail:SetEndScale(.18)
        trail:SetLifetime(.28)
        trail:SetVertexDistance(.08)
        trail:SetSorted(true)
        trail:SetEmitting(true)
        trail:Commit()
        shot.trail = trail
        print("[技能表现] 正式导弹生成 · 等比缩放 · 追踪尾迹已启用")
    end
    -- 玩家/AI共用同一shot；不积分位置，不增加视觉飞行时间，命中由MixedRace销毁shot.node。
    shot.node.position = Vector3(shot.x, shot.y, shot.z)
    local horizontal = math.sqrt(shot.vx * shot.vx + shot.vz * shot.vz)
    if horizontal > .0001 or math.abs(shot.vy) > .0001 then
        local pitch = -math.deg(math.atan(shot.vy, horizontal))
        local yaw = math.deg(math.atan(shot.vx, shot.vz))
        shot.node.rotation = Quaternion(pitch, yaw, 0)
    end
end

-- 父表现树销毁前解除仿真引用，避免Race.Stop再次释放已销毁的子节点。
---@param shots SkillProjectilePresentation[]
function Skill.Clear(shots)
    for _, shot in ipairs(shots) do
        if shot.node then shot.node:Dispose(); shot.node = nil end
    end
end

return Skill
