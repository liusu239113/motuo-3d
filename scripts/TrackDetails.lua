-- 沿线细节仅摆放正式共享MDL/原材质；不再手写草叶、岩块、轮胎、屋顶或设施网格。
local Details = {}
local Props = require("ScenicAssetProps")
local V = Vector3
Details.Resources, Details.ResourceTypes = Props.Resources, Props.ResourceTypes

local function noise(a, b)
    local n = math.sin(a * 127.1 + b * 311.7) * 43758.5453
    return n - math.floor(n)
end
local function basis(yaw)
    local angle = math.rad(yaw)
    return V(math.cos(angle), 0, -math.sin(angle)), V(math.sin(angle), 0, math.cos(angle))
end

-- 占地示意：路肩外缘 | 至少3米净空 | 旋转后的完整矩形占地。
-- 九点全干地、无车道/支路/坡台；再用包围圆补检，拒绝折返夹缝和大高差。
---@param L table
---@param s number
---@param offset number
---@param width number
---@param depth number
---@return Vector3?, Vector3?, Vector3?, number?, number?
function Details.Site(L, s, offset, width, depth)
    local p, yaw = L.RoadPoint(s)
    local r, f = basis(yaw)
    local center = p + r * offset
    local radius = math.sqrt(width * width + depth * depth) * .5
    local ns = L.NearestRoad(center.x, center.z)
    local nearest = L.RoadPoint(ns)
    local distance = math.sqrt((center.x - nearest.x)^2 + (center.z - nearest.z)^2)
    if distance < L.Roads[1].shoulder + radius + 3 then return nil end
    local low, high = math.huge, -math.huge
    for ix = -1, 1 do
        for iz = -1, 1 do
            local q = center + r * (ix * width * .5) + f * (iz * depth * .5)
            local _, onRoad = L.Height(q.x, q.z)
            if onRoad or L.WaterDepth(q.x, q.z) > .01 then return nil end
            if L.RoadHeight and L.RoadHeight(q.x, q.z) ~= nil then return nil end
            if L.RampAt and L.RampAt(q.x, q.z) then return nil end
            local terrain = L.TerrainHeight(q.x, q.z)
            if L.Track.water and terrain < (L.WaterLevel or 0) + .3 then return nil end
            for _, bay in ipairs(L.Laybys or {}) do
                if (q.x - bay.x)^2 + (q.z - bay.z)^2 < 22^2 then return nil end
            end
            low, high = math.min(low, terrain), math.max(high, terrain)
        end
    end
    if high - low > math.max(2.8, math.min(width, depth) * .27) then return nil end
    return V(center.x, high + .1, center.z), r, f, low, high
end

