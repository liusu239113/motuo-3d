-- 基于scaffold-3d-scene的隔离验收：正式导弹+生产HUD方法，不初始化Profile、不读写存档。
local Skill = require("SkillPresentation")
local HUD = require("HUD")
local RaceVisuals = require("RaceVisuals")
local UI = require("urhox-libs/UI")
local Theme = require("RacingTheme")
local MixedChecks = require("MixedChecks")
---@type Scene?
local scene_ = nil
local CASES = {
    ready = {active=0,cd=0,result="",title="",status="就绪"},
    active = {active=1.6,cd=13.6,result="锁定完成 · 导弹已发射，持续追踪",title="导弹已发射",status="持续 1.6s"},
    noTarget = {active=0,cd=0,result="前方无有效目标 · 未消耗技能",title="前方无有效目标",status="就绪"},
    hit = {active=1.2,cd=13.2,result="技能命中 · 对手减速20%，失衡3秒",title="技能命中",status="持续 1.2s"},
    shield = {active=1.1,cd=13.1,result="攻击被护盾挡住",title="攻击被护盾挡住",status="持续 1.1s"},
    miss = {active=0,cd=12,result="弹体未命中 · 对手已躲开",title="攻击未命中",status="冷却 12.0s"},
    cooldown = {active=0,cd=8.5,result="",title="",status="冷却 8.5s"},
}

