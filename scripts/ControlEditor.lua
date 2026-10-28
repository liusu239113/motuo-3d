-- 操作编辑器：与驾驶共用同一批控件、尺寸、中心坐标和安全区。
local UI = require("urhox-libs/UI")
local Settings = require("ControlSettings")
---@class ControlEditor
---@field screen string
---@field controls MobileControls
---@field actions table
---@field controlLayer Panel
---@field controlWidgets table<string, Widget>
---@field cockpit Widget
---@field pausedCockpitVisible boolean?
---@field SetScreen fun(self:ControlEditor, screen:string)
---@field LayoutResponsive fun(self:ControlEditor)
local Editor = {}
local AMBER, WHITE = {224,164,75,255}, {233,234,235,255}
local BORDER, DARK = {172,185,195,55}, {15,18,22,240}
local function label(text, size)
    return UI.Label {text=text, fontSize=size or 10, fontColor=WHITE, pointerEvents="none"}
end
local function button(text, action, width, primary)
    return UI.Button {text=text, onClick=action, width=width or 82, height=36, fontSize=10,
        padding=0, borderRadius=4, borderWidth=1, borderColor=BORDER,
        backgroundColor=primary and AMBER or {27,32,38,225},
        textColor=primary and {16,18,21,255} or WHITE}
end
local function full(props)
    props.position, props.left, props.top, props.right, props.bottom = "absolute",0,0,0,0
    props.padding=props.padding or 0
    return props
end

function Editor:BuildSettings()
        self.settingsSlot, self.settingsReturn, self.settingsToolsOpen = "steering", "menu", false
        self.settingsSchemeLabel = label("")
        self.settingsHint = label("直接拖动实战按键 · 松手自动保存", 9)
        self.settingsHint:SetStyle({textAlign="center"})
        self.settingsSelection = label("已选：转向")
        self.settingsSchemeButtons = {}
        self.settingsSchemeRow = UI.Row {padding=0, gap=5, flexWrap="wrap"}
        self.settingsSensitivityValue, self.settingsDeadzoneValue = label(""), label("")
        local function saved() self:SaveSettings("已保存并应用") end
        self.settingsSensitivity = UI.Slider {width="100%", min=50, max=160, step=1, value=100,
            onChange=function(_, value)
                if self.refreshingSettings then return end
                Settings.SetSlider("steeringSensitivity", value/100)
                self.settingsSensitivityValue:SetText(string.format("转向灵敏度  %.2f", value/100))
                self:ApplySettings()
            end, onChangeEnd=saved}
        self.settingsDeadzone = UI.Slider {width="100%", min=2, max=30, step=1, value=12,
            onChange=function(_, value)
                if self.refreshingSettings then return end
                Settings.SetSlider("steeringDeadzone", value/100)
                self.settingsDeadzoneValue:SetText(string.format("转向死区  %d%%", math.floor(value)))
                self:ApplySettings()
            end, onChangeEnd=saved}
        local function resize(delta)
            Settings.Scale(self.settingsSlot, delta)
            self:ApplySettings(); self:RefreshSettings(); self:SaveSettings("尺寸已保存")
        end
        self.settingsTools = UI.Panel {width="100%", padding=10, gap=6,
            backgroundColor={9,17,24,225}, borderRadius=5, visible=false, children={
                self.settingsSchemeLabel, self.settingsSchemeRow,
                UI.Row {padding=0, gap=5, children={
                    button("复制当前", function()
                        local ok, message=Settings.AddScheme("")
                        self:RefreshSettings(); self:ApplySettings()
                        self.settingsHint:SetText(ok and ("已复制："..message) or message)
                    end, 90),
                    button("删除方案", function()
                        if #Settings.All()<=1 then self.settingsHint:SetText("至少保留一套方案"); return end
                        self.settingsConfirm:Show()
                    end, 90),
                    button("恢复默认", function() self.settingsResetConfirm:Show() end, 90)}},
                UI.Row {padding=0, gap=6, alignItems="center", children={self.settingsSelection,
                    button("缩小", function() resize(-0.05) end, 60),
                    button("放大", function() resize(0.05) end, 60)}},
                self.settingsSensitivityValue, self.settingsSensitivity,
                self.settingsDeadzoneValue, self.settingsDeadzone,
                label("滑杆松手自动保存；收起面板可编辑其后方的按键。",8)}}
        self.settingsToolbarButton = button("灵敏度 / 方案", function()
            self.settingsToolsOpen=not self.settingsToolsOpen
            self.settingsTools:SetVisible(self.settingsToolsOpen)
            self.settingsToolbarButton:SetText(self.settingsToolsOpen and "收起面板" or "灵敏度 / 方案")
        end,112)
        self.settingsChrome = UI.Column {position="absolute", left="50%", marginLeft=-190,
            top=8, width=380, padding=0, gap=5, pointerEvents="box-none", children={
                UI.Row {width="100%", padding=5, gap=5, justifyContent="center",
                    backgroundColor={9,17,24,225}, borderRadius=5, children={
                        self.settingsToolbarButton,
                        button("保存", function() self:SaveSettings("全部设置已保存") end,72,true),
                        button("完成", function() self:CloseSettings() end,72)}},
                self.settingsHint,self.settingsTools}}
        local function confirm(text, action)
            return UI.Panel(full({visible=false, backgroundColor={4,9,14,180},
                justifyContent="center", alignItems="center", children={
                    UI.Column {width=300, padding=16, gap=12, backgroundColor=DARK, borderRadius=5, children={
                        label(text,12), UI.Row {gap=8,padding=0,children={
                            button("取消",function() self.settingsConfirm:Hide();self.settingsResetConfirm:Hide() end,110),
                            button("确认",action,110,true)}}}}}}))
        end
        self.settingsConfirm=confirm("删除当前方案？其他方案不受影响。",function()
            local ok,message=Settings.DeleteScheme()
            self.settingsConfirm:Hide();self:RefreshSettings();self:ApplySettings();self.settingsHint:SetText(message)
            if ok then self:SaveSettings("方案已删除") end
        end)
        self.settingsResetConfirm=confirm("恢复当前布局、尺寸和灵敏度？",function()
            Settings.ResetLayout()
            Settings.SetSlider("steeringSensitivity",1);Settings.SetSlider("steeringDeadzone",0.12)
            self.settingsResetConfirm:Hide();self:RefreshSettings();self:ApplySettings();self:SaveSettings("已恢复默认")
        end)
        self.settings=UI.Panel(full({visible=false,pointerEvents="box-none",zIndex=30,
            children={self.settingsChrome,self.settingsConfirm,self.settingsResetConfirm}}))
    end

