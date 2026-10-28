-- 同场景低频后视摄像头 -> 单共享RT -> 左右镜片。
-- 这是后视摄像头近似：两镜共享画面，不是按眼位/镜面平面求解的物理反射。
-- 渲染目标生命周期基于 scene-to-nanovg.md；镜片网格基于 video-screen-3d.md。
---@class RearMirrorFace
---@field node Node
---@field geometry CustomGeometry
---@field material Material

---@class RearMirrors
---@field scene Scene
---@field cameraNode Node
---@field camera Camera
---@field faces RearMirrorFace[]
---@field texture Texture2D?
---@field surface RenderSurface?
---@field viewport Viewport?
---@field high boolean
---@field interval number
---@field elapsed number
---@field active boolean
---@field failed boolean
---@field disposed boolean
local RearMirrors = {}
RearMirrors.__index = RearMirrors

-- 主相机默认全mask可见；后视相机只剔除这个专用bit。
-- 世界物件保留默认mask，不必遍历整张世界重分层。
RearMirrors.COCKPIT_MASK = 0x40000000
RearMirrors.REAR_MASK = 0xBFFFFFFF

---@param scene Scene
---@param bikeRoot Node 不随车把转向和车身roll变化，仅跟随车辆世界heading
---@param eyeHeight number
---@return RearMirrors
function RearMirrors.New(scene, bikeRoot, eyeHeight)
    local self = setmetatable({}, RearMirrors)
    self:Init(scene, bikeRoot, eyeHeight)
    return self
end

---@param scene Scene
---@param bikeRoot Node
---@param eyeHeight number
function RearMirrors:Init(scene, bikeRoot, eyeHeight)
    self.scene = scene
    self.cameraNode = bikeRoot:CreateChild("SharedRearViewCamera")
    -- 引擎前向+Z，绕Y转180度看向实际后方-Z；安装在尾部上方避开车身。
    self.cameraNode.position = Vector3(0, eyeHeight, -1.20)
    self.cameraNode.rotation = Quaternion(6, 180, 0)
    self.camera = self.cameraNode:CreateComponent("Camera")
    self.camera.nearClip, self.camera.farClip, self.camera.fov = 0.12, 450, 54
    self.camera.autoAspectRatio, self.camera.aspectRatio = false, 2
    self.camera.viewMask = RearMirrors.REAR_MASK
    -- 小后视图关闭额外阴影与软件遮挡；恢复首轮已成功出图的view flags做单变量对照。
    self.camera.viewOverrideFlags = VO_DISABLE_SHADOWS | VO_DISABLE_OCCLUSION
    self.faces = {}
    self.texture, self.surface, self.viewport = nil, nil, nil
    self.high, self.interval, self.elapsed = false, 0.1, 0
    self.active, self.failed, self.disposed = false, false, false
end

