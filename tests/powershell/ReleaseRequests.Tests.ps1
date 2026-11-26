#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Pester 5. Release-request intake (src/SecurityReview/app/ReleaseRequests.ps1). The Exchange Online cmdlets are stubbed as global
# functions (CI has no ExchangeOnlineManagement module) and mocked. Dialog behaviour runs in a child Windows PowerShell 5.1 process.

BeforeAll {
    $script:Repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:RrPath = Join-Path $script:Repo 'src\SecurityReview\app\ReleaseRequests.ps1'
    $script:KitPath = Join-Path $script:Repo 'src\SecurityReview\app\QraUi.ps1'
    $script:TestPath = $PSCommandPath
    $script:Sentinel = 'SENTINEL-7f3a'
    $script:PwSentinel = 'Sentinel-Pw-7f3a'
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    . $script:KitPath

    # The EXO cmdlets do not exist on CI: global stubs first, so Mock has something to replace.
    function global:Initialize-RrStubs {
        function global:Get-QuarantineMessage { [CmdletBinding()] param($ReleaseStatus, $PageSize, $StartReceivedDate, $EndReceivedDate, $RecipientAddress) }
        function global:Export-QuarantineMessage { [CmdletBinding()] param($Identity, [switch]$CompressOutput, [securestring]$Password, $ReasonForExport) }
        function global:Connect-ExchangeOnline { [CmdletBinding()] param([switch]$ShowBanner) }
        function global:Disconnect-ExchangeOnline { [CmdletBinding()] param([switch]$Confirm) }
    }
    Initialize-RrStubs
    . $script:RrPath

    # Runs a script text in a fresh Windows PowerShell 5.1 child process and returns its output lines.
    function Invoke-ChildPs([string]$Body) {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ('qra-rr-test-' + [guid]::NewGuid().ToString('N') + '.ps1')
        try {
            [IO.File]::WriteAllText($tmp, $Body, (New-Object Text.UTF8Encoding($true)))
            $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tmp 2>&1
            @($out | ForEach-Object { "$_" })
        } finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
    }
    function Get-ChildJson($lines) {
        $json = @($lines | Where-Object { $_ -like '{*' }) | Select-Object -Last 1
        if (-not $json) { throw ('child printed no JSON: ' + ($lines -join ' | ')) }
        $json | ConvertFrom-Json
    }

    # A hand-made ZIP: local headers, central directory, end record. Flags are the general-purpose bit flags per entry.
    function New-TestZip {
        param([int[]]$Flags = @(1), [switch]$Aes, [switch]$NoEocd, [string]$EntryName = 'SENTINEL-7f3a-entry-name.eml',
            [string]$Comment = 'SENTINEL-7f3a-entry-comment', [string]$Content = 'SENTINEL-7f3a-content-bytes', [string]$ZipComment = 'SENTINEL-7f3a-zip-comment')
        $enc = [System.Text.Encoding]::ASCII
        $name = $enc.GetBytes($EntryName); $com = $enc.GetBytes($Comment); $data = $enc.GetBytes($Content)
        $extra = New-Object byte[] 0
        $method = 0
        if ($Aes) { $extra = [byte[]](0x01, 0x99, 0x07, 0x00, 0x02, 0x00, 0x41, 0x45, 0x03, 0x08, 0x00); $method = 99 }
        $ms = New-Object System.IO.MemoryStream
        $bw = New-Object System.IO.BinaryWriter($ms)
        $offsets = @()
        foreach ($fl in $Flags) {
            $offsets += [int]$ms.Position
            $bw.Write([uint32]0x04034b50); $bw.Write([uint16]20); $bw.Write([uint16]$fl); $bw.Write([uint16]$method)
            $bw.Write([uint16]0); $bw.Write([uint16]0); $bw.Write([uint32]0); $bw.Write([uint32]$data.Length); $bw.Write([uint32]$data.Length)
            $bw.Write([uint16]$name.Length); $bw.Write([uint16]$extra.Length); $bw.Write($name); $bw.Write($extra); $bw.Write($data)
        }
        $cdStart = [int]$ms.Position
        for ($i = 0; $i -lt $Flags.Count; $i++) {
            $bw.Write([uint32]0x02014b50); $bw.Write([uint16]63); $bw.Write([uint16]20); $bw.Write([uint16]$Flags[$i]); $bw.Write([uint16]$method)
            $bw.Write([uint16]0); $bw.Write([uint16]0); $bw.Write([uint32]0); $bw.Write([uint32]$data.Length); $bw.Write([uint32]$data.Length)
            $bw.Write([uint16]$name.Length); $bw.Write([uint16]$extra.Length); $bw.Write([uint16]$com.Length)
            $bw.Write([uint16]0); $bw.Write([uint16]0); $bw.Write([uint32]0); $bw.Write([uint32]$offsets[$i])
            $bw.Write($name); $bw.Write($extra); $bw.Write($com)
        }
        $cdSize = [int]$ms.Position - $cdStart
        if (-not $NoEocd) {
            $zc = $enc.GetBytes($ZipComment)
            $bw.Write([uint32]0x06054b50); $bw.Write([uint16]0); $bw.Write([uint16]0); $bw.Write([uint16]$Flags.Count); $bw.Write([uint16]$Flags.Count)
            $bw.Write([uint32]$cdSize); $bw.Write([uint32]$cdStart); $bw.Write([uint16]$zc.Length); $bw.Write($zc)
        }
        $bw.Flush()
        , $ms.ToArray()
    }
    function New-PlainZip {
        $ms = New-Object System.IO.MemoryStream
        $zip = New-Object System.IO.Compression.ZipArchive($ms, [System.IO.Compression.ZipArchiveMode]::Create, $true)
        $entry = $zip.CreateEntry('SENTINEL-7f3a-plain.eml')
        $sw = New-Object System.IO.StreamWriter($entry.Open())
        $sw.Write('From: a@b.example'); $sw.Dispose(); $zip.Dispose()
        , $ms.ToArray()
    }
    function New-SecurePw([string]$text) {
        $ss = New-Object System.Security.SecureString
        foreach ($ch in $text.ToCharArray()) { $ss.AppendChar($ch) }
        $ss.MakeReadOnly()
        $ss
    }
    function New-FakeMessage([int]$n) {
        [pscustomobject]@{
            Identity = "00000000-0000-4000-8000-00000000000$n\00000000-0000-4000-8000-0000000000a$n"
            ReceivedTime = ([datetime]'2026-11-25 08:10').AddMinutes($n); SenderAddress = "billing$n@invoice-pay.example"
            RecipientAddress = @('a@corp.example', 'b@corp.example'); Subject = "Invoice $n"; QuarantineTypes = 'HighConfPhish'
            Expires = [datetime]'2026-12-25'
        }
    }
    function Start-RrWatch([string[]]$Paths) {
        $id = [guid]::NewGuid().ToString('N')
        $ws = @()
        foreach ($p in $Paths) {
            $w = New-Object System.IO.FileSystemWatcher $p
            $w.IncludeSubdirectories = $true
            foreach ($ev in 'Created', 'Renamed') { [void](Register-ObjectEvent -InputObject $w -EventName $ev -SourceIdentifier "rrw-$id-$ev-$($ws.Count)") }
            $w.EnableRaisingEvents = $true
            $ws += $w
        }
        @{ Id = $id; Watchers = $ws }
    }
    function Stop-RrWatch($watch) {
        Start-Sleep -Milliseconds 800
        $names = @(Get-Event | Where-Object { $_.SourceIdentifier -like "rrw-$($watch.Id)-*" } | ForEach-Object { [string]$_.SourceEventArgs.Name })
        foreach ($e in @(Get-Event | Where-Object { $_.SourceIdentifier -like "rrw-$($watch.Id)-*" })) { Remove-Event -EventIdentifier $e.EventIdentifier -ErrorAction SilentlyContinue }
        foreach ($sub in @(Get-EventSubscriber | Where-Object { $_.SourceIdentifier -like "rrw-$($watch.Id)-*" })) { Unregister-Event -SubscriptionId $sub.SubscriptionId -ErrorAction SilentlyContinue }
        foreach ($w in $watch.Watchers) { $w.Dispose() }
        , $names
    }
}

