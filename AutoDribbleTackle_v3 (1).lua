-- [v4.1] AUTO DRIBBLE + AUTO TACKLE
-- Changelog v4.1:
-- [REMOVE] Strict режим — полностью удалён
-- [REMOVE] Синхронизация конфигов — полностью удалена
-- [FIX] 3D Box: размеры берутся из конкретных R15 частей тела:
--       W = UpperTorso.Size.X (только торс, без рук)
--       H = Head.Position.Y+Head.Size.Y/2 - RightFoot.Position.Y+RightFoot.Size.Y/2
--       D = UpperTorso.Size.Z
--       OffsetY = (topY + bottomY)/2 - HRP.Position.Y — фиксированный, без прыжка
--       Всё кэшируется в T-позе при первом обнаружении игрока
-- [FIX] Free логика: если враг <= 8 studs И IsTackling → deke немедленно
--       Иначе — стандартная проверка угла + скорость

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
    Mode                 = "OnlyDribble",   -- "OnlyDribble" | "EagleEye" | "ManualTackle"
    MaxDistance          = 20,
    TackleDistance       = 0,
    TackleSpeed          = 60,
    OnlyPlayer           = true,
    RotationMethod       = "Snap",           -- "Snap" | "Legit" | "Always" | "None"
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
    -- RequireTackleAnim: false = реагирует на любого врага в зоне по углу/скорости
    --                    true  = только если враг использует IsTackling
    RequireTackleAnim         = false,
    -- PointBlankRadius: если враг <= этого расстояния И IsTackling → deke немедленно
    PointBlankRadius          = 8.0,
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

-- ============================================================
-- v4.1: КЭШ РАЗМЕРОВ ТЕЛА (R15 по реальным частям, фиксированный)
-- Считаем ОДИН РАЗ при первом обнаружении в T-позе.
-- W = UpperTorso.Size.X (без рук)
-- H = расстояние от низа RightFoot до верха Head (по локальной Y в T-позе)
-- D = UpperTorso.Size.Z
-- OffsetY = середина [bottomY..topY] относительно HRP.Position.Y
--
-- Размеры частей тела в Roblox не меняются при анимации (Size — не CFrame),
-- поэтому кэш остаётся точным навсегда независимо от прыжков/анимаций.
-- ============================================================
local PlayerBoxCache = {}  -- player -> {W, H, D, OffsetY}

local function GetPlayerBoxDimensions(player)
    if PlayerBoxCache[player] then return PlayerBoxCache[player] end

    local char = player.Character
    if not char then return nil end

    local hrp         = char:FindFirstChild("HumanoidRootPart")
    local upperTorso  = char:FindFirstChild("UpperTorso")
    local head        = char:FindFirstChild("Head")
    local rightFoot   = char:FindFirstChild("RightFoot")
    local leftFoot    = char:FindFirstChild("LeftFoot")

    if not hrp or not upperTorso or not head then
        -- Фоллбэк для нестандартных аватаров
        PlayerBoxCache[player] = { W=2.0, H=5.2, D=2.0, OffsetY=0.4 }
        return PlayerBoxCache[player]
    end

    -- Ширина и глубина — только UpperTorso (без рук, фиксировано)
    local w = upperTorso.Size.X
    local d = upperTorso.Size.Z

    -- Высота: от нижней грани ступней до верхней грани головы
    -- Используем Size (не Position!) т.к. Position меняется при анимации,
    -- а Size — нет. Строим из HipHeight + анатомии.
    --
    -- Реальная анатомия стандартного R15 (studs):
    -- HRP.Size.Y = 2.0, HipHeight = 1.35
    -- → нижний край HRP = HRP.Y - HRP.Size.Y/2 = HRP.Y - 1.0
    -- → пол = HRP.Y - 1.0 - 1.35 = HRP.Y - 2.35
    --
    -- Верхний край головы = HRP.Y + (расстояние до верха головы)
    -- Для стандартного R15 верх головы ≈ HRP.Y + 3.15
    -- → H ≈ 2.35 + 3.15 = 5.5
    -- → offsetY = центр [пол..верх] - HRP.Y
    --           = (HRP.Y-2.35 + HRP.Y+3.15)/2 - HRP.Y
    --           = 0.4

    local hum = char:FindFirstChild("Humanoid")
    local hipH   = hum and hum.HipHeight or 1.35
    local hrpHY  = hrp.Size.Y * 0.5            -- = 1.0 для стандарта

    -- Нижняя граница тела = пол
    local floorOffset = -(hrpHY + hipH)        -- относительно HRP.Y

    -- Верх головы: берём из Size головы + расстояние от HRP до низа головы
    -- Низ головы приблизительно на hrp.Size.Y/2 + upperTorso.Size.Y + neck ~= 3.0 над HRP
    -- Верх головы = низ головы + head.Size.Y
    -- Для точности: измеряем через OriginalSize если есть, иначе используем Size
    local headSizeY   = head.Size.Y
    -- Расстояние от HRP до верха головы для стандартного R15
    -- UpperTorso.Size.Y ≈ 1.5, шея ≈ 0.4, Head.Size.Y ≈ 1.2 → итого ≈ 3.1
    local upperTorsoY = upperTorso.Size.Y
    local neckApprox  = 0.35
    local headTopOffset = hrpHY + upperTorsoY + neckApprox + headSizeY

    local h       = headTopOffset - floorOffset   -- полная высота
    -- OffsetY: смещение центра box от центра HRP
    local centerOffset = (floorOffset + headTopOffset) * 0.5

    local result = { W=w, H=h, D=d, OffsetY=centerOffset }
    PlayerBoxCache[player] = result
    return result
end

-- Для себя (серверная позиция box)
local MyBoxDimensions = nil
local function GetMyBoxDimensions()
    if MyBoxDimensions then return MyBoxDimensions end
    local hrp = HumanoidRootPart
    local ut  = Character:FindFirstChild("UpperTorso")
    local head= Character:FindFirstChild("Head")
    if not ut or not head then
        MyBoxDimensions = { W=2.0, H=5.2, D=2.0, OffsetY=0.4 }
        return MyBoxDimensions
    end
    local hum    = Character:FindFirstChild("Humanoid")
    local hipH   = hum and hum.HipHeight or 1.35
    local hrpHY  = hrp.Size.Y * 0.5
    local floorOffset    = -(hrpHY + hipH)
    local headTopOffset  = hrpHY + ut.Size.Y + 0.35 + head.Size.Y
    local h              = headTopOffset - floorOffset
    local centerOffset   = (floorOffset + headTopOffset) * 0.5
    MyBoxDimensions = { W=ut.Size.X, H=h, D=ut.Size.Z, OffsetY=centerOffset }
    return MyBoxDimensions
end

local SPECIFIC_TACKLE_ID = "rbxassetid://14317040670"

-- ============================================================
-- ИСТОРИЯ ПОЗИЦИЙ
-- ============================================================
local HISTORY_SIZE   = 12
local HISTORY_WINDOW = 0.12

local function RecordTargetPosition(ownerRoot, player)
    local h = AutoTackleStatus.TargetPositionHistory[player]
    if not h then h = {}; AutoTackleStatus.TargetPositionHistory[player] = h end
    local p = ownerRoot.Position
    _tins(h, { time=_tick(), x=p.X, y=p.Y, z=p.Z })
    while #h > HISTORY_SIZE do _trem(h, 1) end
end

local function GetPositionBasedVelocity(player)
    local h = AutoTackleStatus.TargetPositionHistory[player]
    if not h or #h < 2 then return 0,0,0 end
    local now = _tick()
    local ox,oy,oz,ot = nil,nil,nil,nil
    local nx,ny,nz,nt = nil,nil,nil,nil
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
    local dt = nt-ot
    if dt < 0.001 then return 0,0,0 end
    local inv = 1/dt
    return (nx-ox)*inv,(ny-oy)*inv,(nz-oz)*inv
end

