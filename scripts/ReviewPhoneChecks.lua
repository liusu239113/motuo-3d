-- 显式手机与现场对话UI专项；复用main中唯一的UI.Init。
-- 入口为ReviewPhoneChecks.lua；不得叠加启动生涯、世界或其他验收的参数。
require("main")
local startGame,stopGame=Start,Stop
local UI=require("urhox-libs/UI")
local Store=require("Career.Store")
local Kit=require("Career.PhoneKit")
local View=require("Career.View")
local AppChecks=require("Career.PhoneAppChecks")
local component="ReviewPhoneRenderOnce"
---@type fun()?
local restoreStore=nil
---@type fun()?
local restoreProfile=nil
local done=false
local validating=false
local function restore()
    if restoreStore then local fn=restoreStore;restoreStore=nil;fn() end
    if restoreProfile then local fn=restoreProfile;restoreProfile=nil;fn() end
end
local function contains(r,b)
    return r.x>=b.x-1 and r.y>=b.y-1 and r.x+r.w<=b.x+b.w+1 and r.y+r.h<=b.y+b.h+1
end
---@param root Widget
local function renderText(root)
    if not root:IsVisible() then return end
    if root._className=="Label" or root._className=="Button" then root:Render(UI.GetNVGContext()) end
    for _,child in ipairs(root:GetChildren()) do renderText(child) end
end
---@param widget Widget
local function verifyText(widget)
    local p=widget.props
    if (widget._className~="Button" and widget._className~="Label") or not p.text or p.text=="" then return end
    local r=widget:GetAbsoluteLayout()
    local width=r.w-(p.paddingLeft or 0)-(p.paddingRight or 0)
    local height=r.h-(p.paddingTop or 0)-(p.paddingBottom or 0)
    local size=UI.Theme.FontSize(p.fontSize)
    local measured=UI.MeasureTextFit(p.text,{fontSize=size,minFontSize=size,
        fontFace=UI.Theme.FontFace(p.fontFamily,p.fontWeight),width=math.max(1,width-2),
        multiline=p.whiteSpace=="normal",lineHeight=p.lineHeight or 1.4,letterSpacing=p.letterSpacing or 0})
    assert(measured.height and measured.height>0,"[ReviewPhoneChecks] real font unavailable")
    assert(measured.height<=height+1,"[ReviewPhoneChecks] clipped text height "..tostring(p.id or p.text))
    if p.whiteSpace~="normal" then
        assert(measured.width<=width+1,string.format("[ReviewPhoneChecks] clipped single-line text %s measured=%.2f available=%.2f",tostring(p.id or p.text),measured.width,width))
    end
    local rendered=Kit.RenderedTextMetrics(widget)
    if rendered then assert(rendered.textHeight<=height+1,"[ReviewPhoneChecks] real Render height clipped "..tostring(p.id)) end
