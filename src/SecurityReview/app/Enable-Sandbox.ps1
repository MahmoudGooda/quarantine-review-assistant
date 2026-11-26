# Quarantine Review Assistant - elevated helper.
# Turns on the Windows Sandbox optional feature. Started by Launcher.ps1 through a UAC prompt.
# It changes nothing else and never restarts the PC by itself.
param([Parameter(Mandatory = $true)][string]$ResultFile)

$Host.UI.RawUI.WindowTitle = 'Quarantine Review Assistant - enabling Windows Sandbox'
Write-Host ''
Write-Host '  Enabling the Windows Sandbox feature (Containers-DisposableClientVM)...' -ForegroundColor Cyan
Write-Host '  This can take one to three minutes. Please do not close this window.'
Write-Host ''

$result = [ordered]@{ ok = $false; restartNeeded = $false; message = '' }
try {
    $feature = Enable-WindowsOptionalFeature -Online -FeatureName 'Containers-DisposableClientVM' -All -NoRestart -ErrorAction Stop
    $result.ok = $true
    $result.restartNeeded = [bool]$feature.RestartNeeded
    $result.message = 'Windows Sandbox feature enabled.'
    Write-Host '  Done.' -ForegroundColor Green
} catch {
    $result.message = $_.Exception.Message
    Write-Host ('  FAILED: ' + $_.Exception.Message) -ForegroundColor Red
    Start-Sleep -Seconds 4
}
try {
    ($result | ConvertTo-Json -Compress) | Set-Content -LiteralPath $ResultFile -Encoding UTF8
} catch {
    Write-Host ('  Could not write result file: ' + $_.Exception.Message) -ForegroundColor Red
    Start-Sleep -Seconds 6
}
