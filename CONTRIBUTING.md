# Contributing

Thanks for helping. Two rules come before everything else:

1. **Never attach, paste or commit real quarantined mail**, real attachments, real tenant, domain, company or person names, or screenshots that
   show them. Test data is synthetic: RFC 2606 names (`example.com`, `sender.example`, `*.invalid`), documentation IPs (RFC 5737), and "executables"
   that are a few bytes starting with `MZ` and do nothing. No EICAR, no real samples.
2. **The runtime is the Python standard library plus Windows PowerShell 5.1 and WinForms.** Test-only tools go in `requirements-dev.txt`.

## Dev setup (Windows, tested versions)

```powershell
# 1. Python (3.12 to 3.14 work; CI runs all three) and the test packages, in a git-ignored virtual environment
py -3.13 -m venv .venv
.\.venv\Scripts\python -m pip install -r requirements-dev.txt        # pytest, pyzipper

# 2. PowerShell test tools (current user only; tested with Pester 5.7.1 and PSScriptAnalyzer 1.25.0)
Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser -Force -SkipPublisherCheck
Install-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -Scope CurrentUser -Force

# 3. Secret scanning (tested with gitleaks 8.30.1)
winget install --id Gitleaks.Gitleaks -e
```

On Linux or macOS only step 1 applies (`python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt`). The analyzer is plain Python and
its tests run everywhere; the GUI and the Pester tests need Windows.

## Run the checks

```powershell
.\.venv\Scripts\python -m pytest tests -q                       # builds tests/.samples and runs the analyzer through its CLI
$env:Path = (Resolve-Path .venv\Scripts).Path + ';' + $env:Path # Pester uses python to generate screenshot fixtures
Import-Module Pester -RequiredVersion 5.7.1
Invoke-Pester -Path tests\powershell -Output Detailed
foreach ($dir in 'src', 'tools', 'tests') {
    Invoke-ScriptAnalyzer -Path $dir -Recurse -Severity Error, Warning
}
gitleaks detect --source . --no-git                             # or: gitleaks detect --source . (with history)
.\tools\build-release.ps1                                       # writes dist\QuarantineReviewAssistant-<version>.zip and its .sha256
```

`python tests/make_samples.py` writes the synthetic packages to `tests/.samples/` (ignored by git) if you want to open them in the Sandbox.

## Rules for changes

- **Line endings and encoding:** `.cmd` and `.ps1` are CRLF, and the `.ps1` files under `src/SecurityReview/app` keep their UTF-8 BOM (Windows PowerShell
  5.1 reads a BOM-less file as ANSI). `.py` and `.md` are LF. `.gitattributes` and `.editorconfig` enforce this and a Pester test checks it.
- **Do not rename runtime files or move folders** under `src/SecurityReview`: the launcher, the Sandbox profile and the `C:\Review\...` paths depend on them.
- **Every release** updates the “Toward a triage kit” roadmap table in the root README, the top release entry in
  `CHANGELOG.md` and the version number in the same commit. Set `$AppVersion` in `Launcher.ps1` and
  `QuarantineReview.ps1`, `VERSION` in `inspect_eml.py` and the titles of both READMEs. Pester checks the version numbers.
- **Analysis changes** need a sample in `tests/make_samples.py` and an expectation in `tests/expected/`. Say in the pull request why the new
  recommendation is right.
- **GUI changes:** keep contrast at 4.5:1 or better, give every control an `AccessibleName`, keep the severity word in every row (never colour alone),
  and test at 100 % and 150 % scaling. Scaling rule: a control that is part of the form when `ResumeLayout()` runs is scaled by `AutoScaleMode`, so write
  its size in plain pixels; anything created later, and list-view column widths, tab padding and tree item height, use `S()`. Never both.
- A pull request that changes behaviour needs a line in `CHANGELOG.md`.

## Reporting bugs

Use the issue templates. Describe the message in words or attach a synthetic sample. For security problems, see [SECURITY.md](SECURITY.md).
