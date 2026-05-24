-- [v4.1] AUTO DRIBBLE + AUTO TACKLE
-- Changelog v4.1:
-- [REMOVE] Strict режим полностью удалён
-- [REMOVE] SynchronizeConfigValues полностью удалён
-- [FIX] 3D Box: переписан с нуля по стандарту exploit ESP
--       Drawing.new("Quad") + Character:GetBoundingBox() — без костылей,
--       без ручного расчёта углов, без артефактов при прыжке/движении
--       Quad автоматически следует за реальным bounding box персонажа
-- [FIX] Free режим: если враг в радиусе <= 8 studs и IsTackling — dribble
--       немедленно, без каких-либо проверок скорости/угла/TTC
-- [NEW] RequireTackleAnim toggle (по умолч. false) — если true, AutoDribble
--       в зоне ActivationDistance реагирует ТОЛЬКО при IsTackling
--       если false — реагирует на любого врага в зоне (старое поведение)

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
local _wtvp   = function(p) return Camera:WorldToViewportPoint(p) end

-- ============================================================
-- SERVICES
-- ============================================================
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
    Mode                 = "OnlyDribble",   -- "OnlyDribble" | "EagleEye" | "ManualTackle"
    MaxDistance          = 20,
    TackleDistance       = 0,
    TackleSpeed          = 60,
    OnlyPlayer           = true,
    RotationMethod       = "Snap",          -- "Snap" | "Legit" | "Always" | "None"
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
    DribbleMode               = "Free",     -- только "Free" теперь
    RequireTackleAnim         = false,      -- true = только при IsTackling в зоне активации
    PointBlankRadius          = 8,          -- studs: при <= этой дист + IsTackling → немедленный dribble
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
-- ИСТОРИЯ ПОЗИЦИЙ (предсказание)
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
    return _V3new((np.X-op.X)*inv, (np.Y-op.Y)*inv, (np.Z-op.Z)*inv)
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
    local my2D  = _V3new(myPos.X,0,myPos.Z)
    local t2D   = _V3new(sx,0,sz)
    local iT    = CalcInterceptTime(my2D, t2D, _V3new(vx,0,vz), AutoTackleConfig.TackleSpeed)
    return _V3new(sx+vx*iT, op.Y, sz+vz*iT)
end

-- ============================================================
-- МОЯ СЕРВЕРНАЯ ПОЗИЦИЯ
-- ============================================================
local MY_HISTORY_SIZE = 10
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
    local sp = _V3new(p.X-v.X*nd, p.Y-v.Y*nd, p.Z-v.Z*nd)
    return CFrame.new(sp) * (HumanoidRootPart.CFrame - HumanoidRootPart.CFrame.Position)
end

-- ============================================================
-- 3D BOX — ПРАВИЛЬНАЯ РЕАЛИЗАЦИЯ ЧЕРЕЗ Quad + GetBoundingBox
--
-- Стандарт exploit ESP (Stefanuk12/Base.lua и др.):
-- 1. Character:GetBoundingBox() → реальный CFrame + Size тела без рук-артефактов
-- 2. 8 углов 3D бокса в world space
-- 3. Project через WorldToViewportPoint
-- 4. 4 Drawing.new("Quad") — по одному на каждую грань (перед/зад/лево/право)
--    или 12 Drawing.new("Line") — рёбра
--
-- Мы используем подход "4 Quad грани" — нет артефактов при прыжке,
-- нет ручных смещений, размер всегда соответствует реальному телу.
--
-- GetBoundingBox() включает все BasePart в Character кроме Accessories,
-- для R15 это UpperTorso, LowerTorso, Head, Arms, Legs — точный fit.
-- ============================================================

-- Вычисляет 8 углов бокса из CFrame центра и Size
local function Get8Corners(cf, size)
    local hx = size.X * 0.5
    local hy = size.Y * 0.5
    local hz = size.Z * 0.5
    -- порядок: 4 нижних (Y-), 4 верхних (Y+)
    -- нижние: BL_back, BR_back, BR_front, BL_front
    -- верхние: TL_back, TR_back, TR_front, TL_front
    return {
        cf:PointToWorldSpace(_V3new(-hx, -hy, -hz)),  -- 1: низ-лево-зад
        cf:PointToWorldSpace(_V3new( hx, -hy, -hz)),  -- 2: низ-право-зад
        cf:PointToWorldSpace(_V3new( hx, -hy,  hz)),  -- 3: низ-право-перед
        cf:PointToWorldSpace(_V3new(-hx, -hy,  hz)),  -- 4: низ-лево-перед
        cf:PointToWorldSpace(_V3new(-hx,  hy, -hz)),  -- 5: верх-лево-зад
        cf:PointToWorldSpace(_V3new( hx,  hy, -hz)),  -- 6: верх-право-зад
        cf:PointToWorldSpace(_V3new( hx,  hy,  hz)),  -- 7: верх-право-перед
        cf:PointToWorldSpace(_V3new(-hx,  hy,  hz)),  -- 8: верх-лево-перед
    }
end

-- Проецирует 3D точку в 2D экранные координаты
-- Возвращает Vector2, on_screen (bool)
local function Project(worldPos)
    local sp, on = Camera:WorldToViewportPoint(worldPos)
    return Vector2.new(sp.X, sp.Y), on, sp.Z
end

-- Находит 2D bounding rect из набора 3D точек
-- Возвращает x_min, y_min, x_max, y_max, all_visible
local function GetScreenBounds(corners3D)
    local xMin, yMin, xMax, yMax = math.huge, math.huge, -math.huge, -math.huge
    local anyVisible = false
    for _, wp in ipairs(corners3D) do
        local sp, on, depth = Project(wp)
        if depth > 0 then  -- перед камерой
            anyVisible = true
            if sp.X < xMin then xMin = sp.X end
            if sp.Y < yMin then yMin = sp.Y end
            if sp.X > xMax then xMax = sp.X end
            if sp.Y > yMax then yMax = sp.Y end
        end
    end
    return xMin, yMin, xMax, yMax, anyVisible
end

-- ESP box структура: использует Drawing.new("Square") — это стандартный
-- 2D прямоугольник, автоматически перестраивается из screen bounds.
-- Это надёжнее чем Quad или Lines для box ESP т.к не зависит от ориентации камеры.
-- Outline = отдельный Square чуть толще для читаемости.
local function CreateESPBox(color, thickness)
    local outline = Drawing.new("Square")
    outline.Color     = Color3.fromRGB(0, 0, 0)
    outline.Thickness = (thickness or 1.5) + 1
    outline.Filled    = false
    outline.Visible   = false

    local box = Drawing.new("Square")
    box.Color     = color or Color3.fromRGB(0, 200, 255)
    box.Thickness = thickness or 1.5
    box.Filled    = false
    box.Visible   = false

    return { box = box, outline = outline }
