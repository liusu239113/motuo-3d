-- Original MDL faces only: MixedMeshParts shares each source VB and partitions IBs at EVERY LOD.
-- No primitive replacements, vertex edits, fake Body joint or autonomous wall-clock motion.
local Parts=require("MixedMeshParts")
---@type table<string,table>
local Assets=require("RemainingWheeledAssets")
local V=Vector3
local M={}
local boardCenters={
    V(.324951,-.247070,-.166748),V(.438965,-.089600,-.130615),
    V(-.343018,-.225586,-.164551),V(-.298584,.266602,-.117188),
    V(.306885,-.264648,.131592),V(.424072,-.090576,.167969),
    V(-.368408,-.246582,.133301),V(-.304688,.242188,.168701),
}
local configs={
    skateboard={joints={"Wheel2","Wheel4","Wheel6","Wheel8"},
        pivot={},radius=.060,sourceScale=1.4472436991752449,rotation=-90},
    sled={joints={"RunnerP","RunnerN"},pivot={RunnerP=V(.2151,-.137,-.0256),RunnerN=V(-.2151,-.137,-.0256)},rotation=180},
    cart={joints={"WheelFrontP","WheelFrontN","WheelRearP","WheelRearN"},radius=.077,sourceScale=1.8008793356130923,
        pivot={WheelFrontP=V(.3672,-.4126,.1685),WheelFrontN=V(.3552,-.4207,-.1931),
            WheelRearP=V(-.3003,-.4167,.2712),WheelRearN=V(-.2883,-.4209,-.2749)},rotation=-90},
}
for i,p in ipairs(boardCenters) do configs.skateboard.pivot["Wheel"..i]=p end
for id,c in pairs(configs) do
    c.orientation=Assets[id].orientation
    c.measuredSize=Assets[id].measuredSize
    c.targetSize=Assets[id].targetSize
    c.targetLength=Assets[id].targetLength
end
function M.Has(id) return configs[id]~=nil end
function M.GetConfig(id) return assert(configs[id],"Unknown wheeled vehicle: "..tostring(id)) end
M.Configs=configs

---@param piece BoundingBox?
local function boardPart(_,_,_,piece)
    if not piece then return "Body" end
    local c,s=piece.center,piece.size
    -- Keep only the principal deck's four wheels and caps. The delivered source contains a
    -- second inverted, crossing deck assembly: partition it to Discard, never render/replace it.
    if s.z<.105 and math.abs(c.z)>.08 and s.x<.17 and s.y<.17 then
        local best,index=math.huge,1
        for i,p in ipairs(boardCenters) do
            local d=(c-p):LengthSquared()
            if d<best then best,index=d,i end
        end
        if best<.009 then return index%2==0 and "Wheel"..index or "Discard" end
    end
    -- Connected component centers in the fitted deck frame separate the second deck and
    -- its truck hardware at every source LOD. No source vertices or surviving faces change.
    local frame=Assets.skateboard.orientation*c
    if frame.y>0 then return "Discard" end
    return "Body"
end
---@param piece BoundingBox?
local function sledPart(_,_,_,piece)
    if piece and math.abs(piece.center.x)>.18 and piece.max.y<-.115 then
        return piece.center.x>0 and "RunnerP" or "RunnerN"
    end
    return "Body"
end
---@param piece BoundingBox?
local function cartPart(_,_,_,piece)
    -- Tire + hub only. Upright caster forks and the cross-frame stay with the body.
    if piece and piece.center.y<-.39 and piece.size.z<.13 and math.abs(piece.center.z)>.1 then
        return "Wheel"..(piece.center.x>0 and "Front" or "Rear")..(piece.center.z>0 and "P" or "N")
    end
    return "Body"
end
---@type table<string,fun(x:number,y:number,z:number,piece:BoundingBox?):string>
local selectors={skateboard=boardPart,sled=sledPart,cart=cartPart}
---@class RemainingWheeledJoint
---@field node Node
---@field rest Vector3
---@field rotation Quaternion
---@type table<Node,table<string,RemainingWheeledJoint>>
local cacheJoints=setmetatable({},{__mode="k"})

