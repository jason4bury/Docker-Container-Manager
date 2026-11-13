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

    The app only edits the compose file or .env when you save changes in a
    Configure window or use Tidy spacing, and keeps a backup copy in %APPDATA% first.

.PARAMETER ComposeFile
    Open this compose file instead of the last one used.

.EXAMPLE
    powershell -STA -ExecutionPolicy Bypass -File .\Docker-Container-Manager.ps1
    Opens the window with the last compose file used.

.EXAMPLE
    "Docker Container Manager v1.10.exe" -ComposeFile "D:\Docker\docker-compose.yml"

.NOTES
    Version:   1.10 (keep in step with CHANGELOG.md)
    Author:    Jason Rhodes
    Licence:   MIT - see LICENSE
    Settings:  %APPDATA%\Docker Container Manager\settings.json
#>
param(
    [string]$ComposeFile
)

$ErrorActionPreference = 'Stop'

$script:AppName    = 'Docker Container Manager'
$script:AppVersion = '1.10'
$script:RepoUrl    = 'https://github.com/jason4bury/Docker-Container-Manager'

#region BUNDLE-ASSETS
# Build-Exe.cmd replaces this region with the icon and logo as base64, so the exe
# needs no other files. Running from source, they are read from ..\assets\.
# If Source\my-groups.txt is there when the exe is built, it's put in too as the
# built-in My groups list.
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
#   Dcm.EnvEntry   - one environment variable in the Configure window.
#   Dcm.ImageInfo  - one image in the Disk usage window.
#   Dcm.MyGroupEntry - one line of My groups (my-groups.txt).
#   Dcm.Native     - dark title bars (Windows 10 20H1 and later).
# ---------------------------------------------------------------------------
if (-not ('Dcm.Native' -as [type])) {
    Add-Type -Language CSharp -ReferencedAssemblies System, System.Core -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

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
        public Runner(string exe, string[] args, string workingDir, bool capture) : this(exe, args, workingDir, capture, null) { }

        // stdinFile: a file whose bytes are fed to the program's input (used to send files over ssh).
        public Runner(string exe, string[] args, string workingDir, bool capture, string stdinFile) {
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
            bool feed = !String.IsNullOrEmpty(stdinFile);
            psi.RedirectStandardInput = feed;
            Proc = new Process();
            Proc.StartInfo = psi;
            Proc.OutputDataReceived += OnOut;
            Proc.ErrorDataReceived += OnErr;
            Proc.Start();
            Proc.BeginOutputReadLine();
            Proc.BeginErrorReadLine();
            if (feed) {
                Process p = Proc;
                string path = stdinFile;
                Thread t = new Thread(delegate() {
                    try {
                        using (System.IO.FileStream fs = System.IO.File.OpenRead(path)) { fs.CopyTo(p.StandardInput.BaseStream); }
                        p.StandardInput.Close();
                    } catch (Exception) { try { p.StandardInput.Close(); } catch (Exception) { } }
                });
                t.IsBackground = true;
                t.Start();
            }
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
        public bool   UpdateAvailable { get { return B("UpdateAvailable"); } set { SetValue("UpdateAvailable", value); } }
        public string ColorLabel    { get { return S("ColorLabel"); }    set { SetValue("ColorLabel", value); } }
        public string IconLabel     { get { return S("IconLabel"); }     set { SetValue("IconLabel", value); } }
        public string SourceLabel   { get { return S("SourceLabel"); }   set { SetValue("SourceLabel", value); } }
        public string IconKey       { get { return S("IconKey"); }       set { SetValue("IconKey", value); } }
        public string GroupColor    { get { string c = S("GroupColor"); return c.Length > 0 ? c : "#97A3B3"; } set { SetValue("GroupColor", value); } }
        public string Initial       { get { string s = S("Service"); return s.Length > 0 ? s.Substring(0, 1).ToUpperInvariant() : "?"; } }
        public object Icon          { get { return GetValue("Icon"); }   set { SetValue("Icon", value); SetValue("HasIcon", value != null); } }
        public bool   HasIcon       { get { return B("HasIcon"); } }
    }

    public class ImageInfo {
        public string Repository { get; set; }
        public string Tag        { get; set; }
        public string Id         { get; set; }
        public string Size       { get; set; }
        public double Bytes      { get; set; }
        public string Created    { get; set; }
        public string UsedBy     { get; set; }
        public string Name       { get { return Repository == "<none>" ? "(no name)" : Repository + ":" + Tag; } }
    }

    // One line of My groups (my-groups.txt): a service name and its group.
    public class MyGroupEntry {
        public string Service { get; set; }
        public string Group   { get; set; }
    }

    public static class Native {
        [DllImport("dwmapi.dll")]
        private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
        public static void DarkTitleBar(IntPtr hwnd) {
            int on = 1;
            try {
                if (DwmSetWindowAttribute(hwnd, 20, ref on, 4) != 0) { DwmSetWindowAttribute(hwnd, 19, ref on, 4); }
            } catch (Exception) { }
        }
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

    public class EnvEntry : Notifier {
        public string Name     { get { return S("Name"); }     set { SetValue("Name", value); Refresh(); } }
        public string Value    { get { return S("Value"); }    set { SetValue("Value", value); Refresh(); } }
        public string Original { get { return S("Original"); } set { SetValue("Original", value); Refresh(); } }
        public string Raw      { get { return S("Raw"); }      set { SetValue("Raw", value); } }
        public string VarName  { get { return S("VarName"); }  set { SetValue("VarName", value); } }
        public string From     { get { return S("From"); }     set { SetValue("From", value); } }
        public string Form     { get { return S("Form"); }     set { SetValue("Form", value); } }
        public bool   Secret   { get { return B("Secret"); }   set { SetValue("Secret", value); Refresh(); } }
        public bool   Reveal   { get { return B("Reveal"); }   set { SetValue("Reveal", value); Refresh(); } }
        public bool   IsNew    { get { return B("IsNew"); }    set { SetValue("IsNew", value); Refresh(); } }
        public bool   MoveToEnv { get { return B("MoveToEnv"); } set { SetValue("MoveToEnv", value); Refresh(); } }
        public bool   Editable { get { return B("Editable"); } set { SetValue("Editable", value); } }
        public bool   Literal  { get { return B("Literal"); }  set { SetValue("Literal", value); } }
        public bool   Missing  { get { return B("Missing"); }  set { SetValue("Missing", value); } }
        public int    Line     { get { object o = GetValue("Line"); return o == null ? -1 : (int)o; } set { SetValue("Line", value); } }
        public string Shown    { get { return S("Shown"); } }
        public string Status   { get { return S("Status"); } }
        private void Refresh() {
            string v = S("Value");
            SetValue("Shown", (B("Secret") && !B("Reveal") && v.Length > 0) ? new string('\u2022', Math.Min(12, v.Length)) : v);
            string st = "";
            if (B("IsNew")) { st = "New"; }
            else if (B("MoveToEnv")) { st = "Move to .env"; }
            else if (v != S("Original")) { st = "Changed"; }
            SetValue("Status", st);
        }
    }

    public class GroupEntry : Notifier {
        public string Key     { get { return S("Key"); }     set { SetValue("Key", value); } }
        public string Name    { get { return S("Name"); }    set { SetValue("Name", value); } }
        public string Counts  { get { return S("Counts"); }  set { SetValue("Counts", value); } }
        public bool   Problem { get { return B("Problem"); } set { SetValue("Problem", value); } }
        public bool   Special { get { return B("Special"); } set { SetValue("Special", value); } }
        public string Color   { get { string c = S("Color"); return c.Length > 0 ? c : "#97A3B3"; } set { SetValue("Color", value); } }
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
        ViewMode          = 'List'
        Theme             = 'System'
        DownloadIcons     = $true
        CheckUpdatesOnStart = $true
        WindowWidth       = 1650
        WindowHeight      = 1080
        WindowMaximised   = $false
        LogHeight         = 221
        Machines          = @()
        Machine           = ''
        ShowProgress      = $true
        PortainerFolder   = ''
        ShowFinished      = $true
    }
}

# One other Docker machine, reached over SSH (see Get-MachineRunnerArgs).
function ConvertTo-Machine($Item) {
    if ($null -eq $Item) { return $null }
    $get = { param($k) $v = if ($Item -is [Collections.IDictionary]) { $Item[$k] } else { $p = $Item.PSObject.Properties[$k]; if ($p) { $p.Value } }; if ($null -eq $v) { '' } else { ([string]$v).Trim() } }
    $m = [ordered]@{
        Name    = & $get 'Name'
        Login   = & $get 'Login'
        Port    = & $get 'Port'
        Folder  = (& $get 'Folder').TrimEnd('/')
        Project = (& $get 'Project').ToLowerInvariant()
        EnvFile = & $get 'EnvFile'
        Docker  = & $get 'Docker'
        WebHost = & $get 'WebHost'
        ComposeFile = & $get 'ComposeFile'
        Portainer = (& $get 'Portainer').TrimEnd('/')
    }
    if (-not $m.Name -or -not $m.Login) { return $null }
    if (-not $m.Docker) { $m.Docker = 'docker' }
    return $m
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
    if ($s.ViewMode -notin 'List', 'Cards') { $s.ViewMode = 'List' }
    if ($s.Theme -notin 'System', 'Light', 'Dark') { $s.Theme = 'System' }
    $s.Machines = @(foreach ($m in @($s.Machines)) { $n = ConvertTo-Machine $m; if ($n) { $n } })
    if (-not @($s.Machines | Where-Object { $_.Name -eq $s.Machine }).Count) { $s.Machine = '' }
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
$script:RemoteError    = ''
$script:OldCompose     = $false
$script:UpdatingMachines = $false
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
$script:ConfigureWindows = New-Object System.Collections.ArrayList
$script:ServiceConfigs = @{}
$script:Closing        = $false
$script:UngroupedName  = 'Ungrouped'
$script:OrphanName     = 'Not in compose file'
$script:FinishedJobs   = New-Object System.Collections.ArrayList
$script:FinishedForm   = $null
$script:SaveGroupsBox  = $null   # the "Saving groups" box while Save groups runs
$script:SaveGroupsNext = $null

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

# ---------------------------------------------------------------------------
# Machines: "This PC" runs docker.exe here. Any other machine (a Linux laptop,
# a VM, a Synology NAS) is reached with Windows' own ssh.exe: each docker
# command runs there, against the compose file and .env in that machine's
# folder. The compose file on this PC is the master; Send to machine copies it
# (with that machine's Env_ file as .env) across.
# ---------------------------------------------------------------------------
function Get-Machine {
    $name = [string]$script:Settings.Machine
    if (-not $name) { return $null }
    $m = @($script:Settings.Machines | Where-Object { $_.Name -eq $name })
    if ($m.Count) { return $m[0] } else { return $null }
}

function Get-MachineName { $m = Get-Machine; if ($m) { return $m.Name } else { return 'This PC' } }

function Find-Ssh([string]$Name = 'ssh.exe') {
    foreach ($dir in @((Join-Path $env:SystemRoot 'Sysnative\OpenSSH'), (Join-Path $env:SystemRoot 'System32\OpenSSH'))) {
        $p = Join-Path $dir $Name
        if (Test-Path -LiteralPath $p) { return $p }
    }
    $cmd = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    return $null
}

# Docker can be used: docker.exe here, or ssh.exe for another machine.
function Test-DockerReady {
    if (Get-Machine) { return [bool](Find-Ssh) }
    return [bool]$script:DockerExe
}

# Quotes one word for the remote (POSIX) shell.
function ConvertTo-ShQuote([string]$Text) {
    if ($Text -match '^[A-Za-z0-9_./:=@%+,-]+$') { return $Text }
    return "'" + $Text.Replace("'", "'\''") + "'"
}

# SSH commands don't read the login profile, so Synology's /usr/local/bin isn't on PATH.
function Get-RemotePathPrefix { return 'PATH="$PATH:/usr/local/bin:/usr/bin:/bin"; ' }

function Get-SshArguments($Machine, [switch]$Tty) {
    $a = @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', '-o', 'StrictHostKeyChecking=accept-new', '-o', 'ServerAliveInterval=20')
    if ($Machine.Port) { $a += @('-p', [string]$Machine.Port) }
    if ($Tty) { $a += '-t' }
    return $a + @([string]$Machine.Login)
}

function Get-MachineHost($Machine) {
    if ($Machine.WebHost) { return $Machine.WebHost }
    return (([string]$Machine.Login -split '@')[-1])
}

function Get-RemoteComposePath($Machine) {
    return ('{0}/{1}' -f $Machine.Folder, [IO.Path]::GetFileName($script:ComposePath))
}

function Get-ComposeArguments([switch]$Local) {
    $m = if ($Local) { $null } else { Get-Machine }
    if ($m) {
        $a = @('compose', '--ansi', 'never', '--progress', 'plain', '-f', (Get-RemoteComposePath $m), '--project-directory', $m.Folder)
        # The stack may have been started under another name (Synology Container Manager uses the project's name).
        if ($m.Project) { $a += @('-p', $m.Project) }
        return $a
    }
    return @('compose', '--ansi', 'never', '--progress', 'plain', '-f', $script:ComposePath, '--project-directory', $script:ComposeDir)
}

# Starts docker here, or over ssh on the chosen machine. CommandLine always
# reads "docker ..." so the Activity log looks the same either way.
function New-DockerRunner([string[]]$Arguments, [bool]$Capture, [switch]$Local) {
    $m = if ($Local) { $null } else { Get-Machine }
    if (-not $m) {
        if (-not $script:DockerExe) { throw 'docker.exe was not found.' }
        return New-Object Dcm.Runner($script:DockerExe, [string[]]$Arguments, $script:ComposeDir, $Capture)
    }
    $ssh = Find-Ssh
    if (-not $ssh) { throw "ssh.exe wasn't found. Turn on the OpenSSH Client in Windows Settings > Apps > Optional features." }
    $remote = (Get-RemotePathPrefix) + $m.Docker + ' ' + (($Arguments | ForEach-Object { ConvertTo-ShQuote ([string]$_) }) -join ' ')
    $r = New-Object Dcm.Runner($ssh, [string[]](@(Get-SshArguments $m) + @($remote)), $script:ComposeDir, $Capture)
    $r.CommandLine = 'docker ' + [Dcm.Runner]::Join([string[]]$Arguments)
    return $r
}

# Runs a shell command on the machine (not docker), optionally feeding a file to it.
function New-SshStep($Machine, [string]$Command, [string]$Display, [string]$Stdin) {
    return @{ Exe = 'ssh'; Args = @(Get-SshArguments $Machine) + @($Command); Display = $Display; Stdin = $Stdin; AllowFail = $false }
}

function Test-DockerDownMessage([string]$Text) {
    return ($Text -match 'error during connect|Cannot connect to the Docker daemon|docker daemon is not running|dockerDesktopLinuxEngine|docker_engine|The system cannot find the file specified|failed to connect to the docker API|ssh: |Connection refused|Connection timed out|Could not resolve hostname|Permission denied|Host key verification failed|No route to host|ssh.exe wasn')
}

function Get-FirstLines([string]$Text, [int]$Count = 3) {
    $lines = @(($Text -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First $Count)
    return ($lines -join ' ').Trim()
}

# Starts a quick docker query. $OnDone gets an object with ExitCode, Output and
# Error once docker has finished (or straight away if docker can't be started).
function Start-DockerCall {
    param([string[]]$Arguments, [scriptblock]$OnDone, [switch]$Compose, [switch]$Local, [object]$Tag)
    $full = if ($Compose) { @(Get-ComposeArguments -Local:$Local) + $Arguments } else { $Arguments }
    try {
        $runner = New-DockerRunner $full $true -Local:$Local
        [void]$script:Calls.Add(@{ Runner = $runner; OnDone = $OnDone; Started = [DateTime]::Now; Tag = $Tag })
    } catch {
        $fail = [pscustomobject]@{ ExitCode = -1; Output = ''; Error = $_.Exception.Message }
        & $OnDone $fail $Tag
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
        # Tag is whatever the caller passed in (for example the row a lookup is for).
        try { & $call.OnDone $res $call.Tag } catch { Write-Activity "Internal error: $($_.Exception.Message)" }
    }
}

# ---------------------------------------------------------------------------
# Theme: light or dark colours. "System" follows the Windows app setting.
# A change applies the next time the app starts.
# ---------------------------------------------------------------------------
$script:Palettes = @{
    Light = @{
        Ink = '#1B2A3D'; SoftInk = '#5B6B80'; Page = '#F2F5F9'; Card = '#FFFFFF'; Edge = '#D9E1EA'; Accent = '#1769C2'
        AccentSoft = '#E3EFFC'; Navy = '#0E2238'; Ok = '#2DA44E'; Warn = '#D99A06'; Bad = '#CF2F3F'; Off = '#97A3B3'
        Orphan = '#8250DF'; Hover = '#F3F7FC'; GroupHover = '#F0F4F9'; Selected = '#B6D4F7'; NoteInk = '#B07A00'
        HeadA = '#0E2238'; HeadB = '#1769C2'; BadgeBg = '#DDF4E4'; BadgeInk = '#1A7F37'
        InfoBg = '#E3EFFC'; InfoEdge = '#9CC3F0'; WarnBg = '#FFF4D6'; WarnEdge = '#E8C66A'; ErrorBg = '#FDE3E6'; ErrorEdge = '#EBA2AA'
    }
    Dark = @{
        Ink = '#E6EDF3'; SoftInk = '#9AA8B8'; Page = '#161B22'; Card = '#1F2630'; Edge = '#333D4A'; Accent = '#4C9BEA'
        AccentSoft = '#23364D'; Navy = '#0B1220'; Ok = '#3FB950'; Warn = '#D8A31A'; Bad = '#F0626E'; Off = '#6E7B8B'
        Orphan = '#A27BEA'; Hover = '#26303C'; GroupHover = '#26303C'; Selected = '#335F93'; NoteInk = '#E3B341'
        HeadA = '#0B1220'; HeadB = '#1A4F8A'; BadgeBg = '#1F3A28'; BadgeInk = '#56D364'
        InfoBg = '#1D3350'; InfoEdge = '#3B6A9E'; WarnBg = '#3A2F12'; WarnEdge = '#8A6D1E'; ErrorBg = '#3D1E24'; ErrorEdge = '#8F3A45'
    }
}

function Get-ThemeName {
    $t = [string]$script:Settings.Theme
    if ($t -eq 'Light' -or $t -eq 'Dark') { return $t }
    try {
        $v = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop
        if ($v.AppsUseLightTheme -eq 0) { return 'Dark' }
    } catch { Write-Verbose 'No Windows app theme setting, so light.' }
    return 'Light'
}

$script:Theme = Get-ThemeName
$script:Pal = $script:Palettes[$script:Theme]

# Group colours, given out in name order. A home.color label on any service of a
# group picks its own colour instead.
$script:GroupPalette = @('#1769C2', '#2DA44E', '#D9822B', '#8250DF', '#CF2F3F', '#0E8A8A', '#B5508A', '#6E7B1E', '#4E5BD1', '#A86B32', '#1F9AD6', '#7A6A58')

# ---------------------------------------------------------------------------
# Shared look: colours and control styles used by every window
# ---------------------------------------------------------------------------
$script:SharedResources = @'
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
    <SolidColorBrush x:Key="Ink" Color="%%Ink%%"/>
    <SolidColorBrush x:Key="SoftInk" Color="%%SoftInk%%"/>
    <SolidColorBrush x:Key="Page" Color="%%Page%%"/>
    <SolidColorBrush x:Key="Card" Color="%%Card%%"/>
    <SolidColorBrush x:Key="Edge" Color="%%Edge%%"/>
    <SolidColorBrush x:Key="Accent" Color="%%Accent%%"/>
    <SolidColorBrush x:Key="AccentSoft" Color="%%AccentSoft%%"/>
    <SolidColorBrush x:Key="Navy" Color="%%Navy%%"/>
    <SolidColorBrush x:Key="Ok" Color="%%Ok%%"/>
    <SolidColorBrush x:Key="Warn" Color="%%Warn%%"/>
    <SolidColorBrush x:Key="Bad" Color="%%Bad%%"/>
    <SolidColorBrush x:Key="Off" Color="%%Off%%"/>
    <SolidColorBrush x:Key="Orphan" Color="%%Orphan%%"/>
    <SolidColorBrush x:Key="Hover" Color="%%Hover%%"/>
    <SolidColorBrush x:Key="GroupHover" Color="%%GroupHover%%"/>
    <SolidColorBrush x:Key="Selected" Color="%%Selected%%"/>
    <SolidColorBrush x:Key="NoteInk" Color="%%NoteInk%%"/>
    <SolidColorBrush x:Key="BadgeBg" Color="%%BadgeBg%%"/>
    <SolidColorBrush x:Key="BadgeInk" Color="%%BadgeInk%%"/>
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
        <Setter Property="Margin" Value="0,3,6,3"/>
        <Setter Property="VerticalAlignment" Value="Bottom"/>
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
    <Style x:Key="IconBtn" TargetType="Button">
        <Setter Property="Cursor" Value="Hand"/>
        <Setter Property="Foreground" Value="{StaticResource SoftInk}"/>
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="Button">
                    <Border x:Name="Bd" Background="Transparent" CornerRadius="5" Padding="6,4">
                        <TextBlock Text="{TemplateBinding Tag}" FontFamily="Segoe MDL2 Assets" FontSize="13" Foreground="{TemplateBinding Foreground}"/>
                    </Border>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsMouseOver" Value="True">
                            <Setter TargetName="Bd" Property="Background" Value="{StaticResource AccentSoft}"/>
                            <Setter Property="Foreground" Value="{StaticResource Accent}"/>
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

# Dark mode only: Windows' own control looks are drawn for light backgrounds, so
# text boxes, drop-down lists, menus and scroll bars get dark versions here.
$script:DarkStyles = @'
    <SolidColorBrush x:Key="{x:Static SystemColors.ControlTextBrushKey}" Color="%%Ink%%"/>
    <SolidColorBrush x:Key="{x:Static SystemColors.WindowTextBrushKey}" Color="%%Ink%%"/>
    <SolidColorBrush x:Key="{x:Static SystemColors.WindowBrushKey}" Color="%%Card%%"/>
    <SolidColorBrush x:Key="{x:Static SystemColors.ControlBrushKey}" Color="%%Card%%"/>
    <SolidColorBrush x:Key="{x:Static SystemColors.GrayTextBrushKey}" Color="%%SoftInk%%"/>
    <SolidColorBrush x:Key="{x:Static SystemColors.HighlightBrushKey}" Color="%%Selected%%"/>
    <SolidColorBrush x:Key="{x:Static SystemColors.HighlightTextBrushKey}" Color="%%Ink%%"/>
    <SolidColorBrush x:Key="{x:Static SystemColors.MenuBrushKey}" Color="%%Card%%"/>
    <SolidColorBrush x:Key="{x:Static SystemColors.MenuTextBrushKey}" Color="%%Ink%%"/>
    <Style TargetType="TextBox">
        <Setter Property="Background" Value="{StaticResource Card}"/>
        <Setter Property="Foreground" Value="{StaticResource Ink}"/>
        <Setter Property="BorderBrush" Value="{StaticResource Edge}"/>
        <Setter Property="CaretBrush" Value="{StaticResource Ink}"/>
    </Style>
    <Style TargetType="PasswordBox">
        <Setter Property="Background" Value="{StaticResource Card}"/>
        <Setter Property="Foreground" Value="{StaticResource Ink}"/>
        <Setter Property="CaretBrush" Value="{StaticResource Ink}"/>
    </Style>
    <Style TargetType="CheckBox">
        <Setter Property="Foreground" Value="{StaticResource Ink}"/>
    </Style>
    <Style TargetType="DataGridColumnHeader">
        <Setter Property="Background" Value="Transparent"/>
        <Setter Property="Foreground" Value="{StaticResource SoftInk}"/>
        <Setter Property="FontWeight" Value="SemiBold"/>
        <Setter Property="Padding" Value="8,6"/>
        <Setter Property="BorderBrush" Value="{StaticResource Edge}"/>
        <Setter Property="BorderThickness" Value="0,0,0,1"/>
    </Style>
    <Style TargetType="ComboBoxItem">
        <Setter Property="Foreground" Value="{StaticResource Ink}"/>
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="ComboBoxItem">
                    <Border x:Name="Bd" Padding="8,4" Background="Transparent">
                        <ContentPresenter/>
                    </Border>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsSelected" Value="True">
                            <Setter TargetName="Bd" Property="Background" Value="{StaticResource Selected}"/>
                        </Trigger>
                        <Trigger Property="IsHighlighted" Value="True">
                            <Setter TargetName="Bd" Property="Background" Value="{StaticResource Hover}"/>
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>
    <Style TargetType="ComboBox">
        <Setter Property="Foreground" Value="{StaticResource Ink}"/>
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="ComboBox">
                    <Grid>
                        <ToggleButton Focusable="False" ClickMode="Press"
                                      IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                            <ToggleButton.Template>
                                <ControlTemplate TargetType="ToggleButton">
                                    <Border x:Name="B" Background="{StaticResource Card}" BorderBrush="{StaticResource Edge}" BorderThickness="1" CornerRadius="4">
                                        <TextBlock Text="&#xE70D;" FontFamily="Segoe MDL2 Assets" FontSize="10" HorizontalAlignment="Right"
                                                   VerticalAlignment="Center" Margin="0,0,8,0" Foreground="{StaticResource SoftInk}"/>
                                    </Border>
                                    <ControlTemplate.Triggers>
                                        <Trigger Property="IsMouseOver" Value="True">
                                            <Setter TargetName="B" Property="BorderBrush" Value="{StaticResource Accent}"/>
                                        </Trigger>
                                    </ControlTemplate.Triggers>
                                </ControlTemplate>
                            </ToggleButton.Template>
                        </ToggleButton>
                        <ContentPresenter IsHitTestVisible="False" Margin="8,4,26,4" VerticalAlignment="Center"
                                          Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"/>
                        <Popup x:Name="PART_Popup" Placement="Bottom" AllowsTransparency="True" Focusable="False"
                               IsOpen="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                            <Border Background="{StaticResource Card}" BorderBrush="{StaticResource Edge}" BorderThickness="1"
                                    MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}"
                                    MaxHeight="{TemplateBinding MaxDropDownHeight}">
                                <ScrollViewer>
                                    <StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Contained"/>
                                </ScrollViewer>
                            </Border>
                        </Popup>
                    </Grid>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsEnabled" Value="False">
                            <Setter Property="Opacity" Value="0.5"/>
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>
    <Style x:Key="DarkMenu" TargetType="ContextMenu">
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="ContextMenu">
                    <Border Background="{StaticResource Card}" BorderBrush="{StaticResource Edge}" BorderThickness="1" CornerRadius="6" Padding="3">
                        <StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Cycle"/>
                    </Border>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>
    <Style x:Key="DarkMenuItem" TargetType="MenuItem">
        <Setter Property="Foreground" Value="{StaticResource Ink}"/>
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="MenuItem">
                    <Border x:Name="Bd" Padding="22,5,28,5" Background="Transparent" CornerRadius="4">
                        <ContentPresenter ContentSource="Header" RecognizesAccessKey="True"/>
                    </Border>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsHighlighted" Value="True">
                            <Setter TargetName="Bd" Property="Background" Value="{StaticResource Hover}"/>
                        </Trigger>
                        <Trigger Property="IsEnabled" Value="False">
                            <Setter Property="Opacity" Value="0.45"/>
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>
    <Style x:Key="DarkSeparator" TargetType="Separator">
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="Separator">
                    <Border Height="1" Margin="8,3" Background="{StaticResource Edge}"/>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>
    <Style x:Key="ScrollPage" TargetType="RepeatButton">
        <Setter Property="Focusable" Value="False"/>
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>
    <Style x:Key="ScrollThumb" TargetType="Thumb">
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="Thumb"><Border CornerRadius="4" Margin="2" Background="{StaticResource Off}"/></ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>
    <Style TargetType="ScrollBar">
        <Setter Property="Width" Value="12"/>
        <Setter Property="MinWidth" Value="12"/>
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="ScrollBar">
                    <Track x:Name="PART_Track" IsDirectionReversed="True">
                        <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource ScrollPage}" Command="ScrollBar.PageUpCommand"/></Track.DecreaseRepeatButton>
                        <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource ScrollPage}" Command="ScrollBar.PageDownCommand"/></Track.IncreaseRepeatButton>
                        <Track.Thumb><Thumb Style="{StaticResource ScrollThumb}"/></Track.Thumb>
                    </Track>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
        <Style.Triggers>
            <Trigger Property="Orientation" Value="Horizontal">
                <Setter Property="Width" Value="Auto"/>
                <Setter Property="MinWidth" Value="0"/>
                <Setter Property="Height" Value="12"/>
                <Setter Property="MinHeight" Value="12"/>
                <Setter Property="Template">
                    <Setter.Value>
                        <ControlTemplate TargetType="ScrollBar">
                            <Track x:Name="PART_Track">
                                <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource ScrollPage}" Command="ScrollBar.PageLeftCommand"/></Track.DecreaseRepeatButton>
                                <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource ScrollPage}" Command="ScrollBar.PageRightCommand"/></Track.IncreaseRepeatButton>
                                <Track.Thumb><Thumb Style="{StaticResource ScrollThumb}"/></Track.Thumb>
                            </Track>
                        </ControlTemplate>
                    </Setter.Value>
                </Setter>
            </Trigger>
        </Style.Triggers>
    </Style>
'@
if ($script:Theme -eq 'Dark') { $script:SharedInner += $script:DarkStyles }

function New-XamlObject([string]$Xaml) {
    $text = $Xaml.Replace('<!--SHARED-->', $script:SharedInner)
    foreach ($k in $script:Pal.Keys) { $text = $text.Replace("%%$k%%", $script:Pal[$k]) }
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$text)
    $obj = [Windows.Markup.XamlReader]::Load($reader)
    if ($script:Theme -eq 'Dark' -and $obj -is [Windows.Window]) {
        $obj.Add_SourceInitialized({
                param($s)
                try { [Dcm.Native]::DarkTitleBar((New-Object Windows.Interop.WindowInteropHelper($s)).Handle) } catch { Write-Verbose 'No dark title bar.' }
            })
    }
    return $obj
}

# Dark menus: a ContextMenu doesn't pick up the window's styles by itself.
function Set-MenuTheme($Menu, $Owner) {
    if ($script:Theme -ne 'Dark' -or -not $Menu) { return }
    $Menu.Style = $Owner.FindResource('DarkMenu')
    foreach ($item in $Menu.Items) {
        if ($item -is [Windows.Controls.MenuItem]) { $item.Style = $Owner.FindResource('DarkMenuItem') }
        elseif ($item -is [Windows.Controls.Separator]) { $item.Style = $Owner.FindResource('DarkSeparator') }
    }
}

# ---------------------------------------------------------------------------
# Main window
# ---------------------------------------------------------------------------
$mainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Docker Container Manager" Width="1650" Height="1080" MinWidth="900" MinHeight="540"
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
            <RowDefinition x:Name="LogRow" Height="221" MinHeight="0"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Header -->
        <Border Grid.Row="0" Padding="16,12">
            <Border.Background>
                <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                    <GradientStop Color="%%HeadA%%" Offset="0"/>
                    <GradientStop Color="%%HeadB%%" Offset="1"/>
                </LinearGradientBrush>
            </Border.Background>
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Image x:Name="ImgLogo" Width="44" Height="44" Margin="0,0,12,0" RenderOptions.BitmapScalingMode="HighQuality"/>
                <StackPanel x:Name="HeaderTitle" Grid.Column="1" VerticalAlignment="Center" Margin="0,0,16,0">
                    <TextBlock Text="Docker Container Manager" FontSize="20" FontWeight="SemiBold" Foreground="#FFFFFF"/>
                    <TextBlock x:Name="TxtSubtitle" Foreground="#CFE0F5" TextTrimming="CharacterEllipsis" Margin="0,2,0,0" MaxWidth="420" HorizontalAlignment="Left"/>
                    <TextBlock x:Name="TxtProject" Foreground="#CFE0F5" TextTrimming="CharacterEllipsis" MaxWidth="420" HorizontalAlignment="Left"/>
                </StackPanel>
                <!-- The buttons wrap onto a second line when the window is narrow, so the title is never cut off. -->
                <WrapPanel x:Name="HeaderButtons" Grid.Column="2" HorizontalAlignment="Right" VerticalAlignment="Center">
                    <!-- Captions above the two lists say what each one is for. -->
                    <StackPanel Margin="0,0,6,0" VerticalAlignment="Bottom">
                        <TextBlock Text="Containers on" FontSize="11" Foreground="#CFE0F5" Margin="2,0,0,0"/>
                        <ComboBox x:Name="CmbMachine" Width="150" Margin="0,2,0,3" VerticalContentAlignment="Center"
                                  ToolTip="Which machine's Docker to manage. Other machines are reached over SSH."/>
                    </StackPanel>
                    <!-- Send sits next to the file it sends. -->
                    <StackPanel Orientation="Horizontal" Margin="0,0,16,0" VerticalAlignment="Bottom">
                        <StackPanel x:Name="PnlRecent" VerticalAlignment="Bottom">
                            <TextBlock x:Name="TxtRecentCaption" Text="Compose file" FontSize="11" MaxWidth="230" TextTrimming="CharacterEllipsis" Foreground="#CFE0F5" Margin="2,0,0,0"/>
                            <ComboBox x:Name="CmbRecent" Width="230" Margin="0,2,0,3" VerticalContentAlignment="Center"
                                      ToolTip="Switch to another compose file you've used on this PC"/>
                        </StackPanel>
                        <Button x:Name="BtnSend" Content="Send" Tag="&#xE898;" Style="{DynamicResource HeaderBtn}" Visibility="Collapsed" Margin="6,3,0,3"
                                ToolTip="Copy the compose file and this machine's Env_ file (as .env) to the machine"/>
                    </StackPanel>
                    <Button x:Name="BtnBrowse" Content="Compose file..." Tag="&#xE8E5;" Style="{DynamicResource HeaderBtn}"
                            ToolTip="Choose a docker-compose.yml"/>
                    <Button x:Name="BtnEditCompose" Content="Edit" Tag="&#xE70F;" Style="{DynamicResource HeaderBtn}"
                            ToolTip="Open the compose file in your editor. The list updates when you save."/>
                    <Button x:Name="BtnEditEnv" Content=".env" Tag="&#xE70F;" Style="{DynamicResource HeaderBtn}"
                            ToolTip="Open the .env file next to the compose file"/>
                    <Button x:Name="BtnCheck" Content="Check" Tag="&#xE73E;" Style="{DynamicResource HeaderBtn}"
                            ToolTip="Check the compose file for spacing, ${...} variables, port clashes and other mistakes"/>
                    <Button x:Name="BtnDisk" Content="Disk" Tag="&#xEDA2;" Style="{DynamicResource HeaderBtn}"
                            ToolTip="How much space images, containers and the build cache use, and clean-up"/>
                    <Button x:Name="BtnFolder" Content="Folder" Tag="&#xE8B7;" Style="{DynamicResource HeaderBtn}"
                            ToolTip="Open the compose file's folder"/>
                    <Button x:Name="BtnSettings" Content="Settings" Tag="&#xE713;" Style="{DynamicResource HeaderBtn}"/>
                    <Button x:Name="BtnHelp" Content="Help" Tag="&#xE897;" Style="{DynamicResource HeaderBtn}" ToolTip="How to use the app (F1)"/>
                    <Button x:Name="BtnAbout" Content="About" Tag="&#xE946;" Style="{DynamicResource HeaderBtn}" Margin="0,3,0,3"/>
                </WrapPanel>
            </Grid>
        </Border>

        <!-- Banner: Docker not running, compose errors, missing .env -->
        <Border x:Name="Banner" Grid.Row="1" Padding="16,9" Visibility="Collapsed" Background="%%WarnBg%%" BorderBrush="%%WarnEdge%%" BorderThickness="0,0,0,1">
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
                                                    <Setter TargetName="Bd" Property="Background" Value="{DynamicResource GroupHover}"/>
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
                                        <ColumnDefinition Width="Auto"/>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <Border x:Name="Swatch" Width="10" Height="10" CornerRadius="3" Margin="0,0,8,0" VerticalAlignment="Center" Background="{Binding Color}"/>
                                    <TextBlock x:Name="N" Grid.Column="1" Text="{Binding Name}" TextTrimming="CharacterEllipsis"/>
                                    <StackPanel Grid.Column="2" Orientation="Horizontal">
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
                                        <Setter TargetName="Swatch" Property="Visibility" Value="Collapsed"/>
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
                    <StackPanel Grid.Column="1" Orientation="Horizontal" Margin="6,0,0,0">
                        <ComboBox x:Name="CmbState" Width="150" VerticalContentAlignment="Center" ToolTip="Show only containers in this state"/>
                        <Button x:Name="BtnView" Style="{DynamicResource Btn}" Margin="6,0,0,0" ToolTip="Switch between the list and cards (Ctrl+T)"/>
                        <Button x:Name="BtnPortainer" Content="Portainer" Tag="&#xE8A7;" Style="{DynamicResource Btn}" Margin="6,0,0,0"
                                ToolTip="Open Portainer on this machine. Starts it if it's stopped, or offers to install it. Right-click to update it or change its data folder."/>
                    </StackPanel>
                    <WrapPanel Grid.Column="2" HorizontalAlignment="Right" VerticalAlignment="Center">
                        <Button x:Name="BtnStart" Content="Start" Tag="&#xE768;" Style="{DynamicResource Btn}" ToolTip="Start the selected containers (creates them if needed)"/>
                        <Button x:Name="BtnStop" Content="Stop" Tag="&#xE71A;" Style="{DynamicResource Btn}" ToolTip="Stop the selected containers"/>
                        <Button x:Name="BtnRestart" Content="Restart" Tag="&#xE72C;" Style="{DynamicResource Btn}" ToolTip="Restart the selected containers"/>
                        <Button x:Name="BtnUpdate" Content="Update" Tag="&#xE896;" Style="{DynamicResource Btn}"
                                ToolTip="Pull the newest images and recreate the selected containers. Stopped ones stay stopped."/>
                        <Button x:Name="BtnConfigure" Content="Configure" Tag="&#xE713;" Style="{DynamicResource Btn}"
                                ToolTip="Environment variables, API keys and passwords, host folders and a shell for the selected container (Ctrl+E)"/>
                        <Button x:Name="BtnLogs" Content="Logs" Tag="&#xE9F9;" Style="{DynamicResource Btn}" ToolTip="Show the logs of the selected container (Ctrl+L)"/>
                        <Button x:Name="BtnSource" Content="Source" Tag="&#xE71B;" Style="{DynamicResource Btn}" ToolTip="Open the selected container's project page (GitHub, GitLab or Docker Hub)"/>
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
                            <Button x:Name="BtnAutoGroup" Content="Group automatically..." Tag="&#xE8FD;" Style="{DynamicResource Btn}" Visibility="Collapsed"
                                    ToolTip="Suggest a group for each container that has none, from its image name. You see the list and can change it before anything is saved."/>
                            <Button x:Name="BtnApply" Tag="&#xE73E;" Style="{DynamicResource PrimaryBtn}" Visibility="Collapsed"
                                    ToolTip="Recreate the containers whose settings changed in the compose file. Stopped ones stay stopped."/>
                            <Button x:Name="BtnGroupStart" Content="Start group" Tag="&#xE768;" Style="{DynamicResource Btn}"/>
                            <Button x:Name="BtnGroupStop" Content="Stop group" Tag="&#xE71A;" Style="{DynamicResource Btn}"/>
                            <Button x:Name="BtnGroupUpdate" Content="Update group" Tag="&#xE896;" Style="{DynamicResource Btn}"/>
                            <Button x:Name="BtnRemoveOrphans" Content="Remove all" Tag="&#xE74D;" Style="{DynamicResource Btn}" Visibility="Collapsed"
                                    ToolTip="Remove these containers. Their data folders are not touched."/>
                            <Button x:Name="BtnCheckUpdates" Content="Check for updates" Tag="&#xE895;" Style="{DynamicResource Btn}"
                                    ToolTip="Ask each image's registry whether a newer image is out. Nothing is downloaded."/>
                            <Button x:Name="BtnExport" Content="Export..." Tag="&#xEDE1;" Style="{DynamicResource Btn}" ToolTip="Save the list as a web page (HTML) to keep, print or send"/>
                            <Button x:Name="BtnRefresh" Content="Refresh" Tag="&#xE72C;" Style="{DynamicResource Btn}" Margin="0" ToolTip="Read the compose file and status again (F5)"/>
                        </WrapPanel>
                    </Grid>
                </Border>

                <!-- Grid -->
                <Border Grid.Row="2" Background="{DynamicResource Card}" BorderBrush="{DynamicResource Edge}" BorderThickness="1" CornerRadius="8">
                    <Grid>
                        <DataGrid x:Name="Grid" AutoGenerateColumns="False" IsReadOnly="True" HeadersVisibility="Column"
                                  GridLinesVisibility="None" BorderThickness="0" Background="Transparent"
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
                                    <Setter Property="Background" Value="Transparent"/>
                                    <Setter Property="ToolTip" Value="{Binding Description}"/>
                                    <Setter Property="BorderThickness" Value="4,0,0,0"/>
                                    <Setter Property="BorderBrush" Value="Transparent"/>
                                    <Style.Triggers>
                                        <Trigger Property="IsMouseOver" Value="True">
                                            <Setter Property="Background" Value="{DynamicResource Hover}"/>
                                        </Trigger>
                                        <Trigger Property="IsSelected" Value="True">
                                            <Setter Property="Background" Value="{DynamicResource Selected}"/>
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
                                                        <StackPanel Margin="0,2,0,2">
                                                            <ToggleButton x:Name="Toggle" IsChecked="True" Focusable="False" Cursor="Hand">
                                                                <ToggleButton.Template>
                                                                    <ControlTemplate TargetType="ToggleButton">
                                                                        <Border Background="Transparent" Padding="4,5,4,5">
                                                                            <StackPanel Orientation="Horizontal">
                                                                                <TextBlock x:Name="Chevron" Text="&#xE70D;" FontFamily="Segoe MDL2 Assets" FontSize="10"
                                                                                           VerticalAlignment="Center" Margin="2,0,8,0" Foreground="{DynamicResource SoftInk}"/>
                                                                                <Border Width="4" Height="16" CornerRadius="2" Margin="0,0,8,0" Background="{Binding Items[0].GroupColor}"/>
                                                                                <TextBlock Text="{Binding Name}" FontWeight="SemiBold" Foreground="{DynamicResource Ink}"/>
                                                                                <TextBlock Text="{Binding ItemCount, StringFormat=' ({0})'}" Foreground="{DynamicResource SoftInk}"/>
                                                                            </StackPanel>
                                                                        </Border>
                                                                        <ControlTemplate.Triggers>
                                                                            <Trigger Property="IsChecked" Value="False">
                                                                                <Setter TargetName="Chevron" Property="Text" Value="&#xE76C;"/>
                                                                            </Trigger>
                                                                        </ControlTemplate.Triggers>
                                                                    </ControlTemplate>
                                                                </ToggleButton.Template>
                                                            </ToggleButton>
                                                            <ItemsPresenter x:Name="Items"/>
                                                        </StackPanel>
                                                        <ControlTemplate.Triggers>
                                                            <Trigger SourceName="Toggle" Property="IsChecked" Value="False">
                                                                <Setter TargetName="Items" Property="Visibility" Value="Collapsed"/>
                                                            </Trigger>
                                                        </ControlTemplate.Triggers>
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
                                <DataGridTemplateColumn Header="Container" Width="225" MinWidth="200" SortMemberPath="Service">
                                    <DataGridTemplateColumn.CellTemplate>
                                        <DataTemplate>
                                            <DockPanel>
                                                <Grid DockPanel.Dock="Left" Width="20" Height="20" Margin="0,0,8,0">
                                                    <Border x:Name="Tile" CornerRadius="4" Background="{Binding GroupColor}">
                                                        <TextBlock Text="{Binding Initial}" Foreground="#FFFFFF" FontSize="11" FontWeight="Bold"
                                                                   HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                                    </Border>
                                                    <Image Source="{Binding Icon}" RenderOptions.BitmapScalingMode="HighQuality"/>
                                                </Grid>
                                                <TextBlock Text="{Binding Service}" FontWeight="SemiBold" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
                                            </DockPanel>
                                            <DataTemplate.Triggers>
                                                <DataTrigger Binding="{Binding HasIcon}" Value="True">
                                                    <Setter TargetName="Tile" Property="Visibility" Value="Collapsed"/>
                                                </DataTrigger>
                                            </DataTemplate.Triggers>
                                        </DataTemplate>
                                    </DataGridTemplateColumn.CellTemplate>
                                </DataGridTemplateColumn>
                                <DataGridTextColumn Header="State" Binding="{Binding StateText}" Width="110" MinWidth="100"/>
                                <DataGridTextColumn Header="Since" Binding="{Binding Since}" Width="110" MinWidth="100"/>
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
                                        <Style TargetType="TextBlock"><Setter Property="Foreground" Value="{DynamicResource SoftInk}"/><Setter Property="TextTrimming" Value="CharacterEllipsis"/><Setter Property="ToolTip" Value="{Binding Image}"/></Style>
                                    </DataGridTextColumn.ElementStyle>
                                </DataGridTextColumn>
                                <DataGridTextColumn Header="Note" Binding="{Binding Note}" Width="240" MinWidth="220">
                                    <DataGridTextColumn.ElementStyle>
                                        <Style TargetType="TextBlock"><Setter Property="Foreground" Value="{DynamicResource NoteInk}"/><Setter Property="TextTrimming" Value="CharacterEllipsis"/><Setter Property="ToolTip" Value="{Binding Note}"/></Style>
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
                                    <MenuItem x:Name="MnuConfigure" Header="Configure..."/>
                                    <MenuItem x:Name="MnuLogs" Header="Logs"/>
                                    <MenuItem x:Name="MnuOpen" Header="Open web page"/>
                                    <MenuItem x:Name="MnuSource" Header="Source page"/>
                                    <MenuItem x:Name="MnuCopy" Header="Copy name"/>
                                    <MenuItem x:Name="MnuSourceList" Header="Edit source links..." ToolTip="Your own list of project pages, kept on this PC"/>
                                    <Separator/>
                                    <MenuItem x:Name="MnuRemove" Header="Remove container..."/>
                                </ContextMenu>
                            </DataGrid.ContextMenu>
                        </DataGrid>
                        <ListBox x:Name="Cards" Visibility="Collapsed" BorderThickness="0" Background="Transparent" Margin="6,2,2,2"
                                 SelectionMode="Extended" IsSynchronizedWithCurrentItem="False"
                                 ScrollViewer.HorizontalScrollBarVisibility="Disabled" ScrollViewer.CanContentScroll="False"
                                 VirtualizingPanel.IsVirtualizing="False">
                            <ListBox.ItemsPanel>
                                <ItemsPanelTemplate><WrapPanel/></ItemsPanelTemplate>
                            </ListBox.ItemsPanel>
                            <ListBox.GroupStyle>
                                <GroupStyle>
                                    <GroupStyle.HeaderTemplate>
                                        <DataTemplate>
                                            <StackPanel Orientation="Horizontal" Margin="2,8,0,8">
                                                <Border Width="4" Height="16" CornerRadius="2" Margin="0,0,8,0" Background="{Binding Items[0].GroupColor}"/>
                                                <TextBlock Text="{Binding Name}" FontWeight="SemiBold" Foreground="{DynamicResource Ink}"/>
                                                <TextBlock Text="{Binding ItemCount, StringFormat=' ({0})'}" Foreground="{DynamicResource SoftInk}"/>
                                            </StackPanel>
                                        </DataTemplate>
                                    </GroupStyle.HeaderTemplate>
                                </GroupStyle>
                            </ListBox.GroupStyle>
                            <ListBox.ItemContainerStyle>
                                <Style TargetType="ListBoxItem">
                                    <Setter Property="Margin" Value="0,0,8,8"/>
                                    <Setter Property="Template">
                                        <Setter.Value>
                                            <ControlTemplate TargetType="ListBoxItem">
                                                <Border x:Name="Sel" BorderThickness="2" BorderBrush="Transparent" CornerRadius="10" Background="Transparent">
                                                    <ContentPresenter/>
                                                </Border>
                                                <ControlTemplate.Triggers>
                                                    <Trigger Property="IsMouseOver" Value="True">
                                                        <Setter TargetName="Sel" Property="BorderBrush" Value="{DynamicResource Edge}"/>
                                                    </Trigger>
                                                    <Trigger Property="IsSelected" Value="True">
                                                        <Setter TargetName="Sel" Property="BorderBrush" Value="{DynamicResource Accent}"/>
                                                    </Trigger>
                                                </ControlTemplate.Triggers>
                                            </ControlTemplate>
                                        </Setter.Value>
                                    </Setter>
                                </Style>
                            </ListBox.ItemContainerStyle>
                            <ListBox.ItemTemplate>
                                <DataTemplate>
                                    <Border x:Name="Card" Width="246" Height="120" CornerRadius="8" Background="{DynamicResource Card}"
                                            BorderBrush="{DynamicResource Edge}" BorderThickness="1" ToolTip="{Binding Description}">
                                        <Grid>
                                            <Grid.RowDefinitions>
                                                <RowDefinition Height="4"/>
                                                <RowDefinition Height="*"/>
                                            </Grid.RowDefinitions>
                                            <Border CornerRadius="7,7,0,0" Background="{Binding GroupColor}"/>
                                            <Grid Grid.Row="1" Margin="10,8,6,6">
                                                <Grid.ColumnDefinitions>
                                                    <ColumnDefinition Width="Auto"/>
                                                    <ColumnDefinition Width="*"/>
                                                </Grid.ColumnDefinitions>
                                                <Grid.RowDefinitions>
                                                    <RowDefinition Height="*"/>
                                                    <RowDefinition Height="Auto"/>
                                                </Grid.RowDefinitions>
                                                <Grid Width="36" Height="36" VerticalAlignment="Top" Margin="0,0,10,0">
                                                    <Border x:Name="Tile" CornerRadius="8" Background="{Binding GroupColor}">
                                                        <TextBlock Text="{Binding Initial}" Foreground="#FFFFFF" FontSize="17" FontWeight="SemiBold"
                                                                   HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                                    </Border>
                                                    <Image Source="{Binding Icon}" RenderOptions.BitmapScalingMode="HighQuality"/>
                                                </Grid>
                                                <StackPanel Grid.Column="1">
                                                    <DockPanel>
                                                        <Ellipse Style="{DynamicResource Dot}" DockPanel.Dock="Right" Margin="6,0,4,0" VerticalAlignment="Center"/>
                                                        <TextBlock Text="{Binding Service}" FontWeight="SemiBold" FontSize="14" TextTrimming="CharacterEllipsis"/>
                                                    </DockPanel>
                                                    <StackPanel Orientation="Horizontal" Margin="0,2,0,0">
                                                        <TextBlock Text="{Binding StateText}" Foreground="{DynamicResource SoftInk}" FontSize="12"/>
                                                        <TextBlock x:Name="SinceText" Text="{Binding Since, StringFormat='  ·  {0}'}" Foreground="{DynamicResource SoftInk}"
                                                                   FontSize="12" TextTrimming="CharacterEllipsis" MaxWidth="120"/>
                                                    </StackPanel>
                                                    <TextBlock Text="{Binding Note}" Foreground="{DynamicResource NoteInk}" FontSize="12" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
                                                </StackPanel>
                                                <DockPanel Grid.Row="1" Grid.ColumnSpan="2" LastChildFill="False" Margin="0,4,0,0">
                                                    <Button DockPanel.Dock="Left" Style="{DynamicResource LinkBtn}" Content="{Binding Ports}" Tag="{Binding Url}" ToolTip="{Binding Url}"
                                                            VerticalAlignment="Center" Visibility="{Binding HasUrl, Converter={StaticResource B2V}}"/>
                                                    <Button x:Name="BLogs" DockPanel.Dock="Right" Style="{DynamicResource IconBtn}" Tag="&#xE9F9;" CommandParameter="logs" ToolTip="Logs"/>
                                                    <Button x:Name="BConf" DockPanel.Dock="Right" Style="{DynamicResource IconBtn}" Tag="&#xE713;" CommandParameter="configure" ToolTip="Configure"/>
                                                    <Button x:Name="BStop" DockPanel.Dock="Right" Style="{DynamicResource IconBtn}" Tag="&#xE71A;" CommandParameter="stop" ToolTip="Stop"/>
                                                    <Button x:Name="BStart" DockPanel.Dock="Right" Style="{DynamicResource IconBtn}" Tag="&#xE768;" CommandParameter="start" ToolTip="Start"/>
                                                </DockPanel>
                                            </Grid>
                                        </Grid>
                                    </Border>
                                    <DataTemplate.Triggers>
                                        <DataTrigger Binding="{Binding HasIcon}" Value="True">
                                            <Setter TargetName="Tile" Property="Visibility" Value="Collapsed"/>
                                        </DataTrigger>
                                        <DataTrigger Binding="{Binding IsRunning}" Value="True">
                                            <Setter TargetName="BStart" Property="Visibility" Value="Collapsed"/>
                                        </DataTrigger>
                                        <DataTrigger Binding="{Binding IsRunning}" Value="False">
                                            <Setter TargetName="BStop" Property="Visibility" Value="Collapsed"/>
                                        </DataTrigger>
                                        <DataTrigger Binding="{Binding HasContainer}" Value="False">
                                            <Setter TargetName="BLogs" Property="Visibility" Value="Collapsed"/>
                                        </DataTrigger>
                                        <DataTrigger Binding="{Binding InCompose}" Value="False">
                                            <Setter TargetName="BConf" Property="Visibility" Value="Collapsed"/>
                                        </DataTrigger>
                                        <DataTrigger Binding="{Binding Since}" Value="">
                                            <Setter TargetName="SinceText" Property="Visibility" Value="Collapsed"/>
                                        </DataTrigger>
                                        <DataTrigger Binding="{Binding Description}" Value="">
                                            <Setter TargetName="Card" Property="ToolTip" Value="{x:Null}"/>
                                        </DataTrigger>
                                    </DataTemplate.Triggers>
                                </DataTemplate>
                            </ListBox.ItemTemplate>
                        </ListBox>
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
foreach ($name in 'ImgLogo', 'HeaderTitle', 'HeaderButtons', 'TxtSubtitle', 'TxtProject', 'CmbMachine', 'BtnSend', 'CmbRecent', 'PnlRecent', 'TxtRecentCaption', 'BtnBrowse', 'BtnEditCompose', 'BtnEditEnv', 'BtnCheck', 'BtnDisk', 'BtnFolder', 'BtnSettings', 'BtnHelp', 'BtnAbout',
    'Banner', 'BannerGlyph', 'BannerText', 'CmbEnvTemplate', 'BannerAction', 'BannerRetry',
    'LstGroups', 'TxtSearch', 'SearchHint', 'CmbState', 'BtnView', 'BtnPortainer', 'BtnStart', 'BtnStop', 'BtnRestart', 'BtnUpdate', 'BtnConfigure', 'BtnLogs', 'BtnSource', 'BtnOpen',
    'TxtGroupName', 'TxtGroupInfo', 'BtnAutoGroup', 'BtnApply', 'BtnGroupStart', 'BtnGroupStop', 'BtnGroupUpdate', 'BtnRemoveOrphans', 'BtnCheckUpdates', 'BtnExport', 'BtnRefresh',
    'Grid', 'Cards', 'TxtEmpty', 'RowMenu', 'MnuStart', 'MnuStop', 'MnuRestart', 'MnuUpdate', 'MnuRecreate', 'MnuConfigure', 'MnuLogs', 'MnuOpen', 'MnuSource', 'MnuCopy', 'MnuSourceList', 'MnuRemove',
    'LogRow', 'LogSplitter', 'LogPane', 'BtnLogCopy', 'BtnLogClear', 'TxtLog', 'TxtStatus', 'PrgBusy', 'TxtBusy', 'BtnCancel', 'ChkActivity') {
    $ui[$name] = $window.FindName($name)
}
if (-not $ui.MnuStart) {
    # Names inside a ContextMenu can sit outside the window's name scope.
    foreach ($item in $ui.Grid.ContextMenu.Items) { if ($item.Name) { $ui[$item.Name] = $item } }
}
if (-not $ui.RowMenu) { $ui.RowMenu = $ui.Grid.ContextMenu }
Set-MenuTheme $ui.RowMenu $window
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
    $p = $script:Pal
    $colours = @{ info = @($p.InfoBg, $p.InfoEdge, [char]0xE946); warn = @($p.WarnBg, $p.WarnEdge, [char]0xE7BA); error = @($p.ErrorBg, $p.ErrorEdge, [char]0xEA39) }
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
    $m = Get-Machine
    if ($m -and $script:ComposePath -and (Test-Path -LiteralPath $script:ComposePath)) {
        if (-not (Find-Ssh)) {
            Show-Banner -Kind error -Text "ssh.exe wasn't found, so $($m.Name) can't be reached. Turn on the OpenSSH Client in Windows Settings > System > Optional features."
            return
        }
        if ($script:DockerState -eq 'down') {
            Show-Banner -Kind warn -Text "$($m.Name) can't be reached over SSH, or Docker isn't running there, so the status below may be out of date. $script:RemoteError" `
                -Action @{ Text = 'Machines...'; Glyph = [string][char]0xE713; Click = { Show-Machines } }
            return
        }
        if ($script:ConfigError) {
            Show-Banner -Kind error -Text ("$($m.Name) couldn't read its compose file, so the list shows the last version that worked. Docker says: " + $script:ConfigError + " Send to machine copies the compose file and .env there.") `
                -Action @{ Text = 'Send to machine...'; Glyph = [string][char]0xE898; Click = { Invoke-SendToMachine } }
            return
        }
        Hide-Banner
        return
    }
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
    $editor = Resolve-EditorPath $script:Settings.Editor
    try {
        if ($editor -and (Test-Path -LiteralPath $editor -PathType Leaf)) {
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
# Container settings: reading and changing one service's environment.
# The compose file and .env are edited as text, line by line, so comments,
# order and spacing elsewhere stay exactly as they were.
# ---------------------------------------------------------------------------
$script:SecretNamePattern = '(PASSWORD|PASSWD|_PASS$|^PASS$|SECRET|TOKEN|API_?KEY|APIKEY|PRIVATE_KEY|CLAIM|CREDENTIAL)'

function Read-TextFile([string]$Path) {
    # Returns the lines plus what's needed to write the file back the same way.
    $bytes = [IO.File]::ReadAllBytes($Path)
    $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text = (New-Object System.Text.UTF8Encoding($false)).GetString($bytes)
    if ($bom) { $text = $text.Substring(1) }
    $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $endsWithNewline = $text.EndsWith("`n")
    if ($endsWithNewline) { $text = $text.Substring(0, $text.Length - $nl.Length) }
    $lines = New-Object System.Collections.Generic.List[string]
    if ($text.Length) { $lines.AddRange([string[]]($text -split "`r?`n")) }
    return @{ Path = $Path; Lines = $lines; Bom = $bom; NewLine = $nl; EndsWithNewline = $endsWithNewline }
}

function Write-TextFile($File) {
    $text = ($File.Lines.ToArray() -join $File.NewLine)
    if ($File.EndsWithNewline -or $File.Lines.Count -eq 0) { $text += $File.NewLine }
    $tmp = $File.Path + '.dcm-tmp'
    [IO.File]::WriteAllText($tmp, $text, (New-Object System.Text.UTF8Encoding($File.Bom)))
    Move-Item -LiteralPath $tmp -Destination $File.Path -Force
}

function Get-LineIndent([string]$Line) { return $Line.Length - $Line.TrimStart(' ').Length }

function Test-ContentLine([string]$Line) {
    $t = $Line.Trim()
    return ($t -ne '' -and -not $t.StartsWith('#'))
}

function Find-ServiceEnv($Lines, [string]$Service) {
    # Finds the service block and its environment: section in the compose text.
    $res = @{ Found = $false; Start = -1; End = -1; KeyIndent = -1; EnvLine = -1; Form = ''; ItemIndent = -1; Entries = @(); EnvFiles = @() }
    $inServices = $false; $svcIndent = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $l = $Lines[$i]
        if (-not (Test-ContentLine $l)) { continue }
        $ind = Get-LineIndent $l
        if ($ind -eq 0) {
            if ($res.Found -and $res.End -lt 0) { $res.End = $i - 1; break }
            $inServices = ($l -match '^services\s*:')
            continue
        }
        if (-not $inServices) { continue }
        if ($svcIndent -lt 0) { $svcIndent = $ind }
        if ($ind -eq $svcIndent) {
            if ($res.Found) { $res.End = $i - 1; break }
            $m = [regex]::Match($l.Trim(), '^("([^"]+)"|''([^'']+)''|([^\s:#]+))\s*:\s*$')
            if ($m.Success) {
                $name = @($m.Groups[2].Value, $m.Groups[3].Value, $m.Groups[4].Value) | Where-Object { $_ } | Select-Object -First 1
                if ($name -eq $Service) { $res.Found = $true; $res.Start = $i }
            }
        }
    }
    if (-not $res.Found) { return $res }
    if ($res.End -lt 0) { $res.End = $Lines.Count - 1 }
    # Trim trailing blank/comment lines that belong between services.
    while ($res.End -gt $res.Start -and -not (Test-ContentLine $Lines[$res.End])) { $res.End-- }

    for ($i = $res.Start + 1; $i -le $res.End; $i++) {
        if (Test-ContentLine $Lines[$i]) { $res.KeyIndent = Get-LineIndent $Lines[$i]; break }
    }
    if ($res.KeyIndent -lt 0) { return $res }

    $entries = New-Object System.Collections.ArrayList
    $envFiles = New-Object System.Collections.ArrayList
    $section = ''
    for ($i = $res.Start + 1; $i -le $res.End; $i++) {
        $l = $Lines[$i]
        if (-not (Test-ContentLine $l)) { continue }
        $ind = Get-LineIndent $l
        $t = $l.Trim()
        if ($ind -eq $res.KeyIndent) {
            $section = ''
            if ($t -match '^environment\s*:\s*$') { $section = 'environment'; $res.EnvLine = $i }
            elseif ($t -match '^env_file\s*:\s*(.*)$') {
                $section = 'env_file'
                $v = (Remove-YamlComment $Matches[1]).Trim()
                if ($v) { [void]$envFiles.Add((Get-Unquoted $v)) }
            }
            continue
        }
        if ($ind -lt $res.KeyIndent) { continue }
        if ($section -eq 'env_file') {
            if ($t -match '^-\s*(.+)$') { [void]$envFiles.Add((Get-Unquoted (Remove-YamlComment $Matches[1]))) }
            elseif ($t -match '^path\s*:\s*(.+)$') { [void]$envFiles.Add((Get-Unquoted (Remove-YamlComment $Matches[1]))) }
            continue
        }
        if ($section -ne 'environment') { continue }
        if ($res.ItemIndent -lt 0) { $res.ItemIndent = $ind }
        if ($ind -ne $res.ItemIndent) { continue }
        $body = Remove-YamlComment $t
        if ($body -match '^-\s*(.*)$') {
            if (-not $res.Form) { $res.Form = 'list' }
            $item = $Matches[1]
            $quote = ''
            if ($item.Length -ge 2 -and ($item[0] -eq '"' -or $item[0] -eq "'") -and $item[-1] -eq $item[0]) { $quote = [string]$item[0]; $item = $item.Substring(1, $item.Length - 2) }
            $eq = $item.IndexOf('=')
            $n = if ($eq -ge 0) { $item.Substring(0, $eq).Trim() } else { $item.Trim() }
            $v = if ($eq -ge 0) { $item.Substring($eq + 1) } else { $null }
            [void]$entries.Add(@{ Name = $n; Raw = $v; Line = $i; Form = 'list'; Quote = $quote })
        } elseif ($body -match '^("([^"]+)"|''([^'']+)''|([^\s:#]+))\s*:\s*(.*)$') {
            if (-not $res.Form) { $res.Form = 'map' }
            $n = @($Matches[2], $Matches[3], $Matches[4]) | Where-Object { $_ } | Select-Object -First 1
            $rawValue = $Matches[5]
            $quote = ''
            if ($rawValue.Length -ge 2 -and ($rawValue[0] -eq '"' -or $rawValue[0] -eq "'") -and $rawValue[-1] -eq $rawValue[0]) {
                $quote = [string]$rawValue[0]; $rawValue = $rawValue.Substring(1, $rawValue.Length - 2)
            }
            if ($rawValue -eq '' -and -not $quote) { $rawValue = $null }
            [void]$entries.Add(@{ Name = $n; Raw = $rawValue; Line = $i; Form = 'map'; Quote = $quote })
        }
    }
    $res.Entries = @($entries)
    $res.EnvFiles = @($envFiles)
    return $res
}

function Get-EnvFileValues([string]$Path) {
    # Name -> @{ Value; Line } for a .env-style file (keeps the first definition, like Compose).
    $map = @{}
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $map }
    $f = Read-TextFile $Path
    for ($i = 0; $i -lt $f.Lines.Count; $i++) {
        if ($f.Lines[$i] -match '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
            if ($map.ContainsKey($Matches[1])) { continue }
            $v = $Matches[2].Trim()
            if ($v.Length -ge 2 -and $v[0] -eq "'" -and $v[-1] -eq "'") { $v = $v.Substring(1, $v.Length - 2) }
            elseif ($v.Length -ge 2 -and $v[0] -eq '"' -and $v[-1] -eq '"') { $v = $v.Substring(1, $v.Length - 2).Replace('\"', '"').Replace('\\', '\') }
            else { $v = ($v -replace '\s+#.*$', '') }
            $map[$Matches[1]] = @{ Value = $v; Line = $i }
        }
    }
    return $map
}

function Format-EnvFileValue([string]$Value) {
    if ($Value -match '^[A-Za-z0-9_./:@+,=%-]*$') { return $Value }
    if (-not $Value.Contains("'")) { return "'$Value'" }
    return '"' + $Value.Replace('\', '\\').Replace('"', '\"').Replace('$', '$$') + '"'
}

function Set-EnvFileValue($File, [string]$Name, [string]$Value) {
    # Changes NAME=... in place, or adds it at the end.
    $line = '{0}={1}' -f $Name, (Format-EnvFileValue $Value)
    for ($i = 0; $i -lt $File.Lines.Count; $i++) {
        if ($File.Lines[$i] -match ('^\s*(?:export\s+)?' + [regex]::Escape($Name) + '\s*=')) { $File.Lines[$i] = $line; return }
    }
    while ($File.Lines.Count -and $File.Lines[$File.Lines.Count - 1].Trim() -eq '') { $File.Lines.RemoveAt($File.Lines.Count - 1) }
    $File.Lines.Add($line)
    $File.EndsWithNewline = $true
}

function Format-ComposeEnvLine([int]$Indent, [string]$Form, [string]$Name, [string]$Value) {
    # $Value is written as-is (callers escape a literal '$' as '$$').
    $pad = ' ' * $Indent
    $plain = '^[A-Za-z0-9_./:@+,=%${}-]*$'
    if ($Form -eq 'map') {
        if ($Value -match $plain -and $Value -ne '') { return '{0}{1}: {2}' -f $pad, $Name, $Value }
        return "{0}{1}: '{2}'" -f $pad, $Name, $Value.Replace("'", "''")
    }
    $item = '{0}={1}' -f $Name, $Value
    if ($Value -match $plain) { return '{0}- {1}' -f $pad, $item }
    return "{0}- '{1}'" -f $pad, $item.Replace("'", "''")
}

function Get-EnvVarReference([string]$Raw) {
    # '${NAME}' or '${NAME:-default}' as the whole value -> NAME, otherwise ''.
    if ($null -eq $Raw) { return '' }
    $m = [regex]::Match($Raw.Trim(), '^\$\{([A-Za-z_][A-Za-z0-9_]*)(:?[-?][^}]*)?\}$')
    if ($m.Success) { return $m.Groups[1].Value }
    $m = [regex]::Match($Raw.Trim(), '^\$([A-Za-z_][A-Za-z0-9_]*)$')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}

function Get-VarUseCount($Lines, [string]$Var) {
    $n = 0
    $pattern = '\$\{' + [regex]::Escape($Var) + '([:?}-])|\$' + [regex]::Escape($Var) + '(?![A-Za-z0-9_])'
    foreach ($l in $Lines) { if ((Test-ContentLine $l) -and $l -match $pattern) { $n++ } }
    return $n
}

function New-EnvVarName([string]$Service, [string]$Name, [hashtable]$Existing, [string]$Value) {
    $svc = ($Service.ToUpperInvariant() -replace '[^A-Z0-9]+', '_').Trim('_')
    $base = ($Name.ToUpperInvariant() -replace '[^A-Z0-9_]+', '_').Trim('_')
    if (-not $base) { $base = 'VALUE' }
    if (-not $base.StartsWith($svc + '_') -and $base -ne $svc) { $base = '{0}_{1}' -f $svc, $base }
    if ($base -match '^[0-9]') { $base = '_' + $base }
    $candidate = $base; $n = 2
    while ($Existing.ContainsKey($candidate) -and $Existing[$candidate].Value -ne $Value) { $candidate = '{0}_{1}' -f $base, $n; $n++ }
    return $candidate
}

# ---------------------------------------------------------------------------
# Compose file choice
# ---------------------------------------------------------------------------
function Update-RecentList {
    $script:UpdatingRecent = $true
    try {
        $ui.CmbRecent.Items.Clear()
        # On another machine the list shows that machine's own compose file. The
        # file picked here is the one on this PC that Send to machine copies across.
        $m = Get-Machine
        $prefix = if ($m) { 'Send from: ' } else { '' }
        $ui.TxtRecentCaption.Text = if ($m) { "Master copy here, sent to $($m.Name)" } else { 'Compose file' }
        $ui.CmbRecent.ToolTip = if ($m) {
            "$($m.Name) uses its own copy: $(Get-RemoteComposePath $m)`nThe file picked here is on this PC and is remembered for $($m.Name). Send to machine copies it there, and Configure edits it."
        } else { "Switch to another compose file you've used on this PC" }
        foreach ($f in @($script:Settings.RecentFiles)) {
            $item = New-Object Windows.Controls.ComboBoxItem
            $item.Content = '{0}{1}  ({2})' -f $prefix, (Split-Path -Leaf (Split-Path -Parent $f)), $f
            $item.Tag = $f
            $item.ToolTip = $f
            if ($f -eq $script:ComposePath) { $item.FontWeight = 'SemiBold' }
            else {
                # Right-click: take it off this list (the file itself is never touched).
                $menu = New-Object Windows.Controls.ContextMenu
                $rm = New-Object Windows.Controls.MenuItem -Property @{ Header = 'Remove from list'; Tag = $f; ToolTip = "Takes it off this list only. The file stays where it is:`n$f" }
                $rm.Add_Click({ Remove-RecentFile ([string]$this.Tag) })
                [void]$menu.Items.Add($rm)
                Set-MenuTheme $menu $window
                $item.ContextMenu = $menu
            }
            [void]$ui.CmbRecent.Items.Add($item)
            if ($f -eq $script:ComposePath) { $ui.CmbRecent.SelectedItem = $item }
        }
        # Last entry: pick a compose file that isn't in the list yet.
        if ($ui.CmbRecent.Items.Count) { [void]$ui.CmbRecent.Items.Add((New-Object Windows.Controls.Separator)) }
        $other = New-Object Windows.Controls.ComboBoxItem
        $other.Content = 'Other compose file...'
        $other.Tag = $script:OtherComposeTag
        $other.FontStyle = 'Italic'
        $other.ToolTip = 'Choose a compose file anywhere on this PC (the same as the Compose file... button)'
        [void]$ui.CmbRecent.Items.Add($other)
        $ui.PnlRecent.Visibility = if (@($script:Settings.RecentFiles).Count) { 'Visible' } else { 'Collapsed' }
    } finally {
        $script:UpdatingRecent = $false
    }
}

# The Tag of the "Other compose file..." entry: never a path, never saved.
$script:OtherComposeTag = '<other>'

# Takes a compose file off the list in the header (settings.json only, never the file on disk).
function Remove-RecentFile([string]$Path) {
    if (-not $Path -or $Path -eq $script:ComposePath) { return }
    $script:Settings.RecentFiles = @($script:Settings.RecentFiles | Where-Object { $_ -and $_ -ne $Path })
    Save-Settings
    Update-RecentList
    Write-Activity "Took $Path off the compose file list. The file itself wasn't touched."
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
    # Each machine remembers its own compose file on this PC; Settings.ComposeFile is This PC's.
    $m = Get-Machine
    if ($m) { $m.ComposeFile = $full } else { $script:Settings.ComposeFile = $full }
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
    $ui.TxtSubtitle.Text = Get-ComposeDisplay
    $ui.TxtSubtitle.ToolTip = $ui.TxtSubtitle.Text
    $ui.TxtProject.Text = ''
    Write-Activity "Compose file: $full"
    Request-ConfigLoad
}

function Get-ComposeDisplay {
    $m = Get-Machine
    if ($m) { return ('{0}: {1}' -f $m.Name, (Get-RemoteComposePath $m)) }
    return $script:ComposePath
}

function Get-FileStamp {
    if (-not $script:ComposePath) { return '' }
    $parts = foreach ($f in @($script:ComposePath, (Get-ConfigureEnvPath))) {
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
    if (-not $script:ComposePath -or -not (Test-Path -LiteralPath $script:ComposePath) -or -not (Test-DockerReady)) { Update-Banner; Update-View; return }
    if ($script:ConfigLoading) { $script:ConfigWanted = $true; return }
    $script:ConfigLoading = $true
    $script:LoadingGen = $script:ConfigGen
    Set-Status 'Reading the compose file...'
    if ($script:CheckForm) { Update-CheckWindow } else { Update-CheckBadge }
    # --no-env-resolution: a missing env_file on this machine shouldn't hide the whole list.
    # Compose before 2.24 (Synology ships 2.20) doesn't know --no-env-resolution.
    $cfgArgs = @('config', '--format', 'json')
    if (-not $script:OldCompose) { $cfgArgs += '--no-env-resolution' }
    Start-DockerCall -Compose -Arguments $cfgArgs -OnDone {
        param($res)
        if ($script:LoadingGen -ne $script:ConfigGen) { $script:ConfigLoading = $false; $script:ConfigWanted = $true; return }
        if ($res.ExitCode -ne 0 -and -not $script:OldCompose -and $res.Error -match 'unknown flag: --no-env-resolution') {
            $script:OldCompose = $true
            $script:ConfigLoading = $false
            Request-ConfigLoad
            return
        }
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
            if ($script:MyGroupsAuto) { $script:MyGroupsAuto = -not (Initialize-MyGroupsFile) }
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
    # A list with one label comes back as a plain string.
    if ($raw -is [string]) { $raw = @($raw) }
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
    $script:ServiceConfigs = @{}
    $seen = @{}
    $added = 0
    if ($services) {
        foreach ($prop in $services.PSObject.Properties) {
            $name = $prop.Name
            $svc = $prop.Value
            $seen[$name] = $true
            $script:ServiceConfigs[$name] = $svc
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
            $colour = if ($labels.ContainsKey("$prefix.color")) { $labels["$prefix.color"].Trim() } else { '' }
            $row.ColorLabel = if ($colour -and (Test-Colour $colour)) { $colour } else { '' }
            $row.IconLabel = if ($labels.ContainsKey("$prefix.icon")) { $labels["$prefix.icon"].Trim() } else { '' }
            $row.SourceLabel = if ($labels.ContainsKey("$prefix.source")) { $labels["$prefix.source"].Trim() } else { '' }
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
    # Path on one line and project on the next, so neither is cut off.
    $ui.TxtSubtitle.Text = Get-ComposeDisplay
    $ui.TxtSubtitle.ToolTip = $ui.TxtSubtitle.Text
    $ui.TxtProject.Text = "Project $script:ProjectName   ·   $count services"
    Update-Banner
    Update-Groups
    Update-View -Refilter
    Update-Icons
    Start-LocalDigestScan
    $script:LastStatusSig = ''
    $script:NextPoll = [DateTime]::MinValue   # status straight away
}

function Test-Colour([string]$Text) {
    try { [void][Windows.Media.ColorConverter]::ConvertFromString($Text); return $true } catch { return $false }
}

# ---------------------------------------------------------------------------
# Live status (docker ps for this compose project)
# ---------------------------------------------------------------------------
$script:PsFormat = "{{.Label `"com.docker.compose.service`"}}`t{{.Label `"com.docker.compose.config-hash`"}}`t{{.State}}`t{{.Status}}`t{{.Names}}`t{{.Image}}`t{{.ID}}"

function Start-Poll {
    if ($script:PollRunning -or -not $script:ConfigLoaded -or -not $script:ProjectName) { return }
    $script:PollRunning = $true
    $script:PollProject = $script:ProjectName
    $script:PollMachine = [string]$script:Settings.Machine
    Start-DockerCall -Arguments @('ps', '-a', '--no-trunc', '--filter', "label=com.docker.compose.project=$script:ProjectName", '--format', $script:PsFormat) -OnDone {
        param($res)
        $script:PollRunning = $false
        $script:NextPoll = [DateTime]::Now.AddSeconds($(if ($window.IsVisible) { $script:Settings.RefreshSeconds } else { 30 }))
        # The machine was switched while docker ps was running: ignore this answer.
        if ($script:PollMachine -ne [string]$script:Settings.Machine) { $script:NextPoll = [DateTime]::MinValue; return }
        if ($res.ExitCode -ne 0) {
            $msg = Get-FirstLines $res.Error 2
            if ($script:DockerState -ne 'down') { Write-Activity "Docker isn't responding on $(Get-MachineName): $msg" }
            $script:DockerState = 'down'
            $script:RemoteError = $msg
            Update-Banner
            Update-Groups
            Set-Status $(if (Get-Machine) { "$(Get-MachineName) can't be reached." } else { "Docker isn't running." })
            return
        }
        # The compose file was switched while docker ps was running: ignore this answer.
        if (-not $script:ConfigLoaded -or $script:PollProject -ne $script:ProjectName) { $script:NextPoll = [DateTime]::MinValue; return }
        if ($script:DockerState -ne 'ok') {
            if ($script:DockerState -eq 'down') { Write-Activity "Docker is running again on $(Get-MachineName)." }
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
    elseif ($Row.UpdateAvailable) { $Row.Note = 'Update available' }
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
    if ($membership) { Update-Icons }
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
    # Colours: a home.color label wins, then the palette in name order.
    $labelColours = @{}
    foreach ($r in $script:Rows) {
        if ($r.InCompose -and $r.ColorLabel -and -not $labelColours.ContainsKey($r.Group)) { $labelColours[$r.Group] = $r.ColorLabel }
    }
    $colourOf = @{}
    for ($i = 0; $i -lt $names.Count; $i++) {
        $colourOf[$names[$i]] = if ($labelColours.ContainsKey($names[$i])) { $labelColours[$names[$i]] } else { $script:GroupPalette[$i % $script:GroupPalette.Count] }
    }
    $grey = $script:Pal.Off
    foreach ($g in $script:Groups) {
        $g.Color = if ($g.Key -eq '*') { $script:Pal.Accent } elseif ($g.Key.StartsWith('g:') -and $colourOf.ContainsKey($g.Name)) { $colourOf[$g.Name] } else { $grey }
    }
    foreach ($r in $script:Rows) {
        $r.GroupColor = if ($r.InCompose -and $colourOf.ContainsKey($r.Group)) { $colourOf[$r.Group] } else { $grey }
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
    $updates = @($rows | Where-Object UpdateAvailable).Count
    $ui.TxtGroupName.Text = $name
    if (-not $script:ComposePath) { $ui.TxtGroupInfo.Text = 'No compose file chosen yet.' }
    elseif ($key -eq '~orphans') { $ui.TxtGroupInfo.Text = "$($rows.Count) container(s) left over from services that were taken out of the compose file." }
    else {
        $info = '{0} running, {1} stopped' -f $running, ($rows.Count - $running)
        if ($problems) { $info += ", $problems need a look" }
        if ($changed) { $info += ", $changed changed in the compose file" }
        if ($updates) { $info += ", $updates with a newer image" }
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
    $ungrouped = @($script:Rows | Where-Object { $_.InCompose -and $_.Group -eq $script:UngroupedName }).Count
    $ui.BtnAutoGroup.Content = "Group automatically ($ungrouped)..."
    $ui.BtnAutoGroup.Visibility = if ($ungrouped -and -not $isOrphans) { 'Visible' } else { 'Collapsed' }
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
        'Updates available' { if (-not $r.UpdateAvailable) { return $false } }
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
        $list = Get-ListControl
        $keep = @($list.SelectedItems)
        Write-Trace "view refresh (group $script:SelectedGroupKey, keeping $($keep.Count) selected)"
        $script:View.Refresh()
        foreach ($r in $keep) { if ($script:Rows.Contains($r) -and $script:View.Contains($r)) { [void]$list.SelectedItems.Add($r) } }
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

# The list or the cards, whichever is showing.
function Get-ListControl { if ($script:Settings.ViewMode -eq 'Cards') { return $ui.Cards } return $ui.Grid }

function Get-SelectedRows { return @((Get-ListControl).SelectedItems | Where-Object { $_ -is [Dcm.Row] }) }

function Set-ViewMode([string]$Mode) {
    $cards = ($Mode -eq 'Cards')
    $to = if ($cards) { $ui.Cards } else { $ui.Grid }
    $other = if ($cards) { $ui.Grid } else { $ui.Cards }
    $keep = @($other.SelectedItems) + @($to.SelectedItems)
    $script:Settings.ViewMode = if ($cards) { 'Cards' } else { 'List' }
    $ui.BtnView.Content = if ($cards) { 'List' } else { 'Cards' }
    $ui.BtnView.Tag = [string][char]$(if ($cards) { 0xE8FD } else { 0xF0E2 })
    # Only the one on show is bound to the list, so the hidden one costs nothing.
    $other.ContextMenu = $null
    $other.ItemsSource = $null
    $other.Visibility = 'Collapsed'
    if (-not [object]::ReferenceEquals($to.ItemsSource, $script:View)) { $to.ItemsSource = $script:View }
    $to.ContextMenu = $ui.RowMenu
    $to.Visibility = 'Visible'
    foreach ($r in $keep) { if ($script:View.Contains($r) -and -not $to.SelectedItems.Contains($r)) { [void]$to.SelectedItems.Add($r) } }
    Update-SelectionButtons
}

function Update-SelectionButtons {
    $sel = Get-SelectedRows
    $any = ($sel.Count -gt 0)
    $inCompose = @($sel | Where-Object InCompose).Count
    $withContainer = @($sel | Where-Object HasContainer).Count
    $ui.BtnStart.IsEnabled = $any
    $ui.BtnStop.IsEnabled = (@($sel | Where-Object IsRunning).Count -gt 0)
    $ui.BtnRestart.IsEnabled = ($withContainer -gt 0)
    $ui.BtnUpdate.IsEnabled = ($inCompose -gt 0)
    $ui.BtnConfigure.IsEnabled = ($sel.Count -eq 1 -and $sel[0].InCompose)
    $ui.BtnLogs.IsEnabled = ($sel.Count -eq 1 -and $sel[0].HasContainer)
    $ui.BtnOpen.IsEnabled = ($sel.Count -eq 1 -and $sel[0].HasUrl)
    $ui.BtnSource.IsEnabled = ($sel.Count -eq 1)
    $ui.BtnSource.ToolTip = Get-SourceHint $(if ($sel.Count -eq 1) { $sel[0] } else { $null })
}

# ---------------------------------------------------------------------------
# Actions. Each job is a list of docker commands run one after another; jobs
# queue up and run one at a time, with their output in the activity log.
# ---------------------------------------------------------------------------
function Add-Job([string]$Label, [object[]]$Steps, [switch]$Reload, [scriptblock]$OnSuccess) {
    $steps = @($Steps | Where-Object { $_ })
    if (-not $steps.Count) { return }
    if (-not (Test-DockerReady)) {
        $what = if (Get-Machine) { "ssh.exe wasn't found" } else { "docker.exe wasn't found" }
        [void][Windows.MessageBox]::Show($window, "$what, so nothing can be started.", $script:AppName, 'OK', 'Warning'); return
    }
    $script:JobQueue.Enqueue(@{ Label = $Label; Steps = $steps; Index = 0; Runner = $null; Failed = $false; Reload = [bool]$Reload; OnSuccess = $OnSuccess })
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
        while ($n -lt 400 -and $r.Lines.TryDequeue([ref]$line)) { Write-Activity ('    ' + $line) -Plain; Add-ProgressLine $line; if ($line.Trim() -and $null -ne $job.StepLines -and $job.StepLines.Count -lt 200) { [void]$job.StepLines.Add($line.Trim()) }; $n++ }
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
        Show-JobProgress $job
        Start-JobStep $job
        Update-BusyState
    }
}

function Start-JobStep($Job) {
    $step = $Job.Steps[$Job.Index]
    $Job.StepLines = New-Object System.Collections.ArrayList
    try {
        if ($step.Exe -eq 'ssh') {
            $ssh = Find-Ssh
            if (-not $ssh) { throw "ssh.exe wasn't found." }
            $Job.Runner = New-Object Dcm.Runner($ssh, [string[]]$step.Args, $script:ComposeDir, $false, [string]$step.Stdin)
            $Job.Runner.CommandLine = $step.Display
        } else {
            $Job.Runner = New-DockerRunner ([string[]]$step.Args) $false
        }
        Write-Activity ('  > ' + (Get-ShortCommand $Job.Runner.CommandLine)) -Plain
        Update-JobProgress $Job
    } catch {
        $Job.Failed = $true
        Write-Activity "Couldn't start docker: $($_.Exception.Message)"
        $Job.StartError = "Couldn't start docker: $($_.Exception.Message)"
        Complete-Job $Job
    }
}

# Hides the -f/--project-directory noise in the log.
function Get-ShortCommand([string]$CommandLine) {
    return ($CommandLine -replace ' --ansi never --progress plain', '' -replace ' -f ("[^"]+"|\S+) --project-directory ("[^"]+"|\S+)( -p \S+)?', '')
}

function Complete-Job($Job) {
    Complete-JobProgress $Job
    $script:CurrentJob = $null
    Update-BusyState
    $script:NextPoll = [DateTime]::MinValue
    if ($Job.Reload) { Request-ConfigLoad }
    if (-not $Job.Failed -and $Job.OnSuccess) {
        try { & $Job.OnSuccess } catch { Write-Activity "Internal error: $($_.Exception.Message)" }
    }
    if (-not $script:JobQueue.Count) {
        Start-LocalDigestScan
        if ($script:DiskForm) { Update-DiskWindow }
    }
    [void]$script:FinishedJobs.Add(@{ Label = $Job.Label; Failed = [bool]$Job.Failed; Cancelled = [bool]$Job.Cancelled; Error = (Get-JobErrorLine $Job) })
    if (-not $script:JobQueue.Count) {
        $done = @($script:FinishedJobs)
        $script:FinishedJobs.Clear()
        Show-Finished $done
    }
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
    $job.Cancelled = $true
    Complete-Job $job
    foreach ($q in @($script:JobQueue.ToArray())) { Write-Activity "Cancelled: $($q.Label)" }
    $script:JobQueue.Clear()
}

# ---------------------------------------------------------------------------
# Progress window: shows the running job (start, stop, update, send...) with
# Docker's output as it arrives. It closes itself a few seconds after a job
# succeeds, and stays open when one fails.
# ---------------------------------------------------------------------------
$progressXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Working" Width="760" Height="420" MinWidth="460" MinHeight="260" WindowStartupLocation="CenterOwner" ShowInTaskbar="False"
        FontFamily="Segoe UI" FontSize="13" Background="{DynamicResource Page}" Foreground="{DynamicResource Ink}">
    <Window.Resources><!--SHARED--></Window.Resources>
    <DockPanel Margin="16">
        <StackPanel DockPanel.Dock="Top">
            <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <TextBlock x:Name="PrgGlyph" FontFamily="Segoe MDL2 Assets" FontSize="20" Text="&#xE895;" Foreground="{StaticResource Accent}"
                           VerticalAlignment="Center" Margin="0,0,10,0"/>
                <StackPanel Grid.Column="1">
                    <TextBlock x:Name="PrgTitle" FontSize="16" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
                    <TextBlock x:Name="PrgStep" Foreground="{StaticResource SoftInk}" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
                </StackPanel>
            </Grid>
            <ProgressBar x:Name="PrgBar" Height="8" Margin="0,12,0,4" Minimum="0" Maximum="1"
                         Foreground="{StaticResource Accent}" Background="{StaticResource AccentSoft}" BorderThickness="0"/>
            <ProgressBar x:Name="PrgBusyBar" Height="3" Margin="0,0,0,10" IsIndeterminate="True"
                         Foreground="{StaticResource Accent}" Background="Transparent" BorderThickness="0"/>
        </StackPanel>
        <Grid DockPanel.Dock="Bottom" Margin="0,12,0,0">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <TextBlock x:Name="PrgNote" Foreground="{StaticResource SoftInk}" VerticalAlignment="Center" TextWrapping="Wrap"/>
            <StackPanel Grid.Column="1" Orientation="Horizontal">
                <Button x:Name="PrgCancel" Content="Cancel" Tag="&#xE711;" Style="{StaticResource Btn}"
                        ToolTip="Stop what Docker is doing now, and anything waiting"/>
                <Button x:Name="PrgClose" Content="Hide" Style="{StaticResource PrimaryBtn}" Margin="0"
                        ToolTip="Close this window. The work carries on, and the Activity log keeps the details."/>
            </StackPanel>
        </Grid>
        <TextBox x:Name="PrgOutput" IsReadOnly="True" FontFamily="Consolas" FontSize="12" TextWrapping="NoWrap"
                 VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                 Background="{StaticResource Card}" Foreground="{StaticResource Ink}" BorderBrush="{StaticResource Edge}"/>
    </DockPanel>
</Window>
'@

$script:ProgressForm = $null

function Show-JobProgress($Job) {
    if (-not $script:Settings.ShowProgress -or -not $window.IsVisible) { return }
    $p = $script:ProgressForm
    if (-not $p) {
        $w = New-XamlObject $progressXaml
        $w.Owner = $window
        if ($window.Icon) { $w.Icon = $window.Icon }
        $p = @{ Window = $w; CloseAt = $null; Lines = 0 }
        foreach ($n in 'PrgGlyph', 'PrgTitle', 'PrgStep', 'PrgBar', 'PrgBusyBar', 'PrgNote', 'PrgCancel', 'PrgClose', 'PrgOutput') { $p[$n] = $w.FindName($n) }
        $p.PrgCancel.Add_Click({
                if ($script:CurrentJob -and (Confirm-Action "Stop $($script:CurrentJob.Label)?`n`nThe docker command is stopped part way, and anything waiting is cancelled.")) { Stop-CurrentJob }
            })
        $p.PrgClose.Add_Click({ if ($script:ProgressForm) { $script:ProgressForm.Window.Close() } })
        $w.Add_Closed({ $script:ProgressForm = $null })
        $script:ProgressForm = $p
        $w.Show()
    }
    $p.CloseAt = $null
    if ($p.Lines) { $p.PrgOutput.AppendText("`r`n") }
    $p.PrgOutput.AppendText("== $($Job.Label) ==`r`n")
    $p.Lines++
    $p.Window.Title = 'Working - ' + (Get-MachineName)
    $p.PrgTitle.Text = $Job.Label
    $p.PrgGlyph.Text = [string][char]0xE895
    $p.PrgGlyph.Foreground = $p.Window.FindResource('Accent')
    $p.PrgBar.Value = 0
    $p.PrgBusyBar.Visibility = 'Visible'
    $p.PrgCancel.Visibility = 'Visible'
    $p.PrgClose.Content = 'Hide'
    Update-JobProgressNote
}

function Update-JobProgressNote {
    $p = $script:ProgressForm
    if (-not $p) { return }
    $waiting = $script:JobQueue.Count
    $p.PrgNote.Text = if ($waiting) { "$waiting more waiting after this." } else { 'Hide closes this window; the work carries on.' }
}

function Update-JobProgress($Job) {
    $p = $script:ProgressForm
    if (-not $p -or -not $Job.Runner) { return }
    $n = $Job.Steps.Count
    $p.PrgStep.Text = ('Step {0} of {1}:  {2}' -f ($Job.Index + 1), $n, (Get-ShortCommand $Job.Runner.CommandLine))
    $p.PrgBar.Value = $Job.Index / [Math]::Max(1, $n)
    $p.PrgOutput.AppendText('> ' + (Get-ShortCommand $Job.Runner.CommandLine) + "`r`n")
    $p.PrgOutput.ScrollToEnd()
    Update-JobProgressNote
}

function Add-ProgressLine([string]$Line) {
    $p = $script:ProgressForm
    if (-not $p) { return }
    # Keep the box light: after 3000 lines, drop the oldest half.
    if ($p.PrgOutput.LineCount -gt 3000) { $t = $p.PrgOutput.Text; $p.PrgOutput.Text = $t.Substring([Math]::Min($t.Length, [int]($t.Length / 2))) }
    $p.PrgOutput.AppendText('  ' + $Line + "`r`n")
    $p.PrgOutput.ScrollToEnd()
}

function Complete-JobProgress($Job) {
    $p = $script:ProgressForm
    if (-not $p) { return }
    $more = ($script:JobQueue.Count -gt 0)
    if ($more) { return }
    $p.PrgBusyBar.Visibility = 'Collapsed'
    $p.PrgCancel.Visibility = 'Collapsed'
    $p.PrgClose.Content = 'Close'
    if ($Job.Failed) {
        $p.PrgBar.Value = $Job.Index / [Math]::Max(1, $Job.Steps.Count)
        $p.PrgGlyph.Text = [string][char]0xEA39
        $p.PrgGlyph.Foreground = $p.Window.FindResource('Bad')
        $p.PrgStep.Text = 'Failed. The lines above say what Docker reported.'
        $p.PrgNote.Text = ''
        $p.PrgOutput.AppendText("Failed.`r`n")
        $p.CloseAt = $null
    } else {
        $p.PrgBar.Value = 1
        $p.PrgGlyph.Text = [string][char]0xE930
        $p.PrgGlyph.Foreground = $p.Window.FindResource('Ok')
        $p.PrgStep.Text = 'Done.'
        $p.PrgNote.Text = ''
        $p.PrgOutput.AppendText("Done.`r`n")
        $p.CloseAt = [DateTime]::Now.AddSeconds(10)
        $p.PrgClose.Content = 'Close (10)'
    }
    $p.PrgOutput.ScrollToEnd()
}

# ---------------------------------------------------------------------------
# Finished box: when Docker has finished what it was asked to do and the
# progress window isn't showing (Hide was pressed, or it's turned off), a small
# box in the bottom-right corner of the screen says how it went. It stays on
# top without taking the focus. Success closes itself after 10 seconds; a
# failure stays until it's closed. Jobs finishing close together share one box.
# ---------------------------------------------------------------------------
$finishedXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Finished" Width="440" SizeToContent="Height" ResizeMode="NoResize" WindowStartupLocation="Manual" ShowInTaskbar="False"
        Topmost="True" ShowActivated="False" WindowStyle="ToolWindow"
        FontFamily="Segoe UI" FontSize="13" Background="{DynamicResource Page}" Foreground="{DynamicResource Ink}">
    <Window.Resources><!--SHARED--></Window.Resources>
    <StackPanel Margin="16">
        <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <TextBlock x:Name="FinGlyph" FontFamily="Segoe MDL2 Assets" FontSize="20" VerticalAlignment="Center" Margin="0,0,10,0"/>
            <TextBlock x:Name="FinTitle" Grid.Column="1" FontSize="16" FontWeight="SemiBold" VerticalAlignment="Center"/>
        </Grid>
        <TextBlock x:Name="FinList" TextWrapping="Wrap" Margin="0,8,0,0" LineHeight="20"/>
        <TextBlock x:Name="FinError" Foreground="{StaticResource SoftInk}" TextWrapping="Wrap" Margin="0,8,0,0" FontSize="12"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
            <Button x:Name="FinLog" Content="Show log" Tag="&#xE9F9;" Style="{StaticResource Btn}"/>
            <Button x:Name="FinClose" Content="Close" Style="{StaticResource PrimaryBtn}" IsCancel="True" Margin="0"/>
        </StackPanel>
    </StackPanel>
</Window>
'@

# Bottom-right corner of the screen the main window is on (in WPF units).
function Set-FinishedPosition {
    $f = $script:FinishedForm
    if (-not $f) { return }
    $w = $f.Window
    try {
        $hwnd = (New-Object Windows.Interop.WindowInteropHelper($window)).Handle
        $area = [Windows.Forms.Screen]::FromHandle($hwnd).WorkingArea
        $src = [Windows.PresentationSource]::FromVisual($window)
        $m = if ($src) { $src.CompositionTarget.TransformFromDevice } else { [Windows.Media.Matrix]::Identity }
        $br = $m.Transform((New-Object Windows.Point($area.Right, $area.Bottom)))
    } catch {
        $wa = [Windows.SystemParameters]::WorkArea
        $br = New-Object Windows.Point($wa.Right, $wa.Bottom)
    }
    $w.Left = $br.X - $w.ActualWidth - 16
    $w.Top = $br.Y - $w.ActualHeight - 16
}

# The line most likely to say what went wrong in the step that failed.
function Get-JobErrorLine($Job) {
    if ($Job.StartError) { return [string]$Job.StartError }
    $lines = @($Job.StepLines)
    $hit = @($lines | Where-Object { $_ -match '(?i)error|denied|not found|unknown|no such|failed|cannot|refused|invalid' } | Select-Object -First 1)
    if ($hit.Count) { return [string]$hit[0] }
    if ($lines.Count) { return [string]$lines[-1] }
    return ''
}

function Show-Finished([object[]]$Jobs) {
    if (-not $Jobs.Count -or -not $script:Settings.ShowFinished) { return }
    if ($script:ProgressForm -and $script:ProgressForm.Window.IsVisible) { return }
    $f = $script:FinishedForm
    if (-not $f) {
        $w = New-XamlObject $finishedXaml
        if ($window.Icon) { $w.Icon = $window.Icon }
        $f = @{ Window = $w; Items = (New-Object System.Collections.ArrayList); CloseAt = $null }
        foreach ($n in 'FinGlyph', 'FinTitle', 'FinList', 'FinError', 'FinLog', 'FinClose') { $f[$n] = $w.FindName($n) }
        $f.FinClose.Add_Click({ if ($script:FinishedForm) { $script:FinishedForm.Window.Close() } })
        $f.FinLog.Add_Click({
                Show-MainWindow
                Set-ActivityVisible $true
                $ui.ChkActivity.IsChecked = $true
                $ui.TxtLog.ScrollToEnd()
                if ($script:FinishedForm) { $script:FinishedForm.Window.Close() }
            })
        $w.Add_SizeChanged({ Set-FinishedPosition })
        $w.Add_Closed({ $script:FinishedForm = $null })
        $script:FinishedForm = $f
    }
    foreach ($j in $Jobs) { [void]$f.Items.Add($j) }
    $failed = @($f.Items | Where-Object { $_.Failed -and -not $_.Cancelled })
    $f.Window.Title = 'Docker Container Manager - ' + (Get-MachineName)
    if ($failed.Count) {
        $f.FinTitle.Text = "Didn't work"
        $f.FinGlyph.Text = [string][char]0xEA39
        $f.FinGlyph.Foreground = $f.Window.FindResource('Bad')
        $err = [string]$failed[-1].Error
        $f.FinError.Text = if ($err) { "Docker said: $err" } else { 'The Activity log shows what Docker said.' }
        $f.FinError.Visibility = 'Visible'
        $f.FinLog.Visibility = 'Visible'
        $f.CloseAt = $null
        $f.FinClose.Content = 'Close'
    } else {
        $allCancelled = (@($f.Items | Where-Object { $_.Cancelled }).Count -eq $f.Items.Count)
        $f.FinTitle.Text = if ($allCancelled) { 'Cancelled' } else { 'Done' }
        $f.FinGlyph.Text = if ($allCancelled) { [string][char]0xE711 } else { [string][char]0xE930 }
        $f.FinGlyph.Foreground = $f.Window.FindResource($(if ($allCancelled) { 'SoftInk' } else { 'Ok' }))
        $f.FinError.Visibility = 'Collapsed'
        $f.FinLog.Visibility = 'Collapsed'
        $f.CloseAt = [DateTime]::Now.AddSeconds(10)
        $f.FinClose.Content = 'Close (10)'
    }
    $lines = foreach ($j in @($f.Items | Select-Object -Last 5)) {
        $what = if ($j.Cancelled) { 'Cancelled' } elseif ($j.Failed) { 'Failed' } else { 'Done' }
        '{0}:  {1}' -f $what, $j.Label
    }
    if ($f.Items.Count -gt 5) { $lines = @("... and $($f.Items.Count - 5) earlier") + @($lines) }
    $f.FinList.Text = ($lines -join "`n")
    if (-not $f.Window.IsVisible) { $f.Window.Show() }
    Set-FinishedPosition
}

# Called by the heartbeat: counts down on the Close button after a success.
function Update-FinishedWindow {
    $f = $script:FinishedForm
    if (-not $f -or -not $f.CloseAt) { return }
    $left = [int][Math]::Ceiling(($f.CloseAt - [DateTime]::Now).TotalSeconds)
    if ($left -le 0) { $f.Window.Close(); return }
    $f.FinClose.Content = "Close ($left)"
}

# Called by the heartbeat: counts down on the Close button and closes the window 10 seconds after a success.
function Update-ProgressWindow {
    $p = $script:ProgressForm
    if (-not $p -or -not $p.CloseAt) { return }
    $left = [int][Math]::Ceiling(($p.CloseAt - [DateTime]::Now).TotalSeconds)
    if ($left -le 0) { $p.Window.Close(); return }
    $p.PrgClose.Content = "Close ($left)"
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
            if (($script:Settings.ConfirmGroupStop -or $key -eq '*') -and -not (Confirm-Action "Stop the $($todo.Count) running container(s) in $($name)?")) { return }
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
    # Ports published on another machine are on that machine, not on this PC.
    $m = Get-Machine
    if ($m) { $Url = $Url -replace '^(?i)(https?://)(localhost|127\.0\.0\.1)(?=[:/]|$)', ('${1}' + (Get-MachineHost $m)) }
    try { Start-Process -FilePath $Url } catch { Set-Status "Couldn't open $Url" }
}

# ---------------------------------------------------------------------------
# Background work (web requests) in a small pool of runspaces, so the window
# never waits on the network. The heartbeat collects the results.
# ---------------------------------------------------------------------------
$script:BgPool  = $null
$script:BgTasks = New-Object System.Collections.ArrayList

function Start-Background([scriptblock]$Work, [object[]]$Arguments, [scriptblock]$OnDone) {
    try {
        if (-not $script:BgPool) {
            $script:BgPool = [RunspaceFactory]::CreateRunspacePool(1, 4)
            $script:BgPool.Open()
        }
        $ps = [PowerShell]::Create()
        $ps.RunspacePool = $script:BgPool
        [void]$ps.AddScript($Work.ToString())
        foreach ($a in $Arguments) { [void]$ps.AddArgument($a) }
        $handle = $ps.BeginInvoke()
        [void]$script:BgTasks.Add(@{ PS = $ps; Handle = $handle; OnDone = $OnDone; Started = [DateTime]::Now })
        return $true
    } catch {
        Write-Activity "Couldn't start background work: $($_.Exception.Message)"
        return $false
    }
}

function Update-Background {
    if ($script:BgTasks.Count -eq 0) { return }
    foreach ($t in @($script:BgTasks)) {
        $timedOut = (([DateTime]::Now - $t.Started).TotalMinutes -gt 5)
        if (-not $t.Handle.IsCompleted -and -not $timedOut) { continue }
        $script:BgTasks.Remove($t)
        $out = @()
        $err = ''
        if (-not $t.Handle.IsCompleted) {
            $err = 'Timed out.'
            try { [void]$t.PS.BeginStop($null, $null) } catch { Write-Verbose 'Background task already ending.' }
        } else {
            try { $out = @($t.PS.EndInvoke($t.Handle)) } catch { $err = $_.Exception.Message }
            if (-not $err -and $t.PS.Streams.Error.Count) { $err = [string]$t.PS.Streams.Error[0] }
            $t.PS.Dispose()
        }
        try { & $t.OnDone $out $err } catch { Write-Activity "Internal error: $($_.Exception.Message)" }
    }
}

function Stop-Background {
    foreach ($t in @($script:BgTasks)) { try { [void]$t.PS.BeginStop($null, $null) } catch { Write-Verbose 'Background task already ending.' } }
    $script:BgTasks.Clear()
    if ($script:BgPool) { try { [void]$script:BgPool.BeginClose($null, $null) } catch { Write-Verbose 'Runspace pool already closed.' } }
}

# ---------------------------------------------------------------------------
# App icons. Found from the image name (lscr.io/linuxserver/sonarr -> sonarr) or
# a home.icon label (a name, a web address or a picture file), downloaded once
# from the dashboard-icons project and kept in %LOCALAPPDATA%. Containers
# without one get a letter in their group colour.
# ---------------------------------------------------------------------------
$script:IconDir       = Join-Path (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) $script:AppName) 'Icons'
$script:IconBase      = 'https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/'
$script:IconImages    = @{}   # file -> decoded picture
$script:IconRequested = @{}   # name -> $true once asked for in this session

$script:IconWork = {
    param($Jobs, $Dir)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    foreach ($j in $Jobs) {
        $wc = New-Object Net.WebClient
        $wc.Headers['User-Agent'] = 'Docker-Container-Manager'
        try {
            $bytes = $wc.DownloadData($j.Url)
            $hex = if ($bytes.Length -ge 4) { [BitConverter]::ToString($bytes, 0, 4) } else { '' }
            # PNG, JPEG, GIF, ICO or BMP; anything else (an error page, WebP) counts as no icon.
            if ($hex -match '^(89-50-4E-47|FF-D8-FF|47-49-46-38|00-00-01-00|42-4D)') {
                [IO.File]::WriteAllBytes((Join-Path $Dir ($j.Key + '.png')), $bytes); 'ok'
            } else {
                [IO.File]::WriteAllText((Join-Path $Dir ($j.Key + '.none')), ''); 'none'
            }
        } catch {
            $ex = $_.Exception
            while ($ex -and -not ($ex -is [Net.WebException])) { $ex = $ex.InnerException }
            if ($ex -and $ex.Response -and [int]$ex.Response.StatusCode -eq 404) {
                [IO.File]::WriteAllText((Join-Path $Dir ($j.Key + '.none')), ''); 'none'
            } else { 'error' }
        } finally { $wc.Dispose() }
    }
}

function Get-IconSlugs([Dcm.Row]$Row) {
    $cands = New-Object System.Collections.Generic.List[string]
    $label = [string]$Row.IconLabel
    if ($label -and $label -notmatch '[\\/:.]') { $cands.Add($label) }
    $img = [string]$Row.Image
    if ($img -and -not $img.StartsWith('(')) {
        $name = ($img -split '@')[0]
        $slash = $name.LastIndexOf('/')
        $colon = $name.LastIndexOf(':')
        if ($colon -gt $slash) { $name = $name.Substring(0, $colon) }
        $name = $name.Substring($slash + 1)
        $cands.Add($name)
        $cands.Add(($name -replace '[-_]?\d+$', ''))
        $cands.Add(($name -replace '[-_](server|web|app|docker|ce|oss)$', ''))
    }
    $cands.Add($Row.Service)
    $cands.Add(($Row.Service -replace '[-_]?\d+$', ''))
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($c in $cands) {
        $s = (([string]$c).ToLowerInvariant() -replace '[^a-z0-9-]+', '-').Trim('-')
        if ($s -and -not $out.Contains($s)) { $out.Add($s) }
    }
    return $out.ToArray()
}

function Get-UrlIconKey([string]$Url) {
    $sha = [Security.Cryptography.SHA1]::Create()
    try { $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Url)) } finally { $sha.Dispose() }
    return 'url-' + ([BitConverter]::ToString($hash, 0, 8) -replace '-', '').ToLowerInvariant()
}

function Get-IconImage([string]$Path) {
    if ($script:IconImages.ContainsKey($Path)) { return $script:IconImages[$Path] }
    $bmp = $null
    try {
        $bmp = New-Object Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit()
        $bmp.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bmp.DecodePixelWidth = 72
        $bmp.UriSource = New-Object Uri($Path)
        $bmp.EndInit()
        $bmp.Freeze()
    } catch {
        Write-Verbose "Icon unreadable: $Path"
        $bmp = $null
    }
    $script:IconImages[$Path] = $bmp
    return $bmp
}

function Update-Icons {
    $show = [bool]$script:Settings.DownloadIcons
    if ($show -and -not (Test-Path -LiteralPath $script:IconDir)) {
        try { New-Item -ItemType Directory -Path $script:IconDir -Force | Out-Null } catch { $show = $false }
    }
    $fetch = [ordered]@{}
    foreach ($row in @($script:Rows)) {
        $found = ''
        $label = [string]$row.IconLabel
        if ($show -and $label -and $label -notmatch '^(?i)https?://' -and $label -match '[\\/]|\.(?i:png|jpe?g|ico|bmp|gif)$') {
            $p = if ([IO.Path]::IsPathRooted($label)) { $label } elseif ($script:ComposeDir) { Join-Path $script:ComposeDir $label } else { '' }
            if ($p -and (Test-Path -LiteralPath $p -PathType Leaf)) { $found = $p }
        } elseif ($show) {
            $keys = @()
            if ($label -match '^(?i)https?://') { $keys += Get-UrlIconKey $label }
            $keys += @(Get-IconSlugs $row)
            foreach ($k in $keys) {
                $png = Join-Path $script:IconDir "$k.png"
                if (Test-Path -LiteralPath $png) { $found = $png; break }
                $miss = Get-Item -LiteralPath (Join-Path $script:IconDir "$k.none") -ErrorAction SilentlyContinue
                if ($miss -and ([DateTime]::Now - $miss.LastWriteTime).TotalDays -lt 14) { continue }
                # Not known yet: ask for it, and wait for the answer before trying the next name.
                if (-not $script:IconRequested.ContainsKey($k)) { $fetch[$k] = if ($k.StartsWith('url-')) { $label } else { $script:IconBase + "$k.png" } }
                break
            }
        }
        if ($row.IconKey -ne $found -or ($found -and -not $row.HasIcon)) {
            $row.IconKey = $found
            $row.Icon = if ($found) { Get-IconImage $found } else { $null }
        }
    }
    if (-not $fetch.Count) { return }
    $jobs = @(foreach ($k in $fetch.Keys) { $script:IconRequested[$k] = $true; @{ Key = $k; Url = $fetch[$k] } })
    $parts = 4
    for ($p = 0; $p -lt $parts; $p++) {
        $chunk = @(for ($i = $p; $i -lt $jobs.Count; $i += $parts) { $jobs[$i] })
        if (-not $chunk.Count) { continue }
        [void](Start-Background -Work $script:IconWork -Arguments @($chunk, $script:IconDir) -OnDone {
                param($out, $err)
                $fails = @($out | Where-Object { $_ -eq 'error' }).Count
                if (($fails -or $err) -and -not $script:IconErrorShown) {
                    $script:IconErrorShown = $true
                    Write-Activity "Some app icons couldn't be downloaded (no internet?). Letters are shown instead; they're tried again next time."
                }
                if (@($out | Where-Object { $_ -eq 'ok' -or $_ -eq 'none' }).Count) { Update-Icons }
            })
    }
}

# ---------------------------------------------------------------------------
# Update checker. Asks each image's registry for the digest of its tag (a HEAD
# request, so nothing is downloaded and Docker Hub's pull limit isn't touched)
# and compares it with the digest of the image on this PC.
# ---------------------------------------------------------------------------
$script:UpdatesPath        = Join-Path $script:SettingsDir 'updates.json'
$script:LocalDigests       = @{}   # image key -> digests of the image on this PC
$script:RemoteDigests      = @{}   # image key -> @{ Digest; Checked }
$script:LocalScanRunning   = $false
$script:UpdateCheckRunning = $false
$script:UpdateAutoDone     = $false

# Splits an image reference into registry, repository and tag. $null for
# references that can't be checked (built from source, pinned to a digest).
function Get-ImageParts([string]$Ref) {
    $r = ([string]$Ref).Trim()
    if (-not $r -or $r.Contains('@') -or $r.StartsWith('(') -or $r -match '\s') { return $null }
    $slash = $r.LastIndexOf('/')
    $colon = $r.LastIndexOf(':')
    $tag = 'latest'
    if ($colon -gt $slash) { $tag = $r.Substring($colon + 1); $r = $r.Substring(0, $colon) }
    $parts = $r.Split('/')
    $registry = 'docker.io'
    if ($parts.Count -gt 1 -and ($parts[0] -match '[.:]' -or $parts[0] -eq 'localhost')) {
        $registry = $parts[0].ToLowerInvariant()
        $r = $parts[1..($parts.Count - 1)] -join '/'
    }
    if ($registry -eq 'index.docker.io' -or $registry -eq 'registry-1.docker.io') { $registry = 'docker.io' }
    if ($registry -eq 'docker.io' -and -not $r.Contains('/')) { $r = "library/$r" }
    if (-not $r -or -not $tag) { return $null }
    $api = if ($registry -eq 'docker.io') { 'registry-1.docker.io' } else { $registry }
    return @{ Registry = $registry; Api = $api; Repo = $r; Tag = $tag; Key = "$registry/$($r):$tag" }
}

function Get-ImageKey([string]$Ref) {
    $p = Get-ImageParts $Ref
    if ($p) { return $p.Key }
    return ''
}

$script:UpdateCheckWork = {
    param($Items)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $accept = 'application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, ' +
        'application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json'
    $tokens = @{}
    function Send-Head([string]$Url, [string]$Token) {
        for ($hop = 0; $hop -lt 4; $hop++) {
            $req = [Net.HttpWebRequest]::Create($Url)
            $req.Method = 'HEAD'
            $req.Accept = $accept
            $req.Timeout = 15000
            $req.AllowAutoRedirect = $false
            $req.UserAgent = 'Docker-Container-Manager'
            if ($Token) { $req.Headers['Authorization'] = "Bearer $Token" }
            $resp = $null
            try { $resp = $req.GetResponse() }
            catch {
                $ex = $_.Exception
                while ($ex -and -not ($ex -is [Net.WebException])) { $ex = $ex.InnerException }
                if (-not $ex -or -not $ex.Response) { throw }
                $resp = $ex.Response
            }
            try {
                $code = [int]$resp.StatusCode
                $location = $resp.Headers['Location']
                if ($code -ge 300 -and $code -lt 400 -and $location) { $Url = [string](New-Object Uri((New-Object Uri($Url)), $location)); continue }
                return @{ Code = $code; Digest = $resp.Headers['Docker-Content-Digest']; Auth = $resp.Headers['WWW-Authenticate'] }
            } finally { $resp.Close() }
        }
        return @{ Code = 0 }
    }
    function Get-Token([string]$Auth) {
        $p = @{}
        foreach ($m in [regex]::Matches($Auth, '(\w+)="([^"]*)"')) { $p[$m.Groups[1].Value] = $m.Groups[2].Value }
        if (-not $p['realm']) { return $null }
        $q = @()
        foreach ($k in 'service', 'scope') { if ($p[$k]) { $q += "$k=" + [Uri]::EscapeDataString($p[$k]) } }
        $url = $p['realm'] + $(if ($q.Count) { '?' + ($q -join '&') } else { '' })
        if ($tokens.ContainsKey($url)) { return $tokens[$url] }
        $wc = New-Object Net.WebClient
        $wc.Headers['User-Agent'] = 'Docker-Container-Manager'
        try { $j = $wc.DownloadString($url) | ConvertFrom-Json } finally { $wc.Dispose() }
        $t = if ($j.token) { $j.token } else { $j.access_token }
        $tokens[$url] = $t
        return $t
    }
    foreach ($it in $Items) {
        $r = @{ Key = $it.Key; Digest = ''; Error = '' }
        try {
            $h = Send-Head $it.Url $null
            if ($h.Code -eq 401 -and $h.Auth -match '^Bearer') { $h = Send-Head $it.Url (Get-Token $h.Auth) }
            if ($h.Code -eq 200 -and $h.Digest) { $r.Digest = [string]$h.Digest } else { $r.Error = "HTTP $($h.Code)" }
        } catch { $r.Error = $_.Exception.Message }
        [pscustomobject]$r
    }
}

function Read-UpdateCache {
    if (-not (Test-Path -LiteralPath $script:UpdatesPath)) { return }
    try {
        $j = [IO.File]::ReadAllText($script:UpdatesPath) | ConvertFrom-Json
        foreach ($p in $j.Images.PSObject.Properties) {
            $when = [DateTime]::Parse([string]$p.Value.Checked, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
            $script:RemoteDigests[$p.Name] = @{ Digest = [string]$p.Value.Digest; Checked = $when.ToLocalTime() }
        }
    } catch { Write-Verbose "Update cache unreadable: $($_.Exception.Message)" }
}

function Save-UpdateCache {
    try {
        $images = [ordered]@{}
        foreach ($k in ($script:RemoteDigests.Keys | Sort-Object)) {
            $v = $script:RemoteDigests[$k]
            $images[$k] = [ordered]@{ Digest = $v.Digest; Checked = $v.Checked.ToUniversalTime().ToString('o') }
        }
        if (-not (Test-Path -LiteralPath $script:SettingsDir)) { New-Item -ItemType Directory -Path $script:SettingsDir -Force | Out-Null }
        $json = [pscustomobject]@{ Images = [pscustomobject]$images } | ConvertTo-Json -Depth 4
        [IO.File]::WriteAllText($script:UpdatesPath, $json, (New-Object Text.UTF8Encoding($false)))
    } catch { Write-Activity "Couldn't save the update check results: $($_.Exception.Message)" }
}

# Reads the digests of the images on this PC, then marks containers with a newer image.
function Start-LocalDigestScan {
    if (-not (Test-DockerReady) -or $script:LocalScanRunning -or -not $script:ConfigLoaded) { return }
    $refs = @($script:Rows | Where-Object { $_.InCompose -and (Get-ImageKey $_.Image) } | ForEach-Object Image | Sort-Object -Unique)
    if (-not $refs.Count) { return }
    $script:LocalScanRunning = $true
    Start-DockerCall -Arguments (@('image', 'inspect', '--format', '{{json .RepoTags}}|{{json .RepoDigests}}') + $refs) -OnDone {
        param($res)
        $script:LocalScanRunning = $false
        $map = @{}
        foreach ($line in ($res.Output -split "`r?`n")) {
            $p = $line.Split('|')
            if ($p.Count -ne 2) { continue }
            try { $tags = @($p[0] | ConvertFrom-Json); $digests = @($p[1] | ConvertFrom-Json) } catch { continue }
            $d = @($digests | Where-Object { $_ } | ForEach-Object { ([string]$_ -split '@')[-1] })
            foreach ($t in $tags) { $k = Get-ImageKey ([string]$t); if ($k) { $map[$k] = $d } }
        }
        $script:LocalDigests = $map
        Update-UpdateFlags
        if ($script:Settings.CheckUpdatesOnStart -and -not $script:UpdateAutoDone -and $map.Count) {
            $script:UpdateAutoDone = $true
            $stale = @($map.Keys | Where-Object { -not $script:RemoteDigests.ContainsKey($_) -or ([DateTime]::Now - $script:RemoteDigests[$_].Checked).TotalHours -ge 12 })
            if ($stale.Count) { Start-UpdateCheck -Keys $stale -Quiet }
        }
    }
}

function Start-UpdateCheck([string[]]$Keys, [switch]$Quiet) {
    if ($script:UpdateCheckRunning) { return }
    if (-not $Keys) { $Keys = @($script:LocalDigests.Keys) }
    $items = @(foreach ($k in $Keys) {
            $p = Get-ImageParts $k
            if ($p) { @{ Key = $k; Url = "https://$($p.Api)/v2/$($p.Repo)/manifests/$($p.Tag)" } }
        })
    if (-not $items.Count) {
        if (-not $Quiet) { Set-Status 'No downloaded images to check yet. Start or update a container first.' }
        return
    }
    $script:UpdateCheckRunning = $true
    $script:UpdatePartsLeft = 0
    $script:UpdateErrors = 0
    $script:UpdateErrorSample = ''
    $ui.BtnCheckUpdates.IsEnabled = $false
    $ui.BtnCheckUpdates.Content = 'Checking...'
    Write-Activity "Checking $($items.Count) image(s) for updates..."
    $parts = 4
    for ($p = 0; $p -lt $parts; $p++) {
        $chunk = @(for ($i = $p; $i -lt $items.Count; $i += $parts) { $items[$i] })
        if (-not $chunk.Count) { continue }
        $script:UpdatePartsLeft++
        $started = Start-Background -Work $script:UpdateCheckWork -Arguments @(, $chunk) -OnDone {
            param($out, $err)
            if ($err -and -not $out.Count) { $script:UpdateErrors++; $script:UpdateErrorSample = $err }
            foreach ($r in $out) {
                if ($r.Digest) { $script:RemoteDigests[$r.Key] = @{ Digest = $r.Digest; Checked = [DateTime]::Now } }
                else { $script:UpdateErrors++; if (-not $script:UpdateErrorSample) { $script:UpdateErrorSample = "$($r.Key): $($r.Error)" } }
            }
            $script:UpdatePartsLeft--
            if ($script:UpdatePartsLeft -le 0) { Complete-UpdateCheck }
        }
        if (-not $started) { $script:UpdatePartsLeft-- }
    }
    if ($script:UpdatePartsLeft -le 0) { Complete-UpdateCheck }
}

function Complete-UpdateCheck {
    $script:UpdateCheckRunning = $false
    $ui.BtnCheckUpdates.IsEnabled = $true
    $ui.BtnCheckUpdates.Content = 'Check for updates'
    Save-UpdateCache
    Update-UpdateFlags
    $n = @($script:Rows | Where-Object UpdateAvailable).Count
    $msg = if ($n) { "Update check: $n container(s) have a newer image. Update them to download it." } else { 'Update check: every image is up to date.' }
    if ($script:UpdateErrors) { $msg += " $($script:UpdateErrors) image(s) couldn't be checked, for example $script:UpdateErrorSample." }
    Write-Activity $msg
    Set-Status $(if ($n) { "$n container(s) have a newer image." } else { 'Every image is up to date.' })
}

function Update-UpdateFlags {
    $changed = $false
    foreach ($row in @($script:Rows)) {
        $flag = $false
        $k = if ($row.InCompose) { Get-ImageKey $row.Image } else { '' }
        if ($k -and $script:RemoteDigests.ContainsKey($k) -and $script:LocalDigests.ContainsKey($k)) {
            $local = @($script:LocalDigests[$k])
            $remote = $script:RemoteDigests[$k].Digest
            $flag = [bool]($local.Count -and $remote -and ($local -notcontains $remote))
        }
        if ($row.UpdateAvailable -ne $flag) { $row.UpdateAvailable = $flag; Update-RowNote $row; $changed = $true }
    }
    if ($changed) {
        Update-GroupBar
        if ($script:StateFilter -eq 'Updates available') { Update-View -Refilter }
    }
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
                <Button x:Name="BtnCheckTidy" Content="Tidy spacing" Tag="&#xE8E4;" Style="{StaticResource Btn}"
                        ToolTip="Re-indent the whole file to two spaces per level. Saved only if Docker reads the result exactly the same."/>
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
                          GridLinesVisibility="None" BorderThickness="0" Background="Transparent"
                          SelectionMode="Extended" SelectionUnit="FullRow" CanUserAddRows="False" RowHeight="28">
                    <DataGrid.RowStyle>
                        <Style TargetType="DataGridRow">
                            <Setter Property="Background" Value="Transparent"/>
                            <Setter Property="BorderThickness" Value="4,0,0,0"/>
                            <Setter Property="BorderBrush" Value="Transparent"/>
                            <Style.Triggers>
                                <Trigger Property="IsMouseOver" Value="True">
                                    <Setter Property="Background" Value="{DynamicResource Hover}"/>
                                </Trigger>
                                <Trigger Property="IsSelected" Value="True">
                                    <Setter Property="Background" Value="{DynamicResource Selected}"/>
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
    $w.FindName('BtnCheckTidy').Add_Click({ Invoke-TidySpacing })
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
# Tidy spacing: re-indents the compose file to two spaces per level. Lists stay
# in the style they were written in, block text (| and >) moves with its key,
# comments move with the line below them. The result is only saved when
# "docker compose config" reads both versions exactly the same.
# ---------------------------------------------------------------------------
function Format-ComposeSpacing($Lines) {
    $out = New-Object System.Collections.Generic.List[string]
    $so = New-Object System.Collections.Generic.List[int]   # indents as written...
    $sn = New-Object System.Collections.Generic.List[int]   # ...and as they will be
    $pending = New-Object System.Collections.Generic.List[int]
    $inBlock = $false
    $blockOrig = 0
    $blockDelta = 0
    foreach ($line in $Lines) {
        if ($inBlock) {
            if (-not $line.Trim()) { $out.Add($line); continue }
            $ind = Get-LineIndent $line
            if ($ind -gt $blockOrig) { $out.Add((' ' * [Math]::Max(0, $ind + $blockDelta)) + $line.TrimStart(' ')); continue }
            $inBlock = $false
        }
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#')) { $pending.Add($out.Count); $out.Add($line.TrimEnd()); continue }
        if ($line -match '^ *\t') { throw "Line $($out.Count + 1) is indented with a tab. Change it to spaces first." }
        $i = Get-LineIndent $line
        if ($t -eq '---' -or $t -eq '...') {
            $so.Clear(); $sn.Clear()
            $new = 0
        } else {
            while ($so.Count -and $so[$so.Count - 1] -gt $i) { $so.RemoveAt($so.Count - 1); $sn.RemoveAt($sn.Count - 1) }
            if ($so.Count -and $so[$so.Count - 1] -eq $i) {
                $new = $sn[$sn.Count - 1]
                $so.RemoveAt($so.Count - 1); $sn.RemoveAt($sn.Count - 1)
            } elseif ($so.Count) { $new = $sn[$sn.Count - 1] + 2 }
            else { $new = 0 }
            $so.Add($i); $sn.Add($new)
            # "-   value" becomes "- value", and the value is one level in.
            $co = $i; $cn = $new; $rest = $t; $norm = ''
            while ($rest.StartsWith('- ') -and $rest.Substring(2).Trim()) {
                $after = $rest.Substring(1)
                $co = $co + 1 + ($after.Length - $after.TrimStart(' ').Length)
                $cn += 2
                $norm += '- '
                $rest = $after.TrimStart(' ')
                $so.Add($co); $sn.Add($cn)
            }
            $t = $norm + $rest
        }
        $delta = $new - $i
        foreach ($p in $pending) {
            $c = $out[$p]
            if ($c.Trim() -and (Get-LineIndent $c) -gt 0) { $out[$p] = (' ' * [Math]::Max(0, (Get-LineIndent $c) + $delta)) + $c.TrimStart(' ') }
        }
        $pending.Clear()
        $out.Add((' ' * $new) + $t)
        if ((Remove-YamlComment $t) -match '(^|:\s+|^-\s+)[|>][-+0-9]*$') { $inBlock = $true; $blockOrig = $i; $blockDelta = $delta }
    }
    return , $out
}

function Get-TidyConfigArguments([string]$File) {
    return @('compose', '--project-directory', $script:ComposeDir, '-p', 'dcmtidy', '-f', $File, 'config', '--format', 'json', '--no-interpolate', '--no-env-resolution')
}

function Invoke-TidySpacing {
    $path = $script:ComposePath
    if (-not $path -or -not (Test-Path -LiteralPath $path) -or $script:Tidy) { return }
    $owner = if ($script:CheckForm) { $script:CheckForm.Window } else { $window }
    try {
        $file = Read-TextFile $path
        $tidy = Format-ComposeSpacing $file.Lines
    } catch {
        [void][Windows.MessageBox]::Show($owner, "The spacing can't be tidied automatically. $($_.Exception.Message)", $script:AppName, 'OK', 'Warning')
        return
    }
    $changed = New-Object System.Collections.Generic.List[int]
    for ($i = 0; $i -lt $file.Lines.Count; $i++) { if ($file.Lines[$i] -cne $tidy[$i]) { $changed.Add($i + 1) } }
    if (-not $changed.Count) {
        [void][Windows.MessageBox]::Show($owner, 'The spacing is already tidy. Nothing to change.', $script:AppName, 'OK', 'Information')
        return
    }
    if (-not $script:DockerExe) {
        [void][Windows.MessageBox]::Show($owner, "docker.exe wasn't found, so the tidied file can't be checked. Nothing was changed.", $script:AppName, 'OK', 'Warning')
        return
    }
    # The test copy sits next to the original so paths in the file mean the same.
    $tmpPath = Join-Path $script:ComposeDir ('.' + [IO.Path]::GetFileNameWithoutExtension($path) + '.dcm-tidy' + [IO.Path]::GetExtension($path))
    try {
        Write-TextFile @{ Path = $tmpPath; Lines = $tidy; Bom = $file.Bom; NewLine = $file.NewLine; EndsWithNewline = $file.EndsWithNewline }
    } catch {
        [void][Windows.MessageBox]::Show($owner, "Couldn't write a test copy next to the compose file: $($_.Exception.Message)", $script:AppName, 'OK', 'Warning')
        return
    }
    $script:Tidy = @{ Path = $path; File = $file; Lines = $tidy; Changed = $changed; TmpPath = $tmpPath; Owner = $owner; Before = $null
        Stamp = (Get-Item -LiteralPath $path).LastWriteTimeUtc
    }
    Set-Status 'Checking that Docker reads the tidied file the same way...'
    Start-DockerCall -Local -Arguments (Get-TidyConfigArguments $path) -OnDone {
        param($before)
        $script:Tidy.Before = $before
        Start-DockerCall -Local -Arguments (Get-TidyConfigArguments $script:Tidy.TmpPath) -OnDone { param($after) Complete-TidySpacing $after }
    }
}

function Complete-TidySpacing($After) {
    $t = $script:Tidy
    $script:Tidy = $null
    if (-not $t) { return }
    Remove-Item -LiteralPath $t.TmpPath -Force -ErrorAction SilentlyContinue
    $before = $t.Before
    Set-Status ''
    if ($before.ExitCode -ne 0) {
        [void][Windows.MessageBox]::Show($t.Owner, "Docker can't read the compose file as it is now, so tidying can't be checked safely. Nothing was changed.`n`nFix the errors first. Docker says: $(Get-FirstLines $before.Error 3)", $script:AppName, 'OK', 'Warning')
        return
    }
    if ($After.ExitCode -ne 0 -or $After.Output -cne $before.Output) {
        Write-Activity 'Tidy spacing: the tidied file would mean something different to Docker, so it was not saved.'
        [void][Windows.MessageBox]::Show($t.Owner, "Tidying would change what the file means to Docker, so nothing was changed. The Check window lists the lines to fix by hand.", $script:AppName, 'OK', 'Warning')
        return
    }
    $list = @($t.Changed | Select-Object -First 15) -join ', '
    if ($t.Changed.Count -gt 15) { $list += " and $($t.Changed.Count - 15) more" }
    $q = "Tidy the spacing on $($t.Changed.Count) line(s)?`n`nLines $list`n`nDocker reads the tidied file exactly the same as now. A copy of the current file is kept in the backups folder first."
    if ([Windows.MessageBox]::Show($t.Owner, $q, $script:AppName, 'YesNo', 'Question') -ne 'Yes') { return }
    if ((Get-Item -LiteralPath $t.Path).LastWriteTimeUtc -ne $t.Stamp) {
        [void][Windows.MessageBox]::Show($t.Owner, 'The compose file was saved by something else in the meantime, so nothing was changed. Press Tidy spacing again.', $script:AppName, 'OK', 'Warning')
        return
    }
    try {
        $bak = Backup-ConfigFile $t.Path
        $t.File.Lines = $t.Lines
        Write-TextFile $t.File
        Write-Activity "Tidied the spacing on $($t.Changed.Count) line(s) of the compose file. Backup: $bak"
    } catch {
        [void][Windows.MessageBox]::Show($t.Owner, "Couldn't save the compose file: $($_.Exception.Message)", $script:AppName, 'OK', 'Error')
    }
    if ($script:CheckForm) { Update-CheckWindow }
}

# ---------------------------------------------------------------------------
# Disk usage window
# ---------------------------------------------------------------------------
$diskXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Disk usage" Width="940" Height="660" MinWidth="780" MinHeight="420" WindowStartupLocation="CenterOwner"
        FontFamily="Segoe UI" FontSize="13" Background="{DynamicResource Page}" Foreground="{DynamicResource Ink}">
    <Window.Resources><!--SHARED-->
        <!-- Small clean-up buttons that sit in each card under the space they free.
             Accent for things Docker can make again; red (CleanRiskBtn) for anything that deletes data. -->
        <Style x:Key="CleanBtn" TargetType="Button">
            <Setter Property="Foreground" Value="{StaticResource Accent}"/>
            <Setter Property="Background" Value="%%AccentSoft%%"/>
            <Setter Property="BorderBrush" Value="%%InfoEdge%%"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Padding" Value="8,3"/>
            <Setter Property="Margin" Value="0,6,6,0"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="ToolTipService.ShowOnDisabled" Value="True"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="1" CornerRadius="5" Padding="{TemplateBinding Padding}">
                            <StackPanel Orientation="Horizontal">
                                <TextBlock Text="{TemplateBinding Tag}" FontFamily="Segoe MDL2 Assets" FontSize="11" VerticalAlignment="Center" Margin="0,0,6,0"/>
                                <ContentPresenter VerticalAlignment="Center"/>
                            </StackPanel>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="BorderBrush" Value="{Binding Foreground, RelativeSource={RelativeSource TemplatedParent}}"/>
                            </Trigger>
                            <Trigger Property="IsKeyboardFocused" Value="True">
                                <Setter TargetName="Bd" Property="BorderBrush" Value="{Binding Foreground, RelativeSource={RelativeSource TemplatedParent}}"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="Bd" Property="Opacity" Value="0.75"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Opacity" Value="0.4"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="CleanRiskBtn" TargetType="Button" BasedOn="{StaticResource CleanBtn}">
            <Setter Property="Foreground" Value="{StaticResource Bad}"/>
            <Setter Property="Background" Value="%%ErrorBg%%"/>
            <Setter Property="BorderBrush" Value="%%ErrorEdge%%"/>
        </Style>
    </Window.Resources>
    <DockPanel Margin="14">
        <Grid DockPanel.Dock="Top" Margin="0,0,0,10">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <StackPanel>
                <TextBlock Text="Disk usage" FontSize="18" FontWeight="SemiBold"/>
                <TextBlock x:Name="TxtDiskInfo" Foreground="{StaticResource SoftInk}" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
            </StackPanel>
            <Button x:Name="BtnDiskRefresh" Grid.Column="1" Content="Refresh" Tag="&#xE72C;" Style="{StaticResource Btn}" Margin="0" VerticalAlignment="Center"/>
        </Grid>
        <UniformGrid DockPanel.Dock="Top" Rows="1" Columns="4" Margin="0,0,-8,10">
            <Border Background="{StaticResource Card}" BorderBrush="{StaticResource Edge}" BorderThickness="1" CornerRadius="8" Padding="12,10" Margin="0,0,8,0">
                <StackPanel>
                    <TextBlock Text="Images" Foreground="{StaticResource SoftInk}"/>
                    <TextBlock x:Name="Size0" FontSize="20" FontWeight="SemiBold" Text="..."/>
                    <TextBlock x:Name="Info0" Foreground="{StaticResource SoftInk}" FontSize="12" TextWrapping="Wrap"/>
                    <TextBlock x:Name="Free0" FontSize="12" FontWeight="SemiBold" Margin="0,4,0,0"/>
                    <WrapPanel>
                        <Button x:Name="BtnPruneDangling" Content="Clean unnamed" Tag="&#xE894;" Style="{StaticResource CleanBtn}" IsEnabled="False"
                                ToolTip="Removes old image versions left behind by updates (no name, no container uses them). Runs: docker image prune -f"/>
                        <Button x:Name="BtnPruneUnused" Content="Clean unused..." Tag="&#xE894;" Style="{StaticResource CleanBtn}" IsEnabled="False"
                                ToolTip="Removes every image no container uses, running or stopped. They download again when needed. Asks first. Runs: docker image prune -a -f"/>
                    </WrapPanel>
                </StackPanel>
            </Border>
            <Border Background="{StaticResource Card}" BorderBrush="{StaticResource Edge}" BorderThickness="1" CornerRadius="8" Padding="12,10" Margin="0,0,8,0">
                <StackPanel>
                    <TextBlock Text="Containers" Foreground="{StaticResource SoftInk}"/>
                    <TextBlock x:Name="Size1" FontSize="20" FontWeight="SemiBold" Text="..."/>
                    <TextBlock x:Name="Info1" Foreground="{StaticResource SoftInk}" FontSize="12" TextWrapping="Wrap"/>
                    <TextBlock x:Name="Free1" FontSize="12" FontWeight="SemiBold" Margin="0,4,0,0"/>
                </StackPanel>
            </Border>
            <Border Background="{StaticResource Card}" BorderBrush="{StaticResource Edge}" BorderThickness="1" CornerRadius="8" Padding="12,10" Margin="0,0,8,0">
                <StackPanel>
                    <TextBlock Text="Volumes" Foreground="{StaticResource SoftInk}"/>
                    <TextBlock x:Name="Size2" FontSize="20" FontWeight="SemiBold" Text="..."/>
                    <TextBlock x:Name="Info2" Foreground="{StaticResource SoftInk}" FontSize="12" TextWrapping="Wrap"/>
                    <TextBlock x:Name="Free2" FontSize="12" FontWeight="SemiBold" Margin="0,4,0,0"/>
                    <WrapPanel>
                        <Button x:Name="BtnPruneVolumes" Content="Remove unused..." Tag="&#xE74D;" Style="{StaticResource CleanRiskBtn}" IsEnabled="False"
                                ToolTip="Deletes volumes no container uses, running or stopped, and the data in them, for good. Lists them and asks twice first. Runs: docker volume ls --filter dangling=true, then docker volume rm with exactly those names"/>
                    </WrapPanel>
                </StackPanel>
            </Border>
            <Border Background="{StaticResource Card}" BorderBrush="{StaticResource Edge}" BorderThickness="1" CornerRadius="8" Padding="12,10" Margin="0,0,8,0">
                <StackPanel>
                    <TextBlock Text="Build cache" Foreground="{StaticResource SoftInk}"/>
                    <TextBlock x:Name="Size3" FontSize="20" FontWeight="SemiBold" Text="..."/>
                    <TextBlock x:Name="Info3" Foreground="{StaticResource SoftInk}" FontSize="12" TextWrapping="Wrap"/>
                    <TextBlock x:Name="Free3" FontSize="12" FontWeight="SemiBold" Margin="0,4,0,0"/>
                    <WrapPanel>
                        <Button x:Name="BtnPruneBuild" Content="Clean build cache" Tag="&#xE894;" Style="{StaticResource CleanBtn}" IsEnabled="False"
                                ToolTip="Removes files kept to speed up building images. The next build may take longer. Asks first. Runs: docker builder prune -f"/>
                    </WrapPanel>
                </StackPanel>
            </Border>
        </UniformGrid>
        <Grid DockPanel.Dock="Bottom" Margin="0,10,0,0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock Foreground="{StaticResource SoftInk}" TextWrapping="Wrap" VerticalAlignment="Center" Margin="0,0,12,0"
                       Text="Volumes hold container data. Removing one deletes its data for good, so the red button lists them and asks twice. Hover over a button to see exactly what it runs."/>
            <Button x:Name="BtnPruneNetworks" Grid.Column="1" Content="Clean unused networks" Tag="&#xE894;" Style="{StaticResource CleanBtn}" Margin="0" VerticalAlignment="Center"
                    ToolTip="Removes networks no container is connected to (they take almost no space; Compose makes them again when needed). Asks first. Runs: docker network prune -f"/>        </Grid>
        <TextBlock DockPanel.Dock="Top" Text="Images, biggest first" FontWeight="SemiBold" Margin="0,0,0,6"/>
        <Border Background="{StaticResource Card}" BorderBrush="{StaticResource Edge}" BorderThickness="1" CornerRadius="8" Padding="2">
            <Grid>
                <DataGrid x:Name="GridImages" AutoGenerateColumns="False" IsReadOnly="True" HeadersVisibility="Column"
                          GridLinesVisibility="None" BorderThickness="0" Background="Transparent"
                          SelectionMode="Extended" SelectionUnit="FullRow" CanUserAddRows="False" RowHeight="28">
                    <DataGrid.RowStyle>
                        <Style TargetType="DataGridRow">
                            <Setter Property="Background" Value="Transparent"/>
                            <Setter Property="BorderThickness" Value="4,0,0,0"/>
                            <Setter Property="BorderBrush" Value="Transparent"/>
                            <Style.Triggers>
                                <Trigger Property="IsMouseOver" Value="True">
                                    <Setter Property="Background" Value="{DynamicResource Hover}"/>
                                </Trigger>
                                <Trigger Property="IsSelected" Value="True">
                                    <Setter Property="Background" Value="{DynamicResource Selected}"/>
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
                        <DataGridTextColumn Header="Image" Binding="{Binding Name}" Width="*"/>
                        <DataGridTextColumn Header="Size" Binding="{Binding Size}" SortMemberPath="Bytes" Width="90"/>
                        <DataGridTextColumn Header="Created" Binding="{Binding Created}" Width="130"/>
                        <DataGridTextColumn Header="Used by" Binding="{Binding UsedBy}" Width="230"/>
                    </DataGrid.Columns>
                </DataGrid>
                <TextBlock x:Name="TxtDiskEmpty" HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="{StaticResource SoftInk}" Visibility="Collapsed"/>
            </Grid>
        </Border>
    </DockPanel>
</Window>
'@

function ConvertFrom-SizeText([string]$Text) {
    if ($Text -match '([\d.]+)\s*([kMGT]?B)') {
        $mult = @{ B = 1; kB = 1e3; MB = 1e6; GB = 1e9; TB = 1e12 }
        return [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture) * $mult[$Matches[2]]
    }
    return 0
}

function Format-Bytes([double]$Bytes) {
    if ($Bytes -ge 1e9) { return '{0:0.0} GB' -f ($Bytes / 1e9) }
    if ($Bytes -ge 1e6) { return '{0:0} MB' -f ($Bytes / 1e6) }
    if ($Bytes -ge 1e3) { return '{0:0} kB' -f ($Bytes / 1e3) }
    return '{0:0} B' -f $Bytes
}

function Update-DiskWindow {
    $d = $script:DiskForm
    if (-not $d -or -not (Test-DockerReady)) { return }
    $d.Window.Title = 'Disk usage - ' + (Get-MachineName)
    $d.Info.Text = 'Asking Docker...'
    Start-DockerCall -Arguments @('system', 'df', '--format', '{{json .}}') -OnDone {
        param($res)
        $d = $script:DiskForm
        if (-not $d) { return }
        if ($res.ExitCode -ne 0) { $d.Info.Text = "Docker didn't answer: $(Get-FirstLines $res.Error 2)"; return }
        $total = 0.0
        $free = 0.0
        $slot = @{ 'Images' = 0; 'Containers' = 1; 'Local Volumes' = 2; 'Build Cache' = 3 }
        foreach ($line in ($res.Output -split "`r?`n")) {
            if (-not $line.Trim()) { continue }
            try { $o = $line | ConvertFrom-Json } catch { continue }
            $n = $slot[[string]$o.Type]
            if ($null -eq $n) { continue }
            $total += ConvertFrom-SizeText $o.Size
            $free += ConvertFrom-SizeText $o.Reclaimable
            $d["Size$n"].Text = [string]$o.Size
            $d["Info$n"].Text = '{0} in all, {1} in use.' -f $o.TotalCount, $o.Active
            $canFree = ConvertFrom-SizeText $o.Reclaimable
            $freeText = ([string]$o.Reclaimable -replace '\s*\(.*\)$', '')
            $d["Free$n"].Text = if ($canFree -le 0) { 'Nothing to free' } elseif ($n -eq 1) { "$freeText in stopped containers" } else { "$freeText can be freed" }
            $d["Free$n"].Foreground = if ($canFree -gt 0) { $d.Window.FindResource('Ink') } else { $d.Window.FindResource('SoftInk') }
            # A button is on only when there's something for it to remove.
            $unused = 0
            [void][int]::TryParse(([string]$o.TotalCount), [ref]$unused)
            $active = 0
            [void][int]::TryParse(([string]$o.Active), [ref]$active)
            $unused -= $active
            switch ($n) {
                0 { $d.BtnPruneUnused.IsEnabled = ($canFree -gt 0 -or $unused -gt 0) }
                2 { $d.BtnPruneVolumes.IsEnabled = ($unused -gt 0) }
                3 { $d.BtnPruneBuild.IsEnabled = ($canFree -gt 0) }
            }
        }
        $d.Info.Text = 'Docker uses {0} on this PC. About {1} of it can be freed.   Checked {2}' -f (Format-Bytes $total), (Format-Bytes $free), (Get-Date).ToString('HH:mm:ss')
    }
    Start-DockerCall -Arguments @('image', 'ls', '--format', '{{json .}}') -OnDone {
        param($res)
        $d = $script:DiskForm
        if (-not $d) { return }
        $users = @{}
        foreach ($r in $script:Rows) {
            $k = Get-ImageKey $r.Image
            if ($k) { if ($users.ContainsKey($k)) { $users[$k] += ", $($r.Service)" } else { $users[$k] = $r.Service } }
        }
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($line in ($res.Output -split "`r?`n")) {
            if (-not $line.Trim()) { continue }
            try { $o = $line | ConvertFrom-Json } catch { continue }
            $img = New-Object Dcm.ImageInfo
            $img.Repository = [string]$o.Repository
            $img.Tag = [string]$o.Tag
            $img.Id = [string]$o.ID
            $img.Size = [string]$o.Size
            $img.Bytes = ConvertFrom-SizeText $o.Size
            $img.Created = [string]$o.CreatedSince
            $k = if ($img.Repository -ne '<none>') { Get-ImageKey ('{0}:{1}' -f $img.Repository, $(if ($img.Tag -and $img.Tag -ne '<none>') { $img.Tag } else { 'latest' })) } else { '' }
            $img.UsedBy = if ($k -and $users.ContainsKey($k)) { $users[$k] } elseif ($img.Repository -eq '<none>') { 'Nothing (left over from an update)' } else { 'Not in this compose file' }
            $list.Add($img)
        }
        $d.Grid.ItemsSource = @($list | Sort-Object Bytes -Descending)
        $d.BtnPruneDangling.IsEnabled = [bool]@($list | Where-Object { $_.Repository -eq '<none>' }).Count
        $d.Empty.Text = if ($res.ExitCode -ne 0) { "Docker didn't answer: $(Get-FirstLines $res.Error 2)" } else { 'No images on this PC yet.' }
        $d.Empty.Visibility = if ($list.Count) { 'Collapsed' } else { 'Visible' }
    }
}

function Invoke-Prune([string]$What) {
    $owner = $script:DiskForm.Window
    switch ($What) {
        'dangling' {
            $q = "Remove the unnamed images?`n`nThese are old versions left behind after updates. No container uses them."
            $steps = @(New-DockerStep @('image', 'prune', '-f'))
            $label = 'Remove unnamed images'
        }
        'unused' {
            $q = "Remove every image that no container uses?`n`nImages of stopped containers are kept. Services that haven't been created yet download their image again when you start them."
            $steps = @(New-DockerStep @('image', 'prune', '-a', '-f'))
            $label = 'Remove unused images'
        }
        'build' {
            $q = "Clear the build cache?`n`nOnly files kept to speed up building images are removed. The next build may take longer."
            $steps = @(New-DockerStep @('builder', 'prune', '-f'))
            $label = 'Clear build cache'
        }
        'networks' {
            $q = "Remove the networks no container is connected to?`n`nCompose makes them again when the containers that use them start."
            $steps = @(New-DockerStep @('network', 'prune', '-f'))
            $label = 'Remove unused networks'
        }
        default { return }
    }
    if ([Windows.MessageBox]::Show($owner, $q, $script:AppName, 'YesNo', 'Question') -ne 'Yes') { return }
    Add-Job $label $steps
}

# Volumes no container uses (running or stopped). Lists them by name, asks twice,
# then removes exactly those, so nothing else can be caught up in it.
function Invoke-VolumePrune {
    if (-not $script:DiskForm) { return }
    Start-DockerCall -Arguments @('volume', 'ls', '--quiet', '--filter', 'dangling=true') -OnDone {
        param($res)
        $d = $script:DiskForm
        if (-not $d) { return }
        $owner = $d.Window
        if ($res.ExitCode -ne 0) { [void][Windows.MessageBox]::Show($owner, "Docker didn't answer: $(Get-FirstLines $res.Error 2)", $script:AppName, 'OK', 'Warning'); return }
        $names = @(($res.Output -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if (-not $names.Count) { [void][Windows.MessageBox]::Show($owner, 'Every volume is used by a container. Nothing to remove.', $script:AppName, 'OK', 'Information'); return }
        $shown = @($names | Select-Object -First 25) -join "`n"
        if ($names.Count -gt 25) { $shown += "`n... and $($names.Count - 25) more" }
        $q1 = "These $($names.Count) volume(s) aren't used by any container, running or stopped:`n`n$shown`n`nRemove them? Their data is deleted for good."
        if ([Windows.MessageBox]::Show($owner, $q1, $script:AppName, 'YesNo', 'Warning') -ne 'Yes') { return }
        $q2 = "Are you sure? This can't be undone.`n`nThe data in these $($names.Count) volume(s) is lost. A container you remove and make again later starts with empty volumes."
        if ([Windows.MessageBox]::Show($owner, $q2, $script:AppName, 'YesNo', 'Warning', 'No') -ne 'Yes') { return }
        Add-Job "Remove $($names.Count) unused volume(s)" @(New-DockerStep (@('volume', 'rm') + $names) -AllowFail)
    }
}

function Show-Disk {
    if ($script:DiskForm) { $script:DiskForm.Window.Activate(); Update-DiskWindow; return }
    $w = New-XamlObject $diskXaml
    $w.Owner = $window
    if ($window.Icon) { $w.Icon = $window.Icon }
    $d = @{ Window = $w; Info = $w.FindName('TxtDiskInfo'); Grid = $w.FindName('GridImages'); Empty = $w.FindName('TxtDiskEmpty') }
    foreach ($n in 0..3) { $d["Size$n"] = $w.FindName("Size$n"); $d["Info$n"] = $w.FindName("Info$n"); $d["Free$n"] = $w.FindName("Free$n") }
    foreach ($n in 'BtnPruneDangling', 'BtnPruneUnused', 'BtnPruneBuild', 'BtnPruneNetworks', 'BtnPruneVolumes') { $d[$n] = $w.FindName($n) }
    $script:DiskForm = $d
    $w.FindName('BtnDiskRefresh').Add_Click({ Update-DiskWindow })
    $d.BtnPruneDangling.Add_Click({ Invoke-Prune 'dangling' })
    $d.BtnPruneUnused.Add_Click({ Invoke-Prune 'unused' })
    $d.BtnPruneBuild.Add_Click({ Invoke-Prune 'build' })
    $d.BtnPruneNetworks.Add_Click({ Invoke-Prune 'networks' })
    $d.BtnPruneVolumes.Add_Click({ Invoke-VolumePrune })
    $w.Add_KeyDown({ param($src, $e) if ($e.Key -eq 'Escape') { $src.Close() } elseif ($e.Key -eq 'F5') { Update-DiskWindow; $e.Handled = $true } })
    $w.Add_Closed({ $script:DiskForm = $null })
    $w.Show()
    Update-DiskWindow
}

# ---------------------------------------------------------------------------
# Configure window (one per service)
# ---------------------------------------------------------------------------
$configureXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="980" Height="680" MinWidth="700" MinHeight="460" WindowStartupLocation="CenterOwner"
        FontFamily="Segoe UI" FontSize="13" Background="{DynamicResource Page}" Foreground="{DynamicResource Ink}">
    <Window.Resources><!--SHARED--></Window.Resources>
    <DockPanel Margin="14">
        <Grid DockPanel.Dock="Top" Margin="0,0,0,10">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <StackPanel>
                <TextBlock x:Name="TxtCfgTitle" FontSize="18" FontWeight="SemiBold"/>
                <TextBlock x:Name="TxtCfgInfo" Foreground="{StaticResource SoftInk}" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
            </StackPanel>
            <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                <Button x:Name="BtnCfgWeb" Content="Web page" Tag="&#xE774;" Style="{StaticResource Btn}" ToolTip="Open the container's web page"/>
                <Button x:Name="BtnCfgFolder" Content="Folders" Tag="&#xE8B7;" Style="{StaticResource Btn}" ToolTip="Open one of the host folders this container uses"/>
                <Button x:Name="BtnCfgShell" Content="Shell" Tag="&#xE756;" Style="{StaticResource Btn}" ToolTip="Open a command prompt inside the running container"/>
                <Button x:Name="BtnCfgLogs" Content="Logs" Tag="&#xE9F9;" Style="{StaticResource Btn}" Margin="0"/>
            </StackPanel>
        </Grid>

        <Grid DockPanel.Dock="Bottom" Margin="0,10,0,0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <StackPanel VerticalAlignment="Center">
                <CheckBox x:Name="ChkCfgTemplates" IsChecked="True" Visibility="Collapsed"/>
                <TextBlock x:Name="TxtCfgStatus" Foreground="{StaticResource SoftInk}" TextWrapping="Wrap" Margin="0,4,0,0"/>
            </StackPanel>
            <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                <Button x:Name="BtnCfgSaveRecreate" Content="Save and recreate" Tag="&#xE72C;" Style="{StaticResource PrimaryBtn}"
                        ToolTip="Save, then recreate the container so it uses the new values (data is kept)"/>
                <Button x:Name="BtnCfgSave" Content="Save" Tag="&#xE74E;" Style="{StaticResource Btn}"
                        ToolTip="Save the changes. The container shows Changed until it's recreated."/>
                <Button x:Name="BtnCfgClose" Content="Close" Style="{StaticResource Btn}" IsCancel="True" Margin="0"/>
            </StackPanel>
        </Grid>

        <Border DockPanel.Dock="Bottom" Background="{StaticResource Card}" BorderBrush="{StaticResource Edge}" BorderThickness="1" CornerRadius="8" Padding="12" Margin="0,10,0,0">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <TextBlock Text="Name" VerticalAlignment="Center" Margin="0,0,10,0"/>
                <TextBox x:Name="TxtEnvName" Grid.Column="1" Style="{StaticResource Field}" IsReadOnly="True"/>
                <TextBlock Grid.Row="1" Text="Value" VerticalAlignment="Center" Margin="0,8,10,0"/>
                <Grid Grid.Row="1" Grid.Column="1" Margin="0,8,0,0">
                    <TextBox x:Name="TxtEnvValue" Style="{StaticResource Field}"/>
                    <PasswordBox x:Name="PwdEnvValue" Padding="6,4" BorderBrush="{StaticResource Edge}" Visibility="Collapsed"/>
                </Grid>
                <TextBlock x:Name="TxtEnvFrom" Grid.Row="2" Grid.Column="1" Foreground="{StaticResource SoftInk}" FontSize="12" TextWrapping="Wrap" Margin="0,6,0,0"/>
                <StackPanel Grid.Row="3" Grid.Column="1" Orientation="Horizontal" Margin="0,10,0,0">
                    <Button x:Name="BtnEnvSet" Content="Set" Tag="&#xE73E;" Style="{StaticResource Btn}" IsDefault="True"
                            ToolTip="Use this value (saved when you press Save)"/>
                    <Button x:Name="BtnEnvMove" Content="Move to .env" Tag="&#xE8DE;" Style="{StaticResource Btn}"
                            ToolTip="Keep the value in .env and put a ${NAME} reference in the compose file instead"/>
                    <Button x:Name="BtnEnvAdd" Content="Add variable" Tag="&#xE710;" Style="{StaticResource Btn}"
                            ToolTip="Add a new environment variable to this service (its value goes in .env)"/>
                    <Button x:Name="BtnEnvUndo" Content="Undo" Tag="&#xE7A7;" Style="{StaticResource Btn}" Margin="0"
                            ToolTip="Forget the change to this variable"/>
                </StackPanel>
            </Grid>
        </Border>

        <Grid DockPanel.Dock="Top" Margin="0,0,0,6">
            <TextBlock Text="Environment variables" FontWeight="SemiBold" VerticalAlignment="Center"/>
            <CheckBox x:Name="ChkCfgReveal" Content="Show passwords and keys" HorizontalAlignment="Right" VerticalAlignment="Center"/>
        </Grid>
        <Border Background="{StaticResource Card}" BorderBrush="{StaticResource Edge}" BorderThickness="1" CornerRadius="8" Padding="2">
            <Grid>
                <DataGrid x:Name="GridEnv" AutoGenerateColumns="False" IsReadOnly="True" HeadersVisibility="Column"
                          GridLinesVisibility="None" BorderThickness="0" Background="Transparent"
                          SelectionMode="Single" SelectionUnit="FullRow" CanUserAddRows="False" RowHeight="28">
                    <DataGrid.RowStyle>
                        <Style TargetType="DataGridRow">
                            <Setter Property="Background" Value="Transparent"/>
                            <Setter Property="BorderThickness" Value="4,0,0,0"/>
                            <Setter Property="BorderBrush" Value="Transparent"/>
                            <Style.Triggers>
                                <Trigger Property="IsMouseOver" Value="True">
                                    <Setter Property="Background" Value="{DynamicResource Hover}"/>
                                </Trigger>
                                <Trigger Property="IsSelected" Value="True">
                                    <Setter Property="Background" Value="{DynamicResource Selected}"/>
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
                        <DataGridTextColumn Header="Name" Binding="{Binding Name}" Width="230"/>
                        <DataGridTextColumn Header="Value" Binding="{Binding Shown}" Width="*"/>
                        <DataGridTextColumn Header="Kept in" Binding="{Binding From}" Width="200"/>
                        <DataGridTextColumn Header="Status" Binding="{Binding Status}" Width="110"/>
                    </DataGrid.Columns>
                </DataGrid>
                <TextBlock x:Name="TxtEnvEmpty" HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="{StaticResource SoftInk}"
                           Text="This service has no environment variables yet. Press Add variable to give it one." Visibility="Collapsed"/>
            </Grid>
        </Border>
    </DockPanel>
</Window>
'@

function Get-ServiceFolders([string]$Service) {
    # Host folders (bind mounts) of a service, from the last docker compose config.
    $list = New-Object System.Collections.ArrayList
    $svc = if ($script:ServiceConfigs) { $script:ServiceConfigs[$Service] } else { $null }
    if (-not $svc) { return @() }
    foreach ($v in @(Get-PropValue $svc 'volumes')) {
        if ($null -eq $v) { continue }
        if ([string](Get-PropValue $v 'type') -ne 'bind') { continue }
        $src = [string](Get-PropValue $v 'source')
        $dst = [string](Get-PropValue $v 'target')
        if ($src) { [void]$list.Add(@{ Source = $src; Target = $dst }) }
    }
    return @($list)
}

# On another machine the values live in its Env_ file here, which Send to machine copies across as .env.
function Get-ConfigureEnvPath {
    $m = Get-Machine
    if ($m -and $m.EnvFile) { return (Join-Path $script:ComposeDir $m.EnvFile) }
    return (Join-Path $script:ComposeDir '.env')
}

function Import-ConfigureEntries($State) {
    $compose = Read-TextFile $script:ComposePath
    $info = Find-ServiceEnv $compose.Lines $State.Service
    $envVals = Get-EnvFileValues (Get-ConfigureEnvPath)
    $State.Entries.Clear()
    $State.Info = $info
    $State.Stamp = Get-FileStamp
    if (-not $info.Found) {
        $State.Status.Text = "Couldn't find '$($State.Service)' in the compose file."
        return
    }
    foreach ($e in $info.Entries) {
        $x = New-Object Dcm.EnvEntry
        $x.Name = $e.Name; $x.Raw = [string]$e.Raw; $x.Line = $e.Line; $x.Form = $e.Form
        $var = Get-EnvVarReference $e.Raw
        $x.Secret = ($e.Name -match $script:SecretNamePattern) -or ($var -and $var -match $script:SecretNamePattern)
        if ($var) {
            $x.VarName = $var
            $x.Editable = $true
            $uses = Get-VarUseCount $compose.Lines $var
            $x.From = if ($uses -gt 1) { '.env: {0} (used {1} times)' -f $var, $uses } else { '.env: ' + $var }
            $x.Original = if ($envVals.ContainsKey($var)) { $envVals[$var].Value } else { '' }
            $x.Missing = -not $envVals.ContainsKey($var)
        } elseif ($null -eq $e.Raw) {
            $x.From = "This PC's environment"
            $x.Original = [string][Environment]::GetEnvironmentVariable($e.Name)
            $x.Editable = $false
        } elseif ($e.Raw.Replace('$$', '').Contains('$')) {
            $x.From = 'Compose file (uses .env)'
            $x.Original = $e.Raw
            $x.Editable = $false
        } else {
            $x.From = 'Compose file, line {0}' -f ($e.Line + 1)
            $x.Original = $e.Raw.Replace('$$', '$')
            $x.Editable = $true
            $x.Literal = $true
        }
        $x.Value = $x.Original
        $x.Reveal = [bool]$State.Reveal.IsChecked
        $State.Entries.Add($x)
    }
    $State.EmptyText.Visibility = if ($State.Entries.Count) { 'Collapsed' } else { 'Visible' }
    $notes = @()
    if ($info.EnvFiles.Count) {
        $files = @($info.EnvFiles | ForEach-Object { Resolve-ComposeVars $_ (Get-EnvTable $envVals) })
        $notes += 'It also reads variables from ' + ($files -join ', ') + ' (open that file to change them).'
    }
    if (-not (Test-Path -LiteralPath (Get-ConfigureEnvPath))) { $notes += "There's no $([IO.Path]::GetFileName((Get-ConfigureEnvPath))) yet; saving creates one." }
    $m = Get-Machine
    if ($m) { $notes += "Values are saved in $([IO.Path]::GetFileName((Get-ConfigureEnvPath))) on this PC. Save and recreate sends it to $($m.Name) first." }
    $State.Status.Text = ($notes -join '  ')
}

function Get-EnvTable([hashtable]$EnvValues) {
    $t = @{}
    foreach ($k in $EnvValues.Keys) { $t[$k] = $EnvValues[$k].Value }
    return $t
}

function Show-ConfigureEntry($State) {
    $x = $State.Grid.SelectedItem
    $State.Loading = $true
    try {
        $has = $x -is [Dcm.EnvEntry]
        $State.NameBox.Text = if ($has) { $x.Name } else { '' }
        $State.NameBox.IsReadOnly = -not ($has -and $x.IsNew)
        $value = if ($has) { $x.Value } else { '' }
        $State.ValueBox.Text = $value
        $State.PwdBox.Password = $value
        $masked = $has -and $x.Secret -and -not $State.Reveal.IsChecked
        $State.ValueBox.Visibility = if ($masked) { 'Collapsed' } else { 'Visible' }
        $State.PwdBox.Visibility = if ($masked) { 'Visible' } else { 'Collapsed' }
        $editable = $has -and $x.Editable
        $State.ValueBox.IsReadOnly = -not $editable
        $State.PwdBox.IsEnabled = $editable
        $State.SetBtn.IsEnabled = $editable
        $State.MoveBtn.IsEnabled = $has -and $x.Literal -and -not $x.MoveToEnv
        $State.UndoBtn.IsEnabled = $has -and ($x.Status -ne '')
        $State.FromText.Text = if (-not $has) { 'Pick a variable above, or press Add variable.' }
        elseif ($x.IsNew) { 'New variable. Its value is saved in .env and the compose file gets a ${NAME} reference to it.' }
        elseif ($x.MoveToEnv) { 'The value moves to .env when you save, and the compose file gets a ${NAME} reference instead.' }
        elseif ($x.VarName) {
            $t = 'Saved in .env as {0}.' -f $x.VarName
            if ($x.Missing) { $t += " It isn't in .env yet, so the container gets an empty value." }
            if ($x.From -match 'used (\d+) times') { $t += ' Other services use it too, so changing it changes them as well.' }
            $t
        }
        elseif ($x.Literal) {
            $t = 'Written in the compose file on line {0}.' -f ($x.Line + 1)
            if ($x.Secret) { $t += ' Move to .env keeps passwords and keys out of the compose file.' }
            $t
        }
        elseif ($x.From -like 'This PC*') { "Taken from this PC's own environment variables. Set it in Windows, or add it to .env." }
        else { "This value mixes text and variables, so change it in the compose file (Edit) or the variables in .env." }
    } finally { $State.Loading = $false }
}

function Set-ConfigureEntry($State) {
    $x = $State.Grid.SelectedItem
    if (-not ($x -is [Dcm.EnvEntry]) -or -not $x.Editable) { return }
    $value = if ($State.PwdBox.Visibility -eq 'Visible') { $State.PwdBox.Password } else { $State.ValueBox.Text }
    if ($x.IsNew) {
        $name = $State.NameBox.Text.Trim()
        if ($name -notmatch '^[A-Za-z_][A-Za-z0-9_.-]*$') {
            [void][Windows.MessageBox]::Show($State.Window, 'Use letters, numbers and _ for the name, starting with a letter.', $script:AppName, 'OK', 'Information'); return
        }
        foreach ($o in $State.Entries) {
            if ($o -ne $x -and $o.Name -eq $name) { [void][Windows.MessageBox]::Show($State.Window, "There's already a variable called $name.", $script:AppName, 'OK', 'Information'); return }
        }
        $x.Name = $name
        $x.Secret = $name -match $script:SecretNamePattern
    }
    $x.Value = $value
    Show-ConfigureEntry $State
    Update-ConfigureButtons $State
}

function Update-ConfigureButtons($State) {
    $changed = @($State.Entries | Where-Object { $_.Status -ne '' }).Count
    $State.SaveBtn.IsEnabled = $changed -gt 0
    $State.SaveRecreateBtn.IsEnabled = $changed -gt 0
    $State.SaveRecreateBtn.Content = if ($State.Row.HasContainer) { 'Save and recreate' } else { 'Save' }
    $State.SaveBtn.Visibility = if ($State.Row.HasContainer) { 'Visible' } else { 'Collapsed' }
    $State.Window.Title = if ($changed) { 'Configure: {0} ({1} unsaved)' -f $State.Service, $changed } else { 'Configure: ' + $State.Service }
    $templates = @($State.Templates)
    $needsEnv = @($State.Entries | Where-Object { $_.IsNew -or $_.MoveToEnv }).Count
    $State.Templates_Check.Visibility = if ($templates.Count -and $needsEnv) { 'Visible' } else { 'Collapsed' }
}

function Save-ConfigureEntries($State, [switch]$Recreate) {
    $changed = @($State.Entries | Where-Object { $_.Status -ne '' })
    if (-not $changed.Count) { return }
    if ((Get-FileStamp) -ne $State.Stamp) {
        [void][Windows.MessageBox]::Show($State.Window, "The compose file or .env was changed somewhere else since this window opened, so nothing was saved.`n`nYour changes are still listed. Note them, then press Reload.", $script:AppName, 'OK', 'Warning')
        return
    }
    $compose = Read-TextFile $script:ComposePath
    $info = Find-ServiceEnv $compose.Lines $State.Service
    foreach ($x in $changed) {
        if ($x.IsNew) { continue }
        $match = @($info.Entries | Where-Object { $_.Line -eq $x.Line -and $_.Name -eq $x.Name })
        if (-not $match.Count) {
            [void][Windows.MessageBox]::Show($State.Window, "The compose file doesn't match what this window read any more, so nothing was saved. Press Reload.", $script:AppName, 'OK', 'Warning')
            return
        }
    }
    $envPath = Get-ConfigureEnvPath
    $envExists = Test-Path -LiteralPath $envPath
    $envFile = if ($envExists) { Read-TextFile $envPath } else {
        @{ Path = $envPath; Lines = (New-Object System.Collections.Generic.List[string]); Bom = $false; NewLine = "`r`n"; EndsWithNewline = $true }
    }
    $envVals = Get-EnvFileValues $envPath
    $composeChanged = $false; $envChanged = $false
    $newVars = [ordered]@{}
    $inserts = New-Object System.Collections.ArrayList
    $log = New-Object System.Collections.ArrayList

    foreach ($x in $changed) {
        if ($x.IsNew) {
            $var = New-EnvVarName $State.Service $x.Name $envVals $x.Value
            Set-EnvFileValue $envFile $var $x.Value; $envChanged = $true
            $envVals[$var] = @{ Value = $x.Value; Line = -1 }
            $newVars[$var] = $x.Value
            [void]$inserts.Add(@($x.Name, ('${' + $var + '}')))
            [void]$log.Add("added $($x.Name) (value in .env as $var)")
        } elseif ($x.VarName) {
            Set-EnvFileValue $envFile $x.VarName $x.Value; $envChanged = $true
            $envVals[$x.VarName] = @{ Value = $x.Value; Line = -1 }
            [void]$log.Add("changed $($x.VarName) in .env")
        } elseif ($x.MoveToEnv) {
            $var = New-EnvVarName $State.Service $x.Name $envVals $x.Value
            Set-EnvFileValue $envFile $var $x.Value; $envChanged = $true
            $envVals[$var] = @{ Value = $x.Value; Line = -1 }
            $newVars[$var] = $x.Value
            $compose.Lines[$x.Line] = Format-ComposeEnvLine (Get-LineIndent $compose.Lines[$x.Line]) $x.Form $x.Name ('${' + $var + '}')
            $composeChanged = $true
            [void]$log.Add("moved $($x.Name) to .env as $var")
        } elseif ($x.Literal) {
            $compose.Lines[$x.Line] = Format-ComposeEnvLine (Get-LineIndent $compose.Lines[$x.Line]) $x.Form $x.Name ($x.Value.Replace('$', '$$'))
            $composeChanged = $true
            [void]$log.Add("changed $($x.Name) in the compose file")
        }
    }

    if ($inserts.Count) {
        $form = if ($info.Form) { $info.Form } else { 'list' }
        $itemIndent = if ($info.ItemIndent -ge 0) { $info.ItemIndent } else { $info.KeyIndent + 2 }
        $newLines = New-Object System.Collections.Generic.List[string]
        if ($info.EnvLine -lt 0) { $newLines.Add((' ' * $info.KeyIndent) + 'environment:') }
        foreach ($p in $inserts) { $newLines.Add((Format-ComposeEnvLine $itemIndent $form $p[0] $p[1])) }
        $at = if ($info.Entries.Count) { ($info.Entries | ForEach-Object { $_.Line } | Measure-Object -Maximum).Maximum + 1 }
        elseif ($info.EnvLine -ge 0) { $info.EnvLine + 1 }
        else { $info.End + 1 }
        $compose.Lines.InsertRange($at, $newLines)
        $composeChanged = $true
    }

    try {
        $backups = @()
        if ($composeChanged) { $backups += Backup-ConfigFile $script:ComposePath }
        if ($envChanged -and $envExists) { $backups += Backup-ConfigFile $envPath }
        if ($composeChanged) { Write-TextFile $compose }
        if ($envChanged) { Write-TextFile $envFile }
        if ($newVars.Count -and $State.Templates_Check.IsChecked) {
            foreach ($t in @($State.Templates)) {
                $tf = Read-TextFile $t
                $have = Get-EnvFileValues $t
                $added = 0
                foreach ($k in $newVars.Keys) { if (-not $have.ContainsKey($k)) { Set-EnvFileValue $tf $k $newVars[$k]; $added++ } }
                if ($added) { Write-TextFile $tf; [void]$log.Add("added $added value(s) to $([IO.Path]::GetFileName($t))") }
            }
        }
    } catch {
        [void][Windows.MessageBox]::Show($State.Window, "Saving failed: $($_.Exception.Message)", $script:AppName, 'OK', 'Error')
        Write-Activity "Configure $($State.Service): saving failed: $($_.Exception.Message)"
        return
    }
    Write-Activity ("Configure {0}: {1}." -f $State.Service, ($log -join ', '))
    foreach ($b in $backups) { if ($b) { Write-Activity "Backup: $b" } }
    Import-ConfigureEntries $State
    Update-ConfigureButtons $State
    $script:FileStamp = Get-FileStamp
    Request-ConfigLoad
    if ($Recreate -and $State.Row.HasContainer) {
        $steps = @()
        if (Get-Machine) {
            $send = Get-SendSteps (Get-Machine)
            if (-not $send) { return }
            $steps += $send
        }
        $steps += Get-RecreateSteps @($State.Row) -Force
        Add-Job ('Apply settings: ' + $State.Service) $steps
        $State.Status.Text = 'Saved. Recreating the container with the new values...'
    } else {
        $State.Status.Text = if ($State.Row.HasContainer) { 'Saved. The container shows Changed until you recreate it.' } else { 'Saved. The container uses the new values when it is created.' }
    }
}

function Backup-ConfigFile([string]$Path) {
    # Copies to %APPDATA%\Docker Container Manager\Backups\<project>\, not next to the file.
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $project = if ($script:ProjectName) { $script:ProjectName } else { 'compose' }
    $dir = Join-Path (Join-Path $script:SettingsDir 'Backups') $project
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $target = Join-Path $dir ('{0}.{1}.bak' -f [IO.Path]::GetFileName($Path), (Get-Date).ToString('yyyy-MM-dd_HHmmss'))
    Copy-Item -LiteralPath $Path -Destination $target -Force
    return $target
}

function Open-ContainerShell([Dcm.Row]$Row) {
    if (-not $Row -or -not $Row.IsRunning -or -not (Test-DockerReady)) { return }
    $m = Get-Machine
    try {
        if ($m) {
            # ssh -t gives the shell a terminal; the remote command is one quoted word.
            $remote = (Get-RemotePathPrefix) + "$($m.Docker) exec -it $($Row.ContainerName) sh -c 'if command -v bash >/dev/null 2>&1; then exec bash; else exec sh; fi'"
            $argLine = [Dcm.Runner]::Join([string[]](@(Get-SshArguments $m -Tty) + @($remote)))
            Start-Process -FilePath (Find-Ssh) -ArgumentList $argLine
        } else {
            $argLine = 'exec -it {0} sh -c "if command -v bash >/dev/null 2>&1; then exec bash; else exec sh; fi"' -f $Row.ContainerName
            Start-Process -FilePath $script:DockerExe -ArgumentList $argLine
        }
        Write-Activity "Opened a shell in $($Row.ContainerName)"
    } catch { [void][Windows.MessageBox]::Show($window, "Couldn't open a shell: $($_.Exception.Message)", $script:AppName, 'OK', 'Error') }
}

function Show-Configure([Dcm.Row]$Row) {
    if (-not $Row -or -not $Row.InCompose -or -not $script:ComposePath) { return }
    foreach ($open in @($script:ConfigureWindows)) {
        if ($open.Service -eq $Row.Service) { $open.Window.Activate(); return }
    }
    $w = New-XamlObject $configureXaml
    $w.Owner = $window
    if ($window.Icon) { $w.Icon = $window.Icon }
    $state = @{
        Window = $w; Row = $Row; Service = $Row.Service; Info = $null; Stamp = ''; Loading = $false
        Entries = New-Object 'System.Collections.ObjectModel.ObservableCollection[Dcm.EnvEntry]'
        Templates = @(Get-ChildItem -LiteralPath $script:ComposeDir -Filter 'Env_*' -File -ErrorAction SilentlyContinue | ForEach-Object FullName)
        Grid = $w.FindName('GridEnv'); EmptyText = $w.FindName('TxtEnvEmpty'); Reveal = $w.FindName('ChkCfgReveal')
        NameBox = $w.FindName('TxtEnvName'); ValueBox = $w.FindName('TxtEnvValue'); PwdBox = $w.FindName('PwdEnvValue'); FromText = $w.FindName('TxtEnvFrom')
        SetBtn = $w.FindName('BtnEnvSet'); MoveBtn = $w.FindName('BtnEnvMove'); AddBtn = $w.FindName('BtnEnvAdd'); UndoBtn = $w.FindName('BtnEnvUndo')
        SaveBtn = $w.FindName('BtnCfgSave'); SaveRecreateBtn = $w.FindName('BtnCfgSaveRecreate'); Status = $w.FindName('TxtCfgStatus')
        Templates_Check = $w.FindName('ChkCfgTemplates')
    }
    $names = @($state.Templates | ForEach-Object { [IO.Path]::GetFileName($_) })
    $state.Templates_Check.Content = 'Also add new .env values to ' + ($names -join ', ') + ' (the templates you copy to other machines)'
    $w.FindName('TxtCfgTitle').Text = $Row.Service
    $w.FindName('TxtCfgInfo').Text = '{0}   ·   {1}   ·   {2}' -f $Row.Image, $Row.Group, $Row.StateText
    $state.Grid.ItemsSource = $state.Entries
    [void]$script:ConfigureWindows.Add($state)
    $w.DataContext = $state

    $web = $w.FindName('BtnCfgWeb'); $web.IsEnabled = $Row.HasUrl
    $web.Add_Click({ $s = $this.DataContext; Open-Url $s.Row.Url })
    $shell = $w.FindName('BtnCfgShell'); $shell.IsEnabled = $Row.IsRunning
    if (-not $Row.IsRunning) { $shell.ToolTip = 'Start the container to open a shell in it' }
    $shell.Add_Click({ $s = $this.DataContext; Open-ContainerShell $s.Row })
    $logs = $w.FindName('BtnCfgLogs'); $logs.IsEnabled = $Row.HasContainer
    $logs.Add_Click({ $s = $this.DataContext; Show-Logs $s.Row })

    $folderBtn = $w.FindName('BtnCfgFolder')
    $folders = @(Get-ServiceFolders $Row.Service)
    $menu = New-Object Windows.Controls.ContextMenu
    foreach ($f in $folders) {
        $item = New-Object Windows.Controls.MenuItem
        $item.Header = '{0}   ->   {1}' -f $f.Source, $f.Target
        $item.Tag = $f.Source
        $item.Add_Click({
                $p = [string]$this.Tag
                if (Test-Path -LiteralPath $p -PathType Container) { Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$p`"" }
                elseif (Test-Path -LiteralPath $p) { Start-Process -FilePath 'explorer.exe' -ArgumentList "/select,`"$p`"" }
                else { [void][Windows.MessageBox]::Show("$p doesn't exist yet. Docker creates it when the container starts.", $script:AppName, 'OK', 'Information') }
            })
        [void]$menu.Items.Add($item)
    }
    $folderBtn.IsEnabled = ($folders.Count -gt 0)
    if (-not $folders.Count) { $folderBtn.ToolTip = "This container doesn't use any host folders" }
    Set-MenuTheme $menu $w
    $folderBtn.ContextMenu = $menu
    $folderBtn.Add_Click({ $this.ContextMenu.PlacementTarget = $this; $this.ContextMenu.IsOpen = $true })

    $state.Grid.Add_SelectionChanged({ param($src) try { Show-ConfigureEntry $src.DataContext } catch { Write-Activity "Configure: $($_.Exception.Message)" } })
    $state.Reveal.Add_Click({
            $s = $this.DataContext
            foreach ($x in $s.Entries) { $x.Reveal = [bool]$s.Reveal.IsChecked }
            Show-ConfigureEntry $s
        })
    $state.SetBtn.Add_Click({ Set-ConfigureEntry $this.DataContext })
    $state.MoveBtn.Add_Click({
            $s = $this.DataContext; $x = $s.Grid.SelectedItem
            if ($x -is [Dcm.EnvEntry] -and $x.Literal) {
                $x.Value = if ($s.PwdBox.Visibility -eq 'Visible') { $s.PwdBox.Password } else { $s.ValueBox.Text }
                $x.MoveToEnv = $true
                Show-ConfigureEntry $s; Update-ConfigureButtons $s
            }
        })
    $state.AddBtn.Add_Click({
            $s = $this.DataContext
            $x = New-Object Dcm.EnvEntry
            $x.Name = 'NEW_VARIABLE'; $x.IsNew = $true; $x.Editable = $true; $x.From = '.env (when saved)'; $x.Line = -1
            $x.Reveal = [bool]$s.Reveal.IsChecked
            $s.Entries.Add($x)
            $s.EmptyText.Visibility = 'Collapsed'
            $s.Grid.SelectedItem = $x
            $s.Grid.ScrollIntoView($x)
            [void]$s.NameBox.Focus(); $s.NameBox.SelectAll()
            Update-ConfigureButtons $s
        })
    $state.UndoBtn.Add_Click({
            $s = $this.DataContext; $x = $s.Grid.SelectedItem
            if (-not ($x -is [Dcm.EnvEntry])) { return }
            if ($x.IsNew) { [void]$s.Entries.Remove($x) } else { $x.MoveToEnv = $false; $x.Value = $x.Original }
            Show-ConfigureEntry $s; Update-ConfigureButtons $s
        })
    $state.SaveBtn.Add_Click({ Save-ConfigureEntries $this.DataContext })
    $state.SaveRecreateBtn.Add_Click({ $s = $this.DataContext; Save-ConfigureEntries $s -Recreate:($s.Row.HasContainer) })
    $w.FindName('BtnCfgClose').Add_Click({ $this.DataContext.Window.Close() })
    $w.Add_Closing({
            param($src, $e)
            $s = $src.DataContext
            $n = @($s.Entries | Where-Object { $_.Status -ne '' }).Count
            if ($n -and [Windows.MessageBox]::Show($src, "Close without saving $n change(s)?", $script:AppName, 'YesNo', 'Question') -ne 'Yes') { $e.Cancel = $true }
        })
    $w.Add_Closed({ $script:ConfigureWindows.Remove($this.DataContext) })
    $w.Add_KeyDown({ param($src, $e) if ($e.Key -eq 'Escape') { $src.Close() } })

    try { Import-ConfigureEntries $state } catch { $state.Status.Text = "Couldn't read the compose file: $($_.Exception.Message)" }
    Update-ConfigureButtons $state
    Show-ConfigureEntry $state
    $w.Show()
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
        $State.Runner = New-DockerRunner ([string[]]$cmd) $false
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
        Title="Settings" Width="680" SizeToContent="Height" ResizeMode="NoResize" WindowStartupLocation="CenterOwner"
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
                    <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
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
                <TextBlock Grid.Row="2" Text="Editor" VerticalAlignment="Top" Margin="0,5,0,10"/>
                <StackPanel Grid.Row="2" Grid.Column="1" Margin="0,0,0,10">
                    <Grid>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <TextBox x:Name="TxtEditor" Style="{StaticResource Field}" ToolTip="Visual Studio Code by default. Leave empty, or point at a missing program, to use Notepad"/>
                        <Button x:Name="BtnEditorCheck" Grid.Column="1" Content="Check" Tag="&#xE73E;" Style="{StaticResource Btn}" Margin="6,0,0,0"
                                ToolTip="Check that the editor is there, and suggest one if it isn't"/>
                        <Button x:Name="BtnEditor" Grid.Column="2" Content="Browse..." Style="{StaticResource Btn}" Margin="6,0,0,0"/>
                    </Grid>
                    <Grid x:Name="PnlEditorCheck" Margin="0,6,0,0" Visibility="Collapsed">
                        <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                        <TextBlock x:Name="TxtEditorCheckIcon" FontFamily="Segoe MDL2 Assets" FontSize="12" Margin="1,3,8,0" VerticalAlignment="Top"/>
                        <StackPanel Grid.Column="1">
                            <TextBlock x:Name="TxtEditorCheck" FontSize="12" TextWrapping="Wrap"/>
                            <WrapPanel Margin="0,3,0,0">
                                <Button x:Name="BtnEditorUse" Style="{StaticResource LinkBtn}" FontSize="12" Margin="0,0,14,0" Visibility="Collapsed"
                                        ToolTip="Put this editor in the box (saved when you press Save)"/>
                                <Button x:Name="BtnEditorOther" Content="Choose another editor..." Style="{StaticResource LinkBtn}" FontSize="12"
                                        ToolTip="Pick any program on this PC, wherever it's installed (saved when you press Save)"/>
                            </WrapPanel>
                        </StackPanel>
                    </Grid>
                </StackPanel>
                <TextBlock Grid.Row="3" Text="Theme" VerticalAlignment="Center" Margin="0,0,0,10"/>
                <StackPanel Grid.Row="3" Grid.Column="1" Orientation="Horizontal" Margin="0,0,0,10">
                    <ComboBox x:Name="CmbTheme" Width="150" VerticalContentAlignment="Center"/>
                    <TextBlock Text="takes effect when the app starts" VerticalAlignment="Center" Margin="8,0,0,0" Foreground="{StaticResource SoftInk}"/>
                </StackPanel>
                <CheckBox x:Name="ChkPrune" Grid.Row="4" Grid.ColumnSpan="2" Margin="0,0,0,8"
                          Content="After Update, remove images nothing uses any more (docker image prune)"/>
                <CheckBox x:Name="ChkConfirm" Grid.Row="5" Grid.ColumnSpan="2" Margin="0,0,0,8" Content="Ask before stopping a group"/>
                <CheckBox x:Name="ChkTray" Grid.Row="6" Grid.ColumnSpan="2" Margin="0,0,0,8" Content="Minimise to the notification area (tray)"/>
                <CheckBox x:Name="ChkIcons" Grid.Row="7" Grid.ColumnSpan="2" Margin="0,0,0,8"
                          Content="Show app icons (downloaded once and kept on this PC)"/>
                <CheckBox x:Name="ChkUpdates" Grid.Row="8" Grid.ColumnSpan="2" Margin="0,0,0,8"
                          Content="Check for newer images when the app starts (at most every 12 hours)"/>
                <CheckBox x:Name="ChkProgress" Grid.Row="9" Grid.ColumnSpan="2" Margin="0,0,0,8"
                          Content="Show a progress window while Docker is starting, stopping or updating containers"/>
                <CheckBox x:Name="ChkFinished" Grid.Row="10" Grid.ColumnSpan="2"
                          Content="Show a box when Docker has finished (when the progress window is hidden)"/>
            </Grid>
        </Border>
        <TextBlock x:Name="TxtWhere" Foreground="{StaticResource SoftInk}" FontSize="12" TextWrapping="Wrap" Margin="2,10,0,0"/>
        <StackPanel Orientation="Horizontal" Margin="2,4,0,0">
            <Button x:Name="BtnSourceLinks" Content="Edit source links..." Style="{StaticResource LinkBtn}" Margin="0,0,16,0" ToolTip="Your own list of project pages for the Source button, kept on this PC (source-links.txt)"/>
            <Button x:Name="BtnMyGroups" Content="My groups..." Style="{StaticResource LinkBtn}" ToolTip="Your own list of which group each container goes in, used first by Group automatically (my-groups.txt on this PC)"/>
        </StackPanel>
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
    $script:SettingsForm.TxtPrefixHelp.Text = "Groups come from the $p.group label. $p.url sets a container's web page ($p.url=none hides it), $p.description its tooltip, $p.icon its icon, $p.color its group's colour and $p.source its source page."
}

# The editor path as typed, without quotes and with %VARIABLES% filled in.
function Resolve-EditorPath([string]$Text) {
    $p = ([string]$Text).Trim().Trim('"').Trim()
    if (-not $p) { return '' }
    return [Environment]::ExpandEnvironmentVariables($p)
}

# Is there a program at this path? Returns Ok, the path and a sentence to show.
function Test-EditorPath([string]$Text) {
    $p = Resolve-EditorPath $Text
    $r = [pscustomobject]@{ Ok = $false; Path = $p; Message = '' }
    if (-not $p) { $r.Message = 'No editor is set, so Notepad is used.'; return $r }
    try {
        if (Test-Path -LiteralPath $p -PathType Container) { $r.Message = "That's a folder, not a program: $p"; return $r }
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { $r.Message = "There's nothing at $p"; return $r }
    } catch { $r.Message = "That isn't a path Windows can use: $p"; return $r }
    if ([IO.Path]::GetExtension($p).ToLowerInvariant() -notin '.exe', '.cmd', '.bat') {
        $r.Message = "That isn't a program (.exe, .cmd or .bat): $p"; return $r
    }
    $r.Ok = $true
    $r.Message = 'Found: ' + (Get-EditorName $p)
    return $r
}

# A friendly name for a program: its product name and version when it has them.
function Get-EditorName([string]$Path) {
    $name = [IO.Path]::GetFileName($Path)
    try {
        $vi = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
        $product = if ($vi.ProductName) { $vi.ProductName.Trim() } elseif ($vi.FileDescription) { $vi.FileDescription.Trim() } else { '' }
        if ($product) {
            $name = $product
            if ($vi.ProductVersion) { $name += ' ' + $vi.ProductVersion.Trim() }
        }
    } catch { Write-Verbose "No version information for $Path." }
    return $name
}

# Where Windows says a program is installed, wherever that is: its App Paths entry,
# its uninstall entry (InstallLocation or DisplayIcon) and, for VS Code, code.cmd on the PATH.
function Find-InstalledEditor([string]$Exe, [string]$DisplayName, [string]$OnPath) {
    $found = New-Object System.Collections.ArrayList
    foreach ($hive in 'HKCU:', 'HKLM:') {
        try {
            $v = (Get-ItemProperty -LiteralPath "$hive\Software\Microsoft\Windows\CurrentVersion\App Paths\$Exe" -ErrorAction Stop).'(default)'
            if ($v) { [void]$found.Add(([string]$v).Trim('"')) }
        } catch { Write-Verbose "No App Paths entry for $Exe in $hive." }
    }
    foreach ($key in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall') {
        foreach ($app in @(Get-ItemProperty -Path "$key\*" -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like $DisplayName })) {
            if ($app.InstallLocation) { [void]$found.Add((Join-Path ([string]$app.InstallLocation).Trim('"') $Exe)) }
            if ($app.DisplayIcon) { [void]$found.Add((([string]$app.DisplayIcon) -replace ',\s*-?\d+$', '').Trim('"')) }
        }
    }
    if ($OnPath) {
        # VS Code puts bin\code.cmd on the PATH; Code.exe is one folder up.
        foreach ($c in @(Get-Command $OnPath -CommandType Application -ErrorAction SilentlyContinue)) {
            [void]$found.Add((Join-Path (Split-Path (Split-Path $c.Source -Parent) -Parent) $Exe))
        }
    }
    return @($found | Where-Object { $_ -and [IO.Path]::GetFileName($_) -ieq $Exe } | Select-Object -Unique)
}

# The first editor found on this PC (VS Code, then Notepad++, then Notepad), other than $Skip.
function Find-Editor([string]$Skip) {
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Microsoft VS Code\Code.exe'),
        $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\Code.exe' })
    ) + @(Find-InstalledEditor 'Code.exe' 'Microsoft Visual Studio Code*' 'code.cmd') + @(
        (Join-Path $env:ProgramFiles 'Notepad++\notepad++.exe'),
        $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} 'Notepad++\notepad++.exe' })
    ) + @(Find-InstalledEditor 'notepad++.exe' 'Notepad++*' '') + @(
        (Join-Path ([Environment]::SystemDirectory) 'notepad.exe'),
        $(if ($env:WINDIR) { Join-Path $env:WINDIR 'notepad.exe' })
    )
    foreach ($c in $candidates) {
        if (-not $c -or -not (Test-Path -LiteralPath $c -PathType Leaf)) { continue }
        if ($Skip -and [string]::Equals($c, $Skip, [StringComparison]::OrdinalIgnoreCase)) { continue }
        return $c
    }
    return $null
}

# Check the editor box and show the result under it, with a "Use ..." link when there's a better choice.
function Update-EditorCheck {
    $f = $script:SettingsForm
    $r = Test-EditorPath $f.TxtEditor.Text
    $f.EditorChecked = $r.Path
    $f.PnlEditorCheck.Visibility = 'Visible'
    $f.TxtEditorCheck.Text = $r.Message
    if ($r.Ok) {
        $f.TxtEditorCheckIcon.Text = [string][char]0xE73E
        $f.TxtEditorCheckIcon.Foreground = $f.Window.FindResource('Ok')
        $f.TxtEditorCheck.Foreground = $f.Window.FindResource('Ink')
        $f.BtnEditorUse.Visibility = 'Collapsed'
        return
    }
    $f.TxtEditorCheckIcon.Text = [string][char]0xE711
    $f.TxtEditorCheckIcon.Foreground = $f.Window.FindResource('Bad')
    $f.TxtEditorCheck.Foreground = $f.Window.FindResource('Ink')
    $found = Find-Editor $r.Path
    if ($found) {
        $f.EditorSuggestion = $found
        $name = Get-EditorName $found
        $f.TxtEditorCheck.Text = $r.Message + "`nThis PC has $name at $found"
        $f.BtnEditorUse.Content = "Use $name"
        $f.BtnEditorUse.ToolTip = "Put $found in the box (saved when you press Save)"
        $f.BtnEditorUse.Visibility = 'Visible'
    }
    else {
        $f.EditorSuggestion = $null
        $f.BtnEditorUse.Visibility = 'Collapsed'
    }
}

# Pick the editor with a file dialog, starting where the box points (or Program Files).
function Select-EditorFile {
    $s = $script:SettingsForm
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Title = 'Choose your editor'
    $dlg.Filter = 'Programs (*.exe;*.cmd;*.bat)|*.exe;*.cmd;*.bat|All files (*.*)|*.*'
    $start = ''
    foreach ($p in @((Resolve-EditorPath $s.TxtEditor.Text), [string]$s.EditorSuggestion)) {
        if (-not $p) { continue }
        try {
            $dir = if (Test-Path -LiteralPath $p -PathType Container) { $p } else { Split-Path -Path $p -Parent }
            if ($dir -and (Test-Path -LiteralPath $dir -PathType Container)) { $start = $dir; break }
        } catch { Write-Verbose "Not a usable folder: $p" }
    }
    $dlg.InitialDirectory = if ($start) { $start } else { $env:ProgramFiles }
    if ($dlg.ShowDialog($s.Window)) { $s.TxtEditor.Text = $dlg.FileName; Update-EditorCheck }
}

function Show-Settings {
    $w = New-XamlObject $settingsXaml
    $w.Owner = $window
    if ($window.Icon) { $w.Icon = $window.Icon }
    $f = @{ Window = $w; Saved = $false }
    foreach ($n in 'TxtPrefix', 'TxtPrefixHelp', 'TxtRefresh', 'TxtEditor', 'BtnEditor', 'BtnEditorCheck', 'PnlEditorCheck', 'TxtEditorCheckIcon', 'TxtEditorCheck', 'BtnEditorUse', 'BtnEditorOther', 'CmbTheme', 'ChkPrune', 'ChkConfirm', 'ChkTray', 'ChkIcons', 'ChkUpdates', 'ChkProgress', 'ChkFinished', 'TxtWhere', 'BtnSaveSettings') { $f[$n] = $w.FindName($n) }
    $w.FindName('BtnSourceLinks').Add_Click({ Edit-SourceList })
    $w.FindName('BtnMyGroups').Add_Click({ Show-MyGroups $script:SettingsForm.Window })
    $script:SettingsForm = $f
    $f.TxtPrefix.Text = $script:Settings.LabelPrefix
    $f.TxtRefresh.Text = [string]$script:Settings.RefreshSeconds
    $f.TxtEditor.Text = $script:Settings.Editor
    $f.ChkPrune.IsChecked = [bool]$script:Settings.PruneAfterUpdate
    $f.ChkConfirm.IsChecked = [bool]$script:Settings.ConfirmGroupStop
    $f.ChkTray.IsChecked = [bool]$script:Settings.MinimiseToTray
    $f.ChkIcons.IsChecked = [bool]$script:Settings.DownloadIcons
    $f.ChkUpdates.IsChecked = [bool]$script:Settings.CheckUpdatesOnStart
    $f.ChkProgress.IsChecked = [bool]$script:Settings.ShowProgress
    $f.ChkFinished.IsChecked = [bool]$script:Settings.ShowFinished
    foreach ($t in 'System', 'Light', 'Dark') { [void]$f.CmbTheme.Items.Add($t) }
    $f.CmbTheme.SelectedItem = [string]$script:Settings.Theme
    $f.TxtWhere.Text = "Saved in $script:SettingsPath"
    Update-PrefixHelp
    $f.TxtPrefix.Add_TextChanged({ Update-PrefixHelp })
    $f.BtnEditor.Add_Click({ Select-EditorFile })
    $f.BtnEditorOther.Add_Click({ Select-EditorFile })
    $f.BtnEditorCheck.Add_Click({ Update-EditorCheck })
    $f.BtnEditorUse.Add_Click({
            $s = $script:SettingsForm
            if ($s.EditorSuggestion) { $s.TxtEditor.Text = $s.EditorSuggestion; Update-EditorCheck }
        })
    # A result is about the path that was checked: hide it once the path is changed by hand.
    $f.TxtEditor.Add_TextChanged({
            $s = $script:SettingsForm
            if ($s -and $s.PnlEditorCheck.Visibility -eq 'Visible' -and (Resolve-EditorPath $s.TxtEditor.Text) -ne $s.EditorChecked) { $s.PnlEditorCheck.Visibility = 'Collapsed' }
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
            if ($editor -and -not (Test-EditorPath $editor).Ok) {
                Update-EditorCheck
                [void][Windows.MessageBox]::Show($f.Window, "Editor: there's no program at $(Resolve-EditorPath $editor). Leave it empty to use Notepad, or see the suggestion under the box.", 'Settings', 'OK', 'Warning'); return
            }
            $prefixChanged = ($prefix -ne $script:Settings.LabelPrefix)
            $script:Settings.LabelPrefix = $prefix
            $script:Settings.RefreshSeconds = $sec
            $script:Settings.Editor = $editor
            $script:Settings.PruneAfterUpdate = [bool]$f.ChkPrune.IsChecked
            $script:Settings.ConfirmGroupStop = [bool]$f.ChkConfirm.IsChecked
            $script:Settings.MinimiseToTray = [bool]$f.ChkTray.IsChecked
            $iconsChanged = ([bool]$f.ChkIcons.IsChecked -ne [bool]$script:Settings.DownloadIcons)
            $script:Settings.DownloadIcons = [bool]$f.ChkIcons.IsChecked
            $script:Settings.CheckUpdatesOnStart = [bool]$f.ChkUpdates.IsChecked
            $script:Settings.ShowProgress = [bool]$f.ChkProgress.IsChecked
            $script:Settings.ShowFinished = [bool]$f.ChkFinished.IsChecked
            $theme = [string]$f.CmbTheme.SelectedItem
            $themeChanged = ($theme -and $theme -ne $script:Settings.Theme)
            if ($theme) { $script:Settings.Theme = $theme }
            Save-Settings
            if ($iconsChanged) { Update-Icons }
            if ($themeChanged) { [void][Windows.MessageBox]::Show($f.Window, 'The new theme is used the next time you start the app.', 'Settings', 'OK', 'Information') }
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
    '1.10' = @(
        'My groups: your own list of which group each container goes in, kept on this PC and ready from the start (the built-in list, or the first compose file loaded). Group automatically uses it first and only guesses the rest (the From column says which), and can add what you save to it.',
        'My groups window (from Group automatically or Settings): sort, filter, add, change and remove rows, fill it from the current compose file''s labels, reset it to the built-in list, open it in your editor. A backup is kept on each save.'
    )
    '1.09' = @(
        'Compose file list: Other compose file... at the end picks a file anywhere on this PC, and right-click an entry for Remove from list (the file itself is never touched).',
        'Settings: Check also finds VS Code and Notepad++ wherever Windows says they''re installed (not only the usual folders), and Choose another editor... under the result lets you pick any program.',
        'Group automatically: Save groups shows a Saving groups box with each step as it happens (adding the labels, checking a test copy, the backup, writing and checking the file, reloading). If a step fails it says why, and the compose file is left as it was.'
    )
    '1.08' = @(
        'Disk usage: smaller clean-up buttons sit in each card next to the space they free, off when there''s nothing to free. Volumes (which deletes data) is red, and each tooltip says exactly what it runs.',
        'Settings: a Check button beside the editor says whether the program is there. If it isn''t, it offers Visual Studio Code, Notepad++ or Notepad, and Use fills the box (saved when you press Save).',
        'About: split into sections (About, What''s new, This PC, Keyboard shortcuts) that open and close with a click. What''s new has a section for each version, with only the newest open.',
        'About: the window is never taller than the screen. The middle part scrolls, while the header and the Close button stay in view.'
    )
    '1.07' = @(
        'Export: the Light / dark switch is bigger and sits in the blue header at the top of the page, so it''s easy to find.'
    )
    '1.06' = @(
        'Source page: right-click a container (or press Source) to open its project page on GitHub, GitLab or Docker Hub. Your own list of links (Edit source links) is kept on this PC.',
        'Export: saves the list as one web page (HTML) to keep, print or send, with icons, states, web pages and source pages. It uses the app''s light or dark theme, with a switch at the top of the page.',
        'Help (F1): a guide to every part of the app, with the text you can select and copy.'
    )
    '1.05' = @(
        'Group automatically: suggests a group for each container without one, from its image name. You check and change the list before anything is saved, and the compose file is backed up first.',
        'Portainer button: opens Portainer on the chosen machine, starts it when it''s stopped, or installs it (shows the docker run line and asks first). Right-click it to update Portainer or change its data folder.',
        'Each machine has a Portainer data folder in the Machines window. Portainer Business asks for its licence key in its own page; the app never stores it.',
        'The Stop group question names the group again.',
        'When the progress window is hidden (or turned off), a box in the corner of the screen says when Docker has finished, and what went wrong if it failed. It can be turned off in Settings.'
    )
    '1.04' = @(
        'Settings: the Show app icons option and the editor path are no longer cut off.',
        'Each machine remembers its own compose file, so picking a machine also picks the file you use with it.',
        'With another machine picked, the compose file box reads "Send from:", because that machine runs its own copy of the file.',
        'Captions above the machine and compose file lists say what each one is for.',
        'The selected container''s row is highlighted more strongly, as well as the line at its start.',
        'The project name and service count have their own line under the compose file path, so they are no longer cut off.',
        'Row highlights now show in every list (they were hidden by a list setting).',
        'The Send button sits right next to the compose file it sends.',
        'The Note column is wider, so notes such as "Changed: recreate to apply" show in full.',
        'The Image column has more room, and hovering over an image shows its full name.'
    )
    '1.03' = @(
        'A progress window shows what Docker is doing while containers start, stop or update (can be turned off in Settings).',
        'Machines: manage Docker on other machines (a Linux laptop, a VM, a Synology NAS) over SSH from the list at the top.',
        'Send to machine: copies the compose file and that machine''s Env_ file (as .env) across, keeping a backup of the old ones there.',
        'Web pages, shells and logs open on the chosen machine; Configure saves to that machine''s Env_ file.'
    )
    '1.02' = @(
        'Dark mode (follows Windows, or pick Light or Dark in Settings).',
        'Card view: switch between the list and cards with the Cards button or Ctrl+T.',
        'App icons for containers, and a colour for each group (home.icon and home.color labels to choose your own).',
        'Check for updates: shows which containers have a newer image, without downloading anything.',
        'Disk usage window with clean-up of old images and the build cache.',
        'Tidy spacing in the Check window: re-indents the compose file, saved only if Docker reads it the same.'
    )
    '1.01' = @(
        'Configure window for each container: change environment variables, API keys and passwords (kept in .env), move values from the compose file to .env, add new variables.',
        'Open a container''s host folders, a shell inside it, its web page and logs from the Configure window.'
    )
    '1.00' = @(
        'Lists every service in your compose file with live status, web page, image and uptime.',
        'Groups from a label in the compose file (home.group), with Start, Stop and Update for a whole group.',
        'Start, stop, restart, update and recreate one container or a selection.',
        'Spots new, removed and changed services whenever the compose file or .env is saved.',
        'Logs window with follow, search, copy and save.',
        'Check compose file: spacing, ${...} variables, port clashes, names and more.',
        'Tray icon with quick start and stop for each group.'
    )
}

$aboutXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="580" SizeToContent="Height" ResizeMode="NoResize" WindowStartupLocation="CenterOwner"
        FontFamily="Segoe UI" FontSize="13" Background="{DynamicResource Page}" Foreground="{DynamicResource Ink}">
    <Window.Resources><!--SHARED-->
        <!-- Fold-away sections, in the same style as the group headers in the main list:
             a chevron, a bold title and a soft count (Tag). -->
        <Style x:Key="AboutSection" TargetType="Expander">
            <Setter Property="Foreground" Value="{StaticResource Ink}"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="Margin" Value="0,2,0,2"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Expander">
                        <StackPanel>
                            <ToggleButton IsChecked="{Binding IsExpanded, RelativeSource={RelativeSource TemplatedParent}, Mode=TwoWay}"
                                          Cursor="Hand" FocusVisualStyle="{x:Null}">
                                <ToggleButton.Template>
                                    <ControlTemplate TargetType="ToggleButton">
                                        <Border x:Name="Bd" Background="Transparent" Padding="4,5,4,5" CornerRadius="4">
                                            <StackPanel Orientation="Horizontal">
                                                <TextBlock x:Name="Chevron" Text="&#xE70D;" FontFamily="Segoe MDL2 Assets" FontSize="10"
                                                           VerticalAlignment="Center" Margin="2,0,8,0" Foreground="{StaticResource SoftInk}"/>
                                                <TextBlock Text="{Binding Header, RelativeSource={RelativeSource AncestorType=Expander}}" FontWeight="SemiBold"
                                                           Foreground="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Expander}}"/>
                                                <TextBlock Text="{Binding Tag, RelativeSource={RelativeSource AncestorType=Expander}}" Foreground="{StaticResource SoftInk}" Margin="6,0,0,0"/>
                                            </StackPanel>
                                        </Border>
                                        <ControlTemplate.Triggers>
                                            <Trigger Property="IsChecked" Value="False">
                                                <Setter TargetName="Chevron" Property="Text" Value="&#xE76C;"/>
                                            </Trigger>
                                            <Trigger Property="IsMouseOver" Value="True">
                                                <Setter TargetName="Bd" Property="Background" Value="{StaticResource Hover}"/>
                                            </Trigger>
                                            <Trigger Property="IsKeyboardFocused" Value="True">
                                                <Setter TargetName="Bd" Property="Background" Value="{StaticResource Hover}"/>
                                            </Trigger>
                                        </ControlTemplate.Triggers>
                                    </ControlTemplate>
                                </ToggleButton.Template>
                            </ToggleButton>
                            <ContentPresenter x:Name="Body" Margin="24,2,4,6" Visibility="Collapsed"/>
                        </StackPanel>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsExpanded" Value="True">
                                <Setter TargetName="Body" Property="Visibility" Value="Visible"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <!-- A version inside What's new: the same, a little smaller, the title in the accent colour. -->
        <Style x:Key="AboutVersionSection" TargetType="Expander" BasedOn="{StaticResource AboutSection}">
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Margin" Value="0,0,0,0"/>
            <Setter Property="Foreground" Value="{StaticResource Accent}"/>
        </Style>
    </Window.Resources>
    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <Border Padding="20,16">
            <Border.Background>
                <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                    <GradientStop Color="%%HeadA%%" Offset="0"/>
                    <GradientStop Color="%%HeadB%%" Offset="1"/>
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
        <ScrollViewer x:Name="AboutScroll" Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Focusable="False">
        <StackPanel Margin="16,12,20,0">
            <Expander x:Name="SecAbout" Header="About" IsExpanded="True" Style="{StaticResource AboutSection}">
                <TextBlock Text="Run and organise the containers in a Docker Compose file." TextWrapping="Wrap" FontSize="13"/>
            </Expander>
            <Expander x:Name="SecNew" Header="What's new" IsExpanded="True" Style="{StaticResource AboutSection}">
                <StackPanel x:Name="AboutNew" Margin="-6,0,0,0"/>
            </Expander>
            <Expander x:Name="SecPc" Header="This PC" Style="{StaticResource AboutSection}">
                <StackPanel>
                    <TextBlock x:Name="AboutDocker" Foreground="{StaticResource SoftInk}" TextWrapping="Wrap" FontSize="13"/>
                    <TextBlock x:Name="AboutPaths" Foreground="{StaticResource SoftInk}" TextWrapping="Wrap" FontSize="13" Margin="0,2,0,0"/>
                </StackPanel>
            </Expander>
            <Expander x:Name="SecKeys" Header="Keyboard shortcuts" Style="{StaticResource AboutSection}">
                <TextBlock x:Name="AboutKeys" Foreground="{StaticResource SoftInk}" TextWrapping="Wrap" FontSize="13" LineHeight="20"/>
            </Expander>
        </StackPanel>
        </ScrollViewer>
        <Grid Grid.Row="2" Margin="20,16,20,18">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <StackPanel VerticalAlignment="Center">
                <Button x:Name="AboutRepo" Style="{StaticResource LinkBtn}" HorizontalAlignment="Left"/>
                <TextBlock x:Name="AboutCopyright" Foreground="{StaticResource SoftInk}" FontSize="12" Margin="0,3,0,0"/>
            </StackPanel>
            <Button x:Name="AboutClose" Grid.Column="1" Content="Close" Style="{StaticResource PrimaryBtn}" IsCancel="True" IsDefault="True" Margin="0"/>
        </Grid>
    </Grid>
</Window>
'@

function Show-About {
    $w = New-XamlObject $aboutXaml
    $w.Owner = $window
    if ($window.Icon) { $w.Icon = $window.Icon }
    $w.Title = "About $script:AppName"
    # No taller than 85% of the screen's work area; the middle part scrolls.
    $w.MaxHeight = [Math]::Floor([Windows.SystemParameters]::WorkArea.Height * 0.85)
    $w.FindName('AboutLogo').Source = $ui.ImgLogo.Source
    $w.FindName('AboutName').Text = $script:AppName
    $w.FindName('AboutVersion').Text = "Version $script:AppVersion"
    $w.FindName('AboutCopyright').Text = 'Copyright (c) 2026 Jason Rhodes  ·  MIT licence'
    $repo = $w.FindName('AboutRepo')
    $repo.Content = $script:RepoUrl
    $repo.Add_Click({ Open-Url $script:RepoUrl })
    $w.FindName('AboutClose').Add_Click({ [Windows.Window]::GetWindow($this).Close() })
    # What's new: a fold-away section for each version, newest first and the only one open.
    $panel = $w.FindName('AboutNew')
    $versionStyle = $w.FindResource('AboutVersionSection')
    $ink = $w.FindResource('Ink')
    $first = $true
    foreach ($v in $script:WhatsNew.Keys) {
        $items = @($script:WhatsNew[$v])
        $sec = New-Object Windows.Controls.Expander
        $sec.Style = $versionStyle
        $sec.Header = "v$v"
        $sec.Tag = [string][char]0x00B7 + ' ' + $(if ($items.Count -eq 1) { '1 change' } else { "$($items.Count) changes" })
        $sec.IsExpanded = $first
        $first = $false
        $list = New-Object Windows.Controls.StackPanel
        foreach ($item in $items) {
            $t = New-Object Windows.Controls.TextBlock
            $t.Text = [string][char]0x2022 + '  ' + $item
            $t.TextWrapping = 'Wrap'
            $t.Foreground = $ink
            $t.Margin = '0,1,0,1'
            [void]$list.Children.Add($t)
        }
        $sec.Content = $list
        [void]$panel.Children.Add($sec)
    }
    # Keyboard shortcuts: one per line, the key in the normal ink and what it does in the soft ink.
    $keys = $w.FindName('AboutKeys')
    $shortcuts = [ordered]@{
        'F5'                       = 'refresh'
        'Ctrl+F'                   = 'search'
        'Ctrl+T'                   = 'list or cards'
        'Ctrl+E'                   = 'configure'
        'Ctrl+L'                   = 'logs'
        'Ctrl+A'                   = 'select all'
        'F1'                       = 'help'
        'Enter'                    = 'open the web page'
        'Double-click a container' = 'open its web page (or its logs if it has none)'
    }
    $firstKey = $true
    foreach ($k in $shortcuts.Keys) {
        if (-not $firstKey) { $keys.Inlines.Add((New-Object Windows.Documents.LineBreak)) }
        $firstKey = $false
        $run = New-Object Windows.Documents.Run $k
        $run.Foreground = $ink
        $keys.Inlines.Add($run)
        $keys.Inlines.Add((New-Object Windows.Documents.Run ('  ' + [string][char]0x00B7 + '  ' + $shortcuts[$k])))
    }
    # Opening a section makes the window taller: keep its bottom on the screen.
    $w.Add_SizeChanged({
            param($s)
            $wa = [Windows.SystemParameters]::WorkArea
            if ($s.Top + $s.ActualHeight -gt $wa.Bottom) { $s.Top = [Math]::Max($wa.Top, $wa.Bottom - $s.ActualHeight) }
        })
    $script:AboutDockerText = $w.FindName('AboutDocker')
    $script:AboutDockerText.Text = if (Test-DockerReady) { 'Docker: checking...' } else { "Docker: docker.exe wasn't found." }
    $composeText = if ($script:ComposePath) { $script:ComposePath } else { 'none chosen' }
    $w.FindName('AboutPaths').Text = "Machine: $(Get-MachineName)`nCompose file: $composeText`nSettings: $script:SettingsPath"
    if (Test-DockerReady) {
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
# A one-line question: returns what was typed, or $null for Cancel.
# ---------------------------------------------------------------------------
$askXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="620" SizeToContent="Height" ResizeMode="NoResize" WindowStartupLocation="CenterOwner"
        FontFamily="Segoe UI" FontSize="13" Background="{DynamicResource Page}" Foreground="{DynamicResource Ink}">
    <Window.Resources><!--SHARED--></Window.Resources>
    <StackPanel Margin="18">
        <TextBlock x:Name="TxtAskTitle" FontSize="16" FontWeight="SemiBold" Margin="0,0,0,6"/>
        <TextBlock x:Name="TxtAskText" TextWrapping="Wrap" Foreground="{StaticResource SoftInk}" Margin="0,0,0,10"/>
        <TextBox x:Name="TxtAskValue" Style="{StaticResource Field}"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
            <Button x:Name="BtnAskOk" Content="OK" Style="{StaticResource PrimaryBtn}" IsDefault="True"/>
            <Button Content="Cancel" Style="{StaticResource Btn}" IsCancel="True" Margin="0"/>
        </StackPanel>
    </StackPanel>
</Window>
'@

function Read-TextValue($Owner, [string]$Title, [string]$Text, [string]$Value) {
    $w = New-XamlObject $askXaml
    $w.Owner = $Owner
    $w.Title = $Title
    if ($window.Icon) { $w.Icon = $window.Icon }
    $w.FindName('TxtAskTitle').Text = $Title
    $w.FindName('TxtAskText').Text = $Text
    $box = $w.FindName('TxtAskValue')
    $box.Text = $Value
    $w.FindName('BtnAskOk').Add_Click({ param($s) [Windows.Window]::GetWindow($s).DialogResult = $true })
    $w.Add_ContentRendered({ param($s) $b = $s.FindName('TxtAskValue'); [void]$b.Focus(); $b.SelectAll() })
    if ($w.ShowDialog()) { return $box.Text.Trim() }
    return $null
}

# ---------------------------------------------------------------------------
# Portainer: one button opens Portainer on the chosen machine, starts it when
# it's stopped, or installs it (after showing the docker run line). Portainer
# Business asks for its licence key in its own web page and keeps it in its
# data folder, so the app never sees or stores it. The data folder is kept for
# each machine in the settings (Machines window; This PC in PortainerFolder).
# ---------------------------------------------------------------------------
$script:PortainerImage = 'portainer/portainer-ee'
$script:PortainerWhat = ''

function Get-PortainerFolder {
    $m = Get-Machine
    if ($m) { return [string]$m.Portainer }
    return [string]$script:Settings.PortainerFolder
}

function Set-PortainerFolder([string]$Folder) {
    $m = Get-Machine
    if ($m) { $m.Portainer = $Folder } else { $script:Settings.PortainerFolder = $Folder }
    Save-Settings
    Write-Activity "Portainer data folder on $(Get-MachineName): $Folder"
}

# A first guess: docker_configs\portainer next to the compose file on this PC,
# the docker shared folder on a Synology, the user's home folder elsewhere.
function Get-PortainerSuggestion {
    $m = Get-Machine
    if (-not $m) {
        $base = if ($script:ComposeDir) { $script:ComposeDir } else { [Environment]::GetFolderPath('MyDocuments') }
        return ((Join-Path $base 'docker_configs\portainer') -replace '\\', '/')
    }
    if ($m.Folder -match '^/(volume\d+)(/|$)') { return "/$($Matches[1])/docker/portainer" }
    $user = ([string]$m.Login -split '@')[0]
    if ($user -eq 'root') { return '/root/docker_configs/portainer' }
    return "/home/$user/docker_configs/portainer"
}

function Read-PortainerFolder {
    $where = Get-MachineName
    $value = Get-PortainerFolder
    if (-not $value) { $value = Get-PortainerSuggestion }
    $hint = if (Get-Machine) { "It's the full path on $where, starting with /." } else { 'For example E:/Docker/portainer.' }
    while ($true) {
        $v = Read-TextValue $window 'Portainer data folder' ("The folder on $where where Portainer keeps its data (mounted as /data). Its settings, users and licence stay there when Portainer is updated. $hint") $value
        if ($null -eq $v) { return $null }
        $v = $v.Trim()
        if (Get-Machine) { $v = $v.TrimEnd('/') } else { $v = ($v -replace '\\', '/'); if ($v -notmatch '^[A-Za-z]:/$') { $v = $v.TrimEnd('/') } }
        $bad = ''
        if (-not $v) { $bad = 'Type a folder.' }
        elseif ($v -match '[;&|`$<>"'']') { $bad = 'The folder name has a character Docker can''t use here.' }
        elseif ((Get-Machine) -and $v -notmatch '^/') { $bad = "Use the full path on $where, starting with /." }
        elseif (-not (Get-Machine) -and $v -notmatch '^[A-Za-z]:/') { $bad = 'Use a full path on this PC, starting with a drive letter, for example E:/Docker/portainer.' }
        if (-not $bad) { return $v }
        [void][Windows.MessageBox]::Show($window, $bad, 'Portainer data folder', 'OK', 'Warning')
        $value = $v
    }
}

function Get-PortainerRunArguments([string]$Folder) {
    return @('run', '-d', '-p', '8000:8000', '-p', '9000:9000', '--name', 'portainer', '--restart=unless-stopped',
        '-v', '/var/run/docker.sock:/var/run/docker.sock', '-v', ($Folder + ':/data'), $script:PortainerImage)
}

# localhost becomes the machine's address in Open-Url when another machine is chosen.
function Open-Portainer { Open-Url 'http://localhost:9000' }

function Invoke-Portainer([string]$What) {
    if ($What -eq 'open') { Open-Portainer; return }
    if ($What -eq 'folder') { $f = Read-PortainerFolder; if ($f) { Set-PortainerFolder $f }; return }
    if (-not (Test-DockerReady)) {
        [void][Windows.MessageBox]::Show($window, "Docker can't be reached on $(Get-MachineName), so Portainer can't be checked.", $script:AppName, 'OK', 'Warning')
        return
    }
    $script:PortainerWhat = $What
    Set-Status "Looking for Portainer on $(Get-MachineName)..."
    Start-DockerCall -Arguments @('ps', '-a', '--filter', 'name=^portainer$', '--format', '{{.State}}') -OnDone { param($res) Complete-PortainerCheck $res }
}

function Complete-PortainerCheck($Res) {
    Set-Status ''
    $where = Get-MachineName
    if ($Res.ExitCode -ne 0) {
        [void][Windows.MessageBox]::Show($window, "Docker on $where didn't answer: $(Get-FirstLines $Res.Error 2)", $script:AppName, 'OK', 'Warning')
        return
    }
    $state = @(@(($Res.Output -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ }) + @(''))[0]
    if ($script:PortainerWhat -eq 'update') {
        if (-not $state) { [void][Windows.MessageBox]::Show($window, "Portainer isn't installed on $where. Press Portainer to install it.", $script:AppName, 'OK', 'Information'); return }
        # Use the folder the container has now, so an update never starts Portainer with empty data.
        Start-DockerCall -Arguments @('inspect', 'portainer', '--format', '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Type}}|{{.Name}}|{{.Source}}{{end}}{{end}}') -OnDone { param($res) Complete-PortainerUpdate $res }
        return
    }
    if ($state -eq 'running') { Open-Portainer; return }
    if ($state) {
        Add-Job "Start Portainer on $where" @(New-DockerStep @('start', 'portainer')) -OnSuccess { Open-Portainer }
        return
    }
    Install-Portainer
}

function Install-Portainer {
    $where = Get-MachineName
    $folder = Get-PortainerFolder
    if (-not $folder) {
        $folder = Read-PortainerFolder
        if (-not $folder) { return }
        Set-PortainerFolder $folder
    }
    $cmd = 'docker ' + [Dcm.Runner]::Join([string[]](Get-PortainerRunArguments $folder))
    $q = "Portainer isn't installed on $where. Install it now?`n`nThe app runs:`n$cmd`n`n" +
    "Portainer keeps its data in $folder (right-click the Portainer button to change it first). It then opens on port 9000, where Portainer Business asks for your licence key the first time. The app doesn't see or keep the key.`n`n" +
    "Portainer can control Docker on $where (it uses the Docker socket)."
    if (-not (Confirm-Action $q)) { return }
    Add-Job "Install Portainer on $where" @(New-DockerStep (Get-PortainerRunArguments $folder)) -OnSuccess { Open-Portainer }
}

function Complete-PortainerUpdate($Res) {
    $where = Get-MachineName
    $mount = ''
    if ($Res.ExitCode -eq 0) {
        $parts = ([string]$Res.Output).Trim() -split '\|', 3
        if ($parts.Count -eq 3) {
            if ($parts[0] -eq 'volume' -and $parts[1]) { $mount = $parts[1] }
            elseif ($parts[0] -eq 'bind' -and $parts[2]) {
                $mount = $parts[2]
                # Docker Desktop shows a folder on this PC as /run/desktop/mnt/host/e/...
                if ($mount -match '^/run/desktop/mnt/host/([a-zA-Z])(/.*)?$') { $mount = $Matches[1].ToUpperInvariant() + ':' + $(if ($Matches[2]) { $Matches[2] } else { '/' }) }
            }
        }
    }
    $folder = if ($mount) { $mount } else { Get-PortainerFolder }
    if (-not $folder) {
        $folder = Read-PortainerFolder
        if (-not $folder) { return }
    }
    $from = if ($mount) { 'the same data it uses now' } else { 'this data folder' }
    $q = "Update Portainer on $($where)?`n`nThe newest $script:PortainerImage image is downloaded, then the portainer container is removed and made again with $from ($folder), so its settings, users and licence are kept.`n`nThe app runs:`n" +
    "docker pull $script:PortainerImage`ndocker rm -f portainer`ndocker " + [Dcm.Runner]::Join([string[]](Get-PortainerRunArguments $folder))
    if (-not (Confirm-Action $q)) { return }
    # Remember a folder (not a named Docker volume) for next time.
    if ($folder -match '[:/]' -and (Get-PortainerFolder) -ne $folder) { Set-PortainerFolder $folder }
    $steps = @(
        New-DockerStep @('pull', $script:PortainerImage)
        New-DockerStep @('rm', '-f', 'portainer')
        New-DockerStep (Get-PortainerRunArguments $folder)
    )
    Add-Job "Update Portainer on $where" $steps -OnSuccess { Open-Portainer }
}

# ---------------------------------------------------------------------------
# Group automatically: suggests a group for each service without a group label,
# from its image and service name. The list is shown first and can be changed;
# Save adds one label line to each of those services and changes nothing else,
# after a backup. Groups already in the file are reused where they fit.
# ---------------------------------------------------------------------------
$script:GroupHints = [ordered]@{
    'Media'      = @('plex', 'jellyfin', 'emby', 'tautulli', 'overseerr', 'jellyseerr', 'ombi', 'petio', 'wizarr', 'kavita', 'komga', 'audiobookshelf', 'navidrome', 'airsonic', 'immich', 'photoprism', 'tdarr', 'handbrake', 'makemkv', 'jellystat', 'streamystats', 'kometa', 'plex-meta-manager', 'tinymediamanager', 'calibre', 'calibre-web', 'jellyplex', 'koel', 'mstream', 'plexautolanguages')
    'Downloads'  = @('sonarr', 'radarr', 'lidarr', 'readarr', 'prowlarr', 'bazarr', 'mylar3', 'mylar', 'lazylibrarian', 'sabnzbd', 'nzbget', 'qbittorrent', 'transmission', 'deluge', 'rtorrent', 'rutorrent', 'jackett', 'flaresolverr', 'byparr', 'nzbhydra2', 'nzbhydra', 'autobrr', 'unpackerr', 'recyclarr', 'notifiarr', 'cross-seed', 'medusa', 'sickchill', 'sickgear', 'headphones', 'pyload', 'pyload-ng', 'jdownloader', 'jdownloader-2', 'metube', 'yt-dlp', 'youtube-dl', 'tubearchivist', 'pinchflat', 'cleanuparr', 'decluttarr', 'huntarr', 'maintainerr', 'gluetun', 'qbit_manage')
    'Databases'  = @('postgres', 'postgresql', 'mariadb', 'mysql', 'mongo', 'mongodb', 'redis', 'valkey', 'keydb', 'influxdb', 'couchdb', 'elasticsearch', 'opensearch', 'meilisearch', 'typesense', 'clickhouse', 'timescaledb', 'memcached', 'adminer', 'phpmyadmin', 'pgadmin', 'pgadmin4', 'mongo-express', 'redis-commander', 'redisinsight', 'pgvecto-rs')
    'Monitoring' = @('uptime-kuma', 'grafana', 'prometheus', 'node-exporter', 'cadvisor', 'netdata', 'glances', 'loki', 'promtail', 'alloy', 'scrutiny', 'dozzle', 'beszel', 'beszel-agent', 'speedtest-tracker', 'healthchecks', 'gotify', 'ntfy', 'apprise', 'diun', 'watchtower', 'changedetection.io', 'changedetection', 'gatus', 'statping', 'smokeping', 'librespeed', 'whatsupdocker', 'wud')
    'Network'    = @('nginx-proxy-manager', 'traefik', 'caddy', 'swag', 'pihole', 'adguardhome', 'unbound', 'wireguard', 'wg-easy', 'tailscale', 'cloudflared', 'ddclient', 'duckdns', 'authelia', 'authentik', 'crowdsec', 'headscale', 'netbird', 'openvpn', 'zerotier', 'technitium')
    'Home'       = @('home-assistant', 'homeassistant', 'mosquitto', 'eclipse-mosquitto', 'zigbee2mqtt', 'node-red', 'esphome', 'frigate', 'scrypted', 'homebridge', 'zwave-js-ui', 'go2rtc', 'music-assistant-server')
    'Dashboards' = @('homepage', 'homarr', 'heimdall', 'organizr', 'dashy', 'flame', 'homer', 'glance', 'dashdot')
    'Files'      = @('nextcloud', 'syncthing', 'filebrowser', 'seafile', 'owncloud', 'paperless-ngx', 'paperless', 'duplicati', 'kopia', 'restic', 'borgmatic', 'resilio-sync', 'samba', 'sftpgo', 'filestash', 'cloudreve', 'duplicacy')
    'Tools'      = @('portainer', 'portainer-ce', 'portainer-ee', 'vaultwarden', 'bitwarden', 'it-tools', 'stirling-pdf', 'code-server', 'openspeedtest', 'cyberchef', 'excalidraw', 'drawio', 'freshrss', 'miniflux', 'linkding', 'wallabag', 'mealie', 'tandoor', 'actual-server', 'firefly-iii', 'n8n', 'gitea', 'forgejo', 'jenkins', 'searxng', 'open-webui', 'ollama')
    'Websites'   = @('nginx', 'httpd', 'apache', 'wordpress', 'ghost', 'php', 'lighttpd')
}

# ghcr.io/hotio/radarr:release -> radarr
function Get-ImageShortName([string]$Image) {
    $ref = ($Image -split '@')[0]
    $last = ($ref -split '/')[-1]
    return (($last -split ':')[0]).ToLowerInvariant()
}

function Get-GroupHint([string]$Image, [string]$Service) {
    foreach ($word in @((Get-ImageShortName $Image), ([string]$Service).ToLowerInvariant())) {
        if (-not $word) { continue }
        foreach ($g in $script:GroupHints.Keys) {
            foreach ($k in $script:GroupHints[$g]) {
                if ($word -eq $k -or $word.StartsWith($k + '-') -or $word.StartsWith($k + '_') -or ($k.Length -ge 5 -and $word.StartsWith($k))) { return $g }
            }
        }
    }
    return ''
}

# The groups already used, and which of them holds each kind of image (so sonarr
# goes to "Arr" when radarr is already there, rather than to a new "Downloads").
function Get-KnownGroups {
    $grouped = @($script:Rows | Where-Object { $_.InCompose -and $_.Group -ne $script:UngroupedName })
    $used = @($grouped | ForEach-Object Group | Sort-Object -Unique)
    $counts = @{}
    foreach ($r in $grouped) {
        $h = Get-GroupHint $r.Image $r.Service
        if ($h) { $k = "$h|$($r.Group)"; $counts[$k] = 1 + [int]$counts[$k] }
    }
    $map = @{}
    foreach ($k in $counts.Keys) {
        $hint, $group = $k -split '\|', 2
        if (-not $map.ContainsKey($hint) -or $counts[$k] -gt $counts["$hint|$($map[$hint])"]) { $map[$hint] = $group }
    }
    return @{ Used = $used; Map = $map }
}

# Where a service's labels: are in the compose text, and which names they set.
function Find-ServiceLabels($Lines, [string]$Service) {
    $res = @{ Found = $false; Start = -1; End = -1; KeyIndent = -1; LabelsLine = -1; Inline = $false; Form = ''; ItemIndent = -1; Names = @(); Last = -1 }
    $b = Find-ServiceEnv $Lines $Service
    if (-not $b.Found -or $b.KeyIndent -lt 0) { return $res }
    $res.Found = $true; $res.Start = $b.Start; $res.End = $b.End; $res.KeyIndent = $b.KeyIndent
    $names = New-Object System.Collections.ArrayList
    $in = $false
    for ($i = $b.Start + 1; $i -le $b.End; $i++) {
        $l = $Lines[$i]
        if (-not (Test-ContentLine $l)) { continue }
        $ind = Get-LineIndent $l
        $t = (Remove-YamlComment $l.Trim()).Trim()
        $item = ($in -and $ind -eq $b.KeyIndent -and $t.StartsWith('-'))
        if ($ind -le $b.KeyIndent -and -not $item) {
            $in = $false
            if ($ind -eq $b.KeyIndent -and $t -match '^labels\s*:\s*(.*)$') {
                $res.LabelsLine = $i; $res.Last = $i
                if ($Matches[1].Trim()) { $res.Inline = $true } else { $in = $true }
            }
            continue
        }
        if (-not $in) { continue }
        $res.Last = $i
        if ($res.ItemIndent -lt 0) { $res.ItemIndent = $ind }
        if ($ind -ne $res.ItemIndent) { continue }
        if ($t -match '^-\s*(.*)$') {
            if (-not $res.Form) { $res.Form = 'list' }
            [void]$names.Add(((Get-Unquoted $Matches[1]) -split '=', 2)[0].Trim())
        } elseif ($t -match '^("([^"]+)"|''([^'']+)''|([^\s:#]+))\s*:') {
            if (-not $res.Form) { $res.Form = 'map' }
            [void]$names.Add((@($Matches[2], $Matches[3], $Matches[4]) | Where-Object { $_ } | Select-Object -First 1))
        }
    }
    $res.Names = @($names)
    return $res
}

# Whether the file writes its labels as a list (- home.group=X) or a map (home.group: X).
function Get-LabelForm($Lines, [string]$Prefix) {
    $p = [regex]::Escape($Prefix)
    $list = @($Lines | Where-Object { $_ -match ('^\s*-\s*["'']?' + $p + '\.') }).Count
    $map = @($Lines | Where-Object { $_ -match ('^\s*["'']?' + $p + '\.[\w.-]+["'']?\s*:') }).Count
    if ($map -gt $list) { return 'map' }
    return 'list'
}

function Format-LabelLine([int]$Indent, [string]$Form, [string]$Name, [string]$Value) {
    $v = $Value.Replace('$', '$$')
    # In a map, words such as yes or 2024 would not be read as text.
    if ($Form -eq 'map' -and $v -match '^(?i)(true|false|yes|no|on|off|null|~|[-+]?[0-9][0-9._]*([eE][-+]?[0-9]+)?)$') { return "{0}{1}: '{2}'" -f (' ' * $Indent), $Name, $v }
    return Format-ComposeEnvLine $Indent $Form $Name $v
}

# Adds one label to a service. Returns '' when done, otherwise why it was skipped.
function Add-ServiceLabel($Lines, [string]$Service, [string]$Label, [string]$Value, [string]$FileForm) {
    $info = Find-ServiceLabels $Lines $Service
    if (-not $info.Found) { return "it wasn't found in the file" }
    if ($info.Inline) { return 'its labels are written on one line' }
    if ($info.Names -contains $Label) { return "it already has $Label" }
    $step = $info.KeyIndent - (Get-LineIndent $Lines[$info.Start])
    if ($step -lt 1) { $step = 2 }
    $form = if ($info.Form) { $info.Form } elseif ($FileForm) { $FileForm } else { 'list' }
    if ($info.LabelsLine -ge 0) {
        $indent = if ($info.ItemIndent -ge 0) { $info.ItemIndent } else { $info.KeyIndent + $step }
        $Lines.Insert($info.Last + 1, (Format-LabelLine $indent $form $Label $Value))
    } else {
        $Lines.Insert($info.End + 1, ((' ' * $info.KeyIndent) + 'labels:'))
        $Lines.Insert($info.End + 2, (Format-LabelLine ($info.KeyIndent + $step) $form $Label $Value))
    }
    return ''
}

$autoGroupXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Group automatically" Width="860" Height="640" MinWidth="620" MinHeight="380" WindowStartupLocation="CenterOwner"
        FontFamily="Segoe UI" FontSize="13" Background="{DynamicResource Page}" Foreground="{DynamicResource Ink}">
    <Window.Resources><!--SHARED--></Window.Resources>
    <DockPanel Margin="14">
        <StackPanel DockPanel.Dock="Top" Margin="0,0,0,10">
            <TextBlock Text="Group automatically" FontSize="18" FontWeight="SemiBold"/>
            <TextBlock x:Name="TxtAgInfo" Foreground="{StaticResource SoftInk}" TextWrapping="Wrap" Margin="0,2,0,0"/>
            <TextBlock x:Name="TxtAgUsed" Foreground="{StaticResource SoftInk}" TextWrapping="Wrap" Margin="0,4,0,0"/>
        </StackPanel>
        <Grid DockPanel.Dock="Bottom" Margin="0,10,0,0">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <StackPanel VerticalAlignment="Center" Margin="0,0,12,0">
                <TextBlock x:Name="TxtAgNote" Foreground="{StaticResource SoftInk}" TextWrapping="Wrap"/>
                <CheckBox x:Name="ChkAgMine" Margin="0,6,0,0" IsChecked="True"
                          Content="Also add the new groups to My groups"
                          ToolTip="After Save groups, adds each saved container that isn't in My groups yet (my-groups.txt on this PC). Groups already in My groups aren't changed."/>
            </StackPanel>
            <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Bottom">
                <Button x:Name="BtnAgMine" Content="My groups..." Tag="&#xE8FD;" Style="{StaticResource Btn}"
                        ToolTip="See and change your own list of groups (my-groups.txt on this PC)"/>
                <Button x:Name="BtnAgSave" Content="Save groups" Tag="&#xE74E;" Style="{StaticResource PrimaryBtn}"/>
                <Button Content="Cancel" Style="{StaticResource Btn}" IsCancel="True" Margin="0"/>
            </StackPanel>
        </Grid>
        <Border Background="{StaticResource Card}" BorderBrush="{StaticResource Edge}" BorderThickness="1" CornerRadius="8" Padding="12,8">
            <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                <Grid x:Name="GridAg">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="190"/><ColumnDefinition Width="*"/><ColumnDefinition Width="210"/><ColumnDefinition Width="96"/></Grid.ColumnDefinitions>
                </Grid>
            </ScrollViewer>
        </Border>
    </DockPanel>
</Window>
'@

function Add-AutoGroupCell($Grid, $Element, [int]$Row, [int]$Column) {
    [Windows.Controls.Grid]::SetRow($Element, $Row)
    [Windows.Controls.Grid]::SetColumn($Element, $Column)
    [void]$Grid.Children.Add($Element)
}

function Show-AutoGroup {
    if (-not $script:ComposePath -or -not (Test-Path -LiteralPath $script:ComposePath)) { return }
    $rows = @($script:Rows | Where-Object { $_.InCompose -and $_.Group -eq $script:UngroupedName } | Sort-Object Service)
    if (-not $rows.Count) { Set-Status 'Every container already has a group.'; return }
    $prefix = [string]$script:Settings.LabelPrefix
    $known = Get-KnownGroups
    [void](Initialize-MyGroupsFile)
    $mine = Get-MyGroupsMap
    $w = New-XamlObject $autoGroupXaml
    $w.Owner = $window
    if ($window.Icon) { $w.Icon = $window.Icon }
    $f = @{ Window = $w; Items = (New-Object System.Collections.ArrayList); Stamp = (Get-FileStamp); Note = $w.FindName('TxtAgNote'); Save = $w.FindName('BtnAgSave') }
    $grid = $w.FindName('GridAg')
    $soft = $w.FindResource('SoftInk')
    $i = 0
    foreach ($h in 'Container', 'Image', 'Group', 'From') {
        $tb = New-Object Windows.Controls.TextBlock -Property @{ Text = $h; FontWeight = 'SemiBold'; Foreground = $soft; Margin = '0,0,8,6' }
        if ($i -eq 0) { $grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height = [Windows.GridLength]::Auto })) }
        Add-AutoGroupCell $grid $tb 0 $i
        $i++
    }
    $n = 1; $suggested = 0; $fromMine = 0
    $accent = $w.FindResource('Accent')
    foreach ($r in $rows) {
        $hint = Get-GroupHint $r.Image $r.Service
        $group = ''
        $from = ''
        if ($mine -and $mine.ContainsKey($r.Service.ToLowerInvariant())) {
            $group = $mine[$r.Service.ToLowerInvariant()]
            $from = 'My groups'
            $fromMine++
        }
        elseif ($hint) {
            $from = 'Guessed'
            $suggested++
            if ($known.Map.ContainsKey($hint)) { $group = $known.Map[$hint] }
            else { $same = @($known.Used | Where-Object { $_ -eq $hint }); $group = if ($same.Count) { $same[0] } else { $hint } }
        }
        $grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height = [Windows.GridLength]::Auto }))
        Add-AutoGroupCell $grid (New-Object Windows.Controls.TextBlock -Property @{ Text = $r.Service; VerticalAlignment = 'Center'; TextTrimming = 'CharacterEllipsis'; Margin = '0,0,8,6' }) $n 0
        Add-AutoGroupCell $grid (New-Object Windows.Controls.TextBlock -Property @{ Text = $r.Image; ToolTip = $r.Image; Foreground = $soft; VerticalAlignment = 'Center'; TextTrimming = 'CharacterEllipsis'; Margin = '0,0,8,6' }) $n 1
        $box = New-Object Windows.Controls.TextBox -Property @{ Text = $group; Margin = '0,0,0,6'; ToolTip = 'Type a group, or leave it empty to keep this container ungrouped' }
        $box.Style = $w.FindResource('Field')
        Add-AutoGroupCell $grid $box $n 2
        $src = New-Object Windows.Controls.TextBlock -Property @{ Text = $from; VerticalAlignment = 'Center'; Margin = '10,0,0,6'; FontSize = 12 }
        $src.Foreground = if ($from -eq 'My groups') { $accent } else { $soft }
        $src.ToolTip = switch ($from) { 'My groups' { 'From your My groups list' } 'Guessed' { 'Guessed from the image and service name' } default { 'No suggestion' } }
        Add-AutoGroupCell $grid $src $n 3
        [void]$f.Items.Add(@{ Service = $r.Service; Box = $box; From = $from; Suggested = $group; FromText = $src })
        $n++
    }
    $w.FindName('TxtAgInfo').Text = ("{0} container(s) have no {1}.group label. {2} got their group from My groups and {3} were guessed from the image name; the rest are empty. Change any group, type a new one, or clear it to leave that container ungrouped." -f $rows.Count, $prefix, $fromMine, $suggested)
    $w.FindName('TxtAgUsed').Text = if ($known.Used.Count) { 'Groups already in the file: ' + ($known.Used -join ', ') } else { '' }
    $note = "Save adds a $prefix.group label to each container with a group, after a backup of the compose file. Nothing else in the file changes. Those containers then show Changed until you press Apply changes."
    if (Get-Machine) { $note += " They run on $(Get-MachineName), so press Send before Apply changes." }
    $f.Note.Text = $note
    $f.Save.Add_Click({ Save-AutoGroups })
    $f.Mine = $w.FindName('ChkAgMine')
    $w.FindName('BtnAgMine').Add_Click({
            Show-MyGroups $script:AutoGroupForm.Window
            Update-AutoGroupFromMine
        })
    $script:AutoGroupForm = $f
    [void]$w.ShowDialog()
    $script:AutoGroupForm = $null
    $script:AutoGroupSave = $null
}

# "Saving groups": a small box over the Group automatically window that shows each
# step of the save as it happens. Each step runs on its own turn of the window's
# dispatcher (and the Docker check runs in the background), so the app keeps
# drawing. If a step fails, the box says why and the compose file is left as it was.
$saveGroupsXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Saving groups" Width="460" SizeToContent="Height" ResizeMode="NoResize" WindowStartupLocation="CenterOwner" ShowInTaskbar="False"
        FontFamily="Segoe UI" FontSize="13" Background="{DynamicResource Page}" Foreground="{DynamicResource Ink}">
    <Window.Resources><!--SHARED--></Window.Resources>
    <StackPanel Margin="18,16,18,16">
        <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <TextBlock x:Name="SgGlyph" FontFamily="Segoe MDL2 Assets" FontSize="20" Text="&#xE74E;" Foreground="{StaticResource Accent}"
                       VerticalAlignment="Center" Margin="0,0,10,0"/>
            <StackPanel Grid.Column="1">
                <TextBlock x:Name="SgTitle" Text="Saving groups" FontSize="16" FontWeight="SemiBold"/>
                <TextBlock x:Name="SgStatus" Foreground="{StaticResource SoftInk}" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
            </StackPanel>
        </Grid>
        <ProgressBar x:Name="SgBar" Height="8" Margin="0,12,0,10" Minimum="0" Maximum="1"
                     Foreground="{StaticResource Accent}" Background="{StaticResource AccentSoft}" BorderThickness="0"/>
        <StackPanel x:Name="SgSteps"/>
        <Border x:Name="SgErrorBox" Background="%%ErrorBg%%" BorderBrush="%%ErrorEdge%%" BorderThickness="1" CornerRadius="6"
                Padding="10,8" Margin="0,10,0,0" Visibility="Collapsed">
            <TextBlock x:Name="SgError" TextWrapping="Wrap"/>
        </Border>
        <Button x:Name="SgClose" Content="Close" Style="{StaticResource PrimaryBtn}" HorizontalAlignment="Right" Margin="0,14,0,0"
                IsCancel="True" IsDefault="True" Visibility="Collapsed"/>
    </StackPanel>
</Window>
'@

$script:SaveGroupSteps = [ordered]@{
    Labels = 'Adding the group labels'
    Check  = 'Checking a test copy with Docker'
    Backup = 'Making a backup of the compose file'
    Write  = 'Writing the compose file'
    Verify = 'Checking the saved file'
    Reload = 'Reloading the list'
}

function Show-SaveGroupsBox($Owner) {
    $w = New-XamlObject $saveGroupsXaml
    $w.Owner = $Owner
    if ($window.Icon) { $w.Icon = $window.Icon }
    $b = @{ Window = $w; Busy = $true; Rows = @{} }
    foreach ($n in 'SgGlyph', 'SgTitle', 'SgStatus', 'SgBar', 'SgSteps', 'SgErrorBox', 'SgError', 'SgClose') { $b[$n] = $w.FindName($n) }
    $b.SgBar.Maximum = $script:SaveGroupSteps.Count
    foreach ($k in $script:SaveGroupSteps.Keys) {
        $row = New-Object Windows.Controls.Grid
        $row.Margin = '0,2,0,2'
        [void]$row.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = [Windows.GridLength]::Auto }))
        [void]$row.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition))
        $glyph = New-Object Windows.Controls.TextBlock -Property @{ FontFamily = 'Segoe MDL2 Assets'; FontSize = 12; Width = 22; VerticalAlignment = 'Center'; Text = [string][char]0xEA3A }
        $glyph.Foreground = $w.FindResource('Off')
        $text = New-Object Windows.Controls.TextBlock -Property @{ Text = $script:SaveGroupSteps[$k]; TextWrapping = 'Wrap' }
        $text.Foreground = $w.FindResource('SoftInk')
        [Windows.Controls.Grid]::SetColumn($text, 1)
        [void]$row.Children.Add($glyph)
        [void]$row.Children.Add($text)
        [void]$b.SgSteps.Children.Add($row)
        $b.Rows[$k] = @{ Glyph = $glyph; Text = $text }
    }
    $b.SgClose.Add_Click({ $s = $script:SaveGroupsBox; if ($s) { $s.Window.Close() } })
    # While it's working the box can't be closed; afterwards Close or Esc closes it.
    $w.Add_Closing({ param($src, $e) if ($script:SaveGroupsBox -and $script:SaveGroupsBox.Busy) { $e.Cancel = $true } })
    $w.Add_Closed({
            $script:SaveGroupsBox = $null
            if ($script:AutoGroupForm) { $script:AutoGroupForm.Window.IsEnabled = $true; [void]$script:AutoGroupForm.Window.Activate() }
        })
    $script:SaveGroupsBox = $b
    # Modal for the Group automatically window, without blocking the code that does the work.
    $Owner.IsEnabled = $false
    $w.Show()
    return $b
}

# Marks a step as running, done, skipped or failed, with an optional note after its name.
function Set-SaveGroupsStep([string]$Step, [string]$State, [string]$Note = '') {
    $b = $script:SaveGroupsBox
    if (-not $b) { return }
    $r = $b.Rows[$Step]
    $name = $script:SaveGroupSteps[$Step]
    $r.Text.Text = if ($Note) { "$name  $([char]0x00B7)  $Note" } else { $name }
    switch ($State) {
        'running' { $r.Glyph.Text = [string][char]0xE768; $r.Glyph.Foreground = $b.Window.FindResource('Accent'); $r.Text.Foreground = $b.Window.FindResource('Ink'); $r.Text.FontWeight = 'SemiBold'; $b.SgStatus.Text = if ($Note) { "$name ($Note)..." } else { "$name..." } }
        'done' { $r.Glyph.Text = [string][char]0xE73E; $r.Glyph.Foreground = $b.Window.FindResource('Ok'); $r.Text.Foreground = $b.Window.FindResource('Ink'); $r.Text.FontWeight = 'Normal' }
        'skipped' { $r.Glyph.Text = [string][char]0xE738; $r.Glyph.Foreground = $b.Window.FindResource('Off'); $r.Text.Foreground = $b.Window.FindResource('SoftInk'); $r.Text.FontWeight = 'Normal' }
        'failed' { $r.Glyph.Text = [string][char]0xE711; $r.Glyph.Foreground = $b.Window.FindResource('Bad'); $r.Text.Foreground = $b.Window.FindResource('Bad'); $r.Text.FontWeight = 'SemiBold' }
    }
    $i = [array]::IndexOf(@($script:SaveGroupSteps.Keys), $Step)
    if ($State -eq 'running') { $b.SgBar.Value = $i } elseif ($State -ne 'failed') { $b.SgBar.Value = $i + 1 }
}

# Stops with an error: says what went wrong, and lets the box be closed.
function Stop-SaveGroups([string]$Step, [string]$Message) {
    $s = $script:AutoGroupSave
    $script:AutoGroupSave = $null
    if ($s -and $s.Tmp) { Remove-Item -LiteralPath $s.Tmp -Force -ErrorAction SilentlyContinue }
    if ($script:AutoGroupForm) { $script:AutoGroupForm.Save.IsEnabled = $true; $script:AutoGroupForm.Note.Text = 'Nothing was saved.' }
    $b = $script:SaveGroupsBox
    if (-not $b) { [void][Windows.MessageBox]::Show($window, $Message, $script:AppName, 'OK', 'Warning'); return }
    if ($Step) { Set-SaveGroupsStep $Step 'failed' }
    $b.Busy = $false
    $b.SgTitle.Text = "Groups weren't saved"
    $b.SgGlyph.Text = [string][char]0xEA39
    $b.SgGlyph.Foreground = $b.Window.FindResource('Bad')
    $b.SgStatus.Text = 'The compose file is as it was.'
    $b.SgBar.Foreground = $b.Window.FindResource('Bad')
    $b.SgError.Text = $Message
    $b.SgErrorBox.Visibility = 'Visible'
    $b.SgClose.Visibility = 'Visible'
    [void]$b.SgClose.Focus()
    Write-Activity "Group automatically: nothing was saved. $Message"
}

# Runs the next step once the box has been drawn.
function Invoke-SaveGroupsNext([scriptblock]$Next) {
    $script:SaveGroupsNext = $Next
    [void]$window.Dispatcher.BeginInvoke([Action] {
            $n = $script:SaveGroupsNext; $script:SaveGroupsNext = $null
            if ($n -and $script:AutoGroupSave) { & $n }
        }, [Windows.Threading.DispatcherPriority]::Background)
}

# After My groups was changed: use it for every row whose group you haven't changed by hand.
function Update-AutoGroupFromMine {
    $f = $script:AutoGroupForm
    if (-not $f) { return }
    $mine = Get-MyGroupsMap
    if (-not $mine) { return }
    $n = 0
    foreach ($x in $f.Items) {
        $k = $x.Service.ToLowerInvariant()
        if (-not $mine.ContainsKey($k) -or $x.Box.Text.Trim() -ne $x.Suggested -or $mine[$k] -eq $x.Suggested) { continue }
        $x.Box.Text = $mine[$k]; $x.Suggested = $mine[$k]; $x.From = 'My groups'
        $x.FromText.Text = 'My groups'; $x.FromText.Foreground = $f.Window.FindResource('Accent'); $x.FromText.ToolTip = 'From your My groups list'
        $n++
    }
    if ($n) { $f.Note.Text = "$n group(s) now come from My groups." }
}

function Save-AutoGroups {
    $f = $script:AutoGroupForm
    if (-not $f -or $script:AutoGroupSave) { return }
    $label = "$([string]$script:Settings.LabelPrefix).group"
    $want = [ordered]@{}
    foreach ($x in $f.Items) { $g = $x.Box.Text.Trim(); if ($g) { $want[$x.Service] = $g } }
    if (-not $want.Count) { [void][Windows.MessageBox]::Show($f.Window, 'Every group is empty, so there is nothing to save.', $script:AppName, 'OK', 'Information'); return }
    if ((Get-FileStamp) -ne $f.Stamp) {
        [void][Windows.MessageBox]::Show($f.Window, 'The compose file was changed somewhere else since this window opened, so nothing was saved. Close this window and press Group automatically again.', $script:AppName, 'OK', 'Warning')
        return
    }
    try { $file = Read-TextFile $script:ComposePath }
    catch { [void][Windows.MessageBox]::Show($f.Window, "Couldn't read the compose file: $($_.Exception.Message)", $script:AppName, 'OK', 'Error'); return }
    $f.Save.IsEnabled = $false
    $script:AutoGroupSave = @{
        File = $file; Want = $want; Services = @($want.Keys); Index = 0; Form = (Get-LabelForm $file.Lines ([string]$script:Settings.LabelPrefix))
        Done = (New-Object System.Collections.ArrayList); Skipped = (New-Object System.Collections.ArrayList); Label = $label; Tmp = ''; Bak = ''
    }
    [void](Show-SaveGroupsBox $f.Window)
    Set-SaveGroupsStep 'Labels' 'running' "0 of $($want.Count)"
    Invoke-SaveGroupsNext { Add-SaveGroupsLabel }
}

# Step 1: one label per turn, so the count moves (n of N).
function Add-SaveGroupsLabel {
    $s = $script:AutoGroupSave
    $svc = $s.Services[$s.Index]
    $why = Add-ServiceLabel $s.File.Lines $svc $s.Label $s.Want[$svc] $s.Form
    if ($why) { [void]$s.Skipped.Add("$svc ($why)") } else { [void]$s.Done.Add($svc) }
    $s.Index++
    Set-SaveGroupsStep 'Labels' 'running' "$($s.Index) of $($s.Services.Count)"
    if ($s.Index -lt $s.Services.Count) { Invoke-SaveGroupsNext { Add-SaveGroupsLabel }; return }
    if (-not $s.Done.Count) { Stop-SaveGroups 'Labels' ("Nothing could be added:`n" + ($s.Skipped -join "`n")); return }
    $note = "$($s.Done.Count) of $($s.Services.Count)"
    if ($s.Skipped.Count) { $note += ", $($s.Skipped.Count) left as they were" }
    Set-SaveGroupsStep 'Labels' 'done' $note
    Set-SaveGroupsStep 'Check' 'running'
    Invoke-SaveGroupsNext { Test-SaveGroupsCopy }
}

# Step 2: Docker reads a test copy first (next to the original, so paths mean the same)
# to make sure each service now has exactly the group that was asked for.
function Test-SaveGroupsCopy {
    $s = $script:AutoGroupSave
    if (-not $script:DockerExe) { Set-SaveGroupsStep 'Check' 'skipped' "docker.exe wasn't found"; Invoke-SaveGroupsNext { Complete-AutoGroups $null }; return }
    $tmpPath = Join-Path $script:ComposeDir ('.' + [IO.Path]::GetFileNameWithoutExtension($script:ComposePath) + '.dcm-group' + [IO.Path]::GetExtension($script:ComposePath))
    try { Write-TextFile @{ Path = $tmpPath; Lines = $s.File.Lines; Bom = $s.File.Bom; NewLine = $s.File.NewLine; EndsWithNewline = $s.File.EndsWithNewline } }
    catch { Stop-SaveGroups 'Check' "Couldn't write a test copy next to the compose file: $($_.Exception.Message)"; return }
    $s.Tmp = $tmpPath
    if ($script:AutoGroupForm) { $script:AutoGroupForm.Note.Text = 'Checking the changed file with Docker...' }
    Start-DockerCall -Local -Arguments (Get-TidyConfigArguments $tmpPath) -OnDone { param($res) Complete-AutoGroups $res }
}

# Steps 2 (Docker's answer) to 6.
function Complete-AutoGroups($Res) {
    $s = $script:AutoGroupSave
    $f = $script:AutoGroupForm
    if (-not $s -or -not $f) {
        $script:AutoGroupSave = $null
        if ($s -and $s.Tmp) { Remove-Item -LiteralPath $s.Tmp -Force -ErrorAction SilentlyContinue }
        if ($script:SaveGroupsBox) { $script:SaveGroupsBox.Busy = $false; $script:SaveGroupsBox.Window.Close() }
        return
    }
    if ($s.Tmp) { Remove-Item -LiteralPath $s.Tmp -Force -ErrorAction SilentlyContinue; $s.Tmp = '' }
    if ($Res) {
        $problem = ''
        if ($Res.ExitCode -ne 0) { $problem = "Docker can't read the changed file: $(Get-FirstLines $Res.Error 3)" }
        else {
            try { $cfg = $Res.Output | ConvertFrom-Json } catch { $cfg = $null; $problem = "Docker's answer couldn't be read." }
            if ($cfg) {
                foreach ($svc in $s.Done) {
                    $labels = Get-ServiceLabels (Get-PropValue $cfg.services $svc)
                    $got = [string]$labels[$s.Label]
                    if ($got -cne $s.Want[$svc] -and $got -cne $s.Want[$svc].Replace('$', '$$')) { $problem = "$svc doesn't get the group $($s.Want[$svc]) from the changed file."; break }
                }
            }
        }
        if ($problem) { Stop-SaveGroups 'Check' "$problem`n`nThe Check window can show what to fix in the compose file."; return }
        Set-SaveGroupsStep 'Check' 'done'
    }
    if ((Get-FileStamp) -ne $f.Stamp) { Stop-SaveGroups 'Backup' 'The compose file was changed somewhere else in the meantime, so nothing was saved.'; return }
    Set-SaveGroupsStep 'Backup' 'running'
    Invoke-SaveGroupsNext { Save-AutoGroupsFile }
}

# Steps 3 to 5: backup, write, then read the file back to make sure it says what was meant.
function Save-AutoGroupsFile {
    $s = $script:AutoGroupSave
    try { $s.Bak = Backup-ConfigFile $script:ComposePath }
    catch { Stop-SaveGroups 'Backup' "Couldn't make a backup, so nothing was saved: $($_.Exception.Message)"; return }
    Set-SaveGroupsStep 'Backup' 'done' $(if ($s.Bak) { [IO.Path]::GetFileName($s.Bak) } else { '' })
    Set-SaveGroupsStep 'Write' 'running' "$($s.Done.Count) label(s)"
    try { Write-TextFile $s.File }
    catch { Stop-SaveGroups 'Write' "Saving failed: $($_.Exception.Message)"; return }
    Set-SaveGroupsStep 'Write' 'done' "$($s.Done.Count) label(s)"
    Set-SaveGroupsStep 'Verify' 'running'
    $problem = ''
    try {
        $back = Read-TextFile $script:ComposePath
        if (($back.Lines.ToArray() -join "`n") -cne ($s.File.Lines.ToArray() -join "`n")) { $problem = "The saved file doesn't read back the same as what was written." }
    } catch { $problem = "Couldn't read the saved file back: $($_.Exception.Message)" }
    if ($problem) {
        # Put the original back from the backup, so the file is as it was.
        $restored = $false
        if ($s.Bak) { try { Copy-Item -LiteralPath $s.Bak -Destination $script:ComposePath -Force; $restored = $true } catch { Write-Verbose 'Restore failed.' } }
        $problem += if ($restored) { ' The original was put back from the backup.' } else { " Put the backup back by hand: $($s.Bak)" }
        Stop-SaveGroups 'Verify' $problem
        return
    }
    Set-SaveGroupsStep 'Verify' 'done'
    Write-Activity ("Group automatically: added {0} to {1} service(s): {2}." -f $s.Label, $s.Done.Count, ($s.Done -join ', '))
    if ($s.Bak) { Write-Activity "Backup: $($s.Bak)" }
    $script:FileStamp = Get-FileStamp
    Set-SaveGroupsStep 'Reload' 'running'
    Invoke-SaveGroupsNext { Complete-SaveGroups }
}

# "Also add ... to My groups": each saved container that isn't in My groups yet.
# Returns a sentence for the message at the end ('' when nothing was added).
function Add-SavedToMyGroups($Save) {
    try {
        $list = Read-MyGroups
        if ($null -eq $list) { $list = New-Object System.Collections.ArrayList }
        $have = @{}
        foreach ($e in $list) { $have[$e.Service.ToLowerInvariant()] = $true }
        $added = 0
        foreach ($svc in $Save.Done) {
            if ($have.ContainsKey($svc.ToLowerInvariant())) { continue }
            [void]$list.Add((New-Object Dcm.MyGroupEntry -Property @{ Service = $svc; Group = $Save.Want[$svc] }))
            $added++
        }
        if (-not $added) { return '' }
        Save-MyGroupsFile @($list)
        Write-Activity "My groups: added $added container(s) from Group automatically."
        return "`n`nAlso added $added of them to My groups."
    } catch {
        Write-Activity "My groups: couldn't add the new groups: $($_.Exception.Message)"
        return "`n`nThey couldn't be added to My groups: $($_.Exception.Message)"
    }
}

# Step 6, then close the box and say how it went.
function Complete-SaveGroups {
    $s = $script:AutoGroupSave
    $f = $script:AutoGroupForm
    $script:AutoGroupSave = $null
    Request-ConfigLoad
    Set-SaveGroupsStep 'Reload' 'done'
    if ($script:SaveGroupsBox) { $script:SaveGroupsBox.Busy = $false; $script:SaveGroupsBox.Window.Close() }
    Show-Finished @(@{ Label = "Save groups: $($s.Label) added to $($s.Done.Count) container(s)"; Failed = $false; Cancelled = $false; Error = '' })
    $msg = "Added a group to $($s.Done.Count) container(s)."
    if ($f -and $f.Mine -and $f.Mine.IsChecked) { $msg += Add-SavedToMyGroups $s }
    if ($s.Skipped.Count) { $msg += "`n`nLeft as they were:`n" + ($s.Skipped -join "`n") }
    $msg += "`n`nThey show Changed until you press Apply changes, which recreates them. Their data is kept."
    if (Get-Machine) { $msg += " They run on $(Get-MachineName), so press Send first." }
    if ($f) { $f.Window.Close() }
    [void][Windows.MessageBox]::Show($window, $msg, 'Group automatically', 'OK', 'Information')
}

# ---------------------------------------------------------------------------
# My groups: your own list of which group each container goes in, kept on this
# PC (my-groups.txt in the settings folder, one "service | Group" per line).
# Group automatically uses it first, so a new compose file gets the groups you
# always use. Filled from a compose file's labels, by hand, or from Group
# automatically. The app never writes it without being asked.
# ---------------------------------------------------------------------------
$script:MyGroupsPath = Join-Path $script:SettingsDir 'my-groups.txt'
$script:MyGroupsAuto = $true   # make my-groups.txt from the first compose file loaded, when there isn't one

# The entries in the file, in file order ($null when there's no file yet).
function Read-MyGroups {
    $p = $script:MyGroupsPath
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
    $list = New-Object System.Collections.ArrayList
    foreach ($line in [IO.File]::ReadAllLines($p)) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        $parts = $t -split '\|', 2
        if ($parts.Count -lt 2) { continue }
        $svc = $parts[0].Trim(); $grp = $parts[1].Trim()
        if ($svc -and $grp) { [void]$list.Add((New-Object Dcm.MyGroupEntry -Property @{ Service = $svc; Group = $grp })) }
    }
    return , $list
}

# service (lower case) -> group, the first line winning; $null when there's no file.
function Get-MyGroupsMap {
    $list = Read-MyGroups
    if ($null -eq $list) { return $null }
    $map = @{}
    foreach ($e in $list) { $k = $e.Service.ToLowerInvariant(); if (-not $map.ContainsKey($k)) { $map[$k] = $e.Group } }
    return $map
}

# Writes the list (sorted by container), after copying the old file to my-groups.bak.txt.
function Save-MyGroupsFile([object[]]$Entries) {
    $p = $script:MyGroupsPath
    $dir = Split-Path -Parent $p
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination (Join-Path $dir 'my-groups.bak.txt') -Force }
    $lines = @(
        '# My groups for Docker Container Manager. This file stays on this PC.',
        '# One container per line: its service name, a | and its group, for example:',
        '#   web | Websites',
        '# Group automatically uses these first. Capitals and spaces around the | don''t matter.',
        '# Lines starting with # are ignored.',
        ''
    ) + @($Entries | Sort-Object { $_.Service } | ForEach-Object { '{0} | {1}' -f $_.Service.Trim(), $_.Group.Trim() })
    $tmp = $p + '.dcm-tmp'
    [IO.File]::WriteAllText($tmp, (($lines -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding $false))
    Move-Item -LiteralPath $tmp -Destination $p -Force
}

# The groups the loaded compose file gives its services (from its labels; nothing is written).
function Get-ComposeGroups {
    $map = [ordered]@{}
    foreach ($r in @($script:Rows | Where-Object { $_.InCompose -and $_.Group -and $_.Group -ne $script:UngroupedName } | Sort-Object Service)) {
        if (-not $map.Contains($r.Service)) { $map[$r.Service] = $r.Group }
    }
    return $map
}

# The My groups list built into the exe (Source\my-groups.txt when it was built), or,
# running from source, Source\my-groups.txt itself. $null when there's none.
function Get-BuiltInMyGroups {
    if ($script:EmbeddedAssets.ContainsKey('my-groups.txt')) { return [Convert]::FromBase64String($script:EmbeddedAssets['my-groups.txt']) }
    if ($PSScriptRoot) {
        $p = Join-Path (Split-Path -Parent $PSScriptRoot) 'my-groups.txt'
        if (Test-Path -LiteralPath $p -PathType Leaf) { return [IO.File]::ReadAllBytes($p) }
    }
    return $null
}

# How many containers a my-groups.txt (as bytes) lists.
function Get-MyGroupsCount([byte[]]$Bytes) {
    $text = (New-Object Text.UTF8Encoding $false).GetString($Bytes)
    return @($text -split "`r?`n" | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') -and $_.Contains('|') }).Count
}

# First use: when there's no my-groups.txt yet, it's made from the built-in list or,
# without one, from the group labels of the compose file that's loaded (once it has
# some). Activity says which. Nothing to answer, and an existing file is never replaced.
# Returns $true when a file exists afterwards.
function Initialize-MyGroupsFile {
    if (Test-Path -LiteralPath $script:MyGroupsPath -PathType Leaf) { return $true }
    $builtIn = Get-BuiltInMyGroups
    if ($builtIn) {
        try {
            $dir = Split-Path -Parent $script:MyGroupsPath
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            [IO.File]::WriteAllBytes($script:MyGroupsPath, $builtIn)
            Write-Activity "My groups: made $script:MyGroupsPath from the built-in list ($(Get-MyGroupsCount $builtIn) containers). Settings > My groups... shows it."
            return $true
        } catch { Write-Activity "My groups: couldn't write the built-in list: $($_.Exception.Message)" }
    }
    $groups = Get-ComposeGroups
    if (-not $groups.Count) { return $false }
    try {
        Save-MyGroupsFile @($groups.Keys | ForEach-Object { New-Object Dcm.MyGroupEntry -Property @{ Service = $_; Group = $groups[$_] } })
        Write-Activity "My groups: made $script:MyGroupsPath from the $($groups.Count) group label(s) in the compose file. Settings > My groups... shows it."
        return $true
    } catch {
        Write-Activity "My groups: couldn't make $($script:MyGroupsPath): $($_.Exception.Message)"
        return $false
    }
}
$myGroupsXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="My groups" Width="680" Height="600" MinWidth="560" MinHeight="380" WindowStartupLocation="CenterOwner"
        FontFamily="Segoe UI" FontSize="13" Background="{DynamicResource Page}" Foreground="{DynamicResource Ink}">
    <Window.Resources><!--SHARED--></Window.Resources>
    <DockPanel Margin="14">
        <StackPanel DockPanel.Dock="Top" Margin="0,0,0,10">
            <TextBlock Text="My groups" FontSize="18" FontWeight="SemiBold"/>
            <TextBlock Foreground="{StaticResource SoftInk}" TextWrapping="Wrap" Margin="0,2,0,0"
                       Text="The group you use for each container. Group automatically uses this list first, then guesses from the image name. Double-click a cell (or press F2) to change it."/>
        </StackPanel>
        <Grid DockPanel.Dock="Top" Margin="0,0,0,8">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <TextBox x:Name="TxtMgFilter" Style="{StaticResource Field}" ToolTip="Show only containers or groups containing this text" Margin="0,0,10,0"/>
            <TextBlock x:Name="TxtMgFilterHint" Text="Filter" Foreground="{StaticResource SoftInk}" IsHitTestVisible="False" VerticalAlignment="Center" Margin="9,0,0,0"/>
            <StackPanel Grid.Column="1" Orientation="Horizontal">
                <Button x:Name="BtnMgAdd" Content="Add" Tag="&#xE710;" Style="{StaticResource Btn}" ToolTip="Add a row for a container"/>
                <Button x:Name="BtnMgRemove" Content="Remove" Tag="&#xE74D;" Style="{StaticResource Btn}" ToolTip="Remove the selected rows from the list (Delete)"/>
                <Button x:Name="BtnMgUpdate" Content="Update from current compose file" Tag="&#xE72C;" Style="{StaticResource Btn}" Margin="0"
                        ToolTip="Read the group labels in the compose file that's open now (it isn't changed). New containers are added; you're asked before any group here changes."/>
            </StackPanel>
        </Grid>
        <Grid DockPanel.Dock="Bottom" Margin="0,10,0,0">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <TextBlock x:Name="TxtMgNote" Foreground="{StaticResource SoftInk}" TextWrapping="Wrap" VerticalAlignment="Center" Margin="0,0,12,0"/>
            <StackPanel Grid.Column="1" Orientation="Horizontal">
                <Button x:Name="BtnMgReset" Content="Reset to built-in list..." Tag="&#xE777;" Style="{StaticResource Btn}"
                        ToolTip="Replace this list with the one built into the app. Asks first; your list is kept as my-groups.bak.txt."/>
                <Button x:Name="BtnMgEditor" Content="Open in editor" Tag="&#xE70F;" Style="{StaticResource Btn}" ToolTip="Open my-groups.txt in your editor (from Settings)"/>
                <Button x:Name="BtnMgFolder" Content="Open folder" Tag="&#xE838;" Style="{StaticResource Btn}" ToolTip="Show my-groups.txt in File Explorer"/>
                <Button x:Name="BtnMgSave" Content="Save" Tag="&#xE74E;" Style="{StaticResource PrimaryBtn}" ToolTip="Save the list (the old one is kept as my-groups.bak.txt)"/>
                <Button x:Name="BtnMgClose" Content="Close" Style="{StaticResource Btn}" IsCancel="True" Margin="0"/>
            </StackPanel>
        </Grid>
        <Border Background="{StaticResource Card}" BorderBrush="{StaticResource Edge}" BorderThickness="1" CornerRadius="8" Padding="2">
            <Grid>
                <DataGrid x:Name="GridMg" AutoGenerateColumns="False" HeadersVisibility="Column" GridLinesVisibility="None" BorderThickness="0"
                          Background="Transparent" SelectionMode="Extended" SelectionUnit="FullRow" CanUserAddRows="False" CanUserDeleteRows="False"
                          CanUserSortColumns="True" RowHeight="28">
                    <DataGrid.RowStyle>
                        <Style TargetType="DataGridRow">
                            <Setter Property="Background" Value="Transparent"/>
                            <Setter Property="BorderThickness" Value="4,0,0,0"/>
                            <Setter Property="BorderBrush" Value="Transparent"/>
                            <Style.Triggers>
                                <Trigger Property="IsMouseOver" Value="True">
                                    <Setter Property="Background" Value="{DynamicResource Hover}"/>
                                </Trigger>
                                <Trigger Property="IsSelected" Value="True">
                                    <Setter Property="Background" Value="{DynamicResource Selected}"/>
                                    <Setter Property="BorderBrush" Value="{DynamicResource Accent}"/>
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
                        <DataGridTextColumn Header="Container" Binding="{Binding Service, UpdateSourceTrigger=LostFocus}" SortMemberPath="Service" Width="*"/>
                        <DataGridTextColumn Header="Group" Binding="{Binding Group, UpdateSourceTrigger=LostFocus}" SortMemberPath="Group" Width="*"/>
                    </DataGrid.Columns>
                </DataGrid>
                <TextBlock x:Name="TxtMgEmpty" HorizontalAlignment="Center" VerticalAlignment="Center" TextAlignment="Center" TextWrapping="Wrap" Margin="20"
                           Foreground="{StaticResource SoftInk}" Visibility="Collapsed"/>
            </Grid>
        </Border>
    </DockPanel>
</Window>
'@

function Update-MyGroupsNote {
    $g = $script:MyGroupsForm
    if (-not $g) { return }
    $n = $g.List.Count
    $shown = @($g.View).Count
    $where = if (Test-Path -LiteralPath $script:MyGroupsPath) { "Saved in $script:MyGroupsPath" } else { "Not saved yet. Save makes $script:MyGroupsPath" }
    $count = if ($shown -ne $n) { "$shown of $n shown" } else { "$n container(s)" }
    $g.Note.Text = "$count$(if ($g.Dirty) { ' - not saved yet' }).  $where"
    $g.Empty.Text = if ($n) { 'Nothing matches the filter.' } else { "No containers yet.`nPress Update from current compose file, or Add." }
    $g.Empty.Visibility = if ($shown) { 'Collapsed' } else { 'Visible' }
    $g.Window.Title = 'My groups' + $(if ($g.Dirty) { ' *' } else { '' })
}

function Set-MyGroupsDirty { if ($script:MyGroupsForm) { $script:MyGroupsForm.Dirty = $true; Update-MyGroupsNote } }

# Adds the compose file's groups: new containers straight in, changed groups only after asking.
function Update-MyGroupsFromCompose {
    $g = $script:MyGroupsForm
    [void]$g.Grid.CommitEdit()
    $groups = Get-ComposeGroups
    if (-not $groups.Count) { [void][Windows.MessageBox]::Show($g.Window, 'The compose file open now has no group labels to add.', 'My groups', 'OK', 'Information'); return }
    $have = @{}
    foreach ($e in $g.List) { if ($e.Service) { $have[$e.Service.Trim().ToLowerInvariant()] = $e } }
    $new = New-Object System.Collections.ArrayList
    $changed = New-Object System.Collections.ArrayList
    foreach ($svc in $groups.Keys) {
        $e = $have[$svc.ToLowerInvariant()]
        if (-not $e) { [void]$new.Add($svc) }
        elseif ($e.Group.Trim() -ne $groups[$svc]) { [void]$changed.Add($svc) }
    }
    if (-not $new.Count -and -not $changed.Count) { $g.Note.Text = 'My groups already has every group in the compose file.'; return }
    $doChange = $false
    if ($changed.Count) {
        $shown = @($changed | Select-Object -First 20 | ForEach-Object { "$($_):  $($have[$_.ToLowerInvariant()].Group.Trim())  ->  $($groups[$_])" }) -join "`n"
        if ($changed.Count -gt 20) { $shown += "`n... and $($changed.Count - 20) more" }
        $q = "The compose file gives $($changed.Count) container(s) a different group from My groups:`n`n$shown`n`nChange them to the compose file's group?`n`nYes: change them$(if ($new.Count) { " and add the $($new.Count) new one(s)" }).`nNo: keep My groups as it is$(if ($new.Count) { " and only add the new one(s)" }).`nCancel: change nothing."
        $a = [Windows.MessageBox]::Show($g.Window, $q, 'My groups', 'YesNoCancel', 'Question')
        if ($a -eq 'Cancel') { return }
        $doChange = ($a -eq 'Yes')
    }
    foreach ($svc in $new) { $g.List.Add((New-Object Dcm.MyGroupEntry -Property @{ Service = $svc; Group = $groups[$svc] })) }
    if ($doChange) { foreach ($svc in $changed) { $have[$svc.ToLowerInvariant()].Group = $groups[$svc] } }
    $g.View.Refresh()
    if ($new.Count -or $doChange) { Set-MyGroupsDirty }
    $g.Note.Text = "Added $($new.Count)$(if ($doChange) { ", changed $($changed.Count)" }) from the compose file. Press Save to keep them."
}

# Saves the window's list. Returns $true when it was saved.
function Save-MyGroupsWindow {
    $g = $script:MyGroupsForm
    [void]$g.Grid.CommitEdit()
    [void]$g.Grid.CommitEdit()
    $keep = New-Object System.Collections.ArrayList
    $problems = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($e in $g.List) {
        $svc = ([string]$e.Service).Trim(); $grp = ([string]$e.Group).Trim()
        if (-not $svc -and -not $grp) { continue }
        if (-not $svc) { [void]$problems.Add("A row has the group $grp but no container."); continue }
        if (-not $grp) { [void]$problems.Add("$svc has no group."); continue }
        if ($svc.Contains('|')) { [void]$problems.Add("$svc has a | in its name."); continue }
        $k = $svc.ToLowerInvariant()
        if ($seen.ContainsKey($k)) { [void]$problems.Add("$svc is in the list twice."); continue }
        $seen[$k] = $true
        [void]$keep.Add((New-Object Dcm.MyGroupEntry -Property @{ Service = $svc; Group = $grp }))
    }
    if ($problems.Count) {
        $shown = @($problems | Select-Object -First 15) -join "`n"
        [void][Windows.MessageBox]::Show($g.Window, "Nothing was saved. Fix these first:`n`n$shown", 'My groups', 'OK', 'Warning')
        return $false
    }
    try { Save-MyGroupsFile @($keep) }
    catch { [void][Windows.MessageBox]::Show($g.Window, "Couldn't save My groups: $($_.Exception.Message)", 'My groups', 'OK', 'Error'); return $false }
    Write-Activity "My groups: saved $($keep.Count) container(s) to $script:MyGroupsPath."
    # Show it as saved: tidied and sorted the way the file is.
    $g.List.Clear()
    foreach ($e in @($keep | Sort-Object Service)) { $g.List.Add($e) }
    $g.Dirty = $false
    Update-MyGroupsNote
    return $true
}

function Show-MyGroups($Owner) {
    if (-not $Owner) { $Owner = $window }
    if ($script:MyGroupsForm) { [void]$script:MyGroupsForm.Window.Activate(); return }
    [void](Initialize-MyGroupsFile)
    $w = New-XamlObject $myGroupsXaml
    $w.Owner = $Owner
    if ($window.Icon) { $w.Icon = $window.Icon }
    $list = New-Object 'System.Collections.ObjectModel.ObservableCollection[Dcm.MyGroupEntry]'
    $read = Read-MyGroups
    if ($read) { foreach ($e in $read) { $list.Add($e) } }
    $g = @{ Window = $w; List = $list; Dirty = $false; Grid = $w.FindName('GridMg'); Note = $w.FindName('TxtMgNote'); Empty = $w.FindName('TxtMgEmpty'); Filter = $w.FindName('TxtMgFilter'); Hint = $w.FindName('TxtMgFilterHint') }
    $g.Grid.ItemsSource = $list
    $g.View = [Windows.Data.CollectionViewSource]::GetDefaultView($list)
    $script:MyGroupsForm = $g
    # Setting the filter runs it straight away, so the form must be known first.
    $g.View.Filter = [Predicate[object]] {
        param($o)
        $s = $script:MyGroupsForm
        $t = if ($s) { $s.Filter.Text.Trim() } else { '' }
        if (-not $t) { return $true }
        return ([string]$o.Service).IndexOf($t, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or ([string]$o.Group).IndexOf($t, [StringComparison]::OrdinalIgnoreCase) -ge 0
    }
    $g.Filter.Add_TextChanged({
            $s = $script:MyGroupsForm
            $s.Hint.Visibility = if ($s.Filter.Text) { 'Collapsed' } else { 'Visible' }
            [void]$s.Grid.CommitEdit(); [void]$s.Grid.CommitEdit()
            $s.View.Refresh()
            Update-MyGroupsNote
        })
    $g.Grid.Add_CellEditEnding({ param($s, $e) if ($e.EditAction -eq 'Commit') { Set-MyGroupsDirty } })
    $g.Grid.Add_PreviewKeyDown({
            param($s, $e)
            if ($e.Key -eq 'Delete' -and -not ($e.OriginalSource -is [Windows.Controls.TextBox])) { Remove-MyGroupsSelected; $e.Handled = $true }
        })
    $w.FindName('BtnMgAdd').Add_Click({
            $s = $script:MyGroupsForm
            [void]$s.Grid.CommitEdit(); [void]$s.Grid.CommitEdit()
            $s.Filter.Text = ''
            $e = New-Object Dcm.MyGroupEntry -Property @{ Service = ''; Group = '' }
            $s.List.Add($e)
            Set-MyGroupsDirty
            $s.Grid.SelectedItem = $e
            $s.Grid.ScrollIntoView($e)
            $s.Grid.CurrentCell = New-Object Windows.Controls.DataGridCellInfo($e, $s.Grid.Columns[0])
            [void]$s.Grid.Focus()
            [void]$s.Grid.BeginEdit()
        })
    $w.FindName('BtnMgRemove').Add_Click({ Remove-MyGroupsSelected })
    $w.FindName('BtnMgUpdate').Add_Click({ Update-MyGroupsFromCompose })
    $reset = $w.FindName('BtnMgReset')
    if (Get-BuiltInMyGroups) { $reset.Add_Click({ Reset-MyGroups }) } else { $reset.Visibility = 'Collapsed' }
    $w.FindName('BtnMgSave').Add_Click({ [void](Save-MyGroupsWindow) })
    $w.FindName('BtnMgClose').Add_Click({ $script:MyGroupsForm.Window.Close() })
    $w.FindName('BtnMgEditor').Add_Click({
            $s = $script:MyGroupsForm
            if (-not (Test-Path -LiteralPath $script:MyGroupsPath)) { [void][Windows.MessageBox]::Show($s.Window, 'There''s no my-groups.txt yet. Press Save first.', 'My groups', 'OK', 'Information'); return }
            if ($s.Dirty) { [void][Windows.MessageBox]::Show($s.Window, 'The editor shows the saved file. Your changes here aren''t saved yet.', 'My groups', 'OK', 'Information') }
            Open-InEditor $script:MyGroupsPath
        })
    $w.FindName('BtnMgFolder').Add_Click({
            $p = $script:MyGroupsPath
            if (Test-Path -LiteralPath $p) { Start-Process -FilePath 'explorer.exe' -ArgumentList "/select,`"$p`"" }
            elseif (Test-Path -LiteralPath (Split-Path -Parent $p)) { Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$(Split-Path -Parent $p)`"" }
        })
    $w.Add_Closing({
            param($src, $e)
            $s = $script:MyGroupsForm
            if (-not $s) { return }
            [void]$s.Grid.CommitEdit(); [void]$s.Grid.CommitEdit()
            if (-not $s.Dirty) { return }
            $a = [Windows.MessageBox]::Show($s.Window, 'Save the changes to My groups?', 'My groups', 'YesNoCancel', 'Question')
            if ($a -eq 'Cancel' -or ($a -eq 'Yes' -and -not (Save-MyGroupsWindow))) { $e.Cancel = $true }
        })
    $w.Add_Closed({ $script:MyGroupsForm = $null })
    Update-MyGroupsNote
    [void]$w.ShowDialog()
}

# Replaces my-groups.txt with the built-in list, after asking and a backup.
function Reset-MyGroups {
    $s = $script:MyGroupsForm
    $builtIn = Get-BuiltInMyGroups
    if (-not $s -or -not $builtIn) { return }
    [void]$s.Grid.CommitEdit(); [void]$s.Grid.CommitEdit()
    $q = "Replace My groups with the list built into the app ($(Get-MyGroupsCount $builtIn) containers)?"
    $q += if (Test-Path -LiteralPath $script:MyGroupsPath) { "`n`nYour list now is kept as my-groups.bak.txt in the same folder." } else { '' }
    if ($s.Dirty) { $q += "`n`nChanges here that aren't saved are lost." }
    if ([Windows.MessageBox]::Show($s.Window, $q, 'My groups', 'YesNo', 'Warning', 'No') -ne 'Yes') { return }
    try {
        $dir = Split-Path -Parent $script:MyGroupsPath
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        if (Test-Path -LiteralPath $script:MyGroupsPath) { Copy-Item -LiteralPath $script:MyGroupsPath -Destination (Join-Path $dir 'my-groups.bak.txt') -Force }
        [IO.File]::WriteAllBytes($script:MyGroupsPath, $builtIn)
    } catch { [void][Windows.MessageBox]::Show($s.Window, "Couldn't reset My groups: $($_.Exception.Message)", 'My groups', 'OK', 'Error'); return }
    Write-Activity 'My groups: replaced with the built-in list (the old one is my-groups.bak.txt).'
    $s.List.Clear()
    $read = Read-MyGroups
    if ($read) { foreach ($x in $read) { $s.List.Add($x) } }
    $s.Dirty = $false
    $s.View.Refresh()
    Update-MyGroupsNote
    $s.Note.Text = "Reset to the built-in list ($($s.List.Count) containers). Your old list is my-groups.bak.txt."
}

function Remove-MyGroupsSelected {
    $s = $script:MyGroupsForm
    $sel = @($s.Grid.SelectedItems | Where-Object { $_ -is [Dcm.MyGroupEntry] })
    if (-not $sel.Count) { return }
    [void]$s.Grid.CancelEdit()
    foreach ($e in $sel) { [void]$s.List.Remove($e) }
    Set-MyGroupsDirty
}

# ---------------------------------------------------------------------------
# Source pages: a container's project page (GitHub, GitLab, Docker Hub).
# Found from, in order: a <prefix>.source label, your own list (a text file in
# the settings folder, kept on this PC only), the image's own
# org.opencontainers.image.source label, then a guess from the image name.
# ---------------------------------------------------------------------------
$script:SourcesPath = Join-Path $script:SettingsDir 'source-links.txt'
$script:SourceList = $null
$script:SourceCache = @{}   # machine|image -> the image's own source label ('' when it has none)

function ConvertTo-SourceKey([string]$Text) { return ([string]$Text).ToLowerInvariant() -replace '[^a-z0-9]', '' }

# https://github.com/linuxserver/docker-firefox -> firefox
function Get-SourceUrlKey([string]$Url) {
    $m = [regex]::Match($Url, '^https?://(?:www\.)?(?:github\.com|gitlab\.com)/[^/]+/([^/?#]+)')
    if (-not $m.Success) { return '' }
    return ConvertTo-SourceKey ($m.Groups[1].Value -replace '^docker-', '' -replace '\.git$', '')
}

# Reads the list again only when the file has changed.
function Read-SourceList {
    $p = $script:SourcesPath
    if (-not (Test-Path -LiteralPath $p)) { $script:SourceList = @{ Stamp = $null; Map = @{} }; return }
    $stamp = (Get-Item -LiteralPath $p).LastWriteTimeUtc
    if ($script:SourceList -and $script:SourceList.Stamp -eq $stamp) { return }
    $map = @{}
    foreach ($line in [IO.File]::ReadAllLines($p)) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        $m = [regex]::Match($t, '^(.*?)[\s=|,;]*(https?://\S+)\s*$')
        if (-not $m.Success) { continue }
        $url = $m.Groups[2].Value
        foreach ($k in @((ConvertTo-SourceKey $m.Groups[1].Value), (Get-SourceUrlKey $url))) {
            if ($k -and -not $map.ContainsKey($k)) { $map[$k] = $url }
        }
    }
    $script:SourceList = @{ Stamp = $stamp; Map = $map }
}

# The words a list entry is matched against: the image's name and the service's name.
function Get-SourceKeys([Dcm.Row]$Row) {
    $keys = New-Object System.Collections.ArrayList
    $parts = Get-ImageParts $Row.Image
    if ($parts) { [void]$keys.Add((ConvertTo-SourceKey ((($parts.Repo -split '/')[-1]) -replace '^docker-', ''))) }
    [void]$keys.Add((ConvertTo-SourceKey $Row.Service))
    [void]$keys.Add((ConvertTo-SourceKey $Row.ContainerName))
    return @($keys | Where-Object { $_ } | Select-Object -Unique)
}

function Get-GuessedSource([string]$Image) {
    $p = Get-ImageParts $Image
    if (-not $p) { return '' }
    $repo = $p.Repo
    $parts = $repo -split '/'
    $name = $parts[-1]
    if ($p.Registry -eq 'ghcr.io' -and $parts.Count -ge 2) { return "https://github.com/$($parts[0])/$($parts[1])" }
    if ($p.Registry -eq 'registry.gitlab.com' -and $parts.Count -ge 2) { return "https://gitlab.com/$($parts[0])/$($parts[1])" }
    if (($p.Registry -eq 'lscr.io' -or $p.Registry -eq 'docker.io') -and $parts[0] -eq 'linuxserver') { return "https://github.com/linuxserver/docker-$name" }
    if ($p.Registry -eq 'docker.io') {
        if ($parts[0] -eq 'library') { return "https://hub.docker.com/_/$name" }
        return "https://hub.docker.com/r/$repo"
    }
    return ''
}

# The page found without asking Docker: the label, then your list, then what an
# earlier lookup of the image found. Url is '' when the label says none.
function Get-SourcePage([Dcm.Row]$Row) {
    $label = ([string]$Row.SourceLabel).Trim()
    if ($label -eq 'none') { return @{ Url = ''; From = "the $($script:Settings.LabelPrefix).source label" } }
    if ($label -match '^https?://') { return @{ Url = $label; From = "the $($script:Settings.LabelPrefix).source label" } }
    Read-SourceList
    foreach ($k in (Get-SourceKeys $Row)) {
        if ($script:SourceList.Map.ContainsKey($k)) { return @{ Url = $script:SourceList.Map[$k]; From = 'your source links list' } }
    }
    $ck = (Get-MachineName) + '|' + $Row.Image
    if ($script:SourceCache.ContainsKey($ck) -and $script:SourceCache[$ck]) { return @{ Url = $script:SourceCache[$ck]; From = "the image's own label" } }
    return $null
}

# What the Source page button and menu item will open, for their tooltips.
function Get-SourceHint([Dcm.Row]$Row) {
    if (-not $Row) { return 'Open the selected container''s project page (GitHub, GitLab or Docker Hub)' }
    $s = Get-SourcePage $Row
    if ($s -and -not $s.Url) { return "Hidden by the $($script:Settings.LabelPrefix).source label" }
    if ($s) { return "Opens $($s.Url)" }
    $ck = (Get-MachineName) + '|' + $Row.Image
    $guess = Get-GuessedSource $Row.Image
    if ($script:SourceCache.ContainsKey($ck)) { if ($guess) { return "Opens $guess" } else { return 'No source page known for this image' } }
    if ($guess) { return "Asks Docker for the image's own source page first, otherwise opens $guess" }
    return 'Asks Docker for the image''s own source page'
}

function Open-SourceUrl([string]$Url, [Dcm.Row]$Row, [string]$From) {
    Write-Activity "Source page of $($Row.Service): $Url (from $From)"
    try { Start-Process -FilePath $Url } catch { Set-Status "Couldn't open $Url" }
}

function Open-SourcePage([Dcm.Row]$Row) {
    if (-not $Row) { return }
    $s = Get-SourcePage $Row
    if ($s -and -not $s.Url) { Set-Status "The $($script:Settings.LabelPrefix).source label hides the source page of $($Row.Service)."; return }
    if ($s) { Open-SourceUrl $s.Url $Row $s.From; return }
    # Most images name their source in a label of their own; ask Docker before guessing.
    $ck = (Get-MachineName) + '|' + $Row.Image
    if ($script:SourceCache.ContainsKey($ck) -or -not $Row.Image -or -not (Test-DockerReady)) { Complete-SourceLookup $null $Row; return }
    Set-Status "Looking up the source page of $($Row.Service)..."
    Start-DockerCall -Arguments @('image', 'inspect', '--format', '{{index .Config.Labels "org.opencontainers.image.source"}}', $Row.Image) -Tag $Row -OnDone { param($res, $row) Complete-SourceLookup $res $row }
}

function Complete-SourceLookup($Res, [Dcm.Row]$Row) {
    $row = $Row
    if (-not $row) { return }
    Set-Status ''
    $url = ''
    if ($Res -and $Res.ExitCode -eq 0) {
        $url = ((([string]$Res.Output).Trim() -split "`r?`n")[0]).Trim() -replace '\.git$', ''
        if ($url -notmatch '^https?://') { $url = '' }
        # Remember the answer (also "none"), so the image is asked about once.
        $script:SourceCache[(Get-MachineName) + '|' + $row.Image] = $url
    }
    if ($url) { Open-SourceUrl $url $row "the image's own label"; return }
    $guess = Get-GuessedSource $row.Image
    if ($guess) { Open-SourceUrl $guess $row 'a guess from the image name'; return }
    Set-Status "No source page found for $($row.Service). Add it to your source links (right-click > Edit source links)."
}

function Edit-SourceList {
    $p = $script:SourcesPath
    if (-not (Test-Path -LiteralPath $p)) {
        if (-not (Test-Path -LiteralPath $script:SettingsDir)) { New-Item -ItemType Directory -Path $script:SettingsDir -Force | Out-Null }
        $text = @(
            '# Source links for Docker Container Manager. This file stays on this PC.',
            '# One page per line: a name, a | and the page''s address, for example:',
            '#   Sonarr | https://github.com/Sonarr/Sonarr',
            '# The name (or the project name in a GitHub or GitLab address) is matched to the image, service or container name.',
            '# Capitals, spaces, dashes, dots and underscores don''t matter. Lines starting with # are ignored.',
            '') -join "`r`n"
        [IO.File]::WriteAllText($p, $text, (New-Object Text.UTF8Encoding $false))
    }
    Open-InEditor $p
}

# ---------------------------------------------------------------------------
# Export: the list as a web page (one HTML file, no other files needed).
# ---------------------------------------------------------------------------
function ConvertTo-HtmlText([string]$Text) { return [Net.WebUtility]::HtmlEncode([string]$Text) }

# Web pages on another machine are on that machine, not on this PC.
function Get-ShownUrl([string]$Url) {
    $m = Get-Machine
    if ($m -and $Url) { return ($Url -replace '^(?i)(https?://)(localhost|127\.0\.0\.1)(?=[:/]|$)', ('${1}' + (Get-MachineHost $m))) }
    return $Url
}

# A cached icon as a data: address, so the page needs no other files.
function Get-IconDataUri([Dcm.Row]$Row) {
    $p = [string]$Row.IconKey
    if (-not $p -or -not (Test-Path -LiteralPath $p -PathType Leaf)) { return '' }
    try {
        $f = Get-Item -LiteralPath $p
        if ($f.Length -gt 300kb) { return '' }
        $type = switch -Regex ($f.Extension.ToLowerInvariant()) { '\.jpe?g' { 'image/jpeg' } '\.gif' { 'image/gif' } '\.ico' { 'image/x-icon' } '\.bmp' { 'image/bmp' } default { 'image/png' } }
        return "data:$type;base64," + [Convert]::ToBase64String([IO.File]::ReadAllBytes($p))
    } catch { return '' }
}

function New-ExportHtml([object[]]$Rows, [string]$Scope) {
    $rows = @($Rows)
    $running = @($rows | Where-Object IsRunning).Count
    $problems = @($rows | Where-Object Problem).Count
    $changed = @($rows | Where-Object Changed).Count
    $updates = @($rows | Where-Object UpdateAvailable).Count
    $title = if ($script:ProjectName) { "$script:ProjectName - Docker containers" } else { 'Docker containers' }
    $sb = New-Object Text.StringBuilder
    $add = { param($s) [void]$sb.Append($s) }
    & $add @'
<!DOCTYPE html>
<html lang="en" class="%THEME%">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
'@
    & $add "<title>$(ConvertTo-HtmlText $title)</title>`n"
    & $add @'
<style>
/* The app's theme picks the colours: html.light, html.dark, or html.auto (follows the browser).
   The switch at the top (a checkbox, no scripts) shows the other one. */
.page, html.dark .flip:checked ~ .page { --page:#f4f6f9; --card:#ffffff; --ink:#1b2430; --soft:#5d6b7c; --edge:#dde3ea; --accent:#1a73d9; --ok:#2da44e; --bad:#cf222e; --off:#97a3b3; --warn:#b07a00; }
html.dark .page, html.light .flip:checked ~ .page, html.auto .flip:checked ~ .page { --page:#161b22; --card:#1f2630; --ink:#e6edf3; --soft:#9aa7b4; --edge:#30363d; --accent:#4c9bea; --ok:#3fb950; --bad:#f85149; --off:#6e7681; --warn:#e3b341; }
@media (prefers-color-scheme: dark) { html.auto .page { --page:#161b22; --card:#1f2630; --ink:#e6edf3; --soft:#9aa7b4; --edge:#30363d; --accent:#4c9bea; --ok:#3fb950; --bad:#f85149; --off:#6e7681; --warn:#e3b341; } html.auto .flip:checked ~ .page { --page:#f4f6f9; --card:#ffffff; --ink:#1b2430; --soft:#5d6b7c; --edge:#dde3ea; --accent:#1a73d9; --ok:#2da44e; --bad:#cf222e; --off:#97a3b3; --warn:#b07a00; } }
* { box-sizing: border-box; }
body { margin: 0; font: 14px/1.45 "Segoe UI", system-ui, sans-serif; }
.page { min-height: 100vh; padding: 24px; background: var(--page); color: var(--ink); }
.flip { position: absolute; opacity: 0; pointer-events: none; }
.flipper { position: absolute; top: 14px; right: 16px; background: rgba(255,255,255,.16); color: #fff; border: 1px solid rgba(255,255,255,.55); border-radius: 16px; padding: 5px 14px; font-size: 13px; font-weight: 600; cursor: pointer; user-select: none; }
.flipper:hover { background: rgba(255,255,255,.28); }
.flip:focus-visible ~ .page .flipper { outline: 2px solid var(--accent); }
header { position: relative; background: linear-gradient(90deg, #12325a, #1e5fa8); color: #fff; border-radius: 10px; padding: 18px 170px 18px 22px; margin-bottom: 16px; }
header h1 { margin: 0 0 4px; font-size: 22px; font-weight: 600; }
header p { margin: 0; color: #cfe0f5; overflow-wrap: anywhere; }
.chips { display: flex; flex-wrap: wrap; gap: 8px; margin: 0 0 16px; }
.chip { background: var(--card); border: 1px solid var(--edge); border-radius: 8px; padding: 8px 14px; }
.chip b { font-size: 18px; display: block; }
section { background: var(--card); border: 1px solid var(--edge); border-radius: 10px; padding: 14px 16px; margin-bottom: 14px; }
h2 { margin: 0 0 8px; font-size: 16px; display: flex; align-items: center; gap: 8px; }
h2 .bar { width: 5px; height: 18px; border-radius: 3px; }
h2 small { color: var(--soft); font-weight: 400; }
.wrap { overflow-x: auto; }
table { width: 100%; border-collapse: collapse; table-layout: fixed; min-width: 900px; }
th:nth-child(1) { width: 24px; } th:nth-child(2) { width: 20%; } th:nth-child(3) { width: 10%; } th:nth-child(4) { width: 11%; }
th:nth-child(5) { width: 8%; } th:nth-child(6) { width: 17%; } th:nth-child(7) { width: 19%; }
td { overflow-wrap: anywhere; }
th { text-align: left; color: var(--soft); font-weight: 600; border-bottom: 1px solid var(--edge); padding: 6px 8px; white-space: nowrap; }
td { padding: 6px 8px; border-bottom: 1px solid var(--edge); vertical-align: top; }
tr:last-child td { border-bottom: none; }
.dot { display: inline-block; width: 10px; height: 10px; border-radius: 50%; background: var(--off); }
.dot.ok { background: var(--ok); } .dot.bad { background: var(--bad); }
.st.ok { color: var(--ok); } .st.bad { color: var(--bad); } .st.off { color: var(--soft); }
.name { font-weight: 600; } .desc, .soft { color: var(--soft); font-size: 12px; }
.ico { width: 20px; height: 20px; vertical-align: middle; margin-right: 6px; object-fit: contain; }
.note { color: var(--warn); }
a { color: var(--accent); text-decoration: none; } a:hover { text-decoration: underline; }
footer { color: var(--soft); font-size: 12px; margin-top: 18px; }
@media print {
  .page { --page:#ffffff !important; --card:#ffffff !important; --ink:#000000 !important; --soft:#444444 !important; --edge:#cccccc !important; --accent:#1a73d9 !important; --ok:#2da44e !important; --bad:#cf222e !important; --off:#97a3b3 !important; --warn:#b07a00 !important; padding: 0; }
  body { font-size: 11px; }
  .flipper { display: none; }
  header, .dot, h2 .bar { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
  section { break-inside: avoid; }
  a { color: inherit; }
}
</style>
</head>
<body>
<input type="checkbox" id="flip" class="flip" aria-label="Switch between light and dark">
<div class="page">
'@
    $machine = Get-MachineName
    $where = if ($script:ComposePath) { Get-ComposeDisplay } else { '' }
    $project = if ($script:ProjectName) { "project $script:ProjectName &middot; " } else { '' }
    & $add ("<header><label for=""flip"" class=""flipper"" title=""Switch between light and dark"">&#9680; Light / dark</label><h1>{0}</h1><p>{1}</p><p>Containers on {2} &middot; {3}{4} containers{5} &middot; exported {6} by {7} v{8}</p></header>`n" -f (ConvertTo-HtmlText $title), (ConvertTo-HtmlText $where), (ConvertTo-HtmlText $machine), $project, $rows.Count, $(if ($Scope) { ' (' + (ConvertTo-HtmlText $Scope) + ')' } else { '' }), (ConvertTo-HtmlText ((Get-Date).ToString('d MMMM yyyy HH:mm'))), (ConvertTo-HtmlText $script:AppName), $script:AppVersion)
    & $add '<div class="chips">'
    foreach ($c in @(@('Running', $running), @('Stopped', ($rows.Count - $running)), @('Need a look', $problems), @('Changed', $changed), @('Newer image', $updates))) {
        & $add ('<div class="chip"><b>{0}</b>{1}</div>' -f $c[1], (ConvertTo-HtmlText $c[0]))
    }
    & $add "</div>`n"
    foreach ($g in @($rows | Group-Object { $_.GroupSort } | Sort-Object Name)) {
        $items = @($g.Group | Sort-Object Service)
        $gname = $items[0].Group
        $up = @($items | Where-Object IsRunning).Count
        & $add ("<section><h2><span class=""bar"" style=""background:{0}""></span>{1} <small>{2} of {3} running</small></h2>`n" -f (ConvertTo-HtmlText $items[0].GroupColor), (ConvertTo-HtmlText $gname), $up, $items.Count)
        & $add "<div class=""wrap""><table><thead><tr><th></th><th>Container</th><th>State</th><th>Since</th><th>Web page</th><th>Image</th><th>Source</th><th>Note</th></tr></thead><tbody>`n"
        foreach ($r in $items) {
            $dot = if ($r.Problem) { 'bad' } elseif ($r.IsRunning) { 'ok' } else { '' }
            $st = if ($dot) { $dot } else { 'off' }
            $icon = Get-IconDataUri $r
            $img = if ($icon) { "<img class=""ico"" alt="""" src=""$icon"">" } else { '' }
            $desc = if ($r.Description) { "<div class=""desc"">$(ConvertTo-HtmlText $r.Description)</div>" } else { '' }
            $url = Get-ShownUrl $r.Url
            $web = if ($url -match '^https?://') { "<a href=""$(ConvertTo-HtmlText $url)"">$(ConvertTo-HtmlText $(if ($r.Ports) { $r.Ports } else { 'open' }))</a>" } else { "<span class=""soft"">$(ConvertTo-HtmlText $r.Ports)</span>" }
            $src = Get-SourcePage $r
            $srcUrl = if ($src) { $src.Url } else { Get-GuessedSource $r.Image }
            $srcCell = if ($srcUrl) { "<a href=""$(ConvertTo-HtmlText $srcUrl)"">$(ConvertTo-HtmlText (($srcUrl -replace '^https?://(www\.)?', '') -replace '/$', ''))</a>" } else { '' }
            & $add ("<tr><td><span class=""dot {0}""></span></td><td>{1}<span class=""name"">{2}</span>{3}</td><td class=""st {4}"">{5}</td><td>{6}</td><td>{7}</td><td>{8}</td><td>{9}</td><td class=""note"">{10}</td></tr>`n" -f $dot, $img, (ConvertTo-HtmlText $r.Service), $desc, $st, (ConvertTo-HtmlText $r.StateText), (ConvertTo-HtmlText $r.Since), $web, (ConvertTo-HtmlText $r.Image), $srcCell, (ConvertTo-HtmlText $r.Note))
        }
        & $add "</tbody></table></div></section>`n"
    }
    & $add ("<footer>Made with {0} v{1}</footer>`n</div>`n</body>`n</html>`n" -f (ConvertTo-HtmlText $script:AppName), $script:AppVersion)
    # The theme setting, not the colours loaded at start, so a theme just changed in Settings is used.
    $mode = switch ([string]$script:Settings.Theme) { 'Light' { 'light' } 'Dark' { 'dark' } default { 'auto' } }
    return $sb.ToString().Replace('%THEME%', $mode)
}

function Export-List {
    if (-not $script:Rows.Count) { Set-Status 'There is nothing in the list to export yet.'; return }
    # The rows the list shows now (group, state filter and search), or all of them.
    $shown = @($script:View | Where-Object { $_ -is [Dcm.Row] })
    $rows = @($script:Rows)
    $scope = ''
    if ($shown.Count -and $shown.Count -lt $rows.Count) {
        $q = "Export only the $($shown.Count) container(s) the list shows now?`n`nYes: only those (the group, filter and search you picked).`nNo: all $($rows.Count) containers."
        $a = [Windows.MessageBox]::Show($window, $q, 'Export', 'YesNoCancel', 'Question')
        if ($a -eq 'Cancel') { return }
        if ($a -eq 'Yes') { $rows = $shown; $scope = 'the ones shown' }
    }
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Title = 'Export the list as a web page'
    $dlg.Filter = 'Web page (*.html)|*.html'
    $base = if ($script:ProjectName) { $script:ProjectName } else { 'containers' }
    $dlg.FileName = ('{0} containers {1}.html' -f $base, (Get-Date).ToString('yyyy-MM-dd')) -replace '[\\/:*?"<>|]', '-'
    $dlg.InitialDirectory = [Environment]::GetFolderPath('MyDocuments')
    if (-not $dlg.ShowDialog($window)) { return }
    try { [IO.File]::WriteAllText($dlg.FileName, (New-ExportHtml $rows $scope), (New-Object Text.UTF8Encoding $false)) }
    catch { [void][Windows.MessageBox]::Show($window, "Couldn't save the file: $($_.Exception.Message)", $script:AppName, 'OK', 'Error'); return }
    Write-Activity "Exported $($rows.Count) container(s) to $($dlg.FileName)"
    if ([Windows.MessageBox]::Show($window, "Saved $($dlg.FileName)`n`nOpen it in your browser now?", 'Export', 'YesNo', 'Question') -eq 'Yes') {
        try { Start-Process -FilePath $dlg.FileName } catch { Set-Status "Couldn't open $($dlg.FileName)" }
    }
}

# ---------------------------------------------------------------------------
# Help window (Help button or F1): topics on the left, the text on the right.
# A line starting with "- " is a bullet; "## " starts a small heading.
# ---------------------------------------------------------------------------
$script:HelpTopics = [ordered]@{
    'Getting started' = @(
        'Docker Container Manager runs the containers in a Docker Compose file (docker-compose.yml) and shows how each one is doing.',
        '- Press Compose file... and pick your docker-compose.yml. Next time the app opens the same file.',
        '- Pick a group on the left, or All containers.',
        '- Select one or more containers (Ctrl+click, Shift+click or Ctrl+A) and use the buttons above the list.',
        'Everything the app does is a normal docker command, listed with what Docker said in the Activity log at the bottom.',
        'To try it out safely, open docs\demo\docker-compose.yml from the app''s folder and press Start all.'
    )
    'The lists at the top' = @(
        '## Containers on',
        'Which computer''s Docker the app shows and controls: This PC, or another machine (a Linux laptop, a VM, a Synology NAS) reached over SSH. Machines... in this list adds or changes them.',
        '## Compose file',
        'The compose file on this PC that the app reads. Each machine remembers the file you last used with it.',
        'With another machine picked, the box reads Send from: that machine runs its own copy of the file, and the file here is the master copy. Send copies it across.'
    )
    'Groups and labels' = @(
        'Groups come from labels in the compose file, so they travel with the file:',
        '- home.group: the group a container is listed under. Without it, it''s under Ungrouped.',
        '- home.url: its web page (home.url=none hides the link). Without it, the first published port is used.',
        '- home.description: the tooltip in the list.',
        '- home.icon and home.color: its icon, and its group''s colour.',
        '- home.source: its source page (GitHub, GitLab and so on).',
        'The home part can be changed in Settings. Adding or changing a label marks the container Changed until you press Apply changes.'
    )
    'The list and cards' = @(
        'Each container shows a dot for its state, its name and icon, the state, how long it''s been up or down, its web page, its image and a note when something needs doing (for example Changed, or a newer image).',
        '- Cards (or Ctrl+T) switches between the list and cards; each card has start, stop, configure and logs buttons.',
        '- The box next to Search shows only running, stopped, problem, changed or updatable containers.',
        '- Search finds containers by name, image, group or port.',
        '- Groups on the left show how many are running, with a red dot when something in the group needs a look.',
        'The list is checked again every few seconds, and whenever the compose file or .env is saved.'
    )
    'Right-click menu' = @(
        'Right-click one or more containers for:',
        '- Start, Stop and Restart,',
        '- Update (download the newest image and recreate) and Recreate (make the container again from the compose file),',
        '- Configure, Logs, Open web page and Source page,',
        '- Copy name, and Edit source links (your own list of project pages),',
        '- Remove container: stops and deletes the container. Its image, volumes and data folders are kept, and Start makes it again.'
    )
    'Logs' = @(
        'Logs (Ctrl+L) opens a window with the selected container''s log. Several can be open at once.',
        '- Follow keeps showing new lines as they come.',
        '- Search, copy and save the log from the window.'
    )
    'Starting, stopping and updating' = @(
        '- Start creates the containers if needed and starts them (docker compose up -d).',
        '- Stop and Restart do what they say. Stopped containers keep their data.',
        '- Update downloads the newest image and recreates the container on it. Stopped ones stay stopped.',
        '- Start all, Stop all and Update all in the bar above the list work on the whole group (or everything, after asking).',
        '- Right-click a container for Recreate, Copy name, Source page and Remove container.',
        'Changed means the compose file says something different from the running container. Apply changes recreates those containers; their data in volumes and folders is kept.'
    )
    'Other machines and Send' = @(
        'Pick a machine in Containers on and every docker command runs there over SSH, using that machine''s copy of the compose file.',
        '- Machines... sets the SSH login, the folder with the compose file, the Env_ file to send as .env, and Portainer''s data folder.',
        '- SSH key help shows the one-time setup; Test connection checks it.',
        '- Send backs up the files on the machine, then copies your compose file (and the Env_ file as .env) there. Nothing restarts; press Apply changes afterwards.',
        '## The usual routine for a NAS',
        '- Pick the NAS in Containers on.',
        '- Edit the master copy on this PC (Edit, or Configure).',
        '- Press Send, then Apply changes.'
    )
    'Configure' = @(
        'Configure (Ctrl+E) shows a container''s settings from the compose file and .env: environment variables, API keys and passwords.',
        '- Change a value and press Save, or Save and recreate to use it straight away.',
        '- Values written in the compose file can be moved to .env, which is the safer place for passwords.',
        '- It also opens the container''s host folders, a shell inside it, its web page and its logs.',
        'Both files are backed up before anything is saved.'
    )
    'Check, Disk and updates' = @(
        '- Check finds mistakes in the compose file: spacing, ${...} variables, ports used twice, missing folders and more. Double-click a result to open the file at that line. Tidy spacing fixes the indents, and only saves when Docker reads the file the same.',
        '- Disk shows how much space images, containers, volumes and the build cache use, with buttons to clear what isn''t needed.',
        '- Check for updates asks each image''s registry whether a newer image is out, without downloading anything. Containers with one show a note, and the Updates available filter lists them.'
    )
    'Group automatically' = @(
        'When some containers have no group, the bar above the list shows Group automatically. It suggests a group for each one from its image name, reusing the groups already in your file.',
        '- Change any group, type a new one, or clear it to leave that container ungrouped.',
        '- Save groups adds one label line to each of them (after a backup) and changes nothing else. A Saving groups box shows each step; if one fails, the file is left as it was.',
        '- My groups (in Group automatically and Settings) is your own list of which group each container goes in, kept on this PC as my-groups.txt. Group automatically uses it first and only guesses the rest; the From column says which. Update from current compose file fills it from the labels you already have.',
        '- The containers then show Changed until you press Apply changes. On another machine, press Send first.'
    )
    'Portainer' = @(
        'The Portainer button works on the machine picked in Containers on:',
        '- Running: opens Portainer on port 9000.',
        '- Stopped: starts it, then opens it.',
        '- Not installed: asks for its data folder, shows the docker run line and asks before installing it.',
        'Right-click the button to update Portainer (keeping its data) or change its data folder. Portainer Business asks for its licence key in its own page; the app never sees or keeps it.'
    )
    'Source pages' = @(
        'Right-click a container and pick Source page (or press Source) to open its project page on GitHub, GitLab or Docker Hub. The app looks, in order, at:',
        '- a home.source label on the service,',
        '- your own source links (right-click > Edit source links, or the link in Settings). It''s a text file, source-links.txt, in the settings folder and stays on this PC: one "Name | address" per line,',
        '- the address the image itself names,',
        '- a guess from the image name.',
        'The Activity log says which page was opened and where it came from.'
    )
    'Export' = @(
        'Export... in the bar above the list saves the list as one web page (HTML): every group with its containers, icon, state, web page, image, source page and notes. When a group, filter or search is picked, it asks whether to save only the containers shown.',
        'The page uses the app''s theme (Light, Dark, or the browser''s setting for System), with a Light / dark switch at the top. It prints in light, has no scripts and needs no other files, so it can be kept or sent as it is.'
    )
    'Progress and the Finished box' = @(
        'While Docker works, the progress window shows what it says. Hide closes the window; the work carries on.',
        'If the progress window was hidden (or is turned off in Settings), a box in the bottom-right corner of the screen says when Docker has finished. Success closes itself after 10 seconds; a failure shows what went wrong, with Show log, and stays until it''s closed.'
    )
    'Keyboard shortcuts' = @(
        '- F1: this help',
        '- F5: read the compose file and status again',
        '- Ctrl+F: search',
        '- Ctrl+T: list or cards',
        '- Ctrl+E: configure the selected container',
        '- Ctrl+L: logs of the selected container',
        '- Enter or double-click: open the selected container''s web page',
        '- Ctrl+A: select everything; Esc: clear the search'
    )
    'Settings and files' = @(
        'Settings sets the label prefix, how often the status is checked, the editor (Check says whether it''s there and suggests one if not), the theme, the tray, app icons, update checks, the progress window and the Finished box.',
        '- Settings (settings.json), your source links (source-links.txt), My groups (my-groups.txt, with my-groups.bak.txt from the save before) and backups of the compose file and .env (Backups) are in %APPDATA%\Docker Container Manager.',
        '- Downloaded icons are in %LOCALAPPDATA%\Docker Container Manager\Icons.',
        'Nothing is installed: delete that folder to start again.'
    )
}

$helpXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Help" Width="940" Height="660" MinWidth="640" MinHeight="400" WindowStartupLocation="CenterOwner"
        FontFamily="Segoe UI" FontSize="13" Background="{DynamicResource Page}" Foreground="{DynamicResource Ink}">
    <Window.Resources><!--SHARED--></Window.Resources>
    <DockPanel Margin="14">
        <TextBlock DockPanel.Dock="Top" Text="Help" FontSize="18" FontWeight="SemiBold" Margin="0,0,0,10"/>
        <Grid DockPanel.Dock="Bottom" Margin="0,10,0,0">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                <TextBlock Text="More in the README: " Foreground="{StaticResource SoftInk}" VerticalAlignment="Center"/>
                <Button x:Name="BtnHelpReadme" Style="{StaticResource LinkBtn}" VerticalAlignment="Center"/>
            </StackPanel>
            <Button x:Name="BtnHelpClose" Grid.Column="1" Content="Close" Style="{StaticResource PrimaryBtn}" IsCancel="True" Margin="0"/>
        </Grid>
        <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="230"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <ListBox x:Name="LstHelp" ScrollViewer.HorizontalScrollBarVisibility="Disabled" Margin="0,0,12,0" Background="{StaticResource Card}" BorderBrush="{StaticResource Edge}" Foreground="{StaticResource Ink}" Padding="2,4"/>
            <Border Grid.Column="1" Background="{StaticResource Card}" BorderBrush="{StaticResource Edge}" BorderThickness="1" CornerRadius="8">
                <ScrollViewer x:Name="HelpScroll" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Padding="18,14">
                    <StackPanel x:Name="HelpBody"/>
                </ScrollViewer>
            </Border>
        </Grid>
    </DockPanel>
</Window>
'@

function Show-HelpTopic {
    $h = $script:HelpForm
    if (-not $h) { return }
    $topic = [string]$h.List.SelectedItem
    if (-not $topic) { return }
    $body = $h.Body
    $body.Children.Clear()
    $ink = $h.Window.FindResource('Ink')
    $prefix = [string]$script:Settings.LabelPrefix
    # Read-only text boxes, so the text can be selected and copied.
    $new = {
        param($Text, $Size, $Weight, $Margin)
        $tb = New-Object Windows.Controls.TextBox
        $tb.Text = $Text; $tb.IsReadOnly = $true; $tb.TextWrapping = 'Wrap'; $tb.BorderThickness = 0
        $tb.Background = [Windows.Media.Brushes]::Transparent; $tb.Foreground = $ink; $tb.Padding = '0'
        $tb.FontSize = $Size; $tb.FontWeight = $Weight; $tb.Margin = $Margin
        [void]$body.Children.Add($tb)
    }
    & $new $topic 17 'SemiBold' '0,0,0,10'
    foreach ($p in $script:HelpTopics[$topic]) {
        $text = $p -replace '\bhome\.', "$prefix."
        if ($text.StartsWith('## ')) { & $new $text.Substring(3) 13 'SemiBold' '0,6,0,4' }
        elseif ($text.StartsWith('- ')) { & $new ([string][char]0x2022 + '  ' + $text.Substring(2)) 13 'Normal' '10,0,0,6' }
        else { & $new $text 13 'Normal' '0,0,0,10' }
    }
    $h.Scroll.ScrollToTop()
}

function Show-Help([string]$Topic) {
    if ($script:HelpForm) {
        $script:HelpForm.Window.Activate() | Out-Null
        if ($Topic) { $script:HelpForm.List.SelectedItem = $Topic }
        return
    }
    $w = New-XamlObject $helpXaml
    $w.Owner = $window
    if ($window.Icon) { $w.Icon = $window.Icon }
    $h = @{ Window = $w; List = $w.FindName('LstHelp'); Body = $w.FindName('HelpBody'); Scroll = $w.FindName('HelpScroll') }
    foreach ($t in $script:HelpTopics.Keys) { [void]$h.List.Items.Add($t) }
    $readme = $w.FindName('BtnHelpReadme')
    $readme.Content = ($script:RepoUrl -replace '^https://', '') + '#readme'
    $readme.Add_Click({ try { Start-Process -FilePath ($script:RepoUrl + '#readme') } catch { Set-Status "Couldn't open $script:RepoUrl" } })
    $script:HelpForm = $h
    $h.List.Add_SelectionChanged({ Show-HelpTopic })
    $w.FindName('BtnHelpClose').Add_Click({ if ($script:HelpForm) { $script:HelpForm.Window.Close() } })
    $w.Add_Closed({ $script:HelpForm = $null })
    $h.List.SelectedItem = if ($Topic -and $script:HelpTopics.Contains($Topic)) { $Topic } else { @($script:HelpTopics.Keys)[0] }
    $w.Show()
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
foreach ($s in 'All', 'Running', 'Stopped', 'Problems', 'Changed', 'Updates available') { [void]$ui.CmbState.Items.Add($s) }
$ui.CmbState.SelectedIndex = 0
$ui.ChkActivity.IsChecked = [bool]$script:Settings.ShowActivity

$logo = Get-ImageSource 'Docker-Container-Manager.png'
if ($logo) { $ui.ImgLogo.Source = $logo; $window.Icon = $logo }

# The Activity log's height, as last left by the splitter (kept within sensible bounds).
function Get-LogHeight {
    $h = 221
    try { $h = [int]$script:Settings.LogHeight } catch { $h = 221 }
    [Math]::Min(900, [Math]::Max(60, $h))
}

function Set-ActivityVisible([bool]$Show) {
    if ($Show) {
        $ui.LogPane.Visibility = 'Visible'; $ui.LogSplitter.Visibility = 'Visible'
        if ($ui.LogRow.Height.Value -lt 60) { $ui.LogRow.Height = New-Object Windows.GridLength((Get-LogHeight)) }
    } else {
        $ui.LogPane.Visibility = 'Collapsed'; $ui.LogSplitter.Visibility = 'Collapsed'
        $ui.LogRow.Height = New-Object Windows.GridLength(0)
    }
}
$ui.LogRow.Height = New-Object Windows.GridLength((Get-LogHeight))
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
        if ($item -and $item.Tag -eq $script:OtherComposeTag) {
            # Once the list has closed: back to the current file (nothing is saved or
            # reloaded), then the picker. Cancel leaves the current file selected.
            [void]$window.Dispatcher.BeginInvoke([Action] { Update-RecentList; Select-ComposeFile }, [Windows.Threading.DispatcherPriority]::Background)
            return
        }
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
        $envFile = Get-ConfigureEnvPath
        if (-not (Test-Path -LiteralPath $envFile)) {
            if (-not (Confirm-Action "There's no .env next to the compose file. Create an empty one?")) { return }
            try { [IO.File]::WriteAllText($envFile, '') } catch { [void][Windows.MessageBox]::Show($window, $_.Exception.Message, $script:AppName); return }
        }
        Open-InEditor $envFile
    })
$ui.BtnFolder.Add_Click({ if ($script:ComposeDir -and (Test-Path -LiteralPath $script:ComposeDir)) { Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$script:ComposeDir`"" } })
$ui.BtnSend.Add_Click({ Invoke-SendToMachine })
$ui.CmbMachine.Add_SelectionChanged({
        if ($script:UpdatingMachines) { return }
        $item = $ui.CmbMachine.SelectedItem
        if (-not $item) { return }
        if ($item.Tag -eq '*edit*') { Update-MachineList; Show-Machines; return }
        if ([string]$item.Tag -ne [string]$script:Settings.Machine) { Set-Machine ([string]$item.Tag) }
    })
$ui.BtnCheck.Add_Click({ Show-Check })
$ui.BtnDisk.Add_Click({ Show-Disk })
$ui.BtnSettings.Add_Click({ Show-Settings })
$ui.BtnAbout.Add_Click({ Show-About })
$ui.BannerAction.Add_Click({ if ($script:BannerClick) { & $script:BannerClick } })
$ui.BannerRetry.Add_Click({
        $script:DockerExe = Find-Docker
        $script:DockerState = if (Test-DockerReady) { 'unknown' } else { 'missing' }
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
        (Get-ListControl).UnselectAll()
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
$ui.BtnConfigure.Add_Click({ $sel = Get-SelectedRows; if ($sel.Count -eq 1) { Show-Configure $sel[0] } })
$ui.BtnLogs.Add_Click({ $sel = Get-SelectedRows; if ($sel.Count -eq 1) { Show-Logs $sel[0] } })
$ui.BtnOpen.Add_Click({ $sel = Get-SelectedRows; if ($sel.Count -eq 1) { Open-Url $sel[0].Url } })
$ui.BtnApply.Add_Click({ Invoke-ApplyChanges })
$ui.BtnGroupStart.Add_Click({ Invoke-GroupAction 'start' })
$ui.BtnGroupStop.Add_Click({ Invoke-GroupAction 'stop' })
$ui.BtnGroupUpdate.Add_Click({ Invoke-GroupAction 'update' })
$ui.BtnRemoveOrphans.Add_Click({ Invoke-GroupAction 'remove' })
$ui.BtnRefresh.Add_Click({ Request-ConfigLoad; $script:NextPoll = [DateTime]::MinValue })
$ui.BtnCheckUpdates.Add_Click({ Start-UpdateCheck })
$ui.BtnPortainer.Add_Click({ Invoke-Portainer })
$ui.BtnAutoGroup.Add_Click({ Show-AutoGroup })
$script:PortainerMenu = New-Object Windows.Controls.ContextMenu
foreach ($x in @(@('Open Portainer', 'open'), @('Update Portainer...', 'update'), @('Change data folder...', 'folder'))) {
    $mi = New-Object Windows.Controls.MenuItem
    $mi.Header = $x[0]
    $mi.Tag = $x[1]
    $mi.Add_Click({ param($s) Invoke-Portainer ([string]$s.Tag) })
    [void]$script:PortainerMenu.Items.Add($mi)
}
$ui.BtnPortainer.ContextMenu = $script:PortainerMenu
Set-MenuTheme $script:PortainerMenu $window
$ui.BtnView.Add_Click({ Set-ViewMode $(if ($script:Settings.ViewMode -eq 'Cards') { 'List' } else { 'Cards' }); Save-Settings })
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
            Open-RowDefault $dep.Item
        } catch {
            Write-Activity "Internal error (double-click): $($_.Exception.Message)"
        }
    })

# Double-click: the web page, or the logs if there's no web page.
function Open-RowDefault($Row) {
    if ($Row -isnot [Dcm.Row]) { return }
    # Open after the click has finished, so the list isn't mid-click when a window opens.
    $script:PendingOpen = $Row
    [void]$window.Dispatcher.BeginInvoke([Action] {
            $r = $script:PendingOpen; $script:PendingOpen = $null
            if (-not $r) { return }
            if ($r.HasUrl) { Open-Url $r.Url } elseif ($r.HasContainer) { Show-Logs $r }
        }, [Windows.Threading.DispatcherPriority]::Background)
}

# Cards: the buttons on each card, selection and double-click.
$ui.Cards.Add_SelectionChanged({ try { Update-SelectionButtons } catch { Write-Activity "Internal error (selection): $($_.Exception.Message)" } })
$ui.Cards.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent, [Windows.RoutedEventHandler] {
        param($s, $e)
        $src = $e.OriginalSource
        if ($src -isnot [Windows.Controls.Button]) { return }
        $e.Handled = $true
        try {
            $row = $src.DataContext
            if ($row -isnot [Dcm.Row]) { return }
            switch ([string]$src.CommandParameter) {
                'start'     { Invoke-Start @($row) }
                'stop'      { Invoke-Stop @($row) }
                'logs'      { Show-Logs $row }
                'configure' { Show-Configure $row }
                default     { if ($src.Tag) { Open-Url ([string]$src.Tag) } }
            }
        } catch { Write-Activity "Internal error (card): $($_.Exception.Message)" }
    })
$ui.Cards.Add_MouseDoubleClick({
        param($s, $e)
        try {
            $dep = $e.OriginalSource
            while ($dep -and -not ($dep -is [Windows.Controls.ListBoxItem])) {
                if ($dep -is [Windows.Controls.Primitives.ButtonBase] -or $dep -is [Windows.Controls.Primitives.ScrollBar]) { return }
                $dep = if ($dep -is [Windows.Media.Visual]) { [Windows.Media.VisualTreeHelper]::GetParent($dep) } else { [Windows.LogicalTreeHelper]::GetParent($dep) }
            }
            if ($dep) { Open-RowDefault $dep.DataContext }
        } catch { Write-Activity "Internal error (double-click): $($_.Exception.Message)" }
    })

# Context menu: enable what makes sense for the selection.
$ui.RowMenu.Add_Opened({
        $sel = Get-SelectedRows
        $ui.MnuStart.IsEnabled = ($sel.Count -gt 0)
        $ui.MnuStop.IsEnabled = (@($sel | Where-Object IsRunning).Count -gt 0)
        $ui.MnuRestart.IsEnabled = (@($sel | Where-Object HasContainer).Count -gt 0)
        $ui.MnuUpdate.IsEnabled = (@($sel | Where-Object InCompose).Count -gt 0)
        $ui.MnuRecreate.IsEnabled = (@($sel | Where-Object { $_.InCompose -and $_.HasContainer }).Count -gt 0)
        $ui.MnuConfigure.IsEnabled = ($sel.Count -eq 1 -and $sel[0].InCompose)
        $ui.MnuLogs.IsEnabled = ($sel.Count -eq 1 -and $sel[0].HasContainer)
        $ui.MnuOpen.IsEnabled = ($sel.Count -eq 1 -and $sel[0].HasUrl)
        $ui.MnuSource.IsEnabled = ($sel.Count -eq 1)
        $ui.MnuSource.ToolTip = if ($sel.Count -eq 1) { Get-SourceHint $sel[0] } else { $null }
        $ui.MnuCopy.IsEnabled = ($sel.Count -gt 0)
        $ui.MnuRemove.IsEnabled = (@($sel | Where-Object HasContainer).Count -gt 0)
    })
$ui.MnuStart.Add_Click({ Invoke-Start (Get-SelectedRows) })
$ui.MnuStop.Add_Click({ Invoke-Stop (Get-SelectedRows) })
$ui.MnuRestart.Add_Click({ Invoke-Restart (Get-SelectedRows) })
$ui.MnuUpdate.Add_Click({ Invoke-Update (Get-SelectedRows) })
$ui.MnuRecreate.Add_Click({ Invoke-Recreate (Get-SelectedRows) })
$ui.MnuConfigure.Add_Click({ $sel = Get-SelectedRows; if ($sel.Count -eq 1) { Show-Configure $sel[0] } })
$ui.MnuLogs.Add_Click({ $sel = Get-SelectedRows; if ($sel.Count -eq 1) { Show-Logs $sel[0] } })
$ui.MnuOpen.Add_Click({ $sel = Get-SelectedRows; if ($sel.Count -eq 1) { Open-Url $sel[0].Url } })
$ui.MnuCopy.Add_Click({ $names = @(Get-SelectedRows | ForEach-Object Service); if ($names.Count) { [Windows.Clipboard]::SetText($names -join "`r`n") } })
$ui.MnuRemove.Add_Click({ Invoke-Remove (Get-SelectedRows) })
$ui.MnuSource.Add_Click({ $sel = Get-SelectedRows; if ($sel.Count -eq 1) { Open-SourcePage $sel[0] } })
$ui.MnuSourceList.Add_Click({ Edit-SourceList })
$ui.BtnSource.Add_Click({ $sel = Get-SelectedRows; if ($sel.Count -eq 1) { Open-SourcePage $sel[0] } })
$ui.BtnExport.Add_Click({ Export-List })
$ui.BtnHelp.Add_Click({ Show-Help })

$window.Add_PreviewKeyDown({
        param($s, $e)
        $ctrl = ([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Control)
        if ($e.Key -eq 'F5') { Request-ConfigLoad; $script:NextPoll = [DateTime]::MinValue; $e.Handled = $true }
        elseif ($e.Key -eq 'F1') { Show-Help; $e.Handled = $true }
        elseif ($ctrl -and $e.Key -eq 'F') { [void]$ui.TxtSearch.Focus(); $ui.TxtSearch.SelectAll(); $e.Handled = $true }
        elseif ($ctrl -and $e.Key -eq 'E') { $sel = Get-SelectedRows; if ($sel.Count -eq 1) { Show-Configure $sel[0] }; $e.Handled = $true }
        elseif ($ctrl -and $e.Key -eq 'L') { $sel = Get-SelectedRows; if ($sel.Count -eq 1) { Show-Logs $sel[0] }; $e.Handled = $true }
        elseif ($ctrl -and $e.Key -eq 'T') { $ui.BtnView.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent))); $e.Handled = $true }
        elseif ($e.Key -eq 'Escape' -and $ui.TxtSearch.IsKeyboardFocusWithin) { $ui.TxtSearch.Clear(); [void](Get-ListControl).Focus(); $e.Handled = $true }
        elseif ($e.Key -eq 'Return' -and (Get-ListControl).IsKeyboardFocusWithin) { $sel = Get-SelectedRows; if ($sel.Count -eq 1) { Open-Url $sel[0].Url }; $e.Handled = $true }
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
        if ($ui.LogPane.Visibility -eq 'Visible' -and $ui.LogRow.ActualHeight -ge 60) { $script:Settings.LogHeight = [int]$ui.LogRow.ActualHeight }
        Save-Settings
        foreach ($lw in @($script:LogWindows)) { try { $lw.Window.Close() } catch { Write-Verbose 'Log window already closed.' } }
        foreach ($c in @($script:Calls)) { $c.Runner.Kill() }
        Stop-Background
    })

# DataGrid can squeeze its fixed columns if it is first measured before the
# window has its final size, and it never widens them again. Set them once
# the window is on screen.
$script:ColumnWidths = @($ui.Grid.Columns | ForEach-Object { $_.Width })
function Update-HeaderFit {
    # Wide enough for the header buttons on one line. The subtitle can grow after start-up (the compose
    # path arrives later), so this runs again whenever the title changes size. Each part is measured
    # unconstrained, because a wrapped WrapPanel reports the wrapped (narrower) size.
    try {
        $inf = New-Object Windows.Size([double]::PositiveInfinity, [double]::PositiveInfinity)
        $ui.CmbRecent.Width = 230
        $buttons = 0.0
        foreach ($c in $ui.HeaderButtons.Children) {
            if ($c.Visibility -ne 'Visible') { continue }
            $c.Measure($inf)
            $buttons += $c.DesiredSize.Width + $c.Margin.Left + $c.Margin.Right
        }
        $ui.HeaderTitle.Measure($inf)
        $ui.ImgLogo.Measure($inf)
        $title = $ui.HeaderTitle.DesiredSize.Width + $ui.HeaderTitle.Margin.Right
        $logo = $ui.ImgLogo.DesiredSize.Width + $ui.ImgLogo.Margin.Right
        $content = ([Windows.FrameworkElement]$window.Content).ActualWidth
        $chrome = if ($content -gt 0) { $window.ActualWidth - $content } else { 16 }
        $need = [Math]::Ceiling($logo + $title + $buttons + 32 + 8 + $chrome)
        $work = [Windows.SystemParameters]::WorkArea
        if ($need -gt $work.Width) {
            # Screen too narrow: give up some of the recent-files box before letting the buttons wrap.
            $cut = [Math]::Min($need - $work.Width, 230 - 130)
            $ui.CmbRecent.Width = 230 - $cut
            $need -= $cut
        }
        $window.MinWidth = [Math]::Min($need, $work.Width)
        if ($window.WindowState -eq 'Normal' -and $window.Width -lt $window.MinWidth) {
            $window.Width = $window.MinWidth
            if ($window.Left + $window.Width -gt $work.Right) { $window.Left = [Math]::Max($work.Left, $work.Right - $window.Width) }
        }
    } catch { Write-Verbose "Header width: $($_.Exception.Message)" }
}

$script:HeaderTitleWidth = 0.0
$ui.HeaderTitle.Add_SizeChanged({
        param($s, $e)
        if ([Math]::Abs($e.NewSize.Width - $script:HeaderTitleWidth) -lt 1) { return }
        $script:HeaderTitleWidth = $e.NewSize.Width
        if ($window.IsLoaded) { Update-HeaderFit }
    })

$window.Add_ContentRendered({
        Update-HeaderFit
    })

# Set the column widths again once the first rows are on screen. Before that the DataGrid
# leaves every column at its MinWidth and the * column (Image) never takes the spare width.
$script:ColumnsSet = $false
$ui.Grid.ItemContainerGenerator.Add_StatusChanged({
        if ($script:ColumnsSet -or $ui.Grid.Items.Count -eq 0) { return }
        if ($ui.Grid.ItemContainerGenerator.Status -ne [Windows.Controls.Primitives.GeneratorStatus]::ContainersGenerated) { return }
        $script:ColumnsSet = $true
        [void]$window.Dispatcher.BeginInvoke([Action] {
                for ($i = 0; $i -lt $ui.Grid.Columns.Count; $i++) {
                    $w = $script:ColumnWidths[$i]
                    $ui.Grid.Columns[$i].Width = New-Object Windows.Controls.DataGridLength($w.Value, $w.UnitType)
                }
            }, [Windows.Threading.DispatcherPriority]::ContextIdle)
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
            Update-Background
            Update-Jobs
            Update-ProgressWindow
            Update-FinishedWindow
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
            $active = ($script:CurrentJob -or $script:JobQueue.Count -or $script:Calls.Count -or $script:LogWindows.Count -or $script:ConfigWanted -or $script:BgTasks.Count)
            $ms = if ($active) { 200 } else { 1000 }
            if ($script:Timer.Interval.TotalMilliseconds -ne $ms) { $script:Timer.Interval = [TimeSpan]::FromMilliseconds($ms) }
        } catch {
            Write-Activity "Internal error: $($_.Exception.Message)"
        }
    })

# ---------------------------------------------------------------------------
# Machines: picker, Send to machine and the Machines window
# ---------------------------------------------------------------------------
function Update-MachineList {
    $script:UpdatingMachines = $true
    try {
        $ui.CmbMachine.Items.Clear()
        $all = @(@{ Name = 'This PC'; Tag = ''; Tip = 'Docker on this PC' }) + @($script:Settings.Machines | ForEach-Object { @{ Name = $_.Name; Tag = $_.Name; Tip = "$($_.Login):$($_.Folder)" } })
        foreach ($x in $all) {
            $item = New-Object Windows.Controls.ComboBoxItem
            $item.Content = $x.Name
            $item.Tag = $x.Tag
            $item.ToolTip = $x.Tip
            [void]$ui.CmbMachine.Items.Add($item)
            if ($x.Tag -eq [string]$script:Settings.Machine) { $ui.CmbMachine.SelectedItem = $item }
        }
        $edit = New-Object Windows.Controls.ComboBoxItem
        $edit.Content = 'Machines...'
        $edit.Tag = '*edit*'
        $edit.FontStyle = 'Italic'
        $edit.ToolTip = 'Add, change or remove machines'
        [void]$ui.CmbMachine.Items.Add($edit)
        $ui.BtnSend.Visibility = if (Get-Machine) { 'Visible' } else { 'Collapsed' }
        $ui.BtnSend.ToolTip = if (Get-Machine) { "Copy the compose file and $(if ((Get-Machine).EnvFile) { (Get-Machine).EnvFile + ' (as .env)' } else { 'nothing else' }) to $(Get-MachineName)" } else { '' }
    } finally {
        $script:UpdatingMachines = $false
    }
}

function Set-Machine([string]$Name) {
    if ($script:CurrentJob -or $script:JobQueue.Count) {
        [void][Windows.MessageBox]::Show($window, "Docker is still working on: $($script:CurrentJob.Label)`n`nSwitch machines when it has finished.", $script:AppName, 'OK', 'Information')
        Update-MachineList
        return
    }
    $script:Settings.Machine = $Name
    # Switch to the compose file this machine was last used with.
    $pick = Get-Machine
    $want = if ($pick) { [string]$pick.ComposeFile } else { [string]$script:Settings.ComposeFile }
    if ($want -and $want -ne $script:ComposePath -and (Test-Path -LiteralPath $want)) {
        foreach ($job in @($script:JobQueue.ToArray())) { Write-Activity "Cancelled (compose file changed): $($job.Label)" }
        $script:JobQueue.Clear()
        $script:ComposePath = $want
        $script:ComposeDir = Split-Path -Parent $want
        $script:Settings.RecentFiles = @(@($want) + @($script:Settings.RecentFiles | Where-Object { $_ -and $_ -ne $want }) | Select-Object -First 8)
        Write-Activity "Compose file: $want"
    } elseif ($pick -and -not $pick.ComposeFile -and $script:ComposePath) {
        $pick.ComposeFile = $script:ComposePath
    }
    Save-Settings
    Update-MachineList
    $script:ConfigGen++
    $script:ProjectName = ''
    $script:ConfigLoaded = $false
    $script:ConfigError = ''
    $script:RemoteError = ''
    $script:OldCompose = $false
    $script:DockerState = if (Test-DockerReady) { 'unknown' } else { 'missing' }
    $script:Rows.Clear()
    $script:RowIndex = @{}
    $script:LocalDigests = @{}
    $script:FileStamp = Get-FileStamp
    $script:NextPoll = [DateTime]::MinValue
    $m = Get-Machine
    Write-Activity $(if ($m) { "Machine: $($m.Name) ($($m.Login), folder $($m.Folder))" } else { 'Machine: This PC' })
    if ($script:ComposePath) { $ui.TxtSubtitle.Text = Get-ComposeDisplay; $ui.TxtSubtitle.ToolTip = $ui.TxtSubtitle.Text; $ui.TxtProject.Text = '' }
    Update-RecentList
    Update-Banner
    Update-Groups
    Update-View -Refilter
    Update-HeaderFit
    Request-ConfigLoad
    if ($script:DiskForm) { Update-DiskWindow }
}

# A copy of a file with Unix line endings and no BOM, for sending to Linux.
function New-SendCopy([string]$Path) {
    $dir = Join-Path ([IO.Path]::GetTempPath()) 'Docker Container Manager'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Get-ChildItem -LiteralPath $dir -Filter '*.send' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) } | Remove-Item -Force -ErrorAction SilentlyContinue
    $text = [IO.File]::ReadAllText($Path)
    if ($text.Length -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    $text = $text -replace "`r`n", "`n"
    $target = Join-Path $dir ([guid]::NewGuid().ToString('N') + '.send')
    [IO.File]::WriteAllText($target, $text, (New-Object Text.UTF8Encoding($false)))
    return $target
}

# Steps that back up the files on the machine, then copy the compose file and
# the machine's Env_ file (as .env) there. Returns nothing if a file is missing.
function Get-SendSteps($Machine) {
    if (-not $script:ComposePath -or -not (Test-Path -LiteralPath $script:ComposePath)) { return $null }
    $envPath = $null
    if ($Machine.EnvFile) {
        $envPath = Join-Path $script:ComposeDir $Machine.EnvFile
        if (-not (Test-Path -LiteralPath $envPath)) {
            [void][Windows.MessageBox]::Show($window, "$($Machine.EnvFile) isn't next to the compose file, so nothing was sent.`n`nCreate it, or pick another Env_ file for $($Machine.Name) in Machines.", $script:AppName, 'OK', 'Warning')
            return $null
        }
    }
    $name = [IO.Path]::GetFileName($script:ComposePath)
    $folder = ConvertTo-ShQuote $Machine.Folder
    $remoteCompose = ConvertTo-ShQuote ($Machine.Folder + '/' + $name)
    $tmpCompose = ConvertTo-ShQuote ($Machine.Folder + '/.' + $name + '.dcm-new')
    $backup = 'mkdir -p ' + $folder + ' && cd ' + $folder + ' && stamp=$(date +%Y-%m-%d_%H%M%S) && for f in ' + (ConvertTo-ShQuote $name) + ' .env; do if [ -f "$f" ]; then cp -p "$f" "$f.$stamp.bak"; fi; done'
    $steps = @(New-SshStep $Machine $backup "back up $name and .env in $($Machine.Folder)" $null)
    $steps += New-SshStep $Machine ('cat > ' + $tmpCompose + ' && mv ' + $tmpCompose + ' ' + $remoteCompose) "copy $name to $($Machine.Name)" (New-SendCopy $script:ComposePath)
    if ($envPath) {
        $remoteEnv = ConvertTo-ShQuote ($Machine.Folder + '/.env')
        $tmpEnv = ConvertTo-ShQuote ($Machine.Folder + '/.env.dcm-new')
        $steps += New-SshStep $Machine ('cat > ' + $tmpEnv + ' && mv ' + $tmpEnv + ' ' + $remoteEnv) "copy $($Machine.EnvFile) to $($Machine.Name) as .env" (New-SendCopy $envPath)
    }
    return $steps
}

function Invoke-SendToMachine {
    $m = Get-Machine
    if (-not $m) { return }
    $name = [IO.Path]::GetFileName($script:ComposePath)
    $lines = @("$name  ->  $($m.Folder)/$name")
    if ($m.EnvFile) { $lines += "$($m.EnvFile)  ->  $($m.Folder)/.env" }
    $msg = "Copy these to $($m.Name) ($($m.Login))?`n`n  " + ($lines -join "`n  ") + "`n`nThe files there now are kept as dated .bak copies first. Nothing is restarted: containers whose settings changed show Changed afterwards, and Apply changes recreates them."
    if (-not (Confirm-Action $msg)) { return }
    $steps = Get-SendSteps $m
    if (-not $steps) { return }
    Add-Job "Send to $($m.Name)" $steps -Reload
}

$machinesXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Machines" Width="760" SizeToContent="Height" ResizeMode="NoResize" WindowStartupLocation="CenterOwner"
        FontFamily="Segoe UI" FontSize="13" Background="{DynamicResource Page}" Foreground="{DynamicResource Ink}">
    <Window.Resources><!--SHARED--></Window.Resources>
    <StackPanel Margin="18">
        <TextBlock Text="Machines" FontSize="18" FontWeight="SemiBold" Margin="0,0,0,4"/>
        <TextBlock Foreground="{StaticResource SoftInk}" TextWrapping="Wrap" Margin="0,0,0,12"
                   Text="Other computers that run your compose file, such as a Linux laptop, a VM or a Synology NAS. The app reaches them with SSH and runs docker there. The compose file on this PC is the master: Send copies it, with the machine's Env_ file as .env, to the machine's folder."/>
        <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="200"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <DockPanel Margin="0,0,14,0">
                <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" Margin="0,8,0,0">
                    <Button x:Name="BtnAddMachine" Content="Add" Tag="&#xE710;" Style="{StaticResource Btn}"/>
                    <Button x:Name="BtnRemoveMachine" Content="Remove" Tag="&#xE74D;" Style="{StaticResource Btn}" Margin="0"/>
                </StackPanel>
                <ListBox x:Name="LstMachines" MinHeight="250" Background="{StaticResource Card}" BorderBrush="{StaticResource Edge}" Foreground="{StaticResource Ink}"/>
            </DockPanel>
            <Border Grid.Column="1" Background="{StaticResource Card}" BorderBrush="{StaticResource Edge}" BorderThickness="1" CornerRadius="8" Padding="14">
                <Grid x:Name="MachineForm">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="130"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>
                    <TextBlock Text="Name" VerticalAlignment="Center" Margin="0,0,0,8"/>
                    <TextBox x:Name="TxtMName" Grid.Column="1" Style="{StaticResource Field}" Margin="0,0,0,8" ToolTip="Shown in the list at the top, for example NAS"/>
                    <TextBlock Grid.Row="1" Text="SSH login" VerticalAlignment="Center" Margin="0,0,0,8"/>
                    <Grid Grid.Row="1" Grid.Column="1" Margin="0,0,0,8">
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="70"/></Grid.ColumnDefinitions>
                        <TextBox x:Name="TxtMLogin" Style="{StaticResource Field}" ToolTip="user@address, for example admin@192.168.0.10"/>
                        <TextBlock Grid.Column="1" Text="port" VerticalAlignment="Center" Margin="8,0,6,0" Foreground="{StaticResource SoftInk}"/>
                        <TextBox x:Name="TxtMPort" Grid.Column="2" Style="{StaticResource Field}" ToolTip="Leave empty for 22"/>
                    </Grid>
                    <TextBlock Grid.Row="2" Text="Compose folder" VerticalAlignment="Center" Margin="0,0,0,8"/>
                    <TextBox x:Name="TxtMFolder" Grid.Row="2" Grid.Column="1" Style="{StaticResource Field}" Margin="0,0,0,8"
                             ToolTip="The full path of the folder on that machine that holds the compose file and .env, for example /volume1/docker"/>
                    <TextBlock Grid.Row="3" Text=".env comes from" VerticalAlignment="Center" Margin="0,0,0,8"/>
                    <Grid Grid.Row="3" Grid.Column="1" Margin="0,0,0,8">
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="120"/></Grid.ColumnDefinitions>
                        <ComboBox x:Name="CmbMEnv" VerticalContentAlignment="Center"
                                  ToolTip="The Env_ file next to your compose file that Send copies to the machine as .env"/>
                        <TextBlock Grid.Column="1" Text="project" VerticalAlignment="Center" Margin="8,0,6,0" Foreground="{StaticResource SoftInk}"/>
                        <TextBox x:Name="TxtMProject" Grid.Column="2" Style="{StaticResource Field}"
                                 ToolTip="The compose project name the containers were started with there (Test connection lists them). Empty uses the folder's name"/>
                    </Grid>
                    <TextBlock Grid.Row="4" Text="Docker command" VerticalAlignment="Center" Margin="0,0,0,8"/>
                    <TextBox x:Name="TxtMDocker" Grid.Row="4" Grid.Column="1" Style="{StaticResource Field}" Margin="0,0,0,8"
                             ToolTip="Usually docker (the app also looks in /usr/local/bin, where Synology keeps it)"/>
                    <TextBlock Grid.Row="5" Text="Web pages on" VerticalAlignment="Center" Margin="0,0,0,8"/>
                    <TextBox x:Name="TxtMWeb" Grid.Row="5" Grid.Column="1" Style="{StaticResource Field}" Margin="0,0,0,8"
                             ToolTip="The address used instead of localhost for web pages. Leave empty to use the SSH address"/>
                    <TextBlock Grid.Row="6" Text="Portainer data" VerticalAlignment="Center" Margin="0,0,0,8"/>
                    <TextBox x:Name="TxtMPortainer" Grid.Row="6" Grid.Column="1" Style="{StaticResource Field}" Margin="0,0,0,8"
                             ToolTip="The folder on that machine where Portainer keeps its data (mounted as /data), for example /volume1/docker/portainer. Asked for the first time you install Portainer there"/>
                    <StackPanel Grid.Row="7" Grid.ColumnSpan="2" Orientation="Horizontal" Margin="0,4,0,0">
                        <Button x:Name="BtnTestMachine" Content="Test connection" Tag="&#xE703;" Style="{StaticResource Btn}"/>
                        <Button x:Name="BtnKeyHelp" Content="SSH key help" Tag="&#xE8D7;" Style="{StaticResource Btn}" Margin="0"/>
                    </StackPanel>
                    <TextBlock x:Name="TxtMTest" Grid.Row="8" Grid.ColumnSpan="2" TextWrapping="Wrap" Margin="0,10,0,0" Foreground="{StaticResource SoftInk}"/>
                </Grid>
            </Border>
        </Grid>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
            <Button x:Name="BtnSaveMachines" Content="Save" Tag="&#xE74E;" Style="{StaticResource PrimaryBtn}" IsDefault="True"/>
            <Button x:Name="BtnCancelMachines" Content="Cancel" Style="{StaticResource Btn}" IsCancel="True" Margin="0"/>
        </StackPanel>
    </StackPanel>
</Window>
'@

function Get-MachineFormValues {
    $f = $script:MachinesForm
    return [ordered]@{
        Name = $f.TxtMName.Text.Trim(); Login = $f.TxtMLogin.Text.Trim(); Port = $f.TxtMPort.Text.Trim()
        Folder = $f.TxtMFolder.Text.Trim().TrimEnd('/'); Project = $f.TxtMProject.Text.Trim().ToLowerInvariant(); EnvFile = $(if ($f.CmbMEnv.SelectedIndex -gt 0) { [string]$f.CmbMEnv.SelectedItem } else { '' })
        Docker = $(if ($f.TxtMDocker.Text.Trim()) { $f.TxtMDocker.Text.Trim() } else { 'docker' }); WebHost = $f.TxtMWeb.Text.Trim()
        Portainer = $f.TxtMPortainer.Text.Trim().TrimEnd('/')
    }
}

# Copies the form into the selected machine (the list keeps working copies until Save).
function Save-MachineForm {
    $f = $script:MachinesForm
    if ($f.Loading -or $f.Current -lt 0 -or $f.Current -ge $f.List.Count) { return }
    $keep = $f.List[$f.Current].ComposeFile
    $f.List[$f.Current] = Get-MachineFormValues
    $f.List[$f.Current].ComposeFile = [string]$keep
    $label = if ($f.List[$f.Current].Name) { $f.List[$f.Current].Name } else { '(new machine)' }
    if ([string]$f.LstMachines.Items[$f.Current] -ne $label) {
        $sel = $f.LstMachines.SelectedIndex
        $f.Loading = $true
        $f.LstMachines.Items[$f.Current] = $label
        $f.LstMachines.SelectedIndex = $sel
        $f.Loading = $false
    }
}

function Show-MachineForm {
    $f = $script:MachinesForm
    $f.Loading = $true
    $i = $f.LstMachines.SelectedIndex
    $f.Current = $i
    $has = ($i -ge 0)
    $f.MachineForm.IsEnabled = $has
    $f.BtnRemoveMachine.IsEnabled = $has
    $m = if ($has) { $f.List[$i] } else { [ordered]@{ Name = ''; Login = ''; Port = ''; Folder = ''; Project = ''; EnvFile = ''; Docker = 'docker'; WebHost = '' } }
    $f.TxtMName.Text = $m.Name; $f.TxtMLogin.Text = $m.Login; $f.TxtMPort.Text = $m.Port; $f.TxtMFolder.Text = $m.Folder; $f.TxtMProject.Text = [string]$m.Project
    $f.TxtMDocker.Text = $m.Docker; $f.TxtMWeb.Text = $m.WebHost; $f.TxtMPortainer.Text = [string]$m.Portainer
    $f.CmbMEnv.SelectedIndex = 0
    if ($m.EnvFile) {
        if (-not $f.CmbMEnv.Items.Contains($m.EnvFile)) { [void]$f.CmbMEnv.Items.Add($m.EnvFile) }
        $f.CmbMEnv.SelectedItem = $m.EnvFile
    }
    $f.TxtMTest.Text = ''
    $f.Loading = $false
}

function Test-MachineValues($m, [object[]]$All) {
    if (-not $m.Name) { return 'Give each machine a name.' }
    if ($m.Name -eq 'This PC') { return "'This PC' is taken. Pick another name." }
    if (@($All | Where-Object { $_.Name -eq $m.Name }).Count -gt 1) { return "Two machines are called $($m.Name)." }
    if ($m.Login -notmatch '^[^\s@]+@[^\s@]+$') { return "$($m.Name): SSH login should look like user@address." }
    if ($m.Port -and ($m.Port -notmatch '^\d+$' -or [int]$m.Port -lt 1 -or [int]$m.Port -gt 65535)) { return "$($m.Name): the port is a number from 1 to 65535." }
    if ($m.Folder -notmatch '^/') { return "$($m.Name): Compose folder is the full path on that machine, starting with /, for example /volume1/docker." }
    if ($m.Project -and $m.Project -notmatch '^[a-z0-9][a-z0-9_-]*$') { return "$($m.Name): the project name uses lower-case letters, numbers, - and _." }
    if ($m.Docker -match '[;&|`$<>]') { return "$($m.Name): Docker command should be a program path such as /usr/local/bin/docker." }
    if ($m.Portainer -and ($m.Portainer -notmatch '^/' -or $m.Portainer -match '[;&|`$<>"'']')) { return "$($m.Name): Portainer data is the full path of a folder on that machine, starting with /, for example /volume1/docker/portainer." }
    return ''
}

function Show-Machines {
    $w = New-XamlObject $machinesXaml
    $w.Owner = $window
    if ($window.Icon) { $w.Icon = $window.Icon }
    $f = @{ Window = $w; Loading = $false; Current = -1; List = (New-Object System.Collections.ArrayList); TestRunner = $null; TestTimer = $null }
    foreach ($n in 'LstMachines', 'BtnAddMachine', 'BtnRemoveMachine', 'MachineForm', 'TxtMName', 'TxtMLogin', 'TxtMPort', 'TxtMFolder', 'TxtMProject', 'CmbMEnv', 'TxtMDocker', 'TxtMWeb', 'TxtMPortainer',
        'BtnTestMachine', 'BtnKeyHelp', 'TxtMTest', 'BtnSaveMachines') { $f[$n] = $w.FindName($n) }
    $script:MachinesForm = $f
    [void]$f.CmbMEnv.Items.Add('(leave .env as it is)')
    if ($script:ComposeDir) { foreach ($t in @(Get-ChildItem -LiteralPath $script:ComposeDir -Filter 'Env_*' -File -ErrorAction SilentlyContinue)) { [void]$f.CmbMEnv.Items.Add($t.Name) } }
    foreach ($m in @($script:Settings.Machines)) {
        $copy = [ordered]@{}
        foreach ($k in $m.Keys) { $copy[$k] = $m[$k] }
        [void]$f.List.Add($copy)
        [void]$f.LstMachines.Items.Add($m.Name)
    }
    $f.LstMachines.Add_SelectionChanged({ $f = $script:MachinesForm; if ($f.Loading) { return }; Save-MachineForm; Show-MachineForm })
    foreach ($n in 'TxtMName', 'TxtMLogin', 'TxtMPort', 'TxtMFolder', 'TxtMProject', 'TxtMDocker', 'TxtMWeb', 'TxtMPortainer') { $f[$n].Add_TextChanged({ Save-MachineForm }) }
    $f.CmbMEnv.Add_SelectionChanged({ Save-MachineForm })
    $f.BtnAddMachine.Add_Click({
            $f = $script:MachinesForm
            Save-MachineForm
            $pick = @($f.CmbMEnv.Items | Where-Object { $_ -match '^Env_' } | Select-Object -First 1)
            [void]$f.List.Add([ordered]@{ Name = ''; Login = ''; Port = ''; Folder = ''; Project = ''; EnvFile = $(if ($pick.Count) { [string]$pick[0] } else { '' }); Docker = 'docker'; WebHost = '' })
            [void]$f.LstMachines.Items.Add('(new machine)')
            $f.LstMachines.SelectedIndex = $f.List.Count - 1
            [void]$f.TxtMName.Focus()
        })
    $f.BtnRemoveMachine.Add_Click({
            $f = $script:MachinesForm
            $i = $f.LstMachines.SelectedIndex
            if ($i -lt 0) { return }
            $f.Loading = $true
            $f.List.RemoveAt($i)
            $f.LstMachines.Items.RemoveAt($i)
            $f.Current = -1
            $f.Loading = $false
            $f.LstMachines.SelectedIndex = [Math]::Min($i, $f.List.Count - 1)
            Show-MachineForm
        })
    $f.BtnKeyHelp.Add_Click({
            $f = $script:MachinesForm
            $m = Get-MachineFormValues
            $login = if ($m.Login) { $m.Login } else { 'user@address' }
            $port = if ($m.Port) { " -p $($m.Port)" } else { '' }
            $text = "The app signs in with an SSH key, so it never asks for a password. Set one up once:`n`n" +
            "1. In PowerShell on this PC, make a key (press Enter at each question):`n     ssh-keygen -t ed25519`n`n" +
            "2. Copy it to the machine (type that machine's password once):`n     type `$env:USERPROFILE\.ssh\id_ed25519.pub | ssh$port $login `"mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys`"`n`n" +
            "3. Press Test connection.`n`n" +
            "Synology: turn on SSH in Control Panel > Terminal & SNMP, turn on the user home service in Control Panel > User & Group > Advanced, and use an administrator account. If Test says permission denied for docker, run once on the NAS: sudo synogroup --add docker <your user>, then sudo chown root:docker /var/run/docker.sock.`n`n" +
            "This text has been copied to the clipboard."
            try { [Windows.Clipboard]::SetText($text) } catch { Write-Verbose 'Clipboard busy.' }
            [void][Windows.MessageBox]::Show($f.Window, $text, 'SSH key help', 'OK', 'Information')
        })
    $f.BtnTestMachine.Add_Click({
            $f = $script:MachinesForm
            $m = Get-MachineFormValues
            $problem = Test-MachineValues $m @($m)
            if ($problem) { $f.TxtMTest.Text = $problem; return }
            $ssh = Find-Ssh
            if (-not $ssh) { $f.TxtMTest.Text = "ssh.exe wasn't found. Turn on the OpenSSH Client in Windows Settings > System > Optional features."; return }
            if ($f.TestRunner) { $f.TestRunner.Kill() }
            $d = $m.Docker
            $file = if ($script:ComposePath) { [IO.Path]::GetFileName($script:ComposePath) } else { 'docker-compose.yml' }
            $cmd = (Get-RemotePathPrefix) + $d + " version --format 'engine {{.Server.Version}}' && " + $d + " compose version --short && if [ -f " + (ConvertTo-ShQuote ($m.Folder + '/' + $file)) + " ]; then echo 'compose file: found'; else echo 'compose file: not there yet (use Send)'; fi && if [ -f " + (ConvertTo-ShQuote ($m.Folder + '/.env')) + " ]; then echo '.env: found'; else echo '.env: not there yet'; fi" + '; echo running projects: $(' + $d + ' ps --format ''{{.Label "com.docker.compose.project"}}'' | sort | uniq -c | tr -s '' '' | tr ''\n'' '','')'
            $f.TxtMTest.Text = "Connecting to $($m.Login)..."
            try { $f.TestRunner = New-Object Dcm.Runner($ssh, [string[]](@(Get-SshArguments $m) + @($cmd)), $env:USERPROFILE, $true) }
            catch { $f.TxtMTest.Text = "Couldn't start ssh: $($_.Exception.Message)"; return }
            $f.TestStarted = [DateTime]::Now
            if (-not $f.TestTimer) {
                $f.TestTimer = New-Object Windows.Threading.DispatcherTimer
                $f.TestTimer.Interval = [TimeSpan]::FromMilliseconds(250)
                $f.TestTimer.Add_Tick({
                        $f = $script:MachinesForm
                        if (-not $f -or -not $f.TestRunner) { $this.Stop(); return }
                        $r = $f.TestRunner
                        if (-not $r.IsDone) {
                            if (([DateTime]::Now - $f.TestStarted).TotalSeconds -gt 30) { $r.Kill(); $f.TestRunner = $null; $f.TxtMTest.Text = 'No answer after 30 seconds.' }
                            return
                        }
                        $f.TestRunner = $null
                        $out = (($r.Output -split "`r?`n") | Where-Object { $_.Trim() }) -join '   ·   '
                        if ($r.ExitCode -eq 0) { $f.TxtMTest.Text = "Connected. Docker $out" }
                        else {
                            $err = Get-FirstLines $r.Error 3
                            $hint = if ($err -match 'Permission denied \(publickey') { ' The SSH key isn''t set up for this user yet: see SSH key help.' }
                            elseif ($err -match 'permission denied.*docker\.sock') { ' This user isn''t allowed to use Docker: see SSH key help.' }
                            elseif ($err -match 'not found') { ' Docker wasn''t found: try /usr/local/bin/docker as the Docker command.' }
                            else { '' }
                            $f.TxtMTest.Text = "Didn't work (exit code $($r.ExitCode)): $err $out$hint"
                        }
                    })
            }
            $f.TestTimer.Start()
        })
    $f.BtnSaveMachines.Add_Click({
            $f = $script:MachinesForm
            Save-MachineForm
            $all = @($f.List)
            foreach ($m in $all) {
                $problem = Test-MachineValues $m $all
                if ($problem) { [void][Windows.MessageBox]::Show($f.Window, $problem, 'Machines', 'OK', 'Warning'); return }
            }
            $old = Get-Machine
            $script:Settings.Machines = @(foreach ($m in $all) { ConvertTo-Machine $m })
            $now = @($script:Settings.Machines | Where-Object { $old -and $_.Name -eq $old.Name })
            $f.Saved = $true
            $f.Window.Close()
            if ($old -and -not $now.Count) { Set-Machine '' }
            elseif ($old -and (($now[0] | ConvertTo-Json -Compress) -ne ($old | ConvertTo-Json -Compress))) { Set-Machine $old.Name }
            else { Save-Settings; Update-MachineList }
        })
    if ($f.List.Count) {
        $cur = [string]$script:Settings.Machine
        $idx = 0
        for ($i = 0; $i -lt $f.List.Count; $i++) { if ($f.List[$i].Name -eq $cur) { $idx = $i } }
        $f.LstMachines.SelectedIndex = $idx
    }
    Show-MachineForm
    [void]$w.ShowDialog()
    if ($f.TestRunner) { $f.TestRunner.Kill() }
    if ($f.TestTimer) { $f.TestTimer.Stop() }
    $script:MachinesForm = $null
    Update-MachineList
}

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
if (-not (Test-DockerReady)) { $script:DockerState = 'missing' }
try { $script:Tray = New-Tray } catch { $script:Tray = $null; Write-Verbose "No tray icon: $($_.Exception.Message)" }

Write-Activity "$script:AppName v$script:AppVersion"
# No My groups list yet? Start it from the built-in one (when the exe has one).
[void](Initialize-MyGroupsFile)
if ($script:DockerExe) { Write-Activity "Using $script:DockerExe" } else { Write-Activity "docker.exe wasn't found. Install Docker Desktop, then press Try again." }

Set-ViewMode $script:Settings.ViewMode
Read-UpdateCache

$startFile = if ($ComposeFile) { $ComposeFile } elseif ((Get-Machine) -and (Get-Machine).ComposeFile) { [string](Get-Machine).ComposeFile } else { [string]$script:Settings.ComposeFile }
Update-MachineList
if (Get-Machine) { Write-Activity "Machine: $(Get-MachineName) ($((Get-Machine).Login))" }
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
