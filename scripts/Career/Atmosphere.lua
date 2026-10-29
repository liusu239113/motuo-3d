-- 生涯昼夜与可见云层；沿用scaffold-3d-scene的场景所有权，不另建世界/渲染管线。
-- Session负责调用：New(scene,sky,sun,moon,zone)，逐帧Apply(day,hour,cameraPosition,indoor)。
-- 不订阅Update，不读写存档，不使用真实时间/RNG：游戏时间不变，天气与云漂移就冻结。
-- 城市灯仍由调用方city:UpdateLights(hour)管理；HUD应直接使用Sample/Apply返回的label、part。
local A={}
A.__index=A
A.Resources={"Techniques/DiffVColUnlitAlpha.xml"}
A.ResourceTypes={[A.Resources[1]]="Technique"}

local PI=math.pi
local SEGMENTS,RINGS,TEXTURE_SIZE=28,7,128
local function clamp(x) return math.max(0,math.min(1,x)) end
local function smooth(a,b,x) local t=clamp((x-a)/(b-a)); return t*t*(3-2*t) end
local function lerp(a,b,t) return a+(b-a)*t end
local function finite(x) return type(x)=="number" and x==x and math.abs(x)<math.huge end
local function rgb(r,g,b) return {r=r,g=g,b=b} end
local function mix(a,b,t) return rgb(lerp(a.r,b.r,t),lerp(a.g,b.g,t),lerp(a.b,b.b,t)) end
local function color(c,alpha) return Color(c.r,c.g,c.b,alpha or 1) end
local function direction(x,y,z)
    local length=math.sqrt(x*x+y*y+z*z)
    return {x=x/length,y=y/length,z=z/length}
end
-- 私有整数散列，不污染游戏的math.random序列；负时间也确定。
local function hash(x,z)
    local n=(math.floor(x)*73856093 ~ math.floor(z)*19349663 ~ 104729)&0x7fffffff
    local mixed=((n ~ (n>>13))*1274126177)&0x7fffffff
    return (mixed ~ (mixed>>16))/2147483647
end
local function weatherAnchor(index)
    return .06+.92*hash(index,17)
end

---@class CareerAtmosphereSample
---@field day number
---@field hour number
---@field absoluteHours number
---@field label string 晴朗/多云/阴天；没有降雨逻辑
---@field part string 清晨/白昼/黄昏/夜晚
---@field cloudiness number 0..1，描述云覆盖强度，不是降水概率
---@field dayMix number
---@field nightMix number
---@field golden number
---@field lamps number 建议的人造光系数；本模块不接管城市路灯
---@field sunDirection table 指向太阳的单位向量，灯光方向取反
---@field moonDirection table
---@field sunColor table
---@field sunBrightness number
---@field moonBrightness number
---@field sunEnergy number
---@field topColor table sRGB
---@field horizonColor table sRGB；雾与天空共用
---@field groundColor table sRGB
---@field cloudColor table
---@field cloudAlpha number
---@field overcastAlpha number
---@field fogStart number 米
---@field fogEnd number 米
---@field cloudU number
---@field cloudV number
local SampleType={}

