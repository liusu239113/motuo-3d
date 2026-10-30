-- 住房规则唯一数据源：price 为未购入时的每晚房费；buyPriceCents 为永久产权的游戏固定价。
-- 购房价仅服务游戏成长节奏，不代表现实房价；旅舍始终按晚，不出售产权。
local Housing={}
---@class CareerHousing
---@field id string
---@field name string
---@field price integer 未拥有产权时每晚房费，整数分
---@field buyPriceCents? integer 永久买断游戏固定价，整数分；缺省不可购买
---@field energy integer
---@field point string
---@field x number
---@field z number
---@field width? number
---@field depth? number
---@field story? string
---@type CareerHousing[]
Housing.List={
    {id="bridge",name="桥下落脚点",price=0,energy=70,point="bridge",x=20,z=-68},
    {id="park",name="公园长椅",price=0,energy=75,point="park",x=108,z=-25},
    {id="hostel",name="青年旅舍床位",price=3000,energy=90,point="housing_hostel",x=-109,z=-43,width=7,depth=8,
        story="旅舍的灯还亮着。王二狗把头盔放进柜子，第一次不用听着桥上的车声入睡。\n30元一晚，不宽敞，但有一张干净的床。"},
    {id="room",name="独立出租屋",price=6500,buyPriceCents=8000000,energy=100,point="housing_room",x=-108,z=74,width=7,depth=9,
        story="门锁咔哒一声，身后终于安静了。小桌、热水壶，还有只属于自己的床。\n王二狗：明天照样跑单，但今晚，能睡个踏实觉。"},
    {id="apartment",name="阳光小公寓",price=15000,buyPriceCents=18000000,energy=100,point="housing_apartment",x=108,z=130,width=10,depth=11,
        story="阳光从窗边照进来。王二狗把旧头盔摆在玄关，没有换掉。\n表哥：住得越来越好了。\n王二狗：是啊，每一单挣来的，都算数。"},
}
---@param id string
---@return CareerHousing?
function Housing.Get(id)
    for _,item in ipairs(Housing.List) do if item.id==id then return item end end
end
function Housing.IsInterior(id)
    local item=Housing.Get(id)
    return item~=nil and item.width~=nil
end
-- 室内在独立可见层中以原点为中心搭建，不扩大城市范围、不让电动车跟随进屋。
function Housing.Spawn(id)
    local item=assert(Housing.Get(id))
    return 0,-(item.depth or 8)/2+1.3
end
function Housing.Bed(id)
    local item=assert(Housing.Get(id))
    return -(item.width or 7)/2+2.5,1.4
end
function Housing.Exit(id)
    local item=assert(Housing.Get(id))
    return 0,-(item.depth or 8)/2+.55
end
return Housing
