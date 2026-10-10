# Omnitrack installer for Windows (DESIGN.md section 11.1).
#
# The download page's one-liner and the GUI installer (healthsync.iss) both run this script. It installs for the
# current user only (no administrator rights), keeps the app and your data in separate folders, and can be run
# again at any time: a second run repairs or updates the app and never touches your data.
#
#   powershell -ExecutionPolicy Bypass -File install.ps1                   latest release from the website
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Zip omnitrack-0.2.0.zip
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Root C:\temp\ot -Port 5799 -ServicePrefix OmniTest -NoBrowser
#   powershell -ExecutionPolicy Bypass -File install.ps1 -DryRun           print the plan, change nothing
#   powershell -ExecutionPolicy Bypass -c "irm https://jel0624.github.io/health-sync/install.ps1 | iex"
#
# Steps: preflight -> release zip (download + SHA256) -> unpack to src.new -> uv -> Python 3.12 -> stop the running
# app -> swap src -> uv sync -> shim + init -> services -> setup page -> state.json. Steps that can fail without a
# network or disk problem run before anything is stopped, so a failed download leaves the installed app untouched.
#
# Health Sync 0.1 (the app's name before 0.2.0, DESIGN.md 11.6) is moved over: its folders <X>\HealthSync\{app,data}
# become <X>\Omnitrack\{app,data} (-LegacyAppDir / -LegacyDataDir name other ones; its own updater passes the old
# folders as -AppDir / -DataDir, and "Health Sync" as -ServicePrefix, which becomes "Omnitrack"). The new app is
# installed first; then the old app is stopped, its tasks, Start-menu shortcuts and "Installed apps" entry removed,
# the data folder moved (a rename: nothing is copied), the sign-ins moved to the new keychain names, and the old app
# folder deleted. When the new version does not install or start, whatever of that was done is undone (its tasks
# back, its server started again when it ran, the data folder moved back) and the old app folder is kept. When both
# data folders exist the new one is used and the old one left as it is; with no Health Sync app as well, that is a
# normal install or update, not a move. Every run also points the settings back into the data folder when an
# earlier move stopped before it could (they still name the HealthSync folder, which no longer holds data).
#
# Port: without -Port the data folder's own port is kept (default 5710); when another program uses it, the next
# free one of 5710-5730 is taken and saved. An explicit -Port is used as given (the installer stops if it is busy).
# The script runs from the temp folder: the old app folder may be renamed only when no process stands in it.
# At the end it writes <Data>\run\installer-result.json (exit code, version, error line) for the setup page.
#
# Exit codes: 0 ok, 1 preflight, 2 download/verify, 3 uv/python, 4 install failed (previous version restored),
#             5 services failed (the app itself is installed).
#
# This file must stay plain ASCII: Windows PowerShell 5.1 reads scripts without a BOM in the ANSI code page.
[CmdletBinding()]
param(
    [string]$AppDir = "",            # default %LOCALAPPDATA%\Omnitrack\app
    [string]$DataDir = "",           # default %LOCALAPPDATA%\Omnitrack\data (HEALTHSYNC_HOME)
    [string]$Root = "",              # test sandbox: AppDir = <Root>\app, DataDir = <Root>\data
    [string]$Zip = "",               # release zip already on disk (GUI installer, updates, tests)
    [string]$Sha256 = "",            # optional expected SHA256 of -Zip
    [string]$UvExe = "",             # optional uv.exe to use instead of downloading it (tests)
    [string]$VersionUrl = "https://jel0624.github.io/health-sync/version.json",
    [int]$Port = 5710,               # see "Port" above
    [string]$ServicePrefix = "Omnitrack",
    [string]$StartMenuDir = "",      # where the one-line install puts its Start-menu shortcuts (tests: a sandbox)
    [string]$LegacyAppDir = "",      # a Health Sync 0.1 app folder to take over (Setup: the previous install's)
    [string]$LegacyDataDir = "",     # a Health Sync 0.1 data folder to move to -DataDir
    [switch]$NoShortcuts,            # no Start-menu shortcuts and no "Installed apps" entry
    [switch]$NoServices,             # do not register or start the background tasks
    [switch]$NoBrowser,              # do not open the setup page at the end
    [switch]$FromInstaller,          # run by the GUI installer (it opens the page and makes the shortcuts itself)
    [switch]$Update,                 # run by "omnitrack update" (logs to update.log, no page)
    [switch]$Relaunched,             # internal: the second half of an update that moves the data folder
    [int]$ParentPid = 0,             # internal: the first half, which this one waits for
    [int]$ServerWait = 90,          # seconds to wait for the new server to answer (tests: less)
    [switch]$DryRun                  # check and print the plan only
)

$script:HsLog = $null
$script:HsExit = 0
$script:HsSavedEnv = @{}
$script:HsTasks = @("Server", "Daily", "Memos")
$script:HsPortGiven = $PSBoundParameters.ContainsKey("Port")
$script:HsBound = @{}                  # the parameters as given (the second half of an update gets them again)
foreach ($k in $PSBoundParameters.Keys) { $script:HsBound[$k] = $PSBoundParameters[$k] }
$script:HsResult = $null             # where installer-result.json goes, once the data folder is known
$script:HsTarget = ""                # the version being installed
$script:HsApp = ""
$script:HsError = ""
$script:NewName = "Omnitrack"        # the app's name and folder name since 0.2.0
$script:OldFolder = "HealthSync"     # Health Sync 0.1's folder name: %LOCALAPPDATA%\HealthSync\{app,data}
$script:OldPrefix = "Health Sync"    # its service prefix and keychain name
$script:Mig = $null                  # the 0.1 install being moved over (see Invoke-Install)
$script:HsHadApp = $false            # an Omnitrack was installed in the app folder before this run


# ---------------------------------------------------------------- small helpers

function Say([string]$Message) {
    # one line to the console and to the install log
    Write-Host $Message
    if ($script:HsLog) {
        try {
            $line = "{0:yyyy-MM-dd HH:mm:ss}  {1}`r`n" -f (Get-Date), $Message
            [IO.File]::AppendAllText($script:HsLog, $line, (New-Object Text.UTF8Encoding $false))
        } catch { }
    }
}

function Step([string]$Message) {
    Say ""
    Say "==> $Message"
}

function Fail([int]$Code, [string]$Message) {
    # stop the install with one of the documented exit codes
    $e = New-Object System.Exception $Message
    $e.Data["hs_code"] = $Code
    throw $e
}

function Invoke-Logged([string]$Exe, [string[]]$Arguments) {
    # Runs a program, copies its output lines to the console and the log, returns its exit code.
    # stderr is merged in; "Continue" keeps PowerShell 5.1 from turning uv's progress lines into errors.
    $ErrorActionPreference = "Continue"
    if (-not (Test-Path -LiteralPath $Exe)) { Say "    missing: $Exe"; return 127 }
    & $Exe @Arguments 2>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) { $t = $_.Exception.Message } else { $t = "$_" }
        if ($t.Trim()) { Say ("    " + $t.TrimEnd()) }
    }
    return $LASTEXITCODE
}

function Set-ProcessEnv([hashtable]$Values) {
    # set environment variables for this process, remembering the old values for Restore-ProcessEnv
    foreach ($k in $Values.Keys) {
        if (-not $script:HsSavedEnv.ContainsKey($k)) {
            $script:HsSavedEnv[$k] = [Environment]::GetEnvironmentVariable($k, "Process")
        }
        [Environment]::SetEnvironmentVariable($k, $Values[$k], "Process")
    }
}

function Restore-ProcessEnv {
    # the one-liner may run inside the user's own PowerShell window: leave its environment as it was
    foreach ($k in $script:HsSavedEnv.Keys) {
        [Environment]::SetEnvironmentVariable($k, $script:HsSavedEnv[$k], "Process")
    }
    $script:HsSavedEnv = @{}
}

