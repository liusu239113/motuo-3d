-- 独立HUD/全图验收入口。复用main.Start唯一UI.Init，只在其已开始的NanoVG帧内绘制。
-- 构建entry=ReviewHudChecks.lua；不要叠加-careerchecks/-career/-ride等启动世界的参数。
-- 无玩家档访问：正式Start之前安装Store内存桩与既有Profile隔离桩，Stop/failure均finally恢复。
require("main")
local startGame,stopGame=Start,Stop
local UI=require("urhox-libs/UI")
local Store=require("Career.Store")
local componentName="ReviewCareerHudOnce"
---@type fun()?
local restoreStore=nil
---@type fun()?
local restoreProfile=nil
local done=false
local function restoreIsolation()
    if restoreStore then local restore=restoreStore;restoreStore=nil;restore() end
    if restoreProfile then local restore=restoreProfile;restoreProfile=nil;restore() end
end
function ReviewHudChecksExit()
    UnsubscribeFromEvent("PostRenderUpdate")
    engine:Exit()
end
function Start()
    for _,arg in ipairs(GetArguments()) do
        assert(not arg:match("^%-career") and not arg:match("^%-test")
            and arg~="-ride" and arg~="-race" and arg~="-challenge" and arg~="-legacy"
            and arg~="-selftest" and arg~="-tracktest" and arg~="-racetest" and arg~="-raceautodrive"
            and arg~="-benchmark" and arg~="-autotest"
            and (not arg:match("checks$") or arg=="-reviewhudchecks"),
            "[ReviewHudChecks] 独立入口不能叠加启动城市/竞速或其他验收参数："..arg)
    end
    local files={}
    local function forbiddenCloud() error("[ReviewHudChecks] 禁止访问账号云档") end
    local ok,failure=pcall(function()
        -- 在正式Start之前隔离，覆盖HUD构造的旧竞速显示查询与Session.Home的HasSave。
        restoreProfile=require("ProfileChecks").BeginUnavailableProfile()
        restoreStore=Store.UseTestStorage({read=function(path) return files[path],nil,files[path]==nil end,
            write=function(path,text) files[path]=text;return true end,
            cloud={Get=forbiddenCloud,Set=forbiddenCloud}})
        startGame()
        assert(UI.IsEnabled() and UI.GetRoot(),"[ReviewHudChecks] 正式Start必须已建立唯一UI")
        UI.RegisterGlobalComponent(componentName,{Render=function()
            if done then return end
            done=true -- 即使断言失败，也不能下一帧重跑或堆积控件。
            local checked,reason=pcall(function()
                local report={resolutions=0,assertions=0,texts=0,touches=0}
                -- 独立临时新档，仅提供生产默认状态。没有Session/城市/物理/音频构造。
                local snapshots={}
                Store.WithTestStorage({read=function(path) return snapshots[path],nil,snapshots[path]==nil end,
                    write=function(path,text) snapshots[path]=text;return true end,
                    cloud={Get=forbiddenCloud,Set=forbiddenCloud}},function()
                    assert(Store.NewCareer())
                    local state=Store.Get()
                    local checks=require("Career.HudLayoutChecks")
                    local failures={}
                    for _,size in ipairs({{1000,400},{640,360},{800,600},{390,844}}) do
                        -- 每个Size都有finally；聚合保留全部真实失败，不因首尺寸失败漏测后续。
                        local passed,result=pcall(checks.Size,state,size[1],size[2])
                        if passed then
                            assert(result.passed)
                            report.resolutions=report.resolutions+1
                            report.assertions=report.assertions+result.assertions
                            report.texts=report.texts+result.texts
                            report.touches=report.touches+result.touches
                        else
                            local message=string.format("%dx%d: %s",size[1],size[2],tostring(result))
                            failures[#failures+1]=message
                            print("[ReviewHudChecks] SIZE FAILED "..message)
                        end
                    end
                    assert(#failures==0,"[ReviewHudChecks] 多尺寸失败 "..table.concat(failures,"；"))
                end)
                require("Career.LoadingChecks").Run()
                local atlas=require("Career.MapOverlay").Checks()
                print(string.format("[ReviewHudChecks] PASS HUD=%d尺寸/%d断言/%d真实字体/%d触摸；全图=%d尺寸/%d按钮；唯一正式UI/NanoVG帧/全内存无玩家档",
                    report.resolutions,report.assertions,report.texts,report.touches,atlas.sizes,atlas.buttons))
            end)
            UI.UnregisterGlobalComponent(componentName)
            if not checked then
                restoreIsolation()
                error("[ReviewHudChecks] FAILED "..tostring(reason),0)
            end
            -- validate必须由正常帧循环写JSON；只在普通专项运行时主动结束。
            local validating=false
            for _,arg in ipairs(GetArguments()) do if arg=="-validate" then validating=true;break end end
            if not validating then
                -- 不在NanoVG帧中途Exit/Shutdown，等该帧完整结束后释放UI及桩。
                SubscribeToEvent("PostRenderUpdate","ReviewHudChecksExit")
            end
        end})
    end)
    if not ok then
        UI.UnregisterGlobalComponent(componentName)
        restoreIsolation()
        error(failure,0)
    end
    print("[ReviewHudChecks] 已排队到正式UI的首个NanoVG Render；不启动城市、不读取玩家档")
end
function Stop()
    UI.UnregisterGlobalComponent(componentName)
    local ok,failure=pcall(stopGame)
    restoreIsolation()
    if not ok then error(failure,0) end
end
