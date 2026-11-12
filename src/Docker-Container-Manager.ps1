<#
.SYNOPSIS
    Docker Container Manager - a PowerShell/WPF window for running and organising
    the containers in a Docker Compose file.

.DESCRIPTION
    Reads a docker-compose.yml (through "docker compose config", so .env values,
    anchors and overrides are all applied the way Docker applies them), lists every
    service with its live status, and starts, stops, restarts, updates and recreates
    one container, a selection, a group or everything.

    Groups come from a label on each service (home.group by default), so they live
    in the compose file and travel with it to every machine. Services without one
    are shown under "Ungrouped". The file is read again whenever it (or .env) is
    saved, so new, removed and edited services show up on their own:
      - a new service appears straight away,
      - a removed service that still has a container is listed under
        "Not in compose file", ready to stop or remove,
      - an edited service is marked "Changed" until it is recreated.

    The app never edits the compose file itself.

.PARAMETER ComposeFile
    Open this compose file instead of the last one used.

.EXAMPLE
    powershell -STA -ExecutionPolicy Bypass -File .\Docker-Container-Manager.ps1
    Opens the window with the last compose file used.

.EXAMPLE
    "Docker Container Manager v1.00.exe" -ComposeFile "D:\Docker\docker-compose.yml"

.NOTES
    Version:   1.00 (keep in step with CHANGELOG.md)
    Author:    Jason Rhodes
    Licence:   MIT - see LICENSE
    Settings:  %APPDATA%\Docker Container Manager\settings.json
#>
param(
    [string]$ComposeFile
)

$ErrorActionPreference = 'Stop'

$script:AppName    = 'Docker Container Manager'
$script:AppVersion = '1.00'
$script:RepoUrl    = 'https://github.com/jason4bury/Docker-Container-Manager'

#region BUNDLE-ASSETS
# Build-Exe.cmd replaces this region with the icon and logo as base64, so the exe
# needs no other files. Running from source, they are read from ..\assets\.
$script:EmbeddedAssets = @{}
#endregion BUNDLE-ASSETS

