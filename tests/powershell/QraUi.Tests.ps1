#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Pester 5. Shared UI kit (src/SecurityReview/app/QraUi.ps1). Run from the repo root:  Invoke-Pester tests/powershell

BeforeAll {
    $script:Repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:KitPath = Join-Path $script:Repo 'src\SecurityReview\app\QraUi.ps1'
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    . $script:KitPath

    # Runs a snippet in a fresh Windows PowerShell child process and returns its output lines.
    function Invoke-ChildPs([string]$Body) {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ('qra-ui-test-' + [guid]::NewGuid().ToString('N') + '.ps1')
        try {
            [IO.File]::WriteAllText($tmp, $Body, (New-Object Text.UTF8Encoding($true)))
            $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tmp 2>&1
            @($out | ForEach-Object { "$_" })
        } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
    function Get-ChildJson($lines) {
        $json = @($lines | Where-Object { $_ -like '{*' }) | Select-Object -Last 1
        if (-not $json) { throw ('child printed no JSON: ' + ($lines -join ' | ')) }
        $json | ConvertFrom-Json
    }
}

Describe 'QraUi kit: compile and tokens' {
    It 'exposes the language mode' {
        $script:QraLanguageMode | Should -Be 'FullLanguage'
    }
    It 'defines every colour token with the agreed key set' {
        $keys = 'Surface', 'Card', 'Border', 'ControlBorder', 'Text', 'TextMuted', 'Primary', 'OnPrimary', 'Success', 'Warning',
        'Danger', 'DangerSoft', 'Info', 'Focus', 'Header', 'HeaderEnd', 'HeaderText', 'HeaderSub', 'Disabled'
        foreach ($k in $keys) { $C.ContainsKey($k) | Should -BeTrue -Because $k }
        $C.Keys.Count | Should -Be $keys.Count
    }
    It 'every text token pair meets 4.5:1' {
        $pairs = @(
            @('Text', 'Surface'), @('TextMuted', 'Surface'), @('TextMuted', 'Card'),
            @('OnPrimary', 'Primary'),
            @('Success', 'Card'), @('Warning', 'Card'), @('Warning', 'Surface'), @('Danger', 'Card'), @('Danger', 'DangerSoft'), @('Info', 'Card'),
            @('HeaderText', 'Header'), @('HeaderSub', 'Header'), @('HeaderSub', 'HeaderEnd'))
        foreach ($p in $pairs) {
            (Get-QraContrast $C[$p[0]] $C[$p[1]]) | Should -BeGreaterOrEqual 4.5 -Because ($p -join '/')
        }
    }
    It 'control boundaries meet 3:1' {
        (Get-QraContrast $C.ControlBorder $C.Card) | Should -BeGreaterOrEqual 3
        (Get-QraContrast $C.Focus $C.Card) | Should -BeGreaterOrEqual 3
    }
    It 'Get-QraContrast returns 21 for black on white' {
        [Math]::Round((Get-QraContrast ([System.Drawing.Color]::Black) ([System.Drawing.Color]::White)), 2) | Should -Be 21
    }
    It 'maps statuses to colours' {
        (Get-QraStatusColor 'OK') | Should -Be $C.Success
        (Get-QraStatusColor 'WARN') | Should -Be $C.Warning
        (Get-QraStatusColor 'FAIL') | Should -Be $C.Danger
        (Get-QraStatusColor 'INFO') | Should -Be $C.Info
    }
    It 'defines the icon glyph table' {
        $QraGlyph.Check | Should -Be ([string][char]0xE73E)
        $QraGlyph.Play | Should -Be ([string][char]0xE768)
        $QraGlyph.Refresh | Should -Be ([string][char]0xE72C)
        $QraGlyph.Keys.Count | Should -Be 14
    }
}

Describe 'QraUi kit: DPI and fonts' {
    BeforeEach {
        $script:SaveDpi = @($script:DpiScale, $script:FontScale, $script:DesignDpi, $script:DeviceDpi)
    }
    AfterEach {
        $script:DpiScale, $script:FontScale, $script:DesignDpi, $script:DeviceDpi = $script:SaveDpi
    }
    It 'S scales by DpiScale' {
        $script:DpiScale = 1.5
        (S 10) | Should -Be 15
    }
    It 'Set-QraEmulatedDpi derives the three scale values' {
        $script:DeviceDpi = 144
        Set-QraEmulatedDpi 96
        $script:DpiScale | Should -Be 1.0
        $script:FontScale | Should -Be (96 / 144)
        $script:DesignDpi | Should -Be (96 * 144 / 96)
        Set-QraEmulatedDpi 192
        $script:DpiScale | Should -Be 2.0
        $script:FontScale | Should -Be (192 / 144)
        $script:DesignDpi | Should -Be (96 * 144 / 192)
    }
    It 'Initialize-QraForm scales children by hostDpi / DesignDpi' {
        # The AutoScaleDimensions getter reports the host DPI in Dpi mode, so assert on the effect: the scaled child size.
        $script:DesignDpi = 120
        $f = New-Object System.Windows.Forms.Form
        try {
            $f.SuspendLayout()
            Initialize-QraForm $f
            $f.AutoScaleMode | Should -Be ([System.Windows.Forms.AutoScaleMode]::Dpi)
            $p = New-Object System.Windows.Forms.Panel
            $p.Size = New-Object System.Drawing.Size(100, 100)
            $f.Controls.Add($p)
            $f.ResumeLayout($false)
            $null = $f.Handle
            $p.Width | Should -Be ([int][Math]::Round(100 * $script:DeviceDpi / 120))
        } finally { $f.Dispose() }
    }
    It 'New-Font multiplies the size by FontScale (system mode: point fonts)' {
        $script:FontScale = 2.0
        $savedPerMonitor = $script:QraPerMonitor
        $script:QraPerMonitor = $false
        try { (New-Font 10).SizeInPoints | Should -Be 20 } finally { $script:QraPerMonitor = $savedPerMonitor }
    }
    It 'New-Font builds pixel fonts of points x 96/72 x DpiScale in per-monitor mode' {
        $script:DpiScale = 1.25
        $savedPerMonitor = $script:QraPerMonitor
        $script:QraPerMonitor = $true
        try {
            $f = New-Font 10
            $f.Unit | Should -Be ([System.Drawing.GraphicsUnit]::Pixel)
            [Math]::Round($f.Size, 3) | Should -Be 16.667
        } finally { $script:QraPerMonitor = $savedPerMonitor }
    }
    It 'New-Font Mono uses Consolas' {
        (New-Font 10 'Regular' 'Mono').Name | Should -Be 'Consolas'
    }
    It 'QRA_UI_WIN10FONTS forces the Windows 10 families' {
        $old = $env:QRA_UI_WIN10FONTS
        try {
            $env:QRA_UI_WIN10FONTS = '1'
            (New-Font 10 'Regular' 'Display').Name | Should -Be 'Segoe UI'
            (New-Font 10 'Regular' 'Text').Name | Should -Be 'Segoe UI'
            (Get-IconFont).Name | Should -Be 'Segoe MDL2 Assets'
        } finally { $env:QRA_UI_WIN10FONTS = $old }
    }
    It 'Get-IconFont returns an icon family' {
        (Get-IconFont 10).Name | Should -BeIn @('Segoe Fluent Icons', 'Segoe MDL2 Assets')
    }
    It 'Measure-Wrapped grows with narrower widths' {
        $f = New-Font 9.5
        $text = 'one two three four five six seven eight nine ten eleven twelve'
        (Measure-Wrapped $text $f 80) | Should -BeGreaterThan (Measure-Wrapped $text $f 600)
    }
}

Describe 'QraUi kit: native controls (run in Windows PowerShell 5.1, the real runtime)' {
    BeforeAll {
        $script:Native = (Invoke-ChildPs @"
`$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. '$($script:KitPath)'
`$r = [ordered]@{}
function Try-Step([string]`$name, [scriptblock]`$body) { try { `$r[`$name] = & `$body } catch { `$r[`$name] = 'ERR ' + `$_.Exception.Message } }
`$r.native = [bool]`$script:UiNative
`$r.spinnerType = [bool]('QraUi.Spinner' -as [type])
`$made = New-Object System.Collections.ArrayList
Try-Step 'button' { `$b = New-QraButton 'x' 'Primary' `$QraGlyph.Play; [void]`$made.Add(`$b); `$b.GetType().FullName + '|' + (`$b -is [System.Windows.Forms.Button]) }
Try-Step 'card' { `$b = New-QraCard; [void]`$made.Add(`$b); `$b.GetType().FullName + '|' + (`$b -is [System.Windows.Forms.Panel]) }
Try-Step 'spinner' { `$b = New-QraSpinner 24; [void]`$made.Add(`$b); `$b.GetType().FullName }
Try-Step 'badge' { `$b = New-QraStepBadge 3; [void]`$made.Add(`$b); `$b.GetType().FullName }
Try-Step 'pill' { `$b = New-QraPill 'OK' 'Ready'; [void]`$made.Add(`$b); `$b.GetType().FullName }
Try-Step 'variants' { ('Primary','Secondary','Link','Danger' | ForEach-Object { `$b = New-QraButton 'Go' `$_; [void]`$made.Add(`$b); `$b.Text + ':' + [string]`$b.Variant }) -join ',' }
Try-Step 'pillSet' { `$p = New-QraPill 'OK' 'Ready'; Set-QraPill `$p 'FAIL' 'Broken'; `$p.Text + '|' + [string]`$p.Status }
Try-Step 'badgeSet' { `$b = New-QraStepBadge 2; Set-QraBadgeState `$b 'Blocked'; [string]`$b.State + '|' + `$b.Number }
Try-Step 'spinnerShowNow' {
    `$s = New-QraSpinner 24
    `$before = `$s.Active; `$s.ShowNow(); `$during = `$s.Active
    Set-QraPill (New-QraPill 'OK' 'x') 'WARN' 'y'
    Set-QraSpinner `$s `$true 'Working'; `$name = `$s.AccessibleName
    Set-QraSpinner `$s `$false ''
    "`$before|`$during|`$(`$s.Active)|`$(`$s.AccessibleRole)|`$name"
}
Try-Step 'spinnerActivity' {
    `$s = New-QraSpinner 24
    `$s.Activity = 'Working'; `$s.Activity = 'Working'
    `$s.Activity + '|' + `$s.AccessibleName
}
Try-Step 'glyphHint' {
    `$bmp = New-Object System.Drawing.Bitmap 40, 40
    `$g = [System.Drawing.Graphics]::FromImage(`$bmp)
    `$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    `$f = New-Object System.Drawing.Font('Segoe UI', 9)
    [QraUi.Theme]::DrawGlyph(`$g, [string][char]0xE73E, `$f, 16, [System.Drawing.Color]::Black, (New-Object System.Drawing.RectangleF(0, 0, 40, 40)))
    `$hint = [string]`$g.TextRenderingHint
    `$g.Dispose(); `$bmp.Dispose()
    `$hint
}
Try-Step 'copied' { `$b = New-QraButton 'Copy' 'Secondary' `$QraGlyph.Copy; Show-QraCopied `$b 'Copied'; `$b.Text }
foreach (`$m in `$made) { `$m.Dispose() }
`$r | ConvertTo-Json -Compress
"@ | Where-Object { $_ -like '{*' } | Select-Object -Last 1) | ConvertFrom-Json
    }
    It 'child process produced results' { $script:Native | Should -Not -BeNullOrEmpty }
    It 'compiles the native controls' {
        $script:Native.native | Should -BeTrue
        $script:Native.spinnerType | Should -BeTrue
    }
    It 'creates native controls of the expected types' {
        $script:Native.button | Should -Be 'QraUi.ModernButton|True'
        $script:Native.card | Should -Be 'QraUi.RoundPanel|True'
        $script:Native.spinner | Should -Be 'QraUi.Spinner'
        $script:Native.badge | Should -Be 'QraUi.StepBadge'
        $script:Native.pill | Should -Be 'QraUi.Pill'
    }
    It 'every button variant is created' {
        $script:Native.variants | Should -Be 'Go:Primary,Go:Secondary,Go:Link,Go:Danger'
    }
    It 'Set-QraPill and Set-QraBadgeState update the native controls' {
        $script:Native.pillSet | Should -Be 'Broken|FAIL'
        $script:Native.badgeSet | Should -Be 'Blocked|2'
    }
    It 'DrawGlyph restores the Graphics text rendering hint it changed' {
        $script:Native.glyphHint | Should -Be 'ClearTypeGridFit'
    }
    It 'setting the same Activity twice leaves name and text intact' {
        $script:Native.spinnerActivity | Should -Be 'Working|Working'
    }
    It 'native spinner shows immediately via ShowNow, exposes ProgressBar and the activity name' {
        $script:Native.spinnerShowNow | Should -Be 'False|True|False|ProgressBar|Working'
    }
    It 'Show-QraCopied shows the done text' {
        $script:Native.copied | Should -Match 'Copied'
    }
}

Describe 'QraUi kit: factories (fallback controls)' {
    BeforeEach { $script:SaveNative = $script:UiNative; $script:UiNative = $false }
    AfterEach { $script:UiNative = $script:SaveNative }
    It 'each factory returns a control' {
        $made = @()
        try {
            $btn = New-QraButton 'x' 'Primary' $QraGlyph.Play; $made += $btn
            $btn | Should -BeOfType [System.Windows.Forms.Button]
            $spin = New-QraSpinner 24; $made += $spin
            $spin | Should -BeOfType [System.Windows.Forms.Control]
            $badge = New-QraStepBadge 3; $made += $badge
            $badge | Should -BeOfType [System.Windows.Forms.Control]
            $pill = New-QraPill 'OK' 'Ready'; $made += $pill
            $pill | Should -BeOfType [System.Windows.Forms.Control]
            $card = New-QraCard; $made += $card
            $card.GetType().FullName | Should -Be 'System.Windows.Forms.Panel'
            { Set-QraBadgeState $badge 'Done' } | Should -Not -Throw
            { Set-QraPill $pill 'WARN' 'Check' } | Should -Not -Throw
            { Set-QraSpinner $spin $true 'Working' } | Should -Not -Throw
            $spin.AccessibleName | Should -Be 'Working'
            { Set-QraSpinner $spin $false '' } | Should -Not -Throw
        } finally { foreach ($m in $made) { $m.Dispose() } }
    }
    It 'every button variant is created' -ForEach @(@{ V = 'Primary' }, @{ V = 'Secondary' }, @{ V = 'Link' }, @{ V = 'Danger' }) {
        $b = New-QraButton 'Go' $V
        try { $b.Text | Should -Be 'Go' } finally { $b.Dispose() }
    }
    It 'Show-QraCopied shows the done text' {
        $b = New-QraButton 'Copy' 'Secondary' $QraGlyph.Copy
        try { Show-QraCopied $b 'Copied'; $b.Text | Should -Match 'Copied' } finally { $b.Dispose() }
    }
}

Describe 'QraUi kit: Show-QraCopied timer and scaled strokes (child Windows PowerShell 5.1)' {
    It 'restores the text after 2 s, raises no error and tracks nothing afterwards' {
        $out = Invoke-ChildPs @"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. '$($script:KitPath)'
`$Error.Clear()
`$res = [ordered]@{}
foreach (`$native in `$true, `$false) {
    `$script:UiNative = `$native
    `$b = New-QraButton 'Copy' 'Secondary' `$QraGlyph.Copy
    Show-QraCopied `$b 'Copied'
    `$during = `$b.Text
    `$sw = [Diagnostics.Stopwatch]::StartNew()
    while (`$sw.ElapsedMilliseconds -lt 2500) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 20 }
    `$res["text`$native"] = `$b.Text
    `$res["during`$native"] = `$during
    `$res["glyph`$native"] = `$(if (`$native) { [int][char]`$b.Glyph[0] } else { 0 })
    `$b.Dispose()
}
`$res.errors = `$Error.Count
`$res.tracked = `$script:QraCopied.Count
`$res | ConvertTo-Json -Compress
"@
        $r = ($out | Where-Object { $_ -like '{*' } | Select-Object -Last 1) | ConvertFrom-Json
        $r.textTrue | Should -Be 'Copy'
        $r.textFalse | Should -Be 'Copy'
        $r.duringTrue | Should -Be 'Copied'
        $r.glyphTrue | Should -Be 0xE8C8
        $r.errors | Should -Be 0
        $r.tracked | Should -Be 0
    }
    It 'factories pass scaled strokes and focus ring to the painted controls' {
        $out = Invoke-ChildPs @"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. '$($script:KitPath)'
`$script:DpiScale = 2.0
`$b = New-QraButton 'x' 'Primary'; `$c1 = New-QraCard; `$p = New-QraPill 'OK' 'x'
[ordered]@{ btn = `$b.Stroke; ring = `$b.FocusRingWidth; card = `$c1.Stroke; pill = `$p.Stroke } | ConvertTo-Json -Compress
`$script:DpiScale = 1.0
`$b2 = New-QraButton 'x' 'Primary'
'one=' + `$b2.Stroke + '/' + `$b2.FocusRingWidth
"@
        $r = ($out | Where-Object { $_ -like '{*' } | Select-Object -Last 1) | ConvertFrom-Json
        $r.btn | Should -Be 2
        $r.ring | Should -Be 4
        $r.card | Should -Be 2
        $r.pill | Should -Be 2
        $out | Should -Contain 'one=1/2'
    }
}

Describe 'QraUi kit: emulated DPI scales a real form on any host DPI (child Windows PowerShell 5.1)' {
    It 'Set-QraEmulatedDpi + Initialize-QraForm scale a 100x100 child to 125 / 150 / 100 percent' {
        $out = Invoke-ChildPs @"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. '$($script:KitPath)'
`$res = [ordered]@{ device = `$script:DeviceDpi }
foreach (`$dpi in 120, 144, 96) {
    Set-QraEmulatedDpi `$dpi
    `$f = New-Object System.Windows.Forms.Form
    `$f.SuspendLayout()
    Initialize-QraForm `$f
    `$p = New-Object System.Windows.Forms.Panel
    `$p.Size = New-Object System.Drawing.Size(100, 100)
    `$f.Controls.Add(`$p)
    `$f.ResumeLayout(`$false)
    `$null = `$f.Handle
    `$res["w`$dpi"] = `$p.Width
    `$res["h`$dpi"] = `$p.Height
    `$f.Dispose()
}
`$res | ConvertTo-Json -Compress
"@
        $r = ($out | Where-Object { $_ -like '{*' } | Select-Object -Last 1) | ConvertFrom-Json
        # The scale is emulated/96 whatever the host DPI is (DesignDpi = 96 * device / emulated cancels the host).
        $r.w120 | Should -Be 125
        $r.h120 | Should -Be 125
        $r.w144 | Should -Be 150
        $r.h144 | Should -Be 150
        $r.w96 | Should -Be 100
    }
}