local reservations = {}
function Details.BeginReservations() reservations = {} end
---@param p Vector3
---@param radius number
function Details.Reserve(p, radius)
    reservations[#reservations + 1] = {x = p.x, z = p.z, radius = radius}
end

---@class DetailContext
---@field root Node
---@field L table
---@field occupied table[]
---@field perChunk table<number, integer>
---@field instances integer
---@field placed integer
---@field rejected integer
---@field plants integer
---@field rocks integer
---@field markers integer
---@field budgetSkipped integer

-- 资产实例而非假草三角预算；全图及每192m站位块同时约束。
local INSTANCE_LIMIT, CHUNK_LIMIT = 900, 40
---@param ctx DetailContext
---@param p Vector3
---@param radius number
local function clear(ctx, p, radius)
    for _, other in ipairs(ctx.occupied) do
        if (p.x - other.x)^2 + (p.z - other.z)^2 < (radius + other.radius + 1.5)^2 then return false end
    end
    return true
end

---@param ctx DetailContext
---@param id string
---@param s number
---@param x number
---@param z number
---@param height number
---@param yaw number
---@param rock? boolean
---@return Node?, number
local function place(ctx, id, s, x, z, height, yaw, rock)
    local chunk = math.floor(s / 192)
    if ctx.instances >= INSTANCE_LIMIT or (ctx.perChunk[chunk] or 0) >= CHUNK_LIMIT then
        ctx.budgetSkipped = ctx.budgetSkipped + 1
        return nil, 0
    end
    local p, radius = Props.GroundSite(ctx.L, id, x, z, height, yaw, .5,
        rock and height * .45 or (id == "house" and .65 or .4), rock and height * .19 or .03)
    if not p or not clear(ctx, p, radius) then return nil, radius end
    local node = Props.Add(ctx.root, id, p, height, yaw)
    ctx.instances = ctx.instances + 1
    ctx.perChunk[chunk] = (ctx.perChunk[chunk] or 0) + 1
    return node, radius
end

local plans = {
    lake = {{.18,1,"view"},{.36,-1,"shelter"},{.62,1,"view"},{.81,-1,"shelter"}},
    alpine = {{.11,-1,"shelter"},{.27,1,"view"},{.43,-1,"view"},{.52,1,"rescue"},{.68,1,"view"},{.88,-1,"shelter"}},
    coast = {{.12,1,"shelter"},{.26,-1,"view"},{.38,-1,"shelter"},{.49,1,"view"},{.67,1,"shelter"},{.84,1,"shelter"}},
    canyon = {{.09,1,"shelter"},{.25,-1,"view"},{.43,1,"shelter"},{.58,-1,"view"},{.76,1,"shelter"},{.9,-1,"view"}},
    forest = {{.12,-1,"forest"},{.29,1,"shelter"},{.44,-1,"forest"},{.6,1,"view"},{.75,1,"forest"},{.9,-1,"shelter"}},
    circuit = {{.04,-1,"stand"},{.12,1,"paddock"},{.28,-1,"stand"},{.45,1,"paddock"},{.64,-1,"stand"},{.83,1,"paddock"}},
}

---@param ctx DetailContext
local function landmark(ctx, s, side, kind)
    -- 不把乡村屋拉成长看台/车库；无对应正式模型的装饰看台、栈台、木料堆直接移除。
    -- 原位置仍保留服务屋或野外路标，玩法目标/控制区由原模块负责。
    local id = (kind == "view" or kind == "stand") and "sign" or "house"
    local height = id == "house" and 4.5 or 2.2
    local size, radius = Props.Measure(id, height)
    local _, yaw = ctx.L.RoadPoint(s)
    for _, extra in ipairs({8, 18, 32}) do
        local p = Details.Site(ctx.L, s, side * (ctx.L.Roads[1].shoulder + radius + extra), size.x + 1, size.z + 1)
        if p then
            local node, placedRadius = place(ctx, id, s, p.x, p.z, height, yaw)
            if node then
                node.name = id == "house" and "正式沿线服务屋" or "正式观景路标"
                ctx.occupied[#ctx.occupied + 1] = {x = p.x, z = p.z, radius = placedRadius}
                ctx.placed = ctx.placed + 1
                return
            end
        end
    end
    ctx.rejected = ctx.rejected + 1
end

---@param ctx DetailContext
local function roadside(ctx, s, index)
    local theme = ctx.L.activeId
    local sides = theme == "forest" and {-1, 1} or {index % 2 == 0 and 1 or -1}
    for _, side in ipairs(sides) do
        local offset = side * (ctx.L.Roads[1].shoulder + 11 + index % 3 * 3)
        local p, r, f = Details.Site(ctx.L, s, offset, 8, 10)
        if p and r and f and clear(ctx, p, 6.5) then
            local count = theme == "forest" and 4 or (theme == "circuit" and 1 or 3)
            for k = 1, count do
                local q = p + r * ((noise(index * 7 + k, 2) - .5) * 5.5)
                    + f * ((noise(index * 7 + k, 4) - .5) * 7)
                local id = k % 3 == 0 and "fernSmall" or "fern"
                local height = (id == "fernSmall" and .25 or .38) + noise(index + k, 9) * .24
                if place(ctx, id, s, q.x, q.z, height, noise(index + k, 1) * 360) then ctx.plants = ctx.plants + 1 end
            end
            if theme == "alpine" or theme == "canyon" or index % 3 == 0 then
                for k = 1, 2 do
                    local q = p + f * (k - 1.5) * 2.4
                    local id = k % 2 == 0 and "rockA" or "rockB"
                    local height = .45 + noise(index + k, 8) * .85
                    if place(ctx, id, s, q.x, q.z, height, noise(index + k, 6) * 360, true) then ctx.rocks = ctx.rocks + 1 end
                end
            end
        end
    end
end

---@param ctx DetailContext
local function marker(ctx, s, side, sector)
    local p, r = Details.Site(ctx.L, s, side * (ctx.L.Roads[1].shoulder + 8), 4, 3)
    if not p or not r or not clear(ctx, p, 3) then return end
    -- 1/2/3只完整官方锥标仍编码原分段提示，不以空白路牌替掉赛事提示。
    local success = false
    for stripe = 1, sector do
        local q = p + r * ((stripe - (sector + 1) * .5) * .8)
        local node = place(ctx, "cone", s, q.x, q.z, .75, 0)
        if node then
            node.name = "赛道分段提示_" .. sector
            ctx.markers = ctx.markers + 1
            success = true
        end
    end
    if success then ctx.occupied[#ctx.occupied + 1] = {x = p.x, z = p.z, radius = 3} end
end

---@param ctx DetailContext
local function rocks(ctx)
    local theme = ctx.L.activeId
    if theme ~= "alpine" and theme ~= "canyon" then return end
    local count = theme == "alpine" and 12 or 20
    for k = 1, count do
        local s = ctx.L.RouteLength * (k - .35) / count
        local p, yaw = ctx.L.RoadPoint(s)
        local r = basis(yaw)
        local side = k % 2 == 0 and 1 or -1
        local height = theme == "canyon" and (4 + k % 3 * 1.2) or (2 + k % 3 * .6)
        local id = k % 2 == 0 and "rockA" or "rockB"
        local _, radius = Props.Measure(id, height)
        local q = p + r * (side * (ctx.L.Roads[1].shoulder + radius + 14))
        if place(ctx, id, s, q.x, q.z, height, k * 137.5, true) then ctx.rocks = ctx.rocks + 1 end
    end
end

---@param root Node
---@param L table
---@param m table<string, Material>
---@param tick fun(stage:string,current:integer,total:integer)
function Details.Build(root, L, m, tick)
    ---@type DetailContext
    local ctx = {root = root, L = L, occupied = {}, perChunk = {}, instances = 0, placed = 0,
        rejected = 0, plants = 0, rocks = 0, markers = 0, budgetSkipped = 0}
    for _, entry in ipairs(reservations) do ctx.occupied[#ctx.occupied + 1] = entry end
    for _, child in ipairs(root:GetChildren(false)) do
        if child.name == "湖岸出发驿站" or child.name == "山间牧场" then
            local p = child.worldPosition
            ctx.occupied[#ctx.occupied + 1] = {x = p.x, z = p.z, radius = 10}
        end
    end
    local chunks = math.ceil(L.RouteLength / 144)
    for _, plan in ipairs(plans[L.activeId] or {}) do
        landmark(ctx, L.RouteLength * plan[1], plan[2], plan[3])
        tick("赛事环境", 0, chunks)
    end
    for k = 1, 12 do marker(ctx, L.RouteLength * (k - .25) / 12, k % 2 == 0 and 1 or -1, (k - 1) % 3 + 1) end
    rocks(ctx)
    local step = L.activeId == "circuit" and 96 or (L.activeId == "forest" and 48 or 40)
    for k = 1, math.floor(L.RouteLength / step) do
        roadside(ctx, k * step, k)
        if k % 8 == 0 then tick("赛事环境", math.min(chunks, math.floor(k * step / 144)), chunks) end
    end
    local maxChunk = 0
    for _, count in pairs(ctx.perChunk) do maxChunk = math.max(maxChunk, count) end
    assert(ctx.instances <= INSTANCE_LIMIT and maxChunk <= CHUNK_LIMIT, "正式沿线实例预算失配")
    print(string.format("[正式沿线] %s %d设施/%d避让/%d实例/%d草蕨/%d岩石/%d赛事锥标；0程序装饰网格，0新增阴影，0逐帧",
        L.activeId, ctx.placed, ctx.rejected, ctx.instances, ctx.plants, ctx.rocks, ctx.markers))
    -- triangles/vertices仅指本模块生成的顶点，不冒充导入MDL的真实三角数。
    Details.LastBuild = {id = L.activeId, placed = ctx.placed, rejected = ctx.rejected, nodes = ctx.instances,
        boxes = 0, triangles = 0, vertices = 0, byMaterial = {}, maxChunkTriangles = 0,
        plants = ctx.plants, rocks = ctx.rocks, logs = 0, shoreSites = 0, markers = ctx.markers,
        budgetSkipped = ctx.budgetSkipped, instances = ctx.instances, instanceLimit = INSTANCE_LIMIT,
        maxChunkInstances = maxChunk, chunkInstanceLimit = CHUNK_LIMIT, proceduralTriangles = 0, shadowTriangles = 0}
    reservations = {}
end

return Details
