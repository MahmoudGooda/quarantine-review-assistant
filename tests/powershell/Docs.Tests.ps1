#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Pester 5. Run from the repo root:  Invoke-Pester tests/powershell/Docs.Tests.ps1

BeforeAll {
    $script:Repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:Src = Join-Path $script:Repo 'src\SecurityReview'
    $script:Doc = Join-Path $script:Repo 'docs\for-security-teams.md'

    # URLs that appear in runtime files but are NOT network calls made by the tool. Each needs a reason.
    $script:DocumentationLinksOnly = @(
        # Microsoft Learn page shown as help text in the intake dialog; the user opens it in a browser.
        'https://learn.microsoft.com/defender-office-365/quarantine-admin-manage-messages-files'
        # The Defender quarantine page the Start-Process call opens in the user's browser (also listed in the doc).
        'https://security.microsoft.com/quarantine'
    )

    function Get-NetworkSection([string]$text) {
        $m = [regex]::Match($text, '(?ms)^## Network calls\s*$(.*?)(?=^## |\z)')
        if ($m.Success) { $m.Groups[1].Value } else { '' }
    }

    function Get-RuntimeUrls {
        $files = Get-ChildItem -LiteralPath $script:Src -Recurse -File |
            Where-Object { $_.Extension -in '.ps1', '.py', '.cmd' -and $_.FullName -notmatch '[\\/]__pycache__[\\/]' }
        foreach ($f in $files) {
            $text = [System.IO.File]::ReadAllText($f.FullName)
            foreach ($m in [regex]::Matches($text, 'https?://[A-Za-z0-9][^\s''"`<>)\]}]*')) {
                [pscustomobject]@{ File = $f.Name; Url = $m.Value.TrimEnd('.', ',', ';') }
            }
        }
    }
}

Describe 'Security-team documentation' {
    It 'docs/for-security-teams.md exists' {
        Test-Path -LiteralPath $script:Doc | Should -BeTrue
    }

    It 'README.md and SECURITY.md link to it' {
        foreach ($name in 'README.md', 'SECURITY.md') {
            $text = [System.IO.File]::ReadAllText((Join-Path $script:Repo $name))
            $text | Should -Match ([regex]::Escape('docs/for-security-teams.md'))
        }
    }

    It 'has a parseable "## Network calls" section with backticked URLs or hosts' {
        $section = Get-NetworkSection ([System.IO.File]::ReadAllText($script:Doc))
        $section | Should -Not -BeNullOrEmpty
        @($section -split '\r?\n' | Where-Object { $_ -match '^- .*`[^`\n]+`' }).Count | Should -BeGreaterThan 2
    }

    It 'Network URLs are documented' {
        $section = Get-NetworkSection ([System.IO.File]::ReadAllText($script:Doc))
        $undocumented = @(Get-RuntimeUrls | Where-Object {
            $url = $_.Url
            -not $section.Contains($url) -and ($script:DocumentationLinksOnly -notcontains $url)
        } | ForEach-Object { "$($_.File): $($_.Url)" } | Sort-Object -Unique)
        $undocumented | Should -BeNullOrEmpty -Because 'every URL in a runtime file must be listed under "## Network calls" in docs/for-security-teams.md or in $DocumentationLinksOnly with a reason'
    }

    It 'quotes the Start-Here.cmd start line exactly' {
        $cmdLines = @([System.IO.File]::ReadAllText((Join-Path $script:Src 'Start-Here.cmd')) -split '\r?\n' | Where-Object { $_ -match '^start ' })
        $cmdLines.Count | Should -Be 1
        $text = [System.IO.File]::ReadAllText($script:Doc)
        $fence = [regex]::Match($text, '(?ms)Start-Here\.cmd` contains this line:\s*```\r?\n(.*?)\r?\n```')
        $fence.Success | Should -BeTrue
        $fence.Groups[1].Value | Should -Be $cmdLines[0]
    }

    It 'the documented download URL is still the one the launcher uses' {
        $launcher = [System.IO.File]::ReadAllText((Join-Path $script:Src 'app\Launcher.ps1'))
        $m = [regex]::Match($launcher, "\`$PyUrl\s*=\s*'([^']+)'")
        $m.Success | Should -BeTrue
        (Get-NetworkSection ([System.IO.File]::ReadAllText($script:Doc))).Contains($m.Groups[1].Value) | Should -BeTrue
    }
}