local function CalcInterceptTime(fx,fz,tx,tz,vx,vz,speed)
    local dx=tx-fx; local dz=tz-fz
    local d2=dx*dx+dz*dz
    if d2<0.0001 then return 0 end
    local dist=_msqrt(d2)
    local v2=vx*vx+vz*vz; local s2=speed*speed
    local dotDV=dx*vx+dz*vz
    local a=s2-v2; local b=-2*dotDV; local c=-d2
    local t
    if _mabs(a)<0.001 then
        t=(_mabs(b)>0.001) and (-c/b) or (dist/_mmax(speed,1))
    else
        local disc=b*b-4*a*c
        if disc<0 then t=dist/_mmax(speed,1)
        else
            local sq=_msqrt(disc)
            local t1=(-b-sq)/(2*a); local t2=(-b+sq)/(2*a)
            if t1>0 and t2>0 then t=_mmin(t1,t2)
            elseif t1>0 then t=t1
            elseif t2>0 then t=t2
            else t=dist/_mmax(speed,1) end
        end
    end
    return _mclamp(t,0.02,0.5)
end

local function PredictTargetPosition(ownerRoot, player)
    if not ownerRoot then return ownerRoot.Position end
    local ping=AutoTackleStatus.Ping
    local vx,vy,vz=GetPositionBasedVelocity(player)
    local op=ownerRoot.Position
    local sx=op.X+vx*ping; local sz=op.Z+vz*ping
    local mp=HumanoidRootPart.Position
    local it=CalcInterceptTime(mp.X,mp.Z,sx,sz,vx,vz,AutoTackleConfig.TackleSpeed)
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
-- 3D BOX v4.1
-- Все 8 углов строятся из CFrame персонажа + фиксированных размеров.
-- OffsetY = константа из GetPlayerBoxDimensions — не меняется при прыжке.
-- ============================================================
local BOX_EDGES={{1,2},{2,3},{3,4},{4,1},{5,6},{6,7},{7,8},{8,5},{1,5},{2,6},{3,7},{4,8}}

local function CreateBoxLines(color, thickness)
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

-- Строим 8 углов по CFrame персонажа + размеры + OffsetY
-- CFrame берётся только по горизонтальному вращению (Y-axis),
-- чтобы box не наклонялся при прыжках/анимациях
local function GetFlatCFrame(cf)
    -- Убираем pitch и roll — только позиция и yaw
    local x,y,z = cf.X, cf.Y, cf.Z
    local lv = cf.LookVector
    local flatLook = _V3new(lv.X, 0, lv.Z)
    local len = _msqrt(flatLook.X*flatLook.X + flatLook.Z*flatLook.Z)
    if len < 0.001 then
        return CFrame.new(x,y,z)
    end
    return CFrame.lookAt(_V3new(x,y,z), _V3new(x+flatLook.X,y,z+flatLook.Z))
end

local function GetBoxCorners(cf, dims)
    local hW = dims.W * 0.5
    local hH = dims.H * 0.5
    local hD = dims.D * 0.5
    local oY = dims.OffsetY
    -- Используем плоский CFrame — box не наклоняется при прыжке
    local flatCF = GetFlatCFrame(cf)
    return {
        flatCF:PointToWorldSpace(_V3new(-hW, -hH+oY, -hD)),
        flatCF:PointToWorldSpace(_V3new( hW, -hH+oY, -hD)),
        flatCF:PointToWorldSpace(_V3new( hW, -hH+oY,  hD)),
        flatCF:PointToWorldSpace(_V3new(-hW, -hH+oY,  hD)),
        flatCF:PointToWorldSpace(_V3new(-hW,  hH+oY, -hD)),
        flatCF:PointToWorldSpace(_V3new( hW,  hH+oY, -hD)),
        flatCF:PointToWorldSpace(_V3new( hW,  hH+oY,  hD)),
        flatCF:PointToWorldSpace(_V3new(-hW,  hH+oY,  hD)),
    }
end

local function UpdateBoxLines(lines, cf, dims, color)
    if not lines or not dims then return end
    local corners=GetBoxCorners(cf, dims)
    for i, edge in ipairs(BOX_EDGES) do
        local line=lines[i]
        if not line then continue end
        local sa, aOn=Camera:WorldToViewportPoint(corners[edge[1]])
        local sb, bOn=Camera:WorldToViewportPoint(corners[edge[2]])
        if aOn and bOn and sa.Z>0.1 and sb.Z>0.1 then
            line.From=Vector2.new(sa.X,sa.Y)
            line.To=Vector2.new(sb.X,sb.Y)
            if color then line.Color=color end
            line.Visible=true
        else
            line.Visible=false
        end
    end
end

local function HideBoxLines(lines)
    if not lines then return end
    for _, l in ipairs(lines) do l.Visible=false end
end

local function RemoveBoxLines(lines)
    if not lines then return end
    for _, l in ipairs(lines) do pcall(function() l:Remove() end) end
end

-- ============================================================
-- GUI (Drawing)
-- ============================================================
local Gui = nil

local function SetupGUI()
    Gui = {
        TackleWaitLabel=Drawing.new("Text"), TackleTargetLabel=Drawing.new("Text"),
        TackleDribblingLabel=Drawing.new("Text"), TackleTacklingLabel=Drawing.new("Text"),
        EagleEyeLabel=Drawing.new("Text"), DribbleStatusLabel=Drawing.new("Text"),
        DribbleTargetLabel=Drawing.new("Text"), DribbleTacklingLabel=Drawing.new("Text"),
        AutoDribbleLabel=Drawing.new("Text"), CooldownListLabel=Drawing.new("Text"),
        ModeLabel=Drawing.new("Text"), ManualTackleLabel=Drawing.new("Text"),
        PingLabel=Drawing.new("Text"), AngleLabel=Drawing.new("Text"),
        PredictionLabel=Drawing.new("Text"), ServerPosLabel=Drawing.new("Text"),
        TargetRingLines={}, ServerPosBoxLines=nil, PredictionBoxLines=nil,
        TackleDebugLabels={}, DribbleDebugLabels={}
    }

    Gui.ServerPosBoxLines  = CreateBoxLines(Color3.fromRGB(0,200,255), 1.5)
    Gui.PredictionBoxLines = CreateBoxLines(Color3.fromRGB(255,165,0), 1.5)

    local sv=Camera.ViewportSize
    local cx=sv.X/2
    local ty=sv.Y*0.6
    local oty=ty+30; local ody=ty-50

    local tackleL={Gui.TackleWaitLabel,Gui.TackleTargetLabel,Gui.TackleDribblingLabel,
        Gui.TackleTacklingLabel,Gui.EagleEyeLabel,Gui.CooldownListLabel,
        Gui.ModeLabel,Gui.ManualTackleLabel,Gui.PingLabel,Gui.AngleLabel,
        Gui.PredictionLabel,Gui.ServerPosLabel}
    for _,l in ipairs(tackleL) do
        l.Size=16; l.Color=Color3.fromRGB(255,255,255)
        l.Outline=true; l.Center=true
        l.Visible=DebugConfig.Enabled and AutoTackleConfig.Enabled
        _tins(Gui.TackleDebugLabels,l)
    end
    Gui.TackleWaitLabel.Color=Color3.fromRGB(255,165,0)
    Gui.ServerPosLabel.Color=Color3.fromRGB(0,200,255)

    local function ap(label) label.Position=Vector2.new(cx,oty); oty+=15 end
    ap(Gui.TackleWaitLabel); ap(Gui.TackleTargetLabel); ap(Gui.TackleDribblingLabel)
    ap(Gui.TackleTacklingLabel); ap(Gui.EagleEyeLabel); ap(Gui.CooldownListLabel)
    ap(Gui.ModeLabel); ap(Gui.ManualTackleLabel); ap(Gui.PingLabel)
    ap(Gui.AngleLabel); ap(Gui.PredictionLabel); ap(Gui.ServerPosLabel)

    local dribbleL={Gui.DribbleStatusLabel,Gui.DribbleTargetLabel,
        Gui.DribbleTacklingLabel,Gui.AutoDribbleLabel}
    for _,l in ipairs(dribbleL) do
        l.Size=16; l.Color=Color3.fromRGB(255,255,255)
        l.Outline=true; l.Center=true
        l.Visible=DebugConfig.Enabled and AutoDribbleConfig.Enabled
        _tins(Gui.DribbleDebugLabels,l)
    end
    local function adp(l) l.Position=Vector2.new(cx,ody); ody+=15 end
    adp(Gui.DribbleStatusLabel); adp(Gui.DribbleTargetLabel)
    adp(Gui.DribbleTacklingLabel); adp(Gui.AutoDribbleLabel)

    Gui.TackleWaitLabel.Text="Wait: 0.00"; Gui.TackleTargetLabel.Text="Target: None"
    Gui.TackleDribblingLabel.Text="isDribbling: false"; Gui.TackleTacklingLabel.Text="isTackling: false"
    Gui.EagleEyeLabel.Text="EagleEye: Idle"; Gui.CooldownListLabel.Text="CooldownList: 0"
    Gui.ModeLabel.Text="Mode: "..AutoTackleConfig.Mode; Gui.ManualTackleLabel.Text="ManualTackle: Ready"
    Gui.PingLabel.Text="Ping: 0ms"; Gui.AngleLabel.Text="Angle: -"
    Gui.PredictionLabel.Text="Pred: 0ms"; Gui.ServerPosLabel.Text="ServerPos: -"
    Gui.DribbleStatusLabel.Text="Dribble: Ready"; Gui.DribbleTargetLabel.Text="Targets: 0"
    Gui.DribbleTacklingLabel.Text="Nearest: None"; Gui.AutoDribbleLabel.Text="AutoDribble: Idle"

    for i=1,24 do
        local l=Drawing.new("Line")
        l.Thickness=3; l.Color=Color3.fromRGB(255,0,0); l.Visible=false
        _tins(Gui.TargetRingLines,l)
    end
