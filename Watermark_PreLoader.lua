-- Watermark_PreLoader.lua  (v8)
-- Fixes:
-- 1. Particles: blue→violet shifting gradient (phase-driven per-particle hue)
-- 2. Logo: fewer segments (12 instead of 30)
-- 3. FPS/Time text centered properly
-- 4. Particles clamped to chip AbsolutePosition (screen-space correct)
-- 5. Top-right: margin 36px from right edge
-- 6. Top-left: 72px from left (skips Roblox buttons but closer)
-- 7. Particles: Z drift + hue oscillation over time = "alive" feel
-- 8. Drag animation: iOS spring (position lerp) + ghost fade
-- 9. Appear animation: UIScale starts at 1.0 from frame 1; opacity-only fade
--    so no size-pop at end of animation

return function(ctx)
    local MacLib          = ctx.MacLib
    local RunService      = game:GetService("RunService")
    local UIS             = game:GetService("UserInputService")

    local function lerp(a, b, t) return a + (b-a)*t end
    local function rand(a, b)    return a + math.random()*(b-a) end
    local function clamp(v,mn,mx) return math.max(mn, math.min(mx, v)) end

    local function GetGui()
        local g = Instance.new("ScreenGui")
        g.ResetOnSpawn   = false
        g.DisplayOrder   = 9998
        g.IgnoreGuiInset = true
        g.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
        local ok
        if gethui then ok = pcall(function() g.Parent = gethui() end) end
        if not ok or not g.Parent then
            ok = pcall(function() g.Parent = game:GetService("CoreGui") end)
        end
        if not ok or not g.Parent then
            g.Parent = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
        end
        return g
    end

    -- ══════════════════════════════════════════════════════════════════════
    function MacLib:Watermark(cfg)
        cfg = cfg or {}
        local titleText = cfg.Title    or "Watermark"
        local showFPS   = cfg.ShowFPS  ~= false
        local showTime  = cfg.ShowTime ~= false

        -- Default position: top-left, past Roblox buttons
        local initX, initY = 72, 8
        if cfg.Position then
            if typeof(cfg.Position) == "UDim2" then
                initX = cfg.Position.X.Offset; initY = cfg.Position.Y.Offset
            elseif typeof(cfg.Position) == "Vector2" then
                initX = cfg.Position.X; initY = cfg.Position.Y
            end
        end

        -- ── Root GUI ──────────────────────────────────────────────────────
        local gui = GetGui(); gui.Name = "MacLibWatermark"

        -- anchor drives position; NO UIScale on anchor (scale on row instead)
        local anchor = Instance.new("Frame")
        anchor.Name                   = "WmAnchor"
        anchor.Position               = UDim2.fromOffset(initX, initY)
        anchor.AnchorPoint            = Vector2.new(0, 0)
        anchor.BackgroundTransparency = 1
        anchor.BorderSizePixel        = 0
        anchor.AutomaticSize          = Enum.AutomaticSize.XY
        anchor.Parent                 = gui

        -- row: holds all chips, no scale transform (scale only via transparency)
        local row = Instance.new("Frame")
        row.Name                   = "Row"
        row.BackgroundTransparency = 1
        row.BorderSizePixel        = 0
        row.AutomaticSize          = Enum.AutomaticSize.XY
        row.Parent                 = anchor

        local rowList = Instance.new("UIListLayout")
        rowList.FillDirection     = Enum.FillDirection.Horizontal
        rowList.VerticalAlignment = Enum.VerticalAlignment.Center
        rowList.SortOrder         = Enum.SortOrder.LayoutOrder
        rowList.Padding           = UDim.new(0, 5)
        rowList.Parent            = row

        -- ── Design tokens ─────────────────────────────────────────────────
        local BAR_H   = 26
        local LOGO_SZ = 30
        local SEG_SZ  = 18
        local TXT_SZ  = 12
        local ICON_SZ = 13
        local PAD_X   = 10

        local FONT_TITLE = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.SemiBold)
        local FONT_BODY  = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Medium)

        local COL_BG_DARK  = Color3.fromRGB(12, 12, 19)
        local COL_BG_CHIP  = Color3.fromRGB(10, 10, 16)
        local COL_STROKE   = Color3.fromRGB(42, 42, 62)
        local COL_TXT_MAIN = Color3.fromRGB(215, 215, 230)
        local COL_TXT_MUTE = Color3.fromRGB(130, 130, 155)
        local BG_TRANSP    = 0.28
        local SEG_COUNT    = 12

        -- ── Chip factory ──────────────────────────────────────────────────
        local chipOrder = 0
        local allChips  = {}

        local function makeChip(opts)
            chipOrder += 1; opts = opts or {}
            local h = opts.h or BAR_H

            local f = Instance.new("Frame")
            f.Name                   = "Chip"..chipOrder
            f.BackgroundColor3       = opts.bg or COL_BG_CHIP
            f.BackgroundTransparency = 1   -- start invisible, fade in
            f.BorderSizePixel        = 0
            f.LayoutOrder            = chipOrder
            f.ClipsDescendants       = true

            if opts.fixedW then
                f.AutomaticSize = Enum.AutomaticSize.None
                f.Size          = UDim2.fromOffset(opts.fixedW, h)
            else
                f.AutomaticSize = Enum.AutomaticSize.X
                f.Size          = UDim2.fromOffset(0, h)
            end
            f.Parent = row

            local corner = Instance.new("UICorner")
            corner.CornerRadius = UDim.new(0, opts.radius or 7)
            corner.Parent = f

            local stroke = nil
            if opts.stroke then
                stroke = Instance.new("UIStroke")
                stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
                stroke.Color           = COL_STROKE
                stroke.Transparency    = 1   -- start invisible
                stroke.Thickness       = 1
                stroke.Parent          = f
            end

            if opts.padX ~= false then
                local pad = Instance.new("UIPadding")
                pad.PaddingLeft  = UDim.new(0, opts.padX or PAD_X)
                pad.PaddingRight = UDim.new(0, opts.padX or PAD_X)
                pad.Parent = f
            end

            local entry = { frame=f, stroke=stroke, labels={}, images={}, bg=opts.bg or COL_BG_CHIP }
            table.insert(allChips, entry)
            return entry
        end

        -- ── LOGO chip ─────────────────────────────────────────────────────
        local logoEntry = makeChip({
            bg     = COL_BG_DARK,
            fixedW = LOGO_SZ,
            h      = LOGO_SZ,
            radius = 8,
            stroke = false,
            padX   = false,
        })

        local logoHolder = Instance.new("Frame")
        logoHolder.Name                   = "LogoHolder"
        logoHolder.AnchorPoint            = Vector2.new(0.5, 0.5)
        logoHolder.Position               = UDim2.new(0.5, 0, 0.5, 0)
        logoHolder.Size                   = UDim2.fromOffset(SEG_SZ, SEG_SZ)
        logoHolder.BackgroundTransparency = 1
        logoHolder.BorderSizePixel        = 0
        logoHolder.Parent                 = logoEntry.frame

        local logoSegs = {}
        for i = 1, SEG_COUNT do
            local seg = Instance.new("ImageLabel")
            seg.Size                   = UDim2.new(1,0,1,0)
            seg.BackgroundTransparency = 1
            seg.Image                  = "rbxassetid://7151778302"
            seg.ImageTransparency      = 1
            seg.Rotation               = (i-1)*(360/SEG_COUNT)
            seg.ZIndex                 = 3
            seg.Parent                 = logoHolder
            Instance.new("UICorner", seg).CornerRadius = UDim.new(0.5, 0)
            local grad = Instance.new("UIGradient")
            local h1   = 0.60 + (i-1)/SEG_COUNT * 0.15
            grad.Color    = ColorSequence.new(
                Color3.fromHSV(h1 % 1, 0.80, 1),
                Color3.fromHSV((h1+0.08) % 1, 0.75, 1)
            )
            grad.Rotation = (i-1)*(360/SEG_COUNT)
            grad.Parent   = seg
            table.insert(logoSegs, seg)
        end

        -- ── TITLE chip ────────────────────────────────────────────────────
        local titleEntry = makeChip({ bg = COL_BG_DARK, stroke = true })

        local titleLbl = Instance.new("TextLabel")
        titleLbl.FontFace               = FONT_TITLE
        titleLbl.TextSize               = TXT_SZ
        titleLbl.TextColor3             = COL_TXT_MAIN
        titleLbl.TextTransparency       = 1
        titleLbl.BackgroundTransparency = 1
        titleLbl.BorderSizePixel        = 0
        titleLbl.AutomaticSize          = Enum.AutomaticSize.X
        titleLbl.Size                   = UDim2.fromOffset(0, BAR_H)
        titleLbl.TextXAlignment         = Enum.TextXAlignment.Left
        titleLbl.Text                   = titleText
        titleLbl.ZIndex                 = 3
        titleLbl.Parent                 = titleEntry.frame
        table.insert(titleEntry.labels, titleLbl)

        -- Accent line — child of titleEntry.frame, positioned after padding
        local accentLine = Instance.new("Frame")
        accentLine.Name                   = "AccentLine"
        accentLine.BackgroundColor3       = Color3.fromRGB(72,138,255)
        accentLine.BackgroundTransparency = 1
        accentLine.BorderSizePixel        = 0
        accentLine.ZIndex                 = 5
        accentLine.Size                   = UDim2.fromOffset(40, 2)
        accentLine.Position               = UDim2.fromOffset(0, BAR_H - 3)
        accentLine.Parent                 = titleEntry.frame
        do
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, 1)
            c.Parent = accentLine
        end

        -- ── FPS chip ──────────────────────────────────────────────────────
        local fpsEntry, fpsIcon, fpsLbl
        if showFPS then
            fpsEntry = makeChip({ fixedW = 72, stroke = true })

            fpsIcon = Instance.new("ImageLabel")
            fpsIcon.Image                  = "rbxassetid://102994395432803"
            fpsIcon.Size                   = UDim2.fromOffset(ICON_SZ, ICON_SZ)
            fpsIcon.AnchorPoint            = Vector2.new(0, 0.5)
            fpsIcon.Position               = UDim2.new(0, 0, 0.5, 0)
            fpsIcon.BackgroundTransparency = 1
            fpsIcon.ImageTransparency      = 1
            fpsIcon.BorderSizePixel        = 0
            fpsIcon.ZIndex                 = 3
            fpsIcon.Parent                 = fpsEntry.frame
            table.insert(fpsEntry.images, fpsIcon)

            fpsLbl = Instance.new("TextLabel")
            fpsLbl.FontFace               = FONT_BODY
            fpsLbl.TextSize               = TXT_SZ
            fpsLbl.TextColor3             = COL_TXT_MUTE
            fpsLbl.TextTransparency       = 1
            fpsLbl.BackgroundTransparency = 1
            fpsLbl.BorderSizePixel        = 0
            -- Center remaining space after icon+gap
            fpsLbl.AnchorPoint            = Vector2.new(0, 0.5)
            fpsLbl.Position               = UDim2.fromOffset(ICON_SZ+4, 0)
            fpsLbl.Size                   = UDim2.new(1, -(ICON_SZ+4), 0, TXT_SZ+2)
            fpsLbl.TextXAlignment         = Enum.TextXAlignment.Center
            fpsLbl.Text                   = "--"
            fpsLbl.ZIndex                 = 3
            fpsLbl.Parent                 = fpsEntry.frame
            table.insert(fpsEntry.labels, fpsLbl)

            -- anchor icon at center-left of chip
            local iconPad = Instance.new("Frame")
            iconPad.BackgroundTransparency = 1
            iconPad.BorderSizePixel        = 0
            iconPad.Size                   = UDim2.new(0, ICON_SZ, 1, 0)
            iconPad.Position               = UDim2.new(0, 0, 0, 0)
            iconPad.ZIndex                 = 2
            iconPad.Parent                 = fpsEntry.frame
            fpsIcon.Parent = iconPad
            fpsIcon.Position = UDim2.new(0, 0, 0.5, -ICON_SZ/2)
            fpsIcon.AnchorPoint = Vector2.new(0, 0)
        end

        -- ── TIME chip ─────────────────────────────────────────────────────
        local timeEntry, timeIcon, timeLbl
        if showTime then
            timeEntry = makeChip({ fixedW = 90, stroke = true })

            timeIcon = Instance.new("ImageLabel")
            timeIcon.Image                  = "rbxassetid://17824308575"
            timeIcon.Size                   = UDim2.fromOffset(ICON_SZ, ICON_SZ)
            timeIcon.BackgroundTransparency = 1
            timeIcon.ImageTransparency      = 1
            timeIcon.BorderSizePixel        = 0
            timeIcon.ZIndex                 = 3
            timeIcon.Parent                 = timeEntry.frame
            table.insert(timeEntry.images, timeIcon)

            timeLbl = Instance.new("TextLabel")
            timeLbl.FontFace               = FONT_BODY
            timeLbl.TextSize               = TXT_SZ
            timeLbl.TextColor3             = COL_TXT_MUTE
            timeLbl.TextTransparency       = 1
            timeLbl.BackgroundTransparency = 1
            timeLbl.BorderSizePixel        = 0
            timeLbl.AnchorPoint            = Vector2.new(0, 0.5)
            timeLbl.Position               = UDim2.fromOffset(ICON_SZ+4, 0)
            timeLbl.Size                   = UDim2.new(1, -(ICON_SZ+4), 0, TXT_SZ+2)
            timeLbl.TextXAlignment         = Enum.TextXAlignment.Center
            timeLbl.Text                   = "00:00"
            timeLbl.ZIndex                 = 3
            timeLbl.Parent                 = timeEntry.frame
            table.insert(timeEntry.labels, timeLbl)

            local iconPad2 = Instance.new("Frame")
            iconPad2.BackgroundTransparency = 1
            iconPad2.BorderSizePixel        = 0
            iconPad2.Size                   = UDim2.new(0, ICON_SZ, 1, 0)
            iconPad2.Position               = UDim2.new(0, 0, 0, 0)
            iconPad2.ZIndex                 = 2
            iconPad2.Parent                 = timeEntry.frame
            timeIcon.Parent = iconPad2
            timeIcon.Position = UDim2.new(0, 0, 0.5, -ICON_SZ/2)
            timeIcon.AnchorPoint = Vector2.new(0, 0)
        end

        -- ════════════════════════════════════════════════════════════════════
        -- DRAWING PARTICLES
        -- Drawing API: Transparency 0=invisible, 1=opaque  (+) Visible=true required
        --
        -- 1. Gradient: blue→violet, per-particle hue phase shifts over time
        -- 2. Pseudo-3D via Z: near=large+bright+fast, far=small+dim+slow
        -- 3. Z drift: Z slowly wanders so particles "breathe" in depth
        -- 4. Particles strictly clamped to chip screen rect
        -- ════════════════════════════════════════════════════════════════════

        local drawObjs = {}
        local function D(t)
            local d = Drawing.new(t)
            d.Visible      = true
            d.Transparency = 0
            table.insert(drawObjs, d)
            return d
        end

        local P_COUNT      = 9
        local CONNECT_DIST = 52
        local SPEED_NEAR   = 20
        local SPEED_FAR    = 6
        local R_NEAR       = 2.0
        local R_FAR        = 0.7
        local Z_DRIFT_SPD  = 0.08   -- how fast Z wanders

        -- Hue range: ~0.60 (blue) → ~0.78 (violet)
        local HUE_MIN = 0.60
        local HUE_MAX = 0.78

        local function buildSys(n)
            local pts = {}
            for i = 1, n do
                local p = {
                    x=0, y=0, vx=0, vy=0,
                    z      = rand(0, 1),
                    zdv    = rand(-1, 1),   -- Z drift velocity direction
                    hueOff = rand(0, 1),    -- per-particle hue offset
                    huePh  = rand(0, math.pi*2),
                    dot    = D("Circle"),
                }
                p.dot.Filled       = true
                p.dot.Color        = Color3.fromHSV(HUE_MIN, 0.80, 1)
                p.dot.Radius       = 1
                p.dot.Transparency = 0
                p.dot.NumSides     = 16
                p.dot.ZIndex       = 9
                table.insert(pts, p)
            end

            local lines = {}
            for i = 1, n do
                lines[i] = {}
                for j = i+1, n do
                    local l = D("Line")
                    l.Thickness    = 0.8
                    l.Color        = Color3.fromHSV(HUE_MIN, 0.80, 1)
                    l.Transparency = 0
                    l.ZIndex       = 8
                    lines[i][j] = l
                end
            end
            return { pts=pts, lines=lines, ready=false, ax=0, ay=0, aw=0, ah=0 }
        end

        local entryToSys = {}
        entryToSys[titleEntry] = buildSys(P_COUNT)
        if fpsEntry  then entryToSys[fpsEntry]  = buildSys(P_COUNT) end
        if timeEntry then entryToSys[timeEntry] = buildSys(P_COUNT) end

        local function initSys(sys, ax, ay, aw, ah)
            sys.ax = ax; sys.ay = ay; sys.aw = aw; sys.ah = ah
            for _, p in ipairs(sys.pts) do
                p.x = rand(ax+4, ax+aw-4)
                p.y = rand(ay+4, ay+ah-4)
                local spd   = lerp(SPEED_FAR, SPEED_NEAR, p.z)
                local angle = rand(0, math.pi*2)
                p.vx = math.cos(angle)*spd
                p.vy = math.sin(angle)*spd
            end
            sys.ready = true
        end

        local globalTime = 0

        local function tickSys(sys, dt, ax, ay, aw, ah, globalA)
            -- Re-init if position changed significantly (drag moved watermark)
            if not sys.ready or math.abs(sys.ax - ax) > 2 or math.abs(sys.ay - ay) > 2 then
                if aw > 4 then initSys(sys, ax, ay, aw, ah) end
                return
            end

            local pts = sys.pts
            for _, p in ipairs(pts) do
                -- Z drift: wanders slowly between 0 and 1
                p.z = p.z + p.zdv * Z_DRIFT_SPD * dt
                if p.z > 1 then p.z = 1; p.zdv = -math.abs(p.zdv) end
                if p.z < 0 then p.z = 0; p.zdv =  math.abs(p.zdv) end

                -- Hue oscillation: blue ↔ violet
                p.huePh = p.huePh + dt * (0.4 + p.hueOff * 0.3)
                local hue = HUE_MIN + (math.sin(p.huePh) * 0.5 + 0.5) * (HUE_MAX - HUE_MIN)

                -- Move
                p.x += p.vx * dt
                p.y += p.vy * dt

                -- Bounce strictly within chip bounds
                local m = 2
                if p.x < ax+m    then p.x=ax+m;    p.vx= math.abs(p.vx) end
                if p.x > ax+aw-m then p.x=ax+aw-m; p.vx=-math.abs(p.vx) end
                if p.y < ay+m    then p.y=ay+m;    p.vy= math.abs(p.vy) end
                if p.y > ay+ah-m then p.y=ay+ah-m; p.vy=-math.abs(p.vy) end

                -- Render dot
                local r     = lerp(R_FAR, R_NEAR, p.z)
                local dotOp = lerp(0.18, 0.65, p.z) * globalA

                p.dot.Position     = Vector2.new(p.x, p.y)
                p.dot.Radius       = r
                p.dot.Transparency = dotOp
                p.dot.Color        = Color3.fromHSV(hue, lerp(0.65, 0.90, p.z), 1)
            end

            -- Lines
            for i = 1, #pts do
                for j = i+1, #pts do
                    local pi, pj = pts[i], pts[j]
                    local dx = pi.x-pj.x; local dy = pi.y-pj.y
                    local dist = math.sqrt(dx*dx+dy*dy)
                    local l = sys.lines[i][j]

                    if dist < CONNECT_DIST then
                        local prox = 1 - dist/CONNECT_DIST
                        local avgZ = (pi.z+pj.z)*0.5
                        local avgHue = HUE_MIN + (math.sin((pi.huePh+pj.huePh)*0.5)*0.5+0.5)*(HUE_MAX-HUE_MIN)
                        local lineOp = lerp(0.05, 0.38, prox) * lerp(0.4, 1, avgZ) * globalA

                        l.From         = Vector2.new(pi.x, pi.y)
                        l.To           = Vector2.new(pj.x, pj.y)
                        l.Transparency = lineOp
                        l.Thickness    = lerp(0.4, 1.0, avgZ)
                        l.Color        = Color3.fromHSV(avgHue, lerp(0.55, 0.85, avgZ), 1)
                    else
                        l.Transparency = 0
                    end
                end
            end
        end

        -- ════════════════════════════════════════════════════════════════════
        -- DRAG (iOS spring: position lerp + ghost echo)
        -- ════════════════════════════════════════════════════════════════════
        local isDragging  = false
        local dragOffsetX = 0
        local dragOffsetY = 0
        local targetPosX  = initX
        local targetPosY  = initY
        local curPosX     = initX
        local curPosY     = initY
        local DRAG_SPRING = 18   -- spring stiffness when following mouse
        local RELEASE_SPRING = 10 -- spring stiffness on release (slower, bouncy)

        -- Ghost: a faded echo that trails behind (iOS "lift" feel)
        local ghost = Instance.new("Frame")
        ghost.Name                   = "Ghost"
        ghost.BackgroundColor3       = Color3.fromRGB(72,138,255)
        ghost.BackgroundTransparency = 1
        ghost.BorderSizePixel        = 0
        ghost.ZIndex                 = 1
        ghost.AutomaticSize          = Enum.AutomaticSize.XY
        ghost.Parent                 = gui
        do
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, 8)
            c.Parent = ghost
        end
        local ghostTargetT = 1
        local ghostT       = 1

        -- Detect drag on anchor
        anchor.InputBegan:Connect(function(inp)
            if inp.UserInputType == Enum.UserInputType.MouseButton1
            or inp.UserInputType == Enum.UserInputType.Touch then
                isDragging  = true
                local ap    = anchor.AbsolutePosition
                dragOffsetX = inp.Position.X - ap.X
                dragOffsetY = inp.Position.Y - ap.Y
                ghostTargetT = 0.70   -- ghost appears
            end
        end)

        UIS.InputChanged:Connect(function(inp)
            if isDragging and (inp.UserInputType == Enum.UserInputType.MouseMovement
                or inp.UserInputType == Enum.UserInputType.Touch) then
                targetPosX = inp.Position.X - dragOffsetX
                targetPosY = inp.Position.Y - dragOffsetY
            end
        end)

        UIS.InputEnded:Connect(function(inp)
            if inp.UserInputType == Enum.UserInputType.MouseButton1
            or inp.UserInputType == Enum.UserInputType.Touch then
                if isDragging then
                    isDragging   = false
                    ghostTargetT = 1   -- ghost fades
                end
            end
        end)

        -- ════════════════════════════════════════════════════════════════════
        -- FADE animation — opacity only, NO scale change (avoids size-pop)
        -- UIScale stays at 1.0 the whole time.
        -- ════════════════════════════════════════════════════════════════════
        local visible  = true
        local alpha    = 0    -- 0=hidden, 1=visible
        local targetA  = 1

        local FPS_N   = 30
        local fpsBuf  = table.create(FPS_N, 1/60)
        local fpsBufI = 1; local fpsTimer = 0
        local lastMin = -1
        local logoAngle = 0
        local accentPh  = 0

        -- Apply GUI transparency from alpha (Roblox GUI: 0=opaque, 1=transparent)
        local function applyAlpha(a)
            local bgT  = lerp(1, BG_TRANSP, a)
            local txtT = lerp(1, 0, a)

            for _, e in ipairs(allChips) do
                e.frame.BackgroundTransparency = bgT
                if e.stroke then e.stroke.Transparency = lerp(1, 0, a) end
                for _, lbl in ipairs(e.labels) do lbl.TextTransparency  = txtT end
                for _, img in ipairs(e.images) do img.ImageTransparency = txtT end
            end

            for _, seg in ipairs(logoSegs) do
                seg.ImageTransparency = lerp(1, 0.38, a)
            end

            accentLine.BackgroundTransparency = lerp(1, 0, a)

            -- Ghost sync
            ghost.BackgroundTransparency = ghostT
            ghost.Size = row.Size
            ghost.Position = UDim2.fromOffset(curPosX, curPosY)
        end

        -- ── Heartbeat ─────────────────────────────────────────────────────
        local conn
        conn = RunService.Heartbeat:Connect(function(dt)
            globalTime += dt

            -- Alpha spring (opacity only, no scale)
            local spd = targetA > alpha and 14 or 22
            alpha = lerp(alpha, targetA, clamp(dt*spd, 0, 1))
            if math.abs(alpha - targetA) < 0.003 then alpha = targetA end

            gui.Enabled = alpha > 0.005

            -- Drag spring
            local dsp = isDragging and DRAG_SPRING or RELEASE_SPRING
            curPosX = lerp(curPosX, targetPosX, clamp(dt*dsp, 0, 1))
            curPosY = lerp(curPosY, targetPosY, clamp(dt*dsp, 0, 1))
            anchor.Position = UDim2.fromOffset(math.round(curPosX), math.round(curPosY))

            -- Ghost transparency
            ghostT = lerp(ghostT, ghostTargetT, clamp(dt*10, 0, 1))

            applyAlpha(alpha)

            -- Logo rotation
            logoAngle = (logoAngle + dt*18) % 360
            for i, seg in ipairs(logoSegs) do
                seg.Rotation = (i-1)*(360/SEG_COUNT) + logoAngle
            end

            -- Accent line: match text width
            accentPh = (accentPh + dt*0.9) % (math.pi*2)
            local t = (math.sin(accentPh)+1)*0.5
            accentLine.BackgroundColor3 = Color3.fromRGB(
                math.round(lerp(72,110,t)),
                math.round(lerp(138,80,t)),
                255
            )
            local ts = titleLbl.AbsoluteSize
            if ts.X > 0 then
                accentLine.Size     = UDim2.fromOffset(ts.X, 2)
                accentLine.Position = UDim2.fromOffset(0, BAR_H - 3)
            end

            -- Particles
            if alpha > 0.03 then
                for entry, sys in pairs(entryToSys) do
                    local f  = entry.frame
                    local ap = f.AbsolutePosition
                    local as = f.AbsoluteSize
                    -- Use raw AbsolutePosition (screen-space), particles stay inside chip
                    tickSys(sys, dt, ap.X, ap.Y, as.X, as.Y, alpha)
                end
            else
                for _, d in ipairs(drawObjs) do d.Transparency = 0 end
            end

            -- FPS
            if fpsLbl then
                fpsBuf[fpsBufI] = dt; fpsBufI = (fpsBufI % FPS_N)+1
                fpsTimer += dt
                if fpsTimer >= 0.25 then
                    fpsTimer = 0
                    local sum = 0
                    for i=1,FPS_N do sum+=fpsBuf[i] end
                    fpsLbl.Text = tostring(sum>0 and math.round(FPS_N/sum) or 0)
                end
            end

            -- Time
            if timeLbl then
                local now    = os.time()
                local curMin = math.floor(now/60)
                if curMin ~= lastMin then
                    lastMin = curMin
                    timeLbl.Text = string.format("%02d:%02d",
                        math.floor(now/3600)%24, curMin%60)
                end
            end
        end)

        -- Init at alpha=0, then fade to 1
        applyAlpha(0)
        targetA = 1
        targetPosX = initX; targetPosY = initY
        curPosX    = initX; curPosY    = initY

        -- ── Top-right helper ──────────────────────────────────────────────
        local function setTopRight()
            task.defer(function()
                local vp = workspace.CurrentCamera.ViewportSize
                local rw = row.AbsoluteSize.X
                local margin = 36
                local nx = vp.X - rw - margin
                targetPosX = nx; targetPosY = 8
            end)
        end

        -- ── Public API ────────────────────────────────────────────────────
        local WM = {}
        function WM:Show()  if not visible then visible=true;  targetA=1 end end
        function WM:Hide()  if visible     then visible=false; targetA=0 end end
        function WM:Toggle() if visible then self:Hide() else self:Show() end end
        function WM:IsVisible() return visible end
        function WM:SetTitle(txt) titleText=txt; titleLbl.Text=txt end
        function WM:SetPosition(pos)
            if typeof(pos)=="UDim2" then
                targetPosX=pos.X.Offset; targetPosY=pos.Y.Offset
            elseif typeof(pos)=="Vector2" then
                targetPosX=pos.X; targetPosY=pos.Y
            end
        end
        function WM:MoveTopRight() setTopRight() end
        function WM:MoveTopLeft()
            targetPosX = 72; targetPosY = 8
        end
        function WM:SetVisible(state) if state then self:Show() else self:Hide() end end
        function WM:Destroy()
            conn:Disconnect()
            for _, d in ipairs(drawObjs) do pcall(function() d:Remove() end) end
            gui:Destroy()
        end

        return WM
    end

    if ctx.onLoad then ctx.onLoad() end
end
