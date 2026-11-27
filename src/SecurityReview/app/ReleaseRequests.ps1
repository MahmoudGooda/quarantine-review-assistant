# Quarantine Review Assistant - release-request intake (optional, v2.3).
# Lists messages that have a pending release request through Exchange Online PowerShell and saves the ones the reviewer selects
# as password-protected ZIPs in Incoming. Read-only: it never releases, deletes or blocks anything and never opens a message.
# Dot-sourced by Launcher.ps1 (functions only, no window) or run on its own:  ReleaseRequests.ps1 [-Incoming <folder>] [-Screenshot <folder>]
# Windows PowerShell 5.1 compatible. ASCII only (glyphs are built from char codes).
param(
    [Alias('Incoming')][string]$RrIncoming,
    [Alias('Screenshot')][string]$RrScreenshot,
    [Alias('ScreenshotState')][string]$RrScreenshotState
)
# The parameters carry the RR prefix so that dot-sourcing this file never overwrites $Incoming or $Screenshot of the launcher.

# ================================================================= pure functions (no Exchange, no window)

function Get-RrInstallCommand {
    "Install-Module ExchangeOnlineManagement -Scope CurrentUser; if (Get-Module -ListAvailable ExchangeOnlineManagement) { Write-Host ''; Write-Host 'Installed. Close this window to return to Quarantine Review Assistant.' -ForegroundColor Green } else { Write-Host ''; Write-Host 'The install did not finish. Read the message above, then close this window.' -ForegroundColor Yellow }"
}

function Get-RrModuleState {
    $mod = Get-Module -ListAvailable -Name ExchangeOnlineManagement -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
    $ver = ''
    if ($mod) { $ver = [string]$mod.Version }
    [pscustomobject]@{ Installed = [bool]$mod; Version = $ver; InstallCommand = (Get-RrInstallCommand) }
}

function Start-RrModuleInstall {
    # A visible Windows PowerShell 5.1 window: the user answers the prompts. The caller watches for the process to exit (never waits).
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $exe -ArgumentList '-NoProfile', '-NoExit', '-Command', (Get-RrInstallCommand) -PassThru
}

function Get-RrWindowDays([int]$days) {
    if ($days -eq 0) { return 16 }
    [Math]::Min(30, [Math]::Max(1, $days))
}

function Get-RrQuarantineParams([int]$Days, [string]$Recipient, [datetime]$Now = (Get-Date), [string]$Status = 'Requested') {
    $span = Get-RrWindowDays $Days
    $p = @{
        ReleaseStatus     = $Status
        PageSize          = 1000
        StartReceivedDate = $Now.AddDays(-$span)
        EndReceivedDate   = $Now
    }
    if ($Recipient -and $Recipient.Trim()) { $p.RecipientAddress = $Recipient.Trim() }
    $p
}

function ConvertTo-RrRow($message) {
    # One quarantine row = one recipient copy of a message.
    $rcpt = @($message.RecipientAddress | Where-Object { $_ }) -join '; '
    $types = @($message.QuarantineTypes | Where-Object { $_ }) -join ', '
    [pscustomobject]@{
        Identity        = [string]$message.Identity
        MessageId       = [string]$message.MessageId
        ReleaseStatus   = [string]$message.ReleaseStatus
        Released        = $message.Released
        RecipientCount  = [Math]::Max([Math]::Max(1, [int]$message.RecipientCount), @($message.RecipientAddress | Where-Object { $_ }).Count)
        Received        = $message.ReceivedTime
        Sender          = [string]$message.SenderAddress
        Recipient       = $rcpt
        Subject         = [string]$message.Subject
        QuarantineTypes = $types
        Expires         = $message.Expires
    }
}

function Get-RrRequests([int]$Days = 0, [string]$Recipient = '', [datetime]$Now = (Get-Date), [string]$Status = 'Requested') {
    # Raw rows (one per recipient copy) that have the given release status.
    $p = Get-RrQuarantineParams -Days $Days -Recipient $Recipient -Now $Now -Status $Status
    foreach ($msg in @(Get-QuarantineMessage @p -ErrorAction Stop)) { ConvertTo-RrRow $msg }
}

function Get-RrCapMessage([int]$count) {
    if ($count -ge 1000) { return 'Showing the first 1000. Narrow the date range or filter by recipient.' }
    ''
}

function Get-RrMessageKey($row) {
    # The message id when there is one, otherwise the part of the identity before the first backslash.
    $mid = ''
    $prop = $row.PSObject.Properties['MessageId']
    if ($prop -and $null -ne $prop.Value) { $mid = ([string]$prop.Value).Trim() }
    if ($mid) { return $mid }
    $id = ''
    $idProp = $row.PSObject.Properties['Identity']
    if ($idProp -and $null -ne $idProp.Value) { $id = [string]$idProp.Value }
    $cut = $id.IndexOf('\')
    if ($cut -ge 0) { return $id.Substring(0, $cut) }
    $id
}

function Get-RrCopyKind($copy) {
    # Pending, Released, Denied or NotRequested. Status text is compared without regard to case (Exchange returns REQUESTED, RELEASED, NOTRELEASED ...).
    $status = ''
    $prop = $copy.PSObject.Properties['ReleaseStatus']
    if ($prop -and $null -ne $prop.Value) { $status = ([string]$prop.Value).Trim().ToUpperInvariant() }
    $rel = $null
    $relProp = $copy.PSObject.Properties['Released']
    if ($relProp) { $rel = $relProp.Value }
    if ($rel -eq $true -or $status -eq 'RELEASED' -or $status -eq 'APPROVED') { return 'Released' }
    if ($status -eq 'REQUESTED') { return 'Pending' }
    if ($status -eq 'DENIED') { return 'Denied' }
    'NotRequested'
}

function Get-RrCopyWeight($copy) {
    # A per-recipient row is one copy. An aggregated row (one entry with several recipients) counts as all of them, with its own status.
    $w = 1
    $prop = $copy.PSObject.Properties['RecipientCount']
    if ($prop -and $null -ne $prop.Value) { try { $w = [Math]::Max($w, [int]$prop.Value) } catch { $null = $_ } }
    $addr = $copy.PSObject.Properties['RecipientAddress']
    if ($addr -and $null -ne $addr.Value) { $w = [Math]::Max($w, @($addr.Value | Where-Object { $_ }).Count) }
    $w
}

function Get-RrCopyCounts($copies) {
    $n = @{ Pending = 0; Released = 0; Denied = 0; NotRequested = 0 }
    foreach ($c in @($copies)) {
        if ($null -eq $c) { continue }
        $n[(Get-RrCopyKind $c)] += (Get-RrCopyWeight $c)
    }
    [pscustomobject]@{
        Pending = [int]$n.Pending; Released = [int]$n.Released; Denied = [int]$n.Denied; NotRequested = [int]$n.NotRequested
        Total   = [int]($n.Pending + $n.Released + $n.Denied + $n.NotRequested); Unknown = $false
    }
}

function Format-RrCopies($counts) {
    # For example: 2 pending . 2 released . 3 not requested (a middle dot between the parts, zero parts left out).
    $parts = New-Object System.Collections.Generic.List[string]
    if ($counts.Pending -gt 0) { $parts.Add("$($counts.Pending) pending") }
    if ($counts.Released -gt 0) { $parts.Add("$($counts.Released) released") }
    if ($counts.Denied -gt 0) { $parts.Add("$($counts.Denied) denied") }
    if ($counts.NotRequested -gt 0) { $parts.Add("$($counts.NotRequested) not requested") }
    if ($counts.Unknown) { $parts.Add('other copies unknown') }
    $parts -join (' {0} ' -f [char]0x00B7)
}

function Get-RrRecipientList($copies) {
    # The distinct, non-empty recipient addresses of a message with the kind of the copy each came from (Pending, Released, Denied, NotRequested).
    # Pending copies come first, then the rest in the order they were returned. Exchange may leave the address empty in list results.
    $out = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($pass in 'Pending', 'Other') {
        foreach ($cp in @($copies)) {
            if ($null -eq $cp) { continue }
            $kind = Get-RrCopyKind $cp
            if (($pass -eq 'Pending') -ne ($kind -eq 'Pending')) { continue }
            $prop = $cp.PSObject.Properties['Recipient']
            if (-not $prop -or $null -eq $prop.Value) { continue }
            foreach ($part in @(([string]$prop.Value) -split ';')) {
                $addr = $part.Trim()
                if (-not $addr) { continue }
                $lower = $addr.ToLowerInvariant()
                if ($seen.Contains($lower)) { continue }
                $seen[$lower] = $true
                $out.Add([pscustomobject]@{ Address = $addr; Kind = $kind })
            }
        }
    }
    $out.ToArray()   # callers wrap the call in @()
}

function Group-RrRowsByKey($Rows) {
    $map = [ordered]@{}
    foreach ($r in @($Rows)) {
        if ($null -eq $r) { continue }
        $key = Get-RrMessageKey $r
        if (-not $map.Contains($key)) { $map[$key] = [System.Collections.Generic.List[object]]::new() }
        $map[$key].Add($r)
    }
    $map
}

function Group-RrMessages($Rows, $CopiesByKey = @{}) {
    # One object per message. CopiesByKey maps a message key to the rows of a MessageId lookup (every recipient copy).
    # A key that is present with a null value means the lookup failed: the copies stay as they are and are marked unknown.
    $byKey = Group-RrRowsByKey $Rows
    foreach ($key in @($byKey.Keys)) {
        $own = @($byKey[$key])
        $unknown = $false
        $found = @()
        if ($CopiesByKey -and $CopiesByKey.Contains($key)) {
            if ($null -eq $CopiesByKey[$key]) { $unknown = $true } else { $found = @($CopiesByKey[$key] | Where-Object { $_ }) }
        }
        # the queried rows first (the lookup version of a copy wins), then the copies only the lookup knew
        $byId = @{}
        foreach ($c in $found) { $byId[[string]$c.Identity] = $c }
        $all = [System.Collections.Generic.List[object]]::new()
        $used = @{}
        foreach ($c in $own) {
            $id = [string]$c.Identity
            if ($used.Contains($id)) { continue }
            $used[$id] = $true
            if ($byId.Contains($id)) { $all.Add($byId[$id]) } else { $all.Add($c) }
        }
        foreach ($c in $found) {
            $id = [string]$c.Identity
            if ($used.Contains($id)) { continue }
            $used[$id] = $true
            $all.Add($c)
        }
        $counts = Get-RrCopyCounts $all
        $counts.Unknown = $unknown
        $pendingCopy = $all | Where-Object { (Get-RrCopyKind $_) -eq 'Pending' } | Select-Object -First 1
        $exportCopy = $(if ($pendingCopy) { $pendingCopy } else { $all[0] })
        $received = @($all | Where-Object { $_.Received } | ForEach-Object { [datetime]$_.Received } | Sort-Object | Select-Object -First 1)
        $expires = @($all | Where-Object { $_.Expires } | ForEach-Object { [datetime]$_.Expires } | Sort-Object | Select-Object -First 1)
        $types = @($all | ForEach-Object { @([string]$_.QuarantineTypes -split ',\s*') } | Where-Object { $_ } | Select-Object -Unique) -join ', '
        $status = 'Released'
        if ($counts.Pending -gt 0) { $status = 'Pending' }
        elseif ($counts.Denied -gt $counts.Released) { $status = 'Denied' }
        [pscustomobject]@{
            Key             = $key
            ExportIdentity  = [string]$exportCopy.Identity
            Received        = $(if ($received.Count) { $received[0] } else { $null })
            Sender          = [string]$own[0].Sender
            Recipients      = @(Get-RrRecipientList $all)
            Subject         = [string]$own[0].Subject
            QuarantineTypes = $types
            Expires         = $(if ($expires.Count) { $expires[0] } else { $null })
            Counts          = $counts
            CopiesText      = (Format-RrCopies $counts)
            Status          = $status
            HasReleasedCopy = ($counts.Released -gt 0)
            RecipientCount  = $counts.Total
        }
    }
}

function Get-RrCopiesCell($message) {
    $mark = $(if ($message.HasReleasedCopy) { '! ' } else { '' })
    $mark + [string]$message.CopiesText
}

function Get-RrRecipientsCell($message, [int]$MaxChars = 40) {
    # The first one or two known addresses that fit in MaxChars, then ' (+N)' for the rest of the recipients (N from Counts.Total).
    # With no known address: '<Total> recipients' (or '1 recipient').
    $known = @()
    $prop = $message.PSObject.Properties['Recipients']
    if ($prop -and $null -ne $prop.Value) { $known = @($prop.Value | Where-Object { $_ }) }
    $total = 0
    if ($message.PSObject.Properties['Counts'] -and $message.Counts) { $total = [int]$message.Counts.Total }
    $total = [Math]::Max($total, $known.Count)
    if ($known.Count -eq 0) {
        if ($total -le 1) { return '1 recipient' }
        return "$total recipients"
    }
    $shown = 1
    $text = [string]$known[0].Address
    if ($known.Count -ge 2) {
        $two = '{0}, {1}' -f $known[0].Address, $known[1].Address
        $suffixTwo = $(if (($total - 2) -gt 0) { " (+$($total - 2))" } else { '' })
        if (($two + $suffixTwo).Length -le $MaxChars) { $shown = 2; $text = $two }
    }
    $left = $total - $shown
    if ($left -gt 0) { $text += " (+$left)" }
    $text
}

function Get-RrRecipientsTip($message) {
    # One line per known recipient with the status of its copy, plus a note when Exchange named only some of them.
    $known = @()
    $prop = $message.PSObject.Properties['Recipients']
    if ($prop -and $null -ne $prop.Value) { $known = @($prop.Value | Where-Object { $_ }) }
    if ($known.Count -eq 0) { return '' }
    $words = @{ Pending = 'pending'; Released = 'released'; Denied = 'denied'; NotRequested = 'not requested' }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('Recipients:')
    foreach ($r in $known) { $lines.Add(('{0} ({1})' -f $r.Address, $words[[string]$r.Kind])) }
    $total = 0
    if ($message.PSObject.Properties['Counts'] -and $message.Counts) { $total = [int]$message.Counts.Total }
    if ($total -gt $known.Count) { $lines.Add("+ $($total - $known.Count) more not listed by Exchange") }
    $lines -join "`r`n"
}

function Sort-RrMessages($Messages, [string]$Column, [bool]$Descending = $false) {
    # Sorts the message objects (never the list control). Received and Expires by date, Copies by pending count then total, the rest as
    # case-insensitive text. Ties keep their original order. Callers wrap the call in @().
    $list = @($Messages | Where-Object { $_ })
    if ($list.Count -eq 0) { return }
    $min = [datetime]::MinValue
    $rows = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $list.Count; $i++) {
        $m = $list[$i]
        $k1 = ''; $k2 = 0
        switch ($Column) {
            'Received' { $k1 = $(if ($m.Received) { [datetime]$m.Received } else { $min }) }
            'Expires' { $k1 = $(if ($m.Expires) { [datetime]$m.Expires } else { $min }) }
            'Copies' { $k1 = [int]$m.Counts.Pending; $k2 = [int]$m.Counts.Total }
            'Sender' { $k1 = ([string]$m.Sender).ToLowerInvariant() }
            'Subject' { $k1 = ([string]$m.Subject).ToLowerInvariant() }
            { $_ -eq 'Quarantine type' -or $_ -eq 'QuarantineTypes' } { $k1 = ([string]$m.QuarantineTypes).ToLowerInvariant() }
            'Recipients' {
                $first = @($m.Recipients | Where-Object { $_ }) | Select-Object -First 1
                $k1 = $(if ($first) { ([string]$first.Address).ToLowerInvariant() } else { '' })
                $k2 = [int]$m.Counts.Total
            }
            default { $k1 = ([string]$m.Subject).ToLowerInvariant() }
        }
        $rows.Add([pscustomobject]@{ Msg = $m; K1 = $k1; K2 = $k2; Idx = $i })
    }
    $sorted = $rows | Sort-Object -Property @{ Expression = 'K1'; Descending = $Descending }, @{ Expression = 'K2'; Descending = $Descending }, @{ Expression = 'Idx'; Descending = $false }
    foreach ($row in @($sorted)) { $row.Msg }
}

