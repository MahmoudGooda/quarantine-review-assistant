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

Describe 'Launcher: decision cards (step 5)' {
    BeforeAll {
        Import-LauncherFunction 'Get-DecisionTone', 'Get-DecisionCards', 'Get-DecisionHeading', 'Get-Step5Wording'
        function New-Dec([string]$final, [string]$subject = 'Invoice') { [pscustomobject]@{ final_decision = $final; confidence = 'High'; recorded_local = '2026-11-25 10:58'; sender = 's@x.example'; subject = $subject; tool_recommendation = 'Likely malicious'; microsoft_verdict = 'Phish' } }
    }
    It 'maps every decision the Sandbox records to a tone' {
        Get-DecisionTone 'Delete and block' | Should -Be 'Danger'
        Get-DecisionTone 'Delete (unwanted, no block)' | Should -Be 'Danger'
        Get-DecisionTone 'Release (false positive, submitted to Microsoft)' | Should -Be 'Success'
        Get-DecisionTone 'Release to user (bulk / marketing)' | Should -Be 'Success'
        Get-DecisionTone 'Keep quarantined (pending verification)' | Should -Be 'Warning'
        Get-DecisionTone 'Something new' | Should -Be 'Info'
        Get-DecisionTone '' | Should -Be 'Info'
        Get-DecisionTone $null | Should -Be 'Info'
    }
    It 'builds one card per reviewed package plus a slim card for each package without a decision' {
        $cards = @(Get-DecisionCards @([pscustomobject]@{ FileName = 'b.zip'; Decision = (New-Dec 'Release') }, [pscustomobject]@{ FileName = 'a.zip'; Decision = (New-Dec 'Delete and block') }) @('a.zip', 'b.zip', 'c.eml') $null $false)
        $cards.Count | Should -Be 3
        $cards[0].File | Should -Be 'a.zip'; $cards[0].Tone | Should -Be 'Danger'; $cards[0].Confidence | Should -Be 'High confidence'
        $cards[0].Tool | Should -Match '^Tool: Likely malicious .+ Microsoft: Phish$'
        $cards[0].Accessible | Should -Match 'Delete and block.*Subject: Invoice.*From: s@x\.example'
        $cards[1].Tone | Should -Be 'Success'
        $cards[2].Kind | Should -Be 'Pending'; $cards[2].File | Should -Be 'c.eml'; $cards[2].Tool | Should -Be 'Launch the Sandbox again to review it.'
        Get-DecisionHeading $cards | Should -Be '2 of 3 messages reviewed'
    }
    It 'headings are singular or plural, and a stale decision is a previous-decision card without heading' {
        Get-DecisionHeading @(Get-DecisionCards @([pscustomobject]@{ FileName = 'a.zip'; Decision = (New-Dec 'Release') }) @('a.zip') $null $false) | Should -Be 'Decision recorded'
        Get-DecisionHeading @(Get-DecisionCards @([pscustomobject]@{ FileName = 'a.zip'; Decision = (New-Dec 'Release') }, [pscustomobject]@{ FileName = 'b.zip'; Decision = (New-Dec 'Release') }) @('a.zip', 'b.zip') $null $false) | Should -Be '2 decisions recorded'
        $old = @(Get-DecisionCards @() @() (New-Dec 'Delete and block') $true)
        $old.Count | Should -Be 1; $old[0].Kind | Should -Be 'Previous'
        $old[0].Accessible | Should -Match '^Previous decision, not for the current download'
        Get-DecisionHeading $old | Should -Be ''
        @(Get-DecisionCards @() @() $null $false).Count | Should -Be 0
    }
    It 'keeps a subject on one line and survives missing fields' {
        $c = @(Get-DecisionCards @() @() ([pscustomobject]@{ final_decision = ''; subject = "two`r`nlines" }) $false)[0]
        $c.Subject | Should -Be 'two lines'; $c.From | Should -Be 'From (no sender)'; $c.Tool | Should -Be ''; $c.Decision | Should -Be 'Decision recorded'
    }
    It 'step 5 wording follows the number of packages' {
        (Get-Step5Wording $false).Lead | Should -Be 'Your recorded decision appears below with a ready-to-paste block list.'
        (Get-Step5Wording $false).Delete | Should -Be 'Delete the downloaded ZIP from Incoming.'
        (Get-Step5Wording $true).Lead | Should -Be 'Your recorded decisions appear below with a ready-to-paste block list.'
        (Get-Step5Wording $true).Delete | Should -Be 'Delete the downloaded ZIPs from Incoming.'
    }
}

