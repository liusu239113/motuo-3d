-- 真实main驾驶采样：Profile内存隔离，正式世界/九车/相机/HUD，自动结束，不调用广告。
local restore_=function() end
local ready_=false
local frames_=0
local cpuStart_=0
local solo_=false
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
        local vehicle,raceMode="beetle",true
        for _,arg in ipairs(GetArguments()) do
            vehicle=arg:match("^%-performance%-vehicle=(.+)$") or vehicle
            if arg=="-performance-solo" then raceMode=false end
        end
        assert(VehicleAssets.Vehicles[vehicle],"验收车型必须已正式交付")
        selectedTrack_,selectedVehicle_="circuit",vehicle
        hud_:SelectTrack("circuit",false);hud_:SelectVehicle(vehicle,false)
        raceAutodrive_,autoTest_=true,true
        -- 对照夹具：同赛道同车型，只切换有无对手，用于分离对手渲染开销。
        challenge=raceMode
        StartRide(raceMode);ConfirmVehicle(vehicle)
    end,
    finish=MainMenu,
    inspect=function()
        -- 采样夹具缩短静止倒计时，驾驶固定步与AI保持产品原逻辑。
        if race_ and race_.phase=="countdown" then race_.countdown=math.min(race_.countdown,.06) end
        return {screen=screen_,phase=race_ and race_.phase or "",elapsed=race_ and race_.elapsed or 0}
    end,
}
]]
function Start()
    restore_=select(1,require("GMChecks").Begin())
    for _,arg in ipairs(GetArguments()) do if arg=="-performance-solo" then solo_=true end end
    bridge_=assert(load(source().."\n"..BRIDGE,"@main.lua（性能隔离）","t",_G))()
    bridge_.start();bridge_.launch()
    SubscribeToEvent("PostRenderUpdate",function()
        if ready_ then return end
        local state=bridge_.inspect()
        if state.screen~="ride" then return end
        if state.phase~="racing" and not solo_ then return end
        frames_=frames_+1
        if frames_==1 then cpuStart_=os.clock() end
        if frames_%15==0 then
            -- 墙钟帧率从日志时间戳取；os.clock只报告本地进程CPU区间。
            print(string.format("[实赛渲染] frames=%d processCPU=%.0fms elapsed=%.2f batches=%d primitives=%d",
                frames_,(os.clock()-cpuStart_)*1000,state.elapsed,renderer.numBatches,renderer.numPrimitives))
        end
        if frames_==30 then
            for _,arg in ipairs(GetArguments()) do
                local path=arg:match("^%-performance%-shot=(screenshots/[%w_-]+%.png)$")
                if path then
                    local image=Image()
                    local captured=graphics:TakeScreenShot(image)
                    local saved=captured and image:SavePNG(path)
                    image:Dispose()
                    assert(saved,"真实九车驾驶截图保存失败")
                    print("[实赛渲染] 驾驶30帧截图 "..path)
                end
            end
        end
        if frames_==60 then
            ready_=true
            print("[实赛渲染] COMPLETE / 正式九车比赛60帧，本地软件渲染不代表手机FPS")
            bridge_.finish();restore_()
            -- 由validate帧预算收尾，保留包含加载/驾驶spike的原始JSON报告。
            for _,arg in ipairs(GetArguments()) do if arg=="-validate" then return end end
            engine:Exit()
        end
    end)
end
