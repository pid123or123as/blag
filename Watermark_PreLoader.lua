-- Watermark_PreLoader.lua  (v5)
-- Layout: [Logo circle] [Syllinse Project chip] [FPS chip] [Time chip]
-- Effects: constellation particles (Drawing lines+circles) confined inside each chip bounds
-- Spring animation via Heartbeat lerp

return function(ctx)
    local MacLib     = ctx.MacLib
    local RunService = game:GetService("RunService")

    local function lerp(a, b, t) return a + (b - a) * t end
    local function clamp(v, mn, mx) return math.max(mn, math.min(mx, v)) end
    local function rand(a, b) return a + math.random() * (b - a) end

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
        local titleText = cfg.Title    or "Watermark"
        local showFPS   = cfg.ShowFPS  ~= false
        local showTime  = cfg.ShowTime ~= false

        -- parse position
        local initX, initY = 22, 22
        if cfg.Position then
            if typeof(cfg.Position) == "UDim2" then
                initX = cfg.Position.X.Offset
                initY = cfg.Position.Y.Offset
            elseif typeof(cfg.Position) == "Vector2" then
                initX = cfg.Position.X
                initY = cfg.Position.Y
            end
        end

        -- ── GUI ───────────────────────────────────────────────────────────
        local gui = GetGui()
        gui.Name = "MacLibWatermark"

        local anchor = Instance.new("Frame")
        anchor.Name                   = "WmAnchor"
        anchor.Position               = UDim2.fromOffset(initX, initY)
        anchor.AnchorPoint            = Vector2.new(0, 0)
        anchor.BackgroundTransparency = 1
        anchor.BorderSizePixel        = 0
        anchor.AutomaticSize          = Enum.AutomaticSize.XY
        anchor.Parent                 = gui

        local uiScale = Instance.new("UIScale")
        uiScale.Scale  = 0.82
        uiScale.Parent = anchor

        -- Row that holds all chips
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
        rowList.Padding           = UDim.new(0, 5)   -- gap between chips
        rowList.Parent            = row

        -- ── Design tokens ────────────────────────────────────────────────
        local BAR_H        = 32
        local LOGO_SZ      = 36      -- logo circle diameter
        local FONT_TITLE   = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.SemiBold)
        local FONT_BODY    = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Medium)
        local TXT_SZ       = 13
        local ICON_SZ      = 14
        local PAD_X        = 14     -- inner horizontal padding per chip
        local PAD_CENTER   = 6      -- extra inner pad to shift content toward center

        local COL_BG_TITLE = Color3.fromRGB(13, 13, 20)
        local COL_BG_CHIP  = Color3.fromRGB(11, 11, 17)
        local COL_BG_LOGO  = Color3.fromRGB(16, 16, 26)
        local COL_ACCENT   = Color3.fromRGB(72, 138, 255)
        local COL_ACCENT2  = Color3.fromRGB(108, 82, 255)
        local COL_STROKE   = Color3.fromRGB(45, 45, 65)
        local COL_TXT_MAIN = Color3.fromRGB(218, 218, 232)
        local COL_TXT_MUTE = Color3.fromRGB(135, 135, 158)
        local BG_TRANSP    = 0.32   -- frosted glass transparency

        -- ── Helper: make a chip frame ─────────────────────────────────────
        local chipOrder   = 0
        local allChips    = {}   -- { frame, labels={}, images={}, absPos=fn }

        local function makeChip(opts)
            chipOrder += 1
            opts = opts or {}

            local frame = Instance.new("Frame")
            frame.Name                   = "Chip" .. chipOrder
            frame.BackgroundColor3       = opts.bg or COL_BG_CHIP
            frame.BackgroundTransparency = BG_TRANSP
            frame.BorderSizePixel        = 0
            frame.LayoutOrder            = chipOrder
            frame.AutomaticSize          = opts.fixedW and Enum.AutomaticSize.None
                                                       or Enum.AutomaticSize.X
            frame.Size                   = opts.fixedW
                and UDim2.fromOffset(opts.fixedW, opts.h or BAR_H)
                or  UDim2.fromOffset(0, opts.h or BAR_H)
            frame.ClipsDescendants       = true
            frame.Parent                 = row

            -- Corner radius
            local corner = Instance.new("UICorner")
            corner.CornerRadius = UDim.new(0, opts.radius or 8)
            corner.Parent       = frame

            -- Stroke (only on some chips)
            local stroke = nil
            if opts.stroke then
                stroke = Instance.new("UIStroke")
                stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
                stroke.Color           = COL_STROKE
                stroke.Transparency    = 0
                stroke.Thickness       = 1
                stroke.Parent          = frame
            end

            -- Inner padding
            local pad = Instance.new("UIPadding")
            pad.PaddingLeft  = UDim.new(0, PAD_X + PAD_CENTER)
            pad.PaddingRight = UDim.new(0, PAD_X + PAD_CENTER)
            pad.Parent       = frame

            local entry = {
                frame   = frame,
                stroke  = stroke,
                labels  = {},
                images  = {},
            }
            table.insert(allChips, entry)
            return entry
        end

        -- ── LOGO chip (circle) ────────────────────────────────────────────
        -- Sits before the title chip, more rounded
        local logoEntry = makeChip({
            bg     = COL_BG_LOGO,
            fixedW = LOGO_SZ,
            h      = LOGO_SZ,
            radius = LOGO_SZ,   -- fully circular
            stroke = false,
        })
        -- remove padding on logo so segments fill the circle
        for _, c in ipairs(logoEntry.frame:GetChildren()) do
            if c:IsA("UIPadding") then c:Destroy() end
        end

        -- Logo segments (30 rotating ImageLabels)
        local SEG_COUNT = 30
        local logoSegments = {}
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
            local hue1 = ((i - 1) / SEG_COUNT)
            local hue2 = ((i)     / SEG_COUNT)
            grad.Color    = ColorSequence.new(
                Color3.fromHSV(0.60 + hue1 * 0.08, 0.85, 1),  -- blue range
                Color3.fromHSV(0.72 + hue2 * 0.06, 0.80, 1)   -- purple range
            )
            grad.Rotation = (i - 1) * (360 / SEG_COUNT)
            grad.Parent   = seg

            table.insert(logoSegments, { seg = seg, grad = grad })
        end

        -- ── TITLE chip ────────────────────────────────────────────────────
        local titleEntry = makeChip({ bg = COL_BG_TITLE, stroke = true })

        local titleLbl = Instance.new("TextLabel")
        titleLbl.FontFace               = FONT_TITLE
        titleLbl.TextSize               = TXT_SZ
        titleLbl.TextColor3             = COL_TXT_MAIN
        titleLbl.BackgroundTransparency = 1
        titleLbl.BorderSizePixel        = 0
        titleLbl.AutomaticSize          = Enum.AutomaticSize.X
        titleLbl.Size                   = UDim2.fromOffset(0, BAR_H)
        titleLbl.TextXAlignment         = Enum.TextXAlignment.Center
        titleLbl.Text                   = titleText
        titleLbl.ZIndex                 = 3
        titleLbl.Parent                 = titleEntry.frame
        table.insert(titleEntry.labels, titleLbl)

        -- Thin accent bottom line on title chip
        local accentBar = Instance.new("Frame")
        accentBar.Name              = "Accent"
        accentBar.AnchorPoint       = Vector2.new(0, 1)
        accentBar.Position          = UDim2.new(0, 0, 1, 0)
        accentBar.Size              = UDim2.new(1, 0, 0, 1)
        accentBar.BackgroundColor3  = COL_ACCENT
        accentBar.BackgroundTransparency = 0
        accentBar.BorderSizePixel   = 0
        accentBar.ZIndex            = 4
        accentBar.Parent            = titleEntry.frame

        -- ── FPS chip ──────────────────────────────────────────────────────
        local fpsEntry, fpsIcon, fpsLbl
        if showFPS then
            fpsEntry = makeChip({ fixedW = 80, stroke = true })

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
            fpsLbl.Size                   = UDim2.new(1, -(ICON_SZ + 5), 1, 0)
            fpsLbl.Position               = UDim2.fromOffset(ICON_SZ + 5, 0)
            fpsLbl.TextXAlignment         = Enum.TextXAlignment.Center
            fpsLbl.Text                   = "--"
            fpsLbl.ZIndex                 = 3
            fpsLbl.Parent                 = fpsEntry.frame
            table.insert(fpsEntry.labels, fpsLbl)
        end

        -- ── TIME chip ─────────────────────────────────────────────────────
        local timeEntry, timeIcon, timeLbl
        if showTime then
            timeEntry = makeChip({ fixedW = 98, stroke = true })

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
            timeLbl.Size                   = UDim2.new(1, -(ICON_SZ + 5), 1, 0)
            timeLbl.Position               = UDim2.fromOffset(ICON_SZ + 5, 0)
            timeLbl.TextXAlignment         = Enum.TextXAlignment.Center
            timeLbl.Text                   = "00:00"
            timeLbl.ZIndex                 = 3
            timeLbl.Parent                 = timeEntry.frame
            table.insert(timeEntry.labels, timeLbl)
        end

        -- ════════════════════════════════════════════════════════════════════
        -- CONSTELLATION PARTICLES  (Drawing, confined to chip bounds)
        -- Particles = small circles; Lines connect nearby ones.
        -- Each chip gets its own independent particle system.
        -- ════════════════════════════════════════════════════════════════════
        local drawObjs = {}
        local function newDraw(t)
            local d = Drawing.new(t)
            table.insert(drawObjs, d)
            return d
        end

        -- Config
        local PARTICLE_COUNT  = 6     -- particles per chip
        local CONNECT_DIST    = 55    -- max distance to draw a line
        local PARTICLE_SPEED  = 18    -- pixels/sec
        local PARTICLE_R      = 1.5   -- dot radius
        local PARTICLE_TRANSP = 0.60  -- dot transparency (0=opaque)
        local LINE_TRANSP     = 0.78  -- line base transparency

        -- Particle system per chip
        local chipParticles = {}

        local function initParticlesForChip(entry)
            local particles = {}
            for i = 1, PARTICLE_COUNT do
                local p = {
                    x = 0, y = 0,   -- will be set after first frame (AbsolutePosition)
                    vx = rand(-PARTICLE_SPEED, PARTICLE_SPEED),
                    vy = rand(-PARTICLE_SPEED, PARTICLE_SPEED),
                    dot = newDraw("Circle"),
                }
                p.dot.Filled      = true
                p.dot.Color       = COL_ACCENT
                p.dot.Radius      = PARTICLE_R
                p.dot.Transparency = 1   -- start hidden
                p.dot.ZIndex      = 7
                table.insert(particles, p)
            end

            -- pre-create connection lines (max pairs = N*(N-1)/2)
            local lines = {}
            for i = 1, PARTICLE_COUNT do
                lines[i] = {}
                for j = i+1, PARTICLE_COUNT do
                    local l = newDraw("Line")
                    l.Thickness    = 1
                    l.Color        = COL_ACCENT
                    l.Transparency = 1
                    l.ZIndex       = 6
                    lines[i][j] = l
                end
            end

            return { particles = particles, lines = lines, initialized = false }
        end

        -- Only title and stat chips get particles (not logo — too small)
        local chipSystemMap = {}
        chipSystemMap[titleEntry] = initParticlesForChip(titleEntry)
        if fpsEntry  then chipSystemMap[fpsEntry]  = initParticlesForChip(fpsEntry)  end
        if timeEntry then chipSystemMap[timeEntry] = initParticlesForChip(timeEntry) end

        -- ── Animation state ───────────────────────────────────────────────
        local visible   = true
        local alpha     = 0
        local targetA   = 1
        local SPRING_IN = 12
        local SPRING_OUT= 18

        -- Logo rotation
        local logoAngle = 0

        -- Accent color pulse
        local accentPhase = 0

        -- FPS
        local FPS_N    = 30
        local fpsBuf   = table.create(FPS_N, 1/60)
        local fpsBufI  = 1
        local fpsTimer = 0

        -- Time
        local lastSec  = -1

        -- ── Apply alpha to ScreenGui elements ─────────────────────────────
        local function applyAlpha(a)
            uiScale.Scale = lerp(0.84, 1.0, a)

            local bgT   = lerp(1, BG_TRANSP, a)
            local txtT  = lerp(1, 0, a)
            local strT  = lerp(1, 0, a)
            local imgT  = lerp(1, 0, a)
            local accT  = lerp(1, 0, a)

            for _, entry in ipairs(allChips) do
                entry.frame.BackgroundTransparency = bgT
                if entry.stroke then entry.stroke.Transparency = strT end
                for _, lbl in ipairs(entry.labels) do
                    lbl.TextTransparency = txtT
                end
                for _, img in ipairs(entry.images) do
                    img.ImageTransparency = imgT
                end
            end

            -- logo segments
            for _, s in ipairs(logoSegments) do
                s.seg.ImageTransparency = lerp(1, 0.45, a)
            end

            accentBar.BackgroundTransparency = accT
        end

        -- ── Update constellation for one chip ─────────────────────────────
        local function updateConstellation(entry, sys, dt, globalAlpha)
            local frame = entry.frame
            local ap = frame.AbsolutePosition
            local as = frame.AbsoluteSize

            -- Initialize particle positions on first valid frame
            if not sys.initialized and as.X > 2 then
                sys.initialized = true
                for _, p in ipairs(sys.particles) do
                    p.x = ap.X + rand(4, as.X - 4)
                    p.y = ap.Y + rand(4, as.Y - 4)
                end
            end
            if not sys.initialized then return end

            -- Move particles, bounce off chip walls
            for _, p in ipairs(sys.particles) do
                p.x += p.vx * dt
                p.y += p.vy * dt

                -- bounce inside chip bounds with small margin
                local margin = 3
                if p.x < ap.X + margin then
                    p.x = ap.X + margin; p.vx = math.abs(p.vx)
                elseif p.x > ap.X + as.X - margin then
                    p.x = ap.X + as.X - margin; p.vx = -math.abs(p.vx)
                end
                if p.y < ap.Y + margin then
                    p.y = ap.Y + margin; p.vy = math.abs(p.vy)
                elseif p.y > ap.Y + as.Y - margin then
                    p.y = ap.Y + as.Y - margin; p.vy = -math.abs(p.vy)
                end

                -- Update dot
                p.dot.Position    = Vector2.new(p.x, p.y)
                p.dot.Transparency = lerp(1, PARTICLE_TRANSP, globalAlpha)
            end

            -- Update connection lines
            local particles = sys.particles
            for i = 1, #particles do
                for j = i+1, #particles do
                    local pi = particles[i]
                    local pj = particles[j]
                    local dx = pi.x - pj.x
                    local dy = pi.y - pj.y
                    local dist = math.sqrt(dx*dx + dy*dy)

                    local l = sys.lines[i][j]
                    if dist < CONNECT_DIST then
                        -- closer = more opaque
                        local t = 1 - dist / CONNECT_DIST
                        l.From         = Vector2.new(pi.x, pi.y)
                        l.To           = Vector2.new(pj.x, pj.y)
                        l.Transparency = lerp(1, lerp(LINE_TRANSP, LINE_TRANSP - 0.3, t), globalAlpha)
                        l.Color        = COL_ACCENT
                    else
                        l.Transparency = 1
                    end
                end
            end
        end

        -- ── Heartbeat ─────────────────────────────────────────────────────
        local conn
        conn = RunService.Heartbeat:Connect(function(dt)
            -- Spring
            local speed = targetA > alpha and SPRING_IN or SPRING_OUT
            alpha = lerp(alpha, targetA, math.min(1, dt * speed))
            if math.abs(alpha - targetA) < 0.004 then alpha = targetA end

            applyAlpha(alpha)
            gui.Enabled = alpha > 0.01

            -- Logo slow rotation
            logoAngle = (logoAngle + dt * 12) % 360
            for i, s in ipairs(logoSegments) do
                s.seg.Rotation = (i - 1) * (360 / SEG_COUNT) + logoAngle
            end

            -- Accent bar color pulse
            accentPhase = (accentPhase + dt * 0.7) % (math.pi * 2)
            local t = (math.sin(accentPhase) + 1) * 0.5
            accentBar.BackgroundColor3 = Color3.fromRGB(
                math.round(lerp(72, 108, t)),
                math.round(lerp(138, 82, t)),
                255
            )

            -- Constellation particles
            if alpha > 0.05 then
                for entry, sys in pairs(chipSystemMap) do
                    updateConstellation(entry, sys, dt, alpha)
                end
            else
                -- Hide all drawing objects when invisible
                for _, d in ipairs(drawObjs) do
                    d.Transparency = 1
                end
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

            -- Time HH:MM (no seconds)
            if timeLbl then
                local now = os.time()
                local curMin = math.floor(now / 60)
                if curMin ~= lastSec then
                    lastSec = curMin
                    local h = math.floor(now / 3600) % 24
                    local m = math.floor(now / 60)   % 60
                    timeLbl.Text = string.format("%02d:%02d", h, m)
                end
            end
        end)

        -- Initial state
        applyAlpha(0)
        targetA = 1

        -- ── Public API ────────────────────────────────────────────────────
        local WM = {}

        function WM:Show()
            if not visible then visible = true; targetA = 1 end
        end

        function WM:Hide()
            if visible then visible = false; targetA = 0 end
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
            for _, d in ipairs(drawObjs) do
                pcall(function() d:Remove() end)
            end
            gui:Destroy()
        end

        return WM
    end

    if ctx.onLoad then ctx.onLoad() end
end