AfterAll {
    foreach ($n in 'Get-QuarantineMessage', 'Export-QuarantineMessage', 'Connect-ExchangeOnline', 'Disconnect-ExchangeOnline', 'Initialize-RrStubs') {
        Remove-Item "function:global:$n" -ErrorAction SilentlyContinue
    }
}

Describe 'ReleaseRequests: listing' {
    It 'asks for requested releases, page size 1000, with the date window and no recipient by default' {
        Mock Get-QuarantineMessage { }
        $now = [datetime]'2026-11-26 12:00'
        $p = Get-RrQuarantineParams -Days 0 -Recipient '' -Now $now
        $p.ReleaseStatus | Should -Be 'Requested'
        $p.PageSize | Should -Be 1000
        $p.EndReceivedDate | Should -Be $now
        $p.StartReceivedDate | Should -Be $now.AddDays(-16)
        $p.ContainsKey('RecipientAddress') | Should -BeFalse
        $null = @(Get-RrRequests -Now $now)
        Should -Invoke Get-QuarantineMessage -Times 1 -Exactly -ParameterFilter {
            $ReleaseStatus -eq 'Requested' -and $PageSize -eq 1000 -and $StartReceivedDate -eq $now.AddDays(-16) -and $EndReceivedDate -eq $now -and -not $RecipientAddress
        }
    }
    It 'clamps the window to 1..30 days and defaults to 16' {
        Get-RrWindowDays 0 | Should -Be 16
        Get-RrWindowDays 1 | Should -Be 1
        Get-RrWindowDays 30 | Should -Be 30
        Get-RrWindowDays 31 | Should -Be 30
        Get-RrWindowDays 400 | Should -Be 30
        Get-RrWindowDays -5 | Should -Be 1
        $now = [datetime]'2026-11-26 12:00'
        (Get-RrQuarantineParams -Days 99 -Recipient '' -Now $now).StartReceivedDate | Should -Be $now.AddDays(-30)
    }
    It 'adds the recipient filter only when it is not blank, trimmed' {
        Mock Get-QuarantineMessage { }
        $now = [datetime]'2026-11-26 12:00'
        (Get-RrQuarantineParams -Days 5 -Recipient '   ' -Now $now).ContainsKey('RecipientAddress') | Should -BeFalse
        (Get-RrQuarantineParams -Days 5 -Recipient '  a.rivera@corp.example ' -Now $now).RecipientAddress | Should -Be 'a.rivera@corp.example'
        $null = @(Get-RrRequests -Days 5 -Recipient ' a.rivera@corp.example ' -Now $now)
        Should -Invoke Get-QuarantineMessage -Times 1 -Exactly -ParameterFilter { $RecipientAddress -eq 'a.rivera@corp.example' }
    }
    It 'maps a message to the dialog row' {
        Mock Get-QuarantineMessage { New-FakeMessage 1; New-FakeMessage 2 }
        $rows = @(Get-RrRequests -Days 3)
        $rows.Count | Should -Be 2
        $rows[0].Identity | Should -Be '00000000-0000-4000-8000-000000000001\00000000-0000-4000-8000-0000000000a1'
        $rows[0].Received | Should -Be ([datetime]'2026-11-25 08:11')
        $rows[0].Sender | Should -Be 'billing1@invoice-pay.example'
        $rows[0].Recipient | Should -Be 'a@corp.example; b@corp.example'
        $rows[0].Subject | Should -Be 'Invoice 1'
        $rows[0].QuarantineTypes | Should -Be 'HighConfPhish'
        $rows[0].Expires | Should -Be ([datetime]'2026-12-25')
    }
    It 'writes the list note: empty, nothing ticked, some ticked, capped' {
        Get-RrListNote 0 0 | Should -Be 'No pending release requests in this period.'
        Get-RrListNote 5 0 | Should -Be '5 pending release requests. Nothing is ticked yet.'
        Get-RrListNote 5 2 | Should -Be '5 pending release requests. 2 ticked.'
        Get-RrListNote 1 0 | Should -Be '1 pending release request. Nothing is ticked yet.'
        Get-RrListNote 1000 0 | Should -BeLike 'Showing the first 1000. Narrow the date range or filter by recipient.*'
        Get-RrListNote 1000 3 | Should -Be 'Showing the first 1000. Narrow the date range or filter by recipient. 3 ticked.'
    }
    It 'shows the cap message only at 1000 rows or more' {
        Get-RrCapMessage 999 | Should -Be ''
        Get-RrCapMessage 1000 | Should -Be 'Showing the first 1000. Narrow the date range or filter by recipient.'
        Get-RrCapMessage 1500 | Should -Be 'Showing the first 1000. Narrow the date range or filter by recipient.'
    }
}

