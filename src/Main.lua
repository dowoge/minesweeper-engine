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
