-- Watermark_PreLoader.lua
-- Registers MacLib:Watermark(cfg) — compact pill-style HUD with FPS + Time
-- Separate backgrounds per chip. No Discord link/logo.
-- Animation: Windows-style "ease" (Exponential Out scale+fade from top-left)

return function(ctx)
    local MacLib = ctx.MacLib
    local TweenService = game:GetService("TweenService")
    local RunService   = game:GetService("RunService")
    local Stats        = game:GetService("Stats")

    -- ── helpers ──────────────────────────────────────────────────────────
    local function Tween(obj, info, props)
        local t = TweenService:Create(obj, info, props); t:Play(); return t
    end

    local function GetGui()
        if syn and syn.protect_gui then
            local g = Instance.new("ScreenGui")
            syn.protect_gui(g)
            g.Parent = game:GetService("CoreGui")
            return g
        end
        local ok, cg = pcall(function() return game:GetService("CoreGui") end)
        if ok then
            local g = Instance.new("ScreenGui"); g.Parent = cg; return g
        end
        local g = Instance.new("ScreenGui")
        g.Parent = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
        return g
    end

    -- ── public API ───────────────────────────────────────────────────────
    function MacLib:Watermark(cfg)
        cfg = cfg or {}
        local title    = cfg.Title    or "Watermark"
        local showFPS  = cfg.ShowFPS  ~= false
        local showTime = cfg.ShowTime ~= false
        local accentR, accentG, accentB = 80, 160, 255 -- chip accent tint

        -- ── GUI root ─────────────────────────────────────────────────────
        local gui = GetGui()
        gui.Name          = "MacLibWatermark"
        gui.ResetOnSpawn  = false
        gui.DisplayOrder  = 9998
        gui.IgnoreGuiInset = true

        -- wrapper: only controls position/anchor, NOT background
        local wrapper = Instance.new("Frame")
        wrapper.Name              = "WmWrapper"
        wrapper.AnchorPoint       = Vector2.new(0, 0)
        wrapper.Position          = UDim2.fromOffset(14, 14)
        wrapper.BackgroundTransparency = 1
        wrapper.BorderSizePixel   = 0
        wrapper.AutomaticSize     = Enum.AutomaticSize.XY
        wrapper.Parent            = gui

        -- horizontal row of chips
        local row = Instance.new("Frame")
        row.Name              = "WmRow"
        row.BackgroundTransparency = 1
        row.BorderSizePixel   = 0
        row.AutomaticSize     = Enum.AutomaticSize.XY
        row.Parent            = wrapper

        local rowLayout = Instance.new("UIListLayout")
        rowLayout.FillDirection       = Enum.FillDirection.Horizontal
        rowLayout.VerticalAlignment   = Enum.VerticalAlignment.Center
        rowLayout.SortOrder           = Enum.SortOrder.LayoutOrder
        rowLayout.Padding             = UDim.new(0, 5)
        rowLayout.Parent              = row

        -- ── chip factory ─────────────────────────────────────────────────
        local CHIP_H   = 26
        local CHIP_PAD = 10   -- horizontal padding inside chip
        local CHIP_BG  = Color3.fromRGB(14, 14, 16)
        local CHIP_BG_T = 0.12
        local CHIP_STROKE_T = 0.82
        local FONT = Font.new("rbxasset://fonts/families/GothamSSm.json",
                              Enum.FontWeight.Medium)

        local chips = {}   -- { frame, label, stroke }

        local function makeChip(order, defaultText, accentBg)
            local chip = Instance.new("Frame")
            chip.Name              = "Chip_" .. order
            chip.BackgroundColor3  = accentBg or CHIP_BG
            chip.BackgroundTransparency = CHIP_BG_T
            chip.BorderSizePixel   = 0
            chip.AutomaticSize     = Enum.AutomaticSize.X
            chip.Size              = UDim2.fromOffset(0, CHIP_H)
            chip.LayoutOrder       = order
            chip.Parent            = row

            local corner = Instance.new("UICorner")
            corner.CornerRadius = UDim.new(0, 6)
            corner.Parent = chip

            local stroke = Instance.new("UIStroke")
            stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
            stroke.Color           = Color3.fromRGB(255, 255, 255)
            stroke.Transparency    = CHIP_STROKE_T
            stroke.Thickness       = 1
            stroke.Parent          = chip

            local pad = Instance.new("UIPadding")
            pad.PaddingLeft  = UDim.new(0, CHIP_PAD)
            pad.PaddingRight = UDim.new(0, CHIP_PAD)
            pad.Parent       = chip

            local lbl = Instance.new("TextLabel")
            lbl.Name               = "ChipLabel"
            lbl.FontFace           = FONT
            lbl.TextSize           = 13
            lbl.TextColor3         = Color3.fromRGB(255, 255, 255)
            lbl.TextTransparency   = 0.08
            lbl.BackgroundTransparency = 1
            lbl.BorderSizePixel    = 0
            lbl.AutomaticSize      = Enum.AutomaticSize.X
            lbl.Size               = UDim2.fromOffset(0, CHIP_H)
            lbl.Text               = defaultText
            lbl.RichText           = false
            lbl.Parent             = chip

            table.insert(chips, { frame = chip, label = lbl, stroke = stroke })
            return lbl
        end

        -- ── create chips ─────────────────────────────────────────────────
        -- Chip 1: title (slightly accented bg)
        local titleLabel = makeChip(1, title, Color3.fromRGB(18, 18, 22))

        -- Chip 2: FPS
        local fpsLabel
        if showFPS then
            fpsLabel = makeChip(2, "FPS: --")
        end

        -- Chip 3: Time
        local timeLabel
        if showTime then
            timeLabel = makeChip(3, "00:00:00")
        end

        -- ── animation helpers ─────────────────────────────────────────────
        -- "Windows ease" = Exponential Out: fast start, smooth settle
        local EASE_IN  = TweenInfo.new(0.22, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out)
        local EASE_OUT = TweenInfo.new(0.16, Enum.EasingStyle.Sine,        Enum.EasingDirection.In)

        -- We animate via UIScale on wrapper + per-chip transparency
        local uiScale = Instance.new("UIScale")
        uiScale.Scale = 0
        uiScale.Parent = wrapper

        local visible = true

        local function setVisuals(show, animate)
            local targetScale = show and 1 or 0
            local targetBgT   = show and CHIP_BG_T or 1
            local targetTxtT  = show and 0.08 or 1
            local targetStT   = show and CHIP_STROKE_T or 1
            local info        = show and EASE_IN or EASE_OUT

            if animate then
                Tween(uiScale, info, { Scale = targetScale })
                for _, c in ipairs(chips) do
                    Tween(c.frame,  info, { BackgroundTransparency = targetBgT })
                    Tween(c.label,  info, { TextTransparency = targetTxtT })
                    Tween(c.stroke, info, { Transparency = targetStT })
                end
            else
                uiScale.Scale = targetScale
                for _, c in ipairs(chips) do
                    c.frame.BackgroundTransparency = targetBgT
                    c.label.TextTransparency       = targetTxtT
                    c.stroke.Transparency          = targetStT
                end
            end
        end

        -- initial appear
        task.defer(function()
            setVisuals(false, false)
            task.wait(0.05)
            setVisuals(true, true)
        end)

        -- ── runtime updates ───────────────────────────────────────────────
        local conn
        conn = RunService.Heartbeat:Connect(function()
            if not gui or not gui.Parent then
                conn:Disconnect(); return
            end

            if fpsLabel then
                local fps = math.round(1 / Stats.HeartbeatTime)
                fpsLabel.Text = "FPS: " .. tostring(fps)
            end

            if timeLabel then
                local t = os.time()
                local h = math.floor(t / 3600) % 24
                local m = math.floor(t / 60)   % 60
                local s = t % 60
                timeLabel.Text = string.format("%02d:%02d:%02d", h, m, s)
            end
        end)

        -- ── public object ─────────────────────────────────────────────────
        local WatermarkFunctions = {}

        function WatermarkFunctions:Show()
            if not visible then
                visible = true
                gui.Enabled = true
                setVisuals(true, true)
            end
        end

        function WatermarkFunctions:Hide()
            if visible then
                visible = false
                local t = Tween(uiScale, EASE_OUT, { Scale = 0 })
                for _, c in ipairs(chips) do
                    Tween(c.frame,  EASE_OUT, { BackgroundTransparency = 1 })
                    Tween(c.label,  EASE_OUT, { TextTransparency = 1 })
                    Tween(c.stroke, EASE_OUT, { Transparency = 1 })
                end
                t.Completed:Connect(function() gui.Enabled = false end)
            end
        end

        function WatermarkFunctions:SetTitle(text)
            title = text
            titleLabel.Text = text
        end

        function WatermarkFunctions:SetPosition(udim2)
            wrapper.Position = udim2
        end

        function WatermarkFunctions:Destroy()
            conn:Disconnect()
            gui:Destroy()
        end

        return WatermarkFunctions
    end

    if ctx.onLoad then ctx.onLoad() end
end
