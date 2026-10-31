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
---@overload fun(props?: PanelProps): CareerPhonePages
local Pages=UI.Panel:Extend("CareerPhonePages")

function Pages:Init(props)
    self.records={};self.units={};self.pages={};self.generated={};self.constraints={}
    self.pageIndex=1;self.requestedPage=1;self.measuring=false;self.signature=""
    self.prevButton=nil;self.nextButton=nil;self.pageLabel=nil;self.pager=nil
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
    for _,record in ipairs(constraints) do
        if record.widget.node then record.widget:ApplyStyleToYoga(record.widget.props) end
    end
    for _,widget in ipairs(generated) do if widget.node then widget:Destroy() end end
end

---@param child Widget
function Pages:AddChild(child)
    self:RestoreSource()
    UI.Widget.AddChild(self,child)
    self.signature=""
    self:RefreshPager()
    return self
end

---@param child Widget
function Pages:RemoveChild(child)
    self:RestoreSource()
    UI.Widget.RemoveChild(self,child)
    self.signature=""
    self:RefreshPager()
    return self
end

function Pages:ClearChildren()
    self:RestoreSource()
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
            tostring(p.gap),tostring(p.minHeight)},"|")
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
        return measured.height and measured.height>0 and math.ceil(measured.height)+vertical<=budget
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
        props.height=nil;props.minHeight=nil;props.maxHeight=nil
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

-- Recursively split ONLY if a whole card cannot fit. A horizontal row retains
-- its other columns on every continuation, so avatar/stat widths cannot shift.
---@param widget Widget
---@param budget number
---@param context table<Widget, boolean>
function Pages:Collect(widget,budget,context)
    if widget.props.visible==false then return end
    local bounds=widget:GetLayout()
    if bounds.h<=budget then
        self.units[#self.units+1]=makeUnit(widget,widget,context)
        return
    end
    if widget._className=="Label" and widget.props.whiteSpace=="normal" then
        for _,fragment in ipairs(self:SplitText(widget,budget)) do
            self.units[#self.units+1]=makeUnit(fragment,widget,context)
        end
        return
    end
    local children={}
    for _,child in ipairs(widget:GetChildren()) do
        if child.props.visible~=false and child.props.position~="absolute" then children[#children+1]=child end
    end
    assert(#children>0,"手机控件高于整页且无法安全拆分："..tostring(widget.props.id or widget._className))
    local inherited={}
    for item,value in pairs(context) do inherited[item]=value end
    inherited[widget]=true
    -- Fragmented cards keep horizontal wrapping/padding, but omit decorative
    -- vertical padding on continuations. On a short landscape phone, nested
    -- padding must not consume the last complete text line or touch target.
    local edgePadding=2/math.max(.1,UI.GetScale())
    local available=budget-edgePadding-(widget.props.borderTopWidth or widget.props.borderWidth or 0)
        -(widget.props.borderBottomWidth or widget.props.borderWidth or 0)
    self.constraints[#self.constraints+1]={widget=widget}
    YGNodeStyleSetHeightAuto(widget.node)
    YGNodeStyleSetMinHeight(widget.node,0)
    YGNodeStyleSetMaxHeight(widget.node,math.huge)
    YGNodeStyleSetPadding(widget.node,YGEdgeTop,0)
    -- Child and parent Yoga edges round independently at fractional UI scale.
    -- Reserve real trailing pixels so the final full-height label stays inside
    -- its fragmented card; this is layout space, not an audit tolerance.
    YGNodeStyleSetPadding(widget.node,YGEdgeBottom,edgePadding)
    local row=widget.props.flexDirection=="row"
    if row then
        -- At most one tall column occurs in current phone rows (message bubble,
        -- header label). Multiple tall columns need explicit app-level layout.
        local tall={}
        for _,child in ipairs(children) do
            if child:GetLayout().h>available then tall[#tall+1]=child
            else includeTree(child,inherited) end
        end
        assert(#tall==1,"手机超高横排需显式拆为纵向卡片："..tostring(widget.props.id))
        self:Collect(tall[1],available,inherited)
    else
        for _,child in ipairs(children) do self:Collect(child,available,inherited) end
    end
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
function Pages:Paginate()
    if self.measuring or not self:IsVisible() or self:GetNumChildren()==0 then self:RefreshPager();return end
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
    if not ok then error(failure,0) end
end

function Pages:Update()
    if self.measuring or not self:IsVisible() or self:GetNumChildren()==0 then return end
    if self.signature~=self:SourceSignature() then self:Paginate() end
end

function Pages:GetPageCount() return #self.pages end
function Pages:GetPage() return self.pageIndex end
---@param page number
function Pages:SetPage(page)
    self.requestedPage=math.max(1,math.floor(page))
    if self:GetNumChildren()>0 and self:IsVisible() and self.signature~=self:SourceSignature() then self:Paginate() end
    self.pageIndex=math.max(1,math.min(self.requestedPage,math.max(1,#self.pages)))
    self.requestedPage=self.pageIndex
    self:Apply(self.pages[self.pageIndex] or {})
    UI.Layout()
    self:RefreshPager()
end
---@param target Widget|string
---@return boolean
function Pages:ShowWidget(target)
    if self.signature~=self:SourceSignature() then self:Paginate() end
    local widget=type(target)=="string" and self:FindById(target) or target
    if not widget then return false end
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
