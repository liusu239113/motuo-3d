-- 混合竞速目录：器械、生物与轻型载具共用米/秒制仿真，各有地形赢法。
local M = {}

-- 普通摩托的专属技能规则由竞速 AI 和玩家共用同一份定义。
-- 技能只改变有限的动力/抓地包络，不能修改位置、检查点或碰撞判定。
---@class MotorcycleSkill
---@field id string
---@field name string
---@field description string
---@field cooldown number
---@field duration number
---@field triggerDistance number
---@field speedScale number
---@field driveScale number
---@field gripScale number
---@field offroadScale number
M.MotorcycleSkills = {
    sport = {id="sport", name="超车脉冲", description="动力×1.22、极速+8%、抓地+6%，持续2.4秒。",
        cooldown=14, duration=2.4, triggerDistance=42, speedScale=1.08, driveScale=1.22,
        gripScale=1.06, offroadScale=1},
    cruiser = {id="cruiser", name="稳压护航", description="动力×1.14、抓地×1.28，撞击伤害×0.72、保留更多速度，持续2.8秒。",
        cooldown=16, duration=2.8, triggerDistance=24, speedScale=1.04, driveScale=1.14,
        gripScale=1.28, offroadScale=1.05},
    rally = {id="rally", name="地形冲线", description="动力×1.12、抓地×1.18、越野抓地×1.16，极速+7%，持续3.2秒。",
        cooldown=13, duration=3.2, triggerDistance=30, speedScale=1.07, driveScale=1.12,
        gripScale=1.18, offroadScale=1.16},
}

---@param id string
---@return MotorcycleSkill?
function M.GetMotorcycleSkill(id)
    local class = type(id) == "string" and (id:match("^(sport)") or id:match("^(cruiser)") or id:match("^(rally)")) or nil
    return class and M.MotorcycleSkills[class] or nil
end

-- 纯规则入口：供无场景验收检查定义完整性和公平边界。
function M.RunSkillRules()
    local count = 0
    local function check(ok, message)
        assert(ok, "[MixedVehicles.SkillRules] " .. message)
        count = count + 1
    end
    for _, class in ipairs({"sport", "cruiser", "rally"}) do
        local skill = assert(M.MotorcycleSkills[class])
        check(skill.cooldown > skill.duration, class .. "技能冷却必须覆盖技能持续时间")
        check(skill.triggerDistance >= 20 and skill.triggerDistance <= 50, class .. "技能触发距离必须有限")
        check(skill.speedScale <= 1.10 and skill.driveScale <= 1.25, class .. "技能倍率不得造成超速")
        check(skill.gripScale <= 1.30 and skill.offroadScale <= 1.20, class .. "技能抓地倍率必须有限")
        check(M.GetMotorcycleSkill(class .. "_2") == skill, class .. "变体必须复用同类技能")
    end
    local ebike, helicopter = assert(M.Get("ebike")), assert(M.Get("helicopter"))
    check(ebike.top <= 225 and helicopter.top <= 215, "电动车与直升机基础极速必须低于混合竞速上限")
    check(helicopter.armor < 55, "直升机不能用高护甲伪造无敌")
    return {passed = true, assertions = count}
end

