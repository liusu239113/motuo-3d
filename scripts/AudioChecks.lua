-- 无声契约检查：fake Sound/Source，只调用生产混音逻辑，不开音频设备、不写档。
local Checks={}
local function source()
    local result={gain=0,frequency=0,playing=false,plays=0,stops=0}
    function result:Play(sound,frequency,gain,panning)
        self.plays=self.plays+1; self.playing=true
        self.sound,self.frequency,self.gain,self.panning=sound,frequency,gain,panning
    end
    function result:StopImmediate() self.playing=false; self.gain=0; self.stops=self.stops+1 end
    function result:Stop() self:StopImmediate() end
    return result
end
local function sound(length,frequency)
    return {GetLength=function() return length or 3 end,GetFrequency=function() return frequency or 48000 end}
end
local function raceFixture(Audio)
    local race={events={},eventSeq=0,phase="racing",racers={
        {id="player",isPlayer=true,x=0,z=0},{id="ai1",isPlayer=false,x=3,z=0},
        {id="ai2",isPlayer=false,x=5,z=0},{id="ai3",isPlayer=false,x=100,z=0}}}
    local sources,sounds={},{}
    for i=1,10 do
        sources[i]=i>7 and sources[7] or source()
        sounds[i]=sound(3+i*.1)
    end
    local instance=setmetatable({sources=sources,sounds=sounds,stopped=false,unlocked=true,
        effectsEnabled=true,currentRace=race,lastSeq=0,curseTimer=0,curseIndex=0,lastSpeakerId="",musicDuck=1,
        node={Dispose=function() end}},{__index=Audio})
    local function emit(kind,a,b)
        race.eventSeq=race.eventSeq+1
        race.events[#race.events+1]={kind=kind,racerId=a or "",targetId=b or "",seq=race.eventSeq}
    end
    return instance,race,emit,sources
end

function Checks.Race(Audio)
    Audio=Audio or require("RaceAudio")
    local a,race,emit,sources=raceFixture(Audio)
    local sim={x=0,z=0}
    local function update(dt,active) a:Update(dt or .02,sim,race,active) end
    emit("contact","player"); update()
    assert(sources[4].plays==1 and sources[7].plays==0,"玩家独撞障碍不得触发无关对手语音")
    emit("contact","player","ai1"); update()
    assert(sources[7].plays==1 and a.lastSpeakerId=="ai1" and a:GetMusicDuck()==.4,"受撞AI发言并输出音乐duck系数")
    local voiceIndex=a.curseIndex+7
    assert(sources[7].sound==a.sounds[voiceIndex] and sources[7].frequency==0,"原速语音资源必须对应真实发言者")
    assert(a.curseTimer>=a.sounds[voiceIndex]:GetLength()+.18,"冷却不得短于素材时长加留白")
    emit("contact","ai2","player"); update(1.3)
    assert(sources[7].plays==1,"大于旧1.2秒冷却但台词尚未结束时不得重叠")
    emit("contact","ai1","ai2"); update(10)
    assert(a.curseTimer==0 and sources[7].plays==1,"音频线程仍playing时计时过期也不得抢播")
    sources[7].playing=false
    emit("contact","ai1","ai2"); update()
    assert(sources[7].plays==2 and a.lastSpeakerId=="ai2","AI互撞优先真实target发言")
    a:Silence()
    emit("contact","ai2","player"); update()
    assert(a.lastSpeakerId=="ai2" and sources[7].plays==3,"target玩家时由另一位碰撞AI发言")
    a:Silence()
    local index=a.curseIndex
    emit("contact","player","ai2"); update()
    assert(a.curseIndex==index,"同一车手声音不随事件seq或碰撞另一方改变")
    a:Silence()
    local count=sources[7].plays
    emit("contact","ai1","ai3"); update()
    assert(sources[7].plays==count,"距离按发言者而不是附近的另一参与者判断")
    emit("bash","ai1","player"); update()
    assert(sources[7].plays==count,"主动攻击玩家的AI不得冒充受击者抱怨")
    emit("contact","player","missing"); update()
    assert(sources[7].plays==count,"未知ID不得被猜成对手")
    emit("contact","player","ai1"); update()
    local before=sources[7].plays
    emit("contact","player","ai2"); update(.02,false)
    assert(not sources[7].playing and a:GetMusicDuck()==1 and a.lastSeq==race.eventSeq,"inactive立即静音、恢复duck并消费序号")
    update()
    assert(sources[7].plays==before,"暂停历史碰撞不得恢复补播")
    for _,mode in ipairs({"locked","muted","sim-paused","zero","nan"}) do
        a.unlocked=mode~="locked"; a.effectsEnabled=mode~="muted"; sim.paused=mode=="sim-paused"
        emit("contact","player","ai1")
        update(mode=="zero" and 0 or mode=="nan" and 0/0 or .02)
        a.unlocked,a.effectsEnabled,sim.paused=true,true,false
        update()
        assert(sources[7].plays==before and a.lastSeq==race.eventSeq,mode.."不发声、不补播")
    end
    emit("contact","player","ai1"); update()
    assert(sources[7].plays==before+1)
    sources[7].playing=false
    update(.1)
    assert(a:GetMusicDuck()>.4 and a:GetMusicDuck()<1,"台词结束应平滑恢复音乐而不是永久duck")
    a:SetEffectsEnabled(false)
    assert(a:GetMusicDuck()==1 and a.curseTimer==0,"关闭音效立即释放语音与duck")
    a:SetEffectsEnabled(true)
    emit("contact","player","ai1"); a:Reset(race); update()
    assert(sources[7].plays==before+1,"Reset消费事件，不补播")
    local first=sources[1]
    assert(a:LoadOne(1) and a.sources[1]==first,"重复LoadOne不能重建已载入source")
    a:Stop(); a:Stop(); update()
    assert(a.stopped and next(a.sources)==nil and a:GetMusicDuck()==1,"释放幂等并清理duck")
    print("[AudioChecks] Race PASS 发言者/障碍静音/单通道/素材时长/playing兜底/暂停/设置/duck/释放；无实际试听")
    return true
end

function Checks.Career(Audio)
    Audio=Audio or require("Career.Audio")
    local sources,sounds={},{}
    for _,key in ipairs({"music","musicDay","city","engine","ring","order","steps"}) do
        sources[key]=source(); sounds[key]=sound(1,44100)
    end
    local a=setmetatable({sources=sources,sounds=sounds,unlocked=true,disposed=false,paused=false,
        musicEnabled=true,effectsEnabled=true,phoneSource=source(),stepState=Audio.NewStepState(),
        stepDistance=0,stepCount=0,orderCount=0,lastOrder="",node={Dispose=function() end}},{__index=Audio})
    a:Loop("city",.2,1,.1); a:Loop("city",.2,1,.1)
    assert(sources.city.plays==1 and sources.city.frequency==44100,"循环只能启动一次并使用绝对Hz")
    local original=sources.city
    a.effectsEnabled=false; a:Loop("city",.2,1,.1)
    assert(not sources.city.playing and sources.city.gain==0,"关闭环境音立即静音，不慢淡出数秒")
    a:Loop("music",.1,1,.1)
    assert(sources.music.playing and a.musicEnabled,"音效静音不改变音乐设置")
    a.musicEnabled=false; a:Loop("music",.1,1,.1)
    assert(not sources.music.playing and sources.music.gain==0,"关闭音乐立即静音")
    a.effectsEnabled=true; a:Loop("city",.2,1,.1)
    assert(sources.city==original and sources.city.plays==2,"恢复复用原source，不重建")
    a:Loop("city",.2,1,0)
    assert(not sources.city.playing,"无效步长不能继续在播循环")
    a:Loop("ring",.5,1,.1)
    assert(sources.ring.plays==0,"一次性铃声不能误走循环接口")
    a:PhoneRing(); a:PhoneRing()
    assert(a.phoneSource.plays==1,"同一铃声在播时不得重启/叠播")
    -- Session的只读审计发现：帧入口按旧IsBlocking执行SetPaused(false)，
    -- 随后OpenPhone/ShowDialog早退不会再走Audio.Update。这里仅检验音频接缝契约，
    -- 不伪称运行了Session输入分支；阻塞入口必须同步补SetPaused(true)。
    a:Loop("city",.2,1,.1)
    a:SetPaused(false)
    assert(sources.city.playing and sources.city.gain>0,"仅旧状态SetPaused(false)不能停止已在播尾音")
    local worldSource,phoneSource=sources.city,a.phoneSource
    a:SetPaused(true)
    assert(sources.city==worldSource and a.phoneSource==phoneSource,"阻塞切换不得重建世界/电话source")
    assert(a.phoneSource.playing,"阻塞通话页暂停世界不能截断独立电话")
    for _,s in pairs(sources) do assert(not s.playing and s.gain==0,"世界暂停必须静音所有普通通道") end
    a:StopPhone(); assert(not a.phoneSource.playing,"真实Pause/loading显式StopPhone必须静音")
    a:Once("tap") -- 缺少UI点击资源也应安全。
    a:Update(.1,nil,true,false,{}, {id="blocked-order"})
    assert(a.lastOrder=="blocked-order" and a.orderCount==0,"阻塞仍须消费订单基线")
    a:Stop(); a:Stop(); a:Unlock(); a:PhoneRing(); a:StopPhone()
    assert(a.disposed and not a.unlocked and a.phoneSource==nil and a.node==nil,"Stop后不得解锁重播或持有废弃source")
    assert(not a.musicEnabled and a.effectsEnabled,"暂停/Stop不能篡改用户音量开关")
    print("[AudioChecks] Career PASS 循环Hz/单次启动/开关立即静音/独立电话/暂停/基线/幂等释放；无实际试听")
    return true
end
-- 可传现有真实实例核验资源/API状态；不创建source、不调用Play、不改变音量设置。
function Checks.Loaded(raceAudio,careerAudio)
    if raceAudio then
        local unique,total={},0
        for index=1,10 do
            local clip,channel=assert(raceAudio.sounds[index]),assert(raceAudio.sources[index])
            assert(clip:GetLength()>0 and clip:GetFrequency()>0,"素材须有有效时长/采样率")
            assert(clip:IsLooped()==(index==1),"仅警笛允许循环，语音/短效果不能循环")
            if index>=7 then assert(channel==raceAudio.sources[7],"四条语音必须共享单source") end
            if not unique[channel] then unique[channel]=true; total=total+1 end
        end
        assert(total==7,"竞速只能创建六效果加一语音source")
    end
    if careerAudio then
        local oneShot={steps=true,sand=true,wood=true,tap=true,order=true,ring=true,horn=true,complaint=true}
        for key,clip in pairs(careerAudio.sounds) do
            assert(clip:GetLength()>0 and clip:GetFrequency()>0)
            assert(clip:IsLooped()==not oneShot[key],"循环标记属于Sound且须匹配单次/循环分类")
        end
    end
    return true
end
-- 调用真实Session方法，但使用fake view/source与内存Store；不创建城市/音频设备。
-- 默认在引擎内显式调用；纯Lua调用方可传入隔离env加载的Session和Store。
-- 不改package.loaded、input全局或真实档案；非交互检查时不要按ESC。
function Checks.SessionTransitions(Session,Store,Audio)
    Session=Session or require("Career.Session")
    Store=Store or require("Career.Store")
    Audio=Audio or require("Career.Audio")
    local files={}
    Store.WithTestStorage({read=function(path) return files[path],nil,files[path]==nil end,
        write=function(path,text) files[path]=text; return true end},function()
        assert(Store.NewCareer())
        assert(Store.Transaction(function(p) p.flags.stayed_hostel=true; return true end))
        local world,phone=source(),source()
        local mix=setmetatable({sources={city=world},sounds={city=sound()},phoneSource=phone,
            paused=false,disposed=false,unlocked=true,musicEnabled=true,effectsEnabled=true,
            stepState=Audio.NewStepState(),stepDistance=0},{__index=Audio})
        local view={blocked=false,phonePage="",storyOpened=false,
            controls={UpdateFeedback=function() end},
            IsBlocking=function(self) return self.blocked or self.phonePage~="" end,
            OpenPhone=function(self,page) self.phonePage=page end,
            ShowDialog=function(self) self.blocked=true; self.storyOpened=true end,
            UpdateSpeech=function() end,LayoutControls=function() end}
        local fixture=setmetatable({audio=mix,view=view,running=true,loading=false,disposed=false,
            options={test=false},actor={x=0,z=0,speed=0},space="city",storyTimer=.49,
            city={UpdateStreaming=function() end,contacts={Update=function() end}},
            State=function() return {} end},{__index=Session})
        local function playing()
            mix:SetPaused(false); mix:Loop("city",.2,1,.1); phone:Play(sound(),0,.24)
            assert(world.playing and phone.playing)
        end
        playing()
        Session.OpenPhone(fixture,"apps")
        assert(view.phonePage=="apps" and not world.playing and world.gain==0,
            "Session.OpenPhone须在同帧停止世界音频，不能等下一帧Update")
        assert(phone.playing,"打开手机不能隐式StopPhone；通话铃声有独立生命周期")
        view.phonePage=""; view.blocked=false
        playing()
        Session.Update(fixture,.02)
        assert(view.storyOpened,"必须实际经过Session.Update故事早退分支（检查时勿按ESC）")
        assert(not world.playing and world.gain==0,
            "故事ShowDialog早退须同帧暂停；帧入口的旧IsBlocking不能覆盖后续新阻塞")
        assert(phone.playing,"Session世界暂停不截断电话；真实View.ShowDialog负责endCall")
        assert(mix.sources.city==world and mix.phoneSource==phone and mix.musicEnabled and mix.effectsEnabled,
            "同帧暂停不得重建source或篡改用户设置")
    end)
    print("[AudioChecks] Session PASS 真实OpenPhone/Update故事早退同帧静音，fake音源/内存档；非声卡验收")
    return true
end
-- 27车型全量无声测试，调用真实RideAudio逻辑；fixture不接触cache/音频设备。
function Checks.Ride(Audio)
    Audio = Audio or require("RideAudio")
    local catalog = Audio.Catalog
    local node = {Dispose = function(self) self.disposed = true end}
    function node:CreateChild() return self end
    function node:CreateComponent() return source() end
    local a = Audio.New(node --[[@as Scene]])
    for i, path in ipairs(Audio.Resources) do
        local clip = sound(3, 48000)
        a.sounds[i], a.resourceSounds[path] = clip, clip
        if i <= 6 then assert(a:LoadOne(i)) end
    end
    local engine = a.sources[2]
    a.unlocked, a.musicEnabled = true, false
    local sim = {speed=20,rpm=5000,throttle=.5,braking=false,health=100,overtakes=0,elapsed=1,
        finished=false,vehicleId="sport",oddSerial=0,motorcycleSkillSerial=0,oddActive=0,motorcycleActive=0}
    local count, paths, skillCount = 0, {}, 0
    local function update(dt, screen) a:Update(dt == nil and .02 or dt, sim, screen or "ride") end
    local function silent()
        assert(not a.skillSource.playing and a.skillSource.gain == 0 and a.skillTimer == 0,"技能必须立即停音")
        for i=2,6 do assert(not a.sources[i].playing and a.sources[i].gain == 0,"驾驶source必须立即停音") end
    end
    for _, id in ipairs(catalog.Ids) do
        local entry = catalog.Vehicles[id]
        count = count + 1
        assert(not paths[entry.drive],"27车型必须真实不同路径而不是pitch伪造："..id)
        paths[entry.drive] = true
        assert(Audio.ResourceTypes[entry.drive] == "Sound" and Audio.EngineResources[id] == entry.drive)
        sim.vehicleId,sim.oddSerial,sim.motorcycleSkillSerial = id,0,0
        sim.oddActive,sim.motorcycleActive = 0,0
        local previous = a.skillSource.plays
        update()
        assert(a.sources[2] == engine and a.sounds[2] == a.resourceSounds[entry.drive],"换车须更换真实素材并复用source")
        assert(a.skillSource.plays == previous,"换车只建基线")
        sim.oddSerial,sim.motorcycleSkillSerial = count <= 9 and 0 or 1,count <= 9 and 1 or 0
        sim.oddActive,sim.motorcycleActive = count <= 9 and 0 or 2,count <= 9 and 2 or 0
        update()
        local expected = entry.skillOwner == "RideAudio" and 1 or 0
        assert(a.skillSource.plays == previous + expected,"成功激活应播一次，保护车/武器车不能叠播："..id)
        if expected == 1 then
            skillCount = skillCount + 1
            assert(a.skillSource.sound == a.resourceSounds[entry.skill],"车型技能实际播放路径必须正确")
            assert(a.skillSource.frequency == 48000 * entry.skillPitch,"技能频率必须是绝对Hz")
        end
        for _=1,100 do update(.02) end
        assert(a.skillSource.plays == previous + expected and a.skillTimer == 0,"连续帧不得重复，循环借用素材必须结束")
        sim.speed,sim.throttle = 0,0
        update()
        if entry.motion == "rolling" or entry.motion == "organic" then
            assert(not engine.playing and engine.gain == 0,"非机动静止不能有摩托怠速")
        end
        sim.speed,sim.throttle = 20,.5
    end
    assert(count == 27 and skillCount == 23,"27行驶，23个Ride技能，3保护+1武器归原系统")
    sim.vehicleId,sim.oddSerial,sim.motorcycleSkillSerial = "sport",0,0
    update()
    local function trigger()
        sim.motorcycleSkillSerial=sim.motorcycleSkillSerial+1;sim.motorcycleActive=2
    end
    for _, mode in ipairs({"pause","menu","result","muted","locked","zero","nan","sim-paused","finished"}) do
        trigger(); update()
        assert(a.skillSource.playing,"阻断前必须真的在播")
        local before = a.skillSource.plays
        trigger()
        a.effectsEnabled, a.unlocked = mode ~= "muted", mode ~= "locked"
        sim.paused,sim.finished = mode == "sim-paused",mode == "finished"
        update(mode == "zero" and 0 or mode == "nan" and 0/0 or .02,
            (mode=="pause" or mode=="menu" or mode=="result") and mode or "ride")
        silent()
        a.effectsEnabled,a.unlocked,sim.paused,sim.finished = true,true,false,false
        update()
        assert(a.skillSource.plays == before,mode.."必须消费序号，恢复不得补播")
    end
    trigger(); update()
    a:ToggleEffects(); silent()
    trigger(); update(); a:ToggleEffects()
    local before = a.skillSource.plays
    update(); assert(a.skillSource.plays == before,"ToggleEffects恢复不补播")
    trigger(); update()
    a:Reset(sim); silent(); before=a.skillSource.plays
    update(); assert(a.skillSource.plays==before,"Reset消费基线")
    trigger(); update(); assert(a.skillSource.plays==before+1)
    sim.elapsed,sim.motorcycleSkillSerial=0,0;update()
    trigger(); update(); assert(a.skillSource.plays==before+2,"原地重开后新的序号可播")
    trigger(); sim.motorcycleActive=0;before=a.skillSource.plays;update()
    assert(a.skillSource.plays==before,"取消激活不得播音")
    -- 已停止实例、换仿真、dt无效均不应重播。
    local skill = a.skillSource
    trigger();update();a:Stop();a:Stop();before=skill.plays
    a:Update(.02,sim,"ride")
    assert(skill.plays==before and not skill.playing and a.skillSource==nil and a.node==nil)
    print("[AudioChecks] Ride PASS 27独立路径/23技能/保护三车/武器不双播/Hz/暂停菜单结果静音/Reset/Stop；fake音源无实际试听")
    return {passed=true,vehicles=count,skills=skillCount}
end

-- 真引擎资源加载检查：只加载和换槽，不解锁、不Play；完整解码另用ffmpeg离线检查。
function Checks.RideLoaded(a)
    local Audio=require("RideAudio")
    local seen={}
    for i,path in ipairs(Audio.Resources) do
        assert(not seen[path],"资源清单重复："..path);seen[path]=true
        assert(Audio.ResourceTypes[path]=="Sound")
        assert(a:LoadOne(i),"声音不可加载："..path)
        local clip=assert(a.resourceSounds[path])
        assert(clip:GetLength()>0 and clip:GetFrequency()>0 and clip:GetDataSize()>0,"无有效音频数据："..path)
    end
    local loader=require("RideLoader").New(Audio.Resources,function() end,function() end,function() end,
        Audio.GetResources() --[[@as string[] ]],Audio.ResourceTypes)
    local types={}
    for _,item in ipairs(loader.verify) do types[item[2]]=item[1] end
    for path in pairs(seen) do assert(types[path]=="Sound","RideLoader验证类型不是Sound："..path) end
    for _,id in ipairs(Audio.Catalog.Ids) do
        assert(a:SetVehicle(id))
        local entry=Audio.Catalog.Vehicles[id]
        assert(a.sounds[2]==a.resourceSounds[entry.drive] and a.sounds[2]:IsLooped())
        assert(not a.sources[2].playing,"资源准备绝不能自动发声")
    end
    print("[AudioChecks] RideLoaded PASS "..#Audio.Resources.." Sound资源/27车型/Loader类型，未解锁未播放")
    return {passed=true,resources=#Audio.Resources,vehicles=27}
end

function Checks.Run()
    assert(Checks.Race() and Checks.Career() and Checks.Ride().passed)
    return {passed=true}
end
return Checks
