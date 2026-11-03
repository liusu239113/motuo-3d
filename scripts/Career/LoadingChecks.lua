-- 正式UI帧中的加载连续更新回归：布局、控件身份、阶段进度和隐藏生命周期。
local UI=require("urhox-libs/UI")
local Loading=require("Career.LoadingScreen")
local Theme=require("RacingTheme")
local Checks={}
function Checks.Run()
    local oldRoot,oldLayout=UI.GetRoot(),UI.Layout
    local sizes,updates=0,0
    local fixture=Loading.New()
    local holder=UI.Panel{width=1000,height=600,padding=0,children={fixture.root}}
    local width,height=1000,600
    local function demand(value,message) assert(value,"[LoadingChecks] "..message) end
    local function count(widget)
        local total=1
        for _,child in ipairs(widget:GetChildren()) do total=total+count(child) end
        return total
    end
    local function rect(widget) return widget:GetAbsoluteLayout() end
    local function same(a,b)
        return math.abs(a.x-b.x)<.05 and math.abs(a.y-b.y)<.05
            and math.abs(a.w-b.w)<.05 and math.abs(a.h-b.h)<.05
    end
    local originalNodes=count(fixture.root)
    local title,detail,bar=fixture.title,fixture.detail,fixture.bar
    local ok,failure=pcall(function()
        UI.SetRoot(holder)
        UI.Layout=function()
            oldLayout()
            YGNodeCalculateLayout(holder.node,width,height,YGDirectionLTR)
        end
        demand(Theme.Theme.fonts[1].weights.normal==Theme.FontPath
            and Theme.Theme.fonts[1].weights.bold==Theme.FontPath,"常规/粗体必须同用宋体")
        for _,size in ipairs({{1000,400},{640,360},{800,600},{390,844}}) do
            width,height=size[1],size[2]
            holder:SetStyle{width=width,height=height}
            fixture:Show("正在下载骑行资源","下载器实时进度；已有资源直接复用，不重复下载。",0,"0 / 1234 项")
            UI.Layout()
            local body=rect(fixture.body)
            local fields={rect(title),rect(detail),rect(bar),rect(fixture.numbers),rect(fixture.percent)}
            for i=1,48 do
                local value=(i%13)/12
                local message=i%2==0 and "正在确认模型、字体与声音。" or
                    "详情变化不应改变加载外框。\n网络较慢时请耐心等待。\n额外下载信息也不能将容器撑满屏幕。"
                fixture:Show(i%3==0 and "正在校验资源" or "正在下载骑行资源",message,value,
                    string.format("%.2f / 88.88 MB · %d/1234 项",value*88.88,i))
                UI.Layout()
                for _,widget in ipairs({title,detail,fixture.numbers,fixture.percent,bar}) do widget:Render(UI.GetNVGContext()) end
                UI.Layout()
                demand(same(body,rect(fixture.body)),"连续进度更新造成外框跳动")
                for index,widget in ipairs({title,detail,bar,fixture.numbers,fixture.percent}) do
                    demand(same(fields[index],rect(widget)),"文字或进度条位置随回调改变")
                end
                demand(count(fixture.root)==originalNodes and title==fixture.title and detail==fixture.detail
                    and bar==fixture.bar,"进度更新不允许销毁重建控件")
                demand(math.abs(bar:GetValue()-value)<.0001,"必须保留真实当前阶段进度，不能伪造单调总进度")
                demand(body.y>=0 and body.y+body.h<=height+1 and body.x>=0 and body.x+body.w<=width+1,"加载区越屏")
                updates=updates+1
            end
            fixture:Hide();demand(not fixture.root:IsVisible(),"离开加载应隐藏")
            sizes=sizes+1
        end
    end)
    UI.Layout=oldLayout;UI.SetRoot(oldRoot);holder:Destroy();oldLayout()
    if not ok then error(failure,0) end
    print(string.format("[LoadingChecks] PASS %d尺寸/%d连续更新；固定布局/同一控件/真实阶段进度/宋体",sizes,updates))
    return sizes,updates
end
return Checks
