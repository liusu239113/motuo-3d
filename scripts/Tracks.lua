-- Six authored closed courses. One sampler is shared by navigation, preview and road geometry.
-- Lengths are horizontal metres (the existing race/AI odometer convention), widths are full widths.
-- 路面加宽、路肩收窄：原版可行驶带只有不到一半沥青宽度，玩家一偏就出界。
-- 每条赛道固定圈数与收益；默认封闭赛道免费，其余需通关或金币解锁。
local Tracks = {}

---@class ScenicSample
---@field x number
---@field y number
---@field z number
---@field s number
---@field rx number
---@field rz number

---@class TrackDefinition
---@field id string
---@field name string
---@field description string
---@field theme string
---@field accent number[]
---@field width number
---@field shoulder number
---@field points number[][]
---@field length? number
---@field samples? ScenicSample[]
---@field preview? table[]
---@field treeBudget integer
---@field water boolean
---@field traffic boolean
---@field goalNames string[]
---@field laps integer 该赛道固定圈数，玩家不可自选
---@field reward integer 基础金币收益（第1名全额）
---@field price integer 解锁所需金币，0为默认解锁
---@field requires string 前置赛道：先在该赛道拿第1名或累计金币解锁
---@field aiLevel number AI强度0..1；第一关最低，越往后越强

---@type TrackDefinition[]
local definitions = {
    {id = "lake", aiLevel = 0.74, laps = 3, reward = 34, price = 0, requires = "default", name = "山湖公路", theme = "lake", accent = {78, 185, 179}, width = 15.0, shoulder = 3.2,
        description = "原版环湖云岭公路 · 河谷高架桥 · 草甸与驿站", treeBudget = 202, water = true, traffic = true,
        goalNames = {"翡翠湖观景湾", "白水河大桥", "冷杉林入口", "高山草甸垭口", "云岭山路入口", "牧场驿站"},
        points = {{0,14,-140},{0,16,56},{-115,19,252},{-338,25,427},{-580,40,535},{-695,58,778},
            {-526,79,1008},{-176,95,1034},{122,105,886},{284,91,684},{486,72,602},{634,53,319},
            {526,35,69},{338,23,-52},{176,17,-201},{27,14,-302}}},
    {id = "alpine", aiLevel = 0.82, laps = 4, reward = 42, price = 2600, requires = "lake", name = "高山发卡", theme = "alpine", accent = {162, 192, 223}, width = 13.0, shoulder = 2.8,
        description = "连续折返攀升 · 岩壁外侧护栏 · 山间维修站", treeBudget = 68, water = false, traffic = true,
        goalNames = {"第一折返", "岩壁发卡", "云上横贯", "山顶救援站", "长下坡", "山脚回程"},
        points = {{0,38,-80},{0,41,100},{-180,54,244},{-468,72,280},{-558,79,358},{-468,85,436},
            {-180,102,466},{-78,111,544},{-180,118,628},{-468,136,664},{-558,144,742},
            {-444,152,832},{-120,166,892},{192,177,1000},{420,164,880},{516,143,640},
            {564,115,340},{516,84,40},{360,59,-236},{144,41,-332},{0,38,-248}}},
    {id = "coast", aiLevel = 0.72, laps = 3, reward = 38, price = 2200, requires = "lake", name = "海岸巡航", theme = "coast", accent = {77, 173, 217}, width = 16.0, shoulder = 3.4,
        description = "滨海长弯 · 沙滩海岬 · 内陆村落回环", treeBudget = 76, water = true, traffic = true,
        goalNames = {"滨海入口", "潮汐湾", "海岬长弯", "海岸驿站", "内陆坡道", "灯塔回望"},
        points = {{0,16,-100},{0,17,125},{-175,19,312},{-356,23,512},{-394,29,825},
            {-325,36,1138},{-100,40,1312},{212,36,1350},{425,29,1162},{481,24,875},
            {362,27,625},{462,33,362},{438,29,100},{269,21,-188},{81,16,-325},{0,16,-250}}},
    {id = "canyon", aiLevel = 0.86, laps = 5, reward = 46, price = 4200, requires = "alpine", name = "沙漠峡谷", theme = "canyon", accent = {221, 158, 92}, width = 17.0, shoulder = 3.6,
        description = "干涸河谷 · 台地岩柱 · 宽幅高速弧线", treeBudget = 0, water = false, traffic = true,
        goalNames = {"干河床", "赤岩走廊", "双台地", "峡谷维修点", "风蚀长弯", "沙丘回程"},
        points = {{0,24,-60},{0,25,182},{-126,31,400},{-402,43,515},{-644,56,688},
            {-713,61,929},{-518,65,1113},{-253,59,1090},{-34,47,894},{207,39,940},
            {483,34,1136},{747,29,1032},{816,25,745},{690,26,446},{500,31,228},
            {610,34,-25},{483,29,-278},{218,24,-382},{0,24,-267}}},
    {id = "forest", aiLevel = 0.80, laps = 4, reward = 50, price = 3400, requires = "coast", name = "森林拉力", theme = "forest", accent = {114, 172, 112}, width = 13.5, shoulder = 2.8,
        description = "林间窄路 · 连续S弯 · 拉力集结区", treeBudget = 202, water = false, traffic = true,
        goalNames = {"林间起跑", "橡树林S弯", "林场发卡", "山脊林道", "木屋集结区", "林缘冲刺"},
        points = {{0,27,-80},{0,29,64},{-132,34,184},{-336,40,208},{-426,47,352},
            {-360,55,532},{-516,63,700},{-480,70,892},{-288,73,1000},{-102,68,898},
            {78,62,1000},{312,53,904},{396,46,700},{264,42,508},{396,38,316},
            {348,34,88},{210,29,-56},{132,27,-260},{0,27,-308},{-48,27,-188}}},
    {id = "circuit", aiLevel = 0.62, laps = 5, reward = 30, price = 0, requires = "default", name = "封闭赛车场", theme = "circuit", accent = {232, 100, 94}, width = 18.0, shoulder = 4.0,
        description = "专用赛道 · 技术内场 · 红白路缘与维修区", treeBudget = 28, water = false, traffic = false,
        goalNames = {"主看台直道", "北侧大弯", "内场技术弯", "后场直道", "南侧回头弯", "维修区入口"},
        points = {{0,18,-120},{0,18,140},{0,18,426},{-84,19,628},{-312,20,692},
            {-533,20,608},{-611,19,400},{-494,19,250},{-273,20,283},{-176,20,186},
            {-286,19,82},{-514,18,68},{-637,18,-94},{-592,18,-341},{-390,18,-452},
            {-143,18,-426},{0,18,-289}}},
}

