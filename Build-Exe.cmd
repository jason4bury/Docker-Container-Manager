<# : batch part - runs the PowerShell part below. Just double-click this file.
@echo off
setlocal
set "BUILD_DIR=%~dp0"
set "BUILD_FILE=%~f0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Expression ([IO.File]::ReadAllText($env:BUILD_FILE))"
set "BUILD_RESULT=%ERRORLEVEL%"
echo.
if not defined NO_PAUSE pause
exit /b %BUILD_RESULT%
: end of batch part #>

# ===========================================================================
# Build-Exe.cmd - builds "..\Builds\Docker Container Manager v<version>.exe".
#
# Interim: once E:\Created\_shared\Build-Tool.ps1 is in place it replaces this
# file (it reads build.json instead). Until then, this builds the same way.
#
# Double-click this file (no admin rights needed). It:
#   1. checks $script:AppVersion in the script matches the newest CHANGELOG entry,
#   2. runs PSScriptAnalyzer if it's installed (stops on errors, shows warnings),
#   3. writes one script to %TEMP% with the icon and logo pasted in as base64,
#      so the exe needs no other files,
#   4. installs ps2exe for the current user if it's missing, then compiles the
#      script with -STA -noConsole and the icon into the project's Builds
#      folder (next to Source, outside the repo).
#
# The exe is NOT signed here - the shared build script will do that. If
# antivirus flags the unsigned exe, report a false positive or add an
# exclusion rather than turning protection off.
# Everything shown on screen is also written to Build-Exe.log (gitignored).
# Set NO_PAUSE=1 to skip the "Press any key" at the end.
# ===========================================================================

$ErrorActionPreference = 'Stop'

