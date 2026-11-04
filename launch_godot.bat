@echo off
setlocal

rem ============================================================
rem Single source of truth for launching "RenTiBanZhiShi".
rem Every user-facing launcher (Chinese-named .bat files) just
rem `call`s this file, so the entry can never drift from the game.
rem
rem IMPORTANT: ASCII-only on purpose. cmd.exe parses .bat files with
rem the system ANSI codepage (GBK on zh-CN), not the chcp setting,
rem so Chinese literals here would be mangled and break `set`.
rem The Chinese project folder is resolved at runtime via %~dp0.
rem ============================================================

set "PROJ=%~dp0godot_poc"

rem Resolution order: %GODOT_BIN% > Godot on PATH > default install dir.
rem Never hardcode one machine's path - anyone cloning the repo should be
rem able to run this after dropping Godot somewhere findable.
set "CAND="
if defined GODOT_BIN set "CAND=%GODOT_BIN%"
if not defined CAND for /f "delims=" %%i in ('where godot 2^>nul') do if not defined CAND set "CAND=%%i"
if not defined CAND set "CAND=%LOCALAPPDATA%\godot_poc\bin\Godot_v4.7.2-stable_win64.exe"
rem Fall back to the console build if the non-console one is missing.
if not exist "%CAND%" set "CAND=%LOCALAPPDATA%\godot_poc\bin\Godot_v4.7.2-stable_win64_console.exe"
set "GODOT=%CAND%"
set "EXTRA=%~1"

if not exist "%GODOT%" (
    echo [ERROR] Godot executable not found.
    echo   Tried: %%GODOT_BIN%%, PATH, %LOCALAPPDATA%\godot_poc\bin
    echo Install Godot 4.7.2 and either put it on PATH or set GODOT_BIN.
    pause
    exit /b 1
)

if not exist "%PROJ%\project.godot" (
    echo [ERROR] project.godot not found at:
    echo   %PROJ%\project.godot
    echo Make sure this launcher sits next to the godot_poc folder.
    pause
    exit /b 1
)

echo Starting RenTiBanZhiShi (Godot build) ...
echo Project: %PROJ%
echo Log file: %PROJ%\godrun.log
echo.

rem Self-check used by the automated entry test: resolve everything, print it,
rem and exit without opening a window. Keeps the entry verifiable without
rem having to launch a GUI.
if /i "%EXTRA%"=="--dry-run" (
    echo ENTRY_EXE=%GODOT%
    echo ENTRY_PROJ=%PROJ%
    if exist "%GODOT%" (echo ENTRY_EXE_OK=1) else (echo ENTRY_EXE_OK=0)
    if exist "%PROJ%\project.godot" (echo ENTRY_PROJECT_GODOT_OK=1) else (echo ENTRY_PROJECT_GODOT_OK=0)
    if exist "%PROJ%\main.tscn" (echo ENTRY_MAIN_TSCN_OK=1) else (echo ENTRY_MAIN_TSCN_OK=0)
    exit /b 0
)

rem Launch in the foreground (no "start"): a detached child can be killed
rem together with the parent console, which looked like an instant crash.
rem All output goes to godrun.log so a real crash still leaves evidence.
rem Args are built into a variable instead of an if/else block: errorlevel
rem read right after a parenthesised block is unreliable in cmd.
set "ARGS="
if not "%~1"=="" set "ARGS=-- %*"

rem First run on a fresh clone: .godot/ (the import cache) does not exist yet,
rem so every texture and font fails to load with "Cannot open file". Import
rem once up front instead of letting the player stare at a broken first launch.
if not exist "%PROJ%\.godot\imported" (
    echo First run: importing assets, this takes about a minute ...
    "%GODOT%" --headless --path "%PROJ%" --import >nul 2>&1
)

"%GODOT%" --path "%PROJ%" --verbose %ARGS% > "%PROJ%\godrun.log" 2>&1
set "RC=%ERRORLEVEL%"
if "%RC%"=="" set "RC=0"
echo.
echo Godot exited with code %RC%.
echo Full log: %PROJ%\godrun.log
rem Only stop the window when something went wrong; a clean quit should just
rem return to the desktop (an unconditional "pause" also hangs CI / probes).
if not "%RC%"=="0" (
    echo.
    echo ---- last 40 log lines ----
    powershell -NoProfile -Command "Get-Content '%PROJ%\godrun.log' -Tail 40"
    pause
)
exit /b %RC%
