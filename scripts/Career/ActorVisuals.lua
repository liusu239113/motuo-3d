-- Career-only presentation adapter, based on scaffold-3d-character's
-- world-target/model separation. Does not change Rider, Bike or VehicleAssets.
-- 正式王二狗/电动车仍在 reviewed 预览等待用户确认。
-- 当前仅为“现有赛车资产调试代理”，步行动作为程序化骨骼过渡，非正式动作资源。
local Rider = require("Rider")
local Assets = require("VehicleAssets")
local V = Vector3

---@class CareerActorVisuals
---@field bikeNode Node
---@field bikeVisual Node
---@field walkNode Node
---@field mountedRider Rider
---@field walker Rider
---@field feet table<string, Vector3>
---@field standOffset Vector3
---@field phase number
---@field gaitWeight number
---@field lean number
---@field leanSign number
---@field mounted boolean
---@field disposed boolean
local Visuals = {}
Visuals.__index = Visuals

Visuals.ProxyLabel = "现有赛车资产调试代理"
Visuals.AnimationLabel = "程序化骨骼步行过渡（非正式动作资源）"
Visuals.Resources = Assets.GetResources("sport", {})
Visuals.ResourceTypes = {}
for _, path in ipairs(Visuals.Resources) do
    Visuals.ResourceTypes[path] = Assets.ResourceTypes[path]
