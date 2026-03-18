-- Minesweeper Engine (compiled 18-Mar-26 0:31:54.05 EST)

-- ======== Config ========
local Config = {
    -- Solving
    MaxSolvingIterations = 50,
    MaxHypothesisIterations = 30,
    MinIterationForPhase3 = 1,
    MaxFrontierTilesForPhase3 = 300,
    YieldEveryNTilesInPhase3 = 10,
    YieldEveryNPairwiseChecks = 20,
    YieldEveryNColorUpdates = 100,

    -- Probability Engine
    MaxBoxesPerRegion = 30,
    YieldEveryNRecursions = 500,

    -- Flagging
    AutoFlagDistance = 22.5,
    FlagDelayMin = 0.1,
    FlagDelayMax = 0.4,
    FlagBatchSize = 3,
    FlagBatchDelayMin = 0.8,
    FlagBatchDelayMax = 1.5,

    -- Board stuff
    HeartbeatInterval = 1,
    BoardStableThreshold = 3,
    MinPartsForValidBoard = 100,
    ReinitDelay = 0.5,
    TotalMines = nil, -- Set if known (enables off-edge probability)

    -- Grid detection
    PositionTolerance = 0.01,

    -- Visuals
    SafeColor = Color3.fromRGB(0, 255, 0),
    MineColor = Color3.fromRGB(255, 0, 0),
    UncertainColor = Color3.fromRGB(255, 200, 0),
    AnalyzingColor = Color3.fromRGB(0, 200, 255),
    BestGuessColor = Color3.fromRGB(0, 150, 255),
}

local TileState = {
    Revealed = 1,
    Mine = 2,
    Safe = 3,
    Unknown = 4
}

-- Roblox services (available to all modules after concatenation)
local PartsFolder = workspace:FindFirstChild("Flag") and workspace.Flag:FindFirstChild("Parts")
if not PartsFolder then error("Parts folder not found") end

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local RunService = game:GetService("RunService")

-- Shared board state, populated by InitializeBoard, reset on reinit
local Board = {
    Grid = nil,
    Rows = 0,
    Cols = 0,
    Status = {},
    OriginalColors = {},
    DirtyTiles = {},
    LastKnownRevealed = {},
    TilesBeingAnalyzed = {},
    DeepAnalysisQueued = false,
    DeepAnalysisRunning = false,
    SuppressColorEvents = false,
    NeighborCache = {},
    PartToCoords = {},
    SalasanaValue = nil,
    Connections = {},
    Active = true,
    ReinitializeRequested = false,
}

-- ======== Grid ========
local Grid = {}

function Grid.Init(Parts)
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

    Board.Cols = #Xs
    Board.Rows = #Zs

    local function FindIndex(SortedList, Value)
        local BestI, BestD = 1, math.huge
        for I, V in ipairs(SortedList) do
            local D = math.abs(V - Value)
            if D < BestD then BestD, BestI = D, I end
        end
        return BestI
    end

    Board.Grid = {}
    for R = 1, Board.Rows do
        Board.Grid[R] = {}
        for C = 1, Board.Cols do Board.Grid[R][C] = nil end
    end

    for _, Part in ipairs(Parts) do
        local C = FindIndex(Xs, Part.Position.X)
        local R = FindIndex(Zs, Part.Position.Z)
        Board.Grid[R][C] = Part
    end

    -- Build neighbor cache
    Board.NeighborCache = {}
    Board.PartToCoords = {}
    for R = 1, Board.Rows do
        Board.NeighborCache[R] = {}
        for C = 1, Board.Cols do
            if Board.Grid[R][C] then
                Board.NeighborCache[R][C] = Grid.ComputeNeighbors(R, C)
                Board.PartToCoords[Board.Grid[R][C]] = {R = R, C = C}
            end
        end
    end

    print("Grid:", Board.Rows, "x", Board.Cols)
end

function Grid.InBounds(R, C)
    return R >= 1 and R <= Board.Rows and C >= 1 and C <= Board.Cols
end

function Grid.ComputeNeighbors(R, C)
    local Out = {}
    for Dr = -1, 1 do
        for Dc = -1, 1 do
            if not (Dr == 0 and Dc == 0) then
                local Nr, Nc = R + Dr, C + Dc
                if Grid.InBounds(Nr, Nc) then
                    local Part = Board.Grid[Nr][Nc]
                    if Part then table.insert(Out, {R = Nr, C = Nc, Part = Part}) end
                end
            end
        end
    end
    return Out
end

function Grid.GetNeighbors(R, C)
    return (Board.NeighborCache[R] and Board.NeighborCache[R][C]) or {}
end

function Grid.GetCoords(Part)
    return Board.PartToCoords[Part]
end

function Grid.GetRevealedNumber(Part)
    local Gui = Part:FindFirstChild("NumberGui")
    if not Gui then return nil end
    local TextLabel = Gui:FindFirstChild("TextLabel")
    if not TextLabel then return nil end
    local Text = TextLabel.Text
    if Text == "" then return 0 end
    return tonumber(Text)
end

-- ======== Visual ========
local Visual = {}

