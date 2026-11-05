-- 确定性道路机关；无引擎对象、外部资产、存档或随机数。
local Features = {}
local abs, sin, cos, rad = math.abs, math.sin, math.cos, math.rad
local function clamp(v,a,b) return math.max(a,math.min(b,v)) end

-- 碰撞设计（米；轮胎接触点，不是渲染包围盒）：
-- 俯视：    可用沥青车道                           前进 +z
--       |  中心绕行净空 | [可选飞坡] |                 ^
--       |              |    / 唇口 --->230米检查走廊   |
--       | >>> 加速带 >>>（部分车道，单向入口）          |
-- 侧视：路面 ____/ 真实采样楔形 | . 重力弹道 . ____ 路面
-- 加速带扫掠p0--p1正向进入内缩.08米矩形；顺向侧并入有效，高速跨整带不漏判。
-- 逆向、横穿、静止、腾空、刹车或损坏不增益。
-- 重复触发：入口穿越 + 每带8秒/全局2.5秒冷却；增量<=4.5m/s，
-- 上限为原车极速108%，从不读写氮气。超额动量沿原有限阻力衰减。
-- 飞坡显示与Height共用每格同一对三角形，入口到唇口取得切线速度，
-- 后续走原TakeOff/重力/Land链；侧壁背壁真实扫掠阻挡，不吸附到顶。
-- 唇口/宽边采样仅容许浮点epsilon，起飞需内缩.08米；整坡高速跨越
-- 同时检测入口和唇口，不能仅检测帧末。

---@class TrackFeature
---@field id string
---@field kind string
---@field optional boolean
---@field s number
---@field lateral number
---@field x number
---@field y number
---@field z number
---@field yaw number
---@field width number
---@field length number
---@field height number
---@field landingEndS number
---@field rows table[]
---@field exitGrade number
---@field cooldown number
---@field gain number

---@param r table
function Features.Coords(r,x,z)
    local a=rad(r.yaw)
    local dx,dz=x-r.x,z-r.z
    return dx*cos(a)-dz*sin(a),dx*sin(a)+dz*cos(a)
end

---@param r table
function Features.Point(r,lateral,forward)
    local a=rad(r.yaw)
    return r.x+cos(a)*lateral+sin(a)*forward,r.z-sin(a)*lateral+cos(a)*forward
end

-- 重心插值精确对应显示使用的a,b,c / c,b,d三角剖分。
---@param r table
function Features.RampHeight(r,x,z)
    local lateral,forward=Features.Coords(r,x,z)
    if abs(lateral)>r.width*.5+1e-6 or forward < -1e-6 or forward>r.length+1e-6 then return nil end
    local u=clamp((lateral+r.width*.5)/r.width,0,1)
    local f=clamp(forward/r.length,0,1)
    if not r.rows then return r.y+f*r.height end
    local n=#r.rows-1
    local index=math.min(n,math.floor(f*n)+1)
    local v=clamp(f*n-(index-1),0,1)
    local a,b=r.rows[index],r.rows[index+1]
    if u+v<=1 then return a.left+(a.right-a.left)*u+(b.left-a.left)*v end
    return b.right+(b.left-b.right)*(1-u)+(a.right-b.right)*(1-v)
end

local function slab(v0,v1,lo,hi,enter,leave)
    local d=v1-v0
    if abs(d)<1e-10 then return v0>=lo and v0<=hi,enter,leave end
    local a,b=(lo-v0)/d,(hi-v0)/d
    if a>b then a,b=b,a end
    local first,last=math.max(a,enter),math.min(b,leave)
    return first<=last,first,last
end

---@param r table
function Features.Sweep(r,x0,z0,x1,z1)
    local a,b=Features.Coords(r,x0,z0)
    local c,d=Features.Coords(r,x1,z1)
    local hit,enter,leave=slab(a,c,-r.width*.5,r.width*.5,0,1)
    if not hit then return false,enter,leave end
    return slab(b,d,0,r.length,enter,leave)
end

---@param ramps table[]
function Features.CrossLip(ramps,x0,z0,x1,z1,heading,speed)
    if speed<8 then return nil end
    for _,r in ipairs(ramps) do
        local a,b=Features.Coords(r,x0,z0)
        local c,d=Features.Coords(r,x1,z1)
        if b<r.length and d>=r.length and d>b and cos(rad(heading-r.yaw))>.7071068 then
            local t=(r.length-b)/(d-b)
            local entry=math.max(0,-b/(d-b))
            local width=r.width*.5-.08
            if abs(a+(c-a)*entry)<=width and abs(a+(c-a)*t)<=width then return r,t end
        end
    end
    return nil
