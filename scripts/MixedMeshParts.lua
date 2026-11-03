-- 只从正式源MDL提取原三角面；不生成顶点、不拼基础形状、不修改缓存源网格。
local M = {}
---@class MixedMeshPart
---@field model Model
---@field buffers IndexBuffer[]
---@field geometry Geometry[]
local shared = {}

---@param source Model
---@param key string
---@param select fun(x:number,y:number,z:number):string
---@return table<string,MixedMeshPart>
function M.Extract(source, key, select)
    if shared[key] then return shared[key] end
    assert(source.numGeometries == 1 and source.numMorphs == 0, "正式载具拆件需要静态单图集源网格")
    ---@type table<string,MixedMeshPart>
    local parts = {}
    local levels = source:GetNumGeometryLodLevels(0)
    for lod = 0, levels - 1 do
        local original = source:GetGeometry(0, lod)
        assert(original.primitiveType == TRIANGLE_LIST and original.numVertexBuffers == 1)
        local vb, ib = original:GetVertexBuffer(0), original:GetIndexBuffer()
        local vertices, indices = vb:GetData(), ib:GetData()
        assert(vertices.size >= vb.vertexCount * vb.vertexSize, "缺少正式模型顶点数据")
        local positionOffset = vb:GetElementOffset(SEM_POSITION)
        ---@type table<number,Vector3>
        local positions = {}
        ---@param index integer
        ---@return Vector3
        local function point(index)
            if not positions[index] then
                vertices:Seek(index * vb.vertexSize + positionOffset)
                positions[index] = vertices:ReadVector3()
            end
            return positions[index]
        end
        ---@type table<string,table>
        local groups = {}
        indices:Seek(original.indexStart * ib.indexSize)
        for _ = 1, original.indexCount // 3 do
            local a = ib.indexSize == 2 and indices:ReadUShort() or indices:ReadUInt()
            local b = ib.indexSize == 2 and indices:ReadUShort() or indices:ReadUInt()
            local c = ib.indexSize == 2 and indices:ReadUShort() or indices:ReadUInt()
            local pa, pb, pc = point(a), point(b), point(c)
            local center = (pa + pb + pc) / 3
            local name = select(center.x, center.y, center.z)
            if not groups[name] then groups[name] = {data=VectorBuffer(), count=0, bounds=BoundingBox()} end
            local group = groups[name]
            group.data:WriteUInt(a); group.data:WriteUInt(b); group.data:WriteUInt(c)
            group.count = group.count + 3
            group.bounds:Merge(pa); group.bounds:Merge(pb); group.bounds:Merge(pc)
        end
        local total = 0
        for name, group in pairs(groups) do
            if not parts[name] then
                local model = Model()
                model:SetNumGeometries(1)
                assert(model:SetNumGeometryLodLevels(0, levels))
                parts[name] = {model=model, buffers={}, geometry={}}
            end
            local part = parts[name]
            local buffer, geometry = IndexBuffer(), Geometry()
            buffer.shadowed = true
            assert(buffer:SetSize(group.count, true) and buffer:SetData(group.data))
            assert(geometry:SetNumVertexBuffers(1) and geometry:SetVertexBuffer(0, vb))
            geometry:SetIndexBuffer(buffer)
            assert(geometry:SetDrawRange(TRIANGLE_LIST, 0, group.count, 0, vb.vertexCount))
            geometry.lodDistance = original.lodDistance
            assert(part.model:SetGeometry(0, lod, geometry))
            part.model.boundingBox = source.boundingBox
            part.model:SetGeometryCenter(0, source:GetGeometryCenter(0))
            part.buffers[#part.buffers+1] = buffer
            part.geometry[#part.geometry+1] = geometry
            total = total + group.count
            if lod == 0 then print(string.format("[正式模型拆件] %s/%s：%d原始三角面", key, name, group.count//3)) end
        end
        assert(total == original.indexCount, "正式源模型拆件不允许丢面或增加替代面")
    end
    shared[key] = parts
    return parts
end
return M
