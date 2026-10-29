-- 有界配送交接人物；沿用 scaffold-3d-character 的父节点/模型生命周期与 Career.StreetLife 的轻手势。
-- 只读订单快照与 City；不 require Store/Delivery、不订阅事件、不写档、不改路网/静态障碍。
-- 主线程：New(city) -> Sync(state.activeOrders)；每帧 Update(dt,actor,not blocking)。
-- 成功结算后、下一次 Sync 前 Respond(pointId,pickup)；这只是回应，不是结算授权或递物动画。
local Rig=require("Career.Rig")
local Pedestrians=require("Career.Pedestrians")
local Config=require("Career.Config")
local World=require("Career.WorldData")
local V=Vector3

---@alias CareerDeliveryPersonRole 'merchant'|'customer'
---@alias CareerDeliveryPersonSource 'pool'|'contact'
---@class CareerDeliveryPeopleOrder
---@field id string
---@field status string
---@field pickupId string
---@field dropoffId string
---@field route? CareerRoutePoint[] 只读取首末接近段，不修改存档订单/Config路线
local OrderType={}
---@class CareerDeliveryApproach
---@field x number 从marker指向来路的单位方向
---@field z number
---@field length number 保留至多4m接近通道
local ApproachType={}
---@class CareerDeliveryTarget
---@field pointId string
---@field role CareerDeliveryPersonRole 同点同时取送时customer优先，仍只占一槽
---@field source CareerDeliveryPersonSource contact绝不创建/借管既有人物
---@field contactId? string breakfast_owner / mechanic，由主线程转发contacts:Respond
---@field orderIds string[] 独立快照，不持有可写的订单对象
---@field approaches CareerDeliveryApproach[]
local TargetType={}
---@class CareerDeliveryPerson
---@field slot integer
---@field source CareerDeliveryPersonSource 池内恒为pool；contact目标只存在targets中
---@field node Node
---@field rig CareerRig
---@field x number
---@field z number
---@field y number
---@field yaw number 正面+Z，atan(dx,dz)，不额外反转共享Rig
---@field homeYaw number
---@field pointId string 空闲时为空串
---@field role CareerDeliveryPersonRole
---@field visible boolean 室内/90m外隐藏，不等同于active
---@field hold number 送达后的剩余活动秒数，0..6；不随重复Sync/Respond续期
---@field active boolean 当前订单仍需要该点；hold>0时可以false
---@field radius number .4米，仅通过IsFree提供动态碰撞
---@field orderIds string[]
---@field clock number 手机/暂停/远距不推进姿势时钟
---@field phase number
---@field poseElapsed number
---@field poseCount integer
---@field bindCount integer 只在目标或角色实际重绑时增加
---@field poseDirty boolean
---@field gesture string pickup / thanks / 空串；不是递物clip
---@field gestureTime number
---@field gestureDuration number
---@field gestureWeight number
local PersonType={}
---@class CareerDeliveryPersonSlot
---@field index integer
---@field person? CareerDeliveryPerson 惰性分配，最多4个真实Rig，之后原地复用
local SlotType={}
---@class CareerDeliveryPeopleStats
---@field capacity integer
---@field created integer 当前已分配Rig数，释放后0
---@field active integer
---@field held integer hold>0的占用人物数，可能同时active
---@field visible integer
---@field binds integer 累计重绑次数
---@field poses integer 累计IK提交次数
---@field targets integer 去重后的目标点数（含contact）
---@field external integer contact目标数
---@field unplaced integer 无安全站位的目标数
---@field overflow integer 超过4槽的目标数
---@field unplacedIds string[] 独立副本
---@field overflowIds string[] 独立副本
---@field disposed boolean
local StatsType={}
---@class CareerDeliveryPeople
---@field city CareerCity
---@field root Node
---@field slots CareerDeliveryPersonSlot[] 恒定4槽（Dispose后仍保留空槽，便于checks）
---@field people CareerDeliveryPerson[] 已创建的池人物；绝不克隆整城联系人
---@field byPoint table<string,CareerDeliveryPerson>
---@field targets CareerDeliveryTarget[] 按输入订单顺序去重点；既有联系人也在此报告
---@field orders CareerDeliveryPeopleOrder[] 独立最小快照；不读真实档
---@field approaches table<string,CareerDeliveryApproach[]>
---@field unplacedIds string[]
---@field overflowIds string[]
---@field binds integer
---@field poses integer
---@field disposed boolean
---@field enabled boolean
---@field pending boolean 室内Sync延后到返回城市时进行安全站位查询
---@field viewer? table 只保存坐标与停放包络，不保管actor生命周期
---@field syncKey string 订单id/status/point与space，不依赖profile revision或table identity
---@field retryKey string 8m观察者格变化才重试unplaced
local People={}
People.__index=People
People.CAPACITY=4
People.RADIUS=.4
People.MIN_DISTANCE=1.8
People.MAX_DISTANCE=2.3
People.HIDE_DISTANCE=90
People.NEAR_DISTANCE=22
People.HOLD_SECONDS=6
People.TURN_SPEED=65
-- 公共复用表仅作接线提示；不将远处常驻联系人强行挪至marker旁。
People.ContactIds={breakfast="breakfast_owner",dealer="mechanic"}
-- 与既有行人同源的资源声明，供主线程loader/preload复用；不修改共享资源表。
People.Resources,People.ResourceTypes={},{}
for _,path in ipairs(Pedestrians.Resources) do
    People.Resources[#People.Resources+1]=path
    People.ResourceTypes[path]=Pedestrians.ResourceTypes[path]
end

local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
local function wrap(yaw) return (yaw+180)%360-180 end
local function copyIds(ids)
    local result={}
    for _,id in ipairs(ids) do result[#result+1]=id end
    return result
end
---@param self CareerDeliveryPeople
---@param actor? CareerActor|table
local function rememberViewer(self,actor)
    if not actor or not finite(actor.x) or not finite(actor.z) then return end
    local radius=1.2
    if type(actor.VehicleRadius)=="function" then radius=math.max(radius,actor:VehicleRadius()) end
    self.viewer={x=actor.x,z=actor.z,mounted=actor.mounted,walkHeight=actor.walkHeight,
        bikeX=actor.bikeX,bikeZ=actor.bikeZ,vehicleRadius=radius}
end
---@param viewer? table
---@return string
local function retryCell(viewer)
    if not viewer then return "none" end
    return math.floor(viewer.x/8)..":"..math.floor(viewer.z/8)
end
---@param list CareerDeliveryApproach[]
---@param point CareerPoint
---@param neighbor? CareerRoutePoint
local function approach(list,point,neighbor)
    if not neighbor or not finite(neighbor.x) or not finite(neighbor.z) then return end
    local dx,dz=neighbor.x-point.x,neighbor.z-point.z
    local length=math.sqrt(dx*dx+dz*dz)
    if length<.001 then return end
    local x,z=dx/length,dz/length
    for _,a in ipairs(list) do if a.x*x+a.z*z>.999 then return end end
    list[#list+1]={x=x,z=z,length=math.min(4,length)}
end
---@param route? CareerRoutePoint[]
---@param pickup boolean
---@return CareerRoutePoint?
local function neighborFor(route,pickup)
    if not route or #route<2 then return nil end
    return pickup and route[2] or route[#route-1]
end
---@param p CareerDeliveryPerson
local function show(p,visible)
    if p.visible==visible and p.node.enabledSelf==visible then return end
    p.visible=visible
    p.node:SetEnabledRecursive(visible)
    p.rig.visible=visible
end

---@param city CareerCity 由调用者持有场景；New不会创建Scene或真实生涯档
---@return CareerDeliveryPeople
function People.New(city)
    local self=setmetatable({},People)
    self:Init(city)
    return self
end
---@param city CareerCity
function People:Init(city)
    self.city=city
    self.root=city.root:CreateChild("四槽配送交接人物")
    self.slots,self.people,self.byPoint={},{},{}
    self.targets,self.orders,self.approaches={},{},{}
    self.unplacedIds,self.overflowIds={},{}
    self.binds,self.poses=0,0
    self.disposed,self.enabled,self.pending=false,false,false
    self.syncKey,self.retryKey="",""
    for i=1,People.CAPACITY do self.slots[i]={index=i} end
    -- 所有配置模板的marker端接近通道均保留；不只顾眼前这一单，不改旧7模板。
    for _,template in ipairs(Config.orderTemplates) do
        for _,pickup in ipairs({true,false}) do
            local id=pickup and template.pickupId or template.dropoffId
            local point=Config.points[id]
            if point then
                local list=self.approaches[id] or {}
                approach(list,point,neighborFor(template.route,pickup))
                self.approaches[id]=list
            end
        end
    end
end

-- 碰撞/站位设计（俯视，单位米）：
--                     [真实建筑/树/静态街坊AABB]
--   候选圆r=.4  O       -> City:StaticFree逐候选检查，不改World.SetLegacy/obstacles
--                 1.2..2.3m
--   来路 ===== 宽1.1m接近通道 ===== [marker中心/1.5m方块]  原2m交互规则不变
-- 候选圆不能覆盖marker（中心至少1.8m），接近段留骑车r1.2+.4+.1m走廊。
-- POI->候选每<=.1m扫掠，防止隔着薄墙/楼角误选；地表中心+四向脚掌包络采样，
-- 不跨>.16m高差/悬空边缘，不用全局最高桥面把地面人物吸到桥上。
-- 人物圆相距>=.9m；静止无随机走动/穿楼退场。hold结束直接隐藏，不伪造走路动画。
-- 边界：恰好相切可通；无合格候选就报告unplaced，不调用FindFree跳到远处或穿墙兜底。
---@param target CareerDeliveryTarget
---@param x number
---@param z number
---@return boolean
function People:ChannelFree(target,x,z)
    local point=Config.points[target.pointId]
    if not point then return false end
    for _,p in ipairs(Config.pointList) do
        if (x-p.x)^2+(z-p.z)^2<1.8^2-.00001 then return false end
    end
    local dx,dz=x-point.x,z-point.z
    for _,a in ipairs(target.approaches) do
        local along=math.max(0,math.min(a.length,dx*a.x+dz*a.z))
        if (dx-a.x*along)^2+(dz-a.z*along)^2<1.7^2 then return false end
    end
    -- 静态free不等于人行安全：任何道路车道都留出自身圆与额外.2m路缘余量。
    for _,road in ipairs(World.Roads) do
        if x>=math.min(road.x1,road.x2)-road.width/2-1
            and x<=math.max(road.x1,road.x2)+road.width/2+1
            and z>=math.min(road.z1,road.z2)-road.width/2-1
            and z<=math.max(road.z1,road.z2)+road.width/2+1 then
            local vx,vz=road.x2-road.x1,road.z2-road.z1
            local u=math.max(0,math.min(1,((x-road.x1)*vx+(z-road.z1)*vz)/(vx*vx+vz*vz)))
            if (x-road.x1-vx*u)^2+(z-road.z1-vz*u)^2<(road.width/2+People.RADIUS+.2)^2 then return false end
        end
    end
    -- 不把新站位放进老街现有八条行人的固定线，避免静态池人物被来回穿过。
    for _,path in ipairs(Pedestrians.Paths) do
        local ax,az,bx,bz=assert(path[1]),assert(path[2]),assert(path[3]),assert(path[4])
        local vx,vz=bx-ax,bz-az
        local u=math.max(0,math.min(1,((x-ax)*vx+(z-az)*vz)/(vx*vx+vz*vz)))
        if (x-ax-vx*u)^2+(z-az-vz*u)^2<(.32+People.RADIUS+.1)^2 then return false end
    end
    return true
end
---@param x number
---@param z number
---@param ignore? CareerDeliveryPerson
---@return boolean
function People:PoolFree(x,z,ignore)
    for _,p in ipairs(self.people) do
        if p~=ignore and p.pointId~="" and (p.active or p.hold>0)
            and (x-p.x)^2+(z-p.z)^2<(People.RADIUS*2+.1)^2 then return false end
    end
    local viewer=self.viewer
    if viewer then
        local actorRadius=viewer.mounted and (viewer.vehicleRadius+.5) or .9
        if (x-viewer.x)^2+(z-viewer.z)^2<actorRadius^2 then return false end
        if finite(viewer.bikeX) and finite(viewer.bikeZ)
            and (x-viewer.bikeX)^2+(z-viewer.bikeZ)^2<(viewer.vehicleRadius+.5)^2 then return false end
    end
    return true
end
---@param target CareerDeliveryTarget
---@param ignore? CareerDeliveryPerson
---@return number?,number?,number?
function People:FindStand(target,ignore)
    if self.city.space~="city" then return nil end
    local point=Config.points[target.pointId]
    if not point then return nil end
    local baseY=self.city:WalkSurface(point.x,point.z,0)
    if not finite(baseY) then return nil end
    -- 每目标独立候选，不给全城预建NPC。优先来路两侧，次选斜侧与背侧。
    local first=target.approaches[1]
    local baseAngle=first and math.atan(first.x,first.z) or 0
    ---@type number[]
    local angles={90,-90,135,-135,45,-45,180,0}
    for i=0,31 do if i%4~=0 then angles[#angles+1]=i*11.25 end end
    for _,distance in ipairs({1.8,2.1,2.3}) do
        for _,degrees in ipairs(angles) do
            local angle=baseAngle+math.rad(degrees)
            local x,z=point.x+math.sin(angle)*distance,point.z+math.cos(angle)*distance
            if self:ChannelFree(target,x,z) and self:PoolFree(x,z,ignore)
                and self.city:StaticFree(x,z,People.RADIUS,"walk",baseY) then
                local y=self.city:WalkSurface(x,z,baseY)
                local free=finite(y) and math.abs(y-baseY)<=.16
                if free then
                    for _,o in ipairs({{.4,0},{-.4,0},{0,.4},{0,-.4}}) do
                        local sample=self.city:WalkSurface(x+o[1],z+o[2],y)
                        if not finite(sample) or math.abs(sample-y)>.16 then free=false; break end
                    end
                end
                if free then
                    local count=math.ceil(distance/.1)
                    for i=0,count do
                        local t=i/count
                        local sx,sz=point.x+(x-point.x)*t,point.z+(z-point.z)*t
                        local sy=self.city:WalkSurface(sx,sz,baseY)
                        if not finite(sy) or math.abs(sy-baseY)>.16
                            or not self.city:StaticFree(sx,sz,People.RADIUS,"walk",sy) then free=false; break end
                    end
                end
                if free then return x,z,y end
            end
        end
    end
    return nil
end

---@param slot CareerDeliveryPersonSlot
---@return CareerDeliveryPerson
function People:CreatePerson(slot)
    local node=self.root:CreateChild("配送交接槽"..slot.index)
    node:SetEnabledRecursive(false)
    local rig=Rig.New(node,Pedestrians.Specs[(slot.index-1)%#Pedestrians.Specs+1])
    rig.ground=self.city
    rig.model.drawDistance=People.HIDE_DISTANCE; rig.model.shadowDistance=28
    rig.model.updateInvisible=false
    ---@type CareerDeliveryPerson
    local p={slot=slot.index,source="pool",node=node,rig=rig,x=0,z=0,y=0,yaw=0,homeYaw=0,
        pointId="",role="merchant",visible=false,hold=0,active=false,radius=People.RADIUS,
        orderIds={},clock=0,phase=slot.index*1.73,poseElapsed=0,poseCount=0,bindCount=0,
        poseDirty=true,gesture="",gestureTime=0,gestureDuration=0,gestureWeight=0}
    rig.visible=false
    node:SetEnabledRecursive(false)
    slot.person=p
    self.people[#self.people+1]=p
    return p
end
---@param p CareerDeliveryPerson
function People:Release(p)
    if self.byPoint[p.pointId]==p then self.byPoint[p.pointId]=nil end
    show(p,false)
    p.pointId,p.active,p.hold="",false,0
    p.orderIds={}
    p.gesture,p.gestureWeight,p.gestureTime="",0,0
    p.poseDirty=true
end
-- Bind为内部接口；只由Sync对新目标/角色变化调用，绝不每帧重置骨架或材质。
---@param slot CareerDeliveryPersonSlot
---@param target CareerDeliveryTarget
---@return CareerDeliveryPerson?
function People:Bind(slot,target)
    local x,z,y=self:FindStand(target,slot.person)
    if x==nil or z==nil or y==nil then return nil end
    local p=slot.person or self:CreatePerson(slot)
    if p.pointId~="" then self:Release(p) end
    local point=assert(Config.points[target.pointId])
    p.pointId,p.role,p.active=target.pointId,target.role,true
    p.x,p.z,p.y=x,z,y
    p.homeYaw=wrap(math.deg(math.atan(point.x-x,point.z-z))); p.yaw=p.homeYaw
    p.orderIds=copyIds(target.orderIds)
    p.clock,p.poseElapsed,p.hold=0,0,0
    p.gesture,p.gestureTime,p.gestureDuration,p.gestureWeight="",0,0,0
    p.node.position=V(x,y,z); p.node.rotation=Quaternion(0,p.yaw,0)
    p.poseDirty=true
    p.bindCount=p.bindCount+1; self.binds=self.binds+1
    self.byPoint[p.pointId]=p
    local viewer=self.viewer
    local visible=self.city.space=="city" and viewer~=nil and (viewer.x-x)^2+(viewer.z-z)^2<=People.HIDE_DISTANCE^2
    show(p,visible)
    if p.visible then self:Pose(p) end
    return p
end

---@param orders? CareerDeliveryPeopleOrder[]|CareerOrder[] accepted/picked_up；nil视为空集，不读取Store
---@param actor? CareerActor|table 新绑定避让骑手/停车；旧目标不因actor移动重绑
function People:Sync(orders,actor)
    if self.disposed then return end
    rememberViewer(self,actor)
    local keyParts={self.city.space}
    for _,o in ipairs(orders or {}) do
        if o.status=="accepted" or o.status=="picked_up" then
            keyParts[#keyParts+1]=table.concat({o.id,o.status,o.pickupId,o.dropoffId},"\31")
        end
    end
    local syncKey=table.concat(keyParts,"\30")
    local retryKey=retryCell(self.viewer)
    if syncKey==self.syncKey and not self.pending
        and (#self.unplacedIds==0 or retryKey==self.retryKey) then return end
    self.syncKey,self.retryKey=syncKey,retryKey
    ---@type CareerDeliveryPeopleOrder[]
    local snapshot={}
    ---@type CareerDeliveryTarget[]
    local targets={}
    ---@type table<string,CareerDeliveryTarget>
    local wanted={}
    for _,order in ipairs(orders or {}) do
        if order.status=="accepted" or order.status=="picked_up" then
            local pickup=order.status=="accepted"
            local id=pickup and order.pickupId or order.dropoffId
            local point=Config.points[id]
            if point then
                local route={}
                for _,r in ipairs(order.route or {}) do route[#route+1]={x=r.x,z=r.z} end
                snapshot[#snapshot+1]={id=order.id,status=order.status,pickupId=order.pickupId,dropoffId=order.dropoffId,route=route}
                local target=wanted[id]
                if not target then
                    local contact=People.ContactIds[id]
                    local list={}
                    for _,a in ipairs(self.approaches[id] or {}) do list[#list+1]={x=a.x,z=a.z,length=a.length} end
                    target={pointId=id,role=pickup and "merchant" or "customer",source=contact and "contact" or "pool",
                        contactId=contact,orderIds={},approaches=list}
                    wanted[id]=target; targets[#targets+1]=target
                end
                if not pickup then target.role="customer" end
                target.orderIds[#target.orderIds+1]=order.id
                approach(target.approaches,point,neighborFor(route,pickup))
            end
        end
    end
    self.orders,self.targets=snapshot,targets
    self.unplacedIds,self.overflowIds={},{}
    if self.city.space~="city" then
        self.pending=true
        for _,p in ipairs(self.people) do show(p,false) end
        return
    end
    self.pending=false
    -- 先保留不变目标，释放消失商家；只有Respond标记过的顾客才可短暂保留。
    for _,p in ipairs(self.people) do
        local target=wanted[p.pointId]
        if not target or target.source~="pool" then
            p.active=false
            if p.hold<=0 then self:Release(p) end
        end
    end
    -- 先处理现有点；避免新目标拿走仍需要的槽，或站位检查忽略尚未恢复active的点。
    for _,target in ipairs(targets) do
        local p=self.byPoint[target.pointId]
        if p and target.source=="pool" then
            if p.role~=target.role then
                if not self:Bind(self.slots[p.slot],target) then
                    self:Release(p)
                    self.unplacedIds[#self.unplacedIds+1]=target.pointId
                end
            else
                -- 同点增减订单只更新快照；同单重复Sync绝不重绑、续hold或触发IK。
                local old={}
                for _,id in ipairs(p.orderIds) do old[id]=true end
                for _,id in ipairs(target.orderIds) do if not old[id] then p.hold=0; break end end
                p.active=true
                p.orderIds=copyIds(target.orderIds)
            end
        end
    end
    for _,target in ipairs(targets) do
        if target.source=="pool" and not self.byPoint[target.pointId] then
            local alreadyFailed=false
            for _,id in ipairs(self.unplacedIds) do if id==target.pointId then alreadyFailed=true; break end end
            if not alreadyFailed then
                ---@type CareerDeliveryPersonSlot?
                local chosen=nil
                for _,slot in ipairs(self.slots) do
                    if not slot.person or slot.person.pointId=="" then chosen=slot; break end
                end
                if not chosen then
                    for _,slot in ipairs(self.slots) do
                        if slot.person and not slot.person.active then chosen=slot; break end
                    end
                end
                if not chosen then self.overflowIds[#self.overflowIds+1]=target.pointId
                elseif not self:Bind(chosen,target) then self.unplacedIds[#self.unplacedIds+1]=target.pointId end
            end
        end
    end
    for _,id in ipairs(self.unplacedIds) do print("[配送人物] 无安全站位，保留原marker授权："..id) end
    for _,id in ipairs(self.overflowIds) do print("[配送人物] 四槽已满，未生成额外人物："..id) end
end

-- 与Life相同：PoseWalk(0,0)先完整恢复腿/鞋底真实顶点贴地，再仅覆盖上肢。
-- 保留后-下-外肘hint，不重转twist、不改共享Rig方法、不声称自然递物/采集动画。
---@param p CareerDeliveryPerson
function People:Pose(p)
    p.rig:PoseWalk(0,0)
    local rig=p.rig
    local t=p.clock+p.phase
    rig:SetBodyRotation("Spine02",math.sin(t*1.6)*.55,math.sin(t*.31)*.6)
    local nod=p.gesture=="thanks" and math.sin(p.gestureTime*6)*4*p.gestureWeight or 0
    rig:SetBodyRotation("Head",math.sin(t*.67)*1.2+nod,math.sin(t*.31)*3)
    for _,chain in ipairs(rig.arms) do
        if chain.side==1 then
            local root=rig:GetBonePosition(chain.upper)
            local rest=rig:GetBonePosition(chain.tip)
            local reach=chain.lengthA+chain.lengthB
            local target=root+V(chain.side*.04,-reach*.63,reach*.43+math.sin(t*2.4)*.025)
            local desired=rest+(target-rest)*p.gestureWeight
            local delta=desired-root
            local length=math.max(math.abs(chain.lengthA-chain.lengthB)+.003,math.min(reach*.96,delta:Length()))
            rig:SolveChain(chain,root+delta:Normalized()*length,V(chain.side*.12,-.1,-1),false)
        end
    end
    p.poseDirty=false
    p.poseCount=p.poseCount+1; self.poses=self.poses+1
end

---@param pointId string
---@return CareerDeliveryPerson? 直接person，不是{person=...}；contact目标返回nil，且不托管既有Rig
function People:Get(pointId)
    if self.disposed then return nil end
    return self.byPoint[pointId]
end
---@param pointId string
---@param pickup boolean true=成功取餐回应；false=成功送达回应+最多6s保留
---@return boolean handled 只有可见池人物才即时提交IK；contact由主线程转发
function People:Respond(pointId,pickup)
    if self.disposed or self.city.space~="city" or type(pickup)~="boolean" then return false end
    local p=self:Get(pointId)
    if not p or not p.visible or (not p.active and p.hold<=0) then return false end
    if not pickup and p.hold<=0 then p.hold=People.HOLD_SECONDS end
    p.gesture=pickup and "pickup" or "thanks"
    p.gestureTime,p.gestureDuration,p.gestureWeight=.22,2.2,.65
    -- 对话框当帧冻结Update也能看见回应；不转动髋/腿，不生成手持物。
    self:Pose(p)
    return true
end

---@param dt number 活动秒；hold使用完整dt（不被IK限步延长）；冻结不补跑
---@param actor? CareerActor|table 只读x/z/mounted/walkHeight；无效actor不推进动作或hold
---@param enabled? boolean false为手机/对话/暂停冻结，不是隐藏开关
function People:Update(dt,actor,enabled)
    if self.disposed then return end
    self.enabled=enabled~=false and self.city.space=="city"
    if self.city.space~="city" then
        for _,p in ipairs(self.people) do show(p,false) end
        return
    end
    rememberViewer(self,actor)
    if self.pending or (#self.unplacedIds>0 and retryCell(self.viewer)~=self.retryKey) then self:Sync(self.orders) end
    for _,p in ipairs(self.people) do
        local viewer=self.viewer
        local distance=viewer and (viewer.x-p.x)^2+(viewer.z-p.z)^2 or math.huge
        show(p,p.pointId~="" and (p.active or p.hold>0) and distance<=People.HIDE_DISTANCE^2)
        -- 新绑定的远处Rig尚未求值；第一次近距显示先站稳，之后暂停绝不推进/重算姿势。
        if p.visible and p.poseDirty then self:Pose(p) end
    end
    if not self.enabled or not actor or not finite(actor.x) or not finite(actor.z) or not finite(dt) or dt<=0 then return end
    local step=math.min(dt,.1)
    for _,p in ipairs(self.people) do
        if p.pointId~="" then
            if p.hold>0 then
                p.hold=math.max(0,p.hold-dt)
                if p.hold==0 and not p.active then self:Release(p) end
            end
            if p.visible then
                local distance=(actor.x-p.x)^2+(actor.z-p.z)^2
                p.clock=p.clock+step; p.poseElapsed=p.poseElapsed+step
                local desired=p.homeYaw
                local sameLevel=not finite(actor.walkHeight) or math.abs(actor.walkHeight-p.y)<.65
                if not actor.mounted and sameLevel and distance<=4.5^2 and distance>.35^2 then
                    desired=math.deg(math.atan(actor.x-p.x,actor.z-p.z))
                end
                local delta=wrap(desired-p.yaw)
                p.yaw=wrap(p.yaw+math.max(-People.TURN_SPEED*step,math.min(People.TURN_SPEED*step,delta)))
                p.node.rotation=Quaternion(0,p.yaw,0)
                if p.gesture~="" then
                    p.gestureTime=p.gestureTime+step
                    local u=math.min(1,p.gestureTime/p.gestureDuration)
                    p.gestureWeight=math.sin(u*math.pi)^.65
                    if u>=1 then p.gesture,p.gestureWeight="",0 end
                end
                local period=distance<=People.NEAR_DISTANCE^2 and .05 or .25
                if p.poseDirty or p.poseElapsed>=period then
                    self:Pose(p); p.poseElapsed=p.poseElapsed%period
                end
            end
        end
    end
end

-- City:IsFree动态接线用；绝不能在City:StaticFree调用（站位检查会递归）。
-- 室内不碰撞；室外active/held即使远距隐藏仍占圆，手机冻结仍阻挡。
---@param x number
---@param z number
---@param radius? number 查询移动体半径（米）
---@param mode? string 可选walk层过滤；不传时按地面查询
---@param height? number 步行脚底高度；相差>.9m不碰撞
---@return boolean
function People:IsFree(x,z,radius,mode,height)
    if self.disposed or self.city.space~="city" then return true end
    local r=radius or 0
    if not finite(x) or not finite(z) or not finite(r) or r<0 then return false end
    for _,p in ipairs(self.people) do
        local sameLevel=mode~="walk" or height==nil or (finite(height) and math.abs(height-p.y)<=.9)
        if p.pointId~="" and (p.active or p.hold>0) and sameLevel
            and (x-p.x)^2+(z-p.z)^2<(r+p.radius)^2 then return false end
    end
    return true
end
---@return CareerDeliveryPeopleStats 返回独立统计快照，不让checks改写内部列表
function People:Stats()
    local active,held,visible,external=0,0,0,0
    for _,p in ipairs(self.people) do
        if p.active then active=active+1 end
        if p.hold>0 then held=held+1 end
        if p.visible then visible=visible+1 end
    end
    for _,target in ipairs(self.targets) do if target.source=="contact" then external=external+1 end end
    return {capacity=People.CAPACITY,created=#self.people,active=active,held=held,visible=visible,
        binds=self.binds,poses=self.poses,targets=#self.targets,external=external,
        unplaced=#self.unplacedIds,overflow=#self.overflowIds,unplacedIds=copyIds(self.unplacedIds),
        overflowIds=copyIds(self.overflowIds),disposed=self.disposed}
end
function People:Dispose()
    if self.disposed then return end
    self.disposed,self.enabled,self.pending=true,false,false
    for _,p in ipairs(self.people) do
        show(p,false); p.active,p.hold=false,0
        p.rig:Dispose()
    end
    self.root:Dispose()
    for _,slot in ipairs(self.slots) do slot.person=nil end
    self.people,self.byPoint,self.targets,self.orders={},{},{},{}
    self.unplacedIds,self.overflowIds={},{}
    self.viewer=nil
    self.approaches={}
end
return People
