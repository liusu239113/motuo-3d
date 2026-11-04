-- scaffold-3d-scene 独立源网格验收；不加载主游戏、不写存档。
-- 一进程12格：每行水母/喷射艇/青蛙；列=静止前侧/静止后侧/技能关节/真实眼位道路。
local V=Vector3
---@type Scene[]
local scenes={}
local Assets=require("RemainingOrganicAssets")
local Art=require("RemainingOrganicArticulation")
local function sourceBounds(source,rotation)
    local bounds=BoundingBox()
    local geo=source:GetGeometry(0,0)
    local vb,ib=geo:GetVertexBuffer(0),geo:GetIndexBuffer()
    local v,i=vb:GetData(),ib:GetData()
    i:Seek(geo.indexStart*ib.indexSize)
    for _=1,geo.indexCount do
        local index=ib.indexSize==2 and i:ReadUShort() or i:ReadUInt()
        v:Seek(index*vb.vertexSize+vb:GetElementOffset(SEM_POSITION))
        bounds:Merge(rotation*v:ReadVector3())
    end
    return bounds
end
local function triangleCounts(geo)
    local ib=geo:GetIndexBuffer();local data=ib:GetData();data:Seek(geo.indexStart*ib.indexSize)
    local result={}
    for _=1,geo.indexCount//3 do
        local a=ib.indexSize==2 and data:ReadUShort() or data:ReadUInt()
        local b=ib.indexSize==2 and data:ReadUShort() or data:ReadUInt()
        local c=ib.indexSize==2 and data:ReadUShort() or data:ReadUInt()
        local key=a..","..b..","..c
        result[key]=(result[key] or 0)+1
    end
    return result
end
local function validate(root,id,source)
    local draws=root:GetComponents("StaticModel",true)
    for lod=0,source:GetNumGeometryLodLevels(0)-1 do
        local original=source:GetGeometry(0,lod)
        local remaining=triangleCounts(original)
        local count=0
        for _,draw in ipairs(draws) do
            local geo=assert(draw.model:GetGeometry(0,lod),"missingLOD")
            assert(geo:GetVertexBuffer(0)==original:GetVertexBuffer(0),"nonoriginalVB")
            assert(geo.lodDistance==original.lodDistance,"changedLODdistance")
            for key,n in pairs(triangleCounts(geo)) do
                assert(remaining[key] and remaining[key]>=n,"newOrDuplicateTriangle")
                remaining[key]=remaining[key]-n
            end
            count=count+geo.indexCount
        end
        assert(count==original.indexCount,"lostFaces")
        for _,n in pairs(remaining) do assert(n==0,"lostOriginalTriangle") end
    end
    local body=root:GetChild("Body",true);assert(body)
    local bodyRotation=body.rotation
    Art.Animate(root,id,.37,{distance=.31,steer=.5,oddActive=true,oddAge=.22})
    ---@type table<string,{p:Vector3,q:Quaternion}>
    local frozen={}
    local moving=0
    for _,name in ipairs(Art.GetConfig(id).joints) do
        local j=assert(root:GetChild(name,true));frozen[name]={p=j.position,q=j.rotation}
        local rest=j:GetVar("RestPosition"):GetVector3()
        local position=j.position
        local displacement=V(position.x-rest.x,position.y-rest.y,position.z-rest.z)
        if not j.rotation:Equals(Quaternion.IDENTITY) or displacement:Length()>.00001 then moving=moving+1 end
    end
    assert(moving>0,"noIndependentJointMovement")
    Art.Animate(root,id,10,{distance=12,steer=-1,oddActive=true,oddAge=9,paused=true})
    for _,name in ipairs(Art.GetConfig(id).joints) do
        local j=root:GetChild(name,true)
        local frozenPosition=frozen[name].p
        assert((j.position-frozenPosition):Length()<.000001 and j.rotation:Equals(frozen[name].q),"pauseDidNotFreeze")
    end
    Art.Animate(root,id,30,{distance=0,steer=0,oddActive=0,oddAge=20})
    for _,name in ipairs(Art.GetConfig(id).joints) do
        local j=root:GetChild(name,true)
        local rest=j:GetVar("RestPosition"):GetVector3()
        local position=j.position
        local displacement=V(position.x-rest.x,position.y-rest.y,position.z-rest.z)
        assert(displacement:Length()<.000001 and j.rotation:Equals(Quaternion.IDENTITY),"skillDidNotReset")
    end
    assert(body.rotation:Equals(bodyRotation),"BodyIsNotJoint")
    print("[OrganicCheck] PASS "..id.." all4LOD exactTriangleMultiset originalVB independentJoints pauseFreeze skillReset BodyStatic")
end
local function road(scene)
    local mat=Material();mat:SetTechnique(0,cache:GetResource("Technique","Techniques/PBR/PBRNoTexture.xml"))
    mat:SetShaderParameter("MatDiffColor",Variant(Color(.18,.20,.22)));mat:SetShaderParameter("Roughness",Variant(.9))
    local plane=scene:CreateChild("Road");plane.position=V(0,-.055,15);plane.scale=V(9,.1,80)
    local draw=plane:CreateComponent("StaticModel");draw.model=cache:GetResource("Model","Models/Box.mdl");draw.material=mat
    local stripe=mat:Clone();stripe:SetShaderParameter("MatDiffColor",Variant(Color(.9,.8,.35)))
    for z=0,50,4 do
        local n=scene:CreateChild("CenterLine");n.position=V(0,.005,z);n.scale=V(.10,.015,1.5)
        local d=n:CreateComponent("StaticModel");d.model=draw.model;d.material=stripe
    end