--- 只依赖旧档已有的day/hour；可独立采样，无引擎对象/资源副作用。
--- hour允许24或负数：Sample(d,24)与Sample(d+1,0)完全一致。
---@param day? number 默认第1天
---@param hour? number 默认12点；输入必须是小时而非分钟
---@return CareerAtmosphereSample
function A.Sample(day,hour)
    local d=finite(day) and day or 1
    local h=finite(hour) and hour or 12
    local total=(math.floor(d)-1)*24+h
    local normalizedHour=total%24
    local slot=math.floor(total/18)
    local cloudy=lerp(weatherAnchor(slot),weatherAnchor(slot+1),smooth(0,1,(total-slot*18)/18))
    local angle=(normalizedHour-6)/12*PI
    local sun=direction(math.cos(angle),math.sin(angle),-.35)
    -- 月光兼作柔和夜间补光：黄昏也保持向下照明，避免太阳贴地时道路全黑。
    local moon=direction(-sun.x,math.max(.45,-sun.y),-.5)
    local height=sun.y
    local daylight=smooth(-.10,.32,height)
    local night=1-smooth(-.18,-.02,height)
    local golden=math.exp(-((height-.02)/.16)^2)
    local grey=smooth(.18,.92,cloudy)
    -- 阴天目标色同样先按昼夜计算，绝不把白天灰色直接混入夜空/夜雾。
    local top=mix(rgb(.065,.095,.21),rgb(.20,.43,.81),daylight)
    top=mix(top,rgb(.27,.19,.39),golden*.32*(1-grey))
    top=mix(top,mix(rgb(.055,.07,.115),rgb(.37,.43,.51),daylight),grey*.9)
    local horizon=mix(rgb(.12,.16,.245),rgb(.66,.77,.90),daylight)
    horizon=mix(horizon,rgb(.98,.48,.22),golden*.85*(1-grey*.78))
    horizon=mix(horizon,mix(rgb(.10,.13,.19),rgb(.56,.61,.67),daylight),grey*.8)
    local ground=mix(rgb(.045,.055,.085),rgb(.29,.30,.27),daylight)
    local cloud=mix(rgb(.025,.037,.065),rgb(.88,.91,.96),daylight)
    cloud=mix(cloud,mix(rgb(.018,.026,.045),rgb(.52,.57,.64),daylight),grey*.72)
    cloud=mix(cloud,rgb(.96,.47,.24),golden*.64*(1-grey*.8))
    local label=cloudy<.30 and "晴朗" or cloudy<.72 and "多云" or "阴天"
    local part="夜晚"
    if normalizedHour>=5 and normalizedHour<7.5 then part="清晨"
    elseif normalizedHour>=7.5 and normalizedHour<16.8 then part="白昼"
    elseif normalizedHour>=16.8 and normalizedHour<19.2 then part="黄昏" end
    return {
        day=math.floor(total/24)+1,hour=normalizedHour,absoluteHours=total,label=label,part=part,
        cloudiness=cloudy,dayMix=daylight,nightMix=night,golden=golden,
        sunDirection=sun,moonDirection=moon,
        sunColor=mix(rgb(1,.40,.16),rgb(1,.95,.86),smooth(0,.5,height)),
        sunBrightness=3.1*smooth(-.035,.12,height)*(1-.82*grey),
        -- 夜间保留冷色月光供步行/骑行辨路；阴天减弱但不把人物压成剪影。
        moonBrightness=1.0*math.max(night,1-daylight)*smooth(0,.20,moon.y)*(1-.4*grey),
        sunEnergy=1-.93*smooth(.45,.94,cloudy),
        topColor=top,horizonColor=horizon,groundColor=ground,cloudColor=cloud,
        cloudAlpha=lerp(.12,.86,smooth(.08,.86,cloudy)),
        overcastAlpha=.96*smooth(.38,.93,cloudy),
        fogStart=lerp(150,65,grey),fogEnd=lerp(450,330,grey),
        lamps=math.max(1-smooth(-.04,.12,height),.35*smooth(.65,.95,cloudy)),
        -- 恒定风向；以游戏小时驱动。只在UV上取模，跨午夜连续、读档可复现。
        cloudU=(total*.021)%1,cloudV=(total*.008)%1,
    }
end

-- 周期性值噪声：边缘与导数连续，滚动UV不会出现方形接缝。
local function noise(u,v,cells)
    local x,z=u*cells,v*cells
    local ix,iz=math.floor(x),math.floor(z)
    local fx,fz=smooth(0,1,x-ix),smooth(0,1,z-iz)
    local a=lerp(hash(ix%cells,iz%cells),hash((ix+1)%cells,iz%cells),fx)
    local b=lerp(hash(ix%cells,(iz+1)%cells),hash((ix+1)%cells,(iz+1)%cells),fx)
    return lerp(a,b,fz)
end
local function cloudNoise(u,v)
    return noise(u,v,4)*.52+noise(u,v,8)*.28+noise(u,v,16)*.14+noise(u,v,32)*.06
end
local function makeTexture(dense)
    local image=Image()
    assert(image:SetSize(TEXTURE_SIZE,TEXTURE_SIZE,4),"[天气] 无法创建云层图像")
    for y=0,TEXTURE_SIZE-1 do
        for x=0,TEXTURE_SIZE-1 do
            local u,v=x/TEXTURE_SIZE,y/TEXTURE_SIZE
            local n=cloudNoise(u,v)
            local alpha=dense and (.3+.7*smooth(.22,.68,n)) or smooth(.43,.66,n)
            -- 内部亮暗不是一块白色软圆；小尺度噪声形成不规则云缘。
            local shade=.62+.38*smooth(.25,.75,cloudNoise((u+.025)%1,(v+.04)%1))
            image:SetPixel(x,y,Color(shade,shade,shade,alpha))
        end
    end
    local texture=Texture2D:new()
    texture:SetSRGB(true)
    texture:SetFilterMode(FILTER_TRILINEAR)
    texture:SetAddressMode(COORD_U,ADDRESS_WRAP); texture:SetAddressMode(COORD_V,ADDRESS_WRAP)
    local uploaded=texture:SetData(image,true)
    image:Dispose()
    if not uploaded then texture:Dispose(); error("[天气] 无法上传云层纹理") end
    return texture
