-- Formal source triangles only: MixedMeshParts shares original VB/UV/normals/tangents
-- and redistributes original indices at every LOD. No replacement geometry or cut caps.
local Parts=require("MixedMeshParts")
local Assets=require("RemainingNoveltyAssets")
local V=Vector3
local M={}
local configs={
    bathtub={joints={"WheelFrontP","WheelFrontN","WheelRearP","WheelRearN","TapValve"},
        pivot={WheelFrontP=V(.267,-.095,.205),WheelFrontN=V(.276,-.095,-.204),
            WheelRearP=V(-.255,-.093,.198),WheelRearN=V(-.243,-.093,-.213),TapValve=V(.128,.220,.171)},
        wheelRadius=.085,skillJoints={"TapValve"}},
    office={joints={"ChairSwivel","Caster1","Caster2","Caster3","Caster4","Caster5","Caster6"},
        pivot={ChairSwivel=V(-.01,-.33,.005),Caster1=V(.252,-.474,-.041),Caster2=V(.171,-.472,.208),
            Caster3=V(-.119,-.480,.258),Caster4=V(-.252,-.469,.080),
            Caster5=V(-.190,-.477,-.203),Caster6=V(.069,-.473,-.249)},
        axes={V(0,0,1),V(.62,0,-.78),V(.65,0,.76),V(.63,0,.78),V(.76,0,-.65),V(.91,0,.42)},
        wheelRadius=.025,skillJoints={"ChairSwivel"}},
    toilet={joints={"Lid","TankCap"},pivot={Lid=V(-.132,-.045,.011),TankCap=V(-.315,.352,.020)},
        skillJoints={"Lid","TankCap"}},
}
for id,c in pairs(configs) do
    c.rotation=Assets[id].rotation;c.orientation=Assets[id].orientation
    c.measuredSize=Assets[id].measuredSize;c.orientedSize=Assets[id].sourceBounds.size
end
function M.Has(id) return configs[id]~=nil end
function M.GetConfig(id) return assert(configs[id],"Unknown novelty vehicle: "..tostring(id)) end
M.Configs=configs

---@param _ number
---@param _ number
---@param _ number
---@param piece BoundingBox?
---@return string
local function bathtubPart(_,_,_,piece)
    if not piece then return "Body" end
    local c,s=piece.center,piece.size
    -- Four complete tyre+hub pieces. Axles, suspension, tub shell remain Body.
    if c.y<-.045 and math.abs(c.z)>.16 and s.y>.10 and s.x>.10 and s.z<.10 then
        return "Wheel"..(c.x>0 and "Front" or "Rear")..(c.z>0 and "P" or "N")
    end
    -- Measured 186-triangle rotary tap control; do not rotate the whole faucet.
    if c.x>.105 and c.x<.15 and c.y>.185 and c.y<.25 and c.z>.14 and c.z<.20 and s.x<.06 then return "TapValve" end
    return "Body"
end
---@param _ number
---@param _ number
---@param _ number
---@param piece BoundingBox?
---@return string
local function officePart(_,_,_,piece)
    if not piece then return "Body" end
    local c,s=piece.center,piece.size
    -- All chair upholstery/arms/seat control are above the real central swivel.
    if piece.min.y>-.30 then return "ChairSwivel" end
    -- Six measured caster stations, paired discs + their small fork components.
    -- Exclude star pedestal and centre shaft by component extent and height.
    if c.y<-.435 and s.x<.10 and s.z<.10 and c.x*c.x+c.z*c.z>.035 then
        local station,best=1,math.huge
        for i=1,6 do
            local p=configs.office.pivot["Caster"..i]
            local d=(c.x-p.x)^2+(c.z-p.z)^2
            if d<best then station,best=i,d end
        end
        return "Caster"..station
    end
    return "Body"
end
---@param _ number
---@param _ number
---@param _ number
---@param piece BoundingBox?
---@return string
local function toiletPart(_,_,_,piece)
    if not piece then return "Body" end
    local c,s=piece.center,piece.size
    -- The upright original lid is a 431-triangle YZ panel, not the bowl/body.
    if c.x>-.19 and c.x<-.08 and c.y>.17 and s.y>.40 and s.x<.14 then return "Lid" end
    -- Independent 168-triangle top of the rear cistern, not its upright tank.
    if c.x<-.24 and c.y>.32 and c.y<.39 and s.y<.09 and s.z>.40 then return "TankCap" end
    return "Body"
