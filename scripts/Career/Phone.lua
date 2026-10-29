-- 手机硬件、桌面与应用入口；真实功能仍由View/Session处理，不把整图当交互。
local UI=require("urhox-libs/UI")
local Theme=require("RacingTheme")
local Kit=require("Career.PhoneKit")
local Phone={}
Phone.Frame="image/career_phone_hardware_frame_20261028190339.png"
Phone.Wallpaper="image/career_phone_wallpaper_20261028185104.png"
Phone.Apps={{"delivery","外卖骑手"},{"map","南城地图"},{"wallet","钱包"},
    {"messages","消息"},{"life","生活"},{"progression","车手生涯"}}
Phone.Resources={Phone.Frame,Phone.Wallpaper}
for _,app in ipairs(Phone.Apps) do Phone.Resources[#Phone.Resources+1]="image/career_phone/"..app[1]..".png" end

-- width/height 是外层 SafeAreaView 扣除刘海、胶囊和边距后的可用基准像素。
-- 短横屏保留足够宽度，而不是继续压缩字号/触摸目标；高度只取可用空间。
function Phone.Metrics(width,height)
    local h=math.min(620,height)
    return {width=math.min(width,324,math.max(260,h*.58)),height=h}
end
---@param view CareerView
function Phone.Layout(view,width,height)
    if width<=0 or height<=0 then return end
    local metrics=Phone.Metrics(width,height)
    if view.phoneWidth==metrics.width and view.phoneHeight==metrics.height then return end
    view.phoneWidth,view.phoneHeight=metrics.width,metrics.height
    view.phoneBody:SetStyle{width=metrics.width,height=metrics.height}
    local summary=view.phoneDesktop:FindById("career-phone-summary")
    if summary then summary:SetVisible(metrics.height>=330) end
end
---@param view CareerView
function Phone.Create(view,actions)
    local shell=UI.Panel{id="career-phone-body",width=300,maxWidth="100%",height="100%",maxHeight=620,padding=0,
        flexShrink=1,backgroundColor={7,10,13,255},borderRadius=26,overflow="hidden"}
    -- 已核对576x1024框图透明开孔：约x50..524、y76..954（四角内收）；内容再留安全余量。
    -- 与框图一样采用百分比缩放，不能把外壳高度当作屏幕可用高度。
    local screen=UI.Panel{id="career-phone-screen",position="absolute",left="9.2%",right="9.2%",top="8%",bottom="7.6%",
        padding=6,gap=6,backgroundImage=Phone.Wallpaper,backgroundFit="cover",overflow="hidden",borderRadius=10}
    view.phoneClock=Kit.Text("08:00",11,Theme.Colors.white,{width="48%"})
    screen:AddChild(UI.Row{id="career-phone-status",width="100%",padding=0,justifyContent="space-between",children={
        view.phoneClock,Kit.Text("4G · 86%",11,Theme.Colors.white,{width="48%",textAlign="right"})}})
    view.phoneTitle=Kit.Text("手机桌面",13,Theme.Colors.white,
        {fontWeight="bold",flexGrow=1,flexShrink=1,flexBasis=0,minWidth=0})
    local touchSize=Kit.TouchSize()
    view.phoneBack=Theme.Button("首页",function() require("Career.PhoneApps").Back(view) end,false,52,
        {id="career-phone-back",height=touchSize,minHeight=touchSize,minWidth=touchSize,padding=0,fontSize=12,visible=false})
    screen:AddChild(UI.Row{id="career-phone-toolbar",width="100%",height=touchSize,minHeight=touchSize,padding=0,gap=4,alignItems="center",children={
        view.phoneBack,view.phoneTitle,
        Theme.Button("收起",function() actions.closePhone() end,false,52,{id="career-phone-close",height=touchSize,minHeight=touchSize,minWidth=touchSize,padding=0,fontSize=12})}})
    -- 首页不在任何 ScrollView 内。长订单/装备等内页共用一个有界滚动容器。
    view.phoneDesktop=UI.Panel{id="career-phone-desktop",width="100%",flexGrow=1,flexBasis=0,minHeight=0,padding=0,overflow="hidden"}
    view.phoneContent=UI.ScrollView{id="career-phone-content",width="100%",flexGrow=1,flexBasis=0,minHeight=0,
        padding=0,scrollX=false,scrollY=true,visible=false}
    screen:AddChild(view.phoneDesktop)
    screen:AddChild(view.phoneContent)
    shell:AddChild(screen)
    shell:AddChild(UI.Panel{id="career-phone-frame",position="absolute",left=0,top=0,width="100%",height="100%",
        backgroundImage=Phone.Frame,backgroundFit="fill",pointerEvents="none"})
    return shell
end
function Phone.Desktop(content,state,actions,height)
    content:AddChild(Kit.Text("第"..state.day.."天 · 南城 · "..(state.online and "正在听单" or "尚未上线"),12,
        Theme.Colors.amber,{id="career-phone-summary",width="100%",textAlign="center",visible=(height or 0)>=330}))
    local grid=UI.Panel{id="career-app-grid",width="100%",flexGrow=1,flexBasis=0,minHeight=156,gap=8,padding=0,
        justifyContent="center"}
    for row=1,2 do
        local line=UI.Row{id="career-app-row-"..row,width="100%",flexGrow=1,flexBasis=0,minHeight=74,maxHeight=98,
            padding=0,gap=6,alignItems="stretch"}
        for col=1,3 do
            local app=Phone.Apps[(row-1)*3+col]
            local id=app[1]
            line:AddChild(UI.Panel{id="career-app-"..id,flexGrow=1,flexShrink=1,flexBasis=0,minWidth=44,minHeight=74,
                padding=0,gap=4,alignItems="center",justifyContent="center",
                pointerEvents="box-only",onClick=function() actions.phone(id) end,
                children={UI.Panel{width=44,height=44,borderRadius=10,backgroundImage="image/career_phone/"..id..".png",
                    backgroundFit="contain",pointerEvents="none"},
                    Kit.Text(app[2],11,Theme.Colors.white,{width="100%",textAlign="center",pointerEvents="none"})}})
        end
        grid:AddChild(line)
    end
    content:AddChild(grid)
end
return Phone
