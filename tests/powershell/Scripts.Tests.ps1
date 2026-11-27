#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Pester 5. Run from the repo root:  Invoke-Pester tests/powershell

BeforeDiscovery {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $ps1Files = Get-ChildItem -LiteralPath $repo -Recurse -Filter '*.ps1' -File |
        Where-Object { $_.FullName -notmatch '[\\/](\.venv|dist|\.git|node_modules|\.superpowers)[\\/]' } |
        ForEach-Object { @{ Name = $_.FullName.Substring($repo.Length + 1); Path = $_.FullName } }
    $runtimePs1 = Get-ChildItem -LiteralPath (Join-Path $repo 'src\SecurityReview') -Recurse -Filter '*.ps1' -File |
        ForEach-Object { @{ Name = $_.FullName.Substring($repo.Length + 1); Path = $_.FullName } }
    $runtimeCmd = Get-ChildItem -LiteralPath (Join-Path $repo 'src\SecurityReview') -Filter '*.cmd' -File |
        ForEach-Object { @{ Name = $_.FullName.Substring($repo.Length + 1); Path = $_.FullName } }
}

BeforeAll {
    $script:Repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:Src = Join-Path $script:Repo 'src\SecurityReview'
}

Describe 'PowerShell scripts' {
    It '<Name> parses without errors' -ForEach $ps1Files {
        $tokens = $null; $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }
}

Describe 'Runtime file encoding (the launcher and Windows PowerShell 5.1 depend on it)' {
    It '<Name> has CRLF line endings and a UTF-8 BOM' -ForEach $runtimePs1 {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $bytes[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
        $text = [System.Text.Encoding]::UTF8.GetString($bytes)
        $text | Should -Not -Match "(?<!`r)`n"
    }
    It '<Name> has CRLF line endings' -ForEach $runtimeCmd {
        $text = [System.IO.File]::ReadAllText($Path)
        $text | Should -Not -Match "(?<!`r)`n"
    }
}

Describe 'Version numbers' {
    BeforeAll {
        function Get-AppVersion($file) {
            $m = Select-String -LiteralPath $file -Pattern "^\`$AppVersion\s*=\s*'([^']+)'" | Select-Object -First 1
            if ($m) { $m.Matches[0].Groups[1].Value }
        }
        $script:Versions = [ordered]@{
            'Launcher.ps1 $AppVersion'         = Get-AppVersion (Join-Path $script:Src 'app\Launcher.ps1')
            'QuarantineReview.ps1 $AppVersion' = Get-AppVersion (Join-Path $script:Src 'app\QuarantineReview.ps1')
            'inspect_eml.py VERSION'           = (Select-String -LiteralPath (Join-Path $script:Src 'app\inspect_eml.py') -Pattern "^VERSION = '([^']+)'").Matches[0].Groups[1].Value
            'src README.md title'              = (Select-String -LiteralPath (Join-Path $script:Src 'README.md') -Pattern '^# Quarantine Review Assistant v(\S+)').Matches[0].Groups[1].Value
            'root README.md title'             = (Select-String -LiteralPath (Join-Path $script:Repo 'README.md') -Pattern '^# Quarantine Review Assistant v(\S+)').Matches[0].Groups[1].Value
            'CHANGELOG.md latest entry'        = (Select-String -LiteralPath (Join-Path $script:Repo 'CHANGELOG.md') -Pattern '^## \[(\d+\.\d+\.\d+)\]' | Select-Object -First 1).Matches[0].Groups[1].Value
        }
    }
    It 'every version source can be read' {
        foreach ($k in $script:Versions.Keys) { $script:Versions[$k] | Should -Not -BeNullOrEmpty -Because $k }
    }
    It 'all version numbers are identical' {
        $distinct = @($script:Versions.Values | Sort-Object -Unique)
        $detail = ($script:Versions.GetEnumerator() | ForEach-Object { "$($_.Key) = $($_.Value)" }) -join '; '
        $distinct.Count | Should -Be 1 -Because $detail
    }
}

Describe 'build-release.ps1' {
    BeforeAll {
        $script:Out = Join-Path ([System.IO.Path]::GetTempPath()) ('qra-build-' + [guid]::NewGuid().ToString('N'))
        $script:Result = & (Join-Path $script:Repo 'tools\build-release.ps1') -OutDir $script:Out
    }
    AfterAll { Remove-Item -LiteralPath $script:Out -Recurse -Force -ErrorAction SilentlyContinue }

    It 'writes the ZIP and its SHA256 file' {
        $script:Result.Zip | Should -Exist
        ($script:Result.Zip + '.sha256') | Should -Exist
        (Get-Content -LiteralPath ($script:Result.Zip + '.sha256') -Raw) | Should -Match $script:Result.Sha256
    }
    It 'contains only the runtime files and distribution notices' {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($script:Result.Zip)
        try { $names = @($zip.Entries | ForEach-Object { $_.FullName } | Sort-Object) } finally { $zip.Dispose() }
        $expected = @('SecurityReview/Start-Here.cmd', 'SecurityReview/Start-Review.cmd', 'SecurityReview/README.md',
            'SecurityReview/LICENSE', 'SecurityReview/THIRD_PARTY_NOTICES.md',
            'SecurityReview/app/Launcher.ps1', 'SecurityReview/app/QuarantineReview.ps1', 'SecurityReview/app/Enable-Sandbox.ps1', 'SecurityReview/app/QraUi.ps1', 'SecurityReview/app/ReleaseRequests.ps1',
            'SecurityReview/app/inspect_eml.py', 'SecurityReview/app/assets/splash.jpg', 'SecurityReview/Incoming/PLACE_ZIP_HERE.txt') | Sort-Object
        $names | Should -Be $expected
    }
    It 'ships the repository license and third-party notices verbatim' {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($script:Result.Zip)
        try {
            foreach ($name in 'LICENSE', 'THIRD_PARTY_NOTICES.md') {
                $entry = $zip.GetEntry("SecurityReview/$name")
                $entry | Should -Not -BeNullOrEmpty
                $stream = $entry.Open()
                $memory = New-Object System.IO.MemoryStream
                try {
                    $stream.CopyTo($memory)
                    [Convert]::ToBase64String($memory.ToArray()) | Should -BeExactly ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $script:Repo $name))))
                } finally { $memory.Dispose(); $stream.Dispose() }
            }
        } finally { $zip.Dispose() }
    }
}

