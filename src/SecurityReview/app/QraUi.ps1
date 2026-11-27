# Quarantine Review Assistant - shared UI kit (dot-sourced by Launcher.ps1 and QuarantineReview.ps1).
# Load it with:  . (Join-Path $PSScriptRoot 'QraUi.ps1')   right after Add-Type -AssemblyName System.Drawing.
# Provides DPI helpers, design tokens, fonts, painted controls (C#, compiled once) with plain WinForms fallbacks,
# and a background-work helper. Windows PowerShell 5.1 (C# 5) compatible.

# ---- Language mode. Constrained Language Mode blocks Add-Type and most .NET calls: the kit must still load, just without painted controls.
$script:QraLanguageMode = [string]$ExecutionContext.SessionState.LanguageMode
function Get-QraCompileDecision([string]$mode = $script:QraLanguageMode) {
    if ($mode -eq 'FullLanguage') { 'compile' } else { 'skip' }
}
$script:QraDisplayReason = ''   # '', 'forced', 'language mode <mode>' or 'compile failed' (why the display is basic)
$script:UiNative = $false

# ---- High DPI. Declare awareness BEFORE any window exists, then scale by hand only what AutoScaleMode cannot.
# Rule (verified): controls that are in the form tree when ResumeLayout() runs are scaled by AutoScaleMode = Dpi,
# so they are written in plain 96-dpi pixels and must NOT be wrapped in S(). Everything else is scaled with S():
# list-view column widths, TabControl.Padding, TreeView.ItemHeight, and any control created or added after that point.
# Per-monitor mode (default, painted kit loaded): the process is per-monitor aware, a window is built at the DPI of the screen it opens on
# (Set-QraEmulatedDpi) and is rescaled live when it is dragged to another screen (Register-QraDpiWindow / Invoke-QraDpiChange).
# Fonts are then created in PIXELS (see New-Font): a point font is measured at the system DPI but drawn at the DPI of the window.
# QRA_DPI_MODE=system keeps the old system-aware behaviour (the Sandbox review window sets it). Constrained Language Mode and the
# plain fallback keep it as well: system-aware where code may be compiled, otherwise untouched, and never a live rescale.
$script:QraDpiMode = $(if ($env:QRA_DPI_MODE -eq 'system') { 'system' } else { 'permonitor' })
$script:QraAwareness = 'None'     # what Enable-QraDpiAwareness reached: PerMonitorV2, PerMonitor, System or None
$script:QraPerMonitor = $false    # true when the process is per-monitor aware and the painted kit is loaded (set once, after the compile below)
$script:QraDpiForms = @{}         # form -> @{ Dpi; Relayout; Tables; Watcher; Busy }
$script:QraDpiLastError = ''      # the last error of a live rescale (it is swallowed: the window keeps working)
$script:QraDpiBusy = 0            # > 0 while Invoke-QraDpiChange runs: layout code must not run then
function Set-QraProcessDpiV2 { try { [bool][QraUi.Native]::SetProcessV2() } catch { $false } }          # PER_MONITOR_AWARE_V2 (Windows 10 1703+)
function Set-QraProcessDpiShcore { try { [bool][QraUi.Native]::SetProcessShcore() } catch { $false } }  # per monitor (Windows 8.1+)
function Set-QraProcessDpiSystem {
    # The legacy call: system DPI aware. A new type name is used because QRA.Dpi may exist in a process with another signature.
    try {
        if (-not ('QRA.Dpi' -as [type])) {
            Add-Type -Namespace QRA -Name Dpi -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();' -ErrorAction Stop
        }
        [bool][QRA.Dpi]::SetProcessDPIAware()
    } catch { $false } # DPI awareness may already be set or unavailable
}
function Get-QraAwarenessLevel {
    # 0 unaware, 1 system, 2 per monitor, -1 unknown. Read back from Windows: the truth, whatever the calls above returned.
    try { [int][QraUi.Native]::AwarenessLevel() } catch { -1 }
}
function Enable-QraDpiAwareness {
    # Ordered fallback: PerMonitorV2, then per monitor (shcore), then system aware. Returns the step that worked: PerMonitorV2, PerMonitor, System or None.
    # Where compiling is not allowed (Constrained Language Mode) nothing is touched. The system-only mode and the plain fallback go straight to System.
    param([string]$Mode = $script:QraDpiMode)
    if ((Get-QraCompileDecision) -ne 'compile') { return 'None' }
    if ($Mode -ne 'system' -and $script:UiNative) {
        if (Set-QraProcessDpiV2) { return 'PerMonitorV2' }
        if (Set-QraProcessDpiShcore) { return 'PerMonitor' }
    }
    [void](Set-QraProcessDpiSystem)
    'System'
}
function Reset-QraScreenCache {
    # Screen.AllScreens is cached for the process: drop what was read before the awareness changed (virtualised bounds).
    try { [System.Windows.Forms.Screen].GetField('screens', [System.Reflection.BindingFlags]'NonPublic,Static').SetValue($null, $null) } catch { $null = $_ } # the cache simply stays
}
$script:DpiScale = 1.0
$script:FontScale = 1.0
$script:DesignDpi = [float]96
$script:DeviceDpi = 96.0
function S([double]$px) { [int][Math]::Round($px * $script:DpiScale) }
function SPad([int]$l, [int]$t, [int]$r, [int]$b) { New-Object System.Windows.Forms.Padding((S $l), (S $t), (S $r), (S $b)) }
function SSize([int]$w, [int]$h) { New-Object System.Drawing.Size((S $w), (S $h)) }
function SPoint([int]$x, [int]$y) { New-Object System.Drawing.Point((S $x), (S $y)) }
function Limit-FormToScreen($f, $Owner = $null) {
    # Never open larger than the usable screen (a 175 % display makes a 1320x860 design taller than 1080p). The screen is the form's own:
    # where its window is, else the owner's, else the one with the mouse (where CenterScreen opens it), else the one it overlaps.
    $scr = $null
    if ($script:QraPerMonitor) {
        try {
            if ($f.IsHandleCreated) { $scr = [System.Windows.Forms.Screen]::FromControl($f) }
            elseif ($Owner -and $Owner.IsHandleCreated) { $scr = [System.Windows.Forms.Screen]::FromControl($Owner) }
            elseif ([string]$f.StartPosition -eq 'CenterScreen') { $scr = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position) }
            else { $scr = [System.Windows.Forms.Screen]::FromRectangle($f.Bounds) }
        } catch { $scr = $null } # falls back to the primary screen
    }
    if (-not $scr) { $scr = [System.Windows.Forms.Screen]::PrimaryScreen }
    $wa = $scr.WorkingArea
    $f.MinimumSize = New-Object System.Drawing.Size([Math]::Min($f.MinimumSize.Width, $wa.Width), [Math]::Min($f.MinimumSize.Height, $wa.Height))
    $f.Size = New-Object System.Drawing.Size([Math]::Min($f.Width, $wa.Width), [Math]::Min($f.Height, $wa.Height))
}
function Set-Access($ctl, [string]$name, [string]$desc = '') { $ctl.AccessibleName = $name; if ($desc) { $ctl.AccessibleDescription = $desc } }
$script:WrapFlags = $null
try { $script:WrapFlags = [System.Windows.Forms.TextFormatFlags]::WordBreak -bor [System.Windows.Forms.TextFormatFlags]::NoPrefix } catch { $null = $_ } # falls back to plain TextRenderer defaults
function Measure-Wrapped([string]$text, $font, [int]$width) {
    [System.Windows.Forms.TextRenderer]::MeasureText($text, $font, (New-Object System.Drawing.Size([Math]::Max(10, $width), 0)), $script:WrapFlags).Height
}
function Initialize-QraForm($form) {
    # Call right after $form.SuspendLayout(). DesignDpi differs from 96 only while -ScreenshotDpi emulates another scale.
    $form.AutoScaleDimensions = New-Object System.Drawing.SizeF([float]$script:DesignDpi, [float]$script:DesignDpi)
    $form.AutoScaleMode = 'Dpi'
}
function Set-QraEmulatedDpi([int]$dpi) {
    # -ScreenshotDpi only: call before any window exists. DeviceDpi is the real DPI read by Graphics.FromHwnd.
    $script:DpiScale = $dpi / 96.0
    $script:FontScale = $dpi / $script:DeviceDpi
    $script:DesignDpi = [float](96 * $script:DeviceDpi / $dpi)
}

