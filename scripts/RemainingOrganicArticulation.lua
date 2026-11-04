-- 正式源MDL原面分组：所有LOD原VB/UV/法线/切线保持共享，仅分配原IB三角面。
-- 实测区域来自 remaining_organic_* 的连通件边界；Body始终静止，绝不把整车伪装成关节。
local Parts=require("MixedMeshParts")
local Assets=require("RemainingOrganicAssets")
local V=Vector3
local M={}
local configs={
    jellyfish={joints={"TentaclePP","TentaclePN","TentacleNP","TentacleNN"},
        pivot={TentaclePP=V(.10,-.06,.01),TentaclePN=V(.10,-.02,-.09),
            TentacleNP=V(-.05,-.07,.01),TentacleNN=V(-.05,-.08,-.09)}},
    jetboat={joints={"JetP","JetN"},pivot={JetP=V(.34,-.1233,.0591),JetN=V(.34,-.1233,-.0642)}},
    frog={joints={"HindFootP","HindFootN","FrontLegP","FrontLegN"},
        pivot={HindFootP=V(-.12,-.34,.19),HindFootN=V(-.12,-.34,-.19),
            FrontLegP=V(.12,.13,.16),FrontLegN=V(.12,.13,-.16)}},
}
for id,c in pairs(configs) do
    c.rotation=Assets[id].rotation;c.orientation=Assets[id].orientation
    c.measuredSize=Assets[id].measuredSize;c.orientedSize=Assets[id].orientedSize
end
function M.Has(id) return configs[id]~=nil end
function M.GetConfig(id) return assert(configs[id],"未知正式Organic车型 "..tostring(id)) end

---@param piece BoundingBox?
local function jellyfishPart(x,y,z,piece)
    if not piece then return "Body" end
    local c,s=piece.center,piece.size
    -- 伞盖与中轴驾驶舱不动；四条长触腕是原始完整连通件，吸盘随对应触腕一起运动。
    if piece.max.y<.075 and c.y<-.13 and (s.z>.30 or (s.x<.12 and s.y<.13)) then
        return "Tentacle"..(c.x>.025 and "P" or "N")..(c.z>.005 and "P" or "N")
    end
    return "Body"
end
---@param piece BoundingBox?
local function jetboatPart(_,_,_,piece)
    if piece and piece.min.x>.32 and piece.max.x<.50 and piece.center.y<-.08
        and piece.size.x>.10 and piece.size.y>.065 and piece.size.z>.06 then
        return piece.center.z>0 and "JetP" or "JetN"
    end
    return "Body"
end
---@param piece BoundingBox?
local function frogPart(_,_,_,piece)
    if not piece then return "Body" end
    local c,s=piece.center,piece.size
    if piece.max.y<-.30 and s.x>.20 and s.z>.15 then return c.z>0 and "HindFootP" or "HindFootN" end
    if c.x>.02 and c.y<.12 and math.abs(c.z)>.12 and s.x<.50 and piece.max.y<.20 then
        return c.z>0 and "FrontLegP" or "FrontLegN"
    end
    return "Body"
end
local selectors={jellyfish=jellyfishPart,jetboat=jetboatPart,frog=frogPart}
---@class RemainingOrganicJoint
---@field node Node
---@field rest Vector3
---@class RemainingOrganicRig
---@field joints table<string,RemainingOrganicJoint>
---@type table<Node,RemainingOrganicRig>
local rigs=setmetatable({},{__mode="k"})

