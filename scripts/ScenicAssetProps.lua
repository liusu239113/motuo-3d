-- 正式环境资产登记：UUID来自已有已用资源/资源库prefab_xml，不生成或变形网格。
local Props = {}

---@class ScenicPropDefinition
---@field model string
---@field materials string[]
---@field distance number

---@type table<string, ScenicPropDefinition>
local definitions = {
    fern = {model = "uuid://GwWKaX_PkE_lqde8fldtFk9F", materials = {"uuid://HQorYSe7jArWJex9O-ITEOoJ"}, distance = 120},
    -- search: BIkOmSAjYs5zSJtbpNguZ-PI，小型绿色蕨类，原始朝向无需修正。
    fernSmall = {model = "uuid://C_GzwbWfJNhFoj-_rEtT7HtV", materials = {"uuid://Eqy3wSag5eJmQEQBqWnLcKwL"}, distance = 100},
    rockA = {model = "uuid://As2_acelV1DosNkDmeMasF4T", materials = {"uuid://ETwgwdlLT9yb0fm2NxmLlURS"}, distance = 420},
    rockB = {model = "uuid://DAxRITvZ1vC60um7M6gXY_Va", materials = {"uuid://HDoGiRhCA1ZwjewmLbRqhTOq"}, distance = 420},
    house = {model = "uuid://D6f5ARUOv2X7EEmXLSrx1AM9", materials = {
        "uuid://Bu1-aXStY3WMbN0SDgV_0J8L", "uuid://HntT6UQGaB9sTTQOuRq_XVBm",
        "uuid://HhdXudJoS_1n5psy_52upCCB", "uuid://BYUaAXeDcr7-GOyrJkX2dGoW"}, distance = 650},
    -- search: Br_YoSXhOaEhODVz4e6GInjs，宽X/高Y/薄Z的完整道路护栏。
    rail = {model = "uuid://FV7oke6s9852a30jMsdkkcC3", materials = {"uuid://EuEAqVcEvrhrHsZmdxoee6N6"}, distance = 230},
    -- search: BrMPQVbouuJ6tP9-opAx9Z5U，完整锥标（不是圆锥+盒底拼装）。
    cone = {model = "uuid://CGp6ca4NUVz_7_-kG06v5Ayb", materials = {"uuid://Fba9ASA3ZLeE2_Fb_Md4QJfF"}, distance = 170},
    -- search: FrQg4QaANHut5x8w5j9xtpVA，Y-up完整木质路标。
    sign = {model = "uuid://A3mHIaEpY-nhUpnHW2XJL2Ka", materials = {"uuid://BbhFaY-oq5NxPUutxC9s5YOQ"}, distance = 240},
}

