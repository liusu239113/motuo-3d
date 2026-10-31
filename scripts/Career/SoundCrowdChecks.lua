-- 主线程显式调用；不构建、不启动Runtime、不写档/云档。
local Audio=require("Career.Audio")
local Crowd=require("Career.Crowd")
local Rig=require("Career.Rig")
local Motion=require("Career.Locomotion")
local Environment=require("Career.CityEnvironment")
local C=require("Career.FootprintCollision")
local Routes=require("Career.TrafficRoutes")
local Checks={}
local function near(a,b,e,message) assert(math.abs(a-b)<=e,message or string.format("%f != %f",a,b)) end

function Checks.Steps()
    local state=Audio.NewStepState()
    local x=0
    local function step(height,enabled,grounded)
        x=x+.09
        return Audio.AdvanceStep(state,.05,{x=x,z=0,left=height,right=.10,phase=x/1.2,enabled=enabled~=false,grounded=grounded~=false})
    end
    assert(not step(0) and not step(.07),"首次/抬脚不可发声")
    for _=1,3 do step(.07) end
    assert(step(0)=="left","真实位移后的支撑边沿没有触发")
    assert(not step(0),"持续支撑重复触发")
    for _=1,10 do
        assert(not Audio.AdvanceStep(state,.05,{x=x,z=0,left=0,right=0,phase=x/1.2,enabled=true,grounded=true}),"静止时伪造脚步")
    end
    for _,mode in ipairs({"paused","air","ride","indoor"}) do
        Audio.ResetSteps(state,x,0)
        for i=1,20 do
            x=x+.09
            assert(not Audio.AdvanceStep(state,.05,{x=x,z=0,left=i%4==0 and 0 or .1,right=.1,phase=x/1.2,
                enabled=mode=="air",grounded=mode~="air"}),mode.."应禁足音")
        end
    end
    assert(not Audio.AdvanceStep(state,2,{x=x+20,z=0,left=0,right=0,enabled=true,grounded=true}),"传送/大dt补发脚步")
    local sea=Audio.Environment(0,-70,{surface="wood",sea=.8,bridge=.3,urban=.1,traffic=.2})
    assert(sea.surface=="wood" and sea.sea==.8 and sea.bridge==.3,"音景context没有覆盖默认区域")
    assert(Audio.Environment(0,0).sea==0,"不存在海岸的市中心凭空响海浪")
end