Describe 'Launcher: verify the package before copying' {
    BeforeAll {
        Import-LauncherFunction 'Get-IncomingPackages', 'Get-IncomingPackageKey', 'Get-IncomingFileKey', 'Read-LastDecision', 'Read-DecisionMap', 'Get-DecisionInputHash', 'Get-VerifiedBlockList', 'Get-BlockListText', 'Get-CombinedBlockListText'
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
        Import-LauncherFunction 'Start-IncomingWatcher', 'Update-IncomingHash', 'Clear-IncomingHash', 'Get-LauncherFacts', 'Get-SandboxProcess', 'Get-ReviewedPackages', 'Test-RunProducedDecision', 'Get-IncomingPackagePaths'
        $Incoming = $inbox
        $form = New-Object Windows.Forms.Form
        [void]$form.Handle
        function Set-LastDecisionView {}
        $optReports = @{ Checked = $true }
        $script:IncomingFiles = @(Get-IncomingPackages $inbox)
        $script:LastDecision = Read-LastDecision $reportsDir
        $script:DecisionMap = Read-DecisionMap $reportsDir
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
            while ($script:IncomingHashKey -and [DateTime]::UtcNow -lt $deadline) {
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
    It 'verifies against the package it belongs to when other packages are present, and rejects a missing download' {
        $other = Join-Path $inbox 'other.eml'
        [IO.File]::WriteAllText($other, 'other')
        Get-VerifiedBlockList $inbox $reportsDir $decision | Should -Match 'sender@example.test'
        Remove-Item -LiteralPath $pkg
        Get-VerifiedBlockList $inbox $reportsDir $decision | Should -BeNullOrEmpty -Because 'the other package is not the one the decision is for'
        Remove-Item -LiteralPath $other
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

Describe 'Launcher: several packages in Incoming' {
    BeforeAll {
        Import-LauncherFunction 'Get-LauncherStepState', 'Format-WaitSeconds'
        Import-LauncherFunction 'Get-IncomingPackages', 'Get-IncomingFileKey', 'Get-IncomingPackageKey', 'Get-IncomingPackagePaths', 'Read-DecisionMap', 'Get-DecisionInputHash',
            'Get-DecisionSnapshot', 'Test-RunProducedDecision', 'Get-ReviewedPackages', 'Get-BlockListText', 'Get-CombinedBlockListText', 'Get-VerifiedBlockList',
            'Get-ReviewedDecisionsText', 'Get-LastDecisionText'
        function New-Facts([hashtable]$over = @{}) {
            $f = @{
                ChecksRunning = $false; BlockingCount = 0; WarnCount = 0; DefenderChecked = $true
                IncomingCount = 2; ReviewedCount = 0; DecisionCurrent = $false; PartialContinued = $false; DecisionText = ''
                SandboxRunning = $false; LaunchState = 'None'; ExportOn = $true
                DecisionAcknowledged = $false; CleanedUp = $false
            }
            foreach ($k in $over.Keys) { $f[$k] = $over[$k] }
            $f
        }
        function New-Package([string]$dir, [string]$name, [string]$content) {
            $path = Join-Path $dir $name
            [IO.File]::WriteAllText($path, $content)
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        function New-DecisionFile([string]$dir, [string]$name, [string]$hash, [string]$decision = 'Delete and block', [hashtable]$extra = @{}) {
            $rec = [ordered]@{ final_decision = $decision; record_complete = $true; input_sha256 = $hash; recorded_local = '2026-11-25 10:58'; confidence = 'High' }
            foreach ($k in $extra.Keys) { $rec[$k] = $extra[$k] }
            $path = Join-Path $dir $name
            $rec | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path
            $path
        }
    }

    Context 'step 4 with two files' {
        It 'nothing reviewed: step 4 waits for the first review' {
            $s = Get-LauncherStepState (New-Facts)
            $s.Steps[3].State | Should -Be 'Current'
            $s.Steps[3].Summary | Should -Be ''
            $s.Current | Should -Be 4
        }
        It 'one of two reviewed, Sandbox closed: partial, stays on step 4' {
            $s = Get-LauncherStepState (New-Facts @{ ReviewedCount = 1; DecisionCurrent = $true; DecisionText = 'Delete and block' })
            $s.Steps[3].State | Should -Be 'Current'
            $s.Steps[3].Summary | Should -Be '1 of 2 messages reviewed'
            $s.Current | Should -Be 4
        }
        It 'one of two reviewed, a failed later run: still partial, the warning is in the launch hint, not the summary' {
            $s = Get-LauncherStepState (New-Facts @{ ReviewedCount = 1; DecisionCurrent = $true; LaunchState = 'Vanished' })
            $s.Steps[3].Summary | Should -Be '1 of 2 messages reviewed'
        }
        It 'one of two reviewed, Sandbox running: review in progress' {
            $s = Get-LauncherStepState (New-Facts @{ ReviewedCount = 1; DecisionCurrent = $true; SandboxRunning = $true })
            $s.Steps[3].State | Should -Be 'Working'
            $s.Steps[3].Summary | Should -Be 'Review in progress'
        }
        It 'none reviewed, Sandbox running or starting' {
            (Get-LauncherStepState (New-Facts @{ SandboxRunning = $true })).Steps[3].Summary | Should -Be 'Review in progress'
            (Get-LauncherStepState (New-Facts @{ LaunchState = 'Starting' })).Steps[3].Summary | Should -Be 'Starting Windows Sandbox...'
        }
        It 'two of two reviewed: done, step 5 says how many decisions' {
            $s = Get-LauncherStepState (New-Facts @{ ReviewedCount = 2; DecisionCurrent = $true })
            $s.Steps[3].State | Should -Be 'Done'
            $s.Steps[3].Summary | Should -Be 'Decisions recorded for 2 messages'
            $s.Current | Should -Be 5
            $s.Steps[4].Summary | Should -Be '2 decisions recorded'
        }
        It 'two of two reviewed while the Sandbox is still open: done' {
            (Get-LauncherStepState (New-Facts @{ ReviewedCount = 2; DecisionCurrent = $true; SandboxRunning = $true })).Steps[3].State | Should -Be 'Done'
        }
        It 'continuing with one of two moves to step 5 with that decision' {
            $s = Get-LauncherStepState (New-Facts @{ ReviewedCount = 1; DecisionCurrent = $true; DecisionText = 'Delete and block'; PartialContinued = $true })
            $s.Steps[3].State | Should -Be 'Done'
            $s.Steps[3].Summary | Should -Be '1 of 2 messages reviewed'
            $s.Current | Should -Be 5
            $s.Steps[4].Summary | Should -Be 'Decision: Delete and block'
        }
        It 'a Sandbox started after continuing takes the step back' {
            (Get-LauncherStepState (New-Facts @{ ReviewedCount = 1; DecisionCurrent = $true; PartialContinued = $true; SandboxRunning = $true })).Current | Should -Be 4
        }
        It 'export off and acknowledged still works with several files' {
            $s = Get-LauncherStepState (New-Facts @{ ExportOn = $false; DecisionAcknowledged = $true })
            $s.Steps[3].Summary | Should -Be 'Decision recorded in the Sandbox'
            $s.Steps[4].Summary | Should -Match 'report export was off'
        }
    }

    Context 'single package regression' {
        It 'one file, one decision: unchanged texts' {
            $s = Get-LauncherStepState (New-Facts @{ IncomingCount = 1; ReviewedCount = 1; DecisionCurrent = $true; DecisionText = 'Release' })
            $s.Steps[3].Summary | Should -Be 'Decision recorded'
            $s.Steps[4].Summary | Should -Be 'Decision: Release'
            $s.Current | Should -Be 5
        }
        It 'one file, no decision, failed run: the warning stays in the summary' {
            $s = Get-LauncherStepState (New-Facts @{ IncomingCount = 1; LaunchState = 'Vanished' })
            $s.Steps[3].Summary | Should -Match 'closed before a decision'
            $s.Current | Should -Be 4
        }
        It 'facts without ReviewedCount still work (DecisionCurrent alone means one reviewed)' {
            $f = New-Facts @{ IncomingCount = 1; DecisionCurrent = $true }
            $f.Remove('ReviewedCount')
            (Get-LauncherStepState $f).Steps[3].State | Should -Be 'Done'
        }
    }

    Context 'the decision map' {
        BeforeEach {
            $inbox = Join-Path $TestDrive 'MapIncoming'; $reportsDir = Join-Path $TestDrive 'MapReports'
            Remove-Item -LiteralPath $inbox, $reportsDir -Recurse -Force -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Path $inbox, $reportsDir -Force | Out-Null
        }
        It 'maps each input hash to its newest record; invalid records are ignored' {
            $hA = New-Package $inbox 'a.zip' 'aaa'; $hB = New-Package $inbox 'b.eml' 'bbb'
            $old = New-DecisionFile $reportsDir 'Decision-1.json' $hA 'Release'
            $new = New-DecisionFile $reportsDir 'Decision-2.json' $hA 'Delete and block'
            [IO.File]::SetLastWriteTimeUtc($old, [DateTime]::UtcNow.AddMinutes(-10)); [IO.File]::SetLastWriteTimeUtc($new, [DateTime]::UtcNow.AddMinutes(-5))
            New-DecisionFile $reportsDir 'Decision-3.json' $hB 'Keep' | Out-Null
            # ignored: incomplete, a hash that is not 64 hex digits, malformed JSON, and a report file
            $bad = New-DecisionFile $reportsDir 'Decision-4.json' ('c' * 64) 'Release' @{ record_complete = $false }
            New-DecisionFile $reportsDir 'Decision-5.json' 'not-a-hash' 'Release' | Out-Null
            '{' | Set-Content -LiteralPath (Join-Path $reportsDir 'Decision-6.json')
            New-DecisionFile $reportsDir 'Decision-7-report.json' ('d' * 64) 'Release' | Out-Null
            $map = Read-DecisionMap $reportsDir
            $map.Count | Should -Be 2
            $map[$hA].final_decision | Should -Be 'Delete and block' -Because 'the newest record for a hash wins'
            $map[$hB].final_decision | Should -Be 'Keep'
            $map.ContainsKey(('c' * 64)) | Should -BeFalse
            $map.ContainsKey(('d' * 64)) | Should -BeFalse
        }
        It 'an empty or missing Reports folder is an empty map' {
            (Read-DecisionMap $reportsDir).Count | Should -Be 0
            (Read-DecisionMap (Join-Path $TestDrive 'nope')).Count | Should -Be 0
        }
        It 'the cache re-reads a record only when the file changes' {
            $h = New-Package $inbox 'a.zip' 'aaa'
            $f = New-DecisionFile $reportsDir 'Decision-1.json' $h 'Release'
            $cache = @{}
            (Read-DecisionMap $reportsDir $cache)[$h].final_decision | Should -Be 'Release'
            $cache.Count | Should -Be 1
            Remove-Item -LiteralPath $f
            (Read-DecisionMap $reportsDir $cache).Count | Should -Be 0
            $cache.Count | Should -Be 0
        }
        It 'a package is reviewed only when its hash has a record; a stale record never counts' {
            $hA = New-Package $inbox 'a.zip' 'aaa'; $hB = New-Package $inbox 'b.zip' 'bbb'
            New-DecisionFile $reportsDir 'Decision-1.json' $hA | Out-Null
            New-DecisionFile $reportsDir 'Decision-2.json' ('e' * 64) | Out-Null     # for a download that is gone
            $files = @(Get-IncomingPackages $inbox)
            $hashes = @{}; foreach ($f in $files) { $hashes[$f.FullName] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash }   # upper case, as Get-FileHash returns it
            $map = Read-DecisionMap $reportsDir
            $r = @(Get-ReviewedPackages $files $hashes $map)
            $r.Count | Should -Be 1
            $r[0].FileName | Should -Be 'a.zip'
            @(Get-ReviewedPackages $files $null $map).Count | Should -Be 0 -Because 'no hashes yet'
            @(Get-ReviewedPackages $files $hashes @{}).Count | Should -Be 0
        }
        It 'two copies of the same package are both reviewed by one record' {
            $h = New-Package $inbox 'a.zip' 'same'; New-Package $inbox 'a (2).zip' 'same' | Out-Null
            New-DecisionFile $reportsDir 'Decision-1.json' $h | Out-Null
            $files = @(Get-IncomingPackages $inbox)
            $hashes = @{}; foreach ($f in $files) { $hashes[$f.FullName] = $h }
            @(Get-ReviewedPackages $files $hashes (Read-DecisionMap $reportsDir)).Count | Should -Be 2
        }
        It 'the package key covers every .zip/.eml and skips other files' {
            New-Package $inbox 'a.zip' 'aaa' | Out-Null; New-Package $inbox 'b.eml' 'bbb' | Out-Null; New-Package $inbox 'notes.txt' 'x' | Out-Null
            $files = @(Get-IncomingPackages $inbox)
            @(Get-IncomingPackagePaths $files).Count | Should -Be 2
            (Get-IncomingPackageKey $files) -split ';' | Should -HaveCount 2
            Get-IncomingPackageKey @() | Should -BeNullOrEmpty
            Get-IncomingPackageKey @($files | Where-Object { $_.Name -eq 'notes.txt' }) | Should -BeNullOrEmpty
        }
    }

    Context 'a run that produced no new decision' {
        It 'compares the decisions at launch with now' {
            $recA = [pscustomobject]@{ qra_source = 'Decision-1.json|10|1' }
            $map = @{ ('a' * 64) = $recA }
            $snap = Get-DecisionSnapshot $map
            $snap[('a' * 64)] | Should -Be 'Decision-1.json|10|1'
            Test-RunProducedDecision $map $snap @(('a' * 64), ('b' * 64)) | Should -BeFalse -Because 'only the old decision for file A exists'
            $map2 = @{ ('a' * 64) = $recA; ('b' * 64) = [pscustomobject]@{ qra_source = 'Decision-2.json|10|2' } }
            Test-RunProducedDecision $map2 $snap @(('a' * 64), ('b' * 64)) | Should -BeTrue
            $map3 = @{ ('a' * 64) = [pscustomobject]@{ qra_source = 'Decision-3.json|10|3' } }
            Test-RunProducedDecision $map3 $snap @(('a' * 64)) | Should -BeTrue -Because 'a re-recorded decision for the same file is new'
        }
        It 'ignores a new record for a package that is not in Incoming, and counts it while the hashes are unknown' {
            $snap = @{}
            $map = @{ ('c' * 64) = [pscustomobject]@{ qra_source = 'Decision-9.json|1|1' } }
            Test-RunProducedDecision $map $snap @(('a' * 64)) | Should -BeFalse
            Test-RunProducedDecision $map $snap $null | Should -BeTrue
            Test-RunProducedDecision @{} $snap $null | Should -BeFalse
        }
        It 'Get-LauncherFacts says Vanished only when the run left nothing new, and None once a decision lands' {
            Import-LauncherFunction 'Get-LauncherFacts', 'Get-SandboxProcess', 'Get-DecisionInputHash'
            Mock Get-SandboxProcess { @() }
            $optReports = @{ Checked = $true }
            $inbox = Join-Path $TestDrive 'RunIncoming'; New-Item -ItemType Directory -Path $inbox -Force | Out-Null
            $hA = New-Package $inbox 'a.zip' 'aaa'; $hB = New-Package $inbox 'b.zip' 'bbb'
            $script:IncomingFiles = @(Get-IncomingPackages $inbox)
            $script:IncomingHashes = @{}; foreach ($f in $script:IncomingFiles) { $script:IncomingHashes[$f.FullName] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash }
            $script:IncomingHashKey = Get-IncomingPackageKey $script:IncomingFiles
            $oldA = [pscustomobject]@{ record_complete = $true; input_sha256 = $hA; final_decision = 'Release'; qra_source = 'Decision-1.json|1|1' }
            $script:DecisionMap = @{ $hA = $oldA }
            $script:LaunchSnapshot = Get-DecisionSnapshot $script:DecisionMap
            $script:SandboxSeen = $true; $script:RunEnded = $false; $script:LaunchState = 'None'
            $script:ReadinessWork = $null; $script:Busy = $null; $script:Checks = @()
            $script:CleanedUp = $false; $script:Step4Seen = $false; $script:DecisionAcknowledged = $false; $script:ContinuedSig = $null
            $f1 = Get-LauncherFacts
            $f1.LaunchState | Should -Be 'Vanished' -Because 'the older decision for A must not hide a failed run'
            $f1.ReviewedCount | Should -Be 1
            $f1.IncomingCount | Should -Be 2
            $script:DecisionMap[$hB] = [pscustomobject]@{ record_complete = $true; input_sha256 = $hB; final_decision = 'Keep'; qra_source = 'Decision-2.json|1|2' }
            $f2 = Get-LauncherFacts
            $f2.LaunchState | Should -Be 'None'
            $f2.ReviewedCount | Should -Be 2
            @($f2.Reviewed).Count | Should -Be 2
            $script:RunEnded = $false; $script:LaunchState = 'None'; $script:DecisionMap = @{}; $script:IncomingHashes = @{}; $script:IncomingHashKey = $null
        }
    }

    Context 'the combined block list' {
        BeforeAll {
            $script:RecA = [pscustomobject]@{ final_decision = 'Delete and block'; recorded_local = '2026-11-25 10:58'
                iocs = [pscustomobject]@{ sender = 'b@y.example'; sender_domain = 'y.example'; domains = @('shared.example', 'y.example'); urls = @('hxxp://x[.]example/p'); sha256 = @('BBBB name.exe') } }
            $script:RecB = [pscustomobject]@{ final_decision = 'Delete and block'; recorded_local = '2026-11-25 11:06'
                iocs = [pscustomobject]@{ sender = 'a@x.example'; sender_domain = 'x.example'; domains = @('shared.example', 'x.example'); urls = @('http://x.example/p', 'http://z.example/'); sha256 = @('bbbb other.exe', 'AAAA') } }
        }
        It 'one record gives exactly the single block list' {
            Get-CombinedBlockListText @($script:RecA) | Should -BeExactly (Get-BlockListText $script:RecA)
        }
        It 'is the union of both, each value once, sorted, whatever the record order' {
            $one = Get-CombinedBlockListText @($script:RecA, $script:RecB)
            $two = Get-CombinedBlockListText @($script:RecB, $script:RecA)
            $one | Should -BeExactly $two
            $lines = $one -split "`r`n"
            @($lines | Where-Object { $_ -eq 'shared.example' }).Count | Should -Be 1
            @($lines | Where-Object { $_ -eq 'http://x.example/p' }).Count | Should -Be 1
            @($lines | Where-Object { $_ -like 'bbbb*' }).Count | Should -Be 1
            $lines[0] | Should -Match '2 decisions, newest recorded 2026-11-25 11:06'
            $lines.IndexOf('a@x.example') | Should -BeLessThan $lines.IndexOf('b@y.example')
            $lines.IndexOf('# Sender') | Should -BeLessThan $lines.IndexOf('# Link domains (URLs tab)')
            $lines | Should -Contain 'x.example'
            $lines | Should -Contain 'aaaa'
        }
        It 'a release decision with a spoof pair contributes only that pair' {
            $rel = [pscustomobject]@{ final_decision = 'Release'; recorded_local = '2026-11-25 11:10'; spoof_pair = 'spoofed@x.example, sender.example'; iocs = [pscustomobject]@{ sender = 'never@x.example' } }
            $text = Get-CombinedBlockListText @($script:RecA, $rel)
            $text | Should -Match 'SPOOF ALLOW PAIR'
            $text | Should -Match 'spoofed@x.example, sender.example'
            $text | Should -Not -Match 'never@x.example'
            $text | Should -Match 'b@y.example'
        }
    }

    Context 'verifying several decisions before copying' {
        BeforeEach {
            $inbox = Join-Path $TestDrive 'VerIncoming'; $reportsDir = Join-Path $TestDrive 'VerReports'
            Remove-Item -LiteralPath $inbox, $reportsDir -Recurse -Force -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Path $inbox, $reportsDir -Force | Out-Null
            $hA = New-Package $inbox 'a.zip' 'aaa'; $hB = New-Package $inbox 'b.eml' 'bbb'
            $recA = New-DecisionFile $reportsDir 'Decision-1.json' $hA 'Delete and block' @{ iocs = @{ sender = 'a@x.example' } }
            $recB = New-DecisionFile $reportsDir 'Decision-2.json' $hB 'Delete and block' @{ iocs = @{ sender = 'b@y.example' } }
            $shown = @((Read-DecisionMap $reportsDir).Values)
        }
        It 'copies the union of both verified decisions' {
            $text = Get-VerifiedBlockList $inbox $reportsDir $shown
            $text | Should -Match 'a@x.example'
            $text | Should -Match 'b@y.example'
        }
        It 'one decision changed on disk blocks the copy' {
            New-DecisionFile $reportsDir 'Decision-2.json' $hB 'Delete and block' @{ iocs = @{ sender = 'changed@y.example' } } | Out-Null
            Get-VerifiedBlockList $inbox $reportsDir $shown | Should -BeNullOrEmpty
        }
        It 'one package replaced blocks the copy' {
            [IO.File]::WriteAllText((Join-Path $inbox 'b.eml'), 'something else')
            Get-VerifiedBlockList $inbox $reportsDir $shown | Should -BeNullOrEmpty
        }
        It 'one package removed blocks the copy' {
            Remove-Item -LiteralPath (Join-Path $inbox 'a.zip')
            Get-VerifiedBlockList $inbox $reportsDir $shown | Should -BeNullOrEmpty
        }
        It 'one record removed blocks the copy' {
            Remove-Item -LiteralPath $recA
            Get-VerifiedBlockList $inbox $reportsDir $shown | Should -BeNullOrEmpty
        }
        It 'a legacy or incomplete record among them blocks the copy' {
            $bad = @($shown | ForEach-Object { $_ })
            $bad[0] = [pscustomobject]@{ final_decision = 'Delete and block'; iocs = @{ sender = 'a@x.example' } }
            Get-VerifiedBlockList $inbox $reportsDir $bad | Should -BeNullOrEmpty
        }
    }

    Context 'the last-decision box' {
        It 'lists every package: reviewed with details, unreviewed as not reviewed yet' {
            $d = [pscustomobject]@{ final_decision = 'Delete and block'; confidence = 'High'; recorded_local = '2026-11-25 10:58'; sender = 's@x.example'; subject = 'Invoice'; tool_recommendation = 'Likely malicious'; microsoft_verdict = 'Phish' }
            $text = Get-ReviewedDecisionsText @([pscustomobject]@{ FileName = 'a.zip'; Decision = $d }) @('a.zip', 'b.eml')
            $text | Should -Match '1 of 2 messages reviewed'
            $text | Should -Match 'a\.zip - Delete and block - High - 2026-11-25 10:58'
            $text | Should -Match 'Sender: s@x.example \| Subject: Invoice'
            $text | Should -Match 'b\.eml - not reviewed yet'
            $all = Get-ReviewedDecisionsText @([pscustomobject]@{ FileName = 'a.zip'; Decision = $d }, [pscustomobject]@{ FileName = 'b.eml'; Decision = $d }) @('a.zip', 'b.eml')
            $all | Should -Match '^2 decisions recorded'
            $all | Should -Not -Match 'not reviewed yet'
        }
    }

    Context 'the hashing worker' {
        It 'hashes every package in Incoming in one background job' {
            Import-LauncherFunction 'Start-IncomingWatcher', 'Update-IncomingHash', 'Clear-IncomingHash', 'Get-SandboxProcess'
            $inbox = Join-Path $TestDrive 'WorkIncoming'; $reportsDir = Join-Path $TestDrive 'WorkReports'
            New-Item -ItemType Directory -Path $inbox, $reportsDir -Force | Out-Null
            $hA = New-Package $inbox 'a.zip' 'aaa'; $hB = New-Package $inbox 'b.eml' 'bbb'; New-Package $inbox 'notes.txt' 'skipped' | Out-Null
            New-DecisionFile $reportsDir 'Decision-1.json' $hA | Out-Null
            $Incoming = $inbox
            $form = New-Object Windows.Forms.Form
            [void]$form.Handle
            function Set-LastDecisionView {}
            $script:IncomingFiles = @(Get-IncomingPackages $inbox)
            $script:DecisionMap = Read-DecisionMap $reportsDir
            $script:IncomingHashes = @{}; $script:IncomingHashKey = $null; $script:HashWork = $null; $script:HashWorkKey = $null
            try {
                Update-IncomingHash
                $script:HashWork | Should -Not -BeNullOrEmpty
                $deadline = [DateTime]::UtcNow.AddSeconds(20)
                while (-not (Test-QraWork $script:HashWork) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
                Update-IncomingHash
                $script:IncomingHashes.Count | Should -Be 2 -Because 'the .txt file is not a package'
                $script:IncomingHashes[(Join-Path $inbox 'a.zip')] | Should -Be $hA.ToUpperInvariant()
                $script:IncomingHashes[(Join-Path $inbox 'b.eml')] | Should -Be $hB.ToUpperInvariant()
                $script:IncomingHashKey | Should -Be (Get-IncomingPackageKey $script:IncomingFiles)
            } finally {
                if ($script:IncomingWatcher) { $script:IncomingWatcher.Dispose(); $script:IncomingWatcher = $null }
                if ($script:HashWork) { Stop-QraWork $script:HashWork; $script:HashWork = $null }
                Clear-IncomingHash
                $form.Dispose()
            }
        }
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
    It 'step 3 offers the optional Fetch release requests button and sub-step' {
        $t = [IO.File]::ReadAllText($script:LauncherPath)
        $t.Contains("New-QraButton 'Fetch release requests' 'Secondary'") | Should -BeTrue
        $t.Contains("(New-SubStep 'Optional: Fetch release requests saves the messages you select straight into this folder.' 'Fetch release requests')") | Should -BeTrue
        $t.Contains("Show-ReleaseRequestDialog -Incoming `$Incoming -Owner `$form") | Should -BeTrue
        $t.Contains(". (Join-Path `$PSScriptRoot 'ReleaseRequests.ps1')") | Should -BeTrue -Because 'dot-sourced without arguments'
    }
}

Describe 'Launcher: sandbox profile settings' {
    BeforeAll {
        Import-LauncherFunction 'Write-SandboxProfile'
        $global:ProfilesDir = Join-Path $TestDrive 'Profiles'
        $global:Reports = Join-Path $TestDrive 'Reports'
        $global:Root = Join-Path $TestDrive 'tool root & more'
        New-Item -ItemType Directory -Force -Path $global:Root | Out-Null
        function Get-Wsb([bool]$exportOn, [bool]$protectedClient, [bool]$compat) {   # not named $reports: the launcher function reads $Reports (PowerShell names are case-insensitive)
            $path = Write-SandboxProfile $exportOn $protectedClient $compat
            [xml][IO.File]::ReadAllText($path)
        }
        function Get-Mapping($xml, [string]$sandboxFolder) {
            @($xml.Configuration.MappedFolders.MappedFolder | Where-Object { $_.SandboxFolder -eq $sandboxFolder })
        }
    }
    AfterAll { foreach ($n in 'ProfilesDir', 'Reports') { Remove-Variable -Name $n -Scope Global -ErrorAction SilentlyContinue }; $global:Root = $TestDrive }

    It 'default mode: no network, every redirection and vGPU disabled, no Protected Client' {
        $x = Get-Wsb $true $false $false
        $x.Configuration.Networking | Should -Be 'Disable'
        foreach ($opt in 'vGPU', 'ClipboardRedirection', 'PrinterRedirection', 'AudioInput', 'VideoInput') { $x.Configuration.$opt | Should -Be 'Disable' -Because $opt }
        $x.Configuration.ProtectedClient | Should -BeNullOrEmpty
    }
    It 'Protected mode adds ProtectedClient and keeps everything else disabled' {
        $x = Get-Wsb $true $true $false
        $x.Configuration.ProtectedClient | Should -Be 'Enable'
        $x.Configuration.Networking | Should -Be 'Disable'
        foreach ($opt in 'vGPU', 'ClipboardRedirection', 'PrinterRedirection', 'AudioInput', 'VideoInput') { $x.Configuration.$opt | Should -Be 'Disable' -Because $opt }
    }
    It 'Compatibility mode leaves the redirections at the Windows default (no elements) but keeps networking disabled' {
        $x = Get-Wsb $true $true $true       # Protected is ignored in compatibility mode
        $x.Configuration.Networking | Should -Be 'Disable'
        foreach ($opt in 'vGPU', 'ClipboardRedirection', 'PrinterRedirection', 'AudioInput', 'VideoInput', 'ProtectedClient') { $x.Configuration.$opt | Should -BeNullOrEmpty -Because $opt }
    }
    It 'maps the tool folder read-only in every mode' {
        foreach ($combo in @(@($true, $false, $false), @($false, $true, $false), @($true, $false, $true))) {
            $x = Get-Wsb $combo[0] $combo[1] $combo[2]
            $m = @(Get-Mapping $x 'C:\Review')
            $m.Count | Should -Be 1
            $m[0].ReadOnly | Should -Be 'true'
            $m[0].HostFolder | Should -Be $global:Root
        }
    }
    It 'maps Reports writable only when report export is on' {
        $on = @(Get-Mapping (Get-Wsb $true $false $false) 'C:\Reports')
        $on.Count | Should -Be 1
        $on[0].ReadOnly | Should -Be 'false'
        $on[0].HostFolder | Should -Be $global:Reports
        (Get-Mapping (Get-Wsb $false $false $false) 'C:\Reports').Count | Should -Be 0
        (Get-Mapping (Get-Wsb $false $true $true) 'C:\Reports').Count | Should -Be 0
        @((Get-Wsb $false $false $false).Configuration.MappedFolders.MappedFolder).Count | Should -Be 1
    }
    It 'starts the review window in the Sandbox and nothing else' {
        $x = Get-Wsb $true $false $false
        $x.Configuration.LogonCommand.Command | Should -Be 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\Review\app\QuarantineReview.ps1'
    }
}

Describe 'Launcher: -Screenshot' -Tag 'Screenshot' {
    BeforeAll {
        $script:ShotStates = 'checks-running', 'not-ready', 'ready', 'watching-incoming', 'sandbox-starting', 'review-in-progress', 'export-off', 'decision-recorded', 'two-files-one-reviewed', 'two-files-reviewed', 'stale-decision', 'many-decisions', 'all-done', 'release-requests'
        # The child is started directly (not through the pipeline) and waited for with an explicit limit: a render in a loaded full-suite run
        # takes much longer than alone, and Pester's Stop error preference would turn any line on stderr into a thrown error under 5.1.
        function Invoke-LauncherShots([string]$dir, [string]$extra = '', [string]$script = $script:LauncherPath, [int]$timeoutSec = 300) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            $argText = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Screenshot "{1}"' -f $script, $dir
            if ($extra) { $argText += ' ' + $extra }
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = (Join-Path $PSHOME 'powershell.exe'); if (-not (Test-Path -LiteralPath $psi.FileName)) { $psi.FileName = 'powershell.exe' }
            $psi.Arguments = $argText; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
            $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
            $proc = [System.Diagnostics.Process]::Start($psi)
            $outTask = $proc.StandardOutput.ReadToEndAsync(); $errTask = $proc.StandardError.ReadToEndAsync()
            $timedOut = -not $proc.WaitForExit($timeoutSec * 1000)
            if ($timedOut) { try { $proc.Kill() } catch { $null = $_ }; [void]$proc.WaitForExit(10000) }
            else { $proc.WaitForExit() }   # flushes the redirected streams
            $text = "stdout:`n$($outTask.Result)`nstderr:`n$($errTask.Result)"
            $exit = if ($timedOut) { -1 } else { $proc.ExitCode }
            $proc.Dispose()
            if ($timedOut) { $text = "TIMED OUT after $timeoutSec s (the render was killed)`n$text" }
            [pscustomobject]@{ Exit = $exit; Output = $text; TimedOut = $timedOut }
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
        $r = Invoke-LauncherShots (Join-Path $TestDrive 'shots-noio') '' (Join-Path $root 'app\Launcher.ps1')
        $r.Exit | Should -Be 0 -Because $r.Output
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

Describe 'Launcher: start-up (splash, single instance, bring to front)' {
    BeforeAll { $script:LauncherText = [IO.File]::ReadAllText($script:LauncherPath) }
    It 'shows a plain-WinForms splash before the UI kit is loaded, only for a real GUI run' {
        $t = $script:LauncherText
        $kit = $t.IndexOf("QraUi.ps1')")
        $splash = $t.IndexOf("`$spT.Text = 'Quarantine Review Assistant'")
        $splash | Should -BeGreaterThan 0
        $splash | Should -BeLessThan $kit -Because 'the splash must be up before the slow part starts'
        $t.Contains('FromArgb(17, 38, 66)') | Should -BeTrue
        $t.Contains("`$spT.Text = 'Quarantine Review Assistant'") | Should -BeTrue
        $t.Contains("`$sp.FormBorderStyle = 'None'") | Should -BeTrue
        $t.Contains('$sp.ShowInTaskbar = $false; $sp.TopMost = $true') | Should -BeTrue
        $t.Contains('Screen]::FromPoint([System.Windows.Forms.Cursor]::Position)') | Should -BeTrue
        $t.Contains('[System.Windows.Forms.Application]::DoEvents()') | Should -BeTrue
        $t.Contains('$startGui = (-not $Screenshot) -and (-not $NoGui)') | Should -BeTrue
        $t.Substring(0, $kit) | Should -Not -Match 'Name Win2' -Because 'the splash needs no native code from the kit'
    }
    It 'closes the splash in the Shown handler and in the trap' {
        $t = $script:LauncherText
        $t.Substring($t.IndexOf('trap {'), 200) | Should -Match 'Close-LauncherSplash'
        $t.Substring($t.IndexOf('$form.Add_Shown({'), 300) | Should -Match 'Close-LauncherSplash'
    }
    It 'brings the window to the front in the Shown handler' {
        $t = $script:LauncherText
        $t.Substring($t.IndexOf('$form.Add_Shown({'), 700) | Should -Match '\$form\.Activate\(\); \$form\.TopMost = \$true; \$form\.TopMost = \$false; \$form\.BringToFront\(\)'
        $t | Should -Match 'Enable-QraForeground; Hide-QraConsole'
    }
    It 'allows only one launcher: named mutex, wake the first window, release on close' {
        $t = $script:LauncherText
        $t.Contains("'Local\QuarantineReviewAssistant.Launcher'") | Should -BeTrue
        $t.Contains("-like 'Quarantine Review Assistant * - Host Launcher'") | Should -BeTrue
        $t.Contains('ShowWindow($other.MainWindowHandle, 9)') | Should -BeTrue
        $t.Contains('SetForegroundWindow($other.MainWindowHandle)') | Should -BeTrue
        $t.Substring($t.IndexOf('$form.Add_FormClosing({'), 200) | Should -Match 'Exit-LauncherMutex'
        $t.IndexOf('System.Threading.Mutex') | Should -BeLessThan $t.IndexOf('if (-not (Start-LauncherSplash))') -Because 'a second launcher must leave before it shows a splash'
    }
    It 'runs without the splash or the mutex in -NoGui mode' {
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:LauncherPath -NoGui 2>&1 | Out-String
        $out | Should -Match 'Windows edition'
    }
}

Describe 'Launcher: layout widths' {
    It 'lead and sub-steps use the content width up to a reading width of 900, not 620' {
        $t = [IO.File]::ReadAllText($script:LauncherPath)
        $t.Contains('$tw = [Math]::Min($cw, (S 900))') | Should -BeTrue
        $t.Contains('(S 620)') | Should -BeFalse
        $t.Contains('$rw = [Math]::Min($cw, (S 760))') | Should -BeTrue -Because 'the step-3 list and button row keep their own width'
    }
}

Describe 'Launcher: wording' {
    It 'has no tick/ticked/unticked in any user-facing string' {
        $strings = $script:LauncherAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }, $true)
        @($strings | Where-Object { $_.Value -match '(?i)\b(un)?tick(ed)?\b' } | ForEach-Object { $_.Value }) | Should -BeNullOrEmpty
    }
}

Describe 'Launcher: animated splash (own thread) and desktop shortcut wiring' {
    BeforeAll {
        $script:LauncherText = [IO.File]::ReadAllText($script:LauncherPath)
        $t = $script:LauncherText
        $script:SplashBlockText = $t.Substring($t.IndexOf('$script:LauncherSplashBlock = {'), $t.IndexOf('function Start-LauncherSplash') - $t.IndexOf('$script:LauncherSplashBlock = {'))
    }
    It 'runs the splash in an STA runspace with its own message loop' {
        $t = $script:LauncherText
        $t.Contains('RunspaceFactory]::CreateRunspace()') | Should -BeTrue
        $t.Contains('$rs.ApartmentState = [System.Threading.ApartmentState]::STA') | Should -BeTrue
        $t.Contains('PSThreadOptions]::ReuseThread') | Should -BeTrue
        $script:SplashBlockText.Contains('[System.Windows.Forms.Application]::Run($win)') | Should -BeTrue
        $script:LauncherFunctions.ContainsKey('Start-LauncherSplash') | Should -BeTrue
    }
    It 'uses plain WinForms and GDI+ only in the splash (no compiled or native code)' {
        $script:SplashBlockText | Should -Not -Match 'Add-Type\s+(-TypeDefinition)'
        ([regex]::Matches($script:SplashBlockText, 'Add-Type\s+-Namespace\s+\w+')).Value | Should -Be @('Add-Type -Namespace QraSplash') -Because 'the only native code in the splash is the small guarded QraSplash.Native compile'
        $script:SplashBlockText | Should -Not -Match 'DllImport'
        $script:SplashBlockText | Should -Match 'HighQualityBicubic'
        $script:SplashBlockText | Should -Match "DoubleBuffered"
        # greyscale anti-aliasing without grid fitting: closest to how Windows 11 draws its own text (ClearType grid fit looked too sharp)
        $script:SplashBlockText | Should -Match 'TextRenderingHint\]::AntiAlias\b'
        $script:SplashBlockText | Should -Not -Match 'ClearTypeGridFit'
    }
    It 'sets the close flag in Close-LauncherSplash, which the Shown handler, the trap and the single-instance exit all call' {
        $t = $script:LauncherText
        $script:LauncherFunctions['Close-LauncherSplash'].Extent.Text | Should -Match '\$script:SplashState\.Close = \$true'
        $t.Substring($t.IndexOf('$form.Add_Shown({'), 200) | Should -Match 'Close-LauncherSplash'
        $t.Substring($t.IndexOf('trap {'), 200) | Should -Match 'Close-LauncherSplash -Wait'
        $mutexLeft = $t.Substring($t.IndexOf('if (-not $mutexMine) {'))
        $mutexLeft = $mutexLeft.Substring(0, $mutexLeft.IndexOf('exit 0'))
        $mutexLeft | Should -Match 'Close-LauncherSplash'
    }
    It 'never blocks the window thread for more than a short wait when the splash is closed' {
        $fn = $script:LauncherFunctions['Close-LauncherSplash'].Extent.Text
        $fn | Should -Match 'WaitOne\(\$\(if \(\$Wait\) \{ 400 \} else \{ 0 \}\)\)'
        $fn | Should -Match 'BeginStop'
    }
    It 'starts the splash only for a real GUI run, after the single-instance check, and keeps the plain splash as the fallback' {
        $t = $script:LauncherText
        $t.Contains('$startGui = (-not $Screenshot) -and (-not $NoGui) -and ($env:USERNAME -ne ''WDAGUtilityAccount'')') | Should -BeTrue
        $call = $t.IndexOf('if (-not (Start-LauncherSplash)) {')
        $call | Should -BeGreaterThan $t.IndexOf('if ($startGui) {')
        $call | Should -BeGreaterThan $t.IndexOf('System.Threading.Mutex')
        $call | Should -BeLessThan $t.IndexOf("QraUi.ps1')")
        $t.IndexOf('$sp = New-Object System.Windows.Forms.Form') | Should -BeGreaterThan $call -Because 'the plain splash only runs when the animated one cannot start'
    }
    It 'keeps the zero-handle owner for the main window' {
        $t = $script:LauncherText
        $t.Contains('[void]$form.ShowDialog($noOwner)') | Should -BeTrue
    }
    It 'step 1 has a Create desktop shortcut button beside Check again, with its own click handler and feedback' {
        $t = $script:LauncherText
        $t.Contains("`$bShortcut = New-QraButton 'Create desktop shortcut' 'Secondary' `$QraGlyph.Link") | Should -BeTrue
        $t.Contains('$bShortcut.Add_Click({ Invoke-CreateDesktopShortcut })') | Should -BeTrue
        $t.Contains("Show-QraCopied `$bShortcut 'Shortcut created'") | Should -BeTrue
        $t.Contains("'Replace the existing desktop shortcut?'") | Should -BeTrue
        $t.Contains("[Environment]::GetFolderPath('Desktop')") | Should -BeTrue
        $t | Should -Match 'Start-Here\.cmd'
    }
    Context 'rendering the splash to a PNG (QRA_SPLASH_SHOT, a child Windows PowerShell 5.1)' {
        BeforeAll {
            function Invoke-SplashShot([string]$png, [string]$image, [int]$dpi = 0) {
                $env:QRA_SPLASH_SHOT = $png
                if ($image) { $env:QRA_SPLASH_IMAGE = $image }
                if ($dpi) { $env:QRA_SPLASH_DPI = [string]$dpi }
                try {
                    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:LauncherPath 2>&1
                    [pscustomobject]@{ Exit = $LASTEXITCODE; Output = ($out | Out-String) }
                } finally { Remove-Item Env:\QRA_SPLASH_SHOT, Env:\QRA_SPLASH_IMAGE, Env:\QRA_SPLASH_DPI -ErrorAction SilentlyContinue }
            }
            # Bounding box (width, height) of the near-white text pixels of the title, in the right-hand part of the splash.
            function Get-SplashTitleInk([string]$png) {
                $bmp = New-Object System.Drawing.Bitmap($png)
                try {
                    $x0 = [int]($bmp.Width * 0.585); $y0 = [int]($bmp.Height * 0.30); $y1 = [int]($bmp.Height * 0.52)
                    $minX = 99999; $maxX = -1; $minY = 99999; $maxY = -1
                    for ($y = $y0; $y -lt $y1; $y++) {
                        for ($x = $x0; $x -lt ($bmp.Width - 4); $x++) {
                            $px = $bmp.GetPixel($x, $y)
                            if ($px.R -ge 225 -and $px.G -ge 225 -and $px.B -ge 225) {
                                if ($x -lt $minX) { $minX = $x }; if ($x -gt $maxX) { $maxX = $x }; if ($y -lt $minY) { $minY = $y }; if ($y -gt $maxY) { $maxY = $y }
                            }
                        }
                    }
                    [pscustomobject]@{ W = ($maxX - $minX + 1); H = ($maxY - $minY + 1); Width = $bmp.Width; Height = $bmp.Height }
                } finally { $bmp.Dispose() }
            }
            function Get-ShotPixel([string]$png, [int]$x, [int]$y) {
                $bmp = New-Object System.Drawing.Bitmap($png)
                try { $px = $bmp.GetPixel($x, $y); @($px.R, $px.G, $px.B, $bmp.Width, $bmp.Height) } finally { $bmp.Dispose() }
            }
        }
        It 'renders the 640 x 357 splash with the picture' {
            $png = Join-Path $TestDrive 'splash.png'
            $r = Invoke-SplashShot $png ''
            $r.Exit | Should -Be 0 -Because $r.Output
            $px = Get-ShotPixel $png 200 170
            $px[3] | Should -Be 640; $px[4] | Should -Be 357
            ($px[0] + $px[1] + $px[2]) | Should -BeGreaterThan 300 -Because 'the shield is bright'
        }
        It 'renders at an emulated 120 and 144 dpi (125 % and 150 %): the window is 640 x 357 scaled, the text is drawn at the real (scaled) size' {
            $p96 = Join-Path $TestDrive 'splash-96.png'; $p120 = Join-Path $TestDrive 'splash-120.png'; $p150 = Join-Path $TestDrive 'splash-150.png'
            foreach ($job in @(@($p96, 0), @($p120, 120), @($p150, 144))) {
                $r = Invoke-SplashShot $job[0] '' $job[1]
                $r.Exit | Should -Be 0 -Because $r.Output
            }
            $i96 = Get-SplashTitleInk $p96; $i120 = Get-SplashTitleInk $p120; $i150 = Get-SplashTitleInk $p150
            $i96.Width | Should -Be 640; $i96.Height | Should -Be 357
            $i120.Width | Should -Be 800; $i120.Height | Should -Be 446
            $i150.Width | Should -Be 960; $i150.Height | Should -Be 536   # 144 dpi = 150 %
            $i96.H | Should -BeGreaterThan 15 -Because 'the title is found'
            ($i120.W / $i96.W) | Should -BeGreaterThan 1.18; ($i120.W / $i96.W) | Should -BeLessThan 1.32
            ($i120.H / $i96.H) | Should -BeGreaterThan 1.15; ($i120.H / $i96.H) | Should -BeLessThan 1.35
            ($i150.W / $i96.W) | Should -BeGreaterThan 1.40; ($i150.W / $i96.W) | Should -BeLessThan 1.62
            ($i150.H / $i96.H) | Should -BeGreaterThan 1.35; ($i150.H / $i96.H) | Should -BeLessThan 1.65
        }
        It 'falls back to a plain navy splash, same size, when the picture is missing, and still exits 0' {
            $png = Join-Path $TestDrive 'splash-nopic.png'
            $r = Invoke-SplashShot $png (Join-Path $TestDrive 'no-such-picture.jpg')
            $r.Exit | Should -Be 0 -Because $r.Output
            $px = Get-ShotPixel $png 200 170
            $px[3] | Should -Be 640; $px[4] | Should -Be 357
            @($px[0], $px[1], $px[2]) | Should -Be @(17, 38, 66)
        }
        It 'falls back the same way when the picture file is not an image' {
            $bad = Join-Path $TestDrive 'bad.jpg'
            Set-Content -LiteralPath $bad -Value 'not a picture'
            $png = Join-Path $TestDrive 'splash-badpic.png'
            $r = Invoke-SplashShot $png $bad
            $r.Exit | Should -Be 0 -Because $r.Output
            (Get-ShotPixel $png 200 170)[0] | Should -Be 17
        }
    }
    It 'ships a splash picture of a sensible size' {
        $jpg = Join-Path $script:Repo 'src\SecurityReview\app\assets\splash.jpg'
        (Get-Item -LiteralPath $jpg).Length | Should -BeLessThan 200KB
        $img = [System.Drawing.Image]::FromFile($jpg)
        try { $img.Width | Should -Be 1280; $img.Height | Should -Be 714 } finally { $img.Dispose() }
    }
}

Describe 'Launcher: per-monitor DPI wiring' {
    BeforeAll { $script:PmText = [IO.File]::ReadAllText($script:LauncherPath) }
    It 'review pictures (-Screenshot) keep one fixed system DPI, set before the kit is loaded' {
        $t = $script:PmText
        $t.Contains("if (`$Screenshot) { `$env:QRA_DPI_MODE = 'system' }") | Should -BeTrue
        $t.IndexOf("`$env:QRA_DPI_MODE = 'system'") | Should -BeLessThan $t.IndexOf("(Join-Path `$PSScriptRoot 'QraUi.ps1')")
    }
    It 'builds the window for the screen with the mouse unless a scale is emulated' {
        $t = $script:PmText
        $t.Contains('if ($ScreenshotDpi -gt 0) { Set-QraEmulatedDpi $ScreenshotDpi }') | Should -BeTrue
        $t.Contains('elseif ($script:QraPerMonitor) { Set-QraEmulatedDpi (Get-QraMonitorDpi) }') | Should -BeTrue
    }
    It '<Name> starts with the form''s own scale (Use-QraFormDpi $form)' -ForEach @(
        @{ Name = 'Update-HeaderLayout' }, @{ Name = 'Update-RailLayout' }, @{ Name = 'Update-StepContent' }, @{ Name = 'Update-StepLayout' }, @{ Name = 'Render-Checks' }, @{ Name = 'Fit-CheckRow' }
    ) {
        $body = $script:LauncherFunctions[$Name].Extent.Text
        $body | Should -Match 'Use-QraFormDpi \$form'
        # the first statement, after the signature (and after Update-StepLayout's guard line)
        $first = ($body -split '\r?\n' | Select-Object -Skip 1 | Where-Object { $_.Trim() -and $_ -notmatch '^\s*if \(-not \$script:LayoutReady' } | Select-Object -First 1)
        $first | Should -Match 'Use-QraFormDpi \$form'
    }
    It 'the layout does not run while a rescale is in progress' {
        $script:LauncherFunctions['Update-StepLayout'].Extent.Text | Should -Match '\$script:QraDpiBusy'
    }
    It 'registers the window with its font table and one relayout, and the check-row fonts with it' {
        $t = $script:PmText
        $t | Should -Match 'Register-QraDpiWindow \$form -FontTables @\(\$Fonts\) -Relayout'
        $t | Should -Match 'Add-QraFontTable \$form \$script:RowFonts'
        $t.Contains('Bold = [bool]$part[1]') | Should -BeTrue -Because 'the inline bold segments get their fonts back after a rescale'
    }
    It 'the splash thread becomes per-monitor aware before it creates any form, reads the mouse monitor and sizes by it' {
        $t = $script:PmText
        $block = $t.Substring($t.IndexOf('$script:LauncherSplashBlock = {'), $t.IndexOf('function Start-LauncherSplash') - $t.IndexOf('$script:LauncherSplashBlock = {'))
        $block.IndexOf('SetThreadPerMonitorV2') | Should -BeGreaterThan 0
        $block.IndexOf('SetThreadPerMonitorV2') | Should -BeLessThan $block.IndexOf('New-Object System.Windows.Forms.Form')
        $block.IndexOf('SetThreadPerMonitorV2') | Should -BeLessThan $block.IndexOf('Add-Type -AssemblyName System.Drawing')
        $block | Should -Match 'MonitorDpi'
        $block | Should -Match '& \$px 640'
        $block | Should -Not -Match 'DllImport'
        $block | Should -Match 'Add-Type -Namespace QraSplash -Name Native -MemberDefinition'
        $block | Should -Match 'catch \{ \$nt = \$false \}' -Because 'a refused compile must leave the splash DPI-unaware, never stop the start'
        $t | Should -Match 'GetDpiForMonitor' 
    }
}

Describe 'Launcher: GDI text rendering for standard controls' {
    It 'switches labels and buttons to GDI text before any control or the splash exists' {
        # .NET Framework defaults to GDI+ text (UseCompatibleTextRendering), which drew plain labels thin and grey next to the kit's own GDI text.
        $t = [IO.File]::ReadAllText($script:LauncherPath)
        $call = $t.IndexOf('SetCompatibleTextRenderingDefault($false)')
        $call | Should -BeGreaterThan 0
        $call | Should -BeLessThan $t.IndexOf('New-Object System.Windows.Forms.') -Because 'it is only allowed before the first control exists'
        $call | Should -BeLessThan $t.IndexOf('$script:LauncherSplashBlock') -Because 'the splash thread creates controls too'
    }
    It 'makes a plain Label use GDI text in a fresh Windows PowerShell 5.1 process' {
        $probe = 'Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false); (New-Object System.Windows.Forms.Label).UseCompatibleTextRendering'
        (& powershell.exe -NoProfile -Command $probe | Select-Object -Last 1) | Should -Be 'False'
    }
}
