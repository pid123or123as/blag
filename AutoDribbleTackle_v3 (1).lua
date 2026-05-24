-- [v3.8] AUTO DRIBBLE + AUTO TACKLE
-- Changelog v3.8:
-- - FastCycle УДАЛЁН: task.desynchronize несовместим без Actor архитектурно
-- - Оптимизация: локализация math/Vector3/table функций как upvalue (горячие пути)
-- - Оптимизация: компонентная Vector3 арифметика на hot path (без __add метаметода)
-- - Оптимизация: dirty-flag кэш расширен — RECALC_INTERVAL снижен до 0.008 (120fps)
--   + позиционный порог снижен до 0.15 studs для Strict
-- - Strict режим: исправлена логика — добавлена TTC проверка во всех стадиях,
--   угловая проверка работает только когда скорость > 2.0 (убраны ложные срабатывания
--   при медленном движении), короткое окно TTC (< 0.25s) для строгой реакции
-- - Box: offsetY теперь корректно рассчитывается через HipHeight + HRP.Size.Y/2,
--   нижняя грань бокса совпадает с позицией ступней (LeftFoot/RightFoot)
--   GetDynamicBoxOffset() читает реальный HipHeight персонажа
-- - Changelog v3.7 и ранее см. выше

-- ============================================================
-- === ЛОКАЛИЗАЦИЯ HOT-PATH ФУНКЦИЙ (upvalue оптимизация)
-- === Избегаем _ENV lookup на каждый кадр
-- ============================================================
local _mabs   = math.abs
local _mcos   = math.cos
local _mrad   = math.rad
local _mmax   = math.max
local _mmin   = math.min
local _mclamp = math.clamp
local _msqrt  = math.sqrt
local _mfloor = math.floor
local _tick   = tick
local _V3new  = Vector3.new
local _tinsert = table.insert
local _tremove = table.remove

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
        _tinsert(DribbleAnimIds, anim.AnimationId)
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
    RotationMethod = "Snap",  -- "Snap" | "Legit" | "Always" | "None"
    DribbleDelayTime = 0,
    EagleEyeMinDelay = 0.2,
    EagleEyeMaxDelay = 0.6,
    ManualTackleEnabled = true,
    ManualTackleKeybind = Enum.KeyCode.Q,
    ManualTackleCooldown = 0.5,
    ShowPredictionBox = false,
}

