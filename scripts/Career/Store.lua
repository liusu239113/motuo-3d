-- 生涯存档，沿用 Profile 的模块级状态 + 沙箱 File 模式，但与旧竞速档完全隔离。
-- Get 返回深拷贝；所有经济/订单更改经 Transaction 验证并先落盘后提交。
-- 本地文件并不等于账号持久化，尤其 WASM 刷新会丢失；云接口必须显式调用并等回调。
local Store = {}
local Config = require "Career.Config"
local Housing = require "Career.HousingData"
local Property = require "Career.Property"
local Vehicles = require "Career.VehicleData"

---@class CareerVehicle
---@field id string
---@field borrowed boolean
---@field condition number
---@class CareerLedgerEntry
---@field id string
---@field kind string
---@field deltaCents integer
---@field balanceCents integer
---@field day integer
---@field time number
---@class CareerOrder
---@field id string
---@field sequence integer
---@field templateId string
---@field title string
---@field pickupId string
---@field dropoffId string
---@field route CareerRoutePoint[]
---@field distanceMeters number
---@field feeCents integer
---@field tutorial boolean
---@field status string
---@field acceptedDay integer
---@field acceptedTime number
---@field remainingHours number
---@field late boolean
---@class CareerPosition
---@field x number
---@field z number
---@field yaw number
---@field mounted boolean
---@field bikeX number
---@field bikeZ number
---@field bikeYaw number
---@field space? string 缺省city，兼容已有v1档
---@field cityX? number 室内时保留城市入口，停车坐标仍为bikeX/bikeZ
---@field cityZ? number
---@field cityYaw? number
---@field activeVehicle? string 缺省借用电动车；不影响参赛车辆
---@field groundHeight? number 步行桥层高度；旧档缺省地面
---@field vehicleParking? table<string, table> 每辆已取出车辆的独立城市停车位
---@class CareerProfile
---@field version integer
---@field revision integer
---@field name string
---@field cashCents integer
---@field reserveCents integer
---@field day integer
---@field time number 游戏小时；8=08:00，非现实秒
---@field hunger number 0=空腹，100=饱腹
---@field energy number
---@field battery number
---@field vehicle CareerVehicle
---@field ownedMotorcycles table<string, boolean>
---@field ownedHomes table<string, boolean> 永久产权；仅买断可写true，住宿选择不授予产权
---@field activeOrders CareerOrder[]
---@field settledOrders table<string, boolean>
---@field nextOrderSequence integer
---@field completedOrders integer
---@field phase string
---@field flags table<string, boolean>
---@field ledger CareerLedgerEntry[]
---@field financialKeys table<string, boolean>
---@field accommodation string
---@field lastAidDay integer
---@field lastDaySummary table
---@field position CareerPosition
---@field equipment? table<string, boolean>
---@field simulatedOrders? integer
---@field weeksWorked? integer
---@field activeSeconds? number
---@field lastScheduleSeconds? number
---@field lastScheduleManualOrders? integer
---@field raceVehicle? string
---@field motorcycleFuel? number 摩托共享油量，首次交车缺省100，电动车电量独立
---@field career? table
---@field teamContract? CareerTeamContract
---@field engagements? table
---@class CareerStorage
---@field read fun(path: string): string?, string?, boolean? text,error,missing
---@field write fun(path: string, text: string): boolean, string?
---@field cloud? table 仅隔离测试注入的回调桩，不替换生产账号接口

---@type CareerProfile?
local data = nil
---@type CareerProfile?
local committed = nil
---@type string?
local loadError = nil
local transactionBusy = false
local elapsedSinceSave = 0
local cloudBusy = false
local cloudStatus = "not_requested"
local cloudRevision = -1
local cloudGeneration = 0
local cloudElapsed = 0
---@type fun()?
local cloudTimeout = nil

-- 独立于手机/暂停的网络看门狗；迟到回包由请求闭包拒绝，不能再次覆盖本地进度。
function Store.UpdateCloud(dt)
    if not cloudBusy then return end
    cloudElapsed=cloudElapsed+math.max(0,dt)
    if cloudElapsed>=20 and cloudTimeout then cloudTimeout() end
end

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end

---@return CareerProfile
local function defaults()
    return {
        version = Config.SAVE_VERSION, revision = 0, name = "王二狗",
        cashCents = Config.INITIAL_CASH_CENTS, reserveCents = 0,
        day = 1, time = Config.START_HOUR, hunger = 65, energy = 80, battery = 70,
        vehicle = { id = "borrowed_ebike", borrowed = true, condition = 55 },
        ownedMotorcycles = {}, ownedHomes = {}, activeOrders = {}, settledOrders = {},
        nextOrderSequence = 1, completedOrders = 0, phase = "opening",
        flags = { tutorialCompleted = false, firstMeal = false, firstRest = false },
        ledger = { { id = "opening", kind = "opening", deltaCents = 5000,
            balanceCents = 5000, day = 1, time = Config.START_HOUR } },
        financialKeys = { opening = true }, accommodation = "bridge", lastAidDay = 0,
        lastDaySummary = {},
        position = { x = 0, z = -20, yaw = 0, mounted = false, bikeX = 1.5, bikeZ = -20, bikeYaw = 0 },
    }
