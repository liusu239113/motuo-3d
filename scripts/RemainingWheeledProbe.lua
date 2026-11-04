-- Source-preserving standalone probe, adapted from scaffold-3d-scene and the original wheeled probe.
-- Default: one deterministic 3x4 contact sheet, no game entry/save data/build/devserver.
-- Columns: rear quarter / right side / top / actual cockpit. Rows: skateboard / sled / cart.
local Assets=require("RemainingWheeledAssets")
local Art=require("RemainingWheeledArticulation")
local V=Vector3
---@type Scene[]
local scenes={}
local rows={"skateboard","sled","cart"}
local checks=0
local function check(ok,message)
    assert(ok,message);checks=checks+1
end
---@param id string
---@return Model,Material
local function load(id)
    local c=assert(Assets[id])
    local source=assert(cache:GetResource("Model",c.model),c.model)
    local material=assert(cache:GetResource("Material",c.material),c.material):Clone()
    material:SetTexture(TU_DIFFUSE,assert(cache:GetResource("Texture2D",c.diffuse)))
    material:SetTexture(TU_NORMAL,assert(cache:GetResource("Texture2D",c.normal)))
    return source,material
end
---@param source Model
---@param rotation Quaternion
---@return BoundingBox
local function measure(source,rotation)
    local bounds=BoundingBox()
    local geo=source:GetGeometry(0,0)
    local vb,ib=geo:GetVertexBuffer(0),geo:GetIndexBuffer()
    local vertices,index=vb:GetData(),ib:GetData()
    index:Seek(geo.indexStart*ib.indexSize)
    for _=1,geo.indexCount do
        local n=ib.indexSize==2 and index:ReadUShort() or index:ReadUInt()
        vertices:Seek(n*vb.vertexSize+vb:GetElementOffset(SEM_POSITION))
        bounds:Merge(rotation*vertices:ReadVector3())
    end
    return bounds
end
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
            data:Seek(n*vb.vertexSize+vb:GetElementOffset(SEM_POSITION));local p=data:ReadVector3()
            data:Seek(n*vb.vertexSize+vb:GetElementOffset(SEM_NORMAL));local normal=data:ReadVector3()
            data:Seek(n*vb.vertexSize+vb:GetElementOffset(SEM_TEXCOORD));local uv=data:ReadVector2()
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
    local file=File("/workspace/.tmp/remaining_wheeled_"..id..".json",FILE_WRITE)
    assert(file.open);file:WriteString(require("cjson").encode(levels));file:Dispose()
end
---@param geometry Geometry
---@return table<string,number>
local function faces(geometry)
    local ib=geometry:GetIndexBuffer();local data=ib:GetData()
    data:Seek(geometry.indexStart*ib.indexSize)
    local result={}
    for _=1,geometry.indexCount//3 do
        local a=ib.indexSize==2 and data:ReadUShort() or data:ReadUInt()
        local b=ib.indexSize==2 and data:ReadUShort() or data:ReadUInt()
        local c=ib.indexSize==2 and data:ReadUShort() or data:ReadUInt()
        local key=a.."/"..b.."/"..c
        result[key]=(result[key] or 0)+1
    end
    return result
end
---@param canonical Node
---@param id string
local function pose(canonical,id)
    local result={}
    for _,name in ipairs(Art.GetConfig(id).joints) do
        local n=assert(canonical:GetChild(name))
        result[name]={p=n.position,q=n.rotation}
    end
    return result
end
local function same(a,b)
    for name,p in pairs(a) do
        if (p.p-b[name].p):Length()>.000001 or not p.q:Equals(b[name].q) then return false end
    end
    return true
