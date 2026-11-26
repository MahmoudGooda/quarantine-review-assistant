# Quarantine Review Assistant v2 - HOST launcher.
# Checks that this PC can run Windows Sandbox, prepares the portable Python runtime,
# guides the Defender download, and launches the isolated review session.
# It hashes opaque package bytes on the host. Extraction and message parsing run in the Sandbox.
param([switch]$NoGui, [string]$Screenshot, [int]$ScreenshotDpi = 0, [switch]$ScreenshotMinSize, [string]$ScreenshotSize)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Shared UI kit: DPI helpers, design tokens, fonts, painted controls (with plain fallbacks) and background work.
. (Join-Path $PSScriptRoot 'QraUi.ps1')
# Optional release-request intake (Exchange Online). Dot-sourced WITHOUT arguments: its parameters are aliased so this script's $Incoming and $Screenshot stay untouched.
. (Join-Path $PSScriptRoot 'ReleaseRequests.ps1')
# -ScreenshotDpi: emulate another display scale. Must run before any window exists.
if ($ScreenshotDpi -gt 0) { Set-QraEmulatedDpi $ScreenshotDpi }
[System.Windows.Forms.Application]::EnableVisualStyles()
trap {
    if ($Screenshot) { [Console]::Error.WriteLine($_.Exception.Message + "`n" + $_.InvocationInfo.PositionMessage + "`n" + $_.ScriptStackTrace); exit 1 }   # headless: never wait on a dialog
    [System.Windows.Forms.MessageBox]::Show("The launcher hit an unexpected error:`r`n`r`n$($_.Exception.Message)`r`n`r`nIf your organisation blocks PowerShell scripts, ask IT security to allow this tool's folder.", 'Quarantine Review Assistant', 'OK', 'Error') | Out-Null
    break
}

# ---------------------------------------------------------------- configuration
$AppVersion   = '2.3.0'
$Root         = Split-Path -Parent $PSScriptRoot
$AppDir       = $PSScriptRoot
$Incoming     = Join-Path $Root 'Incoming'
$Reports      = Join-Path $Root 'Reports'
$ProfilesDir  = Join-Path $Root 'Profiles'
$ConfigDir    = Join-Path $Root 'config'
$ConfigFile   = Join-Path $ConfigDir 'organization.json'
$PyDir        = Join-Path $Root 'Tools\Python'
$PyExe        = Join-Path $PyDir 'python.exe'
$PyVersion    = '3.14.8'
$PyUrl        = 'https://www.python.org/ftp/python/3.14.8/python-3.14.8-embed-amd64.zip'
$PySha256     = 'a93abe456ab01bd96d7a085b3cdb6566b3063f4241360d114142fbdb07f0a310'
$QuarantineUrl = 'https://security.microsoft.com/quarantine'
$SandboxFeature = 'Containers-DisposableClientVM'
# Functions the background readiness runspace needs (Get-ReadinessChecks and everything it calls).
$ReadinessFunctions = @('Get-ReadinessChecks', 'New-Check', 'Get-SandboxFeatureState', 'Test-SandboxClient', 'Test-RebootPending', 'Get-OrgConfigCheck', 'Get-SandboxProcess')

# ---------------------------------------------------------------- layout (runs after scaling, so everything here uses S())
$script:LayoutReady = $false
function Fit-CheckRow($row) {
    $detail = $row.Tag.Detail; $btn = $row.Tag.Btn; $bar = $row.Tag.Bar
    $detail.Width = if ($btn) { $row.Width - (S 170) } else { $row.Width - (S 56) }
    if ($btn) { $btn.Left = $row.Width - (S 116) }
    $detail.Height = [Math]::Max((S 24), (Measure-Wrapped $detail.Text $detail.Font $detail.Width) + (S 2))
    $bottom = $detail.Top + $detail.Height
    if ($bar -and $bar.Visible) {
        $bar.Left = $detail.Left; $bar.Width = $detail.Width; $bar.Height = (S 10)
        $bar.Top = $bottom + (S 2)
        $bottom = $bar.Bottom
    }
    $row.Height = [Math]::Max((S 64), $bottom + (S 8))
    if ($btn) { $btn.Top = [int](($row.Height - $btn.Height) / 2) }
}
# ---------------------------------------------------------------- environment checks
function Test-InsideSandbox { return ($env:USERNAME -eq 'WDAGUtilityAccount') }

function Get-SandboxProcess {
    Get-Process -Name 'WindowsSandbox', 'WindowsSandboxClient', 'WindowsSandboxRemoteSession', 'WindowsSandboxServer' -ErrorAction SilentlyContinue
}

function Test-RebootPending {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    foreach ($k in $keys) { if (Test-Path -LiteralPath $k) { return $true } }
    return $false
}

function Get-SandboxFeatureState {
    # Win32_OptionalFeature is readable without admin rights. InstallState: 1 Enabled, 2 Disabled, 3 Absent.
    try {
        $f = Get-CimInstance -ClassName Win32_OptionalFeature -Filter "Name='$SandboxFeature'" -ErrorAction Stop
        if ($null -eq $f) { return 'Absent' }
        switch ([int]$f.InstallState) { 1 { return 'Enabled' } 2 { return 'Disabled' } 3 { return 'Absent' } default { return 'Unknown' } }
    } catch {
        if (Test-SandboxClient) { return 'Enabled' }
        return 'Unknown'
    }
}

function Test-SandboxClient {
    if (Test-Path -LiteralPath (Join-Path $env:windir 'System32\WindowsSandbox.exe')) { return $true }
    if (Get-Command 'WindowsSandbox.exe', 'wsb.exe' -ErrorAction SilentlyContinue) { return $true }
    return (Test-Path -LiteralPath 'Registry::HKEY_CLASSES_ROOT\.wsb')
}

function New-Check($id, $name, $status, $detail, $actionText = $null, $blocking = $false) {
    [pscustomobject]@{ Id = $id; Name = $name; Status = $status; Detail = $detail; Action = $actionText; Blocking = $blocking }
}

function Get-ReadinessChecks {
    $checks = New-Object System.Collections.Generic.List[object]
    $os = $null; $cs = $null; $cpu = $null
    try { $os = Get-CimInstance Win32_OperatingSystem } catch { $null = $_ } # callers handle $null CIM results
    try { $cs = Get-CimInstance Win32_ComputerSystem } catch { $null = $_ } # callers handle $null CIM results
    try { $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1 } catch { $null = $_ } # callers handle $null CIM results

    # 1. Windows edition / build
    if ($os) {
        $caption = [string]$os.Caption
        $build = [int]$os.BuildNumber
        if ($caption -match 'Home') {
            $checks.Add((New-Check 'edition' 'Windows edition' 'FAIL' "$caption - Windows Sandbox needs Pro, Enterprise or Education. Use another PC or upgrade the edition." $null $true))
        } elseif ($build -lt 18362) {
            $checks.Add((New-Check 'edition' 'Windows edition' 'FAIL' "$caption (build $build) - needs Windows 10 1903 or later." $null $true))
        } else {
            $checks.Add((New-Check 'edition' 'Windows edition' 'OK' "$caption, build $build"))
        }
    } else {
        $checks.Add((New-Check 'edition' 'Windows edition' 'WARN' 'Could not read OS information.'))
    }

    # 2. Virtualization
    $virtStatus = 'WARN'; $virtDetail = 'Could not determine virtualization support.'
    $isVm = $cs -and ([string]$cs.Model -match 'Virtual|VMware|KVM|HVM domU|Parallels')
    if ($cs -and $cs.HypervisorPresent) {
        $virtStatus = 'OK'; $virtDetail = 'Hardware virtualization active (hypervisor running).'
    } elseif ($cpu -and $null -ne $cpu.VirtualizationFirmwareEnabled) {
        if ($cpu.VirtualizationFirmwareEnabled) { $virtStatus = 'OK'; $virtDetail = 'Enabled in BIOS/UEFI.' }
        else {
            $virtStatus = 'FAIL'
            $virtDetail = 'Disabled in BIOS/UEFI. Restart, open firmware setup and enable Intel VT-x / AMD-V (SVM), then try again.'
        }
    }
    if ($isVm -and $virtStatus -ne 'OK') { $virtDetail += ' This PC is a virtual machine: the host must expose nested virtualization.' }
    $checks.Add((New-Check 'virt' 'CPU virtualization' $virtStatus $virtDetail $null ($virtStatus -eq 'FAIL')))

    # 3. Resources
    if ($cs) {
        $ramGb = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        $cores = [int]$cs.NumberOfLogicalProcessors
        $sysDrive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'" -ErrorAction SilentlyContinue
        $freeGb = if ($sysDrive) { [math]::Round($sysDrive.FreeSpace / 1GB, 1) } else { 0 }
        $st = if ($ramGb -ge 4 -and $cores -ge 2 -and $freeGb -ge 1) { 'OK' } else { 'WARN' }
        $checks.Add((New-Check 'res' 'Memory / CPU / disk' $st "$ramGb GB RAM, $cores logical CPUs, $freeGb GB free on $($env:SystemDrive) (minimum 4 GB, 2 CPUs, 1 GB)."))
    }

    # 4. Windows Sandbox feature
    $state = Get-SandboxFeatureState
    $pending = Test-RebootPending
    $exe = Test-SandboxClient
    switch ($state) {
        'Enabled' {
            if (-not $exe) {
                $checks.Add((New-Check 'sandbox' 'Windows Sandbox' 'WARN' 'Turned on, but Windows must RESTART before it can be used.' 'Restart now' $true))
            } elseif ($pending) {
                $checks.Add((New-Check 'sandbox' 'Windows Sandbox' 'WARN' 'Installed. Windows has a pending restart - restart first if the Sandbox fails to open.' 'Restart now'))
            } else {
                $checks.Add((New-Check 'sandbox' 'Windows Sandbox' 'OK' 'Installed and ready.'))
            }
        }
        'Disabled' {
            $checks.Add((New-Check 'sandbox' 'Windows Sandbox' 'FAIL' 'Not installed. Click "Install" (asks for administrator approval). A RESTART of this PC is required afterwards.' 'Install' $true))
        }
        'Absent' {
            $checks.Add((New-Check 'sandbox' 'Windows Sandbox' 'FAIL' 'Not available on this Windows installation (edition or virtualization requirement not met).' $null $true))
        }
        default {
            if ($exe) { $checks.Add((New-Check 'sandbox' 'Windows Sandbox' 'OK' 'WindowsSandbox.exe found.')) }
            else { $checks.Add((New-Check 'sandbox' 'Windows Sandbox' 'WARN' 'Could not confirm the feature state. Click "Install" to enable it (admin + restart).' 'Install')) }
        }
    }
    if ($pending -and $state -ne 'Enabled') {
        $checks.Add((New-Check 'reboot' 'Pending restart' 'WARN' 'Windows has a pending restart. Restart before installing or using Sandbox.' 'Restart now'))
    }

    # 5. Python runtime
    if (Test-Path -LiteralPath $PyExe) {
        $checks.Add((New-Check 'python' 'Analysis runtime' 'OK' "Portable Python found in Tools\Python (used only inside the Sandbox)."))
    } else {
        $checks.Add((New-Check 'python' 'Analysis runtime' 'FAIL' "Portable Python $PyVersion is missing (about 12 MB from python.org, SHA256-verified, no install)." 'Download' $true))
    }

    # 6. Tool folder location
    $cloudRoots = @($env:OneDrive, $env:OneDriveCommercial, $env:OneDriveConsumer) | Where-Object { $_ }
    $synced = ($cloudRoots | Where-Object { $Root.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }) -or ($Root -match '\\(OneDrive|Dropbox|Google Drive|iCloudDrive|Box)( |\\|$)')
    if ($Root.StartsWith('\\')) {
        $checks.Add((New-Check 'folder' 'Tool folder' 'WARN' "Network path ($Root). Copy the tool to a local folder such as D:\SecurityReview."))
    } elseif ($synced) {
        $checks.Add((New-Check 'folder' 'Tool folder' 'FAIL' "Inside a cloud-synced folder ($Root): downloaded samples would be uploaded. Move the tool to a local folder such as D:\SecurityReview." $null $true))
    } else {
        $checks.Add((New-Check 'folder' 'Tool folder' 'OK' $Root))
    }

    # 7. Organisation settings
    $checks.Add((Get-OrgConfigCheck))

    # 8. Running sandbox
    if (Get-SandboxProcess) {
        $checks.Add((New-Check 'running' 'Sandbox session' 'INFO' 'A Windows Sandbox window is already open. Only one session can run at a time - close it before launching a new review.'))
    }
    return $checks
}

# Every script variable that Get-ReadinessChecks (and the functions it calls) reads; handed to the background runspace.
function Get-ReadinessVariables {
    @{ Root = $Root; PyExe = $PyExe; PyVersion = $PyVersion; ConfigFile = $ConfigFile; SandboxFeature = $SandboxFeature }
}

# Turns the finished background work into check rows. A failed run becomes one WARN row instead of an exception.
function ConvertTo-ReadinessResult($result) {
    $rows = @(@($result.Output) | Where-Object { $_ })
    if (-not $result.Error) { return $rows }
    if ($rows.Count -gt 0) {
        # A non-terminating error in the checks: keep every row the checks produced and add a warning that says so.
        return @($rows) + @(New-Check 'checks' 'Readiness checks' 'WARN' "Some checks reported an error: $($result.Error). Click Check again.")
    }
    # Nothing came back at all: the PC cannot be called ready, so Launch stays disabled.
    return @(New-Check 'checks' 'Readiness checks' 'WARN' "Could not complete the checks: $($result.Error). Click Check again." $null $true)
}
# Which display path the kit chose (painted controls or plain WinForms). Runs on the UI thread, not in the runspace.
function Get-DisplayCheck([bool]$native = $script:UiNative, [string]$reason = $script:QraDisplayReason) {
    if ($native) { return (New-Check 'display' 'Display: enhanced' 'INFO' 'Enhanced (painted controls)') }
    return (New-Check 'display' 'Display: basic' 'INFO' "Basic ($reason)")
}

# True when the file's last-write time differs from $lastStamp (which is then updated). Used to notice a save in Notepad
# even when a Store Notepad outlives the process the launcher started.
function Test-ConfigChanged([string]$path, [ref]$lastStamp) {
    $now = $null
    try { if (Test-Path -LiteralPath $path) { $now = (Get-Item -LiteralPath $path).LastWriteTimeUtc } } catch { $null = $_ } # transient file access errors are retried on the next poll
    $changed = ($null -ne $now) -and ($now -ne $lastStamp.Value)
    $lastStamp.Value = $now
    return $changed
}