function Get-RrRowTip($message) {
    if (-not $message.HasReleasedCopy) { return '' }
    "Released to $($message.Counts.Released) recipient(s) already. Decide for all copies in Defender."
}

function Set-RrProgress([string]$Text) {
    # Progress text for the dialog: the session variable State is shared with the window (it is absent outside the dialog session).
    $shared = Get-Variable -Name State -ValueOnly -ErrorAction SilentlyContinue
    if ($shared -is [hashtable]) { $shared['Progress'] = $Text }
}

function Get-RrMessages {
    # The listing step (runs in the session, never on the UI thread): pending copies, optionally released and denied ones, then one
    # read-only lookup per message to count every recipient copy. Returns Messages (one per message) and the raw pending row count.
    param([int]$Days = 0, [string]$Recipient = '', [switch]$IncludeHandled, [datetime]$Now = (Get-Date))
    $raw = @(Get-RrRequests -Days $Days -Recipient $Recipient -Now $Now -Status 'Requested')
    $rows = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    foreach ($r in $raw) {
        if ((Get-RrCopyKind $r) -ne 'Pending') { continue }
        if ($seen.Contains([string]$r.Identity)) { continue }
        $seen[[string]$r.Identity] = $true
        $rows.Add($r)
    }
    if ($IncludeHandled) {
        Set-RrProgress 'Loading released and denied messages...'
        foreach ($status in 'Released', 'Denied') {
            foreach ($r in @(Get-RrRequests -Days $Days -Recipient $Recipient -Now $Now -Status $status)) {
                if ($seen.Contains([string]$r.Identity)) { continue }
                $seen[[string]$r.Identity] = $true
                $rows.Add($r)
            }
        }
    }
    $byKey = Group-RrRowsByKey $rows
    $copiesByKey = @{}
    $total = $byKey.Count
    $at = 0
    foreach ($key in @($byKey.Keys)) {
        $at++
        Set-RrProgress ('Checking other copies ({0} of {1})...' -f $at, $total)
        $mid = ''
        foreach ($r in $byKey[$key]) { if (-not $mid -and $r.MessageId) { $mid = [string]$r.MessageId } }
        if (-not $mid) { continue }
        try {
            $copiesByKey[$key] = @(Get-QuarantineMessage -MessageId $mid -ErrorAction Stop | ForEach-Object { ConvertTo-RrRow $_ })
        } catch {
            $copiesByKey[$key] = $null
        }
    }
    [pscustomobject]@{ Messages = @(Group-RrMessages $rows $copiesByKey); RawPending = $raw.Count; Handled = [bool]$IncludeHandled }
}

function Get-RrFileName([datetime]$Received, [string]$Identity) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Identity)) } finally { $sha.Dispose() }
    $hex = (@($hash | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 10)
    '{0}-{1}.zip' -f $Received.ToString('yyyyMMdd-HHmm', [System.Globalization.CultureInfo]::InvariantCulture), $hex
}

function Get-RrZipSummary([byte[]]$Bytes) {
    # Structure only: signature, size, central directory fields. Never entry names, comments or content.
    $len = 0
    if ($Bytes) { $len = $Bytes.Length }
    $sig = ''
    for ($i = 0; $i -lt [Math]::Min(4, $len); $i++) { $sig += $Bytes[$i].ToString('x2') }
    $isZip = ($len -ge 4 -and $Bytes[0] -eq 0x50 -and $Bytes[1] -eq 0x4B -and $Bytes[2] -eq 3 -and $Bytes[3] -eq 4)
    if (-not $isZip) { return [pscustomobject]@{ Signature = $sig; Length = $len; IsZip = $false; Note = 'not a ZIP' } }
    $entries = New-Object System.Collections.Generic.List[object]
    $found = $false
    try {
        $pos = -1
        $min = [Math]::Max(0, $len - 22 - 65535)
        $i = $len - 22
        while ($i -ge $min) {
            $i = [Array]::LastIndexOf($Bytes, [byte]0x50, $i, ($i - $min + 1))
            if ($i -lt 0) { break }
            if ($Bytes[$i + 1] -eq 0x4B -and $Bytes[$i + 2] -eq 5 -and $Bytes[$i + 3] -eq 6) { $pos = $i; break }
            $i--
        }
        if ($pos -ge 0) {
            $total = [int][BitConverter]::ToUInt16($Bytes, $pos + 10)
            $cdSize = [long][BitConverter]::ToUInt32($Bytes, $pos + 12)
            $cdOff = [long][BitConverter]::ToUInt32($Bytes, $pos + 16)
            $good = (($cdOff + $cdSize) -le $pos)
            $at = $cdOff
            for ($n = 0; $good -and $n -lt $total; $n++) {
                if (($at + 46) -gt $len -or $Bytes[$at] -ne 0x50 -or $Bytes[$at + 1] -ne 0x4B -or $Bytes[$at + 2] -ne 1 -or $Bytes[$at + 3] -ne 2) { $good = $false; break }
                $flag = [BitConverter]::ToUInt16($Bytes, [int]$at + 8)
                $method = [BitConverter]::ToUInt16($Bytes, [int]$at + 10)
                $csize = [BitConverter]::ToUInt32($Bytes, [int]$at + 20)
                $usize = [BitConverter]::ToUInt32($Bytes, [int]$at + 24)
                $nameLen = [int][BitConverter]::ToUInt16($Bytes, [int]$at + 28)
                $extraLen = [int][BitConverter]::ToUInt16($Bytes, [int]$at + 30)
                $commentLen = [int][BitConverter]::ToUInt16($Bytes, [int]$at + 32)
                $next = $at + 46 + $nameLen + $extraLen + $commentLen
                if ($next -gt $len) { $good = $false; break }
                $aes = $false
                $ex = $at + 46 + $nameLen
                $exEnd = $ex + $extraLen
                while (($ex + 4) -le $exEnd) {
                    if ([BitConverter]::ToUInt16($Bytes, [int]$ex) -eq 0x9901) { $aes = $true }
                    $ex += 4 + [BitConverter]::ToUInt16($Bytes, [int]$ex + 2)
                }
                $entries.Add([pscustomobject]@{
                        Flag             = ('0x{0:x4}' -f $flag)
                        Method           = [int]$method
                        CompressedSize   = [long]$csize
                        UncompressedSize = [long]$usize
                        AesExtra         = $aes
                    })
                $at = $next
            }
            $found = $good
        }
    } catch { $found = $false }
    if (-not $found) { $entries.Clear() }
    [pscustomobject]@{ Signature = $sig; Length = $len; IsZip = $true; EocdFound = $found; EntryCount = $entries.Count; Entries = $entries.ToArray() }
}

function Test-RrZipBytes([byte[]]$Bytes) {
    if (-not $Bytes -or $Bytes.Length -eq 0) { return [pscustomobject]@{ Ok = $false; Reason = 'the export is empty' } }
    $s = Get-RrZipSummary $Bytes
    if (-not $s.IsZip) { return [pscustomobject]@{ Ok = $false; Reason = 'it is not a ZIP file' } }
    if (-not $s.EocdFound) { return [pscustomobject]@{ Ok = $false; Reason = 'the ZIP structure is incomplete' } }
    if ($s.EntryCount -lt 1) { return [pscustomobject]@{ Ok = $false; Reason = 'the ZIP has no entries' } }
    foreach ($entry in $s.Entries) {
        $flag = [Convert]::ToInt32($entry.Flag.Substring(2), 16)
        if (($flag -band 1) -eq 0) { return [pscustomobject]@{ Ok = $false; Reason = 'an entry is not password-protected' } }
    }
    [pscustomobject]@{ Ok = $true; Reason = '' }
}

function Format-RrZipSummary($summary) {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Signature (first 4 bytes): $($summary.Signature)")
    $lines.Add("Length: $($summary.Length) bytes")
    $lines.Add("Is ZIP: $($summary.IsZip)")
    if ($summary.PSObject.Properties['Note']) { $lines.Add("Note: $($summary.Note)") }
    if ($summary.PSObject.Properties['EocdFound']) {
        $lines.Add("End of central directory found: $($summary.EocdFound)")
        $lines.Add("Entries: $($summary.EntryCount)")
        $k = 0
        foreach ($entry in @($summary.Entries)) {
            $k++
            $lines.Add(('Entry {0}: flag {1}, method {2}, compressed {3}, uncompressed {4}, AES extra field {5}' -f $k, $entry.Flag, $entry.Method, $entry.CompressedSize, $entry.UncompressedSize, $(if ($entry.AesExtra) { 'yes' } else { 'no' })))
        }
    }
    $lines -join "`r`n"
}

function Get-RrErrorText($err) {
    $e = $null
    if ($err -is [System.Management.Automation.ErrorRecord]) { $e = $err.Exception } elseif ($err -is [System.Exception]) { $e = $err }
    $text = ''
    if ($e) {
        while ($e.InnerException) { $e = $e.InnerException }
        $text = $e.Message
    } else { $text = [string]$err }
    $text = (($text -split '\r?\n')[0]).Trim()
    if ($text.Length -gt 300) { $text = $text.Substring(0, 300) + '...' }
    $text
}

function New-RrResult([string]$Status, [string]$FileName, [string]$Message, $Summary) {
    [pscustomobject]@{ Status = $Status; FileName = $FileName; Message = $Message; Summary = $Summary }
}

