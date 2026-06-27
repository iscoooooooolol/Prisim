--[[
===============================================================================
    PRISM UI LIBRARY  ·  v1.0.0
    Dynamic HSV theming · Neumorphic surfaces · Buttery animations · Full mobile
===============================================================================

    A premium Roblox UI library. One accent color drives the entire palette
    via HSV math. Soft neumorphic shadows, spring physics on every interaction,
    ripple effects on clicks, and full mobile parity.

    Quick start:
        local Prism = loadstring(game:HttpGet('your_url'))()
        local Window = Prism:CreateWindow({
            Name = "My Script",
            Accent = Color3.fromRGB(120, 180, 255),
        })
        local Tab = Window:CreateTab({ Name = "Main", Icon = "rbxassetid://0" })
        local Section = Tab:CreateSection({ Name = "Combat" })
        Section:CreateToggle({
            Name = "Aimbot",
            CurrentValue = false,
            Callback = function(state) print("Aimbot:", state) end,
        })
        Window:Build()

    Theme overrides (optional):
        Prism:SetTheme({
            Surface = Color3.fromRGB(40, 44, 52),  -- main background
            Radius = 16,                            -- global corner radius
            ToggleSpeed = 0.18,                     -- toggle spring duration
        })

    Config save/load:
        Prism:LoadConfig()  -- loads from getgenv().Prism_Config or default key
        Window:SaveConfig() -- saves current state of every flag
]]

--===========================================================================
-- SERVICES
--===========================================================================
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local ContextActionService = game:GetService("ContextActionService")
local CoreGui = game:GetService("CoreGui")
local TextService = game:GetService("TextService")
local GuiService = game:GetService("GuiService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local Screen = Instance.new("ScreenGui")
Screen.Name = "PrismUI"
Screen.ResetOnSpawn = false
Screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
Screen.IgnoreGuiInset = true
-- Try to parent to CoreGui (executors), fall back to PlayerGui
pcall(function() Screen.Parent = CoreGui end)
if not Screen.Parent then Screen.Parent = PlayerGui end

-- Prevent double-load via getgenv if available
pcall(function()
    if getgenv and getgenv().Prism_Loaded then
        local existing = getgenv().Prism_Instance
        if existing then return existing end
    end
end)

--===========================================================================
-- MOBILE DETECTION
--===========================================================================
local IsMobile = (UserInputService.TouchEnabled and not UserInputService.MouseEnabled)
local Scale = IsMobile and 0.85 or 1.0
local TouchHitbox = 44 -- minimum touch target size in pixels

--===========================================================================
-- COLOR MATH (HSV-based dynamic theming)
--===========================================================================
local Color = {}

function Color.fromHex(hex)
    hex = hex:gsub("#", "")
    return Color3.fromRGB(
        tonumber(hex:sub(1, 2), 16) or 0,
        tonumber(hex:sub(3, 4), 16) or 0,
        tonumber(hex:sub(5, 6), 16) or 0
    )
end

function Color.toHex(c)
    return string.format("#%02X%02X%02X", c.R * 255, c.G * 255, c.B * 255)
end

function Color.shiftHsv(c, dh, ds, dv)
    local h, s, v = Color3.toHSV(c)
    h = (h + dh) % 1
    s = math.clamp(s + ds, 0, 1)
    v = math.clamp(v + dv, 0, 1)
    return Color3.fromHSV(h, s, v)
end

function Color.lighten(c, amount)
    local h, s, v = Color3.toHSV(c)
    return Color3.fromHSV(h, s, math.clamp(v + amount, 0, 1))
end

function Color.darken(c, amount)
    return Color.lighten(c, -amount)
end

function Color.saturate(c, amount)
    local h, s, v = Color3.toHSV(c)
    return Color3.fromHSV(h, math.clamp(s + amount, 0, 1), v)
end

function Color.lerp(a, b, t)
    return Color3.fromRGB(
        math.floor(a.R * 255 + (b.R - a.R) * 255 * t + 0.5),
        math.floor(a.G * 255 + (b.G - a.G) * 255 * t + 0.5),
        math.floor(a.B * 255 + (b.B - a.B) * 255 * t + 0.5)
    )
end

-- Transparency-lerp helper: returns a number between two transparency values
local function lerpT(a, b, t) return a + (b - a) * t end

--===========================================================================
-- TWEEN HELPERS
--===========================================================================
local EASE = {
    SNAPPY   = { time = 0.16, style = Enum.EasingStyle.Quint, dir = Enum.EasingDirection.Out },
    SMOOTH   = { time = 0.24, style = Enum.EasingStyle.Quad,  dir = Enum.EasingDirection.Out },
    SPRING   = { time = 0.32, style = Enum.EasingStyle.Back,  dir = Enum.EasingDirection.Out },
    BOUNCE   = { time = 0.42, style = Enum.EasingStyle.Back,  dir = Enum.EasingDirection.Out },
}

local function tween(instance, props, preset)
    preset = preset or EASE.SMOOTH
    local info = TweenInfo.new(preset.time, preset.style, preset.dir)
    local t = TweenService:Create(instance, info, props)
    t:Play()
    return t
end

-- Multi-instance tween (for neumorphic shadow groups)
local function tweenMulti(instances, props, preset)
    preset = preset or EASE.SMOOTH
    local info = TweenInfo.new(preset.time, preset.style, preset.dir)
    local tweens = {}
    for _, inst in ipairs(instances) do
        local t = TweenService:Create(inst, info, props)
        t:Play()
        table.insert(tweens, t)
    end
    return tweens
end

--===========================================================================
-- SPRING PHYSICS (for buttery toggles + sliders)
--===========================================================================
local Spring = {}
Spring.__index = Spring

function Spring.new(initial, stiffness, damping)
    local self = setmetatable({}, Spring)
    self.Position = initial or 0
    self.Target = initial or 0
    self.Velocity = 0
    self.Stiffness = stiffness or 200
    self.Damping = damping or 22
    return self
end

function Spring:Update(dt)
    local force = (self.Target - self.Position) * self.Stiffness
    local damp = self.Velocity * self.Damping
    self.Velocity = self.Velocity + (force - damp) * dt
    self.Position = self.Position + self.Velocity * dt
    return self.Position
end

function Spring:Set(target)
    self.Target = target
end

function Spring:Snap(value)
    self.Position = value
    self.Target = value
    self.Velocity = 0
end

--===========================================================================
-- DYNAMIC HSV THEME SYSTEM
--===========================================================================
-- User picks ONE accent color. Everything else derives from HSV math.
local Theme = {
    Accent       = Color3.fromRGB(120, 180, 255),
    Surface      = Color3.fromRGB(46, 50, 60),     -- main background
    SurfaceHi    = Color3.fromRGB(54, 58, 70),     -- raised panels
    SurfaceLo    = Color3.fromRGB(38, 42, 52),     -- pressed / inset
    Text         = Color3.fromRGB(232, 236, 244),
    TextDim      = Color3.fromRGB(148, 154, 168),
    TextMuted    = Color3.fromRGB(96, 102, 116),
    Divider      = Color3.fromRGB(28, 32, 40),
    Success      = Color3.fromRGB(108, 216, 144),
    Warning      = Color3.fromRGB(244, 196, 96),
    Danger       = Color3.fromRGB(232, 96, 112),
    -- derived (recomputed when Accent changes)
    AccentDim    = Color3.fromRGB(80, 130, 200),
    AccentBright = Color3.fromRGB(180, 220, 255),
    AccentGlow   = Color3.fromRGB(120, 180, 255),
    AccentDark   = Color3.fromRGB(60, 100, 160),
    -- shadow colors (neumorphic dual-shadow)
    ShadowLight  = Color3.fromRGB(70, 76, 92),
    ShadowDark   = Color3.fromRGB(20, 22, 28),
    -- numeric params
    Radius       = 16,
    ShadowOffset = 3,
    ToggleSpeed  = 0.18,
    SliderSpeed  = 0.10,
    NotificationDuration = 4.0,
}

-- Recompute all derived colors from Accent + Surface
function Theme:Rebuild()
    local a = self.Accent
    self.AccentDim    = Color.shiftHsv(a, 0, 0.05, -0.18)
    self.AccentBright = Color.shiftHsv(a, -0.02, -0.10, 0.10)
    self.AccentGlow   = Color.shiftHsv(a, 0, 0.08, 0.0)
    self.AccentDark   = Color.shiftHsv(a, 0, 0.08, -0.30)

    -- Derived neumorphic shadow colors from Surface
    self.ShadowLight = Color.lighten(self.Surface, 0.10)
    self.ShadowDark  = Color.darken(self.Surface, 0.18)
    self.SurfaceHi   = Color.lighten(self.Surface, 0.04)
    self.SurfaceLo   = Color.darken(self.Surface, 0.05)
end
Theme:Rebuild()

-- Allow user overrides
local function ApplyThemeOverrides(overrides)
    for k, v in pairs(overrides or {}) do
        Theme[k] = v
    end
    Theme:Rebuild()
end

--===========================================================================
-- NEUMORPHIC PRIMITIVES
--===========================================================================
-- Creates the soft dual-shadow effect: light top-left, dark bottom-right
-- The returned container has .Surface, .ShadowLight, .ShadowDark fields

local function uiCorner(parent, radius)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, radius or Theme.Radius)
    c.Parent = parent
    return c
end

local function uiStroke(parent, color, thickness, transparency)
    local s = Instance.new("UIStroke")
    s.Color = color or Theme.Divider
    s.Thickness = thickness or 1
    s.Transparency = transparency or 0.6
    s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    s.Parent = parent
    return s
end

local function uiGradient(parent, color1, color2, rotation)
    local g = Instance.new("UIGradient")
    g.Color = ColorSequence.new(color1, color2)
    g.Rotation = rotation or 90
    g.Parent = parent
    return g
end

local function uiPadding(parent, top, bottom, left, right)
    local p = Instance.new("UIPadding")
    p.PaddingTop = UDim.new(0, top or 8)
    p.PaddingBottom = UDim.new(0, bottom or 8)
    p.PaddingLeft = UDim.new(0, left or 8)
    p.PaddingRight = UDim.new(0, right or 8)
    p.Parent = parent
    return p
end

local function uiList(parent, direction, padding, align)
    local l = Instance.new("UIListLayout")
    l.FillDirection = direction or Enum.FillDirection.Vertical
    l.Padding = UDim.new(0, padding or 8)
    l.SortOrder = Enum.SortOrder.LayoutOrder
    l.HorizontalAlignment = align or Enum.HorizontalAlignment.Center
    l.Parent = parent
    return l
end

-- Create a neumorphic surface with dual soft shadows.
-- Returns: { Container, Surface, ShadowLight, ShadowDark, SetPressed(fn), SetRest() }
local function Neumorph(props)
    props = props or {}
    local size = props.Size or UDim2.fromOffset(100, 40)
    local pos = props.Position or UDim2.fromOffset(0, 0)
    local anchor = props.AnchorPoint or Vector2.new(0, 0)
    local radius = props.Radius or Theme.Radius
    local offset = props.ShadowOffset or Theme.ShadowOffset
    local color = props.Color or Theme.SurfaceHi
    local parent = props.Parent
    local layoutOrder = props.LayoutOrder
    local visible = props.Visible ~= false
    local zindex = props.ZIndex or 1

    local container = Instance.new("Frame")
    container.Name = props.Name or "Neumorph"
    container.Size = size
    container.Position = pos
    container.AnchorPoint = anchor
    container.BackgroundTransparency = 1
    container.LayoutOrder = layoutOrder or 0
    container.Visible = visible
    container.ZIndex = zindex
    container.Parent = parent

    -- Dark shadow (bottom-right) — slightly larger, offset positive
    local shadowDark = Instance.new("Frame")
    shadowDark.Name = "ShadowDark"
    shadowDark.Size = UDim2.fromScale(1, 1)
    shadowDark.Position = UDim2.fromOffset(offset, offset)
    shadowDark.BackgroundColor3 = Theme.ShadowDark
    shadowDark.BackgroundTransparency = 0.45
    shadowDark.ZIndex = zindex
    uiCorner(shadowDark, radius)
    shadowDark.Parent = container

    -- Light shadow (top-left) — slightly larger, offset negative
    local shadowLight = Instance.new("Frame")
    shadowLight.Name = "ShadowLight"
    shadowLight.Size = UDim2.fromScale(1, 1)
    shadowLight.Position = UDim2.fromOffset(-offset, -offset)
    shadowLight.BackgroundColor3 = Theme.ShadowLight
    shadowLight.BackgroundTransparency = 0.45
    shadowLight.ZIndex = zindex + 1
    uiCorner(shadowLight, radius)
    shadowLight.Parent = container

    -- Actual surface
    local surface = Instance.new("Frame")
    surface.Name = "Surface"
    surface.Size = UDim2.fromScale(1, 1)
    surface.BackgroundColor3 = color
    surface.BackgroundTransparency = 0
    surface.ZIndex = zindex + 2
    uiCorner(surface, radius)
    surface.Parent = container

    local pressed = false
    local function setPressed(state)
        pressed = state
        if state then
            -- invert shadows: dark top-left, light bottom-right
            tweenMulti({ shadowLight, shadowDark }, {
                BackgroundTransparency = 0.55,
            }, EASE.SNAPPY)
            TweenService:Create(shadowLight, TweenInfo.new(EASE.SNAPPY.time, EASE.SNAPPY.style, EASE.SNAPPY.dir), {
                Position = UDim2.fromOffset(offset, offset),
                BackgroundColor3 = Theme.ShadowDark,
            }):Play()
            TweenService:Create(shadowDark, TweenInfo.new(EASE.SNAPPY.time, EASE.SNAPPY.style, EASE.SNAPPY.dir), {
                Position = UDim2.fromOffset(-offset, -offset),
                BackgroundColor3 = Theme.ShadowLight,
            }):Play()
            tween(surface, { BackgroundColor3 = Theme.SurfaceLo }, EASE.SNAPPY)
        else
            TweenService:Create(shadowLight, TweenInfo.new(EASE.SNAPPY.time, EASE.SNAPPY.style, EASE.SNAPPY.dir), {
                Position = UDim2.fromOffset(-offset, -offset),
                BackgroundColor3 = Theme.ShadowLight,
                BackgroundTransparency = 0.45,
            }):Play()
            TweenService:Create(shadowDark, TweenInfo.new(EASE.SNAPPY.time, EASE.SNAPPY.style, EASE.SNAPPY.dir), {
                Position = UDim2.fromOffset(offset, offset),
                BackgroundColor3 = Theme.ShadowDark,
                BackgroundTransparency = 0.45,
            }):Play()
            tween(surface, { BackgroundColor3 = color }, EASE.SNAPPY)
        end
    end

    return {
        Container = container,
        Surface = surface,
        ShadowLight = shadowLight,
        ShadowDark = shadowDark,
        SetPressed = setPressed,
        SetColor = function(newColor)
            color = newColor
            if not pressed then tween(surface, { BackgroundColor3 = color }, EASE.SMOOTH) end
        end,
    }
