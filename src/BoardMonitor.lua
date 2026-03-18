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
