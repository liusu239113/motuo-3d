-- 索引网格基于 examples/24-model-painter.lua；CPU高度仍严格采样Landscape的同一组三角形。
local Mesh = {}
local sharedIndices = {}
Mesh.vertexCount, Mesh.indexCount, Mesh.tileCount = 0, 0, 0

---@param count integer
---@param include? fun(ix:integer,iz:integer):boolean
---@return IndexBuffer?, integer
local function indices(count, include)
    if not include and sharedIndices[count] then
        return sharedIndices[count], count * count * 6
    end
    local data = VectorBuffer()
    local total = 0
    for iz = 0, count - 1 do
        for ix = 0, count - 1 do
            if not include or include(ix, iz) then
                local a = iz * (count + 1) + ix
                local b, c, d = a + count + 1, a + 1, a + count + 2
                data:WriteUShort(a); data:WriteUShort(b); data:WriteUShort(c)
                data:WriteUShort(c); data:WriteUShort(b); data:WriteUShort(d)
                total = total + 6
            end
        end
    end
    if total == 0 then return nil, 0 end
    local buffer = IndexBuffer:new()
    buffer.shadowed = true
    assert(buffer:SetSize(total, false, false), "terrain index allocation")
    assert(buffer:SetData(data), "terrain index upload")
    if not include then sharedIndices[count] = buffer end
    return buffer, total
end

---@param parent Node
---@param name string
---@param x number
---@param z number
---@param count integer
---@param step number
---@param height fun(x:number,z:number):number
---@param normal fun(x:number,z:number):Vector3
---@param material Material
---@param include? fun(ix:integer,iz:integer):boolean
---@param yieldRow? fun(row:integer)
---@return StaticModel?
function Mesh.Grid(parent, name, x, z, count, step, height, normal, material, include, yieldRow)
    local ib, indexCount = indices(count, include)
    if not ib then return nil end
    local vertices = (count + 1) * (count + 1)
    local size = count * step
    local centerX, centerZ = x + size * 0.5, z + size * 0.5
    local data = VectorBuffer()
    local minY, maxY = math.huge, -math.huge
    for iz = 0, count do
        for ix = 0, count do
            local px, pz = x + ix * step, z + iz * step
            local y = height(px, pz)
            minY, maxY = math.min(minY, y), math.max(maxY, y)
            data:WriteVector3(Vector3(px - centerX, y, pz - centerZ))
            local n=normal(px,pz)
            data:WriteVector3(n)
            data:WriteVector2(Vector2(px / 4, pz / 4))
            local tangent=Vector3(1-n.x*n.x,-n.x*n.y,-n.x*n.z):Normalized()
            data:WriteVector4(Vector4(tangent.x,tangent.y,tangent.z,1))
        end
        if yieldRow then yieldRow(iz) end
    end
    local vb = VertexBuffer:new()
    vb.shadowed = true
    local elements={VertexElement(TYPE_VECTOR3,SEM_POSITION),VertexElement(TYPE_VECTOR3,SEM_NORMAL),
        VertexElement(TYPE_VECTOR2,SEM_TEXCOORD,0),VertexElement(TYPE_VECTOR4,SEM_TANGENT)}
    assert(vb:SetSize(vertices,elements,false), "terrain vertex allocation")
    assert(vb:SetData(data), "terrain vertex upload")
    local geom = Geometry:new()
    assert(geom:SetVertexBuffer(0, vb), "terrain vertex stream")
    geom:SetIndexBuffer(ib)
    assert(geom:SetDrawRange(TRIANGLE_LIST, 0, indexCount), "terrain draw range")
    local model = Model:new()
    model.numGeometries = 1
    assert(model:SetGeometry(0, 0, geom), "terrain model geometry")
    model.boundingBox = BoundingBox(Vector3(-size * 0.5, minY, -size * 0.5), Vector3(size * 0.5, maxY, size * 0.5))
    local node = parent:CreateChild(name)
    node.position = Vector3(centerX, 0, centerZ)
    local drawable = node:CreateComponent("StaticModel")
    -- 必须先设模型再设材质：多重属性赋值可能逆序执行，SetModel会重建材质槽。
    drawable:SetModel(model)
    drawable:SetMaterial(material)
    assert(drawable:GetMaterial(0) == material, "索引地形材质绑定失效")
    drawable.castShadows = false
    Mesh.vertexCount = Mesh.vertexCount + vertices
    Mesh.indexCount = Mesh.indexCount + indexCount
    Mesh.tileCount = Mesh.tileCount + 1
    return drawable
end

return Mesh