end
for _, path in ipairs({Rider.ModelPath, Rider.MaterialPath, Rider.DiffusePath,
    Rider.NormalPath, "Techniques/DiffNormal.xml"}) do
    Visuals.Resources[#Visuals.Resources + 1] = path
    Visuals.ResourceTypes[path] = Rider.ResourceTypes[path]
end

---@param rig Rider
local function resetBind(rig)
    for _, name in ipairs(rig.boneNames) do
        -- Resolve Bone afresh; never retain Skeleton's raw Bone pointers.
        local bone = assert(rig.model:GetSkeleton():GetBone(name))
        local bind = rig.bind[name]
        bone.node:SetTransform(bind.position, bind.rotation, bind.scale)
    end
end

---@param scene Scene
---@param target Node
---@return CareerActorVisuals
function Visuals.New(scene, target)
    local self = setmetatable({}, Visuals)
    self:Init(scene, target)
    return self
end

---@param scene Scene
---@param target Node
function Visuals:Init(scene, target)
    self.bikeNode = scene:CreateChild("CareerParkedBike_RacingAssetDebugProxy")
    self.bikeVisual = self.bikeNode:CreateChild("DebugProxyBikeVisual")
    Assets.Add(self.bikeVisual, "sport", nil, "hero")
    -- Exact sport calibration verified against Bike.GetCockpit("sport").
    -- Reuse the original high-quality MDL and public Rider interface, not Bike's
    -- racing physics, cockpit primitives, mirrors, speed or stunt effects.
    local grip = V(0.34, 1.015, 0.31)
    self.mountedRider = Rider.New(self.bikeVisual, "sport", grip)
    self.walkNode = target:CreateChild("CareerWalker_RacingAssetDebugProxy")
    self.walker = Rider.New(self.walkNode, "sport", grip)
    self.phase, self.gaitWeight, self.lean = 0, 0, 0
    self.leanSign = (Quaternion(0, 0, 10) * V.UP).x > 0 and 1 or -1
    self.mounted, self.disposed = false, false
    resetBind(self.walker)
    local model = assert(self.walker.model:GetModel())
    -- Measured MDL bounds, uniformly scaled to the same 1.78m adult as Rider.
    self.standOffset = V(0, -model.boundingBox.min.y * self.walker.heightScale, 0)
    self.walker.mesh.position = self.standOffset
    self.feet = {
        L_Foot = self.walker:GetBonePosition("L_Foot"),
        R_Foot = self.walker:GetBonePosition("R_Foot"),
    }
    self.bikeNode:SetVar("CareerAssetStatus", Variant(Visuals.ProxyLabel))
    self.walkNode:SetVar("CareerAssetStatus", Variant(Visuals.ProxyLabel))
    self:SetMounted(false)
    self:PoseWalk(0)
    print("[CareerActorVisuals] " .. Visuals.ProxyLabel .. "；王二狗/电动车正式模型尚未确认交付")
    print("[CareerActorVisuals] " .. Visuals.AnimationLabel .. "；41骨同一原资产，独立实例，不改旧Rider行为")
end

---@param mounted boolean
function Visuals:SetMounted(mounted)
    if self.disposed then return end
    self.mounted = mounted
    self.walkNode:SetEnabledRecursive(not mounted)
    self.mountedRider:SetVisible(mounted)
    if not mounted then
        self.lean = 0
        self.bikeVisual.rotation = Quaternion.IDENTITY
        self:PoseWalk(0)
    end
end

-- The same inspected 41-bone skinned racer is restored from bind each frame.
-- Rotate/IK actual bones only: no primitive human, no bone scaling or translation.
-- Feet use two-bone IK with a small pelvis clearance and alternate swing/lift;
-- arms counter-swing from their real shoulders. This is a temporary procedural
-- transition, NOT an imported walk clip or the pending Wang Ergou model.
---@param weight number
function Visuals:PoseWalk(weight)
    local rig = self.walker
    resetBind(rig)
    rig.mesh.position = self.standOffset - V(0, 0.04 * weight, 0)
    rig:SetBodyRotation("Waist", weight * 3)
    rig:SetBodyRotation("Spine01", weight * 3)
    rig:SetBodyRotation("Spine02", weight * 2)
    local wave = math.sin(self.phase)
    for _, chain in ipairs(rig.legs) do
        local base = self.feet[chain.tip]
        local swing = wave * chain.side
        local lift = math.max(0, math.cos(self.phase) * chain.side) * 0.075 * weight
        rig:SolveChain(chain, base + V(0, lift, swing * 0.23 * weight),
            V(chain.side * 0.10, 0, 1), false)
        rig:SetBodyRotation(chain.tip, -math.max(0, swing) * 8 * weight)
    end
    for _, chain in ipairs(rig.arms) do
        local shoulder = rig:GetBonePosition(chain.upper)
        local reach = chain.lengthA + chain.lengthB
        local swing = -wave * chain.side * 0.19 * weight
        rig:SolveChain(chain, shoulder + V(chain.side * 0.065, -reach * 0.93, swing),
            V(chain.side * 0.2, -0.2, 1), false)
    end
end

---@param dt number
---@param speed number
---@param steer number
---@param bikeX number
---@param bikeY number
---@param bikeZ number
---@param bikeYaw number
function Visuals:Update(dt, speed, steer, bikeX, bikeY, bikeZ, bikeYaw)
    if self.disposed then return end
    self.bikeNode.position = V(bikeX, bikeY, bikeZ)
    self.bikeNode.rotation = Quaternion(0, bikeYaw, 0)
    if self.mounted then
        local targetLean = steer * math.min(1, math.abs(speed) / (35 / 3.6)) * 12
        self.lean = self.lean + (targetLean - self.lean) * (1 - math.exp(-dt * 10))
        self.bikeVisual.rotation = Quaternion(0, 0, self.lean * self.leanSign)
        -- The debug proxy is a single MDL with fixed handlebars. Keep hands on
        -- its real grips; the city dynamics own yaw, not a fake moving handlebar.
        self.mountedRider:Update(0, false, self.lean)
    else
        local targetWeight = math.min(1, math.abs(speed) / 1.8)
        self.gaitWeight = self.gaitWeight + (targetWeight - self.gaitWeight) * (1 - math.exp(-dt * 14))
        self.phase = (self.phase + math.abs(speed) * dt * math.pi * 2 / 1.25) % (math.pi * 2)
        self:PoseWalk(self.gaitWeight)
    end
end

function Visuals:Dispose()
    if self.disposed then return end
    self.disposed = true
    self.mountedRider:Dispose()
    self.walker:Dispose()
    self.bikeNode:Dispose()
    self.walkNode:Dispose()
end

return Visuals
