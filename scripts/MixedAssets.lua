-- 正式资源清单：只有已落盘且有完整D/N贴图的车型开放，不允许几何占位回退。
local M = {}
M.Vehicles = {
    tank = {
        model="model/513d518442be410b82afbc2726c8a43d/Meshes/513d518442be410b82afbc2726c8a43d.mdl",
        material="model/513d518442be410b82afbc2726c8a43d/Materials/513d518442be410b82afbc2726c8a43d_00_tripo_material_d39ddc01-06b1-4fec-8a0c-e14e9907c992.xml",
        diffuse="model/513d518442be410b82afbc2726c8a43d/Textures/513d518442be410b82afbc2726c8a43d_00_D.jpg",
        normal="model/513d518442be410b82afbc2726c8a43d/Textures/513d518442be410b82afbc2726c8a43d_00_N.png",
        rotation=-90, targetLength=3.4, targetSize=Vector3(2.181,1.736,3.4),
        measuredSize=Vector3(.999512,.510254,.641113), label="轻型突击坦克", class="mixed", resources={}, articulated=true, delivered=true,
    },
    beetle = {
        model="model/919dbe654dcc4020ba6bf82ee24f7d1c/Meshes/919dbe654dcc4020ba6bf82ee24f7d1c.mdl",
        material="model/919dbe654dcc4020ba6bf82ee24f7d1c/Materials/919dbe654dcc4020ba6bf82ee24f7d1c_00_tripo_material_e8185d8b-7e34-478c-a253-6e935f784562.xml",
        diffuse="model/919dbe654dcc4020ba6bf82ee24f7d1c/Textures/919dbe654dcc4020ba6bf82ee24f7d1c_00_D.jpg",
        normal="model/919dbe654dcc4020ba6bf82ee24f7d1c/Textures/919dbe654dcc4020ba6bf82ee24f7d1c_00_N.png",
        rotation=-90, targetLength=3.2, targetSize=Vector3(3.2,2.028,3.2),
        measuredSize=Vector3(.999512,.633301,.999512), label="蒸汽锹甲", class="mixed", resources={}, articulated=true, delivered=true,
    },
    helicopter = {
        model="model/20a0a237-889c-51ee-8273-c8423e349994/Meshes/59dbd63b4cea40838063939717d5fbf8.mdl",
        material="model/20a0a237-889c-51ee-8273-c8423e349994/Materials/59dbd63b4cea40838063939717d5fbf8_00_tripo_material_89461654-690d-4548-89ee-2619023bb54c.xml",
        diffuse="model/20a0a237-889c-51ee-8273-c8423e349994/Textures/59dbd63b4cea40838063939717d5fbf8_00_D.jpg",
        normal="model/20a0a237-889c-51ee-8273-c8423e349994/Textures/59dbd63b4cea40838063939717d5fbf8_00_N.jpg",
        rotation=-90, targetLength=3.5, targetSize=Vector3(3.226,2.062,3.5),
        measuredSize=Vector3(.998046875,.587890625,.919921875),
        label="武装直升机", class="mixed", resources={}, articulated=true,
    },
    ebike = {
        model="model/873a3764f21f49e4b717387160d13d19/Meshes/873a3764f21f49e4b717387160d13d19.mdl",
        material="model/873a3764f21f49e4b717387160d13d19/Materials/873a3764f21f49e4b717387160d13d19_00_tripo_material_a843f27f-7dc0-48b9-b818-99d319a20274.xml",
        diffuse="model/873a3764f21f49e4b717387160d13d19/Textures/873a3764f21f49e4b717387160d13d19_00_D.jpg",
        normal="model/873a3764f21f49e4b717387160d13d19/Textures/873a3764f21f49e4b717387160d13d19_00_N.png",
        rotation=226.1, targetLength=2.1, targetSize=Vector3(1.060,1.601,2.1),
        measuredSize=Vector3(.966796875,.998046875,.951171875), label="疾风电动车", class="mixed", resources={}, articulated=true,
    },
}
function M.IsReady(id)
    local config=M.Vehicles[id]
    return config~=nil and config.delivered~=false
end
-- 正式混合车型与现有独立摩托组成对手池；未交付车型不再悄悄出现拼装替代物。
---@return string[]
function M.RaceIds()
    local ids={"ebike","helicopter","sport","sport_2","sport_3","rally","rally_2","rally_3","cruiser","cruiser_2","cruiser_3"}
    for _,id in ipairs({"tank","beetle"}) do
        if M.IsReady(id) then ids[#ids+1]=id end
    end
    return ids
end
return M
