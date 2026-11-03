-- 正式障碍/金币：只用资源库MDL，不再用Parts或基础形状拼装。
local Assets=require("CourseAssets")
local Rules=require("MixedRace")
local V=Vector3
local M={Resources=Assets.Resources,ResourceTypes=Assets.ResourceTypes}

-- 判定设计（道路局部坐标；米）：
--   [实体柱]    链条/摆球/空障    [实体柱] | 另一侧完整安全通路
--   地面障碍底面=TrafficPose；空障底面=2.3；门洞绝不作为整梁包围盒。
-- 支架按真实顶点切成柱/拱顶独立盒，链按短段盒，摆动统一变换8个角点；
-- 没加载成功的MDL从判定列表移除，不生成隐形罚区；擦边/高度交叠交给Rules扫掠。
local archBands={
    {-1.5572357,-1.2052612,.002985,2.986677,-.4125595,.3455353},
    {1.2052612,1.5572357,.002985,2.986677,-.4125595,.3455353},
    {-1.5401611,-1.3473778,2.986677,3.6,-.3455353,.3455353},
    {1.3473628,1.5401458,2.986677,3.6,-.3455353,.3455353},
    {-1.5097078,-1.1782679,3.6,4.05,-.3455353,.3455353},
    {1.1782672,1.5096925,3.6,4.05,-.3455353,.3455353},
    {-1.3543606,-.8738195,4.05,4.45,-.3455353,.3455353},
    {.8738042,1.3543453,4.05,4.45,-.3455353,.3455353},
    {-1.0781174,-.4730766,4.45,4.72,-.3455353,.3455353},
    {.4730614,1.0781022,4.45,4.72,-.3455353,.3455353},
    {-.7808009,.7807789,4.72,4.9,-.3455353,.3455353},
    {-.5251215,.5250914,4.9,5.053031,-.3455353,.3455353},
}
local pivot=V(-.0112177394,6.0296020508,-.0571708279)
local ballMin=V(-.8438034654,-.1024709642,-.7814649940)
local ballMax=V(.8361117244,1.3495655060,.6110193729)
local chainMin=V(-.1405742764,1.2055583,-.1287164837)
local chainMax=V(.1181387976,6.0296020508,.0143748280)

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

