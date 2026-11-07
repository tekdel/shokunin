-- Hyprland configuration (Lua, Hyprland 0.57+; hyprlang .conf is no longer supported)
-- API stubs: /usr/share/hypr/stubs/hl.meta.lua
-- Validate: Hyprland --verify-config -c ~/.config/hypr/hyprland.lua

-- Monitor configuration
-- Run 'hyprctl monitors all' to see connected monitors
-- Default: native resolution with auto position, scale 2
hl.monitor({ output = "", mode = "highres", position = "auto", scale = 2 })

-- Workspace binding to monitors (optional)
-- hl.workspace_rule({ workspace = "1", monitor = "desc:LG Electronics LG UltraFine" })

-- Execute at launch
hl.on("hyprland.start", function()
    hl.exec_cmd("waybar")
    hl.exec_cmd("mako")
    hl.exec_cmd("kanshi")
    hl.exec_cmd("elephant")
    hl.exec_cmd("/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1")
    hl.exec_cmd("wl-paste --watch cliphist store")
    hl.exec_cmd("hypridle")
    hl.exec_cmd("swayosd-server")
end)

-- Environment variables
hl.env("XCURSOR_SIZE", "24")
hl.env("XCURSOR_THEME", "Adwaita")
hl.env("XDG_CURRENT_DESKTOP", "Hyprland")
hl.env("XDG_SESSION_TYPE", "wayland")
hl.env("XDG_SESSION_DESKTOP", "Hyprland")

-- NVIDIA Wayland support (only when the proprietary driver is loaded)
local nvidia = io.open("/proc/driver/nvidia/version", "r")
if nvidia then
    nvidia:close()
    hl.env("LIBVA_DRIVER_NAME", "nvidia")
    hl.env("GBM_BACKEND", "nvidia-drm")
    hl.env("__GLX_VENDOR_LIBRARY_NAME", "nvidia")
    hl.env("NVD_BACKEND", "direct")
end

hl.config({
    input = {
        kb_layout = "us",
        kb_options = "caps:escape",
        follow_mouse = 1,
        touchpad = {
            natural_scroll = true,
            scroll_factor = 0.4,
        },
        sensitivity = 0,
    },

    -- Clean minimal look (Gruvbox theme)
    general = {
        gaps_in = 0,
        gaps_out = 0,
        border_size = 1,
        col = {
            active_border = "rgba(83a598ff)",
            inactive_border = "rgba(3c3836ff)",
        },
        layout = "dwindle",
    },

    decoration = {
        rounding = 0,
        blur = { enabled = false },
        shadow = { enabled = false },
    },

    animations = { enabled = false },

    misc = {
        disable_hyprland_logo = true,
        disable_splash_rendering = true,
        background_color = "rgb(282828)",
    },

    dwindle = { preserve_split = true },
})

hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })

-- Window rules - floating
for _, class in ipairs({ "pavucontrol", "pulsemixer", "bluetui", "nm-connection-editor" }) do
    hl.window_rule({ match = { class = "^(" .. class .. ")$" }, float = true })
end
for _, title in ipairs({ "File Operation", "Open", "Save" }) do
    hl.window_rule({ match = { title = "^(" .. title .. ")$" }, float = true })
end

-- Window rules - workspace assignments
local workspace_classes = {
    { "firefox", 3 },
    { "chromium", 3 },
    { "google-chrome", 3 },
    { "brave-browser", 3 },
    { "Google-chrome", 3 },
    { "Slack", 4 },
    { "DBeaver", 5 },
    { "org.keepassxc.KeePassXC", 8 },
    { "spotify", 10 },
}
for _, rule in ipairs(workspace_classes) do
    hl.window_rule({ match = { class = "^(" .. rule[1] .. ")$" }, workspace = rule[2] .. " silent" })
end

-- Keybindings
local mainMod = "SUPER"
local function key(k) return mainMod .. " + " .. k end
local exec = hl.dsp.exec_cmd

