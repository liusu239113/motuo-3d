-- 仅用于显示：不改目录原文、仿真状态、技能效果或冷却。
-- 名称严格少于四个汉字；完整效果说明由调用方照常展示，禁止截断说明。
local M = {}
---@class VehicleSkillNames
---@field active string
---@field passive string
---@field original string
---@type table<string, VehicleSkillNames>
local names = {
    sport      = {active="红温",   passive="高转",   original="红温了兄弟"},
    sport_2    = {active="压弯",   passive="锋刃",   original="弯道不讲武德"},
    sport_3    = {active="弹射",   passive="轻量",   original="起步先弹个射"},
    rally      = {active="跃障",   passive="全地形", original="马路牙子侠"},
    rally_2    = {active="稳舵",   passive="轻越野", original="已读乱回，稳住别浪"},
    rally_3    = {active="补氮",   passive="沙驰",   original="别催，马上到"},
    cruiser    = {active="护航",   passive="稳骑",   original="铁骑护航"},
    cruiser_2  = {active="格挡",   passive="耐撞",   original="拒绝内耗"},
    cruiser_3  = {active="焊油门", passive="重装",   original="油门焊死"},
    ebike      = {active="超频",   passive="轻控",   original="电驱超频"},
    tank       = {active="助推",   passive="履带",   original="助推喷射"},
    beetle     = {active="猛夹",   passive="蓄汽",   original="巨颚猛夹"},
    hovercraft = {active="侧喷",   passive="气垫",   original="侧喷借过"},
    centipede  = {active="扫尾",   passive="长躯",   original="铁尾别贴贴"},
    buggy      = {active="蹦跳",   passive="稳落",   original="蹦迪不等跳台"},
    jellyfish  = {active="水球",   passive="浮空",   original="水球已读乱回"},
    loader     = {active="挑铲",   passive="推障",   original="前方请让一铲"},
    cicada     = {active="上弦",   passive="发条",   original="打工续一秒"},
    jetboat    = {active="尾喷",   passive="顺坡",   original="尾喷拒绝内卷"},
    frog       = {active="蛙跃",   passive="连跳",   original="蛙先走一步"},
    skateboard = {active="豚跳",   passive="板控",   original="豚跳这波很秀"},
    helicopter = {active="空袭",   passive="低飞",   original="空战脉冲"},
    sled       = {active="滑冲",   passive="滑刃",   original="柏油也能出溜"},
    cart       = {active="买单",   passive="拾币",   original="全场我买单"},
    bathtub    = {active="泡泡盾", passive="厚壁",   original="泡澡别打扰"},
    office     = {active="旋椅",   passive="灵巧",   original="工位禁止贴贴"},
    toilet     = {active="冲天",   passive="火箭",   original="一键冲上热搜"},
}

local function assertShort(value)
    local length = utf8.len(value)
    assert(length and length > 0 and length <= 3, "[SkillNames] 名称须为有效UTF-8且最多3字："..value)
    for _, code in utf8.codes(value) do
        assert(code >= 0x4E00 and code <= 0x9FFF, "[SkillNames] 短名只使用汉字："..value)
    end
end
---@type table<string, string>
local shortByOriginal = {}
for _, entry in pairs(names) do
    assertShort(entry.active)
    assertShort(entry.passive)
    shortByOriginal[entry.original] = entry.active
end

---@param id string
---@return string
function M.Active(id)
    local entry = names[id]
    return entry and entry.active or "技能"
end

---@param id string
---@return string
function M.Passive(id)
    local entry = names[id]
    return entry and entry.passive or "特性"
end

-- 只对完整原技能名做字面替换，正文其余字节（数值、限制、状态、换行）原样保留。
---@param value string
---@param original string
---@param short string
---@return string
local function replaceName(value, original, short)
    local parts, from = {}, 1
    while true do
        local first, last = value:find(original, from, true)
        if not first then parts[#parts+1] = value:sub(from); break end
        parts[#parts+1], parts[#parts+2] = value:sub(from, first-1), short
        from = last + 1
    end
    return table.concat(parts)
end

---@param id string
---@param value string
---@return string
function M.DisplayText(id, value)
    local entry = names[id]
    return entry and replaceName(value, entry.original, entry.active) or value
end

-- 按键只有文本而没有车型ID时的显示兜底；非技能操作文字不变。
---@param value string
---@return string
function M.Label(value)
    local exact = shortByOriginal[value]
    if exact then return exact end
    -- 日常油门/刹车/氮气逐帧刷新，无技能原名时避免建立临时字符串表。
    if not value:find(" · ", 1, true) then return value end
    local result = value
    for _, entry in pairs(names) do
        if result:find(entry.original, 1, true) then
            result = replaceName(result, entry.original, entry.active)
        end
    end
    return result
end

-- 可由纯Lua测试或现有验收入口调用；不写目录、不创建引擎对象。
---@param entries MotorcycleEntry[]
---@return table
function M.RunRules(entries)
    local count, seen, activeNames = 0, {}, {}
    assert(#entries == 27, "[SkillNames] 必须覆盖全部27车型")
    for _, vehicle in ipairs(entries) do
        local entry = assert(names[vehicle.id], "[SkillNames] 缺少车型："..vehicle.id)
        assert(not seen[vehicle.id], "[SkillNames] 车型不得重复")
        assertShort(entry.active); assertShort(entry.passive)
        assert(not activeNames[entry.active], "[SkillNames] 主动短名必须唯一")
        assert(entry.original == vehicle.skillName, "[SkillNames] 原名映射过期："..vehicle.id)
        assert(M.Active(vehicle.id) == entry.active and M.Passive(vehicle.id) == entry.passive)
        local suffix = " · 已发动\n动力×1.25，持续2.6秒；不免撞伤。"
        assert(M.DisplayText(vehicle.id, entry.original..suffix) == entry.active..suffix)
        assert(M.Label(entry.original..suffix) == entry.active..suffix)
        local description = vehicle.skillDescription or ""
        assert(M.DisplayText(vehicle.id, description) == replaceName(description, entry.original, entry.active))
        seen[vehicle.id], activeNames[entry.active] = true, true
        count = count + 1
    end
    for id in pairs(names) do assert(seen[id], "[SkillNames] 映射包含非目录车型："..id) end
    assert(M.Active("unknown") == "技能" and M.Passive("unknown") == "特性")
    assert(M.DisplayText("unknown", "完整说明") == "完整说明")
    assert(M.Label("油门") == "油门" and M.Label("氮气") == "氮气")
    return {passed=true, vehicles=count, shortNames=count*2}
end
return M
