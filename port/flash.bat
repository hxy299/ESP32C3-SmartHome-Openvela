@echo off
rem ===========================================================================
rem  One-click flash wrapper for Windows
rem
rem  Why this exists:
rem    Windows blocks .ps1 scripts by default:
rem      "flash.ps1 cannot be loaded because running scripts is disabled"
rem    This wrapper calls PowerShell with -ExecutionPolicy Bypass so you do not
rem    have to change any system setting.
rem
rem  Usage:
rem    flash.bat -Port COM6
rem    flash.bat -Port COM6 -NuttxBin .\nuttx-production.bin
rem    flash.bat -Port COM6 -NuttxBin .\nuttx-production.bin -Erase
rem ===========================================================================
setlocal
set "SCRIPT=%~dp0flash.ps1"

if "%~1"=="" (
    echo Usage: flash.bat -Port COMx [-NuttxBin .\nuttx-production.bin] [-Baud 921600] [-Erase]
    echo Example: flash.bat -Port COM6 -NuttxBin .\nuttx-production.bin
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
exit /b %ERRORLEVEL%
