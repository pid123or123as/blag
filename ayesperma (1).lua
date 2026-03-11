-- Ball Trajectory Visualizer v6 Module — Декабрь 2025 — Адаптировано под лоадер с UI + Sync
local BallTrajectoryModule = {}
local ws = workspace
local rs = game:GetService("RunService")
local uis = game:GetService("UserInputService")
local ts = game:GetService("TweenService")

-- === CONFIG ===
local CONFIG = {
    -- PREDICTION
    PRED_STEPS = 320,
    MAX_PRED_STEPS = 400,  -- Фикс для линий (не меняется)
    CURVE_MULT = 38,
    DT = 1/60,
    GRAVITY = 110,
    DRAG = 0.988,
    BOUNCE_XZ = 0.76,
    BOUNCE_Y = 0.72,
    CURVE_FADE_RATE = 0.06,
    -- RAYCAST
    UseRaycast = true,
    RAYCAST_LENGTH_MULT = 1.8,
    MIN_HIT_DISTANCE = 0.05,
    -- VISUAL
    Enabled = false,
    MAX_DRAW_DISTANCE = 100,
    VISUAL_SMOOTHNESS = 0.85,
    TrajectoryColor = Color3.fromHSV(0, 0.85, 0.95),  -- Начало градиента (синий)
    EndpointColor = Color3.new(1, 0.9, 0),  -- Желтый
    -- PERFORMANCE
    PRED_UPDATE_MIN_VEL = 15,
    MIN_TIME_BETWEEN_PRED = 0.033,
}

-- === STATUS ===
local Status = {
    Running = false,
    RenderConnection = nil,
    IgnoredConn = nil,
}

-- === VISUALS ===
local trajLines = {}
local endpointLines = {}
local ignoredModels = {}
local cachedPoints = nil
local cachedEndpoint = nil
local lastBallVelMag = 0
local lastPredictionTime = 0
local lastBallPos = Vector3.zero
local lastRenderTime = 0
local renderDelta = 1/60
local endpointRadius = 3.8

-- === NOTIFY ===
local notify = function() end

-- HSV Helper
local function Color3ToHSV(c)
    local r, g, b = c.R, c.G, c.B
    local maxv, minv = math.max(r, g, b), math.min(r, g, b)
    local h, s, v = 0, 0, maxv
    local d = maxv - minv
    if maxv ~= 0 then s = d / maxv end
    if maxv == minv then
        h = 0
    else
        if maxv == r then
            h = (g - b) / d + (g < b and 6 or 0)
        elseif maxv == g then
            h = (b - r) / d + 2
        else
            h = (r - g) / d + 4
        end
        h = h * (1/6)
    end
    return h, s, v
end

-- === FUNCTIONS ===
local function initIgnoredModels()
    ignoredModels = {}
    local homePos = ws:FindFirstChild("HomePosition")
    local awayPos = ws:FindFirstChild("AwayPosition")
    if homePos and homePos:IsA("Model") then
        table.insert(ignoredModels, homePos)
    end
    if awayPos and awayPos:IsA("Model") then
        table.insert(ignoredModels, awayPos)
    end
end

local function shouldIgnorePart(part)
    if not part or not part:IsA("BasePart") then return true end
    for _, model in ipairs(ignoredModels) do
        if part:IsDescendantOf(model) then return true end
    end
    if part.Transparency > 0.9 then return true end
    if part.Name:find("Decal") or part.Name:find("Texture") then return true end
    return not part.CanCollide
end

local function drawSmoothEndpoint(pos)
    if not pos then
        for _, l in ipairs(endpointLines) do l.Visible = false end
        return
    end
    local cam = ws.CurrentCamera
    if not cam then return end
    local step = (math.pi * 2) / 32
    local offsetY = math.sin(tick() * 2) * 0.3
    for i = 1, 32 do
        local angle1 = (i-1) * step
        local angle2 = i * step
        local p1 = pos + Vector3.new(math.cos(angle1) * endpointRadius, offsetY, math.sin(angle1) * endpointRadius)
        local p2 = pos + Vector3.new(math.cos(angle2) * endpointRadius, offsetY, math.sin(angle2) * endpointRadius)
        local screen1 = cam:WorldToViewportPoint(p1)
        local screen2 = cam:WorldToViewportPoint(p2)
        local line = endpointLines[i]
        if screen1.Z > 0 and screen2.Z > 0 then
            line.From = Vector2.new(screen1.X, screen1.Y)
            line.To = Vector2.new(screen2.X, screen2.Y)
            line.Visible = true
        else
            line.Visible = false
        end
    end
