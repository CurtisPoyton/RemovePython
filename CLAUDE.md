# RemovePython - Claude Instructions

## Project Overview

**RemovePython** is a comprehensive PowerShell script designed to completely remove Python installations and related artifacts from Windows systems. This is a **destructive utility** that requires administrator privileges and should be handled with extreme care.

**Current Version:** 1.0
**Target Platform:** Windows 10/11
**PowerShell Version:** 7.5+
**Status:** Production-ready

**Cleanup Coverage:**
- **158+ total cleanup locations** (directories, files, registry keys)
- **58+ registry locations** (keys, file associations, app paths, orphaned entries)
- **100+ directory/file locations** (installations, caches, configs, shortcuts)
- **4 virtual environment types** (venv, conda, poetry, pipenv)

---

## Project Structure

```
RemovePython/
├── RemovePython.ps1              # Main PowerShell script (~1000 lines)
├── Run-RemovePython.bat          # Batch launcher with auto-elevation
├── CLAUDE.md                     # This file
├── FINAL_SUMMARY.md              # Complete enhancement summary
├── REGISTRY_CLEANUP.md           # Registry cleanup documentation (58+ locations)
├── DIRECTORY_CLEANUP.md          # Directory cleanup documentation (100+ locations)
├── FIXES_APPLIED.md              # Bug fixes documentation
├── IMPROVEMENTS.md               # Log analysis and improvements
└── *.txt, *.csv, *.json         # Generated log/report files (not tracked)
```

### File Descriptions

#### `RemovePython.ps1` (Primary Script)
- **~1000 lines** of PowerShell 7.5+ code
- Removes Python installations, environments, caches, registry keys, environment variables, shortcuts, config files
- Includes comprehensive safety features, progress indication, and detailed logging
- **Comprehensive coverage:** 158+ cleanup locations
- **CRITICAL:** Never modify without thorough testing

#### `Run-RemovePython.bat` (Launcher)
- Auto-elevates to administrator privileges
- Passes arguments to PowerShell script
- Sets proper working directory
- Version must match PowerShell script

#### Documentation Files
- `FINAL_SUMMARY.md` - Complete overview of all enhancements
- `REGISTRY_CLEANUP.md` - Detailed registry cleanup documentation
- `DIRECTORY_CLEANUP.md` - Detailed directory cleanup documentation
- `FIXES_APPLIED.md` - All bug fixes applied
- `IMPROVEMENTS.md` - Analysis of previous run issues

---

## Critical Safety Guidelines

### 🚨 NEVER Do These Things

1. **NEVER** disable or bypass `Test-PathSafe` function
2. **NEVER** remove paths from `$script:protectedPaths` array
3. **NEVER** allow deletion of root drives (C:\, D:\, etc.)
4. **NEVER** skip path validation in destructive operations
5. **NEVER** commit changes that disable system restore point creation by default
6. **NEVER** remove the `-WhatIf` support (ShouldProcess)
7. **NEVER** bypass the administrator requirement
8. **NEVER** disable the user confirmation prompt by default
9. **NEVER** use hardcoded user paths (always use environment variables)

### ⚠️ Always Do These Things

1. **ALWAYS** test changes with `-ScanOnly` parameter first
2. **ALWAYS** verify `Test-PathSafe` protects system directories
3. **ALWAYS** maintain try-catch blocks around destructive operations
4. **ALWAYS** log operations to the log file
5. **ALWAYS** increment `ItemsRemoved` or `ItemsFailed` counters for all operations
6. **ALWAYS** update version number for significant changes (currently maintain at 1.0)
7. **ALWAYS** run validation checks before committing
8. **ALWAYS** use environment variables for paths (e.g., `$env:USERPROFILE`, `$env:APPDATA`)
9. **ALWAYS** provide descriptive error messages with context
10. **ALWAYS** show progress for long-running operations (>1000 items)

---

## Code Standards

### PowerShell Conventions

