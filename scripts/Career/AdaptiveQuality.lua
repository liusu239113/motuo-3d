-- 自适应画质：按实测帧时自动升降档，能力强的设备保留全部细节，弱设备自动降档保帧。
-- 只调整渲染与NPC模拟预算，不删除任何场景内容、不改变碰撞与存档语义。
local Quality = {}

-- 档位从低到高。渲染项直接映射引擎字段；npcScale 缩放交通/行人的更新预算。
Quality.LEVELS = {
    { name = "低", hdr = false, specular = false, shadowMap = 512, anisotropy = 1, shadowFar = 40, npcScale = 0.5, trafficTicks = 1 },
    { name = "中", hdr = false, specular = true, shadowMap = 768, anisotropy = 2, shadowFar = 50, npcScale = 0.75, trafficTicks = 2 },
    { name = "高", hdr = true, specular = true, shadowMap = 1024, anisotropy = 4, shadowFar = 65, npcScale = 1.0, trafficTicks = 2 },
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

---@param sunlight Light?
function Quality.AttachSunlight(sunlight)
    sun_ = sunlight
    Quality.Apply(Quality.level)
end

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
