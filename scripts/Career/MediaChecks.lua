-- 手机和音源状态回归，只在Career.Checks内存档运行，不声称代替真机听感验收。
local UI=require("urhox-libs/UI")
local PointerEvent=require("urhox-libs/UI/Core/PointerEvent")
local Checks={}
local function tap(widget)
    UI.Layout()
    local r=widget:GetAbsoluteLayout()
    assert(r.w>0 and r.h>0,"手机组件必须有可点击布局")
    local scale=UI.GetScale()
    local function event(kind)
        return PointerEvent.new(kind,{pointerId=790001,pointerType="touch",isPrimary=true,
            x=(r.x+r.w/2)*scale,y=(r.y+r.h/2)*scale,button=PointerEvent.Button.Left})
    end
    local down=event("PointerDown"); UI.HandlePointerEvent(down)
    assert(down.target==widget,"图片装饰不得挡住实际应用点击")
    UI.HandlePointerEvent(event("PointerUp"))
end
function Checks.Run(session)
    local view,actor,sound=session.view,assert(session.actor),assert(session.audio)
    for key,clip in pairs(sound.sounds) do assert(clip:GetLength()>0,"音频为空："..key) end
    assert(sound.sources.music and sound.sources.electric and sound.sources.steps and sound.sources.engine)
    local snapshot={speed=actor.speed,mounted=actor.mounted,vehicle=actor.vehicleId}
    actor.speed,actor.mounted,actor.vehicleId=1.8,false,"borrowed_ebike"
    local before=sound.stepCount
    sound:Update(.25,actor,false,false,{},nil); sound:Update(.25,actor,false,false,{},nil)
    assert(sound.stepCount>before and sound.sources.steps.frequency==sound.sounds.steps:GetFrequency(),"脚步应按距离触发并使用正确采样率")
    sound:Update(.1,actor,true,false,{},nil)
    assert(sound.stepDistance==0 and not sound.sources.steps.playing,"手机暂停必须停止脚步")
    actor.speed,actor.mounted=4,true
    sound:Update(.25,actor,false,false,{throttle=1},nil)
    assert(sound.sources.electric.gain>0 and sound.sources.electric.frequency>sound.sounds.electric:GetFrequency()*.7)
    actor.vehicleId="sport"
    sound:Update(.25,actor,false,false,{throttle=1},nil)
    assert(sound.sources.engine.gain>0,"摩托与电动车应有独立音源")
    local orders=sound.orderCount
    sound:Update(.1,actor,false,false,{}, {id="sound-check-offer"})
    sound:Update(.1,actor,false,false,{}, {id="sound-check-offer"})
    assert(sound.orderCount==orders+1,"同一新订单只提示一次")
    actor.speed,actor.mounted,actor.vehicleId=snapshot.speed,snapshot.mounted,snapshot.vehicle
    session:OpenPhone("apps"); UI.Layout()
    for _,app in ipairs(require("Career.Phone").Apps) do
        local icon=assert(view.root:FindById("career-app-"..app[1]))
        tap(icon)
        assert(view.phonePage==app[1],"应用未打开："..app[1])
        session:OpenPhone("apps"); UI.Layout()
    end
    local music,effects=sound.musicEnabled,sound.effectsEnabled
    view.actions.toggleMusic(); view.actions.toggleEffects()
    assert(sound.musicEnabled~=music and sound.effectsEnabled~=effects)
    for _=1,20 do sound:Update(.1,actor,true,false,{},nil) end
    assert(sound.sources.music.gain==0 and sound.sources.city.gain==0,"关闭分组后应淡出至静音")
    view.actions.toggleMusic(); view.actions.toggleEffects()
    view:ClosePhone(); session:Refresh()
    print("[手机音源验收通过] 六应用真实触摸/框图穿透/音乐与效果独立开关/车辆独立音源/脚步按距离/暂停停脚/订单去重；真实听感仍需手机验收")
end
return Checks
