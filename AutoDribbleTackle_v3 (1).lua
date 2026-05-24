-- [v4.2] AUTO DRIBBLE + AUTO TACKLE
-- Changelog v4.2:
-- [FIX] 3D Box полностью переписан:
--       - 8 углов через character:GetBoundingBox() — реальный размер, не хардкод
--       - 12 рёбер через Drawing.new("Line") — настоящий 3D wireframe
--       - При прыжке/приседе box следует за реальными размерами без артефактов
--       - Outline убран
-- [KEEP] Free режим: distFlat <= PointBlankRadius + IsTackling → немедленный dribble
-- [REMOVE] Strict режим, SynchronizeConfigValues

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
local _tins   = table.insert
local _trem   = table.remove

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")
local Camera            = Workspace.CurrentCamera
local UserInputService  = game:GetService("UserInputService")
local Debris            = game:GetService("Debris")
local Stats             = game:GetService("Stats")

local LocalPlayer      = Players.LocalPlayer
local Character        = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
local HumanoidRootPart = Character:WaitForChild("HumanoidRootPart")
local Humanoid         = Character:WaitForChild("Humanoid")

local ActionRemote        = ReplicatedStorage.Remotes:WaitForChild("Action")
local SoftDisPlayerRemote = ReplicatedStorage.Remotes:WaitForChild("SoftDisPlayer")
local Animations          = ReplicatedStorage:WaitForChild("Animations")
local DribbleAnims        = Animations:WaitForChild("Dribble")

local DribbleAnimIds = {}
for _, a in pairs(DribbleAnims:GetChildren()) do
    if a:IsA("Animation") then _tins(DribbleAnimIds, a.AnimationId) end
end

-- ============================================================
-- ПИНГ
-- ============================================================
local function GetPing()
    local ok, v = pcall(function()
        return tonumber(Stats.Network.ServerStatsItem["Data Ping"]:GetValueString():match("%d+"))
    end)
    if ok and v then return v / 1000 end
    return 0.1
end

-- ============================================================
-- CONFIG
-- ============================================================
local AutoTackleConfig = {
    Enabled              = false,
    Mode                 = "OnlyDribble",
    MaxDistance          = 20,
    TackleDistance       = 0,
    TackleSpeed          = 60,
    OnlyPlayer           = true,
    RotationMethod       = "Snap",
    DribbleDelayTime     = 0,
    EagleEyeMinDelay     = 0.2,
    EagleEyeMaxDelay     = 0.6,
    ManualTackleEnabled  = true,
    ManualTackleKeybind  = Enum.KeyCode.Q,
    ManualTackleCooldown = 0.5,
    ShowPredictionBox    = true,
}

local AutoDribbleConfig = {
    Enabled                   = false,
    MaxDribbleDistance        = 30,
    DribbleActivationDistance = 17,
    MinAngleForDribble        = 32,
    ShowServerPos             = false,
    DribbleMode               = "Free",
    PointBlankRadius          = 8,
}

local DebugConfig = { Enabled = false, MoveEnabled = false }

-- ============================================================
-- STATES
-- ============================================================
local AutoTackleStatus = {
    Running = false, Connection = nil, HeartbeatConnection = nil, InputConnection = nil,
    Ping = 0.1, LastPingUpdate = 0,
    TargetPositionHistory = {}, TargetCircles = {}
}
local AutoDribbleStatus = {
    Running = false, Connection = nil, HeartbeatConnection = nil, LastDribbleTime = 0
}
local DribbleStates       = {}
local TackleStates        = {}
local PrecomputedPlayers  = {}
local HasBall             = false
local CanDribbleNow       = false
local DribbleCooldownList = {}
local EagleEyeTimers      = {}
local IsTypingInChat      = false
local LastManualTackleTime= 0
local CurrentTargetOwner  = nil
local SPECIFIC_TACKLE_ID  = "rbxassetid://14317040670"

-- ============================================================
-- ИСТОРИЯ ПОЗИЦИЙ
-- ============================================================
local HISTORY_SIZE   = 12
local HISTORY_WINDOW = 0.12

local function RecordTargetPosition(ownerRoot, player)
    local h = AutoTackleStatus.TargetPositionHistory[player]
    if not h then h = {}; AutoTackleStatus.TargetPositionHistory[player] = h end
    _tins(h, {time=_tick(), pos=ownerRoot.Position})
    while #h > HISTORY_SIZE do _trem(h,1) end
end

local function GetPositionBasedVelocity(player)
    local h = AutoTackleStatus.TargetPositionHistory[player]
    if not h or #h < 2 then return Vector3.zero end
    local now = _tick()
    local oldest, newest = nil, nil
    for _, pt in ipairs(h) do
        if now - pt.time <= HISTORY_WINDOW then
            if not oldest then oldest = pt end
            newest = pt
        end
    end
    if not oldest or oldest == newest then
        if #h >= 2 then oldest = h[#h-1]; newest = h[#h] else return Vector3.zero end
    end
    local dt = newest.time - oldest.time
    if dt < 0.001 then return Vector3.zero end
    local inv = 1/dt
    local op, np = oldest.pos, newest.pos
    return _V3new((np.X-op.X)*inv,(np.Y-op.Y)*inv,(np.Z-op.Z)*inv)
end

local function CalcInterceptTime(fromPos, targetPos, vel, speed)
    local tx = targetPos.X - fromPos.X
    local tz = targetPos.Z - fromPos.Z
    local dist = _msqrt(tx*tx + tz*tz)
    if dist < 0.01 then return 0 end
    local vx, vz = vel.X, vel.Z
    local a = speed*speed - (vx*vx + vz*vz)
    local b = -2*(tx*vx + tz*vz)
    local c = -(dist*dist)
    local t
    if _mabs(a) < 0.001 then
        t = (_mabs(b) > 0.001) and (-c/b) or (dist/_mmax(speed,1))
    else
        local disc = b*b - 4*a*c
        if disc < 0 then
            t = dist/_mmax(speed,1)
        else
            local sq = _msqrt(disc)
            local t1 = (-b-sq)/(2*a); local t2 = (-b+sq)/(2*a)
            if t1>0 and t2>0 then t=_mmin(t1,t2)
            elseif t1>0 then t=t1 elseif t2>0 then t=t2
            else t=dist/_mmax(speed,1) end
        end
    end
    return _mclamp(t, 0.02, 0.5)
end

local function PredictTargetPosition(ownerRoot, player)
    if not ownerRoot then return ownerRoot.Position end
    local ping = AutoTackleStatus.Ping
    local vel = GetPositionBasedVelocity(player)
    local vx, vz = vel.X, vel.Z
    local op = ownerRoot.Position
    local sx = op.X + vx*ping; local sz = op.Z + vz*ping
    local myPos = HumanoidRootPart.Position
    local iT = CalcInterceptTime(_V3new(myPos.X,0,myPos.Z), _V3new(sx,0,sz), _V3new(vx,0,vz), AutoTackleConfig.TackleSpeed)
    return _V3new(sx+vx*iT, op.Y, sz+vz*iT)
end

-- ============================================================
-- МОЯ СЕРВЕРНАЯ ПОЗИЦИЯ
-- ============================================================
local MY_HISTORY_SIZE = 10
local MyPositionHistory = {}

local function RecordMyPosition()
    _tins(MyPositionHistory, {time=_tick(), cframe=HumanoidRootPart.CFrame})
    while #MyPositionHistory > MY_HISTORY_SIZE do _trem(MyPositionHistory,1) end
end