end

-- 缺省字段迁移只操作副本，不覆写旧档、不从租住/剧情记录推断产权。
-- 本地/云读取共用；非法字段及未知版本仍由validate拒绝。
---@param p any
---@return CareerProfile
function Store.Normalize(p)
    local normalized=copy(p)
    if type(normalized)=="table" then Property.Normalize(normalized) end
    return normalized
end

local function finite(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function integer(value, minimum)
    return finite(value) and value % 1 == 0 and value >= minimum and value <= 9007199254740991
end

local function range(value, lo, hi)
    return finite(value) and value >= lo and value <= hi
end

local function validSpace(pos)
    local space=pos.space or "city"
    if space=="city" then return true end
    local home=Housing.Get(space)
    return home~=nil and home.width~=nil and not pos.mounted
        and range(pos.x,-home.width/2+.32,home.width/2-.32)
        and range(pos.z,-home.depth/2+.32,home.depth/2-.32)
        and finite(pos.cityX) and finite(pos.cityZ) and finite(pos.cityYaw)
end

local function booleanMap(value)
    if type(value) ~= "table" then return false end
    for key, enabled in pairs(value) do
        if type(key) ~= "string" or type(enabled) ~= "boolean" then return false end
    end
    return true
end

local function array(value)
    if type(value) ~= "table" then return false end
    local n = #value
    for key in pairs(value) do
        if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > n then return false end
    end
    return true
end

-- 不“修复”为旧 Profile 的免费 sport；非法/未知版本存档拒绝加载而非重置覆盖。
---@param p CareerProfile
---@return boolean, string?
local function validate(p)
    if type(p) ~= "table" or p.version ~= Config.SAVE_VERSION or p.name ~= "王二狗" then
        return false, "生涯存档版本或身份不兼容"
    end
    if not integer(p.revision, 0) or not integer(p.cashCents, 0) or not integer(p.reserveCents, 0)
        or not integer(p.day, 1) or not range(p.time, 0, 24)
        or not range(p.hunger, 0, 100) or not range(p.energy, 0, 100) or not range(p.battery, 0, 100) then
        return false, "生涯金额、时间或生存数值无效"
    end
    if type(p.vehicle) ~= "table" or p.vehicle.id ~= "borrowed_ebike" or p.vehicle.borrowed ~= true
        or not range(p.vehicle.condition, 0, 100) or not booleanMap(p.ownedMotorcycles) then
        return false, "生涯车辆字段无效"
    end
    if not booleanMap(p.flags) or not booleanMap(p.settledOrders) or not booleanMap(p.financialKeys)
        or not integer(p.nextOrderSequence, 1) or not integer(p.completedOrders, 0)
        or not integer(p.lastAidDay, 0) or p.lastAidDay > p.day or type(p.phase) ~= "string"
        or not ({bridge=true,park=true,hostel=true,room=true,apartment=true})[p.accommodation]
        or type(p.lastDaySummary) ~= "table" then return false, "生涯进度字段无效" end
    if type(p.position) ~= "table" or not finite(p.position.x) or not finite(p.position.z)
        or not finite(p.position.yaw) or type(p.position.mounted) ~= "boolean"
        or not finite(p.position.bikeX) or not finite(p.position.bikeZ) or not finite(p.position.bikeYaw) then
        return false, "生涯位置字段无效"
    end
    if p.position.groundHeight~=nil and not range(p.position.groundHeight,0,20) then return false,"步行高度无效" end
    if not Vehicles.ValidPosition(p.position,p.ownedMotorcycles) then return false,"城市车辆未拥有或停车字段无效" end
    if p.motorcycleFuel~=nil and not range(p.motorcycleFuel,0,100) then return false,"摩托燃油无效" end
    if not validSpace(p.position) or ((p.position.space or "city")~="city" and p.position.space~=p.accommodation) then
        return false,"室内位置或入住信息无效"
    end
    local equipment = p.equipment or {}
    if not booleanMap(equipment) then return false, "装备字段无效" end
    if p.simulatedOrders ~= nil and not integer(p.simulatedOrders,0) then return false,"排班完成数无效" end
    if p.weeksWorked ~= nil and not integer(p.weeksWorked,0) then return false,"排班周数无效" end
    for _,key in ipairs({"activeSeconds","lastScheduleSeconds"}) do
        if p[key]~=nil and not range(p[key],0,9007199254740991) then return false,"班次时间无效" end
    end
    if p.lastScheduleManualOrders~=nil and (not integer(p.lastScheduleManualOrders,0)
        or p.lastScheduleManualOrders>p.completedOrders) then return false,"班次订单数无效" end
    if p.raceVehicle~=nil and (type(p.raceVehicle)~="string" or not p.ownedMotorcycles[p.raceVehicle]) then
        return false,"参赛车辆未购入"
    end
    if p.career ~= nil then
        local c=p.career
        if type(c)~="table" or not integer(c.starts,0) or not integer(c.wins,0) or not integer(c.points,0)
            or not integer(c.season,1) or type(c.team)~="string" then return false,"职业进度无效" end
        if c.pending~=false then
            local pending=c.pending
            local tracks={"circuit","lake","hairpin","coast","canyon","forest"}
            if type(pending)~="table" or type(pending.id)~="string" or not integer(pending.series,1) or pending.series>6
                or pending.track~=tracks[pending.series] or type(pending.vehicle)~="string" or not p.ownedMotorcycles[pending.vehicle]
                or not integer(pending.laps,1) or pending.laps>9 then return false,"职业报名无效" end
            if pending.training then
                if pending.id~="training:license" or pending.series~=1 or pending.laps~=1
                    or not p.financialKeys["training:license"] then return false,"训练报名无效" end
            elseif pending.id~="career-race:"..c.starts or not p.financialKeys[pending.id..":entry"] then
                return false,"职业报名缺少对应入场记录"
            end
        end
    end
    local propertyValid,propertyMessage=Property.Validate(p)
    if not propertyValid then return false,propertyMessage end
    local teamValid,teamMessage=require("Career.Team").Validate(p)
    if not teamValid then return false,teamMessage end
    local eventValid,eventMessage=require("Career.Engagements").Validate(p)
    if not eventValid then return false,eventMessage end
    local capacity=equipment.large_box and 4 or equipment.insulated_box and 2 or 1
    if not array(p.activeOrders) or #p.activeOrders > capacity or not array(p.ledger)
        or #p.ledger == 0 then return false, "订单容量或流水格式无效" end
    local runningBalance = 0
    local ledgerKeys = {}
    for _, entry in ipairs(p.ledger) do
        if type(entry) ~= "table" or type(entry.id) ~= "string" or type(entry.kind) ~= "string"
            or not integer(entry.balanceCents, 0) or not integer(entry.day, 1)
            or not range(entry.time, 0, 24) or not finite(entry.deltaCents) or entry.deltaCents % 1 ~= 0
            or ledgerKeys[entry.id] or p.financialKeys[entry.id] ~= true then
            return false, "流水字段或去重信息无效"
        end
        runningBalance = runningBalance + entry.deltaCents
        if runningBalance ~= entry.balanceCents then return false, "流水余额不一致" end
        ledgerKeys[entry.id] = true
    end
    if runningBalance ~= p.cashCents then return false, "钱包与流水不一致" end
    for key, enabled in pairs(p.financialKeys) do
        if enabled and not ledgerKeys[key] then return false, "流水去重键缺少记录" end
    end
    local settledCount = 0
    for id, enabled in pairs(p.settledOrders) do
        if enabled then
            if not ledgerKeys["delivery:" .. id] then return false, "已结算订单缺少流水" end
            settledCount = settledCount + 1
        end
    end
    if settledCount ~= p.completedOrders then return false, "完成数量与结算记录不一致" end
    for _, order in ipairs(p.activeOrders) do
        if type(order) ~= "table" or not integer(order.sequence, 1)
            or order.sequence >= p.nextOrderSequence or order.id ~= string.format("career-v1-%d", order.sequence)
            or p.settledOrders[order.id] == true or (order.status ~= "accepted" and order.status ~= "picked_up")
            or not integer(order.acceptedDay, 1) or not range(order.acceptedTime, 0, 24)
            or not finite(order.remainingHours) or type(order.late) ~= "boolean" then
            return false, "活动订单状态无效"
        end
        local template = Config.GetTemplate(order.templateId)
        if not template or order.pickupId ~= template.pickupId or order.dropoffId ~= template.dropoffId
            or order.tutorial ~= template.tutorial or order.title ~= template.title then
            return false, "活动订单模板不兼容"
        end
        local expectedDistance = Config.RouteDistance(template.route)
        local expectedFee = template.tutorial and 500 or Config.FeeCents(expectedDistance)
        if order.distanceMeters ~= expectedDistance or order.feeCents ~= expectedFee or not array(order.route)
            or #order.route ~= #template.route then return false, "订单报价或路线无效" end
        for i, point in ipairs(template.route) do
            local savedPoint = order.route[i]
            if type(savedPoint) ~= "table" or savedPoint.x ~= point.x or savedPoint.z ~= point.z then
                return false, "订单路线不一致"
            end
        end
    end
    return true
end

---@param path string
---@return string?, string?, boolean?
local function readFile(path)
    if not fileSystem then return nil, "本地文件系统不可用" end
    if not fileSystem:FileExists(path) then return nil, nil, true end
    local file = File(path, FILE_READ)
    if not file or not file:IsOpen() then
        if file then file:Dispose() end
        return nil, "无法读取生涯存档"
    end
    local ok, text = pcall(function() return file:ReadString() end)
    file:Close()
    file:Dispose()
    if not ok then return nil, "读取生涯存档失败" end
    return text
end

local function writeFile(path, text)
    local file = File(path, FILE_WRITE)
    if not file or not file:IsOpen() then
        if file then file:Dispose() end
        return false, "无法写入生涯存档"
    end
    local ok, written = pcall(function()
        local result = file:WriteString(text)
        file:Flush()
        return result
    end)
    file:Close()
    file:Dispose()
    if not ok or not written then return false, "生涯存档写入失败" end
    local verify = readFile(path)
    if verify ~= text then return false, "生涯存档写后校验失败" end
    return true
end

---@type CareerStorage
local storage = {
    read = readFile,
    write = function(path, text)
        -- 临时文件验证后重命名，失败时保留旧主档；备份仅用于写入恢复，不自动覆盖坏档。
        local temp, backup = path .. ".pending", path .. ".backup"
        local ok, message = writeFile(temp, text)
        if not ok then return false, message end
        local hadOld = fileSystem:FileExists(path)
        if hadOld and not fileSystem:Copy(path, backup) then return false, "无法备份旧生涯存档" end
        if not fileSystem:Rename(temp, path) then return false, "无法提交生涯存档，原档未替换" end
        if readFile(path) ~= text then
            if hadOld then fileSystem:Copy(backup, path) else fileSystem:Delete(path) end
            return false, "提交生涯存档校验失败，已尝试恢复备份"
        end
        return true
    end,
}

---@param p CareerProfile
---@return boolean, string?
local function persist(p)
    local valid, validationMessage = validate(p)
    if not valid then return false, validationMessage end
    local encoded, text = pcall(cjson.encode, p)
    if not encoded then return false, "生涯存档编码失败" end
    local called, saved, message = pcall(storage.write, Config.SAVE_PATH, text)
    if not called then return false, "生涯存档写入异常" end
    return saved == true, message
end

local function install(p)
    data = copy(p)
    committed = copy(p)
    loadError = nil
    elapsedSinceSave = 0
end

-- 主页检测不加载、不创建、不覆盖任何档案；坏档也返回true，交由Load报告错误。
---@return boolean
function Store.HasSave()
    local ok, text, _, missing = pcall(storage.read, Config.SAVE_PATH)
    return ok and missing ~= true and text ~= nil
end

---@param position CareerPosition
---@return boolean, string?
function Store.SetPosition(position)
    if transactionBusy or cloudBusy then return false, "存档忙" end
    if loadError then return false, loadError end
    if type(position) ~= "table" or not finite(position.x) or not finite(position.z)
        or not finite(position.yaw) or type(position.mounted) ~= "boolean"
        or not finite(position.bikeX) or not finite(position.bikeZ) or not finite(position.bikeYaw) then
        return false, "位置字段无效"
    end
    if position.groundHeight~=nil and not range(position.groundHeight,0,20) then return false,"步行高度无效" end
    if not validSpace(position) then return false,"室内位置无效" end
    if not data then Store.Get() end
    local p = data --[[@as CareerProfile]]
    if not Vehicles.ValidPosition(position,p.ownedMotorcycles) then return false,"城市车辆或停车字段无效" end
    if (position.space or "city")~="city" and position.space~=p.accommodation then return false,"室内与所选住处不一致" end
    p.position = copy(position)
    return true
end

---@return boolean, string
function Store.Load()
    if transactionBusy or cloudBusy then return false, "存档忙，请稍后重试" end
    local called, text, message, missing = pcall(storage.read, Config.SAVE_PATH)
    if not called then loadError = "读取生涯存档异常"; return false, loadError end
    if missing then return Store.NewCareer() end
    if not text then loadError = message or "无法读取生涯存档"; return false, loadError end
    local decoded, p = pcall(cjson.decode, text)
    if not decoded then loadError = "生涯存档解析失败；原档已保留"; return false, loadError end
    p=Store.Normalize(p)
    local valid, validationMessage = validate(p)
    if not valid then loadError = validationMessage; return false, validationMessage or "生涯存档无效" end
    install(p)
    print(string.format("[Career.Store] loaded revision=%d day=%d cashCents=%d orders=%d", p.revision, p.day, p.cashCents, #p.activeOrders))
    return true, "已读取本地生涯（不代表云端持久化）"
end

-- 显式新档入口；调用者负责确认覆盖已有生涯，绝不碰 pursuit_profile。
---@return boolean, string
function Store.NewCareer()
    if transactionBusy or cloudBusy then return false, "存档忙，请稍后重试" end
    local fresh = defaults()
    local ok, message = persist(fresh)
    if not ok then
        print("[Career.Store] new career save failed; previous state retained")
        return false, message or "新档保存失败"
    end
    install(fresh)
    cloudGeneration = cloudGeneration + 1
    cloudStatus, cloudRevision = "not_requested", -1
    print("[Career.Store] new career: 王二狗 / 5000 cents / borrowed ebike / no motorcycle")
    return true, "已创建本地生涯（WASM刷新不保证保留）"
end

---@return CareerProfile
function Store.Get()
    if not data then
        if loadError then error(loadError) end
        local ok, message = Store.Load()
        if not ok then error(message) end
    end
    return copy(data)
end

-- 高频移动只取标量快照，避免每帧深拷贝完整流水、订单历史与收藏。
-- 返回新表而非内部档案引用，仍只有Advance/Transaction写入真值。
function Store.MotionState()
    if not data then Store.Get() end
    local p=data --[[@as CareerProfile]]
    return {time=p.time,hunger=p.hunger,energy=p.energy,battery=p.battery,motorcycleFuel=p.motorcycleFuel}
end

---@return boolean, string
function Store.Save()
    if transactionBusy or cloudBusy then return false, "存档忙，请稍后重试" end
    if loadError then return false, loadError end
    if not data then return Store.Load() end
    local candidate = copy(data)
    candidate.revision = candidate.revision + 1
    local ok, message = persist(candidate)
    if not ok then
        data = copy(committed)
        elapsedSinceSave = 0
        print("[Career.Store] save failed; unsaved simulation rolled back")
        return false, message or "保存失败，未保存的模拟时间已回滚"
    end
    install(candidate)
    return true, "本地保存成功（未确认云存档）"
end

-- callback 只能修改传入草稿，必须 return true[,message] 才提交；不可嵌套事务。
---@param callback fun(draft: CareerProfile): boolean, string?
---@return boolean, string
function Store.Transaction(callback)
    if transactionBusy or cloudBusy then return false, "存档忙，请稍后重试" end
    if loadError then return false, loadError end
    local before = Store.Get()
    local draft = copy(before)
    transactionBusy = true
    local called, accepted, message = pcall(callback, draft)
    if not called or accepted ~= true then
        transactionBusy = false
        return false, called and (message or "操作未提交") or "生涯操作异常，已回滚"
    end
    draft.revision = before.revision + 1
    local saved, saveMessage = persist(draft)
    transactionBusy = false
    if not saved then
        print("[Career.Store] transaction save failed; wallet/order/flags unchanged")
        return false, saveMessage or "保存失败，操作已回滚"
    end
    install(draft)
    return true, message or "操作成功，已本地保存"
end

-- 供事务内部使用，金额必须已经是整数分，不静默取整；key 用于支出/收入幂等。
---@param draft CareerProfile
---@param deltaCents integer
---@param kind string
---@param key string
---@return boolean, string?
function Store.ApplyCash(draft, deltaCents, kind, key)
    if not finite(deltaCents) or deltaCents % 1 ~= 0 or type(key) ~= "string" or key == "" then
        return false, "金额必须为整数分且提供流水键"
    end
    if draft.financialKeys[key] then return false, "该笔收支已处理" end
    local balance = draft.cashCents + deltaCents
    if not integer(balance, 0) then return false, "现金不足或金额无效" end
    draft.cashCents = math.floor(balance)
    draft.financialKeys[key] = true
    draft.ledger[#draft.ledger + 1] = {
        id = key, kind = kind, deltaCents = deltaCents, balanceCents = draft.cashCents,
        day = draft.day, time = draft.time,
    }
    return true
end

---@param amountCents integer
---@param reason? string
---@param key? string
---@return boolean, string
function Store.Pay(amountCents, reason, key)
    if not integer(amountCents, 0) then return false, "付款金额必须为非负整数分" end
    return Store.Transaction(function(p)
        return Store.ApplyCash(p, -amountCents, reason or "payment", key or ("payment:" .. (#p.ledger + 1)))
    end)
end

---@return boolean, string
function Store.Eat()
    return Store.Transaction(function(p)
        if p.time + 0.25 > 24 then return false, "已到深夜，请先休息" end
        local ok, message = Store.ApplyCash(p, -Config.MEAL_CENTS, "meal", "meal:" .. (#p.ledger + 1))
        if not ok then return false, message end
        p.hunger = math.min(100, p.hunger + 55)
        p.energy = math.min(100, p.energy + 8)
        p.time = p.time + 0.25
        for _, order in ipairs(p.activeOrders) do
            order.remainingHours = order.remainingHours - 0.25
            order.late = order.remainingHours < 0
        end
        p.flags.firstMeal = true
        return true, "用餐支出12.00元，耗时15游戏分钟"
    end)
end

---@param pointId? string bridge 或 park；入口检查到点/步行停稳
---@return boolean, string
function Store.Rest(pointId)
    local place = pointId or "bridge"
    local room=Housing.Get(place)
    if not room then return false,"住处不存在" end
    return Store.Transaction(function(p)
        if #p.activeOrders > 0 then return false, "请先完成当前配送再休息" end
        if (p.position.space or "city")~="city" and p.position.space~=place then return false,"请先离开当前房间" end
        local nightly=Property.NightlyCost(p,place)
        if nightly>0 then
            local ok,message=Store.ApplyCash(p,-nightly,"lodging","lodging:"..p.day)
            if not ok then return false,message end
        end
        local income, expense = 0, 0
        for _, entry in ipairs(p.ledger) do
            if entry.day == p.day and entry.kind ~= "opening" then
                if entry.deltaCents > 0 then income = income + entry.deltaCents else expense = expense - entry.deltaCents end
            end
        end
        p.lastDaySummary = { day = p.day, incomeCents = income, expenseCents = expense, balanceCents = p.cashCents }
        p.day = p.day + 1
        p.time = Config.START_HOUR
        p.accommodation = place
        p.hunger = math.max(35, p.hunger - 20)
        p.energy = math.max(p.energy, room.energy)
        -- 次日免费最低可用充电，非满电赠送；没有现金/可出售物品收益。
        p.battery = math.max(p.battery, 35)
        p.vehicle.condition = math.max(p.vehicle.condition, 35)
        p.flags.firstRest = true
        if room.price>0 then p.flags["stayed_"..place]=true end
        p.phase = "working"
        if Property.Owns(p,place) then return true,"自有住房免房费，休息至次日08:00，已本地保存" end
        return true, nightly==0 and "免费休息至次日08:00，已本地保存"
            or string.format("住宿支出%.2f元，休息至次日08:00，已本地保存",nightly/100)
    end)
end

---@return boolean, string
function Store.RequestAid()
    return Store.Transaction(function(p)
        if p.cashCents >= Config.AID_THRESHOLD_CENTS then return false, "现金未低于30元" end
        if p.lastAidDay == p.day then return false, "今日已领取基础帮助" end
        p.lastAidDay = p.day
        p.hunger = math.max(p.hunger, 60)
        p.energy = math.max(p.energy, 55)
        p.battery = math.max(p.battery, 35)
        p.vehicle.condition = math.max(p.vehicle.condition, 35)
        p.flags.receivedAid = true
        return true, "已提供不可出售的餐食与最低可用整备；不发现金"
    end)
end

---@return boolean, string
function Store.Charge()
    return Store.Transaction(function(p)
        if p.battery >= 100 then return false, "电量已满" end
        if p.time + 0.5 > 24 then return false, "已到深夜，请先休息" end
        local ok, message = Store.ApplyCash(p, -200, "charge", "charge:" .. (#p.ledger + 1))
        if not ok then return false, message end
        p.battery = 100
        p.time = p.time + 0.5
        p.hunger = math.max(0, p.hunger - 0.5 * Config.HUNGER_PER_HOUR)
        p.energy = math.min(100, p.energy + 3)
        for _, order in ipairs(p.activeOrders) do
            order.remainingHours = order.remainingHours - 0.5
            order.late = order.remainingHours < 0
        end
        return true, "充电支出2.00元，耗时30游戏分钟"
    end)
end

-- 车行提供摩托补给；每次20元补满，实际到场由Session.Service检查。
function Store.Refuel()
    return Store.Transaction(function(p)
        if Vehicles.Active(p)==Vehicles.EBIKE then return false,"当前是电动车，请去街边充电" end
        if (p.motorcycleFuel or 100)>=100 then return false,"摩托燃油已满" end
        if #p.activeOrders>0 then return false,"请先完成配送" end
        local ok,message=Store.ApplyCash(p,-2000,"fuel","fuel:"..(#p.ledger+1))
        if not ok then return false,message end
        p.motorcycleFuel=100
        return true,"摩托补给20元，燃油已满；9号电量不变"
    end)
end

---@return boolean, string
function Store.Help() return Store.RequestAid() end

-- 激励视频奖励统一走事务：去重键即流水号，重复回调无法二次入账。
-- 只有已结算的订单才能领小费，避免配合未完成订单刷奖励。
---@param orderId string
---@param cents integer
---@return boolean, string
function Store.ClaimAdTip(orderId, cents)
    if type(orderId) ~= "string" or not integer(cents, 1) then return false, "小费参数无效" end
    return Store.Transaction(function(p)
        if p.settledOrders[orderId] ~= true then return false, "该订单尚未结算" end
        local ok, message = Store.ApplyCash(p, cents, "ad_tip", "ad_tip:" .. orderId)
        if not ok then return false, message end
        return true, string.format("顾客小费 %.2f 元已入账", cents / 100)
    end)
end

-- 每日一次：键含游戏日，跨天自然恢复，也不额外新增存档字段。
---@param cents integer
---@return boolean, string
function Store.ClaimAdSubsidy(cents)
    if not integer(cents, 1) then return false, "补贴金额无效" end
    return Store.Transaction(function(p)
        local ok, message = Store.ApplyCash(p, cents, "ad_subsidy", "ad_subsidy:day" .. p.day)
        if not ok then return false, "今天已经领过补贴了" end
        return true, string.format("今日补贴 %.2f 元已入账", cents / 100)
    end)
end

---@param day integer
---@return boolean 今日补贴是否已领取
function Store.AdSubsidyClaimed(day)
    if not data then Store.Get() end
    local p = data --[[@as CareerProfile]]
    return p.financialKeys["ad_subsidy:day" .. math.floor(day)] == true
end

---@param orderId string
---@return boolean 该订单的小费是否已领取
function Store.AdTipClaimed(orderId)
    if not data then Store.Get() end
    local p = data --[[@as CareerProfile]]
    return p.financialKeys["ad_tip:" .. orderId] == true
end

-- 仅由 Delivery.Update 转发活动 dt；不订阅全局 Update，不计真实离线时长。
---@param dt number
---@param distanceMeters? number
---@return boolean, string?
function Store.Advance(dt, distanceMeters)
    if not finite(dt) or dt < 0 or not finite(distanceMeters or 0) or (distanceMeters or 0) < 0 then
        return false, "无效的活动时间或行驶距离"
    end
    if transactionBusy or cloudBusy then return false, "存档忙" end
    if dt == 0 then return true end
    if loadError then return false, loadError end
    if not data then Store.Get() end
    local p = data --[[@as CareerProfile]]
    local hours = math.min(dt * Config.GAME_HOURS_PER_SECOND, 24 - p.time)
    p.activeSeconds=(p.activeSeconds or 0)+hours/Config.GAME_HOURS_PER_SECOND
    p.time = p.time + hours
    p.hunger = math.max(0, p.hunger - hours * Config.HUNGER_PER_HOUR)
    local rate = p.equipment and p.equipment.raincoat and .85 or 1
    p.energy = math.max(0, p.energy - hours * Config.ENERGY_PER_HOUR * rate)
    local batteryRate = p.equipment and p.equipment.battery and 100/65000 or Config.BATTERY_PER_METER
    if Vehicles.Active(p)==Vehicles.EBIKE then
        p.battery = math.max(0, p.battery - (distanceMeters or 0) * batteryRate)
    else
        p.motorcycleFuel=math.max(0,(p.motorcycleFuel or 100)-(distanceMeters or 0)*100/180000)
    end
    for _, order in ipairs(p.activeOrders) do
        order.remainingHours = order.remainingHours - hours
        order.late = order.remainingHours < 0
    end
    elapsedSinceSave = elapsedSinceSave + dt
    if elapsedSinceSave >= Config.AUTOSAVE_SECONDS then return Store.Save() end
    return true
end

---@return table
function Store.GetSaveStatus()
    return { localReady = committed ~= nil, localError = loadError,
        cloud = cloudStatus, cloudRevision = cloudRevision,
        revision = data and data.revision or -1,
        warning = "本地WASM文件刷新不保证持久；仅cloud='confirmed'且版本一致代表云端回调已确认" }
end

-- 可选、显式、异步。冻结本地写入直到回调，避免旧快照回包后误报新进度已上云。
-- 仅用于此小型业务快照，不保存 Scene；无服务端，也不承诺跨设备并发合并。
---@param callback? fun(ok: boolean, message: string)
---@return boolean, string
function Store.SaveCloud(callback)
    if cloudBusy or transactionBusy then return false, "存档忙" end
    local cloud=storage.cloud or clientCloud
    if not cloud then return false, "账号云存档接口不可用" end
    local ok, message = Store.Save()
    if not ok then return false, message end
    local snapshot = Store.Get()
    local generation = cloudGeneration
    cloudBusy, cloudStatus = true, "pending"
    local finished = false
    local function finish(success, detail)
        if finished or generation ~= cloudGeneration then return end
        finished = true
        cloudBusy = false
        cloudTimeout=nil
        cloudStatus = success and "confirmed" or "unconfirmed"
        if success then cloudRevision = snapshot.revision end
        print("[Career.Store] cloud save " .. cloudStatus)
        if callback then callback(success, detail) end
    end
    cloudElapsed=0
    cloudTimeout=function() finish(false,"云保存等待超过20秒，结果未确认；本地操作已恢复，云端结果请读取核对") end
    local called = pcall(function()
        cloud:Set(Config.CLOUD_KEY, snapshot, {
            ok = function() finish(true, "账号云存档已确认") end,
            error = function(code, reason) finish(false, "云保存未确认：" .. tostring(code) .. " " .. tostring(reason)) end,
            timeout = function() finish(false, "云保存超时，结果未确认，请读云档核对") end,
        })
    end)
    if not called then finish(false, "请求云保存异常，结果未确认") end
    return called, called and "已发起云保存，尚未确认" or "请求云保存异常"
end

-- 读取云档必须显式选择，期间禁止本地事务；只在解析验证+本地保存均成功后替换内存。
---@param callback fun(ok: boolean, message: string)
---@return boolean, string
function Store.LoadCloud(callback)
    if cloudBusy or transactionBusy then return false, "存档忙" end
    local cloud=storage.cloud or clientCloud
    if not cloud then return false, "账号云存档接口不可用" end
    local generation = cloudGeneration
    cloudBusy, cloudStatus = true, "loading"
    local finished = false
    local function finish(success, detail)
        if finished or generation ~= cloudGeneration then return end
        finished = true
        cloudBusy = false
        cloudTimeout=nil
        cloudStatus = success and "confirmed" or "unconfirmed"
        callback(success, detail)
    end
    cloudElapsed=0
    cloudTimeout=function() finish(false,"云读取等待超过20秒；本地进度未覆盖，操作已恢复") end
    local called = pcall(function()
        cloud:Get(Config.CLOUD_KEY, {
            ok = function(values)
                if finished or generation ~= cloudGeneration then return end
                local p = type(values) == "table" and values[Config.CLOUD_KEY] or nil
                if type(p) ~= "table" then finish(false, "云档为空或格式无效；未覆盖任何本地进度"); return end
                p=Store.Normalize(p)
                local valid, detail = validate(p)
                if not valid then finish(false, detail or "云档无效"); return end
                local saved, saveMessage = persist(p)
                if not saved then finish(false, saveMessage or "云档落地失败，原进度已保留"); return end
                install(p)
                cloudRevision = p.revision
                finish(true, "已读取账号云档并保存本地")
            end,
            error = function(code, reason) finish(false, "云读取失败：" .. tostring(code) .. " " .. tostring(reason)) end,
            timeout = function() finish(false, "云读取超时；未覆盖本地进度") end,
        })
    end)
    if not called then finish(false, "请求云读取异常") end
    return called, called and "正在读取云档" or "请求云读取异常"
end

-- 测试注入只作用于作用域内，finally 恢复全部内存状态；测试绝不写玩家真实文件。
---@param adapter CareerStorage
---@return fun()
function Store.UseTestStorage(adapter)
    if transactionBusy or cloudBusy then error("Cannot test while storage is busy") end
    local previousStorage, previousData, previousCommitted = storage, data, committed
    local previousError, previousElapsed = loadError, elapsedSinceSave
    local previousCloudStatus, previousCloudRevision = cloudStatus, cloudRevision
    storage, data, committed, loadError = adapter, nil, nil, nil
    elapsedSinceSave = 0
    local restored=false
    return function()
        if restored then return end
        restored=true
        storage, data, committed, loadError = previousStorage, previousData, previousCommitted, previousError
        elapsedSinceSave = previousElapsed
        cloudBusy, transactionBusy = false, false
        cloudTimeout=nil; cloudElapsed=0
        cloudStatus, cloudRevision = previousCloudStatus, previousCloudRevision
        cloudGeneration = cloudGeneration + 1
    end
end

-- 同步逻辑检查使用finally恢复；异步场景检查持有显式恢复函数直到Stop。
---@param adapter CareerStorage
---@param callback fun()
function Store.WithTestStorage(adapter, callback)
    local restore=Store.UseTestStorage(adapter)
    local ok,message=pcall(callback)
    restore()
    if not ok then error(message) end
end

return Store
