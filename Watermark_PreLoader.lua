-- Watermark_PreLoader.lua  (v8)
-- Fixes & features:
--  1. Particles gradient blue→light-violet (hue shift over time)
--  2. Logo: fewer segments (8), only arc-dots, no ring overlap
--  3. FPS/Time text centered properly
--  4. Particles: FIXED position offset — use AbsolutePosition correctly
--     Drawing uses SCREEN coords, no UIScale compensation needed on raw AbsPos
--     BUT UIScale shrinks the GUI → AbsolutePosition/Size are already in screen px
--  5. Particles subtle pulse/drift variation
--  6. Smooth drag animation (spring-based, iOS feel)
--  7. Appearance animation: no pop/jump — anchor.Size drives nothing, scale only via UIScale
--     Fixed: UIScale animation starts at 0.72, ends at 1.0 smoothly
--  8. MoveTopRight / MoveTopLeft / MoveBottomLeft / MoveBottomRight built-in
--  9. Drag toggle (default ON for PC, OFF for mobile)

return function(ctx)
    local MacLib          = ctx.MacLib
    local RunService      = game:GetService("RunService")
    local UIS             = game:GetService("UserInputService")
    local isMobile        = UIS.TouchEnabled and not UIS.KeyboardEnabled

    -- ── Utilities ──────────────────────────────────────────────────────
    local function lerp(a,b,t) return a+(b-a)*t end
    local function rand(a,b)   return a+math.random()*(b-a) end
    local function clamp(v,a,b) return math.max(a,math.min(b,v)) end

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

    -- ════════════════════════════════════════════════════════════════════
    function MacLib:Watermark(cfg)
        cfg = cfg or {}
        local titleText  = cfg.Title    or "Watermark"
        local showFPS    = cfg.ShowFPS  ~= false
        local showTime   = cfg.ShowTime ~= false
        local dragEnabled = cfg.Drag ~= nil and cfg.Drag or (not isMobile)

        -- initial position
        local posX, posY = 104, 8
        if cfg.Position then
            if typeof(cfg.Position)=="UDim2" then
                posX=cfg.Position.X.Offset; posY=cfg.Position.Y.Offset
            elseif typeof(cfg.Position)=="Vector2" then
                posX=cfg.Position.X; posY=cfg.Position.Y
            end
        end

        -- ── Root GUI ─────────────────────────────────────────────────
        local gui      = GetGui(); gui.Name = "MacLibWatermark"
        local SAFE_MIN = 1.0      -- final UIScale
        local SAFE_START = 0.72   -- initial UIScale (animation start)

        local anchor = Instance.new("Frame")
        anchor.Name                   = "WmAnchor"
        anchor.BackgroundTransparency = 1
        anchor.BorderSizePixel        = 0
        anchor.AutomaticSize          = Enum.AutomaticSize.XY
        anchor.AnchorPoint            = Vector2.new(0,0)
        anchor.Position               = UDim2.fromOffset(posX, posY)
        anchor.Parent                 = gui

        local uiScale = Instance.new("UIScale")
        uiScale.Scale = SAFE_START
        uiScale.Parent = anchor

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
        rowList.Padding           = UDim.new(0,5)
        rowList.Parent            = row

        -- ── Tokens ───────────────────────────────────────────────────
        local BAR_H   = 26
        local LOGO_SZ = 32
        local SEG_SZ  = 14    -- smaller inner ring
        local TXT_SZ  = 12
        local ICON_SZ = 13
        local PAD_X   = 10

        local FONT_TITLE = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.SemiBold)
        local FONT_BODY  = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Medium)

        local COL_BG_DARK  = Color3.fromRGB(12,12,19)
        local COL_BG_CHIP  = Color3.fromRGB(10,10,16)
        local COL_ACCENT   = Color3.fromRGB(72,138,255)
        local COL_STROKE   = Color3.fromRGB(42,42,62)
        local COL_TXT_MAIN = Color3.fromRGB(215,215,230)
        local COL_TXT_MUTE = Color3.fromRGB(130,130,155)
        local BG_TRANSP    = 0.28

        -- ── Chip factory ─────────────────────────────────────────────
        local chipOrder = 0
        local allChips  = {}

        local function makeChip(opts)
            chipOrder += 1; opts = opts or {}
            local h = opts.h or BAR_H

            local f = Instance.new("Frame")
            f.Name                   = "Chip"..chipOrder
            f.BackgroundColor3       = opts.bg or COL_BG_CHIP
            f.BackgroundTransparency = BG_TRANSP
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
                stroke.Transparency    = 0
                stroke.Thickness       = 1
                stroke.Parent          = f
            end

            if opts.padX ~= false then
                local pad = Instance.new("UIPadding")
                pad.PaddingLeft  = UDim.new(0, opts.padX or PAD_X)
                pad.PaddingRight = UDim.new(0, opts.padX or PAD_X)
                pad.Parent = f
            end

            local entry = { frame=f, stroke=stroke, labels={}, images={} }
            table.insert(allChips, entry)
            return entry
        end

        -- ── LOGO chip ────────────────────────────────────────────────
        -- Chip: LOGO_SZ square. Inside: 8 small ImageLabels arranged in a ring.
        local logoEntry = makeChip({
            bg=COL_BG_DARK, fixedW=LOGO_SZ, h=LOGO_SZ, radius=9,
            stroke=false, padX=false,
        })

        local logoHolder = Instance.new("Frame")
        logoHolder.Name                   = "LogoHolder"
        logoHolder.AnchorPoint            = Vector2.new(0.5,0.5)
        logoHolder.Position               = UDim2.new(0.5,0,0.5,0)
        logoHolder.Size                   = UDim2.fromOffset(SEG_SZ,SEG_SZ)
        logoHolder.BackgroundTransparency = 1
        logoHolder.BorderSizePixel        = 0
        logoHolder.Parent                 = logoEntry.frame

        local SEG_COUNT = 8
        local logoSegs  = {}
        local DOT_SZ    = 3

        for i = 1, SEG_COUNT do
            -- Place each dot at angle around centre, distance = SEG_SZ/2
            local angle = math.rad((i-1)*(360/SEG_COUNT))
            local r     = SEG_SZ/2
            local dx    = math.cos(angle)*r
            local dy    = math.sin(angle)*r

            local dot = Instance.new("Frame")
            dot.Size                   = UDim2.fromOffset(DOT_SZ,DOT_SZ)
            dot.AnchorPoint            = Vector2.new(0.5,0.5)
            dot.Position               = UDim2.new(0.5, math.round(dx), 0.5, math.round(dy))
            dot.BackgroundColor3       = COL_ACCENT
            dot.BackgroundTransparency = 0.2
            dot.BorderSizePixel        = 0
            dot.ZIndex                 = 3
            dot.Parent                 = logoHolder
            Instance.new("UICorner",dot).CornerRadius = UDim.new(1,0)
            table.insert(logoSegs,{dot=dot, baseAngle=angle})
        end

        -- ── TITLE chip ───────────────────────────────────────────────
        local titleEntry = makeChip({bg=COL_BG_DARK, stroke=true})

        local titleLbl = Instance.new("TextLabel")
        titleLbl.FontFace               = FONT_TITLE
        titleLbl.TextSize               = TXT_SZ
        titleLbl.TextColor3             = COL_TXT_MAIN
        titleLbl.BackgroundTransparency = 1
        titleLbl.BorderSizePixel        = 0
        titleLbl.AutomaticSize          = Enum.AutomaticSize.X
        titleLbl.Size                   = UDim2.fromOffset(0,BAR_H)
        titleLbl.TextXAlignment         = Enum.TextXAlignment.Left
        titleLbl.Text                   = titleText
        titleLbl.ZIndex                 = 3
        titleLbl.Parent                 = titleEntry.frame
        table.insert(titleEntry.labels, titleLbl)

        -- Underline: sits 3px above bottom inside padded area
        local accentLine = Instance.new("Frame")
        accentLine.Name                   = "AccentLine"
        accentLine.BackgroundColor3       = COL_ACCENT
        accentLine.BackgroundTransparency = 0
        accentLine.BorderSizePixel        = 0
        accentLine.ZIndex                 = 6
        accentLine.Size                   = UDim2.fromOffset(40,1)
        accentLine.Position               = UDim2.fromOffset(0, BAR_H-3)
        accentLine.Parent                 = titleEntry.frame

        -- ── FPS chip ─────────────────────────────────────────────────
        local fpsEntry,fpsIcon,fpsLbl
        if showFPS then
            fpsEntry = makeChip({fixedW=76, stroke=true, padX=false})
            -- inner layout for centered content
            local innerFps = Instance.new("Frame")
            innerFps.BackgroundTransparency=1; innerFps.BorderSizePixel=0
            innerFps.AnchorPoint=Vector2.new(0.5,0.5)
            innerFps.Position=UDim2.new(0.5,0,0.5,0)
            innerFps.AutomaticSize=Enum.AutomaticSize.XY
            innerFps.Parent=fpsEntry.frame
            local innerFpsLayout=Instance.new("UIListLayout")
            innerFpsLayout.FillDirection=Enum.FillDirection.Horizontal
            innerFpsLayout.VerticalAlignment=Enum.VerticalAlignment.Center
            innerFpsLayout.Padding=UDim.new(0,5)
            innerFpsLayout.Parent=innerFps

            fpsIcon=Instance.new("ImageLabel")
            fpsIcon.Image="rbxassetid://102994395432803"
            fpsIcon.Size=UDim2.fromOffset(ICON_SZ,ICON_SZ)
            fpsIcon.BackgroundTransparency=1
            fpsIcon.BorderSizePixel=0
            fpsIcon.ZIndex=3
            fpsIcon.Parent=innerFps
            table.insert(fpsEntry.images, fpsIcon)

            fpsLbl=Instance.new("TextLabel")
            fpsLbl.FontFace=FONT_BODY
            fpsLbl.TextSize=TXT_SZ
            fpsLbl.TextColor3=COL_TXT_MUTE
            fpsLbl.BackgroundTransparency=1
            fpsLbl.BorderSizePixel=0
            fpsLbl.AutomaticSize=Enum.AutomaticSize.X
            fpsLbl.Size=UDim2.fromOffset(0,BAR_H)
            fpsLbl.TextXAlignment=Enum.TextXAlignment.Center
            fpsLbl.Text="--"
            fpsLbl.ZIndex=3
            fpsLbl.Parent=innerFps
            table.insert(fpsEntry.labels, fpsLbl)
        end

        -- ── TIME chip ────────────────────────────────────────────────
        local timeEntry,timeIcon,timeLbl
        if showTime then
            timeEntry = makeChip({fixedW=92, stroke=true, padX=false})
            local innerTime=Instance.new("Frame")
            innerTime.BackgroundTransparency=1; innerTime.BorderSizePixel=0
            innerTime.AnchorPoint=Vector2.new(0.5,0.5)
            innerTime.Position=UDim2.new(0.5,0,0.5,0)
            innerTime.AutomaticSize=Enum.AutomaticSize.XY
            innerTime.Parent=timeEntry.frame
            local innerTimeLayout=Instance.new("UIListLayout")
            innerTimeLayout.FillDirection=Enum.FillDirection.Horizontal
            innerTimeLayout.VerticalAlignment=Enum.VerticalAlignment.Center
            innerTimeLayout.Padding=UDim.new(0,5)
            innerTimeLayout.Parent=innerTime

            timeIcon=Instance.new("ImageLabel")
            timeIcon.Image="rbxassetid://17824308575"
            timeIcon.Size=UDim2.fromOffset(ICON_SZ,ICON_SZ)
            timeIcon.BackgroundTransparency=1
            timeIcon.BorderSizePixel=0
            timeIcon.ZIndex=3
            timeIcon.Parent=innerTime
            table.insert(timeEntry.images, timeIcon)

            timeLbl=Instance.new("TextLabel")
            timeLbl.FontFace=FONT_BODY
            timeLbl.TextSize=TXT_SZ
            timeLbl.TextColor3=COL_TXT_MUTE
            timeLbl.BackgroundTransparency=1
            timeLbl.BorderSizePixel=0
            timeLbl.AutomaticSize=Enum.AutomaticSize.X
            timeLbl.Size=UDim2.fromOffset(0,BAR_H)
            timeLbl.TextXAlignment=Enum.TextXAlignment.Center
            timeLbl.Text="00:00"
            timeLbl.ZIndex=3
            timeLbl.Parent=innerTime
            table.insert(timeEntry.labels, timeLbl)
        end

        -- ════════════════════════════════════════════════════════════
        -- DRAWING PARTICLES
        --
        -- Drawing.Transparency:  0 = invisible, 1 = fully opaque
        -- Drawing.Position: SCREEN pixels (absolute, ignores UIScale of GUI)
        --
        -- IMPORTANT: AbsolutePosition of a Frame under a UIScale'd parent
        -- is ALREADY in screen coordinates (UIScale affects layout but
        -- AbsolutePosition reflects actual screen px). So particles
        -- should be placed at AbsolutePosition directly — NO extra offset.
        --
        -- Gradient: hue oscillates between blue (~0.61) and violet (~0.76)
        -- ════════════════════════════════════════════════════════════

        local drawObjs = {}
        local function D(t)
            local d = Drawing.new(t)
            d.Visible = true
            table.insert(drawObjs,d)
            return d
        end

        local P_COUNT      = 9
        local CONNECT_DIST = 58
        local SPEED_NEAR   = 20
        local SPEED_FAR    = 6
        local R_NEAR       = 2.2
        local R_FAR        = 0.8

        local globalHue    = 0.61   -- starts at blue, drifts to violet

        local function buildSys()
            local pts = {}
            for i = 1, P_COUNT do
                local p = {
                    x=0, y=0, vx=0, vy=0,
                    z   = rand(0,1),
                    phaseOff = rand(0, math.pi*2),   -- for pulse variation
                    dot = D("Circle"),
                }
                p.dot.Filled       = true
                p.dot.Color        = Color3.fromRGB(72,138,255)
                p.dot.Radius       = 1
                p.dot.Transparency = 0
                p.dot.NumSides     = 12
                p.dot.ZIndex       = 9
                pts[i] = p
            end
            local lines = {}
            for i = 1, P_COUNT do
                lines[i] = {}
                for j = i+1, P_COUNT do
                    local l = D("Line")
                    l.Thickness    = 1
                    l.Color        = Color3.fromRGB(72,138,255)
                    l.Transparency = 0
                    l.ZIndex       = 8
                    lines[i][j]    = l
                end
            end
            return {pts=pts, lines=lines, ready=false}
        end

        local function initSys(sys, ax, ay, aw, ah)
            for _, p in ipairs(sys.pts) do
                p.x = rand(ax+6, ax+aw-6)
                p.y = rand(ay+4, ay+ah-4)
                local spd   = lerp(SPEED_FAR,SPEED_NEAR,p.z)
                local angle = rand(0,math.pi*2)
                p.vx = math.cos(angle)*spd
                p.vy = math.sin(angle)*spd
            end
            sys.ready = true
        end

        -- hue: 0.61=blue, 0.76=violet
        local function hueToColor(h, z)
            -- z affects saturation and value slightly
            local sat = lerp(0.60, 0.90, z)
            local val = lerp(0.80, 1.00, z)
            return Color3.fromHSV(h % 1, sat, val)
        end

        local globalTime = 0

        local function tickSys(sys, dt, ax, ay, aw, ah, globalA)
            if not sys.ready then
                if aw > 8 then initSys(sys, ax, ay, aw, ah) end
                return
            end
            local pts = sys.pts

            for _, p in ipairs(pts) do
                p.x += p.vx*dt; p.y += p.vy*dt

                -- bounce walls
                local m = 4
                if p.x<ax+m     then p.x=ax+m;     p.vx= math.abs(p.vx) end
                if p.x>ax+aw-m  then p.x=ax+aw-m;  p.vx=-math.abs(p.vx) end
                if p.y<ay+m     then p.y=ay+m;      p.vy= math.abs(p.vy) end
                if p.y>ay+ah-m  then p.y=ay+ah-m;   p.vy=-math.abs(p.vy) end

                -- subtle speed variation (pulse)
                local pulse = 0.85 + 0.15*math.sin(globalTime*1.2 + p.phaseOff)
                p.vx = p.vx * (1 + (pulse-1)*dt*3)
                p.vy = p.vy * (1 + (pulse-1)*dt*3)
                -- clamp speed
                local spd = lerp(SPEED_FAR,SPEED_NEAR,p.z)
                local curSpd = math.sqrt(p.vx^2+p.vy^2)
                if curSpd > spd*1.3 then
                    local sc = spd*1.3/curSpd
                    p.vx*=sc; p.vy*=sc
                end

                local r       = lerp(R_FAR, R_NEAR, p.z)
                -- pulse radius slightly
                local pulseR  = r * (0.9 + 0.1*math.sin(globalTime*2.1 + p.phaseOff))
                local dotOpTgt = lerp(0.20, 0.65, p.z)
                local finalOp  = dotOpTgt * globalA

                -- gradient hue per particle (slightly different per phase)
                local ph = globalHue + 0.04*math.sin(p.phaseOff + globalTime*0.4)

                p.dot.Position     = Vector2.new(p.x, p.y)
                p.dot.Radius       = pulseR
                p.dot.Transparency = finalOp
                p.dot.Color        = hueToColor(ph, p.z)
            end

            for i = 1, #pts do
                for j = i+1, #pts do
                    local pi,pj = pts[i],pts[j]
                    local dx=pi.x-pj.x; local dy=pi.y-pj.y
                    local dist=math.sqrt(dx*dx+dy*dy)
                    local l=sys.lines[i][j]
                    if dist < CONNECT_DIST then
                        local prox = 1-dist/CONNECT_DIST
                        local avgZ = (pi.z+pj.z)*0.5
                        local lineOp = lerp(0.06,0.40,prox)*lerp(0.4,1,avgZ)*globalA
                        l.From=Vector2.new(pi.x,pi.y)
                        l.To  =Vector2.new(pj.x,pj.y)
                        l.Transparency=lineOp
                        l.Thickness=lerp(0.5,1.3,avgZ)
                        local ph2=(globalHue+(pi.z+pj.z)*0.05)%1
                        l.Color=hueToColor(ph2,avgZ)
                    else
                        l.Transparency=0
                    end
                end
            end
        end

        -- Build particle systems for chips that have meaningful size
        local entryToSys = {}
        entryToSys[titleEntry] = buildSys()
        if fpsEntry  then entryToSys[fpsEntry]  = buildSys() end
        if timeEntry then entryToSys[timeEntry] = buildSys() end

        -- ── Animation state ──────────────────────────────────────────
        local visible = true
        local alpha   = 0     -- 0→1
        local targetA = 1

        -- Spring for BOTH alpha and scale to avoid the pop-at-end
        -- We animate a single progress t∈[0,1]
        local springV = 0    -- velocity for spring
        local springP = 0    -- position (=alpha target)
        local SPRING_K = 14
        local SPRING_D = 0.72  -- damping (0..1 → springy; closer to 1 = overdamped=smooth)

        -- Drag state
        local isDragging  = false
        local dragStartMouse = Vector2.new(0,0)
        local dragStartAnchor = Vector2.new(posX, posY)
        -- Spring for drag offset (iOS easing: follows cursor with slight lag)
        local dragTargetX, dragTargetY = posX, posY
        local dragCurX,   dragCurY    = posX, posY
        local DRAG_SPRING = 16

        local logoAngle = 0
        local accentPh  = 0

        local FPS_N = 30
        local fpsBuf = table.create(FPS_N, 1/60)
        local fpsBufI = 1; local fpsTimer = 0; local lastMin = -1

        -- ── applyProgress ────────────────────────────────────────────
        -- p: 0=hidden, 1=visible
        local function applyProgress(p)
            -- UIScale: 0.80 → 1.0  (no jump because we start slightly below final)
            uiScale.Scale = lerp(0.80, SAFE_MIN, p)

            -- GUI elements (Roblox: 0=opaque, 1=transparent)
            local bgT  = lerp(1, BG_TRANSP, p)
            local txtT = lerp(1, 0, p)
            local strT = lerp(1, 0, p)

            for _, e in ipairs(allChips) do
                e.frame.BackgroundTransparency = bgT
                if e.stroke then e.stroke.Transparency = strT end
                for _, l in ipairs(e.labels) do l.TextTransparency  = txtT end
                for _, i in ipairs(e.images) do i.ImageTransparency = txtT end
            end

            for _, s in ipairs(logoSegs) do
                s.dot.BackgroundTransparency = lerp(1, 0.2, p)
            end

            accentLine.BackgroundTransparency = lerp(1,0,p)

            -- Drawing: hide all when invisible
            if p < 0.02 then
                for _, d in ipairs(drawObjs) do d.Transparency = 0 end
            end

            alpha = p
        end

        -- ── Heartbeat ────────────────────────────────────────────────
        local conn
        conn = RunService.Heartbeat:Connect(function(dt)
            globalTime = globalTime + dt

            -- Gradient hue drift: cycles between blue(0.61) and violet(0.76)
            globalHue = 0.61 + 0.075*(math.sin(globalTime*0.25)+1)*0.5

            -- ── spring animation for alpha ────────────────────────────
            local force  = SPRING_K*(targetA - springP) - SPRING_D*2*math.sqrt(SPRING_K)*springV
            springV = springV + force*dt
            springP = clamp(springP + springV*dt, 0, 1)
            if math.abs(springP-targetA)<0.003 and math.abs(springV)<0.003 then
                springP=targetA; springV=0
            end

            applyProgress(springP)
            gui.Enabled = springP > 0.01

            -- ── logo dots rotation ────────────────────────────────────
            logoAngle = (logoAngle + dt*40)%360
            local logoPulse = 0.85 + 0.15*math.sin(globalTime*2.5)
            for i, s in ipairs(logoSegs) do
                local baseA = math.rad((i-1)*(360/SEG_COUNT)) + math.rad(logoAngle)
                local r     = SEG_SZ/2 * logoPulse
                local dx    = math.cos(baseA)*r
                local dy    = math.sin(baseA)*r
                s.dot.Position = UDim2.new(0.5, math.round(dx), 0.5, math.round(dy))
                -- color gradient on dots
                local h = (globalHue + i/SEG_COUNT*0.08)%1
                s.dot.BackgroundColor3 = Color3.fromHSV(h, 0.8, 1)
            end

            -- ── accent underline ─────────────────────────────────────
            accentPh = (accentPh+dt*0.7)%(math.pi*2)
            local t  = (math.sin(accentPh)+1)*0.5
            accentLine.BackgroundColor3 = Color3.fromHSV(
                lerp(globalHue, globalHue+0.05, t)%1, 0.8, 1)
            -- match exact rendered text width
            local ts = titleLbl.AbsoluteSize
            if ts.X > 0 then
                accentLine.Size     = UDim2.fromOffset(ts.X, 1)
                accentLine.Position = UDim2.fromOffset(0, BAR_H-3)
            end

            -- ── drag spring ──────────────────────────────────────────
            if dragEnabled then
                dragCurX = lerp(dragCurX, dragTargetX, clamp(dt*DRAG_SPRING, 0, 1))
                dragCurY = lerp(dragCurY, dragTargetY, clamp(dt*DRAG_SPRING, 0, 1))
                anchor.Position = UDim2.fromOffset(math.round(dragCurX), math.round(dragCurY))
            end

            -- ── particles ────────────────────────────────────────────
            if springP > 0.03 then
                for entry, sys in pairs(entryToSys) do
                    local f  = entry.frame
                    local ap = f.AbsolutePosition
                    local as = f.AbsoluteSize
                    -- AbsolutePosition is already in screen pixels
                    -- Particles must live INSIDE the chip bounds
                    tickSys(sys, dt, ap.X, ap.Y, as.X, as.Y, springP)
                end
            end

            -- ── FPS ──────────────────────────────────────────────────
            if fpsLbl then
                fpsBuf[fpsBufI]=dt; fpsBufI=(fpsBufI%FPS_N)+1
                fpsTimer+=dt
                if fpsTimer>=0.25 then
                    fpsTimer=0
                    local sum=0 for i=1,FPS_N do sum+=fpsBuf[i] end
                    fpsLbl.Text=tostring(sum>0 and math.round(FPS_N/sum) or 0)
                end
            end

            -- ── Time ─────────────────────────────────────────────────
            if timeLbl then
                local now=os.time(); local cm=math.floor(now/60)
                if cm~=lastMin then
                    lastMin=cm
                    timeLbl.Text=string.format("%02d:%02d",math.floor(now/3600)%24,cm%60)
                end
            end
        end)

        -- ── Drag input ───────────────────────────────────────────────
        local dragConn1, dragConn2
        local function setupDrag()
            local function getMousePos()
                local mp = UIS:GetMouseLocation()
                return Vector2.new(mp.X, mp.Y)
            end

            row.InputBegan:Connect(function(inp)
                if not dragEnabled then return end
                if inp.UserInputType == Enum.UserInputType.MouseButton1
                or inp.UserInputType == Enum.UserInputType.Touch then
                    isDragging       = true
                    dragStartMouse   = getMousePos()
                    dragStartAnchor  = Vector2.new(dragCurX, dragCurY)
                end
            end)

            dragConn1 = UIS.InputChanged:Connect(function(inp)
                if not isDragging or not dragEnabled then return end
                if inp.UserInputType == Enum.UserInputType.MouseMovement
                or inp.UserInputType == Enum.UserInputType.Touch then
                    local cur = getMousePos()
                    local dx  = cur.X - dragStartMouse.X
                    local dy  = cur.Y - dragStartMouse.Y
                    dragTargetX = dragStartAnchor.X + dx
                    dragTargetY = dragStartAnchor.Y + dy
                end
            end)

            dragConn2 = UIS.InputEnded:Connect(function(inp)
                if inp.UserInputType == Enum.UserInputType.MouseButton1
                or inp.UserInputType == Enum.UserInputType.Touch then
                    isDragging = false
                end
            end)
        end
        setupDrag()

        -- ── initial alpha ────────────────────────────────────────────
        applyProgress(0)
        targetA = 1

        -- ── Built-in position helpers ────────────────────────────────
        local MARGIN = 22

        local function setPos(x,y)
            dragTargetX=x; dragTargetY=y
            dragCurX=x;    dragCurY=y
            anchor.Position=UDim2.fromOffset(x,y)
        end

        local function getBarW()
            -- row.AbsoluteSize is in screen px after UIScale
            return row.AbsoluteSize.X
        end

        local function moveTopLeft()
            setPos(104, MARGIN)
        end

        local function moveTopRight()
            task.defer(function()
                local vp = workspace.CurrentCamera.ViewportSize
                local w  = getBarW()
                setPos(vp.X - w - MARGIN, MARGIN)
            end)
        end

        local function moveBottomLeft()
            task.defer(function()
                local vp = workspace.CurrentCamera.ViewportSize
                setPos(104, vp.Y - (BAR_H + 8)*SAFE_MIN - MARGIN)
            end)
        end

        local function moveBottomRight()
            task.defer(function()
                local vp = workspace.CurrentCamera.ViewportSize
                local w  = getBarW()
                setPos(vp.X - w - MARGIN, vp.Y - (BAR_H + 8)*SAFE_MIN - MARGIN)
            end)
        end

        -- ── Public API ───────────────────────────────────────────────
        local WM = {}
        function WM:Show()       targetA=1 end
        function WM:Hide()       targetA=0 end
        function WM:Toggle()     if targetA>0.5 then self:Hide() else self:Show() end end
        function WM:IsVisible()  return targetA>0.5 end
        function WM:SetTitle(txt) titleText=txt; titleLbl.Text=txt end

        function WM:SetPosition(pos)
            local x,y
            if typeof(pos)=="UDim2" then x=pos.X.Offset; y=pos.Y.Offset
            elseif typeof(pos)=="Vector2" then x=pos.X; y=pos.Y end
            if x then setPos(x,y) end
        end

        function WM:MoveTopLeft()     moveTopLeft()     end
        function WM:MoveTopRight()    moveTopRight()    end
        function WM:MoveBottomLeft()  moveBottomLeft()  end
        function WM:MoveBottomRight() moveBottomRight() end

        function WM:SetDrag(state)
            dragEnabled = state
            if not state and dragConn1 then
                dragConn1:Disconnect(); dragConn2:Disconnect()
                dragConn1=nil; dragConn2=nil
            elseif state and not dragConn1 then
                setupDrag()
            end
        end
        function WM:IsDragEnabled() return dragEnabled end

        function WM:Destroy()
            conn:Disconnect()
            if dragConn1 then dragConn1:Disconnect() end
            if dragConn2 then dragConn2:Disconnect() end
            for _, d in ipairs(drawObjs) do pcall(function() d:Remove() end) end
            gui:Destroy()
        end

        return WM
    end

    if ctx.onLoad then ctx.onLoad() end
end
