-- 显示专用LOD：保留原始模型做碰撞、轮胎、尺寸；不覆盖资源库源文件。
local Lod={}
local replacements={
    c531d52ef7284ea8ae32f415bfe4b98e="model/DisplayLod/building1.mdl",
    ["94b007f45c784751825b3e1b8e1e624a"]="model/DisplayLod/building2.mdl",
    ["863a459ef93647c88fe260263a9b2a1d"]="model/DisplayLod/building3.mdl",
    ["3299d6bc46c84215a963d4b7ec4ba7e8"]="model/DisplayLod/sedan.mdl",
    d598150db01f4e538e87d0cf9c27695a="model/DisplayLod/suv.mdl",
    ecb5c5d083ec481f8b58c2f1c79dc840="model/DisplayLod/truck.mdl",
}
Lod.Resources={}
for _,path in pairs(replacements) do Lod.Resources[#Lod.Resources+1]=path end
local originalOnly=false
for _,arg in ipairs(GetArguments()) do if arg=="-careeroriginallod" then originalOnly=true end end

-- 每个持有者只拥有轻量Model克隆；底层Geometry/缓冲由源资源共享，不复制顶点。
---@param model Model
function Lod.Levels(model)
    local stem=model.name:match("([^/]+)%.mdl$")
    local path=not originalOnly and replacements[stem] or nil
    local display=path and assert(cache:GetResource("Model",path),path) or model
    local levels={model}
    for level=1,3 do
        local copy=display:Clone()
        for i=0,display:GetNumGeometries()-1 do
            local index=math.min(level,display:GetNumGeometryLodLevels(i)-1)
            local geometry=display:GetGeometry(i,index)
            copy:SetNumGeometryLodLevels(i,1)
            copy:SetGeometry(i,0,geometry)
        end
        levels[#levels+1]=copy
    end
    return levels
end
function Lod.Release(levels)
    for i=2,#levels do levels[i]:Dispose() end
end
---@param root Node
---@param list table[]
function Lod.Vehicle(root,list,x,z)
    local mesh=root:GetChild("DetailedBody")
    local draw=mesh and mesh:GetComponent("StaticModel") or nil
    if draw then list[#list+1]={draw=draw,levels=Lod.Levels(draw.model),x=x,z=z,level=1} end
end
---@param draws table[]
function Lod.Update(draws,x,z)
    for _,entry in ipairs(draws) do
        local distance=(entry.x-x)^2+(entry.z-z)^2
        -- 车辆近景22m、建筑近景45m保留原模型，近处栏杆/窗框不提前消失。
        local near,mid,far=entry.near or 22,entry.mid or 65,entry.far or 150
        local level=distance<near^2 and 1 or distance<mid^2 and 2 or distance<far^2 and 3 or 4
        if level~=entry.level then entry.draw.model=entry.levels[level];entry.level=level end
    end
end
return Lod
