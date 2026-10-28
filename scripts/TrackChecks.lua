-- 纯数值赛道验收：检查真实等弧长采样，不用控制多边形代替路面。
local Checks = {}

---@param x number
---@param z number
---@param a ScenicSample
---@param b ScenicSample
---@return number
local function distance2(x,z,a,b)
    local dx,dz=b.x-a.x,b.z-a.z
    local t=math.max(0,math.min(1,((x-a.x)*dx+(z-a.z)*dz)/math.max(1e-12,dx*dx+dz*dz)))
    return (x-a.x-dx*t)^2+(z-a.z-dz*t)^2
end

local function cross(ax,az,bx,bz) return ax*bz-az*bx end
local function intersects(a,b,c,d)
    local abx,abz=b.x-a.x,b.z-a.z
    local cdx,cdz=d.x-c.x,d.z-c.z
    local det=cross(abx,abz,cdx,cdz)
    if math.abs(det)<1e-10 then return false end
    local t=cross(c.x-a.x,c.z-a.z,cdx,cdz)/det
    local u=cross(c.x-a.x,c.z-a.z,abx,abz)/det
    return t>=0 and t<=1 and u>=0 and u<=1
end

---@class TrackReport
---@field length number
---@field maxGrade number
---@field minRadius number
---@field maxWidthRatio number
---@field minClearance number
---@field intersections integer
---@field invertedTriangles integer
---@field seamError number
---@field samples integer
---@field errors string[]

---@param track TrackDefinition
---@return TrackReport
function Checks.Analyze(track)
    local samples=assert(track.samples)
    local length=assert(track.length)
    local n=#samples-1
    local half=track.width*.5
    local outer=track.shoulder
    ---@type TrackReport
    local report={length=length,maxGrade=0,minRadius=math.huge,maxWidthRatio=0,
        minClearance=math.huge,intersections=0,invertedTriangles=0,seamError=0,samples=n,errors={}}
    local grid={}
    local cell=64
    local separation=math.max(80,outer*6)
    for i=1,n do
        local p,q=samples[i],samples[i+1]
        local ds=math.sqrt((q.x-p.x)^2+(q.z-p.z)^2)
        report.maxGrade=math.max(report.maxGrade,math.abs(q.y-p.y)/math.max(ds,1e-9))
        local angle=math.atan(cross(p.rx,p.rz,q.rx,q.rz),p.rx*q.rx+p.rz*q.rz)
        local radius=ds/math.max(1e-12,math.abs(angle))
        report.minRadius=math.min(report.minRadius,radius)
        report.maxWidthRatio=math.max(report.maxWidthRatio,outer/radius)
        -- 路带截面：负路肩 | 负半宽 | 中心 | 正半宽 | 正路肩。
        -- 每个四边形按显示网格的两三角拆分；下列叉积必须始终朝上。
        for _,band in ipairs({{-outer,-half},{-half,half},{half,outer}}) do
            local lo,hi=band[1],band[2]
            local ax,az=p.x+p.rx*lo,p.z+p.rz*lo
            local bx,bz=q.x+q.rx*lo,q.z+q.rz*lo
            local cx,cz=p.x+p.rx*hi,p.z+p.rz*hi
            local dx,dz=q.x+q.rx*hi,q.z+q.rz*hi
            if cross(bx-ax,bz-az,cx-ax,cz-az)>=-1e-7 then report.invertedTriangles=report.invertedTriangles+1 end
            if cross(bx-cx,bz-cz,dx-cx,dz-cz)>=-1e-7 then report.invertedTriangles=report.invertedTriangles+1 end
        end
        local gx,gz=math.floor(p.x/cell),math.floor(p.z/cell)
        for x=gx-2,gx+2 do
            for z=gz-2,gz+2 do
                local list=grid[x..":"..z]
                if list then
                    for _,j in ipairs(list) do
                        local a,b=samples[j],samples[j+1]
                        local along=math.abs(p.s-a.s)
                        if math.min(along,length-along)>separation then
                            local crossing=intersects(p,q,a,b)
                            local d=crossing and 0 or math.sqrt(math.min(distance2(p.x,p.z,a,b),distance2(q.x,q.z,a,b),
                                distance2(a.x,a.z,p,q),distance2(b.x,b.z,p,q)))
                            report.minClearance=math.min(report.minClearance,d-outer*2)
                            if crossing then report.intersections=report.intersections+1 end
                        end
                    end
                end
            end
        end
        local key=gx..":"..gz
        grid[key]=grid[key] or {}
        table.insert(grid[key],i)
    end
    local a,b=samples[1],samples[#samples]
    report.seamError=math.sqrt((a.x-b.x)^2+(a.y-b.y)^2+(a.z-b.z)^2+(a.rx-b.rx)^2+(a.rz-b.rz)^2)
    if outer<=half then report.errors[#report.errors+1]="路肩外边界不大于沥青半宽" end
    if report.maxGrade>.13 then report.errors[#report.errors+1]="纵坡超过13%" end
    if report.maxWidthRatio>.8 then report.errors[#report.errors+1]="内侧路肩接近曲率奇点" end
    if report.minClearance<6 then report.errors[#report.errors+1]="非邻接路带安全净距不足6米" end
    if report.intersections>0 then report.errors[#report.errors+1]="闭合中心线自交" end
    if report.invertedTriangles>0 then report.errors[#report.errors+1]="沥青或路肩三角形倒置" end
    if report.seamError>1e-6 then report.errors[#report.errors+1]="闭环位置或法向接缝不一致" end
    return report
end

---@param tracks TrackDefinition[]
---@return boolean, TrackReport[]
function Checks.Run(tracks)
    local ok,reports=true,{}
    for _,track in ipairs(tracks) do
        local report=Checks.Analyze(track)
        reports[#reports+1]=report
        print(string.format("[赛道验收] %s %.1fm / %d段 / 坡度%.2f%% / 最小半径%.1fm / 路带净距%.1fm / 接缝%.8f / 自交%d / 倒片%d",
            track.id,report.length,report.samples,report.maxGrade*100,report.minRadius,report.minClearance,
            report.seamError,report.intersections,report.invertedTriangles))
        for _,error in ipairs(report.errors) do ok=false;print("[赛道验收失败] "..track.id.." "..error) end
    end
    return ok,reports
end

-- 独立离线入口：运行 TrackChecks.lua 并传入 -track_checks 即可复测六图。
-- 正常游戏加载模块时不覆盖主入口，也不加载三维世界。
for _,argument in ipairs(GetArguments()) do
    if argument=="-track_checks" then
        function Start()
            local ok,error=pcall(function()
                local tracks=require("Tracks")
                assert(Checks.Run(tracks.List()),"存在未通过的赛道几何检查")
            end)
            if not ok then print("[赛道验收异常] "..tostring(error)) end
            engine:Exit()
        end
        break
    end
end

return Checks
