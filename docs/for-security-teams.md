# For security teams: what Quarantine Review Assistant does

This page is for the person who approves software. You do not need to have seen the tool before. It is one page on purpose. The
README and [architecture.md](architecture.md) have the detail.

## What it is, and what it never does

Quarantine Review Assistant helps an IT admin look inside a suspicious message that Microsoft 365 has quarantined. The admin
downloads the message as a password-protected ZIP, and the tool inspects it inside a disposable Windows Sandbox that has no
network. It then gives a recommendation (delete, keep, release after checks). The admin still acts in Microsoft Defender.

It never:

- **executes** anything from a message or attachment (no automated test proves a negative; the analyzer is one Python file that imports only the standard library and starts no process, and `tests/test_analyzer.py::test_case` analyzes every synthetic sample through the CLI).
- **renders** HTML, opens attachments or loads remote content (no dedicated test; the analyzer only reads text and bytes, and the review window shows text only).
- **extracts to disk on the host**. Archives are read in memory, and message parsing runs only inside the Sandbox (no dedicated analyzer test; the analyzer writes only the report files it is told to). For the optional intake (`tests/powershell/ReleaseRequests.Tests.ps1`, "ReleaseRequests: Save-RrExport" > "saves a valid encrypted ZIP once, as the only file anywhere (Incoming and TEMP)"): only encrypted `*.zip` files are ever written.
- **uploads** anything. The only network calls are the ones listed under [Network calls](#network-calls) (`tests/powershell/Docs.Tests.ps1`: Network URLs are documented).
- **changes anything in your tenant**. The optional intake reads and exports only. Release, deny, delete and block-list changes stay in Defender (`tests/powershell/ReleaseRequests.Tests.ps1`, "ReleaseRequests: source scans" > "is read-only: no release, delete, block-list or Set-* Exchange cmdlets").
- **puts a password on a command line or in a report** (`tests/test_analyzer.py::test_password_is_not_in_the_reports`; the password goes to the analyzer on standard input).
- **says a message is safe.** "No strong indicators" is never a safe verdict.

## What runs where

| Part | Where | What it is |
|---|---|---|
| Launcher | Your PC (host) | Windows PowerShell 5.1 and WinForms. Checks the PC, downloads Python once, writes the Sandbox profile, starts the Sandbox. |
| Review window | Inside Windows Sandbox | A PowerShell window that sends the password to the analyzer and shows its report. |
| Analyzer | Inside Windows Sandbox only | One Python file (`inspect_eml.py`) using only the Python standard library. |

**How PowerShell is started.** `Start-Here.cmd` contains this line:

```
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0app\Launcher.ps1"
```

`-ExecutionPolicy Bypass` applies to that one PowerShell process only (process scope). It does not change any machine or user
policy, and it ends when the launcher closes. `Start-Review.cmd` is a fallback that runs only inside the Sandbox, and it starts
`QuarantineReview.ps1` the same way (`powershell.exe -NoProfile -ExecutionPolicy Bypass -File`). The Sandbox profile starts the
review window with that same command plus `-WindowStyle Hidden`.

**The Sandbox profile** (`Profiles\QuarantineReview.wsb`, written by the launcher):

| Setting | Default mode | Compatibility mode |
|---|---|---|
| Networking | Disabled | Disabled |
| Clipboard redirection | Disabled | Windows Sandbox default (clipboard sharing allowed) |
| Printer redirection | Disabled | Windows Sandbox default |
| Audio input, video input, vGPU | Disabled | Windows Sandbox default |
| Protected Client | Off unless the reviewer ticks it | Windows Sandbox default |
| Tool folder (`C:\Review`) | Mapped read-only | Mapped read-only |
| `Reports` folder (`C:\Reports`) | Writable, only if the reviewer allows it | Same |

Compatibility mode exists for PCs where the Sandbox will not start. It is weaker: the clipboard and the other redirections keep
the Windows defaults. Networking stays off in both modes.

`tests/powershell/Launcher.Tests.ps1` ("Launcher: sandbox profile settings") writes the profile for the default, Protected and Compatibility combinations and checks the generated XML against this table. It checks what the file asks for. Windows Sandbox itself enforces it, and no test starts a Sandbox.

## Network calls

This is the complete list. A test fails the build if a runtime file contains a URL that is not listed here or marked as a plain link.

Calls the tool makes:

- `https://www.python.org/ftp/python/3.14.8/python-3.14.8-embed-amd64.zip`: the official Python embeddable package, downloaded **once** by the launcher on the host when the reviewer clicks **Download**. The file is checked against a pinned SHA-256 in `Launcher.ps1` and nothing is installed if it does not match.
- Optional intake (v2.3) only, and only when the reviewer opens the dialog: `login.microsoftonline.com` (the standard Microsoft sign-in) and `outlook.office365.com` (Exchange Online: message list metadata and the encrypted ZIP bytes of the messages the reviewer selects). The module chooses the exact endpoints for your cloud.
- Optional intake only, and only if the reviewer clicks the install button: `www.powershellgallery.com` (PowerShell Gallery, to install the `ExchangeOnlineManagement` module for the current user).

Nothing else. The Sandbox has no network at all.

### Links the tool opens in your browser

These are links the reviewer's browser opens. The tool itself makes no request to them.

- `https://security.microsoft.com/quarantine`: the Defender quarantine page, opened by the **Open Defender quarantine** button.

## What the host shows during intake

The intake list shows one row per message (Exchange keeps one quarantine row per recipient copy, and the tool groups them). It has six columns: **Received, Sender, Subject, Quarantine type, Copies, Expires**. **Copies** summarises the recipient copies by status, for example `2 pending · 2 released · 3 not requested`. No message body and
no attachment is opened or shown on the host. The reviewer selects the messages to export; none is selected by default. Saving exports one copy per selected message. The release decision for all copies stays in Defender. Microsoft lists quarantined messages either once per message or once per recipient (per-recipient since early 2026); the dialog groups both into one row per message. An optional view, **Also show released and denied messages** (off by default), adds messages that were already released or denied. To count the copies, the tool runs one more read-only `Get-QuarantineMessage -MessageId` lookup per listed message.

## Permissions

- **Local administrator:** only to turn on the Windows Sandbox feature, once, with a Windows UAC prompt (and a restart). Everything else runs as a normal user.
- **Module install:** `ExchangeOnlineManagement` installs for the current user only (`-Scope CurrentUser`), without admin rights, and only when the reviewer clicks the install button.
- **Microsoft 365 roles for the intake:** per [Microsoft Learn](https://learn.microsoft.com/defender-office-365/quarantine-admin-manage-messages-files), previewing and downloading quarantined messages for all users needs Global Reader, Security Reader or Security Operator. Verify this in your tenant. **No release rights are needed.**
- The sign-in is the standard interactive Microsoft sign-in (with MFA). There are no stored credentials, no app registration and no secrets.

## Data flow and retention

| What | Where | Notes |
|---|---|---|
| Downloaded ZIPs | `Incoming\` in the tool folder | Password-protected ZIPs only. The intake never writes any other file type. |
| Analysis report and decision | `C:\Work` inside the Sandbox, and `Reports\` on the host if allowed | `C:\Work` is deleted when the Sandbox closes. |
| Audit log | `Reports\decisions-log.csv` | One row per recorded decision: reviewer, decision, recommendation, Microsoft's verdict, input SHA-256. Formula-like fields are escaped. |
| Python runtime | `Tools\Python\` in the tool folder | Downloaded once. |
| Sandbox profile | `Profiles\QuarantineReview.wsb` | Rewritten at each launch. |

- **Disconnect** (when the intake dialog closes) ends the Exchange Online session in that window. The Windows account stays signed in to Windows, as with any other Microsoft sign-in, so a later sign-in in the same Windows session is faster.
- **Clean-up:** after acting in Defender, close the Sandbox and click **Delete Incoming...** in the launcher (step 5). Delete `Reports\` yourself when you no longer need the history. The tool sends nothing off the PC.

## How to verify a release

1. Compare the SHA-256 of the downloaded ZIP with the `.sha256` file next to it on the [Releases](https://github.com/MahmoudGooda/quarantine-review-assistant/releases) page.
2. Check that the CI run for the release tag passed.
3. Compare the ZIP's contents with the tagged source. Everything is plain-text PowerShell plus one Python file.

**Releases are not code-signed yet (planned for v2.8).**

## What to allow if your policy blocks it

- The tool folder, as a **path rule** (AppLocker or WDAC), so the scripts run there.
- `https://www.python.org/ftp/python/3.14.8/python-3.14.8-embed-amd64.zip` once, or place the same Python embeddable package in `Tools\Python` yourself.
- PowerShell script execution for that folder only.
- For the optional intake: the Microsoft sign-in and Exchange Online hosts above, and the PowerShell Gallery only if you want the install button to work.

Please do not weaken a policy globally to run this tool.

## Known limits

- Needs Windows 10 (1903 or later) or Windows 11 **Pro, Enterprise or Education**, with CPU virtualization on. Home has no Windows Sandbox.
- **Constrained Language Mode: not supported.** The launcher loads WinForms and compiles its painted controls with `Add-Type`. In Constrained Language Mode `Add-Type` is refused and the WinForms types cannot be found, so the launcher does not open a window. We tested a PowerShell session set to Constrained Language Mode: the launcher stopped with "Unable to find type [System.Windows.Forms.MessageBox]" (its error dialog cannot load either) and showed no window. The tool does not detect this case or show a friendlier message. Allow the tool folder so it runs in Full Language Mode. The intake also needs the `ExchangeOnlineManagement` module, which we have not verified under Constrained Language Mode, so treat it as unsupported there.
- It is **not an antivirus**. It reads metadata and structure. It cannot see zero-day exploits, text inside images or QR codes, or links that turn malicious later.
- **"No strong indicators" is not a safe verdict.** The tool never says a message is safe. It tells the reviewer what to verify before releasing.
