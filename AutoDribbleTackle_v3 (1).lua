-- [v3.9] AUTO DRIBBLE + AUTO TACKLE
-- Changelog v3.9:
-- - Strict режим полностью переписан: убрана блокировка по IsTackling в стадии 1 для Strict,
--   теперь Strict работает независимо от анимации такла — только физика (угол + TTC + скорость)
--   Free режим: старое поведение (IsTackling обязателен в зоне активации)
-- - Оптимизация: заменены .Magnitude сравнения на Magnitude² (без sqrt) на hot path
--   Vector3 промежуточные объекты убраны в ShouldDribbleNow и PrecomputePlayers
--   GetPositionBasedVelocity: компонентная арифметика без __sub и __div
-- - Box: GetTargetBoxSize() читает реальные размеры тела персонажа через
--   накопление Y-extent всех BasePart в Character, ширину через X/Z extent
--   Результат: BOX_W/H/D = реальные габариты конкретного аватара
-- - CanTackle: добавлена проверка workspace.Bools.Kickoff и workspace.Bools.Penalty
--   если любое из них true — такл запрещён
-- - PredictionBox: показывается всегда когда есть цель (AutoTackle включён),
--   не только в момент вызова PerformTackle. UpdatePredictionBox вызывается
--   в основном Heartbeat loop при наличии owner

-- ============================================================
-- ЛОКАЛИЗАЦИЯ HOT-PATH ФУНКЦИЙ
-- ============================================================
local _mabs    = math.abs
local _mcos    = math.cos
local _mrad    = math.rad
local _mmax    = math.max
local _mmin    = math.min
local _mclamp  = math.clamp
local _msqrt   = math.sqrt
local _mfloor  = math.floor
local _mpi     = math.pi
local _msin    = math.sin
local _tick    = tick
local _V3new   = Vector3.new
local _tinsert = table.insert
local _tremove = table.remove

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")
local Camera            = Workspace.CurrentCamera
local UserInputService  = game:GetService("UserInputService")
local Debris            = game:GetService("Debris")
local Stats             = game:GetService("Stats")

local LocalPlayer        = Players.LocalPlayer
local Character          = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
local HumanoidRootPart   = Character:WaitForChild("HumanoidRootPart")
local Humanoid           = Character:WaitForChild("Humanoid")

local ActionRemote       = ReplicatedStorage.Remotes:WaitForChild("Action")
local SoftDisPlayerRemote= ReplicatedStorage.Remotes:WaitForChild("SoftDisPlayer")
local Animations         = ReplicatedStorage:WaitForChild("Animations")
local DribbleAnims       = Animations:WaitForChild("Dribble")

local DribbleAnimIds = {}
for _, anim in pairs(DribbleAnims:GetChildren()) do
    if anim:IsA("Animation") then
        _tinsert(DribbleAnimIds, anim.AnimationId)
    end
end

-- ============================================================
-- ПИНГ
-- ============================================================
local function GetPing()
    local ok, v = pcall(function()
        local s = Stats.Network.ServerStatsItem["Data Ping"]
        return tonumber(s:GetValueString():match("%d+"))
    end)
    if ok and v then return v / 1000 end
    return 0.1
end

-- ============================================================
-- CONFIG
-- ============================================================
local AutoTackleConfig = {
    Enabled               = false,
    Mode                  = "OnlyDribble", -- "OnlyDribble"|"EagleEye"|"ManualTackle"
    MaxDistance           = 20,
    TackleDistance        = 0,
    TackleSpeed           = 60,
    OnlyPlayer            = true,
    RotationMethod        = "Snap",        -- "Snap"|"Legit"|"Always"|"None"
    DribbleDelayTime      = 0,
    EagleEyeMinDelay      = 0.2,
    EagleEyeMaxDelay      = 0.6,
    ManualTackleEnabled   = true,
    ManualTackleKeybind   = Enum.KeyCode.Q,
    ManualTackleCooldown  = 0.5,
    ShowPredictionBox     = true,  -- v3.9: всегда по умолчанию true
}

local AutoDribbleConfig = {
    Enabled                  = false,
    MaxDribbleDistance       = 30,
    DribbleActivationDistance= 17,
    MinAngleForDribble       = 32,
    ShowServerPos            = false,
    DribbleMode              = "Free",  -- "Free"|"Strict"
}

local DebugConfig = {
    Enabled     = false,
    MoveEnabled = false,
}

-- ============================================================
-- STATES
-- ============================================================
local AutoTackleStatus = {
    Running = false, Connection = nil, HeartbeatConnection = nil, InputConnection = nil,
    Ping = 0.1, LastPingUpdate = 0,
    TargetPositionHistory = {}, TargetCircles = {}
}
local AutoDribbleStatus = { Running = false, Connection = nil, HeartbeatConnection = nil, LastDribbleTime = 0 }

local DribbleStates     = {}
local TackleStates      = {}
local PrecomputedPlayers= {}
local HasBall           = false
local CanDribbleNow     = false
local DribbleCooldownList= {}
local EagleEyeTimers    = {}
local IsTypingInChat    = false
local LastManualTackleTime = 0
local CurrentTargetOwner= nil

local SPECIFIC_TACKLE_ID = "rbxassetid://14317040670"

-- ============================================================
-- ИСТОРИЯ ПОЗИЦИЙ ЦЕЛИ
-- ============================================================
local HISTORY_SIZE   = 12
local HISTORY_WINDOW = 0.12

local function RecordTargetPosition(ownerRoot, player)
    local h = AutoTackleStatus.TargetPositionHistory[player]
    if not h then h = {}; AutoTackleStatus.TargetPositionHistory[player] = h end
    local pos = ownerRoot.Position
    _tinsert(h, { time = _tick(), pos = pos })
    while #h > HISTORY_SIZE do _tremove(h, 1) end
end

-- v3.9: компонентная арифметика, без Vector3 __sub и __div
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
        if #h >= 2 then oldest = h[#h-1]; newest = h[#h]
        else return Vector3.zero end
    end
    local dt = newest.time - oldest.time
    if dt < 0.001 then return Vector3.zero end
    local inv = 1 / dt
    local op, np = oldest.pos, newest.pos
    return _V3new((np.X-op.X)*inv, (np.Y-op.Y)*inv, (np.Z-op.Z)*inv)
end

-- v3.9: компонентная квадратичная формула, без Vector3 операторов
local function CalcInterceptTime(fx, fz, tx, tz, vx, vz, speed)
    local dx = tx - fx; local dz = tz - fz
    local dist2 = dx*dx + dz*dz
    if dist2 < 0.0001 then return 0 end
    local dist = _msqrt(dist2)
    local v2   = vx*vx + vz*vz
    local ts2  = speed * speed
    local dotDV= dx*vx + dz*vz
    local a = ts2 - v2
    local b = -2 * dotDV
    local c = -dist2
    local t
    if _mabs(a) < 0.001 then
        t = (_mabs(b) > 0.001) and (-c/b) or (dist/_mmax(speed,1))
    else
        local disc = b*b - 4*a*c
        if disc < 0 then
            t = dist / _mmax(speed, 1)
        else
            local sq = _msqrt(disc)
            local t1 = (-b - sq) / (2*a)
            local t2 = (-b + sq) / (2*a)
            if   t1 > 0 and t2 > 0 then t = _mmin(t1, t2)
            elseif t1 > 0          then t = t1
            elseif t2 > 0          then t = t2
            else                        t = dist / _mmax(speed,1) end
        end
    end
    return _mclamp(t, 0.02, 0.5)
end

