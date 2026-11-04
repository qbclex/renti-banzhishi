@echo off
setlocal

rem Thin wrapper. The real launcher lives in launch_godot.bat so that every
rem entry point runs the same build (the old Python tkinter prototype was a
rem partial port: no art pipeline, no PIL, so card art never showed).
rem ASCII-only: cmd.exe parses .bat with the system ANSI codepage.

if not exist "%~dp0launch_godot.bat" (
    echo [ERROR] launch_godot.bat is missing next to this file.
    pause
    exit /b 1
)

call "%~dp0launch_godot.bat" %*
exit /b %ERRORLEVEL%
