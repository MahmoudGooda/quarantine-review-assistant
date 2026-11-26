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
    Add-Type -AssemblyName System.IO.Compression
    . $script:KitPath

    # The EXO cmdlets do not exist on CI: global stubs first, so Mock has something to replace.
    function global:Initialize-RrStubs {
        function global:Get-QuarantineMessage { [CmdletBinding()] param($ReleaseStatus, $PageSize, $StartReceivedDate, $EndReceivedDate, $RecipientAddress, $MessageId) }
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
            Identity = "00000000-0000-4000-8000-00000000000$n\00000000-0000-4000-8000-0000000000a$n"; MessageId = "<m$n@invoice-pay.example>"
            ReleaseStatus = 'REQUESTED'; Released = $false
            ReceivedTime = ([datetime]'2026-11-25 08:10').AddMinutes($n); SenderAddress = "billing$n@invoice-pay.example"
            RecipientAddress = @('a@corp.example', 'b@corp.example'); Subject = "Invoice $n"; QuarantineTypes = 'HighConfPhish'
            Expires = [datetime]'2026-12-25'
        }
    }
    function New-Copy([string]$Identity, [string]$Status = 'REQUESTED', [string]$MessageId = '', [string]$At = '08:10', $Released = $false) {
        [pscustomobject]@{
            Identity = $Identity; MessageId = $MessageId; ReleaseStatus = $Status; Released = $Released
            Received = ([datetime]('2026-11-25 ' + $At)); Sender = 'billing@invoice-pay.example'; Recipient = ''; Subject = "Subject of $MessageId"
            QuarantineTypes = 'Phish'; Expires = [datetime]'2026-12-25'
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
        $rows[0].MessageId | Should -Be '<m1@invoice-pay.example>'
        $rows[0].ReleaseStatus | Should -Be 'REQUESTED'
        $rows[0].Released | Should -BeFalse
    }
    It 'writes the list note: empty, nothing selected, some selected, capped, with and without the handled view' {
        function New-NoteMsg([string]$Status, [int]$Pending, [int]$Released = 0) {
            [pscustomobject]@{ Status = $Status; Counts = [pscustomobject]@{ Pending = $Pending; Released = $Released } }
        }
        $three = @((New-NoteMsg 'Pending' 2 2), (New-NoteMsg 'Pending' 1), (New-NoteMsg 'Pending' 2))
        Get-RrListNote @() 0 | Should -Be 'No pending release requests in this period.'
        Get-RrListNote @() 0 $true | Should -Be 'No messages in this period.'
        Get-RrListNote $three 0 | Should -Be '3 messages with pending requests (5 recipient copies). Nothing is selected yet.'
        Get-RrListNote $three 2 | Should -Be '3 messages with pending requests (5 recipient copies). 2 selected.'
        Get-RrListNote @((New-NoteMsg 'Pending' 1)) 0 | Should -Be '1 message with a pending request (1 recipient copy). Nothing is selected yet.'
        $mixed = @((New-NoteMsg 'Pending' 1), (New-NoteMsg 'Released' 0 3), (New-NoteMsg 'Denied' 0), (New-NoteMsg 'Released' 0 1))
        Get-RrListNote $mixed 0 $true | Should -Be '4 messages (1 with a pending request). Nothing is selected yet.'
        Get-RrListNote $mixed 1 $true | Should -Be '4 messages (1 with a pending request). 1 selected.'
        Get-RrListNote @($mixed[0], $mixed[1], $three[2]) 0 $true | Should -Be '3 messages (2 with pending requests). Nothing is selected yet.'
        Get-RrListNote @((New-NoteMsg 'Released' 0 2)) 0 $true | Should -Be '1 message (0 with pending requests). Nothing is selected yet.'
        $cap = 'Showing the first 1000. Narrow the date range or filter by recipient.'
        Get-RrListNote $three 0 $false 1000 | Should -Be "$cap 3 messages with pending requests (5 recipient copies). Nothing is selected yet."
        Get-RrListNote $three 3 $false 1000 | Should -Be "$cap 3 messages with pending requests (5 recipient copies). 3 selected."
        Get-RrListNote $three 0 $false 999 | Should -Not -BeLike 'Showing*'
    }
    It 'shows the cap message only at 1000 rows or more' {
        Get-RrCapMessage 999 | Should -Be ''
        Get-RrCapMessage 1000 | Should -Be 'Showing the first 1000. Narrow the date range or filter by recipient.'
        Get-RrCapMessage 1500 | Should -Be 'Showing the first 1000. Narrow the date range or filter by recipient.'
    }
}

