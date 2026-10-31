-- 仅细化已确认的轮胎圆环，不重建车架/发动机，不改写源MDL或缓存缓冲。
-- 输入profile坐标：与VehicleAssets.Add一致，米制、底部居中、+Z为前。
-- 边界策略：原顶点不动；仅两侧都属于同一轮胎的流形内部边可插点。
-- UV缝保留独立索引，但用位置焊接检查邻接，缝两侧中点位置完全一致。
local Refinement = {}

---@class WheelRefinementVertex
---@field values number[]
---@field point Vector3 源模型坐标
---@field canonical Vector3 规范米坐标

---@class WheelRefinementHold
---@field source Model
---@field model Model?
---@field vertexBuffers VertexBuffer[]
---@field indexBuffers IndexBuffer[]
---@field geometries Geometry[]

---@class WheelRefinementReport
---@field applied boolean
---@field reason string
---@field lods table[]

---@param c VehicleAssetConfig
---@param source Model
local function transform(c, source)
    local rotation = Quaternion(0, c.rotation, 0)
    local b, bounds = source.boundingBox, BoundingBox()
    for _, x in ipairs({b.min.x, b.max.x}) do
        for _, y in ipairs({b.min.y, b.max.y}) do
            for _, z in ipairs({b.min.z, b.max.z}) do bounds:Merge(rotation * Vector3(x, y, z)) end
        end
    end
    return rotation, Vector3(-bounds.center.x, -bounds.min.y, -bounds.center.z), c.targetLength / bounds.size.z
end

---@param p Vector3
---@param profile VehicleFinishProfile
---@return integer
local function wheelAt(p, profile)
    for i, w in ipairs(profile.wheels) do
        local r = math.sqrt((p.y - w.y)^2 + (p.z - w.z)^2)
        if math.abs(p.x) <= w.halfWidth and r >= w.inner and r <= w.radius then return i end
    end
    return 0
end

---@param p Vector3
local function positionKey(p)
    -- 源模型单位下1微米量化只用于拓扑邻接，绝不把原顶点焊成一个索引。
    return string.format("%.6f/%.6f/%.6f", p.x, p.y, p.z)
end

---@param a string
---@param b string
local function edgeKey(a, b)
    if a < b then return a .. "|" .. b end
    return b .. "|" .. a
end

---@param p Vector3
---@param box BoundingBox
local function inside(p, box)
    return p.x >= box.min.x and p.x <= box.max.x
        and p.y >= box.min.y and p.y <= box.max.y
        and p.z >= box.min.z and p.z <= box.max.z
end

