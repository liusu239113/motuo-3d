-- Based on examples/24-model-painter.lua indexed models and Parts' shared mesh pattern.
-- Bake the original 38 rigid parts into four batches ONCE, shared by all trucks.
-- Bolts remain separate solely for short draw distance and the original no-shadow flag.
-- Coordinates remain in the unscaled VehicleAssets.Add attachment root; no frame callbacks.
local Wheels={}
local V=Vector3

---@class TruckWheelBatch
---@field name string
---@field model Model
---@field material Material
---@field vertexBuffer VertexBuffer
---@field indexBuffer IndexBuffer
---@field geometry Geometry

---@class TruckWheelVertex
---@field position Vector3
---@field normal Vector3
---@field uv Vector2
---@field tangent Vector4

---@class TruckWheelSource
---@field vertices TruckWheelVertex[]
---@field indices integer[]

---@class TruckWheelBuilder
---@field vertices VectorBuffer
---@field indices integer[]
---@field count integer
---@field bounds BoundingBox

---@type TruckWheelBatch[]
local shared={}
Wheels.DRAW_DISTANCE=180
Wheels.SHADOW_DISTANCE=45
Wheels.BOLT_DRAW_DISTANCE=24

-- Source buffers are read only during lazy initialization, never per truck/frame.
---@param model Model
---@return TruckWheelSource
local function readSource(model)
    ---@type TruckWheelSource
    local source={vertices={},indices={}}
    for slot=0,model.numGeometries-1 do
        local geometry=assert(model:GetGeometry(slot,0))
        assert(geometry.primitiveType==TRIANGLE_LIST,"Truck wheel source must contain triangles")
        local vb,ib=geometry:GetVertexBuffer(0),geometry:GetIndexBuffer()
        local data,indices=vb:GetData(),ib:GetData()
        assert(data.size>=vb.vertexCount*vb.vertexSize,"Truck wheel source has no CPU vertex data")
        assert(indices.size>=(geometry.indexStart+geometry.indexCount)*ib.indexSize,"Truck wheel source has no CPU index data")
        assert(vb:HasElement(TYPE_VECTOR3,SEM_POSITION) and vb:HasElement(TYPE_VECTOR3,SEM_NORMAL))
        local base=#source.vertices
        for index=0,vb.vertexCount-1 do
            local offset=index*vb.vertexSize
            data:Seek(offset+vb:GetElementOffset(SEM_POSITION))
            local position=data:ReadVector3()
            data:Seek(offset+vb:GetElementOffset(SEM_NORMAL))
            local normal=data:ReadVector3()
            local uv=Vector2(0,0)
            if vb:HasElement(TYPE_VECTOR2,SEM_TEXCOORD) then
                data:Seek(offset+vb:GetElementOffset(SEM_TEXCOORD));uv=data:ReadVector2()
            end
            local tangent=Vector4(1,0,0,1)
            if vb:HasElement(TYPE_VECTOR4,SEM_TANGENT) then
                data:Seek(offset+vb:GetElementOffset(SEM_TANGENT));tangent=data:ReadVector4()
            end
            source.vertices[#source.vertices+1]={position=position,normal=normal,uv=uv,tangent=tangent}
        end
        indices:Seek(geometry.indexStart*ib.indexSize)
        for _=1,geometry.indexCount do
            local index=ib.indexSize==2 and indices:ReadUShort() or indices:ReadUInt()
            source.indices[#source.indices+1]=base+index
        end
    end
    return source
end

---@return TruckWheelBuilder
local function builder()
    return {vertices=VectorBuffer(),indices={},count=0,bounds=BoundingBox()}
end

---@param batch TruckWheelBuilder
---@param source TruckWheelSource
---@param center Vector3
---@param scale Vector3
---@param rotation Quaternion
local function append(batch,source,center,scale,rotation)
    local base=batch.count
    for _,vertex in ipairs(source.vertices) do
        local p=vertex.position
        local point=center+rotation*V(p.x*scale.x,p.y*scale.y,p.z*scale.z)
        local n=vertex.normal
        local normal=(rotation*V(n.x/scale.x,n.y/scale.y,n.z/scale.z)):Normalized()
        local t=vertex.tangent
        local tangent=(rotation*V(t.x*scale.x,t.y*scale.y,t.z*scale.z)):Normalized()
        batch.vertices:WriteVector3(point)
        batch.vertices:WriteVector3(normal)
        batch.vertices:WriteVector2(vertex.uv)
        batch.vertices:WriteVector4(Vector4(tangent.x,tangent.y,tangent.z,t.w))
        batch.bounds:Merge(point)
    end
    for _,index in ipairs(source.indices) do batch.indices[#batch.indices+1]=base+index end
    batch.count=batch.count+#source.vertices
end

---@param batch TruckWheelBuilder
---@param name string
---@param material Material
---@return TruckWheelBatch
local function finish(batch,name,material)
    local vb,ib,geometry=VertexBuffer(),IndexBuffer(),Geometry()
    vb.shadowed=true;ib.shadowed=true
    local elements={VertexElement(TYPE_VECTOR3,SEM_POSITION),VertexElement(TYPE_VECTOR3,SEM_NORMAL),
        VertexElement(TYPE_VECTOR2,SEM_TEXCOORD),VertexElement(TYPE_VECTOR4,SEM_TANGENT)}
    assert(vb:SetSize(batch.count,elements,false) and vb:SetData(batch.vertices),"Truck wheel vertex upload")
    local large=batch.count>65535
    local data=VectorBuffer()
    for _,index in ipairs(batch.indices) do
        if large then data:WriteUInt(index) else data:WriteUShort(index) end
    end
    assert(ib:SetSize(#batch.indices,large,false) and ib:SetData(data),"Truck wheel index upload")
    assert(geometry:SetVertexBuffer(0,vb))
    geometry:SetIndexBuffer(ib)
    assert(geometry:SetDrawRange(TRIANGLE_LIST,0,#batch.indices,0,batch.count))
    local model=Model()
    model.numGeometries=1
    assert(model:SetGeometry(0,0,geometry))
    model.boundingBox=batch.bounds
    model:SetGeometryCenter(0,batch.bounds.center)
    -- Hold buffers/geometry as well as Model for deterministic lifetime across scene rebuilds.
    return {name=name,model=model,material=material,vertexBuffer=vb,indexBuffer=ib,geometry=geometry}
end

local function initialize()
    if #shared>0 then return end
    local Parts=require("Parts")
    local tireShape=CylinderGeometry(.56,.56,.32,32,1,false)
    local hubShape=CylinderGeometry(.32,.32,.335,24,1,false)
    local capShape=CylinderGeometry(.11,.11,.35,16,1,false)
    tireShape:SetShadowed(true);hubShape:SetShadowed(true);capShape:SetShadowed(true)
    local tire=readSource(tireShape:ToModel())
    local hub=readSource(hubShape:ToModel())
    local cap=readSource(capShape:ToModel())
    -- Reuse the exact old sphere and axle meshes, not guessed procedural substitutes.
    local sphere=readSource(assert(cache:GetResource("Model","Models/Sphere.mdl")))
    local axle=readSource(assert(cache:GetResource("Model","Models/Cylinder.mdl")))
    local rubber,metal,dark,bolts=builder(),builder(),builder(),builder()
    local rotation=Quaternion(90,V.FORWARD)
    for _,z in ipairs({-1.79,1.82}) do
        local a,b=V(-1.17,.04,z),V(1.17,.04,z)
        local delta=b-a
        append(dark,axle,(a+b)*.5,V(.15,delta:Length(),.15),Quaternion(V.UP,delta:Normalized()))
        for _,side in ipairs({-1,1}) do
            local center=V(side*1.17,.04,z)
            append(rubber,tire,center,V.ONE,rotation)
            append(metal,hub,center,V.ONE,rotation)
            append(dark,cap,center,V.ONE,rotation)
            for i=0,5 do
                local angle=i*math.pi/3
                append(bolts,sphere,center+V(side*.174,.23*math.cos(angle),.23*math.sin(angle)),
                    V(.035,.035,.035),Quaternion.IDENTITY)
            end
        end
    end
    local darkMaterial=Parts.Material(.055,.06,.065,.65,.3)
    shared={
        finish(rubber,"货车独立轮胎",Parts.Material(.025,.027,.03,.9,0)),
        finish(metal,"货车金属轮毂",Parts.Material(.30,.32,.34,.32,.72)),
        finish(dark,"货车轮轴盖",darkMaterial),
        finish(bolts,"货车轮毂螺栓",darkMaterial),
    }
    print("[货车轮组合批] 38→4 drawable/车；共享4模型/3材质，近景4胎/4毂/4盖/双轴/24螺栓原尺寸变换保留")
end

---@param root Node 原车壳无轮资源的无缩放挂接根
function Wheels.Add(root)
    initialize()
    for _,batch in ipairs(shared) do
        local node=root:CreateChild(batch.name)
        local drawable=node:CreateComponent("StaticModel")
        drawable:SetModel(batch.model)
        drawable:SetMaterial(batch.material)
        -- The built-in sphere has >1200 triangles per tiny bolt. Keep its exact
        -- near shape, but cull all 24 bolts together beyond 24m and never shadow them.
        local isBolt=batch.name=="货车轮毂螺栓"
        drawable.drawDistance=isBolt and Wheels.BOLT_DRAW_DISTANCE or Wheels.DRAW_DISTANCE
        drawable.shadowDistance=Wheels.SHADOW_DISTANCE
        drawable.castShadows=not isBolt
    end
end
return Wheels
