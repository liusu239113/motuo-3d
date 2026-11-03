-- 轻量赛道资源：基础网格和纯色材质共享，障碍不加载外部MDL或D/N贴图。
-- 基于Parts及原程序化赛道实现；每种网格只生成一次，所有机关关闭投影阴影。
local P=require("Parts")
local V=Vector3
local M={Resources={"Techniques/PBR/PBRNoTexture.xml"},
    ResourceTypes={["Techniques/PBR/PBRNoTexture.xml"]="Technique"}}
---@type table<string, Model>
local models={}
---@type table<string, Material>
local materials={}
local colors={orange={.95,.30,.035},dark={.055,.065,.075},yellow={.98,.76,.08},
    steel={.32,.39,.44},wood={.43,.24,.10}}

local function prepare()
    if models.box then return end
    models.box=BoxGeometry(1,1,1):ToModel()
    models.cylinder=CylinderGeometry(.5,.5,1,10):ToModel()
    models.sphere=SphereGeometry(.5,12,8):ToModel()
    models.cone=ConeGeometry(.5,1,12):ToModel()
    for key,rgb in pairs(colors) do
        materials[key]=P.Material(rgb[1],rgb[2],rgb[3],.8,key=="steel" and .2 or 0)
    end
    print("[轻量机关] 共享网格4种 / 材质5种 / 外部模型与贴图0 / 投影阴影关闭")
end

---@param parent Node
---@param name string
---@param shape string
---@param color string
---@param position Vector3
---@param size Vector3
---@param rotation? Quaternion
local function add(parent,name,shape,color,position,size,rotation)
    local model=assert(models[shape])
    local bounds=model.boundingBox
    local source=bounds.size
    local scale=V(size.x/source.x,size.y/source.y,size.z/source.z)
    local center=bounds.center
    local offset=V(center.x*scale.x,center.y*scale.y,center.z*scale.z)
    local node=P.Add(parent,name,model,assert(materials[color]),
        position-(rotation and rotation*offset or offset),scale,rotation,false)
    local draw=assert(node:GetComponent("StaticModel"))
    draw.drawDistance=210
    draw.shadowDistance=0
    return node
end

---@param parent Node
---@param key string
---@param name string
---@param scaleOverride? number
---@return Node?, Vector3?
function M.Add(parent,key,name,scaleOverride)
    prepare()
    local node=parent:CreateChild(name)
    local size=V(1,1,1)
    if key=="cone" then
        add(node,"锥体","cone","orange",V(0,.55,0),V(.9,.9,.9))
        add(node,"底座","box","dark",V(0,.05,0),V(1.1,.1,1.1))
        size=V(1.1,1,1.1)
    elseif key=="barrel" then
        add(node,"桶体","cylinder","orange",V(0,.55,0),V(1,1.1,1))
        add(node,"桶箍","cylinder","steel",V(0,.55,0),V(1.04,.12,1.04))
        size=V(1.04,1.1,1.04)
    elseif key=="crate" then
        add(node,"木箱","box","wood",V(0,.5,0),V(1.3,1,1.2))
        add(node,"束带","box","yellow",V(0,.5,0),V(.14,1.01,1.21))
        size=V(1.3,1.01,1.21)
    elseif key=="barrier" or key=="airbarrier" then
        size=key=="airbarrier" and V(2.6,1.684149,1.694326) or V(1.81,1.1,.46)
        add(node,"挡板","box","orange",V(0,size.y*.5,0),size)
        add(node,"警示带","box","yellow",V(0,size.y*.5,0),V(size.x+.01,.22,size.z+.01))
        size=V(size.x+.01,size.y,size.z+.01)
    elseif key=="support" then
        for _,side in ipairs({-1,1}) do
            add(node,"支柱","box","yellow",V(side*1.75,2.6,0),V(.16,5.2,.16))
        end
        add(node,"横梁","box","steel",V(0,5.2,0),V(3.66,.16,.16))
        size=V(3.66,5.28,.16)
    elseif key=="pendulum" then
        -- 挂点即局部原点；球和单根连杆随同一个节点旋转。
        add(node,"摆球","sphere","orange",V(0,-4.2,0),V(1.25,1.25,1.25))
        add(node,"连杆","box","steel",V(0,-1.7875,0),V(.08,3.575,.08))
        size=V(1.25,4.825,1.25)
    elseif key=="chain" then
        add(node,"悬杆","box","steel",V(0,.5,0),V(.08,1,.08))
        size=V(.08,1,.08)
    elseif key=="warning" then
        add(node,"警示柱","box","dark",V(0,.45,0),V(.08,.9,.08))
        add(node,"警示牌","box","yellow",V(0,.8,0),V(.65,.4,.06))
        size=V(.65,1,.08)
    elseif key=="coin" then
        add(node,"金币","cylinder","yellow",V(0,.3,0),V(.6,.1,.6),Quaternion(90,0,0))
        size=V(.6,.6,.1)
    else
        node:Dispose()
        error("未知轻量机关："..key)
    end
    if scaleOverride then node:SetScale(scaleOverride) end
    return node,size*(scaleOverride or 1)
end

---@param model Model
---@return boolean
function M.IsSharedModel(model)
    for _,shared in pairs(models) do if model==shared then return true end end
    return false
end
return M
