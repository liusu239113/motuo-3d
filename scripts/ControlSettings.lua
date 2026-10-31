-- 操作设置：按钮位置与灵敏度，可保存多套方案。
-- 只保存布局数值，不复制控件节点；HUD 应用后由 UI 层直接改样式。
local Settings = {}

local SAVE_PATH = "pursuit_controls.txt"
-- 可调按钮：位置用“屏幕左下/右下基准 + 偏移”表示，滑杆为相对位移，不破坏响应式布局。
Settings.Keys = {"steering", "gas", "brake", "nitro", "wheelie", "burnout", "spin180", "spin360"}
Settings.Labels = {steering = "转向", gas = "油门", brake = "刹车", nitro = "氮气",
    wheelie = "翘头", burnout = "烧胎", spin180 = "180°", spin360 = "360°"}
Settings.SliderKeys = {"steeringSensitivity", "steeringDeadzone", "nitroSensitivity"}

---@class ControlScheme
---@field name string
---@field pos table<string, number[]> 每个按钮在屏幕上的相对位置 {x,y}，取值0..1
---@field offsetX table<string, number> 兼容旧档：额外像素微调
---@field offsetY table<string, number>
---@field scale table<string, number> 按钮缩放倍率 0.7..1.3
---@field steeringSensitivity number 0.5..1.6
---@field steeringDeadzone number 0.02..0.30
---@field nitroSensitivity number 0.5..1.5

-- 默认摆位与驾驶页初始布局一致：左手转向在左下，其余在右下/左下角。
-- 默认摆位对齐原版：左手转向在左下；刹车/油门右下；氮气/翘头在其上方；
-- 烧胎/180°/360° 一行在左下转向之上的特技区。
Settings.DefaultPos = {
    steering = {0.11, 0.85},
    gas = {0.93, 0.83},
    brake = {0.81, 0.86},
    nitro = {0.92, 0.48},
    wheelie = {0.81, 0.48},
    burnout = {0.05, 0.60},
    spin180 = {0.14, 0.60},
    spin360 = {0.23, 0.60},
}

local function defaults(name)
    local offsetX, offsetY, scale, pos = {}, {}, {}, {}
    for _, key in ipairs(Settings.Keys) do
        offsetX[key], offsetY[key], scale[key] = 0, 0, 1.0
        local p = Settings.DefaultPos[key] or {0.5, 0.5}
        pos[key] = {p[1], p[2]}
    end
    return {name = name or "默认方案", pos = pos, offsetX = offsetX, offsetY = offsetY, scale = scale,
        steeringSensitivity = 1.0, steeringDeadzone = 0.12, nitroSensitivity = 1.0}
end

Settings.defaults = defaults

---@type ControlScheme[]
local schemes = nil
local activeIndex = 1

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local function parseScheme(text, index)
    local scheme = defaults("方案 " .. index)
    for line in (text or ""):gmatch("[^\r\n]+") do
        local key, value = line:match("^([%w_]+)=(.*)$")
        if key == "name" then
            scheme.name = value ~= "" and value or scheme.name
        elseif key == "steeringSensitivity" or key == "steeringDeadzone" or key == "nitroSensitivity" then
            scheme[key] = tonumber(value) or scheme[key]
        else
            -- Lua pattern 不支持正则的 a|b；分别解析后缀，旧写法使所有按键位置都读不回来。
            local slot, kind = (key or ""):match("^([%w]+)_([%a]+)$")
            local number = tonumber(value)
            if slot and scheme.pos[slot] and number and number == number and math.abs(number) < math.huge then
                if kind == "ox" then scheme.offsetX[slot] = number or 0
                elseif kind == "oy" then scheme.offsetY[slot] = number or 0
                elseif kind == "sc" then scheme.scale[slot] = clamp(number or 1, 0.7, 1.3)
                elseif kind == "px" then
                    scheme.pos[slot] = scheme.pos[slot] or {0.5, 0.5}
                    scheme.pos[slot][1] = clamp(number or 0.5, 0, 1)
                elseif kind == "py" then
                    scheme.pos[slot] = scheme.pos[slot] or {0.5, 0.5}
                    scheme.pos[slot][2] = clamp(number or 0.5, 0, 1)
                end
            end
        end
    end
    scheme.steeringSensitivity = clamp(scheme.steeringSensitivity, 0.5, 1.6)
    scheme.steeringDeadzone = clamp(scheme.steeringDeadzone, 0.02, 0.30)
    scheme.nitroSensitivity = clamp(scheme.nitroSensitivity, 0.5, 1.5)
    for _, slot in ipairs(Settings.Keys) do
        scheme.offsetX[slot] = clamp(scheme.offsetX[slot] or 0, -160, 160)
        scheme.offsetY[slot] = clamp(scheme.offsetY[slot] or 0, -160, 160)
        scheme.scale[slot] = clamp(scheme.scale[slot] or 1, 0.7, 1.3)
    end
    return scheme
