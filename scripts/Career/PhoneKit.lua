-- 手机应用的组件语言：真实Widget树；不绘制截图、不接入独立业务或存储。
local UI=require("urhox-libs/UI")
local Kit={}
Kit.C={ink={30,43,45,255},muted={91,108,106,255},paper={244,247,246,255},
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
    props.minFontSize=props.fontSize -- 不用自动缩字掩盖信息架构问题。
    if props.whiteSpace=="normal" then
        props.width=props.width or "100%"
        if props.flexShrink==nil then props.flexShrink=0 end
    end
    local naturalHeight=props.whiteSpace=="normal" and props.height==nil
    local label=UI.Label(props)
    -- Label原生多行高度在Render才更新，离屏长卡片会先按一行排版。
    -- 用同一字体测量API在Update同步自然高度，整页包括滚动底部都参与布局。
    if naturalHeight then
        local inheritedUpdate=label.Update -- 当前Label/Widget没有Update；保留未来库实现的回调。
        local previous=""
        label.Update=function(self,dt)
            if inheritedUpdate then inheritedUpdate(self,dt) end
            local p=self.props
            local rawWidth=self:GetLayout().w-(p.paddingLeft or 0)-(p.paddingRight or 0)
            if rawWidth<=0 then return end
            -- 向下量化到1/64逻辑px，避免浮点末位抖动造成全页反复测量。
            -- 缩小不足1/64px只会保守增加行高，不会侵占字形空间。
            local width=math.floor(rawWidth*64)/64
            local source=p.text or ""
            local size=UI.Theme.FontSize(p.fontSize)
            local face=UI.Theme.FontFace(p.fontFamily,p.fontWeight)
            local key=string.format("%s|%.4f|%s|%.6f|%.4f|%s|%.4f|%.4f|%.4f|%.4f",source,width,
                tostring(UI.GetFontVersion()),UI.GetScale(),size,face,p.lineHeight,p.letterSpacing or 0,
                p.paddingTop or 0,p.paddingBottom or 0)
            if key==previous then return end
            local measured=UI.MeasureTextFit(source,{fontSize=size,minFontSize=size,
                fontFace=face,width=math.max(1,width-2),
                multiline=true,lineHeight=p.lineHeight,letterSpacing=p.letterSpacing or 0})
            -- 字体尚未就绪时不缓存失败，下一帧继续尝试；绝不把长文锁成一行。
            if source~="" and (measured.height or 0)<=0 then return end
            previous=key
            local height=math.ceil(math.max(size*p.lineHeight,measured.height or 0))+2
                +(p.paddingTop or 0)+(p.paddingBottom or 0)
            if math.abs(height-(p.height or 0))>.01 then self:SetHeight(height) end
        end
    end
    return label
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
    props.minFontSize=props.fontSize
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
-- 信息与动作分离：长标题/费用/现场条件不进入单行Button。
function Kit.ActionCard(id,title,description,terms,action,fn,primary)
    local card=Kit.Card(id and id.."-card" or nil)
    card:AddChild(Kit.Text(title,13,C.ink,{id=id and id.."-title" or nil,fontWeight="bold"}))
    if description and description~="" then card:AddChild(Kit.Text(description,11,C.muted)) end
    if terms and terms~="" then card:AddChild(Kit.Text(terms,11,C.green,{id=id and id.."-terms" or nil})) end
    card:AddChild(Kit.Button(action,fn,id,primary))
    return card
end
function Kit.Heading(title,subtitle,id)
    return UI.Panel{id=id,width="100%",padding=0,gap=3,children={
        Kit.Text(title,17,C.ink,{fontWeight="bold"}),Kit.Text(subtitle,10,C.muted)}}
end
function Kit.Tag(text,color)
    return Kit.Text(text,9,color or C.green,{width="100%",paddingHorizontal=6,paddingVertical=3,
        borderRadius=5,backgroundColor=C.pale})
end
-- 验收/实拍只更新手机子树（UI.Update会连同游戏HUD/全局动画一起推进）。
---@param root Widget
function Kit.LayoutTree(root)
    local function update(widget)
        if not widget:IsVisible() then return end
        if widget.Update then widget:Update(0) end
        for _,child in ipairs(widget:GetChildren()) do update(child) end
    end
    for _=1,4 do UI.Layout(); update(root) end
    UI.Layout()
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
