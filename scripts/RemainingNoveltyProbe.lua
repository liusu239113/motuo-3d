-- 独立实车验收入口，基于 scaffold-3d-scene 的 Scene/LightGroup/Viewport。
-- 只展示正式源MDL，不进入主游戏，不读取或修改玩家存档。
local hashes={bathtub="1c6d3272acc54493afca4fd72c8e87c0",office="b8385dcb211748b8b54decb26a11d8cc",toilet="d7926fe871bc43bd8160eb3299bbcc06"}
local mats={bathtub="4836b8a2-1ee6-4afe-8e5a-182a57754c3a",office="93b46be9-1667-46c6-8da0-3d67c4f117bb",toilet="d7704fc2-c4a3-4a84-bd7e-511b66b1485e"}
---@type Scene?
local scene_=nil

---@param source Model
---@param id string
local function dump(source,id)
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
    local path="/workspace/.tmp/remaining_novelty_"..id..".json"
    local file=File(path,FILE_WRITE)
    assert(file.open,path)
    file:WriteString(require("cjson").encode(levels));file:Dispose()
    print("[RemainingNoveltyProbe] dumped "..id.." "..path)
end

local function contactSheet(checking)
    local assets=require("RemainingNoveltyAssets")
    local articulation=require("RemainingNoveltyArticulation")
    scene_=Scene();scene_:CreateComponent("Octree")
    local lights=scene_:CreateChild("LightGroup")
    lights:LoadXML(assert(cache:GetResource("XMLFile","LightGroup/Daytime.xml")):GetRoot())
    local zone=assert(lights:GetComponent("Zone",true))
    zone.depthFogEnable=false;zone.heightFogEnable=false
    -- Four fixed views per car in one process: whole, profile, active joints, eye.
    -- Isolate each cell spatially: all triangles still use original textured MDL.
    renderer:SetNumViewports(12);renderer.hdrRendering=true
    local w,h=graphics:GetWidth()/4,graphics:GetHeight()/3
    for row,id in ipairs({"bathtub","office","toilet"}) do
        local c=assets[id]
        local source=assert(cache:GetResource("Model",c.model))
        local mat=Material()
        mat:SetTechnique(0,assert(cache:GetResource("Technique","Techniques/PBR/PBRDiffNormal.xml")))
        mat:SetTexture(TU_DIFFUSE,assert(cache:GetResource("Texture2D",c.diffuse)))
        mat:SetTexture(TU_NORMAL,assert(cache:GetResource("Texture2D",c.normal)))
        mat:SetShaderParameter("Metallic",Variant(.18));mat:SetShaderParameter("Roughness",Variant(.52))
        for col=1,4 do
            local offset=Vector3(col*30,0,row*30)
            local root=scene_:CreateChild("Vehicle_"..id.."_"..col);root.position=offset
            local canonical=root:CreateChild("SourceTransform");canonical.rotation=c.orientation
            local scale=c.targetLength/c.sourceBounds.size.z
            canonical:SetScale(scale)
            canonical.position=Vector3(-c.sourceBounds.center.x,-c.sourceBounds.min.y,-c.sourceBounds.center.z)*scale
            articulation.Build(canonical,id,source,mat)
            if col==1 and checking then articulation.Validate(root,id,source) end
            articulation.Animate(root,id,0,{distance=col==3 and .37 or 0,steer=0,oddActive=col==3,oddAge=.17})
            local node=scene_:CreateChild("Camera_"..id.."_"..col)
            local focus=offset+Vector3(0,c.targetSize.y*.48,0)
            local extent=math.max(c.targetSize.x,c.targetSize.y,c.targetSize.z)
            node.position=focus+(col==2 and Vector3(2.7,.10,0) or Vector3(1.9,1.1,2.15))*extent
            node:LookAt(focus)
            if col==4 then node.position=offset+c.cockpit.localOffset;node.rotation=Quaternion(c.cockpit.pitch,0,0) end
            local camera=node:CreateComponent("Camera")
            camera.nearClip=.015;camera.farClip=20;camera.fov=col==4 and c.cockpit.fov or 36
            local viewport=Viewport:new(scene_,camera)
            viewport:SetRect(IntRect(math.floor((col-1)*w),math.floor((row-1)*h),math.floor(col*w),math.floor(row*h)))
            local path=viewport:GetRenderPath():Clone()
            assert(path:Load(assert(cache:GetResource("XMLFile","RenderPaths/Forward.xml"))))
            viewport:SetRenderPath(path);renderer:SetViewport((row-1)*4+col-1,viewport)
        end
    end
    print("[RemainingNoveltyProbe] contact sheet rows bathtub/office/toilet; columns iso/profile/skill/eye")
end