function Visual.UpdateColors(TilesToColor)
    Board.SuppressColorEvents = true
    local ColorUpdates = 0
    for Part, _ in pairs(TilesToColor) do
        ColorUpdates = ColorUpdates + 1
        if ColorUpdates % Config.YieldEveryNColorUpdates == 0 then
            RunService.RenderStepped:Wait()
        end

        local IsCurrentlyRevealed = Part:FindFirstChild("NumberGui") ~= nil
        if IsCurrentlyRevealed then
            -- Don't color revealed tiles
        elseif Board.TilesBeingAnalyzed[Part] then
            Part.Color = Config.AnalyzingColor
        elseif Board.Status[Part] == TileState.Mine then
            Part.Color = Config.MineColor
        elseif Board.Status[Part] == TileState.Safe then
            Part.Color = Config.SafeColor
        elseif Board.Status[Part] == TileState.Unknown then
            Part.Color = Config.UncertainColor
        else
            local OrigColor = Board.OriginalColors[Part]
            Part.Color = OrigColor
        end
    end
    Board.SuppressColorEvents = false
end

-- ======== Flagging ========
local Flagging = {}

function Flagging.IsFlagged(Part)
    return Part:FindFirstChildOfClass("Model") ~= nil
end

function Flagging.TryFlagTile(Part)
    if not Board.SalasanaValue then return false end
    if Flagging.IsFlagged(Part) then return false end

    local Character = LocalPlayer.Character
    if not Character then return false end

    local RootPart = Character:FindFirstChild("HumanoidRootPart")
    if not RootPart then return false end

    local Distance = (RootPart.Position - Part.Position).Magnitude
    if Distance >= Config.AutoFlagDistance then return false end

    local Success = pcall(function()
        ReplicatedStorage.Events.FlagEvents.PlaceFlag:FireServer(Part, Board.SalasanaValue, true)
    end)

    if Success then
        print("Flagged mine at distance:", math.floor(Distance))
    end

    return Success
end

function Flagging.FlagNearbyMines()
    if not Board.SalasanaValue then return end

    local MinesToFlag = {}
    for R = 1, Board.Rows do
        for C = 1, Board.Cols do
            local Part = Board.Grid[R][C]
            if Part and Board.Status[Part] == TileState.Mine and not Flagging.IsFlagged(Part) then
                table.insert(MinesToFlag, Part)
            end
        end
    end

    -- Shuffle for human-like flagging
    for i = #MinesToFlag, 2, -1 do
        local j = math.random(1, i)
        MinesToFlag[i], MinesToFlag[j] = MinesToFlag[j], MinesToFlag[i]
    end

    local FlaggedCount = 0
    for _, Part in ipairs(MinesToFlag) do
        if Flagging.TryFlagTile(Part) then
            FlaggedCount = FlaggedCount + 1
            if FlaggedCount % Config.FlagBatchSize == 0 then
                local BatchDelay = Config.FlagBatchDelayMin + math.random() * (Config.FlagBatchDelayMax - Config.FlagBatchDelayMin)
                task.wait(BatchDelay)
            else
                local NormalDelay = Config.FlagDelayMin + math.random() * (Config.FlagDelayMax - Config.FlagDelayMin)
                task.wait(NormalDelay)
            end
        end
    end
end

-- ======== Solver ========
local Solver = {}

local function GetCellInfo(R, C)
    if not Grid.InBounds(R, C) then return nil end
    local Part = Board.Grid[R][C]
    if not Part then return nil end
    return {
        R = R,
        C = C,
        Part = Part,
        status = Board.Status[Part],
        Number = Board.Status[Part] == TileState.Revealed and Grid.GetRevealedNumber(Part) or nil
    }
end

