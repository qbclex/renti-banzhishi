@echo off
setlocal

rem ============================================================
rem This entry used to launch game.py (the Python tkinter prototype).
rem That prototype was a partial port: it had no art pipeline and the
rem bundled Python had no PIL, so card art / portraits / backgrounds
rem never showed and only one sound ever fired. The Godot build is the
rem real game, so this entry now launches it too - both launchers call
rem the same launch_godot.bat, which keeps the entry from drifting away
rem from the game that is actually being developed.
rem ASCII-only: cmd.exe parses .bat with the system ANSI codepage.
rem ============================================================

if not exist "%~dp0launch_godot.bat" (
    echo [ERROR] launch_godot.bat is missing next to this file.
    echo         The Godot project folder should be: %~dp0godot_poc
    pause
    exit /b 1
)

call "%~dp0launch_godot.bat" %*
exit /b %ERRORLEVEL%