local function GetMyVelocityFromHistory()
    if #MyPositionHistory < 2 then return Vector3.zero end
    local o = MyPositionHistory[1]; local n = MyPositionHistory[#MyPositionHistory]
    local dt = n.time - o.time
    if dt < 0.001 then return Vector3.zero end
    local inv = 1/dt
    local op = o.cframe.Position; local np = n.cframe.Position
    return _V3new((np.X-op.X)*inv,(np.Y-op.Y)*inv,(np.Z-op.Z)*inv)
end

local function GetMyServerCFrame()
    local nd = AutoTackleStatus.Ping * 1.5
    local v = GetMyVelocityFromHistory()
    local p = HumanoidRootPart.Position
    local sp = _V3new(p.X - v.X*nd, p.Y - v.Y*nd, p.Z - v.Z*nd)
    return CFrame.new(sp) * (HumanoidRootPart.CFrame - HumanoidRootPart.CFrame.Position)
end

-- ============================================================
-- 3D BOX — ПРАВИЛЬНАЯ РЕАЛИЗАЦИЯ
-- ============================================================
-- Принцип:
-- 1) character:GetBoundingBox() возвращает CFrame + Size реального bounding box
--    персонажа — включает все части (ноги, голова, руки) в любой позе
-- 2) Из CFrame и Size вычисляем 8 углов box в мировых координатах
-- 3) Проецируем каждый угол на экран через WorldToViewportPoint
-- 4) Рисуем 12 рёбер через Drawing.new("Line")
-- Нет хардкода размеров, нет offsetY костылей, нет артефактов при прыжке
-- ============================================================

-- 12 рёбер куба: пары индексов в массиве 8 углов
-- Углы нумерованы: 1-4 нижняя грань, 5-8 верхняя грань
-- 1=BLF, 2=BRF, 3=BRB, 4=BLB (bottom), 5=TLF, 6=TRF, 7=TRB, 8=TLB (top)
local BOX_EDGES = {
    {1,2},{2,3},{3,4},{4,1},  -- нижняя грань
    {5,6},{6,7},{7,8},{8,5},  -- верхняя грань
    {1,5},{2,6},{3,7},{4,8},  -- вертикальные рёбра
}

-- Смещения 8 углов от центра box (знаки ±X, ±Y, ±Z)
local CORNER_OFFSETS = {
    _V3new(-1,-1,-1), _V3new( 1,-1,-1), _V3new( 1,-1, 1), _V3new(-1,-1, 1),
    _V3new(-1, 1,-1), _V3new( 1, 1,-1), _V3new( 1, 1, 1), _V3new(-1, 1, 1),
}

-- Вычисляем 8 мировых точек из CFrame + Size
local function GetBoxWorldCorners(cf, size)
    local hx = size.X * 0.5
    local hy = size.Y * 0.5
    local hz = size.Z * 0.5
    local corners = {}
    for i, off in ipairs(CORNER_OFFSETS) do
        corners[i] = cf:PointToWorldSpace(_V3new(off.X*hx, off.Y*hy, off.Z*hz))
    end
    return corners
end

-- Создаём 12 Drawing.Line для одного box
local function CreateBox3D(color, thickness)
    local lines = {}
    for i = 1, 12 do
        local l = Drawing.new("Line")
        l.Color     = color or Color3.fromRGB(255, 0, 0)
        l.Thickness = thickness or 1
        l.Visible   = false
        lines[i] = l
    end
    return lines
end

-- Обновляем позиции линий по реальным данным персонажа
-- character — Instance персонажа (для GetBoundingBox)
-- overrideCF, overrideSize — если нужно передать кастомный box (для prediction)
local function UpdateBox3D(lines, character, color, overrideCF, overrideSize)
    if not lines then return end

    local cf, size
    if overrideCF and overrideSize then
        cf   = overrideCF
        size = overrideSize
    elseif character then
        -- GetBoundingBox возвращает CFrame центра box И Vector3 размера
        -- Это абсолютно точно — учитывает все части включая LeftFoot/RightFoot
        local ok, bcf, bsz = pcall(function()
            return character:GetBoundingBox()
        end)
        if not ok or not bcf then
            for _, l in ipairs(lines) do l.Visible = false end
            return
        end
        cf   = bcf
        size = bsz
    else
        for _, l in ipairs(lines) do l.Visible = false end
        return
    end

    local corners = GetBoxWorldCorners(cf, size)

    -- Проецируем все 8 углов на экран
    local screen = {}
    local allVisible = true
    for i = 1, 8 do
        local sp, onScreen = Camera:WorldToViewportPoint(corners[i])
        if not onScreen or sp.Z <= 0 then
            allVisible = false
            break
        end
        screen[i] = Vector2.new(sp.X, sp.Y)
    end

    if not allVisible then
        -- Проверяем по-другому: рисуем только рёбра оба конца которых на экране
        -- Сначала пересчитываем screen без early break
        screen = {}
        local visible = {}
        for i = 1, 8 do
            local sp, onScreen = Camera:WorldToViewportPoint(corners[i])
            screen[i]  = Vector2.new(sp.X, sp.Y)
            visible[i] = onScreen and sp.Z > 0
        end
        for i, edge in ipairs(BOX_EDGES) do
            local l = lines[i]
            if visible[edge[1]] and visible[edge[2]] then
                l.From    = screen[edge[1]]
                l.To      = screen[edge[2]]
                l.Color   = color or l.Color
                l.Visible = true
            else
                l.Visible = false
            end
        end
        return
    end

    -- Все 8 углов на экране — рисуем все 12 рёбер
    for i, edge in ipairs(BOX_EDGES) do
        local l  = lines[i]
        l.From   = screen[edge[1]]
        l.To     = screen[edge[2]]
        l.Color  = color or l.Color
        l.Visible = true
    end
end

local function HideBox3D(lines)
    if not lines then return end
    for _, l in ipairs(lines) do l.Visible = false end
end

local function RemoveBox3D(lines)
    if not lines then return end
    for _, l in ipairs(lines) do pcall(function() l:Remove() end) end
end

-- ============================================================
-- GUI
-- ============================================================
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
        -- 3D боксы: один для ServerPos (синий), один для Prediction (оранжевый)
        ServerPosBox         = nil,
        PredictionBox        = nil,
        -- per-player boxes для ESP
        PlayerBoxes          = {},
        TackleDebugLabels    = {},
        DribbleDebugLabels   = {}
    }

    Gui.ServerPosBox  = CreateBox3D(Color3.fromRGB(0, 200, 255), 1.5)
    Gui.PredictionBox = CreateBox3D(Color3.fromRGB(255, 165, 0),  1.5)

    local sv   = Camera.ViewportSize
    local cx   = sv.X / 2
    local ty   = sv.Y * 0.6
    local offT = ty + 30
    local offD = ty - 50

    local tLabels = {
        Gui.TackleWaitLabel, Gui.TackleTargetLabel, Gui.TackleDribblingLabel,
        Gui.TackleTacklingLabel, Gui.EagleEyeLabel, Gui.CooldownListLabel,
        Gui.ModeLabel, Gui.ManualTackleLabel, Gui.PingLabel, Gui.AngleLabel,
        Gui.PredictionLabel, Gui.ServerPosLabel
    }
    for _, lb in ipairs(tLabels) do
        lb.Size = 16; lb.Color = Color3.fromRGB(255,255,255)
        lb.Outline = false; lb.Center = true
        lb.Visible = DebugConfig.Enabled and AutoTackleConfig.Enabled
        _tins(Gui.TackleDebugLabels, lb)
    end
    Gui.TackleWaitLabel.Color  = Color3.fromRGB(255,165,0)
    Gui.ServerPosLabel.Color   = Color3.fromRGB(0,200,255)

    local function setPos(lb)
        lb.Position = Vector2.new(cx, offT); offT = offT + 15
    end
    setPos(Gui.TackleWaitLabel);      setPos(Gui.TackleTargetLabel)
    setPos(Gui.TackleDribblingLabel); setPos(Gui.TackleTacklingLabel)
    setPos(Gui.EagleEyeLabel);        setPos(Gui.CooldownListLabel)
    setPos(Gui.ModeLabel);            setPos(Gui.ManualTackleLabel)
    setPos(Gui.PingLabel);            setPos(Gui.AngleLabel)
    setPos(Gui.PredictionLabel);      setPos(Gui.ServerPosLabel)

    local dLabels = {
        Gui.DribbleStatusLabel, Gui.DribbleTargetLabel,
        Gui.DribbleTacklingLabel, Gui.AutoDribbleLabel
    }
    for _, lb in ipairs(dLabels) do
        lb.Size = 16; lb.Color = Color3.fromRGB(255,255,255)
        lb.Outline = false; lb.Center = true
        lb.Visible = DebugConfig.Enabled and AutoDribbleConfig.Enabled
        _tins(Gui.DribbleDebugLabels, lb)
    end
    Gui.DribbleStatusLabel.Position   = Vector2.new(cx, offD); offD = offD + 15
    Gui.DribbleTargetLabel.Position   = Vector2.new(cx, offD); offD = offD + 15
    Gui.DribbleTacklingLabel.Position = Vector2.new(cx, offD); offD = offD + 15
    Gui.AutoDribbleLabel.Position     = Vector2.new(cx, offD)

    Gui.TackleWaitLabel.Text      = "Wait: 0.00"
    Gui.TackleTargetLabel.Text    = "Target: None"
    Gui.TackleDribblingLabel.Text = "isDribbling: false"
    Gui.TackleTacklingLabel.Text  = "isTackling: false"
    Gui.EagleEyeLabel.Text        = "EagleEye: Idle"
    Gui.CooldownListLabel.Text    = "CooldownList: 0"
    Gui.ModeLabel.Text            = "Mode: " .. AutoTackleConfig.Mode
    Gui.ManualTackleLabel.Text    = "ManualTackle: Ready"
    Gui.PingLabel.Text            = "Ping: 0ms"
    Gui.AngleLabel.Text           = "Angle: -"
    Gui.PredictionLabel.Text      = "Pred: -"
    Gui.ServerPosLabel.Text       = "ServerPos: -"
    Gui.DribbleStatusLabel.Text   = "Dribble: Ready"
    Gui.DribbleTargetLabel.Text   = "Targets: 0"
    Gui.DribbleTacklingLabel.Text = "Nearest: None"
    Gui.AutoDribbleLabel.Text     = "AutoDribble: Idle"
