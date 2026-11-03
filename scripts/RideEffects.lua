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
---@field padRoot Node
---@field padTrails Node[]
---@field lineMaterial Material
---@field padMaterial Material
---@field streakMode integer
---@field padIntensity number
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
    self.padIntensity, self.streakMode = 0, 0
    self.jets, self.streaks, self.padTrails, self.materials = {}, {}, {}, {}
    self.padRoot = self.root:CreateChild("BoostPadSurge", LOCAL)
    local blue = P.Material(0.012, 0.16, 0.78, 0.8, 0, 1.3)
    -- 半透明外焰让短白蓝焰芯可见，避免不透明锥体看起来像两根实体长矛。
    blue:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
    blue:SetShaderParameter("MatDiffColor", Variant(Color(0.012, 0.16, 0.78, 0.44)))
    local cyan = P.Material(0.16, 0.73, 1, 0.8, 0, 2.0)
    local line = P.Material(0.035, 0.33, 0.54, 0.9, 0, 0.65)
    -- 独立青绿能量材质：不改蓝焰材质，不给加速带创建/开启喷气锥体。
    local pad = P.Material(0.015, 0.95, 0.63, 0.9, 0, 2.4)
    self.lineMaterial, self.padMaterial = line, pad
    self.materials = {blue, cyan, line, pad}
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
    -- 固定4条薄能量带，共用一个单位Box；车侧高低错层，第三人称与头盔视角均能看到掠流。
    local bar = BoxGeometry(1, 1, 1):ToModel()
    for _, side in ipairs({-1, 1}) do
        for band = 1, 2 do
            local node = P.Add(self.padRoot, "PadEnergyTrail", bar, pad,
                V(side * math.max(0.62, size.x * 0.60), seatHeight * 0.55 + (band - 1) * 0.28, 0), V.ONE, nil, false)
            local model = node:GetComponent("StaticModel")
            model.drawDistance, model.shadowDistance = lightweight and 100 or 180, 0
            self.padTrails[#self.padTrails + 1] = node
        end
    end
    if not lightweight then
        for index = 1, 14 do
            local node = P.Add(self.root, "NitroAirStreak", bar, line, V.ZERO, V.ONE, nil, false)
            node:GetComponent("StaticModel").drawDistance = 100
            self.streaks[index] = node
        end
    else
        -- 对手只留两条喷焰；4条能量带在现场几乎看不清，却要多8次draw。
        for _, node in ipairs({self.padTrails[3], self.padTrails[4]}) do
            if node then node:Dispose() end
        end
        self.padTrails = {self.padTrails[1], self.padTrails[2]}
    end
    self.root:SetEnabledRecursive(false)
end

---@param dt number 0严格冻结；主入口暂停时传0
---@param boost number 玩家或AI的driveSim.raceBoost(0..1)，只反映实际喷射动力
---@param speed number 实际速度，只决定速度线和尾焰长短，不回写仿真
---@param padPower? number 独立加速带反馈包络(0..1)，约1.35秒，由固定步featureState提供；省略兼容AI
function Effects:Update(dt, boost, speed, padPower)
    if self.disposed or dt <= 0 then return end
    local step = math.max(0, dt)
    local target = math.max(0, math.min(1, boost))
    self.clock = self.clock + step
    self.intensity = self.intensity + (target - self.intensity) * (1 - math.exp(-step * (target > self.intensity and 28 or 20)))
    if self.intensity < 0.008 then self.intensity = 0 end
    local amount = self.intensity
    -- padPower已经是仿真固定步衰减后的包络，不在渲染帧另起计时器或延长成功反馈。
    local pad = math.max(0, math.min(1, padPower or 0))
    self.padIntensity = pad
    self.root:SetEnabledRecursive(amount > 0 or pad > 0)
    self.padRoot:SetEnabledRecursive(pad > 0)
    for _, jet in ipairs(self.jets) do jet.anchor:SetEnabledRecursive(amount > 0) end
    -- 只有视觉车架轻微蓄力/震动，整车与骑手共享父变换，保持IK接触点不变。
    self.pitch = -0.8 * amount - 0.45 * pad
    self.bob = math.sin(self.clock * 43) * 0.006 * amount + math.sin(self.clock * 35) * 0.003 * pad
    if amount == 0 and pad == 0 then return end
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
    for index, node in ipairs(self.padTrails) do
        -- 非火焰的短冲刺能量带：亮青绿、明显车侧长条，固定池不创建粒子或额外灯光。
        local pulse = 0.88 + 0.12 * math.sin(self.clock * 32 + index * 1.7)
        local length = (1.3 + velocity * 1.8) * pad * pulse
        local position = node.position
        node.position = V(position.x, position.y, 0.20 - length * 0.5 - (index % 2) * 0.35)
        node.scale = V(0.045 * pad, 0.065 * pad, length)
    end
    local streakMode = pad > 0 and 1 or 0
    if streakMode ~= self.streakMode then
        local material = streakMode == 1 and self.padMaterial or self.lineMaterial
        for _, node in ipairs(self.streaks) do node:GetComponent("StaticModel").material = material end
        self.streakMode = streakMode
    end
    local streakAmount = math.max(amount, pad)
    local moving = math.abs(speed) > 8
    for index, node in ipairs(self.streaks) do
        node.enabled = moving
        if moving then
            local phase = (self.clock * (1.6 + velocity * 2.0) + index * 0.173) % 1
            local side = index % 2 == 0 and 1 or -1
            local taper = math.sin(phase * math.pi) * streakAmount
            node.position = V(side * (1.10 + index % 3 * 0.14), 0.34 + index % 4 * 0.27, 1.2 - phase * 5.4)
            local thickness = streakMode == 1 and 0.032 or 0.014
            node.scale = V(thickness * taper, thickness * taper, (0.30 + velocity * 0.85) * taper)
        end
    end
end

function Effects:Reset()
    if self.disposed then return end
    self.clock, self.intensity, self.pitch, self.bob = 0, 0, 0, 0
    self.padIntensity, self.streakMode = 0, 0
    for _, node in ipairs(self.streaks) do node:GetComponent("StaticModel").material = self.lineMaterial end
    self.root:SetEnabledRecursive(false)
end

function Effects:Dispose()
    if self.disposed then return end
    self:Reset()
    self.disposed = true
    self.root:Dispose()
    for _, material in ipairs(self.materials) do material:Dispose() end
    self.jets, self.streaks, self.padTrails, self.materials = {}, {}, {}, {}
end

-- 显式验收入口；仅临时Scene和程序化几何，不订阅事件、不触碰当前比赛/车辆。
---@return table
function Effects.CheckPadFeedback()
    local scene = Scene()
    local effects = Effects.New(scene:CreateChild("PadFeedbackCheck"), V(1.1, 1.5, 2.3), 1.0)
    local ok, message = pcall(function()
        effects:Update(1 / 60, 0, 35, 1)
        assert(effects.padIntensity == 1 and effects.padRoot.enabled, "pad-only能量带未开启")
        for _, jet in ipairs(effects.jets) do assert(not jet.anchor.enabled, "pad-only不得伪造氮气蓝焰") end
        assert(effects.streakMode == 1 and effects.padTrails[1].scale.z > 1, "青绿冲刺必须明显可见")
        local clock, pitch, position = effects.clock, effects.pitch, effects.padTrails[1].position
        effects:Update(0, 1, 55, 0)
        assert(effects.clock == clock and effects.pitch == pitch and effects.padIntensity == 1
            and effects.padTrails[1].position.z == position.z, "dt0必须冻结")
        effects:Update(1 / 60, 0, 35, 0)
        assert(not effects.root.enabled and effects.padIntensity == 0, "包络结束必须关闭pad-only")
        effects:Update(1 / 60, 1, 35)
        assert(effects.intensity > 0 and effects.jets[1].anchor.enabled
            and not effects.padRoot.enabled and effects.streakMode == 0, "旧三参氮气回归")
        effects:Update(1 / 60, 1, 35, 1)
        assert(effects.jets[1].anchor.enabled and effects.padRoot.enabled, "氮气和pad必须独立共存")
        effects:Reset()
        assert(not effects.root.enabled and effects.padIntensity == 0 and effects.intensity == 0
            and effects.pitch == 0 and effects.bob == 0 and effects.streakMode == 0, "Reset必须清理反馈")
        effects:Dispose()
        effects:Dispose()
        effects:Update(1 / 60, 1, 35, 1)
        assert(effects.disposed and #effects.padTrails == 0 and #effects.materials == 0, "Dispose必须幂等清理")
    end)
    effects:Dispose()
    scene:Dispose()
    assert(ok, tostring(message))
    print("[加速带表现验收] pad-only/旧三参氮气/共存/暂停/Reset/Dispose通过")
    return {passed = true}
end

return Effects
