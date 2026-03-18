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