local function PredictTargetPosition(ownerRoot, player)
    if not ownerRoot then return ownerRoot.Position end
    local ping = AutoTackleStatus.Ping
    local vel  = GetPositionBasedVelocity(player)
    local vx, vz = vel.X, vel.Z
    local op = ownerRoot.Position
    local sx = op.X + vx * ping
    local sz = op.Z + vz * ping
    local mp  = HumanoidRootPart.Position
    local it  = CalcInterceptTime(mp.X, mp.Z, sx, sz, vx, vz, AutoTackleConfig.TackleSpeed)
    return _V3new(sx + vx*it, op.Y, sz + vz*it)
end

local function UpdatePredictionLabel(ownerRoot, player)
    if not Gui or not DebugConfig.Enabled or not AutoTackleConfig.Enabled then return end
    if not ownerRoot or not player then
        Gui.PredictionLabel.Text = "Pred: no target"; return
    end
    local ping = AutoTackleStatus.Ping
    local vel  = GetPositionBasedVelocity(player)
    local vx, vz = vel.X, vel.Z
    local op  = ownerRoot.Position
    local sx  = op.X + vx*ping; local sz = op.Z + vz*ping
    local mp  = HumanoidRootPart.Position
    local dx  = sx - mp.X; local dz = sz - mp.Z
    local dist= _msqrt(dx*dx + dz*dz)
    local it  = CalcInterceptTime(mp.X, mp.Z, sx, sz, vx, vz, AutoTackleConfig.TackleSpeed)
    local spd = _msqrt(vx*vx + vz*vz)
    Gui.PredictionLabel.Text = string.format("p=%dms t=%dms v=%.0f d=%.0f",
        _mfloor(ping*1000+0.5), _mfloor(it*1000+0.5), spd, dist)
end

local function UpdatePing()
    local t = _tick()
    if t - AutoTackleStatus.LastPingUpdate > 1 then
        AutoTackleStatus.Ping = GetPing()
        AutoTackleStatus.LastPingUpdate = t
        if Gui and AutoTackleConfig.Enabled then
            Gui.PingLabel.Text = string.format("Ping: %dms", _mfloor(AutoTackleStatus.Ping*1000+0.5))
        end
    end
end

-- ============================================================
-- МОЯ ИСТОРИЯ ПОЗИЦИЙ
-- ============================================================
local MY_HISTORY_SIZE = 10
local MyPositionHistory = {}

local function RecordMyPosition()
    _tinsert(MyPositionHistory, { time = _tick(), cframe = HumanoidRootPart.CFrame })
    while #MyPositionHistory > MY_HISTORY_SIZE do _tremove(MyPositionHistory, 1) end
end

local function GetMyVelocityFromHistory()
    if #MyPositionHistory < 2 then return Vector3.zero end
    local o = MyPositionHistory[1]; local n = MyPositionHistory[#MyPositionHistory]
    local dt = n.time - o.time
    if dt < 0.001 then return Vector3.zero end
    local inv = 1 / dt
    local op, np = o.cframe.Position, n.cframe.Position
    return _V3new((np.X-op.X)*inv, (np.Y-op.Y)*inv, (np.Z-op.Z)*inv)
end

local function GetMyServerCFrame()
    local nd  = AutoTackleStatus.Ping * 1.5
    local vel = GetMyVelocityFromHistory()
    local p   = HumanoidRootPart.Position
    local sp  = _V3new(p.X - vel.X*nd, p.Y - vel.Y*nd, p.Z - vel.Z*nd)
    return CFrame.new(sp) * (HumanoidRootPart.CFrame - HumanoidRootPart.CFrame.Position)
end

-- ============================================================
-- v3.9: BOX — РЕАЛЬНЫЕ ГАБАРИТЫ ПЕРСОНАЖА
-- Читаем реальный extent через все BasePart в Character
-- Результат: W/H/D точно равны размеру конкретного аватара
-- ============================================================
local _boxCache = {}  -- player -> {W, H, D, lastUpdate}
local BOX_CACHE_TTL = 3.0  -- пересчёт раз в 3 секунды

local function GetTargetBoxSize(character)
    if not character then return 2.0, 5.5, 2.0 end
    local cached = _boxCache[character]
    if cached and (_tick() - cached.t < BOX_CACHE_TTL) then
        return cached.W, cached.H, cached.D
    end

    local minX, minY, minZ =  math.huge,  math.huge,  math.huge
    local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge

    local hrp = character:FindFirstChild("HumanoidRootPart")
    if not hrp then return 2.0, 5.5, 2.0 end
    local hrpCF = hrp.CFrame  -- используем CFrame HRP как ориентацию

    -- Части тела которые учитываем (R15 стандарт + кастомные)
    local BODY_PARTS = {
        "HumanoidRootPart", "UpperTorso", "LowerTorso",
        "Head",
        "LeftUpperArm", "LeftLowerArm", "LeftHand",
        "RightUpperArm", "RightLowerArm", "RightHand",
        "LeftUpperLeg", "LeftLowerLeg", "LeftFoot",   -- v3.9: LeftLowerLeg + LeftFoot включены
        "RightUpperLeg", "RightLowerLeg", "RightFoot", -- v3.9: RightLowerLeg + RightFoot включены
    }

    local hasAny = false
    for _, partName in ipairs(BODY_PARTS) do
        local part = character:FindFirstChild(partName)
        if part and part:IsA("BasePart") then
            hasAny = true
            -- Переводим углы части в локальное пространство HRP
            local localCF = hrpCF:ToObjectSpace(part.CFrame)
            local lp = localCF.Position
            local sz = part.Size
            local hsx, hsy, hsz = sz.X*0.5, sz.Y*0.5, sz.Z*0.5

            -- Учитываем поворот части: проецируем все 8 углов AABB в локальное пространство
            local rx = localCF.RightVector
            local uy = localCF.UpVector
            local fz = localCF.LookVector

            -- XYZ экстенты в локальном пространстве HRP
            local ex = _mabs(rx.X)*hsx + _mabs(uy.X)*hsy + _mabs(fz.X)*hsz
            local ey = _mabs(rx.Y)*hsx + _mabs(uy.Y)*hsy + _mabs(fz.Y)*hsz
            local ez = _mabs(rx.Z)*hsx + _mabs(uy.Z)*hsy + _mabs(fz.Z)*hsz

            if lp.X - ex < minX then minX = lp.X - ex end
            if lp.X + ex > maxX then maxX = lp.X + ex end
            if lp.Y - ey < minY then minY = lp.Y - ey end
            if lp.Y + ey > maxY then maxY = lp.Y + ey end
            if lp.Z - ez < minZ then minZ = lp.Z - ez end
            if lp.Z + ez > maxZ then maxZ = lp.Z + ez end
        end
    end

    if not hasAny then return 2.0, 5.5, 2.0 end

    local W = _mmax(maxX - minX, 0.5)
    local H = _mmax(maxY - minY, 0.5)
    local D = _mmax(maxZ - minZ, 0.5)

    -- Центр box в локальном пространстве HRP (offsetY = смещение центра)
    local centerY = (minY + maxY) * 0.5

    _boxCache[character] = { W=W, H=H, D=D, centerY=centerY, t=_tick() }
    return W, H, D
end

-- Возвращает offsetY для конкретного персонажа (смещение центра box от HRP)
local function GetBoxCenterOffset(character)
    if not character then return 0 end
    local cached = _boxCache[character]
    if cached and (_tick() - cached.t < BOX_CACHE_TTL) then
        return cached.centerY or 0
    end
    GetTargetBoxSize(character)  -- заполняет кэш
    local c = _boxCache[character]
    return c and c.centerY or 0
end

local BOX_EDGES = {
    {1,2},{2,3},{3,4},{4,1},
    {5,6},{6,7},{7,8},{8,5},
    {1,5},{2,6},{3,7},{4,8},
}

local function CreateBoxLines(color, thickness)
    local lines = {}
    for i = 1, 12 do
        local line = Drawing.new("Line")
        line.Color     = color or Color3.fromRGB(0,200,255)
        line.Thickness = thickness or 1.5
        line.Visible   = false
        _tinsert(lines, line)
    end
    return lines
end

-- v3.9: GetBoxCorners принимает W/H/D явно
local function GetBoxCorners(cf, W, H, D, offsetY)
    local o  = offsetY or 0
    local hW, hH, hD = W*0.5, H*0.5, D*0.5
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

local function UpdateBoxLines(lines, cf, W, H, D, offsetY, color)
    if not lines then return end
    local corners = GetBoxCorners(cf, W, H, D, offsetY)
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
        TargetRingLines      = {},
        ServerPosBoxLines    = nil,
        PredictionBoxLines   = nil,
        TackleDebugLabels    = {},
        DribbleDebugLabels   = {},
    }

    Gui.ServerPosBoxLines  = CreateBoxLines(Color3.fromRGB(0,200,255), 1.5)
    Gui.PredictionBoxLines = CreateBoxLines(Color3.fromRGB(255,165,0), 1.5)

    local sv     = Camera.ViewportSize
    local cx     = sv.X / 2
    local ty     = sv.Y * 0.6
    local oTY    = ty + 30
    local oDY    = ty - 50

    local tackleLabels = {
        Gui.TackleWaitLabel, Gui.TackleTargetLabel, Gui.TackleDribblingLabel,
        Gui.TackleTacklingLabel, Gui.EagleEyeLabel, Gui.CooldownListLabel,
        Gui.ModeLabel, Gui.ManualTackleLabel, Gui.PingLabel,
        Gui.AngleLabel, Gui.PredictionLabel, Gui.ServerPosLabel,
    }
    for _, lbl in ipairs(tackleLabels) do
        lbl.Size = 16; lbl.Color = Color3.fromRGB(255,255,255)
        lbl.Outline = true; lbl.Center = true
        lbl.Visible = DebugConfig.Enabled and AutoTackleConfig.Enabled
        _tinsert(Gui.TackleDebugLabels, lbl)
    end
    Gui.TackleWaitLabel.Color = Color3.fromRGB(255,165,0)
    Gui.ServerPosLabel.Color  = Color3.fromRGB(0,200,255)

    for _, lbl in ipairs({Gui.TackleWaitLabel,Gui.TackleTargetLabel,Gui.TackleDribblingLabel,
                          Gui.TackleTacklingLabel,Gui.EagleEyeLabel,Gui.CooldownListLabel,
                          Gui.ModeLabel,Gui.ManualTackleLabel,Gui.PingLabel,
                          Gui.AngleLabel,Gui.PredictionLabel,Gui.ServerPosLabel}) do
        lbl.Position = Vector2.new(cx, oTY); oTY = oTY + 15
    end

    local dribbleLabels = {
        Gui.DribbleStatusLabel, Gui.DribbleTargetLabel,
        Gui.DribbleTacklingLabel, Gui.AutoDribbleLabel,
    }
    for _, lbl in ipairs(dribbleLabels) do
        lbl.Size = 16; lbl.Color = Color3.fromRGB(255,255,255)
        lbl.Outline = true; lbl.Center = true
        lbl.Visible = DebugConfig.Enabled and AutoDribbleConfig.Enabled
        _tinsert(Gui.DribbleDebugLabels, lbl)
    end
    for _, lbl in ipairs(dribbleLabels) do
        lbl.Position = Vector2.new(cx, oDY); oDY = oDY + 15
    end

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
    Gui.PredictionLabel.Text      = "Pred: 0ms"
    Gui.ServerPosLabel.Text       = "ServerPos: -"
    Gui.DribbleStatusLabel.Text   = "Dribble: Ready"
    Gui.DribbleTargetLabel.Text   = "Targets: 0"
    Gui.DribbleTacklingLabel.Text = "Nearest: None"
    Gui.AutoDribbleLabel.Text     = "AutoDribble: Idle"

    for i = 1, 24 do
        local line = Drawing.new("Line")
        line.Thickness = 3; line.Color = Color3.fromRGB(255,0,0); line.Visible = false
        _tinsert(Gui.TargetRingLines, line)
    end