# ---- Per-monitor DPI: one stored DPI per window, a watcher for WM_DPICHANGED, and the live rescale.
function Get-QraWindowDpi($Form) {
    # The DPI Windows reports for a window; 0 when unknown (no handle yet, or Windows older than 10 1607).
    try { if ($Form -and $Form.IsHandleCreated) { return [int][QraUi.Native]::WindowDpi($Form.Handle) } } catch { $null = $_ } # unknown
    0
}
function Get-QraMonitorDpi($Point = $null) {
    # The DPI of the screen that holds $Point (default: the mouse). Where the process is not per-monitor aware: the one DPI it has (DeviceDpi).
    $fallback = [int][Math]::Round($script:DeviceDpi)
    if (-not $script:QraPerMonitor) { return $fallback }
    try {
        if ($null -eq $Point) { $Point = [System.Windows.Forms.Cursor]::Position }
        $dpi = [int][QraUi.Native]::MonitorDpi([int]$Point.X, [int]$Point.Y)
        if ($dpi -ge 48 -and $dpi -le 960) { return $dpi }
    } catch { $null = $_ } # falls back to the one DPI
    $fallback
}
function Use-QraFormDpi($Form) {
    # Makes the scale globals (S, New-Font, Initialize-QraForm) those of $Form. Call it first in every layout routine of a window, so that a window
    # on another screen never lays out with the scale of this one. A window that is not registered (system mode, fallback) leaves the globals alone.
    if ($null -eq $Form) { return }
    $st = $script:QraDpiForms[$Form]
    if ($st) { Set-QraEmulatedDpi ([int]$st.Dpi) }
}
function Get-QraFormDpi($Form) {
    # The DPI a registered window is currently scaled for; 0 when it is not registered.
    if ($null -eq $Form) { return 0 }
    $st = $script:QraDpiForms[$Form]
    if ($st) { [int]$st.Dpi } else { 0 }
}
function Add-QraFontTable($Form, [hashtable]$Table) {
    # A cached table of fonts (key -> Font) that must be rescaled together with the window, so that controls created later match.
    if ($null -eq $Form -or $null -eq $Table) { return }
    $st = $script:QraDpiForms[$Form]
    if ($st -and -not @($st.Tables).Where({ [object]::ReferenceEquals($_, $Table) })) { $st.Tables = @($st.Tables) + @($Table) }
}
function Unregister-QraDpiWindow($Form) {
    if ($null -ne $Form) { $script:QraDpiForms.Remove($Form) }
}
function Register-QraDpiWindow {
    # Makes $Form follow the screen it is on: its DPI is stored (default: the current scale), WM_DPICHANGED rescales it (Invoke-QraDpiChange) and
    # $Relayout runs once afterwards (called with the form as its only argument). A no-op (returns $false) unless the process is per-monitor aware
    # and the painted kit is loaded: the window then stays system-scaled, as before.
    param($Form, [scriptblock]$Relayout = $null, [int]$Dpi = 0, [hashtable[]]$FontTables = @())
    if (-not $script:QraPerMonitor -or -not $script:UiNative -or -not $Form) { return $false }
    if ($Dpi -le 0) { $Dpi = [int][Math]::Round($script:DpiScale * 96) }
    $st = @{ Dpi = $Dpi; Relayout = $Relayout; Tables = @($FontTables); Watcher = $null; Busy = $false; Missed = $false; Changes = 0; LastError = '' }
    try {
        $watcher = New-Object QraUi.DpiWatcher($Form)
        $watcher.add_DpiChanged({ param($s, $e) try { Invoke-QraDpiChange $s.Target $e.Dpi $e.Bounds } catch { $script:QraDpiLastError = $_.Exception.Message + ' ' + $_.InvocationInfo.PositionMessage } }) # never let an error reach the message loop
        $st.Watcher = $watcher
    } catch { return $false }
    $script:QraDpiForms[$Form] = $st
    $Form.Add_Shown({ param($s, $e) Resolve-QraDpiDrift $s })
    $Form.Add_Disposed({ param($s, $e) Unregister-QraDpiWindow $s })
    $true
}
function Resolve-QraDpiDrift($Form) {
    # The window opened on another screen than the one it was built for (a start position quirk, a screen that went away): rescale once from where it really is.
    try {
        $st = $script:QraDpiForms[$Form]
        if (-not $st) { return }
        $now = Get-QraWindowDpi $Form
        if ($now -gt 0 -and $now -ne $st.Dpi) { Invoke-QraDpiChange $Form $now $null }
    } catch { $null = $_ } # cosmetic: the window keeps its scale
}
function Get-QraControlList($Root) {
    # The control and everything below it, parents before children.
    $all = New-Object System.Collections.ArrayList
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($Root)
    while ($queue.Count -gt 0) {
        $c = $queue.Dequeue()
        [void]$all.Add($c)
        foreach ($kid in $c.Controls) { $queue.Enqueue($kid) }
    }
    $all.ToArray()
}
$script:QraFontProps = @{}
function Test-QraFontExplicit($Control) {
    # True when the control has its own Font; false when it inherits (ambient) the Font of its parent.
    try {
        $type = $Control.GetType()
        $prop = $script:QraFontProps[$type]
        if (-not $prop) { $prop = [System.ComponentModel.TypeDescriptor]::GetProperties($type)['Font']; $script:QraFontProps[$type] = $prop }
        [bool]$prop.ShouldSerializeValue($Control)
    } catch { $true }
}
function ConvertTo-QraScaledFont($Font, [double]$Ratio, [hashtable]$Map) {
    # One new font per distinct source font (family, size, style, unit), so a font shared by many controls is scaled once and stays shared.
    if ($null -eq $Font) { return $null }
    $key = '{0}|{1}|{2}|{3}' -f $Font.Name, $Font.Size, [int]$Font.Style, [int]$Font.Unit
    if (-not $Map.ContainsKey($key)) {
        $Map[$key] = New-Object System.Drawing.Font($Font.FontFamily, [single]($Font.Size * $Ratio), $Font.Style, $Font.Unit, $Font.GdiCharSet)
    }
    $Map[$key]
}
function Update-QraFonts {
    # Two passes: first every control's CURRENT font is recorded, then the fonts are assigned. A control that inherits its font follows its parent and is
    # not touched, so an ambient font is scaled once, not once for the parent and again for each child. Cached font tables get the same new fonts.
    param($Form, [double]$Ratio, [hashtable[]]$Tables = @(), [hashtable]$Map = $null)
    if ($null -eq $Map) { $Map = @{} }
    $all = @(Get-QraControlList $Form)
    $orig = @{}
    foreach ($c in $all) { $orig[$c] = $c.Font }
    foreach ($c in $all) {
        if (-not [object]::ReferenceEquals($c, $Form) -and -not (Test-QraFontExplicit $c)) { continue }
        $c.Font = ConvertTo-QraScaledFont $orig[$c] $Ratio $Map
    }
    foreach ($t in $Tables) {
        foreach ($key in @($t.Keys)) {
            if ($t[$key] -is [System.Drawing.Font]) { $t[$key] = ConvertTo-QraScaledFont $t[$key] $Ratio $Map }
        }
    }
}
function Update-QraControlMetrics {
    # What Form.Scale cannot reach: the radius, stroke, focus ring, shadow and arc thickness of the painted controls, their icon fonts, the
    # list-view column widths, the tree-view item height and the tab padding.
    param($Form, [double]$Ratio, [hashtable]$Map)
    foreach ($c in @(Get-QraControlList $Form)) {
        switch ($c.GetType().FullName) {
            'QraUi.RoundPanel' {
                $c.Radius = [int][Math]::Round($c.Radius * $Ratio); $c.ShadowSize = [int][Math]::Round($c.ShadowSize * $Ratio)
                $c.Stroke = [float][Math]::Max(1, [Math]::Round($c.Stroke * $Ratio))
            }
            'QraUi.ModernButton' {
                $c.Radius = [int][Math]::Round($c.Radius * $Ratio); $c.Stroke = [float][Math]::Max(1, [Math]::Round($c.Stroke * $Ratio))
                $c.FocusRingWidth = [float][Math]::Max(1, [Math]::Round($c.FocusRingWidth * $Ratio))
                if ($c.IconFont) { $c.IconFont = ConvertTo-QraScaledFont $c.IconFont $Ratio $Map }
            }
            'QraUi.Pill' {
                $c.Stroke = [float][Math]::Max(1, [Math]::Round($c.Stroke * $Ratio))
                if ($c.IconFont) { $c.IconFont = ConvertTo-QraScaledFont $c.IconFont $Ratio $Map }
            }
            'QraUi.Spinner' {
                $c.Thickness = [float]($c.Thickness * $Ratio)
                if ($c.IconFont) { $c.IconFont = ConvertTo-QraScaledFont $c.IconFont $Ratio $Map }
            }
            'QraUi.StepBadge' { if ($c.IconFont) { $c.IconFont = ConvertTo-QraScaledFont $c.IconFont $Ratio $Map } }
            'QraUi.CheckBox' {
                $c.BoxSize = [int][Math]::Max(8, [Math]::Round($c.BoxSize * $Ratio)); $c.Gap = [int][Math]::Round($c.Gap * $Ratio)
                $c.Radius = [int][Math]::Round($c.Radius * $Ratio); $c.Stroke = [float][Math]::Max(1, [Math]::Round($c.Stroke * $Ratio))
                $c.FocusRingWidth = [float][Math]::Max(1, [Math]::Round($c.FocusRingWidth * $Ratio))
            }
            'System.Windows.Forms.ListView' { foreach ($col in $c.Columns) { $col.Width = [int][Math]::Round($col.Width * $Ratio) } }
            'System.Windows.Forms.TreeView' { $c.ItemHeight = [int][Math]::Max(1, [Math]::Round($c.ItemHeight * $Ratio)) }
            'System.Windows.Forms.TabControl' { $c.Padding = New-Object System.Drawing.Point([int][Math]::Round($c.Padding.X * $Ratio), [int][Math]::Round($c.Padding.Y * $Ratio)) }
        }
    }
}
function Invoke-QraDpiChange {
    # WM_DPICHANGED for a registered window: scale everything by new/old (once), take the rectangle Windows suggests, run the window's relayout once.
    # $Rect may be $null (no suggestion: the size is only scaled). Safe to call twice with the same DPI: the second call does nothing.
    param($Form, [int]$NewDpi, $Rect = $null)
    if ($null -eq $Form -or $NewDpi -le 0) { return }
    $st = $script:QraDpiForms[$Form]
    if (-not $st -or $Form.IsDisposed) { return }
    if ($st.Busy) { $st.Missed = $true; return }   # a message that arrives while this window is being rescaled: checked again below
    $rounds = 0
    while ($rounds -lt 3) {
        $rounds++
        if ($NewDpi -eq $st.Dpi) { return }
        $ratio = $NewDpi / [double]$st.Dpi
        $st.Busy = $true; $script:QraDpiBusy++
        try {
            Set-QraEmulatedDpi $NewDpi
            $st.Dpi = $NewDpi
            $Form.SuspendLayout()
            try {
                $map = @{}
                Update-QraFonts $Form $ratio $st.Tables $map
                $Form.Scale((New-Object System.Drawing.SizeF([single]$ratio, [single]$ratio)))
                Update-QraControlMetrics $Form $ratio $map
                if ($Rect -and $Rect.Width -gt 0 -and $Rect.Height -gt 0 -and [string]$Form.WindowState -eq 'Normal') {
                    $Form.SetBounds([int]$Rect.X, [int]$Rect.Y, [int]$Rect.Width, [int]$Rect.Height)
                }
            } finally { $Form.ResumeLayout($true) }
            $st.Changes = [int]$st.Changes + 1
        } finally { $script:QraDpiBusy--; $st.Busy = $false }
        if ($st.Relayout) {
            try { & $st.Relayout $Form } catch { $st.LastError = $_.Exception.Message }
        }
        # A message arrived while this ran (the window crossed a screen edge again): follow where it really is, without a rectangle, until the stored DPI matches.
        if (-not $st.Missed) { return }
        $st.Missed = $false
        $actual = Get-QraWindowDpi $Form
        if ($actual -le 0 -or $actual -eq $st.Dpi) { return }
        $NewDpi = $actual; $Rect = $null
    }
}
function Hide-QraConsole {
    # Hides the console window of the launcher. Skipped silently where Add-Type is not allowed (Constrained Language Mode).
    # Start-Here.cmd starts PowerShell minimized (no console on screen). A minimized console must be restored first,
    # off-screen and without activation, before it is hidden: the Exchange Online sign-in window attaches to the console,
    # and Windows hides every window whose owner is minimized, so the sign-in would never appear.
    if ((Get-QraCompileDecision) -ne 'compile') { return }
    try {
        if (-not ('QRA.ConsoleWin' -as [type])) {
            Add-Type -Namespace QRA -Name ConsoleWin -MemberDefinition '[DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int n); [DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr h); [DllImport("user32.dll")] public static extern bool SetWindowPos(System.IntPtr h, System.IntPtr after, int x, int y, int cx, int cy, uint flags);' -ErrorAction Stop
        }
        $console = [QRA.ConsoleWin]::GetConsoleWindow()
        if ($console -eq [IntPtr]::Zero) { return }
        if ([QRA.ConsoleWin]::IsIconic($console)) {
            [void][QRA.ConsoleWin]::SetWindowPos($console, [IntPtr]::Zero, -32000, -32000, 0, 0, 0x0015)   # SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE
            [void][QRA.ConsoleWin]::ShowWindow($console, 4)   # SW_SHOWNOACTIVATE: restore from minimized, off-screen
        }
        [void][QRA.ConsoleWin]::ShowWindow($console, 0)   # SW_HIDE
    } catch { $null = $_ } # no console window to hide
}