# ---------------------------------------------------------------- guided stepper: pure state
# Turns what the launcher can observe into the five rail rows. Pure: no UI, no disk, no clock.
# $Facts keys: ChecksRunning, BlockingCount, WarnCount, DefenderChecked, IncomingCount, DecisionCurrent,
# DecisionText, SandboxRunning, LaunchState ('None' | 'Starting' | 'Vanished'), ExportOn, DecisionAcknowledged, CleanedUp,
# and optionally CheckSeconds / LaunchSeconds (whole seconds the readiness checks / the Sandbox start have been running).
# ' (12 s)' for a wait that has a count, '' otherwise. Whole seconds only, so the text changes once a second and never jitters.
function Format-WaitSeconds($seconds) {
    if ($null -eq $seconds -or "$seconds" -eq '') { return '' }
    return ' ({0} s)' -f [Math]::Max(0, [int]$seconds)
}
function Get-LauncherStepState([hashtable]$Facts) {
    $titles = @('Prepare this PC', 'Check it in Defender', 'Download the message', 'Analyze in the Sandbox', 'Act in Defender and clean up')
    $steps = @(1..5 | ForEach-Object { [pscustomobject]@{ Number = $_; Title = $titles[$_ - 1]; State = 'Pending'; Summary = '' } })
    if ($Facts.CleanedUp) {
        $final = @('This PC is ready', 'Checked', 'Message downloaded', 'Decision recorded', 'Incoming cleaned up')
        for ($i = 0; $i -lt 5; $i++) { $steps[$i].State = 'Done'; $steps[$i].Summary = $final[$i] }
        return [pscustomobject]@{ Steps = $steps; Current = 0; AllDone = $true }
    }
    $current = 0     # index (1-5) of the first step that is not Done
    $incoming = [int]$Facts.IncomingCount

    # 1. Prepare this PC
    $s = $steps[0]
    if ($Facts.ChecksRunning) { $s.State = 'Working'; $s.Summary = 'Checking this PC...' + (Format-WaitSeconds $Facts.CheckSeconds) }
    elseif ([int]$Facts.BlockingCount -gt 0) { $s.State = 'Blocked'; $s.Summary = "$([int]$Facts.BlockingCount) item(s) to fix" }
    elseif ([int]$Facts.WarnCount -gt 0) { $s.State = 'Done'; $s.Summary = 'Ready, with warnings' }
    else { $s.State = 'Done'; $s.Summary = 'This PC is ready' }
    if ($s.State -ne 'Done') { $current = 1 }

    # 2. Check it in Defender (cannot be observed: a click, or a download that implies it)
    if ($current -eq 0) {
        $s = $steps[1]
        if ($Facts.DefenderChecked -or $incoming -gt 0) { $s.State = 'Done'; $s.Summary = 'Checked' }
        else { $s.State = 'Current'; $current = 2 }
    }

    # 3. Download the message
    if ($current -eq 0) {
        $s = $steps[2]
        if ($incoming -gt 0) { $s.State = 'Done'; $s.Summary = "$incoming file(s) in Incoming" }
        else { $s.State = 'Working'; $s.Summary = 'Watching Incoming for the download...'; $current = 3 }
    }

    # 4. Analyze in the Sandbox
    $byDecision = $false
    if ($current -eq 0) {
        $s = $steps[3]
        $byDecision = ($incoming -eq 1 -and [bool]$Facts.DecisionCurrent)
        if ($byDecision) { $s.State = 'Done'; $s.Summary = 'Decision recorded' }
        elseif ($Facts.DecisionAcknowledged -and -not $Facts.ExportOn) { $s.State = 'Done'; $s.Summary = 'Decision recorded in the Sandbox' }
        elseif ($Facts.SandboxRunning) { $s.State = 'Working'; $s.Summary = 'Review in progress'; $current = 4 }
        elseif ($Facts.LaunchState -eq 'Starting') { $s.State = 'Working'; $s.Summary = 'Starting Windows Sandbox...' + (Format-WaitSeconds $Facts.LaunchSeconds); $current = 4 }
        else {
            $s.State = 'Current'; $current = 4
            if ($Facts.LaunchState -eq 'Vanished') { $s.Summary = 'The Sandbox closed before a decision reached this PC.' }
        }
    }

    # 5. Act in Defender and clean up
    if ($current -eq 0) {
        $s = $steps[4]
        $s.State = 'Current'; $current = 5
        if (-not $byDecision -and $Facts.DecisionAcknowledged -and -not $Facts.ExportOn) { $s.Summary = 'No decision received on this PC (report export was off)' }
        elseif ($byDecision -and $Facts.DecisionText) { $s.Summary = "Decision: $($Facts.DecisionText)" }
    }
    [pscustomobject]@{ Steps = $steps; Current = $current; AllDone = $false }
}

# The three header pills (PC, Python, Sandbox) from the readiness rows. Each carries a word, never colour alone.
function Get-LauncherPills($checks, [bool]$checking) {
    if ($checking) {
        return @('PC', 'Python', 'Sandbox' | ForEach-Object { [pscustomobject]@{ Name = $_; Status = 'BUSY'; Text = "$_`: checking" } })
    }
    $rows = @($checks | Where-Object { $_ })
    $worst = {
        param($group)
        $r = 'OK'
        foreach ($g in @($group)) {
            if ($g.Status -eq 'FAIL') { return 'FAIL' }
            if ($g.Status -eq 'WARN') { $r = 'WARN' }
        }
        $r
    }
    $py = @($rows | Where-Object { $_.Id -eq 'python' })
    $sb = @($rows | Where-Object { $_.Id -in 'sandbox', 'reboot' })
    $pc = @($rows | Where-Object { $_.Id -notin 'python', 'sandbox', 'reboot', 'display', 'running' })
    $out = @()
    # PC
    if (-not $pc.Count) { $st = 'INFO'; $tx = 'PC' } else {
        $st = & $worst $pc
        $tx = switch ($st) { 'FAIL' { 'PC: fix needed' } 'WARN' { 'PC: warnings' } default { 'PC ready' } }
    }
    $out += [pscustomobject]@{ Name = 'PC'; Status = $st; Text = $tx }
    # Python
    if (-not $py.Count) { $st = 'INFO'; $tx = 'Python' }
    elseif ($py[0].Status -eq 'INFO') { $st = 'BUSY'; $tx = 'Python: downloading' }
    else {
        $st = & $worst $py
        $tx = switch ($st) { 'FAIL' { 'Python: missing' } 'WARN' { 'Python: check' } default { 'Python ready' } }
    }
    $out += [pscustomobject]@{ Name = 'Python'; Status = $st; Text = $tx }
    # Sandbox
    if (-not $sb.Count) { $st = 'INFO'; $tx = 'Sandbox' }
    elseif (@($sb | Where-Object { $_.Status -eq 'INFO' -and $_.Id -eq 'sandbox' }).Count) { $st = 'BUSY'; $tx = 'Sandbox: installing' }
    else {
        $st = & $worst $sb
        $restart = @($sb | Where-Object { $_.Action -eq 'Restart now' }).Count -gt 0
        $tx = switch ($st) { 'FAIL' { 'Sandbox: not ready' } 'WARN' { if ($restart) { 'Sandbox: restart' } else { 'Sandbox: check' } } default { 'Sandbox ready' } }
    }
    $out += [pscustomobject]@{ Name = 'Sandbox'; Status = $st; Text = $tx }
    $out
}

# ---------------------------------------------------------------- organisation settings
function Initialize-OrgConfig {
    if (Test-Path -LiteralPath $ConfigFile) { return }
    New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
    $tpl = @'
{
  "_help": "Edit the lists below, save, and close Notepad. Used to detect look-alike domains, executive impersonation and external SharePoint tenants. Read-only inside the Sandbox.",
  "org_domains": ["example.com"],
  "m365_tenant_names": ["example"],
  "vip_display_names": ["First Last (CEO)", "First Last (CFO)"],
  "trusted_partner_domains": []
}
'@
    [System.IO.File]::WriteAllText($ConfigFile, $tpl, (New-Object System.Text.UTF8Encoding($false)))
}
function Get-OrgConfigCheck {
    if (-not (Test-Path -LiteralPath $ConfigFile)) {
        return (New-Check 'orgcfg' 'Organisation settings' 'INFO' 'Not set. Add your domains and executive names so impersonation and look-alike checks know what "you" look like.' 'Edit')
    }
    try {
        $cfg = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return (New-Check 'orgcfg' 'Organisation settings' 'WARN' 'organization.json is not valid JSON (check commas and quotes). The review will run without it.' 'Edit')
    }
    $doms = @($cfg.org_domains | Where-Object { $_ -and $_ -ne 'example.com' })
    $vips = @($cfg.vip_display_names | Where-Object { $_ -and $_ -notmatch '^First Last' })
    if (-not $doms.Count) { return (New-Check 'orgcfg' 'Organisation settings' 'INFO' 'Still has example values. Add your real domains and executive names.' 'Edit') }
    return (New-Check 'orgcfg' 'Organisation settings' 'OK' "$($doms.Count) domain(s): $(($doms | Select-Object -First 3) -join ', ')$(if ($doms.Count -gt 3) { '...' }); $($vips.Count) executive name(s)." 'Edit')
}

