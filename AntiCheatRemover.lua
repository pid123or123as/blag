local AntiCheatRemover = {}
print('2')

-- ====================== CONFIG ======================
AntiCheatRemover.Config = {
    DevConsoleBypass = {
        Enabled = false,
        ToggleKey = nil
    },
    BaseACBypass = {
        Enabled = false,
        ToggleKey = nil
    },
    MobileCameraACBypass = {
        Enabled = false,
        ToggleKey = nil
    }
}

-- ====================== STATUS TABLES ======================
local DevConsoleBypassStatus = {
    Running = false,
    Enabled = AntiCheatRemover.Config.DevConsoleBypass.Enabled,
    Status = "Disabled",
    ScriptName = "None",
    FoundScript = nil,
    label = nil,
    Connection = nil
}

local BaseACBypassStatus = {
    Running = false,
    Enabled = AntiCheatRemover.Config.BaseACBypass.Enabled,
    Status = "Disabled",
    ScriptName = "None",
    FoundScript = nil,
    label = nil
}

local MobileCameraACStatus = {
    Running = false,
    Enabled = AntiCheatRemover.Config.MobileCameraACBypass.Enabled,
    Status = "Disabled",
    ScriptName = "None",
    FoundScript = nil,
    label = nil,
    MethodUsed = 1
}

-- ====================== SERVICES & HELPERS ======================
local Services = nil
local notify = nil
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local function updateDevConsoleLabel()
    if DevConsoleBypassStatus.label then
        DevConsoleBypassStatus.label:UpdateName("Status: " .. DevConsoleBypassStatus.Status .. " | Pointer: " .. DevConsoleBypassStatus.ScriptName)
    end
end

local function updateBaseACLabel()
    if BaseACBypassStatus.label then
        BaseACBypassStatus.label:UpdateName("Status: " .. BaseACBypassStatus.Status .. " | Pointer: " .. BaseACBypassStatus.ScriptName)
    end
end

local function updateMobileCameraLabel()
    if MobileCameraACStatus.label then
        MobileCameraACStatus.label:UpdateName("Status: " .. MobileCameraACStatus.Status .. " | Pointer: " .. MobileCameraACStatus.ScriptName)
    end
end

-- ====================== NEUTRALIZE FUNCTIONS ======================
local function neutralizeCoreGuiSetter(scriptObj, mainClosure)
    if not scriptObj or not mainClosure then return false end

    DevConsoleBypassStatus.FoundScript = scriptObj
    DevConsoleBypassStatus.ScriptName = scriptObj.Name
    DevConsoleBypassStatus.Status = "Neutralized"
    updateDevConsoleLabel()

    pcall(function()
        scriptObj.Disabled = true
        scriptObj:Destroy()
    end)

    local constants = debug.getconstants(mainClosure)
    if constants and #constants == 28 then
        for i = 1, 28 do
            pcall(debug.setconstant, mainClosure, i, "broken_" .. math.random(1000, 9999))
        end
    end

    notify("AntiCheatRemover", "DevConsole unlocked", false)
    return true
end

local function neutralizeAdvertisementHandler(scriptObj, mainClosure)
    if not scriptObj or not mainClosure or not scriptObj.Parent then return false end

    BaseACBypassStatus.FoundScript = scriptObj
    BaseACBypassStatus.ScriptName = scriptObj.Name
    BaseACBypassStatus.Status = "Neutralized"
    updateBaseACLabel()

    local constants = debug.getconstants(mainClosure)
    if constants and #constants == 35 then
        for i = 1, #constants do
            pcall(debug.setconstant, mainClosure, i, "BASE_BROKEN_" .. math.random(10000, 99999))
        end
    end

    notify("AntiCheatRemover", "Base AC broken", false)
    return true
end

