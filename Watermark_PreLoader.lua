--[[
    Watermark_PreLoader.lua — MacLib Preloader Module
    Patches Window with :Watermark(cfg).

    cfg = {
        Title      = "Syllinse",
        Version    = "v4.3",
        ShowFPS    = true,
        ShowTime   = true,
        GradColor1 = Color3.fromRGB(130, 90, 255),
        GradColor2 = Color3.fromRGB(70, 180, 255),
        GradSpeed  = 2.8,
    }

    API:
        wm:SetVisible(bool)
        wm:Destroy()
        wm:UpdateTitle(str)
        wm:UpdateVersion(str)
        wm:SetFPSVisible(bool)
        wm:SetTimeVisible(bool)
]]

return function(ctx)
    local MacLib = ctx.MacLib
    local Window = ctx.Window

    local TweenService     = game:GetService("TweenService")
    local RunService       = game:GetService("RunService")
    local UserInputService = game:GetService("UserInputService")
    local Players          = game:GetService("Players")

    local LocalPlayer = Players.LocalPlayer
    local isMobile    = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

    -- ── Helpers ───────────────────────────────────────────────────────────
    local function GetGui()
        local g = Instance.new("ScreenGui")
        g.ScreenInsets   = Enum.ScreenInsets.None
        g.ResetOnSpawn   = false
        g.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
        g.DisplayOrder   = 2147483645
        local parent
        if RunService:IsStudio() then
            parent = LocalPlayer:FindFirstChild("PlayerGui")
        elseif rawget(_G, "gethui") then
            parent = gethui()
        elseif rawget(_G, "cloneref") then
            parent = cloneref(game:GetService("CoreGui"))
        else
            parent = game:GetService("CoreGui")
        end
        g.Parent = parent
        return g
    end

    local function tw(inst, info, props)
        return TweenService:Create(inst, info, props)
    end

    local TW_FAST   = TweenInfo.new(0.18, Enum.EasingStyle.Sine)
    local TW_MEDIUM = TweenInfo.new(0.28, Enum.EasingStyle.Sine)
    local TW_SLOW   = TweenInfo.new(0.50, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out)

    local function Corner(parent, r)
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0, r or 8)
        c.Parent = parent
        return c
    end

    local function MakeStroke(parent, color, thickness, transparency)
        local s = Instance.new("UIStroke")
        s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
        s.Color           = color or Color3.fromRGB(255, 255, 255)
        s.Thickness       = thickness or 1.5
        s.Transparency    = transparency or 0.82
        s.Parent          = parent
        return s
    end

    local function MakePad(parent, l, r, t, b)
        local p = Instance.new("UIPadding")
        p.PaddingLeft   = UDim.new(0, l or 0)
        p.PaddingRight  = UDim.new(0, r or 0)
        p.PaddingTop    = UDim.new(0, t or 0)
        p.PaddingBottom = UDim.new(0, b or 0)
        p.Parent = parent
        return p
    end

    -- ── SetAllTransparency: fade every visual child ────────────────────────
    -- We cannot use GroupTransparency on a Frame, so we tween each
    -- BackgroundTransparency / TextTransparency / ImageTransparency manually.
    local function collectFadeable(root, list)
        list = list or {}
        for _, child in ipairs(root:GetChildren()) do
            if child:IsA("Frame") or child:IsA("ImageLabel") or child:IsA("TextLabel") or child:IsA("TextButton") then
                table.insert(list, child)
            end
            collectFadeable(child, list)
        end
        return list
    end

    -- ── Patch Window:Watermark ─────────────────────────────────────────────
    Window.Watermark = function(_, cfg)
        cfg = cfg or {}

        local TITLE     = cfg.Title     or "Script"
        local VERSION   = cfg.Version   or ""
        local SHOW_FPS  = (cfg.ShowFPS  ~= false)
        local SHOW_TIME = (cfg.ShowTime ~= false)
        local C1        = cfg.GradColor1 or Color3.fromRGB(130, 90, 255)
        local C2        = cfg.GradColor2 or Color3.fromRGB(70, 180, 255)
        local SPEED     = cfg.GradSpeed  or 2.8

        local BG_BASE  = Color3.fromRGB(15, 15, 15)
        local BG_HOVER = Color3.fromRGB(24, 24, 26)
        local WHITE    = Color3.fromRGB(255, 255, 255)

        -- sizes
        local H     = isMobile and 28 or 34
        local FS    = isMobile and 11 or 13
        local FS_SM = isMobile and 10 or 12
        local PAD   = isMobile and 8  or 10

        -- State
        local gradTime   = 0
        local hb_conn    = nil
        local drag       = { active = false, startMouse = Vector2.zero, startPos = UDim2.new() }
        local strokeList = {}  -- { stroke, phase }
        local isVisible  = true

        local function getGradColor(phase, t)
            local s = math.sin((t / SPEED + phase) * math.pi * 2) * 0.5 + 0.5
            return C1:Lerp(C2, s)
        end

        local function regStroke(s, phase)
            table.insert(strokeList, { stroke = s, phase = phase or 0 })
        end

        -- ── Root GUI ──────────────────────────────────────────────────────
        local gui = GetGui()
        gui.Name = "MacLib_Watermark"

        -- ── Outer wrapper Frame (used for slide animation) ─────────────────
        -- Position anchor differs: PC top-right drag / Mobile fixed top-right
        local wrapper = Instance.new("Frame")
        wrapper.Name                  = "WmWrapper"
        wrapper.BackgroundTransparency = 1
        wrapper.BorderSizePixel       = 0
        wrapper.ZIndex                = 10
        wrapper.Size                  = UDim2.fromOffset(10, H + 4)
        wrapper.ClipsDescendants      = false
        wrapper.Parent                = gui

        if isMobile then
            wrapper.AnchorPoint = Vector2.new(1, 0)
            wrapper.Position    = UDim2.new(1, -10, 0, 48)
        else
            wrapper.AnchorPoint = Vector2.new(0, 0)
            wrapper.Position    = UDim2.new(1, -320, 0, 12)
        end

        -- ── Container (horizontal list of blocks) ─────────────────────────
        local container = Instance.new("Frame")
        container.Name                  = "WmContainer"
        container.BackgroundTransparency = 1
        container.BorderSizePixel       = 0
        container.ZIndex                = 10
        container.Size                  = UDim2.fromOffset(10, H)
        container.Parent                = wrapper

        local layout = Instance.new("UIListLayout")
        layout.FillDirection       = Enum.FillDirection.Horizontal
        layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
        layout.VerticalAlignment   = Enum.VerticalAlignment.Center
        layout.Padding             = UDim.new(0, 6)
        layout.SortOrder           = Enum.SortOrder.LayoutOrder
        layout.Parent              = container

        -- auto-size container + wrapper
        layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
            local w = layout.AbsoluteContentSize.X
            container.Size = UDim2.fromOffset(w, H)
            wrapper.Size   = UDim2.fromOffset(w, H + 4)
        end)

        -- ── Block factory ──────────────────────────────────────────────────
        local function makeBlock(order, radius)
            local f = Instance.new("Frame")
            f.Name                  = "WmBlock"
            f.Size                  = UDim2.fromOffset(10, H)
            f.BackgroundColor3      = BG_BASE
            f.BackgroundTransparency = 0.08
            f.BorderSizePixel       = 0
            f.LayoutOrder           = order
            f.ZIndex                = 10
            f.Parent                = container
            Corner(f, radius or 9)
            return f
        end

        local function addHover(block)
            if isMobile then return end
            local base_t = 0.08
            block.MouseEnter:Connect(function()
                tw(block, TW_FAST, { BackgroundColor3 = BG_HOVER, BackgroundTransparency = 0.0 }):Play()
            end)
            block.MouseLeave:Connect(function()
                tw(block, TW_FAST, { BackgroundColor3 = BG_BASE, BackgroundTransparency = base_t }):Play()
            end)
        end

        local function makeDividerPill(parent, order)
            local d = Instance.new("Frame")
            d.Size                  = UDim2.fromOffset(1, isMobile and 13 or 17)
            d.BackgroundColor3      = WHITE
            d.BackgroundTransparency = 0.80
            d.BorderSizePixel       = 0
            d.ZIndex                = 11
            d.LayoutOrder           = order
            d.Parent                = parent
            Corner(d, 2)
            return d
        end

        -- ════════════════════════════════════════
        -- BLOCK 1: Main (Title / Version / FPS / Time)
        -- ════════════════════════════════════════
        local mainBlock = makeBlock(1)
        addHover(mainBlock)
        local mainStroke = MakeStroke(mainBlock, WHITE, isMobile and 1.2 or 1.6, 0.82)
        regStroke(mainStroke, 0)

        local innerLayout = Instance.new("UIListLayout")
        innerLayout.FillDirection       = Enum.FillDirection.Horizontal
        innerLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
        innerLayout.VerticalAlignment   = Enum.VerticalAlignment.Center
        innerLayout.Padding             = UDim.new(0, isMobile and 6 or 8)
        innerLayout.SortOrder           = Enum.SortOrder.LayoutOrder
        innerLayout.Parent              = mainBlock
        MakePad(mainBlock, PAD, PAD, 0, 0)

        innerLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
            mainBlock.Size = UDim2.fromOffset(
                innerLayout.AbsoluteContentSize.X + PAD * 2,
                H
            )
        end)

        -- Title label (gradient animated)
        local titleLabel = Instance.new("TextLabel")
        titleLabel.Name                   = "WmTitle"
        titleLabel.BackgroundTransparency = 1
        titleLabel.Text                   = TITLE
        titleLabel.TextColor3             = WHITE
        titleLabel.TextSize               = FS
        titleLabel.FontFace               = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Bold)
        titleLabel.TextXAlignment         = Enum.TextXAlignment.Left
        titleLabel.AutomaticSize          = Enum.AutomaticSize.XY
        titleLabel.ZIndex                 = 11
        titleLabel.LayoutOrder            = 1
        titleLabel.Size                   = UDim2.fromOffset(0, H)
        titleLabel.Parent                 = mainBlock

        local titleGrad = Instance.new("UIGradient")
        titleGrad.Color    = ColorSequence.new(C1, C2)
        titleGrad.Rotation = 0
        titleGrad.Parent   = titleLabel

        -- Version + separator
        local versionLabel
        if VERSION ~= "" then
            local sep = Instance.new("TextLabel")
            sep.Name                   = "WmSep"
            sep.BackgroundTransparency = 1
            sep.Text                   = "/"
            sep.TextColor3             = WHITE
            sep.TextTransparency       = 0.72
            sep.TextSize               = FS_SM
            sep.FontFace               = Font.new("rbxasset://fonts/families/GothamSSm.json")
            sep.AutomaticSize          = Enum.AutomaticSize.XY
            sep.ZIndex                 = 11
            sep.LayoutOrder            = 2
            sep.Size                   = UDim2.fromOffset(0, H)
            sep.Parent                 = mainBlock

            versionLabel = Instance.new("TextLabel")
            versionLabel.Name                   = "WmVersion"
            versionLabel.BackgroundTransparency = 1
            versionLabel.Text                   = VERSION
            versionLabel.TextColor3             = WHITE
            versionLabel.TextTransparency       = 0.45
            versionLabel.TextSize               = FS_SM
            versionLabel.FontFace               = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Medium)
            versionLabel.AutomaticSize          = Enum.AutomaticSize.XY
            versionLabel.ZIndex                 = 11
            versionLabel.LayoutOrder            = 3
            versionLabel.Size                   = UDim2.fromOffset(0, H)
            versionLabel.Parent                 = mainBlock
        end

        -- FPS
        local fpsLabel, fpsDivider
        if SHOW_FPS then
            fpsDivider = makeDividerPill(mainBlock, 4)

            local fpsIcon = Instance.new("ImageLabel")
            fpsIcon.Name                   = "FPSIcon"
            fpsIcon.Size                   = UDim2.fromOffset(isMobile and 11 or 13, isMobile and 11 or 13)
            fpsIcon.BackgroundTransparency = 1
            fpsIcon.Image                  = "rbxassetid://8587689304"
            fpsIcon.ImageColor3            = WHITE
            fpsIcon.ImageTransparency      = 0.35
            fpsIcon.ZIndex                 = 11
            fpsIcon.LayoutOrder            = 5
            fpsIcon.Parent                 = mainBlock

            fpsLabel = Instance.new("TextLabel")
            fpsLabel.Name                   = "WmFPS"
            fpsLabel.BackgroundTransparency = 1
            fpsLabel.Text                   = "-- fps"
            fpsLabel.TextColor3             = Color3.fromRGB(100, 255, 140)
            fpsLabel.TextTransparency       = 0.10
            fpsLabel.TextSize               = FS_SM
            fpsLabel.FontFace               = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Medium)
            fpsLabel.AutomaticSize          = Enum.AutomaticSize.XY
            fpsLabel.ZIndex                 = 11
            fpsLabel.LayoutOrder            = 6
            fpsLabel.Size                   = UDim2.fromOffset(0, H)
            fpsLabel.Parent                 = mainBlock
        end

        -- Time
        local timeLabel, timeDivider
        if SHOW_TIME then
            timeDivider = makeDividerPill(mainBlock, 7)

            local clockIcon = Instance.new("ImageLabel")
            clockIcon.Name                   = "ClockIcon"
            clockIcon.Size                   = UDim2.fromOffset(isMobile and 11 or 13, isMobile and 11 or 13)
            clockIcon.BackgroundTransparency = 1
            clockIcon.Image                  = "rbxassetid://4034150594"
            clockIcon.ImageColor3            = WHITE
            clockIcon.ImageTransparency      = 0.35
            clockIcon.ZIndex                 = 11
            clockIcon.LayoutOrder            = 8
            clockIcon.Parent                 = mainBlock

            timeLabel = Instance.new("TextLabel")
            timeLabel.Name                   = "WmTime"
            timeLabel.BackgroundTransparency = 1
            timeLabel.Text                   = "00:00:00"
            timeLabel.TextColor3             = WHITE
            timeLabel.TextTransparency       = 0.38
            timeLabel.TextSize               = FS_SM
            timeLabel.FontFace               = Font.new("rbxasset://fonts/families/GothamSSm.json")
            timeLabel.AutomaticSize          = Enum.AutomaticSize.XY
            timeLabel.ZIndex                 = 11
            timeLabel.LayoutOrder            = 9
            timeLabel.Size                   = UDim2.fromOffset(0, H)
            timeLabel.Parent                 = mainBlock
        end

        -- ════════════════════════════════════════
        -- BLOCK 2: Animated logo orb (PC only)
        -- ════════════════════════════════════════
        local logoSegments = {}
        if not isMobile then
            local logoBlock = makeBlock(2, 18)
            local ls = MakeStroke(logoBlock, WHITE, 1.6, 0.82)
            regStroke(ls, 0.5)
            addHover(logoBlock)
            logoBlock.Size = UDim2.fromOffset(34, H)

            local logoFrame = Instance.new("Frame")
            logoFrame.Name                   = "LogoFrame"
            logoFrame.Size                   = UDim2.fromOffset(20, 20)
            logoFrame.AnchorPoint            = Vector2.new(0.5, 0.5)
            logoFrame.Position               = UDim2.fromScale(0.5, 0.5)
            logoFrame.BackgroundTransparency = 1
            logoFrame.ZIndex                 = 11
            logoFrame.Parent                 = logoBlock

            local SEG_COUNT = 4
            local SEG_IMG   = "rbxassetid://7151778302"
            for i = 1, SEG_COUNT do
                local seg = Instance.new("ImageLabel")
                seg.Size                   = UDim2.fromScale(1, 1)
                seg.BackgroundTransparency = 1
                seg.Image                  = SEG_IMG
                seg.ImageTransparency      = 0.28
                seg.Rotation               = (i - 1) * (360 / SEG_COUNT)
                seg.ZIndex                 = 12
                seg.Parent                 = logoFrame
                Corner(seg, 10)
                local g = Instance.new("UIGradient")
                g.Color    = ColorSequence.new(C1, C2)
                g.Rotation = (i - 1) * (360 / SEG_COUNT)
                g.Parent   = seg
                table.insert(logoSegments, { seg = seg, grad = g })
            end
        end

        -- ════════════════════════════════════════
        -- DRAG (PC only)
        -- ════════════════════════════════════════
        if not isMobile then
            local dragArea = Instance.new("TextButton")
            dragArea.Name                   = "DragArea"
            dragArea.Size                   = UDim2.fromScale(1, 1)
            dragArea.BackgroundTransparency = 1
            dragArea.Text                   = ""
            dragArea.ZIndex                 = 9
            dragArea.AutoButtonColor        = false
            dragArea.Parent                 = mainBlock

            dragArea.InputBegan:Connect(function(inp)
                if inp.UserInputType == Enum.UserInputType.MouseButton1 then
                    drag.active     = true
                    drag.startMouse = UserInputService:GetMouseLocation()
                    drag.startPos   = UDim2.new(
                        wrapper.Position.X.Scale,  wrapper.Position.X.Offset,
                        wrapper.Position.Y.Scale,  wrapper.Position.Y.Offset
                    )
                end
            end)

            UserInputService.InputChanged:Connect(function(inp)
                if not drag.active then return end
                if inp.UserInputType ~= Enum.UserInputType.MouseMovement then return end
                local delta = UserInputService:GetMouseLocation() - drag.startMouse
                wrapper.Position = UDim2.new(
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

        -- ════════════════════════════════════════
        -- APPEAR ANIMATION (slide-down + fade via ImageTransparency / TextTransparency)
        -- We fade the wrapper itself by animating its children.
        -- ════════════════════════════════════════
        -- Slide in from slightly above
        local baseY = isMobile and 48 or 12
        wrapper.Position = UDim2.new(
            wrapper.Position.X.Scale,
            wrapper.Position.X.Offset,
            0, baseY - 10
        )
        -- Start all text/image children fully transparent
        local function setChildrenTransparency(target)
            for _, d in ipairs(mainBlock:GetDescendants()) do
                if d:IsA("TextLabel") then
                    d.TextTransparency = target == 0 and d.TextTransparency or 1
                end
                if d:IsA("ImageLabel") then
                    d.ImageTransparency = target == 0 and d.ImageTransparency or 1
                end
            end
            mainBlock.BackgroundTransparency = target == 0 and 0.08 or 1
        end

        setChildrenTransparency(1)

        -- Restore original transparencies for each element
        local origTransparencies = {}
        for _, d in ipairs(mainBlock:GetDescendants()) do
            if d:IsA("TextLabel") then
                origTransparencies[d] = d.TextTransparency == 1 and 0.10 or d.TextTransparency
            end
        end
        -- Store before overwrite
        local origTextTransp = {
            title   = titleLabel.TextTransparency,
            version = versionLabel and versionLabel.TextTransparency or nil,
            fps     = fpsLabel     and fpsLabel.TextTransparency     or nil,
            time    = timeLabel    and timeLabel.TextTransparency    or nil,
        }

        task.defer(function()
            -- Slide in
            tw(wrapper, TW_SLOW, {
                Position = UDim2.new(
                    wrapper.Position.X.Scale,
                    wrapper.Position.X.Offset,
                    0, baseY
                )
            }):Play()
            -- Fade in main block background
            tw(mainBlock, TW_SLOW, { BackgroundTransparency = 0.08 }):Play()
            -- Fade in title gradient
            tw(titleLabel, TW_MEDIUM, { TextTransparency = 0 }):Play()
            if versionLabel then tw(versionLabel, TW_MEDIUM, { TextTransparency = 0.45 }):Play() end
            if fpsLabel     then tw(fpsLabel,     TW_MEDIUM, { TextTransparency = 0.10 }):Play() end
            if timeLabel    then tw(timeLabel,     TW_MEDIUM, { TextTransparency = 0.38 }):Play() end
            -- Reveal strokes
            for _, sd in ipairs(strokeList) do
                tw(sd.stroke, TW_SLOW, { Transparency = 0.82 }):Play()
            end
            -- Fade in logo segments
            for _, ld in ipairs(logoSegments) do
                tw(ld.seg, TW_MEDIUM, { ImageTransparency = 0.28 }):Play()
            end
        end)

        -- ════════════════════════════════════════
        -- HEARTBEAT
        -- ════════════════════════════════════════
        local fpsFrames = 0
        local fpsAccum  = 0
        local lastTimeUpdate = 0

        hb_conn = RunService.Heartbeat:Connect(function(dt)
            gradTime = gradTime + dt
            local t = gradTime

            -- Animated gradient on title
            local s  = math.sin(t / SPEED * math.pi * 2) * 0.5 + 0.5
            local m1 = C1:Lerp(C2, s)
            local m2 = C2:Lerp(C1, s)
            titleGrad.Color    = ColorSequence.new(m1, m2)
            titleGrad.Rotation = (t * 28) % 360

            -- Stroke cycling
            for _, sd in ipairs(strokeList) do
                sd.stroke.Color = getGradColor(sd.phase, t)
            end

            -- Logo segments
            for _, ld in ipairs(logoSegments) do
                ld.grad.Color = ColorSequence.new(m1, m2)
            end

            -- FPS counter
            if SHOW_FPS and fpsLabel then
                fpsFrames = fpsFrames + 1
                fpsAccum  = fpsAccum + dt
                if fpsAccum >= 0.5 then
                    local fps = math.floor(fpsFrames / fpsAccum)
                    fpsLabel.Text = tostring(fps) .. " fps"
                    if fps >= 60 then
                        fpsLabel.TextColor3 = Color3.fromRGB(100, 255, 140)
                    elseif fps >= 30 then
                        fpsLabel.TextColor3 = Color3.fromRGB(255, 210, 80)
                    else
                        fpsLabel.TextColor3 = Color3.fromRGB(255, 90, 90)
                    end
                    fpsFrames = 0
                    fpsAccum  = 0
                end
            end

            -- Time display
            if SHOW_TIME and timeLabel then
                local now = tick()
                if now - lastTimeUpdate >= 1 then
                    lastTimeUpdate = now
                    local td = os.date("*t")
                    timeLabel.Text = string.format("%02d:%02d:%02d", td.hour, td.min, td.sec)
                end
            end
        end)

        -- ════════════════════════════════════════
        -- PUBLIC API
        -- ════════════════════════════════════════
        local WmFunctions = {}

        local function fadeIn()
            tw(wrapper, TW_SLOW, {
                Position = UDim2.new(
                    wrapper.Position.X.Scale,
                    wrapper.Position.X.Offset,
                    0, baseY
                )
            }):Play()
            tw(mainBlock, TW_MEDIUM, { BackgroundTransparency = 0.08 }):Play()
            tw(titleLabel, TW_MEDIUM, { TextTransparency = 0 }):Play()
            if versionLabel then tw(versionLabel, TW_MEDIUM, { TextTransparency = 0.45 }):Play() end
            if fpsLabel     then tw(fpsLabel,     TW_MEDIUM, { TextTransparency = 0.10 }):Play() end
            if timeLabel    then tw(timeLabel,     TW_MEDIUM, { TextTransparency = 0.38 }):Play() end
            for _, sd in ipairs(strokeList) do tw(sd.stroke, TW_MEDIUM, { Transparency = 0.82 }):Play() end
            for _, ld in ipairs(logoSegments) do tw(ld.seg, TW_MEDIUM, { ImageTransparency = 0.28 }):Play() end
        end

        local function fadeOut()
            tw(wrapper, TW_MEDIUM, {
                Position = UDim2.new(
                    wrapper.Position.X.Scale,
                    wrapper.Position.X.Offset,
                    0, baseY - 8
                )
            }):Play()
            tw(mainBlock, TW_MEDIUM, { BackgroundTransparency = 1 }):Play()
            tw(titleLabel, TW_MEDIUM, { TextTransparency = 1 }):Play()
            if versionLabel then tw(versionLabel, TW_MEDIUM, { TextTransparency = 1 }):Play() end
            if fpsLabel     then tw(fpsLabel,     TW_MEDIUM, { TextTransparency = 1 }):Play() end
            if timeLabel    then tw(timeLabel,     TW_MEDIUM, { TextTransparency = 1 }):Play() end
            for _, sd in ipairs(strokeList) do tw(sd.stroke, TW_MEDIUM, { Transparency = 1 }):Play() end
            for _, ld in ipairs(logoSegments) do tw(ld.seg, TW_MEDIUM, { ImageTransparency = 1 }):Play() end
        end

        function WmFunctions:SetVisible(state)
            isVisible = state
            if state then fadeIn() else fadeOut() end
        end

        function WmFunctions:Destroy()
            fadeOut()
            task.delay(0.32, function()
                if hb_conn then hb_conn:Disconnect() end
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
            -- FPS icon
            local icon = mainBlock:FindFirstChild("FPSIcon")
            if icon then icon.Visible = state end
        end

        function WmFunctions:SetTimeVisible(state)
            SHOW_TIME = state
            if timeLabel   then timeLabel.Visible   = state end
            if timeDivider then timeDivider.Visible  = state end
            local icon = mainBlock:FindFirstChild("ClockIcon")
            if icon then icon.Visible = state end
        end

        return WmFunctions
    end
end