end

local function load()
    if schemes then return end
    schemes = {}
    local file = fileSystem:FileExists(SAVE_PATH) and File(SAVE_PATH, FILE_READ) or nil
    if file and file:IsOpen() then
        local text = file:ReadString() or ""
        file:Close()
        for block in text:gmatch("<scheme>(.-)</scheme>") do
            schemes[#schemes + 1] = parseScheme(block, #schemes + 1)
        end
        local active = text:match("active=(%d+)")
        activeIndex = tonumber(active) or 1
    end
    if #schemes == 0 then schemes[1] = defaults() end
    activeIndex = clamp(activeIndex, 1, #schemes)
end

---@return boolean, string?
function Settings.Save()
    load()
    local parts = {"active=" .. tostring(activeIndex)}
    for _, scheme in ipairs(schemes) do
        local lines = {"name=" .. (scheme.name or "方案")}
        for _, slot in ipairs(Settings.Keys) do
            lines[#lines + 1] = slot .. "_ox=" .. string.format("%.1f", scheme.offsetX[slot] or 0)
            lines[#lines + 1] = slot .. "_oy=" .. string.format("%.1f", scheme.offsetY[slot] or 0)
            lines[#lines + 1] = slot .. "_sc=" .. string.format("%.2f", scheme.scale[slot] or 1)
        end
        for _, slot in ipairs(Settings.Keys) do
            local p = scheme.pos[slot] or {0.5, 0.5}
            lines[#lines + 1] = slot .. "_px=" .. string.format("%.4f", p[1])
            lines[#lines + 1] = slot .. "_py=" .. string.format("%.4f", p[2])
        end
        lines[#lines + 1] = "steeringSensitivity=" .. string.format("%.2f", scheme.steeringSensitivity)
        lines[#lines + 1] = "steeringDeadzone=" .. string.format("%.3f", scheme.steeringDeadzone)
        lines[#lines + 1] = "nitroSensitivity=" .. string.format("%.2f", scheme.nitroSensitivity)
        parts[#parts + 1] = "<scheme>" .. table.concat(lines, "\n") .. "</scheme>"
    end
    local file = File(SAVE_PATH, FILE_WRITE)
    if not file or not file:IsOpen() then return false, "无法写入操作方案" end
    local written = file:WriteString(table.concat(parts, "\n") .. "\n")
    file:Close()
    if not written then return false, "操作方案写入失败，请重试" end
    return true
end

---@return ControlScheme
function Settings.Current()
    load()
    return schemes[activeIndex] --[[@as ControlScheme]]
end

---@return ControlScheme[]
function Settings.All()
    load()
    return schemes
end

---@return integer
function Settings.ActiveIndex()
    load()
    return activeIndex
end

local function cloneScheme(source, name)
    local copy = defaults(name or source.name)
    copy.steeringSensitivity, copy.steeringDeadzone, copy.nitroSensitivity =
        source.steeringSensitivity, source.steeringDeadzone, source.nitroSensitivity
    for _, slot in ipairs(Settings.Keys) do
        copy.pos[slot] = {source.pos[slot][1], source.pos[slot][2]}
        copy.offsetX[slot], copy.offsetY[slot], copy.scale[slot] = source.offsetX[slot], source.offsetY[slot], source.scale[slot]
    end
    return copy
end

---@param index integer
---@return boolean, string?
function Settings.SetActive(index)
    load()
    if not schemes[index] then return false, "方案不存在" end
    local previous = activeIndex
    activeIndex = index
    local ok, err = Settings.Save()
    if not ok then activeIndex = previous end
    return ok, err
end

---@param name string
---@return boolean, string
function Settings.AddScheme(name)
    load()
    if #schemes >= 6 then return false, "最多保存6套方案" end
    local previous = activeIndex
    local scheme = cloneScheme(schemes[activeIndex], name ~= "" and name or ("方案 " .. (#schemes + 1)))
    schemes[#schemes + 1] = scheme
    activeIndex = #schemes
    local ok, err = Settings.Save()
    if not ok then table.remove(schemes); activeIndex = previous; return false, err or "保存失败" end
    return true, scheme.name
end

---@return boolean, string
function Settings.DeleteScheme()
    load()
    if #schemes <= 1 then return false, "至少保留一套方案" end
    local previous, removed = activeIndex, schemes[activeIndex]
    table.remove(schemes, activeIndex)
    activeIndex = math.max(1, activeIndex - 1)
    local ok, err = Settings.Save()
    if not ok then table.insert(schemes, previous, removed); activeIndex = previous; return false, err or "保存失败" end
    return true, "已删除"
end

---@param slot string
---@param dx number
---@param dy number
function Settings.Nudge(slot, dx, dy)
    local scheme = Settings.Current()
    if not scheme.offsetX[slot] then return end
    scheme.offsetX[slot] = clamp(scheme.offsetX[slot] + dx, -160, 160)
    scheme.offsetY[slot] = clamp(scheme.offsetY[slot] + dy, -160, 160)
    Settings.Save()
end

-- 拖动后直接写入相对位置（0..1），不依赖具体屏幕尺寸。
---@param slot string
---@param x number
---@param y number
function Settings.SetPosition(slot, x, y)
    local scheme = Settings.Current()
    if not scheme.pos[slot] then return end
    scheme.pos[slot][1] = clamp(x, 0, 1)
    scheme.pos[slot][2] = clamp(y, 0, 1)
    scheme.offsetX[slot], scheme.offsetY[slot] = 0, 0
end

-- 一键恢复默认摆位。
function Settings.ResetLayout()
    local scheme = Settings.Current()
    for _, slot in ipairs(Settings.Keys) do
        local p = Settings.DefaultPos[slot] or {0.5, 0.5}
        scheme.pos[slot] = {p[1], p[2]}
        scheme.offsetX[slot], scheme.offsetY[slot], scheme.scale[slot] = 0, 0, 1.0
    end
    Settings.Save()
end

---@param slot string
---@param delta number
function Settings.Scale(slot, delta)
    local scheme = Settings.Current()
    if not scheme.scale[slot] then return end
    scheme.scale[slot] = clamp((scheme.scale[slot] or 1) + delta, 0.7, 1.3)
    Settings.Save()
end

---@param key string
---@param value number
function Settings.SetSlider(key, value)
    local scheme = Settings.Current()
    if key == "steeringSensitivity" then scheme.steeringSensitivity = clamp(value, 0.5, 1.6)
    elseif key == "steeringDeadzone" then scheme.steeringDeadzone = clamp(value, 0.02, 0.30)
    elseif key == "nitroSensitivity" then scheme.nitroSensitivity = clamp(value, 0.5, 1.5) end
end

---@param name string
function Settings.Rename(name)
    local scheme = Settings.Current()
    scheme.name = (name ~= "" and name) or scheme.name
    Settings.Save()
end

return Settings
