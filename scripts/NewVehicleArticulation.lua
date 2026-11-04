-- 五款真实新车的原网格拆件与独立pivot动画。
-- 所有部件来自 source 的原始三角面；MixedMeshParts 保留源 VB/UV/法线/切线，逐LOD重分配 IndexBuffer。
-- 原始坐标：Y-up；四车+X前（yaw=-90），气垫艇实测斜向(.953,0,-.304)前（yaw=-107.7）。
local Parts = require("MixedMeshParts")
local V = Vector3
local M = {}

local configs = {
    hovercraft = {
        rotation=-107.7,
        measuredSize=V(.999512,.644043,.887207),
        orientedSize=V(.760220,.644043,.980876),
        seat=V(-.04,.075,-.01), controls=V(.12,.10,-.15),
        joints={"FanP","FanN","Nozzle"},
        pivot={FanP=V(-.20,.13,.22),FanN=V(-.28,.13,-.12),Nozzle=V(.19,-.01,-.07)},
        modelHash="4fcb25f68ece49be8eea75f0dc346718",
    },
    centipede = {
        rotation=-90,
        measuredSize=V(.999512,.482910,.756348),
        orientedSize=V(.756348,.482910,.999512),
        seat=V(.16,.08,.02), controls=V(.22,.10,-.08),
        joints={"Tail","LegP1","LegP2","LegP3","LegP4","LegP5","LegP6",
            "LegN1","LegN2","LegN3","LegN4","LegN5","LegN6"},
        pivot={Tail=V(-.31,.01,0)},
        modelHash="a70e6cc64480458486a5635205e3a4ab",
    },
    buggy = {
        rotation=-90,
        measuredSize=V(.999512,.703613,.905762),
        orientedSize=V(.905762,.703613,.999512),
        seat=V(-.10,.28,0), controls=V(-.02,.14,0),
        joints={"WheelFrontP","WheelFrontN","WheelRearP","WheelRearN"},
        pivot={
            WheelFrontP=V(.34,-.18,.382),WheelFrontN=V(.34,-.18,-.382),
            WheelRearP=V(-.35,-.20,.335),WheelRearN=V(-.35,-.20,-.335),
        },
        modelHash="88412bc9434f4f4faa8c418e873ce557",
    },
    loader = {
        rotation=-90,
        measuredSize=V(.999512,.647949,.480957),
        orientedSize=V(.480957,.647949,.999512),
        seat=V(-.08,.16,0), controls=V(.01,.27,0),
        joints={"WheelFrontP","WheelFrontN","WheelRearP","WheelRearN","Arm","Bucket"},
        pivot={
            WheelFrontP=V(.14,-.19,.17),WheelFrontN=V(.14,-.19,-.17),
            WheelRearP=V(-.24,-.19,.17),WheelRearN=V(-.24,-.19,-.17),
            Arm=V(.06,-.02,0),Bucket=V(.34,-.18,0),
        },
        modelHash="87758016d43e4308a546ea464a9b39fb",
    },
    cicada = {
        rotation=-90,
        measuredSize=V(.999512,.815918,.957520),
        orientedSize=V(.957520,.815918,.999512),
        seat=V(-.03,.12,0), controls=V(.16,.04,0),
        joints={"WingP","WingN","WindupKey","FootP1","FootP2","FootP3","FootN1","FootN2","FootN3"},
        pivot={WindupKey=V(-.39,.31,0),WingP=V(.17,-.27,.25),WingN=V(.17,-.27,-.25)},
        modelHash="19fe86ecf0b34b2fb7d3dd067fd84160",
    },
}

---@param id string
---@return table
function M.GetConfig(id)
    local config=configs[id]
    if not config then error("未知真实新车："..tostring(id)) end
    return config
end
M.Configs = configs

local function abs(n) return math.abs(n) end

-- 每个 selector 只看一个原始连通件的实测 BoundingBox；没有按名称/预览图猜面。
-- 形状区域来自 .tmp/new_vehicle_*_pieces.json 的 LOD0/渲染投影测量，
-- 阈值留出不同LOD简化误差，但不改变任何顶点。
local function hovercraftPart(_,_,_,piece)
    if not piece then return "Body" end
    local c,s,lo=piece.center,piece.size,piece.min
    -- 1006/1000面两只真实桨毂+桨叶为完整连通件；护圈/撑杆保持Body。
    if lo.x>-.39 and c.x<-.10 and c.y>.09 and c.y<.15 and s.y>.24 and s.z>.23 then
        return c.z>0 and "FanP" or "FanN"
    end
    -- 船首侧喷口为完整独立的圆筒连通件（112/97面），绝不把方向盘当喷口。
    if c.x>.32 and c.x<.46 and c.y>-.125 and c.y<-.075 and s.y>.024 and s.x>.025 and s.x<.06 then
        return "Nozzle"
    end
    return "Body"
