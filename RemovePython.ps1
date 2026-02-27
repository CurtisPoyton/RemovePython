#Requires -Version 7.5
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Completely removes Python installations, environments, and artifacts from Windows.

.DESCRIPTION
    This script performs a deep clean of Python, including:
    - Microsoft Store installations
    - Traditional MSI/EXE installations (Python, Anaconda, Miniconda, etc.)
    - Environment variables (PATH, PYTHONPATH, etc.)
    - Virtual environments (venv, .venv, conda envs)
    - Package caches (pip, poetry, uv, rye)
    - Registry keys and file associations
    - Jupyter/IPython kernels and configs
    - App execution aliases

.EXAMPLE
    .\RemovePython.ps1
    Runs in automated mode, creating a restore point and removing all Python installations.

.EXAMPLE
    .\RemovePython.ps1 -ScanOnly
    Preview mode - lists all Python components without deleting anything.

.EXAMPLE
    .\RemovePython.ps1 -CreateBackup:$false
    Skips creating a system restore point before removal.

.EXAMPLE
    .\RemovePython.ps1 -MaxScanDepth 5
    Faster virtual environment scan (depth 5 instead of default 8).
#>

[CmdletBinding(SupportsShouldProcess)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'CreateBackup', Justification = 'Used in New-RestorePoint')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'SkipProcessCheck', Justification = 'Used in Test-RunningProcess')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'SkipDiskCheck', Justification = 'Used in Test-DiskSpace')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'IncludeNetworkDrives', Justification = 'Used in Remove-ItemSafely')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'MaxScanDepth', Justification = 'Used in config initialization')]
param(
    [Parameter(HelpMessage = "Preview mode - no changes will be made")]
    [switch]$ScanOnly,

    [Parameter(HelpMessage = "Create system restore point before removal")]
    [bool]$CreateBackup = $true,

    [Parameter(HelpMessage = "Skip checking for running Python processes")]
    [switch]$SkipProcessCheck,

    [Parameter(HelpMessage = "Skip disk space check")]
    [switch]$SkipDiskCheck,

    [Parameter(HelpMessage = "Include network drives (use with caution)")]
    [switch]$IncludeNetworkDrives,

    [Parameter(HelpMessage = "Minimum free disk space in GB")]
    [ValidateRange(1, 1000)]
    [int]$MinFreeDiskSpaceGB = 5,

    [Parameter(HelpMessage = "Operation timeout in seconds")]
    [ValidateRange(60, 3600)]
    [int]$TimeoutSeconds = 300,

    [Parameter(HelpMessage = "Maximum depth for virtual environment scan (lower = faster, higher = more thorough)")]
    [ValidateRange(3, 15)]
    [int]$MaxScanDepth = 8
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'Continue'
$VerbosePreference = 'Continue'
$InformationPreference = 'Continue'

#region Global Configuration
$script:config = @{
    Version            = '1.0'
    LogFile            = "$PSScriptRoot\Python_Removal_Log_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
    ReportFile         = "$PSScriptRoot\Python_Removal_Report_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    BackupFile         = "$PSScriptRoot\Python_EnvVars_Backup_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
    ItemsFound         = [System.Collections.Generic.List[object]]::new()
    ItemsRemoved       = 0
    ItemsFailed        = 0
    ItemsSkipped       = 0
    TotalSize          = [int64]0
    StartTime          = Get-Date
    MaxDepth           = $MaxScanDepth
    TimeoutSeconds     = $TimeoutSeconds
    MinFreeDiskSpaceGB = $MinFreeDiskSpaceGB
}

$script:colors = @{
    Header   = 'Cyan'
    Success  = 'Green'
    Warning  = 'Yellow'
    Error    = 'Red'
    Info     = 'Gray'
    Found    = 'Yellow'
    Critical = 'Magenta'
}

$script:ansiColors = @{
    'Cyan'    = "`e[36m"
    'Green'   = "`e[32m"
    'Yellow'  = "`e[33m"
    'Red'     = "`e[31m"
    'Gray'    = "`e[90m"
    'White'   = "`e[37m"
    'Magenta' = "`e[35m"
    'Reset'   = "`e[0m"
}

$script:pythonPatterns = @{
    PathEntries  = '(^|\\)(python\d*|\.venv|venv|Scripts|Anaconda\d*|Miniconda\d*|Mambaforge|Miniforge|conda|pyenv|pipx|poetry|pdm|rye|uv|hatch|virtualenv|site-packages|dist-packages|pip|wheel|IPython|jupyter|nbconvert|astral|mise|asdf)(\\|$)|\.python-version'
    ProcessNames = '^python(w)?(\d+(\.\d+)?)?$|^pip(\d+)?$|^conda$|^mamba$|^anaconda$|^poetry$|^pdm$|^pipx$|^rye$|^uv$|^hatch$|^jupyter|^ipython|^pyinstaller|^pylint|^pytest|^mypy|^black|^ruff|^flake8|^virtualenv|^pydoc|^idle|^sphinx'
}

$script:protectedPaths = @(
    $env:WINDIR,
    $env:SystemRoot,
    "$env:ProgramFiles\Windows",
    "${env:ProgramFiles(x86)}\Windows",
    'C:\Windows',
    'C:\Program Files\WindowsApps'
)

$script:pythonVariables = @(
    'PYTHONPATH', 'PYTHONHOME', 'PYTHON', 'PYTHONDONTWRITEBYTECODE', 'PYTHONUNBUFFERED',
    'PYTHONSTARTUP', 'PYTHONCASEOK', 'PYTHONIOENCODING', 'PYTHONFAULTHANDLER',
    'PYTHONHASHSEED', 'PYTHONMALLOC', 'PYTHONCOERCECLOCALE', 'PYTHONBREAKPOINT',
    'PYTHONDEVMODE', 'PYTHONPYCACHEPREFIX', 'PYTHONWARNDEFAULTENCODING',
    'PYTHONPLATLIBDIR', 'PYTHONSAFEPATH', 'PYTHONNOUSERSITE', 'PYTHONUTF8',
    'PYTHONLEGACYWINDOWSSTDIO', 'PYTHONLEGACYWINDOWSFSENCODING', 'PYTHONEXECUTABLE',
    'PYTHONUSERBASE', 'PYTHONWARNINGS', 'PYTHONDEBUG', 'PYTHONINSPECT', 'PYTHONOPTIMIZE',
    'PYTHONVERBOSE', 'PYTHONTRACEMALLOC', 'PYTHONASYNCIODEBUG', 'PYTHONINTMAXSTRDIGITS',
    'PYTHONTHREADDEBUG', 'PYTHONDUMPREFS', 'PYTHONPROFILEIMPORTTIME',
    'PYTHON_BASIC_REPL', 'PYTHON_HISTORY', 'PYTHON_COLORS', 'PYTHON_CPU_COUNT',
    'VIRTUAL_ENV', 'VIRTUAL_ENV_PROMPT', 'VIRTUALENVWRAPPER_PYTHON', 'VIRTUALENVWRAPPER_VIRTUALENV',
    'WORKON_HOME', 'PROJECT_HOME', 'VIRTUALENVWRAPPER_HOOK_DIR', 'VIRTUALENVWRAPPER_LOG_DIR',
    'CONDA_PREFIX', 'CONDA_DEFAULT_ENV', 'CONDA_SHLVL', 'CONDA_PROMPT_MODIFIER',
    'CONDA_EXE', 'CONDA_PYTHON_EXE', '_CE_M', '_CE_CONDA', 'CONDA_ROOT',
    'CONDA_BAT', 'CONDA_ENVS_PATH', 'CONDA_PKGS_DIRS', 'ANACONDA_HOME',
    'MINICONDA_HOME', 'MAMBA_EXE', 'MAMBA_ROOT_PREFIX', 'MAMBA_NO_BANNER',
    'CONDA_CHANNELS', 'CONDA_AUTO_UPDATE_CONDA',
    'PYENV', 'PYENV_ROOT', 'PYENV_SHELL', 'PYENV_VERSION', 'PYENV_DIR',
    'POETRY_HOME', 'POETRY_CACHE_DIR', 'POETRY_CONFIG_DIR', 'POETRY_DATA_DIR',
    'PDM_HOME', 'PDM_CACHE_DIR', 'RYE_HOME', 'PIPX_HOME', 'PIPX_BIN_DIR',
    'UV_CACHE_DIR', 'UV_TOOL_DIR', 'UV_PYTHON', 'HATCH_HOME',
    'PIP_CONFIG_FILE', 'PIP_CACHE_DIR', 'JUPYTER_CONFIG_DIR', 'JUPYTER_DATA_DIR',
    'IPYTHONDIR', 'PYLAUNCHER_ALLOW_INSTALL', 'PY_PYTHON'
)
#endregion

#region Utility Functions
function Write-LogMessage {
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Message,
        [Parameter(Position = 1)]
        [string]$Color = 'White',
        [Parameter(Position = 2)]
        [string]$Type = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $logMessage = "[$timestamp][$Type] $Message"

    try {
        $ansiCode = $script:ansiColors[$Color]
        if (-not $ansiCode) { $ansiCode = $script:ansiColors['White'] }
        Write-Information "$ansiCode$Message$($script:ansiColors['Reset'])"
        Add-Content -Path $script:config.LogFile -Value $logMessage -ErrorAction SilentlyContinue
    } catch {
        $null = $_
    }
}

function Test-PathSafe {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }

    try {
        $normalizedPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    } catch {
        Write-LogMessage -Message "Invalid path format: $Path" -Color $script:colors.Warning -Type 'VALIDATE'
        return $false
    }

    if ($normalizedPath -match '^[A-Z]:\\?$') {
        Write-LogMessage -Message "[X] Root drive blocked: $normalizedPath" -Color $script:colors.Critical -Type 'PROTECT'
        return $false
    }

    foreach ($protected in $script:protectedPaths) {
        $protectedNormalized = $protected.TrimEnd('\')
        if ($normalizedPath -eq $protectedNormalized -or $normalizedPath.StartsWith("$protectedNormalized\", [StringComparison]::OrdinalIgnoreCase)) {
            Write-LogMessage -Message "[X] Protected system path blocked: $normalizedPath" -Color $script:colors.Critical -Type 'PROTECT'
            return $false
        }
    }
    return $true
}

function Get-SafeFolderSize {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { return 0 }
    try {
        return (Get-ChildItem -Path $Path -Recurse -File -Force -ErrorAction Ignore | Measure-Object -Property Length -Sum).Sum
    } catch {
        return 0
    }
}

function Format-FileSize {
    param([int64]$Bytes)
    if ($Bytes -le 0) { return '0 B' }
    $sizes = @('B', 'KB', 'MB', 'GB', 'TB')
    $order = [Math]::Floor([Math]::Log($Bytes, 1024))
    $order = [Math]::Min([Math]::Max($order, 0), $sizes.Count - 1)
    $num = [Math]::Round($Bytes / [Math]::Pow(1024, $order), 2)
    return "$num $($sizes[$order])"
}

function Test-IsNetworkPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ($Path -like '\\*') { return $true }
    try {
        $drive = Split-Path $Path -Qualifier -ErrorAction SilentlyContinue
        if ([string]::IsNullOrEmpty($drive)) { return $false }
        $driveInfo = Get-PSDrive -Name $drive.TrimEnd(':') -PSProvider FileSystem -ErrorAction SilentlyContinue
        return ($null -ne $driveInfo.DisplayRoot -and $driveInfo.DisplayRoot -like '\\*')
    } catch { return $false }
}

function Add-Finding {
    param($Type, $Name, $Path, [int64]$SizeBytes = 0, $Status = 'Found')
    $finding = [PSCustomObject]@{
        Type      = $Type
        Name      = $Name
        Path      = $Path
        Size      = Format-FileSize $SizeBytes
        SizeBytes = $SizeBytes
        Status    = $Status
        Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    }
    [void]$script:config.ItemsFound.Add($finding)
    $script:config.TotalSize += $SizeBytes
}

function Test-DiskSpace {
    if ($SkipDiskCheck) { return $true }
    try {
        $systemDrive = $env:SystemDrive.TrimEnd(':')
        $drive = Get-PSDrive -Name $systemDrive -PSProvider FileSystem -ErrorAction Stop
        $freeGB = [Math]::Round($drive.Free / 1GB, 2)
        if ($freeGB -lt $script:config.MinFreeDiskSpaceGB) {
            Write-LogMessage -Message "[!] Low disk space: $freeGB GB (minimum: $($script:config.MinFreeDiskSpaceGB) GB)" -Color $script:colors.Warning -Type 'DISK'
            return $false
        }
        return $true
    } catch { return $true }
}
#endregion

#region Pre-flight Checks & Backup
function New-RestorePoint {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if (-not $CreateBackup -or $ScanOnly) { return }

    if ($PSCmdlet.ShouldProcess("System", "Create Restore Point")) {
        Write-LogMessage -Message "`nCreating system restore point..." -Color $script:colors.Warning -Type 'BACKUP'

        try {
            $desc = "Python Removal v$($script:config.Version) - $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

            try {
                Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
            } catch { $null = $_ }

            $result = Invoke-CimMethod -Namespace root/default -ClassName SystemRestore -MethodName CreateRestorePoint -Arguments @{
                Description      = $desc
                RestorePointType = [uint32]12
                EventType        = [uint32]100
            } -ErrorAction Stop

            if ($result.ReturnValue -eq 0) {
                Write-LogMessage -Message "[OK] Restore point created successfully" -Color $script:colors.Success -Type 'BACKUP'
            } else {
                throw "WMI Return code: $($result.ReturnValue)"
            }
        } catch {
            Write-LogMessage -Message "[X] Failed to create restore point: $($_.Exception.Message)" -Color $script:colors.Error -Type 'ERROR'
            Write-LogMessage -Message "Continuing without restore point..." -Color $script:colors.Warning -Type 'WARN'
        }
    }
}
#endregion

#region Core Removal Functions
function Remove-ItemSafely {
    [CmdletBinding(SupportsShouldProcess)]
    param($Path, $Description, $Type = 'File')

    if (-not (Test-Path $Path)) { return }
    if (-not (Test-PathSafe $Path)) { $script:config.ItemsSkipped++; return }

    if (-not $IncludeNetworkDrives -and (Test-IsNetworkPath $Path)) {
        Write-LogMessage -Message "Skipping network path: $Path" -Color $script:colors.Warning -Type 'SKIP'
        $script:config.ItemsSkipped++
        return
    }

    # Calculate size before removal (for metrics)
    $sizeBytes = Get-SafeFolderSize $Path
    Add-Finding -Type $Type -Name $Description -Path $Path -SizeBytes $sizeBytes

    # Display found message with size
    if ($sizeBytes -gt 0) {
        Write-LogMessage -Message "Found: $Description ($(Format-FileSize $sizeBytes))" -Color $script:colors.Found -Type 'FOUND'
    } else {
        Write-LogMessage -Message "Found: $Description" -Color $script:colors.Found -Type 'FOUND'
    }

    if ($ScanOnly) { return }

    try {
        if ($PSCmdlet.ShouldProcess($Path, "Remove $Type")) {
            if (Test-Path $Path -PathType Leaf) {
                (Get-Item $Path -Force).IsReadOnly = $false
            }

            $item = Get-Item -Path $Path -Force -ErrorAction Stop
            if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                if ($item.PSIsContainer) {
                    [System.IO.Directory]::Delete($Path, $false)
                    Write-LogMessage -Message "  [OK] Removed (junction/symlink)" -Color $script:colors.Success -Type 'REMOVE'
                } else {
                    Remove-Item -Path $Path -Force -ErrorAction Stop
                    Write-LogMessage -Message "  [OK] Removed (symlink)" -Color $script:colors.Success -Type 'REMOVE'
                }
            } else {
                try {
                    # Check if this is a large directory (show progress indicator)
                    if (Test-Path $Path -PathType Container) {
                        $itemCount = 0
                        try {
                            Write-LogMessage -Message "  Counting items..." -Color $script:colors.Info -Type 'INFO'
                            $itemCount = (Get-ChildItem -Path $Path -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object).Count
                            if ($itemCount -gt 1000) {
                                Write-LogMessage -Message "  Removing $itemCount items (this may take a while)..." -Color $script:colors.Warning -Type 'INFO'
                            }
                        } catch { }
                    }

                    Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
                    Write-LogMessage -Message "  [OK] Removed" -Color $script:colors.Success -Type 'REMOVE'
                } catch [System.IO.PathTooLongException] {
                    $longPath = "\\?\$($Path.TrimStart('\\?\'))"
                    [System.IO.Directory]::Delete($longPath, $true)
                    Write-LogMessage -Message "  [OK] Removed (long path)" -Color $script:colors.Success -Type 'REMOVE'
                } catch [System.UnauthorizedAccessException] {
                    if (Test-Path $Path -PathType Container) {
                        Get-ChildItem -Path $Path -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
                            $_.IsReadOnly = $false
                        }
                        Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
                        Write-LogMessage -Message "  [OK] Removed (after clearing readonly)" -Color $script:colors.Success -Type 'REMOVE'
                    } else {
                        throw
                    }
                }
            }
            $script:config.ItemsRemoved++
            $script:config.TotalSize += $sizeBytes
        }
    } catch {
        Write-LogMessage -Message "  [X] Failed: $($_.Exception.Message)" -Color $script:colors.Error -Type 'ERROR'
        $script:config.ItemsFailed++
    }
}