end

-- Обновляет ESP box из Character:GetBoundingBox()
-- character — Instance типа Model (персонаж игрока)
-- espObj — { box, outline } из CreateESPBox
-- color — опциональный Color3
local function UpdateESPBox(espObj, character, color)
    if not espObj or not character or not character.Parent then
        if espObj then
            espObj.box.Visible     = false
            espObj.outline.Visible = false
        end
        return
    end

    -- GetBoundingBox() на Character даёт точный fit по всем частям тела
    local ok, cf, size = pcall(function()
        return character:GetBoundingBox()
    end)
    if not ok or not cf then
        espObj.box.Visible     = false
        espObj.outline.Visible = false
        return
    end

    -- Получаем 8 углов в world space
    local corners = Get8Corners(cf, size)

    -- Проецируем в экранные bounds
    local xMin, yMin, xMax, yMax, anyVis = GetScreenBounds(corners)

    if not anyVis or xMax <= xMin or yMax <= yMin then
        espObj.box.Visible     = false
        espObj.outline.Visible = false
        return
    end

    local w = xMax - xMin
    local h = yMax - yMin

    -- Drawing.Square: Position = top-left corner, Size = Vector2(width, height)
    local pos  = Vector2.new(xMin, yMin)
    local sz   = Vector2.new(w, h)

    if color then espObj.box.Color = color end

    espObj.box.Position    = pos
    espObj.box.Size        = sz
    espObj.box.Visible     = true

    espObj.outline.Position = pos
    espObj.outline.Size     = sz
    espObj.outline.Visible  = true
end

local function HideESPBox(espObj)
    if not espObj then return end
    espObj.box.Visible     = false
    espObj.outline.Visible = false
end

local function RemoveESPBox(espObj)
    if not espObj then return end
    pcall(function() espObj.box:Remove() end)
    pcall(function() espObj.outline:Remove() end)
end

-- ============================================================
-- GUI (Drawing text labels)
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
        -- ESP boxes
        ServerPosBox         = nil,
        PredictionBox        = nil,
        TargetCircles        = {},
        TackleDebugLabels    = {},
        DribbleDebugLabels   = {},
    }

    -- v4.1: ESP boxes через новую систему
    Gui.ServerPosBox  = CreateESPBox(Color3.fromRGB(0, 200, 255), 1.5)
    Gui.PredictionBox = CreateESPBox(Color3.fromRGB(255, 165, 0), 1.5)

    local sv   = Camera.ViewportSize
    local cx   = sv.X / 2
    local tY   = sv.Y * 0.6
    local offT = tY + 30
    local offD = tY - 50

    local tackleLabels = {
        Gui.TackleWaitLabel, Gui.TackleTargetLabel, Gui.TackleDribblingLabel,
        Gui.TackleTacklingLabel, Gui.EagleEyeLabel, Gui.CooldownListLabel,
        Gui.ModeLabel, Gui.ManualTackleLabel, Gui.PingLabel,
        Gui.AngleLabel, Gui.PredictionLabel, Gui.ServerPosLabel,
    }
    for _, lbl in ipairs(tackleLabels) do
        lbl.Size=16; lbl.Color=Color3.fromRGB(255,255,255)
        lbl.Outline=true; lbl.Center=true; lbl.Visible=false
        _tins(Gui.TackleDebugLabels, lbl)
    end
    Gui.TackleWaitLabel.Color = Color3.fromRGB(255,165,0)
    Gui.ServerPosLabel.Color  = Color3.fromRGB(0,200,255)

    local function pos(lbl, y) lbl.Position = Vector2.new(cx, y) end
    pos(Gui.TackleWaitLabel,      offT); offT+=15
    pos(Gui.TackleTargetLabel,    offT); offT+=15
    pos(Gui.TackleDribblingLabel, offT); offT+=15
    pos(Gui.TackleTacklingLabel,  offT); offT+=15
    pos(Gui.EagleEyeLabel,        offT); offT+=15
    pos(Gui.CooldownListLabel,    offT); offT+=15
    pos(Gui.ModeLabel,            offT); offT+=15
    pos(Gui.ManualTackleLabel,    offT); offT+=15
    pos(Gui.PingLabel,            offT); offT+=15
    pos(Gui.AngleLabel,           offT); offT+=15
    pos(Gui.PredictionLabel,      offT); offT+=15
    pos(Gui.ServerPosLabel,       offT)

    local dribbleLabels = {
        Gui.DribbleStatusLabel, Gui.DribbleTargetLabel,
        Gui.DribbleTacklingLabel, Gui.AutoDribbleLabel,
    }
    for _, lbl in ipairs(dribbleLabels) do
        lbl.Size=16; lbl.Color=Color3.fromRGB(255,255,255)
        lbl.Outline=true; lbl.Center=true; lbl.Visible=false
        _tins(Gui.DribbleDebugLabels, lbl)
    end
    pos(Gui.DribbleStatusLabel,   offD); offD+=15
    pos(Gui.DribbleTargetLabel,   offD); offD+=15
    pos(Gui.DribbleTacklingLabel, offD); offD+=15
    pos(Gui.AutoDribbleLabel,     offD)

    -- Default texts
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
    Gui.PredictionLabel.Text      = "Pred: -"
    Gui.ServerPosLabel.Text       = "ServerPos: -"
    Gui.DribbleStatusLabel.Text   = "Dribble: Ready"
    Gui.DribbleTargetLabel.Text   = "Targets: 0"
    Gui.DribbleTacklingLabel.Text = "Nearest: None"
    Gui.AutoDribbleLabel.Text     = "AutoDribble: Idle"
end