# ---------------------------------------------------------------------------
# WPF needs an STA thread. Started any other way, restart in Windows PowerShell.
# ---------------------------------------------------------------------------
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA' -and $PSCommandPath) {
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $relaunch = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"")
    if ($ComposeFile) { $relaunch += @('-ComposeFile', "`"$ComposeFile`"") }
    Start-Process -FilePath $ps -ArgumentList $relaunch
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

# ---------------------------------------------------------------------------
# Helper classes (C# 5, so they compile with the .NET Framework compiler that
# Windows PowerShell 5.1 uses):
#   Dcm.Runner     - runs docker.exe without a window, reading its output on
#                    background threads into a queue the UI timer empties.
#   Dcm.Row        - one service or container in the list (raises
#                    PropertyChanged so the grid updates in place).
#   Dcm.GroupEntry - one line in the Groups pane.
#   Dcm.Finding    - one result of the compose file check.
# ---------------------------------------------------------------------------
if (-not ('Dcm.Finding' -as [type])) {
    Add-Type -Language CSharp -ReferencedAssemblies System, System.Core -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Text;

namespace Dcm {
    public class Runner {
        public ConcurrentQueue<string> Lines = new ConcurrentQueue<string>();
        public Process Proc;
        public string CommandLine;
        private readonly StringBuilder _out = new StringBuilder();
        private readonly StringBuilder _err = new StringBuilder();
        private readonly object _lock = new object();
        private readonly bool _capture;
        private volatile bool _outDone;
        private volatile bool _errDone;

        // capture = true keeps stdout and stderr for the caller (quick queries);
        // capture = false streams every line to Lines as it arrives (actions, logs).
        public Runner(string exe, string[] args, string workingDir, bool capture) {
            _capture = capture;
            string joined = Join(args);
            CommandLine = "docker " + joined;
            ProcessStartInfo psi = new ProcessStartInfo(exe, joined);
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            psi.StandardOutputEncoding = Encoding.UTF8;
            psi.StandardErrorEncoding = Encoding.UTF8;
            if (!String.IsNullOrEmpty(workingDir)) { psi.WorkingDirectory = workingDir; }
            psi.EnvironmentVariables["COMPOSE_ANSI"] = "never";
            psi.EnvironmentVariables["NO_COLOR"] = "1";
            Proc = new Process();
            Proc.StartInfo = psi;
            Proc.OutputDataReceived += OnOut;
            Proc.ErrorDataReceived += OnErr;
            Proc.Start();
            Proc.BeginOutputReadLine();
            Proc.BeginErrorReadLine();
        }

        private void OnOut(object sender, DataReceivedEventArgs e) {
            if (e.Data == null) { _outDone = true; return; }
            if (_capture) { lock (_lock) { _out.AppendLine(e.Data); } } else { Lines.Enqueue(e.Data); }
        }

        private void OnErr(object sender, DataReceivedEventArgs e) {
            if (e.Data == null) { _errDone = true; return; }
            lock (_lock) { _err.AppendLine(e.Data); }
            if (!_capture) { Lines.Enqueue(e.Data); }
        }

        public bool IsDone { get { return _outDone && _errDone && Proc.HasExited; } }
        public int ExitCode { get { return Proc.HasExited ? Proc.ExitCode : -1; } }
        public string Output { get { lock (_lock) { return _out.ToString(); } } }
        public string Error { get { lock (_lock) { return _err.ToString(); } } }

        // docker.exe starts docker-compose.exe as a child, so end the whole tree.
        public void Kill() {
            try {
                if (Proc.HasExited) { return; }
                ProcessStartInfo k = new ProcessStartInfo("taskkill.exe", "/T /F /PID " + Proc.Id);
                k.UseShellExecute = false;
                k.CreateNoWindow = true;
                Process kp = Process.Start(k);
                kp.WaitForExit(5000);
            } catch (Exception) { }
        }

        // Quotes one argument the way CommandLineToArgvW reads it back.
        public static string Quote(string a) {
            if (a == null) { return "\"\""; }
            if (a.Length > 0 && a.IndexOfAny(new char[] { ' ', '\t', '"' }) < 0) { return a; }
            StringBuilder sb = new StringBuilder("\"");
            int slashes = 0;
            foreach (char c in a) {
                if (c == '\\') { slashes++; continue; }
                if (c == '"') { sb.Append('\\', slashes * 2 + 1); sb.Append('"'); slashes = 0; continue; }
                if (slashes > 0) { sb.Append('\\', slashes); slashes = 0; }
                sb.Append(c);
            }
            sb.Append('\\', slashes * 2);
            sb.Append('"');
            return sb.ToString();
        }

        public static string Join(string[] args) {
            List<string> parts = new List<string>();
            foreach (string a in args) { parts.Add(Quote(a)); }
            return String.Join(" ", parts.ToArray());
        }
    }

    public abstract class Notifier : INotifyPropertyChanged {
        public event PropertyChangedEventHandler PropertyChanged;
        private readonly Dictionary<string, object> _v = new Dictionary<string, object>();
        protected object GetValue(string name) {
            object o;
            return _v.TryGetValue(name, out o) ? o : null;
        }
        protected void SetValue(string name, object value) {
            object o;
            if (_v.TryGetValue(name, out o) && Object.Equals(o, value)) { return; }
            _v[name] = value;
            PropertyChangedEventHandler h = PropertyChanged;
            if (h != null) { h(this, new PropertyChangedEventArgs(name)); }
        }
        protected string S(string name) { return (string)GetValue(name) ?? ""; }
        protected bool B(string name) { object o = GetValue(name); return o != null && (bool)o; }
    }

    public class Row : Notifier {
        public string Service       { get { return S("Service"); }       set { SetValue("Service", value); } }
        public string ContainerName { get { return S("ContainerName"); } set { SetValue("ContainerName", value); } }
        public string Group         { get { return S("Group"); }         set { SetValue("Group", value); } }
        public string GroupSort     { get { return S("GroupSort"); }     set { SetValue("GroupSort", value); } }
        public string State         { get { return S("State"); }         set { SetValue("State", value); } }
        public string StateKey      { get { return S("StateKey"); }      set { SetValue("StateKey", value); } }
        public string StateText     { get { return S("StateText"); }     set { SetValue("StateText", value); } }
        public string Since         { get { return S("Since"); }         set { SetValue("Since", value); } }
        public string Ports         { get { return S("Ports"); }         set { SetValue("Ports", value); } }
        public string Url           { get { return S("Url"); }           set { SetValue("Url", value); SetValue("HasUrl", !String.IsNullOrEmpty(value)); } }
        public bool   HasUrl        { get { return B("HasUrl"); } }
        public string Image         { get { return S("Image"); }         set { SetValue("Image", value); } }
        public string Description   { get { return S("Description"); }   set { SetValue("Description", value); } }
        public string Note          { get { return S("Note"); }          set { SetValue("Note", value); } }
        public string ConfigHash    { get { return S("ConfigHash"); }    set { SetValue("ConfigHash", value); } }
        public string RunningHash   { get { return S("RunningHash"); }   set { SetValue("RunningHash", value); } }
        public bool   InCompose     { get { return B("InCompose"); }     set { SetValue("InCompose", value); } }
        public bool   HasContainer  { get { return B("HasContainer"); }  set { SetValue("HasContainer", value); } }
        public bool   IsRunning     { get { return B("IsRunning"); }     set { SetValue("IsRunning", value); } }
        public bool   Changed       { get { return B("Changed"); }       set { SetValue("Changed", value); } }
        public bool   Problem       { get { return B("Problem"); }       set { SetValue("Problem", value); } }
    }

    public class Finding {
        public string Severity { get; set; }
        public int    Line     { get; set; }
        public string Service  { get; set; }
        public string Check    { get; set; }
        public string Message  { get; set; }
        public string LineText { get { return Line > 0 ? Line.ToString() : ""; } }
        public int    Order    { get { return Severity == "Error" ? 0 : (Severity == "Warning" ? 1 : 2); } }
    }

    public class GroupEntry : Notifier {
        public string Key     { get { return S("Key"); }     set { SetValue("Key", value); } }
        public string Name    { get { return S("Name"); }    set { SetValue("Name", value); } }
        public string Counts  { get { return S("Counts"); }  set { SetValue("Counts", value); } }
        public bool   Problem { get { return B("Problem"); } set { SetValue("Problem", value); } }
        public bool   Special { get { return B("Special"); } set { SetValue("Special", value); } }
    }
}
'@
}

# ---------------------------------------------------------------------------
# Settings (%APPDATA%\Docker Container Manager\settings.json)
# ---------------------------------------------------------------------------
$script:SettingsDir  = Join-Path ([Environment]::GetFolderPath('ApplicationData')) $script:AppName
$script:SettingsPath = Join-Path $script:SettingsDir 'settings.json'

function Get-DefaultSettings {
    [ordered]@{
        ComposeFile       = ''
        RecentFiles       = @()
        LabelPrefix       = 'home'
        RefreshSeconds    = 15
        PruneAfterUpdate  = $true
        ConfirmGroupStop  = $true
        MinimiseToTray    = $false
        Editor            = 'C:\Program Files\Microsoft VS Code\code.exe'
        ShowActivity      = $true
        WindowWidth       = 1280
        WindowHeight      = 800
        WindowMaximised   = $false
    }
}

function Read-Settings {
    $s = Get-DefaultSettings
    if (Test-Path -LiteralPath $script:SettingsPath) {
        try {
            $saved = [IO.File]::ReadAllText($script:SettingsPath) | ConvertFrom-Json
            foreach ($p in $saved.PSObject.Properties) {
                if ($s.Contains($p.Name)) { $s[$p.Name] = $p.Value }
            }
        } catch {
            Write-Verbose "Settings file unreadable, using defaults: $($_.Exception.Message)"
        }
    }
    $s.RecentFiles = @($s.RecentFiles | Where-Object { $_ })
    $refresh = 5
    if ([int]::TryParse([string]$s.RefreshSeconds, [ref]$refresh)) { $s.RefreshSeconds = [Math]::Min(300, [Math]::Max(2, $refresh)) }
    else { $s.RefreshSeconds = 15 }
    if (-not ([string]$s.LabelPrefix).Trim()) { $s.LabelPrefix = 'home' }
    return $s
}

function Save-Settings {
    try {
        if (-not (Test-Path -LiteralPath $script:SettingsDir)) { New-Item -ItemType Directory -Path $script:SettingsDir -Force | Out-Null }
        $json = [pscustomobject]$script:Settings | ConvertTo-Json -Depth 4
        [IO.File]::WriteAllText($script:SettingsPath, $json, (New-Object Text.UTF8Encoding($false)))
    } catch {
        Write-Activity "Couldn't save settings: $($_.Exception.Message)"
    }
}

$script:Settings = Read-Settings

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
$script:DockerExe      = $null
$script:DockerState    = 'unknown'   # unknown | ok | down | missing
$script:ComposePath    = ''
$script:ComposeDir     = ''
$script:ProjectName    = ''
$script:ConfigError    = ''
$script:ConfigLoaded   = $false
$script:ConfigLoading  = $false
$script:ConfigWanted   = $false
$script:ConfigGen      = 0
$script:LoadingGen     = 0
$script:PendingConfig  = $null
$script:PollProject    = ''
$script:BannerClick    = $null
$script:BannerKind     = ''
$script:UpdatingRecent = $false
$script:UpdatingGroups = $false
$script:Tray           = $null
$script:SettingsForm   = $null
$script:AboutDockerText = $null
$script:LastStatusSig  = ''
$script:LastFullStatus = [DateTime]::MinValue
$script:PollRunning    = $false
$script:NextPoll       = [DateTime]::MinValue
$script:FileStamp      = ''
$script:FileChangedAt  = [DateTime]::MinValue
$script:Calls          = New-Object System.Collections.ArrayList
$script:JobQueue       = New-Object System.Collections.Queue
$script:CurrentJob     = $null
$script:Rows           = New-Object 'System.Collections.ObjectModel.ObservableCollection[Dcm.Row]'
$script:RowIndex       = @{}
$script:Groups         = New-Object 'System.Collections.ObjectModel.ObservableCollection[Dcm.GroupEntry]'
$script:LogWindows     = New-Object System.Collections.ArrayList
$script:Closing        = $false
$script:UngroupedName  = 'Ungrouped'
$script:OrphanName     = 'Not in compose file'

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
function Get-AssetBytes([string]$Name) {
    if ($script:EmbeddedAssets.ContainsKey($Name)) { return [Convert]::FromBase64String($script:EmbeddedAssets[$Name]) }
    if ($PSScriptRoot) {
        $p = Join-Path (Split-Path -Parent $PSScriptRoot) "assets\$Name"
        if (Test-Path -LiteralPath $p) { return [IO.File]::ReadAllBytes($p) }
    }
    return $null
}

function Get-ImageSource([string]$Name) {
    $bytes = Get-AssetBytes $Name
    if (-not $bytes) { return $null }
    $bmp = New-Object Windows.Media.Imaging.BitmapImage
    $bmp.BeginInit()
    $bmp.StreamSource = New-Object IO.MemoryStream(, $bytes)
    $bmp.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bmp.EndInit()
    $bmp.Freeze()
    return $bmp
}

function Get-TrayIcon {
    $bytes = Get-AssetBytes 'Docker-Container-Manager.ico'
    if ($bytes) {
        try { return New-Object Drawing.Icon((New-Object IO.MemoryStream(, $bytes)), 16, 16) } catch { Write-Verbose 'Icon bytes unreadable.' }
    }
    try { return [Drawing.Icon]::ExtractAssociatedIcon([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) } catch { return [Drawing.SystemIcons]::Application }
}

function Find-Docker {
    $cmd = Get-Command docker.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    foreach ($p in @(
            (Join-Path $env:ProgramFiles 'Docker\Docker\resources\bin\docker.exe'),
            (Join-Path $env:ProgramData 'DockerDesktop\version-bin\docker.exe'))) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    return $null
}

function Find-DockerDesktop {
    foreach ($p in @(
            (Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'),
            (Join-Path $env:LOCALAPPDATA 'Docker\Docker Desktop.exe'))) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    return $null
}

function Get-ComposeArguments {
    return @('compose', '--ansi', 'never', '--progress', 'plain', '-f', $script:ComposePath, '--project-directory', $script:ComposeDir)
}

function Test-DockerDownMessage([string]$Text) {
    return ($Text -match 'error during connect|Cannot connect to the Docker daemon|docker daemon is not running|dockerDesktopLinuxEngine|docker_engine|The system cannot find the file specified|failed to connect to the docker API')
}

function Get-FirstLines([string]$Text, [int]$Count = 3) {
    $lines = @(($Text -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First $Count)
    return ($lines -join ' ').Trim()
}

# Starts a quick docker query. $OnDone gets an object with ExitCode, Output and
# Error once docker has finished (or straight away if docker can't be started).
function Start-DockerCall {
    param([string[]]$Arguments, [scriptblock]$OnDone, [switch]$Compose)
    $full = if ($Compose) { @(Get-ComposeArguments) + $Arguments } else { $Arguments }
    try {
        if (-not $script:DockerExe) { throw 'docker.exe was not found.' }
        $runner = New-Object Dcm.Runner($script:DockerExe, [string[]]$full, $script:ComposeDir, $true)
        [void]$script:Calls.Add(@{ Runner = $runner; OnDone = $OnDone; Started = [DateTime]::Now })
    } catch {
        $fail = [pscustomobject]@{ ExitCode = -1; Output = ''; Error = $_.Exception.Message }
        & $OnDone $fail
    }
}

function Update-Calls {
    if ($script:Calls.Count -eq 0) { return }
    foreach ($call in @($script:Calls)) {
        $r = $call.Runner
        $timedOut = (([DateTime]::Now - $call.Started).TotalSeconds -gt 120)
        if (-not $r.IsDone -and -not $timedOut) { continue }
        $script:Calls.Remove($call)
        if ($timedOut -and -not $r.IsDone) {
            $r.Kill()
            $res = [pscustomobject]@{ ExitCode = -1; Output = ''; Error = "Timed out: $($r.CommandLine)" }
        } else {
            $res = [pscustomobject]@{ ExitCode = $r.ExitCode; Output = $r.Output; Error = $r.Error }
        }
        try { & $call.OnDone $res } catch { Write-Activity "Internal error: $($_.Exception.Message)" }
    }
}

# ---------------------------------------------------------------------------
# Shared look: colours and control styles used by every window
# ---------------------------------------------------------------------------
$script:SharedResources = @'
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
    <SolidColorBrush x:Key="Ink" Color="#1B2A3D"/>
    <SolidColorBrush x:Key="SoftInk" Color="#5B6B80"/>
    <SolidColorBrush x:Key="Page" Color="#F2F5F9"/>
    <SolidColorBrush x:Key="Card" Color="#FFFFFF"/>
    <SolidColorBrush x:Key="Edge" Color="#D9E1EA"/>
    <SolidColorBrush x:Key="Accent" Color="#1769C2"/>
    <SolidColorBrush x:Key="AccentSoft" Color="#E3EFFC"/>
    <SolidColorBrush x:Key="Navy" Color="#0E2238"/>
    <SolidColorBrush x:Key="Ok" Color="#2DA44E"/>
    <SolidColorBrush x:Key="Warn" Color="#D99A06"/>
    <SolidColorBrush x:Key="Bad" Color="#CF2F3F"/>
    <SolidColorBrush x:Key="Off" Color="#97A3B3"/>
    <SolidColorBrush x:Key="Orphan" Color="#8250DF"/>
    <BooleanToVisibilityConverter x:Key="B2V"/>

    <Style x:Key="Btn" TargetType="Button">
        <Setter Property="Foreground" Value="{StaticResource Ink}"/>
        <Setter Property="Background" Value="{StaticResource Card}"/>
        <Setter Property="BorderBrush" Value="{StaticResource Edge}"/>
        <Setter Property="Padding" Value="10,5"/>
        <Setter Property="Margin" Value="0,0,6,0"/>
        <Setter Property="Cursor" Value="Hand"/>
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="Button">
                    <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                            BorderThickness="1" CornerRadius="6" Padding="{TemplateBinding Padding}">
                        <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Center">
                            <TextBlock x:Name="Glyph" Text="{TemplateBinding Tag}" FontFamily="Segoe MDL2 Assets" FontSize="13"
                                       VerticalAlignment="Center" Margin="0,0,7,0"/>
                            <ContentPresenter VerticalAlignment="Center"/>
                        </StackPanel>
                    </Border>
                    <ControlTemplate.Triggers>
                        <Trigger Property="Tag" Value="{x:Null}">
                            <Setter TargetName="Glyph" Property="Visibility" Value="Collapsed"/>
                        </Trigger>
                        <Trigger Property="IsMouseOver" Value="True">
                            <Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource Accent}"/>
                        </Trigger>
                        <Trigger Property="IsPressed" Value="True">
                            <Setter TargetName="Bd" Property="Background" Value="{StaticResource AccentSoft}"/>
                        </Trigger>
                        <Trigger Property="IsEnabled" Value="False">
                            <Setter Property="Opacity" Value="0.45"/>
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>
    <Style x:Key="PrimaryBtn" TargetType="Button" BasedOn="{StaticResource Btn}">
        <Setter Property="Background" Value="{StaticResource Accent}"/>
        <Setter Property="BorderBrush" Value="{StaticResource Accent}"/>
        <Setter Property="Foreground" Value="#FFFFFF"/>
    </Style>
    <Style x:Key="HeaderBtn" TargetType="Button" BasedOn="{StaticResource Btn}">
        <Setter Property="Background" Value="#22FFFFFF"/>
        <Setter Property="BorderBrush" Value="#44FFFFFF"/>
        <Setter Property="Foreground" Value="#FFFFFF"/>
    </Style>
    <Style x:Key="LinkBtn" TargetType="Button">
        <Setter Property="Cursor" Value="Hand"/>
        <Setter Property="Foreground" Value="{StaticResource Accent}"/>
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="Button">
                    <TextBlock x:Name="T" Text="{TemplateBinding Content}" Foreground="{TemplateBinding Foreground}"/>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsMouseOver" Value="True">
                            <Setter TargetName="T" Property="TextDecorations" Value="Underline"/>
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>
    <Style x:Key="Field" TargetType="TextBox">
        <Setter Property="Padding" Value="6,4"/>
        <Setter Property="BorderBrush" Value="{StaticResource Edge}"/>
        <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style x:Key="Dot" TargetType="Ellipse">
        <Setter Property="Width" Value="10"/>
        <Setter Property="Height" Value="10"/>
        <Setter Property="Fill" Value="{StaticResource Off}"/>
        <Style.Triggers>
            <DataTrigger Binding="{Binding StateKey}" Value="ok"><Setter Property="Fill" Value="{StaticResource Ok}"/></DataTrigger>
            <DataTrigger Binding="{Binding StateKey}" Value="warn"><Setter Property="Fill" Value="{StaticResource Warn}"/></DataTrigger>
            <DataTrigger Binding="{Binding StateKey}" Value="bad"><Setter Property="Fill" Value="{StaticResource Bad}"/></DataTrigger>
            <DataTrigger Binding="{Binding StateKey}" Value="none">
                <Setter Property="Fill" Value="Transparent"/>
                <Setter Property="Stroke" Value="{StaticResource Off}"/>
                <Setter Property="StrokeThickness" Value="1.5"/>
            </DataTrigger>
        </Style.Triggers>
    </Style>
</ResourceDictionary>
'@

# The shared styles are pasted into each window's <Window.Resources> (where the
# window's XAML has <!--SHARED-->), so StaticResource lookups work at load time.
$script:SharedInner = [regex]::Match($script:SharedResources, '(?s)<ResourceDictionary[^>]*>(.*)</ResourceDictionary>').Groups[1].Value

function New-XamlObject([string]$Xaml) {
    $reader = New-Object System.Xml.XmlNodeReader ([xml]($Xaml.Replace('<!--SHARED-->', $script:SharedInner)))
    return [Windows.Markup.XamlReader]::Load($reader)
}

# ---------------------------------------------------------------------------
# Main window
# ---------------------------------------------------------------------------
$mainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Docker Container Manager" Width="1280" Height="800" MinWidth="900" MinHeight="540"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" FontSize="13"
        Background="{DynamicResource Page}" Foreground="{DynamicResource Ink}"
        UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
    <Window.Resources><!--SHARED--></Window.Resources>
    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*" MinHeight="200"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition x:Name="LogRow" Height="170" MinHeight="0"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Header -->
        <Border Grid.Row="0" Padding="16,12">
            <Border.Background>
                <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                    <GradientStop Color="#0E2238" Offset="0"/>
                    <GradientStop Color="#1769C2" Offset="1"/>
                </LinearGradientBrush>
            </Border.Background>
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <Image x:Name="ImgLogo" Width="44" Height="44" Margin="0,0,12,0" RenderOptions.BitmapScalingMode="HighQuality"/>
                <StackPanel Grid.Column="1" VerticalAlignment="Center">
                    <TextBlock Text="Docker Container Manager" FontSize="20" FontWeight="SemiBold" Foreground="#FFFFFF"/>
                    <TextBlock x:Name="TxtSubtitle" Foreground="#CFE0F5" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
                </StackPanel>
                <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                    <ComboBox x:Name="CmbRecent" Width="230" Margin="0,0,6,0" VerticalContentAlignment="Center"
                              ToolTip="Switch to another compose file you've used on this PC"/>
                    <Button x:Name="BtnBrowse" Content="Compose file..." Tag="&#xE8E5;" Style="{DynamicResource HeaderBtn}"
                            ToolTip="Choose a docker-compose.yml"/>
                    <Button x:Name="BtnEditCompose" Content="Edit" Tag="&#xE70F;" Style="{DynamicResource HeaderBtn}"
                            ToolTip="Open the compose file in your editor. The list updates when you save."/>
                    <Button x:Name="BtnEditEnv" Content=".env" Tag="&#xE70F;" Style="{DynamicResource HeaderBtn}"
                            ToolTip="Open the .env file next to the compose file"/>
                    <Button x:Name="BtnCheck" Content="Check" Tag="&#xE73E;" Style="{DynamicResource HeaderBtn}"
                            ToolTip="Check the compose file for spacing, ${...} variables, port clashes and other mistakes"/>
                    <Button x:Name="BtnFolder" Content="Folder" Tag="&#xE8B7;" Style="{DynamicResource HeaderBtn}"
                            ToolTip="Open the compose file's folder"/>
                    <Button x:Name="BtnSettings" Content="Settings" Tag="&#xE713;" Style="{DynamicResource HeaderBtn}"/>
                    <Button x:Name="BtnAbout" Content="About" Tag="&#xE946;" Style="{DynamicResource HeaderBtn}" Margin="0"/>
                </StackPanel>
            </Grid>
        </Border>

        <!-- Banner: Docker not running, compose errors, missing .env -->
        <Border x:Name="Banner" Grid.Row="1" Padding="16,9" Visibility="Collapsed" Background="#FFF4D6" BorderBrush="#E8C66A" BorderThickness="0,0,0,1">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="BannerGlyph" FontFamily="Segoe MDL2 Assets" Text="&#xE7BA;" FontSize="16" VerticalAlignment="Center" Margin="0,0,10,0"/>
                <TextBlock x:Name="BannerText" Grid.Column="1" TextWrapping="Wrap" VerticalAlignment="Center"/>
                <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center" Margin="12,0,0,0">
                    <ComboBox x:Name="CmbEnvTemplate" Width="150" Margin="0,0,6,0" Visibility="Collapsed"/>
                    <Button x:Name="BannerAction" Style="{DynamicResource PrimaryBtn}" Visibility="Collapsed"/>
                    <Button x:Name="BannerRetry" Content="Try again" Tag="&#xE72C;" Style="{DynamicResource Btn}" Margin="0"/>
                </StackPanel>
            </Grid>
        </Border>

        <!-- Body -->
        <Grid Grid.Row="2" Margin="12,12,12,8">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="230" MinWidth="170"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <!-- Groups pane -->
            <Border Background="{DynamicResource Card}" BorderBrush="{DynamicResource Edge}" BorderThickness="1" CornerRadius="8">
                <DockPanel>
                    <TextBlock DockPanel.Dock="Top" Text="Groups" FontWeight="SemiBold" Margin="12,10,12,6" Foreground="{DynamicResource SoftInk}"/>
                    <ListBox x:Name="LstGroups" BorderThickness="0" Background="Transparent" Margin="4,0,4,6"
                             ScrollViewer.HorizontalScrollBarVisibility="Disabled">
                        <ListBox.ItemContainerStyle>
                            <Style TargetType="ListBoxItem">
                                <Setter Property="Padding" Value="8,6"/>
                                <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
                                <Setter Property="Template">
                                    <Setter.Value>
                                        <ControlTemplate TargetType="ListBoxItem">
                                            <Border x:Name="Bd" CornerRadius="6" Padding="{TemplateBinding Padding}" Background="Transparent">
                                                <ContentPresenter/>
                                            </Border>
                                            <ControlTemplate.Triggers>
                                                <Trigger Property="IsMouseOver" Value="True">
                                                    <Setter TargetName="Bd" Property="Background" Value="#F0F4F9"/>
                                                </Trigger>
                                                <Trigger Property="IsSelected" Value="True">
                                                    <Setter TargetName="Bd" Property="Background" Value="{DynamicResource AccentSoft}"/>
                                                </Trigger>
                                            </ControlTemplate.Triggers>
                                        </ControlTemplate>
                                    </Setter.Value>
                                </Setter>
                            </Style>
                        </ListBox.ItemContainerStyle>
                        <ListBox.ItemTemplate>
                            <DataTemplate>
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock x:Name="N" Text="{Binding Name}" TextTrimming="CharacterEllipsis"/>
                                    <StackPanel Grid.Column="1" Orientation="Horizontal">
                                        <Ellipse Width="7" Height="7" Fill="{DynamicResource Bad}" Margin="6,0,6,0" VerticalAlignment="Center"
                                                 Visibility="{Binding Problem, Converter={StaticResource B2V}}" ToolTip="Something in this group needs a look"/>
                                        <TextBlock Text="{Binding Counts}" Foreground="{DynamicResource SoftInk}" FontSize="12" VerticalAlignment="Center"/>
                                    </StackPanel>
                                </Grid>
                                <DataTemplate.Triggers>
                                    <DataTrigger Binding="{Binding Special}" Value="True">
                                        <Setter TargetName="N" Property="FontStyle" Value="Italic"/>
                                    </DataTrigger>
                                    <DataTrigger Binding="{Binding Key}" Value="*">
                                        <Setter TargetName="N" Property="FontWeight" Value="SemiBold"/>
                                        <Setter TargetName="N" Property="FontStyle" Value="Normal"/>
                                    </DataTrigger>
                                </DataTemplate.Triggers>
                            </DataTemplate>
                        </ListBox.ItemTemplate>
                    </ListBox>
                </DockPanel>
            </Border>

            <GridSplitter Grid.Column="1" Width="10" HorizontalAlignment="Center" VerticalAlignment="Stretch" Background="Transparent"/>

            <!-- Containers -->
            <Grid Grid.Column="2">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>

                <!-- Search and selection actions -->
                <Grid Margin="0,0,0,8">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="220"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <Grid>
                        <TextBox x:Name="TxtSearch" Style="{DynamicResource Field}" Padding="26,4,6,4" ToolTip="Search by name, image, group or port (Ctrl+F)"/>
                        <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE721;" Foreground="{DynamicResource SoftInk}" Margin="8,0,0,0"
                                   VerticalAlignment="Center" IsHitTestVisible="False"/>
                        <TextBlock x:Name="SearchHint" Text="Search" Foreground="{DynamicResource Off}" Margin="27,0,0,0"
                                   VerticalAlignment="Center" IsHitTestVisible="False"/>
                    </Grid>
                    <ComboBox x:Name="CmbState" Grid.Column="1" Width="130" Margin="6,0,0,0" VerticalContentAlignment="Center"
                              ToolTip="Show only containers in this state"/>
                    <WrapPanel Grid.Column="2" HorizontalAlignment="Right" VerticalAlignment="Center">
                        <Button x:Name="BtnStart" Content="Start" Tag="&#xE768;" Style="{DynamicResource Btn}" ToolTip="Start the selected containers (creates them if needed)"/>
                        <Button x:Name="BtnStop" Content="Stop" Tag="&#xE71A;" Style="{DynamicResource Btn}" ToolTip="Stop the selected containers"/>
                        <Button x:Name="BtnRestart" Content="Restart" Tag="&#xE72C;" Style="{DynamicResource Btn}" ToolTip="Restart the selected containers"/>
                        <Button x:Name="BtnUpdate" Content="Update" Tag="&#xE896;" Style="{DynamicResource Btn}"
                                ToolTip="Pull the newest images and recreate the selected containers. Stopped ones stay stopped."/>
                        <Button x:Name="BtnLogs" Content="Logs" Tag="&#xE9F9;" Style="{DynamicResource Btn}" ToolTip="Show the logs of the selected container (Ctrl+L)"/>
                        <Button x:Name="BtnOpen" Content="Open" Tag="&#xE774;" Style="{DynamicResource Btn}" ToolTip="Open the selected container's web page (Enter)" Margin="0"/>
                    </WrapPanel>
                </Grid>

                <!-- Group bar -->
                <Border Grid.Row="1" Background="{DynamicResource Card}" BorderBrush="{DynamicResource Edge}" BorderThickness="1" CornerRadius="8"
                        Padding="12,8" Margin="0,0,0,8">
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <StackPanel VerticalAlignment="Center">
                            <TextBlock x:Name="TxtGroupName" FontSize="15" FontWeight="SemiBold"/>
                            <TextBlock x:Name="TxtGroupInfo" Foreground="{DynamicResource SoftInk}" Margin="0,1,0,0" TextTrimming="CharacterEllipsis"/>
                        </StackPanel>
                        <WrapPanel Grid.Column="1" VerticalAlignment="Center">
                            <Button x:Name="BtnApply" Tag="&#xE73E;" Style="{DynamicResource PrimaryBtn}" Visibility="Collapsed"
                                    ToolTip="Recreate the containers whose settings changed in the compose file. Stopped ones stay stopped."/>
                            <Button x:Name="BtnGroupStart" Content="Start group" Tag="&#xE768;" Style="{DynamicResource Btn}"/>
                            <Button x:Name="BtnGroupStop" Content="Stop group" Tag="&#xE71A;" Style="{DynamicResource Btn}"/>
                            <Button x:Name="BtnGroupUpdate" Content="Update group" Tag="&#xE896;" Style="{DynamicResource Btn}"/>
                            <Button x:Name="BtnRemoveOrphans" Content="Remove all" Tag="&#xE74D;" Style="{DynamicResource Btn}" Visibility="Collapsed"
                                    ToolTip="Remove these containers. Their data folders are not touched."/>
                            <Button x:Name="BtnRefresh" Content="Refresh" Tag="&#xE72C;" Style="{DynamicResource Btn}" Margin="0" ToolTip="Read the compose file and status again (F5)"/>
                        </WrapPanel>
                    </Grid>
                </Border>

                <!-- Grid -->
                <Border Grid.Row="2" Background="{DynamicResource Card}" BorderBrush="{DynamicResource Edge}" BorderThickness="1" CornerRadius="8">
                    <Grid>
                        <DataGrid x:Name="Grid" AutoGenerateColumns="False" IsReadOnly="True" HeadersVisibility="Column"
                                  GridLinesVisibility="None" BorderThickness="0" Background="Transparent" RowBackground="Transparent"
                                  SelectionMode="Extended" SelectionUnit="FullRow" CanUserResizeRows="False" CanUserReorderColumns="False"
                                  RowHeight="30" Margin="4">
                            <DataGrid.ColumnHeaderStyle>
                                <Style TargetType="DataGridColumnHeader">
                                    <Setter Property="Background" Value="Transparent"/>
                                    <Setter Property="Foreground" Value="{DynamicResource SoftInk}"/>
                                    <Setter Property="FontWeight" Value="SemiBold"/>
                                    <Setter Property="Padding" Value="8,6"/>
                                    <Setter Property="BorderBrush" Value="{DynamicResource Edge}"/>
                                    <Setter Property="BorderThickness" Value="0,0,0,1"/>
                                </Style>
                            </DataGrid.ColumnHeaderStyle>
                            <DataGrid.CellStyle>
                                <Style TargetType="DataGridCell">
                                    <Setter Property="BorderThickness" Value="0"/>
                                    <Setter Property="Padding" Value="8,0"/>
                                    <Setter Property="Template">
                                        <Setter.Value>
                                            <ControlTemplate TargetType="DataGridCell">
                                                <Border Padding="{TemplateBinding Padding}" Background="Transparent">
                                                    <ContentPresenter VerticalAlignment="Center"/>
                                                </Border>
                                            </ControlTemplate>
                                        </Setter.Value>
                                    </Setter>
                                    <Style.Triggers>
                                        <Trigger Property="IsSelected" Value="True">
                                            <Setter Property="Foreground" Value="{DynamicResource Ink}"/>
                                        </Trigger>
                                    </Style.Triggers>
                                </Style>
                            </DataGrid.CellStyle>
                            <DataGrid.RowStyle>
                                <Style TargetType="DataGridRow">
                                    <Setter Property="ToolTip" Value="{Binding Description}"/>
                                    <Setter Property="BorderThickness" Value="4,0,0,0"/>
                                    <Setter Property="BorderBrush" Value="Transparent"/>
                                    <Style.Triggers>
                                        <Trigger Property="IsMouseOver" Value="True">
                                            <Setter Property="Background" Value="#F3F7FC"/>
                                        </Trigger>
                                        <Trigger Property="IsSelected" Value="True">
                                            <Setter Property="Background" Value="#BFD9F7"/>
                                            <Setter Property="BorderBrush" Value="{DynamicResource Accent}"/>
                                            <Setter Property="FontWeight" Value="SemiBold"/>
                                        </Trigger>
                                        <DataTrigger Binding="{Binding Description}" Value="">
                                            <Setter Property="ToolTip" Value="{x:Null}"/>
                                        </DataTrigger>
                                    </Style.Triggers>
                                </Style>
                            </DataGrid.RowStyle>
                            <DataGrid.GroupStyle>
                                <GroupStyle>
                                    <GroupStyle.ContainerStyle>
                                        <Style TargetType="GroupItem">
                                            <Setter Property="Template">
                                                <Setter.Value>
                                                    <ControlTemplate TargetType="GroupItem">
                                                        <Expander IsExpanded="True" Margin="0,2,0,2">
                                                            <Expander.Header>
                                                                <StackPanel Orientation="Horizontal">
                                                                    <TextBlock Text="{Binding Name}" FontWeight="SemiBold" Foreground="{DynamicResource Accent}"/>
                                                                    <TextBlock Text="{Binding ItemCount, StringFormat=' ({0})'}" Foreground="{DynamicResource SoftInk}"/>
                                                                </StackPanel>
                                                            </Expander.Header>
                                                            <ItemsPresenter/>
                                                        </Expander>
                                                    </ControlTemplate>
                                                </Setter.Value>
                                            </Setter>
                                        </Style>
                                    </GroupStyle.ContainerStyle>
                                </GroupStyle>
                            </DataGrid.GroupStyle>
                            <DataGrid.Columns>
                                <DataGridTemplateColumn Width="30" CanUserResize="False">
                                    <DataGridTemplateColumn.CellTemplate>
                                        <DataTemplate>
                                            <Ellipse Style="{DynamicResource Dot}" HorizontalAlignment="Center"/>
                                        </DataTemplate>
                                    </DataGridTemplateColumn.CellTemplate>
                                </DataGridTemplateColumn>
                                <DataGridTextColumn Header="Container" Binding="{Binding Service}" Width="200" MinWidth="200" SortMemberPath="Service">
                                    <DataGridTextColumn.ElementStyle>
                                        <Style TargetType="TextBlock"><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="TextTrimming" Value="CharacterEllipsis"/></Style>
                                    </DataGridTextColumn.ElementStyle>
                                </DataGridTextColumn>
                                <DataGridTextColumn Header="State" Binding="{Binding StateText}" Width="120" MinWidth="110"/>
                                <DataGridTextColumn Header="Since" Binding="{Binding Since}" Width="120" MinWidth="110"/>
                                <DataGridTemplateColumn Header="Web page" Width="140" MinWidth="120" SortMemberPath="Url">
                                    <DataGridTemplateColumn.CellTemplate>
                                        <DataTemplate>
                                            <Button Style="{DynamicResource LinkBtn}" Content="{Binding Ports}" Tag="{Binding Url}" ToolTip="{Binding Url}"
                                                    Visibility="{Binding HasUrl, Converter={StaticResource B2V}}"/>
                                        </DataTemplate>
                                    </DataGridTemplateColumn.CellTemplate>
                                </DataGridTemplateColumn>
                                <DataGridTextColumn Header="Image" Binding="{Binding Image}" Width="*" MinWidth="150">
                                    <DataGridTextColumn.ElementStyle>
                                        <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#5B6B80"/><Setter Property="TextTrimming" Value="CharacterEllipsis"/></Style>
                                    </DataGridTextColumn.ElementStyle>
                                </DataGridTextColumn>
                                <DataGridTextColumn Header="Note" Binding="{Binding Note}" Width="190" MinWidth="170">
                                    <DataGridTextColumn.ElementStyle>
                                        <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#B07A00"/><Setter Property="TextTrimming" Value="CharacterEllipsis"/></Style>
                                    </DataGridTextColumn.ElementStyle>
                                </DataGridTextColumn>
                            </DataGrid.Columns>
                            <DataGrid.ContextMenu>
                                <ContextMenu x:Name="RowMenu">
                                    <MenuItem x:Name="MnuStart" Header="Start"/>
                                    <MenuItem x:Name="MnuStop" Header="Stop"/>
                                    <MenuItem x:Name="MnuRestart" Header="Restart"/>
                                    <Separator/>
                                    <MenuItem x:Name="MnuUpdate" Header="Update (pull and recreate)"/>
                                    <MenuItem x:Name="MnuRecreate" Header="Recreate"/>
                                    <Separator/>
                                    <MenuItem x:Name="MnuLogs" Header="Logs"/>
                                    <MenuItem x:Name="MnuOpen" Header="Open web page"/>
                                    <MenuItem x:Name="MnuCopy" Header="Copy name"/>
                                    <Separator/>
                                    <MenuItem x:Name="MnuRemove" Header="Remove container..."/>
                                </ContextMenu>
                            </DataGrid.ContextMenu>
                        </DataGrid>
                        <TextBlock x:Name="TxtEmpty" HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="{DynamicResource SoftInk}"
                                   TextWrapping="Wrap" TextAlignment="Center" MaxWidth="420" Visibility="Collapsed"/>
                    </Grid>
                </Border>
            </Grid>
        </Grid>

        <!-- Activity log -->
        <GridSplitter x:Name="LogSplitter" Grid.Row="3" Height="6" HorizontalAlignment="Stretch" Background="Transparent" ResizeDirection="Rows"/>
        <Border x:Name="LogPane" Grid.Row="4" Background="{DynamicResource Navy}" CornerRadius="8" Margin="12,0,12,8">
            <DockPanel>
                <Grid DockPanel.Dock="Top" Margin="12,6,8,0">
                    <TextBlock Text="Activity" Foreground="#CFE0F5" FontWeight="SemiBold" VerticalAlignment="Center"/>
                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                        <Button x:Name="BtnLogCopy" Content="Copy" Style="{DynamicResource LinkBtn}" Foreground="#9CC3F0" Margin="0,0,14,0"/>
                        <Button x:Name="BtnLogClear" Content="Clear" Style="{DynamicResource LinkBtn}" Foreground="#9CC3F0"/>
                    </StackPanel>
                </Grid>
                <TextBox x:Name="TxtLog" IsReadOnly="True" BorderThickness="0" Background="Transparent" Foreground="#E3ECF7"
                         FontFamily="Consolas" FontSize="12" Margin="8,4,8,8" TextWrapping="NoWrap"
                         VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
            </DockPanel>
        </Border>

        <!-- Status bar -->
        <Border Grid.Row="5" Background="{DynamicResource Card}" BorderBrush="{DynamicResource Edge}" BorderThickness="0,1,0,0" Padding="14,5">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="TxtStatus" VerticalAlignment="Center" TextTrimming="CharacterEllipsis" Foreground="{DynamicResource SoftInk}"/>
                <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                    <ProgressBar x:Name="PrgBusy" Width="110" Height="6" IsIndeterminate="True" Visibility="Collapsed" Margin="0,0,10,0"/>
                    <TextBlock x:Name="TxtBusy" VerticalAlignment="Center" Margin="0,0,10,0" Foreground="{DynamicResource SoftInk}"/>
                    <Button x:Name="BtnCancel" Content="Cancel" Style="{DynamicResource LinkBtn}" Visibility="Collapsed" Margin="0,0,14,0"/>
                    <CheckBox x:Name="ChkActivity" Content="Activity" VerticalAlignment="Center" ToolTip="Show or hide the activity log"/>
                </StackPanel>
            </Grid>
        </Border>
    </Grid>
</Window>
'@

$window = New-XamlObject $mainXaml
$ui = @{}
foreach ($name in 'ImgLogo', 'TxtSubtitle', 'CmbRecent', 'BtnBrowse', 'BtnEditCompose', 'BtnEditEnv', 'BtnCheck', 'BtnFolder', 'BtnSettings', 'BtnAbout',
    'Banner', 'BannerGlyph', 'BannerText', 'CmbEnvTemplate', 'BannerAction', 'BannerRetry',
    'LstGroups', 'TxtSearch', 'SearchHint', 'CmbState', 'BtnStart', 'BtnStop', 'BtnRestart', 'BtnUpdate', 'BtnLogs', 'BtnOpen',
    'TxtGroupName', 'TxtGroupInfo', 'BtnApply', 'BtnGroupStart', 'BtnGroupStop', 'BtnGroupUpdate', 'BtnRemoveOrphans', 'BtnRefresh',
    'Grid', 'TxtEmpty', 'RowMenu', 'MnuStart', 'MnuStop', 'MnuRestart', 'MnuUpdate', 'MnuRecreate', 'MnuLogs', 'MnuOpen', 'MnuCopy', 'MnuRemove',
    'LogRow', 'LogSplitter', 'LogPane', 'BtnLogCopy', 'BtnLogClear', 'TxtLog', 'TxtStatus', 'PrgBusy', 'TxtBusy', 'BtnCancel', 'ChkActivity') {
    $ui[$name] = $window.FindName($name)
}
if (-not $ui.MnuStart) {
    # Names inside a ContextMenu can sit outside the window's name scope.
    foreach ($item in $ui.Grid.ContextMenu.Items) { if ($item.Name) { $ui[$item.Name] = $item } }
}
$window.Title = "$script:AppName v$script:AppVersion"

# ---------------------------------------------------------------------------
# Activity log, status bar and banner
# ---------------------------------------------------------------------------
$script:LogLimit = 400000
function Write-Activity([string]$Text, [switch]$Plain) {
    if (-not $ui -or -not $ui.TxtLog) { return }
    $line = if ($Plain) { $Text } else { '[{0}] {1}' -f (Get-Date).ToString('HH:mm:ss'), $Text }
    $box = $ui.TxtLog
    $atEnd = ($box.VerticalOffset + $box.ViewportHeight) -ge ($box.ExtentHeight - 4)
    $box.AppendText($line + "`r`n")
    if ($box.Text.Length -gt $script:LogLimit) { $box.Text = $box.Text.Substring($box.Text.Length - [int]($script:LogLimit * 0.75)) }
    if ($atEnd) { $box.ScrollToEnd() }
}

function Set-Status([string]$Text) { $ui.TxtStatus.Text = $Text }

# Set DCM_TRACE=1 before starting the app to log what the list is doing.
$script:Trace = [bool]$env:DCM_TRACE
function Write-Trace([string]$Text) { if ($script:Trace) { Write-Activity "trace: $Text" } }

# Kind: info | warn | error. Action: $null or @{ Text; Glyph; Click = scriptblock }
function Show-Banner {
    param([string]$Kind, [string]$Text, [hashtable]$Action, [switch]$EnvPicker)
    $colours = @{ info = @('#E3EFFC', '#9CC3F0', [char]0xE946); warn = @('#FFF4D6', '#E8C66A', [char]0xE7BA); error = @('#FDE3E6', '#EBA2AA', [char]0xEA39) }
    $c = $colours[$Kind]
    $ui.Banner.Background = [Windows.Media.BrushConverter]::new().ConvertFromString($c[0])
    $ui.Banner.BorderBrush = [Windows.Media.BrushConverter]::new().ConvertFromString($c[1])
    $ui.BannerGlyph.Text = [string]$c[2]
    $ui.BannerText.Text = $Text
    $script:BannerClick = $null
    if ($Action) {
        $ui.BannerAction.Content = $Action.Text
        $ui.BannerAction.Tag = $Action.Glyph
        $script:BannerClick = $Action.Click
        $ui.BannerAction.Visibility = 'Visible'
    } else {
        $ui.BannerAction.Visibility = 'Collapsed'
    }
    $ui.CmbEnvTemplate.Visibility = if ($EnvPicker) { 'Visible' } else { 'Collapsed' }
    $ui.Banner.Visibility = 'Visible'
}

function Hide-Banner { $ui.Banner.Visibility = 'Collapsed'; $script:BannerKind = '' }

# One place decides which banner shows, most important first.
function Update-Banner {
    if ($script:DockerState -eq 'missing') {
        Show-Banner -Kind error -Text "Docker isn't installed (docker.exe wasn't found). Install Docker Desktop, then press Try again."
        return
    }
    if (-not $script:ComposePath) {
        Show-Banner -Kind info -Text 'Choose the docker-compose.yml you want to manage. You can switch between compose files later from the list at the top.' `
            -Action @{ Text = 'Choose compose file...'; Glyph = [string][char]0xE8E5; Click = { Select-ComposeFile } }
        return
    }
    if (-not (Test-Path -LiteralPath $script:ComposePath)) {
        Show-Banner -Kind error -Text "The compose file isn't there any more: $script:ComposePath" `
            -Action @{ Text = 'Choose compose file...'; Glyph = [string][char]0xE8E5; Click = { Select-ComposeFile } }
        return
    }
    if ($script:DockerState -eq 'down') {
        $desktop = Find-DockerDesktop
        $action = if ($desktop) { @{ Text = 'Start Docker Desktop'; Glyph = [string][char]0xE768; Click = { Start-DockerDesktop } } } else { $null }
        Show-Banner -Kind warn -Text "Docker isn't running, so the status below may be out of date. Start Docker, and the list catches up on its own." -Action $action
        return
    }
    $envPath = Join-Path $script:ComposeDir '.env'
    $templates = @(Get-ChildItem -LiteralPath $script:ComposeDir -Filter 'Env_*' -File -ErrorAction SilentlyContinue)
    if ($script:ConfigError) {
        $extra = if (-not (Test-Path -LiteralPath $envPath) -and $templates.Count) { ' There is no .env here yet, which may be why.' } else { '' }
        Show-Banner -Kind error -Text ("The compose file has a problem, so the list shows the last version that worked. Docker says: " + $script:ConfigError + $extra) `
            -Action @{ Text = 'Edit compose file'; Glyph = [string][char]0xE70F; Click = { Open-InEditor $script:ComposePath } }
        return
    }
    if (-not (Test-Path -LiteralPath $envPath) -and $templates.Count) {
        $ui.CmbEnvTemplate.Items.Clear()
        foreach ($t in $templates) { [void]$ui.CmbEnvTemplate.Items.Add($t.Name) }
        $pick = @($templates | Where-Object Name -eq 'Env_Windows')
        $ui.CmbEnvTemplate.SelectedItem = if ($pick.Count) { 'Env_Windows' } else { $templates[0].Name }
        Show-Banner -Kind warn -Text 'This folder has no .env file yet, only templates. Pick the one for this machine to copy it to .env.' -EnvPicker `
            -Action @{ Text = 'Create .env'; Glyph = [string][char]0xE710; Click = { New-EnvFromTemplate } }
        return
    }
    Hide-Banner
}

function Start-DockerDesktop {
    $desktop = Find-DockerDesktop
    if (-not $desktop) { return }
    try {
        Start-Process -FilePath $desktop
        Write-Activity 'Starting Docker Desktop...'
        Set-Status 'Starting Docker Desktop. This can take a minute.'
    } catch {
        Write-Activity "Couldn't start Docker Desktop: $($_.Exception.Message)"
    }
}

function New-EnvFromTemplate {
    $name = [string]$ui.CmbEnvTemplate.SelectedItem
    if (-not $name) { return }
    $target = Join-Path $script:ComposeDir '.env'
    if (Test-Path -LiteralPath $target) { Update-Banner; return }
    try {
        Copy-Item -LiteralPath (Join-Path $script:ComposeDir $name) -Destination $target
        Write-Activity "Copied $name to .env"
        Request-ConfigLoad
    } catch {
        [void][Windows.MessageBox]::Show($window, "Couldn't create .env: $($_.Exception.Message)", $script:AppName, 'OK', 'Error')
    }
}

function Open-InEditor([string]$Path, [int]$Line = 0) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        [void][Windows.MessageBox]::Show($window, "There's no file at $Path yet.", $script:AppName, 'OK', 'Information')
        return
    }
    $editor = [string]$script:Settings.Editor
    try {
        if ($editor -and (Test-Path -LiteralPath $editor)) {
            $exe = [IO.Path]::GetFileName($editor).ToLowerInvariant()
            $editorArgs = "`"$Path`""
            if ($Line -gt 0) {
                if ($exe -eq 'code.exe' -or $exe -eq 'code - insiders.exe' -or $exe -eq 'vscodium.exe') { $editorArgs = "-g `"$($Path):$Line`"" }
                elseif ($exe -eq 'notepad++.exe') { $editorArgs = "-n$Line `"$Path`"" }
                elseif ($exe -eq 'sublime_text.exe' -or $exe -eq 'subl.exe') { $editorArgs = "`"$($Path):$Line`"" }
            }
            Start-Process -FilePath $editor -ArgumentList $editorArgs
        }
        else { Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$Path`"" }
    } catch {
        [void][Windows.MessageBox]::Show($window, "Couldn't open the editor: $($_.Exception.Message)", $script:AppName, 'OK', 'Error')
    }
}

# ---------------------------------------------------------------------------
# Compose file check. Reads the file as text (no Docker needed, so it also works
# when Docker rejects the file) and reports spacing, ${...} variables, ports,
# names, depends_on, folders, groups, image versions and passwords in the file.
# ---------------------------------------------------------------------------
$script:KnownServiceKeys = @{}
foreach ($k in ('image container_name restart ports volumes environment env_file labels depends_on networks command entrypoint ' +
        'devices cap_add cap_drop extra_hosts dns dns_opt dns_search healthcheck deploy build user working_dir hostname domainname ' +
        'privileged security_opt shm_size tmpfs ulimits logging network_mode stdin_open tty init read_only mem_limit ' +
        'mem_reservation memswap_limit mem_swappiness cpus cpu_shares cpu_count cpu_percent cpu_period cpu_quota cpu_rt_runtime ' +
        'cpu_rt_period cpuset platform pull_policy profiles expose links external_links sysctls group_add stop_grace_period ' +
        'stop_signal ipc pid runtime device_cgroup_rules gpus mac_address oom_score_adj oom_kill_disable pids_limit userns_mode ' +
        'cgroup cgroup_parent configs secrets blkio_config storage_opt isolation credential_spec annotations attach develop ' +
        'label_file post_start pre_stop scale volumes_from extends use_api_socket models provider uts').Split(' ')) {
    $script:KnownServiceKeys[$k] = $true
}
# Settings whose contents are a plain list or name=value pairs, so a service
# setting indented inside one of them is a spacing mistake.
$script:FlatKeys = @{}
foreach ($k in 'environment labels ports volumes depends_on env_file command entrypoint devices cap_add cap_drop extra_hosts dns tmpfs expose links security_opt group_add profiles sysctls'.Split(' ')) {
    $script:FlatKeys[$k] = $true
}

function Read-EnvFile([string]$Path) {
    $vars = @{}
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    foreach ($l in [IO.File]::ReadAllLines($Path)) {
        if ($l -match '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
            $v = $Matches[2].Trim()
            if ($v.Length -ge 2 -and $v[0] -eq $v[-1] -and ($v[0] -eq '"' -or $v[0] -eq "'")) { $v = $v.Substring(1, $v.Length - 2) }
            $vars[$Matches[1]] = $v
        }
    }
    return $vars
}

function Resolve-ComposeVars([string]$Text, [hashtable]$Vars) {
    $script:CheckVars = $Vars
    return [regex]::Replace($Text, '\$\{([A-Za-z_][A-Za-z0-9_]*)(:?[-?][^}]*)?\}|\$([A-Za-z_][A-Za-z0-9_]*)', {
            param($m)
            $n = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[3].Value }
            if ($script:CheckVars -and $script:CheckVars.ContainsKey($n)) { return $script:CheckVars[$n] }
            $e = [Environment]::GetEnvironmentVariable($n)
            if ($null -ne $e) { return $e }
            if ($m.Groups[2].Success) { return ($m.Groups[2].Value -replace '^:?[-?]', '') }
            return ''
        })
}

function Remove-YamlComment([string]$Text) {
    $q = [char]0
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        if ($q -ne [char]0) { if ($c -eq $q) { $q = [char]0 } }
        elseif ($c -eq '"' -or $c -eq "'") { $q = $c }
        elseif ($c -eq '#' -and ($i -eq 0 -or $Text[$i - 1] -eq ' ')) { return $Text.Substring(0, $i).TrimEnd() }
    }
    return $Text
}

