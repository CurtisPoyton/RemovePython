# RemovePython - Claude Instructions

## Project Overview

**RemovePython** is a PowerShell script that removes Python installations and artefacts from Windows.
It is a **destructive utility** and requires administrator privileges.

**Version:** 2.0 | **Platform:** Windows 10/11 | **PowerShell:** 7.5+

**Coverage:** 200+ cleanup locations (90+ registry keys, 60+ directory globs, 4 virtual environment
types, 6 PowerShell profiles, the Windows Python Launcher binaries)

---

## Project Structure

```
RemovePython/
├── RemovePython.ps1              # Main script (~3160 lines, 74 functions)
├── RemovePython.Tests.ps1        # Pester suite (~2150 lines, 348 tests)
├── Run-RemovePython.bat          # Launcher with auto-elevation and exit-code propagation
├── PSScriptAnalyzerSettings.psd1 # Lint configuration; the quality gate for this repo
├── CLAUDE.md                     # This file
├── README.md                     # User documentation
└── *.md, *.txt, *.csv, *.json    # Generated logs and reports (git-ignored)
```

Each run emits four artefacts sharing one timestamp: a Markdown review report, a plain-text log, a
CSV of findings, and an environment backup. The Markdown report is the one to read when diagnosing a
run.

---

## Safety Guidelines

### Never do

- Weaken `Test-PathSafe` or remove entries from `$script:protectedPath`. That set includes the
  user's **Documents** folder in all three of its forms — the shell-reported location (which follows
  OneDrive redirection), `%USERPROFILE%\Documents`, and the legacy `My Documents` junction. Documents
  holds live project work, including virtual environments this script would otherwise match.
- Add a filesystem write or delete that does not consult `Test-PathSafe` first. `Remove-ProfileBlock`
  edits and deletes files directly rather than through the removal primitives, so it calls the gate
  itself; any new phase in that shape must do the same.
- Broaden the launcher carve-out in `Test-PathSafe`. It matches `$env:WINDIR\py.exe` and
  `$env:WINDIR\pyw.exe` by **exact, case-insensitive full-path equality only** — never a prefix,
  never a glob, never a directory. `Remove-ItemSafely` and `Remove-FileSafely` route every
  filesystem deletion through `Test-PathSafe`, so widening it widens everything.
- Skip path validation, disable the restore point, drop `-WhatIf` support, or remove the
  administrator requirement.
- Hardcode user paths. Everything is built from environment variables in
  `Initialize-Configuration`, which hard-fails through `Test-RequiredEnvironment` if any required
  variable is empty.
- Write `PATH` with `[Environment]::SetEnvironmentVariable`. That API always writes `REG_SZ` and
  silently converts the machine `PATH` from `REG_EXPAND_SZ`, permanently baking in expanded values.
  Use `Get-EnvironmentEntry` / `Set-EnvironmentEntry`, which preserve the registry value kind.

### Always do

- Test with `-ScanOnly` before making changes, and `-WhatIf` before trusting a new code path.
- Route deletions through `Remove-ItemSafely`, `Remove-FileSafely` or `Remove-RegistryKeySet`.
- Record every discovered item with `Add-Finding` and set `.Status` on the returned object to
  `Removed`, `Failed` or `Skipped`. All counters, both reports and the exit code derive from
  findings, so an unrecorded operation is invisible to every one of them.
- Set `.Reason` whenever the status is not `Removed`. Use `Write-RemovalFailure` for failures and
  `Add-SkippedFinding` for skips; both fill it in for you. A `Skipped` or `Failed` row with an empty
  reason is a defect — the review report exists to answer "why".
- Call `Add-ManualAction` whenever the run leaves something for the user to finish by hand.
- Test a `List` for emptiness with `$null -eq $list`, never `-not $list`. An empty
  `List[T]` is falsy in PowerShell, which silently disabled the whole blocked-path record once.

---

## Code Standards

- Indentation 4 spaces; maximum line length 120; opening brace on the same line; `else`/`catch` on
  their own line after the closing brace.
- Functions use approved Verb-Noun pairs with singular nouns. `Write-Log` is not available — it
  collides with a built-in cmdlet, hence `Write-LogEntry`.
- Single quotes for constant strings; double quotes only where interpolation is required.
- Every parameter is typed. Avoid untyped or `[object]` parameters.
- The script file must remain pure ASCII.

### Required attributes

```powershell
#Requires -Version 7.5
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Remove')]
```

Any function whose verb is `New`, `Set`, `Remove`, `Start`, `Stop`, `Restart`, `Reset` or `Update`
must declare `SupportsShouldProcess` and consult `$PSCmdlet.ShouldProcess` before acting.