function Uninstall-StorePython {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    Write-LogMessage -Message "`n=== MICROSOFT STORE PYTHON ===" -Color $script:colors.Header -Type 'SECTION'

    try {
        $packages = Get-AppxPackage | Where-Object {
            $_.Name -like '*Python*' -or ($_.PSObject.Properties['PublisherDisplayName'] -and $_.PublisherDisplayName -eq 'Python Software Foundation')
        }

        if ($packages) {
            foreach ($package in $packages) {
                Add-Finding -Type 'AppX' -Name $package.Name -Path $package.InstallLocation
                Write-LogMessage -Message "Found Store App: $($package.Name)" -Color $script:colors.Found -Type 'FOUND'

                if (-not $ScanOnly -and $PSCmdlet.ShouldProcess($package.Name, "Uninstall Store App")) {
                    try {
                        Remove-AppxPackage -Package $package.PackageFullName -ErrorAction Stop
                        Write-LogMessage -Message "  [OK] AppX Removed" -Color $script:colors.Success -Type 'REMOVE'
                        $script:config.ItemsRemoved++
                    } catch {
                        Write-LogMessage -Message "  [X] Failed: $($_.Exception.Message)" -Color $script:colors.Error -Type 'ERROR'
                        $script:config.ItemsFailed++
                    }
                }
            }
        }
    } catch {
        Write-LogMessage -Message "Error checking AppX: $($_.Exception.Message)" -Color $script:colors.Error -Type 'ERROR'
    }
}