local function neutralizeMobileCameraAC(scriptObj, mainClosure, method)
    if not scriptObj or not mainClosure then return false end

    MobileCameraACStatus.FoundScript = scriptObj
    MobileCameraACStatus.ScriptName = scriptObj.Name
    MobileCameraACStatus.Status = "Neutralized"
    MobileCameraACStatus.MethodUsed = method or 1
    updateMobileCameraLabel()

    local constants = debug.getconstants(mainClosure)
    if constants then
        for i = 1, #constants do
            pcall(debug.setconstant, mainClosure, i, "MC_BROKEN_" .. math.random(10000, 99999))
        end
    end

    if debug.getproto then
        for protoIndex = 1, 30 do
            local success, proto = pcall(debug.getproto, mainClosure, protoIndex)
            if not success or not proto then break end
            
            local protoConstants = debug.getconstants(proto)
            if protoConstants then
                for i = 1, #protoConstants do
                    pcall(debug.setconstant, proto, i, "PROTO_BROKEN_" .. math.random(1000, 9999))
                end
            end
        end
    end

    pcall(function()
        scriptObj.Disabled = true
        scriptObj:Destroy()
    end)

    notify("AntiCheatRemover", "Character bypassed", false)
    return true
end

-- ====================== SCAN FUNCTIONS ======================
-- DEV CONSOLE: ТОЛЬКО в PlayerGui (не в его дочерних объектах!)
local function scanCoreGuiSetter()
    if not DevConsoleBypassStatus.Enabled or DevConsoleBypassStatus.Status == "Neutralized" then return false end

    DevConsoleBypassStatus.Status = "Scanning..."
    DevConsoleBypassStatus.ScriptName = "Searching..."
    updateDevConsoleLabel()

    -- Ждем PlayerGui
    local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
    if not playerGui then
        DevConsoleBypassStatus.Status = "No PlayerGui"
        updateDevConsoleLabel()
        return false
    end

    -- Ищем ТОЛЬКО прямо в PlayerGui, не в его дочерних объектах
    for _, obj in ipairs(playerGui:GetChildren()) do
        if not obj:IsA("LocalScript") then continue end
        
        local mainClosure = getscriptclosure and getscriptclosure(obj)
        if not mainClosure or not islclosure(mainClosure) then continue end
        
        local upvalues = debug.getupvalues(mainClosure)
        if upvalues and #upvalues ~= 0 then continue end
        
        local constants = debug.getconstants(mainClosure)
        if constants and #constants == 28 then
            DevConsoleBypassStatus.Status = "Found"
            updateDevConsoleLabel()
            neutralizeCoreGuiSetter(obj, mainClosure)
            return true
        end
    end
    
    DevConsoleBypassStatus.Status = "Not found"
    updateDevConsoleLabel()
    return false
end

-- BASE AC: В ReplicatedFirst
local function scanAdvertisementHandler()
    if not BaseACBypassStatus.Enabled or BaseACBypassStatus.Status == "Neutralized" then return end

    BaseACBypassStatus.Status = "Scanning..."
    BaseACBypassStatus.ScriptName = "Searching..."
    updateBaseACLabel()

    local replicatedFirst = game:GetService("ReplicatedFirst")
    if not replicatedFirst then return end

    for _, obj in ipairs(replicatedFirst:GetChildren()) do
        if not obj:IsA("LocalScript") then continue end
        local mainClosure = getscriptclosure and getscriptclosure(obj)
        if not mainClosure or not islclosure(mainClosure) then continue end
        local upvalues = debug.getupvalues(mainClosure)
        if upvalues and #upvalues ~= 0 then continue end
        local constants = debug.getconstants(mainClosure)
        if constants and #constants == 35 then
            BaseACBypassStatus.Status = "Found"
            updateBaseACLabel()
            neutralizeAdvertisementHandler(obj, mainClosure)
            return
        end
    end
    
    BaseACBypassStatus.Status = "Not found"
    updateBaseACLabel()
end