function Resolve-FullPath([string]$Path) {
    # absolute path relative to PowerShell's current location, no trailing backslash
    $p = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    return $p.TrimEnd("\")
}

function Test-Url([string]$Text) { return $Text -match "^https?://" }

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-RemoteFile([string]$Url, [string]$Dest) {
    # download (or copy, for a local path) to Dest through a .part file
    $part = "$Dest.part"
    if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force }
    if (Test-Url $Url) {
        Invoke-WebRequest -Uri $Url -OutFile $part -UseBasicParsing -TimeoutSec 900 `
            -Headers @{ "User-Agent" = "Omnitrack-Installer" }
    } else {
        Copy-Item -LiteralPath ($Url -replace "^file:///", "") -Destination $part -Force
    }
    Move-Item -LiteralPath $part -Destination $Dest -Force
}

function Get-JsonDocument([string]$Url) {
    if (Test-Url $Url) {
        $doc = Invoke-RestMethod -Uri $Url -UseBasicParsing -TimeoutSec 30 -Headers @{ "User-Agent" = "Omnitrack-Installer" }
        if ($doc -is [string]) { $doc = $doc | ConvertFrom-Json }     # served as text/plain
        return $doc
    }
    return (Get-Content -LiteralPath ($Url -replace "^file:///", "") -Raw | ConvertFrom-Json)
}

function Get-SrcVersion([string]$Src) {
    # __version__ from healthsync\__init__.py, "" when missing
    $init = Join-Path $Src "healthsync\__init__.py"
    if (-not (Test-Path -LiteralPath $init)) { return "" }
    $m = Select-String -LiteralPath $init -Pattern '^__version__\s*=\s*["'']([^"'']+)["'']' | Select-Object -First 1
    if ($m) { return $m.Matches[0].Groups[1].Value }
    return ""
}

function Get-UvVersion([string]$Exe) {
    if (-not (Test-Path -LiteralPath $Exe)) { return "" }
    try {
        $out = & $Exe --version 2>$null
        if ("$out" -match "^uv\s+(\S+)") { return $Matches[1] }
    } catch { }
    return ""
}

function Test-Ping([int]$PortNumber, [int]$TimeoutMs = 2000) {
    # $null when nothing answers; else the parsed /ping JSON (or a marker object for a foreign program)
    try {
        $req = [Net.HttpWebRequest]::Create("http://127.0.0.1:$PortNumber/ping")
        $req.Proxy = $null
        $req.Timeout = $TimeoutMs
        $req.ReadWriteTimeout = $TimeoutMs
        $resp = $req.GetResponse()
        try {
            $reader = New-Object IO.StreamReader($resp.GetResponseStream())
            $body = $reader.ReadToEnd()
        } finally { $resp.Close() }
        try { return ($body | ConvertFrom-Json) } catch { return [pscustomobject]@{ app = "other" } }
    } catch [Net.WebException] {
        if ($_.Exception.Response) { return [pscustomobject]@{ app = "other" } }
    } catch { }
    # nothing speaks HTTP: is the port taken by something else?
    $client = New-Object Net.Sockets.TcpClient
    try {
        $ar = $client.BeginConnect("127.0.0.1", $PortNumber, $null, $null)
        if ($ar.AsyncWaitHandle.WaitOne(1000) -and $client.Connected) { return [pscustomobject]@{ app = "other" } }
    } catch { } finally { $client.Close() }
    return $null
}

function Get-HomeId([string]$Path) {
    # same as the server's /ping "home": sha256(str(<Data>))[:12]
    $sha = [Security.Cryptography.SHA256]::Create()
    $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Path))
    return (-join ($bytes | ForEach-Object { $_.ToString("x2") })).Substring(0, 12)
}

function Get-AppProcesses([string]$App) {
    # processes started from the app folder (the server, a running sync or memo job)
    $prefix = $App + "\"
    return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ExecutablePath -and $_.ExecutablePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
    })
}

function Wait-AppStopped([string]$App, [int]$Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if ((Get-AppProcesses $App).Count -eq 0) { return }
        Start-Sleep -Milliseconds 500
    }
    foreach ($p in (Get-AppProcesses $App)) {
        Say "    ending $($p.Name) (pid $($p.ProcessId))"
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 1
}

function Rename-WithRetry([string]$Path, [string]$NewName) {
    # Explorer or an antivirus scan can hold a folder for a moment
    for ($i = 1; $i -le 10; $i++) {
        try { Rename-Item -LiteralPath $Path -NewName $NewName -ErrorAction Stop; return }
        catch { if ($i -eq 10) { throw } ; Start-Sleep -Milliseconds 700 }
    }
}

function Move-Folder([string]$From, [string]$To) {
    # a folder to another place on the same drive: one rename, nothing copied (retried like Rename-WithRetry)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $To) | Out-Null
    for ($i = 1; $i -le 10; $i++) {
        try { [IO.Directory]::Move($From, $To); return }
        catch { if ($i -eq 10) { throw } ; Start-Sleep -Milliseconds 700 }
    }
}

function Remove-Tree([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        # uv marks some cache and venv files read-only
        Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { -not $_.PSIsContainer -and $_.IsReadOnly } |
            ForEach-Object { try { $_.IsReadOnly = $false } catch { } }
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

function Get-TaskState([string]$Name) {
    # "Running", "Ready", ... or "" when the task does not exist (or cannot be read)
    try {
        $t = Get-ScheduledTask -TaskPath "\" -TaskName $Name -ErrorAction Stop
        return "$($t.State)"
    } catch { return "" }
}

function Get-TaskName([string]$Prefix, [string]$Name) {
    # the same name as services/windows.py: "<prefix> Server-<SID>" (the root task folder is shared by every
    # Windows account on the PC; the SID keeps two accounts' tasks apart)
    $sid = ""
    try { $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { }
    if ($sid) { return "$Prefix $Name-$sid" }
    return "$Prefix $Name"
}

function Get-HomeIdOf([string]$Py, [string]$RunPy, [string]$Data) {
    # the /ping "home" of a data folder as the app itself computes it (it resolves junctions and links, which this
    # script cannot), from `version --json`; $null when that app cannot run
    if (-not (Test-Path -LiteralPath $Py) -or -not (Test-Path -LiteralPath $RunPy)) { return $null }
    try {
        $out = & $Py $RunPy --home $Data version --json 2>$null
        $j = ($out | Out-String) | ConvertFrom-Json
        if ($j.home) { return [string]$j.home }
        if ($j.data_dir) { return Get-HomeId ([string]$j.data_dir) }
    } catch { }
    return $null
}

function Get-Saved([string]$Data, [string]$Key) {
    # one top-level value of <Data>\healthsync.json ($null when there is none)
    $p = Join-Path $Data "healthsync.json"
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json).$Key } catch { return $null }
}

function Get-SavedPort([string]$Data) {
    # the port in <Data>\healthsync.json (0 when there is none)
    try {
        $n = [int](Get-Saved $Data "port")
        if ($n -ge 1024 -and $n -le 65535) { return $n }
    } catch { }
    return 0
}

function Select-Port([int]$Wanted, [string[]]$MyHomes, [bool]$Strict) {
    # -> @{ Port = n; Ours = $true/$false }: the wanted port when it is free or this data folder's own server
    # answers there (or the Health Sync 0.1 server being moved over), else (unless -Port was given) the first such
    # port of 5710-5730
    $cands = @($Wanted)
    if (-not $Strict) { $cands += (5710..5730 | Where-Object { $_ -ne $Wanted }) }
    $homes = @($MyHomes | Where-Object { $_ })
    foreach ($p in $cands) {
        $ping = Test-Ping $p 5000          # a busy server (rebuilding pages) may be slow to answer
        if (-not $ping) { return @{ Port = $p; Ours = $false; Home = "" } }
        if ($ping.app -eq "healthsync" -and $homes -contains $ping.home) { return @{ Port = $p; Ours = $true; Home = "$($ping.home)" } }
        if ($p -eq $Wanted) {
            if ($ping.app -eq "healthsync") { Say "    note: port $p is used by another Omnitrack (another data folder or Windows account)" }
            else { Say "    note: port $p is used by another program" }
        }
        if ($Strict) { break }
    }
    return $null
}

function New-Shortcut([string]$Path, [string]$Target, [string]$Arguments, [string]$WorkDir, [string]$Icon, [string]$Comment) {
    $sh = New-Object -ComObject WScript.Shell
    $lnk = $sh.CreateShortcut($Path)
    $lnk.TargetPath = $Target
    $lnk.Arguments = $Arguments
    $lnk.WorkingDirectory = $WorkDir
    if ($Icon -and (Test-Path -LiteralPath $Icon)) { $lnk.IconLocation = "$Icon,0" }
    $lnk.Description = $Comment
    $lnk.Save()
}

function Write-Result([string]$Path, [string]$Mode, [int]$Code, [string]$Target, [string]$App, [string]$Message) {
    # <Data>\run\installer-result.json: the setup page shows whether an update installed or was rolled back
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
        $now = Get-SrcVersion (Join-Path $App "src")
        $doc = [ordered]@{ mode = $Mode; exit = $Code; version = $now; target = $Target; message = $Message
                           finished_at = (Get-Date).ToString("yyyy-MM-ddTHH:mm:sszzz") }
        [IO.File]::WriteAllText($Path, ($doc | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
    } catch { }
}

function Write-Shim([string]$App, [string]$Data, [bool]$CustomData) {
    # <App>\omnitrack.cmd runs the CLI with the app's own Python; --home only for a non-default data folder.
    # healthsync.cmd, the 0.1 name, does the same for scripts and habits that still use it.
    $homeArg = ""
    if ($CustomData) { $homeArg = " --home `"$Data`"" }
    $run = "`"%~dp0venv\Scripts\python.exe`" `"%~dp0src\run.py`"$homeArg %*`r`n"
    # cmd.exe reads batch files in the OEM code page
    $oem = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
    [IO.File]::WriteAllText((Join-Path $App "omnitrack.cmd"), "@echo off`r`nrem Omnitrack command line (written by install.ps1)`r`n$run", $oem)
    [IO.File]::WriteAllText((Join-Path $App "healthsync.cmd"), "@echo off`r`nrem Omnitrack command line under its 0.1 name (omnitrack.cmd is the same)`r`n$run", $oem)
}


# ---------------------------------------------------------------- Health Sync 0.1 (DESIGN.md 11.6)

function Get-RenamedPath([string]$Path) {
    # <X>\HealthSync\<leaf> -> <X>\Omnitrack\<leaf>: where Health Sync 0.1 kept its app and data folders
    $parent = Split-Path -Parent $Path
    if ($parent -and (Split-Path -Leaf $parent) -eq $script:OldFolder) {
        return Join-Path (Join-Path (Split-Path -Parent $parent) $script:NewName) (Split-Path -Leaf $Path)
    }
    return $Path
}

function Get-OldPath([string]$Path) {
    # <X>\Omnitrack\<leaf> -> <X>\HealthSync\<leaf> ("" for any other folder)
    $parent = Split-Path -Parent $Path
    if ($parent -and (Split-Path -Leaf $parent) -eq $script:NewName) {
        return Join-Path (Join-Path (Split-Path -Parent $parent) $script:OldFolder) (Split-Path -Leaf $Path)
    }
    return ""
}

function Test-AppFolder([string]$Path) {
    # an app folder made by install.ps1 or Setup (also one an earlier attempt left half removed)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    foreach ($m in "src\run.py", "state.json", "venv", "uv\uv.exe", "unins000.exe", "healthsync.cmd") {
        if (Test-Path -LiteralPath (Join-Path $Path $m)) { return $true }
    }
    return $false
}

