-- 正式静态MDL的机械关节：只重分配原三角面，所有LOD共享各自源VB。
-- 坐标均为源模型米：+X前、+Y上、±Z左右。禁止把Body摆动当作关节动画。
local Parts = require("MixedMeshParts")
local M = {}
local V = Vector3
local wheelStations = {-.399,-.280,-.165,-.043,.077,.192,.313,.415}

---@param _ number
---@param _ number
---@param _ number
---@param piece BoundingBox?
---@return string
local function tankPart(_,_,_,piece)
    if not piece then return "Body" end
    local lo,hi,size,center=piece.min,piece.max,piece.size,piece.center
    if lo.x>.15 and lo.y>.09 and hi.y<.18 and math.max(math.abs(lo.z),math.abs(hi.z))<.05 then
        return "Barrel"
    end
    -- 炮塔壳跨越y=.075，必须整件纳入；其余完整高位附件随壳转动。
    if lo.y>.075 or (lo.y>.05 and size.x>.45 and hi.y>.20) then return "Turret" end
    -- 排除长履带、悬挂和挡泥板；16只真实轮体在四级LOD均为独立连通件。
    if hi.y<-.035 and size.x>.08 and size.x<.15 and size.y>.08 and size.y<.15 and math.abs(center.z)>.23 then
        local station,best=1,math.huge
        for i,x in ipairs(wheelStations) do
            local delta=math.abs(center.x-x)
            if delta<best then station,best=i,delta end
        end
        return (center.z>0 and "WheelP" or "WheelN")..station
    end
    return "Body"
end

---@param _ number
---@param _ number
---@param _ number
---@param piece BoundingBox?
---@return string
local function beetlePart(_,_,_,piece)
    if not piece then return "Body" end
    local lo,hi,center=piece.min,piece.max,piece.center
    local side=center.z>0 and "P" or "N"
    -- 两侧颚的外壳、内钳、根部活塞与铆钉，整件归组；跨中线的嘴部留在Body。
    if lo.x>.12 and hi.y<-.025 and (lo.z>.015 or hi.z<-.015)
        and math.max(math.abs(lo.z),math.abs(hi.z))<.23 then return "Jaw"..side end
    if (lo.z>.125 or hi.z<-.125) and hi.y<.075 then
        local station=center.x<-.10 and 1 or (center.x<.04 and 2 or 3)
        if (station==1 and hi.x<-.06) or (station==2 and lo.x>-.09 and hi.x<.04)
            or (station==3 and lo.x>.025 and hi.x<.23) then return "Leg"..side..station end
    end
    return "Body"
end

---@param id string
---@param name string
---@param model Model
---@return Vector3
local function pivotFor(id,name,model)
    if id=="tank" then
        if name=="Turret" then return V(-.117,.060,0) end
        if name=="Barrel" then return V(.157,.132,.0022) end
        if name:match("^Wheel") then return model.boundingBox.center end
    else
        local side=name:find("P",1,true) and 1 or -1
        if name:match("^Jaw") then return V(.185,-.095,side*.095) end
        local station=tonumber(name:match("^Leg[PN](%d)$"))
        if station==1 then return V(-.132,-.067,side*.165) end
        if station==2 then return V(-.028,-.10,side*.211) end
        if station==3 then return V(.069,-.096,side*.165) end
    end
    return V.ZERO
end

---@param canonical Node
---@param id string
---@param source Model
---@param material Material
function M.Build(canonical,id,source,material)
    local parts=Parts.Extract(source,id.."_formal_articulation_v1",id=="tank" and tankPart or beetlePart,true)
    assert(parts.Body,"正式机械载具必须保留独立Body")
    local required=id=="tank" and {"Turret","Barrel"} or {"JawP","JawN","LegP1","LegP2","LegP3","LegN1","LegN2","LegN3"}
    if id=="tank" then
        for _,side in ipairs({"P","N"}) do
            for station=1,8 do required[#required+1]="Wheel"..side..station end
        end
    end
    for _,name in ipairs(required) do assert(parts[name],"正式原网格缺少独立部件："..name) end
    ---@type table<string,Node>
    local pivots={}
    for name,part in pairs(parts) do
        local pivot=canonical:CreateChild(name)
        local center=pivotFor(id,name,part.model)
        pivot.position=center
        pivot:SetVar("RestPosition",Variant(center))
        local mesh=pivot:CreateChild("OriginalMesh")
        mesh.position=-center
        local draw=mesh:CreateComponent("StaticModel")
        draw:SetModel(part.model)
        draw:SetMaterial(material)
        draw.castShadows=true
        draw.lodBias=2
        pivots[name]=pivot
        for lod=0,source:GetNumGeometryLodLevels(0)-1 do
            local geometry=assert(part.model:GetGeometry(0,lod),name.."必须保留全部原LOD")
            assert(geometry:GetVertexBuffer(0)==source:GetGeometry(0,lod):GetVertexBuffer(0),"禁止改写源VB/UV")
        end
    end
    if id=="tank" then
        -- 炮管必须继承炮塔水平旋转，源顶点仍不变，网格子节点抵消源坐标铰点。
        local barrel,turret=pivots.Barrel,pivots.Turret
        barrel:SetParent(turret)
        local rest=V(.157,.132,.0022)-turret.position
        barrel.position=rest
        barrel:SetVar("RestPosition",Variant(rest))
    end
    canonical:SetVar("ArticulationReady",Variant(true))
end

---@param root Node
---@param name string
---@param rotation Quaternion
local function rotate(root,name,rotation)
    local node=assert(root:GetChild(name,true),"正式关节丢失："..name)
    node.rotation=rotation
end

---@param root Node
---@param id string
---@param time number
---@param state table?
function M.Animate(root,id,time,state)
    local distance=state and state.distance or 0
    local active=state and (state.oddActive or 0)>0
    if id=="tank" then
        local scale=root:GetChild("SourceTransform"):GetScale().x
        for _,side in ipairs({"P","N"}) do
            for station=1,8 do
                local wheel=assert(root:GetChild("Wheel"..side..station,true))
                local radius=(station==1 or station==8) and .059 or .054
                wheel.rotation=Quaternion(-distance/(radius*scale)*180/math.pi%360,V.FORWARD)
            end
        end
        local steer=state and state.steer or 0
        local yaw=math.max(-1,math.min(1,steer))*12+(active and math.sin(time*7)*7 or 0)
        rotate(root,"Turret",Quaternion(yaw,V.UP))
        local barrel=assert(root:GetChild("Barrel",true))
        local rest=barrel:GetVar("RestPosition"):GetVector3()
        local recoil=active and math.max(0,math.sin(time*18))*.009 or 0
        barrel.position=rest+V(-recoil,0,0)
        return
    end
    -- 以实际里程而非墙钟驱动三足交替步态：车库静止、刹停时六腿严格冻结。
    local phase=distance/1.15*math.pi*2
    for _,side in ipairs({"P","N"}) do
        local sign=side=="P" and 1 or -1
        for station=1,3 do
            local offset=((station==2)~=(side=="N")) and math.pi or 0
            local stride=math.sin(phase+offset)
            local lift=-math.max(0,stride)*5*sign
            rotate(root,"Leg"..side..station,Quaternion(stride*9,V.UP)*Quaternion(lift,V.RIGHT))
        end
        -- 技能夹击是独立巨颚绕根部Y轴闭合；技能结束明确回到原始开颚姿态。
        local closure=active and (10+7*math.sin(time*12)) or 0
        rotate(root,"Jaw"..side,Quaternion(sign*closure,V.UP))
    end
end

return M
