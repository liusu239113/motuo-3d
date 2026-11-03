-- 资源库交付包；路径相对于资源根，不包含assets/前缀。
-- 源包围盒已用UrhoXCLI model-info检查；前向用真实引擎截图或MDL顶点三角面校准。
-- Add返回无缩放、底部居中、前向+Z的挂接节点，不创建物理刚体。
---@class VehicleAssetLibrary
---@field Vehicles table<string, VehicleAssetConfig>
---@field Resources string[]
---@field ResourceTypes table<string, string>
---@field TrafficIds string[]
local VehicleAssets = {}
local VehicleFinish = require("VehicleFinish")

---@class VehicleAssetConfig
---@field model string
---@field material string
---@field diffuse string
---@field normal string
---@field rotation number 偏航校正角（度）
---@field targetLength number 米
---@field targetSize Vector3 归一化后的近似范围，不做非等比缩放
---@field measuredSize Vector3 原始MDL包围盒尺寸
---@field resources string[]
---@field label string
---@field class? string sport/cruiser/rally为摩托；traffic为四轮车
---@field note? string

---@type table<string, VehicleAssetConfig>
VehicleAssets.Vehicles = {
    sport = {
        label = "赤焰 · 仿赛",
        model = "model/4530ce8f-8773-5981-94fa-44f452b87ace/Meshes/666479f191164845b1257b4d3c8698a7.mdl",
        material = "model/4530ce8f-8773-5981-94fa-44f452b87ace/Materials/666479f191164845b1257b4d3c8698a7_00_tripo_material_3d9a56b8-a0fe-402e-bcb7-2f95b412b704.xml",
        diffuse = "model/4530ce8f-8773-5981-94fa-44f452b87ace/Textures/666479f191164845b1257b4d3c8698a7_00_D.jpg",
        normal = "model/4530ce8f-8773-5981-94fa-44f452b87ace/Textures/666479f191164845b1257b4d3c8698a7_00_N.jpg",
        rotation = 180, targetLength = 2.15,
        targetSize = Vector3(0.997, 1.250, 2.15), measuredSize = Vector3(0.462891, 0.580078, 0.998047),
        resources = {
            "model/4530ce8f-8773-5981-94fa-44f452b87ace/Textures/666479f191164845b1257b4d3c8698a7_00_D.xml",
            "model/4530ce8f-8773-5981-94fa-44f452b87ace/Textures/666479f191164845b1257b4d3c8698a7_00_N.xml",
        },
    },
    rally = {
        label = "荒野 · 拉力",
        model = "model/1e4b6b1b-72c5-5195-991f-dfaf8dc23cc2/Meshes/58b7eddf55674a53a43e61df157ee12c.mdl",
        material = "model/1e4b6b1b-72c5-5195-991f-dfaf8dc23cc2/Materials/58b7eddf55674a53a43e61df157ee12c_00_tripo_material_a6984b4f-6344-4c98-bb05-461bdfd28983.xml",
        diffuse = "model/1e4b6b1b-72c5-5195-991f-dfaf8dc23cc2/Textures/58b7eddf55674a53a43e61df157ee12c_00_D.jpg",
        normal = "model/1e4b6b1b-72c5-5195-991f-dfaf8dc23cc2/Textures/58b7eddf55674a53a43e61df157ee12c_00_N.jpg",
        rotation = 180, targetLength = 2.22,
        targetSize = Vector3(1.064, 1.334, 2.22), measuredSize = Vector3(0.478516, 0.599609, 0.998047),
        resources = {
            "model/1e4b6b1b-72c5-5195-991f-dfaf8dc23cc2/Textures/58b7eddf55674a53a43e61df157ee12c_00_D.xml",
            "model/1e4b6b1b-72c5-5195-991f-dfaf8dc23cc2/Textures/58b7eddf55674a53a43e61df157ee12c_00_N.xml",
        },
    },
    sedan = {
        label = "城市轿车",
        model = "model/f17e2264-956a-5fa2-ba41-2287fc02934a/Meshes/3299d6bc46c84215a963d4b7ec4ba7e8.mdl",
        material = "model/f17e2264-956a-5fa2-ba41-2287fc02934a/Materials/3299d6bc46c84215a963d4b7ec4ba7e8_00_tripo_material_6c6172ab-4050-4a96-9225-7238f94479e0.xml",
        diffuse = "model/f17e2264-956a-5fa2-ba41-2287fc02934a/Textures/3299d6bc46c84215a963d4b7ec4ba7e8_00_D.jpg",
        normal = "model/f17e2264-956a-5fa2-ba41-2287fc02934a/Textures/3299d6bc46c84215a963d4b7ec4ba7e8_00_N.jpg",
        rotation = -90, targetLength = 4.6,
        targetSize = Vector3(2.205, 1.575, 4.6), measuredSize = Vector3(0.998047, 0.341797, 0.478516),
        resources = {
            "model/f17e2264-956a-5fa2-ba41-2287fc02934a/Textures/3299d6bc46c84215a963d4b7ec4ba7e8_00_D.xml",
            "model/f17e2264-956a-5fa2-ba41-2287fc02934a/Textures/3299d6bc46c84215a963d4b7ec4ba7e8_00_N.xml",
        },
    },
    suv = {
        label = "跨界 SUV",
        model = "model/ad2bd9f3-98a6-5e00-927c-9f5bcc0c5430/Meshes/d598150db01f4e538e87d0cf9c27695a.mdl",
        material = "model/ad2bd9f3-98a6-5e00-927c-9f5bcc0c5430/Materials/d598150db01f4e538e87d0cf9c27695a_00_tripo_material_6bd733ca-7f9b-407c-be96-07200829d3c5.xml",
        diffuse = "model/ad2bd9f3-98a6-5e00-927c-9f5bcc0c5430/Textures/d598150db01f4e538e87d0cf9c27695a_00_D.jpg",
        normal = "model/ad2bd9f3-98a6-5e00-927c-9f5bcc0c5430/Textures/d598150db01f4e538e87d0cf9c27695a_00_N.jpg",
        rotation = -90, targetLength = 4.7,
        targetSize = Vector3(2.456, 1.793, 4.7), measuredSize = Vector3(0.998047, 0.380859, 0.521484),
        resources = {
            "model/ad2bd9f3-98a6-5e00-927c-9f5bcc0c5430/Textures/d598150db01f4e538e87d0cf9c27695a_00_D.xml",
            "model/ad2bd9f3-98a6-5e00-927c-9f5bcc0c5430/Textures/d598150db01f4e538e87d0cf9c27695a_00_N.xml",
        },
    },
    truck = {
        label = "厢式货车",
        model = "model/8f581573-e1fe-5c1b-a88f-6fc4ae9ac09d/Meshes/ecb5c5d083ec481f8b58c2f1c79dc840.mdl",
        material = "model/8f581573-e1fe-5c1b-a88f-6fc4ae9ac09d/Materials/ecb5c5d083ec481f8b58c2f1c79dc840_00_tripo_material_3e70142b-fc3a-42cc-97b4-328656631119.xml",
        diffuse = "model/8f581573-e1fe-5c1b-a88f-6fc4ae9ac09d/Textures/ecb5c5d083ec481f8b58c2f1c79dc840_00_D.jpg",
        normal = "model/8f581573-e1fe-5c1b-a88f-6fc4ae9ac09d/Textures/ecb5c5d083ec481f8b58c2f1c79dc840_00_N.jpg",
        rotation = -90, targetLength = 5.4,
        targetSize = Vector3(2.758, 2.695, 5.4), measuredSize = Vector3(0.998047, 0.498047, 0.509766),
        resources = {
            "model/8f581573-e1fe-5c1b-a88f-6fc4ae9ac09d/Textures/ecb5c5d083ec481f8b58c2f1c79dc840_00_D.xml",
            "model/8f581573-e1fe-5c1b-a88f-6fc4ae9ac09d/Textures/ecb5c5d083ec481f8b58c2f1c79dc840_00_N.xml",
        },
    },
}

