# Quarantine Review Assistant v2 - HOST launcher.
# Checks that this PC can run Windows Sandbox, prepares the portable Python runtime,
# guides the Defender download, and launches the isolated review session.
# It hashes opaque package bytes on the host. Extraction and message parsing run in the Sandbox.
param([switch]$NoGui, [string]$Screenshot, [int]$ScreenshotDpi = 0, [switch]$ScreenshotMinSize, [string]$ScreenshotSize)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
# Labels, check boxes and buttons draw their text with GDI (TextRenderer, crisp ClearType) instead of the .NET Framework default GDI+,
# which looked thin and grey next to the kit's own painted text. Only allowed before the first control exists, so it runs first.
try { [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false) } catch { $null = $_ } # too late if a control already exists: keep the default
$AppVersion   = '2.3.1'   # read by the start-up splash, so it is set before anything else

# ---------------------------------------------------------------- start-up: single instance, then a splash while the window is built
# Only for a real GUI run (not -Screenshot, -NoGui or inside the Sandbox). Plain WinForms and .NET only: nothing here needs Add-Type or the UI kit,
# so the splash is on screen before the slow part (loading the kit and building the form) starts.
$script:LauncherMutex = $null
$script:Splash = $null          # the plain fallback splash (a form on this thread)
$script:SplashState = $null     # shared with the animated splash thread: Close, Ready, Failed, Status, Frame, Progress
$script:SplashPs = $null; $script:SplashRs = $null; $script:SplashAsync = $null
$startGui = (-not $Screenshot) -and (-not $NoGui) -and ($env:USERNAME -ne 'WDAGUtilityAccount')

# The few native calls the splash needs (compiled with Add-Type inside the splash runspace, namespace QraSplash so it never clashes with the kit's QraUi.Native).
# If the compile is refused (Constrained Language Mode, AppLocker, a compiler error) the splash simply stays DPI-unaware, as in v2.3.0.
$script:LauncherSplashNativeSource = @'
[DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
[DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(long point, uint flags);
[DllImport("shcore.dll")] static extern int GetDpiForMonitor(IntPtr monitor, int type, out uint dpiX, out uint dpiY);
public static bool SetThreadPerMonitorV2() { try { return SetThreadDpiAwarenessContext(new IntPtr(-4)) != IntPtr.Zero; } catch (Exception) { return false; } }
public static int MonitorDpi(int x, int y)
{
    try
    {
        IntPtr mon = MonitorFromPoint(((long)y << 32) | (uint)x, 2);
        uint dx, dy;
        if (mon != IntPtr.Zero && GetDpiForMonitor(mon, 0, out dx, out dy) == 0) return (int)dx;
    }
    catch (Exception) { }
    return 0;
}
'@

# The animated splash. It runs on its OWN STA thread (a runspace with its own message loop), because the launcher thread is busy for a couple of seconds
# (compile, build the form) and pumps no messages: an animation on that thread would freeze. Plain WinForms and GDI+; the only native code is one small guarded Add-Type (QraSplash.Native) for the screen's DPI.
# With $state.Shot set it renders one frame (progress frozen) to that PNG on the calling thread and returns: that is the review screenshot.
$script:LauncherSplashBlock = {
    param($state)
    $ErrorActionPreference = 'Stop'
    $shot = [string]$state.Shot
    $ui = @{ Frame = 0; Fading = 0; Closing = $false; CloseAt = 0; LastStatus = '' }
    $win = $null; $timer = $null
    try {
        # This thread is per-monitor aware BEFORE anything draws (GDI+ takes its DPI from its first use: a stale 96 would leak into the launcher's text),
        # and the window is sized for the screen with the mouse: 640 x 357 at 96 dpi, more pixels on a denser screen, never stretched by Windows.
        $dpi = [int]$state.Dpi   # only the review picture sets it (QRA_SPLASH_DPI): it then draws at that scale without asking Windows
        $nt = $false
        if ($dpi -le 0 -and -not $shot -and $state.NativeSource) {
            try {
                if (-not ('QraSplash.Native' -as [type])) { Add-Type -Namespace QraSplash -Name Native -MemberDefinition ([string]$state.NativeSource) -ErrorAction Stop }
                $nt = [bool][QraSplash.Native]::SetThreadPerMonitorV2()
            } catch { $nt = $false } # no per-monitor awareness here: today's splash
        }
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $dr = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        if ($dpi -le 0) {
            $dpi = 96
            if ($nt) {
                try {
                    $mp = [System.Windows.Forms.Cursor]::Position
                    $md = [QraSplash.Native]::MonitorDpi([int]$mp.X, [int]$mp.Y)
                    if ($md -ge 96 -and $md -le 960) { $dpi = $md }
                    else { $gs = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $dpi = [int]$gs.DpiX; $gs.Dispose() }
                } catch { $dpi = 96 }
            }
        }
        $sc = $dpi / 96.0
        $px = { param([double]$n) [int][Math]::Round($n * $sc) }
        $ui.W = & $px 640; $ui.H = & $px 357
        $navy = [System.Drawing.Color]::FromArgb(17, 38, 66)
        $win = New-Object System.Windows.Forms.Form
        $win.AutoScaleMode = 'None'; $win.FormBorderStyle = 'None'; $win.ShowInTaskbar = $false; $win.TopMost = $true; $win.StartPosition = 'Manual'
        $win.BackColor = $navy; $win.ClientSize = New-Object System.Drawing.Size($ui.W, $ui.H)
        $win.Text = 'Quarantine Review Assistant'
        $win.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic').SetValue($win, $true, $null)
        $area = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).WorkingArea   # the screen with the mouse
        $win.Location = New-Object System.Drawing.Point(($area.Left + [int](($area.Width - $win.Width) / 2)), ($area.Top + [int](($area.Height - $win.Height) / 2)))
        if (-not $shot) { $win.Opacity = 0 }
        # The window exists from the next line on (hidden, opacity 0): the launcher may go on and declare DPI awareness while the picture is prepared.
        $win.Add_HandleCreated({ $state.Ready = $true }.GetNewClosure())
        if (-not $shot) { [void]$win.Handle }

        # A family that is not installed throws: that is the cheap way to ask (listing all families is slow).
        $hasFont = { param($n) try { (New-Object System.Drawing.FontFamily($n)).Dispose(); $true } catch { $false } }
        $titleName = 'Segoe UI'; $titleStyle = [System.Drawing.FontStyle]::Bold
        if (& $hasFont 'Segoe UI Variable Display Semib') { $titleName = 'Segoe UI Variable Display Semib'; $titleStyle = [System.Drawing.FontStyle]::Regular }
        elseif (& $hasFont 'Segoe UI Semibold') { $titleName = 'Segoe UI Semibold'; $titleStyle = [System.Drawing.FontStyle]::Regular }
        $bodyName = if (& $hasFont 'Segoe UI Variable Text') { 'Segoe UI Variable Text' } else { 'Segoe UI' }
        $fTitle = New-Object System.Drawing.Font($titleName, [single](20 * 96 / 72 * $sc), $titleStyle, [System.Drawing.GraphicsUnit]::Pixel)   # 20 pt and 10 pt, in pixels at this scale
        $fBody = New-Object System.Drawing.Font($bodyName, [single](10 * 96 / 72 * $sc), [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
        $ui.FBody = $fBody

        # The picture is shipped at twice the window size and scaled down once, with the best filter, into a cache that every repaint copies from.
        $cache = New-Object System.Drawing.Bitmap($ui.W, $ui.H, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
        $gc = [System.Drawing.Graphics]::FromImage($cache)
        $hasImage = $false
        try {
            $gc.Clear($navy)
            $gc.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $gc.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $gc.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $gc.CompositingQuality = $dr
            $imgPath = [string]$state.Image
            if ($imgPath -and (Test-Path -LiteralPath $imgPath)) {
                $ms = New-Object System.IO.MemoryStream(, [System.IO.File]::ReadAllBytes($imgPath))
                try {
                    $src = [System.Drawing.Image]::FromStream($ms)
                    try {
                        $attr = New-Object System.Drawing.Imaging.ImageAttributes
                        $attr.SetWrapMode([System.Drawing.Drawing2D.WrapMode]::TileFlipXY)
                        $gc.DrawImage($src, (New-Object System.Drawing.Rectangle(0, 0, $ui.W, $ui.H)), 0, 0, $src.Width, $src.Height, [System.Drawing.GraphicsUnit]::Pixel, $attr)
                        $attr.Dispose()
                        $hasImage = $true
                    } finally { $src.Dispose() }
                } finally { $ms.Dispose() }
            }
        } catch { $hasImage = $false; $gc.Clear($navy) }   # missing or unreadable picture: plain navy, same text, same animation

        # Layout: the picture keeps its shield on the left, so the text sits in the empty right part (or the whole width without a picture).
        $ui.TextX = if ($hasImage) { & $px 372 } else { & $px 40 }
        $ui.TextW = $ui.W - $ui.TextX - (& $px 40)
        $white = [System.Drawing.Brushes]::White
        $muted = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(170, 196, 224))
        $sf = New-Object System.Drawing.StringFormat([System.Drawing.StringFormat]::GenericDefault)
        $sf.Trimming = [System.Drawing.StringTrimming]::None
        $gc.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
        $title = 'Quarantine Review Assistant'
        $titleH = [Math]::Ceiling($gc.MeasureString($title, $fTitle, $ui.TextW, $sf).Height)
        $verH = [Math]::Ceiling($fBody.GetHeight($gc))
        $gap = & $px 10
        $blockH = $titleH + $gap + $verH
        $top = [Math]::Round((& $px 158) - $blockH / 2)
        $gc.DrawString($title, $fTitle, $white, (New-Object System.Drawing.RectangleF($ui.TextX, $top, $ui.TextW, ($titleH + 4))), $sf)
        $gc.DrawString(('Version ' + [string]$state.Version), $fBody, $muted, (New-Object System.Drawing.RectangleF($ui.TextX, ($top + $titleH + $gap), $ui.TextW, ($verH + 4))), $sf)
        # 1 px border (one physical pixel per 100 % of scale)
        $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(42, 74, 117), [single][Math]::Max(1, [Math]::Floor($sc)))
        $gc.DrawRectangle($pen, 0, 0, ($ui.W - 1), ($ui.H - 1))
        $pen.Dispose(); $muted.Dispose(); $sf.Dispose(); $gc.Dispose(); $fTitle.Dispose()
        $ui.Cache = $cache
        $ui.StatusRect = New-Object System.Drawing.Rectangle(($ui.TextX - 2), (& $px 284), ($ui.TextW + 4), (& $px 26))
        $ui.BarRect = New-Object System.Drawing.Rectangle($ui.TextX, (& $px 320), $ui.TextW, [Math]::Max(3, (& $px 3)))
        $ui.BarInvalid = New-Object System.Drawing.Rectangle(($ui.TextX - 2), ((& $px 320) - 2), ($ui.TextW + 4), ($ui.BarRect.Height + 4))
        $ui.Segment = [int]($ui.TextW * 0.34)
        $ui.Clock = [System.Diagnostics.Stopwatch]::StartNew()
        $ui.Frozen = -1.0
        if ($shot) { $ui.Frozen = 0.46 }


        $win.Add_Paint({
                param($s, $e)
                $g = $e.Graphics; $r = $e.ClipRectangle
                $g.DrawImage($ui.Cache, $r, $r.X, $r.Y, $r.Width, $r.Height, [System.Drawing.GraphicsUnit]::Pixel)
                if ($r.IntersectsWith($ui.StatusRect)) {
                    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
                    $g.DrawString([string]$state.Status, $ui.FBody, [System.Drawing.Brushes]::White, [single]$ui.TextX, [single]($ui.StatusRect.Y + (& $px 2)))
                }
                if ($r.IntersectsWith($ui.BarInvalid)) {
                    $bar = $ui.BarRect
                    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
                    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
                    $d = [single]$bar.Height
                    $path.AddArc([single]$bar.X, [single]$bar.Y, $d, $d, 90, 180)
                    $path.AddArc([single]($bar.Right - $d), [single]$bar.Y, $d, $d, 270, 180)
                    $path.CloseFigure()
                    $track = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(38, 255, 255, 255))   # white at 15 %
                    $g.FillPath($track, $path); $track.Dispose()
                    # Eased sweep: gentle start, faster middle, gentle end, a very short rest before the loop. The head and the soft tail are one gradient segment.
                    $p = $ui.Progress
                    $t = [Math]::Min(1.0, $p / 0.94)
                    $ease = 0.55 * (0.5 - 0.5 * [Math]::Cos([Math]::PI * $t)) + 0.45 * $t   # mostly eased, never quite stopping
                    $x0 = -$ui.Segment + $ease * ($bar.Width + $ui.Segment)
                    $g.SetClip($path)
                    $segRect = New-Object System.Drawing.RectangleF(([single]($bar.X + $x0)), [single]$bar.Y, [single]$ui.Segment, [single]$bar.Height)
                    $lg = New-Object System.Drawing.Drawing2D.LinearGradientBrush($segRect, [System.Drawing.Color]::FromArgb(0, 76, 194, 255), [System.Drawing.Color]::FromArgb(255, 76, 194, 255), [System.Drawing.Drawing2D.LinearGradientMode]::Horizontal)
                    $blend = New-Object System.Drawing.Drawing2D.ColorBlend(3)
                    $blend.Colors = @([System.Drawing.Color]::FromArgb(0, 76, 194, 255), [System.Drawing.Color]::FromArgb(255, 76, 194, 255), [System.Drawing.Color]::FromArgb(255, 76, 194, 255))
                    $blend.Positions = @([single]0, [single]0.7, [single]1)
                    $lg.InterpolationColors = $blend
                    $g.FillRectangle($lg, $segRect)
                    $lg.Dispose(); $g.ResetClip(); $path.Dispose()
                }
            }.GetNewClosure())

        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 15
        $timer.Add_Tick({
                $ms = $ui.Clock.ElapsedMilliseconds
                $ui.Frame++
                $state.Frame = $ui.Frame
                if ($ui.Frozen -ge 0) { $ui.Progress = $ui.Frozen } else { $ui.Progress = ($ms % 1700) / 1700.0 }
                $state.Progress = $ui.Progress
                # fade in over about 150 ms, fade out over about 120 ms once the launcher asks for it (or after a 60 s safety limit)
                if (-not $ui.Closing -and ($state.Close -or $ms -gt 60000)) { $ui.Closing = $true; $ui.CloseAt = $ms }
                if ($ui.Closing) {
                    $o = 1.0 - (($ms - $ui.CloseAt) / 120.0)
                    if ($o -le 0) { $win.Close(); return }
                    $win.Opacity = $o
                } elseif ($win.Opacity -lt 1) {
                    $win.Opacity = [Math]::Min(1.0, $win.Opacity + 0.12)
                }
                $status = [string]$state.Status
                if ($status -ne $ui.LastStatus) { $ui.LastStatus = $status; $win.Invalidate($ui.StatusRect) }
                $win.Invalidate($ui.BarInvalid)
            }.GetNewClosure())

        if ($shot) {
            # Review screenshot: render this form once, with the bar frozen, and leave.
            $ui.Progress = $ui.Frozen
            $win.Opacity = 0; $win.Location = New-Object System.Drawing.Point(-32000, -32000)
            $win.Show()
            [System.Windows.Forms.Application]::DoEvents()
            $bmp = New-Object System.Drawing.Bitmap($win.Width, $win.Height)
            $win.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $win.Width, $win.Height)))
            $bmp.Save($shot, [System.Drawing.Imaging.ImageFormat]::Png)
            $bmp.Dispose()
            return
        }
        $ui.Progress = 0.0
        $win.Add_FormClosed({ $timer.Stop() }.GetNewClosure())
        $timer.Start()
        [System.Windows.Forms.Application]::Run($win)
    } catch {
        $state.Failed = $true
        $state.Error = $_.Exception.Message
        if ($shot) { throw }
    } finally {
        if ($timer) { $timer.Stop(); $timer.Dispose() }
        if ($win) { $win.Dispose() }
        if ($ui.Cache) { $ui.Cache.Dispose() }
        if ($ui.FBody) { $ui.FBody.Dispose() }
        $state.Done = $true
    }
}

