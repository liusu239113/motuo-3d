-- Button-only phone pages. This is a real Panel, not a disabled ScrollView.
-- Source controls keep their objects, props.visible, callbacks and order. A page
-- selects whole controls; oversized column cards select complete sibling controls.
-- Only a single text Label taller than a page gets lossless UTF-8 continuations.
local UI=require("urhox-libs/UI")
local Kit=require("Career.PhoneKit")

---@class CareerPhonePageUnit
---@field widget Widget
---@field source Widget
---@field members table<Widget, boolean>

---@class CareerPhonePages : Panel
---@field records table[]
---@field units CareerPhonePageUnit[]
---@field pages CareerPhonePageUnit[][]
---@field generated Widget[]
---@field constraints table[]
---@field pageIndex number
---@field requestedPage number
---@field measuring boolean
---@field signature string
---@field prevButton Button?
---@field nextButton Button?
---@field pageLabel Label?
---@field pager Widget?
---@field taskRoot Widget?
---@field taskDirectory Widget?
---@field tasks table[]
---@field taskId string
---@overload fun(props?: PanelProps): CareerPhonePages
local Pages=UI.Panel:Extend("CareerPhonePages")

function Pages:Init(props)
    self.records={};self.units={};self.pages={};self.generated={};self.constraints={}
    self.pageIndex=1;self.requestedPage=1;self.measuring=false;self.signature=""
    self.prevButton=nil;self.nextButton=nil;self.pageLabel=nil;self.pager=nil
    self.taskRoot=nil;self.taskDirectory=nil;self.tasks={};self.taskId=""
    UI.Panel.Init(self,props or {})
end

---@param previous Button
---@param following Button
---@param label Label
---@param pager Widget
function Pages:AttachPager(previous,following,label,pager)
    self.prevButton=previous;self.nextButton=following;self.pageLabel=label;self.pager=pager
    self:RefreshPager()
end

