-- 独立便服路人：四套已有真实骨骼模型，复用骑手库的两段IK，不复制主角外卖服。
local Rig=require("Career.Rig")
local Walk=require("Career.LocalWalk")
---@class CareerPedestrians
---@field Paths number[][]
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
    {root="model/e440d08e-5b0d-55ae-b368-2d2da9e21122/",stem="rig-1-f4b048bc-2e56-4901-931a-f07ef5a695d2",suffix="3c49bff3-7579-4f0c-8bdd-13f3497da040",height=1.68,name="黑衣街坊"},
    {root="model/b2849c2afd734d59aaf285fcb69b2b1a/",stem="rig-1-e41d7bfb-0916-49c9-bbcf-cb2d5f522d14",suffix="f6f61c31-14b2-4a13-a6ed-039b59564bd7",height=1.82,name="黄夹克街坊",
        normal="model/b2849c2afd734d59aaf285fcb69b2b1a/Textures/rig-1-e41d7bfb-0916-49c9-bbcf-cb2d5f522d14_00_N.png"},
}
-- 供外区交通/现场联系人复用同两套便服资源；老街8人路径与步态独立保持。
Pedestrians.Specs=specs
Pedestrians.Resources,Pedestrians.ResourceTypes={},{}
for _,s in ipairs(specs) do
    s.model=s.root.."Meshes/"..s.stem..".mdl"
    s.material=s.root.."Materials/"..s.stem.."_00_tripo_material_"..s.suffix..".xml"
    s.diffuse=s.root.."Textures/"..s.stem.."_00_D.jpg"
    s.normal=s.normal or s.root.."Textures/"..s.stem.."_00_N.jpg"
    for path,kind in pairs({[s.model]="Model",[s.material]="Material",[s.diffuse]="Texture2D",[s.normal]="Texture2D"}) do
        Pedestrians.Resources[#Pedestrians.Resources+1]=path; Pedestrians.ResourceTypes[path]=kind
    end
end
-- 只在独立人行道段往返，距路口至少18m，不横穿机动车道，不挤占店门。
local paths={
    {-82,-8.7,-38,-8.7},{-80,8.7,-24,8.7},{18,-7.7,74,-7.7},{22,8.7,77,8.7},
    {-82,91.3,-25,91.3},{22,108.7,76,108.7},{-106.8,25,-106.8,60},{91.3,20,91.3,65},
}
-- 第3条向道路侧退1m避开原有充电桩(24,-9)，仍在[-12,-6]人行道内。
-- 第7条x=-106.8避开百货旧楼右边缘-107.85，扣除r=.32仍有.73m间隙；不出[-112,-106]步道。
-- 导出同源线路供碰撞验收读取，其余六条保持原样。
Pedestrians.Paths=paths
function Pedestrians.New(root,city)
    local self=setmetatable({},Pedestrians)
    self:Init(root,city)
    return self
end
function Pedestrians:Init(root,city)
    self.city=city
    self.root=root
    self.disposed=false
    self.poseTime=0
    self.people={}
    for i,p in ipairs(paths) do
        local node=root:CreateChild("老街行人"..i)
        local rig=Rig.New(node,specs[(i-1)%#specs+1])
        rig.ground=city
        rig.model.drawDistance=85; rig.model.shadowDistance=30
        local length=math.sqrt((p[3]-p[1])^2+(p[4]-p[2])^2)
        local person={node=node,rig=rig,path=p,length=length,s=length*(i%3)/3,direction=i%2==0 and 1 or -1,phase=i,gaitWeight=0,poseElapsed=(i%4)*.0125,speed=.9+(i%3)*.12,x=0,z=0,radius=.32}
        -- Corridor stays on the original sidewalk, including the off-centre paths 3/7.
        local low,high=-2.3,2.3
        if i==3 then low,high=-2.3,1.2 end
        if i==7 then low,high=-.4,2.3 end
        person.minOffset,person.maxOffset=low,high
        self.people[#self.people+1]=person
        self:Place(person)
        Walk.Reset(person)
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
    local traffic=self.city.traffic
    if self.disposed or self.city.space~="city" or dt<=0 or dt~=dt or dt==math.huge
        or traffic and (traffic.disposed or not traffic.active or traffic.nearOld==false) then return end
    dt=math.min(dt,.25)
    -- 行人逻辑按15Hz累计推进：位置仍按真实时间前进，只是碰撞扫掠次数减少到约1/4。
    -- 骨骼姿态本来就有分频，降低逻辑频率不影响可见步态。
    self.stepAccum=(self.stepAccum or 0)+dt
    if self.stepAccum<1/15 then return end
    dt,self.stepAccum=self.stepAccum,0
    blockers=blockers or {}
    local viewer=blockers[1]
    local outer=traffic and traffic.outer
    local groups={self.people,outer and outer.people or {}}
    local cars={traffic and traffic.cars or {},outer and outer.cars or {}}
    for _,p in ipairs(self.people) do
        local moved=Walk.Advance(self.city,p,dt,blockers,groups,cars)
        if #p.localWalk.points==0 and (p.s<=.00001 or p.s>=p.length-.00001) then
            p.direction=p.s<=.00001 and 1 or -1
        end
        local target=moved>.0001 and .8 or 0
        p.gaitWeight=p.gaitWeight+(target-p.gaitWeight)*(1-math.exp(-dt*14))
        if target==0 and p.gaitWeight<.001 then p.gaitWeight=0 end
        p.phase=(p.phase+moved*2*math.pi/Rig.CycleLength(p.gaitWeight,0))%(math.pi*2)
        p.node.position=Vector3(p.x,self.city:Surface(p.x,p.z),p.z)
        p.node.rotation=Quaternion(0,p.yaw or 0,0)
        -- 移动/碰撞每帧保持原精度；只有昂贵的骨骼与鞋底求解按距离分频，各人错峰。
        p.poseElapsed=math.min(.3,(p.poseElapsed or 0)+dt)
        local distance=viewer and (p.x-viewer.x)^2+(p.z-viewer.z)^2 or 0
        local period=distance<22^2 and .05 or distance<45^2 and .1 or .25
        if distance<85^2 and p.poseElapsed>=period then
            p.rig:PoseWalk(p.phase,p.gaitWeight)
            p.poseElapsed=p.poseElapsed%period
        end
    end
end
function Pedestrians:Dispose()
    if self.disposed then return end
    self.disposed=true
    for _,p in ipairs(self.people) do p.rig:Dispose(); p.node:Dispose() end
    self.people={}
end
return Pedestrians