Describe 'ReleaseRequests: ZIP checks' {
    It 'decodes the Base64 export back to the same bytes' {
        $zip = New-TestZip -Flags 1
        $b64 = [Convert]::ToBase64String($zip)
        $back = [Convert]::FromBase64String($b64)
        $back.Length | Should -Be $zip.Length
        (Test-RrZipBytes $back).Ok | Should -BeTrue
        $eml = [Convert]::FromBase64String([Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes('From: a@b.example')))
        [System.Text.Encoding]::ASCII.GetString($eml) | Should -Be 'From: a@b.example'
    }
    It 'accepts an encrypted archive (flag bit 0) and the AES variant (method 99, extra 0x9901)' {
        $r = Test-RrZipBytes (New-TestZip -Flags 1)
        $r.Ok | Should -BeTrue
        $r.Reason | Should -Be ''
        (Test-RrZipBytes (New-TestZip -Flags 1 -Aes)).Ok | Should -BeTrue
        (Test-RrZipBytes (New-TestZip -Flags 1, 9 -Aes)).Ok | Should -BeTrue
    }
    It 'rejects an unencrypted ZIP' {
        $r = Test-RrZipBytes (New-PlainZip)
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Match 'not password-protected'
        (Test-RrZipBytes (New-TestZip -Flags 0)).Ok | Should -BeFalse
    }
    It 'rejects a non-ZIP, an eml text, a truncated archive, an empty input and null' {
        (Test-RrZipBytes ([System.Text.Encoding]::ASCII.GetBytes('From: a@b.example'))).Ok | Should -BeFalse
        $zip = New-TestZip -Flags 1
        $cut = New-Object byte[] ($zip.Length - 30)
        [Array]::Copy($zip, $cut, $cut.Length)
        $r = Test-RrZipBytes $cut
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Match 'incomplete'
        (Test-RrZipBytes (New-TestZip -Flags 1 -NoEocd)).Ok | Should -BeFalse
        (Test-RrZipBytes (New-Object byte[] 0)).Ok | Should -BeFalse
        (Test-RrZipBytes $null).Ok | Should -BeFalse
        $junk = New-Object byte[] 200
        [Array]::Copy([byte[]](0x50, 0x4B, 3, 4), $junk, 4)
        (Test-RrZipBytes $junk).Ok | Should -BeFalse
    }
    It 'rejects an archive where one entry is not encrypted' {
        $r = Test-RrZipBytes (New-TestZip -Flags 1, 0)
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Match 'not password-protected'
    }
    It 'summarizes structure only' {
        $s = Get-RrZipSummary (New-TestZip -Flags 1, 9 -Aes)
        $s.Signature | Should -Be '504b0304'
        $s.IsZip | Should -BeTrue
        $s.EocdFound | Should -BeTrue
        $s.EntryCount | Should -Be 2
        $s.Entries[0].Flag | Should -Be '0x0001'
        $s.Entries[1].Flag | Should -Be '0x0009'
        $s.Entries[0].Method | Should -Be 99
        $s.Entries[0].AesExtra | Should -BeTrue
        $s.Entries[0].CompressedSize | Should -BeGreaterThan 0
        $s.Entries[0].UncompressedSize | Should -BeGreaterThan 0
        (Get-RrZipSummary (New-TestZip -Flags 1)).Entries[0].AesExtra | Should -BeFalse
        (Get-RrZipSummary (New-TestZip -Flags 1)).Entries[0].Method | Should -Be 0
        $names = @($s.PSObject.Properties.Name)
        $names | Should -Be @('Signature', 'Length', 'IsZip', 'EocdFound', 'EntryCount', 'Entries')
        @($s.Entries[0].PSObject.Properties.Name) | Should -Be @('Flag', 'Method', 'CompressedSize', 'UncompressedSize', 'AesExtra')
    }
    It 'never returns entry names, comments or content bytes' {
        $zip = New-TestZip -Flags 1 -Aes
        $s = Get-RrZipSummary $zip
        $json = $s | ConvertTo-Json -Depth 6
        $text = (Format-RrZipSummary $s) + $json + (($s | Out-String))
        $text | Should -Not -Match 'SENTINEL'
        $text | Should -Not -Match '7f3a'
        $text | Should -Not -Match 'entry-name'
        $text | Should -Not -Match 'content-bytes'
        $text | Should -Not -Match 'zip-comment'
        (Get-RrZipSummary (New-PlainZip) | ConvertTo-Json -Depth 6) | Should -Not -Match 'SENTINEL'
    }
    It 'returns only signature, length and "not a ZIP" for other input, and survives garbage' {
        $s = Get-RrZipSummary ([System.Text.Encoding]::ASCII.GetBytes('From: a@b.example'))
        @($s.PSObject.Properties.Name) | Should -Be @('Signature', 'Length', 'IsZip', 'Note')
        $s.IsZip | Should -BeFalse
        $s.Note | Should -Be 'not a ZIP'
        $s.Length | Should -Be 17
        $s.Signature | Should -Be '46726f6d'
        (Get-RrZipSummary (New-Object byte[] 0)).Note | Should -Be 'not a ZIP'
        (Get-RrZipSummary $null).Length | Should -Be 0
        $rand = New-Object byte[] 5000
        (New-Object System.Random 7).NextBytes($rand)
        [Array]::Copy([byte[]](0x50, 0x4B, 3, 4), $rand, 4)
        { Get-RrZipSummary $rand } | Should -Not -Throw
        (Get-RrZipSummary $rand).EocdFound | Should -BeFalse
        $half = [byte[]](New-TestZip -Flags 1)[0..60]
        (Get-RrZipSummary $half).EocdFound | Should -BeFalse
    }
    It 'formats the summary as plain text for the Copy button' {
        $text = Format-RrZipSummary (Get-RrZipSummary (New-TestZip -Flags 1 -Aes))
        $text | Should -Match 'Signature \(first 4 bytes\): 504b0304'
        $text | Should -Match 'Entry 1: flag 0x0001, method 99'
        $text | Should -Match 'AES extra field yes'
        (Format-RrZipSummary (Get-RrZipSummary ([byte[]](1, 2, 3, 4, 5)))) | Should -Match 'not a ZIP'
    }
}

Describe 'ReleaseRequests: file names' {
    It 'is yyyyMMdd-HHmm plus 10 hex chars of the SHA-256 of the identity' {
        $id = '00000000-0000-4000-8000-000000000001\00000000-0000-4000-8000-0000000000a1'
        $name = Get-RrFileName ([datetime]'2026-11-25 08:12') $id
        $name | Should -Match '^\d{8}-\d{4}-[0-9a-f]{10}\.zip$'
        $name | Should -Match '^20261125-0812-'
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $hex = (($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($id)) | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 10)
        $sha.Dispose()
        $name | Should -Be "20261125-0812-$hex.zip"
    }
    It 'differs when only the second GUID differs, and carries no sender or subject text' {
        $a = Get-RrFileName ([datetime]'2026-11-25 08:12') '00000000-0000-4000-8000-000000000001\00000000-0000-4000-8000-0000000000a1'
        $b = Get-RrFileName ([datetime]'2026-11-25 08:12') '00000000-0000-4000-8000-000000000001\00000000-0000-4000-8000-0000000000a2'
        $a | Should -Not -Be $b
        $a | Should -Not -Match 'billing|invoice|example'
    }
    It 'uses the invariant culture for the date' {
        $old = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('ar-SA')
            (Get-RrFileName ([datetime]'2026-11-25 08:12') 'x') | Should -Match '^20261125-0812-'
        } finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $old }
    }
}

