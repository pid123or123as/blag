--[[
    MacLib — KeySystem element
    MacLib:KeySystem(config) -> KeySystemFunctions

    config = {
        Key             = "1234",           -- correct key (string)
        Title           = "Key System",     -- title text
        Subtitle        = "Enter your key to continue.",
        DiscordInvite   = "A58yhBsJfY",     -- Discord invite code (without discord.gg/)
        DiscordLink     = "https://discord.gg/A58yhBsJfY",
        ManualBtnText   = "Copy manual",
        ManualCopyImage = "rbxassetid://90434151822042",
        DiscordImage    = "rbxassetid://101192191207677",
        onCorrect       = function() end,   -- callback on correct key
        onIncorrect     = function(k) end,  -- callback on wrong key
    }

    Returns:
        KeySystemFunctions:Show()
        KeySystemFunctions:Hide()
        KeySystemFunctions:Destroy()
        KeySystemFunctions:SetKey(key)

    Example:
        local KS = MacLib:KeySystem({
            Key           = "1234",
            DiscordInvite = "A58yhBsJfY",
            DiscordLink   = "https://discord.gg/A58yhBsJfY",
            onCorrect     = function() print("Unlocked!") end,
        })
        KS:Show()
]]

return function(ctx)
    local MacLib      = ctx and ctx.MacLib or _G.MacLib
    local HttpService = game:GetService("HttpService")
    local TweenService= game:GetService("TweenService")
    local UIS         = game:GetService("UserInputService")

    local function Tween(obj, info, goal)
        local t = TweenService:Create(obj, info, goal); t:Play(); return t
    end

    -- ── GetGui helper (matches MacLib internals) ──
    local function GetGui()
        local p = (syn and syn.protect_gui) or (protect_gui)
        local sg = Instance.new("ScreenGui")
        sg.ZIndexBehavior   = Enum.ZIndexBehavior.Sibling
        sg.ResetOnSpawn     = false
        sg.DisplayOrder     = 9999
        if p then p(sg) end
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
        local MANUAL_TEXT  = cfg.ManualBtnText  or "Copy manual"
        local MANUAL_IMG   = cfg.ManualCopyImage or "rbxassetid://90434151822042"
        local DISCORD_IMG  = cfg.DiscordImage    or "rbxassetid://101192191207677"

        -- ── Build GUI ──────────────────────────────────────────────────
        local ksGui = GetGui()
        ksGui.Name = "MacLibKeySystem"

        -- Backdrop
        local backdrop = Instance.new("Frame")
        backdrop.Name = "Backdrop"
        backdrop.Size = UDim2.fromScale(1, 1)
        backdrop.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
        backdrop.BackgroundTransparency = 1
        backdrop.BorderSizePixel = 0
        backdrop.ZIndex = 1
        backdrop.Parent = ksGui

        -- Card
        local card = Instance.new("Frame")
        card.Name = "Card"
        card.AnchorPoint = Vector2.new(0.5, 0.5)
        card.Position = UDim2.fromScale(0.5, 0.5)
        card.Size = UDim2.fromOffset(380, 0)
        card.AutomaticSize = Enum.AutomaticSize.Y
        card.BackgroundColor3 = Color3.fromRGB(13, 13, 15)
        card.BackgroundTransparency = 1  -- starts invisible, animated in
        card.BorderSizePixel = 0
        card.ZIndex = 2
        card.ClipsDescendants = false
        card.Parent = ksGui

        local cardCorner = Instance.new("UICorner")
        cardCorner.CornerRadius = UDim.new(0, 16)
        cardCorner.Parent = card

        local cardStroke = Instance.new("UIStroke")
        cardStroke.Color = Color3.fromRGB(255, 255, 255)
        cardStroke.Transparency = 0.90
        cardStroke.Thickness = 1
        cardStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
        cardStroke.Parent = card

        local cardPad = Instance.new("UIPadding")
        cardPad.PaddingTop    = UDim.new(0, 28)
        cardPad.PaddingBottom = UDim.new(0, 24)
        cardPad.PaddingLeft   = UDim.new(0, 24)
        cardPad.PaddingRight  = UDim.new(0, 24)
        cardPad.Parent = card

        local cardList = Instance.new("UIListLayout")
        cardList.Padding = UDim.new(0, 14)
        cardList.SortOrder = Enum.SortOrder.LayoutOrder
        cardList.HorizontalAlignment = Enum.HorizontalAlignment.Center
        cardList.Parent = card

        -- UIScale for bounce animation
        local cardScale = Instance.new("UIScale")
        cardScale.Scale = 0.88
        cardScale.Parent = card

        -- ── Title ──────────────────────────────────────────────────────
        local titleLbl = Instance.new("TextLabel")
        titleLbl.Name = "Title"
        titleLbl.Size = UDim2.new(1, 0, 0, 28)
        titleLbl.BackgroundTransparency = 1
        titleLbl.Font = Enum.Font.GothamBold
        titleLbl.TextSize = 20
        titleLbl.TextColor3 = Color3.fromRGB(240, 240, 240)
        titleLbl.Text = TITLE
        titleLbl.TextXAlignment = Enum.TextXAlignment.Center
        titleLbl.TextTransparency = 1
        titleLbl.LayoutOrder = 1
        titleLbl.Parent = card

        local subtitleLbl = Instance.new("TextLabel")
        subtitleLbl.Name = "Subtitle"
        subtitleLbl.Size = UDim2.new(1, 0, 0, 18)
        subtitleLbl.BackgroundTransparency = 1
        subtitleLbl.Font = Enum.Font.Gotham
        subtitleLbl.TextSize = 13
        subtitleLbl.TextColor3 = Color3.fromRGB(140, 140, 150)
        subtitleLbl.Text = SUBTITLE
        subtitleLbl.TextXAlignment = Enum.TextXAlignment.Center
        subtitleLbl.TextTransparency = 1
        subtitleLbl.LayoutOrder = 2
        subtitleLbl.Parent = card

        -- ── Divider ────────────────────────────────────────────────────
        local divider = Instance.new("Frame")
        divider.Size = UDim2.new(1, 0, 0, 1)
        divider.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
        divider.BackgroundTransparency = 0.92
        divider.BorderSizePixel = 0
        divider.LayoutOrder = 3
        divider.Parent = card

        -- ── Input row ─────────────────────────────────────────────────
        local inputFrame = Instance.new("Frame")
        inputFrame.Name = "InputRow"
        inputFrame.Size = UDim2.new(1, 0, 0, 40)
        inputFrame.BackgroundColor3 = Color3.fromRGB(22, 22, 26)
        inputFrame.BackgroundTransparency = 0
        inputFrame.BorderSizePixel = 0
        inputFrame.LayoutOrder = 4
        inputFrame.Parent = card

        local inputCorner = Instance.new("UICorner")
        inputCorner.CornerRadius = UDim.new(0, 10)
        inputCorner.Parent = inputFrame

        local inputStroke = Instance.new("UIStroke")
        inputStroke.Color = Color3.fromRGB(255, 255, 255)
        inputStroke.Transparency = 0.88
        inputStroke.Thickness = 1
        inputStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
        inputStroke.Parent = inputFrame

        local inputBox = Instance.new("TextBox")
        inputBox.Name = "Input"
        inputBox.AnchorPoint = Vector2.new(0, 0.5)
        inputBox.Position = UDim2.new(0, 14, 0.5, 0)
        inputBox.Size = UDim2.new(1, -100, 0, 28)
        inputBox.BackgroundTransparency = 1
        inputBox.Font = Enum.Font.Gotham
        inputBox.TextSize = 14
        inputBox.TextColor3 = Color3.fromRGB(220, 220, 220)
        inputBox.PlaceholderText = "Enter key..."
        inputBox.PlaceholderColor3 = Color3.fromRGB(90, 90, 100)
        inputBox.ClearTextOnFocus = false
        inputBox.TextXAlignment = Enum.TextXAlignment.Left
        inputBox.ZIndex = 3
        inputBox.Parent = inputFrame

        -- Submit button (inside input row)
        local submitBtn = Instance.new("TextButton")
        submitBtn.Name = "Submit"
        submitBtn.AnchorPoint = Vector2.new(1, 0.5)
        submitBtn.Position = UDim2.new(1, -8, 0.5, 0)
        submitBtn.Size = UDim2.fromOffset(72, 28)
        submitBtn.BackgroundColor3 = Color3.fromRGB(40, 120, 255)
        submitBtn.BorderSizePixel = 0
        submitBtn.Font = Enum.Font.GothamSemibold
        submitBtn.TextSize = 13
        submitBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
        submitBtn.Text = "Submit"
        submitBtn.AutoButtonColor = false
        submitBtn.ZIndex = 4
        submitBtn.Parent = inputFrame

        local submitCorner = Instance.new("UICorner")
        submitCorner.CornerRadius = UDim.new(0, 7)
        submitCorner.Parent = submitBtn

        -- ── Status label ───────────────────────────────────────────────
        local statusLbl = Instance.new("TextLabel")
        statusLbl.Name = "Status"
        statusLbl.Size = UDim2.new(1, 0, 0, 16)
        statusLbl.BackgroundTransparency = 1
        statusLbl.Font = Enum.Font.Gotham
        statusLbl.TextSize = 12
        statusLbl.TextColor3 = Color3.fromRGB(100, 100, 110)
        statusLbl.Text = " "
        statusLbl.TextXAlignment = Enum.TextXAlignment.Center
        statusLbl.LayoutOrder = 5
        statusLbl.Parent = card

        -- ── Discord/manual row ─────────────────────────────────────────
        local bottomRow = Instance.new("Frame")
        bottomRow.Name = "BottomRow"
        bottomRow.Size = UDim2.new(1, 0, 0, 34)
        bottomRow.BackgroundTransparency = 1
        bottomRow.LayoutOrder = 6
        bottomRow.Parent = card

        local bottomList = Instance.new("UIListLayout")
        bottomList.FillDirection = Enum.FillDirection.Horizontal
        bottomList.HorizontalAlignment = Enum.HorizontalAlignment.Left
        bottomList.VerticalAlignment = Enum.VerticalAlignment.Center
        bottomList.Padding = UDim.new(0, 10)
        bottomList.SortOrder = Enum.SortOrder.LayoutOrder
        bottomList.Parent = bottomRow

        -- Discord round icon button
        local discordBtn = Instance.new("ImageButton")
        discordBtn.Name = "DiscordBtn"
        discordBtn.Size = UDim2.fromOffset(34, 34)
        discordBtn.BackgroundColor3 = Color3.fromRGB(88, 101, 242)
        discordBtn.BorderSizePixel = 0
        discordBtn.Image = DISCORD_IMG
        discordBtn.AutoButtonColor = false
        discordBtn.ScaleType = Enum.ScaleType.Fit
        discordBtn.ZIndex = 3
        discordBtn.LayoutOrder = 1
        discordBtn.Parent = bottomRow

        local discordCorner = Instance.new("UICorner")
        discordCorner.CornerRadius = UDim.new(1, 0)
        discordCorner.Parent = discordBtn

        -- "Don't have a key? →" label
        local hintLbl = Instance.new("TextLabel")
        hintLbl.Name = "Hint"
        hintLbl.Size = UDim2.new(0, 160, 1, 0)
        hintLbl.BackgroundTransparency = 1
        hintLbl.Font = Enum.Font.Gotham
        hintLbl.TextSize = 12
        hintLbl.TextColor3 = Color3.fromRGB(110, 110, 120)
        hintLbl.Text = "Don't have a key? Join us"
        hintLbl.TextXAlignment = Enum.TextXAlignment.Left
        hintLbl.LayoutOrder = 2
        hintLbl.Parent = bottomRow

        -- Copy manual button
        local manualBtn = Instance.new("TextButton")
        manualBtn.Name = "ManualBtn"
        manualBtn.Size = UDim2.fromOffset(120, 30)
        manualBtn.BackgroundColor3 = Color3.fromRGB(28, 28, 32)
        manualBtn.BorderSizePixel = 0
        manualBtn.Font = Enum.Font.GothamSemibold
        manualBtn.TextSize = 12
        manualBtn.TextColor3 = Color3.fromRGB(180, 180, 190)
        manualBtn.Text = ""
        manualBtn.AutoButtonColor = false
        manualBtn.ZIndex = 3
        manualBtn.LayoutOrder = 3
        manualBtn.Parent = bottomRow

        local manualCorner = Instance.new("UICorner")
        manualCorner.CornerRadius = UDim.new(0, 8)
        manualCorner.Parent = manualBtn

        local manualStroke = Instance.new("UIStroke")
        manualStroke.Color = Color3.fromRGB(255, 255, 255)
        manualStroke.Transparency = 0.88
        manualStroke.Thickness = 1
        manualStroke.Parent = manualBtn

        local manualBtnLayout = Instance.new("UIListLayout")
        manualBtnLayout.FillDirection = Enum.FillDirection.Horizontal
        manualBtnLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
        manualBtnLayout.VerticalAlignment = Enum.VerticalAlignment.Center
        manualBtnLayout.Padding = UDim.new(0, 6)
        manualBtnLayout.Parent = manualBtn

        local manualIcon = Instance.new("ImageLabel")
        manualIcon.Size = UDim2.fromOffset(16, 16)
        manualIcon.BackgroundTransparency = 1
        manualIcon.Image = MANUAL_IMG
        manualIcon.ImageTransparency = 0
        manualIcon.ZIndex = 4
        manualIcon.Parent = manualBtn

        local manualLbl = Instance.new("TextLabel")
        manualLbl.Size = UDim2.new(0, 80, 1, 0)
        manualLbl.BackgroundTransparency = 1
        manualLbl.Font = Enum.Font.GothamSemibold
        manualLbl.TextSize = 12
        manualLbl.TextColor3 = Color3.fromRGB(180, 180, 190)
        manualLbl.Text = MANUAL_TEXT
        manualLbl.TextXAlignment = Enum.TextXAlignment.Left
        manualLbl.ZIndex = 4
        manualLbl.Parent = manualBtn

        -- ── Animations ─────────────────────────────────────────────────
        local EASE_OUT  = TweenInfo.new(0.32, Enum.EasingStyle.Back,  Enum.EasingDirection.Out)
        local EASE_IN   = TweenInfo.new(0.20, Enum.EasingStyle.Quad,  Enum.EasingDirection.In)
        local EASE_SINE = TweenInfo.new(0.18, Enum.EasingStyle.Sine,  Enum.EasingDirection.Out)

        local _shown = false

        local function showAnim()
            ksGui.Enabled = true
            _shown = true
            -- backdrop fade
            Tween(backdrop, TweenInfo.new(0.25, Enum.EasingStyle.Sine), { BackgroundTransparency = 0.45 })
            -- card scale + fade
            card.BackgroundTransparency = 0
            cardScale.Scale = 0.88
            Tween(cardScale, EASE_OUT, { Scale = 1 })
            -- text fade in
            local textT = TweenInfo.new(0.28, Enum.EasingStyle.Sine)
            Tween(titleLbl,    textT, { TextTransparency = 0 })
            Tween(subtitleLbl, textT, { TextTransparency = 0 })
        end

        local function hideAnim(callback)
            Tween(backdrop, TweenInfo.new(0.20, Enum.EasingStyle.Sine), { BackgroundTransparency = 1 })
            local t = Tween(cardScale, EASE_IN, { Scale = 0.88 })
            Tween(card, TweenInfo.new(0.18, Enum.EasingStyle.Sine), { BackgroundTransparency = 1 })
            t.Completed:Connect(function()
                ksGui.Enabled = false
                _shown = false
                if callback then callback() end
            end)
        end

        -- Shake animation on wrong key
        local function shakeAnim()
            local orig = card.Position
            local offsets = { 8, -8, 6, -6, 3, -3, 0 }
            local function step(i)
                if i > #offsets then return end
                Tween(card, TweenInfo.new(0.04, Enum.EasingStyle.Sine), {
                    Position = UDim2.new(0.5, offsets[i], 0.5, 0)
                }).Completed:Connect(function() step(i + 1) end)
            end
            step(1)
        end

        -- Success pulse
        local function successAnim()
            inputFrame.BackgroundColor3 = Color3.fromRGB(20, 60, 30)
            inputStroke.Color = Color3.fromRGB(60, 220, 100)
            inputStroke.Transparency = 0.3
            statusLbl.TextColor3 = Color3.fromRGB(60, 220, 100)
            Tween(cardScale, TweenInfo.new(0.15, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1.04 })
            task.delay(0.2, function()
                Tween(cardScale, TweenInfo.new(0.12, Enum.EasingStyle.Sine, Enum.EasingDirection.In), { Scale = 1 })
            end)
        end

        -- Wrong key red flash
        local function errorAnim()
            inputFrame.BackgroundColor3 = Color3.fromRGB(50, 14, 14)
            inputStroke.Color = Color3.fromRGB(220, 60, 60)
            inputStroke.Transparency = 0.3
            statusLbl.TextColor3 = Color3.fromRGB(220, 80, 80)
            shakeAnim()
            task.delay(0.7, function()
                Tween(inputFrame, TweenInfo.new(0.3, Enum.EasingStyle.Sine), { BackgroundColor3 = Color3.fromRGB(22, 22, 26) })
                Tween(inputStroke, TweenInfo.new(0.3), { Transparency = 0.88, Color = Color3.fromRGB(255, 255, 255) })
                Tween(statusLbl, TweenInfo.new(0.3), { TextTransparency = 1 })
            end)
        end

        -- ── Submit logic ───────────────────────────────────────────────
        local function trySubmit()
            local entered = inputBox.Text
            if entered == KEY then
                statusLbl.Text = "✓ Access granted"
                successAnim()
                task.delay(0.55, function()
                    hideAnim(function()
                        if cfg.onCorrect then task.spawn(cfg.onCorrect) end
                    end)
                end)
            else
                statusLbl.Text = "✗ Incorrect key"
                errorAnim()
                if cfg.onIncorrect then task.spawn(cfg.onIncorrect, entered) end
            end
        end

        submitBtn.Activated:Connect(trySubmit)
        inputBox.FocusLost:Connect(function(enter)
            if enter then trySubmit() end
        end)

        -- Button hover effects
        submitBtn.MouseEnter:Connect(function()
            Tween(submitBtn, EASE_SINE, { BackgroundColor3 = Color3.fromRGB(60, 140, 255) })
        end)
        submitBtn.MouseLeave:Connect(function()
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

        discordBtn.Activated:Connect(function()
            task.spawn(sendDiscordRPC)
        end)

        -- ── Copy manual link ────────────────────────────────────────────
        manualBtn.Activated:Connect(function()
            pcall(function()
                if setclipboard then setclipboard(DISCORD_LINK)
                elseif toclipboard then toclipboard(DISCORD_LINK) end
            end)
            local orig = manualLbl.Text
            manualLbl.Text = "Copied!"
            manualIcon.ImageColor3 = Color3.fromRGB(60, 220, 100)
            task.delay(1.5, function()
                manualLbl.Text = orig
                manualIcon.ImageColor3 = Color3.fromRGB(255, 255, 255)
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

        ksGui.Enabled = false
        return KSFunctions
    end
end
