@echo off
setlocal
set "OUTPUT=build\Minesweeper.lua"
if not exist build mkdir build

echo -- Minesweeper Engine (compiled %date%%time% EST)> "%OUTPUT%"
echo.>> "%OUTPUT%"

for %%f in (Config Grid Visual Flagging Solver ProbabilityEngine BoardMonitor Main) do (
    echo -- ======== %%f ========>> "%OUTPUT%"
    type "src\%%f.lua">> "%OUTPUT%"
    echo.>> "%OUTPUT%"
)

echo Compiled to %OUTPUT%
endlocal
