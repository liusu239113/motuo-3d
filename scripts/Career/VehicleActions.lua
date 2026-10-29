-- 车行取车：只允许已拥有车型，先校验/存盘，成功后切换模型；不召回停车在别处的车辆。
local Store=require("Career.Store")
local Data=require("Career.VehicleData")
local Assets=require("VehicleAssets")
local Loader=require("RideLoader")
local Footprints=require("Career.VehicleFootprints")
local Collision=require("Career.FootprintCollision")
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
    -- 模型可能尚未下载：精确占地、最新位置快照与交车位选择都推迟到complete。
    -- 不在下载前以外接大圆拒绝，也不提前改停车表或持久化旧快照。
    local completed=false
    local function complete()
        if completed or session.disposed then return false end
        -- 下载回调重新核验；任何失败都只通知，不切换Actor、不创建车辆模型。
        local ok,detail=session:Allowed("dealer")
        if not ok then session.view:Notice(detail); return false end
        local state=Store.Get()
        if id~=Data.EBIKE and not state.ownedMotorcycles[id] then session.view:Notice("尚未拥有车辆"); return false end
        if #state.activeOrders>0 then session.view:Notice("请先完成配送"); return false end
        if a.vehicleId==id then session.view:Notice("当前已使用这辆车"); return false end
        local pos=session:PositionSnapshot()
        local parks=pos.vehicleParking
        local shape=Footprints.Get(id) -- 仅资源ready后读取真实LOD0
        local function available(park)
            if not session.city:IsShapeFree(park.x,park.z,shape,park.yaw,"vehicle",0,id) then return false end
            local candidate=Collision.Pose(shape,park.x,park.z,park.yaw)
            -- 快照可能比Actor.parking更新；两者都校验，绝不只比车心4米。
            for otherId,other in pairs(parks) do
                if otherId~=id and not Collision.Free(candidate,Footprints.At(otherId,other.x,other.z,other.yaw),Collision.SKIN) then return false end
            end
            local person=Collision.Pose(a:Footprint(),a.x,a.z,a.yaw)
            return Collision.Free(candidate,person,Collision.SKIN)
        end
        local park=parks[id]
        if park then
            -- 已交付车辆只选择原位置，不因换车按钮召回或替它挪车。
            if not available(park) then session.view:Notice("车辆原停车位被占用，请先移开障碍物"); return false end
        else
            local base=Data.Parking
            for i=1,12 do
                local candidate={x=base.x,z=base.z-(i-1)*4,yaw=base.yaw}
                if available(candidate) then park=candidate;break end
            end
            if not park then session.view:Notice("暂无可用交车位"); return false end
            parks[id]=park
        end
        pos.activeVehicle=id; pos.bikeX,pos.bikeZ,pos.bikeYaw=park.x,park.z,park.yaw
        pos.mounted=false
        local saved,reason=Store.Transaction(function(draft)
            if id~=Data.EBIKE and not draft.ownedMotorcycles[id] then return false,"尚未拥有车辆" end
            if #draft.activeOrders>0 then return false,"请先完成配送" end
            draft.position=pos
            return true,"已选择"..Data.Names[id].."，请走到车旁上车；原车辆留在原地"
        end)
        if not saved then session.view:Notice(reason); return false end
        completed=true
        session:RestorePosition(); session.online=false
        session.view:ClosePhone(); session.view:ResetInput(); session:Refresh(); session.view:Notice(reason)
        print("[城市换车] "..id.."；真实模型占地校验通过，原停车位保留，未自动骑乘")
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
