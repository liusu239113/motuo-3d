-- 联系人驻点：真实便服骨骼与名字牌，任务操作仍统一经过现场距离验证。
local Rig=require("Career.Rig")
local Pedestrians=require("Career.Pedestrians")
local Details=require("Career.CityDetails")
---@class CareerContacts
---@field root Node
---@field people table[]
local Contacts={}
Contacts.__index=Contacts
Contacts.List={
    {id="station",name="老街站长",point="breakfast",x=-26.8,z=-8,yaw=90},
    {id="cousin",name="表哥",point="bridge",x=-1.8,z=-70,yaw=90},
    {id="mechanic",name="车行师傅",point="dealer",x=108,z=81.8,yaw=180},
}
function Contacts.New(city)
    local self=setmetatable({},Contacts)
    self.root=city.root:CreateChild("老街驻点联系人")
    self.people={}
    local details=Details.New(self.root,city.mats)
    for index,item in ipairs(Contacts.List) do
        local node=self.root:CreateChild(item.name)
        node.position=Vector3(item.x,city:Surface(item.x,item.z),item.z)
        node.rotation=Quaternion(0,item.yaw,0)
        local rig=Rig.New(node,Pedestrians.Specs[1+(index-1)%#Pedestrians.Specs])
        rig.ground=city; rig.model.drawDistance=85; rig.model.shadowDistance=30
        rig:PoseWalk(0,0)
        self.people[#self.people+1]={rig=rig,node=node,id=item.id}
        city:Obstacle(item.x,item.z,.5,.5)
        details:Sign(item.name.." · 交互",item.x,2.05,item.z,0,.26)
    end
    details:Finish()
    print("[街区联系人] 站长、表哥、车行师傅已到驻点；复用便服资产，不冒充三套新人物美术")
    return self
end
function Contacts:Dispose()
    for _,person in ipairs(self.people) do person.rig:Dispose() end
    self.root:Dispose()
end
return Contacts
