-- 下载与场景准备分开计量；百分比只使用下载器真实回报或已完成任务数。
---@class RideLoader
local Loader = {}
Loader.__index = Loader

Loader.CoreResources = {
    {"XMLFile", "LightGroup/Daytime.xml"},
    {"Technique", "Techniques/PBR/PBRNoTexture.xml"},
    {"Technique", "Techniques/DiffSkybox.xml"},
    {"Technique", "Techniques/DiffUnlit.xml"},
    {"XMLFile", "RenderPaths/Forward.xml"},
    {"TextureCube", "uuid://E4ehad-5axjv7Ml9zasxNx06"},
    {"Model", "Models/Box.mdl"}, {"Model", "Models/Cylinder.mdl"},
    {"Model", "Models/Sphere.mdl"}, {"Model", "Models/Cone.mdl"},
    {"Font", "Fonts/MiSans-Regular.ttf"}, {"Font", "Fonts/MiSans-Bold.ttf"},
}

---@param extraResources string[]?
---@param resourceTypes table<string, string>?
function Loader.New(audioResources, progress, completed, failed, extraResources, resourceTypes)
    local self = setmetatable({}, Loader)
    self.active = true
    self.groupId = 0
    self.verifyIndex = 0
    self.verifyPending = false
    self.roots = {}
    self.progress, self.completed, self.failed = progress, completed, failed
    self.verify = {}
    local seen = {}
    local function add(path, kind)
        if seen[path] then return end
        seen[path] = true
        table.insert(self.roots, path)
        if kind then table.insert(self.verify, {kind, path}) end
    end
    for _, item in ipairs(Loader.CoreResources) do add(item[2], item[1]) end
    for _, path in ipairs(audioResources) do add(path, "Sound") end
    for _, path in ipairs(extraResources or {}) do
        local kind = resourceTypes and resourceTypes[path]
        if not kind then
            local extension = path:match("%.([^./]+)$")
            if extension == "mdl" then kind = "Model"
            elseif extension == "xml" then
                kind = path:find("Materials/", 1, true) and "Material" or "XMLFile"
            elseif extension == "png" or extension == "jpg" or extension == "tga" or extension == "dds" then
                kind = "Texture2D"
            end
        end
        -- UUID 根可能是预制体、材质或纹理，不猜类型；仍递归下载完整依赖，构建时按实际类型检查。
        add(path, kind)
    end
    return self
end

function Loader:Start()
    local resources = cache:GetResRefs(self.roots, true)
    -- 动态拼接的媒体也显式加入，避免引用扫描遗漏；清单去重。
    local seen = {}
    local uris = {}
    for _, list in ipairs({resources, self.roots}) do
        for _, uri in ipairs(list) do
            local canonical = cache:GetResUuidPath(uri)
            if canonical == "" then canonical = uri end
            if not seen[canonical] then
                seen[canonical] = true
                -- 本地已存在的引擎内置资源不必再交给下载器解析。
                if not cache:Exists(uri) then table.insert(uris, canonical) end
            end
        end
    end
    print("[加载] 首场景资源清单 " .. #uris .. " 项，优先复用本地缓存")
    self.progress("正在下载骑行资源", "检查缓存与首场景依赖，完成前不会进入驾驶。", 0, "正在检查 " .. #uris .. " 项资源")
    if #uris == 0 then
        self.progress("资源已在本地", "无需下载，逐项确认可载入。", 1, "缓存检查完成")
        self.verifyPending = true
        return
    end
    self.groupId = cache:DownloadResources(uris, function(success, failedCount)
        if not self.active then return end
        if not success then
            self.failed("有 " .. failedCount .. " 项资源未能下载，请检查网络后重试。")
            return
        end
        print("[加载] 资源下载/缓存检查完成，开始逐项确认可载入")
        self.verifyPending = true
    end, function(done, total, bytes, totalBytes)
        if not self.active then return end
        local fraction = totalBytes > 0 and math.min(1, bytes / totalBytes) or (total > 0 and done / total or 0)
        local numbers = totalBytes > 0 and string.format("%.2f / %.2f MB · %d/%d 项", bytes / 1048576, totalBytes / 1048576, done, total)
            or string.format("已检查 %d / %d 项 · 复用已有缓存", done, total)
        self.progress("正在下载骑行资源", "下载器实时进度；已有资源直接复用，不重复下载。", fraction, numbers)
    end)
end

function Loader:Update()
    if self.active and self.verifyPending then
        self.verifyPending = false
        self:VerifyNext()
    end
end

function Loader:VerifyNext()
    if not self.active then return end
    self.verifyIndex = self.verifyIndex + 1
    local item = self.verify[self.verifyIndex]
    if not item then self.completed(); return end
    cache:GetResourceAsync(item[1], item[2], function(resource)
        if not self.active then return end
        if not resource then self.failed("资源载入失败：" .. item[2]); return end
        self.progress("正在校验资源", "已下载不等于已载入，正在确认模型、字体与声音。",
            self.verifyIndex / #self.verify, string.format("%d / %d 项可用", self.verifyIndex, #self.verify))
        self.verifyPending = true
    end)
end

function Loader:Cancel()
    self.active = false
    if self.groupId ~= 0 then cache:CancelDownloadGroup(self.groupId) end
end

return Loader
