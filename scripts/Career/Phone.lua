-- 手机硬件、桌面与应用入口；真实功能仍由View/Session处理，不把整图当交互。
local UI=require("urhox-libs/UI")
local Theme=require("RacingTheme")
local Phone={}
Phone.Frame="image/career_phone_hardware_frame_20261028190339.png"
Phone.Wallpaper="image/career_phone_wallpaper_20261028185104.png"
Phone.Apps={{"delivery","外卖骑手"},{"map","南城地图"},{"wallet","钱包"},
    {"messages","消息"},{"life","生活"},{"progression","车手生涯"}}
Phone.Resources={Phone.Frame,Phone.Wallpaper}
for _,app in ipairs(Phone.Apps) do Phone.Resources[#Phone.Resources+1]="image/career_phone/"..app[1]..".png" end
function Phone.Create(view,actions)
    local shell=UI.Panel{width=324,maxWidth="94%",height="100%",maxHeight=690,padding=0,
        backgroundColor={7,10,13,255},borderRadius=30,overflow="hidden"}
    local screen=UI.Panel{position="absolute",left="8.5%",right="8.5%",top="7.2%",bottom="6.5%",
        padding=9,gap=7,backgroundImage=Phone.Wallpaper,backgroundFit="cover",overflow="hidden",borderRadius=12}
    view.phoneClock=Theme.Label("08:00",10,Theme.Colors.white)
    screen:AddChild(UI.Row{width="100%",height=18,padding=0,justifyContent="space-between",children={
        view.phoneClock,Theme.Label("4G  ▂▄▆  86%",9,Theme.Colors.white)}})
    view.phoneTitle=Theme.Label("王二狗的手机",13,Theme.Colors.white,{fontWeight="bold",flexShrink=1})
    screen:AddChild(UI.Row{width="100%",padding=0,gap=5,alignItems="center",children={view.phoneTitle,
        Theme.Button("收起",actions.closePhone,false,48,{height=30,padding=0,marginLeft="auto",fontSize=10})}})
    view.phoneContent=UI.ScrollView{width="100%",flexGrow=1,flexBasis=0,minHeight=0,padding=0}
    screen:AddChild(view.phoneContent)
    screen:AddChild(UI.Row{width="100%",gap=6,padding=0,children={
        Theme.Button("应用首页",function() actions.phone("apps") end,false,"100%",{height=30,fontSize=10})}})
    screen:AddChild(UI.Panel{width=75,height=3,alignSelf="center",backgroundColor={230,239,240,210},borderRadius=2})
    shell:AddChild(screen)
    shell:AddChild(UI.Panel{position="absolute",left=0,top=0,width="100%",height="100%",
        backgroundImage=Phone.Frame,backgroundFit="fill",pointerEvents="none"})
    return shell
end
function Phone.Desktop(content,state,actions)
    content:AddChild(Theme.Label(string.format("%02d:%02d",math.floor(state.time),math.floor(state.time*60)%60),34,
        Theme.Colors.white,{textAlign="center",fontWeight="bold",marginTop=8}))
    content:AddChild(Theme.Label("第"..state.day.."天 · 南城",11,Theme.Colors.white,{textAlign="center",marginBottom=9}))
    local grid=UI.SimpleGrid{width="100%",columns=3,gap=7,padding=0}
    for _,app in ipairs(Phone.Apps) do
        local id=app[1]
        grid:AddChild(UI.Panel{id="career-app-"..id,height=83,padding=0,gap=5,alignItems="center",
            pointerEvents="box-only",onClick=function() actions.phone(id) end,
            children={UI.Panel{width=54,height=54,borderRadius=12,backgroundImage="image/career_phone/"..id..".png",
                backgroundFit="contain",pointerEvents="none"},
                Theme.Label(app[2],10,Theme.Colors.white,{textAlign="center",pointerEvents="none"})}})
    end
    content:AddChild(grid)
    content:AddChild(UI.Panel{width="100%",padding=10,gap=5,borderRadius=12,backgroundColor={6,19,28,175},children={
        Theme.Label(state.online and "外卖骑手 · 正在听单" or "外卖骑手 · 尚未上线",11,Theme.Colors.amber),
        Theme.Label(string.format("现金 ¥%.2f · 已完成%d单",state.cashCents/100,state.completedOrders),10,Theme.Colors.white),
        Theme.Label("停车用手机，收起后继续生活。",9,Theme.Colors.muted)}})
end
return Phone
