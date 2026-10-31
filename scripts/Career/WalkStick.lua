-- 生涯步行二维摇杆，沿用UI指针分发/捕获，不另建NanoVG渲染管线。
local UI=require("urhox-libs/UI")
local Stick={}
Stick.__index=Stick
function Stick.New(blocked)
    local self=setmetatable({},Stick)
    self:Init(blocked)
    return self
end
function Stick:Init(blocked)
    self.x,self.y,self.pointer=0,0,-1
    self.blocked=blocked
    self.knob=UI.Panel{position="absolute",left=49,top=49,width=58,height=58,borderRadius=29,
        backgroundGradient={type="linear",direction="to-bottom",from={112,133,141,235},to={37,51,62,245}},
        borderWidth=2,borderColor={194,221,225,210},pointerEvents="none",padding=0}
    self.root=UI.Panel{id="career-walk-stick",position="absolute",left=22,bottom=26,width=156,height=156,
        borderRadius=78,padding=0,backgroundColor={10,20,27,125},borderWidth=2,borderColor={185,215,221,130},
        pointerEvents="box-only",children={self.knob},
        onPointerDown=function(e)
            if blocked() or self.pointer~=-1 or not e:IsPrimaryAction() then return end
            self.pointer=e.pointerId; self:Move(e); e:StopPropagation()
        end,
        onPointerMove=function(e) if self.pointer==e.pointerId then self:Move(e); e:StopPropagation() end end,
        onPointerUp=function(e) if self.pointer==e.pointerId then self:Reset(); e:StopPropagation() end end,
        onPointerCancel=function(e) if self.pointer==e.pointerId then self:Reset(); e:StopPropagation() end end}
end
function Stick:Move(e)
    local r=self.root:GetAbsoluteLayout()
    local dx,dy=(e.x-r.x-r.w/2)/(r.w*.32),(e.y-r.y-r.h/2)/(r.h*.32)
    local len=math.sqrt(dx*dx+dy*dy)
    if len>1 then dx,dy=dx/len,dy/len end
    local strength=math.min(1,len)
    if strength<.12 then self.x,self.y=0,0 else
        local gain=(strength-.12)/.88
        self.x,self.y=dx/math.max(.001,strength)*gain,-dy/math.max(.001,strength)*gain
    end
    self.knob:SetStyle{left=r.w/2-29+dx*r.w*.25,top=r.h/2-29+dy*r.h*.25}
end
function Stick:Reset()
    self.x,self.y,self.pointer=0,0,-1
    self.knob:SetStyle{left=49,top=49}
end
return Stick