---@param parent Node
---@param position Vector3
---@param width number
---@param height number
---@return Node
function RearMirrors:AddFace(parent, position, width, height)
    local node = parent:CreateChild("LiveRearMirrorGlass")
    node.position = position
    local geometry = node:CreateComponent("CustomGeometry")
    geometry:SetNumGeometries(1)
    geometry:BeginGeometry(0, TRIANGLE_LIST)
    -- 顺时针切角轮廓朝骑手(-Z)，每个点按平面位置计算同一套UV，不拉伸角落。
    -- UV横向镜像让左右与实体后视镜一致，v=0对应上缘。
    local hw, hh = width * 0.5, height * 0.5
    local cut = height * 0.16
    local outline = {
        Vector3(-hw + cut, -hh, 0), Vector3(-hw, -hh + cut, 0),
        Vector3(-hw, hh - cut, 0), Vector3(-hw + cut, hh, 0),
        Vector3(hw - cut, hh, 0), Vector3(hw, hh - cut, 0),
        Vector3(hw, -hh + cut, 0), Vector3(hw - cut, -hh, 0),
    }
    for i, point in ipairs(outline) do
        local nextPoint = outline[i % #outline + 1]
        for _, vertex in ipairs({Vector3.ZERO, point, nextPoint}) do
            geometry:DefineVertex(vertex)
            geometry:DefineNormal(Vector3(0, 0, -1))
            geometry:DefineTexCoord(Vector2(0.5 - vertex.x / width, 0.5 - vertex.y / height))
        end
    end
    geometry:Commit()
    local material = Material:new()
    local technique = assert(cache:GetResource("Technique", "Techniques/DiffUnlit.xml"), "Missing rear mirror unlit technique")
    material:SetTechnique(0, technique)
    material:SetShaderParameter("MatDiffColor", Variant(Color(0.025, 0.035, 0.04, 1)))
    material.cullMode = CULL_NONE
    if self.texture then
        material:SetTexture(TU_DIFFUSE, self.texture)
        material:SetShaderParameter("MatDiffColor", Variant(Color(1, 1, 1, 1)))
    end
    geometry.material, geometry.castShadows = material, false
    geometry.viewMask = RearMirrors.COCKPIT_MASK
    self.faces[#self.faces + 1] = {node = node, geometry = geometry, material = material}
    return node
end

---@param high boolean
function RearMirrors:SetQuality(high)
    if self.disposed or self.high == high then return end
    self.high, self.interval = high, high and 1 / 15 or 0.1
    self.failed = false
    if self.texture then self:CreateTarget() end
end

---@return boolean
function RearMirrors:CreateTarget()
    local width, height = self.high and 384 or 256, self.high and 192 or 128
    local texture = Texture2D:new()
    texture:SetNumLevels(1)
    texture:SetFilterMode(FILTER_BILINEAR)
    texture:SetAddressMode(COORD_U, ADDRESS_CLAMP)
    texture:SetAddressMode(COORD_V, ADDRESS_CLAMP)
    if not texture:SetSize(width, height, Graphics:GetRGBAFormat(), TEXTURE_RENDERTARGET) then
        texture:Dispose()
        self.failed = true
        print("[后视镜] 无法创建RT，保留暗色镜片，不重复分配")
        return false
    end
    local path = cache:GetResource("XMLFile", "RenderPaths/Forward.xml")
    if not path then
        texture:Dispose()
        self.failed = true
        print("[后视镜] 缺少RenderPaths/Forward.xml，停止后视渲染")
        return false
    end
    local viewport = Viewport:new(self.scene, self.camera)
    viewport:SetRenderPath(path)
    viewport:SetDrawDebug(false)
    local surface = texture:GetRenderSurface()
    surface:SetUpdateMode(SURFACE_MANUALUPDATE)
    surface:SetViewport(0, viewport)
    -- 换质量时先替换所有引用，再释放旧RT；不让镜片引用已释放纹理。
    local oldTexture, oldSurface = self.texture, self.surface
    for _, face in ipairs(self.faces) do
        face.material:SetTexture(TU_DIFFUSE, texture)
        face.material:SetShaderParameter("MatDiffColor", Variant(Color(1, 1, 1, 1)))
    end
    self.texture, self.surface, self.viewport = texture, surface, viewport
    if oldSurface then oldSurface:SetNumViewports(0) end
    if oldTexture then oldTexture:Dispose() end
    self.elapsed = self.interval
    print(string.format("[后视镜] 单共享后视RT %dx%d / %dHz，后视摄像头近似，非物理平面镜", width, height, self.high and 15 or 10))
    return true
end

---@param dt number
---@param active boolean 仅由主流程在ride且第一人称时传true
function RearMirrors:Update(dt, active)
    -- surfaceless GLES仍可真实渲染；不把engine.headless当作无GPU的判据。
    if self.disposed or not graphics.initialized or graphics.apiName:lower() == "noop" then return end
    if not active then
        self.active, self.elapsed = false, self.interval
        return
    end
    if self.failed then return end
    if not self.texture and not self:CreateTarget() then return end
    if not self.active then self.elapsed = self.interval end
    self.active = true
    self.elapsed = self.elapsed + math.max(0, dt)
    if self.elapsed < self.interval then return end
    self.elapsed = self.elapsed % self.interval
    local surface = self.surface
    if surface then surface:QueueUpdate() end
end

function RearMirrors:Dispose()
    if self.disposed then return end
    self.disposed, self.active = true, false
    local surface = self.surface
    if surface then surface:SetNumViewports(0) end
    -- 先销毁拥有材质引用的镜片，再释放自己的材质和纹理。
    for _, face in ipairs(self.faces) do
        face.node:Dispose()
        face.material:Dispose()
    end
    self.faces = {}
    self.cameraNode:Dispose()
    local texture = self.texture
    if texture then texture:Dispose() end
    self.texture, self.surface, self.viewport = nil, nil, nil
end

return RearMirrors
