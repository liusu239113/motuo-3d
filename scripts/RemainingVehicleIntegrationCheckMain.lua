-- 九款剩余载具的一次批量集成验收；不加载main/Profile，不读写玩家存档。
assert(cache:AddResourceDir("/workspace/assets"))
assert(cache:AddResourceDir("/workspace/scripts"))
local Assets=require("MixedAssets")
local Visual=require("MixedVisuals")
local DrivingCamera=require("DrivingCamera")
local V=Vector3
local libraries={(require("RemainingOrganicArticulation")),(require("RemainingWheeledArticulation")),
    (require("RemainingNoveltyArticulation"))}
---@type Scene?
local scene_=nil
local owners_={}
local count_=0
local function check(ok,message)
    assert(ok,"[剩余九车集成] "..message)
    count_=count_+1
end
local function articulation(id)
    for _,library in ipairs(libraries) do if library.Has(id) then return library end end
    error("未接入关节："..id)
end
local function triangles(geometry)
    local buffer=geometry:GetIndexBuffer()
    local data=buffer:GetData()
    data:Seek(geometry.indexStart*buffer.indexSize)
    local result={}
    for _=1,geometry.indexCount//3 do
        local a=buffer.indexSize==2 and data:ReadUShort() or data:ReadUInt()
        local b=buffer.indexSize==2 and data:ReadUShort() or data:ReadUInt()
        local c=buffer.indexSize==2 and data:ReadUShort() or data:ReadUInt()
        local key=string.format("%d/%d/%d",a,b,c)
        result[key]=(result[key] or 0)+1
    end
    return result
end
local function sourceChecks(body,id)
    local c=Assets.Vehicles[id] --[[@as VehicleAssetConfig]]
    local source=assert(cache:GetResource("Model",c.model))
    local draws=body:GetComponents("StaticModel",true)
    for lod=0,source:GetNumGeometryLodLevels(0)-1 do
        local original=source:GetGeometry(0,lod)
        local remaining=triangles(original)
        local total=0
        for _,draw in ipairs(draws) do
            check(draw:GetMaterial():GetTexture(TU_DIFFUSE)~=nil and draw:GetMaterial():GetTexture(TU_NORMAL)~=nil,id.."D/N完整")
            local model=draw:GetModel()
            local geo=model:GetGeometry(0,lod)
            check(geo~=nil and geo:GetVertexBuffer(0)==original:GetVertexBuffer(0),id.."LOD原顶点缓冲"..lod)
            total=total+geo.indexCount
            for key,n in pairs(triangles(geo)) do
                check(remaining[key]~=nil and remaining[key]>=n,id.."禁止额外/重复/翻面")
                remaining[key]=remaining[key]-n
            end
        end
        if id=="skateboard" then
            -- 交付源文件误含第二套交叉板；仅剔除重复原件，保留一套真实原板+四轮。
            check(total>original.indexCount*.30 and total<=original.indexCount,id.."保留原网格主体且无新增面")
        else
            check(total==original.indexCount,id.."LOD原面数量守恒"..lod)
            for _,n in pairs(remaining) do check(n==0,id.."原三角面无遗漏") end
        end
    end
end
local function drive(id,active)
    return {vehicleId=id,x=0,y=0,z=0,heading=0,distance=active and .317 or 0,steer=active and .35 or 0,
        speed=active and 24 or 0,oddAge=active and .47 or 0,oddActive=active and 1.5 or 0,
        oddPhase=active and "active" or "idle",oddSerial=active and 1 or 0,
        oddShield=active and id=="bathtub" and 1 or 0,oddHop=active and .5 or 0,oddAltitude=0,
        oddLandingBoost=0,oddLandingSerial=0,oddHitSerial=0}
end
local function transforms(body,names)
    local result={}
    for _,name in ipairs(names) do result[name]=assert(body:GetChild(name,true),name).transform end
    return result
