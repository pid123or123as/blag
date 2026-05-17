-- Watermark_PreLoader.lua  (v8)
-- Fixes: particles above frame, gradient color shift, logo segments, centering,
--        positions, size-jump on appear, iOS drag animation, particle pulse

return function(ctx)
    local MacLib     = ctx.MacLib
    local RunService = game:GetService("RunService")
    local UIS        = game:GetService("UserInputService")

    local function lerp(a, b, t) return a + (b - a) * t end
    local function rand(a, b)    return a + math.random() * (b - a) end
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
        local titleText = cfg.Title   or "Watermark"
        local showFPS   = cfg.ShowFPS  ~= false
        local showTime  = cfg.ShowTime ~= false

        -- Default position: top-left, past Roblox buttons
        local initX, initY = 108, 8
        if cfg.Position then
            if typeof(cfg.Position) == "UDim2" then
                initX = cfg.Position.X.Offset; initY = cfg.Position.Y.Offset
            elseif typeof(cfg.Position) == "Vector2" then
                initX = cfg.Position.X; initY = cfg.Position.Y
            end
        end

        -- ── Root GUI ──────────────────────────────────────────────────────
        local gui = GetGui(); gui.Name = "MacLibWatermark"

        -- Outer container — this is what we move for position
        -- Size = XY auto so it wraps content
        local anchor = Instance.new("Frame")
        anchor.Name                   = "WmAnchor"
        anchor.Position               = UDim2.fromOffset(initX, initY)
        anchor.AnchorPoint            = Vector2.new(0, 0)
        anchor.BackgroundTransparency = 1
        anchor.BorderSizePixel        = 0
        anchor.AutomaticSize          = Enum.AutomaticSize.XY
        anchor.Parent                 = gui

        -- UIScale for spring appear/disappear animation
        -- Start at 1.0, animate only transparency — no scale jump at end
        -- We'll NOT use uiScale for appear, instead we fade only
        -- (Scale approach causes the text size jump you saw)

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

        -- ── Tokens ────────────────────────────────────────────────────────
        local BAR_H   = 26
        local LOGO_SZ = 32
        local SEG_SZ  = 18    -- ring inside logo chip (smaller than chip)
        local TXT_SZ  = 12
        local ICON_SZ = 13
        local PAD_X   = 10

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
        local allChips  = {}

        local function makeChip(opts)
            chipOrder += 1; opts = opts or {}
            local h = opts.h or BAR_H

            local f = Instance.new("Frame")
            f.Name                   = "Chip"..chipOrder
            f.BackgroundColor3       = opts.bg or COL_BG_CHIP
            f.BackgroundTransparency = 1   -- start invisible, applyAlpha controls this
            f.BorderSizePixel        = 0
            f.LayoutOrder            = chipOrder
            f.ClipsDescendants       = true

            if opts.fixedW then
                f.AutomaticSize = Enum.AutomaticSize.None
                f.Size = UDim2.fromOffset(opts.fixedW, h)
            else
                f.AutomaticSize = Enum.AutomaticSize.X
                f.Size = UDim2.fromOffset(0, h)
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
                stroke.Transparency    = 1
                stroke.Thickness       = 1
                stroke.Parent          = f
            end

            if opts.padX ~= false then
                local pad = Instance.new("UIPadding")
                pad.PaddingLeft  = UDim.new(0, opts.padX or PAD_X)
                pad.PaddingRight = UDim.new(0, opts.padX or PAD_X)
                pad.Parent = f
            end

            local entry = { frame=f, stroke=stroke, labels={}, images={}, bgColor=opts.bg or COL_BG_CHIP }
            table.insert(allChips, entry)
            return entry
        end

        -- ── LOGO chip ─────────────────────────────────────────────────────
        local logoEntry = makeChip({
            bg=COL_BG_DARK, fixedW=LOGO_SZ, h=LOGO_SZ,
            radius=9, stroke=false, padX=false,
        })

        local logoHolder = Instance.new("Frame")
        logoHolder.Name                   = "LogoHolder"
        logoHolder.AnchorPoint            = Vector2.new(0.5, 0.5)
        logoHolder.Position               = UDim2.new(0.5,0, 0.5,0)
        logoHolder.Size                   = UDim2.fromOffset(SEG_SZ, SEG_SZ)
        logoHolder.BackgroundTransparency = 1
        logoHolder.BorderSizePixel        = 0
        logoHolder.ClipsDescendants       = false
        logoHolder.Parent                 = logoEntry.frame

        local SEG_COUNT = 16   -- reduced from 30
        local logoSegs  = {}
        for i = 1, SEG_COUNT do
            local seg = Instance.new("ImageLabel")
            seg.Size                   = UDim2.new(1,0,1,0)
            seg.BackgroundTransparency = 1
            seg.Image                  = "rbxassetid://7151778302"
            seg.ImageTransparency      = 1   -- start hidden
            seg.Rotation               = (i-1)*(360/SEG_COUNT)
            seg.ZIndex                 = 3
            seg.Parent                 = logoHolder
            Instance.new("UICorner", seg).CornerRadius = UDim.new(0.5, 0)
            local grad = Instance.new("UIGradient")
            local h1 = (0.60 + (i-1)/SEG_COUNT*0.14) % 1
            local h2 = (0.70 + i/SEG_COUNT*0.12) % 1
            grad.Color    = ColorSequence.new(Color3.fromHSV(h1,0.85,1), Color3.fromHSV(h2,0.78,1))
            grad.Rotation = (i-1)*(360/SEG_COUNT)
            grad.Parent   = seg
            table.insert(logoSegs, seg)
        end

        -- ── TITLE chip ────────────────────────────────────────────────────
        local titleEntry = makeChip({ bg=COL_BG_DARK, stroke=true })

        local titleLbl = Instance.new("TextLabel")
        titleLbl.FontFace               = FONT_TITLE
        titleLbl.TextSize               = TXT_SZ
        titleLbl.TextColor3             = COL_TXT_MAIN
        titleLbl.BackgroundTransparency = 1
        titleLbl.BorderSizePixel        = 0
        titleLbl.AutomaticSize          = Enum.AutomaticSize.X
        titleLbl.Size                   = UDim2.fromOffset(0, BAR_H)
        titleLbl.TextXAlignment         = Enum.TextXAlignment.Left
        titleLbl.TextTransparency       = 1
        titleLbl.Text                   = titleText
        titleLbl.ZIndex                 = 3
        titleLbl.Parent                 = titleEntry.frame
        table.insert(titleEntry.labels, titleLbl)

        -- Accent underline
        local accentLine = Instance.new("Frame")
        accentLine.Name                   = "AccentLine"
        accentLine.BackgroundColor3       = COL_ACCENT
        accentLine.BackgroundTransparency = 1
        accentLine.BorderSizePixel        = 0
        accentLine.ZIndex                 = 5
        accentLine.Size                   = UDim2.fromOffset(40, 1)
        accentLine.Position               = UDim2.fromOffset(0, BAR_H - 4)
        accentLine.Parent                 = titleEntry.frame

        -- ── FPS chip ──────────────────────────────────────────────────────
        local fpsEntry, fpsIcon, fpsLbl
        if showFPS then
            fpsEntry = makeChip({ fixedW=74, stroke=true })

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

            -- Center: icon(13) + gap(5) + label fills rest, but we add left shift
            -- total inner = fixedW - 2*padX = 74-20=54. icon=13,gap=5 → label=36
            -- We push label center relative to chip center
            fpsLbl = Instance.new("TextLabel")
            fpsLbl.FontFace               = FONT_BODY
            fpsLbl.TextSize               = TXT_SZ
            fpsLbl.TextColor3             = COL_TXT_MUTE
            fpsLbl.BackgroundTransparency = 1
            fpsLbl.TextTransparency       = 1
            fpsLbl.BorderSizePixel        = 0
            fpsLbl.Size                   = UDim2.new(1, -(ICON_SZ+4), 1, 0)
            fpsLbl.Position               = UDim2.fromOffset(ICON_SZ+4, 0)
            fpsLbl.TextXAlignment         = Enum.TextXAlignment.Center
            fpsLbl.Text                   = "--"
            fpsLbl.ZIndex                 = 3
            fpsLbl.Parent                 = fpsEntry.frame
            table.insert(fpsEntry.labels, fpsLbl)
        end

        -- ── TIME chip ─────────────────────────────────────────────────────
        local timeEntry, timeIcon, timeLbl
        if showTime then
            timeEntry = makeChip({ fixedW=90, stroke=true })

            timeIcon = Instance.new("ImageLabel")
            timeIcon.Image                  = "rbxassetid://17824308575"
            timeIcon.Size                   = UDim2.fromOffset(ICON_SZ, ICON_SZ)
            timeIcon.AnchorPoint            = Vector2.new(0, 0.5)
            timeIcon.Position               = UDim2.new(0, 0, 0.5, 0)
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
            timeLbl.BackgroundTransparency = 1
            timeLbl.TextTransparency       = 1
            timeLbl.BorderSizePixel        = 0
            timeLbl.Size                   = UDim2.new(1, -(ICON_SZ+4), 1, 0)
            timeLbl.Position               = UDim2.fromOffset(ICON_SZ+4, 0)
            timeLbl.TextXAlignment         = Enum.TextXAlignment.Center
            timeLbl.Text                   = "00:00"
            timeLbl.ZIndex                 = 3
            timeLbl.Parent                 = timeEntry.frame
            table.insert(timeEntry.labels, timeLbl)
        end

        -- ════════════════════════════════════════════════════════════════════
        -- DRAWING PARTICLES
        -- Drawing Transparency: 0 = invisible, 1 = fully opaque
        -- Particles confined strictly to chip AbsoluteBounds
        -- Gradient color: blue → light purple pulse per particle
        -- ════════════════════════════════════════════════════════════════════
        local drawObjs = {}
        local function D(t)
            local d = Drawing.new(t)
            d.Visible = true
            table.insert(drawObjs, d)
            return d
        end

        local P_COUNT      = 10
        local CONNECT_DIST = 52
        local SPEED_NEAR   = 20
        local SPEED_FAR    = 6
        local R_NEAR       = 2.0
        local R_FAR        = 0.7

        -- Color gradient: blue (210°) → light purple (265°) in HSV
        local HUE_BLUE   = 210/360
        local HUE_PURPLE = 265/360

        local function buildSys(n)
            local pts = {}
            for i = 1, n do
                local p = {
                    x=0, y=0, vx=0, vy=0,
                    z       = rand(0,1),
                    phase   = rand(0, math.pi*2),  -- individual color phase
                    pulsePh = rand(0, math.pi*2),  -- size pulse phase
                    dot     = D("Circle"),
                }
                p.dot.Filled       = true
                p.dot.Color        = Color3.fromHSV(HUE_BLUE, 0.7, 1)
                p.dot.Radius       = 1
                p.dot.Transparency = 0
                p.dot.NumSides     = 12
                p.dot.ZIndex       = 9
                table.insert(pts, p)
            end

            local lines = {}
            for i = 1, n do
                lines[i] = {}
                for j = i+1, n do
                    local l = D("Line")
                    l.Thickness    = 1
                    l.Color        = Color3.fromHSV(HUE_BLUE, 0.65, 1)
                    l.Transparency = 0
                    l.ZIndex       = 8
                    lines[i][j] = l
                end
            end
            return { pts=pts, lines=lines, ready=false }
        end

        local entryToSys = {}
        entryToSys[titleEntry] = buildSys(P_COUNT)
        if fpsEntry  then entryToSys[fpsEntry]  = buildSys(P_COUNT) end
        if timeEntry then entryToSys[timeEntry] = buildSys(P_COUNT) end

        local function initSys(sys, ax, ay, aw, ah)
            for _, p in ipairs(sys.pts) do
                -- Spawn strictly inside chip
                p.x = rand(ax + R_NEAR + 1, ax + aw - R_NEAR - 1)
                p.y = rand(ay + R_NEAR + 1, ay + ah - R_NEAR - 1)
                local spd   = lerp(SPEED_FAR, SPEED_NEAR, p.z)
                local angle = rand(0, math.pi*2)
                p.vx = math.cos(angle)*spd
                p.vy = math.sin(angle)*spd
            end
            sys.ready = true
        end

        local globalTime = 0

        local function tickSys(sys, dt, ax, ay, aw, ah, globalA)
            if not sys.ready then
                if aw > 4 then initSys(sys, ax, ay, aw, ah) end
                return
            end

            local pts = sys.pts
            for _, p in ipairs(pts) do
                p.x += p.vx * dt
                p.y += p.vy * dt

                -- Strict bounce inside chip pixel bounds
                local rr = lerp(R_FAR, R_NEAR, p.z)
                if p.x - rr < ax    then p.x = ax + rr;    p.vx =  math.abs(p.vx) end
                if p.x + rr > ax+aw then p.x = ax+aw - rr; p.vx = -math.abs(p.vx) end
                if p.y - rr < ay    then p.y = ay + rr;    p.vy =  math.abs(p.vy) end
                if p.y + rr > ay+ah then p.y = ay+ah - rr; p.vy = -math.abs(p.vy) end

                -- Gradient color: blue → light purple, per-particle phase shift
                p.phase   = (p.phase   + dt * 0.6) % (math.pi*2)
                p.pulsePh = (p.pulsePh + dt * 1.4) % (math.pi*2)

                local ct   = (math.sin(p.phase) + 1) * 0.5   -- 0=blue, 1=purple
                local hue  = lerp(HUE_BLUE, HUE_PURPLE, ct)
                local sat  = lerp(0.60, 0.80, p.z)
                local val  = lerp(0.85, 1.00, p.z)

                -- Size pulse
                local pulseMult = 1 + math.sin(p.pulsePh) * 0.25
                local r    = lerp(R_FAR, R_NEAR, p.z) * pulseMult
                -- Opacity: Drawing 0=invisible 1=opaque
                local dotOp = lerp(0.18, 0.72, p.z) * globalA

                p.dot.Position    = Vector2.new(p.x, p.y)
                p.dot.Radius      = math.max(0.3, r)
                p.dot.Transparency = clamp(dotOp, 0, 1)
                p.dot.Color       = Color3.fromHSV(hue, sat, val)
            end

            -- Lines
            for i = 1, #pts do
                for j = i+1, #pts do
                    local pi, pj = pts[i], pts[j]
                    local dx   = pi.x - pj.x; local dy = pi.y - pj.y
                    local dist = math.sqrt(dx*dx + dy*dy)
                    local l    = sys.lines[i][j]

                    if dist < CONNECT_DIST then
                        local prox = 1 - dist/CONNECT_DIST
                        local avgZ = (pi.z + pj.z)*0.5
                        local ct2  = (math.sin((pi.phase+pj.phase)*0.5)+1)*0.5
                        local hue2 = lerp(HUE_BLUE, HUE_PURPLE, ct2)
                        -- Drawing opacity: closer = more opaque
                        local lineOp = lerp(0.05, 0.42, prox) * lerp(0.5, 1, avgZ) * globalA

                        l.From         = Vector2.new(pi.x, pi.y)
                        l.To           = Vector2.new(pj.x, pj.y)
                        l.Transparency = clamp(lineOp, 0, 1)
                        l.Thickness    = lerp(0.5, 1.2, avgZ)
                        l.Color        = Color3.fromHSV(hue2, 0.65, 1)
                    else
                        l.Transparency = 0
                    end
                end
            end
        end

        -- ── Animation state ───────────────────────────────────────────────
        local visible    = true
        local alpha      = 0       -- 0=hidden, 1=shown
        local targetA    = 1
        local SPRING_IN  = 10
        local SPRING_OUT = 18

        local logoAngle = 0
        local accentPh  = 0

        local FPS_N   = 30
        local fpsBuf  = table.create(FPS_N, 1/60)
        local fpsBufI = 1; local fpsTimer = 0
        local lastMin = -1

        -- ── applyAlpha — NO UIScale so no size jump ───────────────────────
        local function applyAlpha(a)
            -- All chips: fade background
            for _, e in ipairs(allChips) do
                e.frame.BackgroundTransparency = lerp(1, BG_TRANSP, a)
                if e.stroke then e.stroke.Transparency = lerp(1, 0, a) end
                for _, lbl in ipairs(e.labels)  do lbl.TextTransparency  = lerp(1, 0, a) end
                for _, img in ipairs(e.images)  do img.ImageTransparency = lerp(1, 0, a) end
            end
            for _, seg in ipairs(logoSegs) do
                seg.ImageTransparency = lerp(1, 0.35, a)
            end
            accentLine.BackgroundTransparency = lerp(1, 0, a)

            if a < 0.02 then
                for _, d in ipairs(drawObjs) do d.Transparency = 0 end
            end
        end

        -- ── Drag (iOS style: smooth position lerp) ────────────────────────
        local isDragging  = false
        local dragOffsetX = 0
        local dragOffsetY = 0
        local targetPosX  = initX
        local targetPosY  = initY
        local currentPosX = initX
        local currentPosY = initY

        -- Drag detect on any chip frame
        local function setupDrag(frame)
            frame.InputBegan:Connect(function(inp)
                if inp.UserInputType == Enum.UserInputType.MouseButton1
                or inp.UserInputType == Enum.UserInputType.Touch then
                    isDragging  = true
                    local ap    = anchor.AbsolutePosition
                    dragOffsetX = inp.Position.X - ap.X
                    dragOffsetY = inp.Position.Y - ap.Y
                end
            end)
        end

        for _, e in ipairs(allChips) do setupDrag(e.frame) end

        UIS.InputEnded:Connect(function(inp)
            if inp.UserInputType == Enum.UserInputType.MouseButton1
            or inp.UserInputType == Enum.UserInputType.Touch then
                isDragging = false
            end
        end)

        -- ── Heartbeat ─────────────────────────────────────────────────────
        local conn
        conn = RunService.Heartbeat:Connect(function(dt)
            globalTime = globalTime + dt

            -- Spring alpha (fade only, no scale change)
            local spd = targetA > alpha and SPRING_IN or SPRING_OUT
            alpha = lerp(alpha, targetA, clamp(dt*spd, 0, 1))
            if math.abs(alpha-targetA) < 0.004 then alpha = targetA end

            applyAlpha(alpha)
            gui.Enabled = alpha > 0.01

            -- Drag: update target from mouse, spring-lerp actual position
            if isDragging then
                local mp    = UIS:GetMouseLocation()
                targetPosX  = mp.X - dragOffsetX
                targetPosY  = mp.Y - dragOffsetY
            end
            -- iOS spring drag: position follows target with slight lag
            local posSpeed = isDragging and 22 or 14
            currentPosX = lerp(currentPosX, targetPosX, clamp(dt*posSpeed, 0, 1))
            currentPosY = lerp(currentPosY, targetPosY, clamp(dt*posSpeed, 0, 1))
            anchor.Position = UDim2.fromOffset(math.round(currentPosX), math.round(currentPosY))

            -- Logo rotation
            logoAngle = (logoAngle + dt*18) % 360
            for i, seg in ipairs(logoSegs) do
                seg.Rotation = (i-1)*(360/SEG_COUNT) + logoAngle
            end

            -- Accent color pulse + size sync to text
            accentPh = (accentPh + dt*0.9) % (math.pi*2)
            local t  = (math.sin(accentPh)+1)*0.5
            accentLine.BackgroundColor3 = Color3.fromRGB(
                math.round(lerp(72,108,t)),
                math.round(lerp(138,82,t)),
                255
            )
            local ts = titleLbl.AbsoluteSize
            if ts.X > 1 then
                accentLine.Size     = UDim2.fromOffset(ts.X, 1)
                accentLine.Position = UDim2.fromOffset(0, BAR_H - 4)
            end

            -- Particles
            if alpha > 0.03 then
                for entry, sys in pairs(entryToSys) do
                    local f  = entry.frame
                    local ap = f.AbsolutePosition
                    local as = f.AbsoluteSize
                    if as.X > 4 and as.Y > 4 then
                        tickSys(sys, dt, ap.X, ap.Y, as.X, as.Y, alpha)
                    end
                end
            else
                for _, d in ipairs(drawObjs) do d.Transparency = 0 end
            end

            -- FPS rolling avg
            if fpsLbl then
                fpsBuf[fpsBufI] = dt; fpsBufI=(fpsBufI % FPS_N)+1
                fpsTimer += dt
                if fpsTimer >= 0.25 then
                    fpsTimer = 0
                    local sum = 0
                    for i=1,FPS_N do sum+=fpsBuf[i] end
                    fpsLbl.Text = tostring(sum>0 and math.round(FPS_N/sum) or 0)
                end
            end

            -- Time HH:MM
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

        applyAlpha(0); targetA = 1
        currentPosX = initX; currentPosY = initY
        targetPosX  = initX; targetPosY  = initY

        -- ── Public API ────────────────────────────────────────────────────
        local WM = {}
        function WM:Show()    if not visible then visible=true;  targetA=1 end end
        function WM:Hide()    if visible     then visible=false; targetA=0 end end
        function WM:Toggle()  if visible then self:Hide() else self:Show() end end
        function WM:IsVisible() return visible end
        function WM:SetTitle(txt) titleText=txt; titleLbl.Text=txt end

        function WM:SetPosition(pos)
            local x, y
            if typeof(pos)=="UDim2" then
                x=pos.X.Offset; y=pos.Y.Offset
            elseif typeof(pos)=="Vector2" then
                x=pos.X; y=pos.Y
            end
            if x then
                targetPosX=x; targetPosY=y
            end
        end

        function WM:MoveTopRight()
            task.defer(function()
                local vp = workspace.CurrentCamera.ViewportSize
                local w  = row.AbsoluteSize.X
                local x  = vp.X - w - 16
                local y  = 8
                targetPosX = x; targetPosY = y
            end)
        end

        function WM:MoveTopLeft()
            targetPosX = 108; targetPosY = 8
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