# ---- Window helpers (taskbar identity, title bar colour, foreground). QRA.Win2 is a NEW type name: QRA.Win may already exist in a process with another signature.
$script:QraWin2Ready = $null
function Initialize-QraWin2 {
    # True when the native helpers are available. Skipped silently where Add-Type is not allowed (Constrained Language Mode).
    if ($null -ne $script:QraWin2Ready) { return [bool]$script:QraWin2Ready }
    $script:QraWin2Ready = $false
    if ((Get-QraCompileDecision) -ne 'compile') { return $false }
    try {
        if (-not ('QRA.Win2' -as [type])) {
            Add-Type -Namespace QRA -Name Win2 -ErrorAction Stop -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool AllowSetForegroundWindow(int pid);
[DllImport("user32.dll")] public static extern bool DestroyIcon(System.IntPtr h);
[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attr, ref int value, int size);
[DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern int SetCurrentProcessExplicitAppUserModelID(string appId);
'@
        }
        $script:QraWin2Ready = $true
    } catch { $script:QraWin2Ready = $false } # no native helpers: the window keeps its default icon grouping and title bar
    [bool]$script:QraWin2Ready
}
function Enable-QraForeground {
    # Lets any process (the Microsoft sign-in window, this window) come to the front after the console was hidden.
    if (-not (Initialize-QraWin2)) { return }
    try { [void][QRA.Win2]::AllowSetForegroundWindow(-1) } catch { $null = $_ } # best effort
}

# ---- Icon glyphs (identical in Segoe Fluent Icons and Segoe MDL2 Assets).
$QraGlyph = @{}
try {
    $QraGlyph = @{
        Check = [string][char]0xE73E; Cancel = [string][char]0xE711; Warning = [string][char]0xE7BA; Info = [string][char]0xE946
        Folder = [string][char]0xE838; Copy = [string][char]0xE8C8; Shield = [string][char]0xEA18; Play = [string][char]0xE768
        Clock = [string][char]0xE823; Mail = [string][char]0xE715; Delete = [string][char]0xE74D; Globe = [string][char]0xE774
        Refresh = [string][char]0xE72C; Link = [string][char]0xE71B
    }
} catch { $null = $_ } # glyph table stays empty if char conversion fails

# ---- High contrast and design tokens.
$script:QraHighContrast = $false
try { $script:QraHighContrast = [bool](([System.Windows.Forms.SystemInformation]::HighContrast) -or ($env:QRA_UI_HIGHCONTRAST -eq '1')) } catch { $null = $_ } # defaults to standard contrast
$C = @{}
try {
    $C = @{
        Surface       = [System.Drawing.Color]::FromArgb(247, 248, 250)
        Card          = [System.Drawing.Color]::FromArgb(255, 255, 255)
        Border        = [System.Drawing.Color]::FromArgb(229, 231, 235)   # decorative card border only
        ControlBorder = [System.Drawing.Color]::FromArgb(138, 145, 155)
        Text          = [System.Drawing.Color]::FromArgb(30, 35, 45)
        TextMuted     = [System.Drawing.Color]::FromArgb(95, 105, 120)
        Primary       = [System.Drawing.Color]::FromArgb(0, 103, 192)
        OnPrimary     = [System.Drawing.Color]::FromArgb(255, 255, 255)
        Success       = [System.Drawing.Color]::FromArgb(16, 124, 16)
        Warning       = [System.Drawing.Color]::FromArgb(150, 85, 0)
        Danger        = [System.Drawing.Color]::FromArgb(196, 43, 28)
        DangerSoft    = [System.Drawing.Color]::FromArgb(253, 240, 237)
        Info          = [System.Drawing.Color]::FromArgb(0, 95, 184)
        Focus         = [System.Drawing.Color]::FromArgb(17, 38, 66)
        Header        = [System.Drawing.Color]::FromArgb(17, 38, 66)
        HeaderEnd     = [System.Drawing.Color]::FromArgb(28, 56, 94)
        HeaderText    = [System.Drawing.Color]::FromArgb(255, 255, 255)
        HeaderSub     = [System.Drawing.Color]::FromArgb(170, 196, 224)
        Disabled      = [System.Drawing.Color]::FromArgb(160, 166, 175)
    }
    if ($script:QraHighContrast) {
        $C.Surface = [System.Drawing.SystemColors]::Window
        $C.Card = [System.Drawing.SystemColors]::Window
        $C.Text = [System.Drawing.SystemColors]::WindowText
        $C.TextMuted = [System.Drawing.SystemColors]::WindowText
        $C.Primary = [System.Drawing.SystemColors]::Highlight
        $C.OnPrimary = [System.Drawing.SystemColors]::HighlightText
        $C.Border = [System.Drawing.SystemColors]::WindowFrame
        $C.ControlBorder = [System.Drawing.SystemColors]::WindowFrame
        # Status colours keep their meaning through the icon and the word, so they all follow the user's theme colours.
        $C.Success = [System.Drawing.SystemColors]::WindowText
        $C.Warning = [System.Drawing.SystemColors]::WindowText
        $C.Danger = [System.Drawing.SystemColors]::WindowText
        $C.DangerSoft = [System.Drawing.SystemColors]::Window
        $C.Info = [System.Drawing.SystemColors]::Highlight
        $C.Focus = [System.Drawing.SystemColors]::Highlight
        $C.Disabled = [System.Drawing.SystemColors]::GrayText
    }
} catch { $null = $_ } # safe fallback in headless/non-WinForms contexts

# ---- Fonts
$script:QraFamilies = $null
function Get-QraFontFamilies {
    if (-not $script:QraFamilies) {
        $ifc = New-Object System.Drawing.Text.InstalledFontCollection
        $script:QraFamilies = @($ifc.Families | ForEach-Object { $_.Name })
    }
    $script:QraFamilies
}
function Resolve-QraFamily([string[]]$names) {
    # First installed family wins. QRA_UI_WIN10FONTS=1 skips the Windows 11 families (to preview a Windows 10 PC).
    $known = Get-QraFontFamilies
    foreach ($n in $names) { if ($known -contains $n) { return $n } }
    $names[$names.Count - 1]
}
function New-Font([float]$size = 9.5, [string]$style = 'Regular', [ValidateSet('Text', 'Display', 'Mono')][string]$role = 'Text') {
    if ($role -eq 'Mono') { $family = 'Consolas' }
    elseif ($env:QRA_UI_WIN10FONTS -eq '1') { $family = 'Segoe UI' }
    elseif ($role -eq 'Display') { $family = Resolve-QraFamily @('Segoe UI Variable Display', 'Segoe UI') }
    else { $family = Resolve-QraFamily @('Segoe UI Variable Text', 'Segoe UI') }
    New-QraFontObject $family $size $style
}
function New-QraFontObject([string]$family, [double]$size, [string]$style) {
    # Per-monitor mode: PIXEL fonts (points x 96/72 x scale), so measuring and drawing agree whatever screen the window is on.
    # Otherwise points scaled by FontScale, as before.
    if ($script:QraPerMonitor) { return (New-Object System.Drawing.Font($family, [float]($size * 96.0 / 72.0 * $script:DpiScale), [System.Drawing.FontStyle]$style, [System.Drawing.GraphicsUnit]::Pixel)) }
    New-Object System.Drawing.Font($family, [float]($size * $script:FontScale), [System.Drawing.FontStyle]$style)
}
function Get-IconFont([float]$size = 10) {
    if ($env:QRA_UI_WIN10FONTS -eq '1') { $family = 'Segoe MDL2 Assets' }
    else { $family = Resolve-QraFamily @('Segoe Fluent Icons', 'Segoe MDL2 Assets') }
    if ($script:UiNative) { try { [QraUi.Theme]::IconFamilyName = $family } catch { $null = $_ } } # optional theme icon override
    New-QraFontObject $family $size 'Regular'
}
function Get-QraStatusColor([ValidateSet('OK', 'WARN', 'FAIL', 'INFO')][string]$status) {
    switch ($status) { 'OK' { $C.Success } 'WARN' { $C.Warning } 'FAIL' { $C.Danger } default { $C.Info } }
}
function Get-QraContrast([System.Drawing.Color]$fg, [System.Drawing.Color]$bg) {
    # WCAG 2.x contrast ratio from relative luminance.
    $lum = {
        param([System.Drawing.Color]$col)
        $ch = @($col.R, $col.G, $col.B) | ForEach-Object {
            $v = $_ / 255.0
            if ($v -le 0.03928) { $v / 12.92 } else { [Math]::Pow(($v + 0.055) / 1.055, 2.4) }
        }
        0.2126 * $ch[0] + 0.7152 * $ch[1] + 0.0722 * $ch[2]
    }
    $l1 = & $lum $fg; $l2 = & $lum $bg
    ([Math]::Max($l1, $l2) + 0.05) / ([Math]::Min($l1, $l2) + 0.05)
}

# ---- App icon and window chrome (taskbar identity, title bar colour). No binary file: the icon is drawn at runtime.
function New-QraAppIconBitmap([int]$size = 32) {
    # Rounded square in the header navy with a white shield glyph, drawn at $size x $size pixels (32-bit, transparent corners). The caller disposes it.
    $size = [Math]::Max(16, $size)
    $bmp = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $fill = $null; $path = $null; $family = $null; $gf = $null; $white = $null; $sf = $null
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([System.Drawing.Color]::Transparent)
        $d = [single]($size * 0.46)   # corner diameter
        $r = New-Object System.Drawing.RectangleF(0, 0, ($size - 1), ($size - 1))
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $path.AddArc($r.X, $r.Y, $d, $d, 180, 90)
        $path.AddArc(($r.Right - $d), $r.Y, $d, $d, 270, 90)
        $path.AddArc(($r.Right - $d), ($r.Bottom - $d), $d, $d, 0, 90)
        $path.AddArc($r.X, ($r.Bottom - $d), $d, $d, 90, 90)
        $path.CloseFigure()
        $fill = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(17, 38, 66))   # the header navy ($C.Header, also in high contrast: an icon is not themed)
        $g.FillPath($fill, $path)
        $iconFont = Get-IconFont 10
        $family = $iconFont.FontFamily
        $gf = New-Object System.Drawing.Font($family, [single]($size * 0.62), [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
        $white = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
        $sf = New-Object System.Drawing.StringFormat([System.Drawing.StringFormat]::GenericTypographic)
        $sf.Alignment = [System.Drawing.StringAlignment]::Center; $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $g.DrawString([string]$QraGlyph.Shield, $gf, $white, (New-Object System.Drawing.RectangleF(0, 0, $size, $size)), $sf)
        $iconFont.Dispose()
    } finally {
        foreach ($res in @($sf, $white, $gf, $fill, $path)) { if ($res) { $res.Dispose() } }
        $g.Dispose()
    }
    $bmp
}
function New-QraAppIcon([int]$size = 32) {
    # The app icon as a System.Drawing.Icon that owns its own handle.
    $bmp = New-QraAppIconBitmap $size
    $hIcon = $bmp.GetHicon()
    try {
        $tmp = [System.Drawing.Icon]::FromHandle($hIcon)
        $icon = $tmp.Clone()   # the clone owns a copy, so the original handle can be destroyed
        $tmp.Dispose()
    } finally {
        if (Initialize-QraWin2) { try { [void][QRA.Win2]::DestroyIcon($hIcon) } catch { $null = $_ } } # without P/Invoke the handle is reclaimed at process exit
        $bmp.Dispose()
    }
    $icon
}

function Write-QraIcoFile {
    # Writes a multi-size .ico: ICONDIR, one ICONDIRENTRY per size, then the PNG-compressed images (Windows Vista and later read these).
    # A width or height of 256 is stored as 0. Needs System.Drawing, so it is skipped (returns $false) where Add-Type and .NET calls are not allowed.
    param([string]$Path, [int[]]$Sizes = @(16, 24, 32, 48, 64, 256))
    if ((Get-QraCompileDecision) -ne 'compile') { return $false }
    $Sizes = @($Sizes | ForEach-Object { [Math]::Min(256, [Math]::Max(16, $_)) })   # the icon drawing starts at 16 px
    $images = New-Object System.Collections.Generic.List[byte[]]
    foreach ($px in $Sizes) {
        $bmp = New-QraAppIconBitmap $px
        $mem = New-Object System.IO.MemoryStream
        try { $bmp.Save($mem, [System.Drawing.Imaging.ImageFormat]::Png); $images.Add($mem.ToArray()) } finally { $mem.Dispose(); $bmp.Dispose() }
    }
    $out = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($out)
    try {
        $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$Sizes.Count)   # ICONDIR: reserved, type 1 (icon), image count
        $offset = 6 + 16 * $Sizes.Count
        for ($i = 0; $i -lt $Sizes.Count; $i++) {
            $dim = if ($Sizes[$i] -ge 256) { [byte]0 } else { [byte]$Sizes[$i] }
            $bw.Write($dim); $bw.Write($dim); $bw.Write([byte]0); $bw.Write([byte]0)   # width, height, palette size, reserved
            $bw.Write([uint16]1); $bw.Write([uint16]32)                                 # colour planes, bits per pixel
            $bw.Write([uint32]$images[$i].Length); $bw.Write([uint32]$offset)           # image size, offset from the start of the file
            $offset += $images[$i].Length
        }
        foreach ($img in $images) { $bw.Write($img) }
        $bw.Flush()
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $tmpPath = $Path + '.tmp'
        [System.IO.File]::WriteAllBytes($tmpPath, $out.ToArray())
        Move-Item -LiteralPath $tmpPath -Destination $Path -Force
    } finally { $bw.Dispose(); $out.Dispose() }
    $true
}
function New-QraDesktopShortcut {
    # Creates a .lnk through the WScript.Shell COM object. Returns Status (Created, Replaced, Exists, Error), Path and Message; it never throws.
    # An existing shortcut is left alone unless -Force. Where COM or Add-Type is not allowed (Constrained Language Mode) the status is Error.
    param([string]$ShortcutPath, [string]$Target, [string]$WorkingDirectory, [string]$IconPath, [string]$Description = 'Quarantine Review Assistant - host launcher', [switch]$Force)
    $result = { param($status, $message) [pscustomobject]@{ Status = $status; Path = $ShortcutPath; Message = $message } }
    if ((Get-QraCompileDecision) -ne 'compile') { return (& $result 'Error' 'This PC restricts PowerShell (Constrained Language Mode), so a shortcut cannot be created from here.') }
    if (-not (Test-Path -LiteralPath $Target)) { return (& $result 'Error' "The launcher file was not found: $Target") }
    $existed = Test-Path -LiteralPath $ShortcutPath
    if ($existed -and -not $Force) { return (& $result 'Exists' 'A shortcut with this name already exists.') }
    $shell = $null; $link = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        $link = $shell.CreateShortcut($ShortcutPath)
        $link.TargetPath = $Target
        if ($WorkingDirectory) { $link.WorkingDirectory = $WorkingDirectory }
        if ($IconPath) { $link.IconLocation = "$IconPath,0" }
        $link.Description = $Description
        $link.WindowStyle = 7   # minimized: the little cmd window that starts the launcher does not flash
        $link.Save()
        return (& $result $(if ($existed) { 'Replaced' } else { 'Created' }) 'Shortcut saved.')
    } catch {
        return (& $result 'Error' $_.Exception.Message)
    } finally {
        foreach ($com in @($link, $shell)) { if ($com) { try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($com) } catch { $null = $_ } } }
    }
}

