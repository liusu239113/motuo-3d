-- 独立可渲染3D几何体，不使用图片冒充载具；共享基础网格与材质降低批次数。
-- 沿用3D场景脚手架的父子节点结构；玩家、车库、AI共用同一套模型。
local P = require("Parts")
local Data = require("MixedVehicles")
local V = Vector3
local M = {}
local palette = {}
local function materials()
    if palette.dark then return palette end
    palette.dark=P.Material(.045,.065,.085,.72,.25)
    palette.rubber=P.Material(.018,.025,.03,.94,0)
    palette.steel=P.Material(.4,.48,.55,.36,.75)
    palette.gold=P.Material(.96,.57,.08,.38,.5)
    palette.red=P.Material(.85,.08,.045,.48,.2)
    palette.green=P.Material(.27,.52,.12,.6,.2)
    palette.cyan=P.Material(.04,.73,.86,.35,.25,.15)
    palette.blue=P.Material(.12,.26,.78,.45,.25)
    palette.white=P.Material(.9,.93,.9,.3,.06)
    palette.wood=P.Material(.48,.24,.09,.8,0)
    palette.purple=P.Material(.62,.12,.81,.38,.15)
    palette.eye=P.Material(.02,.035,.05,.25,.1)
    palette.glow=P.Material(.15,.8,1,.35,.1,1.4)
    local glass=Material:new()
    glass:SetTechnique(0,cache:GetResource("Technique","Techniques/PBR/PBRNoTextureAlpha.xml"))
    glass:SetShaderParameter("MatDiffColor",Variant(Color(.22,.8,.95,.62)))
    glass:SetShaderParameter("Roughness",Variant(.2))
    palette.glass=glass
    return palette
end
local function box(root,name,mat,x,y,z,w,h,d,rot)
    return P.Add(root,name,"Box",mat,V(x,y,z),V(w,h,d),rot)
end
local function ball(root,name,mat,x,y,z,w,h,d)
    return P.Add(root,name,"Sphere",mat,V(x,y,z),V(w,h,d))
end
local function bar(root,mat,a,b,r) return P.Bar(root,mat,a,b,r) end
local function wheel(root,x,y,z,r,width)
    local m=materials()
    P.Add(root,"Wheel","Cylinder",m.rubber,V(x,y,z),V(r*2,width,r*2),Quaternion(0,0,90))
    P.Add(root,"Hub","Cylinder",m.steel,V(x+(x<0 and -.02 or .02),y,z),V(r*.95,width+.025,r*.95),Quaternion(0,0,90))
end
local function seat(root,y,z)
    local m=materials()
    box(root,"Seat",m.dark,0,y,z,.6,.16,.65)
    box(root,"SeatBack",m.dark,0,y+.35,z-.3,.6,.6,.12)
end
local function pilot(root,y,z,standing)
    local m=materials()
    local pelvis=V(0,y,z)
    ball(root,"PilotHelmet",m.gold,0,y+.66,z,.36,.38,.36)
    box(root,"PilotVisor",m.eye,0,y+.69,z+.17,.27,.13,.065)
    ball(root,"PilotJacket",m.blue,0,y+.26,z,.42,.52,.3)
    for _,s in ipairs({-1,1}) do
        local knee=V(s*.2,y-(standing and .34 or .12),z+.24)
        local foot=V(s*.21,y-(standing and .72 or .46),z+.34)
        bar(root,m.dark,pelvis+V(s*.12,0,0),knee,.085)
        bar(root,m.dark,knee,foot,.07)
        box(root,"Boot",m.dark,foot.x,foot.y,foot.z+.06,.16,.12,.28)
        bar(root,m.blue,V(s*.19,y+.4,z),V(s*.32,y+.15,z+.34),.065)
        bar(root,m.dark,V(s*.32,y+.15,z+.34),V(s*.24,y+.2,z+.55),.055)
    end
end
local function jets(root,x,y,z)
    local m=materials()
    for _,s in ipairs({-1,1}) do
        P.Add(root,"JetNozzle","Cylinder",m.steel,V(s*x,y,z),V(.22,.35,.22),Quaternion(90,0,0))
        ball(root,"SkillFlame",m.glow,s*x,y,z-.3,.16,.16,.6)
    end
end
local function eyes(root,x,y,z)
    local m=materials()
    for _,s in ipairs({-1,1}) do
        ball(root,"EyeWhite",m.white,s*x,y,z,.28,.28,.26)
        ball(root,"Eye",m.eye,s*x,y,z+.12,.13,.16,.08)
    end
