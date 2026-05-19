-- [v3.6] AUTO DRIBBLE + AUTO TACKLE
-- Changelog v3.6:
-- [FIX] AutoDribble: fallback-ветка (без IsTackling) теперь ОБЯЗАТЕЛЬНО проверяет
--       IsTackling — если нет анимации такла и враг просто стоит/ходит рядом, скрипт
--       НЕ реагирует. Старая логика: "если flatVel >= 1.5 и dot > 0.55 → deke" —
--       это срабатывало на любого бегущего мимо игрока.
-- [FIX] Стадия 0 (point blank < 4): добавлена проверка — враг должен иметь IsTackling
--       OR двигаться прямо на нас (dot > 0.7 at close range) — иначе false.
-- [OPT] Угловые вычисления: dot-продукт заменён на векторное вычисление
--       без acos/deg — используем только dot (cosine) для сравнения с косинус-порогом.
--       acos теперь вызывается ТОЛЬКО в Debug label, и только если Debug включён.
-- [OPT] PrecomputePlayers: убрана повторная итерация по Players — теперь один проход.
--       velocity из ALV/history сравниваем через sqrMagnitude (избегаем sqrt).
-- [OPT] ShouldDribbleNow: timeToCollision теперь считается на основе planeDistSq
--       (без промежуточного sqrt где возможно).
-- [OPT] GetCosThreshold: убрана внутренняя проверка — кэш инвалидируется только через
--       внешний флаг _angleDirty = true.
-- [OPT] UpdateTargetCircles: Circle refresh только при смене видимого набора игроков.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Camera = Workspace.CurrentCamera
local UserInputService = game:GetService("UserInputService")
local Debris = game:GetService("Debris")
local Stats = game:GetService("Stats")

local LocalPlayer = Players.LocalPlayer
local Character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
local HumanoidRootPart = Character:WaitForChild("HumanoidRootPart")
local Humanoid = Character:WaitForChild("Humanoid")

local ActionRemote = ReplicatedStorage.Remotes:WaitForChild("Action")
local SoftDisPlayerRemote = ReplicatedStorage.Remotes:WaitForChild("SoftDisPlayer")
local Animations = ReplicatedStorage:WaitForChild("Animations")
local DribbleAnims = Animations:WaitForChild("Dribble")

local DribbleAnimIds = {}
for _, anim in pairs(DribbleAnims:GetChildren()) do
    if anim:IsA("Animation") then
        table.insert(DribbleAnimIds, anim.AnimationId)
    end
end

-- === ПИНГ ===
local function GetPing()
    local success, pingValue = pcall(function()
        local pingStat = Stats.Network.ServerStatsItem["Data Ping"]
        local pingStr = pingStat:GetValueString()
        local ping = tonumber(pingStr:match("%d+"))
        return ping or 0
    end)
    if success and pingValue then return pingValue / 1000 end
    return 0.1
end

-- === CONFIG ===
local AutoTackleConfig = {
    Enabled = false,
    Mode = "OnlyDribble",
    MaxDistance = 20,
    TackleDistance = 0,
    TackleSpeed = 60,
    OnlyPlayer = true,
    RotationMethod = "Snap",
    DribbleDelayTime = 0,
    EagleEyeMinDelay = 0.2,
    EagleEyeMaxDelay = 0.6,
    ManualTackleEnabled = true,
    ManualTackleKeybind = Enum.KeyCode.Q,
    ManualTackleCooldown = 0.5,
}

local AutoDribbleConfig = {
    Enabled = false,
    MaxDribbleDistance = 30,
    DribbleActivationDistance = 17,
    MinAngleForDribble = 32,
    ShowServerPos = false,
}

local DebugConfig = {
    Enabled = false,
    MoveEnabled = false,
    Position = Vector2.new(0.5, 0.5)
}

-- === STATES ===
local AutoTackleStatus = {
    Running = false,
    Connection = nil,
    HeartbeatConnection = nil,
    InputConnection = nil,
    Ping = 0.1,
    LastPingUpdate = 0,
    TargetPositionHistory = {},
    TargetCircles = {}
}

local AutoDribbleStatus = {
    Running = false,
    Connection = nil,
    HeartbeatConnection = nil,
    LastDribbleTime = 0,
}

local DribbleStates = {}
local TackleStates = {}
local PrecomputedPlayers = {}
local HasBall = false
local CanDribbleNow = false
local DribbleCooldownList = {}
local EagleEyeTimers = {}
local IsTypingInChat = false
local LastManualTackleTime = 0
local CurrentTargetOwner = nil

local SPECIFIC_TACKLE_ID = "rbxassetid://14317040670"

-- ============================================================
-- === ПРЕДИКТ ПОЗИЦИИ ВРАГА
-- ============================================================
local HISTORY_SIZE = 12
local HISTORY_WINDOW = 0.12

local function RecordTargetPosition(ownerRoot, player)
    local history = AutoTackleStatus.TargetPositionHistory[player]
    if not history then
        history = {}
        AutoTackleStatus.TargetPositionHistory[player] = history
    end
    table.insert(history, { time = tick(), pos = ownerRoot.Position })
    while #history > HISTORY_SIZE do table.remove(history, 1) end
end