-- ============================================================
-- v4.1: UpdateServerPosBox — рисует box вокруг моей server-side позиции
-- Создаём "фантомный" Character clone в памяти — нет, лучше просто
-- рисуем box из реального Character но смещённый на serverOffset.
-- Используем прямой GetBoundingBox() + offset CFrame.
-- ============================================================
local function UpdateServerPosBox()
    if not Gui or not Gui.ServerPosBox then return end
    if not AutoDribbleConfig.Enabled or not AutoDribbleConfig.ShowServerPos then
        HideESPBox(Gui.ServerPosBox)
        if Gui.ServerPosLabel then Gui.ServerPosLabel.Text = "ServerPos: -" end
        return
    end

    local ok, cf, size = pcall(function() return Character:GetBoundingBox() end)
    if not ok or not cf then HideESPBox(Gui.ServerPosBox); return end

    -- Смещаем CFrame на разницу между текущей позицией и серверной
    local serverCF  = GetMyServerCFrame()
    local myPos     = HumanoidRootPart.Position
    local serverPos = serverCF.Position
    local offset    = serverPos - myPos
    -- Применяем offset к bounding box CFrame (только позиция, ориентация та же)
    local serverBoxCF = CFrame.new(cf.Position + offset) * (cf - cf.Position)

    local corners = Get8Corners(serverBoxCF, size)
    local xMin, yMin, xMax, yMax, anyVis = GetScreenBounds(corners)

    if not anyVis or xMax <= xMin or yMax <= yMin then
        HideESPBox(Gui.ServerPosBox)
        return
    end

    local pos2 = Vector2.new(xMin, yMin)
    local sz2  = Vector2.new(xMax-xMin, yMax-yMin)

    Gui.ServerPosBox.box.Position     = pos2
    Gui.ServerPosBox.box.Size         = sz2
    Gui.ServerPosBox.box.Visible      = true
    Gui.ServerPosBox.outline.Position = pos2
    Gui.ServerPosBox.outline.Size     = sz2
    Gui.ServerPosBox.outline.Visible  = true

    if Gui.ServerPosLabel and DebugConfig.Enabled then
        local delay = _mfloor(AutoTackleStatus.Ping * 1.5 * 1000 + 0.5)
        local dv = offset
        local dist = _msqrt(dv.X*dv.X + dv.Y*dv.Y + dv.Z*dv.Z)
        Gui.ServerPosLabel.Text = string.format("ServerPos: %dms | %.1f studs", delay, dist)
    end
end