-- MOBILE CAMERA: Метод 1 (87 констант)
local function scanMobileCameraACMethod1()
    if not MobileCameraACStatus.Enabled or MobileCameraACStatus.Status == "Neutralized" then return false end

    MobileCameraACStatus.Status = "Scanning [M1]..."
    MobileCameraACStatus.ScriptName = "Searching..."
    updateMobileCameraLabel()

    local character = LocalPlayer.Character
    if not character then return false end

    for _, child in ipairs(character:GetChildren()) do
        if not child:IsA("LocalScript") then continue end

        local mainClosure = getscriptclosure and getscriptclosure(child)
        if not mainClosure or not islclosure(mainClosure) then continue end

        local constants = debug.getconstants(mainClosure)
        if constants and #constants == 87 then
            MobileCameraACStatus.Status = "Found [M1]"
            updateMobileCameraLabel()
            neutralizeMobileCameraAC(child, mainClosure, 1)
            return true
        end
    end
    
    return false
end

-- MOBILE CAMERA: Метод 2 (72 константы + 20 protos)
local function scanMobileCameraACMethod2()
    if not MobileCameraACStatus.Enabled or MobileCameraACStatus.Status == "Neutralized" then return false end

    MobileCameraACStatus.Status = "Scanning [M2]..."
    MobileCameraACStatus.ScriptName = "Searching..."
    updateMobileCameraLabel()

    local character = LocalPlayer.Character
    if not character then return false end

    for _, child in ipairs(character:GetChildren()) do
        if not child:IsA("LocalScript") then continue end

        local mainClosure = getscriptclosure and getscriptclosure(child)
        if not mainClosure then continue end

        local constants = debug.getconstants(mainClosure)
        if not constants or #constants ~= 72 then continue end

        local protoCount = 0
        if debug.getproto then
            for i = 1, 25 do
                local success, proto = pcall(debug.getproto, mainClosure, i)
                if not success or not proto then break end
                protoCount = protoCount + 1
            end
        end

        if protoCount == 20 then
            MobileCameraACStatus.Status = "Found [M2]"
            updateMobileCameraLabel()
            neutralizeMobileCameraAC(child, mainClosure, 2)
            return true
        end
    end
    
    return false
end

-- Общая функция сканирования Mobile Camera
local function scanMobileCameraAC()
    if MobileCameraACStatus.MethodUsed == 1 then
        if scanMobileCameraACMethod1() then
            return true
        else
            MobileCameraACStatus.MethodUsed = 2
            return scanMobileCameraACMethod2()
        end
    else
        return scanMobileCameraACMethod2()
    end
end

-- ====================== START/STOP ======================
local function startDevConsoleBypass()
    if DevConsoleBypassStatus.Running then return end
    DevConsoleBypassStatus.Running = true
    
    -- Сканируем сразу
    scanCoreGuiSetter()
    
    -- При респавне сканируем снова
    if DevConsoleBypassStatus.Connection then
        DevConsoleBypassStatus.Connection:Disconnect()
    end
    
    DevConsoleBypassStatus.Connection = LocalPlayer.CharacterAdded:Connect(function()
        task.wait(2)
        if DevConsoleBypassStatus.Running then
            DevConsoleBypassStatus.FoundScript = nil
            DevConsoleBypassStatus.ScriptName = "None"
            DevConsoleBypassStatus.Status = "Rescanning..."
            updateDevConsoleLabel()
            scanCoreGuiSetter()
        end
    end)
    
    -- Периодическое сканирование
    while DevConsoleBypassStatus.Running do
        task.wait(5)
        if DevConsoleBypassStatus.Status ~= "Neutralized" then
            scanCoreGuiSetter()
        end
    end
end

local function startBaseACBypass()
    if BaseACBypassStatus.Running then return end
    BaseACBypassStatus.Running = true
    
    scanAdvertisementHandler()
    
    while BaseACBypassStatus.Running do
        task.wait(5)
        if BaseACBypassStatus.Status ~= "Neutralized" then
            scanAdvertisementHandler()
        end
    end
end

