-- 混合竞速目录：器械、生物与轻型载具共用米/秒制仿真，技能均可用于柏油公路。
local M = {}

-- 九辆普通摩托按完整车型ID定义；玩家和AI消费相同规则，不改变位置或检查点。
---@class MotorcycleSkill
---@field id string
---@field name string
---@field description string
---@field visual string
---@field tactic string
---@field cooldown number
---@field duration number
---@field triggerDistance number
---@field speedScale number
---@field driveScale number
---@field gripScale number
---@field offroadScale number
---@field damageScale? number
---@field lossScale? number
---@field chargeTime? number
---@field disruptScale? number
---@field coastDragScale? number
---@field shieldCharges? integer
---@field nitroGift? number
---@field hopDuration? number
---@field hopHeight? number
---@type table<string, MotorcycleSkill>
M.MotorcycleSkills = {
    sport = {id="sport", name="红温了兄弟", description="红温渐进0.35秒后动力×1.25、极速+8%，共2.6秒；只加速不抗撞。",
        visual="pulse", tactic="straight", cooldown=14, duration=2.6, triggerDistance=42,
        speedScale=1.08, driveScale=1.25, gripScale=1, offroadScale=1},
    sport_2 = {id="sport_2", name="弯道不讲武德", description="3秒抓地×1.28；转向时动力×1.18，回正后动力×1.08、极速+4%。",
        visual="crescent", tactic="corner", cooldown=15, duration=3, triggerDistance=32,
        speedScale=1.04, driveScale=1.18, gripScale=1.28, offroadScale=1},
    sport_3 = {id="sport_3", name="起步先弹个射", description="蓄力0.35秒动力×0.78，随后2.65秒动力×1.25、极速+10%；停车也能发动。",
        visual="coil", tactic="charge", cooldown=16, duration=3, triggerDistance=46,
        speedScale=1.10, driveScale=1.25, gripScale=1.03, offroadScale=1, chargeTime=.35},
    rally = {id="rally", name="马路牙子侠", description="主动小跳1.25秒、最高1.35米，可越过低路障；3.2秒动力×1.10，非无敌。",
        visual="tread", tactic="hop", cooldown=14, duration=3.2, triggerDistance=42,
        speedScale=1.03, driveScale=1.10, gripScale=1.08, offroadScale=1, hopDuration=1.25, hopHeight=1.35},
    rally_2 = {id="rally_2", name="已读乱回，稳住别浪", description="清除当前技能/油污失衡；3.2秒新干扰时长×0.35、抓地×1.22、动力×1.16，不免撞伤。",
        visual="level", tactic="stability", cooldown=15, duration=3.2, triggerDistance=28,
        speedScale=1, driveScale=1.16, gripScale=1.22, offroadScale=1, disruptScale=.35},
    rally_3 = {id="rally_3", name="别催，马上到", description="比赛实赠25点氮气（最多100）；3秒动力×1.12、极速+4%，平路照样赶上。",
        visual="climb", tactic="delivery", cooldown=15, duration=3, triggerDistance=36,
        speedScale=1.04, driveScale=1.12, gripScale=1.04, offroadScale=1, nitroGift=25},
    cruiser = {id="cruiser", name="铁骑护航", description="3.2秒撞击伤害×0.60、损速×0.88，抓地×1.10、动力×1.08；不是全免伤。",
        visual="armor", tactic="armor", cooldown=16, duration=3.2, triggerDistance=24,
        speedScale=1.02, driveScale=1.08, gripScale=1.10, offroadScale=1, damageScale=.60, lossScale=.88},
    cruiser_2 = {id="cruiser_2", name="拒绝内耗", description="2.5秒内格挡首次技能、路障或车辆撞击，立刻破盾；不挡护栏回推，无极速加成。",
        visual="guard", tactic="guard", cooldown=18, duration=2.5, triggerDistance=24,
        speedScale=1, driveScale=1, gripScale=1.05, offroadScale=1, shieldCharges=1},
    cruiser_3 = {id="cruiser_3", name="油门焊死", description="3.4秒撞击损速×0.55、收油阻力×0.65，动力×1.10、极速+3%；不免撞伤或护栏减速。",
        visual="flywheel", tactic="momentum", cooldown=17, duration=3.4, triggerDistance=34,
        speedScale=1.03, driveScale=1.10, gripScale=1, offroadScale=1, lossScale=.55, coastDragScale=.65},
}