end

--===========================================================================
-- RIPPLE EFFECT (on click)
--===========================================================================
local function ripple(parentFrame, absPosition, color)
    color = color or Color3.fromRGB(255, 255, 255)
    local ripple = Instance.new("Frame")
    ripple.Name = "Ripple"
    ripple.BackgroundColor3 = color
    ripple.BackgroundTransparency = 0.7
    ripple.AnchorPoint = Vector2.new(0.5, 0.5)
    ripple.ZIndex = 999
    uiCorner(ripple, 999)
    local relPos = Vector2.new(
        absPosition.X - parentFrame.AbsolutePosition.X,
        absPosition.Y - parentFrame.AbsolutePosition.Y
    )
    ripple.Position = UDim2.fromOffset(relPos.X, relPos.Y)
    ripple.Size = UDim2.fromOffset(0, 0)
    ripple.Parent = parentFrame
    local maxSize = math.max(parentFrame.AbsoluteSize.X, parentFrame.AbsoluteSize.Y) * 2.2
    TweenService:Create(ripple, TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        Size = UDim2.fromOffset(maxSize, maxSize),
        BackgroundTransparency = 1,
    }):Play()
    task.delay(0.55, function() ripple:Destroy() end)
end

--===========================================================================
-- LOGGER (F9 console integration)
--===========================================================================
local Logger = {
    enabled = true,
    prefix = "[Prism]",
    colors = {
        info    = Color3.fromRGB(180, 220, 255),
        success = Color3.fromRGB(108, 216, 144),
        warn    = Color3.fromRGB(244, 196, 96),
        error   = Color3.fromRGB(232, 96, 112),
    },
}
function Logger:log(level, msg, ...)
    if not self.enabled then return end
    local color = self.colors[level] or self.colors.info
    local full = string.format("%s %s", self.prefix, string.format(msg, ...))
    print(full)
end
function Logger:info(...)  self:log("info",  ...) end
function Logger:success(...) self:log("success", ...) end
function Logger:warn(...)  self:log("warn",  ...) end
function Logger:err(...)   self:log("error", ...) end

--===========================================================================
-- NOTIFICATION SYSTEM (stacking queue)
--===========================================================================
local Notifications = {
    queue = {},
    active = {},
    max_active = 4,
    container = nil,
}

function Notifications:Init()
    if self.container then return end
    local c = Instance.new("Frame")
    c.Name = "NotificationContainer"
    c.AnchorPoint = Vector2.new(1, 0)
    c.Position = UDim2.new(1, -16, 0, 16)
    c.Size = UDim2.fromOffset(320, 0)
    c.BackgroundTransparency = 1
    c.ZIndex = 10000
    local layout = Instance.new("UIListLayout")
    layout.FillDirection = Enum.FillDirection.Vertical
    layout.Padding = UDim.new(0, 10)
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
    layout.VerticalAlignment = Enum.VerticalAlignment.Top
    layout.Parent = c
    c.Parent = Screen
    self.container = c
end

function Notifications:Show(opts)
    self:Init()
    opts = opts or {}
    local notif = {
        title = opts.title or "Notification",
        content = opts.content or "",
        duration = opts.duration or Theme.NotificationDuration,
        icon = opts.icon,
        color = opts.color or Theme.Accent,
        kind = opts.kind or "info", -- info | success | warning | error
    }
    if #self.active >= self.max_active then
        table.insert(self.queue, notif)
        return
    end
    self:Render(notif)
end

function Notifications:Render(notif)
    local accent
    if notif.kind == "success" then accent = Theme.Success
    elseif notif.kind == "warning" then accent = Theme.Warning
    elseif notif.kind == "error" then accent = Theme.Danger
    else accent = notif.color or Theme.Accent end

    local frame = Instance.new("Frame")
    frame.Name = "Notification"
    frame.Size = UDim2.fromScale(1, 0)
    frame.AutomaticSize = Enum.AutomaticSize.Y
    frame.BackgroundColor3 = Theme.SurfaceHi
    frame.BackgroundTransparency = 0.0
    frame.AnchorPoint = Vector2.new(1, 0)
    frame.Position = UDim2.new(1, 60, 0, 0) -- start off-screen right
    frame.ZIndex = 10001
    uiCorner(frame, 14)
    uiStroke(frame, accent, 1.5, 0.4)
    frame.Parent = self.container
    table.insert(self.active, frame)

    local pad = uiPadding(frame, 14, 14, 16, 16)

    -- Accent bar on left
    local bar = Instance.new("Frame")
    bar.Name = "AccentBar"
    bar.Size = UDim2.fromOffset(4, 0)
    bar.AnchorPoint = Vector2.new(0, 0.5)
    bar.Position = UDim2.fromOffset(0, 0.5)
    bar.BackgroundColor3 = accent
    bar.BorderSizePixel = 0
    bar.ZIndex = 10002
    uiCorner(bar, 2)
    bar.Parent = frame

    local contentWrap = Instance.new("Frame")
    contentWrap.BackgroundTransparency = 1
    contentWrap.Size = UDim2.fromScale(1, 1)
    contentWrap.AutomaticSize = Enum.AutomaticSize.Y
    contentWrap.Position = UDim2.fromOffset(12, 0)
    contentWrap.ZIndex = 10003
    contentWrap.Parent = frame
    local cl = uiList(contentWrap, Enum.FillDirection.Vertical, 2, Enum.HorizontalAlignment.Left)

    local title = Instance.new("TextLabel")
    title.BackgroundTransparency = 1
    title.Size = UDim2.fromScale(1, 0)
    title.AutomaticSize = Enum.AutomaticSize.Y
    title.Font = Enum.Font.GothamBold
    title.TextSize = 14
    title.TextColor3 = accent
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Text = notif.title
    title.LayoutOrder = 1
    title.Parent = contentWrap

    local content = Instance.new("TextLabel")
    content.BackgroundTransparency = 1
    content.Size = UDim2.fromScale(1, 0)
    content.AutomaticSize = Enum.AutomaticSize.Y
    content.Font = Enum.Font.Gotham
    content.TextSize = 13
    content.TextColor3 = Theme.Text
    content.TextWrapped = true
    content.TextXAlignment = Enum.TextXAlignment.Left
    content.Text = notif.content
    content.LayoutOrder = 2
    content.Parent = contentWrap

    -- Progress bar at bottom
    local progressBg = Instance.new("Frame")
    progressBg.Name = "ProgressBg"
    progressBg.Size = UDim2.fromScale(1, 0)
    progressBg.Position = UDim2.fromScale(0, 1)
    progressBg.AnchorPoint = Vector2.new(0, 1)
    progressBg.BackgroundColor3 = Theme.SurfaceLo
    progressBg.BackgroundTransparency = 0.5
    progressBg.BorderSizePixel = 0
    progressBg.ZIndex = 10004
    uiCorner(progressBg, 14)
    progressBg.Parent = frame

    local progressBar = Instance.new("Frame")
    progressBar.Name = "ProgressBar"
    progressBar.Size = UDim2.fromScale(1, 2)
    progressBar.BackgroundColor3 = accent
    progressBar.BorderSizePixel = 0
    uiCorner(progressBar, 1)
    progressBar.Parent = progressBg

    -- Animate in
    task.spawn(function()
        TweenService:Create(frame, TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
            Position = UDim2.new(1, 0, 0, 0),
        }):Play()
        task.wait(0.1)
        frame.AutomaticSize = Enum.AutomaticSize.Y
        -- shrink progress bar
        TweenService:Create(progressBar, TweenInfo.new(notif.duration, Enum.EasingStyle.Linear), {
            Size = UDim2.fromScale(0, 2),
        }):Play()
        task.wait(notif.duration)
        -- Animate out
        TweenService:Create(frame, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
            Position = UDim2.new(1, 60, 0, 0),
            BackgroundTransparency = 1,
        }):Play()
        task.wait(0.3)
        -- remove from active list
        for i, f in ipairs(self.active) do
            if f == frame then table.remove(self.active, i) break end
        end
        frame:Destroy()
        -- process queue
        if #self.queue > 0 then
            local next = table.remove(self.queue, 1)
            self:Render(next)
        end
    end)
end

--===========================================================================
-- TOOLTIP SYSTEM (desktop only — hidden on touch devices)
--===========================================================================
local Tooltips = {
    current = nil,
    delay = 0.6,
}
function Tooltips:Show(text, anchorFrame)
    if IsMobile then return end
    self:Hide()
    if not text or text == "" then return end

    local tt = Instance.new("TextLabel")
    tt.Name = "Tooltip"
    tt.AnchorPoint = Vector2.new(0.5, 1)
    tt.Position = UDim2.fromOffset(
        anchorFrame.AbsolutePosition.X + anchorFrame.AbsoluteSize.X / 2,
        anchorFrame.AbsolutePosition.Y - 8
    )
    tt.AutomaticSize = Enum.AutomaticSize.XY
    tt.BackgroundColor3 = Theme.SurfaceLo
    tt.BackgroundTransparency = 0.05
    tt.Text = text
    tt.Font = Enum.Font.Gotham
    tt.TextSize = 12
    tt.TextColor3 = Theme.Text
    tt.ZIndex = 20000
    uiPadding(tt, 6, 6, 8, 8)
    uiCorner(tt, 6)
    uiStroke(tt, Theme.Divider, 1, 0.5)
    tt.Parent = Screen

    TweenService:Create(tt, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        TextTransparency = 0,
    }):Play()

    self.current = tt
end
function Tooltips:Hide()
    if self.current then
        local tt = self.current
        self.current = nil
        TweenService:Create(tt, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
            TextTransparency = 1,
            BackgroundTransparency = 1,
        }):Play()
        task.delay(0.12, function() tt:Destroy() end)
    end
end

--===========================================================================
-- HELPER: make any frame draggable + click+press state
--===========================================================================
local function makeButton(container, onPress)
    -- container is the neumorph surface frame
    local isPressed = false
    local isHovered = false

    container.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            isPressed = true
            if onPress then
                task.spawn(function()
                    local ok, err = pcall(onPress, input.Position)
                    if not ok then Logger:err("Button callback: %s", tostring(err)) end
                end)
            end
        elseif input.UserInputType == Enum.UserInputType.MouseMovement then
            isHovered = true
        end
    end)
    container.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            isPressed = false
        elseif input.UserInputType == Enum.UserInputType.MouseMovement then
            isHovered = false
        end
    end)
end

-- Drag-to-move helper (for windows + dropdowns)
local function makeDraggable(frame, handle)
    handle = handle or frame
    local dragging = false
    local dragStart, startPos

    handle.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = frame.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)
    handle.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch then
            if dragging then
                local delta = input.Position - dragStart
                frame.Position = UDim2.new(
                    startPos.X.Scale, startPos.X.Offset + delta.X,
                    startPos.Y.Scale, startPos.Y.Offset + delta.Y
                )
            end
        end
    end)
end

