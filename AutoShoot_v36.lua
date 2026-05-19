-- [v36.1] AUTO SHOOT + AUTO PICKUP — Smart GK-aware, MacLib mobile-keybind fix
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Camera = Workspace.CurrentCamera
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
local Character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
local HumanoidRootPart = Character:WaitForChild("HumanoidRootPart")
local BallAttachment = Character:WaitForChild("ball")
local Humanoid = Character:WaitForChild("Humanoid")

local Shooter = ReplicatedStorage.Remotes:WaitForChild("ShootTheBaII")
local PickupRemote
for _, r in ReplicatedStorage.Remotes:GetChildren() do
    if r:IsA("RemoteEvent") and r:GetAttribute("Attribute") then
        PickupRemote = r
        break
    end
end

local Animations = ReplicatedStorage:WaitForChild("Animations")
local RShootAnim = Humanoid:LoadAnimation(Animations:WaitForChild("RShoot"))
RShootAnim.Priority = Enum.AnimationPriority.Action4
local IsAnimating = false
local AnimationHoldTime = 0.6

-- ============================================================
-- КОНФИГ
-- ============================================================
local AutoShootEnabled = false
local AutoShootLegit = true
local AutoShootManualShot = true
local AutoShootShootKey = Enum.KeyCode.G
local AutoShootMode = "Packet" -- Packet / Hook
local AutoShootMaxDistance = 200
local AutoShootDebugText = false
local AutoShootSpoofPowerEnabled = false
local AutoShootSpoofPowerType = "math.huge"

-- Физика
local GRAVITY = 196.2
local AutoShootBallSpeed = 400
local AutoShootDragComp = 1.05
local FIXED_POWER = 5.0
local GK_REACH_RADIUS = 5.0
local GK_REACH_SPEED = 12.0
local PAST_GOAL_BASE = 45
local PAST_GOAL_CLOSE = 70
local SPIN_TRICK_DIST = 72
local SPIN_SERVER_MIN_DIST = 130
local AutoShootCurveDistanceLimit = 300
local RICOCHET_MIN_DIST = 72
local RICOCHET_MAX_DIST = 175
local SPIN_CROSS_BLOCK_X = 0.18
local AutoShootDerivMult = 4.5
local BALL_RADIUS = 1.168
local INSET = BALL_RADIUS + 0.6
local Y_TOP_TARGET = BALL_RADIUS + 0.28
local Y_TOP_SAFETY = BALL_RADIUS + 0.48
local Y_BOT_INSET = 0.22
local GOAL_DEPTH_MIN = 1.0
local GOAL_DEPTH_MAX = 1.00
local VIS_CURL_MAX = 1.45
local VIS_CURL_PEAK = 0.38
local VIS_FALL_EARLY_BIAS = 0.92

-- ============================================================
-- STATUS
-- ============================================================
local AutoShootStatus = {
    Running = false,
    Connection = nil,
    RenderConnection = nil,
    InputConnection = nil,
}
local AutoPickupEnabled = true
local AutoPickupDist = 180
local AutoPickupSpoofValue = 2.8
local AutoPickupStatus = { Running = false, Connection = nil }

local ShowTrajectory = true
local Show3DBoxes = true
local VisualsOnlyWithBall = true
local TrajectoryColor = Color3.fromRGB(255, 165, 0)
local StartCircleColor = Color3.fromRGB(255, 210, 80)
local TargetCubeColor = Color3.fromRGB(0, 255, 0)
local GoalCubeColor = Color3.fromRGB(255, 0, 0)
local NoSpinCubeColor = Color3.fromRGB(0, 200, 255)
local PeakCubeColor = Color3.fromRGB(255, 255, 0)
local TrajectoryAlpha = 0.55
local BoxAlpha = 0.90
local TrajectoryThickness = 1.6
local BoxThicknessMain = 2.2
local BoxThicknessThin = 1.2
local StartCircleRadius = 4
local StartCircleThickness = 1.5
local StartCircleAlpha = 0.85

-- ============================================================
-- GUI
-- ============================================================
local Gui = nil
local function SetupGUI()
    Gui = {
        Status = Drawing.new("Text"),
        Dist = Drawing.new("Text"),
        Target = Drawing.new("Text"),
        Power = Drawing.new("Text"),
        Spin = Drawing.new("Text"),
        GK = Drawing.new("Text"),
        Debug = Drawing.new("Text"),
        Mode = Drawing.new("Text"),
        Goal = Drawing.new("Text"),
    }

    local s = Camera.ViewportSize
    local cx, y = s.X / 2, s.Y * 0.46
    for i, v in ipairs({Gui.Status, Gui.Dist, Gui.Target, Gui.Power, Gui.Spin, Gui.GK, Gui.Debug, Gui.Mode, Gui.Goal}) do
        v.Size = 18
        v.Color = Color3.fromRGB(255, 255, 255)
        v.Outline = true
        v.Center = true
        v.Position = Vector2.new(cx, y + (i - 1) * 20)
        v.Visible = AutoShootDebugText
    end

    Gui.Status.Text = "v36.1: Ready"
end

local function ToggleDebugText(value)
    if not Gui then
        return
    end
    for _, v in pairs(Gui) do
        v.Visible = value
    end
end

-- ============================================================
-- 3D КУБЫ
-- ============================================================
local TargetCube, GoalCube, NoSpinCube = {}, {}, {}
local TRAJ_SEGMENTS = 20
local TrajectoryLines = {}
local PeakCube = {}
local StartCircle = {}

local function ApplyVisualStyles()
    for _, l in ipairs(TrajectoryLines) do
        l.Color = TrajectoryColor
        l.Thickness = TrajectoryThickness
        l.Transparency = TrajectoryAlpha
        l.ZIndex = 999
        l.Visible = false
    end

    local function SC(cube, color, th)
        for _, l in ipairs(cube) do
            l.Color = color
            l.Thickness = th or BoxThicknessThin
            l.Transparency = BoxAlpha
            l.ZIndex = 1000
            l.Visible = false
        end
    end

    SC(TargetCube, TargetCubeColor, BoxThicknessMain)
    SC(GoalCube, GoalCubeColor, BoxThicknessMain)
    SC(NoSpinCube, NoSpinCubeColor, BoxThicknessThin)
    SC(PeakCube, PeakCubeColor, math.max(BoxThicknessThin + 1, 3))

    for _, l in ipairs(StartCircle) do
        l.Color = StartCircleColor
        l.Thickness = StartCircleThickness
        l.Transparency = StartCircleAlpha
        l.ZIndex = 1000
        l.Visible = false
    end
end

local function InitializeCubes()
    for i = 1, 12 do
        if TargetCube[i] and TargetCube[i].Remove then TargetCube[i]:Remove() end
        if GoalCube[i] and GoalCube[i].Remove then GoalCube[i]:Remove() end
        if NoSpinCube[i] and NoSpinCube[i].Remove then NoSpinCube[i]:Remove() end
        if PeakCube[i] and PeakCube[i].Remove then PeakCube[i]:Remove() end
        TargetCube[i] = Drawing.new("Line")
        GoalCube[i] = Drawing.new("Line")
        NoSpinCube[i] = Drawing.new("Line")
        PeakCube[i] = Drawing.new("Line")
    end

    for i = 1, TRAJ_SEGMENTS do
        if TrajectoryLines[i] and TrajectoryLines[i].Remove then TrajectoryLines[i]:Remove() end
        TrajectoryLines[i] = Drawing.new("Line")
    end

    for i = 1, 28 do
        if StartCircle[i] and StartCircle[i].Remove then StartCircle[i]:Remove() end
        StartCircle[i] = Drawing.new("Line")
    end

    ApplyVisualStyles()
end

