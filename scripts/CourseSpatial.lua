-- 固定赛道碰撞宽阶段：只筛候选，最终仍使用原XYZ扫掠；不按玩家距离停掉AI/机关。
local M={}
local CELL=32
local function insert(grid,index,x0,z0,x1,z1)
    for gx=math.floor(x0/CELL),math.floor(x1/CELL) do
        local column=grid[gx]
        if not column then column={};grid[gx]=column end
        for gz=math.floor(z0/CELL),math.floor(z1/CELL) do
            local cell=column[gz]
            if not cell then cell={};column[gz]=cell end
            cell[#cell+1]=index
        end
    end
end
function M.Build(world)
    local obstacles,coins={},{}
    for i,o in ipairs(world.mixedObstacles) do
        local radius=o.sweepRadius or math.sqrt(o.halfWidth^2+o.halfLength^2)
        local x,z=o.sweepX or o.x,o.sweepZ or o.z
        insert(obstacles,i,x-radius,z-radius,x+radius,z+radius)
    end
    for i,c in ipairs(world.mixedCoins) do insert(coins,i,c.x,c.z,c.x,c.z) end
    world.mixedSpatial={obstacles=obstacles,coins=coins,obstacleSource=world.mixedObstacles,coinSource=world.mixedCoins}
end
function M.Query(world,kind,x0,z0,x1,z1,padding)
    local spatial=world.mixedSpatial
    local source=kind=="obstacles" and world.mixedObstacles or world.mixedCoins
    if not spatial or (kind=="obstacles" and spatial.obstacleSource or spatial.coinSource)~=source then return source or {} end
    local gx0,gx1=math.floor((math.min(x0,x1)-padding)/CELL),math.floor((math.max(x0,x1)+padding)/CELL)
    local gz0,gz1=math.floor((math.min(z0,z1)-padding)/CELL),math.floor((math.max(z0,z1)+padding)/CELL)
    if (gx1-gx0+1)*(gz1-gz0+1)>128 then return source end
    local indices,seen,result={},{},{}
    for gx=gx0,gx1 do
        local column=spatial[kind][gx]
        if column then for gz=gz0,gz1 do
            for _,i in ipairs(column[gz] or {}) do
                if not seen[i] then seen[i]=true;indices[#indices+1]=i end
            end
        end end
    end
    -- 同时接触多个物体仍按原列表顺序处理，保持破障/保护和金币结果。
    table.sort(indices)
    for _,i in ipairs(indices) do result[#result+1]=source[i] end
    return result
end
return M
