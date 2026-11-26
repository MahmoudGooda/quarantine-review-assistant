# Quarantine Review Assistant v2 - review window that runs INSIDE Windows Sandbox.
# Sends no network traffic, renders no email content and never launches attachments.
# The analysis itself is done by inspect_eml.py (offline, in memory).
param([switch]$AllowHost, [string]$Screenshot, [int]$ScreenshotDpi = 0, [switch]$ScreenshotMinSize, [string]$ScreenshotResult, [string]$ScreenshotSize)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Shared UI kit: DPI helpers (S, SPad, SSize, SPoint), design tokens ($C), fonts, painted controls (with plain fallbacks).
. (Join-Path $PSScriptRoot 'QraUi.ps1')
# -ScreenshotDpi: emulate another display scale. Must run before any window exists.
if ($ScreenshotDpi -gt 0) { Set-QraEmulatedDpi $ScreenshotDpi }
$script:LayoutReady = $false
$script:StepUiReady = $false
[System.Windows.Forms.Application]::EnableVisualStyles()
trap {
    if ($Screenshot) { [Console]::Error.WriteLine($_.Exception.Message + "`n" + $_.InvocationInfo.PositionMessage + "`n" + $_.ScriptStackTrace); exit 1 }   # headless: never wait on a dialog
    [System.Windows.Forms.MessageBox]::Show("The review window hit an unexpected error:`r`n`r`n$($_.Exception.Message)`r`n`r`nKeep the message quarantined. You can run C:\Review\Start-Review.cmd to see details.", 'Quarantine Review Assistant', 'OK', 'Error') | Out-Null
    break
}

$AppVersion = '2.3.0'
$ReviewRoot = 'C:\Review'
$AppDir     = $PSScriptRoot
$Incoming   = Join-Path $ReviewRoot 'Incoming'
$PythonExe  = Join-Path $ReviewRoot 'Tools\Python\python.exe'
$Backend    = Join-Path $AppDir 'inspect_eml.py'
$ExportDir  = 'C:\Reports'
$ConfigFile = Join-Path $ReviewRoot 'config\organization.json'
$InSandbox  = ($env:USERNAME -eq 'WDAGUtilityAccount')
$Work       = if ($InSandbox) { 'C:\Work' } else { Join-Path $env:TEMP 'QuarantineReview' }
if (-not $InSandbox -and -not (Test-Path -LiteralPath $PythonExe)) {
    # host test mode: look for the runtime next to the app folder
    $PythonExe = Join-Path (Split-Path -Parent $AppDir) 'Tools\Python\python.exe'
    $Incoming = Join-Path (Split-Path -Parent $AppDir) 'Incoming'
    $ConfigFile = Join-Path (Split-Path -Parent $AppDir) 'config\organization.json'
}
if (-not $Screenshot) { New-Item -ItemType Directory -Force -Path $Work | Out-Null }

# ---------------------------------------------------------------- style
# Design tokens, fonts and the icon glyphs come from the kit. The domain colours below are tuned for contrast on their own backgrounds.
$Sev = @{
    high   = @{ Fore = [System.Drawing.Color]::FromArgb(168, 30, 20);  Back = [System.Drawing.Color]::FromArgb(253, 231, 229); Rank = 3; Label = 'HIGH' }
    medium = @{ Fore = [System.Drawing.Color]::FromArgb(150, 85, 0);   Back = [System.Drawing.Color]::FromArgb(255, 243, 205); Rank = 2; Label = 'MEDIUM' }
    low    = @{ Fore = [System.Drawing.Color]::FromArgb(0, 80, 150);   Back = [System.Drawing.Color]::FromArgb(234, 242, 251); Rank = 1; Label = 'LOW' }
    info   = @{ Fore = [System.Drawing.Color]::FromArgb(90, 100, 115); Back = [System.Drawing.Color]::White;                   Rank = 0; Label = 'INFO' }
}
$Levels = @{
    'HIGH RISK'            = @{ Back = [System.Drawing.Color]::FromArgb(176, 32, 22);  Fore = [System.Drawing.Color]::White }
    'SUSPICIOUS'           = @{ Back = [System.Drawing.Color]::FromArgb(160, 82, 0);   Fore = [System.Drawing.Color]::White }
    'INCOMPLETE'           = @{ Back = [System.Drawing.Color]::FromArgb(92, 99, 112);  Fore = [System.Drawing.Color]::White }
    'NO STRONG INDICATORS' = @{ Back = [System.Drawing.Color]::FromArgb(32, 96, 140);  Fore = [System.Drawing.Color]::White }
}
$Sym = @{ OK = [string][char]0x2714; BAD = [string][char]0x2716; WARN = [string][char]0x25B2; MAIL = [string][char]0x2709; DOT = [string][char]0x25CF; ARROW = [string][char]0x2192 }
function Fmt-Size($n) {
    if ($null -eq $n) { return '' }
    $n = [double]$n
    if ($n -lt 1024) { return ('{0:N0} bytes' -f $n) }
    if ($n -lt 1MB) { return ('{0:N1} KB' -f ($n / 1KB)) }
    return ('{0:N1} MB' -f ($n / 1MB))
}

# ---------------------------------------------------------------- environment status
function Get-EnvStatus {
    $s = [ordered]@{}
    $s.Sandbox = $InSandbox
    $s.Offline = -not [System.Net.NetworkInformation.NetworkInterface]::GetIsNetworkAvailable()
    $ro = $false
    if (Test-Path -LiteralPath $ReviewRoot) {
        $probe = Join-Path $ReviewRoot ('.write-test-' + [guid]::NewGuid().ToString('N'))
        try { [System.IO.File]::WriteAllText($probe, 'x'); Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue } catch { $ro = $true }
    }
    $s.ReadOnly = $ro
    $s.Export = $false
    if (Test-Path -LiteralPath $ExportDir) {
        $probe = Join-Path $ExportDir ('.write-test-' + [guid]::NewGuid().ToString('N'))
        try { [System.IO.File]::WriteAllText($probe, 'x'); Remove-Item -LiteralPath $probe -Force; $s.Export = $true } catch { $null = $_ } # unwritable export dir leaves $s.Export = $false
    }
    return $s
}
# -Screenshot never probes the machine: every chip is faked green.
$EnvStatus = if ($Screenshot) { @{ Sandbox = $true; Offline = $true; ReadOnly = $true; Export = $true } } else { Get-EnvStatus }

# ================================================================= UI skeleton
$form = New-Object System.Windows.Forms.Form
$form.SuspendLayout()
Initialize-QraForm $form
$form.Text = "Quarantine Review Assistant $AppVersion - Offline Sandbox"
$form.Size = New-Object System.Drawing.Size(1320, 860)
$form.MinimumSize = New-Object System.Drawing.Size(1100, 720)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $C.Surface
$form.KeyPreview = $true
Set-QraWindowChrome $form -AppId 'QuarantineReviewAssistant.Review' -NoAppId:([bool]$Screenshot)   # app icon, own taskbar button, navy title bar (Windows 11)

# ---- header with environment pills (the pills are added after scaling: they size themselves from their font)
$header = New-Object System.Windows.Forms.Panel
$header.Dock = 'Top'; $header.Height = 72; $header.BackColor = $C.Header
$hTitle = New-Object System.Windows.Forms.Label
$hTitle.Text = 'Quarantine Review Assistant'; $hTitle.Font = New-Font 16 'Bold' 'Display'; $hTitle.ForeColor = $C.HeaderText
$hTitle.AutoSize = $true; $hTitle.Location = New-Object System.Drawing.Point(20, 10)
$hSub = New-Object System.Windows.Forms.Label
$hSub.Text = 'Offline metadata review  |  nothing is opened, rendered or executed'
$hSub.ForeColor = $C.HeaderSub; $hSub.AutoSize = $true; $hSub.Location = New-Object System.Drawing.Point(22, 44)
$chips = New-Object System.Windows.Forms.FlowLayoutPanel
$chips.Dock = 'Right'; $chips.Width = 560; $chips.FlowDirection = 'RightToLeft'; $chips.WrapContents = $false
$chips.Padding = New-Object System.Windows.Forms.Padding(0, 22, 16, 0); $chips.BackColor = $C.Header
function Add-Chip([string]$text, [bool]$good, [string]$tip) {
    $l = New-QraPill $(if ($good) { 'OK' } else { 'FAIL' }) $text
    $l.Margin = (SPad 6 0 0 0)
    if (-not $script:UiNative) { $l.BackColor = $C.Card; $l.Padding = (SPad 8 2 8 2) }   # plain label: needs its own light background on the navy header
    Set-Access $l ('Status: ' + $text + $(if ($good) { ' (OK)' } else { ' (problem)' })) $tip
    $tt = New-Object System.Windows.Forms.ToolTip; $tt.SetToolTip($l, $tip)
    $chips.Controls.Add($l)
}
$header.Controls.AddRange(@($hTitle, $hSub, $chips))

# ---- warning banner (environment problems)
$envProblems = @()
if (-not $EnvStatus.Sandbox) { $envProblems += 'This window is not running inside Windows Sandbox. Close it and use Start-Here.cmd > Launch Sandbox review on the host.' }
elseif (-not $EnvStatus.Offline) { $envProblems += 'Networking is ON in this Sandbox. Close it and relaunch from the host launcher (it disables networking).' }
if ($EnvStatus.Sandbox -and -not $EnvStatus.ReadOnly) { $envProblems += 'The tool folder is writable from the Sandbox. Relaunch from the host launcher so it is mapped read-only.' }
$warnBar = New-Object System.Windows.Forms.Label
$warnBar.Dock = 'Top'; $warnBar.Height = 34; $warnBar.TextAlign = 'MiddleLeft'
$warnBar.BackColor = $C.DangerSoft; $warnBar.ForeColor = $C.Danger; $warnBar.Font = New-Font 9.5 'Bold'
$warnBar.Padding = New-Object System.Windows.Forms.Padding(20, 0, 0, 0)
$warnBar.Text = "$($Sym.WARN)  " + ($envProblems -join '   ')
$warnBar.Visible = ($envProblems.Count -gt 0)

# ---- main split
$split = New-Object System.Windows.Forms.SplitContainer
$split.Dock = 'Fill'; $split.FixedPanel = 'Panel1'; $split.SplitterWidth = 6
$split.BackColor = $C.Surface
$split.Panel1.Padding = New-Object System.Windows.Forms.Padding(14, 12, 4, 12)
$split.Panel2.Padding = New-Object System.Windows.Forms.Padding(4, 12, 14, 12)

# ================= LEFT: accordion stepper (four step cards)
# Each step is a card (badge, title, one-line summary). The current step is expanded, finished steps collapse to their summary with
# a Change link, later steps are dimmed but can be opened. Nothing is anchored: Update-LeftLayout sets every bound from the real width.
$leftCard = New-Object System.Windows.Forms.Panel
$leftCard.Dock = 'Fill'; $leftCard.BackColor = $C.Surface; $leftCard.AutoScroll = $true
$split.Panel1.Controls.Add($leftCard)

$script:StepUi = @()
$script:StepState = $null
$script:Expanded = 1
$script:IsBusy = $false
$script:CapsOn = $false
$script:PwdUsed = $false
$script:LastElapsed = 0
$script:RecordedDecision = $null
function New-StepCard([int]$num, [string]$title) {
    $card = New-QraCard
    $card.Tag = $num
    $badge = New-QraStepBadge $num
    Set-QraBadgeState $badge 'Pending'
    $ttl = New-Object System.Windows.Forms.Label
    $ttl.Text = $title; $ttl.Font = New-Font 11 'Bold'; $ttl.ForeColor = $C.TextMuted; $ttl.BackColor = $C.Card
    $ttl.AutoSize = $false; $ttl.UseMnemonic = $false
    $sum = New-Object System.Windows.Forms.Label
    $sum.Font = New-Font 9.5; $sum.ForeColor = $C.TextMuted; $sum.BackColor = $C.Card
    $sum.AutoSize = $false; $sum.UseMnemonic = $false; $sum.AutoEllipsis = $true
    $link = New-QraButton 'Open' 'Link'
    $link.Size = New-Object System.Drawing.Size(72, 28); $link.Visible = $false
    $card.Controls.AddRange(@($badge, $ttl, $sum, $link))
    foreach ($kid in @($badge, $ttl, $sum)) { $kid.Cursor = [System.Windows.Forms.Cursors]::Hand; $kid.Add_Click({ Open-ReviewStep ([int]$this.Parent.Tag) }) }
    $link.Add_Click({ Open-ReviewStep ([int]$this.Parent.Tag) })
    $card.Add_Click({ Open-ReviewStep ([int]$this.Tag) })
    $leftCard.Controls.Add($card)
    $script:StepUi += @{ Card = $card; Badge = $badge; Title = $ttl; Summary = $sum; Link = $link; Body = @() }
}
function Add-StepBody([int]$num, $controls) {
    $entry = $script:StepUi[$num - 1]
    foreach ($ctl in @($controls)) { $entry.Card.Controls.Add($ctl); $entry.Body += $ctl }
}
function New-Hint([string]$text, [int]$num) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.ForeColor = $C.TextMuted; $l.AutoSize = $false; $l.UseMnemonic = $false
    Add-StepBody $num $l
    return $l
}
New-StepCard 1 'Choose the package'
New-StepCard 2 'Enter the download password'
New-StepCard 3 'Analyze'
New-StepCard 4 'Decide'

# ---- step 1: choose the package
$hint1 = New-Hint 'Files you saved into Incoming on the host. The newest is selected.' 1
$fileList = New-Object System.Windows.Forms.ListView
$fileList.View = 'Details'; $fileList.FullRowSelect = $true; $fileList.HideSelection = $false; $fileList.MultiSelect = $false
$fileList.HeaderStyle = 'Nonclickable'
$fileList.Size = New-Object System.Drawing.Size(330, 110)
[void]$fileList.Columns.Add('File', (S 200)); [void]$fileList.Columns.Add('Size', (S 60)); [void]$fileList.Columns.Add('Saved', (S 80))
$bBrowse = New-QraButton 'Browse...' 'Secondary' $QraGlyph.Folder
$bBrowse.Size = New-Object System.Drawing.Size(112, 30)
$bRefresh = New-QraButton 'Refresh' 'Secondary' $QraGlyph.Refresh
$bRefresh.Size = New-Object System.Drawing.Size(100, 30)
Add-StepBody 1 @($fileList, $bBrowse, $bRefresh)

# ---- step 2: the download password
$hint2 = New-Hint 'The password you typed in Defender > Download message (not your account password).' 2
$pwdBox = New-Object System.Windows.Forms.TextBox
$pwdBox.UseSystemPasswordChar = $true; $pwdBox.Size = New-Object System.Drawing.Size(230, 26)
$showPwd = New-Object System.Windows.Forms.CheckBox
$showPwd.Text = 'Show'; $showPwd.AutoSize = $true
$bContinue = New-QraButton 'Continue' 'Primary' $QraGlyph.Check
$bContinue.Size = New-Object System.Drawing.Size(130, 34); $bContinue.Enabled = $false
$capsLbl = New-Object System.Windows.Forms.Label
$capsLbl.Text = "$($Sym.WARN) Caps Lock is on"; $capsLbl.ForeColor = $C.Warning; $capsLbl.AutoSize = $true; $capsLbl.Visible = $false
$attLbl = New-Object System.Windows.Forms.Label
$attLbl.Text = 'Attachment passwords (optional, one per line)'; $attLbl.Font = New-Font 9 'Bold'; $attLbl.ForeColor = $C.Text
$attLbl.AutoSize = $false; $attLbl.UseMnemonic = $false
$attPwd = New-Object System.Windows.Forms.TextBox
$attPwd.Multiline = $true; $attPwd.ScrollBars = 'Vertical'; $attPwd.Size = New-Object System.Drawing.Size(330, 46)
$hint3 = New-Hint 'For password-protected ZIPs attached by the sender. Passwords written in the email body are tried automatically.' 2
Add-StepBody 2 @($pwdBox, $showPwd, $capsLbl, $bContinue, $attLbl, $attPwd)

