-- 多尺寸真实生涯HUD专项。只创建生产View控件树；不启动城市、不写档、不推进会话。
-- UI初始化后 require("Career.HudLayoutChecks").Run(session)。可单测 .Size(state,w,h)。
local UI=require("urhox-libs/UI")
local View=require("Career.View")
local Kit=require("Career.PhoneKit")
local Life=require("Career.LifeStatus")
local Config=require("Career.Config")
local PointerEvent=require("urhox-libs/UI/Core/PointerEvent")
local Checks={}
local function demand(ok,message) assert(ok,"[HudLayoutChecks] "..message) end
local function name(widget) return tostring(widget.props.id or widget.props.text or widget._className) end
local function contains(a,b)
    return a.x>=b.x-1 and a.y>=b.y-1 and a.x+a.w<=b.x+b.w+1 and a.y+a.h<=b.y+b.h+1
end
-- 仅边界包含判断容许各Yoga节点独立取整；重叠、至少44触摸尺寸、
-- 至少18物理字号的要求均不放宽。
local function disjoint(a,b)
    return a.x+a.w<=b.x or b.x+b.w<=a.x or a.y+a.h<=b.y or b.y+b.h<=a.y
end
local function copy(source)
    local result={}
    for key,value in pairs(source) do result[key]=value end
    return result
