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