function Save-RrExport {
    param(
        [Parameter(Mandatory)][string]$Identity,
        [Parameter(Mandatory)][datetime]$Received,
        [Parameter(Mandatory)][securestring]$Password,
        [Parameter(Mandatory)][string]$Incoming
    )
    # Exports one message, checks the bytes in memory and writes them only when they are a password-protected ZIP.
    $bytes = $null
    $disk = $null
    try {
        try {
            $export = Export-QuarantineMessage -Identity $Identity -CompressOutput -Password $Password -ReasonForExport 'Offline review with Quarantine Review Assistant' -ErrorAction Stop
        } catch {
            return (New-RrResult 'Failed' '' ('The export failed: ' + (Get-RrErrorText $_)) $null)
        }
        $b64 = ''
        if ($export) { $b64 = [string]@($export)[0].Eml }
        if ([string]::IsNullOrWhiteSpace($b64)) { return (New-RrResult 'Failed' '' 'The export returned no data.' $null) }
        try { $bytes = [Convert]::FromBase64String($b64) } catch { $bytes = New-Object byte[] 0 }
        $check = Test-RrZipBytes $bytes
        if (-not $check.Ok) {
            return (New-RrResult 'Rejected' '' ("Not saved: $($check.Reason). The export is not a password-protected ZIP.") (Get-RrZipSummary $bytes))
        }
        $name = Get-RrFileName $Received $Identity
        $target = Join-Path $Incoming $name
        if (Test-Path -LiteralPath $target) { return (New-RrResult 'Exists' $name 'Already in Incoming.' $null) }
        [void][System.IO.Directory]::CreateDirectory($Incoming)
        $fs = $null
        try {
            $fs = [System.IO.File]::Open($target, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        } catch [System.IO.IOException] {
            if (Test-Path -LiteralPath $target) { return (New-RrResult 'Exists' $name 'Already in Incoming.' $null) }
            return (New-RrResult 'Failed' '' ('The file could not be created: ' + (Get-RrErrorText $_)) $null)
        } catch {
            return (New-RrResult 'Failed' '' ('The file could not be created: ' + (Get-RrErrorText $_)) $null)
        }
        try {
            try { $fs.Write($bytes, 0, $bytes.Length); $fs.Flush() } finally { $fs.Dispose() }
        } catch {
            Remove-Item -LiteralPath $target -ErrorAction SilentlyContinue
            return (New-RrResult 'Failed' '' ('The file could not be written: ' + (Get-RrErrorText $_)) $null)
        }
        $disk = [System.IO.File]::ReadAllBytes($target)
        $again = Test-RrZipBytes $disk
        if (-not $again.Ok) {
            $sum = Get-RrZipSummary $disk
            Remove-Item -LiteralPath $target -ErrorAction SilentlyContinue
            return (New-RrResult 'Rejected' '' ("The saved file failed the check ($($again.Reason)) and was deleted.") $sum)
        }
        New-RrResult 'Saved' $name "Saved $name." $null
    } finally {
        if ($bytes) { [Array]::Clear($bytes, 0, $bytes.Length) }
        if ($disk) { [Array]::Clear($disk, 0, $disk.Length) }
    }
}

# ================================================================= session: one STA runspace per dialog (the Exchange connection lives in it)

function New-RrSession([string[]]$Functions = @()) {
    $state = [hashtable]::Synchronized(@{})
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $iss.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry('State', $state, 'Shared state')))
    foreach ($fn in $Functions) {
        $body = (Get-Item -LiteralPath "function:$fn").ScriptBlock.ToString()
        $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry($fn, $body)))
    }
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($iss)
    $rs.ApartmentState = [System.Threading.ApartmentState]::STA
    $rs.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $rs.Open()
    [pscustomobject]@{ Runspace = $rs; State = $state; Closed = $false; Current = $null }
}

function Invoke-RrStep($Session, [scriptblock]$Script, [hashtable]$Variables = @{}) {
    # Variables (such as the password SecureString) enter the runspace as variables, never as script text.
    foreach ($key in $Variables.Keys) { $Session.Runspace.SessionStateProxy.SetVariable([string]$key, $Variables[$key]) }
    $ps = [powershell]::Create()
    $ps.Runspace = $Session.Runspace
    [void]$ps.AddScript($Script.ToString(), $true)
    $handle = $ps.BeginInvoke()
    $work = [pscustomobject]@{ PowerShell = $ps; Handle = $handle; Session = $Session; Started = [DateTime]::UtcNow; Disposed = $false; Result = $null; Cancelled = $false }
    $Session.Current = $work
    $work
}

function Complete-RrStep($Work) {
    if ($Work.Result) { return $Work.Result }
    $out = @()
    $err = $null
    try {
        $out = @($Work.PowerShell.EndInvoke($Work.Handle))
    } catch {
        $err = Get-RrErrorText $_
    }
    if (-not $err -and $Work.PowerShell.Streams.Error.Count -gt 0) { $err = Get-RrErrorText $Work.PowerShell.Streams.Error[0] }
    try { $Work.PowerShell.Dispose() } catch { $null = $_ } # best-effort cleanup
    $Work.Disposed = $true
    if ($Work.Session -and $Work.Session.Current -eq $Work) { $Work.Session.Current = $null }
    $Work.Result = [pscustomobject]@{ Output = $out; Error = $err }
    $Work.Result
}

function Close-RrSession($Session, [int]$TimeoutMs = 5000) {
    # Signs out of Exchange Online (with a timeout) and always ends with the runspace stopped or abandoned. Safe to call twice.
    if (-not $Session -or $Session.Closed) { return }
    $Session.Closed = $true
    $rs = $Session.Runspace
    $clean = $true
    try {
        $cur = $Session.Current
        if ($cur -and -not $cur.Disposed -and -not $cur.Handle.IsCompleted) {
            $stop = $cur.PowerShell.BeginStop($null, $null)
            if (-not $stop.AsyncWaitHandle.WaitOne(1500)) { $clean = $false }
        }
    } catch { $clean = $false }
    $ps = $null
    try {
        if ($clean -and $rs.RunspaceStateInfo.State -eq [System.Management.Automation.Runspaces.RunspaceState]::Opened) {
            $ps = [powershell]::Create()
            $ps.Runspace = $rs
            [void]$ps.AddScript('Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue')
            $done = $ps.BeginInvoke()
            if (-not $done.AsyncWaitHandle.WaitOne($TimeoutMs)) {
                $stop = $ps.BeginStop($null, $null)
                if (-not $stop.AsyncWaitHandle.WaitOne(1000)) { $clean = $false }
            }
        }
    } catch { $clean = $false }
    try {
        if ($clean) {
            if ($ps) { $ps.Dispose() }
            $rs.Dispose()
        } else {
            $rs.CloseAsync()   # a pipeline that will not stop: abandon the runspace without blocking the window
        }
    } catch { $null = $_ } # nothing more to do for a runspace that cannot close
}

function Enable-RrForeground {
    # Lets the sign-in window of the module come to the front (with the console hidden this is what makes it open in front).
    if (-not (Get-Command Get-QraCompileDecision -ErrorAction SilentlyContinue)) { return }
    if ((Get-QraCompileDecision) -ne 'compile') { return }
    try {
        if (-not ('QRA.Fg' -as [type])) {
            Add-Type -Namespace QRA -Name Fg -MemberDefinition '[DllImport("user32.dll")] public static extern bool AllowSetForegroundWindow(int pid);' -ErrorAction Stop
        }
        [void][QRA.Fg]::AllowSetForegroundWindow(-1)
    } catch { $null = $_ } # compiling is not allowed here: sign-in may open behind the window
}

# ---- Bringing the Microsoft sign-in window forward. The sign-in is a window of another process (Microsoft.AAD.BrokerPlugin) that can open
# behind this dialog. The dialog finds it and brings it forward itself, right after the click (while this process still has the right to), and
# on a click of the "Show sign-in window" link. $script:RrFrameFinder / $script:RrFrameBringer let a test replace the two native calls.
$script:RrSignInSeconds = 30

function Test-RrSignInHelper {
    [bool]($script:RrFrameFinder -or $script:UiNative)
}

function Get-RrSignInFrames {
    # Window handles (int64) of the sign-in windows that exist now. Never throws; empty when none or when the native helpers are missing.
    try {
        if ($script:RrFrameFinder) { return @(@(& $script:RrFrameFinder) | ForEach-Object { [int64]$_ }) }
        if (-not $script:UiNative) { return @() }
        $pids = @(Get-Process -Name 'Microsoft.AAD.BrokerPlugin' -ErrorAction SilentlyContinue | ForEach-Object { [int]$_.Id })
        if ($pids.Count -eq 0) { return @() }
        return @(@([QraUi.Native]::FindSignInFrames([int[]]$pids)) | ForEach-Object { [int64]$_ })
    } catch { return @() }
}

function Invoke-RrBringToFront([int64]$handle) {
    try {
        if ($script:RrFrameBringer) { return [bool](& $script:RrFrameBringer $handle) }
        if (-not $script:UiNative) { return $false }
        return [bool][QraUi.Native]::BringToFront([IntPtr]$handle)
    } catch { return $false }
}

function Start-RrSignInWatch($d) {
    # Remembers the sign-in windows that exist already (leftovers of earlier attempts are ignored).
    $d.SignInOld = @{}
    foreach ($h in @(Get-RrSignInFrames)) { $d.SignInOld[[string]$h] = $true }
    $d.SignInSeen = @{}
    $d.SignInLatest = [int64]0
    $d.SignInUntil = [DateTime]::UtcNow.AddSeconds($script:RrSignInSeconds)
}

function Step-RrSignInWatch($d) {
    # One poll tick while connecting: a NEW sign-in window is brought forward once, at once. Stops after 30 seconds.
    if ($d.ConnectState -ne 'working' -or -not $d.SignInUntil -or [DateTime]::UtcNow -gt $d.SignInUntil) { return }
    foreach ($h in @(Get-RrSignInFrames)) {
        $key = [string]$h
        if ($d.SignInOld.ContainsKey($key) -or $d.SignInSeen.ContainsKey($key)) { continue }
        $d.SignInSeen[$key] = $true
        $d.SignInLatest = $h
        [void](Invoke-RrBringToFront $h)
    }
}

function Show-RrSignIn($d) {
    # The "Show sign-in window" link: a user click always lets this process bring a window forward.
    $frames = @(Get-RrSignInFrames)
    if ($frames.Count -eq 0) { return $false }
    $fresh = @($frames | Where-Object { -not $d.SignInOld.ContainsKey([string]$_) })
    $target = [int64]0
    if ($d.SignInLatest -and ($frames -contains $d.SignInLatest)) { $target = $d.SignInLatest }
    elseif ($fresh.Count -gt 0) { $target = $fresh[$fresh.Count - 1] }
    else { $target = $frames[$frames.Count - 1] }
    $d.SignInLatest = $target
    Invoke-RrBringToFront $target
}

function Get-RrConnectScript {
    {
        if (-not (Get-Command Connect-ExchangeOnline -ErrorAction SilentlyContinue)) { Import-Module ExchangeOnlineManagement -ErrorAction Stop }
        Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop
    }
}

function Get-RrSessionFunctionNames {
    @('Get-RrWindowDays', 'Get-RrQuarantineParams', 'ConvertTo-RrRow', 'Get-RrRequests', 'Get-RrCapMessage', 'Get-RrMessageKey', 'Get-RrCopyKind',
        'Get-RrCopyWeight', 'Get-RrCopyCounts', 'Format-RrCopies', 'Get-RrRecipientList', 'Group-RrRowsByKey', 'Group-RrMessages', 'Set-RrProgress', 'Get-RrMessages', 'Get-RrFileName',
        'Get-RrZipSummary', 'Test-RrZipBytes', 'Get-RrErrorText', 'New-RrResult', 'Save-RrExport')
}

# ================================================================= dialog

function Format-RrDate($value, [string]$format) {
    if ($null -eq $value -or "$value" -eq '') { return '' }
    try {
        $dt = [datetime]$value
        if ($dt.Kind -eq [System.DateTimeKind]::Utc) { $dt = $dt.ToLocalTime() }
        $dt.ToString($format, [System.Globalization.CultureInfo]::InvariantCulture)
    } catch { [string]$value }
}

function New-RrLabel([string]$text, $font, $color) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Font = $font; $l.ForeColor = $color; $l.BackColor = $C.Card
    $l.AutoSize = $false; $l.UseMnemonic = $false
    $l.Visible = $false
    $l
}

function New-RrButton([string]$text, [string]$variant, [string]$glyph, $font) {
    $b = New-QraButton $text $variant $glyph
    $b.Font = $font   # buttons otherwise fall back to a tiny default font
    $b.Visible = $false
    $b
}

