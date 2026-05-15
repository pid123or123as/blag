--[[
    MacLib — ProgressBar PreLoader Module
    Загружается через: MacLib:Preloader(url, function(mod) mod:Init(Window, section) end)
    Модуль получает: MacLib, Options (от PreLoader), Window и section передаются через Init
]]

local ProgressBar = {}
ProgressBar.__index = ProgressBar

function ProgressBar:Init(Window, section)
    local MacLib    = self.MacLib
    local TweenService = game:GetService("TweenService")

    -- Регистрируем тип если ещё не зарегистрирован
    if not MacLib._pbRegistered then
        MacLib:RegisterElement("ProgressBar", {
            Save = function(Flag, data)
                return { type = "ProgressBar", flag = Flag, value = data.Value or 0 }
            end,
            Load = function(Flag, data)
                if MacLib.Options[Flag] and data.value ~= nil then
                    MacLib.Options[Flag]:SetValue(data.value)
                end
            end,
        }, function(sectionFrame, settings, flag)
            local el = {
                Class       = "ProgressBar",
                IgnoreConfig = false,
                Settings    = settings,
                Value       = settings.Default or 0,
            }
            local font = "rbxassetid://12187365364"
            local min, max = settings.Minimum or 0, settings.Maximum or 100

            local frame = Instance.new("Frame")
            frame.Name                = "ProgressBar"
            frame.BackgroundTransparency = 1
            frame.BorderSizePixel     = 0
            frame.Size                = UDim2.new(1, 0, 0, 50)
            frame.Parent              = sectionFrame

            local lbl = Instance.new("TextLabel")
            lbl.FontFace              = Font.new(font)
            lbl.Text                  = settings.Name or ""
            lbl.TextColor3            = Color3.fromRGB(255, 255, 255)
            lbl.TextTransparency      = 0.5
            lbl.TextSize              = 13
            lbl.TextXAlignment        = Enum.TextXAlignment.Left
            lbl.BackgroundTransparency = 1
            lbl.BorderSizePixel       = 0
            lbl.AnchorPoint           = Vector2.new(0, 0)
            lbl.Position              = UDim2.fromOffset(0, 0)
            lbl.Size                  = UDim2.new(1, -44, 0, 18)
            lbl.Parent                = frame

            local pct = Instance.new("TextLabel")
            pct.FontFace              = Font.new(font)
            pct.TextColor3            = Color3.fromRGB(255, 255, 255)
            pct.TextTransparency      = 0.25
            pct.TextSize              = 12
            pct.TextXAlignment        = Enum.TextXAlignment.Right
            pct.BackgroundTransparency = 1
            pct.BorderSizePixel       = 0
            pct.AnchorPoint           = Vector2.new(1, 0)
            pct.Position              = UDim2.fromScale(1, 0)
            pct.Size                  = UDim2.fromOffset(44, 18)
            pct.Parent                = frame

            local track = Instance.new("Frame")
            track.Name                = "Track"
            track.BackgroundColor3    = Color3.fromRGB(255, 255, 255)
            track.BackgroundTransparency = 0.88
            track.BorderSizePixel     = 0
            track.AnchorPoint         = Vector2.new(0, 1)
            track.Position            = UDim2.new(0, 0, 1, 0)
            track.Size                = UDim2.new(1, 0, 0, 8)
            track.ClipsDescendants    = true
            track.Parent              = frame
            Instance.new("UICorner", track).CornerRadius = UDim.new(1, 0)
            local ts = Instance.new("UIStroke", track)
            ts.Color       = Color3.fromRGB(255, 255, 255)
            ts.Transparency = 0.88
            ts.Thickness   = 1

            local fill = Instance.new("Frame")
            fill.Name                = "Fill"
            fill.BackgroundColor3    = settings.Color or Color3.fromRGB(60, 160, 255)
            fill.BackgroundTransparency = 0.1
            fill.BorderSizePixel     = 0
            fill.AnchorPoint         = Vector2.new(0, 0.5)
            fill.Position            = UDim2.fromScale(0, 0.5)
            fill.Size                = UDim2.fromScale(0, 1)
            fill.Parent              = track
            Instance.new("UICorner", fill).CornerRadius = UDim.new(1, 0)

            local activeTween
            local function refresh(val, skipCB)
                val = math.clamp(val, min, max)
                el.Value = val
                local scale = (val - min) / math.max(max - min, 1)
                if activeTween then activeTween:Cancel() end
                activeTween = TweenService:Create(fill,
                    TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
                    { Size = UDim2.new(scale, 0, 1, 0) })
                activeTween:Play()
                pct.Text = tostring(math.round(scale * 100)) .. "%"
                if not skipCB and settings.Callback then
                    task.spawn(settings.Callback, val)
                end
            end
            refresh(el.Value, true)

            function el:SetValue(v)    refresh(tonumber(v) or 0, true) end
            function el:GetValue()     return el.Value end
            function el:SetColor(c)    fill.BackgroundColor3 = c end
            function el:UpdateName(n)  lbl.Text = n end
            function el:SetVisibility(s) frame.Visible = s end

            return el
        end)
        MacLib._pbRegistered = true
    end

    -- Добавляем хелпер на секцию для удобного создания
    function section:ProgressBar(settings, flag)
        return MacLib:CreateCustomElement(self, "ProgressBar", settings, flag)
    end

    return self
end

-- Вызывается PreLoader: возвращает таблицу-модуль
return ProgressBar