$script:QraAppIcon = $null
$script:QraAppIdSet = $false
function Set-QraWindowChrome {
    # Call right after creating a form (before it is shown). Sets the icon, the taskbar identity (once per process; the first call wins)
    # and, when the handle exists, the title bar colours (Windows 11 build 22000+; ignored elsewhere and in high contrast).
    param($form, [string]$AppId = 'QuarantineReviewAssistant.Launcher', [switch]$NoAppId)
    try {
        if (-not $script:QraAppIcon) { $script:QraAppIcon = New-QraAppIcon 32 }
        $form.Icon = $script:QraAppIcon
    } catch { $null = $_ } # keeps the default icon
    if (-not $NoAppId -and -not $script:QraAppIdSet -and (Initialize-QraWin2)) {
        $script:QraAppIdSet = $true
        try { [void][QRA.Win2]::SetCurrentProcessExplicitAppUserModelID($AppId) } catch { $null = $_ } # taskbar groups with PowerShell instead
    }
    if ($script:QraHighContrast) { return }
    try {
        $form.Add_HandleCreated({ param($s, $e) Set-QraCaptionColor $s })
        if ($form.IsHandleCreated) { Set-QraCaptionColor $form }
    } catch { $null = $_ } # default title bar
}
function Set-QraCaptionColor($form) {
    # DWMWA_CAPTION_COLOR (35) = header navy, DWMWA_TEXT_COLOR (36) = white; COLORREF is 0x00BBGGRR. Older Windows returns an error code: ignored.
    if ($script:QraHighContrast -or -not (Initialize-QraWin2)) { return }
    try {
        $caption = (66 -shl 16) -bor (38 -shl 8) -bor 17
        $text = 0x00FFFFFF
        [void][QRA.Win2]::DwmSetWindowAttribute($form.Handle, 35, [ref]$caption, 4)
        [void][QRA.Win2]::DwmSetWindowAttribute($form.Handle, 36, [ref]$text, 4)
    } catch { $null = $_ } # attributes exist only on Windows 11 22000 and later
}

