-- 正式环境独立验收：不加载Profile/Store、不读写玩家存档，不生成替代展示几何。
-- 直接构建真实World；所有阶段/yield完整执行，独立验收每Update最多推进8次。
-- 只验证完整静态环境与真实像素，不是产品加载性能测试。-environment-track=lake/circuit选择。
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
local view_ = "landscape"
local shotPrefix_ = ""
local renderFrames_ = 0
local finished_ = false
local probe_ = ""
local probeMode_ = "compat"
local probeInstances_ = 1

local function materialProbe()
    local paths = {
        fern = "uuid://HQorYSe7jArWJex9O-ITEOoJ",
        fernSmall = "uuid://Eqy3wSag5eJmQEQBqWnLcKwL",
        -- 护栏已改程序化，旧护栏材质探针不再适用。
        cone = "uuid://Fba9ASA3ZLeE2_Fb_Md4QJfF",
        sign = "uuid://BbhFaY-oq5NxPUutxC9s5YOQ",
        arrow = "uuid://FjoMmROgqb4dDyqNZCf6eElx",
    }
    local path = assert(paths[probe_], "未知真实材质探针：" .. probe_)
    assert(probeMode_ == "original" or probeMode_ == "compat" or probeMode_ == "paired", "未知探针材质模式")
    assert(probeInstances_ == 1 or probeInstances_ == 2, "仅验单实例或双实例批次")
    local original = assert(cache:GetResource("Material", path))
    local material = probeMode_ == "original" and original or Props.MaterialFor(path)
    if probeMode_ == "paired" then
        material = material:Clone()
        material:SetVertexShaderDefines(material.vertexShaderDefines .. " PACKEDNORMAL")
        material:SetPixelShaderDefines(material.pixelShaderDefines .. " PACKEDNORMAL")
    end
    print(string.format("[环境材质探针] %s mode=%s instances=%d VSDEF=%s PSDEF=%s", probe_, probeMode_,
        probeInstances_, material.vertexShaderDefines, material.pixelShaderDefines))
    for i = 0, material:GetNumTechniques() - 1 do
        for _, name in ipairs({"base", "litbase", "light", "shadow", "depth", "deferred"}) do
            local pass = material:GetTechnique(i):GetPass(name)
            if pass then print(string.format("[环境探针Pass] %s VS=%s PS=%s VD=%s PD=%s", name,
                pass.vertexShader, pass.pixelShader, pass.vertexShaderDefines, pass.pixelShaderDefines)) end
        end
    end
    scene_ = Scene()
    scene_:CreateComponent("Octree")
    local lightRoot = scene_:CreateChild("LightGroup")
    lightRoot:LoadXML(assert(cache:GetResource("XMLFile", "LightGroup/Daytime.xml")):GetRoot())
    renderer.hdrRendering = true
    renderer.dynamicInstancing = true
    renderer.minInstances = 2
    print("[环境材质探针] renderer.dynamicInstancing=true minInstances=2；双实例是否合批以实际INSTANCED编译日志为准")
    local parent = scene_:CreateChild("真实资产材质探针")
    for i = 1, probeInstances_ do
        local x = probeInstances_ == 1 and 0 or (i == 1 and -1.6 or 1.6)
        if probe_ == "arrow" then
            local node = parent:CreateChild("真实正式箭头")
            local model = assert(cache:GetResource("Model", "uuid://D_WEUc5wpVo9pjy4U8VhVjVV"))
            local scale = 2 / model.boundingBox.size.length
            node:SetScale(scale)
            node.position = Vector3(x, 0, 0) - model.boundingBox.center * scale
            local draw = node:CreateComponent("StaticModel")
            draw:SetModel(model)
            draw:SetMaterial(0, material)
            draw.castShadows = true
        else
            local _, draw = Props.Add(parent, probe_, Vector3(x, 0, 0), 2, 0, {shadow = true, distance = 60})
            draw:SetMaterial(0, material)
        end
    end
    cameraNode_ = scene_:CreateChild("MaterialProbeCamera")
    cameraNode_.position = Vector3(6, 4.5, -8)
    cameraNode_:LookAt(Vector3(0, 1, 0))
    local camera = cameraNode_:CreateComponent("Camera")
    camera.nearClip, camera.farClip = .1, 100
    renderer:SetViewport(0, Viewport:new(scene_, camera))
    SubscribeToEvent("PostRenderUpdate", "ScenicEnvironmentCheckPostRender")
    finished_ = true
    print("[环境材质探针] READY / 只检真实模型材质，不代表World通过")