end
local function sizeCheck(state,width,height)
    local oldRoot,oldLayout,oldFocus=UI.GetRoot(),UI.Layout,UI.GetFocus()
    ---@type CareerView
    local fixture
    local holder=UI.Panel{width=width,height=height,padding=0}
    local actions={phone=function(page) fixture:OpenPhone(page,state,nil,nil) end,
        closePhone=function() fixture:ClosePhone() end,saveStatus=function() return "isolated review" end,
        pause=function() end,mount=function() end,interact=function() end}
    fixture=View.New(actions)
    holder:AddChild(fixture.root);UI.SetRoot(holder)
    UI.Layout=function()
        oldLayout()
        YGNodeCalculateLayout(holder.node,width,height,YGDirectionLTR)
    end
    local texts,pages,options=0,0,0
    local ok,failure=pcall(function()
        fixture.home:SetVisible(false)
        fixture:OpenPhone("life",state,nil,nil)
        Kit.LayoutTree(fixture.phoneArea)
        AppChecks.LifeTasks(fixture)
        for _,task in ipairs({"","today","food","home","supply","status","settings"}) do
            assert(fixture.phoneContent:OpenTask(task))
            for page=1,fixture.phoneContent:GetPageCount() do
                fixture.phoneContent:SetPage(page);Kit.LayoutTree(fixture.phoneArea)
                for _=1,2 do renderText(fixture.phoneBody);Kit.LayoutTree(fixture.phoneArea) end
                local function inspect(widget)
                    if not widget:IsVisible() then return end
                    verifyText(widget)
                    if widget._className=="Label" or widget._className=="Button" then texts=texts+1 end
                    for _,child in ipairs(widget:GetChildren()) do inspect(child) end
                end
                inspect(fixture.phoneBody)
                AppChecks.Audit(fixture,"render/"..width.."x"..height.."/"..task.."/"..page)
                pages=pages+1
            end
        end
        fixture:ShowConversation("早餐店站长","二狗，先别慌。手机上线就能接第一单；接到以后到这儿来，我带你核对餐袋。停车、下车，再拿餐。",{
            {id="engagement",text="问问有什么事需要帮忙",primary=true},
            {id="meal",text="先吃顿饭 · 12元"},{id="orders",text="打开外卖App接着跑"},{id="leave",text="先忙着，我再转转"}})
        for _=1,3 do UI.Layout();renderText(fixture.conversation) end
        UI.Layout()
        local rows=assert(fixture.conversationBody:FindById("career-conversation-options"))
        local bounds=rows:GetAbsoluteLayout()
        local seen={}
        for _,button in ipairs(rows:GetChildren()) do
            local r=button:GetAbsoluteLayout()
            assert(r.w>=44 and r.h>=44,string.format("[ReviewPhoneChecks] conversation target below44 %dx%d %s=(%.9f,%.9f) scale=%.9f",
                width,height,tostring(button.props.id),r.w,r.h,UI.GetScale()))
            local ancestor=button.parent
            while ancestor and ancestor~=holder do
                assert(contains(r,ancestor:GetAbsoluteLayout()),"[ReviewPhoneChecks] conversation outside ancestor "..tostring(ancestor.props.id))
                ancestor=ancestor.parent
            end
            for _,prior in ipairs(seen) do
                assert(r.x+r.w<=prior.x or prior.x+prior.w<=r.x or r.y+r.h<=prior.y or prior.y+prior.h<=r.y,
                    "[ReviewPhoneChecks] conversation choices overlap")
            end
            seen[#seen+1]=r
            verifyText(button);options=options+1
            print(string.format("[ReviewPhoneChecks] conversation %dx%d %s=(%.2f,%.2f,%.2f,%.2f) parent=(%.2f,%.2f)",
                width,height,tostring(button.props.id),r.x,r.y,r.w,r.h,bounds.w,bounds.h))
        end
        print(string.format("[ReviewPhoneChecks] PASS %dx%d / life pages=%d real text=%d conversation choices=%d",width,height,pages,texts,options))
    end)
    UI.Layout=oldLayout
    UI.SetRoot(oldRoot)
    fixture:Dispose();holder:Destroy()
    UI.Layout();UI.SetFocus(oldFocus)
    assert(ok,failure)
    return {pages=pages,texts=texts,options=options}
end
function ReviewPhoneChecksExit()
    UnsubscribeFromEvent("PostRenderUpdate")
    engine:Exit()
end
function Start()
    for _,arg in ipairs(GetArguments()) do
        if arg=="-validate" then validating=true end
        assert(not arg:match("^%-career") and not arg:match("^%-test") and arg~="-ride" and arg~="-race"
            and arg~="-challenge" and arg~="-legacy" and arg~="-selftest" and arg~="-benchmark"
            and arg~="-autotest" and not arg:match("checks$"),"[ReviewPhoneChecks] isolated entry forbids launch flag "..arg)
    end
    local files={}
    local function cloud() error("[ReviewPhoneChecks] account cloud forbidden") end
    local ok,failure=pcall(function()
        restoreProfile=require("ProfileChecks").BeginUnavailableProfile()
        restoreStore=Store.UseTestStorage({read=function(path) return files[path],nil,files[path]==nil end,
            write=function(path,text) files[path]=text;return true end,cloud={Get=cloud,Set=cloud}})
        startGame()
        UI.RegisterGlobalComponent(component,{Render=function()
            if done then return end
            done=true
            local checked,reason=pcall(function()
                assert(Store.NewCareer())
                local state=Store.Get()
                state.currentSpace="city";state.online=false;state.weatherLabel="晴朗"
                state.adSubsidyCents=500;state.musicEnabled=true;state.effectsEnabled=true
                local sizes=0
                local failures={}
                for _,size in ipairs({{1000,400},{640,360},{800,600},{390,844}}) do
                    local passed,why=pcall(sizeCheck,state,size[1],size[2])
                    if passed then sizes=sizes+1
                    else failures[#failures+1]=string.format("%dx%d %s",size[1],size[2],tostring(why));print("[ReviewPhoneChecks] SIZE FAILED "..failures[#failures]) end
                end
                local bounded,why=pcall(AppChecks.BoundedUI)
                if not bounded then failures[#failures+1]="BoundedUI "..tostring(why) end
                assert(#failures==0,table.concat(failures,"\n"))
                print("[ReviewPhoneChecks] PASS all "..sizes.." logical sizes / real NanoVG Render / isolated memory only")
            end)
            UI.UnregisterGlobalComponent(component)
            if not checked then restore();error("[ReviewPhoneChecks] FAILED "..tostring(reason),0) end
            -- validate模式由运行时完成约定帧数并写正式JSON，不能提前Exit。
            -- 非validate运行仍在当前NanoVG帧结束后退出，避免中途Shutdown。
            if not validating then SubscribeToEvent("PostRenderUpdate","ReviewPhoneChecksExit") end
        end})
    end)
    if not ok then UI.UnregisterGlobalComponent(component);restore();error(failure,0) end
end
function Stop()
    UI.UnregisterGlobalComponent(component)
    local ok,failure=pcall(stopGame)
    restore()
    if not ok then error(failure,0) end
end
