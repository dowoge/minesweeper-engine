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
