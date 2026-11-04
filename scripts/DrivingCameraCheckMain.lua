-- 独立相机/触屏LOOK验收：只加载DrivingCamera与MobileControls，不启动main、Profile、广告、网络或存档。
local DrivingCamera = require("DrivingCamera")
local Controls = require("MobileControls")
local PointerEvent = require("urhox-libs/UI/Core/PointerEvent")
local UI = require("urhox-libs/UI")

local count = 0
local function check(value, message)
    assert(value, "[DrivingCameraCheck] " .. message)
    count = count + 1
end

local function near(a, b, epsilon)
    return math.abs(a - b) <= (epsilon or 0.000001)
end

local function fakeInput()
    local state = {right = false, left = false, touches = 0, dx = 0, dy = 0}
    local old = _G.input
    _G.input = {
        numTouches = 0,
        mouseMoveX = 0,
        mouseMoveY = 0,
        GetMouseButtonDown = function(_, button)
            if button == MOUSEB_RIGHT then return state.right end
            if button == MOUSEB_LEFT then return state.left end
            return false
        end,
    }
    return state, old
end

local function runCameraChecks()
    local state, oldInput = fakeInput()
    local oldPointer = UI.IsPointerOverUI
    local ok, message = xpcall(function()
        local camera = DrivingCamera.New()
        check(camera.yaw == 0 and camera.pitch == 0, "初始视角为零")
        camera:AddLook(1800, 0, 1)
        check(near(camera.yaw, 0), "水平视角可跨越整圈并按360度回绕")
        camera:AddLook(181, 0, 1)
        check(near(camera.yaw, -179), "水平角保持[-180,180)连续")
        camera:AddLook(0, 1000, 1)
        check(camera.pitch == DrivingCamera.MaxPitch, "俯仰上限生效")
        camera:AddLook(0, -1000, 1)
        check(camera.pitch == DrivingCamera.MinPitch, "俯仰下限生效")

        local controls = Controls.New()
        controls:SetEnabled(true)
        controls:BeginLook(77, 100, 100)
        controls:MoveLook(77, 110, 90)
        controls:EndLook(77, false)
        camera:Reset(35)
        controls:ResetLook()
        camera:ApplyLookInput(controls, true)
        check(camera.yaw == 0 and camera.pitch == 0, "Reset清理残留触屏增量")
        controls:BeginLook(77, 100, 100)
        controls:MoveLook(77, 110, 90)
        camera:ApplyLookInput(controls, true)
        check(near(camera.yaw, 3.4) and near(camera.pitch, -3.4), "触屏LOOK增量按灵敏度进入相机")
        controls:EndLook(77, false)
        camera:ApplyLookInput(controls, true)
        check(near(camera.yaw, 3.4), "触屏松手保持视角")
        controls:ResetLook()
        camera:Reset(0)
        state.right = true
        camera:ApplyLookInput(controls, true)
        check(not camera.mouseDragging, "右键按下时不能在UI状态中误开始")
        state.right = false
        camera:ApplyLookInput(controls, true)
        state.right = true
        state.left = false
        UI.IsPointerOverUI = function() return false end
        _G.input.mouseMoveX, _G.input.mouseMoveY = 100, -50
        camera:ApplyLookInput(controls, true)
        check(camera.mouseDragging and near(camera.yaw, 22) and near(camera.pitch, -11), "鼠标右键拖动按逻辑像素旋转")
        camera:CancelInput()
        check(not camera.mouseDragging and camera.mouseHeld, "失焦取消不会在右键未松开时自动重启")
        state.right = false
        camera:ApplyLookInput(controls, true)
        check(not camera.mouseHeld, "松开右键后允许下一次新手势")

        local bike = {Cockpit = {localOffset = Vector3(1, 2, 3), pitch = 7, fov = 71}}
        local node = {position = nil, rotation = nil}
        local lens = {fov = 0}
        camera:Reset(0)
        camera:UpdateHelmet(bike --[[@as Bike]], node --[[@as Node]], lens --[[@as Camera]], 20, 4)
        check(node.position == bike.Cockpit.localOffset and lens.fov == 77, "第一视角使用当前车型Cockpit眼位和FOV")
    end, debug.traceback)
    _G.input = oldInput
    UI.IsPointerOverUI = oldPointer
    if not ok then error(message) end
end

local function runControlChecks()
    local controls = Controls.New()
    controls:SetEnabled(true)
    check(controls:BeginLook(1, 100, 100), "LOOK可取得空闲触点")
    check(not controls:Press("gas", 1, 0, 1), "LOOK手指不能同时抢占油门")
    check(controls:Press("steer", 2, 0, 200), "方向可由另一根手指取得")
    check(controls:Press("gas", 3, 0, 1), "油门可与方向并行")
    check(controls:Press("wheelie", 4, 0, 1), "技能可与方向油门并行")
    controls:MoveLook(1, 130, 80)
    local dx, dy = controls:ConsumeLook()
    check(dx == 30 and dy == -20, "LOOK只消费自己的增量")
    check(controls.steer ~= 0 and controls.gas and controls.wheelie, "LOOK消费不改变既有驾驶持有")
    controls:EndLook(1, false)
    controls:Release(2); controls:Release(3); controls:Release(4)
    check(controls.steer == 0 and controls.throttle == 0 and not controls.gas and not controls.wheelie, "释放各自控制不互相残留")
    controls:BeginLook(5, 0, 0)
    controls:MoveLook(5, 40, 40)
    controls:EndLook(5, true)
    local cancelledX = controls:ConsumeLook()
    check(cancelledX == 0, "取消LOOK手势清掉未消费增量")
    controls:Reset()
    check(controls.lookPointer == -1 and controls:ConsumeLook() == 0, "Reset清掉LOOK所有状态")
end

function Start()
    runCameraChecks()
    runControlChecks()
    print("[DrivingCameraCheck] PASS " .. count .. " assertions / 360 yaw / pitch clamp / cockpit / mouse / touch ownership")
    engine:Exit()
end