end
function M.Build(parent,id)
    local v=Data.Get(id)
    assert(v,"未知混合载具 "..tostring(id))
    local root=parent:CreateChild("Vehicle_"..id)
    local m=materials()
    if id=="tank" then
        box(root,"Hull",m.green,0,.64,0,1.85,.65,2.8)
        box(root,"FrontArmor",m.green,0,.7,1.25,1.85,.45,.5,Quaternion(-24,0,0))
        for _,s in ipairs({-1,1}) do
            box(root,"Track",m.rubber,s*.98,.38,0,.42,.64,2.9)
            for j=1,5 do wheel(root,s*1.05,.4,(j-3)*.54,.25,.16) end
            for j=1,12 do box(root,"TrackTread",m.steel,s*.98,.72,(j-6.5)*.23,.46,.045,.1) end
        end
        box(root,"Turret",m.green,0,1.1,-.12,1.15,.42,1.1)
        P.Add(root,"Cannon","Cylinder",m.steel,V(0,1.22,1.06),V(.16,1.7,.16),Quaternion(90,0,0))
        seat(root,1.37,-.42);pilot(root,1.52,-.42)
        jets(root,.6,.67,-1.45)
    elseif id=="beetle" then
        ball(root,"Shell",m.green,0,.78,-.1,1.65,1.2,2.2)
        box(root,"ShellSeam",m.gold,0,1.39,-.1,.055,.035,1.7)
        ball(root,"Head",m.dark,0,.65,1,1.2,.7,.85)
        for _,s in ipairs({-1,1}) do
            local jaw=root:CreateChild(s==1 and "JawRight" or "JawLeft")
            jaw.position=V(s*.42,.7,1.25)
            bar(jaw,m.steel,V.ZERO,V(s*.22,0,.6),.14)
            bar(jaw,m.steel,V(s*.22,0,.6),V(-s*.2,.03,1),.11)
            for j=1,3 do
                local z=(j-2)*.7
                bar(root,m.dark,V(s*.65,.65,z),V(s*1.03,.4,z+.12),.08)
                bar(root,m.gold,V(s*1.03,.4,z+.12),V(s*1.05,.08,z+.45),.055)
            end
            P.Add(root,"SteamPipe","Cylinder",m.gold,V(s*.55,1.3,-.7),V(.15,.8,.15))
        end
        ball(root,"Boiler",m.steel,0,1.3,-.6,.65,.5,.7)
        eyes(root,.36,.85,1.37);seat(root,1.35,.1);pilot(root,1.5,.1)
    elseif id=="centipede" then
        for j=1,7 do
            local segment=root:CreateChild("Segment"..j)
            segment.position=V(0,.55,(j-4)*.53)
            ball(segment,"MetalShell",j%2==0 and m.red or m.dark,0,0,0,1.1,.65,.7)
            for _,s in ipairs({-1,1}) do
                bar(segment,m.steel,V(s*.4,0,0),V(s*.85,-.18,.15),.07)
                bar(segment,m.gold,V(s*.85,-.18,.15),V(s*.95,-.48,.3),.05)
                wheel(segment,s*.55,.1,0,.19,.09)
            end
        end
        eyes(root,.28,.82,1.95)
        bar(root,m.gold,V(-.25,.8,1.9),V(-.65,1.25,2.18),.04)
        bar(root,m.gold,V(.25,.8,1.9),V(.65,1.25,2.18),.04)
        seat(root,1,-.25);pilot(root,1.15,-.25)
    elseif id=="hovercraft" then
        ball(root,"AirSkirt",m.rubber,0,.3,0,2.15,.6,3)
        ball(root,"Deck",m.gold,0,.65,0,1.95,.4,2.6)
        box(root,"Cabin",m.cyan,0,.97,.2,1.1,.55,1.25)
        box(root,"Windshield",m.glass,0,1.1,.85,.92,.36,.04,Quaternion(-20,0,0))
        local fan=root:CreateChild("Rotor");fan.position=V(0,1.15,-1.05)
        for _,a in ipairs({0,90}) do box(fan,"FanBlade",m.steel,0,0,0,1.3,.08,.1,Quaternion(0,0,a)) end
        seat(root,1.1,-.1);pilot(root,1.25,-.1)
    elseif id=="buggy" then
        box(root,"Chassis",m.dark,0,.4,0,1.3,.2,2.2)
        box(root,"Hood",m.red,0,.68,.65,1.1,.35,1)
        for _,s in ipairs({-1,1}) do
            wheel(root,s*.78,.38,.83,.38,.32);wheel(root,s*.78,.38,-.83,.38,.32)
            bar(root,m.gold,V(s*.58,.48,-.85),V(s*.58,1.62,-.55),.055)
            bar(root,m.gold,V(s*.58,1.62,-.55),V(s*.58,1.62,.5),.055)
            bar(root,m.gold,V(s*.58,1.62,.5),V(s*.58,.48,.85),.055)
        end
        bar(root,m.gold,V(-.58,1.62,-.55),V(.58,1.62,-.55),.055)
        bar(root,m.gold,V(-.58,1.62,.5),V(.58,1.62,.5),.055)
        seat(root,.73,-.18);pilot(root,.88,-.18);jets(root,.4,.5,-1.15)
    elseif id=="jellyfish" then
        ball(root,"FloatingBell",m.glass,0,2.1,0,2.1,1.3,2.1)
        ball(root,"BellCore",m.purple,0,2.15,0,.65,.45,.65)
        for j=1,8 do
            local a=j*math.pi/4
            local x,z=math.sin(a)*.78,math.cos(a)*.78
            local t=root:CreateChild("Tentacle"..j)
            t.position=V(x,1.8,z)
            bar(t,m.cyan,V.ZERO,V(x*.15,-.65,z*.15),.045)
            bar(t,m.cyan,V(x*.15,-.65,z*.15),V(-x*.12,-1.2,-z*.12),.035)
        end
        box(root,"PassengerPlatform",m.steel,0,.35,0,1.25,.14,1.3)
        seat(root,.57,0);pilot(root,.72,0)
    elseif id=="loader" then
        box(root,"EngineBody",m.gold,0,.7,-.35,1.5,.8,1.65)
        box(root,"Cabin",m.dark,0,1.4,-.25,1.1,.85,1)
        for _,s in ipairs({-1,1}) do
            wheel(root,s*.86,.4,.7,.4,.32);wheel(root,s*.86,.4,-.9,.4,.32)
            bar(root,m.gold,V(s*.6,.7,.35),V(s*.65,.95,1.2),.1)
        end
        local scoop=root:CreateChild("Scoop");scoop.position=V(0,.38,1.18)
        box(scoop,"BucketFloor",m.gold,0,0,.28,1.95,.13,.9)
        box(scoop,"BucketBack",m.gold,0,.27,-.1,1.95,.58,.12)
        for _,s in ipairs({-1,1}) do box(scoop,"BucketSide",m.gold,s*.94,.23,.25,.1,.47,.86) end
        seat(root,1.1,-.25);pilot(root,1.25,-.25)
    elseif id=="cicada" then
        ball(root,"WoodBody",m.wood,0,.7,0,1.1,.9,2.2)
        for _,s in ipairs({-1,1}) do
            ball(root,"WoodWing",m.gold,s*.5,1,-.25,.6,.15,1.95)
            for j=1,3 do bar(root,m.dark,V(s*.35,.6,(j-2)*.62),V(s*.86,.06,(j-2)*.62+.2),.055) end
        end
        local key=root:CreateChild("ClockKey");key.position=V(0,1.35,-.65)
        box(key,"KeyStem",m.steel,0,0,0,.12,.55,.12)
        for _,s in ipairs({-1,1}) do ball(key,"KeyHandle",m.gold,s*.22,.25,0,.4,.26,.12) end
        eyes(root,.35,.85,1);seat(root,1.15,.15);pilot(root,1.3,.15)
    elseif id=="jetboat" or id=="sled" then
        ball(root,"Hull",id=="jetboat" and m.red or m.blue,0,.48,0,1.35,.65,2.8)
        for _,s in ipairs({-1,1}) do
            box(root,"SkiRunner",m.steel,s*.6,.1,0,.12,.15,2.9)
            box(root,"SkiTip",m.steel,s*.6,.2,1.35,.12,.15,.6,Quaternion(-28,0,0))
        end
        box(root,"Windshield",m.glass,0,.88,.58,.9,.42,.08,Quaternion(-25,0,0))
        seat(root,.76,-.22);pilot(root,.91,-.22);jets(root,.38,.5,-1.35)
    elseif id=="frog" then
        ball(root,"FrogBody",m.green,0,.65,0,1.65,1.05,1.75)
        ball(root,"FrogHead",m.green,0,.94,.65,1.65,.8,1.05)
        eyes(root,.5,1.28,.98)
        box(root,"Mouth",m.dark,0,.76,1.13,.85,.04,.055)
        for _,s in ipairs({-1,1}) do
            ball(root,"HindLeg",m.green,s*.78,.4,-.65,.65,.65,.8)
            bar(root,m.green,V(s*.55,.55,.35),V(s*.9,.1,.8),.12)
            box(root,"FrogFoot",m.green,s*.9,.06,.85,.4,.1,.48)
        end
        for j=1,7 do
            local a=j*2.4
            P.Add(root,"Spine",ConeGeometry(.09,.32,7):ToModel(),m.gold,V(math.sin(a)*.57,1.15,-.55+(j%3)*.4))
        end
        seat(root,1.15,-.25);pilot(root,1.3,-.25)
    elseif id=="helicopter" then
        ball(root,"Fuselage",m.green,0,.85,.2,1.35,1.3,2.2)
        ball(root,"CockpitGlass",m.glass,0,.95,.9,1.15,.9,1.1)
        bar(root,m.green,V(0,.85,-.65),V(0,1.2,-2),.16)
        box(root,"TailFin",m.gold,0,1.4,-1.9,.1,.75,.55)
        for _,s in ipairs({-1,1}) do
            bar(root,m.steel,V(s*.55,.55,.45),V(s*.8,.15,.45),.04)
            bar(root,m.steel,V(s*.8,.15,-.9),V(s*.8,.15,1),.05)
            box(root,"WeaponPod",m.dark,s*.85,.75,.1,.25,.25,.85)
        end
        local rotor=root:CreateChild("Rotor");rotor.position=V(0,1.65,.1)
        P.Add(rotor,"RotorMast","Cylinder",m.steel,V(0,-.12,0),V(.13,.4,.13))
        for _,a in ipairs({0,90}) do box(rotor,"RotorBlade",m.dark,0,0,0,3.8,.035,.13,Quaternion(0,a,0)) end
        local tail=root:CreateChild("TailRotor");tail.position=V(.13,1.3,-1.95)
        box(tail,"TailBlade",m.dark,0,0,0,.05,.9,.1)
    elseif id=="skateboard" then
        ball(root,"Deck",m.red,0,.21,0,.55,.13,1.45)
        for _,s in ipairs({-1,1}) do wheel(root,s*.26,.11,-.45,.11,.09);wheel(root,s*.26,.11,.45,.11,.09) end
        pilot(root,.98,-.12,true)
    elseif id=="cart" then
        for _,s in ipairs({-1,1}) do wheel(root,s*.45,.15,-.5,.15,.1);wheel(root,s*.45,.15,.5,.15,.1) end
        box(root,"BasketBase",m.steel,0,.55,0,.95,.1,1.35)
        for _,s in ipairs({-1,1}) do
            for j=1,6 do bar(root,m.steel,V(s*.48,.58,(j-3.5)*.22),V(s*.55,1.15,(j-3.5)*.24),.022) end
            bar(root,m.gold,V(s*.55,1.15,-.7),V(s*.55,1.15,.7),.045)
        end
        for j=1,5 do bar(root,m.steel,V((j-3)*.22,.58,.65),V((j-3)*.25,1.15,.7),.022) end
        bar(root,m.red,V(-.52,1.35,-.85),V(.52,1.35,-.85),.06)
        seat(root,.9,-.1);pilot(root,1.05,-.1)
    elseif id=="bathtub" then
        ball(root,"BathShell",m.white,0,.55,0,1.3,.85,2.25)
        ball(root,"WaterSurface",m.cyan,0,.9,0,1.08,.12,1.95)
        for _,s in ipairs({-1,1}) do wheel(root,s*.53,.16,-.7,.16,.12);wheel(root,s*.53,.16,.7,.16,.12) end
        bar(root,m.gold,V(.4,.8,.8),V(.4,1.3,.8),.04)
        bar(root,m.gold,V(.4,1.3,.8),V(.15,1.3,.8),.04)
        pilot(root,.94,-.25)
    elseif id=="office" then
        P.Add(root,"ChairStem","Cylinder",m.steel,V(0,.48,0),V(.12,.6,.12))
        for j=1,5 do local a=j*math.pi*.4; local x,z=math.sin(a)*.52,math.cos(a)*.52
            bar(root,m.steel,V(0,.26,0),V(x,.15,z),.045);wheel(root,x,.1,z,.1,.08) end
        seat(root,.8,0);pilot(root,.95,0)
    elseif id=="toilet" then
        ball(root,"CeramicBowl",m.white,0,.72,.2,.95,.8,1.2)
        box(root,"Pedestal",m.white,0,.35,.05,.5,.7,.65)
        box(root,"Cistern",m.white,0,1.05,-.5,.85,.85,.4)
        box(root,"FlushButton",m.gold,.24,1.48,-.5,.15,.04,.1)
        for _,s in ipairs({-1,1}) do wheel(root,s*.48,.16,.4,.16,.12);wheel(root,s*.48,.16,-.45,.16,.12) end
        pilot(root,1.12,.1);jets(root,.53,.55,-.6)
    else -- 电动车：与原生涯相同的踏板车轮廓，不附加外卖任务。
        for _,z in ipairs({-.7,.72}) do wheel(root,0,.3,z,.3,.16) end
        box(root,"Battery",m.cyan,0,.52,-.12,.5,.5,.85)
        box(root,"Footboard",m.dark,0,.33,.17,.48,.12,1.05)
        bar(root,m.steel,V(0,.34,.72),V(0,1.15,.63),.065)
        bar(root,m.dark,V(-.4,1.15,.63),V(.4,1.15,.63),.045)
        ball(root,"Headlight",m.white,0,1.07,.7,.3,.23,.15)
        seat(root,.86,-.35);pilot(root,1,-.35)
    end
    root:SetVar("VehicleId",Variant(id))
    root:SetVar("VehicleSize",Variant(V(v.size[1] or 1,v.size[2] or 1,v.size[3] or 1)))
    return root