# ---------------------------------------------------------------- sandbox profile
function Write-SandboxProfile([bool]$allowReports, [bool]$protected, [bool]$compat) {
    New-Item -ItemType Directory -Force -Path $ProfilesDir | Out-Null
    $hostRoot = [System.Security.SecurityElement]::Escape($Root)
    $hostReports = [System.Security.SecurityElement]::Escape($Reports)
    $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\Review\app\QuarantineReview.ps1'
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<Configuration>')
    [void]$sb.AppendLine('  <Networking>Disable</Networking>')
    if (-not $compat) {
        foreach ($opt in 'vGPU', 'ClipboardRedirection', 'PrinterRedirection', 'AudioInput', 'VideoInput') {
            [void]$sb.AppendLine("  <$opt>Disable</$opt>")
        }
        if ($protected) { [void]$sb.AppendLine('  <ProtectedClient>Enable</ProtectedClient>') }
    }
    [void]$sb.AppendLine('  <MappedFolders>')
    [void]$sb.AppendLine("    <MappedFolder><HostFolder>$hostRoot</HostFolder><SandboxFolder>C:\Review</SandboxFolder><ReadOnly>true</ReadOnly></MappedFolder>")
    if ($allowReports) {
        New-Item -ItemType Directory -Force -Path $Reports | Out-Null
        [void]$sb.AppendLine("    <MappedFolder><HostFolder>$hostReports</HostFolder><SandboxFolder>C:\Reports</SandboxFolder><ReadOnly>false</ReadOnly></MappedFolder>")
    }
    [void]$sb.AppendLine('  </MappedFolders>')
    [void]$sb.AppendLine("  <LogonCommand><Command>$cmd</Command></LogonCommand>")
    [void]$sb.AppendLine('</Configuration>')
    $path = Join-Path $ProfilesDir 'QuarantineReview.wsb'
    [System.IO.File]::WriteAllText($path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
    return $path
}

# ---------------------------------------------------------------- inside-sandbox guard
if (Test-InsideSandbox) {
    [System.Windows.Forms.MessageBox]::Show('You are inside Windows Sandbox. The review window (QuarantineReview.ps1) is the tool to use here; the launcher runs on the host PC.', 'Quarantine Review Assistant', 'OK', 'Information') | Out-Null
    return
}
if (-not $Screenshot) { New-Item -ItemType Directory -Force -Path $Incoming | Out-Null }

if ($NoGui) { Get-ReadinessChecks | Format-Table Name, Status, Detail -AutoSize -Wrap; return }

# hide the PowerShell console that launched us (purely cosmetic; ignored if blocked)
if (-not $Screenshot) { Hide-QraConsole }

# ================================================================= UI
$Fonts = @{
    Title = (New-Font 18 'Bold' 'Display'); Sub = (New-Font 10); Pane = (New-Font 14 'Bold' 'Display')
    Row = (New-Font 11 'Bold'); RowSub = (New-Font 9.5); Body = (New-Font 10); BodyBold = (New-Font 10 'Bold')
    Eyebrow = (New-Font 9 'Bold'); Overall = (New-Font 10 'Bold'); Pill = (New-Font 9.5 'Bold')
}
# Shown in a rail row until the step has a summary of its own (pending steps, or a current step with nothing to report).
$StepHints = @('Check Windows Sandbox and Python', 'Look before you release', 'Save the ZIP into Incoming', 'Open the offline Sandbox', 'Block or release, then clean up')

# Control.Visible is false for every control while the form is not shown, so the launcher tracks what it asked for itself.
$script:Vis = @{}
function Set-Shown($ctl, [bool]$v) { $ctl.Visible = $v; $script:Vis[$ctl] = $v }
function Test-Shown($ctl) { [bool]$script:Vis[$ctl] }

# Real advance width of a run of text (TextRenderer.MeasureText pads by about 10 px; trailing spaces count). Used to lay out mixed-weight lines.
function Get-TextAdvance([string]$text, $font) {
    $fl = [System.Windows.Forms.TextFormatFlags]::NoPadding -bor [System.Windows.Forms.TextFormatFlags]::SingleLine -bor [System.Windows.Forms.TextFormatFlags]::NoPrefix
    $big = New-Object System.Drawing.Size([int]::MaxValue, 0)
    [System.Windows.Forms.TextRenderer]::MeasureText($text + '|', $font, $big, $fl).Width - [System.Windows.Forms.TextRenderer]::MeasureText('|', $font, $big, $fl).Width
}
$script:FocusCuesProp = $null
try { $script:FocusCuesProp = [System.Windows.Forms.Control].GetProperty('ShowFocusCues', [Reflection.BindingFlags]'NonPublic,Instance') } catch { $null = $_ } # falls back to showing focus cues
function Test-FocusCues($ctl) { try { [bool]$script:FocusCuesProp.GetValue($ctl) } catch { $true } }
function Set-ControlStyle($ctl, [string]$style, [bool]$on) {
    # SetStyle is protected: reflection lets a plain Panel take focus (rail rows) and double-buffer.
    try { [void][System.Windows.Forms.Control].GetMethod('SetStyle', [Reflection.BindingFlags]'NonPublic,Instance').Invoke($ctl, @([System.Windows.Forms.ControlStyles]$style, $on)) } catch { $null = $_ } # optional focus/double-buffer hint
}

$form = New-Object System.Windows.Forms.Form
$form.SuspendLayout()
Initialize-QraForm $form
$form.Text = "Quarantine Review Assistant $AppVersion - Host Launcher"
$form.Size = New-Object System.Drawing.Size(1180, 820)
$form.MinimumSize = New-Object System.Drawing.Size(1040, 720)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $C.Surface

# ---- header: navy gradient, title, and (added after scaling) the PC / Python / Sandbox pills
$header = New-Object System.Windows.Forms.Panel
$header.Dock = 'Top'; $header.Height = 78; $header.BackColor = $C.Header
Set-ControlStyle $header 'OptimizedDoubleBuffer' $true
$header.Add_Paint({ param($s, $e)
    if ($script:QraHighContrast -or $s.ClientRectangle.Width -le 0 -or $s.ClientRectangle.Height -le 0) { return }
    $br = New-Object System.Drawing.Drawing2D.LinearGradientBrush($s.ClientRectangle, $C.Header, $C.HeaderEnd, [single]90)
    $e.Graphics.FillRectangle($br, $s.ClientRectangle); $br.Dispose() })
$hTitle = New-Object System.Windows.Forms.Label
$hTitle.Text = 'Quarantine Review Assistant'
$hTitle.Font = $Fonts.Title; $hTitle.ForeColor = $C.HeaderText; $hTitle.BackColor = [System.Drawing.Color]::Transparent
$hTitle.AutoSize = $true; $hTitle.Location = New-Object System.Drawing.Point(22, 10)
$hSub = New-Object System.Windows.Forms.Label
$hSub.Text = 'Host launcher  |  checks this PC, then opens an offline, disposable Windows Sandbox for the review'
$hSub.Font = $Fonts.Sub; $hSub.ForeColor = $C.HeaderSub; $hSub.BackColor = [System.Drawing.Color]::Transparent
$hSub.AutoSize = $true; $hSub.Location = New-Object System.Drawing.Point(24, 46)
$header.Controls.AddRange(@($hTitle, $hSub))

# ---- footer
$footer = New-Object System.Windows.Forms.Label
$footer.Dock = 'Bottom'; $footer.Height = 34
$footer.TextAlign = 'MiddleLeft'; $footer.Padding = New-Object System.Windows.Forms.Padding(22, 0, 0, 0)
$footer.BackColor = $C.DangerSoft
$footer.ForeColor = $C.Danger
$footer.Text = 'Never open, extract or preview quarantined messages on this PC. The review happens only inside the Sandbox. This tool is not an antivirus and never declares a message safe.'

# ---- body: rail (left) + content pane (right)
$body = New-Object System.Windows.Forms.Panel
$body.Dock = 'Fill'; $body.BackColor = $C.Surface
$body.Padding = New-Object System.Windows.Forms.Padding(16, 16, 16, 12)
$rail = New-Object System.Windows.Forms.Panel
$rail.Dock = 'Left'; $rail.Width = 280; $rail.BackColor = $C.Surface
$railGap = New-Object System.Windows.Forms.Panel
$railGap.Dock = 'Left'; $railGap.Width = 16; $railGap.BackColor = $C.Surface
$pane = New-QraCard
$pane.Dock = 'Fill'

# ---- rail rows: badge + title + one-line summary. A row is focusable (Tab) and Enter, Space or a click opens its step.
$script:RailRows = @()
function New-RailRow([int]$n, [string]$title) {
    $row = New-Object System.Windows.Forms.Panel
    $row.BackColor = $C.Surface; $row.Cursor = [System.Windows.Forms.Cursors]::Hand
    $row.TabStop = $true
    Set-ControlStyle $row 'Selectable' $true
    Set-ControlStyle $row 'OptimizedDoubleBuffer' $true
    $row.AccessibleRole = 'PushButton'
    $badge = New-QraStepBadge $n
    $badge.Cursor = [System.Windows.Forms.Cursors]::Hand
    $t = New-Object System.Windows.Forms.Label
    $t.Text = $title; $t.Font = $Fonts.Row; $t.ForeColor = $C.Text; $t.BackColor = [System.Drawing.Color]::Transparent
    $t.AutoSize = $false; $t.UseMnemonic = $false; $t.Cursor = [System.Windows.Forms.Cursors]::Hand
    $sm = New-Object System.Windows.Forms.Label
    $sm.Text = $StepHints[$n - 1]; $sm.Font = $Fonts.RowSub; $sm.ForeColor = $C.TextMuted; $sm.BackColor = [System.Drawing.Color]::Transparent
    $sm.AutoSize = $false; $sm.UseMnemonic = $false; $sm.Cursor = [System.Windows.Forms.Cursors]::Hand
    $row.Controls.AddRange(@($badge, $t, $sm))
    $row.Tag = @{ Index = $n; Badge = $badge; Title = $t; Summary = $sm; Title0 = $title }
    $open = { Select-LauncherStep ([int]$this.Tag.Index) }
    $openChild = { Select-LauncherStep ([int]$this.Parent.Tag.Index) }
    $row.Add_Click($open)
    foreach ($kid in @($badge, $t, $sm)) { $kid.Add_Click($openChild) }
    $row.Add_KeyDown({ param($s, $e)
        if ($e.KeyCode -eq 'Enter' -or $e.KeyCode -eq 'Space') { Select-LauncherStep ([int]$s.Tag.Index); $e.Handled = $true; $e.SuppressKeyPress = $true } })
    $row.Add_GotFocus({ $this.Invalidate() })
    $row.Add_LostFocus({ $this.Invalidate() })
    $row.Add_Paint({ param($s, $e)
        $g = $e.Graphics; $idx = [int]$s.Tag.Index; $b = $s.Tag.Badge
        $sel = ($idx -eq $script:SelectedStep)
        $cx = $b.Left + [int]($b.Width / 2)
        $lw = [single][Math]::Max(2, (S 2))
        $states = $script:RailStates
        # connector between the badges: green once the step above it is done
        if ($idx -gt 1) {
            $col = if ($states[$idx - 2] -eq 'Done') { $C.Success } else { $C.Border }
            $pen = New-Object System.Drawing.Pen($col, $lw); $g.DrawLine($pen, $cx, 0, $cx, ($b.Top - (S 3))); $pen.Dispose()
        }
        if ($idx -lt 5) {
            $col = if ($states[$idx - 1] -eq 'Done') { $C.Success } else { $C.Border }
            $pen = New-Object System.Drawing.Pen($col, $lw); $g.DrawLine($pen, $cx, ($b.Bottom + (S 3)), $cx, $s.Height); $pen.Dispose()
        }
        if ($sel) {
            $pen = New-Object System.Drawing.Pen($C.Border); $g.DrawLine($pen, 0, 0, $s.Width, 0); $g.DrawLine($pen, 0, ($s.Height - 1), $s.Width, ($s.Height - 1)); $pen.Dispose()
            $br = New-Object System.Drawing.SolidBrush($C.Primary); $g.FillRectangle($br, 0, (S 8), (S 3), ($s.Height - (S 16))); $br.Dispose()
        }
        if ($s.Focused -and (Test-FocusCues $s)) {      # keyboard focus only, like the buttons
            $ring = [single](S 2)
            $pen = New-Object System.Drawing.Pen($C.Focus, $ring)
            $g.DrawRectangle($pen, [int]($ring), [int]($ring), ($s.Width - 2 * [int]$ring - 1), ($s.Height - 2 * [int]$ring - 1)); $pen.Dispose()
        }
    })
    $script:RailRows += $row
    $row
}
$railTitles = @('Prepare this PC', 'Check it in Defender', 'Download the message', 'Analyze in the Sandbox', 'Act in Defender and clean up')
$script:RailStates = @('Pending', 'Pending', 'Pending', 'Pending', 'Pending')
foreach ($ri in 1..5) { $rail.Controls.Add((New-RailRow $ri $railTitles[$ri - 1])) }

# ---- content pane: one panel per step, only the selected one is visible
$script:Step = @{}
function New-TextLabel([string]$text, $font, $color) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Font = $font; $l.ForeColor = $color; $l.BackColor = $C.Card
    $l.AutoSize = $false; $l.UseMnemonic = $false
    $l.Size = New-Object System.Drawing.Size(100, 20)
    $l
}
# A numbered sub-step: plain text, with an optional part shown in bold.
function New-SubStep([string]$text, [string]$bold = '') { @{ Text = $text; Bold = $bold } }
function New-StepPanel([int]$n, [string]$title, [string]$lead, [object[]]$subs = @()) {
    $p = New-Object System.Windows.Forms.Panel
    $p.Dock = 'Fill'; $p.BackColor = $C.Card; $p.AutoScroll = $true; $p.Visible = ($n -eq 1)
    $st = @{ Panel = $p; Subs = @() }
    $st.Eyebrow = New-TextLabel "STEP $n OF 5" $Fonts.Eyebrow $C.Primary
    $st.Title = New-TextLabel $title $Fonts.Pane $C.Text
    $st.Lead = New-TextLabel $lead $Fonts.Body $C.TextMuted
    $p.Controls.AddRange(@($st.Eyebrow, $st.Title, $st.Lead))
    $k = 0
    foreach ($sub in $subs) {
        $k++
        $item = @{ Text = $sub.Text; Bold = $sub.Bold }
        $item.Num = New-TextLabel "$k." $Fonts.BodyBold $C.Primary
        $item.Plain = New-TextLabel $sub.Text $Fonts.Body $C.Text
        $p.Controls.AddRange(@($item.Num, $item.Plain))
        $item.Rich = $null
        if ($sub.Bold) {
            # one line with the bold part inline, painted directly (labels pad their text, which would gap the pieces)
            $at = $sub.Text.IndexOf($sub.Bold)
            $parts = @(@($sub.Text.Substring(0, $at), $false), @($sub.Bold, $true), @($sub.Text.Substring($at + $sub.Bold.Length), $false))
            $segs = @()
            foreach ($part in $parts) {
                if (-not $part[0]) { continue }
                $segs += @{ Text = $part[0]; Font = $(if ($part[1]) { $Fonts.BodyBold } else { $Fonts.Body }) }
            }
            $rich = New-TextLabel '' $Fonts.Body $C.Text
            $rich.Tag = $segs; $rich.AccessibleName = $sub.Text; $rich.Visible = $false
            $rich.Add_Paint({ param($s, $e)
                $fl = [System.Windows.Forms.TextFormatFlags]::NoPadding -bor [System.Windows.Forms.TextFormatFlags]::SingleLine -bor [System.Windows.Forms.TextFormatFlags]::NoPrefix
                $x = 0
                foreach ($seg in $s.Tag) {
                    [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $seg.Text, $seg.Font, (New-Object System.Drawing.Point($x, 0)), $C.Text, $s.BackColor, $fl)
                    $x += Get-TextAdvance $seg.Text $seg.Font
                } })
            $item.Rich = $rich; $p.Controls.Add($rich)
        }
        $st.Subs += $item
    }
    $script:Step[$n] = $st
    $pane.Controls.Add($p)
    $st
}

# Step 1: Prepare this PC
$st1 = New-StepPanel 1 'Prepare this PC' 'Windows Sandbox needs a supported PC. These checks run automatically every time the launcher opens. A restart is needed after Windows Sandbox is installed.' @(
    (New-SubStep 'Wait for the checks to finish.'),
    (New-SubStep 'Fix any red item with the button on its row.'),
    (New-SubStep 'Click Check again after a restart or install.' 'Check again')
)
$checksPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$checksPanel.FlowDirection = 'TopDown'; $checksPanel.WrapContents = $false; $checksPanel.AutoScroll = $true
$checksPanel.BackColor = $C.Card
$checksNote = New-TextLabel 'Reading the Windows edition, virtualization, resources, Windows Sandbox and Python...' $Fonts.Body $C.TextMuted
$overall = New-Object System.Windows.Forms.Label
$overall.Font = $Fonts.Overall; $overall.TextAlign = 'MiddleLeft'; $overall.BackColor = $C.Card; $overall.UseMnemonic = $false
$recheck = New-QraButton 'Check again' 'Secondary' $QraGlyph.Refresh
$overallSpin = New-QraSpinner 28
$overallSpin.BackColor = $C.Card; Set-Shown $overallSpin $false
$st1.Panel.Controls.AddRange(@($checksPanel, $checksNote, $overallSpin, $overall, $recheck))

# Step 2: Check it in Defender
$st2 = New-StepPanel 2 'Check it in Defender' 'Look at the message in the portal before anything is downloaded. Many decisions can already be made there.' @(
    (New-SubStep 'Open the Defender quarantine page.'),
    (New-SubStep 'Check the quarantine reason, sender, recipients and the header/preview in the portal.'),
    (New-SubStep 'Do not release the message yet. Come back here when you have looked.')
)
$bPortal = New-QraButton 'Open Defender quarantine' 'Secondary' $QraGlyph.Globe
$bChecked = New-QraButton "I've checked it - next" 'Primary' $QraGlyph.Check
$st2.Panel.Controls.AddRange(@($bPortal, $bChecked))

# Step 3: Download the message
$st3 = New-StepPanel 3 'Download the message' 'The Sandbox reads the ZIP from the Incoming folder on this PC. Nothing is opened here.' @(
    (New-SubStep 'In the portal, select the message.'),
    (New-SubStep 'Choose ... More > Download message.' '... More > Download message'),
    (New-SubStep 'Type a password you will remember for the next few minutes.'),
    (New-SubStep 'Save the ZIP to the folder below. Do not open or extract it.'),
    (New-SubStep 'Optional: Fetch release requests saves the messages you tick straight into this folder.' 'Fetch release requests')
)
$incomingLbl = New-Object System.Windows.Forms.TextBox
$incomingLbl.ReadOnly = $true; $incomingLbl.Text = $Incoming; $incomingLbl.BorderStyle = 'FixedSingle'
$incomingLbl.BackColor = $C.Surface; $incomingLbl.Font = $Fonts.Body
$bOpenIncoming = New-QraButton 'Open folder' 'Secondary' $QraGlyph.Folder
$bCopyIncoming = New-QraButton 'Copy path' 'Secondary' $QraGlyph.Copy
$bFetch = New-QraButton 'Fetch release requests' 'Secondary' $QraGlyph.Mail
$incomingList = New-Object System.Windows.Forms.ListView
$incomingList.View = 'Details'; $incomingList.FullRowSelect = $true; $incomingList.HeaderStyle = 'Nonclickable'
[void]$incomingList.Columns.Add('Waiting for review', (S 290))
[void]$incomingList.Columns.Add('Size', (S 80))
[void]$incomingList.Columns.Add('Saved', (S 130))
$incomingSpin = New-QraSpinner 20
$incomingSpin.BackColor = $C.Card; Set-Shown $incomingSpin $false
$incomingHint = New-TextLabel '' $Fonts.Body $C.TextMuted
$st3.Panel.Controls.AddRange(@($incomingLbl, $bOpenIncoming, $bCopyIncoming, $bFetch, $incomingList, $incomingSpin, $incomingHint))

