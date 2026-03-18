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