---@param vertices WheelRefinementVertex[]
---@param triangles integer[][]
---@param profile VehicleFinishProfile
---@param rotation Quaternion
---@param offset Vector3
---@param scale number
---@param box BoundingBox
---@param positionIndex integer
---@param normalIndex integer
---@param tangentIndex integer
local function subdivide(vertices, triangles, profile, rotation, offset, scale, box, positionIndex, normalIndex, tangentIndex)
    ---@type table<string, table>
    local edges = {}
    ---@type table<number, string>
    local keys = {}
    for i, v in ipairs(vertices) do keys[i] = positionKey(v.point) end
    for _, tri in ipairs(triangles) do
        local ia = math.floor(tri[1])
        local ib = math.floor(tri[2])
        local ic = math.floor(tri[3])
        local va = vertices[ia] --[[@as WheelRefinementVertex]]
        local vb = vertices[ib] --[[@as WheelRefinementVertex]]
        local vc = vertices[ic] --[[@as WheelRefinementVertex]]
        local wa, wb, wc = wheelAt(va.canonical, profile), wheelAt(vb.canonical, profile), wheelAt(vc.canonical, profile)
        local wheel = wa > 0 and wa == wb and wb == wc and wa or 0
        for j = 1, 3 do
            local a = math.floor(tri[j])
            local b = math.floor(tri[j % 3 + 1])
            local k = edgeKey(keys[a], keys[b])
            local e = edges[k]
            if not e then e = {a = a, b = b, count = 0, wheel = wheel, safe = true}; edges[k] = e end
            e.count = e.count + 1
            if wheel == 0 or e.wheel ~= wheel then e.safe = false end
        end
    end
    local inverse = rotation:Inverse()
    local selected, rejected = 0, 0
    for _, e in pairs(edges) do
        e.split = false
        if e.safe and e.count == 2 and e.wheel > 0 then
            local a, b, w = vertices[e.a].canonical, vertices[e.b].canonical, profile.wheels[e.wheel]
            local ay, az, by, bz = a.y - w.y, a.z - w.z, b.y - w.y, b.z - w.z
            local ra, rb = math.sqrt(ay * ay + az * az), math.sqrt(by * by + bz * bz)
            local cosine = (ay * by + az * bz) / (ra * rb)
            local angle = math.acos(math.max(-1, math.min(1, cosine)))
            -- 只加密角向边；跨截面大对角线、几乎径向边、轮圈/车架连接边不碰。
            if angle >= math.rad(2.5) and angle <= math.rad(45)
                and math.abs(ra - rb) <= 0.06 and math.abs(a.x - b.x) <= 0.08 then
                local my, mz, radius = (ay + by) * 0.5, (az + bz) * 0.5, (ra + rb) * 0.5
                local length = math.sqrt(my * my + mz * mz)
                if length > 0.00001 then
                    local canonical = Vector3((a.x + b.x) * 0.5, w.y + my * radius / length, w.z + mz * radius / length)
                    local point = inverse * (canonical / scale - offset)
                    -- 不扩原bbox，避免后续Add/Finish重新归一化改变整车尺寸。
                    if inside(point, box) then
                        e.point, e.canonical, e.split = point, canonical, true
                        selected = selected + 1
                    else rejected = rejected + 1 end
                end
            end
        elseif e.wheel > 0 then rejected = rejected + 1 end
    end
    ---@type table<string, integer>
    local midpoints = {}
    ---@param a integer
    ---@param b integer
    ---@return integer
    local function midpoint(a, b)
        local e = edges[edgeKey(keys[a], keys[b])]
        if not e.split then return 0 end
        local k = a < b and (a .. ":" .. b) or (b .. ":" .. a)
        if midpoints[k] then return midpoints[k] end
        local av = vertices[a].values --[[@as table<number, number>]]
        local bv = vertices[b].values --[[@as table<number, number>]]
        ---@type table<number, number>
        local values = {}
        for i = 1, #av do values[i] = (av[i] + bv[i]) * 0.5 end
        values[positionIndex], values[positionIndex + 1], values[positionIndex + 2] = e.point.x, e.point.y, e.point.z
        local n = Vector3(values[normalIndex], values[normalIndex + 1], values[normalIndex + 2]):Normalized()
        values[normalIndex], values[normalIndex + 1], values[normalIndex + 2] = n.x, n.y, n.z
        if tangentIndex > 0 then
            local t = Vector3(values[tangentIndex], values[tangentIndex + 1], values[tangentIndex + 2])
            local tangent = (t - n * n:DotProduct(t)):Normalized()
            values[tangentIndex], values[tangentIndex + 1], values[tangentIndex + 2] = tangent.x, tangent.y, tangent.z
            -- UV缝处不混合不同手性的切线架；符号沿用该索引边端点。
            values[tangentIndex + 3] = av[tangentIndex + 3] < 0 and -1 or 1
        end
        local index = #vertices + 1
        vertices[index] = {values = values, point = e.point, canonical = e.canonical}
        midpoints[k] = index
        return index
    end
    ---@type integer[][]
    local output = {}
    ---@param a integer
    ---@param b integer
    ---@param c integer
    ---@param normal Vector3
    local function add(a, b, c, normal)
        local face = (vertices[b].point - vertices[a].point):CrossProduct(vertices[c].point - vertices[a].point)
        assert(face:DotProduct(normal) > 0, "局部轮胎细化将翻面，拒绝应用")
        output[#output + 1] = {a, b, c}
    end
    for _, tri in ipairs(triangles) do
        local a = math.floor(tri[1])
        local b = math.floor(tri[2])
        local c = math.floor(tri[3])
        local ab, bc, ca = midpoint(a, b), midpoint(b, c), midpoint(c, a)
        local va = vertices[a] --[[@as WheelRefinementVertex]]
        local vb = vertices[b] --[[@as WheelRefinementVertex]]
        local vc = vertices[c] --[[@as WheelRefinementVertex]]
        local normal = (vb.point - va.point):CrossProduct(vc.point - va.point)
        local count = (ab > 0 and 1 or 0) + (bc > 0 and 1 or 0) + (ca > 0 and 1 or 0)
        if count == 0 then output[#output + 1] = tri
        elseif count == 3 then
            add(a,ab,ca,normal); add(ab,b,bc,normal); add(ca,bc,c,normal); add(ab,bc,ca,normal)
        elseif count == 1 then
            if ab > 0 then add(a,ab,c,normal); add(ab,b,c,normal)
            elseif bc > 0 then add(b,bc,a,normal); add(bc,c,a,normal)
            else add(c,ca,b,normal); add(ca,a,b,normal) end
        else
            -- 各缺边使用固定模板，三角顺序与原面一致。
            if ca == 0 then
                add(a,ab,c,normal); add(ab,bc,c,normal); add(ab,b,bc,normal)
            elseif ab == 0 then
                add(c,ca,bc,normal); add(ca,a,b,normal); add(ca,b,bc,normal)
            else
                add(a,ab,ca,normal); add(ab,b,c,normal); add(ab,c,ca,normal)
            end
        end
    end
    return output, selected, rejected
end

---@param source Model
---@param profile VehicleFinishProfile
---@param config VehicleAssetConfig
---@param hold WheelRefinementHold
---@param report WheelRefinementReport
local function build(source, profile, config, hold, report)
    assert(source.numGeometries == 1 and source.numMorphs == 0, "仅支持已确认静态单图集模型")
    local rotation, offset, scale = transform(config, source)
    local result = Model()
    result.boundingBox = source.boundingBox
    result:SetNumGeometries(1)
    local levels = source:GetNumGeometryLodLevels(0)
    assert(result:SetNumGeometryLodLevels(0, levels))
    for lod = 0, levels - 1 do
        local original = assert(source:GetGeometry(0, lod))
        if lod > 1 then
            assert(result:SetGeometry(0, lod, original))
            hold.geometries[#hold.geometries + 1] = original
        else
            assert(original.primitiveType == TRIANGLE_LIST and original.numVertexBuffers == 1, "轮胎细化不支持此顶点流")
            local oldVB, oldIB = assert(original:GetVertexBuffer(0)), assert(original:GetIndexBuffer())
            assert(oldVB:HasElement(TYPE_VECTOR3, SEM_POSITION) and oldVB:HasElement(TYPE_VECTOR3, SEM_NORMAL), "需要浮点位置与法线")
            local covered = 0
            for _, e in ipairs(oldVB:GetElements()) do
                assert(not e.perInstance, "不处理实例顶点")
                local components = e.type == TYPE_FLOAT and 1 or e.type == TYPE_VECTOR2 and 2 or e.type == TYPE_VECTOR3 and 3 or e.type == TYPE_VECTOR4 and 4 or 0
                assert(components > 0, "未知/压缩顶点元素，不做盲插值")
                covered = covered + components * 4
            end
            assert(covered == oldVB.vertexSize, "顶点布局存在未识别填充")
            local pi = oldVB:GetElementOffset(SEM_POSITION) // 4 + 1
            local ni = oldVB:GetElementOffset(SEM_NORMAL) // 4 + 1
            local ti = oldVB:HasElement(TYPE_VECTOR4, SEM_TANGENT) and (oldVB:GetElementOffset(SEM_TANGENT) // 4 + 1) or 0
            local vd, id = oldVB:GetData(), oldIB:GetData()
            assert(vd.size >= oldVB.vertexCount * oldVB.vertexSize, "无源顶点shadow data")
            assert(id.size >= (original.indexStart + original.indexCount) * oldIB.indexSize, "无源索引shadow data")
            ---@type WheelRefinementVertex[]
            local vertices = {}
            vd:Seek(0)
            for i = 1, oldVB.vertexCount do
                local values = {}
                for j = 1, oldVB.vertexSize // 4 do values[j] = vd:ReadFloat() end
                local p = Vector3(values[pi], values[pi + 1], values[pi + 2])
                vertices[i] = {values = values, point = p, canonical = (rotation * p + offset) * scale}
            end
            ---@type integer[][]
            local tris = {}
            id:Seek(original.indexStart * oldIB.indexSize)
            for _ = 1, original.indexCount // 3 do
                local tri = {}
                for j = 1, 3 do tri[j] = (oldIB.indexSize == 2 and id:ReadUShort() or id:ReadUInt()) + 1 end
                tris[#tris + 1] = tri
            end
            local splits, skipped = 0, 0
            for _ = 1, 2 do
                local nextTris, count, rejected = subdivide(vertices, tris, profile, rotation, offset, scale, source.boundingBox, pi, ni, ti)
                tris, splits, skipped = nextTris, splits + count, skipped + rejected
            end
            assert(splits > 0, "安全轮胎角向边不足，不应用")
            local vertexData, indexData = VectorBuffer(), VectorBuffer()
            for _, v in ipairs(vertices) do for _, value in ipairs(v.values) do vertexData:WriteFloat(value) end end
            for _, tri in ipairs(tris) do for _, index in ipairs(tri) do indexData:WriteUInt(index - 1) end end
            local vb, ib, geometry = VertexBuffer(), IndexBuffer(), Geometry()
            vb.shadowed, ib.shadowed = true, true
            assert(vb:SetSize(#vertices, oldVB:GetElements()) and vb:SetData(vertexData))
            assert(ib:SetSize(#tris * 3, true) and ib:SetData(indexData))
            assert(geometry:SetNumVertexBuffers(1) and geometry:SetVertexBuffer(0, vb))
            geometry:SetIndexBuffer(ib)
            assert(geometry:SetDrawRange(TRIANGLE_LIST, 0, #tris * 3, 0, #vertices))
            geometry.lodDistance = original.lodDistance
            assert(result:SetGeometry(0, lod, geometry))
            hold.vertexBuffers[#hold.vertexBuffers + 1] = vb
            hold.indexBuffers[#hold.indexBuffers + 1] = ib
            hold.geometries[#hold.geometries + 1] = geometry
            report.lods[#report.lods + 1] = {lod = lod, before = original.indexCount // 3, after = #tris, splitEdges = splits, unsafeEdgesSkipped = skipped}
            print(string.format("[轮胎局部细化] %s LOD%d %d→%d三角，角向边%d，跳过边界%d，距离%.3f不变", config.label, lod, original.indexCount // 3, #tris, splits, skipped, original.lodDistance))
        end
    end
    result:SetGeometryCenter(0, source:GetGeometryCenter(0))
    hold.model = result
    return result
end

---@param source Model
---@param profile VehicleFinishProfile
---@param config VehicleAssetConfig
---@return Model, WheelRefinementHold, WheelRefinementReport
function Refinement.Build(source, profile, config)
    ---@type WheelRefinementHold
    local hold = {source = source, vertexBuffers = {}, indexBuffers = {}, geometries = {}}
    ---@type WheelRefinementReport
    local report = {applied = false, reason = "仅雪脊拉力已确认圆环", lods = {}}
    if not config.model:find("ebd838bd-fcf9-537c-abfb-2e9780daa3bb", 1, true) then return source, hold, report end
    local ok, model = pcall(build, source, profile, config, hold, report)
    if not ok then
        report.reason = tostring(model)
        print("[轮胎局部细化] 不安全或API不可用，保留原模型：" .. report.reason)
        return source, hold, report
    end
    report.applied, report.reason = true, "仅确认轮胎内部角向边；UV/截面/原边界保留"
    return model, hold, report
end

return Refinement