--===========================================================================
-- SHARED HELPERS (used by components below)
--===========================================================================
-- Register a flag with Prism.Flags for save/load.
-- Uses _G.__PRISM_REF (set after Prism is fully defined below) so components
-- defined BEFORE Prism can still register flags at runtime.
local function RegisterFlag(name, getFn, setFn)
    if not name then return end
    if _G.__PRISM_REF then
        _G.__PRISM_REF.Flags[name] = { Get = getFn, Set = setFn }
    end
end

-- Attach tooltip (desktop only — auto-hidden on mobile)
local function AttachTooltip(frame, text)
    if not text or IsMobile then return end
    local timer = nil
    frame.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement then
            timer = task.delay(Tooltips.delay, function()
                Tooltips:Show(text, frame)
            end)
        end
    end)
    frame.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement then
            if timer then task.cancel(timer) timer = nil end
            Tooltips:Hide()
        end
    end)
    frame.AncestryChanged:Connect(function()
        if not frame:IsDescendantOf(game) then Tooltips:Hide() end
    end)
end

-- Hover state helper
local function AttachHover(frame, onEnter, onLeave)
    frame.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement and onEnter then onEnter() end
    end)
    frame.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement and onLeave then onLeave() end
    end)
end

--===========================================================================
-- LABEL
--===========================================================================
local function CreateLabel(parent, opts)
    opts = opts or {}
    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Size = UDim2.fromScale(1, 0)
    label.AutomaticSize = Enum.AutomaticSize.Y
    label.Font = opts.Bold and Enum.Font.GothamBold or Enum.Font.Gotham
    label.TextSize = opts.Size or 14
    label.TextColor3 = opts.Dim and Theme.TextDim or Theme.Text
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.TextYAlignment = Enum.TextYAlignment.Center
    label.TextWrapped = true
    label.Text = opts.Text or "Label"
    label.LayoutOrder = opts.LayoutOrder or 0
    label.Parent = parent
    AttachTooltip(label, opts.Tooltip)
    return { Frame = label, Set = function(t) label.Text = t end }
end

--===========================================================================
-- DIVIDER
--===========================================================================
local function CreateDivider(parent, opts)
    opts = opts or {}
    local wrap = Instance.new("Frame")
    wrap.BackgroundTransparency = 1
    wrap.Size = UDim2.fromScale(1, 0)
    wrap.AutomaticSize = Enum.AutomaticSize.Y
    wrap.LayoutOrder = opts.LayoutOrder or 0
    wrap.Parent = parent

    local holder = Instance.new("Frame")
    holder.BackgroundTransparency = 1
    holder.Size = UDim2.fromScale(1, 18)
    holder.AnchorPoint = Vector2.new(0, 0.5)
    holder.Position = UDim2.fromScale(0, 0.5)
    holder.Parent = wrap

    local line = Instance.new("Frame")
    line.Size = UDim2.fromScale(1, 1)
    line.Position = UDim2.fromScale(0, 0.5)
    line.AnchorPoint = Vector2.new(0, 0.5)
    line.BackgroundColor3 = Theme.Divider
    line.BorderSizePixel = 0
    line.Parent = holder

    if opts.Text then
        local text = Instance.new("TextLabel")
        text.BackgroundTransparency = 0
        text.BackgroundColor3 = Theme.SurfaceHi
        text.AnchorPoint = Vector2.new(0.5, 0.5)
        text.Position = UDim2.fromScale(0.5, 0.5)
        text.Font = Enum.Font.GothamBold
        text.TextSize = 10
        text.TextColor3 = Theme.TextMuted
        text.Text = opts.Text:upper()
        uiPadding(text, 0, 0, 8, 8)
        uiCorner(text, 4)
        text.Parent = holder
    end
    return { Frame = wrap }
end

--===========================================================================
-- BUTTON
--===========================================================================
local function CreateButton(parent, opts)
    opts = opts or {}
    local neu = Neumorph({
        Name = "Button",
        Size = UDim2.fromScale(1, 0) + UDim2.fromOffset(0, IsMobile and 48 or 40),
        Color = Theme.SurfaceHi,
        Radius = 12,
        ShadowOffset = 2,
        LayoutOrder = opts.LayoutOrder or 0,
        Parent = parent,
    })

    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Size = UDim2.fromScale(1, 1)
    label.Font = Enum.Font.GothamBold
    label.TextSize = 14
    label.TextColor3 = Theme.Text
    label.Text = opts.Name or "Button"
    label.ZIndex = neu.Surface.ZIndex + 1
    label.Parent = neu.Surface

    if opts.Icon then
        local icon = Instance.new("ImageLabel")
        icon.Size = UDim2.fromOffset(18, 18)
        icon.AnchorPoint = Vector2.new(0, 0.5)
        icon.Position = UDim2.fromOffset(14, 0.5)
        icon.BackgroundTransparency = 1
        icon.Image = opts.Icon
        icon.ImageColor3 = Theme.Accent
        icon.ZIndex = neu.Surface.ZIndex + 1
        icon.Parent = neu.Surface
        uiPadding(label, 0, 0, 40, 14)
    else
        uiPadding(label, 0, 0, 14, 14)
    end

    AttachTooltip(neu.Surface, opts.Tooltip)
    AttachHover(neu.Surface,
        function() tween(label, { TextColor3 = Theme.AccentBright }, EASE.SNAPPY) end,
        function() tween(label, { TextColor3 = Theme.Text }, EASE.SNAPPY) end
    )

    neu.Surface.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            neu.SetPressed(true)
            ripple(neu.Surface, input.Position, Theme.AccentBright)
            if opts.Callback then
                task.spawn(function()
                    local ok, err = pcall(opts.Callback)
                    if not ok then Logger:err("Button '%s': %s", opts.Name or "?", tostring(err)) end
                end)
            end
        end
    end)
    neu.Surface.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            neu.SetPressed(false)
        end
    end)

    return { Frame = neu.Container, SetName = function(n) label.Text = n end }
end

--===========================================================================
-- TOGGLE (spring physics)
--===========================================================================
local function CreateToggle(parent, opts)
    opts = opts or {}
    local state = opts.CurrentValue or false

    local neu = Neumorph({
        Name = "Toggle",
        Size = UDim2.fromScale(1, 0) + UDim2.fromOffset(0, IsMobile and 48 or 40),
        Color = Theme.SurfaceHi,
        Radius = 12,
        ShadowOffset = 2,
        LayoutOrder = opts.LayoutOrder or 0,
        Parent = parent,
    })

    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Position = UDim2.fromOffset(14, 0)
    label.Size = UDim2.fromOffset(180, 1)
    label.Font = Enum.Font.GothamMedium
    label.TextSize = 14
    label.TextColor3 = Theme.Text
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Text = opts.Name or "Toggle"
    label.ZIndex = neu.Surface.ZIndex + 1
    label.Parent = neu.Surface

    local railW, railH = 48, 26
    local rail = Instance.new("Frame")
    rail.Name = "Rail"
    rail.AnchorPoint = Vector2.new(1, 0.5)
    rail.Position = UDim2.fromOffset(-14, 0.5)
    rail.Size = UDim2.fromOffset(railW, railH)
    rail.BackgroundColor3 = state and Theme.Accent or Theme.SurfaceLo
    rail.ZIndex = neu.Surface.ZIndex + 1
    uiCorner(rail, railH / 2)
    rail.Parent = neu.Surface

    local knob = Instance.new("Frame")
    knob.Name = "Knob"
    knob.AnchorPoint = Vector2.new(0.5, 0.5)
    knob.Size = UDim2.fromOffset(railH - 6, railH - 6)
    knob.Position = UDim2.new(0, state and (railW - railH/2) or railH/2, 0.5, 0)
    knob.BackgroundColor3 = state and Theme.AccentBright or Theme.Text
    knob.ZIndex = neu.Surface.ZIndex + 2
    uiCorner(knob, (railH - 6) / 2)
    knob.Parent = rail

    local spring = Spring.new(state and 1 or 0, 260, 26)
    local conn = RunService.RenderStepped:Connect(function(dt)
        local pos = spring:Update(dt)
        knob.Position = UDim2.new(0, railH/2 + pos * (railW - railH), 0.5, 0)
    end)

    local function setState(newState, silent)
        if newState == state then return end
        state = newState
        spring:Set(state and 1 or 0)
        tween(rail, { BackgroundColor3 = state and Theme.Accent or Theme.SurfaceLo }, EASE.SMOOTH)
        tween(knob, { BackgroundColor3 = state and Theme.AccentBright or Theme.Text }, EASE.SMOOTH)
        if not silent and opts.Callback then
            task.spawn(function()
                local ok, err = pcall(opts.Callback, state)
                if not ok then Logger:err("Toggle '%s': %s", opts.Name or "?", tostring(err)) end
            end)
        end
        Logger:info("[Toggle] %s = %s", opts.Name or "?", tostring(state))
    end

    neu.Surface.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            neu.SetPressed(true)
            ripple(neu.Surface, input.Position)
            setState(not state)
        end
    end)
    neu.Surface.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            neu.SetPressed(false)
        end
    end)

    AttachTooltip(neu.Surface, opts.Tooltip)

    RegisterFlag(opts.Flag, function() return state end, function(v, silent) setState(v, silent) end)

    return {
        Frame = neu.Container,
        Set = function(v, silent) setState(v, silent) end,
        Get = function() return state end,
    }
end

--===========================================================================
-- SLIDER (smooth drag with spring)
--===========================================================================
local function CreateSlider(parent, opts)
    opts = opts or {}
    local min = opts.Range and opts.Range[1] or 0
    local max = opts.Range and opts.Range[2] or 100
    local step = opts.Increment or 1
    local suffix = opts.Suffix or ""
    local value = math.clamp(opts.CurrentValue or min, min, max)

    local neu = Neumorph({
        Name = "Slider",
        Size = UDim2.fromScale(1, 0) + UDim2.fromOffset(0, IsMobile and 56 or 48),
        Color = Theme.SurfaceHi,
        Radius = 12,
        ShadowOffset = 2,
        LayoutOrder = opts.LayoutOrder or 0,
        Parent = parent,
    })

    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Position = UDim2.fromOffset(14, 6)
    label.Size = UDim2.fromOffset(180, 18)
    label.Font = Enum.Font.GothamMedium
    label.TextSize = 13
    label.TextColor3 = Theme.Text
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Text = opts.Name or "Slider"
    label.ZIndex = neu.Surface.ZIndex + 1
    label.Parent = neu.Surface

    local valueLabel = Instance.new("TextLabel")
    valueLabel.BackgroundTransparency = 1
    valueLabel.AnchorPoint = Vector2.new(1, 0)
    valueLabel.Position = UDim2.fromOffset(-14, 6)
    label.Size = UDim2.fromOffset(180, 18)
    valueLabel.Size = UDim2.fromOffset(80, 18)
    valueLabel.Font = Enum.Font.GothamBold
    valueLabel.TextSize = 13
    valueLabel.TextColor3 = Theme.AccentBright
    valueLabel.TextXAlignment = Enum.TextXAlignment.Right
    valueLabel.Text = string.format("%g%s", value, suffix)
    valueLabel.ZIndex = neu.Surface.ZIndex + 1
    valueLabel.Parent = neu.Surface

    -- Track (recessed)
    local track = Instance.new("Frame")
    track.Name = "Track"
    track.AnchorPoint = Vector2.new(0.5, 1)
    track.Position = UDim2.fromScale(0.5, 1) + UDim2.fromOffset(0, -10)
    track.Size = UDim2.fromScale(1, 0) + UDim2.fromOffset(-28, 6)
    track.BackgroundColor3 = Theme.SurfaceLo
    track.ZIndex = neu.Surface.ZIndex + 1
    uiCorner(track, 3)
    track.Parent = neu.Surface

    -- Filled portion
    local fill = Instance.new("Frame")
    fill.Name = "Fill"
    fill.Size = UDim2.fromScale((value - min) / (max - min), 1)
    fill.BackgroundColor3 = Theme.Accent
    fill.BorderSizePixel = 0
    uiCorner(fill, 3)
    fill.Parent = track

    -- Knob
    local knob = Instance.new("Frame")
    knob.Name = "Knob"
    knob.AnchorPoint = Vector2.new(0.5, 0.5)
    knob.Size = UDim2.fromOffset(18, 18)
    knob.Position = UDim2.fromScale((value - min) / (max - min), 0.5)
    knob.BackgroundColor3 = Theme.AccentBright
    knob.ZIndex = neu.Surface.ZIndex + 2
    uiCorner(knob, 9)
    knob.Parent = track

    -- spring for knob horizontal position
    local spring = Spring.new((value - min) / (max - min), 320, 28)
    local conn = RunService.RenderStepped:Connect(function(dt)
        local pos = spring:Update(dt)
        knob.Position = UDim2.fromScale(pos, 0.5)
        fill.Size = UDim2.fromScale(pos, 1)
    end)

    local dragging = false
    local function updateFromInput(inputPos)
        local relX = inputPos.X - track.AbsolutePosition.X
        local pct = math.clamp(relX / track.AbsoluteSize.X, 0, 1)
        local raw = min + pct * (max - min)
        -- snap to step
        local snapped = math.floor(raw / step + 0.5) * step
        snapped = math.clamp(snapped, min, max)
        if snapped ~= value then
            value = snapped
            spring:Set((value - min) / (max - min))
            valueLabel.Text = string.format("%g%s", value, suffix)
            if opts.Callback then
                task.spawn(function()
                    local ok, err = pcall(opts.Callback, value)
                    if not ok then Logger:err("Slider '%s': %s", opts.Name or "?", tostring(err)) end
                end)
            end
        end
    end

    track.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            updateFromInput(input.Position)
            knob.Size = UDim2.fromOffset(22, 22)
            TweenService:Create(knob, TweenInfo.new(0.1), { Size = UDim2.fromOffset(22, 22) }):Play()
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch) then
            updateFromInput(input.Position)
        end
    end)
    UserInputService.InputEnded:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch) then
            dragging = false
            TweenService:Create(knob, TweenInfo.new(0.1), { Size = UDim2.fromOffset(18, 18) }):Play()
        end
    end)

    AttachTooltip(neu.Surface, opts.Tooltip)

    local function setValue(v, silent)
        v = math.clamp(v, min, max)
        if v == value then return end
        value = v
        spring:Set((value - min) / (max - min))
        valueLabel.Text = string.format("%g%s", value, suffix)
        if not silent and opts.Callback then
            task.spawn(function() pcall(opts.Callback, value) end)
        end
    end

    RegisterFlag(opts.Flag, function() return value end, function(v, silent) setValue(v, silent) end)

    return {
        Frame = neu.Container,
        Set = function(v, silent) setValue(v, silent) end,
        Get = function() return value end,
    }