-- ============================================================
-- UpdatePredictionBox — box вокруг предсказанной позиции цели
-- ============================================================
local function UpdatePredictionBox(ownerRoot, player)
    if not Gui or not Gui.PredictionBox then return end
    if not AutoTackleConfig.Enabled or not AutoTackleConfig.ShowPredictionBox then
        HideESPBox(Gui.PredictionBox); return
    end
    if not ownerRoot or not player then
        HideESPBox(Gui.PredictionBox); return
    end
    local ownerChar = player.Character
    if not ownerChar then HideESPBox(Gui.PredictionBox); return end

    -- Предсказанная позиция
    local predictedPos = PredictTargetPosition(ownerRoot, player)
    -- Получаем bounding box персонажа и смещаем на разницу
    local ok, cf, size = pcall(function() return ownerChar:GetBoundingBox() end)
    if not ok or not cf then HideESPBox(Gui.PredictionBox); return end

    local currentPos  = ownerRoot.Position
    local offset      = predictedPos - currentPos
    local predBoxCF   = CFrame.new(cf.Position + offset) * (cf - cf.Position)

    local corners = Get8Corners(predBoxCF, size)
    local xMin, yMin, xMax, yMax, anyVis = GetScreenBounds(corners)

    if not anyVis or xMax <= xMin or yMax <= yMin then
        HideESPBox(Gui.PredictionBox); return
    end

    local pos2 = Vector2.new(xMin, yMin)
    local sz2  = Vector2.new(xMax-xMin, yMax-yMin)

    Gui.PredictionBox.box.Position     = pos2
    Gui.PredictionBox.box.Size         = sz2
    Gui.PredictionBox.box.Visible      = true
    Gui.PredictionBox.outline.Position = pos2
    Gui.PredictionBox.outline.Size     = sz2
    Gui.PredictionBox.outline.Visible  = true

    if Gui.PredictionLabel and DebugConfig.Enabled then
        local vel = GetPositionBasedVelocity(player)
        local vx, vz = vel.X, vel.Z
        local ping = AutoTackleStatus.Ping
        local myPos = HumanoidRootPart.Position
        local dx = predictedPos.X - myPos.X; local dz = predictedPos.Z - myPos.Z
        local dist = _msqrt(dx*dx + dz*dz)
        local iT = CalcInterceptTime(
            _V3new(myPos.X,0,myPos.Z),
            _V3new(predictedPos.X,0,predictedPos.Z),
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

local function UpdateDebugVisibility()
    if not Gui then return end
    local tV = DebugConfig.Enabled and AutoTackleConfig.Enabled
    for _, lbl in ipairs(Gui.TackleDebugLabels) do lbl.Visible = tV end
    local dV = DebugConfig.Enabled and AutoDribbleConfig.Enabled
    for _, lbl in ipairs(Gui.DribbleDebugLabels) do lbl.Visible = dV end
    if not AutoTackleConfig.Enabled then
        if Gui.PredictionBox then HideESPBox(Gui.PredictionBox) end
    end
    if not AutoDribbleConfig.Enabled or not AutoDribbleConfig.ShowServerPos then
        if Gui.ServerPosBox then HideESPBox(Gui.ServerPosBox) end
    end
    if not AutoTackleConfig.Enabled or not AutoTackleConfig.ShowPredictionBox then
        if Gui.PredictionBox then HideESPBox(Gui.PredictionBox) end
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
        Gui.PredictionLabel.Text      = "Pred: -"
    end
    if not AutoDribbleConfig.Enabled then
        Gui.DribbleStatusLabel.Text   = "Dribble: Ready"
        Gui.DribbleTargetLabel.Text   = "Targets: 0"
        Gui.DribbleTacklingLabel.Text = "Nearest: None"
        Gui.AutoDribbleLabel.Text     = "AutoDribble: Idle"
        HideESPBox(Gui.ServerPosBox)
    end
end

-- ============================================================
-- 3D КРУГИ (для целей такла)
-- ============================================================
local function Create3DCircle()
    local c = {}
    for i = 1, 24 do
        local l = Drawing.new("Line")
        l.Thickness=3; l.Color=Color3.fromRGB(255,0,0); l.Visible=false
        _tins(c, l)
    end
    return c
end

local function Update3DCircle(circle, position, radius, color)
    if not circle then return end
    local seg = #circle
    local pts = {}
    local px, pz, py = position.X, position.Z, position.Y
    local step = (2 * math.pi) / seg
    for i = 1, seg do
        local a = (i-1) * step
        _tins(pts, _V3new(px + _mcos(a)*radius, py, pz + math.sin(a)*radius))
    end
    for i, line in ipairs(circle) do
        local s = pts[i]; local e = pts[i%seg+1]
        local ss, son = Camera:WorldToViewportPoint(s)
        local es, eon = Camera:WorldToViewportPoint(e)
        if son and eon and ss.Z>0.1 and es.Z>0.1 then
            line.From=Vector2.new(ss.X,ss.Y); line.To=Vector2.new(es.X,es.Y)
            line.Color=color; line.Visible=true
        else
            line.Visible=false
        end
    end
end

local function Hide3DCircle(c)
    if not c then return end
    for _, l in ipairs(c) do l.Visible=false end
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
            local tr = data.RootPart
            if tr then
                local dist = data.Distance
                local col = Color3.fromRGB(255,0,0)
                if dist <= AutoDribbleConfig.DribbleActivationDistance then
                    col = Color3.fromRGB(0,255,0)
                elseif dist <= AutoDribbleConfig.MaxDribbleDistance then
                    col = Color3.fromRGB(255,165,0)
                end
                Update3DCircle(circle, tr.Position - _V3new(0,0.5,0), 2, col)
            end
        end
    end
    for player, circle in pairs(AutoTackleStatus.TargetCircles) do
        if not current[player] then Hide3DCircle(circle) end
    end
end

-- ============================================================
-- DEBUG TEXT MOVE
-- ============================================================
local function SetupDebugMovement()
    if not DebugConfig.MoveEnabled or not Gui then return end
    local dragging = false; local dragStart = Vector2.new(0,0)
    local startPos = {}
    for _, lbl in ipairs(Gui.TackleDebugLabels)  do startPos[lbl] = lbl.Position end
    for _, lbl in ipairs(Gui.DribbleDebugLabels) do startPos[lbl] = lbl.Position end

    UserInputService.InputBegan:Connect(function(inp, gp)
        if gp or not DebugConfig.MoveEnabled then return end
        if inp.UserInputType == Enum.UserInputType.MouseButton1 then
            local mp = UserInputService:GetMouseLocation()
            for lbl, _ in pairs(startPos) do
                if lbl.Visible then
                    local p = lbl.Position; local tb = lbl.TextBounds
                    if mp.X >= p.X-tb.X*0.5 and mp.X <= p.X+tb.X*0.5 and
                       mp.Y >= p.Y-tb.Y*0.5 and mp.Y <= p.Y+tb.Y*0.5 then
                        dragging=true; dragStart=mp; break
                    end
                end
            end
        end
    end)
    UserInputService.InputChanged:Connect(function(inp, gp)
        if gp or not DebugConfig.MoveEnabled or not dragging then return end
        if inp.UserInputType == Enum.UserInputType.MouseMovement then
            local delta = UserInputService:GetMouseLocation() - dragStart
            for lbl, sp in pairs(startPos) do if lbl.Visible then lbl.Position = sp + delta end end
        end
    end)
    UserInputService.InputEnded:Connect(function(inp, gp)
        if gp or not DebugConfig.MoveEnabled then return end
        if inp.UserInputType == Enum.UserInputType.MouseButton1 and dragging then
            local delta = UserInputService:GetMouseLocation() - dragStart
            for lbl, sp in pairs(startPos) do startPos[lbl] = sp + delta end
            dragging = false
        end
    end)
end

local function CheckIfTypingInChat()
    local ok, result = pcall(function()
        local pg = LocalPlayer:WaitForChild("PlayerGui")
        for _, gui in pairs(pg:GetChildren()) do
            if gui:IsA("ScreenGui") and (gui.Name == "Chat" or gui.Name:find("Chat")) then
                local tb = gui:FindFirstChild("TextBox", true)
                if tb then return tb:IsFocused() end
            end
        end
        return false
    end)
    return ok and result or false
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
                IsDribbling=false, LastDribbleEnd=0,
                IsProcessingDelay=false, HadDribble=false
            }
        end
        local st = DribbleStates[player]
        local isDrib = IsDribbling(player)
        if isDrib and not st.IsDribbling then
            st.IsDribbling=true; st.IsProcessingDelay=false; st.HadDribble=true
        elseif not isDrib and st.IsDribbling then
            st.IsDribbling=false; st.LastDribbleEnd=now; st.IsProcessingDelay=true
        elseif st.IsProcessingDelay and not isDrib then
            if now - st.LastDribbleEnd >= AutoTackleConfig.DribbleDelayTime then
                DribbleCooldownList[player] = now + 3.5
                st.IsProcessingDelay = false
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
        DribbleCooldownList[p] = nil; EagleEyeTimers[p] = nil
    end
    if Gui and AutoTackleConfig.Enabled then
        local cnt = 0
        for _ in pairs(DribbleCooldownList) do cnt += 1 end
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
            Gui.DribbleStatusLabel.Text  = bools.dribbleDebounce.Value
                and "Dribble: Cooldown" or "Dribble: Ready"
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
        TackleStates[player] = TackleStates[player] or { IsTackling=false }
        TackleStates[player].IsTackling = IsSpecificTackle(player)
        local tp = root.Position
        local dx = tp.X-myPos.X; local dy = tp.Y-myPos.Y; local dz = tp.Z-myPos.Z
        local dist = _msqrt(dx*dx + dy*dy + dz*dz)
        if dist > AutoDribbleConfig.MaxDribbleDistance then continue end
        local alv    = root.AssemblyLinearVelocity
        local posVel = GetPositionBasedVelocity(player)
        local vel    = alv.Magnitude >= posVel.Magnitude and alv or posVel
        PrecomputedPlayers[player] = {
            Distance   = dist,
            IsValid    = true,
            IsTackling = TackleStates[player].IsTackling,
            RootPart   = root,
            Character  = char,
            Velocity   = vel,
        }
        if dist <= AutoDribbleConfig.DribbleActivationDistance * 1.5 then
            RecordTargetPosition(root, player)
        end
    end
end