function Get-RrButtonWidth($btn, [int]$min = 0) {
    $flags = [System.Windows.Forms.TextFormatFlags]::NoPadding -bor [System.Windows.Forms.TextFormatFlags]::SingleLine -bor [System.Windows.Forms.TextFormatFlags]::NoPrefix
    $tw = [System.Windows.Forms.TextRenderer]::MeasureText([string]$btn.Text, $btn.Font, (New-Object System.Drawing.Size([int]::MaxValue, 0)), $flags).Width
    $gw = 0
    if ($btn.GetType().FullName -eq 'QraUi.ModernButton' -and $btn.Glyph) { $gw = [int]($btn.Font.Height * 1.4) }
    [Math]::Max($min, $tw + $gw + (S 40))
}

function Set-RrBounds($ctl, [int]$x, [int]$y, [int]$w, [int]$h) {
    $ctl.SetBounds($x, $y, $w, $h)
    $ctl.Visible = $true
}

function Set-RrWrapped($lbl, [int]$x, [int]$y, [int]$w) {
    if (-not $lbl.Text) { $lbl.Visible = $false; return $y }
    $lbl.SetBounds($x, $y, $w, ((Measure-Wrapped $lbl.Text $lbl.Font $w) + (S 4)))
    $lbl.Visible = $true
    $lbl.Bottom
}

function Hide-RrControls($list) {
    foreach ($ctl in $list) { $ctl.Visible = $false }
}

function Get-RrStepStates($d) {
    $k = $d.Ctl
    $s = @('Pending', 'Pending', 'Pending', 'Pending')
    if ($null -eq $d.Module) { $s[0] = 'Working'; return $s }
    if (-not $d.Module.Installed) {
        $s[0] = 'Current'
        if ($d.InstallState -eq 'waiting') { $s[0] = 'Working' } elseif ($d.InstallState -eq 'failed') { $s[0] = 'Warning' }
        return $s
    }
    $s[0] = 'Done'
    if ($d.ConnectState -eq 'working') { $s[1] = 'Working' } elseif ($d.ConnectState -eq 'failed') { $s[1] = 'Warning' } elseif ($d.ConnectState -eq 'done') { $s[1] = 'Done' } else { $s[1] = 'Current' }
    if ($d.ConnectState -ne 'done') { return $s }
    $n = $k.List.CheckedItems.Count
    if ($d.ListState -eq 'loading') { $s[2] = 'Working' } elseif ($n -ge 1) { $s[2] = 'Done' } else { $s[2] = 'Current' }
    if ($d.SaveState -eq 'saving') { $s[3] = 'Working' } elseif ($n -ge 1 -or $d.SaveState -eq 'done') { $s[3] = 'Current' }
    $s
}

function Update-RrSaveButton($d) {
    if (-not $d -or -not $d.Ready) { return }
    $k = $d.Ctl
    $k.BSave.Enabled = ($d.ConnectState -eq 'done') -and (-not $d.Work) -and ($d.ListState -ne 'loading') -and ($k.List.CheckedItems.Count -ge 1) -and ($k.Pw.Text.Length -ge 1)
    if ($d.ListState -eq 'loaded') {   # keep the selected count under the list current
        $d.ListMsg = Get-RrListNote $d.Rows $k.List.CheckedItems.Count $d.IncludeHandled $d.RawPending
        $k.LblList.Text = $d.ListMsg
    }
    $st = Get-RrStepStates $d
    for ($i = 0; $i -lt 4; $i++) { Set-QraBadgeState $d.Steps[$i].Badge $st[$i] }
}

function Update-RrView($d) {
    if (-not $d -or -not $d.Ready -or $d.InLayout -or $script:QraDpiBusy) { return }
    Use-QraFormDpi $d.Form
    $d.InLayout = $true
    $k = $d.Ctl
    $scroll = $k.Scroll
    try {
        $scroll.SuspendLayout()
        $st = Get-RrStepStates $d
        $installed = ($null -ne $d.Module -and $d.Module.Installed)
        $connected = ($d.ConnectState -eq 'done')
        $pad = S 24
        $textX = $pad + (S 44)
        $w = [Math]::Max((S 360), $scroll.ClientSize.Width - $textX - $pad)
        $y = S 14

        # ---- step summaries
        if ($null -eq $d.Module) { $d.Steps[0].Sum.Text = 'Checking whether the module is installed...' }
        elseif ($installed) { $d.Steps[0].Sum.Text = "ExchangeOnlineManagement $($d.Module.Version) is installed." }
        else { $d.Steps[0].Sum.Text = 'Not installed yet. It installs for your Windows account only, without administrator rights.' }
        if ($connected) { $d.Steps[1].Sum.Text = 'Signed in. This window signs out again when you close it.' }
        elseif ($installed) { $d.Steps[1].Sum.Text = 'Sign in with your work account. This tool only reads the release requests.' }
        else { $d.Steps[1].Sum.Text = 'Opens the Microsoft sign-in window.' }
        $d.Steps[2].Sum.Text = $(if ($connected) { 'Nothing is selected by default. Select the messages to save.' } else { 'Lists the messages that have a pending release request.' })
        $d.Steps[3].Sum.Text = 'Saves each selected message as a password-protected ZIP.'

        # ---- hide every optional control, then show what the state needs
        Hide-RrControls @($k.I0Num + $k.I0Txt + @($k.BInstall, $k.BCopyCmd, $k.SpInstall, $k.LblWait, $k.LblInstallMsg, $k.BSignIn, $k.SpConnect, $k.LblConnect, $k.BShowSignIn, $k.LblConnectErr,
                $k.LblDays, $k.Days, $k.LblRecip, $k.Recip, $k.BRefresh, $k.ChkHandled, $k.LblHandled, $k.List, $k.SpList, $k.LblList, $k.BCancel, $k.LblCancelNote, $k.LblListHint,
                $k.LblPw, $k.Pw, $k.LblPwNote, $k.BSave, $k.SpSave, $k.LblSave, $k.LblSaved, $k.LblProblems, $k.LblRejHead, $k.Rej, $k.BCopyDet))
        Set-QraSpinner $k.SpInstall ($d.InstallState -eq 'waiting') 'Waiting for the install window to close'
        Set-QraSpinner $k.SpConnect ($d.ConnectState -eq 'working') 'Waiting for you to sign in'
        Set-QraSpinner $k.SpList ($d.ListState -eq 'loading') 'Loading release requests'
        Set-QraSpinner $k.SpSave ($d.SaveState -eq 'saving') 'Saving to Incoming'

        for ($i = 0; $i -lt 4; $i++) {
            $step = $d.Steps[$i]
            Set-QraBadgeState $step.Badge $st[$i]
            Set-RrBounds $step.Badge $pad $y (S 30) (S 30)
            $step.Title.ForeColor = $(if ($st[$i] -eq 'Pending') { $C.TextMuted } else { $C.Text })
            $yy = Set-RrWrapped $step.Title $textX ($y + (S 3)) $w
            if ($i -lt 2 -and $st[$i] -eq 'Done') {
                # a finished step is one line: the title, then its summary beside it
                $tw = (Get-RrTextWidth $step.Title.Text $step.Title.Font) + (S 16)
                $step.Title.Width = $tw
                $yb = Set-RrWrapped $step.Sum ($textX + $tw) ($y + (S 5)) ($w - $tw)
                $yy = [Math]::Max($yy, $yb)
                $yy += S 4
            } else {
                $yy = Set-RrWrapped $step.Sum $textX ($yy + (S 2)) $w
                $yy += S 10
            }

            if ($i -eq 0 -and -not $installed -and $null -ne $d.Module) {
                for ($n = 0; $n -lt 3; $n++) {
                    Set-RrBounds $k.I0Num[$n] $textX $yy (S 22) (S 22)
                    $yy = (Set-RrWrapped $k.I0Txt[$n] ($textX + (S 24)) $yy ($w - (S 24))) + (S 4)
                }
                $yy += S 6
                if ($d.InstallState -eq 'waiting') {
                    Set-RrBounds $k.SpInstall $textX $yy (S 24) (S 24)
                    $yb = Set-RrWrapped $k.LblWait ($textX + (S 34)) $yy ($w - (S 34))
                    $k.SpInstall.Top = $k.LblWait.Top + [int](($k.LblWait.Height - $k.SpInstall.Height) / 2)
                    $yy = [Math]::Max($yb, $k.SpInstall.Bottom) + (S 6)
                } else {
                    if ($d.InstallMsg) { $k.LblInstallMsg.Text = $d.InstallMsg; $yy = (Set-RrWrapped $k.LblInstallMsg $textX $yy $w) + (S 8) }
                    $bw = Get-RrButtonWidth $k.BInstall (S 200)
                    Set-RrBounds $k.BInstall $textX $yy $bw (S 38)
                    $cw = Get-RrButtonWidth $k.BCopyCmd (S 150)
                    Set-RrBounds $k.BCopyCmd ($k.BInstall.Right + (S 10)) $yy $cw (S 38)
                    $yy = $k.BInstall.Bottom + (S 6)
                }
            }
            if ($i -eq 1 -and $installed -and -not $connected) {
                if ($d.ConnectState -eq 'working') {
                    Set-RrBounds $k.SpConnect $textX $yy (S 24) (S 24)
                    $yb = Set-RrWrapped $k.LblConnect ($textX + (S 34)) $yy ($w - (S 34))
                    $k.SpConnect.Top = $k.LblConnect.Top + [int](($k.LblConnect.Height - $k.SpConnect.Height) / 2)
                    $yy = [Math]::Max($yb, $k.SpConnect.Bottom) + (S 6)
                    if (Test-RrSignInHelper) {
                        # Link button under the waiting text; the text label has an opaque background, so the link goes above it in the z-order (as the Cancel link does)
                        Set-RrBounds $k.BShowSignIn ($textX + (S 34)) ($yb + (S 2)) ((Get-RrTextWidth $k.BShowSignIn.Text $k.BShowSignIn.Font) + (S 20)) (S 26)
                        $k.BShowSignIn.BringToFront()
                        $yy = [Math]::Max($yy, $k.BShowSignIn.Bottom + (S 6))
                    }
                } else {
                    if ($d.ConnectState -eq 'failed') { $k.LblConnectErr.Text = $d.ConnectMsg; $yy = (Set-RrWrapped $k.LblConnectErr $textX $yy $w) + (S 8) }
                    $k.BSignIn.Text = $(if ($d.ConnectState -eq 'failed') { 'Retry' } else { 'Sign in' })
                    Set-RrBounds $k.BSignIn $textX $yy (Get-RrButtonWidth $k.BSignIn (S 140)) (S 38)
                    $yy = $k.BSignIn.Bottom + (S 6)
                }
            }
            if ($i -eq 2 -and $connected) {
                $rowH = S 30
                $x = $textX
                $k.LblDays.Text = 'Days to look back'
                $lw = (Get-RrTextWidth $k.LblDays.Text $k.LblDays.Font) + (S 8)
                Set-RrBounds $k.LblDays $x $yy $lw $rowH
                $k.LblDays.TextAlign = 'MiddleLeft'
                $k.Days.SetBounds(($x + $lw), ($yy + [int](($rowH - $k.Days.Height) / 2)), (S 64), $k.Days.Height); $k.Days.Visible = $true
                $x = $k.Days.Right + (S 24)
                $rw = (Get-RrTextWidth $k.LblRecip.Text $k.LblRecip.Font) + (S 8)
                Set-RrBounds $k.LblRecip $x $yy $rw $rowH
                $k.LblRecip.TextAlign = 'MiddleLeft'
                $k.Recip.SetBounds(($x + $rw), ($yy + [int](($rowH - $k.Recip.Height) / 2)), (S 230), $k.Recip.Height); $k.Recip.Visible = $true
                $bw = Get-RrButtonWidth $k.BRefresh (S 130)
                Set-RrBounds $k.BRefresh ($k.Recip.Right + (S 16)) ($yy - (S 2)) $bw (S 34)
                $k.BRefresh.Enabled = ($d.ListState -ne 'loading') -and (-not $d.Work)
                $yy += $rowH + (S 6)
                $k.ChkHandled.Text = 'Also show released and denied messages'
                $indent = Get-QraCheckBoxIndent $k.ChkHandled
                $cw = (Get-RrTextWidth $k.ChkHandled.Text $k.ChkHandled.Font) + $indent + (S 12)
                Set-RrBounds $k.ChkHandled $textX $yy $cw (S 24)
                $k.ChkHandled.Enabled = $true   # a change while a step runs is remembered and refreshed when that step ends
                $yy = $k.ChkHandled.Bottom + (S 1)
                $yy = (Set-RrWrapped $k.LblHandled ($textX + $indent) $yy ($w - $indent)) + (S 8)
                Set-RrBounds $k.List $textX $yy $w (S 160)
                Set-RrListColumns $k.List
                $yy = $k.List.Bottom + (S 6)
                $note = $d.ListMsg
                $lx = $textX
                if ($d.ListState -eq 'loading') { Set-RrBounds $k.SpList $textX $yy (S 24) (S 24); $lx = $textX + (S 34) }
                $k.LblList.Text = $note
                $k.LblList.ForeColor = $(if ($d.ListState -eq 'failed') { $C.Danger } else { $C.TextMuted })
                $yb = Set-RrWrapped $k.LblList $lx $yy ($w - ($lx - $textX))
                if ($d.ListState -eq 'loading') {
                    $k.SpList.Top = $k.LblList.Top + [int](($k.LblList.Height - $k.SpList.Height) / 2); $yb = [Math]::Max($yb, $k.SpList.Bottom)
                    Set-RrBounds $k.BCancel $lx $yy ((Get-RrTextWidth $k.BCancel.Text $k.BCancel.Font) + (S 20)) (S 26)   # Link button: it follows the note (Update-RrCancelLink)
                    Update-RrCancelLink $d
                    $yb = [Math]::Max($yb, $k.BCancel.Bottom)
                }
                $yy = [Math]::Max($yb, $yy + (S 20)) + (S 2)
                if ($d.CancelNote -and $d.ListState -ne 'loading') { $yy = (Set-RrWrapped $k.LblCancelNote $textX $yy $w) + (S 2) }
                $yy = (Set-RrWrapped $k.LblListHint $textX $yy $w) + (S 6)
            }
            if ($i -eq 3 -and $connected) {
                $rowH = S 30
                $pwText = 'Download password'
                $pw = (Get-RrTextWidth $pwText $k.LblPw.Font) + (S 10)
                $k.LblPw.Text = $pwText
                Set-RrBounds $k.LblPw $textX $yy $pw $rowH
                $k.LblPw.TextAlign = 'MiddleLeft'
                $k.Pw.SetBounds(($textX + $pw), ($yy + [int](($rowH - $k.Pw.Height) / 2)), (S 260), $k.Pw.Height); $k.Pw.Visible = $true
                $yy += $rowH + (S 2)
                $yy = (Set-RrWrapped $k.LblPwNote $textX $yy $w) + (S 6)
                $bw = Get-RrButtonWidth $k.BSave (S 170)
                Set-RrBounds $k.BSave $textX $yy $bw (S 38)
                if ($d.SaveState -eq 'saving') {
                    Set-RrBounds $k.SpSave ($k.BSave.Right + (S 14)) ($yy + (S 7)) (S 24) (S 24)
                    $k.LblSave.Text = $d.SaveProgress
                    $yb = Set-RrWrapped $k.LblSave ($k.SpSave.Right + (S 10)) ($yy + (S 8)) ($w - $bw - (S 48))
                    $k.SpSave.Top = $k.LblSave.Top + [int](($k.LblSave.Height - $k.SpSave.Height) / 2)
                }
                $yy = $k.BSave.Bottom + (S 8)
                if ($d.SaveState -eq 'done' -and $d.SaveSummary) {
                    $k.LblSaved.Text = $d.SaveSummary
                    $k.LblSaved.ForeColor = $(if ($d.SaveAllOk) { $C.Success } else { $C.Warning })
                    $yy = (Set-RrWrapped $k.LblSaved $textX $yy $w) + (S 4)
                    $k.LblProblems.Text = $d.SaveProblems
                    $yy = (Set-RrWrapped $k.LblProblems $textX $yy $w) + (S 4)
                    if ($d.RejectedText) {
                        $k.LblRejHead.Text = 'This export was not saved. These details contain no message names or content. Copy them if you need to report it.'
                        $yy = (Set-RrWrapped $k.LblRejHead $textX ($yy + (S 4)) $w) + (S 4)
                        $k.Rej.Text = $d.RejectedText
                        Set-RrBounds $k.Rej $textX $yy $w (S 120)
                        $yy = $k.Rej.Bottom + (S 6)
                        Set-RrBounds $k.BCopyDet $textX $yy (Get-RrButtonWidth $k.BCopyDet (S 140)) (S 34)
                        $yy = $k.BCopyDet.Bottom + (S 4)
                    }
                }
            }
            $y = [Math]::Max($yy, $step.Badge.Bottom) + (S 14)
        }
        $scroll.AutoScrollMinSize = New-Object System.Drawing.Size(0, $y)
        Update-RrSaveButton $d
    } finally {
        $scroll.ResumeLayout($true)
        $d.InLayout = $false
    }
}