end

--===========================================================================
-- INPUT (TextBox)
--===========================================================================
local function CreateInput(parent, opts)
    opts = opts or {}
    local neu = Neumorph({
        Name = "Input",
        Size = UDim2.fromScale(1, 0) + UDim2.fromOffset(0, IsMobile and 48 or 40),
        Color = Theme.SurfaceLo,
        Radius = 12,
        ShadowOffset = 2,
        LayoutOrder = opts.LayoutOrder or 0,
        Parent = parent,
    })

    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Position = UDim2.fromOffset(14, 0)
    label.Size = UDim2.fromOffset(80, 1)
    label.Font = Enum.Font.GothamMedium
    label.TextSize = 13
    label.TextColor3 = Theme.TextDim
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Text = opts.Name or "Input"
    label.ZIndex = neu.Surface.ZIndex + 1
    label.Parent = neu.Surface

    local box = Instance.new("TextBox")
    box.BackgroundTransparency = 1
    box.AnchorPoint = Vector2.new(1, 0.5)
    box.Position = UDim2.fromOffset(-14, 0.5)
    box.Size = UDim2.fromOffset(180, 1)
    box.Font = Enum.Font.Gotham
    box.TextSize = 13
    box.TextColor3 = Theme.Text
    box.PlaceholderText = opts.PlaceholderText or ""
    box.PlaceholderColor3 = Theme.TextMuted
    box.Text = opts.CurrentValue or ""
    box.TextXAlignment = Enum.TextXAlignment.Right
    box.ClearTextOnFocus = false
    box.ZIndex = neu.Surface.ZIndex + 1
    box.Parent = neu.Surface

    local stroke = uiStroke(neu.Surface, Theme.Accent, 1.5, 1)

    box.Focused:Connect(function()
        tween(stroke, { Transparency = 0.2 }, EASE.SNAPPY)
        tween(neu.Surface, { BackgroundColor3 = Theme.SurfaceHi }, EASE.SNAPPY)
    end)
    box.FocusLost:Connect(function(enterPressed)
        tween(stroke, { Transparency = 1 }, EASE.SNAPPY)
        tween(neu.Surface, { BackgroundColor3 = Theme.SurfaceLo }, EASE.SNAPPY)
        if opts.Callback then
            task.spawn(function()
                local ok, err = pcall(opts.Callback, box.Text, enterPressed)
                if not ok then Logger:err("Input '%s': %s", opts.Name or "?", tostring(err)) end
            end)
        end
    end)

    AttachTooltip(neu.Surface, opts.Tooltip)

    RegisterFlag(opts.Flag, function() return box.Text end,
        function(v, silent) box.Text = v or "" if not silent and opts.Callback then pcall(opts.Callback, v, false) end end)

    return {
        Frame = neu.Container,
        Set = function(v) box.Text = v or "" end,
        Get = function() return box.Text end,
    }
end

--===========================================================================
-- DROPDOWN
--===========================================================================
local function CreateDropdown(parent, opts)
    opts = opts or {}
    local options = opts.Options or {}
    local selected = opts.CurrentValue or (options[1] ~= nil and options[1] or "")

    local neu = Neumorph({
        Name = "Dropdown",
        Size = UDim2.fromScale(1, 0) + UDim2.fromOffset(0, IsMobile and 48 or 40),
        Color = Theme.SurfaceHi,
        Radius = 12,
        ShadowOffset = 2,
        LayoutOrder = opts.LayoutOrder or 0,
        Parent = parent,
    })

    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Position = UDim2.fromOffset(14, 0)
    label.Size = UDim2.fromOffset(120, 1)
    label.Font = Enum.Font.GothamMedium
    label.TextSize = 13
    label.TextColor3 = Theme.TextDim
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Text = opts.Name or "Dropdown"
    label.ZIndex = neu.Surface.ZIndex + 1
    label.Parent = neu.Surface

    local valueLabel = Instance.new("TextLabel")
    valueLabel.BackgroundTransparency = 1
    valueLabel.AnchorPoint = Vector2.new(1, 0.5)
    valueLabel.Position = UDim2.fromOffset(-30, 0.5)
    valueLabel.Size = UDim2.fromOffset(140, 1)
    valueLabel.Font = Enum.Font.GothamBold
    valueLabel.TextSize = 13
    valueLabel.TextColor3 = Theme.Text
    valueLabel.TextXAlignment = Enum.TextXAlignment.Right
    valueLabel.Text = tostring(selected)
    valueLabel.ZIndex = neu.Surface.ZIndex + 1
    valueLabel.Parent = neu.Surface

    local chevron = Instance.new("ImageLabel")
    chevron.Size = UDim2.fromOffset(14, 14)
    chevron.AnchorPoint = Vector2.new(1, 0.5)
    chevron.Position = UDim2.fromOffset(-10, 0.5)
    chevron.BackgroundTransparency = 1
    chevron.Image = "rbxassetid://6031280882" -- chevron down
    chevron.ImageColor3 = Theme.TextDim
    chevron.ZIndex = neu.Surface.ZIndex + 1
    chevron.Parent = neu.Surface

    -- Popup container (parented to ScreenGui so it can overlay)
    local popup = Instance.new("Frame")
    popup.Name = "DropdownPopup"
    popup.Size = UDim2.fromOffset(neu.Surface.AbsoluteSize.X, 0)
    popup.Position = UDim2.fromOffset(neu.Surface.AbsolutePosition.X, neu.Surface.AbsolutePosition.Y + neu.Surface.AbsoluteSize.Y + 4)
    popup.BackgroundColor3 = Theme.SurfaceHi
    popup.BorderSizePixel = 0
    popup.Visible = false
    popup.ZIndex = 9000
    uiCorner(popup, 12)
    uiStroke(popup, Theme.Divider, 1, 0.4)
    popup.Parent = Screen
    local layout = uiList(popup, Enum.FillDirection.Vertical, 2, Enum.HorizontalAlignment.Center)
    uiPadding(popup, 6, 6, 6, 6)

    local function rebuildPopup()
        for _, c in ipairs(popup:GetChildren()) do
            if c:IsA("Frame") and c.Name ~= "UICorner" and c.Name ~= "UIStroke" and c.Name ~= "UIListLayout" and c.Name ~= "UIPadding" then
                c:Destroy()
            end
        end
        for i, opt in ipairs(options) do
            local item = Instance.new("TextButton")
            item.BackgroundTransparency = 1
            item.Size = UDim2.fromScale(1, 0) + UDim2.fromOffset(0, IsMobile and 40 or 32)
            item.Font = Enum.Font.Gotham
            item.TextSize = 13
            item.TextColor3 = (opt == selected) and Theme.AccentBright or Theme.Text
            item.Text = tostring(opt)
            item.TextXAlignment = Enum.TextXAlignment.Left
            uiPadding(item, 0, 0, 12, 12)
            item.Parent = popup
            item.MouseButton1Click:Connect(function()
                selected = opt
                valueLabel.Text = tostring(selected)
                popup.Visible = false
                tween(chevron, { Rotation = 0 }, EASE.SNAPPY)
                if opts.Callback then
                    task.spawn(function() pcall(opts.Callback, selected) end)
                end
                rebuildPopup()
            end)
            AttachHover(item,
                function() tween(item, { BackgroundTransparency = 0.7, BackgroundColor3 = Theme.Accent }) end,
                function() tween(item, { BackgroundTransparency = 1 }) end
            )
        end
        -- size popup
        local count = #options
        popup.Size = UDim2.fromOffset(neu.Surface.AbsoluteSize.X, count * (IsMobile and 40 or 32) + 12 + (count-1)*2)
        popup.Position = UDim2.fromOffset(neu.Surface.AbsolutePosition.X, neu.Surface.AbsolutePosition.Y + neu.Surface.AbsoluteSize.Y + 4)
    end

    local open = false
    local function setOpen(state)
        open = state
        if state then
            rebuildPopup()
            popup.Visible = true
            popup.Size = UDim2.fromOffset(neu.Surface.AbsoluteSize.X, 0)
            tween(chevron, { Rotation = 180 }, EASE.SNAPPY)
            TweenService:Create(popup, TweenInfo.new(0.18, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
                Size = UDim2.fromOffset(neu.Surface.AbsoluteSize.X, #options * (IsMobile and 40 or 32) + 12 + math.max(0, #options-1)*2),
            }):Play()
        else
            tween(chevron, { Rotation = 0 }, EASE.SNAPPY)
            TweenService:Create(popup, TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
                Size = UDim2.fromOffset(neu.Surface.AbsoluteSize.X, 0),
            }):Play()
            task.delay(0.14, function() popup.Visible = false end)
        end
    end

    neu.Surface.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            setOpen(not open)
        end
    end)

    -- Close on outside click
    UserInputService.InputBegan:Connect(function(input)
        if open and (input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch) then
            local mp = input.Position
            local pp = popup.AbsolutePosition
            local ps = popup.AbsoluteSize
            local sp = neu.Surface.AbsolutePosition
            local ss = neu.Surface.AbsoluteSize
            local inPopup = mp.X >= pp.X and mp.X <= pp.X + ps.X and mp.Y >= pp.Y and mp.Y <= pp.Y + ps.Y
            local inSurface = mp.X >= sp.X and mp.X <= sp.X + ss.X and mp.Y >= sp.Y and mp.Y <= sp.Y + ss.Y
            if not inPopup and not inSurface then setOpen(false) end
        end
    end)

    AttachTooltip(neu.Surface, opts.Tooltip)

    RegisterFlag(opts.Flag, function() return selected end,
        function(v, silent) selected = v valueLabel.Text = tostring(v) if not silent and opts.Callback then pcall(opts.Callback, v) end end)

    return {
        Frame = neu.Container,
        Set = function(v) selected = v valueLabel.Text = tostring(v) rebuildPopup() end,
        Get = function() return selected end,
        Refresh = function(newOpts) options = newOpts or {} rebuildPopup() end,
    }
end