-- 经用户确认四视图生成的独立巡航整车；原MDL长轴偏45度，已由官方工具校正为+Z。
-- 尺寸来自校正后全部LOD顶点包围盒，不再保留程序化车体回退。
VehicleAssets.Vehicles.cruiser = {
    label = "远行 · 巡航", note = "独立生成的低座宽把 V-twin 整车，非扫描资产",
    model = "model/03c82d85d9f642fbb28a534e2ce05c64/Meshes/03c82d85d9f642fbb28a534e2ce05c64.mdl",
    material = "model/03c82d85d9f642fbb28a534e2ce05c64/Materials/03c82d85d9f642fbb28a534e2ce05c64_00_tripo_material_4fc1c45a-95e2-433f-ba01-87db36e367d6.xml",
    diffuse = "model/03c82d85d9f642fbb28a534e2ce05c64/Textures/03c82d85d9f642fbb28a534e2ce05c64_00_D.jpg",
    normal = "model/03c82d85d9f642fbb28a534e2ce05c64/Textures/03c82d85d9f642fbb28a534e2ce05c64_00_N.png",
    rotation = 0, targetLength = 2.45,
    targetSize = Vector3(1.3628, 1.6641, 2.45), measuredSize = Vector3(0.758206, 0.925829, 1.363114),
    resources = {
        "model/03c82d85d9f642fbb28a534e2ce05c64/Textures/03c82d85d9f642fbb28a534e2ce05c64_00_D.xml",
        "model/03c82d85d9f642fbb28a534e2ce05c64/Textures/03c82d85d9f642fbb28a534e2ce05c64_00_N.xml",
    },
}

