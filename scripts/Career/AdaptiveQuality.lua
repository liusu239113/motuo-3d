-- 自适应画质：按实测帧时自动升降档，能力强的设备保留全部细节，弱设备自动降档保帧。
-- 只调整渲染与NPC模拟预算，不删除任何场景内容、不改变碰撞与存档语义。
local Quality = {}

-- 档位从低到高。draw/shadow 缩放真实可见距离（图元数的主要来源），
-- near 是NPC做完整碰撞的半径；npcScale 缩放人群/行人的更新预算。
Quality.LEVELS = {
    { name = "低", hdr = false, specular = false, shadowMap = 512, anisotropy = 1, shadowFar = 40, draw = 0.45, shadow = 0.30, near = 45, npcScale = 0.5, trafficTicks = 1 },
    { name = "中", hdr = false, specular = true, shadowMap = 768, anisotropy = 2, shadowFar = 50, draw = 0.70, shadow = 0.60, near = 60, npcScale = 0.75, trafficTicks = 2 },
    { name = "高", hdr = true, specular = true, shadowMap = 1024, anisotropy = 4, shadowFar = 65, draw = 1.00, shadow = 1.00, near = 70, npcScale = 1.0, trafficTicks = 2 },
}

Quality.level = 3
-- 自动模式：按实测帧时升降档；关闭后固定玩家选择的档位。
Quality.auto = true
Quality.targetFrame = 1 / 60
-- 升档更保守：只有明显富余才升，避免在两档之间反复抖动。
Quality.DOWN_RATIO = 1.22
Quality.UP_RATIO = 0.62
Quality.WINDOW = 2.0
Quality.COOLDOWN = 3.0

local elapsed, frames = 0, 0
local cooldown = Quality.COOLDOWN
local sun_ = nil
local scene_ = nil
-- 记录每个可绘制物的原始距离，缩放后仍能还原，不做重复缩放。
local baseDistances = setmetatable({}, { __mode = "k" })

---@param sunlight Light?
function Quality.AttachSunlight(sunlight)
    sun_ = sunlight
    Quality.Apply(Quality.level)
end

---@param scene Scene?
function Quality.AttachScene(scene)
    scene_ = scene
    Quality.Apply(Quality.level)
end

---@return number 当前档位下NPC完整碰撞的半径（米）
function Quality.NearRadius() return Quality.LEVELS[Quality.level].near end

---@return table
function Quality.Current() return Quality.LEVELS[Quality.level] end

---@return integer
function Quality.TrafficTicks() return Quality.LEVELS[Quality.level].trafficTicks end

---@param level integer
function Quality.Apply(level)
    level = math.max(1, math.min(#Quality.LEVELS, level))
    Quality.level = level
    local cfg = Quality.LEVELS[level]
    renderer.hdrRendering = cfg.hdr
    renderer.specularLighting = cfg.specular
    renderer.shadowMapSize = cfg.shadowMap
    renderer.textureAnisotropy = cfg.anisotropy
    if sun_ then sun_.shadowCascade = CascadeParameters(8, cfg.shadowFar, 0, 0, .85) end
    Quality.ApplyDistances(cfg)
end

-- 遍历场景里的可绘制物，按档位缩放可见距离与阴影距离。这是图元数的主要来源，
-- 也是画质档位真正能改变帧率的地方；原始值在首次缩放前记录，随时可还原。
---@param cfg table
function Quality.ApplyDistances(cfg)
    local root = scene_
    if not root then return end
    local stack = { root }
    while #stack > 0 do
        local node = table.remove(stack)
        for _, child in ipairs(node:GetChildren()) do stack[#stack + 1] = child end
        for _, typeName in ipairs({ "StaticModel", "CustomGeometry", "AnimatedModel" }) do
            local draw = node:GetComponent(typeName)
            if draw then
                local base = baseDistances[draw]
                if not base then
                    base = { draw = draw.drawDistance, shadow = draw.shadowDistance }
                    baseDistances[draw] = base
                end
                draw.drawDistance = base.draw * cfg.draw
                draw.shadowDistance = base.shadow * cfg.shadow
            end
        end
    end
end

-- 手动切换档位（供画质菜单或验收脚本调用）。
---@param level integer
function Quality.Set(level)
    Quality.auto = false
    Quality.Apply(level)
    elapsed, frames, cooldown = 0, 0, Quality.COOLDOWN
end

---@param on boolean
function Quality.SetAuto(on)
    Quality.auto = on and true or false
    elapsed, frames, cooldown = 0, 0, Quality.COOLDOWN
    if Quality.auto then Quality.Apply(Quality.level) end
end

---@param rawDt number
function Quality.Update(rawDt)
    if not Quality.auto then return end
    if rawDt <= 0 or rawDt ~= rawDt or rawDt > .5 then return end
    elapsed = elapsed + rawDt
    frames = frames + 1
    cooldown = math.max(0, cooldown - rawDt)
    if elapsed < Quality.WINDOW then return end
    local average = elapsed / frames
    elapsed, frames = 0, 0
    if cooldown > 0 then return end
    if average > Quality.targetFrame * Quality.DOWN_RATIO and Quality.level > 1 then
        Quality.Apply(Quality.level - 1)
        cooldown = Quality.COOLDOWN
        print(string.format("[自适应画质] 平均帧时 %.1fms 低于目标，降到%s档", average * 1000, Quality.Current().name))
    elseif average < Quality.targetFrame * Quality.UP_RATIO and Quality.level < #Quality.LEVELS then
        Quality.Apply(Quality.level + 1)
        cooldown = Quality.COOLDOWN
        print(string.format("[自适应画质] 平均帧时 %.1fms 有余量，升到%s档", average * 1000, Quality.Current().name))
    end
end

return Quality