end
local selectors={bathtub=bathtubPart,office=officePart,toilet=toiletPart}
---@class NoveltyJoint
---@field node Node
---@field rest Vector3
---@field rotation Quaternion
---@type table<Node,table<string,NoveltyJoint>>
local jointCache=setmetatable({},{__mode="k"})
---@param root Node
---@param name string
---@return NoveltyJoint
local function joint(root,name)
    local map=jointCache[root]
    if not map then map={};jointCache[root]=map end
    if not map[name] then
        local node=assert(root:GetChild(name,true),"Missing novelty joint: "..name)
        map[name]={node=node,rest=node:GetVar("RestPosition"):GetVector3(),rotation=node:GetVar("RestRotation"):GetQuaternion()}
    end
    return map[name]
end
---@param canonical Node
---@param id string
---@param source Model
---@param material Material
---@return Node
function M.Build(canonical,id,source,material)
    local c=M.GetConfig(id)
    local parts=Parts.Extract(source,"remaining_novelty_v1_"..id,assert(selectors[id]),true)
    assert(parts.Body,"Missing static original Body: "..id)
    for _,name in ipairs(c.joints) do assert(parts[name],"Missing measured original part: "..id.."/"..name) end
    for name,part in pairs(parts) do
        local pivot=canonical:CreateChild(name)
        ---@type Vector3
        local center=c.pivot[name] or V.ZERO
        pivot.position=center
        pivot:SetVar("RestPosition",Variant(center));pivot:SetVar("RestRotation",Variant(Quaternion.IDENTITY))
        local mesh=pivot:CreateChild("OriginalMesh");mesh.position=-center
        local draw=mesh:CreateComponent("StaticModel")
        draw:SetModel(part.model);draw:SetMaterial(material);draw.castShadows=true;draw.lodBias=2
        for lod=0,source:GetNumGeometryLodLevels(0)-1 do
            local g=assert(part.model:GetGeometry(0,lod),id.."/"..name.." missing LOD"..lod)
            assert(g.indexCount>0 and g:GetVertexBuffer(0)==source:GetGeometry(0,lod):GetVertexBuffer(0),"Must retain original VB at every LOD")
        end
    end
    canonical:SetVar("ArticulationReady",Variant(true));canonical:SetVar("ArticulationId",Variant(id))
    return canonical
end
local function number(state,key,default)
    local value=state and state[key]
    return type(value)=="number" and value or default
end
local function enabled(value) return value==true or (type(value)=="number" and value>0) end
---@param root Node
---@param id string
---@param time number
---@param state table?
function M.Animate(root,id,time,state)
    local c=M.GetConfig(id)
    if state and (enabled(state.paused) or enabled(state.pause)) then return end
    -- No wall-clock movement: distance drives all road motion; oddAge drives skills.
    -- Reset every pose before applying active state, so skill completion cannot linger.
    for _,name in ipairs(c.joints) do
        local j=joint(root,name);j.node.position=j.rest;j.node.rotation=j.rotation
    end
    local distance=number(state,"distance",0)
    local steer=math.max(-1,math.min(1,number(state,"steer",0)))
    local active=state and enabled(state.oddActive) or false
    local age=math.max(0,number(state,"oddAge",0))
    if id=="bathtub" then
        local radius=c.wheelRadius*Assets[id].targetLength/Assets[id].sourceBounds.size.z
        local roll=distance/radius*180/math.pi%360
        for _,name in ipairs({"WheelFrontP","WheelFrontN","WheelRearP","WheelRearN"}) do
            local yaw=name:find("Front",1,true) and steer*22 or 0
            joint(root,name).node.rotation=Quaternion(0,yaw,0)*Quaternion(roll,V.FORWARD)
        end
        if active then joint(root,"TapValve").node.rotation=Quaternion(math.sin(age*7)*65,V.UP) end
    elseif id=="office" then
        local radius=c.wheelRadius*Assets[id].targetLength/Assets[id].sourceBounds.size.z
        local roll=distance/radius*180/math.pi%360
        for i=1,6 do joint(root,"Caster"..i).node.rotation=Quaternion(0,steer*18,0)*Quaternion(roll,c.axes[i]) end
        if active then joint(root,"ChairSwivel").node.rotation=Quaternion(0,age*480%360,0) end
    elseif id=="toilet" and active then
        -- Lid swings about its original rear horizontal hinge; seat/bowl never move.
        joint(root,"Lid").node.rotation=Quaternion(-18*math.sin(math.min(1,age/.22)*math.pi*.5),V.FORWARD)
        local cap=joint(root,"TankCap")
        cap.node.position=cap.rest+V(0,.024*math.sin(math.min(1,age/.18)*math.pi*.5),0)
    end
end