- **Indentation:** 4 spaces (no tabs)
- **Line Length:** Soft limit of 120 characters
- **Brace Style:** Opening brace on same line
- **Function Naming:** Verb-Noun format (e.g., `Remove-ItemSafely`)
- **Variable Naming:** PascalCase for global, camelCase for local
- **Comments:** Use `#region` blocks for major sections
- **Paths:** Always use environment variables (never hardcode user paths)

### Required Script Attributes

```powershell
#Requires -Version 7.5
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
```

**Never remove these directives.**

### Error Handling Pattern

```powershell
try {
    # Operation
    Write-LogMessage -Message "Success" -Color $script:colors.Success -Type 'REMOVE'
    $script:config.ItemsRemoved++
} catch {
    Write-LogMessage -Message "Failed: $($_.Exception.Message)" -Color $script:colors.Error -Type 'ERROR'
    $script:config.ItemsFailed++
}
```

**IMPORTANT:** All destructive operations must:
1. Be wrapped in try-catch
2. Increment `ItemsRemoved` on success
3. Increment `ItemsFailed` on error
4. Log both success and failure with descriptive messages

---

## Development Workflow

### Making Changes

1. **Read the entire function** before modifying
2. **Understand dependencies** (what calls this function?)
3. **Test with `-ScanOnly`** parameter first
4. **Test with `-WhatIf`** to verify ShouldProcess support
5. **Verify logging** output is clear and informative
6. **Check try-catch** coverage for new operations
7. **Verify counter tracking** (ItemsRemoved/ItemsFailed incremented)
8. **Test with real data** if adding new cleanup locations
9. **Update documentation** if adding significant features
10. **Run validation** script before committing

### Testing Procedure

```powershell
# 1. Scan only (safe preview)
.\RemovePython.ps1 -ScanOnly

# 2. WhatIf mode (shows what would happen)
.\RemovePython.ps1 -WhatIf

# 3. Test with various parameters
.\RemovePython.ps1 -ScanOnly -SkipProcessCheck
.\RemovePython.ps1 -ScanOnly -IncludeNetworkDrives
.\RemovePython.ps1 -ScanOnly -CreateBackup:$false

# 4. Check logs and reports
Get-Content .\Python_Removal_Log_*.txt
Import-Csv .\Python_Removal_Report_*.csv | Format-Table

# 5. Verify counters
# Check log file for ItemsRemoved, ItemsFailed, ItemsSkipped counts
```

### Validation Checklist

Before committing changes:

- [ ] No syntax errors: `pwsh -NoProfile -Command "Test-Path .\RemovePython.ps1"`
- [ ] Parse validation passes
- [ ] All parameters still work
- [ ] `-ScanOnly` mode tested and accurate
- [ ] `-WhatIf` mode tested
- [ ] Logging output is clear and informative
- [ ] Try-catch blocks intact and comprehensive
- [ ] Counter tracking verified (ItemsRemoved/ItemsFailed)
- [ ] No hardcoded user paths (use `$env:USERPROFILE`, etc.)
- [ ] Progress indication for large operations
- [ ] Version number maintained at 1.0 (or updated if breaking change)
- [ ] `Run-RemovePython.bat` still works
- [ ] Comments are accurate and helpful
- [ ] User confirmation prompt still works
- [ ] Documentation updated if needed

---

## Architecture Overview

### Execution Flow

```
1. Parameter validation & preference settings
2. User confirmation prompt (shows all actions, allows cancellation)
3. Disk space check (if enabled)
4. Create system restore point (if enabled) - Fixed with [uint32] casting
5. Check for running Python processes (skip system processes PID ≤ 10)
6. Uninstall Microsoft Store Python apps
7. Uninstall traditional Python installations (MSI/EXE with enhanced logging)
8. Remove environment variables (with backup and counter tracking)
9. Remove Python directories (100+ locations including configs and shortcuts)
10. Remove virtual environments (4 types: venv, conda, poetry, pipenv)
11. Remove app execution aliases
12. Clear registry keys (58+ locations including orphaned entries)
13. Post-removal verification (comprehensive check of 13 locations)
14. Generate CSV report
```