### Error handling

Destructive operations wrap the action in `try`/`catch`, set the finding status, and log through
`Write-RemovalFailure`. A per-item catch-all is deliberate: one item's failure must never abandon
the remaining cleanup locations. It is not a swallowed exception — the concrete exception type and
message are always logged and the item is counted as failed.

---

## Tagged Logging

Every log statement goes through `Write-LogEntry -Tag <tag> -Message <text> [-Level <level>]` and is
emitted as `[tag] message`. The tag is validated case-sensitively against `^[a-z][a-z0-9_]*$`.

**Levels:** `Section`, `Found`, `Info` (default), `Success`, `Warn`, `Error`. The level sets the
console colour; it is not part of the message.

**Tags in use:** `alias`, `appx`, `config_file`, `directory`, `env_var`, `launcher`, `main`, `path`,
`preflight`, `process`, `profile`, `registry`, `report`, `restore_point`, `safety`, `shortcut`,
`temp_cache`, `uninstall`, `venv`, `verify`.

Reuse an existing tag rather than inventing a near-duplicate. Messages are lower case and lead with
the verb or outcome (`found: <x>`, `removed: <x>`, `remove failed: <x> - <type>: <detail>`).

---

## Development Requirements

- Fix any error found along the way, including pre-existing ones. Hard fail on fixable errors.
- Remove dead code outright. Wire up unwired code where it benefits the script; otherwise delete it.
- No backward-compatibility shims, historical comments, changelog entries, or comments that restate
  what the code already says. Comments explain *why*, and only where the reason is not obvious.
- Use Australian English in user-facing text.

---

## Architecture

### Execution flow

`Initialize-Configuration` populates all script-scoped state, then:

1. Open the log file. When the log directory is not writable the run falls back to `$env:TEMP` and
   **moves the review, CSV and backup with it** — leaving them behind would put the log in one
   directory while every other artefact failed to write in the directory that was just refused. The
   redirection is recorded in `$script:state.LogFallbackFrom` and warned about after the banner.
2. `-RestoreEnvironment` short-circuits to `Restore-EnvironmentVariable` and exits.
3. `Test-RequiredEnvironment` — hard fails with exit 5 if a required variable is empty.
4. `Test-DiskSpace`, whose result warns that restore point creation is likely to fail, then
   `Confirm-Removal` unless `-Force`, `-ScanOnly` or `-WhatIf`.
5. Fourteen phases run in order behind a progress bar (see below).
6. `Test-PostRemoval` (skipped for `-ScanOnly` and `-WhatIf`), `New-Report`, `Write-Summary`.
7. `Get-RunExitCode` determines the exit status.
8. A reboot is advised only on evidence — a failed removal, a terminated process, or a queued
   `PendingFileRenameOperations`. Advising one unconditionally trains the reader to ignore it.

`Test-PostRemoval` checks registered installations, `python`/`py` on PATH, the launcher binaries,
registry keys, environment variables and install directories. The installation check is what turns a
surviving Add/Remove Programs entry into exit code 3; without it a run can report "the system is
Python-free" while Python is still listed in Programs and Features.

### Phases

`New-RestorePoint` → `Test-RunningProcess` → `Uninstall-StorePython` →
`Uninstall-TraditionalPython` → `Remove-EnvironmentVariable` → `Remove-PythonDirectory` →
`Remove-PythonConfigFile` → `Remove-PythonShortcut` → `Remove-PythonTempFile` →
`Remove-VirtualEnvironment` → `Remove-AppExecutionAlias` → `Remove-PythonLauncher` →
`Clear-Registry` → `Remove-ProfileBlock`

Because Documents is protected, the four per-user PowerShell profile locations
(`Documents\PowerShell` and `Documents\WindowsPowerShell`) are reported as `Skipped` rather than
edited. Only the two machine-wide profiles under `%ProgramFiles%\PowerShell\7` are still in scope.
Virtual environments found beneath Documents are likewise reported and skipped, never removed.

Every phase opens with `Write-Section` before it checks whether it is disabled, so a skipped phase
still appears in the log rather than vanishing from it, and closes with a `[main] phase '<name>'
completed in <duration> with <n> finding(s)` line. A phase that costs minutes is visible in the log
itself, not only in the review report's timing table.

Uninstalling and orphan-sweeping are two halves of one job, split across the `Installations` and
`Registry` phases. An Add/Remove Programs entry with nothing to run is *not* a manual action: it is
recorded `Skipped` with a reason naming the registry phase, and `Clear-OrphanedUninstallEntry` then
deletes the key. Raising a manual action there instead strands the entry, because nothing else in the
run removes it and `Test-PostRemoval` used not to look.