function Get-RrTextWidth([string]$text, $font) {
    $fl = [System.Windows.Forms.TextFormatFlags]::NoPadding -bor [System.Windows.Forms.TextFormatFlags]::SingleLine -bor [System.Windows.Forms.TextFormatFlags]::NoPrefix
    [System.Windows.Forms.TextRenderer]::MeasureText($text, $font, (New-Object System.Drawing.Size([int]::MaxValue, 0)), $fl).Width
}

function Update-RrCancelLink($d) {
    # The Cancel link sits right after the loading note (the note changes with the progress), centred on the spinner; it never leaves the row.
    $k = $d.Ctl
    if (-not $k.BCancel.Visible) { return }
    $tw = Get-RrTextWidth $k.LblList.Text $k.LblList.Font
    $x = $k.LblList.Left + [Math]::Min($tw, $k.LblList.Width) + (S 4)
    $x = [Math]::Max($k.LblList.Left, [Math]::Min($x, $k.LblList.Left + $k.LblList.Width - $k.BCancel.Width))
    $k.BCancel.Left = $x
    $k.BCancel.Top = $k.SpList.Top + [int](($k.SpList.Height - $k.BCancel.Height) / 2)
    # The note label spans the whole row with an opaque background; on screen it would paint over the link if it were above it in the z-order.
    $k.BCancel.BringToFront()
}

function Set-RrListColumns($lv) {
    # Columns: Received, Sender, Recipients, Subject, Quarantine type, Copies, Expires. Sender and Subject share what the others leave, so no horizontal scrollbar.
    $avail = $lv.ClientSize.Width - (S 2)
    if ($avail -le 0 -or $lv.Columns.Count -ne 7) { return }
    $received = S 128; $recipients = S 185; $type = S 108; $copies = S 290; $expires = S 84
    $fixed = $received + $recipients + $type + $expires
    $rest = $avail - ($fixed + $copies)
    if ($rest -lt (S 380)) {
        $copies = [Math]::Max((S 170), $copies - ((S 380) - $rest))
        $rest = $avail - ($fixed + $copies)
    }
    $sender = [Math]::Max((S 80), [int]($rest * 0.5))
    $subject = [Math]::Max((S 80), $rest - $sender)
    $widths = @($received, $sender, $recipients, $subject, $type, $copies, $expires)
    for ($i = 0; $i -lt 7; $i++) { $lv.Columns[$i].Width = $widths[$i] }
}

function Update-RrSortHeaders($d) {
    # The sorted column carries a small arrow (up = ascending, down = descending); the others show their plain name.
    $lv = $d.Ctl.List
    $arrow = $(if ($d.SortDesc) { [char]0x25BC } else { [char]0x25B2 })
    for ($i = 0; $i -lt $lv.Columns.Count -and $i -lt $d.ColNames.Count; $i++) {
        $name = [string]$d.ColNames[$i]
        $lv.Columns[$i].Text = $(if ($name -eq $d.SortColumn) { "$name $arrow" } else { $name })
    }
}

function Set-RrRows($d, $rows, [switch]$KeepSelection) {
    # One list row per message, sorted by the dialog's current sort. KeepSelection keeps the checked messages (by Key) that are still listed.
    Use-QraFormDpi $d.Form
    $lv = $d.Ctl.List
    $keep = @{}
    if ($KeepSelection) {
        foreach ($old in $lv.CheckedItems) { if ($old.Tag) { $keep[[string]$old.Tag.Key] = $true } }
    }
    $col = $(if ($d.ContainsKey('SortColumn') -and $d.SortColumn) { [string]$d.SortColumn } else { 'Received' })
    $desc = $(if ($d.ContainsKey('SortDesc')) { [bool]$d.SortDesc } else { $true })
    $d.Rows = @(Sort-RrMessages $rows $col $desc)
    $maxChars = [Math]::Max(12, [int](((S 185) - (S 12)) / ((Get-RrTextWidth 'abcdefghijklmnopqrst' $lv.Font) / 20)))
    $d.Populating = $true
    $lv.BeginUpdate()
    try {
        $lv.Items.Clear()
        foreach ($r in $d.Rows) {
            $it = New-Object System.Windows.Forms.ListViewItem -ArgumentList ([string](Format-RrDate $r.Received 'yyyy-MM-dd HH:mm'))
            $cells = @($r.Sender, (Get-RrRecipientsCell $r $maxChars), $r.Subject, $r.QuarantineTypes, (Get-RrCopiesCell $r), (Format-RrDate $r.Expires 'yyyy-MM-dd'))
            foreach ($cell in $cells) { [void]$it.SubItems.Add([string]$cell) }
            $it.UseItemStyleForSubItems = $false
            $rowColor = $(if ($r.Status -ne 'Pending') { $C.TextMuted } else { $C.Text })
            foreach ($sub in $it.SubItems) { $sub.ForeColor = $rowColor }
            if ($r.HasReleasedCopy -and $r.Status -eq 'Pending') { $it.SubItems[5].ForeColor = $C.Warning }
            $it.ToolTipText = (@((Get-RrRowTip $r), (Get-RrRecipientsTip $r)) | Where-Object { $_ }) -join "`r`n`r`n"
            $it.Tag = $r
            if ($keep.ContainsKey([string]$r.Key)) { $it.Checked = $true }
            [void]$lv.Items.Add($it)
        }
    } finally {
        $lv.EndUpdate()
        $d.Populating = $false
    }
    Update-RrSortHeaders $d
    Update-RrSaveButton $d
}

function Invoke-RrSort($d, [int]$index) {
    # A header click: sort by that column, or reverse the order when it is already the sorted one.
    if ($index -lt 0 -or $index -ge $d.ColNames.Count) { return }
    $name = [string]$d.ColNames[$index]
    if ($d.SortColumn -eq $name) { $d.SortDesc = -not $d.SortDesc } else { $d.SortColumn = $name; $d.SortDesc = $false }
    Set-RrRows $d $d.Rows -KeepSelection
}

function Invoke-RrHandledChanged($d) {
    # The 'released and denied' checkbox refreshes the list at once. While a step runs the refresh is remembered and starts when it ends.
    # A change while the load that this checkbox started is still running is a cancel (and the checkbox goes back), never a second load.
    # NoReact: the dialog itself sets the checkbox (revert, screenshots) and no load may follow.
    if (-not $d -or -not $d.Ready -or $d.ConnectState -ne 'done' -or $d.NoReact) { return }
    if ($d.Work) {
        if ($d.WorkKind -eq 'list' -and $d.ListByCheckbox -and -not $d.Work.Cancelled) { [void](Stop-RrListLoad $d); return }
        $d.PendingRefresh = $true
        return
    }
    Start-RrList $d -FromCheckbox
}

function Invoke-RrPendingRefresh($d) {
    if ($d.PendingRefresh -and -not $d.Work -and $d.ConnectState -eq 'done') {
        $d.PendingRefresh = $false
        Start-RrList $d -FromCheckbox   # only the checkbox sets PendingRefresh
    }
}

function Stop-RrListLoad($d) {
    # Cancel for a running LIST step (exports are not cancellable). The window never waits: the pipeline gets BeginStop, and the step stays in $d.Work (so no
    # other step starts on the busy runspace) until it has ended; Invoke-RrPoll then throws its result away. The session and its Exchange connection stay usable.
    # The rows, the selection and the sort stay exactly as they were. A load that the checkbox started puts the checkbox back, without a new load.
    if (-not $d -or -not $d.Work -or $d.WorkKind -ne 'list' -or $d.Work.Cancelled) { return $false }
    $work = $d.Work
    $work.Cancelled = $true
    try { [void]$work.PowerShell.BeginStop($null, $null) } catch { $null = $_ } # a pipeline that ended on its own needs no stop
    $d.ListState = $d.ListPrevState
    $d.ListMsg = $d.ListPrevMsg
    $d.CancelNote = $true
    $k = $d.Ctl
    if ($d.ListByCheckbox) {
        $d.NoReact = $true
        try { $k.ChkHandled.Checked = [bool]$d.IncludeHandled } finally { $d.NoReact = $false }
    }
    $d.ListByCheckbox = $false
    Update-RrView $d
    try { if ($k.List.Visible) { [void]$k.List.Focus() } } catch { $null = $_ } # the Cancel link is gone: keep the keyboard focus in the dialog
    $true
}

