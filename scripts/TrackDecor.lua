-- 赛道装饰使用正式库MDL；仅保留发车格、起终点棋盘线和赛道路缘等玩法曲面。
local Decor = {}
local Details = require("TrackDetails")
local Props = require("ScenicAssetProps")
local V = Vector3
Decor.Resources, Decor.ResourceTypes = Props.Resources, Props.ResourceTypes

-- 正式护栏是完整小型模块，不沿车道拉成长梁；间隔摆放明确保留路外自由通行。
-- 全占地检查覆盖车道/支路/坡台与水线，坡差过大则不摆，绝不额外造底座。
local function infrastructure(root, L, m, tick)
    local road, length = L.Roads[1], L.RouteLength
    local circuit, forest = L.activeId == "circuit", L.activeId == "forest"
    local chunks = math.ceil(length / 144)
    local rails, markers = 0, 0
    for chunk = 1, chunks do
        local lo, hi = (chunk - 1) * 144, math.min(length, chunk * 144)
        for s = lo + 12, hi - 3, 12 do
            local a, yaw = L.RoadPoint(s)
            local _, yawB = L.RoadPoint(s + 6)
            local r = V(math.cos(math.rad(yaw)), 0, -math.sin(math.rad(yaw)))
            local turn = math.abs((yawB - yaw + 180) % 360 - 180)
            for side = -1, 1, 2 do
                local guarded = circuit or (not forest and (turn > 1.6 or L.activeId == "alpine" or (L.activeId == "coast" and side == -1)))
                if guarded and rails < 420 then
                    local q = a + r * (side * (road.shoulder + (circuit and 4 or 2.1)))
                    local p = Props.GroundSite(L, "rail", q.x, q.z, .95, yaw + 90, .2, .27, .03)
                    if p then
                        Props.Add(root, "rail", p, .95, yaw + 90)
                        rails = rails + 1
                    end
                end
                if math.floor(s / 12) % 4 == 0 and markers < 180 then
                    local q = a + r * (side * (road.shoulder + 1.2))
                    local p = Props.GroundSite(L, "cone", q.x, q.z, .7, yaw, .15, .24, .02)
                    if p then
                        local marker = Props.Add(root, "cone", p, .7, yaw)
                        marker.name = "正式沿线反光锥标"
                        markers = markers + 1
                    end
                end
            end
        end
        tick("赛事环境", chunk, chunks)
    end
    Decor.LastBuild = {rails = rails, markers = markers, railLimit = 420, markerLimit = 180}
end

local function startArea(root, L, m)
    local road = L.Roads[1]
    local p, yaw = L.RoadPoint(0)
    local a = math.rad(yaw)
    local r = V(math.cos(a), 0, -math.sin(a))
    -- 移除拼装跨路门架；两侧完整正式锥标+原贴地棋盘线仍清晰标识起终点。
    for side = -1, 1, 2 do
        for row = 0, 2 do
            local point = L.RoadPoint(row * 2)
            local q = point + r * (side * (road.shoulder + 1.8))
            local safe = Props.GroundSite(L, "cone", q.x, q.z, .9, yaw, .2, .3, .02)
            if safe then
                local cone = Props.Add(root, "cone", safe, .9, yaw)
                cone.name = "起终点正式锥标"
            end
        end
    end
    local grid = L.Geometry(root, "随路线贴地发车标线", m.white)
    -- 发车格逐角查询同一可骑曲面，保留玩法位置、宽度和逐角高度。
    for row = 0, 4 do
        for side = -1, 1, 2 do
            local s = -8 - row * 6.8 + (side == 1 and 2 or 0)
            local lane = side * math.min(2.25, road.width - .8)
            local a0 = L.TrafficPose(s, lane - .55) + V(0, .025, 0)
            local b = L.TrafficPose(s + .12, lane - .55) + V(0, .025, 0)
            local c = L.TrafficPose(s, lane + .55) + V(0, .025, 0)
            local d = L.TrafficPose(s + .12, lane + .55) + V(0, .025, 0)
            L.Triangle(grid, a0, b, c); L.Triangle(grid, c, b, d)
        end
    end
    for k = 0, 15 do
        local a0 = L.TrafficPose(0, -road.width + k * road.width / 8) + V(0, .026, 0)
        local b = L.TrafficPose(.5, -road.width + k * road.width / 8) + V(0, .026, 0)
        local c = L.TrafficPose(0, -road.width + (k + 1) * road.width / 8) + V(0, .026, 0)
        local d = L.TrafficPose(.5, -road.width + (k + 1) * road.width / 8) + V(0, .026, 0)
        if k % 2 == 0 then L.Triangle(grid, a0, b, c); L.Triangle(grid, c, b, d) end
    end
    grid:Commit()