# Step 4: Analyze in the Sandbox
$st4 = New-StepPanel 4 'Analyze in the Sandbox' 'Networking is off. Report export makes the Reports folder writable. Compatibility mode uses the Windows default for clipboard sharing.' @(
    (New-SubStep 'Pick the options below. The defaults are right unless the Sandbox will not start.'),
    (New-SubStep 'Click Launch Sandbox review. The review window starts by itself after 20-60 seconds.' 'Launch Sandbox review'),
    (New-SubStep 'In the review window, select the ZIP, enter the download password, click Analyze.' 'Analyze')
)
$optReports = New-Object System.Windows.Forms.CheckBox
$optReports.Text = 'Let the Sandbox save reports and the decision log to the Reports folder on this PC'
$optReports.Checked = $true
$optProtected = New-Object System.Windows.Forms.CheckBox
$optProtected.Text = 'Protected Client mode (extra hardening; turn off if the Sandbox fails to start)'
$optCompat = New-Object System.Windows.Forms.CheckBox
$optCompat.Text = 'Compatibility mode (only if the Sandbox will not start; weaker isolation)'
foreach ($opt in @($optReports, $optProtected, $optCompat)) { $opt.Font = $Fonts.Body; $opt.ForeColor = $C.Text; $opt.BackColor = $C.Card; $opt.UseMnemonic = $false }
$optCompat.ForeColor = $C.Warning
$bLaunch = New-QraButton 'Launch Sandbox review' 'Primary' $QraGlyph.Play
$bAck = New-QraButton "I've recorded my decision - next" 'Secondary' $QraGlyph.Check
$launchSpin = New-QraSpinner 20
$launchSpin.BackColor = $C.Card; Set-Shown $launchSpin $false
$launchHint = New-TextLabel '' $Fonts.Body $C.TextMuted
$st4.Panel.Controls.AddRange(@($optReports, $optProtected, $optCompat, $bLaunch, $bAck, $launchSpin, $launchHint))

# Step 5: Act in Defender and clean up
$st5 = New-StepPanel 5 'Act in Defender and clean up' 'Your recorded decision appears below with a ready-to-paste block list.' @(
    (New-SubStep 'Follow the Decision tab from the Sandbox and carry the decision out in Defender.'),
    (New-SubStep 'Close the Sandbox window.'),
    (New-SubStep 'Delete the downloaded ZIP from Incoming.')
)
$doneNote = New-TextLabel 'All five steps are done. Review the next message when you are ready.' $Fonts.BodyBold $C.Success
Set-Shown $doneNote $false
$bNext = New-QraButton 'Review the next message' 'Primary' $QraGlyph.Mail
Set-Shown $bNext $false
$lastDec = New-Object System.Windows.Forms.Label
$lastDec.BackColor = $C.Surface; $lastDec.Padding = New-Object System.Windows.Forms.Padding(8, 6, 8, 6); $lastDec.Font = $Fonts.Body
$lastDec.UseMnemonic = $false
$bCopyBlock = New-QraButton 'Copy block list' 'Secondary' $QraGlyph.Copy
$bLog = New-QraButton 'Decisions log' 'Secondary'
$bReports = New-QraButton 'Reports folder' 'Secondary' $QraGlyph.Folder
$bClean = New-QraButton 'Delete Incoming...' 'Danger' $QraGlyph.Delete
$st5.Panel.Controls.AddRange(@($doneNote, $bNext, $lastDec, $bCopyBlock, $bLog, $bReports, $bClean))

$body.Controls.Add($pane)
$body.Controls.Add($railGap)
$body.Controls.Add($rail)
$form.Controls.Add($body)
$form.Controls.Add($footer)
$form.Controls.Add($header)

# ---- accessibility, tab order
foreach ($row in $script:RailRows) { Set-Access $row ("Step $($row.Tag.Index) of 5, $($row.Tag.Title0), not started") }
foreach ($k in 1..5) { Set-Access $script:Step[$k].Panel "Step $k of 5" }
Set-Access $checksPanel 'Readiness checks' 'One row per check, with its status word and an action button where one is needed'
Set-Access $recheck 'Check again'
Set-Access $bPortal 'Open Defender quarantine in the browser'
Set-Access $bChecked "I've checked it in Defender, go to the next step"
Set-Access $incomingLbl 'Incoming folder path'
Set-Access $bOpenIncoming 'Open the Incoming folder'; Set-Access $bCopyIncoming 'Copy the Incoming folder path'
Set-Access $bFetch 'Fetch release requests from Exchange Online and save the ones you tick into Incoming'
Set-Access $incomingList 'Files waiting for review'
Set-Access $optReports 'Let the Sandbox save reports to this PC'; Set-Access $optProtected 'Protected Client mode'; Set-Access $optCompat 'Compatibility mode, weaker isolation'
Set-Access $bLaunch 'Launch Sandbox review'
Set-Access $bAck "I've recorded my decision in the Sandbox, go to the next step"
Set-Access $bCopyBlock 'Copy block list'; Set-Access $bLog 'Open the decisions log'; Set-Access $bReports 'Open the Reports folder'; Set-Access $bClean 'Delete files in Incoming'
Set-Access $bNext 'Review the next message'
$rail.TabIndex = 0; $pane.TabIndex = 1
$ti = 0; foreach ($row in $script:RailRows) { $row.TabIndex = $ti++ }
$checksPanel.TabIndex = 0; $recheck.TabIndex = 1
$bPortal.TabIndex = 0; $bChecked.TabIndex = 1
$ti = 0; foreach ($tabCtl in @($incomingLbl, $bOpenIncoming, $bCopyIncoming, $bFetch, $incomingList)) { $tabCtl.TabIndex = $ti++ }
$ti = 0; foreach ($tabCtl in @($optReports, $optProtected, $optCompat, $bLaunch, $bAck)) { $tabCtl.TabIndex = $ti++ }
$ti = 0; foreach ($tabCtl in @($bNext, $bCopyBlock, $bLog, $bReports, $bClean)) { $tabCtl.TabIndex = $ti++ }
$form.ResumeLayout($false)
# The form font is applied AFTER ResumeLayout: setting it earlier makes every control without its own Font scale twice
# (an ambient-font change during AutoScale), e.g. labels would be 2.25x too big at 150 %.
$form.Font = New-Font 9.5
Limit-FormToScreen $form

# ---- header pills: created after scaling (they size themselves from their font), in a host that matches the gradient
$script:PillHost = New-Object System.Windows.Forms.Panel
$script:PillHost.BackColor = $C.Header
$script:Pills = @()
foreach ($pillName in @('PC', 'Python', 'Sandbox')) {
    $pl = New-QraPill 'INFO' $pillName
    $pl.Font = $Fonts.Pill
    if (-not $script:UiNative) { $pl.BackColor = $C.Card; $pl.Padding = (SPad 8 2 8 2) }   # plain label: needs its own light background on the navy header
    $script:PillHost.Controls.Add($pl)
    $script:Pills += $pl
}
$header.Controls.Add($script:PillHost)

# ---- layout. Runs after scaling, so every number here goes through S(); real container widths are used (no Anchor stretching).
$script:LayoutReady = $false
$script:InLayout = $false
$script:SelectedStep = 1

function Get-ButtonWidth($btn, [int]$min = 0) {
    $flags = [System.Windows.Forms.TextFormatFlags]::NoPadding -bor [System.Windows.Forms.TextFormatFlags]::SingleLine -bor [System.Windows.Forms.TextFormatFlags]::NoPrefix
    $tw = [System.Windows.Forms.TextRenderer]::MeasureText([string]$btn.Text, $btn.Font, (New-Object System.Drawing.Size([int]::MaxValue, 0)), $flags).Width
    $gw = 0
    if ($btn.GetType().FullName -eq 'QraUi.ModernButton' -and $btn.Glyph) { $gw = [int]($btn.Font.Height * 1.4) }
    [Math]::Max($min, $tw + $gw + (S 40))
}
function Set-Wrapped($lbl, [int]$x, [int]$y, [int]$w) {
    $lbl.SetBounds($x, $y, $w, ((Measure-Wrapped $lbl.Text $lbl.Font $w) + (S 4)))
    $lbl.Bottom
}
function Get-Blend([System.Drawing.Color]$from, [System.Drawing.Color]$to, [double]$t) {
    [System.Drawing.Color]::FromArgb([int]($from.R + ($to.R - $from.R) * $t), [int]($from.G + ($to.G - $from.G) * $t), [int]($from.B + ($to.B - $from.B) * $t))
}

function Update-HeaderLayout {
    $gap = S 8; $x = 0; $h = 0
    foreach ($pl in $script:Pills) { $h = [Math]::Max($h, $pl.Height) }
    foreach ($pl in $script:Pills) { $pl.Location = New-Object System.Drawing.Point($x, [int](($h - $pl.Height) / 2)); $x += $pl.Width + $gap }
    $hostW = [Math]::Max(1, $x - $gap)
    $top = S 16
    $script:PillHost.SetBounds(($header.ClientSize.Width - (S 24) - $hostW), $top, $hostW, $h)
    # the host is a flat colour: take the gradient colour at its vertical centre so no box shows
    if (-not $script:QraHighContrast) { $script:PillHost.BackColor = Get-Blend $C.Header $C.HeaderEnd (($top + $h / 2) / [Math]::Max(1, $header.ClientSize.Height)) }
}

function Update-RailLayout {
    $railW = $rail.ClientSize.Width
    $rowH = [Math]::Max((S 64), [Math]::Min((S 88), [int]($rail.ClientSize.Height / 5)))   # shrinks on a small screen so row 5 stays visible
    $badgeD = S 28
    $tx = S 56; $tw = [Math]::Max((S 80), $railW - $tx - (S 8))
    $i = 0
    foreach ($row in $script:RailRows) {
        $row.SetBounds(0, ($i * $rowH), $railW, $rowH)
        $tg = $row.Tag
        $tg.Badge.SetBounds((S 16), [int](($rowH - $badgeD) / 2), $badgeD, $badgeD)
        $ht = [Math]::Min((Measure-Wrapped $tg.Title.Text $tg.Title.Font $tw), (2 * $tg.Title.Font.Height)) + (S 2)
        $hs = [Math]::Min((Measure-Wrapped $tg.Summary.Text $tg.Summary.Font $tw), (2 * $tg.Summary.Font.Height)) + (S 2)
        $top = [int](($rowH - ($ht + (S 2) + $hs)) / 2)
        $tg.Title.SetBounds($tx, $top, $tw, $ht)
        $tg.Summary.SetBounds($tx, ($top + $ht + (S 2)), $tw, $hs)
        $i++
    }
}

# Eyebrow, title, lead and the numbered sub-steps. Returns the y below them.
function Set-StepHead($st, [int]$pad, [int]$tw) {
    $y = S 24
    $st.Eyebrow.SetBounds($pad, $y, $tw, (S 18)); $y += S 20
    $st.Title.SetBounds($pad, $y, $tw, (S 32)); $y += S 36
    $y = (Set-Wrapped $st.Lead $pad $y $tw) + (S 16)
    $numW = S 28
    $flags = [System.Windows.Forms.TextFormatFlags]::NoPadding -bor [System.Windows.Forms.TextFormatFlags]::SingleLine -bor [System.Windows.Forms.TextFormatFlags]::NoPrefix
    foreach ($item in $st.Subs) {
        $avail = $tw - $numW
        $item.Num.SetBounds($pad, $y, $numW, (S 22))
        $placed = $false
        if ($item.Rich) {
            # one line, with the bold part inline; if it does not fit, fall back to wrapped plain text
            $sum = 0
            foreach ($seg in $item.Rich.Tag) { $sum += Get-TextAdvance $seg.Text $seg.Font }
            if ($sum -le $avail) {
                $item.Rich.SetBounds(($pad + $numW + (S 3)), $y, ($sum + (S 4)), (S 22))
                $item.Rich.Invalidate()
                $placed = $true
            }
            $item.Rich.Visible = $placed
        }
        $item.Plain.Visible = -not $placed
        if ($placed) { $y += S 28 }
        else { $y = (Set-Wrapped $item.Plain ($pad + $numW) $y $avail) + (S 6) }
    }
    $y + (S 8)
}

function Update-StepContent([int]$n) {
    $st = $script:Step[$n]; $p = $st.Panel
    $w = $p.ClientSize.Width; $h = $p.ClientSize.Height
    $pad = S 28
    $cw = [Math]::Max((S 320), $w - 2 * $pad)
    $tw = [Math]::Min($cw, (S 620))
    $rw = [Math]::Min($cw, (S 760))
    $p.SuspendLayout()
    $y = Set-StepHead $st $pad $tw
    switch ($n) {
        1 {
            $barH = S 40
            $top = $y
            $hasRows = ($checksPanel.Controls.Count -gt 0)
            $checksPanel.SetBounds($pad, $top, $cw, [Math]::Max((S 120), $h - $top - $barH - (S 32)))
            $checksNote.Visible = -not $hasRows
            if (-not $hasRows) { [void](Set-Wrapped $checksNote $pad ($top + (S 8)) $tw) }
            $by = $checksPanel.Bottom + (S 16)
            $recheck.SetBounds(($pad + $cw - (Get-ButtonWidth $recheck (S 128))), $by, (Get-ButtonWidth $recheck (S 128)), $barH)
            $overallSpin.SetBounds($pad, ($by + [int](($barH - (S 28)) / 2)), (S 28), (S 28))
            $ox = if (Test-Shown $overallSpin) { $pad + (S 40) } else { $pad }
            $overall.SetBounds($ox, $by, [Math]::Max((S 120), $recheck.Left - $ox - (S 8)), $barH)
            $want = [Math]::Max((S 380), $checksPanel.ClientSize.Width - (S 24))
            foreach ($crow in @($checksPanel.Controls)) { if ($crow.Width -ne $want) { $crow.Width = $want; Fit-CheckRow $crow } }
        }
        2 {
            $bh = S 40
            $bPortal.SetBounds($pad, $y, (Get-ButtonWidth $bPortal), $bh)
            $bChecked.SetBounds(($bPortal.Right + (S 16)), $y, (Get-ButtonWidth $bChecked), $bh)
        }
        3 {
            $bh = S 36
            $wCopy = Get-ButtonWidth $bCopyIncoming; $wOpen = Get-ButtonWidth $bOpenIncoming
            $bCopyIncoming.SetBounds(($pad + $rw - $wCopy), $y, $wCopy, $bh)
            $bOpenIncoming.SetBounds(($bCopyIncoming.Left - (S 8) - $wOpen), $y, $wOpen, $bh)
            # Fetch sits left of Open folder when the path box keeps a usable width, else it gets its own row below.
            $wFetch = Get-ButtonWidth $bFetch
            $inline = (($bOpenIncoming.Left - (S 8) - $wFetch - (S 8) - $pad) -ge (S 220))
            if ($inline) {
                $bFetch.SetBounds(($bOpenIncoming.Left - (S 8) - $wFetch), $y, $wFetch, $bh)
                $boxRight = $bFetch.Left
            } else {
                $boxRight = $bOpenIncoming.Left
            }
            $incomingLbl.Width = [Math]::Max((S 120), $boxRight - (S 8) - $pad)
            $incomingLbl.Location = New-Object System.Drawing.Point($pad, ($y + [int](($bh - $incomingLbl.Height) / 2)))
            $y += $bh + (S 16)
            if (-not $inline) { $bFetch.SetBounds($pad, ($y - (S 8)), $wFetch, $bh); $y = $bFetch.Bottom + (S 16) }
            $hintH = (Measure-Wrapped $incomingHint.Text $incomingHint.Font ($rw - (S 28))) + (S 8)   # keep the hint under the list inside the card
            $listH = [Math]::Min((S 240), [Math]::Max((S 72), $h - $y - $hintH - (S 36)))
            $incomingList.SetBounds($pad, $y, $rw, $listH)
            $incomingList.Columns[1].Width = S 90; $incomingList.Columns[2].Width = S 140
            $incomingList.Columns[0].Width = [Math]::Max((S 120), $incomingList.ClientSize.Width - $incomingList.Columns[1].Width - $incomingList.Columns[2].Width - (S 4))
            $y = $incomingList.Bottom + (S 12)
            $hx = $pad
            if (Test-Shown $incomingSpin) { $incomingSpin.SetBounds($pad, ($y + (S 1)), (S 20), (S 20)); $hx = $pad + (S 28) }
            [void](Set-Wrapped $incomingHint $hx $y ($rw - ($hx - $pad)))
        }
        4 {
            foreach ($opt in @($optReports, $optProtected, $optCompat)) {
                $opt.Width = $tw
                $opt.Height = [Math]::Max((S 24), (Measure-Wrapped $opt.Text $opt.Font ($tw - (S 24))) + (S 4))
                $opt.Location = New-Object System.Drawing.Point($pad, $y); $y = $opt.Bottom + (S 4)
            }
            $y += S 16
            $bLaunch.SetBounds($pad, $y, (Get-ButtonWidth $bLaunch (S 232)), (S 44))
            $bAck.SetBounds(($bLaunch.Right + (S 16)), ($y + (S 2)), (Get-ButtonWidth $bAck), (S 40))
            $y = $bLaunch.Bottom + (S 16)
            $lx = $pad
            if (Test-Shown $launchSpin) { $launchSpin.SetBounds($pad, ($y + (S 1)), (S 20), (S 20)); $lx = $pad + (S 28) }
            if ($launchHint.Text) { [void](Set-Wrapped $launchHint $lx $y ($tw - ($lx - $pad))) } else { $launchHint.SetBounds($lx, $y, $tw, (S 4)) }
        }
        5 {
            if (Test-Shown $doneNote) { $y = (Set-Wrapped $doneNote $pad $y $tw) + (S 12) }
            if (Test-Shown $bNext) { $bNext.SetBounds($pad, $y, (Get-ButtonWidth $bNext (S 232)), (S 44)); $y = $bNext.Bottom + (S 16) }
            $lastDec.SetBounds($pad, $y, $tw, [Math]::Max((S 92), (Measure-Wrapped $lastDec.Text $lastDec.Font ($tw - (S 16))) + (S 20)))
            $y = $lastDec.Bottom + (S 16)
            $bh = S 36; $bx = $pad
            foreach ($btn in @($bCopyBlock, $bLog, $bReports)) { $bw = Get-ButtonWidth $btn; $btn.SetBounds($bx, $y, $bw, $bh); $bx += $bw + (S 8) }
            $y += $bh + (S 16)
            $bClean.SetBounds($pad, $y, (Get-ButtonWidth $bClean), $bh)
        }
    }
    $p.ResumeLayout($false)
    $script:ContentW = $w
}

