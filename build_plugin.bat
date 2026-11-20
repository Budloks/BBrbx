@echo off
REM Build the RBXMonkey BB Studio plugin with Rojo.
REM Usage: build_plugin.bat [--install]
REM   --install  also copies the plugin into %LOCALAPPDATA%\Roblox\Plugins
if not exist build mkdir build
rojo build plugin.project.json -o build\RBXMonkeyBB.rbxm
if errorlevel 1 exit /b 1
if /i "%~1"=="--install" (
    copy /y build\RBXMonkeyBB.rbxm "%LOCALAPPDATA%\Roblox\Plugins\RBXMonkeyBB.rbxm" >nul
    echo Installed to %LOCALAPPDATA%\Roblox\Plugins\RBXMonkeyBB.rbxm
)
