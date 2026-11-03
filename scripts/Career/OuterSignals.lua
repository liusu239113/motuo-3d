-- 外区仅12个特色区中心路口受控；不是全城路口信号化。
-- 基于scaffold-3d-scene的独立内容所有权，复用CityDetails.Bar与老街灯芯材质。
-- 不订阅事件、不改city.details/World.Roads；逻辑不依赖流式视觉节点是否存在。
local World=require("Career.WorldData")
local Details=require("Career.CityDetails")
local Parts=require("Parts")

---@class OuterSignalJunction
---@field id string
---@field x number
---@field z number
---@field nsWidth number
---@field ewWidth number
---@field nsSidewalk number
---@field ewSidewalk number
---@field offset number
---@class OuterSignalHead
---@field axis string
---@field lenses table<string, StaticModel>
---@class OuterSignalVisual
---@field root Node
---@field heads OuterSignalHead[]
---@field phase string
---@class OuterSignalSystem
---@field city CareerCity
---@field root Node
---@field visuals table<string, OuterSignalVisual>
---@field ownedMaterials Material[]
---@field dark Material
---@field off Material
---@field colors table<string, Material>
---@field cylinders table<string, Model>
---@field time number
---@field disposed boolean
---@field visible boolean
---@field loaded number
---@field unloaded number
---@field StopGap fun(self:OuterSignalSystem,route:table,distance:number,length:number):number
---@field Gap fun(self:OuterSignalSystem,car:OuterTrafficCar,others:OuterTrafficCar[]):number
---@field Hint fun(self:OuterSignalSystem,x:number,z:number,yaw:number,seconds?:number):string?
---@field SetTime fun(self:OuterSignalSystem,seconds:number)
---@field Update fun(self:OuterSignalSystem,seconds:number,x:number,z:number,enabled:boolean)
---@field Stats fun(self:OuterSignalSystem):table
---@field Dispose fun(self:OuterSignalSystem)
---@field Load fun(self:OuterSignalSystem,junction:OuterSignalJunction)
---@field Unload fun(self:OuterSignalSystem,id:string)
---@field ApplyPhase fun(self:OuterSignalSystem,visual:OuterSignalVisual,junction:OuterSignalJunction)
local Signals={}
Signals.__index=Signals
Signals.GREEN,Signals.YELLOW,Signals.ALL_RED=16,3,2
Signals.HALF_CYCLE,Signals.CYCLE=21,42
Signals.LOAD_DISTANCE,Signals.UNLOAD_DISTANCE=450,650
Signals.LINE_OFFSET,Signals.LINE_HALF,Signals.BUMPER_MARGIN=5.6,.15,.20
Signals.EPSILON=.00001
---@type OuterSignalJunction[]
Signals.Junctions={}
---@type table<number, OuterSignalJunction>
local junctionByPosition={}
local function key(x,z) return x*131072+z end

-- 区域设计（俯视，米；hx=NS最大半宽，hz=EW最大半宽）：
--           P [灯杆/底座]       NS车道       [灯杆] P
--           | 在步道外 .8m |  <-  |  -> | 在步道外 .8m |
-- EW步道 ===+=============+     |     +=============+===
-- EW车道 ------------------ 交叉冲突盒 -------------------
--           停止白线中心距交点=异向半宽+5.6（WorldStream同源规则）
--           车头距白线上游边缘再留 .20m，不以车心停车。
-- 四根杆的x/z同时越过相应道路半宽+完整4m步道+.8m；底座半宽.2m。
-- 灯面朝向对应来车；无路面立柱、无人行带障碍，不增加新碰撞域。
-- 红/黄/全红禁止新增入场；车头真正越线后允许清空；刚好贴线仍须等灯。
-- 绿灯先让异向已越线车辆清空，再由原有OBB/SAT兜底；掉头弧不投影为直行。

-- 同轴主干/支路重叠取最大宽度/步道，包含在中心结束的环路。
-- 是否具备穿过中心的道路单独判断，不能为排除T口而漏掉端点主干的实际路宽。
local function dimensions(x,z,axis)
    local width,sidewalk,through=0,0,false
    for _,r in ipairs(World.Roads) do
        local ns=r.x1==r.x2
        local onAxis=axis=="ns" and ns and r.x1==x or axis=="ew" and not ns and r.z1==r.z2 and r.z1==z
        local along=axis=="ns" and z or x
        local lo=axis=="ns" and math.min(r.z1,r.z2) or math.min(r.x1,r.x2)
        local hi=axis=="ns" and math.max(r.z1,r.z2) or math.max(r.x1,r.x2)
        if not r.old and onAxis and along>=lo and along<=hi then
            width=math.max(width,r.width); sidewalk=math.max(sidewalk,r.sidewalk or 4)
            through=through or (along>lo+24 and along<hi-24)
        end
    end
    return through and width or 0,sidewalk