end

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
        elseif draw.node:GetVar("LightweightRail"):GetBool() then
            -- 整条护栏已合批成一次draw，三角面数随赛道长度变化，不再是固定48面。
            railCount = railCount + 1
            local geometry=model:GetGeometry(0,0)
            local submitted=geometry.indexCount>0 and geometry.indexCount or geometry.vertexCount
            assert(not draw.castShadows and submitted>0 and submitted%144==0,
                "合批护栏必须是每段48面整数倍且关闭阴影："..tostring(submitted))
            local material=assert(draw:GetMaterial(0))
            assert(not material:GetTexture(TU_DIFFUSE) and not material:GetTexture(TU_NORMAL),
                "轻量护栏不得加载外部贴图")
        elseif model == cone then coneCount = coneCount + 1 end
        if model == treeModel or model == fern or model == fernSmall or model == rockA or model == rockB or model == cone then
            local scale = draw.node.scale
            assert(math.abs(scale.x - scale.y) < .00001 and math.abs(scale.y - scale.z) < .00001,
                "环境正式模型必须等比缩放")
            assert(draw:GetMaterial(0), "正式模型缺失原材质")
        end
    end
    assert(treeCount == stats.high + stats.canopyInstances, "环境树数量与真实MDL实例失配")
    -- 每144米合批成一块，draw数应等于赛道分块数，不是每段一个。
    local decor=require("TrackDecor").LastBuild
    assert(decor and railCount>0 and railCount<=math.ceil(9705/144)+1 and decor.rails>0
        and decor.rails<=decor.railLimit, "护栏必须按144米合批且段数在预算内")
    for _,path in ipairs(World.Resources) do
        assert(path~="uuid://FV7oke6s9852a30jMsdkkcC3" and path~="uuid://EuEAqVcEvrhrHsZmdxoee6N6",
            "生产预载清单不得保留旧护栏模型或材质")
    end
    assert(plantCount > 0 and rockCount > 0 and railCount > 0 and coneCount > 0, "草蕨/岩石/护栏/赛事标记不得缺失")
    assert(world.root:GetChild("随路线贴地发车标线", true), "起终点棋盘线与发车格必须保留")
    assert(world.mats.terrain:GetSurfaceTexture("grass_color") and world.mats.terrain:GetSurfaceTexture("rock_color"),
        "真实地形颜色贴图必须绑定")
    -- 必须在运动推进前验真实初相；模块只复制碰撞记录，不改真实World。
    require("CourseWorldChecks").Run(world)
    print(string.format("[正式环境验收] PASS %s trees=%d plants=%d rocks=%d rails=%d cones=%d / 原MDL四级LOD、原贴图、等比缩放、玩法标线",
        trackId_, treeCount, plantCount, rockCount, railCount, coneCount))
    local p, yaw = Landscape.RoadPoint(trackId_ == "lake" and Landscape.RouteLength * .36 or Landscape.RouteLength * .08)
    local camera = assert(cameraNode_)
    if view_ == "rails" then
        local rail=assert(world.root:GetChild("轻量程序化护栏",true),"必须显示生产场景的真实轻量护栏") --[[@as Node]]
        p=rail.worldPosition
        yaw=rail.worldRotation:YawAngle()
        local angle=math.rad(yaw)
        camera.position=p+Vector3(math.cos(angle)*5-math.sin(angle)*6,3.2,
            -math.sin(angle)*5-math.cos(angle)*6)
        camera:LookAt(p+Vector3(0,.55,0))
    elseif view_ == "course" then
        local found = false
        for _, obstacle in ipairs(world.mixedObstacles) do
            if obstacle.kind == "pendulum" then
                p, yaw = assert(obstacle.node).worldPosition, obstacle.yaw
                found = true
                break
            end
        end
        assert(found, "机关近景必须存在真实摆锤/支架，不造展示替代品")
        local angle = math.rad(yaw)
        camera.position = p + Vector3(math.cos(angle) * 7 - math.sin(angle) * 10, 6,
            -math.sin(angle) * 7 - math.cos(angle) * 10)
        camera:LookAt(p + Vector3(0, 2.7, 0))
        print("[正式环境验收] course镜头真实摆锤/支架 yaw=" .. yaw)
    else
        local angle = math.rad(yaw)
        camera.position = p + Vector3(-math.sin(angle) * 25, 12, -math.cos(angle) * 25)
            + Vector3(math.cos(angle) * 11, 0, -math.sin(angle) * 11)
        camera:LookAt(p + Vector3(0, 2, 0))
    end
    finished_ = true
end