end

-- 仅绘制上半球，半径180/188米，低于Session的450米farClip，不改变摄像机。
-- 28段×7环×2三角×2层=784三角；一次建网格，无刚体/碰撞，无全城云团。
-- 内表面朝相机；最低环透明，UV用方向的XZ投影，顶部没有经线UV接缝。
local function cloudVertex(geometry,radius,ring,segment)
    local elevation=lerp(.015,PI*.5,ring/RINGS)
    local azimuth=segment/SEGMENTS*2*PI
    local horizontal=math.cos(elevation)
    local x,y,z=horizontal*math.cos(azimuth),math.sin(elevation),horizontal*math.sin(azimuth)
    geometry:DefineVertex(Vector3(x*radius,y*radius,z*radius))
    geometry:DefineNormal(Vector3(-x,-y,-z))
    -- 透视云平面投影：近地平线的云压扁而不是拉成竖条，顶部也没有经线接缝。
    local projection=.72/(y+.25)
    geometry:DefineTexCoord(Vector2(.5+x*projection,.5+z*projection))
    geometry:DefineColor(Color(1,1,1,smooth(.015,.18,y)))
end
local function makeLayer(root,technique,texture,radius,name)
    local material=Material:new()
    material:SetTechnique(0,technique)
    material:SetTexture(TU_DIFFUSE,texture)
    material:SetCullMode(CULL_NONE)
    material:SetOcclusion(false)
    material:SetShaderParameter("MatDiffColor",Variant(Color(0,0,0,0)))
    local geometry=root:CreateChild(name):CreateComponent("CustomGeometry")
    geometry.castShadows=false; geometry.occluder=false; geometry.occludee=false
    geometry.lightMask=0; geometry.shadowMask=0
    geometry:BeginGeometry(0,TRIANGLE_LIST)
    for ring=0,RINGS-1 do
        for segment=0,SEGMENTS-1 do
            cloudVertex(geometry,radius,ring,segment)
            cloudVertex(geometry,radius,ring+1,segment)
            cloudVertex(geometry,radius,ring,segment+1)
            cloudVertex(geometry,radius,ring,segment+1)
            cloudVertex(geometry,radius,ring+1,segment)
            cloudVertex(geometry,radius,ring+1,segment+1)
        end
    end
    geometry:Commit(); geometry:SetMaterial(material)
    return material
end

---@class CareerAtmosphere
---@field scene Scene
---@field sky ProceduralSky
---@field sun Light
---@field moon Light?
---@field zone Zone
---@field root Node
---@field capture SkyLightCapture?
---@field textures Texture2D[]
---@field materials Material[]
---@field disposed boolean
---@field lastLabel string
---@field lastPart string
---@field state CareerAtmosphereSample?
---@field Apply fun(self:CareerAtmosphere,day?:number,hour?:number,cameraPosition?:Vector3,indoor?:boolean):CareerAtmosphereSample
---@field Dispose fun(self:CareerAtmosphere)
local AtmosphereType={}

---@param scene Scene
---@param sky ProceduralSky
---@param sun Light
---@param moon Light?
---@param zone Zone
---@return CareerAtmosphere
function A.New(scene,sky,sun,moon,zone)
    local self=setmetatable({},A)
    self:Init(scene,sky,sun,moon,zone)
    return self
end
---@param scene Scene
---@param sky ProceduralSky
---@param sun Light
---@param moon Light?
---@param zone Zone
function A:Init(scene,sky,sun,moon,zone)
    self.scene,self.sky,self.sun,self.moon,self.zone=scene,sky,sun,moon,zone
    self.capture=zone.node:GetComponent("SkyLightCapture")
    self.root=scene:CreateChild("南城天气云穹")
    self.root.enabled=false
    self.disposed=false; self.lastLabel=""; self.lastPart=""
    self.textures={}; self.materials={}
    local technique=assert(cache:GetResource("Technique",A.Resources[1]),"[天气] 缺少内置透明云材质")
    for i=1,2 do
        local texture=makeTexture(i==2)
        self.textures[i]=texture
        self.materials[i]=makeLayer(self.root,technique,texture,i==1 and 180 or 188,i==1 and "碎云" or "层云")
    end
    print("[天气] 双层可见云穹已创建；784三角、两张128像素纹理，不参与碰撞")
    if not self.capture then print("[天气] 未找到同节点天空捕获，使用原Zone的环境光并按昼夜压暗") end
