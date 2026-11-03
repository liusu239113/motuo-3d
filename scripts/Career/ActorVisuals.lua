-- 人、战损电动车、保温箱各自独立。尺寸由MDL包围盒校准，不套用赛车比例。
local Rig=require("Career.Rig")
local Locomotion=require("Career.Locomotion")
local Parts=require("Parts")
local Assets=require("VehicleAssets")
local Vehicles=require("Career.VehicleData")
local Rider=require("Rider")
local Bike=require("Bike")
local Contact=require("Career.VehicleContact")
local Footprints=require("Career.VehicleFootprints")
local V=Vector3
local SCOOTER="model/873a3764f21f49e4b717387160d13d19/"
local BOX="model/8c4f0f26f9ee4d3eac2eec49a497852f/"
local scooterModel=SCOOTER.."Meshes/873a3764f21f49e4b717387160d13d19.mdl"
local scooterMaterial=SCOOTER.."Materials/873a3764f21f49e4b717387160d13d19_00_tripo_material_a843f27f-7dc0-48b9-b818-99d319a20274.xml"
local boxModel=BOX.."Meshes/8c4f0f26f9ee4d3eac2eec49a497852f.mdl"
local boxMaterial=BOX.."Materials/8c4f0f26f9ee4d3eac2eec49a497852f_00_tripo_material_da86ec09-2a15-4a63-a371-538bf705b4fa.xml"
local SUBJECT_TECHNIQUE="Techniques/PBR/PBRDiffNormal.xml"
---@class CareerSubjectMaterial
---@field draw StaticModel
---@field material Material
---@field sourcePath string
---@field roughness number
---@field metallic number
---@class CareerSubjectVehicle
---@field node Node
---@field visual Node
---@field rider CareerRig
---@field available? boolean
---@class CareerSubjectParking
---@field x number
---@field z number
---@field yaw number
---@class CareerActorVisuals
---@field city CareerCity
---@field bikeNode Node
---@field bikeVisual Node
---@field cargoMount Node
---@field walkNode Node
---@field walker CareerRig
---@field mountedRider CareerRig
---@field locomotion CareerLocomotion
---@field subjectMaterials CareerSubjectMaterial[]
---@field ownedMaterials Material[]
---@field vehicles table<string,CareerSubjectVehicle>
---@field disposed boolean
---@field mounted boolean
---@field cityVisible boolean
---@field vehicleId string
---@field phase number
---@field gaitWeight number
---@field runWeight number
---@field lean number
---@field stopTime number
---@field lastPoseRider? CareerRig
---@field contactPitch? number
---@field contactRoll? number
---@field contactHeight? number
---@field contactX? number
---@field contactZ? number
---@field contactYaw? number
---@field contactLean? number
---@field contactSpace? string
---@field lastPoseSteer? number
---@field PrepareSubjectMaterial fun(self:CareerActorVisuals,draw:StaticModel,material:Material,sourcePath:string,roughness:number,metallic:number)
---@field EnsureVehicle fun(self:CareerActorVisuals,id:string):CareerSubjectVehicle
---@field SetVehicle fun(self:CareerActorVisuals,id:string)
---@field SetCityVisible fun(self:CareerActorVisuals,visible:boolean)
---@field UpdateParking fun(self:CareerActorVisuals,parking:table<string,CareerSubjectParking>,city:CareerCity)
---@field ResetGait fun(self:CareerActorVisuals)
---@field SetMounted fun(self:CareerActorVisuals,mounted:boolean)
---@field UpdateGait fun(self:CareerActorVisuals,dt:number,speed:number,distance?:number)
---@field Update fun(self:CareerActorVisuals,dt:number,speed:number,steer:number,bikeX:number,bikeY:number,bikeZ:number,bikeYaw:number,distance?:number)
---@field Dispose fun(self:CareerActorVisuals)
local Visuals={}
Visuals.__index=Visuals
Visuals.ProxyLabel="战损9号 · 独立外卖箱"
Visuals.AnimationLabel="王二狗 · 官方Idle/Walk/Run关键帧重定向 · 独立骑姿IK"
Visuals.Resources={scooterModel,scooterMaterial,boxModel,boxMaterial,Rig.ModelPath,Rig.MaterialPath,Rig.DiffusePath,Rig.NormalPath,"Techniques/DiffNormal.xml",SUBJECT_TECHNIQUE}
Visuals.ResourceTypes={[scooterModel]="Model",[scooterMaterial]="Material",[boxModel]="Model",[boxMaterial]="Material",
    [Rig.ModelPath]="Model",[Rig.MaterialPath]="Material",[Rig.DiffusePath]="Texture2D",[Rig.NormalPath]="Texture2D",["Techniques/DiffNormal.xml"]="Technique",[SUBJECT_TECHNIQUE]="Technique"}