local function GetPositionBasedVelocity(player)
    local history = AutoTackleStatus.TargetPositionHistory[player]
    if not history or #history < 2 then return Vector3.zero end
    local now = tick()
    local oldest, newest = nil, nil
    for _, pt in ipairs(history) do
        if now - pt.time <= HISTORY_WINDOW then
            if not oldest then oldest = pt end
            newest = pt
        end
    end
    if not oldest or oldest == newest then
        if #history >= 2 then
            oldest = history[#history - 1]
            newest = history[#history]
        else
            return Vector3.zero
        end
    end
    local dt = newest.time - oldest.time
    if dt < 0.001 then return Vector3.zero end
    return (newest.pos - oldest.pos) / dt
end

local function CalcInterceptTime(fromPos, targetPos, vel, speed)
    local toTarget = targetPos - fromPos
    local dist = toTarget.Magnitude
    if dist < 0.01 then return 0 end
    local v2 = vel:Dot(vel)
    local ts2 = speed * speed
    local dotDV = toTarget:Dot(vel)
    local a = ts2 - v2
    local b = -2 * dotDV
    local c = -(dist * dist)
    local t
    if math.abs(a) < 0.001 then
        t = (math.abs(b) > 0.001) and (-c / b) or (dist / math.max(speed, 1))
    else
        local disc = b * b - 4 * a * c
        if disc < 0 then
            t = dist / math.max(speed, 1)
        else
            local sqrtD = math.sqrt(disc)
            local t1 = (-b - sqrtD) / (2 * a)
            local t2 = (-b + sqrtD) / (2 * a)
            if t1 > 0 and t2 > 0 then t = math.min(t1, t2)
            elseif t1 > 0 then t = t1
            elseif t2 > 0 then t = t2
            else t = dist / math.max(speed, 1) end
        end
    end
    return math.clamp(t, 0.02, 0.5)
end

local function PredictTargetPosition(ownerRoot, player)
    if not ownerRoot then return ownerRoot.Position end
    local ping = AutoTackleStatus.Ping
    local vel = GetPositionBasedVelocity(player)
    local flatVel = Vector3.new(vel.X, 0, vel.Z)
    local serverPos = ownerRoot.Position + flatVel * ping
    local myPos2D = Vector3.new(HumanoidRootPart.Position.X, 0, HumanoidRootPart.Position.Z)
    local target2D = Vector3.new(serverPos.X, 0, serverPos.Z)
    local interceptT = CalcInterceptTime(myPos2D, target2D, flatVel, AutoTackleConfig.TackleSpeed)
    return Vector3.new(
        serverPos.X + flatVel.X * interceptT,
        serverPos.Y,
        serverPos.Z + flatVel.Z * interceptT
    )
end

local function UpdatePredictionLabel(ownerRoot, player)
    if not Gui or not DebugConfig.Enabled or not AutoTackleConfig.Enabled then return end
    if not ownerRoot or not player then
        Gui.PredictionLabel.Text = "Pred: no target"
        return
    end
    local ping = AutoTackleStatus.Ping
    local vel = GetPositionBasedVelocity(player)
    local flatVel = Vector3.new(vel.X, 0, vel.Z)
    local serverPos = ownerRoot.Position + flatVel * ping
    local myPos2D = Vector3.new(HumanoidRootPart.Position.X, 0, HumanoidRootPart.Position.Z)
    local target2D = Vector3.new(serverPos.X, 0, serverPos.Z)
    local dist = (target2D - myPos2D).Magnitude
    local interceptT = CalcInterceptTime(myPos2D, target2D, flatVel, AutoTackleConfig.TackleSpeed)
    Gui.PredictionLabel.Text = string.format(
        "p=%dms t=%dms v=%.0f d=%.0f",
        math.round(ping * 1000),
        math.round(interceptT * 1000),
        flatVel.Magnitude,
        dist
    )
end

-- === ПИНГ UPDATE ===
local function UpdatePing()
    local currentTime = tick()
    if currentTime - AutoTackleStatus.LastPingUpdate > 1 then
        AutoTackleStatus.Ping = GetPing()
        AutoTackleStatus.LastPingUpdate = currentTime
        if Gui and AutoTackleConfig.Enabled then
            Gui.PingLabel.Text = string.format("Ping: %dms", math.round(AutoTackleStatus.Ping * 1000))
        end
    end
end

-- ============================================================
-- === СЕРВЕРНАЯ ПОЗИЦИЯ (CFrame-based)
-- ============================================================
local MY_HISTORY_SIZE = 10
local MyPositionHistory = {}

local function RecordMyPosition()
    table.insert(MyPositionHistory, {
        time = tick(),
        cframe = HumanoidRootPart.CFrame
    })
    while #MyPositionHistory > MY_HISTORY_SIZE do
        table.remove(MyPositionHistory, 1)
    end
end

local function GetMyVelocityFromHistory()
    if #MyPositionHistory < 2 then return Vector3.zero end
    local oldest = MyPositionHistory[1]
    local newest = MyPositionHistory[#MyPositionHistory]
    local dt = newest.time - oldest.time
    if dt < 0.001 then return Vector3.zero end
    return (newest.cframe.Position - oldest.cframe.Position) / dt
end

local function GetMyServerCFrame()
    local networkDelay = AutoTackleStatus.Ping * 1.5
    local myVel = GetMyVelocityFromHistory()
    local flatVel = Vector3.new(myVel.X, 0, myVel.Z)
    local serverPos = HumanoidRootPart.Position - (flatVel * networkDelay)
    return CFrame.new(serverPos) * (HumanoidRootPart.CFrame - HumanoidRootPart.CFrame.Position)
end

-- ============================================================
-- === 3D BOX СЕРВЕРНОЙ ПОЗИЦИИ
-- ============================================================
local BOX_W, BOX_H, BOX_D = 2.2, 5.5, 2.2
local BOX_EDGES = {
    {1,2},{2,3},{3,4},{4,1},
    {5,6},{6,7},{7,8},{8,5},
    {1,5},{2,6},{3,7},{4,8},
}

local function CreateBoxLines(color, thickness)
    local lines = {}
    for i = 1, 12 do
        local line = Drawing.new("Line")
        line.Color = color or Color3.fromRGB(0, 200, 255)
        line.Thickness = thickness or 1.5
        line.Visible = false
        table.insert(lines, line)
    end
    return lines
end

local function GetBoxCorners(cf, offsetY)
    local o = offsetY or 0
    local hW, hH, hD = BOX_W/2, BOX_H/2, BOX_D/2
    return {
        cf:PointToWorldSpace(Vector3.new(-hW, -hH+o, -hD)),
        cf:PointToWorldSpace(Vector3.new( hW, -hH+o, -hD)),
        cf:PointToWorldSpace(Vector3.new( hW, -hH+o, hD)),
        cf:PointToWorldSpace(Vector3.new(-hW, -hH+o, hD)),
        cf:PointToWorldSpace(Vector3.new(-hW, hH+o, -hD)),
        cf:PointToWorldSpace(Vector3.new( hW, hH+o, -hD)),
        cf:PointToWorldSpace(Vector3.new( hW, hH+o, hD)),
        cf:PointToWorldSpace(Vector3.new(-hW, hH+o, hD)),
    }
end

local function UpdateBoxLines(lines, cf, offsetY, color)
    if not lines then return end
    local corners = GetBoxCorners(cf, offsetY)
    for i, edge in ipairs(BOX_EDGES) do
        local line = lines[i]
        if not line then continue end
        local sa, aOn = Camera:WorldToViewportPoint(corners[edge[1]])
        local sb, bOn = Camera:WorldToViewportPoint(corners[edge[2]])
        if aOn and bOn and sa.Z > 0.1 and sb.Z > 0.1 then
            line.From = Vector2.new(sa.X, sa.Y)
            line.To = Vector2.new(sb.X, sb.Y)
            line.Color = color or line.Color
            line.Visible = true
        else
            line.Visible = false
        end
    end
end

local function HideBoxLines(lines)
    if not lines then return end
    for _, line in ipairs(lines) do line.Visible = false end
end

local function RemoveBoxLines(lines)
    if not lines then return end
    for _, line in ipairs(lines) do pcall(function() line:Remove() end) end
end

-- === GUI (Drawing) ===
local Gui = nil
local function SetupGUI()
    Gui = {
        TackleWaitLabel = Drawing.new("Text"),
        TackleTargetLabel = Drawing.new("Text"),
        TackleDribblingLabel = Drawing.new("Text"),
        TackleTacklingLabel = Drawing.new("Text"),
        EagleEyeLabel = Drawing.new("Text"),
        DribbleStatusLabel = Drawing.new("Text"),
        DribbleTargetLabel = Drawing.new("Text"),
        DribbleTacklingLabel = Drawing.new("Text"),
        AutoDribbleLabel = Drawing.new("Text"),
        CooldownListLabel = Drawing.new("Text"),
        ModeLabel = Drawing.new("Text"),
        ManualTackleLabel = Drawing.new("Text"),
        PingLabel = Drawing.new("Text"),
        AngleLabel = Drawing.new("Text"),
        PredictionLabel = Drawing.new("Text"),
        ServerPosLabel = Drawing.new("Text"),
        TargetRingLines = {},
        ServerPosBoxLines = nil,
        TackleDebugLabels = {},
        DribbleDebugLabels = {}
    }

    Gui.ServerPosBoxLines = CreateBoxLines(Color3.fromRGB(0, 200, 255), 1.5)

    local screenSize = Camera.ViewportSize
    local centerX = screenSize.X / 2
    local tackleY = screenSize.Y * 0.6
    local offsetTackleY = tackleY + 30
    local offsetDribbleY = tackleY - 50

    local tackleLabels = {
        Gui.TackleWaitLabel, Gui.TackleTargetLabel, Gui.TackleDribblingLabel,
        Gui.TackleTacklingLabel, Gui.EagleEyeLabel, Gui.CooldownListLabel,
        Gui.ModeLabel, Gui.ManualTackleLabel, Gui.PingLabel, Gui.AngleLabel,
        Gui.PredictionLabel, Gui.ServerPosLabel
    }
    for _, label in ipairs(tackleLabels) do
        label.Size = 16; label.Color = Color3.fromRGB(255, 255, 255)
        label.Outline = true; label.Center = true
        label.Visible = DebugConfig.Enabled and AutoTackleConfig.Enabled
        table.insert(Gui.TackleDebugLabels, label)
    end

    Gui.TackleWaitLabel.Color = Color3.fromRGB(255, 165, 0)
    Gui.ServerPosLabel.Color = Color3.fromRGB(0, 200, 255)

    Gui.TackleWaitLabel.Position = Vector2.new(centerX, offsetTackleY);   offsetTackleY += 15
    Gui.TackleTargetLabel.Position = Vector2.new(centerX, offsetTackleY); offsetTackleY += 15
    Gui.TackleDribblingLabel.Position = Vector2.new(centerX, offsetTackleY); offsetTackleY += 15
    Gui.TackleTacklingLabel.Position = Vector2.new(centerX, offsetTackleY); offsetTackleY += 15
    Gui.EagleEyeLabel.Position = Vector2.new(centerX, offsetTackleY);     offsetTackleY += 15
    Gui.CooldownListLabel.Position = Vector2.new(centerX, offsetTackleY); offsetTackleY += 15
    Gui.ModeLabel.Position = Vector2.new(centerX, offsetTackleY);         offsetTackleY += 15
    Gui.ManualTackleLabel.Position = Vector2.new(centerX, offsetTackleY); offsetTackleY += 15
    Gui.PingLabel.Position = Vector2.new(centerX, offsetTackleY);         offsetTackleY += 15
    Gui.AngleLabel.Position = Vector2.new(centerX, offsetTackleY);        offsetTackleY += 15
    Gui.PredictionLabel.Position = Vector2.new(centerX, offsetTackleY);   offsetTackleY += 15
    Gui.ServerPosLabel.Position = Vector2.new(centerX, offsetTackleY)

    local dribbleLabels = {
        Gui.DribbleStatusLabel, Gui.DribbleTargetLabel,
        Gui.DribbleTacklingLabel, Gui.AutoDribbleLabel
    }
    for _, label in ipairs(dribbleLabels) do
        label.Size = 16; label.Color = Color3.fromRGB(255, 255, 255)
        label.Outline = true; label.Center = true
        label.Visible = DebugConfig.Enabled and AutoDribbleConfig.Enabled
        table.insert(Gui.DribbleDebugLabels, label)
    end

    Gui.DribbleStatusLabel.Position = Vector2.new(centerX, offsetDribbleY); offsetDribbleY += 15
    Gui.DribbleTargetLabel.Position = Vector2.new(centerX, offsetDribbleY); offsetDribbleY += 15
    Gui.DribbleTacklingLabel.Position = Vector2.new(centerX, offsetDribbleY); offsetDribbleY += 15
    Gui.AutoDribbleLabel.Position = Vector2.new(centerX, offsetDribbleY)

    Gui.TackleWaitLabel.Text = "Wait: 0.00"
    Gui.TackleTargetLabel.Text = "Target: None"
    Gui.TackleDribblingLabel.Text = "isDribbling: false"
    Gui.TackleTacklingLabel.Text = "isTackling: false"
    Gui.EagleEyeLabel.Text = "EagleEye: Idle"
    Gui.CooldownListLabel.Text = "CooldownList: 0"
    Gui.ModeLabel.Text = "Mode: " .. AutoTackleConfig.Mode
    Gui.ManualTackleLabel.Text = "ManualTackle: Ready [" .. tostring(AutoTackleConfig.ManualTackleKeybind) .. "]"
    Gui.PingLabel.Text = "Ping: 0ms"
    Gui.AngleLabel.Text = "Angle: -"
    Gui.PredictionLabel.Text = "Pred: 0ms"
    Gui.ServerPosLabel.Text = "ServerPos: -"
    Gui.DribbleStatusLabel.Text = "Dribble: Ready"
    Gui.DribbleTargetLabel.Text = "Targets: 0"
    Gui.DribbleTacklingLabel.Text = "Nearest: None"
    Gui.AutoDribbleLabel.Text = "AutoDribble: Idle"

    for i = 1, 24 do
        local line = Drawing.new("Line")
        line.Thickness = 3; line.Color = Color3.fromRGB(255, 0, 0); line.Visible = false
        table.insert(Gui.TargetRingLines, line)
    end
end

local function UpdateServerPosBox()
    if not Gui or not Gui.ServerPosBoxLines then return end
    if not AutoDribbleConfig.Enabled or not AutoDribbleConfig.ShowServerPos or not DebugConfig.Enabled then
        HideBoxLines(Gui.ServerPosBoxLines)
        if Gui.ServerPosLabel then Gui.ServerPosLabel.Text = "ServerPos: -" end
        return
    end
    local serverCF = GetMyServerCFrame()
    local serverPos = serverCF.Position
    UpdateBoxLines(Gui.ServerPosBoxLines, serverCF, -BOX_H/2 + 3, Color3.fromRGB(0, 200, 255))
    if Gui.ServerPosLabel then
        local delay = math.round(AutoTackleStatus.Ping * 1.5 * 1000)
        local dist = (serverPos - HumanoidRootPart.Position).Magnitude
        Gui.ServerPosLabel.Text = string.format("ServerPos: %dms delay | %.1f studs", delay, dist)
    end
end

local function UpdateDebugVisibility()
    if not Gui then return end
    local tackleVisible = DebugConfig.Enabled and AutoTackleConfig.Enabled
    for _, label in ipairs(Gui.TackleDebugLabels) do label.Visible = tackleVisible end
    local dribbleVisible = DebugConfig.Enabled and AutoDribbleConfig.Enabled
    for _, label in ipairs(Gui.DribbleDebugLabels) do label.Visible = dribbleVisible end
    if not AutoTackleConfig.Enabled then
        for _, line in ipairs(Gui.TargetRingLines) do line.Visible = false end
    end
    if not AutoDribbleConfig.Enabled or not AutoDribbleConfig.ShowServerPos then
        if Gui.ServerPosBoxLines then HideBoxLines(Gui.ServerPosBoxLines) end
    end
end

local function CleanupDebugText()
    if not Gui then return end
    if not AutoTackleConfig.Enabled then
        Gui.TackleWaitLabel.Text = "Wait: 0.00"
        Gui.TackleTargetLabel.Text = "Target: None"
        Gui.TackleDribblingLabel.Text = "isDribbling: false"
        Gui.TackleTacklingLabel.Text = "isTackling: false"
        Gui.EagleEyeLabel.Text = "EagleEye: Idle"
        Gui.ManualTackleLabel.Text = "ManualTackle: Ready [" .. tostring(AutoTackleConfig.ManualTackleKeybind) .. "]"
        Gui.ModeLabel.Text = "Mode: " .. AutoTackleConfig.Mode
        Gui.PingLabel.Text = "Ping: 0ms"
        Gui.PredictionLabel.Text = "Pred: 0ms"
    end
    if not AutoDribbleConfig.Enabled then
        Gui.DribbleStatusLabel.Text = "Dribble: Ready"
        Gui.DribbleTargetLabel.Text = "Targets: 0"
        Gui.DribbleTacklingLabel.Text = "Nearest: None"
        Gui.AutoDribbleLabel.Text = "AutoDribble: Idle"
        if Gui.ServerPosBoxLines then HideBoxLines(Gui.ServerPosBoxLines) end
    end
end

-- === 3D КРУГИ ===
local function Create3DCircle()
    local circle = {}
    for i = 1, 24 do
        local line = Drawing.new("Line")
        line.Thickness = 3; line.Color = Color3.fromRGB(255, 0, 0); line.Visible = false
        table.insert(circle, line)
    end
    return circle
end

local function Update3DCircle(circle, position, radius, color)
    if not circle then return end
    local segments = #circle
    local points = {}
    for i = 1, segments do
        local angle = (i - 1) * 2 * math.pi / segments
        table.insert(points, position + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius))
    end
    for i, line in ipairs(circle) do
        local startPoint = points[i]; local endPoint = points[i % segments + 1]
        local ss, sOn = Camera:WorldToViewportPoint(startPoint)
        local es, eOn = Camera:WorldToViewportPoint(endPoint)
        if sOn and eOn and ss.Z > 0.1 and es.Z > 0.1 then
            line.From = Vector2.new(ss.X, ss.Y); line.To = Vector2.new(es.X, es.Y)
            line.Color = color; line.Visible = true
        else
            line.Visible = false
        end
    end
end

local function Hide3DCircle(circle)
    if not circle then return end
    for _, line in ipairs(circle) do line.Visible = false end
end

-- [OPT] UpdateTargetCircles: обновляем только активно-видимых таклеров
local _prevCirclePlayers = {}
local function UpdateTargetCircles()
    local currentPlayers = {}
    for player, data in pairs(PrecomputedPlayers) do
        if data.IsValid and TackleStates[player] and TackleStates[player].IsTackling then
            currentPlayers[player] = true
            if not AutoTackleStatus.TargetCircles[player] then
                AutoTackleStatus.TargetCircles[player] = Create3DCircle()
            end
            local circle = AutoTackleStatus.TargetCircles[player]
            local targetRoot = data.RootPart
            if targetRoot then
                local distance = data.Distance
                local color = Color3.fromRGB(255, 0, 0)
                if distance <= AutoDribbleConfig.DribbleActivationDistance then
                    color = Color3.fromRGB(0, 255, 0)
                elseif distance <= AutoDribbleConfig.MaxDribbleDistance then
                    color = Color3.fromRGB(255, 165, 0)
                end
                Update3DCircle(circle, targetRoot.Position - Vector3.new(0, 0.5, 0), 2, color)
            end
        end
    end
    for player, circle in pairs(AutoTackleStatus.TargetCircles) do
        if not currentPlayers[player] then Hide3DCircle(circle) end
    end
end

-- === ПЕРЕМЕЩЕНИЕ DEBUG ТЕКСТА ===
local function SetupDebugMovement()
    if not DebugConfig.MoveEnabled or not Gui then return end
    local isDragging = false; local dragStart = Vector2.new(0, 0)
    local startPositions = {}
    for _, label in ipairs(Gui.TackleDebugLabels) do startPositions[label] = label.Position end
    for _, label in ipairs(Gui.DribbleDebugLabels) do startPositions[label] = label.Position end
    local function updateAllPositions(delta)
        for label, startPos in pairs(startPositions) do
            if label.Visible then label.Position = startPos + delta end
        end
    end
    UserInputService.InputBegan:Connect(function(input, gp)
        if gp or not DebugConfig.MoveEnabled then return end
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            local mp = UserInputService:GetMouseLocation()
            for label, _ in pairs(startPositions) do
                if label.Visible then
                    local pos = label.Position; local tb = Vector2.new(label.TextBounds.X, label.TextBounds.Y)
                    if mp.X >= pos.X - tb.X/2 and mp.X <= pos.X + tb.X/2 and
                        mp.Y >= pos.Y - tb.Y/2 and mp.Y <= pos.Y + tb.Y/2 then
                        isDragging = true; dragStart = mp; break
                    end
                end
            end
        end
    end)
    UserInputService.InputChanged:Connect(function(input, gp)
        if gp or not DebugConfig.MoveEnabled or not isDragging then return end
        if input.UserInputType == Enum.UserInputType.MouseMovement then
            updateAllPositions(UserInputService:GetMouseLocation() - dragStart)
        end
    end)
    UserInputService.InputEnded:Connect(function(input, gp)
        if gp or not DebugConfig.MoveEnabled then return end
        if input.UserInputType == Enum.UserInputType.MouseButton1 and isDragging then
            local delta = UserInputService:GetMouseLocation() - dragStart
            for label, startPos in pairs(startPositions) do startPositions[label] = startPos + delta end
            isDragging = false
        end
    end)
end

local function CheckIfTypingInChat()
    local success, result = pcall(function()
        local playerGui = LocalPlayer:WaitForChild("PlayerGui")
        for _, gui in pairs(playerGui:GetChildren()) do
            if gui:IsA("ScreenGui") and (gui.Name == "Chat" or gui.Name:find("Chat")) then
                local textBox = gui:FindFirstChild("TextBox", true)
                if textBox then return textBox:IsFocused() end
            end
        end
        return false
    end)
    return success and result or false
end

-- === ПРОВЕРКИ СОСТОЯНИЙ ===
local function IsDribbling(targetPlayer)
    if not targetPlayer or not targetPlayer.Character or not targetPlayer.Parent
        or targetPlayer.TeamColor == LocalPlayer.TeamColor then return false end
    local targetHumanoid = targetPlayer.Character:FindFirstChild("Humanoid")
    if not targetHumanoid then return false end
    local animator = targetHumanoid:FindFirstChild("Animator")
    if not animator then return false end
    for _, track in pairs(animator:GetPlayingAnimationTracks()) do
        if track.Animation and table.find(DribbleAnimIds, track.Animation.AnimationId) then return true end
    end
    return false
end

local function IsSpecificTackle(targetPlayer)
    if not targetPlayer or not targetPlayer.Character or not targetPlayer.Parent
        or targetPlayer.TeamColor == LocalPlayer.TeamColor then return false end
    local humanoid = targetPlayer.Character:FindFirstChild("Humanoid")
    if not humanoid then return false end
    local animator = humanoid:FindFirstChild("Animator")
    if not animator then return false end
    for _, track in pairs(animator:GetPlayingAnimationTracks()) do
        if track.Animation and track.Animation.AnimationId == SPECIFIC_TACKLE_ID then return true end
    end
    return false
end

local function IsPowerShooting(targetPlayer)
    if not targetPlayer then return false end
    local playerFolder = Workspace:FindFirstChild(targetPlayer.Name)
    if not playerFolder then return false end
    local bools = playerFolder:FindFirstChild("Bools")
    if not bools then return false end
    local powerShootingValue = bools:FindFirstChild("PowerShooting")
    return powerShootingValue and powerShootingValue.Value == true
end

-- === DRIBBLE STATES ===
local function UpdateDribbleStates()
    local currentTime = tick()
    for _, player in pairs(Players:GetPlayers()) do
        if player == LocalPlayer or not player.Parent or player.TeamColor == LocalPlayer.TeamColor then continue end
        if not DribbleStates[player] then
            DribbleStates[player] = { IsDribbling = false, LastDribbleEnd = 0, IsProcessingDelay = false, HadDribble = false }
        end
        local state = DribbleStates[player]
        local isDribblingNow = IsDribbling(player)
        if isDribblingNow and not state.IsDribbling then
            state.IsDribbling = true; state.IsProcessingDelay = false; state.HadDribble = true
        elseif not isDribblingNow and state.IsDribbling then
            state.IsDribbling = false; state.LastDribbleEnd = currentTime; state.IsProcessingDelay = true
        elseif state.IsProcessingDelay and not isDribblingNow then
            if currentTime - state.LastDribbleEnd >= AutoTackleConfig.DribbleDelayTime then
                DribbleCooldownList[player] = currentTime + 3.5
                state.IsProcessingDelay = false
            end
        end
    end
    local toRemove = {}
    for player, endTime in pairs(DribbleCooldownList) do
        if not player or not player.Parent or currentTime >= endTime then
            table.insert(toRemove, player)
        end
    end
    for _, player in ipairs(toRemove) do
        DribbleCooldownList[player] = nil
        EagleEyeTimers[player] = nil
    end
    if Gui and AutoTackleConfig.Enabled then
        local count = 0; for _ in pairs(DribbleCooldownList) do count += 1 end
        Gui.CooldownListLabel.Text = "CooldownList: " .. tostring(count)
    end
end

-- ============================================================
-- === PRECOMPUTE PLAYERS
-- [OPT] Один проход по Players, velocity через sqrMagnitude без sqrt
-- ============================================================
local function PrecomputePlayers()
    PrecomputedPlayers = {}
    HasBall = false; CanDribbleNow = false
    local ball = Workspace:FindFirstChild("ball")
    if ball and ball:FindFirstChild("playerWeld") and ball:FindFirstChild("creator") then
        HasBall = ball.creator.Value == LocalPlayer
    end
    local bools = Workspace:FindFirstChild(LocalPlayer.Name) and Workspace[LocalPlayer.Name]:FindFirstChild("Bools")
    if bools then
        CanDribbleNow = not bools.dribbleDebounce.Value
        if Gui and AutoDribbleConfig.Enabled then
            Gui.DribbleStatusLabel.Text = bools.dribbleDebounce.Value and "Dribble: Cooldown" or "Dribble: Ready"
            Gui.DribbleStatusLabel.Color = bools.dribbleDebounce.Value and Color3.fromRGB(255, 0, 0) or Color3.fromRGB(0, 255, 0)
        end
    end

    local myPos = HumanoidRootPart.Position
    local maxDistSq = AutoDribbleConfig.MaxDribbleDistance * AutoDribbleConfig.MaxDribbleDistance

    for _, player in pairs(Players:GetPlayers()) do
        if player == LocalPlayer or not player.Parent or player.TeamColor == LocalPlayer.TeamColor then continue end
        local character = player.Character
        if not character then continue end
        local humanoid = character:FindFirstChild("Humanoid")
        if not humanoid or humanoid.HipHeight >= 4 then continue end
        local targetRoot = character:FindFirstChild("HumanoidRootPart")
        if not targetRoot then continue end

        TackleStates[player] = TackleStates[player] or { IsTackling = false }
        TackleStates[player].IsTackling = IsSpecificTackle(player)

        local diff = targetRoot.Position - myPos
        local distSq = diff.X * diff.X + diff.Y * diff.Y + diff.Z * diff.Z
        if distSq > maxDistSq then continue end

        local distance = math.sqrt(distSq)

        -- [OPT] Сравниваем sqrMagnitude ALV vs posVel без sqrt
        local alv = targetRoot.AssemblyLinearVelocity
        local posVel = GetPositionBasedVelocity(player)
        local alvSqMag = alv.X*alv.X + alv.Y*alv.Y + alv.Z*alv.Z
        local posVelSqMag = posVel.X*posVel.X + posVel.Y*posVel.Y + posVel.Z*posVel.Z
        local velocity = alvSqMag >= posVelSqMag and alv or posVel

        PrecomputedPlayers[player] = {
            Distance = distance,
            IsValid = true,
            IsTackling = TackleStates[player].IsTackling,
            RootPart = targetRoot,
            Velocity = velocity
        }
        RecordTargetPosition(targetRoot, player)
    end
end

-- === РОТАЦИЯ ===
local function RotateToTarget(targetPos)
    if AutoTackleConfig.RotationMethod == "None" then return end
    local myPos = HumanoidRootPart.Position
    local direction = Vector3.new(targetPos.X - myPos.X, 0, targetPos.Z - myPos.Z)
    if direction.Magnitude > 0.1 then
        HumanoidRootPart.CFrame = CFrame.new(myPos, myPos + direction)
    end
end

-- === ПРОВЕРКА УСЛОВИЙ ТАКЛА ===
local function CanTackle()
    local ball = Workspace:FindFirstChild("ball")
    if not ball or not ball.Parent then return false, nil, nil, nil end
    local hasOwner = ball:FindFirstChild("playerWeld") and ball:FindFirstChild("creator")
    local owner = hasOwner and ball.creator.Value or nil
    if AutoTackleConfig.OnlyPlayer and (not hasOwner or not owner or not owner.Parent) then return false, nil, nil, nil end
    local isEnemy = not owner or (owner and owner.TeamColor ~= LocalPlayer.TeamColor)
    if not isEnemy then return false, nil, nil, nil end
    if Workspace:FindFirstChild("Bools") and (Workspace.Bools.APG.Value == LocalPlayer or Workspace.Bools.HPG.Value == LocalPlayer) then
        return false, nil, nil, nil
    end
    local distance = (HumanoidRootPart.Position - ball.Position).Magnitude
    if distance > AutoTackleConfig.MaxDistance then return false, nil, nil, nil end
    if owner and owner.Character then
        local targetHumanoid = owner.Character:FindFirstChild("Humanoid")
        if targetHumanoid and targetHumanoid.HipHeight >= 4 then return false, nil, nil, nil end
    end
    local bools = Workspace:FindFirstChild(LocalPlayer.Name) and Workspace[LocalPlayer.Name]:FindFirstChild("Bools")
    if bools and (bools.TackleDebounce.Value or bools.Tackled.Value or (Character:FindFirstChild("Bools") and Character.Bools.Debounce.Value)) then
        return false, nil, nil, nil
    end
    return true, ball, distance, owner
end

-- === PERFORM TACKLE ===
local function PerformTackle(ball, owner)
    local bools = Workspace:FindFirstChild(LocalPlayer.Name) and Workspace[LocalPlayer.Name]:FindFirstChild("Bools")
    if not bools or bools.TackleDebounce.Value or bools.Tackled.Value or
        (Character:FindFirstChild("Bools") and Character.Bools.Debounce.Value) then return end
    local ownerRoot = owner and owner.Character and owner.Character:FindFirstChild("HumanoidRootPart")
    local predictedPos
    if ownerRoot and owner then
        predictedPos = PredictTargetPosition(ownerRoot, owner)
    else
        predictedPos = ball.Position
    end
    RotateToTarget(predictedPos)
    if ownerRoot then
        local ftiDist = (HumanoidRootPart.Position - ownerRoot.Position).Magnitude
        if ftiDist <= 10 then
            pcall(function() firetouchinterest(HumanoidRootPart, ownerRoot, 0) end)
            pcall(function() firetouchinterest(HumanoidRootPart, ownerRoot, 1) end)
        end
    end
    pcall(function() ActionRemote:FireServer("TackIe") end)
    local bodyVelocity = Instance.new("BodyVelocity")
    bodyVelocity.Parent = HumanoidRootPart
    bodyVelocity.Velocity = HumanoidRootPart.CFrame.LookVector * AutoTackleConfig.TackleSpeed
    bodyVelocity.MaxForce = Vector3.new(50000000, 0, 50000000)
    local tackleStartTime = tick()
    local tackleDuration = 0.65
    local rotateConnection
    if AutoTackleConfig.RotationMethod == "Always" and ownerRoot and owner then
        rotateConnection = RunService.Heartbeat:Connect(function()
            if tick() - tackleStartTime < tackleDuration then
                RotateToTarget(PredictTargetPosition(ownerRoot, owner))
            else
                rotateConnection:Disconnect()
            end
        end)
    end
    Debris:AddItem(bodyVelocity, tackleDuration)
    task.delay(tackleDuration, function()
        if rotateConnection then rotateConnection:Disconnect() end
    end)
    if owner and ball:FindFirstChild("playerWeld") then
        local dist = (HumanoidRootPart.Position - ball.Position).Magnitude
        pcall(function() SoftDisPlayerRemote:FireServer(owner, dist, false, ball.Size) end)
    end
end

-- === MANUAL TACKLE ===
local function ManualTackleAction()
    local currentTime = tick()
    if currentTime - LastManualTackleTime < AutoTackleConfig.ManualTackleCooldown then return false end
    local canTackle, ball, distance, owner = CanTackle()
    if canTackle then
        LastManualTackleTime = currentTime
        PerformTackle(ball, owner)
        if Gui and AutoTackleConfig.Enabled then
            Gui.ManualTackleLabel.Text = "ManualTackle: EXECUTED! [" .. tostring(AutoTackleConfig.ManualTackleKeybind) .. "]"
            Gui.ManualTackleLabel.Color = Color3.fromRGB(0, 255, 0)
        end
        task.delay(0.3, function()
            if Gui and AutoTackleConfig.Enabled then Gui.ManualTackleLabel.Color = Color3.fromRGB(255, 255, 255) end
        end)
        return true
    else
        if Gui and AutoTackleConfig.Enabled then
            Gui.ManualTackleLabel.Text = "ManualTackle: FAILED [" .. tostring(AutoTackleConfig.ManualTackleKeybind) .. "]"
            Gui.ManualTackleLabel.Color = Color3.fromRGB(255, 0, 0)
        end
        task.delay(0.3, function()
            if Gui and AutoTackleConfig.Enabled then Gui.ManualTackleLabel.Color = Color3.fromRGB(255, 255, 255) end
        end)
        return false
    end
end

-- ==========================================================
-- === AUTOTACKLE MODULE
-- ==========================================================
local AutoTackle = {}
AutoTackle.Start = function()
    if AutoTackleStatus.Running then return end
    AutoTackleStatus.Running = true
    if not Gui then SetupGUI() end

    AutoTackleStatus.HeartbeatConnection = RunService.Heartbeat:Connect(function()
        pcall(UpdatePing)
        pcall(UpdateDribbleStates)
        pcall(PrecomputePlayers)
        pcall(UpdateTargetCircles)
        IsTypingInChat = CheckIfTypingInChat()
    end)

    -- ПК fallback: InputBegan ловит клавиатуру
    -- Мобиль: MacLib Keybind вызывает ManualTackleAction через Callback
    AutoTackleStatus.InputConnection = UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if gameProcessed or not AutoTackleConfig.Enabled or not AutoTackleConfig.ManualTackleEnabled then return end
        if IsTypingInChat then return end
        if input.KeyCode == AutoTackleConfig.ManualTackleKeybind then ManualTackleAction() end
    end)

    AutoTackleStatus.Connection = RunService.Heartbeat:Connect(function()
        if not AutoTackleConfig.Enabled then CleanupDebugText(); UpdateDebugVisibility(); return end
        pcall(function()
            local canTackle, ball, distance, owner = CanTackle()
            if not canTackle or not ball then
                if Gui then
                    Gui.TackleTargetLabel.Text = "Target: None"
                    Gui.TackleDribblingLabel.Text = "isDribbling: false"
                    Gui.TackleTacklingLabel.Text = "isTackling: false"
                    Gui.TackleWaitLabel.Text = "Wait: 0.00"
                    Gui.EagleEyeLabel.Text = "EagleEye: Idle"
                    if AutoTackleConfig.Mode == "ManualTackle" then
                        Gui.ManualTackleLabel.Text = "ManualTackle: NO TARGET [" .. tostring(AutoTackleConfig.ManualTackleKeybind) .. "]"
                        Gui.ManualTackleLabel.Color = Color3.fromRGB(255, 0, 0)
                    end
                end
                CurrentTargetOwner = nil
                return
            end
            if Gui then
                Gui.TackleTargetLabel.Text = "Target: " .. (owner and owner.Name or "None")
                Gui.TackleDribblingLabel.Text = "isDribbling: " .. tostring(owner and DribbleStates[owner] and DribbleStates[owner].IsDribbling or false)
                Gui.TackleTacklingLabel.Text = "isTackling: " .. tostring(owner and IsSpecificTackle(owner) or false)
                Gui.PingLabel.Text = string.format("Ping: %dms", math.round(AutoTackleStatus.Ping * 1000))
            end
            if owner then
                local ownerRootLive = owner.Character and owner.Character:FindFirstChild("HumanoidRootPart")
                UpdatePredictionLabel(ownerRootLive, owner)
            end
            if distance <= AutoTackleConfig.TackleDistance then
                PerformTackle(ball, owner)
                if Gui then Gui.EagleEyeLabel.Text = "Instant Tackle" end
                return
            end
            if owner and IsPowerShooting(owner) then
                PerformTackle(ball, owner)
                if Gui then Gui.EagleEyeLabel.Text = "PowerShooting: Tackling!" end
                return
            end
            CurrentTargetOwner = owner
            if AutoTackleConfig.Mode == "ManualTackle" then
                if Gui then
                    Gui.EagleEyeLabel.Text = "ManualTackle: Ready"
                    Gui.ManualTackleLabel.Text = "ManualTackle: READY [" .. tostring(AutoTackleConfig.ManualTackleKeybind) .. "]"
                    Gui.ManualTackleLabel.Color = Color3.fromRGB(0, 255, 0)
                end
                return
            end
            if not owner then return end
            local state = DribbleStates[owner] or { IsDribbling = false, LastDribbleEnd = 0, IsProcessingDelay = false, HadDribble = false }
            local isDribbling = state.IsDribbling
            local inCooldownList = DribbleCooldownList[owner] ~= nil
            if AutoTackleConfig.Mode == "OnlyDribble" then
                if inCooldownList then
                    PerformTackle(ball, owner)
                    if Gui then Gui.EagleEyeLabel.Text = "OnlyDribble: Tackling!" end
                elseif isDribbling then
                    if Gui then
                        Gui.EagleEyeLabel.Text = "OnlyDribble: Dribbling..."
                        Gui.TackleWaitLabel.Text = string.format("DDelay: %.2f", AutoTackleConfig.DribbleDelayTime)
                    end
                elseif state.IsProcessingDelay then
                    local remaining = AutoTackleConfig.DribbleDelayTime - (tick() - state.LastDribbleEnd)
                    if Gui then
                        Gui.EagleEyeLabel.Text = "OnlyDribble: DribDelay"
                        Gui.TackleWaitLabel.Text = string.format("Wait: %.2f", remaining)
                    end
                else
                    if Gui then
                        Gui.EagleEyeLabel.Text = "OnlyDribble: Waiting dribble"
                        Gui.TackleWaitLabel.Text = "Wait: -"
                    end
                end
            elseif AutoTackleConfig.Mode == "EagleEye" then
                local currentTime = tick()
                if isDribbling then
                    EagleEyeTimers[owner] = nil
                    if Gui then
                        Gui.TackleWaitLabel.Text = "Wait: DRIBBLE"
                        Gui.EagleEyeLabel.Text = "EagleEye: Dribbling (reset)"
                    end
                elseif state.IsProcessingDelay then
                    EagleEyeTimers[owner] = nil
                    local remaining = AutoTackleConfig.DribbleDelayTime - (currentTime - state.LastDribbleEnd)
                    if Gui then
                        Gui.TackleWaitLabel.Text = string.format("DDelay: %.2f", remaining)
                        Gui.EagleEyeLabel.Text = "EagleEye: DribbleDelay"
                    end
                elseif inCooldownList then
                    PerformTackle(ball, owner)
                    EagleEyeTimers[owner] = nil
                    if Gui then Gui.EagleEyeLabel.Text = "EagleEye: Post-Dribble Tackle!" end
                else
                    if not EagleEyeTimers[owner] then
                        local waitTime = AutoTackleConfig.EagleEyeMinDelay +
                            math.random() * (AutoTackleConfig.EagleEyeMaxDelay - AutoTackleConfig.EagleEyeMinDelay)
                        EagleEyeTimers[owner] = { startTime = currentTime, waitTime = waitTime }
                    end
                    local timer = EagleEyeTimers[owner]
                    local elapsed = currentTime - timer.startTime
                    if elapsed >= timer.waitTime then
                        PerformTackle(ball, owner)
                        EagleEyeTimers[owner] = nil
                        if Gui then Gui.EagleEyeLabel.Text = "EagleEye: Tackling!" end
                    else
                        if Gui then
                            Gui.TackleWaitLabel.Text = string.format("Wait: %.2f", timer.waitTime - elapsed)
                            Gui.EagleEyeLabel.Text = "EagleEye: Waiting"
                        end
                    end
                end
            end
        end)
    end)

    if DebugConfig.MoveEnabled then SetupDebugMovement() end
    UpdateDebugVisibility()
    if notify then notify("AutoTackle", "Started", true) end
end

AutoTackle.Stop = function()
    if AutoTackleStatus.Connection then AutoTackleStatus.Connection:Disconnect(); AutoTackleStatus.Connection = nil end
    if AutoTackleStatus.HeartbeatConnection then AutoTackleStatus.HeartbeatConnection:Disconnect(); AutoTackleStatus.HeartbeatConnection = nil end
    if AutoTackleStatus.InputConnection then AutoTackleStatus.InputConnection:Disconnect(); AutoTackleStatus.InputConnection = nil end
    AutoTackleStatus.Running = false
    CleanupDebugText(); UpdateDebugVisibility()
    for player, circle in pairs(AutoTackleStatus.TargetCircles) do
        for _, line in ipairs(circle) do line:Remove() end
    end
    AutoTackleStatus.TargetCircles = {}
    if notify then notify("AutoTackle", "Stopped", true) end
end

-- ==========================================================
-- === AUTODRIBBLE MODULE — v3.6
-- ==========================================================

-- [OPT] Кэш косинус-порога: инвалидируется только через флаг _angleDirty
local _cachedAngleDeg = -1
local _cachedCosThresh = 0
local _angleDirty = true

local function GetCosThreshold()
    if _angleDirty then
        _cachedAngleDeg = AutoDribbleConfig.MinAngleForDribble
        _cachedCosThresh = math.cos(math.rad(_cachedAngleDeg))
        _angleDirty = false
    end
    return _cachedCosThresh
end

-- ============================================================
-- ShouldDribbleNow v3.6
--
-- ГЛАВНЫЕ ИСПРАВЛЕНИЯ ЛОЖНЫХ СРАБАТЫВАНИЙ:
--
-- [FIX 1] Стадия 0 (point blank < 4 studs):
--   БЫЛО: return true всегда — реагировало на любого рядом стоящего
--   СТАЛО: return true только если у врага IsTackling=true ИЛИ
--          он движется прямо на нас (dot > 0.70) — тихо стоящий/проходящий мимо
--          игрок больше НЕ тригерит deke.
--
-- [FIX 2] Стадия 1 (DribbleActivationDistance):
--   БЫЛО: fallback без IsTackling: if dot > 0.55 → return true
--         Это срабатывало на любого бегущего в нашу сторону!
--   СТАЛО: fallback ТРЕБУЕТ IsTackling=true. Без анимации такла — deke
--          не выполняется вне зависимости от скорости и угла.
--          Исключение: если скорость врага > SPRINT_THRESHOLD (≈16 studs/s —
--          типичный спринт с мячом) И dot > 0.85 (почти прямо на нас) —
--          это явно атака, реагируем. Обычный бег мимо (dot < 0.85) — нет.
--
-- [FIX 3] Fallback-ветка в AutoDribble.Start (без IsTackling):
--   БЫЛО: любой движущийся враг (flatVel >= 1.5) в зоне → target
--   СТАЛО: fallback-ветка ПОЛНОСТЬЮ УДАЛЕНА. Скрипт реагирует ТОЛЬКО
--          на игроков с подтверждённой анимацией такла (IsTackling=true).
--          Это устраняет основной источник ложных срабатываний.
--
-- [OPT] Угол: acos вызывается ТОЛЬКО в Debug-label (DebugConfig.Enabled).
--       В боевом режиме используется только dot ≥ cosThresh — без тригонометрии.
-- [OPT] distFlat считается через sqrtf от плоских координат (Y=0 уже обнулён).
-- ============================================================

local SPRINT_THRESHOLD = 16.0   -- studs/s — порог спринта для fallback в стадии 1
local POINTBLANK_DOT = 0.70     -- cos(~46°) — "прямо на нас" для point-blank
local HARDCHASE_DOT = 0.85      -- cos(~32°) — "явная атака" для fallback без такла

local function ShouldDribbleNow(specificTarget, tacklerData)
    if not specificTarget or not tacklerData then return false end

    local tacklerRoot = tacklerData.RootPart
    if not tacklerRoot then return false end

    local serverCF = GetMyServerCFrame()
    -- Плоские координаты — Y всегда 0
    local myServerX = serverCF.Position.X
    local myServerZ = serverCF.Position.Z

    -- [OPT] Прогнозная позиция таклера (ping-компенсация)
    local histVel = GetPositionBasedVelocity(specificTarget)
    local pingOfs = AutoTackleStatus.Ping * 1.5
    local predX = tacklerRoot.Position.X + histVel.X * pingOfs
    local predZ = tacklerRoot.Position.Z + histVel.Z * pingOfs

    local toMeX = myServerX - predX
    local toMeZ = myServerZ - predZ
    local distFlatSq = toMeX * toMeX + toMeZ * toMeZ

    -- Ранний выход без sqrt
    local maxDistSq = AutoDribbleConfig.MaxDribbleDistance * AutoDribbleConfig.MaxDribbleDistance
    if distFlatSq > maxDistSq then
        if Gui and DebugConfig.Enabled and AutoDribbleConfig.Enabled then
            Gui.AngleLabel.Text = string.format("FAR d=%.1f", math.sqrt(distFlatSq))
        end
        return false
    end

    local distFlat = math.sqrt(distFlatSq)
    local isTackling = tacklerData.IsTackling

    -- [СТАДИЯ 0] Point blank < 4 studs
    -- [FIX 1] Требуем IsTackling ИЛИ явный налёт (dot > POINTBLANK_DOT)
    if distFlat < 4 then
        if isTackling then
            if Gui and DebugConfig.Enabled and AutoDribbleConfig.Enabled then
                Gui.AngleLabel.Text = string.format("⚡ TACKLE CLOSE d=%.1f", distFlat)
            end
            return true
        end
        -- Проверяем летит ли прямо на нас
        local vx = histVel.X; local vz = histVel.Z
        local vMagSq = vx*vx + vz*vz
        if vMagSq > 0.25 then  -- speed > 0.5
            local vMag = math.sqrt(vMagSq)
            local toMeLen = distFlat > 0.001 and distFlat or 0.001
            local dot = (vx * toMeX + vz * toMeZ) / (vMag * toMeLen)
            if dot > POINTBLANK_DOT then
                if Gui and DebugConfig.Enabled and AutoDribbleConfig.Enabled then
                    Gui.AngleLabel.Text = string.format("⚡ RUSH d=%.1f dot=%.2f", distFlat, dot)
                end
                return true
            end
        end
        if Gui and DebugConfig.Enabled and AutoDribbleConfig.Enabled then
            Gui.AngleLabel.Text = string.format("NEAR(no tackle) d=%.1f", distFlat)
        end
        return false
    end

    -- [СТАДИЯ 1] Зона активации
    -- [FIX 2] Без IsTackling реагируем только на явный спринт-налёт
    if distFlat <= AutoDribbleConfig.DribbleActivationDistance then
        if isTackling then
            if Gui and DebugConfig.Enabled and AutoDribbleConfig.Enabled then
                Gui.AngleLabel.Text = string.format("⚡ TACKLE ACT d=%.1f", distFlat)
            end
            return true
        end
        -- Fallback: спринт + прямой курс
        local vx = histVel.X; local vz = histVel.Z
        local vMagSq = vx*vx + vz*vz
        if vMagSq >= SPRINT_THRESHOLD * SPRINT_THRESHOLD then
            local vMag = math.sqrt(vMagSq)
            local toMeLen = distFlat > 0.001 and distFlat or 0.001
            local dot = (vx * toMeX + vz * toMeZ) / (vMag * toMeLen)
            if dot > HARDCHASE_DOT then
                if Gui and DebugConfig.Enabled and AutoDribbleConfig.Enabled then
                    Gui.AngleLabel.Text = string.format("⚡ SPRINT RUSH d=%.1f dot=%.2f", distFlat, dot)
                end
                return true
            end
        end
        if Gui and DebugConfig.Enabled and AutoDribbleConfig.Enabled then
            Gui.AngleLabel.Text = string.format("ACT(no tackle) d=%.1f", distFlat)
        end
        return false
    end

    -- [СТАДИЯ 2] Средняя дистанция — ТОЛЬКО с IsTackling
    -- Без анимации такла на средней дистанции — однозначно нет
    if not isTackling then
        if Gui and DebugConfig.Enabled and AutoDribbleConfig.Enabled then
            Gui.AngleLabel.Text = string.format("MID no tackle d=%.1f", distFlat)
        end
        return false
    end

    local tacklerVelX = tacklerData.Velocity.X
    local tacklerVelZ = tacklerData.Velocity.Z
    local tacklerSpeedSq = tacklerVelX*tacklerVelX + tacklerVelZ*tacklerVelZ

    if tacklerSpeedSq < 2.25 then  -- speed < 1.5
        if Gui and DebugConfig.Enabled and AutoDribbleConfig.Enabled then
            Gui.AngleLabel.Text = string.format("v=%.1f (slow)", math.sqrt(tacklerSpeedSq))
        end
        return false
    end

    local tacklerSpeed = math.sqrt(tacklerSpeedSq)
    -- [OPT] dot без acos — сравниваем напрямую с cosThresh
    local toMeLen = distFlat > 0.001 and distFlat or 0.001
    local dot = (tacklerVelX * toMeX + tacklerVelZ * toMeZ) / (tacklerSpeed * toMeLen)
    local cosThresh = GetCosThreshold()

    if Gui and DebugConfig.Enabled and AutoDribbleConfig.Enabled then
        -- acos ТОЛЬКО здесь, только в debug
        local angleDeg = math.deg(math.acos(math.clamp(dot, -1, 1)))
        Gui.AngleLabel.Text = string.format("A=%.0f° v=%.1f d=%.1f", angleDeg, tacklerSpeed, distFlat)
    end

    if dot < cosThresh then
        return false
    end

    -- Время до столкновения (с учётом встречного движения)
    local myFlatVel = GetMyVelocityFromHistory()
    local myFlatX = myFlatVel.X; local myFlatZ = myFlatVel.Z
    local myFlatSpeedSq = myFlatX*myFlatX + myFlatZ*myFlatZ
    local myFlatSpeed = math.sqrt(myFlatSpeedSq)

    local myApproach = 0
    if myFlatSpeed > 0.1 then
        -- dot моей скорости к таклеру (приближаемся или нет)
        local myDirX = myFlatX / myFlatSpeed
        local myDirZ = myFlatZ / myFlatSpeed
        -- направление к таклеру = -toMe / distFlat
        myApproach = (myDirX * (-toMeX) + myDirZ * (-toMeZ)) / toMeLen
    end
    local relSpeed = tacklerSpeed + myFlatSpeed * math.max(myApproach, 0)
    local timeToCollision = distFlat / math.max(relSpeed, 1)

    if timeToCollision < 0.4 then
        if Gui and DebugConfig.Enabled and AutoDribbleConfig.Enabled then
            Gui.AngleLabel.Text = Gui.AngleLabel.Text .. string.format(" t=%.2f", timeToCollision)
        end
        return true
    end

    return false
end

local function PerformDribble()
    local currentTime = tick()
    if currentTime - AutoDribbleStatus.LastDribbleTime < 0.02 then return end
    local bools = Workspace:FindFirstChild(LocalPlayer.Name) and Workspace[LocalPlayer.Name]:FindFirstChild("Bools")
    if not bools or bools.dribbleDebounce.Value then return end
    pcall(function() ActionRemote:FireServer("Deke") end)
    AutoDribbleStatus.LastDribbleTime = currentTime
    if Gui and AutoDribbleConfig.Enabled then
        Gui.DribbleStatusLabel.Text = "Dribble: Cooldown"
        Gui.DribbleStatusLabel.Color = Color3.fromRGB(255, 0, 0)
        Gui.AutoDribbleLabel.Text = "AutoDribble: DEKE!"
    end
end

local AutoDribble = {}
AutoDribble.Start = function()
    if AutoDribbleStatus.Running then return end
    AutoDribbleStatus.Running = true

    AutoDribbleStatus.HeartbeatConnection = RunService.Heartbeat:Connect(function()
        if not AutoDribbleConfig.Enabled then return end
        pcall(function()
            UpdatePing()
            UpdateDribbleStates()
            PrecomputePlayers()
            UpdateTargetCircles()
            RecordMyPosition()
            IsTypingInChat = CheckIfTypingInChat()
            UpdateServerPosBox()
        end)
    end)

    if not Gui then SetupGUI() end

    AutoDribbleStatus.Connection = RunService.Heartbeat:Connect(function()
        if not AutoDribbleConfig.Enabled then CleanupDebugText(); UpdateDebugVisibility(); return end

        if not HasBall or not CanDribbleNow then
            if Gui then Gui.AutoDribbleLabel.Text = "AutoDribble: Idle" end
            return
        end

        -- [FIX 3] Реагируем ТОЛЬКО на игроков с подтверждённым IsTackling
        -- Fallback-ветка (любой движущийся враг) — УДАЛЕНА полностью
        local specificTarget, minDist, targetCount, nearestTacklerData = nil, math.huge, 0, nil
        for player, data in pairs(PrecomputedPlayers) do
            if data.IsValid and data.IsTackling then
                targetCount += 1
                if data.Distance < minDist then
                    minDist = data.Distance
                    specificTarget = player
                    nearestTacklerData = data
                end
            end
        end

        if Gui then
            Gui.DribbleTargetLabel.Text = "Targets: " .. targetCount
            Gui.DribbleTacklingLabel.Text = specificTarget
                and string.format("Tackle: %.1f", minDist)
                or "Tackle: None"
        end

        if not specificTarget or not nearestTacklerData then
            if Gui then Gui.AutoDribbleLabel.Text = "AutoDribble: Idle" end
            return
        end

        if ShouldDribbleNow(specificTarget, nearestTacklerData) then
            PerformDribble()
        else
            if Gui then Gui.AutoDribbleLabel.Text = "AutoDribble: Waiting" end
        end
    end)

    UpdateDebugVisibility()
    if notify then notify("AutoDribble", "Started", true) end
end

AutoDribble.Stop = function()
    if AutoDribbleStatus.Connection then AutoDribbleStatus.Connection:Disconnect(); AutoDribbleStatus.Connection = nil end
    if AutoDribbleStatus.HeartbeatConnection then AutoDribbleStatus.HeartbeatConnection:Disconnect(); AutoDribbleStatus.HeartbeatConnection = nil end
    AutoDribbleStatus.Running = false
    if Gui and Gui.ServerPosBoxLines then HideBoxLines(Gui.ServerPosBoxLines) end
    CleanupDebugText(); UpdateDebugVisibility()
    if notify then notify("AutoDribble", "Stopped", true) end
end

-- ==========================================================
-- === UI ===
-- ==========================================================
local uiElements = {}
local function SetupUI(UI)
    if UI.Sections.AutoTackle then
        UI.Sections.AutoTackle:Header({ Name = "AutoTackle" })
        UI.Sections.AutoTackle:Divider()
        uiElements.AutoTackleEnabled = UI.Sections.AutoTackle:Toggle({
            Name = "Enabled", Default = AutoTackleConfig.Enabled,
            Callback = function(v)
                AutoTackleConfig.Enabled = v
                if v then AutoTackle.Start() else AutoTackle.Stop() end
                UpdateDebugVisibility()
            end
        }, "AutoTackleEnabled")
        uiElements.AutoTackleMode = UI.Sections.AutoTackle:Dropdown({
            Name = "Mode", Default = AutoTackleConfig.Mode,
            Options = {"OnlyDribble", "EagleEye", "ManualTackle"},
            Callback = function(v)
                AutoTackleConfig.Mode = v
                if Gui then Gui.ModeLabel.Text = "Mode: " .. v end
            end
        }, "AutoTackleMode")
        UI.Sections.AutoTackle:Divider()
        uiElements.AutoTackleMaxDistance = UI.Sections.AutoTackle:Slider({
            Name = "Max Distance", Minimum = 5, Maximum = 50,
            Default = AutoTackleConfig.MaxDistance, Precision = 1,
            Callback = function(v) AutoTackleConfig.MaxDistance = v end
        }, "AutoTackleMaxDistance")
        uiElements.AutoTackleTackleDistance = UI.Sections.AutoTackle:Slider({
            Name = "Instant Tackle Distance", Minimum = 0, Maximum = 20,
            Default = AutoTackleConfig.TackleDistance, Precision = 1,
            Callback = function(v) AutoTackleConfig.TackleDistance = v end
        }, "AutoTackleTackleDistance")
        uiElements.AutoTackleTackleSpeed = UI.Sections.AutoTackle:Slider({
            Name = "Tackle Speed", Minimum = 10, Maximum = 100,
            Default = AutoTackleConfig.TackleSpeed, Precision = 1,
            Callback = function(v) AutoTackleConfig.TackleSpeed = v end
        }, "AutoTackleTackleSpeed")
        UI.Sections.AutoTackle:Divider()
        uiElements.AutoTackleOnlyPlayer = UI.Sections.AutoTackle:Toggle({
            Name = "Only Player", Default = AutoTackleConfig.OnlyPlayer,
            Callback = function(v) AutoTackleConfig.OnlyPlayer = v end
        }, "AutoTackleOnlyPlayer")
        uiElements.AutoTackleRotationMethod = UI.Sections.AutoTackle:Dropdown({
            Name = "Rotation Method", Default = AutoTackleConfig.RotationMethod,
            Options = {"Snap", "Always", "None"},
            Callback = function(v) AutoTackleConfig.RotationMethod = v end
        }, "AutoTackleRotationMethod")
        UI.Sections.AutoTackle:Divider()
        uiElements.AutoTackleDribbleDelay = UI.Sections.AutoTackle:Slider({
            Name = "Dribble Delay", Minimum = 0.0, Maximum = 2.0,
            Default = AutoTackleConfig.DribbleDelayTime, Precision = 2,
            Callback = function(v) AutoTackleConfig.DribbleDelayTime = v end
        }, "AutoTackleDribbleDelay")
        uiElements.AutoTackleEagleEyeMinDelay = UI.Sections.AutoTackle:Slider({
            Name = "EagleEye Min Delay", Minimum = 0.0, Maximum = 2.0,
            Default = AutoTackleConfig.EagleEyeMinDelay, Precision = 2,
            Callback = function(v) AutoTackleConfig.EagleEyeMinDelay = v end
        }, "AutoTackleEagleEyeMinDelay")
        uiElements.AutoTackleEagleEyeMaxDelay = UI.Sections.AutoTackle:Slider({
            Name = "EagleEye Max Delay", Minimum = 0.0, Maximum = 2.0,
            Default = AutoTackleConfig.EagleEyeMaxDelay, Precision = 2,
            Callback = function(v) AutoTackleConfig.EagleEyeMaxDelay = v end
        }, "AutoTackleEagleEyeMaxDelay")
        UI.Sections.AutoTackle:Divider()
        uiElements.AutoTackleManualTackleEnabled = UI.Sections.AutoTackle:Toggle({
            Name = "Manual Tackle Enabled", Default = AutoTackleConfig.ManualTackleEnabled,
            Callback = function(v) AutoTackleConfig.ManualTackleEnabled = v end
        }, "AutoTackleManualTackleEnabled")
        -- MacLib Keybind: ПК — InputBegan, Мобиль — FAB-кнопка через Callback
        uiElements.AutoTackleManualTackleKeybind = UI.Sections.AutoTackle:Keybind({
            Name = "Manual Tackle Key",
            Default = AutoTackleConfig.ManualTackleKeybind,
            Callback = function(v)
                if not AutoTackleConfig.Enabled or not AutoTackleConfig.ManualTackleEnabled then return end
                ManualTackleAction()
            end,
            onBinded = function(v)
                AutoTackleConfig.ManualTackleKeybind = v
            end
        }, "AutoTackleManualTackleKeybind")
    end

    if UI.Sections.AutoDribble then
        UI.Sections.AutoDribble:Header({ Name = "AutoDribble" })
        UI.Sections.AutoDribble:Divider()
        uiElements.AutoDribbleEnabled = UI.Sections.AutoDribble:Toggle({
            Name = "Enabled", Default = AutoDribbleConfig.Enabled,
            Callback = function(v)
                AutoDribbleConfig.Enabled = v
                if v then AutoDribble.Start() else AutoDribble.Stop() end
                UpdateDebugVisibility()
            end
        }, "AutoDribbleEnabled")
        UI.Sections.AutoDribble:Divider()
        uiElements.AutoDribbleMaxDistance = UI.Sections.AutoDribble:Slider({
            Name = "Max Distance", Minimum = 10, Maximum = 50,
            Default = AutoDribbleConfig.MaxDribbleDistance, Precision = 1,
            Callback = function(v) AutoDribbleConfig.MaxDribbleDistance = v end
        }, "AutoDribbleMaxDistance")
        uiElements.AutoDribbleActivationDistance = UI.Sections.AutoDribble:Slider({
            Name = "Activation Distance", Minimum = 5, Maximum = 30,
            Default = AutoDribbleConfig.DribbleActivationDistance, Precision = 1,
            Callback = function(v) AutoDribbleConfig.DribbleActivationDistance = v end
        }, "AutoDribbleActivationDistance")
        uiElements.AutoDribbleMinAngle = UI.Sections.AutoDribble:Slider({
            Name = "Max Attack Angle", Minimum = 10, Maximum = 90,
            Default = AutoDribbleConfig.MinAngleForDribble, Precision = 0,
            Callback = function(v)
                AutoDribbleConfig.MinAngleForDribble = v
                _angleDirty = true
            end
        }, "AutoDribbleMinAngle")
        uiElements.AutoDribbleShowServerPos = UI.Sections.AutoDribble:Toggle({
            Name = "Show Server Position Box", Default = AutoDribbleConfig.ShowServerPos,
            Callback = function(v)
                AutoDribbleConfig.ShowServerPos = v
                if not v and Gui and Gui.ServerPosBoxLines then
                    HideBoxLines(Gui.ServerPosBoxLines)
                end
                UpdateDebugVisibility()
            end
        }, "AutoDribbleShowServerPos")
        UI.Sections.AutoDribble:Divider()
    end

    if UI.Sections.Debug then
        UI.Sections.Debug:Header({ Name = "Debug" })
        UI.Sections.Debug:SubLabel({ Text = "* Only for AutoDribble/AutoTackle" })
        UI.Sections.Debug:Divider()
        uiElements.DebugEnabled = UI.Sections.Debug:Toggle({
            Name = "Debug Text", Default = DebugConfig.Enabled,
            Callback = function(v) DebugConfig.Enabled = v; UpdateDebugVisibility() end
        }, "DebugEnabled")
        uiElements.DebugMoveEnabled = UI.Sections.Debug:Toggle({
            Name = "Move Debug Text", Default = DebugConfig.MoveEnabled,
            Callback = function(v)
                DebugConfig.MoveEnabled = v
                if v then SetupDebugMovement() end
            end
        }, "DebugMoveEnabled")
    end
end

-- === СИНХРОНИЗАЦИЯ ===
local function SynchronizeConfigValues()
    if not uiElements then return end
    local pairs_sync = {
        { uiElements.AutoTackleMaxDistance, function(v) AutoTackleConfig.MaxDistance = v end },
        { uiElements.AutoTackleTackleDistance, function(v) AutoTackleConfig.TackleDistance = v end },
        { uiElements.AutoTackleTackleSpeed, function(v) AutoTackleConfig.TackleSpeed = v end },
        { uiElements.AutoTackleDribbleDelay, function(v) AutoTackleConfig.DribbleDelayTime = v end },
        { uiElements.AutoTackleEagleEyeMinDelay, function(v) AutoTackleConfig.EagleEyeMinDelay = v end },
        { uiElements.AutoTackleEagleEyeMaxDelay, function(v) AutoTackleConfig.EagleEyeMaxDelay = v end },
        { uiElements.AutoDribbleMaxDistance, function(v) AutoDribbleConfig.MaxDribbleDistance = v end },
        { uiElements.AutoDribbleActivationDistance, function(v) AutoDribbleConfig.DribbleActivationDistance = v end },
        { uiElements.AutoDribbleMinAngle, function(v) AutoDribbleConfig.MinAngleForDribble = v; _angleDirty = true end },
    }
    for _, pair in ipairs(pairs_sync) do
        local elem, setter = pair[1], pair[2]
        if elem and elem.GetValue then pcall(function() setter(elem:GetValue()) end) end
    end
end

-- === МОДУЛЬ ===
local AutoDribbleTackleModule = {}
function AutoDribbleTackleModule.Init(UI, coreParam, notifyFunc)
    core = coreParam
    Services = core.Services
    PlayerData = core.PlayerData
    notify = notifyFunc
    LocalPlayerObj = PlayerData.LocalPlayer

    SetupUI(UI)

    local synchronizationTimer = 0
    RunService.Heartbeat:Connect(function(deltaTime)
        synchronizationTimer += deltaTime
        if synchronizationTimer >= 1.0 then
            synchronizationTimer = 0
            SynchronizeConfigValues()
        end
    end)

    LocalPlayerObj.CharacterAdded:Connect(function(newChar)
        task.wait(1)
        Character = newChar
        Humanoid = newChar:WaitForChild("Humanoid")
        HumanoidRootPart = newChar:WaitForChild("HumanoidRootPart")
        DribbleStates = {}; TackleStates = {}; PrecomputedPlayers = {}
        DribbleCooldownList = {}; EagleEyeTimers = {}
        AutoTackleStatus.TargetPositionHistory = {}
        AutoTackleStatus.TargetCircles = {}
        MyPositionHistory = {}
        _angleDirty = true
        CurrentTargetOwner = nil
        if AutoTackleConfig.Enabled and not AutoTackleStatus.Running then AutoTackle.Start() end
        if AutoDribbleConfig.Enabled and not AutoDribbleStatus.Running then AutoDribble.Start() end
    end)
end

function AutoDribbleTackleModule:Destroy()
    AutoTackle.Stop()
    AutoDribble.Stop()
    if Gui then
        if Gui.ServerPosBoxLines then RemoveBoxLines(Gui.ServerPosBoxLines) end
    end
end

return AutoDribbleTackleModule
