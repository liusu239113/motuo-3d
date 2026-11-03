-- 独立人物CPU对照：相同两套真实便服、相同站姿/手势，不启动城市或玩家档。
local Rig=require("Career.Rig")
local Pedestrians=require("Career.Pedestrians")
local Life=require("Career.StreetLife")
local Riders=require("Career.TrafficRiders")
---@type Scene?
local scene_=nil
function Start()
    scene_=Scene()
    scene_:CreateComponent("Octree")
    local count,maxError=0,0
    for index,asset in ipairs(Pedestrians.Specs) do
        local parent=scene_:CreateChild("便服等价对照"..index)
        local rig=Rig.New(parent,asset)
        local level=0
        local ground={WalkSurface=function(_,x) return level+(x>.05 and .04 or 0) end}
        rig.ground=ground --[[@as CareerCity]]
        for _,yaw in ipairs({0,45,90,180}) do
            parent.rotation=Quaternion(0,yaw,0)
            for _,height in ipairs({0,.08,.04}) do
                level=height
                rig:PoseWalk(0,0)
                local reference={}
                for _,name in ipairs(rig.boneNames) do reference[name]=rig:GetBonePosition(name) end
                -- 先干扰走姿，缓存恢复不得沿用走路骨骼或旧手势。
                rig:PoseWalk(.7,.8)
                rig:PoseStandingCached()
                for _,name in ipairs(rig.boneNames) do
                    local error=(rig:GetBonePosition(name)-reference[name]):Length()
                    maxError=math.max(error,maxError)
                    assert(error<.00001,"站姿缓存不等价 "..name.." / "..error)
                end
                count=count+1
            end
        end
        rig.ground=nil
        local person={rig=rig,clock=1.2,phase=.3,role="waiting",gesture="",gestureWeight=0,poseCount=0} --[[@as CareerStreetPerson]]
        local life={} --[[@as CareerStreetLife]]
        local originalCached=rig.PoseStandingCached
        rig.PoseStandingCached=function(self) self:PoseWalk(0,0) end
        local start=os.clock()
        for _=1,40 do Life.Pose(life,person) end
        local baseline=os.clock()-start
        rig.PoseStandingCached=originalCached
        rig.standingPose=nil
        Life.Pose(life,person)
        local before=rig.standingBuilds or 0
        start=os.clock()
        for _=1,40 do Life.Pose(life,person) end
        local optimized=os.clock()-start
        assert(rig.standingBuilds==before and (rig.standingRestores or 0)>=40,"稳定站姿必须绕过重复鞋底求解")
        print(string.format("[人群CPU对照] 真实便服%d/相同40次驻足手势：旧%.6fs 新%.6fs；缓存恢复%d；不是手机FPS",index,baseline,optimized,rig.standingRestores))
        rig:Dispose();parent:Dispose()
    end
    local riding=Riders.Add(scene_,Riders.DELIVERY)
    assert(riding.rider.model.model~=cache:GetResource("Model",Rig.ModelPath),"交通配送NPC不能复制主角模型")
    assert(riding.width>0 and riding.length>0 and riding.poseSolves==1,"换模型后须重测真实骑乘包络")
    Riders.Dispose(riding)
    require("Career.RoadReactionChecks").Run()
    print(string.format("[人群优化验收] PASS %d地表/朝向对照；全部骨骼最大误差%.9fm；NPC与主角资源不同",count,maxError))
end
function Stop()
    if scene_ then scene_:Dispose();scene_=nil end
end