end

-- ============================================================
-- ESP: per-player 3D boxes
-- Цвет: красный = обычный враг, оранжевый = в зоне, зелёный = IsTackling
-- ============================================================
local function GetOrCreatePlayerBox(player)
    if not Gui then return nil end
    if not Gui.PlayerBoxes[player] then
        Gui.PlayerBoxes[player] = CreateBox3D(Color3.fromRGB(255,0,0), 1)
    end
    return Gui.PlayerBoxes[player]
end

local function UpdatePlayerESPBoxes()
    if not Gui then return end
    local active = {}
    for player, data in pairs(PrecomputedPlayers) do
        if data.IsValid and data.Character then
            active[player] = true
            local box   = GetOrCreatePlayerBox(player)
            local color = Color3.fromRGB(255,0,0)
            if data.IsTackling then
                color = Color3.fromRGB(0,255,0)
            elseif data.Distance <= AutoDribbleConfig.DribbleActivationDistance then
                color = Color3.fromRGB(255,165,0)
            end
            UpdateBox3D(box, data.Character, color)
        end
    end
    -- Скрываем боксы игроков которых больше нет в списке
    for player, box in pairs(Gui.PlayerBoxes) do
        if not active[player] then
            HideBox3D(box)
        end
    end
end

-- ============================================================
-- SERVER POS BOX (синий) — мой персонаж со сдвигом на пинг
-- ============================================================
local function UpdateServerPosBox()
    if not Gui or not Gui.ServerPosBox then return end
    if not AutoDribbleConfig.ShowServerPos then
        HideBox3D(Gui.ServerPosBox)
        if Gui.ServerPosLabel then Gui.ServerPosLabel.Text = "ServerPos: -" end
        return
    end
    local serverCF = GetMyServerCFrame()
    -- Берём размер из реального персонажа, применяем к серверной позиции
    local ok, bcf, bsz = pcall(function() return Character:GetBoundingBox() end)
    if not ok then HideBox3D(Gui.ServerPosBox); return end
    -- Применяем rotation от реального box, но позицию от serverCF
    local finalCF = CFrame.new(serverCF.Position) * (bcf - bcf.Position)
    UpdateBox3D(Gui.ServerPosBox, nil, Color3.fromRGB(0,200,255), finalCF, bsz)
    if Gui.ServerPosLabel and DebugConfig.Enabled then
        local delay = _mfloor(AutoTackleStatus.Ping * 1.5 * 1000 + 0.5)
        local dv = serverCF.Position - HumanoidRootPart.Position
        local dist = _msqrt(dv.X*dv.X + dv.Y*dv.Y + dv.Z*dv.Z)
        Gui.ServerPosLabel.Text = string.format("ServerPos: %dms | %.1f st", delay, dist)
    end
end

-- ============================================================
-- PREDICTION BOX (оранжевый) — предсказанная позиция цели
-- ============================================================
local function UpdatePredictionBox(ownerRoot, player)
    if not Gui or not Gui.PredictionBox then return end
    if not AutoTackleConfig.ShowPredictionBox then
        HideBox3D(Gui.PredictionBox); return
    end
    if not ownerRoot or not player then
        HideBox3D(Gui.PredictionBox); return
    end
    local predictedPos = PredictTargetPosition(ownerRoot, player)
    local char = player.Character
    if not char then HideBox3D(Gui.PredictionBox); return end
    local ok, bcf, bsz = pcall(function() return char:GetBoundingBox() end)
    if not ok then HideBox3D(Gui.PredictionBox); return end
    -- Prediction box = реальный размер цели, но позиция предсказанная
    local predCF = CFrame.new(predictedPos) * (bcf - bcf.Position)
    UpdateBox3D(Gui.PredictionBox, nil, Color3.fromRGB(255,165,0), predCF, bsz)
end

-- ============================================================
-- DEBUG VISIBILITY
-- ============================================================
local function UpdateDebugVisibility()
    if not Gui then return end
    local tv = DebugConfig.Enabled and AutoTackleConfig.Enabled
    for _, lb in ipairs(Gui.TackleDebugLabels) do lb.Visible = tv end
    local dv = DebugConfig.Enabled and AutoDribbleConfig.Enabled
    for _, lb in ipairs(Gui.DribbleDebugLabels) do lb.Visible = dv end
    if not AutoTackleConfig.Enabled then
        HideBox3D(Gui.PredictionBox)
    end
    if not AutoDribbleConfig.Enabled or not AutoDribbleConfig.ShowServerPos then
        HideBox3D(Gui.ServerPosBox)
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
        Gui.ModeLabel.Text            = "Mode: " .. AutoTackleConfig.Mode
        Gui.ManualTackleLabel.Text    = "ManualTackle: Ready"
        Gui.PingLabel.Text            = "Ping: 0ms"
        Gui.PredictionLabel.Text      = "Pred: -"
    end
    if not AutoDribbleConfig.Enabled then
        Gui.DribbleStatusLabel.Text   = "Dribble: Ready"
        Gui.DribbleTargetLabel.Text   = "Targets: 0"
        Gui.DribbleTacklingLabel.Text = "Nearest: None"
        Gui.AutoDribbleLabel.Text     = "AutoDribble: Idle"
        HideBox3D(Gui.ServerPosBox)
    end
end

-- ============================================================
-- ПРОВЕРКИ СОСТОЯНИЙ
-- ============================================================
local function IsDribbling(targetPlayer)
    if not targetPlayer or not targetPlayer.Character or
       not targetPlayer.Parent or
       targetPlayer.TeamColor == LocalPlayer.TeamColor then return false end
    local h = targetPlayer.Character:FindFirstChild("Humanoid")
    if not h then return false end
    local an = h:FindFirstChild("Animator")
    if not an then return false end
    for _, t in pairs(an:GetPlayingAnimationTracks()) do
        if t.Animation and table.find(DribbleAnimIds, t.Animation.AnimationId) then return true end
    end
    return false
end

local function IsSpecificTackle(targetPlayer)
    if not targetPlayer or not targetPlayer.Character or
       not targetPlayer.Parent or
       targetPlayer.TeamColor == LocalPlayer.TeamColor then return false end
    local h = targetPlayer.Character:FindFirstChild("Humanoid")
    if not h then return false end
    local an = h:FindFirstChild("Animator")
    if not an then return false end
    for _, t in pairs(an:GetPlayingAnimationTracks()) do
        if t.Animation and t.Animation.AnimationId == SPECIFIC_TACKLE_ID then return true end
    end
    return false
