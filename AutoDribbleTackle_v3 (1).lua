-- [v4.2] AUTO DRIBBLE + AUTO TACKLE
-- Changelog v4.2:
-- [FIX] 3D Box полностью переписан:
--       Character:GetBoundingBox() → реальный CFrame + Size персонажа
--       8 углов из Size/2, 12 Drawing.new("Line"), без Outline, без Quad
--       Работает корректно при прыжке/движении/любом скейле
-- [FIX] Server Pos Box аналогично — предсказанный CFrame + тот же Size
-- [REMOVE] Strict режим
-- [REMOVE] SynchronizeConfigValues
-- [FIX] Free: distFlat <= PointBlankRadius + IsTackling → немедленный dribble

-- ============================================================
-- ЛОКАЛИЗАЦИЯ HOT-PATH
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
    RequireTackleAnim         = false,
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
    _tins(h, { time = _tick(), pos = ownerRoot.Position })
    while #h > HISTORY_SIZE do _trem(h, 1) end
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
    local vel  = GetPositionBasedVelocity(player)
    local vx, vz = vel.X, vel.Z
    local op = ownerRoot.Position
    local sx = op.X + vx*ping; local sz = op.Z + vz*ping
    local myPos = HumanoidRootPart.Position
    local iT = CalcInterceptTime(
        _V3new(myPos.X,0,myPos.Z),
        _V3new(sx,0,sz),
        _V3new(vx,0,vz),
        AutoTackleConfig.TackleSpeed
    )
    return _V3new(sx+vx*iT, op.Y, sz+vz*iT)
end

-- ============================================================
-- СЕРВЕРНАЯ ПОЗИЦИЯ
-- ============================================================
local MY_HISTORY_SIZE   = 10
local MyPositionHistory = {}

local function RecordMyPosition()
    _tins(MyPositionHistory, { time=_tick(), cframe=HumanoidRootPart.CFrame })
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
    local v  = GetMyVelocityFromHistory()
    local p  = HumanoidRootPart.Position
    local sp = _V3new(p.X - v.X*nd, p.Y - v.Y*nd, p.Z - v.Z*nd)
    return CFrame.new(sp) * (HumanoidRootPart.CFrame - HumanoidRootPart.CFrame.Position)
end

-- ============================================================
-- 3D BOX — правильная реализация
-- ============================================================
-- Используем Character:GetBoundingBox() → (CFrame, Vector3 size)
-- Это стандарт ESP в Roblox эксплоитах:
-- GetBoundingBox возвращает axis-aligned bounding box всего персонажа
-- Size.X/Y/Z — реальные размеры, работает при прыжке/приседании/любом скейле
-- 8 углов куба, 12 рёбер, каждое ребро = Drawing.new("Line")
--
-- Edges: нижняя грань (1-2-3-4), верхняя (5-6-7-8), вертикали (1-5, 2-6, 3-7, 4-8)
-- ============================================================
local BOX_EDGES = {
    {1,2},{2,3},{3,4},{4,1},   -- нижняя грань
    {5,6},{6,7},{7,8},{8,5},   -- верхняя грань
    {1,5},{2,6},{3,7},{4,8},   -- вертикали
}

local function MakeBoxLines(color, thickness)
    local lines = {}
    for i = 1, 12 do
        local l = Drawing.new("Line")
        l.Color     = color or Color3.fromRGB(255, 165, 0)
        l.Thickness = thickness or 1.5
        l.Visible   = false
        lines[i]    = l
    end
    return lines
end

-- cf = CFrame центра бокса, sz = Vector3 размер бокса
-- Строим 8 углов в world space напрямую из cf и sz
local function GetBoxCorners(cf, sz)
    local hx = sz.X * 0.5
    local hy = sz.Y * 0.5
    local hz = sz.Z * 0.5
    -- right/up/look = колонки матрицы CFrame
    local rx, ry, rz = cf.RightVector.X, cf.RightVector.Y, cf.RightVector.Z
    local ux, uy, uz = cf.UpVector.X,    cf.UpVector.Y,    cf.UpVector.Z
    local lx, ly, lz = cf.LookVector.X,  cf.LookVector.Y,  cf.LookVector.Z
    local ox, oy, oz = cf.X, cf.Y, cf.Z
    -- 8 углов: все комбинации ±hx, ±hy, ±hz
    return {
        _V3new(ox + (-hx)*rx + (-hy)*ux + (-hz)*lx,
               oy + (-hx)*ry + (-hy)*uy + (-hz)*ly,
               oz + (-hx)*rz + (-hy)*uz + (-hz)*lz),
        _V3new(ox + ( hx)*rx + (-hy)*ux + (-hz)*lx,
               oy + ( hx)*ry + (-hy)*uy + (-hz)*ly,
               oz + ( hx)*rz + (-hy)*uz + (-hz)*lz),
        _V3new(ox + ( hx)*rx + (-hy)*ux + ( hz)*lx,
               oy + ( hx)*ry + (-hy)*uy + ( hz)*ly,
               oz + ( hx)*rz + (-hy)*uz + ( hz)*lz),
        _V3new(ox + (-hx)*rx + (-hy)*ux + ( hz)*lx,
               oy + (-hx)*ry + (-hy)*uy + ( hz)*ly,
               oz + (-hx)*rz + (-hy)*uz + ( hz)*lz),
        _V3new(ox + (-hx)*rx + ( hy)*ux + (-hz)*lx,
               oy + (-hx)*ry + ( hy)*uy + (-hz)*ly,
               oz + (-hx)*rz + ( hy)*uz + (-hz)*lz),
        _V3new(ox + ( hx)*rx + ( hy)*ux + (-hz)*lx,
               oy + ( hx)*ry + ( hy)*uy + (-hz)*ly,
               oz + ( hx)*rz + ( hy)*uz + (-hz)*lz),
        _V3new(ox + ( hx)*rx + ( hy)*ux + ( hz)*lx,
               oy + ( hx)*ry + ( hy)*uy + ( hz)*ly,
               oz + ( hx)*rz + ( hy)*uz + ( hz)*lz),
        _V3new(ox + (-hx)*rx + ( hy)*ux + ( hz)*lx,
               oy + (-hx)*ry + ( hy)*uy + ( hz)*ly,
               oz + (-hx)*rz + ( hy)*uz + ( hz)*lz),
    }
end

