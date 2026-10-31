-- 使用交付MDL原三角面做运行时材质分区，不替换为新车模型。
-- 保留原顶点流、UV接缝、切线法线、包围盒和作者设置的LOD距离。
-- 下方部件坐标单位为米，底部中心为原点，车头+Z。
-- 不从漫反射颜色推断材质：黑车漆不等于轮胎，白塑料不等于金属。
-- 未能确认的边界面保留非金属车身材质。
local Finish = {}
local WheelRefinement = require("VehicleWheelRefinement")

---@class VehicleFinishWheel
---@field z number
---@field y number
---@field radius number
---@field halfWidth number
---@field inner number 已确认轮胎橡胶带的内半径

---@class VehicleFinishBox
---@field min Vector3
---@field max Vector3

---@class VehicleFinishProfile
---@field wheels VehicleFinishWheel[]
---@field leather VehicleFinishBox[]
---@field metal VehicleFinishBox[]
---@field glass VehicleFinishBox[]

---@class VehicleFinishEntry
---@field source Model
---@field model Model
---@field materials Material[]
---@field vertexBuffers VertexBuffer[] 强引用所有原始LOD的共享顶点流
---@field indexBuffers IndexBuffer[]
---@field geometries Geometry[]
---@field triangles integer[]
---@field groups string[]
---@field refinement WheelRefinementHold 细化后的缓冲强引用
---@field refinementReport WheelRefinementReport

---@param x0 number
---@param y0 number
---@param z0 number
---@param x1 number
---@param y1 number
---@param z1 number
---@return VehicleFinishBox
local function box(x0, y0, z0, x1, y1, z1)
    return {min = Vector3(x0, y0, z0), max = Vector3(x1, y1, z1)}
end