function Editor:SaveSettings(message)
        local ok,err=Settings.Save()
        self.settingsHint:SetText(ok and (message or "已自动保存") or (err or "保存失败，请重试"))
        if not ok then print("[操作设置] "..(err or "写入失败")) end
        return ok
    end

function Editor:OpenSettings()
        if self.screen=="settings" then return end
        self.settingsReturn=self.screen=="pause" and "pause" or "menu"
        self.settingsToolsOpen=false
        self.settingsTools:Hide();self.settingsToolbarButton:SetText("灵敏度 / 方案")
        self.settingsHint:SetText("直接拖动实战按键 · 松手自动保存")
        self.controls:SetEditor({
            down=function(slot,event,widget) self:BeginDragSettingButton(slot,event,widget) end,
            move=function(event) self:DragSettingButton(event) end,
            up=function(event,cancelled) self:EndDragSettingButton(event,cancelled) end})
        local cockpitVisible = (self.cockpit and self.cockpit:IsVisible())
            or (self.settingsReturn == "pause" and self.pausedCockpitVisible)
        if self.actions.settings then self.actions.settings(true) else self:SetScreen("settings") end
        if cockpitVisible then self.cockpit:Show() end
        UI.Layout();self:ApplySettings();UI.Layout();self:RefreshSettings()
        print("[操作设置] 全屏真实按键编辑，返回页="..self.settingsReturn)
    end

function Editor:CloseSettings()
        if self.dragSlot then self:EndDragSettingButton(nil,true) end
        if not self:SaveSettings("全部设置已保存") then return end
        self.controls:SetEditor(nil)
        self.settingsConfirm:Hide();self.settingsResetConfirm:Hide()
        if self.actions.settings then self.actions.settings(false) else self:SetScreen(self.settingsReturn) end
        UI.Layout();self:ApplySettings();UI.Layout()
    end