end

-- ============================================================
-- v3.9: UpdateServerPosBox — реальный размер моего персонажа
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
    local W, H, D   = GetTargetBoxSize(Character)
    local offY      = GetBoxCenterOffset(Character)
    UpdateBoxLines(Gui.ServerPosBoxLines, serverCF, W, H, D, offY, Color3.fromRGB(0,200,255))
    if Gui.ServerPosLabel and DebugConfig.Enabled then
        local delay = _mfloor(AutoTackleStatus.Ping * 1.5 * 1000 + 0.5)
        local dv    = serverPos - HumanoidRootPart.Position
        local dist  = _msqrt(dv.X*dv.X + dv.Y*dv.Y + dv.Z*dv.Z)
        Gui.ServerPosLabel.Text = string.format("ServerPos: %dms | %.1f studs", delay, dist)
    end
end

-- ============================================================
-- v3.9: UpdatePredictionBox — ВСЕГДА видимый при наличии цели
-- Вызывается каждый кадр в основном loop, не только в PerformTackle
-- ============================================================
local function UpdatePredictionBox(ownerRoot, player, targetCharacter)
    if not Gui or not Gui.PredictionBoxLines then return end
    if not AutoTackleConfig.Enabled or not AutoTackleConfig.ShowPredictionBox then
        HideBoxLines(Gui.PredictionBoxLines); return
    end
    if not ownerRoot or not player then
        HideBoxLines(Gui.PredictionBoxLines); return
    end
    local predictedPos = PredictTargetPosition(ownerRoot, player)
    local predictedCF  = CFrame.new(predictedPos)
    local W, H, D = GetTargetBoxSize(targetCharacter)
    local offY    = GetBoxCenterOffset(targetCharacter)
    UpdateBoxLines(Gui.PredictionBoxLines, predictedCF, W, H, D, offY, Color3.fromRGB(255,165,0))
end

local function UpdateDebugVisibility()
    if not Gui then return end
    local tv = DebugConfig.Enabled and AutoTackleConfig.Enabled
    for _, lbl in ipairs(Gui.TackleDebugLabels) do lbl.Visible = tv end
    local dv = DebugConfig.Enabled and AutoDribbleConfig.Enabled
    for _, lbl in ipairs(Gui.DribbleDebugLabels) do lbl.Visible = dv end
    if not AutoTackleConfig.Enabled then
        for _, ln in ipairs(Gui.TargetRingLines) do ln.Visible = false end
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
        Gui.ManualTackleLabel.Text    = "ManualTackle: Ready"
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

-- ============================================================
-- 3D КРУГИ
-- ============================================================
local function Create3DCircle()
    local c = {}
    for i = 1, 24 do
        local ln = Drawing.new("Line")
        ln.Thickness = 3; ln.Color = Color3.fromRGB(255,0,0); ln.Visible = false
        _tinsert(c, ln)
    end
    return c
end