-- Application shortcuts
hl.bind(key("Return"), exec("alacritty"))
hl.bind(key("Q"), hl.dsp.window.close())
hl.bind(key("SHIFT + E"), exec("~/.local/bin/power-menu"))
hl.bind(key("SHIFT + L"), exec("hyprlock"))
hl.bind(key("E"), exec("nautilus"))
hl.bind(key("V"), hl.dsp.window.float({ action = "toggle" }))
hl.bind(key("D"), exec("walker"))
hl.bind(key("P"), hl.dsp.window.pseudo())
hl.bind(key("SHIFT + J"), hl.dsp.layout("togglesplit"))
hl.bind(key("F"), hl.dsp.window.fullscreen({ action = "toggle", mode = "fullscreen" }))
hl.bind(key("SHIFT + B"), exec("google-chrome-canary"))

-- Move focus (arrows + vim keys) and move window (CTRL + vim keys)
for _, d in ipairs({
    { "left", "h", "left" },
    { "right", "l", "right" },
    { "up", "k", "up" },
    { "down", "j", "down" },
}) do
    hl.bind(key(d[1]), hl.dsp.focus({ direction = d[3] }))
    hl.bind(key(d[2]), hl.dsp.focus({ direction = d[3] }))
    hl.bind(key("CTRL + " .. d[2]), hl.dsp.window.move({ direction = d[3] }))
end

-- Switch workspaces / move window to workspace silently
for i = 1, 10 do
    local k = tostring(i % 10) -- workspace 10 on key 0
    hl.bind(key(k), hl.dsp.focus({ workspace = tostring(i) }))
    hl.bind(key("SHIFT + " .. k), hl.dsp.window.move({ workspace = tostring(i), follow = false }))
end

-- Mouse bindings
hl.bind(key("mouse:272"), hl.dsp.window.drag(), { mouse = true })
hl.bind(key("mouse:273"), hl.dsp.window.resize(), { mouse = true })

-- Screenshot (auto-saves to ~/pictures/screenshots/)
hl.bind("Print", exec("~/.local/bin/screenshot"))
hl.bind("SHIFT + Print", exec("~/.local/bin/screenshot --fullscreen"))
hl.bind(key("Print"), exec([[FILE=~/pictures/screenshots/screenshot-$(date +%Y%m%d-%H%M%S).png && mkdir -p ~/pictures/screenshots && grim -g "$(slurp)" "$FILE" && wl-copy < "$FILE"]]))

-- Screen recording (OBS Studio)
hl.bind(key("SHIFT + R"), exec("obs"))

-- Volume control (swayosd for OSD)
hl.bind("XF86AudioRaiseVolume", exec("swayosd-client --output-volume raise"))
hl.bind("XF86AudioLowerVolume", exec("swayosd-client --output-volume lower"))
hl.bind("XF86AudioMute", exec("swayosd-client --output-volume mute-toggle"))
hl.bind(key("minus"), exec("swayosd-client --output-volume -5"), { repeating = true })
hl.bind(key("equal"), exec("swayosd-client --output-volume +5"), { repeating = true })
hl.bind(key("SHIFT + A"), exec("alacritty -e pulsemixer"))

-- Media control (swayosd for OSD)
hl.bind("XF86AudioPlay", exec("swayosd-client --playerctl play-pause"))
hl.bind("XF86AudioStop", exec("playerctl stop"))
hl.bind("XF86AudioNext", exec("swayosd-client --playerctl next"))
hl.bind("XF86AudioPrev", exec("swayosd-client --playerctl previous"))

-- Brightness control (swayosd for OSD)
hl.bind("XF86MonBrightnessUp", exec("swayosd-client --brightness raise"))
hl.bind("XF86MonBrightnessDown", exec("swayosd-client --brightness lower"))

-- Airplane mode
hl.bind("XF86RFKill", exec("~/.local/bin/airplane-mode"))

-- Clipboard history
hl.bind(key("C"), exec("cliphist list | walker --dmenu | cliphist decode | wl-copy"))

-- Monitor switch
hl.bind(key("SHIFT + M"), exec("~/.local/bin/monitor-switch"))
-- Emergency: force laptop display on with auto-detected resolution (press blind if no display)
-- Works with Z13 (1920x1200), Framework 13 2.2K (2256x1504), and Framework 13 2.8K (2880x1920)
hl.bind(key("SHIFT + F12"), function()
    hl.monitor({ output = "eDP-1", mode = "preferred", position = "auto", scale = 1 })
end)