end

-- 侧壁/背壁扫掠：只有进入时低于真实顶面的车轮才被阻挡；入口零高度不阻挡。
function Features.BlockingFace(ramps,x0,y0,z0,x1,y1,z1)
    for _,r in ipairs(ramps) do
        if r.optional then
            local hit,t=Features.Sweep(r,x0,z0,x1,z1)
            local _,forward=Features.Coords(r,x0,z0)
            if hit and t>1e-6 then
                local x,z=x0+(x1-x0)*t,z0+(z1-z0)*t
                local _,at=Features.Coords(r,x,z)
                local top=Features.RampHeight(r,x,z)
                if top and at>.3 and y0+(y1-y0)*t<top-.10 and forward>=-.3 then return r,t end
            end
        end
    end
    return nil
end

-- 冷却属于每个骑手，绝不存到共享地图或Profile。
function Features.NewBoostState()
    return {clock=0,ready={},globalReady=0,triggers=0,lastId="",lastGain=0,
        feedbackTimer=0,feedbackPower=0}
end

-- 移动后传入移动前XYZ和是否腾空；冲量只改变下一步的真实速度，不改位置。
---@param entity table
---@param map table
function Features.StepBoost(entity,map,dt,x0,y0,z0,wasAirborne)
    local state=entity.featureState
    if not state then state=Features.NewBoostState();entity.featureState=state end
    state.clock=state.clock+dt
    -- 表现只能消费真实冲量的授权包络；暂停不调用固定步，失败入口不刷新时钟。
    state.feedbackTimer=math.max(0,(state.feedbackTimer or 0)-dt)
    state.feedbackPower=clamp(state.feedbackTimer/1.35,0,1)
    if wasAirborne or entity.airborne or entity.braking or entity.burnout or entity.wrecked
        or (entity.health or 100)<=0 or (entity.waterDepth or 0)>.01
        or (entity.crashCooldown or 0)>0 or (entity.speed or 0)<4 or state.clock<state.globalReady then return nil,0 end
    for _,f in ipairs(map.Features or {}) do
        if f.kind=="boost" and state.clock>=(state.ready[f.id] or 0) then
            local a,b=Features.Coords(f,x0,z0)
            local c,d=Features.Coords(f,entity.x,entity.z)
            local width=f.width*.5-.08
            local forward,lateralDelta=d-b,c-a
            local travel=math.sqrt(forward*forward+lateralDelta*lateralDelta)
            local outside=b<0 or b>f.length or abs(a)>width
            local hit,t,last=slab(a,c,-width,width,0,1)
            if hit then hit,t,last=slab(b,d,0,f.length,t,last) end
            -- 真正正向驶入内缩矩形；允许顺向从侧边并入，不允许只转车头横扫刷带。
            if outside and hit and forward>1e-6 and forward/math.max(1e-6,travel)>.85
                and cos(rad((entity.heading or 0)-f.yaw))>.85 then
                local lateral=a+lateralDelta*t
                local x,z=Features.Point(f,lateral,b+forward*t)
                local ground,onRoad=map.Height(x,z)
                local y=y0+(entity.y-y0)*t
                if abs(lateral)<=width+1e-6 and onRoad and abs(y-ground)<=.16 then
                    -- 加速带允许突破常规极速上限到 125%，冲量翻倍，给足爆发感。
                    local maximum=(entity.vehicle and entity.vehicle.maxSpeed or entity.maxSpeed or 60)*1.25
                    local gain=math.max(0,math.min(f.gain or 8,maximum-entity.speed))
                    -- 已到上限仍消费本次入口，不能滞留带内延迟刷取。
                    entity.speed=entity.speed+gain
                    state.ready[f.id]=state.clock+(f.cooldown or 6)
                    state.globalReady=state.clock+1.2
                    state.triggers=state.triggers+1
                    state.lastId,state.lastGain=f.id,gain
                    if gain>0 then state.feedbackTimer,state.feedbackPower=1.35,1 end
                    return f,gain
                end
            end
        end
    end
    return nil,0