M.List = {
    {id="ebike", name="疾风电动车", class="rally", price=0, top=218, accel=1.08, grip=1.12, armor=48, rough=.84,
        skill="电驱超频", passive="轻巧易控，出弯加速快", active="电驱爆发4秒：动力×1.7、极速上限+18%，并补充15点氮气", weakness="车轻，受到侧撞更容易偏航", cooldown=12, duration=4, size={1.060,1.601,2.1}},
    {id="tank", name="轻型突击坦克", class="cruiser", price=16000, top=214, accel=.91, grip=.72, armor=94, rough=1,
        skill="助推喷射", passive="碎石烂路不掉速，正面撞翻障碍；直道长按方向键以外时额外提速8%", active="助推喷射4秒：动力×1.7、极速上限+18%", weakness="急弯转向笨重，侧面受击更易失衡", cooldown=15, duration=4, size={2.181,1.736,3.4}},
    {id="beetle", name="蒸汽锹甲", class="rally", price=16000, top=238, accel=.82, grip=.94, armor=76, rough=.95,
        skill="巨颚猛夹", passive="持续奔跑积蓄蒸汽，满层极速提升18%；高速撞碎小障碍", active="双钳张开前伸、闭合、夹持再抛开：钳口贴近对手表面0.3米内命中，减速20%并翻卷", weakness="起步略慢，撞墙或重击会清空蒸汽", cooldown=11, duration=1.5, size={3.2,2.028,3.2}},
    {id="hovercraft", name="旱地气垫艇", class="rally", price=7200, top=229, accel=.97, grip=.9, armor=70, rough=1,
        skill="侧向喷气", passive="泥潭、水面、粘液不减速，地面陷阱无效", active="沿当前转向侧移；未转向时向空旷侧闪避", weakness="硬地有轻微侧滑，强风区更易偏移", cooldown=10, duration=2.5, size={2.2,1.6,3.1}},
    {id="centipede", name="齿轮蜈蚣", class="cruiser", price=8800, top=232, accel=.98, grip=.76, armor=85, rough=1,
        skill="铁尾横扫", passive="碎石路抓地稳定，长车身拥有更宽的卡位范围", active="横扫6米内两侧对手，打断其冲刺", weakness="转弯半径大，窄路调整困难", cooldown=13, duration=2, size={1.85,1.3,4.1}},
    {id="buggy", name="越野蹦蹦", class="rally", price=9800, top=244, accel=1.04, grip=1.23, armor=44, rough=.98,
        skill="甩尾冲刺", passive="跳台落地叠加短时提速，最多3层", active="动力×1.4、抓地×1.4，持续3秒", weakness="车身轻，重型载具碰撞会造成更大侧偏", cooldown=10, duration=3, size={1.75,1.65,2.8}},
    {id="jellyfish", name="水母浮囊", class="rally", price=11000, top=226, accel=.98, grip=1.04, armor=58, rough=1,
        skill="水球干扰", passive="低空悬浮避开地面陷阱，涉水区提速", active="向前方28米内对手发射直射水球，命中减速20%并干扰转向3秒", weakness="沙漠干燥路段速度降低12%，风区需修正方向", cooldown=12, duration=2, size={2.1,2.7,2.7}},
    {id="loader", name="轮式铲车", class="cruiser", price=6800, top=208, accel=1.03, grip=.86, armor=91, rough=.98,
        skill="铲斗挑飞", passive="前铲破障；正面推挤不被轻型载具拖慢", active="挑起前方12米内的对手并使其弹起，打断其路线", weakness="极速偏低，飞坡落地不稳时恢复更慢", cooldown=12, duration=1.8, size={2.05,2.1,3.3}},
    {id="cicada", name="发条木蝉", class="sport", price=9200, top=236, accel=1.02, grip=1.16, armor=60, rough=.87,
        skill="快速上弦", passive="发条充足时极速提升14%，匀速抓地稳定", active="立即补满发条；上弦1秒内动力×0.65、极速上限+18%", weakness="发条耗尽速度降低18%；需规划上弦时机", cooldown=13, duration=1, size={1.7,1.5,2.8}},
    {id="jetboat", name="旱地喷气快艇", class="sport", price=10500, top=250, accel=.96, grip=1.05, armor=64, rough=.84,
        skill="尾流强喷", passive="下坡滑行极速提升18%，坡底保持动量", active="强力喷流4秒：动力×1.7、极速上限+18%", weakness="上坡动力降低，低速重启略慢", cooldown=14, duration=4, size={1.6,1.25,3.2}},
    {id="frog", name="棘刺弹跳蛙", class="rally", price=5400, top=220, accel=1.08, grip=1.08, armor=63, rough=.98,
        skill="远距蛙跳", passive="自动连续小跳避开低陷阱，落地维持弹跳连击", active="长距跳跃，可在空中微调方向", weakness="平路直道优势有限，急弯起跳会走宽", cooldown=11, duration=2.5, size={2,1.65,2.7}},
    {id="skateboard", name="街头滑板", class="rally", price=2400, top=215, accel=1.10, grip=1.25, armor=35, rough=.78,
        skill="腾空豚跳", passive="轻巧转向，过弯损速少", active="跳过低障碍，落地若未大幅转向则叠加短时提速（最多3层）", weakness="怕重型碰撞与连续碎石", cooldown=8, duration=2, size={.85,1.85,1.6}},
    -- 直升机是最贵载具但不该超标：极速与护甲都低于同价位赛车，
    -- 靠"避开地面障碍"换来容错，而不是速度碾压。
    {id="helicopter", name="武装直升机", class="sport", price=20000, top=210, accel=.88, grip=.84, armor=46, rough=1,
        skill="空战脉冲", passive="沿赛道低空飞行，避开低矮路障和油污", active="锁定前方300米内最近对手并发射追踪导弹，命中减速20%", weakness="强风与高空悬锤仍有威胁，过弯半径较大、极速偏低", cooldown=18, duration=2, size={3.226,2.062,3.5}},
    {id="sled", name="极地雪橇", class="rally", price=7800, top=241, accel=1.0, grip=1.07, armor=62, rough=.86,
        skill="冰刃冲刺", passive="冰面速度+17%、抓地提升；湿滑地带不掉速", active="动力×1.7、极速上限+18%，冰面额外稳向", weakness="干燥碎石地带加速稍弱", cooldown=12, duration=4, size={1.4,1.3,2.7}},
    {id="cart", name="暴走购物车", class="rally", price=3800, top=218, accel=1.11, grip=1.05, armor=43, rough=.83,
        skill="金币磁场", passive="金币不影响名次判定", active="能量吸取：动力×1.35、极速+10%，拾币范围扩大到14米", weakness="轻且易侧滑，碎石地段需控速", cooldown=12, duration=4, size={1.15,1.7,1.8}},
    {id="bathtub", name="泡泡澡盆", class="cruiser", price=5800, top=212, accel=1.0, grip=.98, armor=82, rough=.94,
        skill="泡泡护盾", passive="水面/泥地只提速不掉速，泡体抗冲击", active="护盾持续5秒：免路障伤害、挡对手技能，水面速度+7%", weakness="急弯笨重，护盾结束需注意避障", cooldown=16, duration=5, size={1.3,1.55,2.5}},
    {id="office", name="旋风办公椅", class="rally", price=4600, top=222, accel=1.05, grip=1.2, armor=42, rough=.8,
        skill="旋风转椅", passive="平路灵活，急弯恢复快", active="旋转弹开6米内邻近对手，并获得3秒护盾挡技能", weakness="碎石上速度降低，抗重击弱", cooldown=11, duration=3, size={1.1,1.9,1.5}},
    {id="toilet", name="火箭马桶", class="sport", price=8600, top=246, accel=1.06, grip=.94, armor=52, rough=.82,
        skill="火箭升空", passive="轻量火箭底盘，直道爆发强", active="升空并前冲4秒：动力×1.7、极速上限+18%，可飞越低障碍", weakness="爆发期转向较弱，落地需要留出空间", cooldown=15, duration=4, size={1.2,1.7,1.9}},
}
---@class MixedVehicle
---@field id string
---@field name string
---@field class string
---@field price integer
---@field top number
---@field accel number
---@field grip number
---@field armor number
---@field rough number
---@field skill string
---@field passive string
---@field active string
---@field weakness string
---@field cooldown number
---@field duration number
---@field size number[]
---@type table<string, MixedVehicle>
local byId = {}
for _, v in ipairs(M.List) do byId[v.id] = v end
function M.Get(id) return byId[id] end
function M.Ids()
    local ids = {}
    for _, v in ipairs(M.List) do ids[#ids+1] = v.id end
    return ids
end
function M.CatalogEntries()
    local entries = {}
    for _, v in ipairs(M.List) do
        entries[#entries+1] = {id=v.id, class=v.class, baseClass=v.class, name=v.name, tag="混合竞速 / "..v.skill,
            description="被动："..v.passive.."。主动："..v.active.."。短板："..v.weakness.."。",
            speed=v.top, speedStat=v.top, acceleration=math.floor(v.accel*85), handling=math.floor(v.grip*75),
            accelStat=v.accel, durability=v.armor, offroadStat=v.rough, handlingStat=v.grip,
            available=require("MixedAssets").IsReady(v.id), price=v.price, odd=true, skillName=v.skill, skillDescription=v.active,
            passiveDescription=v.passive, weakness=v.weakness, skillCooldown=v.cooldown, skillDuration=v.duration}
    end
    return entries
end
return M
