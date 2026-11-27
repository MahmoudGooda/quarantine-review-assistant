# Changelog

All notable changes are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/), and the version number is
the same in `Launcher.ps1`, `QuarantineReview.ps1`, `inspect_eml.py` and both READMEs (a Pester test enforces that).

## [Unreleased]

## [2.3.1] - 2026-11-27

### Added
- **Cancel a release-request load.** While the list loads, a **Cancel** link (or Esc) stops it without waiting: the rows and the selection stay as they were, **Also show released and denied messages** goes back to its previous state, and the Exchange session stays ready for the next list or export (exports cannot be cancelled).

### Changed
- **The decision record is always in view in the Sandbox.** **Record your decision** moved from the end of the Decision tab to the bottom of
  the left column, so it no longer needs scrolling and stays there on every tab. It appears once there is a result to record.
- **Step 5 shows each recorded decision as a card.** One card per message with the decision as a coloured badge (red for delete or block, green for release, amber for keep quarantined), its confidence and time, the subject, the sender and file name, and the tool and Microsoft verdicts. A message without a decision gets a muted "Not reviewed yet" card, a long list scrolls above the buttons, and the intro and the clean-up step use the plural when there are several messages.

### Fixed
- **The Microsoft sign-in window now comes to the front.** In the release-requests dialog the sign-in window could open behind other windows. The dialog now brings it forward itself as soon as it appears, and a **Show sign-in window** link next to the waiting text does it on demand.
- **Check boxes are in proportion on scaled screens.** The launcher options and the release-request dialog use a Windows 11 style check box, and the message list uses matching row check boxes, drawn at the scale of the screen the window is on (the standard ones stayed small next to the text at 125 %).
- **Sharp text on PCs with screens of different scaling.** The launcher and the release-request dialog followed one scale for the whole PC, so
  Windows stretched them (soft text) on a screen with another scale. They now follow the screen they are on: they open at the scale of the screen
  with the mouse (the dialog at the scale of the launcher) and rescale as soon as they are dragged to another screen. The start-up splash is
  sized for that screen too and drawn at its real size. The Sandbox review window is unchanged.
- **The launcher reads the display scale from the screen.** Before, the start-up splash could leave the graphics library with a stale 96 dpi,
  so the layout was computed at 100 % on a scaled PC.
- **No PowerShell window when the launcher starts.** `Start-Here.cmd` now starts PowerShell minimised (`start "" /min`), so no PowerShell
  window appears before the splash. A double-click on a `.cmd` file still shows the small `cmd` window for a moment; the desktop shortcut
  (created by **Create desktop shortcut**) starts minimised and shows nothing.
- **Several messages in Incoming.** Reviewing more than one saved message no longer ends on "The Sandbox closed before a decision reached this PC". The launcher now checks every package in Incoming against every recorded decision (by the SHA256 of the file), shows "1 of 2 messages reviewed" with a **Continue with N decision(s)** button while some are still open, and lists every decision in step 5. **Copy block list** then holds the combined, de-duplicated list of all reviewed messages. A closed Sandbox is reported as failed only when that run left no new decision.
- **The Sandbox review window uses the same crisp GDI text as the launcher** (labels, check boxes and buttons).

## [2.3.0] - 2026-11-27

### Added
- **Animated start-up splash.** The launcher opens with an image splash (product picture, name, version and a calm progress bar). It runs
  on its own thread, so it keeps moving while the window is built. If the picture is missing, a plain navy splash with the same animation is used.
- **Create desktop shortcut** button in step 1, next to **Check again**. It writes one shortcut to your Desktop and one icon file to the tool
  folder, only when clicked, and asks before replacing an existing shortcut.
- **Release-request intake (optional).** A **Fetch release requests** button in step 3 of the launcher opens a dialog that lists
  quarantined messages with a pending release request through read-only Exchange Online PowerShell. Exchange keeps one row per
  recipient copy, so the list shows **one row per message** (Received, Sender, Recipients, Subject, Quarantine type, Copies, Expires). **Copies**
  summarises the recipient copies by status (for example `2 pending · 2 released · 3 not requested`) and flags a message that was
  already released to some recipients. An optional **Also show released and denied messages** view is off by default. Every checkbox
  starts unselected and saving exports one copy per selected message. The default window is 16 days (maximum 30) and the query returns
  up to 1000 rows.