function Start()
    local materialsOnly = false
    for _, arg in ipairs(GetArguments()) do
        trackId_ = arg:match("^%-environment%-track=(.+)$") or trackId_
        view_ = arg:match("^%-environment%-view=(.+)$") or view_
        shotPrefix_ = arg:match("^%-environment%-shots=(.+)$") or shotPrefix_
        probe_ = arg:match("^%-environment%-material%-probe=(.+)$") or probe_
        probeMode_ = arg:match("^%-environment%-probe%-mode=(.+)$") or probeMode_
        probeInstances_ = tonumber(arg:match("^%-environment%-probe%-instances=(.+)$")) or probeInstances_
        if arg == "-environment-materials-only" then materialsOnly = true end
    end
    assert(shotPrefix_ == "" or shotPrefix_:match("^screenshots/environment%-official/[%w_-]+$"),
        "验收图片只写screenshots/environment-official下的显式前缀")
    if probe_ ~= "" then materialProbe(); return end
    if materialsOnly then
        for _, path in ipairs(Props.Resources) do
            if Props.ResourceTypes[path] == "Material" then
                local original = assert(cache:GetResource("Material", path))
                local material = Props.MaterialFor(path)
                assert(material == Props.MaterialFor(path), "正式资产兼容材质必须共享")
                assert(material:GetTexture(TU_DIFFUSE) == original:GetTexture(TU_DIFFUSE)
                    and material:GetTexture(TU_NORMAL) == original:GetTexture(TU_NORMAL), "兼容材质不得替换原贴图")
                assert(material.cullMode == original.cullMode and material.alphaToCoverage == original.alphaToCoverage,
                    "兼容材质不得更改alpha/cull状态")
                local diffuse, normal = material:GetTexture(TU_DIFFUSE), material:GetTexture(TU_NORMAL)
                print(string.format("[环境材质诊断] %s D=%s N=%s VSDEF=%s PSDEF=%s cull=%s A2C=%s",
                    path, diffuse and diffuse.name or "nil", normal and normal.name or "nil",
                    material.vertexShaderDefines, material.pixelShaderDefines,
                    tostring(material.cullMode), tostring(material.alphaToCoverage)))
                for i = 0, material:GetNumTechniques() - 1 do
                    local technique = material:GetTechnique(i)
                    print("[环境材质Technique] " .. path .. " " .. technique.name)
                    for _, name in ipairs({"base", "litbase", "light", "shadow", "prepass", "deferred", "alpha"}) do
                        local pass = technique:GetPass(name)
                        if pass then print(string.format("[环境材质Pass] %s %s VS=%s PS=%s VD=%s PD=%s blend=%s",
                            path, name, pass.vertexShader, pass.pixelShader, pass.vertexShaderDefines,
                            pass.pixelShaderDefines, tostring(pass.blendMode))) end
                    end
                end
            end
        end
        print("[环境材质诊断] COMPLETE")
        finished_ = true
        return
    end
    assert(trackId_ == "lake" or trackId_ == "circuit", "仅验收lake/circuit真实环境")
    assert(view_ == "landscape" or view_ == "course" or view_ == "rails", "仅支持真实环境全景/机关/护栏近景")
    assert(shotPrefix_ == "" or shotPrefix_:match("^screenshots/environment%-official/[%w_-]+$"),
        "验收图片只写screenshots/environment-official下的显式前缀")
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
    SubscribeToEvent("PostRenderUpdate", "ScenicEnvironmentCheckPostRender")
end

-- 完整真实World验收成功后才推进运动，固定1/30秒用于可重复的两个真实相位截图。
-- 不依赖全局启动帧，不把初始化期间的默认相机画面当作环境通过证据。
function ScenicEnvironmentCheckPostRender()
    if not finished_ or not scene_ then return end
    renderFrames_ = renderFrames_ + 1
    if shotPrefix_ ~= "" and (renderFrames_ == 4 or renderFrames_ == 28) then
        local image = Image()
        local path = shotPrefix_ .. "-" .. view_ .. "-phase" .. renderFrames_ .. ".png"
        local captured = graphics:TakeScreenShot(image)
        local saved = captured and image:SavePNG(path)
        image:Dispose()
        assert(saved, "真实环境完成后截图失败：" .. path)
        print("[正式环境验收] 正确阶段截图 " .. path .. " motion=" .. (renderFrames_ / 30))
    end
    if world_ then require("MixedCourse").Update(world_, renderFrames_ / 30) end
end

function ScenicEnvironmentCheckUpdate()
    if finished_ then return end
    local task = preparation_
    for _ = 1, 8 do
        if finished_ or not task or coroutine.status(task) == "dead" then break end
        local ok, message = coroutine.resume(task)
        assert(ok, "真实环境构建失败：" .. tostring(message))
    end
end

function Stop()
    preparation_, world_, scene_, cameraNode_ = nil, nil, nil, nil
end
