-- 真实车道挡路反应；只消费已有车辆/玩家包络，不改变速度、碰撞、存档或路权。
local Motion=require("Career.TrafficMotion")
local Routes=require("Career.TrafficRoutes")
local Reactions={}
-- 暂停/离场只清等待，不清冷却；恢复必须重新连续挡路，不能补播旧反应。
function Reactions.ResetWaiting(traffic)
    for _,car in ipairs(traffic.cars or {}) do car.blockedByPlayer=0 end
    if traffic.outer then
        for _,car in ipairs(traffic.outer.cars) do car.blockedByPlayer=0 end
    end
end
-- 俯视（米）：车头 [长/2] -> 0..6m等待区；横向为车半宽+玩家实际半径。
-- 仅同垂直区间/骑乘停稳/前方直接被玩家挡住；红灯、其他车排队均不归咎玩家。
function Reactions.Blocked(traffic,car,actor,signalBlocked,cars)
    if not actor.mounted or math.abs(actor.speed or 0)>.6 or (car.speed or 0)>.7 or signalBlocked then return false end
    if (actor.x-car.x)^2+(actor.z-car.z)^2>18^2 then return false end
    local a=math.rad(car.yaw)
    local dx,dz=actor.x-car.x,actor.z-car.z
    local across,forward=dx*math.cos(a)-dz*math.sin(a),dx*math.sin(a)+dz*math.cos(a)
    local radius=actor:VehicleRadius()
    if forward<car.length/2 or forward>car.length/2+radius+6
        or math.abs(across)>car.width/2+radius+.2 then return false end
    local c1,c2=Motion.VehicleInterval(traffic.city,car)
    local a1,a2=Motion.VehicleInterval(traffic.city,{x=actor.x,z=actor.z,vehicleId=actor.vehicleId})
    if not Motion.VerticalOverlap(c1,c2,a1,a2) then return false end
    for _,other in ipairs(cars) do
        if other~=car then
            local ox,oz=other.x-car.x,other.z-car.z
            local u,v=ox*math.cos(a)-oz*math.sin(a),ox*math.sin(a)+oz*math.cos(a)
            if v>0 and v<forward and math.abs(u)<(car.width+other.width)/2+.3 then return false end
        end
    end
    return true
end
function Reactions.Update(traffic,dt,audio)
    if not audio or audio.paused or not traffic.active or traffic.disposed or traffic.city.space~="city"
        or type(dt)~="number" or dt~=dt or math.abs(dt)==math.huge or dt<=0 then
        Reactions.ResetWaiting(traffic)
        return
    end
    local step=math.min(.1,dt)
    traffic.reactionCooldown=math.max(0,(traffic.reactionCooldown or 0)-step)
    local selected
    local function scan(cars,outer)
        for _,car in ipairs(cars) do
            if (traffic.actor.x-car.x)^2+(traffic.actor.z-car.z)^2>18^2 then
                car.blockedByPlayer=0
                car.reactionCooldown=math.max(0,(car.reactionCooldown or 0)-step)
                goto nextCar
            end
            local signalBlocked
            if outer then
                signalBlocked=outer.signals:Gap(car,cars)<12
            else
                signalBlocked=Routes.Signal(traffic.time,car.route.axis)~="green"
                    and Routes.StopGap(car.route,car.s,car.length)<12 or traffic:CrossingBusy(car)
            end
            car.reactionCooldown=math.max(0,(car.reactionCooldown or 0)-step)
            if Reactions.Blocked(traffic,car,traffic.actor,signalBlocked,cars) then
                car.blockedByPlayer=(car.blockedByPlayer or 0)+step
                if car.blockedByPlayer>=2.5 and car.reactionCooldown==0 and not selected then selected=car end
            else car.blockedByPlayer=0 end
            ::nextCar::
        end
    end
    if traffic.nearOld then scan(traffic.cars)
    else for _,car in ipairs(traffic.cars) do car.blockedByPlayer=0 end end
    if traffic.outer then
        if traffic.outer.active then scan(traffic.outer.cars,traffic.outer)
        else for _,car in ipairs(traffic.outer.cars) do car.blockedByPlayer=0 end end
    end
    if selected and traffic.reactionCooldown==0 and audio:TrafficReaction(selected,traffic.actor) then
        selected.reactionCooldown=25; selected.blockedByPlayer=0;traffic.reactionCooldown=8
    end
end
return Reactions
