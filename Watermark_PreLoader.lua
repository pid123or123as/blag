--[[
    Watermark_PreLoader.lua — MacLib Preloader Module
    Patches MacLib with :Watermark(cfg) method on the Window object.
    
    API (WindowFunctions):
        local wm = Window:Watermark({
            Title        = "Syllinse",     -- script name (gradient animated)
            Version      = "v4.3",         -- shown after gradient title
            Discord      = "discord.gg/A58yhBsJfY", -- optional
            ShowFPS      = true,           -- FPS counter
            ShowTime     = true,           -- HH:MM:SS
            GradColor1   = Color3.fromRGB(130, 90, 255),
            GradColor2   = Color3.fromRGB(70, 180, 255),
            GradSpeed    = 2.5,            -- seconds per full cycle
        })
        
        wm:SetVisible(bool)     -- show / hide
        wm:Destroy()            -- cleanup
        wm:UpdateTitle(str)
        wm:UpdateVersion(str)
        wm:SetFPSVisible(bool)
        wm:SetTimeVisible(bool)
]]

return function(ctx)
    local MacLib   = ctx.MacLib
    local Window   = ctx.Window

    -- ── Services ──────────────────────────────────────────────────────────
    local TweenService     = game:GetService("TweenService")
    local RunService       = game:GetService("RunService")
    local UserInputService = game:GetService("UserInputService")
    local Players          = game:GetService("Players")

    local LocalPlayer = Players.LocalPlayer
    local isMobile    = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

    -- ── Helpers ───────────────────────────────────────────────────────────
    local function GetGui()
        local g = Instance.new("ScreenGui")
        g.ScreenInsets    = Enum.ScreenInsets.None
        g.ResetOnSpawn    = false
        g.ZIndexBehavior  = Enum.ZIndexBehavior.Sibling
        g.DisplayOrder    = 2147483645
        g.Parent = (RunService:IsStudio())
            and LocalPlayer:FindFirstChild("PlayerGui")
            or  (rawget(_G,"gethui") and gethui())
            or  (rawget(_G,"cloneref") and cloneref(game:GetService("CoreGui")))
            or  game:GetService("CoreGui")
        return g
    end

    local function tw(inst, info, props)
        return TweenService:Create(inst, info, props)
    end
    local TW_FAST   = TweenInfo.new(0.18, Enum.EasingStyle.Sine)
    local TW_MEDIUM = TweenInfo.new(0.28, Enum.EasingStyle.Sine)
    local TW_SLOW   = TweenInfo.new(0.45, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out)

    local function Corner(parent, r)
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0, r or 8)
        c.Parent = parent
        return c
    end
    local function Stroke(parent, color, thickness, transparency)
        local s = Instance.new("UIStroke")
        s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
        s.Color           = color or Color3.fromRGB(255,255,255)
        s.Thickness       = thickness or 1.5
        s.Transparency    = transparency or 0.82
        s.Parent          = parent
        return s
    end
    local function Pad(parent, l,r,t,b)
        local p = Instance.new("UIPadding")
        p.PaddingLeft   = UDim.new(0,l or 0)
        p.PaddingRight  = UDim.new(0,r or 0)
        p.PaddingTop    = UDim.new(0,t or 0)
        p.PaddingBottom = UDim.new(0,b or 0)
        p.Parent = parent
        return p
    end

    -- ── Patch Window:Watermark ────────────────────────────────────────────
    Window.Watermark = function(_, cfg)
        cfg = cfg or {}
        local TITLE    = cfg.Title    or "Script"
        local VERSION  = cfg.Version  or ""
        local DISCORD  = cfg.Discord  or nil
        local SHOW_FPS = (cfg.ShowFPS  ~= false)
        local SHOW_TIME= (cfg.ShowTime ~= false)
        local C1 = cfg.GradColor1 or Color3.fromRGB(130, 90, 255)
        local C2 = cfg.GradColor2 or Color3.fromRGB(70, 180, 255)
        local SPEED    = cfg.GradSpeed or 2.5   -- seconds per cycle

        -- BG palette — matches MacLib dark surface
        local BG_BASE  = Color3.fromRGB(15, 15, 15)
        local BG_HOVER = Color3.fromRGB(22, 22, 22)
        local STROKE_C = Color3.fromRGB(255, 255, 255)

        -- State
        local gradTime  = 0
        local hb_conn   = nil
        local drag      = { active=false, startMouse=Vector2.zero, startPos=UDim2.new() }
        local strokeList= {}    -- {stroke, phaseOffset}
        local visible   = true

        -- Root GUI
        local gui = GetGui()
        gui.Name = "MacLib_Watermark"

        -- ── Container ──
        local container = Instance.new("Frame")
        container.Name                 = "WmContainer"
        container.Size                 = UDim2.fromOffset(10, 36)
        container.BackgroundTransparency = 1
        container.BorderSizePixel      = 0
        container.ZIndex               = 10
        container.Parent               = gui

        if isMobile then
            -- Fixed top-right; compact, non-draggable
            container.AnchorPoint = Vector2.new(1, 0)
            container.Position    = UDim2.new(1, -10, 0, 48)
        else
            container.AnchorPoint = Vector2.new(0, 0)
            container.Position    = UDim2.new(1, -320, 0, 12)
        end

        local layout = Instance.new("UIListLayout")
        layout.FillDirection       = Enum.FillDirection.Horizontal
        layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
        layout.VerticalAlignment   = Enum.VerticalAlignment.Center
        layout.Padding             = UDim.new(0, 6)
        layout.SortOrder           = Enum.SortOrder.LayoutOrder
        layout.Parent              = container

        -- auto-resize container width
        layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
            container.Size = UDim2.fromOffset(layout.AbsoluteContentSize.X, isMobile and 30 or 36)
        end)

        -- ── Stroke animation helper ──────────────────────────────────────
        local function registerStroke(s, phase)
            table.insert(strokeList, {stroke=s, phase=phase or 0})
        end
        local function getGradColor(phase, t)
            local p = ((t / SPEED + phase) % 1)
            local s = math.sin(p * math.pi * 2) * 0.5 + 0.5
            return C1:Lerp(C2, s)
        end

        -- ── Block factory ───────────────────────────────────────────────
        local function makeBlock(w, h, layoutOrder, radius)
            local f = Instance.new("Frame")
            f.Name                  = "WmBlock"
            f.Size                  = UDim2.fromOffset(w, h or (isMobile and 28 or 34))
            f.BackgroundColor3      = BG_BASE
            f.BackgroundTransparency= 0.05
            f.BorderSizePixel       = 0
            f.LayoutOrder           = layoutOrder
            f.ZIndex                = 10
            f.Parent                = container
            Corner(f, radius or (isMobile and 7 or 9))
            return f
        end

        local function addHover(block)
            if isMobile then return end
            block.MouseEnter:Connect(function()
                tw(block, TW_FAST, {BackgroundTransparency=0.0, BackgroundColor3=BG_HOVER}):Play()
            end)
            block.MouseLeave:Connect(function()
                tw(block, TW_FAST, {BackgroundTransparency=0.05, BackgroundColor3=BG_BASE}):Play()
            end)
        end

        -- ── BLOCK 1: Main info (title + version, optional FPS, optional time) ──
        local mainBlock = makeBlock(10, isMobile and 28 or 34, 1)
        addHover(mainBlock)
        local mainStroke = Stroke(mainBlock, STROKE_C, isMobile and 1.2 or 1.6, 0.82)
        registerStroke(mainStroke, 0)

        local innerLayout = Instance.new("UIListLayout")
        innerLayout.FillDirection       = Enum.FillDirection.Horizontal
        innerLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
        innerLayout.VerticalAlignment   = Enum.VerticalAlignment.Center
        innerLayout.Padding             = UDim.new(0, isMobile and 6 or 8)
        innerLayout.SortOrder           = Enum.SortOrder.LayoutOrder
        innerLayout.Parent              = mainBlock
        Pad(mainBlock, isMobile and 8 or 10, isMobile and 8 or 10, 0, 0)

        -- auto-resize mainBlock
        innerLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
            mainBlock.Size = UDim2.fromOffset(
                innerLayout.AbsoluteContentSize.X + (isMobile and 16 or 20),
                isMobile and 28 or 34
            )
        end)

        -- ── Gradient title label ──
        local titleLabel = Instance.new("TextLabel")
        titleLabel.Name                  = "WmTitle"
        titleLabel.BackgroundTransparency= 1
        titleLabel.Text                  = TITLE
        titleLabel.TextColor3            = Color3.fromRGB(255,255,255)
        titleLabel.TextSize              = isMobile and 11 or 13
        titleLabel.FontFace              = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Bold)
        titleLabel.TextXAlignment        = Enum.TextXAlignment.Left
        titleLabel.AutomaticSize         = Enum.AutomaticSize.XY
        titleLabel.ZIndex                = 11
        titleLabel.LayoutOrder           = 1
        titleLabel.Size                  = UDim2.fromOffset(0, isMobile and 18 or 22)
        titleLabel.Parent                = mainBlock

        local titleGrad = Instance.new("UIGradient")
        titleGrad.Color    = ColorSequence.new(C1, C2)
        titleGrad.Rotation = 0
        titleGrad.Parent   = titleLabel

        -- ── Version label ──
        local versionLabel
        if VERSION ~= "" then
            local sep = Instance.new("TextLabel")
            sep.Name                  = "WmSep"
            sep.BackgroundTransparency= 1
            sep.Text                  = "/"
            sep.TextColor3            = Color3.fromRGB(255,255,255)
            sep.TextTransparency      = 0.70
            sep.TextSize              = isMobile and 10 or 12
            sep.FontFace              = Font.new("rbxasset://fonts/families/GothamSSm.json")
            sep.AutomaticSize         = Enum.AutomaticSize.XY
            sep.ZIndex                = 11
            sep.LayoutOrder           = 2
            sep.Size                  = UDim2.fromOffset(0, isMobile and 18 or 22)
            sep.Parent                = mainBlock

            versionLabel = Instance.new("TextLabel")
            versionLabel.Name                  = "WmVersion"
            versionLabel.BackgroundTransparency= 1
            versionLabel.Text                  = VERSION
            versionLabel.TextColor3            = Color3.fromRGB(255,255,255)
            versionLabel.TextTransparency      = 0.45
            versionLabel.TextSize              = isMobile and 10 or 12
            versionLabel.FontFace              = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Medium)
            versionLabel.AutomaticSize         = Enum.AutomaticSize.XY
            versionLabel.ZIndex                = 11
            versionLabel.LayoutOrder           = 3
            versionLabel.Size                  = UDim2.fromOffset(0, isMobile and 18 or 22)
            versionLabel.Parent                = mainBlock
        end

        -- ── Divider pill (thin vertical) ──
        local function makePill(order)
            local d = Instance.new("Frame")
            d.Size                  = UDim2.fromOffset(1, isMobile and 14 or 18)
            d.BackgroundColor3      = Color3.fromRGB(255,255,255)
            d.BackgroundTransparency= 0.82
            d.BorderSizePixel       = 0
            d.ZIndex                = 11
            d.LayoutOrder           = order
            d.Parent                = mainBlock
            Corner(d, 2)
            return d
        end

        -- ── FPS container ──
        local fpsLabel
        local fpsDivider
        if SHOW_FPS then
            fpsDivider = makePill(4)

            local fpsIcon = Instance.new("ImageLabel")
            fpsIcon.Name                  = "FPSIcon"
            fpsIcon.Size                  = UDim2.fromOffset(isMobile and 11 or 13, isMobile and 11 or 13)
            fpsIcon.BackgroundTransparency= 1
            fpsIcon.Image                 = "rbxassetid://8587689304"  -- fps/monitor icon
            fpsIcon.ImageColor3           = Color3.fromRGB(255,255,255)
            fpsIcon.ImageTransparency     = 0.35
            fpsIcon.ZIndex                = 11
            fpsIcon.LayoutOrder           = 5
            fpsIcon.Parent                = mainBlock

            fpsLabel = Instance.new("TextLabel")
            fpsLabel.Name                  = "WmFPS"
            fpsLabel.BackgroundTransparency= 1
            fpsLabel.Text                  = "-- fps"
            fpsLabel.TextColor3            = Color3.fromRGB(120, 255, 160)
            fpsLabel.TextTransparency      = 0.15
            fpsLabel.TextSize              = isMobile and 10 or 12
            fpsLabel.FontFace              = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Medium)
            fpsLabel.AutomaticSize         = Enum.AutomaticSize.XY
            fpsLabel.ZIndex                = 11
            fpsLabel.LayoutOrder           = 6
            fpsLabel.Size                  = UDim2.fromOffset(0, isMobile and 18 or 22)
            fpsLabel.Parent                = mainBlock
        end

        -- ── Time container ──
        local timeLabel
        local timeDivider
        if SHOW_TIME then
            timeDivider = makePill(7)

            local clockIcon = Instance.new("ImageLabel")
            clockIcon.Name                  = "ClockIcon"
            clockIcon.Size                  = UDim2.fromOffset(isMobile and 11 or 13, isMobile and 11 or 13)
            clockIcon.BackgroundTransparency= 1
            clockIcon.Image                 = "rbxassetid://4034150594"
            clockIcon.ImageColor3           = Color3.fromRGB(255,255,255)
            clockIcon.ImageTransparency     = 0.35
            clockIcon.ZIndex                = 11
            clockIcon.LayoutOrder           = 8
            clockIcon.Parent                = mainBlock

            timeLabel = Instance.new("TextLabel")
            timeLabel.Name                  = "WmTime"
            timeLabel.BackgroundTransparency= 1
            timeLabel.Text                  = "00:00:00"
            timeLabel.TextColor3            = Color3.fromRGB(255,255,255)
            timeLabel.TextTransparency      = 0.40
            timeLabel.TextSize              = isMobile and 10 or 12
            timeLabel.FontFace              = Font.new("rbxasset://fonts/families/GothamSSm.json")
            timeLabel.AutomaticSize         = Enum.AutomaticSize.XY
            timeLabel.ZIndex                = 11
            timeLabel.LayoutOrder           = 9
            timeLabel.Size                  = UDim2.fromOffset(0, isMobile and 18 or 22)
            timeLabel.Parent                = mainBlock
        end

        -- ── BLOCK 2: Discord (PC only, optional) ──
        local discordBlock
        if DISCORD and not isMobile then
            discordBlock = makeBlock(isMobile and 30 or 36, isMobile and 28 or 34, 2, 18)
            local ds = Stroke(discordBlock, STROKE_C, 1.6, 0.82)
            registerStroke(ds, 0.33)
            addHover(discordBlock)

            local discordIcon = Instance.new("ImageLabel")
            discordIcon.Name                  = "DiscordIcon"
            discordIcon.Size                  = UDim2.fromOffset(isMobile and 14 or 17, isMobile and 11 or 13)
            discordIcon.AnchorPoint           = Vector2.new(0.5, 0.5)
            discordIcon.Position              = UDim2.fromScale(0.5, 0.5)
            discordIcon.BackgroundTransparency= 1
            discordIcon.Image                 = "rbxassetid://7184515830"  -- discord logo
            discordIcon.ImageColor3           = Color3.fromRGB(200, 210, 255)
            discordIcon.ImageTransparency     = 0.1
            discordIcon.ZIndex                = 11
            discordIcon.Parent                = discordBlock

            -- Copy to clipboard on click
            local db = false
            local clickBtn = Instance.new("TextButton")
            clickBtn.Name                  = "DiscordBtn"
            clickBtn.Size                  = UDim2.fromScale(1,1)
            clickBtn.BackgroundTransparency= 1
            clickBtn.Text                  = ""
            clickBtn.ZIndex                = 12
            clickBtn.Parent                = discordBlock
            Corner(clickBtn, 18)

            clickBtn.MouseButton1Click:Connect(function()
                if db then return end
                db = true
                if rawget(_G, "setclipboard") then
                    pcall(setclipboard, DISCORD)
                end
                -- flash animation
                tw(discordBlock, TW_FAST, {BackgroundColor3=Color3.fromRGB(88,101,242)}):Play()
                task.delay(0.25, function()
                    tw(discordBlock, TW_MEDIUM, {BackgroundColor3=BG_BASE}):Play()
                    db = false
                end)
            end)
        end

        -- ── BLOCK 3: Animated logo orb (PC) ──
        local logoBlock
        local logoSegments = {}
        if not isMobile then
            logoBlock = makeBlock(36, 34, 3, 18)
            local ls = Stroke(logoBlock, STROKE_C, 1.6, 0.82)
            registerStroke(ls, 0.66)
            addHover(logoBlock)

            local logoFrame = Instance.new("Frame")
            logoFrame.Name                  = "LogoFrame"
            logoFrame.Size                  = UDim2.fromOffset(20, 20)
            logoFrame.AnchorPoint           = Vector2.new(0.5, 0.5)
            logoFrame.Position              = UDim2.fromScale(0.5, 0.5)
            logoFrame.BackgroundTransparency= 1
            logoFrame.ZIndex                = 11
            logoFrame.Parent                = logoBlock

            local SEG_COUNT = 4
            local SEG_IMG   = "rbxassetid://7151778302"
            for i = 1, SEG_COUNT do
                local seg = Instance.new("ImageLabel")
                seg.Size                  = UDim2.fromScale(1,1)
                seg.BackgroundTransparency= 1
                seg.Image                 = SEG_IMG
                seg.ImageTransparency     = 0.30
                seg.Rotation              = (i-1) * (360 / SEG_COUNT)
                seg.ZIndex                = 12
                seg.Parent                = logoFrame
                Corner(seg, 10)
                local g = Instance.new("UIGradient")
                g.Color    = ColorSequence.new(C1, C2)
                g.Rotation = (i-1) * (360/SEG_COUNT)
                g.Parent   = seg
                table.insert(logoSegments, {seg=seg, grad=g})
            end
        end

        -- ── Drag (PC only) ───────────────────────────────────────────────
        if not isMobile then
            local dragBtn = Instance.new("TextButton")
            dragBtn.Name                  = "DragArea"
            dragBtn.Size                  = UDim2.fromScale(1,1)
            dragBtn.BackgroundTransparency= 1
            dragBtn.Text                  = ""
            dragBtn.ZIndex                = 9
            dragBtn.Parent                = mainBlock

            dragBtn.InputBegan:Connect(function(inp)
                if inp.UserInputType == Enum.UserInputType.MouseButton1 then
                    drag.active     = true
                    drag.startMouse = UserInputService:GetMouseLocation()
                    drag.startPos   = UDim2.new(
                        container.Position.X.Scale,
                        container.Position.X.Offset,
                        container.Position.Y.Scale,
                        container.Position.Y.Offset
                    )
                end
            end)

            UserInputService.InputChanged:Connect(function(inp)
                if not drag.active then return end
                if inp.UserInputType ~= Enum.UserInputType.MouseMovement then return end
                local delta = UserInputService:GetMouseLocation() - drag.startMouse
                container.Position = UDim2.new(
                    drag.startPos.X.Scale, drag.startPos.X.Offset + delta.X,
                    drag.startPos.Y.Scale, drag.startPos.Y.Offset + delta.Y
                )
            end)
            UserInputService.InputEnded:Connect(function(inp)
                if inp.UserInputType == Enum.UserInputType.MouseButton1 then
                    drag.active = false
                end
            end)
        end

        -- ── Appear animation ─────────────────────────────────────────────
        container.GroupTransparency = 1
        -- We use a CanvasGroup for the appear effect
        local canvasGroup = Instance.new("CanvasGroup")
        canvasGroup.Size                  = UDim2.fromScale(1,1)
        canvasGroup.BackgroundTransparency= 1
        canvasGroup.GroupTransparency     = 1
        canvasGroup.BorderSizePixel       = 0
        canvasGroup.ZIndex                = 1
        canvasGroup.Parent                = gui

        -- Reparent container into canvasGroup
        container.Parent = canvasGroup
        canvasGroup.Position = isMobile
            and UDim2.new(1,-10,0,48)
            or  UDim2.new(1,-320,0,12)
        canvasGroup.AnchorPoint = isMobile
            and Vector2.new(1,0)
            or  Vector2.new(0,0)
        canvasGroup.Size = UDim2.fromOffset(400, isMobile and 36 or 44)

        -- slide + fade in
        local slideStartY = isMobile and 40 or 4
        canvasGroup.Position = UDim2.new(
            canvasGroup.Position.X.Scale,
            canvasGroup.Position.X.Offset,
            0,
            (isMobile and 40 or 4)
        )
        task.defer(function()
            tw(canvasGroup, TW_SLOW, {
                GroupTransparency = 0,
                Position = isMobile
                    and UDim2.new(1,-10,0,48)
                    or  UDim2.new(1,-320,0,12)
            }):Play()
        end)

        -- ── Heartbeat ────────────────────────────────────────────────────
        local fpsFrames  = 0
        local fpsAccum   = 0
        local timeAccum  = 0
        local lastTimeUpdate = 0

        hb_conn = RunService.Heartbeat:Connect(function(dt)
            gradTime = gradTime + dt

            -- Gradient title animation
            local t  = gradTime
            local s  = math.sin(t / SPEED * math.pi * 2) * 0.5 + 0.5
            local m1 = C1:Lerp(C2, s)
            local m2 = C2:Lerp(C1, s)
            titleGrad.Color    = ColorSequence.new(m1, m2)
            titleGrad.Rotation = (t * 25) % 360

            -- Stroke cycling
            for _, sd in ipairs(strokeList) do
                sd.stroke.Color = getGradColor(sd.phase, t)
            end

            -- Logo segments
            for _, ld in ipairs(logoSegments) do
                ld.grad.Color = ColorSequence.new(m1, m2)
            end

            -- FPS
            if SHOW_FPS and fpsLabel then
                fpsFrames = fpsFrames + 1
                fpsAccum  = fpsAccum + dt
                if fpsAccum >= 0.5 then
                    local fps = math.floor(fpsFrames / fpsAccum)
                    fpsLabel.Text = tostring(fps) .. " fps"
                    -- color: green ≥60, yellow ≥30, red <30
                    if fps >= 60 then
                        fpsLabel.TextColor3 = Color3.fromRGB(100, 255, 140)
                    elseif fps >= 30 then
                        fpsLabel.TextColor3 = Color3.fromRGB(255, 210, 80)
                    else
                        fpsLabel.TextColor3 = Color3.fromRGB(255, 90, 90)
                    end
                    fpsFrames = 0; fpsAccum = 0
                end
            end

            -- Time
            if SHOW_TIME and timeLabel then
                local now = tick()
                if now - lastTimeUpdate >= 1 then
                    lastTimeUpdate = now
                    local td = os.date("*t")
                    timeLabel.Text = string.format("%02d:%02d:%02d", td.hour, td.min, td.sec)
                end
            end
        end)

        -- ── Public API ────────────────────────────────────────────────────
        local WmFunctions = {}

        function WmFunctions:SetVisible(state)
            visible = state
            local target = state and 0 or 1
            tw(canvasGroup, TW_MEDIUM, {GroupTransparency=target}):Play()
            if state then
                -- slide in
                tw(canvasGroup, TW_SLOW, {
                    Position = isMobile
                        and UDim2.new(1,-10,0,48)
                        or  UDim2.new(1,-320,0,12)
                }):Play()
            end
        end

        function WmFunctions:Destroy()
            if hb_conn then hb_conn:Disconnect() end
            tw(canvasGroup, TW_MEDIUM, {GroupTransparency=1}):Play()
            task.delay(0.32, function()
                pcall(function() gui:Destroy() end)
            end)
        end

        function WmFunctions:UpdateTitle(str)
            TITLE = str
            titleLabel.Text = str
        end

        function WmFunctions:UpdateVersion(str)
            VERSION = str
            if versionLabel then versionLabel.Text = str end
        end

        function WmFunctions:SetFPSVisible(state)
            SHOW_FPS = state
            if fpsLabel   then fpsLabel.Visible   = state end
            if fpsDivider then fpsDivider.Visible  = state end
        end

        function WmFunctions:SetTimeVisible(state)
            SHOW_TIME = state
            if timeLabel   then timeLabel.Visible   = state end
            if timeDivider then timeDivider.Visible  = state end
        end

        return WmFunctions
    end
end