end

local function IsPowerShooting(targetPlayer)
    if not targetPlayer then return false end
    local pf = Workspace:FindFirstChild(targetPlayer.Name)
    if not pf then return false end
    local bl = pf:FindFirstChild("Bools")
    if not bl then return false end
    local ps = bl:FindFirstChild("PowerShooting")
    return ps and ps.Value == true
end

-- ============================================================
-- DRIBBLE STATES
-- ============================================================
local function UpdateDribbleStates()
    local now = _tick()
    for _, player in pairs(Players:GetPlayers()) do
        if player == LocalPlayer or not player.Parent or
           player.TeamColor == LocalPlayer.TeamColor then continue end
        if not DribbleStates[player] then
            DribbleStates[player] = {
                IsDribbling=false, LastDribbleEnd=0,
                IsProcessingDelay=false, HadDribble=false
            }
        end
        local st = DribbleStates[player]
        local dNow = IsDribbling(player)
        if dNow and not st.IsDribbling then
            st.IsDribbling=true; st.IsProcessingDelay=false; st.HadDribble=true
        elseif not dNow and st.IsDribbling then
            st.IsDribbling=false; st.LastDribbleEnd=now; st.IsProcessingDelay=true
        elseif st.IsProcessingDelay and not dNow then
            if now - st.LastDribbleEnd >= AutoTackleConfig.DribbleDelayTime then
                DribbleCooldownList[player] = now + 3.5
                st.IsProcessingDelay = false
            end
        end
    end
    local rem = {}
    for player, endTime in pairs(DribbleCooldownList) do
        if not player or not player.Parent or now >= endTime then
            _tins(rem, player)
        end
    end
    for _, p in ipairs(rem) do
        DribbleCooldownList[p] = nil
        EagleEyeTimers[p]      = nil
    end
    if Gui and AutoTackleConfig.Enabled then
        local cnt = 0
        for _ in pairs(DribbleCooldownList) do cnt = cnt + 1 end
        Gui.CooldownListLabel.Text = "CooldownList: " .. cnt
    end
end

-- ============================================================
-- PRECOMPUTE PLAYERS
-- ============================================================
local function PrecomputePlayers()
    PrecomputedPlayers = {}
    HasBall = false; CanDribbleNow = false
    local ball = Workspace:FindFirstChild("ball")
    if ball and ball:FindFirstChild("playerWeld") and ball:FindFirstChild("creator") then
        HasBall = ball.creator.Value == LocalPlayer
    end
    local myBools = Workspace:FindFirstChild(LocalPlayer.Name) and
                    Workspace[LocalPlayer.Name]:FindFirstChild("Bools")
    if myBools then
        CanDribbleNow = not myBools.dribbleDebounce.Value
        if Gui and AutoDribbleConfig.Enabled then
            Gui.DribbleStatusLabel.Text =
                myBools.dribbleDebounce.Value and "Dribble: Cooldown" or "Dribble: Ready"
            Gui.DribbleStatusLabel.Color =
                myBools.dribbleDebounce.Value and
                Color3.fromRGB(255,0,0) or Color3.fromRGB(0,255,0)
        end
    end
    local myPos = HumanoidRootPart.Position
    for _, player in pairs(Players:GetPlayers()) do
        if player == LocalPlayer or not player.Parent or
           player.TeamColor == LocalPlayer.TeamColor then continue end
        local char = player.Character
        if not char then continue end
        local hum = char:FindFirstChild("Humanoid")
        if not hum or hum.HipHeight >= 4 then continue end
        local root = char:FindFirstChild("HumanoidRootPart")
        if not root then continue end
        TackleStates[player] = TackleStates[player] or {IsTackling=false}
        TackleStates[player].IsTackling = IsSpecificTackle(player)
        local tp = root.Position
        local dx = tp.X-myPos.X; local dy = tp.Y-myPos.Y; local dz = tp.Z-myPos.Z
        local dist = _msqrt(dx*dx + dy*dy + dz*dz)
        if dist > AutoDribbleConfig.MaxDribbleDistance then continue end
        local alv = root.AssemblyLinearVelocity
        local pv  = GetPositionBasedVelocity(player)
        local vel = alv.Magnitude >= pv.Magnitude and alv or pv
        PrecomputedPlayers[player] = {
            Distance  = dist,
            IsValid   = true,
            IsTackling= TackleStates[player].IsTackling,
            RootPart  = root,
            Character = char,
            Velocity  = vel
        }
        if dist <= AutoDribbleConfig.DribbleActivationDistance * 1.5 then
            RecordTargetPosition(root, player)
        end
    end
end

-- ============================================================
-- РОТАЦИЯ
-- ============================================================
local function RotateToTarget(targetPos)
    if AutoTackleConfig.RotationMethod == "None" then return end
    local myPos = HumanoidRootPart.Position
    local dx = targetPos.X - myPos.X
    local dz = targetPos.Z - myPos.Z
    if _msqrt(dx*dx + dz*dz) > 0.1 then
        HumanoidRootPart.CFrame = CFrame.new(myPos, myPos + _V3new(dx,0,dz))
    end
end

-- ============================================================
-- CAN TACKLE
-- ============================================================
local function CanTackle()
    local ball = Workspace:FindFirstChild("ball")
    if not ball or not ball.Parent then return false,nil,nil,nil end
    local hasOwner = ball:FindFirstChild("playerWeld") and ball:FindFirstChild("creator")
    local owner    = hasOwner and ball.creator.Value or nil
    if AutoTackleConfig.OnlyPlayer and (not hasOwner or not owner or not owner.Parent) then
        return false,nil,nil,nil
    end
    local isEnemy = not owner or (owner and owner.TeamColor ~= LocalPlayer.TeamColor)
    if not isEnemy then return false,nil,nil,nil end
    if Workspace:FindFirstChild("Bools") and (
        Workspace.Bools.APG.Value == LocalPlayer or
        Workspace.Bools.HPG.Value == LocalPlayer
    ) then return false,nil,nil,nil end
    local bv = HumanoidRootPart.Position - ball.Position
    local dist = _msqrt(bv.X*bv.X + bv.Y*bv.Y + bv.Z*bv.Z)
    if dist > AutoTackleConfig.MaxDistance then return false,nil,nil,nil end
    if owner and owner.Character then
        local th = owner.Character:FindFirstChild("Humanoid")
        if th and th.HipHeight >= 4 then return false,nil,nil,nil end
    end
    local bools = Workspace:FindFirstChild(LocalPlayer.Name) and
                  Workspace[LocalPlayer.Name]:FindFirstChild("Bools")
    if bools and (
        bools.TackleDebounce.Value or bools.Tackled.Value or
        (Character:FindFirstChild("Bools") and Character.Bools.Debounce.Value)
    ) then return false,nil,nil,nil end
    return true, ball, dist, owner
end

