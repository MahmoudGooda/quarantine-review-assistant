#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Pester 5. Sandbox review window (src/SecurityReview/app/QuarantineReview.ps1). The script runs UI code at top level,
# so it is never dot-sourced here: only its function definitions are extracted with the parser and defined.

BeforeAll {
    $script:Repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ReviewPath = Join-Path $script:Repo 'src\SecurityReview\app\QuarantineReview.ps1'
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    . (Join-Path $script:Repo 'src\SecurityReview\app\QraUi.ps1')

    $tokens = $null; $errs = $null
    $script:ReviewAst = [System.Management.Automation.Language.Parser]::ParseFile($script:ReviewPath, [ref]$tokens, [ref]$errs)
    $script:ReviewFunctions = @{}
    foreach ($fd in $script:ReviewAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $script:ReviewFunctions[$fd.Name] = $fd
    }
    function Import-ReviewFunction([string[]]$names) {
        foreach ($n in $names) {
            $fd = $script:ReviewFunctions[$n]
            if (-not $fd) { throw "Function $n not found in QuarantineReview.ps1" }
            . ([scriptblock]::Create(($fd.Extent.Text -replace '^function\s+', 'function global:')))
        }
    }
}

Describe 'Review window: analysis stage mapping' {
    BeforeAll { Import-ReviewFunction 'ConvertTo-AnalysisStage' }

    It "maps '<Text>' to stage <Index>" -ForEach @(
        @{ Text = 'Reading input file...'; Index = 0; Label = 'Reading file' }
        @{ Text = 'Opening quarantine package...'; Index = 1; Label = 'Opening package' }
        @{ Text = 'Parsing message...'; Index = 1; Label = 'Opening package' }
        @{ Text = 'Analysing message 2 of 3...'; Index = 2; Label = 'Analysing message 2 of 3...' }
        @{ Text = 'Inspecting archive...'; Index = 2; Label = 'Inspecting archive...' }
        @{ Text = 'Building report...'; Index = 3; Label = 'Building report' }
        @{ Text = 'Done.'; Index = 4; Label = 'Done' }
        @{ Text = ''; Index = -1; Label = 'Starting offline analysis...' }
        @{ Text = 'Something new'; Index = -1; Label = 'Something new' }
    ) {
        $s = ConvertTo-AnalysisStage $Text
        $s.Index | Should -Be $Index
        $s.Label | Should -Be $Label
    }

    It 'trims surrounding whitespace and line breaks from the progress text' {
        $s = ConvertTo-AnalysisStage "  Analysing message 1 of 2...`r`n"
        $s.Index | Should -Be 2
        $s.Label | Should -Be 'Analysing message 1 of 2...'
    }
    It 'treats null like empty text' {
        (ConvertTo-AnalysisStage $null).Index | Should -Be -1
    }
}

Describe 'Review window: empty-state prompt' {
    BeforeAll { Import-ReviewFunction 'Get-EmptyPrompt' }
    It 'asks for a package when none is selected' {
        Get-EmptyPrompt $false | Should -Be 'Choose a package and click Analyze.'
    }
    It 'asks for the password when a package is selected' {
        Get-EmptyPrompt $true | Should -Be 'Enter the download password and click Analyze.'
    }
}

