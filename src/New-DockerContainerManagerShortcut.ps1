<#
.SYNOPSIS
    Makes (or refreshes) the Docker Container Manager shortcut, which starts Docker-Container-Manager.ps1 without a console window.

.DESCRIPTION
    Docker Container Manager has no exe: it's a PowerShell script. This makes a Windows shortcut (Docker Container Manager.lnk)
    that starts it hidden, with its icon, and with the same taskbar ID (AppUserModelID) the script
    sets for itself, so the taskbar button shows the tool's icon and a pinned button starts the tool.

    On Windows 11 the shortcut runs
        conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "...\Docker-Container-Manager.ps1"
    which opens no console window at all. On older Windows it runs powershell.exe -WindowStyle Hidden
    from a minimised shortcut instead (a console may flash for a moment).

    A shortcut can only hold a full path, so it's made on the PC that runs the tool: "Docker Container Manager.cmd"
    runs this script, and Build.cmd uses it for "Builds\Docker Container Manager.lnk" (what the Home Launcher starts).
    The execution-policy bypass applies to the tool's own run only; no Windows settings are changed.

.PARAMETER ShortcutPath
    Where to save the shortcut(s). Default: "Docker Container Manager.lnk" next to the script, and in the Start menu.

.PARAMETER Launch
    Start Docker Container Manager from the (first) shortcut afterwards.

.EXAMPLE
    .\New-DockerContainerManagerShortcut.ps1 -Launch
.NOTES
    Author:    Jason Rhodes
    Copyright: (c) 2026 Jason Rhodes - MIT licence (see LICENSE)
#>
[CmdletBinding()]
param(
    [string]$ScriptPath,
    [string]$IconPath,
    [string[]]$ShortcutPath,
    [string]$AppId = 'jason4bury.Docker-Container-Manager',
    [switch]$Launch
)

$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 leaves $PSScriptRoot empty in param() defaults when a script is run with
# powershell.exe -File (as the .cmd does), so the default script path is worked out here instead.
if (-not $ScriptPath) {
    $here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
    $ScriptPath = Join-Path $here 'Docker-Container-Manager.ps1'
}
$ScriptPath = (Resolve-Path -LiteralPath $ScriptPath).ProviderPath
$folder     = Split-Path -Parent $ScriptPath
if (-not $IconPath) {
    # A release folder has assets\ beside the script; the repo has it beside src\.
    $IconPath = @((Join-Path $folder 'assets\Docker-Container-Manager.ico'), (Join-Path (Split-Path -Parent $folder) 'assets\Docker-Container-Manager.ico')) |
        Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if (-not $ShortcutPath) {
    $ShortcutPath = @((Join-Path $folder 'Docker Container Manager.lnk'), (Join-Path ([Environment]::GetFolderPath('Programs')) 'Docker Container Manager.lnk'))
}

# Files from a downloaded zip carry the "from the internet" mark; clear it on the tool's own files.
Get-ChildItem -LiteralPath $folder -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue

if (-not ('HomeToolShortcut.Maker' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;

namespace HomeToolShortcut {
    [ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellLinkW {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder file, int cch, IntPtr fd, uint flags);
        void GetIDList(out IntPtr pidl);
        void SetIDList(IntPtr pidl);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder name, int cch);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string name);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder dir, int cch);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string dir);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder args, int cch);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string args);
        void GetHotkey(out short hotkey);
        void SetHotkey(short hotkey);
        void GetShowCmd(out int showCmd);
        void SetShowCmd(int showCmd);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path, int cch, out int index);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string path, int index);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string path, uint reserved);
        void Resolve(IntPtr hwnd, uint flags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string file);
    }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore {
        void GetCount(out uint count);
        void GetAt(uint index, out PropertyKey key);
        void GetValue(ref PropertyKey key, out PropVariant value);
        void SetValue(ref PropertyKey key, ref PropVariant value);
        void Commit();
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    struct PropertyKey { public Guid FormatId; public uint PropertyId; }

    [StructLayout(LayoutKind.Explicit)]
    struct PropVariant {
        [FieldOffset(0)] public ushort Type;
        [FieldOffset(8)] public IntPtr Pointer;
        [FieldOffset(16)] public IntPtr Spare;   // PROPVARIANT is 24 bytes on 64-bit
    }

    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    class ShellLink { }

    public static class Maker {
        public static void Save(string path, string target, string args, string workDir, string icon, string description, int showCmd, string appId) {
            IShellLinkW link = (IShellLinkW)new ShellLink();
            link.SetPath(target);
            link.SetArguments(args);
            link.SetWorkingDirectory(workDir);
            link.SetDescription(description);
            link.SetShowCmd(showCmd);
            if (!String.IsNullOrEmpty(icon)) link.SetIconLocation(icon, 0);

            // PKEY_AppUserModel_ID
            PropertyKey key = new PropertyKey { FormatId = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), PropertyId = 5 };
            PropVariant value = new PropVariant { Type = 31 /* VT_LPWSTR */, Pointer = Marshal.StringToCoTaskMemUni(appId) };
            try {
                IPropertyStore store = (IPropertyStore)link;
                store.SetValue(ref key, ref value);
                store.Commit();
            } finally {
                Marshal.FreeCoTaskMem(value.Pointer);
            }
            ((IPersistFile)link).Save(path, true);
            Marshal.FinalReleaseComObject(link);
        }
    }
}
'@
}

$ps      = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
$psArgs  = "-NoProfile -ExecutionPolicy Bypass -STA -File `"$ScriptPath`""
# conhost --headless (no console window at all) on Windows 11; hidden PowerShell before that.
if ([Environment]::OSVersion.Version.Build -ge 22000 -and (Test-Path -LiteralPath $conhost)) {
    $target = $conhost; $arguments = "--headless `"$ps`" $psArgs"; $showCmd = 1; $how = 'conhost --headless'
} else {
    $target = $ps; $arguments = "-WindowStyle Hidden $psArgs"; $showCmd = 7; $how = 'powershell -WindowStyle Hidden'
}

$made = @()
foreach ($p in $ShortcutPath) {
    $dir = Split-Path -Parent $p
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [HomeToolShortcut.Maker]::Save($p, $target, $arguments, $folder, [string]$IconPath,
        'Docker Container Manager: running and organising Docker Compose containers in groups, on this PC or over SSH', $showCmd, $AppId)
    Write-Output "Shortcut: $p ($how)"
    $made += $p
}

if ($Launch -and $made.Count) { Start-Process -FilePath $made[0] }
