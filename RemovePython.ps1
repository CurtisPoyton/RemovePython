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
#>

[CmdletBinding(SupportsShouldProcess)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'CreateBackup', Justification = 'Used in New-RestorePoint')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'SkipProcessCheck', Justification = 'Used in Test-RunningProcess')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'SkipDiskCheck', Justification = 'Used in Test-DiskSpace')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'IncludeNetworkDrives', Justification = 'Used in Remove-ItemSafely')]
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
    [int]$TimeoutSeconds = 300
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
    MaxDepth           = 8
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
                RestorePointType = 12
                EventType        = 100
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

    $sizeBytes = if ($ScanOnly) { Get-SafeFolderSize $Path } else { 0 }
    Add-Finding -Type $Type -Name $Description -Path $Path -SizeBytes $sizeBytes

    if ($ScanOnly) {
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
                $cmd = $install.UninstallString.Trim('"')
                $uninstallSuccess = $false

                if ($cmd -match 'MsiExec') {
                    if ($cmd -match '\{[A-F0-9-]+\}') {
                        $code = $matches[0]
                        Write-LogMessage -Message "  Running MSI Uninstall for $code..." -Color $script:colors.Info -Type 'INFO'
                        try {
                            $proc = Start-Process 'MsiExec.exe' -ArgumentList "/X $code /qn /norestart" -PassThru -NoNewWindow
                            $timeoutMs = $script:config.TimeoutSeconds * 1000
                            if ($proc.WaitForExit($timeoutMs)) {
                                if ($proc.ExitCode -in @(0, 3010)) {
                                    $uninstallSuccess = $true
                                    Write-LogMessage -Message "  [OK] MSI Uninstalled (exit code: $($proc.ExitCode))" -Color $script:colors.Success -Type 'REMOVE'
                                    $script:config.ItemsRemoved++
                                } else {
                                    Write-LogMessage -Message "  [X] MSI failed (exit code: $($proc.ExitCode))" -Color $script:colors.Error -Type 'ERROR'
                                    $script:config.ItemsFailed++
                                }
                            } else {
                                $proc.Kill()
                                Write-LogMessage -Message "  [X] MSI timeout after $($script:config.TimeoutSeconds)s" -Color $script:colors.Error -Type 'ERROR'
                                $script:config.ItemsFailed++
                            }
                        } catch {
                            Write-LogMessage -Message "  [X] MSI error: $($_.Exception.Message)" -Color $script:colors.Error -Type 'ERROR'
                            $script:config.ItemsFailed++
                        }
                    }
                } elseif ($install.UninstallString -match '\.exe') {
                    Write-LogMessage -Message "  Attempting EXE uninstall: $cmd" -Color $script:colors.Info -Type 'INFO'
                    $exePath = if ($cmd -match '^"([^"]+)"') { $matches[1] } else { ($cmd -split '\s+')[0] }
                    if (Test-Path $exePath) {
                        $silentArgs = @('/S', '/SILENT', '--uninstall', '/quiet', '/VERYSILENT')
                        foreach ($arg in $silentArgs) {
                            try {
                                $proc = Start-Process $exePath -ArgumentList $arg -PassThru -NoNewWindow -ErrorAction Stop
                                if ($proc.WaitForExit(120000)) {
                                    if ($proc.ExitCode -eq 0) {
                                        $uninstallSuccess = $true
                                        Write-LogMessage -Message "  [OK] EXE Uninstalled with $arg" -Color $script:colors.Success -Type 'REMOVE'
                                        $script:config.ItemsRemoved++
                                        break
                                    }
                                } else { $proc.Kill() }
                            } catch { continue }
                        }
                        if (-not $uninstallSuccess) {
                            Write-LogMessage -Message "  [!] EXE auto-uninstall failed" -Color $script:colors.Warning -Type 'MANUAL'
                        }
                    }
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
        "$env:LOCALAPPDATA\Programs\Python*",
        "$env:ProgramFiles\Python*",
        "${env:ProgramFiles(x86)}\Python*",
        "C:\Python*",
        "$env:USERPROFILE\Anaconda*",
        "$env:USERPROFILE\Miniconda*",
        "$env:USERPROFILE\Mambaforge*",
        "$env:USERPROFILE\Miniforge*",
        "$env:ProgramData\Anaconda*",
        "$env:ProgramData\Miniconda*",
        "$env:ProgramData\Mambaforge*",
        "$env:ProgramData\Miniforge*",
        "$env:LOCALAPPDATA\Continuum",
        "$env:USERPROFILE\.pyenv",
        "$env:USERPROFILE\.conda",
        "$env:APPDATA\Python",
        "$env:LOCALAPPDATA\pip",
        "$env:APPDATA\pip",
        "$env:USERPROFILE\.cache\pip",
        "$env:USERPROFILE\.virtualenvs",
        "$env:USERPROFILE\.jupyter",
        "$env:USERPROFILE\.ipython",
        "$env:USERPROFILE\.rye",
        "$env:USERPROFILE\.uv",
        "$env:LOCALAPPDATA\uv",
        "$env:APPDATA\pypoetry",
        "$env:LOCALAPPDATA\pypoetry",
        "$env:USERPROFILE\.pdm",
        "$env:USERPROFILE\.local\pipx",
        "$env:LOCALAPPDATA\hatch"
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
}

function Remove-VirtualEnvironment {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    Write-LogMessage -Message "`n=== VIRTUAL ENVIRONMENTS ===" -Color $script:colors.Header -Type 'SECTION'

    $scanRoot = $env:USERPROFILE
    Write-LogMessage -Message "Scanning $scanRoot (Depth: $($script:config.MaxDepth))..." -Color $script:colors.Info -Type 'SCAN'

    try {
        $dirs = Get-ChildItem -Path $scanRoot -Directory -Recurse -Depth $script:config.MaxDepth -ErrorAction Ignore -Force

        $venvs = $dirs | Where-Object {
            ($_.Name -in @('.venv', 'venv', 'env')) -and
            ((Test-Path "$($_.FullName)\Scripts\activate") -or (Test-Path "$($_.FullName)\bin\activate"))
        }

        foreach ($venv in $venvs) {
            Remove-ItemSafely -Path $venv.FullName -Description "Venv: $($venv.FullName)" -Type 'VirtualEnv'
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
                    [Environment]::SetEnvironmentVariable($var, $null, $scope)
                    Write-LogMessage -Message "  [OK] Removed" -Color $script:colors.Success -Type 'REMOVE'
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
                Write-LogMessage -Message "Cleaning $scope PATH..." -Color $script:colors.Info -Type 'INFO'
                if (-not $ScanOnly -and $PSCmdlet.ShouldProcess("Path ($scope)", "Clean")) {
                    [Environment]::SetEnvironmentVariable('Path', ($newParts -join ';'), $scope)
                    Write-LogMessage -Message "  [OK] Path Cleaned" -Color $script:colors.Success -Type 'REMOVE'
                }
            }
        }
    }
}

