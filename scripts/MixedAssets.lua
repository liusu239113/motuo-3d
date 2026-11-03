-- 正式资源清单：只有已落盘且有完整D/N贴图的车型开放，不允许几何占位回退。
local M = {}
M.Vehicles = {
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
        rotation=226.1, targetLength=2.1, targetSize=Vector3(.9,1.7,2.1),
        measuredSize=Vector3(1,1,1), label="疾风电动车", class="mixed", resources={}, articulated=true,
    },
}
function M.IsReady(id) return M.Vehicles[id] ~= nil end
-- 正式混合车型与现有独立摩托组成对手池；未交付车型不再悄悄出现拼装替代物。
---@return string[]
function M.RaceIds()
    return {"ebike","helicopter","sport","sport_2","sport_3","rally","rally_2","rally_3","cruiser","cruiser_2","cruiser_3"}
end
return M