function Get-Unquoted([string]$Text) {
    $t = $Text.Trim()
    if ($t.Length -ge 2 -and $t[0] -eq $t[-1] -and ($t[0] -eq '"' -or $t[0] -eq "'")) { return $t.Substring(1, $t.Length - 2) }
    return $t
}

function New-ServiceInfo([string]$Name, [int]$Line) {
    return @{
        Name = $Name; Line = $Line; Image = $null; ImageLine = 0; ContainerName = $null; NameLine = 0; Build = $false
        Ports = New-Object System.Collections.ArrayList; Deps = New-Object System.Collections.ArrayList
        Volumes = New-Object System.Collections.ArrayList; Labels = @{}
    }
}

function Test-ComposeFile([string]$Path, [string]$Prefix = 'home') {
    $found = New-Object System.Collections.Generic.List[Dcm.Finding]
    $add = {
        param([string]$Sev, [int]$Ln, [string]$Svc, [string]$Check, [string]$Msg)
        $f = New-Object Dcm.Finding
        $f.Severity = $Sev; $f.Line = $Ln; $f.Service = $Svc; $f.Check = $Check; $f.Message = $Msg
        $found.Add($f)
    }
    $envPath = Join-Path (Split-Path -Parent $Path) '.env'
    $vars = Read-EnvFile $envPath
    $hasEnv = $null -ne $vars
    if (-not $hasEnv) { $vars = @{} }
    $groupLabel = "$Prefix.group"
    $lines = [IO.File]::ReadAllLines($Path)

    $all = New-Object System.Collections.ArrayList      # every service block, duplicates too
    $byName = @{}
    $svc = ''; $info = $null
    $inServices = $false; $servicesIndent = -1; $keyIndent = -1; $curKey = ''
    $seenKeys = @{}
    $stack = New-Object System.Collections.ArrayList    # @(indent, key)

    for ($n = 0; $n -lt $lines.Length; $n++) {
        $i = $n + 1
        $raw = $lines[$n]
        if ($raw.Trim() -eq '') { continue }
        $lead = ([regex]::Match($raw, '^[ \t]*')).Value
        if ($lead.Contains("`t")) {
            & $add 'Error' $i $svc 'Spacing' 'Tab used for indenting. YAML only allows spaces here.'
            continue
        }
        $isComment = $raw.TrimStart().StartsWith('#')
        if ($raw.Contains("`t") -and -not $isComment) {
            & $add 'Warning' $i $svc 'Spacing' 'Tab in the line. Use spaces so every tool reads it the same way.'
        }
        if ($raw -ne $raw.TrimEnd()) { & $add 'Info' $i $svc 'Spacing' 'Spaces at the end of the line.' }
        if ($isComment) { continue }
        $line = Remove-YamlComment ($raw.Replace("`t", '  ').TrimEnd())
        if ($line.Trim() -eq '') { continue }
        $ind = $line.Length - $line.TrimStart(' ').Length
        $body = $line.Trim()
        if ($ind % 2 -eq 1) {
            & $add 'Warning' $i $svc 'Spacing' ("Indented by {0} spaces, not a multiple of 2. Check it lines up with the lines around it." -f $ind)
        }

        # --- ${...} variables ---
        foreach ($m in [regex]::Matches($body, '\$\{([^}]*)(\}|$)')) {
            $inner = $m.Groups[1].Value
            if ($m.Groups[2].Value -eq '') { & $add 'Error' $i $svc 'Variables' ("'`${{{0}' has no closing '}}'." -f $inner) }
            elseif ($inner.Trim() -eq '') { & $add 'Error' $i $svc 'Variables' "Empty '`${}'." }
            elseif ($inner -notmatch '^[A-Za-z_][A-Za-z0-9_]*(:?[-?+].*)?$') { & $add 'Error' $i $svc 'Variables' ("'`${{{0}}}' isn't a valid variable name." -f $inner) }
        }
        foreach ($m in [regex]::Matches($body, '(?<![\$\{\w])\$([A-Za-z_][A-Za-z0-9_]*)\}')) {
            & $add 'Error' $i $svc 'Variables' ("'`${0}}}' is missing its opening '{{'. Did you mean '`${{{0}}}'?" -f $m.Groups[1].Value)
        }
        foreach ($m in [regex]::Matches($body, '(?<![\$\w])\{([A-Z_][A-Z0-9_]*)\}')) {
            & $add 'Error' $i $svc 'Variables' ("'{{{0}}}' is missing its '`$'. Did you mean '`${{{0}}}'?" -f $m.Groups[1].Value)
        }
        if ($hasEnv) {
            foreach ($m in [regex]::Matches($body, '(?<!\$)\$\{([A-Za-z_][A-Za-z0-9_]*)(:?[-?+][^}]*)?\}|(?<!\$)\$([A-Za-z_][A-Za-z0-9_]*)')) {
                $vn = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[3].Value }
                if (-not $m.Groups[2].Success -and -not $vars.ContainsKey($vn) -and $null -eq [Environment]::GetEnvironmentVariable($vn)) {
                    & $add 'Warning' $i $svc 'Variables' ("'{0}' isn't set in .env, so it becomes empty." -f $vn)
                }
            }
        }

        # --- missing space after '-' or ':' ---
        if ($body -match '^-[^\s-]') { & $add 'Warning' $i $svc 'Spacing' "No space after '-'. YAML reads this as text, not a list item." }
        $km = [regex]::Match($body, '^(-\s+)?([A-Za-z_][\w.\-]*):(\S)')
        if ($km.Success -and $body -notmatch '^(-\s+)?[A-Za-z_][\w.\-]*:\d' -and $km.Groups[3].Value -ne '/') {
            $insideList = $script:FlatKeys.ContainsKey($curKey) -and $ind -gt $keyIndent
            if (-not $km.Groups[1].Success -and -not $insideList) {
                & $add 'Warning' $i $svc 'Spacing' ("No space after '{0}:'. YAML reads the whole line as text." -f $km.Groups[2].Value)
            }
        }

        # --- structure ---
        $m = [regex]::Match($body, '^(-\s+)?([^\s:#][^:#]*?|"[^"]*"|''[^'']*''):(\s|$)')
        $isKey = $m.Success -and -not $m.Groups[1].Success
        $key = if ($isKey) { Get-Unquoted $m.Groups[2].Value } else { '' }
        while ($stack.Count -and $stack[$stack.Count - 1][0] -ge $ind) { $stack.RemoveAt($stack.Count - 1) }
        $parent = if ($stack.Count) { $stack[$stack.Count - 1][1] } else { '' }
        if ($ind -eq 0) {
            $inServices = $key -eq 'services'
            $svc = ''; $info = $null; $curKey = ''
            if ($isKey) { [void]$stack.Add(@($ind, $key)) }
            continue
        }
        if (-not $inServices) { if ($isKey) { [void]$stack.Add(@($ind, $key)) }; continue }
        if ($servicesIndent -lt 0 -and $isKey) { $servicesIndent = $ind }
        if ($isKey -and $ind -eq $servicesIndent) {
            $svc = $key; $keyIndent = -1; $curKey = ''; $seenKeys = @{}
            if ($byName.ContainsKey($svc)) {
                & $add 'Error' $i $svc 'Services' ("Service '{0}' is defined twice (first on line {1})." -f $svc, $byName[$svc].Line)
            }
            $info = New-ServiceInfo $svc $i
            [void]$all.Add($info)
            if (-not $byName.ContainsKey($svc)) { $byName[$svc] = $info }
            [void]$stack.Add(@($ind, $key))
            continue
        }
        if ($ind -lt $servicesIndent) {
            if ($isKey) { & $add 'Error' $i $svc 'Spacing' ("'{0}:' is indented less than the services. Check its spacing." -f $key) }
            continue
        }
        if (-not $info) { continue }
        if ($keyIndent -lt 0 -and $isKey) { $keyIndent = $ind }
        if ($keyIndent -ge 0 -and $ind -lt $keyIndent) {
            & $add 'Error' $i $svc 'Spacing' ("Indented less than the other settings of '{0}'." -f $svc)
        }
        if ($isKey -and $ind -eq $keyIndent) {
            $curKey = $key
            if ($seenKeys.ContainsKey($key)) {
                & $add 'Error' $i $svc 'Services' ("'{0}:' appears twice in '{1}' (also line {2}). Only the last one counts." -f $key, $svc, $seenKeys[$key])
            }
            $seenKeys[$key] = $i
            $val = Get-Unquoted $body.Substring($m.Length)
            switch ($key) {
                'image' { $info.Image = $val; $info.ImageLine = $i }
                'container_name' { $info.ContainerName = $val; $info.NameLine = $i }
                'build' { $info.Build = $true }
                default {
                    if (-not $script:KnownServiceKeys.ContainsKey($key) -and -not $key.StartsWith('x-')) {
                        & $add 'Warning' $i $svc 'Services' ("'{0}:' isn't a setting Docker Compose knows. Check the spelling." -f $key)
                    }
                }
            }
            [void]$stack.Add(@($ind, $key))
            continue
        }
        if ($isKey -and $ind -gt $keyIndent -and $script:KnownServiceKeys.ContainsKey($key) -and $script:FlatKeys.ContainsKey($parent) -and $key -ne 'environment') {
            & $add 'Error' $i $svc 'Spacing' ("'{0}:' is indented under '{1}:', so Docker treats it as part of {1}. Line it up with '{1}:'." -f $key, $parent)
        }
        if ($isKey) { [void]$stack.Add(@($ind, $key)) }

        # --- collect what the later checks need ---
        $item = $null
        $lm = [regex]::Match($body, '^-\s*(.*)$')
        if ($lm.Success) { $item = Get-Unquoted $lm.Groups[1].Value }
        switch ($curKey) {
            'ports' {
                if ($null -ne $item -and $item -notmatch '^(target|published|protocol|mode|host_ip|name|app_protocol)\s*:') { [void]$info.Ports.Add(@($item, $i)) }
                if ($body -match '^(-\s+)?published\s*:\s*(.+)$') { [void]$info.Ports.Add(@(((Get-Unquoted $Matches[2]) + ':0'), $i)) }
            }
            'depends_on' {
                if ($null -ne $item) { [void]$info.Deps.Add(@($item, $i)) }
                elseif ($isKey -and $ind -eq $keyIndent + 2) { [void]$info.Deps.Add(@($key, $i)) }
            }
            'volumes' {
                if ($null -ne $item -and $item.Contains(':')) { [void]$info.Volumes.Add(@($item, $i)) }
                if ($body -match '^(-\s+)?source\s*:\s*(.+)$') { [void]$info.Volumes.Add(@(((Get-Unquoted $Matches[2]) + ':/x'), $i)) }
            }
            'labels' {
                if ($null -ne $item) { $info.Labels[$item.Split('=')[0].Trim()] = $true }
                elseif ($isKey) { $info.Labels[$key] = $true }
            }
            'environment' {
                $ev = $null
                if ($null -ne $item -and $item.Contains('=')) { $ev = $item.Split('=', 2) }
                elseif ($isKey -and $ind -gt $keyIndent) { $ev = @($key, (Get-Unquoted $body.Substring($m.Length))) }
                if ($ev) {
                    $evName = $ev[0].Trim(); $evValue = $ev[1].Trim()
                    if ($evName -match '(PASSWORD|PASSWD|_PASS$|^PASS$|SECRET|TOKEN|API_?KEY|PRIVATE_KEY|CLAIM)' -and $evValue -and
                        -not $evValue.Contains('$') -and @('true', 'false', '0', '1', 'none', 'off', 'on') -notcontains $evValue.ToLower()) {
                        & $add 'Info' $i $svc 'Passwords' ("'{0}' has its value written in the file. Consider moving it to .env." -f $evName)
                    }
                }
            }
        }
    }

    # --- checks across services ---
    $ports = @{}; $names = @{}
    $composeDir = Split-Path -Parent $Path
    foreach ($s in $all) {
        $name = $s.Name
        if (-not $s.Image -and -not $s.Build) { & $add 'Error' $s.Line $name 'Services' ("'{0}' has no image: (and no build:)." -f $name) }
        if ($s.Image -and -not $s.Build) {
            $img = Resolve-ComposeVars $s.Image $vars
            $last = $img.Split('/')[-1]
            if (-not $img.Contains('@') -and (-not $last.Contains(':') -or $last.EndsWith(':latest'))) {
                & $add 'Info' $s.ImageLine $name 'Images' ("'{0}' has no fixed version, so Update always takes the newest." -f $s.Image)
            }
        }
        if ($s.ContainerName) {
            $c = $s.ContainerName
            if ($names.ContainsKey($c)) {
                & $add 'Error' $s.NameLine $name 'Services' ("container_name '{0}' is also used by '{1}' (line {2})." -f $c, $names[$c][0], $names[$c][1])
            } else { $names[$c] = @($name, $s.NameLine) }
        }
        foreach ($d in $s.Deps) {
            if (-not $byName.ContainsKey($d[0])) { & $add 'Error' $d[1] $name 'Services' ("depends_on names '{0}', but there's no service called that." -f $d[0]) }
        }
        if (-not $s.Labels.ContainsKey($groupLabel)) {
            & $add 'Info' $s.Line $name 'Groups' ("'{0}' has no {1} label, so it's listed under Ungrouped." -f $name, $groupLabel)
        }
        foreach ($p in $s.Ports) {
            $r = Resolve-ComposeVars $p[0] $vars
            $proto = 'tcp'
            $slash = $r.LastIndexOf('/')
            if ($slash -ge 0) { $proto = $r.Substring($slash + 1); $r = $r.Substring(0, $slash) }
            $parts = $r.Split(':')
            if ($parts.Length -lt 2) { continue }
            $hostPart = $parts[$parts.Length - 2]
            $ip = if ($parts.Length -ge 3) { $parts[$parts.Length - 3] } else { '0.0.0.0' }
            if (-not $hostPart) { continue }
            $range = $hostPart.Split('-')
            $lo = 0; $hi = 0
            if (-not [int]::TryParse($range[0], [ref]$lo) -or -not [int]::TryParse($range[-1], [ref]$hi)) {
                & $add 'Warning' $p[1] $name 'Ports' ("Port '{0}' doesn't look like host:container." -f $p[0]); continue
            }
            if ($hi - $lo -gt 1000) { $hi = $lo + 1000 }
            for ($hp = $lo; $hp -le $hi; $hp++) {
                $k = '{0}|{1}|{2}' -f $ip, $hp, $proto
                if ($ports.ContainsKey($k) -and $ports[$k][0] -ne $name) {
                    & $add 'Error' $p[1] $name 'Ports' ("Host port {0}/{1} is also used by '{2}' (line {3}). Only one of them can run." -f $hp, $proto, $ports[$k][0], $ports[$k][1])
                    break
                } elseif (-not $ports.ContainsKey($k)) { $ports[$k] = @($name, $p[1]) }
            }
        }
        foreach ($v in $s.Volumes) {
            if ($v[0] -notmatch '^([A-Za-z]:[\\/]|\.{1,2}[\\/]|\$)') { continue }
            $rv = Resolve-ComposeVars $v[0] $vars
            $hm = [regex]::Match($rv, '^([A-Za-z]:[\\/][^:]*|[^:]*)')
            $hostPath = $hm.Groups[1].Value
            if (-not $hostPath -or $hostPath.StartsWith('/') -or $hostPath -notmatch '^([A-Za-z]:[\\/]|\.{1,2}[\\/])') { continue }
            $full = if ($hostPath -match '^[A-Za-z]:') { $hostPath } else { Join-Path $composeDir $hostPath }
            if (-not (Test-Path -LiteralPath $full)) {
                & $add 'Info' $v[1] $name 'Folders' ("'{0}' doesn't exist on this PC. Docker creates it as an empty folder." -f $hostPath)
            }
        }
    }
    if (-not $hasEnv) { & $add 'Info' 0 '' 'Variables' "There's no .env next to the compose file, so variables weren't checked." }

    $order = @{ Error = 0; Warning = 1; Info = 2 }
    return @($found | Sort-Object @{ Expression = { $order[$_.Severity] } }, Line)
}