end
---@param canonical Node
---@param id string
---@param source Model
local function validate(canonical,id,source)
    local config=Art.GetConfig(id)
    for lod=0,source:GetNumGeometryLodLevels(0)-1 do
        local original=source:GetGeometry(0,lod)
        local expected=faces(original)
        local count=0
        for _,draw in ipairs(canonical:GetComponents("StaticModel",true)) do
            local geometry=draw.model:GetGeometry(0,lod)
            check(geometry~=nil,id.." missing part LOD")
            check(geometry:GetVertexBuffer(0)==original:GetVertexBuffer(0),id.." modified VB")
            check(geometry.lodDistance==original.lodDistance,id.." changed LOD distance")
            for key,n in pairs(faces(geometry)) do expected[key]=(expected[key] or 0)-n end
            count=count+geometry.indexCount
        end
        if Assets[id].sourceSubset then
            local retained={2734,2254,1711,1134}
            check(count==retained[lod+1]*3,id.." unexpected principal-board subset size LOD"..lod)
            check(canonical:GetChild("Discard")==nil,"Discard assembly must never be rendered")
            for _,n in pairs(expected) do check(n>=0,id.." invented or duplicated original face LOD"..lod) end
        else
            check(count==original.indexCount,id.." lost/duplicated faces LOD"..lod)
            for _,n in pairs(expected) do check(n==0,id.." changed original triangle/winding LOD"..lod) end
        end
    end
    local body=assert(canonical:GetChild("Body"))
    local rest=pose(canonical,id)
    Art.Animate(canonical,id,200,{distance=0,steer=0,oddActive=false})
    check(same(rest,pose(canonical,id)),id.." idle not at rest")
    Art.Animate(canonical,id,300,{distance=.127,steer=.6,oddActive=false})
    local driven=pose(canonical,id)
    check(not same(rest,driven),id.." no independent driving articulation")
    Art.Animate(canonical,id,700,{distance=.127,steer=.6,oddActive=false})
    check(same(driven,pose(canonical,id)),id.." wall-clock driving")
    Art.Animate(canonical,id,0,{distance=0,steer=0,oddActive=true,oddAge=.23})
    local boolPose=pose(canonical,id)
    check(not same(rest,boolPose),id.." skill has no joint motion")
    Art.Animate(canonical,id,0,{distance=0,steer=0,oddActive=.8,oddAge=.23})
    check(same(boolPose,pose(canonical,id)),id.." bool/numeric skill mismatch")
    Art.Animate(canonical,id,900,{distance=100,steer=-1,oddActive=1,oddAge=10,paused=true})
    check(same(boolPose,pose(canonical,id)),id.." pause changed transform")
    Art.Animate(canonical,id,0,{distance=0,steer=0,oddActive=0,oddAge=9})
    check(same(rest,pose(canonical,id)),id.." skill-end did not restore rest")
    check(body.rotation:Equals(Quaternion.IDENTITY) and body.position:Length()<.000001,id.." Body pretending to be joint")
    for _,name in ipairs(config.joints) do check(name~="Body",id.." invalid Body joint") end
end

