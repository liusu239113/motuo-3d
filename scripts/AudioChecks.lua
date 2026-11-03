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
function Checks.Run()
    assert(Checks.Race() and Checks.Career())
    return {passed=true}
end
return Checks
