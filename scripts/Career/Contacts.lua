-- 联系人驻点与局部街坊：真实便服骨骼复用，不新增人物美术/clip/事务/UI。
local Life=require("Career.StreetLife")
---@class CareerContacts
---@field root Node
---@field city CareerCity
---@field life CareerStreetLife
---@field people CareerStreetPerson[]
---@field disposed boolean
---@field Get fun(self:CareerContacts,id:string):CareerStreetPerson?
---@field Nearest fun(self:CareerContacts,actor:CareerActor|table,radius?:number):CareerStreetPerson?,number
---@field Update fun(self:CareerContacts,dt:number,actor:CareerActor|table,hour?:number,enabled?:boolean)
---@field Dispose fun(self:CareerContacts)
local Contacts={}
Contacts.__index=Contacts
-- 驻足包络在原POI圆和旧路线之外；服务授权仍由Session/Delivery核对原point。
---@type CareerStreetPersonSpec[]
Contacts.List={
    {id="station",name="老街站长",point="breakfast",x=-28.6,z=-10.9,yaw=60,role="waiting",asset=1},
    {id="cousin",name="表哥",point="bridge",x=-9.9,z=-73.3,yaw=60,role="bridge",asset=2},
    {id="mechanic",name="车行师傅",point="dealer",x=110.5,z=83.2,yaw=-90,role="waiting",asset=1},
    {id="breakfast_owner",name="早餐店老板",point="breakfast",x=-22,z=-11.1,yaw=0,role="merchant",asset=2},
}
---@param city CareerCity
---@return CareerContacts
function Contacts.New(city)
    local self=setmetatable({},Contacts)
    self:Init(city)
    return self
end
function Contacts:Init(city)
    self.city=city
    self.root=city.root:CreateChild("老街驻点联系人")
    self.disposed=false
    local specs={}
    for _,item in ipairs(Contacts.List) do specs[#specs+1]=item end
    for _,item in ipairs(Life.Residents) do specs[#specs+1]=item end
    self.life=Life.New(city,self.root,specs)
    self.people=self.life.people
    local font=assert(cache:GetResource("Font","Fonts/MiSans-Regular.ttf"))
    for _,item in ipairs(Contacts.List) do
        local p=assert(self:Get(item.id))
        local name=p.node:CreateChild("联系人名字牌")
        name.position=Vector3(0,2.05,0); name:SetScale(.48)
        local text=name:CreateComponent("Text3D")
        assert(text:SetFont(font,64))
        text.text=item.name; text:SetAlignment(HA_CENTER,VA_CENTER)
        text.textAlignment=HA_CENTER; text.color=Color(.92,.89,.77)
        text.faceCameraMode=FC_ROTATE_XYZ; text.drawDistance=35; text.castShadows=false
    end
    print("[街区生活] 4名联系人+4名驻足街坊；复用两套便服资源、程序化上肢轻动作，无新动作clip")
end
---@param id string
---@return CareerStreetPerson?
function Contacts:Get(id)
    if self.disposed then return nil end
    return self.life:Get(id)
end
---@param actor CareerActor|table
---@param radius? number 默认3m，候选查询不替代现场事务授权
---@return CareerStreetPerson?,number
function Contacts:Nearest(actor,radius) return self.life:Nearest(actor,radius) end
function Contacts:BeginGesture(id,kind,duration) return self.life:BeginGesture(id,kind,duration) end
function Contacts:Respond(id,kind) return self.life:Respond(id,kind) end
---@param dt number
---@param actor CareerActor|table
---@param hour? number
---@param enabled? boolean 手机/暂停false冻结；室内city.space自动隐藏
function Contacts:Update(dt,actor,hour,enabled)
    if self.disposed then return end
    self.life:Update(dt,actor,hour,enabled)
end
function Contacts:Dispose()
    if self.disposed then return end
    self.disposed=true
    self.life:Dispose(); self.root:Dispose()
    self.people={}
end
return Contacts
