-- 六张闭合赛道共用同一套样条，导航、预览与路面网格不另作近似。
-- 长度沿水平里程累计；width 为沥青全宽，shoulder 初始化后为距中心线的外边界。
-- 控制点只改变另外五图；山湖公路保留原版线形与三圈赛事。
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
---@field shoulder number 距中心线的路肩外边界，初始化前为净路肩宽度
---@field shoulderMargin? number 净路肩宽度
---@field originalLength? number 原版真实采样里程
---@field originalLaps? integer 原版固定圈数
---@field checks? TrackReport
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
    {id = "alpine", aiLevel = 0.82, laps = 2, reward = 42, price = 2600, requires = "lake", name = "高山发卡", theme = "alpine", accent = {162, 192, 223}, width = 13.0, shoulder = 2.8,
        description = "六段折返攀升 · 云上横贯 · 岩壁与救援站", treeBudget = 68, water = false, traffic = true,
        goalNames = {"山脚连续弯", "西壁折返", "云上横贯", "山顶救援站", "山脊下降", "山脚回程"},
        points = {{0,38,-150},{0,40,80},{-210,53,215},{-570,69,255},{-785,80,340},
            {-760,88,460},{-530,98,490},{-240,110,510},{-135,118,610},{-270,128,715},
            {-620,141,750},{-850,152,835},{-795,163,970},{-535,177,1025},{-220,188,1025},
            {20,198,1130},{230,208,1340},{505,204,1370},{740,184,1200},{820,161,930},
            {695,141,720},{890,116,510},{950,92,245},{835,70,-5},{930,55,-280},
            {700,44,-500},{405,38,-525},{150,38,-400},{0,38,-320}}},
    {id = "coast", aiLevel = 0.72, laps = 2, reward = 38, price = 2200, requires = "lake", name = "海岸巡航", theme = "coast", accent = {77, 173, 217}, width = 16.0, shoulder = 3.4,
        description = "连续海湾长弯 · 双岬观景 · 内陆葡萄园与村落", treeBudget = 76, water = true, traffic = true,
        goalNames = {"滨海入口", "潮汐湾", "海岬观景台", "北湾灯塔", "内陆缓和弯", "村落冲刺"},
        points = {{0,16,-160},{0,17,75},{-175,19,245},{-350,23,420},{-382,28,665},
            {-310,34,845},{-375,38,1065},{-340,41,1260},{-160,43,1405},{90,40,1390},
            {270,34,1220},{490,30,1265},{725,32,1390},{955,36,1260},{1030,39,1000},
            {930,42,760},{705,44,640},{585,43,435},{730,38,240},{930,31,65},
            {870,25,-175},{625,21,-275},{425,19,-440},{200,16,-520},{30,16,-410}}},
    {id = "canyon", aiLevel = 0.86, laps = 2, reward = 46, price = 4200, requires = "alpine", name = "沙漠峡谷", theme = "canyon", accent = {221, 158, 92}, width = 17.0, shoulder = 3.6,
        description = "赤岩走廊与双台地 · 沙漠高速段 · 干河床连续弯", treeBudget = 0, water = false, traffic = true,
        goalNames = {"干河床", "赤岩走廊", "双台地", "峡谷补给站", "风蚀高速弯", "沙丘回程"},
        points = {{0,24,-180},{0,25,65},{-185,31,245},{-440,42,335},{-700,54,440},
            {-930,67,655},{-1020,76,925},{-925,82,1195},{-655,80,1370},{-375,71,1290},
            {-210,61,1090},{-25,51,915},{205,44,1005},{405,42,1260},{660,39,1380},
            {940,34,1245},{1070,30,985},{995,27,730},{780,28,565},{565,32,365},
            {610,36,140},{840,37,-70},{895,32,-335},{670,27,-535},{375,24,-565},
            {150,24,-450},{0,24,-345}}},
    {id = "forest", aiLevel = 0.80, laps = 2, reward = 50, price = 3400, requires = "coast", name = "森林拉力", theme = "forest", accent = {114, 172, 112}, width = 13.5, shoulder = 2.8,
        description = "林间连续S弯 · 林场折返 · 山脊林道与木屋集结区", treeBudget = 202, water = false, traffic = true,
        goalNames = {"林间起跑", "西林连续S弯", "林场折返", "山脊林道", "木屋集结区", "林缘冲刺"},
        points = {{0,27,-150},{0,29,60},{-180,35,200},{-425,41,215},{-570,48,365},
            {-510,56,555},{-730,64,725},{-835,72,930},{-700,80,1140},{-455,84,1180},
            {-275,81,1050},{-115,76,1190},{85,70,1380},{330,65,1355},{460,60,1160},
            {670,55,1085},{860,50,1200},{1020,46,1020},{1010,42,780},{810,40,640},
            {635,39,460},{770,37,260},{835,34,35},{670,30,-145},{405,28,-140},
            {300,27,-335},{110,27,-505},{-80,27,-400}}},
    {id = "circuit", aiLevel = 0.62, laps = 2, reward = 30, price = 0, requires = "default", name = "封闭赛车场", theme = "circuit", accent = {232, 100, 94}, width = 18.0, shoulder = 4.0,
        description = "加长主直道 · 双看台 · 复合技术弯与高速后场", treeBudget = 28, water = false, traffic = false,
        goalNames = {"主看台直道", "北侧复合弯", "内场技术弯", "后场高速段", "南侧回头弯", "维修区入口"},
        points = {{0,18,-200},{0,18,140},{0,18,490},{-80,19,825},{-305,20,1000},
            {-585,20,1040},{-840,19,885},{-940,19,635},{-810,19,430},{-575,20,405},
            {-360,20,480},{-220,20,365},{-300,19,210},{-565,18,165},{-835,18,140},
            {-1025,18,-60},{-1030,18,-340},{-845,18,-525},{-535,18,-540},{-245,18,-570},
            {80,18,-650},{390,18,-600},{620,18,-430},{680,18,-120},{620,18,200},
            {700,18,480},{635,18,810},{435,18,950},{245,18,800},{160,18,570},
            {190,18,300},{200,18,80},{155,18,-140},{220,18,-335},{100,18,-440},{-50,18,-400}}},
}

local function clamp(v, a, b) return math.max(a, math.min(b, v)) end
local function catmull(a, b, c, d, t, axis)
    return 0.5 * (2*b[axis] + (-a[axis]+c[axis])*t
        + (2*a[axis]-5*b[axis]+4*c[axis]-d[axis])*t*t
        + (-a[axis]+3*b[axis]-3*c[axis]+d[axis])*t*t*t)
end

-- 先以每段64点细分，再统一重采样为不超过2.4米的里程间隔。
-- 闭环最后一点的切线与首点完全一致，路面及两侧路肩在接缝共用截面。
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
local originalLengths={lake=4122.2,alpine=4798.3,coast=4267.0,canyon=5336.4,forest=4013.9,circuit=3764.8}
local originalLaps={lake=3,alpine=4,coast=3,canyon=5,forest=4,circuit=5}
for _,track in ipairs(definitions) do
    -- Landscape与赛事都消费绝对路带边缘，不能把净宽直接当作中心线偏移。
    track.shoulderMargin=track.shoulder
    track.shoulder=track.width*.5+track.shoulderMargin
    track.originalLength=originalLengths[track.id]
    track.originalLaps=originalLaps[track.id]
    track.samples,track.length=Tracks.Sample(track.points,true)
    -- 完整自交检测由 TrackChecks.Run 离线执行，不把数百万次投影塞进移动端启动帧。
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