function Test-DataFolder([string]$Path) {
    return [bool]($Path -and (Test-Path -LiteralPath (Join-Path $Path "healthsync.json")))
}

function Test-EmptyFolder([string]$Path) {
    return [bool]((Test-Path -LiteralPath $Path -PathType Container) -and
                  -not (Get-ChildItem -LiteralPath $Path -Force | Select-Object -First 1))
}

function Get-TasksOf([string]$App) {
    # the scheduled tasks whose program runs from an app folder, whatever their name
    $out = @()
    if (-not $App) { return $out }
    $prefix = $App.TrimEnd("\") + "\"
    foreach ($t in @(Get-ScheduledTask -TaskPath "\" -ErrorAction SilentlyContinue)) {
        foreach ($a in @($t.Actions)) {
            $exe = "$($a.Execute)".Trim().Trim('"')
            if ($exe.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { $out += $t; break }
        }
    }
    return $out
}

function Get-OldLaunchers([string]$OldApp, [string[]]$Dirs) {
    # Start-menu shortcuts that start the old app: the ones its state.json lists (a one-line install) and any .lnk in
    # the given folders whose target lies in the old app folder (Setup's own, which state.json does not list)
    $found = @()
    if (-not $OldApp) { return $found }
    try {
        $st = Get-Content -LiteralPath (Join-Path $OldApp "state.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($l in @($st.launchers)) { if ("$l".EndsWith(".lnk") -and (Test-Path -LiteralPath "$l")) { $found += "$l" } }
    } catch { }
    $sh = New-Object -ComObject WScript.Shell
    $prefix = $OldApp.TrimEnd("\") + "\"
    foreach ($d in @($Dirs | Where-Object { $_ } | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $d -Filter "*.lnk" -File -ErrorAction SilentlyContinue)) {
            try {
                if ($sh.CreateShortcut($f.FullName).TargetPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                    $found += $f.FullName
                }
            } catch { }
        }
    }
    return @($found | Select-Object -Unique)
}

function Get-OldUninstallKeys([string]$OldApp) {
    # "Installed apps" entries (HKCU) of the old app: a one-line install's and Setup's (InstallLocation / Inno's App Path)
    $out = @()
    if (-not $OldApp) { return $out }
    $root = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall"
    foreach ($k in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
        try {
            $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction Stop
            $loc = "$($p.InstallLocation)".TrimEnd("\")
            $inno = "$($p.'Inno Setup: App Path')".TrimEnd("\")
            if (($loc -and $loc -eq $OldApp) -or ($inno -and $inno -eq $OldApp)) { $out += $k }
        } catch { }
    }
    return $out
}

function Copy-OldState([string]$OldApp, [string]$StatePath) {
    # the new app folder inherits the old one's "extras" (the voice memo environment to keep in sync); shortcuts,
    # the "Installed apps" entry and the installer kind are recorded anew at the end
    if (Test-Path -LiteralPath $StatePath) { return @() }
    try {
        $st = Get-Content -LiteralPath (Join-Path $OldApp "state.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch { return @() }
    $extras = @($st.extras | Where-Object { $_ } | ForEach-Object { "$_" })
    $doc = [ordered]@{ extras = $extras }
    if ($st.installed_at) { $doc["installed_at"] = "$($st.installed_at)" }
    [IO.File]::WriteAllText($StatePath, ($doc | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
    return $extras
}

function Stop-OldApp {
    # stop Health Sync 0.1 and take its tasks off the scheduler (kept as XML, so Undo-Migration can put them back)
    $m = $script:Mig
    $m.Stopped = $true                     # from here on Undo-Migration has something to undo
    Step "Stopping Health Sync $($m.Version)"
    $oldPy = Join-Path $m.App "venv\Scripts\python.exe"
    $oldRun = Join-Path $m.App "src\run.py"
    if ($m.Data -and (Test-Path -LiteralPath $oldPy) -and (Test-Path -LiteralPath $oldRun)) {
        $null = Invoke-Logged $oldPy @($oldRun, "--home", $m.Data, "service", "stop")
    }
    foreach ($t in (Get-TasksOf $m.App)) {
        $entry = @{ Name = $t.TaskName; Running = ("$($t.State)" -eq "Running"); Xml = $null }
        try { $entry.Xml = Export-ScheduledTask -TaskPath "\" -TaskName $t.TaskName -ErrorAction Stop } catch { }
        try { Stop-ScheduledTask -TaskPath "\" -TaskName $t.TaskName -ErrorAction SilentlyContinue } catch { }
        try {
            Unregister-ScheduledTask -TaskPath "\" -TaskName $t.TaskName -Confirm:$false -ErrorAction Stop
            $m.Tasks += ,$entry
            Say "    removed the task '$($t.TaskName)'"
        } catch { Say "    note: could not remove the task '$($t.TaskName)': $($_.Exception.Message)" }
    }
    Wait-AppStopped $m.App 30
}

function Move-OldData([string]$Data, [string]$Py, [string]$Run) {
    # move the 0.1 data folder here (one rename), keep its config files as they were for Undo-Migration, and point
    # the paths in them at the new place
    $m = $script:Mig
    Step "Moving your data to $Data"
    if (Test-EmptyFolder $Data) { Remove-Item -LiteralPath $Data -Force }
    Move-Folder $m.Data $Data
    $m.Moved = $true
    $script:HsResult = Join-Path (Join-Path $Data "run") "installer-result.json"
    if ($script:HsLog) { $script:HsLog = Join-Path (Join-Path $Data "logs") (Split-Path -Leaf $script:HsLog) }
    Say "    moved $($m.Data) -> $Data"
    $keep = Join-Path $Data "run\pre-0.2"
    foreach ($rel in "healthsync.json", "activity-tracker\config.json", "google-health-sync\config.json", "voice-memos\config.json") {
        $f = Join-Path $Data $rel
        if (Test-Path -LiteralPath $f) {
            $dest = Join-Path $keep $rel
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
            Copy-Item -LiteralPath $f -Destination $dest -Force
        }
    }
    $rc = Invoke-Logged $Py @($Run, "--home", $Data, "migrate", "--moved-from", $m.Data)
    if ($rc -ne 0) { throw "omnitrack migrate --moved-from failed (exit $rc)" }
}

function Undo-Migration([string]$App, [string]$Data) {
    # the new version did not install or start: put back what this run changed of Health Sync 0.1 and nothing else.
    # The new version's tasks are removed (a previous version of this app folder gets its own back from the
    # caller), the data folder is moved back and its config files restored as they were, and the old tasks are
    # registered again; its server is started when it ran before (or its task was running)
    $m = $script:Mig
    if (-not $m -or -not $m.Stopped) { return }
    $m.Stopped = $false                     # once
    Step "Putting Health Sync $($m.Version) back"
    $py = Join-Path $App "venv\Scripts\python.exe"
    $run = Join-Path $App "src\run.py"
    if ($m.NewTasks -and (Test-Path -LiteralPath $py) -and (Test-Path -LiteralPath $run)) {
        $null = Invoke-Logged $py @($run, "--home", $Data, "service", "uninstall")
    }
    Wait-AppStopped $App 15
    if ($m.Moved) {
        # the folder first: when it cannot move back, its config files keep pointing where it is
        $logName = ""
        if ($script:HsLog) { $logName = Split-Path -Leaf $script:HsLog }
        $back = $false
        try { Move-Folder $Data $m.Data; $back = $true }
        catch { Say "    could not move your data back: $($_.Exception.Message) (it is in $Data)" }
        if ($back) {
            $m.Moved = $false
            $m.Undone = $true
            $script:HsResult = Join-Path (Join-Path $m.Data "run") "installer-result.json"
            if ($logName) { $script:HsLog = Join-Path (Join-Path $m.Data "logs") $logName }
            Say "    moved your data back to $($m.Data)"
            $keep = Join-Path $m.Data "run\pre-0.2"
            try {
                foreach ($rel in "healthsync.json", "activity-tracker\config.json", "google-health-sync\config.json", "voice-memos\config.json") {
                    $f = Join-Path $keep $rel
                    if (Test-Path -LiteralPath $f) { Copy-Item -LiteralPath $f -Destination (Join-Path $m.Data $rel) -Force }
                }
                Remove-Tree $keep
            } catch { Say "    note: the config files could not all be put back from $keep ($($_.Exception.Message))" }
        }
    }
    foreach ($t in $m.Tasks) {
        if (-not $t.Xml) { continue }
        try {
            Register-ScheduledTask -TaskPath "\" -TaskName $t.Name -Xml $t.Xml -Force -ErrorAction Stop | Out-Null
            $m.Undone = $true
            if ($t.Running -or ($m.WasUp -and $t.Name -like "* Server*")) {
                Start-ScheduledTask -TaskPath "\" -TaskName $t.Name -ErrorAction SilentlyContinue
            }
            Say "    restored the task '$($t.Name)'"
        } catch { Say "    could not restore the task '$($t.Name)': $($_.Exception.Message)" }
    }
    $m.Tasks = @()
}

function Get-RollbackNote {
    # the end of the error line after a failed install: what is back as it was
    $m = $script:Mig
    if ($m -and $m.Undone) {
        if ($m.App) { return "Health Sync $($m.Version) is back as it was; your data is where it was." }
        return "Your data is where it was."
    }
    if ($script:HsHadApp) { return "The previous version was restored." }
    return "Nothing else was changed; run the installer again after fixing the problem."
}

function Test-PointsInto([string]$Data, [string]$Old) {
    # does a config file of <Data> name a path inside Old (JSON writes \ as \\; / is accepted as well)
    $needles = @(($Old.TrimEnd("\") + "\").Replace("\", "\\"), ($Old.TrimEnd("\") + "\").Replace("\", "/"),
                 ('"' + $Old.TrimEnd("\").Replace("\", "\\") + '"'))
    foreach ($rel in "healthsync.json", "activity-tracker\config.json", "google-health-sync\config.json", "voice-memos\config.json") {
        $f = Join-Path $Data $rel
        if (-not (Test-Path -LiteralPath $f)) { continue }
        try { $text = [IO.File]::ReadAllText($f) } catch { continue }
        foreach ($n in $needles) { if ($text.IndexOf($n, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true } }
    }
    return $false
}

function Complete-Migration([string]$App, [string]$Data, [string]$MenuDir) {
    # the new version runs (and has the sign-ins): remove what is left of Health Sync 0.1 (shortcuts, its
    # "Installed apps" entry, the app folder, the HealthSync folder when nothing else is in it)
    $m = $script:Mig
    Remove-Tree (Join-Path $Data "run\pre-0.2")
    if (-not $m.App) { return }
    Step "Removing Health Sync $($m.Version)"
    foreach ($l in (Get-OldLaunchers $m.App @($MenuDir, [Environment]::GetFolderPath("Programs")))) {
        try { Remove-Item -LiteralPath $l -Force -ErrorAction Stop; Say "    removed the shortcut $(Split-Path -Leaf $l)" }
        catch { Say "    note: could not remove the shortcut ${l}: $($_.Exception.Message)" }
    }
    foreach ($k in (Get-OldUninstallKeys $m.App)) {
        # Setup is rewriting its own entry (same AppId) for the new folder: leave that one to it
        if ($FromInstaller -and $k.PSChildName -like "*_is1") { continue }
        try { Remove-Item -LiteralPath $k.PSPath -Recurse -Force -ErrorAction Stop; Say "    removed '$($k.PSChildName)' from Installed apps" }
        catch { Say "    note: could not remove the Installed apps entry $($k.PSChildName)" }
    }
    Wait-AppStopped $m.App 10
    try { Remove-Tree $m.App; Say "    deleted $($m.App)" }
    catch { Say "    note: could not delete $($m.App) yet ($($_.Exception.Message)); the next install tries again" }
    foreach ($parent in @(@($m.App, $m.DataWas) | Where-Object { $_ } | ForEach-Object { Split-Path -Parent $_ }) | Select-Object -Unique) {
        if ($parent -and (Split-Path -Leaf $parent) -eq $script:OldFolder -and (Test-EmptyFolder $parent)) {
            Remove-Item -LiteralPath $parent -Force -ErrorAction SilentlyContinue
            Say "    deleted the empty folder $parent"
        }
    }
}

function Start-SecondHalf {
    # Health Sync 0.1's updater gave this script its update.log, inside the data folder that is about to move, as
    # its output, and Windows cannot move a folder while a file in it is open. The install continues in a new
    # process that holds nothing open there (Start-Process inherits no handles); this one exits.
    $copy = Join-Path ([IO.Path]::GetTempPath()) ("omnitrack-install-{0}.ps1" -f $PID)
    Copy-Item -LiteralPath $PSCommandPath -Destination $copy -Force
    $argv = @("-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", "`"$copy`"")
    foreach ($k in $script:HsBound.Keys) {
        $v = $script:HsBound[$k]
        if ($v -is [System.Management.Automation.SwitchParameter]) { if ($v.IsPresent) { $argv += "-$k" } }
        else { $argv += @("-$k", ('"' + ("$v".TrimEnd("\")) + '"')) }
    }
    $argv += @("-Relaunched", "-ParentPid", "$PID")
    $ps = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $p = Start-Process -FilePath $ps -ArgumentList $argv -WindowStyle Hidden -WorkingDirectory ([IO.Path]::GetTempPath()) -PassThru
    Say "    the update continues in a new process (pid $($p.Id)); its log is update.log in the data folder"
}


# ---------------------------------------------------------------- the install

function Invoke-Install {
    $ErrorActionPreference = "Stop"
    $ProgressPreference = "SilentlyContinue"     # Invoke-WebRequest is many times slower with the progress bar
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

    # ---- folders and options
    $base = Join-Path $env:LOCALAPPDATA $script:NewName
    if ($Root) { $base = $Root }
    if ($AppDir) { $App = Resolve-FullPath $AppDir } else { $App = Resolve-FullPath (Join-Path $base "app") }
    if ($DataDir) { $Data = Resolve-FullPath $DataDir } else { $Data = Resolve-FullPath (Join-Path $base "data") }
    $Prefix = $ServicePrefix
    if ($Prefix -eq $script:OldPrefix) { $Prefix = $script:NewName }      # Health Sync 0.1's default name

    # Health Sync 0.1: its updater passes the old folders (they move to the Omnitrack names); otherwise the new
    # folders' HealthSync twins, or what Setup found (-Legacy*), are taken over when they hold an install
    $oldApp = ""
    $oldData = ""
    $r = Get-RenamedPath $App
    if ($r -ne $App) { $oldApp = $App; $App = $r }
    $r = Get-RenamedPath $Data
    if ($r -ne $Data) { $oldData = $Data; $Data = $r }
    if ($LegacyAppDir) { $oldApp = Resolve-FullPath $LegacyAppDir } elseif (-not $oldApp) { $oldApp = Get-OldPath $App }
    if ($LegacyDataDir) { $oldData = Resolve-FullPath $LegacyDataDir } elseif (-not $oldData) { $oldData = Get-OldPath $Data }
    if ($oldApp -and (($oldApp -eq $App) -or -not (Test-AppFolder $oldApp))) { $oldApp = "" }
    if ($oldData -and (($oldData -eq $Data) -or -not (Test-DataFolder $oldData))) { $oldData = "" }
    $moveData = [bool]($oldData -and -not (Test-DataFolder $Data))
    $staleData = ""
    if ($oldData -and -not $moveData -and -not $oldApp) {
        # a HealthSync data folder next to this one and no Health Sync app: nothing to move over, a normal install
        $staleData = $oldData
        $oldData = ""
    }
    if ($oldApp -or $moveData) {
        $oldPrefix = ""
        if ($oldData) { $oldPrefix = "$(Get-Saved $oldData 'service_prefix')" }
        elseif (Test-DataFolder $Data) { $oldPrefix = "$(Get-Saved $Data 'service_prefix')" }
        if ($oldPrefix -eq $Prefix) { $oldPrefix = "" }
        $oldVersion = "0.1"
        if ($oldApp) { $v = Get-SrcVersion (Join-Path $oldApp "src"); if ($v) { $oldVersion = $v } }
        # Stopped / Moved / Tasks: what this run changed of the 0.1 install (Undo-Migration puts back only that);
        # WasUp: its server answered when the install began; Undone: Undo-Migration put something back
        $script:Mig = @{ App = $oldApp; Data = $oldData; DataWas = $oldData; Prefix = $oldPrefix; Version = $oldVersion
                         MoveData = $moveData; Stopped = $false; Moved = $false; Tasks = @(); NewTasks = $false
                         WasUp = $false; Undone = $false }
    }

    $defaultData = Resolve-FullPath (Join-Path (Join-Path $env:LOCALAPPDATA $script:NewName) "data")
    $customData = -not [string]::Equals($Data, $defaultData, [StringComparison]::OrdinalIgnoreCase)
    $mode = "install"
    if ($Update) { $mode = "update" }
    # relative paths are resolved here, before the script moves to the temp folder
    $zipArg = ""
    if ($Zip) { $zipArg = Resolve-FullPath $Zip }
    $uvArg = ""
    if ($UvExe) { $uvArg = Resolve-FullPath $UvExe }
    $menuDir = [Environment]::GetFolderPath("Programs")
    if ($StartMenuDir) { $menuDir = Resolve-FullPath $StartMenuDir }
    # never stand in the app folder: its src folder is renamed below, and Windows refuses to rename a folder that a
    # process (this one) uses as its working folder
    Push-Location -LiteralPath ([IO.Path]::GetTempPath())
    $script:HsPushed = $true
    $script:HsApp = $App

    if ($Relaunched -and $ParentPid -gt 0) {
        # the first half must have exited (and closed update.log) before the data folder can move
        try { Wait-Process -Id $ParentPid -Timeout 60 -ErrorAction SilentlyContinue } catch { }
    }
    if (-not $DryRun) {
        # until the data folder has moved, the log and the result file live in the old one (they move along)
        $logHome = $Data
        if ($moveData) { $logHome = $oldData }
        New-Item -ItemType Directory -Force -Path (Join-Path $logHome "logs") | Out-Null
        $script:HsResult = Join-Path (Join-Path $logHome "run") "installer-result.json"
        $script:HsMode = $mode
        $script:HsLog = Join-Path (Join-Path $logHome "logs") "install.log"
        if ($Update) {
            # "omnitrack update" already sends this script's output to update.log: writing it too would collide
            $redirected = $false
            try { $redirected = [Console]::IsOutputRedirected } catch { }
            if ($redirected) { $script:HsLog = $null } else { $script:HsLog = Join-Path (Join-Path $logHome "logs") "update.log" }
            if ($redirected -and $moveData -and -not $Relaunched -and $PSCommandPath) {
                Start-SecondHalf
                $script:HsResult = $null           # the second half writes the result
                return
            }
        }
    }
    try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

    Say ""
    Say ("---- Omnitrack installer, {0} ({1:yyyy-MM-dd HH:mm:ss})" -f $mode, (Get-Date))
    Say "app folder:  $App"
    Say "data folder: $Data"
    if ($script:Mig) {
        Say "Health Sync $($script:Mig.Version) is moved over: app $(if ($oldApp) { $oldApp } else { '-' }), data $(if ($moveData) { $oldData } else { '-' })"
    }
    $bothData = $staleData
    if ($oldData -and -not $moveData) { $bothData = $oldData }
    if ($bothData -and -not $DryRun) { Say "note: both $bothData and $Data hold Omnitrack data; $Data is used and $bothData is left as it is" }

    # ---- 1. preflight
    Step "Checking this computer"
    if ($Prefix -notmatch "^[A-Za-z0-9][A-Za-z0-9 _-]{0,39}$") { Fail 1 "The service prefix may only use letters, digits, spaces, - and _ (got '$ServicePrefix')." }
    if ($Port -lt 1024 -or $Port -gt 65535) { Fail 1 "The port must be between 1024 and 65535." }
    $appIn = $Data.StartsWith($App + "\", [StringComparison]::OrdinalIgnoreCase)
    if ($appIn -or [string]::Equals($App, $Data, [StringComparison]::OrdinalIgnoreCase)) {
        Fail 1 "The data folder must not be inside the app folder (updates replace the app folder)."
    }
    if ($moveData -and (Test-Path -LiteralPath $Data) -and -not (Test-EmptyFolder $Data)) {
        Fail 1 "Your data is in $oldData, and $Data already exists without Omnitrack's settings in it. Move or delete $Data, then run the installer again."
    }
    $os = [Environment]::OSVersion.Version
    if ($os.Major -lt 10 -or $os.Build -lt 17763) { Fail 1 "Omnitrack needs Windows 10 version 1809 or newer (this is $os)." }
    if (-not [Environment]::Is64BitOperatingSystem) { Fail 1 "Omnitrack needs 64-bit Windows." }
    if ($PSVersionTable.PSVersion.Major -lt 5) { Fail 1 "Omnitrack needs Windows PowerShell 5.1 or newer." }
    if ($env:PROCESSOR_ARCHITEW6432 -eq "ARM64" -or $env:PROCESSOR_ARCHITECTURE -eq "ARM64") {
        Say "    note: Windows on ARM is not tested in this beta; Omnitrack runs as an x64 app."
    }
    $drive = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($App))
    $freeGb = [math]::Round($drive.AvailableFreeSpace / 1GB, 1)
    if ($drive.AvailableFreeSpace -lt 2GB) { Fail 1 "Omnitrack needs at least 2 GB free on $($drive.Name) ($freeGb GB free)." }
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ((New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Say "    note: running as administrator is not needed; Omnitrack still installs for $env:USERNAME only."
    }
    $src = Join-Path $App "src"
    $srcNew = Join-Path $App "src.new"
    $srcOld = Join-Path $App "src.old"
    $downloads = Join-Path $App "downloads"
    $statePath = Join-Path $App "state.json"
    $hadApp = Test-Path -LiteralPath (Join-Path $src "run.py")
    $oldPy = Join-Path $App "venv\Scripts\python.exe"

    # the port: this data folder's own server may hold it (it is restarted), or Health Sync 0.1's being moved over;
    # anything else holding it is never stopped: another program, another data folder's Omnitrack or another Windows
    # account's (loopback is shared)
    $myHome = Get-HomeIdOf $oldPy (Join-Path $src "run.py") $Data
    if (-not $myHome) { $myHome = Get-HomeId $Data }
    $homes = @($myHome)
    if ($oldData) {
        $legacyHome = $null
        if ($oldApp) { $legacyHome = Get-HomeIdOf (Join-Path $oldApp "venv\Scripts\python.exe") (Join-Path $oldApp "src\run.py") $oldData }
        if (-not $legacyHome) { $legacyHome = Get-HomeId $oldData }
        $homes += $legacyHome
    }
    $wanted = $Port
    if (-not $script:HsPortGiven) {
        $saved = Get-SavedPort $Data
        if (-not $saved -and $oldData) { $saved = Get-SavedPort $oldData }
        if ($saved) { $wanted = $saved }
    }
    $pick = Select-Port $wanted $homes $script:HsPortGiven
    if (-not $pick) {
        if ($script:HsPortGiven) { Fail 1 "Port $wanted is used by another program. Close it, or install with a different port (-Port $($wanted + 1))." }
        Fail 1 "Ports 5710-5730 are all used by other programs. Close one of them and run the installer again."
    }
    $Port = $pick.Port
    $serverWasUp = [bool]$pick.Ours
    # whose server it was: this install's own (restarted after a failed update) or Health Sync 0.1's (Undo-Migration)
    $newWasUp = [bool]($pick.Ours -and $pick.Home -eq $myHome)
    if ($script:Mig) { $script:Mig.WasUp = [bool]($pick.Ours -and -not $newWasUp) }
    $script:HsHadApp = $hadApp
    if ($Port -ne $wanted) { Say "    Omnitrack will use port $Port instead" }
    Say "    Windows $($os.Build), $freeGb GB free, port $Port $(if ($serverWasUp) { 'used by this install (will restart)' } else { 'free' })"
    $makeShortcuts = -not ($NoShortcuts -or $FromInstaller)
    if ($Update -and $makeShortcuts) {
        # an update keeps the shortcuts; one that moves Health Sync 0.1 over remakes them under the new name
        $makeShortcuts = [bool]($oldApp -and ((Test-Path -LiteralPath (Join-Path $oldApp "unins000.exe")) -or
                                              (Get-OldLaunchers $oldApp @()).Count -gt 0))
        if ($makeShortcuts -and -not $StartMenuDir) {
            $first = @(Get-OldLaunchers $oldApp @()) | Select-Object -First 1
            if ($first) { $menuDir = Split-Path -Parent $first }    # where the old ones were
        }
    }

    if ($DryRun) {
        Say ""
        Say "Plan (dry run, nothing is changed):"
        if ($Zip) { Say "  release:        $Zip" } else { Say "  release:        latest from $VersionUrl" }
        Say "  existing app:   $(if ($hadApp) { 'yes (update in place, data kept)' } else { 'no (fresh install)' })"
        if ($script:Mig) {
            Say "  Health Sync:    $(if ($oldApp) { "$oldApp is stopped, its tasks, shortcuts and Installed apps entry removed, then the folder deleted" } else { 'no old app folder' })"
            if ($moveData) { Say "  your data:      $oldData is moved to $Data" }
            Say "  sign-ins:       moved to the keychain names of '$Prefix'$(if ($script:Mig.Prefix) { " (from '$($script:Mig.Prefix)')" })"
        }
        if ($bothData) { Say "  your data:      both $bothData and $Data exist: $Data is used, the old folder is left as it is" }
        Say "  uv:             $App\uv\uv.exe (pinned in installer\uv.json)"
        Say "  python:         $App\python (uv-managed CPython 3.12, no PATH or registry entries)"
        Say "  environments:   $App\venv$(if (Test-Path -LiteralPath $statePath) { ' (+ venv-memos when state.json lists memo extras)' })"
        Say "  command line:   $App\omnitrack.cmd (healthsync.cmd: the same, under the 0.1 name)"
        Say "  port:           $Port"
        if ($NoServices) { Say "  services:       not registered (-NoServices)" }
        else { Say "  services:       '$(Get-TaskName $Prefix 'Server')' (at logon), '... Daily-...', '... Memos-...' (only when voice memos are on)" }
        if (-not $makeShortcuts) { Say "  shortcuts:      none (made by the GUI installer, kept by an update, or -NoShortcuts)" }
        else { Say "  shortcuts:      $menuDir\$Prefix.lnk, $Prefix Settings.lnk; an 'Installed apps' entry" }
        if ($NoBrowser -or $FromInstaller -or $Update -or $NoServices) { Say "  setup page:     not opened" }
        else { Say "  setup page:     http://127.0.0.1:$Port/setup" }
        Say "  log:            $Data\logs\$(if ($Update) { 'update.log' } else { 'install.log' })"
        return
    }

    New-Item -ItemType Directory -Force -Path $App, $downloads | Out-Null
    if ($script:Mig -and $oldApp) {
        # the old app's download cache spares downloading every library again (uv's cache can be moved)
        $oldCache = Join-Path $oldApp "cache"
        $newCache = Join-Path $App "cache"
        if ((Test-Path -LiteralPath $oldCache) -and -not (Test-Path -LiteralPath $newCache)) {
            try { Move-Folder $oldCache $newCache; Say "    reusing the download cache of $oldApp" } catch { }
        }
    }

    # ---- 2. release zip
    Step "Getting the Omnitrack release"
    $versionDoc = $null
    if ($zipArg) {
        $zipPath = $zipArg
        if (-not (Test-Path -LiteralPath $zipPath)) { Fail 2 "Release zip not found: $zipPath" }
        if ($Sha256 -and (Get-Sha256 $zipPath) -ne $Sha256.ToLowerInvariant()) { Fail 2 "The release zip does not match its SHA256 checksum." }
        $inDownloads = [string]::Equals((Split-Path -Parent $zipPath), $downloads, [StringComparison]::OrdinalIgnoreCase)
        if (-not $inDownloads) {
            $copy = Join-Path $downloads (Split-Path -Leaf $zipPath)
            Copy-Item -LiteralPath $zipPath -Destination $copy -Force
            $zipPath = $copy
        }
        Say "    using $zipPath"
    } else {
        try { $versionDoc = Get-JsonDocument $VersionUrl } catch { Fail 2 "Could not read $VersionUrl ($($_.Exception.Message)). Check the internet connection and try again." }
        $asset = $versionDoc.assets.zip
        if (-not $asset -or -not $asset.url -or -not $asset.sha256) { Fail 2 "version.json has no release zip." }
        $zipPath = Join-Path $downloads ("omnitrack-{0}.zip" -f $versionDoc.latest)
        if ((Test-Path -LiteralPath $zipPath) -and (Get-Sha256 $zipPath) -eq $asset.sha256.ToLowerInvariant()) {
            Say "    already downloaded: $zipPath"
        } else {
            Say "    downloading Omnitrack $($versionDoc.latest)"
            try { Get-RemoteFile $asset.url $zipPath } catch { Fail 2 "Download failed: $($_.Exception.Message)" }
            if ((Get-Sha256 $zipPath) -ne $asset.sha256.ToLowerInvariant()) {
                Remove-Item -LiteralPath $zipPath -Force
                Fail 2 "The downloaded release does not match its SHA256 checksum; nothing was changed."
            }
        }
    }

    # ---- 3. unpack next to the running app
    Step "Unpacking"
    if (Test-Path -LiteralPath $srcNew) { Remove-Tree $srcNew }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    try { [IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $srcNew) } catch { Fail 2 "The release zip could not be unpacked: $($_.Exception.Message)" }
    $newVersion = Get-SrcVersion $srcNew
    $script:HsTarget = $newVersion
    if (-not (Test-Path -LiteralPath (Join-Path $srcNew "run.py")) -or -not $newVersion) {
        Remove-Tree $srcNew
        Fail 2 "The release zip is not an Omnitrack release (run.py or the version is missing)."
    }
    $oldVersion = ""
    if ($hadApp) { $oldVersion = Get-SrcVersion $src }
    if ($oldVersion) { Say "    Omnitrack $oldVersion -> $newVersion" }
    elseif ($script:Mig) { Say "    Health Sync $($script:Mig.Version) -> Omnitrack $newVersion" }
    else { Say "    Omnitrack $newVersion" }
    $pyVersion = "3.12"
    $pvFile = Join-Path $srcNew ".python-version"
    if (Test-Path -LiteralPath $pvFile) { $pyVersion = (Get-Content -LiteralPath $pvFile -TotalCount 1).Trim() }

    # ---- 4. uv (the package manager that installs Python and the libraries)
    Step "Preparing uv"
    $pins = $null
    $pinFile = Join-Path $srcNew "installer\uv.json"
    if (Test-Path -LiteralPath $pinFile) { $pins = Get-Content -LiteralPath $pinFile -Raw | ConvertFrom-Json }
    elseif ($versionDoc -and $versionDoc.uv) { $pins = $versionDoc.uv }
    else { Fail 3 "The release has no uv pin (installer\uv.json)." }
    $uvDir = Join-Path $App "uv"
    $uv = Join-Path $uvDir "uv.exe"
    New-Item -ItemType Directory -Force -Path $uvDir | Out-Null
    if ((Get-UvVersion $uv) -ne $pins.version) {
        if ($uvArg) {
            if ((Get-UvVersion $uvArg) -ne $pins.version) { Fail 3 "-UvExe is not uv $($pins.version)." }
            Copy-Item -LiteralPath $uvArg -Destination $uv -Force
        } else {
            $pin = $pins."windows-x86_64"
            $uvZip = Join-Path $downloads ("uv-{0}-windows-x86_64.zip" -f $pins.version)
            Say "    downloading uv $($pins.version)"
            try { Get-RemoteFile $pin.url $uvZip } catch { Fail 3 "Could not download uv: $($_.Exception.Message)" }
            if ((Get-Sha256 $uvZip) -ne $pin.sha256.ToLowerInvariant()) {
                Remove-Item -LiteralPath $uvZip -Force
                Fail 3 "The uv download does not match its SHA256 checksum."
            }
            $tmp = Join-Path $downloads "uv-unpack"
            Remove-Tree $tmp
            [IO.Compression.ZipFile]::ExtractToDirectory($uvZip, $tmp)
            foreach ($f in "uv.exe", "uvx.exe", "uvw.exe") {
                $found = Get-ChildItem -LiteralPath $tmp -Recurse -Filter $f | Select-Object -First 1
                if ($found) { Copy-Item -LiteralPath $found.FullName -Destination (Join-Path $uvDir $f) -Force }
            }
            Remove-Tree $tmp
            Remove-Item -LiteralPath $uvZip -Force
        }
    }
    if ((Get-UvVersion $uv) -ne $pins.version) { Fail 3 "uv $($pins.version) could not be set up in $uvDir." }
    Say "    uv $($pins.version)"

    # every uv call: everything inside the app folder, never a system or conda Python, nothing on PATH
    Set-ProcessEnv @{
        UV_CACHE_DIR = (Join-Path $App "cache"); UV_PYTHON_INSTALL_DIR = (Join-Path $App "python")
        UV_PYTHON_PREFERENCE = "only-managed"; UV_PYTHON_INSTALL_BIN = "0"; UV_PYTHON_INSTALL_REGISTRY = "0"
        UV_NO_PROGRESS = "1"; UV_PYTHON = $null; UV_SYSTEM_PYTHON = $null; VIRTUAL_ENV = $null
        PYTHONHOME = $null; PYTHONPATH = $null; PYTHONIOENCODING = "utf-8"; PYTHONUTF8 = "1"
        UV_PROJECT_ENVIRONMENT = (Join-Path $App "venv")
    }

    # ---- 5. Python (before anything is stopped: a failed download changes nothing)
    Step "Installing Python $pyVersion (first time: about 30 MB)"
    $rc = Invoke-Logged $uv @("python", "install", $pyVersion, "--no-bin", "--no-registry")
    if ($rc -ne 0) { Fail 3 "uv could not install Python $pyVersion (exit $rc)." }

    # ---- 6. stop the running app so its files can be replaced
    $running = @()
    foreach ($n in $script:HsTasks) { if ((Get-TaskState (Get-TaskName $Prefix $n)) -eq "Running") { $running += $n } }
    if ($hadApp) {
        Step "Stopping the running Omnitrack"
        if (Test-Path -LiteralPath $oldPy) {
            $null = Invoke-Logged $oldPy @((Join-Path $src "run.py"), "--home", $Data, "service", "stop")
        }
        foreach ($n in $running) {
            try { Stop-ScheduledTask -TaskPath "\" -TaskName (Get-TaskName $Prefix $n) -ErrorAction Stop } catch { }
        }
        Wait-AppStopped $App 30
    }

    # ---- 7. swap src (the previous version stays in src.old until the end)
    Step "Installing the app files"
    if (Test-Path -LiteralPath $srcOld) { Remove-Tree $srcOld }
    $swapped = $false
    try {
        if (Test-Path -LiteralPath $src) { Rename-WithRetry $src "src.old" }
        Rename-WithRetry $srcNew "src"
        $swapped = $true
    } catch {
        if ((-not (Test-Path -LiteralPath $src)) -and (Test-Path -LiteralPath $srcOld)) { Rename-WithRetry $srcOld "src" }
        Restart-Previous $App $Data $running $newWasUp
        Fail 4 "The app folder is in use and could not be replaced: $($_.Exception.Message)"
    }

    # ---- 8. libraries, Health Sync 0.1 handed over, command-line shim, data folder
    $extras = @()
    if ($script:Mig -and $oldApp) { $extras = @(Copy-OldState $oldApp $statePath) }
    if (Test-Path -LiteralPath $statePath) {
        try { $extras = @((Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json).extras | Where-Object { $_ }) } catch { $extras = @() }
    }
    $py = Join-Path $App "venv\Scripts\python.exe"
    $run = Join-Path $src "run.py"
    $problem = Sync-All $App $extras
    if (-not $problem -and $script:Mig) {
        # the new app is ready: only now is Health Sync 0.1 stopped and its data moved (undone on any failure below)
        try {
            if ($oldApp) { Stop-OldApp }
            else { $script:Mig.Stopped = $true }
            if ($moveData) { Move-OldData $Data $py $run }
        } catch { $problem = "Health Sync 0.1 could not be moved over: $($_.Exception.Message)" }
    }
    $prevPrefix = "$(Get-Saved $Data 'service_prefix')"       # the prefix before this install (its keychain names)
    if (-not $prevPrefix -and $script:Mig) { $prevPrefix = $script:Mig.Prefix }
    if (-not $problem) {
        Write-Shim $App $Data $customData
        Step "Preparing the data folder"
        if (-not ($script:Mig -and $script:Mig.Moved)) {
            # an earlier move that stopped between the rename and "migrate --moved-from" (power cut, logoff), or an
            # undo that could not move the folder back: the settings still point into the old folder
            foreach ($twin in @(Get-OldPath $Data) + @(@($LegacyDataDir) | Where-Object { $_ } | ForEach-Object { Resolve-FullPath $_ })) {
                if ($twin -and $twin -ne $Data -and -not (Test-DataFolder $twin) -and (Test-PointsInto $Data $twin)) {
                    Say "    the settings still point into $twin"
                    $rc = Invoke-Logged $py @($run, "--home", $Data, "migrate", "--moved-from", $twin)
                    if ($rc -ne 0) { Say "    note: they could not be changed (exit $rc); the next install tries again" }
                }
            }
        }
        $rc = Invoke-Logged $py @($run, "--home", $Data, "init", "--port", "$Port", "--service-prefix", $Prefix)
        if ($rc -ne 0) { $problem = "omnitrack init failed (exit $rc)" }
    }
    if ($problem) {
        Undo-Migration $App $Data
        Restore-Old $App $extras
        Restart-Previous $App $Data $running $newWasUp
        Fail 4 "$problem. $(Get-RollbackNote)"
    }

    # ---- 9. background tasks and the server
    $servicesOk = $true
    if (-not $NoServices) {
        Step "Registering the background tasks"
        if ($script:Mig) { $script:Mig.NewTasks = $true }
        foreach ($t in (Get-TasksOf $App)) {
            # tasks of this app folder under an earlier prefix (Health Sync 0.1's "Health Sync ...")
            if ($t.TaskName -notlike "$Prefix *") {
                try {
                    Stop-ScheduledTask -TaskPath "\" -TaskName $t.TaskName -ErrorAction SilentlyContinue
                    Unregister-ScheduledTask -TaskPath "\" -TaskName $t.TaskName -Confirm:$false -ErrorAction Stop
                    Say "    removed the task '$($t.TaskName)' (its old name)"
                } catch { Say "    note: could not remove the task '$($t.TaskName)'" }
            }
        }
        $rc = Invoke-Logged $py @($run, "--home", $Data, "service", "install")
        if ($rc -ne 0) { $servicesOk = $false; Say "    service install failed (exit $rc)" }
        $rc = Invoke-Logged $py @($run, "--home", $Data, "service", "start", "--only", "server")
        if ($rc -ne 0) { $servicesOk = $false; Say "    could not start the server (exit $rc)" }
        Step "Waiting for the Omnitrack server on port $Port"
        # only this data folder's own server counts: another Omnitrack on the same port is not this install
        $newHome = Get-HomeIdOf $py $run $Data
        if ($newHome) { $myHome = $newHome }
        $up = $false
        $foreign = $false
        $deadline = (Get-Date).AddSeconds($ServerWait)
        while ((Get-Date) -lt $deadline) {
            $pong = Test-Ping $Port
            if ($pong -and $pong.app -eq "healthsync" -and $pong.home -eq $myHome) { $up = $true; break }
            $foreign = [bool]($pong -and -not ($pong.app -eq "healthsync" -and $pong.home -eq $myHome))
            Start-Sleep -Seconds 1
        }
        if ($up) { Say "    the server answers on http://127.0.0.1:$Port" }
        else {
            $servicesOk = $false
            if ($foreign) { Say "    another program (or another Omnitrack) answers on port $Port, not this one" }
            else { Say "    the server did not answer within $ServerWait seconds" }
            $migrated = [bool]($script:Mig -and $script:Mig.Stopped)
            if ($migrated -or ($hadApp -and $newWasUp -and (Test-Path -LiteralPath $srcOld))) {
                # go back to what worked: Health Sync 0.1 as it was (whether or not its server ran), and the previous
                # version of this app folder when there was one
                Undo-Migration $App $Data
                if ($hadApp -and (Test-Path -LiteralPath $srcOld)) {
                    Restore-Old $App $extras
                    $null = Invoke-Logged $oldPy @($run, "--home", $Data, "service", "install")
                    Restart-Previous $App $Data $running $newWasUp
                }
                Fail 4 "The new version did not start. $(Get-RollbackNote)"
            }
        }
    }

    # ---- 10. finish: sign-ins under the current names, Health Sync 0.1 removed, shortcuts, state.json, clean up
    $ka = @($run, "--home", $Data, "migrate", "--keychain")
    if ($prevPrefix -and $prevPrefix -ne $Prefix) { $ka += @("--from-prefix", $prevPrefix) }
    if ($script:Mig -and $script:Mig.App) {
        $legacyPy = Join-Path $script:Mig.App "venv\Scripts\python.exe"
        if (Test-Path -LiteralPath $legacyPy) { $ka += @("--legacy-python", $legacyPy) }
    }
    $rc = Invoke-Logged $py $ka
    if ($rc -ne 0) { Say "    note: a sign-in stays under its old keychain name (exit $rc); it still works" }
    if ($script:Mig) { Complete-Migration $App $Data $menuDir }
    $kind = "ps1"
    if ($FromInstaller) { $kind = "inno" }
    $stateArgs = @((Join-Path $src "installer\state.py"), $statePath, "--version", $newVersion, "--installer", $kind, "--uv", "$($pins.version)")
    $keyName = $script:NewName
    if ($Prefix -ne $script:NewName) { $keyName = $script:NewName + "-" + ($Prefix -replace "[^A-Za-z0-9_-]", "") }
    $keyPath = "Software\Microsoft\Windows\CurrentVersion\Uninstall\$keyName"
    if (-not $FromInstaller) {
        # this app folder's shortcuts and "Installed apps" entry under an earlier name are made again under this one
        $stale = @(Get-OldLaunchers $App @() | Where-Object { @("$Prefix.lnk", "$Prefix Settings.lnk") -notcontains (Split-Path -Leaf $_) })
        $staleKeys = @(Get-OldUninstallKeys $App | Where-Object { $_.PSChildName -ne $keyName -and $_.PSChildName -notlike "*_is1" })
        foreach ($l in $stale) { Remove-Item -LiteralPath $l -Force -ErrorAction SilentlyContinue; Say "    removed the shortcut $(Split-Path -Leaf $l) (its old name)" }
        foreach ($k in $staleKeys) { Remove-Item -LiteralPath $k.PSPath -Recurse -Force -ErrorAction SilentlyContinue; Say "    removed '$($k.PSChildName)' from Installed apps (its old name)" }
        if (($stale.Count -gt 0 -or $staleKeys.Count -gt 0) -and -not $NoShortcuts) {
            $makeShortcuts = $true
            if ($stale.Count -gt 0 -and -not $StartMenuDir) { $menuDir = Split-Path -Parent $stale[0] }
        }
    }
    if ($FromInstaller) {
        # the GUI installer has its own Start-menu entries and "Installed apps" entry: drop the one-line install's
        try { Remove-Item -LiteralPath "HKCU:\$keyPath" -Recurse -Force -ErrorAction Stop } catch { }
        $stateArgs += @("--no-uninstall-key", "--no-launchers")
    } elseif ($Update -and -not $makeShortcuts) {
        # an update keeps the shortcuts; the "Installed apps" entry shows the new version
        try { Set-ItemProperty -LiteralPath "HKCU:\$keyPath" -Name DisplayVersion -Value $newVersion -ErrorAction Stop } catch { }
    } elseif ($makeShortcuts) {
        # the one-line install gets what the GUI installer makes: two Start-menu entries and an "Installed apps" entry
        Step "Adding Omnitrack to the Start menu"
        $ico = Join-Path $App "omnitrack.ico"
        try { Copy-Item -LiteralPath (Join-Path $src "installer\windows\healthsync.ico") -Destination $ico -Force } catch { }
        $pyw = Join-Path $App "venv\Scripts\pythonw.exe"
        $homeQ = "--home `"$Data`""
        try {
            New-Item -ItemType Directory -Force -Path $menuDir | Out-Null
            $lnkOpen = Join-Path $menuDir "$Prefix.lnk"
            $lnkSet = Join-Path $menuDir "$Prefix Settings.lnk"
            New-Shortcut $lnkOpen $pyw "`"$run`" $homeQ open" $App $ico "Open your Omnitrack day page"
            New-Shortcut $lnkSet $pyw "`"$run`" $homeQ setup" $App $ico "Omnitrack setup and settings"
            $stateArgs += @("--launcher", $lnkOpen, "--launcher", $lnkSet)
            Say "    $lnkOpen"
        } catch { Say "    note: the Start-menu shortcuts could not be made ($($_.Exception.Message))" }
        try {
            $ps = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
            $unins = Join-Path $src "installer\windows\uninstall.ps1"
            $k = "HKCU:\$keyPath"
            New-Item -Path $k -Force | Out-Null
            $vals = [ordered]@{
                DisplayName = $Prefix; DisplayVersion = $newVersion; Publisher = "jel0624"; InstallLocation = $App
                DisplayIcon = $ico; URLInfoAbout = "https://jel0624.github.io/health-sync/"
                UninstallString = "`"$ps`" -NoProfile -ExecutionPolicy Bypass -File `"$unins`" -AppDir `"$App`" -DataDir `"$Data`" -ServicePrefix `"$Prefix`""
            }
            foreach ($name in $vals.Keys) { New-ItemProperty -Path $k -Name $name -Value $vals[$name] -PropertyType String -Force | Out-Null }
            New-ItemProperty -Path $k -Name "NoModify" -Value 1 -PropertyType DWord -Force | Out-Null
            New-ItemProperty -Path $k -Name "NoRepair" -Value 1 -PropertyType DWord -Force | Out-Null
            $stateArgs += @("--uninstall-key", $keyPath)
            Say "    Settings > Apps > Installed apps: $Prefix"
        } catch { Say "    note: the 'Installed apps' entry could not be made ($($_.Exception.Message))" }
    }
    $null = Invoke-Logged $py $stateArgs
    try { Remove-Tree $srcOld } catch { Say "    note: could not remove $srcOld yet ($($_.Exception.Message))" }
    Get-ChildItem -LiteralPath $downloads -Filter "*.zip" -ErrorAction SilentlyContinue |
        Where-Object { ($_.Name -like "omnitrack-*.zip" -or $_.Name -like "health-sync-*.zip") -and $_.FullName -ne $zipPath } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }

    Step "Done"
    Say "    Omnitrack $newVersion is installed for $env:USERNAME."
    Say "    Your data stays in $Data"
    Say "    Command line: `"$App\omnitrack.cmd`" (for example: omnitrack.cmd doctor)"
    if (-not $NoServices -and -not $NoBrowser -and -not $FromInstaller -and -not $Update -and $servicesOk) {
        Say "    Opening the setup page: http://127.0.0.1:$Port/setup"
        $null = Invoke-Logged $py @($run, "--home", $Data, "setup")
    } elseif ($NoServices) {
        Say "    Background tasks were not registered (-NoServices). Start the server with: omnitrack.cmd serve"
    } elseif (-not $Update) {
        Say "    Setup page: http://127.0.0.1:$Port/setup"
    }
    if (-not $servicesOk) { Fail 5 "Omnitrack is installed, but its background tasks could not be set up. Run 'omnitrack.cmd doctor' for details." }
}

function Sync-All([string]$App, [object[]]$Extras) {
    # uv sync of the base environment, and of venv-memos when the voice memo step installed it; "" or a problem text
    Step "Installing the libraries (first time: a few minutes)"
    $env:UV_PROJECT_ENVIRONMENT = Join-Path $App "venv"
    $rc = Invoke-Logged (Join-Path $App "uv\uv.exe") @("sync", "--project", (Join-Path $App "src"), "--frozen", "--no-dev")
    if ($rc -ne 0) { return "uv sync failed (exit $rc)" }
    $memoExtras = @($Extras | Where-Object { $_ -eq "memos" -or $_ -eq "cuda" })
    if ($memoExtras -contains "memos") {
        Step "Updating the voice memo environment"
        $env:UV_PROJECT_ENVIRONMENT = Join-Path $App "venv-memos"
        $a = @("sync", "--project", (Join-Path $App "src"), "--frozen", "--no-dev")
        foreach ($x in $memoExtras) { $a += @("--extra", $x) }
        $rc = Invoke-Logged (Join-Path $App "uv\uv.exe") $a
        $env:UV_PROJECT_ENVIRONMENT = Join-Path $App "venv"
        if ($rc -ne 0) { return "uv sync of the voice memo environment failed (exit $rc)" }
    }
    return ""
}

function Restore-Old([string]$App, [object[]]$Extras) {
    # put src.old back and re-sync its libraries
    $src = Join-Path $App "src"
    $srcOld = Join-Path $App "src.old"
    if (-not (Test-Path -LiteralPath $srcOld)) {
        if (-not $script:Mig) { Say "    nothing to restore (first install); run the installer again after fixing the problem" }
        return
    }
    Step "Restoring the previous version"
    Wait-AppStopped $App 15
    try {
        if (Test-Path -LiteralPath $src) { Remove-Tree $src }
        Rename-WithRetry $srcOld "src"
        $null = Sync-All $App $Extras
    } catch { Say "    restore failed: $($_.Exception.Message)" }
}

function Restart-Previous([string]$App, [string]$Data, [object[]]$Running, [bool]$ServerWasUp) {
    # start again what of this app folder ran before the install began (nothing when there was no Omnitrack here:
    # the new files must not start; Health Sync 0.1 is Undo-Migration's)
    if (-not $script:HsHadApp) { return }
    $py = Join-Path $App "venv\Scripts\python.exe"
    $run = Join-Path $App "src\run.py"
    if (-not (Test-Path -LiteralPath $py) -or -not (Test-Path -LiteralPath $run)) { return }
    $names = @($Running | ForEach-Object { "$_".ToLowerInvariant() })
    if ($ServerWasUp -and ($names -notcontains "server")) { $names += "server" }
    if ($names.Count -gt 0) {
        $null = Invoke-Logged $py @($run, "--home", $Data, "service", "start", "--only", ($names -join ","))
    }
}


# ---------------------------------------------------------------- entry point

$script:HsPushed = $false
$script:HsMode = "install"
try {
    Invoke-Install
} catch {
    $code = $_.Exception.Data["hs_code"]
    if ($null -eq $code) {
        $code = 1
        $script:HsError = "unexpected problem: $($_.Exception.Message)"
        Say "ERROR: $($script:HsError)"
        Say "       at $($_.InvocationInfo.PositionMessage)"
    } else {
        $script:HsError = "$($_.Exception.Message)"
        Say "ERROR: $($script:HsError)"
    }
    if ($script:HsLog) { Say "       The full log is in $($script:HsLog)" }
    $script:HsExit = [int]$code
} finally {
    Restore-ProcessEnv
    if ($script:HsResult) { Write-Result $script:HsResult $script:HsMode $script:HsExit $script:HsTarget $script:HsApp $script:HsError }
    if ($script:HsPushed) { Pop-Location }
    if ($Relaunched -and $PSCommandPath -and (Split-Path -Leaf $PSCommandPath) -like "omnitrack-install-*.ps1") {
        Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue
    }
}

if ($PSCommandPath) { exit $script:HsExit }
# run through "irm | iex" or a script block: do not close the caller's PowerShell window
$global:LASTEXITCODE = $script:HsExit