--===========================================================================
-- MULTISELECT
--===========================================================================
local function CreateMultiSelect(parent, opts)
    opts = opts or {}
    local options = opts.Options or {}
    local selected = {}
    for _, v in ipairs(opts.CurrentValue or {}) do selected[v] = true end

    local neu = Neumorph({
        Name = "MultiSelect",
        Size = UDim2.fromScale(1, 0) + UDim2.fromOffset(0, IsMobile and 48 or 40),
        Color = Theme.SurfaceHi,
        Radius = 12,
        ShadowOffset = 2,
        LayoutOrder = opts.LayoutOrder or 0,
        Parent = parent,
    })

    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Position = UDim2.fromOffset(14, 0)
    label.Size = UDim2.fromOffset(120, 1)
    label.Font = Enum.Font.GothamMedium
    label.TextSize = 13
    label.TextColor3 = Theme.TextDim
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Text = opts.Name or "MultiSelect"
    label.ZIndex = neu.Surface.ZIndex + 1
    label.Parent = neu.Surface

    local valueLabel = Instance.new("TextLabel")
    valueLabel.BackgroundTransparency = 1
    valueLabel.AnchorPoint = Vector2.new(1, 0.5)
    valueLabel.Position = UDim2.fromOffset(-30, 0.5)
    valueLabel.Size = UDim2.fromOffset(160, 1)
    valueLabel.Font = Enum.Font.GothamBold
    valueLabel.TextSize = 12
    valueLabel.TextColor3 = Theme.AccentBright
    valueLabel.TextXAlignment = Enum.TextXAlignment.Right
    local function updateValueLabel()
        local n = 0
        for _ in pairs(selected) do n = n + 1 end
        valueLabel.Text = n == 0 and "None" or (n == #options and "All" or n .. " selected")
    end
    updateValueLabel()
    valueLabel.ZIndex = neu.Surface.ZIndex + 1
    valueLabel.Parent = neu.Surface

    local chevron = Instance.new("ImageLabel")
    chevron.Size = UDim2.fromOffset(14, 14)
    chevron.AnchorPoint = Vector2.new(1, 0.5)
    chevron.Position = UDim2.fromOffset(-10, 0.5)
    chevron.BackgroundTransparency = 1
    chevron.Image = "rbxassetid://6031280882"
    chevron.ImageColor3 = Theme.TextDim
    chevron.ZIndex = neu.Surface.ZIndex + 1
    chevron.Parent = neu.Surface

    local popup = Instance.new("Frame")
    popup.Name = "MultiSelectPopup"
    popup.BackgroundColor3 = Theme.SurfaceHi
    popup.BorderSizePixel = 0
    popup.Visible = false
    popup.ZIndex = 9000
    uiCorner(popup, 12)
    uiStroke(popup, Theme.Divider, 1, 0.4)
    popup.Parent = Screen
    uiList(popup, Enum.FillDirection.Vertical, 2, Enum.HorizontalAlignment.Center)
    uiPadding(popup, 6, 6, 6, 6)

    local function rebuildPopup()
        for _, c in ipairs(popup:GetChildren()) do
            if c:IsA("TextButton") then c:Destroy() end
        end
        for _, opt in ipairs(options) do
            local item = Instance.new("TextButton")
            item.BackgroundTransparency = 1
            item.Size = UDim2.fromScale(1, 0) + UDim2.fromOffset(0, IsMobile and 40 or 32)
            item.Font = Enum.Font.Gotham
            item.TextSize = 13
            item.TextColor3 = selected[opt] and Theme.AccentBright or Theme.Text
            item.Text = (selected[opt] and "●  " or "○  ") .. tostring(opt)
            item.TextXAlignment = Enum.TextXAlignment.Left
            uiPadding(item, 0, 0, 12, 12)
            item.Parent = popup
            item.MouseButton1Click:Connect(function()
                selected[opt] = not selected[opt]
                updateValueLabel()
                rebuildPopup()
                if opts.Callback then
                    local arr = {}
                    for _, o in ipairs(options) do if selected[o] then table.insert(arr, o) end end
                    task.spawn(function() pcall(opts.Callback, arr) end)
                end
            end)
        end
        popup.Size = UDim2.fromOffset(neu.Surface.AbsoluteSize.X, #options * (IsMobile and 40 or 32) + 12 + math.max(0, #options-1)*2)
        popup.Position = UDim2.fromOffset(neu.Surface.AbsolutePosition.X, neu.Surface.AbsolutePosition.Y + neu.Surface.AbsoluteSize.Y + 4)
    end

    local open = false
    local function setOpen(state)
        open = state
        if state then
            rebuildPopup()
            popup.Visible = true
            popup.Size = UDim2.fromOffset(neu.Surface.AbsoluteSize.X, 0)
            tween(chevron, { Rotation = 180 }, EASE.SNAPPY)
            TweenService:Create(popup, TweenInfo.new(0.18, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
                Size = UDim2.fromOffset(neu.Surface.AbsoluteSize.X, #options * (IsMobile and 40 or 32) + 12 + math.max(0, #options-1)*2),
            }):Play()
        else
            tween(chevron, { Rotation = 0 }, EASE.SNAPPY)
            TweenService:Create(popup, TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
                Size = UDim2.fromOffset(neu.Surface.AbsoluteSize.X, 0),
            }):Play()
            task.delay(0.14, function() popup.Visible = false end)
        end
    end

    neu.Surface.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            setOpen(not open)
        end
    end)
    UserInputService.InputBegan:Connect(function(input)
        if open and (input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch) then
            local mp = input.Position
            local pp = popup.AbsolutePosition
            local ps = popup.AbsoluteSize
            local sp = neu.Surface.AbsolutePosition
            local ss = neu.Surface.AbsoluteSize
            local inPopup = mp.X >= pp.X and mp.X <= pp.X + ps.X and mp.Y >= pp.Y and mp.Y <= pp.Y + ps.Y
            local inSurface = mp.X >= sp.X and mp.X <= sp.X + ss.X and mp.Y >= sp.Y and mp.Y <= sp.Y + ss.Y
            if not inPopup and not inSurface then setOpen(false) end
        end
    end)

    AttachTooltip(neu.Surface, opts.Tooltip)

    RegisterFlag(opts.Flag,
        function() local arr={} for _,o in ipairs(options) do if selected[o] then table.insert(arr,o) end end return arr end,
        function(v, silent)
            selected = {}
            for _, o in ipairs(v or {}) do selected[o] = true end
            updateValueLabel()
            if not silent and opts.Callback then pcall(opts.Callback, v) end
        end)

    return {
        Frame = neu.Container,
        Set = function(arr) selected = {} for _,o in ipairs(arr or {}) do selected[o] = true end updateValueLabel() end,
        Get = function() local arr={} for _,o in ipairs(options) do if selected[o] then table.insert(arr,o) end end return arr end,
    }
end

--===========================================================================
-- COLOR PICKER (HSV modal)
--===========================================================================
local function CreateColorPicker(parent, opts)
    opts = opts or {}
    local color = opts.CurrentValue or Color3.fromRGB(255, 255, 255)

    local neu = Neumorph({
        Name = "ColorPicker",
        Size = UDim2.fromScale(1, 0) + UDim2.fromOffset(0, IsMobile and 48 or 40),
        Color = Theme.SurfaceHi,
        Radius = 12,
        ShadowOffset = 2,
        LayoutOrder = opts.LayoutOrder or 0,
        Parent = parent,
    })

    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Position = UDim2.fromOffset(14, 0)
    label.Size = UDim2.fromOffset(120, 1)
    label.Font = Enum.Font.GothamMedium
    label.TextSize = 13
    label.TextColor3 = Theme.TextDim
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Text = opts.Name or "Color"
    label.ZIndex = neu.Surface.ZIndex + 1
    label.Parent = neu.Surface

    local swatch = Instance.new("Frame")
    swatch.AnchorPoint = Vector2.new(1, 0.5)
    swatch.Position = UDim2.fromOffset(-14, 0.5)
    swatch.Size = UDim2.fromOffset(40, 24)
    swatch.BackgroundColor3 = color
    swatch.ZIndex = neu.Surface.ZIndex + 1
    uiCorner(swatch, 6)
    swatch.Parent = neu.Surface

    local function setColor(c, silent)
        color = c
        tween(swatch, { BackgroundColor3 = c }, EASE.SNAPPY)
        if not silent and opts.Callback then
            task.spawn(function() pcall(opts.Callback, c) end)
        end
    end

    -- Modal
    local modal = Instance.new("Frame")
    modal.Name = "ColorPickerModal"
    modal.Size = UDim2.fromOffset(220, 240)
    modal.AnchorPoint = Vector2.new(0.5, 0.5)
    modal.Position = UDim2.fromScale(0.5, 0.5)
    modal.BackgroundColor3 = Theme.SurfaceHi
    modal.Visible = false
    modal.ZIndex = 9500
    uiCorner(modal, 16)
    uiStroke(modal, Theme.Divider, 1, 0.4)
    modal.Parent = Screen
    uiPadding(modal, 16, 16, 16, 16)

    local title = Instance.new("TextLabel")
    title.BackgroundTransparency = 1
    title.Size = UDim2.fromScale(1, 18)
    title.Font = Enum.Font.GothamBold
    title.TextSize = 13
    title.TextColor3 = Theme.Text
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Text = opts.Name or "Pick a color"
    title.Parent = modal

    -- SV square
    local svSquare = Instance.new("TextLabel")
    svSquare.BackgroundTransparency = 0
    svSquare.Size = UDim2.fromOffset(188, 160)
    svSquare.Position = UDim2.fromOffset(0, 24)
    svSquare.BackgroundColor3 = Color3.fromHSV(0, 1, 1)
    svSquare.BorderSizePixel = 0
    svSquare.Text = ""
    uiCorner(svSquare, 8)
    svSquare.Parent = modal

    -- hue slider on the right
    local hueBar = Instance.new("Frame")
    hueBar.Size = UDim2.fromOffset(16, 160)
    hueBar.Position = UDim2.fromOffset(196, 24)
    hueBar.BorderSizePixel = 0
    uiCorner(hueBar, 8)
    local hueGradient = Instance.new("UIGradient")
    hueGradient.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.fromHSV(1, 1, 1)),
        ColorSequenceKeypoint.new(0.166, Color3.fromHSV(0.833, 1, 1)),
        ColorSequenceKeypoint.new(0.333, Color3.fromHSV(0.666, 1, 1)),
        ColorSequenceKeypoint.new(0.5, Color3.fromHSV(0.5, 1, 1)),
        ColorSequenceKeypoint.new(0.666, Color3.fromHSV(0.333, 1, 1)),
        ColorSequenceKeypoint.new(0.833, Color3.fromHSV(0.166, 1, 1)),
        ColorSequenceKeypoint.new(1, Color3.fromHSV(0, 1, 1)),
    })
    hueGradient.Rotation = 90
    hueGradient.Parent = hueBar
    hueBar.Parent = modal

    -- SV indicator
    local svIndicator = Instance.new("Frame")
    svIndicator.Size = UDim2.fromOffset(10, 10)
    svIndicator.AnchorPoint = Vector2.new(0.5, 0.5)
    svIndicator.BorderSizePixel = 0
    svIndicator.BackgroundColor3 = Color3.new(1, 1, 1)
    uiCorner(svIndicator, 5)
    uiStroke(svIndicator, Color3.new(0, 0, 0), 1.5, 0)
    svIndicator.Parent = svSquare

    -- Hue indicator
    local hueIndicator = Instance.new("Frame")
    hueIndicator.Size = UDim2.fromOffset(20, 4)
    hueIndicator.AnchorPoint = Vector2.new(0.5, 0.5)
    hueIndicator.BorderSizePixel = 0
    hueIndicator.BackgroundColor3 = Color3.new(1, 1, 1)
    uiCorner(hueIndicator, 2)
    uiStroke(hueIndicator, Color3.new(0, 0, 0), 1.5, 0)
    hueIndicator.Parent = hueBar

    local h, s, v = Color3.toHSV(color)
    local function refreshUI()
        svSquare.BackgroundColor3 = Color3.fromHSV(h, 1, 1)
        svIndicator.Position = UDim2.fromScale(s, 1 - v)
        hueIndicator.Position = UDim2.fromScale(0.5, h)
        local newColor = Color3.fromHSV(h, s, v)
        setColor(newColor, false)
    end

    local svDragging, hueDragging = false, false
    local function updateSV(inputPos)
        local relX = inputPos.X - svSquare.AbsolutePosition.X
        local relY = inputPos.Y - svSquare.AbsolutePosition.Y
        s = math.clamp(relX / svSquare.AbsoluteSize.X, 0, 1)
        v = math.clamp(1 - relY / svSquare.AbsoluteSize.Y, 0, 1)
        refreshUI()
    end
    local function updateHue(inputPos)
        local relY = inputPos.Y - hueBar.AbsolutePosition.Y
        h = math.clamp(relY / hueBar.AbsoluteSize.Y, 0, 1)
        refreshUI()
    end

    svSquare.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            svDragging = true
            updateSV(input.Position)
        end
    end)
    hueBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            hueDragging = true
            updateHue(input.Position)
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch then
            if svDragging then updateSV(input.Position) end
            if hueDragging then updateHue(input.Position) end
        end
    end)
    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            svDragging = false
            hueDragging = false
        end
    end)

    neu.Surface.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            modal.Visible = true
            modal.Position = UDim2.fromScale(0.5, 0.5) + UDim2.fromOffset(0, 30)
            modal.Position = UDim2.fromScale(0.5, 0.5)
            TweenService:Create(modal, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
                Position = UDim2.fromScale(0.5, 0.5),
            }):Play()
        end
    end)

    -- close on outside click
    UserInputService.InputBegan:Connect(function(input)
        if modal.Visible and (input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch) then
            local mp = input.Position
            local pp = modal.AbsolutePosition
            local ps = modal.AbsoluteSize
            local sp = neu.Surface.AbsolutePosition
            local ss = neu.Surface.AbsoluteSize
            local inModal = mp.X >= pp.X and mp.X <= pp.X + ps.X and mp.Y >= pp.Y and mp.Y <= pp.Y + ps.Y
            local inSurface = mp.X >= sp.X and mp.X <= sp.X + ss.X and mp.Y >= sp.Y and mp.Y <= sp.Y + ss.Y
            if not inModal and not inSurface then
                modal.Visible = false
            end
        end
    end)

    AttachTooltip(neu.Surface, opts.Tooltip)
    refreshUI()

    RegisterFlag(opts.Flag, function() return color end,
        function(c, silent) h,s,v = Color3.toHSV(c) refreshUI() if not silent and opts.Callback then pcall(opts.Callback, c) end end)

    return {
        Frame = neu.Container,
        Set = function(c) h,s,v = Color3.toHSV(c) refreshUI() end,
        Get = function() return color end,
    }