end

--- 返回与Sample同源的天气；仅管理传入的室外光照和自己创建的云层。
--- indoor=true或sky.enabledEffective=false时隐藏云，不反向打开住房关闭的天空/日月。
--- 即使暂停也可重复Apply（保持同一day/hour）；传cameraPosition以避免远离原点后丢云。
---@param day? number
---@param hour? number
---@param cameraPosition? Vector3 缺省取当前视口相机；无视口则保持上次位置
---@param indoor? boolean
---@return CareerAtmosphereSample
function A:Apply(day,hour,cameraPosition,indoor)
    local s=A.Sample(day,hour)
    if self.disposed then return s end
    self.state=s
    if not cameraPosition then
        local viewport=renderer:GetViewport(0)
        if viewport and viewport.camera then cameraPosition=viewport.camera.node.worldPosition end
    end
    if cameraPosition then self.root.worldPosition=cameraPosition end
    local visible=not indoor and self.sky.enabledEffective
    self.root.enabled=visible
    -- 不修改sun/moon.enabled；住房可继续通过enabled=false停用它们。
    local sun,moon=s.sunDirection,s.moonDirection
    self.sun.node.direction=Vector3(-sun.x,-sun.y,-sun.z)
    self.sun.color=color(s.sunColor); self.sun.brightness=s.sunBrightness
    if self.moon then
        self.moon.node.direction=Vector3(-moon.x,-moon.y,-moon.z)
        self.moon.color=Color(.54,.66,1); self.moon.brightness=s.moonBrightness
    end
    self.sky.sunLight=self.sun
    self.sky.skyTopColor=color(s.topColor)
    self.sky.skyHorizonColor=color(s.horizonColor); self.sky.groundHorizonColor=color(s.horizonColor)
    self.sky.groundBottomColor=color(s.groundColor)
    self.sky.skyCurve=.22; self.sky.groundCurve=.04
    self.sky.skyEnergy=1; self.sky.groundEnergy=.8; self.sky.exposure=1
    self.sky.sunDiskSize=.75; self.sky.sunAngleMax=22; self.sky.sunEnergy=s.sunEnergy
    self.zone.fogColor=color(s.horizonColor)
    self.zone.depthFogEnable=true; self.zone.depthFogDensity=1
    self.zone.depthFogStart=s.fogStart; self.zone.depthFogEnd=s.fogEnd
    -- 捕获只含Skybox，不含透明CustomGeometry云；天空本身的同源阴天色负责环境光。
    -- 不增加第二个Skybox/Capture，不每帧强制RequestCapture，保留调用方原有捕获节流。
    local capture=self.capture
    local captured=visible and capture and capture.enabledEffective and capture.supported and capture.ready
    local intensity=captured and lerp(2,1,s.dayMix) or (.08+.70*s.dayMix)*(1-.4*s.cloudiness)
    self.zone.envTextureDiffIntensity=intensity; self.zone.envTextureSpecIntensity=intensity
    self.materials[1]:SetShaderParameter("MatDiffColor",Variant(color(s.cloudColor,s.cloudAlpha)))
    self.materials[2]:SetShaderParameter("MatDiffColor",Variant(color(s.cloudColor,s.overcastAlpha)))
    self.materials[1]:SetUVTransform(Vector2(s.cloudU,s.cloudV),0,Vector2(1,1))
    self.materials[2]:SetUVTransform(Vector2((-s.absoluteHours*.01281)%1,(s.absoluteHours*.00584)%1),19,Vector2(.73,.73))
    if s.label~=self.lastLabel or s.part~=self.lastPart then
        print(string.format("[天气] 第%d天 %.2f时 · %s · %s（云量%.2f）",s.day,s.hour,s.part,s.label,s.cloudiness))
        self.lastLabel,self.lastPart=s.label,s.part
    end
    return s
end

-- 只释放本模块拥有的云节点、材质与纹理；借用的Scene/Zone/天空/灯光不释放、不改enabled。
-- 应在Session销毁Scene前调用；Dispose幂等，已释放实例的Apply只返回纯采样。
function A:Dispose()
    if self.disposed then return end
    self.disposed=true
    self.root:Dispose()
    for _,material in ipairs(self.materials) do material:Dispose() end
    for _,texture in ipairs(self.textures) do texture:Dispose() end
    self.materials={}; self.textures={}
    print("[天气] 云穹资源已释放")
end
return A
