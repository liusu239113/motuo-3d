-- 可终止专项入口：只执行主结算接线隔离验收，不加载main.Start或创建任何Scene。
function Start()
    assert(require("RaceSettlementChecks").Run().passed)
    print("[RaceSettlementCheckMain] 全部断言通过")
    -- validate必须等帧循环自动退出，Start内Exit会早于报告器初始化而没有JSON。
    for _, argument in ipairs(GetArguments()) do if argument == "-validate" then return end end
    engine:Exit()
end