local function startMobileCameraBypass()
    if MobileCameraACStatus.Running then return end
    MobileCameraACStatus.Running = true
    
    scanMobileCameraAC()
    
    LocalPlayer.CharacterAdded:Connect(function()
        task.wait(1.5)
        if MobileCameraACStatus.Running then
            MobileCameraACStatus.FoundScript = nil
            MobileCameraACStatus.ScriptName = "None"
            MobileCameraACStatus.Status = "Rescanning..."
            MobileCameraACStatus.MethodUsed = 1
            updateMobileCameraLabel()
            scanMobileCameraAC()
        end
    end)
    
    while MobileCameraACStatus.Running do
        task.wait(5)
        if MobileCameraACStatus.Status ~= "Neutralized" then
            scanMobileCameraAC()
        end
    end
end

-- ====================== UI SETUP ======================
local function SetupUI(UI)
    if UI.Sections.AntiCheatRemover then
        UI.Sections.AntiCheatRemover:Header({ Name = "AntiCheat Remover" })

        UI.Sections.AntiCheatRemover:Toggle({
            Name = "Bypass DevConsole",
            Default = AntiCheatRemover.Config.DevConsoleBypass.Enabled,
            Callback = function(value)
                AntiCheatRemover.Config.DevConsoleBypass.Enabled = value
                DevConsoleBypassStatus.Enabled = value
                if value then
                    startDevConsoleBypass()
                else
                    DevConsoleBypassStatus.Running = false
                    DevConsoleBypassStatus.Status = "Disabled"
                    updateDevConsoleLabel()
                end
            end
        }, 'BypassDevConsole')

        DevConsoleBypassStatus.label = UI.Sections.AntiCheatRemover:SubLabel({
            Text = "Status: " .. DevConsoleBypassStatus.Status .. " | Pointer: " .. DevConsoleBypassStatus.ScriptName
        })

        UI.Sections.AntiCheatRemover:Toggle({
            Name = "Bypass BaseAC",
            Default = AntiCheatRemover.Config.BaseACBypass.Enabled,
            Callback = function(value)
                AntiCheatRemover.Config.BaseACBypass.Enabled = value
                BaseACBypassStatus.Enabled = value
                if value then
                    startBaseACBypass()
                else
                    BaseACBypassStatus.Running = false
                    BaseACBypassStatus.Status = "Disabled"
                    updateBaseACLabel()
                end
            end
        }, 'BypassBaseAC')

        BaseACBypassStatus.label = UI.Sections.AntiCheatRemover:SubLabel({
            Text = "Status: " .. BaseACBypassStatus.Status .. " | Pointer: " .. BaseACBypassStatus.ScriptName
        })

        UI.Sections.AntiCheatRemover:Toggle({
            Name = "Bypass Character",
            Default = AntiCheatRemover.Config.MobileCameraACBypass.Enabled,
            Callback = function(value)
                AntiCheatRemover.Config.MobileCameraACBypass.Enabled = value
                MobileCameraACStatus.Enabled = value
                if value then
                    startMobileCameraBypass()
                else
                    MobileCameraACStatus.Running = false
                    MobileCameraACStatus.Status = "Disabled"
                    updateMobileCameraLabel()
                end
            end
        }, 'BypassCharacter')

        MobileCameraACStatus.label = UI.Sections.AntiCheatRemover:SubLabel({
            Text = "Status: " .. MobileCameraACStatus.Status .. " | Pointer: " .. MobileCameraACStatus.ScriptName
        })
    end
end

-- ====================== INIT ======================
function AntiCheatRemover.Init(UI, coreParam, notifyFunc)
    Services = coreParam.Services
    notify = notifyFunc

    SetupUI(UI)

    if AntiCheatRemover.Config.DevConsoleBypass.Enabled then
        startDevConsoleBypass()
    end
    
    if AntiCheatRemover.Config.BaseACBypass.Enabled then
        startBaseACBypass()
    end
    
    if AntiCheatRemover.Config.MobileCameraACBypass.Enabled then
        startMobileCameraBypass()
    end
end

return AntiCheatRemover