# ---- Painted controls (C#, compiled once per process)
$script:QraSource = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace QraUi
{
    public enum StepState { Pending, Current, Working, Done, Warning, Blocked }
    public enum PillStatus { OK, WARN, FAIL, INFO, BUSY }
    public enum ButtonVariant { Primary, Secondary, Link, Danger }

    // Every painted type reads Theme, never SystemInformation. In high contrast: system colours, no shadow, no gradient.
    public static class Theme
    {
        public static bool HighContrast;
        public static string IconFamilyName;

        static Color Pick(Color normal, Color hc) { return HighContrast ? hc : normal; }
        public static Color Surface { get { return Pick(Color.FromArgb(247, 248, 250), SystemColors.Window); } }
        public static Color Card { get { return Pick(Color.FromArgb(255, 255, 255), SystemColors.Window); } }
        public static Color Border { get { return Pick(Color.FromArgb(229, 231, 235), SystemColors.WindowFrame); } }
        public static Color ControlBorder { get { return Pick(Color.FromArgb(138, 145, 155), SystemColors.WindowFrame); } }
        public static Color Text { get { return Pick(Color.FromArgb(30, 35, 45), SystemColors.WindowText); } }
        public static Color TextMuted { get { return Pick(Color.FromArgb(95, 105, 120), SystemColors.WindowText); } }
        public static Color Primary { get { return Pick(Color.FromArgb(0, 103, 192), SystemColors.Highlight); } }
        public static Color OnPrimary { get { return Pick(Color.FromArgb(255, 255, 255), SystemColors.HighlightText); } }
        public static Color Success { get { return Pick(Color.FromArgb(16, 124, 16), SystemColors.WindowText); } }
        public static Color Warning { get { return Pick(Color.FromArgb(150, 85, 0), SystemColors.WindowText); } }
        public static Color Danger { get { return Pick(Color.FromArgb(196, 43, 28), SystemColors.WindowText); } }
        public static Color Info { get { return Pick(Color.FromArgb(0, 95, 184), SystemColors.Highlight); } }
        public static Color Focus { get { return Pick(Color.FromArgb(17, 38, 66), SystemColors.Highlight); } }
        public static Color Disabled { get { return Pick(Color.FromArgb(160, 166, 175), SystemColors.GrayText); } }

        public const string Check = "";
        public const string Cancel = "";
        public const string Warn = "";
        public const string InfoGlyph = "";
        public const string Clock = "";

        public static Color Blend(Color a, Color b, float t)
        {
            return Color.FromArgb(
                (int)Math.Round(a.R + (b.R - a.R) * t),
                (int)Math.Round(a.G + (b.G - a.G) * t),
                (int)Math.Round(a.B + (b.B - a.B) * t));
        }

        // Adds delta (for example -0.08) to the HSL lightness of c.
        public static Color Lightness(Color c, float delta)
        {
            float h = c.GetHue(), s = c.GetSaturation(), l = c.GetBrightness();
            l = Math.Max(0f, Math.Min(1f, l + delta));
            float q = l < 0.5f ? l * (1f + s) : l + s - l * s;
            float p = 2f * l - q;
            float hk = h / 360f;
            return Color.FromArgb(c.A, Channel(p, q, hk + 1f / 3f), Channel(p, q, hk), Channel(p, q, hk - 1f / 3f));
        }
        static int Channel(float p, float q, float t)
        {
            if (t < 0f) t += 1f;
            if (t > 1f) t -= 1f;
            float v;
            if (t < 1f / 6f) v = p + (q - p) * 6f * t;
            else if (t < 0.5f) v = q;
            else if (t < 2f / 3f) v = p + (q - p) * (2f / 3f - t) * 6f;
            else v = p;
            return (int)Math.Round(Math.Max(0f, Math.Min(1f, v)) * 255f);
        }

        public static GraphicsPath RoundRect(RectangleF r, float radius)
        {
            GraphicsPath gp = new GraphicsPath();
            float rad = Math.Min(radius, Math.Min(r.Width, r.Height) / 2f);
            if (rad <= 0.5f) { gp.AddRectangle(r); return gp; }
            float d = rad * 2f;
            gp.AddArc(r.X, r.Y, d, d, 180, 90);
            gp.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            gp.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            gp.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            gp.CloseFigure();
            return gp;
        }

        public static FontFamily IconFamily(Font iconFont)
        {
            if (iconFont != null) return new FontFamily(iconFont.Name);
            string[] names = IconFamilyName != null
                ? new string[] { IconFamilyName }
                : new string[] { "Segoe Fluent Icons", "Segoe MDL2 Assets" };
            foreach (string n in names)
            {
                try { return new FontFamily(n); } catch (ArgumentException) { }
            }
            return FontFamily.GenericSansSerif;
        }

        // Draws one icon glyph centred in rect, with a font sized in pixels (the caller's geometry, already DPI correct).
        public static void DrawGlyph(Graphics g, string glyph, Font iconFont, float px, Color color, RectangleF rect)
        {
            using (FontFamily ff = IconFamily(iconFont))
            using (Font f = new Font(ff, Math.Max(6f, px), GraphicsUnit.Pixel))
            using (SolidBrush b = new SolidBrush(color))
            using (StringFormat sf = new StringFormat(StringFormat.GenericTypographic))
            {
                sf.Alignment = StringAlignment.Center;
                sf.LineAlignment = StringAlignment.Center;
                sf.FormatFlags |= StringFormatFlags.NoWrap;
                System.Drawing.Text.TextRenderingHint oldHint = g.TextRenderingHint;
                g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
                try { g.DrawString(glyph, f, b, rect, sf); }
                finally { g.TextRenderingHint = oldHint; }
            }
        }

        public static void DrawArc(Graphics g, RectangleF r, float angle, Color color, float thickness)
        {
            using (Pen p = new Pen(color, thickness))
            {
                p.StartCap = LineCap.Round;
                p.EndCap = LineCap.Round;
                g.DrawArc(p, r, angle, 270f);
            }
        }
    }

    // Base for painted controls: double buffered, owner drawn.
    public class PaintedControl : Control
    {
        public PaintedControl()
        {
            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
            SetStyle(ControlStyles.Selectable, false);
        }
        protected override void OnPaintBackground(PaintEventArgs e) { }
        protected Color ParentBack()
        {
            return Parent != null ? Parent.BackColor : Theme.Surface;
        }
    }

    public class RoundPanel : Panel
    {
        int radius = 8;
        int shadow = 3;
        float stroke = 1f;
        Color border = Color.Empty;
        Color fill = Color.Empty;

        public RoundPanel()
        {
            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
            BackColor = Theme.Card;
        }
        public int Radius { get { return radius; } set { radius = value; Invalidate(); } }
        public float Stroke { get { return stroke; } set { stroke = Math.Max(1f, value); Invalidate(); } }
        public int ShadowSize { get { return shadow; } set { shadow = value; PerformLayout(); Invalidate(); } }
        public Color BorderColor { get { return border.IsEmpty ? Theme.Border : border; } set { border = value; Invalidate(); } }
        public Color FillColor
        {
            get { return fill.IsEmpty ? Theme.Card : fill; }
            set { fill = value; BackColor = value; Invalidate(); }
        }
        // The card body is inset by the shadow, so docked children never overlap it.
        public override Rectangle DisplayRectangle
        {
            get
            {
                Rectangle r = base.DisplayRectangle;
                r.Inflate(-shadow, -shadow);
                return r;
            }
        }
        protected override void OnPaintBackground(PaintEventArgs e) { }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.Clear(Parent != null ? Parent.BackColor : Theme.Surface);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            RectangleF body = new RectangleF(shadow, shadow, Width - 2 * shadow - 1, Height - 2 * shadow - 1);
            if (!Theme.HighContrast && shadow > 0)
            {
                int[] alpha = new int[] { 6, 12, 18 };
                for (int i = 0; i < 3; i++)
                {
                    float grow = shadow * (3 - i) / 3f;
                    RectangleF r = new RectangleF(body.X - grow, body.Y - grow + 1f, body.Width + 2 * grow, body.Height + 2 * grow);
                    using (GraphicsPath gp = Theme.RoundRect(r, radius + grow))
                    using (SolidBrush sb = new SolidBrush(Color.FromArgb(alpha[i], 0, 0, 0)))
                        g.FillPath(sb, gp);
                }
            }
            using (GraphicsPath path = Theme.RoundRect(body, radius))
            {
                using (SolidBrush fb = new SolidBrush(FillColor)) g.FillPath(fb, path);
                using (Pen pen = new Pen(BorderColor, stroke)) g.DrawPath(pen, path);
            }
        }
    }

    // Antialiased arc spinner. One shared 33 ms timer ticks only while some spinner or working badge is visible.
    public class Spinner : PaintedControl
    {
        static readonly List<Control> animated = new List<Control>();
        static Timer tick;

        public static float Angle;

        public static void Register(Control c)
        {
            if (!animated.Contains(c)) animated.Add(c);
            if (!SystemInformation.UIEffectsEnabled) return;
            if (tick == null)
            {
                tick = new Timer();
                tick.Interval = 33;
                tick.Tick += OnTick;
            }
            if (!tick.Enabled) tick.Start();
        }
        public static void Unregister(Control c)
        {
            animated.Remove(c);
            if (animated.Count == 0 && tick != null) tick.Stop();
        }
        public static bool TimerRunning { get { return tick != null && tick.Enabled; } }
        static void OnTick(object sender, EventArgs e)
        {
            Angle = (Environment.TickCount % 1100) * 360f / 1100f;
            Control[] copy = animated.ToArray();
            foreach (Control c in copy)
            {
                if (c.IsDisposed) { animated.Remove(c); continue; }
                if (c.Visible && c.IsHandleCreated) c.Invalidate();
            }
            if (animated.Count == 0) tick.Stop();
        }

        bool active;
        bool shown;
        DateTime shownAt;
        Timer showTimer;
        Timer hideTimer;
        float thickness = 3f;
        Color arcColor = Color.Empty;
        string activity = "";

        public Spinner()
        {
            AccessibleRole = AccessibleRole.ProgressBar;
            Size = new Size(24, 24);
        }
        protected override Size DefaultSize { get { return new Size(24, 24); } }

        public float Thickness { get { return thickness; } set { thickness = value; Invalidate(); } }
        public Color ArcColor { get { return arcColor.IsEmpty ? Theme.Primary : arcColor; } set { arcColor = value; Invalidate(); } }
        public Font IconFont { get; set; }
        public bool IsShown { get { return shown; } }
        public string Activity
        {
            get { return activity; }
            set
            {
                string text = value ?? "";
                if (text == activity) return;
                activity = text;
                AccessibleName = activity;
                try { AccessibilityNotifyClients(AccessibleEvents.NameChange, -1); } catch (Exception) { }
            }
        }
        public bool Active
        {
            get { return active; }
            set
            {
                if (value == active) return;
                active = value;
                if (active)
                {
                    StopTimer(ref hideTimer);
                    if (shown) return;
                    StartTimer(ref showTimer, 300, delegate { StopTimer(ref showTimer); if (active) SetShown(true); });
                }
                else
                {
                    StopTimer(ref showTimer);
                    if (!shown) return;
                    double since = (DateTime.UtcNow - shownAt).TotalMilliseconds;
                    if (since >= 500) SetShown(false);
                    else StartTimer(ref hideTimer, (int)Math.Max(1, 500 - since), delegate { StopTimer(ref hideTimer); if (!active) SetShown(false); });
                }
            }
        }

        // Skips the 300 ms delay and paints one frame (screenshots only).
        public void ShowNow()
        {
            active = true;
            StopTimer(ref showTimer);
            StopTimer(ref hideTimer);
            SetShown(true);
            Invalidate();
            if (IsHandleCreated) Update();
        }

        void StartTimer(ref Timer t, int ms, EventHandler handler)
        {
            StopTimer(ref t);
            t = new Timer();
            t.Interval = ms;
            t.Tick += handler;
            t.Start();
        }
        static void StopTimer(ref Timer t)
        {
            if (t == null) return;
            t.Stop();
            t.Dispose();
            t = null;
        }
        void SetShown(bool v)
        {
            if (shown == v) return;
            shown = v;
            if (v) shownAt = DateTime.UtcNow;
            UpdateRegistration();
            Invalidate();
        }
        void UpdateRegistration()
        {
            if (shown && Visible) Register(this); else Unregister(this);
        }
        protected override void OnVisibleChanged(EventArgs e)
        {
            base.OnVisibleChanged(e);
            UpdateRegistration();
        }
        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                StopTimer(ref showTimer);
                StopTimer(ref hideTimer);
                Unregister(this);
            }
            base.Dispose(disposing);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.Clear(BackColor);
            if (!shown) return;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            float side = Math.Min(ClientSize.Width, ClientSize.Height);
            RectangleF box = new RectangleF((ClientSize.Width - side) / 2f, (ClientSize.Height - side) / 2f, side, side);
            if (!SystemInformation.UIEffectsEnabled)
            {
                Theme.DrawGlyph(g, Theme.Clock, IconFont, side * 0.8f, ArcColor, box);
                return;
            }
            float inset = thickness / 2f + 1f;
            RectangleF r = new RectangleF(box.X + inset, box.Y + inset, box.Width - 2 * inset, box.Height - 2 * inset);
            Theme.DrawArc(g, r, Angle, ArcColor, thickness);
        }
    }

    public class StepBadge : PaintedControl
    {
        int number = 1;
        StepState state = StepState.Pending;

        public StepBadge() { Size = new Size(28, 28); }
        protected override Size DefaultSize { get { return new Size(28, 28); } }

        public int Number { get { return number; } set { number = value; Invalidate(); } }
        public Font IconFont { get; set; }
        public StepState State
        {
            get { return state; }
            set { state = value; UpdateRegistration(); Invalidate(); }
        }
        void UpdateRegistration()
        {
            if (state == StepState.Working && Visible) Spinner.Register(this); else Spinner.Unregister(this);
        }
        protected override void OnVisibleChanged(EventArgs e)
        {
            base.OnVisibleChanged(e);
            UpdateRegistration();
        }
        protected override void Dispose(bool disposing)
        {
            if (disposing) Spinner.Unregister(this);
            base.Dispose(disposing);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.Clear(ParentBack());
            g.SmoothingMode = SmoothingMode.AntiAlias;
            float side = Math.Min(ClientSize.Width, ClientSize.Height);
            RectangleF box = new RectangleF((ClientSize.Width - side) / 2f, (ClientSize.Height - side) / 2f, side - 1f, side - 1f);
            float stroke = Math.Max(1.5f, side / 14f);
            Color fillColor = Color.Empty;
            Color ring = Color.Empty;
            Color mark = Theme.OnPrimary;
            string glyph = null;
            string bang = null;
            switch (state)
            {
                case StepState.Pending: ring = Theme.ControlBorder; mark = Theme.TextMuted; break;
                case StepState.Current: fillColor = Theme.Primary; break;
                case StepState.Working: ring = Theme.Border; break;
                case StepState.Done: fillColor = Theme.Success; glyph = Theme.Check; break;
                case StepState.Warning: fillColor = Theme.Warning; bang = "!"; break;
                default: fillColor = Theme.Danger; glyph = Theme.Cancel; break;
            }
            if (fillColor != Color.Empty)
                using (SolidBrush b = new SolidBrush(fillColor)) g.FillEllipse(b, box);
            if (ring != Color.Empty)
            {
                RectangleF rr = new RectangleF(box.X + stroke / 2f, box.Y + stroke / 2f, box.Width - stroke, box.Height - stroke);
                using (Pen p = new Pen(ring, stroke)) g.DrawEllipse(p, rr);
            }
            if (state == StepState.Working)
            {
                RectangleF ar = new RectangleF(box.X + stroke / 2f, box.Y + stroke / 2f, box.Width - stroke, box.Height - stroke);
                Theme.DrawArc(g, ar, Spinner.Angle, Theme.Primary, stroke);
                if (!SystemInformation.UIEffectsEnabled)
                    Theme.DrawGlyph(g, Theme.Clock, IconFont, side * 0.5f, Theme.Primary, box);
                return;
            }
            if (glyph != null) { Theme.DrawGlyph(g, glyph, IconFont, side * 0.46f, mark, box); return; }
            string text = bang != null ? bang : number.ToString();
            using (Font f = new Font(Font.FontFamily, Math.Max(6f, side * 0.42f), FontStyle.Bold, GraphicsUnit.Pixel))
            using (SolidBrush tb = new SolidBrush(mark))
            using (StringFormat sf = new StringFormat(StringFormat.GenericTypographic))
            {
                sf.Alignment = StringAlignment.Center;
                sf.LineAlignment = StringAlignment.Center;
                g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
                g.DrawString(text, f, tb, box, sf);
            }
        }
    }

    public class Pill : PaintedControl
    {
        PillStatus status = PillStatus.INFO;
        float stroke = 1f;

        public Pill()
        {
            AutoSize = true;
            Size = GetPreferredSize(Size.Empty);
        }
        public Font IconFont { get; set; }
        public float Stroke { get { return stroke; } set { stroke = Math.Max(1f, value); Invalidate(); } }
        public PillStatus Status { get { return status; } set { status = value; Refit(); } }
        public override string Text { get { return base.Text; } set { base.Text = value; Refit(); } }

        void Refit()
        {
            if (AutoSize) Size = GetPreferredSize(Size.Empty);
            Invalidate();
        }
        protected override void OnFontChanged(EventArgs e) { base.OnFontChanged(e); Refit(); }

        Color StatusColor()
        {
            switch (status)
            {
                case PillStatus.OK: return Theme.Success;
                case PillStatus.WARN: return Theme.Warning;
                case PillStatus.FAIL: return Theme.Danger;
                case PillStatus.BUSY: return Theme.Primary;
                default: return Theme.Info;
            }
        }
        string Glyph()
        {
            switch (status)
            {
                case PillStatus.OK: return Theme.Check;
                case PillStatus.WARN: return Theme.Warn;
                case PillStatus.FAIL: return Theme.Cancel;
                case PillStatus.BUSY: return Theme.Clock;
                default: return Theme.InfoGlyph;
            }
        }
        public override Size GetPreferredSize(Size proposedSize)
        {
            int fh = Font.Height;
            Size ts = TextRenderer.MeasureText(Text == null || Text.Length == 0 ? " " : Text, Font, new Size(int.MaxValue, 0),
                TextFormatFlags.NoPadding | TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix);
            int padH = (int)Math.Round(fh * 0.7);
            int padV = (int)Math.Round(fh * 0.3);
            int gap = (int)Math.Round(fh * 0.4);
            return new Size(padH + fh + gap + ts.Width + padH, fh + 2 * padV);
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.Clear(ParentBack());
            g.SmoothingMode = SmoothingMode.AntiAlias;
            Color sc = StatusColor();
            Color fillColor = Theme.HighContrast ? Theme.Card : Theme.Blend(sc, Color.White, 0.92f);
            Color edge = Theme.HighContrast ? Theme.Text : Theme.Blend(sc, Color.White, 0.55f);
            RectangleF r = new RectangleF(stroke / 2f, stroke / 2f, ClientSize.Width - stroke, ClientSize.Height - stroke);
            using (GraphicsPath gp = Theme.RoundRect(r, r.Height / 2f))
            {
                using (SolidBrush b = new SolidBrush(fillColor)) g.FillPath(b, gp);
                using (Pen p = new Pen(edge, stroke)) g.DrawPath(p, gp);
            }
            int fh = Font.Height;
            int padH = (int)Math.Round(fh * 0.7);
            int gap = (int)Math.Round(fh * 0.4);
            RectangleF gr = new RectangleF(padH, 0, fh, ClientSize.Height);
            Theme.DrawGlyph(g, Glyph(), IconFont, fh * 0.8f, sc, gr);
            Rectangle tr = new Rectangle(padH + fh + gap, 0, Math.Max(1, ClientSize.Width - padH * 2 - fh - gap + 2), ClientSize.Height);
            TextRenderer.DrawText(g, Text, Font, tr, sc,
                TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.NoPadding | TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix | TextFormatFlags.EndEllipsis);
        }
    }

    public class ModernButton : Button
    {
        ButtonVariant variant = ButtonVariant.Secondary;
        string glyph = "";
        int radius = 6;
        float stroke = 1f;
        float focusRing = 2f;
        float level;       // 0 normal, 1 hover, 2 pressed (animated)
        float target;
        int lastTick;
        Timer fade;
        bool inside;

        public ModernButton()
        {
            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
            FlatStyle = FlatStyle.Flat;
            UseVisualStyleBackColor = false;
            FlatAppearance.BorderSize = 0;
        }
        protected override Size DefaultSize { get { return new Size(110, 32); } }
        public ButtonVariant Variant { get { return variant; } set { variant = value; Invalidate(); } }
        public string Glyph { get { return glyph; } set { glyph = value ?? ""; Invalidate(); } }
        public Font IconFont { get; set; }
        public int Radius { get { return radius; } set { radius = value; Invalidate(); } }
        public float Stroke { get { return stroke; } set { stroke = Math.Max(1f, value); Invalidate(); } }
        public float FocusRingWidth { get { return focusRing; } set { focusRing = Math.Max(1f, value); Invalidate(); } }

        void SetTarget(float t)
        {
            target = t;
            if (!SystemInformation.UIEffectsEnabled || Theme.HighContrast || !IsHandleCreated) { level = t; Invalidate(); return; }
            if (fade == null)
            {
                fade = new Timer();
                fade.Interval = 16;
                fade.Tick += delegate
                {
                    int now = Environment.TickCount;
                    float step = (now - lastTick) / 120f;
                    lastTick = now;
                    if (level < target) level = Math.Min(target, level + step);
                    else if (level > target) level = Math.Max(target, level - step);
                    Invalidate();
                    if (level == target) fade.Stop();
                };
            }
            lastTick = Environment.TickCount;
            if (!fade.Enabled) fade.Start();
        }
        protected override void OnMouseEnter(EventArgs e) { inside = true; base.OnMouseEnter(e); SetTarget(1f); }
        protected override void OnMouseLeave(EventArgs e) { inside = false; base.OnMouseLeave(e); SetTarget(0f); }
        protected override void OnMouseDown(MouseEventArgs e) { base.OnMouseDown(e); SetTarget(2f); }
        protected override void OnMouseUp(MouseEventArgs e) { base.OnMouseUp(e); SetTarget(inside ? 1f : 0f); }
        protected override void OnEnabledChanged(EventArgs e) { base.OnEnabledChanged(e); Invalidate(); }
        protected override void OnGotFocus(EventArgs e) { base.OnGotFocus(e); Invalidate(); }
        protected override void OnLostFocus(EventArgs e) { base.OnLostFocus(e); Invalidate(); }
        protected override void OnTextChanged(EventArgs e) { base.OnTextChanged(e); Invalidate(); }
        protected override void Dispose(bool disposing)
        {
            if (disposing && fade != null) { fade.Stop(); fade.Dispose(); fade = null; }
            base.Dispose(disposing);
        }
        protected override void OnPaintBackground(PaintEventArgs e) { }

        Color Shade(Color c)
        {
            float delta = -0.08f * Math.Min(level, 1f) - 0.08f * Math.Max(level - 1f, 0f);
            return delta == 0f ? c : Theme.Lightness(c, delta);
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Parent != null ? Parent.BackColor : Theme.Surface);
            Color fillColor = Color.Empty, edge = Color.Empty, text;
            bool on = Enabled;
            switch (variant)
            {
                case ButtonVariant.Primary:
                    fillColor = on ? Shade(Theme.Primary) : Theme.Disabled;
                    text = Theme.OnPrimary;
                    break;
                case ButtonVariant.Link:
                    text = on ? Shade(Theme.Primary) : Theme.Disabled;
                    break;
                case ButtonVariant.Danger:
                    fillColor = Shade(Theme.Card);
                    edge = on ? Theme.Danger : Theme.Disabled;
                    text = on ? Theme.Danger : Theme.Disabled;
                    break;
                default:
                    fillColor = Shade(Theme.Card);
                    edge = on ? Theme.ControlBorder : Theme.Disabled;
                    text = on ? Theme.Text : Theme.Disabled;
                    break;
            }
            RectangleF r = new RectangleF(stroke / 2f, stroke / 2f, ClientSize.Width - stroke, ClientSize.Height - stroke);
            using (GraphicsPath gp = Theme.RoundRect(r, radius))
            {
                if (fillColor != Color.Empty) using (SolidBrush b = new SolidBrush(fillColor)) g.FillPath(b, gp);
                if (edge != Color.Empty) using (Pen p = new Pen(edge, stroke)) g.DrawPath(p, gp);
            }
            DrawContent(g, text);
            if (Focused && ShowFocusCues)
            {
                RectangleF fr = new RectangleF(focusRing / 2f, focusRing / 2f, ClientSize.Width - focusRing, ClientSize.Height - focusRing);
                using (GraphicsPath fp = Theme.RoundRect(fr, radius))
                using (Pen ring = new Pen(Theme.Focus, focusRing)) g.DrawPath(ring, fp);
            }
        }
        void DrawContent(Graphics g, Color text)
        {
            TextFormatFlags flags = TextFormatFlags.NoPadding | TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix | TextFormatFlags.EndEllipsis;
            Size ts = TextRenderer.MeasureText(Text, Font, new Size(int.MaxValue, 0), flags);
            int gw = 0, gap = 0;
            if (glyph.Length > 0) { gw = Font.Height; gap = (int)Math.Round(Font.Height * 0.4); }
            int total = gw + gap + ts.Width;
            int x = Math.Max(0, (ClientSize.Width - total) / 2);
            if (gw > 0) Theme.DrawGlyph(g, glyph, IconFont, gw * 0.85f, text, new RectangleF(x, 0, gw, ClientSize.Height));
            Rectangle tr = new Rectangle(x + gw + gap, 0, Math.Max(1, ClientSize.Width - x - gw - gap), ClientSize.Height);
            TextRenderer.DrawText(g, Text, Font, tr, text, flags | TextFormatFlags.VerticalCenter | TextFormatFlags.Left);
        }
    }

    // Glyph of the check box, shared by the QraUi.CheckBox control and the list-view state images, so that both look alike and scale alike.
    public static class CheckGlyph
    {
        static Color Shade(Color c, int level, float step)
        {
            if (Theme.HighContrast || level <= 0) return c;
            return Theme.Lightness(c, -step * Math.Min(level, 2));
        }

        // level: 0 normal, 1 hover, 2 pressed. The box is the exact pixel rectangle; the stroke runs inside it.
        public static void Draw(Graphics g, Rectangle box, CheckState state, int level, bool enabled, float radius, float stroke)
        {
            SmoothingMode oldMode = g.SmoothingMode;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            try
            {
                float st = Math.Max(1f, stroke);
                RectangleF r = new RectangleF(box.X + st / 2f, box.Y + st / 2f, box.Width - st, box.Height - st);
                bool on = state != CheckState.Unchecked;
                Color fill, edge;
                if (on)
                {
                    fill = enabled ? Shade(Theme.Primary, level, 0.06f) : Theme.Disabled;
                    edge = fill;
                }
                else
                {
                    fill = enabled ? Shade(Theme.Card, level, 0.04f) : Theme.Card;
                    edge = enabled ? Theme.ControlBorder : Theme.Disabled;
                }
                using (GraphicsPath gp = Theme.RoundRect(r, radius))
                {
                    using (SolidBrush b = new SolidBrush(fill)) g.FillPath(b, gp);
                    using (Pen p = new Pen(edge, st)) g.DrawPath(p, gp);
                }
                if (on)
                {
                    float s = box.Width;
                    using (Pen mark = new Pen(Theme.OnPrimary, Math.Max(1.5f, s * 0.105f)))
                    {
                        mark.StartCap = LineCap.Round;
                        mark.EndCap = LineCap.Round;
                        mark.LineJoin = LineJoin.Round;
                        if (state == CheckState.Checked)
                        {
                            g.DrawLines(mark, new PointF[] {
                                new PointF(box.X + s * 0.26f, box.Y + s * 0.53f),
                                new PointF(box.X + s * 0.43f, box.Y + s * 0.70f),
                                new PointF(box.X + s * 0.75f, box.Y + s * 0.32f) });
                        }
                        else
                        {
                            g.DrawLine(mark, box.X + s * 0.28f, box.Y + s * 0.5f, box.X + s * 0.72f, box.Y + s * 0.5f);
                        }
                    }
                }
            }
            finally { g.SmoothingMode = oldMode; }
        }

        // Two images for a list view's StateImageList: 0 = unchecked, 1 = checked, square, with an alpha channel.
        public static ImageList CreateStateImages(int size, float radius, float stroke)
        {
            ImageList il = new ImageList();
            il.ColorDepth = ColorDepth.Depth32Bit;
            il.ImageSize = new Size(size, size);
            IntPtr handle = il.Handle;   // creates the native list first: Add then copies each bitmap at once (before that it only keeps a reference to a bitmap that is disposed below)
            for (int i = 0; i < 2; i++)
            {
                using (Bitmap bmp = new Bitmap(size, size, System.Drawing.Imaging.PixelFormat.Format32bppArgb))
                using (Graphics g = Graphics.FromImage(bmp))
                {
                    g.Clear(Color.Transparent);
                    Draw(g, new Rectangle(0, 0, size, size), i == 0 ? CheckState.Unchecked : CheckState.Checked, 0, true, radius, stroke);
                    il.Images.Add(bmp);
                }
            }
            return il;
        }
    }

    // A painted, Windows 11 style check box. It keeps everything of System.Windows.Forms.CheckBox (Checked, CheckedChanged, Space, focus, accessibility)
    // and only draws itself: the box has a size in pixels that the caller scales (BoxSize), the text is GDI text like the rest of the kit.
    public class CheckBox : System.Windows.Forms.CheckBox
    {
        int boxSize = 16;
        int gap = 8;
        int radius = 4;
        float stroke = 1f;
        float focusRing = 2f;
        bool inside, down, keyDown;

        public CheckBox()
        {
            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
        }
        public int BoxSize { get { return boxSize; } set { boxSize = Math.Max(8, value); Invalidate(); PerformLayout(); } }
        public int Gap { get { return gap; } set { gap = Math.Max(0, value); Invalidate(); PerformLayout(); } }
        public int Radius { get { return radius; } set { radius = Math.Max(0, value); Invalidate(); } }
        public float Stroke { get { return stroke; } set { stroke = Math.Max(1f, value); Invalidate(); } }
        public float FocusRingWidth { get { return focusRing; } set { focusRing = Math.Max(1f, value); Invalidate(); } }
        // The width the box and the gap take before the text starts.
        public int TextIndent { get { return boxSize + gap; } }

        protected override Size DefaultSize { get { return new Size(160, 24); } }
        TextFormatFlags Flags()
        {
            TextFormatFlags f = TextFormatFlags.NoPadding | TextFormatFlags.Left | TextFormatFlags.Top | TextFormatFlags.WordBreak;
            if (!UseMnemonic) f |= TextFormatFlags.NoPrefix;
            else if (!ShowKeyboardCues) f |= TextFormatFlags.HidePrefix;
            return f;
        }
        public override Size GetPreferredSize(Size proposedSize)
        {
            int avail = (proposedSize.Width > 0 && proposedSize.Width < 32000) ? Math.Max(1, proposedSize.Width - TextIndent - Padding.Horizontal) : int.MaxValue;
            Size ts = string.IsNullOrEmpty(Text) ? Size.Empty : TextRenderer.MeasureText(Text, Font, new Size(avail, 0), Flags());
            int lineH = TextRenderer.MeasureText("Ag", Font, new Size(int.MaxValue, 0), TextFormatFlags.NoPadding | TextFormatFlags.SingleLine).Height;
            return new Size(TextIndent + ts.Width + Padding.Horizontal + 2, Math.Max(boxSize, Math.Max(ts.Height, lineH)) + Padding.Vertical + 4);
        }

        protected override void OnMouseEnter(EventArgs e) { inside = true; base.OnMouseEnter(e); Invalidate(); }
        protected override void OnMouseLeave(EventArgs e) { inside = false; down = false; base.OnMouseLeave(e); Invalidate(); }
        protected override void OnMouseDown(MouseEventArgs e) { if (e.Button == MouseButtons.Left) down = true; base.OnMouseDown(e); Invalidate(); }
        protected override void OnMouseUp(MouseEventArgs e) { down = false; base.OnMouseUp(e); Invalidate(); }
        protected override void OnKeyDown(KeyEventArgs e) { if (e.KeyCode == Keys.Space) keyDown = true; base.OnKeyDown(e); Invalidate(); }
        protected override void OnKeyUp(KeyEventArgs e) { keyDown = false; base.OnKeyUp(e); Invalidate(); }
        protected override void OnGotFocus(EventArgs e) { base.OnGotFocus(e); Invalidate(); }
        protected override void OnLostFocus(EventArgs e) { keyDown = false; down = false; base.OnLostFocus(e); Invalidate(); }
        protected override void OnEnabledChanged(EventArgs e) { base.OnEnabledChanged(e); Invalidate(); }
        protected override void OnTextChanged(EventArgs e) { base.OnTextChanged(e); Invalidate(); }
        protected override void OnForeColorChanged(EventArgs e) { base.OnForeColorChanged(e); Invalidate(); }
        protected override void OnCheckStateChanged(EventArgs e) { base.OnCheckStateChanged(e); Invalidate(); }
        protected override void OnPaintBackground(PaintEventArgs e) { }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            Color back = BackColor.A == 255 ? BackColor : (Parent != null ? Parent.BackColor : Theme.Card);
            g.Clear(back);
            bool on = Enabled;
            int indent = TextIndent;
            int avail = Math.Max(1, ClientSize.Width - indent);
            TextFormatFlags flags = Flags();
            Size ts = string.IsNullOrEmpty(Text) ? Size.Empty : TextRenderer.MeasureText(g, Text, Font, new Size(avail, 0), flags);
            int lineH = TextRenderer.MeasureText(g, "Ag", Font, new Size(int.MaxValue, 0), TextFormatFlags.NoPadding | TextFormatFlags.SingleLine).Height;
            int textH = Math.Max(ts.Height, lineH);
            int top = Math.Max(0, (ClientSize.Height - textH) / 2);
            int boxTop = Math.Max(0, top + (lineH - boxSize) / 2);
            int level = (down || keyDown) ? 2 : (inside ? 1 : 0);
            CheckGlyph.Draw(g, new Rectangle(0, boxTop, boxSize, boxSize), CheckState, on ? level : 0, on, radius, stroke);
            if (ts.Width > 0)
            {
                TextRenderer.DrawText(g, Text, Font, new Rectangle(indent, top, avail, textH), on ? ForeColor : Theme.Disabled, flags);
            }
            if (Focused && ShowFocusCues)
            {
                int w = Math.Min(ClientSize.Width, indent + ts.Width + (int)Math.Ceiling(focusRing) * 2);
                RectangleF fr = new RectangleF(focusRing / 2f, focusRing / 2f, w - focusRing, ClientSize.Height - focusRing);
                using (GraphicsPath fp = Theme.RoundRect(fr, radius + 1))
                using (Pen ring = new Pen(Theme.Focus, focusRing))
                {
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    g.DrawPath(ring, fp);
                }
            }
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    struct NativeRect { public int Left, Top, Right, Bottom; }

    // Thin wrappers over the DPI calls. Each one returns a plain value and never throws (a missing entry point on an older Windows gives false / 0 / -1).
    public static class Native
    {
        [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr value);
        [DllImport("user32.dll")] static extern IntPtr GetThreadDpiAwarenessContext();
        [DllImport("user32.dll")] static extern int GetAwarenessFromDpiAwarenessContext(IntPtr value);
        [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr hwnd);
        [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(NativePoint pt, uint flags);
        [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam);
        [DllImport("shcore.dll")] static extern int GetDpiForMonitor(IntPtr monitor, int type, out uint dpiX, out uint dpiY);
        [DllImport("shcore.dll")] static extern int SetProcessDpiAwareness(int value);
        [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr hwnd);
        [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr hwnd, IntPtr dc);
        [DllImport("gdi32.dll")] static extern int GetDeviceCaps(IntPtr dc, int index);

        [StructLayout(LayoutKind.Sequential)]
        struct NativePoint { public int X; public int Y; }

        // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 is -4.
        public static bool SetProcessV2()
        {
            try { return SetProcessDpiAwarenessContext(new IntPtr(-4)); } catch (Exception) { return false; }
        }
        // PROCESS_PER_MONITOR_DPI_AWARE is 2; S_OK is 0.
        public static bool SetProcessShcore()
        {
            try { return SetProcessDpiAwareness(2) == 0; } catch (Exception) { return false; }
        }
        // 0 unaware, 1 system aware, 2 per monitor aware, -1 unknown.
        public static int AwarenessLevel()
        {
            try { return GetAwarenessFromDpiAwarenessContext(GetThreadDpiAwarenessContext()); } catch (Exception) { return -1; }
        }
        // LOGPIXELSX of the screen DC: the DPI WinForms compares AutoScaleDimensions with. 0 when unknown.
        public static int DeviceDpi()
        {
            try
            {
                IntPtr dc = GetDC(IntPtr.Zero);
                if (dc == IntPtr.Zero) return 0;
                try { return GetDeviceCaps(dc, 88); } finally { ReleaseDC(IntPtr.Zero, dc); }
            }
            catch (Exception) { return 0; }
        }
        // ---- Bringing a foreign sign-in window forward (the Exchange Online sign-in is a WAM window that can open behind the dialog).
        delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
        [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr lParam);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd, System.Text.StringBuilder sb, int max);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
        [DllImport("user32.dll")] static extern bool IsIconic(IntPtr hwnd);
        [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hwnd, int cmd);
        [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hwnd);
        [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr hwnd);
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool attach);
        [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();

        static string ClassOf(IntPtr hwnd)
        {
            System.Text.StringBuilder sb = new System.Text.StringBuilder(256);
            return GetClassName(hwnd, sb, sb.Capacity) > 0 ? sb.ToString() : "";
        }
        static uint PidOf(IntPtr hwnd)
        {
            uint pid;
            GetWindowThreadProcessId(hwnd, out pid);
            return pid;
        }

        // The top-level windows that hold a sign-in: an ApplicationFrameWindow with a Windows.UI.Core.CoreWindow child of one of the broker processes,
        // and (fallback) any visible top-level window that belongs to a broker process. Empty on any failure.
        public static IntPtr[] FindSignInFrames(int[] brokerPids)
        {
            List<IntPtr> found = new List<IntPtr>();
            try
            {
                if (brokerPids == null || brokerPids.Length == 0) return found.ToArray();
                HashSet<uint> pids = new HashSet<uint>();
                foreach (int p in brokerPids) pids.Add((uint)p);
                EnumProc top = delegate(IntPtr hwnd, IntPtr lp)
                {
                    try
                    {
                        if (!IsWindowVisible(hwnd)) return true;
                        if (pids.Contains(PidOf(hwnd))) { found.Add(hwnd); return true; }
                        if (ClassOf(hwnd) != "ApplicationFrameWindow") return true;
                        bool hit = false;
                        EnumProc child = delegate(IntPtr ch, IntPtr lp2)
                        {
                            if (pids.Contains(PidOf(ch)) && ClassOf(ch) == "Windows.UI.Core.CoreWindow") { hit = true; return false; }
                            return true;
                        };
                        EnumChildWindows(hwnd, child, IntPtr.Zero);
                        if (hit) found.Add(hwnd);
                    }
                    catch (Exception) { }
                    return true;
                };
                EnumWindows(top, IntPtr.Zero);
            }
            catch (Exception) { }
            return found.ToArray();
        }

        // Restores the window when minimized, then makes it the foreground window; when Windows refuses, borrows the input queue of the
        // current foreground window (the documented AttachThreadInput fallback). True when the window is the foreground window afterwards.
        public static bool BringToFront(IntPtr hwnd)
        {
            try
            {
                if (hwnd == IntPtr.Zero) return false;
                if (IsIconic(hwnd)) ShowWindow(hwnd, 9);   // SW_RESTORE
                if (SetForegroundWindow(hwnd)) return true;
                IntPtr fg = GetForegroundWindow();
                uint fgThread = fg == IntPtr.Zero ? 0 : GetWindowThreadProcessId(fg, out _unusedPid);
                uint me = GetCurrentThreadId();
                bool attached = false;
                try
                {
                    if (fgThread != 0 && fgThread != me) attached = AttachThreadInput(me, fgThread, true);
                    BringWindowToTop(hwnd);
                    SetForegroundWindow(hwnd);
                }
                finally { if (attached) AttachThreadInput(me, fgThread, false); }
                return GetForegroundWindow() == hwnd;
            }
            catch (Exception) { return false; }
        }
        [ThreadStatic] static uint _unusedPid;

        public static int WindowDpi(IntPtr hwnd)
        {
            try { return (int)GetDpiForWindow(hwnd); } catch (Exception) { return 0; }
        }
        // The effective DPI of the monitor that holds (x, y), or the nearest one; 0 when unknown.
        public static int MonitorDpi(int x, int y)
        {
            try
            {
                NativePoint p = new NativePoint();
                p.X = x; p.Y = y;
                IntPtr mon = MonitorFromPoint(p, 2);   // MONITOR_DEFAULTTONEAREST
                uint dx, dy;
                if (mon != IntPtr.Zero && GetDpiForMonitor(mon, 0, out dx, out dy) == 0) return (int)dx;   // MDT_EFFECTIVE_DPI
            }
            catch (Exception) { }
            return 0;
        }
        // Delivers a WM_DPICHANGED to a window, as Windows does when it is dragged to another monitor (tests).
        public static void SendDpiChanged(IntPtr hwnd, int dpi, int left, int top, int right, int bottom)
        {
            NativeRect rc = new NativeRect();
            rc.Left = left; rc.Top = top; rc.Right = right; rc.Bottom = bottom;
            IntPtr mem = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(NativeRect)));
            try
            {
                Marshal.StructureToPtr(rc, mem, false);
                SendMessage(hwnd, 0x02E0, new IntPtr(dpi | (dpi << 16)), mem);
            }
            finally { Marshal.FreeHGlobal(mem); }
        }
    }

    public class DpiChangedEventArgs : EventArgs
    {
        readonly int dpi;
        readonly Rectangle bounds;
        public DpiChangedEventArgs(int dpi, Rectangle bounds) { this.dpi = dpi; this.bounds = bounds; }
        public int Dpi { get { return dpi; } }
        public Rectangle Bounds { get { return bounds; } }
    }

    // Listens to WM_DPICHANGED of one form (the form does nothing with it by itself): LOWORD(wParam) is the new DPI, lParam the rectangle Windows suggests.
    // It follows the form's handle, so it keeps working when the handle is recreated.
    public class DpiWatcher : NativeWindow
    {
        readonly Form target;
        int count;
        public event EventHandler<DpiChangedEventArgs> DpiChanged;

        public DpiWatcher(Form form)
        {
            target = form;
            form.HandleCreated += delegate { Attach(); };
            form.HandleDestroyed += delegate { if (Handle != IntPtr.Zero) ReleaseHandle(); };
            if (form.IsHandleCreated) Attach();
        }
        public Form Target { get { return target; } }
        public int Count { get { return count; } }

        void Attach()
        {
            if (Handle == target.Handle) return;
            if (Handle != IntPtr.Zero) ReleaseHandle();
            AssignHandle(target.Handle);
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == 0x02E0)
            {
                int dpi = (int)((long)m.WParam & 0xFFFF);
                Rectangle r = Rectangle.Empty;
                if (m.LParam != IntPtr.Zero)
                {
                    NativeRect rc = (NativeRect)Marshal.PtrToStructure(m.LParam, typeof(NativeRect));
                    r = Rectangle.FromLTRB(rc.Left, rc.Top, rc.Right, rc.Bottom);
                }
                count++;
                EventHandler<DpiChangedEventArgs> handler = DpiChanged;
                if (handler != null)
                {
                    try { handler(this, new DpiChangedEventArgs(dpi, r)); } catch (Exception) { }
                }
            }
            base.WndProc(ref m);
        }
    }
}
'@

