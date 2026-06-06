@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "FFMPEG=%~dp0ffmpeg.exe"
set "OUTDIR=%~dp0converted"

if not exist "%FFMPEG%" (
    echo ffmpeg.exe not found:
    echo %FFMPEG%
    pause
    exit /b 1
)

if not exist "%OUTDIR%" mkdir "%OUTDIR%"

if "%~1"=="" (
    echo Drag media files onto this batch file to convert them to WebP.
    pause
    exit /b 1
)

:process
if "%~1"=="" goto end

set "BASENAME=%~n1"
set "OUTFILE=%OUTDIR%\!BASENAME!.webp"
set /a COUNT=1

:dedupe
if exist "!OUTFILE!" (
    set "SUFFIX=00!COUNT!"
    set "OUTFILE=%OUTDIR%\!BASENAME!_!SUFFIX:~-3!.webp"
    set /a COUNT+=1
    goto dedupe
)

echo Converting: %~nx1
"%FFMPEG%" -hide_banner -y -i "%~1" -c:v libwebp -lossless 0 -q:v 80 -preset default -loop 0 -an -fps_mode passthrough "!OUTFILE!"

if errorlevel 1 (
    echo Failed: %~f1
) else (
    echo Done: !OUTFILE!
)

shift
goto process

:end
pause