-- 警车顶点侧投影确认车头为原始+X，yaw -90后朝+Z；保留独立实车及贴图。
VehicleAssets.Vehicles.police = {
    label = "公路巡警", class = "traffic",
    model = "model/0d64b489-328b-5ec0-854c-d1d8f93097ba/Meshes/c5a4c601aa1f4763ac63aee761ceb44d.mdl",
    material = "model/0d64b489-328b-5ec0-854c-d1d8f93097ba/Materials/c5a4c601aa1f4763ac63aee761ceb44d_00_tripo_material_c19a6c59-414d-4fc0-8a14-12be486eba42.xml",
    diffuse = "model/0d64b489-328b-5ec0-854c-d1d8f93097ba/Textures/c5a4c601aa1f4763ac63aee761ceb44d_00_D.jpg",
    normal = "model/0d64b489-328b-5ec0-854c-d1d8f93097ba/Textures/c5a4c601aa1f4763ac63aee761ceb44d_00_N.jpg",
    rotation = -90, targetLength = 4.6,
    targetSize = Vector3(2.16947, 1.62935, 4.6), measuredSize = Vector3(0.998047, 0.353516, 0.470703),
    resources = {
        "model/0d64b489-328b-5ec0-854c-d1d8f93097ba/Textures/c5a4c601aa1f4763ac63aee761ceb44d_00_D.xml",
        "model/0d64b489-328b-5ec0-854c-d1d8f93097ba/Textures/c5a4c601aa1f4763ac63aee761ceb44d_00_N.xml",
    },
}

