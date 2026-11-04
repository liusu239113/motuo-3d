-- 驾驶相机：继承既有ThirdPersonCamera脚手架，环视只叠加角度，不写车辆/特技状态。
local ThirdPersonCamera = require("urhox-libs.Camera.ThirdPersonCamera")
local UI = require("urhox-libs/UI")
local remainingIds={jellyfish=true,jetboat=true,frog=true,skateboard=true,sled=true,cart=true,
    bathtub=true,office=true,toilet=true}
local MixedDriver = require("MixedDriver")
---@class DrivingCamera
local DrivingCamera = {}
DrivingCamera.__index = DrivingCamera
-- 单位：度/逻辑像素。水平允许完整360°，俯仰避免越过极点或追尾钻入地面。
DrivingCamera.MouseSensitivity = 0.22
DrivingCamera.TouchSensitivity = 0.34
DrivingCamera.MinPitch, DrivingCamera.MaxPitch = -55, 55

function DrivingCamera.New()
    local self = setmetatable({}, DrivingCamera)
    self:Init()
    return self
end
function DrivingCamera:Init()
    self.yaw, self.pitch, self.chaseYaw, self.boostFov = 0.0, 0.0, 0.0, 0.0
    self.mouseHeld, self.mouseDragging = false, false
end

function DrivingCamera:Reset(heading)
    self.yaw, self.pitch, self.boostFov = 0.0, 0.0, 0.0
    self.chaseYaw = heading or 0
    self:CancelInput()
end
function DrivingCamera:CancelInput()
    -- 取消时记录真实按键状态：暂停/视角切换后仍按着右键，必须先松手再重新拖。
    self.mouseHeld = input:GetMouseButtonDown(MOUSEB_RIGHT)
    self.mouseDragging = false
end
function DrivingCamera:AddLook(dx, dy, sensitivity)
    self.yaw = (self.yaw + dx * sensitivity + 180) % 360 - 180
    self.pitch = math.max(DrivingCamera.MinPitch, math.min(DrivingCamera.MaxPitch, self.pitch + dy * sensitivity))
end

---@param active boolean
function DrivingCamera:ApplyLookInput(controls, active)
    local down = input:GetMouseButtonDown(MOUSEB_RIGHT)
    if not active then
        self:CancelInput()
        controls:ResetLook()
        return
    end
    -- 不以鼠标位置决定持续归属；只在开始拖动时排除UI和其他控制触点。
    if down and not self.mouseHeld then
        self.mouseDragging = not UI.IsPointerOverUI() and not input:GetMouseButtonDown(MOUSEB_LEFT)
            and input.numTouches == 0
    elseif down and self.mouseDragging then
        local scale = math.max(0.01, UI.GetScale())
        self:AddLook(input.mouseMoveX / scale, input.mouseMoveY / scale, DrivingCamera.MouseSensitivity)
    end
    if not down then self.mouseDragging = false end
    self.mouseHeld = down
    local dx, dy = controls:ConsumeLook()
    if dx ~= 0 or dy ~= 0 then self:AddLook(dx, dy, DrivingCamera.TouchSensitivity) end
end

---@param scene Scene
---@return ThirdPersonCameraInstance
function DrivingCamera.CreateChase(scene)
    return ThirdPersonCamera.Create(scene, {
        modes = {
            normal = {distance = 5.4, offset = Vector3(0, 1.45, 0), fov = 66},
            fast = {distance = 6.1, offset = Vector3(0, 1.45, 0), fov = 74},
            showroom = {distance = 4.8, offset = Vector3(-0.8, 1.0, 0), fov = 48},
            profile = {distance = 3.5, offset = Vector3(0, 1.0, 0), fov = 42},
        }, initialMode = "normal", transitionSpeed = 5, farClip = 2600, nearClip = 0.07})
end

---@param bike Bike
---@return Node, Camera
function DrivingCamera.AttachHelmet(bike)
    local node = bike.visual:CreateChild("骑手眼位")
    local camera = node:CreateComponent("Camera")
    camera.nearClip, camera.farClip = 0.025, 2600
    return node, camera