# ---- step 3: analyze (button, Cancel while running, stage tracker with a fixed-width elapsed label so the ticking number never moves anything)
$bAnalyze = New-QraButton 'Analyze' 'Primary' $QraGlyph.Play
$bAnalyze.Font = New-Font 11 'Bold'
$bAnalyze.Size = New-Object System.Drawing.Size(330, 40)
$bCancel = New-QraButton 'Cancel' 'Secondary' $QraGlyph.Cancel
$bCancel.Size = New-Object System.Drawing.Size(100, 40); $bCancel.Visible = $false
Add-StepBody 3 @($bAnalyze, $bCancel)
$script:StageRows = @()
$stageNames = @('Reading file', 'Opening package', 'Analysing message', 'Building report')
for ($i = 0; $i -lt 4; $i++) {
    $sb = New-QraStepBadge ($i + 1)
    Set-QraBadgeState $sb 'Pending'
    $sb.Size = New-Object System.Drawing.Size(22, 22)
    $sl = New-Object System.Windows.Forms.Label
    $sl.Text = $stageNames[$i]; $sl.ForeColor = $C.TextMuted; $sl.AutoSize = $false; $sl.TextAlign = 'MiddleLeft'; $sl.UseMnemonic = $false
    $sl.Size = New-Object System.Drawing.Size(220, 22)
    Add-StepBody 3 @($sb, $sl)
    $script:StageRows += @{ Badge = $sb; Label = $sl }
}
$elapsedLbl = New-Object System.Windows.Forms.Label
$elapsedLbl.Text = '0 s'; $elapsedLbl.ForeColor = $C.TextMuted; $elapsedLbl.AutoSize = $false; $elapsedLbl.TextAlign = 'MiddleRight'
$elapsedLbl.Size = New-Object System.Drawing.Size(80, 22)
Add-StepBody 3 $elapsedLbl

# ---- step 4: decide (the text follows the verdict)
$decision = New-Object System.Windows.Forms.Label
$decision.AutoSize = $false; $decision.UseMnemonic = $false; $decision.Size = New-Object System.Drawing.Size(330, 100)
$decision.ForeColor = $C.TextMuted
$decision.Text = 'Results appear on the right. Then go back to Defender on the host to release, keep or delete the message. Close this Sandbox window when finished: everything in it is destroyed.'
Add-StepBody 4 $decision

# ---- status line under the cards (always visible: errors, "No .zip or .eml in...", "Finished in ...")
$status = New-Object System.Windows.Forms.Label
$status.AutoSize = $false; $status.UseMnemonic = $false; $status.ForeColor = $C.TextMuted; $status.Size = New-Object System.Drawing.Size(330, 20)
$leftCard.Controls.Add($status)

# ================= RIGHT: results
$rightCard = New-Object System.Windows.Forms.Panel
$rightCard.Dock = 'Fill'; $rightCard.BackColor = $C.Card
$split.Panel2.Controls.Add($rightCard)

# Verdict banner: a rounded panel in the decision colour inside a host that gives it a margin. The four count pills are added after scaling.
$verdictHost = New-Object System.Windows.Forms.Panel
$verdictHost.Dock = 'Top'; $verdictHost.Height = 112; $verdictHost.BackColor = $C.Card
$verdictHost.Padding = New-Object System.Windows.Forms.Padding(8, 8, 8, 8)
if ($script:UiNative) { $verdict = New-Object QraUi.RoundPanel; $verdict.Radius = (S 10); $verdict.ShadowSize = 0; $verdict.Stroke = [float](S 1) }
else { $verdict = New-Object System.Windows.Forms.Panel }
$verdict.Dock = 'Fill'
function Set-VerdictColor([System.Drawing.Color]$color) {
    if ($script:UiNative) { $verdict.FillColor = $color; $verdict.BorderColor = $color } else { $verdict.BackColor = $color }
    foreach ($lbl in @($vLevel, $vHead, $vAdvice)) { $lbl.BackColor = $color }
    if ($script:VerdictPills) { $script:VerdictPills.BackColor = $color; foreach ($pl in $script:VerdictPills.Controls) { if (-not $script:UiNative) { $pl.BackColor = $C.Card } } }
}
$vLevel = New-Object System.Windows.Forms.Label
$vLevel.Font = New-Font 17 'Bold' 'Display'; $vLevel.AutoSize = $true; $vLevel.Location = New-Object System.Drawing.Point(18, 10)
$vLevel.Text = 'No analysis yet'; $vLevel.ForeColor = $C.TextMuted;
$vHead = New-Object System.Windows.Forms.Label
$vHead.Font = New-Font 10.5 'Bold'; $vHead.Location = New-Object System.Drawing.Point(20, 44); $vHead.Size = New-Object System.Drawing.Size(860, 22)
$vHead.Text = 'Select a package on the left and click Analyze.'; $vHead.ForeColor = $C.TextMuted;
$vAdvice = New-Object System.Windows.Forms.Label
$vAdvice.Location = New-Object System.Drawing.Point(20, 66); $vAdvice.Size = New-Object System.Drawing.Size(860, 28)
$verdict.Controls.AddRange(@($vLevel, $vHead, $vAdvice))
$verdictHost.Controls.Add($verdict)
Set-VerdictColor $C.Surface
$verdict.Add_Resize({ if ($script:LayoutReady) { Update-HeaderLayout } })

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = 'Fill'; $tabs.Multiline = $true; $tabs.Padding = New-Object System.Drawing.Point((S 14), (S 5)); $tabs.Font = New-Font 9.5

function New-ListView([string[]]$cols, [int[]]$widths) {
    $lv = New-Object System.Windows.Forms.ListView
    $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.GridLines = $false; $lv.Dock = 'Fill'; $lv.HideSelection = $false
    $lv.BorderStyle = 'None'
    for ($i = 0; $i -lt $cols.Count; $i++) { [void]$lv.Columns.Add($cols[$i], (S $widths[$i])) }
    return $lv
}
function New-Tab([string]$title) { $t = New-Object System.Windows.Forms.TabPage; $t.Text = $title; $t.BackColor = $C.Card; $t.Padding = New-Object System.Windows.Forms.Padding(8); [void]$tabs.TabPages.Add($t); return $t }
function New-ReadOnlyText([bool]$mono = $false) {
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Multiline = $true; $tb.ReadOnly = $true; $tb.ScrollBars = 'Both'; $tb.WordWrap = (-not $mono); $tb.Dock = 'Fill'
    $tb.BackColor = $C.Card; $tb.BorderStyle = 'None'
    if ($mono) { $tb.Font = New-Font 9 'Regular' 'Mono' }
    if (-not $mono) { $tb.ScrollBars = 'Vertical' }
    return $tb
}

$tDecision = New-Tab 'Decision'
$decPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$decPanel.Dock = 'Fill'; $decPanel.FlowDirection = 'TopDown'; $decPanel.WrapContents = $false; $decPanel.AutoScroll = $true
$decPanel.Padding = New-Object System.Windows.Forms.Padding(6, 6, 6, 20); $decPanel.BackColor = $C.Card
$tDecision.Controls.Add($decPanel)
$decCheckResult = New-Object System.Windows.Forms.Label
$decCheckResult.AutoSize = $true; $decCheckResult.Font = New-Font 10.5 'Bold'; $decCheckResult.Tag = 'wrap'
$decCheckResult.Margin = (SPad 0 8 0 4)
$decSteps = New-Object System.Windows.Forms.TextBox
$decSteps.Multiline = $true; $decSteps.ReadOnly = $true; $decSteps.BorderStyle = 'None'; $decSteps.BackColor = $C.Surface
$decSteps.Font = New-Font 10; $decSteps.ScrollBars = 'None'
# NOTE: the controls of the record panel are not in the form tree at ResumeLayout, so they are scaled with S().
$decRecordPanel = New-Object System.Windows.Forms.Panel
$decRecordPanel.Height = (S 112); $decRecordPanel.BackColor = $C.Surface
$decChoiceLbl = New-Object System.Windows.Forms.Label
$decChoiceLbl.Text = 'Final decision'; $decChoiceLbl.Location = (SPoint 10 12); $decChoiceLbl.AutoSize = $true
$decChoice = New-Object System.Windows.Forms.ComboBox
$decChoice.DropDownStyle = 'DropDownList'; $decChoice.Location = (SPoint 110 8); $decChoice.Width = (S 300)
[void]$decChoice.Items.AddRange(@('Delete and block', 'Release (false positive, submitted to Microsoft)', 'Release to user (bulk / marketing)', 'Delete (unwanted, no block)', 'Keep quarantined (pending verification)'))
$decRevLbl = New-Object System.Windows.Forms.Label
$decRevLbl.Text = 'Reviewer'; $decRevLbl.Location = (SPoint 424 12); $decRevLbl.AutoSize = $true
$decReviewer = New-Object System.Windows.Forms.TextBox
$decReviewer.Location = (SPoint 490 8); $decReviewer.Width = (S 160)
$decNoteLbl = New-Object System.Windows.Forms.Label
$decNoteLbl.Text = 'Note'; $decNoteLbl.Location = (SPoint 10 46); $decNoteLbl.AutoSize = $true
$decNote = New-Object System.Windows.Forms.TextBox
$decNote.Location = (SPoint 110 42); $decNote.Width = (S 540)
$bRecord = New-QraButton 'Record decision' 'Primary' $QraGlyph.Check
$bRecord.Location = (SPoint 110 74); $bRecord.Size = (SSize 170 32)
$decRecordPanel.Controls.AddRange(@($decChoiceLbl, $decChoice, $decRevLbl, $decReviewer, $decNoteLbl, $decNote, $bRecord))

$tSummary = New-Tab 'Summary'
$lvSummary = New-ListView @('Item', 'Value') @(190, 760)
$tSummary.Controls.Add($lvSummary)

$tFindings = New-Tab 'Findings'
$lvFindings = New-ListView @('Severity', 'Finding', 'Where', 'Details', 'ATT&CK') @(80, 300, 300, 480, 90)
$findDetail = New-ReadOnlyText $false
$findDetail.Dock = 'Bottom'; $findDetail.Height = 104; $findDetail.Font = New-Font 9.5; $findDetail.BackColor = $C.Surface
$findDetail.Text = 'Select a finding to see its full location and details.'
$tFindings.Controls.Add($lvFindings); $tFindings.Controls.Add($findDetail)

$tAttach = New-Tab 'Attachments'
$attSplit = New-Object System.Windows.Forms.SplitContainer
$attSplit.Dock = 'Fill'
$tree = New-Object System.Windows.Forms.TreeView
$tree.Dock = 'Fill'; $tree.BorderStyle = 'None'; $tree.HideSelection = $false; $tree.Font = New-Font 10; $tree.ItemHeight = (S 24); $tree.ShowNodeToolTips = $true
$nodeDetails = New-ReadOnlyText $true
$attSplit.Panel1.Controls.Add($tree); $attSplit.Panel2.Controls.Add($nodeDetails)
$tAttach.Controls.Add($attSplit)
# The split has no real width until the Attachments tab is shown (a hidden tab page keeps the default 150 px), so the 45 % distance is applied
# whenever the split is laid out at a usable width, unless the user dragged the splitter.
$script:AttSplitMoved = $false
$script:AttSplitApplying = $false
function Set-AttachmentSplit {
    if ($script:AttSplitMoved -or $script:AttSplitApplying) { return }
    $min1 = S 200; $min2 = S 280
    $w = $attSplit.Width
    if ($w -le ($min1 + $min2 + $attSplit.SplitterWidth)) { return }   # not laid out yet (or too narrow for both panes)
    $script:AttSplitApplying = $true
    try {
        $attSplit.Panel1MinSize = $min1; $attSplit.Panel2MinSize = $min2
        $want = [int]($w * 0.45)
        $attSplit.SplitterDistance = [Math]::Max($min1, [Math]::Min($want, $w - $min2 - $attSplit.SplitterWidth))
    } catch { $null = $_ } # ignore if the window is too narrow for the requested splitter distance
    finally { $script:AttSplitApplying = $false }
}
$attSplit.Add_SplitterMoving({ if (-not $script:AttSplitApplying) { $script:AttSplitMoved = $true } })   # raised only while the user drags
$attSplit.Add_SizeChanged({ Set-AttachmentSplit })
$tabs.Add_SelectedIndexChanged({ if ($tabs.SelectedTab -eq $tAttach) { Set-AttachmentSplit } })

$tLinks = New-Tab 'Links'
$lvLinks = New-ListView @('Risk', 'Link (defanged - not clickable)', 'Why flagged', 'Found in') @(70, 460, 330, 260)
$tLinks.Controls.Add($lvLinks)

$tHeaders = New-Tab 'Headers'
$lvHeaders = New-ListView @('Header / check', 'Value') @(240, 900)
$tHeaders.Controls.Add($lvHeaders)

$tBody = New-Tab 'Message text'
$bodyNote = New-Object System.Windows.Forms.Label
$bodyNote.Dock = 'Top'; $bodyNote.Height = 24; $bodyNote.ForeColor = $C.TextMuted
$bodyNote.Text = 'Plain-text extract only. HTML is never rendered and no images or remote content are loaded.'
$bodyText = New-ReadOnlyText $false
$bodyText.Font = New-Font 10
$tBody.Controls.Add($bodyText); $tBody.Controls.Add($bodyNote)

$tRaw = New-Tab 'Full report'
$rawText = New-ReadOnlyText $true
$tRaw.Controls.Add($rawText)

# ---- results stage: shown instead of the tabs while there is no result (empty prompt, or the large spinner while analysing).
# Its content is created after scaling (Initialize-ResultsStage), so it can use S().
$resultsStage = New-Object System.Windows.Forms.Panel
$resultsStage.Dock = 'Fill'; $resultsStage.BackColor = $C.Card; $resultsStage.Visible = $false
$resultsStage.Add_Resize({ if ($script:LayoutReady) { Update-StageLayout } })

# ---- bottom action bar
$actions = New-Object System.Windows.Forms.Panel
$actions.Dock = 'Bottom'; $actions.Height = 52; $actions.BackColor = $C.Card
$bSave = New-QraButton 'Save report' 'Secondary'
$bSave.Size = New-Object System.Drawing.Size(130, 32); $bSave.Location = New-Object System.Drawing.Point(14, 10); $bSave.Enabled = $false
$bClear = New-QraButton 'New review' 'Secondary' $QraGlyph.Refresh
$bClear.Size = New-Object System.Drawing.Size(124, 32); $bClear.Location = New-Object System.Drawing.Point(152, 10)
$saveInfo = New-Object System.Windows.Forms.Label
$saveInfo.Location = New-Object System.Drawing.Point(290, 16); $saveInfo.Size = New-Object System.Drawing.Size(700, 22); $saveInfo.ForeColor = $C.TextMuted
$saveInfo.Text = if ($EnvStatus.Export) { 'Saves .txt + .json to C:\Work and to the host Reports folder.' } else { 'Saves to C:\Work inside this Sandbox only (lost when it closes).' }
$actions.Controls.AddRange(@($bSave, $bClear, $saveInfo))
$actions.Add_Resize({ if ($script:LayoutReady) { Update-HeaderLayout } })

$rightCard.Controls.Add($tabs)
$rightCard.Controls.Add($resultsStage)
$rightCard.Controls.Add($actions)
$rightCard.Controls.Add($verdictHost)

$form.Controls.Add($split)
$form.Controls.Add($warnBar)
$form.Controls.Add($header)

$footer = New-Object System.Windows.Forms.Label
$footer.Dock = 'Bottom'; $footer.Height = 26; $footer.TextAlign = 'MiddleLeft'; $footer.Padding = New-Object System.Windows.Forms.Padding(20, 0, 0, 0)
$footer.ForeColor = $C.Danger; $footer.BackColor = $C.DangerSoft
$footer.Text = 'Not a malware scanner. "No strong indicators" is never a safe verdict. Verify the sender through a known channel before releasing.'
$form.Controls.Add($footer)

