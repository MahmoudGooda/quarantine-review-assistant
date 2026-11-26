# Quarantine Review Assistant v2.3.0

Offline review of emails held in **Microsoft Defender / EOP quarantine**, done inside a disposable,
network-less **Windows Sandbox**. It inventories the message, its attachments and anything nested in them
(ZIP → email → attached ZIP → files), with hashes and risk findings. Nothing is executed, rendered or
extracted to disk.

> This is **not** an antivirus. "No strong indicators" is never a safe verdict.

## Quick start

1. Extract the `SecurityReview` folder to a **local, non-synced** drive, e.g. `D:\SecurityReview`
   (not OneDrive or Desktop if that is synced).
2. Double-click **`Start-Here.cmd`**. The launcher checks this PC and fixes what it can:

   | Check | What happens if it fails |
   |---|---|
   | Windows edition | Home is not supported: use a Pro/Enterprise/Education PC |
   | CPU virtualization | Tells you to enable Intel VT-x / AMD-V in BIOS/UEFI |
   | Windows Sandbox feature | **Install** button: asks for admin approval (UAC), then **restarts the PC** |
   | Pending restart | **Restart now** button |
   | Analysis runtime | **Download** button: official Python embeddable package from python.org, SHA256-verified, no install |
   | Tool folder | Warns if the folder is cloud-synced or on a network share |

3. Follow the five steps in the rail on the left of the launcher. The current step opens by itself, a green check marks
   each finished step, and you can click any step to look back at it:
   1. **Prepare this PC.** The readiness checks above (the **Check again** button re-runs them). The PC, Python and
      Sandbox status chips at the top of the window summarise them.
   2. **Check it in Defender.** Click **Open Defender quarantine** and look at the reason, sender and preview there
      first. Do not release. Then click **I've checked it - next**.
   3. **Download the message.** In the portal choose **... More > Download message** with a password, and save the ZIP
      into `Incoming` without opening it. The step finishes by itself when the file appears.
      Optional: **Fetch release requests** lists the messages with a pending release request (read-only, through Exchange Online
      PowerShell) and saves the ones you select as password-protected ZIPs in `Incoming`. The manual portal download above still works.
      See `docs/for-security-teams.md` in the repository for what it connects to.
   4. **Analyze in the Sandbox.** Click **Launch Sandbox review**. The review window opens by itself inside the
      Sandbox. Follow the four steps in the left column: pick the file, type the download password, press **Enter**. If you turned off saving reports to this PC,
      click **I've recorded my decision - next** when you are done.
   5. **Act in Defender and clean up.** Carry the decision out in Defender, close the Sandbox, then click
      **Delete Incoming...**. When everything is done, **Review the next message** starts over at step 2.

## The Decision tab: one clear answer per message

After **Analyze**, the review opens on **Decision**:

1. **Recommendation**, which is one of the following:

   | Recommendation | Meaning |
   |---|---|
   | **DELETE AND BLOCK** | Malicious or fraudulent |
   | **KEEP QUARANTINED, VERIFY FIRST** | Warning signs, not proven |
   | **RELEASE AFTER QUICK CHECKS** | Likely a false positive |
   | **BULK / MARKETING** | Not phishing; the user decides |
   | **ANALYSIS INCOMPLETE** | Keep quarantined and read the reason. Supply a missing password or review messages in a multi-message ZIP individually. |

   Each recommendation comes with a **confidence** level, the **type of message** (attachment malware, credential
   phishing, BEC/payment fraud, callback/phone scam, impersonation, bulk, ordinary) and a one-line **why**.
2. **Five questions** in traffic-light colours:
   * Is the sender who they claim to be?
   * Are the attachments dangerous?
   * Do the links lead somewhere dangerous?
   * Does it try to trick someone into acting?
   * What did Microsoft decide?

   The first four come from this tool's own checks. Microsoft's verdict is shown next to them, and the tool says
   plainly whether the two **agree**, **disagree** (a possible false positive) or whether the tool **found more**
   than Microsoft did.
3. **Confirm before releasing:** Yes/No checks that only a person can answer, such as "the recipient expected it" or
   "confirmed by phone using contact details you already had". The recommendation updates as you answer: all Yes
   means release; any No means delete.
4. **What to do in Defender:** numbered steps for the outcome, following Microsoft guidance:
   * False positives go through admin Submissions, which can add a temporary allow.
   * Do not allow-list senders in anti-spam policies, and do not add mail-flow rules that bypass filtering.
   * After a real attack, find other copies of the message and secure any account that was exposed.
5. **Block list:** sender, domain, URLs and file hashes, ready for the Tenant Allow/Block List. Shared services such as
   google.com, web.app and sharepoint.com are never proposed for blocking; only the exact site is listed.