Describe 'ReleaseRequests: message key and copy counts' {
    It 'uses the MessageId when it is there, otherwise the Identity before the first backslash' {
        Get-RrMessageKey ([pscustomobject]@{ MessageId = '<abc@mail.example>'; Identity = 'g1\a1' }) | Should -Be '<abc@mail.example>'
        Get-RrMessageKey ([pscustomobject]@{ MessageId = '  <abc@mail.example> '; Identity = 'g1\a1' }) | Should -Be '<abc@mail.example>'
        Get-RrMessageKey ([pscustomobject]@{ MessageId = ''; Identity = '11111111-aaaa\22222222-bbbb\33' }) | Should -Be '11111111-aaaa'
        Get-RrMessageKey ([pscustomobject]@{ Identity = 'g1\a1' }) | Should -Be 'g1'
        Get-RrMessageKey ([pscustomobject]@{ MessageId = $null; Identity = 'g1\a1' }) | Should -Be 'g1'
        Get-RrMessageKey ([pscustomobject]@{ Identity = 'no-backslash' }) | Should -Be 'no-backslash'
        # two copies of one message share a key, whichever way it is found
        (Get-RrMessageKey (New-Copy 'g1\a1')) | Should -Be (Get-RrMessageKey (New-Copy 'g1\a2'))
    }
    It 'classifies a copy without regard to the case of the status text' {
        Get-RrCopyKind (New-Copy 'g\1' 'REQUESTED') | Should -Be 'Pending'
        Get-RrCopyKind (New-Copy 'g\1' 'requested') | Should -Be 'Pending'
        Get-RrCopyKind (New-Copy 'g\1' 'Requested') | Should -Be 'Pending'
        Get-RrCopyKind (New-Copy 'g\1' 'RELEASED') | Should -Be 'Released'
        Get-RrCopyKind (New-Copy 'g\1' 'released') | Should -Be 'Released'
        Get-RrCopyKind (New-Copy 'g\1' 'APPROVED') | Should -Be 'Released'
        Get-RrCopyKind (New-Copy 'g\1' 'DENIED') | Should -Be 'Denied'
        Get-RrCopyKind (New-Copy 'g\1' 'denied') | Should -Be 'Denied'
        Get-RrCopyKind (New-Copy 'g\1' 'NOTRELEASED') | Should -Be 'NotRequested'
        Get-RrCopyKind (New-Copy 'g\1' 'notreleased') | Should -Be 'NotRequested'
        Get-RrCopyKind (New-Copy 'g\1' 'PREPARINGTORELEASE') | Should -Be 'NotRequested'
        Get-RrCopyKind (New-Copy 'g\1' 'ERROR') | Should -Be 'NotRequested'
        Get-RrCopyKind (New-Copy 'g\1' '') | Should -Be 'NotRequested'
        # Released = $true wins over a REQUESTED status: that copy is not pending any more
        Get-RrCopyKind (New-Copy 'g\1' 'REQUESTED' '' '08:10' $true) | Should -Be 'Released'
        Get-RrCopyKind (New-Copy 'g\1' 'REQUESTED' '' '08:10' $false) | Should -Be 'Pending'
    }
    It 'counts pending, released, denied and not requested copies' {
        $copies = @(
            (New-Copy 'g\1' 'REQUESTED'), (New-Copy 'g\2' 'requested'), (New-Copy 'g\3' 'RELEASED'), (New-Copy 'g\4' 'REQUESTED' '' '08:10' $true),
            (New-Copy 'g\5' 'DENIED'), (New-Copy 'g\6' 'NOTRELEASED'), (New-Copy 'g\7' 'notreleased'), (New-Copy 'g\8' 'ERROR')
        )
        $n = Get-RrCopyCounts $copies
        $n.Pending | Should -Be 2
        $n.Released | Should -Be 2
        $n.Denied | Should -Be 1
        $n.NotRequested | Should -Be 3
        $n.Total | Should -Be 8
        $n.Unknown | Should -BeFalse
        (Get-RrCopyCounts @()).Total | Should -Be 0
        (Get-RrCopyCounts $null).Total | Should -Be 0
    }
    It 'formats the copies with a middle dot and leaves zero parts out' {
        $dot = [string][char]0x00B7
        function New-Counts($p, $r, $dn, $nr, $u = $false) { [pscustomobject]@{ Pending = $p; Released = $r; Denied = $dn; NotRequested = $nr; Unknown = $u } }
        Format-RrCopies (New-Counts 2 2 0 3) | Should -Be "2 pending $dot 2 released $dot 3 not requested"
        Format-RrCopies (New-Counts 1 0 0 3) | Should -Be "1 pending $dot 3 not requested"
        Format-RrCopies (New-Counts 1 0 0 0) | Should -Be '1 pending'
        Format-RrCopies (New-Counts 0 0 2 0) | Should -Be '2 denied'
        Format-RrCopies (New-Counts 0 4 1 0) | Should -Be "4 released $dot 1 denied"
        Format-RrCopies (New-Counts 1 0 0 0 $true) | Should -Be "1 pending $dot other copies unknown"
        Format-RrCopies (New-Counts 0 0 0 0 $true) | Should -Be 'other copies unknown'
        Format-RrCopies (New-Counts 0 0 0 0) | Should -Be ''
    }
}