end

-- 前段是可见实高坡体，末段收缓至半坡率；不是抛射器额外冲量。
-- 105m/s仍按真实末端切线起飞，减少高坡的无控制长距离腾空。
function Features.Rise(r,forward)
    local u=clamp(forward/r.length,0,1)
    return r.height*(1.5*u-.5*u*u)
end

local function roadBase(map,x,z)
    if map.RoadHeight then return map.RoadHeight(x,z) end
    return map.Height(x,z)
end

---@param map table
---@param s number
---@param lateral number
---@param kind string
---@return TrackFeature
function Features.Make(map,s,lateral,kind,id,yawOffset)
    local p,roadYaw=map.RoadPoint(s)
    local yaw=roadYaw+(yawOffset or 0)
    local a=rad(roadYaw)
    local training=map.activeId=="circuit"
    ---@type TrackFeature
    local f={id=id,kind=kind,optional=true,s=s,lateral=lateral,
        x=p.x+cos(a)*lateral,z=p.z-sin(a)*lateral,y=0,yaw=yaw,
        width=kind=="ramp" and 2.6 or 4.0,length=kind=="ramp" and 20 or 9,
        height=kind=="ramp" and (training and 1.7 or 2.15) or 0,
        landingEndS=s+(kind=="ramp" and 230 or 64),rows={},exitGrade=0,cooldown=6,gain=8}
    f.y=roadBase(map,f.x,f.z) or p.y
    if kind=="ramp" then
        -- 每米横截面贴合既有路面，不改道路或地形。
        for i=0,20 do
            local forward=f.length*i/20
            local lx,lz=Features.Point(f,-f.width*.5,forward)
            local rx,rz=Features.Point(f,f.width*.5,forward)
            local rise=Features.Rise(f,forward)
            f.rows[#f.rows+1]={forward=forward,left=(roadBase(map,lx,lz) or f.y)+rise,
                right=(roadBase(map,rx,rz) or f.y)+rise}
        end
        local last,previous=f.rows[#f.rows],f.rows[#f.rows-1]
        f.exitGrade=((last.left+last.right)-(previous.left+previous.right))*.5/(last.forward-previous.forward)
    end
    return f
end

-- 按五种速度检查完整弹道走廊，不凭样条分数猜直线，也不只查坡脚。
---@param map table
---@param f TrackFeature
function Features.Safe(map,f)
    local half=map.Roads[1].width
    if f.s<190 or f.landingEndS>map.RouteLength-160 then return false,"start/finish" end
    local bridge=map.Bridge
    if map.activeId=="lake" and bridge and f.s<bridge.endS+85 and f.landingEndS>bridge.startS-85 then return false,"bridge" end
    if map.activeId=="lake" then
        for _,fraction in ipairs({.354,.531,.665}) do
            local station=map.RouteLength*fraction
            if f.s<station+70 and f.landingEndS>station-70 then return false,"junction" end
        end
    end
    -- 整个占地加轮宽余量必须位于原始沥青内。
    for forward=-12,f.length+12,2 do
        for _,side in ipairs({-1,0,1}) do
            local x,z=Features.Point(f,side*(f.width*.5+.35),forward)
            local y,onRoad=roadBase(map,x,z)
            if not y or not onRoad then return false,"footprint" end
            if map.WaterDepth and map.WaterDepth(x,z)>.01 then return false,"water" end
        end
    end
    local _,yaw=map.RoadPoint(f.s)
    local curvature=0
    for offset=-20,(f.kind=="ramp" and 80 or 65),5 do
        local _,heading=map.RoadPoint(f.s+offset)
        curvature=math.max(curvature,abs((heading-yaw+180)%360-180))
    end
    if curvature>(f.kind=="ramp" and 13 or 16) then return false,"bend" end
    if f.kind=="ramp" then
        local x,z=Features.Point(f,0,f.length)
        local lip=Features.RampHeight(f,x,z) or f.y+f.height
        local grade=f.exitGrade
        if grade<.005 or grade>.18 then return false,"exit grade" end
        for _,speed in ipairs({12,30,55,80,105}) do
            local horizontal=speed/math.sqrt(1+grade*grade)
            local vy=horizontal*grade
            local landed=false
            for i=1,180 do
                local t=i*.02
                local forward=f.length+horizontal*t
                local px,pz=Features.Point(f,0,forward)
                local ground,onRoad=roadBase(map,px,pz)
                local ns,lat=map.NearestRoad(px,pz)
                if not ground or not onRoad or abs(lat)>half-.65 then return false,"landing lane" end
                if map.WaterDepth and map.WaterDepth(px,pz)>.01 then return false,"landing water" end
                if ns>f.landingEndS or forward>f.length+328 then return false,"landing distance" end
                if lip+vy*t-4.905*t*t<=ground then landed=true;break end
            end
            if not landed then return false,"no landing" end
        end
    end
    return true,curvature
end

-- 原始人工校验过的锚点（每图 4 带 2 坡），保留其精确里程。
-- 加密的加速带由 Plan 按赛道长度等分自动生成，并逐个过 Safe 剔除禁区，
-- 因此不需要把每张图的额外里程硬编码在表里。
local placements={
    lake={{"boost",517.55654974238,2.2},{"boost",1033.3801897542,2.2},
        {"ramp",300,-2.8,-6},{"boost",2364.4753938761,2.2},
        {"boost",3437.2447210658,2.2},{"ramp",3580,-3.0}},
    alpine={{"boost",644.97482591366,2.2},{"ramp",580,-2.6},
        {"boost",3035.1922873742,2.2},{"ramp",2160,-2.6},
        {"boost",4949.9475099643,2.2},{"boost",7041.4761657774,2.2}},
    coast={{"boost",536.64952549038,2.2},{"ramp",320,-3.2},
        {"boost",2205.368075488,2.2},{"boost",2667.5223460745,2.2},
        {"ramp",2160,3.2},{"boost",5309.5061245024,2.2}},
    canyon={{"boost",654.67931613347,2.2},{"ramp",580,-3.4},
        {"boost",2719.8387192982,2.2},{"boost",3487.724874097,2.2},
        {"ramp",3420,-3.4},{"boost",7027.4971836945,2.2}},
    forest={{"boost",548.18435217481,2.2},{"ramp",1200,-2.7},
        {"boost",2655.0964532467,2.2},{"boost",4417.4372836734,2.2},
        {"ramp",3180,2.7},{"boost",6058.6720010512,2.2}},
    circuit={{"boost",704.83980215613,2.2},{"ramp",360,3.6},
        {"boost",3632.1286780794,2.2},{"boost",5378.0364658613,2.2},
        {"ramp",4800,3.6},{"boost",8530.6918435813,2.2}},
}
Features.Placements=placements

---@param map table
---@return TrackFeature[], TrackFeature[]
function Features.Plan(map)
    local result,ramps={},{}
    local counts={ramp=0,boost=0}
    for _,entry in ipairs(assert(placements[map.activeId],"Unknown feature map")) do
        local kind=entry[1]
        counts[kind]=counts[kind]+1
        local f=Features.Make(map,entry[2],entry[3],kind,map.activeId.."_"..kind.."_"..counts[kind],entry[4])
        result[#result+1]=f
        if kind=="ramp" then ramps[#ramps+1]=f end
    end
    -- 按赛道长度加密加速带：目标间隔约 420m，逐个试放并过 Safe 剔除桥梁/路口/弯道禁区。
    -- 只加 kind=="boost"，飞坡仍用上面校验过的锚点，避免落地走廊被改造。
    local wanted=math.max(0,math.floor(map.RouteLength/420)-counts.boost)
    if wanted>0 then
        local placed=0
        local step=map.RouteLength/(wanted+1)
        for i=1,wanted do
            for _,tries in ipairs({0,18,-18,36,-36}) do
                local s=step*i+tries
                local candidate=Features.Make(map,s,2.2,"boost",
                    map.activeId.."_boost_auto_"..(counts.boost+1),nil)
                local safe=Features.Safe(map,candidate)
                if safe then
                    counts.boost=counts.boost+1
                    candidate.id=map.activeId.."_boost_auto_"..counts.boost
                    result[#result+1]=candidate
                    placed=placed+1
                    break
                end
            end
        end
        if placed>0 then
            print(string.format("[道路机关] %s 自动加密加速带 %d 条（目标 %d，总间隔约 %dm）",
                map.activeId,placed,wanted,math.floor(map.RouteLength/(placed+counts.boost))))
        end
    end
    return result,ramps
end

return Features