- **Recipients column, sorting and automatic refresh.** **Recipients** shows the first known address with `(+N)` for the rest (or
  `7 recipients` when Exchange gave no address) and lists everyone in the tooltip, from data the listing already returned. A click on a
  column header sorts the list (again to reverse; newest first by default). Turning **Also show released and denied messages**
  on or off refreshes the list by itself, and the selection is kept across sorting and refreshing.
- **Encrypted ZIP only.** An export is written to `Incoming` as a password-protected ZIP only after its bytes pass a check: ZIP
  signature, a readable central directory, at least one entry, and the encryption flag on every entry. A rejected export writes
  nothing and shows a summary that contains no entry names or content.
- **Install button.** If the `ExchangeOnlineManagement` module is missing, a button installs it for the current user in a visible
  Windows PowerShell 5.1 window (`Install-Module ExchangeOnlineManagement -Scope CurrentUser`). Nothing is installed without the click.
- `docs/for-security-teams.md`: a one-page description for an approver (what runs where, the complete list of network calls,
  permissions, retention, how to verify a release, known limits), with a Pester test that every URL in the runtime files is documented.

### Security
- The download password is typed once per batch in a masked box, held as a SecureString, passed to the Exchange Online session
  without appearing in any script text or argument, and cleared. It is never logged or written.
- The tool never writes an `.eml` or any file other than the `.zip`, and nothing goes to TEMP.
- The intake is read-only: it uses no release, delete, `Set-*` or Tenant Allow/Block List cmdlet.
- The Exchange Online session is disconnected when the dialog closes (including when the launcher closes). The `-DisableWAM`
  switch is not used.

### Changed
- Sandbox review window, step 2: a **Continue** button (or Enter in the password box) moves on to the Analyze step. Analysis starts only
  when you click **Analyze**.
- Roadmap: code signing moved from v3.0 to v2.8 (Enterprise readiness), and v3.0 is now "Playbook and training lab".

## [2.2.0] - 2026-11-25

First release from the public repository.

### Fixed
- Uninspected nested content prevents a release recommendation. Packages containing several messages require individual review before the tool offers sender or blocking actions.
- Attachment-password reporting records the source of a successful password. Legacy reports with password fields require reanalysis.
- Spreadsheet-sensitive fields are escaped in the decision CSV. Each save target publishes its completed decision after the reports and audit entry succeed. The launcher checks the incoming file's SHA-256 before offering its block list.
- The release ZIP includes the license and third-party notices. CI installs the Windows test dependencies and runs ScriptAnalyzer on each source directory. Git ignores mail files and ZIP archives inside the tests directory.
- **A failed save was silent.** `Save-DecisionRecord` and **Save report** wrapped every target in an empty `catch {}`.
  *Repro (v2.1.1):* tick "save reports to this PC", open `Reports\decisions-log.csv` in Excel on the host (it locks the file), then click
  **Record decision** in the Sandbox. The write to the host folder fails, nothing says so, and the dialog lists only `C:\Work (inside Sandbox -
  deleted on close)`. If every target fails, the dialog says "Saved to:" followed by nothing.
  *Now:* every target is tried on its own, the dialog names each target that failed with the reason, and if nothing could be written it shows
  an error ("NOT SAVED") and never says "Saved".
- **Contrast (WCAG 2.1 AA, 4.5:1).** Amber question text was 3.24:1, white on the amber banner and cards was 3.02:1 to 3.59:1, and the warning
  colour was 3.58:1 to 3.87:1. The amber banner is now `(160, 82, 0)` (5.67:1 with white), and amber text on light backgrounds and the warning
  colour are `(150, 85, 0)` (5.27:1 or more). The `SUSPICIOUS` entry of the old `$Levels` table was never used: the banner users see is the
  amber decision colour, and that is what changed.
- **High-DPI displays.** Both windows are now DPI-aware, scale their layout at 125 %, 150 % and 175 %, and never open larger than the screen.
  The review window reduces horizontal tab padding at narrower widths so all eight labels fit at 175% scaling at the minimum window size.
