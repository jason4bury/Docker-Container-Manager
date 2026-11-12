@echo off
rem Starts Docker Container Manager from source (no exe needed).
rem Bypasses the execution policy for this run only; nothing machine-wide changes.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0src\Docker-Container-Manager.ps1" %*
