-- 基于3D场景脚手架的正式载具验收入口，不读取或写入玩家存档。
local Assets = require("MixedAssets")
local Visual = require("MixedVisuals")
---@type Scene?
local scene_ = nil

function Start()
    local id, pose, active = "helicopter", 0, false
    for _,arg in ipairs(GetArguments()) do
        if arg=="-formal-skill" then active=true end
        if arg=="-formal-no-instancing" then renderer.dynamicInstancing=false end
        id = arg:match("^%-formal%-vehicle=(.+)$") or id
        pose = tonumber(arg:match("^%-pose%-time=(.+)$")) or pose
    end
    scene_ = Scene()
    scene_:CreateComponent("Octree")
    local lightGroup = scene_:CreateChild("LightGroup")
    lightGroup:LoadXML(assert(cache:GetResource("XMLFile","LightGroup/Daytime.xml")):GetRoot())
    local zone = lightGroup:GetComponent("Zone",true)
    if zone then
        zone.depthFogEnable, zone.heightFogEnable = false, false
        zone.envTextureDiffIntensity, zone.envTextureSpecIntensity = .7, .65
    end
    local light = lightGroup:GetComponent("Light",true)
    if light then light.brightness=2.2; light.castShadows=false end
    local fillNode=scene_:CreateChild("Softbox")
    fillNode.direction=Vector3(-.6,-.3,.5)
    local fill=fillNode:CreateComponent("Light")
    fill.lightType,fill.brightness,fill.color=LIGHT_DIRECTIONAL,1.2,Color(.85,.92,1)
    local vehicle = Visual.Build(scene_,id)
    local config = assert(Assets.Vehicles[id])
    local source = assert(cache:GetResource("Model",config.model))
    local sourceVB=source:GetGeometry(0,0):GetVertexBuffer(0)
    local count = 0
    for _,draw in ipairs(vehicle:GetComponents("StaticModel",true)) do
        local mat=assert(draw:GetMaterial(),"正式模型材质未绑定")
        assert(mat:GetTexture(TU_DIFFUSE) and mat:GetTexture(TU_NORMAL),"正式模型不能缺D/N贴图")
        local geo=draw:GetModel():GetGeometry(0,0)
        count=count+geo.indexCount
        assert(geo:GetVertexBuffer(0)==sourceVB,"拆件必须直接保留正式源顶点流和UV/法线/切线")
    end
    assert(count==source:GetGeometry(0,0).indexCount,"正式模型必须保留全部原始三角面，不增加替代面")
    if id=="helicopter" then
        local rotor=assert(vehicle:GetChild("Rotor",true))
        local body=assert(vehicle:GetChild("Body",true))
        local initial=body.rotation
        Visual.Animate(vehicle,id,0,{oddActive=0})
        local first=rotor.rotation
        Visual.Animate(vehicle,id,.037,{oddActive=0})
        assert(rotor.rotation~=first,"主旋翼必须独立旋转")
        assert(body.rotation==initial,"禁止转动整架机身冒充旋翼动画")
    end
    local originalOnly=false
    for _,arg in ipairs(GetArguments()) do if arg=="-formal-original" then originalOnly=true end end
    if originalOnly then
        local config=assert(Assets.Vehicles[id])
        local source=assert(cache:GetResource("Model",config.model))
        local root=scene_:CreateChild("OriginalCompare")
        local draw=root:CreateComponent("StaticModel")
        draw:SetModel(source)
        local mat=assert(cache:GetResource("Material",config.material)):Clone()
        local diffuse=cache:GetResource("Texture2D",config.diffuse)
        local normal=cache:GetResource("Texture2D",config.normal)
        mat:SetTexture(TU_DIFFUSE,diffuse);mat:SetTexture(TU_NORMAL,normal)
        mat:SetShaderParameter("Metallic",Variant(.18));mat:SetShaderParameter("Roughness",Variant(.52))
        draw:SetMaterial(mat)
        root.rotation=Quaternion(0,config.rotation,0)
        root:SetScale(config.targetLength/source.boundingBox.size.x)
        root.position=Vector3(0,1,0)
        vehicle.enabled=false
    end
    Visual.Animate(vehicle,id,pose,{oddActive=active and 1 or 0})
    for _,draw in ipairs(vehicle:GetComponents("StaticModel",true)) do
        local mat=draw:GetMaterial()
        for _,pass in ipairs(mat:GetTechnique(0):GetPasses()) do
            print(string.format("[正式材质pass] %s VS=%s [%s] PS=%s [%s]",pass.name,
                pass.vertexShader,pass.vertexShaderDefines,pass.pixelShader,pass.pixelShaderDefines))
        end
        break
    end
    for _,arg in ipairs(GetArguments()) do
        if arg=="-formal-no-model" then vehicle.enabled=false end
        if arg=="-formal-one-light" then fill.enabled=false end
    end
    local cameraNode=scene_:CreateChild("Camera")
    cameraNode.position=Vector3(5.0,3.8,5.6)
    cameraNode:LookAt(Vector3(0,1,0))
    local camera=cameraNode:CreateComponent("Camera")
    camera.nearClip,camera.farClip,camera.fov=.05,60,36
    renderer.hdrRendering=true
    local viewport=Viewport:new(scene_,camera)
    local renderPath=viewport:GetRenderPath():Clone()
    assert(renderPath:Load(assert(cache:GetResource("XMLFile","RenderPaths/Forward.xml"))))
    viewport:SetRenderPath(renderPath)
    renderer:SetViewport(0,viewport)
    print(string.format("[正式模型验收] PASS %s / %d原始三角面 / D+N / 独立部件动画 / pose=%.4f",id,count//3,pose))
end

function Stop()
    if scene_ then scene_:Dispose(); scene_=nil end
end