---@param canonical Node
---@param id string
---@param source Model
---@param material Material
function M.Build(canonical,id,source,material)
    local c=M.GetConfig(id)
    local selector=assert(selectors[id],"未知Organic selector")
    local parts=Parts.Extract(source,"remaining_organic_v1_"..id,selector,true)
    assert(parts.Body,"缺少原始Body "..id)
    for _,name in ipairs(c.joints) do assert(parts[name],"缺少真实关节 "..id.."/"..name) end
    for name,part in pairs(parts) do
        local center=c.pivot[name] or V.ZERO
        local pivot=canonical:CreateChild(name);pivot.position=center
        pivot:SetVar("RestPosition",Variant(center));pivot:SetVar("RestRotation",Variant(Quaternion.IDENTITY))
        local mesh=pivot:CreateChild("OriginalMesh");mesh.position=V(-center.x,-center.y,-center.z)
        local draw=mesh:CreateComponent("StaticModel")
        draw:SetModel(part.model);draw:SetMaterial(material);draw.castShadows=true;draw.lodBias=2
        for lod=0,source:GetNumGeometryLodLevels(0)-1 do
            local original=assert(source:GetGeometry(0,lod))
            local geometry=assert(part.model:GetGeometry(0,lod),id.."/"..name.." LOD"..lod)
            assert(geometry:GetVertexBuffer(0)==original:GetVertexBuffer(0),"禁止替换源VB")
            assert(geometry.lodDistance==original.lodDistance,"禁止改变LOD距离")
        end
    end
    canonical:SetVar("ArticulationReady",Variant(true));canonical:SetVar("ArticulationId",Variant(id))
    return canonical
end
---@param root Node
---@param id string
---@return RemainingOrganicRig
local function rigFor(root,id)
    local cached=rigs[root]
    if cached then return cached end
    ---@type RemainingOrganicRig
    local rig={joints={}}
    for _,name in ipairs(M.GetConfig(id).joints) do
        local node=assert(root:GetChild(name,true),"关节未构建 "..name)
        rig.joints[name]={node=node,rest=node:GetVar("RestPosition"):GetVector3()}
    end
    rigs[root]=rig
    return rig
end
local function number(state,key,fallback)
    local value=state and state[key]
    return type(value)=="number" and value or fallback
end
local function active(state)
    local value=state and state.oddActive
    return value==true or (type(value)=="number" and value>0)
end
---@param root Node
---@param id string
---@param time number
---@param state table?
function M.Animate(root,id,time,state)
    if state and (state.paused==true or state.pause==true) then return end
    local rig=rigFor(root,id)
    local distance=number(state,"distance",0)
    local skill=active(state)
    local age=skill and number(state,"oddAge",0) or 0
    for _,j in pairs(rig.joints) do j.node.position=j.rest;j.node.rotation=Quaternion.IDENTITY end
    if id=="jellyfish" then
        local phase=distance/.95*math.pi*2
        for i,name in ipairs(M.GetConfig(id).joints) do
            local j=rig.joints[name]
            local side=name:sub(-1)=="P" and 1 or -1
            local wave=math.sin(phase+i*math.pi)*8
            local pulse=skill and math.sin(age*12)*14 or 0
            j.node.rotation=Quaternion(side*(wave+pulse),V.RIGHT)*Quaternion(wave*.45,V.FORWARD)
        end
    elseif id=="jetboat" then
        local steer=math.max(-1,math.min(1,number(state,"steer",0)))
        for i,name in ipairs(M.GetConfig(id).joints) do
            local j=rig.joints[name]
            -- 原始喷筒绕喷流轴转动，偏航负责矢量转向；技能结束消除喷筒后坐。
            j.node.rotation=Quaternion(0,steer*16,0)*Quaternion(distance/.12*180/math.pi,V.RIGHT)
            j.node.position=j.rest+V(skill and math.max(0,math.sin(age*18+i))*.012 or 0,0,0)
        end
    elseif id=="frog" then
        local phase=distance/1.12*math.pi*2
        for i,name in ipairs(M.GetConfig(id).joints) do
            local j=rig.joints[name]
            local hind=name:find("Hind",1,true)~=nil
            local wave=math.sin(phase+((i%2)*math.pi))*(hind and 10 or 7)
            local kick=skill and math.sin(math.min(age/.65,1)*math.pi)*(hind and 24 or -12) or 0
            j.node.rotation=Quaternion(wave+kick,V.FORWARD)
        end
    end
end
return M