-- 六款独立摩托均已交付真实MDL及D/N；原始顶点三角面侧投影确认方向。
-- rally_2原始车头-Z；其余五款原始车头+X，统一挂接前向+Z。
VehicleAssets.Vehicles.rally_2 = {
    label = "雪脊 · 轻越野", class = "rally",
    model = "model/ebd838bd-fcf9-537c-abfb-2e9780daa3bb/Meshes/4676a19b2ba94616879aeaa3c5fe5578.mdl",
    material = "model/ebd838bd-fcf9-537c-abfb-2e9780daa3bb/Materials/4676a19b2ba94616879aeaa3c5fe5578_00_tripo_material_14627500-25b3-42ef-9715-e3113def5afb.xml",
    diffuse = "model/ebd838bd-fcf9-537c-abfb-2e9780daa3bb/Textures/4676a19b2ba94616879aeaa3c5fe5578_00_D.jpg",
    normal = "model/ebd838bd-fcf9-537c-abfb-2e9780daa3bb/Textures/4676a19b2ba94616879aeaa3c5fe5578_00_N.jpg",
    rotation = 180, targetLength = 2.22,
    targetSize = Vector3(1.116517, 1.438004, 2.22), measuredSize = Vector3(0.501953125, 0.646484375, 0.998046875),
    resources = {
        "model/ebd838bd-fcf9-537c-abfb-2e9780daa3bb/Textures/4676a19b2ba94616879aeaa3c5fe5578_00_D.xml",
        "model/ebd838bd-fcf9-537c-abfb-2e9780daa3bb/Textures/4676a19b2ba94616879aeaa3c5fe5578_00_N.xml",
    },
}
VehicleAssets.Vehicles.sport_2 = {
    label = "冰锋 · RR", class = "sport",
    model = "model/1dadc7a6f34b4afdb9afc2ac711a409d/Meshes/1dadc7a6f34b4afdb9afc2ac711a409d.mdl",
    material = "model/1dadc7a6f34b4afdb9afc2ac711a409d/Materials/1dadc7a6f34b4afdb9afc2ac711a409d_00_tripo_material_1fbe3a00-81b8-4760-a173-a1fb1e3deb6e.xml",
    diffuse = "model/1dadc7a6f34b4afdb9afc2ac711a409d/Textures/1dadc7a6f34b4afdb9afc2ac711a409d_00_D.jpg",
    normal = "model/1dadc7a6f34b4afdb9afc2ac711a409d/Textures/1dadc7a6f34b4afdb9afc2ac711a409d_00_N.png",
    rotation = -90, targetLength = 2.15,
    targetSize = Vector3(1.081311, 1.645108, 2.15), measuredSize = Vector3(0.998046875, 0.763671875, 0.501953125),
    resources = {
        "model/1dadc7a6f34b4afdb9afc2ac711a409d/Textures/1dadc7a6f34b4afdb9afc2ac711a409d_00_D.xml",
        "model/1dadc7a6f34b4afdb9afc2ac711a409d/Textures/1dadc7a6f34b4afdb9afc2ac711a409d_00_N.xml",
    },
}
VehicleAssets.Vehicles.sport_3 = {
    label = "银隼 · 750", class = "sport",
    model = "model/01f366c45ca44caf9e89fd047621da2f/Meshes/01f366c45ca44caf9e89fd047621da2f.mdl",
    material = "model/01f366c45ca44caf9e89fd047621da2f/Materials/01f366c45ca44caf9e89fd047621da2f_00_tripo_material_d3ea0087-9eba-4aa8-9c2b-33ffbfa7584c.xml",
    diffuse = "model/01f366c45ca44caf9e89fd047621da2f/Textures/01f366c45ca44caf9e89fd047621da2f_00_D.jpg",
    normal = "model/01f366c45ca44caf9e89fd047621da2f/Textures/01f366c45ca44caf9e89fd047621da2f_00_N.png",
    rotation = -90, targetLength = 2.15,
    targetSize = Vector3(1.081311, 1.611448, 2.15), measuredSize = Vector3(0.998046875, 0.748046875, 0.501953125),
    resources = {
        "model/01f366c45ca44caf9e89fd047621da2f/Textures/01f366c45ca44caf9e89fd047621da2f_00_D.xml",
        "model/01f366c45ca44caf9e89fd047621da2f/Textures/01f366c45ca44caf9e89fd047621da2f_00_N.xml",
    },
}
VehicleAssets.Vehicles.cruiser_2 = {
    label = "赤铜 · Classic", class = "cruiser",
    model = "model/e8de4b206429495c8fe2e13e764da5d2/Meshes/e8de4b206429495c8fe2e13e764da5d2.mdl",
    material = "model/e8de4b206429495c8fe2e13e764da5d2/Materials/e8de4b206429495c8fe2e13e764da5d2_00_tripo_material_22b70a3a-13b7-407d-8c0c-f8d36e01ebd3.xml",
    diffuse = "model/e8de4b206429495c8fe2e13e764da5d2/Textures/e8de4b206429495c8fe2e13e764da5d2_00_D.jpg",
    normal = "model/e8de4b206429495c8fe2e13e764da5d2/Textures/e8de4b206429495c8fe2e13e764da5d2_00_N.png",
    rotation = -90, targetLength = 2.45,
    targetSize = Vector3(1.423973, 1.750000, 2.45), measuredSize = Vector3(0.998046875, 0.712890625, 0.580078125),
    resources = {
        "model/e8de4b206429495c8fe2e13e764da5d2/Textures/e8de4b206429495c8fe2e13e764da5d2_00_D.xml",
        "model/e8de4b206429495c8fe2e13e764da5d2/Textures/e8de4b206429495c8fe2e13e764da5d2_00_N.xml",
    },
}
VehicleAssets.Vehicles.cruiser_3 = {
    label = "暗峰 · Muscle", class = "cruiser",
    model = "model/4e969346c4c841879ddb618a4b6d96b7/Meshes/4e969346c4c841879ddb618a4b6d96b7.mdl",
    material = "model/4e969346c4c841879ddb618a4b6d96b7/Materials/4e969346c4c841879ddb618a4b6d96b7_00_tripo_material_8256a5ae-6591-4405-b73f-2435cd328e47.xml",
    diffuse = "model/4e969346c4c841879ddb618a4b6d96b7/Textures/4e969346c4c841879ddb618a4b6d96b7_00_D.jpg",
    normal = "model/4e969346c4c841879ddb618a4b6d96b7/Textures/4e969346c4c841879ddb618a4b6d96b7_00_N.png",
    rotation = -90, targetLength = 2.45,
    targetSize = Vector3(1.097945, 1.625342, 2.45), measuredSize = Vector3(0.998046875, 0.662109375, 0.447265625),
    resources = {
        "model/4e969346c4c841879ddb618a4b6d96b7/Textures/4e969346c4c841879ddb618a4b6d96b7_00_D.xml",
        "model/4e969346c4c841879ddb618a4b6d96b7/Textures/4e969346c4c841879ddb618a4b6d96b7_00_N.xml",
    },
}
VehicleAssets.Vehicles.rally_3 = {
    label = "沙隼 · Dakar", class = "rally",
    model = "model/fe801312afd04b54bd196ffdfca6f364/Meshes/fe801312afd04b54bd196ffdfca6f364.mdl",
    material = "model/fe801312afd04b54bd196ffdfca6f364/Materials/fe801312afd04b54bd196ffdfca6f364_00_tripo_material_e74289b2-facb-4b9b-ad1a-4f1af343cfd9.xml",
    diffuse = "model/fe801312afd04b54bd196ffdfca6f364/Textures/fe801312afd04b54bd196ffdfca6f364_00_D.jpg",
    normal = "model/fe801312afd04b54bd196ffdfca6f364/Textures/fe801312afd04b54bd196ffdfca6f364_00_N.png",
    rotation = -90, targetLength = 2.22,
    targetSize = Vector3(1.029628, 1.924579, 2.22), measuredSize = Vector3(0.998046875, 0.865234375, 0.462890625),
    resources = {
        "model/fe801312afd04b54bd196ffdfca6f364/Textures/fe801312afd04b54bd196ffdfca6f364_00_D.xml",
        "model/fe801312afd04b54bd196ffdfca6f364/Textures/fe801312afd04b54bd196ffdfca6f364_00_N.xml",
    },
}