local function clamp(v, a, b) return math.max(a, math.min(b, v)) end
local function catmull(a, b, c, d, t, axis)
    return 0.5 * (2*b[axis] + (-a[axis]+c[axis])*t
        + (2*a[axis]-5*b[axis]+4*c[axis]-d[axis])*t*t
        + (-a[axis]+3*b[axis]-3*c[axis]+d[axis])*t*t*t)
end

-- Inspect actual sampled strips, not just control polygons: uniform 2.4m arc resampling,
-- wrapped tangent at the seam; the duplicate last point has exactly the first point's normal.
---@param points number[][]
---@param closed boolean
---@return ScenicSample[], number
function Tracks.Sample(points, closed)
    local dense = {}
    local count = #points
    for i = 1, closed and count or count-1 do
        local function point(k) return points[closed and ((k-1)%count+1) or clamp(k,1,count)] end
        local a,b,c,d = point(i-1),point(i),point(i+1),point(i+2)
        for j = 0, 63 do
            local t = j/64
            dense[#dense+1] = {x=catmull(a,b,c,d,t,1), y=catmull(a,b,c,d,t,2), z=catmull(a,b,c,d,t,3), s=0}
        end
    end
    local last = closed and points[1] or points[count]
    dense[#dense+1] = {x=last[1],y=last[2],z=last[3],s=0}
    local length = 0
    for i = 2,#dense do
        local a,b = dense[i-1],dense[i]
        length = length + math.sqrt((a.x-b.x)^2+(a.z-b.z)^2)
        b.s = length
    end
    local n = math.ceil(length/2.4)
    local cursor = 1
    ---@type ScenicSample[]
    local samples = {}
    for i = 0,n do
        local s = length*i/n
        while cursor < #dense-1 and dense[cursor+1].s < s do cursor=cursor+1 end
        local a,b = dense[cursor],dense[cursor+1]
        local t = (s-a.s)/math.max(0.00001,b.s-a.s)
        samples[#samples+1] = {x=a.x+(b.x-a.x)*t,y=a.y+(b.y-a.y)*t,z=a.z+(b.z-a.z)*t,s=s,rx=1,rz=0}
    end
    for i,p in ipairs(samples) do
        local a,b = samples[math.max(1,i-1)],samples[math.min(#samples,i+1)]
        if closed and (i==1 or i==#samples) then a,b=samples[#samples-1],samples[2] end
        local dx,dz=b.x-a.x,b.z-a.z
        local mag=math.sqrt(dx*dx+dz*dz)
        p.rx,p.rz=dz/mag,-dx/mag
    end
    return samples,length
end

---@type table<string, TrackDefinition>
local byId = {}
for _,track in ipairs(definitions) do
    track.samples,track.length=Tracks.Sample(track.points,true)
    track.preview={}
    for i=0,96 do
        local s=track.length*i/96
        local k=math.min(#track.samples-1,math.floor(i/96*(#track.samples-1))+1)
        local a,b=track.samples[k],track.samples[k+1]
        local t=(s-a.s)/(b.s-a.s)
        track.preview[#track.preview+1]={x=a.x+(b.x-a.x)*t,z=a.z+(b.z-a.z)*t}
    end
    byId[track.id]=track
end

---@return TrackDefinition[]
function Tracks.List() return definitions end
---@param id string
---@return TrackDefinition?
function Tracks.Get(id) return byId[id] end

return Tracks