function Get-QraGlyphText([string]$kind) {
    # Plain-text status marks for the fallback labels (the icon font is only used by the painted controls).
    switch ($kind) {
        'OK' { [string][char]0x2713 } 'WARN' { '!' } 'FAIL' { [string][char]0x2715 } 'INFO' { 'i' } default { [string][char]0x2026 }
    }
}

if ((Get-QraCompileDecision) -ne 'compile') {
    $script:QraDisplayReason = "language mode $($script:QraLanguageMode)"
} elseif ($env:QRA_UI_FALLBACK -eq '1') {
    $script:QraDisplayReason = 'forced'
} else {
    try {
        # Compile at most once per process: a second dot-source reuses the type.
        if (-not ('QraUi.Spinner' -as [type])) {
            Add-Type -TypeDefinition $script:QraSource -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing' -ErrorAction Stop
        }
        [QraUi.Theme]::HighContrast = $script:QraHighContrast
        $script:UiNative = $true
    } catch {
        $script:UiNative = $false
        $script:QraDisplayReason = 'compile failed'
    }
}

# ---- Declare the DPI awareness now (the native helpers are compiled; no window of this thread exists yet), then read the DPI Windows reports.
$script:QraAwareness = Enable-QraDpiAwareness
if ($script:QraAwareness -ne 'None') { Reset-QraScreenCache }
$script:QraPerMonitor = ($script:QraDpiMode -ne 'system') -and $script:UiNative -and ((Get-QraAwarenessLevel) -eq 2)
# The DPI is read from the screen DC itself, as WinForms does for AutoScaleMode = Dpi. Graphics.FromHwnd(0).DpiX is GDI+'s copy, taken the first time any
# thread used GDI+: the launcher's splash thread does that before this process is DPI aware, so it would still say 96 on a 125 % PC.
$nativeDpi = 0
if ($script:UiNative) { try { $nativeDpi = [int][QraUi.Native]::DeviceDpi() } catch { $nativeDpi = 0 } } # falls back to GDI+ below
if ($nativeDpi -ge 96) { $script:DeviceDpi = [double]$nativeDpi; $script:DpiScale = [Math]::Max(1.0, $nativeDpi / 96.0) }
else { try { $g0 = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $script:DeviceDpi = [double]$g0.DpiX; $script:DpiScale = [Math]::Max(1.0, $g0.DpiX / 96); $g0.Dispose() } catch { $null = $_ } } # defaults to 96 DPI (scale 1.0)