function Get-RrListNote($Messages, [int]$Picked = 0, [bool]$Handled = $false, [int]$RawPending = 0) {
    $list = @($Messages | Where-Object { $_ })
    if ($list.Count -eq 0) {
        if ($Handled) { return 'No messages in this period.' }
        return 'No pending release requests in this period.'
    }
    $pendingMessages = @($list | Where-Object { $_.Status -eq 'Pending' }).Count
    $pendingCopies = 0
    foreach ($m in $list) { $pendingCopies += [int]$m.Counts.Pending }
    $head = ''
    if ($Handled) {
        $word = $(if ($list.Count -eq 1) { 'message' } else { 'messages' })
        $with = $(if ($pendingMessages -eq 1) { '1 with a pending request' } else { "$pendingMessages with pending requests" })
        $head = "$($list.Count) $word ($with)."
    } else {
        $word = $(if ($list.Count -eq 1) { '1 message with a pending request' } else { "$($list.Count) messages with pending requests" })
        $copyWord = $(if ($pendingCopies -eq 1) { '1 recipient copy' } else { "$pendingCopies recipient copies" })
        $head = "$word ($copyWord)."
    }
    $pickText = $(if ($Picked -eq 0) { 'Nothing is selected yet.' } else { "$Picked selected." })
    $cap = Get-RrCapMessage $RawPending
    if ($cap) { return "$cap $head $pickText" }
    "$head $pickText"
}

function Get-RrDialogSession($d) {
    if (-not $d.Session) { $d.Session = New-RrSession ((Get-RrSessionFunctionNames) + $d.SessionFunctions) }
    $d.Session
}

function Update-RrModuleStep($d) {
    $d.Module = Get-RrModuleState
    if ($d.Module.Installed) { $d.InstallState = 'idle'; $d.InstallMsg = '' }
    Update-RrView $d
}

function Start-RrInstall($d) {
    if ($d.InstallProc) { return }
    try {
        $proc = Start-RrModuleInstall
    } catch {
        $d.InstallState = 'failed'
        $d.InstallMsg = 'Could not open the PowerShell window: ' + (Get-RrErrorText $_)
        Update-RrView $d
        return
    }
    $d.InstallProc = $proc
    $d.InstallState = 'waiting'
    $d.InstallMsg = ''
    $d.InstallWatch.Start()
    Update-RrView $d
}

function Invoke-RrInstallWatch($d) {
    $proc = $d.InstallProc
    if (-not $proc) { $d.InstallWatch.Stop(); return }
    $exited = $true
    try { $exited = [bool]$proc.HasExited } catch { $exited = $true }
    if (-not $exited) { return }
    $d.InstallWatch.Stop()
    try { $proc.Dispose() } catch { $null = $_ } # the process is gone either way
    $d.InstallProc = $null
    $d.Module = Get-RrModuleState
    if ($d.Module.Installed) { $d.InstallState = 'idle'; $d.InstallMsg = '' }
    else { $d.InstallState = 'failed'; $d.InstallMsg = 'The install did not complete. Check the PowerShell window output.' }
    Update-RrView $d
    $d.Form.Activate()
}

function Start-RrConnect($d) {
    if ($d.Work -or $d.ConnectState -eq 'working') { return }
    $d.ConnectState = 'working'
    $d.ConnectMsg = ''
    $k = $d.Ctl
    $k.LblConnect.Text = $(if (Test-RrSignInHelper) { 'Waiting for you to sign in... If the sign-in window is not in front, click Show sign-in window.' } else { "Waiting for you to sign in... If you don't see the sign-in window, check the taskbar." })
    Start-RrSignInWatch $d
    $session = Get-RrDialogSession $d
    Enable-RrForeground
    $d.Work = Invoke-RrStep $session (Get-RrConnectScript) @{}
    $d.WorkKind = 'connect'
    $d.Poll.Start()
    Update-RrView $d
}

function Start-RrList($d, [switch]$FromCheckbox) {
    if ($d.Work -or $d.ConnectState -ne 'done') { return }
    $k = $d.Ctl
    $d.ListPrevState = $d.ListState; $d.ListPrevMsg = $d.ListMsg   # what Cancel goes back to
    $d.ListByCheckbox = [bool]$FromCheckbox
    $d.CancelNote = $false
    $d.ListState = 'loading'
    $d.ListMsg = 'Loading release requests...'
    $session = Get-RrDialogSession $d
    $session.State['Progress'] = ''
    $d.Work = Invoke-RrStep $session { Get-RrMessages -Days $RrDays -Recipient $RrRecipient -IncludeHandled:$RrHandled } @{ RrDays = [int]$k.Days.Value; RrRecipient = $k.Recip.Text.Trim(); RrHandled = [bool]$k.ChkHandled.Checked }
    $d.WorkKind = 'list'
    $d.Poll.Start()
    Update-RrView $d
}

function Start-RrSave($d) {
    $k = $d.Ctl
    if ($d.Work -or $k.List.CheckedItems.Count -lt 1 -or $k.Pw.Text.Length -lt 1) { return }
    $secret = New-Object System.Security.SecureString
    foreach ($ch in $k.Pw.Text.ToCharArray()) { $secret.AppendChar($ch) }
    $secret.MakeReadOnly()
    $k.Pw.Clear()
    $items = @()
    foreach ($it in $k.List.CheckedItems) { $items += $it }
    $d.Batch = @{ Items = $items; Index = 0; Results = @(); Password = $secret }
    $d.SaveState = 'saving'
    $d.SaveSummary = ''; $d.SaveProblems = ''; $d.RejectedText = ''
    Start-RrNextExport $d
}

function Start-RrNextExport($d) {
    $b = $d.Batch
    if ($b.Index -ge $b.Items.Count) { Complete-RrBatch $d; return }
    $row = $b.Items[$b.Index].Tag
    $d.SaveProgress = 'Saving {0} of {1}...' -f ($b.Index + 1), $b.Items.Count
    $vars = @{ RrIdentity = [string]$row.ExportIdentity; RrReceived = [datetime]$row.Received; RrPassword = $b.Password; RrIncoming = [string]$d.Incoming }
    $d.Work = Invoke-RrStep (Get-RrDialogSession $d) { Save-RrExport -Identity $RrIdentity -Received $RrReceived -Password $RrPassword -Incoming $RrIncoming } $vars
    $d.WorkKind = 'export'
    $d.Poll.Start()
    Update-RrView $d
}

function Complete-RrBatch($d) {
    $b = $d.Batch
    $d.Batch = $null
    try { $d.Session.Runspace.SessionStateProxy.SetVariable('RrPassword', $null) } catch { $null = $_ } # variable removal is best effort
    try { $b.Password.Dispose() } catch { $null = $_ } # zeroes the SecureString
    $total = $b.Items.Count
    $saved = 0
    $problems = New-Object System.Collections.Generic.List[string]
    $rejected = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $total; $i++) {
        $res = $b.Results[$i]
        $row = $b.Items[$i].Tag
        $label = "$(Format-RrDate $row.Received 'yyyy-MM-dd HH:mm') from $($row.Sender)"
        if ($res.Status -eq 'Saved') { $saved++; $b.Items[$i].Checked = $false }
        elseif ($res.Status -eq 'Exists') { $problems.Add("${label}: already in Incoming ($($res.FileName)), skipped."); $b.Items[$i].Checked = $false }
        else {
            $problems.Add("${label}: $($res.Message)")
            if ($res.Status -eq 'Rejected' -and $res.Summary) { $rejected.Add("Item $($i + 1) of ${total}`r`n" + (Format-RrZipSummary $res.Summary)) }
        }
    }
    $d.SaveState = 'done'
    $d.SaveSummary = "Saved $saved of $total to Incoming"
    $d.SaveAllOk = ($saved -eq $total)
    $d.SaveProblems = ($problems -join "`r`n")
    $d.RejectedText = ($rejected -join "`r`n`r`n")
    Update-RrView $d
    Invoke-RrPendingRefresh $d
}

function Complete-RrExport($d, $res) {
    $b = $d.Batch
    $r = $null
    if ($res.Error) { $r = New-RrResult 'Failed' '' ('The export failed: ' + $res.Error) $null }
    else { $r = @($res.Output | Where-Object { $_ -and $_.PSObject.Properties['Status'] }) | Select-Object -Last 1 }
    if (-not $r) { $r = New-RrResult 'Failed' '' 'The export returned no result.' $null }
    $b.Results += $r
    $b.Index++
    Start-RrNextExport $d
}

function Invoke-RrPoll($d) {
    $work = $d.Work
    if (-not $work) { $d.Poll.Stop(); return }
    if (-not $work.Handle.IsCompleted) {
        if ($d.WorkKind -eq 'connect') { Step-RrSignInWatch $d; return }
        if ($d.WorkKind -eq 'list' -and $d.Session -and -not $work.Cancelled) {
            $progress = [string]$d.Session.State['Progress']
            if ($progress -and $progress -ne $d.ListMsg) { $d.ListMsg = $progress; $d.Ctl.LblList.Text = $progress; Update-RrCancelLink $d }
        }
        return
    }
    $d.Poll.Stop()
    $d.Work = $null
    $res = Complete-RrStep $work
    if ($work.Cancelled) {
        # a cancelled list step has ended: its rows and its errors are not applied; the dialog is free for the next step
        Update-RrView $d
        Invoke-RrPendingRefresh $d
        return
    }
    switch ($d.WorkKind) {
        'connect' {
            if ($res.Error) {
                $d.ConnectState = 'failed'
                $d.ConnectMsg = 'Sign-in did not finish: ' + $res.Error
                Update-RrView $d
            } else {
                $d.ConnectState = 'done'
                $d.ConnectMsg = ''
                Update-RrView $d
                $d.Form.Activate()
                Start-RrList $d
            }
        }
        'list' {
            $payload = @($res.Output | Where-Object { $_ -and $_.PSObject.Properties['Messages'] }) | Select-Object -Last 1
            if (-not $payload) {
                $d.ListState = 'failed'
                $d.ListMsg = 'Could not list release requests: ' + $(if ($res.Error) { $res.Error } else { 'no data came back.' })
            } else {
                Set-RrRows $d @($payload.Messages) -KeepSelection
                $d.IncludeHandled = [bool]$payload.Handled
                $d.RawPending = [int]$payload.RawPending
                $d.ListState = 'loaded'
                $d.ListMsg = Get-RrListNote $d.Rows $d.Ctl.List.CheckedItems.Count $d.IncludeHandled $d.RawPending
            }
            Update-RrView $d
            Invoke-RrPendingRefresh $d
        }
        'export' { Complete-RrExport $d $res }
    }
}

function Stop-RrDialog($d) {
    # FormClosing: nothing may fire on a disposed form, and the Exchange session ends here.
    if (-not $d) { return }
    foreach ($tm in @($d.Poll, $d.InstallWatch)) { if ($tm) { $tm.Stop() } }
    if ($d.InstallProc) {
        try { $d.InstallProc.Dispose() } catch { $null = $_ } # the install window keeps running on its own
        $d.InstallProc = $null
    }
    if ($d.Batch) {
        try { $d.Batch.Password.Dispose() } catch { $null = $_ } # zeroes the SecureString
        $d.Batch = $null
    }
    if ($d.Session) {
        try { $d.Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor } catch { $null = $_ } # signing out can take a moment
        Close-RrSession $d.Session
    }
}