function Start-LauncherSplash {
    # Starts the animated splash on its own thread and waits (briefly) until it is on screen. Returns $false when that cannot be done.
    # The wait keeps the order the DPI rule needs: this window must exist before the process declares DPI awareness.
    $state = [hashtable]::Synchronized(@{
            Close = $false; Ready = $false; Failed = $false; Done = $false; Frame = 0; Progress = 0.0; Error = ''; Shot = ''
            Status = 'Starting...'; Version = $AppVersion; Image = (Join-Path $PSScriptRoot 'assets\splash.jpg'); Dpi = 0; NativeSource = $script:LauncherSplashNativeSource
        })
    $rs = $null; $ps = $null
    try {
        $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $rs.ApartmentState = [System.Threading.ApartmentState]::STA
        $rs.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
        $rs.Open()
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript($script:LauncherSplashBlock.ToString()).AddArgument($state)
        $async = $ps.BeginInvoke()
        $waited = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $state.Ready -and -not $state.Failed -and -not $async.IsCompleted -and $waited.ElapsedMilliseconds -lt 3000) { [System.Threading.Thread]::Sleep(4) }
        if ($state.Ready) {
            $script:SplashState = $state; $script:SplashPs = $ps; $script:SplashRs = $rs; $script:SplashAsync = $async
            return $true
        }
    } catch { $null = $_ } # no runspace (restricted language mode, no memory): the plain splash below takes over
    $state.Close = $true
    foreach ($res in @($ps, $rs)) { if ($res) { try { $res.Dispose() } catch { $null = $_ } } } # never started or never showed: nothing to wait for
    return $false
}
function Close-LauncherSplash([switch]$Wait) {
    # Asks the splash thread to fade out and finish. Without -Wait the launcher is never held up: the thread is cleaned up by a timer once it is done.
    if ($script:Splash) {
        try { $script:Splash.Close(); $script:Splash.Dispose() } catch { $null = $_ } # already gone
        $script:Splash = $null
    }
    if (-not $script:SplashPs) { return }
    $ps = $script:SplashPs; $rs = $script:SplashRs; $async = $script:SplashAsync
    $script:SplashPs = $null; $script:SplashRs = $null; $script:SplashAsync = $null
    try { $script:SplashState.Close = $true } catch { $null = $_ } # the splash timer sees this and closes its window
    $finish = {
        try { if ($async.IsCompleted) { [void]$ps.EndInvoke($async) } else { [void]$ps.BeginStop($null, $null) } } catch { $null = $_ } # best effort
        foreach ($res in @($ps, $rs)) { try { $res.Dispose() } catch { $null = $_ } }
    }.GetNewClosure()
    $done = $false
    try { $done = $async.AsyncWaitHandle.WaitOne($(if ($Wait) { 400 } else { 0 })) } catch { $null = $_ }
    if ($done) { & $finish; return }
    if ($Wait) { & $finish; return }
    try {
        $cleanup = New-Object System.Windows.Forms.Timer
        $cleanup.Interval = 250
        $left = @{ N = 0 }
        $cleanup.Add_Tick({
                $left.N++
                if ($async.IsCompleted -or $left.N -ge 24) { $cleanup.Stop(); $cleanup.Dispose(); & $finish }
            }.GetNewClosure())
        $cleanup.Start()
    } catch { & $finish }
}
function Exit-LauncherMutex {
    if ($script:LauncherMutex) {
        try { $script:LauncherMutex.ReleaseMutex() } catch { $null = $_ } # not owned by this thread: the OS frees it when the process ends
        try { $script:LauncherMutex.Dispose() } catch { $null = $_ } # already disposed
        $script:LauncherMutex = $null
    }
}
if ($env:QRA_SPLASH_SHOT) {
    # Review screenshot of the splash (renders the same form, progress frozen, to the PNG named in the variable). QRA_SPLASH_IMAGE may point at another picture file,
    # QRA_SPLASH_DPI (for example 120 or 150) draws it at that display scale (default: 96, the picture is then 640 x 357).
    $shotState = @{ Shot = $env:QRA_SPLASH_SHOT; Dpi = $(if ($env:QRA_SPLASH_DPI) { [int]$env:QRA_SPLASH_DPI } else { 0 }); Version = $AppVersion; Status = 'Starting...'; Image = $(if ($env:QRA_SPLASH_IMAGE) { $env:QRA_SPLASH_IMAGE } else { Join-Path $PSScriptRoot 'assets\splash.jpg' }) }
    & $script:LauncherSplashBlock $shotState
    exit 0
}
if ($startGui) {
    $mutexMine = $true
    try {
        $mutexNew = $false
        $script:LauncherMutex = New-Object System.Threading.Mutex($true, 'Local\QuarantineReviewAssistant.Launcher', [ref]$mutexNew)
        if (-not $mutexNew) { $mutexMine = $false; $script:LauncherMutex.Dispose(); $script:LauncherMutex = $null }
    } catch { $mutexMine = $true; $script:LauncherMutex = $null } # cannot create the mutex: carry on without the single-instance check
    if (-not $mutexMine) {
        # Another launcher is running: bring its window forward and leave without building anything.
        try {
            $other = @(Get-Process -Name powershell -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID -and $_.MainWindowTitle -like 'Quarantine Review Assistant * - Host Launcher' })[0]
            if ($other -and $other.MainWindowHandle -ne [IntPtr]::Zero -and [string]$ExecutionContext.SessionState.LanguageMode -eq 'FullLanguage') {
                if (-not ('QRA.Wake' -as [type])) {
                    Add-Type -Namespace QRA -Name Wake -ErrorAction Stop -MemberDefinition '[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int n); [DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h); [DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr h);'
                }
                if ([QRA.Wake]::IsIconic($other.MainWindowHandle)) { [void][QRA.Wake]::ShowWindow($other.MainWindowHandle, 9) }   # SW_RESTORE, only for a minimised window
                [void][QRA.Wake]::SetForegroundWindow($other.MainWindowHandle)
            }
        } catch { $null = $_ } # best effort: the running launcher is still there
        Close-LauncherSplash   # no splash exists on this path; it is still the one place that guarantees none is left behind
        exit 0
    }
    if (-not (Start-LauncherSplash)) {
        try {
            # This thread draws first now: make it per-monitor aware before any GDI+ use, so GDI+ does not keep a stale 96 dpi for the whole process.
            if (-not ('QraSplash.Native' -as [type])) { Add-Type -Namespace QraSplash -Name Native -MemberDefinition $script:LauncherSplashNativeSource -ErrorAction Stop }
            [void][QraSplash.Native]::SetThreadPerMonitorV2()
        } catch { $null = $_ } # keeps today's behaviour
        try {
            $sp = New-Object System.Windows.Forms.Form
            $sp.AutoScaleMode = 'None'; $sp.FormBorderStyle = 'None'; $sp.ShowInTaskbar = $false; $sp.TopMost = $true; $sp.StartPosition = 'Manual'
            $sp.BackColor = [System.Drawing.Color]::FromArgb(17, 38, 66); $sp.Size = New-Object System.Drawing.Size(380, 120)
            $spT = New-Object System.Windows.Forms.Label
            $spT.Text = 'Quarantine Review Assistant'; $spT.AutoSize = $true; $spT.Location = New-Object System.Drawing.Point(24, 24)
            $spT.ForeColor = [System.Drawing.Color]::White; $spT.BackColor = [System.Drawing.Color]::Transparent
            $spT.Font = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
            $spS = New-Object System.Windows.Forms.Label
            $spS.Text = 'Starting...'; $spS.AutoSize = $true; $spS.Location = New-Object System.Drawing.Point(27, 70)
            $spS.ForeColor = [System.Drawing.Color]::FromArgb(170, 196, 224); $spS.BackColor = [System.Drawing.Color]::Transparent
            $spS.Font = New-Object System.Drawing.Font('Segoe UI', 10)
            $sp.Controls.AddRange(@($spT, $spS))
            $spArea = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).WorkingArea   # the screen with the mouse
            $sp.Location = New-Object System.Drawing.Point(($spArea.Left + [int](($spArea.Width - $sp.Width) / 2)), ($spArea.Top + [int](($spArea.Height - $sp.Height) / 2)))
            $sp.Show(); $sp.Refresh()
            [System.Windows.Forms.Application]::DoEvents()
            $script:Splash = $sp
        } catch { $script:Splash = $null } # the splash is cosmetic
    }
}
function Set-LauncherSplashStatus([string]$text) {
    if ($script:SplashState) { try { $script:SplashState.Status = $text } catch { $null = $_ } } # cosmetic
}

