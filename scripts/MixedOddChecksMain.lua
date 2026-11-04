-- 纯规则入口：只验收五辆混合车技能，不创建正式场景、不读存档、不调用SDK。
local Checks=require("MixedChecks")
function Start()
    local result=Checks.RunOddVehicleActions()
    assert(result and result.passed,"五车技能规则验收失败")
    print(string.format("[五车技能规则验收] PASS %d项",result.assertions))
end