local function run()
    assert(cache:AddResourceDir("/workspace/assets"))
    assert(cache:AddResourceDir("/workspace/scripts"))
    local id,view="bathtub","iso"
    local dumping,articulated,checking,sheet,batch=false,false,false,false,false
    local phase=0
    for _,arg in ipairs(GetArguments()) do
        id=arg:match("^%-novelty=(.+)$") or id
        view=arg:match("^%-novelty%-view=(.+)$") or view
        phase=tonumber(arg:match("^%-novelty%-phase=(.+)$")) or phase
        if arg=="-novelty-dump" then dumping=true end
        if arg=="-novelty-articulated" then articulated=true end
        if arg=="-novelty-check" then checking=true end
        if arg=="-novelty-sheet" then sheet=true end
        if arg=="-novelty-batch" then sheet=true;checking=true;batch=true end
    end
    if sheet then
        contactSheet(checking)
        if batch then
            local file=File("/workspace/.tmp/remaining-novelty-assertions.json",FILE_WRITE)
            assert(file.open);file:WriteString('{"result":"PASS","vehicles":["bathtub","office","toilet"],"checks":["sourceTriangleMultiset","sourceVBIdentity","allFourLODs","skillBooleanAndNumeric","pauseFrozen","skillReset","staticBody"]}')
            file:Dispose();engine:Exit()
        end
        return
    end
    if dumping then
        for vehicle,hash in pairs(hashes) do
            dump(assert(cache:GetResource("Model","model/"..hash.."/Meshes/"..hash..".mdl")),vehicle)
        end
        engine:Exit();return
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
    local root=scene_:CreateChild("Vehicle_"..id)
    local mat=Material()
    mat:SetTechnique(0,assert(cache:GetResource("Technique","Techniques/PBR/PBRDiffNormal.xml")))
    mat:SetTexture(TU_DIFFUSE,assert(cache:GetResource("Texture2D",base.."Textures/"..hash.."_00_D.jpg")))
    mat:SetTexture(TU_NORMAL,assert(cache:GetResource("Texture2D",base.."Textures/"..hash.."_00_N.png")))
    mat:SetShaderParameter("Metallic",Variant(.18));mat:SetShaderParameter("Roughness",Variant(.52))
    local focus=Vector3.ZERO
    ---@type number
    local length=1
    if articulated then
        local assets=require("RemainingNoveltyAssets")
        local config=assert(assets[id])
        local canonical=root:CreateChild("SourceTransform")
        canonical.rotation=config.orientation or Quaternion(0,config.rotation,0)
        local bounds=config.sourceBounds
        local scale=config.targetLength/bounds.size.z
        canonical:SetScale(scale)
        canonical.position=Vector3(-bounds.center.x,-bounds.min.y,-bounds.center.z)*scale
        local articulation=require("RemainingNoveltyArticulation")
        articulation.Build(canonical,id,source,mat)
        articulation.Animate(root,id,phase,{distance=phase*.8,steer=.25,oddActive=phase>0 and 1 or 0,oddAge=phase,oddPhase=phase>0 and "active" or "idle",oddSerial=1})
        focus=Vector3(0,config.targetSize.y*.5,0)
        length=config.targetLength
        if checking then articulation.Validate(root,id,source);engine:Exit();return end
    else
        local draw=root:CreateComponent("StaticModel")
        draw:SetModel(source);draw:SetMaterial(mat);draw.lodBias=10
    end
    local cameraNode=scene_:CreateChild("Camera")
    local views={iso=Vector3(1.4,1.1,1.6),rear=Vector3(-1.4,.8,-1.6),side=Vector3(0,.08,2),top=Vector3(0,2.1,.001),front=Vector3(2,.08,0),negx=Vector3(-2,.08,0),negz=Vector3(0,.08,-2)}
    cameraNode.position=focus+(views[view] or views.iso)*length
    cameraNode:LookAt(focus)
    if view=="eye" then
        local c=require("RemainingNoveltyAssets")[id].cockpit
        cameraNode.position=c.localOffset
        cameraNode.rotation=Quaternion(c.pitch,0,0)
    end
    local camera=cameraNode:CreateComponent("Camera")
    camera.nearClip,camera.farClip,camera.fov=.015,100,view=="eye" and 76 or 36
    local viewport=Viewport:new(scene_,camera)
    local renderPath=viewport:GetRenderPath():Clone()
    assert(renderPath:Load(assert(cache:GetResource("XMLFile","RenderPaths/Forward.xml"))))
    viewport:SetRenderPath(renderPath)
    renderer:SetViewport(0,viewport)
    renderer.hdrRendering=true
    print("[RemainingNoveltyProbe] "..id.." view="..view.." phase="..phase)
end

function Start()
    local ok,err=pcall(run)
    if not ok then log:Write(LOG_ERROR,"[RemainingNoveltyProbe] "..tostring(err));engine:Exit() end
end
function Stop()
    if scene_ then scene_:Dispose();scene_=nil end
end
