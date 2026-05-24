-- [v4.0] AUTO DRIBBLE + AUTO TACKLE
-- Changelog v4.0:
-- [FIX] Box: ширина теперь берётся по размеру HRP (не всего тела с руками).
--       W = HRP.Size.X * 1.3, H = GetBoundingBox().Y (реальная высота тела),
--       D = HRP.Size.Z * 1.3 — корректные пропорции без рук
-- [FIX] Strict режим: упрощён до одной проверки —
--       "пересечёт ли предсказанная позиция врага радиус вокруг моей serverPos"
--       Радиус = HitRadius (настраивается, ~3.5 studs). Никакой тригонометрии.
--       Быстрее, точнее, без ложных срабатываний.
-- [NEW] RequireTackleAnim toggle (по умолч. false) — если true, AutoDribble
--       срабатывает только при IsTackling у врага (старый Free режим).
--       Если false — реагирует на любого движущегося врага в зоне.
-- [FIX] DribbleDelayTime: min = -0.2 (отрицательное = упреждение до конца дриббла)
-- [KEEP] Kickoff/Penalty блокировка такла
-- [KEEP] PredictionBox всегда при наличии цели
-- [KEEP] GetBoundingBox() кэшируется 1 раз при обнаружении игрока

-- ============================================================
-- ЛОКАЛИЗАЦИЯ
-- ============================================================
local _mabs   = math.abs
local _mcos   = math.cos
local _mrad   = math.rad
local _mmax   = math.max
local _mmin   = math.min
local _mclamp = math.clamp
local _msqrt  = math.sqrt
local _mfloor = math.floor
local _msin   = math.sin
local _acos   = math.acos
local _mdeg   = math.deg
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
    MinAngleForDribble        = 32,   -- используется только в Free режиме
    ShowServerPos             = false,
    DribbleMode               = "Free",   -- "Free" | "Strict"
    RequireTackleAnim         = false,    -- v4.0: true = только при IsTackling
    -- Strict: радиус пересечения с serverPos игрока
    StrictHitRadius           = 3.5,     -- studs, подбирается под размер HRP
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

-- v4.0: кэш размеров тел
-- W/H/D = финальные размеры бокса, OffsetY = смещение центра от HRP
local PlayerSizeCache = {}

local SPECIFIC_TACKLE_ID = "rbxassetid://14317040670"

-- ============================================================
-- v4.0: РАЗМЕР БОКСА
-- H = реальная высота тела из GetBoundingBox()
-- W = HRP.Size.X * 1.3  (без рук — только торс+ноги)
-- D = HRP.Size.Z * 1.3
-- OffsetY = центр bounding box Y - HRP Y
-- ============================================================
local function CachePlayerSize(player)
    if PlayerSizeCache[player] then return PlayerSizeCache[player] end
    local char = player.Character
    if not char then return nil end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hrp then return nil end

    local ok, bbCF, bbSz = pcall(function() return char:GetBoundingBox() end)

    local h, offsetY
    if ok and bbSz then
        h       = bbSz.Y
        offsetY = bbCF.Position.Y - hrp.Position.Y
    else
        -- fallback R15
        h       = 5.5
        offsetY = 0.4
    end

    -- Ширина и глубина — только HRP, не весь bounding box (убирает руки)
    local hrpSz = hrp.Size
    local w = hrpSz.X * 1.3
    local d = hrpSz.Z * 1.3

    PlayerSizeCache[player] = { W=w, H=h, D=d, OffsetY=offsetY }
    return PlayerSizeCache[player]
end

-- ============================================================
-- ИСТОРИЯ ПОЗИЦИЙ
-- ============================================================
local HISTORY_SIZE   = 12
local HISTORY_WINDOW = 0.12

local function RecordTargetPosition(ownerRoot, player)
    local h = AutoTackleStatus.TargetPositionHistory[player]
    if not h then h = {}; AutoTackleStatus.TargetPositionHistory[player] = h end
    local p = ownerRoot.Position
    _tins(h, { time = _tick(), x=p.X, y=p.Y, z=p.Z })
    while #h > HISTORY_SIZE do _trem(h, 1) end
end

