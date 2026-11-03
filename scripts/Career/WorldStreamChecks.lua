-- 纯隔离回归，不接线main/Checks/Session，不创建引擎对象、不读写玩家状态。
-- 引擎调用：require("Career.WorldStreamChecks").Run()
-- 标准Lua调用：Run(function(path) ...返回scripts/下path源码... end)。只加载真实源码到私有_ENV。
local Checks = {}

---@param path string
---@return string
local function readResource(path)
    local file=assert(cache:GetFile(path),"[WorldStreamChecks] missing source "..path)
    local ok,source=pcall(function()
        local lines={}
        while not file:IsEof() do lines[#lines+1]=file:ReadLine() end
        return table.concat(lines,"\n")
    end)
    file:Dispose()
    assert(ok,tostring(source))
    return source
end

-- 只模拟本次真实源码使用的值类型运算，不给测试环境透传_G/引擎单例。
local function vectorFactory()
    ---@type any
    local methods={}
    ---@type any
    local mt={__index=methods}
    local function vector(x,y,z) return setmetatable({x=x,y=y,z=z},mt) end
    mt.__add=function(a,b) return vector(a.x+b.x,a.y+b.y,a.z+b.z) end
    mt.__sub=function(a,b) return vector(a.x-b.x,a.y-b.y,a.z-b.z) end
    mt.__mul=function(a,b)
        if type(a)=="number" then return vector(a*b.x,a*b.y,a*b.z) end
        return vector(a.x*b,a.y*b,a.z*b)
    end
    function methods:CrossProduct(b)
        return vector(self.y*b.z-self.z*b.y,self.z*b.x-self.x*b.z,self.x*b.y-self.y*b.x)
    end
    function methods:LengthSquared() return self.x*self.x+self.y*self.y+self.z*self.z end
    function methods:Length() return math.sqrt(self:LengthSquared()) end
    function methods:Normalized()
        local length=self:Length()
        if length==0 then return vector(0,0,0) end
        return vector(self.x/length,self.y/length,self.z/length)
    end
    return vector
end

---@param source string
---@param path string
---@param environment table
---@return any
local function isolated(source,path,environment)
    local chunk,failure=load(source,"@"..path.." (isolated)","t",environment)
    assert(chunk,tostring(failure))
    return chunk()
end

---@param readSource? fun(path:string):string 源路径为Career/WorldStream.lua、Career/CityDetails.lua
---@return table
function Checks.Run(readSource)
    local read=readSource or readResource
    local streamSource,detailsSource=read("Career/WorldStream.lua"),read("Career/CityDetails.lua")
    local result={passed=false,assertions=0,groups={},triangles=0,degenerate=0,zeroNormals=0,badUVs=0}
    local function check(ok,message)
        assert(ok,"[WorldStreamChecks] "..message)
        result.assertions=result.assertions+1
    end
    local function group(name) result.groups[#result.groups+1]=name end
    local vector=vectorFactory()

    -- 每组独立模块/根节点/资源缓存；故障由描述、节点、材质或切线提交注入，非替换Load。
    local function fixture()
        ---@type any
        local state={faults={},describes=0,allocations=0,disposals=0,cylinders=0,geometries={},trees=false}
        ---@type any
        local env={assert=assert,error=error,ipairs=ipairs,pairs=pairs,math=math,table=table,
            tostring=tostring,type=type,setmetatable=setmetatable,pcall=pcall,string=string,coroutine=coroutine,
            os={clock=function() return 0 end},
            print=function() end,Vector3=vector,Vector2=function(x,y) return {x=x,y=y} end,
            TRIANGLE_LIST="triangles",TU_DIFFUSE="diffuse",TU_NORMAL="normal",Variant=function(v) return v end,
            Quaternion=function() return {} end}
        env.Vector3=setmetatable({UP=vector(0,1,0)},{__call=function(_,x,y,z) return vector(x,y,z) end})
        local function fault(node)
            local current=node
            while current do
                if current.cell then return state.faults[current.cell] end
                current=current.parent
            end
        end
        local function geometry(node)
            ---@type any
            local g={positions={},normals={},uvs={},node=node}
            function g:BeginGeometry() end
            function g:SetMaterial() end
            function g:DefineVertex(p) self.positions[#self.positions+1]=p end
            function g:DefineNormal(n) self.normals[#self.normals+1]=n end
            function g:DefineTexCoord(uv) self.uvs[#self.uvs+1]=uv end
            function g:GenerateTangents() return fault(node)~="tangents" end
            function g:Commit()
                if node.name:match("^WorldMaterial_") then
                    check(node.visible==false,"流式几何Commit前暴露给渲染器")
                end
                self.committed=true
            end
            state.geometries[#state.geometries+1]=g
            return g
        end
        ---@type any
        local makeNode
        makeNode=function(parent,name)
            ---@type any
            local n={parent=parent,name=name,children={},position=vector(0,0,0),vars={},disposed=false,visible=true}
            n.cell=name:match("^World256_(.+)$")
            function n:CreateChild(childName)
                local cell=childName:match("^World256_(.+)$")
                if cell and state.faults[cell]=="node" then error("injected node failure") end
                local child=makeNode(self,childName)
                self.children[#self.children+1]=child
                if cell then state.allocations=state.allocations+1 end
                return child
            end
            function n:SetVar(k,v) self.vars[k]=v end
            function n:GetVar(k) return {GetInt=function() return self.vars[k] end} end
            function n:CreateComponent(kind)
                if kind=="CustomGeometry" then return geometry(self) end
                return {}
            end
            -- 渲染组件只检查直接所属节点；新子节点默认启用，不继承祖先状态。
            function n:SetEnabled(visible) self.visible=visible end
            function n:SetDeepEnabled(visible)
                self.visible=visible
                for _,child in ipairs(self.children) do child:SetDeepEnabled(visible) end
            end
            function n:SetEnabledRecursive(visible) self:SetDeepEnabled(visible) end
            function n:Dispose()
                check(not self.disposed,"node double dispose")
                self.disposed=true
                if self.cell then state.disposals=state.disposals+1 end
                for _,child in ipairs(self.children) do if not child.disposed then child:Dispose() end end
            end
            return n
        end
        env.cache={GetResource=function(_,kind)
            if kind=="Font" then return {} end
            -- 不下载真实建筑模型，真实Load使用已存在的程序几何路径。
            return nil
        end}
        env.CylinderGeometry=function()
            state.cylinders=state.cylinders+1
            return {ToModel=function() return {Dispose=function() end} end}
        end
        local world={Roads={},OLD_LIMIT=195}
        function world.DescribeCell(ix,iz)
            state.describes=state.describes+1
            local id=ix..":"..iz
            if state.faults[id]=="describe" then error("injected descriptor failure") end
            return {x1=ix*256,x2=(ix+1)*256,z1=iz*256,z2=(iz+1)*256,
                grounds={{material=state.faults[id]=="material" and "missing" or "grass",
                    x1=ix*256,x2=(ix+1)*256,z1=iz*256,z2=(iz+1)*256,y=.05}},
                buildings={},trees={},props=state.trees and {{kind="tree",x=ix*256+128,z=iz*256+128,w=1.8,d=1.8}} or {},
                bridges={},points={},obstacles={}}
        end
        local details=isolated(detailsSource,"Career/CityDetails.lua",env)
        env.require=function(name)
            if name=="Career.WorldData" then return world end
            if name=="Career.CityDetails" then return details end
            if name=="Career.CityExpansion" then return {Roads={},Models={}} end
            if name=="Career.CityEnvironment" then return {RenderCell=function() return 0 end} end
            if name=="Career.HillDistrict" then return {Bounds={x1=-512,x2=512,z1=440,z2=1792},RenderCell=function() return 0 end,RenderPatch=function() return 0 end,Contains=function() return false end} end
            if name=="Career.BuildingLod" then return {Resources={},Update=function() end} end
            error("unisolated dependency "..name)
        end
        local stream=isolated(streamSource,"Career/WorldStream.lua",env)
        local parent=makeNode(nil,"scene")
        local city={root=makeNode(parent,"city"),mats={grass={},foliage={},concrete={},recess={},wood={},metal={},paint={},yellow={}}}
        return {state=state,stream=stream.New(city),module=stream,details=details,city=city,env=env}
    end

    for _,stage in ipairs({"describe","node","material","tangents"}) do
        local f=fixture()
        local s,st=f.stream,f.state
        st.faults["0:0"]=stage
        for frame=1,12 do
            local attempts,disposals=st.describes,s.unloaded
            s:Update(128,128)
            check(st.describes-attempts+s.unloaded-disposals<=1,"Update exceeded one chunk transaction")
            if frame==1 then
                check(s.failed==1 and s.retries["0:0"].after==3,"first failure must back off two visible updates")
                check(s.loaded==0,"failed frame must not load a second chunk")
                check(st.allocations==st.disposals,"partial failed root leaked")
            elseif frame==2 then
                check(s.loaded==1 and not s.chunks["0:0"],"persistent nearest failure starved next candidate")
            end
        end
        check(s.loaded>3 and s.failed==3,"backoff must progress 2/4/8 without disabling healthy chunks")
        check(s.loaded-s.unloaded==s:Stats().active,"chunk accounting changed after failures")
        check(st.allocations-st.disposals==s:Stats().active,"failed roots remain active")
        check(st.cylinders==0,"streaming visuals allocated unused cylinder models")
        local descriptions=st.describes
        s:Ensure(128,128,0);s:Ensure(128,128,0)
        check(st.describes==descriptions,"Ensure bypassed retry cooldown")
        local stats=s:Stats()
        check(stats.cooling==1 and stats.retryCells==1 and stats.pending>=1,"failed pending/cooling stats hidden")
        s:SetVisible(false)
        local tick=s.updateTick
        s:Update(128,128)
        check(s.updateTick==tick and st.describes==descriptions,"hidden stream advanced retries")
        s:SetVisible(true)
        st.faults["0:0"]=nil
        s.updateTick=s.retries["0:0"].after-1
        s:Update(128,128)
        check(s.chunks["0:0"] and not s.retries["0:0"],"recovered cell did not clear retry state")
        check(s:Stats().failed==3,"historical failure counter must not be reset on recovery")
        s:Dispose();s:Dispose()
        descriptions=st.describes
        s:Update(128,128);s:Ensure(128,128,550)
        check(st.describes==descriptions and not next(s.retries),"disposed stream kept retries or attempted loads")
    end
    group("persistent nearest fault / transaction budget / cleanup / recovery / hidden / dispose")

    do
        local f=fixture()
        local s,st=f.stream,f.state
        st.faults["0:0"]="describe"
        for attempt=1,12 do
            if s.retries["0:0"] then s.updateTick=s.retries["0:0"].after-1 end
            s:Update(128,128)
            local retry=s.retries["0:0"]
            check(retry.after-s.updateTick==math.min(120,2^math.min(attempt,8)),"retry delay escaped finite exponential cap")
            check(retry.failures<=8,"retry exponent unbounded")
        end
        s:Update(8000,8000)
        check(not s.retries["0:0"],"teleport retained far-away failure state")
        local staleLoaded=s.loaded
        s:Update(128,128)
        check(s.loaded==staleLoaded and s.unloaded==1,"stale unload must consume the sole update transaction")
        s:Dispose()
    end
    do
        local f=fixture()
        local s,st=f.stream,f.state
        for i=1,f.module.MAX_ACTIVE do
            s.chunks["fake"..i]={root=f.city.root:CreateChild("fake"),stats={},ix=0,iz=0}
        end
        s:Update(128,128)
        check(st.describes==0,"active cap attempted another chunk")
        s:Dispose()
    end
    group("capped backoff / teleport pruning / unload priority / active cap")

    do
        local f=fixture()
        local d=f.details.New(f.city.root,f.city.mats)
        d:Ground("grass",0,0,64,64,.08)
        d:Ground("concrete",0,0,2,2,.12)
        d:Ground("paint",0,0,1,1,9)
        check(#d.surfaces==2 and d:Surface(0,0)==.12 and d:Surface(10,10)==.08,
            "legacy ground rectangles/index/paint exclusion changed")
        local visual=f.details.New(f.city.root,f.city.mats,{indexSurfaces=false})
        visual:Ground("grass",0,0,256,256,.09)
        check(#visual.surfaces==0 and not next(visual.surfaceCells) and visual:Finish().triangles==2,
            "visual ground still allocates query records or stopped drawing")
        check(f.state.cylinders==0,"Details.New eagerly built an unused cylinder")
        d:Bar("metal",vector(0,0,0),vector(0,2,0),.1)
        d:Bar("metal",vector(2,0,0),vector(2,2,0),.1)
        check(f.state.cylinders==1 and d.shapes.cylinder,"Bar no longer reuses one owned cylinder")
        f.stream:Dispose()
    end
    group("opt-out ground registry / unchanged legacy lookup / lazy cylinder reuse")

    do
        local f=fixture()
        local d=f.details.New(f.city.root,f.city.mats,{indexSurfaces=false})
        ---@type any
        local batch={geometry={positions={},normals={},uvs={}},cx=0,cz=0,vertices=0}
        ---@type any
        local g=batch.geometry
        function g:DefineVertex(v) self.positions[#self.positions+1]=v end
        function g:DefineNormal(v) self.normals[#self.normals+1]=v end
        function g:DefineTexCoord(v) self.uvs[#self.uvs+1]=v end
        -- 仅替换几何输出接收器；Ellipsoid/Triangle及法线/UV仍运行真实生产函数。
        d.Batch=function() return batch end
        local cx,cy,cz,rx,ry,rz=14900,4.2,-14900,1.25,1.0,1.15
        d:Ellipsoid("foliage",cx,cy,cz,rx,ry,rz)
        check(batch.vertices==192 and #g.positions==192,"ellipsoid must emit exactly 64 nondegenerate triangles")
        local edges={}
        local function pointKey(p) return string.format("%.7f:%.7f:%.7f",p.x,p.y,p.z) end
        for i=1,#g.positions,3 do
            ---@type any, any, any
            local a,b,c=g.positions[i],g.positions[i+1],g.positions[i+2]
            ---@type any
            local ab=b-a
            ---@type any
            local cross=ab:CrossProduct(c-a)
            local length=cross:LengthSquared()
            if length<1e-10 then result.degenerate=result.degenerate+1 end
            ---@type any
            local center=(a+b+c)*(1/3)
            local outward=vector((center.x-cx)/(rx*rx),(center.y-cy)/(ry*ry),(center.z-cz)/(rz*rz))
            check(cross.x*outward.x+cross.y*outward.y+cross.z*outward.z>0,"ellipsoid face points inward")
            for j=i,i+2 do
                local normal=g.normals[j]
                local squared=normal:LengthSquared()
                if squared<1e-10 then result.zeroNormals=result.zeroNormals+1 end
                check(math.abs(squared-1)<1e-8,"ellipsoid normal must be finite and unit length")
                check(normal.x*cross.x+normal.y*cross.y+normal.z*cross.z>0,"face normal does not match winding")
            end
            local u,v,w=g.uvs[i],g.uvs[i+1],g.uvs[i+2]
            local area=(v.x-u.x)*(w.y-u.y)-(v.y-u.y)*(w.x-u.x)
            if math.abs(area)<1e-10 then result.badUVs=result.badUVs+1 end
            for _,edge in ipairs({{a,b},{b,c},{c,a}}) do
                local ka,kb=pointKey(edge[1]),pointKey(edge[2])
                local id=ka<kb and ka.."/"..kb or kb.."/"..ka
                edges[id]=(edges[id] or 0)+1
            end
        end
        for _,uses in pairs(edges) do check(uses==2,"ellipsoid pole/seam has an open or nonmanifold edge") end
        result.triangles=#g.positions/3
        check(result.degenerate==0 and result.zeroNormals==0 and result.badUVs==0,
            "ellipsoid has degenerate faces, zero normals or collapsed UVs")
        local before=batch.vertices
        d:Triangle("foliage",vector(0,0,0),vector(0,0,0),vector(1,0,0))
        check(batch.vertices==before,"degenerate Triangle guard regressed")
        local s=f.stream
        f.state.trees=true
        check(s:Load(1,1),"production tree-prop Load failed")
        check(s.chunks["1:1"].stats.triangles==230 and s.chunks["1:1"].stats.trees==1,
            "production Load did not use three 64-face crowns + 3 boxes + ground")
        s:Dispose()
    end
    group("64-face crown / outward unit normals / closed poles and seam / UV area / production Load geometry stats")
    do
        local f=fixture()
        local s=f.stream
        local clock=0
        f.env.os.clock=function() clock=clock+.003;return clock end
        s:Update(128,128)
        check(s.job~=nil and s.pendingRoot~=nil and s.loaded==0,"切片未暂停或提前发布半成品")
        check(s.pendingRoot.visible==false,"未完成块可见")
        local function hiddenPending()
            for _,g in ipairs(f.state.geometries) do
                if not g.node.disposed then
                    check(g.node.visible==false,"切片中的新批次继承假隐藏，未提交顶点可被渲染")
                end
            end
        end
        hiddenPending()
        s:SetVisible(false);s:SetVisible(true)
        check(s.pendingRoot.visible==false,"切室内再返回暴露半成品")
        hiddenPending()
        local slices=0
        while s.job and slices<20 do
            s:Update(128,128);slices=slices+1
            if s.job then hiddenPending() end
        end
        check(not s.job and s.loaded==1 and s.chunks["0:0"],"分帧块没有最终原子提交")
        for _,g in ipairs(f.state.geometries) do
            check(g.committed and g.node.visible==true,"完成块漏Commit或未启用实际绘制节点")
        end
        s:SetVisible(false)
        for _,g in ipairs(f.state.geometries) do check(g.node.visible==false,"室内未隐藏完成块绘制节点") end
        s:SetVisible(true)
        for _,g in ipairs(f.state.geometries) do check(g.node.visible==true,"返回城市未恢复完成块绘制节点") end
        s:Update(128,128)
        check(s.job~=nil,"第二块未分帧")
        s:Dispose()
        check(not s.job and not s.pendingRoot and f.state.allocations==f.state.disposals,"取消切片泄漏未提交根节点")
    end
    group("2ms切片 / 隐藏半成品 / 跨室内 / 原子提交 / 取消释放")
    result.passed=true
    return result
end

return Checks
