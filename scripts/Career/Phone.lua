-- 手机硬件、桌面与应用入口；真实功能仍由View/Session处理，不把整图当交互。
local UI=require("urhox-libs/UI")
local Theme=require("RacingTheme")
local Kit=require("Career.PhoneKit")
local PhonePages=require("Career.PhonePages")
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
        {id="career-phone-back",height=touchSize,minHeight=touchSize,minWidth=touchSize,
            paddingLeft=4,paddingRight=4,paddingTop=0,paddingBottom=0,
            paddingHorizontal=4,paddingVertical=0,hoverPadding={0,4,0,4},pressedPadding={0,4,0,4},fontSize=12,visible=false})
    screen:AddChild(UI.Row{id="career-phone-toolbar",width="100%",height=touchSize,minHeight=touchSize,padding=0,gap=4,alignItems="center",children={
        view.phoneBack,view.phoneTitle,
        Theme.Button("收起",function() actions.closePhone() end,false,52,{id="career-phone-close",height=touchSize,minHeight=touchSize,minWidth=touchSize,
            paddingLeft=4,paddingRight=4,paddingTop=0,paddingBottom=0,
            paddingHorizontal=4,paddingVertical=0,hoverPadding={0,4,0,4},pressedPadding={0,4,0,4},fontSize=12})}})
    -- 桌面仍为两行三列；内页使用真实Panel和固定按钮分页，没有滚轮/拖拽/惯性。
    view.phoneDesktop=UI.Panel{id="career-phone-desktop",width="100%",flexGrow=1,flexBasis=0,minHeight=0,padding=0,overflow="hidden"}
    local pages=PhonePages{id="career-phone-content",width="100%",flexGrow=1,flexBasis=0,minHeight=0,
        padding=0,overflow="hidden",visible=false}
    view.phoneContent=pages
    local previous=Kit.Button("上一页",function() pages:SetPage(pages:GetPage()-1) end,"career-phone-page-prev",false,
        {width=66,padding=0,fontSize=11})
    local following=Kit.Button("下一页",function() pages:SetPage(pages:GetPage()+1) end,"career-phone-page-next",true,
        {width=66,padding=0,fontSize=11})
    local number=Kit.Text("1 / 1",10,Kit.C.white,{id="career-phone-page-number",width="auto",
        flexGrow=1,flexShrink=1,flexBasis=0,minWidth=0,height=touchSize,minHeight=touchSize,
        verticalAlign="middle",textAlign="center",whiteSpace="nowrap"})
    local pager=UI.Row{id="career-phone-pagination",width="100%",padding=0,gap=4,height=touchSize,minHeight=touchSize,
        flexShrink=0,alignItems="center",visible=false,children={previous,number,following}}
    pages:AttachPager(previous,following,number,pager)
    screen:AddChild(view.phoneDesktop)
    screen:AddChild(pages)
    screen:AddChild(pager)
    shell:AddChild(screen)
    shell:AddChild(UI.Panel{id="career-phone-frame",position="absolute",left=0,top=0,width="100%",height="100%",
        backgroundImage=Phone.Frame,backgroundFit="fill",pointerEvents="none"})
    return shell
end
-- Call once at the END of View:BuildPhone, after every app branch has added
-- its controls. The widget also reflows on width/font/live-source changes.
---@param view CareerView
function Phone.Paginate(view)
    local pages=view.phoneContent --[[@as CareerPhonePages]]
    pages:RefreshPager()
    if view.phonePage~="apps" and view.phonePage~="" then
        -- First open may precede phoneArea.Update; resolve its actual safe-area
        -- dimensions before measuring cards. No global UI.Update/game tick.
        UI.Layout()
        local area=view.phoneArea
        if area then
            local bounds=area:GetLayout()
            Phone.Layout(view,bounds.w,bounds.h)
        end
        pages:Paginate()
    end
end
function Phone.Desktop(content,state,actions,height)
    local summary=Kit.Text("第"..state.day.."天 · 南城 · "..(state.online and "正在听单" or "尚未上线"),12,
        Theme.Colors.amber,{id="career-phone-summary",width="100%",textAlign="center",visible=(height or 0)>=330})
    content:AddChild(summary)
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
        -- 每列保持图标44px；文字自然高度不能被旧minHeight74夹住。
        local rowMinimum=74
        line.Update=function(self)
            local required=74
            for _,icon in ipairs(self:GetChildren()) do
                local caption=icon:GetChildAt(2)
                if caption then required=math.max(required,44+4+(caption.props.height or 0)) end
            end
            if math.abs(required-rowMinimum)>.01 then
                rowMinimum=required
                self:SetStyle{minHeight=required,maxHeight=math.max(98,required)}
                for _,icon in ipairs(self:GetChildren()) do icon:SetStyle{minHeight=required} end
                -- 两行都使用同字体字号；按较高行给网格保底。
                grid:SetStyle{minHeight=required*2+8}
            end
        end
        grid:AddChild(line)
    end
    content:AddChild(grid)
end
return Phone
