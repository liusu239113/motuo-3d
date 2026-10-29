-- 真实官动采样验收。CPU断言不是视觉通过；Shot固定相位供独立8相位侧/正面实拍。
local Locomotion=require("Career.Locomotion")
local Checks={}
local function requireTest(session)
    assert(session.options and session.options.test==true and type(session.restoreTestStorage)=="function",
        "官方动画检查/摄影只允许隔离test storage，不能操作生产人物/存档")
end
---@param rig CareerRig
local function measure(rig)
    local height=1.76
    local hip=rig:GetBonePosition("Hip")
    local leftKnee,rightKnee=rig:GetBonePosition("L_Calf"),rig:GetBonePosition("R_Calf")
    local leftSole,rightSole=rig:SoleHeight("L_Foot"),rig:SoleHeight("R_Foot")
    return {hip=hip.y,height=height,hipRatio=hip.y/height,leftKnee=leftKnee.y,rightKnee=rightKnee.y,
        leftKneeRatio=leftKnee.y/height,rightKneeRatio=rightKnee.y/height,leftSole=leftSole,rightSole=rightSole,
        leftContact=leftSole<.018,rightContact=rightSole<.018}
end
---@param session table
function Checks.Run(session)
    requireTest(session)
    local visuals=session.actor.visuals
    ---@type CareerRig
    local rig=visuals.walker
    ---@type CareerLocomotion
    local motion=visuals.locomotion
    local saved={phase=motion.phase,idleTime=motion.idleTime,speed=motion.speed,moving=motion.moving,running=motion.running,paused=motion.paused,ground=rig.ground}
    local report={poses=0,maxLengthError=0,minWalkHip=math.huge,maxWalkHip=-math.huge,minRunHip=math.huge,maxRunHip=-math.huge,
        flight=0,leftContacts=0,rightContacts=0,official=true}
    local ok,err=pcall(function()
        rig.ground=nil
        assert(motion.clips.idle.animation.numTracks==97 and motion.clips.walk.animation.numTracks==98 and motion.clips.run.animation.numTracks==88,"官方资源版本/轨道不符，必须重新检查兼容性")
        assert(motion.clips.idle.keyframes==4947 and motion.clips.walk.keyframes==3626 and motion.clips.run.keyframes==2200,"不能用静态pose冒充官动关键帧")
        motion.paused=false
        for _,speed in ipairs({0,.6,1.8,2.6,3.4}) do
            local firstHand=Vector3.ZERO
            local handTravel=0
            for i=0,31 do
                motion:PoseNormalized(i/32,speed)
                local data=measure(rig)
                assert(data.leftSole>-.001 and data.rightSole>-.001,"真实鞋底不可穿地")
                if speed==0 or speed==1.8 then
                    assert(math.min(data.leftSole,data.rightSole)<.025,"Idle/Walk支撑鞋不应悬空")
                end
                if speed==1.8 then
                    report.minWalkHip=math.min(report.minWalkHip,data.hip)
                    report.maxWalkHip=math.max(report.maxWalkHip,data.hip)
                    assert(data.hipRatio>.40,"Walk不可整程半蹲；先检查源根单位/绑定轴")
                end
                if speed==3.4 then
                    report.minRunHip=math.min(report.minRunHip,data.hip)
                    report.maxRunHip=math.max(report.maxRunHip,data.hip)
                    assert(data.hipRatio>.36,"Run髋高异常，不能用IK掩盖重定向错误")
                    if data.leftSole>.025 and data.rightSole>.025 then report.flight=report.flight+1 end
                    if data.leftContact then report.leftContacts=report.leftContacts+1 end
                    if data.rightContact then report.rightContacts=report.rightContacts+1 end
                end
                for _,chains in ipairs({rig.legs,rig.arms}) do
                    for _,chain in ipairs(chains) do
                        local a,b,c=rig:GetBonePosition(chain.upper),rig:GetBonePosition(chain.lower),rig:GetBonePosition(chain.tip)
                        local error=math.max(math.abs((b-a):Length()-chain.lengthA),math.abs((c-b):Length()-chain.lengthB))
                        report.maxLengthError=math.max(report.maxLengthError,error)
                        assert(error<.00004,"官动重定向不得改变原始骨长: "..chain.tip)
                    end
                end
                for _,name in ipairs(rig.boneNames) do
                    local bone=rig.model:GetSkeleton():GetBone(name)
                    assert((bone.node.position-rig.bind[name].position):Length()<.000001,"不得复制源位移拉长骨骼")
                    assert((bone.node.scale-rig.bind[name].scale):Length()<.000001,"不得复制源缩放改变骨长")
                    assert(not bone.node.rotation:IsNaN(),"重定向不能产生NaN")
                end
                local hand=rig:GetBonePosition("L_Hand")
                if i==0 then firstHand=hand else handTravel=math.max(handTravel,(hand-firstHand):Length()) end
                if i%4==0 then
                    print(string.format("[官动相位] speed%.2f phase%.3f hip%.3fm/%.3fh kneeL/R%.3f/%.3fm soleL/R%.4f/%.4fm contact%s/%s",
                        speed,i/32,data.hip,data.hipRatio,data.leftKnee,data.rightKnee,data.leftSole,data.rightSole,tostring(data.leftContact),tostring(data.rightContact)))
                end
                report.poses=report.poses+1
            end
            if speed>=1.8 then assert(handTravel>.12,"真实clip不同相位必须有可观测摆臂，不以load成功验收") end
        end
        assert(report.flight>0 and report.leftContacts>0 and report.rightContacts>0,"Run必须有双侧支撑及原clip腾空，而非原地蹲跳")
        assert(report.maxWalkHip-report.minWalkHip<.10,"Walk不可上下蹲跳")
        motion:Reset()
        motion:Update(.1,0,.06)
        assert(motion.phase>0,"必须使用整帧真实距离，不能吞末子步撞墙前的位移")
        local stoppedPhase=motion.phase
        motion:Update(.1,3.4,0)
        assert(motion.phase==stoppedPhase,"撞墙没有真实位移时不可踏步")
        motion:PoseNormalized(.31,3.4)
        motion:SetPaused(true)
        local phase,idleTime,moving,running=motion.phase,motion.idleTime,motion.moving,motion.running
        local hand=rig:GetBonePosition("L_Hand")
        motion:Update(.5,3.4,1.7)
        assert(motion.phase==phase and motion.idleTime==idleTime and motion.moving==moving and motion.running==running,"暂停必须冻结全部时间/混合权重")
        assert((hand-rig:GetBonePosition("L_Hand")):Length()<.000001,"暂停必须冻结真实骨骼")
        motion:SetPaused(false)
        motion:Update(0,0,0)
        assert(motion.phase==phase,"dt0不可推进动画")
        for _=1,30 do motion:Update(1/60,0,0) end
        assert(motion.moving==0 and motion.running==0,"停止后必须完整混回官方Idle")
    end)
    rig.ground=saved.ground
    motion.phase,motion.idleTime,motion.speed,motion.moving,motion.running,motion.paused=saved.phase,saved.idleTime,saved.speed,saved.moving,saved.running,saved.paused
    motion:Evaluate()
    visuals.phase,visuals.gaitWeight,visuals.runWeight=motion.phase*math.pi*2,motion.moving,motion.running
    assert(ok,tostring(err))
    print(string.format("[官方走跑数据验收] PASS %d姿态 骨长误差%.7fm Walk髋%.3f..%.3f Run髋%.3f..%.3f 腾空%d 左右支撑%d/%d；视觉必须另看多相位实拍",
        report.poses,report.maxLengthError,report.minWalkHip,report.maxWalkHip,report.minRunHip,report.maxRunHip,report.flight,report.leftContacts,report.rightContacts))
    return report