# ================================================================= Decision tab (recommendation, scorecard, checks, steps, record)
# Decision colours. Back = banner fill, OnBack = text on it, Soft = row fill, Text = coloured text on Soft.
# In high contrast every fill and text colour is a system colour (no fixed pastels): the user's theme decides.
function New-DecisionColors([bool]$HighContrast = [bool]$script:QraHighContrast) {
    if ($HighContrast) {
        $sc = [System.Drawing.SystemColors]
        $one = @{ Back = $sc::Highlight; OnBack = $sc::HighlightText; Soft = $sc::Window; Text = $sc::WindowText }
        $set = @{}
        foreach ($k in 'red', 'amber', 'green', 'blue', 'grey') { $set[$k] = $one.Clone() }
        return $set
    }
    $set = @{
        red   = @{ Back = [System.Drawing.Color]::FromArgb(176, 32, 22);  Soft = [System.Drawing.Color]::FromArgb(253, 231, 229) }
        amber = @{ Back = [System.Drawing.Color]::FromArgb(160, 82, 0);  Soft = [System.Drawing.Color]::FromArgb(255, 243, 205) }
        green = @{ Back = [System.Drawing.Color]::FromArgb(22, 120, 52);  Soft = [System.Drawing.Color]::FromArgb(226, 244, 230) }
        blue  = @{ Back = [System.Drawing.Color]::FromArgb(24, 92, 160);  Soft = [System.Drawing.Color]::FromArgb(228, 238, 250) }
        grey  = @{ Back = [System.Drawing.Color]::FromArgb(92, 99, 112);  Soft = [System.Drawing.Color]::FromArgb(236, 238, 242) }
    }
    # Text colour for coloured text on the Soft background (amber needs a darker shade than its banner colour).
    foreach ($k in @($set.Keys)) { $set[$k].Text = $set[$k].Back; $set[$k].OnBack = [System.Drawing.Color]::White }
    $set.amber.Text = [System.Drawing.Color]::FromArgb(150, 85, 0)
    return $set
}
$DecColors = New-DecisionColors
$script:CheckRows = @()
$script:EffectiveOutcome = $null

function New-WrapLabel([string]$text, [float]$size = 9.5, [string]$style = 'Regular', $color = $null) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.AutoSize = $true; $l.Font = New-Font $size $style
    $l.MaximumSize = New-Object System.Drawing.Size([Math]::Max((S 400), $decPanel.ClientSize.Width - (S 60)), 0)
    $l.Margin = (SPad 0 2 0 2)
    $l.Tag = 'wrap'
    if ($color) { $l.ForeColor = $color }
    return $l
}
function New-Section([string]$title) {
    $l = New-WrapLabel $title 11.5 'Bold' $C.Text
    $l.Margin = (SPad 0 16 0 6)
    [void]$decPanel.Controls.Add($l)
}
function Set-WrapIn($ctl, [int]$w) {
    foreach ($inner in $ctl.Controls) {
        if ($inner -is [System.Windows.Forms.Label] -and $inner.Tag -eq 'wrap') {
            $inner.MaximumSize = New-Object System.Drawing.Size([Math]::Max((S 200), $w - $inner.Left - (S 24)), 0)
        } elseif ($inner.Controls.Count) { Set-WrapIn $inner $w }
    }
}
function Set-DecWidths {
    $w = [Math]::Max((S 400), $decPanel.ClientSize.Width - (S 40))
    $decPanel.SuspendLayout()
    foreach ($ctl in $decPanel.Controls) {
        if ($ctl -is [System.Windows.Forms.Label] -and $ctl.Tag -eq 'wrap') { $ctl.MaximumSize = New-Object System.Drawing.Size(($w - (S 10)), 0); continue }
        if ($ctl -is [System.Windows.Forms.Panel] -and $ctl.AutoSize) {
            $ctl.MinimumSize = New-Object System.Drawing.Size($w, 0); $ctl.MaximumSize = New-Object System.Drawing.Size($w, 0)
            Set-WrapIn $ctl ($w - (S 30))
        } elseif ($ctl -is [System.Windows.Forms.Panel] -or $ctl -is [System.Windows.Forms.TextBox]) {
            $ctl.Width = $w
            Set-WrapIn $ctl $w
            $lbl = @($ctl.Controls | Where-Object { $_ -is [System.Windows.Forms.Label] -and $_.Tag -eq 'wrap' }) | Select-Object -First 1
            if ($lbl -and @($ctl.Controls | Where-Object { $_ -is [System.Windows.Forms.RadioButton] }).Count) {
                $ctl.Height = [Math]::Max((S 40), $lbl.Top + $lbl.PreferredHeight + (S 10))
            }
        }
    }
    Fit-StepsBox
    Fit-RecordPanel
    $decPanel.ResumeLayout()
}

$decPanel.Add_Resize({ Set-DecWidths })   # registered here: the handler needs the function above to exist

# Left card: nothing is anchored. Every bound comes from the real card width: cards stack top-down, the expanded card's height comes from
# its content (Measure-Wrapped for the texts), collapsed cards are one header tall.
function Set-LeftBounds([int]$W) {
    $ins = if ($script:UiNative) { [int]$script:StepUi[0].Card.ShadowSize } else { 0 }
    $pad = S 14; $y = S 2
    for ($n = 1; $n -le 4; $n++) {
        $e = $script:StepUi[$n - 1]
        $open = ($n -eq $script:Expanded)
        $stp = if ($script:StepState) { $script:StepState.Steps[$n - 1] } else { $null }
        $hasSum = [bool]$e.Summary.Text
        $tx = $ins + $pad + $e.Badge.Width + (S 10)
        $linkW = S 76
        $tw = [Math]::Max((S 60), $W - $tx - $ins - $pad - $(if ($open) { 0 } else { $linkW }))
        $titleH = $e.Title.Font.Height + (S 2)
        $sumH = if ($hasSum) { $e.Summary.Font.Height + (S 2) } else { 0 }
        $hdrH = [Math]::Max($e.Badge.Height, $titleH + $sumH)
        $top = $ins + (S 12)
        $e.Badge.Location = New-Object System.Drawing.Point(($ins + $pad), ($top + [int](($hdrH - $e.Badge.Height) / 2)))
        $e.Title.SetBounds($tx, ($top + [int](($hdrH - $titleH - $sumH) / 2)), $tw, $titleH)
        $e.Summary.SetBounds($tx, $e.Title.Bottom, $tw, $sumH); $e.Summary.Visible = $hasSum
        $e.Link.Size = New-Object System.Drawing.Size($linkW, (S 28))
        $e.Link.Location = New-Object System.Drawing.Point(($W - $ins - $pad - $linkW + (S 6)), ($top + [int](($hdrH - (S 28)) / 2)))
        $e.Link.Visible = -not $open
        $e.Title.ForeColor = if ($stp -and $stp.State -eq 'Pending') { $C.TextMuted } else { $C.Text }
        if ($script:UiNative) { $e.Card.BorderColor = if ($stp -and $stp.State -in 'Current', 'Working') { $C.Primary } else { $C.Border } }
        foreach ($ctl in $e.Body) { $ctl.Visible = $open }
        $bx = $tx; $bw = [Math]::Max((S 160), $W - $tx - $ins - $pad)
        $by = $top + $hdrH + (S 10)
        if ($open) {
            switch ($n) {
                1 {
                    $h = (Measure-Wrapped $hint1.Text $hint1.Font $bw) + (S 2)
                    $hint1.SetBounds($bx, $by, $bw, $h); $by += $h + (S 6)
                    $fileList.SetBounds($bx, $by, $bw, (S 110)); $by += (S 110) + (S 8)
                    $fw = [Math]::Max((S 80), $bw - (S 64) - (S 84) - (S 6))
                    $fileList.Columns[0].Width = $fw; $fileList.Columns[1].Width = (S 64); $fileList.Columns[2].Width = (S 84)
                    $bBrowse.Location = New-Object System.Drawing.Point($bx, $by)
                    $bRefresh.Location = New-Object System.Drawing.Point(($bx + $bBrowse.Width + (S 8)), $by)
                    $by += $bBrowse.Height
                }
                2 {
                    $h = (Measure-Wrapped $hint2.Text $hint2.Font $bw) + (S 2)
                    $hint2.SetBounds($bx, $by, $bw, $h); $by += $h + (S 6)
                    $showW = $showPwd.PreferredSize.Width
                    $pwdBox.SetBounds($bx, $by, [Math]::Max((S 100), $bw - $showW - (S 8)), $pwdBox.Height)
                    $showPwd.Location = New-Object System.Drawing.Point(($bx + $bw - $showW), ($by + [int](($pwdBox.Height - $showPwd.Height) / 2)))
                    $by += $pwdBox.Height + (S 4)
                    $capsLbl.Visible = $script:CapsOn
                    if ($script:CapsOn) { $capsLbl.Location = New-Object System.Drawing.Point($bx, $by); $by += $capsLbl.Height + (S 2) }
                    $by += (S 6)
                    $bContinue.Location = New-Object System.Drawing.Point($bx, $by); $by += $bContinue.Height + (S 12)
                    $attLbl.SetBounds($bx, $by, $bw, ($attLbl.Font.Height + (S 2))); $by += $attLbl.Height + (S 2)
                    $attPwd.SetBounds($bx, $by, $bw, (S 46)); $by += (S 46) + (S 6)
                    $h = (Measure-Wrapped $hint3.Text $hint3.Font $bw) + (S 2)
                    $hint3.SetBounds($bx, $by, $bw, $h); $by += $h
                }
                3 {
                    $bAnalyze.Location = New-Object System.Drawing.Point($bx, $by)
                    if ($script:IsBusy) {
                        $bCancel.Visible = $true
                        $bAnalyze.Width = [Math]::Max((S 100), $bw - $bCancel.Width - (S 8))
                        $bCancel.Location = New-Object System.Drawing.Point(($bx + $bAnalyze.Width + (S 8)), $by)
                    } else { $bCancel.Visible = $false; $bAnalyze.Width = $bw }
                    $by += $bAnalyze.Height + (S 12)
                    $rowH = S 26
                    $ew = [System.Windows.Forms.TextRenderer]::MeasureText('600 s', $elapsedLbl.Font).Width + (S 6)
                    $elapsedLbl.SetBounds(($bx + $bw - $ew), $by, $ew, $rowH)
                    for ($k = 0; $k -lt $script:StageRows.Count; $k++) {
                        $row = $script:StageRows[$k]; $ry = $by + $k * $rowH
                        $row.Badge.SetBounds($bx, ($ry + [int](($rowH - (S 22)) / 2)), (S 22), (S 22))
                        $row.Label.SetBounds(($bx + (S 30)), $ry, [Math]::Max((S 80), $elapsedLbl.Left - $bx - (S 30) - (S 8)), $rowH)
                    }
                    $by += $rowH * $script:StageRows.Count
                }
                4 {
                    $h = (Measure-Wrapped $decision.Text $decision.Font $bw) + (S 2)
                    $decision.SetBounds($bx, $by, $bw, $h); $by += $h
                }
            }
            $cardH = $by + (S 14) + $ins
        } else {
            $cardH = $top + $hdrH + (S 12) + $ins
        }
        $e.Card.SetBounds(0, $y, $W, $cardH)
        $y += $cardH + (S 2)
    }
    $sx = $ins + (S 6); $sw = [Math]::Max((S 100), $W - 2 * $sx)
    if ($status.Text) {
        $status.SetBounds($sx, ($y + (S 4)), $sw, ((Measure-Wrapped $status.Text $status.Font $sw) + (S 2))); $status.Visible = $true
    } else { $status.Visible = $false }
}
function Update-LeftLayout {
    if (-not $script:LayoutReady -or -not $script:StepUiReady -or $script:InLeftLayout) { return }
    $script:InLeftLayout = $true
    try {
        for ($pass = 0; $pass -lt 2; $pass++) {
            $used = $leftCard.ClientSize.Width
            $leftCard.SuspendLayout()
            Set-LeftBounds $used
            $leftCard.ResumeLayout($true)
            if ($leftCard.ClientSize.Width -eq $used) { break }   # a scroll bar appeared or went away: lay out once more at the new width
        }
    } finally { $script:InLeftLayout = $false }
}

# Keeps the eight tab headers on one row: when they would wrap (large display scale), the side padding of each header shrinks.
function Fit-TabPadding {
    if (-not $script:LayoutReady -or $tabs.TabCount -eq 0 -or $tabs.ClientSize.Width -lt 100) { return }
    $fl = [System.Windows.Forms.TextFormatFlags]::NoPadding -bor [System.Windows.Forms.TextFormatFlags]::SingleLine -bor [System.Windows.Forms.TextFormatFlags]::NoPrefix
    $sum = 0
    foreach ($tp in $tabs.TabPages) { $sum += [System.Windows.Forms.TextRenderer]::MeasureText($tp.Text, $tabs.Font, (New-Object System.Drawing.Size(10000, 100)), $fl).Width }
    $room = $tabs.ClientSize.Width - $sum - (S 6)
    $padX = [Math]::Max((S 4), [Math]::Min((S 14), [int][Math]::Floor($room / (2 * $tabs.TabCount))))
    # a change of 1 px is ignored: the control's own width moves by a pixel when the padding changes, which would loop
    if ([Math]::Abs($tabs.Padding.X - $padX) -ge 2 -and -not $script:InTabFit) {
        $script:InTabFit = $true
        try { $tabs.Padding = New-Object System.Drawing.Point($padX, (S 5)) } finally { $script:InTabFit = $false }
    }
}
$tabs.Add_Resize({ Fit-TabPadding })
# Header: the verdict texts and the save-bar text follow the window width; status pills are never cut off.
function Update-HeaderLayout {
    $vHead.Width = [Math]::Max((S 100), $verdict.Width - $vHead.Left - (S 20))
    $vAdvice.Width = [Math]::Max((S 100), $verdict.Width - $vAdvice.Left - (S 20))
    $vAdvice.Height = [Math]::Max((S 28), (Measure-Wrapped $vAdvice.Text $vAdvice.Font $vAdvice.Width) + (S 2))   # a second line must not be cut off
    $pw = if ($script:VerdictPills) { $script:VerdictPills.PreferredSize.Width } else { 0 }
    # The count pills sit at the top right. When a long title (or a narrow window) would run into them, they move under the advice text.
    if ($script:VerdictPills -and $vLevel.Right + (S 16) -gt ($verdict.Width - $pw - (S 16))) {
        $script:VerdictPills.Location = New-Object System.Drawing.Point((S 20), ($vAdvice.Bottom + (S 4)))
        $inner = $vAdvice.Bottom + (S 4) + $script:VerdictPills.PreferredSize.Height + (S 10)
    } else {
        if ($script:VerdictPills) { $script:VerdictPills.Location = New-Object System.Drawing.Point(($verdict.Width - $pw - (S 16)), (S 12)) }
        $inner = $vAdvice.Bottom + (S 6)
    }
    $verdictHost.Height = [Math]::Max((S 96), $inner) + $verdictHost.Padding.Vertical
    $verdictHost.PerformLayout()
    $saveInfo.Width = [Math]::Max((S 100), $actions.Width - $saveInfo.Left - (S 14))
    $saveInfo.Height = [Math]::Max((S 22), (Measure-Wrapped $saveInfo.Text $saveInfo.Font ($saveInfo.Width - (S 8))) + (S 2))   # measured a little narrower: the label may wrap a word earlier than the measurement
    $actions.Height = [Math]::Max((S 52), $saveInfo.Top + $saveInfo.Height + (S 12))
}

# Record panel: when the window is narrower than the design (high DPI on a small screen) the boxes shrink instead of running off the edge.
function Fit-RecordPanel {
    $w = $decRecordPanel.ClientSize.Width; $pad = S 10
    $comboW = if ($w -ge (S 660)) { S 300 } else { [Math]::Max((S 170), [int](($w - (S 110) - $pad) * 0.46)) }
    $decChoice.Width = $comboW
    $decRevLbl.Left = $decChoice.Left + $comboW + (S 14)
    $decReviewer.Left = $decRevLbl.Left + (S 66)
    $decReviewer.Width = [Math]::Max((S 90), [Math]::Min((S 160), $w - $decReviewer.Left - $pad))
    $decNote.Width = [Math]::Max((S 200), [Math]::Min((S 540), $w - $decNote.Left - $pad))
}
function Fit-Chips {
    $need = $chips.Padding.Horizontal
    foreach ($chip in $chips.Controls) { $need += $chip.PreferredSize.Width + $chip.Margin.Horizontal }
    if ($need -gt $chips.Width) { $chips.Width = $need }
}
$leftCard.Add_Resize({ Update-LeftLayout })
$vAdvice.Add_TextChanged({ if ($script:LayoutReady) { Update-HeaderLayout } })
$vLevel.Add_TextChanged({ if ($script:LayoutReady) { Update-HeaderLayout } })
$status.Add_TextChanged({ Update-LeftLayout })
$decision.Add_TextChanged({ Update-LeftLayout })

# The Defender-steps box is as tall as its text (no empty space, no inner scrollbar).
function Fit-StepsBox {
    if (-not $decSteps.Text) { $decSteps.Height = (S 40); return }
    $wText = [Math]::Max((S 100), $decSteps.ClientSize.Width - (S 6))
    $flags = [System.Windows.Forms.TextFormatFlags]::WordBreak -bor [System.Windows.Forms.TextFormatFlags]::NoPadding -bor [System.Windows.Forms.TextFormatFlags]::TextBoxControl
    $sz = [System.Windows.Forms.TextRenderer]::MeasureText($decSteps.Text, $decSteps.Font, (New-Object System.Drawing.Size($wText, 0)), $flags)
    $decSteps.Height = [Math]::Max((S 40), $sz.Height + (S 12))
}