function Uninstall-TraditionalPython {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    Write-LogMessage -Message "`n=== TRADITIONAL INSTALLATIONS ===" -Color $script:colors.Header -Type 'SECTION'

    if (-not $ScanOnly) {
        Write-LogMessage -Message "Note: MSI component dependency failures (exit 1603) are expected and will be cleaned via orphaned registry entry removal" -Color $script:colors.Info -Type 'INFO'
    }

    $uninstallPaths = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $installs = Get-ItemProperty $uninstallPaths -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.DisplayName -match '\b(Python|Anaconda|Miniconda|Mamba|pyenv|astral|^uv$)\b' -and
                    $_.DisplayName -notmatch 'Visual Studio|PyCharm|VS Code|IntelliJ|Rider|Eclipse|NetBeans|Boost|Iron|Crypto'
                } | Sort-Object DisplayName -Unique

    foreach ($install in $installs) {
        $name = $install.DisplayName
        Add-Finding -Type 'Program' -Name $name -Path $install.InstallLocation
        Write-LogMessage -Message "Found Program: $name" -Color $script:colors.Found -Type 'FOUND'

        if (-not $ScanOnly -and $install.UninstallString) {
            if ($PSCmdlet.ShouldProcess($name, "Uninstall Program")) {
                $cmdOriginal = $install.UninstallString
                $cmd = $cmdOriginal.Trim()
                $uninstallSuccess = $false

                if ($cmd -match 'MsiExec') {
                    if ($cmd -match '\{[A-F0-9-]+\}') {
                        $code = $matches[0]
                        Write-LogMessage -Message "  Running MSI Uninstall for $code..." -Color $script:colors.Info -Type 'INFO'

                        # Try up to 2 times for transient errors (1618 = another install in progress)
                        $maxAttempts = 2
                        $attemptNum = 0
                        $lastExitCode = 0

                        while ($attemptNum -lt $maxAttempts -and -not $uninstallSuccess) {
                            $attemptNum++
                            try {
                                $proc = Start-Process 'MsiExec.exe' -ArgumentList "/X $code /qn /norestart" -PassThru -NoNewWindow
                                $timeoutMs = $script:config.TimeoutSeconds * 1000
                                if ($proc.WaitForExit($timeoutMs)) {
                                    $lastExitCode = $proc.ExitCode
                                    if ($proc.ExitCode -in @(0, 3010)) {
                                        $uninstallSuccess = $true
                                        Write-LogMessage -Message "  [OK] MSI Uninstalled (exit code: $($proc.ExitCode))" -Color $script:colors.Success -Type 'REMOVE'
                                        $script:config.ItemsRemoved++
                                    } elseif ($proc.ExitCode -eq 1618 -and $attemptNum -lt $maxAttempts) {
                                        # Another installation in progress - retry after delay
                                        Write-LogMessage -Message "  [!] Another installation in progress, retrying in 5 seconds..." -Color $script:colors.Warning -Type 'INFO'
                                        Start-Sleep -Seconds 5
                                    } else {
                                        # Non-retriable error or max attempts reached
                                        break
                                    }
                                } else {
                                    $proc.Kill()
                                    Write-LogMessage -Message "  [X] MSI timeout after $($script:config.TimeoutSeconds)s" -Color $script:colors.Error -Type 'ERROR'
                                    $script:config.ItemsFailed++
                                    break
                                }
                            } catch {
                                Write-LogMessage -Message "  [X] MSI error: $($_.Exception.Message)" -Color $script:colors.Error -Type 'ERROR'
                                $script:config.ItemsFailed++
                                break
                            }
                        }

                        # If still not successful after retries, log the final error
                        if (-not $uninstallSuccess -and $lastExitCode -ne 0) {
                            $errorDetail = switch ($lastExitCode) {
                                1601 { "Windows Installer service not accessible or access denied" }
                                1602 { "User cancelled installation" }
                                1603 { "Fatal error during installation/uninstallation" }
                                1605 { "Product not found or already uninstalled" }
                                1618 { "Another installation is in progress (tried $attemptNum times)" }
                                1619 { "Failed to open installation package" }
                                1633 { "Platform not supported (x86/x64 mismatch)" }
                                default { "Unknown MSI error" }
                            }
                            Write-LogMessage -Message "  [X] MSI failed (exit code: $lastExitCode) - $errorDetail" -Color $script:colors.Error -Type 'ERROR'
                            $script:config.ItemsFailed++
                        }
                    }
                } elseif ($install.UninstallString -match '\.exe') {
                    Write-LogMessage -Message "  Attempting EXE uninstall: $cmdOriginal" -Color $script:colors.Info -Type 'INFO'

                    # Extract executable path - handle quoted paths with spaces
                    $exePath = $null
                    if ($cmd -match '^"([^"]+\.exe)"') {
                        # Quoted path: "C:\Path With Spaces\installer.exe" /args
                        $exePath = $matches[1]
                    } elseif ($cmd -match '^([^"\s]+\.exe)') {
                        # Unquoted path (no spaces): C:\Path\installer.exe /args
                        $exePath = $matches[1]
                    } else {
                        # Fallback: try to find .exe in the string
                        if ($cmd -match '([A-Z]:\\[^"]*?\.exe)') {
                            $exePath = $matches[1]
                        }
                    }

                    if (-not $exePath) {
                        Write-LogMessage -Message "  [!] Could not extract EXE path from: $cmd" -Color $script:colors.Warning -Type 'WARN'
                        $script:config.ItemsSkipped++
                    } elseif (Test-Path $exePath) {
                        $silentArgs = @('/uninstall', '/S', '/SILENT', '/quiet', '/VERYSILENT', '-uninstall')
                        $attemptCount = 0
                        foreach ($arg in $silentArgs) {
                            $attemptCount++
                            try {
                                Write-LogMessage -Message "  Trying silent flag: $arg (attempt $attemptCount/$($silentArgs.Count))" -Color $script:colors.Info -Type 'INFO'
                                $proc = Start-Process $exePath -ArgumentList $arg -PassThru -NoNewWindow -ErrorAction Stop
                                if ($proc.WaitForExit(120000)) {
                                    if ($proc.ExitCode -eq 0) {
                                        $uninstallSuccess = $true
                                        Write-LogMessage -Message "  [OK] EXE Uninstalled with $arg (exit code: 0)" -Color $script:colors.Success -Type 'REMOVE'
                                        $script:config.ItemsRemoved++
                                        break
                                    } else {
                                        Write-LogMessage -Message "  [!] Failed with $arg (exit code: $($proc.ExitCode))" -Color $script:colors.Warning -Type 'INFO'
                                    }
                                } else {
                                    $proc.Kill()
                                    Write-LogMessage -Message "  [!] Timeout with $arg after 120s" -Color $script:colors.Warning -Type 'INFO'
                                }
                            } catch {
                                Write-LogMessage -Message "  [!] Error with ${arg}: $($_.Exception.Message)" -Color $script:colors.Warning -Type 'INFO'
                                continue
                            }
                        }
                        if (-not $uninstallSuccess) {
                            Write-LogMessage -Message "  [X] EXE auto-uninstall failed - may require manual removal" -Color $script:colors.Error -Type 'ERROR'
                            Write-LogMessage -Message "  Manual uninstall command: $cmdOriginal" -Color $script:colors.Info -Type 'MANUAL'
                            $script:config.ItemsFailed++
                        }
                    } else {
                        Write-LogMessage -Message "  [!] EXE uninstaller not found: $exePath" -Color $script:colors.Warning -Type 'WARN'
                        $script:config.ItemsSkipped++
                    }
                } else {
                    Write-LogMessage -Message "  [!] Unknown uninstaller format: $cmd" -Color $script:colors.Warning -Type 'WARN'
                    Write-LogMessage -Message "  Manual uninstall may be required" -Color $script:colors.Info -Type 'MANUAL'
                    $script:config.ItemsSkipped++
                }
            }
        }
    }
}

