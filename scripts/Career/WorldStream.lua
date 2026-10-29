-- 基于三维场景脚手架的内容/资源所有权；不订阅事件、不建相机、不改原城。
-- 接线：New(city)；首屏/传送 Ensure(x,z,550)；每帧一次 Update(x,z)；切室内 SetVisible(false)。
-- 世界逻辑只来自WorldData；卸载只释放独立节点，不向city.details/obstacles/markers追加。
local World = require("Career.WorldData")
local Details = require("Career.CityDetails")
local Expansion = require("Career.CityExpansion")
local V = Vector3
---@class CareerWorldChunk
---@field root Node
---@field stats table
---@field ix number
---@field iz number
---@class CareerStreamCandidate
---@field ix number
---@field iz number
---@field distance number
---@class CareerWorldStream
---@field Ensure fun(self:CareerWorldStream,x:number,z:number,radius?:number):table
---@field Update fun(self:CareerWorldStream,x:number,z:number)
---@field SetVisible fun(self:CareerWorldStream,visible:boolean)
---@field Dispose fun(self:CareerWorldStream)
---@field plan CareerStreamCandidate[]
---@field planX number
---@field planZ number
---@field planBuilds number
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
-- 原外区每块最多10楼/16树；邻里补街墙硬限24楼/格，另计真实模型LOD0预算。
-- 程序几何仍限36k面；建筑/门面复用现有材质，最多约20个合批材质。
-- 真实模型复用3套资源，按256m视觉块卸载；Text3D只用于POI和沿街店招。
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
    self.planX,self.planZ=math.huge,math.huge
    self.plan,self.planBuilds={},0
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
    local materialResource=assert(d.mats[material],"WorldStream材质缺失 "..material)
    geom:SetMaterial(materialResource)
    geom.castShadows=material~="road" and material~="grass" and material~="yellow" and material~="paint"
    geom.shadowDistance,geom.drawDistance=85,450
    batch={geometry=geom,cx=cx,cz=cz,vertices=0}
    d.batches[material]=batch;d.meshCount=d.meshCount+1
    return batch
end
local function rect(d,s)
    d:Ground(s.material,(s.x1+s.x2)/2,(s.z1+s.z2)/2,s.x2-s.x1,s.z2-s.z1,s.y)
end

