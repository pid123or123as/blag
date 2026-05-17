-- Watermark_PreLoader.lua  (v13)
return function(ctx)
    local MacLib     = ctx.MacLib
    local RunService = game:GetService("RunService")
    local UIS        = game:GetService("UserInputService")
    local isMobile   = UIS.TouchEnabled and not UIS.KeyboardEnabled

    local function lerp(a,b,t) return a+(b-a)*t end
    local function rand(a,b)   return a+math.random()*(b-a) end
    local function clamp(v,a,b) return math.max(a,math.min(b,v)) end

    local GUI_INSET_Y = 58

    local function GetGui()
        local g = Instance.new("ScreenGui")
        g.ResetOnSpawn   = false
        g.DisplayOrder   = 1999823
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
        local titleText    = cfg.Title    or "Watermark"
        local showFPS      = cfg.ShowFPS  ~= false
        local showTime     = cfg.ShowTime ~= false
        local dragEnabled_ = cfg.Drag ~= nil and cfg.Drag or (not isMobile)

        local particleColor1       = cfg.ParticleColor1       or Color3.fromRGB(72, 138, 255)
        local particleColor2       = cfg.ParticleColor2       or Color3.fromRGB(140, 90, 255)
        local particleCount        = cfg.ParticleCount        or 8
        local connectDist          = cfg.ConnectDist          or 30
        local particleTransparency = cfg.ParticleTransparency or 0.20

        local MARGIN   = 22
        local UI_SCALE = 0.80

        -- ── Position state ────────────────────────────────────────────
        -- Stored as fractions of viewport (0..1) so position is
        -- resolution-independent and can be persisted via MacLib:SetData.
        local posNX, posNY   -- normalised [0..1], nil until first layout

        -- ── Root GUI ──────────────────────────────────────────────────
        local gui = GetGui(); gui.Name = "MacLibWatermark"

        local anchor = Instance.new("Frame")
        anchor.Name                   = "WmAnchor"
        anchor.BackgroundTransparency = 1
        anchor.BorderSizePixel        = 0
        anchor.AutomaticSize          = Enum.AutomaticSize.XY
        anchor.AnchorPoint            = Vector2.new(0,0)
        anchor.Position               = UDim2.fromOffset(0, 0)
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

        -- ── Tokens ────────────────────────────────────────────────────
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

        -- ── Chip factory ──────────────────────────────────────────────
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
        logoHolder.Name              = "LogoHolder"
        logoHolder.AnchorPoint       = Vector2.new(0.5,0.5)
        logoHolder.Position          = UDim2.new(0.5,0,0.5,0)
        logoHolder.Size              = UDim2.fromOffset(18,18)
        logoHolder.BackgroundTransparency = 1
        logoHolder.BorderSizePixel   = 0
        logoHolder.Parent            = logoEntry.frame

        -- Logo segments
        local SEG_COUNT   = cfg.SegmentCount or 17
        local DOT_SZ      = 2.5
        local LOGO_R      = 7
        local logoSegs    = {}
        local logoAngleSm = 0
        local logoAngleTg = 0
        local onThePlane  = cfg.OnThePlane ~= nil and cfg.OnThePlane or true

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

        -- ── Drawing objects ───────────────────────────────────────────
        local drawObjs = {}
        local function D(t)
            local d = Drawing.new(t)
            d.Visible = true
            table.insert(drawObjs, d)
            return d
        end

        -- Orbit outline
        local orbitLines   = {}
        local orbitEnabled = cfg.OrbitEnabled ~= nil and cfg.OrbitEnabled or true

        local function ensureOrbitLines()
            local need = #logoSegs
            while #orbitLines < need do
                local l = D("Line")
                l.Thickness    = 0.8
                l.Transparency = 0.72   -- more transparent than segments
                l.Color        = Color3.fromRGB(255,255,255)
                l.ZIndex       = 7      -- behind segment dots (ZIndex 3 GUI + Drawing 9)
                table.insert(orbitLines, l)
            end
            while #orbitLines > need do
                local l = table.remove(orbitLines)
                pcall(function() l:Remove() end)
            end
        end

        -- ── TITLE chip ────────────────────────────────────────────────
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

        -- ── FPS chip ──────────────────────────────────────────────────
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

        -- ── TIME chip ─────────────────────────────────────────────────
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
        -- ════════════════════════════════════════════════════════════════

        local SPEED_NEAR = cfg.SpeedNear or 50
        local SPEED_FAR  = cfg.SpeedFar  or 25
        local R_NEAR     = 2.2
        local R_FAR      = 0.8
        local globalT    = 0
        local globalTime = 0

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
            return {pts=pts, lines=lines, ready=false, n=n, ax=0,ay=0,aw=0,ah=0}
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
            if not sys.ready then return end
            local dax = ax - sys.ax; local day = ay - sys.ay
            if math.abs(dax)>1 or math.abs(day)>1 then
                for _, p in ipairs(sys.pts) do
                    p.x = p.x + dax; p.y = p.y + day
                    p.x = clamp(p.x, ax+4, ax+aw-4)
                    p.y = clamp(p.y, ay+4, ay+ah-4)
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
                local spd    = lerp(SPEED_FAR, SPEED_NEAR, p.z)
                local curSpd = math.sqrt(p.vx^2+p.vy^2)
                if curSpd > 0.1 then
                    local target = spd*pulse
                    local sc = lerp(1, target/curSpd, dt*2)
                    p.vx *= sc; p.vy *= sc
                end

                local r      = lerp(R_FAR, R_NEAR, p.z)
                local pulseR = r*(0.88+0.12*math.sin(globalTime*1.8+p.phaseOff))
                local baseOp  = lerp(0.18, 0.60, p.z)
                local finalOp = baseOp * globalAlpha * (1 - particleTransparency)
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
                        local prox  = 1-dist/connectDist
                        local avgZ  = (pi.z+pj.z)*0.5
                        local lineOp = lerp(0.05,0.35,prox)*lerp(0.35,1,avgZ)*globalAlpha*(1-particleTransparency)
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

        local entryToSys = {}
        entryToSys[titleEntry] = buildSys(particleCount)
        if fpsEntry  then entryToSys[fpsEntry]  = buildSys(particleCount) end
        if timeEntry then entryToSys[timeEntry] = buildSys(particleCount) end

        task.spawn(function()
            local waited = 0
            while waited < 4 do
                task.wait(0.05); waited += 0.05
                local allReady = true
                for entry, sys in pairs(entryToSys) do
                    if not sys.ready then
                        local ap = entry.frame.AbsolutePosition
                        local as = entry.frame.AbsoluteSize
                        if as.X > 8 and as.Y > 4 then
                            initSys(sys, ap.X, ap.Y + GUI_INSET_Y, as.X, as.Y)
                        else allReady = false end
                    end
                end
                if allReady then break end
            end
        end)

        -- ── Spring ────────────────────────────────────────────────────
        local springP = 0; local springV = 0; local targetA = 1
        local SPRING_K = 120; local SPRING_D = 16

        local dragTargetX = 0; local dragTargetY = 0
        local dragCurX    = 0; local dragCurY    = 0
        local isDragging  = false
        local dragStartMouse  = Vector2.new(0,0)
        local dragStartAnchor = Vector2.new(0,0)
        local DRAG_SPRING = 18

        local accentPh  = 0
        local FPS_N     = 30
        local fpsBuf    = table.create(FPS_N,1/60)
        local fpsBufI   = 1; local fpsTimer=0; local lastMin=-1

        -- Saves normalised position to MacLib custom data
        local function savePos(px, py)
            posNX = px; posNY = py
            MacLib:SetData("WM_PosNX", px)
            MacLib:SetData("WM_PosNY", py)
        end

        -- Converts normalised position → pixel, clamped so watermark stays on screen
        local function normToPixel(nx, ny)
            local vp = workspace.CurrentCamera.ViewportSize
            local w  = math.max(row.AbsoluteSize.X, 10)
            local h  = math.max(row.AbsoluteSize.Y, 10)
            local px = math.round(clamp(nx * vp.X, 0, vp.X - w))
            local py = math.round(clamp(ny * vp.Y, 0, vp.Y - h))
            return px, py
        end

        -- Converts pixel → normalised
        local function pixelToNorm(px, py)
            local vp = workspace.CurrentCamera.ViewportSize
            return px / vp.X, py / vp.Y
        end

        local function setTargetPos(x, y)
            dragTargetX = x; dragTargetY = y
            savePos(pixelToNorm(x, y))
        end

        local function snapPos(x, y)
            dragTargetX=x; dragTargetY=y; dragCurX=x; dragCurY=y
            anchor.Position = UDim2.fromOffset(x, y)
            savePos(pixelToNorm(x, y))
        end

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

        -- ── Position helpers ──────────────────────────────────────────
        local function waitAndMove(fn)
            task.spawn(function()
                local t=0
                while row.AbsoluteSize.X < 8 and t < 0.5 do task.wait(0.05); t+=0.05 end
                fn()
            end)
        end

        local function moveTopLeft()
            setTargetPos(50, MARGIN+40)
        end
        local function moveTopRight()
            waitAndMove(function()
                local vp = workspace.CurrentCamera.ViewportSize
                local w  = row.AbsoluteSize.X
                -- Use actual pixel width of row (already includes UIScale effect on AbsoluteSize)
                setTargetPos(vp.X - w - MARGIN, MARGIN+8)
            end)
        end
        local function moveBottomLeft()
            waitAndMove(function()
                local vp = workspace.CurrentCamera.ViewportSize
                local h  = row.AbsoluteSize.Y
                setTargetPos(50, vp.Y - h - MARGIN)
            end)
        end

        -- ── Connections ───────────────────────────────────────────────
        local conns = {}

        table.insert(conns, RunService.RenderStepped:Connect(function(dt)
            logoAngleTg = logoAngleTg + dt*22
            logoAngleSm = logoAngleSm + (logoAngleTg-logoAngleSm)*(1-math.exp(-dt*10))
            local pulse = 0.88+0.12*math.sin(globalTime*1.4)
            local n = #logoSegs
            for i, s in ipairs(logoSegs) do
                local baseA = math.rad((i-1)*(360/n)) + math.rad(logoAngleSm)
                local r = LOGO_R*pulse
                local px,py,sz,alpha
                if onThePlane then
                    local tilt = 0.45
                    local cosA = math.cos(baseA); local sinA = math.sin(baseA)
                    px = cosA*r; py = sinA*r*(1-tilt)
                    local depth = sinA
                    sz    = lerp(DOT_SZ*0.5, DOT_SZ*1.5, (depth+1)*0.5)
                    alpha = lerp(0.55, 0.15, (depth+1)*0.5)
                else
                    px = math.cos(baseA)*r; py = math.sin(baseA)*r
                    sz    = DOT_SZ
                    alpha = 0.18
                end
                s.dot.Size     = UDim2.fromOffset(sz,sz)
                s.dot.Position = UDim2.new(0.5,math.round(px),0.5,math.round(py))
                s.dot.BackgroundTransparency = alpha
                s.dot.BackgroundColor3 = getParticleColor(
                    (globalT+(i-1)/n*0.25)%1, (i-1)/n)
            end
        end))

        table.insert(conns, RunService.Heartbeat:Connect(function(dt)
            globalTime = globalTime + dt
            globalT    = (math.sin(globalTime*0.39)+1)*0.5

            local force = SPRING_K*(targetA-springP) - SPRING_D*springV
            springV = springV + force*dt
            springP = clamp(springP+springV*dt, 0, 1)
            if math.abs(springP-targetA)<0.003 and math.abs(springV)<0.003 then
                springP=targetA; springV=0
            end
            applyProgress(springP)
            gui.Enabled = springP > 0.008

            dragCurX = lerp(dragCurX, dragTargetX, clamp(dt*DRAG_SPRING,0,1))
            dragCurY = lerp(dragCurY, dragTargetY, clamp(dt*DRAG_SPRING,0,1))
            anchor.Position = UDim2.fromOffset(math.round(dragCurX), math.round(dragCurY))

            -- save normalised pos when dragging (throttled — every 0.2s is fine,
            -- but here we just always save; SetData is cheap)
            if isDragging then
                savePos(pixelToNorm(math.round(dragCurX), math.round(dragCurY)))
            end

            -- Orbit outline
            ensureOrbitLines()
            if orbitEnabled and springP > 0.05 and #logoSegs >= 2 then
                for i = 1, #logoSegs do
                    local s1 = logoSegs[i]
                    local s2 = logoSegs[(i%#logoSegs)+1]
                    local ap1 = s1.dot.AbsolutePosition
                    local ap2 = s2.dot.AbsolutePosition
                    local sz1 = s1.dot.AbsoluteSize
                    local sz2 = s2.dot.AbsoluteSize
                    local l = orbitLines[i]
                    if l then
                        l.From  = Vector2.new(ap1.X+sz1.X*0.5, ap1.Y+sz1.Y*0.5+GUI_INSET_Y)
                        l.To    = Vector2.new(ap2.X+sz2.X*0.5, ap2.Y+sz2.Y*0.5+GUI_INSET_Y)
                    end
                end
            else
                for _, l in ipairs(orbitLines) do l.Transparency = 0 end
            end

            -- Accent underline
            accentPh = (accentPh+dt*0.6)%(math.pi*2)
            accentLine.BackgroundColor3 = getParticleColor((math.sin(accentPh)+1)*0.5, 0.5)
            local ts = titleLbl.AbsoluteSize
            if ts.X > 0 then
                accentLine.Size     = UDim2.fromOffset(ts.X, 1)
                accentLine.Position = UDim2.fromOffset(0, BAR_H-3)
            end

            -- Particles
            if springP > 0.03 then
                for entry, sys in pairs(entryToSys) do
                    local f  = entry.frame
                    local ap = f.AbsolutePosition
                    local as = f.AbsoluteSize
                    if as.X > 8 and as.Y > 4 then
                        local screenY = ap.Y + GUI_INSET_Y
                        if not sys.ready then
                            initSys(sys, ap.X, screenY, as.X, as.Y)
                        else
                            tickSys(sys, dt, ap.X, screenY, as.X, as.Y, springP)
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
                if cm~=lastMin then
                    lastMin=cm
                    timeLbl.Text=string.format("%02d:%02d",math.floor(now/3600)%24,cm%60)
                end
            end
        end))

        -- ── Drag ──────────────────────────────────────────────────────
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

        -- ── Initial position ──────────────────────────────────────────
        -- Try to restore saved normalised position via MacLib:GetData.
        -- If none saved, default to Top-right (computed after layout).
        applyProgress(0); targetA=1

        task.spawn(function()
            -- Wait for row to have a valid size
            local waited = 0
            while row.AbsoluteSize.X < 8 and waited < 1 do
                task.wait(0.05); waited += 0.05
            end

            local savedNX = MacLib:GetData("WM_PosNX", nil)
            local savedNY = MacLib:GetData("WM_PosNY", nil)

            if savedNX and savedNY then
                -- Restore resolution-independent position
                local px, py = normToPixel(savedNX, savedNY)
                snapPos(px, py)
            else
                -- Default: Top-right
                moveTopRight()
            end
        end)

        -- ── Rebuild particles ──────────────────────────────────────────
        local function rebuildAllParticles(n)
            for _, sys in pairs(entryToSys) do
                for _, p in ipairs(sys.pts) do pcall(function() p.dot:Remove() end) end
                for i=1,#sys.pts do
                    for j=i+1,#sys.pts do
                        if sys.lines[i] and sys.lines[i][j] then
                            pcall(function() sys.lines[i][j]:Remove() end)
                        end
                    end
                end
            end
            local kept={}
            for _, d in ipairs(drawObjs) do
                local isOrbit=false
                for _, ol in ipairs(orbitLines) do if ol==d then isOrbit=true break end end
                if isOrbit then table.insert(kept,d) end
            end
            drawObjs = kept

            particleCount = n
            entryToSys = {}
            entryToSys[titleEntry] = buildSys(n)
            if fpsEntry  then entryToSys[fpsEntry]  = buildSys(n) end
            if timeEntry then entryToSys[timeEntry] = buildSys(n) end

            task.spawn(function()
                local waited=0
                while waited<4 do
                    task.wait(0.05); waited+=0.05
                    local allReady=true
                    for entry,sys in pairs(entryToSys) do
                        if not sys.ready then
                            local ap=entry.frame.AbsolutePosition
                            local as=entry.frame.AbsoluteSize
                            if as.X>8 then initSys(sys,ap.X,ap.Y+GUI_INSET_Y,as.X,as.Y)
                            else allReady=false end
                        end
                    end
                    if allReady then break end
                end
            end)
        end

        -- ── Public API ────────────────────────────────────────────────
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

        -- Resets saved position so next launch defaults to Top-right again
        function WM:ResetPosition()
            MacLib:SetData("WM_PosNX", nil)
            MacLib:SetData("WM_PosNY", nil)
            moveTopRight()
        end

        function WM:SetDrag(state)
            dragEnabled_=state
            if not state then isDragging=false; moveTopRight() end
        end
        function WM:IsDragEnabled() return dragEnabled_ end

        function WM:SetParticleColors(c1,c2)
            if c1 then particleColor1=c1 end
            if c2 then particleColor2=c2 end
        end

        function WM:SetParticleCount(n)
            n=math.clamp(math.round(n),2,30)
            rebuildAllParticles(n)
        end

        function WM:SetParticleTransparency(t)
            particleTransparency=clamp(t,0,1)
        end
        function WM:GetParticleTransparency() return particleTransparency end

        function WM:SetConnectDist(d)   connectDist=d end
        function WM:SetParticleSpeed(near,far)
            if near then SPEED_NEAR=near end
            if far  then SPEED_FAR=far   end
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
            ensureOrbitLines()
        end
        function WM:GetSegmentCount() return SEG_COUNT end

        function WM:SetOnThePlane(state) onThePlane=state end
        function WM:IsOnThePlane()       return onThePlane end

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