local function DrawBox(lines, cf, sz)
    if not lines then return end
    local corners = GetBoxCorners(cf, sz)
    for i, edge in ipairs(BOX_EDGES) do
        local line = lines[i]
        if not line then continue end
        local sa, aVisible = Camera:WorldToViewportPoint(corners[edge[1]])
        local sb, bVisible = Camera:WorldToViewportPoint(corners[edge[2]])
        if aVisible and bVisible and sa.Z > 0.1 and sb.Z > 0.1 then
            line.From    = Vector2.new(sa.X, sa.Y)
            line.To      = Vector2.new(sb.X, sb.Y)
            line.Visible = true
        else
            line.Visible = false
        end
    end
end

local function HideBox(lines)
    if not lines then return end
    for _, l in ipairs(lines) do l.Visible = false end
end

local function RemoveBox(lines)
    if not lines then return end
    for _, l in ipairs(lines) do pcall(function() l:Remove() end) end
end

-- ============================================================
-- Получение bounding box персонажа
-- Character:GetBoundingBox() → CFrame, Vector3
-- Это реальный размер — включает ноги, голову, всё
-- ============================================================
local function GetCharacterBox(character)
    if not character then return nil, nil end
    local ok, cf, sz = pcall(function()
        return character:GetBoundingBox()
    end)
    if ok and cf and sz then
        return cf, sz
    end
    -- fallback: HumanoidRootPart + стандартный R15 размер
    local hrp = character:FindFirstChild("HumanoidRootPart")
    if hrp then
        return hrp.CFrame, Vector3.new(3.6, 5.5, 3.6)
    end
    return nil, nil
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
        -- 3D боксы: 12 линий каждый
        ServerPosBoxLines    = nil,
        PredictionBoxLines   = nil,
        TackleDebugLabels    = {},
        DribbleDebugLabels   = {},
    }

    -- Оранжевый = prediction box (позиция перехвата)
    -- Голубой   = server pos box (наша серверная позиция)
    Gui.PredictionBoxLines = MakeBoxLines(Color3.fromRGB(255, 165, 0), 1.5)
    Gui.ServerPosBoxLines  = MakeBoxLines(Color3.fromRGB(0, 200, 255), 1.5)

    local sv   = Camera.ViewportSize
    local cx   = sv.X / 2
    local tyY  = sv.Y * 0.6
    local dyY  = tyY - 50

    local function setupLabel(lbl, pos, color)
        lbl.Size    = 16
        lbl.Color   = color or Color3.fromRGB(255, 255, 255)
        lbl.Outline = true
        lbl.Center  = true
        lbl.Visible = false
        lbl.Position= pos
    end

    local tLabels = {
        { Gui.TackleWaitLabel,      Vector2.new(cx, tyY),      Color3.fromRGB(255,165,0) },
        { Gui.TackleTargetLabel,    Vector2.new(cx, tyY+15),   nil },
        { Gui.TackleDribblingLabel, Vector2.new(cx, tyY+30),   nil },
        { Gui.TackleTacklingLabel,  Vector2.new(cx, tyY+45),   nil },
        { Gui.EagleEyeLabel,        Vector2.new(cx, tyY+60),   nil },
        { Gui.CooldownListLabel,    Vector2.new(cx, tyY+75),   nil },
        { Gui.ModeLabel,            Vector2.new(cx, tyY+90),   nil },
        { Gui.ManualTackleLabel,    Vector2.new(cx, tyY+105),  nil },
        { Gui.PingLabel,            Vector2.new(cx, tyY+120),  nil },
        { Gui.PredictionLabel,      Vector2.new(cx, tyY+135),  nil },
        { Gui.ServerPosLabel,       Vector2.new(cx, tyY+150),  Color3.fromRGB(0,200,255) },
    }
    for _, t in ipairs(tLabels) do
        setupLabel(t[1], t[2], t[3])
        _tins(Gui.TackleDebugLabels, t[1])
    end

    local dLabels = {
        { Gui.DribbleStatusLabel,   Vector2.new(cx, dyY),      nil },
        { Gui.DribbleTargetLabel,   Vector2.new(cx, dyY+15),   nil },
        { Gui.DribbleTacklingLabel, Vector2.new(cx, dyY+30),   nil },
        { Gui.AutoDribbleLabel,     Vector2.new(cx, dyY+45),   nil },
        { Gui.AngleLabel,           Vector2.new(cx, dyY+60),   nil },
    }
    for _, t in ipairs(dLabels) do
        setupLabel(t[1], t[2], t[3])
        _tins(Gui.DribbleDebugLabels, t[1])
    end

    -- Дефолтные тексты
    Gui.TackleWaitLabel.Text      = "Wait: 0.00"
    Gui.TackleTargetLabel.Text    = "Target: None"
    Gui.TackleDribblingLabel.Text = "isDribbling: false"
    Gui.TackleTacklingLabel.Text  = "isTackling: false"
    Gui.EagleEyeLabel.Text        = "EagleEye: Idle"
    Gui.CooldownListLabel.Text    = "CooldownList: 0"
    Gui.ModeLabel.Text            = "Mode: " .. AutoTackleConfig.Mode
    Gui.ManualTackleLabel.Text    = "ManualTackle: Ready"
    Gui.PingLabel.Text            = "Ping: 0ms"
    Gui.PredictionLabel.Text      = "Pred: -"
    Gui.ServerPosLabel.Text       = "ServerPos: -"
    Gui.DribbleStatusLabel.Text   = "Dribble: Ready"
    Gui.DribbleTargetLabel.Text   = "Targets: 0"
    Gui.DribbleTacklingLabel.Text = "Nearest: None"
    Gui.AutoDribbleLabel.Text     = "AutoDribble: Idle"
    Gui.AngleLabel.Text           = "Angle: -"
end

local function UpdateDebugVisibility()
    if not Gui then return end
    local tv = DebugConfig.Enabled and AutoTackleConfig.Enabled
    for _, l in ipairs(Gui.TackleDebugLabels) do l.Visible = tv end
    local dv = DebugConfig.Enabled and AutoDribbleConfig.Enabled
    for _, l in ipairs(Gui.DribbleDebugLabels) do l.Visible = dv end
    if not (AutoTackleConfig.Enabled and AutoTackleConfig.ShowPredictionBox) then
        HideBox(Gui.PredictionBoxLines)
    end
    if not (AutoDribbleConfig.Enabled and AutoDribbleConfig.ShowServerPos) then
        HideBox(Gui.ServerPosBoxLines)
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
        Gui.PredictionLabel.Text      = "Pred: -"
    end
    if not AutoDribbleConfig.Enabled then
        Gui.DribbleStatusLabel.Text   = "Dribble: Ready"
        Gui.DribbleTargetLabel.Text   = "Targets: 0"
        Gui.DribbleTacklingLabel.Text = "Nearest: None"
        Gui.AutoDribbleLabel.Text     = "AutoDribble: Idle"
        Gui.AngleLabel.Text           = "Angle: -"
        HideBox(Gui.ServerPosBoxLines)
    end