end

--===========================================================================
-- KEYBIND
--===========================================================================
local function CreateKeybind(parent, opts)
    opts = opts or {}
    local current = opts.CurrentKeybind or { Key = Enum.KeyCode.B, Mode = "Toggle" }
    local listening = false

    local neu = Neumorph({
        Name = "Keybind",
        Size = UDim2.fromScale(1, 0) + UDim2.fromOffset(0, IsMobile and 48 or 40),
        Color = Theme.SurfaceHi,
        Radius = 12,
        ShadowOffset = 2,
        LayoutOrder = opts.LayoutOrder or 0,
        Parent = parent,
    })

    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Position = UDim2.fromOffset(14, 0)
    label.Size = UDim2.fromOffset(120, 1)
    label.Font = Enum.Font.GothamMedium
    label.TextSize = 13
    label.TextColor3 = Theme.TextDim
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Text = opts.Name or "Keybind"
    label.ZIndex = neu.Surface.ZIndex + 1
    label.Parent = neu.Surface

    local keyLabel = Instance.new("TextLabel")
    keyLabel.BackgroundTransparency = 1
    keyLabel.AnchorPoint = Vector2.new(1, 0.5)
    keyLabel.Position = UDim2.fromOffset(-14, 0.5)
    keyLabel.Size = UDim2.fromOffset(100, 1)
    keyLabel.Font = Enum.Font.GothamBold
    keyLabel.TextSize = 13
    keyLabel.TextColor3 = Theme.AccentBright
    keyLabel.TextXAlignment = Enum.TextXAlignment.Right
    keyLabel.Text = current.Key.Name
    keyLabel.ZIndex = neu.Surface.ZIndex + 1
    keyLabel.Parent = neu.Surface

    local function setKey(key)
        current.Key = key
        keyLabel.Text = key.Name
        listening = false
        tween(keyLabel, { TextColor3 = Theme.AccentBright }, EASE.SNAPPY)
        keyLabel.Text = key.Name
        if opts.Callback then
            task.spawn(function() pcall(opts.Callback, current.Key) end)
        end
    end

    neu.Surface.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            listening = true
            keyLabel.Text = "..."
            tween(keyLabel, { TextColor3 = Theme.Warning }, EASE.SNAPPY)
        end
    end)

    UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if listening then
            if input.UserInputType == Enum.UserInputType.Keyboard then
                setKey(input.KeyCode)
            elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
                setKey(Enum.KeyCode.Unknown) -- cancel
            end
        elseif not gameProcessed then
            if input.KeyCode == current.Key or input.UserInputType == Enum.UserInputType.MouseButton1 and input.UserInputState == Enum.UserInputState.Begin then
                -- handle keybind press
                if opts.OnPress then
                    task.spawn(function() pcall(opts.OnPress) end)
                end
            end
        end
    end)

    AttachTooltip(neu.Surface, opts.Tooltip)

    return {
        Frame = neu.Container,
        Set = function(k) setKey(k) end,
        Get = function() return current.Key end,
    }
end

--===========================================================================
-- TOGGLE GROUP (segmented control)
--===========================================================================
local function CreateToggleGroup(parent, opts)
    opts = opts or {}
    local options = opts.Options or {}
    local selected = opts.CurrentValue or options[1]

    local neu = Neumorph({
        Name = "ToggleGroup",
        Size = UDim2.fromScale(1, 0) + UDim2.fromOffset(0, IsMobile and 56 or 48),
        Color = Theme.SurfaceHi,
        Radius = 12,
        ShadowOffset = 2,
        LayoutOrder = opts.LayoutOrder or 0,
        Parent = parent,
    })

    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Position = UDim2.fromOffset(14, 6)
    label.Size = UDim2.fromOffset(120, 18)
    label.Font = Enum.Font.GothamMedium
    label.TextSize = 13
    label.TextColor3 = Theme.TextDim
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Text = opts.Name or "ToggleGroup"
    label.ZIndex = neu.Surface.ZIndex + 1
    label.Parent = neu.Surface

    local segmentsWrap = Instance.new("Frame")
    segmentsWrap.BackgroundTransparency = 1
    segmentsWrap.AnchorPoint = Vector2.new(0.5, 1)
    segmentsWrap.Position = UDim2.fromScale(0.5, 1) + UDim2.fromOffset(0, -6)
    segmentsWrap.Size = UDim2.fromScale(1, 0) + UDim2.fromOffset(-28, 22)
    segmentsWrap.ZIndex = neu.Surface.ZIndex + 1
    segmentsWrap.Parent = neu.Surface

    local segmentsLayout = Instance.new("UIListLayout")
    segmentsLayout.FillDirection = Enum.FillDirection.Horizontal
    segmentsLayout.Padding = UDim.new(0, 4)
    segmentsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    segmentsLayout.Parent = segmentsWrap

    local indicator = Instance.new("Frame")
    indicator.Name = "Indicator"
    indicator.Size = UDim2.fromOffset(60, 22)
    indicator.Position = UDim2.fromOffset(0, 0)
    indicator.BackgroundColor3 = Theme.Accent
    indicator.BorderSizePixel = 0
    indicator.ZIndex = neu.Surface.ZIndex + 2
    uiCorner(indicator, 6)
    indicator.Parent = segmentsWrap

    local buttons = {}
    local function rebuild()
        for _, b in ipairs(buttons) do b:Destroy() end
        buttons = {}
        local perWidth = (segmentsWrap.AbsoluteSize.X - (#options - 1) * 4) / #options
        for i, opt in ipairs(options) do
            local seg = Instance.new("TextButton")
            seg.BackgroundTransparency = 1
            seg.Size = UDim2.fromOffset(perWidth, 22)
            seg.Font = Enum.Font.GothamBold
            seg.TextSize = 11
            seg.TextColor3 = (opt == selected) and Color3.new(1,1,1) or Theme.TextDim
            seg.Text = tostring(opt)
            seg.ZIndex = neu.Surface.ZIndex + 3
            seg.Parent = segmentsWrap
            table.insert(buttons, seg)
            seg.MouseButton1Click:Connect(function()
                if opt ~= selected then
                    selected = opt
                    -- animate indicator
                    local targetPos = (i - 1) * (perWidth + 4)
                    tween(indicator, { Position = UDim2.fromOffset(targetPos, 0) }, EASE.SPRING)
                    -- update colors
                    for j, b in ipairs(buttons) do
                        tween(b, { TextColor3 = (options[j] == selected) and Color3.new(1,1,1) or Theme.TextDim }, EASE.SNAPPY)
                    end
                    if opts.Callback then
                        task.spawn(function() pcall(opts.Callback, selected) end)
                    end
                end
            end)
        end
    end
    task.defer(rebuild) -- wait for AbsoluteSize
    segmentsWrap:GetPropertyChangedSignal("AbsoluteSize"):Connect(rebuild)

    AttachTooltip(neu.Surface, opts.Tooltip)

    RegisterFlag(opts.Flag, function() return selected end,
        function(v, silent) selected = v rebuild() if not silent and opts.Callback then pcall(opts.Callback, v) end end)

    return {
        Frame = neu.Container,
        Set = function(v) selected = v rebuild() end,
        Get = function() return selected end,
    }
end

--===========================================================================
-- BADGE (count bubble)
--===========================================================================
local function CreateBadge(parent, opts)
    opts = opts or {}
    local count = opts.Count or 0
    local badge = Instance.new("Frame")
    badge.Name = "Badge"
    badge.AnchorPoint = Vector2.new(1, 0)
    badge.Position = UDim2.fromOffset(-6, -6)
    badge.Size = UDim2.fromOffset(20, 20)
    badge.BackgroundColor3 = opts.Color or Theme.Danger
    badge.BorderSizePixel = 0
    badge.ZIndex = (opts.ParentZ or 5) + 1
    uiCorner(badge, 10)
    badge.Parent = parent

    local text = Instance.new("TextLabel")
    text.BackgroundTransparency = 1
    text.Size = UDim2.fromScale(1, 1)
    text.Font = Enum.Font.GothamBlack
    text.TextSize = 10
    text.TextColor3 = Color3.new(1, 1, 1)
    text.Text = tostring(count)
    text.Parent = badge

    local function setCount(n)
        count = n
        text.Text = tostring(n)
        -- animate
        badge.Size = UDim2.fromOffset(28, 28)
        TweenService:Create(badge, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
            Size = UDim2.fromOffset(20, 20),
        }):Play()
    end

    return {
        Frame = badge,
        Set = setCount,
        Get = function() return count end,
    }
end

--===========================================================================
-- SECTION (collapsible neumorphic panel)
--===========================================================================
local Section = {}
Section.__index = Section

function Section.new(tab, opts)
    opts = opts or {}
    local self = setmetatable({}, Section)
    self.Tab = tab
    self.Name = opts.Name or "Section"
    self.Collapsed = opts.Collapsed or false
    self._components = {}

    local neu = Neumorph({
        Name = "Section_" .. self.Name,
        Size = UDim2.fromScale(1, 0),
        Color = Theme.Surface,
        Radius = 16,
        ShadowOffset = 3,
        LayoutOrder = opts.LayoutOrder or 0,
        Parent = tab._content,
    })
    self._neu = neu
    self._frame = neu.Container
    self._frame.AutomaticSize = Enum.AutomaticSize.Y

    uiPadding(neu.Surface, 14, 14, 14, 14)
    local layout = uiList(neu.Surface, Enum.FillDirection.Vertical, 8, Enum.HorizontalAlignment.Center)

    -- Header
    local header = Instance.new("Frame")
    header.BackgroundTransparency = 1
    header.Size = UDim2.fromScale(1, 22)
    header.LayoutOrder = 0
    header.Parent = neu.Surface
    self._header = header

    local title = Instance.new("TextLabel")
    title.BackgroundTransparency = 1
    title.Size = UDim2.fromScale(1, 1)
    title.Font = Enum.Font.GothamBlack
    title.TextSize = 14
    title.TextColor3 = Theme.Text
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Text = ("  " .. self.Name):upper()
    title.Parent = header
    self._title = title

    local chevron = Instance.new("ImageLabel")
    chevron.Size = UDim2.fromOffset(14, 14)
    chevron.AnchorPoint = Vector2.new(1, 0.5)
    chevron.Position = UDim2.fromOffset(0, 0.5)
    chevron.BackgroundTransparency = 1
    chevron.Image = "rbxassetid://6031280882"
    chevron.ImageColor3 = Theme.TextDim
    chevron.Rotation = self.Collapsed and -90 or 0
    chevron.Parent = header
    self._chevron = chevron

    -- Body (collapsible)
    local body = Instance.new("Frame")
    body.BackgroundTransparency = 1
    body.Size = UDim2.fromScale(1, 0)
    body.AutomaticSize = Enum.AutomaticSize.Y
    body.LayoutOrder = 1
    body.Parent = neu.Surface
    self._body = body
    if self.Collapsed then body.Visible = false end
    uiList(body, Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Center)

    -- Click header to collapse/expand
    header.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            self.Collapsed = not self.Collapsed
            if self.Collapsed then
                tween(chevron, { Rotation = -90 }, EASE.SNAPPY)
                body.Visible = false
            else
                tween(chevron, { Rotation = 0 }, EASE.SNAPPY)
                body.Visible = true
            end
        end
    end)

    return self
end

-- Component factories on Section
function Section:CreateButton(opts)
    local c = CreateButton(self._body, opts)
    table.insert(self._components, c)
    return c
end
function Section:CreateToggle(opts)
    local c = CreateToggle(self._body, opts)
    table.insert(self._components, c)
    return c
end
function Section:CreateSlider(opts)
    local c = CreateSlider(self._body, opts)
    table.insert(self._components, c)
    return c
end
function Section:CreateInput(opts)
    local c = CreateInput(self._body, opts)
    table.insert(self._components, c)
    return c
end
function Section:CreateDropdown(opts)
    local c = CreateDropdown(self._body, opts)
    table.insert(self._components, c)
    return c
end
function Section:CreateMultiSelect(opts)
    local c = CreateMultiSelect(self._body, opts)
    table.insert(self._components, c)
    return c
end
function Section:CreateColorPicker(opts)
    local c = CreateColorPicker(self._body, opts)
    table.insert(self._components, c)
    return c
