-- 局部街坊生活：基于3D角色脚手架的节点/资源生命周期，复用现有便服Rig。
-- 只做固定安全驻足与程序化上肢姿势；没有新动画clip、随机寻路、UI或存档事务。
local Rig=require("Career.Rig")
local Pedestrians=require("Career.Pedestrians")
local Config=require("Career.Config")
local V=Vector3

---@class CareerStreetPersonSpec
---@field id string
---@field name string
---@field point? string
---@field x number
---@field z number
---@field yaw number
---@field role string
---@field asset? integer
---@field partner? string
local PersonSpecType={}
---@class CareerStreetPerson : CareerStreetPersonSpec
---@field node Node
---@field rig CareerRig
---@field homeYaw number
---@field phase number
---@field clock number
---@field poseElapsed number
---@field poseCount integer
---@field visible boolean
---@field gesture string
---@field gestureTime number
---@field gestureDuration number
---@field gestureWeight number
---@field attention boolean
---@field phone? Node
---@field blocker table
local PersonType={}
---@class CareerStreetLife
---@field city CareerCity
---@field root Node
---@field people CareerStreetPerson[]
---@field byId table<string,CareerStreetPerson>
---@field blockers table[]
---@field disposed boolean
---@field enabled boolean
local Life={}
Life.__index=Life
Life.TURN_SPEED=65 -- degrees/second; never snap or invert model forward (+Z).
Life.HIDE_DISTANCE=90
Life.NEAR_DISTANCE=22
Life.INTERACTION_RADIUS=3

---@type CareerStreetPersonSpec[]
Life.Residents={
    {id="breakfast_waiting",name="等早餐的街坊",point="breakfast",x=-19.1,z=-10.9,yaw=-55,role="waiting",asset=3},
    {id="bridge_chat_a",name="桥下聊天的街坊",point="bridge",x=-10,z=-66.5,yaw=-42,role="chat",asset=2,partner="bridge_chat_b"},
    {id="bridge_chat_b",name="听街坊说话的居民",point="bridge",x=-11,z=-65.4,yaw=138,role="listening",asset=1,partner="bridge_chat_a"},
    {id="phone_neighbor",name="店边看手机的居民",point="noodle",x=-72.7,z=10.9,yaw=155,role="phone",asset=4},
}

local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
local function wrap(yaw) return (yaw+180)%360-180 end
---@param person CareerStreetPerson
local function show(person,visible)
    if person.visible==visible and person.node.enabledSelf==visible then return end
    person.visible=visible
    -- 整个驻点含名字/手机一起隐藏，不能只关rig留下悬空道具。
    person.node:SetEnabledRecursive(visible)
    person.rig.visible=visible
end

-- 俯视碰撞设计，单位米；所有驻点不移动：
--  [建筑实体]  <- >=.8m ->  (驻足包络r=.45)    原POI圆r=2完整留空
--  --------- z=±10.9 ------ 人行道 ------ z=±8.7旧行人线 ------ 路缘±6
--  桥下使用x≈-10西侧人行道；绝不在x=±3的车辆轨迹或POI(0,-70)站人。
--  碰撞AABB为.8×.8；先检查静态r=.45，再注册，析构按对象identity删除。
--  不做随机漫步/动态扩张，擦边仍由City的原圆-AABB扫掠负责。
---@param city CareerCity
---@param parent? Node
---@param specs? CareerStreetPersonSpec[]
---@return CareerStreetLife
function Life.New(city,parent,specs)
    local self=setmetatable({},Life)
    self:Init(city,parent or city.root,specs or Life.Residents)
    return self
end
function Life:Init(city,parent,specs)
    self.city=city
    self.root=parent:CreateChild("有界街坊生活")
    self.people,self.byId,self.blockers={},{},{}
    self.disposed,self.enabled=false,false
    for _,spec in ipairs(specs) do self:Add(spec) end
end

