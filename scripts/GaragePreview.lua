-- Independent showroom, based on scaffold-3d-scene + scene-to-nanovg recipe.
-- 车库只展示载具；比赛中的玩家和AI人物由MixedVisuals独立创建。
-- Contract: New(props), Select(id, available), Prewarm(ids), Update(dt), Dispose(); widget may reopen.
local UI = require("urhox-libs/UI")
local VehicleAssets = require("VehicleAssets")
local MixedVisuals = require("MixedVisuals")
local PreviewCache = require("PreviewCache")

---@class GaragePreview : Widget
local Preview = UI.Widget:Extend("GaragePreview")
Preview.Resources = {"RenderPaths/Forward.xml", "LightGroup/Daytime.xml"}
Preview.ResourceTypes = {["RenderPaths/Forward.xml"] = "XMLFile", ["LightGroup/Daytime.xml"] = "XMLFile"}

-- Measured on the ORIGINAL 1568x882 backdrop: inner deck ellipse, not its front wall.
-- Keep the same centered cover transform as HUD's background; safe-area UI is unrelated.
local ART_W, ART_H = 1568, 882
local DECK_X, DECK_Y, DECK_RX, DECK_RY = 1102, 452, 365, 42
local ELEVATION = math.asin(DECK_RY / DECK_RX)

function Preview:Init(props)
    props = props or {}
    props.pointerEvents = "none"
    props.padding = 0
    UI.Widget.Init(self, props)
    self.active, self.generation, self.angle, self.frameTimer = false, 0, 28.0, 0.0
    self.vehicleId, self.state = "", "idle"
    ---@type table?
    self.previewCache = nil
    ---@type GaragePreviewEntry?
    self.displayEntry = nil
    self.presentGeneration, self.renderGeneration, self.presentFrame = -1, -1, -1
    ---@type Scene?
    self.previewScene = nil
    ---@type Node?
    self.turntable = nil
    ---@type Rider?
    self.riderRig = nil
    ---@type Node?
    self.cameraNode = nil
    ---@type Camera?
    self.previewCamera = nil
    ---@type Viewport?
    self.previewViewport = nil
    ---@type Texture2D?
    self.previewTexture = nil
    ---@type RenderSurface?
    self.previewSurface = nil
    ---@type NVGContextWrapper?
    self.imageContext = nil
    self.image, self.imageFailed = 0, false
    self.renderWidth, self.renderHeight, self.layoutAspect = 0, 0, 0.0
    self.stageRadius, self.vehicleHeight = 1.65, 1.25
    self.footprintWidth, self.footprintLength = 1.0, 2.2
    self.viewWidth, self.viewHeight = 0.0, 0.0
    self.deckX, self.deckY, self.deckRX, self.deckRY, self.pixelsPerMeter = 0.0, 0.0, 0.0, 0.0, 1.0
    self.riderColor_ = {168, 46, 37, 255}
    ---@type Resource[]
    self.loadedResources = {}
    self.status = UI.Label {text = "实车展示准备中", fontSize = 12, fontColor = {190, 193, 197, 255},
        position = "absolute", left = 12, right = 12, bottom = 10, height = 24,
        textAlign = "center", pointerEvents = "none", maxLines = 2, whiteSpace = "normal"}
    self:AddChild(self.status)
end

function Preview.New(props)
    return Preview(props)
end

function Preview:ChangeStatus(state, text)
    self.state = state
    self.status:SetText(text)
    self.status:SetVisible(state ~= "ready")
end

function Preview:ReleaseImage()
    if self.image ~= 0 and self.imageContext then nvgDeleteVideo(self.imageContext, self.image) end
    self.image, self.imageContext, self.imageFailed = 0, nil, false
end

function Preview:Dispose()
    -- Invalidate all pending asynchronous callbacks before releasing native objects.
    self.active = false
    self.generation = self.generation + 1
    if self.previewCache then self.previewCache:Dispose() end
    self.previewCache, self.displayEntry = nil, nil
    self.presentGeneration, self.renderGeneration, self.presentFrame = -1, -1, -1
    self:ReleaseImage()
    if self.previewSurface then self.previewSurface:SetNumViewports(0) end
    if self.previewTexture then self.previewTexture:Dispose() end
    self.previewSurface, self.previewViewport, self.previewTexture = nil, nil, nil
    if self.riderRig then MixedVisuals.DisposeRider(self.riderRig) end
    self.previewCamera, self.cameraNode, self.turntable, self.riderRig = nil, nil, nil, nil
    if self.previewScene then self.previewScene:Dispose() end
    self.previewScene, self.loadedResources = nil, {}
    self.renderWidth, self.renderHeight, self.layoutAspect = 0, 0, 0.0
    self.state = "idle"