local AutoDribbleConfig = {
    Enabled = false,
    MaxDribbleDistance = 30,
    DribbleActivationDistance = 17,
    MinAngleForDribble = 32,
    ShowServerPos = false,
    DribbleMode = "Free",  -- "Strict" | "Free"
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
local HISTORY_SIZE   = 12
local HISTORY_WINDOW = 0.12

local function RecordTargetPosition(ownerRoot, player)
    local history = AutoTackleStatus.TargetPositionHistory[player]
    if not history then
        history = {}
        AutoTackleStatus.TargetPositionHistory[player] = history
    end
    local pos = ownerRoot.Position
    _tinsert(history, { time = _tick(), pos = pos })
    while #history > HISTORY_SIZE do _tremove(history, 1) end
end

-- v3.8: компонентная арифметика вместо Vector3 оператора /
local function GetPositionBasedVelocity(player)
    local history = AutoTackleStatus.TargetPositionHistory[player]
    if not history or #history < 2 then return Vector3.zero end
    local now = _tick()
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
    local invDt = 1 / dt
    local op, np = oldest.pos, newest.pos
    -- Компонентная арифметика: избегаем __sub и __div метаметоды Vector3
    return _V3new((np.X - op.X) * invDt, (np.Y - op.Y) * invDt, (np.Z - op.Z) * invDt)
end

local function CalcInterceptTime(fromPos, targetPos, vel, speed)
    local tx = targetPos.X - fromPos.X
    local tz = targetPos.Z - fromPos.Z
    local dist = _msqrt(tx*tx + tz*tz)
    if dist < 0.01 then return 0 end
    local vx, vz = vel.X, vel.Z
    local v2    = vx*vx + vz*vz
    local ts2   = speed * speed
    local dotDV = tx*vx + tz*vz
    local a = ts2 - v2
    local b = -2 * dotDV
    local c = -(dist * dist)
    local t
    if _mabs(a) < 0.001 then
        t = (_mabs(b) > 0.001) and (-c / b) or (dist / _mmax(speed, 1))
    else
        local disc = b * b - 4 * a * c
        if disc < 0 then
            t = dist / _mmax(speed, 1)
        else
            local sqrtD = _msqrt(disc)
            local t1 = (-b - sqrtD) / (2 * a)
            local t2 = (-b + sqrtD) / (2 * a)
            if t1 > 0 and t2 > 0 then t = _mmin(t1, t2)
            elseif t1 > 0 then t = t1
            elseif t2 > 0 then t = t2
            else t = dist / _mmax(speed, 1) end
        end
    end
    return _mclamp(t, 0.02, 0.5)
end

local function PredictTargetPosition(ownerRoot, player)
    if not ownerRoot then return ownerRoot.Position end
    local ping    = AutoTackleStatus.Ping
    local vel     = GetPositionBasedVelocity(player)
    local vx, vz  = vel.X, vel.Z
    local op = ownerRoot.Position
    local sx = op.X + vx * ping
    local sz = op.Z + vz * ping
    local myPos   = HumanoidRootPart.Position
    local myPos2D = _V3new(myPos.X, 0, myPos.Z)
    local target2D = _V3new(sx, 0, sz)
    local interceptT = CalcInterceptTime(myPos2D, target2D, _V3new(vx, 0, vz), AutoTackleConfig.TackleSpeed)
    return _V3new(sx + vx * interceptT, op.Y, sz + vz * interceptT)
end

local function UpdatePredictionLabel(ownerRoot, player)
    if not Gui or not DebugConfig.Enabled or not AutoTackleConfig.Enabled then return end
    if not ownerRoot or not player then
        Gui.PredictionLabel.Text = "Pred: no target"
        return
    end
    local ping    = AutoTackleStatus.Ping
    local vel     = GetPositionBasedVelocity(player)
    local vx, vz  = vel.X, vel.Z
    local op = ownerRoot.Position
    local sx = op.X + vx * ping
    local sz = op.Z + vz * ping
    local myPos = HumanoidRootPart.Position
    local dx = sx - myPos.X; local dz = sz - myPos.Z
    local dist = _msqrt(dx*dx + dz*dz)
    local interceptT = CalcInterceptTime(_V3new(myPos.X, 0, myPos.Z), _V3new(sx, 0, sz), _V3new(vx, 0, vz), AutoTackleConfig.TackleSpeed)
    Gui.PredictionLabel.Text = string.format(
        "p=%dms t=%dms v=%.0f d=%.0f",
        _mfloor(ping * 1000 + 0.5),
        _mfloor(interceptT * 1000 + 0.5),
        _msqrt(vx*vx + vz*vz),
        dist
    )
end

-- === ПИНГ UPDATE ===
local function UpdatePing()
    local currentTime = _tick()
    if currentTime - AutoTackleStatus.LastPingUpdate > 1 then
        AutoTackleStatus.Ping = GetPing()
        AutoTackleStatus.LastPingUpdate = currentTime
        if Gui and AutoTackleConfig.Enabled then
            Gui.PingLabel.Text = string.format("Ping: %dms", _mfloor(AutoTackleStatus.Ping * 1000 + 0.5))
        end
    end
end

-- ============================================================
-- === СЕРВЕРНАЯ ПОЗИЦИЯ (CFrame-based)
-- ============================================================
local MY_HISTORY_SIZE = 10
local MyPositionHistory = {}

local function RecordMyPosition()
    _tinsert(MyPositionHistory, {
        time   = _tick(),
        cframe = HumanoidRootPart.CFrame
    })
    while #MyPositionHistory > MY_HISTORY_SIZE do
        _tremove(MyPositionHistory, 1)
    end
end

local function GetMyVelocityFromHistory()
    if #MyPositionHistory < 2 then return Vector3.zero end
    local oldest = MyPositionHistory[1]
    local newest = MyPositionHistory[#MyPositionHistory]
    local dt = newest.time - oldest.time
    if dt < 0.001 then return Vector3.zero end
    local op = oldest.cframe.Position
    local np = newest.cframe.Position
    local invDt = 1 / dt
    return _V3new((np.X - op.X) * invDt, (np.Y - op.Y) * invDt, (np.Z - op.Z) * invDt)
end

local function GetMyServerCFrame()
    local networkDelay = AutoTackleStatus.Ping * 1.5
    local myVel   = GetMyVelocityFromHistory()
    local hrpPos  = HumanoidRootPart.Position
    local serverPos = _V3new(
        hrpPos.X - myVel.X * networkDelay,
        hrpPos.Y - myVel.Y * networkDelay,
        hrpPos.Z - myVel.Z * networkDelay
    )
    return CFrame.new(serverPos) * (HumanoidRootPart.CFrame - HumanoidRootPart.CFrame.Position)
end

-- ============================================================
-- === 3D BOX
-- v3.8: динамический расчёт offsetY через HipHeight + HRP.Size.Y/2
-- Нижняя грань box = уровень ступней (LeftFoot/RightFoot)
-- BOX_W/BOX_D = 3.6 (R15 с плечами и ногами)
-- ============================================================
local BOX_W, BOX_H, BOX_D = 3.6, 5.5, 3.6
local BOX_EDGES = {
    {1,2},{2,3},{3,4},{4,1},
    {5,6},{6,7},{7,8},{8,5},
    {1,5},{2,6},{3,7},{4,8},
}

-- v3.8: рассчитываем правильный offsetY для персонажа
-- HRP центр находится на (HipHeight + HRP.Size.Y/2) над полом
-- Чтобы нижний край box касался пола:
-- offsetY = -(BOX_H/2) + (HipHeight + HRP.Size.Y/2)
-- То есть мы сдвигаем box вверх так, чтобы его дно = полу
local function GetDynamicBoxOffset(humanoid, hrp)
    if not humanoid or not hrp then
        -- Значения по умолчанию для стандартного R15
        -- HipHeight=1.35, HRP.Size.Y=2.0 → центр HRP на 2.35 над полом
        -- BOX_H=5.5 → полвины 2.75
        -- offsetY = 2.75 - 2.35 = 0.4 (поднять box чтоб дно касалось пола)
        return 0.4
    end
    local hipH  = humanoid.HipHeight  -- расстояние от пола до нижней грани HRP
    local hrpHY = hrp.Size.Y * 0.5    -- полвина высоты HRP
    -- Высота центра HRP над полом = hipH + hrpHY
    local hrpCenterAboveFloor = hipH + hrpHY
    -- Чтобы нижний край box (= центр box - BOX_H/2) был на уровне пола:
    -- центр box = центр HRP + offsetY
    -- нижний край box = (HRP.Y) + offsetY - BOX_H/2 = floor
    -- offsetY = BOX_H/2 - hrpCenterAboveFloor
    -- Но нам нужно нижний край box на уровне СТУПНЕЙ, а не пола
    -- Ступни (LeftFoot) примерно на 0 (полу), HRP.Y - hrpCenterAboveFloor = пол
    -- Значит offsetY поднимает центр box на (BOX_H/2 - hrpCenterAboveFloor)
    return BOX_H * 0.5 - hrpCenterAboveFloor
end

local function CreateBoxLines(color, thickness)
    local lines = {}
    for i = 1, 12 do
        local line = Drawing.new("Line")
        line.Color     = color or Color3.fromRGB(0, 200, 255)
        line.Thickness = thickness or 1.5
        line.Visible   = false
        _tinsert(lines, line)
    end
    return lines
end

local function GetBoxCorners(cf, offsetY)
    local o = offsetY or 0
    local hW, hH, hD = BOX_W*0.5, BOX_H*0.5, BOX_D*0.5
    return {
        cf:PointToWorldSpace(_V3new(-hW, -hH+o, -hD)),
        cf:PointToWorldSpace(_V3new( hW, -hH+o, -hD)),
        cf:PointToWorldSpace(_V3new( hW, -hH+o,  hD)),
        cf:PointToWorldSpace(_V3new(-hW, -hH+o,  hD)),
        cf:PointToWorldSpace(_V3new(-hW,  hH+o, -hD)),
        cf:PointToWorldSpace(_V3new( hW,  hH+o, -hD)),
        cf:PointToWorldSpace(_V3new( hW,  hH+o,  hD)),
        cf:PointToWorldSpace(_V3new(-hW,  hH+o,  hD)),
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
            line.From    = Vector2.new(sa.X, sa.Y)
            line.To      = Vector2.new(sb.X, sb.Y)
            line.Color   = color or line.Color
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
        TackleWaitLabel      = Drawing.new("Text"),
        TackleTargetLabel    = Drawing.new("Text"),
        TackleDribblingLabel = Drawing.new("Text"),
        TackleTacklingLabel  = Drawing.new("Text"),
        EagleEyeLabel        = Drawing.new("Text"),
        DribbleStatusLabel   = Drawing.new("Text"),
        DribbleTargetLabel   = Drawing.new("Text"),
        DribbleTacklingLabel = Drawing.new("Text"),
        AutoDribbleLabel     = Drawing.new("Text"),
        CooldownListLabel    = Drawing.new("Text"),
        ModeLabel            = Drawing.new("Text"),
        ManualTackleLabel    = Drawing.new("Text"),
        PingLabel            = Drawing.new("Text"),
        AngleLabel           = Drawing.new("Text"),
        PredictionLabel      = Drawing.new("Text"),
        ServerPosLabel       = Drawing.new("Text"),
        TargetRingLines      = {},
        ServerPosBoxLines    = nil,
        PredictionBoxLines   = nil,
        TackleDebugLabels    = {},
        DribbleDebugLabels   = {}
    }

    Gui.ServerPosBoxLines  = CreateBoxLines(Color3.fromRGB(0, 200, 255), 1.5)
    Gui.PredictionBoxLines = CreateBoxLines(Color3.fromRGB(255, 165, 0), 1.5)

    local screenSize     = Camera.ViewportSize
    local centerX        = screenSize.X / 2
    local tackleY        = screenSize.Y * 0.6
    local offsetTackleY  = tackleY + 30
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
        _tinsert(Gui.TackleDebugLabels, label)
    end

    Gui.TackleWaitLabel.Color  = Color3.fromRGB(255, 165, 0)
    Gui.ServerPosLabel.Color   = Color3.fromRGB(0, 200, 255)

    Gui.TackleWaitLabel.Position      = Vector2.new(centerX, offsetTackleY); offsetTackleY += 15
    Gui.TackleTargetLabel.Position    = Vector2.new(centerX, offsetTackleY); offsetTackleY += 15
    Gui.TackleDribblingLabel.Position = Vector2.new(centerX, offsetTackleY); offsetTackleY += 15
    Gui.TackleTacklingLabel.Position  = Vector2.new(centerX, offsetTackleY); offsetTackleY += 15
    Gui.EagleEyeLabel.Position        = Vector2.new(centerX, offsetTackleY); offsetTackleY += 15
    Gui.CooldownListLabel.Position    = Vector2.new(centerX, offsetTackleY); offsetTackleY += 15
    Gui.ModeLabel.Position            = Vector2.new(centerX, offsetTackleY); offsetTackleY += 15
    Gui.ManualTackleLabel.Position    = Vector2.new(centerX, offsetTackleY); offsetTackleY += 15
    Gui.PingLabel.Position            = Vector2.new(centerX, offsetTackleY); offsetTackleY += 15
    Gui.AngleLabel.Position           = Vector2.new(centerX, offsetTackleY); offsetTackleY += 15
    Gui.PredictionLabel.Position      = Vector2.new(centerX, offsetTackleY); offsetTackleY += 15
    Gui.ServerPosLabel.Position       = Vector2.new(centerX, offsetTackleY)

    local dribbleLabels = {
        Gui.DribbleStatusLabel, Gui.DribbleTargetLabel,
        Gui.DribbleTacklingLabel, Gui.AutoDribbleLabel
    }
    for _, label in ipairs(dribbleLabels) do
        label.Size = 16; label.Color = Color3.fromRGB(255, 255, 255)
        label.Outline = true; label.Center = true
        label.Visible = DebugConfig.Enabled and AutoDribbleConfig.Enabled
        _tinsert(Gui.DribbleDebugLabels, label)
    end

    Gui.DribbleStatusLabel.Position   = Vector2.new(centerX, offsetDribbleY); offsetDribbleY += 15
    Gui.DribbleTargetLabel.Position   = Vector2.new(centerX, offsetDribbleY); offsetDribbleY += 15
    Gui.DribbleTacklingLabel.Position = Vector2.new(centerX, offsetDribbleY); offsetDribbleY += 15
    Gui.AutoDribbleLabel.Position     = Vector2.new(centerX, offsetDribbleY)

    Gui.TackleWaitLabel.Text      = "Wait: 0.00"
    Gui.TackleTargetLabel.Text    = "Target: None"
    Gui.TackleDribblingLabel.Text = "isDribbling: false"
    Gui.TackleTacklingLabel.Text  = "isTackling: false"
    Gui.EagleEyeLabel.Text        = "EagleEye: Idle"
    Gui.CooldownListLabel.Text    = "CooldownList: 0"
    Gui.ModeLabel.Text            = "Mode: " .. AutoTackleConfig.Mode
    Gui.ManualTackleLabel.Text    = "ManualTackle: Ready [" .. tostring(AutoTackleConfig.ManualTackleKeybind) .. "]"
    Gui.PingLabel.Text            = "Ping: 0ms"
    Gui.AngleLabel.Text           = "Angle: -"
    Gui.PredictionLabel.Text      = "Pred: 0ms"
    Gui.ServerPosLabel.Text       = "ServerPos: -"
    Gui.DribbleStatusLabel.Text   = "Dribble: Ready"
    Gui.DribbleTargetLabel.Text   = "Targets: 0"
    Gui.DribbleTacklingLabel.Text = "Nearest: None"
    Gui.AutoDribbleLabel.Text     = "AutoDribble: Idle"

    for i = 1, 24 do
        local line = Drawing.new("Line")
        line.Thickness = 3; line.Color = Color3.fromRGB(255, 0, 0); line.Visible = false
        _tinsert(Gui.TargetRingLines, line)
    end
end

-- ============================================================
-- v3.8: UpdateServerPosBox — динамический offsetY
-- ============================================================
local function UpdateServerPosBox()
    if not Gui or not Gui.ServerPosBoxLines then return end
    if not AutoDribbleConfig.Enabled or not AutoDribbleConfig.ShowServerPos then
        HideBoxLines(Gui.ServerPosBoxLines)
        if Gui.ServerPosLabel then Gui.ServerPosLabel.Text = "ServerPos: -" end
        return
    end
    local serverCF  = GetMyServerCFrame()
    local serverPos = serverCF.Position
    -- v3.8: правильный offsetY — нижний край box = ступни
    local myHum = Character:FindFirstChild("Humanoid")
    local myHrp = HumanoidRootPart
    local boxOffset = GetDynamicBoxOffset(myHum, myHrp)
    UpdateBoxLines(Gui.ServerPosBoxLines, serverCF, boxOffset, Color3.fromRGB(0, 200, 255))
    if Gui.ServerPosLabel and DebugConfig.Enabled then
        local delay = _mfloor(AutoTackleStatus.Ping * 1.5 * 1000 + 0.5)
        local dVec = serverPos - HumanoidRootPart.Position
        local dist = _msqrt(dVec.X*dVec.X + dVec.Y*dVec.Y + dVec.Z*dVec.Z)
        Gui.ServerPosLabel.Text = string.format("ServerPos: %dms delay | %.1f studs", delay, dist)
    end
end

-- ============================================================
-- v3.8: UpdatePredictionBox — динамический offsetY для цели
-- ============================================================
local function UpdatePredictionBox(ownerRoot, player, targetHumanoid)
    if not Gui or not Gui.PredictionBoxLines then return end
    if not AutoTackleConfig.Enabled or not AutoTackleConfig.ShowPredictionBox then
        HideBoxLines(Gui.PredictionBoxLines)
        return
    end
    if not ownerRoot or not player then
        HideBoxLines(Gui.PredictionBoxLines)
        return
    end
    local predictedPos = PredictTargetPosition(ownerRoot, player)
    local predictedCF  = CFrame.new(predictedPos)
    -- v3.8: offsetY для цели (используем её humanoid/hrp)
    local boxOffset = GetDynamicBoxOffset(targetHumanoid, ownerRoot)
    UpdateBoxLines(Gui.PredictionBoxLines, predictedCF, boxOffset, Color3.fromRGB(255, 165, 0))
end

local function UpdateDebugVisibility()
    if not Gui then return end
    local tackleVisible = DebugConfig.Enabled and AutoTackleConfig.Enabled
    for _, label in ipairs(Gui.TackleDebugLabels) do label.Visible = tackleVisible end
    local dribbleVisible = DebugConfig.Enabled and AutoDribbleConfig.Enabled
    for _, label in ipairs(Gui.DribbleDebugLabels) do label.Visible = dribbleVisible end
    if not AutoTackleConfig.Enabled then
        for _, line in ipairs(Gui.TargetRingLines) do line.Visible = false end
        if Gui.PredictionBoxLines then HideBoxLines(Gui.PredictionBoxLines) end
    end
    if not AutoDribbleConfig.Enabled or not AutoDribbleConfig.ShowServerPos then
        if Gui.ServerPosBoxLines then HideBoxLines(Gui.ServerPosBoxLines) end
    end
    if not AutoTackleConfig.Enabled or not AutoTackleConfig.ShowPredictionBox then
        if Gui.PredictionBoxLines then HideBoxLines(Gui.PredictionBoxLines) end
    end
end

local function CleanupDebugText()
    if not Gui then return end
    if not AutoTackleConfig.Enabled then
        Gui.TackleWaitLabel.Text      = "Wait: 0.00"
        Gui.TackleTargetLabel.Text    = "Target: None"
        Gui.TackleDribblingLabel.Text = "isDribbling: false"
        Gui.TackleTacklingLabel.Text  = "isTackling: false"
        Gui.EagleEyeLabel.Text        = "EagleEye: Idle"
        Gui.ManualTackleLabel.Text    = "ManualTackle: Ready [" .. tostring(AutoTackleConfig.ManualTackleKeybind) .. "]"
        Gui.ModeLabel.Text            = "Mode: " .. AutoTackleConfig.Mode
        Gui.PingLabel.Text            = "Ping: 0ms"
        Gui.PredictionLabel.Text      = "Pred: 0ms"
    end
    if not AutoDribbleConfig.Enabled then
        Gui.DribbleStatusLabel.Text   = "Dribble: Ready"
        Gui.DribbleTargetLabel.Text   = "Targets: 0"
        Gui.DribbleTacklingLabel.Text = "Nearest: None"
        Gui.AutoDribbleLabel.Text     = "AutoDribble: Idle"
        if Gui.ServerPosBoxLines then HideBoxLines(Gui.ServerPosBoxLines) end
    end
end

-- === 3D КРУГИ ===
local function Create3DCircle()
    local circle = {}
    for i = 1, 24 do
        local line = Drawing.new("Line")
        line.Thickness = 3; line.Color = Color3.fromRGB(255, 0, 0); line.Visible = false
        _tinsert(circle, line)
    end
    return circle
end

local function Update3DCircle(circle, position, radius, color)
    if not circle then return end
    local segments = #circle
    local points = {}
    local px, pz = position.X, position.Z
    local py = position.Y
    local invSeg = (2 * math.pi) / segments
    for i = 1, segments do
        local angle = (i - 1) * invSeg
        _tinsert(points, _V3new(px + _mcos(angle) * radius, py, pz + math.sin(angle) * radius))
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
                Update3DCircle(circle, targetRoot.Position - _V3new(0, 0.5, 0), 2, color)
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
                    if mp.X >= pos.X - tb.X*0.5 and mp.X <= pos.X + tb.X*0.5 and
                       mp.Y >= pos.Y - tb.Y*0.5 and mp.Y <= pos.Y + tb.Y*0.5 then
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
    if not targetPlayer or not targetPlayer.Character or not targetPlayer.Parent or targetPlayer.TeamColor == LocalPlayer.TeamColor then return false end
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
    if not targetPlayer or not targetPlayer.Character or not targetPlayer.Parent or targetPlayer.TeamColor == LocalPlayer.TeamColor then return false end
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
    local currentTime = _tick()
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
            _tinsert(toRemove, player)
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

-- === PRECOMPUTE PLAYERS ===
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
            Gui.DribbleStatusLabel.Text  = bools.dribbleDebounce.Value and "Dribble: Cooldown" or "Dribble: Ready"
            Gui.DribbleStatusLabel.Color = bools.dribbleDebounce.Value and Color3.fromRGB(255, 0, 0) or Color3.fromRGB(0, 255, 0)
        end
    end
    local myPos = HumanoidRootPart.Position
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
        local tp = targetRoot.Position
        local dx = tp.X - myPos.X; local dz = tp.Z - myPos.Z
        local distance = _msqrt(dx*dx + (tp.Y-myPos.Y)*(tp.Y-myPos.Y) + dz*dz)
        if distance > AutoDribbleConfig.MaxDribbleDistance then continue end
        local alv = targetRoot.AssemblyLinearVelocity
        local posVel = GetPositionBasedVelocity(player)
        local velocity = alv.Magnitude >= posVel.Magnitude and alv or posVel
        PrecomputedPlayers[player] = {
            Distance   = distance,
            IsValid    = true,
            IsTackling = TackleStates[player].IsTackling,
            RootPart   = targetRoot,
            Humanoid   = humanoid,  -- v3.8: храним humanoid для GetDynamicBoxOffset
            Velocity   = velocity
        }
        if distance <= AutoDribbleConfig.DribbleActivationDistance * 1.5 then
            RecordTargetPosition(targetRoot, player)
        end
    end
end

-- ============================================================
-- === РОТАЦИЯ v3.7+
-- ============================================================
local function RotateToTarget(targetPos)
    if AutoTackleConfig.RotationMethod == "None" then return end
    local myPos = HumanoidRootPart.Position
    local dx = targetPos.X - myPos.X
    local dz = targetPos.Z - myPos.Z
    if _msqrt(dx*dx + dz*dz) > 0.1 then
        HumanoidRootPart.CFrame = CFrame.new(myPos, myPos + _V3new(dx, 0, dz))
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
    local bVec = HumanoidRootPart.Position - ball.Position
    local distance = _msqrt(bVec.X*bVec.X + bVec.Y*bVec.Y + bVec.Z*bVec.Z)
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
    local ownerHum  = owner and owner.Character and owner.Character:FindFirstChild("Humanoid")
    local predictedPos
    if ownerRoot and owner then
        predictedPos = PredictTargetPosition(ownerRoot, owner)
    else
        predictedPos = ball.Position
    end
    RotateToTarget(predictedPos)

    if ownerRoot and owner then
        UpdatePredictionBox(ownerRoot, owner, ownerHum)
    end

    if ownerRoot then
        local fv = HumanoidRootPart.Position - ownerRoot.Position
        local ftiDist = _msqrt(fv.X*fv.X + fv.Y*fv.Y + fv.Z*fv.Z)
        if ftiDist <= 10 then
            pcall(function() firetouchinterest(HumanoidRootPart, ownerRoot, 0) end)
            pcall(function() firetouchinterest(HumanoidRootPart, ownerRoot, 1) end)
        end
    end
    pcall(function() ActionRemote:FireServer("TackIe") end)
    local bodyVelocity = Instance.new("BodyVelocity")
    bodyVelocity.Parent   = HumanoidRootPart
    bodyVelocity.Velocity = HumanoidRootPart.CFrame.LookVector * AutoTackleConfig.TackleSpeed
    bodyVelocity.MaxForce = _V3new(50000000, 0, 50000000)
    local tackleStartTime = _tick()
    local tackleDuration  = 0.65
    local rotateConnection

    local method = AutoTackleConfig.RotationMethod
    if method == "Always" and ownerRoot and owner then
        rotateConnection = RunService.Heartbeat:Connect(function()
            if _tick() - tackleStartTime < tackleDuration then
                RotateToTarget(PredictTargetPosition(ownerRoot, owner))
            else
                rotateConnection:Disconnect()
            end
        end)
    elseif method == "Legit" and ownerRoot and owner then
        local lockedCFrame = HumanoidRootPart.CFrame
        rotateConnection = RunService.Heartbeat:Connect(function()
            if _tick() - tackleStartTime < tackleDuration then
                local currentPos = HumanoidRootPart.Position
                HumanoidRootPart.CFrame = CFrame.new(currentPos) * (lockedCFrame - lockedCFrame.Position)
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
        local bv = HumanoidRootPart.Position - ball.Position
        local dist = _msqrt(bv.X*bv.X + bv.Y*bv.Y + bv.Z*bv.Z)
        pcall(function() SoftDisPlayerRemote:FireServer(owner, dist, false, ball.Size) end)
    end
end

-- === MANUAL TACKLE ===
local function ManualTackleAction()
    local currentTime = _tick()
    if currentTime - LastManualTackleTime < AutoTackleConfig.ManualTackleCooldown then return false end
    local canTackle, ball, distance, owner = CanTackle()
    if canTackle then
        LastManualTackleTime = currentTime
        PerformTackle(ball, owner)
        if Gui and AutoTackleConfig.Enabled then
            Gui.ManualTackleLabel.Text  = "ManualTackle: EXECUTED! [" .. tostring(AutoTackleConfig.ManualTackleKeybind) .. "]"
            Gui.ManualTackleLabel.Color = Color3.fromRGB(0, 255, 0)
        end
        task.delay(0.3, function()
            if Gui and AutoTackleConfig.Enabled then Gui.ManualTackleLabel.Color = Color3.fromRGB(255, 255, 255) end
        end)
        return true
    else
        if Gui and AutoTackleConfig.Enabled then
            Gui.ManualTackleLabel.Text  = "ManualTackle: FAILED [" .. tostring(AutoTackleConfig.ManualTackleKeybind) .. "]"
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
                    Gui.TackleTargetLabel.Text    = "Target: None"
                    Gui.TackleDribblingLabel.Text = "isDribbling: false"
                    Gui.TackleTacklingLabel.Text  = "isTackling: false"
                    Gui.TackleWaitLabel.Text      = "Wait: 0.00"
                    Gui.EagleEyeLabel.Text        = "EagleEye: Idle"
                    if AutoTackleConfig.Mode == "ManualTackle" then
                        Gui.ManualTackleLabel.Text  = "ManualTackle: NO TARGET [" .. tostring(AutoTackleConfig.ManualTackleKeybind) .. "]"
                        Gui.ManualTackleLabel.Color = Color3.fromRGB(255, 0, 0)
                    end
                end
                if Gui and Gui.PredictionBoxLines then HideBoxLines(Gui.PredictionBoxLines) end
                CurrentTargetOwner = nil
                return
            end
            if Gui then
                Gui.TackleTargetLabel.Text    = "Target: " .. (owner and owner.Name or "None")
                Gui.TackleDribblingLabel.Text = "isDribbling: " .. tostring(owner and DribbleStates[owner] and DribbleStates[owner].IsDribbling or false)
                Gui.TackleTacklingLabel.Text  = "isTackling: " .. tostring(owner and IsSpecificTackle(owner) or false)
                Gui.PingLabel.Text            = string.format("Ping: %dms", _mfloor(AutoTackleStatus.Ping * 1000 + 0.5))
            end
            if owner then
                local ownerRootLive = owner.Character and owner.Character:FindFirstChild("HumanoidRootPart")
                local ownerHumLive  = owner.Character and owner.Character:FindFirstChild("Humanoid")
                UpdatePredictionLabel(ownerRootLive, owner)
                UpdatePredictionBox(ownerRootLive, owner, ownerHumLive)
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
                    Gui.EagleEyeLabel.Text      = "ManualTackle: Ready"
                    Gui.ManualTackleLabel.Text  = "ManualTackle: READY [" .. tostring(AutoTackleConfig.ManualTackleKeybind) .. "]"
                    Gui.ManualTackleLabel.Color = Color3.fromRGB(0, 255, 0)
                end
                return
            end
            if not owner then return end
            local state = DribbleStates[owner] or { IsDribbling = false, LastDribbleEnd = 0, IsProcessingDelay = false, HadDribble = false }
            local isDribbling    = state.IsDribbling
            local inCooldownList = DribbleCooldownList[owner] ~= nil
            if AutoTackleConfig.Mode == "OnlyDribble" then
                if inCooldownList then
                    PerformTackle(ball, owner)
                    if Gui then Gui.EagleEyeLabel.Text = "OnlyDribble: Tackling!" end
                elseif isDribbling then
                    if Gui then
                        Gui.EagleEyeLabel.Text   = "OnlyDribble: Dribbling..."
                        Gui.TackleWaitLabel.Text = string.format("DDelay: %.2f", AutoTackleConfig.DribbleDelayTime)
                    end
                elseif state.IsProcessingDelay then
                    local remaining = AutoTackleConfig.DribbleDelayTime - (_tick() - state.LastDribbleEnd)
                    if Gui then
                        Gui.EagleEyeLabel.Text   = "OnlyDribble: DribDelay"
                        Gui.TackleWaitLabel.Text = string.format("Wait: %.2f", remaining)
                    end
                else
                    if Gui then
                        Gui.EagleEyeLabel.Text   = "OnlyDribble: Waiting dribble"
                        Gui.TackleWaitLabel.Text = "Wait: -"
                    end
                end
            elseif AutoTackleConfig.Mode == "EagleEye" then
                local currentTime = _tick()
                if isDribbling then
                    EagleEyeTimers[owner] = nil
                    if Gui then
                        Gui.TackleWaitLabel.Text = "Wait: DRIBBLE"
                        Gui.EagleEyeLabel.Text   = "EagleEye: Dribbling (reset)"
                    end
                elseif state.IsProcessingDelay then
                    EagleEyeTimers[owner] = nil
                    local remaining = AutoTackleConfig.DribbleDelayTime - (currentTime - state.LastDribbleEnd)
                    if Gui then
                        Gui.TackleWaitLabel.Text = string.format("DDelay: %.2f", remaining)
                        Gui.EagleEyeLabel.Text   = "EagleEye: DribbleDelay"
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
                    local timer   = EagleEyeTimers[owner]
                    local elapsed = currentTime - timer.startTime
                    if elapsed >= timer.waitTime then
                        PerformTackle(ball, owner)
                        EagleEyeTimers[owner] = nil
                        if Gui then Gui.EagleEyeLabel.Text = "EagleEye: Tackling!" end
                    else
                        if Gui then
                            Gui.TackleWaitLabel.Text = string.format("Wait: %.2f", timer.waitTime - elapsed)
                            Gui.EagleEyeLabel.Text   = "EagleEye: Waiting"
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
-- === AUTODRIBBLE MODULE — v3.8
-- ==========================================================
local _cachedAngleDeg   = -1
local _cachedCosThresh  = 0
local function GetCosThreshold()
    if AutoDribbleConfig.MinAngleForDribble ~= _cachedAngleDeg then
        _cachedAngleDeg  = AutoDribbleConfig.MinAngleForDribble
        _cachedCosThresh = _mcos(_mrad(_cachedAngleDeg))
    end
    return _cachedCosThresh
end

-- ============================================================
-- ShouldDribbleNow v3.8 — ИСПРАВЛЕННЫЙ Strict режим
--
-- Проблемы предыдущей версии и исправления:
-- 1) Ложные срабатывания при медленном движении: теперь минимальный
--    порог скорости повышен до 2.0 для Free и 2.5 для Strict
-- 2) В зоне активации Strict не проверял TTC — теперь проверяет всегда
-- 3) Velocity из истории позиций "запаздывает" — теперь берём
--    max(ALV, posVel) И применяем exponential smoothing буфер
-- 4) Strict: угол проверяется через acos от clamp dot — без артефактов
--    при dot > 1 из-за floating point ошибок
-- 5) Strict: TTC порог 0.22s (был 0.3s) — убирает ложные срабатывания
--    на дальних дистанциях с хорошим углом но медленным сближением
-- ============================================================