-- ============================================================
-- PERFORM TACKLE
-- ============================================================
local function PerformTackle(ball, owner)
    local bools = Workspace:FindFirstChild(LocalPlayer.Name) and
                  Workspace[LocalPlayer.Name]:FindFirstChild("Bools")
    if not bools or bools.TackleDebounce.Value or bools.Tackled.Value or
       (Character:FindFirstChild("Bools") and Character.Bools.Debounce.Value) then return end
    local ownerRoot = owner and owner.Character and
                      owner.Character:FindFirstChild("HumanoidRootPart")
    local predictedPos = (ownerRoot and owner)
        and PredictTargetPosition(ownerRoot, owner)
        or  ball.Position
    RotateToTarget(predictedPos)
    if ownerRoot and owner then
        UpdatePredictionBox(ownerRoot, owner)
    end
    if ownerRoot then
        local fv = HumanoidRootPart.Position - ownerRoot.Position
        if _msqrt(fv.X*fv.X + fv.Y*fv.Y + fv.Z*fv.Z) <= 10 then
            pcall(function() firetouchinterest(HumanoidRootPart, ownerRoot, 0) end)
            pcall(function() firetouchinterest(HumanoidRootPart, ownerRoot, 1) end)
        end
    end
    pcall(function() ActionRemote:FireServer("TackIe") end)
    local bv = Instance.new("BodyVelocity")
    bv.Parent   = HumanoidRootPart
    bv.Velocity = HumanoidRootPart.CFrame.LookVector * AutoTackleConfig.TackleSpeed
    bv.MaxForce = _V3new(50000000, 0, 50000000)
    local tStart = _tick()
    local tDur   = 0.65
    local rotConn
    local method = AutoTackleConfig.RotationMethod
    if method == "Always" and ownerRoot and owner then
        rotConn = RunService.Heartbeat:Connect(function()
            if _tick()-tStart < tDur then
                RotateToTarget(PredictTargetPosition(ownerRoot, owner))
            else rotConn:Disconnect() end
        end)
    elseif method == "Legit" and ownerRoot and owner then
        local lockedCF = HumanoidRootPart.CFrame
        rotConn = RunService.Heartbeat:Connect(function()
            if _tick()-tStart < tDur then
                HumanoidRootPart.CFrame = CFrame.new(HumanoidRootPart.Position) *
                    (lockedCF - lockedCF.Position)
            else rotConn:Disconnect() end
        end)
    end
    Debris:AddItem(bv, tDur)
    task.delay(tDur, function()
        if rotConn then rotConn:Disconnect() end
    end)
    if owner and ball:FindFirstChild("playerWeld") then
        local bvec = HumanoidRootPart.Position - ball.Position
        local d = _msqrt(bvec.X*bvec.X + bvec.Y*bvec.Y + bvec.Z*bvec.Z)
        pcall(function() SoftDisPlayerRemote:FireServer(owner, d, false, ball.Size) end)
    end
end

-- ============================================================
-- MANUAL TACKLE
-- ============================================================
local function ManualTackleAction()
    local now = _tick()
    if now - LastManualTackleTime < AutoTackleConfig.ManualTackleCooldown then return false end
    local canT, ball, dist, owner = CanTackle()
    if canT then
        LastManualTackleTime = now
        PerformTackle(ball, owner)
        if Gui and AutoTackleConfig.Enabled then
            Gui.ManualTackleLabel.Text  = "ManualTackle: EXECUTED!"
            Gui.ManualTackleLabel.Color = Color3.fromRGB(0,255,0)
        end
        task.delay(0.3, function()
            if Gui and AutoTackleConfig.Enabled then
                Gui.ManualTackleLabel.Color = Color3.fromRGB(255,255,255)
            end
        end)
        return true
    else
        if Gui and AutoTackleConfig.Enabled then
            Gui.ManualTackleLabel.Text  = "ManualTackle: FAILED"
            Gui.ManualTackleLabel.Color = Color3.fromRGB(255,0,0)
        end
        task.delay(0.3, function()
            if Gui and AutoTackleConfig.Enabled then
                Gui.ManualTackleLabel.Color = Color3.fromRGB(255,255,255)
            end
        end)
        return false
    end
end

-- ============================================================
-- AUTOTACKLE MODULE
-- ============================================================
local AutoTackle = {}

AutoTackle.Start = function()
    if AutoTackleStatus.Running then return end
    AutoTackleStatus.Running = true
    if not Gui then SetupGUI() end

    AutoTackleStatus.HeartbeatConnection = RunService.Heartbeat:Connect(function()
        pcall(UpdatePing)
        pcall(UpdateDribbleStates)
        pcall(PrecomputePlayers)
        pcall(UpdatePlayerESPBoxes)
        IsTypingInChat = CheckIfTypingInChat and CheckIfTypingInChat() or false
    end)

    AutoTackleStatus.InputConnection = UserInputService.InputBegan:Connect(function(inp, gp)
        if gp or not AutoTackleConfig.Enabled or
           not AutoTackleConfig.ManualTackleEnabled then return end
        if IsTypingInChat then return end
        if inp.KeyCode == AutoTackleConfig.ManualTackleKeybind then ManualTackleAction() end
    end)

    AutoTackleStatus.Connection = RunService.Heartbeat:Connect(function()
        if not AutoTackleConfig.Enabled then
            CleanupDebugText(); UpdateDebugVisibility(); return
        end
        pcall(function()
            local canT, ball, dist, owner = CanTackle()
            if not canT or not ball then
                if Gui then
                    Gui.TackleTargetLabel.Text    = "Target: None"
                    Gui.TackleDribblingLabel.Text = "isDribbling: false"
                    Gui.TackleTacklingLabel.Text  = "isTackling: false"
                    Gui.TackleWaitLabel.Text      = "Wait: 0.00"
                    Gui.EagleEyeLabel.Text        = "EagleEye: Idle"
                end
                HideBox3D(Gui and Gui.PredictionBox)
                CurrentTargetOwner = nil
                return
            end
            if Gui then
                Gui.TackleTargetLabel.Text = "Target: " .. (owner and owner.Name or "None")
                Gui.TackleDribblingLabel.Text = "isDribbling: " ..
                    tostring(owner and DribbleStates[owner] and DribbleStates[owner].IsDribbling or false)
                Gui.TackleTacklingLabel.Text = "isTackling: " ..
                    tostring(owner and IsSpecificTackle(owner) or false)
                Gui.PingLabel.Text = string.format("Ping: %dms",
                    _mfloor(AutoTackleStatus.Ping * 1000 + 0.5))
            end
            if owner then
                local oRoot = owner.Character and
                              owner.Character:FindFirstChild("HumanoidRootPart")
                if oRoot then
                    UpdatePredictionBox(oRoot, owner)
                    -- PredictionLabel
                    if Gui and DebugConfig.Enabled then
                        local vel = GetPositionBasedVelocity(owner)
                        local vx, vz = vel.X, vel.Z
                        local op = oRoot.Position
                        local mp = HumanoidRootPart.Position
                        local sx = op.X + vx*AutoTackleStatus.Ping
                        local sz = op.Z + vz*AutoTackleStatus.Ping
                        local dx = sx-mp.X; local dz = sz-mp.Z
                        local d = _msqrt(dx*dx + dz*dz)
                        local iT = CalcInterceptTime(
                            _V3new(mp.X,0,mp.Z), _V3new(sx,0,sz),
                            _V3new(vx,0,vz), AutoTackleConfig.TackleSpeed
                        )
                        Gui.PredictionLabel.Text = string.format(
                            "p=%dms t=%dms d=%.0f",
                            _mfloor(AutoTackleStatus.Ping*1000+0.5),
                            _mfloor(iT*1000+0.5), d
                        )
                    end
                end
            end
            if dist <= AutoTackleConfig.TackleDistance then
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
                    Gui.EagleEyeLabel.Text     = "ManualTackle: Ready"
                    Gui.ManualTackleLabel.Text = "ManualTackle: READY"
                    Gui.ManualTackleLabel.Color= Color3.fromRGB(0,255,0)
                end
                return
            end
            if not owner then return end
            local st = DribbleStates[owner] or {
                IsDribbling=false, LastDribbleEnd=0,
                IsProcessingDelay=false, HadDribble=false
            }
            local isDrib    = st.IsDribbling
            local inCooldown= DribbleCooldownList[owner] ~= nil
            if AutoTackleConfig.Mode == "OnlyDribble" then
                if inCooldown then
                    PerformTackle(ball, owner)
                    if Gui then Gui.EagleEyeLabel.Text = "OnlyDribble: Tackling!" end
                elseif isDrib then
                    if Gui then
                        Gui.EagleEyeLabel.Text   = "OnlyDribble: Dribbling..."
                        Gui.TackleWaitLabel.Text = string.format("DDelay: %.2f",
                            AutoTackleConfig.DribbleDelayTime)
                    end
                elseif st.IsProcessingDelay then
                    local rem = AutoTackleConfig.DribbleDelayTime - (_tick()-st.LastDribbleEnd)
                    if Gui then
                        Gui.EagleEyeLabel.Text   = "OnlyDribble: DribDelay"
                        Gui.TackleWaitLabel.Text = string.format("Wait: %.2f", rem)
                    end
                else
                    if Gui then
                        Gui.EagleEyeLabel.Text   = "OnlyDribble: Waiting dribble"
                        Gui.TackleWaitLabel.Text = "Wait: -"
                    end
                end
            elseif AutoTackleConfig.Mode == "EagleEye" then
                local now = _tick()
                if isDrib then
                    EagleEyeTimers[owner] = nil
                    if Gui then
                        Gui.TackleWaitLabel.Text = "Wait: DRIBBLE"
                        Gui.EagleEyeLabel.Text   = "EagleEye: Dribbling (reset)"
                    end
                elseif st.IsProcessingDelay then
                    EagleEyeTimers[owner] = nil
                    local rem = AutoTackleConfig.DribbleDelayTime - (now-st.LastDribbleEnd)
                    if Gui then
                        Gui.TackleWaitLabel.Text = string.format("DDelay: %.2f", rem)
                        Gui.EagleEyeLabel.Text   = "EagleEye: DribbleDelay"
                    end
                elseif inCooldown then
                    PerformTackle(ball, owner)
                    EagleEyeTimers[owner] = nil
                    if Gui then Gui.EagleEyeLabel.Text = "EagleEye: Post-Dribble Tackle!" end
                else
                    if not EagleEyeTimers[owner] then
                        local w = AutoTackleConfig.EagleEyeMinDelay +
                            math.random()*(AutoTackleConfig.EagleEyeMaxDelay -
                                           AutoTackleConfig.EagleEyeMinDelay)
                        EagleEyeTimers[owner] = {startTime=now, waitTime=w}
                    end
                    local tmr = EagleEyeTimers[owner]
                    local el  = now - tmr.startTime
                    if el >= tmr.waitTime then
                        PerformTackle(ball, owner)
                        EagleEyeTimers[owner] = nil
                        if Gui then Gui.EagleEyeLabel.Text = "EagleEye: Tackling!" end
                    else
                        if Gui then
                            Gui.TackleWaitLabel.Text = string.format("Wait: %.2f",
                                tmr.waitTime - el)
                            Gui.EagleEyeLabel.Text   = "EagleEye: Waiting"
                        end
                    end
                end
            end
        end)
    end)

    UpdateDebugVisibility()
    if notify then notify("AutoTackle", "Started", true) end