# Size a list view's columns to their text (header or content), within a minimum and a maximum (96-dpi pixels).
function Fit-Columns($lv, [int[]]$min, [int[]]$max) {
    $font = $lv.Font
    for ($i = 0; $i -lt $lv.Columns.Count; $i++) {
        $w = [System.Windows.Forms.TextRenderer]::MeasureText([string]$lv.Columns[$i].Text, $font).Width
        foreach ($it in $lv.Items) {
            $txt = if ($i -eq 0) { $it.Text } elseif ($i -lt $it.SubItems.Count) { $it.SubItems[$i].Text } else { '' }
            $tw = [System.Windows.Forms.TextRenderer]::MeasureText([string]$txt, $font).Width
            if ($tw -gt $w) { $w = $tw }
        }
        $lv.Columns[$i].Width = [Math]::Min((S $max[$i]), [Math]::Max((S $min[$i]), $w + (S 20)))
    }
}

# Hover tooltip for list cells: the full text of the cell under the mouse, only when its column cuts it off.
# Shown by hand because ListView item tooltips are unreliable over sub-item cells.
$script:RowTip = New-Object System.Windows.Forms.ToolTip
$script:RowTip.AutoPopDelay = 30000; $script:RowTip.ReshowDelay = 0
$script:RowTipKey = $null
function Get-RowTipText($lv, $point) {
    $none = @{ Key = $null; Text = '' }
    $hit = $lv.HitTest($point)
    if (-not $hit.Item -or -not $hit.SubItem) { return $none }
    $col = $hit.Item.SubItems.IndexOf($hit.SubItem)
    if ($col -lt 0 -or $col -ge $lv.Columns.Count) { return $none }
    $key = '{0}:{1}' -f $hit.Item.Index, $col
    $text = [string]$hit.SubItem.Text
    # the cell padding is about 6 px on each side at 96 dpi
    $need = [System.Windows.Forms.TextRenderer]::MeasureText($text, $lv.Font).Width + (S 12)
    if (-not $text -or $need -le $lv.Columns[$col].Width) { return @{ Key = $key; Text = '' } }
    return @{ Key = $key; Text = $text }
}
function Enable-RowTips($lv) {
    $lv.Add_MouseMove({ param($s, $e)
        $t = Get-RowTipText $s $e.Location
        if ($t.Key -ne $script:RowTipKey) {
            $script:RowTipKey = $t.Key
            $script:RowTip.Hide($s)
            if ($t.Text) { $script:RowTip.Show($t.Text, $s, ($e.X + (S 16)), ($e.Y + (S 22)), 30000) }
        }
    })
    $lv.Add_MouseLeave({ param($s, $e) $script:RowTipKey = $null; $script:RowTip.Hide($s) })
}

function Show-FindingDetail {
    $f = $null
    if ($lvFindings.SelectedItems.Count) { $f = $lvFindings.SelectedItems[0].Tag }
    if (-not $f) { $findDetail.Text = 'Select a finding to see its full location and details.'; return }
    $lines = @(('[{0}]  {1}' -f $Sev[[string]$f.severity].Label, [string]$f.title),
               ('Where:   ' + [string]$f.where),
               ('ATT&CK:  ' + $(if ($f.attack) { [string]$f.attack } else { '-' })))
    if ($f.detail) { $lines += ''; $lines += [string]$f.detail }
    $findDetail.Text = ($lines -join "`r`n")
}

# Save helper: try every target on its own and report exactly which one failed and why.
function Invoke-SaveTargets([scriptblock]$Action) {
    $targets = @($Work); if ($EnvStatus.Export) { $targets += $ExportDir }
    $saved = New-Object System.Collections.Generic.List[string]
    $failed = New-Object System.Collections.Generic.List[string]
    foreach ($t in $targets) {
        $label = if ($t -eq $ExportDir) { "$t  (host Reports folder)" } else { "$t  (inside Sandbox - deleted on close)" }
        try { & $Action $t; [void]$saved.Add($label) } catch {
            $why = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }   # the real reason, not the .NET wrapper text
            [void]$failed.Add("$label`r`n      $why")
        }
    }
    return [pscustomobject]@{ Saved = @($saved); Failed = @($failed) }
}
function Show-SaveOutcome($res, [string]$okTitle, [string]$okText, [string]$tail) {
    $mb = [System.Windows.Forms.MessageBox]
    if (-not $res.Saved.Count) {
        [void]$mb::Show("No destination completed the save.`r`n`r`nFailed:`r`n  " + ($res.Failed -join "`r`n  ") + "`r`n`r`nFix the problem above and try again.", 'Not saved', 'OK', 'Error')
        return $false
    }
    if ($res.Failed.Count) {
        # Partly saved: do not say "recorded" and do not send the reviewer on to Defender as if the record were complete.
        $msg = "NOT FULLY SAVED. This was written only to:`r`n  " + ($res.Saved -join "`r`n  ")
        $msg += "`r`n`r`nCould NOT save to:`r`n  " + ($res.Failed -join "`r`n  ")
        $msg += "`r`n`r`nFix the problem at the failed destination (for example close a locked file) and use the button again."
        [void]$mb::Show($msg, ($okTitle -replace ' recorded', '') + ' - NOT fully saved', 'OK', 'Warning')
        return $false
    } else {
        $msg = "$okText`r`n`r`nSaved to:`r`n  " + ($res.Saved -join "`r`n  ")
        [void]$mb::Show($msg + "`r`n`r`n$tail", $okTitle, 'OK', 'Information')
    }
    return $true   # fully saved: the caller may mark the step as done
}

function Get-StepsFor([string]$outcome) {
    $d = $script:Result.decision
    if ($outcome -eq 'DISCARD') { return @('Delete it (or leave it to expire). No blocking is needed for unwanted marketing.', 'Optionally tell the user they can unsubscribe from the sender.') }
    $p = $d.steps.PSObject.Properties[$outcome]
    if ($p) { return @($p.Value) } else { return @() }
}

function Test-IncompleteReview($r) {
    return (($null -ne $r.complete -and -not $r.complete) -or $r.decision.outcome -eq 'RERUN' -or $r.assessment.level -eq 'INCOMPLETE')
}

function Update-DecisionOutcome {
    $d = $script:Result.decision
    if (-not $d) { return }
    $answered = 0; $no = 0; $total = @($script:CheckRows).Count
    foreach ($row in $script:CheckRows) {
        if ($row.Yes.Checked) { $answered++ } elseif ($row.No.Checked) { $answered++; $no++ }
        $row.Panel.BackColor = if ($row.No.Checked) { $DecColors.red.Soft } elseif ($row.Yes.Checked) { $DecColors.green.Soft } else { $C.Surface }
    }
    $eff = [string]$d.outcome
    $incomplete = Test-IncompleteReview $script:Result
    $decChoice.Enabled = -not $incomplete
    if ($incomplete) {
        $eff = 'RERUN'
    } elseif ($total -gt 0) {
        if ($no -gt 0) {
            $eff = if ($d.outcome -eq 'BULK') { 'DISCARD' } else { 'DELETE' }
            $decCheckResult.Text = "$($Sym.BAD)  A check failed: " + [string]$d.if_any_no
            $decCheckResult.ForeColor = $DecColors.red.Text
        } elseif ($answered -eq $total) {
            $eff = if ($d.outcome -eq 'BULK') { 'BULK' } elseif ($d.auth_only) { 'RELEASE_SPOOF' } else { 'RELEASE' }
            $decCheckResult.Text = "$($Sym.OK)  All confirmed: " + [string]$d.if_all_yes
            $decCheckResult.ForeColor = $DecColors.green.Text
        } else {
            $eff = 'VERIFY'
            $decCheckResult.Text = "Answer all $total checks ($answered done). Until then: keep it in quarantine."
            $decCheckResult.ForeColor = $C.TextMuted
        }
    }
    $script:EffectiveOutcome = $eff
    $steps = @(Get-StepsFor $eff)
    $n = 0
    $decSteps.Text = (($steps | ForEach-Object { $n++; "$n.  $_" }) -join "`r`n`r`n")
    Fit-StepsBox
    $map = @{ DELETE = 0; RELEASE = 1; RELEASE_SPOOF = 1; BULK = 2; DISCARD = 3; VERIFY = 4; RERUN = 4 }
    if ($map.ContainsKey($eff)) { $decChoice.SelectedIndex = $map[$eff] }
}

function Show-Decision($r) {
    $d = $r.decision
    $incomplete = Test-IncompleteReview $r
    $decPanel.SuspendLayout()
    $decPanel.Controls.Clear()
    $script:CheckRows = @()
    if (-not $d) { $decPanel.ResumeLayout(); return }
    $col = $DecColors[[string]$d.color]; if (-not $col) { $col = $DecColors.grey }

    # --- recommendation card
    $card = New-Object System.Windows.Forms.Panel
    $card.BackColor = $col.Back; $card.Padding = (SPad 18 12 18 14)
    $card.Margin = (SPad 0 0 0 6); $card.AutoSize = $true; $card.AutoSizeMode = 'GrowAndShrink'
    $cardFlow = New-Object System.Windows.Forms.FlowLayoutPanel
    $cardFlow.FlowDirection = 'TopDown'; $cardFlow.WrapContents = $false; $cardFlow.AutoSize = $true; $cardFlow.Dock = 'Fill'; $cardFlow.BackColor = $col.Back
    $onBack = $col.OnBack
    $t1 = New-WrapLabel ([string]$d.title) 18 'Bold' $onBack
    $t2 = New-WrapLabel ("Confidence: $($d.confidence)     Type: $($d.message_type)") 10.5 'Bold' $onBack
    $t3 = New-WrapLabel ([string]$d.summary) 10.5 'Regular' $onBack
    $t4 = New-WrapLabel ('Why: ' + [string]$d.why) 9.5 'Regular' $(if ($script:QraHighContrast) { $onBack } else { [System.Drawing.Color]::FromArgb(240, 240, 240) })
    $cardFlow.Controls.AddRange(@($t1, $t2, $t3, $t4))
    if ($d.microsoft_note) { $cardFlow.Controls.Add((New-WrapLabel ("Microsoft: " + [string]$d.microsoft_note) 9.5 'Bold' $onBack)) }
    $card.Controls.Add($cardFlow)
    [void]$decPanel.Controls.Add($card)

    # --- scorecard
    New-Section 'The five questions'
    foreach ($sc in @($d.scorecard)) {
        if (-not $sc) { continue }
        $sCol = $DecColors[[string]$sc.status]; if (-not $sCol) { $sCol = $DecColors.grey }
        $row = New-Object System.Windows.Forms.Panel
        $row.BackColor = $sCol.Soft; $row.Margin = (SPad 0 0 0 4)
        $row.Padding = (SPad 8 6 8 6); $row.AutoSize = $true; $row.AutoSizeMode = 'GrowAndShrink'
        $rf = New-Object System.Windows.Forms.FlowLayoutPanel
        $rf.FlowDirection = 'TopDown'; $rf.WrapContents = $false; $rf.AutoSize = $true; $rf.Dock = 'Fill'; $rf.BackColor = $sCol.Soft
        $head = New-WrapLabel ("$($Sym.DOT)  " + [string]$sc.question + '   ' + [string]$sc.answer) 10 'Bold' $sCol.Text
        $rf.Controls.Add($head)
        foreach ($ev in @($sc.evidence | Select-Object -First 4)) { if ($ev) { $rf.Controls.Add((New-WrapLabel ("      - " + [string]$ev) 9 'Regular' $C.TextMuted)) } }
        $row.Controls.Add($rf)
        [void]$decPanel.Controls.Add($row)
    }

    # --- human checks
    if (-not $incomplete -and @($d.checks).Count -gt 0) {
        New-Section 'Confirm before releasing (only you can check these)'
        foreach ($ck in @($d.checks)) {
            if (-not $ck) { continue }
            $p = New-Object System.Windows.Forms.Panel
            $p.Height = (S 40); $p.BackColor = $C.Surface; $p.Margin = (SPad 0 0 0 4)
            $yes = New-Object System.Windows.Forms.RadioButton
            $yes.Text = 'Yes'; $yes.Location = (SPoint 8 10); $yes.Size = (SSize 52 22); Set-Access $yes ('Yes: ' + [string]$ck.text)
            $no = New-Object System.Windows.Forms.RadioButton
            $no.Text = 'No'; $no.Location = (SPoint 62 10); $no.Size = (SSize 48 22); Set-Access $no ('No: ' + [string]$ck.text)
            $lt = New-WrapLabel ([string]$ck.text) 9.5 'Regular' $C.Text
            $lt.Location = (SPoint 118 11)
            $p.Controls.AddRange(@($yes, $no, $lt))
            $yes.Add_CheckedChanged({ Update-DecisionOutcome })
            $no.Add_CheckedChanged({ Update-DecisionOutcome })
            $script:CheckRows += @{ Id = [string]$ck.id; Text = [string]$ck.text; Yes = $yes; No = $no; Panel = $p }
            [void]$decPanel.Controls.Add($p)
        }
        [void]$decPanel.Controls.Add($decCheckResult)
    }

    # --- steps
    New-Section 'What to do in Defender'
    [void]$decPanel.Controls.Add($decSteps)

    # --- block list
    $io = if (-not $incomplete) { $d.iocs }
    $lines = @()
    if ($io.sender) { $lines += "Sender:        $($io.sender)" }
    if ($io.sender_domain) { $lines += "Sender domain: $($io.sender_domain)" }
    foreach ($x in @($io.domains)) { if ($x) { $lines += "Link domain:   $x" } }
    foreach ($x in @($io.urls)) { if ($x) { $lines += "URL:           $x" } }
    foreach ($x in @($io.sha256)) { if ($x) { $lines += "SHA256:        $x" } }
    foreach ($x in @($io.not_blocked)) { if ($x) { $lines += "NOT blocked:   $x  (shared service - blocking would stop legitimate mail)" } }
    if ($lines.Count) {
        New-Section 'Block list (Tenant Allow/Block List - only if you block)'
        $bl = New-Object System.Windows.Forms.TextBox
        $bl.Multiline = $true; $bl.ReadOnly = $true; $bl.ScrollBars = 'Vertical'; $bl.Font = New-Font 9 'Regular' 'Mono'
        $bl.Height = (S ([Math]::Min(200, 20 * $lines.Count + 10))); $bl.BackColor = $C.Card; Set-Access $bl 'Block list' 'Sender, domains, URLs and file hashes to add to the Tenant Allow/Block List'
        $bl.Text = ($lines -join "`r`n")
        [void]$decPanel.Controls.Add($bl)
        [void]$decPanel.Controls.Add((New-WrapLabel ($(if ($EnvStatus.Export) { 'Recording the decision also saves this list to the Reports folder on the host, ready to copy from the launcher.' } else { 'Enable report export in the launcher to save this list on the host.' })) 9 'Regular' $C.TextMuted))
    }

    # --- spoof allow pair (authentication-only false positives)
    if (-not $incomplete -and $d.spoof_pair) {
        New-Section 'Spoof allow pair (use only after the sender is confirmed)'
        $sp = New-Object System.Windows.Forms.TextBox
        $sp.ReadOnly = $true; $sp.Font = New-Font 10 'Regular' 'Mono'; $sp.BackColor = $C.Card; $sp.Text = [string]$d.spoof_pair; Set-Access $sp 'Spoof allow pair'
        [void]$decPanel.Controls.Add($sp)
        [void]$decPanel.Controls.Add((New-WrapLabel 'Tenant Allow/Block List > Spoofed senders > Add > Allow, External. Allows only this sender from this sending infrastructure.' 9 'Regular' $C.TextMuted))
    }

    # --- record
    New-Section 'Record your decision'
    [void]$decPanel.Controls.Add($decRecordPanel)
    $decNote.Text = ''
    [void]$decPanel.Controls.Add((New-WrapLabel ([string]$d.disclaimer) 8.5 'Italic' $C.TextMuted))
    $decPanel.ResumeLayout()
    Set-DecWidths
    Update-DecisionOutcome
}