end

local function UpdateDebugVisibility()
    if not Gui then return end
    local tv=DebugConfig.Enabled and AutoTackleConfig.Enabled
    for _,l in ipairs(Gui.TackleDebugLabels) do l.Visible=tv end
    local dv=DebugConfig.Enabled and AutoDribbleConfig.Enabled
    for _,l in ipairs(Gui.DribbleDebugLabels) do l.Visible=dv end
    if not AutoTackleConfig.Enabled then
        for _,l in ipairs(Gui.TargetRingLines) do l.Visible=false end
        HideBoxLines(Gui.PredictionBoxLines)
    end
    if not AutoDribbleConfig.Enabled or not AutoDribbleConfig.ShowServerPos then
        HideBoxLines(Gui.ServerPosBoxLines)
    end
end

local function CleanupDebugText()
    if not Gui then return end
    if not AutoTackleConfig.Enabled then
        Gui.TackleWaitLabel.Text="Wait: 0.00"; Gui.TackleTargetLabel.Text="Target: None"
        Gui.TackleDribblingLabel.Text="isDribbling: false"
        Gui.TackleTacklingLabel.Text="isTackling: false"
        Gui.EagleEyeLabel.Text="EagleEye: Idle"
        Gui.ManualTackleLabel.Text="ManualTackle: Ready"
        Gui.ModeLabel.Text="Mode: "..AutoTackleConfig.Mode
        Gui.PingLabel.Text="Ping: 0ms"; Gui.PredictionLabel.Text="Pred: 0ms"
    end
    if not AutoDribbleConfig.Enabled then
        Gui.DribbleStatusLabel.Text="Dribble: Ready"; Gui.DribbleTargetLabel.Text="Targets: 0"
        Gui.DribbleTacklingLabel.Text="Nearest: None"; Gui.AutoDribbleLabel.Text="AutoDribble: Idle"
        HideBoxLines(Gui.ServerPosBoxLines)
    end
end

-- ============================================================
-- SERVER POS BOX UPDATE
-- ============================================================
local function UpdateServerPosBox()
    if not Gui or not Gui.ServerPosBoxLines then return end
    if not AutoDribbleConfig.Enabled or not AutoDribbleConfig.ShowServerPos then
        HideBoxLines(Gui.ServerPosBoxLines); return
    end
    local serverCF = GetMyServerCFrame()
    local dims = GetMyBoxDimensions()
    UpdateBoxLines(Gui.ServerPosBoxLines, serverCF, dims, Color3.fromRGB(0,200,255))
    if Gui.ServerPosLabel and DebugConfig.Enabled then
        local nd=_mfloor(AutoTackleStatus.Ping*1.5*1000+0.5)
        local dv=serverCF.Position-HumanoidRootPart.Position
        local dist=_msqrt(dv.X*dv.X+dv.Y*dv.Y+dv.Z*dv.Z)
        Gui.ServerPosLabel.Text=string.format("ServerPos: %dms | %.1f st",nd,dist)
    end
end

local function UpdatePredictionBox(ownerRoot, player)
    if not Gui or not Gui.PredictionBoxLines then return end
    if not AutoTackleConfig.Enabled or not AutoTackleConfig.ShowPredictionBox then
        HideBoxLines(Gui.PredictionBoxLines); return
    end
    if not ownerRoot or not player then HideBoxLines(Gui.PredictionBoxLines); return end
    local predictedPos=PredictTargetPosition(ownerRoot, player)
    local predictedCF=CFrame.new(predictedPos)
    local dims=GetPlayerBoxDimensions(player)
    UpdateBoxLines(Gui.PredictionBoxLines, predictedCF, dims, Color3.fromRGB(255,165,0))
end

-- ============================================================
-- 3D КРУГИ
-- ============================================================
local function Create3DCircle()
    local c={}
    for i=1,24 do
        local l=Drawing.new("Line")
        l.Thickness=3; l.Color=Color3.fromRGB(255,0,0); l.Visible=false
        _tins(c,l)
    end
    return c
end

local function Update3DCircle(circle, pos, radius, color)
    if not circle then return end
    local segs=#circle
    local points={}
    local px,pz,py=pos.X,pos.Z,pos.Y
    local step=(2*math.pi)/segs
    for i=1,segs do
        local a=(i-1)*step
        _tins(points,_V3new(px+_mcos(a)*radius, py, pz+math.sin(a)*radius))
    end
    for i,l in ipairs(circle) do
        local sp=points[i]; local ep=points[i%segs+1]
        local ss,sOn=Camera:WorldToViewportPoint(sp)
        local es,eOn=Camera:WorldToViewportPoint(ep)
        if sOn and eOn and ss.Z>0.1 and es.Z>0.1 then
            l.From=Vector2.new(ss.X,ss.Y); l.To=Vector2.new(es.X,es.Y)
            l.Color=color; l.Visible=true
        else l.Visible=false end
    end
end

local function Hide3DCircle(circle)
    if not circle then return end
    for _,l in ipairs(circle) do l.Visible=false end
end

local function UpdateTargetCircles()
    local cur={}
    for player,data in pairs(PrecomputedPlayers) do
        if data.IsValid and TackleStates[player] and TackleStates[player].IsTackling then
            cur[player]=true
            if not AutoTackleStatus.TargetCircles[player] then
                AutoTackleStatus.TargetCircles[player]=Create3DCircle()
            end
            local circle=AutoTackleStatus.TargetCircles[player]
            local tr=data.RootPart
            if tr then
                local d=data.Distance
                local color=Color3.fromRGB(255,0,0)
                if d<=AutoDribbleConfig.DribbleActivationDistance then color=Color3.fromRGB(0,255,0)
                elseif d<=AutoDribbleConfig.MaxDribbleDistance then color=Color3.fromRGB(255,165,0) end
                Update3DCircle(circle,tr.Position-_V3new(0,0.5,0),2,color)
            end
        end
    end
    for player,circle in pairs(AutoTackleStatus.TargetCircles) do
        if not cur[player] then Hide3DCircle(circle) end
    end
end

