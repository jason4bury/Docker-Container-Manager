<# : batch part - runs the PowerShell part below. Just double-click this file.
@echo off
setlocal
set "BUILD_DIR=%~dp0"
set "BUILD_FILE=%~f0"
rem Started from PowerShell 7, PSModulePath points at PS7 modules that 5.1 can't load
set "PSModulePath="
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Expression ([IO.File]::ReadAllText($env:BUILD_FILE))"
set "BUILD_RESULT=%ERRORLEVEL%"
echo.
if not defined NO_PAUSE pause
exit /b %BUILD_RESULT%
: end of batch part #>

# ===========================================================================
# Build.cmd - makes the release from build.json. No exe: the tool is shipped as
# its script, started hidden by a shortcut. (PS2EXE exes kept being flagged by
# antivirus as false positives, so Home tools no longer use them.)
#
# Double-click this file (no admin rights needed). It:
#   1. reads build.json (AppName, EntryScript, Release.Files, Release.Shortcut),
#   2. checks every script in src\ has no syntax errors and that
#      $script:AppVersion matches the newest CHANGELOG entry,
#   3. runs PSScriptAnalyzer on src\ if it's installed (stops on errors),
#   4. copies Release.Files into ..\Builds\<AppName> v<version>\ (made afresh),
#   5. zips that folder as ..\Builds\<App-Name>-v<version>.zip for the GitHub release,
#   6. refreshes ..\Builds\<AppName>.lnk, pointing at the new version, for the
#      Home Launcher (launcher.json's Target) - a shortcut needs a full path, so
#      it is made here on this PC and never shipped. The shortcut maker runs the
#      way the release's start .cmd runs it, so this also tests that .cmd,
#   7. scans the folder and zip with ESET's command-line scanner (ecls.exe) if
#      it's installed, without cleaning anything.
#
# Everything shown on screen is also written to Build.log (gitignored).
# Set NO_PAUSE=1 to skip the "Press any key" at the end.
# ===========================================================================

$ErrorActionPreference = 'Stop'