local function Update3DCircle(circle, position, radius, color)
    if not circle then return end
    local n   = #circle
    local px, pz, py = position.X, position.Z, position.Y
    local inv = (2 * _mpi) / n
    local pts = {}
    for i = 1, n do
        local a = (i-1) * inv
        _tinsert(pts, _V3new(px + _mcos(a)*radius, py, pz + _msin(a)*radius))
    end
    for i, ln in ipairs(circle) do
        local sp = pts[i]; local ep = pts[i % n + 1]
        local ss, sOn = Camera:WorldToViewportPoint(sp)
        local es, eOn = Camera:WorldToViewportPoint(ep)
        if sOn and eOn and ss.Z > 0.1 and es.Z > 0.1 then
            ln.From = Vector2.new(ss.X,ss.Y); ln.To = Vector2.new(es.X,es.Y)
            ln.Color = color; ln.Visible = true
        else
            ln.Visible = false
        end
    end
end

local function Hide3DCircle(circle)
    if not circle then return end
    for _, ln in ipairs(circle) do ln.Visible = false end
end

local function UpdateTargetCircles()
    local cur = {}
    for player, data in pairs(PrecomputedPlayers) do
        if data.IsValid and TackleStates[player] and TackleStates[player].IsTackling then
            cur[player] = true
            if not AutoTackleStatus.TargetCircles[player] then
                AutoTackleStatus.TargetCircles[player] = Create3DCircle()
            end
            local tr = data.RootPart
            if tr then
                local d = data.Distance
                local col = d <= AutoDribbleConfig.DribbleActivationDistance
                    and Color3.fromRGB(0,255,0)
                    or (d <= AutoDribbleConfig.MaxDribbleDistance
                        and Color3.fromRGB(255,165,0)
                        or Color3.fromRGB(255,0,0))
                Update3DCircle(AutoTackleStatus.TargetCircles[player],
                    tr.Position - _V3new(0,0.5,0), 2, col)
            end
        end
    end
    for player, circle in pairs(AutoTackleStatus.TargetCircles) do
        if not cur[player] then Hide3DCircle(circle) end
    end
end

-- ============================================================
-- DEBUG ПЕРЕМЕЩЕНИЕ
-- ============================================================
local function SetupDebugMovement()
    if not DebugConfig.MoveEnabled or not Gui then return end
    local dragging = false; local dragStart = Vector2.new(0,0)
    local startPos = {}
    for _, lbl in ipairs(Gui.TackleDebugLabels) do startPos[lbl] = lbl.Position end
    for _, lbl in ipairs(Gui.DribbleDebugLabels) do startPos[lbl] = lbl.Position end
    local function upd(delta)
        for lbl, sp in pairs(startPos) do
            if lbl.Visible then lbl.Position = sp + delta end
        end
    end
    UserInputService.InputBegan:Connect(function(inp, gp)
        if gp or not DebugConfig.MoveEnabled then return end
        if inp.UserInputType == Enum.UserInputType.MouseButton1 then
            local mp = UserInputService:GetMouseLocation()
            for lbl in pairs(startPos) do
                if lbl.Visible then
                    local pos = lbl.Position; local tb = lbl.TextBounds
                    if mp.X >= pos.X - tb.X*0.5 and mp.X <= pos.X + tb.X*0.5 and
                       mp.Y >= pos.Y - tb.Y*0.5 and mp.Y <= pos.Y + tb.Y*0.5 then
                        dragging = true; dragStart = mp; break
                    end
                end
            end
        end
    end)
    UserInputService.InputChanged:Connect(function(inp, gp)
        if gp or not dragging then return end
        if inp.UserInputType == Enum.UserInputType.MouseMovement then
            upd(UserInputService:GetMouseLocation() - dragStart)
        end
    end)
    UserInputService.InputEnded:Connect(function(inp, gp)
        if gp then return end
        if inp.UserInputType == Enum.UserInputType.MouseButton1 and dragging then
            local delta = UserInputService:GetMouseLocation() - dragStart
            for lbl, sp in pairs(startPos) do startPos[lbl] = sp + delta end
            dragging = false
        end
    end)
end

local function CheckIfTypingInChat()
    local ok, res = pcall(function()
        local pg = LocalPlayer:WaitForChild("PlayerGui")
        for _, gui in pairs(pg:GetChildren()) do
            if gui:IsA("ScreenGui") and (gui.Name == "Chat" or gui.Name:find("Chat")) then
                local tb = gui:FindFirstChild("TextBox", true)
                if tb then return tb:IsFocused() end
            end
        end
        return false
    end)
    return ok and res or false
end

-- ============================================================
-- ПРОВЕРКИ СОСТОЯНИЙ ИГРОКОВ
-- ============================================================
local function IsDribbling(targetPlayer)
    if not targetPlayer or not targetPlayer.Character or not targetPlayer.Parent
    or targetPlayer.TeamColor == LocalPlayer.TeamColor then return false end
    local hum = targetPlayer.Character:FindFirstChild("Humanoid")
    if not hum then return false end
    local anim = hum:FindFirstChild("Animator")
    if not anim then return false end
    for _, track in pairs(anim:GetPlayingAnimationTracks()) do
        if track.Animation and table.find(DribbleAnimIds, track.Animation.AnimationId) then
            return true
        end
    end
    return false
end

local function IsSpecificTackle(targetPlayer)
    if not targetPlayer or not targetPlayer.Character or not targetPlayer.Parent
    or targetPlayer.TeamColor == LocalPlayer.TeamColor then return false end
    local hum = targetPlayer.Character:FindFirstChild("Humanoid")
    if not hum then return false end
    local anim = hum:FindFirstChild("Animator")
    if not anim then return false end
    for _, track in pairs(anim:GetPlayingAnimationTracks()) do
        if track.Animation and track.Animation.AnimationId == SPECIFIC_TACKLE_ID then
            return true
        end
    end
    return false
end

local function IsPowerShooting(targetPlayer)
    if not targetPlayer then return false end
    local pf = Workspace:FindFirstChild(targetPlayer.Name)
    if not pf then return false end
    local bools = pf:FindFirstChild("Bools")
    if not bools then return false end
    local ps = bools:FindFirstChild("PowerShooting")
    return ps and ps.Value == true
end

