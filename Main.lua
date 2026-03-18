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
    FlagDelayMin = 0.1,
    FlagDelayMax = 0.4,
    FlagBatchSize = 3, -- How many flags to place before a longer pause
    FlagBatchDelayMin = 0.8,
    FlagBatchDelayMax = 1.5,

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
    AnalyzingColor = Color3.fromRGB(0, 200, 255), -- Cyan for deep analysis
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
        NeighborCache[R] = {}
        for C = 1, Cols do
            if Grid[R][C] then
                NeighborCache[R][C] = Neighbors(R, C)
                PartToCoords[Grid[R][C]] = {R = R, C = C}
            end
        end
    end

    local function GetNeighbors(R, C)
        return (NeighborCache[R] and NeighborCache[R][C]) or {}
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
    local TilesBeingAnalyzed = {} -- Tiles currently undergoing deep analysis
    local DeepAnalysisQueued = false
    local DeepAnalysisRunning = false
    local SuppressColorEvents = false

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

    -- Shared color update function (defined first so other functions can use it)
    local function UpdateColors(TilesToColor)
        SuppressColorEvents = true
        local ColorUpdates = 0
        for Part, _ in pairs(TilesToColor) do
            ColorUpdates = ColorUpdates + 1
            if ColorUpdates % Config.YieldEveryNColorUpdates == 0 then
                RunService.RenderStepped:Wait()
            end

            local IsCurrentlyRevealed = Part:FindFirstChild("NumberGui") ~= nil
            if IsCurrentlyRevealed then
                -- Don't color revealed tiles
            elseif TilesBeingAnalyzed[Part] then
                -- Show cyan for tiles currently being deeply analyzed
                Part.Color = Config.AnalyzingColor
            elseif Status[Part] == TileState.Mine then
                Part.Color = Config.MineColor
            elseif Status[Part] == TileState.Safe then
                Part.Color = Config.SafeColor
            elseif Status[Part] == TileState.Unknown then
                -- Show yellow for any Unknown tile that has been analyzed
                Part.Color = Config.UncertainColor
            else
                -- No status yet, restore original color
                local OrigColor = OriginalColors[Part]
                Part.Color = OrigColor
            end
        end
        SuppressColorEvents = false
    end

    -- Fast solving phases (Phase 1 & 2) - runs immediately
    local function FastSolve()
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
                end
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

                                                -- General pairwise constraint deduction
                                                -- mines_shared + mines_unique1 = Remaining1
                                                -- mines_shared + mines_unique2 = Remaining2
                                                -- Compute valid range for mines in shared tiles
                                                if #Shared > 0 or #Unique1 == 0 or #Unique2 == 0 then
                                                    local MaxSharedMines = math.min(#Shared, Remaining1, Remaining2)
                                                    local MinSharedMines = math.max(0, Remaining1 - #Unique1, Remaining2 - #Unique2)

                                                    -- Unique1: mines in [Remaining1 - MaxShared, Remaining1 - MinShared]
                                                    local MinUnique1Mines = Remaining1 - MaxSharedMines
                                                    local MaxUnique1Mines = Remaining1 - MinSharedMines

                                                    -- Unique2: mines in [Remaining2 - MaxShared, Remaining2 - MinShared]
                                                    local MinUnique2Mines = Remaining2 - MaxSharedMines
                                                    local MaxUnique2Mines = Remaining2 - MinSharedMines

                                                    -- Unique1 deductions
                                                    if #Unique1 > 0 then
                                                        if MinUnique1Mines >= #Unique1 then
                                                            -- All Unique1 must be mines
                                                            for _, U in ipairs(Unique1) do
                                                                if Status[U.Part] ~= TileState.Mine then
                                                                    Status[U.Part] = TileState.Mine
                                                                    U.Part.Color = Config.MineColor
                                                                    Changed = true
                                                                    DirtyTiles[U.Part] = true
                                                                    TryFlagTile(U.Part)
                                                                end
                                                            end
                                                        elseif MaxUnique1Mines <= 0 then
                                                            -- All Unique1 must be safe
                                                            for _, U in ipairs(Unique1) do
                                                                if Status[U.Part] ~= TileState.Safe then
                                                                    Status[U.Part] = TileState.Safe
                                                                    U.Part.Color = Config.SafeColor
                                                                    Changed = true
                                                                    DirtyTiles[U.Part] = true
                                                                end
                                                            end
                                                        end
                                                    end

                                                    -- Unique2 deductions
                                                    if #Unique2 > 0 then
                                                        if MinUnique2Mines >= #Unique2 then
                                                            -- All Unique2 must be mines
                                                            for _, U in ipairs(Unique2) do
                                                                if Status[U.Part] ~= TileState.Mine then
                                                                    Status[U.Part] = TileState.Mine
                                                                    U.Part.Color = Config.MineColor
                                                                    Changed = true
                                                                    DirtyTiles[U.Part] = true
                                                                    TryFlagTile(U.Part)
                                                                end
                                                            end
                                                        elseif MaxUnique2Mines <= 0 then
                                                            -- All Unique2 must be safe
                                                            for _, U in ipairs(Unique2) do
                                                                if Status[U.Part] ~= TileState.Safe then
                                                                    Status[U.Part] = TileState.Safe
                                                                    U.Part.Color = Config.SafeColor
                                                                    Changed = true
                                                                    DirtyTiles[U.Part] = true
                                                                end
                                                            end
                                                        end
                                                    end

                                                    -- Shared tile deductions
                                                    if #Shared > 0 then
                                                        if MinSharedMines >= #Shared then
                                                            -- All shared must be mines
                                                            for _, S in ipairs(Shared) do
                                                                if Status[S.Part] ~= TileState.Mine then
                                                                    Status[S.Part] = TileState.Mine
                                                                    S.Part.Color = Config.MineColor
                                                                    Changed = true
                                                                    DirtyTiles[S.Part] = true
                                                                    TryFlagTile(S.Part)
                                                                end
                                                            end
                                                        elseif MaxSharedMines <= 0 then
                                                            -- All shared must be safe
                                                            for _, S in ipairs(Shared) do
                                                                if Status[S.Part] ~= TileState.Safe then
                                                                    Status[S.Part] = TileState.Safe
                                                                    S.Part.Color = Config.SafeColor
                                                                    Changed = true
                                                                    DirtyTiles[S.Part] = true
                                                                end
                                                            end
                                                        end
                                                    end
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
                end
            end

            -- Phase 3: Queue deep analysis if fast phases found nothing
            if not Changed and Iterations >= Config.MinIterationForPhase3 then
                -- Don't run Phase 3 inline - queue it for async processing
                DeepAnalysisQueued = true
                break -- Exit fast solve loop
            end

            -- Exit early if nothing changed in this iteration
            if not Changed then
                break
            end
        end

        UpdateColors(DirtyTiles)
        DirtyTiles = {}
    end

    -- Deep analysis (Phase 3) - runs asynchronously
    local function DeepSolve()
        if DeepAnalysisRunning then return end
        DeepAnalysisRunning = true
        DeepAnalysisQueued = false

        task.spawn(function()
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

            if #FrontierTiles == 0 or #FrontierTiles > Config.MaxFrontierTilesForPhase3 then
                DeepAnalysisRunning = false
                return
            end

            -- Mark tiles as being analyzed
            for _, Tile in ipairs(FrontierTiles) do
                TilesBeingAnalyzed[Tile.Part] = true
            end
            UpdateColors(TilesBeingAnalyzed)

            local Changed = false
            for TileIdx, Tile in ipairs(FrontierTiles) do
                if TileIdx % Config.YieldEveryNTilesInPhase3 == 0 then
                    RunService.RenderStepped:Wait()
                end

                if Status[Tile.Part] == TileState.Unknown then
                    local function TestHypothesis(AssumeMine)
                        local TestStatus = {}

                        for _, FTile in ipairs(FrontierTiles) do
                            TestStatus[FTile.Part] = Status[FTile.Part]
                        end

                        for R = 1, Rows do
                            for C = 1, Cols do
                                local Part = Grid[R][C]
                                if Part and Status[Part] == TileState.Revealed then
                                    TestStatus[Part] = TileState.Revealed
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
                            DirtyTiles[Tile.Part] = true
                            TryFlagTile(Tile.Part)
                        end
                    elseif SafeValid and not MineValid then
                        if Status[Tile.Part] ~= TileState.Safe then
                            Status[Tile.Part] = TileState.Safe
                            Tile.Part.Color = Config.SafeColor
                            Changed = true
                            DirtyTiles[Tile.Part] = true
                        end
                    end
                end
            end

            -- Clear analyzing markers
            for Part, _ in pairs(TilesBeingAnalyzed) do
                TilesBeingAnalyzed[Part] = nil
                DirtyTiles[Part] = true
            end

            UpdateColors(DirtyTiles)
            DirtyTiles = {}
            DeepAnalysisRunning = false

            -- If changes were found, run fast solve again
            if Changed then
                FastSolve()
            end
        end)
    end

    local FastSolveScheduled = false
    local function ScheduleFastSolve()
        if FastSolveScheduled then return end
        FastSolveScheduled = true
        task.defer(function()
            FastSolve()
            FastSolveScheduled = false

            -- If fast solve queued deep analysis, start it
            if DeepAnalysisQueued and not DeepAnalysisRunning then
                DeepSolve()
            end
        end)
    end

    for R = 1, Rows do
        for C = 1, Cols do
            local Part = Grid[R][C]
            if Part then
                local Connection = Part.Changed:Connect(function(Property)
                    if Property == "Color" and not SuppressColorEvents then
                        ScheduleFastSolve()
                    end
                end)
                table.insert(Connections, Connection)
            end
        end
    end

    FastSolve()

    local function FlagNearbyMines()
        if not SalasanaValue then return end

        -- Collect all unflagged mines
        local MinesToFlag = {}
        for R = 1, Rows do
            for C = 1, Cols do
                local Part = Grid[R][C]
                if Part and Status[Part] == TileState.Mine and not IsFlagged(Part) then
                    table.insert(MinesToFlag, Part)
                end
            end
        end

        -- Shuffle the mines to flag them in a random order (more human-like)
        for i = #MinesToFlag, 2, -1 do
            local j = math.random(1, i)
            MinesToFlag[i], MinesToFlag[j] = MinesToFlag[j], MinesToFlag[i]
        end

        -- Flag mines with realistic delays
        local FlaggedCount = 0
        for _, Part in ipairs(MinesToFlag) do
            if TryFlagTile(Part) then
                FlaggedCount = FlaggedCount + 1

                -- Add a longer pause after every batch
                if FlaggedCount % Config.FlagBatchSize == 0 then
                    local BatchDelay = Config.FlagBatchDelayMin + math.random() * (Config.FlagBatchDelayMax - Config.FlagBatchDelayMin)
                    task.wait(BatchDelay)
                else
                    -- Normal delay between individual flags
                    local NormalDelay = Config.FlagDelayMin + math.random() * (Config.FlagDelayMax - Config.FlagDelayMin)
                    task.wait(NormalDelay)
                end
            end
        end
    end

    local MainLoop = nil
    MainLoop = spawn(function()
        while BoardActive and not ReinitializeRequested do
            task.wait(Config.HeartbeatInterval)
            if BoardActive and not ReinitializeRequested then
                ScheduleFastSolve()
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

    task.spawn(function()
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