# Shared UI kit: DPI helpers, design tokens, fonts, painted controls (with plain fallbacks) and background work.
Set-LauncherSplashStatus 'Loading the interface...'
if ($Screenshot) { $env:QRA_DPI_MODE = 'system' }   # the review pictures emulate a scale on one fixed system DPI: no per-monitor behaviour there
. (Join-Path $PSScriptRoot 'QraUi.ps1')
# Optional release-request intake (Exchange Online). Dot-sourced WITHOUT arguments: its parameters are aliased so this script's $Incoming and $Screenshot stay untouched.
. (Join-Path $PSScriptRoot 'ReleaseRequests.ps1')
Set-LauncherSplashStatus 'Building the window...'
if ($script:Splash) { [System.Windows.Forms.Application]::DoEvents() }
# -ScreenshotDpi: emulate another display scale. Must run before any window exists.
# Otherwise (per-monitor aware): the window is built for the screen it opens on, the one with the mouse (CenterScreen). Set-QraEmulatedDpi does the rest.
if ($ScreenshotDpi -gt 0) { Set-QraEmulatedDpi $ScreenshotDpi }
elseif ($script:QraPerMonitor) { Set-QraEmulatedDpi (Get-QraMonitorDpi) }
[System.Windows.Forms.Application]::EnableVisualStyles()
trap {
    Close-LauncherSplash -Wait; Exit-LauncherMutex
    if ($Screenshot) { [Console]::Error.WriteLine($_.Exception.Message + "`n" + $_.InvocationInfo.PositionMessage + "`n" + $_.ScriptStackTrace); exit 1 }   # headless: never wait on a dialog
    [System.Windows.Forms.MessageBox]::Show("The launcher hit an unexpected error:`r`n`r`n$($_.Exception.Message)`r`n`r`nIf your organisation blocks PowerShell scripts, ask IT security to allow this tool's folder.", 'Quarantine Review Assistant', 'OK', 'Error') | Out-Null
    break
}

