-- 快速音频验收入口：不加载游戏世界，不自动解锁/播放，不修改主入口。
-- UrhoXRuntime /workspace/scripts/VehicleAudioCheckMain.lua -tapcode_dir=/workspace -tool_mode -validate
-- 显式挂载仅用于此离线验收入口，不改生产main/项目配置。
cache:AddResourceDir("/workspace/assets")
cache:AddResourceDir("/workspace/scripts")
local Audio=require("RideAudio")
local Checks=require("AudioChecks")
---@type Scene?
local scene
---@type RideAudio?
local manager
local playback_=false
local vehicleIndex_,stageFrames_,checked_=1,0,0
local elapsed_=0.0
local sim_={vehicleId="sport",speed=24,rpm=6500,throttle=.8,braking=false,health=100,
    overtakes=0,elapsed=0.0,finished=false,oddSerial=0,motorcycleSkillSerial=0,oddActive=0,motorcycleActive=0}
local function playbackStep(_,eventData)
    if not playback_ or not manager then return end
    local dt=math.max(.001,eventData:GetFloat("TimeStep"))
    elapsed_=elapsed_+dt;sim_.elapsed=elapsed_
    local id=Audio.Catalog.Ids[vehicleIndex_]
    if not id then
        manager:Update(dt,sim_,"pause")
        assert(not manager.sources[2].playing and not manager.skillSource.playing,"暂停必须停止实际音源")
        manager:Stop()
        print("[VehicleAudioCheck] PLAYBACK PASS 27车型真实SoundSource启动、Hz/增益、专属技能、暂停停止")
        playback_=false
        engine:Exit()
        return
    end
    stageFrames_=stageFrames_+1
    if stageFrames_==1 then
        sim_.vehicleId=id;sim_.oddActive=0;sim_.motorcycleActive=0
        manager:Reset(sim_)
    end
    if stageFrames_==3 then
        sim_.oddSerial=sim_.oddSerial+1;sim_.motorcycleSkillSerial=sim_.motorcycleSkillSerial+1
        sim_.oddActive=2;sim_.motorcycleActive=2
    end
    manager:Update(dt,sim_,"ride")
    if stageFrames_==3 then
        local status=manager:GetStatus()
        assert(status.output.initialized and status.output.playing,"验证设备必须实际运行混音")
        assert(status.engine.playing and status.engine.frequency>1000 and status.engine.gain>0,"行驶音源未实际播放："..id)
        local entry=Audio.Catalog.Vehicles[id]
        if entry.skillOwner=="RideAudio" and entry.skill then
            assert(manager.skillSource.playing and manager.skillSource.gain>0,"技能声未实际播放："..id)
        else
            assert(not manager.skillSource.playing,"保护车型或武器声音不得重复播放："..id)
        end
        checked_=checked_+1
    end
    if stageFrames_>=5 then
        manager:Update(dt,sim_,"pause")
        assert(not manager.sources[2].playing and not manager.skillSource.playing,"暂停清理失败："..id)
        vehicleIndex_=vehicleIndex_+1;stageFrames_=0
    end
end
function Start()
    assert(Checks.Ride().passed)
    assert(Audio.CheckPadFeedback().passed)
    assert(Checks.Race())
    scene=Scene()
    manager=Audio.New(scene)
    assert(Checks.RideLoaded(manager).passed)
    for _,arg in ipairs(GetArguments()) do
        if arg=="-audio-playback" then
            assert(GetAudio():IsInitialized(),"音频验证输出设备未初始化")
            manager.musicEnabled=false
            manager:Unlock()
            playback_=true
            SubscribeToEvent("Update",playbackStep)
            return
        end
    end
    local status=manager:GetStatus()
    print(string.format("[VehicleAudioCheck] output available=%s initialized=%s playing=%s; 无实际试听/未调用Unlock",
        tostring(status.output.available),tostring(status.output.initialized),tostring(status.output.playing)))
    manager:Stop()
    manager:Stop()
    print("[VehicleAudioCheck] PASS 资源加载与无声生命周期测试完成；完整媒体解码须另查ffmpeg结果")
end
function Stop()
    if manager then manager:Stop();manager=nil end
    if scene then scene:Dispose();scene=nil end
end