- **Findings tab:** the "Where" column no longer hides the path. Columns are sized to their text, hovering a cell that is cut off shows its full text, and a box
  under the list shows the selected finding's title, severity, full location, ATT&CK ID and details.
- **Defender steps box** is as tall as its text instead of a fixed, mostly empty rectangle.

### Added
- Keyboard: `Ctrl+1` ... `Ctrl+8` switch tabs, `Ctrl+S` saves the report, a visible focus ring on buttons, and a logical tab order.
- Accessible names on every input, button, list and status chip, and a status word for every launcher check.
- Tests: a synthetic sample generator (ZipCrypto and AES-256 Defender-style packages), analyzer tests through the CLI, Pester tests for
  script syntax, file encoding and version numbers, a release build script, and CI.
- **Guided step rail in both windows.** The launcher shows five steps (Prepare this PC, Check it in Defender, Download the message, Analyze in
  the Sandbox, Act in Defender and clean up) with a status for each; the review window is a four-step accordion (Choose the package, Enter the
  download password, Analyze, Decide) that opens the step you are on and folds finished steps to a one-line summary. Step 1 of the launcher
  now lists what to do (wait, fix the red item, check again).
- **Loading states.** A readiness spinner while the launcher checks the PC, a determinate progress bar for the Python download, tracking of the
  Sandbox launch (starting, review in progress), and in the review window a stage tracker (Reading file, Opening package, Analysing, Building
  report) with a large spinner, an elapsed time and a **Cancel** button. The painted spinner appears only after 300 ms, so quick work never flashes (the plain fallback spinner shows at once).
- **-Screenshot <folder>** for both scripts (with -ScreenshotDpi <n> and -ScreenshotMinSize, and -ScreenshotResult <report.json> for the
  review window): renders every step state from built-in fake data to PNG files, headless, without reading Incoming or starting Python or
  the Sandbox. Used for the layout checks at emulated display scales (`-ScreenshotDpi` 96, 120, 144 and 168), not on real 125 %, 150 % or 175 % displays.

### Changed
- The version number is `2.2.0` everywhere, including `inspect_eml.py`.
- `.py` and `.md` files use LF line endings. `.cmd` and `.ps1` files keep CRLF, and the runtime `.ps1` files keep their UTF-8 BOM.
- **Shared UI kit `app/QraUi.ps1`** (packaged with the release): DPI helpers, one set of colour tokens (every text pair is at least 4.5:1,
  control borders and the focus ring at least 3:1), Windows 11 fonts with a Windows 10 fallback, and painted controls (rounded cards,
  spinner, step badges, status pills, buttons with hover, pressed and focus states) written in C# and compiled once. If the compile fails,
  the language mode is not Full Language, or `QRA_UI_FALLBACK=1` is set, plain WinForms controls are used instead (in Constrained Language Mode
  WinForms itself cannot load, so the windows cannot start there: allow the tool folder through AppLocker/WDAC so it runs in Full Language). With high contrast on, the
  painted controls stay but use system colours and draw no shadow or gradient.
  Also a background-work helper (`Start-QraWork`) that keeps the window responsive.
- **Premium restyle of both windows**: rounded cards on a light surface, a navy header with status pills, painted buttons with hover, pressed
  and focus states, one type scale, and consistent spacing.

### Removed
- A duplicated `$optReports.Checked = $true` line in the launcher, and an empty loop in `assess()` of the analyzer (it had no side effects,
  and the reports for all test samples are identical without it).

## 2.1.1 - internal release

Used internally before the repository was published. It was never released publicly; it is listed only because the 2.2.0 fixes refer to it.

[Unreleased]: https://github.com/MahmoudGooda/quarantine-review-assistant/compare/v2.3.1...HEAD
[2.3.1]: https://github.com/MahmoudGooda/quarantine-review-assistant/compare/v2.3.0...v2.3.1
[2.3.0]: https://github.com/MahmoudGooda/quarantine-review-assistant/compare/v2.2.0...v2.3.0
[2.2.0]: https://github.com/MahmoudGooda/quarantine-review-assistant/releases/tag/v2.2.0