end

local function kerbs(root, L, m)
    if L.activeId ~= "circuit" then return end
    local road = L.Roads[1]
    local red = L.Geometry(root, "红色路缘合批", m.red)
    local white = L.Geometry(root, "白色路缘合批", m.white)
    for i = 1, #road.samples - 1 do
        local p = road.samples[i]
        for side = -1, 1, 2 do
            L.Ribbon(math.floor(p.s / 4) % 2 == 0 and red or white, road, i, i,
                side == 1 and road.width or -road.width - .8, side == 1 and road.width + .8 or -road.width, .025, false)
        end
    end
    red:Commit(); white:Commit()
end

local function existingScenery(root, L, m, tick)
    local count = L.activeId == "circuit" and 8 or (L.activeId == "canyon" and 42 or 28)
    for i = 1, count do
        local s = L.RouteLength * (i - .3) / count
        local p, yaw = L.RoadPoint(s)
        local id = i % 2 == 0 and "rockA" or "rockB"
        local height = L.activeId == "canyon" and (4 + i % 4 * 1.8) or (1.3 + i % 3 * .7)
        local _, radius = Props.Measure(id, height)
        local side = i % 2 == 0 and 1 or -1
        local angle = math.rad(yaw)
        local offset = side * (L.Roads[1].shoulder + radius + 12 + i % 4 * 7)
        local x, z = p.x + math.cos(angle) * offset, p.z - math.sin(angle) * offset
        local safe = Props.GroundSite(L, id, x, z, height, i * 137.5, 1, height * .5, height * .23)
        if safe then
            Details.Reserve(safe, radius)
            Props.Add(root, id, safe, height, i * 137.5, {distance = L.activeId == "canyon" and 700 or 380})
        end
        if i % 8 == 0 then tick("赛事环境", 0, math.ceil(L.RouteLength / 144)) end
    end
    if L.activeId == "lake" then
        local s = L.RouteLength * .74
        local p, yaw = L.RoadPoint(s)
        local _, radius = Props.Measure("house", 5)
        local offset = L.Roads[1].shoulder + radius + 25
        local angle = math.rad(yaw)
        local x, z = p.x + math.cos(angle) * offset, p.z - math.sin(angle) * offset
        local safe = Props.GroundSite(L, "house", x, z, 5, yaw, 1, .65, .04)
        if safe then
            Details.Reserve(safe, radius)
            local house = Props.Add(root, "house", safe, 5, yaw)
            house.name = "既有资源乡村驿舍"
        end
    end
    -- 无合适正式灯塔/看台/旗帜资产时不再用基础形状拼装这些纯装饰。
end

---@param root Node
---@param L table
---@param m table
---@param tick fun(stage:string,current:integer,total:integer)
function Decor.Build(root, L, m, tick)
    Details.BeginReservations()
    infrastructure(root, L, m, tick)
    startArea(root, L, m)
    kerbs(root, L, m)
    existingScenery(root, L, m, tick)
    Details.Build(root, L, m, tick)
end

return Decor