Describe 'ReleaseRequests: Save-RrExport' {
    BeforeEach {
        $script:OldTemp = $env:TEMP; $script:OldTmp = $env:TMP
        $script:Case = [guid]::NewGuid().ToString('N')
        $script:FakeTemp = Join-Path $TestDrive ('redirected-temp-' + $script:Case)
        $script:Inc = Join-Path $TestDrive ('Incoming-' + $script:Case)
        [void][System.IO.Directory]::CreateDirectory($script:FakeTemp)
        [void][System.IO.Directory]::CreateDirectory($script:Inc)
        $env:TEMP = $script:FakeTemp; $env:TMP = $script:FakeTemp
        $script:Id = '00000000-0000-4000-8000-000000000001\00000000-0000-4000-8000-0000000000a1'
        $script:Rec = [datetime]'2026-11-25 08:12'
    }
    AfterEach {
        $env:TEMP = $script:OldTemp; $env:TMP = $script:OldTmp
    }
    It 'saves a valid encrypted ZIP once, as the only file anywhere (Incoming and TEMP)' {
        $b64 = [Convert]::ToBase64String((New-TestZip -Flags 1 -Aes))
        Mock Export-QuarantineMessage { [pscustomobject]@{ Eml = $b64 } }
        $watch = Start-RrWatch @($script:Inc, $script:FakeTemp)
        $res = Save-RrExport -Identity $script:Id -Received $script:Rec -Password (New-SecurePw 'x') -Incoming $script:Inc
        $names = Stop-RrWatch $watch
        $res.Status | Should -Be 'Saved'
        $res.FileName | Should -Match '^\d{8}-\d{4}-[0-9a-f]{10}\.zip$'
        $names.Count | Should -BeGreaterThan 0
        foreach ($n in $names) { $n | Should -BeLike '*.zip' }
        @(Get-ChildItem -LiteralPath $script:FakeTemp -Recurse -File).Count | Should -Be 0
        @(Get-ChildItem -LiteralPath $script:Inc -File).Name | Should -Be @($res.FileName)
        (Test-RrZipBytes ([IO.File]::ReadAllBytes((Join-Path $script:Inc $res.FileName)))).Ok | Should -BeTrue
        Should -Invoke Export-QuarantineMessage -Times 1 -Exactly -ParameterFilter {
            $Identity -eq $script:Id -and $CompressOutput -and $Password -is [securestring] -and $ReasonForExport -eq 'Offline review with Quarantine Review Assistant'
        }
    }
    It 'writes nothing when the export is not an encrypted ZIP (plain ZIP, eml text, junk)' {
        foreach ($bad in @((New-PlainZip), [System.Text.Encoding]::ASCII.GetBytes('From: a@b.example'), (New-Object byte[] 0))) {
            $b64 = [Convert]::ToBase64String($bad)
            Mock Export-QuarantineMessage { [pscustomobject]@{ Eml = $b64 } }
            $watch = Start-RrWatch @($script:Inc, $script:FakeTemp)
            $res = Save-RrExport -Identity $script:Id -Received $script:Rec -Password (New-SecurePw 'x') -Incoming $script:Inc
            $names = Stop-RrWatch $watch
            $res.Status | Should -BeIn @('Rejected', 'Failed')
            $names.Count | Should -Be 0
            @(Get-ChildItem -LiteralPath $script:Inc -Force).Count | Should -Be 0
            @(Get-ChildItem -LiteralPath $script:FakeTemp -Force).Count | Should -Be 0
        }
        $b64 = [Convert]::ToBase64String((New-PlainZip))
        Mock Export-QuarantineMessage { [pscustomobject]@{ Eml = $b64 } }
        $res = Save-RrExport -Identity $script:Id -Received $script:Rec -Password (New-SecurePw 'x') -Incoming $script:Inc
        $res.Status | Should -Be 'Rejected'
        $res.Summary.IsZip | Should -BeTrue
        ($res.Summary | ConvertTo-Json -Depth 6) | Should -Not -Match 'SENTINEL'
    }
    It 'rejects text that is not Base64 and an empty export' {
        Mock Export-QuarantineMessage { [pscustomobject]@{ Eml = '***not base64***' } }
        (Save-RrExport -Identity $script:Id -Received $script:Rec -Password (New-SecurePw 'x') -Incoming $script:Inc).Status | Should -Be 'Rejected'
        Mock Export-QuarantineMessage { [pscustomobject]@{ Eml = '' } }
        (Save-RrExport -Identity $script:Id -Received $script:Rec -Password (New-SecurePw 'x') -Incoming $script:Inc).Status | Should -Be 'Failed'
        Mock Export-QuarantineMessage { throw 'service unavailable' }
        $res = Save-RrExport -Identity $script:Id -Received $script:Rec -Password (New-SecurePw 'x') -Incoming $script:Inc
        $res.Status | Should -Be 'Failed'
        $res.Message | Should -Match 'service unavailable'
        @(Get-ChildItem -LiteralPath $script:Inc -Force).Count | Should -Be 0
    }
    It 'skips a message whose file is already in Incoming and leaves that file alone' {
        $b64 = [Convert]::ToBase64String((New-TestZip -Flags 1))
        Mock Export-QuarantineMessage { [pscustomobject]@{ Eml = $b64 } }
        $target = Join-Path $script:Inc (Get-RrFileName $script:Rec $script:Id)
        [IO.File]::WriteAllText($target, 'existing')
        $res = Save-RrExport -Identity $script:Id -Received $script:Rec -Password (New-SecurePw 'x') -Incoming $script:Inc
        $res.Status | Should -Be 'Exists'
        $res.FileName | Should -Be (Split-Path -Leaf $target)
        [IO.File]::ReadAllText($target) | Should -Be 'existing'
        @(Get-ChildItem -LiteralPath $script:Inc -Force).Count | Should -Be 1
    }
    It 'creates the Incoming folder only when there is something to save' {
        $missing = Join-Path $TestDrive 'not-there-yet'
        Mock Export-QuarantineMessage { [pscustomobject]@{ Eml = [Convert]::ToBase64String((New-PlainZip)) } }
        (Save-RrExport -Identity $script:Id -Received $script:Rec -Password (New-SecurePw 'x') -Incoming $missing).Status | Should -Be 'Rejected'
        Test-Path -LiteralPath $missing | Should -BeFalse
        $b64 = [Convert]::ToBase64String((New-TestZip -Flags 1))
        Mock Export-QuarantineMessage { [pscustomobject]@{ Eml = $b64 } }
        (Save-RrExport -Identity $script:Id -Received $script:Rec -Password (New-SecurePw 'x') -Incoming $missing).Status | Should -Be 'Saved'
        Test-Path -LiteralPath $missing | Should -BeTrue
    }
}

