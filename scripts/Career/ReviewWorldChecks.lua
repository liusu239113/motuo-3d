-- -careerreviewfast 的有界世界专项路由；仅在隔离 Session 构建完成后显式调用。
-- 不调用 Render/HudLayoutChecks、世界长回归、构建或截图工具；业务新增项只使用内存隔离档。
local Checks={}

-- Exercise the actual Session cache at unchanged XZ; changing only World's
-- route function would not catch a cache key that forgot support layer / mode.
---@param session CareerSession
---@return boolean
function Checks.TargetLayers(session)
    assert(session.options and session.options.test==true and type(session.restoreTestStorage)=="function",
        "TargetLayers requires an isolated test Session")
    local World=require("Career.WorldData")
    local Config=require("Career.Config")
    local actor,city=assert(session.actor),assert(session.city)
    local bridge=assert(World.Bridges[1],"missing bridge fixture") --[[@as {id:string,x:number,z:number,y:number}]]
    local old={navigation=session.navigation,waypoint=session.waypoint,manual=session.manualWaypoint,
        space=session.space,citySpace=city.space,x=actor.x,z=actor.z,height=actor.walkHeight,mounted=actor.mounted}
    local function sameRoute(actual,expected)
        assert(#actual==#expected and #actual>1,"Session.Target route differs from production navigation")
        for i,p in ipairs(expected) do
            local a=actual[i]
            assert(math.abs(a.x-p.x)+math.abs(a.z-p.z)<.000001 and a.layer==p.layer,
                "Session.Target retained stale route coordinates / layer")
            assert(a.y==p.y or a.y and p.y and math.abs(a.y-p.y)<.000001,"Session.Target retained stale support height")
        end
    end
    local ok,err=pcall(function()
        session.navigation={key="",route={}}
        session.waypoint,session.manualWaypoint="breakfast",true
        session.space,city.space="city","city"
        actor.x,actor.z=bridge.x,bridge.z
        actor.walkHeight,actor.mounted=bridge.y,false
        local top=session:Target()
        assert(top,"bridge target missing")
        local topKey=session.navigation.key
        local destination=assert(Config.points.breakfast)
        assert(top.pointId=="breakfast" and top.route[1].layer=="bridge:"..bridge.id,"Session.Target did not use bridge support")
        sameRoute(top.route,assert(World.NavigationRoute(actor.x,actor.z,destination.x,destination.z,bridge.y,"bridge:"..bridge.id)))
        assert(session:Target().route==top.route,"unchanged bridge target needlessly rebuilt cache")

        actor.walkHeight=city:Surface(actor.x,actor.z)
        local below=session:Target()
        assert(below,"ground target missing")
        local belowKey=session.navigation.key
        assert(belowKey~=topKey and below.route~=top.route,"same-XZ bridge-to-ground did not invalidate Session.Target cache")
        sameRoute(below.route,assert(World.NavigationRoute(actor.x,actor.z,destination.x,destination.z,actor.walkHeight,"ground")))
        for _,p in ipairs(below.route) do assert(p.layer==nil or p.layer=="ground","ground target retained bridge ramp route") end

        -- A stale bridge-height value must not turn mounted navigation into a
        -- pedestrian ramp route. Only mode changes here, not world position.
        actor.walkHeight,actor.mounted=bridge.y,true
        local riding=session:Target()
        assert(riding,"mounted target missing")
        assert(session.navigation.key~=belowKey and session.navigation.key~=topKey and riding.route~=below.route,
            "same-XZ walk-to-vehicle did not invalidate Session.Target cache")
        sameRoute(riding.route,assert(World.NavigationRoute(actor.x,actor.z,destination.x,destination.z,bridge.y,"ground")))
        assert(session:Target().route==riding.route,"unchanged mounted target needlessly rebuilt cache")
    end)
    session.navigation,session.waypoint,session.manualWaypoint=old.navigation,old.waypoint,old.manual
    session.space,city.space=old.space,old.citySpace
    actor.x,actor.z,actor.walkHeight,actor.mounted=old.x,old.z,old.height,old.mounted
    assert(ok,tostring(err))
    print("[Session.Target分层缓存通过] 同XZ桥顶/桥下/骑行三态真实路线更新，重复调用复用；navigation/actor/waypoint/space已恢复，无Teleport/流式推进")
    return true
end

---@param session CareerSession
---@return boolean
function Checks.Run(session)
    assert(session.options and session.options.test==true and type(session.restoreTestStorage)=="function",
        "ReviewWorldChecks requires an isolated test Session; never a player save")
    assert(session.city and session.actor and session.traffic and session.view,"reviewfast requires a fully initialized world")
    session.view:ClosePhone()
    session.view:ShowGame()
    assert(session.city.space=="city","reviewfast requires city space")

    local started=os.clock()
    local function run(label,check)
        local began=os.clock()
        print("[世界快速专项] BEGIN "..label)
        check()
        print(string.format("[世界快速专项] PASS %s CPU %.6fs",label,os.clock()-began))
    end
    local TrafficChecks=require("Career.TrafficChecks")
    run("Camera.Support",function() require("Career.CameraCollision").Checks(session) end)
    run("Traffic.Riders",function() TrafficChecks.Riders(session) end)
    run("Traffic.Layers",function() TrafficChecks.Layers(session) end)
    run("Traffic.ParkingRestore",function() TrafficChecks.ParkingRestore(session) end)
    run("SoundCrowd.Layers",function() require("Career.SoundCrowdChecks").Layers(session) end)
    run("Environment.BoundaryCollision",function() require("Career.CityEnvironmentChecks").BoundaryCollision(session) end)
    run("SubjectVisual.State",function() require("Career.SubjectVisualChecks").Run(session) end)
    run("World.NavigationPlan",function() require("Career.WorldChecks").NavigationPlan() end)
    run("Session.TargetLayers",function() Checks.TargetLayers(session) end)
    run("Outer.SnapshotPlan",function() require("Career.OuterChecks").SnapshotPlan() end)
    run("Traffic.SnapshotPlan",function() TrafficChecks.SnapshotPlan() end)
    run("DeliveryMarker.Support",function() require("Career.DeliveryMarkerChecks").Support(session) end)
    run("DeliveryMarker.Run",function() require("Career.DeliveryMarkerChecks").Run(session) end)
    run("Engagement.World",function() require("Career.EngagementWorldChecks").Run(session) end)
    print(string.format("[世界快速专项通过] 14项 CPU %.6fs；未调用Render/长世界回归，新增业务仅内存档；主体材质状态不代替视觉验收",os.clock()-started))
    return true
end

return Checks
