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
-- 五款独立生成整车；原网格四LOD拆件、关节、实际座舱眼位和玩家/AI/车库已验收开放。
local newModels={
    {id="hovercraft",hash="4fcb25f68ece49be8eea75f0dc346718",mat="c570ae21-28e0-4520-a7c5-9dfa790a94b0",label="旱地气垫艇",length=3.1,size=Vector3(.999512,.644043,.887207),orientedSize=Vector3(.760220,.644043,.980876),rotation=-107.7},
    {id="centipede",hash="a70e6cc64480458486a5635205e3a4ab",mat="d2b35ec5-caa7-495c-98a3-0111372e8f57",label="齿轮蜈蚣",length=4.1,size=Vector3(.999512,.482910,.756348),orientedSize=Vector3(.756348,.482910,.999512),rotation=-90},
    {id="buggy",hash="88412bc9434f4f4faa8c418e873ce557",mat="425b3405-0571-40af-a816-a128a33d3172",label="越野蹦蹦",length=2.8,size=Vector3(.999512,.703613,.905762),orientedSize=Vector3(.905762,.703613,.999512),rotation=-90},
    {id="loader",hash="87758016d43e4308a546ea464a9b39fb",mat="4d0c185a-23ed-457d-a776-eeed17282334",label="轮式铲车",length=3.3,size=Vector3(.999512,.647949,.480957),orientedSize=Vector3(.480957,.647949,.999512),rotation=-90},
    {id="cicada",hash="19fe86ecf0b34b2fb7d3dd067fd84160",mat="39dce6b3-01a5-46b0-93c8-1fa338a05762",label="发条木蝉",length=2.8,size=Vector3(.999512,.815918,.957520),orientedSize=Vector3(.957520,.815918,.999512),rotation=-90},
}
---@type string[]
M.NewIds={"hovercraft","centipede","buggy","loader","cicada"}
for _,entry in ipairs(newModels) do
    local base="model/"..entry.hash.."/"
    M.Vehicles[entry.id]={
        model=base.."Meshes/"..entry.hash..".mdl",
        material=base.."Materials/"..entry.hash.."_00_tripo_material_"..entry.mat..".xml",
        diffuse=base.."Textures/"..entry.hash.."_00_D.jpg",
        normal=base.."Textures/"..entry.hash.."_00_N.png",
        rotation=entry.rotation,targetLength=entry.length,
        targetSize=entry.orientedSize*(entry.length/entry.orientedSize.z),
        measuredSize=entry.size,label=entry.label,class="mixed",resources={},articulated=true,delivered=true,
    }
end
function M.IsReady(id)
    local config=M.Vehicles[id]
    return config~=nil and config.delivered~=false
end
-- 正式混合车型与现有独立摩托组成对手池；未交付车型不再悄悄出现拼装替代物。
---@return string[]
function M.RaceIds()
    local ids={"ebike","helicopter","sport","sport_2","sport_3","rally","rally_2","rally_3","cruiser","cruiser_2","cruiser_3"}
    for _,id in ipairs({"tank","beetle","hovercraft","centipede","buggy","loader","cicada"}) do
        if M.IsReady(id) then ids[#ids+1]=id end
    end
    return ids
end
return M
