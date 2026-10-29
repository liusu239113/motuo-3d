-- Shared visible layout and collision source. All footprints are read ONCE from
-- LOD0 referenced triangles after the SAME transform used by the visible mesh.
-- Height clipping drops roof aerials/high accessories, not wheels/body/mirrors.
-- Longitudinal strips preserve narrow noses and local mirrors: no full-bbox OBB
-- (and especially no width/length diagonal circle) closes empty side channels.
local C=require("Career.FootprintCollision")
local Assets=require("VehicleAssets")
local F={}
local V=Vector3
F.SCOOTER="model/873a3764f21f49e4b717387160d13d19/"
F.BOX="model/8c4f0f26f9ee4d3eac2eec49a497852f/"
F.ScooterModel=F.SCOOTER.."Meshes/873a3764f21f49e4b717387160d13d19.mdl"
F.BoxModel=F.BOX.."Meshes/8c4f0f26f9ee4d3eac2eec49a497852f.mdl"
F.ScooterScale=1.90/1.3094
F.ScooterYaw=226.1
F.CargoPosition=V(0,.88,-.72)
F.CargoWidth=.58
F.MirrorCenter=V(.31,1.425,.19)
F.MirrorSize=V(.145,.10,.045)
F.MirrorYaw=12
local memo={}
local function clip(poly,coordinate,limit,above)
    local out={}
    for i,a in ipairs(poly) do
        local b=poly[i%#poly+1]
        local da,db=a[coordinate]-limit,b[coordinate]-limit
        local ina,inb=above and da>=0 or not above and da<=0,above and db>=0 or not above and db<=0
        if ina then out[#out+1]=a end
        if ina~=inb then
            local t=da/(da-db)
            out[#out+1]={x=a.x+(b.x-a.x)*t,y=a.y+(b.y-a.y)*t,z=a.z+(b.z-a.z)*t}
        end
    end
    return out
end
---@param model Model
---@param rotation Quaternion
---@param scale number
---@param offset Vector3
local function triangles(model,rotation,scale,offset)
    local result={}
    for slot=0,model.numGeometries-1 do
        local g=model:GetGeometry(slot,0)
        assert(g.primitiveType==TRIANGLE_LIST,"Vehicle collision needs triangle LOD0")
        local vb,ib=g:GetVertexBuffer(0),g.indexBuffer
        local data=vb:GetData()
        local indices=ib:GetData()
        local vertices={}
        local function vertex(index)
            if not vertices[index] then
                data:Seek(index*vb.vertexSize+vb:GetElementOffset(SEM_POSITION))
                local p=rotation*data:ReadVector3()*scale+offset
                vertices[index]={x=p.x,y=p.y,z=p.z}
            end
            return vertices[index]
        end
        indices:Seek(g.indexStart*ib.indexSize)
        for _=1,g.indexCount//3 do
            local tri={}
            for j=1,3 do tri[j]=vertex(ib.indexSize==2 and indices:ReadUShort() or indices:ReadUInt()) end
            local clipped=clip(clip(tri,"y",0,true),"y",1.85,false)
            if #clipped>=3 then result[#result+1]=clipped end
        end
    end
    return result
end
local function meshParts(model,rotation,scale,offset)
    local faces=triangles(model,rotation,scale,offset)
    local lo,hi=math.huge,-math.huge
    for _,tri in ipairs(faces) do for _,p in ipairs(tri) do lo=math.min(lo,p.z);hi=math.max(hi,p.z) end end
    assert(hi>lo,"No vehicle collision triangles in 0..1.85m height")
    local parts={}
    local count=12
    for row=1,count do
        local low,high=lo+(hi-lo)*(row-1)/count,lo+(hi-lo)*row/count
        local points={}
        for _,tri in ipairs(faces) do
            local poly=clip(clip(tri,"z",low,true),"z",high,false)
            for _,p in ipairs(poly) do points[#points+1]={x=p.x,z=p.z} end
        end
        if #points>=3 then
            local hull=C.Hull(points)
            if #hull>=3 then parts[#parts+1]={points=hull} end
        end
    end
    return parts
end
local function addParts(target,parts) for _,part in ipairs(parts) do target[#target+1]=part end end
function F.ScooterTransform(model)
    return Quaternion(0,F.ScooterYaw,0),F.ScooterScale,V(0,-model.boundingBox.min.y*F.ScooterScale,0)
end
function F.BoxTransform(model)
    local bb=model.boundingBox
    local scale=F.CargoWidth/math.max(bb.size.x,bb.size.z)
    return Quaternion.IDENTITY,scale,V(-bb.center.x*scale,-bb.min.y*scale,-bb.center.z*scale)
end
-- Same eight-corner normalization as VehicleAssets.Add, including all-LOD bbox
-- centring; the shell itself is measured from referenced LOD0 geometry only.
function F.AssetTransform(id)
    local config=assert(Assets.Vehicles[id])
    local model=assert(cache:GetResource("Model",config.model))
    local rotation=Quaternion(0,config.rotation,0)
    local bb=model.boundingBox
    local bounds=BoundingBox()
    for _,x in ipairs({bb.min.x,bb.max.x}) do for _,y in ipairs({bb.min.y,bb.max.y}) do
        for _,z in ipairs({bb.min.z,bb.max.z}) do bounds:Merge(rotation*V(x,y,z)) end
    end end
    local scale=config.targetLength/bounds.size.z
    return model,rotation,scale,V(-bounds.center.x,-bounds.min.y,-bounds.center.z)*scale
end
function F.Get(id)
    if memo[id] then return memo[id] end
    local parts={}
    if id=="borrowed_ebike" then
        local model=assert(cache:GetResource("Model",F.ScooterModel))
        local rotation,scale,offset=F.ScooterTransform(model)
        addParts(parts,meshParts(model,rotation,scale,offset))
        local cargo=assert(cache:GetResource("Model",F.BoxModel))
        local cr,cs,co=F.BoxTransform(cargo)
        addParts(parts,meshParts(cargo,cr,cs,co+F.CargoPosition))
        -- Supplemental right mirror is a visible ellipsoid, not a whole-bike bbox.
        local mirror={}
        local r=Quaternion(0,F.MirrorYaw,0)
        for i=0,15 do
            local a=i*math.pi/8
            local p=r*V(math.cos(a)*F.MirrorSize.x/2,0,math.sin(a)*F.MirrorSize.z/2)+F.MirrorCenter
            mirror[#mirror+1]={x=p.x,z=p.z}
        end
        parts[#parts+1]={points=C.Hull(mirror)}
    else
        local model,rotation,scale,offset=F.AssetTransform(id)
        addParts(parts,meshParts(model,rotation,scale,offset))
        -- Truck's visible independently supplied wheels extend below the source
        -- shell. In plan each axle's tyre is its exact 0.32 x 1.12m projection.
        if id=="truck" then
            for _,z in ipairs({-1.79,1.82}) do for _,side in ipairs({-1,1}) do
                addParts(parts,C.Box(side*1.17-.16,z-.56,side*1.17+.16,z+.56).parts)
            end end
        end
    end
    local shape=C.Shape(parts)
    memo[id]=shape
    print(string.format("[VehicleFootprint] %s %d referenced-triangle strips, local X[%.3f,%.3f] Z[%.3f,%.3f] (no enclosing-disc collision)",id,#parts,shape.x1,shape.x2,shape.z1,shape.z2))
    return shape
end
function F.At(id,x,z,yaw) return C.Pose(F.Get(id),x,z,yaw) end
return F