end
local function cell(id,col,index,rect,checking)
    local cfg=assert(Assets[id]);local scene=Scene();scenes[#scenes+1]=scene;scene:CreateComponent("Octree")
    local light=scene:CreateChild("LightGroup");light:LoadXML(cache:GetResource("XMLFile","LightGroup/Daytime.xml"):GetRoot())
    local zone=light:GetComponent("Zone",true)
    if zone then zone.depthFogEnable=false;zone.heightFogEnable=false;zone.fogColor=Color(.12,.16,.21) end
    local source=assert(cache:GetResource("Model",cfg.model))
    local mat=Material()
    mat:SetTechnique(0,cache:GetResource("Technique","Techniques/PBR/PBRDiffNormal.xml"))
    mat:SetTexture(TU_DIFFUSE,assert(cache:GetResource("Texture2D",cfg.diffuse)))
    mat:SetTexture(TU_NORMAL,assert(cache:GetResource("Texture2D",cfg.normal)))
    mat:SetShaderParameter("MatDiffColor",Variant(Color(1,1,1,1)));mat:SetShaderParameter("Metallic",Variant(.18));mat:SetShaderParameter("Roughness",Variant(.52))
    local root=scene:CreateChild("Vehicle_"..id);local canonical=root:CreateChild("SourceTransform")
    local rotation=cfg.orientation;local bounds=sourceBounds(source,rotation)
    local scale=cfg.targetLength/bounds.size.z
    canonical.rotation=rotation;canonical:SetScale(scale)
    canonical.position=V(-bounds.center.x,-bounds.min.y,-bounds.center.z)*scale
    assert((bounds.size*scale-cfg.targetSize):Length()<.0005,"meterSizeMismatch "..id)
    assert(cfg.cockpit.localOffset.y>cfg.targetSize.y+.06,"eyeInsideShell "..id)
    Art.Build(canonical,id,source,mat)
    if checking then validate(root,id,source) end
    if col==3 then Art.Animate(root,id,.4,{distance=.21,steer=.5,oddActive=1,oddAge=.34}) end
    local cameraNode=scene:CreateChild("Camera");local focus=V(0,cfg.targetSize.y*.52,0)
    local length=math.max(cfg.targetSize.x,cfg.targetSize.y,cfg.targetLength)
    local direction=col==2 and V(-1.25,.65,-1.45) or V(1.35,.75,1.5)
    cameraNode.position=focus+direction*length;cameraNode:LookAt(focus)
    if col==4 then
        road(scene);cameraNode.position=cfg.cockpit.localOffset;cameraNode.rotation=Quaternion(cfg.cockpit.pitch,0,0)
    end
    local camera=cameraNode:CreateComponent("Camera");camera.nearClip=.015;camera.farClip=120;camera.fov=col==4 and cfg.cockpit.fov or 36
    local viewport=Viewport:new(scene,camera);viewport.rect=rect
    local path=viewport:GetRenderPath():Clone();assert(path:Load(cache:GetResource("XMLFile","RenderPaths/Forward.xml")))
    viewport:SetRenderPath(path);renderer:SetViewport(index,viewport)
    print(string.format("[OrganicMeasure] %s yaw=%.1f size=%.6f/%.6f/%.6f eye=%.2f/%.2f/%.2f col=%d",id,cfg.rotation,cfg.targetSize.x,cfg.targetSize.y,cfg.targetSize.z,cfg.cockpit.localOffset.x,cfg.cockpit.localOffset.y,cfg.cockpit.localOffset.z,col))
end
function Start()
    assert(cache:AddResourceDir("/workspace/assets"));assert(cache:AddResourceDir("/workspace/scripts"))
    local single="";local checkOnly=false
    for _,arg in ipairs(GetArguments()) do
        single=arg:match("^%-organic%-id=(.+)$") or single
        if arg=="-organic-check-only" then checkOnly=true end
    end
    renderer.hdrRendering=true;renderer.drawShadows=false
    local ids=single~="" and {single} or {"jellyfish","jetboat","frog"}
    renderer:SetNumViewports(checkOnly and #ids or #ids*4)
    local width,height=graphics:GetWidth(),graphics:GetHeight()
    for row,id in ipairs(ids) do
        for col=1,checkOnly and 1 or 4 do
            local x0=math.floor((col-1)*width/4);local y0=math.floor((row-1)*height/#ids)
            local x1=math.floor(col*width/4);local y1=math.floor(row*height/#ids)
            local viewportIndex=checkOnly and row-1 or (row-1)*4+col-1
            cell(id,col,viewportIndex,IntRect(x0,y0,x1,y1),col==1)
        end
    end
    print("[OrganicCheck] ALL PASS")
    if checkOnly then engine:Exit() end
end
function Stop()
    for _,scene in ipairs(scenes) do scene:Dispose() end
    scenes={}
end
