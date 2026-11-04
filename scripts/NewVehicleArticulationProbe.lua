-- 独立原网格测量/验收入口；基于 scaffold-3d-scene 的 Scene/LightGroup/Viewport。
-- 不 require 游戏入口、不读写玩家存档。-new-dump 导出全部LOD供连通件测量后退出。
local hashes = {
    hovercraft="4fcb25f68ece49be8eea75f0dc346718",
    centipede="a70e6cc64480458486a5635205e3a4ab",
    buggy="88412bc9434f4f4faa8c418e873ce557",
    loader="87758016d43e4308a546ea464a9b39fb",
    cicada="19fe86ecf0b34b2fb7d3dd067fd84160",
}
local materialNames = {
    hovercraft="c570ae21-28e0-4520-a7c5-9dfa790a94b0",
    centipede="d2b35ec5-caa7-495c-98a3-0111372e8f57",
    buggy="425b3405-0571-40af-a816-a128a33d3172",
    loader="4d0c185a-23ed-457d-a776-eeed17282334",
    cicada="39dce6b3-01a5-46b0-93c8-1fa338a05762",
}
---@type Scene?
local scene_ = nil

---@param source Model
---@param id string
local function dump(source,id)
    local json=require("cjson")
    local levels={}
    for lod=0,source:GetNumGeometryLodLevels(0)-1 do
        local geo=assert(source:GetGeometry(0,lod))
        local vb,ib=geo:GetVertexBuffer(0),geo:GetIndexBuffer()
        local data,index=vb:GetData(),ib:GetData()
        local vertices,triangles={},{}
        for n=0,vb.vertexCount-1 do
            data:Seek(n*vb.vertexSize+vb:GetElementOffset(SEM_POSITION))
            local p=data:ReadVector3()
            data:Seek(n*vb.vertexSize+vb:GetElementOffset(SEM_NORMAL))
            local normal=data:ReadVector3()
            data:Seek(n*vb.vertexSize+vb:GetElementOffset(SEM_TEXCOORD))
            local uv=data:ReadVector2()
            vertices[#vertices+1]={p.x,p.y,p.z,normal.x,normal.y,normal.z,uv.x,uv.y}
        end
        index:Seek(geo.indexStart*ib.indexSize)
        for _=1,geo.indexCount//3 do
            local a=ib.indexSize==2 and index:ReadUShort() or index:ReadUInt()
            local b=ib.indexSize==2 and index:ReadUShort() or index:ReadUInt()
            local c=ib.indexSize==2 and index:ReadUShort() or index:ReadUInt()
            triangles[#triangles+1]={a,b,c}
        end
        levels[#levels+1]={vertices=vertices,triangles=triangles,lodDistance=geo.lodDistance}
    end
    local path="/workspace/.tmp/new_vehicle_"..id..".json"
    local file=File(path,FILE_WRITE)
    assert(file.open,path)
    file:WriteString(json.encode(levels));file:Dispose()
    print("[NewVehicleMeasure] "..id.." -> "..path)
end

local function buildCheck()
    assert(cache:AddResourceDir("/workspace/assets"))
    assert(cache:AddResourceDir("/workspace/scripts"))
    local Articulation=require("NewVehicleArticulation")
    local ids={"hovercraft","centipede","buggy","loader","cicada"}
    local scene=Scene()
    scene:CreateComponent("Octree")
    for _,id in ipairs(ids) do
        local cfg=Articulation.GetConfig(id)
        local base="model/"..cfg.modelHash.."/"
        local source=assert(cache:GetResource("Model",base.."Meshes/"..cfg.modelHash..".mdl"))
        local material=assert(cache:GetResource("Material",base.."Materials/"..cfg.modelHash.."_00_tripo_material_"..materialNames[id]..".xml"))
        local root=scene:CreateChild("Check_"..id)
        local ok,err=pcall(function() Articulation.Build(root,id,source,material) end)
        assert(ok, id.." Build failed: "..tostring(err))
        Articulation.Animate(root,id,0.12,{distance=.25,steer=.4,oddPhase="scoop_lift",oddAge=.3,oddSpring=0})
        Articulation.Animate(root,id,0.12,{distance=.25,steer=.4,oddPhase="wound_release",oddAge=.3,oddSpring=0})
        Articulation.Animate(root,id,0.12,{distance=.25,steer=.4,paused=true})
        print("[NewVehicleArticulation] PASS "..id.." Build/LOD/VB/animation/pause")
    end
    scene:Dispose()
end

local function run()
    assert(cache:AddResourceDir("/workspace/assets"))
    assert(cache:AddResourceDir("/workspace/scripts"))
    local id,view="hovercraft","iso"
    local dumping=false
    local buildChecking=false
    for _,arg in ipairs(GetArguments()) do
        id=arg:match("^%-new%-vehicle=(.+)$") or id
        view=arg:match("^%-new%-view=(.+)$") or view
        if arg=="-new-dump" then dumping=true end
        if arg=="-new-build-check" then buildChecking=true end
    end
    if buildChecking then
        buildCheck()
        return
    end
    if dumping then
        for vehicle,hash in pairs(hashes) do
            dump(assert(cache:GetResource("Model","model/"..hash.."/Meshes/"..hash..".mdl")),vehicle)
        end
        return
    end
    local hash=assert(hashes[id],id)
    local base="model/"..hash.."/"
    local source=assert(cache:GetResource("Model",base.."Meshes/"..hash..".mdl"))
    scene_=Scene()
    scene_:CreateComponent("Octree")
    local lights=scene_:CreateChild("LightGroup")
    lights:LoadXML(assert(cache:GetResource("XMLFile","LightGroup/Daytime.xml")):GetRoot())
    local zone=lights:GetComponent("Zone",true)
    if zone then zone.depthFogEnable=false;zone.heightFogEnable=false end
    local root=scene_:CreateChild("OriginalSource")
    local draw=root:CreateComponent("StaticModel")
    draw:SetModel(source)
    local mat=assert(cache:GetResource("Material",base.."Materials/"..hash.."_00_tripo_material_"..materialNames[id]..".xml")):Clone()
    mat:SetTexture(TU_DIFFUSE,assert(cache:GetResource("Texture2D",base.."Textures/"..hash.."_00_D.jpg")))
    mat:SetTexture(TU_NORMAL,assert(cache:GetResource("Texture2D",base.."Textures/"..hash.."_00_N.png")))
    draw:SetMaterial(mat)
    draw.lodBias=10
    local cameraNode=scene_:CreateChild("Camera")
    local views={iso=Vector3(1.4,1.2,1.6),side=Vector3(0,.15,2),top=Vector3(0,2,.001),front=Vector3(2,.1,0)}
    cameraNode.position=views[view] or views.iso
    cameraNode:LookAt(Vector3.ZERO)
    local camera=cameraNode:CreateComponent("Camera")
    camera.nearClip,camera.farClip,camera.fov=.01,20,36
    local viewport=Viewport:new(scene_,camera)
    local renderPath=viewport:GetRenderPath():Clone()
    assert(renderPath:Load(assert(cache:GetResource("XMLFile","RenderPaths/Forward.xml"))))
    viewport:SetRenderPath(renderPath)
    renderer:SetViewport(0,viewport)
    renderer.hdrRendering=true
    print("[NewVehicleMeasure] original "..id.." view="..view)
end

function Start()
    local dumping=false
    for _,arg in ipairs(GetArguments()) do
        if arg=="-new-dump" or arg=="-new-build-check" then dumping=true end
    end
    local ok,err=pcall(run)
    if not ok then log:Write(LOG_ERROR,"[NewVehicleMeasure] "..tostring(err)) end
    if dumping or not ok then engine:Exit() end
end

function Stop()
    if scene_ then scene_:Dispose();scene_=nil end
end