function Clear-Registry {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    Write-LogMessage -Message "`n=== REGISTRY CLEANUP ===" -Color $script:colors.Header -Type 'SECTION'

    $keys = @(
        'HKCU:\Software\Python', 'HKLM:\Software\Python',
        'HKCU:\Software\Anaconda', 'HKLM:\Software\Anaconda',
        'HKLM:\Software\Wow6432Node\Python'
    )

    foreach ($key in $keys) {
        if (Test-Path $key) {
            Write-LogMessage -Message "Found Registry Key: $key" -Color $script:colors.Found -Type 'FOUND'
            if (-not $ScanOnly -and $PSCmdlet.ShouldProcess($key, "Remove Registry Key")) {
                Remove-Item -Path $key -Recurse -Force -ErrorAction SilentlyContinue
                Write-LogMessage -Message "  [OK] Removed" -Color $script:colors.Success -Type 'REMOVE'
            }
        }
    }

    $assocKeys = @(
        'HKCU:\Software\Classes\.py', 'HKCU:\Software\Classes\.pyw', 'HKCU:\Software\Classes\.pyc',
        'HKCU:\Software\Classes\py_auto_file', 'HKCU:\Software\Classes\Python.File',
        'HKCU:\Software\Classes\Python.CompiledFile', 'HKCU:\Software\Classes\Python.NoConFile'
    )

    foreach ($key in $assocKeys) {
        if (Test-Path $key) {
            Write-LogMessage -Message "Found File Association: $key" -Color $script:colors.Found -Type 'FOUND'
            if (-not $ScanOnly -and $PSCmdlet.ShouldProcess($key, "Remove File Association")) {
                Remove-Item -Path $key -Recurse -Force -ErrorAction SilentlyContinue
                Write-LogMessage -Message "  [OK] Removed" -Color $script:colors.Success -Type 'REMOVE'
            }
        }
    }
}

function Test-RunningProcess {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if ($SkipProcessCheck) { return }
    Write-LogMessage -Message "`n=== PROCESS CHECK ===" -Color $script:colors.Header -Type 'SECTION'

    $procs = @(Get-Process | Where-Object { $_.ProcessName -match $script:pythonPatterns.ProcessNames })
    if ($procs.Count -gt 0) {
        Write-LogMessage -Message "Found $($procs.Count) Python processes." -Color $script:colors.Warning -Type 'WARN'
        if (-not $ScanOnly) {
            foreach ($proc in $procs) {
                if ($PSCmdlet.ShouldProcess("$($proc.ProcessName) (PID: $($proc.Id))", "Stop Process")) {
                    try {
                        $proc | Stop-Process -Force -ErrorAction Stop
                        Write-LogMessage -Message "  [OK] Terminated $($proc.ProcessName)" -Color $script:colors.Success -Type 'REMOVE'
                    } catch {
                        Write-LogMessage -Message "  [X] Failed to stop $($proc.ProcessName): $($_.Exception.Message)" -Color $script:colors.Error -Type 'ERROR'
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
        $pythonAliases = Get-ChildItem -Path $aliasPath -Filter "python*.exe" -ErrorAction SilentlyContinue
        $pythonAliases += Get-ChildItem -Path $aliasPath -Filter "pip*.exe" -ErrorAction SilentlyContinue

        foreach ($alias in $pythonAliases) {
            if ($alias.Length -le 1KB) {
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
    }
}

function Test-PostRemoval {
    Write-LogMessage -Message "`n=== POST-REMOVAL VERIFICATION ===" -Color $script:colors.Header -Type 'SECTION'

    $pythonFound = $false

    try {
        $wherePython = where.exe python 2>$null
        if ($wherePython) {
            Write-LogMessage -Message "Python still found in PATH: $wherePython" -Color $script:colors.Warning -Type 'VERIFY'
            $pythonFound = $true
        }
    } catch {
        $null = $_
    }

    $regKeys = @('HKCU:\Software\Python', 'HKLM:\Software\Python')
    foreach ($key in $regKeys) {
        if (Test-Path $key) {
            Write-LogMessage -Message "Registry key still exists: $key" -Color $script:colors.Warning -Type 'VERIFY'
            $pythonFound = $true
        }
    }

    if (-not $pythonFound) {
        Write-LogMessage -Message "Verification complete: No Python installations detected" -Color $script:colors.Success -Type 'VERIFY'
    } else {
        Write-LogMessage -Message "Some Python components may remain - check above for details" -Color $script:colors.Warning -Type 'VERIFY'
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
