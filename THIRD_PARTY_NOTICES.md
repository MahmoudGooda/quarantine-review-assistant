# Third-party notices

This project is released under the [MIT license](LICENSE). It does not include or redistribute any third-party code, data or binaries.

## Python (downloaded at runtime, not redistributed)

The launcher downloads the official **Python embeddable package for Windows (64-bit)** from python.org on the user's PC, checks its
SHA256 against the value pinned in `Launcher.ps1`, and unpacks it into `Tools\Python`. It is used only inside the Windows Sandbox to run
`inspect_eml.py`. Python is licensed under the [Python Software Foundation License](https://docs.python.org/3/license.html). The package is
**not** part of this repository or of the release ZIP.

## MITRE ATT&CK®

Findings carry MITRE ATT&CK® technique IDs (for example T1566.001). ATT&CK® is a registered trademark of The MITRE Corporation. The IDs are
used under MITRE's [Terms of Use](https://attack.mitre.org/resources/legal-and-branding/terms-of-use/), with attribution: "(c) The MITRE
Corporation. This work reproduces and is derived from MITRE ATT&CK®. ATT&CK® is a registered trademark of The MITRE Corporation." This project
is not affiliated with or endorsed by MITRE.

## Microsoft documentation

The meanings of the Microsoft header values the tool decodes (CAT, SFV, SFTY, SCL, BCL, IPV, the compauth reason codes and the filter-bypass
values) come from Microsoft's public documentation, which is linked here. No Microsoft text or code is copied.

- [Anti-spam message headers](https://learn.microsoft.com/en-us/defender-office-365/message-headers-eop-mdo)
- [Email authentication in Microsoft 365](https://learn.microsoft.com/en-us/defender-office-365/email-authentication-about)
- [Set up DMARC](https://learn.microsoft.com/en-us/defender-office-365/email-authentication-dmarc-configure)
- [Manage quarantined messages as an admin](https://learn.microsoft.com/en-us/defender-office-365/quarantine-admin-manage-messages-files)
- [Tenant Allow/Block List](https://learn.microsoft.com/en-us/defender-office-365/tenant-allow-block-list-about)
- [Submissions (report a message to Microsoft)](https://learn.microsoft.com/en-us/defender-office-365/submissions-admin)
- [Windows Sandbox](https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-overview)

Microsoft, Microsoft 365, Microsoft Defender, Exchange Online Protection and Windows are trademarks of the Microsoft group of companies.

## Standards

DMARC alignment follows [RFC 9989](https://www.rfc-editor.org/rfc/rfc9989). One-click unsubscribe follows RFC 8058.

## Development-only tools (not shipped)

`pytest` (MIT), `pyzipper` (MIT), Pester (Apache-2.0), PSScriptAnalyzer (MIT) and gitleaks (MIT) are used to test and check the repository.
Developers and CI install them; they are not part of any release.
