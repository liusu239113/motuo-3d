-- 老街首片区车道：直行往返环线，端点用半径3m的连续半圆掉头，不传送车辆。
local Routes={}
Routes.STRAIGHT=310
Routes.ARC=math.pi*3
Routes.LENGTH=620+math.pi*6
Routes.List={
    {axis="ns",road=-100},{axis="ns",road=0},{axis="ns",road=100},
    {axis="ew",road=0},{axis="ew",road=100},
}
Routes.Junctions={}
for _,x in ipairs({-100,0,100}) do
    for _,z in ipairs({0,100}) do Routes.Junctions[#Routes.Junctions+1]={x=x,z=z} end
end

---@param route table
---@param distance number
---@return number,number,number,number,number
function Routes.Pose(route,distance)
    local s=distance%Routes.LENGTH
    local u,v,yaw=3,-155+s,0
    if s>=Routes.STRAIGHT and s<Routes.STRAIGHT+Routes.ARC then
        local a=(s-Routes.STRAIGHT)/3
        u,v,yaw=3*math.cos(a),155+3*math.sin(a),-math.deg(a)
    elseif s>=Routes.STRAIGHT+Routes.ARC and s<2*Routes.STRAIGHT+Routes.ARC then
        u,v,yaw=-3,155-(s-Routes.STRAIGHT-Routes.ARC),180
    elseif s>=2*Routes.STRAIGHT+Routes.ARC then
        local a=math.pi+(s-2*Routes.STRAIGHT-Routes.ARC)/3
        u,v,yaw=3*math.cos(a),-155+3*math.sin(a),-math.deg(a)
    end
    if route.axis=="ew" then return v,route.road-u,yaw+90,u,v end
    return route.road+u,v,yaw,u,v
end

-- 42秒一周期：16绿+3黄+2全红，再交换方向；黄灯不新增入场车辆。
---@param seconds number
---@param axis string
---@return string
function Routes.Signal(seconds,axis)
    local t=seconds%42
    if axis=="ew" then t=(t+21)%42 end
    return t<16 and "green" or t<19 and "yellow" or "red"
end

-- 返回前保险杠到停止线的有符号距离；越线后不在路口中央急停。
function Routes.StopGap(route,s,length)
    local p=s%Routes.LENGTH
    local ascending=p<Routes.STRAIGHT
    local descending=p>=Routes.STRAIGHT+Routes.ARC and p<2*Routes.STRAIGHT+Routes.ARC
    if not ascending and not descending then return math.huge end
    local _,_,_,_,v=Routes.Pose(route,s)
    local best=math.huge
    for _,j in ipairs(Routes.Junctions) do
        if (route.axis=="ns" and j.x==route.road) or (route.axis=="ew" and j.z==route.road) then
            local cross=route.axis=="ns" and j.z or j.x
            local gap=ascending and cross-12-length/2-v or v-cross-12-length/2
            if gap>=-.02 then best=math.min(best,math.max(0,gap)) end
        end
    end
    return best
end
return Routes