function Start()
    assert(MixedChecks.RunWeapons().passed, "追踪武器快速规则自测失败")
    local selected = "active"
    for _, arg in ipairs(GetArguments()) do selected = arg:match("^%-skill%-case=(.+)$") or selected end
    assert(CASES[selected], "未知技能验收状态")
    scene_ = Scene(); scene_:CreateComponent("Octree")
    local group = scene_:CreateChild("LightGroup")
    group:LoadXML(assert(cache:GetResource("XMLFile", "LightGroup/Daytime.xml")):GetRoot())
    local zone = group:GetComponent("Zone", true)
    if zone then zone.depthFogEnable, zone.heightFogEnable = false, false end
    local sun = group:GetComponent("Light", true)
    if sun then sun.brightness, sun.castShadows = 2.2, false end
    local parent = scene_:CreateChild("SkillCheck")
    local shot = {kind="helicopter",x=0,y=0,z=0,vx=0,vy=0,vz=65}
    Skill.UpdateShot(parent, shot)
    local node = assert(shot.node)
    local mesh = assert(node:GetChild("正式导弹_含尾翼"))
    local draw = assert(mesh:GetComponent("StaticModel"))
    assert(draw:GetMaterial():GetTexture(TU_DIFFUSE) and draw:GetMaterial():GetTexture(TU_NORMAL), "导弹必须保留正式D/N")
    assert(math.abs(draw:GetModel().boundingBox.size.z * mesh.scale.z - 1)<.001, "导弹长度约1m")
    assert(mesh.scale.x==mesh.scale.y and mesh.scale.y==mesh.scale.z, "导弹禁止非等比缩放")
    shot.x, shot.y, shot.z, shot.vx, shot.vy, shot.vz = .12, .04, .08, 12, 7, 60
    Skill.UpdateShot(parent, shot)
    assert(node.position==Vector3(shot.x,shot.y,shot.z), "显示坐标必须绑定仿真")
    local direction = Vector3(shot.vx,shot.vy,shot.vz):Normalized()
    assert(node.direction:DotProduct(direction)>.999, "弹头+Z必须沿真实三维速度")
    local frozen = node.position
    local visuals = setmetatable({disposed=false,visible=true,root=parent,runners={},markers={},
        race={racers={},mixedProjectiles={shot}},clock=0,visibilityClock=0,
        EnsurePolice=function() end}, RaceVisuals)
    shot.x = 8
    visuals:Update(.2,{paused=true,x=0,z=0})
    assert(node.position==frozen, "暂停必须冻结弹体")
    shot.x,shot.y,shot.z,shot.vx,shot.vy,shot.vz=0,0,0,0,0,65
    Skill.UpdateShot(parent, shot)
    Skill.Clear({shot}); assert(shot.node==nil, "退出清理不得留下已释放Node引用")
    Skill.UpdateShot(parent, shot)
    local water = {kind="jellyfish",x=0,y=0,z=0,vx=0,vy=0,vz=1}
    Skill.UpdateShot(parent,water)
    assert(water.node and water.node.name=="SkillProjectile_Water","水母必须显示独立水球而非导弹")
    water.x,water.y,water.z=2,1,3
    Skill.UpdateShot(parent,water)
    assert(water.node.position==Vector3(2,1,3),"水球表现只跟随真实弹道")
    Skill.Clear({water});assert(not water.node,"水球退出清理")
    -- 爆炸必须使用真实美术贴图，且能在生命周期内放大淡出后自行释放。
    local ExplosionEffects = require("ExplosionEffects")
    assert(cache:GetResource("Texture2D", ExplosionEffects.Resources[1]), "爆炸贴图必须可加载")
    local explosion = ExplosionEffects.Spawn(parent, {x=0, y=1, z=0, scale=1})
    local alive = ExplosionEffects.Update(explosion, 0.2, Vector3(0, 2, -4))
    assert(alive and explosion.node.scale.x > 1.4, "爆炸必须在生命周期内放大")
    local died = ExplosionEffects.Update(explosion, 0.5, Vector3(0, 2, -4))
    assert(not died, "爆炸必须超时释放")
    local camNode=scene_:CreateChild("Camera")
    camNode.position=Vector3(1.2,.72,-1.55);camNode:LookAt(Vector3.ZERO)
    local camera=camNode:CreateComponent("Camera");camera.fov,camera.farClip=32,30
    renderer:SetViewport(0,Viewport:new(scene_,camera));renderer.hdrRendering=true
    UI.Init({theme=Theme.Theme,scale=UI.Scale.DEFAULT})
    local skillButton=UI.Button{text="",width=220,height=48}
    local title=UI.Label{text="",fontSize=22,fontColor=Theme.Colors.cyan,textAlign="center"}
    local hint=UI.Label{text="",fontSize=13,fontColor=Theme.Colors.white,textAlign="center"}
    local panel=UI.Panel{width=480,padding=12,borderWidth=1,borderColor=Theme.Colors.cyan,children={title,hint}}
    -- 只调用生产HUD纯表现方法；不调用HUD.New、Profile.Get、Profile.Save或完整游戏菜单。
    local hud=setmetatable({screen="ride",skillButton=skillButton,featureRush={},featurePanel=panel,
        featureTitle=title,featureHint=hint},HUD)
    for name,c in pairs(CASES) do
        local sim={vehicleId="helicopter",oddActive=c.active,oddCooldown=c.cd,
            oddSkillResult=c.result,oddSkillResultTimer=c.result~="" and 2 or 0,oddDisrupt=0}
        hud:UpdateSkillFeedback(sim);hud:UpdateFeatureFeedback(sim)
        assert((skillButton.props.text or ""):find(c.status,1,true),"HUD按钮绑定失败："..name)
        if c.title~="" then assert(title:GetText():find(c.title,1,true),"HUD结果绑定失败："..name) end
        assert((skillButton.props.disabled==true)==(c.active>0 or c.cd>0),"HUD重入保护失败："..name)
    end
    local c=CASES[selected]
    hud:UpdateSkillFeedback({vehicleId="helicopter",oddActive=c.active,oddCooldown=c.cd,oddDisrupt=0})
    hud:UpdateFeatureFeedback({vehicleId="helicopter",oddSkillResult=c.result,oddSkillResultTimer=c.result~="" and 2 or 0})
    UI.SetRoot(UI.Panel{width="100%",height="100%",pointerEvents="box-none",children={
        UI.Column{position="absolute",top=24,left=24,gap=8,children={
            UI.Label{text="正式导弹 · 1m / 原始尾翼 / 无基础几何",fontSize=16,fontColor=Theme.Colors.white},
            UI.Label{text="生产HUD绑定验收 · "..selected,fontSize=13,fontColor=Theme.Colors.muted},skillButton}},
        UI.Panel{position="absolute",bottom=24,left="50%",marginLeft=-240,children={panel}}}})
    print("[技能专项验收] PASS 正式D/N / 1m等比 / xyz+vxyz / 暂停冻结 / 释放 / 水母真实水球 / HUD就绪发动无目标命中护盾失误冷却")
end

function Stop()
    UI.Shutdown()
    if scene_ then scene_:Dispose();scene_=nil end
end
