-- 独立便服路人：使用两套真实骨骼模型，复用骑手库的两段IK，不复制主角外卖服。
local Rig=require("Career.Rig")
local Pedestrians={}
Pedestrians.__index=Pedestrians
---@class CityPedestrianAsset
---@field root string
---@field stem string
---@field suffix string
---@field height number
---@field name string
---@field model? string
---@field material? string
---@field diffuse? string
---@field normal? string
local PedestrianAssetType={}

---@type CityPedestrianAsset[]
local specs={
    {root="model/8e64bae4-5b82-5be6-8c95-b000fb191bdb/",stem="rig-1-99f19e84-13a1-418a-b205-f5728233dcad",suffix="684fb712-5dcb-4fcf-8b05-c8b855c2b5fd",height=1.73,name="羽绒服路人"},
    {root="model/c993b86d-09f2-5573-a033-4568fad5ce67/",stem="rig-1-6e1ff8c0-1bfd-41eb-992e-03838035c444",suffix="2c590ce0-b4bb-4afe-8357-411942174cd6",height=1.79,name="夹克路人"},
}
-- 供外区交通/现场联系人复用同两套便服资源；老街8人路径与步态独立保持。
Pedestrians.Specs=specs
Pedestrians.Resources,Pedestrians.ResourceTypes={},{}
for _,s in ipairs(specs) do
    s.model=s.root.."Meshes/"..s.stem..".mdl"
    s.material=s.root.."Materials/"..s.stem.."_00_tripo_material_"..s.suffix..".xml"
    s.diffuse=s.root.."Textures/"..s.stem.."_00_D.jpg"
    s.normal=s.root.."Textures/"..s.stem.."_00_N.jpg"
    for path,kind in pairs({[s.model]="Model",[s.material]="Material",[s.diffuse]="Texture2D",[s.normal]="Texture2D"}) do
        Pedestrians.Resources[#Pedestrians.Resources+1]=path; Pedestrians.ResourceTypes[path]=kind
    end
end
-- 只在独立人行道段往返，距路口至少18m，不横穿机动车道，不挤占店门。
local paths={
    {-82,-8.7,-38,-8.7},{-80,8.7,-24,8.7},{18,-8.7,74,-8.7},{22,8.7,77,8.7},
    {-82,91.3,-25,91.3},{22,108.7,76,108.7},{-108.7,25,-108.7,60},{91.3,20,91.3,65},
}
function Pedestrians.New(root,city)
    local self=setmetatable({},Pedestrians)
    self:Init(root,city)
    return self
end
function Pedestrians:Init(root,city)
    self.city=city
    self.poseTime=0
    self.people={}
    for i,p in ipairs(paths) do
        local node=root:CreateChild("老街行人"..i)
        local rig=Rig.New(node,specs[(i-1)%#specs+1])
        rig.ground=city
        rig.model.drawDistance=85; rig.model.shadowDistance=30
        local length=math.sqrt((p[3]-p[1])^2+(p[4]-p[2])^2)
        local person={node=node,rig=rig,path=p,length=length,s=length*(i%3)/3,direction=i%2==0 and 1 or -1,phase=i,gaitWeight=0,speed=.9+(i%3)*.12,x=0,z=0,radius=.32}
        self.people[#self.people+1]=person
        self:Place(person)
        rig:PoseWalk(person.phase,0)
    end
end
function Pedestrians:Place(p)
    local f=p.s/p.length
    p.x,p.z=p.path[1]+(p.path[3]-p.path[1])*f,p.path[2]+(p.path[4]-p.path[2])*f
    p.node.position=Vector3(p.x,self.city:Surface(p.x,p.z),p.z)
    p.node.rotation=Quaternion(0,math.deg(math.atan((p.path[3]-p.path[1])*p.direction,(p.path[4]-p.path[2])*p.direction)),0)
end
function Pedestrians:Update(dt,blockers)
    self.poseTime=self.poseTime+dt
    local poseReady=self.poseTime>=1/20
    if poseReady then self.poseTime=self.poseTime%(1/20) end
    local viewer=blockers[1]
    for _,p in ipairs(self.people) do
        local old=p.s
        local candidate=p.s+p.direction*p.speed*dt
        if candidate<0 or candidate>p.length then p.direction=-p.direction; candidate=math.max(0,math.min(p.length,candidate)) end
        local f=candidate/p.length
        local x,z=p.path[1]+(p.path[3]-p.path[1])*f,p.path[2]+(p.path[4]-p.path[2])*f
        local free=self.city:StaticFree(x,z,p.radius)
        for _,b in ipairs(blockers) do if (x-b.x)^2+(z-b.z)^2<(p.radius+b.radius+.45)^2 then free=false end end
        for _,other in ipairs(self.people) do if other~=p and (x-other.x)^2+(z-other.z)^2<.85^2 then free=false end end
        if free then p.s=candidate end
        local moved=math.abs(p.s-old)
        local target=moved>.0001 and .8 or 0
        p.gaitWeight=p.gaitWeight+(target-p.gaitWeight)*(1-math.exp(-dt*14))
        if target==0 and p.gaitWeight<.001 then p.gaitWeight=0 end
        p.phase=(p.phase+moved*2*math.pi/Rig.CycleLength(p.gaitWeight,0))%(math.pi*2)
        self:Place(p)
        -- 位移与碰撞每帧更新；85m绘制距离之外不做IK，近处骨骼限20Hz。
        if poseReady and (p.x-viewer.x)^2+(p.z-viewer.z)^2<85^2 then
            p.rig:PoseWalk(p.phase,p.gaitWeight)
        end
    end
end
return Pedestrians
