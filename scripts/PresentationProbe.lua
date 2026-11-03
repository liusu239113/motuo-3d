-- 界面实拍夹具：唯一UI.Init，临时内存状态，不加载城市、不触碰玩家存档。
local UI=require("urhox-libs/UI")
local Theme=require("RacingTheme")
local View=require("Career.View")
local Store=require("Career.Store")
---@type table?
local view_=nil
local mode_="loading"
function Start()
    UI.Init{theme=Theme.Theme,scale=UI.Scale.DEFAULT}
    for _,arg in ipairs(GetArguments()) do mode_=arg:match("^%-presentation=(%a+)$") or mode_ end
    local function noop() end
    view_=View.New{phone=noop,pause=noop,mount=noop,interact=noop,startCareer=noop,legacy=noop}
    UI.SetRoot(view_.root)
    if mode_=="loading" then
        view_:ShowLoading("正在下载骑行资源","下载器实时进度；已有资源直接复用，不重复下载。",.39,"34.72 / 89.03 MB · 125/320 项")
    elseif mode_=="hud" then
        local files={}
        Store.WithTestStorage({read=function(path) return files[path],nil,files[path]==nil end,
            write=function(path,text) files[path]=text;return true end},function()
            assert(Store.NewCareer())
            local state=Store.Get()
            state.currentSpace="city";state.online=false
            state.hunger,state.energy,state.battery=65,80,77
            state.nextGoal={title="完成第一单，攒下下一餐生活费"}
            local target={id="breakfast",name="老街早餐店",distance=168,x=-25,z=-10,hint="停稳取餐",route={}}
            view_:ShowGame()
            view_.game:SetStyle{backgroundColor={56,68,76,255}}
            view_:Update(state,{x=0,z=-20,yaw=0,speed=6,mounted=true,vehicleId="borrowed_ebike"},target,nil,nil,0)
        end)
    else view_:ShowHome(false) end
    SubscribeToEvent("Update","PresentationUpdate")
end
function PresentationUpdate()
    if view_ then view_:LayoutControls() end
end
function Stop()
    if view_ then view_:Dispose();view_=nil end
    UI.Shutdown()
end
