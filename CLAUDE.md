# RemovePython - Claude Instructions

## Project Overview

**RemovePython** is a PowerShell script for completely removing Python installations and artifacts from Windows systems. This is a **destructive utility** requiring administrator privileges.

**Version:** 1.1 | **Platform:** Windows 10/11 | **PowerShell:** 7.5+ | **Status:** Production-ready

**Coverage:** 200+ cleanup locations (90+ registry, 108+ directories/files, 4 virtual environment types, 6 PowerShell profiles)

---

## Project Structure

```
RemovePython/
├── RemovePython.ps1              # Main PowerShell script (~2100 lines)
├── Run-RemovePython.bat          # Batch launcher with auto-elevation
├── CLAUDE.md                     # This file
├── FINAL_SUMMARY.md              # Complete enhancement summary
├── REGISTRY_CLEANUP.md           # Registry cleanup documentation
├── DIRECTORY_CLEANUP.md          # Directory cleanup documentation
├── FIXES_APPLIED.md              # Bug fixes documentation
├── IMPROVEMENTS.md               # Log analysis and improvements
└── *.txt, *.csv, *.json         # Generated log/report files (not tracked)
```

### Core Files

- **`RemovePython.ps1`** - Main script (~2100 lines). PSScriptAnalyzer clean (0 violations, all rules). Never modify without testing.
- **`Run-RemovePython.bat`** - Auto-elevation launcher. Validates pwsh.exe before elevation.
- **Documentation** - FINAL_SUMMARY.md, REGISTRY_CLEANUP.md, DIRECTORY_CLEANUP.md, FIXES_APPLIED.md, IMPROVEMENTS.md

---

## Safety Guidelines

### Never Do
- Disable or bypass `Test-PathSafe` function
- Remove paths from `$script:protectedPaths` array
- Allow deletion of root drives or skip path validation
- Disable system restore point, `-WhatIf` support, or admin requirement
- Use hardcoded user paths (always use environment variables)

### Always Do
- Test with `-ScanOnly` before making changes
- Maintain try-catch blocks and increment counters (ItemsRemoved/ItemsFailed)
- Use environment variables for paths (`$env:USERPROFILE`, `$env:APPDATA`)
- Show progress for operations >1000 items
- Run validation checks before committing

---

## Code Standards

### PowerShell Conventions
- Indentation: 4 spaces | Line length: 120 chars max | Braces: opening on same line
- Functions: Verb-Noun | Variables: PascalCase (global), camelCase (local)
- Paths: Always use environment variables
- Strings: Single quotes for constants, double quotes only when interpolation needed
- PSScriptAnalyzer: Must pass all rules at all severity levels (0 violations)

### Required Attributes
```powershell
#Requires -Version 7.5
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
```

### Error Handling
All destructive operations must:
1. Wrap in try-catch
2. Increment `ItemsRemoved` (success) or `ItemsFailed` (error)
3. Log success and failure with descriptive messages

---

## Development Workflow

### Making Changes
1. Read entire function and understand dependencies
2. Test with `-ScanOnly` and `-WhatIf`
3. Verify logging, try-catch coverage, and counter tracking
4. Update documentation for significant features
5. Run validation before committing

### Testing
```powershell
.\RemovePython.ps1 -ScanOnly
.\RemovePython.ps1 -WhatIf
Get-Content .\Python_Removal_Log_*.txt
```

### Pre-Commit Checklist
- [ ] No syntax errors, all parameters work
- [ ] `-ScanOnly` and `-WhatIf` tested
- [ ] Try-catch blocks and counter tracking verified
- [ ] No hardcoded paths (use `$env:USERPROFILE`)
- [ ] `Run-RemovePython.bat` works
- [ ] Documentation updated if needed

---

## Architecture Overview