-- ============================================================
-- ПИНГ UPDATE
-- ============================================================
local function UpdatePing()
    local now = _tick()
    if now - AutoTackleStatus.LastPingUpdate > 1 then
        AutoTackleStatus.Ping = GetPing()
        AutoTackleStatus.LastPingUpdate = now
        if Gui and AutoTackleConfig.Enabled then
            Gui.PingLabel.Text = string.format("Ping: %dms",
                _mfloor(AutoTackleStatus.Ping*1000+0.5))
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
-- CanTackle
-- ============================================================
local function CanTackle()
    local ball = Workspace:FindFirstChild("ball")
    if not ball or not ball.Parent then return false,nil,nil,nil end
    local hasOwner = ball:FindFirstChild("playerWeld") and ball:FindFirstChild("creator")
    local owner    = hasOwner and ball.creator.Value or nil
    if AutoTackleConfig.OnlyPlayer and (not hasOwner or not owner or not owner.Parent) then
        return false,nil,nil,nil
    end
    if not owner or owner.TeamColor == LocalPlayer.TeamColor then
        return false,nil,nil,nil
    end
    local wBools = Workspace:FindFirstChild("Bools")
    if wBools and (wBools.APG.Value == LocalPlayer or wBools.HPG.Value == LocalPlayer) then
        return false,nil,nil,nil
    end
    local bv   = HumanoidRootPart.Position - ball.Position
    local dist = _msqrt(bv.X*bv.X + bv.Y*bv.Y + bv.Z*bv.Z)
    if dist > AutoTackleConfig.MaxDistance then return false,nil,nil,nil end
    if owner.Character then
        local oh = owner.Character:FindFirstChild("Humanoid")
        if oh and oh.HipHeight >= 4 then return false,nil,nil,nil end
    end
    local bools = Workspace:FindFirstChild(LocalPlayer.Name)
        and Workspace[LocalPlayer.Name]:FindFirstChild("Bools")
    if bools and (bools.TackleDebounce.Value or bools.Tackled.Value
       or (Character:FindFirstChild("Bools") and Character.Bools.Debounce.Value)) then
        return false,nil,nil,nil
    end
    return true, ball, dist, owner
end

-- ============================================================
-- PERFORM TACKLE
-- ============================================================
local function PerformTackle(ball, owner)
    local bools = Workspace:FindFirstChild(LocalPlayer.Name)
        and Workspace[LocalPlayer.Name]:FindFirstChild("Bools")
    if not bools or bools.TackleDebounce.Value or bools.Tackled.Value
       or (Character:FindFirstChild("Bools") and Character.Bools.Debounce.Value) then return end

    local ownerRoot = owner and owner.Character and owner.Character:FindFirstChild("HumanoidRootPart")
    local predictedPos
    if ownerRoot and owner then
        predictedPos = PredictTargetPosition(ownerRoot, owner)
    else
        predictedPos = ball.Position
    end
    RotateToTarget(predictedPos)

    if ownerRoot and owner then
        UpdatePredictionBox(ownerRoot, owner)
    end

    if ownerRoot then
        local fv   = HumanoidRootPart.Position - ownerRoot.Position
        local dist = _msqrt(fv.X*fv.X + fv.Y*fv.Y + fv.Z*fv.Z)
        if dist <= 10 then
            pcall(function() firetouchinterest(HumanoidRootPart, ownerRoot, 0) end)
            pcall(function() firetouchinterest(HumanoidRootPart, ownerRoot, 1) end)
        end
    end

    pcall(function() ActionRemote:FireServer("TackIe") end)

    local bv = Instance.new("BodyVelocity")
    bv.Parent   = HumanoidRootPart
    bv.Velocity = HumanoidRootPart.CFrame.LookVector * AutoTackleConfig.TackleSpeed
    bv.MaxForce = _V3new(50000000,0,50000000)
    local startT = _tick()
    local dur    = 0.65
    local rotConn

    if AutoTackleConfig.RotationMethod == "Always" and ownerRoot and owner then
        rotConn = RunService.Heartbeat:Connect(function()
            if _tick()-startT < dur then
                RotateToTarget(PredictTargetPosition(ownerRoot, owner))
            else rotConn:Disconnect() end
        end)
    elseif AutoTackleConfig.RotationMethod == "Legit" and ownerRoot and owner then
        local locked = HumanoidRootPart.CFrame
        rotConn = RunService.Heartbeat:Connect(function()
            if _tick()-startT < dur then
                HumanoidRootPart.CFrame = CFrame.new(HumanoidRootPart.Position)
                    * (locked - locked.Position)
            else rotConn:Disconnect() end
        end)
    end

    Debris:AddItem(bv, dur)
    task.delay(dur, function()
        if rotConn then rotConn:Disconnect() end
    end)

    if owner and ball:FindFirstChild("playerWeld") then
        local dv   = HumanoidRootPart.Position - ball.Position
        local dist = _msqrt(dv.X*dv.X + dv.Y*dv.Y + dv.Z*dv.Z)
        pcall(function() SoftDisPlayerRemote:FireServer(owner, dist, false, ball.Size) end)
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
        if Gui and AutoTackleConfig.Enabled then
            Gui.ManualTackleLabel.Text  = "ManualTackle: EXECUTED! [" .. tostring(AutoTackleConfig.ManualTackleKeybind) .. "]"
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
            Gui.ManualTackleLabel.Text  = "ManualTackle: FAILED [" .. tostring(AutoTackleConfig.ManualTackleKeybind) .. "]"
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
-- AUTOTACKLE
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
            local canTackle, ball, distance, owner = CanTackle()
            if not canTackle or not ball then
                if Gui then
                    Gui.TackleTargetLabel.Text    = "Target: None"
                    Gui.TackleDribblingLabel.Text = "isDribbling: false"
                    Gui.TackleTacklingLabel.Text  = "isTackling: false"
                    Gui.TackleWaitLabel.Text      = "Wait: 0.00"
                    Gui.EagleEyeLabel.Text        = "EagleEye: Idle"
                end
                HideESPBox(Gui and Gui.PredictionBox)
                CurrentTargetOwner = nil
                return
            end

            if Gui then
                Gui.TackleTargetLabel.Text    = "Target: " .. (owner and owner.Name or "None")
                Gui.TackleDribblingLabel.Text = "isDribbling: " ..
                    tostring(owner and DribbleStates[owner] and DribbleStates[owner].IsDribbling or false)
                Gui.TackleTacklingLabel.Text  = "isTackling: " ..
                    tostring(owner and IsSpecificTackle(owner) or false)
                Gui.PingLabel.Text = string.format("Ping: %dms",
                    _mfloor(AutoTackleStatus.Ping*1000+0.5))
            end

            if owner then
                local oRoot = owner.Character and owner.Character:FindFirstChild("HumanoidRootPart")
                if oRoot then UpdatePredictionBox(oRoot, owner) end
            end

            -- Instant tackle при дистанции
            if distance <= AutoTackleConfig.TackleDistance then
                PerformTackle(ball, owner)
                if Gui then Gui.EagleEyeLabel.Text = "Instant Tackle" end
                return
            end

            -- PowerShooting
            if owner and IsPowerShooting(owner) then
                PerformTackle(ball, owner)
                if Gui then Gui.EagleEyeLabel.Text = "PowerShooting: Tackling!" end
                return
            end

            CurrentTargetOwner = owner
            if AutoTackleConfig.Mode == "ManualTackle" then
                if Gui then
                    Gui.EagleEyeLabel.Text     = "ManualTackle: Ready"
                    Gui.ManualTackleLabel.Text  = "ManualTackle: READY [" .. tostring(AutoTackleConfig.ManualTackleKeybind) .. "]"
                    Gui.ManualTackleLabel.Color = Color3.fromRGB(0,255,0)
                end
                return
            end

            if not owner then return end

            local st          = DribbleStates[owner] or { IsDribbling=false, LastDribbleEnd=0, IsProcessingDelay=false }
            local isDribbling  = st.IsDribbling
            local inCooldown   = DribbleCooldownList[owner] ~= nil
            local now          = _tick()

            if AutoTackleConfig.Mode == "OnlyDribble" then
                if inCooldown then
                    PerformTackle(ball, owner)
                    if Gui then Gui.EagleEyeLabel.Text = "OnlyDribble: Tackling!" end
                elseif isDribbling then
                    if Gui then
                        Gui.EagleEyeLabel.Text   = "OnlyDribble: Dribbling..."
                        Gui.TackleWaitLabel.Text = string.format("DDelay: %.2f", AutoTackleConfig.DribbleDelayTime)
                    end
                elseif st.IsProcessingDelay then
                    local remaining = AutoTackleConfig.DribbleDelayTime - (now - st.LastDribbleEnd)
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
                if isDribbling then
                    EagleEyeTimers[owner] = nil
                    if Gui then
                        Gui.TackleWaitLabel.Text = "Wait: DRIBBLE"
                        Gui.EagleEyeLabel.Text   = "EagleEye: Dribbling (reset)"
                    end
                elseif st.IsProcessingDelay then
                    EagleEyeTimers[owner] = nil
                    if Gui then
                        Gui.TackleWaitLabel.Text = string.format("DDelay: %.2f",
                            AutoTackleConfig.DribbleDelayTime - (now - st.LastDribbleEnd))
                        Gui.EagleEyeLabel.Text   = "EagleEye: DribbleDelay"
                    end
                elseif inCooldown then
                    PerformTackle(ball, owner)
                    EagleEyeTimers[owner] = nil
                    if Gui then Gui.EagleEyeLabel.Text = "EagleEye: Post-Dribble Tackle!" end
                else
                    if not EagleEyeTimers[owner] then
                        local w = AutoTackleConfig.EagleEyeMinDelay +
                            math.random() * (AutoTackleConfig.EagleEyeMaxDelay - AutoTackleConfig.EagleEyeMinDelay)
                        EagleEyeTimers[owner] = { startTime=now, waitTime=w }
                    end
                    local timer   = EagleEyeTimers[owner]
                    local elapsed = now - timer.startTime
                    if elapsed >= timer.waitTime then
                        PerformTackle(ball, owner)
                        EagleEyeTimers[owner] = nil
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
    for _, circle in pairs(AutoTackleStatus.TargetCircles) do
        for _, l in ipairs(circle) do l:Remove() end
    end
    AutoTackleStatus.TargetCircles = {}
    if notify then notify("AutoTackle", "Stopped", true) end
