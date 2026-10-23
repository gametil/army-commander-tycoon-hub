--[[
    Army Commander Tycoon - WindUI Automation Hub
    Reverse engineered & automated via Real MCP
    WindUI Modern Interface
    Includes: Auto Upgrade, AFK Auto Pump Oil, Anti-AFK, Army Deployment, Rebirth, Player Mods
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local VirtualUser = game:GetService("VirtualUser")

local LocalPlayer = Players.LocalPlayer
local Character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()

-- Teardown previous instances if running via Real MCP live-reload or standalone
if getgenv and getgenv()._ArmyCommanderHubTeardown then
    pcall(getgenv()._ArmyCommanderHubTeardown)
end

-- Wait for game core modules
local Frontier = ReplicatedStorage:WaitForChild("Frontier", 30)
if not Frontier then
    warn("[Hub] Frontier folder not found in ReplicatedStorage")
    return
end

local Buildings = require(Frontier.Config.Buildings)
local PointsModule = require(Frontier.Config.Points)
local Store = require(LocalPlayer.PlayerScripts.Frontier.UI.Store)

-- Load WindUI
local WindUI = loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()

-- Create Window
local Window = WindUI:CreateWindow({
    Title = "Army Commander Tycoon",
    Icon = "shield",
    Author = "by Antigravity & WindUI",
    Folder = "ArmyCommanderHub",
    Size = UDim2.fromOffset(630, 500),
    Theme = "Dark",
    Transparent = true,
    Resizable = true,
    HideSearchBar = false,
    ScrollBarEnabled = true,
    OpenButton = {
        Title = "Open Commander Hub",
        Icon = "shield",
        CornerRadius = UDim.new(0, 16),
        StrokeThickness = 2,
        Color = ColorSequence.new(
            Color3.fromHex("3B82F6"),
            Color3.fromHex("1D4ED8")
        ),
        OnlyMobile = false,
        Enabled = true,
        Draggable = true,
    }
})

-- State Variables
local HubState = {
    Running = true,
    -- Tycoon Upgrades
    AutoUpgrade = false,
    UpgradePriority = "Cheapest First",
    UpgradeDelay = 0.5,
    AutoClaimDaily = true,
    -- AFK Auto Pump Oil
    AutoPump = false,
    LockAtPump = true,
    PumpStrokeDelay = 0.48,
    PumpStrokesCount = 0,
    PumpCashEarned = 0,
    LastPumpStroke = 0,
    -- Rebirth & Conquest
    AutoRebirth = false,
    AutoConquest = false,
    ConquestTarget = "Central Airfield",
    -- Player Mods
    CustomSpeed = 16,
    SpeedEnabled = false,
    CustomJump = 50,
    JumpEnabled = false,
    InfJump = false,
    NightVision = false,
    AntiAFK = true,
    -- Internals
    Connections = {},
    LastUpgradeTime = 0,
    LastDailyCheck = 0,
    LastConquestCheck = 0,
}

-- Cleanup function
local function Cleanup()
    HubState.Running = false
    for _, conn in ipairs(HubState.Connections) do
        pcall(function() conn:Disconnect() end)
    end
    table.clear(HubState.Connections)
    
    -- Reset character modifications
    if LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Humanoid") then
        pcall(function()
            LocalPlayer.Character.Humanoid.WalkSpeed = 16
            LocalPlayer.Character.Humanoid.UseJumpPower = true
            LocalPlayer.Character.Humanoid.JumpPower = 50
        end)
    end
    
    pcall(function() Window:Destroy() end)
end

if getgenv then
    getgenv()._ArmyCommanderHubTeardown = Cleanup
end

if typeof(STATE) == "table" and STATE.onCleanup then
    STATE.onCleanup(Cleanup)
end

-- ====================
-- HELPER FUNCTIONS
-- ====================

local function FormatMoney(val)
    val = tonumber(val) or 0
    if val >= 1e9 then
        return string.format("$%.2fB", val / 1e9)
    elseif val >= 1e6 then
        return string.format("$%.2fM", val / 1e6)
    elseif val >= 1e3 then
        return string.format("$%.1fK", val / 1e3)
    else
        return string.format("$%d", math.floor(val))
    end
end

-- Get plot instance
local function GetPlayerPlot()
    local plotId = LocalPlayer:GetAttribute("PlotId")
    if not plotId then return nil end
    local plots = workspace:FindFirstChild("Plots")
    return plots and plots:FindFirstChild("Plot" .. tostring(plotId))
end

-- Get Handpump parts & Stand position
local function GetHandpumpData()
    local plot = GetPlayerPlot()
    local hp = plot and plot.Buildings:FindFirstChild("handpump")
    if not hp then return nil, nil, nil end

    local stand = hp:FindFirstChild("StandPoint", true)
    local prompt = hp:FindFirstChildWhichIsA("ProximityPrompt", true)
    local pivot = hp:GetPivot()
    local standPos = stand and stand.WorldPosition or (pivot.Position + Vector3.new(0, 0, 2))

    return hp, standPos, prompt
end

-- Teleport to Handpump stand
local function TeleportToPumpStand()
    local hp, standPos = GetHandpumpData()
    if hp and standPos and LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart") then
        LocalPlayer.Character.HumanoidRootPart.CFrame = CFrame.new(standPos + Vector3.new(0, 2.5, 0), hp:GetPivot().Position)
        LocalPlayer.Character.HumanoidRootPart.AssemblyLinearVelocity = Vector3.zero
        LocalPlayer.Character.HumanoidRootPart.AssemblyAngularVelocity = Vector3.zero
    end
end

-- Get all available buildings that can be upgraded
local function GetUpgradeableBuildings()
    local base = Store.get("base") or {levels = {}}
    local currentCash = Store.cash()
    local list = {}

    for id, def in pairs(Buildings.DEFS) do
        local ok, reason, nextLevel = Buildings.canBuild(base.levels, id)
        if ok and nextLevel then
            local isIncome = (nextLevel.income and nextLevel.income > 0)
                or (nextLevel.incomeMul and nextLevel.incomeMul > 0)
                or (id:find("rig") ~= nil)
                or (id == "refinery")
                or (id == "handpump")
                or (id == "generator")
                or (id == "oilfield")
                or (id == "depot")

            table.insert(list, {
                id = id,
                name = def.name or id,
                level = nextLevel.level,
                maxLevel = #def.levels,
                cost = nextLevel.cost,
                isIncome = isIncome,
                isHQ = (id == "hq"),
                canAfford = (nextLevel.cost <= currentCash)
            })
        end
    end

    return list
end

-- Perform a single upgrade based on priority
local function UpgradeOne(priority)
    local list = GetUpgradeableBuildings()
    local affordable = {}
    for _, item in ipairs(list) do
        if item.canAfford then
            table.insert(affordable, item)
        end
    end

    if #affordable == 0 then
        return false, "No affordable upgrades"
    end

    if priority == "Cheapest First" then
        table.sort(affordable, function(a, b) return a.cost < b.cost end)
        local target = affordable[1]
        local ok, err = Store.call("Build", target.id)
        return ok, target.name, target.cost
    elseif priority == "Income First" then
        local incomeAffordable = {}
        for _, item in ipairs(affordable) do
            if item.isIncome then table.insert(incomeAffordable, item) end
        end
        if #incomeAffordable > 0 then
            table.sort(incomeAffordable, function(a, b) return a.cost < b.cost end)
            local target = incomeAffordable[1]
            local ok, err = Store.call("Build", target.id)
            return ok, target.name, target.cost
        else
            table.sort(affordable, function(a, b) return a.cost < b.cost end)
            local target = affordable[1]
            local ok, err = Store.call("Build", target.id)
            return ok, target.name, target.cost
        end
    elseif priority == "HQ First" then
        for _, item in ipairs(affordable) do
            if item.isHQ then
                local ok, err = Store.call("Build", item.id)
                return ok, item.name, item.cost
            end
        end
        table.sort(affordable, function(a, b) return a.cost < b.cost end)
        local target = affordable[1]
        local ok, err = Store.call("Build", target.id)
        return ok, target.name, target.cost
    else
        local target = affordable[1]
        local ok, err = Store.call("Build", target.id)
        return ok, target.name, target.cost
    end
end

-- Upgrade all affordable buildings in one go
local function UpgradeAllAffordable()
    local count = 0
    local totalSpent = 0
    while true do
        local ok, name, cost = UpgradeOne(HubState.UpgradePriority)
        if ok and cost then
            count = count + 1
            totalSpent = totalSpent + cost
            task.wait(0.08)
        else
            break
        end
    end
    return count, totalSpent
end

_G.ArmyHub = {
    State = HubState,
    TogglePump = function(val)
        if val == nil then
            HubState.AutoPump = not HubState.AutoPump
        else
            HubState.AutoPump = val
        end
        if HubState.AutoPump then
            TeleportToPumpStand()
        end
        return HubState.AutoPump
    end,
    ToggleAutoUpgrade = function(val)
        if val == nil then
            HubState.AutoUpgrade = not HubState.AutoUpgrade
        else
            HubState.AutoUpgrade = val
        end
        return HubState.AutoUpgrade
    end,
    TeleportToPump = TeleportToPumpStand,
    UpgradeAll = UpgradeAllAffordable,
    ClaimDaily = function() return Store.call("ClaimDaily") end,
}

-- Order army to point
local function OrderArmyToPoint(pointId)
    local groups = {"inf", "veh", "air", "naval"}
    local succeeded = {}
    local failed = {}

    for _, grp in ipairs(groups) do
        local ok, err = Store.call("Order", {
            group = grp,
            order = {type = "capture", pointId = pointId}
        })
        if ok then
            table.insert(succeeded, grp)
        else
            table.insert(failed, grp .. " (" .. tostring(err) .. ")")
        end
    end
    return succeeded, failed
end

-- Build capture points list
local PointsList = {}
local PointsMap = {}
for _, pt in ipairs(PointsModule.LIST or {}) do
    table.insert(PointsList, pt.name)
    PointsMap[pt.name] = pt.id
end

-- ====================
-- UI TABS SETUP
-- ====================

local TabTycoon = Window:Tab({
    Title = "Auto Tycoon & Oil",
    Icon = "wrench",
})

local TabArmy = Window:Tab({
    Title = "Army & Combat",
    Icon = "swords",
})

local TabRebirth = Window:Tab({
    Title = "Rebirth",
    Icon = "flame",
})

local TabPlayer = Window:Tab({
    Title = "Player & Teleports",
    Icon = "user",
})

local TabSettings = Window:Tab({
    Title = "Settings & Codes",
    Icon = "settings",
})

-- ===================================================
-- TAB 1: AUTO TYCOON (BASE UPGRADES & AFK OIL PUMP)
-- ===================================================

TabTycoon:Section({ Title = "Base Overview" })

local BaseInfoPara = TabTycoon:Paragraph({
    Title = "Live Base Stats",
    Desc = "Loading stats..."
})

-- SECTION: AFK AUTO PUMP OIL
TabTycoon:Section({ Title = "AFK Auto Pump Oil (Unlimited Cash Farm)" })

local PumpStatsPara = TabTycoon:Paragraph({
    Title = "AFK Oil Pump Status",
    Desc = "Status: Idle  |  Strokes: 0  |  Earned: $0"
})

TabTycoon:Toggle({
    Title = "AFK Auto Pump Oil",
    Desc = "Teleports you onto the pump stand and pumps oil indefinitely for massive cash",
    Value = false,
    Callback = function(state)
        HubState.AutoPump = state
        if state then
            TeleportToPumpStand()
            WindUI:Notify({
                Title = "AFK Auto Pump Started",
                Content = "Teleported to pump stand. Pumping oil for extra cash!",
                Duration = 3,
                Icon = "fuel"
            })
        else
            if LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Humanoid") then
                LocalPlayer.Character.Humanoid.PlatformStand = false
            end
            WindUI:Notify({
                Title = "AFK Auto Pump Stopped",
                Content = "Auto pump disabled.",
                Duration = 2,
                Icon = "x"
            })
        end
    end
})

TabTycoon:Toggle({
    Title = "Lock Position On Pump Stand",
    Desc = "Locks your character's position to prevent falling or getting bumped by tanks/jeeps",
    Value = true,
    Callback = function(state)
        HubState.LockAtPump = state
    end
})

TabTycoon:Slider({
    Title = "Pump Stroke Speed (s)",
    Desc = "Interval between pump strokes (0.45s - 0.48s is optimal for Level 3 Handpump)",
    Value = { Min = 0.4, Max = 1.0, Default = 0.48 },
    Step = 0.02,
    Callback = function(val)
        HubState.PumpStrokeDelay = val
    end
})

TabTycoon:Button({
    Title = "Teleport Directly To Pump",
    Desc = "Moves your character to the hand pump stand immediately",
    Callback = function()
        TeleportToPumpStand()
    end
})

-- SECTION: AUTO UPGRADE BUILDINGS
TabTycoon:Section({ Title = "Auto Upgrade Automation" })

TabTycoon:Toggle({
    Title = "Auto Upgrade Buildings",
    Desc = "Automatically purchases next building upgrades when cash is available",
    Value = true,
    Callback = function(state)
        HubState.AutoUpgrade = state
        WindUI:Notify({
            Title = "Auto Upgrade",
            Content = state and "Auto Upgrade Enabled!" or "Auto Upgrade Disabled.",
            Duration = 2,
            Icon = state and "check" or "x"
        })
    end
})

TabTycoon:Dropdown({
    Title = "Upgrade Priority Mode",
    Desc = "Choose how the bot decides which building to upgrade first",
    Values = {"Cheapest First", "Income First", "HQ First", "All In Order"},
    Value = "Cheapest First",
    Callback = function(val)
        HubState.UpgradePriority = val
    end
})

TabTycoon:Slider({
    Title = "Upgrade Interval Delay",
    Desc = "Delay in seconds between upgrade purchases",
    Value = { Min = 0.1, Max = 2.0, Default = 0.5 },
    Step = 0.1,
    Callback = function(val)
        HubState.UpgradeDelay = val
    end
})

TabTycoon:Section({ Title = "Manual Upgrade Actions" })

TabTycoon:Button({
    Title = "Upgrade Cheapest Building",
    Desc = "Buys the single cheapest currently affordable building",
    Callback = function()
        local ok, name, cost = UpgradeOne("Cheapest First")
        if ok then
            WindUI:Notify({
                Title = "Upgrade Purchased!",
                Content = string.format("Upgraded %s for %s", name, FormatMoney(cost)),
                Duration = 2.5,
                Icon = "check"
            })
        else
            WindUI:Notify({
                Title = "Cannot Upgrade",
                Content = tostring(name or "Not enough cash for any upgrade"),
                Duration = 2,
                Icon = "alert-circle"
            })
        end
    end
})

TabTycoon:Button({
    Title = "Upgrade All Affordable Now",
    Desc = "Immediately scans and buys every building you have cash for",
    Callback = function()
        local count, spent = UpgradeAllAffordable()
        if count > 0 then
            WindUI:Notify({
                Title = "Mass Upgrade Complete!",
                Content = string.format("Upgraded %d buildings (Spent %s)", count, FormatMoney(spent)),
                Duration = 3,
                Icon = "zap"
            })
        else
            WindUI:Notify({
                Title = "No Upgrades",
                Content = "You cannot afford any new upgrades right now.",
                Duration = 2,
                Icon = "info"
            })
        end
    end
})

TabTycoon:Section({ Title = "Daily Rewards" })

TabTycoon:Toggle({
    Title = "Auto Claim Daily Reward",
    Desc = "Automatically claims the daily crate cash reward when ready",
    Value = true,
    Callback = function(state)
        HubState.AutoClaimDaily = state
    end
})

TabTycoon:Button({
    Title = "Claim Daily Reward Now",
    Desc = "Manually trigger the daily crate cash reward claim",
    Callback = function()
        local ok, amount = Store.call("ClaimDaily")
        if ok then
            WindUI:Notify({
                Title = "Daily Claimed!",
                Content = string.format("Received reward: %s", FormatMoney(amount or 0)),
                Duration = 3,
                Icon = "gift"
            })
        else
            WindUI:Notify({
                Title = "Daily Reward",
                Content = tostring(amount or "Daily reward is not ready yet"),
                Duration = 2.5,
                Icon = "info"
            })
        end
    end
})

-- ===================================================
-- TAB 2: ARMY & COMBAT
-- ===================================================

TabArmy:Section({ Title = "Army Command & Conquest" })

local ArmyInfoPara = TabArmy:Paragraph({
    Title = "Army Status",
    Desc = "Fielded units: Loading..."
})

TabArmy:Dropdown({
    Title = "Target Strategic Point",
    Desc = "Select a point on the map to order forces to capture",
    Values = PointsList,
    Value = PointsList[1] or "Central Airfield",
    Callback = function(val)
        HubState.ConquestTarget = val
    end
})

TabArmy:Button({
    Title = "Send All Units To Target Point",
    Desc = "Dispatches all active army groups (Infantry, Vehicles, Air) to capture the point",
    Callback = function()
        local ptId = PointsMap[HubState.ConquestTarget] or "airfield"
        local succ, fail = OrderArmyToPoint(ptId)
        WindUI:Notify({
            Title = "Army Orders Sent!",
            Content = string.format("Dispatched to %s (%d groups deployed)", HubState.ConquestTarget, #succ),
            Duration = 3,
            Icon = "send"
        })
    end
})

TabArmy:Toggle({
    Title = "Auto Conquest (Capture Points)",
    Desc = "Periodically commands all units to attack the chosen strategic point",
    Value = false,
    Callback = function(state)
        HubState.AutoConquest = state
    end
})

TabArmy:Section({ Title = "Quick Tactical Orders" })

TabArmy:Button({
    Title = "Capture Central Airfield",
    Callback = function()
        OrderArmyToPoint("airfield")
        WindUI:Notify({ Title = "Airfield Order", Content = "Army dispatched to Central Airfield!", Duration = 2, Icon = "plane" })
    end
})

TabArmy:Button({
    Title = "Capture Willow Village",
    Callback = function()
        OrderArmyToPoint("village")
        WindUI:Notify({ Title = "Village Order", Content = "Army dispatched to Willow Village!", Duration = 2, Icon = "home" })
    end
})

TabArmy:Button({
    Title = "Capture Radar Hill",
    Callback = function()
        OrderArmyToPoint("radar")
        WindUI:Notify({ Title = "Radar Order", Content = "Army dispatched to Radar Hill!", Duration = 2, Icon = "radio" })
    end
})

TabArmy:Button({
    Title = "Capture Oil Refinery",
    Callback = function()
        OrderArmyToPoint("refinery")
        WindUI:Notify({ Title = "Refinery Order", Content = "Army dispatched to Oil Refinery!", Duration = 2, Icon = "flame" })
    end
})

-- ===================================================
-- TAB 3: REBIRTH / PROMOTION
-- ===================================================

TabRebirth:Section({ Title = "Promotion Status" })

local RebirthInfoPara = TabRebirth:Paragraph({
    Title = "Rank & Rebirth Info",
    Desc = "Loading rebirth data..."
})

TabRebirth:Section({ Title = "Rebirth Automation" })

TabRebirth:Toggle({
    Title = "Auto Rebirth (Promote)",
    Desc = "Automatically promotes when HQ level and cash requirements are met",
    Value = false,
    Callback = function(state)
        HubState.AutoRebirth = state
    end
})

TabRebirth:Button({
    Title = "Rebirth Now (Manual)",
    Desc = "Triggers rebirth promotion immediately if eligible",
    Callback = function()
        local ok, err = Store.call("Rebirth")
        if ok then
            WindUI:Notify({
                Title = "Rebirth Successful!",
                Content = "You have been promoted! Income bonus increased.",
                Duration = 4,
                Icon = "award"
            })
        else
            WindUI:Notify({
                Title = "Rebirth Failed",
                Content = tostring(err or "Prerequisites not met yet."),
                Duration = 3,
                Icon = "alert-triangle"
            })
        end
    end
})

-- ===================================================
-- TAB 4: PLAYER & TELEPORTS
-- ===================================================

TabPlayer:Section({ Title = "Character Modifiers" })

TabPlayer:Toggle({
    Title = "Enable Custom WalkSpeed",
    Value = false,
    Callback = function(state)
        HubState.SpeedEnabled = state
        if not state and LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Humanoid") then
            LocalPlayer.Character.Humanoid.WalkSpeed = 16
        end
    end
})

TabPlayer:Slider({
    Title = "WalkSpeed",
    Value = { Min = 16, Max = 120, Default = 16 },
    Step = 2,
    Callback = function(val)
        HubState.CustomSpeed = val
        if HubState.SpeedEnabled and LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Humanoid") then
            LocalPlayer.Character.Humanoid.WalkSpeed = val
        end
    end
})

TabPlayer:Toggle({
    Title = "Enable Custom JumpPower",
    Value = false,
    Callback = function(state)
        HubState.JumpEnabled = state
        if not state and LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Humanoid") then
            LocalPlayer.Character.Humanoid.JumpPower = 50
        end
    end
})

TabPlayer:Slider({
    Title = "JumpPower",
    Value = { Min = 50, Max = 250, Default = 50 },
    Step = 5,
    Callback = function(val)
        HubState.CustomJump = val
        if HubState.JumpEnabled and LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Humanoid") then
            LocalPlayer.Character.Humanoid.UseJumpPower = true
            LocalPlayer.Character.Humanoid.JumpPower = val
        end
    end
})

TabPlayer:Toggle({
    Title = "Infinite Jump",
    Desc = "Allows jumping continuously mid-air",
    Value = false,
    Callback = function(state)
        HubState.InfJump = state
    end
})

TabPlayer:Toggle({
    Title = "Night Vision",
    Desc = "Toggles high-clarity tactical night vision",
    Value = false,
    Callback = function(state)
        HubState.NightVision = state
        LocalPlayer:SetAttribute("IF_NightVision", state)
    end
})

TabPlayer:Toggle({
    Title = "Anti-AFK Protection",
    Desc = "Prevents Roblox 20-minute idle disconnect",
    Value = true,
    Callback = function(state)
        HubState.AntiAFK = state
    end
})

TabPlayer:Section({ Title = "Base Teleports" })

TabPlayer:Button({
    Title = "Teleport To Your Base",
    Callback = function()
        local plot = GetPlayerPlot()
        if plot then
            local cf = plot:GetPivot()
            if LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart") then
                LocalPlayer.Character.HumanoidRootPart.CFrame = cf + Vector3.new(0, 5, 0)
            end
        else
            WindUI:Notify({ Title = "Teleport", Content = "Could not locate player plot.", Duration = 2, Icon = "alert-circle" })
        end
    end
})

TabPlayer:Button({
    Title = "Teleport To Hand Pump",
    Callback = function()
        TeleportToPumpStand()
    end
})

TabPlayer:Button({
    Title = "Teleport To Headquarters (HQ)",
    Callback = function()
        local plot = GetPlayerPlot()
        local hq = plot and plot.Buildings:FindFirstChild("hq")
        if hq and LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart") then
            LocalPlayer.Character.HumanoidRootPart.CFrame = hq:GetPivot() + Vector3.new(0, 5, 0)
        end
    end
})

TabPlayer:Section({ Title = "Strategic Points Teleports" })

for _, pt in ipairs(PointsModule.LIST or {}) do
    if pt.pos then
        TabPlayer:Button({
            Title = "TP to " .. pt.name,
            Callback = function()
                if LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart") then
                    LocalPlayer.Character.HumanoidRootPart.CFrame = CFrame.new(pt.pos.X, pt.pos.Y + 8, pt.pos.Z)
                end
            end
        })
    end
end

-- ===================================================
-- TAB 5: SETTINGS & PROMO CODES
-- ===================================================

TabSettings:Section({ Title = "Promo Code Redemption" })

local CodeInputVal = ""
TabSettings:Input({
    Title = "Code Box",
    Placeholder = "Enter promo code here",
    Callback = function(val)
        CodeInputVal = val
    end
})

TabSettings:Button({
    Title = "Redeem Code",
    Callback = function()
        if CodeInputVal == "" then
            WindUI:Notify({ Title = "Error", Content = "Please type a code first.", Duration = 2, Icon = "x" })
            return
        end
        local ok, res = Store.call("RedeemCode", CodeInputVal)
        if ok then
            WindUI:Notify({
                Title = "Code Redeemed!",
                Content = tostring(res or "Code successfully redeemed!"),
                Duration = 3,
                Icon = "check"
            })
        else
            WindUI:Notify({
                Title = "Invalid Code",
                Content = tostring(res or "Code is expired or already redeemed."),
                Duration = 2.5,
                Icon = "alert-circle"
            })
        end
    end
})

TabSettings:Section({ Title = "Hub Management" })

TabSettings:Button({
    Title = "Close & Unload Hub",
    Desc = "Disconnects all background loops and closes the UI cleanly",
    Callback = function()
        Cleanup()
    end
})

-- ====================
-- BACKGROUND LOOPS & EVENT CONNECTIONS
-- ====================

-- Anti-AFK Idle Prevention
table.insert(HubState.Connections, LocalPlayer.Idled:Connect(function()
    if HubState.AntiAFK then
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new(0, 0))
        end)
    end
end))

-- Infinite Jump Listener
table.insert(HubState.Connections, UserInputService.JumpRequest:Connect(function()
    if HubState.InfJump and LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Humanoid") then
        LocalPlayer.Character.Humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
    end
end))

-- Character Respawn Handler
table.insert(HubState.Connections, LocalPlayer.CharacterAdded:Connect(function(newChar)
    Character = newChar
    local hum = newChar:WaitForChild("Humanoid", 10)
    if hum then
        if HubState.SpeedEnabled then hum.WalkSpeed = HubState.CustomSpeed end
        if HubState.JumpEnabled then hum.UseJumpPower = true; hum.JumpPower = HubState.CustomJump end
    end
    -- If AFK auto pump is active, return to pump stand
    if HubState.AutoPump then
        task.wait(1)
        TeleportToPumpStand()
    end
end))

-- Main Heartbeat Loop
table.insert(HubState.Connections, RunService.Heartbeat:Connect(function()
    if not HubState.Running then return end

    -- Speed & Jump enforcement
    if Character and Character:FindFirstChild("Humanoid") then
        local hum = Character.Humanoid
        if HubState.SpeedEnabled and hum.WalkSpeed ~= HubState.CustomSpeed then
            hum.WalkSpeed = HubState.CustomSpeed
        end
        if HubState.JumpEnabled and hum.JumpPower ~= HubState.CustomJump then
            hum.UseJumpPower = true
            hum.JumpPower = HubState.CustomJump
        end
    end

    local now = os.clock()

    -- AFK Auto Pump Oil Action & Lock
    if HubState.AutoPump then
        local hp, standPos, prompt = GetHandpumpData()
        if hp and standPos and Character and Character:FindFirstChild("HumanoidRootPart") then
            -- Position lock on the pump stand so character doesn't fall or get pushed
            if HubState.LockAtPump then
                local currentPos = Character.HumanoidRootPart.Position
                local targetPos = standPos + Vector3.new(0, 2.5, 0)
                if (currentPos - targetPos).Magnitude > 3 then
                    Character.HumanoidRootPart.CFrame = CFrame.new(targetPos, hp:GetPivot().Position)
                end
                Character.HumanoidRootPart.AssemblyLinearVelocity = Vector3.new(0, Character.HumanoidRootPart.AssemblyLinearVelocity.Y, 0)
                Character.HumanoidRootPart.AssemblyAngularVelocity = Vector3.zero
            end

            -- Stroke cycle execution
            if (now - HubState.LastPumpStroke) >= HubState.PumpStrokeDelay then
                HubState.LastPumpStroke = now
                if prompt and fireproximityprompt then
                    fireproximityprompt(prompt)
                end
                Store.action("Pump")
                HubState.PumpStrokesCount = HubState.PumpStrokesCount + 1
            end
        end
    end

    -- Auto Upgrade Loop
    if HubState.AutoUpgrade and (now - HubState.LastUpgradeTime >= HubState.UpgradeDelay) then
        HubState.LastUpgradeTime = now
        local ok, name, cost = UpgradeOne(HubState.UpgradePriority)
        if ok and name and cost then
            -- building upgraded
        end
    end

    -- Auto Claim Daily Loop (every 30s)
    if HubState.AutoClaimDaily and (now - HubState.LastDailyCheck >= 30) then
        HubState.LastDailyCheck = now
        pcall(function()
            Store.call("ClaimDaily")
        end)
    end

    -- Auto Rebirth Loop (every 10s)
    if HubState.AutoRebirth then
        local rebirth = Store.get("rebirth")
        if rebirth and rebirth.hqOk and (Store.cash() >= (rebirth.cost or 0)) then
            Store.call("Rebirth")
        end
    end

    -- Auto Conquest Loop (every 15s)
    if HubState.AutoConquest and (now - HubState.LastConquestCheck >= 15) then
        HubState.LastConquestCheck = now
        local ptId = PointsMap[HubState.ConquestTarget] or "airfield"
        pcall(OrderArmyToPoint, ptId)
    end
end))

-- Periodic Stats & Dashboard Updater (every 1.5 seconds)
task.spawn(function()
    local initialCash = Store.cash()
    while HubState.Running do
        pcall(function()
            local eco = Store.get("economy") or {}
            local base = Store.get("base") or {}
            local rebirth = Store.get("rebirth") or {}
            local army = Store.get("army") or {}

            local cash = Store.cash()
            local baseIncome = eco.base or 0
            local terrIncome = eco.territory or 0
            local totalIncome = eco.total or (baseIncome + terrIncome)
            local hqLevel = (base.levels and base.levels.hq) or 1
            local tier = base.tier or 1

            BaseInfoPara:SetDesc(string.format(
                "💰 Cash: %s  |  Tier %d (HQ Lvl %d)\n📈 Base: %s/s  |  Territory: %s/s\n💵 Total Income: %s/s",
                FormatMoney(cash), tier, hqLevel, FormatMoney(baseIncome), FormatMoney(terrIncome), FormatMoney(totalIncome)
            ))

            -- Pump Stats
            local pumpStatus = HubState.AutoPump and "🟢 Pumping (Active)" or "⚪ Idle"
            local strokes = HubState.PumpStrokesCount
            local sessionDiff = math.max(0, cash - initialCash)
            PumpStatsPara:SetDesc(string.format(
                "Status: %s\n🛢️ Total Pump Strokes: %d  |  Speed: %.2fs\n💵 Session Revenue: %s",
                pumpStatus, strokes, HubState.PumpStrokeDelay, FormatMoney(sessionDiff)
            ))

            local fielded = army.fielded or 0
            local total = army.total or 0
            ArmyInfoPara:SetDesc(string.format(
                "⚔️ Fielded Troops: %d / %d\n🎯 Current Target: %s",
                fielded, total, HubState.ConquestTarget
            ))

            local rank = rebirth.rank or "Recruit"
            local nextRank = rebirth.nextRank or "Captain"
            local cost = rebirth.cost or 0
            local bonus = rebirth.bonus or 0
            local hqOk = rebirth.hqOk and "✅ Ready" or "❌ Need higher HQ"
            RebirthInfoPara:SetDesc(string.format(
                "🎖️ Rank: %s ➔ %s\n⭐ Permanent Income Bonus: +%d%%\n💵 Cost: %s  |  HQ Req: %s",
                rank, nextRank, bonus, FormatMoney(cost), hqOk
            ))
        end)
        task.wait(1.5)
    end
end)

WindUI:Notify({
    Title = "Army Commander Hub Loaded",
    Content = "AFK Auto Pump Oil & Tycoon features are ready! Check the Auto Tycoon & Oil tab.",
    Duration = 4,
    Icon = "fuel"
})

return Window