function Remove-PythonDirectory {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    Write-LogMessage -Message "`n=== PYTHON DIRECTORIES ===" -Color $script:colors.Header -Type 'SECTION'

    $globs = @(
        # === Core Python Installations ===
        "$env:LOCALAPPDATA\Programs\Python*",
        "$env:ProgramFiles\Python*",
        "${env:ProgramFiles(x86)}\Python*",
        "C:\Python*",

        # === Anaconda/Conda Distributions ===
        "$env:USERPROFILE\Anaconda*",
        "$env:USERPROFILE\Miniconda*",
        "$env:USERPROFILE\Mambaforge*",
        "$env:USERPROFILE\Miniforge*",
        "$env:ProgramData\Anaconda*",
        "$env:ProgramData\Miniconda*",
        "$env:ProgramData\Mambaforge*",
        "$env:ProgramData\Miniforge*",
        "$env:LOCALAPPDATA\Continuum",
        "$env:USERPROFILE\.continuum",
        "$env:USERPROFILE\.conda",
        "$env:USERPROFILE\.condarc",
        "$env:APPDATA\conda",
        "$env:LOCALAPPDATA\conda",

        # === Python Version Managers ===
        "$env:USERPROFILE\.pyenv",
        "$env:USERPROFILE\.pythonz",
        "$env:USERPROFILE\.python-build",

        # === Package Managers & Tools ===
        # pip
        "$env:APPDATA\Python",
        "$env:LOCALAPPDATA\pip",
        "$env:APPDATA\pip",
        "$env:USERPROFILE\.cache\pip",
        "$env:LOCALAPPDATA\pip-cache",

        # UV (Astral)
        "$env:USERPROFILE\.uv",
        "$env:LOCALAPPDATA\uv",
        "$env:APPDATA\uv",
        "$env:USERPROFILE\.cache\uv",
        "$env:LOCALAPPDATA\astral",
        "$env:APPDATA\astral",
        "$env:USERPROFILE\.astral",

        # Poetry
        "$env:APPDATA\pypoetry",
        "$env:LOCALAPPDATA\pypoetry",
        "$env:USERPROFILE\.poetry",
        "$env:APPDATA\poetry",
        "$env:USERPROFILE\.cache\poetry",
        "$env:USERPROFILE\.cache\pypoetry",

        # PDM
        "$env:USERPROFILE\.pdm",
        "$env:LOCALAPPDATA\pdm",
        "$env:USERPROFILE\.cache\pdm",

        # Rye
        "$env:USERPROFILE\.rye",
        "$env:USERPROFILE\.cache\rye",

        # Hatch
        "$env:LOCALAPPDATA\hatch",
        "$env:USERPROFILE\.cache\hatch",

        # pipx
        "$env:USERPROFILE\.local\pipx",
        "$env:LOCALAPPDATA\pipx",
        "$env:USERPROFILE\.cache\pipx",
        "$env:USERPROFILE\.local\share\pipx",

        # virtualenv/virtualenvwrapper
        "$env:USERPROFILE\.virtualenvs",
        "$env:USERPROFILE\.virtualenv",

        # Pipenv
        "$env:USERPROFILE\.local\share\virtualenvs",

        # === Jupyter & IPython ===
        "$env:USERPROFILE\.jupyter",
        "$env:USERPROFILE\.ipython",
        "$env:APPDATA\jupyter",
        "$env:APPDATA\IPython",
        "$env:LOCALAPPDATA\Jupyter",
        "$env:LOCALAPPDATA\JupyterLab",
        "$env:APPDATA\jupyterlab-desktop",
        "$env:USERPROFILE\.jupyter-desktop",

        # === Code Quality Tools Caches ===
        "$env:USERPROFILE\.mypy_cache",
        "$env:USERPROFILE\.pytest_cache",
        "$env:USERPROFILE\.ruff_cache",
        "$env:USERPROFILE\.ruff",
        "$env:USERPROFILE\.pylint.d",
        "$env:USERPROFILE\.black",
        "$env:USERPROFILE\.tox",
        "$env:USERPROFILE\.nox",

        # === Python Eggs & Build Artifacts ===
        "$env:USERPROFILE\.python-eggs",

        # === Microsoft Store Python ===
        "$env:LOCALAPPDATA\Packages\PythonSoftwareFoundation*",
        "$env:LOCALAPPDATA\Microsoft\WindowsApps\PythonSoftwareFoundation*",

        # === Start Menu Shortcuts ===
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Python*",
        "$env:PROGRAMDATA\Microsoft\Windows\Start Menu\Programs\Python*",
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Anaconda*",
        "$env:PROGRAMDATA\Microsoft\Windows\Start Menu\Programs\Anaconda*",
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Miniconda*",
        "$env:PROGRAMDATA\Microsoft\Windows\Start Menu\Programs\Miniconda*"
    )

    foreach ($glob in $globs) {
        $parent = Split-Path $glob -Parent
        $leaf = Split-Path $glob -Leaf
        if (Test-Path $parent) {
            Get-ChildItem -Path $parent -Filter $leaf -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                Remove-ItemSafely -Path $_.FullName -Description "Directory: $($_.Name)" -Type 'Directory'
            }
        }
    }

    # === Individual Config Files ===
    Write-LogMessage -Message "`n=== CONFIG FILES ===" -Color $script:colors.Header -Type 'SECTION'

    $configFiles = @(
        "$env:USERPROFILE\.condarc",
        "$env:USERPROFILE\.python-version",
        "$env:USERPROFILE\.python_history",
        "$env:USERPROFILE\.pypirc",
        "$env:USERPROFILE\.pydistutils.cfg",
        "$env:APPDATA\pip\pip.ini",
        "$env:USERPROFILE\pip\pip.ini"
    )

    $configFilesFound = 0
    foreach ($file in $configFiles) {
        if (Test-Path $file) {
            $configFilesFound++
            $fileName = Split-Path $file -Leaf
            Write-LogMessage -Message "Found Config File: $fileName" -Color $script:colors.Found -Type 'FOUND'
            if (-not $ScanOnly -and $PSCmdlet.ShouldProcess($file, "Remove Config File")) {
                try {
                    Remove-Item -Path $file -Force -ErrorAction Stop
                    Write-LogMessage -Message "  [OK] Removed" -Color $script:colors.Success -Type 'REMOVE'
                    $script:config.ItemsRemoved++
                } catch {
                    Write-LogMessage -Message "  [X] Failed: $($_.Exception.Message)" -Color $script:colors.Error -Type 'ERROR'
                    $script:config.ItemsFailed++
                }
            }
        }
    }

    if ($configFilesFound -eq 0) {
        Write-LogMessage -Message "No Python config files found" -Color $script:colors.Info -Type 'INFO'
    }

    # === Desktop Shortcuts ===
    Write-LogMessage -Message "`n=== DESKTOP SHORTCUTS ===" -Color $script:colors.Header -Type 'SECTION'

    $desktopPaths = @(
        "$env:USERPROFILE\Desktop",
        "$env:PUBLIC\Desktop"
    )

    $shortcutsFound = 0
    foreach ($desktopPath in $desktopPaths) {
        if (Test-Path $desktopPath) {
            $shortcuts = @()
            $shortcuts += Get-ChildItem -Path $desktopPath -Filter "Python*.lnk" -ErrorAction SilentlyContinue
            $shortcuts += Get-ChildItem -Path $desktopPath -Filter "Anaconda*.lnk" -ErrorAction SilentlyContinue
            $shortcuts += Get-ChildItem -Path $desktopPath -Filter "Jupyter*.lnk" -ErrorAction SilentlyContinue
            $shortcuts += Get-ChildItem -Path $desktopPath -Filter "IDLE*.lnk" -ErrorAction SilentlyContinue

            foreach ($shortcut in $shortcuts) {
                $shortcutsFound++
                Write-LogMessage -Message "Found Desktop Shortcut: $($shortcut.Name)" -Color $script:colors.Found -Type 'FOUND'
                if (-not $ScanOnly -and $PSCmdlet.ShouldProcess($shortcut.FullName, "Remove Shortcut")) {
                    try {
                        Remove-Item -Path $shortcut.FullName -Force -ErrorAction Stop
                        Write-LogMessage -Message "  [OK] Removed" -Color $script:colors.Success -Type 'REMOVE'
                        $script:config.ItemsRemoved++
                    } catch {
                        Write-LogMessage -Message "  [X] Failed: $($_.Exception.Message)" -Color $script:colors.Error -Type 'ERROR'
                        $script:config.ItemsFailed++
                    }
                }
            }
        }
    }

    if ($shortcutsFound -eq 0) {
        Write-LogMessage -Message "No Python desktop shortcuts found" -Color $script:colors.Info -Type 'INFO'
    }

    # === Temp Files & Installer Cache ===
    Write-LogMessage -Message "`n=== TEMP FILES & CACHE ===" -Color $script:colors.Header -Type 'SECTION'

    $tempLocations = @(
        @{ Path = "$env:TEMP"; Pattern = "pip-*" },
        @{ Path = "$env:TEMP"; Pattern = "easy_install-*" },
        @{ Path = "$env:TEMP"; Pattern = "Python*" },
        @{ Path = "$env:LOCALAPPDATA\Package Cache"; Pattern = "*python*" }
    )

    $tempFilesFound = 0
    foreach ($location in $tempLocations) {
        if (Test-Path $location.Path) {
            $items = Get-ChildItem -Path $location.Path -Filter $location.Pattern -Force -ErrorAction SilentlyContinue
            foreach ($item in $items) {
                # Additional safety check for temp files - only delete if older than 1 day
                if ($item.PSIsContainer) {
                    $isOld = (Get-Date) - $item.LastWriteTime -gt [TimeSpan]::FromDays(1)
                    if ($isOld -or $location.Path -like "*Package Cache*") {
                        $tempFilesFound++
                        Write-LogMessage -Message "Found Temp/Cache: $($item.Name)" -Color $script:colors.Found -Type 'FOUND'
                        if (-not $ScanOnly -and $PSCmdlet.ShouldProcess($item.FullName, "Remove Temp/Cache")) {
                            try {
                                Remove-Item -Path $item.FullName -Recurse -Force -ErrorAction Stop
                                Write-LogMessage -Message "  [OK] Removed" -Color $script:colors.Success -Type 'REMOVE'
                                $script:config.ItemsRemoved++
                            } catch {
                                Write-LogMessage -Message "  [X] Failed: $($_.Exception.Message)" -Color $script:colors.Error -Type 'ERROR'
                                $script:config.ItemsFailed++
                            }
                        }
                    }
                }
            }
        }
    }

    if ($tempFilesFound -eq 0) {
        Write-LogMessage -Message "No Python temp files or cache to clean (or all files <1 day old)" -Color $script:colors.Info -Type 'INFO'
    }
}