Describe 'QraUi kit: Start-QraWork' {
    BeforeAll {
        function Wait-Work($w) {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            while (-not (Test-QraWork $w) -and $sw.ElapsedMilliseconds -lt 10000) { Start-Sleep -Milliseconds 25 }
        }
    }
    It 'Start-QraWork returns output and state' {
        $w = Start-QraWork -Script { $State.Stage = 'two'; $X * 2 } -Variables @{ X = 21 }
        Wait-Work $w
        Test-QraWork $w | Should -BeTrue
        (Complete-QraWork $w).Output | Should -Be 42
        $w.State.Stage | Should -Be 'two'
    }
    It 'Start-QraWork imports named functions' {
        function Get-Seven { 7 }
        $w = Start-QraWork -Script { Get-Seven } -Functions 'Get-Seven'
        Wait-Work $w
        (Complete-QraWork $w).Output | Should -Be 7
    }
    It 'Start-QraWork surfaces an exception' {
        $w = Start-QraWork -Script { throw 'boom' }
        Wait-Work $w
        $r = Complete-QraWork $w
        $r.Error | Should -Match 'boom'
    }
    It 'Complete-QraWork reports no error on success' {
        $w = Start-QraWork -Script { 1 }
        Wait-Work $w
        (Complete-QraWork $w).Error | Should -BeNullOrEmpty
    }
    It 'Stop-QraWork stops a running script within 2 s' {
        $w = Start-QraWork -Script { Start-Sleep 30 }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Stop-QraWork $w
        $sw.ElapsedMilliseconds | Should -BeLessThan 2000
        { Stop-QraWork $w } | Should -Not -Throw
    }
}

