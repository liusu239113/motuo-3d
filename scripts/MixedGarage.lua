-- 车库广告入口独立于主流程；只在完整观看成功回调中授予该车三局体验。
local M={}
local Profile=require("Profile")
local Ads=require("RewardedAds")
function M.WatchTrial(hud,id,isValid)
    local entry=require("Catalog").Get(id)
    if not entry or entry.available==false or not isValid() or Profile.Owns(id) then return end
    Ads.Show{
        isValid=isValid,
        setBusy=function(busy) hud.trialButton:SetDisabled(busy) end,
        onReward=function()
            local saved,message,applied=Profile.GrantTrials(id)
            hud:RefreshOwnership();hud:SelectVehicle(id,false)
            hud:ShowNotice(applied and "已获得三局试驾" or "奖励未入账",
                applied and (saved and "已保存。实际出发扣一次，重新比赛也会扣一次。"
                    or "奖励已记入，存档待补存，请勿退出；不需要再看广告。")
                    or (message or "请稍后重试"))
        end,
        onFailure=function(message)
            hud:ShowNotice("广告未完成",(message or "广告暂不可用").."，未增加试驾次数。")
        end}
end
return M