function Update-StepLayout {
    if (-not $script:LayoutReady -or $script:InLayout) { return }
    $script:InLayout = $true
    try {
        Update-HeaderLayout
        Update-RailLayout
        $n = $script:SelectedStep
        Update-StepContent $n
        if ($script:Step[$n].Panel.ClientSize.Width -ne $script:ContentW) { Update-StepContent $n }   # a scroll bar appeared or went away
    } finally { $script:InLayout = $false }
}

function Select-LauncherStep([int]$n) {
    if ($n -lt 1 -or $n -gt 5) { return }
    $script:SelectedStep = $n
    $pane.SuspendLayout()
    $script:Step[$n].Panel.Visible = $true
    foreach ($k in 1..5) { if ($k -ne $n) { $script:Step[$k].Panel.Visible = $false } }
    $pane.ResumeLayout($true)
    foreach ($row in $script:RailRows) { $row.BackColor = if ([int]$row.Tag.Index -eq $n) { $C.Card } else { $C.Surface }; $row.Invalidate() }
    Update-StepLayout
}

$script:LayoutReady = $true   # resize handlers do nothing while the form is still being built and scaled
$form.Add_Resize({ Update-StepLayout })
$pane.Add_Resize({ Update-StepLayout })
foreach ($k in 1..5) { $script:Step[$k].Panel.Add_Resize({ Update-StepLayout }) }
Select-LauncherStep 1

# ================================================================= behaviour
$script:Checks = @()
$script:Busy = $null   # @{ Kind='python'|'sandbox'|'notepad'; Work/Process; RowId; ... } while a user-started task runs
$script:ReadinessWork = $null   # the work object while the readiness checks run in a runspace, else $null
$script:BusyRow = $null
$script:PendingRestart = $false
$script:ConfigStamp = $null
# Guided stepper session state (nothing is saved to disk: it is rebuilt from what the launcher can observe)
$script:DefenderChecked = $false       # step 2 clicked
$script:DecisionAcknowledged = $false  # "I've recorded my decision - next" (report export off)
$script:CleanedUp = $false             # decision made and Incoming emptied
$script:LaunchState = 'None'           # 'None' | 'Starting' | 'Vanished'
$script:LaunchStarted = $null
$script:SandboxSeen = $false
$script:Step4Seen = $false             # step 4 was done while Incoming still had files (so an emptied Incoming means clean-up)
$script:LastCurrent = 0
$script:IncomingFiles = @()
$script:IncomingSig = $null
$script:LastDecision = $null
$script:DecisionCurrent = $false
$script:IncomingWatcher = $null
$script:HashWork = $null
$script:HashWorkKey = $null
$script:IncomingHash = $null
$script:IncomingHashKey = $null

function Set-OverallBusy([string]$text) {
    $overall.Text = $text
    $overall.ForeColor = $C.Text
    Set-Shown $overallSpin $true
    Set-QraSpinner $overallSpin $true $text
    if ($script:LayoutReady) { Update-StepLayout }
}

function Set-Overall {
    Set-QraSpinner $overallSpin $false ''
    Set-Shown $overallSpin $false
    $blocking = @($script:Checks | Where-Object { $_.Blocking -and $_.Status -ne 'OK' })
    $warn = @($script:Checks | Where-Object { $_.Status -eq 'WARN' })
    if ($blocking.Count) {
        $overall.Text = "$(Get-QraGlyphText 'FAIL')  Not ready: fix the red item(s) above."
        $overall.ForeColor = $C.Danger
        $bLaunch.Enabled = $false
    } elseif ($warn.Count) {
        $overall.Text = "$(Get-QraGlyphText 'WARN')  Ready, with warnings."
        $overall.ForeColor = $C.Warning
        $bLaunch.Enabled = $true
    } else {
        $overall.Text = "$(Get-QraGlyphText 'OK')  This PC is ready."
        $overall.ForeColor = $C.Success
        $bLaunch.Enabled = $true
    }
    if ($script:Busy) { $bLaunch.Enabled = $false }
    if ($script:LayoutReady) { Update-StepLayout }
}

function Render-Checks {
    $checksPanel.SuspendLayout()
    foreach ($old in @($checksPanel.Controls)) { $old.Dispose() }   # Clear() would leave animated spinners registered
    $script:BusyRow = $null
    if (-not $script:RowFonts) { $script:RowFonts = @{ Icon = (Get-IconFont 14); Name = (New-Font 10 'Bold') } }
    $primaryTaken = $false; $firstBad = $null
    $glyphName = @{ OK = 'Check'; WARN = 'Warning'; FAIL = 'Cancel'; INFO = 'Info' }
    $w = [Math]::Max((S 380), $checksPanel.ClientSize.Width - (S 24))
    foreach ($ch in $script:Checks) {
        $row = New-Object System.Windows.Forms.Panel
        $row.Width = $w; $row.Height = (S 64)
        $row.Margin = (SPad 0 0 0 6)
        $row.BackColor = $C.Surface
        $busyRow = [bool]($script:Busy -and $script:Busy.RowId -and $script:Busy.RowId -eq $ch.Id)
        $icon = New-Object System.Windows.Forms.Label
        $icon.Text = if ($QraGlyph.Count) { $QraGlyph[$glyphName[[string]$ch.Status]] } else { Get-QraGlyphText ([string]$ch.Status) }
        $icon.Font = $script:RowFonts.Icon
        $icon.ForeColor = Get-QraStatusColor ([string]$ch.Status); $icon.TextAlign = 'MiddleCenter'
        $icon.Location = (SPoint 4 10); $icon.Size = (SSize 36 36)
        $icon.AccessibleName = @{ OK = 'Passed'; WARN = 'Warning'; FAIL = 'Failed'; INFO = 'Information' }[[string]$ch.Status]
        $name = New-Object System.Windows.Forms.Label
        $name.Text = $ch.Name; $name.Font = $script:RowFonts.Name; $name.ForeColor = $C.Text
        $name.Location = (SPoint 46 8); $name.AutoSize = $true
        $detail = New-Object System.Windows.Forms.Label
        $detail.Text = $ch.Detail; $detail.ForeColor = $C.TextMuted
        $detail.Location = (SPoint 46 28)
        $detailW = if ($ch.Action) { $w - (S 170) } else { $w - (S 56) }
        $detail.Size = New-Object System.Drawing.Size($detailW, (S 44))
        $row.Controls.AddRange(@($icon, $name, $detail))
        $spin = $null; $bar = $null
        if ($busyRow) {
            $icon.Visible = $false
            $spin = New-QraSpinner 28
            $spin.Size = (SSize 28 28); $spin.Location = (SPoint 8 14); $spin.BackColor = $row.BackColor
            $row.Controls.Add($spin)
            Set-QraSpinner $spin $true ([string]$ch.Detail)
            if ($script:Busy.Kind -eq 'python') {
                $bar = New-Object System.Windows.Forms.ProgressBar
                $bar.Style = 'Blocks'; $bar.Minimum = 0; $bar.Maximum = 1000; $bar.Value = 0
                $bar.Location = (SPoint 46 60); $bar.Size = (SSize 200 10); $bar.Visible = $false
                $bar.AccessibleName = 'Python download progress'
                $row.Controls.Add($bar)
            }
        }
        $btn = $null
        if ($ch.Action) {
            $variant = 'Secondary'
            if (-not $primaryTaken -and $ch.Blocking -and $ch.Status -in 'FAIL', 'WARN') { $variant = 'Primary'; $primaryTaken = $true }
            $btn = New-QraButton ([string]$ch.Action) $variant
            $btn.Tag = $ch.Id
            $btn.Size = (SSize 108 32)
            $btn.Location = New-Object System.Drawing.Point(($w - (S 116)), (S 20))
            $btn.AccessibleName = "$($ch.Action): $($ch.Name)"
            $btn.Enabled = ($null -eq $script:Busy) -and ($null -eq $script:ReadinessWork)
            $btn.Add_Click({ Invoke-CheckAction ([string]$this.Tag) ([string]$this.Text) })
            $row.Controls.Add($btn)
        }
        $row.Tag = @{ Detail = $detail; Btn = $btn; Bar = $bar; Spin = $spin; Mode = '' }
        $checksPanel.Controls.Add($row)
        if (-not $firstBad -and [string]$ch.Status -eq 'FAIL') { $firstBad = $row }
        if ($busyRow) { $script:BusyRow = $row }
        Fit-CheckRow $row
    }
    $checksPanel.ResumeLayout()
    if ($script:LayoutReady) { Update-StepLayout }
    # a red item must not hide below the fold of a short list
    if ($firstBad) { try { $checksPanel.ScrollControlIntoView($firstBad) } catch { $null = $_ } } # best-effort scroll when control is not yet laid out
}

function Set-RowButtons([bool]$enabled) {
    foreach ($row in @($checksPanel.Controls)) { if ($row.Tag -and $row.Tag.Btn) { $row.Tag.Btn.Enabled = $enabled } }
}

# Starts the readiness checks in a runspace: the window stays responsive and shows a spinner meanwhile.
function Start-ReadinessRefresh {
    if ($script:ReadinessWork) { return }
    $recheck.Enabled = $false
    $bLaunch.Enabled = $false
    Set-RowButtons $false
    Set-OverallBusy 'Checking this PC...'
    try {
        $script:ReadinessWork = Start-QraWork { Get-ReadinessChecks } -Variables (Get-ReadinessVariables) -Functions $ReadinessFunctions
    } catch {
        $script:ReadinessWork = $null
        $script:Checks = @(ConvertTo-ReadinessResult ([pscustomobject]@{ Error = $_.Exception.Message })) + @(Get-DisplayCheck)
        Render-Checks
        Set-Overall
        Set-RowButtons ($null -eq $script:Busy)
        $recheck.Enabled = ($null -eq $script:Busy)
        Update-Stepper
        return
    }
    Update-Stepper
    $timer.Start()
}

function Complete-ReadinessRefresh {
    $res = Complete-QraWork $script:ReadinessWork
    $script:ReadinessWork = $null
    $script:Checks = @(ConvertTo-ReadinessResult $res) + @(Get-DisplayCheck)
    Render-Checks
    Set-Overall
    $recheck.Enabled = ($null -eq $script:Busy)
    if ($script:PendingRestart) {
        $script:PendingRestart = $false
        foreach ($ch in $script:Checks) { if ($ch.Id -eq 'sandbox') { $ch.Status = 'WARN'; $ch.Detail = 'Installed. Windows must RESTART before the Sandbox can be used.'; $ch.Action = 'Restart now'; $ch.Blocking = $true } }
        Render-Checks; Set-Overall
        Update-Stepper
        Start-Restart
    } else {
        Update-Stepper
    }
}

function Get-IncomingPackages([string]$directory) {
    Get-ChildItem -LiteralPath $directory -File -Force -ErrorAction Stop |
        Where-Object { $_.Name -ne 'PLACE_ZIP_HERE.txt' } | Sort-Object LastWriteTime -Descending
}

