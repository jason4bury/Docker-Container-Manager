@echo off
rem Docker Container Manager - double-click to start it.
rem Each time, this makes (or refreshes) the Docker Container Manager shortcut in this folder and in the Start menu,
rem then starts Docker Container Manager from it. After the first run you can use the shortcut, the Start menu or
rem a pinned taskbar button instead: they start Docker Container Manager without a console window.
rem The execution-policy bypass applies to Docker Container Manager's own run only; no Windows settings are changed.
rem If Docker Container Manager doesn't open, run   "Docker Container Manager.cmd" debug   to start it in this window and see any errors.
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if /i "%~1"=="debug" (
    "%PS%" -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Docker-Container-Manager.ps1"
    pause
    exit /b
)
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0New-DockerContainerManagerShortcut.ps1" -Launch
if errorlevel 1 pause