-- Fixed: looks up Status from Board.Status[Info.Part] instead of Info.status
-- (neighbor cache entries don't have a .status field)
local function GetUnknownsAndMines(Neighbors)
    local Unknowns = {}
    local Mines = {}
    for _, Info in ipairs(Neighbors) do
        local S = Board.Status[Info.Part]
        if S == TileState.Unknown then
            table.insert(Unknowns, Info)
        elseif S == TileState.Mine then
            table.insert(Mines, Info)
        end
    end
    return Unknowns, Mines
end

function Solver.FastSolve()
    local NewlyRevealed = {}

    for R = 1, Board.Rows do
        for C = 1, Board.Cols do
            local Part = Board.Grid[R][C]
            if Part then
                if not Board.OriginalColors[Part] then
                    Board.OriginalColors[Part] = Part.Color
                end

                local HasGui = Part:FindFirstChild("NumberGui") ~= nil
                if HasGui then
                    if not Board.LastKnownRevealed[Part] then
                        Board.LastKnownRevealed[Part] = true
                        table.insert(NewlyRevealed, {R = R, C = C, Part = Part})
                        Board.DirtyTiles[Part] = true

                        local Neighbors = Grid.GetNeighbors(R, C)
                        for _, Neighbor in ipairs(Neighbors) do
                            Board.DirtyTiles[Neighbor.Part] = true
                        end
                    end
                    Board.Status[Part] = TileState.Revealed
                elseif Board.Status[Part] == nil then
                    Board.Status[Part] = TileState.Unknown
                end
            end
        end
    end

    if next(NewlyRevealed) == nil and next(Board.DirtyTiles) == nil then
        return
    end

    local Iterations = 0
    while Iterations < Config.MaxSolvingIterations do
        Iterations = Iterations + 1
        local Changed = false

        -- Phase 1: Basic constraint propagation
        for R = 1, Board.Rows do
            for C = 1, Board.Cols do
                local Part = Board.Grid[R][C]
                if Part and Board.Status[Part] == TileState.Revealed then
                    local Number = Grid.GetRevealedNumber(Part)
                    if Number then
                        local NeighborsList = Grid.GetNeighbors(R, C)
                        local Unknowns = {}
                        local KnownMines = 0
                        for _, Info in ipairs(NeighborsList) do
                            local NeighborPart = Info.Part
                            local NeighborStatus = Board.Status[NeighborPart]
                            if NeighborStatus == TileState.Mine then
                                KnownMines = KnownMines + 1
                            elseif NeighborStatus == TileState.Unknown then
                                table.insert(Unknowns, NeighborPart)
                            end
                        end
                        local Need = Number - KnownMines
                        if Need <= 0 and #Unknowns > 0 then
                            for _, UnknownPart in ipairs(Unknowns) do
                                if Board.Status[UnknownPart] ~= TileState.Safe then
                                    Board.Status[UnknownPart] = TileState.Safe
                                    UnknownPart.Color = Config.SafeColor
                                    Changed = true
                                    Board.DirtyTiles[UnknownPart] = true
                                end
                            end
                        elseif Need == #Unknowns and #Unknowns > 0 then
                            for _, UnknownPart in ipairs(Unknowns) do
                                if Board.Status[UnknownPart] ~= TileState.Mine then
                                    Board.Status[UnknownPart] = TileState.Mine
                                    UnknownPart.Color = Config.MineColor
                                    Changed = true
                                    Board.DirtyTiles[UnknownPart] = true
                                    Flagging.TryFlagTile(UnknownPart)
                                end
                            end
                        end
                    end
                end
            end
        end

        -- Phase 2: Pairwise constraint deduction (only if Phase 1 found nothing)
        if not Changed then
            local PairwiseChecks = 0
            for R = 1, Board.Rows do
            for C = 1, Board.Cols do
                local Cell = GetCellInfo(R, C)
                if Cell and Cell.status == TileState.Revealed and Cell.Number and Cell.Number > 0 then
                    PairwiseChecks = PairwiseChecks + 1
                    if PairwiseChecks % Config.YieldEveryNPairwiseChecks == 0 then
                        RunService.RenderStepped:Wait()
                    end
                    local NeighborsList = Grid.GetNeighbors(R, C)
                    local Unknowns1, Mines1 = GetUnknownsAndMines(NeighborsList)
                    local Remaining1 = Cell.Number - #Mines1
                    if #Unknowns1 > 0 and Remaining1 > 0 then
                        for Dr = -1, 1 do
                            for Dc = -1, 1 do
                                if not (Dr == 0 and Dc == 0) then
                                    local Nr, Nc = R + Dr, C + Dc
                                    local Neighbor = GetCellInfo(Nr, Nc)

                                    if Neighbor and Neighbor.status == TileState.Revealed and Neighbor.Number and Neighbor.Number > 0 then
                                        local Neighbors2 = Grid.GetNeighbors(Nr, Nc)
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
                                            if #Shared > 0 or #Unique1 == 0 or #Unique2 == 0 then
                                                local MaxSharedMines = math.min(#Shared, Remaining1, Remaining2)
                                                local MinSharedMines = math.max(0, Remaining1 - #Unique1, Remaining2 - #Unique2)

                                                local MinUnique1Mines = Remaining1 - MaxSharedMines
                                                local MaxUnique1Mines = Remaining1 - MinSharedMines

                                                local MinUnique2Mines = Remaining2 - MaxSharedMines
                                                local MaxUnique2Mines = Remaining2 - MinSharedMines

                                                -- Unique1 deductions
                                                if #Unique1 > 0 then
                                                    if MinUnique1Mines >= #Unique1 then
                                                        for _, U in ipairs(Unique1) do
                                                            if Board.Status[U.Part] ~= TileState.Mine then
                                                                Board.Status[U.Part] = TileState.Mine
                                                                U.Part.Color = Config.MineColor
                                                                Changed = true
                                                                Board.DirtyTiles[U.Part] = true
                                                                Flagging.TryFlagTile(U.Part)
                                                            end
                                                        end
                                                    elseif MaxUnique1Mines <= 0 then
                                                        for _, U in ipairs(Unique1) do
                                                            if Board.Status[U.Part] ~= TileState.Safe then
                                                                Board.Status[U.Part] = TileState.Safe
                                                                U.Part.Color = Config.SafeColor
                                                                Changed = true
                                                                Board.DirtyTiles[U.Part] = true
                                                            end
                                                        end
                                                    end
                                                end

                                                -- Unique2 deductions
                                                if #Unique2 > 0 then
                                                    if MinUnique2Mines >= #Unique2 then
                                                        for _, U in ipairs(Unique2) do
                                                            if Board.Status[U.Part] ~= TileState.Mine then
                                                                Board.Status[U.Part] = TileState.Mine
                                                                U.Part.Color = Config.MineColor
                                                                Changed = true
                                                                Board.DirtyTiles[U.Part] = true
                                                                Flagging.TryFlagTile(U.Part)
                                                            end
                                                        end
                                                    elseif MaxUnique2Mines <= 0 then
                                                        for _, U in ipairs(Unique2) do
                                                            if Board.Status[U.Part] ~= TileState.Safe then
                                                                Board.Status[U.Part] = TileState.Safe
                                                                U.Part.Color = Config.SafeColor
                                                                Changed = true
                                                                Board.DirtyTiles[U.Part] = true
                                                            end
                                                        end
                                                    end
                                                end

                                                -- Shared tile deductions
                                                if #Shared > 0 then
                                                    if MinSharedMines >= #Shared then
                                                        for _, S in ipairs(Shared) do
                                                            if Board.Status[S.Part] ~= TileState.Mine then
                                                                Board.Status[S.Part] = TileState.Mine
                                                                S.Part.Color = Config.MineColor
                                                                Changed = true
                                                                Board.DirtyTiles[S.Part] = true
                                                                Flagging.TryFlagTile(S.Part)
                                                            end
                                                        end
                                                    elseif MaxSharedMines <= 0 then
                                                        for _, S in ipairs(Shared) do
                                                            if Board.Status[S.Part] ~= TileState.Safe then
                                                                Board.Status[S.Part] = TileState.Safe
                                                                S.Part.Color = Config.SafeColor
                                                                Changed = true
                                                                Board.DirtyTiles[S.Part] = true
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
            Board.DeepAnalysisQueued = true
            break
        end

        if not Changed then
            break
        end
    end

    Visual.UpdateColors(Board.DirtyTiles)
    Board.DirtyTiles = {}
end

function Solver.DeepSolve()
    if Board.DeepAnalysisRunning then return end
    Board.DeepAnalysisRunning = true
    Board.DeepAnalysisQueued = false

    task.spawn(function()
        -- Try probability engine first, fall back to hypothesis testing
        local ProbResult = ProbabilityEngine.Solve()

        if not ProbResult then
            -- Fallback: hypothesis testing (original DeepSolve)
            Solver.HypothesisTest()
        end

        Board.DeepAnalysisRunning = false
    end)
end

function Solver.HypothesisTest()
    local FrontierTiles = Solver.GetFrontierTiles()

    if #FrontierTiles == 0 or #FrontierTiles > Config.MaxFrontierTilesForPhase3 then
        return
    end

    -- Mark tiles as being analyzed
    for _, Tile in ipairs(FrontierTiles) do
        Board.TilesBeingAnalyzed[Tile.Part] = true
    end
    Visual.UpdateColors(Board.TilesBeingAnalyzed)

    local Changed = false
    for TileIdx, Tile in ipairs(FrontierTiles) do
        if TileIdx % Config.YieldEveryNTilesInPhase3 == 0 then
            RunService.RenderStepped:Wait()
        end

        if Board.Status[Tile.Part] == TileState.Unknown then
            local function TestHypothesis(AssumeMine)
                local TestStatus = {}

                for _, FTile in ipairs(FrontierTiles) do
                    TestStatus[FTile.Part] = Board.Status[FTile.Part]
                end

                for R = 1, Board.Rows do
                    for C = 1, Board.Cols do
                        local Part = Board.Grid[R][C]
                        if Part and Board.Status[Part] == TileState.Revealed then
                            TestStatus[Part] = TileState.Revealed
                        end
                    end
                end

                TestStatus[Tile.Part] = AssumeMine and TileState.Mine or TileState.Safe

                local TestChanged = true
                local TestIter = 0
                while TestChanged and TestIter < Config.MaxHypothesisIterations do
                    TestIter = TestIter + 1
                    TestChanged = false

                    for TR = 1, Board.Rows do
                        for TC = 1, Board.Cols do
                            local TPart = Board.Grid[TR][TC]
                            if TPart and TestStatus[TPart] == TileState.Revealed then
                                local TNumber = Grid.GetRevealedNumber(TPart)
                                if TNumber then
                                    local TNeighbors = Grid.GetNeighbors(TR, TC)
                                    local TUnknowns = {}
                                    local TMines = 0

                                    for _, TInfo in ipairs(TNeighbors) do
                                        local TNeighborPart = TInfo.Part
                                        local TStatus = TestStatus[TNeighborPart] or Board.Status[TNeighborPart]
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
                if Board.Status[Tile.Part] ~= TileState.Mine then
                    Board.Status[Tile.Part] = TileState.Mine
                    Tile.Part.Color = Config.MineColor
                    Changed = true
                    Board.DirtyTiles[Tile.Part] = true
                    Flagging.TryFlagTile(Tile.Part)
                end
            elseif SafeValid and not MineValid then
                if Board.Status[Tile.Part] ~= TileState.Safe then
                    Board.Status[Tile.Part] = TileState.Safe
                    Tile.Part.Color = Config.SafeColor
                    Changed = true
                    Board.DirtyTiles[Tile.Part] = true
                end
            end
        end
    end

    -- Clear analyzing markers
    for Part, _ in pairs(Board.TilesBeingAnalyzed) do
        Board.TilesBeingAnalyzed[Part] = nil
        Board.DirtyTiles[Part] = true
    end

    Visual.UpdateColors(Board.DirtyTiles)
    Board.DirtyTiles = {}

    if Changed then
        Solver.FastSolve()
    end
end

function Solver.GetFrontierTiles()
    local FrontierTiles = {}
    for R = 1, Board.Rows do
        for C = 1, Board.Cols do
            local Part = Board.Grid[R][C]
            if Part and Board.Status[Part] == TileState.Unknown then
                local NeighborsList = Grid.GetNeighbors(R, C)
                local HasRevealedNeighbor = false
                for _, Info in ipairs(NeighborsList) do
                    if Board.Status[Info.Part] == TileState.Revealed then
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
    return FrontierTiles
end

-- ======== ProbabilityEngine ========
local ProbabilityEngine = {}

-- Precomputed binomial coefficients C[n][k] for n <= 50
local BinomialCache = {}
do
    for n = 0, 50 do
        BinomialCache[n] = {}
        BinomialCache[n][0] = 1
        for k = 1, n do
            BinomialCache[n][k] = BinomialCache[n - 1][k - 1] + (BinomialCache[n - 1][k] or 0)
        end
    end
end

local function Choose(n, k)
    if k < 0 or k > n then return 0 end
    if n <= 50 then return BinomialCache[n][k] end
    -- Fallback for large n (shouldn't happen with box sizes <= 50)
    local result = 1
    if k > n - k then k = n - k end
    for i = 0, k - 1 do
        result = result * (n - i) / (i + 1)
    end
    return math.floor(result + 0.5)
end

-- Step 1: Build witness/box graph
-- A witness = revealed tile with Number > 0 and at least 1 unknown neighbor
-- A box = group of frontier tiles sharing the exact same set of witnesses
function ProbabilityEngine.BuildWitnessBoxGraph(FrontierTiles)
    -- Build witness set for each frontier tile
    local TileWitnesses = {} -- Part → sorted list of witness keys
    local WitnessSet = {}    -- "R,C" → {R, C, Part, Number, Remaining}
    local FrontierLookup = {} -- Part → true

    for _, Tile in ipairs(FrontierTiles) do
        FrontierLookup[Tile.Part] = true
    end

    for _, Tile in ipairs(FrontierTiles) do
        local Witnesses = {}
        local NeighborsList = Grid.GetNeighbors(Tile.R, Tile.C)
        for _, Info in ipairs(NeighborsList) do
            if Board.Status[Info.Part] == TileState.Revealed then
                local Number = Grid.GetRevealedNumber(Info.Part)
                if Number and Number > 0 then
                    local Key = Info.R .. "," .. Info.C
                    table.insert(Witnesses, Key)

                    if not WitnessSet[Key] then
                        -- Count known mines around this witness
                        local WNeighbors = Grid.GetNeighbors(Info.R, Info.C)
                        local KnownMines = 0
                        for _, WN in ipairs(WNeighbors) do
                            if Board.Status[WN.Part] == TileState.Mine then
                                KnownMines = KnownMines + 1
                            end
                        end
                        WitnessSet[Key] = {
                            R = Info.R, C = Info.C, Part = Info.Part,
                            Number = Number, Remaining = Number - KnownMines,
                            Key = Key
                        }
                    end
                end
            end
        end
        table.sort(Witnesses)
        TileWitnesses[Tile.Part] = table.concat(Witnesses, "|")
    end

    -- Group tiles into boxes by witness signature
    local SignatureToBox = {} -- signature string → box index
    local Boxes = {}         -- {tiles = {Part, ...}, size = N, witnesses = {Key, ...}, signatureStr = "..."}

    for _, Tile in ipairs(FrontierTiles) do
        local Sig = TileWitnesses[Tile.Part]
        if not SignatureToBox[Sig] then
            local BoxIdx = #Boxes + 1
            SignatureToBox[Sig] = BoxIdx

            -- Parse witness keys from signature
            local WitnessKeys = {}
            for Key in Sig:gmatch("[^|]+") do
                table.insert(WitnessKeys, Key)
            end

            Boxes[BoxIdx] = {
                tiles = {},
                size = 0,
                witnessKeys = WitnessKeys,
                index = BoxIdx
            }
        end
        local Box = Boxes[SignatureToBox[Sig]]
        table.insert(Box.tiles, Tile)
        Box.size = Box.size + 1
    end

    -- Build witness → boxes mapping
    local WitnessToBoxes = {} -- Key → {boxIdx, ...}
    for BoxIdx, Box in ipairs(Boxes) do
        for _, Key in ipairs(Box.witnessKeys) do
            if not WitnessToBoxes[Key] then
                WitnessToBoxes[Key] = {}
            end
            table.insert(WitnessToBoxes[Key], BoxIdx)
        end
    end

    return Boxes, WitnessSet, WitnessToBoxes, FrontierLookup
end

-- Step 2: Find independent regions via flood fill on witness-box connections
function ProbabilityEngine.FindRegions(Boxes, WitnessToBoxes)
    local BoxRegion = {} -- boxIdx → regionIdx
    local Regions = {}   -- {{boxIndices = {...}, witnessKeys = {...}}, ...}

    for StartBoxIdx = 1, #Boxes do
        if not BoxRegion[StartBoxIdx] then
            local RegionIdx = #Regions + 1
            local Region = {boxIndices = {}, witnessKeys = {}}
            local WitnessVisited = {}

            -- BFS from this box
            local Queue = {StartBoxIdx}
            BoxRegion[StartBoxIdx] = RegionIdx

            while #Queue > 0 do
                local BoxIdx = table.remove(Queue, 1)
                table.insert(Region.boxIndices, BoxIdx)

                for _, Key in ipairs(Boxes[BoxIdx].witnessKeys) do
                    if not WitnessVisited[Key] then
                        WitnessVisited[Key] = true
                        table.insert(Region.witnessKeys, Key)

                        -- Visit all boxes connected to this witness
                        for _, ConnectedBoxIdx in ipairs(WitnessToBoxes[Key]) do
                            if not BoxRegion[ConnectedBoxIdx] then
                                BoxRegion[ConnectedBoxIdx] = RegionIdx
                                table.insert(Queue, ConnectedBoxIdx)
                            end
                        end
                    end
                end
            end

            Regions[RegionIdx] = Region
        end
    end

    return Regions
end

-- Step 3: Enumerate valid mine distributions for a region
-- Returns: list of {assignment = {[boxIdx] = mineCount}, weight = product of C(size, count)}
function ProbabilityEngine.EnumerateRegion(Region, Boxes, WitnessSet, WitnessToBoxes)
    local BoxIndices = Region.boxIndices
    local WitnessKeys = Region.witnessKeys
    local NumBoxes = #BoxIndices

    if NumBoxes > Config.MaxBoxesPerRegion then
        return nil -- Too complex, fall back to hypothesis testing
    end

    -- For each witness, track: how many mines assigned so far, and remaining capacity
    -- WitnessState[Key] = {assigned = 0, remaining = Witness.Remaining, unprocessedBoxes = count}
    local function MakeWitnessState()
        local State = {}
        for _, Key in ipairs(WitnessKeys) do
            local Witness = WitnessSet[Key]
            -- Count how many boxes for this witness are in this region
            local BoxCount = 0
            for _, BI in ipairs(WitnessToBoxes[Key]) do
                for _, RegBI in ipairs(BoxIndices) do
                    if BI == RegBI then BoxCount = BoxCount + 1; break end
                end
            end
            State[Key] = {
                assigned = 0,
                remaining = Witness.Remaining,
                unprocessed = BoxCount
            }
        end
        return State
    end

    local Solutions = {}
    local Assignment = {} -- [boxIdx] = mineCount
    local RecursionCount = 0

    local function Recurse(Depth, WState)
        RecursionCount = RecursionCount + 1
        if RecursionCount % Config.YieldEveryNRecursions == 0 then
            RunService.RenderStepped:Wait()
        end

        if Depth > NumBoxes then
            -- Check all witnesses are satisfied (assigned == remaining)
            for _, Key in ipairs(WitnessKeys) do
                if WState[Key].assigned ~= WState[Key].remaining then
                    return
                end
            end

            -- Valid solution: compute weight = product of C(boxSize, mineCount)
            local Weight = 1
            for _, BI in ipairs(BoxIndices) do
                Weight = Weight * Choose(Boxes[BI].size, Assignment[BI])
            end

            local AssignCopy = {}
            for K, V in pairs(Assignment) do AssignCopy[K] = V end
            table.insert(Solutions, {assignment = AssignCopy, weight = Weight})
            return
        end

        local BoxIdx = BoxIndices[Depth]
        local Box = Boxes[BoxIdx]

        -- Try mine counts M = 0..Box.size
        for M = 0, Box.size do
            -- Check feasibility: for each witness of this box, assigned + M must be feasible
            local Feasible = true
            for _, Key in ipairs(Box.witnessKeys) do
                local WS = WState[Key]
                local NewAssigned = WS.assigned + M
                if NewAssigned > WS.remaining then
                    Feasible = false
                    break
                end
                -- If no more boxes will contribute to this witness, need must be exactly met
                local RemainingNeed = WS.remaining - NewAssigned
                local RemainingUnprocessed = WS.unprocessed - 1
                if RemainingNeed > 0 and RemainingUnprocessed == 0 then
                    Feasible = false
                    break
                end
            end

            if Feasible then
                Assignment[BoxIdx] = M
                -- Update witness state
                for _, Key in ipairs(Box.witnessKeys) do
                    WState[Key].assigned = WState[Key].assigned + M
                    WState[Key].unprocessed = WState[Key].unprocessed - 1
                end

                Recurse(Depth + 1, WState)

                -- Restore witness state
                for _, Key in ipairs(Box.witnessKeys) do
                    WState[Key].assigned = WState[Key].assigned - M
                    WState[Key].unprocessed = WState[Key].unprocessed + 1
                end
            end
        end
    end

    local WState = MakeWitnessState()
    Recurse(1, WState)

    return Solutions
end

-- Step 4: Compute mine probabilities from enumerated solutions
function ProbabilityEngine.ComputeProbabilities(Boxes, RegionSolutions, BoxIndices)
    local BoxProb = {} -- [boxIdx] = probability of mine

    local TotalWeight = 0
    local BoxMineWeight = {} -- [boxIdx] = sum of (mineCount/boxSize * weight)

    for _, BI in ipairs(BoxIndices) do
        BoxMineWeight[BI] = 0
    end

    for _, Sol in ipairs(RegionSolutions) do
        TotalWeight = TotalWeight + Sol.weight
        for _, BI in ipairs(BoxIndices) do
            local MineCount = Sol.assignment[BI]
            local BoxSize = Boxes[BI].size
            BoxMineWeight[BI] = BoxMineWeight[BI] + (MineCount / BoxSize) * Sol.weight
        end
    end

    if TotalWeight > 0 then
        for _, BI in ipairs(BoxIndices) do
            BoxProb[BI] = BoxMineWeight[BI] / TotalWeight
        end
    end

    return BoxProb
end

-- Main solve function: builds graph, enumerates, computes probabilities, makes decisions
function ProbabilityEngine.Solve()
    local FrontierTiles = Solver.GetFrontierTiles()

    if #FrontierTiles == 0 or #FrontierTiles > Config.MaxFrontierTilesForPhase3 then
        return false
    end

    -- Mark tiles as being analyzed
    for _, Tile in ipairs(FrontierTiles) do
        Board.TilesBeingAnalyzed[Tile.Part] = true
    end
    Visual.UpdateColors(Board.TilesBeingAnalyzed)

    local Boxes, WitnessSet, WitnessToBoxes, FrontierLookup = ProbabilityEngine.BuildWitnessBoxGraph(FrontierTiles)

    if #Boxes == 0 then
        -- Clear analyzing markers
        ProbabilityEngine.ClearAnalyzing()
        return false
    end

    print("ProbEngine: " .. #FrontierTiles .. " frontier tiles → " .. #Boxes .. " boxes")

    local Regions = ProbabilityEngine.FindRegions(Boxes, WitnessToBoxes)
    print("ProbEngine: " .. #Regions .. " independent region(s)")

    -- Solve each region
    local AllBoxProbs = {} -- [boxIdx] = probability
    local FallbackNeeded = false

    for _, Region in ipairs(Regions) do
        local Solutions = ProbabilityEngine.EnumerateRegion(Region, Boxes, WitnessSet, WitnessToBoxes)

        if not Solutions then
            -- Region too complex, mark for hypothesis fallback
            print("ProbEngine: Region too complex (" .. #Region.boxIndices .. " boxes), falling back")
            FallbackNeeded = true
        elseif #Solutions == 0 then
            -- No valid solutions found (shouldn't happen on valid board)
            warn("ProbEngine: No valid solutions for region!")
        else
            print("ProbEngine: Region solved with " .. #Solutions .. " valid distribution(s)")
            local RegionProbs = ProbabilityEngine.ComputeProbabilities(Boxes, Solutions, Region.boxIndices)
            for BI, Prob in pairs(RegionProbs) do
                AllBoxProbs[BI] = Prob
            end
        end
    end

    -- Step 5: Off-edge probability (if total mines known)
    local OffEdgeProb = nil
    if Config.TotalMines then
        local TotalFrontierTiles = #FrontierTiles
        local TotalUnknowns = 0
        local KnownMines = 0

        for R = 1, Board.Rows do
            for C = 1, Board.Cols do
                local Part = Board.Grid[R][C]
                if Part then
                    if Board.Status[Part] == TileState.Unknown then
                        TotalUnknowns = TotalUnknowns + 1
                    elseif Board.Status[Part] == TileState.Mine then
                        KnownMines = KnownMines + 1
                    end
                end
            end
        end

        local OffEdgeTiles = TotalUnknowns - TotalFrontierTiles
        local RemainingMines = Config.TotalMines - KnownMines

        -- Estimate expected frontier mines from probabilities
        local ExpectedFrontierMines = 0
        for BI, Prob in pairs(AllBoxProbs) do
            ExpectedFrontierMines = ExpectedFrontierMines + Prob * Boxes[BI].size
        end

        if OffEdgeTiles > 0 then
            local ExpectedOffEdgeMines = RemainingMines - ExpectedFrontierMines
            OffEdgeProb = math.max(0, math.min(1, ExpectedOffEdgeMines / OffEdgeTiles))
        end
    end

    -- Step 6: Decision — apply deterministic results and find best guess
    local Changed = false
    local BestGuessProb = 1.0
    local BestGuessTile = nil

    for BI, Prob in pairs(AllBoxProbs) do
        local Box = Boxes[BI]
        if Prob == 0 then
            -- Provably safe
            for _, Tile in ipairs(Box.tiles) do
                if Board.Status[Tile.Part] ~= TileState.Safe then
                    Board.Status[Tile.Part] = TileState.Safe
                    Tile.Part.Color = Config.SafeColor
                    Changed = true
                    Board.DirtyTiles[Tile.Part] = true
                end
            end
        elseif Prob == 1 then
            -- Provably mine
            for _, Tile in ipairs(Box.tiles) do
                if Board.Status[Tile.Part] ~= TileState.Mine then
                    Board.Status[Tile.Part] = TileState.Mine
                    Tile.Part.Color = Config.MineColor
                    Changed = true
                    Board.DirtyTiles[Tile.Part] = true
                    Flagging.TryFlagTile(Tile.Part)
                end
            end
        else
            -- Track best guess (lowest mine probability)
            if Prob < BestGuessProb then
                BestGuessProb = Prob
                BestGuessTile = Box.tiles[1]
            end
        end
    end

    -- Check if off-edge is the best guess
    if OffEdgeProb and OffEdgeProb < BestGuessProb then
        -- Off-edge tiles are safer than any frontier tile
        -- Find an off-edge tile to suggest
        for R = 1, Board.Rows do
            for C = 1, Board.Cols do
                local Part = Board.Grid[R][C]
                if Part and Board.Status[Part] == TileState.Unknown and not FrontierLookup[Part] then
                    BestGuessProb = OffEdgeProb
                    BestGuessTile = {R = R, C = C, Part = Part}
                    break
                end
            end
            if BestGuessProb == OffEdgeProb then break end
        end
    end

    -- Highlight best guess tile if no deterministic moves were found
    if not Changed and BestGuessTile then
        print(string.format("ProbEngine: Best guess at (%d,%d) with %.1f%% mine probability",
            BestGuessTile.R, BestGuessTile.C, BestGuessProb * 100))
        BestGuessTile.Part.Color = Config.BestGuessColor
        Board.DirtyTiles[BestGuessTile.Part] = true
    end

    -- Clear analyzing markers
    ProbabilityEngine.ClearAnalyzing()

    Visual.UpdateColors(Board.DirtyTiles)
    Board.DirtyTiles = {}

    if Changed then
        Solver.FastSolve()
    end

    return true
end

function ProbabilityEngine.ClearAnalyzing()
    for Part, _ in pairs(Board.TilesBeingAnalyzed) do
        Board.TilesBeingAnalyzed[Part] = nil
        Board.DirtyTiles[Part] = true
    end
end

-- ======== BoardMonitor ========
local BoardMonitor = {}

function BoardMonitor.Start(InitCallback)
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
            Board.Active = false
            Board.ReinitializeRequested = true

            if Board.Cleanup then
                Board.Cleanup()
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
                        Board.Active = true
                        Board.ReinitializeRequested = false
                        StableCount = 0

                        task.wait(Config.ReinitDelay)
                        InitCallback()
                    end
                else
                    StableCount = 0
                end
            end

            LastChildCount = CurrentCount
        end
    end)
end

-- ======== Main ========
local function InitializeBoard()
    print("Initializing board...")

    -- Reset board state
    Board.Status = {}
    Board.OriginalColors = {}
    Board.DirtyTiles = {}
    Board.LastKnownRevealed = {}
    Board.TilesBeingAnalyzed = {}
    Board.DeepAnalysisQueued = false
    Board.DeepAnalysisRunning = false
    Board.SuppressColorEvents = false
    Board.Connections = {}

    -- Extract salasana value from MouseControl upvalues
    Board.SalasanaValue = nil
    for _, Function in getgc(true) do
        if type(Function) == "function" and islclosure(Function) then
            local FunctionInfo = getinfo(Function)
            if FunctionInfo.source:find("MouseControl") then
                if FunctionInfo.nups == 5 then
                    local Upvalues = getupvalues(FunctionInfo.func)
                    Board.SalasanaValue = Upvalues[#Upvalues]
                    break
                end
            end
        end
    end

    if not Board.SalasanaValue then
        warn("Could not find salasana value - automatic flagging disabled")
    else
        print("Salasana value found - automatic flagging enabled")
    end

    -- Collect parts
    local Parts = {}
    for _, Part in ipairs(PartsFolder:GetChildren()) do
        if Part:IsA("BasePart") then
            table.insert(Parts, Part)
        end
    end
    if #Parts == 0 then error("No parts found") end

    -- Initialize grid
    Grid.Init(Parts)

    -- Connect color change events
    local FastSolveScheduled = false
    local function ScheduleFastSolve()
        if FastSolveScheduled then return end
        FastSolveScheduled = true
        task.defer(function()
            Solver.FastSolve()
            FastSolveScheduled = false

            if Board.DeepAnalysisQueued and not Board.DeepAnalysisRunning then
                Solver.DeepSolve()
            end
        end)
    end

    for R = 1, Board.Rows do
        for C = 1, Board.Cols do
            local Part = Board.Grid[R][C]
            if Part then
                local Connection = Part.Changed:Connect(function(Property)
                    if Property == "Color" and not Board.SuppressColorEvents then
                        ScheduleFastSolve()
                    end
                end)
                table.insert(Board.Connections, Connection)
            end
        end
    end

    -- Initial solve
    Solver.FastSolve()

    -- Main heartbeat loop
    task.spawn(function()
        while Board.Active and not Board.ReinitializeRequested do
            task.wait(Config.HeartbeatInterval)
            if Board.Active and not Board.ReinitializeRequested then
                ScheduleFastSolve()
                Flagging.FlagNearbyMines()
            end
        end
    end)

    -- Cleanup function
    Board.Cleanup = function()
        for _, Connection in ipairs(Board.Connections) do
            Connection:Disconnect()
        end
        Board.Status = {}
        Board.DirtyTiles = {}
        Board.LastKnownRevealed = {}
    end

    print("Minesweeper helper active.")
end

-- Entry point
InitializeBoard()
BoardMonitor.Start(InitializeBoard)

