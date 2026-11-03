-- 真实main驾驶采样：Profile内存隔离，正式世界/九车/相机/HUD，自动结束，不调用广告。
local restore_=function() end
local ready_=false
local frames_=0
local wallStart_=0
local bridge_={inspect=function() return {screen="",phase="",elapsed=0} end}
local function source()
    local file=assert(cache:GetFile("main.lua"))
    local lines={}
    while not file:IsEof() do lines[#lines+1]=file:ReadLine() end
    file:Dispose()
    return table.concat(lines,"\n")
end
local BRIDGE=[[
return {
    start=Start,
    launch=function()
        Catalog.SetGMFreeExperience(true)
        selectedTrack_,selectedVehicle_="circuit","beetle"
        hud_:SelectTrack("circuit",false);hud_:SelectVehicle("beetle",false)
        raceAutodrive_,autoTest_=true,true
        StartRide(true);ConfirmVehicle("beetle")
    end,
    inspect=function() return {screen=screen_,phase=race_ and race_.phase or "",elapsed=race_ and race_.elapsed or 0} end,
}
]]
function Start()
    restore_=select(1,require("GMChecks").Begin())
    bridge_=assert(load(source().."\n"..BRIDGE,"@main.lua（性能隔离）","t",_G))()
    bridge_.start();bridge_.launch()
    SubscribeToEvent("PostRenderUpdate",function()
        if ready_ then return end
        local state=bridge_.inspect()
        if state.screen~="ride" or state.phase~="racing" then return end
        frames_=frames_+1
        if frames_==1 then wallStart_=time:GetTimeSinceEpochMs() end
        if frames_%15==0 then
            print(string.format("[实赛渲染] frames=%d wall=%.0fms elapsed=%.2f batches=%d primitives=%d",
                frames_,time:GetTimeSinceEpochMs()-wallStart_,state.elapsed,renderer.numBatches,renderer.numPrimitives))
        end
        if frames_==60 then
            ready_=true
            print("[实赛渲染] COMPLETE / 正式九车比赛60帧，本地软件渲染不代表手机FPS")
            restore_();engine:Exit()
        end
    end)
end