### Execution Flow (10 phases with progress bar)
1. Parameter validation & user confirmation
2. Disk space check & system restore point creation
3. Check/terminate running Python processes (skip PID ≤ 10)
4. Uninstall Microsoft Store & traditional Python installations
5. Remove environment variables (with backup)
6. Remove directories (108+ locations), virtual environments (4 types), aliases
7. Clear registry keys (90+ locations, HKCU + HKLM)
8. Clean PowerShell profiles (conda init block removal)
9. Post-removal verification & CSV report generation
10. Summary statistics & report

### Key Functions

| Function | Purpose | Safety |
|----------|---------|--------|
| `Test-PathSafe` | Validates paths before deletion | CRITICAL |
| `Remove-ItemSafely` | Safe wrapper with progress indication | CRITICAL |
| `New-RestorePoint` | Creates system restore point | Important |
| `Test-RunningProcess` | Finds/terminates processes (skips PID ≤ 10) | Destructive |
| `Uninstall-TraditionalPython` | Removes installed Python | Destructive |
| `Remove-EnvironmentVariable` | Clears env vars with backup | Destructive |
| `Remove-PythonDirectory` | Removes 108+ locations | Destructive |
| `Remove-VirtualEnvironment` | Removes 4 venv types | Destructive |
| `Remove-AppExecutionAlias` | Removes Python app aliases | Destructive |
| `Clear-Registry` | Cleans 90+ registry locations | Destructive |
| `Remove-ProfileBlock` | Removes conda init from PS profiles | Destructive |
| `Test-PostRemoval` | Verifies cleanup | Safe |

### Protected Paths
Never deletes: `$env:WINDIR`, `$env:SystemRoot`, `$env:ProgramFiles\Windows`, `${env:ProgramFiles(x86)}\Windows`, `C:\Windows`, `C:\Program Files\WindowsApps`

---

## Cleanup Coverage

### Registry (90+ locations)
- Core Python keys (HKCU/HKLM:\Software\Python, Python Software Foundation)
- Conda distributions (Anaconda, Miniconda, Mambaforge, Miniforge)
- File associations HKCU + HKLM (11 extensions: .py, .pyw, .pyc, .pyo, .pyd, .pyi, .pyz, .pyzw, .pth, .whl, .ipynb)
- File type handlers HKCU + HKLM (py_auto_file, Python.File, etc.)
- Application associations HKCU + HKLM (python.exe, pythonw.exe, py.exe, pyw.exe, idle.exe)
- UserChoice file extension associations (11 extensions)
- App paths (python.exe, pythonw.exe, py.exe, pyw.exe, idle.exe + Wow6432Node)
- Orphaned uninstall entries & shared DLL references

### Directories (108+ locations)
- Core installations (4), Conda distributions (12), Version managers (3)
- Python Launcher (`$env:LOCALAPPDATA\Programs\Python\Launcher`)
- Package managers: pip, UV, Poetry, PDM, Rye, Hatch, pipx, virtualenv, Pipenv
- Development tools: Jupyter, IPython, JupyterLab, MyPy, Pytest, Ruff, Pylint, Black, Tox, Nox
- Config files (8): .condarc, .pypirc, pip.ini (user + system), .python-version, etc.
- Shortcuts (Desktop + Start Menu), temp/cache files (age-checked)

### Virtual Environments (4 types)
1. Standard venv (.venv, venv, env)
2. Conda environments (excludes base)
3. Poetry environments
4. Pipenv environments

See REGISTRY_CLEANUP.md and DIRECTORY_CLEANUP.md for complete details.

---

## Parameters

| Parameter | Default | Purpose |
|-----------|---------|---------|
| `-ScanOnly` | False | Preview mode, no changes made |
| `-CreateBackup` | True | Create system restore point |
| `-SkipProcessCheck` | False | Skip running process check |
| `-SkipDiskCheck` | False | Skip disk space validation |
| `-IncludeNetworkDrives` | False | Allow network operations (caution) |
| `-MinFreeDiskSpaceGB` | 5 | Minimum free space (GB) |
| `-TimeoutSeconds` | 300 | Uninstall operation timeout |
| `-MaxScanDepth` | 8 | Virtual environment scan depth (3-15) |

---

## Common Modifications

