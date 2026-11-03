-- 道路机关实景：所有可见路障、金币与地形色带来自同一份判定数据。
local P=require("Parts")
local Rules=require("MixedRace")
local V=Vector3
local M={}
function M.Build(world)
    local root=world.root:CreateChild("混合赛道机关")
    local orange=P.Material(.95,.37,.035,.8)
    local dark=P.Material(.035,.045,.055,.9)
    local yellow=P.Material(.96,.73,.08,.55,.1,.15)
    local steel=P.Material(.35,.42,.46,.5,.6)
    local wood=P.Material(.43,.24,.1,.9)
    world.mixedObstacles=Rules.CreateCourse(world.landscape)
    world.mixedCoins={}
    for _,o in ipairs(world.mixedObstacles) do
        local node=root:CreateChild("Obstacle_"..o.kind..o.id)
        node.position=V(o.x,o.y+.03,o.z);node.rotation=Quaternion(0,o.yaw,0);o.node=node
        if o.kind=="oil" then
            P.Add(node,"OilPatch","Sphere",dark,V(0,.025,0),V(2.6,.06,4),nil,false)
            for j=1,3 do P.Add(node,"OilSheen","Box",steel,V((j-2)*.5,.065,0),V(.12,.015,2.8),Quaternion(0,25,0),false) end
        elseif o.kind=="pendulum" then
            for _,s in ipairs({-1,1}) do
                P.Add(node,"Stand","Box",yellow,V(s*1.65,2.2,0),V(.14,4.4,.14))
            end
            P.Add(node,"Crossbar","Box",steel,V(0,4.4,0),V(3.5,.14,.14))
            local arm=node:CreateChild("SwingArm")
            arm.position=V(0,4.3,0)
            P.Add(arm,"Chain","Cylinder",steel,V(0,-1.3,0),V(.06,2.6,.06))
            P.Add(arm,"Hammer","Sphere",orange,V(0,-2.8,0),V(1.25,1.25,1.25))
        elseif o.kind=="cone" then
            P.Add(node,"Cone",ConeGeometry(.5,1,12):ToModel(),orange,V(0,.5,0))
            P.Add(node,"Base","Box",dark,V(0,.05,0),V(1.2,.1,1.2))
        elseif o.kind=="barrel" then
            P.Add(node,"Barrel","Cylinder",orange,V(0,.5,0),V(1,1,1))
            for _,h in ipairs({.22,.75}) do P.Add(node,"SteelBand","Cylinder",steel,V(0,h,0),V(1.04,.06,1.04)) end
        elseif o.kind=="barrier" then
            P.Add(node,"Roadblock","Box",orange,V(0,.5,0),V(1.3,1,1.2))
            for j=1,4 do P.Add(node,"WarningStripe","Box",yellow,V((j-2.5)*.3,.55,-.61),V(.13,.8,.025),Quaternion(0,0,-25),false) end
        else
            P.Add(node,"Crate","Box",wood,V(0,.5,0),V(1.3,1,1.2))
            for _,s in ipairs({-1,1}) do P.Add(node,"CrateBrace","Box",yellow,V(s*.4,.5,-.61),V(.1,1,.04),nil,false) end
        end
        -- 提前25米的警示牌在障碍同侧，安全通道保留在另一侧。
        local p,yaw=world.landscape.TrafficPose(o.s-25,o.lane)
        P.Add(root,"ApproachWarning","Box",yellow,p+V(0,.035,0),V(.7,.025,2),Quaternion(0,yaw,0),false)
        local cp=world.landscape.TrafficPose(o.s+15,-o.lane*.8)
        local coin={x=cp.x,y=cp.y+.7,z=cp.z,active=true}
        coin.node=P.Add(root,"TrackCoin","Cylinder",yellow,V(coin.x,coin.y,coin.z),V(.6,.12,.6),Quaternion(90,0,0),false)
        world.mixedCoins[#world.mixedCoins+1]=coin
    end
    local colors={gravel=P.Material(.38,.33,.24,.96),water=P.Material(.08,.37,.52,.38),
        mud=P.Material(.25,.14,.07,.95),slime=P.Material(.27,.54,.12,.65),ice=P.Material(.48,.72,.85,.28),
        dry=P.Material(.62,.43,.23,.95),wind=P.Material(.38,.4,.48,.8)}
    for s=0,world.landscape.RouteLength-8,8 do
        local terrain=Rules.Terrain(world.landscape,s,0)
        local mat=colors[terrain]
        if mat then
            local p,yaw,pitch=world.landscape.TrafficPose(s+4,0)
            local half=world.landscape.Roads[1].width
            P.Add(root,"Terrain_"..terrain,"Box",mat,p+V(0,.018,0),V(half*2-.4,.025,8.1),Quaternion(pitch,yaw,0),false)
        end
    end
    for _,model in ipairs(root:GetComponents("StaticModel",true)) do model.drawDistance=230;model.shadowDistance=60 end
    world.mixedRoot=root
    print(string.format("[混合赛道] %d障碍 / %d金币 / 碎石、涉水、粘液、风区随赛道布置",#world.mixedObstacles,#world.mixedCoins))
end
function M.Update(world,clock)
    for _,o in ipairs(world.mixedObstacles or {}) do
        if o.kind=="pendulum" and o.node then
            local arm=o.node:GetChild("SwingArm")
            if arm then arm.rotation=Quaternion(0,0,math.sin(clock*1.7+o.phase)*32) end
            -- 扫掠判定只在锤头进入中央车道时启用，支架不挡整路。
            o.active=math.abs(math.sin(clock*1.7+o.phase))<.52
        end
    end
end
return M