end

AutoTackle.Stop = function()
    if AutoTackleStatus.Connection then
        AutoTackleStatus.Connection:Disconnect()
        AutoTackleStatus.Connection = nil
    end
    if AutoTackleStatus.HeartbeatConnection then
        AutoTackleStatus.HeartbeatConnection:Disconnect()
        AutoTackleStatus.HeartbeatConnection = nil
    end
    if AutoTackleStatus.InputConnection then
        AutoTackleStatus.InputConnection:Disconnect()
        AutoTackleStatus.InputConnection = nil
    end
    AutoTackleStatus.Running = false
    CleanupDebugText(); UpdateDebugVisibility()
    if Gui then
        for _, box in pairs(Gui.PlayerBoxes) do HideBox3D(box) end
    end
    if notify then notify("AutoTackle", "Stopped", true) end
end

-- ============================================================
-- AUTODRIBBLE MODULE
-- ============================================================
local _cachedAngleDeg  = -1
local _cachedCosThresh = 0
local function GetCosThreshold()
    if AutoDribbleConfig.MinAngleForDribble ~= _cachedAngleDeg then
        _cachedAngleDeg  = AutoDribbleConfig.MinAngleForDribble
        _cachedCosThresh = _mcos(_mrad(_cachedAngleDeg))
    end
    return _cachedCosThresh
end

-- Smoothing скоростей
local _velocitySmooth = {}
local SMOOTH_ALPHA    = 0.35

local function GetSmoothedVelocity(player, rawVel)
    local prev = _velocitySmooth[player]
    if not prev then _velocitySmooth[player] = rawVel; return rawVel end
    local s = _V3new(
        SMOOTH_ALPHA*rawVel.X + (1-SMOOTH_ALPHA)*prev.X,
        SMOOTH_ALPHA*rawVel.Y + (1-SMOOTH_ALPHA)*prev.Y,
        SMOOTH_ALPHA*rawVel.Z + (1-SMOOTH_ALPHA)*prev.Z
    )
    _velocitySmooth[player] = s
    return s
end

-- ============================================================
-- ShouldDribbleNow — только Free режим
-- Логика:
--   [0] distFlat <= PointBlankRadius + IsTackling → немедленно (без проверок)
--   [1] distFlat <  4 → немедленно
--   [2] distFlat <= DribbleActivationDistance + IsTackling → true
--   [3] дальше: скорость + угол + TTC (мягкий порог 0.4s)
-- ============================================================
local function ShouldDribbleNow(specificTarget, tacklerData)
    if not specificTarget or not tacklerData then return false end
    local tacklerRoot = tacklerData.RootPart
    if not tacklerRoot then return false end

    local serverCF    = GetMyServerCFrame()
    local myServerPos = serverCF.Position
    local msx, msz    = myServerPos.X, myServerPos.Z

    local rawVel  = tacklerData.Velocity
    local velocity= GetSmoothedVelocity(specificTarget, rawVel)
    local vx, vz  = velocity.X, velocity.Z
    local speed2D = _msqrt(vx*vx + vz*vz)

    local tp    = tacklerRoot.Position
    local ping  = AutoTackleStatus.Ping
    local predTx= tp.X + vx*ping*1.5
    local predTz= tp.Z + vz*ping*1.5
    local toMeX = msx - predTx
    local toMeZ = msz - predTz
    local distFlat = _msqrt(toMeX*toMeX + toMeZ*toMeZ)

    if distFlat > AutoDribbleConfig.MaxDribbleDistance then
        if Gui then Gui.AngleLabel.Text = string.format("FAR d=%.1f", distFlat) end
        return false
    end

    -- [0] Point-blank + IsTackling → мгновенно, без всяких проверок
    if distFlat <= AutoDribbleConfig.PointBlankRadius and tacklerData.IsTackling then
        if Gui then
            Gui.AngleLabel.Text = string.format("⚡ PB d=%.1f TACKLE", distFlat)
        end
        return true
    end

    -- [1] Вплотную независимо от такла
    if distFlat < 4 then
        if Gui then Gui.AngleLabel.Text = string.format("⚡ CLOSE d=%.1f", distFlat) end
        return true
    end

    -- [2] Зона активации — только при IsTackling
    if distFlat <= AutoDribbleConfig.DribbleActivationDistance then
        if not tacklerData.IsTackling then
            if Gui then
                Gui.AngleLabel.Text = string.format("CLOSE d=%.1f no tackle", distFlat)
            end
            return false
        end
        if Gui then
            Gui.AngleLabel.Text = string.format("⚡ TACKLE d=%.1f", distFlat)
        end
        return true
    end

    -- [3] Средняя дистанция: скорость + угол + TTC
    if speed2D < 2.0 then
        if Gui then
            Gui.AngleLabel.Text = string.format("v=%.1f slow", speed2D)
        end
        return false
    end

    local invDist  = 1/_mmax(distFlat, 0.001)
    local toMeUX   = toMeX * invDist
    local toMeUZ   = toMeZ * invDist
    local invSpeed = 1/_mmax(speed2D, 0.001)
    local dirVX    = vx * invSpeed
    local dirVZ    = vz * invSpeed
    local dot      = _mclamp(dirVX*toMeUX + dirVZ*toMeUZ, -1, 1)

    if Gui then
        local angleDeg = math.deg(math.acos(dot))
        Gui.AngleLabel.Text = string.format("A=%.0f° v=%.1f d=%.1f", angleDeg, speed2D, distFlat)
    end

    if dot < GetCosThreshold() then return false end

    local approach = vx*toMeUX + vz*toMeUZ
    local myVH     = GetMyVelocityFromHistory()
    local myApp    = -(myVH.X*toMeUX + myVH.Z*toMeUZ)
    local relSpeed = approach + _mmax(myApp, 0)
    if relSpeed < 0.5 then return false end

    local ttc = distFlat / _mmax(relSpeed, 1)
    if Gui then
        Gui.AngleLabel.Text = Gui.AngleLabel.Text .. string.format(" t=%.2f", ttc)
    end

    return ttc < 0.4
