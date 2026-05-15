--[[
    MacLib PreLoader Module — CheckBox

    Использование:
        MacLib:Preloader("https://raw.githubusercontent.com/.../CheckBox_Element.lua", {
            onLoad = function()
                local cb = mySection:CheckBox({
                    Name    = "Option A",
                    Default = false,
                    Callback = function(v) print("CheckBox:", v) end,
                }, "CB_A")
            end,
        })

    После загрузки section:CheckBox(settings, flag) доступен на любой секции.

    Методы элемента:
        cb:SetChecked(bool)   -- установить состояние
        cb:GetChecked()       -- получить текущее состояние
        cb:Toggle()           -- переключить
        cb:UpdateName(string) -- изменить заголовок
        cb:SetVisibility(bool)-- показать/скрыть
]]

return function(ctx)
    local MacLib = ctx.MacLib
    local TweenService = game:GetService("TweenService")
    local font = "rbxassetid://12187365364"

    MacLib:RegisterElement("CheckBox", {
        Save = function(Flag, data)
            return { type = "CheckBox", flag = Flag, checked = data.Checked or false }
        end,
        Load = function(Flag, data)
            if MacLib.Options[Flag] and data.checked ~= nil then
                MacLib.Options[Flag]:SetChecked(data.checked)
            end
        end,
    }, function(sectionFrame, settings, flag)

        -- Root frame
        local frame = Instance.new("Frame")
        frame.Name = "CheckBox"
        frame.BackgroundTransparency = 1
        frame.BorderSizePixel = 0
        frame.Size = UDim2.new(1, 0, 0, 38)
        frame.Parent = sectionFrame

        -- Label
        local lbl = Instance.new("TextLabel")
        lbl.FontFace = Font.new(font)
        lbl.Text = settings.Name or ""
        lbl.TextColor3 = Color3.fromRGB(255, 255, 255)
        lbl.TextSize = 13
        lbl.TextTransparency = 0.5
        lbl.RichText = true
        lbl.TextXAlignment = Enum.TextXAlignment.Left
        lbl.AnchorPoint = Vector2.new(0, 0.5)
        lbl.BackgroundTransparency = 1
        lbl.BorderSizePixel = 0
        lbl.Position = UDim2.fromScale(0, 0.5)
        lbl.Size = UDim2.new(1, -50, 0, 0)
        lbl.Parent = frame

        -- Checkbox box
        local box = Instance.new("ImageButton")
        box.AnchorPoint = Vector2.new(1, 0.5)
        box.Position = UDim2.fromScale(1, 0.5)
        box.Size = UDim2.fromOffset(20, 20)
        box.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
        box.BackgroundTransparency = 0.9
        box.BorderSizePixel = 0
        box.Image = ""
        box.AutoButtonColor = false
        box.Parent = frame
        Instance.new("UICorner", box).CornerRadius = UDim.new(0, 4)
        local bst = Instance.new("UIStroke", box)
        bst.Color = Color3.fromRGB(255, 255, 255)
        bst.Transparency = 0.75
        bst.Thickness = 1

        -- Checkmark
        local ck = Instance.new("TextLabel")
        ck.Text = "✓"
        ck.FontFace = Font.new(font, Enum.FontWeight.Medium)
        ck.TextColor3 = Color3.fromRGB(255, 255, 255)
        ck.TextSize = 13
        ck.AnchorPoint = Vector2.new(0.5, 0.5)
        ck.Position = UDim2.fromScale(0.5, 0.5)
        ck.Size = UDim2.fromScale(1, 1)
        ck.BackgroundTransparency = 1
        ck.BorderSizePixel = 0
        ck.TextTransparency = 1
        ck.Parent = box

        -- Element object
        local el = {
            Class        = "CheckBox",
            IgnoreConfig = false,
            Settings     = settings,
            Checked      = settings.Default == true,
        }

        local tweenInfo = TweenInfo.new(0.12, Enum.EasingStyle.Quad)

        local function refresh(animate)
            local targetBgColor = el.Checked and Color3.fromRGB(60, 160, 255) or Color3.fromRGB(255, 255, 255)
            local targetBgT     = el.Checked and 0.2 or 0.9
            local targetTextT   = el.Checked and 0.05 or 1

            if animate then
                TweenService:Create(box, tweenInfo, {
                    BackgroundColor3 = targetBgColor,
                    BackgroundTransparency = targetBgT,
                }):Play()
                TweenService:Create(ck, tweenInfo, {
                    TextTransparency = targetTextT,
                }):Play()
            else
                box.BackgroundColor3    = targetBgColor
                box.BackgroundTransparency = targetBgT
                ck.TextTransparency     = targetTextT
            end
        end

        refresh(false)

        box.MouseButton1Click:Connect(function()
            el.Checked = not el.Checked
            refresh(true)
            if settings.Callback then
                task.spawn(settings.Callback, el.Checked)
            end
        end)

        function el:SetChecked(s)
            el.Checked = s == true
            refresh(true)
        end
        function el:GetChecked()      return el.Checked end
        function el:Toggle()
            el.Checked = not el.Checked
            refresh(true)
            if settings.Callback then task.spawn(settings.Callback, el.Checked) end
        end
        function el:UpdateName(n)     lbl.Text = n end
        function el:SetVisibility(s)  frame.Visible = s end

        return el
    end)

    -- Патчим все секции методом :CheckBox()
    MacLib:PatchSection("CheckBox", function(self, settings, flag)
        return MacLib:CreateCustomElement(self, "CheckBox", settings, flag)
    end)
end
