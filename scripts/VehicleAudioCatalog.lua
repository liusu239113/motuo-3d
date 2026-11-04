-- 27辆车的真实行驶素材；只描述声音，不改技能规则或视觉。
-- 资源根是assets/，调用方必须用Sound类型预载。保护车型的技能仍由原系统负责。
---@class VehicleAudioEntry
---@field drive string
---@field class string
---@field motion string
---@field skill string?
---@field skillGain number
---@field skillPitch number
---@field skillDuration number
---@field skillOwner string
---@class VehicleAudioCatalog
---@field Vehicles table<string, VehicleAudioEntry>
---@field Ids string[]
---@field Resources string[]
---@field ResourceTypes table<string, string>
---@field Looped table<string, boolean>
---@field GetResources fun(id?: string): string[]
---@type VehicleAudioCatalog
local C = {Vehicles = {}, Ids = {}, Resources = {}, ResourceTypes = {}, Looped = {}}
local function path(name) return "audio/sfx/" .. name .. ".mp3" end
local function add(id, drive, class, motion, skill, gain, pitch, duration, owner)
    C.Ids[#C.Ids + 1] = id
    C.Vehicles[id] = {drive = path(drive), class = class, motion = motion,
        skill = skill and path(skill) or nil, skillGain = gain or .40,
        skillPitch = pitch or 1, skillDuration = duration or 1.2, skillOwner = owner or "RideAudio"}
    C.Looped[path(drive)] = true
end
-- 九辆摩托和电动车保留已有合适录音，其余20辆复用本轮已落盘素材。
add("sport", "race_engine_sport_inline4", "sport", "motor", "race_nitro_burst")
add("sport_2", "vehicle_sport_2_drive", "sport", "motor", "motorcycle_pass", .36, 1.10)
add("sport_3", "vehicle_sport_3_drive", "sport", "motor", "race_start_green", .40, .92)
add("cruiser", "race_engine_cruiser_vtwin", "cruiser", "motor", "race_contact_metal", .32, .72, .7)
add("cruiser_2", "vehicle_cruiser_2_drive", "cruiser", "motor", "race_countdown_beep", .34, .82, .7)
add("cruiser_3", "vehicle_cruiser_3_drive", "cruiser", "motor", "career_impatient_horn", .32, .80, .9)
add("rally", "race_engine_rally_twin", "rally", "motor", "motorcycle_impact", .30, .90, .65)
add("rally_2", "vehicle_rally_2_drive", "rally", "motor", "career_ui_tap", .40, 1, .65)
add("rally_3", "vehicle_rally_3_drive", "rally", "motor", "career_order_chime", .36, 1.08)
add("ebike", "career_ebike_motor", "electric", "electric", "career_ebike_motor", .36, 1.45, .85)
-- 三辆保护车型不注册新技能声、不监听武器事件；RaceAudio及旧表现保持原样。
add("tank", "vehicle_tank_drive", "heavy", "motor", nil, nil, nil, nil, "existing")
add("helicopter", "vehicle_helicopter_drive", "turbine", "air", nil, nil, nil, nil, "existing")
add("beetle", "vehicle_beetle_drive", "heavy", "organic", nil, nil, nil, nil, "existing")
add("hovercraft", "vehicle_hovercraft_drive", "turbine", "air", "highway_wind_loop", .40, 1.4, .65)
add("centipede", "vehicle_centipede_drive", "heavy", "organic", "race_contact_metal", .40, .85, .9)
add("buggy", "vehicle_buggy_drive", "rally", "motor", "motorcycle_brake_loop", .32, 1.12, .9)
-- 水球发射已由RaceAudio.weapon-fire负责，禁止在激活时再叠一次launch。
add("jellyfish", "vehicle_jellyfish_drive", "turbine", "organic", nil, nil, nil, nil, "RaceAudio")
add("loader", "vehicle_loader_drive", "heavy", "motor", "race_contact_metal", .36, .62, .85)
add("cicada", "vehicle_cicada_drive", "rally", "organic", "vehicle_cicada_skill", .42, 1, 1.2)
add("jetboat", "vehicle_jetboat_drive", "turbine", "air", "race_nitro_burst", .42, .84, 1.2)
add("frog", "vehicle_frog_drive", "rally", "organic", "vehicle_frog_skill", .44, 1, 1.3)
add("skateboard", "vehicle_skateboard_drive", "rally", "rolling", "motorcycle_impact", .30, 1.4, .5)
add("sled", "vehicle_sled_drive", "sport", "rolling", "highway_wind_loop", .38, .85, .85)
add("cart", "vehicle_cart_drive", "rally", "rolling", "career_order_chime", .40, 1.30, 1)
-- 只有这三种行驶声与四种无合适替代的技能声需要本轮单批补齐。
add("bathtub", "vehicle_bathtub_drive", "cruiser", "rolling", "vehicle_bathtub_skill", .42, 1, 1.5)
add("office", "vehicle_office_drive", "sport", "rolling", "vehicle_office_skill", .40, 1, 1.3)
add("toilet", "vehicle_toilet_drive", "turbine", "air", "race_weapon_launch", .40, 1.12, 1.1)
-- 共用的循环Sound不改成单次；技能独立source用有限包络停止，绝不污染原通道。
C.Looped[path("highway_wind_loop")] = true
C.Looped[path("motorcycle_brake_loop")] = true
local function resource(p)
    if p and not C.ResourceTypes[p] then
        C.Resources[#C.Resources + 1] = p
        C.ResourceTypes[p] = "Sound"
    end
end
for _, id in ipairs(C.Ids) do
    local v = C.Vehicles[id]
    resource(v.drive); resource(v.skill)
end
---@param id? string
---@return string[]
function C.GetResources(id)
    if id then
        local v = C.Vehicles[id]
        if not v then return {} end
        return v.skill and v.skill ~= v.drive and {v.drive, v.skill} or {v.drive}
    end
    local result = {}
    for _, p in ipairs(C.Resources) do result[#result + 1] = p end
    return result
end
return C