---@param pending table[]
---@param owner table
---@param node Node
---@param suffix string
---@return table
local function extra(pending,owner,node,suffix)
    local record={id="course_"..owner.id.."_"..suffix,kind="support",s=owner.s,lane=owner.lane,
        yaw=owner.yaw,node=node,active=true,breakable=false}
    pending[#pending+1]=record
    return record
end

local function addArch(node,owner,pending,origin)
    local arch=Assets.Add(node,"support","FormalSupport",1.05)
    if not arch then return false end
    -- Assets.Add 将底面归零、z居中；精确抵消源包围盒中心偏移。
    for i,b in ipairs(archBands) do
        local low=V(b[1]*1.05,(b[3]-.0029854774)*1.05,(b[5]+.0335875)*1.05)
        local high=V(b[2]*1.05,(b[4]-.0029854774)*1.05,(b[6]+.0335875)*1.05)
        bounds(extra(pending,owner,arch,"arch"..i),origin,owner.yaw,low,high)
    end
    return true
end

local function setSwingBounds(part,origin,yaw,angle)
    local rotation=Quaternion(0,0,angle)
    local low=V(math.huge,math.huge,math.huge)
    local high=V(-math.huge,-math.huge,-math.huge)
    for _,x in ipairs({part.low.x,part.high.x}) do
        for _,y in ipairs({part.low.y,part.high.y}) do
            for _,z in ipairs({part.low.z,part.high.z}) do
                local point=rotation*V(x,y,z)+V(0,5.2,0)
                low=V(math.min(low.x,point.x),math.min(low.y,point.y),math.min(low.z,point.z))
                high=V(math.max(high.x,point.x),math.max(high.y,point.y),math.max(high.z,point.z))
            end
        end
    end
    local record=part.record
    local previousX,previousY,previousZ=record.x,record.y,record.z
    bounds(record,origin,yaw,low,high)
    record.previousX=previousX or record.x
    record.previousY=previousY or record.y
    record.previousZ=previousZ or record.z
end

function M.Build(world)
    if world.mixedRoot then world.mixedRoot:Dispose() end
    local root=world.root:CreateChild("混合赛道正式机关")
    world.mixedRoot=root
    world.mixedCoins={}
    world.mixedSwings={}
    -- 未交付真实地表贴图分区时，规则必须返回asphalt，禁止保留不可见减速。
    world.mixedTerrainVisualsReady=false
    world.landscape.mixedTerrainVisualsReady=false
    local candidates=Rules.CreateCourse(world.landscape)
    local obstacles,pending={},{}
    world.mixedObstacles=obstacles
    for _,o in ipairs(candidates) do
        -- 兼容旧规则数据：油污不再有模型或滑移判定，明确换成实模油桶。
        if o.kind=="oil" then o.kind="barrel";o.breakable=true end
        local base=world.landscape.TrafficPose(o.s,o.lane)
        local node=root:CreateChild("Obstacle_"..o.kind..o.id)
        node.position=base
        node.rotation=Quaternion(0,o.yaw,0)
        o.node=node
        local startPending=#pending
        local ready=false
        if o.kind=="pendulum" then
            local swing=Assets.Add(node,"pendulum","SwingArm",.75)
            if swing and addArch(node,o,pending,base) then
                swing.position=V(0,5.2,0)
                local mesh=swing:GetChild("FormalMesh")
                mesh.position=pivot*-.75
                local parts={{record=o,low=(ballMin-pivot)*.75,high=(ballMax-pivot)*.75}}
                -- 真链条也可撞；十二段短盒随同一挂点旋转，不把整条摆动弧当碰撞。
                for j=1,12 do
                    local y0=chainMin.y+(chainMax.y-chainMin.y)*(j-1)/12
                    local y1=chainMin.y+(chainMax.y-chainMin.y)*j/12
                    parts[#parts+1]={record=extra(pending,o,swing,"swingchain"..j),
                        low=(V(chainMin.x,y0,chainMin.z)-pivot)*.75,
                        high=(V(chainMax.x,y1,chainMax.z)-pivot)*.75}
                end
                world.mixedSwings[#world.mixedSwings+1]={node=swing,origin=base,yaw=o.yaw,phase=o.phase or 0,parts=parts}
                o.breakable=false
                ready=true
            end
        elseif o.kind=="airbarrier" then
            local visual,size=Assets.Add(node,"barrier","AirBarrier",2.6/.998046875)
            if visual and size and addArch(node,o,pending,base) then
                visual.position=V(0,2.3,0)
                bounds(o,base,o.yaw,V(-size.x*.5,2.3,-size.z*.5),V(size.x*.5,2.3+size.y,size.z*.5))
                ready=true
                -- 正式链条从路障顶面连至拱顶；两链均有真实短段判定。
                local chainHeight=5.0-(2.3+size.y)
                for _,side in ipairs({-1,1}) do
                    local chain,chainSize=Assets.Add(node,"chain","AirSuspension",chainHeight/4.69425)
                    if not chain or not chainSize then ready=false;break end
                    chain.position=V(side*.6,2.3+size.y,0)
                    bounds(extra(pending,o,chain,"suspension"..side),base,o.yaw,
                        V(side*.6-chainSize.x*.5,2.3+size.y,-chainSize.z*.5),
                        V(side*.6+chainSize.x*.5,5.0,chainSize.z*.5))
                end
                o.breakable=false
            end
        else
            local visual,size=Assets.Add(node,o.kind,"FormalObstacle")
            if visual and size then
                bounds(o,base,o.yaw,V(-size.x*.5,0,-size.z*.5),V(size.x*.5,size.y,size.z*.5))
                ready=true
            end
        end
        if ready then
            obstacles[#obstacles+1]=o
            -- 提前25米的正式警示牌放同侧路肩，不把路面黄盒当警告。
            local half=world.landscape.Roads[1].width
            local p,yaw=world.landscape.TrafficPose(o.s-25,(o.lane<0 and -1 or 1)*(half+.65))
            local warning=Assets.Add(root,"warning","ApproachWarning")
            if warning then warning.position=p;warning.rotation=Quaternion(0,yaw+180,0) end
            local cp=world.landscape.TrafficPose(o.s+15,-o.lane*.8)
            local coinNode=Assets.Add(root,"coin","TrackCoin")
            if coinNode then
                coinNode.position=cp+V(0,.45,0)
                world.mixedCoins[#world.mixedCoins+1]={x=cp.x,y=cp.y+.75,z=cp.z,active=true,node=coinNode}
            end
        else
            for i=#pending,startPending+1,-1 do pending[i]=nil end
            node:Dispose()
            print("[混合赛道] 取消未交付实模障碍及判定 "..o.kind.." #"..o.id)
        end
    end
    for _,record in ipairs(pending) do obstacles[#obstacles+1]=record end
    -- 动态链段创建时尚无坐标，必须先初始化真实bounds，再统一做道路投影。
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
    print(string.format("[混合赛道] 正式机关%d / 支架链段%d / 实模金币%d；地形视觉未交付，特殊地形判定禁用",#obstacles-#pending,#pending,#world.mixedCoins))
end

function M.Update(world,clock)
    for _,swing in ipairs(world.mixedSwings or {}) do
        local angle=math.sin(clock*1.7+swing.phase)*22
        swing.node.rotation=Quaternion(0,0,angle)
        for _,part in ipairs(swing.parts) do
            setSwingBounds(part,swing.origin,swing.yaw,angle)
            local record=part.record
            record.s,record.lane=world.landscape.NearestRoad(record.x,record.z)
        end
    end
end
return M
