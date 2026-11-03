-- 轻量程序化机关；造型与碰撞共用米制尺寸，不加载高面数机关MDL。
local Assets=require("CourseAssets")
local Rules=require("MixedRace")
local V=Vector3
local M={Resources=Assets.Resources,ResourceTypes=Assets.ResourceTypes}

-- 判定设计（道路局部坐标；米）：
--     支柱 | 横梁 y=5.12..5.28 | 支柱       另一侧完整安全通路
--          | 单根连杆 + 摆球 |
-- 支柱中心x=±1.75，宽/深=.16；门洞不填整盒。
-- 摆球直径1.25，挂点y=5.2，球心距挂点4.2；单根可见连杆用8个短盒扫掠。
-- 空障底面2.3，低车可下穿；两根可见悬杆有独立判定。
-- 擦边、跨帧扫掠、上下分离继续由Rules处理；禁止保留旧实模的隐形支架/链段。
local pivotHeight=5.2
local archBands={
    {-1.83,-1.67,0,5.2,-.08,.08},
    {1.67,1.83,0,5.2,-.08,.08},
    {-1.83,1.83,5.12,5.28,-.08,.08},
}

---@param record table
---@param origin Vector3
---@param yaw number
---@param low Vector3
---@param high Vector3
local function bounds(record,origin,yaw,low,high)
    local center=(low+high)*.5
    local a=math.rad(yaw)
    record.x=origin.x+math.cos(a)*center.x+math.sin(a)*center.z
    record.z=origin.z-math.sin(a)*center.x+math.cos(a)*center.z
    record.y=origin.y+low.y
    record.halfWidth=(high.x-low.x)*.5
    record.halfLength=(high.z-low.z)*.5
    record.height=high.y-low.y
    record.yaw=yaw
end