### Key Functions

| Function | Purpose | Safety Level | Enhancements |
|----------|---------|--------------|--------------|
| `Test-PathSafe` | Validates paths before deletion | 🛡️ CRITICAL | Original |
| `Remove-ItemSafely` | Safe wrapper for Remove-Item | 🛡️ CRITICAL | ✨ Progress indication added |
| `Write-LogMessage` | Logging with colors and file output | ✅ Safe | Original |
| `New-RestorePoint` | Creates system restore point | 🛡️ Important | ✨ Fixed [uint32] type issue |
| `Test-DiskSpace` | Validates free space | ✅ Safe | Original |
| `Test-RunningProcess` | Finds/terminates processes | ⚠️ Destructive | ✨ Skips system processes |
| `Uninstall-StorePython` | Removes AppX packages | ⚠️ Destructive | Original |
| `Uninstall-TraditionalPython` | Removes installed Python | ⚠️ Destructive | ✨ Enhanced error messages |
| `Remove-EnvironmentVariable` | Clears env vars | ⚠️ Destructive | ✨ Counter tracking added |
| `Remove-PythonDirectory` | Removes directories | ⚠️ Destructive | ✨ 100+ locations, configs, shortcuts |
| `Remove-VirtualEnvironment` | Removes venvs | ⚠️ Destructive | ✨ 4 types detected |
| `Clear-Registry` | Cleans registry | ⚠️ Destructive | ✨ 58+ locations, orphan cleanup |
| `Test-PostRemoval` | Verifies cleanup | ✅ Safe | ✨ Comprehensive verification |

### Protected Paths (Never Delete)

```powershell
$script:protectedPaths = @(
    $env:WINDIR,                           # C:\Windows
    $env:SystemRoot,                       # C:\Windows
    "$env:ProgramFiles\Windows",           # Program Files\Windows
    "${env:ProgramFiles(x86)}\Windows",    # Program Files (x86)\Windows
    'C:\Windows',                          # Hardcoded Windows
    'C:\Program Files\WindowsApps'         # Store apps folder
)
```

**Do not modify this list without explicit approval.**

---

## Cleanup Coverage Details

### Registry Cleanup (58+ locations)

**Core Python Keys:**
- HKCU/HKLM:\Software\Python (4 locations including Wow6432Node)
- HKCU/HKLM:\Software\Python Software Foundation (3 locations)

**Conda Distributions:**
- Anaconda, Miniconda, Mambaforge, Miniforge, Continuum Analytics (8 locations)

**Package Managers:**
- Poetry, pyenv (4 locations)

**File Associations:**
- 21 file types: .py, .pyw, .pyc, .pyo, .pyd, .pyi, .pyz, .pyzw, .pth, .whl, .ipynb

**App Paths:**
- python.exe, pythonw.exe, py.exe, pyw.exe, idle.exe (7 locations)

**Application Associations:**
- 6 applications: python.exe, pythonw.exe, py.exe, pyw.exe, idle.exe, ipython.exe

**Orphaned Cleanup:**
- Uninstall registry entries (smart detection, installation-gone only)
- Shared DLL references (orphaned DLL files only)

See `REGISTRY_CLEANUP.md` for complete details.

### Directory Cleanup (100+ locations)

**Core Installations:** 4 locations
**Conda Distributions:** 12 locations
**Version Managers:** 3 locations (pyenv, pythonz, python-build)

**Package Managers:**
- pip (6 locations)
- UV/Astral (7 locations including %APPDATA%\uv)
- Poetry (6 locations + virtualenvs)
- PDM (3 locations)
- Rye (2 locations)
- Hatch (2 locations)
- pipx (4 locations)
- virtualenv/Pipenv (3 locations)

