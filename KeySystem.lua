--[[
    MacLib — KeySystem
    MacLib:KeySystem(config) -> KeySystemFunctions

    config = {
        Key             = "1234",
        Title           = "Key System",
        Subtitle        = "Enter your key to continue.",
        DiscordInvite   = "A58yhBsJfY",
        DiscordLink     = "https://discord.gg/A58yhBsJfY",
        ManualBtnText   = "Copy link",
        ManualCopyImage = "rbxassetid://90434151822042",
        DiscordImage    = "rbxassetid://101192191207677",
        Scale           = 1,          -- initial UI scale (same as MacLib SetScale)
        onCorrect       = function() end,
        onIncorrect     = function(k) end,
    }

    Methods:
        :Show()
        :Hide()
        :Destroy()
        :SetKey(key)
        :SetScale(scale)   -- rescale the card (0.5 – 2.0)
]]

return function(ctx)
    local MacLib       = ctx and ctx.MacLib or _G.MacLib
    local TweenService = game:GetService("TweenService")
    local UIS          = game:GetService("UserInputService")
    local HttpService  = game:GetService("HttpService")

    local function Tween(obj, info, goal)
        local t = TweenService:Create(obj, info, goal); t:Play(); return t
    end

    -- ── GetGui: highest possible DisplayOrder, protected ──────────────
    local function GetGui()
        local sg = Instance.new("ScreenGui")
        sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
        sg.ResetOnSpawn   = false
        sg.DisplayOrder   = 999999   -- #1: above all other GUIs including MacLib
        sg.IgnoreGuiInset = true
        local protect = (syn and syn.protect_gui) or (protect_gui) or nil
        if protect then pcall(protect, sg) end
        sg.Parent = (gethui and gethui()) or game:GetService("CoreGui")
        return sg
    end

    function MacLib:KeySystem(cfg)
        cfg = cfg or {}
        local KEY          = tostring(cfg.Key or "1234")
        local TITLE        = cfg.Title    or "Key System"
        local SUBTITLE     = cfg.Subtitle or "Enter your key to continue."
        local DISCORD_CODE = cfg.DiscordInvite or ""
        local DISCORD_LINK = cfg.DiscordLink   or ("https://discord.gg/" .. DISCORD_CODE)
        local MANUAL_TEXT  = cfg.ManualBtnText  or "Copy link"
        local MANUAL_IMG   = cfg.ManualCopyImage or "rbxassetid://90434151822042"
        local DISCORD_IMG  = cfg.DiscordImage    or "rbxassetid://101192191207677"
        local INIT_SCALE   = cfg.Scale or 1

        -- ── Build GUI ──────────────────────────────────────────────────
        local ksGui = GetGui()
        ksGui.Name    = "MacLibKeySystem"
        ksGui.Enabled = false

        -- #8 Anti-bypass: prevent deletion of the ScreenGui
        local _guardConn
        _guardConn = ksGui.AncestryChanged:Connect(function()
            if not ksGui.Parent then
                -- re-parent immediately
                local ok = pcall(function()
                    ksGui.Parent = (gethui and gethui()) or game:GetService("CoreGui")
                end)
                if not ok then
                    -- last resort: recreate (rare edge case)
                    task.defer(function()
                        ksGui = GetGui()
                        ksGui.Enabled = true
                    end)
                end
            end
        end)

        -- Blocker: intercepts all input while KeySystem is visible
        -- #8 Also blocks the MacLib window from receiving clicks
        local blocker = Instance.new("Frame")
        blocker.Name             = "Blocker"
        blocker.Size             = UDim2.fromScale(1, 1)
        blocker.BackgroundTransparency = 1
        blocker.BorderSizePixel  = 0
        blocker.ZIndex           = 1
        -- Making it a button eats all Activated/MouseButton1Click events
        local blockerBtn = Instance.new("TextButton")
        blockerBtn.Size              = UDim2.fromScale(1, 1)
        blockerBtn.BackgroundTransparency = 1
        blockerBtn.Text              = ""
        blockerBtn.ZIndex            = 1
        blockerBtn.Parent            = blocker
        blocker.Parent               = ksGui

        -- Backdrop dim
        local backdrop = Instance.new("Frame")
        backdrop.Name                = "Backdrop"
        backdrop.Size                = UDim2.fromScale(1, 1)
        backdrop.BackgroundColor3    = Color3.fromRGB(0, 0, 0)
        backdrop.BackgroundTransparency = 1
        backdrop.BorderSizePixel     = 0
        backdrop.ZIndex              = 2
        backdrop.Parent              = ksGui

        -- Card container (holds UIScale for SetScale support)
        local cardHolder = Instance.new("Frame")
        cardHolder.Name              = "CardHolder"
        cardHolder.AnchorPoint       = Vector2.new(0.5, 0.5)
        cardHolder.Position          = UDim2.fromScale(0.5, 0.5)
        cardHolder.Size              = UDim2.fromOffset(390, 0)
        cardHolder.AutomaticSize     = Enum.AutomaticSize.Y
        cardHolder.BackgroundTransparency = 1
        cardHolder.BorderSizePixel   = 0
        cardHolder.ZIndex            = 3
        cardHolder.ClipsDescendants  = false
        cardHolder.Parent            = ksGui

        -- #10 SetScale UIScale
        local cardUIScale = Instance.new("UIScale")
        cardUIScale.Scale  = INIT_SCALE
        cardUIScale.Parent = cardHolder

        -- Bounce scale (separate from user scale)
        local cardScale = Instance.new("UIScale")
        cardScale.Scale  = 0.88
        -- We'll drive bounce via cardHolder transform instead; keep single UIScale
        -- Actually Roblox supports only one UIScale → we multiply them via a wrapper
        -- Simpler: animate Position Y offset for bounce instead
        cardHolder.Position = UDim2.new(0.5, 0, 0.5, 20)

        -- Card
        local card = Instance.new("Frame")
        card.Name                = "Card"
        card.Size                = UDim2.fromScale(1, 0)
        card.AutomaticSize       = Enum.AutomaticSize.Y
        card.BackgroundColor3    = Color3.fromRGB(13, 13, 15)
        card.BackgroundTransparency = 1
        card.BorderSizePixel     = 0
        card.ZIndex              = 3
        card.ClipsDescendants    = false
        card.Parent              = cardHolder

        local cardCorner = Instance.new("UICorner")
        cardCorner.CornerRadius  = UDim.new(0, 16)
        cardCorner.Parent        = card

        local cardStroke = Instance.new("UIStroke")
        cardStroke.Color         = Color3.fromRGB(255, 255, 255)
        cardStroke.Transparency  = 0.90
        cardStroke.Thickness     = 1
        cardStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
        cardStroke.Parent        = card

        local cardPad = Instance.new("UIPadding")
        cardPad.PaddingTop    = UDim.new(0, 28)
        cardPad.PaddingBottom = UDim.new(0, 24)
        cardPad.PaddingLeft   = UDim.new(0, 24)
        cardPad.PaddingRight  = UDim.new(0, 24)
        cardPad.Parent        = card

        local cardList = Instance.new("UIListLayout")
        cardList.Padding              = UDim.new(0, 14)
        cardList.SortOrder            = Enum.SortOrder.LayoutOrder
        cardList.HorizontalAlignment  = Enum.HorizontalAlignment.Center
        cardList.Parent               = card

        -- ── Title ──────────────────────────────────────────────────────
        local titleLbl = Instance.new("TextLabel")
        titleLbl.Name                = "Title"
        titleLbl.Size                = UDim2.new(1, 0, 0, 28)
        titleLbl.BackgroundTransparency = 1
        titleLbl.Font                = Enum.Font.GothamBold
        titleLbl.TextSize            = 20
        titleLbl.TextColor3          = Color3.fromRGB(240, 240, 240)
        titleLbl.Text                = TITLE   -- #7 set via cfg
        titleLbl.TextXAlignment      = Enum.TextXAlignment.Center
        titleLbl.TextTransparency    = 1
        titleLbl.LayoutOrder         = 1
        titleLbl.Parent              = card

        local subtitleLbl = Instance.new("TextLabel")
        subtitleLbl.Name             = "Subtitle"
        subtitleLbl.Size             = UDim2.new(1, 0, 0, 18)
        subtitleLbl.BackgroundTransparency = 1
        subtitleLbl.Font             = Enum.Font.Gotham
        subtitleLbl.TextSize         = 13
        subtitleLbl.TextColor3       = Color3.fromRGB(140, 140, 150)
        subtitleLbl.Text             = SUBTITLE
        subtitleLbl.TextXAlignment   = Enum.TextXAlignment.Center
        subtitleLbl.TextTransparency = 1
        subtitleLbl.LayoutOrder      = 2
        subtitleLbl.Parent           = card

        -- Divider
        local divider = Instance.new("Frame")
        divider.Size                 = UDim2.new(1, 0, 0, 1)
        divider.BackgroundColor3     = Color3.fromRGB(255, 255, 255)
        divider.BackgroundTransparency = 0.92
        divider.BorderSizePixel      = 0
        divider.LayoutOrder          = 3
        divider.Parent               = card

        -- ── Input row ─────────────────────────────────────────────────
        local inputFrame = Instance.new("Frame")
        inputFrame.Name              = "InputRow"
        inputFrame.Size              = UDim2.new(1, 0, 0, 40)
        inputFrame.BackgroundColor3  = Color3.fromRGB(22, 22, 26)
        inputFrame.BorderSizePixel   = 0
        inputFrame.LayoutOrder       = 4
        inputFrame.Parent            = card

        local inputCorner = Instance.new("UICorner")
        inputCorner.CornerRadius     = UDim.new(0, 10)
        inputCorner.Parent           = inputFrame

        local inputStroke = Instance.new("UIStroke")
        inputStroke.Color            = Color3.fromRGB(255, 255, 255)
        inputStroke.Transparency     = 0.88
        inputStroke.Thickness        = 1
        inputStroke.ApplyStrokeMode  = Enum.ApplyStrokeMode.Border
        inputStroke.Parent           = inputFrame

        local inputBox = Instance.new("TextBox")
        inputBox.Name                = "Input"
        inputBox.AnchorPoint         = Vector2.new(0, 0.5)
        inputBox.Position            = UDim2.new(0, 14, 0.5, 0)
        inputBox.Size                = UDim2.new(1, -100, 0, 28)
        inputBox.BackgroundTransparency = 1
        inputBox.Font                = Enum.Font.Gotham
        inputBox.TextSize            = 14
        inputBox.TextColor3          = Color3.fromRGB(220, 220, 220)
        inputBox.PlaceholderText     = "Enter key..."
        inputBox.PlaceholderColor3   = Color3.fromRGB(90, 90, 100)
        inputBox.ClearTextOnFocus    = true   -- #2 clear on focus
        inputBox.TextXAlignment      = Enum.TextXAlignment.Left
        inputBox.ZIndex              = 4
        inputBox.Parent              = inputFrame

        local submitBtn = Instance.new("TextButton")
        submitBtn.Name               = "Submit"
        submitBtn.AnchorPoint        = Vector2.new(1, 0.5)
        submitBtn.Position           = UDim2.new(1, -8, 0.5, 0)
        submitBtn.Size               = UDim2.fromOffset(72, 28)
        submitBtn.BackgroundColor3   = Color3.fromRGB(40, 120, 255)
        submitBtn.BorderSizePixel    = 0
        submitBtn.Font               = Enum.Font.GothamSemibold
        submitBtn.TextSize           = 13
        submitBtn.TextColor3         = Color3.fromRGB(255, 255, 255)
        submitBtn.Text               = "Submit"
        submitBtn.AutoButtonColor    = false
        submitBtn.ZIndex             = 5
        submitBtn.Parent             = inputFrame

        local submitCorner = Instance.new("UICorner")
        submitCorner.CornerRadius    = UDim.new(0, 7)
        submitCorner.Parent          = submitBtn

        -- ── Status label ───────────────────────────────────────────────
        local statusLbl = Instance.new("TextLabel")
        statusLbl.Name               = "Status"
        statusLbl.Size               = UDim2.new(1, 0, 0, 16)
        statusLbl.BackgroundTransparency = 1
        statusLbl.Font               = Enum.Font.Gotham
        statusLbl.TextSize           = 12
        statusLbl.TextColor3         = Color3.fromRGB(100, 100, 110)
        statusLbl.TextTransparency   = 1
        statusLbl.Text               = " "
        statusLbl.TextXAlignment     = Enum.TextXAlignment.Center
        statusLbl.LayoutOrder        = 5
        statusLbl.Parent             = card

        -- ── Bottom row ─────────────────────────────────────────────────
        local bottomRow = Instance.new("Frame")
        bottomRow.Name               = "BottomRow"
        bottomRow.Size               = UDim2.new(1, 0, 0, 36)
        bottomRow.BackgroundTransparency = 1
        bottomRow.LayoutOrder        = 6
        bottomRow.Parent             = card

        local bottomList = Instance.new("UIListLayout")
        bottomList.FillDirection     = Enum.FillDirection.Horizontal
        bottomList.HorizontalAlignment = Enum.HorizontalAlignment.Left
        bottomList.VerticalAlignment = Enum.VerticalAlignment.Center
        bottomList.Padding           = UDim.new(0, 10)
        bottomList.SortOrder         = Enum.SortOrder.LayoutOrder
        bottomList.Parent            = bottomRow

        -- #3 Discord icon: button is 36px, image inset to 22px to look smaller
        local discordBtn = Instance.new("ImageButton")
        discordBtn.Name              = "DiscordBtn"
        discordBtn.Size              = UDim2.fromOffset(36, 36)
        discordBtn.BackgroundColor3  = Color3.fromRGB(88, 101, 242)
        discordBtn.BorderSizePixel   = 0
        discordBtn.Image             = DISCORD_IMG
        discordBtn.ImageRectSize     = Vector2.new(0, 0)  -- full image
        discordBtn.AutoButtonColor   = false
        discordBtn.ScaleType         = Enum.ScaleType.Fit
        discordBtn.ImageTransparency = 0
        discordBtn.ZIndex            = 4
        discordBtn.LayoutOrder       = 1
        discordBtn.Parent            = bottomRow

        -- #3 icon smaller via UIPadding on the image inside the button
        local discordImgPad = Instance.new("UIPadding")
        discordImgPad.PaddingTop    = UDim.new(0, 7)
        discordImgPad.PaddingBottom = UDim.new(0, 7)
        discordImgPad.PaddingLeft   = UDim.new(0, 7)
        discordImgPad.PaddingRight  = UDim.new(0, 7)
        discordImgPad.Parent        = discordBtn

        local discordCorner = Instance.new("UICorner")
        discordCorner.CornerRadius   = UDim.new(1, 0)
        discordCorner.Parent         = discordBtn

        -- #9 Subtle "clickable" hint: small arrow label next to the button
        local discordHint = Instance.new("TextLabel")
        discordHint.Name             = "DiscordHint"
        discordHint.Size             = UDim2.new(0, 140, 1, 0)
        discordHint.BackgroundTransparency = 1
        discordHint.Font             = Enum.Font.Gotham
        discordHint.TextSize         = 12
        discordHint.TextColor3       = Color3.fromRGB(110, 110, 125)
        discordHint.RichText         = true
        -- underline effect via RichText to hint it's clickable
        discordHint.Text             = "Don't have a key? <u>Join Discord ↗</u>"
        discordHint.TextXAlignment   = Enum.TextXAlignment.Left
        discordHint.LayoutOrder      = 2
        discordHint.Parent           = bottomRow

        -- Copy button
        local manualBtn = Instance.new("TextButton")
        manualBtn.Name               = "ManualBtn"
        manualBtn.Size               = UDim2.fromOffset(110, 30)
        manualBtn.BackgroundColor3   = Color3.fromRGB(28, 28, 32)
        manualBtn.BorderSizePixel    = 0
        manualBtn.Font               = Enum.Font.GothamSemibold
        manualBtn.TextSize           = 12
        manualBtn.TextColor3         = Color3.fromRGB(180, 180, 190)
        manualBtn.Text               = ""
        manualBtn.AutoButtonColor    = false
        manualBtn.ZIndex             = 4
        manualBtn.LayoutOrder        = 3
        manualBtn.Parent             = bottomRow

        local manualCorner = Instance.new("UICorner")
        manualCorner.CornerRadius    = UDim.new(0, 8)
        manualCorner.Parent          = manualBtn

        local manualStroke = Instance.new("UIStroke")
        manualStroke.Color           = Color3.fromRGB(255, 255, 255)
        manualStroke.Transparency    = 0.88
        manualStroke.Thickness       = 1
        manualStroke.Parent          = manualBtn

        local manualLayout = Instance.new("UIListLayout")
        manualLayout.FillDirection   = Enum.FillDirection.Horizontal
        manualLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
        manualLayout.VerticalAlignment = Enum.VerticalAlignment.Center
        manualLayout.Padding         = UDim.new(0, 6)
        manualLayout.Parent          = manualBtn

        local manualIcon = Instance.new("ImageLabel")
        manualIcon.Size              = UDim2.fromOffset(14, 14)
        manualIcon.BackgroundTransparency = 1
        manualIcon.Image             = MANUAL_IMG
        manualIcon.ZIndex            = 5
        manualIcon.Parent            = manualBtn

        local manualLbl = Instance.new("TextLabel")
        manualLbl.Size               = UDim2.new(0, 70, 1, 0)
        manualLbl.BackgroundTransparency = 1
        manualLbl.Font               = Enum.Font.GothamSemibold
        manualLbl.TextSize           = 12
        manualLbl.TextColor3         = Color3.fromRGB(180, 180, 190)
        manualLbl.Text               = MANUAL_TEXT
        manualLbl.TextXAlignment     = Enum.TextXAlignment.Left
        manualLbl.ZIndex             = 5
        manualLbl.Parent             = manualBtn

        -- ── Tween helpers ──────────────────────────────────────────────
        local EASE_OUT  = TweenInfo.new(0.32, Enum.EasingStyle.Back,  Enum.EasingDirection.Out)
        local EASE_IN   = TweenInfo.new(0.20, Enum.EasingStyle.Quad,  Enum.EasingDirection.In)
        local EASE_SINE = TweenInfo.new(0.18, Enum.EasingStyle.Sine,  Enum.EasingDirection.Out)

        local _shown = false

        -- #4 Fix: all content elements fade IN together from the start,
        --         and fade OUT all together before the card shrinks
        local _contentAlpha = 1  -- tracks current transparency

        local function setContentTransparency(v)
            titleLbl.TextTransparency    = v
            subtitleLbl.TextTransparency = v
            statusLbl.TextTransparency   = math.max(v, statusLbl.TextTransparency)
            inputBox.TextTransparency    = v
            inputBox.PlaceholderColor3   = Color3.fromRGB(90, 90, 100):Lerp(
                Color3.fromRGB(0,0,0), v)
            submitBtn.TextTransparency   = v
            manualLbl.TextTransparency   = v
            manualIcon.ImageTransparency = v
            discordBtn.ImageTransparency = v
            discordHint.TextTransparency = v
        end

        local function tweenContent(targetT, duration)
            local info = TweenInfo.new(duration or 0.22, Enum.EasingStyle.Sine)
            Tween(titleLbl,    info, { TextTransparency = targetT })
            Tween(subtitleLbl, info, { TextTransparency = targetT })
            Tween(inputBox,    info, { TextTransparency = targetT })
            Tween(submitBtn,   info, { TextTransparency = targetT })
            Tween(manualLbl,   info, { TextTransparency = targetT })
            Tween(manualIcon,  info, { ImageTransparency = targetT })
            Tween(discordBtn,  info, { ImageTransparency = targetT })
            Tween(discordHint, info, { TextTransparency = targetT })
        end

        -- Initial state: everything invisible
        setContentTransparency(1)
        card.BackgroundTransparency = 1

        local function showAnim()
            ksGui.Enabled = true
            _shown = true
            Tween(backdrop, TweenInfo.new(0.25, Enum.EasingStyle.Sine), { BackgroundTransparency = 0.45 })
            Tween(card, TweenInfo.new(0.20, Enum.EasingStyle.Sine), { BackgroundTransparency = 0 })
            -- bounce: slide up from slightly below
            cardHolder.Position = UDim2.new(0.5, 0, 0.5, 24)
            Tween(cardHolder, EASE_OUT, { Position = UDim2.fromScale(0.5, 0.5) })
            -- content fades in together with card
            tweenContent(0, 0.28)
        end

        local function hideAnim(callback)
            -- #4 Fix: fade content OUT first, then shrink card
            tweenContent(1, 0.14)
            task.delay(0.10, function()
                Tween(backdrop, TweenInfo.new(0.20, Enum.EasingStyle.Sine), { BackgroundTransparency = 1 })
                Tween(card, TweenInfo.new(0.18, Enum.EasingStyle.Sine), { BackgroundTransparency = 1 })
                local t = Tween(cardHolder, EASE_IN, { Position = UDim2.new(0.5, 0, 0.5, 24) })
                t.Completed:Connect(function()
                    ksGui.Enabled = false
                    _shown = false
                    if callback then callback() end
                end)
            end)
        end

        -- Shake on wrong key
        local function shakeAnim()
            local offsets = { 8, -8, 6, -6, 3, -3, 0 }
            local function step(i)
                if i > #offsets then return end
                Tween(cardHolder, TweenInfo.new(0.04, Enum.EasingStyle.Sine), {
                    Position = UDim2.new(0.5, offsets[i], 0.5, 0)
                }).Completed:Connect(function() step(i + 1) end)
            end
            step(1)
        end

        local function successAnim()
            inputFrame.BackgroundColor3 = Color3.fromRGB(20, 60, 30)
            inputStroke.Color           = Color3.fromRGB(60, 220, 100)
            inputStroke.Transparency    = 0.3
            statusLbl.TextColor3        = Color3.fromRGB(60, 220, 100)
            statusLbl.TextTransparency  = 0
            Tween(cardHolder, TweenInfo.new(0.15, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
                { Position = UDim2.new(0.5, 0, 0.5, -6) })
            task.delay(0.18, function()
                Tween(cardHolder, TweenInfo.new(0.12, Enum.EasingStyle.Sine),
                    { Position = UDim2.fromScale(0.5, 0.5) })
            end)
        end

        local function errorAnim()
            inputFrame.BackgroundColor3 = Color3.fromRGB(50, 14, 14)
            inputStroke.Color           = Color3.fromRGB(220, 60, 60)
            inputStroke.Transparency    = 0.3
            statusLbl.TextColor3        = Color3.fromRGB(220, 80, 80)
            statusLbl.TextTransparency  = 0
            shakeAnim()
            task.delay(0.8, function()
                Tween(inputFrame, TweenInfo.new(0.3, Enum.EasingStyle.Sine),
                    { BackgroundColor3 = Color3.fromRGB(22, 22, 26) })
                Tween(inputStroke, TweenInfo.new(0.3),
                    { Transparency = 0.88, Color = Color3.fromRGB(255, 255, 255) })
                Tween(statusLbl, TweenInfo.new(0.3), { TextTransparency = 1 })
            end)
        end

        -- ── Submit logic ───────────────────────────────────────────────
        local _submitted = false
        local function trySubmit()
            if _submitted then return end
            local entered = inputBox.Text
            if entered == "" then return end
            if entered == KEY then
                _submitted = true
                statusLbl.Text = "✓ Access granted"
                successAnim()
                task.delay(0.6, function()
                    hideAnim(function()
                        if cfg.onCorrect then task.spawn(cfg.onCorrect) end
                    end)
                end)
            else
                statusLbl.Text = "✗ Incorrect key"   -- #5: no key shown in notify
                errorAnim()
                if cfg.onIncorrect then
                    -- #5: pass the key to the callback but NOT to any notification here
                    task.spawn(cfg.onIncorrect, entered)
                end
            end
        end

        submitBtn.Activated:Connect(trySubmit)
        inputBox.FocusLost:Connect(function(enter)
            if enter then trySubmit() end
        end)

        -- Hover effects
        submitBtn.MouseEnter:Connect(function()
            Tween(submitBtn, EASE_SINE, { BackgroundColor3 = Color3.fromRGB(60, 140, 255) })
        end)
        submitBtn.MouseLeave:Connect(function()
            Tween(submitBtn, EASE_SINE, { BackgroundColor3 = Color3.fromRGB(40, 120, 255) })
        end)
        -- Touch feedback (mobile)
        submitBtn.MouseButton1Down:Connect(function()
            Tween(submitBtn, EASE_SINE, { BackgroundColor3 = Color3.fromRGB(20, 90, 220) })
        end)
        submitBtn.MouseButton1Up:Connect(function()
            Tween(submitBtn, EASE_SINE, { BackgroundColor3 = Color3.fromRGB(40, 120, 255) })
        end)

        manualBtn.MouseEnter:Connect(function()
            Tween(manualBtn, EASE_SINE, { BackgroundColor3 = Color3.fromRGB(38, 38, 44) })
        end)
        manualBtn.MouseLeave:Connect(function()
            Tween(manualBtn, EASE_SINE, { BackgroundColor3 = Color3.fromRGB(28, 28, 32) })
        end)

        discordBtn.MouseEnter:Connect(function()
            Tween(discordBtn, EASE_SINE, { BackgroundColor3 = Color3.fromRGB(110, 125, 255) })
        end)
        discordBtn.MouseLeave:Connect(function()
            Tween(discordBtn, EASE_SINE, { BackgroundColor3 = Color3.fromRGB(88, 101, 242) })
        end)
        -- Touch press glow (mobile #10)
        discordBtn.MouseButton1Down:Connect(function()
            Tween(discordBtn, EASE_SINE, { BackgroundColor3 = Color3.fromRGB(130, 150, 255) })
        end)
        discordBtn.MouseButton1Up:Connect(function()
            Tween(discordBtn, EASE_SINE, { BackgroundColor3 = Color3.fromRGB(88, 101, 242) })
        end)

        -- ── Discord RPC ────────────────────────────────────────────────
        local function openDiscord()
            -- Try Discord RPC (PC desktop client)
            pcall(function()
                local reqFunc = (http and http.request) or request or nil
                if not reqFunc then return end
                reqFunc({
                    Url    = "http://127.0.0.1:6463/rpc?v=1",
                    Method = "POST",
                    Headers = {
                        ["Content-Type"] = "application/json",
                        ["Origin"]       = "https://discord.com",
                    },
                    Body = HttpService:JSONEncode({
                        cmd   = "INVITE_BROWSER",
                        args  = { code = DISCORD_CODE },
                        nonce = HttpService:GenerateGUID(false),
                    }),
                })
            end)
        end

        discordBtn.Activated:Connect(openDiscord)
        -- #9: hint label is a TextLabel so we overlay an invisible button for click detection
        local discordHintBtn = Instance.new("TextButton")
        discordHintBtn.Size                 = UDim2.fromScale(1, 1)
        discordHintBtn.BackgroundTransparency = 1
        discordHintBtn.Text                 = ""
        discordHintBtn.ZIndex               = discordHint.ZIndex + 1
        discordHintBtn.Parent               = discordHint
        discordHintBtn.Activated:Connect(openDiscord)

        -- ── Copy link ──────────────────────────────────────────────────
        local _copyDebounce = false
        manualBtn.Activated:Connect(function()
            if _copyDebounce then return end
            _copyDebounce = true
            pcall(function()
                if setclipboard then setclipboard(DISCORD_LINK)
                elseif toclipboard then toclipboard(DISCORD_LINK) end
            end)
            -- Show "Copied!" state
            local origText = MANUAL_TEXT
            manualLbl.Text = "Copied!"
            manualIcon.ImageColor3 = Color3.fromRGB(60, 220, 100)
            manualLbl.TextColor3   = Color3.fromRGB(60, 220, 100)
            Tween(manualStroke, TweenInfo.new(0.2), { Color = Color3.fromRGB(60, 220, 100), Transparency = 0.5 })
            -- #6: revert after 2 seconds
            task.delay(2, function()
                manualLbl.Text     = origText
                manualLbl.TextColor3 = Color3.fromRGB(180, 180, 190)
                manualIcon.ImageColor3 = Color3.fromRGB(255, 255, 255)
                Tween(manualStroke, TweenInfo.new(0.2), { Color = Color3.fromRGB(255, 255, 255), Transparency = 0.88 })
                task.delay(0.2, function() _copyDebounce = false end)
            end)
        end)

        -- ── #10 Mobile: responsive card width ─────────────────────────
        local function adaptToViewport()
            local vp = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize
                or Vector2.new(1280, 720)
            local isTouchDevice = UIS.TouchEnabled
            if isTouchDevice or vp.X < 500 then
                -- On phone: make card full-width with margins
                local w = math.min(vp.X - 32, 390)
                cardHolder.Size = UDim2.fromOffset(w, 0)
                -- slightly bigger text for touch
                titleLbl.TextSize    = 22
                subtitleLbl.TextSize = 14
                inputBox.TextSize    = 15
                submitBtn.TextSize   = 14
                inputFrame.Size      = UDim2.new(1, 0, 0, 46)
                submitBtn.Size       = UDim2.fromOffset(80, 32)
            else
                cardHolder.Size = UDim2.fromOffset(390, 0)
            end
        end

        adaptToViewport()
        -- Re-adapt if viewport changes (rotation, etc.)
        if workspace.CurrentCamera then
            workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(adaptToViewport)
        end

        -- ── Public API ─────────────────────────────────────────────────
        local KSFunctions = {}

        function KSFunctions:Show()
            _submitted = false
            showAnim()
        end

        function KSFunctions:Hide()
            hideAnim()
        end

        function KSFunctions:Destroy()
            _guardConn:Disconnect()
            hideAnim(function() ksGui:Destroy() end)
        end

        function KSFunctions:SetKey(key)
            KEY = tostring(key)
            _submitted = false
        end

        -- #10 SetScale: rescale the card just like MacLib:SetScale
        function KSFunctions:SetScale(scale)
            cardUIScale.Scale = math.clamp(scale, 0.4, 3)
        end

        return KSFunctions
    end
end
