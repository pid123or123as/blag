-- Watermark_PreLoader.lua  (v3 — Drawing-based, Neverlose/Thunderhack style)
-- Pure Drawing API: no ScreenGui. Fake-blur via layered semi-transparent squares.
-- Features: icon+text chips, animated accent line, layered bg "glass" effect,
--           spring-style show/hide, rolling-avg FPS, fixed layout.

return function(ctx)
    local MacLib     = ctx.MacLib
    local RunService = game:GetService("RunService")

    -- ── Drawing helpers ──────────────────────────────────────────────────
    local function D(type) return Drawing.new(type) end

    -- Smooth lerp for animation
    local function lerp(a, b, t) return a + (b - a) * t end

    -- ── Icon rbxassetids ─────────────────────────────────────────────────
    -- We'll render icon images via Drawing "Image" if available,
    -- otherwise fallback to unicode glyphs in Drawing "Text"
    local ICON_FPS  = 102994395432803  -- user-provided asset
    local ICON_TIME = 17824308575      -- user-provided asset

    -- ── Color palette (Neverlose dark + blue accent) ──────────────────────
    local C = {
        bg_dark   = Color3.fromRGB(10, 10, 13),       -- main bg
        bg_mid    = Color3.fromRGB(16, 16, 22),        -- title section bg
        accent    = Color3.fromRGB(75, 140, 255),       -- blue accent
        accent2   = Color3.fromRGB(100, 80, 255),       -- purple accent (gradient sim)
        text_main = Color3.fromRGB(225, 225, 235),      -- primary text
        text_muted= Color3.fromRGB(140, 140, 155),      -- secondary text
        white     = Color3.fromRGB(255, 255, 255),
        sep       = Color3.fromRGB(40, 40, 55),         -- separator line
    }

    -- ── Layout constants ─────────────────────────────────────────────────
    local PAD_X    = 10   -- horizontal padding inside chip
    local PAD_Y    = 6    -- vertical padding
    local H        = 30   -- total height
    local ICON_SZ  = 14   -- icon square size
    local FONT     = Drawing.Fonts and Drawing.Fonts.UI or 0
    local TXT_SZ   = 13
    local SEP_W    = 1    -- separator width
    local CORNER   = 4    -- rounding for image objects (if supported)

    -- ── State ─────────────────────────────────────────────────────────────
    local allObjs  = {}   -- all Drawing objects, for bulk remove
    local function reg(obj) table.insert(allObjs, obj); return obj end

    local visible  = true
    local alpha    = 0    -- 0=hidden 1=shown, used for fade animation
    local targetA  = 1

    -- FPS rolling average
    local FPS_N    = 30
    local fpsBuf   = table.create(FPS_N, 1/60)
    local fpsBufI  = 1
    local fpsVal   = 0
    local fpsTimer = 0

    -- Time
    local lastSec  = -1
    local timeStr  = "00:00:00"

    -- Animated accent bar phase
    local accentPhase = 0

    -- Position (top-left corner of whole watermark)
    local POS_X = 18
    local POS_Y = 22

    -- ========================================================================
    function MacLib:Watermark(cfg)
        cfg = cfg or {}
        local titleText = cfg.Title    or "Watermark"
        local showFPS   = cfg.ShowFPS  ~= false
        local showTime  = cfg.ShowTime ~= false

        if cfg.Position then
            -- accept UDim2 or Vector2
            if typeof(cfg.Position) == "UDim2" then
                local vp = workspace.CurrentCamera.ViewportSize
                POS_X = cfg.Position.X.Offset + cfg.Position.X.Scale * vp.X
                POS_Y = cfg.Position.Y.Offset + cfg.Position.Y.Scale * vp.Y
            elseif typeof(cfg.Position) == "Vector2" then
                POS_X = cfg.Position.X
                POS_Y = cfg.Position.Y
            end
        end

        -- ── Measure text widths ──────────────────────────────────────────
        -- We create hidden probe texts to measure TextBounds
        local function measureText(str, size)
            local t = Drawing.new("Text")
            t.Text    = str
            t.Size    = size or TXT_SZ
            t.Font    = FONT
            t.Visible = false
            local b = t.TextBounds
            t:Remove()
            return b.X, b.Y
        end

        -- Pre-measure all sections
        local titleW = measureText(titleText, TXT_SZ) + PAD_X * 2
        local fpsW   = showFPS   and (ICON_SZ + 4 + measureText("000", TXT_SZ) + PAD_X * 2) or 0
        local timeW  = showTime  and (ICON_SZ + 4 + measureText("00:00:00", TXT_SZ) + PAD_X * 2) or 0

        -- Total width: title + (optional) fps + (optional) time + separators
        local numSeps = (showFPS and 1 or 0) + (showTime and 1 or 0)
        local totalW  = titleW + fpsW + timeW + numSeps * SEP_W

        -- ── Build all Drawing objects ────────────────────────────────────
        -- Layer order (ZIndex): bg=1, blur sim=2, accent=3, sep=4, icons=5, text=6

        -- 1) Outer shadow (fake depth) — slightly larger dark square
        local shadow = reg(D("Square"))
        shadow.Filled      = true
        shadow.Color       = Color3.fromRGB(0,0,0)
        shadow.Transparency = 0.55
        shadow.Thickness   = 0
        shadow.ZIndex      = 1

        -- 2) Main background (dark glass)
        local bgMain = reg(D("Square"))
        bgMain.Filled      = true
        bgMain.Color       = C.bg_dark
        bgMain.Transparency = 0.08   -- mostly opaque, slight transparency = "glass feel"
        bgMain.Thickness   = 0
        bgMain.ZIndex      = 2

        -- 3) Blur simulation: multiple thin semi-transparent layers stacked
        --    Real GPU blur is impossible in Roblox even with exploits.
        --    Best approximation: 3 offset squares at different transparencies
        --    giving a "frosted glass" impression when overlaid on game world.
        local blurLayers = {}
        local blurColors = {
            Color3.fromRGB(20,20,30),
            Color3.fromRGB(15,15,25),
            Color3.fromRGB(25,25,40),
        }
        local blurAlphas = { 0.82, 0.88, 0.75 }
        local blurOffset = { {0,0}, {1,0}, {0,1} }
        for i = 1,3 do
            local bl = reg(D("Square"))
            bl.Filled      = true
            bl.Color       = blurColors[i]
            bl.Transparency = blurAlphas[i]
            bl.Thickness   = 0
            bl.ZIndex      = 3
            table.insert(blurLayers, { sq = bl, ox = blurOffset[i][1], oy = blurOffset[i][2] })
        end

        -- 4) Title section bg (slightly different tint = visual separation)
        local bgTitle = reg(D("Square"))
        bgTitle.Filled      = true
        bgTitle.Color       = C.bg_mid
        bgTitle.Transparency = 0.05
        bgTitle.Thickness   = 0
        bgTitle.ZIndex      = 4

        -- 5) Outer border (1px, dim)
        local border = reg(D("Square"))
        border.Filled      = false
        border.Color       = C.sep
        border.Transparency = 0.4
        border.Thickness   = 1
        border.ZIndex      = 5

        -- 6) Accent bottom line (animated gradient shimmer simulation)
        --    We use 3 overlapping lines of different color to simulate gradient
        local accentLines = {}
        for i = 1, 3 do
            local al = reg(D("Line"))
            al.Thickness  = 1
            al.ZIndex     = 6
            al.Transparency = 1
            table.insert(accentLines, al)
        end

        -- 7) Separator lines between chips
        local seps = {}
        local function makeSep()
            local s = reg(D("Line"))
            s.Color       = C.sep
            s.Transparency = 0.5
            s.Thickness   = 1
            s.ZIndex      = 7
            table.insert(seps, s)
            return s
        end

        -- Separator after title
        local sep1 = makeSep()
        -- Separator after FPS (only if time shown)
        local sep2 = showFPS and showTime and makeSep() or nil

        -- 8) Title text (SemiBold sim: outline trick)
        local titleLbl = reg(D("Text"))
        titleLbl.Text         = titleText
        titleLbl.Size         = TXT_SZ
        titleLbl.Font         = FONT
        titleLbl.Color        = C.text_main
        titleLbl.Outline      = true
        titleLbl.OutlineColor = Color3.fromRGB(0,0,0)
        titleLbl.Transparency = 1
        titleLbl.ZIndex       = 8
        titleLbl.Center       = false

        -- 9) FPS icon (Drawing Image if rbxassetid works, else Text glyph)
        local fpsIcon, fpsLbl
        if showFPS then
            -- Try Drawing Image for the icon
            fpsIcon = reg(D("Image"))
            -- rbxassetid numeric → packed into Data field on some executors
            -- Fallback: if executor doesn't support Image drawing, we use text
            pcall(function()
                fpsIcon.Data = "rbxassetid://" .. tostring(ICON_FPS)
                fpsIcon.Rounding = 2
            end)
            fpsIcon.Transparency = 1
            fpsIcon.ZIndex = 8

            fpsLbl = reg(D("Text"))
            fpsLbl.Text         = "000"
            fpsLbl.Size         = TXT_SZ
            fpsLbl.Font         = FONT
            fpsLbl.Color        = C.text_muted
            fpsLbl.Outline      = false
            fpsLbl.Transparency = 1
            fpsLbl.ZIndex       = 8
            fpsLbl.Center       = false
        end

        local timeIcon, timeLbl
        if showTime then
            timeIcon = reg(D("Image"))
            pcall(function()
                timeIcon.Data = "rbxassetid://" .. tostring(ICON_TIME)
                timeIcon.Rounding = 2
            end)
            timeIcon.Transparency = 1
            timeIcon.ZIndex = 8

            timeLbl = reg(D("Text"))
            timeLbl.Text         = "00:00:00"
            timeLbl.Size         = TXT_SZ
            timeLbl.Font         = FONT
            timeLbl.Color        = C.text_muted
            timeLbl.Outline      = false
            timeLbl.Transparency = 1
            timeLbl.ZIndex       = 8
            timeLbl.Center       = false
        end

        -- ── Layout function: positions all objects given current POS_X/Y ─
        local function layout()
            local x = POS_X
            local y = POS_Y
            local W = totalW
            local shadowPad = 6

            -- shadow
            shadow.Position = Vector2.new(x - 2 + shadowPad*0.5, y + 2 + shadowPad*0.5)
            shadow.Size     = Vector2.new(W + 4, H + 2)

            -- blur layers
            for _, bl in ipairs(blurLayers) do
                bl.sq.Position = Vector2.new(x + bl.ox, y + bl.oy)
                bl.sq.Size     = Vector2.new(W + 4, H)
            end

            -- main bg
            bgMain.Position = Vector2.new(x, y)
            bgMain.Size     = Vector2.new(W, H)

            -- title bg (left portion)
            bgTitle.Position = Vector2.new(x, y)
            bgTitle.Size     = Vector2.new(titleW, H)

            -- outer border
            border.Position = Vector2.new(x - 0.5, y - 0.5)
            border.Size     = Vector2.new(W + 1, H + 1)

            -- accent bottom lines (will be animated, just set base positions)
            local bY = y + H - 1
            accentLines[1].From = Vector2.new(x,         bY); accentLines[1].To = Vector2.new(x + W*0.5,  bY)
            accentLines[2].From = Vector2.new(x + W*0.4, bY); accentLines[2].To = Vector2.new(x + W*0.8,  bY)
            accentLines[3].From = Vector2.new(x + W*0.7, bY); accentLines[3].To = Vector2.new(x + W,      bY)

            -- sep1 (after title)
            local s1x = x + titleW
            sep1.From = Vector2.new(s1x, y + 4)
            sep1.To   = Vector2.new(s1x, y + H - 4)

            -- Title text: vertically centered, left-padded
            local tY = y + (H - TXT_SZ) * 0.5
            titleLbl.Position = Vector2.new(x + PAD_X, tY)

            -- FPS chip
            if showFPS then
                local chipX = x + titleW + SEP_W
                local iconX = chipX + PAD_X
                local iconY = y + (H - ICON_SZ) * 0.5
                fpsIcon.Position = Vector2.new(iconX, iconY)
                fpsIcon.Size     = Vector2.new(ICON_SZ, ICON_SZ)
                fpsLbl.Position  = Vector2.new(iconX + ICON_SZ + 4, tY)

                if sep2 then
                    local s2x = chipX + fpsW
                    sep2.From = Vector2.new(s2x, y + 4)
                    sep2.To   = Vector2.new(s2x, y + H - 4)
                end
            end

            -- Time chip
            if showTime then
                local chipX = x + titleW + SEP_W + fpsW + (sep2 and SEP_W or 0)
                local iconX = chipX + PAD_X
                local iconY = y + (H - ICON_SZ) * 0.5
                timeIcon.Position = Vector2.new(iconX, iconY)
                timeIcon.Size     = Vector2.new(ICON_SZ, ICON_SZ)
                timeLbl.Position  = Vector2.new(iconX + ICON_SZ + 4, tY)
            end
        end

        layout()

        -- ── Animation helpers ──────────────────────────────────────────────
        local function applyAlpha(a)
            -- a: 0 = invisible, 1 = fully visible
            -- Drawing Transparency: 0=opaque, 1=invisible  → invert
            local inv = 1 - a

            shadow.Transparency  = math.min(1, 0.55 + inv * 0.45)
            bgMain.Transparency  = math.min(1, 0.08 + inv * 0.92)
            bgTitle.Transparency = math.min(1, 0.05 + inv * 0.95)
            border.Transparency  = math.min(1, 0.4  + inv * 0.6)
            for _, bl in ipairs(blurLayers) do
                bl.sq.Transparency = math.min(1, bl.sq.Transparency * 1 + inv * (1 - bl.sq.Transparency))
            end

            titleLbl.Transparency = inv
            sep1.Transparency     = math.min(1, 0.5 + inv * 0.5)
            if sep2 then sep2.Transparency = math.min(1, 0.5 + inv * 0.5) end

            for _, al in ipairs(accentLines) do
                al.Transparency = inv
            end

            if fpsIcon  then fpsIcon.Transparency  = inv end
            if fpsLbl   then fpsLbl.Transparency   = inv end
            if timeIcon then timeIcon.Transparency  = inv end
            if timeLbl  then timeLbl.Transparency   = inv end
        end

        -- Spring lerp speed: fast spring (iOS deceleration feel)
        local SPRING_SPEED = 12  -- higher = snappier

        -- ── Main loop ─────────────────────────────────────────────────────
        local conn
        conn = RunService.Heartbeat:Connect(function(dt)
            -- Spring animation toward target
            local speed = targetA > alpha and SPRING_SPEED or (SPRING_SPEED * 1.5)
            alpha = lerp(alpha, targetA, math.min(1, dt * speed))
            if math.abs(alpha - targetA) < 0.001 then alpha = targetA end

            applyAlpha(alpha)

            -- Animated accent bottom bar (shimmer/pulse effect)
            -- Simulates the Neverlose gradient line by animating color phases
            accentPhase = (accentPhase + dt * 0.8) % (math.pi * 2)
            local t1 = (math.sin(accentPhase) + 1) * 0.5          -- 0..1
            local t2 = (math.sin(accentPhase + 2.1) + 1) * 0.5
            local t3 = (math.sin(accentPhase + 4.2) + 1) * 0.5

            local function blendC(a, b, t)
                return Color3.fromRGB(
                    math.round(lerp(a.R*255, b.R*255, t)),
                    math.round(lerp(a.G*255, b.G*255, t)),
                    math.round(lerp(a.B*255, b.B*255, t))
                )
            end
            accentLines[1].Color = blendC(C.accent, C.accent2, t1)
            accentLines[2].Color = blendC(C.accent2, C.accent, t2)
            accentLines[3].Color = blendC(C.accent, C.accent2, t3)

            -- FPS
            if fpsLbl then
                fpsBuf[fpsBufI] = dt
                fpsBufI = (fpsBufI % FPS_N) + 1
                fpsTimer += dt
                if fpsTimer >= 0.25 then
                    fpsTimer = 0
                    local sum = 0
                    for i = 1, FPS_N do sum += fpsBuf[i] end
                    local avg = sum / FPS_N
                    fpsVal = avg > 0 and math.round(1/avg) or 0
                    fpsLbl.Text = tostring(fpsVal)
                end
            end

            -- Time (update every second)
            if timeLbl then
                local now = os.time()
                if now ~= lastSec then
                    lastSec = now
                    local h = math.floor(now/3600)%24
                    local m = math.floor(now/60)%60
                    local s = now%60
                    timeStr = string.format("%02d:%02d:%02d", h, m, s)
                    timeLbl.Text = timeStr
                end
            end
        end)

        -- ── Public API ─────────────────────────────────────────────────────
        local WM = {}

        function WM:Show()
            if not visible then
                visible = true
                targetA = 1
            end
        end

        function WM:Hide()
            if visible then
                visible = false
                targetA = 0
            end
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
                local vp = workspace.CurrentCamera.ViewportSize
                POS_X = pos.X.Offset + pos.X.Scale * vp.X
                POS_Y = pos.Y.Offset + pos.Y.Scale * vp.Y
            elseif typeof(pos) == "Vector2" then
                POS_X = pos.X; POS_Y = pos.Y
            end
            layout()
        end

        function WM:SetVisible(state)
            if state then self:Show() else self:Hide() end
        end

        function WM:Destroy()
            conn:Disconnect()
            for _, obj in ipairs(allObjs) do
                pcall(function() obj:Remove() end)
            end
            table.clear(allObjs)
        end

        -- Initial appear (spring from 0)
        alpha = 0; targetA = 1

        return WM
    end

    if ctx.onLoad then ctx.onLoad() end
end