end

-- ============================================================
-- PERFORM DRIBBLE
-- ============================================================
local function PerformDribble()
    local now = _tick()
    if now - AutoDribbleStatus.LastDribbleTime < 0.02 then return end
    local bools = Workspace:FindFirstChild(LocalPlayer.Name) and
                  Workspace[LocalPlayer.Name]:FindFirstChild("Bools")
    if not bools or bools.dribbleDebounce.Value then return end
    pcall(function() ActionRemote:FireServer("Deke") end)
    AutoDribbleStatus.LastDribbleTime = now
    if Gui and AutoDribbleConfig.Enabled then
        Gui.DribbleStatusLabel.Text  = "Dribble: Cooldown"
        Gui.DribbleStatusLabel.Color = Color3.fromRGB(255,0,0)
        Gui.AutoDribbleLabel.Text    = "AutoDribble: DEKE!"
    end
end

-- ============================================================
-- AUTODRIBBLE
-- ============================================================
local AutoDribble = {}

local _dribCache = {
    result=false, lastTarget=nil, lastTargetPos=Vector3.zero,
    lastMyPos=Vector3.zero, lastIsTackling=false, lastCalcTime=0,
    INTERVAL=0.008, POS_THRESH=0.15,
}

local function IsCacheDirty(target, data)
    if not target or not data then return true end
    local now = _tick()
    if now - _dribCache.lastCalcTime > _dribCache.INTERVAL then return true end
    if _dribCache.lastTarget ~= target then return true end
    if _dribCache.lastIsTackling ~= data.IsTackling then return true end
    if data.RootPart then
        local cp = _dribCache.lastTargetPos; local rp = data.RootPart.Position
        local dx = rp.X-cp.X; local dz = rp.Z-cp.Z
        if _msqrt(dx*dx + dz*dz) > _dribCache.POS_THRESH then return true end
    end
    local mp = _dribCache.lastMyPos; local hp = HumanoidRootPart.Position
    local mdx = hp.X-mp.X; local mdz = hp.Z-mp.Z
    if _msqrt(mdx*mdx + mdz*mdz) > _dribCache.POS_THRESH then return true end
    return false
end

AutoDribble.Start = function()
    if AutoDribbleStatus.Running then return end
    AutoDribbleStatus.Running = true
    if not Gui then SetupGUI() end

    AutoDribbleStatus.HeartbeatConnection = RunService.Heartbeat:Connect(function()
        if not AutoDribbleConfig.Enabled then return end
        pcall(function()
            UpdatePing()
            UpdateDribbleStates()
            PrecomputePlayers()
            UpdatePlayerESPBoxes()
            RecordMyPosition()
            IsTypingInChat = CheckIfTypingInChat and CheckIfTypingInChat() or false
            UpdateServerPosBox()
        end)
    end)

    AutoDribbleStatus.Connection = RunService.Heartbeat:Connect(function()
        if not AutoDribbleConfig.Enabled then
            CleanupDebugText(); UpdateDebugVisibility(); return
        end
        pcall(function()
            if not HasBall or not CanDribbleNow then
                if Gui then Gui.AutoDribbleLabel.Text = "AutoDribble: Idle" end
                return
            end
            local bestTarget, minDist, targetCount, bestData = nil, math.huge, 0, nil
            for player, data in pairs(PrecomputedPlayers) do
                if data.IsValid and data.IsTackling then
                    targetCount = targetCount + 1
                    if data.Distance < minDist then
                        minDist     = data.Distance
                        bestTarget  = player
                        bestData    = data
                    end
                end
            end
            if Gui then
                Gui.DribbleTargetLabel.Text  = "Targets: " .. targetCount
                Gui.DribbleTacklingLabel.Text= bestTarget
                    and string.format("Tackle: %.1f", minDist) or "Tackle: None"
            end
            if not bestTarget or not bestData then
                if Gui then Gui.AutoDribbleLabel.Text = "AutoDribble: Idle" end
                return
            end
            local shouldFire
            if IsCacheDirty(bestTarget, bestData) then
                shouldFire = ShouldDribbleNow(bestTarget, bestData)
                _dribCache.result        = shouldFire
                _dribCache.lastCalcTime  = _tick()
                _dribCache.lastTarget    = bestTarget
                _dribCache.lastIsTackling= bestData.IsTackling
                if bestData.RootPart then
                    _dribCache.lastTargetPos = bestData.RootPart.Position
                end
                _dribCache.lastMyPos = HumanoidRootPart.Position
            else
                shouldFire = _dribCache.result
            end
            if shouldFire then
                PerformDribble()
            else
                if Gui then Gui.AutoDribbleLabel.Text = "AutoDribble: Waiting" end
            end
        end)
    end)

    UpdateDebugVisibility()
    if notify then notify("AutoDribble", "Started", true) end
end

AutoDribble.Stop = function()
    if AutoDribbleStatus.Connection then
        AutoDribbleStatus.Connection:Disconnect()
        AutoDribbleStatus.Connection = nil
    end
    if AutoDribbleStatus.HeartbeatConnection then
        AutoDribbleStatus.HeartbeatConnection:Disconnect()
        AutoDribbleStatus.HeartbeatConnection = nil
    end
    AutoDribbleStatus.Running = false
    if Gui then
        HideBox3D(Gui.ServerPosBox)
        HideBox3D(Gui.PredictionBox)
        for _, box in pairs(Gui.PlayerBoxes) do HideBox3D(box) end
    end
    CleanupDebugText(); UpdateDebugVisibility()
    if notify then notify("AutoDribble", "Stopped", true) end
end

-- ============================================================
-- UI
-- ============================================================
local uiElements = {}

local function CheckIfTypingInChat()
    local ok, r = pcall(function()
        local pg = LocalPlayer:WaitForChild("PlayerGui")
        for _, g in pairs(pg:GetChildren()) do
            if g:IsA("ScreenGui") and g.Name:find("Chat") then
                local tb = g:FindFirstChild("TextBox", true)
                if tb then return tb:IsFocused() end
            end
        end
        return false
    end)
    return ok and r or false
end

local function UpdatePing()
    local now = _tick()
    if now - AutoTackleStatus.LastPingUpdate > 1 then
        AutoTackleStatus.Ping         = GetPing()
        AutoTackleStatus.LastPingUpdate = now
        if Gui and (AutoTackleConfig.Enabled or AutoDribbleConfig.Enabled) then
            Gui.PingLabel.Text = string.format("Ping: %dms",
                _mfloor(AutoTackleStatus.Ping*1000+0.5))
        end
    end
end