-- 材质行为按车型class，不按某三个表引用比较，新增同类变体自动适用。
VehicleAssets.Vehicles.sport.class = "sport"
VehicleAssets.Vehicles.cruiser.class = "cruiser"
VehicleAssets.Vehicles.rally.class = "rally"

-- 街道车流按车型轮换。新增车型必须同时在 Career/VehicleContact 里做胎面标定，
-- 否则城市构建会因缺少标定而失败，所以这里只列已标定的三种。
VehicleAssets.TrafficIds = {"sedan", "suv", "truck"}
-- 混合载具使用独立3D几何模型，车库/实战/AI保持一致。
for _, v in ipairs(require("MixedVehicles").List) do
    VehicleAssets.Vehicles[v.id]={label=v.name,class=v.class,procedural=true,model="",material="",diffuse="",normal="",
        rotation=0,targetLength=v.size[3],targetSize=Vector3(v.size[1],v.size[2],v.size[3]),
        measuredSize=Vector3(v.size[1],v.size[2],v.size[3]),resources={}}
end
VehicleAssets.ResourceTypes = {}

---@param ids string[]
---@return string[]
function VehicleAssets.ResourcesFor(ids)
    local roots, seen = {}, {}
    local function add(path)
        if path == "" then return end
        if not seen[path] then
            seen[path] = true; roots[#roots + 1] = path
            local kind = path:match("^Techniques/") and "Technique"
                or path:match("%.mdl$") and "Model"
                or path:match("/Materials/") and "Material"
                or (path:match("%.jpg$") or path:match("%.png$")) and "Texture2D" or "XMLFile"
            VehicleAssets.ResourceTypes[path] = kind
        end
    end
    add("Techniques/PBR/PBRDiffNormal.xml")
    add("Techniques/PBR/PBRNoTextureAlpha.xml")
    add("Techniques/PBR/PBRNoTexture.xml")
    for _,shape in ipairs({"Box","Sphere","Cylinder"}) do add("Models/"..shape..".mdl") end
    for _, id in ipairs(ids) do
        local c = assert(VehicleAssets.Vehicles[id], "Unknown vehicle: " .. tostring(id))
        add(c.model); add(c.material); add(c.diffuse); add(c.normal)
        -- Textures/*_D.xml、*_N.xml是构建期纹理导入设置，压缩后不会作为
        -- 独立XMLFile进入运行时manifest；校验它们会让新车型永远卡在下载失败。
        -- 真实贴图与材质已在上方逐项登记，导入设置由构建器读取，不交给DWP。
    end
    return roots
end

---@param bikeId? string
---@param trafficIds? string[] 不需要交通车时传{}
---@return string[]
function VehicleAssets.GetResources(bikeId, trafficIds)
    local ids = {bikeId or "sport"}
    for _, id in ipairs(trafficIds or VehicleAssets.TrafficIds) do ids[#ids + 1] = id end
    return VehicleAssets.ResourcesFor(ids)
end

-- 工具使用完整静态导出；一次骑行的Loader优先调用GetResources按需选择。
VehicleAssets.Resources = VehicleAssets.ResourcesFor({
    "sport", "sport_2", "sport_3", "cruiser", "cruiser_2", "cruiser_3",
    "rally", "rally_2", "rally_3", "sedan", "suv", "truck", "police",
})

---@type table<string, Material>
local materials = {}

---@param c VehicleAssetConfig
---@return Material
local function loadMaterial(c)
    if materials[c.material] then return materials[c.material] end
    local source = assert(cache:GetResource("Material", c.material), "Missing vehicle material: " .. c.material)
    local mat = source:Clone()
    -- 显式路径也适用于尚未构建、缺少UUID索引的本地预览。
    local diffuse = assert(cache:GetResource("Texture2D", c.diffuse), c.diffuse)
    local normal = assert(cache:GetResource("Texture2D", c.normal), c.normal)
    local motorcycle = c.class == "sport" or c.class == "rally" or c.class == "cruiser"
    if motorcycle then
        VehicleFinish.ConfigureTexture(diffuse, true)
        VehicleFinish.ConfigureTexture(normal, false)
    end
    mat:SetTexture(TU_DIFFUSE, diffuse)
    mat:SetTexture(TU_NORMAL, normal)
    -- 远处AI使用保守的单次绘制材质；近车通过SetDetail获得独立几何分区。
    -- 不对整个混合图集使用统一金属度或过亮反射。
    mat:SetShaderParameter("Metallic", Variant(motorcycle and 0.0 or 0.24))
    mat:SetShaderParameter("Roughness", Variant(motorcycle and 0.56 or 0.48))
    if motorcycle then mat:SetShaderParameter("MatSpecColor", Variant(Color(0.5, 0.5, 0.5, 16))) end
    materials[c.material] = mat
    return mat
end

---@param parent Node
---@param id string
---@param length? number 最终车长（米）；各轴等比缩放
---@param detailTier? string hero|balanced|distant；AI可直接distant避免预构建近车分组
---@return Node
function VehicleAssets.Add(parent, id, length, detailTier)
    local c = assert(VehicleAssets.Vehicles[id], "Unknown vehicle: " .. tostring(id))
    if c.procedural then return require("MixedVisuals").Build(parent,id) end
    local model = assert(cache:GetResource("Model", c.model), "Missing vehicle model: " .. c.model)
    local rotation = Quaternion(0, c.rotation, 0)
    local bounds = BoundingBox()
    local source = model.boundingBox
    -- 旋转全部八个角点，不假设资源长轴一定是Z。
    for _, x in ipairs({source.min.x, source.max.x}) do
        for _, y in ipairs({source.min.y, source.max.y}) do
            for _, z in ipairs({source.min.z, source.max.z}) do bounds:Merge(rotation * Vector3(x, y, z)) end
        end
    end
    local size = bounds.size
    assert(size.z > 0.0001 and size.y > 0.0001, "Degenerate vehicle bbox: " .. id)
    local scale = (length or c.targetLength) / size.z
    assert(scale > 0, "Vehicle length must be positive")
    local root = parent:CreateChild("Vehicle_" .. id)
    local mesh = root:CreateChild("DetailedBody")
    mesh.rotation = rotation
    mesh:SetScale(scale)
    mesh.position = Vector3(-bounds.center.x, -bounds.min.y, -bounds.center.z) * scale
    local drawable = mesh:CreateComponent("StaticModel")
    drawable.model = model
    drawable.material = loadMaterial(c)
    drawable.castShadows = true
    root:SetVar("VehicleId", Variant(id))
    root:SetVar("VehicleSize", Variant(size * scale))
    VehicleAssets.SetDetail(root, detailTier or "hero")
    print(string.format("[车型] %s bbox %.3f/%.3f/%.3f -> %.2fm, yaw %.0f", id, size.x, size.y, size.z, size.z * scale, c.rotation))
    return root
end

-- 切换档位不逐帧分类、不上传新缓冲、不创建新材质。
-- 相同档位重复调用直接返回，所有近车共享按id缓存的模型。
---@param root Node VehicleAssets.Add返回的根节点，不是Bike/Rider外层节点
---@param tier string hero|balanced|distant
---@return boolean 仅当近车真实分区可用时返回true
function VehicleAssets.SetDetail(root, tier)
    assert(tier == "hero" or tier == "balanced" or tier == "distant", "Invalid vehicle detail tier")
    if root:GetVar("VehicleDetail"):GetString() == tier then
        return root:GetVar("VehiclePartitioned"):GetBool()
    end
    local id = root:GetVar("VehicleId"):GetString()
    local c = VehicleAssets.Vehicles[id]
    if not c then return false end
    local mesh = root:GetChild("DetailedBody")
    if not mesh then return false end
    local drawable = mesh:GetComponent("StaticModel")
    if not drawable then return false end
    local source = assert(cache:GetResource("Model", c.model), c.model)
    local base = loadMaterial(c)
    local motorcycle = c.class == "sport" or c.class == "rally" or c.class == "cruiser"
    local entry = motorcycle and tier ~= "distant" and VehicleFinish.Get(id, c, source, base) or nil
    if entry then
        drawable.model = entry.model
        for slot, material in ipairs(entry.materials) do drawable:SetMaterial(slot - 1, material) end
    else
        drawable.model = source
        drawable.material = base
    end
    -- 较高bias推迟玩家/近景的粗LOD切换；源LOD距离、索引范围和交通车不改。
    drawable.lodBias = motorcycle and (tier == "hero" and 1.6 or tier == "balanced" and 1.0 or 0.75) or 1.0
    root:SetVar("VehicleDetail", Variant(tier))
    root:SetVar("VehiclePartitioned", Variant(entry ~= nil))
    return entry ~= nil
end

return VehicleAssets