# Windows PowerShell's own module folders, so the right PSScriptAnalyzer loads.
$env:PSModulePath = @(
    (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules'),
    (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'),
    [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine')
) -join ';'

$here      = if ($env:BUILD_DIR) { $env:BUILD_DIR.TrimEnd('\') } else { (Get-Location).Path }
$buildJson = Join-Path $here 'build.json'
$changelog = Join-Path $here 'CHANGELOG.md'
$buildsDir = Join-Path (Split-Path -Parent $here) 'Builds'
$logPath   = Join-Path $here 'Build.log'
$failed    = $false

try { Start-Transcript -LiteralPath $logPath -Force | Out-Null } catch { Write-Verbose 'No transcript.' }

try {
    # --- 1. build.json ---
    if (-not (Test-Path -LiteralPath $buildJson)) { throw "Missing build.json in $here." }
    $cfg = Get-Content -LiteralPath $buildJson -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $cfg.AppName -or -not $cfg.EntryScript -or -not $cfg.Release.Files) {
        throw 'build.json needs AppName, EntryScript and Release.Files.'
    }
    $appName = [string]$cfg.AppName
    $script  = Join-Path $here $cfg.EntryScript
    foreach ($f in $script, $changelog) {
        if (-not (Test-Path -LiteralPath $f)) { throw "Missing file: $f" }
    }

    # --- 2. Syntax and version ---
    $srcDir = Split-Path -Parent $script
    foreach ($ps1 in Get-ChildItem -LiteralPath $srcDir -Filter '*.ps1' -File) {
        $tokens = $null; $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($ps1.FullName, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0) {
            throw "$($ps1.Name) has $($parseErrors.Count) syntax error(s). First, on line $($parseErrors[0].Extent.StartLineNumber): $($parseErrors[0].Message)"
        }
    }
    $text = [IO.File]::ReadAllText($script)
    if ($text -notmatch "AppVersion\s*=\s*'(\d+\.\d{2})'") {
        throw "Couldn't find `$script:AppVersion = '<major>.<two-digit minor>' (e.g. '1.00') in $($cfg.EntryScript)."
    }
    $version = $Matches[1]
    $logVersion = $null
    foreach ($line in [IO.File]::ReadAllLines($changelog)) {
        if ($line -match '^##\s*\[(\d+\.\d+)\]') { $logVersion = $Matches[1]; break }
    }
    if ($logVersion -ne $version) {
        throw "The script says v$version but the newest CHANGELOG entry is v$logVersion. Make them match first."
    }
    $releaseName = "$appName v$version"
    Write-Host "Building $releaseName" -ForegroundColor Cyan
    Write-Host ''

    # --- 3. PSScriptAnalyzer (if installed) ---
    if (Get-Module -ListAvailable -Name PSScriptAnalyzer) {
        Write-Host 'Running PSScriptAnalyzer...' -ForegroundColor Cyan
        $settings = Join-Path $here 'PSScriptAnalyzerSettings.psd1'
        $paArgs = @{ Path = $srcDir; Recurse = $true }
        if (Test-Path -LiteralPath $settings) { $paArgs.Settings = $settings }
        $results = @(Invoke-ScriptAnalyzer @paArgs)
        if ($results.Count -gt 0) { $results | Format-Table -AutoSize Severity, ScriptName, RuleName, Line, Message | Out-String -Width 200 | Write-Host }
        if (@($results | Where-Object Severity -eq 'Error').Count -gt 0) { throw 'PSScriptAnalyzer found errors (see above).' }
        if ($results.Count -eq 0) { Write-Host '  No problems found.' }
        Write-Host ''
    } else {
        Write-Warning 'PSScriptAnalyzer is not installed - skipping static analysis. (Install-Module PSScriptAnalyzer -Scope CurrentUser)'
    }

    # --- 4. Release folder ---
    if (-not (Test-Path -LiteralPath $buildsDir)) { New-Item -ItemType Directory -Path $buildsDir -Force | Out-Null }
    $outDir = Join-Path $buildsDir $releaseName
    if (Test-Path -LiteralPath $outDir) { Remove-Item -LiteralPath $outDir -Recurse -Force }   # this version's own earlier build
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    foreach ($p in $cfg.Release.Files.PSObject.Properties) {
        $from = Join-Path $here $p.Value
        if (-not (Test-Path -LiteralPath $from)) { throw "Release.Files: $($p.Value) not found." }
        $to = Join-Path $outDir $p.Name
        $toDir = Split-Path -Parent $to
        if (-not (Test-Path -LiteralPath $toDir)) { New-Item -ItemType Directory -Path $toDir -Force | Out-Null }
        Copy-Item -LiteralPath $from -Destination $to -Force
        Write-Host "  $($p.Name)"
    }
    Write-Host "Release folder: $outDir" -ForegroundColor Green

    # --- 5. Zip (the folder itself is the zip's top level) ---
    $zipPath = Join-Path $buildsDir "$($appName -replace '\s+', '-')-v$version.zip"
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($outDir, $zipPath, [IO.Compression.CompressionLevel]::Optimal, $true)
    Write-Host "Zip: $zipPath" -ForegroundColor Green

    # --- 6. Builds\<AppName>.lnk for the Home Launcher ---
    if ($cfg.Release.Shortcut) {
        $maker = Join-Path $outDir $cfg.Release.Shortcut
        $lnk   = Join-Path $buildsDir "$appName.lnk"
        # Run it the way the release's start .cmd does (powershell.exe -File, no -ScriptPath), so the
        # build fails if the shortcut maker can't find the script by itself (PS 5.1 leaves $PSScriptRoot
        # empty in param() defaults under -File).
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        & $ps -NoProfile -ExecutionPolicy Bypass -File $maker -ShortcutPath $lnk | Write-Host
        if ($LASTEXITCODE -ne 0) { throw "$($cfg.Release.Shortcut) failed (exit code $LASTEXITCODE)." }
        # The shortcut maker unblocks the folder; nothing else changes in it.
    }

    # --- 7. ESET scan (if installed) ---
    $ecls = Join-Path $env:ProgramFiles 'ESET\ESET Security\ecls.exe'
    if (Test-Path -LiteralPath $ecls) {
        Write-Host ''
        Write-Host 'Scanning with ESET (ecls.exe, no cleaning)...' -ForegroundColor Cyan
        # ecls writes notes (such as "run as a limited user") to stderr; that isn't a failure.
        $ErrorActionPreference = 'Continue'
        $targets = @($outDir, $zipPath, (Join-Path $buildsDir "$appName.lnk")) | Where-Object { Test-Path -LiteralPath $_ }
        $out = & $ecls /clean-mode=none /no-log-all /log-console @targets 2>&1
        $code = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        $out | ForEach-Object { "$_".Trim() } | Where-Object { $_ -and $_ -notmatch 'RemoteException' } | ForEach-Object { Write-Host "  $_" }
        switch ($code) {
            0       { Write-Host '  ESET: no threats found.' -ForegroundColor Green }
            10      { Write-Warning 'ESET: some files could not be scanned.' }
            default { throw "ESET reported a detection or error (exit code $code). Check before releasing." }
        }
    } else {
        Write-Host 'ESET command-line scanner not found - skipped the scan.'
    }

    Write-Host ''
    Write-Host "Done: $releaseName" -ForegroundColor Green
} catch {
    $failed = $true
    Write-Host ''
    Write-Host "Build failed: $($_.Exception.Message)" -ForegroundColor Red
}

try { Stop-Transcript | Out-Null } catch { Write-Verbose 'No transcript.' }

if ($failed) { [Environment]::Exit(1) }
