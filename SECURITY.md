# Security policy

## Reporting a vulnerability

Please report security problems **privately** through GitHub Security Advisories:
**Security tab > Report a vulnerability** on this repository. Do not open a public issue for a vulnerability.

Include what you did, what you expected and what happened, the version (shown in the window title and in the report), and
the Windows build. You will get an answer within a few days.

## Never send real quarantined mail

Do **not** attach real quarantined messages, real attachments, real tenant or company names, passwords or screenshots that show
them to an issue, an advisory, a pull request or an email. If you need to show a problem, build a synthetic sample with
`tests/make_samples.py` (it uses only RFC 2606 names such as `example.com`, `sender.example` and `*.invalid`) or describe the
message in words. Anything real that is posted by mistake will be deleted, and you should treat it as disclosed.

## What is in scope

- A way for a crafted message, archive or attachment to make the tool execute, render, extract, fetch or write something it should not.
- A way to leak a password, a report or a host file out of the Sandbox.
- A way to weaken the Sandbox profile (networking, clipboard, read-only folder mapping) or to bypass the size, depth and time limits.
- A wrong "safe" signal: the tool must never present a message as safe.

Out of scope: the tool is not an antivirus and does not claim to detect every threat. A missed detection is a bug report, not a vulnerability.

## Supported versions

| Version | Supported |
|---|---|
| 2.2.x | Yes |
| < 2.2 | No |
