-- 生涯车辆局部夜灯；Session在Actor同步外观后调用，不订阅事件、不处理输入或存档。
-- 只保留一盏前灯Spot与一盏近距红色尾灯Point，沿用现有车灯外观，不叠假光束。
-- 前向手游不投影、不参与体积雾；不改Zone、曝光、日月光或渲染管线。
local V=Vector3

---@class CareerNightLampLayout
---@field front Vector3 车辆外观根的局部坐标，米；前向统一为+Z
---@field rear Vector3

-- 挂点沿用ActorVisuals/VehicleAssets归一化后的坐标域。
-- 前灯置于头罩前缘，尾灯置于后壳外侧；不是车长包围盒外的悬空照明。
-- 源MDL的灯罩与车壳共用图集，不给整车材质加自发光，也不动共享材质。
---@type table<string, CareerNightLampLayout>
local layouts={
    borrowed_ebike={front=V(0,1.04,.59),rear=V(0,.77,-.73)},
    sport={front=V(0,.98,.78),rear=V(0,1.05,-.91)},
    cruiser={front=V(0,1.18,.61),rear=V(0,.93,-1.03)},
    rally={front=V(0,1.10,.60),rear=V(0,1.00,-.98)},
    sport_2={front=V(0,1.24,.78),rear=V(0,1.17,-.96)},
    sport_3={front=V(0,1.20,.77),rear=V(0,1.13,-.96)},
    cruiser_2={front=V(-.09,1.34,.69),rear=V(-.09,1.02,-1.08)},
    cruiser_3={front=V(0,1.27,.63),rear=V(0,1.13,-1.04)},
    rally_2={front=V(0,1.23,.62),rear=V(0,1.10,-1.00)},
    rally_3={front=V(0,1.49,.64),rear=V(0,1.28,-.99)},
}

local function clamp(x) return math.max(0,math.min(1,x)) end
local function smooth(a,b,x) local t=clamp((x-a)/(b-a)); return t*t*(3-2*t) end

---@param sample CareerAtmosphereSample?
---@return number
local function lampLevel(sample)
    if not sample then return 0 end
    -- lamps已含太阳高度与阴天贡献；不另造时钟或夜间判定，暂停/读档可复现。
    local dusk=smooth(.04,.82,sample.lamps)
    local overcast=.4*smooth(.72,.94,sample.cloudiness)*(1-smooth(.65,1.2,sample.sunBrightness))
    return math.max(dusk,overcast)
end

---@param node Node
---@param kind LightType
---@param color Color
---@param range number 米
---@return Light
local function makeLight(node,kind,color,range)
    local light=node:CreateComponent("Light")
    light.temporary=true
    light.lightType=kind; light.color=color; light.range=range
    light.brightness=0; light.enabled=false
    light.castShadows=false; light.affectVolumetricFog=false
    light.punctualLight=true
    light.specularIntensity=.35
    -- 引擎视距裁剪作为额外保险；实际步行距离仍由Update决定。
    light.drawDistance=48; light.fadeDistance=32
    return light
end

---@class CareerNightLighting
---@field scene Scene 借用，释放顺序必须早于Scene
---@field root Node
---@field headNode Node
---@field tailNode Node
---@field head Light
---@field tail Light
---@field disposed boolean
---@field level number 当前天气灯光系数，不写回Actor或档案
---@field vehicleId string
---@field loggedOn boolean
local N={}
N.__index=N

---@param scene Scene
---@return CareerNightLighting
function N.New(scene)
    local self=setmetatable({},N)
    self:Init(scene)
    return self
end

---@param scene Scene
function N:Init(scene)
    self.scene=scene
    self.root=scene:CreateChild("生涯车辆夜灯")
    self.root.temporary=true
    self.headNode=self.root:CreateChild("车前灯聚光")
    self.tailNode=self.root:CreateChild("车尾近距红光")
    self.head=makeLight(self.headNode,LIGHT_SPOT,Color(1,.94,.84),18)
    self.head.fov=44; self.head.aspectRatio=1.25
    self.tail=makeLight(self.tailNode,LIGHT_POINT,Color(1,.025,.012),1.8)
    self.tail.specularIntensity=.12
    self.disposed=false; self.level=0; self.vehicleId=""; self.loggedOn=false
    print("[车辆夜灯] 单前灯18米/单尾灯1.8米；无阴影、无体积光，不改全局照明")
end

-- 借用外观的真实世界变换：bikeNode含停车/坡度，bikeVisual再含压弯。
-- actor.node下车后跟人物，不能拿它当车辆朝向，也不调用有地面状态写回的GetPosition。
-- 车灯始终留在真实车辆处：骑行完整照明，步行18..26米渐隐前灯，8..12米渐隐尾灯。
-- 这些只是光照距离预算，不创建/查询碰撞体，不改变车辆动力或停车可达性。
---@param actor CareerActor?
---@param atmosphereSample CareerAtmosphereSample? 传Atmosphere.Apply返回值或同源Sample
---@param indoor? boolean 室内必须传true；同时检查CityVisible，避免住房隐藏车辆后漏光
function N:Update(actor,atmosphereSample,indoor)
    if self.disposed then return end
    self.head.enabled=false; self.tail.enabled=false
    self.head.brightness=0; self.tail.brightness=0; self.level=0
    if indoor or not actor or actor.disposed then return end
    local visuals=actor.visuals
    if not visuals or visuals.disposed or visuals.cityVisible==false then return end
    local vehicle=visuals.bikeVisual --[[@as Node?]]
    if not vehicle or not vehicle:IsEnabled() or vehicle.scene~=self.scene then return end
    local layout=layouts[actor.vehicleId]
    if not layout then return end
    local level=lampLevel(atmosphereSample)
    if level<=.001 then return end

    -- 用三维实距区分天桥上的人物与桥下停车，不把Y差丢掉。
    local delta=actor.node.worldPosition-vehicle.worldPosition
    local distance=delta:Length()
    local frontNear=actor.mounted and 1 or 1-smooth(18,26,distance)
    local rearNear=1-smooth(8,12,distance)
    if frontNear<=.001 and rearNear<=.001 then return end

    self.level=level
    self.headNode.worldPosition=vehicle:LocalToWorld(layout.front)
    -- 相对实际车身向下约5度照路；不随人物/相机转头、不因倒车反转前灯。
    self.headNode.worldDirection=vehicle.worldRotation*V(0,-.087,1):Normalized()
    self.tailNode.worldPosition=vehicle:LocalToWorld(layout.rear)
    -- 固定曝光用小亮度，不套用自动曝光下的3000量级，也不擅自开启曝光。
    self.head.brightness=4*level*frontNear
    self.tail.brightness=.4*level*rearNear
    self.head.enabled=self.head.brightness>.004
    self.tail.enabled=self.tail.brightness>.004
    if self.vehicleId~=actor.vehicleId then
        self.vehicleId=actor.vehicleId
        print("[车辆夜灯] 挂接真实车身："..self.vehicleId.."；下车灯留原地，远离停更照明")
    end
    if not self.loggedOn and self.head.enabled then
        self.loggedOn=true
        print("[车辆夜灯] 夜晚/阴天弱光开启；室内与远处停车禁用局部灯")
    end
end

-- 必须在Scene释放前调用；只释放自建节点，绝不释放借用的车辆或Scene。
-- 未订阅事件，无全局材质缓存；重复调用或释放后Update均无副作用。
function N:Dispose()
    if self.disposed then return end
    self.disposed=true; self.level=0
    self.head.enabled=false; self.tail.enabled=false
    self.root:Dispose()
    print("[车辆夜灯] 前灯与尾灯已释放")
end

return N