end

local function centipedePart(_,_,_,piece)
    if not piece then return "Body" end
    local c,s=piece.center,piece.size
    -- 长身机的+Z侧是抬起的蝎尾，源-X尾端是躯干末节，不能误认。
    if c.z>.22 and c.y>-.08 then return "Tail" end
    -- 两侧六站步足相对源躯干中心Z=-.09，而不是相对Z=0。
    if c.y<.065 and s.x<.13 and (c.z<-.15 or (c.z>.015 and c.z<.22)) then
        local stations={-.24,-.14,.045,.15,.29,.41}
        local station,best=1,math.huge
        for i,x in ipairs(stations) do if abs(c.x-x)<best then station,best=i,abs(c.x-x) end end
        return "Leg"..(c.z>-.09 and "P" or "N")..station
    end
    return "Body"
end

local function buggyPart(_,_,_,piece)
    if not piece then return "Body" end
    local c,s=piece.center,piece.size
    -- 轮胎/轮毂的源连通件都位于 |Z|>.25、Y<-.05；悬架和车架保留Body。
    if abs(c.z)>.25 and c.y<-.05 then
        local axle=c.x>.12 and "Front" or (c.x<-.12 and "Rear" or nil)
        if axle then return "Wheel"..axle..(c.z>0 and "P" or "N") end
    end
    return "Body"
end

local function loaderPart(_,_,_,piece)
    if not piece then return "Body" end
    local c,s=piece.center,piece.size
    if abs(c.z)>.08 and c.y<-.045 and abs(c.x)>.08 and abs(c.x)<.35 then
        return "Wheel"..(c.x>0 and "Front" or "Rear")..(c.z>0 and "P" or "N")
    end
    -- 铲斗是+X端、低位且横向展开的原始连通件；臂在其后方独立归组。
    if c.x>.30 and c.y<-.06 then return "Bucket" end
    if c.x>.075 and c.x<.34 and c.y<.18 then return "Arm" end
    return "Body"
end

local function cicadaPart(x,y,z,piece)
    if not piece then return "Body" end
    local c,s,lo,hi=piece.center,piece.size,piece.min,piece.max
    if c.x<-.30 and lo.y>.19 then return "WindupKey" end
    -- 12540面最大连通件把真实翼壳、躯干与后足焊在一起。
    -- 仅在该大件的实测翼根侧分配原面：不生成切口盖面、不焊接、不重写VB。
    if s.x>.8 and s.z>.8 then
        local wingTop=.075-.33*x
        if x<.15 and x>-.46 and y>wingTop-.055 and abs(z)>.045 then
            return z>0 and "WingP" or "WingN"
        end
        if x<-.045 and y<-.13 and abs(z)>.22 then return z>0 and "FootP1" or "FootN1" end
        return "Body"
    end
    -- 独立的四条前/中足，铰接圆球和边侧连杆一并进入同侧足；翼不再误用足网格。
    if hi.y<-.12 and (c.z<-.12 or c.z>.12) and s.x>.10 and s.z>.16 then
        return "Foot"..(c.z>0 and "P" or "N")..(c.x>.27 and "3" or "2")
    end
    if c.y<-.14 and abs(c.z)>.20 and s.x<.09 then
        return "Foot"..(c.z>0 and "P" or "N")..(c.x<0 and "1" or (c.x>.27 and "3" or "2"))
    end
    return "Body"
end

local selectors={hovercraft=hovercraftPart,centipede=centipedePart,buggy=buggyPart,loader=loaderPart,cicada=cicadaPart}

local function selectorFor(id)
    local selector=selectors[id]
    if not selector then error("未注册真实新车拆件："..id) end
    return selector
