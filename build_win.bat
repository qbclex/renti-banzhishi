@echo off
setlocal EnableDelayedExpansion

rem ============================================================
rem Build a distributable Windows folder for "RenTiBanZhiShi".
rem
rem Output: godot_poc\build\windows\RenTiBanZhiShi.exe
rem   (embedded PCK, so the exe is self-contained)
rem
rem Prereq: Godot export templates for 4.7.2 must be installed.
rem   The editor normally fetches them; on a machine that cannot
rem   reach GitHub, run:  python godot_poc\tools\fetch_templates.py
rem
rem IMPORTANT: ASCII-only. cmd.exe parses .bat with the system ANSI
rem codepage (GBK on zh-CN) regardless of chcp, so Chinese literals
rem here would be mangled and silently break `set`.
rem ============================================================

set "PROJ=%~dp0godot_poc"
set "GODOT=%LOCALAPPDATA%\godot_poc\bin\Godot_v4.7.2-stable_win64.exe"
set "OUTDIR=%PROJ%\build\windows"
set "OUTEXE=%OUTDIR%\RenTiBanZhiShi.exe"
set "TPLDIR=%APPDATA%\Godot\export_templates\4.7.2.stable"

if not exist "%GODOT%" (
    set "GODOT=%LOCALAPPDATA%\godot_poc\bin\Godot_v4.7.2-stable_win64_console.exe"
)

if not exist "%GODOT%" (
    echo [ERROR] Godot executable not found.
    echo   Expected: %LOCALAPPDATA%\godot_poc\bin\Godot_v4.7.2-stable_win64.exe
    exit /b 1
)

if not exist "%TPLDIR%\windows_release_x86_64.exe" (
    echo [ERROR] Windows export template missing:
    echo   %TPLDIR%\windows_release_x86_64.exe
    echo.
    echo Fix one of these:
    echo   1^) Editor -^> Editor menu -^> Manage Export Templates -^> Download
    echo   2^) python "%PROJ%\tools\fetch_templates.py" --release-only
    exit /b 1
)

if not exist "%OUTDIR%" mkdir "%OUTDIR%"

rem Regenerate the .raw copies of the SVG icons. Icons are rasterized at
rem runtime from the SVG source, but the export only ships imported
rem resources -- so the plain .svg would be missing from the pack. A .raw
rem copy is a non-resource file and survives via include_filter.
python "%PROJ%\tools\prepare_export_assets.py"
if errorlevel 1 (
    echo [ERROR] prepare_export_assets.py failed. Is python on PATH?
    exit /b 1
)

echo Building ...
echo   Godot : %GODOT%
echo   Output: %OUTEXE%
echo.

rem Export in the foreground; the process exits with the export result code.
rem Args are assembled into a variable first: %ERRORLEVEL% read right after a
rem parenthesised block is unreliable, which caused false "exit code 1" reports.
"%GODOT%" --headless --path "%PROJ%" --export-release "Windows Desktop" "%OUTEXE%" 2>&1
set "RC=%ERRORLEVEL%"

if not exist "%OUTEXE%" (
    echo.
    echo [ERROR] Export finished with code %RC% but produced no exe.
    exit /b 1
)

for %%F in ("%OUTEXE%") do set "SIZE=%%~zF"
echo.
echo [OK] %OUTEXE%
echo      size: !SIZE! bytes

rem Release gate: boot the exported build and ask it to prove that the
rem art, icons, fonts and user:// actually made it into the pack. Without
rem this, a pack with zero assets still starts and still finishes a run.
rem
rem It runs from a copy under %TEMP% on purpose: this machine blocks file
rem writes for binaries launched straight out of the Desktop tree (the
rem very same exe passes when copied elsewhere), and that would turn the
rem save check into a false alarm about the build.
echo.
echo Verifying exported build ...
set "VERIFY=%TEMP%\rtbzs_verify"
if exist "%VERIFY%" rd /s /q "%VERIFY%"
mkdir "%VERIFY%" 2>nul
copy /y "%OUTEXE%" "%VERIFY%\verify.exe" >nul
"%VERIFY%\verify.exe" --headless --log-file "%VERIFY%\selfcheck.log" -- --selfcheck
set "SC=%ERRORLEVEL%"
findstr /C:"[save]" /C:"SELFCHECK" "%VERIFY%\selfcheck.log" 2>nul
if not "%SC%"=="0" (
    echo [ERROR] selfcheck failed, exit=!SC!  see %VERIFY%\selfcheck.log
    exit /b 1
)
del /q "%VERIFY%\verify.exe" 2>nul
echo [OK] selfcheck passed
exit /b 0
