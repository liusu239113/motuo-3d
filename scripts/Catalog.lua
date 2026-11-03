-- 车型目录与实车资产分离；available 只在真实 MDL 交付并登记后开放。
local Catalog = {}
---@class MotorcycleEntry
---@field odd? boolean
---@field baseClass? string
---@field skillName? string
---@field passiveDescription? string
---@field skillDescription? string
---@field weakness? string
---@field skillCooldown? number
---@field skillDuration? number
---@field id string
---@field class string
---@field name string
---@field tag string
---@field description string
---@field speed number 极速参考，km/h
---@field acceleration number 动力响应评分，0..100
---@field handling number 操控评分，0..100
---@field available boolean
---@field price integer 金币售价，0为默认免费
---@field speedStat number 极速实值 km/h（进入仿真倍率）
---@field accelStat number 加速实值倍率
---@field durability number 耐久 0..100，影响碰撞掉速与车况恢复
---@field offroadStat number 越野通过性 0..1
---@field handlingStat number 操控 0..1，影响转向与过弯
---@field preview? string
---@type MotorcycleEntry[]
Catalog.List = {
    {id="sport", class="sport", name="赤焰 R1000", tag="仿赛 / 直四高转", description="全包围整流罩与敏捷压弯，直线极速优先。", speed=274, acceleration=94, handling=88, available=true, price=0, speedStat=274, accelStat=1.00, durability=58, offroadStat=0.58, handlingStat=1.00},
    {id="sport_2", class="sport", name="冰锋 RR", tag="仿赛 / 白蓝旗舰", description="独立白蓝超级仿赛车体，尖锐双灯与流线短尾。", speed=274, acceleration=94, handling=88, available=true, price=4200, speedStat=279, accelStat=1.02, durability=60, offroadStat=0.58, handlingStat=1.01, preview="image/vehicle_reviews/sport_2_left.png"},
    {id="sport_3", class="sport", name="银隼 750", tag="仿赛 / 银黄轻量", description="独立银黄中量仿赛车体，单目车灯与鲨鱼鳃侧罩。", speed=274, acceleration=94, handling=88, available=true, price=5600, speedStat=283, accelStat=1.03, durability=62, offroadStat=0.60, handlingStat=1.02, preview="image/vehicle_reviews/sport_3_left.png"},
    {id="cruiser", class="cruiser", name="远行 V1700", tag="巡航 / 低座宽把", description="长轴距、低坐姿与厚重双缸声浪，稳健出弯。", speed=205, acceleration=76, handling=70, available=true, price=3600, speedStat=205, accelStat=0.80, durability=80, offroadStat=0.64, handlingStat=0.78},
    {id="cruiser_2", class="cruiser", name="赤铜 Classic", tag="巡航 / 经典镀铬", description="独立酒红水滴油箱、镀铬 V 双缸与复古长排气。", speed=205, acceleration=76, handling=70, available=true, price=6800, speedStat=209, accelStat=0.82, durability=84, offroadStat=0.64, handlingStat=0.79, preview="image/vehicle_reviews/cruiser_2_left.png"},
    {id="cruiser_3", class="cruiser", name="暗峰 Muscle", tag="巡航 / 肌肉短尾", description="独立墨绿肌肉巡航，宽后胎与枪灰裸露发动机。", speed=205, acceleration=76, handling=70, available=true, price=7600, speedStat=214, accelStat=0.84, durability=88, offroadStat=0.66, handlingStat=0.80, preview="image/vehicle_reviews/cruiser_3_left.png"},
    {id="rally", class="rally", name="荒野 Enduro", tag="拉力 / 全地形", description="高车身与长行程设定，路肩和弯道容错更高。", speed=234, acceleration=86, handling=94, available=true, price=5200, speedStat=234, accelStat=0.92, durability=74, offroadStat=0.92, handlingStat=1.12},
    {id="rally_2", class="rally", name="雪脊 Trail", tag="拉力 / 轻越野", description="独立灰白轻越野车体，细长高挡泥板与粗纹轮胎。", speed=234, acceleration=86, handling=94, available=true, price=8800, speedStat=240, accelStat=0.95, durability=78, offroadStat=0.95, handlingStat=1.14},
    {id="rally_3", class="rally", name="沙隼 Dakar", tag="拉力 / 沙漠竞技", description="独立沙黄深蓝拉力车体，直立头罩与高位短排气。", speed=234, acceleration=86, handling=94, available=true, price=11000, speedStat=247, accelStat=0.97, durability=82, offroadStat=0.97, handlingStat=1.15, preview="image/vehicle_reviews/rally_3_left.png"},
}
for _, entry in ipairs(require("MixedVehicles").CatalogEntries()) do Catalog.List[#Catalog.List+1]=entry end
---@param id string
---@return MotorcycleEntry?
function Catalog.Get(id)
    for _, entry in ipairs(Catalog.List) do
        if entry.id == id then return entry end
    end
    return nil
end
---@return MotorcycleEntry[]
function Catalog.ForClass(classId)
    local list = {}
    for _, entry in ipairs(Catalog.List) do
        if entry.class == classId then list[#list + 1] = entry end
    end
    return list
end
---@return string[]
function Catalog.AvailableIds()
    local ids = {}
    for _, entry in ipairs(Catalog.List) do
        if entry.available then ids[#ids + 1] = entry.id end
    end
    return ids
end
return Catalog
