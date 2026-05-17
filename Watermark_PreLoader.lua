-- Watermark_PreLoader.lua  (v11)
-- CHANGES from v10:
--   • Orbit outline: lines connect BETWEEN the logo segments (dots),
--     not around the chip background. Lines go dot-to-dot in sequence,
--     forming an organic (non-uniform) polygon that follows the actual
--     dot positions — intentionally uneven.
--   • ParticleYOffset removed (was hardcoded 28). The fixed offset of
--     28px is now baked into the coordinate read directly.
--     particles use chip.AbsolutePosition + 28 as the screen Y base.
--     (If this is still wrong, use WM:SetParticleYOffset(n) — kept as API)
--   • Particle transparency: default baseOp raised (less visible), plus
--     WM:SetParticleAlpha(n) / Demo slider "Particle Opacity" (0–1)
--   • Logo chip also gets its own particle system (same as title/fps/time chips)
--   • Extra particles: "Particle Density" slider — adds a second, sparser
--     independent particle layer on top of the base layer (different speeds,
--     larger dots). Each chip has TWO independent particle systems.
--   • Top-left position: more left AND lower  (X=88, Y=42)
--   • Bottom-left position: further left (X=96 → 80)

return function(ctx)
    local MacLib     = ctx.MacLib
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
        local titleText   = cfg.Title    or "Watermark"
        local showFPS     = cfg.ShowFPS  ~= false
        local showTime    = cfg.ShowTime ~= false
        local dragEnabled_ = (cfg.Drag ~= nil) and cfg.Drag or (not isMobile)

        local particleColor1 = cfg.ParticleColor1 or Color3.fromRGB(72, 138, 255)
        local particleColor2 = cfg.ParticleColor2 or Color3.fromRGB(140, 90, 255)
        local particleCount  = cfg.ParticleCount  or 9
        local connectDist    = cfg.ConnectDist    or 58
        -- baked offset: 28px to account for GuiInset in the coordinate system
        local particleYOffset = cfg.ParticleYOffset or 28
        -- base opacity multiplier for all particles (0=invisible, 1=full)
        local globalParticleAlpha = cfg.ParticleAlpha or 0.45

        local posX, posY = 104, 22
        if cfg.Position then
            if typeof(cfg.Position)=="UDim2" then
                posX=cfg.Position.X.Offset; posY=cfg.Position.Y.Offset
            elseif typeof(cfg.Position)=="Vector2" then
                posX=cfg.Position.X; posY=cfg.Position.Y
            end
        end

        local MARGIN   = 22
        local UI_SCALE = 0.80

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
        uiScale.Scale  = UI_SCALE
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

        -- ── LOGO chip ─────────────────────────────────────────────────
        local logoEntry = makeChip({
            bg=COL_BG_DARK, fixedW=LOGO_SZ, h=LOGO_SZ,
            radius=9, stroke=false, padX=false,
        })

        local logoHolder = Instance.new("Frame")
        logoHolder.Name = "LogoHolder"
        logoHolder.AnchorPoint = Vector2.new(0.5,0.5)
        logoHolder.Position    = UDim2.new(0.5,0,0.5,0)
        logoHolder.Size        = UDim2.fromOffset(18,18)
        logoHolder.BackgroundTransparency = 1
        logoHolder.BorderSizePixel = 0
        logoHolder.Parent = logoEntry.frame

        -- Logo state
        local SEG_COUNT   = cfg.SegmentCount or 10
        local DOT_SZ      = 2.5
        local LOGO_R      = 7
        local logoSegs    = {}
        local logoAngleSm = 0
        local logoAngleTg = 0
        local onThePlane  = false

        local function rebuildLogoSegs(n)
            for _, s in ipairs(logoSegs) do s.dot:Destroy() end
            logoSegs = {}
            for i = 1, n do
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
        end
        rebuildLogoSegs(SEG_COUNT)

        -- ── Orbit outline: Drawing Lines connecting the logo DOTS ─────
        -- Lines go between consecutive logo segments (dot to dot),
        -- forming a polygon that follows the actual dot screen positions.
        -- Since dots move on a (possibly tilted) orbit, the polygon is
        -- intentionally uneven — that's the designed aesthetic.
        -- We also close the loop (last dot → first dot).
        local orbitLines  = {}
        local orbitEnabled = true
        local drawObjs    = {}

        local function D(t)
            local d = Drawing.new(t)
            d.Visible = true
            table.insert(drawObjs, d)
            return d
        end

        local function buildOrbitLines(n)
            for _, l in ipairs(orbitLines) do pcall(function() l:Remove() end) end
            orbitLines = {}
            -- n segments need n lines (one per adjacent pair, loop closed)
            for i = 1, n do
                local l = D("Line")
                l.Thickness    = 0.8
                l.Transparency = 0.50  -- semi-transparent
                l.ZIndex       = 7
                table.insert(orbitLines, l)
            end
        end
        buildOrbitLines(SEG_COUNT)

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
            fpsEntry = makeChip({fixedW=72, stroke=true, padX=false})
            local inner = Instance.new("Frame")
            inner.BackgroundTransparency=1; inner.BorderSizePixel=0
            inner.AnchorPoint=Vector2.new(0.5,0.5)
            inner.Position=UDim2.new(0.5,-2,0.5,0)
            inner.AutomaticSize=Enum.AutomaticSize.XY
            inner.Parent=fpsEntry.frame
            local il=Instance.new("UIListLayout")
            il.FillDirection=Enum.FillDirection.Horizontal
            il.VerticalAlignment=Enum.VerticalAlignment.Center
            il.Padding=UDim.new(0,4); il.Parent=inner

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
            fpsLbl.TextXAlignment=Enum.TextXAlignment.Left
            fpsLbl.Text="--"; fpsLbl.ZIndex=3; fpsLbl.Parent=inner
            table.insert(fpsEntry.labels, fpsLbl)
        end

        -- ── TIME chip ────────────────────────────────────────────────
        local timeEntry, timeLbl
        if showTime then
            timeEntry = makeChip({fixedW=88, stroke=true, padX=false})
            local inner = Instance.new("Frame")
            inner.BackgroundTransparency=1; inner.BorderSizePixel=0
            inner.AnchorPoint=Vector2.new(0.5,0.5)
            inner.Position=UDim2.new(0.5,-2,0.5,0)
            inner.AutomaticSize=Enum.AutomaticSize.XY
            inner.Parent=timeEntry.frame
            local il=Instance.new("UIListLayout")
            il.FillDirection=Enum.FillDirection.Horizontal
            il.VerticalAlignment=Enum.VerticalAlignment.Center
            il.Padding=UDim.new(0,4); il.Parent=inner

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
            timeLbl.TextXAlignment=Enum.TextXAlignment.Left
            timeLbl.Text="00:00"; timeLbl.ZIndex=3; timeLbl.Parent=inner
            table.insert(timeEntry.labels, timeLbl)
        end

        -- ════════════════════════════════════════════════════════════════
        -- PARTICLE SYSTEM
        -- Each chip gets TWO independent particle systems:
        --   sys_A  → "base" particles  (count = particleCount, smaller, faster)
        --   sys_B  → "density" layer   (count = densityCount,  larger,  slower)
        -- ════════════════════════════════════════════════════════════════
        local SPEED_NEAR  = 18
        local SPEED_FAR   = 5
        local R_NEAR      = 2.2
        local R_FAR       = 0.8
        local SPEED_NEAR2 = 8    -- density layer speeds
        local SPEED_FAR2  = 2
        local R_NEAR2     = 3.5
        local R_FAR2      = 1.5
        local densityCount = cfg.DensityCount or 4
        local globalTime   = 0
        local globalT      = 0

        local function getParticleColor(t, z)
            local r = lerp(particleColor1.R*255, particleColor2.R*255, t)
            local g = lerp(particleColor1.G*255, particleColor2.G*255, t)
            local b = lerp(particleColor1.B*255, particleColor2.B*255, t)
            local bright = lerp(0.75, 1.0, z)
            return Color3.fromRGB(
                math.round(clamp(r*bright,0,255)),
                math.round(clamp(g*bright,0,255)),
                math.round(clamp(b*bright,0,255))
            )
        end

        local function buildSys(n, speedNear, speedFar, rNear, rFar)
            local pts = {}
            for i = 1, n do
                local p = {
                    x=0, y=0, vx=0, vy=0,
                    z        = rand(0,1),
                    phaseOff = rand(0, math.pi*2),
                    dot      = D("Circle"),
                    sNear = speedNear, sFar = speedFar,
                    rNear = rNear,     rFar = rFar,
                }
                p.dot.Filled       = true
                p.dot.Color        = particleColor1
                p.dot.Radius       = 1
                p.dot.Transparency = 0
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
            return {pts=pts, lines=lines, ready=false, n=n,
                    ax=0, ay=0, aw=0, ah=0}
        end

        local function initSys(sys, ax, ay, aw, ah)
            for _, p in ipairs(sys.pts) do
                p.x  = rand(ax+6, ax+aw-6)
                p.y  = rand(ay+4, ay+ah-4)
                local spd   = lerp(p.sFar, p.sNear, p.z)
                local angle = rand(0, math.pi*2)
                p.vx = math.cos(angle)*spd
                p.vy = math.sin(angle)*spd
            end
            sys.ready = true
            sys.ax,sys.ay,sys.aw,sys.ah = ax,ay,aw,ah
        end

        local function tickSys(sys, dt, ax, ay, aw, ah, alpha)
            if not sys.ready then return end
            local dax = ax - sys.ax
            local day = ay - sys.ay
            if math.abs(dax)>1 or math.abs(day)>1 then
                for _, p in ipairs(sys.pts) do
                    p.x = clamp(p.x+dax, ax+4, ax+aw-4)
                    p.y = clamp(p.y+day, ay+4, ay+ah-4)
                    if p.x <= ax+4    then p.vx =  math.abs(p.vx) end
                    if p.x >= ax+aw-4 then p.vx = -math.abs(p.vx) end
                    if p.y <= ay+4    then p.vy =  math.abs(p.vy) end
                    if p.y >= ay+ah-4 then p.vy = -math.abs(p.vy) end
                end
            end
            sys.ax,sys.ay,sys.aw,sys.ah = ax,ay,aw,ah

            for _, p in ipairs(sys.pts) do
                p.x += p.vx*dt; p.y += p.vy*dt
                local m = 4
                if p.x < ax+m    then p.x = ax+m;    p.vx =  math.abs(p.vx) end
                if p.x > ax+aw-m then p.x = ax+aw-m; p.vx = -math.abs(p.vx) end
                if p.y < ay+m    then p.y = ay+m;    p.vy =  math.abs(p.vy) end
                if p.y > ay+ah-m then p.y = ay+ah-m; p.vy = -math.abs(p.vy) end

                local pulse  = 0.88+0.12*math.sin(globalTime*1.1+p.phaseOff)
                local spd    = lerp(p.sFar, p.sNear, p.z)
                local curSpd = math.sqrt(p.vx^2+p.vy^2)
                if curSpd > 0.1 then
                    local sc = lerp(1, spd*pulse/curSpd, dt*2)
                    p.vx *= sc; p.vy *= sc
                end

                local r      = lerp(p.rFar, p.rNear, p.z)
                local pulseR = r*(0.88+0.12*math.sin(globalTime*1.8+p.phaseOff))
                -- globalParticleAlpha controls overall transparency
                local baseOp  = lerp(0.12, 0.40, p.z) * globalParticleAlpha
                local finalOp = baseOp * alpha
                local pT      = (globalT + p.phaseOff/(math.pi*2)*0.3)%1

                p.dot.Position     = Vector2.new(p.x, p.y)
                p.dot.Radius       = pulseR
                p.dot.Transparency = finalOp
                p.dot.Color        = getParticleColor(pT, p.z)
            end

            for i=1,#sys.pts do
                for j=i+1,#sys.pts do
                    local pi,pj = sys.pts[i],sys.pts[j]
                    local dx=pi.x-pj.x; local dy=pi.y-pj.y
                    local dist=math.sqrt(dx*dx+dy*dy)
                    local l=sys.lines[i][j]
                    if dist < connectDist then
                        local prox = 1-dist/connectDist
                        local avgZ = (pi.z+pj.z)*0.5
                        local lineOp = lerp(0.05,0.25,prox)*lerp(0.35,1,avgZ)*alpha*globalParticleAlpha
                        l.From        = Vector2.new(pi.x, pi.y)
                        l.To          = Vector2.new(pj.x, pj.y)
                        l.Transparency = lineOp
                        l.Thickness   = lerp(0.4,1.2,avgZ)
                        l.Color       = getParticleColor(globalT, avgZ)
                    else
                        l.Transparency = 0
                    end
                end
            end
        end

        -- Build A (base) + B (density) for each chip including logo
        local entrySystems = {}   -- entry → {sysA, sysB}

        local function buildEntrySystems(entry)
            entrySystems[entry] = {
                buildSys(particleCount, SPEED_NEAR, SPEED_FAR, R_NEAR, R_FAR),
                buildSys(densityCount,  SPEED_NEAR2, SPEED_FAR2, R_NEAR2, R_FAR2),
            }
        end

        buildEntrySystems(logoEntry)
        buildEntrySystems(titleEntry)
        if fpsEntry  then buildEntrySystems(fpsEntry)  end
        if timeEntry then buildEntrySystems(timeEntry) end

        -- Deferred init
        task.spawn(function()
            local waited = 0
            while waited < 4 do
                task.wait(0.05); waited += 0.05
                local allReady = true
                for entry, pair in pairs(entrySystems) do
                    local f  = entry.frame
                    local ap = f.AbsolutePosition
                    local as = f.AbsoluteSize
                    if as.X > 4 and as.Y > 4 then
                        local ay = ap.Y + particleYOffset
                        for _, sys in ipairs(pair) do
                            if not sys.ready then
                                initSys(sys, ap.X, ay, as.X, as.Y)
                            end
                        end
                    else
                        allReady = false
                    end
                end
                if allReady then break end
            end
        end)

        -- ── Spring / drag state ───────────────────────────────────────
        local springP = 0; local springV = 0; local targetA = 1
        local SPRING_K = 120; local SPRING_D = 16

        local dragTargetX = posX; local dragTargetY = posY
        local dragCurX    = posX; local dragCurY    = posY
        local isDragging  = false
        local dragStartMouse  = Vector2.new(0,0)
        local dragStartAnchor = Vector2.new(posX,posY)
        local DRAG_SPRING = 18

        local accentPh = 0
        local FPS_N    = 30
        local fpsBuf   = table.create(FPS_N,1/60)
        local fpsBufI  = 1; local fpsTimer=0; local lastMin=-1

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
        end

        local function setTargetPos(x, y)
            dragTargetX = x; dragTargetY = y
        end
        local function snapPos(x, y)
            dragTargetX=x; dragTargetY=y; dragCurX=x; dragCurY=y
            anchor.Position = UDim2.fromOffset(x, y)
        end

        -- ── Cached screen positions of logo dots (for orbit lines) ────
        -- Updated each RenderStepped from the dot UI positions.
        -- We compute actual SCREEN positions by sampling logoEntry.frame.AbsolutePosition
        -- plus the dot's offset (Position) scaled by chip size.
        local dotScreenPos = {}  -- [i] = Vector2
        for i = 1, SEG_COUNT do dotScreenPos[i] = Vector2.new(0,0) end

        -- ── Connections ───────────────────────────────────────────────
        local conns = {}

        table.insert(conns, RunService.RenderStepped:Connect(function(dt)
            logoAngleTg = logoAngleTg + dt*22
            logoAngleSm = logoAngleSm + (logoAngleTg - logoAngleSm)*(1-math.exp(-dt*10))

            local pulse = 0.88 + 0.12*math.sin(globalTime*1.4)
            local n = #logoSegs
            local lf  = logoEntry.frame
            local lap = lf.AbsolutePosition
            local las = lf.AbsoluteSize

            for i, s in ipairs(logoSegs) do
                local baseA = math.rad((i-1)*(360/n)) + math.rad(logoAngleSm)
                local r     = LOGO_R * pulse

                local px, py, sz, alpha
                if onThePlane then
                    local tilt  = 0.45
                    local cosA  = math.cos(baseA)
                    local sinA  = math.sin(baseA)
                    px   = cosA * r
                    py   = sinA * r * (1-tilt)
                    local depth = sinA
                    sz    = lerp(DOT_SZ*0.5, DOT_SZ*1.5, (depth+1)*0.5)
                    alpha = lerp(0.55, 0.15, (depth+1)*0.5)
                else
                    px    = math.cos(baseA) * r
                    py    = math.sin(baseA) * r
                    sz    = DOT_SZ
                    alpha = 0.18
                end

                s.dot.Size = UDim2.fromOffset(sz, sz)
                s.dot.Position = UDim2.new(0.5, math.round(px), 0.5, math.round(py))
                s.dot.BackgroundTransparency = alpha
                s.dot.BackgroundColor3 = getParticleColor(
                    (globalT + (i-1)/n*0.25)%1, (i-1)/n)

                -- Compute screen position of this dot for orbit line drawing.
                -- logoHolder is centered inside lf at (0.5, 0.5).
                -- Dot position inside logoHolder = (0.5*las.X + px, 0.5*las.Y + py)
                local cx = lap.X + las.X*0.5
                local cy = lap.Y + las.Y*0.5 + particleYOffset
                dotScreenPos[i] = Vector2.new(cx + px, cy + py)
            end
        end))

        table.insert(conns, RunService.Heartbeat:Connect(function(dt)
            globalTime = globalTime + dt
            globalT    = (math.sin(globalTime*0.39)+1)*0.5

            -- entrance spring
            local force = SPRING_K*(targetA-springP) - SPRING_D*springV
            springV = springV + force*dt
            springP = clamp(springP + springV*dt, 0, 1)
            if math.abs(springP-targetA)<0.003 and math.abs(springV)<0.003 then
                springP=targetA; springV=0
            end
            applyProgress(springP)
            gui.Enabled = springP > 0.008

            -- accent
            accentPh = (accentPh+dt*0.6)%(math.pi*2)
            accentLine.BackgroundColor3 = getParticleColor((math.sin(accentPh)+1)*0.5, 0.5)
            local ts = titleLbl.AbsoluteSize
            if ts.X > 0 then
                accentLine.Size     = UDim2.fromOffset(ts.X, 1)
                accentLine.Position = UDim2.fromOffset(0, BAR_H-3)
            end

            -- smooth position spring
            dragCurX = lerp(dragCurX, dragTargetX, clamp(dt*DRAG_SPRING,0,1))
            dragCurY = lerp(dragCurY, dragTargetY, clamp(dt*DRAG_SPRING,0,1))
            anchor.Position = UDim2.fromOffset(math.round(dragCurX), math.round(dragCurY))

            -- orbit lines: connect consecutive dots (dot[i] → dot[i+1], closing loop)
            if orbitEnabled and springP > 0.05 and #logoSegs >= 2 then
                local n        = #logoSegs
                local orbitCol = getParticleColor(globalT, 0.5)
                -- orbit lines count may differ from logoSegs if rebuilt
                local lineCount = math.min(#orbitLines, n)
                for i = 1, lineCount do
                    local j = (i % n) + 1  -- next dot, wrapping around
                    local from = dotScreenPos[i]
                    local to   = dotScreenPos[j]
                    if from and to then
                        orbitLines[i].From        = from
                        orbitLines[i].To          = to
                        orbitLines[i].Color       = orbitCol
                        orbitLines[i].Transparency = 0.50 * (1-springP*0.3)
                    end
                end
            else
                for _, l in ipairs(orbitLines) do l.Transparency = 0 end
            end

            -- particles
            if springP > 0.03 then
                for entry, pair in pairs(entrySystems) do
                    local f  = entry.frame
                    local ap = f.AbsolutePosition
                    local as = f.AbsoluteSize
                    if as.X > 4 and as.Y > 4 then
                        local ay = ap.Y + particleYOffset
                        for _, sys in ipairs(pair) do
                            if not sys.ready then
                                initSys(sys, ap.X, ay, as.X, as.Y)
                            else
                                tickSys(sys, dt, ap.X, ay, as.X, as.Y, springP)
                            end
                        end
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
                if cm ~= lastMin then
                    lastMin=cm
                    timeLbl.Text=string.format("%02d:%02d",math.floor(now/3600)%24,cm%60)
                end
            end
        end))

        -- ── Drag ─────────────────────────────────────────────────────
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
                    setTargetPos(
                        dragStartAnchor.X+(cur.X-dragStartMouse.X),
                        dragStartAnchor.Y+(cur.Y-dragStartMouse.Y)
                    )
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
        local function waitAndMove(fn)
            task.spawn(function()
                local t=0
                while row.AbsoluteSize.X<8 and t<0.5 do task.wait(0.05); t+=0.05 end
                fn()
            end)
        end

        local function moveTopLeft()
            -- left AND lower: X=88, Y=42
            setTargetPos(88, 42)
        end
        local function moveTopRight()
            waitAndMove(function()
                local vp=workspace.CurrentCamera.ViewportSize
                local w=row.AbsoluteSize.X
                setTargetPos(vp.X-w-MARGIN, MARGIN+8)
            end)
        end
        local function moveBottomLeft()
            waitAndMove(function()
                local vp=workspace.CurrentCamera.ViewportSize
                local h=row.AbsoluteSize.Y
                -- further left: 80px from edge
                setTargetPos(80, vp.Y-h-MARGIN)
            end)
        end

        -- ── Rebuild helpers ───────────────────────────────────────────
        local function rebuildAllSystems()
            -- remove old drawing objs except orbit lines (rebuilt separately)
            for entry, pair in pairs(entrySystems) do
                for _, sys in ipairs(pair) do
                    for _, p in ipairs(sys.pts) do
                        pcall(function() p.dot:Remove() end)
                    end
                    for i=1,#sys.pts do
                        for j=i+1,#sys.pts do
                            if sys.lines[i] and sys.lines[i][j] then
                                pcall(function() sys.lines[i][j]:Remove() end)
                            end
                        end
                    end
                end
            end
            -- Rebuild drawObjs list keeping orbit lines
            drawObjs = {}
            for _, l in ipairs(orbitLines) do table.insert(drawObjs, l) end

            entrySystems = {}
            buildEntrySystems(logoEntry)
            buildEntrySystems(titleEntry)
            if fpsEntry  then buildEntrySystems(fpsEntry)  end
            if timeEntry then buildEntrySystems(timeEntry) end

            task.spawn(function()
                local waited=0
                while waited<4 do
                    task.wait(0.05); waited+=0.05
                    local ok=true
                    for entry, pair in pairs(entrySystems) do
                        local f=entry.frame
                        local ap=f.AbsolutePosition
                        local as=f.AbsoluteSize
                        if as.X>4 then
                            local ay=ap.Y+particleYOffset
                            for _, sys in ipairs(pair) do
                                if not sys.ready then initSys(sys,ap.X,ay,as.X,as.Y) end
                            end
                        else ok=false end
                    end
                    if ok then break end
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
            if typeof(pos)=="UDim2" then snapPos(pos.X.Offset,pos.Y.Offset)
            elseif typeof(pos)=="Vector2" then snapPos(pos.X,pos.Y) end
        end
        function WM:MoveTopLeft()    moveTopLeft()    end
        function WM:MoveTopRight()   moveTopRight()   end
        function WM:MoveBottomLeft() moveBottomLeft() end

        function WM:SetDrag(state)
            dragEnabled_=state
            if not state then isDragging=false; moveTopRight() end
        end
        function WM:IsDragEnabled() return dragEnabled_ end

        -- Particle Y offset (manual fine-tune, default=28)
        function WM:SetParticleYOffset(v)
            particleYOffset=v
            for _, pair in pairs(entrySystems) do
                for _, sys in ipairs(pair) do sys.ready=false end
            end
        end
        function WM:GetParticleYOffset() return particleYOffset end

        -- Particle global opacity (0=invisible, 1=full)
        function WM:SetParticleAlpha(a)
            globalParticleAlpha = math.clamp(a, 0, 1)
        end
        function WM:GetParticleAlpha() return globalParticleAlpha end

        function WM:SetParticleColors(c1,c2)
            if c1 then particleColor1=c1 end
            if c2 then particleColor2=c2 end
        end
        function WM:SetParticleCount(n, cd)
            particleCount=math.clamp(math.round(n),2,30)
            if cd then connectDist=cd end
            rebuildAllSystems()
        end
        function WM:SetDensityCount(n)
            densityCount=math.clamp(math.round(n),0,20)
            rebuildAllSystems()
        end
        function WM:SetConnectDist(d) connectDist=d end
        function WM:SetParticleSpeed(near,far)
            if near then SPEED_NEAR=near end
            if far  then SPEED_FAR=far  end
        end

        function WM:SetOrbitEnabled(state)
            orbitEnabled=state
            if not state then for _,l in ipairs(orbitLines) do l.Transparency=0 end end
        end
        function WM:IsOrbitEnabled() return orbitEnabled end

        function WM:SetSegmentCount(n)
            n=math.clamp(math.round(n),2,24)
            SEG_COUNT=n
            rebuildLogoSegs(n)
            buildOrbitLines(n)
            for i=1,n do dotScreenPos[i]=Vector2.new(0,0) end
        end
        function WM:GetSegmentCount() return SEG_COUNT end

        function WM:SetOnThePlane(state) onThePlane=state end
        function WM:IsOnThePlane() return onThePlane end

        function WM:Destroy()
            for _,c in ipairs(conns) do c:Disconnect() end
            for _,c in ipairs(dragInputConns) do c:Disconnect() end
            for _,d in ipairs(drawObjs) do pcall(function() d:Remove() end) end
            gui:Destroy()
        end

        return WM
    end

    if ctx.onLoad then ctx.onLoad() end
end
