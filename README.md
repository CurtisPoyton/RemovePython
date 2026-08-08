# RemovePython

PowerShell script that completely removes Python installations and artefacts from Windows.

**Version 2.0** | **200+ cleanup locations** | **PowerShell 7.5+** | **Windows 10/11**

## Warning

This is a destructive utility. It permanently removes Python installations, environments, caches and
configuration. Run it with `-ScanOnly` first.

## Quick start

```powershell
.\RemovePython.ps1 -ScanOnly     # report what would be removed, change nothing
.\RemovePython.ps1               # remove, with a confirmation prompt
.\RemovePython.ps1 -Force        # remove unattended
Run-RemovePython.bat             # launcher; elevates automatically
```

## Features

- **Comprehensive cleanup** — Microsoft Store packages (including provisioned), traditional
  installations, four virtual environment types, package caches, 90+ registry keys across HKCU and
  HKLM, environment variables, configuration files, shortcuts, app execution aliases, the Windows
  Python Launcher, and conda blocks in PowerShell profiles.
- **PATH handled through the registry** — `REG_EXPAND_SZ` keeps its type, so unexpanded tokens such
  as `%SystemRoot%` survive. Empty segments are compacted. Running processes are notified with
  `WM_SETTINGCHANGE`.
- **Reversible environment changes** — every run writes a JSON backup that `-RestoreEnvironment`
  replays, restoring each value with its original registry type.
- **Safety** — protected-path validation, a system restore point by default, a confirmation prompt,
  and full `-WhatIf` support.
- **Parallel scanning** — profile subtrees and directory sizing run across up to 32 runspaces.
- **Reporting** — tagged console output, a timestamped log, and a CSV recording every item with its
  final status.

## What gets removed

- **Installations** — Microsoft Store, Python.org, Anaconda, Miniconda, Mambaforge, Miniforge
- **Environments** — venv, conda, Poetry, Pipenv
- **Caches** — pip, UV, and temporary files older than one day
- **Registry** — installation keys, file associations, ProgID handlers, App Paths, UserChoice
  entries, orphaned uninstall entries, orphaned shared DLL references
- **System** — environment variables, PATH entries, desktop and Start Menu shortcuts, app execution
  aliases, `py.exe` and `pyw.exe`
- **Configuration** — `.condarc`, `.pypirc`, `pip.ini`, `.python-version`, and others
- **PowerShell profiles** — conda initialisation blocks in the machine-wide profiles under
  `%ProgramFiles%\PowerShell\7`, removed after backing the profile up. Per-user profiles live in
  Documents and are therefore skipped. Other Python-related lines are reported for manual review
  rather than edited.

**Preserved:** IDEs such as PyCharm and VS Code, user scripts outside standard Python locations, and
the Poetry, PDM, Rye, Hatch, pipx and Jupyter binaries. Those tools will need a Python reinstall
before they work again.

## Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-ScanOnly` | Switch | False | Preview mode; nothing is changed |
| `-SkipRestorePoint` | Switch | False | Do not create a system restore point |
| `-SkipProcessCheck` | Switch | False | Do not look for running Python processes |
| `-SkipDiskCheck` | Switch | False | Do not validate free disk space |
| `-IncludeNetworkDrives` | Switch | False | Allow removal of network paths |
| `-Force` | Switch | False | Skip the confirmation prompt |
| `-MinFreeDiskSpaceGB` | Int | 5 | Free-space warning threshold |
| `-TimeoutSeconds` | Int | 300 | Uninstaller timeout |
| `-MaxScanDepth` | Int | 8 | Virtual environment scan depth (3-15) |
| `-RestoreEnvironment` | String | — | Replay an environment backup, then exit |
| `-LogDirectory` | String | Script directory | Destination for the log, report and backup |

`-ScanOnly` and `-RestoreEnvironment` are mutually exclusive.

## Examples

```powershell
.\RemovePython.ps1 -ScanOnly                       # preview
.\RemovePython.ps1 -WhatIf                         # show every action without doing it
.\RemovePython.ps1 -Force -SkipRestorePoint        # unattended, no restore point
.\RemovePython.ps1 -MaxScanDepth 5                 # shallower, faster scan
.\RemovePython.ps1 -LogDirectory C:\Logs           # write output elsewhere
.\RemovePython.ps1 -RestoreEnvironment .\Python_EnvVars_Backup_20260808_101500.json
```

## Output

| File | Contents |
|------|----------|
| `Python_Removal_Log_*.md` | Review report — read this one first |
| `Python_Removal_Log_*.txt` | Timestamped, tagged log of every action |
| `Python_Removal_Report_*.csv` | Every item found, with type, path, size, status and reason |
| `Python_EnvVars_Backup_*.json` | Environment variables and PATH, with registry value kinds |

The Markdown report is written on every run — including `-WhatIf`, `-ScanOnly` and after a crash,
since that is when it is most useful. It contains:

- **Summary** — mode, exit code and its meaning, counts, reclaimable size versus size left in place
- **Configuration** and **Environment** — every parameter and host detail, so a run is reproducible
- **Phase timings** — duration and item count for each of the fourteen phases
- **Findings by type** — found / removed / failed / skipped / size, broken down
- **Failures** — each one with its path and the concrete exception type and message
- **Skipped** and **Paths refused by the safety gate** — what was left alone and exactly why
- **Verification**, **Manual action required** — anything still needing your attention, with commands
- **Console output** — the full tagged transcript in a collapsed block

Old reports are never pruned automatically; the script does not delete its own output.

Console output is tagged by subsystem, for example
`[registry] removed: HKLM:\Software\Python`. Colour is suppressed when output is redirected or when
`NO_COLOR` is set.

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | Completed with no failures |
| 1 | Critical failure; the run was abandoned |
| 2 | Completed, but one or more operations failed |
| 3 | Completed, but verification found remaining components |
| 4 | Cancelled at the confirmation prompt |
| 5 | Pre-flight validation failed; nothing was changed |

## Safety

- **Your Documents folder is never touched.** It is protected in all three of its forms: the
  shell-reported location (following OneDrive redirection), `%USERPROFILE%\Documents`, and the legacy
  `My Documents` junction. Virtual environments and PowerShell profiles found there are reported as
  `Skipped` in the log and CSV, never removed.
- Protected paths, root drives and network paths are refused. The only exception is `py.exe` and
  `pyw.exe` in the Windows directory, matched by exact full path.
- Pre-flight validation refuses to run if any required environment variable is empty, which would
  otherwise let a path collapse to a drive root.
- System processes (PID ≤ 10) are never terminated.
- Vendor uninstallers recorded under HKCU are Authenticode-checked before being run elevated; that
  registry location is writable without elevation.
- Verification rebuilds the process PATH from the registry, so a successful cleanup is not reported
  as a failure.

## Troubleshooting

**Access denied** — run as administrator and close Python applications.
**MSI hangs** — increase `-TimeoutSeconds`, check for a pending reboot, verify the Windows Installer service.
**Registry denied** — some keys are owned by TrustedInstaller.
**Verification reports `py.exe`** — the launcher's own uninstaller failed; the log prints the exact
command to remove it manually.

**Runtime:** roughly 1-3 minutes, dominated by cache size and virtual environment count.

## Development

See [CLAUDE.md](CLAUDE.md). The quality gate is
`Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1`, which must
return nothing, plus the Pester suite in `RemovePython.Tests.ps1`.

## Licence

Use at your own risk. Create a restore point, back up your data, and test with `-ScanOnly` first.