-- ============================================================
-- DRIBBLE STATES
-- ============================================================
local function UpdateDribbleStates()
    local now = _tick()
    for _, player in pairs(Players:GetPlayers()) do
        if player == LocalPlayer or not player.Parent
        or player.TeamColor == LocalPlayer.TeamColor then continue end
        if not DribbleStates[player] then
            DribbleStates[player] = {
                IsDribbling = false, LastDribbleEnd = 0,
                IsProcessingDelay = false, HadDribble = false
            }
        end
        local st = DribbleStates[player]
        local dn = IsDribbling(player)
        if dn and not st.IsDribbling then
            st.IsDribbling = true; st.IsProcessingDelay = false; st.HadDribble = true
        elseif not dn and st.IsDribbling then
            st.IsDribbling = false; st.LastDribbleEnd = now; st.IsProcessingDelay = true
        elseif st.IsProcessingDelay and not dn then
            if now - st.LastDribbleEnd >= AutoTackleConfig.DribbleDelayTime then
                DribbleCooldownList[player] = now + 3.5
                st.IsProcessingDelay = false
            end
        end
    end
    local toRm = {}
    for player, endT in pairs(DribbleCooldownList) do
        if not player or not player.Parent or now >= endT then _tinsert(toRm, player) end
    end
    for _, p in ipairs(toRm) do
        DribbleCooldownList[p] = nil; EagleEyeTimers[p] = nil
    end
    if Gui and AutoTackleConfig.Enabled then
        local cnt = 0; for _ in pairs(DribbleCooldownList) do cnt = cnt + 1 end
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
    local bools = Workspace:FindFirstChild(LocalPlayer.Name)
        and Workspace[LocalPlayer.Name]:FindFirstChild("Bools")
    if bools then
        CanDribbleNow = not bools.dribbleDebounce.Value
        if Gui and AutoDribbleConfig.Enabled then
            local cd = bools.dribbleDebounce.Value
            Gui.DribbleStatusLabel.Text  = cd and "Dribble: Cooldown" or "Dribble: Ready"
            Gui.DribbleStatusLabel.Color = cd and Color3.fromRGB(255,0,0) or Color3.fromRGB(0,255,0)
        end
    end
    local mp = HumanoidRootPart.Position
    local mpx, mpy, mpz = mp.X, mp.Y, mp.Z
    for _, player in pairs(Players:GetPlayers()) do
        if player == LocalPlayer or not player.Parent
        or player.TeamColor == LocalPlayer.TeamColor then continue end
        local char = player.Character
        if not char then continue end
        local hum = char:FindFirstChild("Humanoid")
        if not hum or hum.HipHeight >= 4 then continue end
        local root = char:FindFirstChild("HumanoidRootPart")
        if not root then continue end
        TackleStates[player] = TackleStates[player] or { IsTackling = false }
        TackleStates[player].IsTackling = IsSpecificTackle(player)
        local rp = root.Position
        -- v3.9: Magnitude² сравнение без sqrt для дистанции > MaxDribble
        local dx = rp.X - mpx; local dy = rp.Y - mpy; local dz = rp.Z - mpz
        local dist2 = dx*dx + dy*dy + dz*dz
        local maxD  = AutoDribbleConfig.MaxDribbleDistance
        if dist2 > maxD * maxD then continue end
        local distance = _msqrt(dist2)
        local alv    = root.AssemblyLinearVelocity
        local posVel = GetPositionBasedVelocity(player)
        -- v3.9: сравниваем величины без Magnitude вызова через Magnitude²
        local alvMag2 = alv.X*alv.X + alv.Y*alv.Y + alv.Z*alv.Z
        local pvMag2  = posVel.X*posVel.X + posVel.Y*posVel.Y + posVel.Z*posVel.Z
        local velocity = alvMag2 >= pvMag2 and alv or posVel
        PrecomputedPlayers[player] = {
            Distance  = distance,
            IsValid   = true,
            IsTackling= TackleStates[player].IsTackling,
            RootPart  = root,
            Character = char,   -- v3.9: передаём character для GetTargetBoxSize
            Velocity  = velocity,
        }
        if dist2 <= (AutoDribbleConfig.DribbleActivationDistance * 1.5)^2 then
            RecordTargetPosition(root, player)
        end
    end
end

-- ============================================================
-- РОТАЦИЯ
-- ============================================================
local function RotateToTarget(targetPos)
    if AutoTackleConfig.RotationMethod == "None" then return end
    local mp = HumanoidRootPart.Position
    local dx = targetPos.X - mp.X; local dz = targetPos.Z - mp.Z
    if dx*dx + dz*dz > 0.01 then
        HumanoidRootPart.CFrame = CFrame.new(mp, mp + _V3new(dx, 0, dz))
    end
end

-- ============================================================
-- v3.9: CanTackle — добавлены Kickoff и Penalty проверки
-- ============================================================
local function CanTackle()
    local ball = Workspace:FindFirstChild("ball")
    if not ball or not ball.Parent then return false, nil, nil, nil end

    -- v3.9: проверка Kickoff и Penalty
    local wBools = Workspace:FindFirstChild("Bools")
    if wBools then
        local kickoff = wBools:FindFirstChild("Kickoff")
        local penalty = wBools:FindFirstChild("Penalty")
        if (kickoff and kickoff.Value == true) or (penalty and penalty.Value == true) then
            if Gui and AutoTackleConfig.Enabled then
                Gui.EagleEyeLabel.Text = kickoff and kickoff.Value == true
                    and "BLOCKED: Kickoff" or "BLOCKED: Penalty"
            end
            return false, nil, nil, nil
        end
    end

    local hasOwner = ball:FindFirstChild("playerWeld") and ball:FindFirstChild("creator")
    local owner    = hasOwner and ball.creator.Value or nil
    if AutoTackleConfig.OnlyPlayer and (not hasOwner or not owner or not owner.Parent) then
        return false, nil, nil, nil
    end
    local isEnemy = not owner or (owner and owner.TeamColor ~= LocalPlayer.TeamColor)
    if not isEnemy then return false, nil, nil, nil end
    if wBools and (wBools.APG.Value == LocalPlayer or wBools.HPG.Value == LocalPlayer) then
        return false, nil, nil, nil
    end
    local bp = HumanoidRootPart.Position - ball.Position
    local dist2 = bp.X*bp.X + bp.Y*bp.Y + bp.Z*bp.Z
    if dist2 > AutoTackleConfig.MaxDistance * AutoTackleConfig.MaxDistance then
        return false, nil, nil, nil
    end
    local distance = _msqrt(dist2)
    if owner and owner.Character then
        local th = owner.Character:FindFirstChild("Humanoid")
        if th and th.HipHeight >= 4 then return false, nil, nil, nil end
    end
    local myBools = Workspace:FindFirstChild(LocalPlayer.Name)
        and Workspace[LocalPlayer.Name]:FindFirstChild("Bools")
    if myBools and (myBools.TackleDebounce.Value or myBools.Tackled.Value
    or (Character:FindFirstChild("Bools") and Character.Bools.Debounce.Value)) then
        return false, nil, nil, nil
    end
    return true, ball, distance, owner
end

-- ============================================================
-- PERFORM TACKLE
-- ============================================================
local function PerformTackle(ball, owner)
    local myBools = Workspace:FindFirstChild(LocalPlayer.Name)
        and Workspace[LocalPlayer.Name]:FindFirstChild("Bools")
    if not myBools or myBools.TackleDebounce.Value or myBools.Tackled.Value
    or (Character:FindFirstChild("Bools") and Character.Bools.Debounce.Value) then return end

    local ownerRoot = owner and owner.Character
        and owner.Character:FindFirstChild("HumanoidRootPart")
    local predictedPos = ownerRoot and PredictTargetPosition(ownerRoot, owner) or ball.Position
    RotateToTarget(predictedPos)

    if ownerRoot then
        local fv = HumanoidRootPart.Position - ownerRoot.Position
        if fv.X*fv.X + fv.Y*fv.Y + fv.Z*fv.Z <= 100 then
            pcall(function() firetouchinterest(HumanoidRootPart, ownerRoot, 0) end)
            pcall(function() firetouchinterest(HumanoidRootPart, ownerRoot, 1) end)
        end
    end
    pcall(function() ActionRemote:FireServer("TackIe") end)

    local bv = Instance.new("BodyVelocity")
    bv.Parent   = HumanoidRootPart
    bv.Velocity = HumanoidRootPart.CFrame.LookVector * AutoTackleConfig.TackleSpeed
    bv.MaxForce = _V3new(50000000, 0, 50000000)

    local tStart    = _tick()
    local tDuration = 0.65
    local rotConn

    if AutoTackleConfig.RotationMethod == "Always" and ownerRoot and owner then
        rotConn = RunService.Heartbeat:Connect(function()
            if _tick() - tStart < tDuration then
                RotateToTarget(PredictTargetPosition(ownerRoot, owner))
            else rotConn:Disconnect() end
        end)
    elseif AutoTackleConfig.RotationMethod == "Legit" and ownerRoot and owner then
        local lockedCF = HumanoidRootPart.CFrame
        rotConn = RunService.Heartbeat:Connect(function()
            if _tick() - tStart < tDuration then
                HumanoidRootPart.CFrame = CFrame.new(HumanoidRootPart.Position)
                    * (lockedCF - lockedCF.Position)
            else rotConn:Disconnect() end
        end)
    end

    Debris:AddItem(bv, tDuration)
    task.delay(tDuration, function()
        if rotConn then rotConn:Disconnect() end
    end)

    if owner and ball:FindFirstChild("playerWeld") then
        local dv = HumanoidRootPart.Position - ball.Position
        local bd = _msqrt(dv.X*dv.X + dv.Y*dv.Y + dv.Z*dv.Z)
        pcall(function() SoftDisPlayerRemote:FireServer(owner, bd, false, ball.Size) end)
    end