-- Probe-only full index multiset audit: preserve each source triangle exactly once,
-- original source VB identity, LOD count/distance, pause and skill reset contracts.
---@param root Node
---@param id string
---@param source Model
function M.Validate(root,id,source)
    local c=M.GetConfig(id)
    local draws=root:GetComponents("StaticModel",true)
    local asset=Assets[id]
    local measured=BoundingBox()
    local originalLOD=source:GetGeometry(0,0)
    local vb,ib=originalLOD:GetVertexBuffer(0),originalLOD:GetIndexBuffer()
    local vertexData,indexData=vb:GetData(),ib:GetData()
    indexData:Seek(originalLOD.indexStart*ib.indexSize)
    for _=1,originalLOD.indexCount do
        local index=ib.indexSize==2 and indexData:ReadUShort() or indexData:ReadUInt()
        vertexData:Seek(index*vb.vertexSize+vb:GetElementOffset(SEM_POSITION))
        measured:Merge(asset.orientation*vertexData:ReadVector3())
    end
    local size=measured.size*(asset.targetLength/measured.size.z)
    assert((size-asset.targetSize):Length()<.00001,id.." canonical targetSize is not indexed LOD0 uniform scale")
    local function sameRotation(a,b)
        return math.abs(a.w-b.w)+math.abs(a.x-b.x)+math.abs(a.y-b.y)+math.abs(a.z-b.z)<.00001
    end
    local function triangles(geo,out,sign)
        local ib=geo:GetIndexBuffer();local data=ib:GetData();data:Seek(geo.indexStart*ib.indexSize)
        for _=1,geo.indexCount//3 do
            local a=ib.indexSize==2 and data:ReadUShort() or data:ReadUInt()
            local b=ib.indexSize==2 and data:ReadUShort() or data:ReadUInt()
            local d=ib.indexSize==2 and data:ReadUShort() or data:ReadUInt()
            local key=a.."/"..b.."/"..d;out[key]=(out[key] or 0)+sign
        end
    end
    for lod=0,source:GetNumGeometryLodLevels(0)-1 do
        local original=source:GetGeometry(0,lod);local counts={};triangles(original,counts,1)
        for _,draw in ipairs(draws) do
            local model=draw:GetModel()
            assert(model:GetNumGeometryLodLevels(0)==source:GetNumGeometryLodLevels(0))
            local g=assert(model:GetGeometry(0,lod));assert(g:GetVertexBuffer(0)==original:GetVertexBuffer(0))
            assert(math.abs(g.lodDistance-original.lodDistance)<.0001)
            triangles(g,counts,-1)
        end
        for _,count in pairs(counts) do assert(count==0,id.." lost/duplicated original triangle at LOD"..lod) end
    end
    M.Animate(root,id,0,{distance=.37,oddActive=true,oddAge=.17})
    local moved=false
    for _,name in ipairs(c.skillJoints) do
        local j=joint(root,name)
        if (j.node.position-j.rest):Length()>.00001 or math.abs(j.node.rotation.w-1)>.00001 then moved=true end
    end
    assert(moved,id.." bool skill did not animate")
    ---@type table<string,{p:Vector3,q:Quaternion}>
    local saved={}
    for _,name in ipairs(c.joints) do local j=joint(root,name);saved[name]={p=j.node.position,q=j.node.rotation} end
    M.Animate(root,id,999,{distance=123,oddActive=1,oddAge=7,paused=true})
    for _,name in ipairs(c.joints) do
        local j=joint(root,name);local rest=saved[name]
        assert((j.node.position-rest.p):Length()<.00001 and sameRotation(j.node.rotation,rest.q),id.." pause changed joint")
    end
    M.Animate(root,id,0,{distance=.37,oddActive=1,oddAge=.17})
    for _,name in ipairs(c.skillJoints) do
        local j=joint(root,name);local rest=saved[name]
        assert((j.node.position-rest.p):Length()<.00001 and sameRotation(j.node.rotation,rest.q),id.." numeric/bool skills differ")
    end
    M.Animate(root,id,999,{distance=.37,oddActive=0,oddAge=7})
    for _,name in ipairs(c.skillJoints) do
        local j=joint(root,name)
        assert((j.node.position-j.rest):Length()<.00001 and math.abs(j.node.rotation.w-1)<.00001,id.." skill failed reset")
    end
    M.Animate(root,id,999,{distance=0,steer=0,oddActive=false,oddAge=7})
    for _,name in ipairs(c.joints) do
        local j=joint(root,name)
        assert((j.node.position-j.rest):Length()<.00001 and sameRotation(j.node.rotation,j.rotation),id.." idle did not restore joint")
    end
    local body=assert(root:GetChild("Body",true))
    assert(body.position:Length()<.00001 and math.abs(body.rotation.w-1)<.00001,"Body cannot impersonate a joint")
    print("[RemainingNoveltyProbe] PASS "..id.." source indices/VB/all LODs, bool+numeric skill, pause, reset")
end
return M