# ---- Control factories (native C# type when $script:UiNative, else a plain WinForms control with today's look)
function New-QraCard {
    if ($script:UiNative) {
        $p = New-Object QraUi.RoundPanel
        $p.Radius = S 8
        $p.ShadowSize = S 3
        $p.Stroke = [float](S 1)
        $p.BorderColor = $C.Border
        $p.FillColor = $C.Card
        return $p
    }
    $p = New-Object System.Windows.Forms.Panel
    $p.BackColor = $C.Card
    $p
}
function New-QraSpinner([int]$diameter = 24) {
    if ($script:UiNative) {
        $s = New-Object QraUi.Spinner
        $s.Size = New-Object System.Drawing.Size($diameter, $diameter)
        $s.Thickness = [float](S ([Math]::Max(2, [Math]::Round($diameter / 8.0))))
        $s.ArcColor = $C.Primary
        $s.IconFont = Get-IconFont 10
        $s.BackColor = $C.Card
        return $s
    }
    $s = New-Object System.Windows.Forms.Label
    $s.AutoSize = $false
    $s.Size = New-Object System.Drawing.Size(([Math]::Max($diameter, 24)), $diameter)
    $s.TextAlign = 'MiddleCenter'
    $s.Font = New-Font 12 'Bold'   # the dots are tiny in the body font
    $s.ForeColor = $C.Primary
    $s.Text = ''
    $s.AccessibleRole = 'ProgressBar'
    $s.Tag = $null
    $s
}
function New-QraStepBadge([int]$number = 1) {
    if ($script:UiNative) {
        $b = New-Object QraUi.StepBadge
        $b.Number = $number
        $b.IconFont = Get-IconFont 11
        return $b
    }
    $b = New-Object System.Windows.Forms.Label
    $b.AutoSize = $false
    $b.Size = New-Object System.Drawing.Size(28, 28)
    $b.TextAlign = 'MiddleCenter'
    $b.Font = New-Font 10 'Bold'
    $b.Tag = $number
    Set-QraBadgeState $b 'Pending'
    $b
}
function New-QraPill([string]$status = 'INFO', [string]$text = '') {
    if ($script:UiNative) {
        $p = New-Object QraUi.Pill
        $p.Stroke = [float](S 1)
        $p.IconFont = Get-IconFont 10
        Set-QraPill $p $status $text
        return $p
    }
    $p = New-Object System.Windows.Forms.Label
    $p.AutoSize = $true
    $p.Font = New-Font 9.5 'Bold'
    Set-QraPill $p $status $text
    $p
}
function New-QraButton([string]$text, [ValidateSet('Primary', 'Secondary', 'Link', 'Danger')][string]$variant = 'Secondary', [string]$glyph = '') {
    if ($script:UiNative) {
        $b = New-Object QraUi.ModernButton
        $b.Text = $text
        $b.Variant = [QraUi.ButtonVariant]$variant
        $b.Glyph = $glyph
        $b.Radius = S 6
        $b.Stroke = [float](S 1)
        $b.FocusRingWidth = [float](S 2)
        $b.IconFont = Get-IconFont 10
        return $b
    }
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    if ($variant -eq 'Primary') {
        $b.FlatStyle = 'Flat'
        $b.FlatAppearance.BorderSize = 0
        $b.BackColor = $C.Primary
        $b.ForeColor = $C.OnPrimary
        $b.Font = New-Font 9.5 'Bold'
        $b.Add_GotFocus({ $this.FlatAppearance.BorderColor = $C.Focus; $this.FlatAppearance.BorderSize = (S 3) })
        $b.Add_LostFocus({ $this.FlatAppearance.BorderSize = 0 })
    } else {
        $b.FlatStyle = 'Standard'
        $b.UseVisualStyleBackColor = $true
        if ($variant -eq 'Danger') { $b.ForeColor = $C.Danger }
        elseif ($variant -eq 'Link') { $b.ForeColor = $C.Primary }
    }
    $b
}

