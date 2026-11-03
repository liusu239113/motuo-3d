-- 正式环境独立验收：不加载Profile/Store、不读写玩家存档，不生成替代展示几何。
-- 直接构建真实World；构建与产品相同按进度回调yield，-environment-track=lake/circuit选择。
local World = require("World")
local Landscape = require("Landscape")
local Trees = require("ScenicTrees")
local Props = require("ScenicAssetProps")
---@type Scene?
local scene_ = nil
---@type World?
local world_ = nil
---@type thread?
local preparation_ = nil
---@type Node?
local cameraNode_ = nil
local trackId_ = "lake"
local finished_ = false

local function checkEnvironment()
    local world = assert(world_)
    local stats = Trees.Stats()
    assert(stats.proceduralTrees == 0 and stats.canopyInstances == stats.middle + stats.far,
        "树木必须使用完整正式实例，不可把手写树冠算作MDL")
    assert(stats.canopyInstances > 0 and stats.canopyInstances <= stats.canopyLimit,
        "中远树林不得删空或超过正式实例预算")
    local treeModel = assert(cache:GetResource("Model", Trees.Resources[1]))
    local treeCount, plantCount, rockCount, railCount, coneCount = 0, 0, 0, 0, 0
    local fern = assert(cache:GetResource("Model", "uuid://GwWKaX_PkE_lqde8fldtFk9F"))
    local fernSmall = assert(cache:GetResource("Model", "uuid://C_GzwbWfJNhFoj-_rEtT7HtV"))
    local rockA = assert(cache:GetResource("Model", "uuid://As2_acelV1DosNkDmeMasF4T"))
    local rockB = assert(cache:GetResource("Model", "uuid://DAxRITvZ1vC60um7M6gXY_Va"))
    local rail = assert(cache:GetResource("Model", "uuid://FV7oke6s9852a30jMsdkkcC3"))
    local cone = assert(cache:GetResource("Model", "uuid://CGp6ca4NUVz_7_-kG06v5Ayb"))
    ---@type Material?
    local sharedTreeMaterial = nil
    for _, draw in ipairs(world.root:GetComponents("StaticModel", true)) do
        local model = draw:GetModel()
        if model == treeModel then
            treeCount = treeCount + 1
            assert(model:GetNumGeometryLodLevels(0) == 4, "正式树四级LOD必须完整")
            local mat = assert(draw:GetMaterial(0))
            assert(mat:GetTexture(TU_DIFFUSE) and mat:GetTexture(TU_NORMAL), "正式树必须完整颜色/法线图集")
            if sharedTreeMaterial then assert(mat == sharedTreeMaterial, "树实例必须共享材质") else sharedTreeMaterial = mat end
        elseif model == fern or model == fernSmall then plantCount = plantCount + 1
        elseif model == rockA or model == rockB then rockCount = rockCount + 1
        elseif model == rail then railCount = railCount + 1
        elseif model == cone then coneCount = coneCount + 1 end
        if model == treeModel or model == fern or model == fernSmall or model == rockA or model == rockB or model == rail or model == cone then
            local scale = draw.node.scale
            assert(math.abs(scale.x - scale.y) < .00001 and math.abs(scale.y - scale.z) < .00001,
                "环境正式模型必须等比缩放")
            assert(draw:GetMaterial(0), "正式模型缺失原材质")
        end
    end
    assert(treeCount == stats.high + stats.canopyInstances, "环境树数量与真实MDL实例失配")
    assert(plantCount > 0 and rockCount > 0 and railCount > 0 and coneCount > 0, "草蕨/岩石/护栏/赛事标记不得缺失")
    assert(world.root:GetChild("随路线贴地发车标线", true), "起终点棋盘线与发车格必须保留")
    assert(world.mats.terrain:GetSurfaceTexture("grass_color") and world.mats.terrain:GetSurfaceTexture("rock_color"),
        "真实地形颜色贴图必须绑定")
    print(string.format("[正式环境验收] PASS %s trees=%d plants=%d rocks=%d rails=%d cones=%d / 原MDL四级LOD、原贴图、等比缩放、玩法标线",
        trackId_, treeCount, plantCount, rockCount, railCount, coneCount))
    local p, yaw = Landscape.RoadPoint(trackId_ == "lake" and Landscape.RouteLength * .36 or Landscape.RouteLength * .08)
    local camera = assert(cameraNode_)
    local angle = math.rad(yaw)
    camera.position = p + Vector3(-math.sin(angle) * 25, 12, -math.cos(angle) * 25)
        + Vector3(math.cos(angle) * 11, 0, -math.sin(angle) * 11)
    camera:LookAt(p + Vector3(0, 2, 0))
    finished_ = true
end

function Start()
    for _, arg in ipairs(GetArguments()) do trackId_ = arg:match("^%-environment%-track=(.+)$") or trackId_ end
    assert(trackId_ == "lake" or trackId_ == "circuit", "仅验收lake/circuit真实环境")
    assert(Landscape.SelectTrack(trackId_))
    scene_ = Scene()
    scene_:CreateComponent("Octree")
    local lightRoot = scene_:CreateChild("LightGroup")
    lightRoot:LoadXML(assert(cache:GetResource("XMLFile", "LightGroup/Daytime.xml")):GetRoot())
    renderer.hdrRendering = true
    cameraNode_ = scene_:CreateChild("EnvironmentCheckCamera")
    local camera = cameraNode_:CreateComponent("Camera")
    camera.nearClip, camera.farClip, camera.fov = .2, 1800, 62
    renderer:SetViewport(0, Viewport:new(scene_, camera))
    -- 跟产品一样先验证全部正式资源，不以缓存空占位当PASS。
    for _, path in ipairs(Props.Resources) do assert(cache:GetResource(Props.ResourceTypes[path], path), "正式环境资源不可载入：" .. path) end
    preparation_ = coroutine.create(function()
        world_ = World.New(assert(scene_), function() coroutine.yield() end)
        checkEnvironment()
    end)
    SubscribeToEvent("Update", "ScenicEnvironmentCheckUpdate")
end

function ScenicEnvironmentCheckUpdate()
    if finished_ then return end
    local task = preparation_
    if task and coroutine.status(task) ~= "dead" then
        local ok, message = coroutine.resume(task)
        assert(ok, "真实环境构建失败：" .. tostring(message))
    end
end

function Stop()
    preparation_, world_, scene_, cameraNode_ = nil, nil, nil, nil
end
