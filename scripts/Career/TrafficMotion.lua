-- Shared traffic shell geometry. Traffic following buffers remain behavioural
-- only; actual occupancy is the same visible model footprint as Actor/parking.
local C=require("Career.FootprintCollision")
local F=require("Career.VehicleFootprints")
local M={}
function M.Shape(car)
    if car.shapeX==car.x and car.shapeZ==car.z and car.shapeYaw==car.yaw and car.shell then return car.shell end
    local shape=car.id and F.Get(car.id) or C.Box(-car.width/2,-car.length/2,car.width/2,car.length/2)
    car.shell=C.Pose(shape,car.x,car.z,car.yaw)
    car.shapeX,car.shapeZ,car.shapeYaw=car.x,car.z,car.yaw
    return car.shell
end
function M.CircleFree(car,x,z,r) return C.Free(M.Shape(car),C.Circle(x,z,r),C.SKIN) end
function M.BlockerFree(car,b)
    return C.Free(M.Shape(car),b.shape or C.Circle(b.x,b.z,b.radius),C.SKIN)
end
function M.Separate(a,b)
    local reachA=a.length/2+a.width/2
    local reachB=b.length/2+b.width/2
    if (a.x-b.x)^2+(a.z-b.z)^2>(reachA+reachB+.01)^2 then return true end
    return C.Free(M.Shape(a),M.Shape(b),C.SKIN)
end
function M.StaticFree(city,car)
    local shape=car.id and F.Get(car.id) or C.Box(-car.width/2,-car.length/2,car.width/2,car.length/2)
    return city:StaticShapeFree(car.x,car.z,shape,car.yaw,"vehicle",0)
end
return M