**Development Tools:**
- Jupyter/IPython/JupyterLab (8 locations)
- Code quality tools: MyPy, Pytest, Ruff, Pylint, Black, Tox, Nox (7 caches)

**Config Files:** 7 files (.condarc, .pypirc, pip.ini, .python-version, etc.)
**Shortcuts:** Desktop + Start Menu (Python, Anaconda, Jupyter, IDLE)
**Temp/Cache:** %TEMP% files (age-checked) + Package Cache

See `DIRECTORY_CLEANUP.md` for complete details.

### Virtual Environment Detection (4 types)

1. **Standard venv** - .venv, venv, env (via activate script)
2. **Conda environments** - via conda-meta directory (excludes base env)
3. **Poetry environments** - in %LOCALAPPDATA%\pypoetry\Cache\virtualenvs
4. **Pipenv environments** - in %USERPROFILE%\.local\share\virtualenvs

---

## Parameters Reference

| Parameter | Type | Default | Purpose |
|-----------|------|---------|---------|
| `-ScanOnly` | Switch | False | Preview mode, no changes made |
| `-CreateBackup` | Bool | True | Create system restore point |
| `-SkipProcessCheck` | Switch | False | Skip checking for running processes |
| `-SkipDiskCheck` | Switch | False | Skip disk space validation |
| `-IncludeNetworkDrives` | Switch | False | Allow network path operations (use with caution) |
| `-MinFreeDiskSpaceGB` | Int | 5 | Minimum free space required |
| `-TimeoutSeconds` | Int | 300 | Timeout for uninstall operations |

---

## Common Modifications

### Adding New Python-Related Directories

Add to `$globs` array in `Remove-PythonDirectory` function:

```powershell
$globs = @(
    # ... existing paths ...
    "$env:USERPROFILE\.myNewPythonTool",  # New entry (use env vars!)
    "$env:LOCALAPPDATA\myNewPythonTool"
)
```

**IMPORTANT:** Always use environment variables, never hardcode paths like "C:\Users\Curtis\..."

### Adding New Config Files

Add to `$configFiles` array in `Remove-PythonDirectory` function:

```powershell
$configFiles = @(
    # ... existing files ...
    "$env:USERPROFILE\.mynewconfig"
)
```

### Adding New Registry Keys

Add to `$keys` array in `Clear-Registry` function:

```powershell
$keys = @(
    # ... existing keys ...
    'HKCU:\Software\MyNewPythonTool',
    'HKLM:\Software\MyNewPythonTool'
)
```

### Adding New Environment Variables

Add to `$script:pythonVariables` array:

```powershell
$script:pythonVariables = @(
    # ... existing vars ...
    'MY_NEW_PYTHON_VAR'
)
```

### Modifying Process Detection

Update `$script:pythonPatterns.ProcessNames` regex:

```powershell
ProcessNames = '^python...|^mynewtool$'
```

---

## Bug Fixes Applied

### 1. System Restore Point Creation (CRITICAL)
**Issue:** Type mismatch error
**Fix:** Cast to [uint32]
```powershell
RestorePointType = [uint32]12
EventType        = [uint32]100
```

### 2. Process Termination - System Process Protection
**Issue:** Attempted to stop system processes (PID 0-10)
**Fix:** Filter out system processes
```powershell
$_.Id -gt 10  # Skip system processes
```

### 3. MSI Error Messages
**Issue:** Generic error messages
**Fix:** Comprehensive error code lookup (1601, 1602, 1603, 1605, 1618, 1619, 1633)

### 4. EXE Uninstaller Logging
**Issue:** Silent failures with no diagnostic info
**Fix:** Verbose logging, reordered silent flags, manual command on failure

### 5. Directory Deletion Progress
**Issue:** Long operations with no feedback
**Fix:** Item count display for directories >1000 items

### 6. Counter Tracking
**Issue:** Missing ItemsRemoved/ItemsFailed increments
**Fix:** Added counters to all operations