end

-- ============================================================
-- AUTODRIBBLE — v4.1
-- ============================================================
-- Кэш для angle threshold
local _cachedAngleDeg  = -1
local _cachedCosThresh = 0
local function GetCosThreshold()
    if AutoDribbleConfig.MinAngleForDribble ~= _cachedAngleDeg then
        _cachedAngleDeg  = AutoDribbleConfig.MinAngleForDribble
        _cachedCosThresh = _mcos(_mrad(_cachedAngleDeg))
    end
    return _cachedCosThresh
end

-- Exponential smoothing скорости
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
-- ShouldDribbleNow v4.1 — Free режим
--
-- Логика:
-- [0] PointBlank (dist <= PointBlankRadius) + IsTackling → немедленно, без проверок
-- [1] Зона активации (dist <= DribbleActivationDistance):
--     если RequireTackleAnim=true → только при IsTackling
--     если RequireTackleAnim=false → любой враг в зоне
-- [2] Средняя дистанция: проверка скорости + угол + TTC
-- Strict режим УДАЛЁН
-- ============================================================
local function ShouldDribbleNow(specificTarget, tacklerData)
    if not specificTarget or not tacklerData then return false end
    local tacklerRoot = tacklerData.RootPart
    if not tacklerRoot then return false end

    local serverCF    = GetMyServerCFrame()
    local myServerPos = serverCF.Position
    local msx, msz    = myServerPos.X, myServerPos.Z

    local vel      = GetSmoothedVelocity(specificTarget, tacklerData.Velocity)
    local vx, vz   = vel.X, vel.Z
    local speed2D  = _msqrt(vx*vx + vz*vz)

    local ping  = AutoTackleStatus.Ping
    local tp    = tacklerRoot.Position
    -- Предсказанная позиция через пинг*1.5
    local predTx = tp.X + vx*ping*1.5
    local predTz = tp.Z + vz*ping*1.5

    local toMeX  = msx - predTx
    local toMeZ  = msz - predTz
    local distFlat = _msqrt(toMeX*toMeX + toMeZ*toMeZ)

    if distFlat > AutoDribbleConfig.MaxDribbleDistance then
        if Gui and AutoDribbleConfig.Enabled then
            Gui.AngleLabel.Text = string.format("FAR d=%.1f", distFlat)
        end
        return false
    end

    -- [СТАДИЯ 0] Point blank + IsTackling → немедленно
    if distFlat <= AutoDribbleConfig.PointBlankRadius and tacklerData.IsTackling then
        if Gui and AutoDribbleConfig.Enabled then
            Gui.AngleLabel.Text = string.format("⚡ POINT BLANK d=%.1f", distFlat)
        end
        return true
    end

    -- [СТАДИЯ 1] Зона активации
    if distFlat <= AutoDribbleConfig.DribbleActivationDistance then
        if AutoDribbleConfig.RequireTackleAnim and not tacklerData.IsTackling then
            if Gui and AutoDribbleConfig.Enabled then
                Gui.AngleLabel.Text = string.format("CLOSE d=%.1f NO_TACKLE", distFlat)
            end
            return false
        end
        -- RequireTackleAnim=false: реагируем на любого в зоне
        -- RequireTackleAnim=true: только при IsTackling
        if Gui and AutoDribbleConfig.Enabled then
            Gui.AngleLabel.Text = string.format("⚡ ZONE d=%.1f", distFlat)
        end
        return true
    end

    -- [СТАДИЯ 2] Средняя дистанция — проверка скорости + угол + TTC
    if speed2D < 2.0 then
        if Gui and AutoDribbleConfig.Enabled then
            Gui.AngleLabel.Text = string.format("v=%.1f (slow)", speed2D)
        end
        return false
    end

    local invDist   = 1 / _mmax(distFlat, 0.001)
    local toMeUX    = toMeX * invDist
    local toMeUZ    = toMeZ * invDist
    local invSpeed  = 1 / _mmax(speed2D, 0.001)
    local dirVX     = vx * invSpeed
    local dirVZ     = vz * invSpeed
    local dot       = _mclamp(dirVX*toMeUX + dirVZ*toMeUZ, -1, 1)
    local cosThresh = GetCosThreshold()

    if Gui and AutoDribbleConfig.Enabled then
        local angleDeg = math.deg(math.acos(dot))
        Gui.AngleLabel.Text = string.format("A=%.0f° v=%.1f d=%.1f", angleDeg, speed2D, distFlat)
    end

    if dot < cosThresh then return false end

    -- TTC
    local approach = vx*toMeUX + vz*toMeUZ
    local myVelH   = GetMyVelocityFromHistory()
    local myApp    = -(myVelH.X*toMeUX + myVelH.Z*toMeUZ)
    local relSpeed = approach + _mmax(myApp, 0)
    if relSpeed < 0.5 then return false end
    local ttc = distFlat / _mmax(relSpeed, 1)

    if Gui and AutoDribbleConfig.Enabled then
        Gui.AngleLabel.Text = Gui.AngleLabel.Text .. string.format(" t=%.2f", ttc)
    end

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
    if Gui and AutoDribbleConfig.Enabled then
        Gui.DribbleStatusLabel.Text  = "Dribble: Cooldown"
        Gui.DribbleStatusLabel.Color = Color3.fromRGB(255,0,0)
        Gui.AutoDribbleLabel.Text    = "AutoDribble: DEKE!"
    end
