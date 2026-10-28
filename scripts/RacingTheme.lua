-- Restrained BrawlForge adaptation: stamped silhouettes and state depth, not cartoon outlines.
-- All page/component styling lives here; the UI library owns fonts, frames and DPI.
local UI = require("urhox-libs/UI")
local Racing = {}
Racing.Colors = {
    amber = {226, 177, 101, 255}, cyan = {112, 207, 211, 255},
    white = {239, 242, 243, 255}, muted = {167, 177, 184, 255},
    steel = {120, 144, 156, 255}, dark = {17, 21, 25, 250},
    border = {66, 77, 85, 255}, red = {227, 119, 103, 255}, green = {148, 199, 169, 255},
}
local C = Racing.Colors
function Racing.Gradient(top, bottom)
    return {type = "linear", direction = "to-bottom", from = top, to = bottom}
end
local shadow = {{x = 0, y = 3, blur = 10, color = {0, 0, 0, 65}}}
Racing.Theme = UI.Theme.ExtendTheme(UI.Theme.defaultTheme, {
    fonts = {{family = "sans", weights = {
        normal = "Fonts/MiSans-Regular.ttf", bold = "Fonts/NotoSansSC-Black.ttf",
    }}},
    colors = {
        primary = C.amber, primaryHover = {242, 199, 131, 255}, primaryPressed = {177, 130, 64, 255},
        secondary = {35, 43, 49, 255}, secondaryHover = {48, 58, 65, 255}, secondaryPressed = {21, 27, 32, 255},
        background = {10, 13, 16, 255}, surface = C.dark, surfaceHover = {33, 41, 47, 255},
        surfaceAlt = {24, 30, 35, 255}, text = C.white, textSecondary = C.muted,
        textDisabled = {118, 129, 137, 255}, disabledText = {130, 141, 149, 255},
        disabled = {31, 37, 42, 255}, disabledBorder = C.border,
        border = C.border, borderFocus = C.cyan, success = C.green, successHover = C.green,
        warning = C.amber, error = C.red, errorHover = C.red, info = C.cyan,
        hover = {255, 255, 255, 12}, overlay = {4, 7, 10, 218},
    },
    radius = {none = 0, xs = 0, sm = 2, md = 4, lg = 6, full = 999},
    componentDefaults = {borderRadius = 0},
    components = {
        Label = {fontWeight = "normal", lineHeight = 1.3},
        Button = {
            height = 44, fontSize = 11, fontWeight = "bold", borderRadius = 0,
            borderWidth = {1, 1, 2, 1}, borderColor = {95, 108, 116, 150},
            padding = {0, 14, 2, 14}, pressedPadding = {1, 14, 0, 14},
            boxShadow = {{x = 0, y = 2, blur = 0, color = {0, 0, 0, 65}}},
            pressedBoxShadow = false, disabledBoxShadow = false,
            variantTextColor = {primary = {22, 24, 26, 255}, secondary = C.white},
            variantBackgroundGradient = {
                primary = Racing.Gradient({239, 195, 128, 255}, {201, 149, 74, 255}),
                secondary = Racing.Gradient({43, 52, 59, 250}, {26, 32, 38, 250}),
            },
            variantHoverBackgroundGradient = {
                primary = Racing.Gradient({250, 213, 153, 255}, {222, 174, 107, 255}),
                secondary = Racing.Gradient({54, 66, 74, 255}, {34, 43, 51, 255}),
            },
            variantPressedBackgroundGradient = {
                primary = Racing.Gradient({170, 123, 61, 255}, {202, 151, 81, 255}),
                secondary = Racing.Gradient({21, 27, 32, 255}, {36, 45, 52, 255}),
            },
            disabledBackgroundGradient = Racing.Gradient({37, 43, 48, 255}, {26, 31, 36, 255}),
        },
        Card = {
            borderRadius = 2, borderWidth = 1, borderColor = C.border, boxShadow = shadow,
            backgroundGradient = Racing.Gradient({29, 36, 42, 250}, {16, 21, 26, 252}),
            padding = 14, gap = 8, showDividers = false,
        },
        Modal = {
            borderRadius = 2, borderWidth = 1, borderColor = {101, 121, 130, 255}, boxShadow = shadow,
            backgroundColor = C.dark, headerBgColor = {30, 39, 45, 255}, contentBgColor = C.dark,
            headerStripeHeight = 2, headerStripeColor = C.cyan, headerHeight = 54,
            titleFontSize = 15, titleFontWeight = "bold", titleTextColor = C.white,
            headerBorderWidth = 0, footerBorderWidth = 0, headerContentGap = 12,
            contentPadding = {10, 20, 10, 20}, contentGap = 10, footerPadding = {8, 20, 18, 20},
        },
        ProgressBar = {height = 4, borderWidth = 0, borderRadius = 0, showLabel = false,
            backgroundColor = {98, 116, 128, 60}},
        Slider = {trackHeight = 3, trackBgColor = C.border, trackFillColor = C.cyan,
            thumbColor = C.cyan, thumbSize = 16, thumbBorderRadius = 1, thumbBorderWidth = 1,
            thumbBorderColor = {177, 231, 233, 255}},
        Toast = {borderRadius = 2, borderWidth = 1, borderColor = C.border, boxShadow = shadow, showIcon = false},
    },
})

function Racing.Label(text, size, color, props)
    props = props or {}
    props.text, props.fontSize, props.fontColor = text, size or 11, color or C.white
    props.pointerEvents = "none"
    return UI.Label(props)
end
function Racing.Button(text, callback, primary, width, props)
    props = props or {}
    props.text, props.onClick, props.variant, props.width = text, callback, primary and "primary" or "secondary", width
    return UI.Button(props)
end
function Racing.Card(props)
    props = props or {}
    props.variant = props.variant or "outlined"
    return UI.Card(props)
end
function Racing.Kicker(text, props)
    props = props or {}
    props.fontWeight, props.letterSpacing = "bold", 1.2
    return Racing.Label(text, 9, C.cyan, props)
end
function Racing.Full(props)
    props = props or {}
    props.position, props.left, props.top, props.right, props.bottom = "absolute", 0, 0, 0, 0
    props.padding = props.padding or 0
    return props
end
-- Material surfaces for existing driver controls: style-only, never alter hit geometry.
function Racing.ControlSurface(pressed, active, blocked)
    local top = pressed and {88, 70, 45, 242} or (active and {37, 74, 79, 242} or {42, 50, 56, 232})
    local bottom = pressed and {50, 40, 28, 245} or (active and {19, 42, 48, 245} or {14, 20, 25, 228})
    return {
        backgroundColor = bottom, backgroundGradient = Racing.Gradient(top, bottom),
        borderColor = pressed and C.amber or (active and C.cyan or (blocked and {151, 101, 88, 190} or {137, 156, 168, 135})),
        borderWidth = 1, borderRadius = 4,
        boxShadow = {{x = 0, y = 1, blur = 0, inset = true, color = {227, 238, 241, 28}},
            {x = 0, y = 2, blur = 0, color = {0, 0, 0, 60}}},
    }
end
return Racing