Describe 'ReleaseRequests: password handling' {
    It 'never shows the password in any output stream or in a transcript during list and export' {
        $b64 = [Convert]::ToBase64String((New-TestZip -Flags 1))
        Mock Export-QuarantineMessage { [pscustomobject]@{ Eml = $b64 } }
        Mock Get-QuarantineMessage { New-FakeMessage 1 }
        $inc = Join-Path $TestDrive 'pw-incoming'
        $log = Join-Path $TestDrive 'transcript.txt'
        $pw = New-SecurePw $script:PwSentinel
        Start-Transcript -LiteralPath $log | Out-Null
        try {
            $all = & {
                $rows = @(Get-RrRequests -Days 4)
                $VerbosePreference = 'Continue'; $DebugPreference = 'Continue'; $InformationPreference = 'Continue'
                $r = Save-RrExport -Identity $rows[0].Identity -Received $rows[0].Received -Password $pw -Incoming $inc
                $r
                $r | Format-List | Out-String
            } *>&1
        } finally { Stop-Transcript | Out-Null }
        ($all | Out-String) | Should -Not -Match $script:PwSentinel
        ($all | ConvertTo-Json -Depth 5 -WarningAction SilentlyContinue) | Should -Not -Match $script:PwSentinel
        [IO.File]::ReadAllText($log) | Should -Not -Match $script:PwSentinel
        Mock Export-QuarantineMessage { throw 'boom' }
        $r2 = Save-RrExport -Identity 'a\b' -Received ([datetime]'2026-11-25 08:12') -Password $pw -Incoming $inc
        ($r2 | Out-String) | Should -Not -Match $script:PwSentinel
    }
    It 'passes the password to the runspace as a variable, not as script text' {
        $src = [IO.File]::ReadAllText($script:RrPath)
        $src | Should -Match 'RrPassword = \$b\.Password'
        $src | Should -Match 'SetVariable\(\[string\]\$key'
        # the step script only refers to the variable
        $src | Should -Match 'Save-RrExport -Identity \$RrIdentity -Received \$RrReceived -Password \$RrPassword -Incoming \$RrIncoming'
    }
}

Describe 'ReleaseRequests: module state and install' {
    It 'reports a missing module with the install command' {
        Mock Get-Module { $null }
        $s = Get-RrModuleState
        $s.Installed | Should -BeFalse
        $s.Version | Should -Be ''
        $s.InstallCommand | Should -Be (Get-RrInstallCommand)
        $s.InstallCommand | Should -Match '^Install-Module ExchangeOnlineManagement -Scope CurrentUser;'
        $s.InstallCommand | Should -Match 'Installed\. Close this window to return to Quarantine Review Assistant\.'
        $s.InstallCommand | Should -Match 'The install did not finish\. Read the message above, then close this window\.'
    }
    It 'reports the highest installed version' {
        Mock Get-Module {
            [pscustomobject]@{ Name = 'ExchangeOnlineManagement'; Version = [version]'3.1.0' }
            [pscustomobject]@{ Name = 'ExchangeOnlineManagement'; Version = [version]'3.11.1' }
        }
        $s = Get-RrModuleState
        $s.Installed | Should -BeTrue
        $s.Version | Should -Be '3.11.1'
    }
    It 'starts a visible Windows PowerShell 5.1 window with the exact arguments and without waiting' {
        Mock Start-Process { [pscustomobject]@{ Id = 1; HasExited = $false } }
        $proc = Start-RrModuleInstall
        $proc.Id | Should -Be 1
        $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq $exe -and $PassThru -and -not $Wait -and $ArgumentList.Count -eq 4 -and
            $ArgumentList[0] -eq '-NoProfile' -and $ArgumentList[1] -eq '-NoExit' -and $ArgumentList[2] -eq '-Command' -and $ArgumentList[3] -eq (Get-RrInstallCommand)
        }
        Should -Invoke Start-Process -Times 0 -ParameterFilter { $WindowStyle -or $Verb }
    }
    It 'the install command and the script carry no forbidden switch' {
        $cmd = Get-RrInstallCommand
        $src = [IO.File]::ReadAllText($script:RrPath)
        foreach ($bad in '-Force', '-AllowClobber', '-SkipPublisherCheck', 'Set-PSRepository', '-InstallationPolicy', 'SecurityProtocol', 'Set-ExecutionPolicy', '-ExecutionPolicy', '-WindowStyle') {
            $cmd.Contains($bad) | Should -BeFalse -Because "install command contains $bad"
            $src.Contains($bad) | Should -BeFalse -Because "ReleaseRequests.ps1 contains $bad"
        }
    }
    It 'dot-sourcing opens no window and keeps the launcher variables' {
        $out = & {
            $Incoming = 'keep-incoming'; $Screenshot = 'keep-shot'
            . $script:RrPath
            "$Incoming|$Screenshot|$([System.Windows.Forms.Application]::OpenForms.Count)|$([bool](Get-Command Show-ReleaseRequestDialog -ErrorAction SilentlyContinue))"
        }
        $out | Should -Be 'keep-incoming|keep-shot|0|True'
    }
}