end

-- ============================================================
-- SERVER POS BOX UPDATE
-- Используем GetCharacterBox(Character) для нашего персонажа
-- и сдвигаем CFrame на разницу серверной позиции
-- ============================================================
local function UpdateServerPosBox()
    if not Gui or not Gui.ServerPosBoxLines then return end
    if not (AutoDribbleConfig.Enabled and AutoDribbleConfig.ShowServerPos) then
        HideBox(Gui.ServerPosBoxLines)
        if Gui.ServerPosLabel then Gui.ServerPosLabel.Text = "ServerPos: -" end
        return
    end
    -- Получаем реальный bounding box нашего персонажа
    local realCF, realSZ = GetCharacterBox(Character)
    if not realCF or not realSZ then HideBox(Gui.ServerPosBoxLines); return end

    -- Серверная CFrame = реальная CFrame но с сдвинутой позицией
    local serverCF  = GetMyServerCFrame()
    -- Берём ориентацию от серверной CFrame, размер — реальный
    local boxCF = CFrame.new(serverCF.Position) * (realCF - realCF.Position)
    DrawBox(Gui.ServerPosBoxLines, boxCF, realSZ)

    if Gui.ServerPosLabel and DebugConfig.Enabled then
        local delay = _mfloor(AutoTackleStatus.Ping * 1.5 * 1000 + 0.5)
        local dv = serverCF.Position - HumanoidRootPart.Position
        local dist = _msqrt(dv.X*dv.X + dv.Y*dv.Y + dv.Z*dv.Z)
        Gui.ServerPosLabel.Text = string.format("ServerPos: %dms | %.1f st", delay, dist)
    end
end

-- ============================================================
-- PREDICTION BOX UPDATE
-- GetCharacterBox(targetCharacter) → реальный размер цели
-- CFrame = предсказанная позиция + оригинальная ориентация
-- ============================================================
local function UpdatePredictionBox(ownerRoot, player, targetCharacter)
    if not Gui or not Gui.PredictionBoxLines then return end
    if not (AutoTackleConfig.Enabled and AutoTackleConfig.ShowPredictionBox) then
        HideBox(Gui.PredictionBoxLines)
        return
    end
    if not ownerRoot or not player then
        HideBox(Gui.PredictionBoxLines)
        return
    end
    local targetCF, targetSZ = GetCharacterBox(targetCharacter)
    if not targetCF or not targetSZ then
        HideBox(Gui.PredictionBoxLines)
        return
    end
    -- Предсказанная позиция центра бокса
    local predictedPos = PredictTargetPosition(ownerRoot, player)
    -- Смещение центра bounding box от HRP
    local hrp = targetCharacter and targetCharacter:FindFirstChild("HumanoidRootPart")
    local offsetFromHRP = Vector3.zero
    if hrp then
        offsetFromHRP = targetCF.Position - hrp.Position
    end
    -- Финальная CFrame: предсказанная позиция HRP + смещение + ориентация
    local finalPos = predictedPos + offsetFromHRP
    local boxCF    = CFrame.new(finalPos) * (targetCF - targetCF.Position)
    DrawBox(Gui.PredictionBoxLines, boxCF, targetSZ)

    if Gui.PredictionLabel and DebugConfig.Enabled then
        local ping  = AutoTackleStatus.Ping
        local vel   = GetPositionBasedVelocity(player)
        local vx,vz = vel.X, vel.Z
        local myPos = HumanoidRootPart.Position
        local op    = ownerRoot.Position
        local dx    = op.X - myPos.X; local dz = op.Z - myPos.Z
        local dist  = _msqrt(dx*dx + dz*dz)
        local iT    = CalcInterceptTime(
            _V3new(myPos.X,0,myPos.Z),
            _V3new(op.X+vx*ping,0,op.Z+vz*ping),
            _V3new(vx,0,vz),
            AutoTackleConfig.TackleSpeed
        )
        Gui.PredictionLabel.Text = string.format(
            "p=%dms t=%dms v=%.0f d=%.0f",
            _mfloor(ping*1000+0.5),
            _mfloor(iT*1000+0.5),
            _msqrt(vx*vx+vz*vz),
            dist
        )
    end
end

-- ============================================================
-- PING UPDATE
-- ============================================================
local function UpdatePing()
    local now = _tick()
    if now - AutoTackleStatus.LastPingUpdate > 1 then
        AutoTackleStatus.Ping = GetPing()
        AutoTackleStatus.LastPingUpdate = now
        if Gui and AutoTackleConfig.Enabled then
            Gui.PingLabel.Text = string.format("Ping: %dms", _mfloor(AutoTackleStatus.Ping*1000+0.5))
        end
    end
end

-- ============================================================
-- ПРОВЕРКИ СОСТОЯНИЙ
-- ============================================================
local function IsDribbling(targetPlayer)
    if not targetPlayer or not targetPlayer.Character or not targetPlayer.Parent
       or targetPlayer.TeamColor == LocalPlayer.TeamColor then return false end
    local hum = targetPlayer.Character:FindFirstChild("Humanoid")
    if not hum then return false end
    local anim = hum:FindFirstChild("Animator")
    if not anim then return false end
    for _, t in pairs(anim:GetPlayingAnimationTracks()) do
        if t.Animation and table.find(DribbleAnimIds, t.Animation.AnimationId) then return true end
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
    for _, t in pairs(anim:GetPlayingAnimationTracks()) do
        if t.Animation and t.Animation.AnimationId == SPECIFIC_TACKLE_ID then return true end
    end
    return false
end