### 7. Unknown Uninstaller Format
**Issue:** Silent skip for non-MSI/EXE uninstallers
**Fix:** Log warning with manual intervention message

See `FIXES_APPLIED.md` for detailed documentation.

---

## Git Workflow

### Commit Message Format

```
<type>: <subject>

<body>

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>
```

**Types:** `feat`, `fix`, `refactor`, `docs`, `test`, `chore`

**Example:**
```
feat: Add comprehensive registry orphan cleanup

Enhance registry cleanup to detect and remove orphaned uninstall entries
and shared DLL references. Includes smart detection to only remove entries
where the installation or DLL file no longer exists.

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>
```

### Files to Track

- ✅ `RemovePython.ps1`
- ✅ `Run-RemovePython.bat`
- ✅ `CLAUDE.md`
- ✅ `FINAL_SUMMARY.md`
- ✅ `REGISTRY_CLEANUP.md`
- ✅ `DIRECTORY_CLEANUP.md`
- ✅ `FIXES_APPLIED.md`
- ✅ `IMPROVEMENTS.md`
- ✅ `README.md` (if created)
- ❌ `*.txt` (logs - runtime generated)
- ❌ `*.csv` (reports - runtime generated)
- ❌ `*.json` (backups - runtime generated)

### Recommended .gitignore

```gitignore
# Runtime generated files
*.txt
*.csv
*.json

# Exception: keep documentation
!validation_report.md
```

---

## Troubleshooting

### Common Issues

**"Access Denied" errors:**
- Verify script runs as Administrator
- Check if files are in use (processes running)
- Close Python processes before running
- Verify readonly attributes are cleared

**MSI Uninstall hangs:**
- Check `$TimeoutSeconds` parameter (default 300s)
- Verify MSI installer is not corrupted
- Look for pending reboots
- Check if Windows Installer service is running

**MSI Exit Codes:**
- 1601: Windows Installer service not accessible
- 1603: Fatal error during installation (often dependency issue)
- 1605: Product not found or already uninstalled
- See `FIXES_APPLIED.md` for complete error code list