-- v3.8: кэш скоростей с exponential smoothing для стабилизации
local _velocitySmooth = {}  -- player -> smoothed velocity
local SMOOTH_ALPHA = 0.35   -- коэффициент сглаживания (0=полный кэш, 1=raw)

local function GetSmoothedVelocity(player, rawVelocity)
    local prev = _velocitySmooth[player]
    if not prev then
        _velocitySmooth[player] = rawVelocity
        return rawVelocity
    end
    -- Exponential Moving Average: smooth = alpha*raw + (1-alpha)*prev
    local sx = SMOOTH_ALPHA * rawVelocity.X + (1 - SMOOTH_ALPHA) * prev.X
    local sy = SMOOTH_ALPHA * rawVelocity.Y + (1 - SMOOTH_ALPHA) * prev.Y
    local sz = SMOOTH_ALPHA * rawVelocity.Z + (1 - SMOOTH_ALPHA) * prev.Z
    local smoothed = _V3new(sx, sy, sz)
    _velocitySmooth[player] = smoothed
    return smoothed
end

local function ShouldDribbleNow(specificTarget, tacklerData)
    if not specificTarget or not tacklerData then return false end

    local tacklerRoot = tacklerData.RootPart
    if not tacklerRoot then return false end

    local serverCF     = GetMyServerCFrame()
    local myServerPos  = serverCF.Position
    local msx, msz     = myServerPos.X, myServerPos.Z

    -- v3.8: берём сглаженную скорость чтобы убрать дрожание вектора
    local rawVel   = tacklerData.Velocity
    local velocity = GetSmoothedVelocity(specificTarget, rawVel)
    local vx, vz   = velocity.X, velocity.Z
    local speed2D  = _msqrt(vx*vx + vz*vz)

    local tp = tacklerRoot.Position
    local toPing = AutoTackleStatus.Ping
    -- Предсказанная позиция таклера через пинг
    local predTx = tp.X + vx * toPing * 1.5
    local predTz = tp.Z + vz * toPing * 1.5

    local toMeX = msx - predTx
    local toMeZ = msz - predTz
    local distFlat = _msqrt(toMeX*toMeX + toMeZ*toMeZ)

    if distFlat > AutoDribbleConfig.MaxDribbleDistance then
        if Gui and AutoDribbleConfig.Enabled then
            Gui.AngleLabel.Text = string.format("FAR d=%.1f", distFlat)
        end
        return false
    end

    -- [СТАДИЯ 0] Вплотную — реагируем немедленно в обоих режимах
    if distFlat < 4 then
        if Gui and AutoDribbleConfig.Enabled then
            Gui.AngleLabel.Text = string.format("⚡ POINT BLANK d=%.1f", distFlat)
        end
        return true
    end

    -- [СТАДИЯ 1] Зона активации
    if distFlat <= AutoDribbleConfig.DribbleActivationDistance then
        if not tacklerData.IsTackling then
            if Gui and AutoDribbleConfig.Enabled then
                Gui.AngleLabel.Text = string.format("CLOSE d=%.1f NO_TACKLE", distFlat)
            end
            return false
        end

        if AutoDribbleConfig.DribbleMode == "Strict" then
            -- Strict в зоне активации: проверяем СКОРОСТЬ и TTC
            -- Минимальная скорость 2.5 для исключения ложных срабатываний
            -- при медленном движении/стоячем враге
            local minSpeedStrict = 2.5
            if speed2D < minSpeedStrict then
                if Gui and AutoDribbleConfig.Enabled then
                    Gui.AngleLabel.Text = string.format("[S] CLOSE slow v=%.1f", speed2D)
                end
                return false
            end
            -- Рассчитываем TTC: relSpeed = скорость сближения по оси toMe
            local invDistFlat = 1 / _mmax(distFlat, 0.001)
            local toMeUX = toMeX * invDistFlat
            local toMeUZ = toMeZ * invDistFlat
            -- Проекция скорости таклера на направление к игроку
            local approach = vx * toMeUX + vz * toMeUZ
            -- Также учитываем нашу скорость (уходим/приближаемся)
            local myVelH = GetMyVelocityFromHistory()
            local myApproach = -(myVelH.X * toMeUX + myVelH.Z * toMeUZ) -- знак: убегание уменьшает relSpeed
            local relSpeedStrict = approach + _mmax(myApproach, 0)
            if relSpeedStrict < 1.0 then
                -- Скорость сближения слишком мала — не столкнутся
                if Gui and AutoDribbleConfig.Enabled then
                    Gui.AngleLabel.Text = string.format("[S] CLOSE approach=%.1f", relSpeedStrict)
                end
                return false
            end
            local ttcStrict = distFlat / _mmax(relSpeedStrict, 1)

            -- Угловая проверка только если не вплотную (< 8 studs угол не важен)
            if distFlat >= 8 then
                local cosThreshS = GetCosThreshold()
                -- Нормализуем вектор скорости
                local invSpeed2D = 1 / _mmax(speed2D, 0.001)
                local dirVX = vx * invSpeed2D
                local dirVZ = vz * invSpeed2D
                local dotS = dirVX * toMeUX + dirVZ * toMeUZ
                -- Clamp для floating point безопасности
                dotS = _mclamp(dotS, -1, 1)
                if dotS < cosThreshS then
                    if Gui and AutoDribbleConfig.Enabled then
                        local angleDegS = math.deg(math.acos(dotS))
                        Gui.AngleLabel.Text = string.format("[S] BAD_ANGLE A=%.0f°", angleDegS)
                    end
                    return false
                end
            end

            if Gui and AutoDribbleConfig.Enabled then
                Gui.AngleLabel.Text = string.format("[S] TTC=%.2f d=%.1f", ttcStrict, distFlat)
            end
            return ttcStrict < 0.22

        else
            -- Free: просто реагируем в зоне активации при такле
            if Gui and AutoDribbleConfig.Enabled then
                Gui.AngleLabel.Text = string.format("⚡ TACKLE CLOSE d=%.1f", distFlat)
            end
            return true
        end
    end

    -- [СТАДИЯ 2] Средняя дистанция — проверка скорости и угла
    -- v3.8: минимальная скорость 2.0 для Free, 2.5 для Strict
    local minSpeed = AutoDribbleConfig.DribbleMode == "Strict" and 2.5 or 2.0
    if speed2D < minSpeed then
        if Gui and AutoDribbleConfig.Enabled then
            Gui.AngleLabel.Text = string.format("v=%.1f (slow)", speed2D)
        end
        return false
    end

    local invDistFlat = 1 / _mmax(distFlat, 0.001)
    local toMeUX = toMeX * invDistFlat
    local toMeUZ = toMeZ * invDistFlat
    local invSpeed2D = 1 / _mmax(speed2D, 0.001)
    local dirVX = vx * invSpeed2D
    local dirVZ = vz * invSpeed2D
    local dot = dirVX * toMeUX + dirVZ * toMeUZ
    dot = _mclamp(dot, -1, 1)  -- floating point защита
    local cosThresh = GetCosThreshold()

    if Gui and AutoDribbleConfig.Enabled then
        local angleDeg = math.deg(math.acos(dot))
        Gui.AngleLabel.Text = string.format("A=%.0f° v=%.1f d=%.1f", angleDeg, speed2D, distFlat)
    end

    if dot < cosThresh then return false end

    -- Рассчитываем TTC
    local approach = vx * toMeUX + vz * toMeUZ
    local myVelH   = GetMyVelocityFromHistory()
    local myApproach = -(myVelH.X * toMeUX + myVelH.Z * toMeUZ)
    local relSpeed = approach + _mmax(myApproach, 0)
    if relSpeed < 0.5 then return false end  -- расходятся — не сработает
    local timeToCollision = distFlat / _mmax(relSpeed, 1)

    if Gui and AutoDribbleConfig.Enabled then
        Gui.AngleLabel.Text = Gui.AngleLabel.Text .. string.format(" t=%.2f", timeToCollision)
    end

    if AutoDribbleConfig.DribbleMode == "Strict" then
        -- Strict: строгое окно TTC и дополнительная проверка минимального сближения
        return timeToCollision < 0.22
    else
        -- Free: мягкий порог
        return timeToCollision < 0.4
    end