local function DrawTrajectory(startPos, peakPos, endPos, peakFrac, spinStr)
    if not ShowTrajectory or not peakPos or not endPos then
        for _, l in ipairs(TrajectoryLines) do l.Visible = false end
        for _, l in ipairs(StartCircle) do l.Visible = false end
        return
    end

    local fwdH = Vector3.new(endPos.X - startPos.X, 0, endPos.Z - startPos.Z)
    if fwdH.Magnitude < 0.1 then
        fwdH = Vector3.new(1, 0, 0)
    end
    fwdH = fwdH.Unit
    local right = Vector3.new(-fwdH.Z, 0, fwdH.X)

    local fwdTotal = (Vector3.new(endPos.X - startPos.X, 0, endPos.Z - startPos.Z)).Magnitude
    local peakHoriz = (Vector3.new(peakPos.X - startPos.X, 0, peakPos.Z - startPos.Z)).Magnitude
    local t_peak = (fwdTotal > 0.1) and math.clamp(peakHoriz / fwdTotal, 0.36, 0.44) or 0.40
    local neutralXZ = startPos + fwdH * peakHoriz
    local neutralPk = Vector3.new(neutralXZ.X, peakPos.Y, neutralXZ.Z)

    local f = t_peak
    local Pc = (neutralPk - startPos * ((1 - f) ^ 2) - endPos * (f ^ 2)) / math.max(2 * f * (1 - f), 1e-4)

    local spinSign = (spinStr == "Right") and -1 or (spinStr == "Left") and 1 or 0
    local dist3D = (endPos - startPos).Magnitude
    local curlAmp = spinSign * math.min(0.9 + dist3D / 160, 2.2)

    local function point(t)
        local mt = 1 - t
        local arc = startPos * (mt * mt) + Pc * (2 * mt * t) + endPos * (t * t)
        local curl = right * curlAmp * math.sin(math.pi * t)
        return arc + curl
    end

    for i = 1, TRAJ_SEGMENTS do
        local t0 = (i - 1) / TRAJ_SEGMENTS
        local t1 = i / TRAJ_SEGMENTS
        local p0 = point(t0)
        local p1 = point(t1)
        local s0, v0 = Camera:WorldToViewportPoint(p0)
        local s1, v1 = Camera:WorldToViewportPoint(p1)
        local l = TrajectoryLines[i]
        if v0 and v1 and s0.Z > 0 and s1.Z > 0 then
            l.From = Vector2.new(s0.X, s0.Y)
            l.To = Vector2.new(s1.X, s1.Y)
            l.Visible = true
        else
            l.Visible = false
        end
    end

    local ringR = math.max(0.9, 0.70 + dist3D * 0.006)
    local prev2D, prevOk = nil, false
    for i = 1, #StartCircle do
        local a = ((i - 1) / #StartCircle) * math.pi * 2
        local p = startPos + Vector3.new(math.cos(a) * ringR, 0, math.sin(a) * ringR)
        local s, v = Camera:WorldToViewportPoint(p)
        local ok = v and s.Z > 0
        if i > 1 and prevOk and ok then
            local l = StartCircle[i - 1]
            l.From = prev2D
            l.To = Vector2.new(s.X, s.Y)
            l.Visible = true
        elseif i > 1 then
            StartCircle[i - 1].Visible = false
        end
        prev2D, prevOk = Vector2.new(s.X, s.Y), ok
    end

    local firstP = startPos + Vector3.new(ringR, 0, 0)
    local fs, fv = Camera:WorldToViewportPoint(firstP)
    if prevOk and fv and fs.Z > 0 then
        local l = StartCircle[#StartCircle]
        l.From = prev2D
        l.To = Vector2.new(fs.X, fs.Y)
        l.Visible = true
    else
        StartCircle[#StartCircle].Visible = false
    end
end

local function DrawOrientedCube(cube, cframe, size)
    if not cframe or not size then
        for _, l in ipairs(cube) do
            l.Visible = false
        end
        return
    end

    pcall(function()
        local h = size / 2
        local corners = {
            cframe * Vector3.new(-h.X, -h.Y, -h.Z), cframe * Vector3.new(h.X, -h.Y, -h.Z),
            cframe * Vector3.new(h.X, h.Y, -h.Z), cframe * Vector3.new(-h.X, h.Y, -h.Z),
            cframe * Vector3.new(-h.X, -h.Y, h.Z), cframe * Vector3.new(h.X, -h.Y, h.Z),
            cframe * Vector3.new(h.X, h.Y, h.Z), cframe * Vector3.new(-h.X, h.Y, h.Z),
        }
        local edges = {{1,2},{2,3},{3,4},{4,1},{5,6},{6,7},{7,8},{8,5},{1,5},{2,6},{3,7},{4,8}}
        for i, e in ipairs(edges) do
            local a, b = corners[e[1]], corners[e[2]]
            local as, av = Camera:WorldToViewportPoint(a)
            local bs, bv = Camera:WorldToViewportPoint(b)
            local l = cube[i]
            if av and bv and as.Z > 0 and bs.Z > 0 then
                l.From = Vector2.new(as.X, as.Y)
                l.To = Vector2.new(bs.X, bs.Y)
                l.Visible = true
            else
                l.Visible = false
            end
        end
    end)
end

-- ============================================================
-- ВОРОТА / МЯЧ
-- ============================================================
local function GetBallStartPos()
    local ballPart = Character:FindFirstChild("ball")
    if ballPart then
        if ballPart:IsA("BasePart") then return ballPart.Position end
        if ballPart:IsA("Attachment") then return ballPart.WorldPosition end
    end
    return HumanoidRootPart.Position
end

local function GetVisualStartPos()
    local hrp = HumanoidRootPart
    if not hrp then return GetBallStartPos() end
    local rootPos = hrp.Position
    local footY = rootPos.Y - (Humanoid and (Humanoid.HipHeight + hrp.Size.Y * 0.5) or (hrp.Size.Y * 0.9))
    local ballPos = GetBallStartPos()
    local flatToBall = Vector3.new(ballPos.X - rootPos.X, 0, ballPos.Z - rootPos.Z)
    local flatMag = flatToBall.Magnitude
    local lateral = (flatMag > 0.01) and (flatToBall.Unit * math.min(flatMag, 1.8)) or Vector3.zero
    return Vector3.new(rootPos.X + lateral.X, footY + 0.15, rootPos.Z + lateral.Z)
end

local GoalCFrame, GoalWidth, GoalHeight, GoalFloorY

local function IsLocalGoalkeeper()
    local wModel = Workspace:FindFirstChild(LocalPlayer.Name)
    local hitbox = wModel and wModel:FindFirstChild("Hitbox")
    return hitbox and hitbox:IsA("BasePart") or false
end

local function UpdateGoal()
    local myTeam, enemyGoalName = (function()
        local stats = Workspace:FindFirstChild("PlayerStats")
        if not stats then return nil, nil end
        if stats:FindFirstChild("Away") and stats.Away:FindFirstChild(LocalPlayer.Name) then
            return "Away", "HomeGoal"
        elseif stats:FindFirstChild("Home") and stats.Home:FindFirstChild(LocalPlayer.Name) then
            return "Home", "AwayGoal"
        end
        return nil, nil
    end)()

    if not enemyGoalName then return nil end
    local goalFolder = Workspace:FindFirstChild(enemyGoalName)
    if not goalFolder then return nil end
    local frame = goalFolder:FindFirstChild("Frame")
    if not frame then return nil end

    local posts, crossbar = {}, nil
    for _, part in ipairs(frame:GetChildren()) do
        if part:IsA("BasePart") then
            if part.Name == "Crossbar" then
                crossbar = part
            else
                local hasCyl, hasSnd = false, false
                for _, c in ipairs(part:GetChildren()) do
                    if c:IsA("CylinderMesh") then hasCyl = true end
                    if c:IsA("Sound") then hasSnd = true end
                end
                if hasCyl and hasSnd then
                    table.insert(posts, part)
                end
            end
        end
    end

    if #posts < 2 then
        for _, part in ipairs(frame:GetChildren()) do
            if part:IsA("BasePart") and part.Name ~= "Crossbar" then
                table.insert(posts, part)
            end
        end
    end

    if #posts < 2 or not crossbar then
        return nil
    end

    table.sort(posts, function(a, b)
        return a.Position.X < b.Position.X
    end)

    local leftPost, rightPost = posts[1], posts[#posts]
    local lFloor = leftPost.Position.Y - leftPost.Size.Y / 2
    local rFloor = rightPost.Position.Y - rightPost.Size.Y / 2
    local floorY = math.min(lFloor, rFloor)

    local crossbarRadius = math.min(crossbar.Size.X, crossbar.Size.Z) / 2
    local topY = crossbar.Position.Y - crossbarRadius

    local postRadiusL = math.min(leftPost.Size.X, leftPost.Size.Z) / 2
    local postRadiusR = math.min(rightPost.Size.X, rightPost.Size.Z) / 2
    local width = (leftPost.Position - rightPost.Position).Magnitude - postRadiusL - postRadiusR
    local height = math.abs(topY - floorY)

    local rightDir = (rightPost.Position - leftPost.Position).Unit
    local upDir = Vector3.new(0, 1, 0)
    local fwdDir = rightDir:Cross(upDir).Unit
    local floorCenter = Vector3.new(
        (leftPost.Position.X + rightPost.Position.X) / 2,
        floorY,
        (leftPost.Position.Z + rightPost.Position.Z) / 2
    )

    GoalCFrame = CFrame.fromMatrix(floorCenter, rightDir, upDir, -fwdDir)
    GoalWidth = width
    GoalHeight = height
    GoalFloorY = floorY
    return width
end

-- ============================================================
-- GK
-- ============================================================
local GkTrack = {}

local function GetEnemyGoalie()
    if not GoalCFrame or not GoalWidth then
        if Gui then Gui.GK.Text = "GK: No Goal" end
        return nil, 0, 0, false, Vector3.zero, false, 2.2, 0, 0
    end

    local myTeam = (function()
        local stats = Workspace:FindFirstChild("PlayerStats")
        if not stats then return nil end
        if stats:FindFirstChild("Away") and stats.Away:FindFirstChild(LocalPlayer.Name) then
            return "Away"
        elseif stats:FindFirstChild("Home") and stats.Home:FindFirstChild(LocalPlayer.Name) then
            return "Home"
        end
    end)()

    local goalies = {}
    local halfW = GoalWidth / 2

    local function addGoalie(part, name, isNPC)
        if not part or not part:IsA("BasePart") then return end
        local local3 = GoalCFrame:PointToObjectSpace(part.Position)
        local localX = local3.X
        local localY = local3.Y
        local distGoal = (part.Position - GoalCFrame.Position).Magnitude
        local isInGoal = distGoal < 20 and math.abs(localX) < halfW + 3
        local hbRadius = math.max(part.Size.X, part.Size.Z) * 0.5
        table.insert(goalies, {
            hrp = part,
            localX = localX,
            localY = localY,
            distGoal = distGoal,
            name = name,
            isInGoal = isInGoal,
            isNPC = isNPC or false,
            hbRadius = hbRadius
        })
    end

    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and player.Team and player.Team.Name ~= myTeam then
            local wModel = Workspace:FindFirstChild(player.Name)
            local hitbox = wModel and wModel:FindFirstChild("Hitbox")
            if hitbox and hitbox:IsA("BasePart") then
                addGoalie(hitbox, player.Name, false)
            end
        end
    end

    for _, npcName in ipairs({ myTeam == "Away" and "HomeGoalie" or "Goalie", "Goalie", "HomeGoalie" }) do
        local npc = Workspace:FindFirstChild(npcName)
        local hitbox = npc and npc:FindFirstChild("Hitbox")
        if hitbox and hitbox:IsA("BasePart") then
            addGoalie(hitbox, "NPC", true)
            break
        end
    end

    if #goalies == 0 then
        for _, player in ipairs(Players:GetPlayers()) do
            if player ~= LocalPlayer and player.Team and player.Team.Name ~= myTeam then
                local char = player.Character
                if char then
                    local hum = char:FindFirstChild("Humanoid")
                    local hrp = char:FindFirstChild("HumanoidRootPart")
                    if hum and hrp and hum.HipHeight >= 4 then
                        addGoalie(hrp, player.Name, false)
                    end
                end
            end
        end
        local npcName = myTeam == "Away" and "HomeGoalie" or "Goalie"
        local npc = Workspace:FindFirstChild(npcName)
        if npc and npc:FindFirstChild("HumanoidRootPart") then
            addGoalie(npc.HumanoidRootPart, "NPC", true)
        end
    end

    if #goalies == 0 then
        if Gui then
            Gui.GK.Text = "GK: None"
            Gui.GK.Color = Color3.fromRGB(150, 150, 150)
        end
        return nil, 0, 0, false, Vector3.zero, false, 2.2, 0, 0
    end

    table.sort(goalies, function(a, b)
        if a.isInGoal ~= b.isInGoal then
            return a.isInGoal
        end
        return a.distGoal < b.distGoal
    end)

    local best = goalies[1]
    local now = tick()
    local tr = GkTrack[best.name]
    local vel = Vector3.zero
    local dt = tr and (now - tr.time) or 0

    if tr and dt > 0.02 and dt < 0.8 then
        vel = (best.hrp.Position - tr.pos) / dt
    end

    local assemblyVel = best.hrp.AssemblyLinearVelocity or Vector3.zero
    if assemblyVel.Magnitude > vel.Magnitude then
        vel = assemblyVel
    end

    local hist = (tr and tr.hist) or {}
    table.insert(hist, best.localX)
    while #hist > 8 do
        table.remove(hist, 1)
    end

    local sumX = 0
    for _, x in ipairs(hist) do
        sumX = sumX + x
    end

    local biasX = (#hist > 0) and (sumX / #hist) or best.localX
    local driftX = (tr and tr.localX and dt > 0.02 and dt < 0.8) and ((best.localX - tr.localX) / dt) or 0

    GkTrack[best.name] = {
        pos = best.hrp.Position,
        time = now,
        vel = vel,
        hist = hist,
        localX = best.localX
    }

    best.localY = GoalCFrame:PointToObjectSpace(best.hrp.Position).Y
    local isAggressive = not best.isInGoal

    if Gui then
        Gui.GK.Text = string.format(
            "GK: %s%s X=%.1f Y=%.1f v=%.1f b=%.1f",
            best.name,
            isAggressive and " [RUSH]" or "",
            best.localX,
            best.localY,
            vel.Magnitude,
            biasX
        )
        Gui.GK.Color = isAggressive and Color3.fromRGB(255, 80, 0) or Color3.fromRGB(255, 200, 0)
    end

    return best.hrp, best.localX, best.localY, isAggressive, vel, (best.isNPC or false), (best.hbRadius or 2.2), biasX, driftX
end

-- ============================================================
-- ЯДРО
-- ============================================================
local TargetPoint, ShootDir, ShootVel, CurrentSpin, CurrentPower, CurrentType
local AimPoint = nil
local PredictedLand = nil
local CurrentFlightTime = 0
local CurrentLaunchDir = nil
local CurrentSpeed = 0
local CurrentPeakPos = nil
local CurrentPeakFrac = 0.40
local CurrentIsLob = false
local CurrentDist = 0
local LastShoot = 0
local CanShoot = true

local function CalcLaunchDir(startPos, targetPos)
    local toTarget = targetPos - startPos
    local horiz = Vector3.new(toTarget.X, 0, toTarget.Z)
    local horizDist = horiz.Magnitude

    if horizDist < 0.5 then
        return Vector3.new(0, 1, 0), 0, 0.1
    end

    local V = AutoShootBallSpeed
    local k = AutoShootDragComp

    local t
    if k < 1e-5 then
        t = horizDist / V
    else
        local kd = math.min(k * horizDist / V, 0.990)
        t = -math.log(1 - kd) / k
    end

    local gravRamp = 1 - math.exp(-(t / 0.26) ^ 2)
    local baseComp = (0.5 * GRAVITY + 0.19 * k * V) * t * t * gravRamp
    local t2 = t * t
    local s = t2 / (t2 + 0.80 * 0.80)
    local farScale = 0.80 + 0.16 * s + 0.58 * s * s + 0.46 * s * s * s
    local upDy = math.max(targetPos.Y - startPos.Y, 0)
    local nearRise = upDy * 0.68 * math.exp(-(t / 0.34) ^ 2)
    local corrY = targetPos.Y + baseComp * farScale - nearRise
    local dir = (Vector3.new(targetPos.X, corrY, targetPos.Z) - startPos).Unit
    local cosAngle = math.sqrt(dir.X * dir.X + dir.Z * dir.Z)

    local realT
    if k < 1e-5 then
        realT = (cosAngle > 0.01) and (horizDist / (V * cosAngle)) or t
    else
        local kdCos = math.min(k * horizDist / math.max(V * cosAngle, 1), 0.990)
        realT = -math.log(1 - kdCos) / k
    end

    return dir, horizDist, realT
end

local function GetTarget(dist, gkX, gkY, isAggressive, gkHrp, gkVel, gkIsNPC, gkHitRadius, gkBiasX, gkDriftX)
    if not GoalCFrame or not GoalWidth or not GoalHeight then return nil end
    if dist > AutoShootMaxDistance then return nil end

    local startPos = GetBallStartPos()
    local halfW = GoalWidth / 2 - INSET
    local playerLocalX = GoalCFrame:PointToObjectSpace(startPos).X
    gkVel = gkVel or Vector3.zero
    gkHitRadius = gkHitRadius or 2.2
    gkBiasX = gkBiasX or 0
    gkDriftX = gkDriftX or 0

    local approxT = dist / AutoShootBallSpeed
    local gkPredW = gkHrp and (gkHrp.Position + gkVel * math.min(approxT, 0.8)) or nil
    local gkPredLoc = gkPredW and GoalCFrame:PointToObjectSpace(gkPredW) or nil
    local pgkX = gkPredLoc and gkPredLoc.X or gkX
    local pgkY = gkPredLoc and GoalCFrame:PointToObjectSpace(gkPredW).Y or gkY

    local reactionBonus = math.min(GK_REACH_SPEED * approxT * 0.25, 3.0)
    local diveRange = GK_REACH_RADIUS + reactionBonus

    local xPoints = {-halfW, -halfW*0.82, -halfW*0.60, -halfW*0.35, -halfW*0.15, 0, halfW*0.15, halfW*0.35, halfW*0.60, halfW*0.82, halfW}
    local yFracs = {0.08, 0.18, 0.30, 0.46, 0.60, 0.74, 0.86, 0.96}
    local candidates = {}

    for _, xf in ipairs(xPoints) do
        for _, yf in ipairs(yFracs) do
            local xSign = (xf >= 0) and 1 or -1
            local playerSideFrac = math.clamp(math.abs(playerLocalX) / math.max(halfW, 0.1), 0, 1)
            local cornerness = math.clamp((math.abs(xf) / math.max(halfW, 0.1) - 0.70) / 0.30, 0, 1)
            local sameSide = ((playerLocalX >= 0 and xf >= 0) or (playerLocalX < 0 and xf < 0)) and 1 or 0
            local centerness = 1 - playerSideFrac
            local shotOpen = math.clamp(math.abs(xf - playerLocalX) / math.max(GoalWidth * 0.95, 0.1), 0, 1)

            local laneTightness = cornerness * math.clamp(
                0.18 + 0.58 * centerness + 0.54 * sameSide * playerSideFrac - 0.76 * shotOpen,
                0, 1
            )
            local sameSideNarrow = cornerness * math.max(0, sameSide * playerSideFrac * (shotOpen - 0.38)) * 0.18
            local distTightBoost = cornerness * math.clamp((dist - 150) / 120, 0, 1) * (0.10 + 0.22 * centerness + 0.16 * sameSide * playerSideFrac)
            local longCornerInset = cornerness * math.clamp((dist - 140) / 160, 0, 1) * (0.22 + 0.24 * (1 - shotOpen) + 0.14 * centerness + 0.08 * sameSide * playerSideFrac)
            local cornerPull = math.max(0, cornerness * (0.14 + 0.82 * laneTightness) + distTightBoost + longCornerInset - sameSideNarrow)
            local localX = xf - xSign * cornerPull

            local yRange = math.max(0.5, GoalHeight - Y_TOP_TARGET - Y_BOT_INSET)
            local localY = Y_BOT_INSET + yf * yRange
            local highFrac = math.clamp((yf - 0.60) / 0.40, 0, 1)
            localY = math.max(Y_BOT_INSET, localY - (laneTightness + distTightBoost + longCornerInset * 0.65) * highFrac * 0.56)

            local idealPos = GoalCFrame * Vector3.new(localX, localY, 0)

            local gkDistX = math.abs(gkX - localX)
            local gkDistY = math.abs(gkY - localY)
            local gkDist2D = math.sqrt(gkDistX * gkDistX + gkDistY * gkDistY)
            local pgkDistX = math.abs(pgkX - localX)
            local gkEffY = math.max(0, pgkY - GoalHeight * 0.22)
            local pgkDistY = math.abs(gkEffY - localY)
            local pgkDist2D = math.sqrt(pgkDistX * pgkDistX + pgkDistY * pgkDistY)

            local reachability = math.clamp(1 - pgkDist2D / diveRange, 0, 1)
            local score = pgkDistX * 4.0 + (localY / math.max(GoalHeight, 1)) * 8.0 - reachability * 8.0

            if math.abs(pgkY - localY) < GK_REACH_RADIUS * 0.7 then
                score = score - 4.5
            end

            local isTopCorner = (yf >= 0.66) and (math.abs(localX) > halfW * 0.45)
            local isCorner = math.abs(localX) > halfW * 0.5
            local isLobShot = (yf >= 0.85)

            if isTopCorner then score = score + 9.0 end
            if isCorner and not isTopCorner then score = score + 3.0 end

            local hFrac = localY / math.max(yRange, 1)
            score = score + hFrac * 0.75
            score = score + hFrac * math.clamp((dist - 120) / 85, 0, 1) * 1.15
            score = score - hFrac * hFrac * math.clamp((85 - dist) / 40, 0, 1) * 3.8

            local midNoSpinHighPenalty = hFrac * math.clamp((dist - 95) / 45, 0, 1) * math.clamp((160 - dist) / 60, 0, 1) * 3.2
            if isLobShot and dist > 95 then score = score + 4.0 end

            if isLobShot then
                if pgkY < GoalHeight * 0.55 then score = score + 5.0 end
                if isAggressive then score = score + 7.0 end
                if dist < 50 then score = score - 12.0 end
            end

            if dist < 45 and localY > GoalHeight * 0.82 then
                score = score - 8.0
            end

            local centerPenalty = math.max(0, 1 - math.abs(localX) / (halfW * 0.4)) * 2.5
            score = score - centerPenalty

            local isFarCorner = (playerLocalX > halfW*0.2 and localX < -halfW*0.4)
                or (playerLocalX < -halfW*0.2 and localX > halfW*0.4)

            if gkIsNPC then
                score = score + pgkDist2D * 1.55 + math.abs(localX) * 0.45
                if isTopCorner then score = score + 0.7 end
                if isCorner then score = score + 1.3 end
                score = score - hFrac * math.clamp((dist - 110) / 55, 0, 1) * 3.0
                score = score - midNoSpinHighPenalty * 1.2
            else
                score = score - midNoSpinHighPenalty
                if isFarCorner then score = score + 3.5 end
                local biasFrac = math.min(math.abs(gkBiasX) / math.max(halfW, 0.1), 1)
                local driftFrac = math.min(math.abs(gkDriftX) / 8, 1)
                if gkBiasX < -halfW * 0.10 and localX > 0 then score = score + 1.6 + biasFrac * 2.6 end
                if gkBiasX > halfW * 0.10 and localX < 0 then score = score + 1.6 + biasFrac * 2.6 end
                if gkDriftX < -0.35 and localX > 0 then score = score + 1.0 + driftFrac * 1.8 end
                if gkDriftX > 0.35 and localX < 0 then score = score + 1.0 + driftFrac * 1.8 end
            end

            if gkHrp then
                local toTarget = (idealPos - startPos).Unit
                local toGK = (gkHrp.Position - startPos)
                local gkOnPath = toGK:Dot(toTarget) / math.max(toTarget.Magnitude, 1)
                local gkPerp = (toGK - toTarget * toGK:Dot(toTarget)).Magnitude
                if gkOnPath > 1 and gkPerp < math.max(1.7, gkHitRadius * 0.70) then
                    score = score - 10.0
                end
            end

            if isAggressive and gkHrp then
                local dot = (idealPos - startPos).Unit:Dot((gkHrp.Position - startPos).Unit)
                score = score + (dot > 0.90 and -12.0 or 8.0)
            end

            if math.abs(gkX) > halfW * 0.55 and math.abs(localX) < halfW * 0.3 then
                score = score + 6.0
            end

            if gkVel.Magnitude > 2 and gkHrp then
                local toT = (idealPos - gkHrp.Position).Unit
                if gkVel.Unit:Dot(toT) > 0.65 then score = score - 4.5 end
            end

            if gkHrp then
                local gkProj = GoalCFrame:PointToObjectSpace(gkHrp.Position)
                local gkBX = gkProj.X
                local gkBY = gkProj.Y
                local hbHalfW = math.max(1.15, gkHitRadius * 0.62)
                local hbLow = math.max(1.0, gkHrp.Size.Y * 0.38)
                local hbHigh = math.max(1.8, gkHrp.Size.Y * 0.55)
                local inShadow = math.abs(localX - gkBX) < hbHalfW
                    and localY > (gkBY - hbLow)
                    and localY < (gkBY + hbHigh)
                if inShadow then score = score - 14.0 end
            end

            local power = FIXED_POWER
            local speed = AutoShootBallSpeed
            local spinDir = "None"

            local sameSideLane = (playerLocalX < 0 and localX < 0) or (playerLocalX > 0 and localX > 0)
            local crossLaneOpen = math.abs(localX - playerLocalX) / math.max(halfW, 0.1)
            local canServerSpin = (not gkIsNPC) and dist > SPIN_SERVER_MIN_DIST and dist <= AutoShootCurveDistanceLimit
            local isCenterCurl = math.abs(localX) < halfW * 0.30
                and (math.abs(gkX) > halfW * 0.14 or math.abs(gkBiasX) > halfW * 0.12)

            if canServerSpin and gkDist2D < 5.8 then
                spinDir = (gkX > localX) and "Right" or "Left"
                score = score + 3.4 + (sameSideLane and 0.8 or 0.0)
            elseif canServerSpin and isCenterCurl then
                spinDir = (playerLocalX < 0) and "Left" or "Right"
                score = score + 4.8 + (sameSideLane and 0.5 or 0.0)
            elseif canServerSpin and isCorner then
                spinDir = (localX >= 0) and "Left" or "Right"
                score = score + 2.4 + (sameSideLane and 1.0 or math.min(crossLaneOpen, 1) * 0.9)
            elseif canServerSpin then
                local goalDir = (GoalCFrame.Position - startPos).Unit
                local fwdDir = HumanoidRootPart.CFrame.LookVector
                local fwdAngle = math.deg(math.acos(math.clamp(goalDir:Dot(fwdDir), -1, 1)))
                if fwdAngle < 42 then
                    spinDir = localX >= 0 and "Left" or "Right"
                    score = score + 1.8 + (sameSideLane and 0.6 or 0.0)
                end
            end

            local derivation = 0
            if spinDir ~= "None" then
                local dMult = AutoShootDerivMult * (dist / 100) ^ 2
                derivation = (spinDir == "Right" and 1 or -1) * dMult
                score = score + math.min(dMult * 0.35, 1.5)
            end

            local safeEdge = GoalWidth / 2 - BALL_RADIUS
            local shootLocalX = math.clamp(localX + derivation, -safeEdge, safeEdge)
            local shootLocalY = localY

            if spinDir ~= "None" then
                local hf = localY / math.max(GoalHeight, 1)
                local spinDrop = 0.18 + 0.34 * hf
                shootLocalY = math.max(Y_BOT_INSET, localY - spinDrop)
            else
                local hf = localY / math.max(GoalHeight, 1)
                local midBand = math.clamp((dist - 95) / 40, 0, 1) * math.clamp((160 - dist) / 60, 0, 1)
                local npcBand = gkIsNPC and 1 or 0
                local noSpinDrop = (0.18 + 0.28 * hf) * midBand * (1.0 + 0.45 * npcBand)
                local extraFlatDrop = (0.05 + 0.07 * math.clamp(1 - hf, 0, 1)) * midBand
                shootLocalY = math.max(Y_BOT_INSET, localY - noSpinDrop - extraFlatDrop)
            end

            local depthAlpha = 1 - math.exp(-dist / 95)
            local goalDepth = GOAL_DEPTH_MIN + (GOAL_DEPTH_MAX - GOAL_DEPTH_MIN) * depthAlpha
            if spinDir ~= "None" then goalDepth = goalDepth + 0.90 end
            if isLobShot then goalDepth = goalDepth + 0.45 end

            local shootPos = GoalCFrame * Vector3.new(shootLocalX, shootLocalY, -goalDepth)
            local launchDir, _, flightT = CalcLaunchDir(startPos, shootPos)
            local launchAngleDeg = math.deg(math.asin(math.clamp(launchDir.Y, -1, 1)))
            local trajOk = (launchAngleDeg < 42)

            if not trajOk then
                score = score - 5.0
                if launchAngleDeg > 55 then score = score - 6.0 end
            end

            local V = AutoShootBallSpeed
            local cosA = math.sqrt(launchDir.X^2 + launchDir.Z^2)
            local aimPoint
            if cosA > 0.01 and flightT > 0 then
                local hFactor = (AutoShootDragComp > 1e-5)
                    and ((1 - math.exp(-AutoShootDragComp * flightT)) / AutoShootDragComp)
                    or flightT
                aimPoint = Vector3.new(
                    startPos.X + launchDir.X * V * hFactor,
                    startPos.Y + launchDir.Y * V * flightT - 0.5 * GRAVITY * flightT * flightT,
                    startPos.Z + launchDir.Z * V * hFactor
                )
            else
                aimPoint = shootPos
            end

            local flightTime = flightT
            local t40 = 0.40 * flightTime
            local hF40 = (AutoShootDragComp > 1e-5)
                and ((1 - math.exp(-AutoShootDragComp * t40)) / AutoShootDragComp)
                or t40
            local peakPos = Vector3.new(
                startPos.X + launchDir.X * speed * hF40,
                startPos.Y + launchDir.Y * speed * t40 - 0.5 * GRAVITY * t40 * t40,
                startPos.Z + launchDir.Z * speed * hF40
            )

            table.insert(candidates, {
                idealPos = idealPos,
                aimPoint = aimPoint,
                shootPos = shootPos,
                launchDir = launchDir,
                localX = localX,
                localY = localY,
                spin = spinDir,
                power = power,
                speed = speed,
                score = score,
                gkDist = gkDist2D,
                trajOk = trajOk,
                flightTime = flightTime,
                peakPos = peakPos,
                peakFrac = 0.40,
                isTopCorner = isTopCorner,
                isLobShot = isLobShot,
                isRicochet = false,
            })
        end
    end

    if #candidates == 0 then return nil end
    table.sort(candidates, function(a, b)
        return a.score > b.score
    end)
    return candidates[1]
end

local function CalculateTarget()
    local width = UpdateGoal()
    if not GoalCFrame or not width then
        TargetPoint = nil
        if Gui then
            Gui.Target.Text = "Target: --"
            Gui.Power.Text = "Power: --"
            Gui.Spin.Text = "Spin: --"
        end
        return
    end

    local dist = (GetBallStartPos() - GoalCFrame.Position).Magnitude
    if Gui then
        Gui.Dist.Text = string.format("Dist: %.0f | Goal: %.0f×%.0f", dist, GoalWidth, GoalHeight)
    end

    if dist > AutoShootMaxDistance then
        TargetPoint = nil
        if Gui then Gui.Target.Text = "Too Far" end
        return
    end

    local gkHrp, gkX, gkY, isAggressive, gkVel, gkIsNPC, gkHitRadius, gkBiasX, gkDriftX =
        GetEnemyGoalie()

    local result = GetTarget(
        dist,
        gkX or 0,
        gkY or 0,
        isAggressive or false,
        gkHrp,
        gkVel,
        gkIsNPC or false,
        gkHitRadius or 2.2,
        gkBiasX or 0,
        gkDriftX or 0
    )

    if not result then
        TargetPoint = nil
        if Gui then Gui.Target.Text = "No Candidate" end
        return
    end

    ShootDir = result.launchDir
    local closeExtra = (CurrentDist < SPIN_TRICK_DIST) and PAST_GOAL_CLOSE or 0
    local velMult = (CurrentDist + PAST_GOAL_BASE + closeExtra) / math.max(CurrentDist, 5)
    ShootVel = ShootDir * (FIXED_POWER * 1400 * velMult)

    CurrentSpin = result.spin
    CurrentPower = FIXED_POWER

    local typePrefix =
        result.isRicochet and "[RIC] "
        or (result.isLobShot and "[LOB] "
        or (result.isTopCorner and "[TC] " or ""))

    CurrentType = string.format(
        "%sX=%.1f Y=%.1f/%.1f gk=%.1f",
        typePrefix,
        result.localX,
        result.localY,
        GoalHeight,
        result.gkDist
    )

    PredictedLand = result.idealPos
    AimPoint = result.aimPoint
    CurrentFlightTime = result.flightTime
    CurrentLaunchDir = result.launchDir
    CurrentSpeed = result.speed
    CurrentPeakPos = result.peakPos
    CurrentPeakFrac = result.peakFrac or 0.40
    CurrentIsLob = result.isLobShot or false
    CurrentDist = dist
    TargetPoint = result.shootPos

    if Gui then
        Gui.Target.Text = string.format("→ X=%.1f Y=%.1f/%.1f", result.localX, result.localY, GoalHeight)
        local cosA_d = math.sqrt(result.launchDir.X^2 + result.launchDir.Z^2)
        local launchAngle = math.deg(math.atan(result.launchDir.Y / math.max(cosA_d, 0.01)))
        local spinShown = (result.spin == "Right") and "CurveLeft"
            or (result.spin == "Left") and "CurveRight"
            or "None"

        Gui.Power.Text = string.format(
            "θ=%.1f° t=%.2fs %s | Spin=%s",
            launchAngle,
            result.flightTime,
            result.trajOk and "OK" or "!steep",
            spinShown
        )
        Gui.Spin.Text = string.format(
            "V=%.0f k=%.2f drv=%.1f curve<=%.0f d=%.0f",
            AutoShootBallSpeed,
            AutoShootDragComp,
            AutoShootDerivMult,
            AutoShootCurveDistanceLimit,
            dist
        )
        Gui.Goal.Text = string.format("Goal W=%.1f H=%.1f floor=%.1f", GoalWidth, GoalHeight, GoalFloorY)
    end
end

-- ============================================================
-- SPOOF
-- ============================================================
local function GetSpoofPower()
    if not AutoShootSpoofPowerEnabled then return nil end
    if AutoShootSpoofPowerType == "math.huge" then return math.huge
    elseif AutoShootSpoofPowerType == "9999999" then return 9999999
    elseif AutoShootSpoofPowerType == "100" then return 100 end
    return nil
end

local function GetKeyName(key)
    if key == Enum.KeyCode.Unknown then return "None" end
    local name = tostring(key):match("KeyCode%.(.+)") or tostring(key)
    local pretty = {
        LeftMouse = "LMB",
        RightMouse = "RMB",
        Space = "Space",
        LeftShift = "LShift",
        RightShift = "RShift",
        ButtonR2 = "R2",
        ButtonL2 = "L2"
    }
    return pretty[name] or name
end

local function UpdateModeText()
    if not Gui then return end
    if AutoShootMode == "Hook" then
        Gui.Mode.Text = "Mode: Hook | Keybind: Off"
    else
        Gui.Mode.Text = AutoShootManualShot
            and string.format("Mode: Packet | Manual (%s)", GetKeyName(AutoShootShootKey))
            or "Mode: Packet | Auto"
    end
end

-- ============================================================
-- HOOK MODE STATE
-- ============================================================
local AutoShootHookState = {
    Enabled = false,
    NamecallHook = nil,
    IndexHook = nil,
}

local function DisableHookMode()
    AutoShootHookState.Enabled = false
    AutoShootHookState.NamecallHook = nil
    AutoShootHookState.IndexHook = nil
end

local function EnableHookMode()
    if AutoShootHookState.Enabled then
        return true
    end

    -- Заглушка под реальную hook-реализацию.
    -- Сюда можно вставить hookmetamethod/newcclosure и перехват нужных вызовов.
    AutoShootHookState.Enabled = true
    return true
end

-- ============================================================
-- SHOOT
-- ============================================================
local function DoShoot()
    if not ShootDir then return false end

    if AutoShootMode == "Hook" then
        return EnableHookMode()
    end

    if IsAnimating and AutoShootLegit then return false end
    if AutoShootLegit then
        IsAnimating = true
        RShootAnim:Play()
        task.delay(AnimationHoldTime, function()
            IsAnimating = false
        end)
    end

    local power = GetSpoofPower() or CurrentPower
    local ok = pcall(function()
        Shooter:FireServer(ShootDir, BallAttachment.CFrame, power, ShootVel, false, false, CurrentSpin, nil, false)
    end)
    return ok
end

-- ============================================================
-- AUTO SHOOT MODULE
-- ============================================================
local AutoShoot = {}

AutoShoot.Start = function()
    if AutoShootStatus.Running then return end
    AutoShootStatus.Running = true

    SetupGUI()
    InitializeCubes()
    UpdateModeText()

    if AutoShootMode == "Hook" then
        EnableHookMode()
    else
        DisableHookMode()
    end

    AutoShootStatus.Connection = RunService.Heartbeat:Connect(function()
        if not AutoShootEnabled then return end

        pcall(CalculateTarget)

        local ball = Workspace:FindFirstChild("ball")
        local hasBall = ball and ball:FindFirstChild("playerWeld") and ball.creator.Value == LocalPlayer
        local dist = GoalCFrame and (GetBallStartPos() - GoalCFrame.Position).Magnitude or 999

        if hasBall and TargetPoint and dist <= AutoShootMaxDistance then
            if Gui then
                if AutoShootMode == "Hook" then
                    Gui.Status.Text = "Hook Ready"
                else
                    Gui.Status.Text = AutoShootManualShot and ("Ready [" .. GetKeyName(AutoShootShootKey) .. "]") or "Aiming..."
                end
                Gui.Status.Color = Color3.fromRGB(0, 255, 0)
            end
        elseif hasBall then
            if Gui then
                Gui.Status.Text = dist > AutoShootMaxDistance and "Too Far" or "No Target"
                Gui.Status.Color = Color3.fromRGB(255, 100, 0)
            end
        else
            if Gui then
                Gui.Status.Text = "No Ball"
                Gui.Status.Color = Color3.fromRGB(255, 165, 0)
            end
        end

        if AutoShootMode == "Packet"
            and hasBall
            and TargetPoint
            and dist <= AutoShootMaxDistance
            and not AutoShootManualShot
            and tick() - LastShoot >= 0.3
        then
            if DoShoot() then
                LastShoot = tick()
            end
        end
    end)

    AutoShootStatus.InputConnection = UserInputService.InputBegan:Connect(function(inp, gp)
        if gp or not AutoShootEnabled or not AutoShootManualShot or not CanShoot then
            return
        end

        if AutoShootMode ~= "Packet" then
            return
        end

        if inp.KeyCode == AutoShootShootKey or inp.UserInputType == AutoShootShootKey then
            local ball = Workspace:FindFirstChild("ball")
            local hasBall = ball and ball:FindFirstChild("playerWeld") and ball.creator.Value == LocalPlayer
            if hasBall and TargetPoint then
                pcall(CalculateTarget)
                if DoShoot() then
                    if Gui then
                        Gui.Status.Text = "SHOT! [" .. CurrentType .. "]"
                        Gui.Status.Color = Color3.fromRGB(0, 255, 0)
                    end
                    LastShoot = tick()
                    CanShoot = false
                    task.delay(0.3, function()
                        CanShoot = true
                    end)
                end
            end
        end
    end)

    AutoShootStatus.RenderConnection = RunService.RenderStepped:Connect(function()
        local width = UpdateGoal()
        local hasTarget = TargetPoint ~= nil
        local ball = Workspace:FindFirstChild("ball")
        local hasBall = ball and ball:FindFirstChild("playerWeld") and ball.creator.Value == LocalPlayer
        local showVisuals = (not VisualsOnlyWithBall) or hasBall

        if showVisuals and ShowTrajectory and hasTarget and CurrentLaunchDir and CurrentFlightTime > 0 then
            DrawTrajectory(GetVisualStartPos(), CurrentPeakPos, PredictedLand, CurrentPeakFrac, CurrentSpin)
        else
            for _, l in ipairs(TrajectoryLines) do l.Visible = false end
            for _, l in ipairs(StartCircle) do l.Visible = false end
        end

        if showVisuals and Show3DBoxes and AimPoint then
            DrawOrientedCube(TargetCube, CFrame.new(AimPoint), Vector3.new(2, 2, 2))
        else
            for _, l in ipairs(TargetCube) do l.Visible = false end
        end

        if showVisuals and Show3DBoxes and PredictedLand then
            DrawOrientedCube(GoalCube, CFrame.new(PredictedLand), Vector3.new(2.5, 2.5, 2.5))
        else
            for _, l in ipairs(GoalCube) do l.Visible = false end
        end

        if showVisuals and Show3DBoxes and CurrentPeakPos and hasTarget then
            DrawOrientedCube(PeakCube, CFrame.new(CurrentPeakPos), Vector3.new(2, 2, 2))
        else
            for _, l in ipairs(PeakCube) do l.Visible = false end
        end

        if showVisuals and Show3DBoxes and GoalCFrame and width and GoalHeight then
            DrawOrientedCube(NoSpinCube, GoalCFrame * CFrame.new(0, GoalHeight / 2, 0), Vector3.new(width, GoalHeight, 1))
        else
            for _, l in ipairs(NoSpinCube) do l.Visible = false end
        end
    end)
end

AutoShoot.Stop = function()
    if AutoShootStatus.Connection then
        AutoShootStatus.Connection:Disconnect()
        AutoShootStatus.Connection = nil
    end
    if AutoShootStatus.RenderConnection then
        AutoShootStatus.RenderConnection:Disconnect()
        AutoShootStatus.RenderConnection = nil
    end
    if AutoShootStatus.InputConnection then
        AutoShootStatus.InputConnection:Disconnect()
        AutoShootStatus.InputConnection = nil
    end

    DisableHookMode()
    AutoShootStatus.Running = false

    if Gui then
        for _, v in pairs(Gui) do
            if v.Remove then v:Remove() end
        end
        Gui = nil
    end

    for i = 1, 12 do
        if TargetCube[i] and TargetCube[i].Remove then TargetCube[i]:Remove() end
        if GoalCube[i] and GoalCube[i].Remove then GoalCube[i]:Remove() end
        if NoSpinCube[i] and NoSpinCube[i].Remove then NoSpinCube[i]:Remove() end
        if PeakCube[i] and PeakCube[i].Remove then PeakCube[i]:Remove() end
    end

    for i = 1, TRAJ_SEGMENTS do
        if TrajectoryLines[i] and TrajectoryLines[i].Remove then TrajectoryLines[i]:Remove() end
    end

    for i = 1, #StartCircle do
        if StartCircle[i] and StartCircle[i].Remove then
            StartCircle[i]:Remove()
        end
    end
    StartCircle = {}
end

AutoShoot.SetDebugText = function(v)
    AutoShootDebugText = v
    ToggleDebugText(v)
end

-- ============================================================
-- AUTO PICKUP
-- ============================================================
local AutoPickup = {}

local function AutoPickupTick()
    if not AutoPickupEnabled or not PickupRemote or not HumanoidRootPart then return end
    if IsLocalGoalkeeper() then return end

    local ball = Workspace:FindFirstChild("ball")
    if not ball or ball:FindFirstChild("playerWeld") then return end

    if (HumanoidRootPart.Position - ball.Position).Magnitude <= AutoPickupDist then
        pcall(function()
            PickupRemote:FireServer(AutoPickupSpoofValue)
        end)
    end
end

AutoPickup.Start = function()
    if AutoPickupStatus.Running then return end
    AutoPickupStatus.Running = true

    pcall(AutoPickupTick)
    AutoPickupStatus.Connection = RunService.Heartbeat:Connect(function()
        AutoPickupTick()
    end)
end

AutoPickup.Stop = function()
    if AutoPickupStatus.Connection then
        AutoPickupStatus.Connection:Disconnect()
        AutoPickupStatus.Connection = nil
    end
    AutoPickupStatus.Running = false
end

-- ============================================================
-- UI
-- ============================================================
local uiElements = {}

local function SynchronizeConfigValues()
    if not uiElements then return end
    local pairs_sync = {
        { uiElements.AutoShootMaxDist, function(v) AutoShootMaxDistance = v end },
        { uiElements.AutoShootCurveDistanceLimit, function(v) AutoShootCurveDistanceLimit = v end },
        { uiElements.AutoShootBallSpeed, function(v) AutoShootBallSpeed = v end },
        { uiElements.AutoShootDragComp, function(v) AutoShootDragComp = v end },
        { uiElements.AutoShootDerivMult, function(v) AutoShootDerivMult = v end },
        { uiElements.AutoPickupDist, function(v) AutoPickupDist = v end },
        { uiElements.AutoPickupSpoof, function(v) AutoPickupSpoofValue = v end },
    }

    for _, pair in ipairs(pairs_sync) do
        local elem, setter = pair[1], pair[2]
        if elem and elem.GetValue then
            pcall(function()
                setter(elem:GetValue())
            end)
        end
    end
end

local function SetupUI(UI)
    if UI.Sections.AutoShoot then
        UI.Sections.AutoShoot:Header({ Name = "AutoShoot" })
        UI.Sections.AutoShoot:Divider()

        uiElements.AutoShootEnabled = UI.Sections.AutoShoot:Toggle({
            Name = "Enabled",
            Default = AutoShootEnabled,
            Callback = function(v)
                AutoShootEnabled = v
                if v then
                    AutoShoot.Start()
                else
                    AutoShoot.Stop()
                end
            end
        }, "AutoShootEnabled")

        uiElements.AutoShootMode = UI.Sections.AutoShoot:Dropdown({
            Name = "Mode",
            Default = AutoShootMode,
            Options = {"Packet", "Hook"},
            Required = true,
            Callback = function(v)
                AutoShootMode = v
                UpdateModeText()
                if AutoShootEnabled then
                    AutoShoot.Stop()
                    AutoShoot.Start()
                end
            end
        }, "AutoShootMode")

        uiElements.AutoShootLegit = UI.Sections.AutoShoot:Toggle({
            Name = "Legit Animation",
            Default = AutoShootLegit,
            Callback = function(v)
                AutoShootLegit = v
            end
        }, "AutoShootLegit")

        UI.Sections.AutoShoot:Divider()

        uiElements.AutoShootManual = UI.Sections.AutoShoot:Toggle({
            Name = "Manual Shot",
            Default = AutoShootManualShot,
            Callback = function(v)
                AutoShootManualShot = v
                UpdateModeText()
            end
        }, "AutoShootManual")

        uiElements.AutoShootKey = UI.Sections.AutoShoot:Keybind({
            Name = "Shoot Key",
            Default = AutoShootShootKey,
            Callback = function(v)
                if AutoShootMode == "Hook" then return end
                AutoShootShootKey = v
                UpdateModeText()
            end,
            onBinded = function(v)
                if AutoShootMode == "Hook" then return end
                AutoShootShootKey = v
                UpdateModeText()
            end
        }, "AutoShootKey")

        UI.Sections.AutoShoot:Divider()

        uiElements.AutoShootMaxDist = UI.Sections.AutoShoot:Slider({
            Name = "Max Distance",
            Minimum = 50,
            Maximum = 300,
            Default = AutoShootMaxDistance,
            Precision = 1,
            Callback = function(v)
                AutoShootMaxDistance = v
            end
        }, "AutoShootMaxDist")

        uiElements.AutoShootCurveDistanceLimit = UI.Sections.AutoShoot:Slider({
            Name = "Curve Distance Limit",
            Minimum = 130,
            Maximum = 300,
            Default = AutoShootCurveDistanceLimit,
            Precision = 1,
            Callback = function(v)
                AutoShootCurveDistanceLimit = v
            end
        }, "AutoShootCurveDistanceLimit")

        uiElements.AutoShootBallSpeed = UI.Sections.AutoShoot:Slider({
            Name = "Ball Speed",
            Minimum = 100,
            Maximum = 1000,
            Default = AutoShootBallSpeed,
            Precision = 1,
            Callback = function(v)
                AutoShootBallSpeed = v
            end
        }, "AutoShootBallSpeed")
        UI.Sections.AutoShoot:SubLabel({ Text = "~400 studs/s. if ball higher → increase | ball down → reduce" })

        uiElements.AutoShootDragComp = UI.Sections.AutoShoot:Slider({
            Name = "Drag Compensation",
            Minimum = 0,
            Maximum = 3,
            Default = AutoShootDragComp,
            Precision = 2,
            Callback = function(v)
                AutoShootDragComp = v
            end
        }, "AutoShootDragComp")
        UI.Sections.AutoShoot:SubLabel({ Text = "[↑] ball does not reach → increase  | flight away → reduce" })

        uiElements.AutoShootDerivMult = UI.Sections.AutoShoot:Slider({
            Name = "Derivation Mult",
            Minimum = 0.5,
            Maximum = 10.0,
            Default = AutoShootDerivMult,
            Precision = 2,
            Callback = function(v)
                AutoShootDerivMult = v
            end
        }, "AutoShootDerivMult")

        UI.Sections.AutoShoot:Divider()

        uiElements.AutoShootSpoofPower = UI.Sections.AutoShoot:Toggle({
            Name = "Spoof Power",
            Default = AutoShootSpoofPowerEnabled,
            Callback = function(v)
                AutoShootSpoofPowerEnabled = v
            end
        }, "AutoShootSpoofPower")

        uiElements.AutoShootSpoofType = UI.Sections.AutoShoot:Dropdown({
            Name = "Spoof Power Type",
            Default = AutoShootSpoofPowerType,
            Options = {"math.huge", "9999999", "100"},
            Required = true,
            Callback = function(v)
                AutoShootSpoofPowerType = v
            end
        }, "AutoShootSpoofType")

        uiElements.AutoShootDebugText = UI.Sections.AutoShoot:Toggle({
            Name = "Debug Text",
            Default = AutoShootDebugText,
            Callback = function(v)
                AutoShoot.SetDebugText(v)
            end
        }, "AutoShootDebugText")

        UI.Sections.AutoShoot:Divider()

        uiElements.ShowTrajectory = UI.Sections.AutoShoot:Toggle({
            Name = "Show Trajectory",
            Default = ShowTrajectory,
            Callback = function(v)
                ShowTrajectory = v
            end
        }, "ShowTrajectory")

        uiElements.Show3DBoxes = UI.Sections.AutoShoot:Toggle({
            Name = "Show 3D Boxes",
            Default = Show3DBoxes,
            Callback = function(v)
                Show3DBoxes = v
            end
        }, "Show3DBoxes")

        uiElements.VisualsOnlyWithBall = UI.Sections.AutoShoot:Toggle({
            Name = "Visuals Only With Ball",
            Default = VisualsOnlyWithBall,
            Callback = function(v)
                VisualsOnlyWithBall = v
            end
        }, "VisualsOnlyWithBall")
    end

    if UI.Sections.AutoPickup then
        UI.Sections.AutoPickup:Header({ Name = "AutoPickup" })
        UI.Sections.AutoPickup:Divider()

        uiElements.AutoPickupEnabled = UI.Sections.AutoPickup:Toggle({
            Name = "Enabled",
            Default = AutoPickupEnabled,
            Callback = function(v)
                AutoPickupEnabled = v
                if v then
                    AutoPickup.Start()
                else
                    AutoPickup.Stop()
                end
            end
        }, "AutoPickupEnabled")

        uiElements.AutoPickupDist = UI.Sections.AutoPickup:Slider({
            Name = "Pickup Distance",
            Minimum = 10,
            Maximum = 300,
            Default = AutoPickupDist,
            Precision = 1,
            Callback = function(v)
                AutoPickupDist = v
            end
        }, "AutoPickupDist")

        uiElements.AutoPickupSpoof = UI.Sections.AutoPickup:Slider({
            Name = "Spoof Value",
            Minimum = 0.1,
            Maximum = 5.0,
            Default = AutoPickupSpoofValue,
            Precision = 2,
            Callback = function(v)
                AutoPickupSpoofValue = v
            end
        }, "AutoPickupSpoof")

        UI.Sections.AutoPickup:SubLabel({ Text = "[💠] Distance sent to server for pickup" })
    end

    if UI.Sections.AutoShoot then
        UI.Sections.AutoShoot:Divider()

        uiElements.TrajectoryColor = UI.Sections.AutoShoot:Colorpicker({
            Name = "Trajectory Color",
            Default = TrajectoryColor,
            Callback = function(v)
                TrajectoryColor = v
                ApplyVisualStyles()
            end
        }, "TrajectoryColor")

        uiElements.StartCircleColor = UI.Sections.AutoShoot:Colorpicker({
            Name = "Start Circle Color",
            Default = StartCircleColor,
            Callback = function(v)
                StartCircleColor = v
                ApplyVisualStyles()
            end
        }, "StartCircleColor")

        uiElements.TargetCubeColor = UI.Sections.AutoShoot:Colorpicker({
            Name = "Aim Box Color",
            Default = TargetCubeColor,
            Callback = function(v)
                TargetCubeColor = v
                ApplyVisualStyles()
            end
        }, "TargetCubeColor")

        uiElements.GoalCubeColor = UI.Sections.AutoShoot:Colorpicker({
            Name = "Predicted Box Color",
            Default = GoalCubeColor,
            Callback = function(v)
                GoalCubeColor = v
                ApplyVisualStyles()
            end
        }, "GoalCubeColor")

        uiElements.NoSpinCubeColor = UI.Sections.AutoShoot:Colorpicker({
            Name = "Goal Frame Color",
            Default = NoSpinCubeColor,
            Callback = function(v)
                NoSpinCubeColor = v
                ApplyVisualStyles()
            end
        }, "NoSpinCubeColor")

        uiElements.PeakCubeColor = UI.Sections.AutoShoot:Colorpicker({
            Name = "Peak Box Color",
            Default = PeakCubeColor,
            Callback = function(v)
                PeakCubeColor = v
                ApplyVisualStyles()
            end
        }, "PeakCubeColor")
    end
end

-- ============================================================
-- MODULE INIT
-- ============================================================
local AutoShootModule = {}

function AutoShootModule.Init(UI, coreParam, notifyFunc)
    local notify = notifyFunc or function(t, m)
        print("[" .. t .. "]: " .. m)
    end

    SetupUI(UI)

    local synchronizationTimer = 0
    RunService.Heartbeat:Connect(function(deltaTime)
        synchronizationTimer += deltaTime
        if synchronizationTimer >= 1.0 then
            synchronizationTimer = 0
            SynchronizeConfigValues()
        end
    end)

    if AutoPickupEnabled then AutoPickup.Start() end
    if AutoShootEnabled then AutoShoot.Start() end

    LocalPlayer.CharacterAdded:Connect(function(newChar)
        task.wait(1)
        Character = newChar
        Humanoid = newChar:WaitForChild("Humanoid")
        HumanoidRootPart = newChar:WaitForChild("HumanoidRootPart")
        BallAttachment = newChar:WaitForChild("ball")
        RShootAnim = Humanoid:LoadAnimation(Animations:WaitForChild("RShoot"))
        RShootAnim.Priority = Enum.AnimationPriority.Action4

        GoalCFrame = nil
        TargetPoint = nil
        PredictedLand = nil
        AimPoint = nil
        CurrentFlightTime = 0
        CurrentLaunchDir = nil
        CurrentSpeed = 0
        CurrentPeakPos = nil
        LastShoot = 0
        IsAnimating = false
        CanShoot = true

        if AutoShootEnabled then AutoShoot.Start() end
        if AutoPickupEnabled then AutoPickup.Start() end
    end)
end

function AutoShootModule:Destroy()
    AutoShoot.Stop()
    AutoPickup.Stop()
end

return AutoShootModule
