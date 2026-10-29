-- 基于三维场景脚手架的内容/资源所有权；不订阅事件、不建相机、不改原城。
-- 接线：New(city)；首屏/传送 Ensure(x,z,550)；每帧一次 Update(x,z)；切室内 SetVisible(false)。
-- 世界逻辑只来自WorldData；卸载只释放独立节点，不向city.details/obstacles/markers追加。
local World = require("Career.WorldData")
local Details = require("Career.CityDetails")
local V = Vector3
---@class CareerWorldChunk
---@field root Node
---@field stats table
---@field ix number
---@field iz number
---@class CareerWorldStream
---@field root Node
---@field mats table<string, Material>
---@field chunks table<string, CareerWorldChunk>
---@field models table[]
---@field visible boolean
---@field disposed boolean
---@field loaded number
---@field unloaded number
---@field failed number
---@field x number
---@field z number
local Stream = {}
Stream.__index = Stream
Stream.CELL,Stream.LOAD_DISTANCE,Stream.UNLOAD_DISTANCE,Stream.VIEW_DISTANCE = 256,550,850,450
Stream.MAX_ACTIVE=80
-- 每块最多10楼/16树，程序几何预算36k面，最多14个合并材质批次。
-- 真实模型每特色区复用1栋，资源只加载一次；Text3D只用于固定POI与少数店招。
Stream.MAX_TRIANGLES=36000
local architecture={
    {root="model/e799bc6c-0cef-5148-978f-9a41183cc268/",stem="c531d52ef7284ea8ae32f415bfe4b98e",material="c531d52ef7284ea8ae32f415bfe4b98e_00_tripo_material_55e20983-baca-4902-adac-b025ebed4e62.xml"},
    {root="model/62f2b98b-631d-5438-94ed-5ed78d3984b0/",stem="94b007f45c784751825b3e1b8e1e624a",material="94b007f45c784751825b3e1b8e1e624a_00_tripo_material_4516bc36-b2c8-41bf-8f41-8eed1211e086.xml"},
    {root="model/ea4b7cae-42e1-5651-8edf-6ccadbbd2046/",stem="863a459ef93647c88fe260263a9b2a1d",material="863a459ef93647c88fe260263a9b2a1d_00_tripo_material_6416e276-d70d-40dd-8b35-835c0187af3e.xml"},
}
Stream.Resources,Stream.ResourceTypes={},{}
for _,a in ipairs(architecture) do
    for p,t in pairs({[a.root.."Meshes/"..a.stem..".mdl"]="Model",[a.root.."Materials/"..a.material]="Material",
        [a.root.."Textures/"..a.stem.."_00_D.jpg"]="Texture2D",[a.root.."Textures/"..a.stem.."_00_N.jpg"]="Texture2D"}) do
        Stream.Resources[#Stream.Resources+1]=p;Stream.ResourceTypes[p]=t
    end
end
local function key(ix,iz) return ix..":"..iz end
local function cellDistance(ix,iz,x,z)
    local dx=math.max(ix*256-x,0,x-(ix+1)*256)
    local dz=math.max(iz*256-z,0,z-(iz+1)*256)
    return math.sqrt(dx*dx+dz*dz)
end
---@param city CareerCity
---@return CareerWorldStream
function Stream.New(city)
    local self=setmetatable({},Stream)
    self:Init(city)
    return self
end
---@param city CareerCity
function Stream:Init(city)
    assert(city.root and city.mats,"WorldStream需要已经初始化的City")
    -- 独立场景子树：原城SetEnabledRecursive不能把已隐藏的流式块复活。
    self.root=city.root.parent:CreateChild("CareerWorldStream")
    self.mats=city.mats
    self.chunks,self.models={},{ }
    self.visible,self.disposed=true,false
    self.loaded,self.unloaded,self.failed=0,0,0
    self.x,self.z=0,0
    for _,a in ipairs(architecture) do
        local model=cache:GetResource("Model",a.root.."Meshes/"..a.stem..".mdl")
        local source=cache:GetResource("Material",a.root.."Materials/"..a.material)
        if model and source then
            local mat=source:Clone()
            mat:SetTexture(TU_DIFFUSE,cache:GetResource("Texture2D",a.root.."Textures/"..a.stem.."_00_D.jpg"))
            mat:SetTexture(TU_NORMAL,cache:GetResource("Texture2D",a.root.."Textures/"..a.stem.."_00_N.jpg"))
            mat:SetShaderParameter("Metallic",Variant(0));mat:SetShaderParameter("Roughness",Variant(.88))
            self.models[#self.models+1]={model=model,material=mat}
        else
            print("[WorldStream] 错误：建筑资源缺失 "..a.root)
            self.models[#self.models+1]={}
        end
    end
end

-- 仍用独立Details.New/Finish，但将48m细分批次替换为本块每材质一个批次。
-- 不跨块共享CustomGeometry，所以Dispose不会留下另一块持有的顶点/Surface记录。
---@param d CityDetails
---@param material string
---@param _x number
---@param _z number
---@return CityBatch
local function cellBatch(d,material,_x,_z)
    local batch=d.batches[material]
    if batch then return batch end
    local cx,cz=d.root.position.x,d.root.position.z
    local node=d.root:CreateChild("WorldMaterial_"..material)
    -- root位于世界原点；批次局部原点固定为cell中心以降低大坐标精度损失。
    local ix,iz=d.root:GetVar("CellX"):GetInt(),d.root:GetVar("CellZ"):GetInt()
    cx,cz=ix*256+128,iz*256+128
    node.position=V(cx,0,cz)
    local geom=node:CreateComponent("CustomGeometry")
    geom:BeginGeometry(0,TRIANGLE_LIST)
    geom:SetMaterial(assert(d.mats[material],"WorldStream材质缺失 "..material))
    geom.castShadows=material~="road" and material~="grass" and material~="yellow" and material~="paint"
    geom.shadowDistance,geom.drawDistance=85,450
    batch={geometry=geom,cx=cx,cz=cz,vertices=0}
    d.batches[material]=batch;d.meshCount=d.meshCount+1
    return batch
end
local function rect(d,s)
    d:Ground(s.material,(s.x1+s.x2)/2,(s.z1+s.z2)/2,s.x2-s.x1,s.z2-s.z1,s.y)
end
local function facade(d,b)
    local angle=math.rad(b.yaw)
    local cs,sn=math.cos(angle),math.sin(angle)
    local function p(x,y,z) return V(b.x+x*cs+z*sn,y,b.z-x*sn+z*cs) end
    local function quad(mat,x1,y1,x2,y2,z)
        d:Quad(mat,p(x1,y1,z),p(x1,y2,z),p(x2,y1,z),p(x2,y2,z))
    end
    -- 侧/背墙也有窗；窗洞边框、金属竖梃与连续窗台几何，不用纯色整面假楼。
    for _,side in ipairs({-1,1}) do
        local z=side*(b.d/2+.06)
        for floor=1,math.min(6,b.floors) do
            local y=floor*3.05-1.1
            for col=1,3 do
                local x=(col-2)*b.w*.25
                if side<0 then
                    quad("trim",x-1.04,y-.9,x+1.04,y+.9,z-.01)
                    quad((floor+col)%5==0 and "windowWarm" or "glass",x-.9,y-.76,x+.9,y+.76,z-.03)
                    quad("frame",x-.035,y-.76,x+.035,y+.76,z-.05)
                else
                    -- 背面面向+Z：交换左右以保持绕序正确。
                    quad("trim",x+1.04,y-.9,x-1.04,y+.9,z+.01)
                    quad("glass",x+.9,y-.76,x-.9,y+.76,z+.03)
                end
            end
            d:Box("trim",b.x,y-1.04,b.z+side*(b.d/2+.11),b.w+.12,.13,.26,b.yaw)
        end
    end
    local door=p(0,1.35,-b.d/2-.14)
    d:Box("frame",door.x,door.y,door.z,2.5,2.65,.18,b.yaw)
    local glass=p(0,1.35,-b.d/2-.25)
    d:Box("glass",glass.x,glass.y,glass.z,2.15,2.4,.04,b.yaw)
    local canopy=p(0,3.2,-b.d/2-.65)
    d:Box("metal",canopy.x,3.2,canopy.z,math.min(b.w-2,13),.3,1.4,b.yaw)
end
---@param d CityDetails
---@param root Node
---@param b table
---@return boolean
function Stream:Building(d,root,b)
    local detailed=false
    if b.asset then
        local asset=self.models[b.asset]
        if asset and asset.model then
            ---@type Model
            local model=asset.model
            local bounds=model.boundingBox
            -- 精确包围盒填满同一描述中的预留AABB；碰撞不依赖模型是否已下载/显示。
            local sx,sy,sz=b.w/bounds.size.x,b.h/bounds.size.y,b.d/bounds.size.z
            local holder=root:CreateChild(b.id)
            holder.position=V(b.x,.085,b.z);holder.rotation=Quaternion(0,b.yaw,0)
            local mesh=holder:CreateChild("复用写实建筑")
            mesh.scale=V(sx,sy,sz)
            mesh.position=V(-bounds.center.x*sx,-bounds.min.y*sy,-bounds.center.z*sz)
            local draw=mesh:CreateComponent("StaticModel")
            draw.model=model;draw.material=asset.material
            draw.castShadows=true;draw.drawDistance=450;draw.shadowDistance=85
            detailed=true
        end
    end
    if not detailed then
        d:Box(b.style,b.x,b.h/2+.085,b.z,b.w,b.h,b.d,b.yaw)
        facade(d,b)
        d:Box("trim",b.x,b.h+.18,b.z,b.w+.4,.22,b.d+.4,b.yaw)
        d:Box("recess",b.x,b.h+.31,b.z,b.w-.7,.16,b.d-.7,b.yaw)
        d:Box("metal",b.x+b.w*.2,b.h+.75,b.z+b.d*.2,2,1.0,1.4,b.yaw)
    end
    d:Box("concrete",b.x,.18,b.z,b.w+.3,.4,b.d+.3,b.yaw)
    if b.asset or b.floors<=3 then
        local a=math.rad(b.yaw)
        local x,z=b.x-math.sin(a)*(b.d/2+.4),b.z-math.cos(a)*(b.d/2+.4)
        d:Sign(b.name,x,3.35,z,b.yaw,.4)
    end
    return detailed
end
local function tree(d,t)
    d:Box("wood",t.x,t.h*.38,t.z,.48,t.h*.76,.48)
    local top,bottom=V(t.x,t.h+1,t.z),V(t.x,t.h*.43,t.z)
    local ring={V(t.x-t.r,t.h*.72,t.z),V(t.x,t.h*.72,t.z+t.r),
        V(t.x+t.r,t.h*.72,t.z),V(t.x,t.h*.72,t.z-t.r)}
    for i=1,4 do
        local a,b=ring[i],ring[i%4+1]
        d:Quad("foliage",top,a,b,bottom)
    end
    d.trees=d.trees+1
end
local function bridge(d,b)
    -- 真实桥面、支柱、楔形坡面与WorldData高度完全同源；道路下部不加横墙。
    d:Box("concrete",b.x,b.y-.2,b.z,44,.4,4)
    for _,side in ipairs({-1,1}) do
        d:Box("concrete",b.x+side*14,(b.y-.4)/2,b.z,1.2,b.y-.4,1.2)
        local x=b.x+side*20
        local z0,z1=b.z-64,b.z-2
        local lo,hi=.085,b.y
        d:Quad("concrete",V(x-2,lo,z0),V(x-2,hi,z1),V(x+2,lo,z0),V(x+2,hi,z1))
        d:Quad("concrete",V(x-2,0,z0),V(x-2,0,z1),V(x-2,lo,z0),V(x-2,hi,z1))
        d:Quad("concrete",V(x+2,lo,z0),V(x+2,hi,z1),V(x+2,0,z0),V(x+2,0,z1))
        -- 坡道两侧护栏采用斜向Quad，无新增模型/物理域。
        for _,edge in ipairs({-1,1}) do
            local rx=x+edge*2
            d:Quad("metal",V(rx,lo+.5,z0),V(rx,hi+.5,z1),V(rx+.06,lo+1.15,z0),V(rx+.06,hi+1.15,z1))
            d:Quad("metal",V(rx+.06,lo+1.15,z0),V(rx+.06,hi+1.15,z1),V(rx,lo+.5,z0),V(rx,hi+.5,z1))
            d:Box("metal",rx,.65,z0,.12,1.3,.12)
        end
        -- 车禁护桩在入口侧边，行人仍有3.2m净通道；车辆禁行由WorldData处理。
        d:Sign("步行天桥 · 车辆止步",x,1.8,z0-1,0,.3)
    end
    d:Box("metal",b.x,b.y+.9,b.z+2,44,.65,.10)
    -- 南侧留两个坡道入口；中间横栏不切断坡顶。
    d:Box("metal",b.x,b.y+.9,b.z-2,36,.65,.10)
    for _,side in ipairs({-1,1}) do d:Box("metal",b.x+side*22,b.y+.9,b.z,.10,.65,4) end
end

---@param ix number
---@param iz number
---@return boolean
function Stream:Load(ix,iz)
    local k=key(ix,iz)
    if self.chunks[k] or self.disposed then return false end
    local data=World.DescribeCell(ix,iz)
    if data.x1>=data.x2 or data.z1>=data.z2 then return false end
    local root=self.root:CreateChild("World256_"..k)
    root:SetVar("CellX",Variant(ix));root:SetVar("CellZ",Variant(iz))
    local ok,result=pcall(function()
        local d=Details.New(root,self.mats)
        -- 实例冒号方法覆盖保留显式self；LSP的method赋值签名漏计self，运行调用正确。
        ---@diagnostic disable-next-line: assign-type-mismatch
        d.Batch=cellBatch
        for _,s in ipairs(data.grounds) do rect(d,s) end
        local models=0
        for _,b in ipairs(data.buildings) do if self:Building(d,root,b) then models=models+1 end end
        for _,t in ipairs(data.trees) do tree(d,t) end
        for _,p in ipairs(data.props) do
            if p.kind=="bench" then d:Bench(p.x,p.z,0)
            else
                d:Box("metal",p.x,p.h/2,p.z,p.w,p.h,p.d)
                d:Box("lamp",p.x,1.1,p.z-.36,.4,.35,.04)
            end
        end
        for _,b in ipairs(data.bridges) do bridge(d,b) end
        for _,p in ipairs(data.points) do
            d:Ground(p.kind=="rest" and "paint" or "yellow",p.x,p.z,1.5,1.5,.09)
            d:Sign(p.label,p.x,2.4,p.z,0,.35)
        end
        local stats=d:Finish()
        stats.buildings,stats.models,stats.obstacles=#data.buildings,models,#data.obstacles
        assert(stats.triangles<=Stream.MAX_TRIANGLES,"单块三角面预算超限")
        -- 释放Details持有的临时程序圆柱；本流式块未使用Bar/Lamp。
        if d.shapes.cylinder then d.shapes.cylinder:Dispose() end
        d.shapes={}
        return stats
    end)
    if not ok then
        root:Dispose();self.failed=self.failed+1
        print("[WorldStream] 错误：块"..k.." "..tostring(result))
        return false
    end
    self.chunks[k]={root=root,stats=result,ix=ix,iz=iz}
    root:SetEnabledRecursive(self.visible)
    self.loaded=self.loaded+1
    print(string.format("[WorldStream] 加载 %s / %d楼 / %.0f面 / %d批",k,result.buildings,result.triangles,result.batches))
    return true
end
function Stream:Unload(k)
    local chunk=self.chunks[k]
    if not chunk then return end
    chunk.root:Dispose();self.chunks[k]=nil
    self.unloaded=self.unloaded+1
    print("[WorldStream] 卸载 "..k)
end
local function wanted(x,z,radius)
    local list={}
    for ix=math.floor((x-radius)/256),math.floor((x+radius)/256) do
        for iz=math.floor((z-radius)/256),math.floor((z+radius)/256) do
            local dist=cellDistance(ix,iz,x,z)
            if dist<=radius and (ix+1)*256> -15000 and ix*256<15000 and (iz+1)*256> -15000 and iz*256<15000 then
                list[#list+1]={ix=ix,iz=iz,distance=dist}
            end
        end
    end
    table.sort(list,function(a,b)
        if a.distance==b.distance then return key(a.ix,a.iz)<key(b.ix,b.iz) end
        return a.distance<b.distance
    end)
    return list
end
---@param x number
---@param z number
function Stream:Update(x,z)
    if self.disposed or not self.visible then return end
    self.x,self.z=x,z
    -- 一次Update最多一个块事务；先卸离开850m的最远块，防传送后旧块累积。
    local farKey,farDistance="",850
    local count=0
    for k,c in pairs(self.chunks) do
        count=count+1
        local dist=cellDistance(c.ix,c.iz,x,z)
        if dist>farDistance then farKey,farDistance=k,dist end
    end
    if farKey~="" then self:Unload(farKey);return end
    if count>=Stream.MAX_ACTIVE then return end
    for _,c in ipairs(wanted(x,z,550)) do
        if not self.chunks[key(c.ix,c.iz)] then self:Load(c.ix,c.iz);return end
    end
end
---@param x number
---@param z number
---@param radius? number 同步首屏半径；默认300，传550可完整预热视距
---@return table
function Stream:Ensure(x,z,radius)
    if self.disposed then return self:Stats() end
    self.x,self.z=x,z
    -- 首屏/传送是显式同步例外；不需要移动角色就能先获得空块地面。
    local stale={}
    for k,c in pairs(self.chunks) do if cellDistance(c.ix,c.iz,x,z)>850 then stale[#stale+1]=k end end
    for _,k in ipairs(stale) do self:Unload(k) end
    for _,c in ipairs(wanted(x,z,math.min(550,math.max(0,radius or 300)))) do self:Load(c.ix,c.iz) end
    return self:Stats()
end
---@param visible boolean
function Stream:SetVisible(visible)
    if self.disposed then return end
    self.visible=visible
    self.root:SetEnabledRecursive(visible)
end
---@return table
function Stream:Stats()
    local result={active=0,loaded=self.loaded,unloaded=self.unloaded,failed=self.failed,
        batches=0,triangles=0,buildings=0,models=0,obstacles=0,signs=0,trees=0,
        cellSize=256,viewDistance=450,loadDistance=550,unloadDistance=850,maxActive=Stream.MAX_ACTIVE,
        visible=self.visible,disposed=self.disposed,pending=0}
    for _,c in pairs(self.chunks) do
        result.active=result.active+1
        for _,field in ipairs({"batches","triangles","buildings","models","obstacles","signs","trees"}) do
            result[field]=result[field]+(c.stats[field] or 0)
        end
    end
    if not self.disposed then
        for _,c in ipairs(wanted(self.x,self.z,550)) do if not self.chunks[key(c.ix,c.iz)] then result.pending=result.pending+1 end end
    end
    result.cells=result.active
    return result
end
function Stream:Dispose()
    if self.disposed then return end
    local keys={}
    for k in pairs(self.chunks) do keys[#keys+1]=k end
    for _,k in ipairs(keys) do self:Unload(k) end
    self.root:Dispose()
    for _,a in ipairs(self.models) do if a.material then a.material:Dispose() end end
    self.models={};self.disposed=true;self.visible=false
end
return Stream