local function SetupUI(UI)
    if UI.Sections.AutoTackle then
        UI.Sections.AutoTackle:Header({Name="AutoTackle"})
        UI.Sections.AutoTackle:Divider()
        uiElements.AutoTackleEnabled = UI.Sections.AutoTackle:Toggle({
            Name="Enabled", Default=AutoTackleConfig.Enabled,
            Callback=function(v)
                AutoTackleConfig.Enabled = v
                if v then AutoTackle.Start() else AutoTackle.Stop() end
                UpdateDebugVisibility()
            end
        }, "AutoTackleEnabled")
        uiElements.AutoTackleMode = UI.Sections.AutoTackle:Dropdown({
            Name="Mode", Default=AutoTackleConfig.Mode,
            Options={"OnlyDribble","EagleEye","ManualTackle"},
            Callback=function(v)
                AutoTackleConfig.Mode = v
                if Gui then Gui.ModeLabel.Text = "Mode: " .. v end
            end
        }, "AutoTackleMode")
        UI.Sections.AutoTackle:Divider()
        UI.Sections.AutoTackle:Slider({
            Name="Max Distance", Minimum=5, Maximum=50,
            Default=AutoTackleConfig.MaxDistance, Precision=1,
            Callback=function(v) AutoTackleConfig.MaxDistance = v end
        }, "AutoTackleMaxDist")
        UI.Sections.AutoTackle:Slider({
            Name="Instant Tackle Distance", Minimum=0, Maximum=20,
            Default=AutoTackleConfig.TackleDistance, Precision=1,
            Callback=function(v) AutoTackleConfig.TackleDistance = v end
        }, "AutoTackleTackleDist")
        UI.Sections.AutoTackle:Slider({
            Name="Tackle Speed", Minimum=10, Maximum=100,
            Default=AutoTackleConfig.TackleSpeed, Precision=1,
            Callback=function(v) AutoTackleConfig.TackleSpeed = v end
        }, "AutoTackleSpeed")
        UI.Sections.AutoTackle:Divider()
        UI.Sections.AutoTackle:Toggle({
            Name="Only Player", Default=AutoTackleConfig.OnlyPlayer,
            Callback=function(v) AutoTackleConfig.OnlyPlayer = v end
        }, "AutoTackleOnlyPlayer")
        UI.Sections.AutoTackle:Dropdown({
            Name="Rotation Method", Default=AutoTackleConfig.RotationMethod,
            Options={"Snap","Legit","Always","None"},
            Callback=function(v) AutoTackleConfig.RotationMethod = v end
        }, "AutoTackleRotation")
        UI.Sections.AutoTackle:Toggle({
            Name="Show Prediction Box", Default=AutoTackleConfig.ShowPredictionBox,
            Callback=function(v)
                AutoTackleConfig.ShowPredictionBox = v
                if not v and Gui then HideBox3D(Gui.PredictionBox) end
            end
        }, "AutoTackleShowPredBox")
        UI.Sections.AutoTackle:Divider()
        UI.Sections.AutoTackle:Slider({
            Name="Dribble Delay", Minimum=0.0, Maximum=2.0,
            Default=AutoTackleConfig.DribbleDelayTime, Precision=2,
            Callback=function(v) AutoTackleConfig.DribbleDelayTime = v end
        }, "AutoTackleDribDelay")
        UI.Sections.AutoTackle:Slider({
            Name="EagleEye Min Delay", Minimum=0.0, Maximum=2.0,
            Default=AutoTackleConfig.EagleEyeMinDelay, Precision=2,
            Callback=function(v) AutoTackleConfig.EagleEyeMinDelay = v end
        }, "AutoTackleEEMin")
        UI.Sections.AutoTackle:Slider({
            Name="EagleEye Max Delay", Minimum=0.0, Maximum=2.0,
            Default=AutoTackleConfig.EagleEyeMaxDelay, Precision=2,
            Callback=function(v) AutoTackleConfig.EagleEyeMaxDelay = v end
        }, "AutoTackleEEMax")
        UI.Sections.AutoTackle:Divider()
        UI.Sections.AutoTackle:Toggle({
            Name="Manual Tackle Enabled", Default=AutoTackleConfig.ManualTackleEnabled,
            Callback=function(v) AutoTackleConfig.ManualTackleEnabled = v end
        }, "AutoTackleManualEnabled")
        UI.Sections.AutoTackle:Keybind({
            Name="Manual Tackle Key",
            Default=AutoTackleConfig.ManualTackleKeybind,
            Callback=function()
                if AutoTackleConfig.Enabled and AutoTackleConfig.ManualTackleEnabled then
                    ManualTackleAction()
                end
            end,
            onBinded=function(v) AutoTackleConfig.ManualTackleKeybind = v end
        }, "AutoTackleManualKey")
    end

    if UI.Sections.AutoDribble then
        UI.Sections.AutoDribble:Header({Name="AutoDribble"})
        UI.Sections.AutoDribble:Divider()
        UI.Sections.AutoDribble:Toggle({
            Name="Enabled", Default=AutoDribbleConfig.Enabled,
            Callback=function(v)
                AutoDribbleConfig.Enabled = v
                if v then AutoDribble.Start() else AutoDribble.Stop() end
                UpdateDebugVisibility()
            end
        }, "AutoDribbleEnabled")
        UI.Sections.AutoDribble:Divider()
        UI.Sections.AutoDribble:Slider({
            Name="Max Distance", Minimum=10, Maximum=50,
            Default=AutoDribbleConfig.MaxDribbleDistance, Precision=1,
            Callback=function(v) AutoDribbleConfig.MaxDribbleDistance = v end
        }, "AutoDribbleMaxDist")
        UI.Sections.AutoDribble:Slider({
            Name="Activation Distance", Minimum=5, Maximum=30,
            Default=AutoDribbleConfig.DribbleActivationDistance, Precision=1,
            Callback=function(v) AutoDribbleConfig.DribbleActivationDistance = v end
        }, "AutoDribbleActDist")
        UI.Sections.AutoDribble:Slider({
            Name="Max Attack Angle", Minimum=10, Maximum=90,
            Default=AutoDribbleConfig.MinAngleForDribble, Precision=0,
            Callback=function(v)
                AutoDribbleConfig.MinAngleForDribble = v
                _cachedAngleDeg = -1
            end
        }, "AutoDribbleAngle")
        UI.Sections.AutoDribble:Slider({
            Name="Point-Blank Radius", Minimum=2, Maximum=15,
            Default=AutoDribbleConfig.PointBlankRadius, Precision=1,
            Callback=function(v) AutoDribbleConfig.PointBlankRadius = v end
        }, "AutoDribblePBRadius")
        UI.Sections.AutoDribble:Toggle({
            Name="Show Server Position Box", Default=AutoDribbleConfig.ShowServerPos,
            Callback=function(v)
                AutoDribbleConfig.ShowServerPos = v
                if not v and Gui then HideBox3D(Gui.ServerPosBox) end
                UpdateDebugVisibility()
            end
        }, "AutoDribbleShowServer")
        UI.Sections.AutoDribble:Divider()
    end

    if UI.Sections.Debug then
        UI.Sections.Debug:Header({Name="Debug"})
        UI.Sections.Debug:SubLabel({Text="* Only for AutoDribble/AutoTackle"})
        UI.Sections.Debug:Divider()
        UI.Sections.Debug:Toggle({
            Name="Debug Text", Default=DebugConfig.Enabled,
            Callback=function(v) DebugConfig.Enabled=v; UpdateDebugVisibility() end
        }, "DebugEnabled")
    end
end

-- ============================================================
-- MODULE INIT
-- ============================================================
local core, Services, PlayerData, notify, LocalPlayerObj

local AutoDribbleTackleModule = {}

function AutoDribbleTackleModule.Init(UI, coreParam, notifyFunc)
    core           = coreParam
    Services       = core.Services
    PlayerData     = core.PlayerData
    notify         = notifyFunc
    LocalPlayerObj = PlayerData.LocalPlayer

    SetupUI(UI)

    LocalPlayerObj.CharacterAdded:Connect(function(newChar)
        task.wait(1)
        Character        = newChar
        Humanoid         = newChar:WaitForChild("Humanoid")
        HumanoidRootPart = newChar:WaitForChild("HumanoidRootPart")
        DribbleStates    = {}; TackleStates = {}; PrecomputedPlayers = {}
        DribbleCooldownList = {}; EagleEyeTimers = {}
        AutoTackleStatus.TargetPositionHistory = {}
        AutoTackleStatus.TargetCircles         = {}
        MyPositionHistory = {}
        _cachedAngleDeg   = -1
        _velocitySmooth   = {}
        CurrentTargetOwner= nil
        if Gui then
            for _, box in pairs(Gui.PlayerBoxes) do RemoveBox3D(box) end
            Gui.PlayerBoxes = {}
        end
        if AutoTackleConfig.Enabled and not AutoTackleStatus.Running then
            AutoTackle.Start()
        end
        if AutoDribbleConfig.Enabled and not AutoDribbleStatus.Running then
            AutoDribble.Start()
        end
    end)
end

function AutoDribbleTackleModule:Destroy()
    AutoTackle.Stop()
    AutoDribble.Stop()
    if Gui then
        RemoveBox3D(Gui.ServerPosBox)
        RemoveBox3D(Gui.PredictionBox)
        for _, box in pairs(Gui.PlayerBoxes) do RemoveBox3D(box) end
    end
end

return AutoDribbleTackleModule