Describe 'Start-Here.cmd' {
    BeforeAll {
        $script:CmdPath = Join-Path $script:Src 'Start-Here.cmd'
        $script:CmdText = [System.IO.File]::ReadAllText($script:CmdPath)
        $script:StartLine = 'start "" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0app\Launcher.ps1"'
    }
    It 'starts the launcher with the exact minimised start line' {
        @($script:CmdText -split '\r?\n' | Where-Object { $_ -eq $script:StartLine }).Count | Should -Be 1
    }
    It 'never hides the window with -WindowStyle Hidden (a classic malware indicator)' {
        $script:CmdText | Should -Not -Match '(?i)-WindowStyle'
        $script:CmdText | Should -Not -Match '(?i)\bhidden\b' -Because 'the comment lines do not promise a hidden window either'
    }
    It 'keeps its comment lines accurate: they describe /min, not a hidden window' {
        $script:CmdText | Should -Match 'start /min'
        $script:CmdText | Should -Match 'minimised'
    }
}

Describe 'Runtime files: no dynamic P/Invoke or assembly emission' {
    # Reflection.Emit P/Invoke is the PSReflect/PowerSploit pattern: AMSI, Defender and EDR products flag it, which a security tool must never trigger. Use Add-Type.
    It '<Name> contains none of DefinePInvokeMethod, DefineDynamicAssembly, AssemblyBuilder, TypeBuilder, Reflection.Emit' -ForEach (Get-ChildItem -LiteralPath (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src') -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.cmd', '.py' } | ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }) {
        [System.IO.File]::ReadAllText($Path) | Should -Not -Match 'DefinePInvokeMethod|DefineDynamicAssembly|AssemblyBuilder|TypeBuilder|Reflection\.Emit'
    }
}