Describe 'ReleaseRequests: session' {
    BeforeEach { Initialize-RrStubs }
    AfterAll { Initialize-RrStubs }
    It 'runs steps in an STA runspace with variables set outside the script text' {
        $s = New-RrSession
        try {
            $s.Runspace.ApartmentState | Should -Be 'STA'
            $work = Invoke-RrStep $s { "$([System.Threading.Thread]::CurrentThread.GetApartmentState())|$Rr1" } @{ Rr1 = 'value-1' }
            $deadline = [DateTime]::UtcNow.AddSeconds(30)
            while (-not $work.Handle.IsCompleted -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
            $res = Complete-RrStep $work
            $res.Error | Should -BeNullOrEmpty
            @($res.Output)[0] | Should -Be 'STA|value-1'
            $res2 = Complete-RrStep $work
            $res2 | Should -Be $res
            $bad = Invoke-RrStep $s { throw 'step failed: simulated' } @{}
            while (-not $bad.Handle.IsCompleted) { Start-Sleep -Milliseconds 20 }
            (Complete-RrStep $bad).Error | Should -Match 'step failed: simulated'
        } finally { Close-RrSession $s }
    }
    It 'Close-RrSession calls Disconnect-ExchangeOnline in the runspace and is idempotent' {
        function global:Disconnect-ExchangeOnline { [CmdletBinding()] param([switch]$Confirm) $State.Disconnected = $true; $State.Calls = 1 + [int]$State.Calls }
        $s = New-RrSession -Functions @('Disconnect-ExchangeOnline')
        Close-RrSession $s
        $s.Closed | Should -BeTrue
        $s.State.Disconnected | Should -BeTrue
        Close-RrSession $s
        $s.State.Calls | Should -Be 1
        { Close-RrSession $null } | Should -Not -Throw
    }
    It 'Close-RrSession gives up after its timeout when Disconnect hangs' {
        function global:Disconnect-ExchangeOnline { [CmdletBinding()] param([switch]$Confirm) Start-Sleep -Seconds 30 }
        $s = New-RrSession -Functions @('Disconnect-ExchangeOnline')
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Close-RrSession $s 1000
        $sw.Stop()
        $sw.ElapsedMilliseconds | Should -BeLessThan 3000
        $s.Closed | Should -BeTrue
    }
    It 'Close-RrSession stops a step that is still running (window closed during sign-in)' {
        function global:Disconnect-ExchangeOnline { [CmdletBinding()] param([switch]$Confirm) $State.Disconnected = $true }
        function global:Connect-ExchangeOnline { [CmdletBinding()] param([switch]$ShowBanner) Start-Sleep -Seconds 30 }
        $s = New-RrSession -Functions @('Connect-ExchangeOnline', 'Disconnect-ExchangeOnline')
        $null = Invoke-RrStep $s (Get-RrConnectScript) @{}
        Start-Sleep -Milliseconds 300
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Close-RrSession $s 1500
        $sw.Stop()
        $sw.ElapsedMilliseconds | Should -BeLessThan 6000
        $s.State.Disconnected | Should -BeTrue
    }
    It 'a failing connect gives an error and no listing is requested' {
        function global:Connect-ExchangeOnline { [CmdletBinding()] param([switch]$ShowBanner) throw 'sign-in cancelled: simulated' }
        function global:Get-QuarantineMessage { [CmdletBinding()] param($ReleaseStatus, $PageSize, $StartReceivedDate, $EndReceivedDate, $RecipientAddress) $State.Listed = $true }
        $s = New-RrSession -Functions (@('Connect-ExchangeOnline', 'Get-QuarantineMessage') + (Get-RrSessionFunctionNames))
        try {
            $work = Invoke-RrStep $s (Get-RrConnectScript) @{}
            while (-not $work.Handle.IsCompleted) { Start-Sleep -Milliseconds 20 }
            $res = Complete-RrStep $work
            $res.Error | Should -Match 'sign-in cancelled: simulated'
            $s.State.ContainsKey('Listed') | Should -BeFalse
        } finally { Close-RrSession $s }
    }
    It 'lists and exports through the session functions' {
        $b64 = [Convert]::ToBase64String((New-TestZip -Flags 1))
        Invoke-Expression ("function global:Get-QuarantineMessage { [CmdletBinding()] param(`$ReleaseStatus, `$PageSize, `$StartReceivedDate, `$EndReceivedDate, `$RecipientAddress) [pscustomobject]@{ Identity = 'a\b'; ReceivedTime = [datetime]'2026-11-25 08:11'; SenderAddress = 's@x.example'; RecipientAddress = @('r@corp.example'); Subject = 'S'; QuarantineTypes = 'Phish'; Expires = [datetime]'2026-12-25' } }")
        Invoke-Expression ("function global:Export-QuarantineMessage { [CmdletBinding()] param(`$Identity, [switch]`$CompressOutput, `$Password, `$ReasonForExport) [pscustomobject]@{ Eml = '$b64' } }")
        $s = New-RrSession -Functions (@('Get-QuarantineMessage', 'Export-QuarantineMessage') + (Get-RrSessionFunctionNames))
        $inc = Join-Path $TestDrive 'session-incoming'
        try {
            $w = Invoke-RrStep $s { Get-RrRequests -Days $RrDays -Recipient $RrRecipient } @{ RrDays = 7; RrRecipient = '' }
            while (-not $w.Handle.IsCompleted) { Start-Sleep -Milliseconds 20 }
            $rows = @((Complete-RrStep $w).Output)
            $rows.Count | Should -Be 1
            $rows[0].Sender | Should -Be 's@x.example'
            $vars = @{ RrIdentity = [string]$rows[0].Identity; RrReceived = [datetime]$rows[0].Received; RrPassword = (New-SecurePw $script:PwSentinel); RrIncoming = $inc }
            $w2 = Invoke-RrStep $s { Save-RrExport -Identity $RrIdentity -Received $RrReceived -Password $RrPassword -Incoming $RrIncoming } $vars
            while (-not $w2.Handle.IsCompleted) { Start-Sleep -Milliseconds 20 }
            $r2 = Complete-RrStep $w2
            $r2.Error | Should -BeNullOrEmpty
            @($r2.Output)[-1].Status | Should -Be 'Saved'
            @(Get-ChildItem -LiteralPath $inc -File).Count | Should -Be 1
        } finally { Close-RrSession $s }
    }
}

Describe 'ReleaseRequests: dialog (child Windows PowerShell 5.1)' {
    BeforeAll {
        $script:ChildHead = @"
`$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. '$($script:KitPath)'
[System.Windows.Forms.Application]::EnableVisualStyles()
. '$($script:RrPath)'
function Show-Offscreen(`$form) {
    `$form.ShowInTaskbar = `$false; `$form.Opacity = 0; `$form.StartPosition = 'Manual'
    `$form.Location = New-Object System.Drawing.Point(-32000, -32000)
    `$form.Show(); [System.Windows.Forms.Application]::DoEvents()
}
function Wait-Until([scriptblock]`$cond, [int]`$seconds = 40) {
    `$end = [DateTime]::UtcNow.AddSeconds(`$seconds)
    while (-not (& `$cond) -and [DateTime]::UtcNow -lt `$end) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
}
"@
    }
    It 'FormClosing signs out of the session and unhooks the install watcher; an exited install window re-checks the module' {
        $body = $script:ChildHead + @'
function Disconnect-ExchangeOnline { [CmdletBinding()] param([switch]$Confirm) $State.Disconnected = $true }
$script:Missing = $true
function Get-RrModuleState { [pscustomobject]@{ Installed = (-not $script:Missing); Version = '3.11.1'; InstallCommand = 'x' } }
$d = New-RrDialog -Incoming (Join-Path $env:TEMP 'qra-rr-none') -SessionFunctions @('Disconnect-ExchangeOnline') -NoAutoStart
Show-Offscreen $d.Form
$d.Module = Get-RrModuleState
Update-RrView $d
$sess = Get-RrDialogSession $d
# 1. the install window exits and the module is still missing
$p1 = [pscustomobject]@{ HasExited = $true; Disposed = $false }
$p1 | Add-Member ScriptMethod Dispose { $this.Disposed = $true }
$d.InstallProc = $p1; $d.InstallState = 'waiting'; $d.InstallWatch.Start()
Wait-Until { -not $d.InstallWatch.Enabled } 10
$after1 = @{ State = $d.InstallState; Msg = $d.InstallMsg; WatchOn = $d.InstallWatch.Enabled; Disposed = $p1.Disposed; ProcNull = ($null -eq $d.InstallProc) }
# 2. the window is still open when the dialog closes
$p2 = [pscustomobject]@{ HasExited = $false; Disposed = $false }
$p2 | Add-Member ScriptMethod Dispose { $this.Disposed = $true }
$d.InstallProc = $p2; $d.InstallState = 'waiting'; $d.InstallWatch.Start()
$d.Form.Close()
[pscustomobject]@{
    After1 = $after1; Disconnected = [bool]$sess.State.Disconnected; SessionClosed = $sess.Closed
    WatchOnAfterClose = $d.InstallWatch.Enabled; ProcNullAfterClose = ($null -eq $d.InstallProc); P2Disposed = $p2.Disposed; PollOn = $d.Poll.Enabled
} | ConvertTo-Json -Compress -Depth 4
'@
        $r = Get-ChildJson (Invoke-ChildPs $body)
        $r.After1.State | Should -Be 'failed'
        $r.After1.Msg | Should -Be 'The install did not complete. Check the PowerShell window output.'
        $r.After1.WatchOn | Should -BeFalse
        $r.After1.Disposed | Should -BeTrue
        $r.After1.ProcNull | Should -BeTrue
        $r.Disconnected | Should -BeTrue
        $r.SessionClosed | Should -BeTrue
        $r.WatchOnAfterClose | Should -BeFalse
        $r.ProcNullAfterClose | Should -BeTrue
        $r.P2Disposed | Should -BeTrue
        $r.PollOn | Should -BeFalse
    }
    It 'a failed sign-in shows the error and a Retry button and never lists' {
        $body = $script:ChildHead + @'
function Connect-ExchangeOnline { [CmdletBinding()] param([switch]$ShowBanner) throw 'sign-in cancelled: simulated' }
function Disconnect-ExchangeOnline { [CmdletBinding()] param([switch]$Confirm) $State.Disconnected = $true }
function Get-QuarantineMessage { [CmdletBinding()] param($ReleaseStatus, $PageSize, $StartReceivedDate, $EndReceivedDate, $RecipientAddress) $State.Listed = $true }
$d = New-RrDialog -Incoming (Join-Path $env:TEMP 'qra-rr-none') -SessionFunctions @('Connect-ExchangeOnline', 'Disconnect-ExchangeOnline', 'Get-QuarantineMessage') -NoAutoStart
Show-Offscreen $d.Form
$d.Module = [pscustomobject]@{ Installed = $true; Version = '9.9.9'; InstallCommand = '' }
Update-RrView $d
$d.Ctl.BSignIn.PerformClick()
Wait-Until { $d.ConnectState -ne 'working' }
$sess = $d.Session
$out = [pscustomobject]@{
    ConnectState = $d.ConnectState; Msg = $d.ConnectMsg; ButtonText = $d.Ctl.BSignIn.Text; ButtonVisible = $d.Ctl.BSignIn.Visible
    ErrLabel = $d.Ctl.LblConnectErr.Text; Listed = $sess.State.ContainsKey('Listed'); ListItems = $d.Ctl.List.Items.Count; ListState = $d.ListState
}
$d.Form.Close()
$out | Add-Member Disconnected ([bool]$sess.State.Disconnected)
$out | ConvertTo-Json -Compress
'@
        $r = Get-ChildJson (Invoke-ChildPs $body)
        $r.ConnectState | Should -Be 'failed'
        $r.Msg | Should -Match 'sign-in cancelled: simulated'
        $r.ErrLabel | Should -Match 'sign-in cancelled: simulated'
        $r.ButtonText | Should -Be 'Retry'
        $r.Listed | Should -BeFalse
        $r.ListItems | Should -Be 0
        $r.ListState | Should -Be 'idle'
        $r.Disconnected | Should -BeTrue
    }
    It 'signs in, lists with nothing ticked, saves only the ticked message and clears the password box' {
        $b64 = [Convert]::ToBase64String((New-TestZip -Flags 1 -Aes))
        $inc = Join-Path $TestDrive 'dialog-incoming'
        $head = $script:ChildHead + "`r`n`$b64 = '$b64'`r`n`$inc = '$inc'`r`n"
        $body = $head + @'
function Connect-ExchangeOnline { [CmdletBinding()] param([switch]$ShowBanner) }
function Disconnect-ExchangeOnline { [CmdletBinding()] param([switch]$Confirm) $State.Disconnected = $true }
function Get-QuarantineMessage {
    [CmdletBinding()] param($ReleaseStatus, $PageSize, $StartReceivedDate, $EndReceivedDate, $RecipientAddress)
    foreach ($n in 1, 2) {
        [pscustomobject]@{ Identity = "00000000-0000-4000-8000-00000000000$n\00000000-0000-4000-8000-0000000000a$n"; ReceivedTime = ([datetime]'2026-11-25 08:10').AddMinutes($n)
            SenderAddress = "billing$n@invoice-pay.example"; RecipientAddress = @('a@corp.example'); Subject = "Invoice $n"; QuarantineTypes = 'Phish'; Expires = [datetime]'2026-12-25' }
    }
}
$exportCode = 'function Export-QuarantineMessage { [CmdletBinding()] param($Identity, [switch]$CompressOutput, $Password, $ReasonForExport) [pscustomobject]@{ Eml = ''' + $b64 + ''' } }'
Invoke-Expression $exportCode
$d = New-RrDialog -Incoming $inc -SessionFunctions @('Connect-ExchangeOnline', 'Disconnect-ExchangeOnline', 'Get-QuarantineMessage', 'Export-QuarantineMessage') -NoAutoStart
Show-Offscreen $d.Form
$d.Module = [pscustomobject]@{ Installed = $true; Version = '9.9.9'; InstallCommand = '' }
Update-RrView $d
$d.Ctl.BSignIn.PerformClick()
Wait-Until { $d.ListState -eq 'loaded' -or $d.ListState -eq 'failed' }
$sess = $d.Session
$listed = @{ State = $d.ListState; Items = $d.Ctl.List.Items.Count; Ticked = $d.Ctl.List.CheckedItems.Count; Note = $d.ListMsg; SaveEnabledEarly = $d.Ctl.BSave.Enabled; Connect = $d.ConnectState }
$d.Ctl.List.Items[1].Checked = $true
$enabledNoPw = $d.Ctl.BSave.Enabled
$d.Ctl.Pw.Text = 'Sentinel-Pw-7f3a'
$enabledWithPw = $d.Ctl.BSave.Enabled
$d.Ctl.BSave.PerformClick()
$pwAfterClick = $d.Ctl.Pw.Text
Wait-Until { $d.SaveState -eq 'done' }
$files = @(Get-ChildItem -LiteralPath $inc -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
$out = [pscustomobject]@{
    Listed = $listed; EnabledNoPw = $enabledNoPw; EnabledWithPw = $enabledWithPw; PwAfterClick = $pwAfterClick
    Summary = $d.SaveSummary; Problems = $d.SaveProblems; Files = $files; TickedAfter = $d.Ctl.List.CheckedItems.Count; SaveEnabledAfter = $d.Ctl.BSave.Enabled
    PwBox = $d.Ctl.Pw.Text
}
$d.Form.Close()
$out | Add-Member Disconnected ([bool]$sess.State.Disconnected)
$out | ConvertTo-Json -Compress -Depth 4
'@
        $r = Get-ChildJson (Invoke-ChildPs $body)
        $r.Listed.State | Should -Be 'loaded'
        $r.Listed.Items | Should -Be 2
        $r.Listed.Ticked | Should -Be 0
        $r.Listed.SaveEnabledEarly | Should -BeFalse
        $r.EnabledNoPw | Should -BeFalse
        $r.EnabledWithPw | Should -BeTrue
        $r.PwAfterClick | Should -Be ''
        $r.PwBox | Should -Be ''
        $r.Summary | Should -Be 'Saved 1 of 1 to Incoming'
        @($r.Files).Count | Should -Be 1
        @($r.Files)[0] | Should -Match '^20261125-0812-[0-9a-f]{10}\.zip$'
        $r.TickedAfter | Should -Be 0
        $r.SaveEnabledAfter | Should -BeFalse
        $r.Disconnected | Should -BeTrue
    }
    It 'a rejected export shows its structure summary and saves nothing' {
        $b64 = [Convert]::ToBase64String((New-PlainZip))
        $inc = Join-Path $TestDrive 'dialog-incoming-rejected'
        $head = $script:ChildHead + "`r`n`$b64 = '$b64'`r`n`$inc = '$inc'`r`n"
        $body = $head + @'
function Connect-ExchangeOnline { [CmdletBinding()] param([switch]$ShowBanner) }
function Disconnect-ExchangeOnline { [CmdletBinding()] param([switch]$Confirm) }
function Get-QuarantineMessage {
    [CmdletBinding()] param($ReleaseStatus, $PageSize, $StartReceivedDate, $EndReceivedDate, $RecipientAddress)
    [pscustomobject]@{ Identity = '00000000-0000-4000-8000-000000000001\00000000-0000-4000-8000-0000000000a1'; ReceivedTime = [datetime]'2026-11-25 08:11'
        SenderAddress = 'billing@invoice-pay.example'; RecipientAddress = @('a@corp.example'); Subject = 'Invoice'; QuarantineTypes = 'Phish'; Expires = [datetime]'2026-12-25' }
}
Invoke-Expression ('function Export-QuarantineMessage { [CmdletBinding()] param($Identity, [switch]$CompressOutput, $Password, $ReasonForExport) [pscustomobject]@{ Eml = ''' + $b64 + ''' } }')
$d = New-RrDialog -Incoming $inc -SessionFunctions @('Connect-ExchangeOnline', 'Disconnect-ExchangeOnline', 'Get-QuarantineMessage', 'Export-QuarantineMessage') -NoAutoStart
Show-Offscreen $d.Form
$d.Module = [pscustomobject]@{ Installed = $true; Version = '9.9.9'; InstallCommand = '' }
Update-RrView $d
$d.Ctl.BSignIn.PerformClick()
Wait-Until { $d.ListState -eq 'loaded' -or $d.ListState -eq 'failed' }
$d.Ctl.List.Items[0].Checked = $true
$d.Ctl.Pw.Text = 'Sentinel-Pw-7f3a'
$d.Ctl.BSave.PerformClick()
Wait-Until { $d.SaveState -eq 'done' }
$out = [pscustomobject]@{
    Summary = $d.SaveSummary; Problems = $d.SaveProblems; Rejected = $d.RejectedText; BoxText = $d.Ctl.Rej.Text; CopyVisible = $d.Ctl.BCopyDet.Visible
    Files = @(Get-ChildItem -LiteralPath $inc -Force -ErrorAction SilentlyContinue).Count; TickedAfter = $d.Ctl.List.CheckedItems.Count
}
$d.Form.Close()
$out | ConvertTo-Json -Compress
'@
        $r = Get-ChildJson (Invoke-ChildPs $body)
        $r.Summary | Should -Be 'Saved 0 of 1 to Incoming'
        $r.Problems | Should -Match 'not password-protected'
        $r.Rejected | Should -Match 'Signature \(first 4 bytes\): 504b0304'
        $r.Rejected | Should -Not -Match 'SENTINEL|plain\.eml'
        $r.BoxText | Should -Be $r.Rejected
        $r.CopyVisible | Should -BeTrue
        $r.Files | Should -Be 0
        $r.TickedAfter | Should -Be 1
    }
}

Describe 'ReleaseRequests: -Screenshot' -Tag 'Screenshot' {
    It 'standalone screenshot mode writes release-requests.png and exits 0' {
        $dir = Join-Path $TestDrive 'shots-rr'
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:RrPath -Screenshot $dir 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($out | Out-String)
        (Get-Item -LiteralPath (Join-Path $dir 'release-requests.png')).Length | Should -BeGreaterThan 10000
        Test-Path -LiteralPath (Join-Path $dir 'release-requests-missing.png') | Should -BeTrue
    }
    It 'screenshot mode touches no Incoming folder' {
        $root = Join-Path $TestDrive 'tool-root-rr'
        [void][System.IO.Directory]::CreateDirectory($root)
        Copy-Item -LiteralPath (Join-Path $script:Repo 'src\SecurityReview\app') -Destination (Join-Path $root 'app') -Recurse
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'app\ReleaseRequests.ps1') -Screenshot (Join-Path $TestDrive 'shots-rr2') 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($out | Out-String)
        Test-Path -LiteralPath (Join-Path $root 'Incoming') | Should -BeFalse
    }
}

Describe 'ReleaseRequests: source scans' {
    BeforeAll { $script:RrSource = [IO.File]::ReadAllText($script:RrPath) }
    It 'is read-only: no release, delete, block-list or Set-* Exchange cmdlets' {
        $script:RrSource | Should -Not -Match 'Release-QuarantineMessage'
        $script:RrSource | Should -Not -Match 'Delete-QuarantineMessage'
        $script:RrSource | Should -Not -Match 'New-TenantAllowBlockList'
        $script:RrSource | Should -Not -Match 'Remove-(Quarantine|Tenant)'
        # only the UI kit's Set-Qra* and Set-Access helpers and this file's own Set-Rr* helpers may start with Set-
        [regex]::Matches($script:RrSource, '\bSet-(?!Qra|Rr|Access\b)[A-Za-z]+').Count | Should -Be 0
        # the only Exchange cmdlets used
        $used = [regex]::Matches($script:RrSource, '\b(Get|Export|Connect|Disconnect)-(Quarantine|Exchange)[A-Za-z]*') | ForEach-Object { $_.Value } | Sort-Object -Unique
        $used | Should -Be @('Connect-ExchangeOnline', 'Disconnect-ExchangeOnline', 'Export-QuarantineMessage', 'Get-QuarantineMessage')
    }
    It 'contains none of the forbidden strings' {
        $forbidden = '-Force', '-AllowClobber', '-SkipPublisherCheck', 'Set-PSRepository', '-InstallationPolicy', 'SecurityProtocol', 'Set-ExecutionPolicy', '-ExecutionPolicy',
        '-WindowStyle', 'ConvertFrom-SecureString', 'AsPlainText', 'PasswordV2', 'DisableWAM', 'Device'
        foreach ($f in $forbidden) { $script:RrSource.Contains($f) | Should -BeFalse -Because "found '$f'" }
    }
    It 'writes only through the checked path and never to TEMP or non-zip files' {
        $script:RrSource | Should -Not -Match 'GetTempPath|\$env:TEMP|\$env:TMP|New-TemporaryFile'
        $script:RrSource | Should -Not -Match '\.eml''|\.partial|WriteAllText|WriteAllBytes|Set-Content|Out-File'
    }
    It 'has a UTF-8 BOM and CRLF line endings (both new files)' {
        foreach ($path in @($script:RrPath, $script:TestPath)) {
            $bytes = [IO.File]::ReadAllBytes($path)
            $bytes[0..2] | Should -Be @(0xEF, 0xBB, 0xBF) -Because $path
            ([System.Text.Encoding]::UTF8.GetString($bytes)) | Should -Not -Match "(?<!`r)`n" -Because $path
        }
    }
    It 'is plain ASCII after the BOM' {
        $bytes = [IO.File]::ReadAllBytes($script:RrPath)
        @($bytes[3..($bytes.Length - 1)] | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }
}
