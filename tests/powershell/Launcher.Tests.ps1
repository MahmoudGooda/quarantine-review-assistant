#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Pester 5. Host launcher (src/SecurityReview/app/Launcher.ps1). Launcher.ps1 runs UI code at top level, so it is never
# dot-sourced here: only its function definitions are extracted with the parser and defined.

BeforeAll {
    $script:Repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:LauncherPath = Join-Path $script:Repo 'src\SecurityReview\app\Launcher.ps1'
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    . (Join-Path $script:Repo 'src\SecurityReview\app\QraUi.ps1')

    $tokens = $null; $errs = $null
    $script:LauncherAst = [System.Management.Automation.Language.Parser]::ParseFile($script:LauncherPath, [ref]$tokens, [ref]$errs)
    $script:LauncherFunctions = @{}
    foreach ($fd in $script:LauncherAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $script:LauncherFunctions[$fd.Name] = $fd
    }
    $script:ImportedFns = New-Object System.Collections.Generic.List[string]
    function Import-LauncherFunction([string[]]$names) {
        foreach ($n in $names) {
            $fd = $script:LauncherFunctions[$n]
            if (-not $fd) { throw "Function $n not found in Launcher.ps1" }
            $script:ImportedFns.Add($n)
            # global: so Start-QraWork can read the body with Get-Item function:<name>
            . ([scriptblock]::Create(($fd.Extent.Text -replace '^function\s+', 'function global:')))
        }
    }

    $global:SandboxFeature = 'Containers-DisposableClientVM'
    $global:Root = $TestDrive
    $global:PyExe = Join-Path $TestDrive 'none.exe'
    $global:PyVersion = '3.14.8'
    $global:ConfigFile = Join-Path $TestDrive 'org.json'
}

AfterAll {
    # nothing this file defined may leak into the next test file of the same Pester run
    foreach ($n in $script:ImportedFns) { Remove-Item "function:global:$n" -ErrorAction SilentlyContinue }
    foreach ($n in 'SandboxFeature', 'Root', 'PyExe', 'PyVersion', 'ConfigFile', 'PyUrl', 'PySha256', 'PyDir', 'Calls', 'SeenChecks', 'recheck', 'bLaunch', 'timer', 'ReadinessFunctions') {
        Remove-Variable -Name $n -Scope Global -ErrorAction SilentlyContinue
    }
}

