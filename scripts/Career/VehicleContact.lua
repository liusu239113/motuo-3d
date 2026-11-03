-- 城市专用接触标定，不修改旧竞速的资源归一化或骑手。
-- 侧视：后胎<0 ----- 车根 ----- 前胎>0；胎面保留原始Y，不能把边撑当胎底。
-- 点来自归一化MDL的胎面支撑顶点，覆盖俯仰±6°、压弯±12°；货车原包无轮，另补轮组。
local Contact={}
local V=Vector3
local function wheel(points)
    local vertices={}
    local x,z=0,0
    for _,p in ipairs(points) do
        vertices[#vertices+1]=V(p[1],p[2],p[3]);x=x+p[1];z=z+p[3]
    end
    return {points=vertices,x=x/#points,z=z/#points}
end
local function pair(rear,front) return {wheel(rear),wheel(front)} end
Contact.Wheels={
    borrowed_ebike=pair({{-.031924,.002834,-.617155},{-.009846,0,-.617155},{.016007,0,-.617155},{.040051,.002834,-.617155}},
        {{-.031924,.002834,.729281},{-.009846,0,.729281},{.016007,0,.729281},{.040051,.002834,.729281}}),
    sport=pair({{-.039971,.008415,-.784687},{-.039971,.008415,-.713160},{-.002104,.004208,-.751027},{-.002104,.008415,-.675294},{.039971,.004208,-.729990}},
        {{-.039971,.004207,.805724},{-.039971,.004208,.700538},{-.002104,0,.767857},{-.002104,.004208,.696331},{.039971,0,.746820}}),
    rally=pair({{.023894,.008689,-.719002},{.023894,.013033,-.797202}},{{.019550,.004344,.719002},{.019550,.008689,.801546}}),
    cruiser=pair({{-.035993,.028084,-.889894},{-.031028,.028084,-.835284},{-.001241,.024573,-.889894},{-.001241,.024573,-.830319},{.001241,.024573,-.892376},{.031028,.028084,-.837766},{.033511,.028084,-.889894}},
        {{-.031029,.003510,.817908},{-.001241,0,.817908},{-.001241,0,.867553},{-.001241,.003510,.773227},{.028546,.003510,.817908}}),
    sport_2=pair({{-.052593,.008415,-.713160},{-.002104,0,-.713160},{.044178,.008415,-.713160},{.044178,.016830,-.793102},{.044178,.016830,-.633219}},
        {{-.056800,.008415,.725783},{-.018933,.004207,.725783},{-.018933,.012622,.641634},{-.018933,.012622,.805724},{.014726,.008415,.725783}}),
    sport_3=pair({{-.039971,.004207,-.717368},{-.006311,0,-.717368},{.027348,.004207,-.717368}},{{-.018933,0,.713160},{.002104,0,.713160},{.027348,.004207,.713160}}),
    cruiser_2=pair({{-.146233,.019178,-.836644},{-.146233,.019178,-.759932},{-.093493,.014384,-.798288},{-.093493,.019178,-.879795},{-.045548,.019178,-.836644},{-.045548,.019178,-.759932}},
        {{-.127055,0,.807877},{-.088699,0,.735959},{-.088699,0,.875000},{-.055137,0,.769521},{-.055137,0,.855822}}),
    cruiser_3=pair({{-.059932,.009589,-.783904},{-.059932,.014384,-.855822},{.007192,0,-.836644},{.007192,0,-.750342},{.074315,.009589,-.783904},{.074315,.014384,-.855822}},
        {{-.059932,.057534,.836644},{.007192,.047945,.836644},{.074315,.057534,.836644}}),
    rally_2=pair({{-.032583,.021722,-.732035},{.032583,.021722,-.732035}},{{-.032583,0,.762446},{.032583,0,.762446}}),
    rally_3=pair({{-.010861,0,-.705969},{-.010861,0,-.671213},{-.010861,.004344,-.758102},{.041272,0,-.675558},{.045616,0,-.727691}},
        {{-.019550,0,.675558},{-.019550,0,.701624},{.036928,0,.679902},{.036928,0,.705969}}),
}
-- 巡航包围盒含LOD3向下扩展1.197mm，Assets.Add以全LOD包围盒归零，胎面也须同源。
for _,w in ipairs(Contact.Wheels.cruiser) do
    for i,p in ipairs(w.points) do w.points[i]=p+V(0,.0021517,0) end
end
Contact.Wheels.sedan={
    wheel({{-.922701,0,-1.318787},{-.922701,0,-1.219765},{-.733659,0,-1.318787},{-.733659,0,-1.219765}}),
    wheel({{.733659,0,-1.318787},{.733659,0,-1.219765},{.922701,0,-1.318787},{.922701,0,-1.219765}}),
    wheel({{-.922701,0,1.300783},{-.922701,0,1.399804},{-.787671,0,1.300783},{-.787671,0,1.399804},{-.697652,.018004,1.300783},{-.697652,.018004,1.390802}}),
    wheel({{.697652,.018004,1.300783},{.697652,.018004,1.390802},{.787671,0,1.300783},{.787671,0,1.399804},{.922701,0,1.300783},{.922701,0,1.399804}}),
}
Contact.Wheels.suv={
    wheel({{-1.117515,0,-1.568200},{-1.117515,0,-1.448630},{-.915166,0,-1.568200},{-.915166,0,-1.448630},{-.887573,0,-1.503816}}),
    wheel({{.887573,0,-1.503816},{.915166,0,-1.568200},{.915166,0,-1.448630},{1.117515,0,-1.568200},{1.117515,0,-1.448630}}),
    wheel({{-1.135910,0,1.411840},{-1.117515,0,1.356654},{-1.117515,0,1.476223},{-.915166,0,1.347456},{-.915166,0,1.476223},{-.887573,0,1.411840}}),
    wheel({{.887573,0,1.411840},{.915166,0,1.347456},{.915166,0,1.476223},{1.117515,0,1.347456},{1.117515,0,1.476223}}),
}
-- 货车轮拱中心取自车壳轮拱：后Z=-1.79、前Z=1.82，侧面X=±1.17。
local truck={}
for _,z in ipairs({-1.79,1.82}) do
    for _,side in ipairs({-1,1}) do
        local points={}
        for i=0,31 do
            local a=i*math.pi/16
            for _,edge in ipairs({-.16,.16}) do
                points[#points+1]={side*1.17+edge,.04+.56*math.cos(a),z+.56*math.sin(a)}
            end
        end
        truck[#truck+1]=wheel(points)
    end
end
Contact.Wheels.truck=truck

---@param city CareerCity
---@param id string
---@param x number
---@param z number
---@param yaw number
---@param lean? number
---@param flat? number 已证明整个旋转包络同高
---@param wheelHeights? number[] 各轮完整旋转包络各自同高
---@param noReuse? boolean 独立验收保留逐点重算
---@param plane? {x:number,z:number,base:number} 已证明完整旋转包络同一地形平面
---@param sample? fun(x:number,z:number):number 局部同源矩形精确查询
---@return number, number, number
local function solve(city,id,x,z,yaw,lean,flat,wheelHeights,noReuse,plane,sample)
    local wheels=assert(Contact.Wheels[id],"缺少城市胎面标定："..id)
    local pitch,roll=0,lean or 0
    local yawRotation=Quaternion(0,yaw,0)
    local heights={}
    local constant,previous={},{ }
    local lastRotation={pitch=math.huge,roll=math.huge,value=Quaternion.IDENTITY}
    if wheelHeights then for i,w in ipairs(wheels) do constant[w]=wheelHeights[i] end end
    local function support(w,pitchAngle,rollAngle)
        local cached=previous[w]
        if cached and cached.pitch==pitchAngle and cached.roll==rollAngle then return cached.height end
        local ground=flat or constant[w]
        -- 精确零姿态且该轮完整包络同高时，恒等旋转不改变Y。
        -- 仍逐点按原顺序取最大值；不跨次缓存，不增加标定扫描。
        if not noReuse and ground~=nil and pitchAngle==0 and rollAngle==0 then
            local needed=-math.huge
            for _,p in ipairs(w.points) do needed=math.max(needed,ground-p.y) end
            previous[w]={pitch=pitchAngle,roll=rollAngle,height=needed}
            return needed
        end
        local rotation=lastRotation.value
        if noReuse or lastRotation.pitch~=pitchAngle or lastRotation.roll~=rollAngle then
            rotation=Quaternion(pitchAngle,V.RIGHT)*Quaternion(rollAngle,V.FORWARD)
            if not noReuse then lastRotation={pitch=pitchAngle,roll=rollAngle,value=rotation} end
        end
        local needed=-math.huge
        for _,p in ipairs(w.points) do
            local localPoint=rotation*p
            local surface=ground
            if surface==nil then
                local world=yawRotation*localPoint
                if plane then surface=plane.x*(x+world.x)+plane.z*(z+world.z)+plane.base
                elseif sample then surface=sample(x+world.x,z+world.z)
                else surface=city:Surface(x+world.x,z+world.z) end
            end
            needed=math.max(needed,surface-localPoint.y)
        end
        if not noReuse then previous[w]={pitch=pitchAngle,roll=rollAngle,height=needed} end
        return needed
    end
    if #wheels==2 then
        -- 二轮用有界求根，避免胎面切换或路沿边缘让固定步长反复跳变。
        local lo,hi=-6,6
        for _=1,18 do
            local mid=(lo+hi)*.5
            local difference=support(wheels[2],mid,roll)-support(wheels[1],mid,roll)
            if difference>0 then hi=mid else lo=mid end
        end
        pitch=(lo+hi)*.5
        return math.max(support(wheels[1],pitch,roll),support(wheels[2],pitch,roll)),pitch,roll
    end
    -- 四轮允许刚性车身在不共面路沿上三点支撑；不强行穿地求四轮全贴。
    for _=1,6 do
        for i,w in ipairs(wheels) do heights[i]=support(w,pitch,roll) end
        local rear,front=wheels[1],wheels[#wheels]
        local rh,fh=(heights[1]+heights[2])*.5,(heights[3]+heights[4])*.5
        local left=(heights[1]+heights[3])*.5
        local right=(heights[2]+heights[4])*.5
        local track=wheels[2].x-wheels[1].x
        roll=math.max(-6,math.min(6,roll+math.deg((right-left)/track)))
        pitch=math.max(-6,math.min(6,pitch-math.deg((fh-rh)/(front.z-rear.z))))
    end
    local height=-math.huge
    for _,w in ipairs(wheels) do height=math.max(height,support(w,pitch,roll)) end
    return height,pitch,roll
end

-- 只在整个轮胎旋转球包络被证明同高时复用相同lean的原算法结果。
-- 斜坡/台阶/海岸返回nil，逐顶点原求解一字不变；不近似轮胎或改迭代阈值。
local flatResults={}
Contact.flatHits,Contact.exactSolves=0,0
---@return number, number, number
function Contact.Solve(city,id,x,z,yaw,lean)
    local wheels=assert(Contact.Wheels[id],"缺少城市胎面标定："..id)
    if city.FlatHeight then
        local memo=flatResults[id]
        if not memo or memo.wheels~=wheels then
            local reach=0
            for _,w in ipairs(wheels) do for _,p in ipairs(w.points) do reach=math.max(reach,p:Length()) end end
            memo={wheels=wheels,reach=reach,regions={}}
            for _,w in ipairs(wheels) do
                local x1,x2,z1,z2,yabs=math.huge,-math.huge,math.huge,-math.huge,0
                for _,p in ipairs(w.points) do
                    x1,x2=math.min(x1,p.x),math.max(x2,p.x)
                    z1,z2=math.min(z1,p.z),math.max(z2,p.z)
                    yabs=math.max(yabs,math.abs(p.y))
                end
                memo.regions[#memo.regions+1]={x1=x1,x2=x2,z1=z1,z2=z2,yabs=yabs}
            end
            flatResults[id]=memo
        end
        local r=memo.reach+.00001
        local flat=city:FlatHeight(x-r,z-r,x+r,z+r)
        if flat==nil and city.space=="city" then
            local plane=require("Career.HillDistrict").Plane(x-r,z-r,x+r,z+r) --[[@as {x:number,z:number,base:number}?]]
            if plane then
                -- 同一已证明坡面、车型、朝向与压弯角的支撑姿态只与坡度有关。
                -- 相对高度求解仍遍历全部胎面点；只平移平面截距，不复用跨折线结果。
                local bank=plane --[[@as {x:number,z:number,base:number}]]
                local roll=lean or 0
                local key=string.pack("dddd",bank.x,bank.z,yaw,roll)
                memo.planes=memo.planes or {}
                local saved=memo.planes[key]
                if not saved then
                    if (memo.planeCount or 0)>=64 then memo.planes={};memo.planeCount=0 end
                    local h,p,r=solve(city,id,0,0,yaw,roll,nil,nil,false,{x=bank.x,z=bank.z,base=0})
                    saved={height=h,pitch=p,roll=r}
                    memo.planes[key]=saved;memo.planeCount=(memo.planeCount or 0)+1
                end
                return bank.x*x+bank.z*z+bank.base+saved.height,saved.pitch,saved.roll
            end
        end
        local wheelHeights={}
        local allWheels=true
        if flat==nil then
            -- 整车包络跨路沿，不代表轮胎跨路沿。各轮独立证明，仍覆盖全部迭代旋转。
            -- pitch绕X、roll绕Z：逐轴区间界比旋转球更紧，但仍覆盖每个原始胎面点。
            local angle=math.rad(#wheels==2 and math.abs(lean or 0) or math.max(6,math.abs(lean or 0)))
            local sn,loss=math.sin(angle),1-math.cos(angle)
            local ps,pl=math.sin(math.rad(6)),1-math.cos(math.rad(6))
            local a=math.rad(yaw)
            local cs,ys=math.cos(a),math.sin(a)
            for i,region in ipairs(memo.regions) do
                local mx,mz=math.max(math.abs(region.x1),math.abs(region.x2)),math.max(math.abs(region.z1),math.abs(region.z2))
                local ex=mx*loss+region.yabs*sn
                local ey=region.yabs+mx*sn
                local ez=mz*pl+ey*ps
                local cx,cz=(region.x1+region.x2)/2,(region.z1+region.z2)/2
                local hx,hz=(region.x2-region.x1)/2+ex,(region.z2-region.z1)/2+ez
                local wx,wz=x+cs*cx+ys*cz,z-ys*cx+cs*cz
                local rx,rz=math.abs(cs)*hx+math.abs(ys)*hz+.00001,math.abs(ys)*hx+math.abs(cs)*hz+.00001
                local h=city:FlatHeight(wx-rx,wz-rz,wx+rx,wz+rz)
                if h~=nil then wheelHeights[i]=h else allWheels=false end
            end
            if allWheels then
                flat=wheelHeights[1]
                for _,h in ipairs(wheelHeights) do if h~=flat then flat=nil;break end end
                if flat==nil then
                    -- Proven constant height PER wheel makes yaw/XZ irrelevant,
                    -- even while axles straddle a curb. Reuse only an identical
                    -- ordered height vector and lean; never reuse across a break.
                    local values={lean or 0}
                    for i=1,#wheels do values[#values+1]=wheelHeights[i] end
                    local key=string.pack(string.rep("d",#values),table.unpack(values))
                    memo.postures=memo.postures or {}
                    local saved=memo.postures[key]
                    if not saved then
                        if (memo.postureCount or 0)>=128 then memo.postures={};memo.postureCount=0 end
                        local height,pitch,roll=solve(city,id,x,z,yaw,lean,nil,wheelHeights)
                        saved={height=height,pitch=pitch,roll=roll}
                        memo.postures[key]=saved;memo.postureCount=(memo.postureCount or 0)+1
                    end
                    Contact.flatHits=Contact.flatHits+1
                    return saved.height,saved.pitch,saved.roll
                end
            end
        end
        if flat~=nil then
            local roll=lean or 0
            if memo.lean~=roll then
                memo.height,memo.pitch,memo.roll=solve(city,id,0,0,0,roll,0)
                memo.lean=roll
            end
            Contact.flatHits=Contact.flatHits+1
            return flat+memo.height,memo.pitch,memo.roll
        end
        -- A curb under ONE wheel must not discard proofs for the other three.
        -- Compile the exact authored old-city rectangles once per 16m candidate
        -- region, avoiding Environment/Hills/grid traversal in every tire sample.
        local sample=require("Career.FlatSurface").Compile(city,x-r,z-r,x+r,z+r)
        Contact.exactSolves=Contact.exactSolves+1
        return solve(city,id,x,z,yaw,lean,nil,wheelHeights,false,nil,sample)
    end
    Contact.exactSolves=Contact.exactSolves+1
    return solve(city,id,x,z,yaw,lean)
end
-- 验收保留精确原路径，对照任意地形/朝向/lean，禁止把快路结果当参考值。
function Contact.SolveExact(city,id,x,z,yaw,lean)
    return solve(city,id,x,z,yaw,lean,nil,nil,true)
end

-- 显式隔离验收：真实第四轮胎面跨过断面，其余三轮完整包络常高。
function Contact.SupportChecks()
    local count=0
    for _,id in ipairs({"sedan","suv","truck"}) do
        local wheels=Contact.Wheels[id]
        local cut=wheels[4].z
        for _,ground in ipairs({0,.055,-.125}) do
            for _,yaw in ipairs({0,37,90,180}) do
                local cs,sn=math.cos(math.rad(yaw)),math.sin(math.rad(yaw))
                local lowCalls,highCalls,proofMisses,proofHits=0,0,0,0
                local function surface(x,z)
                    local lx,lz=cs*x-sn*z,sn*x+cs*z
                    if lx>=0 and lz>=cut then highCalls=highCalls+1;return ground+.069 end
                    lowCalls=lowCalls+1
                    return ground
                end
                local function flat(_,x1,z1,x2,z2)
                    local minX,maxX,minZ,maxZ=math.huge,-math.huge,math.huge,-math.huge
                    for _,x in ipairs({x1,x2}) do for _,z in ipairs({z1,z2}) do
                        local lx,lz=cs*x-sn*z,sn*x+cs*z
                        minX,maxX=math.min(minX,lx),math.max(maxX,lx)
                        minZ,maxZ=math.min(minZ,lz),math.max(maxZ,lz)
                    end end
                    if maxX<0 or maxZ<cut then proofHits=proofHits+1;return ground end
                    if minX>=0 and minZ>=cut then proofHits=proofHits+1;return ground+.069 end
                    proofMisses=proofMisses+1
                    return nil
                end
                local city={space="support-check",Surface=function(_,x,z) return surface(x,z) end,
                    FlatHeight=flat} --[[@as CareerCity]]
                for _,lean in ipairs({0,-.000001,.000001,-6,6}) do
                    lowCalls,highCalls,proofMisses,proofHits=0,0,0,0
                    local h,p,r=Contact.Solve(city,id,0,0,yaw,lean)
                    assert(proofHits==3 and proofMisses==2,"未覆盖三轮常高和整车/第四轮回退")
                    if lean==0 then
                        assert(lowCalls>0 and highCalls>0,"优化路径第四轮未实际查询断面两侧")
                    end
                    local misses=proofMisses
                    local eh,ep,er=Contact.SolveExact(city,id,0,0,yaw,lean)
                    assert(proofMisses==misses,"原始参考路径不应读取常高证明")
                    assert(math.abs(h-eh)<1e-7 and math.abs(p-ep)<1e-6 and math.abs(r-er)<1e-6,
                        "零姿态快路或断面回退改变接地 "..id)
                    count=count+1
                end
                assert(proofMisses>0 and lowCalls>0 and highCalls>0,"断面验收未实际覆盖高低两侧")
                -- 无证明时仍查询原地表，精确参考路径不调用FlatHeight。
                local calls=lowCalls+highCalls
                local unproven={Surface=city.Surface} --[[@as CareerCity]]
                local h,p,r=Contact.Solve(unproven,id,0,0,yaw,0)
                assert(lowCalls+highCalls>calls,"无证明时必须读取地表")
                local eh,ep,er=Contact.SolveExact(unproven,id,0,0,yaw,0)
                assert(h==eh and p==ep and r==er,"无证明回退改变原值")
                count=count+1
            end
        end
    end
    print(string.format("[零姿态支撑验收] PASS %d例 三车型/第四轮真实跨断面/零与负地面/多朝向/微小非零与压弯/无证明/独立原路径；无跨次支撑缓存",count))
end

-- Explicit regression entry; never runs during gameplay. Invoke from a test
-- session as require("Career.VehicleContact").PerformanceChecks(session).
---@param session {city:CareerCity}
function Contact.PerformanceChecks(session)
    Contact.SupportChecks()
    local city=session.city
    local cases={}
    local ids={"borrowed_ebike","sport","rally","cruiser","sport_2","sport_3","cruiser_2","cruiser_3","rally_2","rally_3","sedan","suv","truck"}
    for _,id in ipairs(ids) do
        for i=1,20 do
            -- Actual old-city crossing edges, road/sidewalk borders, both axle
            -- layouts and bank angles; no generated replacement surface.
            local x=100+(i-10)*1.37
            local z=(i%4-2)*6.13
            cases[#cases+1]={id=id,x=x,z=z,yaw=(i*47)%360,lean=(i%3-1)*6}
        end
        for _,point in ipairs({{0,440},{150,600},{304,636},{8,1232},{0,1280},{-401,-401},{-530,-530},{-548,-660}}) do
            cases[#cases+1]={id=id,x=point[1],z=point[2],yaw=47,lean=0}
        end
    end
    local maxHeight,maxPitch,maxRoll=0.0,0.0,0.0
    for _,c in ipairs(cases) do
        local h,p,r=Contact.Solve(city,c.id,c.x,c.z,c.yaw,c.lean)
        local eh,ep,er=Contact.SolveExact(city,c.id,c.x,c.z,c.yaw,c.lean)
        maxHeight=math.max(maxHeight,math.abs(h-eh))
        maxPitch=math.max(maxPitch,math.abs(p-ep));maxRoll=math.max(maxRoll,math.abs(r-er))
        assert(math.abs(h-eh)<1e-7 and math.abs(p-ep)<1e-6 and math.abs(r-er)<1e-6,
            "接地原路径不等价："..c.id.." at "..c.x..","..c.z)
    end
    local start=os.clock()
    for _,c in ipairs(cases) do Contact.SolveExact(city,c.id,c.x,c.z,c.yaw,c.lean) end
    local exact=(os.clock()-start)*1000
    start=os.clock()
    for _,c in ipairs(cases) do Contact.Solve(city,c.id,c.x,c.z,c.yaw,c.lean) end
    local fast=(os.clock()-start)*1000
    print(string.format("[接地数值/性能验收] %d例 maxError h=%.9g p=%.9g r=%.9g exact=%.3fms optimized=%.3fms speedup=%.2fx",
        #cases,maxHeight,maxPitch,maxRoll,exact,fast,exact/math.max(fast,.000001)))
    return {cases=#cases,heightError=maxHeight,pitchError=maxPitch,rollError=maxRoll,exactMs=exact,optimizedMs=fast}
end

---@param root Node
function Contact.CompleteTruck(root)
    require("Career.TruckWheelVisuals").Add(root)
end
return Contact