---@param canonical Node
---@param id string
---@param source Model
---@param material Material
---@return Node
function M.Build(canonical,id,source,material)
    local c=M.GetConfig(id)
    local parts=Parts.Extract(source,"remaining_wheeled_v1_"..id,selectors[id],true)
    assert(parts.Body,"Missing original Body: "..id)
    for _,name in ipairs(c.joints) do assert(parts[name],"Missing original joint: "..id.."/"..name) end
    local map={}
    for name,part in pairs(parts) do
        if name~="Discard" then
        ---@type Vector3
        local p=c.pivot[name] or V.ZERO
        local pivot=canonical:CreateChild(name)
        pivot.position=p
        pivot:SetVar("RestPosition",Variant(p))
        pivot:SetVar("RestRotation",Variant(Quaternion.IDENTITY))
        local mesh=pivot:CreateChild("OriginalMesh")
        mesh.position=-p
        local draw=mesh:CreateComponent("StaticModel")
        draw:SetModel(part.model);draw:SetMaterial(material)
        draw.castShadows=true;draw.lodBias=2
        map[name]={node=pivot,rest=p,rotation=Quaternion.IDENTITY}
        for lod=0,source:GetNumGeometryLodLevels(0)-1 do
            local original=assert(source:GetGeometry(0,lod))
            local geometry=assert(part.model:GetGeometry(0,lod),id.."/"..name.." missing LOD"..lod)
            assert(geometry:GetVertexBuffer(0)==original:GetVertexBuffer(0),"Original VB must stay shared")
            assert(geometry.primitiveType==TRIANGLE_LIST and geometry.lodDistance==original.lodDistance)
        end
        end
    end
    cacheJoints[canonical]=map
    canonical:SetVar("ArticulationReady",Variant(true))
    canonical:SetVar("ArticulationId",Variant(id))
    canonical:SetVar("OriginalRotation",Variant(c.rotation))
    canonical:SetVar("MeasuredSize",Variant(c.measuredSize))
    return canonical
end
---@param root Node
---@param name string
---@return RemainingWheeledJoint
local function joint(root,name)
    local map=cacheJoints[root]
    if not map then map={};cacheJoints[root]=map end
    if not map[name] then
        local n=assert(root:GetChild(name,true),"Missing wheeled joint "..name)
        map[name]={node=n,rest=n:GetVar("RestPosition"):GetVector3(),rotation=n:GetVar("RestRotation"):GetQuaternion()}
    end
    return map[name]
end
local function numeric(state,key)
    local n=state and state[key]
    return type(n)=="number" and n==n and n~=math.huge and n~=-math.huge and n or 0
end
local function active(state)
    local value=state and state.oddActive
    return value==true or (type(value)=="number" and value>0)
end
local function clamp(n,a,b) return math.max(a,math.min(b,n)) end

---@param root Node Vehicle root OR SourceTransform
---@param id string
---@param time number Deliberately ignored; all running motion uses distance, skills use oddAge.
---@param state table?
function M.Animate(root,id,time,state)
    if state and (state.paused==true or state.pause==true) then return end
    local c=M.GetConfig(id)
    for _,name in ipairs(c.joints) do
        local j=joint(root,name)
        j.node.position=j.rest;j.node.rotation=j.rotation
    end
    local distance=numeric(state,"distance")
    local steer=clamp(numeric(state,"steer"),-1,1)
    local skill=state~=nil and active(state) and not (state.finished or state.wrecked or state.eliminated)
    local age=math.max(0,numeric(state,"oddAge"))
    local sourceUp=c.orientation:Inverse()*V.UP
    if id=="sled" then
        -- The two complete original runners carve independently. Low-amplitude distance-driven
        -- suspension settles at rest; blade skill banks the runner, never the entire Body.
        for _,side in ipairs({"P","N"}) do
            local sign=side=="P" and 1 or -1
            local j=joint(root,"Runner"..side)
            local carve=steer*6+(skill and math.sin(age*9)*3 or 0)
            j.node.rotation=Quaternion(carve,sourceUp)*Quaternion(sign*(skill and 5 or 0),V.FORWARD)
            j.node.position=j.rest+V(0,math.sin(distance*8)*.002*sign,0)
        end
    elseif id=="cart" then
        local angle=(distance/(c.radius*c.sourceScale)*180/math.pi)%360
        local magnetic=skill and math.sin(age*10)*6 or 0
        for _,name in ipairs(c.joints) do
            local j=joint(root,name)
            local front=name:find("Front",1,true)~=nil
            -- Source +Z becomes vehicle -X after yaw=-90; negate the roll for forward ground travel.
            j.node.rotation=Quaternion(steer*(front and 20 or -7)+magnetic,sourceUp)*Quaternion(-angle,V.FORWARD)
        end
    else
        local angle=(distance/(c.radius*c.sourceScale)*180/math.pi)%360
        for i,name in ipairs(c.joints) do
            local j=joint(root,name)
            -- Source wheel axles are predominantly Z; wheels rotate about their measured hubs.
            -- Ollie articulation is a small independent truck lean; board/air-spin belongs to Simulation.
            local lean=skill and math.sin(age*8)*(i%2==0 and 4 or -4) or 0
            j.node.rotation=Quaternion(steer*5+lean,sourceUp)*Quaternion(angle,V.FORWARD)
        end
    end
end
return M