# Started from a PowerShell 7 window, Windows PowerShell inherits pwsh's
# module path and can load the wrong PSScriptAnalyzer/ps2exe. Use its own.
$env:PSModulePath = @(
    (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules'),
    (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'),
    [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine')
) -join ';'

$here       = if ($env:BUILD_DIR) { $env:BUILD_DIR.TrimEnd('\') } else { (Get-Location).Path }
$script     = Join-Path $here 'src\Docker-Container-Manager.ps1'
$assetsDir  = Join-Path $here 'assets'
$iconPath   = Join-Path $assetsDir 'Docker-Container-Manager.ico'
$logoPath   = Join-Path $assetsDir 'Docker-Container-Manager.png'
$changelog  = Join-Path $here 'CHANGELOG.md'
$buildsDir  = Join-Path (Split-Path -Parent $here) 'Builds'
$logPath    = Join-Path $here 'Build-Exe.log'
$bundlePath = Join-Path $env:TEMP 'Docker-Container-Manager.bundle.ps1'
$failed     = $false

try { Start-Transcript -LiteralPath $logPath -Force | Out-Null } catch { Write-Verbose 'No transcript.' }

try {
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
    foreach ($f in $script, $iconPath, $logoPath, $changelog) {
        if (-not (Test-Path -LiteralPath $f)) { throw "Missing file: $f" }
    }

    # --- 1. Version ---
    $text = [IO.File]::ReadAllText($script)
    if ($text -notmatch "AppVersion\s*=\s*'(\d+\.\d{2})'") {
        throw "Couldn't find `$script:AppVersion = '<major>.<two-digit minor>' in $script."
    }
    $version = $Matches[1]
    $appName = if ($text -match "AppName\s*=\s*'([^']+)'") { $Matches[1] } else { 'Docker Container Manager' }
    $logVersion = $null
    foreach ($line in [IO.File]::ReadAllLines($changelog)) {
        if ($line -match '^##\s*\[(\d+\.\d+)\]') { $logVersion = $Matches[1]; break }
    }
    if ($logVersion -ne $version) {
        throw "The script says v$version but the newest CHANGELOG entry is v$logVersion. Make them match first."
    }
    Write-Host "Building $appName v$version.exe" -ForegroundColor Cyan
    Write-Host ''

    # --- 2. PSScriptAnalyzer (if installed) ---
    if (Get-Module -ListAvailable -Name PSScriptAnalyzer) {
        Write-Host 'Running PSScriptAnalyzer...' -ForegroundColor Cyan
        $results = @(Invoke-ScriptAnalyzer -Path $script -Settings (Join-Path $here 'PSScriptAnalyzerSettings.psd1'))
        $results | Format-Table -AutoSize Severity, RuleName, Line, Message | Out-String -Width 200 | Write-Host
        if (@($results | Where-Object Severity -eq 'Error').Count -gt 0) { throw 'PSScriptAnalyzer found errors (see above).' }
        if ($results.Count -eq 0) { Write-Host '  No problems found.' }
        Write-Host ''
    } else {
        Write-Warning 'PSScriptAnalyzer is not installed - skipping static analysis. (Install-Module PSScriptAnalyzer -Scope CurrentUser)'
    }

    # --- 3. Bundle the icon and logo ---
    $start = $text.IndexOf('#region BUNDLE-ASSETS')
    $endTag = '#endregion BUNDLE-ASSETS'
    $end = $text.IndexOf($endTag)
    if ($start -lt 0 -or $end -lt $start) { throw "Couldn't find the BUNDLE-ASSETS region in the script." }
    $region = @(
        '# Embedded by Build-Exe.cmd',
        '$script:EmbeddedAssets = @{',
        "    'Docker-Container-Manager.ico' = '$([Convert]::ToBase64String([IO.File]::ReadAllBytes($iconPath)))'",
        "    'Docker-Container-Manager.png' = '$([Convert]::ToBase64String([IO.File]::ReadAllBytes($logoPath)))'",
        '}'
    ) -join "`r`n"
    $bundle = $text.Substring(0, $start) + $region + $text.Substring($end + $endTag.Length)
    [IO.File]::WriteAllText($bundlePath, $bundle, (New-Object System.Text.UTF8Encoding($true)))

    $tokens = $null; $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($bundlePath, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -gt 0) { throw "The bundled script doesn't parse: $($parseErrors[0].Message) (line $($parseErrors[0].Extent.StartLineNumber) of $bundlePath)" }

    # --- 4. Compile ---
    $parts = $version.Split('.')
    $fileVersion = '{0}.{1}.0.0' -f [int]$parts[0], [int]$parts[1]
    if (-not (Test-Path -LiteralPath $buildsDir)) { New-Item -ItemType Directory -Path $buildsDir -Force | Out-Null }
    $outputPath = Join-Path $buildsDir "$appName v$version.exe"

    if (-not (Get-Module -ListAvailable -Name ps2exe)) {
        Write-Host 'ps2exe module not found - installing for the current user (one-time)...' -ForegroundColor Cyan
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        } catch { Write-Verbose 'TLS 1.2 already on.' }
        if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue |
                  Where-Object { $_.Version -ge [version]'2.8.5.201' })) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
        }
        Install-Module -Name ps2exe -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module ps2exe

    $appArgs = @{
        inputFile    = $bundlePath
        outputFile   = $outputPath
        iconFile     = $iconPath
        STA          = $true
        noConsole    = $true
        noConfigFile = $true
        title        = $appName
        description  = $appName
        product      = $appName
        version      = $fileVersion
        company      = 'Jason Rhodes'
        copyright    = 'Copyright (c) 2026 Jason Rhodes'
    }
    Invoke-ps2exe @appArgs

    if (-not (Test-Path -LiteralPath $outputPath)) {
        throw "ps2exe didn't report an error, but $outputPath wasn't created."
    }
    Remove-Item -LiteralPath $bundlePath -Force -ErrorAction SilentlyContinue
    Write-Host ''
    Write-Host "Done: $outputPath" -ForegroundColor Green
} catch {
    $failed = $true
    Write-Host ''
    Write-Host "Build failed: $($_.Exception.Message)" -ForegroundColor Red
}

try { Stop-Transcript | Out-Null } catch { Write-Verbose 'No transcript.' }

if ($failed) { [Environment]::Exit(1) }