-- ============================================================
-- DRAG DEBUG
-- ============================================================
local function SetupDebugMovement()
    if not DebugConfig.MoveEnabled or not Gui then return end
    local isDragging=false; local dragStart=Vector2.new(0,0)
    local startPos={}
    for _,l in ipairs(Gui.TackleDebugLabels) do startPos[l]=l.Position end
    for _,l in ipairs(Gui.DribbleDebugLabels) do startPos[l]=l.Position end
    UserInputService.InputBegan:Connect(function(inp,gp)
        if gp or not DebugConfig.MoveEnabled then return end
        if inp.UserInputType==Enum.UserInputType.MouseButton1 then
            local mp=UserInputService:GetMouseLocation()
            for l,_ in pairs(startPos) do
                if l.Visible then
                    local p=l.Position; local tb=l.TextBounds
                    if mp.X>=p.X-tb.X*0.5 and mp.X<=p.X+tb.X*0.5 and
                       mp.Y>=p.Y-tb.Y*0.5 and mp.Y<=p.Y+tb.Y*0.5 then
                        isDragging=true; dragStart=mp; break
                    end
                end
            end
        end
    end)
    UserInputService.InputChanged:Connect(function(inp,gp)
        if gp or not isDragging then return end
        if inp.UserInputType==Enum.UserInputType.MouseMovement then
            local d=UserInputService:GetMouseLocation()-dragStart
            for l,sp in pairs(startPos) do l.Position=sp+d end
        end
    end)
    UserInputService.InputEnded:Connect(function(inp,gp)
        if gp or not isDragging then return end
        if inp.UserInputType==Enum.UserInputType.MouseButton1 then
            local d=UserInputService:GetMouseLocation()-dragStart
            for l,sp in pairs(startPos) do startPos[l]=sp+d end
            isDragging=false
        end
    end)
end

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

-- ============================================================
-- ПРОВЕРКИ СОСТОЯНИЙ
-- ============================================================
local function IsDribbling(target)
    if not target or not target.Character or not target.Parent
       or target.TeamColor==LocalPlayer.TeamColor then return false end
    local hum=target.Character:FindFirstChild("Humanoid")
    if not hum then return false end
    local anim=hum:FindFirstChild("Animator")
    if not anim then return false end
    for _,t in pairs(anim:GetPlayingAnimationTracks()) do
        if t.Animation and table.find(DribbleAnimIds,t.Animation.AnimationId) then return true end
    end
    return false
end

local function IsSpecificTackle(target)
    if not target or not target.Character or not target.Parent
       or target.TeamColor==LocalPlayer.TeamColor then return false end
    local hum=target.Character:FindFirstChild("Humanoid")
    if not hum then return false end
    local anim=hum:FindFirstChild("Animator")
    if not anim then return false end
    for _,t in pairs(anim:GetPlayingAnimationTracks()) do
        if t.Animation and t.Animation.AnimationId==SPECIFIC_TACKLE_ID then return true end
    end
    return false
end

local function IsPowerShooting(target)
    if not target then return false end
    local pf=Workspace:FindFirstChild(target.Name)
    if not pf then return false end
    local b=pf:FindFirstChild("Bools")
    if not b then return false end
    local ps=b:FindFirstChild("PowerShooting")
    return ps and ps.Value==true
end

-- ============================================================
-- DRIBBLE STATES
-- ============================================================
local function UpdateDribbleStates()
    local now=_tick()
    for _,player in pairs(Players:GetPlayers()) do
        if player==LocalPlayer or not player.Parent
           or player.TeamColor==LocalPlayer.TeamColor then continue end
        if not DribbleStates[player] then
            DribbleStates[player]={IsDribbling=false,LastDribbleEnd=0,IsProcessingDelay=false,HadDribble=false}
        end
        local s=DribbleStates[player]
        local dribblingNow=IsDribbling(player)
        if dribblingNow and not s.IsDribbling then
            s.IsDribbling=true; s.IsProcessingDelay=false; s.HadDribble=true
        elseif not dribblingNow and s.IsDribbling then
            s.IsDribbling=false; s.LastDribbleEnd=now; s.IsProcessingDelay=true
        elseif s.IsProcessingDelay and not dribblingNow then
            if now-s.LastDribbleEnd>=AutoTackleConfig.DribbleDelayTime then
                DribbleCooldownList[player]=now+3.5
                s.IsProcessingDelay=false
            end
        end
    end
    local toRemove={}
    for player,endTime in pairs(DribbleCooldownList) do
        if not player or not player.Parent or now>=endTime then _tins(toRemove,player) end
    end
    for _,p in ipairs(toRemove) do DribbleCooldownList[p]=nil; EagleEyeTimers[p]=nil end
    if Gui and AutoTackleConfig.Enabled then
        local c=0; for _ in pairs(DribbleCooldownList) do c+=1 end
        Gui.CooldownListLabel.Text="CooldownList: "..tostring(c)
    end
end

-- ============================================================
-- PRECOMPUTE PLAYERS
-- ============================================================
local function PrecomputePlayers()
    PrecomputedPlayers={}; HasBall=false; CanDribbleNow=false
    local ball=Workspace:FindFirstChild("ball")
    if ball and ball:FindFirstChild("playerWeld") and ball:FindFirstChild("creator") then
        HasBall=ball.creator.Value==LocalPlayer
    end
    local bools=Workspace:FindFirstChild(LocalPlayer.Name) and Workspace[LocalPlayer.Name]:FindFirstChild("Bools")
    if bools then
        CanDribbleNow=not bools.dribbleDebounce.Value
        if Gui and AutoDribbleConfig.Enabled then
            Gui.DribbleStatusLabel.Text=bools.dribbleDebounce.Value and "Dribble: Cooldown" or "Dribble: Ready"
            Gui.DribbleStatusLabel.Color=bools.dribbleDebounce.Value
                and Color3.fromRGB(255,0,0) or Color3.fromRGB(0,255,0)
        end
    end
    local myPos=HumanoidRootPart.Position
    for _,player in pairs(Players:GetPlayers()) do
        if player==LocalPlayer or not player.Parent
           or player.TeamColor==LocalPlayer.TeamColor then continue end
        local char=player.Character; if not char then continue end
        local hum=char:FindFirstChild("Humanoid")
        if not hum or hum.HipHeight>=4 then continue end
        local tr=char:FindFirstChild("HumanoidRootPart"); if not tr then continue end
        TackleStates[player]=TackleStates[player] or {IsTackling=false}
        TackleStates[player].IsTackling=IsSpecificTackle(player)
        local tp=tr.Position
        local dv=tp-myPos
        local dist=_msqrt(dv.X*dv.X+dv.Y*dv.Y+dv.Z*dv.Z)
        if dist>AutoDribbleConfig.MaxDribbleDistance then continue end
        local alv=tr.AssemblyLinearVelocity
        local pvx,pvy,pvz=GetPositionBasedVelocity(player)
        local posVelMag=_msqrt(pvx*pvx+pvz*pvz)
        local vel=alv.Magnitude>=posVelMag and alv or _V3new(pvx,pvy,pvz)
        PrecomputedPlayers[player]={
            Distance=dist, IsValid=true,
            IsTackling=TackleStates[player].IsTackling,
            RootPart=tr, Humanoid=hum, Velocity=vel
        }
        if dist<=AutoDribbleConfig.DribbleActivationDistance*1.5 then
            RecordTargetPosition(tr,player)
        end
    end
end