end

local function predictTrajectory(ball)
    local points = {}
    local pos, vel = ball.Position, ball.Velocity
    if vel.Magnitude < 8 then return {pos} end
    local dt = CONFIG.DT
    local gravity = Vector3.new(0, -CONFIG.GRAVITY, 0)
    local drag = CONFIG.DRAG
    local spinEffect = Vector3.new(0, 0, 0)
    pcall(function()
        if ws.Bools and ws.Bools.Curve and ws.Bools.Curve.Value then
            spinEffect = ball.CFrame.RightVector * CONFIG.CURVE_MULT * 0.025
        end
        if ws.Bools and ws.Bools.Header and ws.Bools.Header.Value then
            spinEffect = spinEffect + Vector3.new(0, 22, 0)
        end
    end)
    local rayParams = RaycastParams.new()
    rayParams.FilterType = Enum.RaycastFilterType.Exclude
    rayParams.RespectCanCollide = true
    rayParams.IgnoreWater = true
    local maxBounces = 4
    local bounceCount = 0
    local pointIndex = 0
    for step = 1, CONFIG.PRED_STEPS do
        if step % 4 == 1 or step == 1 then
            pointIndex = pointIndex + 1
            points[pointIndex] = pos
        end
        local spinMultiplier = math.max(0, 1 - (step / CONFIG.PRED_STEPS) * CONFIG.CURVE_FADE_RATE)
        spinMultiplier = spinMultiplier * math.clamp(vel.Magnitude / 80, 0.3, 1)
        vel = vel * drag + (spinEffect * spinMultiplier * dt)
        vel = vel + (gravity * dt)
        local newPos = pos + (vel * dt)
        local rayDirection = newPos - pos
        local hit = false
        if CONFIG.UseRaycast and rayDirection.Magnitude > CONFIG.MIN_HIT_DISTANCE then
            rayParams.FilterDescendantsInstances = {ball}
            local rayResult = ws:Raycast(pos, rayDirection.Unit * rayDirection.Magnitude * CONFIG.RAYCAST_LENGTH_MULT, rayParams)
            if rayResult and rayResult.Instance and not shouldIgnorePart(rayResult.Instance) then
                local normal = rayResult.Normal
                local hitPos = rayResult.Position
                pos = hitPos + (normal * 0.05)
                local normalDot = vel:Dot(normal)
                if normalDot < 0 then
                    vel = vel - (normal * normalDot * 2.1)
                    vel = vel * 0.74
                    bounceCount = bounceCount + 1
                    if bounceCount >= maxBounces then vel = vel * 0.4 end
                end
                hit = true
            end
        end
        if not hit then pos = newPos end
        if pos.Y < 0.3 then
            pos = Vector3.new(pos.X, 0.3, pos.Z)
            if math.abs(vel.Y) > 4 then
                vel = Vector3.new(vel.X * CONFIG.BOUNCE_XZ, math.abs(vel.Y) * CONFIG.BOUNCE_Y, vel.Z * CONFIG.BOUNCE_XZ)
                bounceCount = bounceCount + 1
                pointIndex = pointIndex + 1
                points[pointIndex] = pos
            else
                vel = Vector3.new(vel.X * 0.4, 0, vel.Z * 0.4)
                if vel.Magnitude < 2 then
                    pointIndex = pointIndex + 1
                    points[pointIndex] = pos
                    break
                end
            end
        end
        if pos.Y > 200 or pos.Magnitude > 500 then break end
    end
    return points
end