Describe 'Review window: source conventions' {
    BeforeAll { $script:Bytes = [IO.File]::ReadAllBytes($script:ReviewPath); $script:Text = [IO.File]::ReadAllText($script:ReviewPath) }
    It 'has a UTF-8 BOM and CRLF line endings' {
        $script:Bytes[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
        ($script:Text -split "(?<!`r)`n").Count | Should -Be 1
    }
    It 'uses the shared kit and no local copies of its helpers' {
        ($script:Text -match 'QraUi\.ps1') | Should -BeTrue
        $script:ReviewFunctions.ContainsKey('S') | Should -BeFalse
        $script:ReviewFunctions.ContainsKey('New-Font') | Should -BeFalse
        $script:ReviewFunctions.ContainsKey('Set-FocusRing') | Should -BeFalse
    }
    It 'defines the helpers Task 5 builds on' {
        foreach ($n in 'ConvertTo-AnalysisStage', 'Stop-Analysis', 'Set-ResultsMode') { $script:ReviewFunctions.ContainsKey($n) | Should -BeTrue }
    }
}

Describe 'Review window: step state' {
    BeforeAll { Import-ReviewFunction 'Get-ReviewStepState' }

    It 'nothing selected' {
        $s = Get-ReviewStepState @{ FileName = $null; FileSize = ''; PasswordEntered = $false; Analyzing = $false; ResultShown = $false; ElapsedSeconds = 0; RecordedDecision = $null }
        $s.Current | Should -Be 1
        $s.Steps.Count | Should -Be 4
        $s.Steps[0].State | Should -Be 'Current'
        $s.Steps[1].State | Should -Be 'Pending'
        ($s.Steps | ForEach-Object { $_.Title }) -join '|' | Should -Be 'Choose the package|Enter the download password|Analyze|Decide'
    }
    It 'file and password' {
        $s = Get-ReviewStepState @{ FileName = 'Quarantined Messages.zip'; FileSize = '48.0 KB'; PasswordEntered = $true; Analyzing = $false; ResultShown = $false; ElapsedSeconds = 0; RecordedDecision = $null }
        $s.Steps[0].State | Should -Be 'Done'
        $s.Steps[0].Summary | Should -Be 'Quarantined Messages.zip (48.0 KB)'
        $s.Steps[1].State | Should -Be 'Done'
        $s.Current | Should -Be 3
        $s.Steps[2].State | Should -Be 'Current'
        $s.Steps[3].State | Should -Be 'Pending'
    }
    It 'password summary never contains the password' {
        $s = Get-ReviewStepState @{ PasswordEntered = $true }
        $s.Steps[1].Summary | Should -BeExactly 'Password entered'
    }
    It 'analysing' {
        $s = Get-ReviewStepState @{ FileName = 'a.zip'; FileSize = '1 KB'; PasswordEntered = $true; Analyzing = $true }
        $s.Steps[2].State | Should -Be 'Working'
        $s.Current | Should -Be 3
    }
    It 'result shown' {
        $s = Get-ReviewStepState @{ FileName = 'a.zip'; FileSize = '1 KB'; PasswordEntered = $false; ResultShown = $true; ElapsedSeconds = 12 }
        $s.Steps[1].Summary | Should -Be 'Password entered'
        $s.Steps[2].Summary | Should -Be 'Finished in 12 s'
        $s.Steps[2].State | Should -Be 'Done'
        $s.Current | Should -Be 4
    }
    It 'decision recorded' {
        $s = Get-ReviewStepState @{ FileName = 'a.zip'; FileSize = '1 KB'; PasswordEntered = $true; ResultShown = $true; ElapsedSeconds = 3; RecordedDecision = 'Delete and block' }
        ($s.Steps | Where-Object { $_.State -eq 'Done' }).Count | Should -Be 4
        $s.Steps[3].Summary | Should -Be 'Delete and block'
    }
}

Describe 'Review window: refused password' {
    BeforeAll { Import-ReviewFunction 'Get-ReviewStepState' }
    It "'<Status>' makes step 2 the current step with a warning and the exact summary" -ForEach @(
        @{ Status = 'wrong'; Text = 'Wrong password - enter it again' }
        @{ Status = 'missing'; Text = 'Password missing - enter it' }
    ) {
        $s = Get-ReviewStepState @{ FileName = 'a.zip'; FileSize = '1 KB'; PasswordEntered = $false; ResultShown = $true; ElapsedSeconds = 4; PasswordRejected = $Status }
        $s.Current | Should -Be 2
        $s.Steps[1].State | Should -Be 'Warning'
        $s.Steps[1].Summary | Should -BeExactly $Text
        $s.Steps[2].Summary | Should -Be 'Finished in 4 s'
        $s.Steps[3].State | Should -Be 'Pending'
    }
    It "'ok', null and empty leave the normal result state" {
        foreach ($v in 'ok', $null, '') {
            $s = Get-ReviewStepState @{ FileName = 'a.zip'; FileSize = '1 KB'; ResultShown = $true; ElapsedSeconds = 4; PasswordRejected = $v }
            $s.Current | Should -Be 4
            $s.Steps[1].Summary | Should -Be 'Password entered'
        }
    }
    It 'a rejection is only meaningful once a result is shown' {
        (Get-ReviewStepState @{ FileName = 'a.zip'; PasswordEntered = $true; PasswordRejected = 'wrong' }).Current | Should -Be 3
    }
}

Describe 'Review window: high contrast colours' {
    BeforeAll {
        Import-ReviewFunction 'New-DecisionColors'
        $script:HcAllowedFore = @('WindowText', 'HighlightText', 'GrayText')
        $script:HcAllowedBack = @('Window', 'Highlight')
        # every system colour name this colour equals (Window and HighlightText are both white in the default theme)
        function Get-SysName($color) { @(foreach ($n in 'WindowText', 'HighlightText', 'GrayText', 'Window', 'Highlight', 'WindowFrame') { if ($color.ToArgb() -eq [System.Drawing.SystemColors]::$n.ToArgb()) { $n } }) -join '+' }
        function Test-AnyIn([string]$names, [string[]]$allowed) { [bool](@($names -split '\+' | Where-Object { $_ -in $allowed }).Count) }
    }
    It 'every fill and text colour of the decision colours is a system colour pair in high contrast' {
        $dc = New-DecisionColors $true
        foreach ($k in 'red', 'amber', 'green', 'blue', 'grey') {
            Test-AnyIn (Get-SysName $dc[$k].Soft) $script:HcAllowedBack | Should -BeTrue
            Test-AnyIn (Get-SysName $dc[$k].Back) $script:HcAllowedBack | Should -BeTrue
            Test-AnyIn (Get-SysName $dc[$k].Text) $script:HcAllowedFore | Should -BeTrue
            Test-AnyIn (Get-SysName $dc[$k].OnBack) $script:HcAllowedFore | Should -BeTrue
        }
    }
    It 'the normal colours are unchanged outside high contrast' {
        $dc = New-DecisionColors $false
        $dc.red.Soft.ToArgb() | Should -Be ([System.Drawing.Color]::FromArgb(253, 231, 229).ToArgb())
        $dc.amber.Text.ToArgb() | Should -Be ([System.Drawing.Color]::FromArgb(150, 85, 0).ToArgb())
        $dc.green.OnBack.ToArgb() | Should -Be ([System.Drawing.Color]::White.ToArgb())
    }
    It 'footer, warning bar, scorecard and check rows resolve to system colour pairs in high contrast (child process)' {
        $kit = Join-Path $script:Repo 'src\SecurityReview\app\QraUi.ps1'
        $fn = $script:ReviewFunctions['New-DecisionColors'].Extent.Text
        $tmp = Join-Path $TestDrive 'hc.ps1'
        $body = @"
`$env:QRA_UI_HIGHCONTRAST = '1'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. '$kit'
$fn
`$dc = New-DecisionColors
function N(`$col) { (@(foreach (`$n in 'WindowText','HighlightText','GrayText','Window','Highlight','WindowFrame') { if (`$col.ToArgb() -eq [System.Drawing.SystemColors]::`$n.ToArgb()) { `$n } }) -join '+') + '' }
'footer=' + (N `$C.Danger) + '/' + (N `$C.DangerSoft)
'warnbar=' + (N `$C.Danger) + '/' + (N `$C.DangerSoft)
'evidence=' + (N `$C.TextMuted) + '/' + (N `$dc.red.Soft)
'checkrow=' + (N `$C.Text) + '/' + (N `$C.Surface)
'checkresult=' + (N `$dc.green.Text) + '/' + (N `$C.Surface)
'answered=' + (N `$dc.red.Text) + '/' + (N `$dc.red.Soft) + ',' + (N `$dc.green.Text) + '/' + (N `$dc.green.Soft)
"@
        [IO.File]::WriteAllText($tmp, $body, (New-Object Text.UTF8Encoding($true)))
        $out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tmp 2>&1 | ForEach-Object { "$_" })
        $pairs = @($out | Where-Object { $_ -match '^(footer|warnbar|evidence|checkrow|checkresult|answered)=' })
        $pairs.Count | Should -Be 6 -Because ($out -join "`n")
        foreach ($line in $pairs) {
            foreach ($m in [regex]::Matches(($line -replace '^[a-z]+=', ''), '([\w+]*)/([\w+]*)')) {
                Test-AnyIn $m.Groups[1].Value $script:HcAllowedFore | Should -BeTrue -Because $line
                Test-AnyIn $m.Groups[2].Value $script:HcAllowedBack | Should -BeTrue -Because $line
            }
        }
    }
}

Describe 'Review window: list hover tips' {
    It 'shows the full text of the hovered cell only, and only when the column cuts it off (child process)' {
        $kit = Join-Path $script:Repo 'src\SecurityReview\app\QraUi.ps1'
        $fn = $script:ReviewFunctions['Get-RowTipText'].Extent.Text
        $tmp = Join-Path $TestDrive 'tips.ps1'
        $body = @"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. '$kit'
$fn
`$form = New-Object System.Windows.Forms.Form
`$form.ShowInTaskbar = `$false; `$form.Opacity = 0; `$form.Size = New-Object System.Drawing.Size(900, 300)
`$lv = New-Object System.Windows.Forms.ListView
`$lv.View = 'Details'; `$lv.FullRowSelect = `$true; `$lv.Dock = 'Fill'
foreach (`$w in 80, 120, 120) { [void]`$lv.Columns.Add('c', `$w) }
`$it = New-Object System.Windows.Forms.ListViewItem('HIGH')
[void]`$it.SubItems.Add('A finding title that is much too long for a narrow column')
[void]`$it.SubItems.Add('Message 1 > Weekly-schedule.zip > Schedule-demo.exe')
`$it.ToolTipText = 'Message 1 > Weekly-schedule.zip > Schedule-demo.exe'
[void]`$lv.Items.Add(`$it)
`$form.Controls.Add(`$lv); `$form.Show(); [System.Windows.Forms.Application]::DoEvents()
`$y = `$it.Bounds.Top + 3
'sev=' + (Get-RowTipText `$lv (New-Object System.Drawing.Point(20, `$y))).Text
'title=' + (Get-RowTipText `$lv (New-Object System.Drawing.Point(140, `$y))).Text
'where=' + (Get-RowTipText `$lv (New-Object System.Drawing.Point(260, `$y))).Text
'empty=' + (Get-RowTipText `$lv (New-Object System.Drawing.Point(20, 250))).Text
`$form.Close()
"@
        [IO.File]::WriteAllText($tmp, $body, (New-Object Text.UTF8Encoding($true)))
        $out = @(& powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $tmp 2>&1 | ForEach-Object { "$_" })
        $all = $out -join "`n"
        $out | Should -Contain 'sev=' -Because $all
        $out | Should -Contain 'title=A finding title that is much too long for a narrow column' -Because $all
        $out | Should -Contain 'where=Message 1 > Weekly-schedule.zip > Schedule-demo.exe' -Because $all
        $out | Should -Contain 'empty=' -Because $all
    }
}

Describe 'Review window: decision publication' {
    BeforeAll {
        foreach ($name in 'Save-DecisionRecord', 'Invoke-SaveTargets', 'Write-DecisionTarget', 'Get-ReviewRestriction', 'Show-NodeDetails', 'Test-IncompleteReview', 'Update-DecisionOutcome', 'Get-StepsFor') {
            if ($script:ReviewFunctions.ContainsKey($name)) { Import-ReviewFunction $name }
        }
        function Show-SaveOutcome($res) { $res.Failed.Count -eq 0 }
        function Update-ReviewStepper {}
        function Fit-StepsBox {}
        function Get-Records($dir) { Get-ChildItem $dir -Filter 'Decision-*.json' | Where-Object Name -NotLike '*-report.json' }
    }
    BeforeEach {
        $Work = (New-Item -ItemType Directory (Join-Path $TestDrive ([guid]::NewGuid()))).FullName
        $ExportDir = (New-Item -ItemType Directory (Join-Path $TestDrive ([guid]::NewGuid()))).FullName
        $EnvStatus = @{ Export = $true }
        $script:PendingDecision = $null
        $script:RecordedDecision = $null
        $script:CheckRows = @()
        $script:LastText = Join-Path $Work 'last-report.txt'
        $script:LastJson = Join-Path $Work 'last-report.json'
        [IO.File]::WriteAllText($script:LastText, 'Example report')
        [IO.File]::WriteAllText($script:LastJson, '{}')
        $decReviewer = @{ Text = '@example' }
        $decChoice = @{ SelectedItem = 'Keep quarantined (pending verification)' }
        $decNote = @{ Text = "-quoted, `"example`"`r`nsecond line" }
        $script:Result = @{
            messages = @(@{ from_address = '+example'; headers = @{ Subject = "`t=Example" } })
            decision = @{ title = 'Verify'; message_type = 'Mail'; confidence = 'Low' }
            input = @{ name = 'example.eml'; hashes = @{ sha256 = 'abc' } }
        }
    }
    It 'keeps original evidence in JSON and prefixes spreadsheet-sensitive cells in the audit CSV' {
        Save-DecisionRecord
        $records = @(Get-Records $ExportDir)
        $records.Count | Should -Be 1
        $record = Get-Content $records[0].FullName -Raw | ConvertFrom-Json
        $record.reviewer | Should -BeExactly '@example'
        $record.subject | Should -BeExactly "`t=Example"
        $record.note | Should -BeExactly $decNote.Text
        $row = Import-Csv (Join-Path $ExportDir 'decisions-log.csv')
        $row.Reviewer | Should -BeExactly "'@example"
        $row.Subject | Should -BeExactly "'`t=Example"
        $row.Sender | Should -BeExactly "'+example"
        $row.Note | Should -BeExactly "'-quoted, `"example`" second line"
        $record.record_complete | Should -BeTrue
        Get-Content (Join-Path $ExportDir ($records[0].BaseName + '-report.txt')) | Should -BeExactly 'Example report'
        Get-Content (Join-Path $ExportDir ($records[0].BaseName + '-report.json')) | Should -BeExactly '{}'
    }
    It 'publishes only successful targets when the host CSV is locked and retries without duplicating the local decision' {
        $csv = Join-Path $ExportDir 'decisions-log.csv'
        $locked = [IO.File]::Open($csv, 'CreateNew', 'Write', 'None')
        try {
            Save-DecisionRecord
            @(Get-Records $ExportDir).Count | Should -Be 0
            @(Get-Records $Work).Count | Should -Be 1
            $script:RecordedDecision | Should -BeNullOrEmpty
        } finally { $locked.Dispose() }
        Save-DecisionRecord
        $script:RecordedDecision | Should -Be $decChoice.SelectedItem
        (Get-Records $Work).Name | Should -BeExactly (Get-Records $ExportDir).Name
        @(Import-Csv (Join-Path $Work 'decisions-log.csv')).Count | Should -Be 1
        @(Import-Csv $csv).Count | Should -Be 1
    }
    It 'keeps successive decisions with independent companion reports' {
        Save-DecisionRecord
        $decNote.Text = 'Second review'
        Save-DecisionRecord
        @(Get-Records $Work).Count | Should -Be 2
        @(Get-ChildItem $Work -Filter 'Decision-*-report.json').Count | Should -Be 2
    }
    It 'requires separate review for multi-message packages including old reports' {
        $script:Result.container = @{ requires_individual_review = $true; messages = 2 }
        Save-DecisionRecord
        @(Get-Records $Work).Count | Should -Be 0
        $script:Result.container = @{}
        $script:Result.messages += @{ from_address = 'second@example.test' }
        Save-DecisionRecord
        @(Get-Records $Work).Count | Should -Be 0
    }
    It 'requires a fresh analysis before displaying legacy reports with password-bearing nodes' {
        $script:Result.messages[0].children = @(@{ children = @(@{ unlocked_with = 'legacy sample' }) })
        Get-ReviewRestriction $script:Result | Should -Match 'analy'
        Save-DecisionRecord
        @(Get-Records $Work).Count | Should -Be 0
    }
    It 'shows only the provenance of an attachment password' {
        $nodeDetails = @{ Text = '' }
        Show-NodeDetails @{ kind = 'file'; unlock_source = 'operator'; unlocked_with = 'legacy sample' }
        $nodeDetails.Text | Should -Match 'operator'
        $nodeDetails.Text | Should -Not -Match 'legacy sample'
        Show-NodeDetails @{ kind = 'file'; unlock_source = 'message_body' }
        $nodeDetails.Text | Should -Match 'message body'
    }
    It 'keeps incomplete analysis on hold even when an old report includes confirmed checks' {
        $script:Result.complete = $false
        $script:Result.decision.outcome = 'RERUN'
        $script:Result.decision.steps = [pscustomobject]@{ RERUN = @('Analyze again'); RELEASE = @('Release') }
        $script:Result.decision.iocs = @{ sender = 'example' }
        $script:CheckRows = @(@{ Id = 'expected'; Yes = @{ Checked = $true }; No = @{ Checked = $false }; Panel = @{} })
        $decSteps = @{}
        $decCheckResult = @{}
        $decChoice.Enabled = $true
        Update-DecisionOutcome
        $script:EffectiveOutcome | Should -Be 'RERUN'
        $decSteps.Text | Should -Match 'Analyze again'
        $decChoice.Enabled | Should -BeFalse
        $decChoice.SelectedItem = 'Release (false positive, submitted to Microsoft)'
        Save-DecisionRecord
        @(Get-Records $Work).Count | Should -Be 0
        $decChoice.SelectedItem = 'Keep quarantined (pending verification)'
        Save-DecisionRecord
        $record = Get-Content (Get-Records $Work).FullName -Raw | ConvertFrom-Json
        $record.final_decision | Should -Be $decChoice.SelectedItem
        $record.iocs.sender | Should -BeNullOrEmpty
    }
    It 'shows verification steps while release checks are unanswered' {
        $script:Result.complete = $true
        $script:Result.decision.outcome = 'RELEASE'
        $script:Result.decision.steps = [pscustomobject]@{ VERIFY = @('Verify sender'); RELEASE = @('Release') }
        $script:CheckRows = @(@{ Id = 'expected'; Yes = @{ Checked = $false }; No = @{ Checked = $false }; Panel = @{} })
        $decSteps = @{}
        $decCheckResult = @{}
        Update-DecisionOutcome
        $decSteps.Text | Should -Match 'Verify sender'
        $decChoice.SelectedIndex | Should -Be 4
    }
}

Describe 'Review window: -Screenshot' -Tag 'Screenshot' {
    BeforeAll {
        $script:HavePython = [bool](Get-Command python -ErrorAction SilentlyContinue)
        if ($script:HavePython) {
            Push-Location $script:Repo
            try {
                & python tests/make_samples.py *> $null
                if ($LASTEXITCODE -ne 0) { throw "Could not generate screenshot fixtures (Python exit $LASTEXITCODE)." }
                $script:ResultJson = Join-Path $TestDrive 'r.json'
                $secrets = '{"zip_password":"Sample-Pass-123","attachment_passwords":[]}'
                $secrets | & python -I src/SecurityReview/app/inspect_eml.py --input tests/.samples/exe_in_zip.zip --secrets-stdin --json-out $script:ResultJson *> $null
                if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $script:ResultJson -PathType Leaf)) {
                    throw "Could not create the screenshot analysis report (Python exit $LASTEXITCODE)."
                }
            } finally { Pop-Location }
        }
        $script:ReviewStates = 'empty', 'analysing', 'result', 'decision-recorded', 'result-findings', 'result-attachments'
        function Invoke-ReviewShots([string]$dir) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:ReviewPath, '-Screenshot', $dir, '-ScreenshotResult', $script:ResultJson)
            $out = & powershell.exe @psArgs 2>&1
            [pscustomobject]@{ Exit = $LASTEXITCODE; Output = ($out | Out-String) }
        }
    }
    It 'screenshot mode writes every state' {
        if (-not $script:HavePython) { Set-ItResult -Skipped -Because 'python is not on PATH'; return }
        $dir = Join-Path $TestDrive 'shots-native'
        $r = Invoke-ReviewShots $dir
        $r.Exit | Should -Be 0 -Because $r.Output
        foreach ($s in $script:ReviewStates) { Test-Path -LiteralPath (Join-Path $dir "review-$s.png") | Should -BeTrue -Because $s }
    }
    It 'screenshot mode creates no Incoming folder' {
        if (-not $script:HavePython) { Set-ItResult -Skipped -Because 'python is not on PATH'; return }
        $root = Join-Path $TestDrive 'tool-root'
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:Repo 'src\SecurityReview\app') -Destination (Join-Path $root 'app') -Recurse
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'app\QuarantineReview.ps1') -Screenshot (Join-Path $TestDrive 'shots-noio') -ScreenshotResult $script:ResultJson 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($out | Out-String)
        Test-Path -LiteralPath (Join-Path $root 'Incoming') | Should -BeFalse
    }
    It 'screenshot mode writes every state in fallback display mode' {
        if (-not $script:HavePython) { Set-ItResult -Skipped -Because 'python is not on PATH'; return }
        $dir = Join-Path $TestDrive 'shots-fallback'
        $env:QRA_UI_FALLBACK = '1'
        try { $r = Invoke-ReviewShots $dir } finally { Remove-Item Env:\QRA_UI_FALLBACK -ErrorAction SilentlyContinue }
        $r.Exit | Should -Be 0 -Because $r.Output
        foreach ($s in $script:ReviewStates) { Test-Path -LiteralPath (Join-Path $dir "review-$s.png") | Should -BeTrue -Because $s }
    }
}

Describe 'Review window: Attachments split' {
    It 'gives the details pane a usable width once the Attachments tab is shown, keeps 45 % and respects a dragged splitter (child process)' {
        # Runs the real script with its final ShowDialog replaced by a probe, so the real tab and size events are exercised.
        $root = Join-Path $TestDrive 'att-root'
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:Repo 'src\SecurityReview\app') -Destination (Join-Path $root 'app') -Recurse
        $script = Join-Path $root 'app\QuarantineReview.ps1'
        $text = [IO.File]::ReadAllText($script)
        $probe = @'
$form.ShowInTaskbar = $false; $form.Opacity = 0; $form.StartPosition = 'Manual'; $form.Location = New-Object System.Drawing.Point(-32000, -32000)
$form.Show(); [System.Windows.Forms.Application]::DoEvents()
$resultsStage.Visible = $false; $tabs.Visible = $true
$tabs.SelectedTab = $tAttach; [System.Windows.Forms.Application]::DoEvents()
'p2=' + $attSplit.Panel2.Width
'width=' + $attSplit.Width
'dist=' + $attSplit.SplitterDistance
'min2=' + (S 280)
'min1=' + (S 200)
'minsizes=' + $attSplit.Panel1MinSize + '/' + $attSplit.Panel2MinSize
$attSplit.SplitterDistance = (S 300); $script:AttSplitMoved = $true
Set-AttachmentSplit
'afterdrag=' + $attSplit.SplitterDistance + '/' + (S 300)
$form.Dispose(); exit 0
'@
        $idx = $text.LastIndexOf('[void]$form.ShowDialog()')
        $idx | Should -BeGreaterThan 0
        [IO.File]::WriteAllText($script, ($text.Substring(0, $idx) + $probe), (New-Object Text.UTF8Encoding($true)))
        $out = @(& powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $script 2>&1 | ForEach-Object { "$_" })
        $all = $out -join "`n"
        function Get-Probe([string]$key) { [int](($out | Where-Object { $_ -like "$key=*" } | Select-Object -First 1) -replace '^[^=]+=', '') }
        $w = Get-Probe 'width'; $d = Get-Probe 'dist'
        $w | Should -BeGreaterThan 0 -Because $all
        (Get-Probe 'p2') | Should -BeGreaterOrEqual (Get-Probe 'min2') -Because $all
        $d | Should -BeGreaterThan ([int]($w * 0.45) - 8) -Because $all
        $d | Should -BeLessThan ([int]($w * 0.45) + 8) -Because $all
        ($out | Where-Object { $_ -like 'minsizes=*' }) | Should -Be ('minsizes=' + (Get-Probe 'min1') + '/' + (Get-Probe 'min2')) -Because $all
        ($out | Where-Object { $_ -like 'afterdrag=*' }) | Should -Match '^afterdrag=(\d+)/\1$' -Because 'a splitter the user moved is not reset'
    }
    It 'applies the split from the tab and size events, not only from Shown' {
        $t = [IO.File]::ReadAllText($script:ReviewPath)
        $t.Contains('$attSplit.Add_SizeChanged({ Set-AttachmentSplit })') | Should -BeTrue
        $t.Contains('$tabs.Add_SelectedIndexChanged({ if ($tabs.SelectedTab -eq $tAttach) { Set-AttachmentSplit } })') | Should -BeTrue
        $t.Contains('$attSplit.Add_SplitterMoving(') | Should -BeTrue
    }
}

Describe 'Review window: icon and taskbar identity' {
    It 'applies the chrome with the Review app id (not in -Screenshot)' {
        $t = [IO.File]::ReadAllText($script:ReviewPath)
        $t.Contains("Set-QraWindowChrome `$form -AppId 'QuarantineReviewAssistant.Review' -NoAppId:([bool]`$Screenshot)") | Should -BeTrue
    }
}