function New-QraCheckBox([string]$text = '', [int]$box = 16) {
    # A painted Windows 11 style check box (QraUi.CheckBox: a box of $box px at 100 %, scaled with the window). Without the painted kit: the plain WinForms CheckBox.
    # It is still a CheckBox: Checked, CheckedChanged, Enabled, ForeColor and the Space key work the same. Callers set Font, BackColor, bounds and TabIndex.
    if ($script:UiNative) {
        $cb = New-Object QraUi.CheckBox
        $cb.Text = $text
        $cb.BoxSize = S $box
        $cb.Gap = S 8
        $cb.Radius = S 4
        $cb.Stroke = [float](S 1)
        $cb.FocusRingWidth = [float](S 2)
        return $cb
    }
    $cb = New-Object System.Windows.Forms.CheckBox
    $cb.Text = $text
    $cb
}
function Get-QraCheckBoxIndent($CheckBox) {
    # The width a check box takes before its text (the box and the gap); the plain CheckBox needs about 24 px at 100 %.
    if ($CheckBox -and $CheckBox.GetType().FullName -eq 'QraUi.CheckBox') { return [int]$CheckBox.TextIndent }
    S 24
}
function Set-QraListCheckImages($ListView) {
    # The row check boxes of a list view (CheckBoxes = $true) get the same painted look: a StateImageList with two images (unchecked, checked) at 16 px
    # of the current scale. Call it again after a DPI change; it does nothing when the images already have the right size, and nothing without the painted kit.
    if (-not $script:UiNative -or $null -eq $ListView) { return $false }
    $size = [int](S 16)
    # Without this the list view ignores the state images for its row check boxes; it can only be set before the window handle exists (call this right after creating the list view).
    if (-not $ListView.IsHandleCreated -and $ListView.UseCompatibleStateImageBehavior) { $ListView.UseCompatibleStateImageBehavior = $false }
    $old = $ListView.StateImageList
    if ($old -and $old.ImageSize.Width -eq $size) { return $true }
    $ListView.StateImageList = [QraUi.CheckGlyph]::CreateStateImages($size, [float](S 4), [float](S 1))
    if ($old) { try { $old.Dispose() } catch { $null = $_ } } # the list view has the new images by now
    $true
}

# ---- State setters
function Set-QraBadgeState($badge, [ValidateSet('Pending', 'Current', 'Working', 'Done', 'Warning', 'Blocked')][string]$state) {
    if ($badge.GetType().FullName -eq 'QraUi.StepBadge') { $badge.State = [QraUi.StepState]$state; return }
    switch ($state) {
        'Pending' { $badge.Text = [string]$badge.Tag; $badge.ForeColor = $C.TextMuted; $badge.BackColor = $C.Surface }
        'Current' { $badge.Text = [string]$badge.Tag; $badge.ForeColor = $C.OnPrimary; $badge.BackColor = $C.Primary }
        'Working' { $badge.Text = [string][char]0x2026; $badge.ForeColor = $C.Primary; $badge.BackColor = $C.Surface }
        'Done' { $badge.Text = [string][char]0x2713; $badge.ForeColor = $C.OnPrimary; $badge.BackColor = $C.Success }
        'Warning' { $badge.Text = '!'; $badge.ForeColor = $C.OnPrimary; $badge.BackColor = $C.Warning }
        'Blocked' { $badge.Text = [string][char]0x2715; $badge.ForeColor = $C.OnPrimary; $badge.BackColor = $C.Danger }
    }
}
function Set-QraPill($pill, [string]$status, [string]$text) {
    if ($pill.GetType().FullName -eq 'QraUi.Pill') {
        $pill.Status = [QraUi.PillStatus]$status
        $pill.Text = $text
        return
    }
    $pill.Text = "$(Get-QraGlyphText $status) $text"
    $pill.ForeColor = switch ($status) { 'OK' { $C.Success } 'WARN' { $C.Warning } 'FAIL' { $C.Danger } 'BUSY' { $C.Primary } default { $C.Info } }
}
function Set-QraSpinner($spinner, [bool]$active, [string]$activity) {
    if ($spinner.GetType().FullName -eq 'QraUi.Spinner') {
        $spinner.Activity = $activity
        $spinner.Active = $active
        return
    }
    # Fallback label: the text cycles . .. ... on a 400 ms timer while active.
    $spinner.AccessibleName = $activity
    if ($active) {
        if (-not $spinner.Tag) {
            $t = New-Object System.Windows.Forms.Timer
            $t.Interval = 400
            $lbl = $spinner
            $dots = [string][char]0x00B7
            $t.Add_Tick({ $n = ($lbl.Text.Length % 3) + 1; $lbl.Text = $dots * $n }.GetNewClosure())
            $lbl.Add_Disposed({ $t.Stop(); $t.Dispose() }.GetNewClosure())
            $spinner.Tag = $t
        }
        $spinner.Text = [string][char]0x00B7
        $spinner.Tag.Start()
    } else {
        if ($spinner.Tag) { $spinner.Tag.Stop() }
        $spinner.Text = ''
    }
}
$script:QraCopied = @{}
function Show-QraCopied($button, [string]$doneText = 'Copied') {
    # Shows a check mark and $doneText for 2 s, then restores the original text (and icon).
    $key = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($button)
    $native = ($button.GetType().FullName -eq 'QraUi.ModernButton')
    $copied = $script:QraCopied   # captured: GetNewClosure() rebinds $script: to a dynamic module where it is null
    if ($copied.ContainsKey($key)) {
        $state = $copied[$key]
        $state.Timer.Stop(); $state.Timer.Start()
    } else {
        $state = @{ Text = $button.Text; Glyph = $(if ($native) { $button.Glyph } else { '' }) }
        $t = New-Object System.Windows.Forms.Timer
        $t.Interval = 2000
        $state.Timer = $t
        $copied[$key] = $state
        $t.Add_Tick({
                $t.Stop()
                if (-not $button.IsDisposed) {
                    $button.Text = $state.Text
                    if ($native) { $button.Glyph = $state.Glyph }
                }
                $copied.Remove($key)
                $t.Dispose()
            }.GetNewClosure())
        $t.Start()
    }
    if ($native) { $button.Glyph = $QraGlyph.Check; $button.Text = $doneText }
    else { $button.Text = ([string][char]0x2713) + ' ' + $doneText }
}

# ---- Background work (a runspace, not Start-Job: a job takes 1-2 s to start in Windows PowerShell 5.1)
function Start-QraWork([scriptblock]$Script, [hashtable]$Variables = @{}, [string[]]$Functions = @()) {
    $state = [hashtable]::Synchronized(@{})
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $iss.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry('State', $state, 'Shared progress state')))
    foreach ($k in $Variables.Keys) {
        $iss.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry([string]$k, $Variables[$k], '')))
    }
    foreach ($fn in $Functions) {
        $body = (Get-Item -LiteralPath "function:$fn").ScriptBlock.ToString()
        $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry($fn, $body)))
    }
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($iss)
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($Script.ToString())
    $handle = $ps.BeginInvoke()
    [pscustomobject]@{ PowerShell = $ps; Handle = $handle; State = $state; Started = [DateTime]::UtcNow; Disposed = $false; Result = $null }
}
function Test-QraWork($work) { [bool]($work.Disposed -or $work.Handle.IsCompleted) }
function Remove-QraWorkRunspace($work) {
    if ($work.Disposed) { return }
    $work.Disposed = $true
    $rs = $work.PowerShell.Runspace
    try { $work.PowerShell.Dispose() } catch { $null = $_ } # best-effort runspace cleanup
    try { $rs.Dispose() } catch { $null = $_ } # best-effort runspace cleanup
}
function Complete-QraWork($work) {
    if ($work.Result) { return $work.Result }
    $out = @(); $err = $null
    try {
        $out = @($work.PowerShell.EndInvoke($work.Handle))
    } catch {
        $e = $_.Exception
        while ($e.InnerException) { $e = $e.InnerException }
        $err = $e.Message
    }
    if (-not $err -and $work.PowerShell.Streams.Error.Count -gt 0) { $err = [string]$work.PowerShell.Streams.Error[0] }
    Remove-QraWorkRunspace $work
    $work.Result = [pscustomobject]@{ Output = $out; Error = $err }
    $work.Result
}
function Stop-QraWork($work) {
    if ($work.Disposed) { return }
    try {
        $stopped = $work.PowerShell.BeginStop($null, $null)
        [void]$stopped.AsyncWaitHandle.WaitOne(1500)
    } catch { $null = $_ } # stop wait best-effort before disposing runspace
    Remove-QraWorkRunspace $work
}
