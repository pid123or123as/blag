-- Watermark_PreLoader.lua  (v9)
-- ROOT CAUSE FIX: particles stuck at (0,0) because AbsoluteSize=0 on first frames
-- (AutomaticSize frames need 1+ frames to compute size).
-- Fix: each particle system stores bounds independently, re-inits when size becomes valid.
-- Particles use AbsolutePosition which IS correct screen coords for Drawing.
-- Logo: 10 dots, slower smoother rotation (RunService.RenderStepped for logo only).

return function(ctx)
    local MacLib = ctx.MacLib
    local RunService = game:GetService("RunService")
    local UIS        = game:GetService("UserInputService")
    local isMobile   = UIS.TouchEnabled and not UIS.KeyboardEnabled

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

        -- Customisation options (can be changed at runtime via WM:SetParticleColor etc.)
        local particleColor1 = cfg.ParticleColor1 or Color3.fromRGB(72,138,255)  -- blue
        local particleColor2 = cfg.ParticleColor2 or Color3.fromRGB(140,90,255)  -- violet
        local particleCount  = cfg.ParticleCount  or 9
        local connectDist    = cfg.ConnectDist    or 58

        local posX, posY = 104, 8
        if cfg.Position then
            if typeof(cfg.Position)=="UDim2" then
                posX=cfg.Position.X.Offset; posY=cfg.Position.Y.Offset
            elseif typeof(cfg.Position)=="Vector2" then
                posX=cfg.Position.X; posY=cfg.Position.Y
            end
        end

        -- ── Root GUI ─────────────────────────────────────────────────
        local gui = GetGui(); gui.Name = "MacLibWatermark"

        local anchor = Instance.new("Frame")
        anchor.Name                   = "WmAnchor"
        anchor.BackgroundTransparency = 1
        anchor.BorderSizePixel        = 0
        anchor.AutomaticSize          = Enum.AutomaticSize.XY
        anchor.AnchorPoint            = Vector2.new(0,0)
        anchor.Position               = UDim2.fromOffset(posX, posY)
        anchor.Parent                 = gui

        local uiScale = Instance.new("UIScale")
        uiScale.Scale  = 0.80
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
        local SEG_SZ  = 14
        local TXT_SZ  = 12
        local ICON_SZ = 13
        local PAD_X   = 10

        local FONT_TITLE = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.SemiBold)
        local FONT_BODY  = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Medium)

        local COL_BG_DARK  = Color3.fromRGB(12,12,19)
        local COL_BG_CHIP  = Color3.fromRGB(10,10,16)
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
                stroke.Color     = COL_STROKE
                stroke.Transparency = 0
                stroke.Thickness = 1
                stroke.Parent    = f
            end
            if opts.padX ~= false then
                local pad = Instance.new("UIPadding")
                pad.PaddingLeft  = UDim.new(0, opts.padX or PAD_X)
                pad.PaddingRight = UDim.new(0, opts.padX or PAD_X)
                pad.Parent = f
            end
            local entry = {frame=f, stroke=stroke, labels={}, images={}}
            table.insert(allChips, entry)
            return entry
        end

        -- ── LOGO chip (10 dots, smooth) ───────────────────────────────
        local logoEntry = makeChip({
            bg=COL_BG_DARK, fixedW=LOGO_SZ, h=LOGO_SZ,
            radius=9, stroke=false, padX=false,
        })

        local logoHolder = Instance.new("Frame")
        logoHolder.Name = "LogoHolder"
        logoHolder.AnchorPoint = Vector2.new(0.5,0.5)
        logoHolder.Position    = UDim2.new(0.5,0,0.5,0)
        logoHolder.Size        = UDim2.fromOffset(SEG_SZ,SEG_SZ)
        logoHolder.BackgroundTransparency = 1
        logoHolder.BorderSizePixel = 0
        logoHolder.Parent = logoEntry.frame

        local SEG_COUNT   = 10
        local DOT_SZ      = 3
        local logoSegs    = {}
        local logoAngleSm = 0   -- smooth angle (we interpolate towards target)
        local logoAngleTg = 0   -- target angle (advances at constant rate)

        for i = 1, SEG_COUNT do
            local dot = Instance.new("Frame")
            dot.Size               = UDim2.fromOffset(DOT_SZ, DOT_SZ)
            dot.AnchorPoint        = Vector2.new(0.5,0.5)
            dot.Position           = UDim2.new(0.5,0,0.5,0)
            dot.BackgroundColor3   = particleColor1
            dot.BackgroundTransparency = 0.2
            dot.BorderSizePixel    = 0
            dot.ZIndex             = 3
            dot.Parent             = logoHolder
            Instance.new("UICorner", dot).CornerRadius = UDim.new(1,0)
            table.insert(logoSegs, {dot=dot, idx=i})
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
        titleLbl.Size                   = UDim2.fromOffset(0, BAR_H)
        titleLbl.TextXAlignment         = Enum.TextXAlignment.Left
        titleLbl.Text                   = titleText
        titleLbl.ZIndex                 = 3
        titleLbl.Parent                 = titleEntry.frame
        table.insert(titleEntry.labels, titleLbl)

        local accentLine = Instance.new("Frame")
        accentLine.Name                   = "AccentLine"
        accentLine.BackgroundColor3       = particleColor1
        accentLine.BackgroundTransparency = 0
        accentLine.BorderSizePixel        = 0
        accentLine.ZIndex                 = 6
        accentLine.Size                   = UDim2.fromOffset(40,1)
        accentLine.Position               = UDim2.fromOffset(0, BAR_H-3)
        accentLine.Parent                 = titleEntry.frame

        -- ── FPS chip ─────────────────────────────────────────────────
        local fpsEntry, fpsLbl
        if showFPS then
            fpsEntry = makeChip({fixedW=76, stroke=true, padX=false})
            local inner = Instance.new("Frame")
            inner.BackgroundTransparency=1; inner.BorderSizePixel=0
            inner.AnchorPoint=Vector2.new(0.5,0.5)
            inner.Position=UDim2.new(0.5,0,0.5,0)
            inner.AutomaticSize=Enum.AutomaticSize.XY
            inner.Parent=fpsEntry.frame
            local il=Instance.new("UIListLayout")
            il.FillDirection=Enum.FillDirection.Horizontal
            il.VerticalAlignment=Enum.VerticalAlignment.Center
            il.Padding=UDim.new(0,5); il.Parent=inner

            local fpsIcon=Instance.new("ImageLabel")
            fpsIcon.Image="rbxassetid://102994395432803"
            fpsIcon.Size=UDim2.fromOffset(ICON_SZ,ICON_SZ)
            fpsIcon.BackgroundTransparency=1; fpsIcon.BorderSizePixel=0
            fpsIcon.ZIndex=3; fpsIcon.Parent=inner
            table.insert(fpsEntry.images, fpsIcon)

            fpsLbl=Instance.new("TextLabel")
            fpsLbl.FontFace=FONT_BODY; fpsLbl.TextSize=TXT_SZ
            fpsLbl.TextColor3=COL_TXT_MUTE; fpsLbl.BackgroundTransparency=1
            fpsLbl.BorderSizePixel=0; fpsLbl.AutomaticSize=Enum.AutomaticSize.X
            fpsLbl.Size=UDim2.fromOffset(0,BAR_H)
            fpsLbl.TextXAlignment=Enum.TextXAlignment.Center
            fpsLbl.Text="--"; fpsLbl.ZIndex=3; fpsLbl.Parent=inner
            table.insert(fpsEntry.labels, fpsLbl)
        end

        -- ── TIME chip ────────────────────────────────────────────────
        local timeEntry, timeLbl
        if showTime then
            timeEntry = makeChip({fixedW=92, stroke=true, padX=false})
            local inner = Instance.new("Frame")
            inner.BackgroundTransparency=1; inner.BorderSizePixel=0
            inner.AnchorPoint=Vector2.new(0.5,0.5)
            inner.Position=UDim2.new(0.5,0,0.5,0)
            inner.AutomaticSize=Enum.AutomaticSize.XY
            inner.Parent=timeEntry.frame
            local il=Instance.new("UIListLayout")
            il.FillDirection=Enum.FillDirection.Horizontal
            il.VerticalAlignment=Enum.VerticalAlignment.Center
            il.Padding=UDim.new(0,5); il.Parent=inner

            local timeIcon=Instance.new("ImageLabel")
            timeIcon.Image="rbxassetid://17824308575"
            timeIcon.Size=UDim2.fromOffset(ICON_SZ,ICON_SZ)
            timeIcon.BackgroundTransparency=1; timeIcon.BorderSizePixel=0
            timeIcon.ZIndex=3; timeIcon.Parent=inner
            table.insert(timeEntry.images, timeIcon)

            timeLbl=Instance.new("TextLabel")
            timeLbl.FontFace=FONT_BODY; timeLbl.TextSize=TXT_SZ
            timeLbl.TextColor3=COL_TXT_MUTE; timeLbl.BackgroundTransparency=1
            timeLbl.BorderSizePixel=0; timeLbl.AutomaticSize=Enum.AutomaticSize.X
            timeLbl.Size=UDim2.fromOffset(0,BAR_H)
            timeLbl.TextXAlignment=Enum.TextXAlignment.Center
            timeLbl.Text="00:00"; timeLbl.ZIndex=3; timeLbl.Parent=inner
            table.insert(timeEntry.labels, timeLbl)
        end

        -- ════════════════════════════════════════════════════════════════
        -- DRAWING PARTICLES
        --
        -- KEY INSIGHT: Drawing uses raw SCREEN pixels.
        -- AbsolutePosition of a GUI Frame is also in screen pixels.
        -- They match directly — no compensation needed.
        --
        -- BUG FIX: AutomaticSize frames have AbsoluteSize=0 for 1-2 frames.
        -- We store a "ready" flag per system and WAIT until AbsoluteSize.X > 8
        -- before spawning particles. Each particle system is independent.
        --
        -- STUCK BUG FIX: p.vx/vy=0 initially, initSys sets them.
        -- If initSys never runs, particles stay at x=0,y=0 → drawn at top-left.
        -- ════════════════════════════════════════════════════════════════

        local drawObjs = {}
        local function D(t)
            local d = Drawing.new(t)
            d.Visible = true
            table.insert(drawObjs,d)
            return d
        end

        -- Color interpolation between the two particle colors
        local globalT    = 0   -- 0→1→0 cycling (gradient phase)
        local globalTime = 0

        local function getParticleColor(t, z)
            -- t: gradient phase 0-1, z: depth 0(far)-1(near)
            local r = math.round(lerp(particleColor1.R*255, particleColor2.R*255, t))
            local g = math.round(lerp(particleColor1.G*255, particleColor2.G*255, t))
            local b = math.round(lerp(particleColor1.B*255, particleColor2.B*255, t))
            -- near particles slightly brighter
            local bright = lerp(0.75, 1.0, z)
            return Color3.fromRGB(
                math.round(clamp(r*bright, 0, 255)),
                math.round(clamp(g*bright, 0, 255)),
                math.round(clamp(b*bright, 0, 255))
            )
        end

        local SPEED_NEAR = 18
        local SPEED_FAR  = 5
        local R_NEAR     = 2.2
        local R_FAR      = 0.8

        local function buildSys(n)
            local pts = {}
            for i = 1, n do
                local p = {
                    x=0, y=0, vx=0, vy=0,
                    z        = rand(0,1),
                    phaseOff = rand(0, math.pi*2),
                    dot      = D("Circle"),
                }
                p.dot.Filled       = true
                p.dot.Color        = particleColor1
                p.dot.Radius       = 1
                p.dot.Transparency = 0   -- invisible until init (0=transparent in Drawing)
                p.dot.NumSides     = 12
                p.dot.ZIndex       = 9
                pts[i] = p
            end
            local lines = {}
            for i = 1, n do
                lines[i] = {}
                for j = i+1, n do
                    local l = D("Line")
                    l.Thickness    = 1
                    l.Color        = particleColor1
                    l.Transparency = 0
                    l.ZIndex       = 8
                    lines[i][j]    = l
                end
            end
            return {pts=pts, lines=lines, ready=false, n=n}
        end

        local function initSys(sys, ax, ay, aw, ah)
            for _, p in ipairs(sys.pts) do
                p.x = rand(ax+6, ax+aw-6)
                p.y = rand(ay+4, ay+ah-4)
                local spd   = lerp(SPEED_FAR, SPEED_NEAR, p.z)
                local angle = rand(0, math.pi*2)
                p.vx = math.cos(angle)*spd
                p.vy = math.sin(angle)*spd
            end
            sys.ready = true
            sys.ax,sys.ay,sys.aw,sys.ah = ax,ay,aw,ah
        end

        local function tickSys(sys, dt, ax, ay, aw, ah, globalAlpha)
            -- Re-init if frame bounds changed significantly (e.g. after drag)
            if not sys.ready then return end
            if math.abs((sys.ax or 0)-ax)>5 or math.abs((sys.ay or 0)-ay)>5 then
                -- bounds shifted (drag) — teleport particles to new region
                local dx = ax - (sys.ax or ax)
                local dy = ay - (sys.ay or ay)
                for _, p in ipairs(sys.pts) do
                    p.x += dx; p.y += dy
                    -- clamp into new bounds
                    p.x = clamp(p.x, ax+4, ax+aw-4)
                    p.y = clamp(p.y, ay+4, ay+ah-4)
                end
                sys.ax,sys.ay,sys.aw,sys.ah = ax,ay,aw,ah
            end
            sys.ax,sys.ay = ax,ay

            local pts = sys.pts
            for _, p in ipairs(pts) do
                p.x += p.vx*dt; p.y += p.vy*dt
                -- bounce
                local m=4
                if p.x<ax+m    then p.x=ax+m;    p.vx= math.abs(p.vx) end
                if p.x>ax+aw-m then p.x=ax+aw-m; p.vx=-math.abs(p.vx) end
                if p.y<ay+m    then p.y=ay+m;    p.vy= math.abs(p.vy) end
                if p.y>ay+ah-m then p.y=ay+ah-m; p.vy=-math.abs(p.vy) end

                -- subtle speed pulse
                local pulse = 0.88+0.12*math.sin(globalTime*1.1+p.phaseOff)
                local spd   = lerp(SPEED_FAR,SPEED_NEAR,p.z)
                local curSpd= math.sqrt(p.vx^2+p.vy^2)
                if curSpd>0.1 then
                    local target = spd*pulse
                    local sc = lerp(1, target/curSpd, dt*2)
                    p.vx*=sc; p.vy*=sc
                end

                local r       = lerp(R_FAR,R_NEAR,p.z)
                local pulseR  = r*(0.88+0.12*math.sin(globalTime*1.8+p.phaseOff))
                local baseOp  = lerp(0.18,0.60,p.z)
                local finalOp = baseOp*globalAlpha

                -- per-particle gradient phase offset
                local pT = (globalT + p.phaseOff/(math.pi*2)*0.3)%1

                p.dot.Position     = Vector2.new(p.x, p.y)
                p.dot.Radius       = pulseR
                p.dot.Transparency = finalOp
                p.dot.Color        = getParticleColor(pT, p.z)
            end

            for i=1,#pts do
                for j=i+1,#pts do
                    local pi,pj = pts[i],pts[j]
                    local dx=pi.x-pj.x; local dy=pi.y-pj.y
                    local dist=math.sqrt(dx*dx+dy*dy)
                    local l=sys.lines[i][j]
                    if dist < connectDist then
                        local prox = 1-dist/connectDist
                        local avgZ = (pi.z+pj.z)*0.5
                        local lineOp=lerp(0.05,0.35,prox)*lerp(0.35,1,avgZ)*globalAlpha
                        l.From=Vector2.new(pi.x,pi.y)
                        l.To  =Vector2.new(pj.x,pj.y)
                        l.Transparency=lineOp
                        l.Thickness=lerp(0.4,1.2,avgZ)
                        l.Color=getParticleColor(globalT, avgZ)
                    else
                        l.Transparency=0
                    end
                end
            end
        end

        -- systems built AFTER chips
        local entryToSys = {}
        entryToSys[titleEntry] = buildSys(particleCount)
        if fpsEntry  then entryToSys[fpsEntry]  = buildSys(particleCount) end
        if timeEntry then entryToSys[timeEntry] = buildSys(particleCount) end

        -- ════════════════════════════════════════════════════════════════
        -- Deferred init: wait until frames have valid AbsoluteSize
        -- Run in a separate task so it doesn't block the heartbeat
        -- ════════════════════════════════════════════════════════════════
        task.spawn(function()
            local waited = 0
            while waited < 3 do
                task.wait(0.05); waited+=0.05
                local allReady = true
                for entry, sys in pairs(entryToSys) do
                    if not sys.ready then
                        local f  = entry.frame
                        local ap = f.AbsolutePosition
                        local as = f.AbsoluteSize
                        if as.X > 8 and as.Y > 4 then
                            initSys(sys, ap.X, ap.Y, as.X, as.Y)
                        else
                            allReady = false
                        end
                    end
                end
                if allReady then break end
            end
        end)

        -- ── Animation spring ─────────────────────────────────────────
        local springP  = 0
        local springV  = 0
        local targetA  = 1
        local SPRING_K = 120
        local SPRING_D = 16   -- critically-damped: D = 2*sqrt(K) = 2*sqrt(120) ≈ 21.9
                              -- use 16 for slight overshoot (feels alive)

        -- Drag spring
        local dragEnabled_    = dragEnabled
        local dragTargetX     = posX; local dragTargetY = posY
        local dragCurX        = posX; local dragCurY    = posY
        local isDragging      = false
        local dragStartMouse  = Vector2.new(0,0)
        local dragStartAnchor = Vector2.new(posX,posY)
        local DRAG_SPRING     = 18

        local accentPh = 0
        local FPS_N    = 30
        local fpsBuf   = table.create(FPS_N,1/60)
        local fpsBufI  = 1; local fpsTimer=0; local lastMin=-1

        -- ── applyProgress ────────────────────────────────────────────
        local function applyProgress(p)
            uiScale.Scale = lerp(0.80, 1.0, p)
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
                s.dot.BackgroundTransparency = lerp(1, 0.15, p)
            end
            accentLine.BackgroundTransparency = lerp(1,0,p)
            if p < 0.02 then
                for _, d in ipairs(drawObjs) do d.Transparency=0 end
            end
        end

        -- ── Heartbeat ────────────────────────────────────────────────
        local conns = {}

        -- Logo uses RenderStepped for smoothest rotation (60fps guaranteed)
        table.insert(conns, RunService.RenderStepped:Connect(function(dt)
            -- advance target angle smoothly
            logoAngleTg = logoAngleTg + dt*25   -- deg/s (slow)
            -- smooth follow with lerp (spring-like, no jitter)
            logoAngleSm = logoAngleSm + (logoAngleTg - logoAngleSm)*(1-math.exp(-dt*10))

            local pulse = 0.88+0.12*math.sin(globalTime*1.4)
            for i, s in ipairs(logoSegs) do
                local baseA = math.rad((i-1)*(360/SEG_COUNT)) + math.rad(logoAngleSm)
                local r     = SEG_SZ/2 * pulse
                s.dot.Position = UDim2.new(0.5, math.round(math.cos(baseA)*r),
                                           0.5, math.round(math.sin(baseA)*r))
                s.dot.BackgroundColor3 = getParticleColor(
                    (globalT + (i-1)/SEG_COUNT*0.25)%1, (i-1)/SEG_COUNT)
            end
        end))

        table.insert(conns, RunService.Heartbeat:Connect(function(dt)
            globalTime = globalTime + dt
            -- gradient phase: cycles 0→1→0 every ~8s
            globalT = (math.sin(globalTime*0.39)+1)*0.5

            -- spring animation
            local force  = SPRING_K*(targetA-springP) - SPRING_D*springV
            springV = springV + force*dt
            springP = clamp(springP+springV*dt, 0, 1)
            if math.abs(springP-targetA)<0.003 and math.abs(springV)<0.003 then
                springP=targetA; springV=0
            end

            applyProgress(springP)
            gui.Enabled = springP > 0.008

            -- accent underline
            accentPh=(accentPh+dt*0.6)%(math.pi*2)
            accentLine.BackgroundColor3 = getParticleColor((math.sin(accentPh)+1)*0.5, 0.5)
            local ts = titleLbl.AbsoluteSize
            if ts.X > 0 then
                accentLine.Size     = UDim2.fromOffset(ts.X, 1)
                accentLine.Position = UDim2.fromOffset(0, BAR_H-3)
            end

            -- drag spring position
            if dragEnabled_ then
                dragCurX = lerp(dragCurX, dragTargetX, clamp(dt*DRAG_SPRING,0,1))
                dragCurY = lerp(dragCurY, dragTargetY, clamp(dt*DRAG_SPRING,0,1))
                anchor.Position = UDim2.fromOffset(math.round(dragCurX), math.round(dragCurY))
            end

            -- particles
            if springP > 0.03 then
                for entry, sys in pairs(entryToSys) do
                    local f  = entry.frame
                    local ap = f.AbsolutePosition
                    local as = f.AbsoluteSize
                    if sys.ready and as.X > 8 then
                        tickSys(sys, dt, ap.X, ap.Y, as.X, as.Y, springP)
                    end
                end
            end

            -- FPS
            if fpsLbl then
                fpsBuf[fpsBufI]=dt; fpsBufI=(fpsBufI%FPS_N)+1
                fpsTimer+=dt
                if fpsTimer>=0.25 then
                    fpsTimer=0
                    local sum=0 for i=1,FPS_N do sum+=fpsBuf[i] end
                    fpsLbl.Text=tostring(sum>0 and math.round(FPS_N/sum) or 0)
                end
            end

            -- Time
            if timeLbl then
                local now=os.time(); local cm=math.floor(now/60)
                if cm~=lastMin then
                    lastMin=cm
                    timeLbl.Text=string.format("%02d:%02d",math.floor(now/3600)%24,cm%60)
                end
            end
        end))

        -- ── Drag input ───────────────────────────────────────────────
        local dragInputConns = {}
        local function setupDrag()
            local function getMP()
                local mp=UIS:GetMouseLocation()
                return Vector2.new(mp.X,mp.Y)
            end
            table.insert(dragInputConns, row.InputBegan:Connect(function(inp)
                if not dragEnabled_ then return end
                if inp.UserInputType==Enum.UserInputType.MouseButton1
                or inp.UserInputType==Enum.UserInputType.Touch then
                    isDragging=true
                    dragStartMouse=getMP()
                    dragStartAnchor=Vector2.new(dragCurX,dragCurY)
                end
            end))
            table.insert(dragInputConns, UIS.InputChanged:Connect(function(inp)
                if not isDragging or not dragEnabled_ then return end
                if inp.UserInputType==Enum.UserInputType.MouseMovement
                or inp.UserInputType==Enum.UserInputType.Touch then
                    local cur=getMP()
                    dragTargetX=dragStartAnchor.X+(cur.X-dragStartMouse.X)
                    dragTargetY=dragStartAnchor.Y+(cur.Y-dragStartMouse.Y)
                end
            end))
            table.insert(dragInputConns, UIS.InputEnded:Connect(function(inp)
                if inp.UserInputType==Enum.UserInputType.MouseButton1
                or inp.UserInputType==Enum.UserInputType.Touch then
                    isDragging=false
                end
            end))
        end
        setupDrag()

        applyProgress(0); targetA=1

        -- ── Position helpers ─────────────────────────────────────────
        local MARGIN = 22
        local function setPos(x,y)
            dragTargetX=x; dragTargetY=y; dragCurX=x; dragCurY=y
            anchor.Position=UDim2.fromOffset(x,y)
        end
        local function waitAndSetPos(fn)
            task.defer(function()
                task.wait() -- 1 frame for AutomaticSize
                fn()
            end)
        end

        -- ── Rebuild particle systems ──────────────────────────────────
        local function rebuildParticles(n, cd)
            -- remove old drawObjs
            for _, d in ipairs(drawObjs) do pcall(function() d:Remove() end) end
            drawObjs = {}
            -- rebuild
            entryToSys[titleEntry] = buildSys(n)
            if fpsEntry  then entryToSys[fpsEntry]  = buildSys(n) end
            if timeEntry then entryToSys[timeEntry] = buildSys(n) end
            particleCount = n
            connectDist   = cd or connectDist
            -- re-init
            task.spawn(function()
                local waited=0
                while waited<3 do
                    task.wait(0.05); waited+=0.05
                    local allReady=true
                    for entry, sys in pairs(entryToSys) do
                        if not sys.ready then
                            local f=entry.frame
                            local ap=f.AbsolutePosition
                            local as=f.AbsoluteSize
                            if as.X>8 then initSys(sys,ap.X,ap.Y,as.X,as.Y)
                            else allReady=false end
                        end
                    end
                    if allReady then break end
                end
            end)
        end

        -- ── Public API ───────────────────────────────────────────────
        local WM = {}
        function WM:Show()      targetA=1 end
        function WM:Hide()      targetA=0 end
        function WM:Toggle()    if targetA>0.5 then self:Hide() else self:Show() end end
        function WM:IsVisible() return targetA>0.5 end
        function WM:SetTitle(txt) titleText=txt; titleLbl.Text=txt end

        function WM:SetPosition(pos)
            if typeof(pos)=="UDim2" then setPos(pos.X.Offset,pos.Y.Offset)
            elseif typeof(pos)=="Vector2" then setPos(pos.X,pos.Y) end
        end
        function WM:MoveTopLeft()
            setPos(104, MARGIN)
        end
        function WM:MoveTopRight()
            waitAndSetPos(function()
                local vp=workspace.CurrentCamera.ViewportSize
                setPos(vp.X - row.AbsoluteSize.X - MARGIN, MARGIN)
            end)
        end
        function WM:MoveBottomLeft()
            waitAndSetPos(function()
                local vp=workspace.CurrentCamera.ViewportSize
                setPos(104, vp.Y - row.AbsoluteSize.Y - MARGIN)
            end)
        end
        function WM:MoveBottomRight()
            waitAndSetPos(function()
                local vp=workspace.CurrentCamera.ViewportSize
                setPos(vp.X - row.AbsoluteSize.X - MARGIN, vp.Y - row.AbsoluteSize.Y - MARGIN)
            end)
        end

        function WM:SetDrag(state)
            dragEnabled_ = state
            if not state then isDragging=false end
        end
        function WM:IsDragEnabled() return dragEnabled_ end

        -- Particle customisation
        function WM:SetParticleColors(c1, c2)
            particleColor1 = c1 or particleColor1
            particleColor2 = c2 or particleColor2
        end
        function WM:SetParticleCount(n, cd)
            n = math.clamp(math.round(n), 2, 30)
            rebuildParticles(n, cd)
        end
        function WM:SetConnectDist(d)
            connectDist = d
        end
        function WM:SetParticleSpeed(near, far)
            SPEED_NEAR = near or SPEED_NEAR
            SPEED_FAR  = far  or SPEED_FAR
        end

        function WM:Destroy()
            for _, c in ipairs(conns) do c:Disconnect() end
            for _, c in ipairs(dragInputConns) do c:Disconnect() end
            for _, d in ipairs(drawObjs) do pcall(function() d:Remove() end) end
            gui:Destroy()
        end

        return WM
    end

    if ctx.onLoad then ctx.onLoad() end
end
