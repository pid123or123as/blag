-- Watermark_PreLoader.lua  (V10)
-- Патчит MacLib:Watermark(cfg) — создаёт standalone Drawing-ватермарку.
-- Новое в V10:
--   • OnThePlane          — 3D-глубина орбит-точек логотипа
--   • ShowOrbit           — прозрачный orbit-ring из линий
--   • SegmentCount        — кол-во сегментов orbit-ring
--   • :SetOnThePlane(v)   • :SetOrbit(v)   • :SetSegmentCount(n)
--   • Позиции: Top-left (правее), Top-right (ниже), Bottom-left (левее); Bottom-right удалён
--   • При смене позиции — плавная tween-анимация (как при Drag)
--   • При выключении Drag — авторесет на Top-right
--   • FPS / Time иконки сдвинуты чуть левее
--   • Particle Y-offset slider (:SetParticleOffsetY)
--   • Частицы отскакивают от границ ватермарки при её перемещении
--   • :MoveTopLeft() / :MoveTopRight() / :MoveBottomLeft() — публичные методы

return function(ctx)
    local MacLib = ctx.MacLib
    local Window = ctx.Window

    local RS  = game:GetService("RunService")
    local UIS = game:GetService("UserInputService")

    -- ────────────────────────────────────────────────
    -- Drawing helpers
    -- ────────────────────────────────────────────────
    local function newLine()
        local l = Drawing.new("Line")
        l.Visible   = false
        l.Thickness = 1
        l.Color     = Color3.new(1, 1, 1)
        l.Transparency = 1
        return l
    end

    local function newCircle()
        local c = Drawing.new("Circle")
        c.Visible     = false
        c.Filled      = false
        c.Thickness   = 1
        c.Transparency = 1
        c.NumSides    = 64
        return c
    end

    local function newText()
        local t = Drawing.new("Text")
        t.Visible    = false
        t.Size       = 14
        t.Center     = false
        t.Outline    = true
        t.OutlineColor = Color3.new(0, 0, 0)
        t.Color      = Color3.new(1, 1, 1)
        t.Font       = 2
        t.Transparency = 1
        return t
    end

    local function newImage()
        local ok, img = pcall(Drawing.new, "Image")
        if not ok then return nil end
        img.Visible      = false
        img.Transparency = 1
        return img
    end

    -- ────────────────────────────────────────────────
    -- Tween helper (lerp over time using Heartbeat)
    -- ────────────────────────────────────────────────
    local function tweenVec2(getter, setter, targetVec, duration, onDone)
        local startVec = getter()
        local elapsed  = 0
        local conn
        conn = RS.Heartbeat:Connect(function(dt)
            elapsed = math.min(elapsed + dt, duration)
            local alpha = elapsed / duration
            -- EaseOutQuart
            local t = 1 - alpha
            local ease = 1 - t * t * t * t
            local cur = startVec:Lerp(targetVec, ease)
            setter(cur)
            if elapsed >= duration then
                conn:Disconnect()
                setter(targetVec)
                if onDone then onDone() end
            end
        end)
        return conn
    end

    -- ────────────────────────────────────────────────
    -- MacLib:Watermark(cfg)
    -- ────────────────────────────────────────────────
    function MacLib:Watermark(cfg)
        cfg = cfg or {}

        -- ── config fields ────────────────────────────
        local title         = cfg.Title          or "Watermark"
        local showFPS       = cfg.ShowFPS        ~= false
        local showTime      = cfg.ShowTime       ~= false
        local initPos       = cfg.Position       or Vector2.new(104, 22)
        local dragEnabled   = cfg.Drag           ~= false
        local pColor1       = cfg.ParticleColor1 or Color3.fromRGB(72, 138, 255)
        local pColor2       = cfg.ParticleColor2 or Color3.fromRGB(140, 90, 255)
        local pCount        = cfg.ParticleCount  or 9
        local connectDist   = cfg.ConnectDist    or 58
        local onThePlane    = cfg.OnThePlane     ~= false
        local showOrbit     = cfg.ShowOrbit      ~= false
        local segmentCount  = cfg.SegmentCount   or 10

        -- ── state ────────────────────────────────────
        local visible       = true
        local pos           = initPos
        local pOffsetY      = 0     -- Y correction for GuiInset
        local speedNear     = 18
        local speedFar      = 5
        local tweenConn     = nil

        -- ── sizes ────────────────────────────────────
        local WM_H          = 26
        local PAD_X         = 8
        local LOGO_R        = 8
        local LOGO_DOT_R    = 2
        local ORBIT_FADE    = 0.35   -- orbit ring transparency (0=opaque 1=transparent)

        -- ── compute width ────────────────────────────
        local function computeWidth()
            local base = (LOGO_R * 2 + PAD_X) + (PAD_X)
            -- title width estimate
            local tw = #title * 7
            base = base + tw + PAD_X
            if showFPS then base = base + 42 end
            if showTime then base = base + 70 end
            return math.max(base, 120)
        end
        local WM_W = computeWidth()

        -- ── Drawing objects ──────────────────────────
        -- background rect (line quad)
        local bgLines = {}
        for i = 1, 4 do
            local l = newLine()
            l.Thickness = 1
            l.Color     = Color3.fromRGB(18, 18, 22)
            l.Transparency = 0.18
            table.insert(bgLines, l)
        end

        -- separator line
        local sepLine = newLine()
        sepLine.Color        = Color3.fromRGB(80, 80, 120)
        sepLine.Transparency = 0.6
        sepLine.Thickness    = 1

        -- logo dots
        local logoDots = {}
        do
            local pts = {
                Vector2.new( 0,  -LOGO_R),
                Vector2.new( LOGO_R * 0.85,  -LOGO_R * 0.3),
                Vector2.new( LOGO_R * 0.55,   LOGO_R * 0.8),
                Vector2.new(-LOGO_R * 0.55,   LOGO_R * 0.8),
                Vector2.new(-LOGO_R * 0.85,  -LOGO_R * 0.3),
            }
            for i = 1, 5 do
                local c = newCircle()
                c.Filled    = true
                c.NumSides  = 16
                c.Radius    = LOGO_DOT_R
                logoDots[i] = { circle = c, base = pts[i], phase = (i - 1) / 5 * math.pi * 2 }
            end
        end

        -- logo connector lines (between adjacent dots)
        local logoLines = {}
        for i = 1, 5 do
            local l = newLine()
            l.Thickness   = 1
            l.Transparency = 0.55
            logoLines[i]  = l
        end

        -- orbit ring segments
        local orbitLines = {}
        for i = 1, segmentCount do
            local l = newLine()
            l.Thickness   = 1
            l.Transparency = ORBIT_FADE
            l.Color       = Color3.fromRGB(120, 140, 220)
            orbitLines[i] = l
        end

        -- text labels
        local txtTitle = newText()
        local txtFPS   = newText()
        local txtTime  = newText()
        txtTitle.Size  = 14
        txtFPS.Size    = 12
        txtTime.Size   = 12
        txtFPS.Color   = Color3.fromRGB(140, 180, 255)
        txtTime.Color  = Color3.fromRGB(180, 210, 255)

        -- particles
        local particles = {}
        local particleLines = {}

        local function makeParticles()
            -- destroy old
            for _, p in ipairs(particles) do
                p.circ:Remove()
            end
            for _, l in ipairs(particleLines) do
                l:Remove()
            end
            particles      = {}
            particleLines  = {}

            local margin = 10
            for i = 1, pCount do
                local c    = newCircle()
                c.Filled   = true
                c.NumSides = 8
                c.Radius   = math.random(1, 2)
                c.Visible  = visible

                local px = pos.X + margin + math.random() * (WM_W - 2 * margin)
                local py = pos.Y + margin + math.random() * (WM_H - 2 * margin)
                local angle  = math.random() * math.pi * 2
                local spd    = math.random(speedFar, speedNear)
                local depth  = math.random() -- 0..1, used for size/speed modulation
                local alpha  = math.random(30, 90) / 100
                local col    = pColor1:Lerp(pColor2, math.random())

                particles[i] = {
                    circ  = c,
                    pos   = Vector2.new(px, py),
                    vel   = Vector2.new(math.cos(angle) * spd, math.sin(angle) * spd),
                    depth = depth,
                    alpha = alpha,
                    col   = col,
                }
                c.Color        = col
                c.Transparency = 1 - alpha
            end

            -- prealloc lines
            local needed = pCount * (pCount - 1) / 2
            for i = 1, needed do
                local l = newLine()
                l.Thickness = 1
                particleLines[i] = l
            end
        end

        makeParticles()

        -- ── helper: rebuild orbit lines when segmentCount changes ────
        local function rebuildOrbitLines(newSeg)
            for _, l in ipairs(orbitLines) do
                l:Remove()
            end
            orbitLines = {}
            for i = 1, newSeg do
                local l = newLine()
                l.Thickness   = 1
                l.Transparency = ORBIT_FADE
                l.Color       = Color3.fromRGB(120, 140, 220)
                orbitLines[i] = l
            end
            segmentCount = newSeg
        end

        -- ── compute screen bounds helper ─────────────────────────────
        local function screenSize()
            local cam = workspace.CurrentCamera
            if cam then
                return cam.ViewportSize
            end
            return Vector2.new(1920, 1080)
        end

        -- ── draw ─────────────────────────────────────────────────────
        local function draw(dt)
            if not visible then
                for _, l in ipairs(bgLines)      do l.Visible = false end
                for _, d in ipairs(logoDots)     do d.circle.Visible = false end
                for _, l in ipairs(logoLines)    do l.Visible = false end
                for _, l in ipairs(orbitLines)   do l.Visible = false end
                for _, p in ipairs(particles)    do p.circ.Visible = false end
                for _, l in ipairs(particleLines) do l.Visible = false end
                sepLine.Visible   = false
                txtTitle.Visible  = false
                txtFPS.Visible    = false
                txtTime.Visible   = false
                return
            end

            local x, y = pos.X, pos.Y
            local w, h = WM_W, WM_H

            -- ── background quad (4 lines forming filled rect appearance) ──
            -- We fake a filled rect with a thick horizontal sweep
            -- Actually Drawing has no Rect, so use 4 border lines
            bgLines[1].From = Vector2.new(x,     y)      bgLines[1].To = Vector2.new(x + w, y)
            bgLines[2].From = Vector2.new(x + w, y)      bgLines[2].To = Vector2.new(x + w, y + h)
            bgLines[3].From = Vector2.new(x + w, y + h)  bgLines[3].To = Vector2.new(x,     y + h)
            bgLines[4].From = Vector2.new(x,     y + h)  bgLines[4].To = Vector2.new(x,     y)
            for _, l in ipairs(bgLines) do
                l.Visible    = true
                l.Thickness  = h / 2
                l.Color      = Color3.fromRGB(12, 12, 18)
                l.Transparency = 0.22
            end
            -- override: just use top line with extreme thickness to fill
            bgLines[1].From = Vector2.new(x,     y + h / 2)
            bgLines[1].To   = Vector2.new(x + w, y + h / 2)
            bgLines[1].Thickness = h
            bgLines[2].Visible = false
            bgLines[3].Visible = false
            bgLines[4].Visible = false

            -- ── logo center ──────────────────────────────────────────
            local logoCX = x + PAD_X + LOGO_R
            local logoCY = y + h / 2
            local t_anim = tick()

            -- dot positions (with optional 3D plane effect)
            local dotScreenPos = {}
            for i, d in ipairs(logoDots) do
                local angle  = d.phase + t_anim * 0.9
                local bx, by = d.base.X, d.base.Y
                local sx, sy

                if onThePlane then
                    -- simulate a tilted plane:
                    -- rotate base around Z, then project with tilt
                    local cosA, sinA = math.cos(t_anim * 0.6), math.sin(t_anim * 0.6)
                    local rx = bx * cosA - by * sinA
                    local ry = bx * sinA + by * cosA
                    -- tilt: scale Y by cos of tilt angle
                    local TILT = math.sin(t_anim * 0.25) * 0.5 + 0.5  -- 0..1
                    local tiltCos = math.cos(TILT * math.pi * 0.5)
                    sy = logoCY + ry * tiltCos + math.sin(angle + t_anim * 0.4) * 1.2
                    sx = logoCX + rx
                    -- depth modulation: dots closer look bigger
                    local depthScale = (ry * tiltCos / LOGO_R + 1) * 0.5  -- 0..1
                    d.circle.Radius = LOGO_DOT_R * (0.7 + depthScale * 0.7)
                else
                    -- flat orbit
                    sx = logoCX + bx + math.cos(angle) * 0.8
                    sy = logoCY + by + math.sin(angle) * 0.8
                    d.circle.Radius = LOGO_DOT_R
                end

                dotScreenPos[i] = Vector2.new(sx, sy)
                d.circle.Position   = Vector2.new(sx, sy)
                d.circle.Color      = pColor1:Lerp(pColor2, (i - 1) / 4)
                d.circle.Transparency = 0.1
                d.circle.Visible    = true
            end

            -- logo connector lines
            for i = 1, 5 do
                local j = (i % 5) + 1
                logoLines[i].From        = dotScreenPos[i]
                logoLines[i].To          = dotScreenPos[j]
                logoLines[i].Color       = pColor1:Lerp(pColor2, (i - 1) / 4)
                logoLines[i].Visible     = true
                logoLines[i].Thickness   = 1
                logoLines[i].Transparency = 0.55
            end

            -- orbit ring
            if showOrbit then
                for i = 1, segmentCount do
                    local a0 = (i - 1) / segmentCount * math.pi * 2
                    local a1 = i       / segmentCount * math.pi * 2
                    local fx, fy, tx, ty
                    if onThePlane then
                        local TILT = math.sin(t_anim * 0.25) * 0.5 + 0.5
                        local tiltCos = math.cos(TILT * math.pi * 0.5)
                        fx = logoCX + math.cos(a0) * (LOGO_R + 2)
                        fy = logoCY + math.sin(a0) * (LOGO_R + 2) * tiltCos
                        tx = logoCX + math.cos(a1) * (LOGO_R + 2)
                        ty = logoCY + math.sin(a1) * (LOGO_R + 2) * tiltCos
                    else
                        fx = logoCX + math.cos(a0) * (LOGO_R + 2)
                        fy = logoCY + math.sin(a0) * (LOGO_R + 2)
                        tx = logoCX + math.cos(a1) * (LOGO_R + 2)
                        ty = logoCY + math.sin(a1) * (LOGO_R + 2)
                    end
                    local ol = orbitLines[i]
                    if ol then
                        ol.From    = Vector2.new(fx, fy)
                        ol.To      = Vector2.new(tx, ty)
                        ol.Visible = true
                    end
                end
            else
                for _, l in ipairs(orbitLines) do l.Visible = false end
            end

            -- separator
            local sepX = logoCX + LOGO_R + PAD_X / 2
            sepLine.From    = Vector2.new(sepX, y + 4)
            sepLine.To      = Vector2.new(sepX, y + h - 4)
            sepLine.Visible = true

            -- texts
            local curX = sepX + 6

            txtTitle.Text     = title
            txtTitle.Position = Vector2.new(curX, y + h / 2 - 7)
            txtTitle.Visible  = true
            curX = curX + #title * 7 + PAD_X

            -- FPS icon offset: push left by 4 px compared to old code
            if showFPS then
                local fps  = math.floor(1 / (dt + 0.0001))
                txtFPS.Text     = "FPS " .. fps
                txtFPS.Position = Vector2.new(curX - 4, y + h / 2 - 6)
                txtFPS.Visible  = true
                curX = curX + 40
            else
                txtFPS.Visible = false
            end

            -- Time icon offset: push left by 4 px
            if showTime then
                local hr  = os.date("*t").hour
                local mn  = os.date("*t").min
                txtTime.Text     = string.format("%02d:%02d", hr, mn)
                txtTime.Position = Vector2.new(curX - 4, y + h / 2 - 6)
                txtTime.Visible  = true
            else
                txtTime.Visible = false
            end

            -- ── particles ────────────────────────────────────────────
            -- boundary box for bounce (slightly inside wm bounds)
            local PMARG = 6
            local bx0 = x + PMARG
            local by0 = y + PMARG + pOffsetY
            local bx1 = x + w - PMARG
            local by1 = y + h - PMARG + pOffsetY

            for _, p in ipairs(particles) do
                -- depth-based speed
                local spd = speedFar + (speedNear - speedFar) * p.depth
                -- normalize vel and apply speed
                local vl = math.sqrt(p.vel.X ^ 2 + p.vel.Y ^ 2)
                if vl > 0 then
                    p.vel = Vector2.new(p.vel.X / vl * spd, p.vel.Y / vl * spd)
                end

                local nx = p.pos.X + p.vel.X * dt
                local ny = p.pos.Y + p.vel.Y * dt

                -- bounce off wm edges
                if nx < bx0 then nx = bx0; p.vel = Vector2.new(math.abs(p.vel.X), p.vel.Y) end
                if nx > bx1 then nx = bx1; p.vel = Vector2.new(-math.abs(p.vel.X), p.vel.Y) end
                if ny < by0 then ny = by0; p.vel = Vector2.new(p.vel.X, math.abs(p.vel.Y)) end
                if ny > by1 then ny = by1; p.vel = Vector2.new(p.vel.X, -math.abs(p.vel.Y)) end

                p.pos = Vector2.new(nx, ny)

                -- depth modulation for size
                local sz = math.max(1, math.floor(p.depth * 2.5 + 0.5))
                p.circ.Radius      = sz
                p.circ.Color       = p.col
                p.circ.Position    = Vector2.new(nx, ny + pOffsetY)
                p.circ.Transparency = 1 - p.alpha
                p.circ.Visible     = true
            end

            -- particle connect lines
            local lineIdx = 1
            for i = 1, #particles do
                for j = i + 1, #particles do
                    local pl = particleLines[lineIdx]
                    if pl then
                        local pi = particles[i]
                        local pj = particles[j]
                        local dist = (pi.pos - pj.pos).Magnitude
                        if dist < connectDist then
                            local fade = 1 - dist / connectDist
                            pl.From        = Vector2.new(pi.pos.X, pi.pos.Y + pOffsetY)
                            pl.To          = Vector2.new(pj.pos.X, pj.pos.Y + pOffsetY)
                            pl.Color       = pi.col:Lerp(pj.col, 0.5)
                            pl.Transparency = 1 - fade * 0.5
                            pl.Visible     = true
                        else
                            pl.Visible = false
                        end
                    end
                    lineIdx = lineIdx + 1
                end
            end
            -- hide unused lines
            for k = lineIdx, #particleLines do
                particleLines[k].Visible = false
            end
        end

        -- ── drag logic ───────────────────────────────────────────────
        local dragging = false
        local dragOff  = Vector2.new(0, 0)
        local inputConn, inputEndConn, moveConn

        local function startDrag(inputPos)
            if not dragEnabled then return end
            dragging = true
            dragOff  = pos - inputPos
        end

        inputConn = UIS.InputBegan:Connect(function(inp, gp)
            if gp then return end
            if inp.UserInputType == Enum.UserInputType.MouseButton1 then
                local mp = Vector2.new(inp.Position.X, inp.Position.Y)
                if mp.X >= pos.X and mp.X <= pos.X + WM_W
                and mp.Y >= pos.Y and mp.Y <= pos.Y + WM_H then
                    startDrag(mp)
                end
            elseif inp.UserInputType == Enum.UserInputType.Touch then
                local mp = Vector2.new(inp.Position.X, inp.Position.Y)
                if mp.X >= pos.X and mp.X <= pos.X + WM_W
                and mp.Y >= pos.Y and mp.Y <= pos.Y + WM_H then
                    startDrag(mp)
                end
            end
        end)

        inputEndConn = UIS.InputEnded:Connect(function(inp)
            if inp.UserInputType == Enum.UserInputType.MouseButton1
            or inp.UserInputType == Enum.UserInputType.Touch then
                dragging = false
            end
        end)

        moveConn = UIS.InputChanged:Connect(function(inp)
            if not dragging then return end
            local mp
            if inp.UserInputType == Enum.UserInputType.MouseMovement then
                mp = Vector2.new(inp.Position.X, inp.Position.Y)
            elseif inp.UserInputType == Enum.UserInputType.Touch then
                mp = Vector2.new(inp.Position.X, inp.Position.Y)
            else
                return
            end
            pos = mp + dragOff
        end)

        -- ── tween to position ─────────────────────────────────────────
        local function tweenTo(target)
            if tweenConn then tweenConn:Disconnect(); tweenConn = nil end
            tweenConn = tweenVec2(
                function() return pos end,
                function(v) pos = v end,
                target,
                0.35
            )
        end

        -- ── preset positions ─────────────────────────────────────────
        local function getTopLeft()
            -- slightly right of screen left edge
            return Vector2.new(88, 8)
        end
        local function getTopRight()
            local ss = screenSize()
            -- slightly lower than before
            return Vector2.new(ss.X - WM_W - 12, 14)
        end
        local function getBottomLeft()
            local ss = screenSize()
            -- slightly less left (a bit further from edge)
            return Vector2.new(72, ss.Y - WM_H - 10)
        end

        -- ── run loop ─────────────────────────────────────────────────
        local renderConn = RS.RenderStepped:Connect(function(dt)
            draw(dt)
        end)

        -- ── public object ─────────────────────────────────────────────
        local wm = {}

        function wm:Show()
            visible = true
        end

        function wm:Hide()
            visible = false
        end

        function wm:Toggle()
            visible = not visible
        end

        function wm:Destroy()
            if renderConn   then renderConn:Disconnect()   end
            if inputConn    then inputConn:Disconnect()    end
            if inputEndConn then inputEndConn:Disconnect() end
            if moveConn     then moveConn:Disconnect()     end
            if tweenConn    then tweenConn:Disconnect()    end
            for _, l in ipairs(bgLines)       do l:Remove() end
            for _, d in ipairs(logoDots)      do d.circle:Remove() end
            for _, l in ipairs(logoLines)     do l:Remove() end
            for _, l in ipairs(orbitLines)    do l:Remove() end
            for _, p in ipairs(particles)     do p.circ:Remove() end
            for _, l in ipairs(particleLines) do l:Remove() end
            sepLine:Remove()
            txtTitle:Remove()
            txtFPS:Remove()
            txtTime:Remove()
        end

        function wm:SetTitle(t)
            title = t
            WM_W = computeWidth()
        end

        function wm:SetDrag(v)
            dragEnabled = v
            if not v then
                -- reset to Top-right when drag is disabled
                tweenTo(getTopRight())
            end
        end

        function wm:MoveTopLeft()
            tweenTo(getTopLeft())
        end

        function wm:MoveTopRight()
            tweenTo(getTopRight())
        end

        function wm:MoveBottomLeft()
            tweenTo(getBottomLeft())
        end

        function wm:SetOnThePlane(v)
            onThePlane = v
        end

        function wm:SetOrbit(v)
            showOrbit = v
        end

        function wm:SetSegmentCount(n)
            n = math.clamp(math.floor(n), 3, 48)
            rebuildOrbitLines(n)
        end

        function wm:SetParticleCount(n)
            pCount = math.clamp(math.floor(n), 2, 50)
            makeParticles()
        end

        function wm:SetConnectDist(d)
            connectDist = d
        end

        function wm:SetParticleSpeed(near, far)
            if near then speedNear = near end
            if far  then speedFar  = far  end
        end

        function wm:SetParticleOffsetY(v)
            pOffsetY = v
        end

        function wm:SetParticleColors(c1, c2)
            if c1 then pColor1 = c1 end
            if c2 then pColor2 = c2 end
            -- re-randomize colors on particles
            for _, p in ipairs(particles) do
                p.col = pColor1:Lerp(pColor2, math.random())
            end
        end

        return wm
    end

    if ctx.onLoad then ctx.onLoad() end
end
