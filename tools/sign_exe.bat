@echo off
rem =====================================================================
rem  Sign the exported exe with an Authenticode certificate.
rem
rem  Two hard prerequisites, both currently missing on this machine:
rem    1. signtool.exe  (Windows SDK)
rem       winget install Microsoft.WindowsSDK.10.0.22621
rem    2. A code signing certificate in Cert:\CurrentUser\My
rem       (or a cloud-signing client, e.g. Certum cloud signing)
rem
rem  Then set CERT_SUBJECT to the CN of that certificate and run:
rem       tools\sign_exe.bat
rem
rem  DO NOT buy an EV certificate just to kill the SmartScreen prompt:
rem  since 2024 EV no longer grants instant reputation. OV and EV both
rem  have to accumulate it. The difference is weeks vs months, not zero
rem  vs prompt.
rem
rem  This file must stay pure ASCII.
rem =====================================================================
setlocal

rem ---- edit this one line -------------------------------------------
set "CERT_SUBJECT=YOUR COMPANY OR PUBLISHER NAME"
rem -------------------------------------------------------------------

set "EXE=%~dp0..\godot_poc\build\windows\RenTiBanZhiShi.exe"
set "STAMP=http://timestamp.digicert.com"

if not exist "%EXE%" (
    echo [ERROR] No build found:
    echo         %EXE%
    echo         Run build_win.bat first.
    pause
    exit /b 1
)

rem ---- locate signtool (highest SDK version wins) ----
set "SIGNTOOL="
where signtool.exe >nul 2>&1 && set "SIGNTOOL=signtool.exe"
if not defined SIGNTOOL (
    for /d %%D in ("%ProgramFiles(x86)%\Windows Kits\10\bin\10.*") do (
        if exist "%%D\x64\signtool.exe" set "SIGNTOOL=%%D\x64\signtool.exe"
    )
)
if not defined SIGNTOOL (
    echo [ERROR] signtool.exe not found.
    echo         Install the Windows SDK:
    echo             winget install Microsoft.WindowsSDK.10.0.22621
    pause
    exit /b 1
)
echo Using: %SIGNTOOL%

rem ---- refuse to run with the placeholder ----
if "%CERT_SUBJECT%"=="YOUR COMPANY OR PUBLISHER NAME" (
    echo [ERROR] Set CERT_SUBJECT in this script first.
    echo         Open the certificate and copy the CN from its Subject line.
    echo.
    powershell -NoProfile -Command "Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert ^| Select-Object Subject, NotAfter ^| Format-List"
    pause
    exit /b 1
)

echo Signing with subject: %CERT_SUBJECT%
"%SIGNTOOL%" sign /fd SHA256 /td SHA256 /tr "%STAMP%" /n "%CERT_SUBJECT%" "%EXE%"
if errorlevel 1 (
    echo.
    echo [ERROR] Signing failed. Common causes:
    echo   - Subject does not match any installed certificate
    echo   - Certificate expired, or private key not accessible
    echo   - Cloud signing client not running
    pause
    exit /b 1
)

echo Verifying ...
"%SIGNTOOL%" verify /pa /v "%EXE%"
if errorlevel 1 (
    echo [ERROR] Verification failed - the file is NOT properly signed.
    pause
    exit /b 1
)

echo.
echo [OK] Signed and verified: %EXE%
echo      Timestamp included, so the signature survives certificate expiry.
exit /b 0