function Editor:BeginDragSettingButton(slot,event,widget)
        if self.dragSlot or self.screen~="settings" then return end
        self.settingsSlot,self.dragSlot,self.dragPointer=slot,slot,event.pointerId
        local rect,area=widget:GetAbsoluteLayout(),self.controlLayer:GetAbsoluteLayout()
        self.dragOffsetX,self.dragOffsetY=event.x-rect.x,event.y-rect.y
        self.dragRectX,self.dragRectY,self.dragRectW,self.dragRectH=area.x,area.y,area.w,area.h
        self.dragWidth,self.dragHeight=rect.w,rect.h
        self.settingsSelection:SetText("已选："..(Settings.Labels[slot] or slot))
        widget:SetStyle({borderColor=AMBER,borderWidth=2})
    end

function Editor:DragSettingButton(event)
        if not self.dragSlot or event.pointerId~=self.dragPointer then return end
        local widget=self.controlWidgets[self.dragSlot]
        local x=math.max(0,math.min(self.dragRectW-self.dragWidth,event.x-self.dragRectX-self.dragOffsetX))
        local y=math.max(0,math.min(self.dragRectH-self.dragHeight,event.y-self.dragRectY-self.dragOffsetY))
        widget:SetStyle({left=x,top=y})
        self.dragPreviewX,self.dragPreviewY=(x+self.dragWidth*0.5)/self.dragRectW,(y+self.dragHeight*0.5)/self.dragRectH
    end

function Editor:EndDragSettingButton(event,cancelled)
        if not self.dragSlot or (event and event.pointerId~=self.dragPointer) then return end
        if not cancelled and self.dragPreviewX then
            Settings.SetPosition(self.dragSlot,self.dragPreviewX,self.dragPreviewY)
            self:SaveSettings("位置已自动保存")
        end
        self.dragSlot,self.dragPointer,self.dragPreviewX,self.dragPreviewY=nil,nil,nil,nil
        self:ApplySettings()
    end

function Editor:RefreshSettings()
        local scheme,index=Settings.Current(),Settings.ActiveIndex()
        self.settingsSchemeLabel:SetText(string.format("当前：%s  ·  %d / %d",scheme.name,index,#Settings.All()))
        for _,child in ipairs(self.settingsSchemeRow:GetChildren()) do child:Hide() end
        for i,entry in ipairs(Settings.All()) do
            local idx=i
            local b=self.settingsSchemeButtons[i]
            if not b then
                b=button("",function()
                    if self.dragSlot then self:EndDragSettingButton(nil,true) end
                    local ok=Settings.SetActive(idx)
                    self:RefreshSettings();self:ApplySettings()
                    self.settingsHint:SetText(ok and "方案已切换并应用" or "方案保存失败，请重试")
                end,90)
                b:SetHeight(28)
                self.settingsSchemeButtons[i]=b;self.settingsSchemeRow:AddChild(b)
            end
            b:Show();b:SetText(entry.name);b:SetStyle({borderColor=idx==index and AMBER or BORDER})
        end
        self.refreshingSettings=true
        self.settingsSensitivity:SetValue(scheme.steeringSensitivity*100)
        self.settingsDeadzone:SetValue(scheme.steeringDeadzone*100)
        self.refreshingSettings=false
        self.settingsSensitivityValue:SetText(string.format("转向灵敏度  %.2f",scheme.steeringSensitivity))
        self.settingsDeadzoneValue:SetText(string.format("转向死区  %d%%",math.floor(scheme.steeringDeadzone*100+0.5)))
        self.settingsSelection:SetText(string.format("已选：%s  ·  %d%%",Settings.Labels[self.settingsSlot],
            math.floor((scheme.scale[self.settingsSlot] or 1)*100+0.5)))
    end

function Editor:ApplySettings()
        local l=self.controlLayer:GetAbsoluteLayout()
        if l.w<=60 or l.h<=60 or l.w~=l.w or l.h~=l.h then self.pendingControlLayout=true;return end
        self.controlWidth,self.controlHeight=l.w,l.h
        self.controls:ApplyScheme(Settings.Current(),l.w,l.h)
    end

function Editor:UpdateLayout()
        self:LayoutResponsive()
        local l=self.controlLayer:GetAbsoluteLayout()
        if (self.screen=="ride" or self.screen=="settings") and not self.dragSlot
            and (self.pendingControlLayout or l.w~=self.controlWidth or l.h~=self.controlHeight) then
            if l.w>60 and l.h>60 then self.pendingControlLayout=false;self:ApplySettings() end
        end
    end
function Editor.Install(target)
    for name, method in pairs(Editor) do
        if name ~= "Install" then target[name] = method end
    end
end
return Editor