function Get-ReviewRestriction($r) {
    $messages = @($r.messages | Where-Object { $_ })
    if ($r.container.requires_individual_review -or $r.container.messages -gt 1 -or $messages.Count -gt 1) {
        return 'Keep this package quarantined. Download and analyze each message separately before recording a decision.'
    }
    # Older analyzers copied credentials into the tree and body preview. Their text report may contain them too.
    $legacy = 'This report used an older password format. Analyze the original package again to view its results.'
    foreach ($entry in $r.unlocked) { if ($entry.password) { return $legacy } }
    $nodes = New-Object System.Collections.Stack
    foreach ($node in @($messages) + @($r.other)) { if ($node) { $nodes.Push($node) } }
    while ($nodes.Count) {
        $node = $nodes.Pop()
        if ($node.password_hints -or $node.unlocked_with) { return $legacy }
        foreach ($child in $node.children) { if ($child) { $nodes.Push($child) } }
    }
}

function Write-DecisionTarget([string]$target, [string]$id, $record) {
    $stem = Join-Path $target "Decision-$id"
    $staged = Join-Path $target ".$id.pending"
    $created = New-Object System.Collections.Generic.List[string]
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    try {
        foreach ($ext in 'txt', 'json') {
            $source = if ($ext -eq 'txt') { $script:LastText } else { $script:LastJson }
            $dest = "$stem-report.$ext"
            $inputStream = [IO.File]::OpenRead($source)
            try {
                $outputStream = [IO.File]::Open($dest, 'CreateNew', 'Write', 'None')
                try {
                    $created.Add($dest)
                    $inputStream.CopyTo($outputStream)
                    $outputStream.Flush($true)
                } finally { $outputStream.Dispose() }
            } finally { $inputStream.Dispose() }
        }
        $stageStream = [IO.File]::Open($staged, 'CreateNew', 'Write', 'None')
        try {
            $created.Add($staged)
            $bytes = $utf8.GetBytes(($record | ConvertTo-Json -Depth 6))
            $stageStream.Write($bytes, 0, $bytes.Length)
            $stageStream.Flush($true)
        } finally { $stageStream.Dispose() }

        $fields = 'recorded_local', 'reviewer', 'final_decision', 'tool_recommendation', 'confidence', 'message_type', 'microsoft_verdict', 'sender', 'subject', 'input_sha256', 'note'
        $cells = foreach ($field in $fields) {
            $value = [string]$record[$field]
            if ($value -match '^[\t\r\n]|^[\s\p{Cc}\p{Cf}]*[=+@\-\uFF1D\uFF0B\uFF0D\uFF20]') { $value = "'" + $value }
            '"' + ($value -replace '\r\n|[\r\n]', ' ' -replace '"', '""') + '"'
        }
        # Hold the log exclusively through publication so rollback cannot truncate another reviewer's row.
        $csv = [IO.File]::Open((Join-Path $target 'decisions-log.csv'), 'OpenOrCreate', 'ReadWrite', 'None')
        try {
            $length = $csv.Length
            $csv.Position = $length
            try {
                if ($length -eq 0) {
                    $header = [char]0xFEFF + "Recorded,Reviewer,Final decision,Tool recommendation,Confidence,Type,Microsoft verdict,Sender,Subject,Input SHA256,Note`r`n"
                    $bytes = $utf8.GetBytes($header)
                    $csv.Write($bytes, 0, $bytes.Length)
                }
                $bytes = $utf8.GetBytes(($cells -join ',') + "`r`n")
                $csv.Write($bytes, 0, $bytes.Length)
                $csv.Flush($true)
                [IO.File]::Move($staged, "$stem.json")
            } catch {
                $csv.SetLength($length)
                $csv.Flush($true)
                throw
            }
            $created.Clear()
        } finally { $csv.Dispose() }
    } finally {
        foreach ($path in $created) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    }
}

function Save-DecisionRecord {
    $r = $script:Result
    if (-not $r -or (Get-ReviewRestriction $r)) { return }
    $d = $r.decision
    $incomplete = Test-IncompleteReview $r
    if ($incomplete -and $decChoice.SelectedItem -ne 'Keep quarantined (pending verification)') { return }
    $m = @($r.messages | Where-Object { $_ }) | Select-Object -First 1
    $answers = [ordered]@{}
    foreach ($row in $script:CheckRows) { $answers[$row.Id] = if ($row.Yes.Checked) { 'yes' } elseif ($row.No.Checked) { 'no' } else { 'unanswered' } }
    $record = [ordered]@{
        record_complete  = $true
        reviewer         = $decReviewer.Text
        final_decision   = [string]$decChoice.SelectedItem
        note             = $decNote.Text
        tool_recommendation = [string]$d.title
        confidence       = [string]$d.confidence
        message_type     = [string]$d.message_type
        microsoft_verdict = if ($m) { [string]$m.eop_category } else { '' }
        sender           = if ($m) { [string]$m.from_address } else { '' }
        subject          = if ($m -and $m.headers) { [string]$m.headers.Subject } else { '' }
        input_file       = [string]$r.input.name
        input_sha256     = [string]$r.input.hashes.sha256
        checks           = $answers
        iocs             = if (-not $incomplete) { $d.iocs } else { $null }
        spoof_pair       = if (-not $incomplete) { [string]$d.spoof_pair } else { '' }
    }
    # Preserve the original timestamp and skip already-published targets on a retry of the same decision.
    $key = $record | ConvertTo-Json -Depth 6 -Compress
    if (-not $script:PendingDecision -or $key -cne $script:PendingDecision.Key) {
        $now = Get-Date
        $script:PendingDecision = @{
            Key = $key; Id = $now.ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N')
            Time = $now.ToString('yyyy-MM-dd HH:mm:ss'); Published = @{}
        }
    }
    $pending = $script:PendingDecision
    $record.recorded_local = $pending.Time
    $res = Invoke-SaveTargets {
        param($t)
        if (-not $pending.Published[$t]) {
            Write-DecisionTarget $t $pending.Id $record
            $pending.Published[$t] = $true
        }
    }
    if (Show-SaveOutcome $res 'Decision recorded' "Decision recorded: $($record.final_decision)" 'Now carry it out in the Defender portal on the host.') {
        $script:RecordedDecision = [string]$record.final_decision
        Update-ReviewStepper
    }
}

# ================================================================= stepper state
# Pure: turns the facts the window can observe into the four step states. The password itself is never part of the facts,
# so a summary can never contain it.
function Get-ReviewStepState([hashtable]$Facts) {
    $titles = @('Choose the package', 'Enter the download password', 'Analyze', 'Decide')
    $fileName = [string]$Facts.FileName
    $fileSize = [string]$Facts.FileSize
    $analyzing = [bool]$Facts.Analyzing
    $result = [bool]$Facts.ResultShown
    $recorded = [string]$Facts.RecordedDecision
    $done = @((-not [string]::IsNullOrEmpty($fileName)), ([bool]$Facts.PasswordEntered -or $result), $result, (-not [string]::IsNullOrEmpty($recorded)))
    $summary = @('', '', '', '')
    if ($done[0]) { $summary[0] = if ($fileSize) { "$fileName ($fileSize)" } else { $fileName } }
    if ($done[1]) { $summary[1] = 'Password entered' }
    if ($done[2]) { $summary[2] = 'Finished in {0} s' -f [int]$Facts.ElapsedSeconds }
    if ($done[3]) { $summary[3] = $recorded }
    # A later phase means the earlier steps are over: a running analysis or a result implies the file and password were used.
    $reached = if ($done[3]) { 3 } elseif ($result) { 2 } elseif ($analyzing) { 2 } else { 0 }
    for ($i = 0; $i -lt $reached; $i++) { $done[$i] = $true }
    $steps = @(); $current = 0
    for ($i = 0; $i -lt 4; $i++) {
        if ($current -ne 0) { $state = 'Pending' }
        elseif ($i -eq 2 -and $analyzing -and -not $result) { $state = 'Working'; $current = $i + 1 }
        elseif ($done[$i]) { $state = 'Done' }
        else { $state = 'Current'; $current = $i + 1 }
        $steps += [pscustomobject]@{ Index = $i + 1; Title = $titles[$i]; State = $state; Summary = $summary[$i] }
    }
    if ($current -eq 0) { $current = 4 }
    # The package was opened but its password was refused (or absent): the next thing to do is step 2 again, not the decision.
    $rejected = [string]$Facts.PasswordRejected
    if ($result -and $rejected -in 'wrong', 'missing') {
        $steps[1].State = 'Warning'
        foreach ($i in 2, 3) { if ($steps[$i].State -eq 'Current') { $steps[$i].State = 'Pending' } }   # the step after a refused password waits
        $steps[1].Summary = if ($rejected -eq 'wrong') { 'Wrong password - enter it again' } else { 'Password missing - enter it' }
        $current = 2
    }
    [pscustomobject]@{ Steps = $steps; Current = $current }
}

function Get-ReviewFacts {
    $name = $null; $size = ''
    if ($fileList.SelectedItems.Count) {
        $it = $fileList.SelectedItems[0]; $name = $it.Text
        if ($it.SubItems.Count -gt 1) { $size = $it.SubItems[1].Text }
    }
    @{ FileName = $name; FileSize = $size; PasswordEntered = (($pwdBox.Text.Length -gt 0) -or $script:PwdUsed); Analyzing = [bool]$script:Run
       ResultShown = [bool]$script:Result; PasswordRejected = $(if ($script:Result) { [string]$script:Result.container.password_status } else { $null }); ElapsedSeconds = [int]$script:LastElapsed; RecordedDecision = $script:RecordedDecision }
}

# Re-reads the facts and restyles the four cards. The expanded card follows the current step, except while the user is typing the
# password (-Keep): the password card must not fold away under their hands.
function Update-ReviewStepper([switch]$Keep) {
    if (-not $script:StepUiReady) { return }
    $leaf = Get-FocusLeaf
    $state = Get-ReviewStepState (Get-ReviewFacts)
    $script:StepState = $state
    if (-not $Keep) { $script:Expanded = $state.Current }
    for ($i = 0; $i -lt 4; $i++) {
        $entry = $script:StepUi[$i]; $stp = $state.Steps[$i]
        Set-QraBadgeState $entry.Badge $stp.State
        $entry.Summary.Text = $stp.Summary
        $entry.Link.Text = if ($stp.State -eq 'Done') { 'Change' } else { 'Open' }
        $desc = "Step $($stp.Index) of 4, $($stp.Title), " + $(if ($stp.Summary) { $stp.Summary } else { $stp.State.ToLowerInvariant() })
        Set-Access $entry.Card $desc
        Set-Access $entry.Link ("$($entry.Link.Text) step $($stp.Index): $($stp.Title)")
    }
    Update-LeftLayout
    if ($leaf -and -not $leaf.Visible) { Set-ReviewStepFocus $script:Expanded }   # the focused control was folded away: keep the keyboard user going
}
# The control of the left column that has the keyboard focus (a card link or a control inside a card), or $null.
function Get-FocusLeaf {
    foreach ($entry in $script:StepUi) { foreach ($ctl in (@($entry.Link) + $entry.Body)) { if ($ctl.Focused) { return $ctl } } }
    return $null
}
function Set-ReviewStepFocus([int]$num) {
    switch ($num) {
        1 { [void]$fileList.Focus() }
        2 { [void]$pwdBox.Focus() }
        3 { if ($bCancel.Visible) { [void]$bCancel.Focus() } elseif ($bAnalyze.Enabled) { [void]$bAnalyze.Focus() } }
    }
}
function Open-ReviewStep([int]$num) {
    if ($script:Expanded -eq $num) { return }
    $script:Expanded = $num
    Update-LeftLayout
    Set-ReviewStepFocus $num
    try { $leftCard.ScrollControlIntoView($script:StepUi[$num - 1].Card) } catch { $null = $_ } # best-effort scroll
}

# ================================================================= data -> UI
$script:Result = $null
$script:Run = $null
$script:LastJson = Join-Path $Work 'last-report.json'
$script:LastText = Join-Path $Work 'last-report.txt'
$script:ProgressFile = Join-Path $Work 'progress.txt'

