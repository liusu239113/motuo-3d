-- 手动调用 Run(Session.New({test=true}) 的已就绪会话)；不会自动挂到入口。
-- 真触摸走 UI 命中测试，内存存储/禁云，finally 恢复；不建城、不跑帧、不传送。
local UI=require("urhox-libs/UI")
local PointerEvent=require("urhox-libs/UI/Core/PointerEvent")
local Store=require("Career.Store")
local Config=require("Career.Config")
local World=require("Career.WorldData")
local Delivery=require("Career.Delivery")
local Checks={}

---@param widget Widget
---@return Widget[]
local function tree(widget)
    local result={widget}
    for _,child in ipairs(widget:GetChildren()) do
        for _,item in ipairs(tree(child)) do result[#result+1]=item end
    end
    return result
end
---@param widgets Widget[]
local function freed(widgets)
    for _,widget in ipairs(widgets) do
        assert(widget.node==nil and widget.parent==nil and widget:GetNumChildren()==0,
            "旧树未Destroy（Yoga/父引用/子节点）："..tostring(widget.props.id))
    end
end
---@param widget Widget
---@return string
local function widgetId(widget)
    local id=widget.props.id
    if type(id)~="string" then error("地图控件缺少稳定id") end
    return id
end
---@param view CareerView
---@param id string
---@return Widget
local function find(view,id)
    local widget=assert(view.phoneBody:FindById(id),"缺少手机控件："..id)
    return widget
end
---@param view CareerView
local function layout(view)
    UI.Layout()
    view.phoneArea:Update(0)
    UI.Layout()
    view.phoneContent:Update(0) -- 同步内容尺寸，无惯性推进或游戏 Update。
    local map=view.phoneContent:FindById("career-phone-map")
    if map then map:Update(0) end
    UI.Layout()
end
---@param view CareerView
---@param id string
local function tap(view,id)
    layout(view)
    local widget=find(view,id)
    assert(widget:IsVisible() and not widget.props.disabled,"控件不可点："..id)
    local r=widget:GetAbsoluteLayoutForHitTest()
    local desktop=view.phonePage=="apps"
    local area=(desktop and view.phoneDesktop or view.phoneContent):GetAbsoluteLayoutForHitTest()
    assert(area.h>0 and r.h>=44 and r.w>=44,"触摸必须使用至少44px真实布局："..id)
    -- 主页禁止通过滚动寻找应用；仅内页允许把目标滚进视口。
    if not desktop then
        local _,scroll=view.phoneContent:GetScroll()
        view.phoneContent:SetScroll(0,math.max(0,scroll+r.y+r.h/2-area.y-area.h/2))
        r=widget:GetAbsoluteLayoutForHitTest()
    end
    assert(r.y+r.h/2>area.y and r.y+r.h/2<area.y+area.h,"目标仍被滚动视口裁剪："..id)
    local scale=UI.GetScale()
    local function event(kind)
        return PointerEvent.new(kind,{pointerId=791201,pointerType="touch",isPrimary=false,
            x=(r.x+r.w/2)*scale,y=(r.y+r.h/2)*scale,button=PointerEvent.Button.Left})
    end
    local down=event("PointerDown")
    UI.HandlePointerEvent(down)
    local up=event("PointerUp")
    UI.HandlePointerEvent(up)
    assert(down.target==widget and up.target==widget,"实际触摸命中错误："..id)
end
---@param view CareerView
---@param district string
local function choose(view,district)
    local old=tree(find(view,"career-map-points"))
    table.remove(old,1) -- 地点容器保留，只销毁内容。
    local page=view.phoneContent:GetChildAt(1)
    local map=find(view,"career-phone-map")
    local picker=find(view,"career-map-regions")
    if not picker:IsVisible() then tap(view,"career-map-region-toggle") end
    tap(view,"career-map-region-"..district)
    assert(view.mapDistrictId==district and not picker:IsVisible(),"切区没有选中并收起")
    assert(view.phoneContent:GetChildAt(1)==page and find(view,"career-phone-map")==map,
        "切区不应重建整页/全城概览")
    freed(old)
    layout(view)
end
---@param view CareerView
---@return Widget[]
local function rows(view)
    local result={}
    for _,widget in ipairs(tree(find(view,"career-map-points"))) do
        if widget.props.id and widget.props.id:match("^career%-map%-poi%-") then result[#result+1]=widget end
    end
    assert(#result>=1 and #result<=6,"地点按钮必须有界且非空")
    return result
end
local function distanceText(distance)
    return distance>=1000 and string.format("%.1f公里",distance/1000) or string.format("%.0f米",distance)
end
---@param view CareerView
local function verifyRows(view,district,x,z)
    local current=World.District(x,z)
    local result=rows(view)
    local previous=-1
    for _,row in ipairs(result) do
        local id=widgetId(row):sub(#"career-map-poi-"+1)
        local point=assert(Config.points[id],"不得制造地图POI："..id)
        local owner=World.District(point.x,point.z)
        assert(district=="greenbelt" or owner.id==district,"地点串区："..id)
        local distance=Config.DistanceTo(id,x,z)
        assert(distance>=previous,"地点应按当前位置距离排序")
        previous=distance
        local detail=find(view,"career-map-distance-"..id).props.text
        assert(detail:find("直线 "..distanceText(distance),1,true),"距离未按城市坐标计算："..id)
        if owner.id~=current.id then
            assert(detail:find("跨区",1,true) and detail:find(owner.label,1,true),"跨区必须明确标记所属区")
        end
    end
    return result
end
---@param session CareerSession
---@return boolean
function Checks.Run(session)
    assert(session.options and session.options.test==true and type(session.restoreTestStorage)=="function",
        "MapPhoneChecks 只允许明确 test=true 的隔离 Session")
    local actor=assert(session.actor,"人物未就绪")
    local view=session.view
    assert(session.running and UI.GetRoot()==view.root and not view.blocked and view.phonePage=="",
        "请在已挂载、非弹窗、非手机的测试游戏态调用")
    local old={x=actor.x,z=actor.z,yaw=actor.yaw,speed=actor.speed,space=session.space,
        cityX=session.cityX,cityZ=session.cityZ,cityYaw=session.cityYaw,waypoint=session.waypoint,
        navigation=session.navigation,manualWaypoint=session.manualWaypoint,online=session.online,lastActor=view.lastActor,lastTarget=view.lastTarget,
        notice=view.notice.props.text,noticeTime=view.noticeTime,mapDistrictId=view.mapDistrictId,
        mapPointPage=view.mapPointPage,mapPickerOpen=view.mapPickerOpen}
    local files={}
    local cloudCalls,writes=0,0
    local restore=Store.UseTestStorage({read=function(path) return files[path],nil,files[path]==nil end,
        write=function(path,text) writes=writes+1; files[path]=text; return true end,
        cloud={Get=function() cloudCalls=cloudCalls+1; error("MapPhoneChecks 禁止云读取") end,
            Set=function() cloudCalls=cloudCalls+1; error("MapPhoneChecks 禁止云写入") end}})
    local ok,failure=pcall(function()
        assert(Store.NewCareer())
        local initialWrites=writes
        actor.x,actor.z,actor.speed=768,-18,0 -- 只改隔离人物逻辑坐标，不调用Teleport/Ensure。
        session.space="city"; session.online=false; session.waypoint=""; session.navigation={key="",route={}}
        session:Refresh()
        local revision=Store.Get().revision
        session:OpenPhone("apps")
        tap(view,"career-app-map")
        assert(view.mapDistrictId=="east_market","初开应由实时actor而非老存档定位")
        assert(find(view,"career-map-current").props.text:find("东门市集",1,true))
        assert(find(view,"career-map-region-east_market").props.text:find("当前区",1,true))
        assert(#verifyRows(view,"east_market",actor.x,actor.z)==4)
        local mapPage=tree(assert(view.phoneContent:GetChildAt(1)))
        choose(view,"west_garden")
        assert(#verifyRows(view,"west_garden",actor.x,actor.z)==4)
        session:RefreshPhone()
        freed(mapPage)
        assert(view.mapDistrictId=="west_garden","同页刷新应保留用户选择")
        local refreshed=tree(assert(view.phoneContent:GetChildAt(1)))
        session:OpenPhone("wallet"); freed(refreshed)
        session:OpenPhone("map")
        assert(view.mapDistrictId=="west_garden","切应用后返回应保留选择")

        choose(view,"old_town")
        local seen={}
        while true do
            for _,row in ipairs(verifyRows(view,"old_town",actor.x,actor.z)) do
                seen[widgetId(row):sub(#"career-map-poi-"+1)]=true
            end
            local nextPage=view.phoneContent:FindById("career-map-next")
            if not nextPage or nextPage.props.disabled then break end
            local stale=tree(find(view,"career-map-points")); table.remove(stale,1)
            tap(view,"career-map-next"); freed(stale)
        end
        local oldCount=0
        for _,point in ipairs(Config.pointList) do
            if World.District(point.x,point.z).id=="old_town" then
                assert(seen[point.id],"老街/住房入口不可丢失："..point.id); oldCount=oldCount+1
            end
        end
        assert(oldCount>=9 and seen.breakfast and seen.dealer and seen.bridge)
        choose(view,"east_tech")
        local selected=assert(verifyRows(view,"east_tech",actor.x,actor.z)[1])
        local selectedId=widgetId(selected)
        local destination=selectedId:sub(#"career-map-poi-"+1)
        local beforeX,beforeZ=actor.x,actor.z
        local navigationPage=tree(assert(view.phoneContent:GetChildAt(1)))
        tap(view,selectedId)
        assert(session.waypoint==destination and view.phonePage=="" and not view.phone:IsVisible(),
            "地点应经生产actions.setWaypoint并closePhone")
        assert(actor.x==beforeX and actor.z==beforeZ and Store.Get().revision==revision,
            "设置导航不能传送或保存新字段")
        freed(navigationPage)
        local target=assert(session:Target())
        assert(target.pointId==destination and #target.route>=2,"城市导航未接到真实目的地/道路路线")

        -- 绿带无虚构门店；必须是距当前位置最近4个真实Config点。
        actor.x,actor.z=14000,1000; session:Refresh(); session:OpenPhone("map")
        assert(view.mapDistrictId=="greenbelt","重开手机应按新当前位置重定位")
        local nearest=verifyRows(view,"greenbelt",actor.x,actor.z)
        assert(#nearest==4 and find(view,"career-map-distance-note").props.text:find("无固定服务点",1,true))
        local sorted={}
        for _,point in ipairs(Config.pointList) do sorted[#sorted+1]=point end
        table.sort(sorted,function(a,b)
            local left,right=Config.DistanceTo(a.id,actor.x,actor.z),Config.DistanceTo(b.id,actor.x,actor.z)
            return left==right and a.id<b.id or left<right
        end)
        for i,row in ipairs(nearest) do assert(row.props.id=="career-map-poi-"..sorted[i].id,"绿带不是最近真实点") end

        -- 房间局部坐标在老街范围，但城市入口在北湖，选择/距离/全城标记必须统一。
        view:ClosePhone()
        session.space="hostel"; actor.x,actor.z=0,0
        assert(Store.Transaction(function(p)
            p.accommodation="hostel"
            p.position.space="hostel"; p.position.x=0; p.position.z=0
            p.position.cityX=0; p.position.cityZ=6144; p.position.cityYaw=37
            return true
        end))
        session:Refresh(); session:OpenPhone("map"); layout(view)
        assert(view.mapDistrictId=="north_lake" and find(view,"career-map-indoor"))
        assert(#verifyRows(view,"north_lake",0,6144)==4)
        local map=find(view,"career-phone-map")
        local viewport=assert(map:GetChildAt(1)):GetLayout()
        local player=find(view,"career-phone-map-player")
        local scale=math.min(viewport.w,viewport.h)/30000
        assert(player.props.visible~=false and math.abs(player.props.left-viewport.w/2)<.001
            and math.abs(player.props.top-(viewport.h/2-6144*scale))<.001,"室内地图标记不是城市入口")
        local indoor=assert(rows(view)[1])
        local indoorWidgetId=widgetId(indoor)
        local indoorId=indoorWidgetId:sub(#"career-map-poi-"+1)
        tap(view,indoorWidgetId)
        assert(session.waypoint==indoorId and view.phonePage=="" and actor.x==0 and actor.z==0 and session.space=="hostel",
            "室内点选只能记导航并收起，不得出屋或移动人物")

        session.space="city"; actor.x,actor.z=768,-18; session:Refresh()
        local baseCount=#tree(view.root)
        local maximum=0
        -- 全14区反复切区+切页；真实命中、旧Yoga释放、单页与整个HUD数量同时有界。
        local districts={World.District(0,0)}
        for _,d in ipairs(World.Districts) do districts[#districts+1]=d end
        districts[#districts+1]=World.District(14000,1000)
        for round=1,2 do
            session:OpenPhone("map")
            for _,d in ipairs(districts) do
                choose(view,d.id)
                verifyRows(view,d.id,actor.x,actor.z)
                local count=#tree(assert(view.phoneContent:GetChildAt(1)))
                maximum=math.max(maximum,count)
                assert(count<=180 and #tree(view.root)<=baseCount+180,"地图活控件数无界增长")
            end
            local stale=tree(assert(view.phoneContent:GetChildAt(1)))
            session:OpenPhone("apps"); freed(stale)
            tap(view,"career-app-map")
            assert(view.mapDistrictId=="greenbelt","反复切页丢失所选区域")
            local closing=tree(assert(view.phoneContent:GetChildAt(1)))
            view:ClosePhone(); freed(closing)
            assert(view.phoneContent:GetNumChildren()==0 and #tree(view.root)==baseCount,"收起未释放手机子树")
        end
        assert(writes==initialWrites+1 and cloudCalls==0,"导航/切区不应读写存档或云；仅允许室内fixture事务写内存")
        -- 带单真实点选补给，不能只改waypoint却仍强制把HUD指向订单。
        assert(Delivery.Accept())
        local active=assert(Delivery.GetActive())
        session.manualWaypoint=false
        assert(session:Target().pointId==active.pickupId,"默认仍应导航当前取餐点")
        local beforeNavigation=Store.Get()
        session:OpenPhone("map")
        choose(view,"east_market")
        tap(view,"career-map-poi-world_east_market_charge")
        local supply=assert(session:Target())
        assert(supply.pointId=="world_east_market_charge" and session.manualWaypoint and #supply.route>=2,
            "带单点选充电站必须切换实际导航而非静默被订单覆盖")
        local supplyHint=assert(supply.hint,"补给导航缺少提示")
        assert(supplyHint:find("配送继续计时",1,true),"补给导航应提示配送仍计时")
        session:OpenPhone("delivery")
        tap(view,"career-order-navigation")
        assert(view.phonePage=="" and not session.manualWaypoint and session:Target().pointId==active.pickupId,
            "外卖页应可真实触摸切回订单导航")
        local afterNavigation=Store.Get()
        assert(afterNavigation.revision==beforeNavigation.revision and afterNavigation.cashCents==beforeNavigation.cashCents
            and afterNavigation.activeOrders[1].remainingHours==beforeNavigation.activeOrders[1].remainingHours,
            "手机导航不得结算、停表重置或额外保存订单")
        assert(writes==initialWrites+2 and cloudCalls==0,"仅允许额外一次接单内存事务，导航仍零存档写入")
        print(string.format("[地图手机验收通过] 真触摸14区/地点/导航；老街%d点分页完整；绿带最近4真实点；带单补给导航与订单导航切回；室内城市入口；旧树Destroy；地图活控件峰值%d（非真机性能结论）；内存禁云",oldCount,maximum))
    end)
    -- finally 不调用RestorePosition/ApplySpace，不触真实档、不反复加载世界。
    local cleaned,cleanupFailure=pcall(function()
        view:ClosePhone()
        actor.x,actor.z,actor.yaw,actor.speed=old.x,old.z,old.yaw,old.speed
        session.space=old.space
        session.cityX,session.cityZ,session.cityYaw=old.cityX,old.cityZ,old.cityYaw
        session.waypoint,session.navigation,session.online=old.waypoint,old.navigation,old.online
        session.manualWaypoint=old.manualWaypoint
    end)
    restore()
    local refreshed,refreshFailure=pcall(function()
        session:Refresh()
        view.lastActor,view.lastTarget=old.lastActor,old.lastTarget
        view.notice:SetText(old.notice or ""); view.noticeTime=old.noticeTime
        view.mapDistrictId,view.mapPointPage,view.mapPickerOpen=old.mapDistrictId,old.mapPointPage,old.mapPickerOpen
    end)
    if not ok then error(failure,0) end
    if not cleaned then error(cleanupFailure,0) end
    if not refreshed then error(refreshFailure,0) end
    return true
end
-- 可单独验收手机：UI初始化后调用RunLayout(view,state,offer,active)。不建城、不读写档、不执行业务动作。
-- 用真实Yoga/控件/命中测试，显式尺寸根模拟横屏与安全区；不更改UI.Scale.DEFAULT或graphics模式。
---@param view CareerView
function Checks.RunLayout(view,state,offer,active)
    assert(view.phonePage=="" and not view.blocked and UI.GetRoot()==view.root,"请在非手机/非弹窗的已挂载游戏态验收")
    local Phone=require("Career.Phone")
    local root=UI.GetRoot()
    local phoneAction,closeAction=view.actions.phone,view.actions.closePhone
    local oldWidth,oldHeight=view.phoneWidth,view.phoneHeight
    local oldStyle={width=view.phoneBody.props.width,height=view.phoneBody.props.height}
    local holder=UI.Panel{width=640,height=360,padding=0}
    view.phoneArea:Remove(); holder:AddChild(view.phoneArea)
    UI.SetRoot(holder)
    view.actions.phone=function(page) view:OpenPhone(page,state,offer,active) end
    view.actions.closePhone=function() view:ClosePhone() end
    local function inside(child,parent)
        return child.x>=parent.x-1 and child.y>=parent.y-1
            and child.x+child.w<=parent.x+parent.w+1 and child.y+child.h<=parent.y+parent.h+1
    end
    local function settle(width,height)
        holder:SetStyle{width=width,height=height}
        UI.Layout()
        view.phoneArea:Update(0)
        UI.Layout()
        view.phoneContent:Update(0)
        UI.Layout()
    end
    local function touch(widget)
        local r=widget:GetAbsoluteLayoutForHitTest()
        assert(r.w>=44 and r.h>=44,"手机触摸目标不得小于44逻辑像素："..tostring(widget.props.id))
        local scale=UI.GetScale()
        local down=PointerEvent.new("PointerDown",{pointerId=791202,pointerType="touch",isPrimary=true,
            x=(r.x+r.w/2)*scale,y=(r.y+r.h/2)*scale,button=PointerEvent.Button.Left})
        UI.HandlePointerEvent(down)
        assert(down.target==widget,"无滚动首页/固定工具栏真实命中错误："..tostring(widget.props.id))
        UI.HandlePointerEvent(PointerEvent.new("PointerUp",{pointerId=791202,pointerType="touch",isPrimary=true,
            x=(r.x+r.w/2)*scale,y=(r.y+r.h/2)*scale,button=PointerEvent.Button.Left}))
    end
    local ok,failure=pcall(function()
        -- 后两组额外模拟刘海/胶囊挤占空间；640x360还直接按基准像素验收，比默认密度缩放更紧。
        for _,size in ipairs({{640,360,0,0},{960,540,0,0},{640,360,24,36},{960,540,32,48}}) do
            local width,height=size[1],size[2]
            holder:SetStyle{paddingLeft=size[3],paddingRight=size[3],paddingTop=size[4],paddingBottom=8}
            view:OpenPhone("apps",state,offer,active)
            settle(width,height)
            local body=view.phoneBody:GetAbsoluteLayout()
            local area=view.phoneArea:GetAbsoluteLayout()
            assert(inside(body,area),"手机外壳超出实际安全可用区域")
            local screen=assert(holder:FindById("career-phone-screen")):GetAbsoluteLayout()
            local aperture={x=body.x+body.w*50/576,y=body.y+body.h*76/1024,
                w=body.w*476/576,h=body.h*880/1024}
            assert(inside(screen,aperture),"内容安全区不匹配硬件框图透明开孔")
            assert(view.phoneDesktop:IsVisible() and not view.phoneContent:IsVisible(),"主页不得使用纵向ScrollView")
            local old=tree(assert(view.phoneDesktop:GetChildAt(1)))
            local grid=assert(holder:FindById("career-app-grid"))
            assert(grid:GetNumChildren()==2,"固定六应用必须是两行三列")
            for _,app in ipairs(Phone.Apps) do
                local icon=assert(holder:FindById("career-app-"..app[1]))
                local r=icon:GetAbsoluteLayoutForHitTest()
                assert(inside(r,screen) and inside(r,view.phoneDesktop:GetAbsoluteLayout()),"底部软件被裁剪："..app[1])
                assert(r.w>=44 and r.h>=44,"应用触摸目标过小")
                local ancestor=icon.parent
                while ancestor and ancestor~=view.phoneBody do
                    assert(ancestor._className~="ScrollView","首页应用不得有ScrollView祖先")
                    ancestor=ancestor.parent
                end
                for _,item in ipairs(tree(icon)) do
                    if item._className=="Label" then
                        assert(item.props.fontSize>=11 and item:GetAbsoluteLayout().h>=18,"不能靠缩小应用文字解决布局")
                    end
                end
            end
            for _,app in ipairs(Phone.Apps) do
                touch(assert(holder:FindById("career-app-"..app[1])))
                assert(view.phonePage==app[1] and view.phoneContent:IsVisible() and not view.phoneDesktop:IsVisible())
                freed(old)
                settle(width,height)
                assert(view.phoneContent:GetAbsoluteLayout().h>44,"内页滚动视口坍缩")
                if app[1]=="progression" then
                    local _,contentHeight=view.phoneContent:GetContentSize()
                    assert(contentHeight>view.phoneContent:GetAbsoluteLayout().h,"装备/生涯长页仍须可纵向滚动")
                    view.phoneContent:ScrollToBottom()
                    local _,scroll=view.phoneContent:GetScroll()
                    assert(scroll>0,"长内页滚动失效")
                end
                local oldPage=tree(assert(view.phoneContent:GetChildAt(1)))
                local back=assert(holder:FindById("career-phone-back"))
                assert(inside(back:GetAbsoluteLayout(),screen),"固定返回超出屏幕")
                touch(back); freed(oldPage)
                assert(view.phonePage=="apps","内页返回必须回到应用首页")
                settle(width,height)
                old=tree(assert(view.phoneDesktop:GetChildAt(1)))
            end
            touch(assert(holder:FindById("career-phone-close"))); freed(old)
            assert(view.phonePage=="" and view.phoneDesktop:GetNumChildren()==0 and view.phoneContent:GetNumChildren()==0,
                "收起必须Destroy所有页面子树")
            print(string.format("[手机布局验收通过] %dx%d 安全边距%d/%d；六应用无滚动/44px真实命中/框孔包含/固定返回/Destroy",width,height,size[3],size[4]))
        end
    end)
    view:ClosePhone()
    view.actions.phone,view.actions.closePhone=phoneAction,closeAction
    view.phoneArea:Remove(); holder:Destroy(); view.phone:AddChild(view.phoneArea)
    view.phoneBody:SetStyle(oldStyle)
    view.phoneWidth,view.phoneHeight=oldWidth,oldHeight
    UI.SetRoot(root); UI.Layout()
    if not ok then error(failure,0) end
    return true
end
return Checks
