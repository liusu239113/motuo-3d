-- 现场分段计时：每2秒汇总一次各阶段耗时，用真实设备定位卡顿来源。
-- 只在赛事驾驶中启用；纯CPU计时，不创建节点、不读存档。
local M = {}
local now = os.clock
local window = 0
local acc = {}
local counts = {}
local marks = {}
---@type number?
local markStart = nil
local markName = ""

---@param name string
function M.Begin(name)
    markName = name
    markStart = now()
end

function M.End()
    if not markStart then return end
    local elapsed = now() - markStart
    acc[markName] = (acc[markName] or 0) + elapsed
    counts[markName] = (counts[markName] or 0) + 1
    markStart = nil
end

---@param dt number
function M.Tick(dt)
    window = window + dt
    if window < 2 then return end
    window = 0
    local names = {}
    for name in pairs(acc) do names[#names + 1] = name end
    table.sort(names)
    local parts = {}
    for _, name in ipairs(names) do
        local n = counts[name] or 0
        if n > 0 then
            parts[#parts + 1] = string.format("%s=%.1fms", name, acc[name] / n * 1000)
        end
    end
    if #parts > 0 then print("[帧剖析] " .. table.concat(parts, " ")) end
    acc, counts = {}, {}
end

function M.Reset()
    window, acc, counts, markStart = 0, {}, {}, nil
end

return M
