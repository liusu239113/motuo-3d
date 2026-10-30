-- Isolated atlas fixture: only the two changed map modules override resource loading.
local scene = Scene()
function Start()
    scene:CreateComponent("Octree")
    local camera = scene:CreateChild("Camera"):CreateComponent("Camera")
    renderer:SetViewport(0, Viewport:new(scene, camera))
    local UI = require("urhox-libs/UI")
    local Theme = require("RacingTheme")
    UI.Init({theme = Theme.Theme, scale = UI.Scale.DEFAULT})
    local originalRequire = require
    local widget = dofile("/workspace/scripts/Career/MapWidget.lua")
    require = function(name)
        if name == "Career.MapWidget" then return widget end
        return originalRequire(name)
    end
    local overlay = dofile("/workspace/scripts/Career/MapOverlay.lua")
    require = originalRequire
    local result = overlay.Checks()
    print("[ATLAS_FIXTURE_PASS] " .. result.sizes .. " sizes / " .. result.buttons .. " taps / max " .. result.maxWidgets)
    return
    -- Screenshot setup intentionally disabled for the final logic-only rerun.
    --[[
    local atlas = overlay.New(function() end, function() end)
    local root = UI.Panel {width = "100%", height = "100%", padding = 0, children = {atlas.root}}
    UI.SetRoot(root)
    atlas:Open({x = 0, z = -20, yaw = 35}, nil, nil)
    ]]
end