function Remove-VirtualEnvironment {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    Write-LogMessage -Message "`n=== VIRTUAL ENVIRONMENTS ===" -Color $script:colors.Header -Type 'SECTION'

    $scanRoot = $env:USERPROFILE
    Write-LogMessage -Message "Scanning $scanRoot (Depth: $($script:config.MaxDepth))..." -Color $script:colors.Info -Type 'SCAN'

    try {
        $dirs = Get-ChildItem -Path $scanRoot -Directory -Recurse -Depth $script:config.MaxDepth -ErrorAction Ignore -Force
        Write-LogMessage -Message "Scanned $($dirs.Count) directories" -Color $script:colors.Info -Type 'INFO'

        # Standard Python virtual environments
        $venvs = $dirs | Where-Object {
            ($_.Name -in @('.venv', 'venv', 'env')) -and
            ((Test-Path "$($_.FullName)\Scripts\activate") -or (Test-Path "$($_.FullName)\bin\activate"))
        }

        foreach ($venv in $venvs) {
            Remove-ItemSafely -Path $venv.FullName -Description "Venv: $($venv.FullName)" -Type 'VirtualEnv'
        }

        # Conda environments (look for conda-meta directory)
        $condaEnvs = $dirs | Where-Object {
            (Test-Path "$($_.FullName)\conda-meta") -and
            $_.FullName -notmatch '(Anaconda|Miniconda|Mambaforge|Miniforge)\\envs\\base'  # Skip base environment
        }

        foreach ($condaEnv in $condaEnvs) {
            Remove-ItemSafely -Path $condaEnv.FullName -Description "Conda Env: $($condaEnv.Name)" -Type 'CondaEnv'
        }

        # Poetry environments (typically in virtualenvs directory, but also in cache)
        $poetryEnvPattern = '*-py*'
        $poetryEnvs = @()
        if (Test-Path "$env:LOCALAPPDATA\pypoetry\Cache\virtualenvs") {
            $poetryEnvs = Get-ChildItem -Path "$env:LOCALAPPDATA\pypoetry\Cache\virtualenvs" -Filter $poetryEnvPattern -Directory -ErrorAction SilentlyContinue
            foreach ($poetryEnv in $poetryEnvs) {
                Remove-ItemSafely -Path $poetryEnv.FullName -Description "Poetry Env: $($poetryEnv.Name)" -Type 'PoetryEnv'
            }
        }

        # Pipenv environments
        $pipenvEnvs = @()
        if (Test-Path "$env:USERPROFILE\.local\share\virtualenvs") {
            $pipenvEnvs = Get-ChildItem -Path "$env:USERPROFILE\.local\share\virtualenvs" -Directory -ErrorAction SilentlyContinue
            foreach ($pipenvEnv in $pipenvEnvs) {
                Remove-ItemSafely -Path $pipenvEnv.FullName -Description "Pipenv Env: $($pipenvEnv.Name)" -Type 'PipenvEnv'
            }
        }

        # Summary
        $totalEnvs = $venvs.Count + $condaEnvs.Count + $poetryEnvs.Count + $pipenvEnvs.Count
        if ($totalEnvs -eq 0) {
            Write-LogMessage -Message "No virtual environments found" -Color $script:colors.Info -Type 'INFO'
        } else {
            Write-LogMessage -Message "Found $totalEnvs virtual environment(s): $($venvs.Count) venv, $($condaEnvs.Count) conda, $($poetryEnvs.Count) poetry, $($pipenvEnvs.Count) pipenv" -Color $script:colors.Info -Type 'INFO'
        }
    } catch {
        Write-LogMessage -Message "Scan interrupted: $($_.Exception.Message)" -Color $script:colors.Info -Type 'INFO'
    }
}