end
local function playerChecks(id)
    local bike=Visual.NewBike(scene_,id)
    owners_[#owners_+1]=bike
    local c=Assets.Vehicles[id] --[[@as VehicleAssetConfig]]
    local eye=id=="skateboard" and require("MixedDriver").Profiles[id].eye or c.cockpit.localOffset
    check((bike.Cockpit.localOffset-eye):Length()<.0001,id.."使用本车实测眼位")
    local size=bike.body:GetVar("VehicleSize"):GetVector3()
    check((size-c.targetSize):Length()<.005,id.."模型与碰撞尺寸一致")
    check(bike.body:GetVar("FormalModel"):GetString()==c.model,id.."正式独立模型")
    local canonical=assert(bike.body:GetChild("SourceTransform"))
    check(math.abs(canonical.scale.x-canonical.scale.y)<1e-6 and math.abs(canonical.scale.y-canonical.scale.z)<1e-6,id.."等比缩放")
    sourceChecks(bike.body,id)
    local names=articulation(id).GetConfig(id).joints
    local bodyNode=assert(bike.body:GetChild("Body",true))
    local fixed,sourceFixed=bodyNode.transform,canonical.transform
    local idle=drive(id,false)
    bike:UpdateState(.02,idle,true,0)
    local rest=transforms(bike.body,names)
    local helmet,camera=DrivingCamera.AttachHelmet(bike --[[@as Bike]])
    camera.aspectRatio=16/9
    local look=DrivingCamera.New()
    look:UpdateHelmet(bike --[[@as Bike]],helmet,camera,0,0)
    local dashboard=camera:WorldToScreenPoint(bike:GetDashboardWorldPosition())
    check(dashboard.x>0 and dashboard.x<1 and dashboard.y>0 and dashboard.y<1,id.."首视角仪表在屏内")
    for _,yaw in ipairs({0,90,180,270,360}) do
        look.yaw=yaw
        look:UpdateHelmet(bike --[[@as Bike]],helmet,camera,0,0)
        check((helmet.position-c.cockpit.localOffset):Length()<.00001,id.."360环视不改变眼位")
    end
    look.yaw=0;look:UpdateHelmet(bike --[[@as Bike]],helmet,camera,0,0)
    local active=drive(id,true)
    bike:UpdateState(.02,active,true,.47)
    check(bike.skillEffects and bike.skillEffects.active,id.."技能工厂实际接入")
    local moved=transforms(bike.body,names)
    local changed=false
    for _,name in ipairs(names) do if moved[name]~=rest[name] then changed=true end end
    check(changed,id.."独立原网格关节确实运动")
    active.paused=true
    bike:UpdateState(.8,active,true,99)
    for _,name in ipairs(names) do check(assert(bike.body:GetChild(name,true)).transform==moved[name],id.."暂停冻结"..name) end
    bike:UpdateState(.02,idle,false,2)
    for _,name in ipairs(names) do check(assert(bike.body:GetChild(name,true)).transform==rest[name],id.."结束恢复"..name) end
    check(bodyNode.transform==fixed and canonical.transform==sourceFixed,id.."禁止整车抖动冒充关节")
    check(not bike.skillEffects.active and not bike.firstPerson,id.."效果清理与视角恢复")
    bike.node:SetEnabledRecursive(false)
    return bike,helmet,camera
end
local function garageChecks(id)
    local preview=require("GaragePreview").New({width=800,height=500})
    preview.vehicleId,preview.active=id,true
    preview:BuildScene(id)
    local body=assert(preview.turntable:GetChild("Vehicle_"..id))
    check(body:GetVar("FormalModel"):GetString()==Assets.Vehicles[id].model,id.."真实车库使用同一模型")
    local names=articulation(id).GetConfig(id).joints
    Visual.Animate(body,id,0,drive(id,false))
    local rest=transforms(body,names)
    for _,yaw in ipairs({0,90,180,270,360}) do
        preview.turntable.rotation=Quaternion(0,yaw,0)
        Visual.Animate(body,id,yaw,drive(id,false))
        for _,name in ipairs(names) do check(assert(body:GetChild(name,true)).transform==rest[name],id.."车库360停车不乱动") end
    end
    preview:Dispose();preview:Dispose();preview:Destroy()
end
local function aiChecks()
    local RV=require("RaceVisuals")
    local root=scene_:CreateChild("RemainingRivals")
    local racers={}
    for i,id in ipairs(Assets.RemainingIds) do
        racers[#racers+1]={id="fixture_"..id,vehicleId=id,colorId="red",index=i,x=i*5,y=0,z=0,
            heading=0,speed=24,steer=.35,driveSim=drive(id,true)}
    end
    local visuals=setmetatable({scene=scene_,root=root,rosterRoot=root:CreateChild("RaceRivals"),
        runners={},markers={},materials={},world={},race={racers=racers},clock=0,visibilityClock=0,
        highQuality=false,leanSign=1,disposed=false,visible=true,EnsurePolice=function() end},RV)
    visuals:Reset();visuals:Update(.02,{x=0,z=0})
    for _,data in ipairs(racers) do
        local runner=assert(visuals.runners[data.id])
        check(runner.body:GetVar("FormalModel"):GetString()==Assets.Vehicles[data.vehicleId].model,data.vehicleId.."AI同一正式模型")
        check(runner.skillEffects and runner.skillEffects.active,data.vehicleId.."AI技能表现")
        check(not runner.node:GetChild("Cockpit",true),data.vehicleId.."AI不分配玩家座舱")
        data.x=1000
    end
    visuals:Update(.02,{x=0,z=0})
    for _,runner in pairs(visuals.runners) do check(not runner.active and not runner.skillEffects.active,runner.vehicleId.."远距清理") end
    for i,data in ipairs(racers) do data.x=i*5 end
    visuals:Update(.02,{x=0,z=0})
    for _,runner in pairs(visuals.runners) do check(runner.active and runner.skillEffects.active,runner.vehicleId.."远距恢复") end
    visuals:SetVisible(false)
    for _,runner in pairs(visuals.runners) do check(not runner.skillEffects.active,runner.vehicleId.."隐藏清理") end
    visuals:Dispose();visuals:Dispose()
end
local function reviewSheet()
    -- 同一进程18格：每车第三人称/真实首视角并排，不反复启动或生成新素材。
    renderer:SetNumViewports(#owners_*2)
    local w,h=graphics:GetWidth(),graphics:GetHeight()
    local roadMaterial=Material:new()
    roadMaterial:SetTechnique(0,assert(cache:GetResource("Technique","Techniques/PBR/PBRNoTexture.xml")))
    roadMaterial:SetShaderParameter("MatDiffColor",Variant(Color(.12,.14,.16)))
    local stripeMaterial=roadMaterial:Clone()
    stripeMaterial:SetShaderParameter("MatDiffColor",Variant(Color(.94,.76,.18)))
    local box=assert(cache:GetResource("Model","Models/Box.mdl"))
    for i,bike in ipairs(owners_) do
        local base=V(i*30,0,0)
        bike.node.position=base;bike.node:SetEnabledRecursive(true)
        bike:SetFirstPerson(true)
        local road=scene_:CreateChild("ReviewRoad")
        road.position=base+V(0,-.06,24);road.scale=V(9,.1,60)
        local draw=road:CreateComponent("StaticModel");draw:SetModel(box);draw:SetMaterial(roadMaterial)
        for z=4,48,5 do
            local mark=scene_:CreateChild("ReviewLine")
            mark.position=base+V(0,.001,z);mark.scale=V(.10,.01,2)
            local d=mark:CreateComponent("StaticModel");d:SetModel(box);d:SetMaterial(stripeMaterial)
        end
        for view=1,2 do
            local cell=(i-1)*2+view-1
            local col,row=cell%6,cell//6
            local cameraNode=scene_:CreateChild("SheetCamera")
            local camera=cameraNode:CreateComponent("Camera")
            camera.nearClip,camera.farClip=.025,100
            if view==2 then
                cameraNode:SetParent(bike.visual);cameraNode.position=bike.Cockpit.localOffset
                cameraNode.rotation=Quaternion(bike.Cockpit.pitch,V.RIGHT);camera.fov=bike.Cockpit.fov
            else
                local size=bike.body:GetVar("VehicleSize"):GetVector3()
                local focus=base+V(0,size.y*.5,0)
                cameraNode.position=focus+V(1.35,.65,1.5)*math.max(size.x,size.y,size.z)
                cameraNode:LookAt(focus);camera.fov=40
            end
            local viewport=Viewport:new(scene_,camera)
            viewport.rect=IntRect(math.floor(col*w/6),math.floor(row*h/3),math.floor((col+1)*w/6),math.floor((row+1)*h/3))
            renderer:SetViewport(cell,viewport)
        end
    end
end
function Start()
    local UI=require("urhox-libs/UI")
    UI.Init({theme="default-dark",scale=UI.Scale.DEFAULT})
    scene_=Scene();scene_:CreateComponent("Octree")
    local group=scene_:CreateChild("LightGroup")
    group:LoadXML(assert(cache:GetResource("XMLFile","LightGroup/Daytime.xml")):GetRoot())
    local zone=group:GetComponent("Zone",true)
    if zone then zone.depthFogEnable,zone.heightFogEnable=false,false end
    local catalog=require("Catalog")
    local pool={}
    for _,id in ipairs(Assets.RaceIds()) do check(not pool[id],"竞速池不得重复");pool[id]=true end
    check(#Assets.RaceIds()==27,"27车型均进入竞速池")
    for _,id in ipairs(Assets.RemainingIds) do
        check(catalog.Get(id).available and pool[id],id.."车库与竞赛均开放")
        playerChecks(id)
        garageChecks(id)
    end
    aiChecks()
    local Skill=require("SkillPresentation")
    local water={kind="jellyfish",x=1,y=2,z=3,vx=0,vy=0,vz=65}
    Skill.UpdateShot(scene_,water)
    check(water.node and water.node.position==V(1,2,3),"水母可见弹体绑定真实位置")
    Skill.Clear({water});check(not water.node,"水球清理")
    print("[剩余九车集成] PASS "..count_.." assertions / 正式模型+LOD原面+眼位360+关节+玩家AI车库+生命周期")
    for _,arg in ipairs(GetArguments()) do
        if arg=="-remaining-sheet" then reviewSheet();return end
    end
    engine:Exit()
end
function Stop()
    for _,owner in ipairs(owners_) do owner:Dispose() end
    owners_={}
    if scene_ then scene_:Dispose();scene_=nil end
end