end
function Section:CreateKeybind(opts)
    local c = CreateKeybind(self._body, opts)
    table.insert(self._components, c)
    return c
end
function Section:CreateToggleGroup(opts)
    local c = CreateToggleGroup(self._body, opts)
    table.insert(self._components, c)
    return c
end
function Section:CreateLabel(opts)
    local c = CreateLabel(self._body, opts)
    table.insert(self._components, c)
    return c
end
function Section:CreateDivider(opts)
    local c = CreateDivider(self._body, opts)
    table.insert(self._components, c)
    return c
end
function Section:CreateBadge(opts)
    return CreateBadge(self._header, opts)
end

--===========================================================================
-- TAB
--===========================================================================
local Tab = {}
Tab.__index = Tab

function Tab.new(window, opts)
    opts = opts or {}
    local self = setmetatable({}, Tab)
    self.Window = window
    self.Name = opts.Name or "Tab"
    self.Icon = opts.Icon
    self.Sections = {}
    self._components = {}

    -- Sidebar entry
    local entry = Neumorph({
        Name = "TabEntry_" .. self.Name,
        Size = UDim2.fromScale(1, 0) + UDim2.fromOffset(0, IsMobile and 44 or 40),
        Color = Theme.SurfaceLo,
        Radius = 10,
        ShadowOffset = 0,
        Parent = nil,
    })
    self._entryNeu = entry
    self._entry = entry.Container

    local entryLayout = Instance.new("Frame")
    entryLayout.BackgroundTransparency = 1
    entryLayout.Size = UDim2.fromScale(1, 1)
    entryLayout.Parent = entry.Surface
    uiPadding(entryLayout, 0, 0, 12, 12)
    local el = uiList(entryLayout, Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Left)
    el.VerticalAlignment = Enum.VerticalAlignment.Center

    if self.Icon then
        local icon = Instance.new("ImageLabel")
        icon.Size = UDim2.fromOffset(18, 18)
        icon.BackgroundTransparency = 1
        icon.Image = self.Icon
        icon.ImageColor3 = Theme.TextDim
        icon.Parent = entryLayout
        self._entryIcon = icon
    end

    local name = Instance.new("TextLabel")
    name.BackgroundTransparency = 1
    name.Size = UDim2.fromScale(1, 1)
    name.Font = Enum.Font.GothamMedium
    name.TextSize = 13
    name.TextColor3 = Theme.TextDim
    name.TextXAlignment = Enum.TextXAlignment.Left
    name.Text = self.Name
    name.Parent = entryLayout
    self._entryName = name

    entry.Surface.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            entry.SetPressed(true)
        end
    end)
    entry.Surface.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            entry.SetPressed(false)
            window:_SelectTab(self)
        end
    end)

    -- Content container (hidden by default)
    local content = Instance.new("ScrollingFrame")
    content.Name = "TabContent_" .. self.Name
    content.Size = UDim2.fromScale(1, 1)
    content.BackgroundTransparency = 1
    content.BorderSizePixel = 0
    content.ScrollBarThickness = 4
    content.ScrollBarImageColor3 = Theme.Accent
    content.ScrollBarImageTransparency = 0.5
    content.CanvasSize = UDim2.fromScale(0, 0)
    content.AutomaticCanvasSize = Enum.AutomaticSize.Y
    content.Visible = false
    content.ZIndex = 5
    uiPadding(content, 8, 8, 8, 8)
    uiList(content, Enum.FillDirection.Vertical, 10, Enum.HorizontalAlignment.Center)
    content.Parent = nil
    self._content = content

    table.insert(window.Tabs, self)
    return self
end

function Tab:CreateSection(opts)
    local s = Section.new(self, opts)
    table.insert(self.Sections, s)
    return s
end

function Tab:_Select()
    self._entryNeu.SetColor(Theme.SurfaceHi)
    tween(self._entryName, { TextColor3 = Theme.AccentBright }, EASE.SNAPPY)
    if self._entryIcon then
        tween(self._entryIcon, { ImageColor3 = Theme.AccentBright }, EASE.SNAPPY)
    end
    self._content.Visible = true
    -- crossfade in
    self._content.Position = UDim2.fromOffset(0, 10)
    self._content.GroupTransparency = 1
    TweenService:Create(self._content, TweenInfo.new(0.24, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
        Position = UDim2.fromOffset(0, 0),
        GroupTransparency = 0,
    }):Play()
end

function Tab:_Deselect()
    self._entryNeu.SetColor(Theme.SurfaceLo)
    tween(self._entryName, { TextColor3 = Theme.TextDim }, EASE.SNAPPY)
    if self._entryIcon then
        tween(self._entryIcon, { ImageColor3 = Theme.TextDim }, EASE.SNAPPY)
    end
    self._content.Visible = false
end

--===========================================================================
-- WINDOW
--===========================================================================
local Window = {}
Window.__index = Window

function Window.new(config)
    config = config or {}
    local self = setmetatable({}, Window)
    self.Name = config.Name or "Prism"
    self.Accent = config.Accent or Theme.Accent
    self.Size = config.Size or (IsMobile and UDim2.fromOffset(math.min(380, workspace.CurrentCamera.ViewportSize.X - 16), math.min(640, workspace.CurrentCamera.ViewportSize.Y - 32)) or UDim2.fromOffset(720, 480))
    self.MinSize = config.MinSize or UDim2.fromOffset(380, 280)
    self.Tabs = {}
    self.CurrentTab = nil
    self._components = {}
    self._visible = true

    Theme.Accent = self.Accent
    Theme:Rebuild()

    self:_Build()
    table.insert(_G.__PRISM_REF._Windows, self)
    return self
end

function Window:_Build()
    local vp = workspace.CurrentCamera.ViewportSize
    local isMob = IsMobile

    -- Mobile: full-screen takeover with bottom nav
    -- Desktop: centered floating window

    local win = Neumorph({
        Name = "Window_" .. self.Name,
        Size = self.Size,
        Position = UDim2.fromScale(0.5, 0.5),
        AnchorPoint = Vector2.new(0.5, 0.5),
        Color = Theme.Surface,
        Radius = isMob and 0 or 22,
        ShadowOffset = isMob and 0 or 6,
        ZIndex = 2,
        Parent = Screen,
    })
    self._neu = win
    self._frame = win.Container

    if isMob then
        self._frame.Size = UDim2.fromScale(1, 1)
        self._frame.Position = UDim2.fromScale(0, 0)
        self._frame.AnchorPoint = Vector2.new(0, 0)
    end

    uiPadding(win.Surface, isMob and 0 or 16, isMob and 0 or 16, isMob and 0 or 16, isMob and 0 or 16)

    -- Inner layout
    local inner
    if isMob then
        -- Vertical: header on top, content fills, tabs at bottom
        inner = Instance.new("Frame")
        inner.BackgroundTransparency = 1
        inner.Size = UDim2.fromScale(1, 1)
        inner.Parent = win.Surface
        uiPadding(inner, 12, 8, 12, 8)
        local il = uiList(inner, Enum.FillDirection.Vertical, 8, Enum.HorizontalAlignment.Center)
        -- header
        local header = Instance.new("Frame")
        header.BackgroundTransparency = 1
        header.Size = UDim2.fromScale(1, 32)
        header.Parent = inner
        local title = Instance.new("TextLabel")
        title.BackgroundTransparency = 1
        title.Size = UDim2.fromScale(1, 1)
        title.Font = Enum.Font.GothamBlack
        title.TextSize = 20
        title.TextColor3 = Theme.Text
        title.Text = self.Name
        title.Parent = header
        self._title = title
        self._header = header
        -- content
        local content = Instance.new("Frame")
        content.BackgroundTransparency = 1
        content.Size = UDim2.fromScale(1, 1)
        content.Parent = inner
        self._contentArea = content
        -- bottom tab bar
        local tabbar = Instance.new("Frame")
        tabbar.BackgroundTransparency = 1
        tabbar.Size = UDim2.fromScale(1, 50)
        tabbar.Parent = inner
        local tbLayout = uiList(tabbar, Enum.FillDirection.Horizontal, 4, Enum.HorizontalAlignment.Center)
        self._sidebar = tabbar
    else
        -- Desktop: horizontal split (sidebar | content)
        inner = Instance.new("Frame")
        inner.BackgroundTransparency = 1
        inner.Size = UDim2.fromScale(1, 1)
        inner.Parent = win.Surface
        local il = Instance.new("UIListLayout")
        il.FillDirection = Enum.FillDirection.Horizontal
        il.Padding = UDim.new(0, 12)
        il.Parent = inner

        -- Sidebar
        local sidebar = Neumorph({
            Name = "Sidebar",
            Size = UDim2.fromOffset(200, 1) - UDim2.fromOffset(0, 0),
            Color = Theme.SurfaceLo,
            Radius = 14,
            ShadowOffset = 0,
            Parent = inner,
        })
        self._sidebarNeu = sidebar
        self._sidebar = sidebar.Surface
        uiPadding(sidebar.Surface, 16, 16, 16, 16)
        local sl = uiList(sidebar.Surface, Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Center)

        -- Title
        local title = Instance.new("TextLabel")
        title.BackgroundTransparency = 1
        title.Size = UDim2.fromScale(1, 0)
        title.AutomaticSize = Enum.AutomaticSize.Y
        title.Font = Enum.Font.GothamBlack
        title.TextSize = 22
        title.TextColor3 = Theme.Text
        title.TextXAlignment = Enum.TextXAlignment.Left
        title.Text = self.Name
        title.LayoutOrder = 0
        title.Parent = sidebar.Surface
        self._title = title

        -- Subtitle
        local sub = Instance.new("TextLabel")
        sub.BackgroundTransparency = 1
        sub.Size = UDim2.fromScale(1, 0)
        sub.AutomaticSize = Enum.AutomaticSize.Y
        sub.Font = Enum.Font.Gotham
        sub.TextSize = 11
        sub.TextColor3 = Theme.TextMuted
        sub.TextXAlignment = Enum.TextXAlignment.Left
        sub.Text = "Prism v" .. (_G.__PRISM_REF and _G.__PRISM_REF.Version or "1.0")
        sub.LayoutOrder = 1
        sub.Parent = sidebar.Surface
        self._subtitle = sub

        -- Search box
        local searchNeu = Neumorph({
            Name = "Search",
            Size = UDim2.fromScale(1, 0) + UDim2.fromOffset(0, 32),
            Color = Theme.SurfaceHi,
            Radius = 10,
            ShadowOffset = 0,
            LayoutOrder = 2,
            Parent = sidebar.Surface,
        })
        self._searchNeu = searchNeu
        local searchBox = Instance.new("TextBox")
        searchBox.BackgroundTransparency = 1
        searchBox.Size = UDim2.fromScale(1, 1)
        searchBox.Font = Enum.Font.Gotham
        searchBox.TextSize = 12
        searchBox.TextColor3 = Theme.Text
        searchBox.PlaceholderText = "Search..."
        searchBox.PlaceholderColor3 = Theme.TextMuted
        searchBox.TextXAlignment = Enum.TextXAlignment.Left
        uiPadding(searchBox, 0, 0, 10, 10)
        searchBox.Parent = searchNeu.Surface
        self._search = searchBox
        searchBox:GetPropertyChangedSignal("Text"):Connect(function()
            self:_FilterTabs(searchBox.Text)
        end)

        -- Tab list container (scrollable)
        local tabList = Instance.new("ScrollingFrame")
        tabList.BackgroundTransparency = 1
        tabList.BorderSizePixel = 0
        tabList.Size = UDim2.fromScale(1, 1)
        tabList.CanvasSize = UDim2.fromScale(0, 0)
        tabList.AutomaticCanvasSize = Enum.AutomaticSize.Y
        tabList.ScrollBarThickness = 2
        tabList.ScrollBarImageColor3 = Theme.Accent
        tabList.ScrollBarImageTransparency = 0.5
        tabList.LayoutOrder = 3
        uiPadding(tabList, 0, 0, 0, 0)
        uiList(tabList, Enum.FillDirection.Vertical, 4, Enum.HorizontalAlignment.Center)
        tabList.Parent = sidebar.Surface
        self._tabList = tabList

        -- Sidebar footer (save/load buttons)
        local footer = Instance.new("Frame")
        footer.BackgroundTransparency = 1
        footer.Size = UDim2.fromScale(1, 0)
        footer.AutomaticSize = Enum.AutomaticSize.Y
        footer.LayoutOrder = 4
        uiList(footer, Enum.FillDirection.Horizontal, 4, Enum.HorizontalAlignment.Center)
        footer.Parent = sidebar.Surface
        self._sidebarFooter = footer

        local saveBtn = Instance.new("TextButton")
        saveBtn.BackgroundTransparency = 1
        saveBtn.Size = UDim2.fromScale(0.5, 0) + UDim2.fromOffset(-2, 28)
        saveBtn.Font = Enum.Font.GothamBold
        saveBtn.TextSize = 11
        saveBtn.TextColor3 = Theme.Accent
        saveBtn.Text = "Save"
        saveBtn.Parent = footer
        saveBtn.MouseButton1Click:Connect(function()
            Prism:SaveConfig()
            Notifications:Show({ kind="success", title="Config saved", content="All flag values stored." })
        end)

        local loadBtn = Instance.new("TextButton")
        loadBtn.BackgroundTransparency = 1
        loadBtn.Size = UDim2.fromScale(0.5, 0) + UDim2.fromOffset(-2, 28)
        loadBtn.Font = Enum.Font.GothamBold
        loadBtn.TextSize = 11
        loadBtn.TextColor3 = Theme.TextDim
        loadBtn.Text = "Load"
        loadBtn.Parent = footer
        loadBtn.MouseButton1Click:Connect(function()
            Prism:LoadConfig()
            Notifications:Show({ kind="info", title="Config loaded", content="All flag values restored." })
        end)

        -- Content area
        local contentArea = Instance.new("Frame")
        contentArea.BackgroundTransparency = 1
        contentArea.Size = UDim2.fromScale(1, 1)
        contentArea.Parent = inner
        self._contentArea = contentArea

        -- Window controls (minimize / close)
        local controls = Instance.new("Frame")
        controls.BackgroundTransparency = 1
        controls.Size = UDim2.fromOffset(0, 0)
        controls.Parent = win.Surface
        -- Minimize button (top-right corner)
        local minBtn = Instance.new("TextButton")
        minBtn.BackgroundTransparency = 1
        minBtn.Size = UDim2.fromOffset(24, 24)
        minBtn.AnchorPoint = Vector2.new(1, 0)
        minBtn.Position = UDim2.fromOffset(-12, 12)
        minBtn.Font = Enum.Font.GothamBold
        minBtn.TextSize = 16
        minBtn.TextColor3 = Theme.TextDim
        minBtn.Text = "—"
        minBtn.ZIndex = 100
        minBtn.Parent = win.Surface
        minBtn.MouseButton1Click:Connect(function()
            self:Minimize()
        end)
        self._minBtn = minBtn
    end

    -- Make draggable (desktop only, from header)
    if not isMob then
        makeDraggable(self._frame, self._header or win.Surface)
    end

    return self
