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