-- 依据 screenshots/vehicle-quality/*_parts.png 的真实LOD0三角侧投影与前投影。
-- 0.1米网格逐车定位；宁可保留不确定边界，也不按贴图黑白猜材质。
-- 轮胎用YZ圆环+X带宽，彩绘轮圈不归裸金属；只把轴心小圆域视作金属。
-- 风挡/灯罩维持不透明，不制造透明缝。无可确认风挡的车型只分四类。
---@type table<string, VehicleFinishProfile>
local profiles = {
    sport = {
        wheels = {{z=-0.76,y=0.35,radius=0.355,inner=0.245,halfWidth=0.135}, {z=0.72,y=0.35,radius=0.350,inner=0.240,halfWidth=0.120}},
        leather = {box(-0.22,0.83,-0.53,0.22,0.98,-0.23), box(-0.17,1.065,-0.87,0.17,1.12,-0.65)},
        metal = {box(-0.20,0.22,-0.34,0.20,0.31,0.12), box(-0.16,0.39,-0.20,0.16,0.59,0.12)},
        glass = {box(-0.20,1.10,0.43,0.20,1.255,0.68)},
    },
    rally = {
        wheels = {{z=-0.75,y=0.365,radius=0.365,inner=0.265,halfWidth=0.115}, {z=0.73,y=0.370,radius=0.370,inner=0.270,halfWidth=0.100}},
        leather = {box(-0.19,0.91,-0.64,0.19,1.08,-0.08)},
        metal = {box(-0.18,0.40,-0.14,0.18,0.70,0.20), box(-0.28,0.80,-0.88,-0.16,0.93,-0.51)},
        glass = {box(-0.13,1.07,0.465,0.13,1.19,0.57)},
    },
    cruiser = {
        wheels = {{z=-0.82,y=0.385,radius=0.390,inner=0.280,halfWidth=0.170}, {z=0.83,y=0.405,radius=0.410,inner=0.300,halfWidth=0.145}},
        leather = {box(-0.25,0.855,-0.62,0.25,1.00,-0.23)},
        metal = {box(-0.27,0.40,-0.20,0.27,0.65,0.25), box(-0.40,0.30,-0.66,0.40,0.405,0.21), box(-0.23,0.73,-0.04,0.23,0.91,0.16)},
        glass = {box(-0.14,1.10,0.45,0.14,1.27,0.59)},
    },
    rally_2 = {
        wheels = {{z=-0.723,y=0.430,radius=0.415,inner=0.285,halfWidth=0.115}, {z=0.716,y=0.415,radius=0.425,inner=0.280,halfWidth=0.105}},
        leather = {box(-0.145,1.073,-0.636,0.145,1.153,-0.212)},
        metal = {box(-0.19,0.50,-0.06,0.19,0.72,0.17), box(-0.17,0.435,-0.52,0.17,0.50,0.34)},
        glass = {},
    },
    sport_2 = {
        wheels = {{z=-0.71,y=0.450,radius=0.455,inner=0.340,halfWidth=0.170}, {z=0.71,y=0.445,radius=0.450,inner=0.335,halfWidth=0.145}},
        leather = {box(-0.22,1.14,-0.53,0.22,1.25,-0.22)},
        metal = {box(-0.35,0.48,-0.75,-0.20,0.73,-0.30), box(-0.17,0.61,-0.12,0.17,0.86,0.08)},
        glass = {box(-0.27,1.40,0.42,0.27,1.65,0.69)},
    },
    sport_3 = {
        wheels = {{z=-0.71,y=0.450,radius=0.455,inner=0.335,halfWidth=0.170}, {z=0.71,y=0.435,radius=0.440,inner=0.320,halfWidth=0.140}},
        leather = {box(-0.20,1.105,-0.52,0.20,1.22,-0.21)},
        metal = {box(-0.34,0.47,-0.66,-0.19,0.64,-0.23), box(-0.15,0.58,-0.14,0.15,0.76,0.10)},
        glass = {box(-0.26,1.41,0.38,0.26,1.62,0.66)},
    },
    cruiser_2 = {
        wheels = {{z=-0.82,y=0.425,radius=0.430,inner=0.335,halfWidth=0.185}, {z=0.83,y=0.435,radius=0.440,inner=0.345,halfWidth=0.150}},
        leather = {box(-0.24,0.97,-0.59,0.24,1.14,-0.13)},
        metal = {box(-0.30,0.38,-0.32,0.30,0.65,0.18), box(-0.27,0.72,-0.20,0.27,1.00,0.25), box(-0.35,0.235,-0.78,0.35,0.34,-0.31)},
        glass = {box(-0.16,1.25,0.51,0.16,1.43,0.67)},
    },
    cruiser_3 = {
        wheels = {{z=-0.78,y=0.475,radius=0.480,inner=0.350,halfWidth=0.185}, {z=0.83,y=0.475,radius=0.480,inner=0.350,halfWidth=0.160}},
        leather = {box(-0.24,1.07,-0.76,0.24,1.235,-0.18)},
        metal = {box(-0.26,0.51,-0.16,0.26,0.77,0.24), box(-0.25,0.82,0.15,0.25,1.02,0.29)},
        glass = {box(-0.115,1.18,0.48,0.115,1.36,0.61)},
    },
    rally_3 = {
        wheels = {{z=-0.70,y=0.465,radius=0.470,inner=0.355,halfWidth=0.160}, {z=0.72,y=0.465,radius=0.470,inner=0.355,halfWidth=0.130}},
        leather = {box(-0.18,1.235,-0.735,0.19,1.40,-0.12)},
        metal = {box(-0.25,0.57,-0.13,0.25,0.78,0.18), box(-0.33,0.98,-0.80,-0.18,1.20,-0.47), box(-0.16,0.48,-0.49,0.16,0.56,0.39)},
        glass = {box(-0.17,1.70,0.44,0.17,1.93,0.60)},
    },
}

---@type table<string, VehicleFinishEntry>
local entries = {}
---@type table<string, boolean>
local failed = {}
local names = {"body", "metal", "rubber", "leather", "glass"}
-- 源车存在融合表面，整块透明会露出不应有的洞；玻璃组只改善不透明
-- 灯罩/风挡的表面反射，不宣称完成真实透射玻璃。
local roughness = {0.34, 0.29, 0.88, 0.66, 0.13}
local metallic = {0.0, 0.92, 0.0, 0.0, 0.0}

---@param texture Texture
---@param colorTexture boolean
function Finish.ConfigureTexture(texture, colorTexture)
    texture:SetSRGB(colorTexture)
    texture:SetFilterMode(FILTER_ANISOTROPIC)
    texture:SetAnisotropy(8)
    -- 保留mipmap，不加负LOD偏移，避免高速骑行时闪烁。
    -- 采样设置不能恢复源JPEG/压缩纹理已经丢失的细节。
end

---@param point Vector3
---@param box VehicleFinishBox
---@return boolean
local function inBox(point, box)
    return point.x >= box.min.x and point.x <= box.max.x
        and point.y >= box.min.y and point.y <= box.max.y
        and point.z >= box.min.z and point.z <= box.max.z
end

---@param p Vector3
---@param profile VehicleFinishProfile
---@return integer
local function classify(p, profile)
    for _, w in ipairs(profile.wheels) do
        local distanceSquared = (p.z - w.z)^2 + (p.y - w.y)^2
        -- 外缘仅2%浮点/定位容差；不可扩大到挡泥板，内缘不扩张以免吞轮圈。
        if math.abs(p.x) <= w.halfWidth and distanceSquared <= (w.radius * 1.02)^2 then
            if distanceSquared >= w.inner^2 then return 3 end
            -- 仅接受轮轴附近的小圆域；彩绘轮圈/辐条不自动视为裸金属。
            if distanceSquared <= (w.inner * 0.48)^2 then return 2 end
        end
    end
    for _, box in ipairs(profile.leather) do if inBox(p, box) then return 4 end end
    for _, box in ipairs(profile.glass) do if inBox(p, box) then return 5 end end
    for _, box in ipairs(profile.metal) do if inBox(p, box) then return 2 end end
    return 1
end

---@param c VehicleAssetConfig
---@param source Model
---@return Quaternion, Vector3, number
local function canonicalTransform(c, source)
    local rotation = Quaternion(0, c.rotation, 0)
    local bounds = BoundingBox()
    local b = source.boundingBox
    for _, x in ipairs({b.min.x, b.max.x}) do
        for _, y in ipairs({b.min.y, b.max.y}) do
            for _, z in ipairs({b.min.z, b.max.z}) do bounds:Merge(rotation * Vector3(x, y, z)) end
        end
    end
    return rotation, Vector3(-bounds.center.x, -bounds.min.y, -bounds.center.z), c.targetLength / bounds.size.z
end

---@param base Material
---@param group integer
---@return Material
local function partMaterial(base, group)
    local material = base:Clone()
    material:SetShaderParameter("Metallic", Variant(metallic[group]))
    material:SetShaderParameter("Roughness", Variant(roughness[group]))
    material:SetShaderParameter("MatSpecColor", Variant(Color(0.5, 0.5, 0.5, 16)))
    return material
end

---@class VehicleFinishTriangle
---@field a integer
---@field b integer
---@field c integer
---@field group integer
---@field wheel integer
---@field seed boolean
---@field edges string[]

---@param p Vector3
---@return string
local function pointKey(p)
    return string.format("%.5f/%.5f/%.5f", p.x, p.y, p.z)
end

---@param a string
---@param b string
---@return string
local function edgeKey(a, b)
    return a < b and (a .. "|" .. b) or (b .. "|" .. a)
end

-- 候选轮环按真实位置边连通；从轮心以下的胎面泛洪，剔除上方
-- 独立挡泥板。位置量化只用于诊断邻接，不焊接/改写UV或原顶点。
---@param triangles VehicleFinishTriangle[]
local function keepConnectedRubber(triangles)
    ---@type table<string, integer[]>
    local edges = {}
    ---@type table<number, boolean>
    local visited = {}
    ---@type integer[]
    local queue = {}
    for index, tri in ipairs(triangles) do
        if tri.group == 3 then
            for _, key in ipairs(tri.edges) do
                if not edges[key] then edges[key] = {} end
                local neighbors = edges[key]
                neighbors[#neighbors + 1] = index
            end
            if tri.seed then visited[index] = true; queue[#queue + 1] = index end
        end
    end
    local cursor = 1
    while cursor <= #queue do
        local index = math.floor(queue[cursor])
        local tri = triangles[index]
        for _, key in ipairs(tri.edges) do
            for _, nextIndex in ipairs(edges[key]) do
                if not visited[nextIndex] and triangles[nextIndex].wheel == tri.wheel then
                    visited[nextIndex] = true; queue[#queue + 1] = nextIndex
                end
            end
        end
        cursor = cursor + 1
    end
    local removed = 0
    for index, tri in ipairs(triangles) do
        if tri.group == 3 and not visited[index] then tri.group = 1; removed = removed + 1 end
    end
    return removed
end

---@param id string
---@param c VehicleAssetConfig
---@param originalSource Model
---@param base Material
---@return VehicleFinishEntry
local function build(id, c, originalSource, base)
    local profile = assert(profiles[id], "No verified geometric part profile for " .. id)
    -- 只有已确认低边轮胎的雪脊车型进行局部角向细化，其余原模型直接返回。
    -- 分组守恒相对于细化后的输入；原始资源仍用于远处AI单次绘制。
    local source, refinement, refinementReport = WheelRefinement.Build(originalSource, profile, c)
    assert(source.numGeometries == 1, "Expected delivered single-atlas geometry")
    local rotation, offset, scale = canonicalTransform(c, source)
    local result = Model()
    result.boundingBox = source.boundingBox
    ---@type VehicleFinishEntry
    local entry = {
        source = originalSource, model = result, materials = {}, vertexBuffers = {},
        indexBuffers = {}, geometries = {}, triangles = {}, groups = {},
        refinement = refinement, refinementReport = refinementReport,
    }
    -- 强引用全部原顶点流，不写入资源缓存里的共享缓冲。
    ---@type table<VertexBuffer, Vector3[]>
    local positions = {}
    ---@type table<VertexBuffer, integer[]>
    local vertexGroups = {}
    ---@type table<IndexBuffer, VectorBuffer>
    local sourceIndices = {}
    local lodCount = source:GetNumGeometryLodLevels(0)
    ---@type integer[][][]
    local lodParts = {}
    ---@type table<number, boolean>
    local active = {}
    for lod = 0, lodCount - 1 do
        local geometry = assert(source:GetGeometry(0, lod))
        assert(geometry.primitiveType == TRIANGLE_LIST and geometry.indexCount % 3 == 0, "Invalid triangle draw range")
        local vb = assert(geometry:GetVertexBuffer(0))
        assert(vb:HasElement(TYPE_VECTOR3, SEM_POSITION), "Missing float position stream")
        if not positions[vb] then
            local data = vb:GetData()
            assert(data.size >= vb.vertexCount * vb.vertexSize, "Vertex shadow data unavailable")
            local points, groups = {}, {}
            local positionOffset = vb:GetElementOffset(SEM_POSITION)
            for vertex = 0, vb.vertexCount - 1 do
                data:Seek(vertex * vb.vertexSize + positionOffset)
                local point = (rotation * data:ReadVector3() + offset) * scale
                points[vertex + 1] = point
                groups[vertex + 1] = classify(point, profile)
            end
            positions[vb] = points
            vertexGroups[vb] = groups
            for stream = 0, geometry.numVertexBuffers - 1 do
                entry.vertexBuffers[#entry.vertexBuffers + 1] = assert(geometry:GetVertexBuffer(stream))
            end
        end
        local groups = vertexGroups[vb]
        local points = positions[vb]
        local ib = assert(geometry:GetIndexBuffer())
        if not sourceIndices[ib] then sourceIndices[ib] = ib:GetData() end
        local data = sourceIndices[ib]
        assert(data.size >= (geometry.indexStart + geometry.indexCount) * ib.indexSize, "Index shadow data unavailable")
        data:Seek(geometry.indexStart * ib.indexSize)
        ---@type integer[][]
        local parts = {{}, {}, {}, {}, {}}
        ---@type VehicleFinishTriangle[]
        local triangles = {}
        for _ = 1, geometry.indexCount // 3 do
            local a = ib.indexSize == 2 and data:ReadUShort() or data:ReadUInt()
            local b = ib.indexSize == 2 and data:ReadUShort() or data:ReadUInt()
            local d = ib.indexSize == 2 and data:ReadUShort() or data:ReadUInt()
            local ca, cb, cd = assert(groups[a + 1]), assert(groups[b + 1]), assert(groups[d + 1])
            -- 金属/玻璃仍要求三个顶点全在可信区域。轮胎和细长座垫面允许
            -- 中心位于同一区域且至少两个顶点同类，避免边界容差造成高光斑块。
            local group = ca == cb and cb == cd and ca or 1
            local wheelIndex, seed = 0, false
            if group == 1 then
                local center = Vector3((points[a + 1].x + points[b + 1].x + points[d + 1].x) / 3,
                    (points[a + 1].y + points[b + 1].y + points[d + 1].y) / 3,
                    (points[a + 1].z + points[b + 1].z + points[d + 1].z) / 3)
                local centerGroup = classify(center, profile)
                if centerGroup == 3 or centerGroup == 4 then
                    local matches = (ca == centerGroup and 1 or 0) + (cb == centerGroup and 1 or 0) + (cd == centerGroup and 1 or 0)
                    if matches >= 2 then group = centerGroup end
                end
            end
            if group == 3 then
                local pa, pb, pd = points[a + 1], points[b + 1], points[d + 1]
                local edgeAB = pa - pb --[[@as Vector3]]
                local edgeBD = pb - pd --[[@as Vector3]]
                local edgeDA = pd - pa --[[@as Vector3]]
                -- 车腹/挡泥板的跨部件长面可能三个角恰落在轮胎圆环内，
                -- 必须整面属于同一个轮环，禁止跨前后轮或横跨大孔洞。
                local oneWheel = false
                for index, wheel in ipairs(profile.wheels) do
                    local function inside(p)
                        local r2 = (p.z - wheel.z)^2 + (p.y - wheel.y)^2
                        return r2 >= wheel.inner^2 and r2 <= (wheel.radius * 1.02)^2
                            and math.abs(p.x) <= wheel.halfWidth
                    end
                    local center = (pa + pb + pd) / 3
                    if inside(center) and (inside(pa) or inside(pb)) and (inside(pb) or inside(pd))
                        and edgeAB:Length() <= wheel.radius * 1.3
                        and edgeBD:Length() <= wheel.radius * 1.3
                        and edgeDA:Length() <= wheel.radius * 1.3 then
                        oneWheel, wheelIndex = true, index
                        seed = center.y < wheel.y - wheel.radius * 0.20
                        break
                    end
                end
                if not oneWheel then group = 1 end
            end
            local keys = {pointKey(points[a + 1]), pointKey(points[b + 1]), pointKey(points[d + 1])}
            triangles[#triangles + 1] = {
                a = a, b = b, c = d, group = group, wheel = wheelIndex, seed = seed,
                edges = {edgeKey(keys[1],keys[2]), edgeKey(keys[2],keys[3]), edgeKey(keys[3],keys[1])},
            }
        end
        local rejectedRubber = keepConnectedRubber(triangles)
        for _, tri in ipairs(triangles) do
            local target = parts[tri.group]
            target[#target + 1] = tri.a; target[#target + 1] = tri.b; target[#target + 1] = tri.c
            active[tri.group] = true
        end
        print(string.format("[VehicleFinish] %s LOD%d disconnected rubber rejected=%d", id, lod, rejectedRubber))
        local sum = 0
        local counts = {}
        for group, part in ipairs(parts) do
            sum = sum + #part
            counts[#counts + 1] = names[group] .. "=" .. tostring(#part // 3)
        end
        assert(sum == geometry.indexCount, "Partition lost or duplicated triangles")
        print(string.format("[VehicleFinish] %s LOD%d source=%d split=%d (%s), lodDistance=%.4f", id, lod, geometry.indexCount // 3, sum // 3, table.concat(counts, ","), geometry.lodDistance))
        entry.triangles[lod + 1] = sum // 3
        lodParts[lod + 1] = parts
    end
    local activeGroups = {}
    for group = 1, #names do
        if active[group] then
            activeGroups[#activeGroups + 1] = group
            entry.groups[#entry.groups + 1] = names[group]
            entry.materials[#entry.materials + 1] = partMaterial(base, group)
        end
    end
    assert(#activeGroups > 1 and #activeGroups <= 5, "No credible part separation")
    result:SetNumGeometries(#activeGroups)
    for slot = 0, #activeGroups - 1 do assert(result:SetNumGeometryLodLevels(slot, lodCount)) end
    for lod = 0, lodCount - 1 do
        local sourceGeometry = source:GetGeometry(0, lod)
        local parts = lodParts[lod + 1]
        local data = VectorBuffer()
        for _, group in ipairs(activeGroups) do
            for _, index in ipairs(parts[group]) do data:WriteUInt(index) end
        end
        local ib = IndexBuffer()
        ib.shadowed = true
        assert(ib:SetSize(sourceGeometry.indexCount, true))
        assert(ib:SetData(data))
        entry.indexBuffers[#entry.indexBuffers + 1] = ib
        local start = 0
        for slot, group in ipairs(activeGroups) do
            local geometry = Geometry()
            assert(geometry:SetNumVertexBuffers(sourceGeometry.numVertexBuffers))
            for stream = 0, sourceGeometry.numVertexBuffers - 1 do
                assert(geometry:SetVertexBuffer(stream, sourceGeometry:GetVertexBuffer(stream)))
            end
            geometry:SetIndexBuffer(ib)
            assert(geometry:SetDrawRange(TRIANGLE_LIST, start, #parts[group], sourceGeometry.vertexStart, sourceGeometry.vertexCount))
            geometry.lodDistance = sourceGeometry.lodDistance
            assert(result:SetGeometry(slot - 1, lod, geometry))
            result:SetGeometryCenter(slot - 1, source:GetGeometryCenter(0))
            entry.geometries[#entry.geometries + 1] = geometry
            start = start + #parts[group]
        end
        assert(start == sourceGeometry.indexCount, "Draw ranges do not cover source triangles")
    end
    print(string.format("[VehicleFinish] %s ready: %d parts [%s], %d LODs, LOD0=%d tris; source UV/N/T unchanged; opaque glazing", id, #activeGroups, table.concat(entry.groups, ","), lodCount, entry.triangles[1]))
    return entry
end

---@param id string
---@param c VehicleAssetConfig
---@param source Model
---@param base Material
---@return VehicleFinishEntry?
function Finish.Get(id, c, source, base)
    if entries[id] then return entries[id] end
    if failed[id] then return nil end
    local ok, entry = pcall(build, id, c, source, base)
    if not ok then
        failed[id] = true
        print("[VehicleFinish] " .. id .. " FALLBACK original single material; separation NOT applied: " .. tostring(entry))
        return nil
    end
    entries[id] = entry
    return entry
end

---@param config VehicleAssetConfig
---@return boolean, any
function Finish.Test(config)
    local ok, err = pcall(function()
        local model = assert(cache:GetResource("Model", config.model))
        local geometry = assert(model:GetGeometry(0, 0))
        local vb = assert(geometry:GetVertexBuffer(0))
        local ib = assert(geometry:GetIndexBuffer())
        local vertices, indices = vb:GetData(), ib:GetData()
        assert(vertices.size >= vb.vertexCount * vb.vertexSize, "Vertex shadow data unavailable")
        assert(indices.size >= ib.indexCount * ib.indexSize, "Index shadow data unavailable")
        vertices:Seek(vb:GetElementOffset(SEM_POSITION))
        local p = vertices:ReadVector3()
        local copy = Model()
        copy:SetNumGeometries(1)
        assert(copy:SetNumGeometryLodLevels(0, model:GetNumGeometryLodLevels(0)))
        local g = Geometry()
        assert(g:SetNumVertexBuffers(geometry.numVertexBuffers))
        for index = 0, geometry.numVertexBuffers - 1 do assert(g:SetVertexBuffer(index, geometry:GetVertexBuffer(index))) end
        g:SetIndexBuffer(ib)
        assert(g:SetDrawRange(TRIANGLE_LIST, geometry.indexStart, geometry.indexCount, geometry.vertexStart, geometry.vertexCount))
        g.lodDistance = geometry.lodDistance
        assert(copy:SetGeometry(0, 0, g))
        copy.boundingBox = model.boundingBox
        print(string.format("[VehicleFinish probe] PASS vb=%d bytes=%d, ib=%d bytes=%d, p=(%.5f %.5f %.5f), sharedVB tris=%d", vb.vertexCount, vertices.size, ib.indexCount, indices.size, p.x, p.y, p.z, g.indexCount // 3))
    end)
    if not ok then print("[VehicleFinish probe] FAILED " .. tostring(err)) end
    return ok, err
end

return Finish
