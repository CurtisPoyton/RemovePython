@echo off
setlocal
title Python Removal v2.0
chcp 65001 >nul 2>&1

:: Usage:
::   Run-RemovePython.bat                       preview then prompt
::   Run-RemovePython.bat -ScanOnly             report only, change nothing
::   Run-RemovePython.bat -Force                unattended removal, no prompt
::   Run-RemovePython.bat -SkipRestorePoint     removal without a restore point
::   Run-RemovePython.bat -WhatIf               show every action without doing it
::   Run-RemovePython.bat -RestoreEnvironment <backup.json>
::
:: Exit codes: 0 clean, 1 critical failure, 2 operations failed,
::             3 components remain, 4 cancelled, 5 pre-flight failed

where pwsh >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo ERROR: PowerShell 7+ ^(pwsh.exe^) was not found.
    echo This script requires PowerShell 7.5 or later.
    echo Download it from: https://aka.ms/powershell-release?tag=stable
    pause
    exit /b 1
)

net session >nul 2>&1
if %errorlevel% equ 0 goto :elevated

echo Requesting administrator privileges...
if "%~1"=="" (
    pwsh -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0'" 2>nul
) else (
    pwsh -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0' -ArgumentList '%*'" 2>nul
)
if %errorlevel% neq 0 (
    echo.
    echo ERROR: Administrator privileges could not be obtained.
    echo Right-click this file and choose "Run as administrator".
    pause
    exit /b 1
)
exit /b 0

:elevated
:: Elevated processes start in System32, so restore the script directory.
cd /d "%~dp0"

set "scriptPath=%~dp0RemovePython.ps1"
if not exist "%scriptPath%" (
    echo ERROR: RemovePython.ps1 was not found at %scriptPath%
    pause
    exit /b 1
)

pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%scriptPath%" %*
set "runExitCode=%errorlevel%"

echo.
echo Finished with exit code %runExitCode%.
pause
exit /b %runExitCode%