function Remove-EnvironmentVariable {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    Write-LogMessage -Message "`n=== ENVIRONMENT VARIABLES ===" -Color $script:colors.Header -Type 'SECTION'

    if (-not $ScanOnly) {
        try {
            $backup = @{
                Timestamp    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                Variables    = @{}
                PATH_User    = [Environment]::GetEnvironmentVariable('Path', 'User')
                PATH_Machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
            }
            foreach ($var in $script:pythonVariables) {
                foreach ($scope in 'User', 'Machine') {
                    $val = [Environment]::GetEnvironmentVariable($var, $scope)
                    if ($val) {
                        $backup.Variables["${var}_${scope}"] = $val
                    }
                }
            }
            $backup | ConvertTo-Json -Depth 3 | Set-Content -Path $script:config.BackupFile -ErrorAction Stop
            Write-LogMessage -Message "Backup saved: $($script:config.BackupFile)" -Color $script:colors.Success -Type 'BACKUP'
        } catch {
            Write-LogMessage -Message "Warning: Backup failed: $($_.Exception.Message)" -Color $script:colors.Warning -Type 'WARN'
        }
    }

    foreach ($var in $script:pythonVariables) {
        foreach ($scope in 'User', 'Machine') {
            if ([Environment]::GetEnvironmentVariable($var, $scope)) {
                Write-LogMessage -Message "Found Variable: $var ($scope)" -Color $script:colors.Found -Type 'FOUND'
                if (-not $ScanOnly -and $PSCmdlet.ShouldProcess("Environment Variable: $var ($scope)", "Remove")) {
                    try {
                        [Environment]::SetEnvironmentVariable($var, $null, $scope)
                        Write-LogMessage -Message "  [OK] Removed" -Color $script:colors.Success -Type 'REMOVE'
                        $script:config.ItemsRemoved++
                    } catch {
                        Write-LogMessage -Message "  [X] Failed: $($_.Exception.Message)" -Color $script:colors.Error -Type 'ERROR'
                        $script:config.ItemsFailed++
                    }
                }
            }
        }
    }

    foreach ($scope in 'User', 'Machine') {
        $path = [Environment]::GetEnvironmentVariable('Path', $scope)
        if ($path) {
            $parts = $path -split ';'
            $newParts = $parts | Where-Object { $_ -notmatch $script:pythonPatterns.PathEntries }

            if ($parts.Count -ne $newParts.Count) {
                $removedCount = $parts.Count - $newParts.Count
                Write-LogMessage -Message "Cleaning $scope PATH ($removedCount entries)..." -Color $script:colors.Info -Type 'INFO'
                if (-not $ScanOnly -and $PSCmdlet.ShouldProcess("Path ($scope)", "Clean")) {
                    try {
                        [Environment]::SetEnvironmentVariable('Path', ($newParts -join ';'), $scope)
                        Write-LogMessage -Message "  [OK] Path Cleaned" -Color $script:colors.Success -Type 'REMOVE'
                        $script:config.ItemsRemoved++
                    } catch {
                        Write-LogMessage -Message "  [X] Failed: $($_.Exception.Message)" -Color $script:colors.Error -Type 'ERROR'
                        $script:config.ItemsFailed++
                    }
                }
            }
        }
    }
}

function Clear-Registry {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    Write-LogMessage -Message "`n=== REGISTRY CLEANUP ===" -Color $script:colors.Header -Type 'SECTION'

    # Core Python installation keys
    $keys = @(
        # Python core
        'HKCU:\Software\Python',
        'HKLM:\Software\Python',
        'HKCU:\Software\Wow6432Node\Python',
        'HKLM:\Software\Wow6432Node\Python',

        # Python Software Foundation
        'HKCU:\Software\Python Software Foundation',
        'HKLM:\Software\Python Software Foundation',
        'HKLM:\Software\Wow6432Node\Python Software Foundation',

        # Anaconda/Conda variants
        'HKCU:\Software\Anaconda',
        'HKLM:\Software\Anaconda',
        'HKLM:\Software\Wow6432Node\Anaconda',
        'HKCU:\Software\Miniconda',
        'HKLM:\Software\Miniconda',
        'HKCU:\Software\Mambaforge',
        'HKLM:\Software\Mambaforge',
        'HKCU:\Software\Miniforge',
        'HKLM:\Software\Miniforge',
        'HKCU:\Software\Continuum Analytics',
        'HKLM:\Software\Continuum Analytics',

        # Package managers
        'HKCU:\Software\Poetry',
        'HKLM:\Software\Poetry',
        'HKCU:\Software\pyenv',
        'HKLM:\Software\pyenv'
    )

    foreach ($key in $keys) {
        if (Test-Path $key) {
            Write-LogMessage -Message "Found Registry Key: $key" -Color $script:colors.Found -Type 'FOUND'
            if (-not $ScanOnly -and $PSCmdlet.ShouldProcess($key, "Remove Registry Key")) {
                try {
                    Remove-Item -Path $key -Recurse -Force -ErrorAction Stop
                    Write-LogMessage -Message "  [OK] Removed" -Color $script:colors.Success -Type 'REMOVE'
                    $script:config.ItemsRemoved++
                } catch {
                    Write-LogMessage -Message "  [X] Failed: $($_.Exception.Message)" -Color $script:colors.Error -Type 'ERROR'
                    $script:config.ItemsFailed++
                }
            }
        }
    }

    # File type associations
    $assocKeys = @(
        # Python file extensions
        'HKCU:\Software\Classes\.py',
        'HKCU:\Software\Classes\.pyw',
        'HKCU:\Software\Classes\.pyc',
        'HKCU:\Software\Classes\.pyo',
        'HKCU:\Software\Classes\.pyd',
        'HKCU:\Software\Classes\.pyi',
        'HKCU:\Software\Classes\.pyz',
        'HKCU:\Software\Classes\.pyzw',
        'HKCU:\Software\Classes\.pth',
        'HKCU:\Software\Classes\.whl',

        # Jupyter/IPython
        'HKCU:\Software\Classes\.ipynb',

        # Python file type handlers
        'HKCU:\Software\Classes\py_auto_file',
        'HKCU:\Software\Classes\pyw_auto_file',
        'HKCU:\Software\Classes\pyc_auto_file',
        'HKCU:\Software\Classes\Python.File',
        'HKCU:\Software\Classes\Python.CompiledFile',
        'HKCU:\Software\Classes\Python.NoConFile',
        'HKCU:\Software\Classes\Python.ArchiveFile',

        # Application associations
        'HKCU:\Software\Classes\Applications\python.exe',
        'HKCU:\Software\Classes\Applications\pythonw.exe',
        'HKCU:\Software\Classes\Applications\py.exe',
        'HKCU:\Software\Classes\Applications\pyw.exe',
        'HKCU:\Software\Classes\Applications\idle.exe',
        'HKCU:\Software\Classes\Applications\ipython.exe'
    )

    foreach ($key in $assocKeys) {
        if (Test-Path $key) {
            Write-LogMessage -Message "Found File Association: $key" -Color $script:colors.Found -Type 'FOUND'
            if (-not $ScanOnly -and $PSCmdlet.ShouldProcess($key, "Remove File Association")) {
                try {
                    Remove-Item -Path $key -Recurse -Force -ErrorAction Stop
                    Write-LogMessage -Message "  [OK] Removed" -Color $script:colors.Success -Type 'REMOVE'
                    $script:config.ItemsRemoved++
                } catch {
                    Write-LogMessage -Message "  [X] Failed: $($_.Exception.Message)" -Color $script:colors.Error -Type 'ERROR'
                    $script:config.ItemsFailed++
                }
            }
        }
    }

    # App Paths
    $appPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\python.exe',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\pythonw.exe',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\py.exe',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\pyw.exe',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\idle.exe',
        'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\App Paths\python.exe',
        'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\App Paths\pythonw.exe'
    )

    foreach ($key in $appPaths) {
        if (Test-Path $key) {
            Write-LogMessage -Message "Found App Path: $key" -Color $script:colors.Found -Type 'FOUND'
            if (-not $ScanOnly -and $PSCmdlet.ShouldProcess($key, "Remove App Path")) {
                try {
                    Remove-Item -Path $key -Force -ErrorAction Stop
                    Write-LogMessage -Message "  [OK] Removed" -Color $script:colors.Success -Type 'REMOVE'
                    $script:config.ItemsRemoved++
                } catch {
                    Write-LogMessage -Message "  [X] Failed: $($_.Exception.Message)" -Color $script:colors.Error -Type 'ERROR'
                    $script:config.ItemsFailed++
                }
            }
        }
    }

    # Clean up orphaned uninstall registry entries
    $uninstallPaths = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
    )

    foreach ($uninstallPath in $uninstallPaths) {
        if (Test-Path $uninstallPath) {
            try {
                $entries = Get-ChildItem -Path $uninstallPath -ErrorAction SilentlyContinue
                foreach ($entry in $entries) {
                    try {
                        $props = Get-ItemProperty -Path $entry.PSPath -ErrorAction SilentlyContinue
                        if ($props.DisplayName -match '\b(Python|Anaconda|Miniconda|Mamba|pyenv|astral|^uv$)\b' -and
                            $props.DisplayName -notmatch 'Visual Studio|PyCharm|VS Code|IntelliJ|Rider|Eclipse|NetBeans|Boost|Iron|Crypto') {

                            # Check if installation location exists
                            $installExists = $false
                            if ($props.InstallLocation -and (Test-Path $props.InstallLocation)) {
                                $installExists = $true
                            }
                            if ($props.UninstallString -and $props.UninstallString -match '\.exe' -and (Test-Path ($props.UninstallString.Trim('"') -replace '\s.*$', ''))) {
                                $installExists = $true
                            }

                            # Remove orphaned entries (installation no longer exists)
                            if (-not $installExists) {
                                Add-Finding -Type 'Registry' -Name "Orphaned: $($props.DisplayName)" -Path $entry.PSPath -Status 'Found'
                                Write-LogMessage -Message "Found Orphaned Uninstall Entry: $($props.DisplayName)" -Color $script:colors.Found -Type 'FOUND'
                                if (-not $ScanOnly -and $PSCmdlet.ShouldProcess($entry.PSPath, "Remove Orphaned Uninstall Entry")) {
                                    try {
                                        Remove-Item -Path $entry.PSPath -Recurse -Force -ErrorAction Stop
                                        Write-LogMessage -Message "  [OK] Removed" -Color $script:colors.Success -Type 'REMOVE'
                                        $script:config.ItemsRemoved++
                                    } catch {
                                        Write-LogMessage -Message "  [X] Failed: $($_.Exception.Message)" -Color $script:colors.Error -Type 'ERROR'
                                        $script:config.ItemsFailed++
                                    }
                                }
                            }
                        }
                    } catch {
                        continue
                    }
                }
            } catch {
                Write-LogMessage -Message "Unable to scan $uninstallPath : $($_.Exception.Message)" -Color $script:colors.Warning -Type 'WARN'
            }
        }
    }

    # Clean Python-related SharedDLLs entries
    $sharedDllPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\SharedDLLs'
    if (Test-Path $sharedDllPath) {
        try {
            $props = Get-ItemProperty -Path $sharedDllPath -ErrorAction SilentlyContinue
            foreach ($prop in $props.PSObject.Properties) {
                if ($prop.Name -match '(python|anaconda|miniconda|\.pyd)' -and $prop.Name -ne 'PSPath' -and $prop.Name -ne 'PSParentPath' -and $prop.Name -ne 'PSChildName' -and $prop.Name -ne 'PSDrive' -and $prop.Name -ne 'PSProvider') {
                    # Check if DLL still exists
                    if (-not (Test-Path $prop.Name)) {
                        Add-Finding -Type 'Registry' -Name "Orphaned DLL: $(Split-Path $prop.Name -Leaf)" -Path $prop.Name -Status 'Found'
                        Write-LogMessage -Message "Found Orphaned SharedDLL: $($prop.Name)" -Color $script:colors.Found -Type 'FOUND'
                        if (-not $ScanOnly -and $PSCmdlet.ShouldProcess($prop.Name, "Remove SharedDLL Entry")) {
                            try {
                                Remove-ItemProperty -Path $sharedDllPath -Name $prop.Name -Force -ErrorAction Stop
                                Write-LogMessage -Message "  [OK] Removed" -Color $script:colors.Success -Type 'REMOVE'
                                $script:config.ItemsRemoved++
                            } catch {
                                Write-LogMessage -Message "  [X] Failed: $($_.Exception.Message)" -Color $script:colors.Error -Type 'ERROR'
                                $script:config.ItemsFailed++
                            }
                        }
                    }
                }
            }
        } catch {
            Write-LogMessage -Message "Unable to scan SharedDLLs: $($_.Exception.Message)" -Color $script:colors.Warning -Type 'WARN'
        }
    }
}