### Key functions

| Function | Purpose | Notes |
|----------|---------|-------|
| `Initialize-Configuration` | Builds all script state from parameters and environment | Called by the script and by the test suite, so tests cannot drift from the script |
| `Test-PathSafe` | Gate for every filesystem write and deletion | CRITICAL. Blocks root drives, Windows locations and the whole Documents tree; allows the two launcher binaries by exact match |
| `Remove-ItemSafely` | Directory and reparse-point removal | Accepts a pre-computed `-Statistic` to avoid re-walking |
| `Remove-FileSafely` | Single-file removal | |
| `Remove-RegistryKeySet` | Bulk registry key removal | Used by all four registry key groups |
| `Write-RemovalFailure` | Uniform failure logging and status | Names the concrete exception type |
| `Get-DirectoryStatistic` | Size and file count in one pass | Skips reparse points |
| `Get-DirectoryStatisticSet` | Parallel batch sizing | Falls back to a direct call for a single path |
| `Get-ScanRootDirectory` | Top-level scan roots | Excludes junctions so linked trees are not counted twice |
| `Get-EnvironmentEntry` / `Set-EnvironmentEntry` / `Remove-EnvironmentEntry` | Registry-native environment access | Preserves `REG_EXPAND_SZ` and reads unexpanded |
| `Send-SettingChange` | Broadcasts `WM_SETTINGCHANGE` | Registry writes are otherwise invisible to running processes |
| `Backup-EnvironmentVariable` / `Restore-EnvironmentVariable` | Environment backup and replay | Backup records the value kind per entry |
| `Test-UninstallerTrust` | Authenticode check before running a vendor uninstaller | Refuses unsigned executables recorded under HKCU, which is writable without elevation |
| `Test-InstallationPresent` | Orphan detection | Reports *present* when Windows Installer owns the registration, so a live MSI product is never stranded. An entry with no install location, no uninstall command and no `WindowsInstaller` flag is a stub and is reported orphaned — nothing can uninstall it, so deleting the key is the only cleanup there is |
| `Test-RegistryKeyPresent` | Registry existence test | `Test-Path` costs ~350ms per *missing* key under `HKLM:\SOFTWARE\Classes`, which was the whole cost of the registry phase; the .NET call answers identically in under a millisecond. Falls back to the provider for anything it cannot resolve |
| `Test-PendingReboot` | Reads `PendingFileRenameOperations` | The run only advises a reboot on evidence |
| `Format-Duration` | `12.4s` / `2m 1.6s` | Rounds before splitting; `[int]` on total minutes rounds *up*, which rendered 119.99s as `2m 60s` |
| `Get-RemovalDetail` | File count, size and elapsed for a large removal | Empty below `LargeDirectoryThreshold`, so small deletions stay quiet |
| `Sync-ProcessPath` | Rebuilds `$env:Path` from the registry before verification | Without it, verification reads the stale launch-time PATH and reports false failures |
| `Write-MarkdownReport` | Builds the review report | Called from `finally`, so it survives a crash and runs under `-WhatIf`. Uses `Write-` rather than `New-` deliberately: a `New-` verb would demand `SupportsShouldProcess`, which would suppress the report in exactly the preview mode it is most useful for |
| `ConvertTo-MarkdownCell` | Escapes and truncates a table cell | Pipes and newlines in a program name or exception message would otherwise break the table |
| `Add-BlockedPath` | Records what the safety gate refused, deduplicated | Feeds the report's "Paths refused" section |

The script never prunes its own output. The reference implementation this report style follows does,
but `$PSScriptRoot` is inside Documents here and that tree is protected, so a retention sweep would
be dead code.

### Concurrency

The host is assumed to be many-core with fast storage. `MaxParallelism` is
`[Math]::Clamp([Environment]::ProcessorCount, 2, 32)`.

Two IO-bound stages run in parallel runspaces:

- `Remove-VirtualEnvironment` scans each top-level profile subtree concurrently.
- `Get-DirectoryStatisticSet` sizes candidate directories concurrently before removal.

Everything else is deliberately serial: uninstallers must not run concurrently, registry deletions
are order-dependent, and findings are appended from a single thread. Do not parallelise them.

`ForEach-Object -Parallel` blocks must reference outer variables with `$using:` and must avoid a
trailing multi-line pipeline — `PSUseConsistentIndentation` mis-models that shape and cascades a
false indentation error across the rest of the file.

---

## Parameters