Describe 'Launcher: non-blocking readiness' {
    It 'readiness checks run in a runspace' {
        Import-LauncherFunction 'Get-ReadinessVariables'
        $fns = @('Get-ReadinessChecks', 'New-Check', 'Get-SandboxFeatureState', 'Test-SandboxClient', 'Test-RebootPending', 'Get-OrgConfigCheck', 'Get-SandboxProcess')
        Import-LauncherFunction $fns
        $work = Start-QraWork { Get-ReadinessChecks } -Variables (Get-ReadinessVariables) -Functions $fns
        $deadline = [DateTime]::UtcNow.AddSeconds(60)
        while (-not (Test-QraWork $work) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
        Test-QraWork $work | Should -BeTrue
        $res = Complete-QraWork $work
        # the real checks may report a non-terminating error on some PCs: the rows are what matters, not an empty Error
        @($res.Output).Count | Should -BeGreaterOrEqual 5
        $py = @($res.Output | Where-Object { $_.Id -eq 'python' })
        $py.Count | Should -Be 1
        $py[0].Status | Should -Be 'FAIL'
    }
    It 'readiness work failure becomes a WARN row' {
        Import-LauncherFunction 'ConvertTo-ReadinessResult', 'New-Check'
        $r = @(ConvertTo-ReadinessResult ([pscustomobject]@{ Output = @(); Error = 'WMI broken' }))
        $r.Count | Should -Be 1
        $r[0].Status | Should -Be 'WARN'
        $r[0].Id | Should -Be 'checks'
        $r[0].Detail | Should -Match 'WMI broken'
    }
    It 'a non-terminating error keeps every row, adds a WARN row and does not wipe the checks' {
        $fns = @('New-Check', 'ConvertTo-ReadinessResult')
        Import-LauncherFunction $fns
        $work = Start-QraWork { Write-Error 'x'; New-Check 'folder' 'Tool folder' 'FAIL' 'd' $null $true } -Functions @('New-Check')
        $deadline = [DateTime]::UtcNow.AddSeconds(60)
        while (-not (Test-QraWork $work) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
        $res = Complete-QraWork $work
        $res.Error | Should -Not -BeNullOrEmpty
        $r = @(ConvertTo-ReadinessResult $res)
        $folder = @($r | Where-Object { $_.Id -eq 'folder' })
        $folder.Count | Should -Be 1
        $folder[0].Status | Should -Be 'FAIL'
        $folder[0].Blocking | Should -BeTrue
        $warn = @($r | Where-Object { $_.Id -eq 'checks' })
        $warn.Count | Should -Be 1
        $warn[0].Status | Should -Be 'WARN'
        $warn[0].Detail | Should -Match 'x'
    }
    It 'an error with no rows at all is a blocking WARN row (Launch stays disabled)' {
        Import-LauncherFunction 'ConvertTo-ReadinessResult', 'New-Check'
        $r = @(ConvertTo-ReadinessResult ([pscustomobject]@{ Output = @(); Error = 'WMI broken' }))
        $r.Count | Should -Be 1
        $r[0].Blocking | Should -BeTrue
        $r = @(ConvertTo-ReadinessResult ([pscustomobject]@{ Error = 'no output property' }))
        $r.Count | Should -Be 1
        $r[0].Blocking | Should -BeTrue
    }
    It 'passes the output through when there is no error' {
        Import-LauncherFunction 'ConvertTo-ReadinessResult', 'New-Check'
        $r = @(ConvertTo-ReadinessResult ([pscustomobject]@{ Output = @((New-Check 'a' 'A' 'OK' 'x'), (New-Check 'b' 'B' 'OK' 'y')); Error = $null }))
        $r.Count | Should -Be 2
    }
}

Describe 'Launcher: Python download in a runspace' {
    BeforeAll {
        Import-LauncherFunction 'Start-PythonDownload'
        $global:PyUrl = 'x'; $global:PySha256 = 'x'; $global:PyDir = Join-Path $TestDrive 'unused'
        $script:Src = Join-Path $TestDrive 'src'; New-Item -ItemType Directory -Force -Path $script:Src | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Src 'python.exe') -Value 'stub'
        $script:Zip = Join-Path $TestDrive 'py.zip'
        Compress-Archive -Path (Join-Path $script:Src 'python.exe') -DestinationPath $script:Zip -Force
        $script:ZipUrl = ([Uri]$script:Zip).AbsoluteUri
        $script:ZipSha = (Get-FileHash -LiteralPath $script:Zip -Algorithm SHA256).Hash.ToLowerInvariant()
        function Wait-Work($work) {
            $deadline = [DateTime]::UtcNow.AddSeconds(60)
            while (-not (Test-QraWork $work) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
            Complete-QraWork $work
        }
    }
    It 'downloads, verifies and extracts, reporting bytes and stage' {
        $dest = Join-Path $TestDrive 'py-ok'
        $work = Start-PythonDownload -Url $script:ZipUrl -Sha $script:ZipSha -Dest $dest
        $res = Wait-Work $work
        $res.Error | Should -BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path $dest 'python.exe') | Should -BeTrue
        [long]$work.State.BytesDone | Should -Be (Get-Item -LiteralPath $script:Zip).Length
        [long]$work.State.BytesTotal | Should -Be (Get-Item -LiteralPath $script:Zip).Length
        $work.State.Stage | Should -Be 'Extracting'
    }
    It 'fails with the SHA256 mismatch text and installs nothing' {
        $dest = Join-Path $TestDrive 'py-bad'
        $work = Start-PythonDownload -Url $script:ZipUrl -Sha ('0' * 64) -Dest $dest
        $res = Wait-Work $work
        $res.Error | Should -Match 'SHA256 mismatch \(expected 0{64}, got [0-9a-f]{64}\)\. Nothing was installed\.'
        Test-Path -LiteralPath (Join-Path $dest 'python.exe') | Should -BeFalse
    }
}

Describe 'Launcher: display row and config watcher' {
    It 'display row names the display mode' {
        Import-LauncherFunction 'Get-DisplayCheck', 'New-Check'
        $on = Get-DisplayCheck $true ''
        $on.Id | Should -Be 'display'; $on.Name | Should -Be 'Display: enhanced'; $on.Detail | Should -Be 'Enhanced (painted controls)'
        $off = Get-DisplayCheck $false 'language mode ConstrainedLanguage'
        $off.Name | Should -Be 'Display: basic'; $off.Detail | Should -Be 'Basic (language mode ConstrainedLanguage)'
        $off.Status | Should -Be 'INFO'
    }
    It 'Test-ConfigChanged notices a save' {
        Import-LauncherFunction 'Test-ConfigChanged'
        $f = Join-Path $TestDrive 'watch.json'
        $stamp = $null
        Test-ConfigChanged $f ([ref]$stamp) | Should -BeFalse          # missing file
        Set-Content -LiteralPath $f -Value '{}'
        Test-ConfigChanged $f ([ref]$stamp) | Should -BeTrue           # appeared
        Test-ConfigChanged $f ([ref]$stamp) | Should -BeFalse          # unchanged
        (Get-Item -LiteralPath $f).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddMinutes(5)
        Test-ConfigChanged $f ([ref]$stamp) | Should -BeTrue           # saved
        Test-ConfigChanged $f ([ref]$stamp) | Should -BeFalse
    }
}

Describe 'Get-LauncherStepState' {
    BeforeAll {
        Import-LauncherFunction 'Get-LauncherStepState', 'Format-WaitSeconds'
        function New-Facts([hashtable]$over = @{}) {
            $f = @{
                ChecksRunning = $false; BlockingCount = 0; WarnCount = 0; DefenderChecked = $false
                IncomingCount = 0; NewestIncoming = $null; NewestDecision = $null; DecisionText = ''
                SandboxRunning = $false; LaunchState = 'None'; ExportOn = $true
                DecisionAcknowledged = $false; CleanedUp = $false
            }
            foreach ($k in $over.Keys) { $f[$k] = $over[$k] }
            $f
        }
    }
    It 'has the five titles' {
        $s = Get-LauncherStepState (New-Facts)
        @($s.Steps).Count | Should -Be 5
        (@($s.Steps) | ForEach-Object { $_.Title }) -join '|' | Should -Be 'Prepare this PC|Check it in Defender|Download the message|Analyze in the Sandbox|Act in Defender and clean up'
        (@($s.Steps) | ForEach-Object { $_.Number }) -join ',' | Should -Be '1,2,3,4,5'
    }
    It 'fresh PC with a failing check' {
        $s = Get-LauncherStepState (New-Facts @{ BlockingCount = 1 })
        $s.Steps[0].State | Should -Be 'Blocked'
        $s.Steps[0].Summary | Should -Be '1 item(s) to fix'
        $s.Current | Should -Be 1
        $s.AllDone | Should -BeFalse
        $s.Steps[1].State | Should -Be 'Pending'
    }
    It 'checks running' {
        $s = Get-LauncherStepState (New-Facts @{ ChecksRunning = $true })
        $s.Steps[0].State | Should -Be 'Working'
        $s.Steps[0].Summary | Should -Be 'Checking this PC...'
        $s.Current | Should -Be 1
    }
    It 'ready with warnings' {
        $s = Get-LauncherStepState (New-Facts @{ WarnCount = 2 })
        $s.Steps[0].State | Should -Be 'Done'
        $s.Steps[0].Summary | Should -Be 'Ready, with warnings'
    }
    It 'ready, nothing downloaded' {
        $s = Get-LauncherStepState (New-Facts)
        $s.Steps[0].Summary | Should -Be 'This PC is ready'
        $s.Current | Should -Be 2
        $s.Steps[1].State | Should -Be 'Current'
        $s.Steps[2].State | Should -Be 'Pending'
    }
    It 'defender checked, still watching Incoming' {
        $s = Get-LauncherStepState (New-Facts @{ DefenderChecked = $true })
        $s.Steps[1].State | Should -Be 'Done'
        $s.Steps[1].Summary | Should -Be 'Checked'
        $s.Current | Should -Be 3
        $s.Steps[2].State | Should -Be 'Working'
        $s.Steps[2].Summary | Should -Be 'Watching Incoming for the download...'
    }
    It 'ready with a file in Incoming' {
        $s = Get-LauncherStepState (New-Facts @{ IncomingCount = 1; NewestIncoming = (Get-Date) })
        $s.Steps[1].State | Should -Be 'Done'
        $s.Steps[2].State | Should -Be 'Done'
        $s.Steps[2].Summary | Should -Be '1 file(s) in Incoming'
        $s.Current | Should -Be 4
        $s.Steps[3].State | Should -Be 'Current'
    }
    It 'a verified decision advances the rail regardless of file dates' {
        $s = Get-LauncherStepState (New-Facts @{ IncomingCount = 1; DecisionCurrent = $true; NewestIncoming = (Get-Date); NewestDecision = (Get-Date).AddMinutes(-1) })
        $s.Steps[3].State | Should -Be 'Done'
        $s.Steps[3].Summary | Should -Be 'Decision recorded'
        $s.Current | Should -Be 5
    }
    It 'a newer timestamp alone cannot advance the rail' {
        $now = Get-Date
        $s = Get-LauncherStepState (New-Facts @{ IncomingCount = 1; NewestIncoming = $now; NewestDecision = $now.AddMinutes(1) })
        $s.Current | Should -Be 4
    }
    It 'reopened while running' {
        $s = Get-LauncherStepState (New-Facts @{ IncomingCount = 1; NewestIncoming = (Get-Date); SandboxRunning = $true })
        $s.Steps[3].State | Should -Be 'Working'
        $s.Steps[3].Summary | Should -Be 'Review in progress'
    }
    It 'starting' {
        $s = Get-LauncherStepState (New-Facts @{ IncomingCount = 1; NewestIncoming = (Get-Date); LaunchState = 'Starting' })
        $s.Steps[3].State | Should -Be 'Working'
        $s.Steps[3].Summary | Should -Be 'Starting Windows Sandbox...'
    }
    It 'vanished' {
        $s = Get-LauncherStepState (New-Facts @{ IncomingCount = 1; NewestIncoming = (Get-Date); LaunchState = 'Vanished' })
        $s.Steps[3].State | Should -Be 'Current'
        $s.Steps[3].Summary | Should -Match 'closed before a decision'
    }
    It 'export off, acknowledged' {
        $s = Get-LauncherStepState (New-Facts @{ IncomingCount = 1; NewestIncoming = (Get-Date); ExportOn = $false; DecisionAcknowledged = $true })
        $s.Steps[3].State | Should -Be 'Done'
        $s.Steps[3].Summary | Should -Be 'Decision recorded in the Sandbox'
        $s.Steps[4].Summary | Should -Match 'report export was off'
        $s.Current | Should -Be 5
    }
    It 'cleaned up' {
        $s = Get-LauncherStepState (New-Facts @{ CleanedUp = $true })
        $s.AllDone | Should -BeTrue
        $s.Current | Should -Be 0
        @($s.Steps | Where-Object { $_.State -ne 'Done' }).Count | Should -Be 0
    }
}

Describe 'Launcher: waits show elapsed seconds' {
    BeforeAll { Import-LauncherFunction 'Format-WaitSeconds', 'Get-LauncherStepState' }
    It 'Format-WaitSeconds is empty without a count and (n s) with one' {
        Format-WaitSeconds $null | Should -Be ''
        Format-WaitSeconds 0 | Should -Be ' (0 s)'
        Format-WaitSeconds 7 | Should -Be ' (7 s)'
    }
    It 'the rail summary for the readiness checks carries the seconds' {
        $f = @{ ChecksRunning = $true; BlockingCount = 0; WarnCount = 0; CheckSeconds = 12 }
        (Get-LauncherStepState $f).Steps[0].Summary | Should -Be 'Checking this PC... (12 s)'
        $f.Remove('CheckSeconds')
        (Get-LauncherStepState $f).Steps[0].Summary | Should -Be 'Checking this PC...'
    }
    It 'the rail summary for the Sandbox start carries the seconds' {
        $f = @{ IncomingCount = 1; NewestIncoming = (Get-Date); LaunchState = 'Starting'; LaunchSeconds = 31; BlockingCount = 0; WarnCount = 0; DefenderChecked = $true }
        (Get-LauncherStepState $f).Steps[3].Summary | Should -Be 'Starting Windows Sandbox... (31 s)'
    }
}

Describe 'Launcher: stale decision and the block list' {
    BeforeAll { Import-LauncherFunction 'Get-CopyBlockState', 'Get-LastDecisionText' }
    It 'copy is enabled only for a verified decision with something to block and export on' {
        (Get-CopyBlockState $true $true $true).Enabled | Should -BeTrue
        (Get-CopyBlockState $true $true $true).Stale | Should -BeFalse
        (Get-CopyBlockState $true $false $true).Enabled | Should -BeFalse
        (Get-CopyBlockState $true $false $true).Stale | Should -BeTrue
        (Get-CopyBlockState $true $true $false).Enabled | Should -BeFalse
        (Get-CopyBlockState $false $true $true).Enabled | Should -BeFalse
    }
    It 'the previous-decision label is exact' {
        $d = [pscustomobject]@{ recorded_local = 'x'; final_decision = 'Delete'; sender = 's'; subject = 'u'; tool_recommendation = 'a'; confidence = 'high'; microsoft_verdict = 'm' }
        (Get-LastDecisionText $d $true) | Should -Match '^Previous decision \(not for the current download\)'
        (Get-LastDecisionText $d $false) | Should -Match '^Last decision \(x\)'
    }
}

Describe 'Launcher: verify the package before copying' {
    BeforeAll {
        Import-LauncherFunction 'Get-IncomingPackages', 'Get-IncomingPackageKey', 'Read-LastDecision', 'Get-DecisionInputHash', 'Get-VerifiedBlockList', 'Get-BlockListText'
    }
    BeforeEach {
        $inbox = Join-Path $TestDrive 'Incoming'
        $reportsDir = Join-Path $TestDrive 'Reports'
        New-Item -ItemType Directory -Path $inbox, $reportsDir -Force | Out-Null
        $pkg = Join-Path $inbox 'review.zip'
        [IO.File]::WriteAllText($pkg, 'sample one')
        $digest = (Get-FileHash -LiteralPath $pkg -Algorithm SHA256).Hash
        $decision = [ordered]@{
            final_decision = 'Delete and block'; record_complete = $true; input_sha256 = $digest.ToLowerInvariant()
            iocs = @{ sender = 'sender@example.test' }
        }
        $record = Join-Path $reportsDir 'Decision-1.json'
        $decision | ConvertTo-Json | Set-Content -LiteralPath $record
    }
    It 'copies the displayed record for the matching package' {
        Get-VerifiedBlockList $inbox $reportsDir $decision | Should -Match 'sender@example.test'
    }
    It 'hashes off the UI thread, reuses a verified hash, and invalidates it on a same-size rewrite' {
        Import-LauncherFunction 'Start-IncomingWatcher', 'Update-IncomingHash', 'Clear-IncomingHash', 'Get-LauncherFacts', 'Get-SandboxProcess'
        $Incoming = $inbox
        $form = New-Object Windows.Forms.Form
        [void]$form.Handle
        function Set-LastDecisionView {}
        $optReports = @{ Checked = $true }
        $script:IncomingFiles = @(Get-IncomingPackages $inbox)
        $script:LastDecision = Read-LastDecision $reportsDir
        try {
            Update-IncomingHash
            $script:HashWork | Should -Not -BeNullOrEmpty
            $deadline = [DateTime]::UtcNow.AddSeconds(15)
            while (-not (Test-QraWork $script:HashWork) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
            Update-IncomingHash
            (Get-LauncherFacts).DecisionCurrent | Should -BeTrue
            Update-IncomingHash
            $script:HashWork | Should -BeNullOrEmpty
            $stamp = [IO.File]::GetLastWriteTimeUtc($pkg)
            [IO.File]::WriteAllText($pkg, 'sample two')
            [IO.File]::SetLastWriteTimeUtc($pkg, $stamp)
            $deadline = [DateTime]::UtcNow.AddSeconds(5)
            while ($script:IncomingHash -and [DateTime]::UtcNow -lt $deadline) {
                [Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 20
            }
            (Get-LauncherFacts).DecisionCurrent | Should -BeFalse
        } finally {
            if ($script:IncomingWatcher) { $script:IncomingWatcher.Dispose(); $script:IncomingWatcher = $null }
            if ($script:HashWork) { Stop-QraWork $script:HashWork; $script:HashWork = $null }
            Clear-IncomingHash
            $form.Dispose()
        }
    }
    It 'rejects a different package even with the same size and timestamp and a newer decision' {
        $stamp = (Get-Item -LiteralPath $pkg).LastWriteTimeUtc
        [IO.File]::WriteAllText($pkg, 'sample two')
        [IO.File]::SetLastWriteTimeUtc($pkg, $stamp)
        [IO.File]::SetLastWriteTimeUtc($record, $stamp.AddMinutes(1))
        Get-VerifiedBlockList $inbox $reportsDir $decision | Should -BeNullOrEmpty
    }
    It 'rejects an ambiguous or missing download' {
        $other = Join-Path $inbox 'other.eml'
        [IO.File]::WriteAllText($other, 'other')
        Get-VerifiedBlockList $inbox $reportsDir $decision | Should -BeNullOrEmpty
        Remove-Item -LiteralPath $pkg, $other
        Get-VerifiedBlockList $inbox $reportsDir $decision | Should -BeNullOrEmpty
    }
    It 'keeps legacy, partial and malformed records out of the current workflow' {
        $decision.Remove('record_complete')
        $decision | ConvertTo-Json | Set-Content -LiteralPath $record
        (Read-LastDecision $reportsDir).final_decision | Should -Be 'Delete and block'
        Get-VerifiedBlockList $inbox $reportsDir $decision | Should -BeNullOrEmpty
        $decision.record_complete = 'false'
        $decision | ConvertTo-Json | Set-Content -LiteralPath $record
        Get-VerifiedBlockList $inbox $reportsDir $decision | Should -BeNullOrEmpty
        '{' | Set-Content -LiteralPath $record
        Read-LastDecision $reportsDir | Should -BeNullOrEmpty
    }
    It 'rejects a removed or replaced report on Copy' {
        $displayed = Read-LastDecision $reportsDir
        $decision.iocs.sender = 'different@example.test'
        $decision | ConvertTo-Json | Set-Content -LiteralPath $record
        Get-VerifiedBlockList $inbox $reportsDir $displayed | Should -BeNullOrEmpty
        Remove-Item -LiteralPath $record
        Get-VerifiedBlockList $inbox $reportsDir $displayed | Should -BeNullOrEmpty
    }
}

Describe 'Launcher: decisions log' {
    It 'opens a CSV path with spaces as text in Notepad' {
        Import-LauncherFunction 'Open-DecisionLog'
        $dir = Join-Path $TestDrive 'review reports'
        New-Item -ItemType Directory $dir | Out-Null
        $csv = Join-Path $dir 'decisions-log.csv'
        Set-Content -LiteralPath $csv -Value 'decision'
        Mock Start-Process {}
        Open-DecisionLog $dir
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq (Join-Path $env:SystemRoot 'System32\notepad.exe') -and $ArgumentList -eq ('"' + $csv + '"')
        }
    }
}

Describe 'Launcher: header pills' {
    It 'summarises PC, Python and Sandbox' {
        Import-LauncherFunction 'Get-LauncherPills', 'New-Check'
        $ok = @((New-Check 'edition' 'Windows edition' 'OK' 'x'), (New-Check 'sandbox' 'Windows Sandbox' 'OK' 'x'), (New-Check 'python' 'Analysis runtime' 'OK' 'x'))
        $p = @(Get-LauncherPills $ok $false)
        $p.Count | Should -Be 3
        (@($p | ForEach-Object { $_.Name }) -join ',') | Should -Be 'PC,Python,Sandbox'
        @($p | Where-Object { $_.Status -ne 'OK' }).Count | Should -Be 0
        $bad = @((New-Check 'edition' 'Windows edition' 'OK' 'x'), (New-Check 'sandbox' 'Windows Sandbox' 'FAIL' 'x' 'Install' $true), (New-Check 'python' 'Analysis runtime' 'FAIL' 'x' 'Download' $true))
        $p = @(Get-LauncherPills $bad $false)
        ($p | Where-Object Name -eq 'Python').Status | Should -Be 'FAIL'
        ($p | Where-Object Name -eq 'Sandbox').Status | Should -Be 'FAIL'
        ($p | Where-Object Name -eq 'PC').Status | Should -Be 'OK'
        @(Get-LauncherPills $ok $true | Where-Object { $_.Status -ne 'BUSY' }).Count | Should -Be 0
    }
}

Describe 'Launcher: readiness start failure' {
    It 'a throw while starting the work renders a WARN row and re-enables the buttons' {
        Import-LauncherFunction 'Start-ReadinessRefresh', 'ConvertTo-ReadinessResult', 'Get-DisplayCheck', 'New-Check'
        $global:Calls = New-Object System.Collections.ArrayList
        $global:SeenChecks = $null
        $global:recheck = [pscustomobject]@{ Enabled = $true }
        $global:bLaunch = [pscustomobject]@{ Enabled = $true }
        $global:timer = [pscustomobject]@{}; $global:timer | Add-Member ScriptMethod Start { [void]$global:Calls.Add('timer') }
        $global:ReadinessFunctions = @()
        function global:Get-ReadinessVariables { @{} }
        function Start-QraWork { throw 'runspace boom' }   # local: the kit's own Start-QraWork sits in a nearer scope than a global stub
        function global:Set-RowButtons([bool]$enabled) { [void]$global:Calls.Add("rows:$enabled") }
        function global:Set-OverallBusy([string]$t) { [void]$global:Calls.Add('busy') }
        function global:Render-Checks { [void]$global:Calls.Add('render'); $global:SeenChecks = @($script:Checks) }
        function global:Set-Overall { [void]$global:Calls.Add('overall') }
        function global:Update-Stepper { [void]$global:Calls.Add('stepper') }
        try {
            { Start-ReadinessRefresh } | Should -Not -Throw
            $global:Calls | Should -Contain 'render'
            $global:Calls | Should -Contain 'stepper'
            $global:Calls | Should -Contain 'rows:True'
            $global:recheck.Enabled | Should -BeTrue
            $rows = @($global:SeenChecks)
            ($rows | Where-Object { $_.Id -eq 'checks' }).Status | Should -Be 'WARN'
            ($rows | Where-Object { $_.Id -eq 'checks' }).Detail | Should -Match 'runspace boom'
            ($rows | Where-Object { $_.Id -eq 'display' }) | Should -Not -BeNullOrEmpty
        } finally {
            foreach ($fn in 'Get-ReadinessVariables', 'Set-RowButtons', 'Set-OverallBusy', 'Render-Checks', 'Set-Overall', 'Update-Stepper') { Remove-Item "function:global:$fn" -ErrorAction SilentlyContinue }
        }
    }
}

Describe 'Launcher: step texts' {
    It 'step 3 sub-steps are exact' {
        $t = [IO.File]::ReadAllText($script:LauncherPath)
        $t.Contains('In the portal, select the message.') | Should -BeTrue -Because 'In the portal, select the message.'
        $t.Contains('... More > Download message') | Should -BeTrue -Because '... More > Download message'
        $t.Contains('Choose ... More > Download message.') | Should -BeTrue -Because 'Choose ... More > Download message.'
        $t.Contains('Type a password you will remember for the next few minutes.') | Should -BeTrue -Because 'Type a password you will remember for the next few minutes.'
        $t.Contains('Save the ZIP to the folder below. Do not open or extract it.') | Should -BeTrue -Because 'Save the ZIP to the folder below. Do not open or extract it.'
    }
}

Describe 'Launcher: -Screenshot' -Tag 'Screenshot' {
    BeforeAll {
        $script:ShotStates = 'checks-running', 'not-ready', 'ready', 'watching-incoming', 'sandbox-starting', 'review-in-progress', 'export-off', 'decision-recorded', 'all-done'
        function Invoke-LauncherShots([string]$dir, [string]$extra = '') {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:LauncherPath, '-Screenshot', $dir)
            if ($extra) { $psArgs += $extra.Split(' ') }
            $out = & powershell.exe @psArgs 2>&1
            [pscustomobject]@{ Exit = $LASTEXITCODE; Output = ($out | Out-String) }
        }
    }
    It 'screenshot mode writes every state' {
        $dir = Join-Path $TestDrive 'shots-native'
        $r = Invoke-LauncherShots $dir
        $r.Exit | Should -Be 0 -Because $r.Output
        foreach ($s in $script:ShotStates) { Test-Path -LiteralPath (Join-Path $dir "launcher-$s.png") | Should -BeTrue -Because $s }
    }
    It 'screenshot mode creates no Incoming or Reports folder' {
        # a copy of the app folder in an empty tool root: whatever the script creates next to it shows up there
        $root = Join-Path $TestDrive 'tool-root'
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:Repo 'src\SecurityReview\app') -Destination (Join-Path $root 'app') -Recurse
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'app\Launcher.ps1') -Screenshot (Join-Path $TestDrive 'shots-noio') 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($out | Out-String)
        Test-Path -LiteralPath (Join-Path $root 'Incoming') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $root 'Reports') | Should -BeFalse
    }
    It 'screenshot mode writes every state in fallback display mode' {
        $dir = Join-Path $TestDrive 'shots-fallback'
        $env:QRA_UI_FALLBACK = '1'
        try { $r = Invoke-LauncherShots $dir } finally { Remove-Item Env:\QRA_UI_FALLBACK -ErrorAction SilentlyContinue }
        $r.Exit | Should -Be 0 -Because $r.Output
        foreach ($s in $script:ShotStates) { Test-Path -LiteralPath (Join-Path $dir "launcher-$s.png") | Should -BeTrue -Because $s }
    }
}