function Refresh-Incoming {
    $script:IncomingReadFailed = $false
    try { $files = @(Get-IncomingPackages $Incoming) }
    catch { $files = @(); $script:IncomingReadFailed = $true }
    Show-IncomingFiles $files
    if ($script:IncomingReadFailed) {
        $incomingHint.Text = 'Incoming could not be read. Check that the folder exists and you can access it.'
        $incomingHint.ForeColor = $C.Warning
    }
}
# Fills the Incoming list, hint and spinner, and remembers the files for the step state. $files: Name, Length, LastWriteTime, Extension.
function Show-IncomingFiles($files) {
    $files = @($files | Where-Object { $_ })
    $script:IncomingFiles = $files
    $sig = ($files | ForEach-Object { '{0}|{1}|{2}' -f $_.Name, $_.Length, $_.LastWriteTime.Ticks }) -join ';'
    if ($sig -ne $script:IncomingSig) {      # rebuild only when something changed: no flicker, the selection survives
        $script:IncomingSig = $sig
        $incomingList.BeginUpdate()
        $incomingList.Items.Clear()
        foreach ($f in $files) {
            $it = New-Object System.Windows.Forms.ListViewItem($f.Name)
            [void]$it.SubItems.Add(('{0:N0} KB' -f [math]::Ceiling($f.Length / 1KB)))
            [void]$it.SubItems.Add($f.LastWriteTime.ToString('dd MMM HH:mm'))
            [void]$incomingList.Items.Add($it)
        }
        $incomingList.EndUpdate()
    }
    $wasEmpty = (Test-Shown $incomingSpin)
    Set-Shown $incomingSpin ($files.Count -eq 0)
    Set-QraSpinner $incomingSpin ($files.Count -eq 0) 'Watching Incoming for the download'
    if ($wasEmpty -ne ($files.Count -eq 0) -and $script:LayoutReady) { Update-StepLayout }
    if ($files.Count -eq 0) {
        $incomingHint.Text = 'Nothing here yet. Save the "Quarantined Messages.zip" download into this folder.'
        $incomingHint.ForeColor = $C.TextMuted
    } else {
        $other = @($files | Where-Object { $_.Extension -notin '.zip', '.eml' })
        if ($other.Count) {
            $incomingHint.Text = "$(Get-QraGlyphText 'WARN') $($other.Count) file(s) are not .zip/.eml. Keep only downloaded quarantine packages here."
            $incomingHint.ForeColor = $C.Warning
        } elseif ($files.Count -gt 1) {
            $incomingHint.Text = 'Keep one package in Incoming so the launcher can verify which decision applies.'
            $incomingHint.ForeColor = $C.Warning
        } else {
            $incomingHint.Text = "$($files.Count) file(s) ready. They are visible read-only inside the Sandbox as C:\Review\Incoming."
            $incomingHint.ForeColor = $C.Success
        }
    }
}