# ---------------------------------------------------------------------------
# Compose file choice
# ---------------------------------------------------------------------------
function Update-RecentList {
    $script:UpdatingRecent = $true
    try {
        $ui.CmbRecent.Items.Clear()
        foreach ($f in @($script:Settings.RecentFiles)) {
            $item = New-Object Windows.Controls.ComboBoxItem
            $item.Content = '{0}  ({1})' -f (Split-Path -Leaf (Split-Path -Parent $f)), $f
            $item.Tag = $f
            $item.ToolTip = $f
            [void]$ui.CmbRecent.Items.Add($item)
            if ($f -eq $script:ComposePath) { $ui.CmbRecent.SelectedItem = $item }
        }
        $ui.CmbRecent.Visibility = if ($ui.CmbRecent.Items.Count) { 'Visible' } else { 'Collapsed' }
    } finally {
        $script:UpdatingRecent = $false
    }
}

function Select-ComposeFile {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Title = 'Choose a Docker Compose file'
    $dlg.Filter = 'Compose files|docker-compose.yml;docker-compose.yaml;compose.yml;compose.yaml|YAML files (*.yml, *.yaml)|*.yml;*.yaml|All files (*.*)|*.*'
    if ($script:ComposeDir -and (Test-Path -LiteralPath $script:ComposeDir)) { $dlg.InitialDirectory = $script:ComposeDir }
    if ($dlg.ShowDialog($window)) { Set-ComposeFile $dlg.FileName }
}

function Set-ComposeFile([string]$Path) {
    if (-not $Path) { return }
    $full = [IO.Path]::GetFullPath($Path)
    foreach ($job in @($script:JobQueue.ToArray())) { Write-Activity "Cancelled (compose file changed): $($job.Label)" }
    $script:JobQueue.Clear()
    $script:ComposePath = $full
    $script:ComposeDir = Split-Path -Parent $full
    $script:Settings.ComposeFile = $full
    $script:Settings.RecentFiles = @(@($full) + @($script:Settings.RecentFiles | Where-Object { $_ -and $_ -ne $full }) | Select-Object -First 8)
    Save-Settings
    Update-RecentList
    $script:ConfigGen++
    $script:ProjectName = ''
    $script:ConfigLoaded = $false
    $script:ConfigError = ''
    $script:Rows.Clear()
    $script:RowIndex = @{}
    $script:FileStamp = Get-FileStamp
    $ui.TxtSubtitle.Text = $full
    Write-Activity "Compose file: $full"
    Request-ConfigLoad
}

function Get-FileStamp {
    if (-not $script:ComposePath) { return '' }
    $parts = foreach ($f in @($script:ComposePath, (Join-Path $script:ComposeDir '.env'))) {
        $i = Get-Item -LiteralPath $f -ErrorAction SilentlyContinue
        if ($i) { '{0}:{1}' -f $i.LastWriteTimeUtc.Ticks, $i.Length } else { '-' }
    }
    return ($parts -join '|')
}

# ---------------------------------------------------------------------------
# Reading the compose file
# ---------------------------------------------------------------------------
function Request-ConfigLoad {
    $script:ConfigWanted = $true
}

function Start-ConfigLoad {
    $script:ConfigWanted = $false
    if (-not $script:ComposePath -or -not (Test-Path -LiteralPath $script:ComposePath) -or -not $script:DockerExe) { Update-Banner; Update-View; return }
    if ($script:ConfigLoading) { $script:ConfigWanted = $true; return }
    $script:ConfigLoading = $true
    $script:LoadingGen = $script:ConfigGen
    Set-Status 'Reading the compose file...'
    if ($script:CheckForm) { Update-CheckWindow } else { Update-CheckBadge }
    # --no-env-resolution: a missing env_file on this machine shouldn't hide the whole list.
    Start-DockerCall -Compose -Arguments @('config', '--format', 'json', '--no-env-resolution') -OnDone {
        param($res)
        if ($script:LoadingGen -ne $script:ConfigGen) { $script:ConfigLoading = $false; $script:ConfigWanted = $true; return }
        if ($res.ExitCode -ne 0) {
            $script:ConfigLoading = $false
            $msg = Get-FirstLines $res.Error 4
            if (-not $msg) { $msg = "docker compose config exited with code $($res.ExitCode)." }
            if (Test-DockerDownMessage $msg) { $msg = "Docker couldn't be reached: $msg" }
            $script:ConfigError = $msg
            Write-Activity "Compose file problem: $msg"
            Update-Banner
            Update-View
            Set-Status 'The compose file has a problem.'
            return
        }
        $warnings = @(($res.Error -split "`r?`n") | Where-Object { $_ -match 'variable is not set|level=warning|WARN' } | Select-Object -Unique)
        foreach ($w in $warnings | Select-Object -First 10) { Write-Activity "Compose warning: $($w.Trim())" }
        try {
            $cfg = $res.Output | ConvertFrom-Json
        } catch {
            $script:ConfigLoading = $false
            $script:ConfigError = "Couldn't read docker compose's output: $($_.Exception.Message)"
            Update-Banner
            return
        }
        # Hashes tell which containers were made from an older version of their service.
        $script:PendingConfig = $cfg
        Start-DockerCall -Compose -Arguments @('config', '--hash', '*') -OnDone {
            param($hashRes)
            $hashes = @{}
            if ($hashRes.ExitCode -eq 0) {
                foreach ($line in ($hashRes.Output -split "`r?`n")) {
                    $p = $line.Trim() -split '\s+'
                    if ($p.Count -eq 2) { $hashes[$p[0]] = $p[1] }
                }
            }
            $script:ConfigLoading = $false
            $pending = $script:PendingConfig
            $script:PendingConfig = $null
            if ($script:LoadingGen -ne $script:ConfigGen) { $script:ConfigWanted = $true; return }
            Import-ComposeConfig $pending $hashes
        }
    }
}