local function extra(pending,owner,node,suffix)
    local record={id="course_"..owner.id.."_"..suffix,kind="support",s=owner.s,lane=owner.lane,
        yaw=owner.yaw,node=node,active=true,breakable=false}
    pending[#pending+1]=record
    return record
end

local function addArch(node,owner,pending,origin)
    local arch=assert(Assets.Add(node,"support","轻量支架"))
    for i,b in ipairs(archBands) do
        bounds(extra(pending,owner,arch,"arch"..i),origin,owner.yaw,
            V(b[1],b[3],b[5]),V(b[2],b[4],b[6]))
    end
end

local function setSwingBounds(part,swing,c,s)
    -- 绕Z轴旋转盒：中心随旋转，半尺寸为 |R|*extent，与八角点取极值等价。
    local record=part.record
    local previousX,previousY,previousZ=record.x,record.y,record.z
    local cx,cy=part.cx*c-part.cy*s,part.cx*s+part.cy*c+pivotHeight
    local ex,ey=math.abs(c)*part.ex+math.abs(s)*part.ey,math.abs(s)*part.ex+math.abs(c)*part.ey
    record.x=swing.origin.x+swing.cosYaw*cx+swing.sinYaw*part.cz
    record.z=swing.origin.z-swing.sinYaw*cx+swing.cosYaw*part.cz
    record.y=swing.origin.y+cy-ey
    record.halfWidth,record.halfLength,record.height=ex,part.ez,ey*2
    record.previousX=previousX or record.x
    record.previousY=previousY or record.y
    record.previousZ=previousZ or record.z
end

-- 开关：true=完全关闭赛道机关（障碍/金币/预警）用于性能对照。
local DISABLE_COURSE = true

function M.Build(world)
    if world.mixedRoot then world.mixedRoot:Dispose() end
    local root=world.root:CreateChild("混合赛道轻量机关")
    world.mixedRoot=root
    world.mixedCoins={}
    world.mixedSwings={}
    world.mixedObstacles={}
    if DISABLE_COURSE then
        print("[混合赛道] 机关系统已关闭（性能对照）：无障碍/金币/预警")
        require("CourseSpatial").Build(world)
        return
    end
    world.mixedTerrainVisualsReady=false
    world.landscape.mixedTerrainVisualsReady=false
    local candidates=Rules.CreateCourse(world.landscape)
    local obstacles,pending={},{}
    world.mixedObstacles=obstacles
    for _,o in ipairs(candidates) do
        if o.kind=="oil" then o.kind="barrel";o.breakable=true end
        local base=world.landscape.TrafficPose(o.s,o.lane)
        local node=root:CreateChild("Obstacle_"..o.kind..o.id)
        node.position=base
        node.rotation=Quaternion(0,o.yaw,0)
        o.node=node
        if o.kind=="pendulum" then
            local swing=assert(Assets.Add(node,"pendulum","SwingArm"))
            addArch(node,o,pending,base)
            swing.position=V(0,pivotHeight,0)
            ---@type table[]
            local parts={
                {record=o,low=V(-.625,-4.825,-.625),high=V(.625,-3.575,.625)},
            }
            -- 可见杆不拆件；判定细分，避免斜杆整段包围盒覆盖门洞空白区。
            for j=1,8 do
                parts[#parts+1]={record=extra(pending,o,swing,"swingchain"..j),
                    low=V(-.04,-3.575+(j-1)*3.575/8,-.04),
                    high=V(.04,-3.575+j*3.575/8,.04)}
            end
            for _,part in ipairs(parts) do
                local cx,cy,cz=(part.low.x+part.high.x)*.5,(part.low.y+part.high.y)*.5,(part.low.z+part.high.z)*.5
                local ex,ey,ez=(part.high.x-part.low.x)*.5,(part.high.y-part.low.y)*.5,(part.high.z-part.low.z)*.5
                part.cx,part.cy,part.cz=cx,cy,cz
                part.ex,part.ey,part.ez=ex,ey,ez
                part.record.sweepX,part.record.sweepZ=base.x,base.z
                part.record.sweepRadius=math.sqrt(cx^2+cy^2)+math.abs(cz)+math.sqrt(ex^2+ey^2+ez^2)
            end
            local yaw=math.rad(o.yaw)
            local project=world.landscape.CreateRoadProjector
                and world.landscape.CreateRoadProjector(base.x,base.z,4) or world.landscape.NearestRoad
            world.mixedSwings[#world.mixedSwings+1]={node=swing,origin=base,yaw=o.yaw,project=project,
                cosYaw=math.cos(yaw),sinYaw=math.sin(yaw),phase=o.phase or 0,parts=parts}
            o.breakable=false
        elseif o.kind=="airbarrier" then
            local visual,size=Assets.Add(node,"airbarrier","轻量空障")
            assert(visual and size,"轻量空障创建失败")
            visual.position=V(0,2.3,0)
            bounds(o,base,o.yaw,V(-size.x*.5,2.3,-size.z*.5),V(size.x*.5,2.3+size.y,size.z*.5))
            addArch(node,o,pending,base)
            local top=2.3+size.y
            local chainHeight=5.12-top
            for _,side in ipairs({-1,1}) do
                -- 悬杆尺寸直接用于可见网格和判定，不再创建实模链环。
                local chain=assert(Assets.Add(node,"chain","轻量悬杆"))
                chain.scale=V(1,chainHeight,1)
                chain.position=V(side*.6,top,0)
                bounds(extra(pending,o,chain,"suspension"..side),base,o.yaw,
                    V(side*.6-.04,top,-.04),V(side*.6+.04,5.12,.04))
            end
            o.breakable=false
        else
            local visual,size=Assets.Add(node,o.kind,"轻量地障")
            assert(visual and size,"轻量地障创建失败")
            bounds(o,base,o.yaw,V(-size.x*.5,0,-size.z*.5),V(size.x*.5,size.y,size.z*.5))
        end
        obstacles[#obstacles+1]=o
        local half=world.landscape.Roads[1].width
        local p,yaw=world.landscape.TrafficPose(o.s-25,(o.lane<0 and -1 or 1)*(half+.65))
        local warning=assert(Assets.Add(root,"warning","轻量预警"))
        warning.position=p
        warning.rotation=Quaternion(0,yaw+180,0)
        local cp=world.landscape.TrafficPose(o.s+15,-o.lane*.8)
        local coinNode=assert(Assets.Add(root,"coin","TrackCoin"))
        coinNode.position=cp+V(0,.45,0)
        world.mixedCoins[#world.mixedCoins+1]={x=cp.x,y=cp.y+.75,z=cp.z,active=true,node=coinNode}
    end
    for _,record in ipairs(pending) do obstacles[#obstacles+1]=record end
    M.Update(world,0)
    for _,record in ipairs(obstacles) do
        record.s,record.lane=world.landscape.NearestRoad(record.x,record.z)
    end
    for _,swing in ipairs(world.mixedSwings) do
        for _,part in ipairs(swing.parts) do
            local record=part.record
            record.previousX,record.previousY,record.previousZ=record.x,record.y,record.z
        end
    end
    require("CourseSpatial").Build(world)
    print(string.format("[混合赛道] 轻量机关%d / 支架连杆%d / 金币%d；无机关贴图、无投影阴影，特殊地形判定禁用",
        #obstacles-#pending,#pending,#world.mixedCoins))
end

function M.Update(world,clock)
    for _,swing in ipairs(world.mixedSwings or {}) do
        local angle=math.sin(clock*1.7+swing.phase)*22
        swing.node.rotation=Quaternion(0,0,angle)
        local radians=math.rad(angle)
        local c,s=math.cos(radians),math.sin(radians)
        for _,part in ipairs(swing.parts) do
            setSwingBounds(part,swing,c,s)
            local record=part.record
            record.s,record.lane=swing.project(record.x,record.z)
        end
    end
end
return M
