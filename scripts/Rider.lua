-- 全盔连体赛车服骑手；骨骼命名/朝向与上一版一致，直接复用同一套手动骑姿解算。
local V = Vector3
local ROOT = "model/b3b4ca93506c4baba807b60e71555d2d/"
local STEM = "rig-1-c09759e5-dd10-4064-900b-8c28233ef213"

---@class RiderPoseConfig
---@field hip Vector3
---@field foot Vector3 右踝；左踝镜像X
---@field waist number
---@field spine number
---@field chest number
---@field head number
---@field kneeHint Vector3
---@field elbowHint Vector3
---@field height? number 成年骑手身高米数，整个人等比；不单独伸缩四肢

---@class RiderBindPose
---@field position Vector3
---@field rotation Quaternion
---@field scale Vector3
---@field modelRotation Quaternion
---@field parentName string|nil

---@class RiderChain
---@field upper string
---@field lower string
---@field tip string
---@field side number
---@field lengthA number
---@field lengthB number

---@class Rider
---@field parent Node
---@field node Node
---@field mesh Node
---@field model AnimatedModel
---@field material Material
---@field config RiderPoseConfig
---@field bind table<string, RiderBindPose>
---@field arms RiderChain[]
---@field legs RiderChain[]
---@field grip Vector3 右握把
---@field leftGrip Vector3 左握把；允许与右握把有真实车型偏移
---@field rightGrip Vector3 右握把
---@field gripOrigin Vector3 两握把之间的转向中心
---@field lastSteer number
---@field visible boolean
---@field heightScale number
---@field vehicleId string
---@field classId string
---@field colorId string
---@field disposed boolean
---@field warnedReach table<string, boolean>
---@field initializing boolean
---@field boneNames string[]
---@field lastLean number
local Rider = {}
Rider.__index = Rider

Rider.ModelPath = ROOT .. "Meshes/" .. STEM .. ".mdl"
Rider.MaterialPath = ROOT .. "Materials/" .. STEM .. "_00_tripo_material_a25358d7-b55a-4920-9f10-2adc510c072f.xml"
Rider.DiffusePath = ROOT .. "Textures/" .. STEM .. "_00_D.jpg"
Rider.NormalPath = ROOT .. "Textures/" .. STEM .. "_00_N.png"
Rider.Resources = {
    Rider.ModelPath, Rider.MaterialPath, Rider.DiffusePath, Rider.NormalPath,
    ROOT .. "Textures/" .. STEM .. "_00_D.xml",
    ROOT .. "Textures/" .. STEM .. "_00_N.xml", "Techniques/DiffNormal.xml",
}
Rider.ResourceTypes = {
    [Rider.ModelPath] = "Model", [Rider.MaterialPath] = "Material",
    [Rider.DiffusePath] = "Texture2D", [Rider.NormalPath] = "Texture2D",
    [ROOT .. "Textures/" .. STEM .. "_00_D.xml"] = "XMLFile",
    [ROOT .. "Textures/" .. STEM .. "_00_N.xml"] = "XMLFile",
    ["Techniques/DiffNormal.xml"] = "Technique",
}

