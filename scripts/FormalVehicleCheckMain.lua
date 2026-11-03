-- 基于3D场景脚手架的正式载具验收入口，不读取或写入玩家存档。
local Assets = require("MixedAssets")
local Visual = require("MixedVisuals")
---@type Scene?
local scene_ = nil
---@class FormalSequence
---@field vehicle Node
---@field id string
---@field frame integer
---@field body Matrix3x4
---@field source Matrix3x4
---@field previous table<string,Matrix3x4>
---@field resting table<string,Matrix3x4>
---@field hold integer
---@type FormalSequence?
local sequence_ = nil

---@param geometry Geometry
---@return table<string,integer>
local function triangleCounts(geometry)
    local buffer=geometry:GetIndexBuffer()
    local data=buffer:GetData()
    data:Seek(geometry.indexStart*buffer.indexSize)
    ---@type table<string,integer>
    local counts={}
    for _=1,geometry.indexCount//3 do
        local a=buffer.indexSize==2 and data:ReadUShort() or data:ReadUInt()
        local b=buffer.indexSize==2 and data:ReadUShort() or data:ReadUInt()
        local c=buffer.indexSize==2 and data:ReadUShort() or data:ReadUInt()
        local key=string.format("%d/%d/%d",a,b,c)
        counts[key]=(counts[key] or 0)+1
    end
    return counts
end