end

local function PerformDribble()
    local currentTime = _tick()
    if currentTime - AutoDribbleStatus.LastDribbleTime < 0.02 then return end
    local bools = Workspace:FindFirstChild(LocalPlayer.Name) and Workspace[LocalPlayer.Name]:FindFirstChild("Bools")
    if not bools or bools.dribbleDebounce.Value then return end
    pcall(function() ActionRemote:FireServer("Deke") end)
    AutoDribbleStatus.LastDribbleTime = currentTime
    if Gui and AutoDribbleConfig.Enabled then
        Gui.DribbleStatusLabel.Text  = "Dribble: Cooldown"
        Gui.DribbleStatusLabel.Color = Color3.fromRGB(255, 0, 0)
        Gui.AutoDribbleLabel.Text    = "AutoDribble: DEKE!"
    end
end

local AutoDribble = {}

-- v3.8: dirty-flag кэш с пониженным порогом позиции для Strict
local _dribbleCache = {
    result = false,
    lastTacklerPlayer = nil,
    lastTacklerPos = Vector3.zero,
    lastMyPos = Vector3.zero,
    lastIsTackling = false,
    lastCalcTime = 0,
    RECALC_INTERVAL = 0.008,         -- ~120fps пересчёт
    POSITION_DIRTY_THRESHOLD = 0.15, -- меньше порог = чаще пересчёт при движении
}

