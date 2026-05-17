-- Watermark_PreLoader.lua  (v7)
-- КРИТИЧНЫЕ ИСПРАВЛЕНИЯ:
--   • Drawing: Transparency 0=прозрачный, 1=непрозрачный (ОБРАТНО от Roblox GUI!)
--              + обязателен Visible = true
--   • Полоска: сдвиг через TextLabel GetTextSize → точная ширина текста
--   • Логотип: сегменты меньше фона (scale 0.7 внутри chip), фон больше
--   • Top-right: учитывает UIScale при вычислении ширины
--   • Top-left margin: 104px от левого края (мимо кнопок Roblox)

return function(ctx)
    local MacLib     = ctx.MacLib
    local RunService = game:GetService("RunService")

    local function lerp(a, b, t) return a + (b - a) * t end
    local function rand(a, b)    return a + math.random() * (b - a) end

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

        local initX, initY = 104, 8  -- left: skip Roblox top-left buttons
        if cfg.Position then
            if typeof(cfg.Position) == "UDim2" then
                initX = cfg.Position.X.Offset
                initY = cfg.Position.Y.Offset
            elseif typeof(cfg.Position) == "Vector2" then
                initX = cfg.Position.X; initY = cfg.Position.Y
            end
        end

        -- ── Root ──────────────────────────────────────────────────────────
        local gui = GetGui(); gui.Name = "MacLibWatermark"

        local anchor = Instance.new("Frame")
        anchor.Name                   = "WmAnchor"
        anchor.Position               = UDim2.fromOffset(initX, initY)
        anchor.AnchorPoint            = Vector2.new(0, 0)
        anchor.BackgroundTransparency = 1
        anchor.BorderSizePixel        = 0
        anchor.AutomaticSize          = Enum.AutomaticSize.XY
        anchor.Parent                 = gui

        local uiScale       = Instance.new("UIScale")
        uiScale.Scale       = 0.85
        uiScale.Parent      = anchor

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
        local BAR_H    = 26
        local LOGO_SZ  = 32       -- chip size (bigger than BAR_H)
        local SEG_SZ   = 20       -- logo ring size inside chip
        local TXT_SZ   = 12
        local ICON_SZ  = 13
        local PAD_X    = 10

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

        -- ── LOGO chip ─────────────────────────────────────────────────────
        -- Chip = LOGO_SZ × LOGO_SZ square with rounded corners (not full circle)
        -- Inside: ring of segments scaled to SEG_SZ
        local logoEntry = makeChip({
            bg     = COL_BG_DARK,
            fixedW = LOGO_SZ,
            h      = LOGO_SZ,
            radius = 9,
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
        logoHolder.ClipsDescendants       = false
        logoHolder.Parent                 = logoEntry.frame

        local SEG_COUNT = 30
        local logoSegs  = {}

        for i = 1, SEG_COUNT do
            local seg = Instance.new("ImageLabel")
            seg.Size                   = UDim2.new(1, 0, 1, 0)
            seg.BackgroundTransparency = 1
            seg.Image                  = "rbxassetid://7151778302"
            seg.ImageTransparency      = 0.35
            seg.Rotation               = (i-1) * (360/SEG_COUNT)
            seg.ZIndex                 = 3
            seg.Parent                 = logoHolder
            Instance.new("UICorner", seg).CornerRadius = UDim.new(0.5, 0)

            local grad = Instance.new("UIGradient")
            local h1 = 0.60 + (i-1)/SEG_COUNT * 0.12
            local h2 = 0.68 + i/SEG_COUNT     * 0.10
            grad.Color    = ColorSequence.new(
                Color3.fromHSV(h1 % 1, 0.85, 1),
                Color3.fromHSV(h2 % 1, 0.78, 1)
            )
            grad.Rotation = (i-1) * (360/SEG_COUNT)
            grad.Parent   = seg

            table.insert(logoSegs, { seg=seg })
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

        -- Accent underline inside title chip — positioned above bottom edge
        local accentLine = Instance.new("Frame")
        accentLine.Name                   = "AccentLine"
        accentLine.BackgroundColor3       = COL_ACCENT
        accentLine.BackgroundTransparency = 0
        accentLine.BorderSizePixel        = 0
        accentLine.ZIndex                 = 5
        accentLine.Size                   = UDim2.fromOffset(40, 1)
        accentLine.Position               = UDim2.fromOffset(0, BAR_H - 4)
        accentLine.Parent                 = titleEntry.frame

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
            fpsLbl.TextXAlignment         = Enum.TextXAlignment.Left
            fpsLbl.Text                   = "--"
            fpsLbl.ZIndex                 = 3
            fpsLbl.Parent                 = fpsEntry.frame
            table.insert(fpsEntry.labels, fpsLbl)
        end

        -- ── TIME chip ─────────────────────────────────────────────────────
        local timeEntry, timeIcon, timeLbl
        if showTime then
            timeEntry = makeChip({ fixedW = 90, stroke = true })

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
            timeLbl.TextXAlignment         = Enum.TextXAlignment.Left
            timeLbl.Text                   = "00:00"
            timeLbl.ZIndex                 = 3
            timeLbl.Parent                 = timeEntry.frame
            table.insert(timeEntry.labels, timeLbl)
        end

        -- ════════════════════════════════════════════════════════════════════
        -- DRAWING PARTICLES  (particles.js constellation, per-chip)
        --
        -- Drawing API transparency: 0 = полностью прозрачный, 1 = непрозрачный
        -- Drawing API: обязателен Visible = true
        --
        -- Pseudo-3D: Z∈[0,1], 0=далеко(маленький, тусклый), 1=близко(большой, яркий)
        -- ════════════════════════════════════════════════════════════════════

        local drawObjs = {}
        local function D(t)
            local d = Drawing.new(t)
            d.Visible = true
            table.insert(drawObjs, d)
            return d
        end

        local P_COUNT      = 9
        local CONNECT_DIST = 55
        local SPEED_NEAR   = 22
        local SPEED_FAR    = 7
        local R_NEAR       = 2.0
        local R_FAR        = 0.7

        local function buildSys(n)
            local pts = {}
            for i = 1, n do
                local p = {
                    x=0, y=0,
                    vx=0, vy=0,
                    z = rand(0,1),
                    dot = D("Circle"),
                }
                -- Drawing Transparency: начинаем с 0 (прозрачный), покажем позже
                p.dot.Filled       = true
                p.dot.Color        = COL_ACCENT
                p.dot.Radius       = 1
                p.dot.Transparency = 0   -- начало: невидимый
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
                    l.Color        = COL_ACCENT
                    l.Transparency = 0   -- начало: невидимый
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
                p.x = rand(ax+4, ax+aw-4)
                p.y = rand(ay+4, ay+ah-4)
                local spd   = lerp(SPEED_FAR, SPEED_NEAR, p.z)
                local angle = rand(0, math.pi*2)
                p.vx = math.cos(angle)*spd
                p.vy = math.sin(angle)*spd
            end
            sys.ready = true
        end

        -- Drawing Transparency: 0=прозрачный, 1=непрозрачный
        -- globalA ∈ [0,1] — наш alpha fade
        -- Итоговая drawing transparency = lerp(0, targetOpacity, globalA)
        local function tickSys(sys, dt, ax, ay, aw, ah, globalA)
            if not sys.ready then
                if aw > 4 then initSys(sys, ax, ay, aw, ah) end
                return
            end

            local pts = sys.pts
            for _, p in ipairs(pts) do
                p.x += p.vx * dt
                p.y += p.vy * dt

                local m = 3
                if p.x < ax+m    then p.x=ax+m;    p.vx= math.abs(p.vx) end
                if p.x > ax+aw-m then p.x=ax+aw-m; p.vx=-math.abs(p.vx) end
                if p.y < ay+m    then p.y=ay+m;    p.vy= math.abs(p.vy) end
                if p.y > ay+ah-m then p.y=ay+ah-m; p.vy=-math.abs(p.vy) end

                local r      = lerp(R_FAR, R_NEAR, p.z)
                local dotOp  = lerp(0.25, 0.70, p.z)  -- target opacity in Drawing scale
                local finalOp = dotOp * globalA        -- fade with global alpha

                p.dot.Position    = Vector2.new(p.x, p.y)
                p.dot.Radius      = r
                p.dot.Transparency = finalOp
                p.dot.Color = Color3.fromRGB(
                    math.round(lerp(60, 130, p.z)),
                    math.round(lerp(100, 170, p.z)),
                    255
                )
            end

            for i = 1, #pts do
                for j = i+1, #pts do
                    local pi, pj = pts[i], pts[j]
                    local dx = pi.x-pj.x; local dy = pi.y-pj.y
                    local dist = math.sqrt(dx*dx+dy*dy)
                    local l = sys.lines[i][j]

                    if dist < CONNECT_DIST then
                        local prox = 1 - dist/CONNECT_DIST   -- 0→1 closer=1
                        local avgZ = (pi.z+pj.z)*0.5
                        -- Drawing transparency: ближе = больше opacity
                        local lineOp = lerp(0.08, 0.45, prox) * lerp(0.5, 1, avgZ) * globalA

                        l.From         = Vector2.new(pi.x, pi.y)
                        l.To           = Vector2.new(pj.x, pj.y)
                        l.Transparency = lineOp
                        l.Thickness    = lerp(0.5, 1.2, avgZ)
                        l.Color = Color3.fromRGB(
                            math.round(lerp(55, 110, avgZ)),
                            math.round(lerp(90, 155, avgZ)),
                            255
                        )
                    else
                        l.Transparency = 0
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

        local logoAngle = 0
        local accentPh  = 0

        local FPS_N   = 30
        local fpsBuf  = table.create(FPS_N, 1/60)
        local fpsBufI = 1; local fpsTimer = 0
        local lastMin = -1

        -- ── applyAlpha: Roblox GUI transparency (0=опак, 1=прозрачный) ────
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
                s.seg.ImageTransparency = lerp(1, 0.35, a)
            end

            accentLine.BackgroundTransparency = lerp(1, 0, a)

            -- Hide drawing objects when invisible
            if a < 0.02 then
                for _, d in ipairs(drawObjs) do d.Transparency = 0 end
            end
        end

        -- ── Heartbeat ─────────────────────────────────────────────────────
        local conn
        conn = RunService.Heartbeat:Connect(function(dt)
            local spd = targetA > alpha and SPRING_IN or SPRING_OUT
            alpha = lerp(alpha, targetA, math.min(1, dt*spd))
            if math.abs(alpha-targetA) < 0.004 then alpha = targetA end

            applyAlpha(alpha)
            gui.Enabled = alpha > 0.01

            -- Logo slow rotation
            logoAngle = (logoAngle + dt*15) % 360
            for i, s in ipairs(logoSegs) do
                s.seg.Rotation = (i-1)*(360/SEG_COUNT) + logoAngle
            end

            -- Accent color pulse + resize to match text width
            accentPh = (accentPh + dt*0.8) % (math.pi*2)
            local t = (math.sin(accentPh)+1)*0.5
            accentLine.BackgroundColor3 = Color3.fromRGB(
                math.round(lerp(72,108,t)),
                math.round(lerp(138,82,t)),
                255
            )

            -- Match accent line exactly to text width using AbsoluteSize
            -- AbsoluteSize gives the rendered text bounds
            local ts = titleLbl.AbsoluteSize
            if ts.X > 0 then
                -- The label has UIPadding from its parent chip.
                -- We want the line to start at same X as the label inside the padded area.
                -- titleLbl Position is UDim2.fromOffset(0,0) inside padded chip,
                -- so relative offset = 0 from padding start.
                accentLine.Size     = UDim2.fromOffset(ts.X, 1)
                -- Position relative to chip: same X as padded label, near bottom
                accentLine.Position = UDim2.fromOffset(0, BAR_H - 4)
            end

            -- Particle systems
            if alpha > 0.03 then
                for entry, sys in pairs(entryToSys) do
                    local f  = entry.frame
                    local ap = f.AbsolutePosition
                    local as = f.AbsoluteSize
                    tickSys(sys, dt, ap.X, ap.Y, as.X, as.Y, alpha)
                end
            end

            -- FPS
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

        -- ── Top-right helper ──────────────────────────────────────────────
        local function setTopRight()
            -- Wait one frame so AutomaticSize has settled
            task.defer(function()
                local vp     = workspace.CurrentCamera.ViewportSize
                local scale  = uiScale.Scale
                local rawW   = row.AbsoluteSize.X  -- already scaled by UIScale
                local margin = 22
                local posX   = vp.X - rawW - margin
                anchor.Position = UDim2.fromOffset(posX, 8)
            end)
        end

        -- ── Public API ────────────────────────────────────────────────────
        local WM = {}
        function WM:Show()    if not visible then visible=true;  targetA=1 end end
        function WM:Hide()    if visible     then visible=false; targetA=0 end end
        function WM:Toggle()  if visible then self:Hide() else self:Show() end end
        function WM:IsVisible() return visible end
        function WM:SetTitle(txt) titleText=txt; titleLbl.Text=txt end
        function WM:SetPosition(pos)
            if typeof(pos)=="UDim2" then anchor.Position=pos
            elseif typeof(pos)=="Vector2" then
                anchor.Position=UDim2.fromOffset(pos.X,pos.Y)
            end
        end
        function WM:MoveTopRight() setTopRight() end
        function WM:MoveTopLeft()
            anchor.Position = UDim2.fromOffset(104, 8)
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
