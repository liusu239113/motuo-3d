-- 只读竞速动力授权的轻量表现。无物理、无输入、无加速度写入；全部尺寸为米。
-- 共用程序化几何，纯色PBR自发光；无需新增图片、模型或粒子资源。
local P = require("Parts")
local V = Vector3

---@class RideEffectJet
---@field anchor Node
---@field outer Node
---@field core Node

---@class RideEffects
---@field root Node
---@field jets RideEffectJet[]
---@field streaks Node[]
---@field materials Material[]
---@field clock number
---@field intensity number
---@field pitch number
---@field bob number
---@field disposed boolean
local Effects = {}
Effects.__index = Effects
Effects.Resources = {"Techniques/PBR/PBRNoTexture.xml", "Techniques/PBR/PBRNoTextureAlpha.xml"}

---@param parent Node 车身和骑手共用的visual父节点，不挂在骨骼或握把上
---@param size Vector3 VehicleAssets已量测、归一化后的整车范围
---@param seatHeight number
---@param lightweight? boolean AI不分配玩家周边速度线
---@return RideEffects
function Effects.New(parent, size, seatHeight, lightweight)
    local self = setmetatable({}, Effects)
    self:Init(parent, size, seatHeight, lightweight == true)
    return self
end

---@param parent Node
---@param size Vector3
---@param seatHeight number
---@param lightweight boolean
function Effects:Init(parent, size, seatHeight, lightweight)
    self.root = parent:CreateChild("NitroRideEffects", LOCAL)
    self.clock, self.intensity, self.pitch, self.bob = 0, 0, 0, 0
    self.disposed = false
    self.jets, self.streaks, self.materials = {}, {}, {}
    local blue = P.Material(0.012, 0.16, 0.78, 0.8, 0, 1.3)
    -- 半透明外焰让短白蓝焰芯可见，避免不透明锥体看起来像两根实体长矛。
    blue:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
    blue:SetShaderParameter("MatDiffColor", Variant(Color(0.012, 0.16, 0.78, 0.44)))
    local cyan = P.Material(0.16, 0.73, 1, 0.8, 0, 2.0)
    local line = P.Material(0.035, 0.33, 0.54, 0.9, 0, 0.65)
    self.materials = {blue, cyan, line}
    -- 尾部左右的街机氮气喷流，不为单体MDL伪造可拆卸排气管。
    -- 根点依真实整车范围设置，避开中间后轮；不是新碰撞体。
    local cone = ConeGeometry(0.5, 1, 10):ToModel()
    local backward = Quaternion(V.UP, V(0, 0, -1))
    for _, side in ipairs({-1, 1}) do
        local anchor = self.root:CreateChild("NitroTailJet", LOCAL)
        anchor.position = V(side * math.max(0.26, size.x * 0.29), seatHeight * 0.53, -size.z * 0.44)
        local outer = P.Add(anchor, "BlueFlame", cone, blue, V.ZERO, V.ONE, backward, false)
        local core = P.Add(anchor, "CyanFlameCore", cone, cyan, V.ZERO, V.ONE, backward, false)
        for _, node in ipairs({outer, core}) do
            local model = node:GetComponent("StaticModel")
            model.drawDistance, model.shadowDistance = lightweight and 100 or 180, 0
        end
        self.jets[#self.jets + 1] = {anchor = anchor, outer = outer, core = core}
    end
    if not lightweight then
        local bar = BoxGeometry(1, 1, 1):ToModel()
        for index = 1, 14 do
            local node = P.Add(self.root, "NitroAirStreak", bar, line, V.ZERO, V.ONE, nil, false)
            node:GetComponent("StaticModel").drawDistance = 100
            self.streaks[index] = node
        end
    end
    self.root:SetEnabledRecursive(false)
end

---@param dt number 0严格冻结；主入口暂停时传0
---@param boost number 玩家或AI的driveSim.raceBoost(0..1)，只反映实际喷射动力
---@param speed number 实际速度，只决定速度线和尾焰长短，不回写仿真
function Effects:Update(dt, boost, speed)
    if self.disposed or dt <= 0 then return end
    local step = math.max(0, dt)
    local target = math.max(0, math.min(1, boost))
    self.clock = self.clock + step
    self.intensity = self.intensity + (target - self.intensity) * (1 - math.exp(-step * (target > self.intensity and 28 or 20)))
    if self.intensity < 0.008 then self.intensity = 0 end
    local amount = self.intensity
    self.root:SetEnabledRecursive(amount > 0)
    -- 只有视觉车架轻微蓄力/震动，整车与骑手共享父变换，保持IK接触点不变。
    self.pitch = -0.8 * amount
    self.bob = math.sin(self.clock * 43) * 0.006 * amount
    if amount == 0 then return end
    local velocity = math.min(1, math.abs(speed) / 55)
    for index, jet in ipairs(self.jets) do
        -- 氮气必须一眼看出来：尾焰更长更粗、脉动更明显，仍只读动力授权。
        local flicker = 0.86 + 0.17 * math.sin(self.clock * 59 + index * 2.4)
        local length = (1.05 + velocity * 0.75) * amount * flicker
        local width = (0.20 + velocity * 0.05) * amount
        -- Cone的尖端沿局部+Y；旋至-Z后，底部位于喷口、尖端指向车后。
        jet.outer.position, jet.outer.scale = V(0, 0, -length * 0.5), V(width, length, width)
        jet.core.position, jet.core.scale = V(0, 0, -length * 0.28), V(width * 0.52, length * 0.56, width * 0.52)
    end
    local moving = math.abs(speed) > 8
    for index, node in ipairs(self.streaks) do
        node.enabled = moving
        if moving then
            local phase = (self.clock * (1.6 + velocity * 2.0) + index * 0.173) % 1
            local side = index % 2 == 0 and 1 or -1
            local taper = math.sin(phase * math.pi) * amount
            node.position = V(side * (1.10 + index % 3 * 0.14), 0.34 + index % 4 * 0.27, 1.2 - phase * 5.4)
            node.scale = V(0.014 * taper, 0.014 * taper, (0.30 + velocity * 0.85) * taper)
        end
    end
end

function Effects:Reset()
    if self.disposed then return end
    self.clock, self.intensity, self.pitch, self.bob = 0, 0, 0, 0
    self.root:SetEnabledRecursive(false)
end

function Effects:Dispose()
    if self.disposed then return end
    self.disposed = true
    self.root:Dispose()
    for _, material in ipairs(self.materials) do material:Dispose() end
    self.jets, self.streaks, self.materials = {}, {}, {}
end

return Effects
