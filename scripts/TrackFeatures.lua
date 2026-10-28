-- 确定性道路机关；无引擎对象、外部资产、存档或随机数。
local Features = {}
local abs, sin, cos, rad = math.abs, math.sin, math.cos, math.rad
local function clamp(v,a,b) return math.max(a,math.min(b,v)) end

-- 碰撞设计（米；轮胎接触点，不是渲染包围盒）：
-- 俯视：    可用沥青车道                           前进 +z
--       |  中心绕行净空 | [可选飞坡] |                 ^
--       |              |    / 唇口 --->150米检查走廊   |
--       | >>> 加速带 >>>（部分车道，单向入口）          |
-- 侧视：路面 ____/ 真实采样楔形 | . 重力弹道 . ____ 路面
-- 加速带扫掠p0--p1跨入口，宽边内缩.08米；擦边不激活，高速一步跨整带不漏判。
-- 逆向、侧入、静止、腾空、刹车或损坏不增益。
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
function Features.NewBoostState() return {clock=0,ready={},globalReady=0,triggers=0,lastId="",lastGain=0} end

-- 移动后传入移动前XYZ和是否腾空；冲量只改变下一步的真实速度，不改位置。
---@param entity table
---@param map table
function Features.StepBoost(entity,map,dt,x0,y0,z0,wasAirborne)
    local state=entity.featureState
    if not state then state=Features.NewBoostState();entity.featureState=state end
    state.clock=state.clock+dt
    if wasAirborne or entity.airborne or entity.braking or entity.burnout or entity.wrecked
        or (entity.health or 100)<=0 or (entity.waterDepth or 0)>.01
        or (entity.crashCooldown or 0)>0 or (entity.speed or 0)<4 or state.clock<state.globalReady then return nil,0 end
    for _,f in ipairs(map.Features or {}) do
        if f.kind=="boost" and state.clock>=(state.ready[f.id] or 0) then
            local a,b=Features.Coords(f,x0,z0)
            local c,d=Features.Coords(f,entity.x,entity.z)
            if b<0 and d>=0 and d>b and cos(rad((entity.heading or 0)-f.yaw))>.85 then
                local t=-b/(d-b)
                local lateral=a+(c-a)*t
                local x,z=Features.Point(f,lateral,0)
                local ground,onRoad=map.Height(x,z)
                local y=y0+(entity.y-y0)*t
                if abs(lateral)<=f.width*.5-.08 and onRoad and abs(y-ground)<=.16 then
                    local maximum=(entity.vehicle and entity.vehicle.maxSpeed or entity.maxSpeed or 60)*1.08
                    local gain=math.max(0,math.min(f.gain or 4.5,maximum-entity.speed))
                    -- 已到上限仍消费本次入口，不能滞留带内延迟刷取。
                    entity.speed=entity.speed+gain
                    state.ready[f.id]=state.clock+(f.cooldown or 8)
                    state.globalReady=state.clock+2.5
                    state.triggers=state.triggers+1
                    state.lastId,state.lastGain=f.id,gain
                    return f,gain
                end
            end
        end
    end
    return nil,0
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
function Features.Make(map,s,lateral,kind,id)
    local p,yaw=map.RoadPoint(s)
    local a=rad(yaw)
    local training=map.activeId=="circuit"
    ---@type TrackFeature
    local f={id=id,kind=kind,optional=true,s=s,lateral=lateral,
        x=p.x+cos(a)*lateral,z=p.z-sin(a)*lateral,y=0,yaw=yaw,
        width=kind=="ramp" and 2.6 or 4.0,length=kind=="ramp" and 24 or 9,
        height=kind=="ramp" and (training and .55 or .85) or 0,
        landingEndS=s+(kind=="ramp" and 174 or 64),rows={},exitGrade=0,cooldown=8,gain=4.5}
    f.y=roadBase(map,f.x,f.z) or p.y
    if kind=="ramp" then
        -- 每米横截面贴合既有路面，不改道路或地形。
        for i=0,24 do
            local forward=f.length*i/24
            local lx,lz=Features.Point(f,-f.width*.5,forward)
            local rx,rz=Features.Point(f,f.width*.5,forward)
            f.rows[#f.rows+1]={forward=forward,left=(roadBase(map,lx,lz) or f.y)+f.height*i/24,
                right=(roadBase(map,rx,rz) or f.y)+f.height*i/24}
        end
        local last,previous=f.rows[#f.rows],f.rows[#f.rows-1]
        f.exitGrade=((last.left+last.right)-(previous.left+previous.right))*.5
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
        if grade<.005 or grade>.14 then return false,"exit grade" end
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
                if ns>f.landingEndS or forward>f.length+148 then return false,"landing distance" end
                if lip+vy*t-4.905*t*t<=ground then landed=true;break end
            end
            if not landed then return false,"no landing" end
        end
    end
    return true,curvature
end

-- 离线全搜索后的固定站位；每图4带2坡，每次建图只采样300个左右顶点。
-- 原搜索实测湖图20.5秒/高山63.3秒，故绝不把候选扫描放入游戏加载帧。
-- 每项为{kind,s,lateral}，s是现有主路水平里程，不改变控制点。
local placements={
    lake={{"boost",517.55654974238,2.2},{"boost",1033.3801897542,2.2},
        {"ramp",1735.7060666863,3.6},{"boost",2364.4753938761,2.2},
        {"boost",3437.2447210658,2.2},{"ramp",3637.1271477403,3.6}},
    alpine={{"boost",644.97482591366,2.2},{"ramp",1420.7391538202,3.12},
        {"boost",3035.1922873742,2.2},{"ramp",3794.5195504966,3.12},
        {"boost",4949.9475099643,2.2},{"boost",7041.4761657774,2.2}},
    coast={{"boost",536.64952549038,2.2},{"ramp",1047.2138049014,-3.84},
        {"boost",2205.368075488,2.2},{"boost",2667.5223460745,2.2},
        {"ramp",4314.3261421515,3.84},{"boost",5309.5061245024,2.2}},
    canyon={{"boost",654.67931613347,2.2},{"ramp",1186.6129064327,4.08},
        {"boost",2719.8387192982,2.2},{"boost",3487.724874097,2.2},
        {"ramp",5172.9317127623,4.08},{"boost",7027.4971836945,2.2}},
    forest={{"boost",548.18435217481,2.2},{"ramp",1232.5712706452,3.24},
        {"boost",2655.0964532467,2.2},{"boost",4417.4372836734,2.2},
        {"ramp",5064.0546423623,3.24},{"boost",6058.6720010512,2.2}},
    circuit={{"boost",704.83980215613,2.2},{"ramp",2754.4344874226,4.32},
        {"boost",3632.1286780794,2.2},{"boost",5378.0364658613,2.2},
        {"ramp",6965.8374550807,4.32},{"boost",8530.6918435813,2.2}},
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
        local f=Features.Make(map,entry[2],entry[3],kind,map.activeId.."_"..kind.."_"..counts[kind])
        result[#result+1]=f
        if kind=="ramp" then ramps[#ramps+1]=f end
    end
    return result,ramps
end

return Features
