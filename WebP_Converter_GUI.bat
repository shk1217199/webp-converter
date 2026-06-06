@echo off
set "SCRIPT=%~dp0bin\webp_converter_gui.ps1"

if not exist "%SCRIPT%" (
    echo GUI script not found:
    echo %SCRIPT%
    pause
    exit /b 1
)

start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%SCRIPT%"