6. **Record decision:** saves the decision, your answers, a note and the full report, and adds a line to
   `Reports\decisions-log.csv` as an audit trail. **Copy block list** on the host requires a completed decision matching the SHA-256 of the single incoming package.
   **Open decisions log** opens the CSV in Notepad. Older rows may contain spreadsheet formulas. Use the text view for logs carried over from earlier versions.

Confidence shows how strongly the offline evidence and Microsoft's verdict agree. No static review can be 100%;
the human checks close that gap.

### When only sender authentication fails

A message that fails SPF, DKIM or DMARC but has no dangerous links, attachments or requests is usually a legitimate
sender with a mis-configured mail set-up, for example a new hosting provider that is not in their SPF record. The
tool treats this as **KEEP QUARANTINED, VERIFY FIRST**, not **DELETE**. Real impersonation is still treated as an
attack: a fake display name, a look-alike domain, spoofing your own domain or one of your executives.

After you confirm the sender through contact details you already have:

1. **Release** the message.
2. On the **Submissions** page, report it to Microsoft as *Should not have been blocked*, and turn on the option to
   allow emails with similar attributes.
3. If the sender writes to you regularly, add the **spoof allow pair** the tool shows (`sender domain, sending
   infrastructure`) under Tenant Allow/Block List > Spoofed senders. This allows only that sender from that
   infrastructure. Do **not** add the whole domain to the anti-spam allowed domains.
4. Tell the sender to fix their SPF, DKIM and DMARC records.

### Organisation settings (recommended)

Launcher > *Organisation settings* > **Edit** opens `config\organization.json`. Fill in:

| Setting | Used for |
|---|---|
| `org_domains` | Your domains, for look-alike detection |
| `vip_display_names` | Executives, for impersonation detection |
| `m365_tenant_names` | Your tenants, to flag documents hosted in other organisations' Microsoft 365 |
| `trusted_partner_domains` | Context in the decision |

## The review window (inside the Sandbox)

The left column is a four-step guide. The current step is open; a finished step folds into one line with a summary
and a **Change** link; later steps are dimmed but you can open any of them at any time.

1. **Choose the package.** Click the downloaded file in the list (the newest is selected for you), or use
   **Browse...** / **Refresh**.
2. **Enter the download password.** The one you typed in Defender > Download message. Attachment passwords are
   optional. The step summary only ever says *Password entered*; the password is never shown in the summary, logged or saved.
3. **Analyze.** Click **Analyze** (or press **Enter** in the password box). A stage tracker shows *Reading file*,
   *Opening package*, *Analysing message n of m* and *Building report* with a running seconds counter, and the
   results area shows a spinner with the current stage. **Cancel** stops the analysis at any time; the message
   stays quarantined.
4. **Decide.** Follow the **Decision** tab, record your decision, then carry it out in Defender on the host.

* **Status chips** confirm *Windows Sandbox / Offline / Host files read-only*. Analysis is disabled if any of
  these is wrong.
* **Verdict banner**: `HIGH RISK`, `SUSPICIOUS`, `NO STRONG INDICATORS` or `INCOMPLETE`, plus what to do next.
* **Tabs**
  * **Summary:** sender, authentication, Microsoft's own verdict, and each attachment with what it contains.
  * **Findings:** every indicator, colour-coded, with its exact location (`Message 1 > Invoice.zip > pay.html`). Hover a cell that is cut off to see its full text; select a row to read the title, severity, full location, ATT&CK ID and details in the box underneath. The severity is always written as a word, never colour alone.
  * **Attachments:** a tree of the whole chain. Click a node for its hashes (SHA256/SHA1/MD5) and findings.
  * **Links:** every URL, defanged and not clickable, with the reason it was flagged.
  * **Headers:** SPF, DKIM, DMARC, compauth, EOP fields (CAT, SFV, SCL, BCL, CIP, CTRY) and Received hops.
  * **Message text:** a plain-text extract. HTML is never rendered.
  * **Full report:** the same report as text.
* **Keyboard:** `Ctrl+1` ... `Ctrl+8` switch tabs, `Ctrl+S` saves the report, `F5` refreshes the file list, `Enter` in the
  password box starts the analysis, `Tab` moves through the controls in reading order. Every control has an accessible
  name for screen readers, and the focused button shows a dark ring.
* **High-DPI screens:** both windows are DPI-aware (100 % to 175 % and above) and never open larger than the screen.
* **Save report** writes `.txt` and `.json` files. By default they also go to the host `Reports` folder, so you
  can look up hashes on the host. Untick that option in the launcher to keep reports inside the Sandbox only.

## What it checks

* **Package:** Defender ZipCrypto and AES-256 ZIPs are decrypted in memory; no 7-Zip needed. A wrong password
  is reported as a wrong password and not mixed up with other errors. The email is found by its content, so the
  ZIP entry does not need an `.eml` name.