Props.Resources, Props.ResourceTypes = {}, {}
local function register(path, kind)
    if Props.ResourceTypes[path] then return end
    Props.Resources[#Props.Resources + 1] = path
    Props.ResourceTypes[path] = kind
end
-- 稳定清单顺序，RideLoader递归下载材质完整依赖，并逐项校验Model/Material。
for _, id in ipairs({"fern", "fernSmall", "rockA", "rockB", "house", "rail", "cone", "sign"}) do
    local def = assert(definitions[id])
    register(def.model, "Model")
    for _, path in ipairs(def.materials) do register(path, "Material") end
end

---@type table<string, Model>
local models = {}
---@type table<string, Material>
local materials = {}

---@param id string
---@return Model
local function modelFor(id)
    local def = assert(definitions[id], "未知环境资产：" .. id)
    if not models[id] then models[id] = assert(cache:GetResource("Model", def.model), "环境模型未预载：" .. def.model) end
    return models[id]
end

-- 只以真实包围盒计算等比缩放，绝不分别拉伸XYZ来适应旧拼模尺寸。
---@param id string
---@param height number
---@return Vector3, number, number
function Props.Measure(id, height)
    local bounds = modelFor(id).boundingBox
    assert(bounds.size.y > 0.0001, "环境资产高度无效：" .. id)
    local scale = height / bounds.size.y
    local size = bounds.size * scale
    return size, .5 * math.sqrt(size.x * size.x + size.z * size.z), scale
end

---@class ScenicPropOptions
---@field distance? number
---@field shadow? boolean
---@field lodBias? number

---@param parent Node
---@param id string
---@param position Vector3
---@param height number
---@param yaw number
---@param options? ScenicPropOptions
---@return Node, StaticModel
function Props.Add(parent, id, position, height, yaw, options)
    local def = assert(definitions[id])
    local model = modelFor(id)
    local bounds = model.boundingBox
    local _, _, scale = Props.Measure(id, height)
    local root = parent:CreateChild("正式资产_" .. id)
    root.position = position
    root.rotation = Quaternion(0, yaw, 0)
    local mesh = root:CreateChild("共享原始网格与贴图")
    mesh:SetScale(scale)
    mesh.position = Vector3(-bounds.center.x, -bounds.min.y, -bounds.center.z) * scale
    local drawable = mesh:CreateComponent("StaticModel")
    drawable:SetModel(model)
    for i, path in ipairs(def.materials) do
        if not materials[path] then materials[path] = assert(cache:GetResource("Material", path), "环境材质未预载：" .. path) end
        assert(drawable:SetMaterial(i - 1, materials[path]), "环境资产材质槽不匹配：" .. id)
    end
    drawable.castShadows = options ~= nil and options.shadow == true
    drawable.shadowDistance = drawable.castShadows and 45 or 0
    drawable.drawDistance = options and options.distance or def.distance
    drawable.lodBias = options and options.lodBias or .45
    return root, drawable
end

-- 占地俯视：完整旋转模型包围矩形 + margin；九点必须在干地、车道/路肩/机关外。
-- 大岩石允许适当埋地；设施/小植物控制地形高差，不用底座盒体修补悬空。
-- 擦边、折返、跨支路、海滩水线、坡面角点均拒绝；不新增物理碰撞。
---@param L table
---@param id string
---@param x number
---@param z number
---@param height number
---@param yaw number
---@param margin? number
---@param maxRise? number
---@param sink? number
---@return Vector3?, number
function Props.GroundSite(L, id, x, z, height, yaw, margin, maxRise, sink)
    local size, radius = Props.Measure(id, height)
    local angle = math.rad(yaw)
    local right = Vector3(math.cos(angle), 0, -math.sin(angle))
    local forward = Vector3(math.sin(angle), 0, math.cos(angle))
    local low, high = math.huge, -math.huge
    local clearance = margin or .4
    for ix = -1, 1 do
        for iz = -1, 1 do
            local p = Vector3(x, 0, z) + right * (ix * (size.x * .5 + clearance))
                + forward * (iz * (size.z * .5 + clearance))
            local _, onRoad = L.Height(p.x, p.z)
            if onRoad or L.RoadHeight(p.x, p.z) ~= nil or L.WaterDepth(p.x, p.z) > .01
                or (L.RampAt and L.RampAt(p.x, p.z)) then return nil, radius end
            local y = L.TerrainHeight(p.x, p.z)
            if L.Track.water and y < L.WaterLevel + .18 then return nil, radius end
            for _, bay in ipairs(L.Laybys or {}) do
                if (p.x - bay.x)^2 + (p.z - bay.z)^2 < 22^2 then return nil, radius end
            end
            low, high = math.min(low, y), math.max(high, y)
        end
    end
    -- 最近主路中心距离的包围圆补检，防止窄车道从九点采样之间穿过。
    local station = L.NearestRoad(x, z)
    local nearest = L.RoadPoint(station)
    if (x - nearest.x)^2 + (z - nearest.z)^2 < (L.Roads[1].shoulder + radius + clearance)^2 then return nil, radius end
    if high - low > (maxRise or .45) then return nil, radius end
    local y = L.TerrainHeight(x, z) - (sink or .03)
    return Vector3(x, y, z), radius
end

return Props
