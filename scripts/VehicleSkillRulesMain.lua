-- 快速批量验证入口：无截图、无媒体生成、不接SDK、不写用户档案。
assert(cache:AddResourceDir("/workspace/assets"))
assert(cache:AddResourceDir("/workspace/scripts"))
function Start()
    local results={}
    local suites={
        {"motorcycles",function() return require("MotorcycleSkillChecks").Run() end},
        {"five-actions",function() return require("MixedChecks").RunOddVehicleActions() end},
        {"remaining-rules",function() return require("MixedChecks").RunRemainingRules() end},
        {"protected-weapons",function() return require("MixedChecks").RunWeapons() end},
        {"effect-lifecycle",function() return require("MixedChecks").RunEffectLifecycle() end},
    }
    local failures={}
    for _,suite in ipairs(suites) do
        local ok,result=pcall(suite[2])
        if ok then
            results[#results+1]=suite[1].."="..tostring(type(result)=="table" and (result.assertions or result.count) or result)
        else
            failures[#failures+1]=suite[1]..": "..tostring(result)
            print("[快速技能批验] FAIL "..failures[#failures])
        end
    end
    print("[快速技能批验] "..table.concat(results," / "))
    assert(#failures==0,table.concat(failures,"\n"))
    print("[快速技能批验] ALL PASS")
end