end
function M.Animate(root,id,time,state)
    local active=(state and state.oddActive or 0)>0
    for _,part in ipairs(root:GetChildren(true)) do
        local name=part.name
        if name=="Rotor" then part.rotation=Quaternion(0,time*1600%360,0)
        elseif name=="TailRotor" then part.rotation=Quaternion(time*1800%360,0,0)
        elseif name=="ClockKey" then part.rotation=Quaternion(0,time*120%360,0)
        elseif name:match("^Tentacle%d") then part.rotation=Quaternion(math.sin(time*3+#name)*12,0,math.cos(time*2+#name)*10)
        elseif name:match("^Segment%d") then part.rotation=Quaternion(0,math.sin(time*9+(tonumber(name:match("%d+")) or 0)) * 7,0)
        elseif name=="JawRight" or name=="JawLeft" then part.rotation=Quaternion(0,(name=="JawRight" and 1 or -1)*(active and 24 or math.sin(time*2)*4),0)
        elseif name=="Scoop" then part.rotation=Quaternion(active and -32 or 0,0,0)
        elseif name=="SkillFlame" then part.enabled=active end
    end
end
-- 轻量玩家适配器：沿用Bike公开生命周期，不创建错误的摩托骨骼或重复座舱。
local Adapter={};Adapter.__index=Adapter
function M.NewBike(scene,id)
    local self=setmetatable({},Adapter);self:Init(scene,id);return self
end
function Adapter:Init(scene,id)
    self.vehicleId=id;self.node=scene:CreateChild("Bike_"..id)
    self.visual=self.node:CreateChild("VehicleMotion");self.body=M.Build(self.visual,id)
    self.cockpit=self.visual:CreateChild("Cockpit");self.steering=self.cockpit:CreateChild("Steering")
    self.dashboardMarker=self.visual:CreateChild("Dashboard");self.dashboardMarker.position=V(0,1,.4)
    self.Cockpit={localOffset=V(0,2.6,-.3),pitch=8,fov=72,seatHeight=1,grip=V(.3,1,.4)}
    self.firstPerson,self.disposed,self.leanSign=false,false,1
    self.riderRig={visible=true,SetColor=function() return true end,Update=function() end,Dispose=function() end}
    self.mirrors={SetQuality=function() end,Update=function() end,Dispose=function() end}
    self.effects={pitch=0,bob=0,Dispose=function() end}
end
function Adapter:SetRiderColor(_) return true end
function Adapter:SetFirstPerson(_) self.firstPerson=false;self.cockpit.enabled=false end
function Adapter:SetQuality(_) end
function Adapter:UpdateMirrors(_,_) end
function Adapter:GetDashboardWorldPosition() return self.dashboardMarker.worldPosition end
function Adapter:GetCameraWorldPosition() return self.visual:LocalToWorld(self.Cockpit.localOffset) end
function Adapter:UpdateState(dt,sim,_,clock)
    if self.disposed then return end
    self.node.position=V(sim.x,sim.y,sim.z)
    self.node.rotation=Quaternion(0,sim.heading or sim.yaw,0)
    local id=self.vehicleId
    local roll=(sim.lean or 0)*((id=="tank" or id=="loader") and .08 or .25)
    if id=="tank" then roll=(sim.lean or 0)*.08 end
    self.visual.position=V(0,sim.oddAltitude or 0,0)
    self.visual.rotation=Quaternion((sim.pitch or 0)*.5,id=="office" and (sim.oddActive or 0)>0 and clock*650%360 or 0,roll)
    M.Animate(self.body,id,sim.elapsed or clock,sim)
    self:SetFirstPerson(false)
end
function Adapter:Dispose() if self.disposed then return end;self.disposed=true;self.node:Dispose() end
return M