function Refresh-Files([string]$select) {
    $fileList.BeginUpdate(); $fileList.Items.Clear()
    $files = @()
    if (Test-Path -LiteralPath $Incoming) {
        $files = @(Get-ChildItem -LiteralPath $Incoming -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.zip', '.eml' } | Sort-Object LastWriteTime -Descending)
    }
    foreach ($f in $files) {
        $it = New-Object System.Windows.Forms.ListViewItem($f.Name)
        [void]$it.SubItems.Add((Fmt-Size $f.Length)); [void]$it.SubItems.Add($f.LastWriteTime.ToString('HH:mm dd/MM'))
        $it.Tag = $f.FullName; $it.ToolTipText = $f.FullName
        [void]$fileList.Items.Add($it)
    }
    if ($select) {
        $found = $false
        foreach ($it in $fileList.Items) { if ($it.Tag -eq $select) { $it.Selected = $true; $found = $true } }
        if (-not $found) {
            $it = New-Object System.Windows.Forms.ListViewItem([System.IO.Path]::GetFileName($select))
            [void]$it.SubItems.Add(''); [void]$it.SubItems.Add('browsed'); $it.Tag = $select
            [void]$fileList.Items.Insert(0, $it); $it.Selected = $true
        }
    } elseif ($fileList.Items.Count) { $fileList.Items[0].Selected = $true }
    $fileList.EndUpdate()
    if (-not $fileList.Items.Count) {
        $status.Text = "No .zip or .eml in $Incoming. Save the Defender download there on the host (Sandbox sees it immediately), then click Refresh."
    }
}
function Get-SelectedFile { if ($fileList.SelectedItems.Count) { return [string]$fileList.SelectedItems[0].Tag } return $null }

$script:DecisionDefault = 'Results appear on the right. Then go back to Defender on the host to release, keep or delete the message. Close this Sandbox window when finished: everything in it is destroyed.'
function Clear-Results {
    $script:Result = $null
    $script:PendingDecision = $null
    $script:RecordedDecision = $null; $script:PwdUsed = $false; $script:LastElapsed = 0
    $decision.Text = $script:DecisionDefault; $decision.ForeColor = $C.TextMuted
    foreach ($lv in @($lvSummary, $lvFindings, $lvLinks, $lvHeaders)) { $lv.Items.Clear() }
    $tree.Nodes.Clear(); $nodeDetails.Text = ''; $bodyText.Text = ''; $rawText.Text = ''; $findDetail.Text = 'Select a finding to see its full location and details.'
    Set-VerdictColor $C.Surface
    $vLevel.Text = 'No analysis yet'; $vLevel.ForeColor = $C.TextMuted
    $vHead.Text = 'Select a package on the left and click Analyze.'; $vHead.ForeColor = $C.TextMuted
    $vAdvice.Text = ''; Set-VerdictPills $null
    $tFindings.Text = 'Findings'; $tAttach.Text = 'Attachments'; $tLinks.Text = 'Links'
    $decPanel.Controls.Clear(); $script:CheckRows = @()
    $bSave.Enabled = $false
    Reset-StageTracker
    Set-ResultsMode 'Empty'
    Update-ReviewStepper
}

function Add-Row($lv, [string[]]$cells, $sevKey = $null, [bool]$bold = $false) {
    $it = New-Object System.Windows.Forms.ListViewItem($cells[0])
    for ($i = 1; $i -lt $cells.Count; $i++) { [void]$it.SubItems.Add([string]$cells[$i]) }
    if ($sevKey -and $Sev.ContainsKey($sevKey)) { $it.BackColor = $Sev[$sevKey].Back; $it.ForeColor = $Sev[$sevKey].Fore; $it.UseItemStyleForSubItems = $true }
    if ($bold) { $it.Font = New-Font 9.5 'Bold' }
    [void]$lv.Items.Add($it)
    return $it
}

function Get-WorstSeverity([string]$where, [bool]$subtree) {
    $best = $null; $rank = -1
    foreach ($f in @($script:Result.findings)) {
        if (-not $f) { continue }
        $w = [string]$f.where
        $hit = ($w -eq $where) -or ($subtree -and $w.StartsWith($where + ' > '))
        if ($hit -and $Sev[$f.severity].Rank -gt $rank) { $rank = $Sev[$f.severity].Rank; $best = [string]$f.severity }
    }
    return $best
}

function Get-NodeText($n) {
    if ($n.kind -eq 'message') {
        $subj = ''
        if ($n.headers -and $n.headers.Subject) { $subj = [string]$n.headers.Subject }
        return "$($Sym.MAIL)  Email: " + $(if ($subj) { $subj } else { '(no subject)' })
    }
    $bits = @()
    if ($n.signature) { $bits += $n.signature }
    if ($null -ne $n.size) { $bits += (Fmt-Size $n.size) }
    if ($n.encryption -and $n.encryption -ne 'none') { $bits += ('encrypted:' + $n.encryption) }
    $tagList = @($n.tags | Where-Object { $_ })
    if ($tagList -contains 'unlocked with candidate password') { $bits += 'unlocked' }
    $label = [string]$n.name
    if ($bits.Count) { $label += '   (' + ($bits -join ', ') + ')' }
    return $label
}

function Add-TreeNode($parentCollection, $n) {
    $where = [string]$n.where
    $worst = if ($where) { Get-WorstSeverity $where $true } else { $null }
    $tn = New-Object System.Windows.Forms.TreeNode((Get-NodeText $n))
    $tn.Tag = $n
    if ($worst) {
        $tn.ForeColor = $Sev[$worst].Fore
        if ($worst -in 'high', 'medium') { $tn.Text = "[$($Sev[$worst].Label)]  " + $tn.Text }
    }
    if ($n.note) { $tn.ToolTipText = [string]$n.note }
    [void]$parentCollection.Add($tn)
    foreach ($ch in @($n.children)) { if ($ch) { [void](Add-TreeNode $tn.Nodes $ch) } }
    return $tn
}

function Show-NodeDetails($n) {
    if (-not $n) { $nodeDetails.Text = ''; return }
    $L = New-Object System.Collections.Generic.List[string]
    if ($n.kind -eq 'message') {
        $L.Add('EMAIL MESSAGE'); $L.Add('')
        foreach ($k in 'From', 'Reply-To', 'Return-Path', 'To', 'Cc', 'Subject', 'Date', 'Message-ID') { if ($n.headers.$k) { $L.Add(('{0,-12} {1}' -f ($k + ':'), $n.headers.$k)) } }
        $L.Add('')
        $L.Add(('{0,-12} {1}' -f 'Size:', (Fmt-Size $n.size)))
        $L.Add(('{0,-12} {1}' -f 'Attachments:', $n.attachment_count))
    } else {
        $L.Add([string]$n.name); $L.Add('')
        $L.Add(('{0,-14} {1}' -f 'Location:', $n.where))
        $L.Add(('{0,-14} {1}' -f 'Content type:', $(if ($n.signature) { $n.signature } else { 'not recognised' })))
        if ($n.mime) { $L.Add(('{0,-14} {1}' -f 'Declared MIME:', $n.mime)) }
        if ($null -ne $n.size) { $L.Add(('{0,-14} {1}' -f 'Size:', (Fmt-Size $n.size))) }
        if ($n.encryption -and $n.encryption -ne 'none') { $L.Add(('{0,-14} {1}' -f 'Encryption:', $n.encryption)) }
        switch ($n.unlock_source) {
            'operator' { $L.Add('Password source: operator') }
            'message_body' { $L.Add('Password source: message body') }
        }
        $tags = @($n.tags | Where-Object { $_ })
        if ($tags.Count) { $L.Add(('{0,-14} {1}' -f 'Tags:', ($tags -join ', '))) }
        if ($n.note) { $L.Add(('{0,-14} {1}' -f 'Note:', $n.note)) }
        if ($n.pdf) { $L.Add(('{0,-14} {1}' -f 'PDF objects:', (($n.pdf.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '  '))) }
    }
    if ($n.hashes) {
        $L.Add(''); $L.Add('HASHES (look these up on the HOST - never upload the file)')
        $L.Add(('SHA256  {0}' -f $n.hashes.sha256)); $L.Add(('SHA1    {0}' -f $n.hashes.sha1)); $L.Add(('MD5     {0}' -f $n.hashes.md5))
    }
    $own = @($script:Result.findings | Where-Object { $_ -and ([string]$_.where -eq [string]$n.where) })
    if ($own.Count) {
        $L.Add(''); $L.Add('FINDINGS HERE')
        foreach ($f in $own) { $L.Add(('  [{0}] {1}' -f $Sev[$f.severity].Label, $f.title)); if ($f.detail) { $L.Add('         ' + $f.detail) } }
    }
    $nodeDetails.Text = ($L -join "`r`n")
}

function Show-Result($r) {
    $restriction = Get-ReviewRestriction $r
    if ($restriction) {
        Clear-Results
        $script:stText.Text = $restriction
        $decision.Text = $restriction
        $status.Text = $restriction
        $status.ForeColor = $C.Danger
        Update-StageLayout
        return
    }
    $script:Result = $r
    $asm = $r.assessment
    $lvl = [string]$asm.level
    $dd = $r.decision
    $dcol = if ($dd) { $DecColors[[string]$dd.color] } else { $null }
    $style = @{ Back = $(if ($dcol) { $dcol.Back } else { $Levels['INCOMPLETE'].Back }); Fore = $(if ($dcol) { $dcol.OnBack } else { [System.Drawing.Color]::White }) }
    if ($script:QraHighContrast) { $style = @{ Back = [System.Drawing.SystemColors]::Highlight; Fore = [System.Drawing.SystemColors]::HighlightText } }
    Set-VerdictColor $style.Back
    $vLevel.Text = if ($dd) { [string]$dd.title } else { $lvl }; $vLevel.ForeColor = $style.Fore
    $vHead.Text = if ($dd) { "Confidence: $($dd.confidence)   |   $($dd.message_type)" } else { [string]$asm.headline }; $vHead.ForeColor = $style.Fore
    $vAdvice.Text = if ($dd) { [string]$dd.summary + '  Open the Decision tab.' } else { [string]$asm.advice }; $vAdvice.ForeColor = $style.Fore
    Set-VerdictPills $asm
    $decision.Text = switch ($lvl) {
        'HIGH RISK' { "$($Sym.BAD) Do NOT release. In Defender: keep quarantined or delete; block sender/URLs if appropriate; search for the same message in other mailboxes (Threat Explorer)." }
        'SUSPICIOUS' { "$($Sym.WARN) Confirm with the sender through a known channel (phone/Teams, not by replying). Release only if the business reason and attachment are confirmed." }
        'INCOMPLETE' { "$($Sym.WARN) The review did not finish. Fix the error shown (often the password) and analyze again. Until then: keep quarantined." }
        default { 'No strong indicators - still verify the sender and context before releasing. Static checks cannot see everything (e.g. QR images, zero-days).' }
    }
    if ($dd) { $decision.Text = [string]$dd.title + ': ' + [string]$dd.summary + ' Follow the Decision tab, then act in Defender on the host.' }
    $decision.ForeColor = $style.Back
    Show-Decision $r

    # ---- summary
    $lvSummary.BeginUpdate(); $lvSummary.Items.Clear()
    foreach ($e in @($r.errors)) { if ($e) { [void](Add-Row $lvSummary @('ERROR', [string]$e) 'high' $true) } }
    $inp = $r.input
    [void](Add-Row $lvSummary @('Input file', ("$($inp.name)   ($(Fmt-Size $inp.size))")))
    if ($r.container.kind) {
        $pkg = "$($r.container.kind)"
        if ($r.container.encryption) { $pkg += ", encryption: $($r.container.encryption)" }
        if ($r.container.password_status) { $pkg += ", password: $($r.container.password_status)" }
        if ($null -ne $r.container.messages) { $pkg += ", messages: $($r.container.messages)" }
        [void](Add-Row $lvSummary @('Package', $pkg))
    }
    $mi = 0
    foreach ($m in @($r.messages)) {
        if (-not $m) { continue }
        $mi++
        $h = $m.headers
        [void](Add-Row $lvSummary @("--- Email $mi", '') $null $true)
        [void](Add-Row $lvSummary @('From', [string]$h.From))
        if ($h.'Reply-To') { [void](Add-Row $lvSummary @('Reply-To', [string]$h.'Reply-To')) }
        [void](Add-Row $lvSummary @('To', [string]$h.To))
        [void](Add-Row $lvSummary @('Subject', [string]$h.Subject))
        [void](Add-Row $lvSummary @('Date', [string]$h.Date))
        $au = $m.auth
        if ($au) {
            $authTxt = "SPF $($au.spf)   DKIM $($au.dkim)   DMARC $($au.dmarc)   compauth $($au.compauth)"
            $authSev = if ($au.dmarc -eq 'fail') { 'high' } elseif ($au.spf -in 'fail', 'softfail' -or $au.compauth -eq 'fail') { 'medium' } else { $null }
            [void](Add-Row $lvSummary @('Authentication', $authTxt) $authSev)
        }
        if ($m.alignment) {
            $alTxt = "SPF aligned: $(if ($m.alignment.spf_aligned) { 'yes' } else { 'no' })   DKIM aligned: $(if ($m.alignment.dkim_aligned) { 'yes' } else { 'no' })"
            [void](Add-Row $lvSummary @('DMARC alignment', $alTxt) $(if (-not $m.alignment.aligned) { 'medium' }))
        }
        if ($m.compauth_meaning) { [void](Add-Row $lvSummary @('compauth reason', ("$($m.auth_full.reason): $($m.compauth_meaning)"))) }
        if ($m.sfty) { foreach ($p in $m.sfty.PSObject.Properties) { [void](Add-Row $lvSummary @("Safety tip $($p.Name)", [string]$p.Value) 'low') } }
        if ($m.bulk -and $m.bulk.is_bulk) {
            $bt = "Bulk sender$(if ($m.bulk.esp) { " via $($m.bulk.esp)" })$(if ($m.bulk.bcl) { ", BCL $($m.bulk.bcl) ($($m.bulk.bcl_meaning))" }); meets 2024-25 sender requirements: $(if ($m.bulk.meets_sender_requirements) { 'yes' } else { 'no' })"
            [void](Add-Row $lvSummary @('Bulk mail', $bt))
        }
        if ($m.phones) { [void](Add-Row $lvSummary @('Phone numbers', ((@($m.phones) | Where-Object { $_ }) -join ', ')) 'medium') }
        if ($m.ibans) { [void](Add-Row $lvSummary @('Bank accounts (IBAN)', ((@($m.ibans) | Where-Object { $_ }) -join ', ')) 'medium') }
        if ($m.eop_category) { [void](Add-Row $lvSummary @('Microsoft verdict', ("$($m.eop_category)   (SFV $($m.eop.SFV), SCL $($m.eop.SCL)$(if ($m.bcl) { ", BCL $($m.bcl)" }))")) $(if ($m.eop_category -match 'Malware|phish|impersonation|Spoof') { 'high' } else { $null })) }
        if ($m.origin_ip) { [void](Add-Row $lvSummary @('Origin IP', ("$($m.origin_ip)$(if ($m.eop.CTRY) { "   country: $($m.eop.CTRY)" })"))) }
        if ($m.password_hint_count -gt 0) { [void](Add-Row $lvSummary @('Password hints in message body', [string]$m.password_hint_count) 'medium') }
        $atts = @($m.children | Where-Object { $_ })
        [void](Add-Row $lvSummary @('Attachments', ("$($atts.Count)")))
        foreach ($att in $atts) {
            $w = Get-WorstSeverity ([string]$att.where) $true
            $chain = Get-NodeText $att
            $inner = @($att.children | Where-Object { $_ -and $_.kind -ne 'dir' })
            if ($inner.Count) { $chain += "   $($Sym.ARROW) contains: " + (($inner | Select-Object -First 6 | ForEach-Object { [string]$_.name }) -join ', ') + $(if ($inner.Count -gt 6) { ', ...' }) }
            [void](Add-Row $lvSummary @(("   " + $(if ($w) { $Sev[$w].Label } else { 'attachment' })), $chain) $w)
        }
    }
    if ($r.other) { [void](Add-Row $lvSummary @('Archive contents', ((@($r.other.children) | Where-Object { $_ } | ForEach-Object { [string]$_.name }) -join ', '))) }
    [void](Add-Row $lvSummary @('Input SHA256', [string]$inp.hashes.sha256))
    $lvSummary.EndUpdate()

    # ---- findings
    $lvFindings.BeginUpdate(); $lvFindings.Items.Clear()
    $fs = @($r.findings | Where-Object { $_ })
    foreach ($f in $fs) { $it = Add-Row $lvFindings @($Sev[$f.severity].Label, [string]$f.title, [string]$f.where, [string]$f.detail, [string]$f.attack) $f.severity; $it.Tag = $f; $it.ToolTipText = [string]$f.where }
    if (-not $fs.Count) { [void](Add-Row $lvFindings @('', 'No findings. This is not a safe verdict.', '', '')) }
    $lvFindings.EndUpdate()
    Fit-Columns $lvFindings @(80, 220, 300, 300, 80) @(110, 480, 760, 640, 110)
    Show-FindingDetail
    $tFindings.Text = "Findings ($($fs.Count))"

    # ---- attachment tree
    $tree.BeginUpdate(); $tree.Nodes.Clear()
    foreach ($m in @($r.messages)) { if ($m) { $tn = Add-TreeNode $tree.Nodes $m; $tn.ExpandAll() } }
    if ($r.other) { $tn = Add-TreeNode $tree.Nodes $r.other; $tn.ExpandAll() }
    $tree.EndUpdate()
    if ($tree.Nodes.Count) { $tree.SelectedNode = $tree.Nodes[0] }
    $attCount = 0; foreach ($m in @($r.messages)) { if ($m) { $attCount += [int]$m.attachment_count } }
    $tAttach.Text = "Attachments ($attCount)"

    # ---- links
    $lvLinks.BeginUpdate(); $lvLinks.Items.Clear()
    $us = @($r.urls | Where-Object { $_ })
    foreach ($u in $us) { $it = Add-Row $lvLinks @($Sev[$u.severity].Label, [string]$u.defanged, ((@($u.flags) | Where-Object { $_ }) -join '; '), ((@($u.sources) | Where-Object { $_ }) -join '; ')) $(if ($u.severity -ne 'info') { $u.severity }); $it.ToolTipText = [string]$u.defanged }
    $lvLinks.EndUpdate()
    Fit-Columns $lvLinks @(70, 300, 260, 200) @(100, 760, 560, 420)
    $tLinks.Text = "Links ($($us.Count))"

    # ---- headers
    $lvHeaders.BeginUpdate(); $lvHeaders.Items.Clear()
    $mi = 0
    foreach ($m in @($r.messages)) {
        if (-not $m) { continue }
        $mi++
        [void](Add-Row $lvHeaders @("--- Email $mi", [string]$m.where) $null $true)
        if ($m.auth) { foreach ($p in $m.auth.PSObject.Properties) { [void](Add-Row $lvHeaders @("auth: $($p.Name)", [string]$p.Value) $(if ($p.Value -in 'fail', 'softfail') { 'medium' })) } }
        if ($m.eop) { foreach ($p in $m.eop.PSObject.Properties) { [void](Add-Row $lvHeaders @("EOP: $($p.Name)", [string]$p.Value)) } }
        if ($m.eop_sfv) { [void](Add-Row $lvHeaders @('EOP: SFV meaning', [string]$m.eop_sfv)) }
        foreach ($p in $m.headers.PSObject.Properties) { [void](Add-Row $lvHeaders @($p.Name, [string]$p.Value)) }
        $hop = 0
        foreach ($rcv in @($m.received)) { if ($rcv) { $hop++; [void](Add-Row $lvHeaders @("Received hop $hop", ("from $($rcv.from)  by $($rcv.by)  [$($rcv.ip)]"))) } }
    }
    $lvHeaders.EndUpdate()

    # ---- body + raw
    $bodies = @()
    $mi = 0
    foreach ($m in @($r.messages)) { if ($m) { $mi++; $bodies += "===== Email $mi ====="; $bodies += ([string]$m.body_preview -replace "`r?`n", "`r`n"); $bodies += '' } }
    $bodyText.Text = ($bodies -join "`r`n")
    if (Test-Path -LiteralPath $script:LastText) { $rawText.Text = ((Get-Content -LiteralPath $script:LastText -Raw -Encoding UTF8) -replace "`r?`n", "`r`n") }
    $bSave.Enabled = $true
    $tabs.SelectedTab = $tDecision
    Fit-TabPadding
    Set-ResultsMode 'Result'
    Update-ReviewStepper
}

# ================================================================= analysis run (asynchronous)
# Continue (step 2) needs a password in the box and no analysis running.
function Update-ContinueState { $bContinue.Enabled = (-not $script:IsBusy) -and ($pwdBox.Text.Length -gt 0) }
function Set-Busy([bool]$busy) {
    $script:IsBusy = $busy
    Update-ContinueState
    $bAnalyze.Enabled = -not $busy; $bBrowse.Enabled = -not $busy; $bRefresh.Enabled = -not $busy; $fileList.Enabled = -not $busy
    $bClear.Enabled = -not $busy   # a new review would wipe the screen under a running analysis
    $bAnalyze.Text = if ($busy) { 'Analyzing...' } else { 'Analyze' }
    Update-ReviewStepper
}

# Maps the analyzer's progress text to a stage of the tracker. Index -1 means "not a known stage": the Label is then the text itself.
function ConvertTo-AnalysisStage([string]$text) {
    $t = if ($null -eq $text) { '' } else { $text.Trim() }
    $index = -1; $label = if ($t) { $t } else { 'Starting offline analysis...' }
    if ($t -match '^Reading input file') { $index = 0; $label = 'Reading file' }
    elseif ($t -match '^(Parsing message|Opening quarantine package)') { $index = 1; $label = 'Opening package' }
    elseif ($t -match '^(Analysing message|Inspecting archive)') { $index = 2; $label = $t }
    elseif ($t -match '^Building report') { $index = 3; $label = 'Building report' }
    elseif ($t -match '^Done') { $index = 4; $label = 'Done' }
    [pscustomobject]@{ Index = $index; Label = $label }
}

# The four tracker rows: rows below the Index are Done, the row at the Index is Working, the rest are Pending. Index 4 (Done) completes all rows.
$script:StageDefaultNames = @('Reading file', 'Opening package', 'Analysing message', 'Building report')
$script:StageKey = ''
function Set-StageTracker([int]$index, [string]$label = '') {
    $key = "$index|$label"
    if ($key -eq $script:StageKey) { return }
    $script:StageKey = $key
    for ($i = 0; $i -lt $script:StageRows.Count; $i++) {
        $row = $script:StageRows[$i]
        $state = if ($i -lt $index) { 'Done' } elseif ($i -eq $index) { 'Working' } else { 'Pending' }
        Set-QraBadgeState $row.Badge $state
        $row.Label.ForeColor = if ($state -eq 'Pending') { $C.TextMuted } else { $C.Text }
        $row.Label.Text = if ($i -eq 2 -and $index -eq 2 -and $label) { $label -replace '\.+$', '' } else { $script:StageDefaultNames[$i] }
    }
}
function Reset-StageTracker {
    $script:StageKey = ''
    Set-StageTracker -1
    $elapsedLbl.Text = '0 s'
}
function Set-WorkingStageWarning {
    # The row that was still working did not finish (cancelled, timed out or no report).
    foreach ($row in $script:StageRows) {
        if ($row.Badge.GetType().FullName -eq 'QraUi.StepBadge' -and $row.Badge.State -eq 'Working') { Set-QraBadgeState $row.Badge 'Warning' }
    }
}

# ---- results area modes: Empty (prompt), Analysing (large spinner + stage), Result (the tabs)
$script:ResultsMode = 'Empty'
$script:StageUiReady = $false
function Initialize-ResultsStage {
    # Created after scaling, so sizes and fonts here use S() and the real fonts.
    $script:stIcon = New-Object System.Windows.Forms.Label
    $script:stIcon.AutoSize = $false; $script:stIcon.TextAlign = 'MiddleCenter'; $script:stIcon.Font = Get-IconFont 48
    $script:stIcon.ForeColor = $C.TextMuted; $script:stIcon.Text = $QraGlyph.Shield; $script:stIcon.AccessibleName = 'Shield'
    $script:stText = New-Object System.Windows.Forms.Label
    $script:stText.AutoSize = $false; $script:stText.TextAlign = 'MiddleCenter'; $script:stText.Font = New-Font 12
    $script:stText.ForeColor = $C.TextMuted; $script:stText.Text = 'Choose a package and click Analyze.'
    $script:stSpin = New-QraSpinner 56   # the factory takes the unscaled diameter (it scales the stroke itself)
    $script:stSpin.Size = New-Object System.Drawing.Size((S 56), (S 56))   # created after scaling, so the size goes through S()
    if (-not $script:UiNative) { $script:stSpin.Font = New-Font 28 'Bold' }   # the fallback spinner is three dots: make them readable at this size
    $script:stStage = New-Object System.Windows.Forms.Label
    $script:stStage.AutoSize = $false; $script:stStage.TextAlign = 'MiddleCenter'; $script:stStage.Font = New-Font 12 'Bold'
    $script:stStage.ForeColor = $C.Text; $script:stStage.Text = 'Starting offline analysis...'
    $script:stSub = New-Object System.Windows.Forms.Label
    $script:stSub.AutoSize = $false; $script:stSub.TextAlign = 'MiddleCenter'
    $script:stSub.ForeColor = $C.TextMuted; $script:stSub.Text = 'Offline analysis. Nothing is opened, rendered or executed.'
    $resultsStage.Controls.AddRange(@($script:stIcon, $script:stText, $script:stSpin, $script:stStage, $script:stSub))
    $script:StageUiReady = $true
}
function Update-StageLayout {
    if (-not $script:StageUiReady) { return }
    $w = $resultsStage.ClientSize.Width; $h = $resultsStage.ClientSize.Height
    $gap = S 12
    $tw = [Math]::Max((S 100), [Math]::Min((S 620), $w - (S 40)))
    if ($script:ResultsMode -eq 'Analysing') {
        $items = @(@{ C = $script:stSpin; W = $script:stSpin.Width; H = $script:stSpin.Height },
                   @{ C = $script:stStage; W = $tw; H = (Measure-Wrapped $script:stStage.Text $script:stStage.Font $tw) + (S 6) },
                   @{ C = $script:stSub; W = $tw; H = (Measure-Wrapped $script:stSub.Text $script:stSub.Font $tw) + (S 4) })
    } else {
        $items = @(@{ C = $script:stIcon; W = $tw; H = $script:stIcon.Font.Height + (S 8) },
                   @{ C = $script:stText; W = $tw; H = (Measure-Wrapped $script:stText.Text $script:stText.Font $tw) + (S 6) })
    }
    $total = $gap * ($items.Count - 1)
    foreach ($it in $items) { $total += $it.H }
    $y = [Math]::Max((S 16), [int](($h - $total) / 2) - (S 24))
    foreach ($it in $items) {
        $it.C.SetBounds([int](($w - $it.W) / 2), $y, $it.W, $it.H)
        $y += $it.H + $gap
    }
}
# The empty-state prompt follows the selection: with a package chosen the next thing to do is the password.
function Get-EmptyPrompt([bool]$HasSelection) {
    if ($HasSelection) { return 'Enter the download password, then click Continue.' }
    return 'Choose a package and click Analyze.'
}
function Set-ResultsMode([ValidateSet('Empty', 'Analysing', 'Result')][string]$mode) {
    $script:ResultsMode = $mode
    $isResult = ($mode -eq 'Result')
    $tabs.Visible = $isResult
    $resultsStage.Visible = -not $isResult
    $verdictHost.Visible = ($isResult -and [bool]$script:Result)
    if ($script:StageUiReady) {
        $script:stIcon.Visible = ($mode -eq 'Empty'); $script:stText.Visible = ($mode -eq 'Empty')
        if ($mode -eq 'Empty') { $script:stText.Text = Get-EmptyPrompt ([bool]$fileList.SelectedItems.Count) }
        $script:stSpin.Visible = ($mode -eq 'Analysing'); $script:stStage.Visible = ($mode -eq 'Analysing'); $script:stSub.Visible = ($mode -eq 'Analysing')
        Set-QraSpinner $script:stSpin ($mode -eq 'Analysing') $script:stStage.Text
        Update-StageLayout
    }
}
# The big spinner shows the current stage and announces changes to screen readers (no focus change).
function Set-AnalysisStageText([string]$text) {
    if ($script:stStage.Text -eq $text) { return }
    $script:stStage.Text = $text
    Set-QraSpinner $script:stSpin ($script:ResultsMode -eq 'Analysing') $text
    Update-StageLayout
}

# Verdict count pills (High / Medium / Low / Risky links), created after scaling.
$script:VerdictPills = $null
function Initialize-VerdictPills {
    $flow = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.AutoSize = $true; $flow.AutoSizeMode = 'GrowAndShrink'; $flow.WrapContents = $false; $flow.FlowDirection = 'LeftToRight'
    $flow.BackColor = $verdict.BackColor; $flow.Margin = (SPad 0 0 0 0); $flow.Visible = $false
    foreach ($name in @('High', 'Medium', 'Low', 'Risky links')) {
        $pl = New-QraPill 'INFO' $name
        $pl.Font = New-Font 9.5 'Bold'
        $pl.Margin = (SPad 0 0 8 0); $pl.Tag = $name
        if (-not $script:UiNative) { $pl.BackColor = $C.Card; $pl.Padding = (SPad 8 2 8 2) }
        $flow.Controls.Add($pl)
    }
    $verdict.Controls.Add($flow)
    $script:VerdictPills = $flow
}
function Set-VerdictPills($asm) {
    if (-not $script:VerdictPills) { return }
    if (-not $asm) { $script:VerdictPills.Visible = $false; Update-HeaderLayout; return }
    $cnt = $asm.counts
    $vals = @([int]$cnt.high, [int]$cnt.medium, [int]$cnt.low, [int]$asm.suspicious_links)
    $kinds = @('FAIL', 'WARN', 'INFO', 'WARN')
    $i = 0
    foreach ($pl in @($script:VerdictPills.Controls)) {
        Set-QraPill $pl $(if ($vals[$i] -gt 0) { $kinds[$i] } else { 'INFO' }) ("$($pl.Tag) $($vals[$i])")
        Set-Access $pl ("$($pl.Tag): $($vals[$i])")
        $i++
    }
    $script:VerdictPills.Visible = $true
    Update-HeaderLayout
}

# Stops a running analysis (Cancel button, the 10-minute limit, closing the window). Safe to call when nothing is running.
function Stop-Analysis([string]$reason) {
    $run = $script:Run
    if (-not $run) { return }
    $script:Run = $null
    try { if (-not $run.Proc.HasExited) { $run.Proc.Kill() } } catch { $null = $_ } # process may have already exited
    $runTimer.Stop()
    $script:PwdUsed = $false   # the password box was cleared when the run started: the step asks for it again
    Set-Busy $false
    Set-WorkingStageWarning
    $status.Text = $reason; $status.ForeColor = $C.Danger
    Set-ResultsMode 'Empty'
    try { $leftCard.ScrollControlIntoView($status) } catch { $null = $_ } # best-effort scroll
}

function ConvertTo-JsonString([string]$s) {
    if ($null -eq $s) { return '""' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $s.ToCharArray()) {
        $code = [int]$ch
        if ($ch -eq '"') { [void]$sb.Append('\"') }
        elseif ($ch -eq '\') { [void]$sb.Append('\\') }
        elseif ($code -lt 32 -or $code -gt 126) { [void]$sb.Append(('\u{0:x4}' -f $code)) }
        else { [void]$sb.Append($ch) }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Start-Analysis {
    if ($script:Run -or -not $bAnalyze.Enabled) { return }   # Enter in the password box must not bypass a disabled Analyze button
    if (-not (Test-Path -LiteralPath $PythonExe)) {
        [System.Windows.Forms.MessageBox]::Show("The analysis runtime is missing:`r`n$PythonExe`r`n`r`nClose this Sandbox, open Start-Here.cmd on the host and click 'Download' next to 'Analysis runtime'.", 'Setup incomplete', 'OK', 'Warning') | Out-Null
        return
    }
    if (-not $EnvStatus.Sandbox -and -not $AllowHost) {
        [System.Windows.Forms.MessageBox]::Show('For safety, analysis only runs inside Windows Sandbox. Use Start-Here.cmd on the host to launch it.', 'Not in Sandbox', 'OK', 'Warning') | Out-Null
        return
    }
    $path = Get-SelectedFile
    if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        [System.Windows.Forms.MessageBox]::Show('Select a .zip or .eml file first (step 1).', 'Nothing selected', 'OK', 'Information') | Out-Null
        return
    }
    if ([System.IO.Path]::GetExtension($path).ToLowerInvariant() -notin '.zip', '.eml') {
        [System.Windows.Forms.MessageBox]::Show('Only .zip and .eml files are accepted.', 'Unsupported file', 'OK', 'Warning') | Out-Null
        return
    }
    if ($path.ToLowerInvariant().EndsWith('.zip') -and -not $pwdBox.Text) {
        $ans = [System.Windows.Forms.MessageBox]::Show("No download password entered.`r`n`r`nDefender quarantine downloads are always password-protected. Continue without a password? (Only for ZIPs that are not Defender downloads.)", 'Password missing', 'YesNo', 'Question')
        if ($ans -ne 'Yes') { $pwdBox.Focus(); return }
    }
    Clear-Results
    foreach ($f in @($script:LastJson, $script:LastText, $script:ProgressFile)) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }

    $attList = @($attPwd.Lines | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $secret = '{"zip_password":' + (ConvertTo-JsonString $pwdBox.Text) + ',"attachment_passwords":[' + (($attList | ForEach-Object { ConvertTo-JsonString $_ }) -join ',') + ']}'

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $PythonExe
    $q = { param($s) '"' + ($s -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' }
    $psi.Arguments = '-I -B -X utf8 ' + (& $q $Backend) + ' --input ' + (& $q $path) + ' --secrets-stdin --json-out ' + (& $q $script:LastJson) + ' --text-out ' + (& $q $script:LastText) + ' --progress-file ' + (& $q $script:ProgressFile) + $(if (Test-Path -LiteralPath $ConfigFile) { ' --config ' + (& $q $ConfigFile) } else { '' })
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    try {
        if (-not $proc.Start()) { throw 'Python did not start.' }
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($secret + "`n")
        $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $proc.StandardInput.BaseStream.Flush()
        $proc.StandardInput.Close()
    } catch {
        $status.Text = 'Could not start the analysis: ' + $_.Exception.Message
        return
    } finally {
        $secret = $null
    }
    $script:PwdUsed = ($pwdBox.Text.Length -gt 0)
    $pwdBox.Clear()
    $script:Run = @{ Proc = $proc; Out = $outTask; Err = $errTask; Started = Get-Date; Input = $path }
    Set-Busy $true
    $status.Text = 'Starting offline analysis...'; $status.ForeColor = $C.TextMuted
    $script:stStage.Text = ''
    Set-ResultsMode 'Analysing'
    Set-AnalysisStageText 'Starting offline analysis...'
    try { $leftCard.ScrollControlIntoView($status) } catch { $null = $_ }   # keep the stage tracker in view on a short window
    $runTimer.Start()
}

$runTimer = New-Object System.Windows.Forms.Timer
$runTimer.Interval = 300
$runTimer.Add_Tick({
    $run = $script:Run
    if (-not $run) { $runTimer.Stop(); return }
    $elapsed = [int]((Get-Date) - $run.Started).TotalSeconds
    $elapsedLbl.Text = "$elapsed s"
    if (-not $run.Proc.HasExited) {
        $msg = ''
        try { $msg = [System.IO.File]::ReadAllText($script:ProgressFile) } catch { $null = $_ } # progress file may be locked mid-write; retried next tick
        $stage = ConvertTo-AnalysisStage $msg
        Set-StageTracker $stage.Index $stage.Label
        Set-AnalysisStageText $stage.Label
        $status.Text = $stage.Label
        if ($elapsed -gt 600) { Stop-Analysis 'Stopped after 10 minutes. The file is unusually large or complex - keep it quarantined and escalate.' }
        return
    }
    $runTimer.Stop()
    $script:Run = $null
    Set-Busy $false
    $code = $run.Proc.ExitCode
    $stderr = ''
    try { $stderr = $run.Err.Result } catch { $null = $_ } # stderr task may be faulted/cancelled on abort
    $r = $null
    if (Test-Path -LiteralPath $script:LastJson) {
        try { $r = Get-Content -LiteralPath $script:LastJson -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $stderr += "`r`nCould not read JSON: " + $_.Exception.Message }
    }
    if ($r) {
        Set-StageTracker 4
        $script:LastElapsed = $elapsed
        Show-Result $r
        if ($script:Result) {
            $status.Text = if ($code -eq 0) { "Finished in $elapsed s. Read the Summary and Findings tabs." } else { 'Finished with errors - see the red rows in Summary.' }
            $status.ForeColor = if ($code -eq 0) { $C.Success } else { $C.Danger }
        }
        if ($r.container.password_status -in 'wrong', 'missing') { $pwdBox.Focus() }
    } else {
        $script:PwdUsed = $false
        Set-WorkingStageWarning
        $status.Text = 'The analysis failed to produce a report. Keep the message quarantined.'
        $status.ForeColor = $C.Danger
        $rawText.Text = "Backend exit code $code`r`n`r`n" + ($stderr -replace "`r?`n", "`r`n")
        Set-ResultsMode 'Result'
        $tabs.SelectedTab = $tRaw
        Update-ReviewStepper
    }
})

# ================================================================= events
$showPwd.Add_CheckedChanged({ $pwdBox.UseSystemPasswordChar = -not $showPwd.Checked })
$pwdBox.Add_KeyUp({ $script:CapsOn = [System.Windows.Forms.Control]::IsKeyLocked('CapsLock'); Update-LeftLayout })
$pwdBox.Add_Enter({ $script:CapsOn = [System.Windows.Forms.Control]::IsKeyLocked('CapsLock'); Update-LeftLayout })
$pwdBox.Add_TextChanged({ Update-ContinueState; Update-ReviewStepper -Keep })
# A click on a package moves on to the password; arrow keys inside the list do not (they would fold the list away under the user).
$fileList.Add_SelectedIndexChanged({
    if ($script:ResultsMode -eq 'Empty' -and $script:StageUiReady) { $script:stText.Text = Get-EmptyPrompt ([bool]$fileList.SelectedItems.Count); Update-StageLayout }
    Update-ReviewStepper -Keep:$fileList.Focused
})
$fileList.Add_MouseUp({ Update-ReviewStepper })
# When the keyboard focus leaves a card for something other than a card link (or the user clicks elsewhere), the stepper moves on.
$script:AdvanceTimer = New-Object System.Windows.Forms.Timer
$script:AdvanceTimer.Interval = 120
$script:AdvanceTimer.Add_Tick({
    $script:AdvanceTimer.Stop()
    foreach ($entry in $script:StepUi) { if ($entry.Link.Focused) { return } }
    if ($script:StepUi[$script:Expanded - 1].Card.ContainsFocus) { return }
    Update-ReviewStepper
})
foreach ($entry in $script:StepUi) { $entry.Card.Add_Leave({ $script:AdvanceTimer.Stop(); $script:AdvanceTimer.Start() }) }
# Step 2 -> step 3: the password is entered, so the stepper moves on and the Analyze button gets the focus. Nothing is analyzed yet:
# Enter in the box (or Continue) = go to Analyze, Enter on the Analyze button = analyze.
function Complete-PasswordStep {
    if (-not $bContinue.Enabled) { return }
    Update-ReviewStepper
    Set-ReviewStepFocus $script:Expanded
    if ($script:Expanded -eq 3 -and $bAnalyze.Enabled) { [void]$bAnalyze.Select() }   # also makes it the active control when the window is not foreground yet
}
$pwdBox.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Enter') { $e.SuppressKeyPress = $true; Complete-PasswordStep } })
$bContinue.Add_Click({ Complete-PasswordStep })
$bAnalyze.Add_Click({ Start-Analysis })
$bCancel.Add_Click({ Stop-Analysis 'Analysis cancelled - keep the message quarantined.' })
$bRecord.Add_Click({ Save-DecisionRecord })
$bRefresh.Add_Click({ Refresh-Files $null })
$fileList.Add_DoubleClick({ Open-ReviewStep 2 })
$bBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = 'Choose the Defender quarantine download (.zip) or a saved .eml'
    $dlg.Filter = 'Quarantine package or email (*.zip;*.eml)|*.zip;*.eml'
    $dlg.InitialDirectory = if (Test-Path -LiteralPath $Incoming) { $Incoming } else { $ReviewRoot }
    if ($dlg.ShowDialog() -eq 'OK') { Refresh-Files $dlg.FileName }
})
$tree.Add_AfterSelect({ param($s, $e) Show-NodeDetails $e.Node.Tag })
$lvFindings.Add_SelectedIndexChanged({ Show-FindingDetail })
Enable-RowTips $lvFindings
Enable-RowTips $lvLinks
$bClear.Add_Click({ Clear-Results; $attPwd.Clear(); $pwdBox.Clear(); $status.Text = ''; Refresh-Files $null })
$bSave.Add_Click({
    if (-not (Test-Path -LiteralPath $script:LastText)) { return }
    $stem = 'QuarantineReview-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    if ($script:Result -and $script:Result.input.name) { $stem += '-' + (([string]$script:Result.input.name) -replace '[^\w.-]', '_' -replace '\.(zip|eml)$', '') }
    $res = Invoke-SaveTargets {
        param($t)
        Copy-Item -LiteralPath $script:LastText -Destination (Join-Path $t ($stem + '.txt')) -Force -ErrorAction Stop
        Copy-Item -LiteralPath $script:LastJson -Destination (Join-Path $t ($stem + '.json')) -Force -ErrorAction Stop
    }
    [void](Show-SaveOutcome $res 'Report saved' "Saved $stem (.txt and .json)" 'The report contains email metadata and hashes. Treat it as confidential.')
})
$form.Add_KeyDown({ param($s, $e)
    if ($e.KeyCode -eq 'F5') { Refresh-Files $null; return }
    if (-not $e.Control -or $e.Alt) { return }
    $k = [int]$e.KeyCode
    $idx = -1
    if ($k -ge 49 -and $k -le 56) { $idx = $k - 49 } elseif ($k -ge 97 -and $k -le 104) { $idx = $k - 97 }   # Ctrl+1..8 (top row or keypad)
    if ($idx -ge 0 -and $idx -lt $tabs.TabCount) { $tabs.SelectedIndex = $idx; $e.Handled = $true; $e.SuppressKeyPress = $true; return }
    if ($e.KeyCode -eq 'S' -and -not $e.Shift) { if ($bSave.Enabled) { $bSave.PerformClick() }; $e.Handled = $true; $e.SuppressKeyPress = $true }
})
if (-not $Screenshot) { $form.Add_Shown({
    try { $split.SplitterDistance = (S 420) } catch { $null = $_ } # ignore if window is too narrow for the requested splitter distance
    Update-LeftLayout; Update-HeaderLayout
    Set-AttachmentSplit   # a no-op while the Attachments tab is hidden: the tab's own events apply it when it appears
    Refresh-Files $null
    if ($envProblems.Count -and -not $AllowHost) { $bAnalyze.Enabled = $false; $status.Text = 'Analysis disabled: see the red warning at the top.'; $status.ForeColor = $C.Danger }
    elseif ($fileList.Items.Count) { $pwdBox.Focus(); $status.Text = 'Enter the download password, then click Continue.' }
    if (-not (Test-Path -LiteralPath $PythonExe)) { $status.Text = 'Analysis runtime missing - run Start-Here.cmd on the host and click Download.'; $status.ForeColor = $C.Danger }
}) }
$form.Add_FormClosing({ Stop-Analysis 'Analysis cancelled - keep the message quarantined.' })

# ================================================================= accessibility, tab order, shortcuts
Set-Access $fileList 'Downloaded packages' 'Files in the Incoming folder. Select the package to analyze.'
Set-Access $bBrowse 'Browse for a package'
Set-Access $bRefresh 'Refresh the file list' 'Shortcut F5'
Set-Access $pwdBox 'Download password' 'The password typed in the Defender Download message dialog. Press Enter or Continue to go to the Analyze step.'
Set-Access $bContinue 'Continue' 'Moves to the Analyze step. Nothing is analyzed until you click Analyze.'
Set-Access $showPwd 'Show password'
Set-Access $attPwd 'Attachment passwords' 'Optional. One password per line.'
Set-Access $bAnalyze 'Analyze' 'Starts the offline analysis.'
Set-Access $bCancel 'Cancel the analysis' 'Stops the analysis and keeps the message quarantined.'
Set-Access $elapsedLbl 'Elapsed seconds'
Set-Access $tabs 'Result tabs' 'Ctrl+1 to Ctrl+8 switch tabs'
Set-Access $lvSummary 'Summary table'; Set-Access $lvFindings 'Findings table' 'One row per finding, with the severity word in the first column'
Set-Access $findDetail 'Selected finding: full details'; Set-Access $tree 'Attachment tree'; Set-Access $nodeDetails 'Selected attachment details'
Set-Access $lvLinks 'Links table'; Set-Access $lvHeaders 'Headers table'; Set-Access $bodyText 'Message text, plain-text extract'; Set-Access $rawText 'Full text report'
Set-Access $decSteps 'What to do in Defender'
Set-Access $decChoice 'Final decision'; Set-Access $decReviewer 'Reviewer name'; Set-Access $decNote 'Decision note'; Set-Access $bRecord 'Record decision'
Set-Access $bSave 'Save report' 'Shortcut Ctrl+S'; Set-Access $bClear 'New review'
$ti = 0; foreach ($tabCtl in @($fileList, $bBrowse, $bRefresh, $pwdBox, $showPwd, $bContinue, $attPwd, $bAnalyze, $bCancel)) { $tabCtl.TabIndex = $ti++ }
$split.Panel1.TabIndex = 0; $split.Panel2.TabIndex = 1
for ($i = 0; $i -lt 4; $i++) { $script:StepUi[$i].Card.TabIndex = $i; $script:StepUi[$i].Link.TabIndex = 0 }
$status.TabIndex = 4
$tabs.TabIndex = 0; $actions.TabIndex = 1; $bSave.TabIndex = 0; $bClear.TabIndex = 1
$ti = 0; foreach ($tabCtl in @($decChoice, $decReviewer, $decNote, $bRecord)) { $tabCtl.TabIndex = $ti++ }
$ttKeys = New-Object System.Windows.Forms.ToolTip
$ttKeys.SetToolTip($tabs, 'Ctrl+1 ... Ctrl+8 switch tabs')
$ttKeys.SetToolTip($bSave, 'Save report (Ctrl+S)')
$ttKeys.SetToolTip($bRefresh, 'Refresh (F5)')

$form.ResumeLayout($false)
# The form font is applied AFTER ResumeLayout: setting it earlier makes every control without its own Font scale twice
# (an ambient-font change during AutoScale), e.g. labels would be 2.25x too big at 150 %.
$form.Font = New-Font 9.5
Limit-FormToScreen $form
# Created after scaling (they size themselves from their font): environment pills, results stage content, verdict count pills.
Add-Chip $(if ($EnvStatus.Export) { 'Report export on' } else { 'No host export' }) $true $(if ($EnvStatus.Export) { 'Reports can be saved to the host Reports folder (C:\Reports).' } else { 'Reports stay inside this Sandbox (C:\Work) and are deleted when it closes.' })
Add-Chip $(if ($EnvStatus.ReadOnly) { 'Host files read-only' } else { 'Host files WRITABLE' }) $EnvStatus.ReadOnly 'C:\Review (your tool folder) must be mapped read-only.'
Add-Chip $(if ($EnvStatus.Offline) { 'Offline' } else { 'NETWORK ON' }) $EnvStatus.Offline 'The Sandbox profile disables networking.'
Add-Chip $(if ($EnvStatus.Sandbox) { 'Windows Sandbox' } else { 'NOT IN SANDBOX' }) $EnvStatus.Sandbox 'Must run inside Windows Sandbox.'
Initialize-ResultsStage
Initialize-VerdictPills
Reset-StageTracker
Set-ResultsMode 'Empty'
$script:StepUiReady = $true
$script:LayoutReady = $true   # resize handlers do nothing while the form is still being built and scaled
Fit-Chips
Update-HeaderLayout
Update-ReviewStepper
Update-StageLayout

# ================================================================= -Screenshot <folder>
# Headless: applies each state from built-in fake data and renders the window to <folder>\review-<state>.png.
# Never reads Incoming, never starts Python or the Sandbox and never shows the window. States: empty, analysing and, when
# -ScreenshotResult <report.json> is given, result, decision-recorded and result-findings.
if ($Screenshot) {
    New-Item -ItemType Directory -Force -Path $Screenshot | Out-Null
    $shotTime = [datetime]'2026-11-25 10:42'
    $shotData = $null
    if ($ScreenshotResult) { $shotData = Get-Content -LiteralPath $ScreenshotResult -Raw -Encoding UTF8 | ConvertFrom-Json }
    $script:LastText = Join-Path $Screenshot 'no-report.txt'   # never exists: the Full report tab stays empty
    if ($ScreenshotMinSize) { $form.Size = $form.MinimumSize } elseif ($ScreenshotSize) { $form.Size = [System.Drawing.Size]$ScreenshotSize }
    # DrawToBitmap needs a created, shown form (WM_PRINT only reaches existing child windows), so it is shown off screen at Opacity 0 for the render only
    $form.ShowInTaskbar = $false; $form.Opacity = 0; $form.StartPosition = 'Manual'; $form.Location = New-Object System.Drawing.Point(-32000, -32000)
    $form.Show()
    try { $split.SplitterDistance = (S 420) } catch { $null = $_ } # ignore if window is too narrow for the requested splitter distance
    $shotItem = New-Object System.Windows.Forms.ListViewItem('Quarantined Messages.zip')
    [void]$shotItem.SubItems.Add((Fmt-Size 49152)); [void]$shotItem.SubItems.Add($shotTime.ToString('HH:mm dd/MM'))
    $shotItem.Tag = 'C:\Review\Incoming\Quarantined Messages.zip'
    [void]$fileList.Items.Add($shotItem); $shotItem.Selected = $true
    [System.Windows.Forms.Application]::DoEvents()
    function Save-ShotImage([string]$state) {
        Update-HeaderLayout; Update-LeftLayout; Update-StageLayout; Fit-TabPadding
        [System.Windows.Forms.Application]::DoEvents()
        $bmp = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
        $form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
        $bmp.Save((Join-Path $Screenshot "review-$state.png"), [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
    }
    # empty: a package is selected, nothing typed yet
    Clear-Results
    $status.Text = 'Enter the download password, then click Continue.'; $status.ForeColor = $C.TextMuted
    Update-ReviewStepper
    Save-ShotImage 'empty'
    # password: a (fake) password is in the box, so Continue is enabled and step 2 stays open
    $pwdBox.Text = 'sample-pass'
    Update-ReviewStepper -Keep
    Save-ShotImage 'password'
    $pwdBox.Clear()
    Update-ReviewStepper
    # analysing: a fake run at the "Analysing message" stage (no process); the large spinner is forced visible
    Clear-Results
    $script:PwdUsed = $true
    $script:Run = @{ Started = (Get-Date); Input = 'fake' }
    Set-Busy $true
    $shotStage = ConvertTo-AnalysisStage 'Analysing message 1 of 1...'
    Set-StageTracker $shotStage.Index $shotStage.Label
    Set-ResultsMode 'Analysing'
    Set-AnalysisStageText $shotStage.Label
    $elapsedLbl.Text = '7 s'
    $status.Text = $shotStage.Label; $status.ForeColor = $C.TextMuted
    if ($script:UiNative) { $script:stSpin.ShowNow() } else { $script:stSpin.Text = ([string][char]0x00B7) * 3 }
    Update-ReviewStepper
    Save-ShotImage 'analysing'
    $script:Run = $null
    Set-Busy $false
    if ($shotData) {
        Clear-Results
        $script:PwdUsed = $true; $script:LastElapsed = 12
        Set-StageTracker 4
        Show-Result $shotData
        if (-not $script:Result) { Save-ShotImage 'result'; $form.Dispose(); exit 0 }
        $status.Text = 'Finished in 12 s. Read the Summary and Findings tabs.'; $status.ForeColor = $C.Success
        Update-ReviewStepper
        Save-ShotImage 'result'
        if (Test-IncompleteReview $shotData) {
            $decChoice.SelectedIndex = 4
            $decNote.Text = 'Kept quarantined pending a fresh analysis.'
        } else {
            $decChoice.SelectedIndex = 0
            $decNote.Text = 'Blocked sender and SHA256; no other copies found.'
        }
        $script:RecordedDecision = [string]$decChoice.SelectedItem
        $decReviewer.Text = 'J. Analyst'
        Update-ReviewStepper
        [System.Windows.Forms.Application]::DoEvents()
        $decPanel.ScrollControlIntoView($decRecordPanel)   # show the 'Record your decision' section
        Save-ShotImage 'decision-recorded'
        $tabs.SelectedTab = $tFindings
        Save-ShotImage 'result-findings'
        $tabs.SelectedTab = $tAttach
        [System.Windows.Forms.Application]::DoEvents()
        Save-ShotImage 'result-attachments'
    }
    $form.Dispose()
    exit 0
}

[void]$form.ShowDialog()