* **Sender:** DMARC/SPF/compauth failures, Microsoft verdict (phish/malware/impersonation), Reply-To going to
  another domain, a display name that contains a different email address, brand or role impersonation, and
  look-alike domains of the recipient's domain.
* **Nested attachments within inspection limits:**
  * Archives: password-protected archives are unlocked with passwords written in the email body or ones you
    enter. RAR/7z/ISO/VHD/IMG are flagged.
  * Risky file types: executables, scripts, LNK, OneNote, CHM.
  * Disguised files: double extensions, right-to-left-override names, and content that doesn't match the
    extension.
  * HTML and SVG: HTML smuggling, password forms, redirects, obfuscated script.
  * PDF: auto-run JavaScript, /Launch, embedded files, link lures.
  * Office: VBA macros, remote template injection, DDE, embedded OLE, Equation Editor exploits.
  * Also: RTF objects, attached emails and .msg files.
* **Messages without attachments:**
  * Business email compromise: payment or bank-detail changes (IBANs are checksum-validated), gift cards,
    secrecy, "are you available?" openers, executive names on external or free-webmail senders, Reply-To going to
    free webmail.
  * Callback scams (call this number about a charge).
  * Credential and document-share lures: a brand is mentioned, but no link goes to that brand.
  * Look-alike characters (Cyrillic or Greek letters mixed into Latin text).
  * Trusted-site redirects (google.com/url, bing, LinkedIn) that hide the real destination.
  * Documents hosted in another organisation's Microsoft 365, image-only messages and QR lures.
* **Microsoft verdict decoded** from the official Microsoft documentation: CAT, SFV, SFTY (9.19, 9.20 and 9.25
  first contact), the meaning of every compauth reason code, BCL, and filter bypasses (allow lists, mail-flow rules).
* **DMARC alignment** ([RFC 9989](https://www.rfc-editor.org/rfc/rfc9989)) for SPF and DKIM, ARC, and bulk-sender requirements: SPF, DKIM, DMARC, and RFC 8058
  one-click unsubscribe, as required by Gmail/Yahoo since 2024 and Outlook.com since May 2025.
* **MITRE ATT&CK** technique IDs on findings (T1566.001/.002/.004, T1598.003, T1657, T1027.006 and others).
* **Links:** link text that shows one domain but points to another, IP or punycode hosts, shorteners,
  commonly abused free hosting, links that carry the recipient's own email address, file downloads,
  `javascript:`/`data:`/`file:` links.

## Safety design

* Both profiles disable networking and map the tool folder **read-only**. The default profile also disables clipboard and printer redirection, microphone and camera input, and vGPU. Compatibility mode leaves these settings and Protected Client at their Windows Sandbox defaults. The optional `Reports` mapping gives the Sandbox write access to that folder.
* Size, depth and decompression-ratio limits protect against ZIP bombs. Analysis is stopped after 10 minutes.
* Passwords reach the analyzer through stdin, never through command-line arguments.
* Everything is plain-text PowerShell and one standard-library Python file, so it can be audited.

## Command line (inside the Sandbox)

Run it the same way the review window does. Exit codes: `0` finished, `3` finished but incomplete (for example a wrong
password), `2` the input could not be processed.

```powershell
& C:\Review\Tools\Python\python.exe -I -B -X utf8 C:\Review\app\inspect_eml.py `
    --input "C:\Review\Incoming\Quarantined Messages.zip" --password-stdin
```

Options: `--json-out <file>`, `--text-out <file>`, `--secrets-stdin` (one JSON line:
`{"zip_password": "...", "attachment_passwords": ["..."]}`).

## Troubleshooting

* **Sandbox will not start:** untick *Protected Client*, then try *Compatibility mode*.
* **Review window did not appear:** in the Sandbox, run `C:\Review\Start-Review.cmd`.
* **"Wrong password":** the password is the one typed in Defender's *Download message* dialog. Check Caps Lock,
  or download the message again with a new password.
* **PowerShell scripts blocked by policy:** ask IT security to allow this folder. Do not weaken policy globally.

## Files

| Path | Purpose |
|---|---|
| `Start-Here.cmd` | Host launcher (readiness, install, download, launch, clean up) |
| `Start-Review.cmd` | Fallback that opens the review window inside the Sandbox |
| `app\Launcher.ps1` | Host GUI |
| `app\Enable-Sandbox.ps1` | Elevated helper, only used for the Install button |
| `app\QraUi.ps1` | Shared UI kit for both windows (scaling, colours, fonts, painted controls) |
| `app\QuarantineReview.ps1` | Review GUI (Sandbox) |
| `app\inspect_eml.py` | Offline analyzer (standard library only) |
| `Incoming\` | Put Defender downloads here; nothing else |
| `config\organization.json` | Your domains, executives, tenants, partners (created by the launcher) |
| `Reports\`, `Profiles\`, `Tools\Python\` | Created by the launcher |
