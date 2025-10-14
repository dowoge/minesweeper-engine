local TileState = {
    Revealed = 1,
    Mine = 2,
    Safe = 3,
    Unknown = 4
}

local PartsFolder = workspace:FindFirstChild("Flag") and workspace.Flag:FindFirstChild("Parts")
if not PartsFolder then error("Parts folder not found") end

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local BoardActive = true
local ReinitializeRequested = false

local function InitializeBoard()
    print("Initializing board...")

    local SalasanaValue = nil
    for _, f in getgc(true) do
        if type(f) == "function" and islclosure(f) then
            local FunctionInfo = getinfo(f)
            if FunctionInfo.source:find("MouseControl") then
                if FunctionInfo.nups == 5 then
                    local upvalues = getupvalues(FunctionInfo.func)
                    SalasanaValue = upvalues[#upvalues]
                    break
                end
            end
        end
    end

    if not SalasanaValue then
        warn("Could not find salasana value - automatic flagging disabled")
    else
        print("Salasana value found - automatic flagging enabled")
    end

    local TileSize = 5
    local PosTolerance = 0.01
    local ColorTolerance = 8

    local RevealedColor = Color3.fromRGB(230, 230, 113)
    local SafeColor = Color3.fromRGB(0, 255, 0)
    local MineColor = Color3.fromRGB(255, 0, 0)
    local UncertainColor = Color3.fromRGB(255, 200, 0)

    local Parts = {}
    for _, p in ipairs(PartsFolder:GetChildren()) do
        if p:IsA("BasePart") then
            table.insert(Parts, p)
        end
    end
    if #Parts == 0 then error("No parts found") end

    local function AddUnique(list, value)
        for _, v in ipairs(list) do
            if math.abs(v - value) <= PosTolerance then return end
        end
        table.insert(list, value)
    end

    local Xs, Zs = {}, {}
    for _, p in ipairs(Parts) do
        AddUnique(Xs, p.Position.X)
        AddUnique(Zs, p.Position.Z)
    end
    table.sort(Xs)
    table.sort(Zs)

    local Cols = #Xs
    local Rows = #Zs

    local function FindIndex(sortedList, value)
        local BestI, BestD = 1, math.huge
        for i, v in ipairs(sortedList) do
            local D = math.abs(v - value)
            if D < BestD then BestD, BestI = D, i end
        end
        return BestI
    end

    local Grid = {}
    for r = 1, Rows do
        Grid[r] = {}
        for c = 1, Cols do Grid[r][c] = nil end
    end

    for _, p in ipairs(Parts) do
        local c = FindIndex(Xs, p.Position.X)
        local r = FindIndex(Zs, p.Position.Z)
        Grid[r][c] = p
    end

    print("Grid:", Rows, "x", Cols)

    local function InBounds(r, c)
        return r >= 1 and r <= Rows and c >= 1 and c <= Cols
    end

    local function Neighbors(r, c)
        local Out = {}
        for dr = -1, 1 do
            for dc = -1, 1 do
                if not (dr == 0 and dc == 0) then
                    local Nr, Nc = r + dr, c + dc
                    if InBounds(Nr, Nc) then
                        local p = Grid[Nr][Nc]
                        if p then table.insert(Out, {r = Nr, c = Nc, part = p}) end
                    end
                end
            end
        end
        return Out
    end

    local function GetRevealedNumber(part)
        local Gui = part:FindFirstChild("NumberGui")
        if not Gui then return nil end
        local Tl = Gui:FindFirstChild("TextLabel")
        if not Tl then return nil end
        local Text = Tl.Text
        if Text == "" then return 0 end
        local N = tonumber(Text)
        return N
    end

    local Status = {}
    local OriginalColors = {}

    local function IsFlagged(part)
        return part:FindFirstChildOfClass("Model") ~= nil
    end

    local function TryFlagTile(part)
        if not SalasanaValue then return false end
        if IsFlagged(part) then return false end

        local character = LocalPlayer.Character
        if not character then return false end

        local rootPart = character:FindFirstChild("HumanoidRootPart")
        if not rootPart then return false end

        local distance = (rootPart.Position - part.Position).Magnitude
        if distance >= 145 then return false end

        local success = pcall(function()
            ReplicatedStorage.Events.FlagEvents.PlaceFlag:FireServer(part, SalasanaValue, true)
        end)

        if success then
            print("Flagged mine at distance:", math.floor(distance))
        end

        return success
    end

    local function Recompute()
        for r = 1, Rows do
            for c = 1, Cols do
                local p = Grid[r][c]
                if p then
                    if not OriginalColors[p] then
                        OriginalColors[p] = p.Color
                    end

                    local HasGui = p:FindFirstChild("NumberGui") ~= nil
                    if HasGui then
                        Status[p] = TileState.Revealed
                    else
                        Status[p] = TileState.Unknown
                    end
                end
            end
        end

        local Changed = true
        while Changed do
            Changed = false
            for r = 1, Rows do
                for c = 1, Cols do
                    local p = Grid[r][c]
                    if p and Status[p] == TileState.Revealed then
                        local N = GetRevealedNumber(p)
                        if N then
                            local Neigh = Neighbors(r, c)
                            local Unknowns = {}
                            local KnownMines = 0
                            for _, info in ipairs(Neigh) do
                                local Np = info.part
                                local S = Status[Np]
                                if S == TileState.Mine then
                                    KnownMines = KnownMines + 1
                                elseif S == TileState.Unknown then
                                    table.insert(Unknowns, Np)
                                end
                            end
                            local Need = N - KnownMines
                            if Need <= 0 and #Unknowns > 0 then
                                for _, up in ipairs(Unknowns) do
                                    if Status[up] ~= TileState.Safe then
                                        Status[up] = TileState.Safe
                                        Changed = true
                                    end
                                end
                            elseif Need == #Unknowns and #Unknowns > 0 then
                                for _, up in ipairs(Unknowns) do
                                    if Status[up] ~= TileState.Mine then
                                        Status[up] = TileState.Mine
                                        Changed = true
                                        TryFlagTile(up)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end

        for r = 1, Rows do
            for c = 1, Cols do
                local p = Grid[r][c]
                if p then
                    local OrigColor = OriginalColors[p]
                    if Status[p] == TileState.Revealed then

                    elseif Status[p] == TileState.Mine then
                        p.Color = MineColor
                    elseif Status[p] == TileState.Safe then
                        p.Color = SafeColor
                    else
                        local Neigh = Neighbors(r, c)
                        local HasRevealedNeighbor = false
                        for _, info in ipairs(Neigh) do
                            if Status[info.part] == TileState.Revealed then
                                HasRevealedNeighbor = true
                                break
                            end
                        end
                        if HasRevealedNeighbor then
                            p.Color = UncertainColor
                        else
                            p.Color = OrigColor
                        end
                    end
                end
            end
        end
    end

    local RecomputeScheduled = false
    local function ScheduleRecompute()
        if RecomputeScheduled then return end
        RecomputeScheduled = true
        task.defer(function()
            Recompute()
            RecomputeScheduled = false
        end)
    end

    for r = 1, Rows do
        for c = 1, Cols do
            local p = Grid[r][c]
            if p then
                p.Changed:Connect(function(prop)
                    if prop == "Color" then
                        ScheduleRecompute()
                    end
                end)
            end
        end
    end

    Recompute()

    -- Function to check and flag any unflagged nearby mines
    local function FlagNearbyMines()
        if not SalasanaValue then return end

        for r = 1, Rows do
            for c = 1, Cols do
                local p = Grid[r][c]
                if p and Status[p] == TileState.Mine and not IsFlagged(p) then
                    if TryFlagTile(p) then
                        task.wait(0.05)
                    end
                end
            end
        end
    end

    local HeartbeatInterval = 1
    local MainLoop = nil
    MainLoop = spawn(function()
        while BoardActive and not ReinitializeRequested do
            task.wait(HeartbeatInterval)
            if BoardActive and not ReinitializeRequested then
                ScheduleRecompute()
                FlagNearbyMines()
            end
        end
    end)

    print("Minesweeper helper active.")

    return {Grid = Grid, Status = Status, MainLoop = MainLoop}
end

local function MonitorBoard()
    local LastChildCount = #PartsFolder:GetChildren()
    local BoardDisappeared = false
    local StableCount = 0
    local StableThreshold = 3

    PartsFolder.ChildAdded:Connect(function()
        local CurrentCount = #PartsFolder:GetChildren()
        if BoardDisappeared and CurrentCount > 0 then
            print("Board respawning... (" .. CurrentCount .. " parts)")
            StableCount = 0
        end
    end)

    PartsFolder.ChildRemoved:Connect(function()
        local CurrentCount = #PartsFolder:GetChildren()
        if CurrentCount == 0 and not BoardDisappeared then
            print("Board disappeared - waiting for respawn...")
            BoardDisappeared = true
            BoardActive = false
            ReinitializeRequested = true
        end
    end)

    spawn(function()
        while true do
            task.wait(1)
            local CurrentCount = #PartsFolder:GetChildren()

            if BoardDisappeared and CurrentCount > 0 then
                if CurrentCount == LastChildCount then
                    StableCount = StableCount + 1

                    if StableCount >= StableThreshold and CurrentCount >= 100 then
                        print("Board stable with " .. CurrentCount .. " parts - reinitializing...")
                        BoardDisappeared = false
                        BoardActive = true
                        ReinitializeRequested = false
                        StableCount = 0

                        task.wait(0.5)
                        InitializeBoard()
                    end
                else
                    StableCount = 0
                end
            end

            LastChildCount = CurrentCount
        end
    end)
end

InitializeBoard()
MonitorBoard()