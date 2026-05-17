-- Watermark_PreLoader.lua  (v2 — V11 compatible)
-- Registers MacLib:Watermark(cfg)
-- Fixes: spring animation, stable FPS rolling avg, fixed-width chips, styled title chip

return function(ctx)
    local MacLib       = ctx.MacLib
    local TweenService = game:GetService("TweenService")
    local RunService   = game:GetService("RunService")

    local function Tween(obj, info, props)
        local t = TweenService:Create(obj, info, props); t:Play(); return t
    end

    local function GetGui()
        local g = Instance.new("ScreenGui")
        g.ResetOnSpawn   = false
        g.DisplayOrder   = 9998
        g.IgnoreGuiInset = true
        g.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
        local ok
        if gethui then ok = pcall(function() g.Parent = gethui() end) end
        if not ok or not g.Parent then ok = pcall(function() g.Parent = game:GetService("CoreGui") end) end
        if not ok or not g.Parent then g.Parent = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui") end
        return g
    end

    function MacLib:Watermark(cfg)
        cfg = cfg or {}
        local titleText = cfg.Title    or "Watermark"
        local showFPS   = cfg.ShowFPS  ~= false
        local showTime  = cfg.ShowTime ~= false

        local gui = GetGui()
        gui.Name = "MacLibWatermark"

        local anchor = Instance.new("Frame")
        anchor.Name = "WmAnchor"; anchor.AnchorPoint = Vector2.new(0, 0)
        anchor.Position = cfg.Position or UDim2.fromOffset(14, 14)
        anchor.BackgroundTransparency = 1; anchor.BorderSizePixel = 0
        anchor.AutomaticSize = Enum.AutomaticSize.XY; anchor.Parent = gui

        local wrapper = Instance.new("Frame")
        wrapper.Name = "WmWrapper"; wrapper.AnchorPoint = Vector2.new(0, 0)
        wrapper.Position = UDim2.fromScale(0, 0); wrapper.BackgroundTransparency = 1
        wrapper.BorderSizePixel = 0; wrapper.AutomaticSize = Enum.AutomaticSize.XY
        wrapper.ClipsDescendants = false; wrapper.Parent = anchor

        local uiScale = Instance.new("UIScale"); uiScale.Scale = 0; uiScale.Parent = wrapper

        local row = Instance.new("Frame")
        row.Name = "WmRow"; row.BackgroundTransparency = 1
        row.BorderSizePixel = 0; row.AutomaticSize = Enum.AutomaticSize.XY; row.Parent = wrapper

        local rowLayout = Instance.new("UIListLayout")
        rowLayout.FillDirection = Enum.FillDirection.Horizontal
        rowLayout.VerticalAlignment = Enum.VerticalAlignment.Center
        rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
        rowLayout.Padding = UDim.new(0, 4); rowLayout.Parent = row

        local CHIP_H = 28; local CHIP_PAD_H = 12; local CHIP_RADIUS = 8
        local CHIP_BG = Color3.fromRGB(12, 12, 14)
        local CHIP_BG_T = 0.08; local CHIP_STROKE_T = 0.80; local TXT_T = 0.05
        local FONT_BODY  = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Medium)
        local FONT_TITLE = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.SemiBold)

        local allChips = {}

        local function makeChip(order, defaultText, opts)
            opts = opts or {}
            local chip = Instance.new("Frame")
            chip.Name = "Chip"..order; chip.BackgroundColor3 = opts.bg or CHIP_BG
            chip.BackgroundTransparency = CHIP_BG_T; chip.BorderSizePixel = 0
            chip.LayoutOrder = order
            chip.AutomaticSize = opts.fixedW and Enum.AutomaticSize.None or Enum.AutomaticSize.X
            chip.Size = opts.fixedW and UDim2.fromOffset(opts.fixedW, CHIP_H) or UDim2.fromOffset(0, CHIP_H)
            chip.Parent = row
            Instance.new("UICorner", chip).CornerRadius = UDim.new(0, CHIP_RADIUS)
            local stroke = Instance.new("UIStroke")
            stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
            stroke.Color = Color3.fromRGB(255,255,255); stroke.Transparency = CHIP_STROKE_T
            stroke.Thickness = 1; stroke.Parent = chip
            local pad = Instance.new("UIPadding")
            pad.PaddingLeft = UDim.new(0, CHIP_PAD_H); pad.PaddingRight = UDim.new(0, CHIP_PAD_H)
            pad.Parent = chip
            local lbl = Instance.new("TextLabel")
            lbl.Name = "Lbl"; lbl.FontFace = opts.font or FONT_BODY
            lbl.TextSize = opts.textSize or 13; lbl.TextColor3 = Color3.fromRGB(255,255,255)
            lbl.TextTransparency = TXT_T; lbl.BackgroundTransparency = 1
            lbl.BorderSizePixel = 0; lbl.RichText = false
            lbl.TextTruncate = Enum.TextTruncate.None
            lbl.Size = UDim2.new(1, 0, 1, 0); lbl.TextXAlignment = Enum.TextXAlignment.Center
            lbl.Text = defaultText; lbl.Parent = chip
            local entry = { frame = chip, label = lbl, stroke = stroke }
            table.insert(allChips, entry)
            return entry
        end

        -- Title chip: dark tinted bg + blue accent stroke + left stripe
        local titleChip = makeChip(1, titleText, {
            bg = Color3.fromRGB(15, 16, 24), font = FONT_TITLE, textSize = 13,
        })
        local stripe = Instance.new("Frame")
        stripe.Name = "AccentStripe"; stripe.AnchorPoint = Vector2.new(0, 0.5)
        stripe.Position = UDim2.new(0, 0, 0.5, 0); stripe.Size = UDim2.fromOffset(2, 14)
        stripe.BackgroundColor3 = Color3.fromRGB(75, 155, 255); stripe.BackgroundTransparency = 0
        stripe.BorderSizePixel = 0; stripe.ZIndex = 3; stripe.Parent = titleChip.frame
        Instance.new("UICorner", stripe).CornerRadius = UDim.new(1, 0)
        titleChip.stroke.Color = Color3.fromRGB(75, 155, 255); titleChip.stroke.Transparency = 0.65

        -- FPS chip: fixed width prevents layout jitter
        local fpsChip
        if showFPS then fpsChip = makeChip(2, "FPS  --", { fixedW = 78 }) end

        -- Time chip: fixed width
        local timeChip
        if showTime then timeChip = makeChip(3, "00:00:00", { fixedW = 88 }) end

        -- ==================================================================
        -- ANIMATION: iOS/macOS spring-style
        --   Appear  → Back Out (overshoot scale 0.80→1.0) + Quint Out (fade)
        --   Disappear → Quint In (fast, clean scale 1→0.82 + fade)
        -- ==================================================================
        local APPEAR_SCALE = TweenInfo.new(0.40, Enum.EasingStyle.Back,  Enum.EasingDirection.Out)
        local APPEAR_FADE  = TweenInfo.new(0.24, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
        local DISAPPEAR    = TweenInfo.new(0.16, Enum.EasingStyle.Quint, Enum.EasingDirection.In)

        local visible = true

        local function setVisible(show, animate)
            if animate then
                if show then
                    uiScale.Scale = 0.80
                    for _, c in ipairs(allChips) do
                        c.frame.BackgroundTransparency = 1
                        c.label.TextTransparency = 1
                        c.stroke.Transparency = 1
                    end
                    Tween(uiScale, APPEAR_SCALE, { Scale = 1 })
                    for _, c in ipairs(allChips) do
                        Tween(c.frame,  APPEAR_FADE, { BackgroundTransparency = CHIP_BG_T })
                        Tween(c.label,  APPEAR_FADE, { TextTransparency = TXT_T })
                        Tween(c.stroke, APPEAR_FADE, { Transparency = CHIP_STROKE_T })
                    end
                    Tween(titleChip.stroke, APPEAR_FADE, { Transparency = 0.65 })
                else
                    Tween(uiScale, DISAPPEAR, { Scale = 0.82 })
                    for _, c in ipairs(allChips) do
                        Tween(c.frame,  DISAPPEAR, { BackgroundTransparency = 1 })
                        Tween(c.label,  DISAPPEAR, { TextTransparency = 1 })
                        Tween(c.stroke, DISAPPEAR, { Transparency = 1 })
                    end
                    task.delay(0.18, function() if not visible then gui.Enabled = false end end)
                end
            else
                uiScale.Scale = show and 1 or 0
                for _, c in ipairs(allChips) do
                    c.frame.BackgroundTransparency = show and CHIP_BG_T or 1
                    c.label.TextTransparency = show and TXT_T or 1
                    c.stroke.Transparency = show and CHIP_STROKE_T or 1
                end
            end
        end

        task.defer(function()
            setVisible(false, false); task.wait(0.08); setVisible(true, true)
        end)

        -- ==================================================================
        -- FPS: rolling average over 30 Heartbeat samples → update every 0.25s
        -- Text is only updated at 4Hz, chip width is fixed → zero layout jitter
        -- ==================================================================
        local FPS_SAMPLES = 30
        local fpsBuf = table.create(FPS_SAMPLES, 1/60)
        local fpsBufIdx = 1; local fpsTimer = 0

        -- Time: only recalc when second changes
        local lastSecond = -1

        local conn
        conn = RunService.Heartbeat:Connect(function(dt)
            if not gui or not gui.Parent then conn:Disconnect(); return end
            if fpsChip then
                fpsBuf[fpsBufIdx] = dt
                fpsBufIdx = (fpsBufIdx % FPS_SAMPLES) + 1
                fpsTimer += dt
                if fpsTimer >= 0.25 then
                    fpsTimer = 0
                    local sum = 0
                    for i = 1, FPS_SAMPLES do sum += fpsBuf[i] end
                    local avgDt = sum / FPS_SAMPLES
                    fpsChip.label.Text = "FPS  " .. tostring(avgDt > 0 and math.round(1/avgDt) or 0)
                end
            end
            if timeChip then
                local now = os.time()
                if now ~= lastSecond then
                    lastSecond = now
                    local h = math.floor(now/3600)%24
                    local m = math.floor(now/60)%60
                    local s = now%60
                    timeChip.label.Text = string.format("%02d:%02d:%02d", h, m, s)
                end
            end
        end)

        local WM = {}
        function WM:Show()    if not visible then visible=true; gui.Enabled=true; setVisible(true,true) end end
        function WM:Hide()    if visible then visible=false; setVisible(false,true) end end
        function WM:Toggle()  if visible then self:Hide() else self:Show() end end
        function WM:SetTitle(text) titleText=text; titleChip.label.Text=text end
        function WM:SetPosition(udim2) anchor.Position=udim2 end
        function WM:SetVisible(state) if state then self:Show() else self:Hide() end end
        function WM:IsVisible() return visible end
        function WM:Destroy() conn:Disconnect(); gui:Destroy() end
        return WM
    end

    if ctx.onLoad then ctx.onLoad() end
end