Describe 'ReleaseRequests: one row per message' {
    BeforeAll {
        $script:M1 = '<m1@invoice-pay.example>'; $script:M2 = '<m2@parcel-track.example>'
        $script:Dot = [string][char]0x00B7
        $script:PendingRows = @(
            (New-Copy 'g1\a1' 'REQUESTED' $script:M1 '08:12'), (New-Copy 'g1\a2' 'REQUESTED' $script:M1 '08:10'),
            (New-Copy 'g2\b1' 'REQUESTED' $script:M2 '09:00'),
            (New-Copy 'g3\c1' 'REQUESTED' '' '10:00'), (New-Copy 'g3\c2' 'REQUESTED' '' '10:05')
        )
        $script:Lookup1 = @(
            (New-Copy 'g1\a1' 'REQUESTED' $script:M1 '08:12'), (New-Copy 'g1\a2' 'REQUESTED' $script:M1 '08:10'),
            (New-Copy 'g1\a3' 'RELEASED' $script:M1 '08:11' $true), (New-Copy 'g1\a4' 'RELEASED' $script:M1 '08:11' $true),
            (New-Copy 'g1\a5' 'NOTRELEASED' $script:M1 '08:11'), (New-Copy 'g1\a6' 'NOTRELEASED' $script:M1 '08:11'), (New-Copy 'g1\a7' 'NOTRELEASED' $script:M1 '08:11')
        )
        $script:Lookup2 = @((New-Copy 'g2\b1' 'REQUESTED' $script:M2 '09:00'), (New-Copy 'g2\b2' 'NOTRELEASED' $script:M2 '09:00'), (New-Copy 'g2\b3' 'NOTRELEASED' $script:M2 '09:00'), (New-Copy 'g2\b4' 'NOTRELEASED' $script:M2 '09:00'))
    }
    It 'groups 5 rows into 3 messages with the earliest Received and a pending ExportIdentity' {
        $g = @(Group-RrMessages $script:PendingRows @{ $script:M1 = $script:Lookup1; $script:M2 = $script:Lookup2 })
        $g.Count | Should -Be 3
        $g[0].Key | Should -Be $script:M1
        $g[0].Received | Should -Be ([datetime]'2026-11-25 08:10')
        $g[0].ExportIdentity | Should -Be 'g1\a1'
        $g[0].CopiesText | Should -Be "2 pending $($script:Dot) 2 released $($script:Dot) 3 not requested"
        $g[0].HasReleasedCopy | Should -BeTrue
        $g[0].RecipientCount | Should -Be 7
        $g[0].Status | Should -Be 'Pending'
        $g[0].Counts.Pending | Should -Be 2
        $g[1].Key | Should -Be $script:M2
        $g[1].CopiesText | Should -Be "1 pending $($script:Dot) 3 not requested"
        $g[1].HasReleasedCopy | Should -BeFalse
        $g[1].RecipientCount | Should -Be 4
        # no MessageId: the key is the identity before the backslash, and only the rows already returned are used
        $g[2].Key | Should -Be 'g3'
        $g[2].Received | Should -Be ([datetime]'2026-11-25 10:00')
        $g[2].CopiesText | Should -Be '2 pending'
        $g[2].RecipientCount | Should -Be 2
        $g[2].Sender | Should -Be 'billing@invoice-pay.example'
        $g[2].Subject | Should -Be 'Subject of '
        $g[2].QuarantineTypes | Should -Be 'Phish'
        $g[2].Expires | Should -Be ([datetime]'2026-12-25')
        @($g | ForEach-Object { $_.PSObject.Properties.Name } | Select-Object -Unique) | Should -Be @('Key', 'ExportIdentity', 'Received', 'Sender', 'Subject', 'QuarantineTypes', 'Expires', 'Counts', 'CopiesText', 'Status', 'HasReleasedCopy', 'RecipientCount')
    }
    It 'prefers a pending copy for the export, even when the first row is not pending' {
        $rows = @((New-Copy 'g9\x1' 'RELEASED' '<m9@x.example>' '08:00' $true))
        $look = @((New-Copy 'g9\x1' 'RELEASED' '<m9@x.example>' '08:00' $true), (New-Copy 'g9\x2' 'REQUESTED' '<m9@x.example>' '08:05'))
        $g = @(Group-RrMessages $rows @{ '<m9@x.example>' = $look })
        $g[0].ExportIdentity | Should -Be 'g9\x2'
        $g[0].Status | Should -Be 'Pending'
        $g[0].Received | Should -Be ([datetime]'2026-11-25 08:00')
    }
    It 'gives Released or Denied for a message with no pending copy, by the larger count, and the first copy to export' {
        $rel = @(Group-RrMessages @((New-Copy 'g5\1' 'RELEASED' '<m5@x.example>' '08:00'), (New-Copy 'g5\2' 'RELEASED' '<m5@x.example>' '08:01')) @{})
        $rel[0].Status | Should -Be 'Released'
        $rel[0].ExportIdentity | Should -Be 'g5\1'
        $rel[0].HasReleasedCopy | Should -BeTrue
        $den = @(Group-RrMessages @((New-Copy 'g6\1' 'DENIED' '<m6@x.example>'), (New-Copy 'g6\2' 'DENIED' '<m6@x.example>')) @{})
        $den[0].Status | Should -Be 'Denied'
        $den[0].HasReleasedCopy | Should -BeFalse
        $mix = @(Group-RrMessages @((New-Copy 'g7\1' 'DENIED' '<m7@x.example>'), (New-Copy 'g7\2' 'RELEASED' '<m7@x.example>'), (New-Copy 'g7\3' 'RELEASED' '<m7@x.example>')) @{})
        $mix[0].Status | Should -Be 'Released'
    }
    It 'marks the copies unknown when the lookup failed, and keeps the group' {
        $g = @(Group-RrMessages $script:PendingRows @{ $script:M1 = $script:Lookup1; $script:M2 = $null })
        $g.Count | Should -Be 3
        $g[1].Counts.Unknown | Should -BeTrue
        $g[1].CopiesText | Should -Be "1 pending $($script:Dot) other copies unknown"
        $g[1].ExportIdentity | Should -Be 'g2\b1'
        $g[0].Counts.Unknown | Should -BeFalse
    }
    It 'builds the Copies cell with a leading mark only when a copy was released, and the tooltip text' {
        $g = @(Group-RrMessages $script:PendingRows @{ $script:M1 = $script:Lookup1; $script:M2 = $script:Lookup2 })
        Get-RrCopiesCell $g[0] | Should -Be "! 2 pending $($script:Dot) 2 released $($script:Dot) 3 not requested"
        Get-RrCopiesCell $g[1] | Should -Be "1 pending $($script:Dot) 3 not requested"
        Get-RrRowTip $g[0] | Should -Be 'Released to 2 recipient(s) already. Decide for all copies in Defender.'
        Get-RrRowTip $g[1] | Should -Be ''
    }
}