| Parameter | Set | Default | Purpose |
|-----------|-----|---------|---------|
| `-ScanOnly` | Remove | False | Preview mode; nothing is changed |
| `-SkipRestorePoint` | Remove | False | Do not create a system restore point |
| `-SkipProcessCheck` | Remove | False | Do not look for running Python processes |
| `-SkipDiskCheck` | Remove | False | Do not validate free disk space |
| `-IncludeNetworkDrives` | Remove | False | Allow removal of network paths |
| `-Force` | Remove | False | Skip the confirmation prompt; required for unattended runs |
| `-MinFreeDiskSpaceGB` | Remove | 5 | Free-space warning threshold |
| `-TimeoutSeconds` | Remove | 300 | Uninstaller timeout |
| `-MaxScanDepth` | Remove | 8 | Virtual environment scan depth (3-15) |
| `-RestoreEnvironment` | Restore | — | Replay an environment backup, then exit |
| `-LogDirectory` | Both | `$PSScriptRoot` | Destination for log, report and backup |

## Exit codes

`0` clean · `1` critical failure · `2` operations failed · `3` components remain ·
`4` cancelled at the prompt · `5` pre-flight validation failed

---

## Adding cleanup locations

All detection data lives in `Initialize-Configuration`. Build paths with `Join-Path` and an
environment variable; never concatenate a literal user path.

| Target | Add to |
|--------|--------|
| Directories | `$script:directoryGlob` (or `$script:coreInstallGlob` for an install root, which also feeds verification) |
| Configuration files | `$script:configFile` |
| Registry keys | `$script:coreRegistryKey` |
| File extensions | `$script:fileExtension` — automatically expands into association and UserChoice keys |
| ProgID handlers | `$script:fileHandler` |
| Environment variables | `$script:pythonVariable` |
| Process names | `$script:pattern.ProcessName` — anchor every alternation; an unanchored `^mypy` also matches `mypythonapp` and this script terminates what it matches |
| Installation names | `$script:pattern.InstallInclude` — use `Name\d*` so `Anaconda3` matches; a bare `\bAnaconda\b` does not |

---

## Testing

```powershell
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1 -ErrorAction Stop
Invoke-Formatter -ScriptDefinition (Get-Content ./RemovePython.ps1 -Raw) -Settings ./PSScriptAnalyzerSettings.psd1
Invoke-Pester -Path ./RemovePython.Tests.ps1
.\RemovePython.ps1 -ScanOnly
```

The settings file is the gate, not the default rule set. `Invoke-ScriptAnalyzer` without `-Settings`
skips the opt-in formatting rules and reports a clean file that is not.

`-ErrorAction Stop` is not optional. PSScriptAnalyzer 1.25.0 fails in roughly half of fresh sessions
with `NullReferenceException` or `The term 'Get-Command' is not recognized`, its rule runspaces
having started without the default modules. **A failed run emits no findings**, so empty output alone
does not mean clean — the run must also not have raised. Re-run until one completes; the flakiness is
per-session and unrelated to the code under analysis.

The suite loads functions out of `RemovePython.ps1` by AST parsing and calls
`Initialize-Configuration`, so it never executes the script and never duplicates its data. Tests
confine writes to `TestDrive`, `HKCU:\Software\RemovePythonPesterScratch` and a single scratch
environment value, all removed in `AfterAll`.

Note that `TestDrive` resolves under `AppData\Local`, which the production scan-exclusion pattern
rejects wholesale; tests exercising that pattern swap in a benign one and restore it.

### Pre-commit checklist

- [ ] Analyzer returns zero findings with the settings file
- [ ] `Invoke-Formatter` is a no-op
- [ ] Full Pester suite passes
- [ ] `-ScanOnly` and `-WhatIf` verified against a real machine, with state unchanged afterwards
- [ ] New operations record a finding and set its status
- [ ] Documentation updated

---

## Git Workflow

```
<type>: <subject>

<body>

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
```

**Types:** feat, fix, refactor, docs, test, chore

Track `*.ps1`, `*.bat`, `*.psd1`, `*.md`. Ignore generated `*.txt`, `*.csv`, `*.json`.

---

## Troubleshooting

**Access denied** — run as administrator, close Python processes, check file attributes.
**MSI hangs** — raise `-TimeoutSeconds`, check for a pending reboot, verify the Windows Installer service.
**Registry denied** — some keys are owned by TrustedInstaller and cannot be removed under normal elevation.
**Verification fails on py.exe** — the launcher MSI did not uninstall; the log prints the exact manual command.

**Preserved:** IDE installations (PyCharm, VS Code), user scripts outside standard Python locations,
data files, and the Poetry / PDM / Rye / Hatch / pipx / Jupyter binaries.