end

---@param bike Bike
---@param node Node
---@param camera Camera
---@param speed number
---@param boost number
function DrivingCamera:UpdateHelmet(bike, node, camera, speed, boost)
    -- 眼位始终取当前实例的米制Cockpit；未来车型只需遵守相同字段，不做ID白名单。
    node.position = bike.Cockpit.localOffset
    node.rotation = Quaternion(self.yaw, Vector3.UP) * Quaternion(bike.Cockpit.pitch + self.pitch, Vector3.RIGHT)
    camera.fov = bike.Cockpit.fov + math.min(6, math.abs(speed) * 0.1) + boost
end

---@param dt number
---@param chase ThirdPersonCameraInstance
---@param bike Bike
---@param helmet Node
---@param camera Camera
---@param sim table
---@param screen string
---@param clock number
---@param profile boolean
---@return number, number
function DrivingCamera:Update(dt, chase, bike, helmet, camera, sim, screen, clock, profile)
    -- 新车及敞开载具人物一同取景；已有坦克/飞机/锹甲和摩托的镜头参数不动。
    local id=bike.vehicleId
    local extraDistance,extraHeight=0,0
    local driver=MixedDriver.Profiles[id]
    if remainingIds[id] or driver then
        local size=bike.body:GetVar("VehicleSize"):GetVector3()
        local visualHeight=driver and math.max(size.y,driver.visualHeight) or size.y
        extraDistance=math.max(0,math.sqrt(size.x*size.x+size.z*size.z)*.5-1.45,visualHeight-1.6)
        extraHeight=math.max(0,visualHeight*.55-1.45)+(sim.oddAltitude or 0)
    end
    if self.framedVehicle~=id or math.abs((self.framedHeight or 0)-extraHeight)>.02 then
        chase:SetModeConfig("normal",{distance=5.4+extraDistance,offset=Vector3(0,1.45+extraHeight,0),fov=66})
        chase:SetModeConfig("fast",{distance=6.1+extraDistance,offset=Vector3(0,1.45+extraHeight,0),fov=74})
        chase:SetModeConfig("showroom",{distance=4.8+extraDistance,offset=Vector3(-.8,1+extraHeight,0),fov=48})
        chase:SetModeConfig("profile",{distance=3.5+extraDistance,offset=Vector3(0,1+extraHeight,0),fov=42})
        local current=chase:GetMode()
        chase:SetMode(current=="normal" and "fast" or "normal")
        chase:SetMode(current)
        self.framedVehicle,self.framedHeight=id,extraHeight
    end
    if profile then
        chase:SetMode("profile")
        chase:Update(1, bike.node, sim.heading - 90, 3)
    elseif screen == "menu" or screen == "garage" then
        chase:Update(dt, bike.node, sim.heading - 145 + math.sin(clock * 0.1) * 3, 7)
    else
        local delta = (sim.heading - self.chaseYaw + 180) % 360 - 180
        self.chaseYaw = self.chaseYaw + delta * math.min(1, dt * 5)
        chase:SetMode(sim.speed > 38 and "fast" or "normal")
        -- 只有库负责轨道位置；此处扩展既有yaw接口，保留原有追尾距离/平滑。
        chase:Update(dt, bike.node, self.chaseYaw + self.yaw, math.max(-20, math.min(70, 9 + self.pitch)))
        if screen == "ride" then
            local padPower = sim.featureState and sim.featureState.feedbackPower or 0
            local targetBoost = math.max(math.max(0, math.min(1, sim.raceBoost or 0)) * 9,
                math.max(0, math.min(1, padPower)) * 7)
            self.boostFov = self.boostFov + (targetBoost - self.boostFov) * (1 - math.exp(-dt * 12))
        end
        local chaseCamera = chase:GetCamera()
        chaseCamera.fov = chaseCamera.fov + self.boostFov
        self:UpdateHelmet(bike, helmet, camera, sim.speed, self.boostFov)
    end
    return self.boostFov, self.chaseYaw
end

return DrivingCamera