end

function Window:CreateTab(opts)
    local t = Tab.new(self, opts)
    if not IsMobile then
        t._entry.Parent = self._tabList
    else
        t._entry.Parent = self._sidebar
        t._entry.Size = UDim2.fromScale(1, 1) - UDim2.fromOffset(0, 0)
    end
    t._content.Parent = self._contentArea
    if not self.CurrentTab then
        self:_SelectTab(t)
    end
    return t
end

function Window:_SelectTab(tab)
    if self.CurrentTab == tab then return end
    if self.CurrentTab then self.CurrentTab:_Deselect() end
    self.CurrentTab = tab
    tab:_Select()
    Logger:info("[Window] Selected tab: %s", tab.Name)
end

function Window:_FilterTabs(query)
    query = (query or ""):lower()
    for _, tab in ipairs(self.Tabs) do
        local match = tab.Name:lower():find(query, 1, true) ~= nil
        tab._entry.Visible = match or query == ""
    end
end

function Window:Minimize()
    if not self._visible then return end
    self._visible = false
    local curSize = self._frame.Size
    local curPos = self._frame.Position
    TweenService:Create(self._frame, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.In), {
        Size = UDim2.fromOffset(200, 40),
        Position = UDim2.fromScale(0.5, 1) - UDim2.fromOffset(0, -50),
    }):Play()
    -- Show a restore button
    task.delay(0.3, function()
        self._frame.Visible = false
        local restore = Instance.new("TextButton")
        restore.Name = "RestoreButton"
        restore.Size = UDim2.fromOffset(200, 40)
        restore.AnchorPoint = Vector2.new(0.5, 0)
        restore.Position = UDim2.fromScale(0.5, 1) + UDim2.fromOffset(0, -50)
        restore.BackgroundColor3 = Theme.Accent
        restore.Font = Enum.Font.GothamBold
        restore.TextSize = 13
        restore.TextColor3 = Color3.new(1, 1, 1)
        restore.Text = self.Name
        restore.Parent = Screen
        uiCorner(restore, 10)
        restore.MouseButton1Click:Connect(function()
            self:Restore(restore)
        end)
        self._restoreBtn = restore
    end)
end

function Window:Restore(restoreBtn)
    if self._visible then return end
    self._visible = true
    if restoreBtn then restoreBtn = restoreBtn or self._restoreBtn end
    if restoreBtn then restoreBtn:Destroy() end
    self._frame.Visible = true
    TweenService:Create(self._frame, TweenInfo.new(0.32, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
        Size = self.Size,
        Position = UDim2.fromScale(0.5, 0.5),
    }):Play()
end

function Window:SaveConfig()
    Prism:SaveConfig()
end

function Window:LoadConfig()
    Prism:LoadConfig()
end

function Window:Build()
    -- Final setup hook (kept for API parity with Rayfield)
    Logger:info("[Window] Built window: %s (%d tabs)", self.Name, #self.Tabs)
    Notifications:Show({
        kind = "info",
        title = self.Name,
        content = "Loaded successfully.",
        duration = 3,
    })
end

function Window:_ApplyTheme()
    -- Recolor all neumorphic surfaces
    -- For brevity, just rebuild shadows via Theme:Rebuild (already called by Prism:SetAccent)
    -- A full implementation would iterate all components and tween their colors
    if self._title then
        self._title.TextColor3 = Theme.Text
    end
end

function Window:Notify(opts)
    Notifications:Show(opts)
end

--===========================================================================
-- PUBLIC API (assembled at end of file)
--===========================================================================
local Prism = {
    Version = "1.0.0",
    Theme = Theme,
    Logger = Logger,
    Notifications = nil, -- set below
    IsMobile = IsMobile,
    Flags = {}, -- all toggle/slider/etc. values keyed by Flag name
    ConfigKey = "Prism_DefaultConfig",
    _Windows = {},
}

function Prism:Notify(opts)
    Notifications:Show(opts)
end
function Prism:NotifyInfo(title, content) Notifications:Show({ kind="info", title=title, content=content }) end
function Prism:NotifySuccess(title, content) Notifications:Show({ kind="success", title=title, content=content }) end
function Prism:NotifyWarn(title, content) Notifications:Show({ kind="warning", title=title, content=content }) end
function Prism:NotifyError(title, content) Notifications:Show({ kind="error", title=title, content=content }) end

function Prism:SetAccent(color)
    Theme.Accent = color
    Theme:Rebuild()
    -- re-render all windows (TODO: propagate to all elements)
    for _, win in ipairs(self._Windows) do
        if win._ApplyTheme then win:_ApplyTheme() end
    end
    Logger:info("Accent updated to %s", Color.toHex(color))
end

function Prism:SetTheme(overrides)
    ApplyThemeOverrides(overrides)
    for _, win in ipairs(self._Windows) do
        if win._ApplyTheme then win:_ApplyTheme() end
    end
end

function Prism:LoadConfig(key)
    key = key or self.ConfigKey
    local raw
    pcall(function()
        if writefile and isfile and readfile then
            if isfile(key) then raw = readfile(key) end
        elseif getgenv and getgenv()[key] then
            raw = getgenv()[key]
        end
    end)
    if not raw then Logger:info("No saved config at %s", key); return nil end
    local ok, data = pcall(function() return HttpService:JSONDecode(raw) end)
    if not ok or type(data) ~= "table" then Logger:warn("Config decode failed"); return nil end
    for flagName, value in pairs(data) do
        if self.Flags[flagName] and self.Flags[flagName].Set then
            self.Flags[flagName]:Set(value, false)
        end
    end
    Logger:success("Loaded config (%d flags)", 0)
    return data
end

function Prism:SaveConfig(key)
    key = key or self.ConfigKey
    local data = {}
    for flagName, flag in pairs(self.Flags) do
        if flag.Get then data[flagName] = flag:Get() end
    end
    local raw = HttpService:JSONEncode(data)
    pcall(function()
        if writefile then
            writefile(key, raw)
        elseif getgenv then
            getgenv()[key] = raw
        end
    end)
    Logger:success("Saved config to %s (%d flags)", key, 0)
end

Prism.Notifications = Notifications

-- getgenv publish for cross-script access
pcall(function()
    if getgenv then
        getgenv().Prism_Loaded = true
        getgenv().Prism_Instance = Prism
    end
end)

--===========================================================================
-- WIRE UP PUBLIC API
--===========================================================================
-- Make Prism referenceable from RegisterFlag helper above
_G.__PRISM_REF = Prism

-- CreateWindow: instantiates a Window
function Prism:CreateWindow(config)
    return Window.new(config)
end

-- Confirmation modal (programmatic — useful for "are you sure?" prompts)
function Prism:Confirm(opts)
    opts = opts or {}
    local result = false
    local modal = Instance.new("Frame")
    modal.Name = "ConfirmModal"
    modal.Size = UDim2.fromOffset(320, 160)
    modal.AnchorPoint = Vector2.new(0.5, 0.5)
    modal.Position = UDim2.fromScale(0.5, 0.5)
    modal.BackgroundColor3 = Theme.SurfaceHi
    modal.ZIndex = 9800
    uiCorner(modal, 16)
    uiStroke(modal, Theme.Divider, 1, 0.4)
    modal.Parent = Screen
    uiPadding(modal, 18, 18, 18, 18)
    local layout = uiList(modal, Enum.FillDirection.Vertical, 12, Enum.HorizontalAlignment.Center)

    local title = Instance.new("TextLabel")
    title.BackgroundTransparency = 1
    title.Size = UDim2.fromScale(1, 20)
    title.Font = Enum.Font.GothamBold
    title.TextSize = 15
    title.TextColor3 = Theme.Text
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Text = opts.Title or "Confirm"
    title.Parent = modal

    local body = Instance.new("TextLabel")
    body.BackgroundTransparency = 1
    body.Size = UDim2.fromScale(1, 0)
    body.AutomaticSize = Enum.AutomaticSize.Y
    body.Font = Enum.Font.Gotham
    body.TextSize = 13
    body.TextColor3 = Theme.TextDim
    body.TextWrapped = true
    body.TextXAlignment = Enum.TextXAlignment.Left
    body.Text = opts.Content or "Are you sure?"
    body.Parent = modal

    local btnWrap = Instance.new("Frame")
    btnWrap.BackgroundTransparency = 1
    btnWrap.Size = UDim2.fromScale(1, 32)
    btnWrap.Parent = modal
    local bl = Instance.new("UIListLayout")
    bl.FillDirection = Enum.FillDirection.Horizontal
    bl.Padding = UDim.new(0, 8)
    bl.HorizontalAlignment = Enum.HorizontalAlignment.Right
    bl.Parent = btnWrap

    local function makeBtn(text, color)
        local b = Instance.new("TextButton")
        b.BackgroundTransparency = 0
        b.BackgroundColor3 = color
        b.Size = UDim2.fromOffset(80, 32)
        b.Font = Enum.Font.GothamBold
        b.TextSize = 12
        b.TextColor3 = Color3.new(1, 1, 1)
        b.Text = text
        b.ZIndex = 9801
        uiCorner(b, 8)
        b.Parent = btnWrap
        return b
    end

    local okBtn = makeBtn(opts.ConfirmText or "Confirm", opts.ConfirmColor or Theme.Accent)
    local cancelBtn = makeBtn(opts.CancelText or "Cancel", Theme.SurfaceLo)
    cancelBtn.TextColor3 = Theme.Text

    local function close(res)
        result = res
        TweenService:Create(modal, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.In), {
            Size = UDim2.fromOffset(280, 140),
            GroupTransparency = 1,
        }):Play()
        task.delay(0.18, function()
            modal:Destroy()
            if opts.Callback then opts.Callback(res) end
        end)
    end

    okBtn.MouseButton1Click:Connect(function() close(true) end)
    cancelBtn.MouseButton1Click:Connect(function() close(false) end)

    -- appear animation
    modal.Size = UDim2.fromOffset(280, 140)
    modal.GroupTransparency = 1
    TweenService:Create(modal, TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
        Size = UDim2.fromOffset(320, 160),
        GroupTransparency = 0,
    }):Play()

    return modal
end

-- Set the global default config key (used by LoadConfig/SaveConfig)
function Prism:SetConfigKey(key)
    self.ConfigKey = key
end

--===========================================================================
-- CLEANUP ON UNLOAD
--===========================================================================
local function cleanup()
    if Screen then Screen:Destroy() end
    if getgenv then
        getgenv().Prism_Loaded = nil
        getgenv().Prism_Instance = nil
    end
    _G.__PRISM_REF = nil
end
Prism._Cleanup = cleanup

-- getgenv publish for cross-script access
pcall(function()
    if getgenv then
        getgenv().Prism_Loaded = true
        getgenv().Prism_Instance = Prism
    end
end)

Logger:info("Prism v%s loaded (%s mode)", Prism.Version, IsMobile and "mobile" or "desktop")

return Prism