Describe 'QraUi kit: fallback, language mode and compile guard' {
    It 'QRA_UI_FALLBACK=1 disables the native controls in a child process' {
        $out = Invoke-ChildPs @"
`$env:QRA_UI_FALLBACK = '1'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. '$($script:KitPath)'
'native=' + `$script:UiNative
'reason=' + `$script:QraDisplayReason
'card=' + (New-QraCard).GetType().FullName
"@
        $out | Should -Contain 'native=False'
        $out | Should -Contain 'reason=forced'
        $out | Should -Contain 'card=System.Windows.Forms.Panel'
    }
    It 'the language-mode guard says skip outside FullLanguage' {
        Get-QraCompileDecision 'ConstrainedLanguage' | Should -Be 'skip'
        Get-QraCompileDecision 'RestrictedLanguage' | Should -Be 'skip'
        Get-QraCompileDecision 'NoLanguage' | Should -Be 'skip'
        Get-QraCompileDecision 'FullLanguage' | Should -Be 'compile'
    }
    It 'loads without throwing in Constrained Language Mode and is not native' {
        $out = Invoke-ChildPs @"
`$ExecutionContext.SessionState.LanguageMode = 'ConstrainedLanguage'
Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
try {
    . '$($script:KitPath)'
    'loaded=yes'
    'native=' + `$script:UiNative
    'mode=' + `$script:QraLanguageMode
    'decision=' + (Get-QraCompileDecision `$script:QraLanguageMode)
    'compiled=' + [bool]('QraUi.Spinner' -as [type])
} catch { 'loaded=no ' + `$_.Exception.Message }
"@
        $out | Should -Contain 'loaded=yes'
        $out | Should -Contain 'native=False'
        $out | Should -Contain 'mode=ConstrainedLanguage'
        $out | Should -Contain 'decision=skip'
        $out | Should -Contain 'compiled=False'
    }
    It 'compiles at most once per process' {
        $out = Invoke-ChildPs @"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
`$ErrorActionPreference = 'Stop'
. '$($script:KitPath)'
. '$($script:KitPath)'
'native=' + `$script:UiNative
'assemblies=' + @([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { `$_.GetType('QraUi.Spinner', `$false) }).Count
"@
        $out | Should -Contain 'native=True'
        $out | Should -Contain 'assemblies=1'
    }
    It 'high contrast maps the tokens to system colours' {
        $out = Invoke-ChildPs @"
`$env:QRA_UI_HIGHCONTRAST = '1'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. '$($script:KitPath)'
'card=' + (`$C.Card.ToArgb() -eq [System.Drawing.SystemColors]::Window.ToArgb())
'primary=' + (`$C.Primary.ToArgb() -eq [System.Drawing.SystemColors]::Highlight.ToArgb())
'text=' + (`$C.Text.ToArgb() -eq [System.Drawing.SystemColors]::WindowText.ToArgb())
'success=' + (`$C.Success.ToArgb() -eq [System.Drawing.SystemColors]::WindowText.ToArgb())
'warning=' + (`$C.Warning.ToArgb() -eq [System.Drawing.SystemColors]::WindowText.ToArgb())
'danger=' + (`$C.Danger.ToArgb() -eq [System.Drawing.SystemColors]::WindowText.ToArgb())
'info=' + (`$C.Info.ToArgb() -eq [System.Drawing.SystemColors]::Highlight.ToArgb())
'focus=' + (`$C.Focus.ToArgb() -eq [System.Drawing.SystemColors]::Highlight.ToArgb())
'disabled=' + (`$C.Disabled.ToArgb() -eq [System.Drawing.SystemColors]::GrayText.ToArgb())
'themeInfo=' + ([QraUi.Theme]::Info.ToArgb() -eq `$C.Info.ToArgb())
'themeFocus=' + ([QraUi.Theme]::Focus.ToArgb() -eq `$C.Focus.ToArgb())
'dangerSoft=' + (`$C.DangerSoft.ToArgb() -eq [System.Drawing.SystemColors]::Window.ToArgb())
'hc=' + [QraUi.Theme]::HighContrast
"@
        $out | Should -Contain 'card=True'
        $out | Should -Contain 'primary=True'
        $out | Should -Contain 'text=True'
        foreach ($k in 'success','warning','danger','info','focus','disabled') { $out | Should -Contain ($k + '=True') }
        foreach ($k in 'themeInfo', 'themeFocus', 'dangerSoft') { $out | Should -Contain ($k + '=True') }
        $out | Should -Contain 'hc=True'
    }
}

Describe 'QraUi kit: app icon and window chrome' {
    It 'draws the app icon at the requested size' {
        foreach ($px in 16, 32, 48) {
            $ic = New-QraAppIcon $px
            try {
                $ic | Should -BeOfType [System.Drawing.Icon]
                $ic.Width | Should -Be $px
                $ic.Height | Should -Be $px
            } finally { $ic.Dispose() }
        }
    }
    It 'paints the navy rounded square with a light glyph and a transparent corner' {
        $ic = New-QraAppIcon 32
        try {
            $bmp = $ic.ToBitmap()
            try {
                $bmp.GetPixel(0, 0).A | Should -Be 0 -Because 'the corner is rounded'
                $edge = $bmp.GetPixel(3, 16)
                $edge.R | Should -Be 17; $edge.G | Should -Be 38; $edge.B | Should -Be 66
                $light = 0
                foreach ($x in 8..24) { foreach ($y in 8..24) { if ($bmp.GetPixel($x, $y).R -gt 200) { $light++ } } }
                $light | Should -BeGreaterThan 10 -Because 'the white shield glyph'
            } finally { $bmp.Dispose() }
        } finally { $ic.Dispose() }
    }
    It 'Set-QraWindowChrome sets the icon and does not throw in fallback display mode (child process)' {
        $out = Invoke-ChildPs @"
`$env:QRA_UI_FALLBACK = '1'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. '$($script:KitPath)'
`$f = New-Object System.Windows.Forms.Form
`$f.ShowInTaskbar = `$false; `$f.Opacity = 0
`$err = ''
try { Set-QraWindowChrome `$f -NoAppId } catch { `$err = `$_.Exception.Message }
'err=' + `$err
'icon=' + (`$null -ne `$f.Icon)
'native=' + `$script:UiNative
`$f.Show(); [System.Windows.Forms.Application]::DoEvents()
'shown=' + `$f.Visible
`$f.Dispose()
"@
        $out | Should -Contain 'err='
        $out | Should -Contain 'icon=True'
        $out | Should -Contain 'native=False'
        $out | Should -Contain 'shown=True'
    }
    It 'Set-QraWindowChrome and Enable-QraForeground skip the native calls where Add-Type is not allowed (child process)' {
        $out = Invoke-ChildPs @"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. '$($script:KitPath)'
`$script:QraWin2Ready = `$null
`$script:QraLanguageMode = 'ConstrainedLanguage'
`$f = New-Object System.Windows.Forms.Form
`$err = ''
try { Set-QraWindowChrome `$f; Enable-QraForeground } catch { `$err = `$_.Exception.Message }
'err=' + `$err
'ready=' + [bool]`$script:QraWin2Ready
`$f.Dispose()
"@
        $out | Should -Contain 'err='
        $out | Should -Contain 'ready=False'
    }
    It 'sets the app id once per process and the caption colours without throwing (child process)' {
        $out = Invoke-ChildPs @"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. '$($script:KitPath)'
`$f = New-Object System.Windows.Forms.Form
`$f.ShowInTaskbar = `$false; `$f.Opacity = 0
Set-QraWindowChrome `$f
'idset=' + `$script:QraAppIdSet
`$g = New-Object System.Windows.Forms.Form
Set-QraWindowChrome `$g -AppId 'Other.Id'
'idstill=' + `$script:QraAppIdSet
`$f.Show(); [System.Windows.Forms.Application]::DoEvents()
'shown=' + `$f.Visible
`$f.Dispose(); `$g.Dispose()
"@
        $out | Should -Contain 'idset=True'
        $out | Should -Contain 'idstill=True'
        $out | Should -Contain 'shown=True'
    }
}

Describe 'QraUi kit: app icon file (ICO writer)' {
    BeforeAll {
        $script:IcoPath = Join-Path $TestDrive 'QuarantineReviewAssistant.ico'
        $script:IcoResult = Write-QraIcoFile $script:IcoPath
        $script:IcoBytes = [System.IO.File]::ReadAllBytes($script:IcoPath)
        $script:IcoSizes = 16, 24, 32, 48, 64, 256
    }
    It 'reports success and leaves no temp file behind' {
        $script:IcoResult | Should -BeTrue
        Test-Path -LiteralPath ($script:IcoPath + '.tmp') | Should -BeFalse
    }
    It 'starts with a valid ICONDIR: reserved 0, type 1, six entries' {
        [BitConverter]::ToUInt16($script:IcoBytes, 0) | Should -Be 0
        [BitConverter]::ToUInt16($script:IcoBytes, 2) | Should -Be 1
        [BitConverter]::ToUInt16($script:IcoBytes, 4) | Should -Be 6
    }
    It 'describes every entry (size, 32 bit, image range) and stores 256 as 0' {
        for ($i = 0; $i -lt 6; $i++) {
            $e = 6 + 16 * $i
            $want = $script:IcoSizes[$i]
            $stored = if ($want -eq 256) { 0 } else { $want }
            [int]$script:IcoBytes[$e] | Should -Be $stored -Because "width of entry $i"
            [int]$script:IcoBytes[$e + 1] | Should -Be $stored -Because "height of entry $i"
            [BitConverter]::ToUInt16($script:IcoBytes, $e + 4) | Should -Be 1
            [BitConverter]::ToUInt16($script:IcoBytes, $e + 6) | Should -Be 32
            $len = [BitConverter]::ToUInt32($script:IcoBytes, $e + 8); $off = [BitConverter]::ToUInt32($script:IcoBytes, $e + 12)
            $len | Should -BeGreaterThan 8
            ($off + $len) | Should -BeLessOrEqual $script:IcoBytes.Length
        }
    }
    It 'has a PNG signature at the start of every image, and the images fill the file exactly' {
        $end = 6 + 16 * 6
        for ($i = 0; $i -lt 6; $i++) {
            $e = 6 + 16 * $i
            $len = [BitConverter]::ToUInt32($script:IcoBytes, $e + 8); $off = [BitConverter]::ToUInt32($script:IcoBytes, $e + 12)
            $off | Should -Be $end -Because 'images follow the directory one after the other'
            @($script:IcoBytes[$off..($off + 7)]) | Should -Be @(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)
            $end += $len
        }
        $end | Should -Be $script:IcoBytes.Length
    }
    It 'loads as a System.Drawing.Icon in the 16, 48 and 64 pixel sizes' {
        foreach ($px in 16, 48, 64) {
            $ico = New-Object System.Drawing.Icon($script:IcoPath, $px, $px)
            try { $ico.Width | Should -Be $px } finally { $ico.Dispose() }
        }
        $default = New-Object System.Drawing.Icon($script:IcoPath)
        try { $default.Width | Should -BeGreaterThan 0 } finally { $default.Dispose() }
    }
    It 'draws each size with the shared bitmap helper at exactly that size' {
        foreach ($px in 16, 40, 256) {
            $bmp = New-QraAppIconBitmap $px
            try { $bmp.Width | Should -Be $px; $bmp.Height | Should -Be $px; $bmp.GetPixel([int]($px / 2), [int]($px / 2)).A | Should -Be 255 } finally { $bmp.Dispose() }
        }
    }
    It 'accepts a custom list of sizes' {
        $p = Join-Path $TestDrive 'two.ico'
        Write-QraIcoFile $p @(32, 256) | Should -BeTrue
        $b = [System.IO.File]::ReadAllBytes($p)
        [BitConverter]::ToUInt16($b, 4) | Should -Be 2
    }
}

Describe 'QraUi kit: desktop shortcut (child Windows PowerShell 5.1, never the real Desktop)' {
    BeforeAll {
        $script:LnkDir = Join-Path $TestDrive 'desk'
        New-Item -ItemType Directory -Force -Path $script:LnkDir | Out-Null
        $script:LnkTarget = Join-Path $TestDrive 'Start-Here.cmd'
        Set-Content -LiteralPath $script:LnkTarget -Value '@echo off'
        $script:LnkIcon = Join-Path $TestDrive 'icon.ico'
        $script:LnkPath = Join-Path $script:LnkDir 'Quarantine Review Assistant.lnk'
        $body = @'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. '__KIT__'
$lnk = '__LNK__'; $target = '__TARGET__'; $wd = '__WD__'; $ico = '__ICO__'
$r1 = New-QraDesktopShortcut -ShortcutPath $lnk -Target $target -WorkingDirectory $wd -IconPath $ico
"s1=$($r1.Status)"
$sh = New-Object -ComObject WScript.Shell
$l = $sh.CreateShortcut($lnk)
"target=$($l.TargetPath)"; "wd=$($l.WorkingDirectory)"; "icon=$($l.IconLocation)"; "style=$($l.WindowStyle)"; "desc=$($l.Description)"
[void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($l); [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($sh)
$stamp = (Get-Item -LiteralPath $lnk).LastWriteTimeUtc.Ticks
$r2 = New-QraDesktopShortcut -ShortcutPath $lnk -Target $target -WorkingDirectory $wd -IconPath $ico
"s2=$($r2.Status)"
"unchanged=$((Get-Item -LiteralPath $lnk).LastWriteTimeUtc.Ticks -eq $stamp)"
$r3 = New-QraDesktopShortcut -ShortcutPath $lnk -Target $target -WorkingDirectory $wd -IconPath $ico -Force
"s3=$($r3.Status)"
$r4 = New-QraDesktopShortcut -ShortcutPath ($lnk + '2.lnk') -Target ($target + '.missing') -WorkingDirectory $wd
"s4=$($r4.Status)"
$r5 = New-QraDesktopShortcut -ShortcutPath (Join-Path '__WD__\no-such-folder' 'x.lnk') -Target $target -WorkingDirectory $wd
"s5=$($r5.Status)"; "s5msg=$([bool]$r5.Message)"
'@
        $body = $body.Replace('__KIT__', $script:KitPath).Replace('__LNK__', $script:LnkPath).Replace('__TARGET__', $script:LnkTarget).Replace('__WD__', $TestDrive).Replace('__ICO__', $script:LnkIcon)
        $script:LnkOut = Invoke-ChildPs $body
    }
    It 'creates the shortcut with the right target, working directory, icon, window style and description' {
        $script:LnkOut | Should -Contain 's1=Created'
        $script:LnkOut | Should -Contain ('target=' + $script:LnkTarget)
        $script:LnkOut | Should -Contain ('wd=' + $TestDrive)
        $script:LnkOut | Should -Contain ('icon=' + $script:LnkIcon + ',0')
        $script:LnkOut | Should -Contain 'style=7'
        $script:LnkOut | Should -Contain 'desc=Quarantine Review Assistant - host launcher'
    }
    It 'reports Exists and changes nothing without -Force' {
        $script:LnkOut | Should -Contain 's2=Exists'
        $script:LnkOut | Should -Contain 'unchanged=True'
    }
    It 'reports Replaced with -Force' { $script:LnkOut | Should -Contain 's3=Replaced' }
    It 'reports Error (and does not throw) for a missing target or an impossible path' {
        $script:LnkOut | Should -Contain 's4=Error'
        $script:LnkOut | Should -Contain 's5=Error'
        $script:LnkOut | Should -Contain 's5msg=True'
    }
    It 'skips with an Error status where Constrained Language Mode is in force (no COM, no Add-Type)' {
        Mock Get-QraCompileDecision { 'skip' }
        $r = New-QraDesktopShortcut -ShortcutPath (Join-Path $TestDrive 'never.lnk') -Target $script:LnkTarget
        $r.Status | Should -Be 'Error'
        Test-Path -LiteralPath (Join-Path $TestDrive 'never.lnk') | Should -BeFalse
        Write-QraIcoFile (Join-Path $TestDrive 'never.ico') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $TestDrive 'never.ico') | Should -BeFalse
    }
}

Describe 'QraUi kit: DPI awareness order and fallbacks' {
    BeforeEach { $script:SaveNativeFlag = $script:UiNative }
    AfterEach { $script:UiNative = $script:SaveNativeFlag }
    It 'tries PerMonitorV2 first and stops there when it works' {
        Mock Get-QraCompileDecision { 'compile' }
        Mock Set-QraProcessDpiV2 { $true }
        Mock Set-QraProcessDpiShcore { $true }
        Mock Set-QraProcessDpiSystem { $true }
        $script:UiNative = $true
        Enable-QraDpiAwareness 'permonitor' | Should -Be 'PerMonitorV2'
        Should -Invoke Set-QraProcessDpiV2 -Times 1 -Exactly
        Should -Invoke Set-QraProcessDpiShcore -Times 0 -Exactly
        Should -Invoke Set-QraProcessDpiSystem -Times 0 -Exactly
    }
    It 'falls back to the shcore per-monitor call when V2 is not available' {
        Mock Get-QraCompileDecision { 'compile' }
        Mock Set-QraProcessDpiV2 { $false }
        Mock Set-QraProcessDpiShcore { $true }
        Mock Set-QraProcessDpiSystem { $true }
        $script:UiNative = $true
        Enable-QraDpiAwareness 'permonitor' | Should -Be 'PerMonitor'
        Should -Invoke Set-QraProcessDpiV2 -Times 1 -Exactly
        Should -Invoke Set-QraProcessDpiShcore -Times 1 -Exactly
        Should -Invoke Set-QraProcessDpiSystem -Times 0 -Exactly
    }
    It 'falls back to the system aware call last' {
        Mock Get-QraCompileDecision { 'compile' }
        Mock Set-QraProcessDpiV2 { $false }
        Mock Set-QraProcessDpiShcore { $false }
        Mock Set-QraProcessDpiSystem { $true }
        $script:UiNative = $true
        Enable-QraDpiAwareness 'permonitor' | Should -Be 'System'
        Should -Invoke Set-QraProcessDpiSystem -Times 1 -Exactly
    }
    It 'goes straight to system aware in system mode (the review window) and in the plain fallback' {
        Mock Get-QraCompileDecision { 'compile' }
        Mock Set-QraProcessDpiV2 { $true }
        Mock Set-QraProcessDpiShcore { $true }
        Mock Set-QraProcessDpiSystem { $true }
        $script:UiNative = $true
        Enable-QraDpiAwareness 'system' | Should -Be 'System'
        $script:UiNative = $false
        Enable-QraDpiAwareness 'permonitor' | Should -Be 'System'
        Should -Invoke Set-QraProcessDpiV2 -Times 0 -Exactly
        Should -Invoke Set-QraProcessDpiShcore -Times 0 -Exactly
        Should -Invoke Set-QraProcessDpiSystem -Times 2 -Exactly
    }
    It 'touches nothing where compiling is not allowed (Constrained Language Mode)' {
        Mock Get-QraCompileDecision { 'skip' }
        Mock Set-QraProcessDpiV2 { $true }
        Mock Set-QraProcessDpiShcore { $true }
        Mock Set-QraProcessDpiSystem { $true }
        $script:UiNative = $true
        Enable-QraDpiAwareness 'permonitor' | Should -Be 'None'
        Should -Invoke Set-QraProcessDpiV2 -Times 0 -Exactly
        Should -Invoke Set-QraProcessDpiShcore -Times 0 -Exactly
        Should -Invoke Set-QraProcessDpiSystem -Times 0 -Exactly
    }
    It 'the kit declares the awareness after it compiled the native helpers and before it reads the DPI' {
        $kit = [IO.File]::ReadAllText($script:KitPath)
        $compile = $kit.IndexOf("Add-Type -TypeDefinition `$script:QraSource")
        $apply = $kit.IndexOf('$script:QraAwareness = Enable-QraDpiAwareness')
        $read = $kit.IndexOf('[QraUi.Native]::DeviceDpi()')
        $compile | Should -BeGreaterThan 0
        $apply | Should -BeGreaterThan $compile
        $read | Should -BeGreaterThan $apply
    }
}

Describe 'QraUi kit: per-monitor mode, system mode and Constrained Language Mode (child Windows PowerShell 5.1)' {
    BeforeAll {
        $script:DpiHead = @"
`$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
"@ + "`r`n"
        $script:DpiKit = ". '$($script:KitPath)'`r`n"
        function Get-LastJson($lines) { ($lines | Where-Object { $_ -like '{*' } | Select-Object -Last 1) | ConvertFrom-Json }
    }
    It 'is per-monitor aware by default, builds pixel fonts and registers windows' {
        $r = Get-LastJson (Invoke-ChildPs ($script:DpiHead + $script:DpiKit + @'
$f = New-Object System.Windows.Forms.Form
$ok = Register-QraDpiWindow $f
[ordered]@{ awareness = $script:QraAwareness; level = (Get-QraAwarenessLevel); perMonitor = $script:QraPerMonitor; unit = [string](New-Font 10).Unit
    registered = $ok; stored = (Get-QraFormDpi $f); device = $script:DeviceDpi; monitorDpi = (Get-QraMonitorDpi) } | ConvertTo-Json -Compress
'@))
        $r.awareness | Should -BeIn 'PerMonitorV2', 'PerMonitor'
        $r.level | Should -Be 2
        $r.perMonitor | Should -BeTrue
        $r.unit | Should -Be 'Pixel'
        $r.registered | Should -BeTrue
        $r.stored | Should -Be ([int][Math]::Round([double]$r.device))
        $r.monitorDpi | Should -BeGreaterOrEqual 96
    }
    It 'QRA_DPI_MODE=system keeps the old system-aware behaviour: point fonts, no live rescale' {
        $r = Get-LastJson (Invoke-ChildPs ($script:DpiHead + "`$env:QRA_DPI_MODE = 'system'`r`n" + $script:DpiKit + @'
$f = New-Object System.Windows.Forms.Form
[ordered]@{ awareness = $script:QraAwareness; level = (Get-QraAwarenessLevel); perMonitor = $script:QraPerMonitor; unit = [string](New-Font 10).Unit
    registered = (Register-QraDpiWindow $f); stored = (Get-QraFormDpi $f); same = ((Get-QraMonitorDpi) -eq [int][Math]::Round($script:DeviceDpi)) } | ConvertTo-Json -Compress
'@))
        $r.awareness | Should -Be 'System'
        $r.level | Should -Be 1
        $r.perMonitor | Should -BeFalse
        $r.unit | Should -Be 'Point'
        $r.registered | Should -BeFalse
        $r.stored | Should -Be 0
        $r.same | Should -BeTrue
    }
    It 'Constrained Language Mode: no awareness call, no registration, still loads' {
        $r = Get-LastJson (Invoke-ChildPs (@"
`$ExecutionContext.SessionState.LanguageMode = 'ConstrainedLanguage'
Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
$($script:DpiKit)
"@ + @'
[ordered]@{ awareness = $script:QraAwareness; perMonitor = $script:QraPerMonitor; native = $script:UiNative; registered = [bool](Register-QraDpiWindow $null) } | ConvertTo-Json -Compress
'@))
        $r.awareness | Should -Be 'None'
        $r.perMonitor | Should -BeFalse
        $r.native | Should -BeFalse
        $r.registered | Should -BeFalse
    }
    It 'Limit-FormToScreen clamps to the form''s own screen, not the primary one' {
        $r = Get-LastJson (Invoke-ChildPs ($script:DpiHead + $script:DpiKit + @'
$res = @()
foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
    $wa = $s.WorkingArea
    $f = New-Object System.Windows.Forms.Form
    $f.StartPosition = 'Manual'; $f.Location = $wa.Location; $f.Size = New-Object System.Drawing.Size(($wa.Width + 600), ($wa.Height + 600)); $f.MinimumSize = $f.Size
    Limit-FormToScreen $f
    $res += "$($f.Width -eq $wa.Width)/$($f.Height -eq $wa.Height)/$($f.MinimumSize.Width -le $wa.Width)"
    $f.Dispose()
}
[ordered]@{ results = ($res -join ',') } | ConvertTo-Json -Compress
'@))
        foreach ($x in ($r.results -split ',')) { $x | Should -Be 'True/True/True' }
    }
}

Describe 'QraUi kit: live rescale of a window (child Windows PowerShell 5.1)' {
    BeforeAll {
        $script:DpiHead = @"
`$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. '$($script:KitPath)'
"@ + "`r`n"
        function Get-LastJson($lines) { ($lines | Where-Object { $_ -like '{*' } | Select-Object -Last 1) | ConvertFrom-Json }
    }
    It 'scales every font exactly once (ambient, explicit, shared, cached table) and the kit control metrics, column widths and ItemHeight' {
        $out = Invoke-ChildPs ($script:DpiHead + @'
Set-QraEmulatedDpi 96
$f = New-Object System.Windows.Forms.Form
$f.SuspendLayout(); Initialize-QraForm $f
$shared = New-Font 10
$lblAmbient = New-Object System.Windows.Forms.Label
$lblExplicit = New-Object System.Windows.Forms.Label; $lblExplicit.Font = New-Font 12 'Bold'
$lblShared = New-Object System.Windows.Forms.Label; $lblShared.Font = $shared
$pnl = New-Object System.Windows.Forms.Panel
$deepAmbient = New-Object System.Windows.Forms.Label; $deepShared = New-Object System.Windows.Forms.Label; $deepShared.Font = $shared
$pnl.Controls.AddRange(@($deepAmbient, $deepShared))
$btn = New-QraButton 'x' 'Secondary' $QraGlyph.Check; $card = New-QraCard; $spin = New-QraSpinner 24; $pill = New-QraPill 'OK' 'x'; $badge = New-QraStepBadge 2
$lv = New-Object System.Windows.Forms.ListView; $lv.View = 'Details'
[void]$lv.Columns.Add('a', 100); [void]$lv.Columns.Add('b', 200)
$tv = New-Object System.Windows.Forms.TreeView; $tv.ItemHeight = 20
$f.Controls.AddRange(@($lblAmbient, $lblExplicit, $lblShared, $pnl, $btn, $card, $spin, $pill, $badge, $lv, $tv))
$f.ResumeLayout($false)
$f.Font = New-Font 10
$tbl = @{ Shared = $shared; Other = (New-Font 14); NotAFont = 'keep' }
$null = Register-QraDpiWindow $f -FontTables @($tbl)
$before = [ordered]@{ form = $f.Font.Size; explicit = $lblExplicit.Font.Size; shared = $shared.Size; other = $tbl.Other.Size; icon = $btn.IconFont.Size
    radius = $btn.Radius; card = $card.Radius; shadow = $card.ShadowSize; thick = $spin.Thickness; col0 = $lv.Columns[0].Width; col1 = $lv.Columns[1].Width; item = $tv.ItemHeight }
Invoke-QraDpiChange $f 120 $null
$r = 1.25
[ordered]@{
    err = $script:QraDpiLastError; stored = (Get-QraFormDpi $f); scaleG = $script:DpiScale
    formRatio = $f.Font.Size / $before.form; ambientIsForm = ($lblAmbient.Font.Size -eq $f.Font.Size); deepAmbientIsForm = ($deepAmbient.Font.Size -eq $f.Font.Size)
    explicitRatio = $lblExplicit.Font.Size / $before.explicit; sharedRatio = $lblShared.Font.Size / $before.shared; deepSharedRatio = $deepShared.Font.Size / $before.shared
    tableSharedRatio = $tbl.Shared.Size / $before.shared; tableOtherRatio = $tbl.Other.Size / $before.other; tableKept = $tbl.NotAFont
    sameInstance = ([object]::ReferenceEquals($tbl.Shared, $lblShared.Font) -and [object]::ReferenceEquals($lblShared.Font, $deepShared.Font))
    iconRatio = $btn.IconFont.Size / $before.icon; radius = $btn.Radius; card = $card.Radius; shadow = $card.ShadowSize; thick = [Math]::Round($spin.Thickness, 3)
    col0 = $lv.Columns[0].Width; col1 = $lv.Columns[1].Width; item = $tv.ItemHeight; before = $before
} | ConvertTo-Json -Compress -Depth 4
'@)
        $r = Get-LastJson $out
        $r.err | Should -BeNullOrEmpty
        $r.stored | Should -Be 120
        $r.scaleG | Should -Be 1.25
        foreach ($k in 'formRatio', 'explicitRatio', 'sharedRatio', 'deepSharedRatio', 'tableSharedRatio', 'tableOtherRatio', 'iconRatio') {
            $r.$k | Should -BeGreaterThan 1.24 -Because "$k scaled once (x1.25)"
            $r.$k | Should -BeLessThan 1.26 -Because "$k scaled once (x1.25)"
        }
        $r.ambientIsForm | Should -BeTrue
        $r.deepAmbientIsForm | Should -BeTrue
        $r.tableKept | Should -Be 'keep'
        $r.sameInstance | Should -BeTrue -Because 'one new font per distinct source font, shared by controls and the cached table'
        $r.radius | Should -Be ([int][Math]::Round($r.before.radius * 1.25))
        $r.card | Should -Be ([int][Math]::Round($r.before.card * 1.25))
        $r.shadow | Should -Be ([int][Math]::Round($r.before.shadow * 1.25))
        $r.thick | Should -Be ([Math]::Round($r.before.thick * 1.25, 3))
        $r.col0 | Should -Be 125
        $r.col1 | Should -Be 250
        $r.item | Should -Be 25
    }
    It 'Invoke-QraDpiChange 96 -> 120 -> 96: child bounds x1.25 and back within 1 px, the suggested rectangle is applied, the relayout runs once per change' {
        $out = Invoke-ChildPs ($script:DpiHead + @'
Set-QraEmulatedDpi 96
$script:Relayouts = 0
$f = New-Object System.Windows.Forms.Form
$f.SuspendLayout(); Initialize-QraForm $f
$f.Size = New-Object System.Drawing.Size(400, 300); $f.MinimumSize = New-Object System.Drawing.Size(200, 150)
$p = New-Object System.Windows.Forms.Panel; $p.SetBounds(10, 20, 100, 40)
$dock = New-Object System.Windows.Forms.Panel; $dock.Dock = 'Top'; $dock.Height = 30
$f.Controls.AddRange(@($p, $dock)); $f.ResumeLayout($false); $f.Font = New-Font 10
$null = Register-QraDpiWindow $f -Relayout { param($x) $script:Relayouts++ }
$a = [ordered]@{ p = "$($p.Left),$($p.Top),$($p.Width),$($p.Height)"; dock = $dock.Height; min = "$($f.MinimumSize.Width)x$($f.MinimumSize.Height)" }
Invoke-QraDpiChange $f 120 (New-Object System.Drawing.Rectangle(50, 60, 500, 375))
$b = [ordered]@{ p = "$($p.Left),$($p.Top),$($p.Width),$($p.Height)"; dock = $dock.Height; min = "$($f.MinimumSize.Width)x$($f.MinimumSize.Height)"; bounds = "$($f.Left),$($f.Top),$($f.Width),$($f.Height)"; relayouts = $script:Relayouts; stored = (Get-QraFormDpi $f) }
Invoke-QraDpiChange $f 120 $null   # same DPI again: nothing happens
$same = $script:Relayouts
Invoke-QraDpiChange $f 96 (New-Object System.Drawing.Rectangle(50, 60, 400, 300))
$c = [ordered]@{ p = "$($p.Left),$($p.Top),$($p.Width),$($p.Height)"; dock = $dock.Height; min = "$($f.MinimumSize.Width)x$($f.MinimumSize.Height)"; bounds = "$($f.Left),$($f.Top),$($f.Width),$($f.Height)"; relayouts = $script:Relayouts; stored = (Get-QraFormDpi $f); fontPx = [Math]::Round($f.Font.Size, 2) }
[ordered]@{ err = $script:QraDpiLastError; a = $a; b = $b; sameCount = $same; c = $c } | ConvertTo-Json -Compress -Depth 4
'@)
        $r = Get-LastJson $out
        $r.err | Should -BeNullOrEmpty
        $pa = [int[]]($r.a.p -split ','); $pb = [int[]]($r.b.p -split ','); $pc = [int[]]($r.c.p -split ',')
        for ($i = 0; $i -lt 4; $i++) {
            [Math]::Abs($pb[$i] - [Math]::Round($pa[$i] * 1.25)) | Should -BeLessOrEqual 1 -Because "child bounds part $i x1.25"
            [Math]::Abs($pc[$i] - $pa[$i]) | Should -BeLessOrEqual 1 -Because "child bounds part $i back to the original"
        }
        [Math]::Abs($r.b.dock - 37.5) | Should -BeLessOrEqual 1
        $r.c.dock | Should -Be $r.a.dock
        $r.b.bounds | Should -Be '50,60,500,375'
        $r.c.bounds | Should -Be '50,60,400,300'
        $bm = [int[]]($r.b.min -split 'x')
        $bm[0] | Should -BeGreaterThan 235 -Because 'MinimumSize is scaled with the form (about x1.25; the window frame itself is not scaled by WinForms)'
        $bm[0] | Should -BeLessOrEqual 250
        $bm[1] | Should -BeGreaterThan 170
        $bm[1] | Should -BeLessOrEqual 190
        $r.c.min | Should -Be $r.a.min
        $r.b.relayouts | Should -Be 1
        $r.sameCount | Should -Be 1
        $r.c.relayouts | Should -Be 2
        $r.b.stored | Should -Be 120
        $r.c.stored | Should -Be 96
        $r.c.fontPx | Should -Be 13.33
    }
    It 'Use-QraFormDpi: two windows with different DPIs never lay out with each other''s scale; an unregistered window leaves the globals alone' {
        $r = Get-LastJson (Invoke-ChildPs ($script:DpiHead + @'
$f1 = New-Object System.Windows.Forms.Form; $f2 = New-Object System.Windows.Forms.Form; $loose = New-Object System.Windows.Forms.Form
Set-QraEmulatedDpi 96;  $null = Register-QraDpiWindow $f1
Set-QraEmulatedDpi 120; $null = Register-QraDpiWindow $f2
function Invoke-FakeLayout($form) { Use-QraFormDpi $form; [ordered]@{ s = (S 100); px = [Math]::Round((New-Font 9).Size, 2) } }
$a = Invoke-FakeLayout $f1; $b = Invoke-FakeLayout $f2; $c = Invoke-FakeLayout $f1
Set-QraEmulatedDpi 144; Use-QraFormDpi $loose
[ordered]@{ a = $a; b = $b; c = $c; looseScale = $script:DpiScale; looseDesign = [Math]::Round($script:DesignDpi, 2) } | ConvertTo-Json -Compress -Depth 4
'@))
        $r.a.s | Should -Be 100
        $r.b.s | Should -Be 125
        $r.c.s | Should -Be 100 -Because 'after the other window laid out, this one gets its own scale back'
        $r.a.px | Should -Be 12
        $r.b.px | Should -Be 15
        $r.looseScale | Should -Be 1.5
    }
    It 'a real WM_DPICHANGED reaches the watcher: stored DPI, rectangle and relayout' {
        $r = Get-LastJson (Invoke-ChildPs ($script:DpiHead + @'
Set-QraEmulatedDpi 96
$script:Relayouts = 0
$f = New-Object System.Windows.Forms.Form
$f.SuspendLayout(); Initialize-QraForm $f; $f.Size = New-Object System.Drawing.Size(400, 300)
$p = New-Object System.Windows.Forms.Panel; $p.SetBounds(10, 20, 100, 40); $f.Controls.Add($p); $f.ResumeLayout($false)
$null = $f.Handle
$null = Register-QraDpiWindow $f -Relayout { param($x) $script:Relayouts++ }
$w = $script:QraDpiForms[$f].Watcher
[QraUi.Native]::SendDpiChanged($f.Handle, 120, 30, 40, 530, 415)
[ordered]@{ err = $script:QraDpiLastError; count = $w.Count; stored = (Get-QraFormDpi $f); relayouts = $script:Relayouts; bounds = "$($f.Left),$($f.Top),$($f.Width),$($f.Height)"; panel = "$($p.Width)x$($p.Height)" } | ConvertTo-Json -Compress
'@))
        $r.err | Should -BeNullOrEmpty
        $r.count | Should -Be 1
        $r.stored | Should -Be 120
        $r.relayouts | Should -Be 1
        $r.bounds | Should -Be '30,40,500,375'
        $r.panel | Should -Be '125x50'
    }
}

Describe 'QraUi kit: Hide-QraConsole under a minimized start (Start-Here.cmd uses start /min)' {
    # The Exchange Online sign-in window attaches to the console, and Windows hides windows whose owner is minimized.
    # So the console must end up hidden but NOT minimized, or the sign-in never appears (seen in a real test).
    It 'leaves the console hidden and not minimized' -Skip:([bool]$env:GITHUB_ACTIONS -or -not [Environment]::UserInteractive) {
        $dir = Join-Path ([IO.Path]::GetTempPath()) ('qra-hide-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        try {
            $probe = Join-Path $dir 'probe.ps1'; $out = Join-Path $dir 'out.json'
            $body = @"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. '$($script:KitPath)'
Add-Type -Namespace HideProbe -Name W -MemberDefinition '[DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr h); [DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);'
`$h = [HideProbe.W]::GetConsoleWindow()
`$r = [ordered]@{ before_iconic = [HideProbe.W]::IsIconic(`$h) }
Hide-QraConsole
`$r.after_iconic = [HideProbe.W]::IsIconic(`$h); `$r.after_visible = [HideProbe.W]::IsWindowVisible(`$h)
(`$r | ConvertTo-Json -Compress) | Set-Content -LiteralPath '$out'
"@
            [IO.File]::WriteAllText($probe, $body, (New-Object Text.UTF8Encoding($true)))
            & cmd.exe /c "start `"`" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$probe`""
            $deadline = [DateTime]::UtcNow.AddSeconds(30)
            while (-not (Test-Path -LiteralPath $out) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 200 }
            $r = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json
            $r.before_iconic | Should -BeTrue -Because 'start /min creates the console minimized'
            $r.after_iconic | Should -BeFalse -Because 'a minimized owner hides the Exchange sign-in window'
            $r.after_visible | Should -BeFalse -Because 'the console must never be visible'
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'restores a minimized console off-screen and without activation before hiding it' {
        $t = [IO.File]::ReadAllText($script:KitPath)
        $t | Should -Match 'IsIconic\(\$console\)'
        $t | Should -Match 'SetWindowPos\(\$console, \[IntPtr\]::Zero, -32000, -32000'
        $t | Should -Match 'ShowWindow\(\$console, 4\)'
    }
}

Describe 'QraUi kit: painted check box and list-view check images' {
    BeforeAll {
        $script:CbHead = @"
`$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -Namespace CbTest -Name Win -MemberDefinition '[DllImport("user32.dll")] public static extern System.IntPtr SendMessage(System.IntPtr h, int msg, System.IntPtr w, System.IntPtr l);'
. '$($script:KitPath)'
[System.Windows.Forms.Application]::EnableVisualStyles()
"@ + "`r`n"
        function Get-LastJson($lines) {
            $json = @($lines | Where-Object { $_ -like '{*' }) | Select-Object -Last 1
            if (-not $json) { throw ('child printed no JSON: ' + ($lines -join ' | ')) }
            $json | ConvertFrom-Json
        }
    }
    It 'New-QraCheckBox returns the native QraUi.CheckBox (still a CheckBox) when the kit is compiled' {
        $r = Get-LastJson (Invoke-ChildPs ($script:CbHead + @'
Set-QraEmulatedDpi 96
$cb = New-QraCheckBox 'Option one'
[ordered]@{ native = $script:UiNative; type = $cb.GetType().FullName; isCheckBox = ($cb -is [System.Windows.Forms.CheckBox]); text = $cb.Text; box = $cb.BoxSize; gap = $cb.Gap; radius = $cb.Radius
    indent = (Get-QraCheckBoxIndent $cb); role = [string]$cb.AccessibleRole } | ConvertTo-Json -Compress
'@))
        $r.native | Should -BeTrue
        $r.type | Should -Be 'QraUi.CheckBox'
        $r.isCheckBox | Should -BeTrue
        $r.text | Should -Be 'Option one'
        $r.box | Should -Be 16
        $r.gap | Should -Be 8
        $r.radius | Should -Be 4
        $r.indent | Should -Be 24
    }
    It 'falls back to the plain CheckBox (forced fallback and Constrained Language Mode) and leaves list views alone' {
        $r = Get-LastJson (Invoke-ChildPs (@'
$env:QRA_UI_FALLBACK = '1'
'@ + "`r`n" + $script:CbHead + @'
Set-QraEmulatedDpi 96
$cb = New-QraCheckBox 'Plain'
$lv = New-Object System.Windows.Forms.ListView; $lv.CheckBoxes = $true
[ordered]@{ native = $script:UiNative; type = $cb.GetType().FullName; text = $cb.Text; indent = (Get-QraCheckBoxIndent $cb); images = [bool](Set-QraListCheckImages $lv); state = [bool]$lv.StateImageList } | ConvertTo-Json -Compress
'@))
        $r.native | Should -BeFalse
        $r.type | Should -Be 'System.Windows.Forms.CheckBox'
        $r.text | Should -Be 'Plain'
        $r.indent | Should -Be 24
        $r.images | Should -BeFalse
        $r.state | Should -BeFalse
    }
    It 'Checked toggles, CheckedChanged fires, a click toggles and the Space key toggles it (real key messages)' {
        $r = Get-LastJson (Invoke-ChildPs ($script:CbHead + @'
Set-QraEmulatedDpi 96
$f = New-Object System.Windows.Forms.Form; $f.ShowInTaskbar = $false; $f.Opacity = 0; $f.StartPosition = 'Manual'; $f.Location = New-Object System.Drawing.Point(-32000, -32000)
$cb = New-QraCheckBox 'Toggle me'; $cb.SetBounds(10, 10, 300, 24); $f.Controls.Add($cb)
$f.Show(); [System.Windows.Forms.Application]::DoEvents()
$script:n = 0
$cb.Add_CheckedChanged({ $script:n++ })
$out = [ordered]@{ start = $cb.Checked }
$cb.Checked = $true; $out.afterSet = $cb.Checked; $out.eventsSet = $script:n
$onClick = $cb.GetType().GetMethod('OnClick', [Reflection.BindingFlags]'NonPublic,Instance')   # what a mouse click raises
[void]$onClick.Invoke($cb, @([EventArgs]::Empty))
$out.afterClick = $cb.Checked; $out.eventsClick = $script:n
[void]$cb.Focus()
$WM_KEYDOWN = 0x100; $WM_KEYUP = 0x101; $VK_SPACE = [IntPtr]0x20
[void][CbTest.Win]::SendMessage($cb.Handle, $WM_KEYDOWN, $VK_SPACE, [IntPtr]0x00390001)
[void][CbTest.Win]::SendMessage($cb.Handle, $WM_KEYUP, $VK_SPACE, [IntPtr]([int]0xC0390001))
[System.Windows.Forms.Application]::DoEvents()
$out.afterSpace = $cb.Checked; $out.eventsSpace = $script:n
$f.Dispose()
$out | ConvertTo-Json -Compress
'@))
        $r.start | Should -BeFalse
        $r.afterSet | Should -BeTrue
        $r.eventsSet | Should -Be 1
        $r.afterClick | Should -BeFalse
        $r.eventsClick | Should -Be 2
        $r.afterSpace | Should -BeTrue -Because 'Space toggles a focused check box'
        $r.eventsSpace | Should -Be 3
    }
    It 'paints the box: Primary fill with a white mark when checked, a bordered empty box when not, and it keeps the text and focus behaviour' {
        $r = Get-LastJson (Invoke-ChildPs ($script:CbHead + @'
Set-QraEmulatedDpi 96
$f = New-Object System.Windows.Forms.Form; $f.ShowInTaskbar = $false; $f.Opacity = 0; $f.StartPosition = 'Manual'; $f.Location = New-Object System.Drawing.Point(-32000, -32000)
$f.BackColor = [System.Drawing.Color]::White
$cb = New-QraCheckBox 'Paint me'; $cb.SetBounds(0, 0, 200, 24); $cb.BackColor = $C.Card; $cb.ForeColor = $C.Text; $cb.Font = New-Font 10; $f.Controls.Add($cb)
$f.Show(); [System.Windows.Forms.Application]::DoEvents()
function Shot($c) { $b = New-Object System.Drawing.Bitmap($c.Width, $c.Height); $c.DrawToBitmap($b, (New-Object System.Drawing.Rectangle(0, 0, $c.Width, $c.Height))); $b }
function CountColor($b, [System.Drawing.Color]$col, [int]$x0, [int]$x1) { $n = 0; for ($x = $x0; $x -lt $x1; $x++) { for ($y = 0; $y -lt $b.Height; $y++) { $p = $b.GetPixel($x, $y); if ($p.R -eq $col.R -and $p.G -eq $col.G -and $p.B -eq $col.B) { $n++ } } }; $n }
$unchecked = Shot $cb; $cb.Checked = $true; $checked = Shot $cb
$prim = [System.Drawing.Color]::FromArgb(0, 103, 192)
$out = [ordered]@{ primUnchecked = (CountColor $unchecked $prim 0 16); primChecked = (CountColor $checked $prim 0 16); whiteInBox = (CountColor $checked ([System.Drawing.Color]::White) 3 13)
    textPixels = (CountColor $checked $C.Text 24 200) }
$out.focusable = $cb.CanFocus; $out.tabStop = $cb.TabStop
$cb.Enabled = $false; $dis = Shot $cb; $out.primDisabled = (CountColor $dis $prim 0 16)
$f.Dispose()
$out | ConvertTo-Json -Compress
'@))
        $r.primUnchecked | Should -Be 0
        $r.primChecked | Should -BeGreaterThan 100 -Because 'the checked box is filled with the Primary colour'
        $r.whiteInBox | Should -BeGreaterThan 3 -Because 'the check mark is white'
        $r.textPixels | Should -BeGreaterThan 20 -Because 'the text is drawn in ForeColor'
        $r.primDisabled | Should -Be 0 -Because 'a disabled box is muted, not Primary'
        $r.focusable | Should -BeTrue
        $r.tabStop | Should -BeTrue
    }
    It 'BoxSize, Gap, Radius and Stroke scale once with a DPI change, like the other kit metrics' {
        $r = Get-LastJson (Invoke-ChildPs ($script:CbHead + @'
Set-QraEmulatedDpi 96
$f = New-Object System.Windows.Forms.Form
$f.SuspendLayout(); Initialize-QraForm $f
$cb = New-QraCheckBox 'Scale me'; $cb.Font = New-Font 10; $f.Controls.Add($cb)
$f.ResumeLayout($false)
$null = Register-QraDpiWindow $f
$b = [ordered]@{ box = $cb.BoxSize; gap = $cb.Gap; radius = $cb.Radius; stroke = $cb.Stroke; ring = $cb.FocusRingWidth }
Invoke-QraDpiChange $f 120 $null
$m = [ordered]@{ box = $cb.BoxSize; gap = $cb.Gap; radius = $cb.Radius; stroke = $cb.Stroke; ring = $cb.FocusRingWidth; indent = (Get-QraCheckBoxIndent $cb) }
Invoke-QraDpiChange $f 120 $null
$again = $cb.BoxSize
Invoke-QraDpiChange $f 96 $null
$back = [ordered]@{ box = $cb.BoxSize; gap = $cb.Gap }
$fresh = $null
Set-QraEmulatedDpi 120; $fresh = (New-QraCheckBox 'x').BoxSize
[ordered]@{ err = $script:QraDpiLastError; before = $b; at120 = $m; again = $again; back = $back; fresh120 = $fresh } | ConvertTo-Json -Compress -Depth 4
'@))
        $r.err | Should -BeNullOrEmpty
        $r.before.box | Should -Be 16
        $r.at120.box | Should -Be 20
        $r.at120.gap | Should -Be 10
        $r.at120.radius | Should -Be 5
        $r.at120.indent | Should -Be 30
        $r.again | Should -Be 20 -Because 'the same DPI twice does nothing'
        $r.back.box | Should -Be 16
        $r.back.gap | Should -Be 8
        $r.fresh120 | Should -Be $r.at120.box -Because 'a control built at 120 dpi has the size a rescaled one has'
    }
    It 'the state image list has 2 images at S(16) (16 px at 100 %) and is rebuilt on a DPI change; CheckBoxes, ItemChecked and CheckedItems keep working' {
        $r = Get-LastJson (Invoke-ChildPs ($script:CbHead + @'
Set-QraEmulatedDpi 96
$f = New-Object System.Windows.Forms.Form; $f.ShowInTaskbar = $false; $f.Opacity = 0; $f.StartPosition = 'Manual'; $f.Location = New-Object System.Drawing.Point(-32000, -32000)
$lv = New-Object System.Windows.Forms.ListView; $lv.View = 'Details'; $lv.CheckBoxes = $true; $lv.Dock = 'Fill'
[void]$lv.Columns.Add('Name', 150)
$first = Set-QraListCheckImages $lv
$f.Controls.Add($lv)
$null = Register-QraDpiWindow $f -Relayout { param($ff) Set-QraListCheckImages $ff.Controls[0] | Out-Null }
$f.Show(); [System.Windows.Forms.Application]::DoEvents()
Invoke-QraDpiChange $f 96 $null   # the window may have opened on a screen with another scale: start from 100 %
$script:ev = 0; $lv.Add_ItemChecked({ $script:ev++ })
foreach ($n in 'a', 'b', 'c') { [void]$lv.Items.Add($n) }
$ev0 = $script:ev
$lv.Items[0].Checked = $true; $lv.Items[2].Checked = $true
$img1 = $lv.StateImageList
$out = [ordered]@{ first = $first; count1 = $img1.Images.Count; size1 = $img1.ImageSize.Width; depth = [string]$img1.ColorDepth; compat = $lv.UseCompatibleStateImageBehavior; checked1 = $lv.CheckedItems.Count; ev1 = ($script:ev - $ev0) }
$again = Set-QraListCheckImages $lv
$out.sameWhenSameSize = [object]::ReferenceEquals($img1, $lv.StateImageList)
Invoke-QraDpiChange $f 120 $null
$img2 = $lv.StateImageList
$out.rebuilt = -not [object]::ReferenceEquals($img1, $img2); $out.count2 = $img2.Images.Count; $out.size2 = $img2.ImageSize.Width
$out.checked2 = $lv.CheckedItems.Count; $out.keys2 = (@($lv.CheckedItems | ForEach-Object { $_.Text }) -join ',')
$ev2 = $script:ev; $lv.Items[1].Checked = $true; $out.checked3 = $lv.CheckedItems.Count; $out.ev3 = ($script:ev - $ev2)
$out.colText = $(try { $lv.Columns[0].Text = 'Renamed'; $lv.Columns[0].Text } catch { 'ERR ' + $_.Exception.Message })
# the painted images really differ (unchecked is not the checked one)
function Count($il, $i, [scriptblock]$test) { $b = $il.Images[$i]; $n = 0; for ($x = 3; $x -lt $b.Width - 3; $x++) { for ($y = 3; $y -lt $b.Height - 3; $y++) { if (& $test $b.GetPixel($x, $y)) { $n++ } } }; $n }
$out.uncheckedWhite = Count $img2 0 { param($p) $p.R -gt 240 -and $p.G -gt 240 -and $p.B -gt 240 }
$out.checkedPrimary = Count $img2 1 { param($p) $p.R -lt 40 -and $p.B -gt 150 }
$out.checkedWhite = Count $img2 1 { param($p) $p.R -gt 240 -and $p.G -gt 240 -and $p.B -gt 240 }
$out.uncheckedPrimary = Count $img2 0 { param($p) $p.R -lt 40 -and $p.B -gt 150 }
$f.Dispose()
$out | ConvertTo-Json -Compress
'@))
        $r.first | Should -BeTrue
        $r.count1 | Should -Be 2
        $r.size1 | Should -Be 16
        $r.depth | Should -Be 'Depth32Bit'
        $r.compat | Should -BeFalse
        $r.checked1 | Should -Be 2
        $r.ev1 | Should -Be 2
        $r.sameWhenSameSize | Should -BeTrue -Because 'no rebuild when the size is right'
        $r.rebuilt | Should -BeTrue
        $r.count2 | Should -Be 2
        $r.size2 | Should -Be 20
        $r.checked2 | Should -Be 2 -Because 'a rebuild keeps the ticks'
        $r.keys2 | Should -Be 'a,c'
        $r.checked3 | Should -Be 3
        $r.ev3 | Should -Be 1
        $r.colText | Should -Be 'Renamed'
        $r.uncheckedWhite | Should -BeGreaterThan 20 -Because 'the unchecked image is an empty light box'
        $r.uncheckedPrimary | Should -Be 0
        $r.checkedPrimary | Should -BeGreaterThan 20 -Because 'the checked image is filled with the Primary colour'
        $r.checkedWhite | Should -BeGreaterThan 3 -Because 'the mark is white'
    }
    It 'follows the kit rules: Theme colours (system colours in high contrast), GDI text, no scaling of its own, Update-QraControlMetrics case' {
        $t = [IO.File]::ReadAllText($script:KitPath)
        $t | Should -Match 'class CheckBox : System\.Windows\.Forms\.CheckBox'
        $t | Should -Match 'class CheckGlyph'
        $t | Should -Match "'QraUi\.CheckBox' \{"
        $cs = $t.Substring($t.IndexOf('public class CheckBox :'), 6000)
        $cs | Should -Match 'TextRenderer\.DrawText'
        $cs | Should -Match 'Theme\.Disabled'
        $cs | Should -Match 'ShowFocusCues'
        $glyph = $t.Substring($t.IndexOf('public static class CheckGlyph'), 3000)
        $glyph | Should -Match 'Theme\.HighContrast'
        $glyph | Should -Match 'Theme\.OnPrimary'
        $glyph | Should -Match 'Theme\.ControlBorder'
    }
}

Describe 'QraUi kit: sign-in window helpers (FindSignInFrames, BringToFront)' {
    BeforeAll {
        # A stand-in window in its own process (a plain WinForms form, so its class is not ApplicationFrameWindow): it writes its handle to a file and runs until the stop file exists.
        $script:SiDir = Join-Path ([IO.Path]::GetTempPath()) ('qra-signin-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:SiDir | Out-Null
        $standIn = @"
Add-Type -AssemblyName System.Windows.Forms
`$f = New-Object System.Windows.Forms.Form
`$f.Text = 'qra-standin'; `$f.StartPosition = 'Manual'; `$f.Location = New-Object System.Drawing.Point(40, 40); `$f.Size = New-Object System.Drawing.Size(300, 200)
`$f.Show()
[IO.File]::WriteAllText('$($script:SiDir)\handle.txt', [string]`$f.Handle.ToInt64())
`$end = [DateTime]::UtcNow.AddSeconds(120)
while (-not (Test-Path -LiteralPath '$($script:SiDir)\stop.txt') -and [DateTime]::UtcNow -lt `$end) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 30 }
"@
        $script:SiScript = Join-Path $script:SiDir 'standin.ps1'
        [IO.File]::WriteAllText($script:SiScript, $standIn, (New-Object Text.UTF8Encoding($true)))
        if (-not ([bool]$env:GITHUB_ACTIONS -or -not [Environment]::UserInteractive)) {
            $script:SiProc = Start-Process -FilePath powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:SiScript) -PassThru
            $deadline = [DateTime]::UtcNow.AddSeconds(30)
            while (-not (Test-Path -LiteralPath (Join-Path $script:SiDir 'handle.txt')) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
            Start-Sleep -Milliseconds 200
            $script:SiHandle = [int64](Get-Content -LiteralPath (Join-Path $script:SiDir 'handle.txt') -Raw)
        }
    }
    AfterAll {
        try { Set-Content -LiteralPath (Join-Path $script:SiDir 'stop.txt') -Value 'x' } catch { $null = $_ }
        try { if ($script:SiProc -and -not $script:SiProc.WaitForExit(5000)) { $script:SiProc.Kill() } } catch { $null = $_ }
        Remove-Item -LiteralPath $script:SiDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    It 'FindSignInFrames returns the handle of a window of a given broker pid (generic fallback) and nothing else' -Skip:([bool]$env:GITHUB_ACTIONS -or -not [Environment]::UserInteractive) {
        $r = Get-ChildJson (Invoke-ChildPs (@"
`$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. '$($script:KitPath)'
Add-Type -Namespace SiProbe -Name P -MemberDefinition '[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);'
`$mine = @([QraUi.Native]::FindSignInFrames([int[]]@($($script:SiProc.Id))) | ForEach-Object { [int64]`$_ })
`$foreign = 0
foreach (`$h in `$mine) { `$pp = [uint32]0; [void][SiProbe.P]::GetWindowThreadProcessId([IntPtr]`$h, [ref]`$pp); if (`$pp -ne $($script:SiProc.Id)) { `$foreign++ } }
`$none = @([QraUi.Native]::FindSignInFrames([int[]]@()))
`$nul = @([QraUi.Native]::FindSignInFrames(`$null))
`$zero = @([QraUi.Native]::FindSignInFrames([int[]]@(0)))
[ordered]@{ mine = `$mine; foreign = `$foreign; none = `$none.Count; nul = `$nul.Count; zero = `$zero.Count } | ConvertTo-Json -Compress
"@))
        @($r.mine) | Should -Contain $script:SiHandle
        $r.foreign | Should -Be 0 -Because 'only windows of the given pid come back'
        $r.none | Should -Be 0
        $r.nul | Should -Be 0
        $r.zero | Should -Be 0
    }
    It 'BringToFront makes a window of another process the foreground window' -Skip:([bool]$env:GITHUB_ACTIONS -or -not [Environment]::UserInteractive) {
        $r = Get-ChildJson (Invoke-ChildPs (@"
`$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. '$($script:KitPath)'
Add-Type -Namespace SiProbe -Name W -MemberDefinition '[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();'
# a cover window of this process is in front, so the stand-in is behind it
`$cover = New-Object System.Windows.Forms.Form
`$cover.StartPosition = 'Manual'; `$cover.Location = New-Object System.Drawing.Point(20, 20); `$cover.Size = New-Object System.Drawing.Size(500, 400)
`$cover.Show(); `$cover.Activate(); [System.Windows.Forms.Application]::DoEvents()
`$target = [IntPtr][int64]$($script:SiHandle)
`$before = [int64][SiProbe.W]::GetForegroundWindow()
`$ok = [QraUi.Native]::BringToFront(`$target)
[System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 200
`$after = [int64][SiProbe.W]::GetForegroundWindow()
`$bad = [QraUi.Native]::BringToFront([IntPtr]::Zero)
`$cover.Close()
[ordered]@{ ok = `$ok; before = `$before; after = `$after; bad = `$bad; coverHandleDiffers = (`$before -ne $($script:SiHandle)) } | ConvertTo-Json -Compress
"@))
        $r.bad | Should -BeFalse
        $r.coverHandleDiffers | Should -BeTrue
        [int64]$r.after | Should -Be $script:SiHandle
        $r.ok | Should -BeTrue
    }
    It 'uses Add-Type P/Invoke only (no Reflection.Emit) and never changes AllowSetForegroundWindow or TopMost for the sign-in helpers' {
        $t = [IO.File]::ReadAllText($script:KitPath)
        $start = $t.IndexOf('public static IntPtr[] FindSignInFrames'); $end = $t.IndexOf('public static int WindowDpi')
        $start | Should -BeGreaterThan 0
        $block = $t.Substring($start, $end - $start)
        $block | Should -Not -Match 'AllowSetForegroundWindow|TopMost|HWND_TOPMOST|Reflection\.Emit'
        $block | Should -Match 'AttachThreadInput'
        $block | Should -Match 'ApplicationFrameWindow'
        $block | Should -Match 'Windows\.UI\.Core\.CoreWindow'
    }
}