# ---------------------------------------------------------------- configuration ($AppVersion is set at the top: the splash shows it)
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
    Use-QraFormDpi $form
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
# $Facts keys: ChecksRunning, BlockingCount, WarnCount, DefenderChecked, IncomingCount, ReviewedCount (packages with a
# decision for exactly these bytes; absent = 1 when DecisionCurrent, else 0), DecisionCurrent (at least one package reviewed),
# PartialContinued (the user chose to go on with some of the packages reviewed), DecisionText, SandboxRunning, LaunchState ('None' | 'Starting' | 'Vanished'), ExportOn, DecisionAcknowledged, CleanedUp,
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
        $reviewed = if ($null -ne $Facts.ReviewedCount) { [int]$Facts.ReviewedCount } else { [int][bool]$Facts.DecisionCurrent }
        $all = ($incoming -gt 0 -and $reviewed -ge $incoming)
        $partial = ($reviewed -gt 0 -and $reviewed -lt $incoming)
        $byDecision = $all
        if ($all) { $s.State = 'Done'; $s.Summary = $(if ($reviewed -gt 1) { "Decisions recorded for $reviewed messages" } else { 'Decision recorded' }) }
        elseif ($Facts.DecisionAcknowledged -and -not $Facts.ExportOn) { $s.State = 'Done'; $s.Summary = 'Decision recorded in the Sandbox' }
        elseif ($Facts.SandboxRunning) { $s.State = 'Working'; $s.Summary = 'Review in progress'; $current = 4 }
        elseif ($Facts.LaunchState -eq 'Starting') { $s.State = 'Working'; $s.Summary = 'Starting Windows Sandbox...' + (Format-WaitSeconds $Facts.LaunchSeconds); $current = 4 }
        elseif ($partial -and $Facts.PartialContinued) { $s.State = 'Done'; $s.Summary = "$reviewed of $incoming messages reviewed"; $byDecision = $true }
        else {
            $s.State = 'Current'; $current = 4
            if ($partial) { $s.Summary = "$reviewed of $incoming messages reviewed" }
            elseif ($Facts.LaunchState -eq 'Vanished') { $s.Summary = 'The Sandbox closed before a decision reached this PC.' }
        }
    }

    # 5. Act in Defender and clean up
    if ($current -eq 0) {
        $s = $steps[4]
        $s.State = 'Current'; $current = 5
        if (-not $byDecision -and $Facts.DecisionAcknowledged -and -not $Facts.ExportOn) { $s.Summary = 'No decision received on this PC (report export was off)' }
        elseif ($byDecision -and $reviewed -gt 1) { $s.Summary = "$reviewed decisions recorded" }
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
if (-not $Screenshot) { Enable-QraForeground; Hide-QraConsole }   # the console is about to vanish: keep the right to come to the front

# ================================================================= UI
$Fonts = @{
    Title = (New-Font 18 'Bold' 'Display'); Sub = (New-Font 10); Pane = (New-Font 14 'Bold' 'Display')
    Row = (New-Font 11 'Bold'); RowSub = (New-Font 9.5); Body = (New-Font 10); BodyBold = (New-Font 10 'Bold')
    Eyebrow = (New-Font 9 'Bold'); Small = (New-Font 9); Overall = (New-Font 10 'Bold'); Pill = (New-Font 9.5 'Bold')
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
Set-QraWindowChrome $form -NoAppId:([bool]$Screenshot)   # app icon, own taskbar button, navy title bar (Windows 11)

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
        Use-QraFormDpi $form
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
                $segs += @{ Text = $part[0]; Bold = [bool]$part[1]; Font = $(if ($part[1]) { $Fonts.BodyBold } else { $Fonts.Body }) }
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
$bShortcut = New-QraButton 'Create desktop shortcut' 'Secondary' $QraGlyph.Link
$overallSpin = New-QraSpinner 28
$overallSpin.BackColor = $C.Card; Set-Shown $overallSpin $false
$st1.Panel.Controls.AddRange(@($checksPanel, $checksNote, $overallSpin, $overall, $bShortcut, $recheck))

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
    (New-SubStep 'Optional: Fetch release requests saves the messages you select straight into this folder.' 'Fetch release requests')
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
$optReports = New-QraCheckBox 'Let the Sandbox save reports and the decision log to the Reports folder on this PC'
$optReports.Checked = $true
$optProtected = New-QraCheckBox 'Protected Client mode (extra hardening; turn off if the Sandbox fails to start)'
$optCompat = New-QraCheckBox 'Compatibility mode (only if the Sandbox will not start; weaker isolation)'
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
# The recorded decisions: a heading with a count, then one card per package (built by Build-DecisionCards while the step is laid out). With no
# decision yet, $lastDec holds the guidance as a muted note.
$lastDec = New-Object System.Windows.Forms.Label
$lastDec.BackColor = $C.Surface; $lastDec.Padding = New-Object System.Windows.Forms.Padding(8, 6, 8, 6); $lastDec.Font = $Fonts.Body
$lastDec.ForeColor = $C.TextMuted; $lastDec.UseMnemonic = $false
$decHead = New-TextLabel '' $Fonts.BodyBold $C.Text
$decArea = New-Object System.Windows.Forms.Panel
$decArea.AutoScroll = $true; $decArea.BackColor = $C.Card; $decArea.TabStop = $false
Set-ControlStyle $decArea 'Selectable' $true     # takes the focus on mouse-over, so the wheel scrolls a long list
$decArea.Add_MouseEnter({ if (-not $this.Focused) { [void]$this.Focus() } })
Set-Shown $lastDec $true; Set-Shown $decHead $false; Set-Shown $decArea $false
$bCopyBlock = New-QraButton 'Copy block list' 'Secondary' $QraGlyph.Copy
$bLog = New-QraButton 'Decisions log' 'Secondary'
$bReports = New-QraButton 'Reports folder' 'Secondary' $QraGlyph.Folder
$bClean = New-QraButton 'Delete Incoming...' 'Danger' $QraGlyph.Delete
$st5.Panel.Controls.AddRange(@($doneNote, $bNext, $decHead, $decArea, $lastDec, $bCopyBlock, $bLog, $bReports, $bClean))

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
Set-Access $bShortcut 'Create a desktop shortcut for the launcher'
Set-Access $bPortal 'Open Defender quarantine in the browser'
Set-Access $bChecked "I've checked it in Defender, go to the next step"
Set-Access $incomingLbl 'Incoming folder path'
Set-Access $bOpenIncoming 'Open the Incoming folder'; Set-Access $bCopyIncoming 'Copy the Incoming folder path'
Set-Access $bFetch 'Fetch release requests from Exchange Online and save the ones you select into Incoming'
Set-Access $incomingList 'Files waiting for review'
Set-Access $optReports 'Let the Sandbox save reports to this PC'; Set-Access $optProtected 'Protected Client mode'; Set-Access $optCompat 'Compatibility mode, weaker isolation'
Set-Access $bLaunch 'Launch Sandbox review'
Set-Access $bAck "I've recorded my decision in the Sandbox, go to the next step"
Set-Access $bCopyBlock 'Copy block list'; Set-Access $bLog 'Open the decisions log'; Set-Access $bReports 'Open the Reports folder'; Set-Access $bClean 'Delete files in Incoming'
Set-Access $bNext 'Review the next message'
Set-Access $decArea 'Recorded decisions' 'One card per message, with its decision, subject, sender and the tool verdicts'
$rail.TabIndex = 0; $pane.TabIndex = 1
$ti = 0; foreach ($row in $script:RailRows) { $row.TabIndex = $ti++ }
$checksPanel.TabIndex = 0; $recheck.TabIndex = 1; $bShortcut.TabIndex = 2
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
    Use-QraFormDpi $form
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
    Use-QraFormDpi $form
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
    Use-QraFormDpi $form
    $st = $script:Step[$n]; $p = $st.Panel
    $w = $p.ClientSize.Width; $h = $p.ClientSize.Height
    $pad = S 28
    $cw = [Math]::Max((S 320), $w - 2 * $pad)
    $tw = [Math]::Min($cw, (S 900))   # lead, sub-steps and options use the content width up to a comfortable reading width
    $rw = [Math]::Min($cw, (S 760))
    $p.SuspendLayout()
    $y = Set-StepHead $st $pad $tw
    switch ($n) {
        1 {
            $barH = S 40
            $top = $y
            $hasRows = ($checksPanel.Controls.Count -gt 0)
            # Check again sits at the right end; Create desktop shortcut is left of it (same height, 8 px gap), or on its own row below when the text would get too narrow.
            $wRe = Get-ButtonWidth $recheck (S 128); $wSc = Get-ButtonWidth $bShortcut (S 128)
            $oneRow = (($cw - $wRe - (S 8) - $wSc - (S 8)) -ge (S 240))
            $barBlock = if ($oneRow) { $barH } else { 2 * $barH + (S 8) }
            $checksPanel.SetBounds($pad, $top, $cw, [Math]::Max((S 120), $h - $top - $barBlock - (S 32)))
            $checksNote.Visible = -not $hasRows
            if (-not $hasRows) { [void](Set-Wrapped $checksNote $pad ($top + (S 8)) $tw) }
            $by = $checksPanel.Bottom + (S 16)
            $recheck.SetBounds(($pad + $cw - $wRe), $by, $wRe, $barH)
            if ($oneRow) { $bShortcut.SetBounds(($recheck.Left - (S 8) - $wSc), $by, $wSc, $barH); $textRight = $bShortcut.Left }
            else { $bShortcut.SetBounds(($pad + $cw - $wSc), ($by + $barH + (S 8)), $wSc, $barH); $textRight = $recheck.Left }
            $overallSpin.SetBounds($pad, ($by + [int](($barH - (S 28)) / 2)), (S 28), (S 28))
            $ox = if (Test-Shown $overallSpin) { $pad + (S 40) } else { $pad }
            $overall.SetBounds($ox, $by, [Math]::Max((S 120), $textRight - $ox - (S 8)), $barH)
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
                $opt.Height = [Math]::Max((S 24), (Measure-Wrapped $opt.Text $opt.Font ($tw - (Get-QraCheckBoxIndent $opt))) + (S 4))
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
            if (Test-Shown $decHead) { $decHead.SetBounds($pad, $y, $rw, ($Fonts.BodyBold.Height + (S 4))); $y = $decHead.Bottom + (S 8) }
            if (Test-Shown $decArea) {
                # the cards scroll inside their area when they do not fit; the buttons below always stay visible
                $below = (S 16) + (S 36) + (S 16) + (S 36) + (S 24)
                $total = Get-DecisionCardsHeight $script:DecCards
                $avail = [Math]::Max((S 140), $h - $y - $below)
                $scrolls = ($total -gt $avail)
                $decArea.SetBounds($pad, $y, $rw, $(if ($scrolls) { $avail } else { $total }))
                Build-DecisionCards ($rw - $(if ($scrolls) { [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth } else { 0 }))
                $y = $decArea.Bottom + (S 16)
            }
            if (Test-Shown $lastDec) {
                $lastDec.SetBounds($pad, $y, $rw, [Math]::Max((S 56), (Measure-Wrapped $lastDec.Text $lastDec.Font ($rw - (S 16))) + (S 20)))
                $y = $lastDec.Bottom + (S 16)
            }
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
    if (-not $script:LayoutReady -or $script:InLayout -or $script:QraDpiBusy) { return }
    Use-QraFormDpi $form
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

# ---- Per-monitor DPI: the window is rescaled when it is dragged to a screen with another scale (no-op in system mode, the fallback and Constrained Language Mode).
# The rich sub-step lines hold their fonts in Tag, the check rows are rebuilt (they were sized with S()), then the whole layout runs again.
[void](Register-QraDpiWindow $form -FontTables @($Fonts) -Relayout {
        param($f)
        foreach ($stepInfo in @($script:Step.Values)) {
            foreach ($item in $stepInfo.Subs) {
                if ($item.Rich) { foreach ($seg in $item.Rich.Tag) { $seg.Font = $(if ($seg.Bold) { $Fonts.BodyBold } else { $Fonts.Body }) } }
            }
        }
        if (@($script:Checks).Count) { Render-Checks }
        Update-StepLayout
    })

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
$script:DecisionMap = @{}              # input_sha256 -> newest complete decision record in Reports
$script:DecisionCache = @{}            # record file signature -> parsed record (old files are read once)
$script:DecCards = @(); $script:DecSig = ''; $script:DecBuiltKey = ''   # the step 5 cards (data, signature, what was last built)
$script:Reviewed = @()                 # {FileName, Decision} for every package in Incoming with a decision for its bytes
$script:IncomingWatcher = $null
$script:HashWork = $null
$script:HashWorkKey = $null
$script:IncomingHashes = @{}           # full path -> SHA256 of each package in Incoming
$script:IncomingHashKey = $null
$script:RunEnded = $false              # a Sandbox run was seen and has closed (Vanished is judged against LaunchSnapshot)
$script:LaunchSnapshot = @{}           # decision hash -> record source when the Sandbox was launched
$script:ContinuedSig = $null           # 'reviewed/incoming' the user chose to go on with (some packages unreviewed)
$script:LastReviewedSig = $null
$script:AckPartial = $false

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
    Use-QraFormDpi $form
    $checksPanel.SuspendLayout()
    foreach ($old in @($checksPanel.Controls)) { $old.Dispose() }   # Clear() would leave animated spinners registered
    $script:BusyRow = $null
    if (-not $script:RowFonts) { $script:RowFonts = @{ Icon = (Get-IconFont 14); Name = (New-Font 10 'Bold') }; Add-QraFontTable $form $script:RowFonts }   # rescaled with the window
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

# Puts "Quarantine Review Assistant.lnk" on the user's Desktop (the real one, also when OneDrive redirects it). Asks before replacing. Nothing else is touched.
function Invoke-CreateDesktopShortcut {
    $title = 'Quarantine Review Assistant'
    try {
        $desktop = [Environment]::GetFolderPath('Desktop')
        $lnkPath = Join-Path $desktop 'Quarantine Review Assistant.lnk'
        $force = $false
        if (Test-Path -LiteralPath $lnkPath) {
            if ([System.Windows.Forms.MessageBox]::Show('Replace the existing desktop shortcut?', $title, 'YesNo', 'Question') -ne 'Yes') { return }
            $force = $true
        }
        $icoPath = Join-Path $Root 'QuarantineReviewAssistant.ico'
        if (-not (Test-Path -LiteralPath $icoPath)) {
            try { if (-not (Write-QraIcoFile $icoPath)) { $icoPath = '' } } catch { $icoPath = '' }   # no icon file: the shortcut still works, with the default icon
        }
        $res = New-QraDesktopShortcut -ShortcutPath $lnkPath -Target (Join-Path $Root 'Start-Here.cmd') -WorkingDirectory $Root -IconPath $icoPath -Force:$force
        if ($res.Status -in 'Created', 'Replaced') { Show-QraCopied $bShortcut 'Shortcut created'; return }
        [System.Windows.Forms.MessageBox]::Show("The desktop shortcut could not be created.`r`n`r`n$($res.Message)", $title, 'OK', 'Warning') | Out-Null
    } catch {
        [System.Windows.Forms.MessageBox]::Show("The desktop shortcut could not be created.`r`n`r`n$($_.Exception.Message)", $title, 'OK', 'Warning') | Out-Null
    }
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

# Every complete decision record in $directory as a map input_sha256 -> newest record for that hash. Records that are
# unreadable, malformed or incomplete (Get-DecisionInputHash) are ignored. Each record carries qra_source (file name, size
# and write time) so a re-recorded decision can be told from an older one. $cache (sig -> record) spares re-reading old files.
function Read-DecisionMap([string]$directory, [hashtable]$cache = $null) {
    $map = @{}
    try {
        $files = @(Get-ChildItem -LiteralPath $directory -File -Filter 'Decision-*.json' -ErrorAction Stop |
            Where-Object { $_.Name -notlike '*-report.json' -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
            Sort-Object LastWriteTimeUtc, Name)
        $seen = @{}
        foreach ($f in $files) {
            $sig = '{0}|{1}|{2}' -f $f.Name, $f.Length, $f.LastWriteTimeUtc.Ticks
            $seen[$sig] = $true
            if ($cache -and $cache.ContainsKey($sig)) { $record = $cache[$sig] }
            else {
                $record = $null
                try {
                    $r = [IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json -ErrorAction Stop
                    if ($r -is [pscustomobject] -and (Get-DecisionInputHash $r)) {
                        Add-Member -InputObject $r -NotePropertyName qra_source -NotePropertyValue $sig -Force
                        $record = $r
                    }
                } catch { $null = $_ } # unreadable or malformed decision JSON is ignored
                if ($cache) { $cache[$sig] = $record }
            }
            if ($record) { $map[[string]$record.input_sha256] = $record }
        }
        if ($cache) { foreach ($k in @($cache.Keys)) { if (-not $seen.ContainsKey($k)) { $cache.Remove($k) } } }
    } catch { $null = $_ } # an unreadable Reports folder means no decisions
    return $map
}

# hash -> source of the record, to tell later which decisions are new
function Get-DecisionSnapshot($map) {
    $snap = @{}
    if ($map) { foreach ($k in @($map.Keys)) { $snap[[string]$k] = [string]$map[$k].qra_source } }
    return $snap
}

# True when the Sandbox run left a decision that was not there at launch. $currentHashes: the hashes of the packages now in
# Incoming, or $null while they are still being computed (then any new record counts, so a decision just recorded is not
# reported as missing for the few seconds the hashing takes).
function Test-RunProducedDecision($map, $snapshot, $currentHashes) {
    if (-not $map) { return $false }
    foreach ($h in @($map.Keys)) {
        if ($null -ne $currentHashes -and @($currentHashes) -notcontains [string]$h) { continue }
        if (-not $snapshot -or -not $snapshot.ContainsKey([string]$h) -or $snapshot[[string]$h] -ne [string]$map[$h].qra_source) { return $true }
    }
    return $false
}

# Timestamps identify when to discard work. Only a hash of the bytes can match a record.
function Get-IncomingFileKey($f) {
    if ($f.Extension -in '.zip', '.eml' -and -not ($f.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        return '{0}|{1}|{2}|{3}' -f $f.FullName, $f.Length, $f.CreationTimeUtc.Ticks, $f.LastWriteTimeUtc.Ticks
    }
}
# One key for every package in Incoming (.zip/.eml, not a reparse point), in a fixed order. Nothing when there is none.
function Get-IncomingPackageKey($files) {
    $keys = @(@($files) | Where-Object { $_ } | Sort-Object FullName | ForEach-Object { Get-IncomingFileKey $_ })
    if ($keys.Count) { return ($keys -join ';') }
}
function Get-IncomingPackagePaths($files) {
    @(@($files) | Where-Object { $_ -and (Get-IncomingFileKey $_) } | Sort-Object FullName | ForEach-Object { [string]$_.FullName })
}

# The packages in $files that have a decision for exactly these bytes. $hashes: full path -> SHA256 of the file now in
# Incoming; $map: input_sha256 -> newest record (Read-DecisionMap). A stale or previous decision never matches.
function Get-ReviewedPackages($files, $hashes, $map) {
    if (-not $hashes -or -not $map) { return }
    foreach ($f in @($files | Where-Object { $_ })) {
        $h = [string]$hashes[[string]$f.FullName]
        if ($h -and $map.ContainsKey($h) -and (Get-DecisionInputHash $map[$h]) -eq $h) {
            [pscustomobject]@{ FileName = [string]$f.Name; Decision = $map[$h] }
        }
    }
}

function Clear-IncomingHash {
    $script:HashWorkKey = $null  # discard an in-flight result even if the path and timestamps were preserved
    $script:IncomingHashKey = $null
    $script:IncomingHashes = @{}
    $script:DecisionCurrent = $false
    $script:Reviewed = @()
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
        $script:IncomingHashes = @{}; $script:IncomingHashKey = $null
    }
    if ($script:HashWork) {
        if ($key -ne $script:HashWorkKey) { $script:HashWorkKey = $null }
        if (-not (Test-QraWork $script:HashWork)) { return }
        $result = Complete-QraWork $script:HashWork
        $script:HashWork = $null
        if ($key -and $key -eq $script:HashWorkKey -and $script:IncomingWatcher -and -not $result.Error) {
            $found = @{}
            foreach ($o in @($result.Output)) { if ($o.Path -and $o.Hash) { $found[[string]$o.Path] = [string]$o.Hash } }
            if ($found.Count) { $script:IncomingHashes = $found; $script:IncomingHashKey = $key }
        }
    }
    if (-not $key -or -not $script:IncomingWatcher -or $script:IncomingHashKey -or -not $script:DecisionMap.Count) { return }
    try {
        $script:HashWorkKey = $key
        # every package in Incoming, in one background job (nothing is hashed on the UI thread)
        $script:HashWork = Start-QraWork {
            foreach ($p in $packagePaths) {
                [pscustomobject]@{ Path = $p; Hash = (Get-FileHash -LiteralPath $p -Algorithm SHA256 -ErrorAction Stop).Hash }
            }
        } -Variables @{ packagePaths = @(Get-IncomingPackagePaths $script:IncomingFiles) }
    } catch { $script:HashWorkKey = $null }
}

function Refresh-LastDecision {
    $script:DecisionMap = Read-DecisionMap $Reports $script:DecisionCache
    Show-LastDecision (Read-LastDecision $Reports)
    Update-IncomingHash
}

$script:NoDecisionText = 'No decision recorded yet. In the Sandbox: Record decision, bottom left (needs "save reports to this PC" selected in step 4).'
function Show-LastDecision($d) {
    $script:LastDecision = $d
    if (-not $d) {
        $lastDec.Text = $script:NoDecisionText
        $bCopyBlock.Enabled = $false
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
# Several decisions for the last-decision box: one line per package, then the compact details of each decision.
function Get-ReviewedDecisionsText($reviewed, $incomingNames) {
    $items = @($reviewed | Where-Object { $_ } | Sort-Object { [string]$_.FileName })
    $names = @($items | ForEach-Object { [string]$_.FileName })
    $rest = @(@($incomingNames) | Where-Object { $_ -and ($names -notcontains [string]$_) } | Sort-Object)
    $head = if ($rest.Count) { "$($items.Count) of $($items.Count + $rest.Count) messages reviewed" } else { "$($items.Count) decisions recorded" }
    $L = @($head)
    foreach ($i in $items) {
        $d = $i.Decision
        $L += "$($i.FileName) - $($d.final_decision) - $($d.confidence) - $($d.recorded_local)"
        $L += "    Sender: $($d.sender) | Subject: $($d.subject)"
        $L += "    Tool said: $($d.tool_recommendation); Microsoft: $($d.microsoft_verdict)"
    }
    foreach ($n in $rest) { $L += "$n - not reviewed yet" }
    return ($L -join "`r`n")
}
function Test-DecisionHasIocs($d) {
    $io = $d.iocs
    return [bool]($io.sender -or $io.sender_domain -or $io.domains -or $io.urls -or $io.sha256 -or $d.spoof_pair)
}
# Pure: the tone of a recorded decision ('Danger' | 'Success' | 'Warning' | 'Info'). Keep/verify wins over release, release over delete/block.
function Get-DecisionTone($finalDecision) {
    $t = ([string]$finalDecision).ToLowerInvariant()
    if ($t -match 'keep|verif|pending|hold') { return 'Warning' }
    if ($t -match 'release|allow|false positive|deliver') { return 'Success' }
    if ($t -match 'delete|block|remove|purge') { return 'Danger' }
    return 'Info'
}
# Pure: the cards for step 5. Kind is 'Decision', 'Pending' (a package in Incoming without a decision) or 'Previous' (a decision that is not for the current download).
function Get-DecisionCards($reviewed, $incomingNames, $lastDecision, [bool]$stale) {
    $dot = '  ' + [string][char]0x00B7 + '  '
    $oneLine = { param($s) (([string]$s) -replace '[\r\n]+', ' ').Trim() }
    $make = { param($d, $file, $kind)
        $subject = & $oneLine $d.subject; if (-not $subject) { $subject = '(no subject)' }
        $fromAddr = & $oneLine $d.sender; if (-not $fromAddr) { $fromAddr = '(no sender)' }
        $decision = & $oneLine $d.final_decision; if (-not $decision) { $decision = 'Decision recorded' }
        $conf = & $oneLine $d.confidence; if ($conf) { $conf = "$conf confidence" }
        $from = "From $fromAddr"; if ($file) { $from += $dot + $file }
        $toolParts = @()
        $rec = & $oneLine $d.tool_recommendation; $ms = & $oneLine $d.microsoft_verdict
        if ($rec) { $toolParts += "Tool: $rec" }
        if ($ms) { $toolParts += "Microsoft: $ms" }
        $prefix = if ($kind -eq 'Previous') { 'Previous decision, not for the current download: ' } else { 'Recorded decision: ' }
        $confText = if ($conf) { ', ' + $conf } else { '' }
        [pscustomobject]@{
            Kind = $kind; Tone = (Get-DecisionTone $decision); Decision = $decision; Confidence = $conf; Time = (& $oneLine $d.recorded_local)
            Subject = $subject; From = $from; File = [string]$file; Tool = ($toolParts -join $dot)
            Accessible = "$prefix$decision$confText. Subject: $subject. From: $fromAddr."
        }
    }
    $cards = @()
    $items = @($reviewed | Where-Object { $_ } | Sort-Object { [string]$_.FileName })
    if ($items.Count) {
        foreach ($i in $items) { $cards += & $make $i.Decision ([string]$i.FileName) 'Decision' }
        $names = @($items | ForEach-Object { [string]$_.FileName })
        foreach ($n in @(@($incomingNames) | Where-Object { $_ -and ($names -notcontains [string]$_) } | Sort-Object)) {
            $cards += [pscustomobject]@{ Kind = 'Pending'; Tone = 'Info'; Decision = 'Not reviewed yet'; Confidence = ''; Time = ''; Subject = ''; From = ''; File = [string]$n; Tool = 'Launch the Sandbox again to review it.'
                Accessible = "Not reviewed yet: $n. Launch the Sandbox again to review it." }
        }
    } elseif ($lastDecision) {
        $cards += & $make $lastDecision '' $(if ($stale) { 'Previous' } else { 'Decision' })
    }
    return @($cards)
}
# Pure: the line above the cards ('' for none).
function Get-DecisionHeading($cards) {
    $dec = @($cards | Where-Object { $_.Kind -eq 'Decision' }).Count
    $pend = @($cards | Where-Object { $_.Kind -eq 'Pending' }).Count
    if (-not $dec) { return '' }
    if ($pend) { return "$dec of $($dec + $pend) messages reviewed" }
    if ($dec -eq 1) { return 'Decision recorded' }
    return "$dec decisions recorded"
}
# Pure: the step 5 intro and the clean-up sub-step, singular or plural.
function Get-Step5Wording([bool]$several) {
    if ($several) { return @{ Lead = 'Your recorded decisions appear below with a ready-to-paste block list.'; Delete = 'Delete the downloaded ZIPs from Incoming.' } }
    return @{ Lead = 'Your recorded decision appears below with a ready-to-paste block list.'; Delete = 'Delete the downloaded ZIP from Incoming.' }
}
function Get-DecisionCardHeight($card) {
    $sh = if ($script:UiNative) { S 2 } else { 0 }
    $fp = $Fonts.Pill.Height
    $pillH = $fp + 2 * [int][Math]::Round($fp * 0.3)
    if ($card.Kind -eq 'Pending') { return (2 * $sh + 2 * (S 10) + $Fonts.BodyBold.Height + (S 2) + (S 2) + $Fonts.Small.Height + (S 2)) }
    $h = 2 * $sh + 2 * (S 10) + $pillH + (S 6) + ($Fonts.BodyBold.Height + (S 2)) + (S 2) + ($Fonts.Body.Height + (S 2))
    if ($card.Tool) { $h += (S 2) + $Fonts.Small.Height + (S 2) }
    if ($card.Kind -eq 'Previous') { $h += $Fonts.Small.Height + (S 2) + (S 4) }
    return $h
}
function Get-DecisionCardsHeight($cards) {
    $list = @($cards | Where-Object { $_ })
    if (-not $list.Count) { return 0 }
    $sum = 0; foreach ($one in $list) { $sum += Get-DecisionCardHeight $one }
    return ($sum + ($list.Count - 1) * (S 10))
}
# Rebuilds the cards at this width. Nothing is cached in pixels: the key holds the data, the width, the scale and the contrast mode.
function Build-DecisionCards([int]$width) {
    Use-QraFormDpi $form
    $key = '{0}|{1}|{2}|{3}' -f $script:DecSig, $width, $script:DpiScale, $script:QraHighContrast
    if ($key -eq $script:DecBuiltKey) { return }
    $script:DecBuiltKey = $key
    $native = [bool]$script:UiNative
    $sh = if ($native) { S 2 } else { 0 }
    $statusOf = @{ Danger = 'FAIL'; Success = 'OK'; Warning = 'WARN'; Info = 'INFO' }
    if (-not $script:DecTip) { try { $script:DecTip = New-Object System.Windows.Forms.ToolTip } catch { $script:DecTip = $null } }
    $mkLabel = { param($text, $font, $color, $fill, $x, $y, $w, $tip)
        $l = New-Object System.Windows.Forms.Label
        $l.AutoSize = $false; $l.UseMnemonic = $false; $l.AutoEllipsis = $true; $l.TextAlign = 'MiddleLeft'
        $l.Text = $text; $l.Font = $font; $l.ForeColor = $color; $l.BackColor = $fill
        $l.SetBounds($x, $y, [Math]::Max((S 20), $w), ($font.Height + (S 2)))
        if ($tip -and $script:DecTip) { $script:DecTip.SetToolTip($l, $text) }
        $l
    }
    $decArea.SuspendLayout()
    foreach ($old in @($decArea.Controls)) { $old.Dispose() }
    $y = 0
    foreach ($card in @($script:DecCards)) {
        $ch = Get-DecisionCardHeight $card
        $stale = ($card.Kind -ne 'Decision')
        $fill = if ($card.Kind -eq 'Decision') { $C.Card } else { $C.Surface }
        $p = New-QraCard
        if ($native) { $p.ShadowSize = $sh; $p.Radius = S 8; $p.FillColor = $fill } else { $p.BackColor = $fill; $p.BorderStyle = 'FixedSingle' }
        $p.AccessibleName = $card.Accessible; $p.AccessibleRole = 'Grouping'
        $x0 = $sh + (S 20); $xr = $width - $sh - (S 16); $cw = $xr - $x0
        $mute = $C.TextMuted
        if ($card.Kind -eq 'Pending') {
            $yy = $sh + (S 10)
            $p.Controls.Add((& $mkLabel $card.Decision $Fonts.BodyBold $mute $fill $x0 $yy $cw $false))
            $yy += $Fonts.BodyBold.Height + (S 4)
            $p.Controls.Add((& $mkLabel ($card.File + '  ' + [string][char]0x00B7 + '  ' + $card.Tool) $Fonts.Small $mute $fill $x0 $yy $cw $true))
        } else {
            if ($card.Kind -eq 'Decision') {
                $bar = New-Object System.Windows.Forms.Panel
                $bar.BackColor = $C[[string]$card.Tone]
                if ($native) { $bar.SetBounds(($sh + (S 1)), ($sh + (S 8)), (S 4), ($ch - 2 * ($sh + (S 8)))) } else { $bar.SetBounds(1, 1, (S 4), ($ch - 2)) }
                $p.Controls.Add($bar)
            }
            $yy = $sh + (S 10)
            if ($card.Kind -eq 'Previous') {
                $p.Controls.Add((& $mkLabel 'Previous decision (not for the current download)' $Fonts.Small $mute $fill $x0 $yy $cw $false))
                $yy += $Fonts.Small.Height + (S 2) + (S 4)
            }
            $pill = New-QraPill $statusOf[[string]$card.Tone] $card.Decision
            $pill.Font = $Fonts.Pill
            if (-not $native) { $pill.BackColor = $fill; $pill.Padding = (SPad 8 2 8 2) }
            $timeW = 0
            if ($card.Time) { $timeW = (Get-TextAdvance $card.Time $Fonts.Small) + (S 16) }
            $room = $cw - $timeW - (S 12)
            if ($pill.Width -gt $room) { $pill.AutoSize = $false; $pill.Width = [Math]::Max((S 80), $room) }
            $pill.Location = New-Object System.Drawing.Point($x0, $yy)
            $pill.AccessibleName = $card.Decision
            $p.Controls.Add($pill)
            $pillH = $pill.Height
            $rx = $pill.Right + (S 10)
            $smallTop = $yy + [int](($pillH - $Fonts.Small.Height - (S 2)) / 2)
            if ($card.Time) {
                $tl = & $mkLabel $card.Time $Fonts.Small $mute $fill ($xr - $timeW) $smallTop $timeW $false
                $tl.TextAlign = 'MiddleRight'; $tl.AutoEllipsis = $false; $p.Controls.Add($tl)
            }
            if ($card.Confidence) { $p.Controls.Add((& $mkLabel $card.Confidence $Fonts.Small $mute $fill $rx $smallTop ($xr - $timeW - (S 8) - $rx) $false)) }
            $yy += $pillH + (S 6)
            $subjColor = if ($stale) { $mute } else { $C.Text }
            $p.Controls.Add((& $mkLabel $card.Subject $Fonts.BodyBold $subjColor $fill $x0 $yy $cw $true))
            $yy += $Fonts.BodyBold.Height + (S 2) + (S 2)
            $p.Controls.Add((& $mkLabel $card.From $Fonts.Body $mute $fill $x0 $yy $cw $true))
            $yy += $Fonts.Body.Height + (S 2) + (S 2)
            if ($card.Tool) { $p.Controls.Add((& $mkLabel $card.Tool $Fonts.Small $mute $fill $x0 $yy $cw $true)) }
        }
        $p.SetBounds(0, $y, $width, $ch)
        $decArea.Controls.Add($p)
        $y += $ch + (S 10)
    }
    $decArea.ResumeLayout($true)
}
function Set-LastDecisionView {
    $reviewed = @($script:Reviewed | Where-Object { $_ })
    $incNames = @($script:IncomingFiles | Where-Object { $_ } | ForEach-Object { [string]$_.Name })
    $d = $script:LastDecision
    $cards = @(); $enabled = $false
    if ($reviewed.Count) {
        $hasIocs = [bool](@($reviewed | Where-Object { Test-DecisionHasIocs $_.Decision }).Count)
        $st = Get-CopyBlockState $hasIocs $true ([bool]$optReports.Checked)
        $cards = @(Get-DecisionCards $reviewed $incNames $null $false); $enabled = $st.Enabled
    } elseif ($d) {
        $st = Get-CopyBlockState (Test-DecisionHasIocs $d) ([bool]$script:DecisionCurrent) ([bool]$optReports.Checked)
        $cards = @(Get-DecisionCards @() @() $d $st.Stale); $enabled = $st.Enabled
    }
    $bCopyBlock.Enabled = $enabled
    $several = (($reviewed.Count -gt 1) -or ($incNames.Count -gt 1))
    $wording = Get-Step5Wording $several
    $changed = $false
    if ($st5.Lead.Text -ne $wording.Lead) { $st5.Lead.Text = $wording.Lead; $changed = $true }
    $delSub = $st5.Subs[2]
    if ($delSub.Plain.Text -ne $wording.Delete) { $delSub.Plain.Text = $wording.Delete; $delSub.Text = $wording.Delete; $changed = $true }
    $sig = (@($cards | ForEach-Object { @($_.Kind, $_.Decision, $_.Confidence, $_.Time, $_.Subject, $_.From, $_.Tool) -join '~' }) -join '||')
    if ($sig -ne $script:DecSig) { $script:DecSig = $sig; $script:DecCards = $cards; $changed = $true }
    $heading = Get-DecisionHeading $cards
    if ($decHead.Text -ne $heading) { $decHead.Text = $heading; $changed = $true }
    if ($cards.Count -eq 0 -and $lastDec.Text -ne $script:NoDecisionText) { $lastDec.Text = $script:NoDecisionText }
    $showCards = [bool]$cards.Count
    if ((Test-Shown $decArea) -ne $showCards) { Set-Shown $decArea $showCards; Set-Shown $lastDec (-not $showCards); $changed = $true }
    $showHead = [bool]$heading
    if ((Test-Shown $decHead) -ne $showHead) { Set-Shown $decHead $showHead; $changed = $true }
    if ($changed -and $script:LayoutReady) { Update-StepLayout }
}
# The block list for the displayed decisions (one record, or one per reviewed package). Nothing unless every one of them still
# matches a package in Incoming (checked on its bytes, which stay locked against writes meanwhile) and its record on disk.
function Get-VerifiedBlockList([string]$directory, [string]$reportsDir, $displayed) {
    $shown = @($displayed | Where-Object { $_ })
    if (-not $shown.Count) { return }
    foreach ($d in $shown) { if (-not (Get-DecisionInputHash $d)) { return } }
    $streams = New-Object System.Collections.Generic.List[IO.Stream]
    try {
        $files = @(Get-IncomingPackages $directory)
        $key = Get-IncomingPackageKey $files
        if (-not $key) { return }
        # Deny writes and replacement while checking the packages and rereading the displayed decisions.
        $hashes = @{}
        foreach ($f in $files) {
            if (-not (Get-IncomingFileKey $f)) { continue }
            $stream = [IO.File]::OpenRead($f.FullName)
            $streams.Add($stream)
            $hashes[[string](Get-FileHash -InputStream $stream -Algorithm SHA256 -ErrorAction Stop).Hash] = $true
        }
        $map = Read-DecisionMap $reportsDir
        $current = [ordered]@{}
        foreach ($d in $shown) {
            $h = [string](Get-DecisionInputHash $d)
            if (-not $hashes.ContainsKey($h) -or -not $map.ContainsKey($h)) { return }
            if ((Get-BlockListText $map[$h]) -cne (Get-BlockListText $d)) { return }
            $current[$h.ToLowerInvariant()] = $map[$h]
        }
        if ($key -ne (Get-IncomingPackageKey @(Get-IncomingPackages $directory))) { return }
        return (Get-CombinedBlockListText @($current.Values))
    } catch { $null = $_ } finally { foreach ($s in $streams) { $s.Dispose() } } # hash/read failure falls back to no block list
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

# One block list for several decisions: the union of their IOCs (senders, domains and hashes lower-cased), each value once, every section sorted. One record gives
# exactly Get-BlockListText.
function Get-CombinedBlockListText($records) {
    $recs = @($records | Where-Object { $_ })
    if ($recs.Count -eq 1) { return (Get-BlockListText $recs[0]) }
    $refang = { param($u) ([string]$u -replace '^hxxp', 'http' -replace '^fxp', 'ftp' -replace '\[\.\]', '.') }
    $newSet = { param($cmp) New-Object 'System.Collections.Generic.SortedSet[string]' $cmp }
    $spoof = & $newSet ([StringComparer]::OrdinalIgnoreCase); $senders = & $newSet ([StringComparer]::OrdinalIgnoreCase)
    $sdoms = & $newSet ([StringComparer]::OrdinalIgnoreCase); $doms = & $newSet ([StringComparer]::OrdinalIgnoreCase)
    $urls = & $newSet ([StringComparer]::Ordinal); $shas = & $newSet ([StringComparer]::OrdinalIgnoreCase)
    foreach ($d in $recs) {
        if ($d.spoof_pair -and [string]$d.final_decision -like 'Release*') { [void]$spoof.Add([string]$d.spoof_pair); continue }
        $io = $d.iocs
        if ($io.sender) { [void]$senders.Add(([string]$io.sender).ToLowerInvariant()) }
        if ($io.sender_domain) { [void]$sdoms.Add(([string]$io.sender_domain).ToLowerInvariant()) }
        foreach ($x in @($io.domains | Where-Object { $_ })) { [void]$doms.Add(([string]$x).ToLowerInvariant()) }
        foreach ($x in @($io.urls | Where-Object { $_ })) { [void]$urls.Add([string](& $refang $x)) }
        foreach ($x in @($io.sha256 | Where-Object { $_ })) { [void]$shas.Add(([string]$x).Split(' ')[0].ToLowerInvariant()) }
    }
    $newest = ($recs | ForEach-Object { [string]$_.recorded_local } | Sort-Object | Select-Object -Last 1)
    $L = @("# Block list from Quarantine Review Assistant - $($recs.Count) decisions, newest recorded $newest",
           '# Paste into Defender > Policies & rules > Threat policies > Tenant Allow/Block Lists (block).', '')
    if ($spoof.Count) { $L += '# SPOOF ALLOW PAIR (Tenant Allow/Block List > Spoofed senders > Add > Allow, External)'; $L += @($spoof); $L += '' }
    if ($senders.Count) { $L += '# Sender'; $L += @($senders); $L += '' }
    if ($sdoms.Count) { $L += '# Sender domain'; $L += @($sdoms); $L += '' }
    if ($doms.Count) { $L += '# Link domains (URLs tab)'; $L += @($doms); $L += '' }
    if ($urls.Count) { $L += '# Full URLs (live - do not click)'; $L += @($urls); $L += '' }
    if ($shas.Count) { $L += '# File SHA256 (Files tab)'; $L += @($shas) }
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
    $script:RunEnded = $false; $script:LaunchSnapshot = @{}; $script:ContinuedSig = $null
}

# What the launcher can observe right now. Incoming and Reports are read by their own refreshers (cached); only the
# Sandbox process list is queried here. Also advances the session state (Sandbox started or vanished, clean-up done).
function Get-LauncherFacts {
    $checks = @($script:Checks)
    $files = @($script:IncomingFiles | Where-Object { $_ })
    $incCount = $files.Count
    # a decision counts only for a package whose bytes (hashed in the background) equal its input_sha256
    $hashesCurrent = [bool]($script:IncomingHashKey -and $script:IncomingHashKey -eq (Get-IncomingPackageKey $files))
    $reviewed = @(if ($hashesCurrent) { Get-ReviewedPackages $files $script:IncomingHashes $script:DecisionMap })
    $decisionCurrent = ($reviewed.Count -gt 0)
    $partialContinued = [bool]($decisionCurrent -and $script:ContinuedSig -and $script:ContinuedSig -eq ('{0}/{1}' -f $reviewed.Count, $incCount))
    $acknowledged = $script:DecisionAcknowledged -and -not $optReports.Checked
    $running = (@(Get-SandboxProcess | Where-Object { $_ }).Count -gt 0)
    $checking = [bool]($script:ReadinessWork -or $script:Busy)

    # Sandbox lifecycle: Starting until a process appears; Vanished when it was seen, is gone, and the run left no decision that
    # was not already there at launch (an older decision for one of the files must not hide a failed run). Judged on every
    # tick after the close, so a decision that is still being verified is not reported as missing.
    if ($running) {
        $script:SandboxSeen = $true; $script:RunEnded = $false
        if ($script:LaunchState -ne 'None') { $script:LaunchState = 'None' }
    } elseif ($script:SandboxSeen) {
        $script:SandboxSeen = $false; $script:RunEnded = $true
    } elseif ($script:LaunchState -eq 'Starting' -and $script:LaunchStarted -and ((Get-Date) - $script:LaunchStarted).TotalSeconds -gt 120) {
        $script:LaunchState = 'Vanished'    # no Sandbox process ever appeared
    }
    if ($script:RunEnded -and -not $running) {
        $current = if ($hashesCurrent) { @($script:IncomingHashes.Values) } else { $null }
        $produced = Test-RunProducedDecision $script:DecisionMap $script:LaunchSnapshot $current
        $script:LaunchState = if ($produced -or $acknowledged) { 'None' } else { 'Vanished' }
    }

    # Clean-up: step 4 was done while Incoming had files, and now it is empty
    if ($script:CleanedUp -and $incCount -gt 0) { Reset-LauncherSession; $script:LastCurrent = 0 }     # a new download starts the next message (and may move the view forward again)
    elseif (-not $script:CleanedUp -and $script:Step4Seen -and $incCount -eq 0 -and -not $checking -and -not $script:IncomingReadFailed) { $script:CleanedUp = $true }
    $script:Step4Seen = ($incCount -gt 0) -and (($decisionCurrent -and ($reviewed.Count -ge $incCount -or $partialContinued)) -or $acknowledged)

    @{
        ChecksRunning = $checking
        BlockingCount = @($checks | Where-Object { $_.Blocking -and $_.Status -ne 'OK' }).Count
        WarnCount = @($checks | Where-Object { $_.Status -eq 'WARN' }).Count
        DefenderChecked = [bool]$script:DefenderChecked
        IncomingCount = $incCount
        DecisionCurrent = $decisionCurrent
        ReviewedCount = $reviewed.Count
        Reviewed = $reviewed
        PartialContinued = $partialContinued
        CheckSeconds = $(if ($script:ReadinessWork) { [int]([DateTime]::UtcNow - $script:ReadinessWork.Started).TotalSeconds } else { $null })
        LaunchSeconds = $(if ($script:LaunchState -eq 'Starting' -and $script:LaunchStarted) { [int]((Get-Date) - $script:LaunchStarted).TotalSeconds } else { $null })
        DecisionText = $(if ($reviewed.Count -eq 1) { [string]$reviewed[0].Decision.final_decision } else { '' })
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
    $script:Reviewed = @($Facts.Reviewed | Where-Object { $_ })
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

    # step 4: the secondary button and the launch status line. With some (not all) packages reviewed it continues to step 5 with
    # those decisions; with report export off it is the "I've recorded my decision" button.
    $nRev = [int]$Facts.ReviewedCount; $nInc = [int]$Facts.IncomingCount
    $script:LastReviewedSig = '{0}/{1}' -f $nRev, $nInc
    $idle = (-not $Facts.SandboxRunning -and $Facts.LaunchState -ne 'Starting')
    $partial = ([bool]$Facts.ExportOn -and $nRev -gt 0 -and $nRev -lt $nInc -and $idle -and -not $Facts.PartialContinued)
    $script:AckPartial = $partial
    $ackText = if ($partial) { "Continue with $nRev decision(s)" } else { "I've recorded my decision - next" }
    if ($bAck.Text -ne $ackText) {
        $bAck.Text = $ackText
        Set-Access $bAck $(if ($partial) { "Continue to the next step with the $nRev decision(s) recorded so far" } else { "I've recorded my decision in the Sandbox, go to the next step" })
    }
    Set-Shown $bAck ($partial -or -not [bool]$Facts.ExportOn)
    $text = ''; $color = $C.TextMuted; $spin = $false
    if ([int]$Facts.BlockingCount -gt 0 -and -not $Facts.ChecksRunning) { $text = 'Complete step 1 (PC readiness) first.' }
    elseif ($Facts.SandboxRunning) { $text = 'Review in progress. Record your decision in the Sandbox, then come back here.'; $color = $C.Text; $spin = $true }
    elseif ($Facts.LaunchState -eq 'Starting') { $text = 'Starting... the review window opens inside the Sandbox in 20-60 s.'; $color = $C.Text; $spin = $true }
    elseif ($partial) {
        $text = 'Review the rest in the Sandbox (launch it again), or continue to step 5 with the decisions you have.'
        $color = $C.Text
        if ($Facts.LaunchState -eq 'Vanished') { $text = 'The Sandbox closed without a new decision. ' + $text; $color = $C.Warning }
    }
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
$bShortcut.Add_Click({ Invoke-CreateDesktopShortcut })
$bChecked.Add_Click({ $script:DefenderChecked = $true; Update-Stepper; Select-LauncherStep 3 })
$bAck.Add_Click({
    if ($script:AckPartial) { $script:ContinuedSig = $script:LastReviewedSig } else { $script:DecisionAcknowledged = $true }
    Update-Stepper; Select-LauncherStep 5
})
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
    $text = Get-VerifiedBlockList $Incoming $Reports @($script:Reviewed | ForEach-Object { $_.Decision })
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
        $script:RunEnded = $false; $script:ContinuedSig = $null
        $script:LaunchSnapshot = Get-DecisionSnapshot $script:DecisionMap     # what was decided before this run
        Update-Stepper
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Could not start Windows Sandbox:`r`n$($_.Exception.Message)`r`n`r`nTry again with 'Compatibility mode' selected.", 'Launch failed', 'OK', 'Error') | Out-Null
    }
})

$checksPanel.Add_Resize({ if ($script:LayoutReady -and -not $script:QraDpiBusy) { Use-QraFormDpi $form; foreach ($ctl in $checksPanel.Controls) { $ctl.Width = [Math]::Max((S 380), $checksPanel.ClientSize.Width - (S 24)); Fit-CheckRow $ctl } } })
if (-not $Screenshot) { $form.Add_Shown({
    Close-LauncherSplash
    # The console is hidden, so this process may have lost the right to come to the front: ask for it explicitly.
    try { $form.Activate(); $form.TopMost = $true; $form.TopMost = $false; $form.BringToFront() } catch { $null = $_ } # cosmetic
    $form.Refresh()
    [void](Test-ConfigChanged $ConfigFile ([ref]$script:ConfigStamp))
    Refresh-Incoming        # Incoming and Reports first, so the first readiness result already lands on the right step
    Refresh-LastDecision
    Start-ReadinessRefresh
    $incomingTimer.Start(); $waitTimer.Start()
    Update-StepLayout
}) }
$form.Add_FormClosing({
    Exit-LauncherMutex
    Close-LauncherSplash -Wait   # normally gone long ago
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
        DecisionCurrent = $false; ReviewedCount = 0; Reviewed = @(); DecisionText = ''; SandboxRunning = $false; LaunchState = 'None'; ExportOn = $true
        DecisionAcknowledged = $false; CleanedUp = $false
    }
    $withFile = @{ DefenderChecked = $true; IncomingCount = 1 }
    $shotFile2 = [pscustomobject]@{ Name = 'Quarantined Messages (2).zip'; Length = 36864; LastWriteTime = $shotTime.AddMinutes(-3); Extension = '.zip' }
    $shotDecision2 = [pscustomobject]@{
        record_complete = $true; input_sha256 = ('b' * 64)
        recorded_local = '2026-11-25 11:06'; final_decision = 'Release'; sender = 'newsletter@news-digest.example'
        subject = 'Weekly digest'; tool_recommendation = 'Likely safe'; confidence = 'Medium'; microsoft_verdict = 'Bulk'
        iocs = [pscustomobject]@{ sender = ''; sender_domain = ''; domains = @(); urls = @(); sha256 = @() }
    }
    $twoFiles = @{ DefenderChecked = $true; IncomingCount = 2 }
    $shotMany = @('Quarantined Messages (3).zip', 'Quarantined Messages (4).zip', 'Quarantined Messages (5) with a very long file name for the ellipsis check - long.zip', 'Quarantined Messages (6).zip', 'Quarantined Messages (7).zip') |
        ForEach-Object { [pscustomobject]@{ Name = $_; Length = 20480; LastWriteTime = $shotTime; Extension = '.zip' } }
    $shotLong = [pscustomobject]@{
        record_complete = $true; input_sha256 = ('c' * 64)
        recorded_local = '2026-11-25 11:20'; final_decision = 'Release (false positive, submitted to Microsoft)'; sender = 'accounts-payable-notifications@a-rather-long-sender-domain.example'
        subject = 'Re: Fwd: Updated remittance advice for purchase order 77120-B, please confirm the new bank details before Friday'; tool_recommendation = 'Likely safe'; confidence = 'Medium'; microsoft_verdict = 'No threat found'
        iocs = [pscustomobject]@{ sender = ''; sender_domain = ''; domains = @(); urls = @(); sha256 = @() }
    }
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
        'two-files-one-reviewed' = @{ Checks = $shotOk; Files = @($shotFile, $shotFile2); Decision = $shotDecision
            Reviewed = @([pscustomobject]@{ FileName = $shotFile.Name; Decision = $shotDecision })
            Facts = $twoFiles + @{ DecisionCurrent = $true; ReviewedCount = 1; DecisionText = 'Delete and block' }; Select = 4 }
        'two-files-reviewed' = @{ Checks = $shotOk; Files = @($shotFile, $shotFile2); Decision = $shotDecision
            Reviewed = @([pscustomobject]@{ FileName = $shotFile.Name; Decision = $shotDecision }, [pscustomobject]@{ FileName = $shotFile2.Name; Decision = $shotDecision2 })
            Facts = $twoFiles + @{ DecisionCurrent = $true; ReviewedCount = 2 }; Select = 5 }
        'stale-decision'     = @{ Checks = $shotOk; Files = @($shotFile2); Decision = $shotDecision
            Facts = $withFile + @{ DecisionCurrent = $false }; Select = 5 }
        'many-decisions'     = @{ Checks = $shotOk; Files = $shotMany; Decision = $shotDecision
            Reviewed = @($shotMany[0..3] | ForEach-Object { [pscustomobject]@{ FileName = $_.Name; Decision = $(if ($_.Name -like '*long*') { $shotLong } else { $shotDecision2 }) } })
            Facts = @{ DefenderChecked = $true; IncomingCount = 5; DecisionCurrent = $true; ReviewedCount = 4 }; Select = 5 }
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
        $facts.Reviewed = @($sd.Reviewed)
        if ($facts.DecisionCurrent -and -not $sd.Reviewed) { $facts.Reviewed = @([pscustomobject]@{ FileName = $shotFile.Name; Decision = $sd.Decision }); $facts.ReviewedCount = 1 }
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
# ShowDialog() with no owner adopts the active window, which is the splash: closing the splash would then close the launcher.
# An owner whose handle is zero means "no owner". Without that object (restricted language mode) the splash goes first.
$noOwner = $null
try { $noOwner = New-Object System.Windows.Forms.NativeWindow } catch { $noOwner = $null } # restricted language mode
if ($noOwner) { [void]$form.ShowDialog($noOwner) } else { Close-LauncherSplash; [void]$form.ShowDialog() }