-- ============================================================
-- РОТАЦИЯ
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
-- CanTackle / PerformTackle / ManualTackle
-- ============================================================
local function CanTackle()
    local ball=Workspace:FindFirstChild("ball")
    if not ball or not ball.Parent then return false,nil,nil,nil end
    local hasOwner=ball:FindFirstChild("playerWeld") and ball:FindFirstChild("creator")
    local owner=hasOwner and ball.creator.Value or nil
    if AutoTackleConfig.OnlyPlayer and (not hasOwner or not owner or not owner.Parent) then
        return false,nil,nil,nil
    end
    local isEnemy=not owner or (owner and owner.TeamColor~=LocalPlayer.TeamColor)
    if not isEnemy then return false,nil,nil,nil end
    if Workspace:FindFirstChild("Bools") and
       (Workspace.Bools.APG.Value==LocalPlayer or Workspace.Bools.HPG.Value==LocalPlayer) then
        return false,nil,nil,nil
    end
    local bv=HumanoidRootPart.Position-ball.Position
    local dist=_msqrt(bv.X*bv.X+bv.Y*bv.Y+bv.Z*bv.Z)
    if dist>AutoTackleConfig.MaxDistance then return false,nil,nil,nil end
    if owner and owner.Character then
        local th=owner.Character:FindFirstChild("Humanoid")
        if th and th.HipHeight>=4 then return false,nil,nil,nil end
    end
    local b=Workspace:FindFirstChild(LocalPlayer.Name) and Workspace[LocalPlayer.Name]:FindFirstChild("Bools")
    if b and (b.TackleDebounce.Value or b.Tackled.Value or
       (Character:FindFirstChild("Bools") and Character.Bools.Debounce.Value)) then
        return false,nil,nil,nil
    end
    return true,ball,dist,owner
end

local function PerformTackle(ball, owner)
    local b=Workspace:FindFirstChild(LocalPlayer.Name) and Workspace[LocalPlayer.Name]:FindFirstChild("Bools")
    if not b or b.TackleDebounce.Value or b.Tackled.Value or
       (Character:FindFirstChild("Bools") and Character.Bools.Debounce.Value) then return end
    local ownerRoot=owner and owner.Character and owner.Character:FindFirstChild("HumanoidRootPart")
    local predictedPos
    if ownerRoot and owner then predictedPos=PredictTargetPosition(ownerRoot,owner)
    else predictedPos=ball.Position end
    RotateToTarget(predictedPos)
    if ownerRoot and owner then UpdatePredictionBox(ownerRoot,owner) end
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
    local ts=_tick(); local td=0.65; local rc=nil
    local method=AutoTackleConfig.RotationMethod
    if method=="Always" and ownerRoot and owner then
        rc=RunService.Heartbeat:Connect(function()
            if _tick()-ts<td then RotateToTarget(PredictTargetPosition(ownerRoot,owner))
            else rc:Disconnect() end
        end)
    elseif method=="Legit" and ownerRoot and owner then
        local lc=HumanoidRootPart.CFrame
        rc=RunService.Heartbeat:Connect(function()
            if _tick()-ts<td then
                HumanoidRootPart.CFrame=CFrame.new(HumanoidRootPart.Position)*(lc-lc.Position)
            else rc:Disconnect() end
        end)
    end
    Debris:AddItem(bv,td)
    task.delay(td,function() if rc then rc:Disconnect() end end)
    if owner and ball:FindFirstChild("playerWeld") then
        local bvec=HumanoidRootPart.Position-ball.Position
        local bd=_msqrt(bvec.X*bvec.X+bvec.Y*bvec.Y+bvec.Z*bvec.Z)
        pcall(function() SoftDisPlayerRemote:FireServer(owner,bd,false,ball.Size) end)
    end
end

local function ManualTackleAction()
    local now=_tick()
    if now-LastManualTackleTime<AutoTackleConfig.ManualTackleCooldown then return false end
    local canTackle,ball,dist,owner=CanTackle()
    if canTackle then
        LastManualTackleTime=now; PerformTackle(ball,owner)
        if Gui and AutoTackleConfig.Enabled then
            Gui.ManualTackleLabel.Text="ManualTackle: EXECUTED!"
            Gui.ManualTackleLabel.Color=Color3.fromRGB(0,255,0)
        end
        task.delay(0.3,function()
            if Gui and AutoTackleConfig.Enabled then
                Gui.ManualTackleLabel.Color=Color3.fromRGB(255,255,255)
            end
        end)
        return true
    else
        if Gui and AutoTackleConfig.Enabled then
            Gui.ManualTackleLabel.Text="ManualTackle: FAILED"
            Gui.ManualTackleLabel.Color=Color3.fromRGB(255,0,0)
        end
        task.delay(0.3,function()
            if Gui and AutoTackleConfig.Enabled then
                Gui.ManualTackleLabel.Color=Color3.fromRGB(255,255,255)
            end
        end)
        return false
    end
end

-- ============================================================
-- AUTOTACKLE
-- ============================================================
local AutoTackle={}

