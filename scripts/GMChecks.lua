-- GM回归使用真实Profile源码和局部内存文件系统，不访问玩家档或真实广告SDK。
local Checks={}
local function source(name)
    local file=assert(cache:GetFile(name))
    local lines={}
    while not file:IsEof() do lines[#lines+1]=file:ReadLine() end
    file:Dispose()
    return table.concat(lines,"\n")
end
function Checks.Begin()
    -- 使用模块正常序列化的新档作为种子，不猜测试驾字段格式。
    local files={}
    local writes=0
    local env=setmetatable({fileSystem={
        FileExists=function(_,p) return files[p]~=nil end,
        Copy=function(_,a,b) files[b]=files[a];return true end,
        Rename=function(_,a,b) files[b],files[a]=files[a],nil;return true end,
        Delete=function(_,p) files[p]=nil;return true end},
        File=function(p,mode)
            assert(p:match("^pursuit_profile%.txt"),"禁止访问玩家文件")
            if mode==FILE_WRITE then writes=writes+1;files[p]="" end
            return {IsOpen=function() return mode==FILE_WRITE or files[p]~=nil end,
                ReadString=function() return files[p] end,
                WriteString=function(_,text) files[p]=text;return true end,
                Flush=function() end,Close=function() end,Dispose=function() end}
        end},{__index=_G})
    local isolated=assert(load(source("Profile.lua"),"GM隔离Profile","t",env))()
    assert(isolated.TryLoad())
    local data=isolated.Get()
    data.coins=2300;data.trials.helicopter=2
    assert(isolated.Save())
    local Profile=require("Profile")
    local previous={}
    for k,v in pairs(isolated) do previous[k]=Profile[k];Profile[k]=v end
    local restored=false
    return function()
        if restored then return end
        restored=true
        for k in pairs(isolated) do Profile[k]=previous[k] end
    end,function() return writes,files["pursuit_profile.txt"] end
end
-- GM 免费体验已从正式发布版移除；本文件现在只提供存档隔离夹具 Begin()，
-- 供性能与菜单演示自检复用，不再包含任何 GM 断言或开关。
return Checks
