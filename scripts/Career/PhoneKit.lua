-- 手机应用的组件语言：真实Widget树；不绘制截图、不接入独立业务或存储。
local UI=require("urhox-libs/UI")
local Kit={}
Kit.C={ink={30,43,45,255},muted={108,123,123,255},paper={244,247,246,255},
    white={255,255,255,255},line={224,231,228,255},green={29,120,87,255},
    pale={226,241,232,255},orange={166,98,27,255},blue={46,100,137,255},red={172,71,64,255}}
local C=Kit.C
-- Yoga按物理像素对两端取整；44逻辑px在scale<1时可能回读43.x。
-- 多留一个物理像素，保证真实命中布局仍不小于44，而不是放宽验收阈值。
function Kit.TouchSize() return 44+1/math.max(.1,UI.GetScale()) end
function Kit.Text(text,size,color,props)
    props=props or {}
    props.text,props.fontSize,props.fontColor=text,size or 11,color or C.ink
    props.whiteSpace=props.whiteSpace or "normal"
    props.lineHeight=1.35; props.pointerEvents="none"
    return UI.Label(props)
end
function Kit.Card(id,props)
    props=props or {}
    props.id=id; props.width=props.width or "100%"; props.padding=props.padding or 10
    props.gap=props.gap or 7; props.borderRadius=props.borderRadius or 12
    props.backgroundColor=props.backgroundColor or C.white
    props.borderWidth=props.borderWidth or 0
    return UI.Panel(props)
end
function Kit.Button(text,fn,id,primary,props)
    props=props or {}
    props.text,props.onClick,props.id=text,fn,id
    local touchSize=Kit.TouchSize()
    props.width=props.width or "100%"; props.height=math.max(touchSize,props.height or 44)
    props.minHeight=math.max(touchSize,props.minHeight or 44); props.minWidth=math.max(touchSize,props.minWidth or 44)
    props.fontSize=props.fontSize or 11
    props.padding=props.padding or 4; props.borderRadius=9; props.borderWidth=0
    props.boxShadow=false; props.pressedBoxShadow=false
    local fill=primary and C.green or C.pale
    props.backgroundGradient={direction="to-bottom",from=fill,to=fill}
    props.variantBackgroundGradient={}; props.variantHoverBackgroundGradient={}; props.variantPressedBackgroundGradient={}
    props.hoverBackgroundGradient={direction="to-bottom",from=fill,to=fill}
    props.pressedBackgroundGradient={direction="to-bottom",from=fill,to=fill}
    props.backgroundColor=primary and C.green or C.pale
    props.hoverBackgroundColor=primary and {35,139,100,255} or {211,230,219,255}
    props.pressedBackgroundColor=primary and {22,94,68,255} or {198,219,205,255}
    props.textColor=primary and C.white or C.green
    return UI.Button(props)
end
function Kit.Heading(title,subtitle,id)
    return UI.Panel{id=id,width="100%",padding=0,gap=3,children={
        Kit.Text(title,17,C.ink,{fontWeight="bold"}),Kit.Text(subtitle,10,C.muted)}}
end
function Kit.Tag(text,color)
    return Kit.Text(text,9,color or C.green,{alignSelf="flex-start",whiteSpace="nowrap",paddingHorizontal=6,paddingVertical=3,
        borderRadius=5,backgroundColor=C.pale})
end
function Kit.Money(cents) return string.format("¥%.2f",cents/100) end
function Kit.Time(hour) return string.format("%02d:%02d",math.floor(hour),math.floor(hour*60)%60) end
function Kit.Stamp(day,hour) return "第"..day.."天 "..Kit.Time(hour) end
---@param parent Widget
function Kit.Clear(parent)
    for i=parent:GetNumChildren(),1,-1 do
        local child=parent:GetChildAt(i)
        if child then child:Destroy() end
    end
end
function Kit.Stat(title,value,color)
    return UI.Panel{flexGrow=1,flexShrink=1,flexBasis=0,minWidth=0,padding=0,gap=3,children={
        Kit.Text(title,9,color or C.muted),Kit.Text(value,12,color or C.ink,{fontWeight="bold"})}}
end
return Kit
