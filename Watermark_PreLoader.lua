-- Watermark_PreLoader.lua  (v4 — ScreenGui + Drawing effects)
-- ScreenGui: основа UI (чипы, текст, иконки)
-- Drawing: фоновые частицы/линии поверх всего (эффект элитного чита)
-- Spring-анимация через Heartbeat lerp, FPS rolling avg, fixed-width chips

return function(ctx)
    local MacLib       = ctx.MacLib
    local TweenService = game:GetService("TweenService")
    local RunService   = game:GetService("RunService")

    local function lerp(a, b, t) return a + (b - a) * t end

    local function GetGui()
        local g = Instance.new("ScreenGui")
        g.ResetOnSpawn    = false
        g.DisplayOrder    = 9998
        g.IgnoreGuiInset  = true
        g.ZIndexBehavior  = Enum.ZIndexBehavior.Sibling
        local ok
        if gethui then ok = pcall(function() g.Parent = gethui() end) end
        if not ok or not g.Parent then ok = pcall(function() g.Parent = game:GetService("CoreGui") end) end
        if not ok or not g.Parent then
            g.Parent = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
        end
        return g
    end

    -- ──────────────────────────────────────────────────────────────────────
    function MacLib:Watermark(cfg)
        cfg = cfg or {}
        local titleText = cfg.Title    or "Watermark"
        local showFPS   = cfg.ShowFPS  ~= false
        local showTime  = cfg.ShowTime ~= false
        local initPos   = cfg.Position or UDim2.fromOffset(22, 22)

        -- ── ScreenGui ────────────────────────────────────────────────────
        local gui = GetGui()
        gui.Name = "MacLibWatermark"

        -- Anchor frame (draggable position)
        local anchor = Instance.new("Frame")
        anchor.Name                   = "WmAnchor"
        anchor.AnchorPoint            = Vector2.new(0, 0)
        anchor.BackgroundTransparency = 1
        anchor.BorderSizePixel        = 0
        anchor.AutomaticSize          = Enum.AutomaticSize.XY
        anchor.Parent                 = gui

        -- Set initial position from cfg
        if typeof(initPos) == "UDim2" then
            anchor.Position = initPos
        elseif typeof(initPos) == "Vector2" then
            anchor.Position = UDim2.fromOffset(initPos.X, initPos.Y)
        end

        -- UIScale for spring animation
        local uiScale = Instance.new("UIScale")
        uiScale.Scale  = 1
        uiScale.Parent = anchor

        -- Row container
        local row = Instance.new("Frame")
        row.Name                   = "WmRow"
        row.BackgroundTransparency = 1
        row.BorderSizePixel        = 0
        row.AutomaticSize          = Enum.AutomaticSize.XY
        row.Parent                 = anchor

        local rowList = Instance.new("UIListLayout")
        rowList.FillDirection     = Enum.FillDirection.Horizontal
        rowList.VerticalAlignment = Enum.VerticalAlignment.Center
        rowList.SortOrder         = Enum.SortOrder.LayoutOrder
        rowList.Padding           = UDim.new(0, 0)  -- chips share borders, no gap
        rowList.Parent            = row

        -- ── Constants ─────────────────────────────────────────────────────
        local H          = 30
        local PAD_X      = 11
        local ICON_SZ    = 14
        local FONT_BODY  = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Medium)
        local FONT_TITLE = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.SemiBold)
        local TXT_SZ     = 13

        -- Color palette (Neverlose-style dark + blue)
        local COL_BG_TITLE  = Color3.fromRGB(14, 14, 20)
        local COL_BG_CHIP   = Color3.fromRGB(10, 10, 14)
        local COL_ACCENT    = Color3.fromRGB(72, 138, 255)
        local COL_STROKE    = Color3.fromRGB(38, 38, 52)
        local COL_TEXT_MAIN = Color3.fromRGB(220, 220, 232)
        local COL_TEXT_MUTE = Color3.fromRGB(138, 138, 155)
        local COL_SEP       = Color3.fromRGB(38, 38, 52)

        -- Outer border radius
        local RADIUS = 7

        -- ── Chip factory ──────────────────────────────────────────────────
        local allChips = {}  -- { frame, content frames/labels }
        local chipCount = 0

        local function makeChip(opts)
            chipCount += 1
            opts = opts or {}

            local chip = Instance.new("Frame")
            chip.Name                   = "Chip" .. chipCount
            chip.BackgroundColor3       = opts.bg or COL_BG_CHIP
            chip.BackgroundTransparency = 0
            chip.BorderSizePixel        = 0
            chip.LayoutOrder            = chipCount
            chip.AutomaticSize          = opts.fixedW and Enum.AutomaticSize.None or Enum.AutomaticSize.X
            chip.Size                   = opts.fixedW
                                          and UDim2.fromOffset(opts.fixedW, H)
                                          or  UDim2.fromOffset(0, H)
            chip.ClipsDescendants       = false
            chip.Parent                 = row

            -- Left separator line (except first chip)
            if chipCount > 1 then
                local sep = Instance.new("Frame")
                sep.Name              = "Sep"
                sep.AnchorPoint       = Vector2.new(0, 0)
                sep.Position          = UDim2.fromOffset(0, 0)
                sep.Size              = UDim2.fromOffset(1, H)
                sep.BackgroundColor3  = COL_SEP
                sep.BackgroundTransparency = 0
                sep.BorderSizePixel   = 0
                sep.ZIndex            = 2
                sep.Parent            = chip
            end

            -- Horizontal padding
            local pad = Instance.new("UIPadding")
            pad.PaddingLeft  = UDim.new(0, chipCount > 1 and PAD_X + 1 or PAD_X)
            pad.PaddingRight = UDim.new(0, PAD_X)
            pad.Parent       = chip

            local entry = { frame = chip, labels = {}, images = {} }
            table.insert(allChips, entry)
            return entry
        end

        -- ── Outer wrapper for rounded corners on the whole bar ───────────
        -- We wrap all chips in a Frame with UICorner
        -- The row frame itself is the clipping container
        local outerWrap = Instance.new("Frame")
        outerWrap.Name                   = "WmOuter"
        outerWrap.BackgroundTransparency = 1
        outerWrap.BorderSizePixel        = 0
        outerWrap.AutomaticSize          = Enum.AutomaticSize.XY
        outerWrap.ClipsDescendants       = true
        outerWrap.Parent                 = anchor

        -- Move row inside outerWrap
        row.Parent = outerWrap

        local outerCorner = Instance.new("UICorner")
        outerCorner.CornerRadius = UDim.new(0, RADIUS)
        outerCorner.Parent       = outerWrap

        -- Outer stroke (1px border around entire bar)
        local outerStroke = Instance.new("UIStroke")
        outerStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
        outerStroke.Color           = COL_STROKE
        outerStroke.Transparency    = 0
        outerStroke.Thickness       = 1
        outerStroke.Parent          = outerWrap

        -- ── Accent bottom line (animated, sits outside ClipsDescendants) ─
        -- We put it on a separate Frame overlaid at the bottom
        local accentBar = Instance.new("Frame")
        accentBar.Name              = "AccentBar"
        accentBar.AnchorPoint       = Vector2.new(0, 1)
        accentBar.Position          = UDim2.new(0, 0, 1, 0)
        accentBar.Size              = UDim2.new(1, 0, 0, 1)
        accentBar.BackgroundColor3  = COL_ACCENT
        accentBar.BackgroundTransparency = 0
        accentBar.BorderSizePixel   = 0
        accentBar.ZIndex            = 10
        accentBar.Parent            = outerWrap

        -- ── Build chips ───────────────────────────────────────────────────

        -- CHIP 1: Title
        local titleEntry = makeChip({ bg = COL_BG_TITLE })

        local titleLbl = Instance.new("TextLabel")
        titleLbl.Name                   = "TitleLbl"
        titleLbl.FontFace               = FONT_TITLE
        titleLbl.TextSize               = TXT_SZ
        titleLbl.TextColor3             = COL_TEXT_MAIN
        titleLbl.BackgroundTransparency = 1
        titleLbl.BorderSizePixel        = 0
        titleLbl.AutomaticSize          = Enum.AutomaticSize.X
        titleLbl.Size                   = UDim2.fromOffset(0, H)
        titleLbl.TextXAlignment         = Enum.TextXAlignment.Left
        titleLbl.Text                   = titleText
        titleLbl.ZIndex                 = 3
        titleLbl.Parent                 = titleEntry.frame
        table.insert(titleEntry.labels, titleLbl)

        -- CHIP 2: FPS (icon + number, fixed width)
        local fpsEntry, fpsLbl, fpsIcon
        if showFPS then
            fpsEntry = makeChip({ fixedW = 84 })

            -- icon
            fpsIcon = Instance.new("ImageLabel")
            fpsIcon.Name                   = "FpsIcon"
            fpsIcon.Image                  = "rbxassetid://102994395432803"
            fpsIcon.Size                   = UDim2.fromOffset(ICON_SZ, ICON_SZ)
            fpsIcon.AnchorPoint            = Vector2.new(0, 0.5)
            fpsIcon.Position               = UDim2.new(0, 0, 0.5, 0)
            fpsIcon.BackgroundTransparency = 1
            fpsIcon.BorderSizePixel        = 0
            fpsIcon.ZIndex                 = 3
            fpsIcon.Parent                 = fpsEntry.frame

            -- number label
            fpsLbl = Instance.new("TextLabel")
            fpsLbl.Name                   = "FpsLbl"
            fpsLbl.FontFace               = FONT_BODY
            fpsLbl.TextSize               = TXT_SZ
            fpsLbl.TextColor3             = COL_TEXT_MUTE
            fpsLbl.BackgroundTransparency = 1
            fpsLbl.BorderSizePixel        = 0
            fpsLbl.AutomaticSize          = Enum.AutomaticSize.None
            fpsLbl.Size                   = UDim2.new(1, -(ICON_SZ + 4), 1, 0)
            fpsLbl.Position               = UDim2.fromOffset(ICON_SZ + 4, 0)
            fpsLbl.TextXAlignment         = Enum.TextXAlignment.Left
            fpsLbl.Text                   = "--"
            fpsLbl.ZIndex                 = 3
            fpsLbl.Parent                 = fpsEntry.frame

            table.insert(fpsEntry.labels, fpsLbl)
            table.insert(fpsEntry.images, fpsIcon)
        end

        -- CHIP 3: Time (icon + clock, fixed width)
        local timeEntry, timeLbl, timeIcon
        if showTime then
            timeEntry = makeChip({ fixedW = 120 })

            timeIcon = Instance.new("ImageLabel")
            timeIcon.Name                   = "TimeIcon"
            timeIcon.Image                  = "rbxassetid://17824308575"
            timeIcon.Size                   = UDim2.fromOffset(ICON_SZ, ICON_SZ)
            timeIcon.AnchorPoint            = Vector2.new(0, 0.5)
            timeIcon.Position               = UDim2.new(0, 0, 0.5, 0)
            timeIcon.BackgroundTransparency = 1
            timeIcon.BorderSizePixel        = 0
            timeIcon.ZIndex                 = 3
            timeIcon.Parent                 = timeEntry.frame

            timeLbl = Instance.new("TextLabel")
            timeLbl.Name                   = "TimeLbl"
            timeLbl.FontFace               = FONT_BODY
            timeLbl.TextSize               = TXT_SZ
            timeLbl.TextColor3             = COL_TEXT_MUTE
            timeLbl.BackgroundTransparency = 1
            timeLbl.BorderSizePixel        = 0
            timeLbl.AutomaticSize          = Enum.AutomaticSize.None
            timeLbl.Size                   = UDim2.new(1, -(ICON_SZ + 4), 1, 0)
            timeLbl.Position               = UDim2.fromOffset(ICON_SZ + 4, 0)
            timeLbl.TextXAlignment         = Enum.TextXAlignment.Left
            timeLbl.Text                   = "00:00:00"
            timeLbl.ZIndex                 = 3
            timeLbl.Parent                 = timeEntry.frame

            table.insert(timeEntry.labels, timeLbl)
            table.insert(timeEntry.images, timeIcon)
        end

        -- ── Drawing effects layer ─────────────────────────────────────────
        -- Rendered on top of ScreenGui via Drawing (ZIndex > GUI).
        -- Effect: animated shimmer lines that follow the watermark position.
        -- These are purely decorative — the main UI is ScreenGui.
        local drawObjs = {}
        local function newDraw(t)
            local d = Drawing.new(t)
            table.insert(drawObjs, d)
            return d
        end

        -- 3 thin horizontal shimmer lines above/below the bar
        local shimLines = {}
        for i = 1, 3 do
            local l = newDraw("Line")
            l.Thickness    = 1
            l.Transparency = 1  -- start invisible, animated
            l.ZIndex       = 5
            table.insert(shimLines, l)
        end

        -- Glow dot at the accent line (left corner)
        local glowDot = newDraw("Circle")
        glowDot.Filled      = true
        glowDot.Radius      = 3
        glowDot.ZIndex      = 6
        glowDot.Transparency = 1
        glowDot.Color       = COL_ACCENT

        -- ── Animation state ───────────────────────────────────────────────
        local visible    = true
        local alpha      = 0       -- 0=hidden 1=shown
        local targetA    = 1
        local SPRING_IN  = 14
        local SPRING_OUT = 20

        -- Accent bar animation (hue shift Blue→Purple→Blue)
        local accentPhase = 0

        -- Drawing shimmer animation
        local shimPhase = 0

        -- FPS rolling average
        local FPS_N    = 30
        local fpsBuf   = table.create(FPS_N, 1/60)
        local fpsBufI  = 1
        local fpsTimer = 0

        -- Time
        local lastSec = -1

        -- ── Apply alpha to all ScreenGui objects ──────────────────────────
        local function applyAlpha(a)
            -- UIScale: spring overshoot on appear (scale 0.82→1.04→1)
            -- We just use lerp here; the overshoot comes from the lerp speed difference
            uiScale.Scale = lerp(0.82, 1, a)

            -- Fade all chips
            local bgT    = lerp(1, 0, a)              -- 1=invisible 0=opaque
            local textT  = lerp(1, 0, a)
            local strokeT = lerp(1, 0, a)

            for _, entry in ipairs(allChips) do
                entry.frame.BackgroundTransparency = bgT
                -- separator lines inside chip (if any)
                for _, child in ipairs(entry.frame:GetChildren()) do
                    if child.Name == "Sep" then
                        child.BackgroundTransparency = bgT
                    end
                end
                for _, lbl in ipairs(entry.labels) do
                    lbl.TextTransparency = textT
                end
                for _, img in ipairs(entry.images) do
                    img.ImageTransparency = textT
                end
            end

            outerStroke.Transparency = strokeT
            accentBar.BackgroundTransparency = textT

            -- Drawing objects
            for i, sl in ipairs(shimLines) do
                sl.Transparency = math.min(1, lerp(1, 0.60 + i * 0.1, a))
            end
            glowDot.Transparency = lerp(1, 0.15, a)
        end

        -- ── Get absolute screen position of outerWrap ─────────────────────
        local function getBarPos()
            -- AbsolutePosition gives screen coords in ScreenGui space
            local ap = outerWrap.AbsolutePosition
            local as = outerWrap.AbsoluteSize
            return ap, as
        end

        -- ── Update Drawing positions ──────────────────────────────────────
        local function updateDrawing(dt)
            shimPhase = (shimPhase + dt * 1.2) % (math.pi * 2)
            accentPhase = (accentPhase + dt * 0.6) % (math.pi * 2)

            local ok, ap, as = pcall(getBarPos)
            if not ok then return end

            -- Animated accent bar color (Blue ↔ Blue-Purple pulse)
            local t = (math.sin(accentPhase) + 1) * 0.5
            accentBar.BackgroundColor3 = Color3.fromRGB(
                math.round(lerp(72, 100, t)),
                math.round(lerp(138, 90, t)),
                math.round(lerp(255, 255, t))
            )

            -- Shimmer lines: thin horizontal lines that drift across bar top
            -- They appear just above the bar and fade out
            local barY = ap.Y
            local barX = ap.X
            local barW = as.X

            for i, sl in ipairs(shimLines) do
                local phase = shimPhase + (i - 1) * 2.1
                local t2 = (math.sin(phase) + 1) * 0.5
                local xOff = barW * t2
                local lineLen = barW * 0.25

                sl.From  = Vector2.new(barX + xOff,              barY - 1)
                sl.To    = Vector2.new(barX + xOff + lineLen,    barY - 1)
                sl.Color = Color3.fromRGB(
                    math.round(lerp(72, 180, t2)),
                    math.round(lerp(138, 100, t2)),
                    255
                )
            end

            -- Glow dot: bounces along accent bar bottom
            local dotPhase = shimPhase * 0.5
            local dotX = barX + ((math.sin(dotPhase) + 1) * 0.5) * barW
            glowDot.Position = Vector2.new(dotX, barY + as.Y)
        end

        -- ── Main heartbeat ────────────────────────────────────────────────
        local conn
        conn = RunService.Heartbeat:Connect(function(dt)
            -- Spring toward target alpha
            local speed = targetA > alpha and SPRING_IN or SPRING_OUT
            alpha = lerp(alpha, targetA, math.min(1, dt * speed))
            if math.abs(alpha - targetA) < 0.005 then alpha = targetA end

            applyAlpha(alpha)

            -- Hide ScreenGui when fully faded
            gui.Enabled = alpha > 0.01

            -- Drawing effects (only when visible)
            if alpha > 0.01 then
                updateDrawing(dt)
            end

            -- FPS rolling average
            if fpsLbl then
                fpsBuf[fpsBufI] = dt
                fpsBufI = (fpsBufI % FPS_N) + 1
                fpsTimer += dt
                if fpsTimer >= 0.25 then
                    fpsTimer = 0
                    local sum = 0
                    for i = 1, FPS_N do sum += fpsBuf[i] end
                    local avg = sum / FPS_N
                    fpsLbl.Text = tostring(avg > 0 and math.round(1/avg) or 0)
                end
            end

            -- Time (per-second)
            if timeLbl then
                local now = os.time()
                if now ~= lastSec then
                    lastSec = now
                    timeLbl.Text = string.format("%02d:%02d:%02d",
                        math.floor(now/3600)%24,
                        math.floor(now/60)%60,
                        now%60)
                end
            end
        end)

        -- Initial spring: start at scale 0, fade in
        uiScale.Scale = 0.82
        applyAlpha(0)
        targetA = 1

        -- ── Public API ────────────────────────────────────────────────────
        local WM = {}

        function WM:Show()
            if not visible then
                visible = true
                targetA = 1
            end
        end

        function WM:Hide()
            if visible then
                visible = false
                targetA = 0
            end
        end

        function WM:Toggle()
            if visible then self:Hide() else self:Show() end
        end

        function WM:IsVisible() return visible end

        function WM:SetTitle(text)
            titleText = text
            titleLbl.Text = text
        end

        function WM:SetPosition(pos)
            if typeof(pos) == "UDim2" then
                anchor.Position = pos
            elseif typeof(pos) == "Vector2" then
                anchor.Position = UDim2.fromOffset(pos.X, pos.Y)
            end
        end

        function WM:SetVisible(state)
            if state then self:Show() else self:Hide() end
        end

        function WM:Destroy()
            conn:Disconnect()
            for _, d in ipairs(drawObjs) do pcall(function() d:Remove() end) end
            gui:Destroy()
        end

        return WM
    end

    if ctx.onLoad then ctx.onLoad() end
end