function Test-RunningProcess {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if ($SkipProcessCheck) { return }
    Write-LogMessage -Message "`n=== PROCESS CHECK ===" -Color $script:colors.Header -Type 'SECTION'

    $procs = @(Get-Process | Where-Object {
        $_.ProcessName -match $script:pythonPatterns.ProcessNames -and
        $_.Id -gt 10  # Skip system processes (PID 0-10)
    })
    if ($procs.Count -gt 0) {
        Write-LogMessage -Message "Found $($procs.Count) Python processes." -Color $script:colors.Warning -Type 'WARN'
        if (-not $ScanOnly) {
            foreach ($proc in $procs) {
                if ($PSCmdlet.ShouldProcess("$($proc.ProcessName) (PID: $($proc.Id))", "Stop Process")) {
                    try {
                        $proc | Stop-Process -Force -ErrorAction Stop
                        Write-LogMessage -Message "  [OK] Terminated $($proc.ProcessName) (PID: $($proc.Id))" -Color $script:colors.Success -Type 'REMOVE'
                        $script:config.ItemsRemoved++
                    } catch {
                        Write-LogMessage -Message "  [X] Failed to stop $($proc.ProcessName) (PID: $($proc.Id)): $($_.Exception.Message)" -Color $script:colors.Error -Type 'ERROR'
                        $script:config.ItemsFailed++
                    }
                }
            }
        }
    }
}

function Remove-AppExecutionAlias {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    Write-LogMessage -Message "`n=== APP EXECUTION ALIASES ===" -Color $script:colors.Header -Type 'SECTION'
    $aliasPath = "$env:LOCALAPPDATA\Microsoft\WindowsApps"

    if (Test-Path $aliasPath) {
        $pythonAliases = @()
        $pythonAliases += Get-ChildItem -Path $aliasPath -Filter "python*.exe" -ErrorAction SilentlyContinue
        $pythonAliases += Get-ChildItem -Path $aliasPath -Filter "pip*.exe" -ErrorAction SilentlyContinue

        $aliasCount = 0
        foreach ($alias in $pythonAliases) {
            if ($alias.Length -le 1KB) {
                $aliasCount++
                Write-LogMessage -Message "Found App Alias: $($alias.Name)" -Color $script:colors.Found -Type 'FOUND'
                if (-not $ScanOnly -and $PSCmdlet.ShouldProcess($alias.FullName, "Remove App Alias")) {
                    try {
                        Remove-Item -Path $alias.FullName -Force -ErrorAction Stop
                        Write-LogMessage -Message "  [OK] Removed" -Color $script:colors.Success -Type 'REMOVE'
                        $script:config.ItemsRemoved++
                    } catch {
                        Write-LogMessage -Message "  [X] Failed: $($_.Exception.Message)" -Color $script:colors.Error -Type 'ERROR'
                        $script:config.ItemsFailed++
                    }
                }
            }
        }

        if ($aliasCount -eq 0) {
            Write-LogMessage -Message "No Python app aliases found" -Color $script:colors.Info -Type 'INFO'
        }
    }
}