function New-RrDialog {
    param([string]$Incoming = '', [string[]]$SessionFunctions = @(), [switch]$NoAutoStart, $Owner = $null)
    if ($script:QraPerMonitor) {
        # Built for the screen it opens on: its owner's (it opens centred on it), else the one with the mouse. Screenshots and tests (NoAutoStart) keep the current scale.
        $ownerDpi = Get-QraWindowDpi $Owner
        if ($ownerDpi -le 0) { $ownerDpi = Get-QraFormDpi $Owner }
        if ($ownerDpi -gt 0) { Set-QraEmulatedDpi $ownerDpi } elseif (-not $NoAutoStart) { Set-QraEmulatedDpi (Get-QraMonitorDpi) }
    }
    $fonts = @{
        Title = (New-Font 18 'Bold' 'Display'); Sub = (New-Font 10); Row = (New-Font 11 'Bold'); Body = (New-Font 10); BodyBold = (New-Font 10 'Bold')
        Mono = (New-Font 9.5 'Regular' 'Mono'); Note = (New-Font 9.5)
    }
    $form = New-Object System.Windows.Forms.Form
    $form.SuspendLayout()
    Initialize-QraForm $form
    $form.Text = 'Fetch release requests - Quarantine Review Assistant'
    $form.Size = New-Object System.Drawing.Size(1330, 880)
    $form.MinimumSize = New-Object System.Drawing.Size(760, 640)
    $form.StartPosition = 'CenterScreen'
    $form.BackColor = $C.Surface
    Set-QraWindowChrome $form -NoAppId:([bool]$NoAutoStart)   # NoAutoStart is the screenshot/test build: it must not rename this process in the taskbar

    $header = New-Object System.Windows.Forms.Panel
    $header.Dock = 'Top'; $header.Height = 78; $header.BackColor = $C.Header
    $header.Add_Paint({ param($s, $e)
            if ($script:QraHighContrast -or $s.ClientRectangle.Width -le 0 -or $s.ClientRectangle.Height -le 0) { return }
            $br = New-Object System.Drawing.Drawing2D.LinearGradientBrush($s.ClientRectangle, $C.Header, $C.HeaderEnd, [single]90)
            $e.Graphics.FillRectangle($br, $s.ClientRectangle); $br.Dispose() })
    $hTitle = New-Object System.Windows.Forms.Label
    $hTitle.Text = 'Fetch release requests'; $hTitle.Font = $fonts.Title; $hTitle.ForeColor = $C.HeaderText; $hTitle.BackColor = [System.Drawing.Color]::Transparent
    $hTitle.AutoSize = $true; $hTitle.Location = New-Object System.Drawing.Point(22, 10)
    $hSub = New-Object System.Windows.Forms.Label
    $hSub.Text = 'Lists release requests and saves the messages you choose to Incoming. Nothing is opened on this PC.'
    $hSub.Font = $fonts.Sub; $hSub.ForeColor = $C.HeaderSub; $hSub.BackColor = [System.Drawing.Color]::Transparent
    $hSub.AutoSize = $true; $hSub.Location = New-Object System.Drawing.Point(24, 46)
    $header.Controls.AddRange(@($hTitle, $hSub))

    $footer = New-Object System.Windows.Forms.Panel
    $footer.Dock = 'Bottom'; $footer.Height = 56; $footer.BackColor = $C.Surface

    $body = New-Object System.Windows.Forms.Panel
    $body.Dock = 'Fill'; $body.BackColor = $C.Surface
    $body.Padding = New-Object System.Windows.Forms.Padding(16, 16, 16, 8)
    $card = New-QraCard
    $card.Dock = 'Fill'
    $scroll = New-Object System.Windows.Forms.Panel
    $scroll.Dock = 'Fill'; $scroll.AutoScroll = $true; $scroll.BackColor = $C.Card
    $card.Controls.Add($scroll)
    $body.Controls.Add($card)
    $form.Controls.Add($body)
    $form.Controls.Add($footer)
    $form.Controls.Add($header)
    $form.ResumeLayout($false)
    # Applied after ResumeLayout, like the launcher: an earlier ambient font would scale every control twice.
    $form.Font = $fonts.Body
    Limit-FormToScreen $form $Owner

    # ---- everything below is created after scaling, so every number goes through S()
    $k = @{ Scroll = $scroll }
    $d = @{
        Form = $form; Incoming = $Incoming; Fonts = $fonts; Ctl = $k; SessionFunctions = $SessionFunctions
        Session = $null; Work = $null; WorkKind = ''; Module = $null; InstallProc = $null; Batch = $null
        InstallState = 'idle'; InstallMsg = ''; ConnectState = 'idle'; ConnectMsg = ''; ListState = 'idle'; ListMsg = ''
        SaveState = 'idle'; SaveProgress = ''; SaveSummary = ''; SaveProblems = ''; SaveAllOk = $false; RejectedText = ''; Rows = @(); IncludeHandled = $false; RawPending = 0
        Steps = @(); Ready = $false; InLayout = $false
        ColNames = @('Received', 'Sender', 'Recipients', 'Subject', 'Quarantine type', 'Copies', 'Expires'); SortColumn = 'Received'; SortDesc = $true; PendingRefresh = $false; Populating = $false
        ListPrevState = 'idle'; ListPrevMsg = ''; ListByCheckbox = $false; CancelNote = $false; NoReact = $false
        SignInOld = @{}; SignInSeen = @{}; SignInLatest = [int64]0; SignInUntil = $null
    }
    $form.Tag = $d

    $stepTitles = @('Exchange Online module', 'Sign in', 'Choose messages', 'Save to Incoming')
    for ($i = 0; $i -lt 4; $i++) {
        $badge = New-QraStepBadge ($i + 1)
        $badge.Size = SSize 30 30
        $title = New-RrLabel $stepTitles[$i] $fonts.Row $C.Text
        $sum = New-RrLabel '' $fonts.Body $C.TextMuted
        $scroll.Controls.AddRange(@($badge, $title, $sum))
        $d.Steps += @{ Badge = $badge; Title = $title; Sum = $sum }
    }

    # step 1: install instructions
    $instr = @('Click the button below. A PowerShell window opens and installs the module.',
        'If it asks about NuGet or an untrusted repository, type Y and press Enter.',
        'When it shows "Installed. Close this window...", close that PowerShell window. This window continues by itself.')
    $k.I0Num = @(); $k.I0Txt = @()
    for ($i = 0; $i -lt 3; $i++) {
        $k.I0Num += New-RrLabel ("{0}." -f ($i + 1)) $fonts.BodyBold $C.Primary
        $k.I0Txt += New-RrLabel $instr[$i] $fonts.Body $C.Text
    }
    $k.BInstall = New-RrButton 'Install ExchangeOnlineManagement for my account' 'Primary' $QraGlyph.Play $fonts.BodyBold
    $k.BCopyCmd = New-RrButton 'Copy command' 'Secondary' $QraGlyph.Copy $fonts.Body
    $k.SpInstall = New-QraSpinner (S 24); $k.SpInstall.Visible = $false
    $k.LblWait = New-RrLabel 'Waiting for the install window to close...' $fonts.BodyBold $C.Text
    $k.LblInstallMsg = New-RrLabel '' $fonts.BodyBold $C.Warning

    # step 2: sign in
    $k.BSignIn = New-RrButton 'Sign in' 'Primary' $QraGlyph.Shield $fonts.BodyBold
    $k.SpConnect = New-QraSpinner (S 24); $k.SpConnect.Visible = $false
    $k.LblConnect = New-RrLabel "Waiting for you to sign in... If you don't see the sign-in window, check the taskbar." $fonts.BodyBold $C.Text
    $k.BShowSignIn = New-RrButton 'Show sign-in window' 'Link' '' $fonts.Body
    $k.LblConnectErr = New-RrLabel '' $fonts.BodyBold $C.Danger

    # step 3: choose messages
    $k.LblDays = New-RrLabel 'Days to look back' $fonts.Body $C.Text
    $k.Days = New-Object System.Windows.Forms.NumericUpDown
    $k.Days.Minimum = 1; $k.Days.Maximum = 30; $k.Days.Value = 16; $k.Days.Font = $fonts.Body; $k.Days.Visible = $false
    $k.LblRecip = New-RrLabel 'Recipient (optional)' $fonts.Body $C.Text
    $k.Recip = New-Object System.Windows.Forms.TextBox
    $k.Recip.Font = $fonts.Body; $k.Recip.Visible = $false
    $k.BRefresh = New-RrButton 'Refresh list' 'Secondary' $QraGlyph.Refresh $fonts.Body
    $k.ChkHandled = New-QraCheckBox 'Also show released and denied messages'
    $k.ChkHandled.Font = $fonts.Body; $k.ChkHandled.ForeColor = $C.Text; $k.ChkHandled.BackColor = $C.Card
    $k.ChkHandled.AutoSize = $false; $k.ChkHandled.UseMnemonic = $false; $k.ChkHandled.Visible = $false
    $k.LblHandled = New-RrLabel 'Includes messages released by an admin without a request.' $fonts.Body $C.TextMuted
    $lv = New-Object System.Windows.Forms.ListView
    $lv.View = 'Details'; $lv.CheckBoxes = $true; $lv.FullRowSelect = $true; $lv.HideSelection = $false; $lv.MultiSelect = $false
    $lv.HeaderStyle = 'Clickable'; $lv.BorderStyle = 'FixedSingle'; $lv.Font = $fonts.Body
    $lv.BackColor = $C.Card; $lv.ForeColor = $C.Text; $lv.Visible = $false; $lv.ShowItemToolTips = $true
    [void](Set-QraListCheckImages $lv)   # row check boxes in the same painted look, at the current scale (rebuilt on a DPI change)
    foreach ($col in @(@('Received', 128), @('Sender', 130), @('Recipients', 185), @('Subject', 160), @('Quarantine type', 108), @('Copies', 290), @('Expires', 84))) {
        [void]$lv.Columns.Add([string]$col[0], (S $col[1]))
    }
    $k.List = $lv
    Update-RrSortHeaders $d
    $k.SpList = New-QraSpinner (S 24); $k.SpList.Visible = $false
    $k.LblList = New-RrLabel '' $fonts.Body $C.TextMuted
    $k.BCancel = New-RrButton 'Cancel' 'Link' '' $fonts.Body
    $k.LblCancelNote = New-RrLabel 'Loading cancelled.' $fonts.Body $C.TextMuted
    $k.LblListHint = New-RrLabel 'One row per message. Saving exports one copy; decide for all copies in Defender.' $fonts.Body $C.TextMuted

    # step 4: save
    $k.LblPw = New-RrLabel 'Download password' $fonts.BodyBold $C.Text
    $k.Pw = New-Object System.Windows.Forms.TextBox
    $k.Pw.UseSystemPasswordChar = $true; $k.Pw.Font = $fonts.Body; $k.Pw.Visible = $false
    $k.LblPwNote = New-RrLabel 'Use this same password in the Sandbox review window.' $fonts.Body $C.TextMuted
    $k.BSave = New-RrButton 'Save to Incoming' 'Primary' $QraGlyph.Folder $fonts.BodyBold
    $k.BSave.Enabled = $false
    $k.SpSave = New-QraSpinner (S 24); $k.SpSave.Visible = $false
    $k.LblSave = New-RrLabel '' $fonts.Body $C.Text
    $k.LblSaved = New-RrLabel '' $fonts.BodyBold $C.Success
    $k.LblProblems = New-RrLabel '' $fonts.Body $C.Warning
    $k.LblRejHead = New-RrLabel '' $fonts.Body $C.Text
    $k.Rej = New-Object System.Windows.Forms.TextBox
    $k.Rej.Multiline = $true; $k.Rej.ReadOnly = $true; $k.Rej.ScrollBars = 'Vertical'; $k.Rej.Font = $fonts.Mono; $k.Rej.Visible = $false
    $k.BCopyDet = New-RrButton 'Copy details' 'Secondary' $QraGlyph.Copy $fonts.Body

    $scroll.Controls.AddRange(@($k.I0Num + $k.I0Txt + @($k.BInstall, $k.BCopyCmd, $k.SpInstall, $k.LblWait, $k.LblInstallMsg, $k.BSignIn, $k.SpConnect, $k.LblConnect, $k.BShowSignIn, $k.LblConnectErr,
                $k.LblDays, $k.Days, $k.LblRecip, $k.Recip, $k.BRefresh, $k.ChkHandled, $k.LblHandled, $k.List, $k.SpList, $k.LblList, $k.BCancel, $k.LblCancelNote, $k.LblListHint,
                $k.LblPw, $k.Pw, $k.LblPwNote, $k.BSave, $k.SpSave, $k.LblSave, $k.LblSaved, $k.LblProblems, $k.LblRejHead, $k.Rej, $k.BCopyDet)))

    # footer: a read-only reminder on the left, Close on the right
    $k.BClose = New-RrButton 'Close' 'Secondary' '' $fonts.Body
    $k.BClose.Visible = $true
    $k.FootNote = New-Object System.Windows.Forms.Label
    $k.FootNote.Text = 'Read-only: this tool never releases, deletes or blocks a message.'
    $k.FootNote.Font = $fonts.Note; $k.FootNote.ForeColor = $C.TextMuted; $k.FootNote.BackColor = $C.Surface
    $k.FootNote.AutoSize = $false; $k.FootNote.UseMnemonic = $false; $k.FootNote.TextAlign = 'MiddleLeft'
    $footer.Controls.AddRange(@($k.FootNote, $k.BClose))
    $k.Footer = $footer
    $placeFooter = {
        param($s)
        $dd = $s.FindForm().Tag
        if (-not $dd) { return }
        Use-QraFormDpi $dd.Form
        $kk = $dd.Ctl
        $kk.BClose.SetBounds(($kk.Footer.ClientSize.Width - (S 24) - (S 110)), (S 10), (S 110), (S 36))
        $kk.FootNote.SetBounds((S 26), (S 10), ($kk.Footer.ClientSize.Width - (S 190)), (S 36))
    }
    $footer.Add_Resize($placeFooter)

    # timers
    $d.Poll = New-Object System.Windows.Forms.Timer
    $d.Poll.Interval = 200
    $d.Poll.Tag = $d
    $d.Poll.Add_Tick({ param($s) Invoke-RrPoll $s.Tag })
    $d.InstallWatch = New-Object System.Windows.Forms.Timer
    $d.InstallWatch.Interval = 500
    $d.InstallWatch.Tag = $d
    $d.InstallWatch.Add_Tick({ param($s) Invoke-RrInstallWatch $s.Tag })

    # events
    $k.BInstall.Add_Click({ param($s) Start-RrInstall $s.FindForm().Tag })
    $k.BCopyCmd.Add_Click({ param($s)
            try { [System.Windows.Forms.Clipboard]::SetText((Get-RrInstallCommand)); Show-QraCopied $s 'Copied' } catch { $null = $_ } # the clipboard can be busy
        })
    $k.BSignIn.Add_Click({ param($s) Start-RrConnect $s.FindForm().Tag })
    $k.BShowSignIn.Add_Click({ param($s) [void](Show-RrSignIn $s.FindForm().Tag) })
    $k.BRefresh.Add_Click({ param($s) Start-RrList $s.FindForm().Tag })
    $k.BCancel.Add_Click({ param($s) [void](Stop-RrListLoad $s.FindForm().Tag) })
    $form.KeyPreview = $true
    $form.Add_KeyDown({ param($s, $e)   # Esc cancels a list load, and only then (otherwise it does nothing, as before)
            $dd = $s.Tag
            if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape -and $dd -and $dd.Ready -and $dd.ListState -eq 'loading' -and (Stop-RrListLoad $dd)) { $e.Handled = $true; $e.SuppressKeyPress = $true }
        })
    $k.BSave.Add_Click({ param($s) Start-RrSave $s.FindForm().Tag })
    $k.BCopyDet.Add_Click({ param($s)
            $dd = $s.FindForm().Tag
            try { [System.Windows.Forms.Clipboard]::SetText([string]$dd.RejectedText); Show-QraCopied $s 'Copied' } catch { $null = $_ } # the clipboard can be busy
        })
    $k.BClose.Add_Click({ param($s) $s.FindForm().Close() })
    $k.List.Add_ItemChecked({ param($s) $dd = $s.FindForm().Tag; if (-not $dd.Populating) { Update-RrSaveButton $dd } })
    $k.List.Add_ColumnClick({ param($s, $e) Invoke-RrSort $s.FindForm().Tag $e.Column })
    $k.ChkHandled.Add_CheckedChanged({ param($s) Invoke-RrHandledChanged $s.FindForm().Tag })
    $k.Recip.Add_KeyDown({ param($s, $e)
            if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) { $e.SuppressKeyPress = $true; $e.Handled = $true; Start-RrList $s.FindForm().Tag }
        })
    $k.Pw.Add_TextChanged({ param($s) Update-RrSaveButton $s.FindForm().Tag })
    $scroll.Add_Resize({ param($s) Update-RrView $s.FindForm().Tag })
    $form.Add_FormClosing({ param($s) Stop-RrDialog $s.Tag })
    if (-not $NoAutoStart) { $form.Add_Shown({ param($s) Update-RrModuleStep $s.Tag }) }

    Set-Access $k.BInstall 'Install the ExchangeOnlineManagement module for my account'
    Set-Access $k.BCopyCmd 'Copy the install command'
    Set-Access $k.BSignIn 'Sign in to Exchange Online'
    Set-Access $k.BShowSignIn 'Bring the Microsoft sign-in window to the front'
    Set-Access $k.Days 'Days to look back'
    Set-Access $k.Recip 'Recipient address filter, optional. Press Enter or Refresh list to apply'
    Set-Access $k.BRefresh 'Refresh the list of release requests'
    Set-Access $k.BCancel 'Cancel loading the release requests'
    Set-Access $k.ChkHandled 'Also show released and denied messages'
    Set-Access $k.List 'Messages with release requests, select the messages to save. Use the column headers to sort.'
    Set-Access $k.Pw 'Download password'
    Set-Access $k.BSave 'Save the selected messages to Incoming'
    Set-Access $k.Rej 'Details of the rejected export'
    Set-Access $k.BCopyDet 'Copy the details of the rejected export'
    Set-Access $k.BClose 'Close this window'
    $ti = 0
    foreach ($ctl in @($k.BInstall, $k.BCopyCmd, $k.BSignIn, $k.BShowSignIn, $k.Days, $k.Recip, $k.ChkHandled, $k.BRefresh, $k.BCancel, $k.List, $k.Pw, $k.BSave, $k.Rej, $k.BCopyDet)) { $ctl.TabIndex = $ti++ }
    $k.BClose.TabIndex = 0

    $d.Ready = $true
    $d.PlaceFooter = $placeFooter
    & $placeFooter $footer $null
    # Rescaled live when the window is dragged to a screen with another scale (no-op in system mode, the fallback and Constrained Language Mode).
    [void](Register-QraDpiWindow $form -FontTables @($fonts) -Relayout {
            param($f)
            $dd = $f.Tag
            & $dd.PlaceFooter $dd.Ctl.Footer $null
            Use-QraFormDpi $f
            [void](Set-QraListCheckImages $dd.Ctl.List)   # the row check boxes follow the new scale
            Update-RrView $dd
        })
    $d
}