local function run()
    renderer.drawShadows=false -- Multi-viewport source validation does not need repeated shadow-map passes.
    assert(cache:AddResourceDir("/workspace/assets"));assert(cache:AddResourceDir("/workspace/scripts"))
    local dumping=false
    local id,view="all","montage"
    for _,arg in ipairs(GetArguments()) do
        id=arg:match("^%-remaining%-vehicle=(.+)$") or id
        view=arg:match("^%-remaining%-view=(.+)$") or view
        if arg=="-remaining-dump" then dumping=true end
    end
    if dumping then
        for _,vehicle in ipairs(rows) do local source=load(vehicle);dump(source,vehicle) end
        engine:Exit();return
    end
    local selected=id=="all" and rows or {id}
    local report={vehicles={},layout="rows skateboard/sled/cart; columns rear-quarter/side/top/cockpit"}
    local w,h=graphics:GetWidth(),graphics:GetHeight()
    local index=0
    for row,vehicle in ipairs(selected) do
        local c=assert(Assets[vehicle]);local source,mat=load(vehicle)
        local bounds=c.sourceBounds or measure(source,c.orientation)
        local scale=c.targetLength/bounds.size.z
        local size=bounds.size*scale
        check((size-c.targetSize):Length()<.00002,vehicle.." targetSize mismatch")
        check((measure(source,Quaternion.IDENTITY).size-c.measuredSize):Length()<.00002,vehicle.." raw measurement mismatch")
        check(c.cockpit.localOffset.y>size.y+.1,vehicle.." cockpit inside body bounds")
        local scene=Scene();scenes[#scenes+1]=scene;scene:CreateComponent("Octree")
        local lights=scene:CreateChild("LightGroup")
        lights:LoadXML(assert(cache:GetResource("XMLFile","LightGroup/Daytime.xml")):GetRoot())
        local zone=lights:GetComponent("Zone",true)
        if zone then zone.depthFogEnable=false;zone.heightFogEnable=false end
        local root=scene:CreateChild("Vehicle_"..vehicle)
        local canonical=root:CreateChild("SourceTransform")
        canonical.rotation=c.orientation;canonical:SetScale(scale)
        canonical.position=V(-bounds.center.x,-bounds.min.y,-bounds.center.z)*scale
        Art.Build(canonical,vehicle,source,mat)
        validate(canonical,vehicle,source)
        local renderedBounds=BoundingBox()
        for _,draw in ipairs(canonical:GetComponents("StaticModel",true)) do
            local actual=measure(draw.model,c.orientation)
            renderedBounds:Merge(actual.min);renderedBounds:Merge(actual.max)
        end
        check((renderedBounds.min-bounds.min):Length()<.00002 and (renderedBounds.max-bounds.max):Length()<.00002,
            vehicle.." retained indexed LOD0 bounds differ from Assets.sourceBounds")
        local directions={V(1.15,.70,-1.25),V(1.5,.17,0),V(0,1.65,.001)}
        local columns=view=="montage" and 4 or 1
        for col=1,columns do
            local node=scene:CreateChild("Camera_"..col)
            local camera=node:CreateComponent("Camera")
            camera.nearClip,camera.farClip,camera.fov=.025,100,42
            local choose=view=="montage" and col or (view=="side" and 2 or view=="top" and 3 or view=="cockpit" and 4 or 1)
            if choose==4 then
                node.position=c.cockpit.localOffset;node.rotation=Quaternion(c.cockpit.pitch,0,0)
                camera.fov=c.cockpit.fov
            else
                local focus=V(0,size.y*.45,0)
                node.position=focus+directions[choose]*math.max(size.z,size.y)*1.05
                node:LookAt(focus)
            end
            local viewport=Viewport:new(scene,camera)
            viewport.rect=IntRect(math.floor((col-1)*w/columns),math.floor((row-1)*h/#selected),
                math.floor(col*w/columns),math.floor(row*h/#selected))
            local path=viewport:GetRenderPath():Clone()
            assert(path:Load(assert(cache:GetResource("XMLFile","RenderPaths/Forward.xml"))))
            viewport:SetRenderPath(path);renderer:SetViewport(index,viewport);index=index+1
        end
        report.vehicles[vehicle]={size={size.x,size.y,size.z},scale=scale,
            eye={c.cockpit.localOffset.x,c.cockpit.localOffset.y,c.cockpit.localOffset.z},joints=Art.GetConfig(vehicle).joints}
    end
    renderer.hdrRendering=true
    report.assertions=checks;report.result="PASS"
    local file=File("/workspace/.tmp/remaining_wheeled_validation.json",FILE_WRITE)
    assert(file.open);file:WriteString(require("cjson").encode(report));file:Dispose()
    print("[RemainingWheeled] READY: all source-face, LOD, dimension, animation, pause and reset assertions PASS ("..checks..")")
end
function Start()
    local ok,err=xpcall(run,debug.traceback)
    if not ok then log:Write(LOG_ERROR,"[RemainingWheeled] "..tostring(err));error(err) end
end
function Stop()
    for _,scene in ipairs(scenes) do scene:Dispose() end
    scenes={}
end