Describe 'ReleaseRequests: Get-RrMessages (the listing step)' {
    BeforeAll {
        $script:Now = [datetime]'2026-11-26 12:00'
        function New-Msg($c) {
            [pscustomobject]@{
                Identity = $c.Identity; MessageId = $c.MessageId; ReleaseStatus = $c.ReleaseStatus; Released = $c.Released; ReceivedTime = $c.Received
                SenderAddress = $c.Sender; RecipientAddress = @('r@corp.example'); Subject = $c.Subject; QuarantineTypes = $c.QuarantineTypes; Expires = $c.Expires
            }
        }
        $script:Q1 = '<q1@invoice-pay.example>'; $script:Q2 = '<q2@parcel-track.example>'
        $script:PendingCopies = @((New-Copy 'q1\a1' 'REQUESTED' $script:Q1 '08:12'), (New-Copy 'q1\a2' 'REQUESTED' $script:Q1 '08:10'), (New-Copy 'q2\b1' 'REQUESTED' $script:Q2 '09:00'))
        $script:AllQ1 = @($script:PendingCopies[0], $script:PendingCopies[1], (New-Copy 'q1\a3' 'RELEASED' $script:Q1 '08:11' $true), (New-Copy 'q1\a4' 'NOTRELEASED' $script:Q1 '08:11'))
        $script:AllQ2 = @($script:PendingCopies[2], (New-Copy 'q2\b2' 'NOTRELEASED' $script:Q2 '09:00'))
    }
    It 'toggle off: one -ReleaseStatus Requested query plus one -MessageId lookup per message, nothing else' {
        Mock Get-QuarantineMessage { @($script:PendingCopies | ForEach-Object { New-Msg $_ }) } -ParameterFilter { $ReleaseStatus -eq 'Requested' }
        Mock Get-QuarantineMessage { @($script:AllQ1 | ForEach-Object { New-Msg $_ }) } -ParameterFilter { $MessageId -eq $script:Q1 }
        Mock Get-QuarantineMessage { @($script:AllQ2 | ForEach-Object { New-Msg $_ }) } -ParameterFilter { $MessageId -eq $script:Q2 }
        $res = Get-RrMessages -Days 5 -Now $script:Now
        Should -Invoke Get-QuarantineMessage -Times 1 -Exactly -ParameterFilter { $ReleaseStatus }
        Should -Invoke Get-QuarantineMessage -Times 1 -Exactly -ParameterFilter {
            $ReleaseStatus -eq 'Requested' -and $PageSize -eq 1000 -and $StartReceivedDate -eq $script:Now.AddDays(-5) -and $EndReceivedDate -eq $script:Now -and -not $RecipientAddress
        }
        Should -Invoke Get-QuarantineMessage -Times 0 -ParameterFilter { $ReleaseStatus -eq 'Released' -or $ReleaseStatus -eq 'Denied' }
        Should -Invoke Get-QuarantineMessage -Times 2 -Exactly -ParameterFilter { $MessageId }
        Should -Invoke Get-QuarantineMessage -Times 1 -Exactly -ParameterFilter { $MessageId -eq $script:Q1 }
        Should -Invoke Get-QuarantineMessage -Times 1 -Exactly -ParameterFilter { $MessageId -eq $script:Q2 }
        Should -Invoke Get-QuarantineMessage -Times 0 -ParameterFilter { $ReleaseStatus -and $MessageId }
        $res.RawPending | Should -Be 3
        $res.Handled | Should -BeFalse
        @($res.Messages).Count | Should -Be 2
        $res.Messages[0].CopiesText | Should -Be "2 pending $([char]0x00B7) 1 released $([char]0x00B7) 1 not requested"
        $res.Messages[0].HasReleasedCopy | Should -BeTrue
        $res.Messages[1].CopiesText | Should -Be "1 pending $([char]0x00B7) 1 not requested"
    }
    It 'toggle on: also queries Released and Denied with the same window and recipient' {
        $released = @((New-Copy 'q3\r1' 'RELEASED' '<q3@x.example>' '07:00' $true))
        $denied = @((New-Copy 'q4\d1' 'DENIED' '<q4@x.example>' '07:30'))
        Mock Get-QuarantineMessage { @($script:PendingCopies | ForEach-Object { New-Msg $_ }) } -ParameterFilter { $ReleaseStatus -eq 'Requested' }
        Mock Get-QuarantineMessage { @($released | ForEach-Object { New-Msg $_ }) } -ParameterFilter { $ReleaseStatus -eq 'Released' }
        Mock Get-QuarantineMessage { @($denied | ForEach-Object { New-Msg $_ }) } -ParameterFilter { $ReleaseStatus -eq 'Denied' }
        Mock Get-QuarantineMessage { @($script:AllQ1 | ForEach-Object { New-Msg $_ }) } -ParameterFilter { $MessageId -eq $script:Q1 }
        Mock Get-QuarantineMessage { @($script:AllQ2 | ForEach-Object { New-Msg $_ }) } -ParameterFilter { $MessageId -eq $script:Q2 }
        Mock Get-QuarantineMessage { @($released | ForEach-Object { New-Msg $_ }) } -ParameterFilter { $MessageId -eq '<q3@x.example>' }
        Mock Get-QuarantineMessage { @($denied | ForEach-Object { New-Msg $_ }) } -ParameterFilter { $MessageId -eq '<q4@x.example>' }
        $res = Get-RrMessages -Days 5 -Recipient ' r@corp.example ' -IncludeHandled -Now $script:Now
        foreach ($st in 'Requested', 'Released', 'Denied') {
            Should -Invoke Get-QuarantineMessage -Times 1 -Exactly -ParameterFilter {
                $ReleaseStatus -eq $st -and $PageSize -eq 1000 -and $StartReceivedDate -eq $script:Now.AddDays(-5) -and $EndReceivedDate -eq $script:Now -and $RecipientAddress -eq 'r@corp.example'
            }
        }
        Should -Invoke Get-QuarantineMessage -Times 4 -Exactly -ParameterFilter { $MessageId }
        $res.Handled | Should -BeTrue
        @($res.Messages).Count | Should -Be 4
        @($res.Messages | ForEach-Object { $_.Status }) | Should -Be @('Pending', 'Pending', 'Released', 'Denied')
        $res.Messages[2].ExportIdentity | Should -Be 'q3\r1'
    }
    It 'a copy with REQUESTED but Released = true is not pending, and the cap counts the raw query rows' {
        Mock Get-QuarantineMessage { @((New-Copy 'q8\a1' 'REQUESTED' '<q8@x.example>' '08:00' $true), (New-Copy 'q9\a1' 'REQUESTED' '<q9@x.example>' '08:00') | ForEach-Object { New-Msg $_ }) } -ParameterFilter { $ReleaseStatus -eq 'Requested' }
        Mock Get-QuarantineMessage { } -ParameterFilter { $MessageId }
        $res = Get-RrMessages -Days 5 -Now $script:Now
        @($res.Messages).Count | Should -Be 1
        $res.Messages[0].Key | Should -Be '<q9@x.example>'
        $res.RawPending | Should -Be 2
        Mock Get-QuarantineMessage { 1..1000 | ForEach-Object { New-Msg (New-Copy "qc$_\a" 'REQUESTED' '') } } -ParameterFilter { $ReleaseStatus -eq 'Requested' }
        (Get-RrMessages -Days 5 -Now $script:Now).RawPending | Should -Be 1000
    }
    It 'skips the lookup when there is no MessageId and uses the rows already returned' {
        Mock Get-QuarantineMessage { @((New-Copy 'n1\a1' 'REQUESTED' ''), (New-Copy 'n1\a2' 'REQUESTED' '')) | ForEach-Object { New-Msg $_ } } -ParameterFilter { $ReleaseStatus -eq 'Requested' }
        Mock Get-QuarantineMessage { throw 'must not be called' } -ParameterFilter { $MessageId }
        $res = Get-RrMessages -Days 5 -Now $script:Now
        Should -Invoke Get-QuarantineMessage -Times 0 -ParameterFilter { $MessageId }
        @($res.Messages).Count | Should -Be 1
        $res.Messages[0].CopiesText | Should -Be '2 pending'
        $res.Messages[0].Counts.Unknown | Should -BeFalse
    }
    It 'a failed -MessageId lookup keeps the message and marks other copies unknown' {
        Mock Get-QuarantineMessage { @($script:PendingCopies | ForEach-Object { New-Msg $_ }) } -ParameterFilter { $ReleaseStatus -eq 'Requested' }
        Mock Get-QuarantineMessage { @($script:AllQ1 | ForEach-Object { New-Msg $_ }) } -ParameterFilter { $MessageId -eq $script:Q1 }
        Mock Get-QuarantineMessage { throw 'throttled: simulated' } -ParameterFilter { $MessageId -eq $script:Q2 }
        $res = Get-RrMessages -Days 5 -Now $script:Now
        @($res.Messages).Count | Should -Be 2
        $res.Messages[1].CopiesText | Should -Be "1 pending $([char]0x00B7) other copies unknown"
        $res.Messages[1].Counts.Unknown | Should -BeTrue
        $res.Messages[1].ExportIdentity | Should -Be 'q2\b1'
        $res.Messages[0].Counts.Unknown | Should -BeFalse
    }
    It 'a failing main query throws, so the dialog shows the error' {
        Mock Get-QuarantineMessage { throw 'no access: simulated' } -ParameterFilter { $ReleaseStatus -eq 'Requested' }
        { Get-RrMessages -Days 5 -Now $script:Now } | Should -Throw '*no access: simulated*'
    }
    It 'reports the lookup progress through $State' {
        $State = [hashtable]::Synchronized(@{})
        Mock Get-QuarantineMessage { @($script:PendingCopies | ForEach-Object { New-Msg $_ }) } -ParameterFilter { $ReleaseStatus -eq 'Requested' }
        Mock Get-QuarantineMessage { @($script:AllQ1 | ForEach-Object { New-Msg $_ }) } -ParameterFilter { $MessageId -eq $script:Q1 }
        Mock Get-QuarantineMessage { @($script:AllQ2 | ForEach-Object { New-Msg $_ }) } -ParameterFilter { $MessageId -eq $script:Q2 }
        $null = Get-RrMessages -Days 5 -Now $script:Now
        $State.Progress | Should -Be 'Checking other copies (2 of 2)...'
    }
    It 'exports one copy per selected message: the pending ExportIdentity, one ZIP each' {
        $inc = Join-Path $TestDrive 'per-message-incoming'
        Mock Get-QuarantineMessage { @($script:PendingCopies | ForEach-Object { New-Msg $_ }) } -ParameterFilter { $ReleaseStatus -eq 'Requested' }
        Mock Get-QuarantineMessage { @($script:AllQ1 | ForEach-Object { New-Msg $_ }) } -ParameterFilter { $MessageId -eq $script:Q1 }
        Mock Get-QuarantineMessage { @($script:AllQ2 | ForEach-Object { New-Msg $_ }) } -ParameterFilter { $MessageId -eq $script:Q2 }
        $b64 = [Convert]::ToBase64String((New-TestZip -Flags 1 -Aes))
        Mock Export-QuarantineMessage { [pscustomobject]@{ Eml = $b64 } }
        $msgs = @((Get-RrMessages -Days 5 -Now $script:Now).Messages)
        $msgs.Count | Should -Be 2
        foreach ($m in $msgs) {
            (Save-RrExport -Identity $m.ExportIdentity -Received $m.Received -Password (New-SecurePw 'x') -Incoming $inc).Status | Should -Be 'Saved'
        }
        Should -Invoke Export-QuarantineMessage -Times 2 -Exactly
        Should -Invoke Export-QuarantineMessage -Times 1 -Exactly -ParameterFilter { $Identity -eq 'q1\a1' }
        Should -Invoke Export-QuarantineMessage -Times 1 -Exactly -ParameterFilter { $Identity -eq 'q2\b1' }
        Should -Invoke Export-QuarantineMessage -Times 0 -ParameterFilter { $Identity -eq 'q1\a2' -or $Identity -eq 'q1\a3' }
        $files = @(Get-ChildItem -LiteralPath $inc -File | ForEach-Object { $_.Name } | Sort-Object)
        $files.Count | Should -Be 2
        $files | Should -Be @((Get-RrFileName $msgs[0].Received 'q1\a1'), (Get-RrFileName $msgs[1].Received 'q2\b1') | Sort-Object)
        $files[0] | Should -Match '^20261125-08\d\d-[0-9a-f]{10}\.zip$'
    }
}

