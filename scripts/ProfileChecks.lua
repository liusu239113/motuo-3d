-- 真实Profile源码的隔离回归；所有文件均为局部内存，不触碰玩家存档。
local Checks = {}

function Checks.Run()
    local file = assert(cache:GetFile("Profile.lua"), "[ProfileChecks] 缺少Profile源资源")
    local lines = {}
    while not file:IsEof() do lines[#lines + 1] = file:ReadLine() end
    file:Dispose()
    local source = table.concat(lines, "\n")
    ---@type table<string,string>
    local files = {}
    local failWrite, writes, assertions = false, 0, 0
    local function check(value, message)
        assert(value, "[ProfileChecks] " .. message)
        assertions = assertions + 1
    end
    local environment = setmetatable({
        fileSystem = {FileExists = function(_, path) return files[path] ~= nil end},
        File = function(path, mode)
            assert(path == "pursuit_profile.txt", "[ProfileChecks] 禁止未隔离存档")
            return {
                IsOpen = function() return true end,
                ReadString = function() return files[path] or "" end,
                WriteString = function(_, text)
                    assert(mode == FILE_WRITE)
                    if failWrite then return false end
                    files[path], writes = text, writes + 1
                    return true
                end,
                Close = function() end,
                Dispose = function() end,
            }
        end,
    }, {__index = _G})
    local function fresh()
        local chunk = assert(load(source, "@Profile.lua（内存回归）", "t", environment))
        return chunk()
    end
    local p = fresh()
    check(p.TrackUnlocked("circuit"), "默认赛车场必须开放")
    for _, id in ipairs({"lake", "alpine", "coast", "canyon", "forest"}) do
        check(not p.TrackUnlocked(id), "新档不得额外开放 " .. id)
    end
    local ok = p.UnlockTrack("lake", 1200)
    check(not ok and p.Coins() == 0 and not p.TrackUnlocked("lake"), "不足金币不能扣款或解锁")
    p.AddCoins(1800)
    ok = p.UnlockTrack("lake", 1200)
    check(ok and p.Coins() == 600 and p.TrackUnlocked("lake"), "明确购买扣准确金币")
    local reload = fresh()
    check(reload.Coins() == 600 and reload.TrackUnlocked("lake"), "新实例确实重读已购进度")
    files["pursuit_profile.txt"] = "version=1\ncoins=2300\nvehicle=sport,cruiser\nrider=green\ntrack=circuit,lake,coast\n"
    local old = fresh()
    check(old.TrackUnlocked("lake") and old.TrackUnlocked("coast") and old.Owns("cruiser"), "旧档购买与通关权益保留")
    failWrite = true
    local bought, message = old.UnlockTrack("alpine", 2200)
    check(not bought and message and old.Coins() == 2300 and not old.TrackUnlocked("alpine"), "写档失败必须回滚扣款和解锁")
    check(old.TrackUnlocked("coast"), "失败回滚不能清空原权益")
    bought = old.Buy("rally", 1200)
    check(not bought and old.Coins() == 2300 and not old.Owns("rally"), "车辆购买写失败不能丢金币或假报拥有")
    bought = old.BuyRider("red", 900)
    check(not bought and old.Coins() == 2300 and not old.OwnsRider("red"), "配色购买写失败必须回滚")
    print(string.format("[ProfileChecks] PASS %d项，%d次内存写入，玩家存档未访问", assertions, writes))
    return {passed = true, assertions = assertions}
end

return Checks