end
for _,d in ipairs(World.Districts) do
    local nw,ns=dimensions(d.x,d.z,"ns")
    local ew,es=dimensions(d.x,d.z,"ew")
    assert(nw>0 and ew>0 and not World.IsOld(d.x,d.z),"外区中心缺少双向共享道路")
    local hash=0
    for i=1,#d.id do hash=(hash*33+d.id:byte(i))%65521 end
    ---@type OuterSignalJunction
    local j={id=d.id,x=d.x,z=d.z,nsWidth=nw,ewWidth=ew,nsSidewalk=ns,ewSidewalk=es,offset=hash%42}
    Signals.Junctions[#Signals.Junctions+1]=j
    junctionByPosition[key(j.x,j.z)]=j
end

---@param x number
---@param z number
---@return OuterSignalJunction?
function Signals.Find(x,z) return junctionByPosition[key(x,z)] end

-- 纯函数、固定ID相位偏移，不使用随机数/墙钟，不跟随节点加载重新起相位。
---@param seconds number
---@param axis string
---@param junction OuterSignalJunction
---@return string
function Signals.Signal(seconds,axis,junction)
    local t=(seconds+junction.offset+(axis=="ew" and Signals.HALF_CYCLE or 0))%Signals.CYCLE
    return t<Signals.GREEN and "green" or t<Signals.GREEN+Signals.YELLOW and "yellow" or "red"
end
---@param junction OuterSignalJunction
---@param axis string
---@return number
function Signals.StopOffset(junction,axis)
    local half=axis=="ns" and junction.ewWidth/2 or junction.nsWidth/2
    return half+Signals.LINE_OFFSET+Signals.LINE_HALF+Signals.BUMPER_MARGIN
end

-- 掉头安全域（沿道路，米）：
--   白线 | 停线余量 | < 车身外包圆R > (半圆轨迹最前端) -- radius -- 掉头圆心
--   start/finish是圆心，不是弧的最远点；整车OBB始终落在半径hypot(L/2,W/2)内。
-- 端点落入中心两侧禁掉头区时只向路线内部裁剪，绝不延长到原道路之外。
-- 贯穿中心且两端足够远的路线不变；过短/反向的结果由Scan拒绝，不把弧当直行放行。
---@param route table
---@param length number 最大车长
---@param width number 最大车宽
---@return number,number
function Signals.TrimTurns(route,length,width)
    local start,finish=route.start,route.finish
    local bodyRadius=math.sqrt((length/2)^2+(width/2)^2)
    for _,j in ipairs(Signals.Junctions) do
        local across=route.axis=="ns" and j.x or j.z
        if math.abs(route.road-across)<.01 then
            local cross=route.axis=="ns" and j.z or j.x
            local clearance=Signals.StopOffset(j,route.axis)+route.radius+bodyRadius
            if math.abs(start-cross)<clearance then start=cross+clearance end
            if math.abs(finish-cross)<clearance then finish=cross-clearance end
        end
    end
    return start,finish
end

-- 返回车头到上游停车目标的有符号距离；负值含.20m余量区，
-- 只有超过该余量、真正越过白线上游边缘才算已入场。nil表示非本路口直行。
---@param junction OuterSignalJunction
---@param route table
---@param distance number
---@param length number
---@return number?
function Signals.Approach(junction,route,distance,length)
    if route.axis~="ns" and route.axis~="ew" then return nil end
    local across=route.axis=="ns" and junction.x or junction.z
    local cross=route.axis=="ns" and junction.z or junction.x
    if math.abs(route.road-across)>.01 or cross<route.start or cross>route.finish then return nil end
    local straight=route.finish-route.start
    local arc=math.pi*route.radius
    local p=distance%(2*straight+2*arc)
    local sign,along=1,route.start+p
    if p>=straight+arc and p<2*straight+arc then
        sign,along=-1,route.finish-(p-straight-arc)
    elseif p>=straight then return nil end
    return sign*(cross-along)-Signals.StopOffset(junction,route.axis)-length/2
end

---@param route table
---@param distance number
---@param length number
---@return number
function Signals:StopGap(route,distance,length)
    local best=math.huge
    for _,j in ipairs(Signals.Junctions) do
        local gap=Signals.Approach(j,route,distance,length)
        if gap and gap>=-Signals.BUMPER_MARGIN-Signals.EPSILON and Signals.Signal(self.time,route.axis,j)~="green" then
            best=math.min(best,math.max(0,gap))
        end
    end
    return best
end

local function crossingBusy(j,car,others)
    for _,other in ipairs(others) do
        if other~=car and other.route.axis~=car.route.axis then
            -- 精确OBB在冲突AABB上的投影；长车的尾部未离开也算占用。
            local a=math.rad(other.yaw)
            local ex=math.abs(math.sin(a))*other.length/2+math.abs(math.cos(a))*other.width/2
            local ez=math.abs(math.cos(a))*other.length/2+math.abs(math.sin(a))*other.width/2
            if math.abs(other.x-j.x)<j.nsWidth/2+ex+.35 and math.abs(other.z-j.z)<j.ewWidth/2+ez+.35 then return true end
            local gap=Signals.Approach(j,other.route,other.s,other.length)
            -- 从停止线到冲突盒之间也有清空权；已远离的车不能永久锁住路口。
            if gap and gap<-Signals.BUMPER_MARGIN-Signals.EPSILON then
                local cross=other.route.axis=="ns" and j.z or j.x
                local along=other.route.axis=="ns" and other.z or other.x
                local forward=(cross-along)*(other.route.axis=="ns" and math.cos(a) or math.sin(a))
                local half=other.route.axis=="ns" and j.ewWidth/2 or j.nsWidth/2
                if forward+other.length/2+half+.35>0 then return true end
            end
        end
    end
    return false
end
---@param car OuterTrafficCar
---@param others OuterTrafficCar[]
---@return number
function Signals:Gap(car,others)
    local best=self:StopGap(car.route,car.s,car.length)
    for _,j in ipairs(Signals.Junctions) do
        local gap=Signals.Approach(j,car.route,car.s,car.length)
        if gap and gap>=-Signals.BUMPER_MARGIN-Signals.EPSILON and crossingBusy(j,car,others) then
            best=math.min(best,math.max(0,gap))
        end
    end
    return best
end

---@param x number
---@param z number
---@param yaw number
---@param seconds? number 默认当前外区模拟时钟
---@return string?
function Signals:Hint(x,z,yaw,seconds)
    if self.disposed or self.city.space~="city" then return nil end
    local a=math.rad(yaw)
    local axis=math.abs(math.cos(a))>=.7 and "ns" or "ew"
    local best=math.huge
    ---@type OuterSignalJunction?
    local chosen=nil
    for _,j in ipairs(Signals.Junctions) do
        local across=axis=="ns" and math.abs(x-j.x) or math.abs(z-j.z)
        local width=axis=="ns" and j.nsWidth or j.ewWidth
        local forward=axis=="ns" and (j.z-z)*math.cos(a) or (j.x-x)*math.sin(a)
        if across<width/2 and forward>Signals.StopOffset(j,axis)-2 and forward<70 and forward<best then
            chosen,best=j,forward
        end
    end
    if not chosen then return nil end
    local color=Signals.Signal(seconds or self.time,axis,chosen)
    return color=="green" and "外区中心路口绿灯 · 留意正在清空的车辆"
        or color=="yellow" and "外区中心路口黄灯 · 在白色停止线前等候"
        or "外区中心路口红灯 · 在白色停止线前等候"
end

---@param owner table City或持有city的外区交通实例
---@return OuterSignalSystem
function Signals.New(owner)
    local self=setmetatable({},Signals)
    self:Init(owner)
    return self
end
function Signals:Init(owner)
    self.city=owner.city or owner
    self.root=self.city.root:CreateChild("外区12中心路口信号")
    self.root:SetEnabledRecursive(false)
    self.visuals={}
    self.cylinders={}
    self.time,self.loaded,self.unloaded=0,0,0
    self.visible,self.disposed=false,false
    self.ownedMaterials={}
    -- 借用现有灯材质，绝不修改/Dispose老街材质。缺省只为独立City夹具建自己的材质。
    local legacy=self.city.signals
    if legacy then self.dark,self.off,self.colors=legacy.dark,legacy.off,legacy.colors
    else
        self.dark=Parts.Material(.025,.032,.038,.65,.15)
        self.off=Parts.Material(.045,.055,.05,.7)
        self.colors={red=Parts.Material(.95,.025,.015,.35,0,2),yellow=Parts.Material(1,.58,.025,.35,0,2),green=Parts.Material(.025,.9,.22,.35,0,2)}
        self.ownedMaterials={self.dark,self.off,self.colors.red,self.colors.yellow,self.colors.green}
    end
end

---@param junction OuterSignalJunction
---@param arm integer 1..4: 南北/东西来车朝向
---@return number,number,number,string
function Signals.PolePose(junction,arm)
    local x=junction.nsWidth/2+junction.nsSidewalk+.8
    local z=junction.ewWidth/2+junction.ewSidewalk+.8
    if arm==1 then return junction.x-x,junction.z+z,0,"ns" end
    if arm==2 then return junction.x+x,junction.z-z,180,"ns" end
    if arm==3 then return junction.x+x,junction.z+z,90,"ew" end
    return junction.x-x,junction.z-z,270,"ew"
end
---@param visual OuterSignalVisual
---@param junction OuterSignalJunction
function Signals:ApplyPhase(visual,junction)
    local ns,ew=Signals.Signal(self.time,"ns",junction),Signals.Signal(self.time,"ew",junction)
    local phase=ns..ew
    if visual.phase==phase then return end
    visual.phase=phase
    for _,head in ipairs(visual.heads) do
        local selected=head.axis=="ns" and ns or ew
        for color,lens in pairs(head.lenses) do lens.material=color==selected and self.colors[color] or self.off end
    end
end
---@param junction OuterSignalJunction
function Signals:Load(junction)
    if self.disposed or self.visuals[junction.id] then return end
    local root=self.root:CreateChild("OuterSignal_"..junction.id)
    -- 独立Details事务：不接触city.details已经Commit的批次/Surface记录。
    local d=Details.New(root,{metal=self.dark})
    ---@type OuterSignalVisual
    local visual={root=root,heads={},phase=""}
    for arm=1,4 do
        local x,z,yaw,axis=Signals.PolePose(junction,arm)
        local y=World.Surface(x,z,"vehicle",0)
        d:Bar("metal",Vector3(x,y,z),Vector3(x,y+4.35,z),.14)
        local head=root:CreateChild("外区路侧信号灯")
        head.position=Vector3(x,y,z); head.rotation=Quaternion(0,yaw,0)
        Parts.Add(head,"路外底座","Box",self.dark,Vector3(0,.25,0),Vector3(.4,.5,.4))
        Parts.Add(head,"信号灯壳","Box",self.dark,Vector3(0,3.7,0),Vector3(.48,1.28,.28))
        ---@type table<string, StaticModel>
        local lenses={}
        for i,color in ipairs({"red","yellow","green"}) do
            local cy=4.08-(i-1)*.38
            Parts.Add(head,"遮光眉","Box",self.dark,Vector3(0,cy+.16,.18),Vector3(.47,.045,.30))
            local lens=Parts.Add(head,color,"Sphere",self.off,Vector3(0,cy,.17),Vector3(.27,.27,.085),nil,false)
            lenses[color]=lens:GetComponent("StaticModel")
        end
        visual.heads[#visual.heads+1]={axis=axis,lenses=lenses}
    end
    -- Bar使用的程序圆柱须与节点一起持有，卸载先释放节点再释放模型。
    self.visuals[junction.id]=visual
    self.cylinders[junction.id]=assert(d.shapes.cylinder)
    self.loaded=self.loaded+1
    root:SetEnabledRecursive(self.visible and self.city.space=="city")
    self:ApplyPhase(visual,junction)
end
---@param id string
function Signals:Unload(id)
    local visual=self.visuals[id]
    if not visual then return end
    visual.root:Dispose(); self.visuals[id]=nil
    self.cylinders[id]:Dispose(); self.cylinders[id]=nil
    self.unloaded=self.unloaded+1
end
---@param seconds number
function Signals:SetTime(seconds)
    if self.disposed then return end
    self.time=seconds
    for _,j in ipairs(Signals.Junctions) do
        local visual=self.visuals[j.id]
        if visual then self:ApplyPhase(visual,j) end
    end
end
---@param seconds number 绝对模拟时钟，暂停/室内不调用，不补追墙钟
---@param x number
---@param z number
---@param enabled boolean
function Signals:Update(seconds,x,z,enabled)
    if self.disposed then return end
    self.visible=enabled and self.city.space=="city"
    if self.root:IsEnabled()~=self.visible then self.root:SetEnabledRecursive(self.visible) end
    for _,j in ipairs(Signals.Junctions) do
        local d2=(x-j.x)^2+(z-j.z)^2
        if d2>Signals.UNLOAD_DISTANCE^2 then self:Unload(j.id) end
        if self.visible and d2<=Signals.LOAD_DISTANCE^2 then self:Load(j) end
    end
    self:SetTime(seconds)
end
function Signals:Stats()
    local active=0
    for _ in pairs(self.visuals) do active=active+1 end
    return {junctions=#Signals.Junctions,active=active,loaded=self.loaded,unloaded=self.unloaded,
        time=self.time,visible=self.visible,disposed=self.disposed,coverage="district-centres-only"}
end
function Signals:Dispose()
    if self.disposed then return end
    for _,j in ipairs(Signals.Junctions) do self:Unload(j.id) end
    self.root:Dispose()
    for _,m in ipairs(self.ownedMaterials) do m:Dispose() end
    self.ownedMaterials={}; self.visible=false; self.disposed=true
end
return Signals
