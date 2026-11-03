-- 独立挡路反应回归：使用真实垂直区间算法、纯车道夹具，不生成城市/读档/播音。
local R=require("Career.RoadReactions")
local CareerAudio=require("Career.Audio")
local Checks={}
function Checks.Run()
    local count,calls=0,0
    local function check(value,message) assert(value,"[RoadReactionChecks] "..message);count=count+1 end
    local actor={x=3,z=-30,yaw=0,speed=0,mounted=true,vehicleId="borrowed_ebike",VehicleRadius=function() return 1 end}
    local car={x=3,z=-36,yaw=0,speed=0,length=4,width=2,vehicleId="sedan",route={axis="ns",road=0},s=119}
    local ground=0
    local city={space="city",Surface=function() return ground end}
    local traffic={city=city,actor=actor,time=4,active=true,nearOld=true,cars={car},CrossingBusy=function() return false end}
    check(R.Blocked(traffic,car,actor,false,traffic.cars),"同车道停稳应识别")
    check(not R.Blocked(traffic,car,actor,true,traffic.cars),"红灯不能误怪玩家")
    actor.x=12;check(not R.Blocked(traffic,car,actor,false,traffic.cars),"旁边路人不能触发");actor.x=3
    actor.z=-40;check(not R.Blocked(traffic,car,actor,false,traffic.cars),"车后不能触发");actor.z=-30
    ground=0
    city.Surface=function(_,_,z) return z>-33 and 8 or 0 end
    check(not R.Blocked(traffic,car,actor,false,traffic.cars),"桥上桥下不能误触发")
    city.Surface=function() return ground end
    actor.speed=2;check(not R.Blocked(traffic,car,actor,false,traffic.cars),"正常骑行不应抱怨");actor.speed=0
    actor.mounted=false;check(not R.Blocked(traffic,car,actor,false,traffic.cars),"本轮只处理骑车挡路");actor.mounted=true
    local other={x=3,z=-33,length=4,width=2}
    check(not R.Blocked(traffic,car,actor,false,{car,other}),"其他车排队不是玩家直接阻挡")
    local audio={TrafficReaction=function() calls=calls+1;return true end}
    for _=1,24 do R.Update(traffic,.1,audio) end
    check(calls==0,"未持续2.5秒不应鸣笛")
    for _=1,3 do R.Update(traffic,.1,audio) end
    check(calls==1,"持续挡路仅一次")
    for _=1,100 do R.Update(traffic,.1,audio) end
    check(calls==1,"25秒单车冷却")
    car.blockedByPlayer=2.4;car.reactionCooldown=7;traffic.reactionCooldown=3
    R.ResetWaiting(traffic)
    check(car.blockedByPlayer==0 and car.reactionCooldown==7 and traffic.reactionCooldown==3,
        "暂停清等待但不能绕过冷却")
    car.reactionCooldown=0;traffic.reactionCooldown=0
    audio.paused=true;car.blockedByPlayer=2.4
    R.Update(traffic,.1,audio)
    check(car.blockedByPlayer==0 and calls==1,"暂停不能累计或补播旧反应")
    audio.paused=false
    for _=1,24 do R.Update(traffic,.1,audio) end
    check(calls==1,"恢复后必须重新等待完整时长")
    traffic.nearOld=false;R.Update(traffic,.1,audio)
    check(car.blockedByPlayer==0,"远离老街必须清除旧等待")
    traffic.nearOld=true;car.blockedByPlayer=2.4
    traffic.active=false;R.Update(traffic,.1,audio)
    check(car.blockedByPlayer==0,"非活动交通不得保留等待")
    traffic.active=true;car.blockedByPlayer=2.4
    R.Update(traffic,0/0,audio)
    check(car.blockedByPlayer==0 and calls==1,"异常时间步不能污染等待计时")
    local node={IsEnabled=function() return false end}
    local pooled={node=node,speed=0,inUse=true,blockedByPlayer=2.4,reactionCooldown=9}
    local outer=require("Career.OuterTraffic")
    local pool=setmetatable({cars={pooled},recycled=0},{__index=outer})
    pool:ReleaseCar(1)
    check(pooled.blockedByPlayer==0 and pooled.reactionCooldown==0 and not pooled.inUse,
        "外区车槽回收不能继承旧司机反应")
    traffic.time=20;car.blockedByPlayer=0;car.reactionCooldown=0;traffic.reactionCooldown=0
    car.z=-20;car.s=135;actor.z=-14
    for _=1,30 do R.Update(traffic,.1,audio) end
    check(calls==1,"红灯停止线等待不能鸣笛")
    local plays,stops=0,0
    local function source()
        return {playing=false,Play=function() plays=plays+1 end,
            StopImmediate=function() stops=stops+1 end,gain=0}
    end
    local soundscape={disposed=false,paused=false,unlocked=true,effectsEnabled=true,
        sources={horn=source(),complaint=source()},sounds={horn={},complaint={}},stepState=CareerAudio.NewStepState()} --[[@as CareerSoundscape]]
    setmetatable(soundscape,{__index=CareerAudio})
    check(soundscape:TrafficReaction(car,actor),"启用音效应播放")
    check(plays==2,"只有喇叭与单语音两通道")
    CareerAudio.SetPaused(soundscape,true)
    check(stops==2 and not soundscape:TrafficReaction(car,actor),"暂停立即停声且不补播")
    soundscape.paused=false;soundscape.effectsEnabled=false
    check(not soundscape:TrafficReaction(car,actor),"关闭音效不发声")
    print(string.format("[RoadReactionChecks] PASS %d断言；车前/车后/侧向/红灯/排队/持续等待/冷却/暂停/音效关闭",count))
    return count
end
return Checks
