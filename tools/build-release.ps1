# Builds dist\QuarantineReviewAssistant-<version>.zip from src\SecurityReview and writes its SHA256.
# The ZIP contains the runtime files and distribution notices under a top-level "SecurityReview" folder.
# Works in Windows PowerShell 5.1 and PowerShell 7. Entry names always use "/" and timestamps are fixed,
# so the same sources give the same ZIP when built with the same PowerShell version.
[CmdletBinding()]
param(
    [string]$OutDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist')
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$repo = Split-Path -Parent $PSScriptRoot
$src = Join-Path $repo 'src\SecurityReview'

# The release allow-list: nothing else is ever packed (no reports, profiles, tools, samples or caches).
$runtimeFiles = @(
    'Start-Here.cmd', 'Start-Review.cmd', 'README.md',
    'app\Launcher.ps1', 'app\QuarantineReview.ps1', 'app\Enable-Sandbox.ps1', 'app\QraUi.ps1', 'app\ReleaseRequests.ps1', 'app\inspect_eml.py',
    'Incoming\PLACE_ZIP_HERE.txt'
)
$releaseFiles = [ordered]@{}
foreach ($rel in $runtimeFiles) { $releaseFiles[$rel] = Join-Path $src $rel }
foreach ($rel in 'LICENSE', 'THIRD_PARTY_NOTICES.md') { $releaseFiles[$rel] = Join-Path $repo $rel }

$version = $null
foreach ($line in Get-Content -LiteralPath (Join-Path $src 'app\Launcher.ps1') -Encoding UTF8) {
    if ($line -match "^\`$AppVersion\s*=\s*'([^']+)'") { $version = $Matches[1]; break }
}
if (-not $version) { throw 'Could not read $AppVersion from Launcher.ps1.' }

# Line endings and BOMs are part of the contract (Windows PowerShell 5.1 needs the BOM for non-ASCII text).
foreach ($rel in $releaseFiles.Keys) {
    $path = $releaseFiles[$rel]
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing release file: $rel" }
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    $hasLf = $text -match "(?<!`r)`n"
    $hasCrlf = $text.Contains("`r`n")
    if ($rel -match '\.(cmd|ps1)$' -and ($hasLf -or -not $hasCrlf)) { throw "$rel must use CRLF line endings." }
    if (($rel -eq 'LICENSE' -or $rel -match '\.(py|md)$') -and $hasCrlf) { throw "$rel must use LF line endings." }
    if ($rel -match '\.ps1$') {
        $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        if (-not $bom) { throw "$rel lost its UTF-8 BOM." }
    }
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$zipPath = Join-Path $OutDir "QuarantineReviewAssistant-$version.zip"
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

$stamp = New-Object System.DateTimeOffset(2026, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
$fs = [System.IO.File]::Open($zipPath, [System.IO.FileMode]::CreateNew)
try {
    $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create, $false)
    try {
        foreach ($rel in $releaseFiles.Keys) {
            $entry = $zip.CreateEntry('SecurityReview/' + ($rel -replace '\\', '/'), [System.IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = $stamp
            $in = [System.IO.File]::OpenRead($releaseFiles[$rel])
            $out = $entry.Open()
            try { $in.CopyTo($out) } finally { $out.Dispose(); $in.Dispose() }
        }
    }
    finally { $zip.Dispose() }
}
finally { $fs.Dispose() }

$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$shaPath = $zipPath + '.sha256'
[System.IO.File]::WriteAllText($shaPath, "$hash  $(Split-Path -Leaf $zipPath)`n", (New-Object System.Text.UTF8Encoding($false)))

[pscustomobject]@{ Version = $version; Zip = $zipPath; Sha256 = $hash; Files = $releaseFiles.Count }