AutoTackle.Start=function()
    if AutoTackleStatus.Running then return end
    AutoTackleStatus.Running=true
    if not Gui then SetupGUI() end

    AutoTackleStatus.HeartbeatConnection=RunService.Heartbeat:Connect(function()
        pcall(UpdatePing); pcall(UpdateDribbleStates); pcall(PrecomputePlayers)
        pcall(UpdateTargetCircles); IsTypingInChat=CheckIfTypingInChat()
    end)
    AutoTackleStatus.InputConnection=UserInputService.InputBegan:Connect(function(inp,gp)
        if gp or not AutoTackleConfig.Enabled or not AutoTackleConfig.ManualTackleEnabled then return end
        if IsTypingInChat then return end
        if inp.KeyCode==AutoTackleConfig.ManualTackleKeybind then ManualTackleAction() end
    end)

    AutoTackleStatus.Connection=RunService.Heartbeat:Connect(function()
        if not AutoTackleConfig.Enabled then CleanupDebugText(); UpdateDebugVisibility(); return end
        pcall(function()
            local canTackle,ball,distance,owner=CanTackle()
            if not canTackle or not ball then
                if Gui then
                    Gui.TackleTargetLabel.Text="Target: None"
                    Gui.TackleDribblingLabel.Text="isDribbling: false"
                    Gui.TackleTacklingLabel.Text="isTackling: false"
                    Gui.TackleWaitLabel.Text="Wait: 0.00"
                    Gui.EagleEyeLabel.Text="EagleEye: Idle"
                    if AutoTackleConfig.Mode=="ManualTackle" then
                        Gui.ManualTackleLabel.Text="ManualTackle: NO TARGET"
                        Gui.ManualTackleLabel.Color=Color3.fromRGB(255,0,0)
                    end
                end
                HideBoxLines(Gui and Gui.PredictionBoxLines or nil)
                CurrentTargetOwner=nil; return
            end
            if Gui then
                Gui.TackleTargetLabel.Text="Target: "..(owner and owner.Name or "None")
                Gui.TackleDribblingLabel.Text="isDribbling: "..tostring(owner and DribbleStates[owner] and DribbleStates[owner].IsDribbling or false)
                Gui.TackleTacklingLabel.Text="isTackling: "..tostring(owner and IsSpecificTackle(owner) or false)
                Gui.PingLabel.Text=string.format("Ping: %dms",_mfloor(AutoTackleStatus.Ping*1000+0.5))
            end
            if owner then
                local ownerRoot=owner.Character and owner.Character:FindFirstChild("HumanoidRootPart")
                UpdatePredictionLabel(ownerRoot,owner)
                UpdatePredictionBox(ownerRoot,owner)
            end
            if distance<=AutoTackleConfig.TackleDistance then
                PerformTackle(ball,owner)
                if Gui then Gui.EagleEyeLabel.Text="Instant Tackle" end; return
            end
            if owner and IsPowerShooting(owner) then
                PerformTackle(ball,owner)
                if Gui then Gui.EagleEyeLabel.Text="PowerShooting: Tackling!" end; return
            end
            CurrentTargetOwner=owner
            if AutoTackleConfig.Mode=="ManualTackle" then
                if Gui then
                    Gui.EagleEyeLabel.Text="ManualTackle: Ready"
                    Gui.ManualTackleLabel.Text="ManualTackle: READY"
                    Gui.ManualTackleLabel.Color=Color3.fromRGB(0,255,0)
                end; return
            end
            if not owner then return end
            local state=DribbleStates[owner] or {IsDribbling=false,LastDribbleEnd=0,IsProcessingDelay=false}
            local isDribbling=state.IsDribbling
            local inCooldownList=DribbleCooldownList[owner]~=nil
            if AutoTackleConfig.Mode=="OnlyDribble" then
                if inCooldownList then
                    PerformTackle(ball,owner)
                    if Gui then Gui.EagleEyeLabel.Text="OnlyDribble: Tackling!" end
                elseif isDribbling then
                    if Gui then
                        Gui.EagleEyeLabel.Text="OnlyDribble: Dribbling..."
                        Gui.TackleWaitLabel.Text=string.format("DDelay: %.2f",AutoTackleConfig.DribbleDelayTime)
                    end
                elseif state.IsProcessingDelay then
                    local rem=AutoTackleConfig.DribbleDelayTime-(_tick()-state.LastDribbleEnd)
                    if Gui then
                        Gui.EagleEyeLabel.Text="OnlyDribble: DribDelay"
                        Gui.TackleWaitLabel.Text=string.format("Wait: %.2f",rem)
                    end
                else
                    if Gui then
                        Gui.EagleEyeLabel.Text="OnlyDribble: Waiting dribble"
                        Gui.TackleWaitLabel.Text="Wait: -"
                    end
                end
            elseif AutoTackleConfig.Mode=="EagleEye" then
                local now=_tick()
                if isDribbling then
                    EagleEyeTimers[owner]=nil
                    if Gui then
                        Gui.TackleWaitLabel.Text="Wait: DRIBBLE"
                        Gui.EagleEyeLabel.Text="EagleEye: Dribbling (reset)"
                    end
                elseif state.IsProcessingDelay then
                    EagleEyeTimers[owner]=nil
                    local rem=AutoTackleConfig.DribbleDelayTime-(now-state.LastDribbleEnd)
                    if Gui then
                        Gui.TackleWaitLabel.Text=string.format("DDelay: %.2f",rem)
                        Gui.EagleEyeLabel.Text="EagleEye: DribbleDelay"
                    end
                elseif inCooldownList then
                    PerformTackle(ball,owner); EagleEyeTimers[owner]=nil
                    if Gui then Gui.EagleEyeLabel.Text="EagleEye: Post-Dribble Tackle!" end
                else
                    if not EagleEyeTimers[owner] then
                        local wt=AutoTackleConfig.EagleEyeMinDelay+math.random()*(AutoTackleConfig.EagleEyeMaxDelay-AutoTackleConfig.EagleEyeMinDelay)
                        EagleEyeTimers[owner]={startTime=now,waitTime=wt}
                    end
                    local timer=EagleEyeTimers[owner]
                    local elapsed=now-timer.startTime
                    if elapsed>=timer.waitTime then
                        PerformTackle(ball,owner); EagleEyeTimers[owner]=nil
                        if Gui then Gui.EagleEyeLabel.Text="EagleEye: Tackling!" end
                    else
                        if Gui then
                            Gui.TackleWaitLabel.Text=string.format("Wait: %.2f",timer.waitTime-elapsed)
                            Gui.EagleEyeLabel.Text="EagleEye: Waiting"
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
    for _,circle in pairs(AutoTackleStatus.TargetCircles) do
        for _,l in ipairs(circle) do l:Remove() end
    end
    AutoTackleStatus.TargetCircles={}
    if notify then notify("AutoTackle","Stopped",true) end
end

-- ============================================================
-- AUTODRIBBLE v4.1
-- Логика Free (единственный режим):
--   СТАДИЯ 0: враг <= PointBlankRadius (8 studs) И IsTackling → deke немедленно
--   СТАДИЯ 1: враг в DribbleActivationDistance и IsTackling → deke
--             (RequireTackleAnim=false → без проверки анимации)
--   СТАДИЯ 2: средняя дистанция → проверка угла + скорость
-- ============================================================
local _cachedAngleDeg  = -1
local _cachedCosThresh = 0
local function GetCosThreshold()
    if AutoDribbleConfig.MinAngleForDribble~=_cachedAngleDeg then
        _cachedAngleDeg=AutoDribbleConfig.MinAngleForDribble
        _cachedCosThresh=_mcos(_mrad(_cachedAngleDeg))
    end
    return _cachedCosThresh
end

local function ShouldDribbleNow(specificTarget, tacklerData)
    if not specificTarget or not tacklerData then return false end
    local tacklerRoot=tacklerData.RootPart
    if not tacklerRoot then return false end

    local serverCF    = GetMyServerCFrame()
    local myServerPos = serverCF.Position
    local velocity    = tacklerData.Velocity
    local vx,vz       = velocity.X, velocity.Z
    local speed2D     = _msqrt(vx*vx+vz*vz)
    local tp          = tacklerRoot.Position
    local toPing      = AutoTackleStatus.Ping
    local predTx      = tp.X + vx*toPing*1.5
    local predTz      = tp.Z + vz*toPing*1.5
    local toMeX       = myServerPos.X - predTx
    local toMeZ       = myServerPos.Z - predTz
    local distFlat    = _msqrt(toMeX*toMeX + toMeZ*toMeZ)

    if distFlat > AutoDribbleConfig.MaxDribbleDistance then
        if Gui then Gui.AngleLabel.Text=string.format("FAR d=%.1f",distFlat) end
        return false
    end

    -- [СТАДИЯ 0] PointBlank: вплотную + IsTackling → немедленно
    if distFlat <= AutoDribbleConfig.PointBlankRadius then
        local isTackling = tacklerData.IsTackling
        if isTackling then
            if Gui then Gui.AngleLabel.Text=string.format("⚡ POINT BLANK TACKLE d=%.1f",distFlat) end
            return true
        end
        -- Без IsTackling в pointblank — проверяем RequireTackleAnim
        if not AutoDribbleConfig.RequireTackleAnim then
            -- Реагируем если враг движется к нам (approach > 0)
            if speed2D > 1.5 then
                local invD=1/_mmax(distFlat,0.001)
                local approach=vx*(toMeX*invD)+vz*(toMeZ*invD)
                if approach > 0 then
                    if Gui then Gui.AngleLabel.Text=string.format("⚡ PB approach=%.1f",approach) end
                    return true
                end
            end
        end
        if Gui then Gui.AngleLabel.Text=string.format("PB no_tackle d=%.1f",distFlat) end
        return false
    end

    -- [СТАДИЯ 1] Зона активации
    if distFlat <= AutoDribbleConfig.DribbleActivationDistance then
        local isTackling = tacklerData.IsTackling
        -- RequireTackleAnim: если включён — нужна анимация такла
        if AutoDribbleConfig.RequireTackleAnim and not isTackling then
            if Gui then Gui.AngleLabel.Text=string.format("CLOSE need_tackle d=%.1f",distFlat) end
            return false
        end
        -- RequireTackleAnim выключен: реагируем при IsTackling ИЛИ если враг летит на нас
        if isTackling then
            if Gui then Gui.AngleLabel.Text=string.format("⚡ TACKLE d=%.1f",distFlat) end
            return true
        end
        -- Нет анимации такла, RequireTackleAnim=false: проверяем скорость + угол
        if speed2D < 2.0 then
            if Gui then Gui.AngleLabel.Text=string.format("CLOSE slow v=%.1f",speed2D) end
            return false
        end
        local invD  = 1/_mmax(distFlat,0.001)
        local toMeUX= toMeX*invD; local toMeUZ=toMeZ*invD
        local invS  = 1/_mmax(speed2D,0.001)
        local dot   = _mclamp((vx*invS)*toMeUX+(vz*invS)*toMeUZ,-1,1)
        if dot < GetCosThreshold() then
            if Gui then
                Gui.AngleLabel.Text=string.format("CLOSE bad_angle %.0f°",math.deg(math.acos(dot)))
            end
            return false
        end
        if Gui then Gui.AngleLabel.Text=string.format("CLOSE A=%.0f° d=%.1f",math.deg(math.acos(dot)),distFlat) end
        return true
    end

    -- [СТАДИЯ 2] Средняя дистанция — угол + скорость
    if speed2D < 2.0 then
        if Gui then Gui.AngleLabel.Text=string.format("v=%.1f (slow)",speed2D) end
        return false
    end
    local invD  = 1/_mmax(distFlat,0.001)
    local toMeUX= toMeX*invD; local toMeUZ=toMeZ*invD
    local invS  = 1/_mmax(speed2D,0.001)
    local dot   = _mclamp((vx*invS)*toMeUX+(vz*invS)*toMeUZ,-1,1)
    if Gui then
        Gui.AngleLabel.Text=string.format("A=%.0f° v=%.1f d=%.1f",
            math.deg(math.acos(dot)),speed2D,distFlat)
    end
    if dot < GetCosThreshold() then return false end
    local approach=vx*toMeUX+vz*toMeUZ
    local mvx,_,mvz=GetMyVelocityFromHistory()
    local myApproach=-(mvx*toMeUX+mvz*toMeUZ)
    local relSpeed=approach+_mmax(myApproach,0)
    if relSpeed < 0.5 then return false end
    local ttc=distFlat/_mmax(relSpeed,1)
    if Gui then
        Gui.AngleLabel.Text=Gui.AngleLabel.Text..string.format(" t=%.2f",ttc)
    end
    return ttc < 0.4
end

local function PerformDribble()
    local now=_tick()
    if now-AutoDribbleStatus.LastDribbleTime<0.02 then return end
    local b=Workspace:FindFirstChild(LocalPlayer.Name) and Workspace[LocalPlayer.Name]:FindFirstChild("Bools")
    if not b or b.dribbleDebounce.Value then return end
    pcall(function() ActionRemote:FireServer("Deke") end)
    AutoDribbleStatus.LastDribbleTime=now
    if Gui and AutoDribbleConfig.Enabled then
        Gui.DribbleStatusLabel.Text="Dribble: Cooldown"
        Gui.DribbleStatusLabel.Color=Color3.fromRGB(255,0,0)
        Gui.AutoDribbleLabel.Text="AutoDribble: DEKE!"
    end
end

-- Кэш дриббла
local _dc={result=false,lastPlayer=nil,lastTacklerPos=Vector3.zero,
    lastMyPos=Vector3.zero,lastIsTackling=false,lastCalcTime=0}

local function IsDribbleCacheDirty(sp,td)
    if not sp or not td then return true end
    local now=_tick()
    if now-_dc.lastCalcTime>0.008 then return true end
    if _dc.lastPlayer~=sp then return true end
    if _dc.lastIsTackling~=td.IsTackling then return true end
    local root=td.RootPart
    if root then
        local cp=_dc.lastTacklerPos; local rp=root.Position
        local dx=rp.X-cp.X; local dz=rp.Z-cp.Z
        if _msqrt(dx*dx+dz*dz)>0.15 then return true end
    end
    local mp=_dc.lastMyPos; local hp=HumanoidRootPart.Position
    if _msqrt((hp.X-mp.X)^2+(hp.Z-mp.Z)^2)>0.15 then return true end
    return false
end

local AutoDribble={}

AutoDribble.Start=function()
    if AutoDribbleStatus.Running then return end
    AutoDribbleStatus.Running=true

    AutoDribbleStatus.HeartbeatConnection=RunService.Heartbeat:Connect(function()
        if not AutoDribbleConfig.Enabled then return end
        pcall(function()
            UpdatePing(); UpdateDribbleStates(); PrecomputePlayers()
            UpdateTargetCircles(); RecordMyPosition()
            IsTypingInChat=CheckIfTypingInChat()
            UpdateServerPosBox()
        end)
    end)

    if not Gui then SetupGUI() end

    local function DribbleLoop()
        if not AutoDribbleConfig.Enabled then CleanupDebugText(); UpdateDebugVisibility(); return end
        if not HasBall or not CanDribbleNow then
            if Gui then Gui.AutoDribbleLabel.Text="AutoDribble: Idle" end; return
        end
        local specificTarget,minDist,targetCount,nearestTacklerData=nil,math.huge,0,nil
        for player,data in pairs(PrecomputedPlayers) do
            if data.IsValid then
                -- Считаем цели: с IsTackling или (RequireTackleAnim=false и всех)
                local counts = data.IsTackling or not AutoDribbleConfig.RequireTackleAnim
                if counts then
                    targetCount+=1
                    if data.Distance<minDist then
                        minDist=data.Distance; specificTarget=player; nearestTacklerData=data
                    end
                end
            end
        end
        if Gui then
            Gui.DribbleTargetLabel.Text="Targets: "..targetCount
            Gui.DribbleTacklingLabel.Text=specificTarget
                and string.format("Nearest: %.1f st",minDist) or "Nearest: None"
        end
        if not specificTarget or not nearestTacklerData then
            if Gui then Gui.AutoDribbleLabel.Text="AutoDribble: Idle" end; return
        end
        local fire
        if IsDribbleCacheDirty(specificTarget,nearestTacklerData) then
            fire=ShouldDribbleNow(specificTarget,nearestTacklerData)
            _dc.result=fire; _dc.lastCalcTime=_tick()
            _dc.lastPlayer=specificTarget
            _dc.lastIsTackling=nearestTacklerData and nearestTacklerData.IsTackling or false
            if nearestTacklerData and nearestTacklerData.RootPart then
                _dc.lastTacklerPos=nearestTacklerData.RootPart.Position
            end
            _dc.lastMyPos=HumanoidRootPart.Position
        else
            fire=_dc.result
        end
        if fire then PerformDribble()
        else if Gui then Gui.AutoDribbleLabel.Text="AutoDribble: Waiting" end end
    end

    AutoDribbleStatus.Connection=RunService.Heartbeat:Connect(function()
        pcall(DribbleLoop)
    end)

    UpdateDebugVisibility()
    if notify then notify("AutoDribble","Started",true) end
end

AutoDribble.Stop=function()
    if AutoDribbleStatus.Connection then AutoDribbleStatus.Connection:Disconnect(); AutoDribbleStatus.Connection=nil end
    if AutoDribbleStatus.HeartbeatConnection then AutoDribbleStatus.HeartbeatConnection:Disconnect(); AutoDribbleStatus.HeartbeatConnection=nil end
    AutoDribbleStatus.Running=false
    HideBoxLines(Gui and Gui.ServerPosBoxLines or nil)
    HideBoxLines(Gui and Gui.PredictionBoxLines or nil)
    CleanupDebugText(); UpdateDebugVisibility()
    if notify then notify("AutoDribble","Stopped",true) end
end

-- ============================================================
-- UI
-- ============================================================
local uiElements={}
local function SetupUI(UI)
    if UI.Sections.AutoTackle then
        UI.Sections.AutoTackle:Header({Name="AutoTackle"})
        UI.Sections.AutoTackle:Divider()
        uiElements.AutoTackleEnabled=UI.Sections.AutoTackle:Toggle({
            Name="Enabled",Default=AutoTackleConfig.Enabled,
            Callback=function(v)
                AutoTackleConfig.Enabled=v
                if v then AutoTackle.Start() else AutoTackle.Stop() end
                UpdateDebugVisibility()
            end},"AutoTackleEnabled")
        uiElements.AutoTackleMode=UI.Sections.AutoTackle:Dropdown({
            Name="Mode",Default=AutoTackleConfig.Mode,
            Options={"OnlyDribble","EagleEye","ManualTackle"},
            Callback=function(v)
                AutoTackleConfig.Mode=v
                if Gui then Gui.ModeLabel.Text="Mode: "..v end
            end},"AutoTackleMode")
        UI.Sections.AutoTackle:Divider()
        UI.Sections.AutoTackle:Slider({Name="Max Distance",Minimum=5,Maximum=50,Default=AutoTackleConfig.MaxDistance,Precision=1,Callback=function(v) AutoTackleConfig.MaxDistance=v end},"AutoTackleMaxDistance")
        UI.Sections.AutoTackle:Slider({Name="Instant Tackle Distance",Minimum=0,Maximum=20,Default=AutoTackleConfig.TackleDistance,Precision=1,Callback=function(v) AutoTackleConfig.TackleDistance=v end},"AutoTackleTackleDistance")
        UI.Sections.AutoTackle:Slider({Name="Tackle Speed",Minimum=10,Maximum=100,Default=AutoTackleConfig.TackleSpeed,Precision=1,Callback=function(v) AutoTackleConfig.TackleSpeed=v end},"AutoTackleTackleSpeed")
        UI.Sections.AutoTackle:Divider()
        UI.Sections.AutoTackle:Toggle({Name="Only Player",Default=AutoTackleConfig.OnlyPlayer,Callback=function(v) AutoTackleConfig.OnlyPlayer=v end},"AutoTackleOnlyPlayer")
        UI.Sections.AutoTackle:Dropdown({Name="Rotation Method",Default=AutoTackleConfig.RotationMethod,Options={"Snap","Legit","Always","None"},Callback=function(v) AutoTackleConfig.RotationMethod=v end},"AutoTackleRotationMethod")
        UI.Sections.AutoTackle:Toggle({Name="Show Prediction Box",Default=AutoTackleConfig.ShowPredictionBox,Callback=function(v)
            AutoTackleConfig.ShowPredictionBox=v
            if not v then HideBoxLines(Gui and Gui.PredictionBoxLines or nil) end
            UpdateDebugVisibility()
        end},"AutoTackleShowPredictionBox")
        UI.Sections.AutoTackle:Divider()
        UI.Sections.AutoTackle:Slider({Name="Dribble Delay",Minimum=0.0,Maximum=2.0,Default=AutoTackleConfig.DribbleDelayTime,Precision=2,Callback=function(v) AutoTackleConfig.DribbleDelayTime=v end},"AutoTackleDribbleDelay")
        UI.Sections.AutoTackle:Slider({Name="EagleEye Min Delay",Minimum=0.0,Maximum=2.0,Default=AutoTackleConfig.EagleEyeMinDelay,Precision=2,Callback=function(v) AutoTackleConfig.EagleEyeMinDelay=v end},"AutoTackleEEMin")
        UI.Sections.AutoTackle:Slider({Name="EagleEye Max Delay",Minimum=0.0,Maximum=2.0,Default=AutoTackleConfig.EagleEyeMaxDelay,Precision=2,Callback=function(v) AutoTackleConfig.EagleEyeMaxDelay=v end},"AutoTackleEEMax")
        UI.Sections.AutoTackle:Divider()
        UI.Sections.AutoTackle:Toggle({Name="Manual Tackle Enabled",Default=AutoTackleConfig.ManualTackleEnabled,Callback=function(v) AutoTackleConfig.ManualTackleEnabled=v end},"AutoTackleManualEnabled")
        UI.Sections.AutoTackle:Keybind({Name="Manual Tackle Key",Default=AutoTackleConfig.ManualTackleKeybind,
            Callback=function(v) if AutoTackleConfig.Enabled and AutoTackleConfig.ManualTackleEnabled then ManualTackleAction() end end,
            onBinded=function(v) AutoTackleConfig.ManualTackleKeybind=v end},"AutoTackleManualKeybind")
    end

    if UI.Sections.AutoDribble then
        UI.Sections.AutoDribble:Header({Name="AutoDribble"})
        UI.Sections.AutoDribble:Divider()
        UI.Sections.AutoDribble:Toggle({Name="Enabled",Default=AutoDribbleConfig.Enabled,Callback=function(v)
            AutoDribbleConfig.Enabled=v
            if v then AutoDribble.Start() else AutoDribble.Stop() end
            UpdateDebugVisibility()
        end},"AutoDribbleEnabled")
        UI.Sections.AutoDribble:Divider()
        UI.Sections.AutoDribble:Slider({Name="Max Distance",Minimum=10,Maximum=50,Default=AutoDribbleConfig.MaxDribbleDistance,Precision=1,Callback=function(v) AutoDribbleConfig.MaxDribbleDistance=v end},"AutoDribbleMaxDist")
        UI.Sections.AutoDribble:Slider({Name="Activation Distance",Minimum=5,Maximum=30,Default=AutoDribbleConfig.DribbleActivationDistance,Precision=1,Callback=function(v) AutoDribbleConfig.DribbleActivationDistance=v end},"AutoDribbleActDist")
        UI.Sections.AutoDribble:Slider({Name="Max Attack Angle",Minimum=10,Maximum=90,Default=AutoDribbleConfig.MinAngleForDribble,Precision=0,Callback=function(v) AutoDribbleConfig.MinAngleForDribble=v; _cachedAngleDeg=-1 end},"AutoDribbleAngle")
        UI.Sections.AutoDribble:Slider({Name="Point Blank Radius",Minimum=3,Maximum=15,Default=AutoDribbleConfig.PointBlankRadius,Precision=1,Callback=function(v) AutoDribbleConfig.PointBlankRadius=v end},"AutoDribblePBRadius")
        -- RequireTackleAnim toggle (по умолчанию false)
        UI.Sections.AutoDribble:Toggle({Name="Require Tackle Anim",Default=AutoDribbleConfig.RequireTackleAnim,Callback=function(v) AutoDribbleConfig.RequireTackleAnim=v end},"AutoDribbleRequireTackle")
        UI.Sections.AutoDribble:Toggle({Name="Show Server Position Box",Default=AutoDribbleConfig.ShowServerPos,Callback=function(v)
            AutoDribbleConfig.ShowServerPos=v
            if not v then HideBoxLines(Gui and Gui.ServerPosBoxLines or nil) end
            UpdateDebugVisibility()
        end},"AutoDribbleShowServer")
        UI.Sections.AutoDribble:Divider()
    end

    if UI.Sections.Debug then
        UI.Sections.Debug:Header({Name="Debug"})
        UI.Sections.Debug:SubLabel({Text="* Only for AutoDribble/AutoTackle"})
        UI.Sections.Debug:Divider()
        UI.Sections.Debug:Toggle({Name="Debug Text",Default=DebugConfig.Enabled,Callback=function(v) DebugConfig.Enabled=v; UpdateDebugVisibility() end},"DebugEnabled")
        UI.Sections.Debug:Toggle({Name="Move Debug Text",Default=DebugConfig.MoveEnabled,Callback=function(v) DebugConfig.MoveEnabled=v; if v then SetupDebugMovement() end end},"DebugMoveEnabled")
    end
end

-- ============================================================
-- MODULE
-- ============================================================
local AutoDribbleTackleModule={}

function AutoDribbleTackleModule.Init(UI, coreParam, notifyFunc)
    core=coreParam; Services=core.Services; PlayerData=core.PlayerData; notify=notifyFunc
    LocalPlayerObj=PlayerData.LocalPlayer
    SetupUI(UI)

    LocalPlayerObj.CharacterAdded:Connect(function(newChar)
        task.wait(1)
        Character=newChar
        Humanoid=newChar:WaitForChild("Humanoid")
        HumanoidRootPart=newChar:WaitForChild("HumanoidRootPart")
        DribbleStates={}; TackleStates={}; PrecomputedPlayers={}
        DribbleCooldownList={}; EagleEyeTimers={}
        AutoTackleStatus.TargetPositionHistory={}
        AutoTackleStatus.TargetCircles={}
        MyPositionHistory={}; PlayerBoxCache={}
        MyBoxDimensions=nil  -- сбрасываем кэш размеров своего тела
        _cachedAngleDeg=-1; CurrentTargetOwner=nil
        if AutoTackleConfig.Enabled and not AutoTackleStatus.Running then AutoTackle.Start() end
        if AutoDribbleConfig.Enabled and not AutoDribbleStatus.Running then AutoDribble.Start() end
    end)
end

function AutoDribbleTackleModule:Destroy()
    AutoTackle.Stop(); AutoDribble.Stop()
    if Gui then
        RemoveBoxLines(Gui.ServerPosBoxLines)
        RemoveBoxLines(Gui.PredictionBoxLines)
    end
end

return AutoDribbleTackleModule
