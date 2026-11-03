-- 轻量程序化机关专项验收；只复制判定记录并创建Lua夹具，不读取/写入存档。
-- 接入：require("CourseWorldChecks").Run(world)，须在World构建完成、正式发车前调用。
local Assets=require("CourseAssets")
local Rules=require("MixedRace")
local Vehicles=require("MixedVehicles")
local M={}

---@class CourseCheckRecord
---@field id string|number
---@field kind string
---@field node Node?
---@field active boolean
---@field breakable boolean
---@field x number
---@field y number
---@field z number
---@field previousX? number
---@field previousY? number
---@field previousZ? number
---@field yaw number
---@field s number
---@field lane number
---@field halfWidth number
---@field halfLength number
---@field height number

---@param source CourseCheckRecord[]
---@param include? fun(record:CourseCheckRecord):boolean
---@return CourseCheckRecord[]
local function cloneRecords(source,include)
    local out={}
    for _,record in ipairs(source) do
        if not include or include(record) then
            ---@type CourseCheckRecord
            local copy={id=record.id,kind=record.kind,active=true,breakable=false,
                x=record.x,y=record.y,z=record.z,yaw=record.yaw,s=record.s,lane=record.lane,
                halfWidth=record.halfWidth,halfLength=record.halfLength,height=record.height,
                previousX=record.x,previousY=record.y,previousZ=record.z}
            out[#out+1]=copy
        end
    end
    return out
end

-- 碰撞夹具（米）：实际record局部+Z方向，起止为中心前后8米；
-- 高度用真实路面+载具稳定悬高，车体尺寸由生产MixedVehicles取得。
-- 不借用Simulation:Impact，以明确的内存计数/生命/速度验证规则调用与去重。
local function sweep(records,id,x,z,y,yaw)
    local a=math.rad(yaw)
    local dx,dz=math.sin(a)*8,math.cos(a)*8
    local sim={vehicleId=id,x=x+dx,y=y,z=z+dz,heading=yaw,speed=20,health=100,impactSerial=0}
    function sim:Impact()
        self.impactSerial=self.impactSerial+1
        self.health=self.health-7
    end
    Rules.Reset(sim)
    sim.oddAltitude=id=="helicopter" and 2.5 or 0
    sim.oddPreviousAltitude=sim.oddAltitude
    Rules.Obstacles(sim,{mixedObstacles=records,mixedCoins={}},x-dx,y,z-dz)
    return sim
end

local function finite(x)
    return type(x)=="number" and x==x and math.abs(x)<math.huge
end

-- 低成本回归：真实Course.Build + 真MDL/材质，只有道路采样使用平直解析夹具。
-- 不替换CreateCourse/Assets/Build，也不需要构建完整Landscape/交通/植被World。
-- 可独立调用RunInitialization()，应在正式资源预热完成后执行。
function M.RunInitialization()
    local Course=require("MixedCourse")
    local scene=Scene()
    scene:CreateComponent("Octree")
    local map={RouteLength=720,Roads={{width=8}},Ramps={},Track={theme="circuit"},
        RoadPoint=function(s) return Vector3(0,0,s),0 end,
        TrafficPose=function(s,lane) return Vector3(lane,0,s),0,0 end,
        NearestRoad=function(x,z)
            assert(finite(x) and finite(z),"[正式机关初始化] 生产Build不能在动态bounds初始化前投影")
            return z,x
        end}
    local fixture={root=scene:CreateChild("CourseInitializationFixture"),landscape=map}
    local count=0
    local ok,message=pcall(function()
        Course.Build(fixture)
        assert(#fixture.mixedSwings>0,"[正式机关初始化] 必须由生产CreateCourse实际生成摆锤")
        for _,record in ipairs(fixture.mixedObstacles) do
            assert(finite(record.x) and finite(record.y) and finite(record.z),"[正式机关初始化] 真实记录缺坐标")
            assert(finite(record.halfWidth) and finite(record.halfLength) and finite(record.height),
                "[正式机关初始化] 真实记录缺bounds")
            count=count+1
        end
        local chainCount=0
        for _,swing in ipairs(fixture.mixedSwings) do
            assert(#swing.parts==9,"[轻量机关初始化] 每锤必须保留摆球和8段连杆判定")
            for _,part in ipairs(swing.parts) do
                local record=part.record
                assert(record.previousX==record.x and record.previousY==record.y and record.previousZ==record.z,
                    "[轻量机关初始化] previous必须初始化为当前坐标")
                if tostring(record.id):find("_swingchain",1,true) then
                    chainCount=chainCount+1
                    assert(record.node and record.node:GetChild("连杆"),"[轻量机关初始化] 连杆判定必须有对应可见几何")
                end
            end
        end
        assert(chainCount==#fixture.mixedSwings*8,"[轻量机关初始化] 每根可见连杆必须细分8段判定")
        local swing=fixture.mixedSwings[1]
        local origin=swing.origin --[[@as Vector3]]
        Course.Update(fixture,(math.pi*.5-swing.phase)/1.7)
        local clear=sweep(cloneRecords(fixture.mixedObstacles),"ebike",origin.x-.4,origin.z,2.3,0)
        assert(clear.impactSerial==0,"[轻量机关初始化] 最大摆角时连杆左下空白区不得误撞")
        local angle=math.rad(22)
        local hit=sweep(cloneRecords(fixture.mixedObstacles),"ebike",origin.x+math.sin(angle)*1.8,
            origin.z,5.2-math.cos(angle)*1.8,0)
        assert(hit.impactSerial>0,"[轻量机关初始化] 最大摆角时可见连杆仍须能撞到")
    end)
    scene:Dispose()
    assert(ok,tostring(message))
    print(string.format("[轻量机关初始化] PASS records=%d / 生产Build、摆球与单连杆先bounds后投影",count))
    return count
end

---@param world table
---@return table
function M.Run(world)
    M.RunInitialization()
    assert(world and world.landscape and world.mixedRoot,"[正式机关验收] 必须传入已构建真实World")
    ---@type CourseCheckRecord[]
    local source=assert(world.mixedObstacles)
    local map=world.landscape
    local checks,owners,supports,airCount,coinCount=0,0,0,0,0
    local function check(ok,message)
        assert(ok,"[正式机关验收] "..message)
        checks=checks+1
    end
    check(#source>0,"真实赛道机关不可为空")
    -- 新契约：共享低面数网格、共享无贴图材质；关闭机关阴影。
    ---@type table<Node, boolean>
    local checkedNodes={}
    ---@type table<Model, boolean>
    local sharedModels={}
    ---@type table<Material, boolean>
    local sharedMaterials={}
    local drawsCount,triangles=0,0
    ---@type table<StaticModel, boolean>
    local checkedDraws={}
    local function formalNode(node)
        if checkedNodes[node] then return end
        checkedNodes[node]=true
        local draws=node:GetComponents("StaticModel",true)
        check(#draws>0,"碰撞记录必须挂接可见程序化网格："..node.name)
        for _,draw in ipairs(draws) do
            if not checkedDraws[draw] then
            checkedDraws[draw]=true
            local model=draw:GetModel()
            check(model and Assets.IsSharedModel(model),"机关必须使用共享轻量网格："..node.name)
            sharedModels[model]=true
            local scale=draw.node.scale
            check(scale.x>0 and scale.y>0 and scale.z>0,"网格缩放必须为正")
            check(not draw.castShadows and draw.drawDistance<=210,"机关阴影与可视距离超出预算")
            drawsCount=drawsCount+1
            for slot=0,model.numGeometries-1 do
                local material=draw:GetMaterial(slot)
                check(material and not material:GetTexture(TU_DIFFUSE) and not material:GetTexture(TU_NORMAL),
                    "轻量机关不得加载D/N贴图："..node.name)
                sharedMaterials[material]=true
                local geometry=assert(model:GetGeometry(slot,0))
                triangles=triangles+geometry.indexCount/3
            end
            end
        end
    end
    local ids={}
    local snapshots={}
    for _,record in ipairs(source) do
        check(not ids[record.id],"碰撞ID必须唯一："..tostring(record.id))
        ids[record.id]=true
        check(record.node~=nil,"碰撞记录缺少真实节点")
        local recordNode=assert(record.node)
        formalNode(recordNode)
        for _,key in ipairs({"x","y","z","yaw","s","lane","halfWidth","halfLength","height"}) do
            check(finite(record[key]),"碰撞范围出现非法数值："..tostring(record.id).."/"..key)
        end
        check(record.halfWidth>0 and record.halfLength>0 and record.height>0,"实体范围必须非零")
        local station,lane=map.NearestRoad(record.x,record.z)
        local route=map.RouteLength
        local delta=(station-record.s+route*.5)%route-route*.5
        check(math.abs(delta)<.02 and math.abs(lane-record.lane)<.02,"AI坐标必须投影实际碰撞片段中心")
        snapshots[#snapshots+1]={record=record,x=record.x,y=record.y,z=record.z,active=record.active,
            node=recordNode,enabled=recordNode.enabled}
        if record.kind=="support" then supports=supports+1 else owners=owners+1 end
    end
    local all=cloneRecords(source)
    local safeCount,doorCount=0,0
    for _,owner in ipairs(source) do
        if owner.kind~="support" then
            local origin=assert(owner.node).position
            local baseY=origin.y
            -- 同侧功能先隔离目标真实record，避免同里程cone+airbarrier互相污染结论。
            local single=cloneRecords({owner})
            local ground=sweep(single,"ebike",owner.x,owner.z,baseY,owner.yaw)
            local air=sweep(cloneRecords({owner}),"helicopter",owner.x,owner.z,baseY,owner.yaw)
            if owner.kind=="airbarrier" then
                airCount=airCount+1
                check(air.impactSerial>0 and air.health<100 and air.speed<20,"飞机同侧必须撞上真实空障")
                check(ground.impactSerial==0 and ground.health==100 and ground.speed==20,"低车必须从空障下方通过")
            else
                check(ground.impactSerial>0 and ground.health<100 and ground.speed<20,
                    "玩家同侧必须撞上真实地面/摆球实体："..owner.kind)
                if owner.kind~="pendulum" then
                    check(air.impactSerial==0 and air.health==100 and air.speed==20,"飞机必须飞过低矮正式障碍")
                end
            end
            for _,id in ipairs({"ebike","helicopter"}) do
                local vehicle=assert(Vehicles.Get(id))
                local margin=map.Roads[1].width-assert(vehicle.size[1])*.5-.3
                check(margin>0,"路宽必须容纳完整载具")
                local side=owner.lane<0 and 1 or -1
                local point,yaw=map.TrafficPose(owner.s,side*margin)
                local drive=sweep(cloneRecords(all),id,point.x,point.z,point.y,yaw)
                check(drive.impactSerial==0 and drive.health==100 and drive.speed==20,
                    "完整World另一侧必须安全通过："..id.."/"..owner.kind.." #"..tostring(owner.id))
                safeCount=safeCount+1
            end
            if owner.kind=="pendulum" or owner.kind=="airbarrier" then
                local prefix="course_"..owner.id.."_arch"
                local arch=cloneRecords(source,function(record) return tostring(record.id):sub(1,#prefix)==prefix end)
                check(#arch>=2,"悬挂机关必须保留实际支架判定")
                local door=sweep(arch,"ebike",origin.x,origin.z,origin.y,owner.yaw)
                check(door.impactSerial==0,"不得使用整门框盒填满门洞")
                local column=assert(arch[1])
                local columnHit=sweep(cloneRecords(arch),"ebike",column.x,column.z,origin.y,owner.yaw)
                check(columnHit.impactSerial>0,"真实支架柱不可无碰撞")
                doorCount=doorCount+1
            end
        end
    end
    for _,coin in ipairs(world.mixedCoins or {}) do
        check(coin.node~=nil,"金币判定必须存在正式模型")
        formalNode(assert(coin.node))
        coinCount=coinCount+1
    end
    check(airCount>0 and doorCount>0 and supports>0 and coinCount>0,"空障/真支架/金币必须实际生成，不得删空取PASS")
    for _,before in ipairs(snapshots) do
        local record=before.record
        check(record.x==before.x and record.y==before.y and record.z==before.z and record.active==before.active
            and record.node==before.node and record.node.enabled==before.enabled,"隔离验收不得修改真实World")
    end
    -- 也检查预警牌，确保整条机关资源链没有残留实模、贴图或阴影。
    formalNode(world.mixedRoot)
    local modelCount,materialCount=0,0
    for _ in pairs(sharedModels) do modelCount=modelCount+1 end
    for _ in pairs(sharedMaterials) do materialCount=materialCount+1 end
    check(modelCount<=4 and materialCount<=5,"共享网格/材质数量超过预算")
    check(drawsCount<=owners*9+coinCount,"机关可渲染部件数量超过预算")
    check(triangles<=owners*400+coinCount*40,"机关三角面超过预算")
    print(string.format("[轻量机关预算] draws=%d triangles=%d sharedModels=%d materials=%d shadows=0",
        drawsCount,triangles,modelCount,materialCount))
    print(string.format("[轻量机关验收] PASS checks=%d owners=%d supports=%d air=%d coins=%d safe=%d doors=%d / 程序化网格、共享材质、双侧扫掠、门洞与柱体",
        checks,owners,supports,airCount,coinCount,safeCount,doorCount))
    return {checks=checks,owners=owners,supports=supports,air=airCount,coins=coinCount,safe=safeCount,doors=doorCount}
end
return M