end

function Preview:Destroy()
    self:Dispose()
    UI.Widget.Destroy(self)
end

function Preview:EnsureCache()
    if self.previewCache then return end
    self.previewCache = PreviewCache.New {
        limit = 12, commonPaths = Preview.Resources, commonTypes = Preview.ResourceTypes,
        build = function(entry) self:BuildVehicle(entry) end,
        ready = function(entry, token)
            if self.active and self.vehicleId == entry.id and token == self.generation then self:Activate(entry) end
        end,
        failed = function(entry, token)
            if not self.active or self.vehicleId ~= entry.id or token ~= self.generation then return end
            self:ChangeStatus("failed", "实车准备中 · 资源未就绪，重新选择可重试")
            print("[车库预览] " .. entry.id .. " " .. tostring(entry.error))
        end,
    }
end

---@param entry GaragePreviewEntry
---@param visible boolean
function Preview:SetEntryVisible(entry, visible)
    -- Parent Node.enabled did not suppress descendant meshes in the real CLI RT.
    -- Gate the actual drawables, never recursively enable the whole articulation:
    -- source-disabled pieces stay disabled, and joint node rest states stay untouched.
    for _, snapshot in ipairs(entry.visibility or {}) do
        snapshot.drawable.enabled = visible and snapshot.enabled or false
        snapshot.drawable.viewMask = visible and snapshot.viewMask or 0
    end
    if entry.content then entry.content.enabled = visible end
end

---@param id string
---@param available? boolean
function Preview:Select(id, available)
    if self.active and self.vehicleId == id and (self.state == "ready" or self.state == "preparing") then return end
    -- Switching does not destroy the showroom or any resident vehicle. Hide the OLD
    -- node/image immediately; only a generation-matched selection may become visible.
    self.generation = self.generation + 1
    if self.displayEntry then self:SetEntryVisible(self.displayEntry, false) end
    self.displayEntry = nil
    self.vehicleId, self.active = id, true
    self.presentGeneration, self.renderGeneration = -1, -1
    if available == false or not VehicleAssets.Vehicles[id] then
        if self.previewCache then self.previewCache.selected = "" end
        self:ChangeStatus("unavailable", "车型资源准备中 · 暂不可驾驶")
        return
    end
    self:EnsureCache()
    self:ChangeStatus("preparing", "正在准备真实车型…")
    local entry = self.previewCache:Request(id, self.generation)
    if entry and entry.state == "ready" then self:Activate(entry) end
end

-- HUD supplies ordered current-page + next-page IDs. No rider assets, synchronous
-- downloads, model construction or resource loads happen in this call.
---@param ids string[]
function Preview:Prewarm(ids)
    if not self.active then return end
    self:EnsureCache()
    self.previewCache:Prewarm(ids)
end

-- Compatibility only: the vehicle-only showroom never creates or loads a rider.
function Preview:SetRiderColor(color)
    self.riderColor_ = color or self.riderColor_
end