Describe 'ReleaseRequests: aggregated and per-recipient shapes' {
    It 'weights an aggregated row by RecipientCount or the address list, and a per-recipient row as one' {
        $agg = New-Copy 'a1\1' 'REQUESTED' '<agg@x.example>'
        $agg | Add-Member RecipientCount 5
        Get-RrCopyWeight $agg | Should -Be 5
        $addr = New-Copy 'a1\2' 'REQUESTED' '<agg2@x.example>'
        $addr | Add-Member RecipientAddress @('a@corp.example', 'b@corp.example', 'c@corp.example')
        Get-RrCopyWeight $addr | Should -Be 3
        Get-RrCopyWeight (New-Copy 'p\1') | Should -Be 1
        $zero = New-Copy 'p\2'; $zero | Add-Member RecipientCount 0; $zero | Add-Member RecipientAddress @()
        Get-RrCopyWeight $zero | Should -Be 1
        (ConvertTo-RrRow ([pscustomobject]@{ Identity = 'a\b'; RecipientCount = 5; RecipientAddress = @('x@corp.example') })).RecipientCount | Should -Be 5
        (ConvertTo-RrRow ([pscustomobject]@{ Identity = 'a\b'; RecipientAddress = @() })).RecipientCount | Should -Be 1
    }
    It '(a) aggregated: one row with RecipientCount 5 and REQUESTED is one message with 5 pending' {
        $agg = New-Copy 'ag\1' 'REQUESTED' '<agg@x.example>'
        $agg | Add-Member RecipientCount 5
        $g = @(Group-RrMessages @($agg) @{})
        $g.Count | Should -Be 1
        $g[0].Counts.Pending | Should -Be 5
        $g[0].RecipientCount | Should -Be 5
        $g[0].CopiesText | Should -Be '5 pending'
        $g[0].ExportIdentity | Should -Be 'ag\1'
    }
    It '(b) per-recipient: 3 rows with one MessageId, one with an empty RecipientAddress, are one message' {
        $rows = @(
            (New-Copy 'pr\a' 'REQUESTED' '<pr@x.example>'), (New-Copy 'pr\b' 'REQUESTED' '<pr@x.example>'), (New-Copy 'pr\c' 'REQUESTED' '<pr@x.example>')
        )
        $rows[0] | Add-Member RecipientAddress @('a@corp.example'); $rows[1] | Add-Member RecipientAddress @('b@corp.example'); $rows[2] | Add-Member RecipientAddress @()
        $g = @(Group-RrMessages $rows @{})
        $g.Count | Should -Be 1
        $g[0].CopiesText | Should -Be '3 pending'
        $g[0].RecipientCount | Should -Be 3
    }
    It '(c) mixed: an aggregated released entry and per-recipient pending ones add up' {
        $rel = New-Copy 'mx\r' 'RELEASED' '<mx@x.example>' '08:00' $true
        $rel | Add-Member RecipientCount 4
        $look = @($rel, (New-Copy 'mx\p1' 'REQUESTED' '<mx@x.example>' '08:05'), (New-Copy 'mx\p2' 'REQUESTED' '<mx@x.example>' '08:06'))
        $g = @(Group-RrMessages @($look[1], $look[2]) @{ '<mx@x.example>' = $look })
        $g.Count | Should -Be 1
        $g[0].CopiesText | Should -Be "2 pending $([char]0x00B7) 4 released"
        $g[0].HasReleasedCopy | Should -BeTrue
        $g[0].ExportIdentity | Should -Be 'mx\p1'
    }
    BeforeAll { function New-Msg($c) { [pscustomobject]@{ Identity = $c.Identity; MessageId = $c.MessageId; ReleaseStatus = $c.ReleaseStatus; Released = $c.Released; ReceivedTime = $c.Received; SenderAddress = $c.Sender; RecipientAddress = @(); Subject = $c.Subject; QuarantineTypes = $c.QuarantineTypes; Expires = $c.Expires } } }
    It 'passes the MessageId, angle brackets included, to -MessageId unchanged' {
        $mid = '<CAF=weird+id.1@mail.example.com>'
        Mock Get-QuarantineMessage { New-Msg (New-Copy 'br\1' 'REQUESTED' $mid) } -ParameterFilter { $ReleaseStatus -eq 'Requested' }
        Mock Get-QuarantineMessage { New-Msg (New-Copy 'br\1' 'REQUESTED' $mid) } -ParameterFilter { $MessageId }
        $null = Get-RrMessages -Days 5
        Should -Invoke Get-QuarantineMessage -Times 1 -Exactly -ParameterFilter { $MessageId -ceq $mid }
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
        function global:Get-QuarantineMessage { [CmdletBinding()] param($ReleaseStatus, $PageSize, $StartReceivedDate, $EndReceivedDate, $RecipientAddress, $MessageId) $State.Listed = $true }
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
        Invoke-Expression ("function global:Get-QuarantineMessage { [CmdletBinding()] param(`$ReleaseStatus, `$PageSize, `$StartReceivedDate, `$EndReceivedDate, `$RecipientAddress, `$MessageId) [pscustomobject]@{ Identity = 'a\b'; MessageId = ''; ReleaseStatus = 'REQUESTED'; Released = `$false; ReceivedTime = [datetime]'2026-11-25 08:11'; SenderAddress = 's@x.example'; RecipientAddress = @('r@corp.example'); Subject = 'S'; QuarantineTypes = 'Phish'; Expires = [datetime]'2026-12-25' } }")
        Invoke-Expression ("function global:Export-QuarantineMessage { [CmdletBinding()] param(`$Identity, [switch]`$CompressOutput, `$Password, `$ReasonForExport) [pscustomobject]@{ Eml = '$b64' } }")
        $s = New-RrSession -Functions (@('Get-QuarantineMessage', 'Export-QuarantineMessage') + (Get-RrSessionFunctionNames))
        $inc = Join-Path $TestDrive 'session-incoming'
        try {
            $w = Invoke-RrStep $s { Get-RrMessages -Days $RrDays -Recipient $RrRecipient -IncludeHandled:$RrHandled } @{ RrDays = 7; RrRecipient = ''; RrHandled = $false }
            while (-not $w.Handle.IsCompleted) { Start-Sleep -Milliseconds 20 }
            $payload = @((Complete-RrStep $w).Output | Where-Object { $_.PSObject.Properties['Messages'] })[-1]
            $rows = @($payload.Messages)
            $rows.Count | Should -Be 1
            $rows[0].Sender | Should -Be 's@x.example'
            $rows[0].CopiesText | Should -Be '1 pending'
            $s.State.Progress | Should -Be 'Checking other copies (1 of 1)...'
            $vars = @{ RrIdentity = [string]$rows[0].ExportIdentity; RrReceived = [datetime]$rows[0].Received; RrPassword = (New-SecurePw $script:PwSentinel); RrIncoming = $inc }
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
function Get-QuarantineMessage { [CmdletBinding()] param($ReleaseStatus, $PageSize, $StartReceivedDate, $EndReceivedDate, $RecipientAddress, $MessageId) $State.Listed = $true }
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
    [CmdletBinding()] param($ReleaseStatus, $PageSize, $StartReceivedDate, $EndReceivedDate, $RecipientAddress, $MessageId)
    foreach ($n in 1, 2) {
        [pscustomobject]@{ Identity = "00000000-0000-4000-8000-00000000000$n\00000000-0000-4000-8000-0000000000a$n"; ReleaseStatus = 'REQUESTED'; Released = $false; ReceivedTime = ([datetime]'2026-11-25 08:10').AddMinutes($n)
            SenderAddress = "billing$n@invoice-pay.example"; RecipientAddress = @('a@corp.example'); Subject = "Invoice $n"; QuarantineTypes = 'Phish'; Expires = [datetime]'2026-12-25' }
    }
}
$exportCode = 'function Export-QuarantineMessage { [CmdletBinding()] param($Identity, [switch]$CompressOutput, $Password, $ReasonForExport) $State.ExportIds = @($State.ExportIds | Where-Object { $_ }) + $Identity; [pscustomobject]@{ Eml = ''' + $b64 + ''' } }'
Invoke-Expression $exportCode
$d = New-RrDialog -Incoming $inc -SessionFunctions @('Connect-ExchangeOnline', 'Disconnect-ExchangeOnline', 'Get-QuarantineMessage', 'Export-QuarantineMessage') -NoAutoStart
Show-Offscreen $d.Form
$d.Module = [pscustomobject]@{ Installed = $true; Version = '9.9.9'; InstallCommand = '' }
Update-RrView $d
$d.Ctl.BSignIn.PerformClick()
Wait-Until { $d.ListState -eq 'loaded' -or $d.ListState -eq 'failed' }
$sess = $d.Session
$listed = @{ State = $d.ListState; Items = $d.Ctl.List.Items.Count; Ticked = $d.Ctl.List.CheckedItems.Count; Note = $d.ListMsg; SaveEnabledEarly = $d.Ctl.BSave.Enabled; Connect = $d.ConnectState
    Columns = (@($d.Ctl.List.Columns | ForEach-Object { $_.Text }) -join '|'); Cells = (@($d.Ctl.List.Items[1].SubItems | ForEach-Object { $_.Text }) -join '|'); HScroll = ($d.Ctl.List.Columns | Measure-Object Width -Sum).Sum -gt $d.Ctl.List.ClientSize.Width }
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
    PwBox = $d.Ctl.Pw.Text; ExportIds = @($sess.State.ExportIds)
}
$d.Form.Close()
$out | Add-Member Disconnected ([bool]$sess.State.Disconnected)
$out | ConvertTo-Json -Compress -Depth 4
'@
        $r = Get-ChildJson (Invoke-ChildPs $body)
        $r.Listed.State | Should -Be 'loaded'
        $r.Listed.Items | Should -Be 2
        $r.Listed.Ticked | Should -Be 0
        $r.Listed.Note | Should -Be '2 messages with pending requests (2 recipient copies). Nothing is selected yet.'
        $r.Listed.Columns | Should -Be 'Received|Sender|Subject|Quarantine type|Copies|Expires'
        $r.Listed.Cells | Should -Be '2026-11-25 08:12|billing2@invoice-pay.example|Invoice 2|Phish|1 pending|2026-12-25'
        $r.Listed.HScroll | Should -BeFalse
        $r.Listed.SaveEnabledEarly | Should -BeFalse
        $r.EnabledNoPw | Should -BeFalse
        $r.EnabledWithPw | Should -BeTrue
        $r.PwAfterClick | Should -Be ''
        $r.PwBox | Should -Be ''
        $r.Summary | Should -Be 'Saved 1 of 1 to Incoming'
        @($r.Files).Count | Should -Be 1
        @($r.Files)[0] | Should -Match '^20261125-0812-[0-9a-f]{10}\.zip$'
        @($r.ExportIds) | Should -Be @('00000000-0000-4000-8000-000000000002\00000000-0000-4000-8000-0000000000a2')
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
    [CmdletBinding()] param($ReleaseStatus, $PageSize, $StartReceivedDate, $EndReceivedDate, $RecipientAddress, $MessageId)
    [pscustomobject]@{ Identity = '00000000-0000-4000-8000-000000000001\00000000-0000-4000-8000-0000000000a1'; ReleaseStatus = 'REQUESTED'; Released = $false; ReceivedTime = [datetime]'2026-11-25 08:11'
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

Describe 'ReleaseRequests: dialog, handled view and screenshot data (child Windows PowerShell 5.1)' {
    BeforeAll {
        $script:ChildHead2 = @"
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
function Out-AsciiJson(`$obj) {
    `$j = `$obj | ConvertTo-Json -Compress -Depth 5
    [regex]::Replace(`$j, '[^\x00-\x7F]', { param(`$m) ('\u{0:x4}' -f [int][char]`$m.Value) })
}
"@
    }
    It 'the checkbox is off by default, its note is shown, and turning it on adds the released and denied queries' {
        $body = $script:ChildHead2 + @'
function Connect-ExchangeOnline { [CmdletBinding()] param([switch]$ShowBanner) }
function Disconnect-ExchangeOnline { [CmdletBinding()] param([switch]$Confirm) }
function Get-QuarantineMessage {
    [CmdletBinding()] param($ReleaseStatus, $PageSize, $StartReceivedDate, $EndReceivedDate, $RecipientAddress, $MessageId)
    $State.Calls = @($State.Calls | Where-Object { $_ }) + ("status=$ReleaseStatus;mid=$MessageId")
    function Row($id, $status, $rel) { [pscustomobject]@{ Identity = $id; MessageId = '<m1@invoice-pay.example>'; ReleaseStatus = $status; Released = $rel; ReceivedTime = [datetime]'2026-11-25 08:11'
        SenderAddress = 'billing@invoice-pay.example'; RecipientAddress = @('a@corp.example'); Subject = 'Invoice'; QuarantineTypes = 'Phish'; Expires = [datetime]'2026-12-25' } }
    function Denied { [pscustomobject]@{ Identity = 'g2\d1'; MessageId = '<m2@invoice-pay.example>'; ReleaseStatus = 'DENIED'; Released = $false; ReceivedTime = [datetime]'2026-11-25 07:00'
        SenderAddress = 'old@invoice-pay.example'; RecipientAddress = @('a@corp.example'); Subject = 'Old'; QuarantineTypes = 'Spam'; Expires = [datetime]'2026-12-25' } }
    if ($MessageId -eq '<m1@invoice-pay.example>') { Row 'g1\a1' 'REQUESTED' $false; Row 'g1\a2' 'RELEASED' $true; Row 'g1\a3' 'NOTRELEASED' $false; return }
    if ($MessageId -eq '<m2@invoice-pay.example>') { Denied; return }
    if ($ReleaseStatus -eq 'Requested') { Row 'g1\a1' 'REQUESTED' $false }
    if ($ReleaseStatus -eq 'Denied') { Denied }
}
$d = New-RrDialog -Incoming (Join-Path $env:TEMP 'qra-rr-none') -SessionFunctions @('Connect-ExchangeOnline', 'Disconnect-ExchangeOnline', 'Get-QuarantineMessage') -NoAutoStart
Show-Offscreen $d.Form
$d.Module = [pscustomobject]@{ Installed = $true; Version = '9.9.9'; InstallCommand = '' }
Update-RrView $d
$d.Ctl.BSignIn.PerformClick()
Wait-Until { $d.ListState -eq 'loaded' -or $d.ListState -eq 'failed' }
$sess = $d.Session
$first = @{ Checked = $d.Ctl.ChkHandled.Checked; Visible = $d.Ctl.ChkHandled.Visible; Text = $d.Ctl.ChkHandled.Text; Note = $d.Ctl.LblHandled.Text; NoteVisible = $d.Ctl.LblHandled.Visible
    Hint = $d.Ctl.LblListHint.Text; HintVisible = $d.Ctl.LblListHint.Visible; Items = $d.Ctl.List.Items.Count; Calls = (@($sess.State.Calls) -join ' | '); ListNote = $d.ListMsg
    Copies = $d.Ctl.List.Items[0].SubItems[4].Text; Tip = $d.Ctl.List.Items[0].ToolTipText; ShowTips = $d.Ctl.List.ShowItemToolTips; Flag = ($d.Ctl.List.Items[0].SubItems[4].ForeColor -eq $C.Warning) }
$sess.State.Calls = @()
$d.Ctl.ChkHandled.Checked = $true
$d.Ctl.BRefresh.PerformClick()
Wait-Until { $d.ListState -eq 'loaded' -or $d.ListState -eq 'failed' }
$second = @{ Items = $d.Ctl.List.Items.Count; Calls = (@($sess.State.Calls) -join ' | '); ListNote = $d.ListMsg
    MutedSecond = ($d.Ctl.List.Items[1].SubItems[2].ForeColor -eq $C.TextMuted); Status = @($d.Rows | ForEach-Object { $_.Status }) -join ',' }
$d.Form.Close()
Out-AsciiJson ([pscustomobject]@{ First = $first; Second = $second })
'@
        $r = Get-ChildJson (Invoke-ChildPs $body)
        $dot = [string][char]0x00B7
        $r.First.Checked | Should -BeFalse
        $r.First.Visible | Should -BeTrue
        $r.First.Text | Should -Be 'Also show released and denied messages'
        $r.First.Note | Should -Be 'Includes messages released by an admin without a request.'
        $r.First.NoteVisible | Should -BeTrue
        $r.First.Hint | Should -Be 'One row per message. Saving exports one copy; decide for all copies in Defender.'
        $r.First.HintVisible | Should -BeTrue
        $r.First.Items | Should -Be 1
        $r.First.Calls | Should -Be 'status=Requested;mid= | status=;mid=<m1@invoice-pay.example>'
        $r.First.ListNote | Should -Be '1 message with a pending request (1 recipient copy). Nothing is selected yet.'
        $r.First.Copies | Should -Be "! 1 pending $dot 1 released $dot 1 not requested"
        $r.First.Tip | Should -Be 'Released to 1 recipient(s) already. Decide for all copies in Defender.'
        $r.First.ShowTips | Should -BeTrue
        $r.First.Flag | Should -BeTrue
        $r.Second.Items | Should -Be 2
        $r.Second.Calls | Should -Be 'status=Requested;mid= | status=Released;mid= | status=Denied;mid= | status=;mid=<m1@invoice-pay.example> | status=;mid=<m2@invoice-pay.example>'
        $r.Second.ListNote | Should -Be '2 messages (1 with a pending request). Nothing is selected yet.'
        $r.Second.Status | Should -Be 'Pending,Denied'
        $r.Second.MutedSecond | Should -BeTrue
    }
    It 'the screenshot data is three synthetic messages, two selected, saved 2 of 2' {
        $body = $script:ChildHead2 + @'
$d = New-RrDialog -Incoming 'D:\SecurityReview\Incoming' -NoAutoStart
Show-Offscreen $d.Form
Set-RrScreenshotState $d 'results'
$items = $d.Ctl.List.Items
[pscustomobject]@{
    Count = $items.Count; Rows = @($items | ForEach-Object { ($_.SubItems | ForEach-Object { $_.Text }) -join '|' }); Checked = $d.Ctl.List.CheckedItems.Count
    Saved = $d.SaveSummary; Note = $d.ListMsg; Flags = @($d.Rows | ForEach-Object { $_.HasReleasedCopy })
    Json = ($d.Rows | ConvertTo-Json -Depth 5 -Compress)
} | ForEach-Object { Out-AsciiJson $_ }
$d.Form.Close()
'@
        $r = Get-ChildJson (Invoke-ChildPs $body)
        $dot = [string][char]0x00B7
        $r.Count | Should -Be 3
        $r.Checked | Should -Be 2
        $r.Saved | Should -Be 'Saved 2 of 2 to Incoming'
        $r.Rows[0] | Should -BeLike "2026-11-25 08:12|billing@invoice-pay.example|*|HighConfPhish|! 2 pending $dot 2 released $dot 3 not requested|2026-12-25"
        $r.Rows[1] | Should -BeLike "2026-11-25 09:03|*|Phish|1 pending $dot 3 not requested|2026-12-25"
        $r.Rows[2] | Should -BeLike "2026-11-25 09:47|*|Spam|1 pending|2026-12-25"
        @($r.Flags) | Should -Be @($true, $false, $false)
        $r.Json | Should -Not -Match '(?i)@(?!\w[\w.-]*\.example)'
        $r.Json | Should -Match '00000000-0000-4000-8000'
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

Describe 'Release requests: wording and window chrome' {
    It 'has no tick/ticked/unticked in any user-facing string' {
        $tokens = $null; $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:RrPath, [ref]$tokens, [ref]$errs)
        $strings = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }, $true)
        @($strings | Where-Object { $_.Value -match '(?i)\b(un)?tick(ed)?\b' } | ForEach-Object { $_.Value }) | Should -BeNullOrEmpty
    }
    It 'uses select wording in the step summaries' {
        $t = [IO.File]::ReadAllText($script:RrPath)
        $t.Contains("'Nothing is selected by default. Select the messages to save.'") | Should -BeTrue
        $t.Contains("'Saves each selected message as a password-protected ZIP.'") | Should -BeTrue
    }
    It 'gives the dialog the app icon and the taskbar identity (not for the screenshot build)' {
        $t = [IO.File]::ReadAllText($script:RrPath)
        $t.Contains('Set-QraWindowChrome $form -NoAppId:([bool]$NoAutoStart)') | Should -BeTrue
    }
}