function Get-PropValue($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Get-ServiceLabels($Service) {
    $labels = @{}
    $raw = Get-PropValue $Service 'labels'
    if ($null -eq $raw) { return $labels }
    if ($raw -is [array]) {
        foreach ($l in $raw) { $kv = ([string]$l).Split('=', 2); $labels[$kv[0]] = if ($kv.Count -gt 1) { $kv[1] } else { '' } }
    } else {
        foreach ($p in $raw.PSObject.Properties) { $labels[$p.Name] = [string]$p.Value }
    }
    return $labels
}

function Get-PortInfo($Service, [string]$UrlLabel) {
    $texts = New-Object System.Collections.Generic.List[string]
    $firstWeb = $null
    foreach ($p in @(Get-PropValue $Service 'ports')) {
        if ($null -eq $p) { continue }
        $target = [string](Get-PropValue $p 'target')
        $published = [string](Get-PropValue $p 'published')
        $proto = [string](Get-PropValue $p 'protocol')
        $suffix = if ($proto -and $proto -ne 'tcp') { "/$proto" } else { '' }
        if ($published) {
            $texts.Add("$published$suffix")
            if (-not $firstWeb -and (-not $proto -or $proto -eq 'tcp')) { $firstWeb = @{ Published = $published; Target = $target } }
        }
    }
    $url = ''
    if ($UrlLabel) {
        if ($UrlLabel -ne 'none') { $url = $UrlLabel }
    } elseif ($firstWeb) {
        $port = ($firstWeb.Published -split '-')[0]
        $scheme = if ($firstWeb.Target -eq '443' -or $port -eq '443') { 'https' } else { 'http' }
        $url = "${scheme}://localhost:$port"
    }
    $network = [string](Get-PropValue $Service 'network_mode')
    $text = if ($texts.Count) { ($texts -join ', ') } elseif ($network -eq 'host') { 'host network' } else { '' }
    if ($url -and -not $text) { $text = 'open' }
    return @{ Text = $text; Url = $url }
}

function Get-GroupSort([string]$Group) {
    if ($Group -eq $script:OrphanName) { return "2|$Group" }
    if ($Group -eq $script:UngroupedName) { return "1|$Group" }
    return "0|$Group"
}

function Import-ComposeConfig($Config, [hashtable]$Hashes) {
    $prefix = ([string]$script:Settings.LabelPrefix).Trim().TrimEnd('.')
    $oldProject = $script:ProjectName
    $script:ProjectName = [string](Get-PropValue $Config 'name')
    if ($oldProject -and $oldProject -ne $script:ProjectName) {
        $script:Rows.Clear(); $script:RowIndex = @{}
    }
    $script:ConfigError = ''
    $services = Get-PropValue $Config 'services'
    $seen = @{}
    $added = 0
    if ($services) {
        foreach ($prop in $services.PSObject.Properties) {
            $name = $prop.Name
            $svc = $prop.Value
            $seen[$name] = $true
            $labels = Get-ServiceLabels $svc
            $group = if ($labels.ContainsKey("$prefix.group") -and $labels["$prefix.group"].Trim()) { $labels["$prefix.group"].Trim() } else { $script:UngroupedName }
            $ports = Get-PortInfo $svc $(if ($labels.ContainsKey("$prefix.url")) { $labels["$prefix.url"].Trim() } else { '' })
            $image = [string](Get-PropValue $svc 'image')
            if (-not $image -and (Get-PropValue $svc 'build')) { $image = '(built from source)' }
            $row = $script:RowIndex[$name]
            if (-not $row) {
                $row = New-Object Dcm.Row
                $row.Service = $name
                $row.StateKey = 'none'
                $row.StateText = 'Not created'
                $script:RowIndex[$name] = $row
                $script:Rows.Add($row)
                $added++
            }
            $cn = [string](Get-PropValue $svc 'container_name')
            if ($cn -and -not $row.HasContainer) { $row.ContainerName = $cn }
            $row.InCompose = $true
            $row.Group = $group
            $row.GroupSort = Get-GroupSort $group
            $row.Image = $image
            $row.Ports = $ports.Text
            $row.Url = $ports.Url
            $row.Description = if ($labels.ContainsKey("$prefix.description")) { $labels["$prefix.description"] } else { '' }
            $row.ConfigHash = if ($Hashes.ContainsKey($name)) { $Hashes[$name] } else { '' }
            Update-RowNote $row
        }
    }
    foreach ($row in @($script:Rows)) {
        if ($seen.ContainsKey($row.Service)) { continue }
        if ($row.HasContainer) {
            $row.InCompose = $false
            $row.Group = $script:OrphanName
            $row.GroupSort = Get-GroupSort $script:OrphanName
            $row.ConfigHash = ''
            Update-RowNote $row
        } else {
            [void]$script:Rows.Remove($row)
            $script:RowIndex.Remove($row.Service)
        }
    }
    $first = -not $script:ConfigLoaded
    $script:ConfigLoaded = $true
    $count = @($script:Rows | Where-Object InCompose).Count
    $msg = "Read $count services from the compose file (project '$script:ProjectName')."
    if (-not $first -and $added) { $msg += " $added new." }
    Write-Activity $msg
    $ui.TxtSubtitle.Text = "$script:ComposePath   ·   project $script:ProjectName   ·   $count services"
    Update-Banner
    Update-Groups
    Update-View -Refilter
    $script:LastStatusSig = ''
    $script:NextPoll = [DateTime]::MinValue   # status straight away
}

# ---------------------------------------------------------------------------
# Live status (docker ps for this compose project)
# ---------------------------------------------------------------------------
$script:PsFormat = "{{.Label `"com.docker.compose.service`"}}`t{{.Label `"com.docker.compose.config-hash`"}}`t{{.State}}`t{{.Status}}`t{{.Names}}`t{{.Image}}`t{{.ID}}"

function Start-Poll {
    if ($script:PollRunning -or -not $script:ConfigLoaded -or -not $script:ProjectName) { return }
    $script:PollRunning = $true
    $script:PollProject = $script:ProjectName
    Start-DockerCall -Arguments @('ps', '-a', '--no-trunc', '--filter', "label=com.docker.compose.project=$script:ProjectName", '--format', $script:PsFormat) -OnDone {
        param($res)
        $script:PollRunning = $false
        $script:NextPoll = [DateTime]::Now.AddSeconds($(if ($window.IsVisible) { $script:Settings.RefreshSeconds } else { 30 }))
        if ($res.ExitCode -ne 0) {
            $msg = Get-FirstLines $res.Error 2
            if ($script:DockerState -ne 'down') { Write-Activity "Docker isn't responding: $msg" }
            $script:DockerState = 'down'
            Update-Banner
            Update-Groups
            Set-Status "Docker isn't running."
            return
        }
        # The compose file was switched while docker ps was running: ignore this answer.
        if (-not $script:ConfigLoaded -or $script:PollProject -ne $script:ProjectName) { $script:NextPoll = [DateTime]::MinValue; return }
        if ($script:DockerState -ne 'ok') {
            if ($script:DockerState -eq 'down') { Write-Activity 'Docker is running again.' }
            $script:DockerState = 'ok'
            Update-Banner
        }
        Import-Status $res.Output
    }
}

function Get-StateInfo([string]$State, [string]$Status) {
    $since = ''
    switch ($State) {
        'running' {
            $since = ($Status -replace '^Up\s+', '') -replace '\s*\(.*\)\s*$', ''
            if ($Status -match '\(unhealthy\)') { return @{ Key = 'bad'; Text = 'Unhealthy'; Since = $since; Running = $true; Problem = $true } }
            if ($Status -match '\(health: starting\)') { return @{ Key = 'warn'; Text = 'Starting'; Since = $since; Running = $true; Problem = $false } }
            if ($Status -match '\(healthy\)') { return @{ Key = 'ok'; Text = 'Healthy'; Since = $since; Running = $true; Problem = $false } }
            return @{ Key = 'ok'; Text = 'Running'; Since = $since; Running = $true; Problem = $false }
        }
        'exited' {
            $code = if ($Status -match 'Exited \((-?\d+)\)') { [int]$Matches[1] } else { 0 }
            $since = $Status -replace '^Exited \(-?\d+\)\s*', ''
            # 0 = clean exit, 137/143 = stopped by docker stop. Anything else is a crash.
            if ($code -in 0, 137, 143) { return @{ Key = 'off'; Text = 'Stopped'; Since = $since; Running = $false; Problem = $false } }
            return @{ Key = 'bad'; Text = "Exited ($code)"; Since = $since; Running = $false; Problem = $true }
        }
        'restarting' { return @{ Key = 'bad'; Text = 'Restarting'; Since = ($Status -replace '^Restarting \(-?\d+\)\s*', ''); Running = $false; Problem = $true } }
        'paused'     { return @{ Key = 'warn'; Text = 'Paused'; Since = ''; Running = $true; Problem = $false } }
        'created'    { return @{ Key = 'off'; Text = 'Created'; Since = ''; Running = $false; Problem = $false } }
        'dead'       { return @{ Key = 'bad'; Text = 'Dead'; Since = ''; Running = $false; Problem = $true } }
        'removing'   { return @{ Key = 'warn'; Text = 'Removing'; Since = ''; Running = $false; Problem = $false } }
    }
    return @{ Key = 'off'; Text = $State; Since = ''; Running = $false; Problem = $false }
}

function Update-RowNote([Dcm.Row]$Row) {
    $Row.Changed = ($Row.InCompose -and $Row.HasContainer -and $Row.ConfigHash -and $Row.RunningHash -and $Row.ConfigHash -ne $Row.RunningHash)
    if (-not $Row.InCompose) { $Row.Note = 'Removed from compose file' }
    elseif ($Row.Changed) { $Row.Note = 'Changed: recreate to apply' }
    else { $Row.Note = '' }
}

# A short summary of docker ps output that ignores the ticking uptime text.
function Get-StatusSignature([string]$Output) {
    $parts = foreach ($line in ($Output -split "`r?`n")) {
        $f = $line.Split("`t")
        if ($f.Count -lt 7) { continue }
        $health = if ($f[3] -match '\((healthy|unhealthy|health: starting|Paused)\)') { $Matches[1] } else { '' }
        $code = if ($f[3] -match '^\w+ \((-?\d+)\)') { $Matches[1] } else { '' }
        '{0}|{1}|{2}|{3}|{4}|{5}' -f $f[0], $f[1], $f[2], $health, $code, $f[4]
    }
    return ($parts -join "`n")
}

function Import-Status([string]$Output) {
    # Most checks find nothing new. Then only the time in the status bar changes,
    # which keeps the window free for clicks. Uptime text is refreshed once a minute.
    $now = [DateTime]::Now
    $sig = Get-StatusSignature $Output
    if ($sig -eq $script:LastStatusSig -and ($now - $script:LastFullStatus).TotalSeconds -lt 60) {
        $ui.TxtStatus.Text = $ui.TxtStatus.Text -replace 'updated \d\d:\d\d:\d\d$', ('updated ' + $now.ToString('HH:mm:ss'))
        return
    }
    $script:LastStatusSig = $sig
    $script:LastFullStatus = $now
    $found = @{}
    $membership = $false
    $stateChanged = $false
    foreach ($line in ($Output -split "`r?`n")) {
        if (-not $line.Trim()) { continue }
        $f = $line.Split("`t")
        if ($f.Count -lt 7) { continue }
        $svc = $f[0]
        if (-not $svc -or $found.ContainsKey($svc)) { continue }   # one row per service (scaled services show the first)
        $found[$svc] = $true
        $row = $script:RowIndex[$svc]
        if (-not $row) {
            # A container from this project whose service isn't in the file any more.
            $row = New-Object Dcm.Row
            $row.Service = $svc
            $row.InCompose = $false
            $row.Group = $script:OrphanName
            $row.GroupSort = Get-GroupSort $script:OrphanName
            $row.Image = $f[5]
            $script:RowIndex[$svc] = $row
            $script:Rows.Add($row)
            $membership = $true
        }
        $info = Get-StateInfo $f[2] $f[3]
        if ($row.State -ne $f[2] -or $row.StateText -ne $info.Text) { $stateChanged = $true }
        $row.HasContainer = $true
        $row.ContainerName = $f[4]
        $row.RunningHash = $f[1]
        $row.State = $f[2]
        $row.StateKey = $info.Key
        $row.StateText = $info.Text
        $row.Since = $info.Since
        $row.IsRunning = $info.Running
        $row.Problem = $info.Problem
        Update-RowNote $row
    }
    foreach ($row in @($script:Rows)) {
        if ($found.ContainsKey($row.Service)) { continue }
        if (-not $row.InCompose) {
            [void]$script:Rows.Remove($row); $script:RowIndex.Remove($row.Service); $membership = $true; continue
        }
        if ($row.HasContainer -or $row.StateKey -ne 'none') { $stateChanged = $true }
        $row.HasContainer = $false
        $row.RunningHash = ''
        $row.State = ''
        $row.StateKey = 'none'
        $row.StateText = 'Not created'
        $row.Since = ''
        $row.IsRunning = $false
        $row.Problem = $false
        Update-RowNote $row
    }
    Update-Groups
    if ($membership -or ($stateChanged -and $script:StateFilter -ne 'All')) { Update-View -Refilter } else { Update-View }
    $running = @($script:Rows | Where-Object IsRunning).Count
    Set-Status ('{0} of {1} running  ·  updated {2}' -f $running, $script:Rows.Count, (Get-Date).ToString('HH:mm:ss'))
}

# ---------------------------------------------------------------------------
# Groups pane and the filtered, grouped list
# ---------------------------------------------------------------------------
$script:SelectedGroupKey = '*'
$script:StateFilter = 'All'
$script:SearchText = ''

# Which group key a row belongs to: g:<name>, ~ungrouped or ~orphans.
function Get-RowGroupKey([Dcm.Row]$Row) {
    if (-not $Row.InCompose) { return '~orphans' }
    if ($Row.Group -eq $script:UngroupedName) { return '~ungrouped' }
    return 'g:' + $Row.Group
}

function Get-GroupRows([string]$Key) {
    if ($Key -eq '*') { return @($script:Rows) }
    return @($script:Rows | Where-Object { (Get-RowGroupKey $_) -eq $Key })
}

function Update-Groups {
    $wanted = New-Object System.Collections.Generic.List[object]
    $wanted.Add(@{ Key = '*'; Name = 'All containers'; Special = $false })
    $names = @($script:Rows | Where-Object { $_.InCompose -and $_.Group -ne $script:UngroupedName } | ForEach-Object Group | Sort-Object -Unique)
    foreach ($n in $names) { $wanted.Add(@{ Key = "g:$n"; Name = $n; Special = $false }) }
    if (@($script:Rows | Where-Object { $_.InCompose -and $_.Group -eq $script:UngroupedName }).Count) { $wanted.Add(@{ Key = '~ungrouped'; Name = $script:UngroupedName; Special = $true }) }
    if (@($script:Rows | Where-Object { -not $_.InCompose }).Count) { $wanted.Add(@{ Key = '~orphans'; Name = $script:OrphanName; Special = $true }) }

    $same = ($wanted.Count -eq $script:Groups.Count)
    if ($same) { for ($i = 0; $i -lt $wanted.Count; $i++) { if ($script:Groups[$i].Key -ne $wanted[$i].Key) { $same = $false; break } } }
    if (-not $same) {
        $script:UpdatingGroups = $true
        Write-Trace 'groups list rebuilt'
        try {
            $script:Groups.Clear()
            foreach ($w in $wanted) {
                $g = New-Object Dcm.GroupEntry
                $g.Key = $w.Key; $g.Name = $w.Name; $g.Special = $w.Special
                $script:Groups.Add($g)
            }
            $sel = @($script:Groups | Where-Object Key -eq $script:SelectedGroupKey)
            if (-not $sel.Count) { $script:SelectedGroupKey = '*'; $sel = @($script:Groups[0]) }
            $ui.LstGroups.SelectedItem = $sel[0]
        } finally {
            $script:UpdatingGroups = $false
        }
    }
    # Counts in one pass (this runs after every status check).
    $tally = @{}
    foreach ($g in $script:Groups) { $tally[$g.Key] = @{ Running = 0; Total = 0; Problem = $false } }
    if (-not $tally.ContainsKey('*')) { $tally['*'] = @{ Running = 0; Total = 0; Problem = $false } }
    foreach ($r in $script:Rows) {
        foreach ($k in '*', (Get-RowGroupKey $r)) {
            $t = $tally[$k]
            if (-not $t) { continue }
            $t.Total++
            if ($r.IsRunning) { $t.Running++ }
            if ($r.Problem) { $t.Problem = $true }
        }
    }
    foreach ($g in $script:Groups) {
        $t = $tally[$g.Key]
        $g.Counts = '{0}/{1}' -f $t.Running, $t.Total
        $g.Problem = $t.Problem
    }
    Update-GroupBar
}

function Update-GroupBar {
    $key = $script:SelectedGroupKey
    $entry = @($script:Groups | Where-Object Key -eq $key)
    $name = if ($entry.Count) { $entry[0].Name } else { 'All containers' }
    $rows = Get-GroupRows $key
    $running = @($rows | Where-Object IsRunning).Count
    $problems = @($rows | Where-Object Problem).Count
    $changed = @($rows | Where-Object Changed).Count
    $ui.TxtGroupName.Text = $name
    if (-not $script:ComposePath) { $ui.TxtGroupInfo.Text = 'No compose file chosen yet.' }
    elseif ($key -eq '~orphans') { $ui.TxtGroupInfo.Text = "$($rows.Count) container(s) left over from services that were taken out of the compose file." }
    else {
        $info = '{0} running, {1} stopped' -f $running, ($rows.Count - $running)
        if ($problems) { $info += ", $problems need a look" }
        if ($changed) { $info += ", $changed changed in the compose file" }
        $ui.TxtGroupInfo.Text = $info
    }
    $isOrphans = ($key -eq '~orphans')
    $all = ($key -eq '*')
    $ui.BtnGroupStart.Content = if ($all) { 'Start all' } else { 'Start group' }
    $ui.BtnGroupStop.Content = if ($all) { 'Stop all' } else { 'Stop group' }
    $ui.BtnGroupUpdate.Content = if ($all) { 'Update all' } else { 'Update group' }
    foreach ($b in $ui.BtnGroupStart, $ui.BtnGroupUpdate) { $b.Visibility = if ($isOrphans) { 'Collapsed' } else { 'Visible' }; $b.IsEnabled = ($rows.Count -gt 0) }
    $ui.BtnGroupStop.IsEnabled = ($running -gt 0)
    $ui.BtnRemoveOrphans.Visibility = if ($isOrphans) { 'Visible' } else { 'Collapsed' }
    $allChanged = @($script:Rows | Where-Object Changed).Count
    if ($allChanged) {
        $ui.BtnApply.Content = "Apply changes ($allChanged)"
        $ui.BtnApply.Visibility = 'Visible'
    } else {
        $ui.BtnApply.Visibility = 'Collapsed'
    }
}

$script:View = [Windows.Data.CollectionViewSource]::GetDefaultView($script:Rows)
$script:View.SortDescriptions.Add((New-Object ComponentModel.SortDescription('GroupSort', 'Ascending')))
$script:View.SortDescriptions.Add((New-Object ComponentModel.SortDescription('Service', 'Ascending')))
$script:View.Filter = [Predicate[object]] {
    param($r)
    $key = $script:SelectedGroupKey
    if ($key -ne '*' -and (Get-RowGroupKey $r) -ne $key) { return $false }
    switch ($script:StateFilter) {
        'Running'  { if (-not $r.IsRunning) { return $false } }
        'Stopped'  { if ($r.IsRunning) { return $false } }
        'Problems' { if (-not $r.Problem) { return $false } }
        'Changed'  { if (-not $r.Changed) { return $false } }
    }
    $q = $script:SearchText
    if ($q) {
        $hay = '{0} {1} {2} {3} {4} {5}' -f $r.Service, $r.Image, $r.Group, $r.Ports, $r.StateText, $r.Description
        if ($hay.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
    }
    return $true
}
$script:GroupDescription = New-Object Windows.Data.PropertyGroupDescription('Group')

function Update-View([switch]$Refilter) {
    $wantGroups = ($script:SelectedGroupKey -eq '*')
    $hasGroups = ($script:View.GroupDescriptions.Count -gt 0)
    if ($wantGroups -ne $hasGroups) {
        if ($wantGroups) { $script:View.GroupDescriptions.Add($script:GroupDescription) } else { $script:View.GroupDescriptions.Clear() }
        $Refilter = $true
    }
    if ($Refilter) {
        $keep = @($ui.Grid.SelectedItems)
        Write-Trace "view refresh (group $script:SelectedGroupKey, keeping $($keep.Count) selected)"
        $script:View.Refresh()
        foreach ($r in $keep) { if ($script:Rows.Contains($r) -and $script:View.Contains($r)) { [void]$ui.Grid.SelectedItems.Add($r) } }
    }
    $shown = @($script:View).Count
    if (-not $script:ComposePath) {
        $ui.TxtEmpty.Text = 'Choose a docker-compose.yml to see its containers here.'
        $ui.TxtEmpty.Visibility = 'Visible'
    } elseif (-not $script:ConfigLoaded) {
        $ui.TxtEmpty.Text = if ($script:ConfigError) { 'The compose file could not be read. See the message at the top.' } else { 'Reading the compose file...' }
        $ui.TxtEmpty.Visibility = 'Visible'
    } elseif ($shown -eq 0) {
        $ui.TxtEmpty.Text = 'Nothing matches the search or filter.'
        $ui.TxtEmpty.Visibility = 'Visible'
    } else {
        $ui.TxtEmpty.Visibility = 'Collapsed'
    }
    Update-SelectionButtons
}

function Get-SelectedRows { return @($ui.Grid.SelectedItems | Where-Object { $_ -is [Dcm.Row] }) }

function Update-SelectionButtons {
    $sel = Get-SelectedRows
    $any = ($sel.Count -gt 0)
    $inCompose = @($sel | Where-Object InCompose).Count
    $withContainer = @($sel | Where-Object HasContainer).Count
    $ui.BtnStart.IsEnabled = $any
    $ui.BtnStop.IsEnabled = (@($sel | Where-Object IsRunning).Count -gt 0)
    $ui.BtnRestart.IsEnabled = ($withContainer -gt 0)
    $ui.BtnUpdate.IsEnabled = ($inCompose -gt 0)
    $ui.BtnLogs.IsEnabled = ($sel.Count -eq 1 -and $sel[0].HasContainer)
    $ui.BtnOpen.IsEnabled = ($sel.Count -eq 1 -and $sel[0].HasUrl)
}

# ---------------------------------------------------------------------------
# Actions. Each job is a list of docker commands run one after another; jobs
# queue up and run one at a time, with their output in the activity log.
# ---------------------------------------------------------------------------
function Add-Job([string]$Label, [object[]]$Steps) {
    $steps = @($Steps | Where-Object { $_ })
    if (-not $steps.Count) { return }
    if (-not $script:DockerExe) { [void][Windows.MessageBox]::Show($window, "docker.exe wasn't found, so nothing can be started.", $script:AppName, 'OK', 'Warning'); return }
    $script:JobQueue.Enqueue(@{ Label = $Label; Steps = $steps; Index = 0; Runner = $null; Failed = $false })
    $script:Timer.Interval = [TimeSpan]::FromMilliseconds(200)
    Update-BusyState
    Update-Jobs
}

function New-ComposeStep([string[]]$Arguments, [switch]$AllowFail) {
    return @{ Args = @(Get-ComposeArguments) + $Arguments; AllowFail = [bool]$AllowFail }
}

function New-DockerStep([string[]]$Arguments, [switch]$AllowFail) {
    return @{ Args = $Arguments; AllowFail = [bool]$AllowFail }
}

function Update-Jobs {
    $job = $script:CurrentJob
    if ($job) {
        $r = $job.Runner
        $line = $null
        $n = 0
        while ($n -lt 400 -and $r.Lines.TryDequeue([ref]$line)) { Write-Activity ('    ' + $line) -Plain; $n++ }
        if (-not $r.IsDone -or -not $r.Lines.IsEmpty) { return }
        $step = $job.Steps[$job.Index]
        if ($r.ExitCode -ne 0 -and -not $step.AllowFail) {
            $job.Failed = $true
            Write-Activity "Failed (exit code $($r.ExitCode)): $($job.Label)"
            Complete-Job $job
            return
        }
        $job.Index++
        if ($job.Index -ge $job.Steps.Count) { Write-Activity "Done: $($job.Label)"; Complete-Job $job; return }
        Start-JobStep $job
        return
    }
    if ($script:JobQueue.Count -gt 0) {
        $job = $script:JobQueue.Dequeue()
        $script:CurrentJob = $job
        Write-Activity "$($job.Label)..."
        Start-JobStep $job
        Update-BusyState
    }
}

function Start-JobStep($Job) {
    $step = $Job.Steps[$Job.Index]
    try {
        $Job.Runner = New-Object Dcm.Runner($script:DockerExe, [string[]]$step.Args, $script:ComposeDir, $false)
        Write-Activity ('  > ' + (Get-ShortCommand $Job.Runner.CommandLine)) -Plain
    } catch {
        $Job.Failed = $true
        Write-Activity "Couldn't start docker: $($_.Exception.Message)"
        Complete-Job $Job
    }
}

# Hides the -f/--project-directory noise in the log.
function Get-ShortCommand([string]$CommandLine) {
    return ($CommandLine -replace ' --ansi never --progress plain', '' -replace ' -f ("[^"]+"|\S+) --project-directory ("[^"]+"|\S+)', '')
}

function Complete-Job($Job) {
    $script:CurrentJob = $null
    Update-BusyState
    $script:NextPoll = [DateTime]::MinValue
    if (-not $window.IsVisible -and $script:Tray) {
        $icon = if ($Job.Failed) { [Windows.Forms.ToolTipIcon]::Error } else { [Windows.Forms.ToolTipIcon]::Info }
        $text = if ($Job.Failed) { "Failed: $($Job.Label)" } else { "Done: $($Job.Label)" }
        $script:Tray.ShowBalloonTip(4000, $script:AppName, $text, $icon)
    }
}

function Stop-CurrentJob {
    $job = $script:CurrentJob
    if (-not $job) { return }
    $job.Runner.Kill()
    $job.Index = $job.Steps.Count
    Write-Activity "Cancelled: $($job.Label)"
    $job.Failed = $true
    Complete-Job $job
    foreach ($q in @($script:JobQueue.ToArray())) { Write-Activity "Cancelled: $($q.Label)" }
    $script:JobQueue.Clear()
}

function Update-BusyState {
    $busy = ($null -ne $script:CurrentJob)
    $ui.PrgBusy.Visibility = if ($busy) { 'Visible' } else { 'Collapsed' }
    $ui.BtnCancel.Visibility = if ($busy) { 'Visible' } else { 'Collapsed' }
    $waiting = $script:JobQueue.Count
    $ui.TxtBusy.Text = if ($busy) { $script:CurrentJob.Label + $(if ($waiting) { "  (+$waiting waiting)" } else { '' }) } else { '' }
}

function Format-Names([object[]]$Rows, [int]$Max = 4) {
    $names = @($Rows | ForEach-Object Service)
    if ($names.Count -le $Max) { return ($names -join ', ') }
    return ('{0} and {1} more' -f (($names | Select-Object -First $Max) -join ', '), ($names.Count - $Max))
}

function Confirm-Action([string]$Text) {
    return ([Windows.MessageBox]::Show($window, $Text, $script:AppName, 'YesNo', 'Question') -eq 'Yes')
}

function Invoke-Start([object[]]$Rows, [string]$Label) {
    $svc = @($Rows | Where-Object InCompose | ForEach-Object Service)
    $orph = @($Rows | Where-Object { -not $_.InCompose -and $_.HasContainer -and -not $_.IsRunning } | ForEach-Object ContainerName)
    if (-not $Label) { $Label = 'Start ' + (Format-Names $Rows) }
    $steps = @()
    if ($svc.Count) { $steps += New-ComposeStep (@('up', '-d') + $svc) }
    if ($orph.Count) { $steps += New-DockerStep (@('start') + $orph) }
    Add-Job $Label $steps
}

function Invoke-Stop([object[]]$Rows, [string]$Label) {
    $running = @($Rows | Where-Object IsRunning)
    if (-not $running.Count) { return }
    $svc = @($running | Where-Object InCompose | ForEach-Object Service)
    $orph = @($running | Where-Object { -not $_.InCompose } | ForEach-Object ContainerName)
    if (-not $Label) { $Label = 'Stop ' + (Format-Names $running) }
    $steps = @()
    if ($svc.Count) { $steps += New-ComposeStep (@('stop') + $svc) }
    if ($orph.Count) { $steps += New-DockerStep (@('stop') + $orph) }
    Add-Job $Label $steps
}

function Invoke-Restart([object[]]$Rows) {
    $have = @($Rows | Where-Object HasContainer)
    if (-not $have.Count) { return }
    $svc = @($have | Where-Object InCompose | ForEach-Object Service)
    $orph = @($have | Where-Object { -not $_.InCompose } | ForEach-Object ContainerName)
    $steps = @()
    if ($svc.Count) { $steps += New-ComposeStep (@('restart') + $svc) }
    if ($orph.Count) { $steps += New-DockerStep (@('restart') + $orph) }
    Add-Job ('Restart ' + (Format-Names $have)) $steps
}

# Recreates services without changing whether they run: running ones with
# "up -d", the rest with "up --no-start" (made fresh, left stopped).
function Get-RecreateSteps([object[]]$Rows, [switch]$Force) {
    $extra = if ($Force) { @('--force-recreate') } else { @() }
    $run = @($Rows | Where-Object { $_.InCompose -and $_.IsRunning } | ForEach-Object Service)
    $idle = @($Rows | Where-Object { $_.InCompose -and -not $_.IsRunning -and $_.HasContainer } | ForEach-Object Service)
    $steps = @()
    if ($run.Count) { $steps += New-ComposeStep (@('up', '-d', '--no-deps') + $extra + $run) }
    if ($idle.Count) { $steps += New-ComposeStep (@('up', '--no-start', '--no-deps') + $extra + $idle) }
    return $steps
}

function Invoke-Update([object[]]$Rows, [string]$Label) {
    $rows = @($Rows | Where-Object InCompose)
    if (-not $rows.Count) { return }
    if (-not $Label) { $Label = 'Update ' + (Format-Names $rows) }
    $steps = @(New-ComposeStep (@('pull', '--ignore-buildable') + @($rows | ForEach-Object Service)))
    $steps += Get-RecreateSteps $rows
    if ($script:Settings.PruneAfterUpdate) { $steps += New-DockerStep @('image', 'prune', '-f') -AllowFail }
    Add-Job $Label $steps
}

function Invoke-Recreate([object[]]$Rows) {
    $rows = @($Rows | Where-Object { $_.InCompose -and $_.HasContainer })
    if (-not $rows.Count) { return }
    if (-not (Confirm-Action ("Recreate {0}?`n`nEach container is removed and made again from the compose file. Data in volumes and host folders is kept." -f (Format-Names $rows 8)))) { return }
    Add-Job ('Recreate ' + (Format-Names $rows)) (Get-RecreateSteps $rows -Force)
}

function Invoke-ApplyChanges {
    $rows = @($script:Rows | Where-Object Changed)
    if (-not $rows.Count) { return }
    $msg = "Recreate {0} container(s) so they pick up the changes in the compose file?`n`n{1}`n`nRunning ones are restarted; stopped ones stay stopped. Data in volumes and host folders is kept." -f $rows.Count, (Format-Names $rows 12)
    if (-not (Confirm-Action $msg)) { return }
    Add-Job ("Apply changes to " + (Format-Names $rows)) (Get-RecreateSteps $rows)
}

function Invoke-Remove([object[]]$Rows) {
    $rows = @($Rows | Where-Object HasContainer)
    if (-not $rows.Count) { return }
    $msg = "Remove {0}?`n`nThe container is stopped and deleted. Its image, volumes and data folders are kept" -f (Format-Names $rows 8)
    if (@($rows | Where-Object InCompose).Count) { $msg += ', and Start makes it again from the compose file' }
    if (-not (Confirm-Action ($msg + '.'))) { return }
    Add-Job ('Remove ' + (Format-Names $rows)) @(New-DockerStep (@('rm', '-f') + @($rows | ForEach-Object ContainerName)))
}

function Invoke-GroupAction([string]$What) {
    $key = $script:SelectedGroupKey
    $rows = Get-GroupRows $key
    $entry = @($script:Groups | Where-Object Key -eq $key)
    $name = if ($key -eq '*') { 'all containers' } elseif ($entry.Count) { $entry[0].Name } else { 'group' }
    switch ($What) {
        'start' {
            $todo = @($rows | Where-Object { -not $_.IsRunning })
            if (-not $todo.Count) { Set-Status "Everything in $name is already running."; return }
            if ($key -eq '*' -and -not (Confirm-Action "Start all $($todo.Count) containers that aren't running?")) { return }
            Invoke-Start $todo "Start $name"
        }
        'stop' {
            $todo = @($rows | Where-Object IsRunning)
            if (-not $todo.Count) { return }
            if (($script:Settings.ConfirmGroupStop -or $key -eq '*') -and -not (Confirm-Action "Stop the $($todo.Count) running container(s) in $name?")) { return }
            Invoke-Stop $todo "Stop $name"
        }
        'update' {
            $todo = @($rows | Where-Object InCompose)
            if (-not $todo.Count) { return }
            if (-not (Confirm-Action "Pull the newest images for the $($todo.Count) container(s) in $name and recreate the ones that changed?`n`nRunning ones are restarted on the new image; stopped ones stay stopped.")) { return }
            Invoke-Update $todo "Update $name"
        }
        'remove' { Invoke-Remove $rows }
    }
}

function Open-Url([string]$Url) {
    if (-not $Url) { return }
    if ($Url -notmatch '^(?i)https?://') { Set-Status "Not a web address: $Url"; return }
    try { Start-Process -FilePath $Url } catch { Set-Status "Couldn't open $Url" }
}

# ---------------------------------------------------------------------------
# Check window
# ---------------------------------------------------------------------------
$checkXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Check compose file" Width="1000" Height="620" MinWidth="640" MinHeight="320" WindowStartupLocation="CenterOwner"
        FontFamily="Segoe UI" FontSize="13" Background="{DynamicResource Page}" Foreground="{DynamicResource Ink}">
    <Window.Resources><!--SHARED--></Window.Resources>
    <DockPanel Margin="12">
        <Grid DockPanel.Dock="Top" Margin="0,0,0,8">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <StackPanel>
                <TextBlock x:Name="TxtCheckTitle" FontSize="15" FontWeight="SemiBold"/>
                <TextBlock x:Name="TxtCheckFile" Foreground="{StaticResource SoftInk}" FontSize="12" TextTrimming="CharacterEllipsis" Margin="0,2,0,6"/>
                <StackPanel Orientation="Horizontal">
                    <CheckBox x:Name="ChkErrors" IsChecked="True" VerticalAlignment="Center" Margin="0,0,14,0" ToolTip="Mistakes that stop a container or the whole file from working"/>
                    <CheckBox x:Name="ChkWarnings" IsChecked="True" VerticalAlignment="Center" Margin="0,0,14,0" ToolTip="Things that are probably wrong"/>
                    <CheckBox x:Name="ChkInfo" IsChecked="False" VerticalAlignment="Center" ToolTip="Tidying up and suggestions"/>
                </StackPanel>
            </StackPanel>
            <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Bottom">
                <Button x:Name="BtnCheckAgain" Content="Check again" Tag="&#xE72C;" Style="{StaticResource Btn}"/>
                <Button x:Name="BtnCheckOpen" Content="Open at line" Tag="&#xE70F;" Style="{StaticResource Btn}"/>
                <Button x:Name="BtnCheckCopy" Content="Copy" Tag="&#xE8C8;" Style="{StaticResource Btn}" Margin="0"/>
            </StackPanel>
        </Grid>
        <TextBlock DockPanel.Dock="Bottom" Foreground="{StaticResource SoftInk}" Margin="2,6,0,0"
                   Text="Double-click a line to open the compose file at that line. The check reads the file as text, so it also works when Docker rejects the file."/>
        <Border Background="{StaticResource Card}" BorderBrush="{StaticResource Edge}" BorderThickness="1" CornerRadius="8" Padding="2">
            <Grid>
                <DataGrid x:Name="GridFindings" AutoGenerateColumns="False" IsReadOnly="True" HeadersVisibility="Column"
                          GridLinesVisibility="None" BorderThickness="0" Background="Transparent" RowBackground="Transparent"
                          SelectionMode="Extended" SelectionUnit="FullRow" CanUserAddRows="False" RowHeight="28">
                    <DataGrid.RowStyle>
                        <Style TargetType="DataGridRow">
                            <Setter Property="BorderThickness" Value="4,0,0,0"/>
                            <Setter Property="BorderBrush" Value="Transparent"/>
                            <Style.Triggers>
                                <Trigger Property="IsMouseOver" Value="True">
                                    <Setter Property="Background" Value="#F3F7FC"/>
                                </Trigger>
                                <Trigger Property="IsSelected" Value="True">
                                    <Setter Property="Background" Value="#BFD9F7"/>
                                    <Setter Property="BorderBrush" Value="{DynamicResource Accent}"/>
                                    <Setter Property="FontWeight" Value="Bold"/>
                                </Trigger>
                            </Style.Triggers>
                        </Style>
                    </DataGrid.RowStyle>
                    <DataGrid.CellStyle>
                        <Style TargetType="DataGridCell">
                            <Setter Property="BorderThickness" Value="0"/>
                            <Setter Property="Foreground" Value="{DynamicResource Ink}"/>
                            <Setter Property="Template">
                                <Setter.Value>
                                    <ControlTemplate TargetType="DataGridCell">
                                        <Border Padding="8,0" Background="Transparent">
                                            <ContentPresenter VerticalAlignment="Center"/>
                                        </Border>
                                    </ControlTemplate>
                                </Setter.Value>
                            </Setter>
                        </Style>
                    </DataGrid.CellStyle>
                    <DataGrid.Columns>
                        <DataGridTemplateColumn Header="Severity" Width="100" SortMemberPath="Order">
                            <DataGridTemplateColumn.CellTemplate>
                                <DataTemplate>
                                    <StackPanel Orientation="Horizontal">
                                        <Ellipse x:Name="Dot" Width="9" Height="9" Margin="0,0,7,0" Fill="{DynamicResource Off}"/>
                                        <TextBlock Text="{Binding Severity}"/>
                                    </StackPanel>
                                    <DataTemplate.Triggers>
                                        <DataTrigger Binding="{Binding Severity}" Value="Error">
                                            <Setter TargetName="Dot" Property="Fill" Value="{DynamicResource Bad}"/>
                                        </DataTrigger>
                                        <DataTrigger Binding="{Binding Severity}" Value="Warning">
                                            <Setter TargetName="Dot" Property="Fill" Value="{DynamicResource Warn}"/>
                                        </DataTrigger>
                                        <DataTrigger Binding="{Binding Severity}" Value="Info">
                                            <Setter TargetName="Dot" Property="Fill" Value="{DynamicResource Accent}"/>
                                        </DataTrigger>
                                    </DataTemplate.Triggers>
                                </DataTemplate>
                            </DataGridTemplateColumn.CellTemplate>
                        </DataGridTemplateColumn>
                        <DataGridTextColumn Header="Line" Binding="{Binding LineText}" SortMemberPath="Line" Width="60"/>
                        <DataGridTextColumn Header="Service" Binding="{Binding Service}" Width="170"/>
                        <DataGridTextColumn Header="Check" Binding="{Binding Check}" Width="90"/>
                        <DataGridTextColumn Header="Problem" Binding="{Binding Message}" Width="*"/>
                    </DataGrid.Columns>
                </DataGrid>
                <TextBlock x:Name="TxtCheckEmpty" HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="{StaticResource SoftInk}"
                           FontSize="14" Visibility="Collapsed"/>
            </Grid>
        </Border>
    </DockPanel>
</Window>
'@

function Invoke-ComposeCheck {
    if (-not $script:ComposePath -or -not (Test-Path -LiteralPath $script:ComposePath)) { return @() }
    try {
        return @(Test-ComposeFile -Path $script:ComposePath -Prefix ([string]$script:Settings.LabelPrefix))
    } catch {
        Write-Activity "Compose check failed: $($_.Exception.Message)"
        return @()
    }
}

function Update-CheckBadge([object[]]$Findings) {
    if ($null -eq $Findings) { $Findings = Invoke-ComposeCheck }
    $errors = @($Findings | Where-Object { $_.Severity -eq 'Error' }).Count
    $warnings = @($Findings | Where-Object { $_.Severity -eq 'Warning' }).Count
    $ui.BtnCheck.Content = if ($errors + $warnings) { 'Check ({0})' -f ($errors + $warnings) } else { 'Check' }
    $ui.BtnCheck.ToolTip = if ($errors + $warnings) {
        'Check the compose file: {0} error(s) and {1} warning(s) found' -f $errors, $warnings
    } else { 'Check the compose file for spacing, ${...} variables, port clashes and other mistakes' }
}

function Update-CheckWindow {
    $c = $script:CheckForm
    if (-not $c) { return }
    $c.All = Invoke-ComposeCheck
    $e = @($c.All | Where-Object { $_.Severity -eq 'Error' }).Count
    $w = @($c.All | Where-Object { $_.Severity -eq 'Warning' }).Count
    $i = @($c.All | Where-Object { $_.Severity -eq 'Info' }).Count
    $c.ChkErrors.Content = "Errors ($e)"
    $c.ChkWarnings.Content = "Warnings ($w)"
    $c.ChkInfo.Content = "Suggestions ($i)"
    $c.Title.Text = if ($e + $w -eq 0) { 'No errors or warnings found' } else { '{0} error(s) and {1} warning(s) found' -f $e, $w }
    $c.File.Text = '{0}   ·   checked {1}' -f $script:ComposePath, (Get-Date).ToString('HH:mm:ss')
    Update-CheckBadge $c.All
    Show-CheckFindings
}

function Show-CheckFindings {
    $c = $script:CheckForm
    if (-not $c) { return }
    $keep = @{ Error = [bool]$c.ChkErrors.IsChecked; Warning = [bool]$c.ChkWarnings.IsChecked; Info = [bool]$c.ChkInfo.IsChecked }
    $shown = @($c.All | Where-Object { $keep[$_.Severity] })
    $c.Grid.ItemsSource = $shown
    $c.Empty.Text = if (@($c.All).Count -eq 0) { 'Nothing to report. The compose file looks good.' } else { 'Nothing to show. Tick Suggestions to see them.' }
    $c.Empty.Visibility = if ($shown.Count) { 'Collapsed' } else { 'Visible' }
}

function Open-CheckFinding {
    $c = $script:CheckForm
    if (-not $c) { return }
    $f = $c.Grid.SelectedItem
    if ($f -is [Dcm.Finding]) { Open-InEditor $script:ComposePath $f.Line }
}

function Show-Check {
    if (-not $script:ComposePath) { return }
    if ($script:CheckForm) { $script:CheckForm.Window.Activate(); Update-CheckWindow; return }
    $w = New-XamlObject $checkXaml
    $w.Owner = $window
    if ($window.Icon) { $w.Icon = $window.Icon }
    $script:CheckForm = @{
        Window = $w; All = @()
        Title = $w.FindName('TxtCheckTitle'); File = $w.FindName('TxtCheckFile'); Grid = $w.FindName('GridFindings'); Empty = $w.FindName('TxtCheckEmpty')
        ChkErrors = $w.FindName('ChkErrors'); ChkWarnings = $w.FindName('ChkWarnings'); ChkInfo = $w.FindName('ChkInfo')
    }
    foreach ($n in 'ChkErrors', 'ChkWarnings', 'ChkInfo') { $script:CheckForm[$n].Add_Click({ Show-CheckFindings }) }
    $w.FindName('BtnCheckAgain').Add_Click({ Update-CheckWindow })
    $w.FindName('BtnCheckOpen').Add_Click({ Open-CheckFinding })
    $w.FindName('BtnCheckCopy').Add_Click({
            $items = @($script:CheckForm.Grid.SelectedItems)
            if (-not $items.Count) { $items = @($script:CheckForm.Grid.ItemsSource) }
            $text = ($items | ForEach-Object { "{0}`tline {1}`t{2}`t{3}`t{4}" -f $_.Severity, $_.Line, $_.Service, $_.Check, $_.Message }) -join "`r`n"
            if ($text) { [Windows.Clipboard]::SetText($text) }
        })
    $script:CheckForm.Grid.Add_MouseDoubleClick({
            param($src, $e)
            try {
                $dep = $e.OriginalSource
                while ($dep -and -not ($dep -is [Windows.Controls.DataGridRow])) {
                    $dep = if ($dep -is [Windows.Media.Visual]) { [Windows.Media.VisualTreeHelper]::GetParent($dep) } else { [Windows.LogicalTreeHelper]::GetParent($dep) }
                }
                if ($dep) { Open-CheckFinding }
            } catch { Write-Activity "Check window: $($_.Exception.Message)" }
        })
    $w.Add_KeyDown({
            param($src, $e)
            if ($e.Key -eq 'Escape') { $src.Close() }
            elseif ($e.Key -eq 'Enter') { Open-CheckFinding; $e.Handled = $true }
            elseif ($e.Key -eq 'F5') { Update-CheckWindow; $e.Handled = $true }
        })
    $w.Add_Closed({ $script:CheckForm = $null })
    $w.Show()
    Update-CheckWindow
}

# ---------------------------------------------------------------------------
# Logs window (one per container; several can be open)
# ---------------------------------------------------------------------------
$logsXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="980" Height="620" MinWidth="600" MinHeight="300" WindowStartupLocation="CenterOwner"
        FontFamily="Segoe UI" FontSize="13" Background="{DynamicResource Page}" Foreground="{DynamicResource Ink}">
    <Window.Resources><!--SHARED--></Window.Resources>
    <DockPanel Margin="12">
        <Grid DockPanel.Dock="Top" Margin="0,0,0,8">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                <TextBlock Text="Last" VerticalAlignment="Center" Margin="0,0,6,0"/>
                <ComboBox x:Name="CmbTail" Width="80" Margin="0,0,12,0"/>
                <CheckBox x:Name="ChkFollow" Content="Follow" VerticalAlignment="Center" Margin="0,0,12,0" IsChecked="True"
                          ToolTip="Keep adding new lines as the container writes them"/>
                <CheckBox x:Name="ChkTimes" Content="Timestamps" VerticalAlignment="Center" Margin="0,0,12,0"/>
                <CheckBox x:Name="ChkWrap" Content="Wrap" VerticalAlignment="Center" Margin="0,0,12,0"/>
            </StackPanel>
            <Grid Grid.Column="1" MaxWidth="320" HorizontalAlignment="Left">
                <TextBox x:Name="TxtFind" Style="{StaticResource Field}" Padding="26,4,6,4" ToolTip="Show only lines containing this text (Ctrl+F)"/>
                <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE721;" Foreground="{StaticResource SoftInk}" Margin="8,0,0,0"
                           VerticalAlignment="Center" IsHitTestVisible="False"/>
            </Grid>
            <StackPanel Grid.Column="2" Orientation="Horizontal">
                <Button x:Name="BtnReload" Content="Reload" Tag="&#xE72C;" Style="{StaticResource Btn}"/>
                <Button x:Name="BtnCopy" Content="Copy" Tag="&#xE8C8;" Style="{StaticResource Btn}"/>
                <Button x:Name="BtnSave" Content="Save..." Tag="&#xE74E;" Style="{StaticResource Btn}" Margin="0"/>
            </StackPanel>
        </Grid>
        <TextBlock x:Name="TxtInfo" DockPanel.Dock="Bottom" Foreground="{StaticResource SoftInk}" Margin="2,6,0,0"/>
        <Border Background="{StaticResource Navy}" CornerRadius="8" Padding="8">
            <TextBox x:Name="TxtLines" IsReadOnly="True" BorderThickness="0" Background="Transparent" Foreground="#E3ECF7"
                     FontFamily="Consolas" FontSize="12" TextWrapping="NoWrap"
                     VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
        </Border>
    </DockPanel>
</Window>
'@

function Show-Logs([Dcm.Row]$Row) {
    if (-not $Row -or -not $Row.HasContainer) { return }
    foreach ($open in @($script:LogWindows)) {
        if ($open.Service -eq $Row.Service) { $open.Window.Activate(); return }
    }
    $w = New-XamlObject $logsXaml
    $w.Owner = $window
    if ($window.Icon) { $w.Icon = $window.Icon }
    $w.Title = "Logs: $($Row.Service)"
    $state = @{
        Window = $w; Service = $Row.Service; Container = $Row.ContainerName; InCompose = $Row.InCompose
        Runner = $null; Lines = New-Object System.Collections.Generic.List[string]; Find = ''
        Tail = $w.FindName('CmbTail'); Follow = $w.FindName('ChkFollow'); Times = $w.FindName('ChkTimes')
        Wrap = $w.FindName('ChkWrap'); Text = $w.FindName('TxtLines'); FindBox = $w.FindName('TxtFind'); Info = $w.FindName('TxtInfo')
    }
    foreach ($n in '100', '300', '1000', '5000', 'All') { [void]$state.Tail.Items.Add($n) }
    $state.Tail.SelectedItem = '300'
    [void]$script:LogWindows.Add($state)

    # Every control carries the window's state in DataContext, so the handlers
    # (plain script blocks) can find it without closures.
    $w.DataContext = $state
    $restart = { $s = $this.DataContext; if ($s) { Start-LogStream $s } }
    $state.Tail.Add_SelectionChanged($restart)
    $state.Follow.Add_Click($restart)
    $state.Times.Add_Click($restart)
    $state.Wrap.Add_Click({ $s = $this.DataContext; $s.Text.TextWrapping = if ($s.Wrap.IsChecked) { 'Wrap' } else { 'NoWrap' } })
    $state.FindBox.Add_TextChanged({ $s = $this.DataContext; $s.Find = $s.FindBox.Text.Trim(); Show-LogLines $s })
    $w.FindName('BtnReload').Add_Click($restart)
    $w.FindName('BtnCopy').Add_Click({ $s = $this.DataContext; if ($s.Text.Text) { [Windows.Clipboard]::SetText($s.Text.Text) } })
    $w.FindName('BtnSave').Add_Click({
            $s = $this.DataContext
            $dlg = New-Object Microsoft.Win32.SaveFileDialog
            $dlg.FileName = '{0}-{1}.log' -f $s.Service, (Get-Date).ToString('yyyyMMdd-HHmmss')
            $dlg.Filter = 'Log files (*.log)|*.log|Text files (*.txt)|*.txt'
            if ($dlg.ShowDialog($s.Window)) {
                try { [IO.File]::WriteAllLines($dlg.FileName, $s.Lines.ToArray()) }
                catch { [void][Windows.MessageBox]::Show($s.Window, $_.Exception.Message, $script:AppName) }
            }
        })
    $w.Add_Closed({
            $s = $this.DataContext
            if ($s.Runner) { $s.Runner.Kill() }
            $script:LogWindows.Remove($s)
        })
    $w.Add_KeyDown({
            param($src, $e)
            if ($e.Key -eq 'Escape') { $src.Close() }
            elseif ($e.Key -eq 'F' -and [Windows.Input.Keyboard]::Modifiers -eq 'Control') { [void]$src.DataContext.FindBox.Focus(); $e.Handled = $true }
        })
    $w.Show()
    Start-LogStream $state
}

function Start-LogStream($State) {
    if ($State.Runner) { $State.Runner.Kill(); $State.Runner = $null }
    $State.Lines.Clear()
    $State.Text.Clear()
    $tail = [string]$State.Tail.SelectedItem
    if ($tail -eq 'All') { $tail = 'all' }
    $opts = @('--tail', $tail)
    if ($State.Times.IsChecked) { $opts += '--timestamps' }
    if ($State.Follow.IsChecked) { $opts += '--follow' }
    if ($State.InCompose) { $cmd = @(Get-ComposeArguments) + @('logs', '--no-color', '--no-log-prefix') + $opts + @($State.Service) }
    else { $cmd = @('logs') + $opts + @($State.Container) }
    try {
        $State.Runner = New-Object Dcm.Runner($script:DockerExe, [string[]]$cmd, $script:ComposeDir, $false)
        $State.Info.Text = 'Loading...'
    } catch {
        $State.Info.Text = "Couldn't read the logs: $($_.Exception.Message)"
    }
}

function Show-LogLines($State) {
    $q = $State.Find
    $lines = if ($q) { @($State.Lines | Where-Object { $_.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0 }) } else { $State.Lines.ToArray() }
    $State.Text.Text = ($lines -join "`r`n")
    $State.Text.ScrollToEnd()
    Update-LogInfo $State
}

function Update-LogInfo($State) {
    $shown = if ($State.Find) { "  ·  showing lines with '$($State.Find)'" } else { '' }
    $live = if ($State.Runner -and -not $State.Runner.IsDone) { '  ·  following' } else { '' }
    $State.Info.Text = '{0} lines{1}{2}' -f $State.Lines.Count, $live, $shown
}

function Update-LogWindows {
    foreach ($s in @($script:LogWindows)) {
        $r = $s.Runner
        if (-not $r) { continue }
        $line = $null
        $new = New-Object System.Collections.Generic.List[string]
        while ($new.Count -lt 2000 -and $r.Lines.TryDequeue([ref]$line)) { $new.Add($line) }
        if ($new.Count) {
            $s.Lines.AddRange($new)
            if ($s.Lines.Count -gt 50000) { $s.Lines.RemoveRange(0, $s.Lines.Count - 40000); Show-LogLines $s; continue }
            $box = $s.Text
            $atEnd = ($box.VerticalOffset + $box.ViewportHeight) -ge ($box.ExtentHeight - 4)
            $add = if ($s.Find) { @($new | Where-Object { $_.IndexOf($s.Find, [StringComparison]::OrdinalIgnoreCase) -ge 0 }) } else { $new.ToArray() }
            if ($add.Count) {
                $prefix = if ($box.Text.Length) { "`r`n" } else { '' }
                $box.AppendText($prefix + ($add -join "`r`n"))
                if ($atEnd) { $box.ScrollToEnd() }
            }
            Update-LogInfo $s
        } elseif ($r.IsDone -and $r.Lines.IsEmpty) {
            $s.Runner = $null
            if ($r.ExitCode -ne 0 -and -not $s.Lines.Count) { $s.Info.Text = 'docker logs failed: ' + (Get-FirstLines $r.Error 2) }
            else { Update-LogInfo $s }
        }
    }
}

# ---------------------------------------------------------------------------
# Settings window
# ---------------------------------------------------------------------------
$settingsXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Settings" Width="580" SizeToContent="Height" ResizeMode="NoResize" WindowStartupLocation="CenterOwner"
        FontFamily="Segoe UI" FontSize="13" Background="{DynamicResource Page}" Foreground="{DynamicResource Ink}">
    <Window.Resources><!--SHARED--></Window.Resources>
    <StackPanel Margin="18">
        <TextBlock Text="Settings" FontSize="18" FontWeight="SemiBold" Margin="0,0,0,12"/>
        <Border Background="{StaticResource Card}" BorderBrush="{StaticResource Edge}" BorderThickness="1" CornerRadius="8" Padding="14">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="160"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <TextBlock Text="Label prefix" Margin="0,5,0,10"/>
                <StackPanel Grid.Column="1" Margin="0,0,0,10">
                    <TextBox x:Name="TxtPrefix" Style="{StaticResource Field}"/>
                    <TextBlock x:Name="TxtPrefixHelp" Foreground="{StaticResource SoftInk}" FontSize="12" TextWrapping="Wrap" Margin="0,4,0,0"/>
                </StackPanel>
                <TextBlock Grid.Row="1" Text="Check status every" VerticalAlignment="Center" Margin="0,0,0,10"/>
                <StackPanel Grid.Row="1" Grid.Column="1" Orientation="Horizontal" Margin="0,0,0,10">
                    <TextBox x:Name="TxtRefresh" Style="{StaticResource Field}" Width="60"/>
                    <TextBlock Text="seconds (2 to 300)" VerticalAlignment="Center" Margin="8,0,0,0" Foreground="{StaticResource SoftInk}"/>
                </StackPanel>
                <TextBlock Grid.Row="2" Text="Editor" VerticalAlignment="Center" Margin="0,0,0,10"/>
                <Grid Grid.Row="2" Grid.Column="1" Margin="0,0,0,10">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <TextBox x:Name="TxtEditor" Style="{StaticResource Field}" ToolTip="Visual Studio Code by default. Leave empty, or point at a missing program, to use Notepad"/>
                    <Button x:Name="BtnEditor" Grid.Column="1" Content="Browse..." Style="{StaticResource Btn}" Margin="6,0,0,0"/>
                </Grid>
                <CheckBox x:Name="ChkPrune" Grid.Row="3" Grid.ColumnSpan="2" Margin="0,0,0,8"
                          Content="After Update, remove images nothing uses any more (docker image prune)"/>
                <CheckBox x:Name="ChkConfirm" Grid.Row="4" Grid.ColumnSpan="2" Margin="0,0,0,8" Content="Ask before stopping a group"/>
                <CheckBox x:Name="ChkTray" Grid.Row="5" Grid.ColumnSpan="2" Content="Minimise to the notification area (tray)"/>
            </Grid>
        </Border>
        <TextBlock x:Name="TxtWhere" Foreground="{StaticResource SoftInk}" FontSize="12" TextWrapping="Wrap" Margin="2,10,0,0"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
            <Button x:Name="BtnSaveSettings" Content="Save" Tag="&#xE74E;" Style="{StaticResource PrimaryBtn}" IsDefault="True"/>
            <Button x:Name="BtnCancelSettings" Content="Cancel" Style="{StaticResource Btn}" IsCancel="True" Margin="0"/>
        </StackPanel>
    </StackPanel>
</Window>
'@

function Update-PrefixHelp {
    $p = $script:SettingsForm.TxtPrefix.Text.Trim().TrimEnd('.')
    if (-not $p) { $p = 'home' }
    $script:SettingsForm.TxtPrefixHelp.Text = "Groups come from the $p.group label. $p.url sets a container's web page ($p.url=none hides it) and $p.description its tooltip."
}

function Show-Settings {
    $w = New-XamlObject $settingsXaml
    $w.Owner = $window
    if ($window.Icon) { $w.Icon = $window.Icon }
    $f = @{ Window = $w; Saved = $false }
    foreach ($n in 'TxtPrefix', 'TxtPrefixHelp', 'TxtRefresh', 'TxtEditor', 'BtnEditor', 'ChkPrune', 'ChkConfirm', 'ChkTray', 'TxtWhere', 'BtnSaveSettings') { $f[$n] = $w.FindName($n) }
    $script:SettingsForm = $f
    $f.TxtPrefix.Text = $script:Settings.LabelPrefix
    $f.TxtRefresh.Text = [string]$script:Settings.RefreshSeconds
    $f.TxtEditor.Text = $script:Settings.Editor
    $f.ChkPrune.IsChecked = [bool]$script:Settings.PruneAfterUpdate
    $f.ChkConfirm.IsChecked = [bool]$script:Settings.ConfirmGroupStop
    $f.ChkTray.IsChecked = [bool]$script:Settings.MinimiseToTray
    $f.TxtWhere.Text = "Saved in $script:SettingsPath"
    Update-PrefixHelp
    $f.TxtPrefix.Add_TextChanged({ Update-PrefixHelp })
    $f.BtnEditor.Add_Click({
            $dlg = New-Object Microsoft.Win32.OpenFileDialog
            $dlg.Filter = 'Programs (*.exe)|*.exe'
            if ($dlg.ShowDialog($script:SettingsForm.Window)) { $script:SettingsForm.TxtEditor.Text = $dlg.FileName }
        })
    $f.BtnSaveSettings.Add_Click({
            $f = $script:SettingsForm
            $sec = 0
            if (-not [int]::TryParse($f.TxtRefresh.Text.Trim(), [ref]$sec) -or $sec -lt 2 -or $sec -gt 300) {
                [void][Windows.MessageBox]::Show($f.Window, 'Check status every: enter a number of seconds from 2 to 300.', 'Settings', 'OK', 'Warning'); return
            }
            $prefix = $f.TxtPrefix.Text.Trim().TrimEnd('.')
            if ($prefix -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
                [void][Windows.MessageBox]::Show($f.Window, 'Label prefix: use letters, numbers, dots, dashes or underscores, for example home.', 'Settings', 'OK', 'Warning'); return
            }
            $editor = $f.TxtEditor.Text.Trim().Trim('"')
            if ($editor -and -not (Test-Path -LiteralPath $editor -PathType Leaf)) {
                [void][Windows.MessageBox]::Show($f.Window, "Editor: there's no program at $editor. Leave it empty to use Notepad.", 'Settings', 'OK', 'Warning'); return
            }
            $prefixChanged = ($prefix -ne $script:Settings.LabelPrefix)
            $script:Settings.LabelPrefix = $prefix
            $script:Settings.RefreshSeconds = $sec
            $script:Settings.Editor = $editor
            $script:Settings.PruneAfterUpdate = [bool]$f.ChkPrune.IsChecked
            $script:Settings.ConfirmGroupStop = [bool]$f.ChkConfirm.IsChecked
            $script:Settings.MinimiseToTray = [bool]$f.ChkTray.IsChecked
            Save-Settings
            $script:NextPoll = [DateTime]::Now.AddSeconds($sec)
            if ($prefixChanged) { Request-ConfigLoad }
            $f.Window.Close()
        })
    [void]$w.ShowDialog()
    $script:SettingsForm = $null
}

# ---------------------------------------------------------------------------
# About window
# ---------------------------------------------------------------------------
$script:WhatsNew = [ordered]@{
    '1.00' = @(
        'Lists every service in your compose file with live status, web page, image and uptime.',
        'Groups from a label in the compose file (home.group), with Start, Stop and Update for a whole group.',
        'Start, stop, restart, update and recreate one container or a selection.',
        'Spots new, removed and changed services whenever the compose file or .env is saved.',
        'Logs window with follow, search, copy and save.',
        'Tray icon with quick start and stop for each group.'
    )
}

$aboutXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="580" SizeToContent="Height" ResizeMode="NoResize" WindowStartupLocation="CenterOwner"
        FontFamily="Segoe UI" FontSize="13" Background="{DynamicResource Page}" Foreground="{DynamicResource Ink}">
    <Window.Resources><!--SHARED--></Window.Resources>
    <StackPanel>
        <Border Padding="20,16">
            <Border.Background>
                <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                    <GradientStop Color="#0E2238" Offset="0"/>
                    <GradientStop Color="#1769C2" Offset="1"/>
                </LinearGradientBrush>
            </Border.Background>
            <StackPanel Orientation="Horizontal">
                <Image x:Name="AboutLogo" Width="72" Height="72" Margin="0,0,16,0" RenderOptions.BitmapScalingMode="HighQuality"/>
                <StackPanel VerticalAlignment="Center">
                    <TextBlock x:Name="AboutName" FontSize="22" FontWeight="SemiBold" Foreground="#FFFFFF"/>
                    <TextBlock x:Name="AboutVersion" Foreground="#CFE0F5" Margin="0,2,0,0"/>
                </StackPanel>
            </StackPanel>
        </Border>
        <StackPanel Margin="20,14,20,0">
            <TextBlock Text="Run and organise the containers in a Docker Compose file." TextWrapping="Wrap"/>
            <TextBlock Text="What's new" FontWeight="SemiBold" Margin="0,14,0,4"/>
            <StackPanel x:Name="AboutNew"/>
            <TextBlock Text="This PC" FontWeight="SemiBold" Margin="0,14,0,4"/>
            <TextBlock x:Name="AboutDocker" Foreground="{StaticResource SoftInk}" TextWrapping="Wrap"/>
            <TextBlock x:Name="AboutPaths" Foreground="{StaticResource SoftInk}" TextWrapping="Wrap" Margin="0,2,0,0"/>
            <TextBlock Text="Keys" FontWeight="SemiBold" Margin="0,14,0,4"/>
            <TextBlock Foreground="{StaticResource SoftInk}" TextWrapping="Wrap"
                       Text="F5 refresh  ·  Ctrl+F search  ·  Ctrl+L logs  ·  Enter open web page  ·  Ctrl+A select all  ·  double-click a container to open its web page (or its logs if it has none)"/>
        </StackPanel>
        <Grid Margin="20,16,20,18">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <StackPanel VerticalAlignment="Center">
                <Button x:Name="AboutRepo" Style="{StaticResource LinkBtn}" HorizontalAlignment="Left"/>
                <TextBlock x:Name="AboutCopyright" Foreground="{StaticResource SoftInk}" FontSize="12" Margin="0,3,0,0"/>
            </StackPanel>
            <Button x:Name="AboutClose" Grid.Column="1" Content="Close" Style="{StaticResource PrimaryBtn}" IsCancel="True" IsDefault="True" Margin="0"/>
        </Grid>
    </StackPanel>
</Window>
'@

function Show-About {
    $w = New-XamlObject $aboutXaml
    $w.Owner = $window
    if ($window.Icon) { $w.Icon = $window.Icon }
    $w.Title = "About $script:AppName"
    $w.FindName('AboutLogo').Source = $ui.ImgLogo.Source
    $w.FindName('AboutName').Text = $script:AppName
    $w.FindName('AboutVersion').Text = "Version $script:AppVersion"
    $w.FindName('AboutCopyright').Text = 'Copyright (c) 2026 Jason Rhodes  ·  MIT licence'
    $repo = $w.FindName('AboutRepo')
    $repo.Content = $script:RepoUrl
    $repo.Add_Click({ Open-Url $script:RepoUrl })
    $w.FindName('AboutClose').Add_Click({ [Windows.Window]::GetWindow($this).Close() })
    $panel = $w.FindName('AboutNew')
    foreach ($v in $script:WhatsNew.Keys) {
        foreach ($item in $script:WhatsNew[$v]) {
            $t = New-Object Windows.Controls.TextBlock
            $t.Text = [string][char]0x2022 + '  ' + $item
            $t.TextWrapping = 'Wrap'
            $t.Margin = '0,1,0,1'
            [void]$panel.Children.Add($t)
        }
    }
    $script:AboutDockerText = $w.FindName('AboutDocker')
    $script:AboutDockerText.Text = if ($script:DockerExe) { 'Docker: checking...' } else { "Docker: docker.exe wasn't found." }
    $composeText = if ($script:ComposePath) { $script:ComposePath } else { 'none chosen' }
    $w.FindName('AboutPaths').Text = "Compose file: $composeText`nSettings: $script:SettingsPath"
    if ($script:DockerExe) {
        Start-DockerCall -Arguments @('version', '--format', '{{.Client.Version}}|{{.Server.Version}}') -OnDone {
            param($res)
            $parts = @($res.Output.Trim() -split '\|')
            $script:AboutClient = $parts[0]
            $script:AboutServer = if ($parts.Count -gt 1 -and $parts[1]) { $parts[1] } else { 'not running' }
            Start-DockerCall -Arguments @('compose', 'version', '--short') -OnDone {
                param($c)
                $compose = if ($c.ExitCode -eq 0) { $c.Output.Trim() } else { 'not found' }
                if ($script:AboutDockerText) { $script:AboutDockerText.Text = "Docker $script:AboutClient (engine $script:AboutServer)  ·  Compose $compose" }
            }
        }
    }
    [void]$w.ShowDialog()
    $script:AboutDockerText = $null
}

# ---------------------------------------------------------------------------
# Tray icon
# ---------------------------------------------------------------------------
function Show-MainWindow {
    $window.Show()
    if ($window.WindowState -eq 'Minimized') { $window.WindowState = if ($script:Settings.WindowMaximised) { 'Maximized' } else { 'Normal' } }
    [void]$window.Activate()
    $script:NextPoll = [DateTime]::MinValue
}

function Update-TrayMenu {
    $menu = $script:Tray.ContextMenuStrip
    $menu.Items.Clear()
    $open = $menu.Items.Add("Open $script:AppName")
    $open.Font = New-Object Drawing.Font($open.Font, [Drawing.FontStyle]::Bold)
    $open.Add_Click({ Show-MainWindow })
    [void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
    if ($script:ConfigLoaded -and $script:DockerState -eq 'ok') {
        foreach ($g in @($script:Groups | Where-Object { $_.Key -ne '~orphans' })) {
            $item = New-Object Windows.Forms.ToolStripMenuItem("$($g.Name)   $($g.Counts)")
            $start = $item.DropDownItems.Add('Start')
            $start.Tag = $g.Key
            $start.Add_Click({ $script:SelectedGroupKeyForTray = $this.Tag; Invoke-TrayGroup 'start' })
            $stop = $item.DropDownItems.Add('Stop')
            $stop.Tag = $g.Key
            $stop.Add_Click({ $script:SelectedGroupKeyForTray = $this.Tag; Invoke-TrayGroup 'stop' })
            [void]$menu.Items.Add($item)
        }
    } else {
        $none = $menu.Items.Add($(if ($script:DockerState -eq 'down') { "Docker isn't running" } else { 'No containers yet' }))
        $none.Enabled = $false
    }
    [void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
    $exit = $menu.Items.Add('Exit')
    $exit.Add_Click({ $window.Close() })
}

function Invoke-TrayGroup([string]$What) {
    $key = $script:SelectedGroupKeyForTray
    $rows = Get-GroupRows $key
    $entry = @($script:Groups | Where-Object Key -eq $key)
    $name = if ($key -eq '*') { 'all containers' } elseif ($entry.Count) { $entry[0].Name } else { 'group' }
    if ($What -eq 'start') { Invoke-Start @($rows | Where-Object { -not $_.IsRunning }) "Start $name" }
    else { Invoke-Stop $rows "Stop $name" }
}

function New-Tray {
    $tray = New-Object Windows.Forms.NotifyIcon
    $tray.Icon = Get-TrayIcon
    $tray.Text = $script:AppName
    $tray.ContextMenuStrip = New-Object Windows.Forms.ContextMenuStrip
    $tray.Add_MouseDoubleClick({ Show-MainWindow })
    $tray.Add_MouseUp({ param($s, $e) if ($e.Button -eq 'Left') { Show-MainWindow } })
    $tray.ContextMenuStrip.Add_Opening({ Update-TrayMenu })
    $tray.Visible = $true
    return $tray
}

# ---------------------------------------------------------------------------
# Wiring up the main window
# ---------------------------------------------------------------------------
$ui.Grid.ItemsSource = $script:View
$ui.Grid.Add_PreviewMouseLeftButtonDown({
        param($s, $e)
        if ($script:Trace) { Write-Trace ("grid mouse down on {0}" -f $e.OriginalSource.GetType().Name) }
    })
$ui.LstGroups.ItemsSource = $script:Groups
foreach ($s in 'All', 'Running', 'Stopped', 'Problems', 'Changed') { [void]$ui.CmbState.Items.Add($s) }
$ui.CmbState.SelectedIndex = 0
$ui.ChkActivity.IsChecked = [bool]$script:Settings.ShowActivity

$logo = Get-ImageSource 'Docker-Container-Manager.png'
if ($logo) { $ui.ImgLogo.Source = $logo; $window.Icon = $logo }

function Set-ActivityVisible([bool]$Show) {
    if ($Show) {
        $ui.LogPane.Visibility = 'Visible'; $ui.LogSplitter.Visibility = 'Visible'
        if ($ui.LogRow.Height.Value -lt 60) { $ui.LogRow.Height = New-Object Windows.GridLength(170) }
    } else {
        $ui.LogPane.Visibility = 'Collapsed'; $ui.LogSplitter.Visibility = 'Collapsed'
        $ui.LogRow.Height = New-Object Windows.GridLength(0)
    }
}
Set-ActivityVisible ([bool]$script:Settings.ShowActivity)

$ui.ChkActivity.Add_Click({
        $script:Settings.ShowActivity = [bool]$ui.ChkActivity.IsChecked
        Set-ActivityVisible $script:Settings.ShowActivity
        Save-Settings
    })

$ui.BtnBrowse.Add_Click({ Select-ComposeFile })
$ui.CmbRecent.Add_SelectionChanged({
        if ($script:UpdatingRecent) { return }
        $item = $ui.CmbRecent.SelectedItem
        if ($item -and $item.Tag -and $item.Tag -ne $script:ComposePath) {
            if (Test-Path -LiteralPath $item.Tag) { Set-ComposeFile $item.Tag }
            else {
                [void][Windows.MessageBox]::Show($window, "That compose file isn't there any more:`n$($item.Tag)", $script:AppName, 'OK', 'Warning')
                $script:Settings.RecentFiles = @($script:Settings.RecentFiles | Where-Object { $_ -ne $item.Tag })
                Save-Settings
                Update-RecentList
            }
        }
    })
$ui.BtnEditCompose.Add_Click({ Open-InEditor $script:ComposePath })
$ui.BtnEditEnv.Add_Click({
        if (-not $script:ComposeDir) { return }
        $envFile = Join-Path $script:ComposeDir '.env'
        if (-not (Test-Path -LiteralPath $envFile)) {
            if (-not (Confirm-Action "There's no .env next to the compose file. Create an empty one?")) { return }
            try { [IO.File]::WriteAllText($envFile, '') } catch { [void][Windows.MessageBox]::Show($window, $_.Exception.Message, $script:AppName); return }
        }
        Open-InEditor $envFile
    })
$ui.BtnFolder.Add_Click({ if ($script:ComposeDir -and (Test-Path -LiteralPath $script:ComposeDir)) { Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$script:ComposeDir`"" } })
$ui.BtnCheck.Add_Click({ Show-Check })
$ui.BtnSettings.Add_Click({ Show-Settings })
$ui.BtnAbout.Add_Click({ Show-About })
$ui.BannerAction.Add_Click({ if ($script:BannerClick) { & $script:BannerClick } })
$ui.BannerRetry.Add_Click({
        $script:DockerExe = Find-Docker
        $script:DockerState = if ($script:DockerExe) { 'unknown' } else { 'missing' }
        Request-ConfigLoad
        $script:NextPoll = [DateTime]::MinValue
        Update-Banner
    })

$ui.LstGroups.Add_SelectionChanged({
        if ($script:UpdatingGroups) { return }
        $g = $ui.LstGroups.SelectedItem
        if (-not $g) { return }
        $script:SelectedGroupKey = $g.Key
        Write-Trace "group picked: $($g.Key)"
        $ui.Grid.UnselectAll()
        Update-GroupBar
        Update-View -Refilter
    })
$ui.CmbState.Add_SelectionChanged({ $script:StateFilter = [string]$ui.CmbState.SelectedItem; Update-View -Refilter })
$ui.TxtSearch.Add_TextChanged({
        $script:SearchText = $ui.TxtSearch.Text.Trim()
        $ui.SearchHint.Visibility = if ($ui.TxtSearch.Text) { 'Collapsed' } else { 'Visible' }
        Update-View -Refilter
    })
# Handlers that run inside the grid's own mouse and selection handling must not
# throw: an error there can leave the grid ignoring clicks.
$ui.Grid.Add_SelectionChanged({ try { Write-Trace "grid selection: $($ui.Grid.SelectedItems.Count) selected"; Update-SelectionButtons } catch { Write-Activity "Internal error (selection): $($_.Exception.Message)" } })

$ui.BtnStart.Add_Click({ Invoke-Start (Get-SelectedRows) })
$ui.BtnStop.Add_Click({ Invoke-Stop (Get-SelectedRows) })
$ui.BtnRestart.Add_Click({ Invoke-Restart (Get-SelectedRows) })
$ui.BtnUpdate.Add_Click({ Invoke-Update (Get-SelectedRows) })
$ui.BtnLogs.Add_Click({ $sel = Get-SelectedRows; if ($sel.Count -eq 1) { Show-Logs $sel[0] } })
$ui.BtnOpen.Add_Click({ $sel = Get-SelectedRows; if ($sel.Count -eq 1) { Open-Url $sel[0].Url } })
$ui.BtnApply.Add_Click({ Invoke-ApplyChanges })
$ui.BtnGroupStart.Add_Click({ Invoke-GroupAction 'start' })
$ui.BtnGroupStop.Add_Click({ Invoke-GroupAction 'stop' })
$ui.BtnGroupUpdate.Add_Click({ Invoke-GroupAction 'update' })
$ui.BtnRemoveOrphans.Add_Click({ Invoke-GroupAction 'remove' })
$ui.BtnRefresh.Add_Click({ Request-ConfigLoad; $script:NextPoll = [DateTime]::MinValue })
$ui.BtnCancel.Add_Click({ Stop-CurrentJob })
$ui.BtnLogClear.Add_Click({ $ui.TxtLog.Clear() })
$ui.BtnLogCopy.Add_Click({ if ($ui.TxtLog.Text) { [Windows.Clipboard]::SetText($ui.TxtLog.Text) } })

# The "web page" link in each row.
$ui.Grid.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent, [Windows.RoutedEventHandler] {
        param($s, $e)
        $src = $e.OriginalSource
        if ($src -is [Windows.Controls.Button] -and $src.Tag) {
            $e.Handled = $true
            try { Open-Url ([string]$src.Tag) } catch { Write-Activity "Internal error (link): $($_.Exception.Message)" }
        }
    })
$ui.Grid.Add_MouseDoubleClick({
        param($s, $e)
        try {
            $dep = $e.OriginalSource
            while ($dep -and -not ($dep -is [Windows.Controls.DataGridRow])) {
                if ($dep -is [Windows.Controls.Primitives.DataGridColumnHeader] -or $dep -is [Windows.Controls.Primitives.ScrollBar]) { return }
                $dep = if ($dep -is [Windows.Media.Visual]) { [Windows.Media.VisualTreeHelper]::GetParent($dep) } else { [Windows.LogicalTreeHelper]::GetParent($dep) }
            }
            if (-not $dep) { return }
            $row = $dep.Item
            if ($row -isnot [Dcm.Row]) { return }
            # Open after the click has finished, so the grid isn't mid-click when a window opens.
            $script:PendingOpen = $row
            [void]$window.Dispatcher.BeginInvoke([Action] {
                    $r = $script:PendingOpen; $script:PendingOpen = $null
                    if (-not $r) { return }
                    if ($r.HasUrl) { Open-Url $r.Url } elseif ($r.HasContainer) { Show-Logs $r }
                }, [Windows.Threading.DispatcherPriority]::Background)
        } catch {
            Write-Activity "Internal error (double-click): $($_.Exception.Message)"
        }
    })

# Context menu: enable what makes sense for the selection.
$ui.RowMenu.Add_Opened({
        $sel = Get-SelectedRows
        $ui.MnuStart.IsEnabled = ($sel.Count -gt 0)
        $ui.MnuStop.IsEnabled = (@($sel | Where-Object IsRunning).Count -gt 0)
        $ui.MnuRestart.IsEnabled = (@($sel | Where-Object HasContainer).Count -gt 0)
        $ui.MnuUpdate.IsEnabled = (@($sel | Where-Object InCompose).Count -gt 0)
        $ui.MnuRecreate.IsEnabled = (@($sel | Where-Object { $_.InCompose -and $_.HasContainer }).Count -gt 0)
        $ui.MnuLogs.IsEnabled = ($sel.Count -eq 1 -and $sel[0].HasContainer)
        $ui.MnuOpen.IsEnabled = ($sel.Count -eq 1 -and $sel[0].HasUrl)
        $ui.MnuCopy.IsEnabled = ($sel.Count -gt 0)
        $ui.MnuRemove.IsEnabled = (@($sel | Where-Object HasContainer).Count -gt 0)
    })
$ui.MnuStart.Add_Click({ Invoke-Start (Get-SelectedRows) })
$ui.MnuStop.Add_Click({ Invoke-Stop (Get-SelectedRows) })
$ui.MnuRestart.Add_Click({ Invoke-Restart (Get-SelectedRows) })
$ui.MnuUpdate.Add_Click({ Invoke-Update (Get-SelectedRows) })
$ui.MnuRecreate.Add_Click({ Invoke-Recreate (Get-SelectedRows) })
$ui.MnuLogs.Add_Click({ $sel = Get-SelectedRows; if ($sel.Count -eq 1) { Show-Logs $sel[0] } })
$ui.MnuOpen.Add_Click({ $sel = Get-SelectedRows; if ($sel.Count -eq 1) { Open-Url $sel[0].Url } })
$ui.MnuCopy.Add_Click({ $names = @(Get-SelectedRows | ForEach-Object Service); if ($names.Count) { [Windows.Clipboard]::SetText($names -join "`r`n") } })
$ui.MnuRemove.Add_Click({ Invoke-Remove (Get-SelectedRows) })

$window.Add_PreviewKeyDown({
        param($s, $e)
        $ctrl = ([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Control)
        if ($e.Key -eq 'F5') { Request-ConfigLoad; $script:NextPoll = [DateTime]::MinValue; $e.Handled = $true }
        elseif ($ctrl -and $e.Key -eq 'F') { [void]$ui.TxtSearch.Focus(); $ui.TxtSearch.SelectAll(); $e.Handled = $true }
        elseif ($ctrl -and $e.Key -eq 'L') { $sel = Get-SelectedRows; if ($sel.Count -eq 1) { Show-Logs $sel[0] }; $e.Handled = $true }
        elseif ($e.Key -eq 'Escape' -and $ui.TxtSearch.IsKeyboardFocusWithin) { $ui.TxtSearch.Clear(); [void]$ui.Grid.Focus(); $e.Handled = $true }
        elseif ($e.Key -eq 'Return' -and $ui.Grid.IsKeyboardFocusWithin) { $sel = Get-SelectedRows; if ($sel.Count -eq 1) { Open-Url $sel[0].Url }; $e.Handled = $true }
    })

$window.Add_StateChanged({
        if ($window.WindowState -eq 'Minimized' -and $script:Settings.MinimiseToTray -and $script:Tray) { $window.Hide() }
        elseif ($window.WindowState -ne 'Minimized') { $script:Settings.WindowMaximised = ($window.WindowState -eq 'Maximized') }
    })

$window.Add_Closing({
        param($s, $e)
        if ($script:CurrentJob -or $script:JobQueue.Count) {
            $answer = [Windows.MessageBox]::Show($window, "Docker is still working on: $($script:CurrentJob.Label)`n`nClose anyway? The command is stopped part way.", $script:AppName, 'YesNo', 'Warning')
            if ($answer -ne 'Yes') { $e.Cancel = $true; return }
            Stop-CurrentJob
        }
        $script:Closing = $true
        if ($window.WindowState -eq 'Normal') {
            $script:Settings.WindowWidth = [int]$window.Width
            $script:Settings.WindowHeight = [int]$window.Height
        }
        $script:Settings.WindowMaximised = ($window.WindowState -eq 'Maximized')
        Save-Settings
        foreach ($lw in @($script:LogWindows)) { try { $lw.Window.Close() } catch { Write-Verbose 'Log window already closed.' } }
        foreach ($c in @($script:Calls)) { $c.Runner.Kill() }
    })

# DataGrid can squeeze its fixed columns if it is first measured before the
# window has its final size, and it never widens them again. Set them once
# the window is on screen.
$script:ColumnWidths = @($ui.Grid.Columns | ForEach-Object { $_.Width })
$window.Add_ContentRendered({
        for ($i = 0; $i -lt $ui.Grid.Columns.Count; $i++) {
            $ui.Grid.Columns[$i].Width = New-Object Windows.Controls.DataGridLength(0)
            $ui.Grid.Columns[$i].Width = $script:ColumnWidths[$i]
        }
    })

$window.Add_Closed({
        $script:Timer.Stop()
        if ($script:Tray) { $script:Tray.Visible = $false; $script:Tray.Dispose() }
    })

# ---------------------------------------------------------------------------
# The heartbeat: one timer drives queries, jobs, logs and file watching.
# ---------------------------------------------------------------------------
$script:Timer = New-Object Windows.Threading.DispatcherTimer
$script:Timer.Interval = [TimeSpan]::FromMilliseconds(250)
$script:LastStampCheck = [DateTime]::MinValue
$script:Timer.Add_Tick({
        if ($script:Closing) { return }
        try {
            Update-Calls
            Update-Jobs
            Update-LogWindows
            $now = [DateTime]::Now
            # The compose file or .env saved? Wait a moment for the editor to finish, then re-read.
            if ($script:ComposePath -and ($now - $script:LastStampCheck).TotalSeconds -ge 2) {
                $script:LastStampCheck = $now
                $stamp = Get-FileStamp
                if ($stamp -ne $script:FileStamp) {
                    $script:FileStamp = $stamp
                    $script:FileChangedAt = $now
                }
                if ($script:FileChangedAt -ne [DateTime]::MinValue -and ($now - $script:FileChangedAt).TotalSeconds -ge 1) {
                    $script:FileChangedAt = [DateTime]::MinValue
                    Write-Activity 'The compose file or .env changed. Reading it again.'
                    Request-ConfigLoad
                }
            }
            if ($script:ConfigWanted -and -not $script:ConfigLoading) { Start-ConfigLoad }
            if ($now -ge $script:NextPoll -and -not $script:PollRunning) {
                if ($script:ConfigLoaded) { Start-Poll }
                else { $script:NextPoll = $now.AddSeconds(5) }
            }
            # Tick fast only while something is running; idle ticks cost CPU on the UI thread.
            $active = ($script:CurrentJob -or $script:JobQueue.Count -or $script:Calls.Count -or $script:LogWindows.Count -or $script:ConfigWanted)
            $ms = if ($active) { 200 } else { 1000 }
            if ($script:Timer.Interval.TotalMilliseconds -ne $ms) { $script:Timer.Interval = [TimeSpan]::FromMilliseconds($ms) }
        } catch {
            Write-Activity "Internal error: $($_.Exception.Message)"
        }
    })

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------
$window.Width = [Math]::Max(900, [int]$script:Settings.WindowWidth)
$window.Height = [Math]::Max(540, [int]$script:Settings.WindowHeight)
$work = [Windows.SystemParameters]::WorkArea
if ($window.Width -gt $work.Width) { $window.Width = $work.Width }
if ($window.Height -gt $work.Height) { $window.Height = $work.Height }
if ($script:Settings.WindowMaximised) { $window.WindowState = 'Maximized' }

$script:DockerExe = Find-Docker
if (-not $script:DockerExe) { $script:DockerState = 'missing' }
try { $script:Tray = New-Tray } catch { $script:Tray = $null; Write-Verbose "No tray icon: $($_.Exception.Message)" }

Write-Activity "$script:AppName v$script:AppVersion"
if ($script:DockerExe) { Write-Activity "Using $script:DockerExe" } else { Write-Activity "docker.exe wasn't found. Install Docker Desktop, then press Try again." }

$startFile = if ($ComposeFile) { $ComposeFile } else { [string]$script:Settings.ComposeFile }
Update-RecentList
if ($startFile -and (Test-Path -LiteralPath $startFile)) {
    Set-ComposeFile $startFile
} else {
    if ($startFile) { Write-Activity "The last compose file isn't there any more: $startFile" }
    Update-Banner
    Update-Groups
    Update-View
}

$script:Timer.Start()
$app = [Windows.Application]::Current
if (-not $app) { $app = New-Object Windows.Application; $app.ShutdownMode = 'OnMainWindowClose' }
# An error inside a click or key handler must never reach WPF's input handling:
# log it and carry on, so the window keeps responding.
$app.Add_DispatcherUnhandledException({
        param($s, $e)
        $e.Handled = $true
        try { Write-Activity "Internal error: $($e.Exception.Message)" } catch { Write-Verbose 'Activity log unavailable.' }
    })
[void]$app.Run($window)