---@param entry GaragePreviewEntry
function Preview:BuildVehicle(entry)
    self:BuildScene()
    local content = assert(self.previewScene):CreateChild("Preview_" .. entry.id)
    entry.content = content
    -- Build at identity in the original world frame, NOT underneath the rotating
    -- turntable. MixedVisuals source seat/bounds transforms assume that frame.
    local vehicle = VehicleAssets.Add(content, entry.id)
    entry.vehicle = vehicle
    local drawables = vehicle:GetComponents("StaticModel", true)
    assert(#drawables > 0, "载具预览需要真实3D模型")
    local bounds = BoundingBox()
    for _, drawable in ipairs(drawables) do bounds:Merge(drawable.worldBoundingBox) end
    -- SourceTransform already normalizes the actual retained triangles to y=0.
    -- Rotated part AABBs are conservative and MUST NOT lift a mixed vehicle.
    local groundY = require("MixedVehicles").Get(entry.id) and 0 or bounds.min.y
    local size = Vector3(bounds.size.x, bounds.max.y - groundY, bounds.size.z)
    content.position = Vector3(-bounds.center.x, -groundY, -bounds.center.z)
    entry.size = size
    entry.radius = math.sqrt(size.x * size.x + size.z * size.z) * 0.5
    entry.visibility = {}
    for _, drawable in ipairs(drawables) do
        drawable.lodBias = 3
        drawable:SetMaxLights(3)
        entry.visibility[#entry.visibility + 1] = {drawable=drawable, enabled=drawable.enabled, viewMask=drawable.viewMask}
    end
    self:SetEntryVisible(entry, false)
    content:SetParent(assert(self.turntable))
end

---@param entry GaragePreviewEntry
function Preview:Activate(entry)
    if not self.active or self.vehicleId ~= entry.id or not entry.alive then return end
    if self.displayEntry then self:SetEntryVisible(self.displayEntry, false) end
    local size = assert(entry.size)
    if self.imageFailed then self:ReleaseImage() end
    self.displayEntry = entry
    self:SetEntryVisible(entry, true)
    self.vehicleHeight, self.footprintWidth, self.footprintLength = size.y, size.x, size.z
    self.stageRadius = assert(entry.radius)
    self.angle, self.frameTimer = 20.0, 0.0
    assert(self.turntable).rotation = Quaternion(0, self.angle, 0)
    -- ready means the new source node is active; drawing is gated until its RT
    -- has passed a render frame, so a shared RT never flashes the previous car.
    self.presentGeneration, self.renderGeneration = self.generation, -1
    self.presentFrame = GetTime():GetFrameNumber()
    self:ResizeTarget()
    if self.previewSurface then self.previewSurface:QueueUpdate() end
    self:ChangeStatus("ready", "")
end

function Preview:BuildScene()
    if self.previewScene then return end
    -- Based on scaffold-3d-scene: independent Octree + LightGroup + camera.
    -- Vehicle-only transparent layer; the authored backdrop owns the entire showroom.
    self.previewScene = Scene()
    self.previewScene:CreateComponent("Octree")
    local lightGroup = self.previewScene:CreateChild("ShowroomLighting")
    lightGroup:LoadXML(assert(cache:GetResource("XMLFile", "LightGroup/Daytime.xml")):GetRoot())
    local zone = lightGroup:GetComponent("Zone", true)
    if zone then
        zone.depthFogEnable, zone.heightFogEnable = false, false
        -- Keep the preset's prefiltered IBL (no fabricated environment texture).
        -- Less flat diffuse fill and a stronger reflection separate paint/chrome/rubber.
        zone.envTextureDiffIntensity, zone.envTextureSpecIntensity = 0.64, 0.72
    end
    local light = lightGroup:GetComponent("Light", true)
    if light then
        -- Warm overhead strip from the reference garage, not an outdoor blue sun.
        -- 保留白色车壳的层次，避免顶灯把贴图高光压成纯白。
        light.brightness, light.castShadows = 2.8, false
        light.color = Color(1.0, 0.89, 0.73)
        light.node.direction = Vector3(0.35, -0.9, 0.25)
    end
    local fillNode = self.previewScene:CreateChild("NeutralSoftbox")
    fillNode.direction = Vector3(-0.7, -0.35, 0.6)
    local fill = fillNode:CreateComponent("Light")
    fill.lightType, fill.brightness, fill.color, fill.castShadows = LIGHT_POINT, 24, Color(0.89, 0.94, 1.0), false
    fill.range=16
    fillNode.position=Vector3(-3,4,3)
    local rimNode = self.previewScene:CreateChild("CoolRim")
    rimNode.direction = Vector3(-0.4, -0.55, -0.7)
    local rim = rimNode:CreateComponent("Light")
    rim.lightType, rim.brightness, rim.color, rim.castShadows = LIGHT_POINT, 20, Color(0.76, 0.86, 1), false
    rim.range=14
    rimNode.position=Vector3(2,3,-4)
    self.turntable = self.previewScene:CreateChild("VehicleTurntable")
    self.cameraNode = self.previewScene:CreateChild("ShowroomCamera")
    self.previewCamera = self.cameraNode:CreateComponent("Camera")
    -- The reference is a long-lens image: weak perspective and a 42/365 deck ellipse.
    -- Orthographic projection preserves that elevation throughout a full rotation.
    self.previewCamera.orthographic = true
    self.previewCamera.nearClip, self.previewCamera.farClip = 0.05, 80
    self.cameraNode.position = Vector3(0.8 * math.cos(ELEVATION), math.sin(ELEVATION), -0.6 * math.cos(ELEVATION)) * 20
    self.cameraNode:LookAt(Vector3.ZERO)
    self.previewViewport = Viewport:new(self.previewScene, self.previewCamera)
    local renderPath = self.previewViewport:GetRenderPath():Clone()
    assert(renderPath:Load(assert(cache:GetResource("XMLFile", "RenderPaths/Forward.xml"))))
    self.previewViewport:SetRenderPath(renderPath)
    for i = 0, renderPath:GetNumCommands() - 1 do
        local command = renderPath:GetCommand(i)
        if command.type == CMD_CLEAR then
            command.useFogColor, command.clearColor = false, Color(0, 0, 0, 0)
        end
    end

end

function Preview:ResizeTarget()
    if not self.previewCamera or not self.cameraNode or not self.previewViewport then return end
    local l = self:GetAbsoluteLayout()
    if l.w < 2 or l.h < 2 then return end
    -- Same centered cover mapping as Widget:RenderFitImage, in UI base pixels.
    local cover = math.max(l.w / ART_W, l.h / ART_H)
    self.deckX = l.x + (l.w - ART_W * cover) * 0.5 + DECK_X * cover
    self.deckY = l.y + (l.h - ART_H * cover) * 0.5 + DECK_Y * cover
    self.deckRX, self.deckRY = DECK_RX * cover, DECK_RY * cover
    local projectedHeight = self.vehicleHeight * math.cos(ELEVATION) + self.stageRadius * math.sin(ELEVATION)
    self.pixelsPerMeter = math.min(self.deckRX * 0.70 / self.stageRadius,
        (self.deckY - l.y - l.h * 0.25) / projectedHeight)
    -- A local, symmetric ground-centered ROI contains the ENTIRE rotation. Keep
    -- screen pixels/metre unchanged: improving the RT must not resize/reposition the bike.
    -- 12% + 4px guard covers bilinear edges and slightly conservative source bounds.
    self.viewWidth = (self.stageRadius * self.pixelsPerMeter * 1.12 + 4) * 2
    self.viewHeight = (projectedHeight * self.pixelsPerMeter * 1.12 + 4) * 2
    local aspect = self.viewWidth / self.viewHeight
    -- RT allocation depends on the layout's maximum transparent ROI, not car
    -- dimensions. The projection limits above bound EVERY car inside this envelope.
    -- Explicit camera aspect + ROI mapping preserve metres/pixel even when the
    -- resident RT's pixel aspect differs from a particular vehicle's compact ROI.
    local maxWidth = (self.deckRX * 0.70 * 1.12 + 4) * 2
    local maxHeight = (math.max(1, self.deckY - l.y - l.h * 0.25) * 1.12 + 4) * 2
    local density = math.min(UI.GetScale() * 2, 1536 / math.max(maxWidth, maxHeight))
    local targetW = math.max(128, math.ceil(maxWidth * density / 8) * 8)
    local targetH = math.max(128, math.ceil(maxHeight * density / 8) * 8)
    local projectionChanged = self.layoutAspect ~= aspect
        or math.abs(self.previewCamera.orthoSize - self.viewHeight / self.pixelsPerMeter) > 0.000001
    local targetChanged = self.renderWidth ~= targetW or self.renderHeight ~= targetH
    -- Only GPU allocation is quantized/cached. Photo anchors must follow every
    -- layout change, even a sub-8-pixel resize that keeps the same texture size.
    if self.renderWidth ~= targetW or self.renderHeight ~= targetH then
        self:ReleaseImage()
        if self.previewSurface then self.previewSurface:SetNumViewports(0) end
        if self.previewTexture then self.previewTexture:Dispose() end
        self.previewTexture = Texture2D:new()
        self.previewTexture:SetNumLevels(1)
        assert(self.previewTexture:SetSize(targetW, targetH, Graphics:GetRGBAFormat(), TEXTURE_RENDERTARGET))
        self.previewTexture:SetFilterMode(FILTER_BILINEAR)
        self.previewSurface = self.previewTexture:GetRenderSurface()
        self.previewSurface:SetViewport(0, self.previewViewport)
        self.previewSurface:SetUpdateMode(SURFACE_MANUALUPDATE)
        self.renderWidth, self.renderHeight = targetW, targetH
    end
    self.layoutAspect = aspect
    -- SetOrthoSize(float) resets aspectRatio to 1 in the engine: assign the
    -- measured viewport aspect AFTER orthoSize, or the bike stretches horizontally.
    self.previewCamera.orthoSize = self.viewHeight / self.pixelsPerMeter
    self.previewCamera.autoAspectRatio = false
    self.previewCamera.aspectRatio = aspect
    -- 普通帧由Update的24Hz节拍排队；布局/目标变动才立即重绘。
    if targetChanged or projectionChanged then self.previewSurface:QueueUpdate() end
end

function Preview:Update(dt)
    if not self.active then return end
    if self.previewCache then self.previewCache:Update() end
    if self.state ~= "ready" then return end
    self:ResizeTarget()
    if self.presentGeneration == self.generation and GetTime():GetFrameNumber() > self.presentFrame + 1 then
        self.renderGeneration = self.generation
    end
    if not self.turntable or not self.previewSurface then return end
    self.frameTimer = self.frameTimer + dt
    if self.frameTimer < 1 / 24 then return end
    self.angle = (self.angle + self.frameTimer * 9) % 360
    self.frameTimer = 0
    self.turntable.rotation = Quaternion(0, self.angle, 0)
    if require("MixedVehicles").Get(self.vehicleId or "") and self.displayEntry and self.displayEntry.vehicle then
        MixedVisuals.Animate(self.displayEntry.vehicle, self.vehicleId, self.angle / 9, {oddActive=0})
    end
    self.previewSurface:QueueUpdate()
end

-- A restrained ambient-contact approximation, not a replacement deck or fake
-- wheel locations. Project a conservative central footprint onto the original
-- photographed deck. Rotation/elevation use the SAME camera as the vehicle.
function Preview:DrawContactShadow(nvg)
    if not self.previewCamera or not self.turntable then return end
    local camera, rotation = self.previewCamera, self.turntable.rotation
    local origin = camera:WorldToScreenPoint(Vector3.ZERO)
    local across = camera:WorldToScreenPoint(rotation * Vector3(self.footprintWidth * 0.32, 0, 0))
    local along = camera:WorldToScreenPoint(rotation * Vector3(0, 0, self.footprintLength * 0.46))
    nvgSave(nvg)
    nvgTransform(nvg, (across.x - origin.x) * self.viewWidth, (across.y - origin.y) * self.viewHeight,
        (along.x - origin.x) * self.viewWidth, (along.y - origin.y) * self.viewHeight, self.deckX, self.deckY)
    nvgBeginPath(nvg)
    nvgCircle(nvg, 0, 0, 1)
    nvgFillPaint(nvg, nvgRadialGradient(nvg, 0, 0, 0.08, 1,
        nvgRGBA(5, 4, 3, 24), nvgRGBA(5, 4, 3, 0)))
    nvgFill(nvg)
    nvgRestore(nvg)
end

function Preview:Render(nvg)
    if not self.active or self.state ~= "ready" or self.renderGeneration ~= self.generation
        or not self.previewTexture or self.imageFailed then return end
    local l = self:GetAbsoluteLayout()
    if l.w <= 0 or l.h <= 0 then return end
    if self.imageContext and self.imageContext ~= nvg then self:ReleaseImage() end
    if self.image == 0 then
        self.image = nvgCreateVideo(nvg, self.previewTexture)
        self.imageContext = nvg
        if self.image == 0 then
            self.imageFailed = true
            self:ChangeStatus("failed", "实车准备中 · 设备暂不支持预览")
            return
        end
    end
    local width, height = self.viewWidth, self.viewHeight
    -- Translate only the compact transparent ROI: its center is the ground origin,
    -- whose screen location remains the photographed deck center at every aspect.
    local x, y = self.deckX - width * 0.5, self.deckY - height * 0.5
    -- UI owns the NanoVG frame and DPR transform. No nvgCreate/BeginFrame here.
    nvgSave(nvg)
    nvgIntersectScissor(nvg, l.x, l.y, l.w, l.h)
    self:DrawContactShadow(nvg)
    nvgBeginPath(nvg)
    nvgRect(nvg, x, y, width, height)
    nvgFillPaint(nvg, nvgImagePattern(nvg, x, y, width, height, 0, self.image, 1))
    nvgFill(nvg)
    nvgRestore(nvg)
end

return Preview
