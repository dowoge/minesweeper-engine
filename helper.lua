local Config = {
    -- Solving
    MaxSolvingIterations = 50,
    MaxHypothesisIterations = 30,
    MinIterationForPhase3 = 1,
    MaxFrontierTilesForPhase3 = 200,
    YieldEveryNTilesInPhase3 = 10,
    YieldEveryNPairwiseChecks = 20,
    YieldEveryNColorUpdates = 100,

    -- Flagging
    AutoFlagDistance = 22.5,
    FlagDelay = 0.05,

    -- Board stuff
    HeartbeatInterval = 1,
    BoardStableThreshold = 3,
    MinPartsForValidBoard = 100,
    ReinitDelay = 0.5,

    -- Grid detection
    PositionTolerance = 0.01,

    -- Visuals
    SafeColor = Color3.fromRGB(0, 255, 0),
    MineColor = Color3.fromRGB(255, 0, 0),
    UncertainColor = Color3.fromRGB(255, 200, 0),
}

-- Tile states
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
local RunService = game:GetService("RunService")

local BoardActive = true
local ReinitializeRequested = false

local function InitializeBoard()
    print("Initializing board...")

    local Connections = {}

    local SalasanaValue = nil
    for _, Function in getgc(true) do
        if type(Function) == "function" and islclosure(Function) then
            local FunctionInfo = getinfo(Function)
            if FunctionInfo.source:find("MouseControl") then
                if FunctionInfo.nups == 5 then
                    local Upvalues = getupvalues(FunctionInfo.func)
                    SalasanaValue = Upvalues[#Upvalues]
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

    local Parts = {}
    for _, Part in ipairs(PartsFolder:GetChildren()) do
        if Part:IsA("BasePart") then
            table.insert(Parts, Part)
        end
    end
    if #Parts == 0 then error("No parts found") end

    local function AddUnique(List, Value)
        for _, V in ipairs(List) do
            if math.abs(V - Value) <= Config.PositionTolerance then return end
        end
        table.insert(List, Value)
    end

    local Xs, Zs = {}, {}
    for _, Part in ipairs(Parts) do
        AddUnique(Xs, Part.Position.X)
        AddUnique(Zs, Part.Position.Z)
    end
    table.sort(Xs)
    table.sort(Zs)

    local Cols = #Xs
    local Rows = #Zs

    local function FindIndex(SortedList, Value)
        local BestI, BestD = 1, math.huge
        for I, V in ipairs(SortedList) do
            local D = math.abs(V - Value)
            if D < BestD then BestD, BestI = D, I end
        end
        return BestI
    end

    local Grid = {}
    for R = 1, Rows do
        Grid[R] = {}
        for C = 1, Cols do Grid[R][C] = nil end
    end

    for _, Part in ipairs(Parts) do
        local C = FindIndex(Xs, Part.Position.X)
        local R = FindIndex(Zs, Part.Position.Z)
        Grid[R][C] = Part
    end

    print("Grid:", Rows, "x", Cols)

    local function InBounds(R, C)
        return R >= 1 and R <= Rows and C >= 1 and C <= Cols
    end

    local function Neighbors(R, C)
        local Out = {}
        for Dr = -1, 1 do
            for Dc = -1, 1 do
                if not (Dr == 0 and Dc == 0) then
                    local Nr, Nc = R + Dr, C + Dc
                    if InBounds(Nr, Nc) then
                        local Part = Grid[Nr][Nc]
                        if Part then table.insert(Out, {R = Nr, C = Nc, Part = Part}) end
                    end
                end
            end
        end
        return Out
    end

    local NeighborCache = {}
    local PartToCoords = {}
    for R = 1, Rows do
        for C = 1, Cols do
            if Grid[R][C] then
                NeighborCache[R .. "," .. C] = Neighbors(R, C)
                PartToCoords[Grid[R][C]] = {R = R, C = C}
            end
        end
    end
    
    local function GetNeighbors(R, C)
        return NeighborCache[R .. "," .. C] or {}
    end
    
    local function GetCoords(Part)
        return PartToCoords[Part]
    end

    local function GetRevealedNumber(Part)
        local Gui = Part:FindFirstChild("NumberGui")
        if not Gui then return nil end
        local TextLabel = Gui:FindFirstChild("TextLabel")
        if not TextLabel then return nil end
        local Text = TextLabel.Text
        if Text == "" then return 0 end
        local Number = tonumber(Text)
        return Number
    end

    local Status = {}
    local OriginalColors = {}
    local DirtyTiles = {}
    local LastKnownRevealed = {}

    local function IsFlagged(Part)
        return Part:FindFirstChildOfClass("Model") ~= nil
    end

    local function TryFlagTile(Part)
        if not SalasanaValue then return false end
        if IsFlagged(Part) then return false end

        local Character = LocalPlayer.Character
        if not Character then return false end

        local RootPart = Character:FindFirstChild("HumanoidRootPart")
        if not RootPart then return false end

        local Distance = (RootPart.Position - Part.Position).Magnitude
        if Distance >= Config.AutoFlagDistance then return false end

        local Success = pcall(function()
            ReplicatedStorage.Events.FlagEvents.PlaceFlag:FireServer(Part, SalasanaValue, true)
        end)

        if Success then
            print("Flagged mine at distance:", math.floor(Distance))
        end

        return Success
    end

    local function Recompute()
        local NewlyRevealed = {}

        for R = 1, Rows do
            for C = 1, Cols do
                local Part = Grid[R][C]
                if Part then
                    if not OriginalColors[Part] then
                        OriginalColors[Part] = Part.Color
                    end

                    local HasGui = Part:FindFirstChild("NumberGui") ~= nil
                    if HasGui then
                        if not LastKnownRevealed[Part] then
                            LastKnownRevealed[Part] = true
                            table.insert(NewlyRevealed, {R = R, C = C, Part = Part})
                            DirtyTiles[Part] = true

                            local Neighbors = GetNeighbors(R, C)
                            for _, Neighbor in ipairs(Neighbors) do
                                DirtyTiles[Neighbor.Part] = true
                            end
                        end
                        Status[Part] = TileState.Revealed
                    elseif Status[Part] == nil then
                        Status[Part] = TileState.Unknown
                    end
                end
            end
        end

        if next(NewlyRevealed) == nil and next(DirtyTiles) == nil then
            return
        end

        local function GetCellInfo(R, C)
            if not InBounds(R, C) then return nil end
            local Part = Grid[R][C]
            if not Part then return nil end
            return {
                R = R,
                C = C,
                Part = Part,
                status = Status[Part],
                Number = Status[Part] == TileState.Revealed and GetRevealedNumber(Part) or nil
            }
        end

        local function GetUnknownsAndMines(Neighbors)
            local Unknowns = {}
            local Mines = {}
            for _, Info in ipairs(Neighbors) do
                if Info.status == TileState.Unknown then
                    table.insert(Unknowns, Info)
                elseif Info.status == TileState.Mine then
                    table.insert(Mines, Info)
                end
            end
            return Unknowns, Mines
        end

        local Iterations = 0
        while Iterations < Config.MaxSolvingIterations do
            Iterations = Iterations + 1
            local Changed = false

            -- Basic deduction logic (cheapest, try first)
            for R = 1, Rows do
                for C = 1, Cols do
                    local Part = Grid[R][C]
                    if Part and Status[Part] == TileState.Revealed then
                        local Number = GetRevealedNumber(Part)
                        if Number then
                            local NeighborsList = GetNeighbors(R, C)
                            local Unknowns = {}
                            local KnownMines = 0
                            for _, Info in ipairs(NeighborsList) do
                                local NeighborPart = Info.Part
                                local NeighborStatus = Status[NeighborPart]
                                if NeighborStatus == TileState.Mine then
                                    KnownMines = KnownMines + 1
                                elseif NeighborStatus == TileState.Unknown then
                                    table.insert(Unknowns, NeighborPart)
                                end
                            end
                            local Need = Number - KnownMines
                            if Need <= 0 and #Unknowns > 0 then
                                for _, UnknownPart in ipairs(Unknowns) do
                                    if Status[UnknownPart] ~= TileState.Safe then
                                        Status[UnknownPart] = TileState.Safe
                                        UnknownPart.Color = Config.SafeColor
                                        Changed = true
                                        DirtyTiles[UnknownPart] = true
                                    end
                                end
                            elseif Need == #Unknowns and #Unknowns > 0 then
                                for _, UnknownPart in ipairs(Unknowns) do
                                    if Status[UnknownPart] ~= TileState.Mine then
                                        Status[UnknownPart] = TileState.Mine
                                        UnknownPart.Color = Config.MineColor
                                        Changed = true
                                        DirtyTiles[UnknownPart] = true
                                        TryFlagTile(UnknownPart)
                                    end
                                end
                            end
                        end
                    end
                    if Changed then break end
                end
                if Changed then break end
            end

            -- Pairwise comparison (only if Phase 1 found nothing)
            if not Changed then
                local PairwiseChecks = 0
                for R = 1, Rows do
                for C = 1, Cols do
                    local Cell = GetCellInfo(R, C)
                    if Cell and Cell.status == TileState.Revealed and Cell.Number and Cell.Number > 0 then
                        PairwiseChecks = PairwiseChecks + 1
                        if PairwiseChecks % Config.YieldEveryNPairwiseChecks == 0 then
                            RunService.RenderStepped:Wait()
                        end
                        local NeighborsList = GetNeighbors(R, C)
                        local Unknowns1, Mines1 = GetUnknownsAndMines(NeighborsList)
                        local Remaining1 = Cell.Number - #Mines1
                        if #Unknowns1 > 0 and Remaining1 > 0 then
                            for Dr = -1, 1 do
                                for Dc = -1, 1 do
                                    if not (Dr == 0 and Dc == 0) then
                                        local Nr, Nc = R + Dr, C + Dc
                                        local Neighbor = GetCellInfo(Nr, Nc)

                                        if Neighbor and Neighbor.status == TileState.Revealed and Neighbor.Number and Neighbor.Number > 0 then
                                            local Neighbors2 = GetNeighbors(Nr, Nc)
                                            local Unknowns2, Mines2 = GetUnknownsAndMines(Neighbors2)
                                            local Remaining2 = Neighbor.Number - #Mines2

                                            if #Unknowns2 > 0 and Remaining2 > 0 then
                                                local Shared = {}
                                                local Unique1 = {}
                                                local Unique2 = {}

                                                for _, U1 in ipairs(Unknowns1) do
                                                    local IsShared = false
                                                    for _, U2 in ipairs(Unknowns2) do
                                                        if U1.R == U2.R and U1.C == U2.C then
                                                            table.insert(Shared, U1)
                                                            IsShared = true
                                                            break
                                                        end
                                                    end
                                                    if not IsShared then
                                                        table.insert(Unique1, U1)
                                                    end
                                                end

                                                for _, U2 in ipairs(Unknowns2) do
                                                    local IsShared = false
                                                    for _, S in ipairs(Shared) do
                                                        if U2.R == S.R and U2.C == S.C then
                                                            IsShared = true
                                                            break
                                                        end
                                                    end
                                                    if not IsShared then
                                                        table.insert(Unique2, U2)
                                                    end
                                                end

                                                -- Should andle all cases (shared unknowns, subsets, and supersets)
                                                if #Shared > 0 or #Unique1 == 0 or #Unique2 == 0 then
                                                    -- Case 1: Equal remaining mines with shared unknowns
                                                    if Remaining1 == Remaining2 and #Unique1 > 0 and #Unique2 > 0 then
                                                        for _, U in ipairs(Unique1) do
                                                            if Status[U.Part] ~= TileState.Safe then
                                                                Status[U.Part] = TileState.Safe
                                                                U.Part.Color = Config.SafeColor
                                                                Changed = true
                                                            end
                                                        end
                                                        for _, U in ipairs(Unique2) do
                                                            if Status[U.Part] ~= TileState.Safe then
                                                                Status[U.Part] = TileState.Safe
                                                                U.Part.Color = Config.SafeColor
                                                                Changed = true
                                                            end
                                                        end
                                                    end

                                                    -- Case 2: Cell 1's unique tiles contain all the extra mines
                                                    if Remaining1 - Remaining2 == #Unique1 and #Unique1 > 0 then
                                                        for _, U in ipairs(Unique1) do
                                                            if Status[U.Part] ~= TileState.Mine then
                                                                Status[U.Part] = TileState.Mine
                                                                U.Part.Color = Config.MineColor
                                                                Changed = true
                                                                TryFlagTile(U.Part)
                                                            end
                                                        end
                                                        -- The shared tiles must be safe
                                                        if Remaining2 == 0 then
                                                            for _, S in ipairs(Shared) do
                                                                if Status[S.Part] ~= TileState.Safe then
                                                                    Status[S.Part] = TileState.Safe
                                                                    S.Part.Color = Config.SafeColor
                                                                    Changed = true
                                                                end
                                                            end
                                                        end
                                                    end

                                                    -- Case 3: Cell 2's unique tiles contain all the extra mines
                                                    if Remaining2 - Remaining1 == #Unique2 and #Unique2 > 0 then
                                                        for _, U in ipairs(Unique2) do
                                                            if Status[U.Part] ~= TileState.Mine then
                                                                Status[U.Part] = TileState.Mine
                                                                U.Part.Color = Config.MineColor
                                                                Changed = true
                                                                TryFlagTile(U.Part)
                                                            end
                                                        end
                                                        -- The shared tiles must be safe
                                                        if Remaining1 == 0 then
                                                            for _, S in ipairs(Shared) do
                                                                if Status[S.Part] ~= TileState.Safe then
                                                                    Status[S.Part] = TileState.Safe
                                                                    S.Part.Color = Config.SafeColor
                                                                    Changed = true
                                                                end
                                                            end
                                                        end
                                                    end

                                                    -- Case 4: Perfect subset - Cell 1 is fully contained in Cell 2
                                                    if #Unique1 == 0 and #Unknowns1 > 0 then
                                                        -- All of Cell 1's unknowns are shared with Cell 2
                                                        -- Cell 2 has Remaining2 mines, Cell 1 has Remaining1 mines
                                                        -- So Unique2 must have exactly (Remaining2 - Remaining1) mines
                                                        -- (p.42)
                                                        local Unique2Mines = Remaining2 - Remaining1
                                                        if Unique2Mines == 0 and #Unique2 > 0 then
                                                            -- All unique tiles in Cell 2 are safe
                                                            for _, U in ipairs(Unique2) do
                                                                if Status[U.Part] ~= TileState.Safe then
                                                                    Status[U.Part] = TileState.Safe
                                                                    U.Part.Color = Config.SafeColor
                                                                    Changed = true
                                                                end
                                                            end
                                                        elseif Unique2Mines == #Unique2 and #Unique2 > 0 then
                                                            -- All unique tiles in Cell 2 are mines
                                                            for _, U in ipairs(Unique2) do
                                                                if Status[U.Part] ~= TileState.Mine then
                                                                    Status[U.Part] = TileState.Mine
                                                                    U.Part.Color = Config.MineColor
                                                                    Changed = true
                                                                    TryFlagTile(U.Part)
                                                                end
                                                            end
                                                        end
                                                    end

                                                    -- Case 5: Perfect subset - Cell 2 is fully contained in Cell 1
                                                    if #Unique2 == 0 and #Unknowns2 > 0 then
                                                        local Unique1Mines = Remaining1 - Remaining2
                                                        if Unique1Mines == 0 and #Unique1 > 0 then
                                                            -- All unique tiles in Cell 1 are safe
                                                            for _, U in ipairs(Unique1) do
                                                                if Status[U.Part] ~= TileState.Safe then
                                                                    Status[U.Part] = TileState.Safe
                                                                    U.Part.Color = Config.SafeColor
                                                                    Changed = true
                                                                end
                                                            end
                                                        elseif Unique1Mines == #Unique1 and #Unique1 > 0 then
                                                            -- All unique tiles in Cell 1 are mines
                                                            for _, U in ipairs(Unique1) do
                                                                if Status[U.Part] ~= TileState.Mine then
                                                                    Status[U.Part] = TileState.Mine
                                                                    U.Part.Color = Config.MineColor
                                                                    Changed = true
                                                                    TryFlagTile(U.Part)
                                                                end
                                                            end
                                                        end
                                                    end

                                                    if Changed then break end
                                                end
                                            end
                                        end
                                        if Changed then break end
                                    end
                                end
                                if Changed then break end
                            end
                        end
                    end
                    if Changed then break end
                end
                    if Changed then break end
                end
            end

            -- Phase 3: Contradiction testing (only if Phase 1 AND Phase 2 found nothing)
            if not Changed and Iterations >= Config.MinIterationForPhase3 then
                local FrontierTiles = {}
                for R = 1, Rows do
                    for C = 1, Cols do
                        local Part = Grid[R][C]
                        if Part and Status[Part] == TileState.Unknown then
                            local NeighborsList = GetNeighbors(R, C)
                            local HasRevealedNeighbor = false
                            for _, Info in ipairs(NeighborsList) do
                                if Status[Info.Part] == TileState.Revealed then
                                    HasRevealedNeighbor = true
                                    break
                                end
                            end
                            if HasRevealedNeighbor then
                                table.insert(FrontierTiles, {R = R, C = C, Part = Part})
                            end
                        end
                    end
                end

                if #FrontierTiles > 0 and #FrontierTiles < Config.MaxFrontierTilesForPhase3 then
                    for TileIdx, Tile in ipairs(FrontierTiles) do
                    if TileIdx % Config.YieldEveryNTilesInPhase3 == 0 then
                        RunService.RenderStepped:Wait()
                    end
                    if Status[Tile.Part] == TileState.Unknown then
                        local function TestHypothesis(AssumeMine)
                            local TestStatus = {}
                            local RelevantParts = {}

                            for _, FTile in ipairs(FrontierTiles) do
                                TestStatus[FTile.Part] = Status[FTile.Part]
                                RelevantParts[FTile.Part] = true
                            end

                            for R = 1, Rows do
                                for C = 1, Cols do
                                    local Part = Grid[R][C]
                                    if Part and Status[Part] == TileState.Revealed then
                                        TestStatus[Part] = TileState.Revealed
                                        RelevantParts[Part] = true
                                    end
                                end
                            end

                            TestStatus[Tile.Part] = AssumeMine and TileState.Mine or TileState.Safe

                            local TestChanged = true
                            local Iterations = 0
                            while TestChanged and Iterations < Config.MaxHypothesisIterations do
                                Iterations = Iterations + 1
                                TestChanged = false

                                for TR = 1, Rows do
                                    for TC = 1, Cols do
                                        local TPart = Grid[TR][TC]
                                        if TPart and TestStatus[TPart] == TileState.Revealed then
                                            local TNumber = GetRevealedNumber(TPart)
                                            if TNumber then
                                                local TNeighbors = GetNeighbors(TR, TC)
                                                local TUnknowns = {}
                                                local TMines = 0

                                                for _, TInfo in ipairs(TNeighbors) do
                                                    local TNeighborPart = TInfo.Part
                                                    local TStatus = TestStatus[TNeighborPart] or Status[TNeighborPart]
                                                    if TStatus == TileState.Mine then
                                                        TMines = TMines + 1
                                                    elseif TStatus == TileState.Unknown then
                                                        table.insert(TUnknowns, TNeighborPart)
                                                    end
                                                end

                                                if TMines > TNumber then
                                                    return false
                                                end

                                                local TNeed = TNumber - TMines

                                                if TNeed < 0 then
                                                    return false
                                                elseif TNeed == 0 and #TUnknowns > 0 then
                                                    for _, TUnknown in ipairs(TUnknowns) do
                                                        if TestStatus[TUnknown] == TileState.Unknown then
                                                            TestStatus[TUnknown] = TileState.Safe
                                                            TestChanged = true
                                                        end
                                                    end
                                                elseif TNeed == #TUnknowns and #TUnknowns > 0 then
                                                    for _, TUnknown in ipairs(TUnknowns) do
                                                        if TestStatus[TUnknown] == TileState.Unknown then
                                                            TestStatus[TUnknown] = TileState.Mine
                                                            TestChanged = true
                                                        end
                                                    end
                                                elseif TNeed > #TUnknowns then
                                                    return false
                                                end
                                            end
                                        end
                                    end
                                end
                            end

                            return true
                        end
                        local MineValid = TestHypothesis(true)
                        local SafeValid = TestHypothesis(false)
                        if MineValid and not SafeValid then
                            if Status[Tile.Part] ~= TileState.Mine then
                                Status[Tile.Part] = TileState.Mine
                                Tile.Part.Color = Config.MineColor
                                Changed = true
                                TryFlagTile(Tile.Part)
                            end
                        elseif SafeValid and not MineValid then
                            if Status[Tile.Part] ~= TileState.Safe then
                                Status[Tile.Part] = TileState.Safe
                                Tile.Part.Color = Config.SafeColor
                                Changed = true
                            end
                        end
                    end
                end
                end
            end

            -- Exit early if nothing changed in this iteration
            if not Changed then
                break
            end
        end

        local function UpdateColors(TilesToColor)
            local ColorUpdates = 0
            for Part, _ in pairs(TilesToColor) do
                ColorUpdates = ColorUpdates + 1
                if ColorUpdates % Config.YieldEveryNColorUpdates == 0 then
                    RunService.RenderStepped:Wait()
                end

                local IsCurrentlyRevealed = Part:FindFirstChild("NumberGui") ~= nil
                if IsCurrentlyRevealed then

                elseif Status[Part] == TileState.Mine then
                    Part.Color = Config.MineColor
                elseif Status[Part] == TileState.Safe then
                    Part.Color = Config.SafeColor
                else
                    local OrigColor = OriginalColors[Part]
                    local Coords = GetCoords(Part)

                    if Coords then
                        local NeighborsList = GetNeighbors(Coords.R, Coords.C)
                        local HasRevealedNeighbor = false
                        for _, Info in ipairs(NeighborsList) do
                            if Status[Info.Part] == TileState.Revealed then
                                HasRevealedNeighbor = true
                                break
                            end
                        end
                        if HasRevealedNeighbor then
                            Part.Color = Config.UncertainColor
                        else
                            Part.Color = OrigColor
                        end
                    else
                        Part.Color = OrigColor
                    end
                end
            end
        end

        UpdateColors(DirtyTiles)

        DirtyTiles = {}
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

    for R = 1, Rows do
        for C = 1, Cols do
            local Part = Grid[R][C]
            if Part then
                local Connection = Part.Changed:Connect(function(Property)
                    if Property == "Color" then
                        ScheduleRecompute()
                    end
                end)
                table.insert(Connections, Connection)
            end
        end
    end

    Recompute()

    local function FlagNearbyMines()
        if not SalasanaValue then return end

        for R = 1, Rows do
            for C = 1, Cols do
                local Part = Grid[R][C]
                if Part and Status[Part] == TileState.Mine and not IsFlagged(Part) then
                    if TryFlagTile(Part) then
                        task.wait(Config.FlagDelay)
                    end
                end
            end
        end
    end

    local MainLoop = nil
    MainLoop = spawn(function()
        while BoardActive and not ReinitializeRequested do
            task.wait(Config.HeartbeatInterval)
            if BoardActive and not ReinitializeRequested then
                ScheduleRecompute()
                FlagNearbyMines()
            end
        end
    end)

    print("Minesweeper helper active.")

    local function Cleanup()
        for _, Connection in ipairs(Connections) do
            Connection:Disconnect()
        end
        Status = {}
        DirtyTiles = {}
        LastKnownRevealed = {}
    end

    return {Grid = Grid, Status = Status, MainLoop = MainLoop, Connections = Connections, Cleanup = Cleanup}
end

local CurrentBoard = nil

local function MonitorBoard()
    local LastChildCount = #PartsFolder:GetChildren()
    local BoardDisappeared = false
    local StableCount = 0

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

            if CurrentBoard and CurrentBoard.Cleanup then
                CurrentBoard.Cleanup()
                print("Cleaned up board state")
            end
        end
    end)

    spawn(function()
        while true do
            task.wait(1)
            local CurrentCount = #PartsFolder:GetChildren()

            if BoardDisappeared and CurrentCount > 0 then
                if CurrentCount == LastChildCount then
                    StableCount = StableCount + 1

                    if StableCount >= Config.BoardStableThreshold and CurrentCount >= Config.MinPartsForValidBoard then
                        print("Board stable with " .. CurrentCount .. " parts - reinitializing...")
                        BoardDisappeared = false
                        BoardActive = true
                        ReinitializeRequested = false
                        StableCount = 0

                        task.wait(Config.ReinitDelay)
                        CurrentBoard = InitializeBoard()
                    end
                else
                    StableCount = 0
                end
            end

            LastChildCount = CurrentCount
        end
    end)
end

CurrentBoard = InitializeBoard()
MonitorBoard()