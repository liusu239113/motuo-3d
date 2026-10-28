-- 车行取车：只允许已拥有车型，先校验/存盘，成功后切换模型；不召回停车在别处的车辆。
local Store=require("Career.Store")
local Data=require("Career.VehicleData")
local Assets=require("VehicleAssets")
local Loader=require("RideLoader")
local Actions={}
function Actions.Resources(profile)
    local ids={}
    for id in pairs(profile.position.vehicleParking or {}) do if id~=Data.EBIKE then ids[#ids+1]=id end end
    local paths=Assets.ResourcesFor(ids)
    return paths,Assets.ResourceTypes
end
function Actions.Switch(session,id)
    local allowed,message=session:Allowed("dealer")
    if not allowed then session.waypoint="dealer"; session.view:Notice(message); return false end
    local p=Store.Get()
    if not Data.Known(id) or (id~=Data.EBIKE and not p.ownedMotorcycles[id]) then
        session.view:Notice("请先购买这辆摩托"); return false
    end
    if #p.activeOrders>0 then session.view:Notice("先完成配送再换车，订单需要9号的保温箱"); return false end
    local a=assert(session.actor)
    if a.vehicleId==id then session.view:Notice("当前已使用这辆车"); return false end
    local pos=session:PositionSnapshot()
    local parks=pos.vehicleParking
    if not parks[id] then
        local park=Data.Parking
        if not session.city:IsFree(park.x,park.z,Data.Radii[id]) then session.view:Notice("车行交车位被阻挡"); return false end
        -- 多辆车逐个交付到独立车位；不覆盖已在街上停放的车型。
        local z=park.z
        for _=1,12 do
            local occupied=false
            for _,other in pairs(parks) do
                if (other.x-park.x)^2+(other.z-z)^2<16 then occupied=true; break end
            end
            if not occupied and session.city:IsFree(park.x,z,Data.Radii[id]) then break end
            z=z-4
        end
        if not session.city:IsFree(park.x,z,Data.Radii[id]) then session.view:Notice("暂无可用交车位"); return false end
        parks[id]={x=park.x,z=z,yaw=park.yaw}
    end
    local function complete()
        -- 异步下载期间不推进模拟；重新验证实际持有、位置与订单，不提交过期快照。
        local ok,detail=session:Allowed("dealer")
        if not ok then session.view:Notice(detail); return false end
        local state=Store.Get()
        if #state.activeOrders>0 then session.view:Notice("请先完成配送"); return false end
        local park=parks[id]
        pos.activeVehicle=id; pos.bikeX,pos.bikeZ,pos.bikeYaw=park.x,park.z,park.yaw
        local saved,reason=Store.Transaction(function(draft)
            if id~=Data.EBIKE and not draft.ownedMotorcycles[id] then return false,"尚未拥有车辆" end
            draft.position=pos
            return true,"已选择"..Data.Names[id].."，请走到车旁上车；原车辆留在原地"
        end)
        if not saved then session.view:Notice(reason); return false end
        session:RestorePosition(); session.online=false
        session.view:ClosePhone(); session.view:ResetInput(); session:Refresh(); session.view:Notice(reason)
        print("[城市换车] "..id.."；原停车位保留，未自动骑乘")
        return true
    end
    local paths=id~=Data.EBIKE and Assets.ResourcesFor({id}) or {}
    local ready=true
    for _,path in ipairs(paths) do if not cache:Exists(path) then ready=false; break end end
    if ready then return complete() end
    session.loading=true
    session.view:ClosePhone(); session.view.controls:SetEnabled(false)
    session.loader=Loader.New({},function(title,detail,fraction) session.view:ShowLoading(title,detail,fraction) end,
        function()
            session.loading=false; session.view:ShowGame()
            complete()
        end,function(detail)
            session.loading=false; session.view:ShowGame(); session.view:Notice(detail)
        end,paths,Assets.ResourceTypes)
    session.loader:Start()
    return true
end
return Actions