-- 仅替换原图的红色皮革/头盔面板；黑色护甲、白缝线、镜片与原Normal保持不变。
-- 六张1024px PNG由原diffuse遮罩离线生成，不覆盖原资产。
Rider.ColorIds = {"red", "blue", "yellow", "white", "green", "violet"}
---@class RiderPalette
---@field id string
---@field label string
---@field color number[]
---@field diffuse string
---@type table<string, RiderPalette>
Rider.Palettes = {
    red = {id = "red", label = "赤焰红", color = {238, 53, 43, 255}, diffuse = ROOT .. "Textures/RiderColors/red.png"},
    blue = {id = "blue", label = "竞速蓝", color = {42, 115, 245, 255}, diffuse = ROOT .. "Textures/RiderColors/blue.png"},
    yellow = {id = "yellow", label = "闪电黄", color = {250, 216, 37, 255}, diffuse = ROOT .. "Textures/RiderColors/yellow.png"},
    white = {id = "white", label = "极地白", color = {240, 244, 250, 255}, diffuse = ROOT .. "Textures/RiderColors/white.png"},
    green = {id = "green", label = "疾风绿", color = {42, 216, 81, 255}, diffuse = ROOT .. "Textures/RiderColors/green.png"},
    violet = {id = "violet", label = "电光紫", color = {173, 55, 245, 255}, diffuse = ROOT .. "Textures/RiderColors/violet.png"},
}
for _, id in ipairs(Rider.ColorIds) do
    local path = ROOT .. "Textures/RiderColors/" .. id .. ".png"
    Rider.Palettes[id].diffuse = path
    Rider.Resources[#Rider.Resources + 1] = path
    Rider.ResourceTypes[path] = "Texture2D"
end

---@param vehicleId string
---@return string
function Rider.ClassFor(vehicleId)
    return vehicleId:match("^(%a+)") or vehicleId
end

---@type table<string, RiderPoseConfig>
Rider.Poses = {
    sport = {hip = V(0, 0.95, -0.43), foot = V(0.28, 0.39, -0.28),
        waist = 48, spine = 60, chest = 68, head = 12,
        kneeHint = V(0.26, 0.08, 1), elbowHint = V(0.8, -0.6, -0.5)},
    rally = {hip = V(0, 1.03, -0.25), foot = V(0.29, 0.43, -0.16),
        waist = 30, spine = 40, chest = 46, head = 5,
        kneeHint = V(0.25, 0, 1), elbowHint = V(1, -0.4, -0.4)},
    -- 巡航目标来自新整车顶点测量：低座、宽高把、脚踏前置；不复用仿赛趴伏。
    cruiser = {hip = V(0, 0.95, -0.30), foot = V(0.31, 0.46, 0.12),
        waist = 22, spine = 30, chest = 38, head = 3,
        kneeHint = V(0.3, 0.2, 1), elbowHint = V(1, -0.7, -0.3)},
}

-- 新整车归一化尺寸不同；髋点位于测得座面上方9cm（骨盆中心而非臀部接触面）。
-- 脚踝位于脚踏上方，脚掌由原绑定形状自然延伸；接触点不会靠缩放骨长补齐。
Rider.Poses.sport_2 = {hip = V(0, 1.293, -0.33), foot = V(0.32, 0.62, -0.32),
    waist = 48, spine = 60, chest = 68, head = 12,
    kneeHint = V(0.26, 0.08, 1), elbowHint = V(0.8, -0.6, -0.5)}
Rider.Poses.sport_3 = {hip = V(0, 1.215, -0.30), foot = V(0.30, 0.48, -0.27),
    waist = 48, spine = 60, chest = 68, head = 12,
    kneeHint = V(0.26, 0.08, 1), elbowHint = V(0.8, -0.6, -0.5)}
Rider.Poses.cruiser_2 = {hip = V(-0.09, 1.09, -0.20), foot = V(0.31, 0.40, -0.12), height = 1.90,
    waist = 22, spine = 30, chest = 38, head = 3,
    kneeHint = V(0.3, 0.2, 1), elbowHint = V(1, -0.7, -0.3)}
Rider.Poses.cruiser_3 = {hip = V(0, 1.165, -0.25), foot = V(0.30, 0.52, -0.12),
    waist = 22, spine = 30, chest = 38, head = 3,
    kneeHint = V(0.3, 0.2, 1), elbowHint = V(1, -0.7, -0.3)}
Rider.Poses.rally_2 = {hip = V(0, 1.185, -0.22), foot = V(0.27, 0.52, -0.14),
    waist = 30, spine = 40, chest = 46, head = 5,
    kneeHint = V(0.25, 0, 1), elbowHint = V(1, -0.4, -0.4)}
Rider.Poses.rally_3 = {hip = V(0, 1.39, -0.26), foot = V(0.29, 0.63, -0.16),
    waist = 30, spine = 40, chest = 46, head = 5,
    kneeHint = V(0.25, 0, 1), elbowHint = V(1, -0.4, -0.4)}

-- 正式电动车是平踏板坐姿；接触点位于MixedVisuals归一化后的本地米坐标。
-- 座面z=-.22处约.996m，Hip骨盆中心高于接触面9cm；靴底高于踝点约8cm。
Rider.Poses.ebike = {hip = V(0, 1.086, -0.22), foot = V(0.19, 0.44, -0.08),
    waist = 30, spine = 40, chest = 46, head = 5,
    kneeHint = V(0.3, 0.2, 1), elbowHint = V(1, -0.4, -0.4)}

---@class RiderGripBinding
---@field right Vector3
---@field left Vector3
---@field origin? Vector3

---@param model AnimatedModel
---@param name string
---@return Node
local function boneNode(model, name)
    -- Bone是Skeleton内的裸指针；不跨帧保存，模型重载后也重新解析。
    local bone = model:GetSkeleton():GetBone(name)
    assert(bone and bone.node, "Rider skeleton missing bone: " .. name)
    return bone.node
end

-- 所有IK与朝向都在车辆visual的本地米坐标解算。
-- 不从世界坐标相减再逆变换：在公里级远坐标会丢失毫米精度，且不应把父lean/pitch烘进骨骼。
---@param name string
---@return Matrix3x4
function Rider:GetLocalBoneTransform(name)
    local bind = self.bind[name]
    local localTransform = boneNode(self.model, name).transform
    if bind.parentName then return self:GetLocalBoneTransform(bind.parentName) * localTransform end
    return self.node.transform * self.mesh.transform * localTransform
end

---@param name string
---@param rotation Quaternion 车辆本地绝对朝向，不是骨骼父节点本地朝向
function Rider:SetLocalBoneRotation(name, rotation)
    local bind = self.bind[name]
    local parentTransform = bind.parentName and self:GetLocalBoneTransform(bind.parentName)
        or self.node.transform * self.mesh.transform
    boneNode(self.model, name).rotation = (parentTransform:Rotation():Inverse() * rotation):Normalized()
end

---@param name string
---@param childName string
---@param target Vector3
function Rider:PointJoint(name, childName, target)
    local joint = self:GetLocalBoneTransform(name)
    local from = self:GetLocalBoneTransform(childName):Translation() - joint:Translation()
    local to = target - joint:Translation()
    -- 退化时不能抛错中断整段姿势：否则骨骼会停在半新半旧的中间态，
    -- 表现为躯干/四肢被撕成条带，而且停住后不会自行恢复。保留原旋转即可。
    if from:LengthSquared() < 1e-12 or to:LengthSquared() < 1e-12 then
        self.degenerateFrames = (self.degenerateFrames or 0) + 1
        return
    end
    self:SetLocalBoneRotation(name, Quaternion(from:Normalized(), to:Normalized()) * joint:Rotation())
end

-- 两段骨骼IK，仅旋转关节，绝不拉长骨骼或移动肘/膝。
--      root O ---- a ---- O joint ---- b ---- O target
--                         ^ hint 指向弯曲侧；距离夹在 |a-b| 与 a+b 内。
-- 防退化：零距离、完全伸直、反折极值均夹开；hint平行时选非平行备用轴。
---@param root Vector3
---@param target Vector3
---@param lengthA number
---@param lengthB number
---@param hint Vector3
---@return Vector3, Vector3
local function solveTwoBone(root, target, lengthA, lengthB, hint)
    local delta = target - root
    local distance = delta:Length()
    -- 退化输入返回 nil，由调用方跳过本次解算；绝不抛错。
    if distance <= 0.00001 then return nil, nil end
    local direction = delta / distance
    local reach = math.max(math.abs(lengthA - lengthB) + 0.0001,
        math.min(lengthA + lengthB - 0.0001, distance))
    local cosine = math.max(-1, math.min(1,
        (lengthA * lengthA + reach * reach - lengthB * lengthB) / (2 * lengthA * reach)))
    local perpendicular = hint - direction * hint:DotProduct(direction)
    if perpendicular:Length() < 0.00001 then
        local axis = math.abs(direction.y) < 0.9 and V.UP or V.RIGHT
        perpendicular = axis - direction * axis:DotProduct(direction)
    end
    local joint = root + direction * (lengthA * cosine)
        + perpendicular:Normalized() * (lengthA * math.sqrt(math.max(0, 1 - cosine * cosine)))
    return joint, root + direction * reach
end

---@param parent Node 车辆visual，所有目标均为此节点的本地米坐标
---@param vehicleId string
---@param grip Vector3 右握把（兼容旧调用）
---@param gripBinding? RiderGripBinding 左右握把及转向中心；省略时按X镜像
---@return Rider
function Rider.New(parent, vehicleId, grip, gripBinding)
    local self = setmetatable({}, Rider)
    self:Init(parent, vehicleId, grip, gripBinding)
    return self
end

---@param parent Node
---@param vehicleId string
---@param grip Vector3 右握把（兼容旧调用）
---@param gripBinding? RiderGripBinding
function Rider:Init(parent, vehicleId, grip, gripBinding)
    self.parent, self.vehicleId = parent, vehicleId
    self.classId = Rider.ClassFor(vehicleId)
    self.colorId, self.disposed = "red", false
    self.config = assert(Rider.Poses[vehicleId] or Rider.Poses[self.classId], "Unsupported rider pose: " .. vehicleId)
    self.grip = grip
    self.rightGrip = gripBinding and gripBinding.right or grip
    self.leftGrip = gripBinding and gripBinding.left or V(-grip.x, grip.y, grip.z)
    self.gripOrigin = gripBinding and gripBinding.origin
        or V(0, grip.y, grip.z + 0.09)
    assert(self.rightGrip and self.leftGrip and self.gripOrigin, "Rider grip binding incomplete")
    self.node = parent:CreateChild("ThirdPersonRider")
    self.mesh = self.node:CreateChild("RiggedLeatherRider")
    self.model = self.mesh:CreateComponent("AnimatedModel")
    local resource = assert(cache:GetResource("Model", Rider.ModelPath), "Missing rigged rider MDL")
    self.model:SetModel(resource)
    assert(self.model:GetSkeleton():GetNumBones() == 41, "Wrong rider pack: expected 41 bones")
    self.model:RemoveAllAnimationStates()
    self.model.updateInvisible = true
    self.model.animationLodBias = 0 -- 手动pose不按可见性/动画LOD延迟提交。几何LOD仍正常工作。
    self.model.castShadows = true
    self.material = assert(cache:GetResource("Material", Rider.MaterialPath), "Missing rider material"):Clone()
    self.material:SetTexture(TU_DIFFUSE, assert(cache:GetResource("Texture2D", Rider.DiffusePath)))
    self.material:SetTexture(TU_NORMAL, assert(cache:GetResource("Texture2D", Rider.NormalPath)))
    self.model:SetMaterial(self.material)
    -- 本包mesh沿Z展开，但初始骨架已转换为X左右/+Z前，不再额外yaw90。
    self.heightScale = (self.config.height or 1.78) / resource.boundingBox.size.y
    self.mesh:SetScale(self.heightScale)
    self.bind, self.arms, self.legs, self.boneNames = {}, {}, {}, {}
    self.warnedReach, self.initializing = {}, true
    self.visible, self.lastSteer, self.lastLean = true, 0, 0
    local skeleton = self.model:GetSkeleton()
    -- 这里是引擎Skeleton零起始索引，不是Lua数组。
    for index = 0, skeleton:GetNumBones() - 1 do
        local bone = skeleton:GetBone(index)
        assert(bone and bone.node, "Rider bone node not created")
        -- 不交给引擎动画重置：无动画状态时 ApplyAnimation 会把骨骼还原成绑定姿势，
        -- 与脚本手写姿势竞争，产生间歇性蒙皮撕裂。
        bone.animated = false
        local parentBone = index ~= bone.parentIndex and skeleton:GetBone(bone.parentIndex) or nil
        self.boneNames[#self.boneNames + 1] = bone.name
        self.bind[bone.name] = {position = bone.initialPosition,
            rotation = Quaternion(bone.initialRotation), scale = bone.initialScale,
            modelRotation = Quaternion.IDENTITY, parentName = parentBone and parentBone.name or nil}
        bone.node:SetTransform(bone.initialPosition, bone.initialRotation, bone.initialScale)
    end
    -- 初始绑定朝向同样只走本地FK，创建时父节点已倾斜/位于远坐标也不污染绑定基准。
    for _, name in ipairs(self.boneNames) do
        self.bind[name].modelRotation = self:GetLocalBoneTransform(name):Rotation()
    end
    self.mesh.position = self.config.hip - self:GetBonePosition("Hip")
    for _, side in ipairs({-1, 1}) do
        local prefix = side == -1 and "L_" or "R_"
        self.arms[#self.arms + 1] = self:CreateChain(prefix .. "Upperarm", prefix .. "Forearm", prefix .. "Hand", side)
        self.legs[#self.legs + 1] = self:CreateChain(prefix .. "Thigh", prefix .. "Calf", prefix .. "Foot", side)
    end
    self:PoseBody()
    self:Update(0, true)
    self.model:UpdateBoneBoundingBox()
    self:ValidatePose()
    self.initializing = false
    print("[骑手] 全盔连体赛车服骑手 / 手动骨骼骑姿 / 无骑行clip，头盔为模型自带")
end

---@param upper string
---@param lower string
---@param tip string
---@param side number
---@return RiderChain
function Rider:CreateChain(upper, lower, tip, side)
    return {upper = upper, lower = lower, tip = tip, side = side,
        lengthA = (self:GetBonePosition(lower) - self:GetBonePosition(upper)):Length(),
        lengthB = (self:GetBonePosition(tip) - self:GetBonePosition(lower)):Length()}
end

---@param name string
---@param pitch number
---@param yaw? number
---@param roll? number
function Rider:SetBodyRotation(name, pitch, yaw, roll)
    self:SetLocalBoneRotation(name, Quaternion(roll or 0, V.FORWARD)
        * Quaternion(yaw or 0, V.UP) * Quaternion(pitch, V.RIGHT) * self.bind[name].modelRotation)
end

function Rider:PoseBody()
    local c = self.config
    -- Hip与Pelvis不转，Waist和Pelvis为兄弟：胸椎前屈不拖动腿和坐垫接触点。
    self:SetBodyRotation("Waist", c.waist)
    self:SetBodyRotation("Spine01", c.spine)
    self:SetBodyRotation("Spine02", c.chest)
    self:SetBodyRotation("NeckTwist01", c.head + 5)
    self:SetBodyRotation("NeckTwist02", c.head + 2)
    self:SetBodyRotation("Head", c.head)
    for _, chain in ipairs(self.legs) do
        local foot = V(chain.side * c.foot.x, c.foot.y, c.foot.z)
        local hint = V(chain.side * c.kneeHint.x, c.kneeHint.y, c.kneeHint.z)
        self:SolveChain(chain, foot, hint, true)
        -- 脚掌保持前向；保留该rig绑定时的脚掌/脚尖相对方向。
        self:SetBodyRotation(chain.tip, 0)
    end
end

---@param chain RiderChain
---@param localTarget Vector3
---@param localHint Vector3
---@param strict boolean
function Rider:SolveChain(chain, localTarget, localHint, strict)
    local upper = boneNode(self.model, chain.upper)
    local lower = boneNode(self.model, chain.lower)
    local tip = boneNode(self.model, chain.tip)
    local target = localTarget
    local distance = (target - self:GetBonePosition(chain.upper)):Length()
    local reachable = distance < chain.lengthA + chain.lengthB - 0.0001
        and distance > math.abs(chain.lengthA - chain.lengthB) + 0.0001
    if not reachable then
        -- 运行时绝不因握把目标瞬时不可达而中断整段姿势。可操纵范围内的轻微越界
        -- 由 solveTwoBone 的距离夹取吸收；只有初始化（strict）才把它当成骨架配置错误。
        if strict and self.initializing then
            assert(distance < chain.lengthA + chain.lengthB - 0.0001,
                "Rider unreachable target: " .. chain.tip .. " / " .. tostring(distance))
            assert(distance > math.abs(chain.lengthA - chain.lengthB) + 0.0001, "Rider folded target: " .. chain.tip)
        elseif not self.warnedReach[chain.tip] then
            self.warnedReach[chain.tip] = true
            print(string.format("[骑手IK] %s %s 目标%.4fm超出骨长范围，安全夹取",
                self.vehicleId, chain.tip, distance))
        end
        self.reachClampedFrames = (self.reachClampedFrames or 0) + 1
    end
    -- 每次从绑定局部姿势解算，避免转向多帧累计旋转导致骨骼roll漂移。
    upper.rotation = self.bind[chain.upper].rotation
    lower.rotation = self.bind[chain.lower].rotation
    tip.rotation = self.bind[chain.tip].rotation
    local joint, reachedTarget = solveTwoBone(self:GetBonePosition(chain.upper), target,
        chain.lengthA, chain.lengthB, localHint)
    if not joint then return end
    self:PointJoint(chain.upper, chain.lower, joint)
    self:PointJoint(chain.lower, chain.tip, reachedTarget)
    -- twist骨是对应上/下段的子骨，保留绑定局部旋转后会自动跟随，不要重复旋转。
end

---@param steerAngle number
---@param force? boolean 保留原接口；手动pose现在每次调用完整重置/提交，不以steer缓存跳过父变换。
---@param lean? number 向弯内带符号的倾角（度）；省略时保留上次值，兼容Update(angle,true)。
function Rider:Update(steerAngle, force, lean)
    self.lastSteer = steerAngle
    self.lastLean = math.max(-55, math.min(55, lean or self.lastLean))
    if not self.visible then return end

    -- 姿势必须是全有或全无的事务：任何一步意外中断，都不能把骨骼留在
    -- 半新半旧的姿态（这正是整块网格被撕成条带的形态）。失败时整只骑手
    -- 退回完整绑定姿势，下一帧再重新解算。
    local ok, err = pcall(function() self:ApplyPose(steerAngle) end)
    if not ok then
        for _, name in ipairs(self.boneNames) do
            local bind = self.bind[name]
            boneNode(self.model, name):SetTransform(bind.position, bind.rotation, bind.scale)
        end
        self.poseFailures = (self.poseFailures or 0) + 1
        if self.poseFailures == 1 then print("[骑手] 姿势解算中断，已回退绑定姿势：" .. tostring(err)) end
    end
end

---@param steerAngle number
function Rider:ApplyPose(steerAngle)
    -- 一次完整的本地pose事务：每帧恢复全部41骨（含twist）的绑定TRS，再父到子旋转。
    -- 不允许把上一帧世界朝向、不可见期间的旧姿势或局部缩放混进下一次IK。
    for _, name in ipairs(self.boneNames) do
        local bind = self.bind[name]
        boneNode(self.model, name):SetTransform(bind.position, bind.rotation, bind.scale)
    end
    self:PoseBody()
    -- 仅胸肩轻微追随车把；髋和腿保持原坐垫/脚踏接触点，仿赛原姿不改。
    local torsoYaw = self.classId == "sport" and 0
        or steerAngle * (self.classId == "cruiser" and 0.4 or 0.25)
    -- 极宽把需要胸肩朝远侧手前送，不能随近侧手反向缩回。
    if self.vehicleId == "cruiser_2" then torsoYaw = -steerAngle * 0.65 end
    local c = self.config
    local rollSign = (Quaternion(0, 0, 10) * V.UP).x > 0 and 1 or -1
    -- 巡航宽把极舵已接近臂展极限，不再叠加侧倾；整个人仍随父车架压弯。
    local bodyRoll = self.lastLean * rollSign * (self.classId == "sport" and 0.055
        or self.classId == "rally" and 0.035 or 0)
    self:SetBodyRotation("Waist", c.waist, torsoYaw, bodyRoll * 0.5)
    self:SetBodyRotation("Spine01", c.spine, torsoYaw, bodyRoll * 0.8)
    self:SetBodyRotation("Spine02", c.chest, torsoYaw, bodyRoll)
    self:SetBodyRotation("NeckTwist01", c.head + 5, torsoYaw * 0.3, bodyRoll * 0.5)
    self:SetBodyRotation("NeckTwist02", c.head + 2, torsoYaw * 0.3, bodyRoll * 0.4)
    self:SetBodyRotation("Head", c.head, torsoYaw * 0.3, bodyRoll * 0.3)
    local origin = self.gripOrigin
    local steering = Quaternion(0, steerAngle, 0)
    for _, chain in ipairs(self.arms) do
        -- 宽把极舵时远侧肩胛前伸，旋转真实锁骨，不挪髋也不拉长上臂。
        -- 拉力/巡航分别使用8/13cm的方向目标偏移；实际肩点仍由锁骨长度约束。
        local prefix = chain.side == -1 and "L_" or "R_"
        local clavicle = boneNode(self.model, prefix .. "Clavicle")
        clavicle.rotation = self.bind[prefix .. "Clavicle"].rotation
        if self.classId ~= "sport" and chain.side * steerAngle < 0 then
            local shoulder = self:GetBonePosition(chain.upper)
            local protraction = math.min(1, math.abs(steerAngle) / 22)
                * (self.classId == "cruiser" and 0.13 or 0.08)
            self:PointJoint(prefix .. "Clavicle", chain.upper, shoulder + V(0, 0, protraction))
        end
        -- 手腕在手掌后方约5cm；模型手掌自然延伸到真实握把。
        local boundGrip = chain.side == 1 and self.rightGrip or self.leftGrip
        local wrist = origin + steering * (boundGrip - origin + V(0, 0.012, -0.045))
        local hint = self.config.elbowHint
        -- 宽把巡航的肩胛随握把方向外展；只旋转真实锁骨，保持骨长和座垫髋点。
        -- 非对称整车中心偏移会使外侧握把更远，不能简单平移/拉长手臂补偿。
        if self.vehicleId == "cruiser_2" or self.vehicleId == "sport_2" then
            self:PointJoint(prefix .. "Clavicle", chain.upper, wrist)
        end
        self:SolveChain(chain, wrist, V(chain.side * hint.x, hint.y, hint.z), self.initializing)
        -- 手指朝前下方，保留左右手各自的绑定翻转，不交换手掌朝向。
        local bindRotation = self.bind[chain.tip].modelRotation
        local fingerDirection = bindRotation * V.UP
        self:SetLocalBoneRotation(chain.tip,
            Quaternion(fingerDirection, (steering * V(0, -0.25, 1)):Normalized()) * bindRotation)
    end
    -- 不在每帧姿态写入后立刻重算骨骼包围盒：这一步会遍历骨骼/顶点，与引擎
    -- 自己的蒙皮更新叠加会放大同帧数据竞争。绑定姿势的包围盒比骑姿更宽松，
    -- 保留它做剔除足够安全，也避免每帧重复扫描。
end

---@param id string
---@return boolean
function Rider:SetColor(id)
    if self.disposed then return false end
    local palette = Rider.Palettes[id]
    if not palette then return false end
    local texture = cache:GetResource("Texture2D", palette.diffuse)
    if not texture then
        print("[骑手配色] 缺少贴图：" .. palette.diffuse)
        return false
    end
    self.material:SetTexture(TU_DIFFUSE, texture)
    self.material:SetShaderParameter("MatDiffColor", Variant(Color(1, 1, 1, 1)))
    self.colorId = id
    return true
end

---@param visible boolean
function Rider:SetVisible(visible)
    if self.disposed then return end
    self.visible = visible
    self.node:SetEnabledRecursive(visible)
    if visible then self:Update(self.lastSteer, true) end
end

---@param name string
---@return Vector3
function Rider:GetBonePosition(name)
    return self:GetLocalBoneTransform(name):Translation()
end

-- 返回实际骨骼位置而非配置目标，便于headless/实拍回归读回。
---@return table
function Rider:ReadPose()
    local result = {vehicleId = self.vehicleId, hip = self:GetBonePosition("Hip"),
        head = self:GetBonePosition("Head"), leftHand = self:GetBonePosition("L_Hand"),
        rightHand = self:GetBonePosition("R_Hand"), leftFoot = self:GetBonePosition("L_Foot"),
        rightFoot = self:GetBonePosition("R_Foot")}
    local chest = self:GetBonePosition("NeckTwist01") - self:GetBonePosition("Spine02")
    result.chestTilt = math.deg(math.atan(chest.z, chest.y))
    local origin = self.gripOrigin
    local steering = Quaternion(0, self.lastSteer, 0)
    result.leftGripError = (result.leftHand - (origin + steering * (self.leftGrip + V(0, 0.012, -0.045) - origin))):Length()
    result.rightGripError = (result.rightHand - (origin + steering * (self.rightGrip + V(0, 0.012, -0.045) - origin))):Length()
    return result
end

function Rider:ValidatePose()
    local pose = self:ReadPose()
    assert((pose.hip - self.config.hip):Length() < 0.002, "Rider hip left saddle")
    assert(pose.leftGripError < 0.005 and pose.rightGripError < 0.005, "Rider hands detached from grips")
    if self.classId == "sport" then assert(pose.chestTilt > 50, "Sport rider must tuck, not sit upright") end
    print(string.format("[骑姿] %s Hip=%s Head=%s LHand=%s RHand=%s LFoot=%s RFoot=%s chest=%.1fdeg gripError=%.4f/%.4fm",
        self.vehicleId, pose.hip:ToString(), pose.head:ToString(), pose.leftHand:ToString(),
        pose.rightHand:ToString(), pose.leftFoot:ToString(), pose.rightFoot:ToString(),
        pose.chestTilt, pose.leftGripError, pose.rightGripError))
end

-- 仅显式回归调用时读取CPU shadow buffer；不缓存Bone，也不在游戏每帧读顶点。
---@param onlyLod? integer 只解码指定的0起始LOD；默认仍完整返回全部LOD供蒙皮验收。
---@return table[]
function Rider:ReadSkinVertices(onlyLod)
    local resource = self.model:GetModel()
    local lods = {}
    assert(resource:GetNumGeometries() == 1, "Rider skin test expects inspected single-geometry pack")
    local lastLod=resource:GetNumGeometryLodLevels(0)-1
    assert(onlyLod==nil or onlyLod>=0 and onlyLod<=lastLod,"蒙皮读取LOD越界")
    for lod = onlyLod or 0, onlyLod or lastLod do
        local vb = resource:GetGeometry(0, lod):GetVertexBuffer(0)
        assert(vb:HasElement(TYPE_VECTOR3, SEM_POSITION)
            and vb:HasElement(TYPE_VECTOR4, SEM_BLENDWEIGHTS)
            and vb:HasElement(TYPE_UBYTE4, SEM_BLENDINDICES), "Rider unexpected skin layout")
        local data = vb:GetData()
        assert(data.size >= vb.vertexCount * vb.vertexSize, "Rider missing CPU skin buffer")
        local vertices = {}
        for index = 0, vb.vertexCount - 1 do
            local start = index * vb.vertexSize
            data:Seek(start + vb:GetElementOffset(SEM_POSITION))
            local position = data:ReadVector3()
            data:Seek(start + vb:GetElementOffset(SEM_BLENDWEIGHTS))
            local weights = {data:ReadFloat(), data:ReadFloat(), data:ReadFloat(), data:ReadFloat()}
            data:Seek(start + vb:GetElementOffset(SEM_BLENDINDICES))
            local indices = {data:ReadUByte(), data:ReadUByte(), data:ReadUByte(), data:ReadUByte()}
            local sum = weights[1] + weights[2] + weights[3] + weights[4]
            assert(math.abs(sum - 1) < 0.00001, "Rider invalid skin weight sum")
            for slot = 1, 4 do
                assert(weights[slot] >= 0 and indices[slot] < #self.boneNames, "Rider invalid skin influence")
            end
            vertices[#vertices + 1] = {position = position, weights = weights, indices = indices}
        end
        lods[#lods + 1] = vertices
    end
    -- 已实际核对当前MDL：geometry0的boneMappings为空，四LOD使用全局0..40 palette。
    -- 替换资源后必须重新审计palette，不能把此测试直接当任意模型的GPU蒙皮读回。
    return lods
end

---@param vertex table
---@param matrices Matrix3x4[]
---@return Vector3
local function skinVertex(vertex, matrices)
    local x, y, z = 0, 0, 0
    for slot = 1, 4 do
        local p = matrices[vertex.indices[slot] + 1] * vertex.position
        local weight = vertex.weights[slot]
        x, y, z = x + p.x * weight, y + p.y * weight, z + p.z * weight
    end
    return V(x, y, z)
end

-- 完整的骨矩阵/真实权重CPU蒙皮回归；不是只看腕点，更不冒充GPU上传或截图验收。
-- 调用者每车型显式调用一次。测试保留并恢复父TRS/可见性/steer/lean，失败也恢复。
---@return table
function Rider:TestTransforms()
    local savedPosition, savedRotation, savedScale = self.parent.position, Quaternion(self.parent.rotation), self.parent.scale
    local savedSteer, savedLean, savedVisible = self.lastSteer, self.lastLean, self.visible
    local report = {vehicleId = self.vehicleId, cases = 0, vertices = 0,
        maxMatrixError = 0, maxSkinError = 0, maxGripError = 0, maxBoneLengthError = 0, maxBindError = 0}
    local ok, err = pcall(function()
        self:SetVisible(true)
        local lods = self:ReadSkinVertices()
        for _, vertices in ipairs(lods) do report.vertices = report.vertices + #vertices end
        local axes = {V.ZERO, V.RIGHT, V.UP, V.FORWARD}
        -- 绑定矩阵彼此应给出同一个mesh基变换；本包存在共同轴变换，不能盲断言identity。
        for _, name in ipairs(self.boneNames) do
            local bind = self.bind[name]
            boneNode(self.model, name):SetTransform(bind.position, bind.rotation, bind.scale)
        end
        local skeleton = self.model:GetSkeleton()
        local root = skeleton:GetBone(0)
        local rootBind = self:GetLocalBoneTransform(root.name) * root.offsetMatrix
        for _, name in ipairs(self.boneNames) do
            local b = skeleton:GetBone(name)
            local bindSkin = self:GetLocalBoneTransform(name) * b.offsetMatrix
            for _, axis in ipairs(axes) do
                report.maxBindError = math.max(report.maxBindError, (bindSkin * axis - rootBind * axis):Length())
            end
        end
        -- 实测本包Waist的导入绑定残差1.18mm（不是identity精度），不篡改inverse bind来掩盖它。
        assert(report.maxBindError < 0.002, "Rider inverse-bind matrices disagree by >2mm")
        local cases = {
            {lean = 0, pitch = 0, yaw = 0, steer = 0},
            {lean = 50, pitch = 35, yaw = 179, steer = 22},
            {lean = -50, pitch = -35, yaw = -179, steer = -22},
            {lean = 50, pitch = -35, yaw = 721, steer = 0},
            {lean = -50, pitch = 35, yaw = -1081, steer = 0},
        }
        for frame = 1, 24 do
            cases[#cases + 1] = {lean = math.sin(frame * 0.73) * 50,
                pitch = math.cos(frame * 0.91) * 35, yaw = frame * 137,
                steer = frame <= 12 and 0 or math.sin(frame * 0.57) * 22}
        end
        for index, case in ipairs(cases) do
            -- reference在原点求解，同输入移到远坐标后不得改变任何本地pose。
            self.parent:SetTransform(V.ZERO, Quaternion.IDENTITY, V.ONE)
            self:Update(case.steer, false, case.lean)
            local reference = {}
            for _, name in ipairs(self.boneNames) do reference[name] = self:GetLocalBoneTransform(name) end
            local far = index % 2 == 0 and V(1400, 42, -3100) or V(-12000, 350, 8500)
            self.parent:SetTransform(far, Quaternion(case.pitch, case.yaw, case.lean), V.ONE)
            self:Update(case.steer, false, case.lean) -- 故意恒steer、不force，父TRS仍变化
            local localMatrices, worldMatrices = {}, {}
            local inverseParent = self.parent.worldTransform:Inverse()
            for bi, name in ipairs(self.boneNames) do
                local bone = skeleton:GetBone(name) -- 每次新解析，不跨帧保存裸Bone
                local fk = self:GetLocalBoneTransform(name)
                local actual = bone:GetFinalWorldTransform()
                local expected = self.parent.worldTransform * fk
                local bind = self.bind[name]
                assert((bone.node.position - bind.position):Length() < 0.000001, "Rider translated bone: " .. name)
                assert((bone.node.scale - bind.scale):Length() < 0.000001, "Rider stretched bone: " .. name)
                for _, axis in ipairs(axes) do
                    local error = math.max((actual * axis - expected * axis):Length(), (fk * axis - reference[name] * axis):Length())
                    assert(error == error and error < 0.012, "Rider world/FK matrix mismatch: " .. name)
                    report.maxMatrixError = math.max(report.maxMatrixError, error)
                end
                localMatrices[bi] = fk * bone.offsetMatrix
                worldMatrices[bi] = actual * bone.offsetMatrix
            end
            for _, chains in ipairs({self.arms, self.legs}) do
                for _, chain in ipairs(chains) do
                    local a, b, c = self:GetBonePosition(chain.upper), self:GetBonePosition(chain.lower), self:GetBonePosition(chain.tip)
                    local error = math.max(math.abs((b - a):Length() - chain.lengthA), math.abs((c - b):Length() - chain.lengthB))
                    report.maxBoneLengthError = math.max(report.maxBoneLengthError, error)
                    assert(error < 0.00001, "Rider chain stretched")
                end
            end
            local pose = self:ReadPose()
            report.maxGripError = math.max(report.maxGripError, pose.leftGripError, pose.rightGripError)
            assert(pose.leftGripError < 0.005 and pose.rightGripError < 0.005, "Rider grip regression")
            assert((pose.hip - self.config.hip):Length() < 0.00001, "Rider saddle regression")
            assert((pose.leftFoot - V(-self.config.foot.x, self.config.foot.y, self.config.foot.z)):Length() < 0.00001
                and (pose.rightFoot - self.config.foot):Length() < 0.00001, "Rider footpeg regression")
            for lod, vertices in ipairs(lods) do
                local box = BoundingBox()
                for _, vertex in ipairs(vertices) do
                    local localPoint = skinVertex(vertex, localMatrices)
                    local worldPoint = skinVertex(vertex, worldMatrices)
                    local error = (inverseParent * worldPoint - localPoint):Length()
                    report.maxSkinError = math.max(report.maxSkinError, error)
                    assert(error == error and error < 0.015, "Rider CPU skin world/local divergence")
                    assert(localPoint:Length() < 3, "Rider skin vertex escaped 3m envelope")
                    box:Merge(localPoint)
                end
                assert(box.size.x < 2 and box.size.y < 2.5 and box.size.z < 2.5, "Rider skin exploded")
                if index == 2 then
                    print(string.format("[RiderSkin] %s LOD%d vertices=%d CPU posed bounds=%s",
                        self.vehicleId, lod - 1, #vertices, box:ToString()))
                end
            end
            report.cases = report.cases + 1
        end
        -- 隐藏期间仍记录输入，重新显示立即重建完整pose。
        self:SetVisible(false)
        self:Update(0, false, -50)
        self.parent.rotation = Quaternion(-35, 179, -50)
        self:SetVisible(true)
        self:ValidatePose()
    end)
    self.parent:SetTransform(savedPosition, savedRotation, savedScale)
    self.visible = true
    self:Update(savedSteer, true, savedLean)
    self:SetVisible(savedVisible)
    assert(ok, tostring(err))
    print(string.format("[RiderTransforms] %s PASS cases=%d bones=%d vertices/allLOD=%d matrix=%.6fm skin=%.6fm grip=%.6fm length=%.8fm bind=%.8fm (CPU; GPU requires render capture)",
        self.vehicleId, report.cases, #self.boneNames, report.vertices, report.maxMatrixError,
        report.maxSkinError, report.maxGripError, report.maxBoneLengthError, report.maxBindError))
    return report
end

function Rider:Dispose()
    if self.disposed then return end
    self.disposed = true
    self.node:Dispose()
    self.material:Dispose()
end

return Rider
