-- 显式整改短验收入口；复用正式HUD/主入口，初始化前隔离档案，检查不访问真实广告SDK。
require("main")
local startGame,stopGame=Start,Stop
local Store=require("Career.Store")
---@type fun()?
local restoreStore=nil
---@type fun()?
local restoreProfile=nil
local function restoreIsolation()
    if restoreStore then local restore=restoreStore;restoreStore=nil;restore() end
    if restoreProfile then local restore=restoreProfile;restoreProfile=nil;restore() end
end
function Start()
    -- 正式HUD构造也会查询竞速权益；隔离必须早于startGame，不能只隔离后面的业务短测。
    for _,arg in ipairs(GetArguments()) do
        assert(not arg:match("^%-career") and not arg:match("checks$")
            and arg~="-ride" and arg~="-race" and arg~="-challenge" and arg~="-legacy"
            and arg~="-selftest" and arg~="-tracktest" and arg~="-racetest" and arg~="-raceautodrive"
            and arg~="-autotest" and arg~="-benchmark","整改短验收不能叠加其他业务启动参数："..arg)
    end
    local files={}
    local function forbiddenCloud() error("整改短验收禁止访问账号云档") end
    restoreProfile=require("ProfileChecks").BeginUnavailableProfile()
    restoreStore=Store.UseTestStorage({read=function(path) return files[path],nil,files[path]==nil end,
        write=function(path,text) files[path]=text;return true end,
        cloud={Get=forbiddenCloud,Set=forbiddenCloud}})
    local ok,message=pcall(function()
        startGame()
        assert(require("Career.WorldStreamChecks").Run().passed)
        require("Career.WorldChecks").NavigationPlan()
        require("Career.CityEnvironmentChecks").BoundaryPlan()
        require("Career.ProgressionChecks").Run()
        require("AudioChecks").Run()
        require("AudioChecks").SessionTransitions()
        require("ProfileChecks").Run()
        require("RewardedAdsChecks").Run()
        require("Career.PhoneAppChecks").BoundedUI()
        require("Career.MapOverlay").Checks()
        print("[整改短验收] 全部检查执行完成；初始化及专项全内存隔离，无玩家档与真实SDK访问")
    end)
    if not ok then restoreIsolation();error(message,0) end
end
function Stop()
    local ok,message=pcall(stopGame)
    restoreIsolation()
    if not ok then error(message,0) end
end