local function IsPowerShooting(targetPlayer)
    if not targetPlayer then return false end
    local pf = Workspace:FindFirstChild(targetPlayer.Name)
    if not pf then return false end
    local b = pf:FindFirstChild("Bools")
    if not b then return false end
    local ps = b:FindFirstChild("PowerShooting")
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
        local s = DribbleStates[player]
        local isDrib = IsDribbling(player)
        if isDrib and not s.IsDribbling then
            s.IsDribbling = true; s.IsProcessingDelay = false; s.HadDribble = true
        elseif not isDrib and s.IsDribbling then
            s.IsDribbling = false; s.LastDribbleEnd = now; s.IsProcessingDelay = true
        elseif s.IsProcessingDelay and not isDrib then
            if now - s.LastDribbleEnd >= AutoTackleConfig.DribbleDelayTime then
                DribbleCooldownList[player] = now + 3.5
                s.IsProcessingDelay = false
            end
        end
    end
    local toRemove = {}
    for player, endTime in pairs(DribbleCooldownList) do
        if not player or not player.Parent or now >= endTime then
            _tins(toRemove, player)
        end
    end
    for _, p in ipairs(toRemove) do
        DribbleCooldownList[p] = nil
        EagleEyeTimers[p]      = nil
    end
    if Gui and AutoTackleConfig.Enabled then
        local c = 0; for _ in pairs(DribbleCooldownList) do c+=1 end
        Gui.CooldownListLabel.Text = "CooldownList: " .. c
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
            Gui.DribbleStatusLabel.Text  = bools.dribbleDebounce.Value and "Dribble: Cooldown" or "Dribble: Ready"
            Gui.DribbleStatusLabel.Color = bools.dribbleDebounce.Value
                and Color3.fromRGB(255,0,0) or Color3.fromRGB(0,255,0)
        end
    end
    local myPos = HumanoidRootPart.Position
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
        local dx = rp.X-myPos.X; local dy = rp.Y-myPos.Y; local dz = rp.Z-myPos.Z
        local dist = _msqrt(dx*dx + dy*dy + dz*dz)
        if dist > AutoDribbleConfig.MaxDribbleDistance then continue end
        local alv    = root.AssemblyLinearVelocity
        local posVel = GetPositionBasedVelocity(player)
        local vel    = alv.Magnitude >= posVel.Magnitude and alv or posVel
        if dist <= AutoDribbleConfig.DribbleActivationDistance * 1.5 then
            RecordTargetPosition(root, player)
        end
        PrecomputedPlayers[player] = {
            Distance   = dist,
            IsValid    = true,
            IsTackling = TackleStates[player].IsTackling,
            RootPart   = root,
            Character  = char,
            Humanoid   = hum,
            Velocity   = vel,
        }
    end
end

-- ============================================================
-- ROTATION
-- ============================================================
local function RotateToTarget(targetPos)
    if AutoTackleConfig.RotationMethod == "None" then return end
    local myPos = HumanoidRootPart.Position
    local dx = targetPos.X - myPos.X; local dz = targetPos.Z - myPos.Z
    if _msqrt(dx*dx + dz*dz) > 0.1 then
        HumanoidRootPart.CFrame = CFrame.new(myPos, myPos + _V3new(dx,0,dz))
    end
end

-- ============================================================
-- CAN TACKLE / PERFORM TACKLE
-- ============================================================
local function CanTackle()
    local ball = Workspace:FindFirstChild("ball")
    if not ball or not ball.Parent then return false, nil, nil, nil end
    local hasOwner = ball:FindFirstChild("playerWeld") and ball:FindFirstChild("creator")
    local owner    = hasOwner and ball.creator.Value or nil
    if AutoTackleConfig.OnlyPlayer and (not hasOwner or not owner or not owner.Parent) then
        return false, nil, nil, nil
    end
    local isEnemy = not owner or (owner and owner.TeamColor ~= LocalPlayer.TeamColor)
    if not isEnemy then return false, nil, nil, nil end
    if Workspace:FindFirstChild("Bools") then
        local wb = Workspace.Bools
        if wb.APG and wb.APG.Value == LocalPlayer then return false, nil, nil, nil end
        if wb.HPG and wb.HPG.Value == LocalPlayer then return false, nil, nil, nil end
    end
    local bv   = HumanoidRootPart.Position - ball.Position
    local dist = _msqrt(bv.X*bv.X + bv.Y*bv.Y + bv.Z*bv.Z)
    if dist > AutoTackleConfig.MaxDistance then return false, nil, nil, nil end
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
    return true, ball, dist, owner
end

