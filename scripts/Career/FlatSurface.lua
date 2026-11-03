-- 精确平面区域证明，不采样近似地形；只为重复轮胎接地提供可验证的常高快路。
-- 俯视（米）：查询轮胎旋转包络[AABB]必须完整被同高地面覆盖；
-- 任意更高地表与其相交、跨坡/海岸/世界边缘，都返回nil走原顶点求解。
local World=require("Career.WorldData")
local Environment=require("Career.CityEnvironment")
local Hills=require("Career.HillDistrict")
local Details=require("Career.CityDetails")
local Flat={}
local function overlap(a,x1,z1,x2,z2)
    return a.x1<=x2 and a.x2>=x1 and a.z1<=z2 and a.z2>=z1
end
function Flat.Height(city,x1,z1,x2,z2)
    if city.space~="city" then return .085 end
    if not city.details or not city.details.surfaceCells then return nil end
    if overlap(Hills.Bounds,x1,z1,x2,z2) then return Hills.FlatHeight(x1,z1,x2,z2) end
    if x1< -World.LIMIT or z1< -World.LIMIT or x2>World.LIMIT or z2>World.LIMIT
        or overlap(Environment.Bounds,x1,z1,x2,z2) or overlap(Environment.Connector,x1,z1,x2,z2) then return nil end
    local y=city:Surface((x1+x2)/2,(z1+z2)/2)
    -- Surface has an implicit zero-height base even where no authored rectangle exists.
    local covered=y==0
    local same={}
    local function inspect(a,b,c,d,height)
        if a<=x2 and b>=x1 and c<=z2 and d>=z1 then
            if height>y then return false end
            if height==y then
                if a<=x1 and b>=x2 and c<=z1 and d>=z2 then covered=true end
                same[#same+1]={x1=math.max(a,x1),x2=math.min(b,x2),z1=math.max(c,z1),z2=math.min(d,z2)}
            end
        end
        return true
    end
    local seen={}
    for gx=math.floor(x1/16),math.floor(x2/16) do
        for gz=math.floor(z1/16),math.floor(z2/16) do
            for _,s in ipairs(city.details.surfaceCells[Details.CellKey(gx,gz)] or {}) do
                if not seen[s] then
                    seen[s]=true
                    if not inspect(s.x-s.w/2,s.x+s.w/2,s.z-s.d/2,s.z+s.d/2,s.y) then return nil end
                end
            end
        end
    end
    -- 老街基面已经完整覆盖时无需查外域描述；跨保护边仍检查同源外区地面。
    if x1< -World.OLD_LIMIT or x2>World.OLD_LIMIT or z1< -World.OLD_LIMIT or z2>World.OLD_LIMIT then
        for ix=math.floor(x1/256),math.floor(x2/256) do
            for iz=math.floor(z1/256),math.floor(z2/256) do
                for _,s in ipairs(World.DescribeCell(ix,iz).grounds) do
                    if not inspect(s.x1,s.x2,s.z1,s.z2,s.y) then return nil end
                end
            end
        end
    end
    if not covered and #same>1 then
        -- Rectangle union proof, not corner/centre sampling: every x slab between
        -- authored edges must have its complete z interval covered at height y.
        local edges={x1,x2}
        for _,s in ipairs(same) do edges[#edges+1]=s.x1;edges[#edges+1]=s.x2 end
        table.sort(edges)
        covered=true
        for i=1,#edges-1 do
            local left,right=edges[i],edges[i+1]
            if right>left or x1==x2 then
                local strips={}
                for _,s in ipairs(same) do
                    if s.x1<=left and s.x2>=right then strips[#strips+1]=s end
                end
                table.sort(strips,function(a,b) return a.z1<b.z1 end)
                local reach=z1
                local started=false
                for _,s in ipairs(strips) do
                    if s.z1>reach then break end
                    if s.z2>=reach then reach=s.z2;started=true end
                    if reach>=z2 then break end
                end
                if not started or reach<z2 then covered=false;break end
            end
        end
    end
    return covered and y or nil
end

-- Compile only the old-city rectangle field. Outside this domain City.Surface's
-- coastline/hill/world precedence must remain on the original path. Cached lists
-- retain the ORIGINAL abs(delta)<=half-size predicates and maximum height.
local compiled=setmetatable({},{__mode="k"})
---@param city CareerCity
---@param x1 number
---@param z1 number
---@param x2 number
---@param z2 number
---@return (fun(x:number,z:number):number)?
function Flat.Compile(city,x1,z1,x2,z2)
    if city.space~="city" or not city.details or not city.details.surfaceCells
        or x1< -World.OLD_LIMIT or x2>World.OLD_LIMIT or z1< -World.OLD_LIMIT or z2>World.OLD_LIMIT
        or overlap(Hills.Bounds,x1,z1,x2,z2) or overlap(Environment.Bounds,x1,z1,x2,z2)
        or overlap(Environment.Connector,x1,z1,x2,z2) then return nil end
    local cells=city.details.surfaceCells
    local memo=compiled[cells]
    local count=city.details.surfaces and #city.details.surfaces or 0
    if not memo or memo.sourceCount~=count then
        memo={entries={},count=0,sourceCount=count};compiled[cells]=memo
    end
    local gx1,gx2,gz1,gz2=math.floor(x1/16),math.floor(x2/16),math.floor(z1/16),math.floor(z2/16)
    local key=gx1..":"..gx2..":"..gz1..":"..gz2
    local saved=memo.entries[key]
    if saved then return saved end
    -- Preserve cell membership too: a rectangle from a neighbouring cell must
    -- not appear merely because abs() happens to round onto its closed edge.
    local grid={}
    for gx=gx1,gx2 do
        local row={};grid[gx]=row
        for gz=gz1,gz2 do
            local candidates={}
            for _,s in ipairs(cells[Details.CellKey(gx,gz)] or {}) do
                if s.y>0 then candidates[#candidates+1]=s end
            end
            table.sort(candidates,function(a,b) return a.y>b.y end)
            row[gz]=candidates
        end
    end
    local function surface(x,z)
        local row=grid[math.floor(x/16)]
        for _,s in ipairs(row and row[math.floor(z/16)] or {}) do
            if math.abs(x-s.x)<=s.w/2 and math.abs(z-s.z)<=s.d/2 then return s.y end
        end
        return 0
    end
    if memo.count>=128 then memo.entries={};memo.count=0 end
    memo.entries[key]=surface;memo.count=memo.count+1
    return surface
end
return Flat
