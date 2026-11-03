-- 一致线性图标，挂在现有UI组件中绘制，不创建NanoVG上下文或独立帧。
local UI=require("urhox-libs/UI")
local Icon=UI.Widget:Extend("CareerLineIcon")
function Icon:Render(vg)
    local r=self:GetAbsoluteLayout()
    local unit=math.min(r.w,r.h)/24
    local x,y=r.x+(r.w-unit*24)/2,r.y+(r.h-unit*24)/2
    local function line(points)
        nvgMoveTo(vg,x+points[1]*unit,y+points[2]*unit)
        for i=3,#points,2 do nvgLineTo(vg,x+points[i]*unit,y+points[i+1]*unit) end
    end
    local function box(a,b,w,h) nvgRoundedRect(vg,x+a*unit,y+b*unit,w*unit,h*unit,unit) end
    local function circle(a,b,rad) nvgCircle(vg,x+a*unit,y+b*unit,rad*unit) end
    nvgBeginPath(vg)
    local kind=self.props.kind
    if kind=="phone" then
        box(6,2,12,20);line{10,5,14,5};line{11,19,13,19}
    elseif kind=="pause" then
        line{8,5,8,19};line{16,5,16,19}
    elseif kind=="food" then
        line{5,3,5,10,9,10,9,3};line{7,3,7,21};line{18,21,18,3,15,8,15,13,18,13}
    elseif kind=="energy" then
        line{13,2,5,14,11,14,10,22,19,9,13,9,13,2}
    elseif kind=="battery" then
        box(3,6,17,12);line{22,10,22,14};line{7,10,7,14};line{11,10,11,14};line{15,10,15,14}
    elseif kind=="fuel" then
        box(4,3,10,18);box(6,5,6,5);line{14,8,17,8,20,11,20,18,18,18,18,13,16,13};line{2,21,16,21}
    elseif kind=="bike" then
        circle(5,17,4);circle(19,17,4);line{5,17,10,7,15,17,5,17};line{10,7,18,7,19,17};line{8,4,12,4}
    elseif kind=="interact" then
        circle(12,12,4);line{3,8,3,3,8,3};line{16,3,21,3,21,8};line{21,16,21,21,16,21};line{8,21,3,21,3,16}
    elseif kind=="gas" then
        line{5,20,5,15,19,15,19,20};line{12,15,12,3};line{7,8,12,3,17,8}
    elseif kind=="brake" then
        circle(12,12,7);line{3,6,1,12,3,18};line{21,6,23,12,21,18};line{9,12,15,12}
    elseif kind=="player" then
        line{12,2,21,21,12,16,3,21,12,2}
    else
        circle(12,12,8)
    end
    local c=self.props.color or {239,242,243,255}
    local width=math.max(1.2,unit*1.6)
    -- 天空、墙面与阴影都可能出现在HUD后方，黑色外描边避免浅色图标消失。
    nvgStrokeColor(vg,nvgRGBA(0,0,0,220));nvgStrokeWidth(vg,width+2);nvgStroke(vg)
    nvgStrokeColor(vg,nvgRGBA(c[1],c[2],c[3],c[4] or 255))
    nvgStrokeWidth(vg,width);nvgStroke(vg)
end
return Icon