### Adding Cleanup Locations
- **Directories**: Add to `$globs` in `Remove-PythonDirectory` (use `$env:USERPROFILE`, never hardcode)
- **Config files**: Add to `$configFiles` in `Remove-PythonDirectory`
- **Registry keys**: Add to `$keys` in `Clear-Registry`
- **Environment vars**: Add to `$script:pythonVariables`
- **Processes**: Update `$script:pythonPatterns.ProcessNames` regex

---

## Bug Fixes Applied

1. **System restore point** - Fixed type mismatch with [uint32] casting
2. **Process termination** - Skip system processes (PID ≤ 10)
3. **MSI errors** - Enhanced error messages for codes 1601, 1602, 1603, 1605, 1618, 1619, 1633
4. **EXE uninstaller** - Added verbose logging and manual command on failure
5. **Directory deletion** - Progress display for >1000 items
6. **Counter tracking** - Added ItemsRemoved/ItemsFailed to all operations
7. **Unknown uninstallers** - Log warnings for manual intervention
8. **Orphan detection** - Fixed path extraction for paths with spaces (was truncating at first space)
9. **Temp file cleanup** - Now handles both files and directories (was silently skipping files)
10. **Long-path fallback** - Fixed TrimStart character-set bug with regex replacement
11. **Batch launcher** - Validates pwsh.exe availability; uses pwsh consistently for elevation

See FIXES_APPLIED.md for details.

---

## Git Workflow

### Commit Format
```
<type>: <subject>

<body>

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
```
**Types:** feat, fix, refactor, docs, test, chore

### Tracked Files
Track: *.ps1, *.bat, *.md (documentation)
Ignore: *.txt (logs), *.csv (reports), *.json (backups)

---

## Troubleshooting

**Access Denied** - Run as Administrator, close Python processes, check file attributes
**MSI hangs** - Increase `-TimeoutSeconds`, check for pending reboots, verify Windows Installer service
**Registry denied** - Confirm admin rights, some keys may be TrustedInstaller-owned
**Process won't stop** - Use Task Manager or check services (services.msc)

**MSI Exit Codes:** 1601 (service not accessible), 1603 (fatal error), 1605 (not found)

## Performance

**Typical runtime:** 1-3 minutes (varies by installations, cache size, venv count, disk I/O)
**Large caches:** UV (5+ GB), Conda (10+ GB), Poetry (1-3 GB), pip (500MB-2GB)
**Progress indicators:** Show for operations >1000 items

---

## Version History

### v1.1 (2026-05-11)
**New:** PowerShell profile cleanup (conda init removal), HKLM file associations, UserChoice registry keys, .ipynb/.jupyter/.ipython/.jupyterlab cleanup, Python Launcher directory, progress bar across all phases, venv scan optimization (skips heavy subtrees)

**Fixed:** Orphan detection path truncation, temp file-only cleanup, long-path TrimStart bug, misleading "tools remain functional" message, batch launcher pwsh validation

**Quality:** PSScriptAnalyzer clean — 0 violations across all rules (default + formatting + style)

### v1.0 (2026-02-28)
**Features:** 158+ cleanup locations, 4 venv types, system restore, user confirmation, progress tracking, comprehensive logging, CSV reports, post-removal verification

**Safety:** Protected paths, root drive protection, system process protection (PID ≤ 10), age-based temp deletion, orphan detection, try-catch coverage, WhatIf/ScanOnly support

**Documentation:** CLAUDE.md, FINAL_SUMMARY.md, REGISTRY_CLEANUP.md, DIRECTORY_CLEANUP.md, FIXES_APPLIED.md, IMPROVEMENTS.md

---

## License & Disclaimer

**USE AT YOUR OWN RISK** - This script permanently removes Python installations, environments, caches, and configurations. Always create a system restore point (enabled by default), backup data, and test with `-ScanOnly` first.

**Preserved:** IDE installations (PyCharm, VS Code), user scripts outside standard Python locations, data files

---

*Last Updated: 2026-05-11 | Status: Production-ready | Coverage: 200+ locations*
