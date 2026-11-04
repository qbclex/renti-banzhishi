@echo off
rem =====================================================================
rem  Play the exported build. Two reasons this launcher exists:
rem
rem  1) This machine refuses disk writes for binaries launched from the
rem     Desktop tree. The game runs but every save fails (save=false).
rem     Copying to %LOCALAPPDATA% first makes saves work.
rem  2) After rebuilding, the local copy is synced automatically, so you
rem     are never testing a stale exe.
rem
rem  This file must stay pure ASCII (cmd parses .bat with the ANSI code
rem  page; CJK comments break it at line 1).
rem =====================================================================
setlocal

set "SRCDIR=%~dp0godot_poc\build\windows"
set "DSTDIR=%LOCALAPPDATA%\RenTiBanZhiShi\play"
set "EXE=RenTiBanZhiShi.exe"

if not exist "%SRCDIR%\%EXE%" (
    echo [ERROR] No build found at:
    echo         %SRCDIR%\%EXE%
    echo.
    echo Build it first:  cmd /c build_win.bat
    echo.
    pause
    exit /b 1
)

if not exist "%DSTDIR%" mkdir "%DSTDIR%" >nul 2>&1

rem robocopy skips the copy when size and timestamp already match,
rem so relaunching after no changes is instant.
robocopy "%SRCDIR%" "%DSTDIR%" "%EXE%" /NJH /NJS /NDL /NC /NS /NP >nul
if errorlevel 8 (
    echo [ERROR] Could not copy the exe to:
    echo         %DSTDIR%
    echo.
    pause
    exit /b 1
)

start "" "%DSTDIR%\%EXE%" %*
exit /b 0