local function renderSmoothTrajectory(points)
    if not points or #points < 2 then
        for _, line in ipairs(trajLines) do line.Visible = false end
        drawSmoothEndpoint(nil)
        return
    end
    local cam = ws.CurrentCamera
    if not cam then return end
    local ball = ws:FindFirstChild("ball")
    if not ball then return end
    local timeOffset = tick() * 0.5
    local pulse = 0.5 + math.sin(timeOffset) * 0.3
    local visibleLines = 0
    local lastScreenPos = nil
    for i = 1, math.min(#points - 1, CONFIG.MAX_PRED_STEPS) do
        if (points[i] - ball.Position).Magnitude > CONFIG.MAX_DRAW_DISTANCE then
            trajLines[i].Visible = false
            break
        end
        local screenPos1 = cam:WorldToViewportPoint(points[i])
        local screenPos2 = cam:WorldToViewportPoint(points[i + 1])
        if screenPos1.Z > 0 and screenPos2.Z > 0 then
            local fromPos, toPos
            if lastScreenPos then
                fromPos = Vector2.new(lastScreenPos.X * 0.15 + screenPos1.X * 0.85, lastScreenPos.Y * 0.15 + screenPos1.Y * 0.85)
            else
                fromPos = Vector2.new(screenPos1.X, screenPos1.Y)
            end
            toPos = Vector2.new(screenPos2.X, screenPos2.Y)
            local line = trajLines[i]
            line.From = fromPos
            line.To = toPos
            line.Visible = true
            local distanceFactor = 1 - (i / CONFIG.MAX_PRED_STEPS) * 0.7
            line.Thickness = 1.8 + (distanceFactor * pulse * 0.8)
            visibleLines = visibleLines + 1
            lastScreenPos = screenPos2
        else
            trajLines[i].Visible = false
            lastScreenPos = nil
        end
    end
    for i = visibleLines + 1, CONFIG.MAX_PRED_STEPS do
        trajLines[i].Visible = false
    end
    if visibleLines > 3 and points[#points] then
        drawSmoothEndpoint(points[#points])
        cachedEndpoint = points[#points]
    else
        drawSmoothEndpoint(nil)
        cachedEndpoint = nil
    end
end

local function clearAllVisuals()
    for _, line in ipairs(trajLines) do line.Visible = false end
    for _, line in ipairs(endpointLines) do line.Visible = false end
end

local function UpdateTrajColors()
    local h0, s, v = Color3ToHSV(CONFIG.TrajectoryColor)
    for i = 1, CONFIG.MAX_PRED_STEPS do
        local l = trajLines[i]
        if l then
            local dh = (i / CONFIG.MAX_PRED_STEPS) * 0.7
            l.Color = Color3.fromHSV((h0 + dh) % 1, s, v)
        end
    end
end

local function UpdateEndpointColors()
    for _, l in ipairs(endpointLines) do
        if l then l.Color = CONFIG.EndpointColor end
    end
end

local function SetupVisuals()
    -- Clear old
    for _, l in ipairs(trajLines) do if l and l.Remove then l:Remove() end end
    for _, l in ipairs(endpointLines) do if l and l.Remove then l:Remove() end end
    trajLines = {}
    endpointLines = {}
    -- Endpoint
    for i = 1, 32 do
        local l = Drawing.new("Line")
        l.Thickness = 2.6
        l.Transparency = 0.55
        endpointLines[i] = l
    end
    -- Trajectory
    for i = 1, CONFIG.MAX_PRED_STEPS do
        local l = Drawing.new("Line")
        l.Thickness = 2.0
        l.Transparency = 0.4 + (i / CONFIG.MAX_PRED_STEPS) * 0.3
        trajLines[i] = l
    end
    UpdateTrajColors()
    UpdateEndpointColors()
end

local function ClearVisuals()
    clearAllVisuals()
    for _, l in ipairs(trajLines) do if l and l.Remove then l:Remove() end end
    for _, l in ipairs(endpointLines) do if l and l.Remove then l:Remove() end end
    trajLines = {}
    endpointLines = {}
end

-- === START/STOP ===
function BallTrajectoryModule.Start()
    if Status.Running then return end
    Status.Running = true
    initIgnoredModels()
    SetupVisuals()
    Status.IgnoredConn = ws.DescendantAdded:Connect(function()
        initIgnoredModels()
    end)
    Status.RenderConnection = rs.RenderStepped:Connect(function(deltaTime)
        if not CONFIG.Enabled then
            if trajLines[1] and trajLines[1].Visible then clearAllVisuals() end
            return
        end
        local currentTime = tick()
        local timeSinceLastRender = currentTime - lastRenderTime
        lastRenderTime = currentTime
        renderDelta = math.min(timeSinceLastRender, 1/30)
        local ball = ws:FindFirstChild("ball")
        if not ball then
            if cachedPoints then
                clearAllVisuals()
                cachedPoints = nil
                cachedEndpoint = nil
            end
            return
        end
        local hasWeld = ball:FindFirstChild("playerWeld")
        local owner = ball:FindFirstChild("creator") and ball.creator.Value
        local isShot = not hasWeld and owner
        local ballVel = ball.Velocity
        local ballSpeed = ballVel.Magnitude
        if ballSpeed > 20 and lastBallVelMag <= 20 then
            cachedPoints = nil
            clearAllVisuals()
        end
        lastBallVelMag = ballSpeed
        if isShot and ballSpeed > CONFIG.PRED_UPDATE_MIN_VEL then
            local shouldUpdate = false
            if not cachedPoints then
                shouldUpdate = true
            elseif (ball.Position - lastBallPos).Magnitude > 0.3 then
                local timeSinceLastPred = currentTime - lastPredictionTime
                if timeSinceLastPred > CONFIG.MIN_TIME_BETWEEN_PRED then
                    shouldUpdate = true
                end
            end
            if shouldUpdate then
                cachedPoints = predictTrajectory(ball)
                lastPredictionTime = currentTime
                lastBallPos = ball.Position
            end
        elseif cachedPoints then
            cachedPoints = nil
            cachedEndpoint = nil
            clearAllVisuals()
        end
        if cachedPoints and #cachedPoints > 1 then
            renderSmoothTrajectory(cachedPoints)
        else
            clearAllVisuals()
        end
    end)
    notify("BallTrajectory", "Started", true)
end

function BallTrajectoryModule.Stop()
    if Status.RenderConnection then
        Status.RenderConnection:Disconnect()
        Status.RenderConnection = nil
    end
    if Status.IgnoredConn then
        Status.IgnoredConn:Disconnect()
        Status.IgnoredConn = nil
    end
    clearAllVisuals()
    Status.Running = false
    notify("BallTrajectory", "Stopped", true)
end

-- === UI ===
local uiElements = {}
function BallTrajectoryModule.SetupUI(UI)
    if UI.Sections.TrajectoryPrediction then
        local section = UI.Sections.TrajectoryPrediction
        section:Header({ Name = "Trajectory Visualizer" })
        section:Divider()
        uiElements.Enabled = section:Toggle({
            Name = "Enabled",
            Default = CONFIG.Enabled,
            Callback = function(v)
                CONFIG.Enabled = v
                if v then
                    BallTrajectoryModule.Start()
                else
                    BallTrajectoryModule.Stop()
                end
            end
        }, "TrajectoryEnabled")
        uiElements.Raycast = section:Toggle({
            Name = "Raycast",
            Default = CONFIG.UseRaycast,
            Callback = function(v)
                CONFIG.UseRaycast = v
            end
        }, "TrajectoryRaycast")
        section:Divider()
        uiElements.PredSteps = section:Slider({
            Name = "Pred Steps",
            Minimum = 100,
            Maximum = 400,
            Default = CONFIG.PRED_STEPS,
            Precision = 0,
            Callback = function(v)
                CONFIG.PRED_STEPS = v
            end
        }, "TrajectoryPredSteps")
        section:Divider()
        uiElements.TrajColor = section:Colorpicker({
            Name = "Trajectory Color",
            Default = CONFIG.TrajectoryColor,
            Callback = function(c)
                CONFIG.TrajectoryColor = c
                if trajLines[1] then
                    UpdateTrajColors()
                end
            end
        }, "TrajectoryTrajColor")
        uiElements.EndpointColor = section:Colorpicker({
            Name = "Endpoint Color",
            Default = CONFIG.EndpointColor,
            Callback = function(c)
                CONFIG.EndpointColor = c
                if endpointLines[1] then
                    UpdateEndpointColors()
                end
            end
        }, "TrajectoryEndpointColor")
    end

    -- Sync Config Button
    if UI.Tabs and UI.Tabs.Config then
        local syncSection = UI.Tabs.Config:Section({ Name = "Ball Trajectory Sync", Side = "Right" })
        syncSection:Header({ Name = "TrajectoryPrediction" })
        syncSection:Button({
            Name = "Sync Config",
            Callback = function()
                if uiElements.Enabled then CONFIG.Enabled = uiElements.Enabled:GetState() end
                if uiElements.Raycast then CONFIG.UseRaycast = uiElements.Raycast:GetState() end
                if uiElements.PredSteps then CONFIG.PRED_STEPS = uiElements.PredSteps:GetValue() end
                if CONFIG.Enabled then
                    if not Status.Running then
                        BallTrajectoryModule.Start()
                    end
                else
                    if Status.Running then
                        BallTrajectoryModule.Stop()
                    end
                end
                UpdateTrajColors()
                UpdateEndpointColors()
                notify("BallTrajectory", "Config synchronized!", true)
            end
        })
    end
end

-- === MODULE ===
function BallTrajectoryModule.Init(UI, coreParam, notifyFunc)
    notify = notifyFunc
    BallTrajectoryModule.SetupUI(UI)
    initIgnoredModels()
    if CONFIG.Enabled then
        BallTrajectoryModule.Start()
    end
end

function BallTrajectoryModule:Destroy()
    BallTrajectoryModule.Stop()
    ClearVisuals()
end

return BallTrajectoryModule