**Path too long errors:**
- Already handled with `\\?\` prefix in catch block
- If new paths fail, wrap in similar handler

**Registry access denied:**
- Confirm administrator rights
- Check if registry keys are protected by system policies
- Some keys may be owned by TrustedInstaller

**Process won't stop:**
- Close applications manually
- Use Task Manager to end processes
- Check for services (use `services.msc`)

**Confirmation prompt not showing:**
- Check if running with `-ScanOnly` (prompt skipped)
- Check if running with `-WhatIf` (prompt skipped)
- Verify not running in non-interactive mode

---

## Performance Expectations

Typical cleanup times:
- Confirmation prompt: Interactive
- Disk space check: <1 second
- System restore point: 2-5 seconds
- Process check: <1 second
- Store Python uninstall: 1-2 seconds
- Traditional uninstalls: 30-60 seconds (MSI timeouts)
- Environment variables: <1 second
- Directory cleanup: 30-60 seconds (varies with cache size)
- Virtual environment scan: 10-30 seconds (depth 8)
- Registry cleanup: 3-5 seconds
- Post-removal verification: 1-2 seconds

**Total: 1-3 minutes** (varies based on:
- Number of Python installations
- Size of caches (UV can be 5+ GB, Conda 10+ GB)
- Number of virtual environments
- Disk I/O speed

**Large cache warnings:**
- UV cache: Can exceed 5+ GB
- Conda package cache: Can exceed 10+ GB
- Poetry cache: Typically 1-3 GB
- pip cache: Typically 500MB-2GB

Progress indicators show when deleting >1000 items to avoid "frozen" appearance.

---

## Version History

### v1.0 (2026-02-28)
**Status:** Production-ready

**Features:**
- Comprehensive Python removal (158+ locations)
- User confirmation prompt with detailed warning
- System restore point creation (type-safe)
- 4 virtual environment types detected
- 58+ registry locations cleaned (including orphans)
- 100+ directory/file locations cleaned
- Config file cleanup (7 files)
- Desktop and Start Menu shortcut cleanup
- Temp file cleanup (age-checked for safety)
- Progress indication for large operations
- Comprehensive error handling and logging
- CSV report generation
- Post-removal verification (13 locations checked)

**Bug Fixes:**
- System restore point type mismatch - FIXED
- Process termination system process issue - FIXED
- MSI error messages enhanced - FIXED
- EXE uninstaller logging improved - FIXED
- Directory deletion progress added - FIXED
- Counter tracking completed - FIXED
- Unknown uninstaller format handled - FIXED

**Safety Features:**
- Protected path validation
- Root drive protection
- System process protection (PID ≤ 10)
- Age-based temp file deletion (>1 day)
- Smart orphan detection (registry)
- Comprehensive try-catch coverage
- WhatIf and ScanOnly support
- User confirmation prompt

**Documentation:**
- CLAUDE.md (this file) - Developer guidelines
- FINAL_SUMMARY.md - Complete enhancement summary
- REGISTRY_CLEANUP.md - 58+ registry locations
- DIRECTORY_CLEANUP.md - 100+ directory locations
- FIXES_APPLIED.md - Bug fix documentation
- IMPROVEMENTS.md - Log analysis

---

## Contact & Support

**Script Author:** Curtis
**Maintained by:** Claude Code
**Repository:** Local (%USERPROFILE%\Documents\Scripts\RemovePython)

For issues or questions:
1. Review documentation:
   - `FINAL_SUMMARY.md` - Complete overview
   - `REGISTRY_CLEANUP.md` - Registry details
   - `DIRECTORY_CLEANUP.md` - Directory details
   - `FIXES_APPLIED.md` - Bug fixes
2. Check logs: `Python_Removal_Log_*.txt`
3. Review report: `Python_Removal_Report_*.csv`
4. Test with `-ScanOnly` first
5. Test with `-WhatIf` to preview actions

---

## License & Disclaimer

⚠️ **USE AT YOUR OWN RISK** ⚠️

This script performs destructive operations that permanently remove software and configurations. Always:
- ✅ Create a system restore point (enabled by default)
- ✅ Backup important data
- ✅ Test in `-ScanOnly` mode first
- ✅ Review the confirmation prompt carefully
- ✅ Understand what will be deleted (check logs from -ScanOnly run)
- ✅ Close all Python-related applications
- ✅ Save any work in Python IDEs/editors

**What gets removed:**
- All Python installations (official, Store, Anaconda, conda distributions)
- All package managers (pip, UV, Poetry, PDM, Rye, Hatch, pipx, etc.)
- All virtual environments (venv, conda, poetry, pipenv)
- All caches and config files
- All registry keys and file associations
- All shortcuts (desktop and start menu)

**What's preserved:**
- IDE/Editor installations (PyCharm, VS Code, etc.)
- User scripts outside standard Python locations
- Data files created by Python programs

The authors are not responsible for data loss or system issues resulting from use of this script.

---

**Important Reminders for Future Development:**

1. ✅ Always use environment variables for paths
2. ✅ Always increment counters (ItemsRemoved/ItemsFailed)
3. ✅ Always wrap destructive operations in try-catch
4. ✅ Always show progress for large operations (>1000 items)
5. ✅ Always test with `-ScanOnly` and `-WhatIf` before committing
6. ✅ Always maintain comprehensive logging
7. ✅ Always preserve safety features (Test-PathSafe, protected paths, user confirmation)
8. ✅ Never hardcode user paths
9. ✅ Never disable safety features without explicit user request
10. ✅ Never skip validation before committing

---

*Last Updated: 2026-02-28*
*Script Status: Production-ready with comprehensive enhancements*
*Coverage: 158+ cleanup locations*