---@param id string
---@return MotorcycleSkill?
function M.GetMotorcycleSkill(id)
    return type(id)=="string" and M.MotorcycleSkills[id] or nil
end

-- 纯规则入口：九个独立技能，限制持续收益与强度，变体不能再回退到同类技能。
function M.RunSkillRules()
    local count,names,visuals,definitions=0,{},{},{}
    local function check(ok,message)
        assert(ok,"[MixedVehicles.SkillRules] "..message);count=count+1
    end
    for _,id in ipairs({"sport","sport_2","sport_3","rally","rally_2","rally_3","cruiser","cruiser_2","cruiser_3"}) do
        local skill=assert(M.GetMotorcycleSkill(id))
        check(skill.id==id and not definitions[skill],id.."必须有独立定义")
        check(not names[skill.name] and not visuals[skill.visual],id.."名字与空间效果必须唯一")
        check(skill.cooldown>=14 and skill.duration/skill.cooldown<=.26,id.."持续收益必须有限")
        check(skill.triggerDistance>=20 and skill.triggerDistance<=50,id.."触发距离必须有限")
        check(skill.speedScale<=1.10 and skill.driveScale<=1.25,id.."动力倍率不得超标")
        check(skill.gripScale<=1.30 and skill.offroadScale<=1.20,id.."抓地倍率必须有限")
        check((skill.shieldCharges or 0)<=1 and (skill.damageScale or 1)>=.60,id.."防御不能变成持续无敌")
        names[skill.name],visuals[skill.visual],definitions[skill]=true,true,true
    end
    check(M.GetMotorcycleSkill("sport_4")==nil and M.GetMotorcycleSkill("sport_fake")==nil,"未知车型不能继承普通技能")
    local ebike,helicopter=assert(M.Get("ebike")),assert(M.Get("helicopter"))
    check(ebike.top<=225 and helicopter.top<=215,"电动车与直升机基础极速必须低于混合竞速上限")
    check(helicopter.armor<55,"直升机不能用高护甲伪造无敌")
    return {passed=true,assertions=count}
end

