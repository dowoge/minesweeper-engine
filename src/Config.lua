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
    AutoFlagDistance = 0,
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