end

-- ============================================================
-- MANUAL TACKLE
-- ============================================================
local function ManualTackleAction()
    local now = _tick()
    if now - LastManualTackleTime < AutoTackleConfig.ManualTackleCooldown then return false end
    local ok, ball, dist, owner = CanTackle()
    if ok then
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
        pcall(UpdateTargetCircles)
        IsTypingInChat = CheckIfTypingInChat()
    end)

    AutoTackleStatus.InputConnection = UserInputService.InputBegan:Connect(function(inp, gp)
        if gp or not AutoTackleConfig.Enabled or not AutoTackleConfig.ManualTackleEnabled then return end
        if IsTypingInChat then return end
        if inp.KeyCode == AutoTackleConfig.ManualTackleKeybind then ManualTackleAction() end
    end)

    AutoTackleStatus.Connection = RunService.Heartbeat:Connect(function()
        if not AutoTackleConfig.Enabled then
            CleanupDebugText(); UpdateDebugVisibility(); return
        end
        pcall(function()
            local ok, ball, dist, owner = CanTackle()

            -- v3.9: PredictionBox обновляется ВСЕГДА при наличии owner,
            -- независимо от того вызывается ли PerformTackle
            if owner then
                local ownerRootLive = owner.Character
                    and owner.Character:FindFirstChild("HumanoidRootPart")
                local ownerCharLive = owner.Character
                UpdatePredictionLabel(ownerRootLive, owner)
                UpdatePredictionBox(ownerRootLive, owner, ownerCharLive)
            else
                HideBoxLines(Gui and Gui.PredictionBoxLines)
            end

            if not ok or not ball then
                if Gui then
                    Gui.TackleTargetLabel.Text    = "Target: None"
                    Gui.TackleDribblingLabel.Text = "isDribbling: false"
                    Gui.TackleTacklingLabel.Text  = "isTackling: false"
                    Gui.TackleWaitLabel.Text      = "Wait: 0.00"
                    Gui.EagleEyeLabel.Text        = (Gui.EagleEyeLabel.Text:find("BLOCKED")
                        and Gui.EagleEyeLabel.Text or "EagleEye: Idle")
                    if AutoTackleConfig.Mode == "ManualTackle" then
                        Gui.ManualTackleLabel.Text  = "ManualTackle: NO TARGET"
                        Gui.ManualTackleLabel.Color = Color3.fromRGB(255,0,0)
                    end
                end
                CurrentTargetOwner = nil
                return
            end

            if Gui then
                Gui.TackleTargetLabel.Text    = "Target: " .. (owner and owner.Name or "None")
                Gui.TackleDribblingLabel.Text = "isDribbling: " .. tostring(
                    owner and DribbleStates[owner] and DribbleStates[owner].IsDribbling or false)
                Gui.TackleTacklingLabel.Text  = "isTackling: " .. tostring(
                    owner and IsSpecificTackle(owner) or false)
                Gui.PingLabel.Text = string.format("Ping: %dms",
                    _mfloor(AutoTackleStatus.Ping*1000+0.5))
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
                    Gui.EagleEyeLabel.Text      = "ManualTackle: Ready"
                    Gui.ManualTackleLabel.Text  = "ManualTackle: READY"
                    Gui.ManualTackleLabel.Color = Color3.fromRGB(0,255,0)
                end
                return
            end
            if not owner then return end

            local state = DribbleStates[owner] or {
                IsDribbling=false, LastDribbleEnd=0, IsProcessingDelay=false, HadDribble=false
            }
            local isDribbling    = state.IsDribbling
            local inCooldownList = DribbleCooldownList[owner] ~= nil

            if AutoTackleConfig.Mode == "OnlyDribble" then
                if inCooldownList then
                    PerformTackle(ball, owner)
                    if Gui then Gui.EagleEyeLabel.Text = "OnlyDribble: Tackling!" end
                elseif isDribbling then
                    if Gui then
                        Gui.EagleEyeLabel.Text   = "OnlyDribble: Dribbling..."
                        Gui.TackleWaitLabel.Text = string.format("DDelay: %.2f",
                            AutoTackleConfig.DribbleDelayTime)
                    end
                elseif state.IsProcessingDelay then
                    local rem = AutoTackleConfig.DribbleDelayTime - (_tick() - state.LastDribbleEnd)
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
                if isDribbling then
                    EagleEyeTimers[owner] = nil
                    if Gui then
                        Gui.TackleWaitLabel.Text = "Wait: DRIBBLE"
                        Gui.EagleEyeLabel.Text   = "EagleEye: Dribbling (reset)"
                    end
                elseif state.IsProcessingDelay then
                    EagleEyeTimers[owner] = nil
                    local rem = AutoTackleConfig.DribbleDelayTime - (now - state.LastDribbleEnd)
                    if Gui then
                        Gui.TackleWaitLabel.Text = string.format("DDelay: %.2f", rem)
                        Gui.EagleEyeLabel.Text   = "EagleEye: DribbleDelay"
                    end
                elseif inCooldownList then
                    PerformTackle(ball, owner)
                    EagleEyeTimers[owner] = nil
                    if Gui then Gui.EagleEyeLabel.Text = "EagleEye: Post-Dribble Tackle!" end
                else
                    if not EagleEyeTimers[owner] then
                        local wt = AutoTackleConfig.EagleEyeMinDelay
                            + math.random() * (AutoTackleConfig.EagleEyeMaxDelay
                            - AutoTackleConfig.EagleEyeMinDelay)
                        EagleEyeTimers[owner] = { startTime = now, waitTime = wt }
                    end
                    local tmr = EagleEyeTimers[owner]
                    local elapsed = now - tmr.startTime
                    if elapsed >= tmr.waitTime then
                        PerformTackle(ball, owner)
                        EagleEyeTimers[owner] = nil
                        if Gui then Gui.EagleEyeLabel.Text = "EagleEye: Tackling!" end
                    else
                        if Gui then
                            Gui.TackleWaitLabel.Text = string.format("Wait: %.2f",
                                tmr.waitTime - elapsed)
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
    if AutoTackleStatus.Connection then
        AutoTackleStatus.Connection:Disconnect(); AutoTackleStatus.Connection = nil
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
    for _, circle in pairs(AutoTackleStatus.TargetCircles) do
        for _, ln in ipairs(circle) do ln:Remove() end
    end
    AutoTackleStatus.TargetCircles = {}
    if notify then notify("AutoTackle", "Stopped", true) end
end

-- ============================================================
-- AUTODRIBBLE — v3.9
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

-- ============================================================
-- ShouldDribbleNow v3.9 — ПОЛНОСТЬЮ ПЕРЕПИСАН
--
-- КЛЮЧЕВЫЕ ИЗМЕНЕНИЯ:
-- - Strict режим БОЛЬШЕ НЕ требует IsTackling.
--   Strict = чистая физика: угол + TTC + скорость сближения
--   Это позволяет реагировать РАНЬШЕ чем началась анимация такла
-- - Free режим = старое поведение (IsTackling обязателен в зоне)
-- - Все Vector3 операторы заменены на компонентную арифметику
-- - Magnitude сравнения заменены на Magnitude² (без sqrt)
-- - Exponential smoothing скорости (EMA, alpha=0.35)
-- - TTC вычисляется через скорость сближения (dot-product), а не .Magnitude
-- - Добавлен минимальный relSpeed порог (0.8) для исключения
--   параллельного движения при хорошем угле
-- ============================================================
local _velSmooth = {}
local SMOOTH_A   = 0.35

local function GetSmoothedVelocity(player, rawV)
    local prev = _velSmooth[player]
    if not prev then _velSmooth[player] = rawV; return rawV end
    local sx = SMOOTH_A*rawV.X + (1-SMOOTH_A)*prev.X
    local sy = SMOOTH_A*rawV.Y + (1-SMOOTH_A)*prev.Y
    local sz = SMOOTH_A*rawV.Z + (1-SMOOTH_A)*prev.Z
    local s  = _V3new(sx, sy, sz)
    _velSmooth[player] = s
    return s
end

local function ShouldDribbleNow(specificTarget, tacklerData)
    if not specificTarget or not tacklerData then return false end
    local tacklerRoot = tacklerData.RootPart
    if not tacklerRoot then return false end

    local serverCF    = GetMyServerCFrame()
    local msx = serverCF.Position.X
    local msz = serverCF.Position.Z

    local rawV = tacklerData.Velocity
    local vel  = GetSmoothedVelocity(specificTarget, rawV)
    local vx, vz = vel.X, vel.Z
    -- v3.9: speed² без sqrt
    local speed2 = vx*vx + vz*vz

    local tp = tacklerRoot.Position
    local ping = AutoTackleStatus.Ping
    -- Предсказанная позиция таклера с учётом пинга
    local predTx = tp.X + vx * ping * 1.5
    local predTz = tp.Z + vz * ping * 1.5

    local toMeX = msx - predTx
    local toMeZ = msz - predTz
    local dist2 = toMeX*toMeX + toMeZ*toMeZ
    local maxD  = AutoDribbleConfig.MaxDribbleDistance
    if dist2 > maxD * maxD then
        if Gui and AutoDribbleConfig.Enabled then
            Gui.AngleLabel.Text = string.format("FAR d=%.0f", _msqrt(dist2))
        end
        return false
    end
    local distFlat = _msqrt(dist2)

    -- [СТАДИЯ 0] Вплотную — мгновенная реакция
    if distFlat < 4 then
        if Gui and AutoDribbleConfig.Enabled then
            Gui.AngleLabel.Text = string.format("⚡ INSTANT d=%.1f", distFlat)
        end
        return true
    end

    local isStrict = AutoDribbleConfig.DribbleMode == "Strict"

    -- -------------------------------------------------------
    -- STRICT режим: чистая физика, IsTackling НЕ нужен
    -- -------------------------------------------------------
    if isStrict then
        -- Минимальная скорость: без неё все стоячие враги будут триггерить
        local minSpeed2 = 2.5 * 2.5  -- 6.25
        if speed2 < minSpeed2 then
            if Gui and AutoDribbleConfig.Enabled then
                Gui.AngleLabel.Text = string.format("[S] slow v=%.1f", _msqrt(speed2))
            end
            return false
        end

        -- Нормализуем вектор скорости (без Vector3.Unit — руками)
        local invSpeed = 1 / _msqrt(speed2)
        local dirVX = vx * invSpeed
        local dirVZ = vz * invSpeed

        -- Нормализуем вектор "ко мне" (без Vector3.Unit)
        local invDist = 1 / _mmax(distFlat, 0.001)
        local toMeUX  = toMeX * invDist
        local toMeUZ  = toMeZ * invDist

        -- Dot-product: насколько таклер "смотрит на нас"
        local dot = dirVX*toMeUX + dirVZ*toMeUZ
        dot = _mclamp(dot, -1, 1)  -- защита от float ошибок

        -- На дальних дистанциях (>= 8 studs) угол важен
        -- На близких (< 8) — угол не важен, важно только TTC
        if distFlat >= 8 then
            local cosT = GetCosThreshold()
            if dot < cosT then
                if Gui and AutoDribbleConfig.Enabled then
                    local deg = math.deg(math.acos(dot))
                    Gui.AngleLabel.Text = string.format("[S] BAD A=%.0f°", deg)
                end
                return false
            end
        end

        -- Скорость сближения: проекция скорости таклера на ось "к нам"
        local approach = vx*toMeUX + vz*toMeUZ

        -- Учитываем нашу скорость (убегаем — уменьшаем relSpeed)
        local myVelH = GetMyVelocityFromHistory()
        -- Проекция моей скорости на ось "к таклеру" (противоположная ось)
        local myApproach = -(myVelH.X*toMeUX + myVelH.Z*toMeUZ)
        local relSpeed = approach + _mmax(myApproach, 0)

        -- Если скорость сближения слишком мала — не столкнутся
        -- (враг движется параллельно даже при хорошем угле)
        if relSpeed < 0.8 then
            if Gui and AutoDribbleConfig.Enabled then
                Gui.AngleLabel.Text = string.format("[S] PARALLEL rs=%.1f", relSpeed)
            end
            return false
        end

        local ttc = distFlat / _mmax(relSpeed, 1)

        if Gui and AutoDribbleConfig.Enabled then
            local deg = math.deg(math.acos(dot))
            Gui.AngleLabel.Text = string.format("[S] A=%.0f° t=%.2f d=%.1f rs=%.1f",
                deg, ttc, distFlat, relSpeed)
        end

        -- Strict: реагируем только если TTC < 0.28s
        -- (достаточно мало чтобы исключить ложные, достаточно велико для реакции)
        return ttc < 0.28

    -- -------------------------------------------------------
    -- FREE режим: требует IsTackling в зоне активации
    -- -------------------------------------------------------
    else
        if distFlat <= AutoDribbleConfig.DribbleActivationDistance then
            if not tacklerData.IsTackling then
                if Gui and AutoDribbleConfig.Enabled then
                    Gui.AngleLabel.Text = string.format("CLOSE d=%.1f no tackle", distFlat)
                end
                return false
            end
            if Gui and AutoDribbleConfig.Enabled then
                Gui.AngleLabel.Text = string.format("⚡ TACKLE d=%.1f", distFlat)
            end
            return true
        end

        -- Free средняя дистанция: скорость + угол + TTC
        local minSpeed2Free = 2.0 * 2.0  -- 4.0
        if speed2 < minSpeed2Free then
            if Gui and AutoDribbleConfig.Enabled then
                Gui.AngleLabel.Text = string.format("v=%.1f slow", _msqrt(speed2))
            end
            return false
        end

        local invSpeed = 1 / _msqrt(speed2)
        local dirVX    = vx * invSpeed
        local dirVZ    = vz * invSpeed
        local invDist  = 1 / _mmax(distFlat, 0.001)
        local toMeUX   = toMeX * invDist
        local toMeUZ   = toMeZ * invDist

        local dot = dirVX*toMeUX + dirVZ*toMeUZ
        dot = _mclamp(dot, -1, 1)
        local cosT = GetCosThreshold()

        if Gui and AutoDribbleConfig.Enabled then
            local deg = math.deg(math.acos(dot))
            Gui.AngleLabel.Text = string.format("A=%.0f° v=%.1f d=%.1f",
                deg, _msqrt(speed2), distFlat)
        end

        if dot < cosT then return false end

        local myVelH = GetMyVelocityFromHistory()
        local approach   = vx*toMeUX + vz*toMeUZ
        local myApproach = -(myVelH.X*toMeUX + myVelH.Z*toMeUZ)
        local relSpeed   = approach + _mmax(myApproach, 0)
        if relSpeed < 0.5 then return false end

        local ttc = distFlat / _mmax(relSpeed, 1)
        if Gui and AutoDribbleConfig.Enabled then
            Gui.AngleLabel.Text = Gui.AngleLabel.Text .. string.format(" t=%.2f", ttc)
        end
        return ttc < 0.4
    end
end

local function PerformDribble()
    local now = _tick()
    if now - AutoDribbleStatus.LastDribbleTime < 0.02 then return end
    local myBools = Workspace:FindFirstChild(LocalPlayer.Name)
        and Workspace[LocalPlayer.Name]:FindFirstChild("Bools")
    if not myBools or myBools.dribbleDebounce.Value then return end
    pcall(function() ActionRemote:FireServer("Deke") end)
    AutoDribbleStatus.LastDribbleTime = now
    if Gui and AutoDribbleConfig.Enabled then
        Gui.DribbleStatusLabel.Text  = "Dribble: Cooldown"
        Gui.DribbleStatusLabel.Color = Color3.fromRGB(255,0,0)
        Gui.AutoDribbleLabel.Text    = "AutoDribble: DEKE!"
    end
end

local AutoDribble = {}

-- v3.9: dirty-flag кэш, порог 0.12 studs
local _dribbleCache = {
    result = false,
    lastTacklerPlayer = nil,
    lastTacklerPos = Vector3.zero,
    lastMyPos = Vector3.zero,
    lastIsTackling = false,
    lastCalcTime = 0,
    RECALC_INTERVAL = 0.008,
    POSITION_DIRTY_THRESHOLD = 0.12,
}

local function IsDribbleCacheDirty(specificTarget, tacklerData)
    if not specificTarget or not tacklerData then return true end
    local now = _tick()
    if now - _dribbleCache.lastCalcTime > _dribbleCache.RECALC_INTERVAL then return true end
    if _dribbleCache.lastTacklerPlayer ~= specificTarget then return true end
    -- v3.9: IsTackling не в Strict (там не важно), но в Free важно
    if AutoDribbleConfig.DribbleMode == "Free"
    and _dribbleCache.lastIsTackling ~= tacklerData.IsTackling then return true end
    local root = tacklerData.RootPart
    if root then
        local cp = _dribbleCache.lastTacklerPos; local rp = root.Position
        local dx = rp.X-cp.X; local dz = rp.Z-cp.Z
        local thr = _dribbleCache.POSITION_DIRTY_THRESHOLD
        if dx*dx + dz*dz > thr*thr then return true end
    end
    local mp = _dribbleCache.lastMyPos; local hp = HumanoidRootPart.Position
    local mdx = hp.X-mp.X; local mdz = hp.Z-mp.Z
    local thr = _dribbleCache.POSITION_DIRTY_THRESHOLD
    if mdx*mdx + mdz*mdz > thr*thr then return true end
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

    AutoDribbleStatus.Connection = RunService.Heartbeat:Connect(function()
        if not AutoDribbleConfig.Enabled then
            CleanupDebugText(); UpdateDebugVisibility(); return
        end
        if not HasBall or not CanDribbleNow then
            if Gui then Gui.AutoDribbleLabel.Text = "AutoDribble: Idle" end
            return
        end

        local specificTarget, minDist, targetCount, nearestData = nil, math.huge, 0, nil
        for player, data in pairs(PrecomputedPlayers) do
            -- Strict: ищем ближайшего независимо от IsTackling
            -- Free: только среди тех кто делает IsTackling
            local validTarget = data.IsValid and (
                AutoDribbleConfig.DribbleMode == "Strict"
                or (TackleStates[player] and TackleStates[player].IsTackling)
            )
            if validTarget then
                targetCount = targetCount + 1
                if data.Distance < minDist then
                    minDist = data.Distance
                    specificTarget = player
                    nearestData    = data
                end
            end
        end

        if Gui then
            Gui.DribbleTargetLabel.Text   = "Targets: " .. targetCount
            Gui.DribbleTacklingLabel.Text = specificTarget
                and string.format("Near: %.1f", minDist) or "Near: None"
        end

        if not specificTarget or not nearestData then
            if Gui then Gui.AutoDribbleLabel.Text = "AutoDribble: Idle" end
            return
        end

        local dribbleShouldFire
        if IsDribbleCacheDirty(specificTarget, nearestData) then
            dribbleShouldFire = ShouldDribbleNow(specificTarget, nearestData)
            _dribbleCache.result             = dribbleShouldFire
            _dribbleCache.lastCalcTime       = _tick()
            _dribbleCache.lastTacklerPlayer  = specificTarget
            _dribbleCache.lastIsTackling     = nearestData.IsTackling
            if nearestData.RootPart then
                _dribbleCache.lastTacklerPos = nearestData.RootPart.Position
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
    end)

    UpdateDebugVisibility()
    if notify then notify("AutoDribble", "Started", true) end
end

AutoDribble.Stop = function()
    if AutoDribbleStatus.Connection then
        AutoDribbleStatus.Connection:Disconnect(); AutoDribbleStatus.Connection = nil
    end
    if AutoDribbleStatus.HeartbeatConnection then
        AutoDribbleStatus.HeartbeatConnection:Disconnect()
        AutoDribbleStatus.HeartbeatConnection = nil
    end
    AutoDribbleStatus.Running = false
    if Gui and Gui.ServerPosBoxLines then HideBoxLines(Gui.ServerPosBoxLines) end
    if Gui and Gui.PredictionBoxLines then HideBoxLines(Gui.PredictionBoxLines) end
    CleanupDebugText(); UpdateDebugVisibility()
    if notify then notify("AutoDribble", "Stopped", true) end
end

-- ============================================================
-- UI
-- ============================================================
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
            Name = "Show Prediction Box (always)", Default = AutoTackleConfig.ShowPredictionBox,
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
            onBinded = function(v) AutoTackleConfig.ManualTackleKeybind = v end
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
            Name = "Activation Distance (Free only)", Minimum = 5, Maximum = 30,
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

-- ============================================================
-- СИНХРОНИЗАЦИЯ
-- ============================================================
local function SynchronizeConfigValues()
    if not uiElements then return end
    local sync = {
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
    for _, pair in ipairs(sync) do
        local elem, setter = pair[1], pair[2]
        if elem and elem.GetValue then pcall(function() setter(elem:GetValue()) end) end
    end
end

-- ============================================================
-- МОДУЛЬ
-- ============================================================
local AutoDribbleTackleModule = {}

function AutoDribbleTackleModule.Init(UI, coreParam, notifyFunc)
    core       = coreParam
    Services   = core.Services
    PlayerData = core.PlayerData
    notify     = notifyFunc
    LocalPlayerObj = PlayerData.LocalPlayer

    SetupUI(UI)

    local syncTimer = 0
    RunService.Heartbeat:Connect(function(dt)
        syncTimer = syncTimer + dt
        if syncTimer >= 1.0 then
            syncTimer = 0
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
        MyPositionHistory = {}
        _cachedAngleDeg   = -1
        _velSmooth        = {}
        _boxCache         = {}  -- v3.9: сброс box кэша при respawn
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