---@param vehicle Node
---@param id string
---@return string[]
local function movingNames(vehicle,id)
    local names=id=="tank" and {"Turret","Barrel"} or {"JawP","JawN"}
    for _,side in ipairs({"P","N"}) do
        for station=1,(id=="tank" and 8 or 3) do
            names[#names+1]=(id=="tank" and "Wheel" or "Leg")..side..station
        end
    end
    for _,name in ipairs(names) do assert(vehicle:GetChild(name,true),"缺少原网格关节："..name) end
    return names
end

---@param vehicle Node
---@param id string
local function checkArticulation(vehicle,id)
    local body=assert(vehicle:GetChild("Body",true))
    local source=assert(vehicle:GetChild("SourceTransform"))
    local bodyRest,sourceRest=body.worldTransform,source.transform
    local names=movingNames(vehicle,id)
    Visual.Animate(vehicle,id,0,{distance=0,steer=0,oddActive=0})
    ---@type table<string,Matrix3x4>
    local resting={}
    for _,name in ipairs(names) do resting[name]=assert(vehicle:GetChild(name,true)).transform end
    Visual.Animate(vehicle,id,.12,{distance=.207,steer=.5,oddActive=0})
    for _,name in ipairs(names) do
        if name:match("^Wheel") or name:match("^Leg") or name=="Turret" then
            assert(assert(vehicle:GetChild(name,true)).transform~=resting[name],name.."必须独立运动")
        end
    end
    ---@type table<string,Matrix3x4>
    local stopped={}
    for _,name in ipairs(names) do stopped[name]=assert(vehicle:GetChild(name,true)).transform end
    Visual.Animate(vehicle,id,19,{distance=.207,steer=.5,oddActive=0})
    for _,name in ipairs(names) do
        assert(assert(vehicle:GetChild(name,true)).transform==stopped[name],name.."停止行驶后不可继续按墙钟运动")
    end
    Visual.Animate(vehicle,id,.049,{distance=.207,steer=0,oddActive=1})
    for _,name in ipairs(id=="tank" and {"Turret","Barrel"} or {"JawP","JawN"}) do
        assert(assert(vehicle:GetChild(name,true)).transform~=resting[name],name.."技能应驱动独立原网格")
    end
    Visual.Animate(vehicle,id,3,{distance=0,steer=0,oddActive=0})
    for _,name in ipairs(names) do
        assert(assert(vehicle:GetChild(name,true)).transform==resting[name],name.."结束技能/里程复位后必须精确复位")
    end
    assert(body.worldTransform==bodyRest and source.transform==sourceRest,"禁止整块Body或源变换晃动冒充关节动画")
    print("[正式关节断言] PASS "..id.." / 原部件运动 / 停驶冻结 / 技能复位 / Body稳固")
end

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
        local originals=triangleCounts(original)
        ---@type table<string,integer>
        local extracted={}
        for _,draw in ipairs(vehicle:GetComponents("StaticModel",true)) do
            local geometry=assert(draw:GetModel():GetGeometry(0,lod),"每个部件必须保留全部LOD")
            assert(geometry:GetVertexBuffer(0)==original:GetVertexBuffer(0),"每LOD保留正式源顶点流")
            for key,amount in pairs(triangleCounts(geometry)) do extracted[key]=(extracted[key] or 0)+amount end
            total=total+geometry.indexCount
        end
        assert(total==original.indexCount,"各LOD拆件不得增加或丢失原三角面")
        for key,amount in pairs(originals) do assert(extracted[key]==amount,"原始三角面重复或遗漏："..key) end
        for key,amount in pairs(extracted) do assert(originals[key]==amount,"拆件不得新增或翻转源三角面："..key) end
    end
    if id=="tank" or id=="beetle" then
        local actual=vehicle:GetVar("VehicleSize"):GetVector3()
        assert((actual-config.targetSize):Length()<.003,"正式实测尺寸必须同步规则targetSize")
        assert(config.rotation==-90,"源+X前必须统一yaw=-90")
        checkArticulation(vehicle,id)
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
        root.transform=assert(vehicle:GetChild("SourceTransform")).transform
        local draw=root:CreateComponent("StaticModel")
        draw:SetModel(source)
        local formalDraw=assert(vehicle:GetComponents("StaticModel",true)[1])
        draw:SetMaterial(assert(formalDraw:GetMaterial()))
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
    local animated=id=="ebike" or id=="helicopter" or id=="tank" or id=="beetle"
    print(string.format("[正式模型验收] PASS %s / %d原始三角面 / D+N / %s / pose=%.4f",id,count//3,
        animated and "独立部件动画断言通过" or "静态模型检查，动画尚未验收",pose))
    for _,arg in ipairs(GetArguments()) do
        if arg=="-formal-sequence" then
            assert(id=="tank" or id=="beetle","受控分帧检查用于坦克/锹甲")
            Visual.Animate(vehicle,id,0,{distance=0,steer=0,oddActive=0})
            ---@type table<string,Matrix3x4>
            local resting={}
            for _,name in ipairs(movingNames(vehicle,id)) do resting[name]=assert(vehicle:GetChild(name,true)).transform end
            sequence_={vehicle=vehicle,id=id,frame=0,hold=8,body=assert(vehicle:GetChild("Body",true)).worldTransform,
                source=assert(vehicle:GetChild("SourceTransform")).transform,previous={},resting=resting}
            for _,option in ipairs(GetArguments()) do
                sequence_.hold=math.max(1,math.floor(tonumber(option:match("^%-formal%-hold=(%d+)$")) or sequence_.hold))
            end
            SubscribeToEvent("Update","HandleFormalSequence")
        end
    end
end

-- 每个阶段持续hold个真正渲染帧：0静止、1/2行驶、3/4停驶、5/6技能、7复位。
-- 截图脚本可按 -formal-hold=N 精确采样；不写玩家存档，不自行退出或构建。
---@param _ string
---@param _ UpdateEventData
function HandleFormalSequence(_,_)
    local sequence=sequence_
    if not sequence then return end
    sequence.frame=sequence.frame+1
    local stage=math.min(7,(sequence.frame-1)//sequence.hold)
    local distance=stage==0 and 0 or (stage==1 and .207 or .391)
    local steer=(stage==1 or stage==2) and .5 or 0
    local active=(stage==5 or stage==6) and 1 or 0
    if stage==7 then distance=0 end
    local time=stage==5 and .049 or (stage==6 and .13 or stage*.12)
    Visual.Animate(sequence.vehicle,sequence.id,time,{distance=distance,steer=steer,oddActive=active})
    assert(assert(sequence.vehicle:GetChild("Body",true)).worldTransform==sequence.body,"分帧Body必须稳固不动")
    assert(assert(sequence.vehicle:GetChild("SourceTransform")).transform==sequence.source,"分帧源变换不得晃动")
    if sequence.frame%sequence.hold==0 then
        for _,name in ipairs(movingNames(sequence.vehicle,sequence.id)) do
            local transform=assert(sequence.vehicle:GetChild(name,true)).transform
            if stage==1 or stage==2 then
                if name:match("^Wheel") or name:match("^Leg") then
                    assert(transform~=sequence.previous[name],"受控行驶帧关节没有运动："..name)
                end
            elseif stage==4 then
                assert(transform==sequence.previous[name],"受控停驶帧关节未冻结："..name)
            elseif stage==5 or stage==6 then
                if name=="Turret" or name=="Barrel" or name:match("^Jaw") then
                    assert(transform~=sequence.previous[name],"受控技能帧没有独立动作："..name)
                end
            elseif stage==7 then
                assert(transform==sequence.resting[name],"受控技能结束关节未复位："..name)
            end
            sequence.previous[name]=transform
        end
        print(string.format("[正式受控帧] PASS %s / stage=%d / frame=%d / distance=%.3f / skill=%d",
            sequence.id,stage,sequence.frame,distance,active))
        if stage==7 then
            print("[正式受控多帧验收] PASS "..sequence.id.." / 行驶独立动作 / 停驶冻结 / 技能结束复位 / Body稳固")
            UnsubscribeFromEvent("Update")
            sequence_=nil
        end
    end
end

function Stop()
    UnsubscribeFromEvent("Update")
    sequence_=nil
    if scene_ then scene_:Dispose(); scene_=nil end
end