local function IsDribbleCacheDirty(specificTarget, tacklerData)
    if not specificTarget or not tacklerData then return true end
    local now = _tick()
    if now - _dribbleCache.lastCalcTime > _dribbleCache.RECALC_INTERVAL then return true end
    if _dribbleCache.lastTacklerPlayer ~= specificTarget then return true end
    if _dribbleCache.lastIsTackling ~= tacklerData.IsTackling then return true end
    local root = tacklerData.RootPart
    if root then
        local cp = _dribbleCache.lastTacklerPos
        local rp = root.Position
        local dx = rp.X - cp.X; local dz = rp.Z - cp.Z
        if _msqrt(dx*dx + dz*dz) > _dribbleCache.POSITION_DIRTY_THRESHOLD then return true end
    end
    local mp = _dribbleCache.lastMyPos
    local hp = HumanoidRootPart.Position
    local mdx = hp.X - mp.X; local mdz = hp.Z - mp.Z
    if _msqrt(mdx*mdx + mdz*mdz) > _dribbleCache.POSITION_DIRTY_THRESHOLD then return true end
    return false
end

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

    local function DribbleLoop()
        if not AutoDribbleConfig.Enabled then CleanupDebugText(); UpdateDebugVisibility(); return end

        if not HasBall or not CanDribbleNow then
            if Gui then Gui.AutoDribbleLabel.Text = "AutoDribble: Idle" end
            return
        end

        local specificTarget, minDist, targetCount, nearestTacklerData = nil, math.huge, 0, nil
        for player, data in pairs(PrecomputedPlayers) do
            if data.IsValid and TackleStates[player] and TackleStates[player].IsTackling then
                targetCount += 1
                if data.Distance < minDist then
                    minDist = data.Distance
                    specificTarget = player
                    nearestTacklerData = data
                end
            end
        end

        if Gui then
            Gui.DribbleTargetLabel.Text  = "Targets: " .. targetCount
            Gui.DribbleTacklingLabel.Text = specificTarget
                and string.format("Tackle: %.1f", minDist)
                or "Tackle: None"
        end

        if not specificTarget or not nearestTacklerData then
            if Gui then Gui.AutoDribbleLabel.Text = "AutoDribble: Idle" end
            return
        end

        local dribbleShouldFire
        if IsDribbleCacheDirty(specificTarget, nearestTacklerData) then
            dribbleShouldFire = ShouldDribbleNow(specificTarget, nearestTacklerData)
            _dribbleCache.result = dribbleShouldFire
            _dribbleCache.lastCalcTime = _tick()
            _dribbleCache.lastTacklerPlayer = specificTarget
            _dribbleCache.lastIsTackling = nearestTacklerData and nearestTacklerData.IsTackling or false
            if nearestTacklerData and nearestTacklerData.RootPart then
                _dribbleCache.lastTacklerPos = nearestTacklerData.RootPart.Position
            end
            _dribbleCache.lastMyPos = HumanoidRootPart.Position
        else
            dribbleShouldFire = _dribbleCache.result
        end

        if dribbleShouldFire then
            PerformDribble()
        else
            if Gui then Gui.AutoDribbleLabel.Text = "AutoDribble: Waiting" end
        end
    end

    AutoDribbleStatus.Connection = RunService.Heartbeat:Connect(function()
        pcall(DribbleLoop)
    end)

    UpdateDebugVisibility()
    if notify then notify("AutoDribble", "Started", true) end