local function GetPositionBasedVelocity(player)
    local h = AutoTackleStatus.TargetPositionHistory[player]
    if not h or #h < 2 then return 0, 0, 0 end
    local now = _tick()
    local ox, oy, oz, ot = nil, nil, nil, nil
    local nx, ny, nz, nt = nil, nil, nil, nil
    for _, pt in ipairs(h) do
        if now - pt.time <= HISTORY_WINDOW then
            if not ox then ox,oy,oz,ot = pt.x,pt.y,pt.z,pt.time end
            nx,ny,nz,nt = pt.x,pt.y,pt.z,pt.time
        end
    end
    if not ox or (ox==nx and oz==nz) then
        if #h >= 2 then
            local a=h[#h-1]; local b=h[#h]
            ox,oy,oz,ot = a.x,a.y,a.z,a.time
            nx,ny,nz,nt = b.x,b.y,b.z,b.time
        else return 0,0,0 end
    end
    local dt = nt - ot
    if dt < 0.001 then return 0,0,0 end
    local inv = 1/dt
    return (nx-ox)*inv, (ny-oy)*inv, (nz-oz)*inv
end

local function CalcInterceptTime(fx, fz, tx, tz, vx, vz, speed)
    local dx=tx-fx; local dz=tz-fz
    local d2=dx*dx+dz*dz
    if d2 < 0.0001 then return 0 end
    local dist=_msqrt(d2)
    local v2=vx*vx+vz*vz; local s2=speed*speed
    local dotDV=dx*vx+dz*vz
    local a=s2-v2; local b=-2*dotDV; local c=-d2
    local t
    if _mabs(a) < 0.001 then
        t = (_mabs(b)>0.001) and (-c/b) or (dist/_mmax(speed,1))
    else
        local disc=b*b-4*a*c
        if disc < 0 then
            t = dist/_mmax(speed,1)
        else
            local sq=_msqrt(disc)
            local t1=(-b-sq)/(2*a); local t2=(-b+sq)/(2*a)
            if t1>0 and t2>0 then t=_mmin(t1,t2)
            elseif t1>0 then t=t1
            elseif t2>0 then t=t2
            else t=dist/_mmax(speed,1) end
        end
    end
    return _mclamp(t, 0.02, 0.5)
end

local function PredictTargetPosition(ownerRoot, player)
    if not ownerRoot then return ownerRoot.Position end
    local ping = AutoTackleStatus.Ping
    local vx,vy,vz = GetPositionBasedVelocity(player)
    local op = ownerRoot.Position
    local sx = op.X + vx*ping; local sz = op.Z + vz*ping
    local mp = HumanoidRootPart.Position
    local it = CalcInterceptTime(mp.X,mp.Z,sx,sz,vx,vz,AutoTackleConfig.TackleSpeed)
    return _V3new(sx+vx*it, op.Y, sz+vz*it)
end

local function UpdatePredictionLabel(ownerRoot, player)
    if not Gui or not DebugConfig.Enabled then return end
    if not ownerRoot or not player then Gui.PredictionLabel.Text="Pred: no target"; return end
    local ping=AutoTackleStatus.Ping
    local vx,_,vz=GetPositionBasedVelocity(player)
    local op=ownerRoot.Position
    local sx=op.X+vx*ping; local sz=op.Z+vz*ping
    local mp=HumanoidRootPart.Position
    local dx=sx-mp.X; local dz=sz-mp.Z
    local dist=_msqrt(dx*dx+dz*dz)
    local it=CalcInterceptTime(mp.X,mp.Z,sx,sz,vx,vz,AutoTackleConfig.TackleSpeed)
    Gui.PredictionLabel.Text=string.format("p=%dms t=%dms v=%.0f d=%.0f",
        _mfloor(ping*1000+0.5),_mfloor(it*1000+0.5),_msqrt(vx*vx+vz*vz),dist)
end

-- ============================================================
-- ПИНГ UPDATE
-- ============================================================
local function UpdatePing()
    local now=_tick()
    if now-AutoTackleStatus.LastPingUpdate > 1 then
        AutoTackleStatus.Ping=GetPing()
        AutoTackleStatus.LastPingUpdate=now
        if Gui and AutoTackleConfig.Enabled then
            Gui.PingLabel.Text=string.format("Ping: %dms",_mfloor(AutoTackleStatus.Ping*1000+0.5))
        end
    end
end

-- ============================================================
-- МОЯ СЕРВЕРНАЯ ПОЗИЦИЯ
-- ============================================================
local MY_HISTORY_SIZE=10
local MyPositionHistory={}

local function RecordMyPosition()
    local p=HumanoidRootPart.Position
    _tins(MyPositionHistory,{time=_tick(),x=p.X,y=p.Y,z=p.Z})
    while #MyPositionHistory>MY_HISTORY_SIZE do _trem(MyPositionHistory,1) end
end

local function GetMyVelocityFromHistory()
    if #MyPositionHistory<2 then return 0,0,0 end
    local a=MyPositionHistory[1]; local b=MyPositionHistory[#MyPositionHistory]
    local dt=b.time-a.time
    if dt<0.001 then return 0,0,0 end
    local inv=1/dt
    return (b.x-a.x)*inv,(b.y-a.y)*inv,(b.z-a.z)*inv
end

local function GetMyServerCFrame()
    local nd=AutoTackleStatus.Ping*1.5
    local mvx,_,mvz=GetMyVelocityFromHistory()
    local p=HumanoidRootPart.Position
    local sp=_V3new(p.X-mvx*nd, p.Y, p.Z-mvz*nd)
    return CFrame.new(sp)*(HumanoidRootPart.CFrame-HumanoidRootPart.CFrame.Position)
end

-- ============================================================
-- 3D BOX
-- ============================================================
local BOX_EDGES={{1,2},{2,3},{3,4},{4,1},{5,6},{6,7},{7,8},{8,5},{1,5},{2,6},{3,7},{4,8}}

local function CreateBoxLines(color,thickness)
    local lines={}
    for i=1,12 do
        local l=Drawing.new("Line")
        l.Color=color or Color3.fromRGB(0,200,255)
        l.Thickness=thickness or 1.5
        l.Visible=false
        _tins(lines,l)
    end
    return lines
end

local function GetBoxCorners(cf,w,h,d,oY)
    local hW=w*.5; local hH=h*.5; local hD=d*.5; local o=oY or 0
    return {
        cf:PointToWorldSpace(_V3new(-hW,-hH+o,-hD)),
        cf:PointToWorldSpace(_V3new( hW,-hH+o,-hD)),
        cf:PointToWorldSpace(_V3new( hW,-hH+o, hD)),
        cf:PointToWorldSpace(_V3new(-hW,-hH+o, hD)),
        cf:PointToWorldSpace(_V3new(-hW, hH+o,-hD)),
        cf:PointToWorldSpace(_V3new( hW, hH+o,-hD)),
        cf:PointToWorldSpace(_V3new( hW, hH+o, hD)),
        cf:PointToWorldSpace(_V3new(-hW, hH+o, hD)),
    }
end

local function UpdateBoxLines(lines,cf,w,h,d,oY,color)
    if not lines then return end
    local corners=GetBoxCorners(cf,w,h,d,oY)
    for i,edge in ipairs(BOX_EDGES) do
        local ln=lines[i]; if not ln then continue end
        local sa,aOn=Camera:WorldToViewportPoint(corners[edge[1]])
        local sb,bOn=Camera:WorldToViewportPoint(corners[edge[2]])
        if aOn and bOn and sa.Z>0.1 and sb.Z>0.1 then
            ln.From=Vector2.new(sa.X,sa.Y); ln.To=Vector2.new(sb.X,sb.Y)
            ln.Color=color or ln.Color; ln.Visible=true
        else ln.Visible=false end
    end
end

local function HideBoxLines(lines)
    if not lines then return end
    for _,l in ipairs(lines) do l.Visible=false end
end

local function RemoveBoxLines(lines)
    if not lines then return end
    for _,l in ipairs(lines) do pcall(function() l:Remove() end) end
end

-- ============================================================
-- GUI
-- ============================================================
local Gui=nil

local function SetupGUI()
    Gui={
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
        KickoffLabel         = Drawing.new("Text"),
        TargetRingLines      = {},
        ServerPosBoxLines    = nil,
        PredictionBoxLines   = nil,
        TackleDebugLabels    = {},
        DribbleDebugLabels   = {},
    }
    Gui.ServerPosBoxLines  = CreateBoxLines(Color3.fromRGB(0,200,255),1.5)
    Gui.PredictionBoxLines = CreateBoxLines(Color3.fromRGB(255,165,0),1.5)

    local sv=Camera.ViewportSize
    local cx=sv.X/2; local ty=sv.Y*0.6
    local oy=ty+30;  local dy=ty-50

    local tackleL={
        Gui.TackleWaitLabel, Gui.TackleTargetLabel, Gui.TackleDribblingLabel,
        Gui.TackleTacklingLabel, Gui.EagleEyeLabel, Gui.CooldownListLabel,
        Gui.ModeLabel, Gui.ManualTackleLabel, Gui.PingLabel, Gui.AngleLabel,
        Gui.PredictionLabel, Gui.ServerPosLabel, Gui.KickoffLabel
    }
    for _,lb in ipairs(tackleL) do
        lb.Size=16; lb.Color=Color3.fromRGB(255,255,255)
        lb.Outline=true; lb.Center=true; lb.Visible=false
        _tins(Gui.TackleDebugLabels,lb)
    end
    Gui.TackleWaitLabel.Color=Color3.fromRGB(255,165,0)
    Gui.ServerPosLabel.Color =Color3.fromRGB(0,200,255)
    Gui.KickoffLabel.Color   =Color3.fromRGB(255,80,80)

    local function sy(lb,y) lb.Position=Vector2.new(cx,y) end
    sy(Gui.TackleWaitLabel,      oy); oy+=15
    sy(Gui.TackleTargetLabel,    oy); oy+=15
    sy(Gui.TackleDribblingLabel, oy); oy+=15
    sy(Gui.TackleTacklingLabel,  oy); oy+=15
    sy(Gui.EagleEyeLabel,        oy); oy+=15
    sy(Gui.CooldownListLabel,    oy); oy+=15
    sy(Gui.ModeLabel,            oy); oy+=15
    sy(Gui.ManualTackleLabel,    oy); oy+=15
    sy(Gui.PingLabel,            oy); oy+=15
    sy(Gui.AngleLabel,           oy); oy+=15
    sy(Gui.PredictionLabel,      oy); oy+=15
    sy(Gui.ServerPosLabel,       oy); oy+=15
    sy(Gui.KickoffLabel,         oy)

    local dribbleL={
        Gui.DribbleStatusLabel, Gui.DribbleTargetLabel,
        Gui.DribbleTacklingLabel, Gui.AutoDribbleLabel
    }
    for _,lb in ipairs(dribbleL) do
        lb.Size=16; lb.Color=Color3.fromRGB(255,255,255)
        lb.Outline=true; lb.Center=true; lb.Visible=false
        _tins(Gui.DribbleDebugLabels,lb)
    end
    sy(Gui.DribbleStatusLabel,   dy); dy+=15
    sy(Gui.DribbleTargetLabel,   dy); dy+=15
    sy(Gui.DribbleTacklingLabel, dy); dy+=15
    sy(Gui.AutoDribbleLabel,     dy)

    Gui.TackleWaitLabel.Text      ="Wait: 0.00"
    Gui.TackleTargetLabel.Text    ="Target: None"
    Gui.TackleDribblingLabel.Text ="isDribbling: false"
    Gui.TackleTacklingLabel.Text  ="isTackling: false"
    Gui.EagleEyeLabel.Text        ="EagleEye: Idle"
    Gui.CooldownListLabel.Text    ="CooldownList: 0"
    Gui.ModeLabel.Text            ="Mode: "..AutoTackleConfig.Mode
    Gui.ManualTackleLabel.Text    ="ManualTackle: Ready"
    Gui.PingLabel.Text            ="Ping: 0ms"
    Gui.AngleLabel.Text           ="Angle: -"
    Gui.PredictionLabel.Text      ="Pred: 0ms"
    Gui.ServerPosLabel.Text       ="ServerPos: -"
    Gui.KickoffLabel.Text         ="Kickoff/Penalty: -"
    Gui.DribbleStatusLabel.Text   ="Dribble: Ready"
    Gui.DribbleTargetLabel.Text   ="Targets: 0"
    Gui.DribbleTacklingLabel.Text ="Nearest: None"
    Gui.AutoDribbleLabel.Text     ="AutoDribble: Idle"

    for i=1,24 do
        local ln=Drawing.new("Line")
        ln.Thickness=3; ln.Color=Color3.fromRGB(255,0,0); ln.Visible=false
        _tins(Gui.TargetRingLines,ln)
    end
end

local function UpdateServerPosBox()
    if not Gui or not Gui.ServerPosBoxLines then return end
    if not AutoDribbleConfig.Enabled or not AutoDribbleConfig.ShowServerPos then
        HideBoxLines(Gui.ServerPosBoxLines)
        if Gui.ServerPosLabel then Gui.ServerPosLabel.Text="ServerPos: -" end
        return
    end
    local serverCF=GetMyServerCFrame()
    local ok,bbCF,bbSz=pcall(function() return Character:GetBoundingBox() end)
    local bW,bH,bD,bOff=3.6,5.5,3.6,0.4
    if ok and bbSz then
        local hrpSz=HumanoidRootPart.Size
        bW=hrpSz.X*1.3; bH=bbSz.Y; bD=hrpSz.Z*1.3
        bOff=bbCF.Position.Y-HumanoidRootPart.Position.Y
    end
    UpdateBoxLines(Gui.ServerPosBoxLines,serverCF,bW,bH,bD,bOff,Color3.fromRGB(0,200,255))
    if Gui.ServerPosLabel and DebugConfig.Enabled then
        local nd=_mfloor(AutoTackleStatus.Ping*1.5*1000+0.5)
        local dp=serverCF.Position-HumanoidRootPart.Position
        local dist=_msqrt(dp.X*dp.X+dp.Y*dp.Y+dp.Z*dp.Z)
        Gui.ServerPosLabel.Text=string.format("ServerPos: %dms | %.1f st",nd,dist)
    end
end

local function UpdatePredictionBox(ownerRoot,player)
    if not Gui or not Gui.PredictionBoxLines then return end
    if not AutoTackleConfig.Enabled or not AutoTackleConfig.ShowPredictionBox then
        HideBoxLines(Gui.PredictionBoxLines); return
    end
    if not ownerRoot or not player then
        HideBoxLines(Gui.PredictionBoxLines); return
    end
    local predictedPos=PredictTargetPosition(ownerRoot,player)
    local predictedCF =CFrame.new(predictedPos)
    local sz=PlayerSizeCache[player]
    if not sz then sz=CachePlayerSize(player) end
    if not sz then HideBoxLines(Gui.PredictionBoxLines); return end
    UpdateBoxLines(Gui.PredictionBoxLines,predictedCF,sz.W,sz.H,sz.D,sz.OffsetY,Color3.fromRGB(255,165,0))
end

local function UpdateDebugVisibility()
    if not Gui then return end
    local tv=DebugConfig.Enabled and AutoTackleConfig.Enabled
    for _,lb in ipairs(Gui.TackleDebugLabels) do lb.Visible=tv end
    local dv=DebugConfig.Enabled and AutoDribbleConfig.Enabled
    for _,lb in ipairs(Gui.DribbleDebugLabels) do lb.Visible=dv end
    if not AutoTackleConfig.Enabled then
        for _,ln in ipairs(Gui.TargetRingLines) do ln.Visible=false end
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
        Gui.TackleWaitLabel.Text     ="Wait: 0.00"
        Gui.TackleTargetLabel.Text   ="Target: None"
        Gui.TackleDribblingLabel.Text="isDribbling: false"
        Gui.TackleTacklingLabel.Text ="isTackling: false"
        Gui.EagleEyeLabel.Text       ="EagleEye: Idle"
        Gui.ManualTackleLabel.Text   ="ManualTackle: Ready"
        Gui.ModeLabel.Text           ="Mode: "..AutoTackleConfig.Mode
        Gui.PingLabel.Text           ="Ping: 0ms"
        Gui.PredictionLabel.Text     ="Pred: 0ms"
        Gui.KickoffLabel.Text        ="Kickoff/Penalty: -"
    end
    if not AutoDribbleConfig.Enabled then
        Gui.DribbleStatusLabel.Text  ="Dribble: Ready"
        Gui.DribbleTargetLabel.Text  ="Targets: 0"
        Gui.DribbleTacklingLabel.Text="Nearest: None"
        Gui.AutoDribbleLabel.Text    ="AutoDribble: Idle"
        if Gui.ServerPosBoxLines then HideBoxLines(Gui.ServerPosBoxLines) end
    end
end

-- ============================================================
-- 3D КРУГИ
-- ============================================================
local _2pi=math.pi*2
local function Create3DCircle()
    local c={}
    for i=1,24 do
        local ln=Drawing.new("Line")
        ln.Thickness=3; ln.Color=Color3.fromRGB(255,0,0); ln.Visible=false
        _tins(c,ln)
    end
    return c
end

local function Update3DCircle(circle,pos,radius,color)
    if not circle then return end
    local seg=#circle; local px,pz,py=pos.X,pos.Z,pos.Y
    local step=_2pi/seg; local pts={}
    for i=1,seg do
        local a=(i-1)*step
        _tins(pts,_V3new(px+_mcos(a)*radius,py,pz+_msin(a)*radius))
    end
    for i,ln in ipairs(circle) do
        local sp=pts[i]; local ep=pts[i%seg+1]
        local ss,sO=Camera:WorldToViewportPoint(sp)
        local es,eO=Camera:WorldToViewportPoint(ep)
        if sO and eO and ss.Z>0.1 and es.Z>0.1 then
            ln.From=Vector2.new(ss.X,ss.Y); ln.To=Vector2.new(es.X,es.Y)
            ln.Color=color; ln.Visible=true
        else ln.Visible=false end
    end
end

local function Hide3DCircle(c)
    if not c then return end
    for _,ln in ipairs(c) do ln.Visible=false end
end

local function UpdateTargetCircles()
    local cur={}
    for player,data in pairs(PrecomputedPlayers) do
        if data.IsValid and TackleStates[player] and TackleStates[player].IsTackling then
            cur[player]=true
            if not AutoTackleStatus.TargetCircles[player] then
                AutoTackleStatus.TargetCircles[player]=Create3DCircle()
            end
            local tr=data.RootPart
            if tr then
                local col=data.Distance<=AutoDribbleConfig.DribbleActivationDistance
                    and Color3.fromRGB(0,255,0) or Color3.fromRGB(255,165,0)
                Update3DCircle(AutoTackleStatus.TargetCircles[player],
                    tr.Position-_V3new(0,.5,0),2,col)
            end
        end
    end
    for p,c in pairs(AutoTackleStatus.TargetCircles) do
        if not cur[p] then Hide3DCircle(c) end
    end
end

-- ============================================================
-- DEBUG MOVE
-- ============================================================
local function SetupDebugMovement()
    if not DebugConfig.MoveEnabled or not Gui then return end
    local isDragging=false; local dragStart=Vector2.new(0,0); local startPos={}
    for _,lb in ipairs(Gui.TackleDebugLabels) do startPos[lb]=lb.Position end
    for _,lb in ipairs(Gui.DribbleDebugLabels) do startPos[lb]=lb.Position end
    UserInputService.InputBegan:Connect(function(inp,gp)
        if gp then return end
        if inp.UserInputType==Enum.UserInputType.MouseButton1 then
            local mp=UserInputService:GetMouseLocation()
            for lb in pairs(startPos) do
                if lb.Visible then
                    local p=lb.Position; local tb=lb.TextBounds
                    if mp.X>=p.X-tb.X*.5 and mp.X<=p.X+tb.X*.5 and
                       mp.Y>=p.Y-tb.Y*.5 and mp.Y<=p.Y+tb.Y*.5 then
                        isDragging=true; dragStart=mp; break
                    end
                end
            end
        end
    end)
    UserInputService.InputChanged:Connect(function(inp,gp)
        if gp or not isDragging then return end
        if inp.UserInputType==Enum.UserInputType.MouseMovement then
            local delta=UserInputService:GetMouseLocation()-dragStart
            for lb,sp in pairs(startPos) do if lb.Visible then lb.Position=sp+delta end end
        end
    end)
    UserInputService.InputEnded:Connect(function(inp,gp)
        if gp then return end
        if inp.UserInputType==Enum.UserInputType.MouseButton1 and isDragging then
            local delta=UserInputService:GetMouseLocation()-dragStart
            for lb,sp in pairs(startPos) do startPos[lb]=sp+delta end
            isDragging=false
        end
    end)
end

-- ============================================================
-- STATE CHECKS
-- ============================================================
local function CheckIfTypingInChat()
    local ok,r=pcall(function()
        local pg=LocalPlayer:WaitForChild("PlayerGui")
        for _,g in pairs(pg:GetChildren()) do
            if g:IsA("ScreenGui") and g.Name:find("Chat") then
                local tb=g:FindFirstChild("TextBox",true)
                if tb then return tb:IsFocused() end
            end
        end
        return false
    end)
    return ok and r or false
end

local function IsDribbling(p)
    if not p or not p.Character or not p.Parent or p.TeamColor==LocalPlayer.TeamColor then return false end
    local hum=p.Character:FindFirstChild("Humanoid"); if not hum then return false end
    local anim=hum:FindFirstChild("Animator"); if not anim then return false end
    for _,tr in pairs(anim:GetPlayingAnimationTracks()) do
        if tr.Animation and table.find(DribbleAnimIds,tr.Animation.AnimationId) then return true end
    end
    return false
end

local function IsSpecificTackle(p)
    if not p or not p.Character or not p.Parent or p.TeamColor==LocalPlayer.TeamColor then return false end
    local hum=p.Character:FindFirstChild("Humanoid"); if not hum then return false end
    local anim=hum:FindFirstChild("Animator"); if not anim then return false end
    for _,tr in pairs(anim:GetPlayingAnimationTracks()) do
        if tr.Animation and tr.Animation.AnimationId==SPECIFIC_TACKLE_ID then return true end
    end
    return false
end

local function IsPowerShooting(p)
    if not p then return false end
    local pf=Workspace:FindFirstChild(p.Name); if not pf then return false end
    local bools=pf:FindFirstChild("Bools"); if not bools then return false end
    local ps=bools:FindFirstChild("PowerShooting")
    return ps and ps.Value==true
end

-- ============================================================
-- DRIBBLE STATES
-- ============================================================
local function UpdateDribbleStates()
    local now=_tick()
    for _,p in pairs(Players:GetPlayers()) do
        if p==LocalPlayer or not p.Parent or p.TeamColor==LocalPlayer.TeamColor then continue end
        if not DribbleStates[p] then
            DribbleStates[p]={IsDribbling=false,LastDribbleEnd=0,IsProcessingDelay=false,HadDribble=false}
        end
        local st=DribbleStates[p]
        local isDribNow=IsDribbling(p)
        if isDribNow and not st.IsDribbling then
            st.IsDribbling=true; st.IsProcessingDelay=false; st.HadDribble=true
        elseif not isDribNow and st.IsDribbling then
            st.IsDribbling=false; st.LastDribbleEnd=now; st.IsProcessingDelay=true
        elseif st.IsProcessingDelay and not isDribNow then
            local effDelay=_mmax(AutoTackleConfig.DribbleDelayTime,0)
            if now-st.LastDribbleEnd>=effDelay then
                DribbleCooldownList[p]=now+3.5; st.IsProcessingDelay=false
            end
        end
    end
    -- Отрицательный delay: заносим в cooldown пока ещё дриблит (упреждение)
    if AutoTackleConfig.DribbleDelayTime < 0 then
        for p,st in pairs(DribbleStates) do
            if st.IsDribbling and not DribbleCooldownList[p] then
                DribbleCooldownList[p]=now+3.5
            end
        end
    end
    local toRem={}
    for p,et in pairs(DribbleCooldownList) do
        if not p or not p.Parent or now>=et then _tins(toRem,p) end
    end
    for _,p in ipairs(toRem) do DribbleCooldownList[p]=nil; EagleEyeTimers[p]=nil end
    if Gui and AutoTackleConfig.Enabled then
        local cnt=0; for _ in pairs(DribbleCooldownList) do cnt+=1 end
        Gui.CooldownListLabel.Text="CooldownList: "..cnt
    end
end

-- ============================================================
-- PRECOMPUTE PLAYERS
-- ============================================================
local function PrecomputePlayers()
    PrecomputedPlayers={}
    HasBall=false; CanDribbleNow=false
    local ball=Workspace:FindFirstChild("ball")
    if ball and ball:FindFirstChild("playerWeld") and ball:FindFirstChild("creator") then
        HasBall=ball.creator.Value==LocalPlayer
    end
    local myBoolsFolder=Workspace:FindFirstChild(LocalPlayer.Name)
    local myBools=myBoolsFolder and myBoolsFolder:FindFirstChild("Bools")
    if myBools then
        CanDribbleNow=not myBools.dribbleDebounce.Value
        if Gui and AutoDribbleConfig.Enabled then
            Gui.DribbleStatusLabel.Text =myBools.dribbleDebounce.Value and "Dribble: Cooldown" or "Dribble: Ready"
            Gui.DribbleStatusLabel.Color=myBools.dribbleDebounce.Value
                and Color3.fromRGB(255,0,0) or Color3.fromRGB(0,255,0)
        end
    end
    local mp=HumanoidRootPart.Position
    local mpx,mpy,mpz=mp.X,mp.Y,mp.Z
    local maxD=AutoDribbleConfig.MaxDribbleDistance
    local maxD2=maxD*maxD
    for _,p in pairs(Players:GetPlayers()) do
        if p==LocalPlayer or not p.Parent or p.TeamColor==LocalPlayer.TeamColor then continue end
        local char=p.Character; if not char then continue end
        local hum=char:FindFirstChild("Humanoid")
        if not hum or hum.HipHeight>=4 then continue end
        local root=char:FindFirstChild("HumanoidRootPart"); if not root then continue end
        if not PlayerSizeCache[p] then CachePlayerSize(p) end
        TackleStates[p]=TackleStates[p] or {IsTackling=false}
        TackleStates[p].IsTackling=IsSpecificTackle(p)
        local tp=root.Position
        local dx=tp.X-mpx; local dy=tp.Y-mpy; local dz=tp.Z-mpz
        local d2=dx*dx+dy*dy+dz*dz
        if d2>maxD2 then continue end
        local dist=_msqrt(d2)
        local alv=root.AssemblyLinearVelocity
        local pvx,pvy,pvz=GetPositionBasedVelocity(p)
        local alvM2=alv.X*alv.X+alv.Y*alv.Y+alv.Z*alv.Z
        local pvM2=pvx*pvx+pvy*pvy+pvz*pvz
        local vx,vy,vz
        if alvM2>=pvM2 then vx,vy,vz=alv.X,alv.Y,alv.Z
        else vx,vy,vz=pvx,pvy,pvz end
        PrecomputedPlayers[p]={
            Distance=dist, IsValid=true, IsTackling=TackleStates[p].IsTackling,
            RootPart=root, VX=vx, VY=vy, VZ=vz,
        }
        if d2<=(AutoDribbleConfig.DribbleActivationDistance*1.5)^2 then
            RecordTargetPosition(root,p)
        end
    end
end

-- ============================================================
-- ROTATION
-- ============================================================
local function RotateToTarget(targetPos)
    if AutoTackleConfig.RotationMethod=="None" then return end
    local mp=HumanoidRootPart.Position
    local dx=targetPos.X-mp.X; local dz=targetPos.Z-mp.Z
    if _msqrt(dx*dx+dz*dz)>0.1 then
        HumanoidRootPart.CFrame=CFrame.new(mp,mp+_V3new(dx,0,dz))
    end
end

-- ============================================================
-- CanTackle — v4.0: Kickoff + Penalty
-- ============================================================
local function CanTackle()
    local wsBools=Workspace:FindFirstChild("Bools")
    if wsBools then
        local ko=wsBools:FindFirstChild("Kickoff")
        local pen=wsBools:FindFirstChild("Penalty")
        local koOn=ko and ko:IsA("BoolValue") and ko.Value
        local penOn=pen and pen:IsA("BoolValue") and pen.Value
        if koOn or penOn then
            if Gui then
                local s=(koOn and penOn) and "Kickoff+Penalty" or (koOn and "Kickoff") or "Penalty"
                Gui.KickoffLabel.Text="BLOCKED: "..s
                Gui.KickoffLabel.Color=Color3.fromRGB(255,80,80)
            end
            return false,nil,nil,nil
        end
    end
    if Gui then Gui.KickoffLabel.Text="Kickoff/Penalty: OK"; Gui.KickoffLabel.Color=Color3.fromRGB(0,255,0) end

    local ball=Workspace:FindFirstChild("ball")
    if not ball or not ball.Parent then return false,nil,nil,nil end
    local hasOwner=ball:FindFirstChild("playerWeld") and ball:FindFirstChild("creator")
    local owner=hasOwner and ball.creator.Value or nil
    if AutoTackleConfig.OnlyPlayer and (not hasOwner or not owner or not owner.Parent) then return false,nil,nil,nil end
    local isEnemy=not owner or (owner and owner.TeamColor~=LocalPlayer.TeamColor)
    if not isEnemy then return false,nil,nil,nil end
    if wsBools and (wsBools.APG.Value==LocalPlayer or wsBools.HPG.Value==LocalPlayer) then return false,nil,nil,nil end
    local bv=HumanoidRootPart.Position-ball.Position
    local dist=_msqrt(bv.X*bv.X+bv.Y*bv.Y+bv.Z*bv.Z)
    if dist>AutoTackleConfig.MaxDistance then return false,nil,nil,nil end
    if owner and owner.Character then
        local th=owner.Character:FindFirstChild("Humanoid")
        if th and th.HipHeight>=4 then return false,nil,nil,nil end
    end
    local myBF=Workspace:FindFirstChild(LocalPlayer.Name)
    local myBools=myBF and myBF:FindFirstChild("Bools")
    if myBools and (myBools.TackleDebounce.Value or myBools.Tackled.Value or
       (Character:FindFirstChild("Bools") and Character.Bools.Debounce.Value)) then
        return false,nil,nil,nil
    end
    return true,ball,dist,owner
end

-- ============================================================
-- PERFORM TACKLE
-- ============================================================
local function PerformTackle(ball,owner)
    local myBF=Workspace:FindFirstChild(LocalPlayer.Name)
    local myBools=myBF and myBF:FindFirstChild("Bools")
    if not myBools or myBools.TackleDebounce.Value or myBools.Tackled.Value or
       (Character:FindFirstChild("Bools") and Character.Bools.Debounce.Value) then return end
    local ownerRoot=owner and owner.Character and owner.Character:FindFirstChild("HumanoidRootPart")
    local predictedPos
    if ownerRoot and owner then predictedPos=PredictTargetPosition(ownerRoot,owner)
    else predictedPos=ball.Position end
    RotateToTarget(predictedPos)
    if ownerRoot then
        local fv=HumanoidRootPart.Position-ownerRoot.Position
        local fd=_msqrt(fv.X*fv.X+fv.Y*fv.Y+fv.Z*fv.Z)
        if fd<=10 then
            pcall(function() firetouchinterest(HumanoidRootPart,ownerRoot,0) end)
            pcall(function() firetouchinterest(HumanoidRootPart,ownerRoot,1) end)
        end
    end
    pcall(function() ActionRemote:FireServer("TackIe") end)
    local bv=Instance.new("BodyVelocity")
    bv.Parent=HumanoidRootPart
    bv.Velocity=HumanoidRootPart.CFrame.LookVector*AutoTackleConfig.TackleSpeed
    bv.MaxForce=_V3new(50000000,0,50000000)
    local startT=_tick(); local dur=0.65; local rotConn
    local method=AutoTackleConfig.RotationMethod
    if method=="Always" and ownerRoot and owner then
        rotConn=RunService.Heartbeat:Connect(function()
            if _tick()-startT<dur then RotateToTarget(PredictTargetPosition(ownerRoot,owner))
            else rotConn:Disconnect() end
        end)
    elseif method=="Legit" and ownerRoot and owner then
        local lockedCF=HumanoidRootPart.CFrame
        rotConn=RunService.Heartbeat:Connect(function()
            if _tick()-startT<dur then
                HumanoidRootPart.CFrame=CFrame.new(HumanoidRootPart.Position)*(lockedCF-lockedCF.Position)
            else rotConn:Disconnect() end
        end)
    end
    Debris:AddItem(bv,dur)
    task.delay(dur,function() if rotConn then rotConn:Disconnect() end end)
    if owner and ball:FindFirstChild("playerWeld") then
        local bvec=HumanoidRootPart.Position-ball.Position
        local bd=_msqrt(bvec.X*bvec.X+bvec.Y*bvec.Y+bvec.Z*bvec.Z)
        pcall(function() SoftDisPlayerRemote:FireServer(owner,bd,false,ball.Size) end)
    end
end

-- ============================================================
-- MANUAL TACKLE
-- ============================================================
local function ManualTackleAction()
    local now=_tick()
    if now-LastManualTackleTime<AutoTackleConfig.ManualTackleCooldown then return false end
    local ok,ball,dist,owner=CanTackle()
    if ok then
        LastManualTackleTime=now; PerformTackle(ball,owner)
        if Gui then
            Gui.ManualTackleLabel.Text="ManualTackle: EXECUTED!"
            Gui.ManualTackleLabel.Color=Color3.fromRGB(0,255,0)
        end
        task.delay(0.3,function()
            if Gui then Gui.ManualTackleLabel.Color=Color3.fromRGB(255,255,255) end
        end)
        return true
    else
        if Gui then
            Gui.ManualTackleLabel.Text="ManualTackle: FAILED"
            Gui.ManualTackleLabel.Color=Color3.fromRGB(255,0,0)
        end
        task.delay(0.3,function()
            if Gui then Gui.ManualTackleLabel.Color=Color3.fromRGB(255,255,255) end
        end)
        return false
    end
end

-- ==========================================================
-- AUTOTACKLE
-- ==========================================================
local AutoTackle={}
AutoTackle.Start=function()
    if AutoTackleStatus.Running then return end
    AutoTackleStatus.Running=true
    if not Gui then SetupGUI() end
    AutoTackleStatus.HeartbeatConnection=RunService.Heartbeat:Connect(function()
        pcall(UpdatePing); pcall(UpdateDribbleStates)
        pcall(PrecomputePlayers); pcall(UpdateTargetCircles)
        IsTypingInChat=CheckIfTypingInChat()
    end)
    AutoTackleStatus.InputConnection=UserInputService.InputBegan:Connect(function(inp,gp)
        if gp or not AutoTackleConfig.Enabled or not AutoTackleConfig.ManualTackleEnabled then return end
        if IsTypingInChat then return end
        if inp.KeyCode==AutoTackleConfig.ManualTackleKeybind then ManualTackleAction() end
    end)
    AutoTackleStatus.Connection=RunService.Heartbeat:Connect(function()
        if not AutoTackleConfig.Enabled then CleanupDebugText(); UpdateDebugVisibility(); return end
        pcall(function()
            local canT,ball,dist,owner=CanTackle()
            if not canT or not ball then
                if Gui then
                    Gui.TackleTargetLabel.Text   ="Target: None"
                    Gui.TackleDribblingLabel.Text="isDribbling: false"
                    Gui.TackleTacklingLabel.Text ="isTackling: false"
                    Gui.TackleWaitLabel.Text     ="Wait: 0.00"
                    Gui.EagleEyeLabel.Text       ="EagleEye: Idle"
                end
                if owner then
                    local oRoot=owner.Character and owner.Character:FindFirstChild("HumanoidRootPart")
                    if oRoot then UpdatePredictionBox(oRoot,owner) end
                else
                    if Gui and Gui.PredictionBoxLines then HideBoxLines(Gui.PredictionBoxLines) end
                end
                CurrentTargetOwner=nil; return
            end
            if Gui then
                Gui.TackleTargetLabel.Text   ="Target: "..(owner and owner.Name or "None")
                Gui.TackleDribblingLabel.Text="isDribbling: "..tostring(owner and DribbleStates[owner] and DribbleStates[owner].IsDribbling or false)
                Gui.TackleTacklingLabel.Text ="isTackling: "..tostring(owner and IsSpecificTackle(owner) or false)
                Gui.PingLabel.Text           =string.format("Ping: %dms",_mfloor(AutoTackleStatus.Ping*1000+0.5))
            end
            if owner then
                local oRoot=owner.Character and owner.Character:FindFirstChild("HumanoidRootPart")
                if oRoot then UpdatePredictionLabel(oRoot,owner); UpdatePredictionBox(oRoot,owner) end
            end
            if dist<=AutoTackleConfig.TackleDistance then
                PerformTackle(ball,owner)
                if Gui then Gui.EagleEyeLabel.Text="Instant Tackle" end; return
            end
            if owner and IsPowerShooting(owner) then
                PerformTackle(ball,owner)
                if Gui then Gui.EagleEyeLabel.Text="PowerShooting!" end; return
            end
            CurrentTargetOwner=owner
            if AutoTackleConfig.Mode=="ManualTackle" then
                if Gui then
                    Gui.EagleEyeLabel.Text     ="ManualTackle: Ready"
                    Gui.ManualTackleLabel.Text ="ManualTackle: READY"
                    Gui.ManualTackleLabel.Color=Color3.fromRGB(0,255,0)
                end; return
            end
            if not owner then return end
            local st=DribbleStates[owner] or {IsDribbling=false,LastDribbleEnd=0,IsProcessingDelay=false}
            local isDrib=st.IsDribbling; local inCooldown=DribbleCooldownList[owner]~=nil
            if AutoTackleConfig.Mode=="OnlyDribble" then
                if inCooldown then
                    PerformTackle(ball,owner)
                    if Gui then Gui.EagleEyeLabel.Text="OnlyDribble: Tackling!" end
                elseif isDrib then
                    if Gui then Gui.EagleEyeLabel.Text="OnlyDribble: Dribbling..." end
                elseif st.IsProcessingDelay then
                    local rem=_mmax(AutoTackleConfig.DribbleDelayTime,0)-(_tick()-st.LastDribbleEnd)
                    if Gui then
                        Gui.EagleEyeLabel.Text  ="OnlyDribble: DribDelay"
                        Gui.TackleWaitLabel.Text=string.format("Wait: %.2f",rem)
                    end
                else
                    if Gui then Gui.EagleEyeLabel.Text="OnlyDribble: Waiting" end
                end
            elseif AutoTackleConfig.Mode=="EagleEye" then
                local now=_tick()
                if isDrib then
                    EagleEyeTimers[owner]=nil
                    if Gui then Gui.EagleEyeLabel.Text="EagleEye: Dribbling (reset)" end
                elseif st.IsProcessingDelay then
                    EagleEyeTimers[owner]=nil
                    local rem=_mmax(AutoTackleConfig.DribbleDelayTime,0)-(now-st.LastDribbleEnd)
                    if Gui then Gui.EagleEyeLabel.Text=string.format("EagleEye: DDelay %.2f",rem) end
                elseif inCooldown then
                    PerformTackle(ball,owner); EagleEyeTimers[owner]=nil
                    if Gui then Gui.EagleEyeLabel.Text="EagleEye: Post-Dribble!" end
                else
                    if not EagleEyeTimers[owner] then
                        local wt=AutoTackleConfig.EagleEyeMinDelay+math.random()*(AutoTackleConfig.EagleEyeMaxDelay-AutoTackleConfig.EagleEyeMinDelay)
                        EagleEyeTimers[owner]={startTime=now,waitTime=wt}
                    end
                    local tmr=EagleEyeTimers[owner]; local el=now-tmr.startTime
                    if el>=tmr.waitTime then
                        PerformTackle(ball,owner); EagleEyeTimers[owner]=nil
                        if Gui then Gui.EagleEyeLabel.Text="EagleEye: Tackling!" end
                    else
                        if Gui then
                            Gui.TackleWaitLabel.Text=string.format("Wait: %.2f",tmr.waitTime-el)
                            Gui.EagleEyeLabel.Text  ="EagleEye: Waiting"
                        end
                    end
                end
            end
        end)
    end)
    if DebugConfig.MoveEnabled then SetupDebugMovement() end
    UpdateDebugVisibility()
    if notify then notify("AutoTackle","Started",true) end
end

AutoTackle.Stop=function()
    if AutoTackleStatus.Connection then AutoTackleStatus.Connection:Disconnect(); AutoTackleStatus.Connection=nil end
    if AutoTackleStatus.HeartbeatConnection then AutoTackleStatus.HeartbeatConnection:Disconnect(); AutoTackleStatus.HeartbeatConnection=nil end
    if AutoTackleStatus.InputConnection then AutoTackleStatus.InputConnection:Disconnect(); AutoTackleStatus.InputConnection=nil end
    AutoTackleStatus.Running=false
    CleanupDebugText(); UpdateDebugVisibility()
    for _,c in pairs(AutoTackleStatus.TargetCircles) do for _,ln in ipairs(c) do ln:Remove() end end
    AutoTackleStatus.TargetCircles={}
    if notify then notify("AutoTackle","Stopped",true) end
end

-- ==========================================================
-- AUTODRIBBLE — v4.0
-- ==========================================================
local _cachedAngleDeg =-1
local _cachedCosThresh= 0
local function GetCosThreshold()
    if AutoDribbleConfig.MinAngleForDribble~=_cachedAngleDeg then
        _cachedAngleDeg =AutoDribbleConfig.MinAngleForDribble
        _cachedCosThresh=_mcos(_mrad(_cachedAngleDeg))
    end
    return _cachedCosThresh
end

local _velSmooth={}
local SMOOTH_ALPHA=0.35
local function GetSmoothedVelocity(player,vx,vy,vz)
    local prev=_velSmooth[player]
    if not prev then _velSmooth[player]={X=vx,Y=vy,Z=vz}; return vx,vy,vz end
    local sx=SMOOTH_ALPHA*vx+(1-SMOOTH_ALPHA)*prev.X
    local sy=SMOOTH_ALPHA*vy+(1-SMOOTH_ALPHA)*prev.Y
    local sz=SMOOTH_ALPHA*vz+(1-SMOOTH_ALPHA)*prev.Z
    _velSmooth[player]={X=sx,Y=sy,Z=sz}
    return sx,sy,sz
end

-- ============================================================
-- v4.0: ShouldDribbleNow
--
-- STRICT (переписан, максимально простой):
--   Предсказываем позицию врага на ping+dt секунд вперёд.
--   Если расстояние от предсказанной позиции до моей serverPos
--   меньше StrictHitRadius — враг касается меня → срабатываем.
--   Дополнительно: враг должен двигаться (speed >= 1.5).
--   RequireTackleAnim: если true — только при IsTackling.
--   Никакой тригонометрии, только одна проверка расстояния.
--
-- FREE (без изменений из v3.9):
--   RequireTackleAnim управляет IsTackling в ActivationDistance.
--   За зоной: угол + TTC.
-- ============================================================
local function ShouldDribbleNow(player,data)
    if not player or not data then return false end
    local root=data.RootPart; if not root then return false end

    -- RequireTackleAnim: общая блокировка если включена
    if AutoDribbleConfig.RequireTackleAnim and not data.IsTackling then
        if Gui then Gui.AngleLabel.Text="[RTA] no tackle anim" end
        return false
    end

    local vx,vy,vz=GetSmoothedVelocity(player,data.VX,data.VY,data.VZ)
    local speed2D_sq=vx*vx+vz*vz

    local serverCF=GetMyServerCFrame()
    local msx,msy,msz=serverCF.Position.X,serverCF.Position.Y,serverCF.Position.Z

    local tp=root.Position
    local ping=AutoTackleStatus.Ping

    -- ==========================================
    -- STRICT v4.0: одна проверка дистанции
    -- ==========================================
    if AutoDribbleConfig.DribbleMode=="Strict" then
        -- Враг должен двигаться
        if speed2D_sq < 1.5*1.5 then
            if Gui then Gui.AngleLabel.Text=string.format("[S] slow v=%.1f",_msqrt(speed2D_sq)) end
            return false
        end

        -- Шаг предсказания: ping*1.5 (серверная задержка) + дополнительный шаг
        -- Мы проверяем несколько моментов времени вперёд чтобы не пропустить пересечение
        local radius=AutoDribbleConfig.StrictHitRadius
        local r2=radius*radius

        -- Проверяем 3 момента: t=ping, t=ping*1.5, t=ping*2
        -- Если хотя бы один попадает в радиус — срабатываем
        local steps={ping, ping*1.5, ping*2.0}
        local minDist2=math.huge
        local hitT=-1

        for _,t in ipairs(steps) do
            local px=tp.X+vx*t
            local pz=tp.Z+vz*t
            local dx=px-msx; local dz=pz-msz
            -- Y не учитываем (горизонтальная плоскость)
            local d2=dx*dx+dz*dz
            if d2 < minDist2 then minDist2=d2; hitT=t end
            if d2 <= r2 then
                if Gui then
                    Gui.AngleLabel.Text=string.format("[S] HIT d=%.1f t=%.2f",_msqrt(d2),t)
                end
                return true
            end
        end

        if Gui then
            Gui.AngleLabel.Text=string.format("[S] MISS d=%.1f r=%.1f",_msqrt(minDist2),radius)
        end
        return false
    end

    -- ==========================================
    -- FREE MODE
    -- ==========================================
    local dist2D_sq=(tp.X-msx)*(tp.X-msx)+(tp.Z-msz)*(tp.Z-msz)
    local dist2D=_msqrt(dist2D_sq)
    local maxD=AutoDribbleConfig.MaxDribbleDistance
    if dist2D_sq>maxD*maxD then
        if Gui then Gui.AngleLabel.Text=string.format("FAR d=%.1f",dist2D) end
        return false
    end

    -- Вплотную
    if dist2D<3 then
        if Gui then Gui.AngleLabel.Text=string.format("⚡ POINT_BLANK d=%.1f",dist2D) end
        return true
    end

    local actD=AutoDribbleConfig.DribbleActivationDistance
    if dist2D<=actD then
        -- В зоне активации: требуем IsTackling если RequireTackleAnim (уже проверено выше)
        -- Без RequireTackleAnim — реагируем всегда в зоне
        if not AutoDribbleConfig.RequireTackleAnim and not data.IsTackling then
            if Gui then Gui.AngleLabel.Text=string.format("FREE CLOSE no_tackle d=%.1f",dist2D) end
            return false
        end
        if Gui then Gui.AngleLabel.Text=string.format("⚡ FREE CLOSE d=%.1f",dist2D) end
        return true
    end

    -- За зоной: угол + скорость + TTC
    if speed2D_sq < 2.0*2.0 then
        if Gui then Gui.AngleLabel.Text=string.format("FREE slow v=%.1f",_msqrt(speed2D_sq)) end
        return false
    end
    local toMeX=msx-tp.X; local toMeZ=msz-tp.Z
    local invDist=1/_mmax(dist2D,0.001)
    local umX=toMeX*invDist; local umZ=toMeZ*invDist
    local speed2D=_msqrt(speed2D_sq)
    local invSpd=1/speed2D
    local dot=_mclamp((vx*invSpd)*umX+(vz*invSpd)*umZ,-1,1)
    if dot<GetCosThreshold() then
        if Gui then Gui.AngleLabel.Text=string.format("FREE BAD_A %.0f°",_mdeg(_acos(dot))) end
        return false
    end
    local relSpd=vx*umX+vz*umZ
    local mvx,_,mvz=GetMyVelocityFromHistory()
    local myAp=-(mvx*umX+mvz*umZ)
    local relSpeedF=relSpd+_mmax(myAp,0)
    if relSpeedF<0.5 then return false end
    local ttc=dist2D/_mmax(relSpeedF,1)
    if Gui then Gui.AngleLabel.Text=string.format("FREE A=%.0f° t=%.2f d=%.1f",_mdeg(_acos(dot)),ttc,dist2D) end
    return ttc<0.4
end

local function PerformDribble()
    local now=_tick()
    if now-AutoDribbleStatus.LastDribbleTime<0.02 then return end
    local myBF=Workspace:FindFirstChild(LocalPlayer.Name)
    local bools=myBF and myBF:FindFirstChild("Bools")
    if not bools or bools.dribbleDebounce.Value then return end
    pcall(function() ActionRemote:FireServer("Deke") end)
    AutoDribbleStatus.LastDribbleTime=now
    if Gui and AutoDribbleConfig.Enabled then
        Gui.DribbleStatusLabel.Text ="Dribble: Cooldown"
        Gui.DribbleStatusLabel.Color=Color3.fromRGB(255,0,0)
        Gui.AutoDribbleLabel.Text   ="AutoDribble: DEKE!"
    end
end

local AutoDribble={}

local _dribCache={
    result=false,lastPlayer=nil,lastTacklerPos={X=0,Z=0},lastMyPos={X=0,Z=0},
    lastIsTackling=false,lastCalcTime=0,
    RECALC_INTERVAL=0.008, POS_DIRTY=0.15,
}

local function IsDribbleCacheDirty(player,data)
    if not player or not data then return true end
    local now=_tick()
    if now-_dribCache.lastCalcTime>_dribCache.RECALC_INTERVAL then return true end
    if _dribCache.lastPlayer~=player then return true end
    if _dribCache.lastIsTackling~=data.IsTackling then return true end
    local root=data.RootPart
    if root then
        local cp=_dribCache.lastTacklerPos; local rp=root.Position
        local dx=rp.X-cp.X; local dz=rp.Z-cp.Z
        if dx*dx+dz*dz>_dribCache.POS_DIRTY*_dribCache.POS_DIRTY then return true end
    end
    local mp=_dribCache.lastMyPos; local hp=HumanoidRootPart.Position
    local mdx=hp.X-mp.X; local mdz=hp.Z-mp.Z
    if mdx*mdx+mdz*mdz>_dribCache.POS_DIRTY*_dribCache.POS_DIRTY then return true end
    return false
end

AutoDribble.Start=function()
    if AutoDribbleStatus.Running then return end
    AutoDribbleStatus.Running=true
    AutoDribbleStatus.HeartbeatConnection=RunService.Heartbeat:Connect(function()
        if not AutoDribbleConfig.Enabled then return end
        pcall(function()
            UpdatePing(); UpdateDribbleStates(); PrecomputePlayers()
            UpdateTargetCircles(); RecordMyPosition()
            IsTypingInChat=CheckIfTypingInChat(); UpdateServerPosBox()
        end)
    end)
    if not Gui then SetupGUI() end
    local function DribbleLoop()
        if not AutoDribbleConfig.Enabled then CleanupDebugText(); UpdateDebugVisibility(); return end
        if not HasBall or not CanDribbleNow then
            if Gui then Gui.AutoDribbleLabel.Text="AutoDribble: Idle" end; return
        end
        local target,minDist,count,targetData=nil,math.huge,0,nil
        for p,d in pairs(PrecomputedPlayers) do
            if d.IsValid then
                count+=1
                if d.Distance<minDist then minDist=d.Distance; target=p; targetData=d end
            end
        end
        if Gui then
            Gui.DribbleTargetLabel.Text  ="Targets: "..count
            Gui.DribbleTacklingLabel.Text=target and string.format("Nearest: %.1f",minDist) or "Nearest: None"
        end
        if not target or not targetData then
            if Gui then Gui.AutoDribbleLabel.Text="AutoDribble: Idle" end; return
        end
        local shouldFire
        if IsDribbleCacheDirty(target,targetData) then
            shouldFire=ShouldDribbleNow(target,targetData)
            _dribCache.result=shouldFire; _dribCache.lastCalcTime=_tick()
            _dribCache.lastPlayer=target; _dribCache.lastIsTackling=targetData.IsTackling
            if targetData.RootPart then
                local rp=targetData.RootPart.Position
                _dribCache.lastTacklerPos={X=rp.X,Z=rp.Z}
            end
            local hp=HumanoidRootPart.Position; _dribCache.lastMyPos={X=hp.X,Z=hp.Z}
        else
            shouldFire=_dribCache.result
        end
        if shouldFire then PerformDribble()
        else if Gui then Gui.AutoDribbleLabel.Text="AutoDribble: Waiting" end end
    end
    AutoDribbleStatus.Connection=RunService.Heartbeat:Connect(function() pcall(DribbleLoop) end)
    UpdateDebugVisibility()
    if notify then notify("AutoDribble","Started",true) end
end

AutoDribble.Stop=function()
    if AutoDribbleStatus.Connection then AutoDribbleStatus.Connection:Disconnect(); AutoDribbleStatus.Connection=nil end
    if AutoDribbleStatus.HeartbeatConnection then AutoDribbleStatus.HeartbeatConnection:Disconnect(); AutoDribbleStatus.HeartbeatConnection=nil end
    AutoDribbleStatus.Running=false
    if Gui and Gui.ServerPosBoxLines  then HideBoxLines(Gui.ServerPosBoxLines) end
    if Gui and Gui.PredictionBoxLines then HideBoxLines(Gui.PredictionBoxLines) end
    CleanupDebugText(); UpdateDebugVisibility()
    if notify then notify("AutoDribble","Stopped",true) end
end

-- ==========================================================
-- UI
-- ==========================================================
local uiElements={}
local function SetupUI(UI)
    if UI.Sections.AutoTackle then
        UI.Sections.AutoTackle:Header({Name="AutoTackle"})
        UI.Sections.AutoTackle:Divider()
        uiElements.AutoTackleEnabled=UI.Sections.AutoTackle:Toggle({
            Name="Enabled",Default=AutoTackleConfig.Enabled,
            Callback=function(v) AutoTackleConfig.Enabled=v
                if v then AutoTackle.Start() else AutoTackle.Stop() end
                UpdateDebugVisibility()
            end},"AutoTackleEnabled")
        uiElements.AutoTackleMode=UI.Sections.AutoTackle:Dropdown({
            Name="Mode",Default=AutoTackleConfig.Mode,
            Options={"OnlyDribble","EagleEye","ManualTackle"},
            Callback=function(v) AutoTackleConfig.Mode=v
                if Gui then Gui.ModeLabel.Text="Mode: "..v end
            end},"AutoTackleMode")
        UI.Sections.AutoTackle:Divider()
        uiElements.AutoTackleMaxDistance=UI.Sections.AutoTackle:Slider({
            Name="Max Distance",Minimum=5,Maximum=50,Default=AutoTackleConfig.MaxDistance,Precision=1,
            Callback=function(v) AutoTackleConfig.MaxDistance=v end},"AutoTackleMaxDistance")
        uiElements.AutoTackleTackleDistance=UI.Sections.AutoTackle:Slider({
            Name="Instant Tackle Distance",Minimum=0,Maximum=20,Default=AutoTackleConfig.TackleDistance,Precision=1,
            Callback=function(v) AutoTackleConfig.TackleDistance=v end},"AutoTackleTackleDistance")
        uiElements.AutoTackleTackleSpeed=UI.Sections.AutoTackle:Slider({
            Name="Tackle Speed",Minimum=10,Maximum=100,Default=AutoTackleConfig.TackleSpeed,Precision=1,
            Callback=function(v) AutoTackleConfig.TackleSpeed=v end},"AutoTackleTackleSpeed")
        UI.Sections.AutoTackle:Divider()
        uiElements.AutoTackleOnlyPlayer=UI.Sections.AutoTackle:Toggle({
            Name="Only Player",Default=AutoTackleConfig.OnlyPlayer,
            Callback=function(v) AutoTackleConfig.OnlyPlayer=v end},"AutoTackleOnlyPlayer")
        uiElements.AutoTackleRotationMethod=UI.Sections.AutoTackle:Dropdown({
            Name="Rotation Method",Default=AutoTackleConfig.RotationMethod,
            Options={"Snap","Legit","Always","None"},
            Callback=function(v) AutoTackleConfig.RotationMethod=v end},"AutoTackleRotationMethod")
        uiElements.AutoTackleShowPredictionBox=UI.Sections.AutoTackle:Toggle({
            Name="Show Prediction Box",Default=AutoTackleConfig.ShowPredictionBox,
            Callback=function(v)
                AutoTackleConfig.ShowPredictionBox=v
                if not v and Gui and Gui.PredictionBoxLines then HideBoxLines(Gui.PredictionBoxLines) end
                UpdateDebugVisibility()
            end},"AutoTackleShowPredictionBox")
        UI.Sections.AutoTackle:Divider()
        uiElements.AutoTackleDribbleDelay=UI.Sections.AutoTackle:Slider({
            Name="Dribble Delay",Minimum=-0.2,Maximum=2.0,Default=AutoTackleConfig.DribbleDelayTime,Precision=2,
            Callback=function(v) AutoTackleConfig.DribbleDelayTime=v end},"AutoTackleDribbleDelay")
        uiElements.AutoTackleEagleEyeMinDelay=UI.Sections.AutoTackle:Slider({
            Name="EagleEye Min Delay",Minimum=0.0,Maximum=2.0,Default=AutoTackleConfig.EagleEyeMinDelay,Precision=2,
            Callback=function(v) AutoTackleConfig.EagleEyeMinDelay=v end},"AutoTackleEagleEyeMinDelay")
        uiElements.AutoTackleEagleEyeMaxDelay=UI.Sections.AutoTackle:Slider({
            Name="EagleEye Max Delay",Minimum=0.0,Maximum=2.0,Default=AutoTackleConfig.EagleEyeMaxDelay,Precision=2,
            Callback=function(v) AutoTackleConfig.EagleEyeMaxDelay=v end},"AutoTackleEagleEyeMaxDelay")
        UI.Sections.AutoTackle:Divider()
        uiElements.AutoTackleManualTackleEnabled=UI.Sections.AutoTackle:Toggle({
            Name="Manual Tackle Enabled",Default=AutoTackleConfig.ManualTackleEnabled,
            Callback=function(v) AutoTackleConfig.ManualTackleEnabled=v end},"AutoTackleManualTackleEnabled")
        uiElements.AutoTackleManualTackleKeybind=UI.Sections.AutoTackle:Keybind({
            Name="Manual Tackle Key",Default=AutoTackleConfig.ManualTackleKeybind,
            Callback=function(v)
                if not AutoTackleConfig.Enabled or not AutoTackleConfig.ManualTackleEnabled then return end
                ManualTackleAction()
            end,
            onBinded=function(v) AutoTackleConfig.ManualTackleKeybind=v end
        },"AutoTackleManualTackleKeybind")
    end

    if UI.Sections.AutoDribble then
        UI.Sections.AutoDribble:Header({Name="AutoDribble"})
        UI.Sections.AutoDribble:Divider()
        uiElements.AutoDribbleEnabled=UI.Sections.AutoDribble:Toggle({
            Name="Enabled",Default=AutoDribbleConfig.Enabled,
            Callback=function(v) AutoDribbleConfig.Enabled=v
                if v then AutoDribble.Start() else AutoDribble.Stop() end
                UpdateDebugVisibility()
            end},"AutoDribbleEnabled")
        UI.Sections.AutoDribble:Divider()
        uiElements.AutoDribbleMaxDistance=UI.Sections.AutoDribble:Slider({
            Name="Max Distance",Minimum=10,Maximum=50,Default=AutoDribbleConfig.MaxDribbleDistance,Precision=1,
            Callback=function(v) AutoDribbleConfig.MaxDribbleDistance=v end},"AutoDribbleMaxDistance")
        uiElements.AutoDribbleActivationDistance=UI.Sections.AutoDribble:Slider({
            Name="Activation Distance",Minimum=5,Maximum=30,Default=AutoDribbleConfig.DribbleActivationDistance,Precision=1,
            Callback=function(v) AutoDribbleConfig.DribbleActivationDistance=v end},"AutoDribbleActivationDistance")
        uiElements.AutoDribbleMode=UI.Sections.AutoDribble:Dropdown({
            Name="Dribble Mode",Default=AutoDribbleConfig.DribbleMode,
            Options={"Free","Strict"},
            Callback=function(v) AutoDribbleConfig.DribbleMode=v; _cachedAngleDeg=-1 end
        },"AutoDribbleMode")
        uiElements.AutoDribbleMinAngle=UI.Sections.AutoDribble:Slider({
            Name="Max Attack Angle (Free only)",Minimum=10,Maximum=90,
            Default=AutoDribbleConfig.MinAngleForDribble,Precision=0,
            Callback=function(v) AutoDribbleConfig.MinAngleForDribble=v; _cachedAngleDeg=-1 end
        },"AutoDribbleMinAngle")
        uiElements.AutoDribbleStrictRadius=UI.Sections.AutoDribble:Slider({
            Name="Strict Hit Radius",Minimum=1.0,Maximum=8.0,
            Default=AutoDribbleConfig.StrictHitRadius,Precision=1,
            Callback=function(v) AutoDribbleConfig.StrictHitRadius=v end
        },"AutoDribbleStrictRadius")
        UI.Sections.AutoDribble:Divider()
        -- v4.0: RequireTackleAnim toggle — по умолчанию false
        uiElements.AutoDribbleRequireTackleAnim=UI.Sections.AutoDribble:Toggle({
            Name="Require Tackle Anim",Default=AutoDribbleConfig.RequireTackleAnim,
            Callback=function(v) AutoDribbleConfig.RequireTackleAnim=v end
        },"AutoDribbleRequireTackleAnim")
        uiElements.AutoDribbleShowServerPos=UI.Sections.AutoDribble:Toggle({
            Name="Show Server Position Box",Default=AutoDribbleConfig.ShowServerPos,
            Callback=function(v)
                AutoDribbleConfig.ShowServerPos=v
                if not v and Gui and Gui.ServerPosBoxLines then HideBoxLines(Gui.ServerPosBoxLines) end
                UpdateDebugVisibility()
            end},"AutoDribbleShowServerPos")
        UI.Sections.AutoDribble:Divider()
    end

    if UI.Sections.Debug then
        UI.Sections.Debug:Header({Name="Debug"})
        UI.Sections.Debug:SubLabel({Text="* Only for AutoDribble/AutoTackle"})
        UI.Sections.Debug:Divider()
        uiElements.DebugEnabled=UI.Sections.Debug:Toggle({
            Name="Debug Text",Default=DebugConfig.Enabled,
            Callback=function(v) DebugConfig.Enabled=v; UpdateDebugVisibility() end
        },"DebugEnabled")
        uiElements.DebugMoveEnabled=UI.Sections.Debug:Toggle({
            Name="Move Debug Text",Default=DebugConfig.MoveEnabled,
            Callback=function(v) DebugConfig.MoveEnabled=v; if v then SetupDebugMovement() end end
        },"DebugMoveEnabled")
    end
end

-- ============================================================
-- SYNC
-- ============================================================
local function SynchronizeConfigValues()
    local syncMap={
        {uiElements.AutoTackleMaxDistance,         function(v) AutoTackleConfig.MaxDistance=v end},
        {uiElements.AutoTackleTackleDistance,      function(v) AutoTackleConfig.TackleDistance=v end},
        {uiElements.AutoTackleTackleSpeed,         function(v) AutoTackleConfig.TackleSpeed=v end},
        {uiElements.AutoTackleDribbleDelay,        function(v) AutoTackleConfig.DribbleDelayTime=v end},
        {uiElements.AutoTackleEagleEyeMinDelay,    function(v) AutoTackleConfig.EagleEyeMinDelay=v end},
        {uiElements.AutoTackleEagleEyeMaxDelay,    function(v) AutoTackleConfig.EagleEyeMaxDelay=v end},
        {uiElements.AutoDribbleMaxDistance,        function(v) AutoDribbleConfig.MaxDribbleDistance=v end},
        {uiElements.AutoDribbleActivationDistance, function(v) AutoDribbleConfig.DribbleActivationDistance=v end},
        {uiElements.AutoDribbleMinAngle,           function(v) AutoDribbleConfig.MinAngleForDribble=v; _cachedAngleDeg=-1 end},
        {uiElements.AutoDribbleStrictRadius,       function(v) AutoDribbleConfig.StrictHitRadius=v end},
    }
    for _,pair in ipairs(syncMap) do
        local el,fn=pair[1],pair[2]
        if el and el.GetValue then pcall(function() fn(el:GetValue()) end) end
    end
end

-- ============================================================
-- MODULE
-- ============================================================
local AutoDribbleTackleModule={}

function AutoDribbleTackleModule.Init(UI,coreParam,notifyFunc)
    core=coreParam; notify=notifyFunc
    SetupUI(UI)
    local syncTimer=0
    RunService.Heartbeat:Connect(function(dt)
        syncTimer+=dt
        if syncTimer>=1 then syncTimer=0; SynchronizeConfigValues() end
    end)
    LocalPlayer.CharacterAdded:Connect(function(newChar)
        task.wait(1)
        Character=newChar
        Humanoid=newChar:WaitForChild("Humanoid")
        HumanoidRootPart=newChar:WaitForChild("HumanoidRootPart")
        DribbleStates={}; TackleStates={}; PrecomputedPlayers={}
        DribbleCooldownList={}; EagleEyeTimers={}
        AutoTackleStatus.TargetPositionHistory={}
        AutoTackleStatus.TargetCircles={}
        MyPositionHistory={}
        PlayerSizeCache={}
        _cachedAngleDeg=-1; _velSmooth={}
        CurrentTargetOwner=nil
        if AutoTackleConfig.Enabled and not AutoTackleStatus.Running then AutoTackle.Start() end
        if AutoDribbleConfig.Enabled and not AutoDribbleStatus.Running then AutoDribble.Start() end
    end)
end

function AutoDribbleTackleModule:Destroy()
    AutoTackle.Stop(); AutoDribble.Stop()
    if Gui then
        if Gui.ServerPosBoxLines  then RemoveBoxLines(Gui.ServerPosBoxLines) end
        if Gui.PredictionBoxLines then RemoveBoxLines(Gui.PredictionBoxLines) end
    end
end

return AutoDribbleTackleModule
