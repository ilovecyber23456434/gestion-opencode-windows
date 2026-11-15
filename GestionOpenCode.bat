@echo off
setlocal EnableExtensions
chcp 65001 >nul 2>&1
title Gestion OpenCode

set "SCRIPT=%~dp0GestionOpenCode.ps1"

if not exist "%SCRIPT%" (
    echo.
    echo   [X] Fichier introuvable :
    echo       "%SCRIPT%"
    echo.
    echo   Mettez GestionOpenCode.ps1 dans le meme dossier que ce fichier .bat
    echo   puis relancez.
    echo.
    pause
    exit /b 1
)

rem Au double-clic, on relance ce fichier minimise : la fenetre noire ne
rem vient pas se mettre devant l'interface graphique.
if "%~1"=="" (
    start "" /min "%~f0" --minimized
    exit /b 0
)

set "ARGS=%*"
if /I "%~1"=="--minimized" set "ARGS="

rem Utilise PowerShell 7 si disponible, sinon Windows PowerShell 5.1.
where pwsh.exe >nul 2>&1
if not errorlevel 1 (
    pwsh.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%SCRIPT%" -Gui %ARGS%
    goto :fin
)

powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%SCRIPT%" -Gui %ARGS%

:fin
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
    echo.
    echo   Le script s'est arrete avec le code %RC%.
    echo   Verifiez qu'OpenCode est installe et que PowerShell fonctionne.
    echo.
    pause
)

exit /b %RC%