end

AutoDribble.Stop = function()
    if AutoDribbleStatus.Connection then AutoDribbleStatus.Connection:Disconnect(); AutoDribbleStatus.Connection = nil end
    if AutoDribbleStatus.HeartbeatConnection then AutoDribbleStatus.HeartbeatConnection:Disconnect(); AutoDribbleStatus.HeartbeatConnection = nil end
    AutoDribbleStatus.Running = false
    if Gui and Gui.ServerPosBoxLines then HideBoxLines(Gui.ServerPosBoxLines) end
    if Gui and Gui.PredictionBoxLines then HideBoxLines(Gui.PredictionBoxLines) end
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
            Options = {"Snap", "Legit", "Always", "None"},
            Callback = function(v) AutoTackleConfig.RotationMethod = v end
        }, "AutoTackleRotationMethod")
        uiElements.AutoTackleShowPredictionBox = UI.Sections.AutoTackle:Toggle({
            Name = "Show Prediction Box", Default = AutoTackleConfig.ShowPredictionBox,
            Callback = function(v)
                AutoTackleConfig.ShowPredictionBox = v
                if not v and Gui and Gui.PredictionBoxLines then
                    HideBoxLines(Gui.PredictionBoxLines)
                end
                UpdateDebugVisibility()
            end
        }, "AutoTackleShowPredictionBox")
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
                _cachedAngleDeg = -1
            end
        }, "AutoDribbleMinAngle")
        uiElements.AutoDribbleMode = UI.Sections.AutoDribble:Dropdown({
            Name = "Dribble Mode", Default = AutoDribbleConfig.DribbleMode,
            Options = {"Free", "Strict"},
            Callback = function(v)
                AutoDribbleConfig.DribbleMode = v
                _cachedAngleDeg = -1
            end
        }, "AutoDribbleMode")
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
        { uiElements.AutoTackleMaxDistance,         function(v) AutoTackleConfig.MaxDistance = v end },
        { uiElements.AutoTackleTackleDistance,      function(v) AutoTackleConfig.TackleDistance = v end },
        { uiElements.AutoTackleTackleSpeed,         function(v) AutoTackleConfig.TackleSpeed = v end },
        { uiElements.AutoTackleDribbleDelay,        function(v) AutoTackleConfig.DribbleDelayTime = v end },
        { uiElements.AutoTackleEagleEyeMinDelay,    function(v) AutoTackleConfig.EagleEyeMinDelay = v end },
        { uiElements.AutoTackleEagleEyeMaxDelay,    function(v) AutoTackleConfig.EagleEyeMaxDelay = v end },
        { uiElements.AutoDribbleMaxDistance,        function(v) AutoDribbleConfig.MaxDribbleDistance = v end },
        { uiElements.AutoDribbleActivationDistance, function(v) AutoDribbleConfig.DribbleActivationDistance = v end },
        { uiElements.AutoDribbleMinAngle,           function(v) AutoDribbleConfig.MinAngleForDribble = v; _cachedAngleDeg = -1 end },
    }
    for _, pair in ipairs(pairs_sync) do
        local elem, setter = pair[1], pair[2]
        if elem and elem.GetValue then pcall(function() setter(elem:GetValue()) end) end
    end
end

-- === МОДУЛЬ ===
local AutoDribbleTackleModule = {}
function AutoDribbleTackleModule.Init(UI, coreParam, notifyFunc)
    core       = coreParam
    Services   = core.Services
    PlayerData = core.PlayerData
    notify     = notifyFunc
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
        Character        = newChar
        Humanoid         = newChar:WaitForChild("Humanoid")
        HumanoidRootPart = newChar:WaitForChild("HumanoidRootPart")
        DribbleStates    = {}; TackleStates = {}; PrecomputedPlayers = {}
        DribbleCooldownList = {}; EagleEyeTimers = {}
        AutoTackleStatus.TargetPositionHistory = {}
        AutoTackleStatus.TargetCircles = {}
        MyPositionHistory  = {}
        _cachedAngleDeg    = -1
        _velocitySmooth    = {}  -- v3.8: сброс smoothing буфера
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
        if Gui.PredictionBoxLines then RemoveBoxLines(Gui.PredictionBoxLines) end
    end
end

return AutoDribbleTackleModule