end
-- -careeranimshot=idle|slow|walk|blend|run|front|side
-- -animphase=0..1 -animview=side|front|rear|threequarter，或-side/-front。
-- 不独立订阅Update、不使用渲染帧号；Session冻结后该真实clip相位保持稳定。
function Checks.Shot(session,mode)
    requireTest(session)
    local actor=session.actor
    local visuals=actor.visuals
    ---@type CareerLocomotion
    local motion=visuals.locomotion
    local phase=.125
    local view="side"
    local speed=mode=="idle" and 0 or mode=="slow" and .6 or mode=="walk" and 1.8 or mode=="blend" and 2.6 or 3.4
    if mode=="front" or mode=="rear" or mode=="threequarter" then view=mode end
    for _,arg in ipairs(GetArguments()) do
        local number=arg:match("^%-animphase=([%d%.]+)$")
        if number then phase=math.max(0,math.min(1,tonumber(number) or phase)) end
        local selected=arg:match("^%-animview=([%a]+)$")
        if selected then view=selected end
        if arg=="-side" then view="side" end
        if arg=="-front" then view="front" end
    end
    actor.mounted=false
    visuals:SetMounted(false)
    actor:Teleport(2,-20,0)
    session.yaw,session.pitch=view=="front" and 180 or view=="rear" and 0 or view=="threequarter" and 135 or 90,0
    session:UpdateEnvironment(12)
    session.camera:SetModeConfig("normal",{distance=3.1,offset=Vector3(0,.93,0),fov=44})
    session.camera:Update(1,actor.node,session.yaw,session.pitch)
    session.view:ShowGame();session:Refresh()
    session.view:ShowDialog("官方动作实拍","",{});session.view.overlay:SetVisible(false)
    for _,entry in pairs(visuals.vehicles) do entry.node:SetEnabledRecursive(false) end
    visuals.walkNode:SetEnabledRecursive(true)
    motion:PoseNormalized(phase,speed)
    motion:SetPaused(true)
    visuals.phase,visuals.gaitWeight,visuals.runWeight=motion.phase*math.pi*2,motion.moving,motion.running
    local d=measure(visuals.walker)
    local path=speed==0 and Locomotion.Paths.idle or speed<=1.8 and Locomotion.Paths.walk or Locomotion.Paths.run
    print(string.format("[官方动画实拍] mode%s view%s phase%.4f speed%.2f clip%s hip%.3f/%.3fh knee%.3f/%.3f sole%.4f/%.4f contact%s/%s frozen=true",
        tostring(mode),view,motion.phase,speed,path,d.hip,d.hipRatio,d.leftKnee,d.rightKnee,d.leftSole,d.rightSole,tostring(d.leftContact),tostring(d.rightContact)))
end
return Checks
