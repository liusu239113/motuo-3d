-- 纯Lua隔离回归：不创建世界，不调用Profile，不接触玩家存档。
local Checks={}
local F=require("TrackFeatures")
local Sim=require("Simulation")

local function fixture()
    local map={Goals={},RouteLength=2000,SpawnLaneOffset=0,activeId="fixture",Features={},Ramps={},
        Roads={{width=7.5,shoulder=10.7}},RoadPoint=function(s)return{x=0,y=0,z=s},0 end,
        NearestRoad=function(x,z)return z,x end, RoadHeight=function()return 0,true end}
    function map.RampAt(x,z)
        for _,r in ipairs(map.Ramps)do if F.RampHeight(r,x,z) then return r end end
        return nil
    end
    function map.Height(x,z)
        local r=map.RampAt(x,z)
        return r and F.RampHeight(r,x,z) or 0,true
    end
    return map
end

function Checks.Run()
    local report={passed=false,checks=0,flights={},errors={}}
    local function check(ok,name)
        report.checks=report.checks+1
        assert(ok,"[机关回归失败] "..name)
    end
    local ok,error=pcall(function()
        local map=fixture()
        local boost=F.Make(map,200,0,"boost","test_boost")
        map.Features={boost}
        local function rider(x,z,heading)
            return {x=x,y=0,z=z,heading=heading or 0,speed=35,maxSpeed=76,health=100,
                airborne=false,braking=false,featureState=F.NewBoostState(),nitro=42}
        end
        local e=rider(0,212)
        local triggered,gain=F.StepBoost(e,map,.02,0,0,198,false)
        check(triggered==boost and gain==4.5 and e.speed==39.5,"高速一步跨完整带仍触发，增益有限")
        check(e.nitro==42,"不读取或消耗玩家氮气")
        check(e.featureState.feedbackTimer==1.35 and e.featureState.feedbackPower==1,"真实增益授权1.35秒反馈")
        local fresh=F.NewBoostState()
        check(fresh.feedbackTimer==0 and fresh.feedbackPower==0,"新状态无假特效")
        local timer=e.featureState.feedbackTimer
        local speed=e.speed
        F.StepBoost(e,map,.02,0,0,198,false)
        check(e.speed==speed and e.featureState.triggers==1,"重复扫掠不能叠加")
        check(e.featureState.feedbackTimer<timer and e.featureState.feedbackPower<1,"冷却内不会续表现计时")
        local merge=rider(1.7,207)
        local merged=F.StepBoost(merge,map,.02,2.3,0,203,false)
        check(merged==boost and merge.speed==39.5,"顺向从侧边并入加速带有效")
        local sideways=rider(1.7,204.1)
        check(F.StepBoost(sideways,map,.02,2.3,0,204,false)==nil,"仅头向前但横向扫过不增益")
        for _=1,70 do F.StepBoost(merge,map,.02,merge.x,merge.y,merge.z,false) end
        check(merge.featureState.feedbackTimer==0 and merge.featureState.feedbackPower==0,"停留带内反馈会耗尽")
        e.featureState.clock=9
        F.StepBoost(e,map,.02,0,0,198,false)
        check(e.featureState.triggers==2,"冷却后重新跨入口可再次触发")
        for _,test in ipairs({{x=2.001,z=202,h=0},{x=0,z=198,h=180},
            {x=0,z=202,h=90},{x=0,z=202,h=0,air=true},{x=0,z=202,h=0,brake=true}}) do
            local r=rider(test.x,test.z,test.h)
            r.airborne,r.braking=test.air==true,test.brake==true
            local oldZ=test.h==180 and 212 or 198
            local hit=F.StepBoost(r,map,.02,test.x,0,oldZ,false)
            check(hit==nil and r.speed==35,"擦边/反向/横穿/腾空/刹车不触发")
        end
        local r=rider(0,202)
        r.speed=90
        local _,amount=F.StepBoost(r,map,.02,0,0,198,false)
        check(amount==0 and r.speed==90,"超上限不增加也不硬减速")
        check(r.featureState.triggers==1 and r.featureState.lastGain==0
            and r.featureState.feedbackTimer==0 and r.featureState.feedbackPower==0,"满速入口被消费且不授权假特效")
        local capped=rider(0,202)
        capped.speed=76*1.08-1
        local _,limited=F.StepBoost(capped,map,.02,0,0,198,false)
        check(math.abs(limited-1)<1e-8 and math.abs(capped.speed-76*1.08)<1e-8,"真实冲量严格保留108%上限")
        local still=rider(0,202)
        F.StepBoost(still,map,.02,0,0,202,false)
        check(still.speed==35,"停在带内不重复发力")
        -- 带外对照与带内实体同起始动量，用真实Sim连续一秒验证增益未被封顶抹掉。
        for _,initial in ipairs({35,76}) do
            local a,b=Sim.New(map),Sim.New(map)
            a.z,b.z=199.8,199.8
            a.x,b.x=0,3
            a.speed,b.speed=initial,initial
            a.nitro,b.nitro=42,42
            a:Step(.02,{throttle=1});b:Step(.02,{throttle=1})
            check(a.speed>b.speed,"过带前后速度真实增加")
            for _=1,50 do a:Step(.02,{throttle=1});b:Step(.02,{throttle=1}) end
            check(a.speed>b.speed+1 and a.distance>b.distance+.5,"0.5至1秒后仍有实际速度与距离收益")
            check(a.nitro==42 and a.raceBoost==0,"不占用氮气或Race boost输入")
        end
        map.Features={}
        local ramp=F.Make(map,200,0,"ramp","test_ramp")
        map.Ramps={ramp}
        for _,speedAtEntry in ipairs({12,30,55,80,105})do
            local s=Sim.New(map)
            s.z,s.y,s.speed=199,0,speedAtEntry
            local airborne,maxHeight,flight=false,0,0
            for _=1,400 do
                s:Step(.02,{throttle=1})
                if s.airborne then airborne=true;flight=flight+.02;maxHeight=math.max(maxHeight,s.y) end
                if airborne and not s.airborne then break end
            end
            check(airborne and not s.airborne and s.landingStable and s.health==100,"真实坡面起飞并平稳落地")
            check(s.y==0 and s.vY==0 and s.z>ramp.s+ramp.length,"弹道位移与落地状态一致")
            report.flights[#report.flights+1]={speed=speedAtEntry,height=maxHeight,time=flight}
            print(string.format("[机关飞跃] 入坡%.0fm/s 高度%.2fm 腾空%.2fs",speedAtEntry,maxHeight,flight))
        end
        local bypass=Sim.New(map)
        bypass.x,bypass.z,bypass.speed=2,199,55
        for _=1,60 do bypass:Step(.02,{throttle=1});check(not bypass.airborne,"保留车道可绕坡不飞起")end
        local entry,lip=ramp.s,ramp.s+ramp.length
        local hit=F.CrossLip({ramp},0,entry-1,0,lip+2,0,105)
        check(hit==ramp,"高速一步越过整个坡仍检测唇口")
        check(F.CrossLip({ramp},1.31,entry-1,1.31,lip+2,0,105)==nil,"坡外擦边不额外起飞")
        check(F.CrossLip({ramp},0,lip+2,0,entry-1,180,55)==nil,"逆向不能获起飞冲量")
        local back=Sim.New(map)
        back.z,back.speed,back.heading=lip+1,30,180
        back:Step(.1,{throttle=1})
        check(back.z>lip and back.y==0 and back.speed<=2 and not back.airborne,"坡背扫掠阻挡而非传送到顶")
        local side=Sim.New(map)
        side.x,side.z,side.speed,side.heading=2,lip-4,30,270
        side:Step(.1,{throttle=1})
        check(side.x>=1.3 and side.y==0 and side.speed<=2,"侧壁不穿透或吸附坡顶")
        -- 逐行、对角线和正负宽边，验证Height与真实显示三角形插值完全一致。
        for i=1,#ramp.rows-1 do
            for _,u in ipairs({0,.2,.5,.8,1})do
                local a,b=ramp.rows[i],ramp.rows[i+1]
                local f=a.forward+.37
                local x,z=F.Point(ramp,(u-.5)*ramp.width,f)
                local expected=a.left+(b.left-a.left)*(f-a.forward)/(b.forward-a.forward)
                check(math.abs(F.RampHeight(ramp,x,z)-expected)<1e-8,"坡面/显示同三角形高程")
            end
        end
        -- 原始Simulation测试包含三维交通扫掠、特技起飞/落地等既有链路。
        local simOk,simCount=Sim.Test()
        check(simOk,"原Simulation隔离回归")
        report.simChecks=simCount
    end)
    if not ok then report.errors[#report.errors+1]=tostring(error) end
    report.passed=ok
    print(string.format("[机关回归] passed=%s checks=%d",tostring(ok),report.checks))
    for _,message in ipairs(report.errors)do print(message) end
    return report
end

-- 显式六图检查；传入真实Landscape，结束后恢复活动图，不构建Scene。
---@param map table
function Checks.RealMaps(map)
    local previous=map.activeId
    local report={passed=false,checks=0,maps={},flights={},bypasses={},errors={}}
    local ok,error=pcall(function()
        for _,id in ipairs({"lake","alpine","coast","canyon","forest","circuit"})do
            assert(map.SelectTrack(id))
            -- 使用真实RaceAI避让、真实TrafficPose/道路曲面，不用伪造的平直地图。
            local Race=require("Race")
            local AI=require("RaceAI")
            local race=Race.New(map,Sim.New(map),{quiet=true,aiLevel=map.Track.aiLevel,seed=31})
            race:Start(1)
            race.phase="racing"
            local ai=race.racers[1]
            race.racers={ai}
            local ramps,boosts=0,0
            for _,f in ipairs(map.Features)do
                local safe,reason=F.Safe(map,f)
                assert(safe,id.." "..f.id.." "..tostring(reason))
                report.checks=report.checks+1
                if f.kind=="boost" then
                    local a,b=Sim.New(map),Sim.New(map)
                    a.x,a.z=F.Point(f,0,-.2)
                    b.x,b.z=F.Point(f,-3,-.2)
                    a.y,b.y=map.Height(a.x,a.z),map.Height(b.x,b.z)
                    a.heading,b.heading=f.yaw,f.yaw
                    a.speed,b.speed=38,38
                    a:Step(.02,{throttle=1});b:Step(.02,{throttle=1})
                    assert(a.featureState.triggers==1 and b.featureState.triggers==0,"实图加速带入口未触发")
                    assert(a.speed>b.speed+4,"实图加速带增益缺失")
                    report.checks=report.checks+1
                end
                if f.kind=="ramp" then ramps=ramps+1 else boosts=boosts+1 end
                if f.kind=="ramp" then
                    assert(f.width<map.Roads[1].width-2,"缺少绕行车道")
                    assert(f.length>=18 and f.length<=22 and f.height>=(id=="circuit" and 1.5 or 2),"飞坡仍过于矮平")
                    assert(id~="circuit" or f~=map.OptionalRamps[1] or (f.s>=300 and f.s<=1000),"免费图首坡应在早期安全路段")
                    for _,speed in ipairs({12,30,55,80,90,105})do
                        local s=Sim.New(map)
                        s.x,s.z=F.Point(f,0,-1)
                        s.y=map.Height(s.x,s.z)
                        s.heading,s.yaw,s.speed=f.yaw,f.yaw,speed
                        local airborne,maxAir,maxHeight=false,0,0
                        for _=1,400 do
                            s:Step(.02,{throttle=1})
                            local ground,onRoad=map.RoadHeight(s.x,s.z)
                            if s.airborne then
                                airborne=true;maxAir=maxAir+.02
                                maxHeight=math.max(maxHeight,s.y-(ground or s.y))
                            end
                            assert(not airborne or onRoad,"飞跃越出安全沥青走廊")
                            assert(s.health==100,"飞跃产生碰撞/失稳")
                            if airborne and not s.airborne then break end
                        end
                        assert(airborne and not s.airborne and s.landingStable,"未完整起飞落地")
                        assert(map.NearestRoad(s.x,s.z)<=f.landingEndS,"真实落地超出AI预留走廊")
                        report.checks=report.checks+1
                        report.flights[#report.flights+1]={id=f.id,speed=speed,height=maxHeight,time=maxAir,
                            landingS=map.NearestRoad(s.x,s.z),stable=s.landingStable}
                        print(string.format("[实图机关] %s %s %.0fm/s 离地%.2fm %.2fs",id,f.id,speed,maxHeight,maxAir))
                    end
                    for _,initial in ipairs({30,65,95}) do
                        ai.s,ai.speed=f.s-135,initial
                        ai.lane,ai.wantedLane,ai.preferredLane=f.lateral,f.lateral,f.lateral
                        ai.mistakeTimer,ai.mistakeDuration,ai.recoveryTimer=1000,0,0
                        ai.nitro,ai.boostTimer=0,0
                        ai.decisionTimer,ai.paceTimer,ai.laneHold=0,0,0
                        ai.perception.timer,ai.perception.recovery=0,0
                        ai.started,ai.finished,ai.eliminated=true,false,false
                        ai.nextGate=math.ceil(ai.s/race.gateSpacing)*race.gateSpacing
                        race:Place(ai)
                        local reached,minGap=false,math.huge
                        for _=1,2400 do
                            local oldX,oldY,oldZ=ai.x,ai.y,ai.z
                            AI.Update(race,ai,.02)
                            ai.boostTimer=math.max(0,ai.boostTimer-.02)
                            -- 实际旋转坡矩形和连续车轮轨迹；横偏>=.30m车宽+.10m净空。
                            local _,forward=F.Coords(f,ai.x,ai.z)
                            if forward>=-1 and forward<=f.length+1 then
                                local lateral=F.Coords(f,ai.x,ai.z)
                                local clearance=math.abs(lateral)-f.width*.5
                                minGap=math.min(minGap,clearance)
                                assert(clearance>=.40,"AI实际轨迹没有绕过坡体 "..f.id)
                            end
                            assert(F.BlockingFace({f},oldX,oldY,oldZ,ai.x,ai.y,ai.z)==nil,"AI穿过真实侧板")
                            assert(F.Sweep(f,oldX,oldZ,ai.x,ai.z)==false,"AI扫掠穿坡")
                            if ai.s>=f.s+f.length and ai.s<=f.landingEndS then
                                assert(math.abs(ai.lane-f.lateral)>=f.width*.5+.40,"AI提前占回飞跃落地区")
                            end
                            if ai.s>f.landingEndS+8 then reached=true;break end
                        end
                        assert(reached,"AI停在坡前而非真正绕行 "..f.id)
                        report.checks=report.checks+1
                        report.bypasses[#report.bypasses+1]={id=f.id,speed=initial,clearance=minGap}
                    end
                end
            end
            assert(ramps==2 and boosts==4,"机关数量错误 "..id)
            report.maps[#report.maps+1]={id=id,ramps=ramps,boosts=boosts}
        end
    end)
    local restored,restoreError=pcall(map.SelectTrack,previous)
    report.passed=ok and restored
    if not ok then report.errors[#report.errors+1]=tostring(error) end
    if not restored then report.errors[#report.errors+1]=tostring(restoreError) end
    for _,message in ipairs(report.errors)do print("[实图机关失败] "..message)end
    return report
end

return Checks