function Show-ReleaseRequestDialog {
    param([string]$Incoming, $Owner)
    $d = New-RrDialog -Incoming $Incoming -Owner $Owner
    try {
        if ($Owner) { $d.Form.StartPosition = 'CenterParent'; [void]$d.Form.ShowDialog($Owner) } else { [void]$d.Form.ShowDialog() }
    } finally {
        Stop-RrDialog $d
        $d.Form.Dispose()
        Use-QraFormDpi $Owner   # the owner's scale is the current one again
    }
}

# ================================================================= screenshot support (synthetic data, no connection, no file access)

function ConvertTo-RrShotDate([string]$text) {
    [datetime]::ParseExact($text, 'yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Set-RrScreenshotState($d, [string]$State = 'results') {
    $k = $d.Ctl
    $d.Module = [pscustomobject]@{ Installed = $true; Version = '3.11.1'; InstallCommand = (Get-RrInstallCommand) }
    $d.InstallState = 'idle'; $d.InstallMsg = ''
    if ($State -eq 'missing') {
        $d.Module = [pscustomobject]@{ Installed = $false; Version = ''; InstallCommand = (Get-RrInstallCommand) }
        $d.ConnectState = 'idle'; $d.ListState = 'idle'; $d.SaveState = 'idle'
        Set-RrRows $d @()
        Update-RrView $d
        return
    }
    # three messages (synthetic): the copies of each are what the MessageId lookup would return
    $expires = ConvertTo-RrShotDate '2026-12-25 00:00'
    $plan = @(
        @{ At = '08:12'; Sender = 'billing@invoice-pay.example'; Subject = 'Invoice 4471 - action required'; Type = 'HighConfPhish'; Who = @(); Copies = @('REQUESTED', 'REQUESTED', 'RELEASED', 'RELEASED', 'NOTRELEASED', 'NOTRELEASED', 'NOTRELEASED') },
        @{ At = '09:03'; Sender = 'it-helpdesk@contoso-mail.example'; Subject = 'Password expires today - verify now'; Type = 'Phish'; Who = @('a.rivera@corp.example', 'j.okafor@corp.example', 'm.haddad@corp.example', 'l.petit@corp.example'); Copies = @('REQUESTED', 'NOTRELEASED', 'NOTRELEASED', 'NOTRELEASED') },
        @{ At = '09:47'; Sender = 'shipping@parcel-track.example'; Subject = 'Parcel on hold: confirm your delivery'; Type = 'Spam'; Who = @('p.nguyen@corp.example'); Copies = @('REQUESTED') }
    )
    $pendingRows = @()
    $lookups = @{}
    for ($m = 0; $m -lt $plan.Count; $m++) {
        $p = $plan[$m]
        $mid = '<shot-{0}@{1}>' -f ($m + 1), ($p.Sender -split '@')[1]
        $copies = @()
        for ($n = 0; $n -lt $p.Copies.Count; $n++) {
            $copies += [pscustomobject]@{
                Identity = ('00000000-0000-4000-8000-{0:x12}\00000000-0000-4000-8000-{1:x12}' -f ($m + 1), (($m + 1) * 100 + $n + 1))
                MessageId = $mid; ReleaseStatus = $p.Copies[$n]; Released = ($p.Copies[$n] -eq 'RELEASED')
                Received = (ConvertTo-RrShotDate ('2026-11-25 ' + $p.At)); Sender = $p.Sender; Recipient = $(if ($n -lt $p.Who.Count) { $p.Who[$n] } else { '' }); Subject = $p.Subject; QuarantineTypes = $p.Type; Expires = $expires
            }
        }
        $pendingRows += @($copies | Where-Object { $_.ReleaseStatus -eq 'REQUESTED' })
        $lookups[$mid] = $copies
    }
    $rows = @(Group-RrMessages $pendingRows $lookups)
    Set-RrRows $d $rows
    $d.ConnectState = 'done'
    $d.ListState = 'loaded'
    $d.IncludeHandled = $false
    $d.RawPending = $pendingRows.Count
    $d.ListMsg = Get-RrListNote $rows 0 $false $d.RawPending
    $k.List.Items[0].Checked = $true
    $k.List.Items[2].Checked = $true
    $k.Pw.Text = '        '   # eight blanks: the box shows mask dots only, there is no secret in a screenshot
    $d.SaveState = 'done'
    $d.SaveSummary = 'Saved 2 of 2 to Incoming'
    $d.SaveAllOk = $true
    $d.SaveProblems = ''
    $d.RejectedText = ''
    if ($State -eq 'loading') {
        # the checkbox is ticked and its load is running: the spinner, the progress note and the Cancel link
        $d.NoReact = $true
        try { $k.ChkHandled.Checked = $true } finally { $d.NoReact = $false }
        $d.ListState = 'loading'; $d.ListMsg = 'Checking other copies (12 of 31)...'; $d.ListByCheckbox = $true
        $d.SaveState = 'idle'; $d.SaveSummary = ''
        $k.Pw.Text = ''
    }
    Update-RrView $d
}

# ================================================================= standalone mode (not dot-sourced)
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    try { [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false) } catch { $null = $_ } # GDI text like the launcher; too late if a control already exists
    if ($RrScreenshot) { $env:QRA_DPI_MODE = 'system' }   # review pictures: one fixed system DPI, no per-monitor behaviour
    . (Join-Path $PSScriptRoot 'QraUi.ps1')
    [System.Windows.Forms.Application]::EnableVisualStyles()
    if (-not $RrIncoming) { $RrIncoming = Join-Path (Split-Path -Parent $PSScriptRoot) 'Incoming' }
    if ($RrScreenshot) {
        try {
            [void][System.IO.Directory]::CreateDirectory($RrScreenshot)
            $dlg = New-RrDialog -Incoming 'D:\SecurityReview\Incoming' -NoAutoStart
            $dlg.Form.ShowInTaskbar = $false; $dlg.Form.Opacity = 0; $dlg.Form.StartPosition = 'Manual'
            $dlg.Form.Location = New-Object System.Drawing.Point(-32000, -32000)
            $dlg.Form.Show()
            [System.Windows.Forms.Application]::DoEvents()
            $shots = @(@('results', 'release-requests.png'), @('missing', 'release-requests-missing.png'))
            if ($RrScreenshotState) { $shots = @(, @($RrScreenshotState, 'release-requests.png')) }
            foreach ($shot in $shots) {
                Set-RrScreenshotState $dlg $shot[0]
                $dlg.Form.ActiveControl = $null
                [System.Windows.Forms.Application]::DoEvents()
                $bmp = New-Object System.Drawing.Bitmap($dlg.Form.Width, $dlg.Form.Height)
                $dlg.Form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $dlg.Form.Width, $dlg.Form.Height)))
                $bmp.Save((Join-Path $RrScreenshot $shot[1]), [System.Drawing.Imaging.ImageFormat]::Png)
                $bmp.Dispose()
            }
            $dlg.Form.Dispose()
        } catch {
            [Console]::Error.WriteLine($_.Exception.Message + "`n" + $_.InvocationInfo.PositionMessage + "`n" + $_.ScriptStackTrace)
            exit 1
        }
        exit 0
    }
    Hide-QraConsole
    try {
        Show-ReleaseRequestDialog -Incoming $RrIncoming
    } catch {
        [System.Windows.Forms.MessageBox]::Show("The release-request window hit an unexpected error:`r`n`r`n$($_.Exception.Message)", 'Quarantine Review Assistant', 'OK', 'Error') | Out-Null
    }
}
