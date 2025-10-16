-- Decompiled with Medal's Decompiler. (Modified by SignalHub)
-- Decompiled at: 10/14/2025, 1:23:52 PM
-- Cached decompilation

while true do
    local salasanaObject = workspace:FindFirstChild("Salasana")
    if not salasanaObject then
        task.wait()
    end;
    if salasanaObject then
        local salasanaValue = salasanaObject.Value
        salasanaObject.Value = 0
        salasanaObject.Name = ""
        salasanaObject:Destroy()
        local ReplicatedStorage = game:GetService("ReplicatedStorage")
        local Players = game:GetService("Players")
        local RunService = game:GetService("RunService")
        local UserInputService = game:GetService("UserInputService")
        local Teams = game:GetService("Teams")
        local LocalPlayer = Players.LocalPlayer
        local Mouse = LocalPlayer:GetMouse()
        local Camera = workspace.CurrentCamera
        local FlagFolder = workspace:WaitForChild("Flag")
        local PartsFolder = FlagFolder:WaitForChild("Parts")
        local CursorSelection = workspace:WaitForChild("Terrain"):WaitForChild("CursorSelection")
        if UserInputService.TouchEnabled then
            local function addClickDetector(part)
                local clickDetector = Instance.new("ClickDetector")
                clickDetector.Parent = part
                clickDetector.MouseClick:Connect(function()
                    ReplicatedStorage.Events.FlagEvents.PlaceFlag:FireServer(part, salasanaValue, true)
                    if _G.CursorSelectionBox then
                        CursorSelection.Adornee = part
                        task.wait(0.3333333333333333)
                        if CursorSelection.Adornee == part then
                            CursorSelection.Adornee = nil
                        end;
                    end;
                end)
            end;
            for _, part in PartsFolder:GetChildren() do
                if part:IsA("Part") then
                    local clickDetector = Instance.new("ClickDetector")
                    clickDetector.Parent = part
                    clickDetector.MouseClick:Connect(function()
                        ReplicatedStorage.Events.FlagEvents.PlaceFlag:FireServer(part, salasanaValue, true)
                        if _G.CursorSelectionBox then
                            CursorSelection.Adornee = part
                            task.wait(0.3333333333333333)
                            if CursorSelection.Adornee == part then
                                CursorSelection.Adornee = nil
                            end;
                        end;
                    end)
                end;
            end;
            PartsFolder.ChildAdded:Connect(function(newPart)
                if newPart:IsA("Part") then
                    local clickDetector = Instance.new("ClickDetector")
                    clickDetector.Parent = newPart
                    clickDetector.MouseClick:Connect(function()
                        ReplicatedStorage.Events.FlagEvents.PlaceFlag:FireServer(newPart, salasanaValue, true)
                        if _G.CursorSelectionBox then
                            CursorSelection.Adornee = newPart
                            task.wait(0.3333333333333333)
                            if CursorSelection.Adornee == newPart then
                                CursorSelection.Adornee = nil
                            end;
                        end;
                    end)
                end;
            end)
        else
            local Flagless = ReplicatedStorage.Info.Flagless
            local function raycast(screenX, screenY)
                local ray = Camera:ScreenPointToRay(screenX, screenY)
                local rayParams = RaycastParams.new()
                local characterList = {}
                for _, player in Players:GetPlayers() do
                    if player.Character then
                        table.insert(characterList, player.Character)
                    end;
                end;
                rayParams.FilterType = Enum.RaycastFilterType.Exclude
                rayParams.FilterDescendantsInstances = characterList
                return workspace:Raycast(ray.Origin, ray.Direction * 150, rayParams);
            end;
            Mouse.Button1Down:Connect(function()
                local rayResult = raycast(Mouse.X, Mouse.Y)
                if rayResult and (rayResult.Instance and (rayResult.Instance:IsDescendantOf(PartsFolder) and not _G.IgnoreCursor)) then
                    ReplicatedStorage.Events.FlagEvents.PlaceFlag:FireServer(rayResult.Instance, salasanaValue, true)
                end;
            end)
            RunService.RenderStepped:Connect(function()
                local mouseTarget = Mouse.Target
                local character = LocalPlayer.Character
                if character then
                    character = character:FindFirstChild("HumanoidRootPart")
                end;
                if not (mouseTarget and (mouseTarget:IsDescendantOf(FlagFolder) and character)) then
                    if UserInputService.MouseBehavior ~= Enum.MouseBehavior.LockCenter then
                        Mouse.Icon = "rbxasset://textures/Cursors/KeyboardMouse/ArrowFarCursor.png"
                    end;
                    CursorSelection.Adornee = nil
                    return;
                end;
                local targetPart = mouseTarget.Parent == PartsFolder and mouseTarget and mouseTarget or mouseTarget:FindFirstAncestor("Part")
                local shouldHighlight
                if targetPart then
                    if not targetPart:FindFirstChild("NumberGui") then
                        -- Unrevealed tile
                        shouldHighlight = not Flagless.Value
                        if shouldHighlight then
                            if (character.Position - targetPart.Position).Magnitude < 32 and LocalPlayer.Team == Teams.Playing then
                                shouldHighlight = not _G.IgnoreCursor
                            else
                                shouldHighlight = false
                            end;
                        end;
                    else
                        -- Has NumberGui - check if it's a flagged tile
                        local textLabel = targetPart.NumberGui:FindFirstChild("TextLabel")
                        if textLabel then
                            if targetPart.NumberGui.TextLabel.Text ~= "X" then
                                shouldHighlight = false
                            else
                                shouldHighlight = true
                            end;
                        end;
                    end;
                else
                    shouldHighlight = targetPart
                end;
                
                local adornPart = targetPart
                if not (_G.CursorSelectionBox and (shouldHighlight and targetPart)) then
                    adornPart = nil
                end;
                CursorSelection.Adornee = adornPart
                Mouse.Icon = UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter and Mouse.Icon or (shouldHighlight and "rbxasset://textures//DragCursor.png" or "rbxasset://textures/Cursors/KeyboardMouse/ArrowFarCursor.png")
            end)
        end;
    end;
end;
