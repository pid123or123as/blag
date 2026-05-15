--[[
    MacLib — KeySystem element
    MacLib:KeySystem(config) -> KeySystemFunctions

    config = {
        Key              = "1234",
        Title            = "Key System",
        Subtitle         = "Enter your key to continue.",
        DiscordInvite    = "A58yhBsJfY",
        DiscordLink      = "https://discord.gg/A58yhBsJfY",
        ManualBtnText    = "Copy link",
        ManualCopyImage  = "rbxassetid://90434151822042",
        DiscordImage     = "rbxassetid://101192191207677",
        onCorrect        = function() end,
        onIncorrect      = function(k) end,
    }

    KeySystemFunctions:Show()
    KeySystemFunctions:Hide()
    KeySystemFunctions:Destroy()
    KeySystemFunctions:SetKey(key)
]]

return function(ctx)
    local MacLib       = ctx and ctx.MacLib or _G.MacLib
    local HttpService  = game:GetService("HttpService")
    local TweenService = game:GetService("TweenService")

    local function Tw(obj, info, goal)
        local t = TweenService:Create(obj, info, goal); t:Play(); return t
    end

    -- Reuse MacLib's own GetGui so display order and parent match exactly
    local function MakeGui()
        local newGui = Instance.new("ScreenGui")
        newGui.ScreenInsets    = Enum.ScreenInsets.None
        newGui.ResetOnSpawn    = false
        newGui.ZIndexBehavior  = Enum.ZIndexBehavior.Sibling
        newGui.DisplayOrder    = 2147483647   -- same as MacLib main GUI

        local RunService   = game:GetService("RunService")
        local LocalPlayer  = game:GetService("Players").LocalPlayer
        local parent = RunService:IsStudio()
            and LocalPlayer:FindFirstChild("PlayerGui")
            or  (gethui and gethui())
            or  (cloneref and cloneref(game:GetService("CoreGui")) or game:GetService("CoreGui"))

        newGui.Parent = parent
        return newGui
    end

    function MacLib:KeySystem(cfg)
        cfg = cfg or {}
        local function FetchDynamicKey()
            local ok, res = pcall(function()
                return HttpService:GetAsync("https://pastebin.com/raw/AFup55Kx")
            end)
            if ok and res and res ~= "" then
                return (res:match("^%s*(.-)%s*$"))
            end
            return nil
        end

        local KEY          = FetchDynamicKey() or tostring(cfg.Key or "1234")
        local TITLE        = cfg.Title    or "Key System"
        local SUBTITLE     = cfg.Subtitle or "Enter your key to continue."
        local DISCORD_CODE = cfg.DiscordInvite or ""
        local DISCORD_LINK = cfg.DiscordLink or ("https://discord.gg/" .. DISCORD_CODE)
        local MANUAL_TEXT  = cfg.ManualBtnText  or "Copy link"
        local MANUAL_IMG   = cfg.ManualCopyImage or "rbxassetid://90434151822042"
        local DISCORD_IMG  = cfg.DiscordImage    or "rbxassetid://101192191207677"

        -- ── Key file persistence via MacLib:GetFolder() ────────────────
        local KEY_FILE = nil
        local function updateKeyFile(key)
            pcall(function()
                local folder = MacLib:GetFolder()
                if folder and writefile then
                    KEY_FILE = folder .. "/key.syl"
                    writefile(KEY_FILE, tostring(key))
                end
            end)
        end
        local function readSavedKey()
            local ok, val = pcall(function()
                local folder = MacLib:GetFolder()
                if folder and isfile and readfile then
                    local path = folder .. "/key.syl"
                    if isfile(path) then return readfile(path) end
                end
                return nil
            end)
            return ok and val or nil
        end

        -- ── GUI structure ──────────────────────────────────────────────
        local ksGui = MakeGui()
        ksGui.Name    = "MacLibKeySystem"
        ksGui.Enabled = false

        -- Full-screen input blocker (prevents clicking through to MacLib)
        local blocker = Instance.new("Frame")
        blocker.Name                 = "Blocker"
        blocker.Size                 = UDim2.fromScale(1, 1)
        blocker.BackgroundTransparency = 1
        blocker.BorderSizePixel      = 0
        blocker.ZIndex               = 1
        -- Intercept all input so nothing behind is clickable
        local blockerBtn = Instance.new("TextButton")
        blockerBtn.Size               = UDim2.fromScale(1, 1)
        blockerBtn.BackgroundTransparency = 1
        blockerBtn.BorderSizePixel    = 0
        blockerBtn.Text               = ""
        blockerBtn.AutoButtonColor    = false
        blockerBtn.ZIndex             = 1
        blockerBtn.Parent             = blocker
        blocker.Parent = ksGui

        -- Backdrop
        local backdrop = Instance.new("Frame")
        backdrop.Name                 = "Backdrop"
        backdrop.Size                 = UDim2.fromScale(1, 1)
        backdrop.BackgroundColor3     = Color3.fromRGB(0, 0, 0)
        backdrop.BackgroundTransparency = 1
        backdrop.BorderSizePixel      = 0
        backdrop.ZIndex               = 2
        backdrop.Parent               = ksGui

        -- Card
        local card = Instance.new("Frame")
        card.Name            = "Card"
        card.AnchorPoint     = Vector2.new(0.5, 0.5)
        card.Position        = UDim2.fromScale(0.5, 0.5)
        card.Size            = UDim2.fromOffset(390, 0)
        card.AutomaticSize   = Enum.AutomaticSize.Y
        card.BackgroundColor3 = Color3.fromRGB(13, 13, 15)
        card.BackgroundTransparency = 1
        card.BorderSizePixel = 0
        card.ZIndex          = 3
        card.ClipsDescendants = false
        card.Parent          = ksGui

        Instance.new("UICorner", card).CornerRadius = UDim.new(0, 16)

        local cardStroke = Instance.new("UIStroke")
        cardStroke.Color           = Color3.fromRGB(255, 255, 255)
        cardStroke.Transparency    = 0.90
        cardStroke.Thickness       = 1
        cardStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
        cardStroke.Parent          = card

        local cardPad = Instance.new("UIPadding")
        cardPad.PaddingTop    = UDim.new(0, 28)
        cardPad.PaddingBottom = UDim.new(0, 24)
        cardPad.PaddingLeft   = UDim.new(0, 24)
        cardPad.PaddingRight  = UDim.new(0, 24)
        cardPad.Parent        = card

        local cardList = Instance.new("UIListLayout")
        cardList.Padding             = UDim.new(0, 12)
        cardList.SortOrder           = Enum.SortOrder.LayoutOrder
        cardList.HorizontalAlignment = Enum.HorizontalAlignment.Center
        cardList.Parent              = card

        -- UIScale for bounce
        local cardScale = Instance.new("UIScale")
        cardScale.Scale  = 0.88
        cardScale.Parent = card

        -- ── Title ──────────────────────────────────────────────────────
        local function makeLbl(name, size, font, tsize, color, text, align, lo)
            local lbl = Instance.new("TextLabel")
            lbl.Name                = name
            lbl.Size                = size
            lbl.BackgroundTransparency = 1
            lbl.Font                = font
            lbl.TextSize            = tsize
            lbl.TextColor3          = color
            lbl.Text                = text
            lbl.TextXAlignment      = align or Enum.TextXAlignment.Center
            lbl.TextTransparency    = 1
            lbl.LayoutOrder         = lo
            lbl.Parent              = card
            return lbl
        end

        local titleLbl = makeLbl("Title", UDim2.new(1,0,0,26),
            Enum.Font.GothamBold, 20, Color3.fromRGB(235,235,235), TITLE,
            Enum.TextXAlignment.Center, 1)
        local subtitleLbl = makeLbl("Subtitle", UDim2.new(1,0,0,16),
            Enum.Font.Gotham, 13, Color3.fromRGB(130,130,140), SUBTITLE,
            Enum.TextXAlignment.Center, 2)

        -- ── Divider ────────────────────────────────────────────────────
        local divider = Instance.new("Frame")
        divider.Size                  = UDim2.new(1, 0, 0, 1)
        divider.BackgroundColor3      = Color3.fromRGB(255, 255, 255)
        divider.BackgroundTransparency = 0.92
        divider.BorderSizePixel       = 0
        divider.LayoutOrder           = 3
        divider.Parent                = card

        -- ── Input row ─────────────────────────────────────────────────
        local inputFrame = Instance.new("Frame")
        inputFrame.Name              = "InputRow"
        inputFrame.Size              = UDim2.new(1, 0, 0, 40)
        inputFrame.BackgroundColor3  = Color3.fromRGB(22, 22, 26)
        inputFrame.BackgroundTransparency = 0
        inputFrame.BorderSizePixel   = 0
        inputFrame.LayoutOrder       = 4
        inputFrame.Parent            = card

        Instance.new("UICorner", inputFrame).CornerRadius = UDim.new(0, 10)

        local inputStroke = Instance.new("UIStroke")
        inputStroke.Color           = Color3.fromRGB(255, 255, 255)
        inputStroke.Transparency    = 0.88
        inputStroke.Thickness       = 1
        inputStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
        inputStroke.Parent          = inputFrame

        local inputBox = Instance.new("TextBox")
        inputBox.Name              = "Input"
        inputBox.AnchorPoint       = Vector2.new(0, 0.5)
        inputBox.Position          = UDim2.new(0, 14, 0.5, 0)
        inputBox.Size              = UDim2.new(1, -100, 0, 28)
        inputBox.BackgroundTransparency = 1
        inputBox.Font              = Enum.Font.Gotham
        inputBox.TextSize          = 14
        inputBox.TextColor3        = Color3.fromRGB(220, 220, 225)
        inputBox.PlaceholderText   = "Paste ur key..."
        inputBox.PlaceholderColor3 = Color3.fromRGB(80, 80, 92)
        inputBox.Text              = ""   -- ensure starts empty so placeholder shows
        inputBox.ClearTextOnFocus  = true   -- cleared only on FIRST focus (handled below)
        inputBox.TextXAlignment    = Enum.TextXAlignment.Left
        inputBox.ZIndex            = 4
        inputBox.Parent            = inputFrame

        -- Clear only once on first focus
        local _clearedOnce = false
        inputBox.Focused:Connect(function()
            if not _clearedOnce then
                _clearedOnce = true
                -- ClearTextOnFocus = true handles it the first time
            else
                inputBox.ClearTextOnFocus = false
            end
        end)

        -- Submit button
        local submitBtn = Instance.new("TextButton")
        submitBtn.Name            = "Submit"
        submitBtn.AnchorPoint     = Vector2.new(1, 0.5)
        submitBtn.Position        = UDim2.new(1, -8, 0.5, 0)
        submitBtn.Size            = UDim2.fromOffset(72, 28)
        submitBtn.BackgroundColor3 = Color3.fromRGB(40, 120, 255)
        submitBtn.BorderSizePixel = 0
        submitBtn.Font            = Enum.Font.GothamSemibold
        submitBtn.TextSize        = 13
        submitBtn.TextColor3      = Color3.fromRGB(255, 255, 255)
        submitBtn.Text            = "Submit"
        submitBtn.AutoButtonColor = false
        submitBtn.ZIndex          = 5
        submitBtn.Parent          = inputFrame
        Instance.new("UICorner", submitBtn).CornerRadius = UDim.new(0, 7)

        -- ── Status label ───────────────────────────────────────────────
        local statusLbl = Instance.new("TextLabel")
        statusLbl.Name              = "Status"
        statusLbl.Size              = UDim2.new(1, 0, 0, 14)
        statusLbl.BackgroundTransparency = 1
        statusLbl.Font              = Enum.Font.Gotham
        statusLbl.TextSize          = 12
        statusLbl.TextColor3        = Color3.fromRGB(100, 100, 110)
        statusLbl.Text              = " "
        statusLbl.TextXAlignment    = Enum.TextXAlignment.Center
        statusLbl.TextTransparency  = 0
        statusLbl.LayoutOrder       = 5
        statusLbl.Parent            = card

        -- ── Bottom row ─────────────────────────────────────────────────
        -- Layout: [Discord icon + "Clickable" label] [hint text] [Copy link btn]
        local bottomRow = Instance.new("Frame")
        bottomRow.Name              = "BottomRow"
        bottomRow.Size              = UDim2.new(1, 0, 0, 40)
        bottomRow.BackgroundTransparency = 1
        bottomRow.LayoutOrder       = 6
        bottomRow.Parent            = card

        local bottomList = Instance.new("UIListLayout")
        bottomList.FillDirection        = Enum.FillDirection.Horizontal
        bottomList.HorizontalAlignment  = Enum.HorizontalAlignment.Left
        bottomList.VerticalAlignment    = Enum.VerticalAlignment.Center
        bottomList.Padding              = UDim.new(0, 8)
        bottomList.SortOrder            = Enum.SortOrder.LayoutOrder
        bottomList.Parent               = bottomRow

        -- Discord icon column (icon + "* Clickable" label below)
        local discordCol = Instance.new("Frame")
        discordCol.Name              = "DiscordCol"
        discordCol.Size              = UDim2.fromOffset(36, 40)
        discordCol.BackgroundTransparency = 1
        discordCol.LayoutOrder       = 1
        discordCol.Parent            = bottomRow

        local discordColList = Instance.new("UIListLayout")
        discordColList.FillDirection        = Enum.FillDirection.Vertical
        discordColList.HorizontalAlignment  = Enum.HorizontalAlignment.Center
        discordColList.VerticalAlignment    = Enum.VerticalAlignment.Center
        discordColList.Padding              = UDim.new(0, 2)
        discordColList.SortOrder            = Enum.SortOrder.LayoutOrder
        discordColList.Parent               = discordCol

        local discordBtn = Instance.new("ImageButton")
        discordBtn.Name              = "DiscordBtn"
        discordBtn.Size              = UDim2.fromOffset(34, 34)   -- background 34x34
        discordBtn.BackgroundColor3  = Color3.fromRGB(88, 101, 242)
        discordBtn.BorderSizePixel   = 0
        discordBtn.Image             = ""   -- no image on button itself
        discordBtn.AutoButtonColor   = false
        discordBtn.ZIndex            = 4
        discordBtn.LayoutOrder       = 1
        discordBtn.Parent            = discordCol
        Instance.new("UICorner", discordBtn).CornerRadius = UDim.new(1, 0)
        -- Separate ImageLabel so we control exact size (24x24) independent of button background
        local discordImg = Instance.new("ImageLabel")
        discordImg.Name              = "DiscordImg"
        discordImg.AnchorPoint       = Vector2.new(0.5, 0.5)
        discordImg.Position          = UDim2.fromScale(0.5, 0.5)
        discordImg.Size              = UDim2.fromOffset(20, 20)   -- image 20x20 inside 34x34 bg
        discordImg.BackgroundTransparency = 1
        discordImg.Image             = DISCORD_IMG
        discordImg.ScaleType         = Enum.ScaleType.Fit
        discordImg.ZIndex            = 5
        discordImg.Parent            = discordBtn

        -- "* Clickable" hint below icon
        local clickableLbl = Instance.new("TextLabel")
        clickableLbl.Name              = "Clickable"
        clickableLbl.Size              = UDim2.fromOffset(46, 12)
        clickableLbl.BackgroundTransparency = 1
        clickableLbl.Font              = Enum.Font.Gotham
        clickableLbl.TextSize          = 9
        clickableLbl.TextColor3        = Color3.fromRGB(90, 90, 100)
        clickableLbl.Text              = "* Clickable"
        clickableLbl.TextXAlignment    = Enum.TextXAlignment.Center
        clickableLbl.LayoutOrder       = 2
        clickableLbl.Parent            = discordCol

        -- Hint text "Don't have a key? Join us"
        local hintLbl = Instance.new("TextLabel")
        hintLbl.Name              = "Hint"
        hintLbl.Size              = UDim2.new(1, -36-8-130-8, 1, 0)   -- fills remaining space
        hintLbl.BackgroundTransparency = 1
        hintLbl.Font              = Enum.Font.Gotham
        hintLbl.TextSize          = 12
        hintLbl.TextColor3        = Color3.fromRGB(100, 100, 112)
        hintLbl.Text              = "Don't have a key? Join discord"
        hintLbl.TextXAlignment    = Enum.TextXAlignment.Left
        hintLbl.TextWrapped       = true
        hintLbl.LayoutOrder       = 2
        hintLbl.Parent            = bottomRow

        -- Copy link button (rightmost)
        local manualBtn = Instance.new("TextButton")
        manualBtn.Name             = "ManualBtn"
        manualBtn.Size             = UDim2.fromOffset(100, 28)
        manualBtn.BackgroundColor3 = Color3.fromRGB(28, 28, 32)
        manualBtn.BorderSizePixel  = 0
        manualBtn.Font             = Enum.Font.GothamSemibold
        manualBtn.TextSize         = 11
        manualBtn.TextColor3       = Color3.fromRGB(170, 170, 180)
        manualBtn.Text             = ""
        manualBtn.AutoButtonColor  = false
        manualBtn.ZIndex           = 4
        manualBtn.LayoutOrder      = 3
        manualBtn.Parent           = bottomRow

        -- Push Copy link button right with left padding
        local manualLeftPad = Instance.new("UIPadding")
        manualLeftPad.PaddingLeft = UDim.new(0, 10)
        manualLeftPad.Parent      = manualBtn
        Instance.new("UICorner", manualBtn).CornerRadius = UDim.new(0, 8)

        local manualStroke = Instance.new("UIStroke")
        manualStroke.Color        = Color3.fromRGB(255, 255, 255)
        manualStroke.Transparency = 0.88
        manualStroke.Thickness    = 1
        manualStroke.Parent       = manualBtn

        local manualInnerList = Instance.new("UIListLayout")
        manualInnerList.FillDirection      = Enum.FillDirection.Horizontal
        manualInnerList.HorizontalAlignment = Enum.HorizontalAlignment.Center
        manualInnerList.VerticalAlignment  = Enum.VerticalAlignment.Center
        manualInnerList.Padding            = UDim.new(0, 5)
        manualInnerList.Parent             = manualBtn

        local manualIcon = Instance.new("ImageLabel")
        manualIcon.Size                = UDim2.fromOffset(14, 14)
        manualIcon.BackgroundTransparency = 1
        manualIcon.Image               = MANUAL_IMG
        manualIcon.ImageColor3         = Color3.fromRGB(200, 200, 210)
        manualIcon.ZIndex              = 5
        manualIcon.Parent              = manualBtn

        local manualLblInner = Instance.new("TextLabel")
        manualLblInner.Size                = UDim2.fromOffset(66, 28)
        manualLblInner.BackgroundTransparency = 1
        manualLblInner.Font               = Enum.Font.GothamSemibold
        manualLblInner.TextSize           = 11
        manualLblInner.TextColor3         = Color3.fromRGB(170, 170, 180)
        manualLblInner.Text               = MANUAL_TEXT
        manualLblInner.TextXAlignment     = Enum.TextXAlignment.Left
        manualLblInner.ZIndex             = 5
        manualLblInner.Parent             = manualBtn

        -- (Paste last key is now automatic — no button needed)

        -- ── Tween helpers ──────────────────────────────────────────────
        local EASE_OUT  = TweenInfo.new(0.30, Enum.EasingStyle.Back,  Enum.EasingDirection.Out)
        local EASE_IN   = TweenInfo.new(0.22, Enum.EasingStyle.Quad,  Enum.EasingDirection.In)
        local EASE_SINE = TweenInfo.new(0.16, Enum.EasingStyle.Sine,  Enum.EasingDirection.Out)

        -- All fade-able objects, tweened together so nothing lags behind
        local function setAllTransparency(t)
            card.BackgroundTransparency   = t
            backdrop.BackgroundTransparency = t == 0 and 0.45 or 1
            titleLbl.TextTransparency     = t
            subtitleLbl.TextTransparency  = t
            divider.BackgroundTransparency = t == 0 and 0.92 or 1
            statusLbl.TextTransparency    = t
            inputFrame.BackgroundTransparency = t
        end

        local _shown = false

        local function showAnim()
            ksGui.Enabled = true
            _shown = true
            -- Snap all to start state
            card.BackgroundTransparency   = 0
            inputFrame.BackgroundTransparency = 0
            cardScale.Scale = 0.88
            -- Fade in: backdrop
            Tw(backdrop, TweenInfo.new(0.25, Enum.EasingStyle.Sine), { BackgroundTransparency = 0.45 })
            -- Card scale bounce
            Tw(cardScale, EASE_OUT, { Scale = 1 })
            -- Text fade
            local tInfo = TweenInfo.new(0.28, Enum.EasingStyle.Sine)
            Tw(titleLbl,    tInfo, { TextTransparency = 0 })
            Tw(subtitleLbl, tInfo, { TextTransparency = 0 })
            -- Auto-fill saved key: if saved key matches current KEY — submit automatically
            task.defer(function()
                local saved = readSavedKey()
                if saved and saved ~= "" then
                    inputBox.Text = saved
                    inputBox.ClearTextOnFocus = false
                    if saved == KEY then
                        task.wait(0.35)  -- let show animation play a bit first
                        trySubmit()
                    end
                end
            end)
        end

        local function hideAnim(callback)
            -- Tween everything simultaneously so nothing lags
            Tw(backdrop,    TweenInfo.new(0.22, Enum.EasingStyle.Sine), { BackgroundTransparency = 1 })
            Tw(card,        TweenInfo.new(0.20, Enum.EasingStyle.Sine), { BackgroundTransparency = 1 })
            Tw(inputFrame,  TweenInfo.new(0.20, Enum.EasingStyle.Sine), { BackgroundTransparency = 1 })
            Tw(titleLbl,    TweenInfo.new(0.16, Enum.EasingStyle.Sine), { TextTransparency = 1 })
            Tw(subtitleLbl, TweenInfo.new(0.16, Enum.EasingStyle.Sine), { TextTransparency = 1 })
            Tw(statusLbl,   TweenInfo.new(0.16, Enum.EasingStyle.Sine), { TextTransparency = 1 })
            local t = Tw(cardScale, EASE_IN, { Scale = 0.88 })
            t.Completed:Connect(function()
                ksGui.Enabled = false
                _shown = false
                if callback then callback() end
            end)
        end

        -- Shake on wrong key
        local function shakeAnim()
            local offsets = { 9, -9, 6, -6, 3, -3, 0 }
            local function step(i)
                if i > #offsets then return end
                Tw(card, TweenInfo.new(0.04, Enum.EasingStyle.Sine), {
                    Position = UDim2.new(0.5, offsets[i], 0.5, 0)
                }).Completed:Connect(function() step(i + 1) end)
            end
            step(1)
        end


        -- Forward declaration to avoid nil when called from showAnim
        local trySubmit

        -- ── Submit logic ───────────────────────────────────────────────
        local function trySubmit()
            local entered = inputBox.Text
            if entered == "" then return end
            inputBox.ClearTextOnFocus = false   -- never clear again after first submit

            if entered == KEY then
                -- Save to file
                updateKeyFile(entered)
                statusLbl.TextColor3 = Color3.fromRGB(55, 210, 95)
                statusLbl.Text       = "Access granted"
                -- Success pulse
                inputFrame.BackgroundColor3 = Color3.fromRGB(18, 52, 28)
                Tw(inputStroke, EASE_SINE, { Color = Color3.fromRGB(55, 210, 95), Transparency = 0.3 })
                Tw(cardScale, TweenInfo.new(0.14, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1.04 })
                task.delay(0.18, function()
                    Tw(cardScale, TweenInfo.new(0.12, Enum.EasingStyle.Sine), { Scale = 1 })
                end)
                task.delay(0.55, function()
                    hideAnim(function()
                        if cfg.onCorrect then task.spawn(cfg.onCorrect) end
                    end)
                end)
            else
                statusLbl.TextColor3 = Color3.fromRGB(210, 70, 70)
                statusLbl.Text       = "Incorrect key"
                inputFrame.BackgroundColor3 = Color3.fromRGB(46, 14, 14)
                Tw(inputStroke, EASE_SINE, { Color = Color3.fromRGB(210, 70, 70), Transparency = 0.3 })
                shakeAnim()
                task.delay(0.75, function()
                    Tw(inputFrame,  EASE_SINE, { BackgroundColor3 = Color3.fromRGB(22, 22, 26) })
                    Tw(inputStroke, TweenInfo.new(0.3), { Transparency = 0.88, Color = Color3.fromRGB(255,255,255) })
                    Tw(statusLbl,   TweenInfo.new(0.3), { TextTransparency = 1 })
                end)
                if cfg.onIncorrect then task.spawn(cfg.onIncorrect, entered) end
            end
        end

        submitBtn.Activated:Connect(trySubmit)
        inputBox.FocusLost:Connect(function(enter)
            if enter then trySubmit() end
        end)



        -- ── Hover effects ──────────────────────────────────────────────
        submitBtn.MouseEnter:Connect(function() Tw(submitBtn, EASE_SINE, { BackgroundColor3 = Color3.fromRGB(65, 140, 255) }) end)
        submitBtn.MouseLeave:Connect(function() Tw(submitBtn, EASE_SINE, { BackgroundColor3 = Color3.fromRGB(40, 120, 255) }) end)
        manualBtn.MouseEnter:Connect(function() Tw(manualBtn, EASE_SINE, { BackgroundColor3 = Color3.fromRGB(36, 36, 42) }) end)
        manualBtn.MouseLeave:Connect(function() Tw(manualBtn, EASE_SINE, { BackgroundColor3 = Color3.fromRGB(28, 28, 32) }) end)
        discordBtn.MouseEnter:Connect(function() Tw(discordBtn, EASE_SINE, { BackgroundColor3 = Color3.fromRGB(110, 125, 255) }) end)
        discordBtn.MouseLeave:Connect(function() Tw(discordBtn, EASE_SINE, { BackgroundColor3 = Color3.fromRGB(88, 101, 242) }) end)


        -- ── Discord RPC ────────────────────────────────────────────────
        local function sendDiscordRPC()
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

        discordBtn.Activated:Connect(function() task.spawn(sendDiscordRPC) end)

        -- ── Copy link ──────────────────────────────────────────────────
        local _copyDebounce = false
        manualBtn.Activated:Connect(function()
            if _copyDebounce then return end
            _copyDebounce = true
            pcall(function()
                if setclipboard then setclipboard(DISCORD_LINK)
                elseif toclipboard then toclipboard(DISCORD_LINK) end
            end)
            manualLblInner.Text        = "Copied!"
            manualIcon.ImageColor3     = Color3.fromRGB(60, 210, 95)
            task.delay(1.5, function()
                manualLblInner.Text    = MANUAL_TEXT
                manualIcon.ImageColor3 = Color3.fromRGB(200, 200, 210)
                _copyDebounce = false
            end)
        end)

        -- ── Public API ─────────────────────────────────────────────────
        local KSFunctions = {}

        function KSFunctions:Show()
            showAnim()
        end

        function KSFunctions:Hide()
            hideAnim()
        end

        function KSFunctions:Destroy()
            hideAnim(function() ksGui:Destroy() end)
        end

        function KSFunctions:SetKey(key)
            KEY = tostring(key)
        end

        return KSFunctions
    end
end
