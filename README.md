# RemovePython

Comprehensive PowerShell script for completely removing Python installations and artifacts from Windows systems.

**Version 1.0** — Production-ready with 158+ cleanup locations, safety features, and detailed logging.

## ⚠️ Warning

This is a **destructive utility** that permanently removes Python installations, environments, caches, and configurations. Use with caution.

## Features

- **Comprehensive cleanup** — 158+ locations including:
  - Microsoft Store and traditional Python installations
  - Virtual environments (venv, conda, poetry, pipenv)
  - Package managers (pip, UV, Poetry, PDM, Rye, Hatch, pipx)
  - Registry keys (58+ locations) and file associations
  - Environment variables and app execution aliases
  - Config files, caches, and shortcuts
- **Safety features** — Protected path validation, system restore points, confirmation prompts
- **Progress tracking** — Real-time feedback for all operations
- **Detailed logging** — Comprehensive logs and CSV reports
- **Preview mode** — `-ScanOnly` to see what would be removed

## Requirements

- PowerShell 7.5+
- Windows 10/11
- Administrator privileges

## Quick Start

### Double-click launcher (auto-elevates to admin)

```
Run-RemovePython.bat
```

### PowerShell

```powershell
# Preview mode (safe, no changes)
.\RemovePython.ps1 -ScanOnly

# Remove all Python (creates restore point)
.\RemovePython.ps1

# Skip restore point creation
.\RemovePython.ps1 -CreateBackup:$false

# Faster scan (lower depth)
.\RemovePython.ps1 -MaxScanDepth 5
```

## What Gets Removed

### Python Installations
- Microsoft Store Python apps
- Traditional MSI/EXE installations (Python.org, Anaconda, Miniconda, etc.)

### Package Managers & Tools
- pip, UV, Poetry, PDM, Rye, Hatch, pipx, virtualenv, pipenv
- Jupyter, IPython, JupyterLab
- MyPy, Pytest, Ruff, Pylint, Black, Tox, Nox caches

### Environments & Caches
- Virtual environments (venv, .venv, conda envs, poetry, pipenv)
- Package caches (pip, UV, conda, poetry)
- Temporary files (age-checked for safety)

### System Integration
- 58+ registry keys (installations, file associations, app paths, orphaned entries)
- 21 file type associations (.py, .pyw, .pyc, .pyo, .pyd, etc.)
- Environment variables (PATH, PYTHONPATH, etc.)
- Desktop and Start Menu shortcuts
- App execution aliases

### Configuration Files
- .condarc, .pypirc, pip.ini, .python-version, .pythonrc, .python_history, .pyenvrc

## What Gets Preserved

- IDE/editor installations (PyCharm, VS Code, etc.)
- User scripts outside standard Python locations
- Data files created by Python programs

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

- **Protected paths** — Prevents deletion of system directories (Windows, Program Files\Windows, etc.)
- **System process protection** — Skips system processes (PID ≤ 10)
- **Root drive protection** — Prevents deletion of root drives (C:\, D:\, etc.)
- **User confirmation** — Interactive prompt before making changes (shows detailed warning)
- **System restore point** — Created by default before removal
- **Age-based temp cleanup** — Only removes temp files older than 1 day
- **Smart orphan detection** — Only removes registry entries where installation is gone
- **Comprehensive error handling** — All operations wrapped in try-catch with logging
- **WhatIf support** — Test with `-WhatIf` to preview actions

## Usage Examples

```powershell
# Safe preview - see what would be removed
.\RemovePython.ps1 -ScanOnly

# Remove Python with all safety features (default)
.\RemovePython.ps1

# Skip restore point (faster, but less safe)
.\RemovePython.ps1 -CreateBackup:$false

# Faster scan for large systems
.\RemovePython.ps1 -MaxScanDepth 5

# Skip process checking
.\RemovePython.ps1 -SkipProcessCheck

# Preview with WhatIf
.\RemovePython.ps1 -WhatIf
```

## Output Files

Generated in script directory:

- `Python_Removal_Log_YYYYMMDD_HHMMSS.txt` — Detailed operation log
- `Python_Removal_Report_YYYYMMDD_HHMMSS.csv` — CSV report of all removed items
- `Python_EnvVars_Backup_YYYYMMDD_HHMMSS.json` — Environment variable backup

## Typical Runtime

1-3 minutes depending on:
- Number of Python installations
- Cache sizes (UV: 5+ GB, Conda: 10+ GB, Poetry: 1-3 GB)
- Number of virtual environments
- Disk I/O speed

Progress indicators show real-time status for operations with >1000 items.

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success or preview mode |
| 1 | Errors occurred (check log file) |

## Troubleshooting

**"Access Denied" errors:**
- Run as Administrator
- Close all Python-related applications
- Check for readonly file attributes

**MSI uninstall hangs:**
- Increase `-TimeoutSeconds` parameter
- Check for pending reboots
- Verify Windows Installer service is running

**Process won't stop:**
- Close applications manually via Task Manager
- Check for Python services (use `services.msc`)

**Registry access denied:**
- Confirm administrator rights
- Some keys may be owned by TrustedInstaller

## Development

See [CLAUDE.md](CLAUDE.md) for development guidelines, architecture details, and code standards.

## License

Use at your own risk. The authors are not responsible for data loss or system issues.

**Always:**
- ✅ Create a system restore point (enabled by default)
- ✅ Back up important data
- ✅ Test with `-ScanOnly` first
- ✅ Review the confirmation prompt carefully
- ✅ Close all Python-related applications
- ✅ Save work in Python IDEs/editors

## Version History

**v1.0 (2026-02-28)** — Production-ready release
- 158+ cleanup locations
- 58+ registry locations (including orphan detection)
- 100+ directory/file locations
- 4 virtual environment types
- Comprehensive safety features
- Progress indication and detailed logging
