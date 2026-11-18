@echo off
setlocal EnableExtensions
title OpenCode - Gestion AGENTS.md

rem -- Style de la console (fond bleu fonce, texte blanc) --
color 1F

rem -- Se placer dans le dossier du script (plus robuste si lance via raccourci) --
cd /d "%~dp0"

rem -- Emplacements (modifiable ici si besoin) --
set "SRC=%~dp0AGENTS.md"
set "DST=%USERPROFILE%\.config\opencode\AGENTS.md"
set "DSTDIR=%USERPROFILE%\.config\opencode"

:menu
set "SRCSTAT=NON DETECTE"
if exist "%SRC%" set "SRCSTAT=DETECTE"
set "DSTSTAT=NON DETECTE"
if exist "%DST%" set "DSTSTAT=DETECTE"
cls
echo.
echo  ============================================================
echo   OPENCODE - GESTION AGENTS.MD
echo  ============================================================
echo.
echo   Etat actuel
echo   --------------------------------------------------------
echo   Source (racine)   : %SRCSTAT%
echo   Actif  (OpenCode) : %DSTSTAT%
echo.
echo   Source : %SRC%
echo   Actif  : %DST%
echo.
echo   [1] Supprimer l'AGENTS.md actif
echo   [2] Copier l'AGENTS.md de la racine vers OpenCode
echo   [3] Quitter
echo.
choice /c 123 /n /m "  Ton choix : "
if errorlevel 3 goto :quit
if errorlevel 2 goto :copyfile
if errorlevel 1 goto :deletefile
goto :menu

:deletefile
cls
echo.
echo  --- SUPPRESSION ---
echo.
if not exist "%DST%" (
  echo  Aucun AGENTS.md actif trouve :
  echo  %DST%
  echo.
  pause
  goto :menu
)
echo  Fichier : %DST%
echo.
choice /c ON /n /m "  Confirmer la suppression ? (O/N) : "
if errorlevel 2 goto :menu
attrib -r -h -s "%DST%" >nul 2>&1
del /f /q "%DST%" >nul 2>&1
if exist "%DST%" (
  echo.
  echo  [ECHEC] Impossible de supprimer le fichier.
) else (
  echo.
  echo  [OK] AGENTS.md actif supprime.
)
echo.
pause
goto :menu

:copyfile
cls
echo.
echo  --- COPIE ---
echo.
if not exist "%SRC%" (
  echo  AGENTS.md introuvable a la racine :
  echo  %SRC%
  echo.
  echo  Place le fichier dans le meme dossier que ce .bat.
  echo.
  pause
  goto :menu
)
if not exist "%DSTDIR%" mkdir "%DSTDIR%" >nul 2>&1
echo  De   : %SRC%
echo  Vers : %DST%
echo.
choice /c ON /n /m "  Confirmer la copie ? (O/N) : "
if errorlevel 2 goto :menu
if exist "%DST%" attrib -r -h -s "%DST%" >nul 2>&1
copy /y "%SRC%" "%DST%" >nul 2>&1
if errorlevel 1 goto :copyfail
if not exist "%DST%" goto :copyfail
echo.
echo  [OK] AGENTS.md copie et actif.
echo.
pause
goto :menu

:copyfail
echo.
echo  [ECHEC] La copie a echoue.
echo.
pause
goto :menu

:quit
cls
echo.
echo  A plus.
echo.
pause
endlocal
exit /b 0