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
        $QraGlyph.Keys.Count | Should -Be 13
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
    It 'New-Font multiplies the size by FontScale' {
        $script:FontScale = 2.0
        (New-Font 10).SizeInPoints | Should -Be 20
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