function Pages:RefreshPager()
    local count=math.max(1,#self.pages)
    if self.prevButton then self.prevButton:SetDisabled(self.pageIndex<=1) end
    if self.nextButton then self.nextButton:SetDisabled(self.pageIndex>=count) end
    if self.pageLabel then self.pageLabel:SetText(string.format("%d / %d",self.pageIndex,count)) end
    if self.pager then self.pager:SetVisible(self:IsVisible() and self:GetNumChildren()>0) end
end

-- Snapshot the actual Yoga values, including undefined/auto/percent. Reapplying
-- props alone is NOT an undo: ApplyStyleToYoga ignores nil fields, leaving e.g.
-- a temporary minHeight=0 / maxHeight=infinity or column direction behind.
local DIMENSIONS={
    {"Width",YGNodeStyleGetWidth,YGNodeStyleSetWidth,YGNodeStyleSetWidthPercent,YGNodeStyleSetWidthAuto},
    {"Height",YGNodeStyleGetHeight,YGNodeStyleSetHeight,YGNodeStyleSetHeightPercent,YGNodeStyleSetHeightAuto},
    {"MinWidth",YGNodeStyleGetMinWidth,YGNodeStyleSetMinWidth,YGNodeStyleSetMinWidthPercent},
    {"MaxWidth",YGNodeStyleGetMaxWidth,YGNodeStyleSetMaxWidth,YGNodeStyleSetMaxWidthPercent},
    {"MinHeight",YGNodeStyleGetMinHeight,YGNodeStyleSetMinHeight,YGNodeStyleSetMinHeightPercent},
    {"MaxHeight",YGNodeStyleGetMaxHeight,YGNodeStyleSetMaxHeight,YGNodeStyleSetMaxHeightPercent},
    {"FlexBasis",YGNodeStyleGetFlexBasis,YGNodeStyleSetFlexBasis,YGNodeStyleSetFlexBasisPercent,YGNodeStyleSetFlexBasisAuto},
}
local ENUM_STYLES={
    {YGNodeStyleGetFlexDirection,YGNodeStyleSetFlexDirection},
    {YGNodeStyleGetFlexWrap,YGNodeStyleSetFlexWrap},
    {YGNodeStyleGetAlignItems,YGNodeStyleSetAlignItems},
    {YGNodeStyleGetJustifyContent,YGNodeStyleSetJustifyContent},
    {YGNodeStyleGetFlexGrow,YGNodeStyleSetFlexGrow},
    {YGNodeStyleGetFlexShrink,YGNodeStyleSetFlexShrink},
}
---@param widget Widget
function Pages:Constrain(widget)
    for _,record in ipairs(self.constraints) do if record.widget==widget then return end end
    local record={widget=widget,dimensions={},enums={},padding={}}
    for i,spec in ipairs(DIMENSIONS) do record.dimensions[i]=spec[2](widget.node) end
    for i,spec in ipairs(ENUM_STYLES) do record.enums[i]=spec[1](widget.node) end
    for _,edge in ipairs({YGEdgeTop,YGEdgeBottom,YGEdgeRight}) do record.padding[edge]=YGNodeStyleGetPadding(widget.node,edge) end
    self.constraints[#self.constraints+1]=record
end

local function restoreConstraint(record)
    local widget=record.widget
    if not widget.node then return end
    for i,spec in ipairs(DIMENSIONS) do
        local value=record.dimensions[i]
        if value.unit==YGUnitPercent then spec[4](widget.node,value.value)
        elseif value.unit==YGUnitAuto and spec[5] then spec[5](widget.node)
        elseif value.unit==YGUnitMaxContent then _G["YGNodeStyleSet"..spec[1].."MaxContent"](widget.node)
        elseif value.unit==YGUnitFitContent then _G["YGNodeStyleSet"..spec[1].."FitContent"](widget.node)
        elseif value.unit==YGUnitStretch then _G["YGNodeStyleSet"..spec[1].."Stretch"](widget.node)
        else spec[3](widget.node,value.unit==YGUnitUndefined and YGGetUndefined() or value.value) end
    end
    for i,spec in ipairs(ENUM_STYLES) do spec[2](widget.node,record.enums[i]) end
    for edge,value in pairs(record.padding) do
        if value.unit==YGUnitPercent then YGNodeStyleSetPaddingPercent(widget.node,edge,value.value)
        else YGNodeStyleSetPadding(widget.node,edge,value.unit==YGUnitUndefined and YGGetUndefined() or value.value) end
    end
    -- Honor live business style changes made since the snapshot as well.
    widget:ApplyStyleToYoga(widget.props)
end

-- Page masking is NOT business visibility. Restore the exact IsVisible method
-- and Yoga display before measuring or detaching, never overwrite props.visible.
function Pages:RestoreSource()
    -- Detaching a generated direct child calls Pages:RemoveChild again. Take
    -- ownership up front so teardown cannot recursively revisit the same list.
    local records,constraints,generated=self.records,self.constraints,self.generated
    self.records={};self.constraints={};self.generated={};self.units={};self.pages={}
    for _,record in ipairs(records) do
        local widget=record.widget
        if widget.node then
            widget.IsVisible=record.isVisible
            widget._phonePageHidden=nil
            YGNodeStyleSetDisplay(widget.node,widget:IsVisible() and YGDisplayFlex or YGDisplayNone)
        end
    end
    for _,record in ipairs(constraints) do restoreConstraint(record) end
    for _,widget in ipairs(generated) do if widget.node then widget:Destroy() end end
    UI.MarkLayoutDirty()
end

-- 通过稳定业务卡片id识别现有生活分区。View仍拥有全部业务动作与数据；
-- 这里仅提供任务导航层，不需要给View或PhoneKit增加接线。
-- 分页时识别已经构建完成的控件树。
local LIFE_TASKS={
    {id="today",label="今日安排",anchors={"career-life-summary","career-life-plan","career-life-alert-1"}},
    {id="food",label="吃饭休息",anchors={"career-life-meal-card"}},
    {id="home",label="今晚住处",title="今晚住哪里"},
    {id="supply",label="续航与帮助",anchors={"career-life-range"}},
    {id="status",label="收支与状态",anchors={"career-life-day-ledger","career-life-stat-hunger"}},
    {id="settings",label="声音偏好",anchors={"career-music-card"}},
}

function Pages:ResetTasks()
    for _,task in ipairs(self.tasks) do
        for _,section in ipairs(task.sections) do
            if section.widget.node then section.widget:SetVisible(section.visible~=false) end
        end
    end
    self.taskRoot=nil;self.taskDirectory=nil;self.tasks={};self.taskId=""
end

function Pages:PrepareTasks()
    local root=self:GetChildAt(1)
    if self.taskRoot==root then return end
    self:ResetTasks()
    if not root or not root:FindById("career-life-summary") then return end
    self.taskRoot=root
    for _,definition in ipairs(LIFE_TASKS) do
        self.tasks[#self.tasks+1]={id=definition.id,label=definition.label,sections={}}
    end
    for _,section in ipairs(root:GetChildren()) do
        local assigned=false
        for index,definition in ipairs(LIFE_TASKS) do
            local match=false
            for _,id in ipairs(definition.anchors or {}) do if section:FindById(id) then match=true;break end end
            local title=section:GetChildAt(1)
            if definition.title and title and title.props.text==definition.title then match=true end
            if match then
                self.tasks[index].sections[#self.tasks[index].sections+1]={widget=section,visible=section.props.visible}
                assigned=true;break
            end
        end
        -- 不丢弃新增业务分区：尚未明确分类的分区先保留在“今日安排”中。
        if not assigned then self.tasks[1].sections[#self.tasks[1].sections+1]={widget=section,visible=section.props.visible} end
    end
    local directory=UI.Panel{id="career-life-tasks",width="100%",padding=0,gap=8,children={
        Kit.Heading("生活目录","按事情找入口，不必逐页翻找。","career-life-task-heading")}}
    for row=1,3 do
        -- 分数scale下，Yoga会对各flex子控件独立取整。保留真实尾部空间，
        -- 避免末尾完整按钮超出行框一物理像素；行容器本身也必须完整容纳。
        local edge=2/math.max(.1,UI.GetScale())
        local line=UI.Row{width="100%",padding=0,paddingBottom=edge,gap=6}
        for column=1,2 do
            local task=self.tasks[(row-1)*2+column]
            line:AddChild(Kit.Button(task.label,function() self:OpenTask(task.id) end,"career-life-task-"..task.id,false,
                {width="auto",flexGrow=1,flexShrink=1,flexBasis=0,marginRight=column==2 and edge or 0}))
        end
        directory:AddChild(line)
    end
    root:InsertChild(directory,1)
    local back=Kit.Button("返回生活目录",function() self:OpenTask("") end,"career-life-task-back",false)
    root:InsertChild(back,2)
    self.taskDirectory=directory
    self:ApplyTaskVisibility()
end

function Pages:ApplyTaskVisibility()
    if not self.taskRoot then return end
    if self.taskDirectory then self.taskDirectory:SetVisible(self.taskId=="") end
    local back=self.taskRoot:FindById("career-life-task-back")
    if back then back:SetVisible(self.taskId~="") end
    ---@type Widget?
    local ancestor=self.parent
    while ancestor do
        if ancestor.props.id=="career-phone-body" then
            local toolbarBack=ancestor:FindById("career-phone-back") --[[@as Button?]]
            if toolbarBack then toolbarBack:SetText(self.taskId~="" and "目录" or "首页") end
            break
        end
        ancestor=ancestor.parent
    end
    for _,task in ipairs(self.tasks) do
        for _,section in ipairs(task.sections) do section.widget:SetVisible(task.id==self.taskId and section.visible~=false) end
    end
end

---@param id string 空字符串表示打开任务目录。
---@return boolean
function Pages:OpenTask(id)
    if not self.taskRoot then return false end
    local found=id==""
    for _,task in ipairs(self.tasks) do if task.id==id then found=true end end
    if not found then return false end
    self:RestoreSource()
    self.taskId=id;self.requestedPage=1;self.signature=""
    self:ApplyTaskVisibility()
    self:Paginate()
    return true
end

---@return string?
function Pages:GetTask() return self.taskRoot and self.taskId or nil end

---@param child Widget
function Pages:AddChild(child)
    self:RestoreSource()
    self:ResetTasks()
    UI.Widget.AddChild(self,child)
    self.signature=""
    self:RefreshPager()
    return self
end

---@param child Widget
function Pages:RemoveChild(child)
    self:RestoreSource()
    if child==self.taskRoot then self:ResetTasks() end
    UI.Widget.RemoveChild(self,child)
    self.signature=""
    self:RefreshPager()
    return self
end

function Pages:ClearChildren()
    self:RestoreSource()
    self:ResetTasks()
    UI.Widget.ClearChildren(self)
    self.signature=""
    self:RefreshPager()
    return self
end
Pages.RemoveAllChildren=Pages.ClearChildren

-- Widget.Destroy iterates its live children backwards. RestoreSource removes
-- continuation siblings, so perform that teardown BEFORE the base iteration.
function Pages:Destroy()
    self:RestoreSource()
    self:ResetTasks()
    UI.Widget.Destroy(self)
end

-- Include logical props and tree identity, not the selected page's zero layouts.
-- This detects live map-picker changes, rebuilt lists, text/font and screen changes.
function Pages:SourceSignature()
    local bounds=self:GetLayout()
    local parts={tostring(bounds.w),tostring(bounds.h),tostring(UI.GetScale()),tostring(UI.GetFontVersion())}
    local function visit(widget)
        if widget._phoneContinuation then return end
        local p=widget.props
        parts[#parts+1]=table.concat({tostring(widget),tostring(p.visible),tostring(p.text),
            tostring(p.height),tostring(p.width),tostring(p.fontSize),tostring(p.fontWeight),
            tostring(p.gap),tostring(p.rowGap),tostring(p.columnGap),tostring(p.minHeight),tostring(p.maxHeight),
            tostring(p.minWidth),tostring(p.maxWidth),tostring(p.flexDirection),tostring(p.flexWrap),
            tostring(p.flexGrow),tostring(p.flexShrink),tostring(p.flexBasis),tostring(p.alignItems),
            tostring(p.justifyContent),tostring(p.marginTop),tostring(p.marginBottom),
            tostring(p.paddingTop),tostring(p.paddingBottom),tostring(p.paddingLeft),tostring(p.paddingRight)},"|")
        for _,child in ipairs(widget:GetChildren()) do visit(child) end
    end
    for _,child in ipairs(self:GetChildren()) do visit(child) end
    return table.concat(parts,";")
end

---@param widget Widget
local function updateNatural(widget)
    if widget.props.visible==false then return end
    if widget.Update then widget:Update(0) end
    for _,child in ipairs(widget:GetChildren()) do updateNatural(child) end
end

---@param widget Widget
local function register(self,widget)
    self.records[#self.records+1]={widget=widget,isVisible=widget.IsVisible}
    for _,child in ipairs(widget:GetChildren()) do register(self,child) end
end

---@param widget Widget
---@param set table<Widget, boolean>
local function includeTree(widget,set)
    if widget.props.visible==false then return end
    set[widget]=true
    for _,child in ipairs(widget:GetChildren()) do includeTree(child,set) end
end

---@param widget Widget
---@param source Widget
---@param context table<Widget, boolean>
local function makeUnit(widget,source,context)
    local members={}
    for item,value in pairs(context) do members[item]=value end
    includeTree(widget,members)
    return {widget=widget,source=source,members=members}
end

---@param widget Widget
---@param budget number
---@return Widget[]
function Pages:SplitText(widget,budget)
    local p=widget.props
    local source=p.text or ""
    local positions={}
    for offset in utf8.codes(source) do positions[#positions+1]=offset end
    positions[#positions+1]=#source+1
    local width=widget:GetLayout().w-(p.paddingLeft or 0)-(p.paddingRight or 0)
    local vertical=(p.paddingTop or 0)+(p.paddingBottom or 0)+2
    local size=UI.Theme.FontSize(p.fontSize)
    local function fits(text)
        local measured=UI.MeasureTextFit(text,{fontSize=size,minFontSize=size,
            fontFace=UI.Theme.FontFace(p.fontFamily,p.fontWeight),width=math.max(1,width-2),
            multiline=true,lineHeight=p.lineHeight or 1.35,letterSpacing=p.letterSpacing or 0})
        -- Match Label.Render's two overhang correction passes. Glyph bounds at
        -- the nominal width can include a wrap-triggering glyph; Render narrows
        -- the break width, sometimes adding a complete extra line. Never infer
        -- the continuation's height from nominal-width measurement alone.
        local vg=UI.GetNVGContext()
        nvgSave(vg);nvgResetTransform(vg)
        nvgFontFace(vg,UI.Theme.FontFace(p.fontFamily,p.fontWeight));nvgFontSize(vg,size)
        nvgTextLetterSpacing(vg,p.letterSpacing or 0);nvgTextLineHeight(vg,p.lineHeight or 1.35)
        local align=p.textAlign=="center" and NVG_ALIGN_CENTER or p.textAlign=="right" and NVG_ALIGN_RIGHT or NVG_ALIGN_LEFT
        nvgTextAlign(vg,align+NVG_ALIGN_TOP)
        local breakWidth=math.max(1,width)
        local rect=nvgTextBoxBounds(vg,0,0,breakWidth,text,nil,nil,false)
        for _=1,2 do
            if not rect then break end
            local left,right=math.max(0,-rect[1]),math.max(0,rect[3]-breakWidth)
            if left<=0 and right<=0 then break end
            breakWidth=math.max(1,breakWidth-(left>0 and left+1 or 0)-(right>0 and right+1 or 0))
            rect=nvgTextBoxBounds(vg,0,0,breakWidth,text,nil,nil,false)
        end
        nvgRestore(vg)
        local actual=rect and rect[4]-rect[2] or 0
        local height=math.ceil(math.max(measured.height or 0,actual))+vertical
        return measured.height and measured.height>0 and actual>0 and height<=budget,height
    end
    local result={}
    local first=1
    while first<#positions do
        local lo,hi,last=first,#positions-1,first-1
        while lo<=hi do
            local mid=math.floor((lo+hi)/2)
            if fits(source:sub(positions[first],positions[mid+1]-1)) then last=mid;lo=mid+1
            else hi=mid-1 end
        end
        assert(last>=first,string.format("手机可用高度连一行正文也容纳不下 %s / %.1fpx / %s",tostring(p.id),budget,source:sub(positions[first],positions[first+1]-1)))
        ---@type table
        local props={}
        for key,value in pairs(p) do if type(key)=="string" then rawset(props,key,value) end end
        props.id=p.id and p.id.."-continuation-"..(#result+1) or nil
        props.height=nil;props.maxHeight=nil
        local _,renderHeight=fits(source:sub(positions[first],positions[last+1]-1))
        props.minHeight=renderHeight
        -- A flex-basis=0 label may itself be a row column. After masking the
        -- source, its continuations must retain the measured column width, not
        -- become width=100% beside the same avatar/action context.
        props.width=widget:GetLayout().w
        props.flexGrow=0;props.flexShrink=0;props.flexBasis="auto"
        local text=source:sub(positions[first],positions[last+1]-1)
        local fragment=Kit.Text(text,p.fontSize,p.fontColor,props)
        fragment._phoneContinuation=true
        self.generated[#self.generated+1]=fragment
        result[#result+1]=fragment
        first=last+1
    end
    local parent=assert(widget.parent,"手机正文必须有父容器")
    local index=1
    for i,child in ipairs(parent:GetChildren()) do if child==widget then index=i;break end end
    for i,fragment in ipairs(result) do parent:InsertChild(fragment,index+i) end
    return result
end

-- Include descendant overflow, not just a flex item's (possibly constrained)
-- border box. Layout edges/margins are resolved Yoga values, not props guesses.
---@param widget Widget
local function naturalExtent(widget)
    local bounds=widget:GetAbsoluteLayout()
    local top,bottom=bounds.y,bounds.y+bounds.h
    local function inspect(item)
        if item.props.visible==false then return end
        local r=item:GetAbsoluteLayout()
        top=math.min(top,r.y);bottom=math.max(bottom,r.y+r.h)
        for _,child in ipairs(item:GetChildren()) do inspect(child) end
    end
    inspect(widget)
    return bottom-top
end

---@param widget Widget
local function settleNatural(widget)
    -- Reflow BEFORE classifying columns: removing a row's minimum/padding or
    -- changing its direction can change every wrapped label's natural height.
    for _=1,5 do UI.Layout();updateNatural(widget) end
    UI.Layout()
end

-- Split only complete controls. A normal one-tall-column bubble retains its
-- avatar; zero/multiple tall columns and wrapped rows become a vertical flow of
-- independent units in the SAME tree (no cloned buttons/callbacks or gestures).
---@param widget Widget
---@param budget number
---@param context table<Widget, boolean>
function Pages:Collect(widget,budget,context)
    if widget.props.visible==false then return end
    local margin=YGNodeLayoutGetMargin(widget.node,YGEdgeTop)+YGNodeLayoutGetMargin(widget.node,YGEdgeBottom)
    local room=budget-math.max(0,margin)
    if naturalExtent(widget)<=room then
        self.units[#self.units+1]=makeUnit(widget,widget,context)
        return
    end
    if widget._className=="Label" and widget.props.whiteSpace=="normal" then
        for _,fragment in ipairs(self:SplitText(widget,room)) do
            self.units[#self.units+1]=makeUnit(fragment,widget,context)
        end
        return
    end
    local children={}
    for _,child in ipairs(widget:GetChildren()) do
        if child.props.visible~=false and child.props.position~="absolute" then children[#children+1]=child end
    end
    assert(#children>0,string.format("手机完整控件无法容纳 %s / 自然高 %.2f / 可用 %.2f / scale %.4f",
        tostring(widget.props.id or widget._className),naturalExtent(widget),room,UI.GetScale()))
    local inherited={}
    for item,value in pairs(context) do inherited[item]=value end
    inherited[widget]=true
    local edgePadding=2/math.max(.1,UI.GetScale())
    self:Constrain(widget)
    YGNodeStyleSetHeightAuto(widget.node)
    YGNodeStyleSetMinHeight(widget.node,0)
    YGNodeStyleSetMaxHeight(widget.node,YGGetUndefined())
    YGNodeStyleSetPadding(widget.node,YGEdgeTop,0)
    YGNodeStyleSetPadding(widget.node,YGEdgeBottom,edgePadding)
    -- The row's horizontal flexBasis=0 is valid in a row parent only. Do not
    -- clear it before deciding to stack: that would change wrapping widths of
    -- ordinary one-tall-column headers while their ancestor stays horizontal.
    local parentDirection=widget.parent and YGNodeStyleGetFlexDirection(widget.parent.node)
    if parentDirection~=YGFlexDirectionRow and parentDirection~=YGFlexDirectionRowReverse then
        YGNodeStyleSetFlexGrow(widget.node,0)
        YGNodeStyleSetFlexShrink(widget.node,0)
        YGNodeStyleSetFlexBasisAuto(widget.node)
    end
    settleNatural(widget)
    -- Oversized padding/minHeight is decoration, not a tall child. Once removed,
    -- the whole row may already fit; keep all its controls together in that case.
    if naturalExtent(widget)<=room then
        self.units[#self.units+1]=makeUnit(widget,widget,context)
        return
    end
    local available=room-edgePadding-YGNodeLayoutGetBorder(widget.node,YGEdgeTop)
        -YGNodeLayoutGetBorder(widget.node,YGEdgeBottom)
    local direction=YGNodeStyleGetFlexDirection(widget.node)
    local row=direction==YGFlexDirectionRow or direction==YGFlexDirectionRowReverse
    if row then
        local tall={}
        for _,child in ipairs(children) do
            local outer=naturalExtent(child)+math.max(0,YGNodeLayoutGetMargin(child.node,YGEdgeTop)
                +YGNodeLayoutGetMargin(child.node,YGEdgeBottom))
            if outer>available then tall[#tall+1]=child end
        end
        if #tall==1 and YGNodeStyleGetFlexWrap(widget.node)==YGWrapNoWrap then
            for _,child in ipairs(children) do if child~=tall[1] then includeTree(child,inherited) end end
            self:Collect(tall[1],available,inherited)
            return
        end
        -- A row can overflow with ZERO tall columns (min/padding, flex-wrap,
        -- independent pixel rounding), or with MANY (stats and responsive text).
        -- Do not repeat unrelated columns on every continuation. Stack in source
        -- order; clear horizontal flexBasis=0 so column children cannot collapse.
        YGNodeStyleSetFlexDirection(widget.node,YGFlexDirectionColumn)
        YGNodeStyleSetFlexWrap(widget.node,YGWrapNoWrap)
        YGNodeStyleSetAlignItems(widget.node,YGAlignStretch)
        YGNodeStyleSetJustifyContent(widget.node,YGJustifyFlexStart)
        for _,child in ipairs(children) do
            self:Constrain(child)
            YGNodeStyleSetFlexGrow(child.node,0)
            YGNodeStyleSetFlexShrink(child.node,0)
            YGNodeStyleSetFlexBasisAuto(child.node)
            -- Horizontal percent widths/basis describe columns, not vertical
            -- cards. Auto-width flex columns need an explicit bounded width as
            -- well, otherwise Yoga may measure their nowrap/intrinsic content.
            if child.props.width==nil or child.props.width=="auto"
                or (type(child.props.width)=="string" and child.props.width:match("%%$")) then
                YGNodeStyleSetWidthPercent(child.node,100)
            end
        end
        settleNatural(widget)
    end
    for _,child in ipairs(children) do self:Collect(child,available,inherited) end
end

---@param units CareerPhonePageUnit[]
function Pages:Apply(units)
    local members={}
    for _,unit in ipairs(units) do for widget in pairs(unit.members) do members[widget]=true end end
    for _,record in ipairs(self.records) do
        local widget=record.widget
        if widget.node then
            widget._phonePageHidden=not members[widget]
            YGNodeStyleSetDisplay(widget.node,widget.props.visible~=false and members[widget] and YGDisplayFlex or YGDisplayNone)
        end
    end
    UI.MarkLayoutDirty()
end

-- Measure the original, unconstrained vertical tree at its ACTUAL wrapping
-- width. Then pack by applying candidates and measuring Yoga, not by guessed
-- card heights or viewport-sized pixel jumps. Nothing is rendered mid-measure.
-- UI.Update仍遍历隐藏子树，而Widget:IsVisible只检查自身props。
-- 不测量脱离挂载或祖先隐藏的手机：这些状态下Yoga边界为零，
-- 否则会每帧失效并反复尝试分页。
---@return boolean
function Pages:IsActiveInTree()
    ---@type Widget?
    local current=self
    while current do
        if not current.node or not current:IsVisible() or current.props.visibility=="hidden" then return false end
        if not current.parent then return current==UI.GetRoot() end
        current=current.parent
    end
    return false
end

function Pages:Paginate()
    if self.measuring or not self:IsActiveInTree() then return end
    if self:GetNumChildren()==0 then self:RefreshPager();return end
    self:PrepareTasks()
    self.measuring=true
    UI.Layout()
    local ready=self:GetLayout()
    if ready.w<=0 or ready.h<=0 then self.measuring=false;self:RefreshPager();return end
    local ok,failure=pcall(function()
        local selected=self.requestedPage
        self:RestoreSource()
        UI.Layout()
        for _=1,5 do
            for _,child in ipairs(self:GetChildren()) do updateNatural(child) end
            UI.Layout()
        end
        -- Yoga rounds each sibling's edges independently. Reserve physical
        -- trailing space INSIDE rows before measuring/packing; otherwise the
        -- last full button or flex label can cross its parent by >1 base px at
        -- scale<1 although nominal widths sum correctly. This is real layout
        -- space, restored with the other temporary constraints, not clipping.
        local function protectRows(widget)
            if widget.props.visible==false then return end
            local direction=YGNodeStyleGetFlexDirection(widget.node)
            if direction==YGFlexDirectionRow or direction==YGFlexDirectionRowReverse then
                self:Constrain(widget)
                local padding=YGNodeLayoutGetPadding(widget.node,YGEdgeRight)
                YGNodeStyleSetPadding(widget.node,YGEdgeRight,padding+2/math.max(.1,UI.GetScale()))
            end
            for _,child in ipairs(widget:GetChildren()) do protectRows(child) end
        end
        for _,child in ipairs(self:GetChildren()) do protectRows(child);settleNatural(child) end
        local bounds=self:GetLayout()
        assert(bounds.w>0 and bounds.h>0,"手机分页需要先挂载到有界布局")
        -- Two physical pixels protect independent Yoga edge rounding.
        local budget=bounds.h-2/math.max(.1,UI.GetScale())
        local sourceChildren={}
        for _,child in ipairs(self:GetChildren()) do sourceChildren[#sourceChildren+1]=child end
        -- SplitText inserts real continuation siblings. Never traverse that
        -- live array while appending, or newly inserted fragments split forever.
        for _,child in ipairs(sourceChildren) do self:Collect(child,budget,{}) end
        -- Continuation labels are inserted only after source measurement. Give
        -- them their final parent width and run the same natural-height updater.
        UI.Layout()
        for _=1,3 do
            for _,widget in ipairs(self.generated) do updateNatural(widget) end
            UI.Layout()
        end
        for _,child in ipairs(self:GetChildren()) do register(self,child) end
        for _,record in ipairs(self.records) do
            local sourceVisible=record.isVisible
            record.widget.IsVisible=function(widget) return not widget._phonePageHidden and sourceVisible(widget) end
        end
        local page={}
        local function fits(candidate)
            self:Apply(candidate);UI.Layout()
            local top=self:GetAbsoluteLayout().y
            local bottom=top
            local function inspect(widget)
                if not widget:IsVisible() then return end
                local rect=widget:GetAbsoluteLayout()
                bottom=math.max(bottom,rect.y+rect.h)
                for _,child in ipairs(widget:GetChildren()) do inspect(child) end
            end
            for _,child in ipairs(self:GetChildren()) do inspect(child) end
            return bottom<=top+bounds.h+.01
        end
        for _,unit in ipairs(self.units) do
            page[#page+1]=unit
            if not fits(page) then
                table.remove(page)
                assert(#page>0,"手机单个完整控件仍超出页高："..tostring(unit.source.props.id or unit.source._className))
                self.pages[#self.pages+1]=page
                page={unit}
                assert(fits(page),"手机拆分后的完整控件仍超出页高："..tostring(unit.source.props.id or unit.source._className))
            end
        end
        if #page>0 then self.pages[#self.pages+1]=page end
        self.pageIndex=math.max(1,math.min(selected,math.max(1,#self.pages)))
        self.requestedPage=self.pageIndex
        self:Apply(self.pages[self.pageIndex] or {})
        UI.Layout()
        self.signature=self:SourceSignature()
        self:RefreshPager()
        print(string.format("[手机按钮分页] %d页 / %d组完整控件 / 自然布局 %.1fx%.1f / 无滚动手势",#self.pages,#self.units,bounds.w,bounds.h))
    end)
    self.measuring=false
    if not ok then
        -- A genuine unsplittable leaf still fails loudly, but never leave half
        -- installed masks/temporary Yoga styles for the next frame or teardown.
        self:RestoreSource();UI.Layout()
        error(failure,0)
    end
end

function Pages:Update()
    if self.measuring or not self:IsActiveInTree() or self:GetNumChildren()==0 then return end
    if self.signature~=self:SourceSignature() then self:Paginate()
    elseif self.requestedPage~=self.pageIndex then self:SetPage(self.requestedPage) end
end

function Pages:GetPageCount() return #self.pages end
function Pages:GetPage() return self.pageIndex end
---@param page number
function Pages:SetPage(page)
    self.requestedPage=math.max(1,math.floor(page))
    -- 手机关闭或祖先隐藏时保留翻页请求；恢复可见前不应用分页遮罩，
    -- 也不强制执行全局布局。
    if not self:IsActiveInTree() then return end
    if self:GetNumChildren()>0 and self.signature~=self:SourceSignature() then self:Paginate() end
    self.pageIndex=math.max(1,math.min(self.requestedPage,math.max(1,#self.pages)))
    self.requestedPage=self.pageIndex
    self:Apply(self.pages[self.pageIndex] or {})
    UI.Layout()
    self:RefreshPager()
end
---@param target Widget|string
---@return boolean
function Pages:ShowWidget(target)
    if not self:IsActiveInTree() then return false end
    local widget=type(target)=="string" and self:FindById(target) or target
    if not widget then return false end
    if self.taskRoot then
        for _,task in ipairs(self.tasks) do
            for _,section in ipairs(task.sections) do
                local current=widget
                while current and current~=self.taskRoot do
                    if current==section.widget and task.id~=self.taskId then self:OpenTask(task.id);break end
                    current=current.parent
                end
            end
        end
    end
    if self.signature~=self:SourceSignature() then self:Paginate() end
    for index,page in ipairs(self.pages) do
        for _,unit in ipairs(page) do
            if unit.source==widget or unit.members[widget] then self:SetPage(index);return true end
        end
    end
    return false
end

-- Compatibility with former ScrollView callers: this Panel has NO pixel offset.
-- Widget hit-testing subtracts every ancestor's GetScroll(), so returning a page
-- index here would move descendants' hit boxes without moving their rendering.
-- Save/restore page selection explicitly with GetPage/SetPage instead.
function Pages:GetScroll() return 0,0 end
function Pages:SetScroll(_,__) return self end
function Pages:ScrollToTop() self:SetPage(1) end
function Pages:ScrollToBottom() self:SetPage(math.max(1,#self.pages)) end
function Pages:GetContentSize() return self:GetLayout().w,self:GetLayout().h end

return Pages