---@param spec CareerStreetPersonSpec
---@return CareerStreetPerson
function Life:Add(spec)
    assert(not self.disposed and not self.byId[spec.id],"重复或已释放的街坊ID")
    assert(self.city:StaticFree(spec.x,spec.z,.45,"walk",0),"街坊驻点落在障碍内："..spec.id)
    for _,point in ipairs(Config.pointList) do
        assert((point.x-spec.x)^2+(point.z-spec.z)^2>(Config.INTERACTION_RADIUS+.6)^2,
            "街坊驻点侵占原POI两米交互圆："..spec.id)
    end
    local node=self.root:CreateChild(spec.name)
    node.position=V(spec.x,self.city:Surface(spec.x,spec.z),spec.z)
    node.rotation=Quaternion(0,spec.yaw,0)
    local rig=Rig.New(node,Pedestrians.Specs[spec.asset or 1])
    rig.ground=self.city; rig.model.drawDistance=90; rig.model.shadowDistance=28
    local blocker={x1=spec.x-.4,x2=spec.x+.4,z1=spec.z-.4,z2=spec.z+.4}
    self.city.obstacles[#self.city.obstacles+1]=blocker
    self.blockers[#self.blockers+1]=blocker
    ---@type CareerStreetPerson
    local p={id=spec.id,name=spec.name,point=spec.point,x=spec.x,z=spec.z,yaw=spec.yaw,homeYaw=spec.yaw,
        role=spec.role,asset=spec.asset,partner=spec.partner,node=node,rig=rig,blocker=blocker,
        phase=#self.people*1.73,clock=0,poseElapsed=0,poseCount=0,visible=true,
        gesture="",gestureTime=0,gestureDuration=0,gestureWeight=0,attention=false}
    self.people[#self.people+1]=p; self.byId[p.id]=p
    if p.role=="phone" then
        -- 已有1m Box精确缩为手机尺寸；不是新导入/新生成的美术资产。
        local phone=node:CreateChild("既有Box组合手机")
        local model=phone:CreateChild("手机机身")
        model.scale=V(.068,.13,.009)
        local draw=model:CreateComponent("StaticModel")
        draw.model=cache:GetResource("Model","Models/Box.mdl"); draw.material=self.city.mats.recess
        draw.drawDistance=35; draw.castShadows=false
        local screen=phone:CreateChild("手机屏面")
        screen.position=V(0,0,.005); screen.scale=V(.056,.108,.001)
        local screenDraw=screen:CreateComponent("StaticModel")
        screenDraw.model=draw.model; screenDraw.material=self.city.mats.glass
        screenDraw.drawDistance=35; screenDraw.castShadows=false
        p.phone=phone
    end
    self:Pose(p)
    return p
end

---@param id string
---@return CareerStreetPerson?
function Life:Get(id)
    if self.disposed then return nil end
    return self.byId[id]
end

-- 仅现场候选查询，绝不是收钱/交付/委托授权；调用者仍检查原POI和停稳条件。
---@param actor CareerActor|table
---@param radius? number
---@return CareerStreetPerson?,number
function Life:Nearest(actor,radius)
    if self.disposed or self.city.space~="city" or not actor or not finite(actor.x) or not finite(actor.z) then return nil,math.huge end
    local best,distance=nil,(radius or Life.INTERACTION_RADIUS)^2
    for _,p in ipairs(self.people) do
        local d=(actor.x-p.x)^2+(actor.z-p.z)^2
        if d<=distance then best,distance=p,d end
    end
    return best,best and math.sqrt(distance) or math.huge
end

-- 本地米坐标与Rig/PoseWalk相同：+X右、+Y上、+Z前。
-- 先完整PoseWalk(0,0)保留双鞋真实顶点贴地；只替换肩/肘/腕，髋和腿不再动。
-- 不使用世界空间骨骼Euler、不重转twist、不翻肘：沿用PoseWalk的后下外侧hint。
-- 这是程序化轻动作，不是采集的自然交谈/看手机动画；视觉自然度仍需截图验收。
---@param p CareerStreetPerson
function Life:Pose(p)
    local rig=p.rig
    rig:PoseStandingCached()
    local t=p.clock+p.phase
    local breath=math.sin(t*1.6)*.65
    rig:SetBodyRotation("Spine02",breath,math.sin(t*.31)*.7)
    local phone=p.role=="phone" and p.gesture==""
    local weight=p.gestureWeight
    local ambient=(t%9)>5 and math.sin(((t%9)-5)/4*math.pi)^2 or 0
    if p.gesture=="" then
        weight=p.role=="chat" and ambient*.65 or p.role=="merchant" and ambient*.42
            or p.role=="waiting" and ambient*.12 or p.role=="bridge" and ambient*.28 or 0
    end
    local headPitch=phone and 13 or math.sin(t*.67)*1.4
    if p.gesture=="nod" then headPitch=headPitch+math.sin(p.gestureTime*6)*4*weight end
    rig:SetBodyRotation("Head",headPitch,math.sin(t*.31)*4)
    for _,chain in ipairs(rig.arms) do
        local root=rig:GetBonePosition(chain.upper)
        local rest=rig:GetBonePosition(chain.tip)
        local reach=chain.lengthA+chain.lengthB
        local active=chain.side==1 or phone
        if active then
            local target
            if phone then
                target=V(chain.side*.055,root.y-reach*.55,root.z+reach*.50)
            else
                local pulse=math.sin(t*2.4)*.035
                target=root+V(chain.side*.04,-reach*(p.gesture=="greet" and .38 or .63),reach*.43+pulse)
            end
            local w=phone and .94 or math.max(0,math.min(1,weight))
            local desired=rest+(target-rest)*w
            -- 显式夹到两段骨长的内部，杜绝手势越界产生夹取日志/极端直臂。
            local delta=desired-root
            local length=math.max(math.abs(chain.lengthA-chain.lengthB)+.003,math.min(reach*.96,delta:Length()))
            local safe=root+delta:Normalized()*length
            rig:SolveChain(chain,safe,V(chain.side*.12,-.1,-1),false)
        end
    end
    if p.phone then
        local l,r=rig:GetBonePosition("L_Hand"),rig:GetBonePosition("R_Hand")
        p.phone.position=(l+r)*.5+V(0,.025,.015)
        p.phone.rotation=Quaternion(32,0,0)
        p.phone:SetEnabledRecursive(phone)
    end
    p.poseCount=p.poseCount+1
end

---@param id string
---@param kind? string talk/greet/nod/handover；handover复用交谈轻手势，不冒充递物clip
---@param duration? number seconds, clamped .8..4
---@return boolean
function Life:BeginGesture(id,kind,duration)
    local p=self:Get(id)
    if not p or self.city.space~="city" then return false end
    local gesture=kind=="handover" and "talk" or kind or "talk"
    if gesture~="talk" and gesture~="greet" and gesture~="nod" then return false end
    p.gesture,p.gestureTime,p.gestureDuration=gesture,.22,math.max(.8,math.min(4,duration or 2.2))
    -- 对话框马上冻结Update，仍必须在点击当帧出现可读的回应姿势。
    p.gestureWeight=.65
    self:Pose(p)
    return true
end
function Life:Respond(id,kind) return self:BeginGesture(id,kind or "talk",2.2) end

---@param dt number
---@param actor CareerActor|table
---@param hour? number 仅留作现场时段扩展；不写档、不以时钟跳变推进动作
---@param enabled? boolean false为暂停/手机冻结；室内由city.space附加隐藏
function Life:Update(dt,actor,hour,enabled)
    if self.disposed then return end
    self.enabled=enabled~=false and self.city.space=="city"
    if self.city.space~="city" then
        for _,p in ipairs(self.people) do show(p,false) end
        return
    end
    if not self.enabled or not finite(dt) or dt<=0 or not actor or not finite(actor.x) or not finite(actor.z) then return end
    local step=math.min(dt,.1) -- 不补跑暂停或大卡顿的时间；转速仍小于TURN_SPEED*dt。
    for _,p in ipairs(self.people) do
        local distance=(actor.x-p.x)^2+(actor.z-p.z)^2
        local visible=distance<=Life.HIDE_DISTANCE^2
        show(p,visible)
        if visible then
            p.clock=p.clock+step; p.poseElapsed=p.poseElapsed+step
            local sameLevel=not actor.walkHeight or math.abs(actor.walkHeight-p.node.position.y)<.65
            local attention=not actor.mounted and sameLevel and distance<=4.5^2
            p.attention=attention
            local desired=p.homeYaw
            if attention and distance>.35^2 then desired=math.deg(math.atan(actor.x-p.x,actor.z-p.z)) end
            local delta=wrap(desired-p.yaw)
            p.yaw=wrap(p.yaw+math.max(-Life.TURN_SPEED*step,math.min(Life.TURN_SPEED*step,delta)))
            p.node.rotation=Quaternion(0,p.yaw,0)
            if p.gesture~="" then
                p.gestureTime=p.gestureTime+step
                local u=p.gestureTime/p.gestureDuration
                p.gestureWeight=math.sin(math.min(1,u)*math.pi)^.65
                if u>=1 then p.gesture=""; p.gestureWeight=0 end
            end
            -- 22m内20Hz，其余90m内4Hz；远处不做骨骼FK/IK，角色总数固定8。
            local period=distance<Life.NEAR_DISTANCE^2 and 1/20 or .25
            if p.poseElapsed>=period then self:Pose(p); p.poseElapsed=p.poseElapsed%period end
        end
    end
end

function Life:Dispose()
    if self.disposed then return end
    self.disposed=true
    for _,p in ipairs(self.people) do p.rig:Dispose() end
    for index=#self.city.obstacles,1,-1 do
        for _,blocker in ipairs(self.blockers) do
            if self.city.obstacles[index]==blocker then table.remove(self.city.obstacles,index); break end
        end
    end
    self.root:Dispose()
    self.people,self.byId,self.blockers={},{},{}
end
return Life
