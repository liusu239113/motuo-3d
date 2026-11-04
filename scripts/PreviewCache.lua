-- Garage-owned bounded LRU and staged DWP queue. Never owns global source mesh/material caches.
-- Download callbacks only advance state; native loads and formal vehicle assembly run in Update.
local VehicleAssets = require("VehicleAssets")
local Cache = {}
Cache.__index = Cache

---@class GaragePreviewDrawable
---@field drawable StaticModel
---@field enabled boolean
---@field viewMask integer

---@class GaragePreviewEntry
---@field visibility? GaragePreviewDrawable[]
---@field id string
---@field state string
---@field paths string[]
---@field resources Resource[]
---@field group integer
---@field index integer
---@field pending boolean
---@field alive boolean
---@field stamp integer
---@field requestToken integer
---@field content? Node
---@field vehicle? Node
---@field size? Vector3
---@field radius? number
---@field error? string

function Cache.New(options)
    local self = setmetatable({}, Cache)
    self:Init(options)
    return self
end

function Cache:Init(options)
    self.options = options
    self.limit = options.limit or 12
    self.concurrent = 2
    self.clock, self.generation, self.count = 0, 0, 0
    self.selected, self.closed = "", false
    ---@type table<string, GaragePreviewEntry>
    self.entries = {}
    ---@type string[]
    self.wanted = {}
    self.builds, self.hits, self.evictions, self.peakActive = 0, 0, 0, 0
end

---@param entry GaragePreviewEntry
function Cache:Release(entry)
    -- Invalidate before CancelDownloadGroup: cancellation can invoke completion inline.
    entry.alive = false
    if entry.group > 0 then cache:CancelDownloadGroup(entry.group) end
    entry.group = 0
    if entry.content then entry.content:Dispose() end
    entry.content, entry.vehicle, entry.resources, entry.visibility = nil, nil, {}, nil
    self.entries[entry.id] = nil
    self.count = self.count - 1
end

---@param entry GaragePreviewEntry
function Cache:Touch(entry)
    self.clock = self.clock + 1
    entry.stamp = self.clock
end