for _,path in ipairs(Locomotion.Resources) do
    Visuals.Resources[#Visuals.Resources+1]=path
    Visuals.ResourceTypes[path]=Locomotion.ResourceTypes[path]
end
---@param scene Scene
---@param target Node
---@param city CareerCity
---@return CareerActorVisuals
function Visuals.New(scene,target,city)
    local self=setmetatable({},Visuals); self:Init(scene,target,city); return self
end
-- 主体使用已有D/N贴图的PBR漫反射/天空SH路径；不建覆盖Zone、不动太阳阴影。
-- 衣服/皮肤/保温箱不是金属，整车单材质也不能沿用导入器的Metallic=1。
-- 不加固定自发光底色，夜晚/室内仍由实际环境光决定亮度；缓存源材质保持只读。
---@param draw StaticModel
---@param material Material 私有clone；Rig已有材质仍由Rig释放
---@param sourcePath string
---@param roughness number
---@param metallic number
function Visuals:PrepareSubjectMaterial(draw,material,sourcePath,roughness,metallic)
    assert(material:GetTexture(TU_DIFFUSE) and material:GetTexture(TU_NORMAL),"主体PBR材质需要已有D/N贴图: "..sourcePath)
    material:SetTechnique(0,assert(cache:GetResource("Technique",SUBJECT_TECHNIQUE)))
    material:SetShaderParameter("MatDiffColor",Variant(Color(1,1,1,1)))
    -- 旧DiffNormal的MatSpecColor.a=25是高光幂，不能当作PBR反射参数沿用。
    material:SetShaderParameter("MatSpecColor",Variant(Color(.5,.5,.5,1)))
    material:SetShaderParameter("Metallic",Variant(metallic))
    material:SetShaderParameter("Roughness",Variant(roughness))
    -- PBRLitSolid的cMatEmissiveColor是vec3；显式零发光，不依赖旧材质/Technique默认值的Variant类型。
    material:SetShaderParameter("MatEmissiveColor",Variant(V.ZERO))
    draw:SetMaterial(material)
    self.subjectMaterials[#self.subjectMaterials+1]={draw=draw,material=material,sourcePath=sourcePath,roughness=roughness,metallic=metallic}
end
function Visuals:Init(scene,target,city)
    self.city=city
    self.subjectMaterials={}; self.ownedMaterials={}
    self.bikeNode=scene:CreateChild("战损9号与配送箱")
    self.bikeVisual=self.bikeNode:CreateChild("电动车压弯根")
    local body=self.bikeVisual:CreateChild("正式战损电动车")
    local model=cache:GetResource("Model",scooterModel)
    local bounds=model.boundingBox
    -- 长轴只确定轴线，正面实拍以白色头灯/前挡板为+Z；红尾灯与号牌必须在-Z。
    local rotation,scale,offset=Footprints.ScooterTransform(model)
    body:SetScale(scale)
    body.rotation=rotation
    body.position=offset
    local draw=body:CreateComponent("StaticModel")
    draw.model=model; draw.castShadows=true
    local scooterMat=cache:GetResource("Material",scooterMaterial):Clone()
    self.ownedMaterials[#self.ownedMaterials+1]=scooterMat
    self:PrepareSubjectMaterial(draw,scooterMat,scooterMaterial,.78,.12)
    self.cargoMount=self.bikeVisual:CreateChild("外卖箱固定挂点")
    self.cargoMount.position=Footprints.CargoPosition
    local box=self.cargoMount:CreateChild("橙色软保温外卖箱")
    local cargo=cache:GetResource("Model",boxModel)
    local bb=cargo.boundingBox
    local br,bs,bo=Footprints.BoxTransform(cargo)
    box:SetScale(bs); box.rotation=br; box.position=bo
    local cargoDraw=box:CreateComponent("StaticModel")
    cargoDraw.model=cargo; cargoDraw.castShadows=true
    local cargoMat=cache:GetResource("Material",boxMaterial):Clone()
    self.ownedMaterials[#self.ownedMaterials+1]=cargoMat
    self:PrepareSubjectMaterial(cargoDraw,cargoMat,boxMaterial,.9,0)
    local metal=Parts.Material(.08,.09,.1,.55,.55)
    local mirror=Parts.Material(.45,.57,.62,.1,.85)
    -- 原模型的完整高镜在-X（左侧），只补缺失的+X右镜；位置按原镜顶点镜像。
    Parts.Bar(self.bikeVisual,metal,V(.29,1.21,.27),V(.31,1.40,.20),.008)
    Parts.Add(self.bikeVisual,"9号右后视镜镜壳","Sphere",metal,Footprints.MirrorCenter,Footprints.MirrorSize,Quaternion(0,Footprints.MirrorYaw,0),true)
    Parts.Add(self.bikeVisual,"9号右后视镜镜片","Sphere",mirror,V(.306,1.425,.169),V(.125,.082,.012),Quaternion(0,12,0),false)
    for _,side in ipairs({-1,1}) do
        Parts.Bar(self.bikeVisual,metal,V(side*.2,.68,-.56),V(side*.2,.88,-.91),.015)
    end
    self.walkNode=target:CreateChild("王二狗步行根")
    self.walker=Rig.New(self.walkNode)
    self:PrepareSubjectMaterial(self.walker.model,self.walker.material,Rig.MaterialPath,.88,0)
    self.walker.ground=city
    self.locomotion=Locomotion.New(self.walker)
    self.walker.locomotion=self.locomotion
    self.mountedRider=Rig.New(self.bikeVisual)
    self:PrepareSubjectMaterial(self.mountedRider.model,self.mountedRider.material,Rig.MaterialPath,.88,0)
    self.phase,self.gaitWeight,self.runWeight,self.lean=0,0,0,0
    self.mounted,self.disposed=false,false
    self.vehicleId=Vehicles.EBIKE
    self.cityVisible=true
    self.vehicles={[Vehicles.EBIKE]={node=self.bikeNode,visual=self.bikeVisual,rider=self.mountedRider}}
    self:SetMounted(false)
    self.walker:PoseWalk(0,0)
    -- 完整模型落盘后才允许城市进入可玩态。
    print(string.format("[配送装备] 电动车原尺寸%s 缩放%.4f；箱原尺寸%s 缩放%.4f；独立挂点(0,.88,-.72)",bounds.size:ToString(),scale,bb.size:ToString(),bs))
    print("[主体材质] 主角/骑手启用贴图PBR，电动车金属度.12/软箱0；保留D/N贴图与阴影，无补灯/固定自发光")
end
function Visuals:EnsureVehicle(id)
    if self.vehicles[id] then return self.vehicles[id] end
    assert(Vehicles.Known(id),"未知城市车型")
    local node=self.bikeNode.parent:CreateChild("生涯城市摩托_"..id)
    local visual=node:CreateChild("摩托压弯根")
    Assets.Add(visual,id,nil,"balanced")
    local rider=Rig.New(visual)
    self:PrepareSubjectMaterial(rider.model,rider.material,Rig.MaterialPath,.88,0)
    rider.vehicleId,rider.classId=id,Rider.ClassFor(id)
    local source=assert(Rider.Poses[id] or Rider.Poses[rider.classId])
    local config={}
    for key,value in pairs(source) do config[key]=value end
    -- 同一人物始终1.76m；宽把巡航在座面内向右调整2cm，不能沿用旧骑手1.90m身高。
    if id=="cruiser_2" then config.hip=source.hip+V(.02,0,0) end
    rider.config=config
    rider.grip=Bike.GetCockpit(id).grip
    rider:SetVisible(false)
    self.vehicles[id]={node=node,visual=visual,rider=rider}
    node:SetEnabledRecursive(self.cityVisible)
    rider:SetVisible(false)
    return self.vehicles[id]
end
function Visuals:SetVehicle(id)
    local entry=self:EnsureVehicle(id)
    self.mountedRider:SetVisible(false)
    self.bikeVisual.rotation=Quaternion.IDENTITY
    self.bikeVisual.position=V.ZERO
    self.vehicleId=id
    self.contactX=nil
    self.bikeNode,self.bikeVisual,self.mountedRider=entry.node,entry.visual,entry.rider
    self.lean=0
    self:SetMounted(self.mounted)
end
function Visuals:SetCityVisible(visible)
    self.cityVisible=visible
    for id,entry in pairs(self.vehicles) do
        local enabled=visible and entry.available~=false
        entry.node:SetEnabledRecursive(enabled)
        entry.rider:SetVisible(enabled and self.mounted and id==self.vehicleId)
    end
end
function Visuals:UpdateParking(parking,city)
    for id,entry in pairs(self.vehicles) do
        entry.available=parking[id]~=nil
        local enabled=self.cityVisible and entry.available
        entry.node:SetEnabledRecursive(enabled)
        entry.rider:SetVisible(enabled and self.mounted and id==self.vehicleId)
    end
    for id,park in pairs(parking) do
        local entry=self:EnsureVehicle(id)
        local height,pitch,roll=Contact.Solve(city,id,park.x,park.z,park.yaw,0)
        entry.node.position=V(park.x,height,park.z)
        entry.node.rotation=Quaternion(0,park.yaw,0)*Quaternion(pitch,V.RIGHT)*Quaternion(roll,V.FORWARD)
    end
end
function Visuals:ResetGait()
    self.phase,self.gaitWeight,self.runWeight,self.stopTime=0,0,0,0
    self.locomotion:Reset()
end
function Visuals:SetMounted(mounted)
    if self.mounted~=mounted then self:ResetGait() end
    self.mounted=mounted
    self.lastPoseRider=nil
    self.walkNode:SetEnabledRecursive(not mounted); self.mountedRider:SetVisible(mounted and self.cityVisible)
    if not mounted then self.lean=0; self.bikeVisual.rotation=Quaternion.IDENTITY; self.bikeVisual.position=V.ZERO end
end
-- 纯步态入口，回归可直接驱动；不处理输入/相机/存档/车辆。
-- distance是Actor子步累计的真实移动距离（撞墙=0），省略时兼容既有速度驱动。
function Visuals:UpdateGait(dt,speed,distance)
    self.locomotion:Update(dt,speed,distance)
    self.phase=self.locomotion.phase*math.pi*2
    self.gaitWeight,self.runWeight=self.locomotion.moving,self.locomotion.running
end
function Visuals:Update(dt,speed,steer,bikeX,bikeY,bikeZ,bikeYaw,distance)
    if self.disposed then return end
    if self.mounted then
        local target=-steer*math.min(1,math.abs(speed)/(35/3.6))*10
        self.lean=self.lean+(target-self.lean)*(1-math.exp(-dt*10))
    else self.lean=0 end
    local height=bikeY
    ---@type number
    local pitch=0
    ---@type number
    local roll=self.lean
    if self.city and self.contactX==bikeX and self.contactZ==bikeZ and self.contactYaw==bikeYaw
        and self.contactLean==self.lean and self.contactSpace==self.city.space then
        height,pitch,roll=self.contactHeight or bikeY,self.contactPitch or 0,self.contactRoll or self.lean
    elseif self.city then
        height,pitch,roll=Contact.Solve(self.city,self.vehicleId,bikeX,bikeZ,bikeYaw,self.lean)
        self.contactX,self.contactZ,self.contactYaw,self.contactLean=bikeX,bikeZ,bikeYaw,self.lean
        self.contactSpace,self.contactHeight,self.contactPitch,self.contactRoll=self.city.space,height,pitch,roll
    end
    self.bikeNode.position=V(bikeX,height,bikeZ)
    self.bikeNode.rotation=Quaternion(0,bikeYaw,0)*Quaternion(pitch or 0,V.RIGHT)
    self.bikeVisual.rotation=Quaternion(roll or 0,V.FORWARD)
    self.bikeVisual.position=V.ZERO
    if self.mounted then
        if math.abs(steer-(self.lastPoseSteer or 100))>.001 or self.lastPoseRider~=self.mountedRider then
            self.mountedRider:PoseRide(steer)
            self.lastPoseSteer=steer;self.lastPoseRider=self.mountedRider
        end
    else
        self:UpdateGait(dt,speed,distance)
    end
end
function Visuals:Dispose()
    if self.disposed then return end
    self.disposed=true
    for _,entry in pairs(self.vehicles) do entry.rider:Dispose(); entry.node:Dispose() end
    self.walker:Dispose(); self.walkNode:Dispose()
    for _,material in ipairs(self.ownedMaterials) do material:Dispose() end
    self.ownedMaterials={}; self.subjectMaterials={}
end
return Visuals
