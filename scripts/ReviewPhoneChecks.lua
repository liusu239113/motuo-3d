-- 显式手机与现场对话UI专项；复用main中唯一的UI.Init。
-- 入口为ReviewPhoneChecks.lua；不得叠加启动生涯、世界或其他验收的参数。
require("main")
local startGame,stopGame=Start,Stop
local UI=require("urhox-libs/UI")
local Store=require("Career.Store")
local Kit=require("Career.PhoneKit")
local View=require("Career.View")
local AppChecks=require("Career.PhoneAppChecks")
local Pages=require("Career.PhonePages")
local PointerEvent=require("urhox-libs/UI/Core/PointerEvent")
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
    local collect=fixture.phoneContent.Collect
    fixture.phoneContent.Collect=function(self,widget,budget,context)
        if widget.props.flexDirection=="row" and widget:GetLayout().h>budget then
            local tall,children=0,{}
            local available=budget-2/math.max(.1,UI.GetScale())-(widget.props.borderTopWidth or widget.props.borderWidth or 0)
                -(widget.props.borderBottomWidth or widget.props.borderWidth or 0)
            for _,child in ipairs(widget:GetChildren()) do
                if child.props.visible~=false then
                    local r=child:GetLayout()
                    if r.h>available then tall=tall+1 end
                    children[#children+1]=string.format("%s=%.2fx%.2f",tostring(child.props.id or child._className),r.w,r.h)
                end
            end
            print(string.format("[ReviewPhoneChecks] REAL oversized row app=%s parent=%s row=%s size=%dx%d scale=%.5f h=%.3f budget=%.3f oldTall=%d children=[%s]",
                fixture.phonePage,tostring(widget.parent and widget.parent.props.id),tostring(widget.props.id),width,height,UI.GetScale(),
                widget:GetLayout().h,budget,tall,table.concat(children,", ")))
        end
        return collect(self,widget,budget,context)
    end
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
        -- Exercise the real previously-uncovered anonymous rows too: delivery
        -- status/stats, wallet stats/data buttons, message avatars/info/side.
        for _,app in ipairs({"delivery","wallet","messages"}) do
            fixture.phoneChatId=""
            fixture:OpenPhone(app,state,nil,nil)
            Kit.LayoutTree(fixture.phoneArea)
            AppChecks.Audit(fixture,"real-row/"..width.."x"..height.."/"..app)
            if app=="messages" then
                for _,id in ipairs({"cousin","station_master","mechanic","journal"}) do
                    fixture.phoneChatId=id;fixture:BuildPhone(state,nil,nil)
                    Kit.LayoutTree(fixture.phoneArea)
                    AppChecks.Audit(fixture,"real-chat/"..width.."x"..height.."/"..id)
                end
            end
        end
        fixture:ClosePhone()
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
-- Mounted, real-Yoga regressions for the former #tall==1 assertion. These are
-- UI-only objects: never dispatch production save/load/cloud/business actions.
local function paginationCheck()
    local savedRoot,savedFocus=UI.GetRoot(),UI.GetFocus()
    local savedScale=UI.GetScale()
    local config=YGConfigGetDefault()
    local savedPointScale=YGConfigGetPointScaleFactor(config)
    ---@type Widget?
    local holder=nil
    local cases=0
    local function near(a,b) return a==b or (a~=a and b~=b) or math.abs(a-b)<.001 end
    local dimensionGetters={YGNodeStyleGetWidth,YGNodeStyleGetHeight,YGNodeStyleGetMinHeight,
        YGNodeStyleGetMaxHeight,YGNodeStyleGetFlexBasis}
    local enumGetters={YGNodeStyleGetFlexDirection,YGNodeStyleGetFlexWrap,YGNodeStyleGetFlexGrow,
        YGNodeStyleGetFlexShrink,YGNodeStyleGetAlignItems,YGNodeStyleGetJustifyContent}
    local function snapshot(widget)
        local result={dimensions={},enums={},padding={}}
        for i,get in ipairs(dimensionGetters) do result.dimensions[i]=get(widget.node) end
        for i,get in ipairs(enumGetters) do result.enums[i]=get(widget.node) end
        for _,edge in ipairs({YGEdgeTop,YGEdgeBottom}) do result.padding[edge]=YGNodeStyleGetPadding(widget.node,edge) end
        return result
    end
    local function sameStyle(widget,before)
        local after=snapshot(widget)
        for i,value in ipairs(before.dimensions) do
            assert(after.dimensions[i].unit==value.unit and near(after.dimensions[i].value,value.value),"RestoreSource lost dimension unit/value")
        end
        for i,value in ipairs(before.enums) do assert(near(after.enums[i],value),"RestoreSource lost flex style") end
        for edge,value in pairs(before.padding) do
            assert(after.padding[edge].unit==value.unit and near(after.padding[edge].value,value.value),"RestoreSource lost padding")
        end
    end
    local ok,failure=pcall(function()
        for _,scale in ipairs({.625,.8333333333,1,1.5}) do
            UI.SetScale(scale);YGConfigSetPointScaleFactor(config,scale)
            holder=UI.Panel{width=640,height=360,padding=8,gap=8}
            local pages=Pages{width=224,height=102,padding=0,overflow="hidden"}
            local previous=Kit.Button("上一页",function() pages:SetPage(pages:GetPage()-1) end,"regression-prev",false,{width=90})
            local following=Kit.Button("下一页",function() pages:SetPage(pages:GetPage()+1) end,"regression-next",false,{width=90})
            local number=Kit.Text("",10,nil,{width=70})
            local pager=UI.Row{padding=0,gap=6,children={previous,number,following}}
            pages:AttachPager(previous,following,number,pager)
            holder:AddChild(pages);holder:AddChild(pager);UI.SetRoot(holder)
            local function settle()
                for _=1,4 do UI.Layout();pages:Update(0) end
                UI.Layout()
            end
            local function touch(widget)
                local r=widget:GetAbsoluteLayoutForHitTest()
                assert(r.w>=44 and r.h>=44,"regression target below 44")
                local function event(kind)
                    return PointerEvent.new(kind,{pointerId=791217,pointerType="touch",isPrimary=true,
                        x=(r.x+r.w/2)*scale,y=(r.y+r.h/2)*scale,button=PointerEvent.Button.Left})
                end
                local down,up=event("PointerDown"),event("PointerUp")
                UI.HandlePointerEvent(down);UI.HandlePointerEvent(up)
                assert(down.target==widget and up.target==widget,"regression actual pointer target mismatch")
            end
            for _,kind in ipairs({"zero-min","zero-padding","zero-wrap","multiple","one-tall","boundary"}) do
                Kit.Clear(pages);pages:SetPage(1)
                local clicked={}
                local buttons={}
                local hidden=Kit.Button("业务隐藏",function() error("hidden control activated") end,"regression-hidden",false,{visible=false})
                -- Deliberately id=nil: this is the reported production error.
                local row=UI.Row{width="100%",padding=0,gap=5,alignItems="flex-start"}
                local function button(index,props)
                    local item=Kit.Button("操作"..index,function() clicked[index]=(clicked[index] or 0)+1 end,"regression-action-"..index,false,props)
                    buttons[#buttons+1]=item
                    return item
                end
                if kind=="zero-min" or kind=="zero-padding" or kind=="boundary" then
                    row:SetStyle{alignItems="center"}
                    if kind=="zero-min" then row:SetStyle{minHeight=165,maxHeight="180%"}
                    elseif kind=="zero-padding" then row:SetStyle{paddingTop=45,paddingBottom=45}
                    else
                        local edge=2/scale
                        row:SetStyle{height=102-edge+1/scale}
                    end
                    row:AddChild(button(1,{width="46%"}));row:AddChild(button(2,{width="46%"}))
                elseif kind=="zero-wrap" then
                    row:SetStyle{flexWrap="wrap",rowGap=7}
                    for i=1,6 do row:AddChild(button(i,{width="48%"})) end
                elseif kind=="multiple" then
                    for i=1,2 do
                        row:AddChild(UI.Panel{width="48%",flexGrow=1,flexShrink=1,flexBasis=0,padding=0,gap=5,children={
                            Kit.Text("双列自然高度随宽度变化，完整正文不能裁切。"..string.rep("逐项核对信息。",16),11,nil,{id="regression-long-"..i}),
                            button(i,{width="100%"})}})
                    end
                else
                    row:AddChild(UI.Panel{width=28,height=28,padding=0})
                    row:AddChild(UI.Panel{width="78%",padding=0,gap=5,children={
                        Kit.Text(string.rep("保留头像并完整继续正文。",35),11,nil,{id="regression-long-1"}),button(1,{width="100%"})}})
                end
                row:AddChild(hidden);pages:AddChild(row)
                UI.Layout()
                for _=1,5 do
                    local function natural(widget)
                        if widget.Update and widget~=pages then widget:Update(0) end
                        for _,child in ipairs(widget:GetChildren()) do natural(child) end
                    end
                    natural(row);UI.Layout()
                end
                local before={}
                local callbacks={}
                local function save(widget)
                    before[widget]=snapshot(widget)
                    callbacks[widget]={visible=widget.props.visible,onClick=widget.props.onClick,isVisible=widget.IsVisible}
                    for _,child in ipairs(widget:GetChildren()) do save(child) end
                end
                save(row)
                local budget=pages:GetLayout().h-2/scale
                local tall=0
                for _,child in ipairs(row:GetChildren()) do
                    if child.props.visible~=false and child:GetLayout().h>budget-2/scale then tall=tall+1 end
                end
                assert(row:GetLayout().h>budget,"regression must start oversized "..kind)
                if kind=="multiple" then assert(tall==2,"regression requires two real tall columns")
                elseif kind=="one-tall" then assert(tall==1,"regression requires exactly one tall column")
                else assert(tall==0,"regression requires zero real tall columns "..kind) end
                print(string.format("[ReviewPhoneChecks] row %s scale=%.5f rowH=%.3f budget=%.3f tall=%d",kind,scale,row:GetLayout().h,budget,tall))
                pages:Paginate();settle()
                assert(pages:GetPageCount()>0 and pages.signature==pages:SourceSignature(),"pagination did not settle")
                local continuations={}
                for _,unit in ipairs(pages.units) do
                    if unit.widget~=unit.source then
                        continuations[unit.source]=(continuations[unit.source] or "")..unit.widget.props.text
                    end
                end
                for source,text in pairs(continuations) do assert(text==source.props.text,"continuation changed UTF8 text") end
                local visited={}
                for page=1,pages:GetPageCount() do
                    assert(pages:GetPage()==page,"button pager did not advance")
                    settle()
                    local function inspect(widget)
                        if not widget:IsVisible() then return end
                        local r=widget:GetAbsoluteLayout()
                        assert(contains(r,pages:GetAbsoluteLayout()),"regression clipped full unit "..kind.." / "..tostring(widget.props.id))
                        if widget.parent then
                            local parent=widget.parent:GetAbsoluteLayout()
                            assert(contains(r,parent),string.format("regression outside parent %s / %s:%s child=(%.4f,%.4f,%.4f,%.4f) parent=%s:(%.4f,%.4f,%.4f,%.4f) scale=%.5f page=%d",
                                kind,tostring(widget._className),tostring(widget.props.id),r.x,r.y,r.w,r.h,tostring(widget.parent.props.id),
                                parent.x,parent.y,parent.w,parent.h,scale,page))
                        end
                        assert(widget._className~="ScrollView","phone regression must not use scroll")
                        local hit=widget:GetAbsoluteLayoutForHitTest()
                        assert(near(r.x,hit.x) and near(r.y,hit.y) and near(r.w,hit.w) and near(r.h,hit.h),"render/hit boundaries differ")
                        if widget._className=="Label" or widget._className=="Button" then verifyText(widget) end
                        if callbacks[widget] then visited[widget]=true end
                        for _,child in ipairs(widget:GetChildren()) do inspect(child) end
                    end
                    renderText(pages);UI.Layout();inspect(row)
                    for _,item in ipairs(buttons) do if item:IsVisible() then touch(item) end end
                    if page<pages:GetPageCount() then touch(following) end
                end
                for index,item in ipairs(buttons) do assert(visited[item] and clicked[index],"lost button/callback") end
                assert(not hidden:IsVisible() and hidden.props.visible==false,"business visible changed")
                local pageCount=pages:GetPageCount()
                local original=pages.Paginate
                local calls=0
                pages.Paginate=function(self) calls=calls+1;return original(self) end
                for _=1,30 do pages:Update(0) end
                assert(calls==0,"stable row re-paginates every frame")
                pages.Paginate=original
                -- Width/height changes must restore/re-measure natural labels,
                -- not keep the tall classification from the old wrapping width.
                pages:SetStyle{width=196,height=85};settle()
                for _,item in ipairs(buttons) do assert(pages:ShowWidget(item),"resize lost original action") end
                pages:RestoreSource();UI.Layout()
                for widget,style in pairs(before) do
                    -- Natural text height legitimately changes on resize.
                    if widget._className~="Label" then sameStyle(widget,style) end
                    assert(widget.props.visible==callbacks[widget].visible and widget.props.onClick==callbacks[widget].onClick
                        and widget.IsVisible==callbacks[widget].isVisible,"restore changed source callback/visible/method")
                end
                assert(#pages.constraints==0 and #pages.generated==0 and row:GetNumChildren()>0,"restore left temporary state")
                pages:SetStyle{width=224,height=102}
                cases=cases+1
                print(string.format("[ReviewPhoneChecks] pagination PASS %s / scale %.5f / %d pages / restore+resize+actual touches",kind,scale,pageCount))
            end
            UI.SetRoot(savedRoot);holder:Destroy();holder=nil
        end
    end)
    if holder then UI.SetRoot(savedRoot);holder:Destroy() end
    UI.SetScale(UI.Scale.DEFAULT);YGConfigSetPointScaleFactor(config,savedPointScale)
    assert(near(UI.GetScale(),savedScale),"regression did not restore default UI scale")
    UI.SetRoot(savedRoot);UI.Layout();UI.SetFocus(savedFocus)
    assert(ok,failure)
    print("[ReviewPhoneChecks] pagination PASS all "..cases.." mounted short-landscape/scale cases")
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
                local paginationPassed,paginationFailure=pcall(paginationCheck)
                if not paginationPassed then failures[#failures+1]="Pagination "..tostring(paginationFailure) end
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