function Test-PostRemoval {
    Write-LogMessage -Message "`n=== POST-REMOVAL VERIFICATION ===" -Color $script:colors.Header -Type 'SECTION'

    $pythonFound = $false
    $issuesFound = @()

    # Check if python is still in PATH
    try {
        $wherePython = where.exe python 2>$null
        if ($wherePython) {
            Write-LogMessage -Message "  [X] Python in PATH: $wherePython" -Color $script:colors.Error -Type 'VERIFY'
            $issuesFound += "Python executable in PATH: $wherePython"
            $pythonFound = $true
        } else {
            Write-LogMessage -Message "  [OK] No python.exe in PATH" -Color $script:colors.Success -Type 'VERIFY'
        }
    } catch {
        Write-LogMessage -Message "  [OK] No python.exe in PATH" -Color $script:colors.Success -Type 'VERIFY'
    }

    # Check for py launcher
    try {
        $wherePy = where.exe py 2>$null
        if ($wherePy) {
            Write-LogMessage -Message "  [X] py.exe in PATH: $wherePy" -Color $script:colors.Error -Type 'VERIFY'
            $issuesFound += "Python Launcher (py.exe) in PATH: $wherePy"
            $pythonFound = $true
        } else {
            Write-LogMessage -Message "  [OK] No py.exe in PATH" -Color $script:colors.Success -Type 'VERIFY'
        }
    } catch {
        Write-LogMessage -Message "  [OK] No py.exe in PATH" -Color $script:colors.Success -Type 'VERIFY'
    }

    # Comprehensive registry check
    $regKeys = @(
        'HKCU:\Software\Python',
        'HKLM:\Software\Python',
        'HKCU:\Software\Wow6432Node\Python',
        'HKLM:\Software\Wow6432Node\Python',
        'HKCU:\Software\Python Software Foundation',
        'HKLM:\Software\Python Software Foundation',
        'HKLM:\Software\Wow6432Node\Python Software Foundation',
        'HKCU:\Software\Anaconda',
        'HKLM:\Software\Anaconda',
        'HKCU:\Software\Miniconda',
        'HKLM:\Software\Miniconda'
    )

    $regKeysFound = 0
    foreach ($key in $regKeys) {
        if (Test-Path $key) {
            $issuesFound += "Registry key: $key"
            $pythonFound = $true
            $regKeysFound++
        }
    }
    if ($regKeysFound -eq 0) {
        Write-LogMessage -Message "  [OK] No registry keys ($($regKeys.Count) locations checked)" -Color $script:colors.Success -Type 'VERIFY'
    } else {
        Write-LogMessage -Message "  [X] Found $regKeysFound registry key(s)" -Color $script:colors.Error -Type 'VERIFY'
    }

    # Check for Python environment variables
    $envVarsStillPresent = @()
    foreach ($var in @('PYTHONPATH', 'PYTHONHOME', 'VIRTUAL_ENV', 'CONDA_PREFIX')) {
        $userVal = [Environment]::GetEnvironmentVariable($var, 'User')
        $machineVal = [Environment]::GetEnvironmentVariable($var, 'Machine')
        if ($userVal) { $envVarsStillPresent += "$var (User)" }
        if ($machineVal) { $envVarsStillPresent += "$var (Machine)" }
    }
    if ($envVarsStillPresent.Count -eq 0) {
        Write-LogMessage -Message "  [OK] No environment variables (4 checked)" -Color $script:colors.Success -Type 'VERIFY'
    } else {
        Write-LogMessage -Message "  [X] Found $($envVarsStillPresent.Count) environment variable(s)" -Color $script:colors.Error -Type 'VERIFY'
        $issuesFound += "Environment variables: $($envVarsStillPresent -join ', ')"
        $pythonFound = $true
    }

    # Check for Python directories
    $commonPaths = @(
        "$env:ProgramFiles\Python*",
        "${env:ProgramFiles(x86)}\Python*",
        "C:\Python*",
        "$env:LOCALAPPDATA\Programs\Python*"
    )
    $dirsFound = 0
    foreach ($pathPattern in $commonPaths) {
        $found = Get-ChildItem -Path (Split-Path $pathPattern -Parent) -Filter (Split-Path $pathPattern -Leaf) -Directory -ErrorAction SilentlyContinue
        if ($found) {
            foreach ($dir in $found) {
                $issuesFound += "Directory: $($dir.FullName)"
                $pythonFound = $true
                $dirsFound++
            }
        }
    }
    if ($dirsFound -eq 0) {
        Write-LogMessage -Message "  [OK] No common directories ($($commonPaths.Count) locations checked)" -Color $script:colors.Success -Type 'VERIFY'
    } else {
        Write-LogMessage -Message "  [X] Found $dirsFound Python directory/directories" -Color $script:colors.Error -Type 'VERIFY'
    }

    # Display final verdict
    if (-not $pythonFound) {
        Write-LogMessage -Message "`nVerification: PASSED - System is Python-free" -Color $script:colors.Success -Type 'VERIFY'
    } else {
        Write-LogMessage -Message "`nVerification: FAILED - Found remaining Python components:" -Color $script:colors.Warning -Type 'VERIFY'
        foreach ($issue in $issuesFound) {
            Write-LogMessage -Message "  - $issue" -Color $script:colors.Warning -Type 'VERIFY'
        }
        Write-LogMessage -Message "Total issues found: $($issuesFound.Count)" -Color $script:colors.Warning -Type 'VERIFY'
    }
}

function New-Report {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if ($script:config.ItemsFound.Count -gt 0) {
        if ($PSCmdlet.ShouldProcess($script:config.ReportFile, "Create Report")) {
            $script:config.ItemsFound | Export-Csv -Path $script:config.ReportFile -NoTypeInformation -Encoding UTF8
            Write-LogMessage -Message "Report generated: $($script:config.ReportFile)" -Color $script:colors.Success -Type 'REPORT'
        }
    }
}
#endregion

#region Main Execution
try {
    if (-not $ScanOnly) { Clear-Host }
    Write-Information "$($script:ansiColors['Cyan'])Python Removal Script v$($script:config.Version)$($script:ansiColors['Reset'])"

    if (-not (Test-DiskSpace)) {
        Write-Warning "Low Disk Space - Backup might fail."
    }

    # Confirmation prompt (skip for ScanOnly or WhatIf modes)
    if (-not $ScanOnly -and -not $WhatIfPreference) {
        Write-Information "`n$($script:ansiColors['Yellow'])WARNING: This will permanently remove all Python installations and related files.$($script:ansiColors['Reset'])"
        Write-Information "  - All Python installations (traditional, Microsoft Store, Anaconda, etc.)"
        Write-Information "  - Virtual environments (.venv, venv, conda envs)"
        Write-Information "  - Package caches (pip, uv, poetry, rye)"
        Write-Information "  - Environment variables and PATH entries"
        Write-Information "  - Registry keys and file associations`n"

        if ($CreateBackup) {
            Write-Information "$($script:ansiColors['Cyan'])A system restore point will be created before removal.$($script:ansiColors['Reset'])`n"
        } else {
            Write-Information "$($script:ansiColors['Red'])WARNING: System restore point creation is DISABLED.$($script:ansiColors['Reset'])`n"
        }

        Write-Information "$($script:ansiColors['Gray'])Log file: $($script:config.LogFile)$($script:ansiColors['Reset'])"
        Write-Host "`n$($script:ansiColors['Yellow'])Do you want to continue? [Y]es / [N]o:$($script:ansiColors['Reset']) " -NoNewline
        $confirmation = Read-Host

        if ($confirmation -notmatch '^[Yy]') {
            Write-Information "`n$($script:ansiColors['Cyan'])Operation cancelled by user.$($script:ansiColors['Reset'])"
            exit 0
        }
        Write-Information ""
    }

    New-RestorePoint
    Test-RunningProcess
    Uninstall-StorePython
    Uninstall-TraditionalPython
    Remove-EnvironmentVariable
    Remove-PythonDirectory
    Remove-VirtualEnvironment
    Remove-AppExecutionAlias
    Clear-Registry

    if (-not $ScanOnly) { Test-PostRemoval }

    New-Report

    # Summary Statistics
    Write-LogMessage -Message "`n=== CLEANUP SUMMARY ===" -Color $script:colors.Header -Type 'SECTION'
    Write-LogMessage -Message "Items Found: $($script:config.ItemsFound.Count)" -Color $script:colors.Info -Type 'INFO'
    Write-LogMessage -Message "Items Removed: $($script:config.ItemsRemoved)" -Color $script:colors.Success -Type 'INFO'
    Write-LogMessage -Message "Items Failed: $($script:config.ItemsFailed)" -Color $script:colors.Error -Type 'INFO'
    Write-LogMessage -Message "Items Skipped: $($script:config.ItemsSkipped)" -Color $script:colors.Warning -Type 'INFO'

    $elapsed = (Get-Date) - $script:config.StartTime
    Write-LogMessage -Message "Execution Time: $([Math]::Round($elapsed.TotalSeconds, 1))s" -Color $script:colors.Info -Type 'INFO'

    if ($script:config.ItemsRemoved -gt 0) {
        $successRate = [Math]::Round(($script:config.ItemsRemoved / ($script:config.ItemsRemoved + $script:config.ItemsFailed)) * 100, 1)
        Write-LogMessage -Message "Success Rate: $successRate%" -Color $script:colors.Success -Type 'INFO'
    }

    if ($script:config.TotalSize -gt 0) {
        $sizeLabel = if ($ScanOnly) { "Total Size" } else { "Space Freed" }
        Write-LogMessage -Message "$sizeLabel: $(Format-FileSize $script:config.TotalSize)" -Color $script:colors.Info -Type 'INFO'
    }

    $mode = if ($ScanOnly) { 'Scan' } else { 'Cleanup' }
    Write-Information "$($script:ansiColors['Green'])`n$mode Complete.$($script:ansiColors['Reset'])"
    Write-Information "Log file: $($script:config.LogFile)"

    if (-not $ScanOnly) {
        Write-Information "$($script:ansiColors['Yellow'])Please reboot to complete removal.$($script:ansiColors['Reset'])"
    }
} catch {
    Write-Error "Critical Failure: $_"
    exit 1
} finally {
    if ([Environment]::UserInteractive) {
        try {
            Write-Information "`nPress any key to exit..."
            $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        } catch {
            Start-Sleep -Seconds 2
        }
    }
}
#endregion
