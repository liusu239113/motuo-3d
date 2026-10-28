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
---@return number, number, number
function Contact.Solve(city,id,x,z,yaw,lean)
    local wheels=assert(Contact.Wheels[id],"缺少城市胎面标定："..id)
    local pitch,roll=0,lean or 0
    local yawRotation=Quaternion(0,yaw,0)
    local heights={}
    local function support(w,pitchAngle,rollAngle)
        local rotation=Quaternion(pitchAngle,V.RIGHT)*Quaternion(rollAngle,V.FORWARD)
        local needed=-math.huge
        for _,p in ipairs(w.points) do
            local localPoint=rotation*p
            local world=yawRotation*localPoint
            needed=math.max(needed,city:Surface(x+world.x,z+world.z)-localPoint.y)
        end
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

function Contact.CompleteTruck(root)
    local Parts=require("Parts")
    local rubber=Parts.Material(.025,.027,.03,.9,0)
    local rim=Parts.Material(.30,.32,.34,.32,.72)
    local dark=Parts.Material(.055,.06,.065,.65,.3)
    local tire=CylinderGeometry(.56,.56,.32,32,1,false):ToModel()
    local hub=CylinderGeometry(.32,.32,.335,24,1,false):ToModel()
    local cap=CylinderGeometry(.11,.11,.35,16,1,false):ToModel()
    for _,z in ipairs({-1.79,1.82}) do
        Parts.Bar(root,dark,V(-1.17,.04,z),V(1.17,.04,z),.075)
        for _,side in ipairs({-1,1}) do
            local center=V(side*1.17,.04,z)
            local rotation=Quaternion(90,V.FORWARD)
            Parts.Add(root,"货车独立轮胎",tire,rubber,center,V.ONE,rotation,true)
            Parts.Add(root,"货车金属轮毂",hub,rim,center,V.ONE,rotation,true)
            Parts.Add(root,"货车轮轴盖",cap,dark,center,V.ONE,rotation,true)
            for i=0,5 do
                local a=i*math.pi/3
                Parts.Add(root,"货车轮毂螺栓","Sphere",dark,
                    center+V(side*.174,.23*math.cos(a),.23*math.sin(a)),V(.035,.035,.035),nil,false)
            end
        end
    end
    print("[货车轮组] 原车壳无轮资源；按真实轮拱补4条轮胎/轮毂/双轴，直径1.12m")
end
return Contact