end

-- Dirty-flag кэш для ShouldDribbleNow
local _dc = {
    result=false, lastPlayer=nil, lastTacklerPos=Vector3.zero,
    lastMyPos=Vector3.zero, lastIsTackling=false,
    lastCalcTime=0,
    INTERVAL=0.008, POS_THRESH=0.15,
}

local function IsCacheDirty(target, data)
    if not target or not data then return true end
    local now = _tick()
    if now - _dc.lastCalcTime > _dc.INTERVAL then return true end
    if _dc.lastPlayer ~= target then return true end
    if _dc.lastIsTackling ~= data.IsTackling then return true end
    if data.RootPart then
        local c = _dc.lastTacklerPos; local r = data.RootPart.Position
        local dx = r.X-c.X; local dz = r.Z-c.Z
        if _msqrt(dx*dx+dz*dz) > _dc.POS_THRESH then return true end
    end
    local m = _dc.lastMyPos; local h = HumanoidRootPart.Position
    local mx = h.X-m.X; local mz = h.Z-m.Z
    if _msqrt(mx*mx+mz*mz) > _dc.POS_THRESH then return true end
    return false
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

    local function DribbleLoop()
        if not AutoDribbleConfig.Enabled then CleanupDebugText(); UpdateDebugVisibility(); return end
        if not HasBall or not CanDribbleNow then
            if Gui then Gui.AutoDribbleLabel.Text = "AutoDribble: Idle" end
            return
        end

        local target, minDist, count, targetData = nil, math.huge, 0, nil
        for player, data in pairs(PrecomputedPlayers) do
            if data.IsValid then
                -- Учитываем только tacklers (IsTackling) для выбора "ближайшего"
                -- но в цикле проверяем всех если RequireTackleAnim=false
                if data.IsTackling or not AutoDribbleConfig.RequireTackleAnim then
                    count += 1
                    if data.Distance < minDist then
                        minDist = data.Distance
                        target  = player
                        targetData = data
                    end
                end
            end
        end

        if Gui then
            Gui.DribbleTargetLabel.Text   = "Targets: " .. count
            Gui.DribbleTacklingLabel.Text = target
                and string.format("Near: %.1f", minDist)
                or "Near: None"
        end

        if not target or not targetData then
            if Gui then Gui.AutoDribbleLabel.Text = "AutoDribble: Idle" end
            return
        end

        local shouldFire
        if IsCacheDirty(target, targetData) then
            shouldFire = ShouldDribbleNow(target, targetData)
            _dc.result       = shouldFire
            _dc.lastCalcTime = _tick()
            _dc.lastPlayer   = target
            _dc.lastIsTackling = targetData.IsTackling
            if targetData.RootPart then
                _dc.lastTacklerPos = targetData.RootPart.Position
            end
            _dc.lastMyPos = HumanoidRootPart.Position
        else
            shouldFire = _dc.result
        end

        if shouldFire then
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
    HideESPBox(Gui and Gui.ServerPosBox)
    HideESPBox(Gui and Gui.PredictionBox)
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
            Options = { "OnlyDribble", "EagleEye", "ManualTackle" },
            Callback = function(v)
                AutoTackleConfig.Mode = v
                if Gui then Gui.ModeLabel.Text = "Mode: " .. v end
            end
        }, "AutoTackleMode")

        UI.Sections.AutoTackle:Divider()

        uiElements.AutoTackleMaxDist = UI.Sections.AutoTackle:Slider({
            Name = "Max Distance", Minimum = 5, Maximum = 50,
            Default = AutoTackleConfig.MaxDistance, Precision = 1,
            Callback = function(v) AutoTackleConfig.MaxDistance = v end
        }, "AutoTackleMaxDist")

        uiElements.AutoTackleInstDist = UI.Sections.AutoTackle:Slider({
            Name = "Instant Tackle Distance", Minimum = 0, Maximum = 20,
            Default = AutoTackleConfig.TackleDistance, Precision = 1,
            Callback = function(v) AutoTackleConfig.TackleDistance = v end
        }, "AutoTackleInstDist")

        uiElements.AutoTackleSpeed = UI.Sections.AutoTackle:Slider({
            Name = "Tackle Speed", Minimum = 10, Maximum = 100,
            Default = AutoTackleConfig.TackleSpeed, Precision = 1,
            Callback = function(v) AutoTackleConfig.TackleSpeed = v end
        }, "AutoTackleSpeed")

        UI.Sections.AutoTackle:Divider()

        uiElements.AutoTackleOnlyPlayer = UI.Sections.AutoTackle:Toggle({
            Name = "Only Player", Default = AutoTackleConfig.OnlyPlayer,
            Callback = function(v) AutoTackleConfig.OnlyPlayer = v end
        }, "AutoTackleOnlyPlayer")

        uiElements.AutoTackleRotation = UI.Sections.AutoTackle:Dropdown({
            Name = "Rotation Method", Default = AutoTackleConfig.RotationMethod,
            Options = { "Snap", "Legit", "Always", "None" },
            Callback = function(v) AutoTackleConfig.RotationMethod = v end
        }, "AutoTackleRotation")

        uiElements.AutoTackleShowPred = UI.Sections.AutoTackle:Toggle({
            Name = "Show Prediction Box", Default = AutoTackleConfig.ShowPredictionBox,
            Callback = function(v)
                AutoTackleConfig.ShowPredictionBox = v
                if not v and Gui then HideESPBox(Gui.PredictionBox) end
                UpdateDebugVisibility()
            end
        }, "AutoTackleShowPred")

        UI.Sections.AutoTackle:Divider()

        uiElements.AutoTackleDribDelay = UI.Sections.AutoTackle:Slider({
            Name = "Dribble Delay", Minimum = -0.2, Maximum = 2.0,
            Default = AutoTackleConfig.DribbleDelayTime, Precision = 2,
            Callback = function(v) AutoTackleConfig.DribbleDelayTime = v end
        }, "AutoTackleDribDelay")

        uiElements.AutoTackleEEMin = UI.Sections.AutoTackle:Slider({
            Name = "EagleEye Min Delay", Minimum = 0, Maximum = 2.0,
            Default = AutoTackleConfig.EagleEyeMinDelay, Precision = 2,
            Callback = function(v) AutoTackleConfig.EagleEyeMinDelay = v end
        }, "AutoTackleEEMin")

        uiElements.AutoTackleEEMax = UI.Sections.AutoTackle:Slider({
            Name = "EagleEye Max Delay", Minimum = 0, Maximum = 2.0,
            Default = AutoTackleConfig.EagleEyeMaxDelay, Precision = 2,
            Callback = function(v) AutoTackleConfig.EagleEyeMaxDelay = v end
        }, "AutoTackleEEMax")

        UI.Sections.AutoTackle:Divider()

        uiElements.AutoTackleManual = UI.Sections.AutoTackle:Toggle({
            Name = "Manual Tackle Enabled", Default = AutoTackleConfig.ManualTackleEnabled,
            Callback = function(v) AutoTackleConfig.ManualTackleEnabled = v end
        }, "AutoTackleManual")

        uiElements.AutoTackleKeybind = UI.Sections.AutoTackle:Keybind({
            Name = "Manual Tackle Key", Default = AutoTackleConfig.ManualTackleKeybind,
            Callback = function(v)
                if not AutoTackleConfig.Enabled or not AutoTackleConfig.ManualTackleEnabled then return end
                ManualTackleAction()
            end,
            onBinded = function(v) AutoTackleConfig.ManualTackleKeybind = v end
        }, "AutoTackleKeybind")
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

        uiElements.AutoDribbleMaxDist = UI.Sections.AutoDribble:Slider({
            Name = "Max Distance", Minimum = 10, Maximum = 50,
            Default = AutoDribbleConfig.MaxDribbleDistance, Precision = 1,
            Callback = function(v) AutoDribbleConfig.MaxDribbleDistance = v end
        }, "AutoDribbleMaxDist")

        uiElements.AutoDribbleActDist = UI.Sections.AutoDribble:Slider({
            Name = "Activation Distance", Minimum = 5, Maximum = 30,
            Default = AutoDribbleConfig.DribbleActivationDistance, Precision = 1,
            Callback = function(v) AutoDribbleConfig.DribbleActivationDistance = v end
        }, "AutoDribbleActDist")

        uiElements.AutoDribbleAngle = UI.Sections.AutoDribble:Slider({
            Name = "Max Attack Angle", Minimum = 10, Maximum = 90,
            Default = AutoDribbleConfig.MinAngleForDribble, Precision = 0,
            Callback = function(v)
                AutoDribbleConfig.MinAngleForDribble = v
                _cachedAngleDeg = -1
            end
        }, "AutoDribbleAngle")

        uiElements.AutoDribblePBRadius = UI.Sections.AutoDribble:Slider({
            Name = "Point Blank Radius", Minimum = 3, Maximum = 15,
            Default = AutoDribbleConfig.PointBlankRadius, Precision = 1,
            Callback = function(v) AutoDribbleConfig.PointBlankRadius = v end
        }, "AutoDribblePBRadius")

        -- RequireTackleAnim toggle (по умолчанию false)
        uiElements.AutoDribbleReqTackle = UI.Sections.AutoDribble:Toggle({
            Name = "Require Tackle Anim", Default = AutoDribbleConfig.RequireTackleAnim,
            Callback = function(v) AutoDribbleConfig.RequireTackleAnim = v end
        }, "AutoDribbleReqTackle")

        uiElements.AutoDribbleServerPos = UI.Sections.AutoDribble:Toggle({
            Name = "Show Server Position Box", Default = AutoDribbleConfig.ShowServerPos,
            Callback = function(v)
                AutoDribbleConfig.ShowServerPos = v
                if not v and Gui then HideESPBox(Gui.ServerPosBox) end
                UpdateDebugVisibility()
            end
        }, "AutoDribbleServerPos")

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

        uiElements.DebugMove = UI.Sections.Debug:Toggle({
            Name = "Move Debug Text", Default = DebugConfig.MoveEnabled,
            Callback = function(v)
                DebugConfig.MoveEnabled = v
                if v then SetupDebugMovement() end
            end
        }, "DebugMove")
    end
end

-- ============================================================
-- MODULE
-- ============================================================
local AutoDribbleTackleModule = {}

function AutoDribbleTackleModule.Init(UI, coreParam, notifyFunc)
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
        AutoTackleStatus.TargetCircles = {}
        MyPositionHistory  = {}
        _cachedAngleDeg    = -1
        _velocitySmooth    = {}
        CurrentTargetOwner = nil
        _dc.lastPlayer     = nil
        _dc.lastCalcTime   = 0
        if AutoTackleConfig.Enabled and not AutoTackleStatus.Running then AutoTackle.Start() end
        if AutoDribbleConfig.Enabled and not AutoDribbleStatus.Running then AutoDribble.Start() end
    end)
end

function AutoDribbleTackleModule:Destroy()
    AutoTackle.Stop()
    AutoDribble.Stop()
    if Gui then
        RemoveESPBox(Gui.ServerPosBox)
        RemoveESPBox(Gui.PredictionBox)
    end
end

return AutoDribbleTackleModule