end
---@param state table 从session:State()复制的只读状态。
---@param width number 请求的UI基准像素宽度，不是物理帧缓冲尺寸。
---@param height number 请求的UI基准像素高度。
function Checks.Size(state,width,height)
    demand(UI.IsEnabled() and UI.GetRoot()~=nil,"需要已初始化且挂载的真实UI")
    demand(not UI.Input.HasActivePointer(),"不能打断真实触摸")
    demand(UI.GetTopOverlay()==nil,"请先关闭真实模态")
    local oldRoot,oldFocus,oldLayout=UI.GetRoot(),UI.GetFocus(),UI.Layout
    local calls={phone=0,pause=0,mount=0,interact=0,sound=0}
    local fixture=View.New({phone=function(page) demand(page=="apps","手机回调必须指向应用桌面");calls.phone=calls.phone+1 end,
        pause=function() calls.pause=calls.pause+1 end,mount=function() calls.mount=calls.mount+1 end,
        interact=function() calls.interact=calls.interact+1 end,sound=function() calls.sound=calls.sound+1 end})
    local holder=UI.Panel{width=width,height=height,padding=0,children={fixture.root}}
    UI.SetRoot(holder)
    -- 当前UI模块没有UI.SetScreenSize。沿用RacingUIChecks方法，
    -- 每次布局（包括文字更新）均约束到请求尺寸，同时保留真实字体、缩放和命中。
    UI.Layout=function()
        oldLayout()
        YGNodeCalculateLayout(holder.node,width,height,YGDirectionLTR)
    end
    local pointers={}
    local assertions,texts,touches=0,0,0
    local context=string.format("%.0fx%.0f scale=%.4f",width,height,UI.GetScale())
    local function check(ok,message)
        demand(ok,context.." / "..message)
        assertions=assertions+1
    end
    local function send(kind,id,x,y)
        local ending=kind==PointerEvent.Types.PointerUp or kind==PointerEvent.Types.PointerCancel
        local event=PointerEvent.new(kind,{pointerId=id,pointerType=PointerEvent.PointerTypes.Touch,
            x=x*UI.GetScale(),y=y*UI.GetScale(),isPrimary=id==792501,button=PointerEvent.Button.Left,
            buttons=ending and PointerEvent.Buttons.None or PointerEvent.Buttons.Primary,pressure=ending and 0 or .5})
        if not ending then pointers[id]={x=x,y=y} end
        UI.HandlePointerEvent(event)
        if ending then pointers[id]=nil end
        return event
    end
    local function rect(widget)
        local r=widget:GetAbsoluteLayout()
        check(r.w>0 and r.h>0 and r.x==r.x and r.y==r.y and r.w<math.huge and r.h<math.huge,
            "可见节点必须有有限正布局 "..name(widget))
        local screen=fixture.root:GetAbsoluteLayout()
        check(contains(r,screen),string.format("越出屏幕 %s (%.1f,%.1f %.1fx%.1f) / 屏幕 (%.1f,%.1f %.1fx%.1f)",
            name(widget),r.x,r.y,r.w,r.h,screen.x,screen.y,screen.w,screen.h))
        return r
    end
    local function text(widget,minPhysical)
        check(widget:IsVisible(),"核心文字必须可见 "..name(widget))
        local p,r=widget.props,rect(widget)
        check(type(p.text)=="string" and p.text~="","核心文字不可为空 "..name(widget))
        local scale=UI.GetScale()
        check((p.fontSize or 0)*scale>=minPhysical,"核心字号低于"..minPhysical.."物理px "..name(widget))
        check((p.minFontSize or p.fontSize or 0)*scale>=minPhysical,
            "自动缩字下限低于物理字号要求 "..name(widget))
        local size=UI.Theme.FontSize(p.fontSize)
        local contentW=r.w-(p.paddingLeft or 0)-(p.paddingRight or 0)
        local contentH=r.h-(p.paddingTop or 0)-(p.paddingBottom or 0)
        local multiline=p.whiteSpace=="normal"
        local measured=UI.MeasureTextFit(p.text,{fontSize=size,minFontSize=size,
            fontFace=UI.Theme.FontFace(p.fontFamily,p.fontWeight),width=math.max(1,contentW-2),
            multiline=multiline,lineHeight=p.lineHeight or 1.35,letterSpacing=p.letterSpacing or 0})
        check(measured.width>0 and measured.height>0,"真实字体未就绪 "..name(widget))
        if not multiline then check(measured.width<=contentW+1,string.format("单行文字截断/越宽 %s measured=%.3f content=%.3f bounds=%.3f padding=(%s,%s) font=%.3f",
            name(widget),measured.width,contentW,r.w,tostring(p.paddingLeft),tostring(p.paddingRight),size)) end
        check(measured.height<=contentH+1,string.format("真实字体高度被裁切 %s measured=%.3f content=%.3f bounds=%.3f padding=(%s,%s) font=%.3f",
            name(widget),measured.height,contentH,r.h,tostring(p.paddingTop),tostring(p.paddingBottom),size))
        local rendered=Kit.RenderedTextMetrics(widget)
        if rendered then check(rendered.textHeight<=contentH+1,"真实Render正文裁切 "..name(widget)) end
        local ancestor=widget.parent
        while ancestor and ancestor~=fixture.root do
            check(contains(r,ancestor:GetAbsoluteLayout()),"文字超出祖先 "..name(widget).." / "..name(ancestor))
            ancestor=ancestor.parent
        end
        texts=texts+1
    end
    local function settle()
        for _=1,5 do Kit.LayoutTree(fixture.game);fixture:LayoutControls() end
        Kit.LayoutTree(fixture.game)
        -- 真实字体绘制两次，捕获首帧绘制后的高度变化。
        -- 不调用UI.Update，避免推进无关会话或全局特效。
        for _=1,2 do
            for _,widget in ipairs({fixture.dashboard.clock,fixture.dashboard.foodValue,fixture.dashboard.energyValue,
                fixture.dashboard.batteryValue,fixture.dashboard.speed,fixture.objective,fixture.deliveryStatus,
                fixture.pauseButton,fixture.menuButton,fixture.mountButton,fixture.interactButton}) do
                if widget:IsVisible() then widget:Render(UI.GetNVGContext()) end
            end
            Kit.LayoutTree(fixture.game);fixture:LayoutControls();UI.Layout()
        end
    end
    local function tap(widget,id,held,fx,fy)
        local r=rect(widget)
        check(r.w>=44 and r.h>=44,"触摸目标不足44 "..name(widget))
        local hit=widget:GetAbsoluteLayoutForHitTest()
        check(math.abs(hit.x-r.x)<.01 and math.abs(hit.y-r.y)<.01
            and math.abs(hit.w-r.w)<.01 and math.abs(hit.h-r.h)<.01,"绘制和触摸边界不一致 "..name(widget))
        local x,y=hit.x+hit.w*(fx or .5),hit.y+hit.h*(fy or .5)
        local down=send(PointerEvent.Types.PointerDown,id,x,y)
        check(down.target==widget,"真实按下被遮挡 "..name(widget).." / 命中 "..(down.target and name(down.target) or "nil"))
        if held then held() end
        local up=send(PointerEvent.Types.PointerUp,id,x,y)
        check(up.target==widget,"真实抬手未交还原捕获者 "..name(widget))
        touches=touches+1
    end
    local function auditGroups(mounted)
        local d=fixture.dashboard
        local groups={d.clock,d.root,fixture.navPanel,fixture.pauseButton,fixture.menuButton,fixture.actionTray}
        if mounted then
            groups[#groups+1]=d.speed
            for _,key in ipairs({"gas","brake","steering"}) do groups[#groups+1]=fixture.controls.widgets[key] end
        else groups[#groups+1]=fixture.walkStick.root end
        for i,first in ipairs(groups) do
            if first:IsVisible() then
                local a=rect(first)
                for j=i+1,#groups do
                    local second=groups[j]
                    if second:IsVisible() then
                        local b=rect(second)
                        check(disjoint(a,b),string.format("可见HUD组重叠 %s (%.1f,%.1f %.1fx%.1f) / %s (%.1f,%.1f %.1fx%.1f)",
                            name(first),a.x,a.y,a.w,a.h,name(second),b.x,b.y,b.w,b.h))
                    end
                end
            end
        end
        check(d.root.props.borderWidth==0 and d.root.props.backgroundColor[4]==0
            and not d.root.props.backgroundGradient,"生活HUD不得恢复底板")
        check(fixture.actionTray.props.backgroundColor[4]==0 and not fixture.actionTray.props.backgroundGradient,
            "动作不得加卡片底座")
    end
    local ok,failure=pcall(function()
        fixture:ShowGame()
        local p=copy(state)
        p.currentSpace="city";p.online=false;p.contactName=nil;p.trafficHint=nil
        p.hunger,p.energy,p.battery=65,80,77
        p.nextGoal={title="完成第一单，攒下下一餐生活费"}
        local actor={x=0,z=-20,yaw=0,speed=0,mounted=false,vehicleId="borrowed_ebike"}
        for _,mounted in ipairs({false,true}) do
            actor.mounted=mounted
            -- 同时验收无导航目标和真实活动目标/订单；
            -- 隐藏导航或订单状态不能让测试通过。
            fixture:Update(p,actor,nil,nil,nil,0);settle()
            check(fixture.objective.props.text=="下一步 · "..p.nextGoal.title,
                "无导航时必须显示真实nextGoal，而不是空提示或仅放进手机")
            check(not fixture.deliveryStatus:IsVisible(),"无订单不得显示配送说明")
            text(fixture.objective,18)
            auditGroups(mounted)
            local point=assert(Config.points.breakfast)
            local target={id="breakfast",name=point.name or "早餐店",distance=8,x=point.x,z=point.z,hint="停稳取餐",route={}}
            local active={id="hud-layout-only",status="accepted",remainingHours=.18,route={}}
            fixture:Update(p,actor,target,active,nil,0);settle()
            check(fixture.objective.props.text:find(target.name,1,true)~=nil
                and fixture.objective.props.text:find("8米",1,true)~=nil,"导航目标必须显示名称和真实距离")
            check(fixture.deliveryStatus:IsVisible() and fixture.deliveryStatus.props.text:find("取餐",1,true)~=nil,
                "活动订单必须显示当前阶段")
            check(fixture.mapOpen:IsVisible() and fixture.map.root:IsVisible(),"小地图入口必须常驻")
            local d=fixture.dashboard
            check(d.clock.props.text==Life.Clock(p.time) and d.foodBar:GetValue()==p.hunger
                and d.energyBar:GetValue()==p.energy and d.batteryBar:GetValue()==p.battery,"核心HUD必须显示真实状态值")
            for _,widget in ipairs({d.foodValue,d.energyValue,d.batteryValue,fixture.objective,fixture.deliveryStatus,
                fixture.menuButton,fixture.mountButton,fixture.interactButton}) do text(widget,18) end
            text(d.clock,28)
            if mounted then text(d.speed,18) end
            auditGroups(mounted)
            for _,widget in ipairs({fixture.pauseButton,fixture.menuButton,fixture.mountButton,fixture.interactButton}) do
                check(widget:IsVisible(),"真实动作入口必须可见 "..name(widget))
                tap(widget,792501)
            end
            tap(fixture.mapOpen,792501)
            check(fixture.worldMap:IsVisible() and fixture:IsBlocking(),"小地图真实触摸须打开全图并阻断输入")
            fixture:CloseWorldMap();settle()
            if mounted then
                for _,key in ipairs({"gas","brake","steering"}) do
                    local widget=fixture.controls.widgets[key]
                    tap(widget,792501,function()
                        check(key=="steering" and fixture.controls.pointers.steer==792501
                            or key~="steering" and fixture.controls[key],"踏板必须持有真实指针 "..key)
                    end)
                    check(key=="steering" and fixture.controls.pointers.steer==-1
                        or key~="steering" and not fixture.controls[key],"踏板松手必须清空 "..key)
                end
                tap(fixture.controls.widgets.gas,792501,function()
                    tap(fixture.controls.widgets.brake,792502,function()
                        check(fixture.controls.gas and fixture.controls.brake,"油门刹车双指必须可独立持有")
                    end)
                    check(fixture.controls.gas and not fixture.controls.brake,"松刹车不能清另一指油门")
                end)
                check(not fixture.controls.gas and not fixture.controls.brake,"双指松手不得卡住")
            else
                tap(fixture.walkStick.root,792501,function()
                    check(fixture.walkStick.pointer==792501 and math.abs(fixture.walkStick.x)>0,
                        "步行摇杆外圈必须真实命中并移动")
                end,.72,.5)
                check(fixture.walkStick.pointer==-1 and fixture.walkStick.x==0 and fixture.walkStick.y==0,
                    "步行松手必须归零")
            end
            -- 三位满值与燃油文案比初始电量更宽；相同控件真Render验收，不能靠77%样本蒙混。
            for _,vehicle in ipairs({"borrowed_ebike","motorcycle"}) do
                local extreme=copy(p)
                extreme.hunger,extreme.energy,extreme.battery,extreme.motorcycleFuel=100,100,100,100
                actor.vehicleId=vehicle
                fixture:Update(extreme,actor,target,active,nil,0);settle()
                for _,widget in ipairs({d.foodValue,d.energyValue,d.batteryValue}) do text(widget,18) end
                auditGroups(mounted)
            end
            actor.vehicleId="borrowed_ebike"
        end
        check(calls.phone==2 and calls.pause==2 and calls.mount==2 and calls.interact==2,
            "两模式每个真实按钮必须各分发一次既有动作")
        print(string.format("[HudLayoutChecks] PASS %s / %d断言 / %d真实字体 / %d触摸",context,assertions,texts,touches))
    end)
    -- 即使首个真实边界、字体或命中断言失败，也必须执行最终恢复。
    -- 不修改调用方View的Store函数、根节点或回调。
    local errors={}
    local function restore(fn)
        local restored,reason=pcall(fn)
        if not restored then errors[#errors+1]=tostring(reason) end
    end
    for id,position in pairs(pointers) do
        restore(function() send(PointerEvent.Types.PointerCancel,id,position.x,position.y) end)
    end
    restore(function() fixture:ResetInput();fixture.controls:SetEnabled(false) end)
    UI.Layout=oldLayout
    restore(function() UI.SetRoot(oldRoot) end)
    restore(function() fixture:Dispose();holder:Destroy() end)
    restore(function() UI.Layout();UI.SetFocus(oldFocus) end)
    demand(UI.GetRoot()==oldRoot and UI.Layout==oldLayout,"finally必须恢复原Root与Layout函数")
    demand(UI.GetFocus()==oldFocus,"finally必须恢复原焦点")
    demand(#errors==0,"finally恢复失败 "..table.concat(errors,"；"))
    demand(ok,tostring(failure))
    return {passed=true,assertions=assertions,texts=texts,touches=touches,width=width,height=height}
end
---@param session CareerSession
function Checks.Run(session)
    demand(session.options.test and session.restoreTestStorage,"需要显式test内存隔离会话")
    local state=session:State()
    local result={passed=true,resolutions=0,assertions=0,texts=0,touches=0}
    for _,size in ipairs({{1000,400},{640,360},{800,600},{390,844}}) do
        local item=Checks.Size(state,size[1],size[2])
        result.resolutions=result.resolutions+1
        result.assertions=result.assertions+item.assertions
        result.texts=result.texts+item.texts;result.touches=result.touches+item.touches
    end
    return result
end
return Checks