---@class CareerMarkRoad
---@field vertical boolean
---@field center number
---@field lo number
---@field hi number
---@field width number
---@field crossings table[]
---@class CareerMarkGroup
---@field vertical boolean
---@field center number
---@field roads table[]
---@field ends table<number, boolean>
---@type CareerMarkRoad[]
local markingRoads={}
-- 主干/支路同轴重叠时先切分取最大路宽，再合并连续段，避免重叠双黄线。
do
    ---@type table<string, CareerMarkGroup>
    local groups={}
    local allRoads={}
    for _,r in ipairs(World.Roads) do allRoads[#allRoads+1]=r end
    for _,r in ipairs(Expansion.Roads) do allRoads[#allRoads+1]=r end
    for _,r in ipairs(allRoads) do
        if not r.old then
            local vertical=r.x1==r.x2
            local center=vertical and r.x1 or r.z1
            local id=(vertical and "x" or "z")..center
            local g=groups[id] or {vertical=vertical,center=center,roads={},ends={}}
            local lo=vertical and math.min(r.z1,r.z2) or math.min(r.x1,r.x2)
            local hi=vertical and math.max(r.z1,r.z2) or math.max(r.x1,r.x2)
            g.roads[#g.roads+1]={lo=lo,hi=hi,width=r.width}
            g.ends[lo]=true;g.ends[hi]=true;groups[id]=g
        end
    end
    for _,g in pairs(groups) do
        ---@type number[]
        local ends={}
        for n in pairs(g.ends) do ends[#ends+1]=n end
        table.sort(ends)
        ---@type CareerMarkRoad?
        local previous=nil
        for i=2,#ends do
            local lo,hi=assert(ends[i-1]),assert(ends[i])
            local midpoint=(lo+hi)/2
            local width=0
            for _,r in ipairs(g.roads) do if midpoint>=r.lo and midpoint<=r.hi then width=math.max(width,r.width) end end
            if width>0 then
                if previous and previous.hi==lo and previous.width==width then previous.hi=hi
                else
                    previous={vertical=g.vertical,center=g.center,lo=lo,hi=hi,width=width,crossings={}}
                    markingRoads[#markingRoads+1]=previous
                end
            end
        end
    end
    for _,a in ipairs(markingRoads) do
        for _,b in ipairs(markingRoads) do
            if a.vertical~=b.vertical and b.center>=a.lo and b.center<=a.hi
                and a.center>=b.lo and a.center<=b.hi then
                a.crossings[#a.crossings+1]={along=b.center,half=b.width/2}
            end
        end
    end
end

---@param d CityDetails
---@param cell CareerWorldCell
---@return integer
local function roadMarkings(d,cell)
    local quads=0
    local seen={}
    -- 只画贴花Quad，不登记Surface；每块上限1200个四边形/2400面，复用paint/yellow批次。
    local function paint(material,x1,z1,x2,z2)
        x1,x2=math.max(x1,cell.x1),math.min(x2,cell.x2)
        z1,z2=math.max(z1,cell.z1),math.min(z2,cell.z2)
        if x1>=x2 or z1>=z2 or quads>=1200 then return end
        local pieces={}
        local limit=World.OLD_LIMIT
        if x1<limit and x2> -limit and z1<limit and z2> -limit then
            local l,r=math.max(x1,-limit),math.min(x2,limit)
            local bottom,top=math.max(z1,-limit),math.min(z2,limit)
            if x1<l then pieces[#pieces+1]={x1,z1,l,z2} end
            if r<x2 then pieces[#pieces+1]={r,z1,x2,z2} end
            if z1<bottom then pieces[#pieces+1]={l,z1,r,bottom} end
            if top<z2 then pieces[#pieces+1]={l,top,r,z2} end
        else pieces[1]={x1,z1,x2,z2} end
        for _,p in ipairs(pieces) do
            local id=material..table.concat(p,":")
            if not seen[id] and quads<1200 then
                seen[id]=true
                d:Quad(material,V(p[1],.073,p[2]),V(p[1],.073,p[4]),V(p[3],.073,p[2]),V(p[3],.073,p[4]))
                quads=quads+1
            end
        end
    end
    for _,r in ipairs(markingRoads) do
        local alongLo=r.vertical and cell.z1 or cell.x1
        local alongHi=r.vertical and cell.z2 or cell.x2
        local crossLo=r.vertical and cell.x1 or cell.z1
        local crossHi=r.vertical and cell.x2 or cell.z2
        local lo,hi=math.max(r.lo,alongLo),math.min(r.hi,alongHi)
        if lo<hi and r.center+r.width/2>=crossLo and r.center-r.width/2<=crossHi then
            local function strip(material,across,width,start,finish)
                if r.vertical then paint(material,r.center+across-width/2,start,r.center+across+width/2,finish)
                else paint(material,start,r.center+across-width/2,finish,r.center+across+width/2) end
            end
            -- 纵向线在路口+斑马线+停止线前断开；横穿步行带绝不被黄线贯穿。
            local function lane(material,across,width,start,finish)
                local intervals={{math.max(start,lo),math.min(finish,hi)}}
                for _,c in ipairs(r.crossings) do
                    local nextIntervals={}
                    local cutLo,cutHi=c.along-c.half-7,c.along+c.half+7
                    for _,p in ipairs(intervals) do
                        if p[2]<=cutLo or p[1]>=cutHi then nextIntervals[#nextIntervals+1]=p
                        else
                            if p[1]<cutLo then nextIntervals[#nextIntervals+1]={p[1],cutLo} end
                            if cutHi<p[2] then nextIntervals[#nextIntervals+1]={cutHi,p[2]} end
                        end
                    end
                    intervals=nextIntervals
                end
                for _,p in ipairs(intervals) do if p[1]<p[2] then strip(material,across,width,p[1],p[2]) end end
            end
            for _,side in ipairs({-1,1}) do lane("paint",side*(r.width/2-.35),.12,lo,hi) end
            if r.width>=16 then
                for _,side in ipairs({-1,1}) do lane("yellow",side*.14,.10,lo,hi) end
            else
                for n=math.floor(lo/8),math.floor(hi/8) do lane("yellow",0,.12,n*8,n*8+3.5) end
            end
            for _,c in ipairs(r.crossings) do
                for _,side in ipairs({-1,1}) do
                    local crosswalk=c.along+side*(c.half+2.8)
                    -- T形端点无出口的一侧不画悬空斑马线。
                    if crosswalk-1.5>=r.lo and crosswalk+1.5<=r.hi
                        and math.abs(crosswalk-(lo+hi)/2)<(hi-lo)/2+2 then
                        local stripes=math.floor((r.width-1.2)/1.0)
                        for n=1,stripes do
                            strip("paint",(n-(stripes+1)/2),.5,crosswalk-1.45,crosswalk+1.45)
                        end
                        local stop=c.along+side*(c.half+5.6)
                        if stop>=r.lo and stop<=r.hi then strip("paint",0,r.width-1.2,stop-.15,stop+.15) end
                    end
                end
            end
        end
    end
    return quads
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
local function detailedFront(d,b)
    local angle=math.rad(b.yaw)
    local cs,sn=math.cos(angle),math.sin(angle)
    local function p(x,y,z) return V(b.x+x*cs+z*sn,y,b.z-x*sn+z*cs) end
    local function box(mat,x,y,z,w,h,depth)
        local pos=p(x,y,z)
        d:Box(mat,pos.x,pos.y,pos.z,w,h,depth,b.yaw)
    end
    -- 模型原有贴图/屋顶保留；只加正面门厅幕墙，消除截图中的整面空白裙楼。
    -- 所有落地构件在原碰撞AABB的15cm基座余量内，不另放挡路台阶。
    local front=-b.d/2-.045
    box("stone",0,1.75,front,b.w-.8,3.35,.09)
    for _,side in ipairs({-1,1}) do
        box("metal",side*(b.w/2-.8),1.8,front-.06,.24,3.5,.10)
        box("frame",side*7,1.48,front-.055,7.5,2.55,.05)
        box("glass",side*7,1.48,front-.09,7.15,2.25,.025)
        box("trim",side*7,2.68,front-.11,7.4,.09,.04)
        box("metal",side*7,1.48,front-.115,.07,2.3,.04)
    end
    box("frame",0,1.42,front-.055,3.4,2.8,.06)
    box("glass",0,1.42,front-.095,3.05,2.6,.025)
    box("metal",0,1.42,front-.115,.10,2.65,.04)
    for _,side in ipairs({-1,1}) do box("lamp",side*.27,1.40,front-.135,.055,.5,.025) end
    box("metal",0,3.55,front-.06,b.w-.5,.78,.12)
    box("trim",0,4.06,front+.10,b.w+.25,.18,.55)
    -- 上层采用真实窗洞组件：凹框、窗台、分格玻璃，不把楼顶/背面重做为方盒。
    for floor=2,math.min(5,b.floors) do
        for col=1,4 do
            local x=(col-2.5)*(b.w-5)/4
            local pos=p(x,floor*3.05-1.1,front)
            d:Window(pos.x,pos.y,pos.z,b.yaw,1.75,1.8,(floor+col)%5==0)
        end
    end
    local entrance=p(0,2.95,front-.16)
    d:Sign("门厅接餐 · 请在入口等候",entrance.x,entrance.y,entrance.z,b.yaw,.24)
end
-- 邻里门面收在实测地基以内，使用现有砖/金属贴图和分格玻璃。
-- 保留真实楼体比例，不叠加巨大统一空白裙楼。
local function expansionFront(d,b)
    local a=math.rad(b.yaw)
    local function p(x,y,z) return V(b.x+x*math.cos(a)+z*math.sin(a),y,b.z-x*math.sin(a)+z*math.cos(a)) end
    local front=-b.d/2+.10
    local function box(mat,x,y,z,w,h,depth)
        local v=p(x,y,z);d:Box(mat,v.x,v.y,v.z,w,h,depth,b.yaw)
    end
    local signMaterials={"street_teal","street_red","street_steel"}
    if b.shop then
        local bay=(b.w-1.2)/3
        box("street_brick",0,1.65,front+.12,b.w-.15,3.12,.20)
        for i=-1,1 do
            local x=i*bay
            box("frame",x,1.48,front+.005,bay-.22,2.58,.10)
            box("glass",x,1.48,front-.015,bay-.40,2.37,.035)
            box("street_steel",x,1.48,front-.04,.045,2.37,.03)
            box("street_steel",x,.55,front-.04,bay-.40,.055,.03)
        end
        box(signMaterials[(math.floor(b.x+b.z)%3)+1],0,3.12,front-.07,b.w-.20,.62,.10)
        box("street_steel",0,3.50,front-.35,b.w-.05,.12,.9)
        local sign=p(0,3.12,front-.13)
        d:Sign(b.name,sign.x,sign.y,sign.z,b.yaw,.32)
        -- 底层服务细节不超出可见实体地基。
        box("street_steel",b.w/2-.42,1.55,front-.03,.40,.62,.08)
        for i=1,5 do box("frame",b.w/2-.42,1.32+i*.075,front-.08,.31,.018,.02) end
    else
        box("street_brick",0,1.42,front+.06,3.0,2.60,.12)
        box("frame",0,1.30,front-.025,1.85,2.44,.055)
        box("glass",0,1.30,front-.060,1.61,2.28,.02)
        box("street_steel",0,1.3,front-.08,.05,2.28,.03)
        box("street_steel",0,2.78,front-.3,3.5,.12,.8)
    end
    if b.infill then
        -- 真实楼体侧/背面加窗、空调格栅、门边窄柜，不沿街展示整排裸山墙。
        -- 低处细节全留在已有实体基座内；雨篷在2.7m以上，无新增地面障碍。
        for _,side in ipairs({-1,1}) do
            for floor=2,math.min(4,b.floors) do
                local y=math.min(b.h-1.3,floor*2.7-1.1)
                for col=-1,1 do
                    local z=col*b.d*.25
                    box("street_brick",side*(b.w/2+.005),y,z,.08,1.52,1.32)
                    box("glass",side*(b.w/2+.055),y,z,.025,1.25,1.07)
                    box("street_steel",side*(b.w/2+.075),y,z,.025,1.25,.045)
                end
            end
        end
        for col=-1,1 do
            box("street_brick",col*b.w*.27,1.5,b.d/2-.03,1.65,2.5,.12)
            box("glass",col*b.w*.27,1.5,b.d/2+.04,1.4,2.2,.03)
        end
        if b.shop then
            box("street_steel",b.w*.32,.54,front+.08,.64,.9,.14)
            for i=1,4 do box("street_wood",b.w*.32,.24+i*.17,front-.01,.59,.045,.035) end
            box("street_teal",-b.w*.33,1.1,front+.03,.52,1.5,.10)
        end
    end
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
            if b.expansion then
                assert(math.abs(sx-sy)<.00001 and math.abs(sy-sz)<.00001,"neighbourhood model proportions changed")
                ---@type number[]
                local measured=Expansion.Models[b.asset].size
                assert(math.abs(bounds.size.x-measured[1])<.000001
                    and math.abs(bounds.size.y-measured[2])<.000001
                    and math.abs(bounds.size.z-measured[3])<.000001,"neighbourhood MDL bounds replaced")
            end
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
    if detailed then
        if b.expansion then expansionFront(d,b) else detailedFront(d,b) end
    end
    if not detailed then
        d:Box(b.style,b.x,b.h/2+.085,b.z,b.w,b.h,b.d,b.yaw)
        facade(d,b)
        d:Box("trim",b.x,b.h+.18,b.z,b.w+.4,.22,b.d+.4,b.yaw)
        d:Box("recess",b.x,b.h+.31,b.z,b.w-.7,.16,b.d-.7,b.yaw)
        d:Box("metal",b.x+b.w*.2,b.h+.75,b.z+b.d*.2,2,1.0,1.4,b.yaw)
    end
    local lip=b.expansion and .1 or .3
    d:Box("concrete",b.x,b.expansion and .0 or .18,b.z,b.w+lip,b.expansion and .24 or .4,b.d+lip,b.yaw)
    if not b.expansion and (b.asset or b.floors<=3) then
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
        local markingQuads=roadMarkings(d,data)
        local models,modelTriangles,expansionModels=0,0,0
        for _,b in ipairs(data.buildings) do
            if self:Building(d,root,b) then
                models=models+1
                modelTriangles=modelTriangles+Expansion.Models[b.asset].triangles
                if b.expansion then expansionModels=expansionModels+1 end
            end
        end
        if expansionModels>0 then
            assert(expansionModels<=24 and modelTriangles<=200000,"邻里块真实模型预算超限")
        end
        for _,t in ipairs(data.trees) do tree(d,t) end
        for _,p in ipairs(data.props) do
            if p.kind=="bench" then d:Bench(p.x,p.z,0)
            elseif p.kind=="tree" then
                -- 1.8m可见树池与碰撞同尺寸，树干/树冠合批并投近景阴影。
                d:Box("concrete",p.x,.30,p.z,p.w,.60,p.d)
                d:Box("recess",p.x,.606,p.z,p.w-.20,.025,p.d-.20)
                d:Box("wood",p.x,2.05,p.z,.26,3.0,.26)
                for _,c in ipairs({{-.65,3.6,0,1.15,.9,1.05},{.60,4.2,.25,1.25,1.0,1.15},{0,4.9,-.3,1.0,.8,1.05}}) do
                    -- 合批椭球树冠，避免以方盒假装绿化；每层80面，无额外节点。
                    for row=0,4 do for sector=0,7 do
                        local function point(v,u)
                            local phi=-math.pi/2+v*math.pi/5
                            local theta=u*math.pi/4
                            return V(p.x+c[1]+c[4]*math.cos(phi)*math.cos(theta),c[2]+c[5]*math.sin(phi),
                                p.z+c[3]+c[6]*math.cos(phi)*math.sin(theta))
                        end
                        d:Quad("foliage",point(row,sector),point(row+1,sector),point(row,sector+1),point(row+1,sector+1))
                    end end
                end
                d.trees=d.trees+1
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
        stats.modelTriangles,stats.expansionModels=modelTriangles,expansionModels
        stats.markingQuads=markingQuads
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
---@param x number
---@param z number
---@param radius number
---@return CareerStreamCandidate[]
local function wanted(x,z,radius)
    ---@type CareerStreamCandidate[]
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
-- 32m格内复用候选表；多取半格对角线覆盖量，再按实时距离过滤，边界不漏块。
-- 静止和低速骑行不再每帧构造/排序几十个table，仍严格按550m半径加载。
function Stream:Candidates(x,z)
    local gx,gz=math.floor(x/32),math.floor(z/32)
    if gx~=self.planX or gz~=self.planZ then
        self.planX,self.planZ=gx,gz
        self.plan=wanted(gx*32+16,gz*32+16,550+math.sqrt(2)*16)
        self.planBuilds=self.planBuilds+1
    end
    return self.plan
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
    for _,c in ipairs(self:Candidates(x,z)) do
        if cellDistance(c.ix,c.iz,x,z)<=550 and not self.chunks[key(c.ix,c.iz)] then
            self:Load(c.ix,c.iz);return
        end
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
        batches=0,triangles=0,buildings=0,models=0,modelTriangles=0,maxCellModelTriangles=0,expansionModels=0,
        obstacles=0,signs=0,trees=0,markingQuads=0,
        cellSize=256,viewDistance=450,loadDistance=550,unloadDistance=850,maxActive=Stream.MAX_ACTIVE,
        visible=self.visible,disposed=self.disposed,pending=0,planBuilds=self.planBuilds,candidates=#self.plan}
    for _,c in pairs(self.chunks) do
        result.active=result.active+1
        result.maxCellModelTriangles=math.max(result.maxCellModelTriangles,c.stats.modelTriangles or 0)
        for _,field in ipairs({"batches","triangles","buildings","models","modelTriangles","expansionModels","obstacles","signs","trees","markingQuads"}) do
            result[field]=result[field]+(c.stats[field] or 0)
        end
    end
    if not self.disposed then
        for _,c in ipairs(self:Candidates(self.x,self.z)) do
            if cellDistance(c.ix,c.iz,self.x,self.z)<=550 and not self.chunks[key(c.ix,c.iz)] then
                result.pending=result.pending+1
            end
        end
        result.planBuilds,result.candidates=self.planBuilds,#self.plan
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
    self.plan={}
    self.models={};self.disposed=true;self.visible=false
end
return Stream
