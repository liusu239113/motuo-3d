-- Dedicated garage acceptance. No main/HUD/Profile, saves, audio, AI or generated media.
-- Runtime stdout includes measured local cold assembly vs resident hot selection (not CDN latency).
assert(cache:AddResourceDir("/workspace/assets", false))
assert(cache:AddResourceDir("/workspace/scripts", false))
cache.searchPackagesFirst = false
local UI = require("urhox-libs/UI")
local Preview = require("GaragePreview")
local Assets = require("VehicleAssets")
---@type GaragePreview?
local preview_ = nil
local stage_, started_, cpuStart_, frameStart_, assertions_ = 0, 0, 0, 0, 0
local finished_ = false
---@type table<string, Node>
local nodes_ = {}
---@type Scene?
local scene_ = nil
---@type Texture2D?
local texture_ = nil
---@type Camera?
local camera_ = nil
local function check(ok, message)
    assert(ok, "[GaragePreviewCheck] " .. message)
    assertions_ = assertions_ + 1
end
local function source(path)
    local file = assert(cache:GetFile(path))
    local lines = {}
    while not file:IsEof() do lines[#lines + 1] = file:ReadLine() end
    file:Dispose()
    return table.concat(lines, "\n")
end
local function queueChecks()
    local text = source("PreviewCache.lua")
    local function fixture(remote)
        ---@type any
        local state = {groups={}, cancelled=0, downloads=0, loads=0, builds=0, ready=0, failed=0, disposed=0, remote=remote}
        ---@type any
        local assets = {Vehicles={}, ResourceTypes={}}
        for i = 1, 27 do assets.Vehicles["car" .. i] = true end
        function assets.ResourcesFor(ids) return {ids[1] .. ".mdl", ids[1] .. ".png"} end
        ---@type any
        local fakeCache = {}
        function fakeCache:Exists() return not state.remote end
        function fakeCache:DownloadResources(paths, callback)
            state.downloads = state.downloads + 1
            local id = state.downloads
            state.groups[id] = callback
            return id
        end
        function fakeCache:CancelDownloadGroup(id)
            state.cancelled = state.cancelled + 1
            state.groups[id](false, 1) -- inline cancellation exercises invalidate-before-cancel
        end
        function fakeCache:GetResourceAsync(_, _, callback)
            state.loads = state.loads + 1
            if state.defer then state.callback = callback else callback({}) end
        end
        local environment = setmetatable({cache=fakeCache, require=function(name)
            assert(name == "VehicleAssets"); return assets
        end}, {__index=_G})
        local module = assert(load(text, "@PreviewCache.lua (queue isolation)", "t", environment))()
        local owner = module.New {limit=12, commonPaths={}, commonTypes={},
            build=function(entry)
                state.builds = state.builds + 1
                entry.content = {Dispose=function() state.disposed = state.disposed + 1 end}
            end,
            ready=function() state.ready = state.ready + 1 end,
            failed=function() state.failed = state.failed + 1 end}
        return owner, state
    end
    local function drain(owner, state, steps)
        for _ = 1, steps do
            local loads, builds = state.loads, state.builds
            owner:Update()
            check(state.loads - loads <= 4, "foreground resource budget <=4/update")
            check(state.builds - builds <= 1, "formal assembly budget <=1/update")
            check(owner.count <= 12, "bounded entries <=12")
        end
    end
    local c, s = fixture(false)
    c:Request("car1", 1)
    local all = {}
    for i=1,27 do all[#all+1] = "car" .. i end
    c:Prewarm(all)
    check(s.loads==0 and s.builds==0 and s.downloads==0, "Prewarm27 performs zero eager work")
    drain(c,s,100)
    check(c.count==12 and c.builds==12 and s.builds==12, "Prewarm27 settles at exactly12, no eviction thrash")
    for _=1,20 do c:Update() end
    check(s.builds==12 and c.evictions==0, "settled prewarm cannot rebuild/evict itself")
    local original=c.entries.car1
    check(c:Request("car1",2)==original and c.hits==1, "hot node identity reused")
    c:Prewarm({"car13","car14"})
    drain(c,s,25)
    check(c.count==12 and c.evictions==2 and c.entries.car1==original, "LRU replaces stale nodes, pins selected")
    c:Dispose();c:Dispose()
    check(c.count==0 and s.disposed==14 and s.failed==0, "all owned nodes disposed exactly once")
    local remote, r = fixture(true)
    remote:Prewarm({"car1","car2"})
    remote:Update();remote:Update()
    check(r.downloads==2 and remote.peakActive==2, "two download pipelines maximum")
    remote:Request("car3",3)
    remote:Update()
    check(r.cancelled==1 and r.downloads==3, "new foreground preempts speculative slow download")
    check(r.failed==0, "cancel completion cannot fail current selection")
    remote:Dispose()
    for _,callback in pairs(r.groups) do callback(true,0) end
    check(remote.count==0 and r.ready==0 and r.failed==0, "late download callbacks after exit are inert")
    local pending,p=fixture(false)
    pending:Request("car1",1);p.defer=true;pending:Update()
    local callback=p.callback
    pending:Dispose();callback({})
    check(pending.count==0 and p.ready==0 and p.builds==0, "late resource callback after exit is inert")
    local superseded,t=fixture(false)
    superseded:Request("car1",1);t.defer=true;superseded:Update()
    local oldCallback=t.callback
    superseded:Request("car2",2)
    oldCallback({})
    t.defer=false;drain(superseded,t,4)
    check(t.ready==1 and superseded.entries.car1==nil and superseded.entries.car2.requestToken==2,
        "superseded async resource cannot resurrect old selected vehicle")
    superseded:Dispose()
    local failure,f=fixture(false)
    failure:Request("car1",1)
    f.defer=true;failure:Update();f.callback(nil)
    check(f.failed==1 and failure.entries.car1.state=="failed", "resource failure is retryable")
    f.defer=false;failure:Request("car1",2);drain(failure,f,4)
    check(f.ready==1 and failure.entries.car1.requestToken==2, "retry has fresh request generation")
    failure:Dispose()
    print("[GaragePreviewCheck] queue PASS bounded27/LRU/preemption/inline-cancel/late-download/late-resource/retry")
end
---@param id string
local function select(id)
    local preview=assert(preview_)
    -- GetSystemTime has a divergent static binding in the CLI; GetElapsedTime is
    -- the supported instance monotonic wall clock, verified by this Runtime run.
    started_, cpuStart_, frameStart_ = GetTime():GetElapsedTime() * 1000, os.clock(), GetTime():GetFrameNumber()
    preview:Select(id,true)
end
---@param label string
local function measured(label)
    print(string.format("[GaragePreviewTiming] %s id=%s wall=%.3fms processCPU=%.3fms frames=%d builds=%d hits=%d",
        label,assert(preview_).vehicleId,GetTime():GetElapsedTime() * 1000-started_,(os.clock()-cpuStart_)*1000,
        GetTime():GetFrameNumber()-frameStart_,preview_.previewCache.builds,preview_.previewCache.hits))
end
function Start()
    queueChecks()
    UI.Init {theme="default-dark",scale=UI.Scale.DEFAULT}
    preview_=Preview.New {width="100%",height="100%"}
    UI.SetRoot(UI.Panel {width="100%",height="100%",children={preview_}})
    UI.Layout()
    stage_=1
    select("skateboard")
    SubscribeToEvent("Update","GaragePreviewCheckUpdate")
end
---@param _ string
---@param _ UpdateEventData
function GaragePreviewCheckUpdate(_,_)
    if finished_ then return end
    local preview=assert(preview_)
    assert(GetTime():GetElapsedTime() * 1000-started_<30000,"garage acceptance timeout stage "..stage_)
    if stage_==4 then
        if not preview.previewCache.entries.loader or preview.previewCache.entries.loader.state~="ready" then return end
        local before=preview.previewCache.builds
        local begin=os.clock()
        preview:Select("loader",true)
        print(string.format("[GaragePreviewTiming] prewarmed-select loader synchronousCPU=%.3fms",(os.clock()-begin)*1000))
        check(preview.state=="ready" and preview.previewCache.builds==before,"prewarmed page selects synchronously without assembly")
        stage_=5
    end
    if preview.state~="ready" or preview.renderGeneration~=preview.generation then return end
    local entry=assert(preview.displayEntry)
    local node=assert(entry.content)
    check(preview.riderRig==nil and #assert(preview.previewScene):GetComponents("AnimatedModel",true)==0,"vehicle-only, no person assets/nodes")
    check(math.abs(node.position.y)<.00001,"canonical mixed groundY remains zero")
    check(assert(entry.vehicle):GetVar("FormalModel"):GetString()==Assets.Vehicles[preview.vehicleId].model,"actual original MDL assembled")
    if stage_==1 then
        measured("cold-local-first-use")
        scene_,texture_,camera_=preview.previewScene,preview.previewTexture,preview.previewCamera
        nodes_.skateboard=node
        stage_=2;select("tank")
        check(not node.enabledSelf,"Select hides previous car immediately while new car loads")
        for _, snapshot in ipairs(assert(entry.visibility)) do
            check(not snapshot.drawable.enabled and snapshot.drawable.viewMask==0,"inactive cached drawable explicitly excluded from rendering")
        end
        check(preview.renderGeneration~=preview.generation,"old shared RT cannot display under new selection")
    elseif stage_==2 then
        measured("cold-local-first-use")
        nodes_.tank=node
        check(preview.previewScene==scene_ and preview.previewTexture==texture_ and preview.previewCamera==camera_,"shared scene/camera/RT survive different car size")
        stage_=3;select("skateboard")
        check(preview.state=="ready" and preview.displayEntry.content==nodes_.skateboard,"hot return reuses exact original nodes")
        measured("hot-select-synchronous")
    elseif stage_==3 then
        measured("hot-presentable")
        check(preview.previewCache.builds==2,"A/B/A did not re-extract or rebuild")
        stage_=4
        preview:Prewarm({"skateboard","loader","hovercraft"})
    elseif stage_==5 then
        check(preview.previewScene==scene_ and preview.previewTexture==texture_,"prewarm also reuses same native pipeline")
        local owner=preview.previewCache
        preview:Dispose()
        check(owner.count==0 and preview.previewScene==nil and preview.previewTexture==nil,"exit releases preview-owned resources")
        stage_=6;select("skateboard")
    elseif stage_==6 then
        check(preview.previewScene~=scene_ and preview.previewCache.count==1,"exit/reopen starts fresh preview owner")
        preview:Select("not_delivered",false)
        check(preview.state=="unavailable" and preview.displayEntry==nil,"unavailable vehicle never substitutes old model")
        preview:Dispose();finished_=true
        print(string.format("[GaragePreviewCheck] PASS assertions=%d; timings are local Runtime CPU+wall, not remote network or GPU first-pixel timing",assertions_))
    end
end
function Stop()
    if preview_ then preview_:Dispose() end
    UI.Shutdown()
end