function Read-LastDecision([string]$directory) {
    try {
        $f = Get-ChildItem -LiteralPath $directory -File -Filter 'Decision-*.json' -ErrorAction Stop |
            Where-Object { $_.Name -notlike '*-report.json' } | Sort-Object LastWriteTimeUtc, Name -Descending | Select-Object -First 1
        if ($f -and -not ($f.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            $record = [IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json -ErrorAction Stop
            if ($record -is [pscustomobject] -and $record.final_decision -is [string] -and $record.final_decision.Trim()) { return $record }
        }
    } catch { $null = $_ } # unreadable or malformed decision JSON is treated as no decision
}

function Get-DecisionInputHash($d) {
    if ($d.record_complete -is [bool] -and $d.record_complete -and
        $d.input_sha256 -is [string] -and $d.input_sha256 -match '\A[0-9a-f]{64}\z' -and
        $d.final_decision -is [string] -and $d.final_decision.Trim()) { return $d.input_sha256 }
}

# Timestamps identify when to discard work. Only a hash of the bytes can match a record.
function Get-IncomingPackageKey($files) {
    if ($files.Count -ne 1) { return }
    $f = $files[0]
    if ($f.Extension -in '.zip', '.eml' -and -not ($f.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        return '{0}|{1}|{2}|{3}' -f $f.FullName, $f.Length, $f.CreationTimeUtc.Ticks, $f.LastWriteTimeUtc.Ticks
    }
}

function Clear-IncomingHash {
    $script:HashWorkKey = $null  # discard an in-flight result even if the path and timestamps were preserved
    $script:IncomingHashKey = $null
    $script:IncomingHash = $null
    $script:DecisionCurrent = $false
}

function Start-IncomingWatcher {
    if ($script:IncomingWatcher) { return }
    try {
        $watcher = New-Object IO.FileSystemWatcher $Incoming
        $watcher.SynchronizingObject = $form
        $watcher.NotifyFilter = 'FileName, Size, LastWrite, CreationTime, Attributes'
        $invalidate = { Clear-IncomingHash; Set-LastDecisionView }
        $watcher.add_Changed($invalidate); $watcher.add_Created($invalidate)
        $watcher.add_Deleted($invalidate); $watcher.add_Renamed($invalidate)
        $watcher.add_Error({
            Clear-IncomingHash; Set-LastDecisionView
            if ($script:IncomingWatcher) { $script:IncomingWatcher.Dispose(); $script:IncomingWatcher = $null }
        })
        $watcher.EnableRaisingEvents = $true
        $script:IncomingWatcher = $watcher
    } catch { if ($watcher) { $watcher.Dispose() } }
}

function Update-IncomingHash {
    Start-IncomingWatcher
    $key = Get-IncomingPackageKey $script:IncomingFiles
    if ($key -ne $script:IncomingHashKey -or -not $script:IncomingWatcher) {
        $script:IncomingHash = $null; $script:IncomingHashKey = $null
    }
    if ($script:HashWork) {
        if ($key -ne $script:HashWorkKey) { $script:HashWorkKey = $null }
        if (-not (Test-QraWork $script:HashWork)) { return }
        $result = Complete-QraWork $script:HashWork
        $script:HashWork = $null
        if ($key -and $key -eq $script:HashWorkKey -and $script:IncomingWatcher -and -not $result.Error) {
            $script:IncomingHash = [string]($result.Output | Select-Object -First 1)
            $script:IncomingHashKey = $key
        }
    }
    if (-not $key -or -not $script:IncomingWatcher -or $script:IncomingHash -or -not (Get-DecisionInputHash $script:LastDecision)) { return }
    try {
        $script:HashWorkKey = $key
        $script:HashWork = Start-QraWork {
            (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256 -ErrorAction Stop).Hash
        } -Variables @{ packagePath = $script:IncomingFiles[0].FullName }
    } catch { $script:HashWorkKey = $null }
}

function Refresh-LastDecision {
    Show-LastDecision (Read-LastDecision $Reports)
    Update-IncomingHash
}

function Show-LastDecision($d) {
    $script:LastDecision = $d
    if (-not $d) {
        $lastDec.Text = 'No decision recorded yet. In the Sandbox: Decision tab > Record decision (needs "save reports to this PC" ticked in step 4).'
        $lastDec.ForeColor = $C.TextMuted; $bCopyBlock.Enabled = $false
        return
    }
}
function Get-CopyBlockState([bool]$HasIocs, [bool]$DecisionCurrent, [bool]$ExportOn) {
    [pscustomobject]@{ Enabled = ($HasIocs -and $DecisionCurrent -and $ExportOn); Stale = (-not $DecisionCurrent) }
}
function Get-LastDecisionText($d, [bool]$stale) {
    $head = if ($stale) { "Previous decision (not for the current download) - $($d.recorded_local):  $($d.final_decision)" } else { "Last decision ($($d.recorded_local)):  $($d.final_decision)" }
    return ($head + "`r`n" +
            "Sender: $($d.sender)`r`nSubject: $($d.subject)`r`n" +
            "Tool said: $($d.tool_recommendation) (confidence $($d.confidence)); Microsoft: $($d.microsoft_verdict)")
}
function Set-LastDecisionView {
    $d = $script:LastDecision
    if (-not $d) { return }
    $io = $d.iocs
    $hasIocs = [bool]($io.sender -or $io.sender_domain -or $io.domains -or $io.urls -or $io.sha256 -or $d.spoof_pair)
    $st = Get-CopyBlockState $hasIocs ([bool]$script:DecisionCurrent) ([bool]$optReports.Checked)
    $lastDec.ForeColor = $C.Text
    $text = Get-LastDecisionText $d $st.Stale
    if ($lastDec.Text -ne $text) { $lastDec.Text = $text }
    $bCopyBlock.Enabled = $st.Enabled
}
function Get-VerifiedBlockList([string]$directory, [string]$reportsDir, $displayed) {
    $expected = Get-DecisionInputHash $displayed
    if (-not $expected) { return }
    $stream = $null
    try {
        $files = @(Get-IncomingPackages $directory)
        $key = Get-IncomingPackageKey $files
        if (-not $key) { return }
        # Deny writes and replacement while checking the package and rereading the displayed decision.
        $stream = [IO.File]::OpenRead($files[0].FullName)
        if ((Get-FileHash -InputStream $stream -Algorithm SHA256 -ErrorAction Stop).Hash -ne $expected) { return }
        $d = Read-LastDecision $reportsDir
        if ((Get-DecisionInputHash $d) -ne $expected -or $key -ne (Get-IncomingPackageKey @(Get-IncomingPackages $directory))) { return }
        $text = Get-BlockListText $d
        if ($text -ceq (Get-BlockListText $displayed)) { return $text }
    } catch { $null = $_ } finally { if ($stream) { $stream.Dispose() } } # hash/read failure falls back to no block list
}
function Get-BlockListText($d) {
    $io = $d.iocs
    $refang = { param($u) ([string]$u -replace '^hxxp', 'http' -replace '^fxp', 'ftp' -replace '\[\.\]', '.') }
    $L = @("# Block list from Quarantine Review Assistant - $($d.recorded_local) - decision: $($d.final_decision)",
           '# Paste into Defender > Policies & rules > Threat policies > Tenant Allow/Block Lists (block).', '')
    if ($d.spoof_pair -and [string]$d.final_decision -like 'Release*') {
        $L += '# SPOOF ALLOW PAIR (Tenant Allow/Block List > Spoofed senders > Add > Allow, External)'; $L += [string]$d.spoof_pair; $L += ''
        return ($L -join "`r`n")
    }
    if ($io.sender) { $L += '# Sender'; $L += [string]$io.sender; $L += '' }
    if ($io.sender_domain) { $L += '# Sender domain'; $L += [string]$io.sender_domain; $L += '' }
    $doms = @($io.domains | Where-Object { $_ }); if ($doms.Count) { $L += '# Link domains (URLs tab)'; $L += $doms; $L += '' }
    $urls = @($io.urls | Where-Object { $_ }); if ($urls.Count) { $L += '# Full URLs (live - do not click)'; $L += ($urls | ForEach-Object { & $refang $_ }); $L += '' }
    $sh = @($io.sha256 | Where-Object { $_ }); if ($sh.Count) { $L += '# File SHA256 (Files tab)'; $L += ($sh | ForEach-Object { ([string]$_).Split(' ')[0] }) }
    return ($L -join "`r`n")
}

function Set-RowBusy([string]$id, [string]$text) {
    foreach ($ch in $script:Checks) { if ($ch.Id -eq $id) { $ch.Status = 'INFO'; $ch.Detail = $text; $ch.Action = $null } }
    Render-Checks; Set-Overall
}

function Start-Restart {
    $ans = [System.Windows.Forms.MessageBox]::Show("Windows will restart in 30 seconds.`r`n`r`nSave your work in other programs first. After the restart, run Start-Here.cmd again to continue.`r`n`r`nRestart now?", 'Restart required', 'YesNo', 'Warning')
    if ($ans -eq 'Yes') {
        Start-Process -FilePath "$env:windir\System32\shutdown.exe" -ArgumentList '/r', '/t', '30', '/c', '"Restarting to finish enabling Windows Sandbox (Quarantine Review Assistant)"' -WindowStyle Hidden
        $form.Close()
    }
}

# Downloads the portable Python in a runspace. Reports $work.State.Stage ('Downloading' | 'Verifying' | 'Extracting')
# and $work.State.BytesDone / BytesTotal (long; BytesTotal is 0 while the size is unknown).
function Start-PythonDownload([string]$Url = $PyUrl, [string]$Sha = $PySha256, [string]$Dest = $PyDir) {
    Start-QraWork {
        $ErrorActionPreference = 'Stop'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $zip = Join-Path $env:TEMP ('qra-python-' + [guid]::NewGuid().ToString('N') + '.zip')
        $State.Stage = 'Downloading'; $State.BytesDone = [long]0; $State.BytesTotal = [long]0
        try {
            $req = [System.Net.WebRequest]::Create($url)
            if ($req -is [System.Net.HttpWebRequest]) { $req.Method = 'GET'; $req.Timeout = 30000; $req.ReadWriteTimeout = 30000 }
            $resp = $req.GetResponse()
            try {
                if ($resp.ContentLength -gt 0) { $State.BytesTotal = [long]$resp.ContentLength }
                $inStream = $resp.GetResponseStream()
                $outStream = [System.IO.File]::Create($zip)
                try {
                    $buf = New-Object byte[] 65536
                    while (($n = $inStream.Read($buf, 0, $buf.Length)) -gt 0) {
                        $outStream.Write($buf, 0, $n)
                        $State.BytesDone = [long]($State.BytesDone + $n)
                    }
                } finally { $outStream.Dispose(); $inStream.Dispose() }
            } finally { $resp.Close() }
            $State.Stage = 'Verifying'
            $h = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($h -ne $sha) { throw "SHA256 mismatch (expected $sha, got $h). Nothing was installed." }
            $State.Stage = 'Extracting'
            New-Item -ItemType Directory -Force -Path $dest | Out-Null
            Expand-Archive -LiteralPath $zip -DestinationPath $dest -Force
            if (-not (Test-Path -LiteralPath (Join-Path $dest 'python.exe'))) { throw 'python.exe missing after extraction.' }
            'OK'
        } finally { Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue }
    } -Variables @{ url = $Url; sha = $Sha; dest = $Dest }
}

# Updates the busy row's text (and the row height) without rebuilding the rows.
function Set-BusyRowText([string]$text) {
    $row = $script:BusyRow
    if ($row -and $row.Tag.Detail.Text -ne $text) { $row.Tag.Detail.Text = $text; Fit-CheckRow $row }
}

function Update-PythonProgress($work) {
    $row = $script:BusyRow
    if (-not $row) { return }
    $st = $work.State
    $stage = [string]$st.Stage
    $done = [long]$st.BytesDone; $total = [long]$st.BytesTotal
    $bar = $row.Tag.Bar; $spin = $row.Tag.Spin
    if (($stage -eq 'Downloading' -or -not $stage) -and $total -gt 0) {
        $mode = 'bar'
        $text = 'Downloading Python {0} - {1:N1} of {2:N1} MB' -f $PyVersion, ($done / 1MB), ($total / 1MB)
        if ($bar) { $bar.Value = [int][Math]::Min(1000, [Math]::Floor($done * 1000 / $total)) }
    } elseif ($stage -eq 'Verifying') { $mode = 'spin'; $text = "Verifying Python $PyVersion (SHA256)..."
    } elseif ($stage -eq 'Extracting') { $mode = 'spin'; $text = "Extracting Python $PyVersion..."
    } else { $mode = 'spin'; $text = "Downloading Python $PyVersion..." }
    if ($row.Tag.Mode -ne $mode) {
        $row.Tag.Mode = $mode
        if ($bar) { $bar.Visible = ($mode -eq 'bar') }
        if ($mode -eq 'bar') { Set-QraSpinner $spin $false ''; $spin.Visible = $false }
        else { $spin.Visible = $true; Set-QraSpinner $spin $true $text }
    }
    Set-BusyRowText $text
}

function Invoke-CheckAction([string]$id, [string]$label) {
    if ($script:Busy -or $script:ReadinessWork) { return }
    if ($label -eq 'Restart now') { Start-Restart; return }
    switch ($id) {
        'orgcfg' {
            Initialize-OrgConfig
            $p = $null
            try { $p = Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $ConfigFile + '"') -PassThru } catch { $null = $_ } # $p remains $null and the next line shows a manual fallback
            if (-not $p) { $overall.Text = "Notepad could not be started. Open $ConfigFile by hand, then click Check again."; $overall.ForeColor = $C.Warning; return }
            $script:Busy = @{ Kind = 'notepad'; Process = $p }
            [void](Test-ConfigChanged $ConfigFile ([ref]$script:ConfigStamp))
            $recheck.Enabled = $false; $bLaunch.Enabled = $false
            Set-RowButtons $false
            Set-OverallBusy 'Waiting for you to close Notepad...'
            $timer.Start()
        }
        'sandbox' {
            $msg = "This turns on the Windows feature 'Windows Sandbox'.`r`n`r`n" +
                   "- Windows will ask for administrator approval (UAC).`r`n" +
                   "- It takes 1-3 minutes.`r`n" +
                   "- This PC MUST RESTART before the Sandbox can be used.`r`n`r`nContinue?"
            if ([System.Windows.Forms.MessageBox]::Show($msg, 'Install Windows Sandbox', 'OKCancel', 'Information') -ne 'OK') { return }
            $result = Join-Path $env:TEMP ('qra-enable-' + [guid]::NewGuid().ToString('N') + '.json')
            try {
                $p = Start-Process -FilePath 'powershell.exe' -Verb RunAs -PassThru -ArgumentList @(
                    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + (Join-Path $AppDir 'Enable-Sandbox.ps1') + '"'), '-ResultFile', ('"' + $result + '"'))
            } catch {
                [System.Windows.Forms.MessageBox]::Show("Administrator approval was cancelled or is not available.`r`n`r`nAsk an administrator to run (elevated PowerShell):`r`nEnable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -All", 'Not installed', 'OK', 'Warning') | Out-Null
                return
            }
            $script:Busy = @{ Kind = 'sandbox'; Process = $p; Result = $result; Started = Get-Date; RowId = 'sandbox' }
            $recheck.Enabled = $false
            Set-RowBusy 'sandbox' 'Installing Windows Sandbox... (0 s)'
            $timer.Start()
        }
        'python' {
            $script:Busy = @{ Kind = 'python'; Started = Get-Date; RowId = 'python'; Work = (Start-PythonDownload) }
            $recheck.Enabled = $false
            Set-RowBusy 'python' "Downloading Python $PyVersion..."
            $timer.Start()
        }
    }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 100
$timer.Add_Tick({
    if ($script:ReadinessWork -and (Test-QraWork $script:ReadinessWork)) { Complete-ReadinessRefresh }
    $b = $script:Busy
    if (-not $b) { if (-not $script:ReadinessWork) { $timer.Stop() }; return }
    if ($b.Kind -eq 'python') {
        if (Test-QraWork $b.Work) {
            $res = Complete-QraWork $b.Work
            $script:Busy = $null
            $err = $res.Error
            if ($err -or -not (Test-Path -LiteralPath $PyExe)) {
                [System.Windows.Forms.MessageBox]::Show("Python download failed:`r`n$err`r`n`r`nManual option: download the 'Windows embeddable package (64-bit)' for Python $PyVersion from python.org, verify its SHA256, and extract it into:`r`n$PyDir", 'Download failed', 'OK', 'Error') | Out-Null
            }
            Start-ReadinessRefresh
        } else {
            Update-PythonProgress $b.Work
        }
    } elseif ($b.Kind -eq 'notepad') {
        $exited = $false
        try { $exited = $b.Process.HasExited } catch { $exited = $true }
        if (-not $exited) { $exited = Test-ConfigChanged $ConfigFile ([ref]$script:ConfigStamp) }   # saved: a Store Notepad may outlive its launcher process
        if ($exited) {
            $script:Busy = $null
            Start-ReadinessRefresh
        }
    } elseif ($b.Kind -eq 'sandbox') {
        $exited = $false
        try { $exited = $b.Process.HasExited } catch { $exited = (Test-Path -LiteralPath $b.Result) }
        if (-not $exited -and ((Get-Date) - $b.Started).TotalMinutes -gt 20) { $exited = $true }
        if (-not $exited) {
            Set-BusyRowText ('Installing Windows Sandbox... ({0} s)' -f [int]((Get-Date) - $b.Started).TotalSeconds)
        } else {
            $script:Busy = $null
            $res = $null
            try { $res = Get-Content -LiteralPath $b.Result -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null = $_ } # $res remains $null and triggers the fallback message
            Remove-Item -LiteralPath $b.Result -Force -ErrorAction SilentlyContinue
            if ($res -and $res.ok) {
                $script:PendingRestart = [bool]($res.restartNeeded -or (Test-RebootPending))
                Start-ReadinessRefresh
            } else {
                $why = if ($res) { $res.message } else { 'The installer window closed without a result.' }
                [System.Windows.Forms.MessageBox]::Show("Windows Sandbox could not be enabled:`r`n$why", 'Install failed', 'OK', 'Error') | Out-Null
                Start-ReadinessRefresh
            }
        }
    }
})

# ---------------------------------------------------------------- guided stepper: facts and rail
function Reset-LauncherSession {
    $script:DefenderChecked = $false; $script:DecisionAcknowledged = $false; $script:CleanedUp = $false
    $script:LaunchState = 'None'; $script:LaunchStarted = $null; $script:SandboxSeen = $false; $script:Step4Seen = $false
}

# What the launcher can observe right now. Incoming and Reports are read by their own refreshers (cached); only the
# Sandbox process list is queried here. Also advances the session state (Sandbox started or vanished, clean-up done).
function Get-LauncherFacts {
    $checks = @($script:Checks)
    $files = @($script:IncomingFiles | Where-Object { $_ })
    $incCount = $files.Count
    $expected = Get-DecisionInputHash $script:LastDecision
    $decisionCurrent = [bool]($expected -and $script:IncomingHash -eq $expected -and
        $script:IncomingHashKey -eq (Get-IncomingPackageKey $files))
    $acknowledged = $script:DecisionAcknowledged -and -not $optReports.Checked
    $running = (@(Get-SandboxProcess | Where-Object { $_ }).Count -gt 0)
    $checking = [bool]($script:ReadinessWork -or $script:Busy)

    # Sandbox lifecycle: Starting until a process appears; Vanished when it was seen, is gone, and no decision came with it
    if ($running) {
        $script:SandboxSeen = $true
        if ($script:LaunchState -ne 'None') { $script:LaunchState = 'None' }
    } elseif ($script:SandboxSeen) {
        $script:SandboxSeen = $false
        $script:LaunchState = if ($decisionCurrent -or $acknowledged) { 'None' } else { 'Vanished' }
    } elseif ($script:LaunchState -eq 'Starting' -and $script:LaunchStarted -and ((Get-Date) - $script:LaunchStarted).TotalSeconds -gt 120) {
        $script:LaunchState = 'Vanished'    # no Sandbox process ever appeared
    }

    # Clean-up: step 4 was done while Incoming had files, and now it is empty
    if ($script:CleanedUp -and $incCount -gt 0) { Reset-LauncherSession; $script:LastCurrent = 0 }     # a new download starts the next message (and may move the view forward again)
    elseif (-not $script:CleanedUp -and $script:Step4Seen -and $incCount -eq 0 -and -not $checking -and -not $script:IncomingReadFailed) { $script:CleanedUp = $true }
    $script:Step4Seen = ($incCount -gt 0) -and ($decisionCurrent -or $acknowledged)

    @{
        ChecksRunning = $checking
        BlockingCount = @($checks | Where-Object { $_.Blocking -and $_.Status -ne 'OK' }).Count
        WarnCount = @($checks | Where-Object { $_.Status -eq 'WARN' }).Count
        DefenderChecked = [bool]$script:DefenderChecked
        IncomingCount = $incCount
        DecisionCurrent = $decisionCurrent
        CheckSeconds = $(if ($script:ReadinessWork) { [int]([DateTime]::UtcNow - $script:ReadinessWork.Started).TotalSeconds } else { $null })
        LaunchSeconds = $(if ($script:LaunchState -eq 'Starting' -and $script:LaunchStarted) { [int]((Get-Date) - $script:LaunchStarted).TotalSeconds } else { $null })
        DecisionText = $(if ($decisionCurrent) { [string]$script:LastDecision.final_decision } else { '' })
        SandboxRunning = $running
        LaunchState = [string]$script:LaunchState
        ExportOn = [bool]$optReports.Checked
        DecisionAcknowledged = [bool]$acknowledged
        CleanedUp = [bool]$script:CleanedUp
    }
}

# Applies the step state to the rail, the header pills and the step panes. With -Facts (screenshots) nothing is queried.
function Update-Stepper([hashtable]$Facts = $null) {
    $live = ($null -eq $Facts)
    if ($live) { $Facts = Get-LauncherFacts }
    $script:DecisionCurrent = [bool]$Facts.DecisionCurrent
    Set-LastDecisionView
    $state = Get-LauncherStepState $Facts
    $words = @{ Pending = 'not started'; Current = 'current step'; Working = 'in progress'; Done = 'done'; Warning = 'needs attention'; Blocked = 'blocked' }
    $names = @()
    for ($i = 0; $i -lt 5; $i++) {
        $s = $state.Steps[$i]; $row = $script:RailRows[$i]
        $summary = [string]$s.Summary
        if ($i -eq 0 -and $live -and $script:Busy) {
            $summary = switch ($script:Busy.Kind) { 'python' { 'Downloading Python...' } 'sandbox' { 'Installing Windows Sandbox...' } 'notepad' { 'Waiting for Notepad...' } default { $summary } }
        }
        if (-not $summary) { $summary = $StepHints[$i] }
        $row.Tag.Summary.Text = $summary
        $row.Tag.Summary.ForeColor = switch ([string]$s.State) {
            'Done' { if ($i -eq 0 -and [int]$Facts.WarnCount -gt 0) { $C.Warning } else { $C.Success } }
            'Working' { $C.Primary } 'Blocked' { $C.Danger } 'Warning' { $C.Warning } 'Current' { $C.Text } default { $C.TextMuted }
        }
        $row.Tag.Title.ForeColor = if ([string]$s.State -eq 'Pending') { $C.TextMuted } else { $C.Text }
        Set-QraBadgeState $row.Tag.Badge ([string]$s.State)
        $row.AccessibleName = "Step $($s.Number) of 5, $($s.Title), $($words[[string]$s.State])"
        $names += [string]$s.State
    }
    $script:RailStates = $names
    foreach ($row in $script:RailRows) { $row.Invalidate() }

    # header pills
    $pillsBusy = if ($live) { [bool]$script:ReadinessWork } else { [bool]$Facts.ChecksRunning }
    $pl = @(Get-LauncherPills $script:Checks $pillsBusy)
    for ($i = 0; $i -lt 3; $i++) { Set-QraPill $script:Pills[$i] $pl[$i].Status $pl[$i].Text; $script:Pills[$i].AccessibleName = $pl[$i].Text }

    # step 4: the optional "recorded my decision" button and the launch status line
    Set-Shown $bAck (-not [bool]$Facts.ExportOn)
    $text = ''; $color = $C.TextMuted; $spin = $false
    if ([int]$Facts.BlockingCount -gt 0 -and -not $Facts.ChecksRunning) { $text = 'Complete step 1 (PC readiness) first.' }
    elseif ($Facts.SandboxRunning) { $text = 'Review in progress. Record your decision in the Sandbox, then come back here.'; $color = $C.Text; $spin = $true }
    elseif ($Facts.LaunchState -eq 'Starting') { $text = 'Starting... the review window opens inside the Sandbox in 20-60 s.'; $color = $C.Text; $spin = $true }
    elseif ($Facts.LaunchState -eq 'Vanished') { $text = if ($Facts.ExportOn) { 'The Sandbox closed before a decision reached this PC. Launch again to continue.' } else { "The Sandbox closed. Report export is off, so no decision reaches this PC. If you recorded your decision, click `"I've recorded my decision - next`"." }; $color = $C.Warning }
    $launchHint.Text = $text; $launchHint.ForeColor = $color
    Set-Shown $launchSpin $spin
    Set-QraSpinner $launchSpin $spin $text

    # step 5
    Set-Shown $bNext ([bool]$state.AllDone)
    Set-Shown $doneNote ([bool]$state.AllDone)

    # open the step the user has to act on; never move them backwards, and not while the checks are still running
    if (-not $Facts.ChecksRunning) {
        $eff = if ($state.AllDone) { 5 } else { [int]$state.Current }
        if ($eff -gt $script:LastCurrent) { Select-LauncherStep $eff }
        $script:LastCurrent = $eff
    }
    if ($script:LayoutReady) { Update-StepLayout }
}

$incomingTimer = New-Object System.Windows.Forms.Timer
$incomingTimer.Interval = 3000
$incomingTimer.Add_Tick({
    Refresh-Incoming; Refresh-LastDecision
    # organization.json saved in a Notepad that is still open: re-check (only when nothing else is running)
    if (-not $script:Busy -and -not $script:ReadinessWork -and (Test-ConfigChanged $ConfigFile ([ref]$script:ConfigStamp))) { Start-ReadinessRefresh }
    Update-Stepper
})

# Once a second while the readiness checks run or the Sandbox starts: the elapsed seconds in the status text and on the rail.
$waitTimer = New-Object System.Windows.Forms.Timer
$waitTimer.Interval = 1000
$waitTimer.Add_Tick({
    if ($script:ReadinessWork) {
        $secs = [int]([DateTime]::UtcNow - $script:ReadinessWork.Started).TotalSeconds
        $txt = 'Checking this PC...' + (Format-WaitSeconds $secs)
        if ($overall.Text -ne $txt) { $overall.Text = $txt }
        Update-Stepper
    } elseif ($script:LaunchState -eq 'Starting') { Update-Stepper }
})

# texts that change while the launcher runs may need another line: lay the steps out again
foreach ($lbl in @($launchHint, $lastDec, $incomingHint)) { $lbl.Add_TextChanged({ if ($script:LayoutReady) { Update-StepLayout } }) }
$recheck.Add_Click({ Start-ReadinessRefresh; Refresh-Incoming })
$bChecked.Add_Click({ $script:DefenderChecked = $true; Update-Stepper; Select-LauncherStep 3 })
$bAck.Add_Click({ $script:DecisionAcknowledged = $true; Update-Stepper; Select-LauncherStep 5 })
$bNext.Add_Click({ Reset-LauncherSession; Update-Stepper; Select-LauncherStep 2 })
$optReports.Add_CheckedChanged({ if (-not $Screenshot) { Update-Stepper } })
$bPortal.Add_Click({ Start-Process $QuarantineUrl })
$bOpenIncoming.Add_Click({ Start-Process explorer.exe -ArgumentList ('"' + $Incoming + '"') })
$bCopyIncoming.Add_Click({ [System.Windows.Forms.Clipboard]::SetText($Incoming); Show-QraCopied $bCopyIncoming })
# Modal, but the dialog works in its own runspace and polls with a timer, so this window's timers keep running while it is open.
$bFetch.Add_Click({
    try { Show-ReleaseRequestDialog -Incoming $Incoming -Owner $form }
    catch { [System.Windows.Forms.MessageBox]::Show("The release-request window hit an unexpected error:`r`n`r`n$($_.Exception.Message)", 'Quarantine Review Assistant', 'OK', 'Error') | Out-Null }
    Refresh-Incoming
    Update-Stepper
})
$bCopyBlock.Add_Click({
    if (-not $optReports.Checked -or -not $script:DecisionCurrent) { return }
    $text = Get-VerifiedBlockList $Incoming $Reports $script:LastDecision
    if (-not $text) {
        Clear-IncomingHash
        Refresh-Incoming; Refresh-LastDecision; Update-Stepper
        return
    }
    [System.Windows.Forms.Clipboard]::SetText($text)
    Show-QraCopied $bCopyBlock
})
function Open-DecisionLog([string]$directory) {
    $csv = Join-Path $directory 'decisions-log.csv'
    if (Test-Path -LiteralPath $csv -PathType Leaf) {
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\notepad.exe') -ArgumentList ('"' + $csv + '"')
    } else { [System.Windows.Forms.MessageBox]::Show('No decisions recorded yet.', 'Decisions log', 'OK', 'Information') | Out-Null }
}
$bLog.Add_Click({ Open-DecisionLog $Reports })
$bReports.Add_Click({
    New-Item -ItemType Directory -Force -Path $Reports | Out-Null
    Start-Process explorer.exe -ArgumentList ('"' + $Reports + '"')
})
$bClean.Add_Click({
    $files = @(Get-ChildItem -LiteralPath $Incoming -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'PLACE_ZIP_HERE.txt' })
    if (-not $files.Count) { [System.Windows.Forms.MessageBox]::Show('Incoming is already empty.', 'Clean up', 'OK', 'Information') | Out-Null; return }
    if (Get-SandboxProcess) {
        [System.Windows.Forms.MessageBox]::Show('Close the Windows Sandbox window first (it still has the folder open).', 'Clean up', 'OK', 'Warning') | Out-Null; return
    }
    $list = ($files | Select-Object -First 12 | ForEach-Object { '  - ' + $_.Name }) -join "`r`n"
    if ($files.Count -gt 12) { $list += "`r`n  ... and $($files.Count - 12) more" }
    if ([System.Windows.Forms.MessageBox]::Show("Permanently delete $($files.Count) file(s) from Incoming?`r`n`r`n$list`r`n`r`nOnly do this after you have made the release/delete decision in Defender.", 'Delete reviewed files', 'YesNo', 'Warning') -eq 'Yes') {
        $failed = @()
        foreach ($f in $files) { try { Remove-Item -LiteralPath $f.FullName -Force } catch { $failed += $f.Name } }
        if ($failed.Count) { [System.Windows.Forms.MessageBox]::Show("Could not delete:`r`n" + ($failed -join "`r`n"), 'Clean up', 'OK', 'Warning') | Out-Null }
        Refresh-Incoming
        Update-Stepper
    }
})
$optCompat.Add_CheckedChanged({ $optProtected.Enabled = -not $optCompat.Checked })

$bLaunch.Add_Click({
    if (Get-SandboxProcess) {
        [System.Windows.Forms.MessageBox]::Show('A Windows Sandbox window is already open. Close it (this discards its contents) and click Launch again.', 'Sandbox already running', 'OK', 'Warning') | Out-Null
        return
    }
    if (-not (Test-Path -LiteralPath $PyExe)) {
        [System.Windows.Forms.MessageBox]::Show('Download the analysis runtime first (step 1, "Analysis runtime").', 'Not ready', 'OK', 'Warning') | Out-Null
        return
    }
    if ($incomingList.Items.Count -eq 0) {
        if ([System.Windows.Forms.MessageBox]::Show('Incoming is empty. Launch the Sandbox anyway?', 'Nothing to review yet', 'YesNo', 'Question') -ne 'Yes') { return }
    }
    try {
        $wsb = Write-SandboxProfile $optReports.Checked $optProtected.Checked $optCompat.Checked
        $exe = Join-Path $env:windir 'System32\WindowsSandbox.exe'
        if (Test-Path -LiteralPath $exe) { Start-Process -FilePath $exe -ArgumentList ('"' + $wsb + '"') }
        else { Start-Process -FilePath $wsb }
        $script:LaunchState = 'Starting'; $script:LaunchStarted = Get-Date; $script:SandboxSeen = $false
        Update-Stepper
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Could not start Windows Sandbox:`r`n$($_.Exception.Message)`r`n`r`nTry again with 'Compatibility mode' ticked.", 'Launch failed', 'OK', 'Error') | Out-Null
    }
})

$checksPanel.Add_Resize({ if ($script:LayoutReady) { foreach ($ctl in $checksPanel.Controls) { $ctl.Width = [Math]::Max((S 380), $checksPanel.ClientSize.Width - (S 24)); Fit-CheckRow $ctl } } })
if (-not $Screenshot) { $form.Add_Shown({
    $form.Refresh()
    [void](Test-ConfigChanged $ConfigFile ([ref]$script:ConfigStamp))
    Refresh-Incoming        # Incoming and Reports first, so the first readiness result already lands on the right step
    Refresh-LastDecision
    Start-ReadinessRefresh
    $incomingTimer.Start(); $waitTimer.Start()
    Update-StepLayout
}) }
$form.Add_FormClosing({
    $incomingTimer.Stop(); $timer.Stop(); $waitTimer.Stop()
    # The release-request dialog is modal, so this should never find one. If it does, closing it signs out of Exchange Online (its FormClosing calls Close-RrSession).
    foreach ($owned in @($form.OwnedForms)) { try { $owned.Close() } catch { $null = $_ } } # best effort on the way out
    if ($script:IncomingWatcher) { $script:IncomingWatcher.Dispose() }
    foreach ($running in @($script:HashWork, $script:ReadinessWork, $(if ($script:Busy) { $script:Busy.Work }))) { if ($running) { Stop-QraWork $running } }
})
# ================================================================= -Screenshot <folder>
# Headless: applies each step state from built-in fake data and renders the window to <folder>\launcher-<state>.png.
# Never reads Incoming or Reports, never starts a timer, Python or the Sandbox, and never shows the window.
if ($Screenshot) {
    New-Item -ItemType Directory -Force -Path $Screenshot | Out-Null
    $shotTime = [datetime]'2026-11-25 10:42'
    $shotFile = [pscustomobject]@{ Name = 'Quarantined Messages.zip'; Length = 49152; LastWriteTime = $shotTime; Extension = '.zip' }
    $shotDecision = [pscustomobject]@{
        record_complete = $true; input_sha256 = ('a' * 64)
        recorded_local = '2026-11-25 10:58'; final_decision = 'Delete and block'; sender = 'billing@invoice-pay.example'
        subject = 'Invoice 4471 - action required'; tool_recommendation = 'Likely malicious'; confidence = 'High'; microsoft_verdict = 'Phish'
        iocs = [pscustomobject]@{ sender = 'billing@invoice-pay.example'; sender_domain = 'invoice-pay.example'; domains = @('invoice-pay.example'); urls = @(); sha256 = @() }
    }
    $shotOk = @(
        (New-Check 'edition' 'Windows edition' 'OK' 'Windows 11 Pro, build 26100'),
        (New-Check 'virt' 'CPU virtualization' 'OK' 'Hardware virtualization active (hypervisor running).'),
        (New-Check 'res' 'Memory / CPU / disk' 'OK' '16 GB RAM, 8 logical CPUs, 120 GB free on C: (minimum 4 GB, 2 CPUs, 1 GB).'),
        (New-Check 'sandbox' 'Windows Sandbox' 'OK' 'Installed and ready.'),
        (New-Check 'python' 'Analysis runtime' 'OK' 'Portable Python found in Tools\Python (used only inside the Sandbox).'),
        (New-Check 'folder' 'Tool folder' 'OK' 'D:\SecurityReview'),
        (New-Check 'orgcfg' 'Organisation settings' 'OK' '1 domain(s): example.com; 2 executive name(s).' 'Edit')
    )
    $shotNotReady = @(
        (New-Check 'edition' 'Windows edition' 'OK' 'Windows 11 Pro, build 26100'),
        (New-Check 'virt' 'CPU virtualization' 'OK' 'Hardware virtualization active (hypervisor running).'),
        (New-Check 'res' 'Memory / CPU / disk' 'OK' '16 GB RAM, 8 logical CPUs, 120 GB free on C: (minimum 4 GB, 2 CPUs, 1 GB).'),
        (New-Check 'sandbox' 'Windows Sandbox' 'FAIL' 'Not installed. Click "Install" (asks for administrator approval). A RESTART of this PC is required afterwards.' 'Install' $true),
        (New-Check 'python' 'Analysis runtime' 'FAIL' "Portable Python $PyVersion is missing (about 12 MB from python.org, SHA256-verified, no install)." 'Download' $true),
        (New-Check 'folder' 'Tool folder' 'OK' 'D:\SecurityReview'),
        (New-Check 'orgcfg' 'Organisation settings' 'OK' '1 domain(s): example.com; 2 executive name(s).' 'Edit')
    )
    $shotBase = @{
        ChecksRunning = $false; BlockingCount = 0; WarnCount = 0; DefenderChecked = $false; IncomingCount = 0
        DecisionCurrent = $false; DecisionText = ''; SandboxRunning = $false; LaunchState = 'None'; ExportOn = $true
        DecisionAcknowledged = $false; CleanedUp = $false
    }
    $withFile = @{ DefenderChecked = $true; IncomingCount = 1 }
    $ScreenshotStates = [ordered]@{
        'checks-running'     = @{ Checks = @(); Facts = @{ ChecksRunning = $true }; Select = 1 }
        'not-ready'          = @{ Checks = $shotNotReady; Facts = @{ BlockingCount = 2 }; Select = 1 }
        'ready'              = @{ Checks = $shotOk; Facts = @{}; Select = 2 }
        'watching-incoming'  = @{ Checks = $shotOk; Facts = @{ DefenderChecked = $true }; Select = 3 }
        'sandbox-starting'   = @{ Checks = $shotOk; Files = @($shotFile); Facts = $withFile + @{ LaunchState = 'Starting' }; Select = 4 }
        'review-in-progress' = @{ Checks = $shotOk; Files = @($shotFile); Facts = $withFile + @{ SandboxRunning = $true }; Select = 4 }
        'export-off'         = @{ Checks = $shotOk; Files = @($shotFile); Facts = $withFile + @{ ExportOn = $false }; Select = 4 }
        'decision-recorded'  = @{ Checks = $shotOk; Files = @($shotFile); Decision = $shotDecision
            Facts = $withFile + @{ DecisionCurrent = $true; DecisionText = 'Delete and block' }; Select = 5 }
        'all-done'           = @{ Checks = $shotOk; Files = @(); Decision = $shotDecision
            Facts = @{ DefenderChecked = $true; CleanedUp = $true }; Select = 5 }
    }
    function Show-SpinnerNow($sp) {
        if (-not (Test-Shown $sp)) { return }
        if ($sp.GetType().FullName -eq 'QraUi.Spinner') { $sp.ShowNow() } else { $sp.Text = ([string][char]0x00B7) * 3 }
    }
    $incomingLbl.Text = 'D:\SecurityReview\Incoming'     # neutral fake path: the real one is never shown in screenshots
    if ($ScreenshotMinSize) { $form.Size = $form.MinimumSize } elseif ($ScreenshotSize) { $form.Size = [System.Drawing.Size]$ScreenshotSize }
    # DrawToBitmap needs a created, shown form (WM_PRINT only reaches existing child windows), so it is shown off screen at Opacity 0 for the render only
    $form.ShowInTaskbar = $false; $form.Opacity = 0; $form.StartPosition = 'Manual'; $form.Location = New-Object System.Drawing.Point(-32000, -32000)
    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()
    foreach ($shotName in $ScreenshotStates.Keys) {
        $sd = $ScreenshotStates[$shotName]
        $facts = @{}; foreach ($k in $shotBase.Keys) { $facts[$k] = $shotBase[$k] }; foreach ($k in $sd.Facts.Keys) { $facts[$k] = $sd.Facts[$k] }
        $optReports.Checked = [bool]$facts.ExportOn
        $script:Checks = if ($sd.Checks.Count) { @($sd.Checks) + @(Get-DisplayCheck) } else { @() }
        Render-Checks
        if ($facts.ChecksRunning) { Set-OverallBusy 'Checking this PC...' } else { Set-Overall }
        Show-IncomingFiles $sd.Files
        Show-LastDecision $sd.Decision
        Update-Stepper $facts
        Select-LauncherStep ([int]$sd.Select)
        Update-StepLayout
        $form.ActiveControl = $null   # no keyboard focus ring in the pictures
        foreach ($sp in @($overallSpin, $incomingSpin, $launchSpin)) { Show-SpinnerNow $sp }
        $bmp = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
        $form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
        $bmp.Save((Join-Path $Screenshot "launcher-$shotName.png"), [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
    }
    $form.Dispose()
    # The release-request dialog, built from synthetic rows (no connection, no real data, no file access beyond this PNG).
    $rrDlg = New-RrDialog -Incoming 'D:\SecurityReview\Incoming' -NoAutoStart
    try {
        $rrDlg.Form.ShowInTaskbar = $false; $rrDlg.Form.Opacity = 0; $rrDlg.Form.StartPosition = 'Manual'
        $rrDlg.Form.Location = New-Object System.Drawing.Point(-32000, -32000)
        $rrDlg.Form.Show()
        [System.Windows.Forms.Application]::DoEvents()
        Set-RrScreenshotState $rrDlg 'results'
        $rrDlg.Form.ActiveControl = $null
        [System.Windows.Forms.Application]::DoEvents()
        $bmp = New-Object System.Drawing.Bitmap($rrDlg.Form.Width, $rrDlg.Form.Height)
        $rrDlg.Form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $rrDlg.Form.Width, $rrDlg.Form.Height)))
        $bmp.Save((Join-Path $Screenshot 'launcher-release-requests.png'), [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
    } finally {
        Stop-RrDialog $rrDlg
        $rrDlg.Form.Dispose()
    }
    exit 0
}

$ErrorActionPreference = 'Continue'
[void]$form.ShowDialog()