local function PerformTackle(ball, owner)
    local myBools = Workspace:FindFirstChild(LocalPlayer.Name)
        and Workspace[LocalPlayer.Name]:FindFirstChild("Bools")
    if not myBools or myBools.TackleDebounce.Value or myBools.Tackled.Value
       or (Character:FindFirstChild("Bools") and Character.Bools.Debounce.Value) then return end

    local ownerRoot = owner and owner.Character and owner.Character:FindFirstChild("HumanoidRootPart")
    local ownerChar = owner and owner.Character

    local predictedPos
    if ownerRoot and owner then
        predictedPos = PredictTargetPosition(ownerRoot, owner)
    else
        predictedPos = ball.Position
    end
    RotateToTarget(predictedPos)
    if ownerRoot and owner then
        UpdatePredictionBox(ownerRoot, owner, ownerChar)
    end
    if ownerRoot then
        local fv = HumanoidRootPart.Position - ownerRoot.Position
        if _msqrt(fv.X*fv.X+fv.Y*fv.Y+fv.Z*fv.Z) <= 10 then
            pcall(function() firetouchinterest(HumanoidRootPart, ownerRoot, 0) end)
            pcall(function() firetouchinterest(HumanoidRootPart, ownerRoot, 1) end)
        end
    end
    pcall(function() ActionRemote:FireServer("TackIe") end)

    local bv = Instance.new("BodyVelocity")
    bv.Parent   = HumanoidRootPart
    bv.Velocity = HumanoidRootPart.CFrame.LookVector * AutoTackleConfig.TackleSpeed
    bv.MaxForce = _V3new(50000000, 0, 50000000)

    local startT   = _tick()
    local duration = 0.65
    local rotConn

    local method = AutoTackleConfig.RotationMethod
    if method == "Always" and ownerRoot and owner then
        rotConn = RunService.Heartbeat:Connect(function()
            if _tick() - startT < duration then
                RotateToTarget(PredictTargetPosition(ownerRoot, owner))
            else rotConn:Disconnect() end
        end)
    elseif method == "Legit" and ownerRoot and owner then
        local locked = HumanoidRootPart.CFrame
        rotConn = RunService.Heartbeat:Connect(function()
            if _tick() - startT < duration then
                HumanoidRootPart.CFrame = CFrame.new(HumanoidRootPart.Position) * (locked - locked.Position)
            else rotConn:Disconnect() end
        end)
    end

    Debris:AddItem(bv, duration)
    task.delay(duration, function()
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
    local canTackle, ball, _, owner = CanTackle()
    if canTackle then
        LastManualTackleTime = now
        PerformTackle(ball, owner)
        if Gui then
            Gui.ManualTackleLabel.Text  = "ManualTackle: EXECUTED!"
            Gui.ManualTackleLabel.Color = Color3.fromRGB(0,255,0)
        end
        task.delay(0.3, function()
            if Gui then Gui.ManualTackleLabel.Color = Color3.fromRGB(255,255,255) end
        end)
        return true
    else
        if Gui then
            Gui.ManualTackleLabel.Text  = "ManualTackle: FAILED"
            Gui.ManualTackleLabel.Color = Color3.fromRGB(255,0,0)
        end
        task.delay(0.3, function()
            if Gui then Gui.ManualTackleLabel.Color = Color3.fromRGB(255,255,255) end
        end)
        return false
    end
end

-- ============================================================
-- TARGET RINGS (3D круги под ногами)
-- ============================================================
local function Create3DCircle(segs)
    local c = {}; segs = segs or 24
    for i = 1, segs do
        local l = Drawing.new("Line")
        l.Thickness = 3; l.Color = Color3.fromRGB(255,0,0); l.Visible = false
        _tins(c, l)
    end
    return c
end

local function Update3DCircle(circle, pos, radius, color)
    local segs = #circle
    local invS = (2 * math.pi) / segs
    local pts  = {}
    for i = 1, segs do
        local a = (i-1)*invS
        _tins(pts, _V3new(pos.X + _mcos(a)*radius, pos.Y, pos.Z + math.sin(a)*radius))
    end
    for i, line in ipairs(circle) do
        local sp = pts[i]; local ep = pts[i%segs+1]
        local ss, sOn = Camera:WorldToViewportPoint(sp)
        local es, eOn = Camera:WorldToViewportPoint(ep)
        if sOn and eOn and ss.Z > 0.1 and es.Z > 0.1 then
            line.From = Vector2.new(ss.X,ss.Y); line.To = Vector2.new(es.X,es.Y)
            line.Color = color; line.Visible = true
        else line.Visible = false end
    end
end

local function Hide3DCircle(circle)
    if not circle then return end
    for _, l in ipairs(circle) do l.Visible = false end
end

local function UpdateTargetCircles()
    local current = {}
    for player, data in pairs(PrecomputedPlayers) do
        if data.IsValid and TackleStates[player] and TackleStates[player].IsTackling then
            current[player] = true
            if not AutoTackleStatus.TargetCircles[player] then
                AutoTackleStatus.TargetCircles[player] = Create3DCircle()
            end
            local circle = AutoTackleStatus.TargetCircles[player]
            local root   = data.RootPart
            if root then
                local dist = data.Distance
                local col  = Color3.fromRGB(255,0,0)
                if dist <= AutoDribbleConfig.DribbleActivationDistance then
                    col = Color3.fromRGB(0,255,0)
                elseif dist <= AutoDribbleConfig.MaxDribbleDistance then
                    col = Color3.fromRGB(255,165,0)
                end
                Update3DCircle(circle, root.Position - _V3new(0,0.5,0), 2, col)
            end
        end
    end
    for player, circle in pairs(AutoTackleStatus.TargetCircles) do
        if not current[player] then Hide3DCircle(circle) end
    end
end

-- ============================================================
-- AUTO TACKLE MODULE
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
        IsTypingInChat = false
        pcall(function()
            local pg = LocalPlayer:FindFirstChild("PlayerGui")
            if not pg then return end
            for _, g in pairs(pg:GetChildren()) do
                if g:IsA("ScreenGui") and g.Name:find("Chat") then
                    local tb = g:FindFirstChild("TextBox", true)
                    if tb and tb:IsFocused() then IsTypingInChat = true end
                end
            end
        end)
    end)

    AutoTackleStatus.InputConnection = UserInputService.InputBegan:Connect(function(input, gp)
        if gp or not AutoTackleConfig.Enabled or not AutoTackleConfig.ManualTackleEnabled then return end
        if IsTypingInChat then return end
        if input.KeyCode == AutoTackleConfig.ManualTackleKeybind then ManualTackleAction() end
    end)

    AutoTackleStatus.Connection = RunService.Heartbeat:Connect(function()
        if not AutoTackleConfig.Enabled then CleanupDebugText(); UpdateDebugVisibility(); return end
        pcall(function()
            local canTackle, ball, dist, owner = CanTackle()
            if not canTackle or not ball then
                if Gui then
                    Gui.TackleTargetLabel.Text    = "Target: None"
                    Gui.TackleDribblingLabel.Text = "isDribbling: false"
                    Gui.TackleTacklingLabel.Text  = "isTackling: false"
                    Gui.TackleWaitLabel.Text      = "Wait: 0.00"
                    Gui.EagleEyeLabel.Text        = "EagleEye: Idle"
                end
                HideBox(Gui and Gui.PredictionBoxLines)
                CurrentTargetOwner = nil
                return
            end
            if Gui then
                Gui.TackleTargetLabel.Text    = "Target: "..(owner and owner.Name or "None")
                Gui.TackleDribblingLabel.Text = "isDribbling: "..tostring(
                    owner and DribbleStates[owner] and DribbleStates[owner].IsDribbling or false)
                Gui.TackleTacklingLabel.Text  = "isTackling: "..tostring(
                    owner and IsSpecificTackle(owner) or false)
                Gui.PingLabel.Text = string.format("Ping: %dms", _mfloor(AutoTackleStatus.Ping*1000+0.5))
            end
            if owner then
                local ownerRoot = owner.Character and owner.Character:FindFirstChild("HumanoidRootPart")
                local ownerChar = owner.Character
                UpdatePredictionBox(ownerRoot, owner, ownerChar)
            end
            if dist <= AutoTackleConfig.TackleDistance then
                PerformTackle(ball, owner); if Gui then Gui.EagleEyeLabel.Text = "Instant Tackle" end; return
            end
            if owner and IsPowerShooting(owner) then
                PerformTackle(ball, owner); if Gui then Gui.EagleEyeLabel.Text = "PowerShooting!" end; return
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
            local state        = DribbleStates[owner] or { IsDribbling=false, LastDribbleEnd=0, IsProcessingDelay=false, HadDribble=false }
            local isDribbling  = state.IsDribbling
            local inCooldown   = DribbleCooldownList[owner] ~= nil

            if AutoTackleConfig.Mode == "OnlyDribble" then
                if inCooldown then
                    PerformTackle(ball, owner); if Gui then Gui.EagleEyeLabel.Text = "OnlyDribble: Tackling!" end
                elseif isDribbling then
                    if Gui then Gui.EagleEyeLabel.Text = "OnlyDribble: Dribbling..." end
                elseif state.IsProcessingDelay then
                    local r = AutoTackleConfig.DribbleDelayTime - (_tick()-state.LastDribbleEnd)
                    if Gui then Gui.TackleWaitLabel.Text = string.format("Wait: %.2f",r) end
                else
                    if Gui then Gui.EagleEyeLabel.Text = "OnlyDribble: Waiting..." end
                end
            elseif AutoTackleConfig.Mode == "EagleEye" then
                local now = _tick()
                if isDribbling then
                    EagleEyeTimers[owner] = nil
                    if Gui then Gui.EagleEyeLabel.Text = "EagleEye: Dribbling" end
                elseif state.IsProcessingDelay then
                    EagleEyeTimers[owner] = nil
                    local r = AutoTackleConfig.DribbleDelayTime - (now-state.LastDribbleEnd)
                    if Gui then Gui.TackleWaitLabel.Text = string.format("DDelay: %.2f",r) end
                elseif inCooldown then
                    PerformTackle(ball, owner); EagleEyeTimers[owner]=nil
                    if Gui then Gui.EagleEyeLabel.Text = "EagleEye: Post-Dribble!" end
                else
                    if not EagleEyeTimers[owner] then
                        local wt = AutoTackleConfig.EagleEyeMinDelay
                            + math.random()*(AutoTackleConfig.EagleEyeMaxDelay-AutoTackleConfig.EagleEyeMinDelay)
                        EagleEyeTimers[owner] = { startTime=now, waitTime=wt }
                    end
                    local timer   = EagleEyeTimers[owner]
                    local elapsed = now - timer.startTime
                    if elapsed >= timer.waitTime then
                        PerformTackle(ball, owner); EagleEyeTimers[owner]=nil
                        if Gui then Gui.EagleEyeLabel.Text = "EagleEye: Tackling!" end
                    else
                        if Gui then
                            Gui.TackleWaitLabel.Text = string.format("Wait: %.2f", timer.waitTime-elapsed)
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
    if AutoTackleStatus.Connection then AutoTackleStatus.Connection:Disconnect(); AutoTackleStatus.Connection=nil end
    if AutoTackleStatus.HeartbeatConnection then AutoTackleStatus.HeartbeatConnection:Disconnect(); AutoTackleStatus.HeartbeatConnection=nil end
    if AutoTackleStatus.InputConnection then AutoTackleStatus.InputConnection:Disconnect(); AutoTackleStatus.InputConnection=nil end
    AutoTackleStatus.Running = false
    CleanupDebugText(); UpdateDebugVisibility()
    for _, circle in pairs(AutoTackleStatus.TargetCircles) do
        for _, l in ipairs(circle) do l:Remove() end
    end
    AutoTackleStatus.TargetCircles = {}
    if notify then notify("AutoTackle","Stopped",true) end
end

-- ============================================================
-- AUTO DRIBBLE MODULE
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
-- ShouldDribbleNow — только Free режим
-- Логика:
--   [0] distFlat <= PointBlankRadius + IsTackling → немедленно (без ВСЯКИХ проверок)
--   [1] distFlat <= DribbleActivationDistance + IsTackling → немедленно
--       (если RequireTackleAnim=false — любой в зоне)
--   [2] Средняя дистанция: скорость > 2.0 + угол + TTC < 0.4
-- ============================================================
local function ShouldDribbleNow(player, data)
    if not player or not data then return false end
    local root = data.RootPart
    if not root then return false end

    local serverCF  = GetMyServerCFrame()
    local myPos     = serverCF.Position
    local tp        = root.Position
    local vel       = data.Velocity
    local vx, vz    = vel.X, vel.Z

    -- Предсказанная позиция с учётом пинга
    local ping   = AutoTackleStatus.Ping
    local predTx = tp.X + vx*ping*1.5
    local predTz = tp.Z + vz*ping*1.5

    local toMeX  = myPos.X - predTx
    local toMeZ  = myPos.Z - predTz
    local distFlat = _msqrt(toMeX*toMeX + toMeZ*toMeZ)

    if distFlat > AutoDribbleConfig.MaxDribbleDistance then
        if Gui then Gui.AngleLabel.Text = string.format("FAR d=%.1f", distFlat) end
        return false
    end

    -- [СТАДИЯ 0] Point blank + tackle → немедленно, никаких проверок
    if distFlat <= AutoDribbleConfig.PointBlankRadius and data.IsTackling then
        if Gui then Gui.AngleLabel.Text = string.format("⚡ POINT BLANK d=%.1f", distFlat) end
        return true
    end

    -- [СТАДИЯ 1] Зона активации
    if distFlat <= AutoDribbleConfig.DribbleActivationDistance then
        local shouldReact = data.IsTackling or (not AutoDribbleConfig.RequireTackleAnim)
        if not shouldReact then
            if Gui then Gui.AngleLabel.Text = string.format("CLOSE no_tackle d=%.1f", distFlat) end
            return false
        end
        if Gui then Gui.AngleLabel.Text = string.format("⚡ CLOSE d=%.1f", distFlat) end
        return true
    end

    -- [СТАДИЯ 2] Средняя дистанция — скорость, угол, TTC
    local speed2D = _msqrt(vx*vx + vz*vz)
    if speed2D < 2.0 then
        if Gui then Gui.AngleLabel.Text = string.format("v=%.1f (slow)", speed2D) end
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
        local deg = math.deg(math.acos(dot))
        Gui.AngleLabel.Text = string.format("A=%.0f° v=%.1f d=%.1f", deg, speed2D, distFlat)
    end

    if dot < GetCosThreshold() then return false end

    -- TTC
    local approach = vx*toMeUX + vz*toMeUZ
    local myVelH   = GetMyVelocityFromHistory()
    local myApp    = -(myVelH.X*toMeUX + myVelH.Z*toMeUZ)
    local relSpeed = approach + _mmax(myApp, 0)
    if relSpeed < 0.5 then return false end
    local ttc = distFlat / _mmax(relSpeed, 1)

    if Gui then Gui.AngleLabel.Text = Gui.AngleLabel.Text..string.format(" t=%.2f", ttc) end
    return ttc < 0.4
end

local function PerformDribble()
    local now = _tick()
    if now - AutoDribbleStatus.LastDribbleTime < 0.02 then return end
    local bools = Workspace:FindFirstChild(LocalPlayer.Name)
        and Workspace[LocalPlayer.Name]:FindFirstChild("Bools")
    if not bools or bools.dribbleDebounce.Value then return end
    pcall(function() ActionRemote:FireServer("Deke") end)
    AutoDribbleStatus.LastDribbleTime = now
    if Gui then
        Gui.DribbleStatusLabel.Text  = "Dribble: Cooldown"
        Gui.DribbleStatusLabel.Color = Color3.fromRGB(255,0,0)
        Gui.AutoDribbleLabel.Text    = "AutoDribble: DEKE!"
    end
end

-- dirty-flag кэш
local _dc = {
    result=false, lastPlayer=nil, lastTacklerPos=Vector3.zero,
    lastMyPos=Vector3.zero, lastIsTackling=false, lastCalcTime=0,
    RECALC=0.008, POS_THRESH=0.15,
}
local function IsCacheDirty(player, data)
    local now = _tick()
    if now - _dc.lastCalcTime > _dc.RECALC then return true end
    if _dc.lastPlayer ~= player then return true end
    if _dc.lastIsTackling ~= data.IsTackling then return true end
    local r = data.RootPart
    if r then
        local cp = _dc.lastTacklerPos; local rp = r.Position
        local dx = rp.X-cp.X; local dz = rp.Z-cp.Z
        if _msqrt(dx*dx+dz*dz) > _dc.POS_THRESH then return true end
    end
    local mp = _dc.lastMyPos; local hp = HumanoidRootPart.Position
    if _msqrt((hp.X-mp.X)^2+(hp.Z-mp.Z)^2) > _dc.POS_THRESH then return true end
    return false
end

local AutoDribble = {}
AutoDribble.Start = function()
    if AutoDribbleStatus.Running then return end
    AutoDribbleStatus.Running = true
    if not Gui then SetupGUI() end

    AutoDribbleStatus.HeartbeatConnection = RunService.Heartbeat:Connect(function()
        if not AutoDribbleConfig.Enabled then return end
        pcall(function()
            UpdatePing(); UpdateDribbleStates(); PrecomputePlayers()
            UpdateTargetCircles(); RecordMyPosition(); UpdateServerPosBox()
        end)
    end)

    AutoDribbleStatus.Connection = RunService.Heartbeat:Connect(function()
        if not AutoDribbleConfig.Enabled then CleanupDebugText(); UpdateDebugVisibility(); return end
        pcall(function()
            if not HasBall or not CanDribbleNow then
                if Gui then Gui.AutoDribbleLabel.Text = "AutoDribble: Idle (no ball)" end
                return
            end
            local target, minDist, count, targetData = nil, math.huge, 0, nil
            for player, data in pairs(PrecomputedPlayers) do
                if data.IsValid and data.IsTackling then
                    count += 1
                    if data.Distance < minDist then
                        minDist = data.Distance; target = player; targetData = data
                    end
                end
            end
            if Gui then
                Gui.DribbleTargetLabel.Text  = "Targets: "..count
                Gui.DribbleTacklingLabel.Text= target
                    and string.format("Tackle: %.1f st", minDist) or "Tackle: None"
            end
            if not target or not targetData then
                if Gui then Gui.AutoDribbleLabel.Text = "AutoDribble: Idle" end
                return
            end
            local shouldFire
            if IsCacheDirty(target, targetData) then
                shouldFire = ShouldDribbleNow(target, targetData)
                _dc.result = shouldFire; _dc.lastCalcTime = _tick()
                _dc.lastPlayer = target; _dc.lastIsTackling = targetData.IsTackling
                if targetData.RootPart then _dc.lastTacklerPos = targetData.RootPart.Position end
                _dc.lastMyPos = HumanoidRootPart.Position
            else
                shouldFire = _dc.result
            end
            if shouldFire then PerformDribble()
            else if Gui then Gui.AutoDribbleLabel.Text = "AutoDribble: Waiting" end end
        end)
    end)

    UpdateDebugVisibility()
    if notify then notify("AutoDribble","Started",true) end
end

AutoDribble.Stop = function()
    if AutoDribbleStatus.Connection then AutoDribbleStatus.Connection:Disconnect(); AutoDribbleStatus.Connection=nil end
    if AutoDribbleStatus.HeartbeatConnection then AutoDribbleStatus.HeartbeatConnection:Disconnect(); AutoDribbleStatus.HeartbeatConnection=nil end
    AutoDribbleStatus.Running = false
    HideBox(Gui and Gui.ServerPosBoxLines)
    HideBox(Gui and Gui.PredictionBoxLines)
    CleanupDebugText(); UpdateDebugVisibility()
    if notify then notify("AutoDribble","Stopped",true) end
end

-- ============================================================
-- UI
-- ============================================================
local uiElements = {}
local function SetupUI(UI)
    if UI.Sections.AutoTackle then
        local S = UI.Sections.AutoTackle
        S:Header({ Name = "AutoTackle" }); S:Divider()
        uiElements.AutoTackleEnabled = S:Toggle({
            Name = "Enabled", Default = AutoTackleConfig.Enabled,
            Callback = function(v)
                AutoTackleConfig.Enabled = v
                if v then AutoTackle.Start() else AutoTackle.Stop() end
                UpdateDebugVisibility()
            end
        }, "AutoTackleEnabled")
        uiElements.AutoTackleMode = S:Dropdown({
            Name = "Mode", Default = AutoTackleConfig.Mode,
            Options = {"OnlyDribble","EagleEye","ManualTackle"},
            Callback = function(v)
                AutoTackleConfig.Mode = v
                if Gui then Gui.ModeLabel.Text = "Mode: "..v end
            end
        }, "AutoTackleMode")
        S:Divider()
        S:Slider({ Name="Max Distance", Minimum=5, Maximum=50,
            Default=AutoTackleConfig.MaxDistance, Precision=1,
            Callback=function(v) AutoTackleConfig.MaxDistance=v end }, "AutoTackleMaxDist")
        S:Slider({ Name="Instant Tackle Distance", Minimum=0, Maximum=20,
            Default=AutoTackleConfig.TackleDistance, Precision=1,
            Callback=function(v) AutoTackleConfig.TackleDistance=v end }, "AutoTackleTackleDist")
        S:Slider({ Name="Tackle Speed", Minimum=10, Maximum=100,
            Default=AutoTackleConfig.TackleSpeed, Precision=1,
            Callback=function(v) AutoTackleConfig.TackleSpeed=v end }, "AutoTackleSpeed")
        S:Divider()
        S:Toggle({ Name="Only Player", Default=AutoTackleConfig.OnlyPlayer,
            Callback=function(v) AutoTackleConfig.OnlyPlayer=v end }, "AutoTackleOnlyPlayer")
        S:Dropdown({ Name="Rotation Method", Default=AutoTackleConfig.RotationMethod,
            Options={"Snap","Legit","Always","None"},
            Callback=function(v) AutoTackleConfig.RotationMethod=v end }, "AutoTackleRot")
        S:Toggle({ Name="Show Prediction Box", Default=AutoTackleConfig.ShowPredictionBox,
            Callback=function(v)
                AutoTackleConfig.ShowPredictionBox=v
                if not v then HideBox(Gui and Gui.PredictionBoxLines) end
                UpdateDebugVisibility()
            end }, "AutoTackleShowPred")
        S:Divider()
        S:Slider({ Name="Dribble Delay", Minimum=0.0, Maximum=2.0,
            Default=AutoTackleConfig.DribbleDelayTime, Precision=2,
            Callback=function(v) AutoTackleConfig.DribbleDelayTime=v end }, "AutoTackleDribDelay")
        S:Slider({ Name="EagleEye Min Delay", Minimum=0.0, Maximum=2.0,
            Default=AutoTackleConfig.EagleEyeMinDelay, Precision=2,
            Callback=function(v) AutoTackleConfig.EagleEyeMinDelay=v end }, "AutoTackleEEMin")
        S:Slider({ Name="EagleEye Max Delay", Minimum=0.0, Maximum=2.0,
            Default=AutoTackleConfig.EagleEyeMaxDelay, Precision=2,
            Callback=function(v) AutoTackleConfig.EagleEyeMaxDelay=v end }, "AutoTackleEEMax")
        S:Divider()
        S:Toggle({ Name="Manual Tackle", Default=AutoTackleConfig.ManualTackleEnabled,
            Callback=function(v) AutoTackleConfig.ManualTackleEnabled=v end }, "AutoTackleMT")
        S:Keybind({
            Name="Manual Tackle Key", Default=AutoTackleConfig.ManualTackleKeybind,
            Callback=function() if AutoTackleConfig.Enabled and AutoTackleConfig.ManualTackleEnabled then ManualTackleAction() end end,
            onBinded=function(v) AutoTackleConfig.ManualTackleKeybind=v end
        }, "AutoTackleMTKey")
    end

    if UI.Sections.AutoDribble then
        local S = UI.Sections.AutoDribble
        S:Header({ Name = "AutoDribble" }); S:Divider()
        uiElements.AutoDribbleEnabled = S:Toggle({
            Name="Enabled", Default=AutoDribbleConfig.Enabled,
            Callback=function(v)
                AutoDribbleConfig.Enabled=v
                if v then AutoDribble.Start() else AutoDribble.Stop() end
                UpdateDebugVisibility()
            end
        }, "AutoDribbleEnabled")
        S:Divider()
        S:Slider({ Name="Max Distance", Minimum=10, Maximum=50,
            Default=AutoDribbleConfig.MaxDribbleDistance, Precision=1,
            Callback=function(v) AutoDribbleConfig.MaxDribbleDistance=v end }, "AutoDribMaxDist")
        S:Slider({ Name="Activation Distance", Minimum=5, Maximum=30,
            Default=AutoDribbleConfig.DribbleActivationDistance, Precision=1,
            Callback=function(v) AutoDribbleConfig.DribbleActivationDistance=v end }, "AutoDribActDist")
        S:Slider({ Name="Max Attack Angle", Minimum=10, Maximum=90,
            Default=AutoDribbleConfig.MinAngleForDribble, Precision=0,
            Callback=function(v) AutoDribbleConfig.MinAngleForDribble=v; _cachedAngleDeg=-1 end }, "AutoDribAngle")
        S:Slider({ Name="Point Blank Radius", Minimum=3, Maximum=15,
            Default=AutoDribbleConfig.PointBlankRadius, Precision=1,
            Callback=function(v) AutoDribbleConfig.PointBlankRadius=v end }, "AutoDribPBR")
        S:Toggle({ Name="Require Tackle Anim", Default=AutoDribbleConfig.RequireTackleAnim,
            Callback=function(v) AutoDribbleConfig.RequireTackleAnim=v end }, "AutoDribReqTackle")
        S:Toggle({ Name="Show Server Pos Box", Default=AutoDribbleConfig.ShowServerPos,
            Callback=function(v)
                AutoDribbleConfig.ShowServerPos=v
                if not v then HideBox(Gui and Gui.ServerPosBoxLines) end
                UpdateDebugVisibility()
            end }, "AutoDribShowServer")
        S:Divider()
    end

    if UI.Sections.Debug then
        local S = UI.Sections.Debug
        S:Header({ Name = "Debug" })
        S:SubLabel({ Text = "* Only for AutoDribble/AutoTackle" })
        S:Divider()
        S:Toggle({ Name="Debug Text", Default=DebugConfig.Enabled,
            Callback=function(v) DebugConfig.Enabled=v; UpdateDebugVisibility() end }, "DebugEnabled")
    end
end

-- ============================================================
-- MODULE
-- ============================================================
local Module = {}
function Module.Init(UI, coreParam, notifyFunc)
    core       = coreParam
    notify     = notifyFunc
    SetupUI(UI)
    LocalPlayer.CharacterAdded:Connect(function(newChar)
        task.wait(1)
        Character        = newChar
        Humanoid         = newChar:WaitForChild("Humanoid")
        HumanoidRootPart = newChar:WaitForChild("HumanoidRootPart")
        DribbleStates    = {}; TackleStates = {}; PrecomputedPlayers = {}
        DribbleCooldownList = {}; EagleEyeTimers = {}
        AutoTackleStatus.TargetPositionHistory = {}
        AutoTackleStatus.TargetCircles         = {}
        MyPositionHistory  = {}
        _cachedAngleDeg    = -1
        CurrentTargetOwner = nil
        if AutoTackleConfig.Enabled and not AutoTackleStatus.Running then AutoTackle.Start() end
        if AutoDribbleConfig.Enabled and not AutoDribbleStatus.Running then AutoDribble.Start() end
    end)
end

function Module:Destroy()
    AutoTackle.Stop(); AutoDribble.Stop()
    if Gui then
        RemoveBox(Gui.ServerPosBoxLines)
        RemoveBox(Gui.PredictionBoxLines)
    end
end

return Module