end
local function requiredFor(id) return M.GetConfig(id).joints end
---@param id string
---@param name string
---@param model Model
---@return Vector3
local function pivotFor(id,name,model)
    local c=M.GetConfig(id)
    if c.pivot[name] then return c.pivot[name] end
    if id=="centipede" and name:match("^Leg") then
        local side=name:find("P",1,true) and 1 or -1
        local station=tonumber(name:match("(%d)$"))
        if not station then station=1 end
        ---@type number[]
        local xs={-.24,-.14,.045,.15,.29,.41}
        local clamped=math.max(1,math.min(#xs,station))
        ---@type number
        local x=xs[clamped]
        return V(x,-.05,side==1 and .025 or -.175)
    end
    if id=="cicada" and name:match("^Foot") then
        local side=name:find("P",1,true) and 1 or -1
        local station=tonumber(name:match("(%d)$"))
        if not station then station=1 end
        ---@type number[]
        local xs={.12,.27,.39}
        local clamped=math.max(1,math.min(#xs,station))
        ---@type number
        local x=xs[clamped]
        return V(x,-.12,side*.18)
    end
    if name:match("^WheelFront") then return V(.3,-.19,name:find("P",1,true) and .18 or -.18) end
    if name:match("^WheelRear") then return V(-.3,-.19,name:find("P",1,true) and .18 or -.18) end
    return model.boundingBox.center
end

local function rememberRest(node)
    node:SetVar("RestPosition",Variant(node.position))
    node:SetVar("RestRotation",Variant(node.rotation))
end

---@param canonical Node
---@param id string
---@param source Model
---@param material Material
function M.Build(canonical,id,source,material)
    local config=M.GetConfig(id)
    local parts=Parts.Extract(source,"new_vehicle_articulation_v1_"..id,selectorFor(id),true)
    assert(parts.Body,"真实新车必须保留Body原网格："..id)
    for _,name in ipairs(requiredFor(id)) do assert(parts[name],"真实原网格未测得关节："..id.."/"..name) end
    ---@type table<string,Node>
    local joints={}
    for name,part in pairs(parts) do
        local pivot=canonical:CreateChild(name)
        local center=pivotFor(id,name,part.model)
        pivot.position=center
        rememberRest(pivot)
        local mesh=pivot:CreateChild("OriginalMesh")
        mesh.position=-center
        local draw=mesh:CreateComponent("StaticModel")
        draw:SetModel(part.model)
        draw:SetMaterial(material)
        draw.castShadows=true
        draw.lodBias=2
        joints[name]=pivot
        -- 逐LOD确认每个拆件仍直接引用源VB；IndexBuffer只保存原三角面索引。
        for lod=0,source:GetNumGeometryLodLevels(0)-1 do
            local original=assert(source:GetGeometry(0,lod),"缺少源LOD"..lod)
            local geometry=assert(part.model:GetGeometry(0,lod),name.."缺少LOD"..lod)
            assert(geometry:GetVertexBuffer(0)==original:GetVertexBuffer(0),id.."/"..name.."禁止复制VB")
            assert(geometry.primitiveType==TRIANGLE_LIST,"拆件必须保留三角面")
        end
    end
    -- 铲斗随臂的父子层级仍只改变pivot，不改变原始网格；复位位置改为臂局部坐标。
    if id=="loader" then
        local arm,bucket=joints.Arm,joints.Bucket
        bucket:SetParent(arm)
        local rest=config.pivot.Bucket-config.pivot.Arm
        bucket.position=rest
        bucket:SetVar("RestPosition",Variant(rest))
    end
    canonical:SetVar("ArticulationReady",Variant(true))
    canonical:SetVar("ArticulationId",Variant(id))
    canonical:SetVar("OriginalRotation",Variant(config.rotation))
    canonical:SetVar("MeasuredSize",Variant(config.measuredSize))
    canonical:SetVar("OrientedSize",Variant(config.orientedSize))
    return canonical
end

local jointCache=setmetatable({},{__mode="k"})
local function joint(root,name)
    local map=jointCache[root]
    if not map then map={};jointCache[root]=map end
    local cached=map[name]
    if cached then return cached end
    local node=assert(root:GetChild(name,true),"真实关节丢失："..name)
    local rest=node:GetVar("RestPosition"):GetVector3()
    cached={node=node,rest=rest}
    map[name]=cached
    return cached
end
local function resetPose(root,id)
    for _,name in ipairs(requiredFor(id)) do
        local j=joint(root,name)
        j.node.position=j.rest
        j.node.rotation=Quaternion.IDENTITY
    end
end
local function bounded(value,lo,hi) return math.max(lo,math.min(hi,value)) end
local function numberState(state,key,default)
    local value=state and state[key]
    return type(value)=="number" and value or default
end
local function phaseIs(state,...)
    local phase=state and state.oddPhase
    for i=1,select("#",...) do if phase==select(i,...) then return true end end
    return false
end

---@param root Node
---@param id string
---@param time number
---@param state table?
function M.Animate(root,id,time,state)
    local config=M.GetConfig(id)
    local distance=numberState(state,"distance",0)
    -- config is intentionally read here so integration can assert the same canonical orientation.
    local paused=state and (state.paused==true or state.pause==true)
    if paused then return end
    resetPose(root,id)
    if id=="hovercraft" then
        -- 双风扇只在行驶里程变化时转动；停驶时保留当前帧姿态，不按墙钟继续跑。
        local fanAngle=distance/.11*180/math.pi
        for _,name in ipairs({"FanP","FanN"}) do joint(root,name).node.rotation=Quaternion(fanAngle,V.RIGHT) end
        local jetSide=numberState(state,"oddJetSide",0)
        local jetSpeed=numberState(state,"oddJetLateralSpeed",0)
        local jetDistance=numberState(state,"oddJetDistance",0)
        local nozzle=joint(root,"Nozzle")
        nozzle.node.rotation=Quaternion(0,bounded(jetSpeed*.8,-25,25),0)
        nozzle.node.position=nozzle.rest+V(0,0,bounded(jetDistance*.02,-.06,.06)*jetSide)
        return
    end
    if id=="centipede" then
        local phase=distance/1.05*math.pi*2
        local windup=phaseIs(state,"tail_windup","tail_sweep","tail_recover")
        local tail=joint(root,"Tail")
        if windup then tail.node.rotation=Quaternion(0,math.sin(numberState(state,"oddAge",0)*8)*22,0) end
        local hitPulse=phaseIs(state,"tail_sweep") and math.sin(numberState(state,"oddAge",0)*18)*10 or 0
        for sideIndex,side in ipairs({"P","N"}) do
            local sign=side=="P" and 1 or -1
            for station=1,6 do
                local stride=math.sin(phase+((station+sideIndex)%2)*math.pi)
                local lift=-math.max(0,stride)*7*sign
                local leg=joint(root,"Leg"..side..station)
                leg.node.rotation=Quaternion(stride*11+hitPulse*sign,V.UP)*Quaternion(lift,V.RIGHT)
            end
        end
        return
    end
    if id=="buggy" then
        local roll=distance/.16*180/math.pi
        local steer=bounded(numberState(state,"steer",0),-1,1)
        local front=steer*28
        local rear=-steer*16
        for _,entry in ipairs({{"WheelFrontP",front},{"WheelFrontN",front},{"WheelRearP",rear},{"WheelRearN",rear}}) do
            local wheel=joint(root,entry[1])
            wheel.node.rotation=Quaternion(0,entry[2],0)*Quaternion(roll,V.FORWARD)
        end
        return
    end
    if id=="loader" then
        local roll=distance/.17*180/math.pi
        local steer=bounded(numberState(state,"steer",0),-1,1)
        for _,name in ipairs({"WheelFrontP","WheelFrontN"}) do joint(root,name).node.rotation=Quaternion(0,steer*18,0)*Quaternion(roll,V.FORWARD) end
        for _,name in ipairs({"WheelRearP","WheelRearN"}) do joint(root,name).node.rotation=Quaternion(0,-steer*10,0)*Quaternion(roll,V.FORWARD) end
        local age=numberState(state,"oddAge",0)
        local armLift=0
        if phaseIs(state,"scoop_windup","scoop_lift","scoop_release","scoop_recover") then
            if phaseIs(state,"scoop_windup") then armLift=bounded(age/.20,0,1)*18
            elseif phaseIs(state,"scoop_lift") then armLift=18+math.sin(bounded((age-.20)/.36,0,1)*math.pi)*34
            elseif phaseIs(state,"scoop_release") then armLift=52-bounded((age-.56)/.18,0,1)*20
            else armLift=32*(1-bounded((age-.74)/.28,0,1)) end
        end
        local arm=joint(root,"Arm")
        -- 铲车臂沿源+X伸展，实测抬升轴为源Z（FORWARD），不是横向RIGHT。
        arm.node.rotation=Quaternion(-armLift,V.FORWARD)
        local bucket=joint(root,"Bucket")
        local bucketTilt=phaseIs(state,"scoop_lift","scoop_release") and 18 or 0
        bucket.node.rotation=Quaternion(bucketTilt,V.FORWARD)
        return
    end
    if id=="cicada" then
        local age=numberState(state,"oddAge",0)
        local key=joint(root,"WindupKey")
        local windup=phaseIs(state,"wound","wound_release","exhausted") or numberState(state,"oddSpring",0)>0
        if windup then key.node.rotation=Quaternion(0,age*220%360,0) end
        local wing=phaseIs(state,"dash","landing_boost") and math.sin(age*30)*18 or 0
        for _,name in ipairs({"WingP","WingN"}) do joint(root,name).node.rotation=Quaternion(wing,name=="WingP" and V.FORWARD or -V.FORWARD) end
        local phase=distance/.94*math.pi*2
        for sideIndex,side in ipairs({"P","N"}) do
            local sign=side=="P" and 1 or -1
            for station=1,3 do
                local stride=math.sin(phase+((station+sideIndex)%2)*math.pi)
                local foot=joint(root,"Foot"..side..station)
                foot.node.rotation=Quaternion(stride*9,V.UP)*Quaternion(-math.max(0,stride)*5*sign,V.RIGHT)
            end
        end
    end
end

return M