M.List = {
    {id="ebike", name="疾风电动车", class="rally", price=0, top=218, accel=1.08, grip=1.12, armor=48, rough=.84,
        skill="电驱超频", passive="轻巧易控，基础抓地×1.12", active="电驱爆发4秒：动力×1.7、极速上限+18%，比赛补充15点氮气（最多100）", weakness="护甲48，车辆侧撞会额外损速与偏航", cooldown=12, duration=4, size={1.060,1.601,2.1}},
    {id="tank", name="轻型突击坦克", class="cruiser", price=16000, top=214, accel=.91, grip=.72, armor=94, rough=1,
        skill="助推喷射", passive="碎石烂路不掉速，正面撞翻障碍；直道长按方向键以外时额外提速8%", active="助推喷射4秒：动力×1.7、极速上限+18%", weakness="急弯转向笨重，侧面受击更易失衡", cooldown=15, duration=4, size={2.181,1.736,3.4}},
    {id="beetle", name="蒸汽锹甲", class="rally", price=16000, top=238, accel=.82, grip=.94, armor=76, rough=.95,
        skill="巨颚猛夹", passive="持续奔跑积蓄蒸汽，满层极速提升18%；高速撞碎小障碍", active="双钳张开前伸、闭合、夹持再抛开：钳口贴近对手表面0.3米内命中，减速20%并翻卷", weakness="起步略慢，撞墙或重击会清空蒸汽", cooldown=11, duration=1.5, size={3.2,2.028,3.2}},
    {id="hovercraft", name="旱地气垫艇", class="rally", price=7200, top=229, accel=.97, grip=.9, armor=70, rough=1,
        skill="侧喷借过", passive="悬浮底盘高0.2米，免油污；柏油上转向略侧滑", active="按方向侧喷2.5秒，横移2.3米/秒；无转向时朝赛道中心一侧闪避，不免实体碰撞", weakness="基础抓地×0.9且侧喷不自动刹停，贴边需预留5.75米横移空间", cooldown=10, duration=2.5, size={2.2,1.6,3.1}},
    {id="centipede", name="齿轮蜈蚣", class="cruiser", price=8800, top=232, accel=.98, grip=.76, armor=85, rough=1,
        skill="铁尾别贴贴", passive="4.1米长车身占位，护甲85耐撞", active="先蓄力0.42秒，再扫6米内侧后方对手；命中减速20%、失衡3秒并断氮气，不打正前方或高空", weakness="基础抓地×0.76，急弯和窄路调整较慢", cooldown=13, duration=2, size={1.85,1.3,4.1}},
    {id="buggy", name="越野蹦蹦", class="rally", price=9800, top=244, accel=1.04, grip=1.23, armor=44, rough=.98,
        skill="蹦迪不等跳台", passive="稳定落地叠极速+3.5%，最多3层，6秒未续落地清空", active="原地主动跃起1.6秒、最高2米；稳定着地后2.2秒动力×1.35、极速+6%、抓地×1.15，不依赖跳台", weakness="护甲44，起落时仍会撞低障碍；大幅转向或失衡落地无加速", cooldown=10, duration=3, size={1.75,1.65,2.8}},
    {id="jellyfish", name="水母浮囊", class="rally", price=11000, top=226, accel=.98, grip=1.04, armor=58, rough=1,
        skill="水球已读乱回", passive="底盘悬浮1.65米，越过1米低障碍并免油污", active="向前方28米内对手直射水球，命中减速20%、失衡3秒并断氮气；无目标不消耗", weakness="水球不追踪，变道和高度差能躲开；仍会撞到高障碍", cooldown=12, duration=2, size={2.1,2.7,2.7}},
    {id="loader", name="轮式铲车", class="cruiser", price=6800, top=208, accel=1.03, grip=.86, armor=91, rough=.98,
        skill="前方请让一铲", passive="压碎可破路障，正面推挤保留98%速度，护甲91", active="0.36秒抬斗关键帧挑前方12米、侧宽3.1米内一名对手；减速20%、失衡3秒并弹起", weakness="极速208km/h；撞击恢复期动力再×0.75，空铲仍消耗冷却", cooldown=12, duration=1.8, size={2.05,2.1,3.3}},
    {id="cicada", name="发条木蝉", class="sport", price=9200, top=236, accel=1.02, grip=1.16, armor=60, rough=.87,
        skill="打工续一秒", passive="22秒发条储量；有弦极速+14%，耗尽极速×0.82", active="用1秒有限速率补满发条，上弦期间动力×0.65；不瞬间灌满，也不额外叠加14%", weakness="上弦减动力，有弦仍逐秒消耗；提前选择安全直道续弦", cooldown=13, duration=1, size={1.7,1.5,2.8}},
    {id="jetboat", name="旱地喷气快艇", class="sport", price=10500, top=250, accel=.96, grip=1.05, armor=64, rough=.84,
        skill="尾喷拒绝内卷", passive="下坡坡度低于-1.5%时极速+18%；不是永久保速", active="平路也能强喷4秒：动力×1.7、极速上限+18%", weakness="上坡超过2.5%动力×0.72，低于29km/h再×0.82，喷流不免撞", cooldown=14, duration=4, size={1.6,1.25,3.2}},
    {id="frog", name="棘刺弹跳蛙", class="rally", price=5400, top=220, accel=1.08, grip=1.08, armor=63, rough=.98,
        skill="蛙先走一步", passive="超过29km/h自动0.65米小跳；稳定落地连击极速+3.5%，最多3层持续5秒", active="主动大跳2.4秒、最高2.2米，越过低障碍；空中抓地×0.78，可有限微调", weakness="小跳不能保证避开1米路障；落地满舵超过0.8损速13%并失衡0.6秒", cooldown=11, duration=2.5, size={2,1.65,2.7}},
    {id="skateboard", name="街头滑板", class="rally", price=2400, top=215, accel=1.10, grip=1.25, armor=35, rough=.78,
        skill="豚跳这波很秀", passive="基础抓地×1.25，轻巧但护甲仅35", active="主动豚跳1.5秒、最高2.2米；回正稳定落地加1.4米/秒，连击极速+3.5%最多3层持续5秒", weakness="落地满舵超过0.8损速13%并失衡0.6秒；不免车辆撞伤", cooldown=8, duration=2, size={.85,1.85,1.6}},
    -- 直升机是最贵载具但不该超标：极速与护甲都低于同价位赛车，
    -- 靠"避开地面障碍"换来容错，而不是速度碾压。
    {id="helicopter", name="武装直升机", class="sport", price=20000, top=210, accel=.88, grip=.84, armor=46, rough=1,
        skill="空战脉冲", passive="沿赛道低空飞行，避开低矮路障和油污", active="锁定前方300米内最近对手并发射追踪导弹，命中减速20%", weakness="强风与高空悬锤仍有威胁，过弯半径较大、极速偏低", cooldown=18, duration=2, size={3.226,2.062,3.5}},
    {id="sled", name="极地雪橇", class="rally", price=7800, top=241, accel=1.0, grip=1.07, armor=62, rough=.86,
        skill="柏油也能出溜", passive="基础抓地×1.07，极速241km/h，不依赖冰面", active="4秒滑刃强推：动力×1.7、极速上限+18%，柏油同样生效", weakness="护甲62，冲刺不免撞也不自动回正，急弯应提前收油", cooldown=12, duration=4, size={1.4,1.3,2.7}},
    {id="cart", name="暴走购物车", class="rally", price=3800, top=218, accel=1.11, grip=1.05, armor=43, rough=.83,
        skill="全场我买单", passive="轻快起步，基础动力×1.11，转向灵活", active="4秒冲动采购：动力×1.7、极速上限+18%，撞到对手就把他顶开减速", weakness="护甲43，车辆侧撞额外损速偏航", cooldown=11, duration=4, size={1.15,1.7,1.8}},
    {id="bathtub", name="泡泡澡盆", class="cruiser", price=5800, top=212, accel=1.0, grip=.98, armor=82, rough=.94,
        skill="泡泡加速", passive="护甲82，承伤较低；长2.5米的稳定澡盆底盘", active="5秒泡泡推进：动力×1.65、极速上限+16%，同时生成泡泡护盾挡技能与路障", weakness="护盾不挡护栏和车辆接触，加速结束后立即恢复路障碰撞", cooldown=15, duration=5, size={1.3,1.55,2.5}},
    {id="office", name="旋风办公椅", class="rally", price=4600, top=222, accel=1.05, grip=1.2, armor=42, rough=.8,
        skill="工位弹射", passive="基础抓地×1.2，护甲42，轻巧易变线", active="转椅弹射3秒：动力×1.7、极速上限+16%，弹开周围6米对手并自身获得护盾", weakness="护盾不挡护栏或车辆碰撞，弹射期间抓地略降", cooldown=10, duration=3, size={1.1,1.9,1.5}},
    {id="toilet", name="火箭马桶", class="sport", price=8600, top=246, accel=1.06, grip=.94, armor=52, rough=.82,
        skill="一键冲上热搜", passive="极速246km/h，动力×1.06的轻量火箭底盘", active="点火前冲4秒：底盘抬高1.8米，动力×1.7、极速上限+18%，可越过低障碍", weakness="爆发期间抓地再×0.72，仍撞高障碍和护栏；停喷时注意低障碍", cooldown=15, duration=4, size={1.2,1.7,1.9}},
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
for _, v in ipairs(M.List) do
    local asset=require("MixedAssets").Vehicles[v.id]
    if asset and asset.class=="mixed" then
        v.size={asset.targetSize.x,asset.targetSize.y,asset.targetSize.z}
    end
    byId[v.id] = v
end
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