-- 每段按高度阈值分组并输出段内min/max与相位；源探针是绑定相对Foot/Toe，非源模型鞋底。
---@param values number[]
local function curve(label,values)
    local groups={}
    local start,kind,low,high=1,"",math.huge,-math.huge
    local lowAt,highAt=1,1
    for i=1,#values+1 do
        local value=values[i]
        local band=value and (value<=.018 and "接地" or value>.028 and "抬脚" or "过渡") or "结束"
        if band~=kind then
            if i>1 then
                groups[#groups+1]=string.format("%s[%.4f..%.4f]谷%.4f@%.4f峰%.4f@%.4f",kind,(start-1)/80,(i-2)/80,low,(lowAt-1)/80,high,(highAt-1)/80)
            end
            start,kind,low,high=i,band,math.huge,-math.huge
        end
        if value then
            if value<low then low,lowAt=value,i end
            if value>high then high,highAt=value,i end
        end
    end
    print("[官动支撑曲线] "..label.." "..table.concat(groups,"; "))
end
-- 真模型/真官动：原161相位和正式Update分别验；不扩大两周期事件上界。
function Checks.Motion(scene,city)
    local root=scene:CreateChild("SoundCrowdChecks官方步态夹具")
    local rig=Rig.New(root)
    local ground={WalkSurface=function() return .085 end,Surface=function() return .085 end} --[[@as CareerCity]]
    rig.ground=ground
    local locomotion=Motion.New(rig)
    rig.locomotion=locomotion -- 与Rig:EnableOfficialLocomotion生产字段一致。
    local actor={x=0,z=0,mounted=false,walkHeight=.085,city=ground,visuals={walker=rig}}
    local ok,err=pcall(function()
        for _,speed in ipairs({1.8,3.4}) do
            local state=Audio.NewStepState()
            local count,total=0,0
            local clip=speed==1.8 and locomotion.clips.walk or locomotion.clips.run
            local duration=clip.length
            ---@type table<string,number[]>
            local curves={left={},right={},sourceLeft={},sourceRight={}}
            for i=0,160 do
                local phase=i/80
                actor.x=phase*speed*duration
                root.position=Vector3(actor.x,.085,0)
                locomotion:PoseNormalized(phase,speed)
                local support=Audio.Support(actor,{})
                assert(support.phase==locomotion.phase,"未读取生产rig.locomotion.phase")
                support.enabled=true
                local source=locomotion:SampleSource(clip,(phase%1)*duration)
                for _,side in ipairs({"left","right"}) do
                    curves[side][#curves[side]+1]=support[side]
                    local prefix=side=="left" and "Bip001 L " or "Bip001 R "
                    local foot,toe=prefix.."Foot",prefix.."Toe0"
                    local sourceHeight=math.min(source[foot]:Translation().y-locomotion.reference[foot]:Translation().y,
                        source[toe]:Translation().y-locomotion.reference[toe]:Translation().y)*locomotion.rootRatio
                    local key=side=="left" and "sourceLeft" or "sourceRight"
                    curves[key][#curves[key]+1]=sourceHeight
                end
                local foot=Audio.AdvanceStep(state,duration/80,support)
                if foot then
                    count=count+1
                    print(string.format("[官动落足事件] Pose %.1fm/s phase=%.4f %s L=%.4f R=%.4f",speed,phase,foot,support.left,support.right))
                end
                total=total+(support.grounded and 1 or 0)
            end
            for _,key in ipairs({"left","right","sourceLeft","sourceRight"}) do curve(string.format("%.1fm/s %s",speed,key),curves[key]) end
            assert(total>=150,"官动步/跑支撑误判为持续空中")
            assert(count>=2 and count<=5,string.format("官动%d相位 %.1fm/s 足音次数异常%d",161,speed,count))
            print(string.format("[真实官动足音] %.1fm/s 161相位 两周期 支撑帧%d 事件%d",speed,total,count))
            -- 连续正式Update：先完成移动混合再测两周期，距离/phase都来自同一路径。
            locomotion:Reset()
            local dt=duration/80
            for _=1,160 do locomotion:Update(dt,speed,speed*dt) end
            state=Audio.NewStepState(); count=0; actor.x=0
            for i=0,160 do
                if i>0 then actor.x=actor.x+speed*dt; locomotion:Update(dt,speed,speed*dt) end
                root.position=Vector3(actor.x,.085,0)
                local support=Audio.Support(actor,{})
                support.enabled=true
                local foot=Audio.AdvanceStep(state,dt,support)
                if foot then
                    count=count+1
                    print(string.format("[官动落足事件] Update %.1fm/s frame=%d phase=%.4f %s L=%.4f R=%.4f",speed,i,support.phase,foot,support.left,support.right))
                end
            end
            assert(count>=2 and count<=5,string.format("正式Motion.Update %.1fm/s 两周期足音次数异常%d",speed,count))
            print(string.format("[真实官动足音] Motion.Update %.1fm/s 两周期 事件%d",speed,count))
        end
        -- 停止、空中、骑行、室内和暂停通过同一个Audio.Update正式入口检查。
        ---@type CareerSoundscape
        local sound=Audio.New(scene)
        local soundOk,soundErr=pcall(function()
            sound:Unlock()
            actor.x=0; root.position=Vector3(0,.085,0)
            for _,mode in ipairs({"stand","paused","air","ride","indoor"}) do
                local before=sound.stepCount
                sound:SetPaused(false); Audio.ResetSteps(sound.stepState,0,0)
                for i=1,24 do
                    actor.x=mode=="stand" and 0 or i*.08
                    root.position=Vector3(actor.x,mode=="air" and 1.085 or .085,0)
                    actor.mounted=mode=="ride"
                    locomotion:PoseNormalized(i/24,1.8)
                    sound:Update(.05,actor,mode=="paused",mode=="indoor",{},nil,mode=="air" and {grounded=false} or {})
                end
                assert(sound.stepCount==before,"正式Audio.Update在"..mode.."仍发脚步")
                for _,key in ipairs({"steps","sand","wood"}) do assert(not sound.sources[key].playing,"禁止态仍有足音尾音") end
            end
            sound:Update(.05,actor,true,false,{},nil)
            for _,source in pairs(sound.sources) do assert(not source.playing and source.gain==0,"暂停未停止全部音源") end
            actor.mounted=false
            sound.paused=false
            for _,surface in ipairs({"concrete","sand","wood"}) do
                local before=sound.stepCount
                sound:Footstep(surface,"left")
                assert(sound.stepCount==before+1 and sound.lastSurface==surface,"地表足音未选择独立素材")
            end
        end)
        sound:Stop(); sound:Stop(); assert(soundOk,tostring(soundErr))
    end)
    rig:Dispose(); root:Dispose(); assert(ok,tostring(err))
end

function Checks.Pool(scene,city)
    local scratch=scene:CreateChild("SoundCrowdChecks人群夹具")
    local fixture=setmetatable({space="city",traffic={active=true,time=0,cars={},pedestrians={people={}}},root=scratch,deliveryPeople=nil},{__index=city}) --[[@as CareerCity]]
    local actor={x=0,z=-20,mounted=false,yaw=0,vehicleId="borrowed_ebike"}
    ---@type CareerCrowd
    local crowd=Crowd.New(fixture,scratch,{budget=12})
    local ok,err=pcall(function()
        assert(crowd:Prime(actor),"首屏安全人群未初始化")
        local initial=#crowd.people
        assert(initial>=8 and initial<=12 and #crowd.pool<=12,"近场池不足或越界")
        local p=assert(crowd.people[1])
        assert(p.radius==.30 and p.model:GetSkeleton():GetNumBones()>0,"行人包络/骨架异常")
        local originalNode=p.node
        local x,z,phase,poses=p.x,p.z,p.phase,crowd.poseCount
        for _=1,20 do crowd:Update(.05,actor,false,nil) end
        near(p.x,x,1e-8,"暂停位移"); near(p.z,z,1e-8,"暂停位移"); near(p.phase,phase,1e-8,"暂停官动相位")
        assert(crowd.poseCount==poses,"暂停仍求骨骼")
        fixture.space="hostel"; crowd:Update(.05,actor,true,nil)
        assert(not crowd.root.enabledSelf and #crowd:GetBlockers()==0,"室内仍显示/阻挡")
        fixture.space="city"
        local positions={}
        for _,person in ipairs(crowd.people) do positions[person]={person.x,person.z} end
        for _=1,20 do
            local before=crowd:Stats()
            crowd:Update(.05,actor,true,nil)
            local after=crowd:Stats()
            assert(after.poses-before.poses<=Crowd.MAX_POSES and after.moves-before.moves<=Crowd.MAX_MOVES,"每帧工作预算失控")
            assert(after.pool<=12 and after.active<=12,"池无界增长")
            for _,person in ipairs(crowd.people) do assert(city:StaticFree(person.x,person.z,person.radius,"walk",person.height),"行人穿静态障碍") end
        end
        assert(crowd.created<=12 and not crowd:Prime(actor),"重复Prime可运行中刷脸")
        -- 连续静态薄墙和可见车壳：使用生产SegmentFree，不用点采样伪造可通。
        local wall=C.Box(2,-1,2.02,1)
        local originalSegment=fixture.StaticSegmentFree
        fixture.StaticSegmentFree=function(_,ax,az,bx,bz,r)
            return C.Free(C.Circle(ax,az,r),wall) and not C.Sweep(C.Circle(ax,az,r),wall,bx-ax,bz-az)
        end
        crowd.people={p}; p.x,p.z,p.height=0,0,.085; p.active=true
        crowd.shapes={}
        assert(not crowd:SegmentFree(p,0,0,4,0),"薄墙被连续扫掠漏掉")
        crowd.shapes={{shape=C.Box(-.6,1,.6,4),vx=0,vz=0}}
        assert(not crowd:SegmentFree(p,0,0,0,3),"行人可穿可见车体")
        crowd.shapes={}
        fixture.StaticSegmentFree=function() return true end
        p.route={path={9,-28,9,28},length=56,crossing={axis="ns",enter=19.6,exit=36.4}}
        p.x,p.z,p.s,p.direction,p.speed=9,-8.4,19.6,1,1.4
        fixture.traffic.time=21
        assert(Routes.Signal(21,"ns")=="red" and not crowd:CanCross(p),"红灯新增横穿")
        local s=p.s
        crowd:Move(p,.05); near(p.s,s,1e-8,"红灯没有停在路缘")
        fixture.traffic.time=0
        assert(crowd:CanCross(p),"整段绿灯窗口不能通行")
        crowd:Move(p,.05); assert(p.s>s,"绿灯未正常横穿")
        fixture.StaticSegmentFree=originalSegment
        -- 退休只放回槽；再次Acquire使用同一个Node，绝不新增大模型。
        crowd:Retire(1)
        crowd.routes={{path={-80,-8.7,-38,-8.7},length=42,id="reuse"}}
        crowd.shapes={}
        crowd.Hidden=function() return true end
        assert(crowd:Acquire(actor,nil,false),"释放槽不能复用")
        assert(crowd.people[1].node==originalNode and crowd.created<=12,"复用偷偷新建骨骼")
        fixture.traffic.active=false
        assert(#crowd:GetBlockers()==0 and crowd:IsFree(p.x,p.z,1),"旧测试禁用交通后残留隐形新行人墙")
    end)
    crowd:Dispose(); crowd:Dispose(); scratch:Dispose(); assert(ok,tostring(err))
end
function Checks.Run(session)
    assert(session.options and session.options.test==true and type(session.restoreTestStorage)=="function","仅隔离test Session可运行")
    Checks.Steps(); Checks.Motion(session.scene,session.city); Checks.Pool(session.scene,session.city)
    print("[声音人群专项通过] 真官动鞋底支撑/停站空中骑行暂停室内/独立表面音色/近场池预算/薄墙车体/遵灯/节点复用；未代替手机实际听感与GPU截图验收")
    return true
end
-- 仅准备已有场景与镜头；截图/Runtime由主线程显式统一启动。
function Checks.Shot(session,name)
    assert(session.options and session.options.test==true,"人群实拍仅隔离test Session")
    assert(name=="street" or name=="bridge" or name=="coast","未知人群实拍视图")
    local actor=session.actor
    session:ApplySpace("city")
    local x,z,yaw=0,-20,0
    if name=="bridge" then x,z,yaw=-9,-89,0 end
    if name=="coast" then x,z,yaw=-548,-590,180 end
    -- test Update不推进流式；摄影定位必须先加载与EnvironmentShot相同的实际地形。
    session.city.stream:Ensure(x,z,550)
    local height=Environment.Surface(x,z) or session.city:WalkSurface(x,z,0)
    actor.mounted=false; actor.visuals:SetMounted(false)
    actor:Teleport(x,z,yaw,height); actor:SyncVisuals(0)
    session.yaw,session.pitch=yaw,10
    session.camera:Update(2,actor.node,yaw,10)
    session.view:ClosePhone(); session.view:ShowGame(); session.view.overlay:SetVisible(false)
    local crowd=session.crowd
    if crowd then
        -- 专项镜头在加载遮罩内重建本地增量池；非生产Update中的刷人入口。
        crowd:Dispose()
        session.crowd=Crowd.New(session.city)
        session.city.crowd=session.crowd
        session.crowd:Prime(actor)
    end
    session:Refresh()
    print("[人群实拍准备] "..name.."；请主线程截图，脚本未启动Runtime")
end
return Checks
