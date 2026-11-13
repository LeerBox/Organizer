@echo off
setlocal EnableExtensions DisableDelayedExpansion
rem ===========================================================================
rem  Organizer launcher - double-click to start Organizer.
rem
rem  Organizer.ps1 and OrganizerEngine.psm1 must be in the same folder as this file.
rem ===========================================================================

set "ORGANIZER_DIR=%~dp0"
set "ORGANIZER_PS1=%~dp0Organizer.ps1"
set "ORGANIZER_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%ORGANIZER_PS1%" goto :missing_files
if not exist "%ORGANIZER_DIR%OrganizerEngine.psm1" goto :missing_files
if not exist "%ORGANIZER_PS%" goto :missing_powershell

rem Start Organizer in its own hidden console, so no PowerShell window stays open.
"%ORGANIZER_PS%" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$q = [char]34; $arguments = '-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File ' + $q + $env:ORGANIZER_PS1 + $q; try { Start-Process -FilePath $env:ORGANIZER_PS -ArgumentList $arguments -WindowStyle Hidden -ErrorAction Stop; exit 0 } catch { exit 1 }"
if errorlevel 1 goto :start_failed
exit /b 0

:missing_files
echo.
echo   Organizer could not start: Organizer.ps1 and OrganizerEngine.psm1 must be
echo   in the same folder as this file:
echo   "%ORGANIZER_DIR%"
echo.
pause
exit /b 1

:missing_powershell
echo.
echo   Organizer could not start: Windows PowerShell was not found here:
echo   "%ORGANIZER_PS%"
echo.
pause
exit /b 1

:start_failed
echo.
echo   Organizer did not start. Please run Organizer.cmd again.
echo.
timeout /t 6 >nul
exit /b 1
