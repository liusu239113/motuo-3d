-- GM回归使用真实Profile源码和局部内存文件系统，不访问玩家档或真实广告SDK。
local Checks={}
local function source(name)
    local file=assert(cache:GetFile(name))
    local lines={}
    while not file:IsEof() do lines[#lines+1]=file:ReadLine() end
    file:Dispose()
    return table.concat(lines,"\n")
end
function Checks.Begin()
    -- 使用模块正常序列化的新档作为种子，不猜测试驾字段格式。
    local files={}
    local writes=0
    local env=setmetatable({fileSystem={
        FileExists=function(_,p) return files[p]~=nil end,
        Copy=function(_,a,b) files[b]=files[a];return true end,
        Rename=function(_,a,b) files[b],files[a]=files[a],nil;return true end,
        Delete=function(_,p) files[p]=nil;return true end},
        File=function(p,mode)
            assert(p:match("^pursuit_profile%.txt"),"禁止访问玩家文件")
            if mode==FILE_WRITE then writes=writes+1;files[p]="" end
            return {IsOpen=function() return mode==FILE_WRITE or files[p]~=nil end,
                ReadString=function() return files[p] end,
                WriteString=function(_,text) files[p]=text;return true end,
                Flush=function() end,Close=function() end,Dispose=function() end}
        end},{__index=_G})
    local isolated=assert(load(source("Profile.lua"),"GM隔离Profile","t",env))()
    assert(isolated.TryLoad())
    local data=isolated.Get()
    data.coins=2300;data.trials.helicopter=2
    assert(isolated.Save())
    local Profile=require("Profile")
    local previous={}
    for k,v in pairs(isolated) do previous[k]=Profile[k];Profile[k]=v end
    local restored=false
    return function()
        if restored then return end
        restored=true
        for k in pairs(isolated) do Profile[k]=previous[k] end
    end,function() return writes,files["pursuit_profile.txt"] end
end

---@param hud HUD
function Checks.Run(hud,storage)
    local Catalog=require("Catalog")
    local Profile=require("Profile")
    local UI=require("urhox-libs/UI")
    local Pointer=require("urhox-libs/UI/Core/PointerEvent")
    local count=0
    local function check(v,message) assert(v,"[GMChecks] "..message);count=count+1 end
    local function click(widget)
        UI.Layout()
        local r=widget:GetAbsoluteLayout()
        check(r.w>0 and r.h>0,"真实按钮必须有可触摸尺寸")
        for _,kind in ipairs({Pointer.Types.PointerDown,Pointer.Types.PointerUp}) do
            local scale=UI.GetScale()
            local down=kind==Pointer.Types.PointerDown
            local event=Pointer.new(kind,{pointerId=811,x=(r.x+r.w*.5)*scale,y=(r.y+r.h*.5)*scale,
                button=Pointer.Button.Left,buttons=down and Pointer.Buttons.Primary or Pointer.Buttons.None,
                pointerType=Pointer.PointerTypes.Touch,isPrimary=true,pressure=down and .5 or 0})
            UI.HandlePointerEvent(event)
            check(event.target==widget,"真实指针必须命中按钮而非直接调用回调")
        end
    end
    local beforeWrites,beforeText=storage()
    check(not Catalog.IsGMFreeExperience(),"启动默认关闭")
    check(not Catalog.CanDrive("helicopter") or Profile.Trials("helicopter")==2,"原始试驾权益保留")
    hud.actions.start(false)
    hud:SelectVehicle("helicopter",true)
    click(hud.garageGMButton)
    check(Catalog.IsGMFreeExperience(),"车库真实指针点击可开启GM")
    check(hud.confirmButton.props.text=="GM 免费体验 · 出发 →","发车文案准确")
    check(not hud.buyButton:IsVisible() and not hud.trialButton:IsVisible(),"GM隐藏经济入口")
    local ready=0
    local unavailableId=""
    for _,v in ipairs(Catalog.List) do
        if v.available then
            ready=ready+1
            check(Catalog.CanFreeExperience(v.id) and Catalog.CanDrive(v.id),v.id.."免费驾驶")
            for _=1,4 do check(Catalog.ConsumeDriveTrial(v.id),v.id.."发车及重赛不扣次") end
        else
            check(not Catalog.CanFreeExperience(v.id),v.id.."未交付不能绕过")
            if unavailableId=="" then unavailableId=v.id end
        end
    end
    check(ready>=11,"覆盖所有已登记正式车型，不硬编码两种")
    check(not Catalog.CanFreeExperience("missing"),"未知车型不可驾驶")
    hud.actions.buyVehicle("helicopter")
    hud.actions.watchVehicleAd("helicopter")
    check(Profile.Coins()==2300 and not Profile.Owns("helicopter") and Profile.Trials("helicopter")==2,
        "购买及广告直调不改变金币、永久所有权和次数")
    click(hud.confirmButton)
    check(hud.screen=="loading","真实车库确认按钮可免费发车")
    hud.actions.menu()
    hud.actions.start(false)
    if unavailableId~="" then
        hud:SelectVehicle(unavailableId,true)
        check(hud.confirmButton.props.disabled==true
            and hud.vehicleBadges[unavailableId]:GetText()=="准备中 · 不可驾驶",
            "GM下未交付车型仍明确禁用："..unavailableId)
        hud.actions.confirmVehicle(unavailableId)
        check(hud.screen=="garage","主入口也阻止未交付车："..unavailableId)
    end
    hud.actions.menu();hud:OpenSettings();UI.Layout()
    local r=hud.gmFreeButton:GetAbsoluteLayout()
    local w,h=UI.GetViewportSize()
    check(r.x>=0 and r.y>=0 and r.x+r.w<=w+1 and r.y+r.h<=h+1,"设置开关落在屏内")
    click(hud.gmFreeButton)
    check(not Catalog.IsGMFreeExperience(),"设置真实点击可关闭GM")
    check(not Catalog.CanDrive("rally") and Profile.Trials("helicopter")==2,"关闭恢复原权限和未消耗次数")
    local afterWrites,afterText=storage()
    check(beforeWrites==afterWrites and beforeText==afterText,"整个GM选车/发车/重赛/切换无存档写入")
    check(Catalog.ConsumeDriveTrial("helicopter") and Profile.Trials("helicopter")==1,"关闭后正常出发扣一次")
    hud.actions.menu()
    -- 迟到广告使用真实广告状态机，仅SDK回调是本地桩。
    local callback=function() end
    local calls=0
    local ads=assert(load(source("RewardedAds.lua"),"GM隔离广告","t",setmetatable({
        sdk={ShowRewardVideoAd=function(_,cb) calls=calls+1;callback=cb;return true end}},{__index=_G})))()
    local garage=assert(load(source("MixedGarage.lua"),"GM隔离车库","t",setmetatable({require=function(name)
        if name=="RewardedAds" then return ads end
        return require(name)
    end},{__index=_G})))()
    garage.WatchTrial(hud,"helicopter",function() return true end)
    check(calls==1 and ads.IsBusy(),"普通广告真实状态机已持有请求")
    Catalog.SetGMFreeExperience(true)
    callback({success=true})
    check(Profile.Trials("helicopter")==1 and not ads.IsBusy(),"GM开启后迟到成功不发试驾")
    garage.WatchTrial(hud,"helicopter",function() return true end)
    check(calls==1,"GM下底层车库入口不请求SDK")
    Catalog.SetGMFreeExperience(false)
    hud:SelectVehicle("sport",true)
    for _,arg in ipairs(GetArguments()) do
        if arg=="-gmshowcase" then
            hud.actions.start(false);hud:SelectVehicle("helicopter",true)
            hud.actions.toggleGMFreeExperience()
        elseif arg=="-gmsettingsshowcase" then
            hud:OpenSettings();hud.actions.toggleGMFreeExperience()
        end
    end
    print(string.format("[GMChecks] PASS %d项 / %d台正式车型 / 玩家档和真实SDK未访问",count,ready))
    return true
end
-- 不启用autotest/testShot豁免，沿正式加载、实际提交与缓存重赛走两次发车。
function Checks.RunDrive(hud,storage,restore)
    local Catalog=require("Catalog")
    local Profile=require("Profile")
    local originalWrites,originalText=storage()
    local stage,frames=0,0
    local vehicleId="helicopter"
    for _,arg in ipairs(GetArguments()) do
        local selected=arg:match("^%-gmdrivevehicle=(.+)$")
        if selected then
            assert(selected=="tank" or selected=="beetle" or selected=="helicopter","GM流程车型参数无效")
            vehicleId=selected
        end
    end
    Catalog.SetGMFreeExperience(true)
    assert(Catalog.CanFreeExperience(vehicleId),"GM流程所选车型尚未正式开放："..vehicleId)
    hud.actions.start(false);hud:SelectVehicle(vehicleId,true)
    hud.actions.confirmVehicle(vehicleId)
    local function verify()
        local writes,text=storage()
        assert(writes==originalWrites and text==originalText,"GM实际发车不得写档或消费试驾")
        assert(Profile.Trials("helicopter")==1 and not Profile.Owns("helicopter") and Profile.Coins()==2300)
    end
    -- 不抢占主入口唯一的Update订阅；此验收不启用testShot的截图订阅。
    SubscribeToEvent("PostRenderUpdate",function()
        if stage==2 then return end
        frames=frames+1
        if frames>=1400 then restore();error("GM真实发车流程超时") end
        if hud.screen=="loading" and hud.enterRide:IsVisible() then hud.actions.enter() end
        if hud.screen=="ride" then
            verify()
            assert(hud.selectedVehicle==vehicleId and Catalog.CanFreeExperience(vehicleId)
                and not Profile.Owns(vehicleId),"GM实际发车所选车型必须保持免费体验且未获永久所有权")
            if stage==0 then
                stage=1
                hud.actions.restart()
                assert(hud.screen=="loading","重赛必须重新准备并提交")
            else
                hud.actions.menu()
                Catalog.SetGMFreeExperience(false)
                hud:SelectVehicle(vehicleId,true)
                verify();restore();stage=2
                print("[GMChecks] "..vehicleId.." 实际加载→发车→缓存重赛两次均不扣币/次数/写档 PASS")
            end
        end
    end)
end
return Checks
