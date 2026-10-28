-- 人、战损电动车、保温箱各自独立。尺寸由MDL包围盒校准，不套用赛车比例。
local Rig=require("Career.Rig")
local Parts=require("Parts")
local V=Vector3
local SCOOTER="model/873a3764f21f49e4b717387160d13d19/"
local BOX="model/8c4f0f26f9ee4d3eac2eec49a497852f/"
local scooterModel=SCOOTER.."Meshes/873a3764f21f49e4b717387160d13d19.mdl"
local scooterMaterial=SCOOTER.."Materials/873a3764f21f49e4b717387160d13d19_00_tripo_material_a843f27f-7dc0-48b9-b818-99d319a20274.xml"
local boxModel=BOX.."Meshes/8c4f0f26f9ee4d3eac2eec49a497852f.mdl"
local boxMaterial=BOX.."Materials/8c4f0f26f9ee4d3eac2eec49a497852f_00_tripo_material_da86ec09-2a15-4a63-a371-538bf705b4fa.xml"
---@class CareerActorVisuals
local Visuals={}
Visuals.__index=Visuals
Visuals.ProxyLabel="战损9号 · 独立外卖箱"
Visuals.AnimationLabel="王二狗 · 骨骼IK骑姿与步行"
Visuals.Resources={scooterModel,scooterMaterial,boxModel,boxMaterial,Rig.ModelPath,Rig.MaterialPath,Rig.DiffusePath,Rig.NormalPath,"Techniques/DiffNormal.xml"}
Visuals.ResourceTypes={[scooterModel]="Model",[scooterMaterial]="Material",[boxModel]="Model",[boxMaterial]="Material",
    [Rig.ModelPath]="Model",[Rig.MaterialPath]="Material",[Rig.DiffusePath]="Texture2D",[Rig.NormalPath]="Texture2D",["Techniques/DiffNormal.xml"]="Technique"}
function Visuals.New(scene,target)
    local self=setmetatable({},Visuals); self:Init(scene,target); return self
end
function Visuals:Init(scene,target)
    self.bikeNode=scene:CreateChild("战损9号与配送箱")
    self.bikeVisual=self.bikeNode:CreateChild("电动车压弯根")
    local body=self.bikeVisual:CreateChild("正式战损电动车")
    local model=cache:GetResource("Model",scooterModel)
    local bounds=model.boundingBox
    -- 实际顶点PCA长轴=(-.721,0,.693)，旋转46.1度对齐城市车辆纵轴。
    local scale=1.90/1.3094
    body:SetScale(scale)
    body.rotation=Quaternion(0,46.1,0)
    body.position=V(0,-bounds.min.y*scale,0)
    local draw=body:CreateComponent("StaticModel")
    draw.model=model; draw.material=cache:GetResource("Material",scooterMaterial); draw.castShadows=true
    self.cargoMount=self.bikeVisual:CreateChild("外卖箱固定挂点")
    self.cargoMount.position=V(0,.88,-.72)
    local box=self.cargoMount:CreateChild("橙色软保温外卖箱")
    local cargo=cache:GetResource("Model",boxModel)
    local bb=cargo.boundingBox
    local bs=.58/math.max(bb.size.x,bb.size.z)
    box:SetScale(bs); box.position=V(-bb.center.x*bs,-bb.min.y*bs,-bb.center.z*bs)
    local cargoDraw=box:CreateComponent("StaticModel")
    cargoDraw.model=cargo; cargoDraw.material=cache:GetResource("Material",boxMaterial); cargoDraw.castShadows=true
    local metal=Parts.Material(.08,.09,.1,.55,.55)
    local mirror=Parts.Material(.45,.57,.62,.1,.85)
    -- 原模型自带右镜，补左镜及支杆，避免重复叠放已有镜片。
    Parts.Bar(self.bikeVisual,metal,V(-.28,1.03,.37),V(-.37,1.32,.37),.008)
    Parts.Add(self.bikeVisual,"9号左后视镜","Sphere",mirror,V(-.37,1.34,.37),V(.13,.1,.035),Quaternion(0,-12,0),false)
    for _,side in ipairs({-1,1}) do
        Parts.Bar(self.bikeVisual,metal,V(side*.2,.68,-.56),V(side*.2,.88,-.91),.015)
    end
    self.walkNode=target:CreateChild("王二狗步行根")
    self.walker=Rig.New(self.walkNode)
    self.mountedRider=Rig.New(self.bikeVisual)
    self.phase,self.gaitWeight,self.lean=0,0,0
    self.mounted,self.disposed=false,false
    self:SetMounted(false)
    self.walker:PoseWalk(0,0)
    -- 完整模型落盘后才允许城市进入可玩态。
    print(string.format("[配送装备] 电动车原尺寸%s 缩放%.4f；箱原尺寸%s 缩放%.4f；独立挂点(0,.88,-.72)",bounds.size:ToString(),scale,bb.size:ToString(),bs))
end
function Visuals:SetMounted(mounted)
    self.mounted=mounted
    self.walkNode:SetEnabledRecursive(not mounted); self.mountedRider:SetVisible(mounted)
    if not mounted then self.lean=0; self.bikeVisual.rotation=Quaternion.IDENTITY end
end
function Visuals:Update(dt,speed,steer,bikeX,bikeY,bikeZ,bikeYaw)
    if self.disposed then return end
    self.bikeNode.position=V(bikeX,bikeY,bikeZ); self.bikeNode.rotation=Quaternion(0,bikeYaw,0)
    if self.mounted then
        local target=steer*math.min(1,math.abs(speed)/(35/3.6))*10
        self.lean=self.lean+(target-self.lean)*(1-math.exp(-dt*10))
        self.bikeVisual.rotation=Quaternion(0,0,self.lean)
        self.mountedRider:PoseRide(0)
    else
        local target=math.min(1,math.abs(speed)/1.8)
        self.gaitWeight=self.gaitWeight+(target-self.gaitWeight)*(1-math.exp(-dt*14))
        self.phase=(self.phase+math.abs(speed)*dt*math.pi*2/1.25)%(math.pi*2)
        self.walker:PoseWalk(self.phase,self.gaitWeight)
    end
end
function Visuals:Dispose()
    if self.disposed then return end
    self.disposed=true; self.mountedRider:Dispose(); self.walker:Dispose()
    self.bikeNode:Dispose(); self.walkNode:Dispose()
end
return Visuals
