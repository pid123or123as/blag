-- Watermark_PreLoader.lua  (v6)
-- Layout (left→right, gap=5px):
--   [Logo circle, slightly taller]  [Syllinse Project chip]  [FPS chip]  [Time chip]
-- Drawing: particles.js-style constellation (dots + connecting lines, confined per chip)
--   + pseudo-3D depth via size/opacity based on Z coordinate
-- ScreenGui: all actual UI (chips, text, icons, stroke, accentBar)

return function(ctx)
    local MacLib     = ctx.MacLib
    local RunService = game:GetService("RunService")

    local function lerp(a, b, t) return a + (b - a) * t end
    local function rand(a, b)    return a + math.random() * (b - a) end

    -- ──────────────────────────────────────────────────────────────────────
    -- GUI parent helper
    -- ──────────────────────────────────────────────────────────────────────
    local function GetGui()
        local g = Instance.new("ScreenGui")
        g.ResetOnSpawn    = false
        g.DisplayOrder    = 9998
        g.IgnoreGuiInset  = true
        g.ZIndexBehavior  = Enum.ZIndexBehavior.Sibling
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
        local titleText = cfg.Title   or "Watermark"
        local showFPS   = cfg.ShowFPS  ~= false
        local showTime  = cfg.ShowTime ~= false

        local initX, initY = 22, 22
        if cfg.Position then
            if typeof(cfg.Position) == "UDim2" then
                initX = cfg.Position.X.Offset
                initY = cfg.Position.Y.Offset
            elseif typeof(cfg.Position) == "Vector2" then
                initX = cfg.Position.X; initY = cfg.Position.Y
            end
        end

        -- ── Root GUI ──────────────────────────────────────────────────────
        local gui = GetGui(); gui.Name = "MacLibWatermark"

        local anchor = Instance.new("Frame")
        anchor.Name                   = "WmAnchor"
        anchor.Position               = UDim2.fromOffset(initX, initY)
        anchor.AnchorPoint            = Vector2.new(0, 0)
        anchor.BackgroundTransparency = 1
        anchor.BorderSizePixel        = 0
        anchor.AutomaticSize          = Enum.AutomaticSize.XY
        anchor.Parent                 = gui

        local uiScale        = Instance.new("UIScale")
        uiScale.Scale        = 0.85
        uiScale.Parent       = anchor

        -- Row holding all chips
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
        local BAR_H      = 26          -- base chip height (reduced)
        local LOGO_SZ    = 30          -- logo circle (slightly taller than chips)
        local TXT_SZ     = 12
        local ICON_SZ    = 13
        local PAD_X      = 10

        local FONT_TITLE = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.SemiBold)
        local FONT_BODY  = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Medium)

        local COL_BG_DARK  = Color3.fromRGB(12, 12, 19)
        local COL_BG_CHIP  = Color3.fromRGB(10, 10, 16)
        local COL_ACCENT   = Color3.fromRGB(72, 138, 255)
        local COL_STROKE   = Color3.fromRGB(42, 42, 62)
        local COL_TXT_MAIN = Color3.fromRGB(215, 215, 230)
        local COL_TXT_MUTE = Color3.fromRGB(130, 130, 155)
        local BG_TRANSP    = 0.28

        -- ── Chip factory ──────────────────────────────────────────────────
        local chipOrder = 0
        local allChips  = {}  -- {frame, labels, images, stroke}

        local function makeChip(opts)
            chipOrder += 1; opts = opts or {}

            local f = Instance.new("Frame")
            f.Name                   = "Chip"..chipOrder
            f.BackgroundColor3       = opts.bg or COL_BG_CHIP
            f.BackgroundTransparency = BG_TRANSP
            f.BorderSizePixel        = 0
            f.LayoutOrder            = chipOrder
            f.ClipsDescendants       = true
            if opts.fixedW then
                f.AutomaticSize = Enum.AutomaticSize.None
                f.Size          = UDim2.fromOffset(opts.fixedW, opts.h or BAR_H)
            else
                f.AutomaticSize = Enum.AutomaticSize.X
                f.Size          = UDim2.fromOffset(0, opts.h or BAR_H)
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
                stroke.Transparency    = 0
                stroke.Thickness       = 1
                stroke.Parent          = f
            end

            local pad = Instance.new("UIPadding")
            pad.PaddingLeft  = UDim.new(0, opts.padX or PAD_X)
            pad.PaddingRight = UDim.new(0, opts.padX or PAD_X)
            pad.Parent       = f

            local entry = { frame=f, stroke=stroke, labels={}, images={} }
            table.insert(allChips, entry)
            return entry
        end

        -- ── LOGO chip (full circle, slightly taller) ──────────────────────
        local logoEntry = makeChip({
            bg     = COL_BG_DARK,
            fixedW = LOGO_SZ,
            h      = LOGO_SZ,
            radius = LOGO_SZ,
            stroke = false,
            padX   = 0,
        })
        -- remove padding so segments fill the circle fully
        for _, c in ipairs(logoEntry.frame:GetChildren()) do
            if c:IsA("UIPadding") then c:Destroy() end
        end

        -- 30 segments — no center content, pure rotating ring segments
        local SEG_COUNT   = 30
        local logoSegs    = {}
        -- Inner mask: white circle to cut out the center and make it look like a ring
        local innerMask = Instance.new("Frame")
        innerMask.Name                   = "InnerMask"
        innerMask.AnchorPoint            = Vector2.new(0.5, 0.5)
        innerMask.Position               = UDim2.new(0.5, 0, 0.5, 0)
        innerMask.Size                   = UDim2.fromOffset(LOGO_SZ * 0.46, LOGO_SZ * 0.46)
        innerMask.BackgroundColor3       = COL_BG_DARK
        innerMask.BackgroundTransparency = 0
        innerMask.BorderSizePixel        = 0
        innerMask.ZIndex                 = 5
        innerMask.Parent                 = logoEntry.frame
        local innerCorner = Instance.new("UICorner")
        innerCorner.CornerRadius = UDim.new(0.5, 0)
        innerCorner.Parent       = innerMask

        for i = 1, SEG_COUNT do
            local seg = Instance.new("ImageLabel")
            seg.Size                   = UDim2.new(1, 0, 1, 0)
            seg.BackgroundTransparency = 1
            seg.Image                  = "rbxassetid://7151778302"
            seg.ImageTransparency      = 0.45
            seg.Rotation               = (i - 1) * (360 / SEG_COUNT)
            seg.ZIndex                 = 2
            seg.Parent                 = logoEntry.frame
            Instance.new("UICorner", seg).CornerRadius = UDim.new(0.5, 0)

            local grad = Instance.new("UIGradient")
            local h1   = 0.60 + (i-1)/SEG_COUNT * 0.10
            local h2   = 0.70 + (i)/SEG_COUNT   * 0.08
            grad.Color    = ColorSequence.new(
                Color3.fromHSV(h1, 0.85, 1),
                Color3.fromHSV(h2, 0.80, 1)
            )
            grad.Rotation = (i-1) * (360/SEG_COUNT)
            grad.Parent   = seg
            table.insert(logoSegs, {seg=seg, grad=grad})
        end

        -- ── TITLE chip ────────────────────────────────────────────────────
        local titleEntry = makeChip({ bg = COL_BG_DARK, stroke = true })

        local titleLbl = Instance.new("TextLabel")
        titleLbl.FontFace               = FONT_TITLE
        titleLbl.TextSize               = TXT_SZ
        titleLbl.TextColor3             = COL_TXT_MAIN
        titleLbl.BackgroundTransparency = 1
        titleLbl.BorderSizePixel        = 0
        titleLbl.AutomaticSize          = Enum.AutomaticSize.X
        titleLbl.Size                   = UDim2.fromOffset(0, BAR_H)
        titleLbl.TextXAlignment         = Enum.TextXAlignment.Left
        titleLbl.Text                   = titleText
        titleLbl.ZIndex                 = 3
        titleLbl.Parent                 = titleEntry.frame
        table.insert(titleEntry.labels, titleLbl)

        -- Accent underline: sits UNDER the text, matches text width exactly
        -- We use a Frame sized to the text and positioned at text bottom
        local accentLine = Instance.new("Frame")
        accentLine.Name                  = "AccentLine"
        accentLine.AnchorPoint           = Vector2.new(0, 1)
        accentLine.BackgroundColor3      = COL_ACCENT
        accentLine.BackgroundTransparency= 0
        accentLine.BorderSizePixel       = 0
        accentLine.ZIndex                = 4
        -- will be resized/repositioned each frame to match titleLbl
        accentLine.Size                  = UDim2.fromOffset(60, 1)
        accentLine.Position              = UDim2.new(0, 0, 1, -3)
        accentLine.Parent                = titleEntry.frame

        -- ── FPS chip ──────────────────────────────────────────────────────
        local fpsEntry, fpsIcon, fpsLbl
        if showFPS then
            fpsEntry = makeChip({ fixedW = 70, stroke = true })

            fpsIcon = Instance.new("ImageLabel")
            fpsIcon.Image                  = "rbxassetid://102994395432803"
            fpsIcon.Size                   = UDim2.fromOffset(ICON_SZ, ICON_SZ)
            fpsIcon.AnchorPoint            = Vector2.new(0, 0.5)
            fpsIcon.Position               = UDim2.new(0, 0, 0.5, 0)
            fpsIcon.BackgroundTransparency = 1
            fpsIcon.BorderSizePixel        = 0
            fpsIcon.ZIndex                 = 3
            fpsIcon.Parent                 = fpsEntry.frame
            table.insert(fpsEntry.images, fpsIcon)

            fpsLbl = Instance.new("TextLabel")
            fpsLbl.FontFace               = FONT_BODY
            fpsLbl.TextSize               = TXT_SZ
            fpsLbl.TextColor3             = COL_TXT_MUTE
            fpsLbl.BackgroundTransparency = 1
            fpsLbl.BorderSizePixel        = 0
            fpsLbl.Size                   = UDim2.new(1, -(ICON_SZ+5), 1, 0)
            fpsLbl.Position               = UDim2.fromOffset(ICON_SZ+5, 0)
            fpsLbl.TextXAlignment         = Enum.TextXAlignment.Center
            fpsLbl.Text                   = "--"
            fpsLbl.ZIndex                 = 3
            fpsLbl.Parent                 = fpsEntry.frame
            table.insert(fpsEntry.labels, fpsLbl)
        end

        -- ── TIME chip ─────────────────────────────────────────────────────
        local timeEntry, timeIcon, timeLbl
        if showTime then
            timeEntry = makeChip({ fixedW = 88, stroke = true })

            timeIcon = Instance.new("ImageLabel")
            timeIcon.Image                  = "rbxassetid://17824308575"
            timeIcon.Size                   = UDim2.fromOffset(ICON_SZ, ICON_SZ)
            timeIcon.AnchorPoint            = Vector2.new(0, 0.5)
            timeIcon.Position               = UDim2.new(0, 0, 0.5, 0)
            timeIcon.BackgroundTransparency = 1
            timeIcon.BorderSizePixel        = 0
            timeIcon.ZIndex                 = 3
            timeIcon.Parent                 = timeEntry.frame
            table.insert(timeEntry.images, timeIcon)

            timeLbl = Instance.new("TextLabel")
            timeLbl.FontFace               = FONT_BODY
            timeLbl.TextSize               = TXT_SZ
            timeLbl.TextColor3             = COL_TXT_MUTE
            timeLbl.BackgroundTransparency = 1
            timeLbl.BorderSizePixel        = 0
            timeLbl.Size                   = UDim2.new(1, -(ICON_SZ+5), 1, 0)
            timeLbl.Position               = UDim2.fromOffset(ICON_SZ+5, 0)
            timeLbl.TextXAlignment         = Enum.TextXAlignment.Center
            timeLbl.Text                   = "00:00"
            timeLbl.ZIndex                 = 3
            timeLbl.Parent                 = timeEntry.frame
            table.insert(timeEntry.labels, timeLbl)
        end

        -- ════════════════════════════════════════════════════════════════════
        -- DRAWING PARTICLE SYSTEM  (particles.js style)
        -- Each chip gets its own isolated particle field.
        -- Pseudo-3D: each particle has a Z coord [0..1].
        --   Z≈0 = far (small, dim, slow)  Z≈1 = near (large, bright, fast)
        -- Dots:  Drawing.new("Circle")
        -- Lines: Drawing.new("Line")   — drawn when distance < CONNECT_DIST
        -- ════════════════════════════════════════════════════════════════════

        local drawObjs = {}
        local function D(t)
            local d = Drawing.new(t)
            table.insert(drawObjs, d)
            return d
        end

        -- Tuning
        local P_PER_CHIP    = 10     -- particles per chip
        local CONNECT_DIST  = 60     -- px: max link distance
        local SPEED_BASE    = 20     -- px/s at Z=1
        local SPEED_MIN     = 6      -- px/s at Z=0
        local R_NEAR        = 2.2    -- dot radius at Z=1
        local R_FAR         = 0.8    -- dot radius at Z=0
        local TRANSP_NEAR   = 0.40   -- dot transparency at Z=1 (smaller = more opaque)
        local TRANSP_FAR    = 0.78   -- dot transparency at Z=0
        local LINE_BASE_T   = 0.55   -- line transparency at closest
        local LINE_FAR_T    = 0.92   -- line transparency at CONNECT_DIST

        -- Per-chip system table: { particles, lines, ready }
        local chipSystems = {}

        local function buildSystem(nParticles)
            local particles = {}
            for i = 1, nParticles do
                local p = {
                    x  = 0, y  = 0,        -- screen coords (set on first tick)
                    vx = 0, vy = 0,
                    z  = rand(0, 1),        -- depth [0=far .. 1=near]
                    dot = D("Circle"),
                }
                p.dot.Filled      = true
                p.dot.Color       = COL_ACCENT
                p.dot.Radius      = 1
                p.dot.Transparency = 1
                p.dot.ZIndex      = 8
                table.insert(particles, p)
            end

            -- Pre-allocate lines for every possible pair
            local lines = {}
            for i = 1, nParticles do
                lines[i] = {}
                for j = i+1, nParticles do
                    local l = D("Line")
                    l.Thickness    = 1
                    l.Color        = COL_ACCENT
                    l.Transparency = 1
                    l.ZIndex       = 7
                    lines[i][j] = l
                end
            end
            return { particles=particles, lines=lines, ready=false }
        end

        -- Build systems for title, fps, time chips (exclude tiny logo)
        local entryToSystem = {}
        entryToSystem[titleEntry] = buildSystem(P_PER_CHIP)
        if fpsEntry  then entryToSystem[fpsEntry]  = buildSystem(P_PER_CHIP) end
        if timeEntry then entryToSystem[timeEntry] = buildSystem(P_PER_CHIP) end

        -- Init particle positions once we know AbsoluteSize
        local function initSystem(sys, ax, ay, aw, ah)
            for _, p in ipairs(sys.particles) do
                p.x  = rand(ax + 2, ax + aw - 2)
                p.y  = rand(ay + 2, ay + ah - 2)
                local spd = lerp(SPEED_MIN, SPEED_BASE, p.z)
                local angle = rand(0, math.pi * 2)
                p.vx = math.cos(angle) * spd
                p.vy = math.sin(angle) * spd
            end
            sys.ready = true
        end

        -- Update one chip's system
        local function tickSystem(sys, dt, ax, ay, aw, ah, globalA)
            if not sys.ready then
                if aw > 4 then initSystem(sys, ax, ay, aw, ah) end
                return
            end

            local pts = sys.particles
            for _, p in ipairs(pts) do
                -- speed scales with Z (depth)
                p.x += p.vx * dt
                p.y += p.vy * dt

                -- bounce off chip walls
                local m = 2
                if p.x < ax+m     then p.x = ax+m;     p.vx = math.abs(p.vx)  end
                if p.x > ax+aw-m  then p.x = ax+aw-m;  p.vx = -math.abs(p.vx) end
                if p.y < ay+m     then p.y = ay+m;     p.vy = math.abs(p.vy)  end
                if p.y > ay+ah-m  then p.y = ay+ah-m;  p.vy = -math.abs(p.vy) end

                -- render dot — size and opacity driven by Z (pseudo-3D)
                local r    = lerp(R_FAR,      R_NEAR,      p.z)
                local dotT = lerp(TRANSP_FAR, TRANSP_NEAR, p.z)
                p.dot.Position    = Vector2.new(p.x, p.y)
                p.dot.Radius      = r
                p.dot.Transparency = lerp(1, dotT, globalA)
                -- depth: blue (far) → bright blue/white (near)
                p.dot.Color       = Color3.fromRGB(
                    math.round(lerp(60, 160, p.z)),
                    math.round(lerp(100, 180, p.z)),
                    255
                )
            end

            -- Draw connection lines
            for i = 1, #pts do
                for j = i+1, #pts do
                    local pi, pj = pts[i], pts[j]
                    local dx = pi.x - pj.x
                    local dy = pi.y - pj.y
                    local dist = math.sqrt(dx*dx + dy*dy)
                    local l = sys.lines[i][j]

                    if dist < CONNECT_DIST then
                        local proximity = 1 - dist / CONNECT_DIST  -- 0..1, 1=closest
                        local avgZ = (pi.z + pj.z) * 0.5

                        -- opacity: closer & nearer = more visible
                        local baseT = lerp(LINE_FAR_T, LINE_BASE_T, proximity)
                        local finalT = lerp(baseT, baseT - 0.20, avgZ)

                        l.From         = Vector2.new(pi.x, pi.y)
                        l.To           = Vector2.new(pj.x, pj.y)
                        l.Transparency = lerp(1, finalT, globalA)
                        l.Thickness    = lerp(0.5, 1.0, avgZ)
                        l.Color        = Color3.fromRGB(
                            math.round(lerp(55, 110, avgZ)),
                            math.round(lerp(90, 160, avgZ)),
                            255
                        )
                    else
                        l.Transparency = 1
                    end
                end
            end
        end

        -- ── Animation state ───────────────────────────────────────────────
        local visible    = true
        local alpha      = 0
        local targetA    = 1
        local SPRING_IN  = 12
        local SPRING_OUT = 20

        local logoAngle  = 0
        local accentPh   = 0

        local FPS_N = 30
        local fpsBuf = table.create(FPS_N, 1/60)
        local fpsBufI = 1; local fpsTimer = 0

        local lastMin = -1

        -- ── Apply fade to all ScreenGui elements ──────────────────────────
        local function applyAlpha(a)
            uiScale.Scale = lerp(0.85, 1.0, a)

            local bgT  = lerp(1, BG_TRANSP, a)
            local txtT = lerp(1, 0, a)
            local strT = lerp(1, 0, a)

            for _, e in ipairs(allChips) do
                e.frame.BackgroundTransparency = bgT
                if e.stroke then e.stroke.Transparency = strT end
                for _, l in ipairs(e.labels) do l.TextTransparency  = txtT end
                for _, i in ipairs(e.images) do i.ImageTransparency = txtT end
            end
            for _, s in ipairs(logoSegs) do
                s.seg.ImageTransparency = lerp(1, 0.45, a)
            end
            innerMask.BackgroundTransparency = lerp(1, 0, a)
            accentLine.BackgroundTransparency = lerp(1, 0, a)
        end

        -- ── Heartbeat ─────────────────────────────────────────────────────
        local conn
        conn = RunService.Heartbeat:Connect(function(dt)
            -- Spring alpha
            local spd = targetA > alpha and SPRING_IN or SPRING_OUT
            alpha = lerp(alpha, targetA, math.min(1, dt * spd))
            if math.abs(alpha - targetA) < 0.004 then alpha = targetA end

            applyAlpha(alpha)
            gui.Enabled = alpha > 0.01

            -- Logo rotation
            logoAngle = (logoAngle + dt * 14) % 360
            for i, s in ipairs(logoSegs) do
                s.seg.Rotation = (i-1)*(360/SEG_COUNT) + logoAngle
            end

            -- Accent underline: match titleLbl text width + update color pulse
            accentPh = (accentPh + dt * 0.8) % (math.pi * 2)
            local t = (math.sin(accentPh) + 1) * 0.5
            local accentColor = Color3.fromRGB(
                math.round(lerp(72, 108, t)),
                math.round(lerp(138, 82, t)),
                255
            )
            accentLine.BackgroundColor3 = accentColor

            -- Resize accent line to fit text exactly
            do
                local ts = titleLbl.AbsoluteSize
                local tp = titleLbl.AbsolutePosition
                local fp = titleEntry.frame.AbsolutePosition
                if ts.X > 0 then
                    -- position relative to titleEntry.frame
                    local relX = tp.X - fp.X
                    accentLine.Size     = UDim2.fromOffset(ts.X, 1)
                    accentLine.Position = UDim2.fromOffset(relX, BAR_H - 4)
                end
            end

            -- Particle systems
            if alpha > 0.04 then
                for entry, sys in pairs(entryToSystem) do
                    local f  = entry.frame
                    local ap = f.AbsolutePosition
                    local as = f.AbsoluteSize
                    tickSystem(sys, dt, ap.X, ap.Y, as.X, as.Y, alpha)
                end
            else
                for _, d in ipairs(drawObjs) do d.Transparency = 1 end
            end

            -- FPS
            if fpsLbl then
                fpsBuf[fpsBufI] = dt; fpsBufI = (fpsBufI % FPS_N) + 1
                fpsTimer += dt
                if fpsTimer >= 0.25 then
                    fpsTimer = 0
                    local sum = 0
                    for i = 1, FPS_N do sum += fpsBuf[i] end
                    fpsLbl.Text = tostring(sum > 0 and math.round(FPS_N / sum) or 0)
                end
            end

            -- Time HH:MM (updates per minute)
            if timeLbl then
                local now = os.time()
                local curMin = math.floor(now / 60)
                if curMin ~= lastMin then
                    lastMin = curMin
                    local h = math.floor(now / 3600) % 24
                    local m = curMin % 60
                    timeLbl.Text = string.format("%02d:%02d", h, m)
                end
            end
        end)

        applyAlpha(0); targetA = 1

        -- ── TOP-RIGHT helper: repositions to viewport top-right ───────────
        local function setTopRight()
            local vp = workspace.CurrentCamera.ViewportSize
            -- measure total bar width
            task.wait()  -- let AutomaticSize settle
            local totalW = row.AbsoluteSize.X
            local margin = 22
            anchor.Position = UDim2.fromOffset(vp.X - totalW - margin, margin)
        end

        -- ── Public API ────────────────────────────────────────────────────
        local WM = {}

        function WM:Show()    if not visible then visible=true;  targetA=1 end end
        function WM:Hide()    if visible     then visible=false; targetA=0 end end
        function WM:Toggle()  if visible then self:Hide() else self:Show() end end
        function WM:IsVisible() return visible end

        function WM:SetTitle(text)
            titleText = text; titleLbl.Text = text
        end

        function WM:SetPosition(pos)
            if typeof(pos) == "UDim2" then
                anchor.Position = pos
            elseif typeof(pos) == "Vector2" then
                anchor.Position = UDim2.fromOffset(pos.X, pos.Y)
            end
        end

        function WM:MoveTopRight()  setTopRight()  end
        function WM:MoveTopLeft()
            anchor.Position = UDim2.fromOffset(22, 22)
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
