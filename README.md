# RemovePython

PowerShell script for completely removing Python installations and artifacts from Windows systems.

**Version 1.1** | **200+ cleanup locations** | **Production-ready**

## Warning

**Destructive utility** - Permanently removes Python installations, environments, caches, and configurations.

## Features

- **Comprehensive cleanup** - Microsoft Store & traditional installations, virtual environments (4 types), package managers, 90+ registry keys (HKCU + HKLM), environment variables, config files, caches, shortcuts, PowerShell profiles
- **Safety** - Protected path validation, system restore points, confirmation prompts, WhatIf/ScanOnly support
- **Progress & logging** - Real-time progress bar, detailed logs, CSV reports

## Requirements

PowerShell 7.5+ | Windows 10/11 | Administrator privileges

## Quick Start

```powershell
# Preview mode (no changes)
.\RemovePython.ps1 -ScanOnly

# Remove all Python
.\RemovePython.ps1

# Or use launcher (auto-elevates)
Run-RemovePython.bat
```

## What Gets Removed

- **Installations** - Microsoft Store & traditional (Python.org, Anaconda, Miniconda)
- **Package managers** - pip, UV, Poetry, PDM, Rye, Hatch, pipx, virtualenv, pipenv
- **Development tools** - Jupyter, IPython, MyPy, Pytest, Ruff, Pylint, Black, Tox, Nox
- **Environments** - venv, conda, poetry, pipenv
- **Caches** - pip, UV, conda, poetry, temp files (age-checked)
- **Registry** - 90+ keys (HKCU + HKLM), file associations, UserChoice, app paths, shared DLLs
- **System** - Environment variables, shortcuts, aliases
- **Config files** - .condarc, .pypirc, pip.ini, .python-version, etc.
- **PowerShell profiles** - Conda init blocks (auto-removed with backup), other Python lines (warned)

**Preserved:** IDEs (PyCharm, VS Code), user scripts outside Python locations, data files. Tool binaries (Poetry, PDM, Rye, Hatch, pipx, Jupyter) are preserved but require Python reinstall to function.

## Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-ScanOnly` | Switch | False | Preview mode - no changes made |
| `-CreateBackup` | Bool | True | Create system restore point before removal |
| `-SkipProcessCheck` | Switch | False | Skip checking for running Python processes |
| `-SkipDiskCheck` | Switch | False | Skip disk space validation |
| `-IncludeNetworkDrives` | Switch | False | Allow network path operations (use with caution) |
| `-MinFreeDiskSpaceGB` | Int | 5 | Minimum free disk space required (GB) |
| `-TimeoutSeconds` | Int | 300 | Timeout for uninstall operations (seconds) |
| `-MaxScanDepth` | Int | 8 | Maximum depth for virtual environment scan (3-15) |

## Safety Features

- Protected paths (Windows, Program Files), root drives, system processes (PID ≤ 10)
- User confirmation prompt with detailed warning
- System restore point created by default
- Age-based temp cleanup (>1 day old)
- Smart orphan detection (registry — handles paths with spaces correctly)
- Comprehensive error handling and logging
- WhatIf/ScanOnly support for preview
- PSScriptAnalyzer clean (0 violations across all rules)

## Usage Examples

```powershell
.\RemovePython.ps1 -ScanOnly              # Preview mode
.\RemovePython.ps1                        # Full removal
.\RemovePython.ps1 -CreateBackup:$false   # Skip restore point
.\RemovePython.ps1 -MaxScanDepth 5        # Faster scan
.\RemovePython.ps1 -WhatIf                # Preview with WhatIf
```

## Output Files

- `Python_Removal_Log_*.txt` - Detailed operation log
- `Python_Removal_Report_*.csv` - CSV report of removed items
- `Python_EnvVars_Backup_*.json` - Environment variable backup

**Runtime:** 1-3 minutes (varies by installations, cache size, venv count)
**Exit codes:** 0 (success/preview), 1 (errors - check log)

## Troubleshooting

**Access Denied** - Run as admin, close Python apps, check file attributes
**MSI hangs** - Increase `-TimeoutSeconds`, check pending reboots, verify Windows Installer service
**Process won't stop** - Use Task Manager or services.msc
**Registry denied** - Confirm admin rights (some keys may be TrustedInstaller-owned)

## Development

See [CLAUDE.md](CLAUDE.md) for development guidelines and architecture details.

## License

**Use at your own risk.** Always create a system restore point (enabled by default), backup data, test with `-ScanOnly` first, and close Python applications before running.
