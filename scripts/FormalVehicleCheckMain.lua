-- 基于3D场景脚手架的正式载具验收入口，不读取或写入玩家存档。
local Assets = require("MixedAssets")
local Visual = require("MixedVisuals")
---@type Scene?
local scene_ = nil

function Start()
    local id, pose, active, distance = "helicopter", 0, false, 0
    for _,arg in ipairs(GetArguments()) do
        if arg=="-formal-skill" then active=true end
        if arg=="-formal-no-instancing" then renderer.dynamicInstancing=false end
        id = arg:match("^%-formal%-vehicle=(.+)$") or id
        pose = tonumber(arg:match("^%-pose%-time=(.+)$")) or pose
        distance=tonumber(arg:match("^%-wheel%-distance=(.+)$")) or distance
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
    -- 单方向主光 + 局部补光；避免附加方向光pass在当前GLES运行时链接失败。
    local fill=fillNode:CreateComponent("Light")
    fill.lightType,fill.brightness,fill.color=LIGHT_POINT,18,Color(.85,.92,1)
    fill.range=18
    fillNode.position=Vector3(-3,4,4)
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
    for lod=0,source:GetNumGeometryLodLevels(0)-1 do
        local total=0
        local original=source:GetGeometry(0,lod)
        for _,draw in ipairs(vehicle:GetComponents("StaticModel",true)) do
            local geometry=assert(draw:GetModel():GetGeometry(0,lod),"每个部件必须保留全部LOD")
            assert(geometry:GetVertexBuffer(0)==original:GetVertexBuffer(0),"每LOD保留正式源顶点流")
            total=total+geometry.indexCount
        end
        assert(total==original.indexCount,"各LOD拆件不得增加或丢失原三角面")
    end
    if id=="ebike" then
        local front=assert(vehicle:GetChild("FrontWheel",true))
        local rear=assert(vehicle:GetChild("RearWheel",true))
        local body=assert(vehicle:GetChild("Body",true))
        local initial=body.transform
        Visual.Animate(vehicle,id,0,{distance=0})
        local first=front.rotation
        Visual.Animate(vehicle,id,0,{distance=.207})
        assert(front.rotation~=first and rear.rotation~=first,"前后车轮必须独立转动")
        assert(body.transform==initial,"车轮转动不得带动车架挡泥板")
    end
    if id=="helicopter" then
        local rotor=assert(vehicle:GetChild("Rotor",true))
        local body=assert(vehicle:GetChild("Body",true))
        local initial=body.rotation
        Visual.Animate(vehicle,id,0,{oddActive=0})
        local first=rotor.rotation
        Visual.Animate(vehicle,id,.037,{oddActive=0})
        assert(rotor.rotation~=first,"主旋翼必须独立旋转")
        assert(body.rotation==initial,"禁止转动整架机身冒充旋翼动画")
        local pods=assert(vehicle:GetChild("WeaponPods",true))
        local bodyPosition=body.position
        Visual.Animate(vehicle,id,.049,{oddActive=0})
        local resting=pods.position
        Visual.Animate(vehicle,id,.049,{oddActive=1})
        assert((pods.position-resting):Length()>.02,"技能必须驱动独立发射筒后坐")
        assert(body.position==bodyPosition and body.rotation==initial,"技能后坐不能移动机身")
        Visual.Animate(vehicle,id,.049,{oddActive=0})
        assert(pods.position==resting,"技能结束后发射筒必须复位")
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
    Visual.Animate(vehicle,id,pose,{oddActive=active and 1 or 0,distance=distance})
    for _,arg in ipairs(GetArguments()) do
        local rotorPose=tonumber(arg:match("^%-rotor%-angle=(.+)$"))
        local rotor=vehicle:GetChild("Rotor",true)
        if rotorPose and rotor then rotor.rotation=Quaternion(0,rotorPose,0) end
    end
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
    for _,arg in ipairs(GetArguments()) do
        if arg=="-formal-side" then
            cameraNode.position=Vector3(4.5,1.1,0)
            cameraNode:LookAt(Vector3(0,.85,0))
        end
    end
    local camera=cameraNode:CreateComponent("Camera")
    camera.nearClip,camera.farClip,camera.fov=.05,60,36
    renderer.hdrRendering=true
    local viewport=Viewport:new(scene_,camera)
    local renderPath=viewport:GetRenderPath():Clone()
    assert(renderPath:Load(assert(cache:GetResource("XMLFile","RenderPaths/Forward.xml"))))
    viewport:SetRenderPath(renderPath)
    renderer:SetViewport(0,viewport)
    local animated=id=="ebike" or id=="helicopter"
    print(string.format("[正式模型验收] PASS %s / %d原始三角面 / D+N / %s / pose=%.4f",id,count//3,
        animated and "独立部件动画已验证" or "静态模型检查，动画尚未验收",pose))
end

function Stop()
    if scene_ then scene_:Dispose(); scene_=nil end
end
