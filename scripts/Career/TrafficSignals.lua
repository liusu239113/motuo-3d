-- 信号灯只更新灯芯材质，不逐帧重建城市几何；标线在城市批次提交前建立。
local Parts=require("Parts")
local Routes=require("Career.TrafficRoutes")
local Signals={}
Signals.__index=Signals
function Signals.New(root,details)
    local self=setmetatable({},Signals)
    self:Init(root,details)
    return self
end
function Signals:Init(root,details)
    self.heads={}
    self.dark=Parts.Material(.025,.032,.038,.65,.15)
    self.off=Parts.Material(.045,.055,.05,.7)
    self.colors={red=Parts.Material(.95,.025,.015,.35,0,2),yellow=Parts.Material(1,.58,.025,.35,0,2),green=Parts.Material(.025,.9,.22,.35,0,2)}
    self.phase=""
    for _,j in ipairs(Routes.Junctions) do
        for _,arm in ipairs({{0,1,"ns",0},{0,-1,"ns",180},{1,0,"ew",90},{-1,0,"ew",270}}) do
            local dx,dz=arm[1],arm[2]
            local yaw=arm[4]
            local corner=root:CreateChild("老街实体信号灯")
            corner.position=Vector3(j.x+dx*11+dz*7.2,.085,j.z+dz*11-dx*7.2)
            corner.rotation=Quaternion(0,yaw,0)
            Parts.Bar(corner,self.dark,Vector3.ZERO,Vector3(0,4.2,0),.07)
            Parts.Add(corner,"防撞底座","Box",self.dark,Vector3(0,.25,0),Vector3(.28,.5,.28))
            Parts.Add(corner,"信号灯壳","Box",self.dark,Vector3(0,3.7,0),Vector3(.48,1.28,.28))
            local lenses={}
            for i,color in ipairs({"red","yellow","green"}) do
                local y=4.08-(i-1)*.38
                Parts.Add(corner,"遮光眉","Box",self.dark,Vector3(0,y+.16,.18),Vector3(.47,.045,.3))
                local lens=Parts.Add(corner,color,"Sphere",self.off,Vector3(0,y,.17),Vector3(.27,.27,.085),nil,false)
                lenses[color]=lens:GetComponent("StaticModel")
            end
            self.heads[#self.heads+1]={axis=arm[3],lenses=lenses}
            -- 右侧行车停止线：距中心12m，位于9m处斑马线外侧。
            if dx==0 then details:Ground("paint",j.x-dz*3,j.z+dz*12,5.4,.32,.087)
            else details:Ground("paint",j.x+dx*12,j.z+dx*3,.32,5.4,.087) end
        end
        -- 补齐东西向过街带，和已有南北向斑马线组成四边路口。
        for n=-3,3 do
            details:Ground("paint",j.x-9,j.z+n,3,.5,.086)
            details:Ground("paint",j.x+9,j.z+n,3,.5,.086)
        end
    end
    self:Update(0)
end
function Signals:Update(seconds)
    local ns,ew=Routes.Signal(seconds,"ns"),Routes.Signal(seconds,"ew")
    local phase=ns..ew
    if self.phase==phase then return end
    self.phase=phase
    for _,head in ipairs(self.heads) do
        local selected=head.axis=="ns" and ns or ew
        for color,lens in pairs(head.lenses) do lens.material=color==selected and self.colors[color] or self.off end
    end
end
return Signals