---@param id string
---@return GaragePreviewEntry?
function Cache:Ensure(id)
    if self.closed or not VehicleAssets.Vehicles[id] then return nil end
    local found = self.entries[id]
    if found then return found end
    if self.count >= self.limit then
        ---@type GaragePreviewEntry?
        local oldest = nil
        local pinned = {[self.selected] = true}
        for _, key in ipairs(self.wanted) do pinned[key] = true end
        for _, entry in pairs(self.entries) do
            if not pinned[entry.id] and (not oldest or entry.stamp < oldest.stamp) then oldest = entry end
        end
        -- A foreground selection may replace the least-recent nonselected item
        -- before HUD supplies its new page. Prewarming never evicts its own intent.
        if not oldest and id == self.selected then
            for _, entry in pairs(self.entries) do
                if entry.id ~= self.selected and (not oldest or entry.stamp < oldest.stamp) then oldest = entry end
            end
        end
        if not oldest then return nil end
        self:Release(oldest)
        self.evictions = self.evictions + 1
    end
    local paths = VehicleAssets.ResourcesFor({id})
    for _, path in ipairs(self.options.commonPaths) do paths[#paths + 1] = path end
    ---@type GaragePreviewEntry
    local entry = {id=id, state="queued", paths=paths, resources={}, group=0, index=1,
        pending=false, alive=true, stamp=0, requestToken=0}
    self.entries[id] = entry
    self.count = self.count + 1
    self:Touch(entry)
    return entry
end

---@param id string
---@param token integer
---@return GaragePreviewEntry?
function Cache:Request(id, token)
    if self.closed then return nil end
    self.selected = id
    local wanted = {}
    for _, key in ipairs(self.wanted) do wanted[key] = true end
    local remove = {}
    for key, old in pairs(self.entries) do
        if key ~= id and not wanted[key] and old.state ~= "ready" then remove[#remove + 1] = old end
    end
    for _, old in ipairs(remove) do self:Release(old) end
    local entry = self.entries[id]
    if entry and entry.state == "failed" then self:Release(entry); entry = nil end
    entry = entry or self:Ensure(id)
    if not entry then return nil end
    self:Touch(entry)
    entry.requestToken = token
    if entry.state == "queued" then
        local active = 0
        ---@type GaragePreviewEntry?
        local victim = nil
        for key, candidate in pairs(self.entries) do
            if candidate.state == "downloading" or candidate.state == "loading" or candidate.state == "build" then
                active = active + 1
                if key ~= id then victim = candidate end
            end
        end
        -- Foreground admission never waits behind two speculative slow downloads.
        -- Its ID remains in wanted, so an interrupted prewarm may retry later.
        if active >= self.concurrent and victim then self:Release(victim) end
    end
    if entry.state == "ready" then self.hits = self.hits + 1 end
    return entry
end

-- Ordered replacement, not an append-only list: obsolete page jobs must not starve new selections.
---@param ids string[]
function Cache:Prewarm(ids)
    if self.closed then return end
    self.wanted = {}
    local keep = {[self.selected] = true}
    for _, id in ipairs(ids) do
        if not keep[id] and VehicleAssets.Vehicles[id] and #self.wanted < self.limit - 1 then
            keep[id] = true
            self.wanted[#self.wanted + 1] = id
        end
    end
    local remove = {}
    for id, entry in pairs(self.entries) do
        if not keep[id] and entry.state ~= "ready" then remove[#remove + 1] = entry end
    end
    for _, entry in ipairs(remove) do self:Release(entry) end
    -- Do not create/load/build vehicles here. Even an entirely local 27-car list is bounded.
end

---@param entry GaragePreviewEntry
function Cache:Fail(entry, message)
    entry.state, entry.error = "failed", message
    self.options.failed(entry, entry.requestToken)
end

---@param entry GaragePreviewEntry
function Cache:StartDownload(entry)
    entry.state = "downloading"
    local token = self.generation
    local pendingPaths = {}
    for _, path in ipairs(entry.paths) do
        if not cache:Exists(path) then pendingPaths[#pendingPaths + 1] = path end
    end
    local completed = false
    local function downloaded(success, failedCount)
        if self.closed or token ~= self.generation or not entry.alive or completed then return end
        completed, entry.group = true, 0
        if not success then self:Fail(entry, "download: " .. tostring(failedCount)); return end
        entry.state = "loading"
    end
    if #pendingPaths == 0 then downloaded(true, 0); return end
    local group = cache:DownloadResources(pendingPaths, downloaded)
    if not completed and entry.alive and not self.closed and token == self.generation then entry.group = group end
end

---@param state string
---@return GaragePreviewEntry?
function Cache:Next(state)
    local selected = self.entries[self.selected]
    if selected and selected.state == state and not selected.pending then return selected end
    for _, id in ipairs(self.wanted) do
        local entry = self.entries[id]
        if entry and entry.state == state and not entry.pending then return entry end
    end
    return nil
end

function Cache:Update()
    if self.closed then return end
    local foreground = self.entries[self.selected]
    local foregroundPending = foreground and foreground.state ~= "ready" and foreground.state ~= "failed"
    local active = 0
    for _, entry in pairs(self.entries) do
        if entry.state == "downloading" or entry.state == "loading" or entry.state == "build" then active = active + 1 end
    end
    -- Admit only one job/frame; two vehicle pipelines at most, never 27 parallel texture uploads.
    if active < self.concurrent then
        local nextEntry = self:Next("queued")
        if not nextEntry then
            for _, id in ipairs(self.wanted) do
                if not self.entries[id] then nextEntry = self:Ensure(id); break end
            end
        end
        if nextEntry then
            self:StartDownload(nextEntry)
            self.peakActive = math.max(self.peakActive, active + 1)
        end
    end
    local build = self:Next("build")
    -- A speculative 50k-triangle split must not steal the frame while the user is
    -- waiting for their selection. Network prewarming may overlap, CPU assembly waits.
    if foregroundPending and build and build.id ~= self.selected then build = nil end
    if build then
        -- One formal original-MDL assembly per frame, never in a completion callback.
        local ok, message = pcall(self.options.build, build)
        if not ok then
            if build.content then build.content:Dispose(); build.content = nil end
            self:Fail(build, tostring(message))
        else
            build.state = "ready"
            self.builds = self.builds + 1
            self:Touch(build)
            self.options.ready(build, build.requestToken)
        end
        return
    end
    local entry = self:Next("loading")
    if not entry then return end
    local budget = entry.id == self.selected and 4 or 1
    for _ = 1, budget do
        if entry.pending or entry.state ~= "loading" then break end
        local path = entry.paths[entry.index]
        if not path then entry.state = "build"; break end
        entry.pending = true
        local token = self.generation
        local kind = self.options.commonTypes[path] or VehicleAssets.ResourceTypes[path] or "XMLFile"
        local completed = false
        -- Inline hits may consume up to four foreground resources/frame. Background
        -- work gets only one; genuinely async work always stops on the pending flag.
        cache:GetResourceAsync(kind, path, function(resource)
            if self.closed or token ~= self.generation or not entry.alive or completed then return end
            completed, entry.pending = true, false
            if not resource then self:Fail(entry, "resource: " .. path); return end
            entry.resources[#entry.resources + 1] = resource
            entry.index = entry.index + 1
            if entry.index > #entry.paths then entry.state = "build" end
        end)
    end
end

function Cache:Dispose()
    self.closed = true
    self.generation = self.generation + 1
    local remove = {}
    for _, entry in pairs(self.entries) do remove[#remove + 1] = entry end
    for _, entry in ipairs(remove) do self:Release(entry) end
    self.wanted, self.selected = {}, ""
end

return Cache
