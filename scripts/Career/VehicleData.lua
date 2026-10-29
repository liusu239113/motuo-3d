-- 城市车辆规则与存档边界；与赛道动力、旧竞速Profile隔离。
local Data={}
local LIMIT=require("Career.WorldData").LIMIT
Data.EBIKE="borrowed_ebike"
Data.Ids={"sport","cruiser","rally","sport_2","sport_3","cruiser_2","cruiser_3","rally_2","rally_3"}
Data.Names={borrowed_ebike="9号电动车",sport="赤焰R1000",cruiser="远行V1700",rally="荒野Enduro",
    sport_2="冰锋RR",sport_3="银隼750",cruiser_2="赤铜Classic",cruiser_3="暗峰Muscle",rally_2="雪脊Trail",rally_3="沙隼Dakar"}
-- 保守包围圆：用VehicleAssets实测整车长宽对角线的一半并留余量。
Data.Radii={borrowed_ebike=1.2,sport=1.25,cruiser=1.45,rally=1.3,sport_2=1.3,sport_3=1.3,
    cruiser_2=1.5,cruiser_3=1.4,rally_2=1.3,rally_3=1.3}
Data.Parking={x=108,z=76,yaw=0}
function Data.Known(id) return Data.Names[id]~=nil end
function Data.Active(p) return p.position.activeVehicle or Data.EBIKE end
local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
function Data.ValidPosition(pos,owned)
    local id=pos.activeVehicle or Data.EBIKE
    if not Data.Known(id) or (id~=Data.EBIKE and not owned[id]) then return false end
    local parks=pos.vehicleParking
    if parks~=nil then
        if type(parks)~="table" then return false end
        for key,park in pairs(parks) do
            if not Data.Known(key) or (key~=Data.EBIKE and not owned[key]) or type(park)~="table"
                or not finite(park.x) or not finite(park.z) or not finite(park.yaw)
                or math.abs(park.x)>LIMIT or math.abs(park.z)>LIMIT then return false end
        end
        local active=parks[id]
        if not active or active.x~=pos.bikeX or active.z~=pos.bikeZ or active.yaw~=pos.bikeYaw then return false end
    elseif id~=Data.EBIKE then return false end
    return true
end
return Data
