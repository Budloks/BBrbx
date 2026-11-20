@echo off
REM Build the BBrbx Studio plugin with Rojo.
REM Usage: build_plugin.bat [--install]
REM   --install  also copies the plugin into %LOCALAPPDATA%\Roblox\Plugins
if not exist build mkdir build
rojo build plugin.project.json -o build\BBrbx.rbxm
if errorlevel 1 exit /b 1
if /i "%~1"=="--install" (
    copy /y build\BBrbx.rbxm "%LOCALAPPDATA%\Roblox\Plugins\BBrbx.rbxm" >nul
    echo Installed to %LOCALAPPDATA%\Roblox\Plugins\BBrbx.rbxm
)
