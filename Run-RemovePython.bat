@echo off
title Python Removal Script v1.0
chcp 65001 >nul 2>&1

:: --- Self-elevate to Administrator if needed ---
net session >nul 2>&1
if %errorlevel% equ 0 goto :main

echo Requesting administrator privileges...
powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0' -ArgumentList '%*'" 2>nul
if %errorlevel% neq 0 (
    echo.
    echo ERROR: Could not obtain administrator privileges.
    echo Please right-click this file and select "Run as administrator".
    pause
)
exit /b

:main
:: Elevated processes default to System32 - restore script directory
cd /d "%~dp0"

set "scriptPath=%~dp0RemovePython.ps1"

if not exist "%scriptPath%" (
    echo ERROR: Script not found at %scriptPath%
    pause
    exit /b 1
)

:: Usage:
::   Run-RemovePython.bat
::   Run-RemovePython.bat -ScanOnly
::   Run-RemovePython.bat -CreateBackup:$false

pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%scriptPath%" %*
