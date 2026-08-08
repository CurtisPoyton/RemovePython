#Requires -Version 7.5
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Completely removes Python installations, environments, and artefacts from Windows.

.DESCRIPTION
    Performs a deep clean of Python across the whole machine:
      - Microsoft Store packages (per-user and provisioned)
      - Traditional MSI/EXE installations (Python, Anaconda, Miniconda, Mambaforge, Miniforge)
      - Environment variables and PATH entries, rewritten through the registry so that
        REG_EXPAND_SZ values keep their type and unexpanded tokens survive
      - Virtual environments (venv, conda, Poetry, Pipenv)
      - Package caches (pip, UV)
      - Registry keys, file associations, application paths and shared DLL references
      - App execution aliases and the Windows Python Launcher binaries
      - Conda initialisation blocks in PowerShell profiles

    Tool binaries (Poetry, PDM, Rye, Hatch, pipx, Jupyter) are deliberately preserved; they
    will require a Python reinstall before they work again.

    Every environment change is written to a JSON backup that -RestoreEnvironment can replay.

.PARAMETER ScanOnly
    Report every component that would be removed without changing anything.

.PARAMETER SkipRestorePoint
    Do not create a system restore point before removal.

.PARAMETER SkipProcessCheck
    Do not look for or terminate running Python processes.

.PARAMETER SkipDiskCheck
    Do not validate available disk space before starting.

.PARAMETER IncludeNetworkDrives
    Allow removal of paths that resolve to network locations. Off by default.

.PARAMETER Force
    Skip the interactive confirmation prompt. Required for unattended runs.

.PARAMETER MinFreeDiskSpaceGB
    Free space on the system drive below which a warning is raised. Default 5 GB.

.PARAMETER TimeoutSeconds
    Upper bound for a single uninstaller invocation. Default 300 seconds.

.PARAMETER MaxScanDepth
    Directory depth used when scanning the user profile for virtual environments.

.PARAMETER RestoreEnvironment
    Path to a Python_EnvVars_Backup_*.json file. Restores the recorded environment
    variables and PATH values, then exits without removing anything.

.PARAMETER LogDirectory
    Directory that receives the log, CSV report and environment backup.

.EXAMPLE
    .\RemovePython.ps1 -ScanOnly
    Lists every Python component that would be removed and writes a CSV report.

.EXAMPLE
    .\RemovePython.ps1 -Force
    Runs unattended, creating a restore point and removing everything found.

.EXAMPLE
    .\RemovePython.ps1 -SkipRestorePoint -MaxScanDepth 5
    Removes without a restore point and with a shallower virtual environment scan.

.EXAMPLE
    .\RemovePython.ps1 -RestoreEnvironment .\Python_EnvVars_Backup_20260808_101500.json
    Replays a previous environment backup and exits.

.NOTES
    Exit codes:
      0  Completed with no failures
      1  Critical failure; the run was abandoned
      2  Completed, but one or more operations failed
      3  Completed, but post-removal verification found remaining components
      4  Cancelled at the confirmation prompt
      5  Pre-flight validation failed; nothing was changed
#>

[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Remove')]
param(
    [Parameter(ParameterSetName = 'Remove', HelpMessage = 'Preview mode; no changes are made')]
    [switch]$ScanOnly,

    [Parameter(ParameterSetName = 'Remove', HelpMessage = 'Do not create a system restore point')]
    [switch]$SkipRestorePoint,

    [Parameter(ParameterSetName = 'Remove', HelpMessage = 'Do not check for running Python processes')]
    [switch]$SkipProcessCheck,

    [Parameter(ParameterSetName = 'Remove', HelpMessage = 'Do not check available disk space')]
    [switch]$SkipDiskCheck,

    [Parameter(ParameterSetName = 'Remove', HelpMessage = 'Allow removal of network paths')]
    [switch]$IncludeNetworkDrives,

    [Parameter(ParameterSetName = 'Remove', HelpMessage = 'Skip the confirmation prompt')]
    [switch]$Force,

    [Parameter(ParameterSetName = 'Remove', HelpMessage = 'Minimum free disk space in GB')]
    [ValidateRange(1, 1000)]
    [int]$MinFreeDiskSpaceGB = 5,

    [Parameter(ParameterSetName = 'Remove', HelpMessage = 'Uninstaller timeout in seconds')]
    [ValidateRange(60, 3600)]
    [int]$TimeoutSeconds = 300,

    [Parameter(ParameterSetName = 'Remove', HelpMessage = 'Virtual environment scan depth')]
    [ValidateRange(3, 15)]
    [int]$MaxScanDepth = 8,

    [Parameter(ParameterSetName = 'Restore', Mandatory, HelpMessage = 'Environment backup file to replay')]
    [ValidateNotNullOrEmpty()]
    [string]$RestoreEnvironment,

    [Parameter(HelpMessage = 'Directory for the log, report and backup files')]
    [ValidateNotNullOrEmpty()]
    [string]$LogDirectory = $PSScriptRoot
)

$ErrorActionPreference = 'Continue'
$InformationPreference = 'Continue'

#region Configuration
function Initialize-Configuration {
    [CmdletBinding()]
    param(
        [switch]$ScanOnly,
        [switch]$SkipRestorePoint,
        [switch]$SkipProcessCheck,
        [switch]$SkipDiskCheck,
        [switch]$IncludeNetworkDrives,
        [switch]$Force,
        [int]$MinFreeDiskSpaceGB = 5,
        [int]$TimeoutSeconds = 300,
        [int]$MaxScanDepth = 8,
        [string]$LogDirectory
    )

    if ([string]::IsNullOrWhiteSpace($LogDirectory)) { $LogDirectory = $PWD.Path }
    $stamp = [datetime]::Now.ToString('yyyyMMdd_HHmmss')

    $script:config = @{
        Version                 = '2.0'
        LogDirectory            = $LogDirectory
        LogFile                 = Join-Path $LogDirectory "Python_Removal_Log_$stamp.txt"
        MarkdownFile            = Join-Path $LogDirectory "Python_Removal_Log_$stamp.md"
        ReportFile              = Join-Path $LogDirectory "Python_Removal_Report_$stamp.csv"
        BackupFile              = Join-Path $LogDirectory "Python_EnvVars_Backup_$stamp.json"
        ScanOnly                = [bool]$ScanOnly
        RestoreMode             = $false
        SkipRestorePoint        = [bool]$SkipRestorePoint
        SkipProcessCheck        = [bool]$SkipProcessCheck
        SkipDiskCheck           = [bool]$SkipDiskCheck
        IncludeNetworkDrives    = [bool]$IncludeNetworkDrives
        Force                   = [bool]$Force
        MinFreeDiskSpaceGB      = $MinFreeDiskSpaceGB
        TimeoutSeconds          = $TimeoutSeconds
        MaxScanDepth            = $MaxScanDepth
        MaxParallelism          = [Math]::Clamp([Environment]::ProcessorCount, 2, 32)
        ExeUninstallTimeoutSec  = [Math]::Min($TimeoutSeconds, 180)
        MsiRetryCount           = 2
        MsiRetryDelaySeconds    = 5
        TempFileMinimumAgeDays  = 1
        LargeDirectoryThreshold = 1000
        MinimumSystemProcessId  = 10
        LauncherBinary          = @(
            (Join-Path $env:WINDIR 'py.exe'),
            (Join-Path $env:WINDIR 'pyw.exe')
        )
    }

    $script:state = @{
        Findings          = [System.Collections.Generic.List[object]]::new()
        VerificationIssue = [System.Collections.Generic.List[string]]::new()
        PhaseTiming       = [System.Collections.Generic.List[object]]::new()
        ManualAction      = [System.Collections.Generic.List[object]]::new()
        BlockedPath       = [System.Collections.Generic.List[object]]::new()
        Transcript        = [System.Text.StringBuilder]::new()
        StartTime         = [datetime]::Now
        ErrorCountAtStart = $Error.Count
        LogWriter         = $null
        ExitCode          = 0
    }

    $script:ansi = @{
        Cyan       = "`e[36m"
        Green      = "`e[32m"
        Yellow     = "`e[33m"
        BoldYellow = "`e[93m"
        Red        = "`e[31m"
        Gray       = "`e[90m"
        Reset      = "`e[0m"
    }

    $script:levelColour = @{
        Section = $script:ansi.Cyan
        Found   = $script:ansi.Yellow
        Info    = $script:ansi.Gray
        Success = $script:ansi.Green
        Warn    = $script:ansi.BoldYellow
        Error   = $script:ansi.Red
    }

    $script:pattern = @{
        PathEntry        = '(^|\\)(python\d*|\.venv|\.pyenv|' +
        '\.virtualenvs?|Anaconda\d*|Miniconda\d*|' +
        'Mambaforge\d*|Miniforge\d*|conda|site-packages|' +
        'dist-packages)(\\|$)|' +
        '\\(pyenv|virtualenv)\\|\.python-version'
        ProcessName      = '^python(w)?(\d+(\.\d+)?)?$|' +
        '^pip(\d+)?$|^conda$|^mamba$|^anaconda$|' +
        '^jupyter(-[a-z]+)?$|^ipython\d*$|' +
        '^pyinstaller$|^pylint$|^pytest$|^mypy(c)?$|' +
        '^black(d)?$|^ruff$|^flake8$|^virtualenv$|' +
        '^pydoc\d*(\.\d+)?$|^idle\d*(\.\d+)?$|^sphinx(-[a-z]+)?$'
        InstallInclude   = '\b(Python|Anaconda\d*|Miniconda\d*|Mambaforge\d*|Miniforge\d*|Mamba|pyenv)\b|' +
        '^uv\b|^astral\b'
        InstallExclude   = 'Visual Studio|PyCharm|VS Code|IntelliJ|Rider|Eclipse|NetBeans|Boost|Iron|Crypto'
        SharedDll        = '(python|anaconda|miniconda|\.pyd)'
        CondaInitBlock   = '(?ms)^#region conda initialize\r?\n.*?#endregion\r?\n?'
        CondaInitMarker  = '#region conda initialize'
        ProfilePythonUse = '(?i)(pyenv|conda|python|virtualenv|poetry.*python|pipenv|\.venv)'
        ScanExclusion    = '\\(node_modules|\.git|\.hg|AppData\\Local|AppData\\LocalLow|\.cache\\(?!pip|uv))(\\.+|$)'
        CondaBaseEnv     = '(Anaconda|Miniconda|Mambaforge|Miniforge)\\envs\\base'
        MsiProductCode   = '\{[A-F0-9-]+\}'
    }

    $script:protectedPath = @(
        $env:WINDIR,
        $env:SystemRoot,
        (Join-Path $env:ProgramFiles 'Windows'),
        'C:\Windows',
        'C:\Program Files\WindowsApps'
    )
    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
        $script:protectedPath += (Join-Path ${env:ProgramFiles(x86)} 'Windows')
    }

    # Documents holds live project work, including virtual environments this script would otherwise
    # match. Guard the shell-reported location, which follows OneDrive redirection, the literal
    # profile path, and the legacy junction that reaches the same tree under a different prefix.
    $documentsPath = @(
        [Environment]::GetFolderPath('MyDocuments'),
        (Join-Path $env:USERPROFILE 'Documents'),
        (Join-Path $env:USERPROFILE 'My Documents')
    )
    foreach ($candidate in $documentsPath) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if ($script:protectedPath -notcontains $candidate) { $script:protectedPath += $candidate }
    }

    $script:pythonVariable = @(
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
        'PYLAUNCHER_ALLOW_INSTALL', 'PY_PYTHON'
    )

    $script:environmentKey = @{
        User    = @{ Hive = 'CurrentUser'; SubKey = 'Environment' }
        Machine = @{
            Hive   = 'LocalMachine'
            SubKey = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
        }
    }

    $script:coreInstallGlob = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Python*'),
        (Join-Path $env:ProgramFiles 'Python*'),
        (Join-Path $env:SystemDrive '\Python*')
    )
    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
        $script:coreInstallGlob += (Join-Path ${env:ProgramFiles(x86)} 'Python*')
    }

    $script:directoryGlob = $script:coreInstallGlob + @(
        (Join-Path $env:USERPROFILE 'Anaconda*'),
        (Join-Path $env:USERPROFILE 'Miniconda*'),
        (Join-Path $env:USERPROFILE 'Mambaforge*'),
        (Join-Path $env:USERPROFILE 'Miniforge*'),
        (Join-Path $env:ProgramData 'Anaconda*'),
        (Join-Path $env:ProgramData 'Miniconda*'),
        (Join-Path $env:ProgramData 'Mambaforge*'),
        (Join-Path $env:ProgramData 'Miniforge*'),
        (Join-Path $env:LOCALAPPDATA 'Continuum'),
        (Join-Path $env:USERPROFILE '.continuum'),
        (Join-Path $env:USERPROFILE '.conda'),
        (Join-Path $env:APPDATA 'conda'),
        (Join-Path $env:LOCALAPPDATA 'conda'),
        (Join-Path $env:USERPROFILE '.pyenv'),
        (Join-Path $env:USERPROFILE '.pythonz'),
        (Join-Path $env:USERPROFILE '.python-build'),
        (Join-Path $env:APPDATA 'Python'),
        (Join-Path $env:LOCALAPPDATA 'pip'),
        (Join-Path $env:APPDATA 'pip'),
        (Join-Path $env:USERPROFILE '.cache\pip'),
        (Join-Path $env:LOCALAPPDATA 'pip-cache'),
        (Join-Path $env:LOCALAPPDATA 'pip-audit'),
        (Join-Path $env:USERPROFILE '.uv'),
        (Join-Path $env:LOCALAPPDATA 'uv'),
        (Join-Path $env:APPDATA 'uv'),
        (Join-Path $env:USERPROFILE '.cache\uv'),
        (Join-Path $env:LOCALAPPDATA 'astral'),
        (Join-Path $env:APPDATA 'astral'),
        (Join-Path $env:USERPROFILE '.astral'),
        (Join-Path $env:USERPROFILE '.virtualenvs'),
        (Join-Path $env:USERPROFILE '.virtualenv'),
        (Join-Path $env:USERPROFILE '.local\share\virtualenvs'),
        (Join-Path $env:USERPROFILE '.jupyter'),
        (Join-Path $env:USERPROFILE '.ipython'),
        (Join-Path $env:USERPROFILE '.jupyterlab'),
        (Join-Path $env:USERPROFILE '.mypy_cache'),
        (Join-Path $env:USERPROFILE '.pytest_cache'),
        (Join-Path $env:USERPROFILE '.ruff_cache'),
        (Join-Path $env:USERPROFILE '.ruff'),
        (Join-Path $env:USERPROFILE '.pylint.d'),
        (Join-Path $env:USERPROFILE '.black'),
        (Join-Path $env:USERPROFILE '.tox'),
        (Join-Path $env:USERPROFILE '.nox'),
        (Join-Path $env:USERPROFILE '.python-eggs'),
        (Join-Path $env:LOCALAPPDATA 'Packages\PythonSoftwareFoundation*'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\PythonSoftwareFoundation*'),
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Python*'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Python*'),
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Anaconda*'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Anaconda*'),
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Miniconda*'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Miniconda*'),
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Mambaforge*'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Mambaforge*'),
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Miniforge*'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Miniforge*')
    )

    $script:configFile = @(
        (Join-Path $env:USERPROFILE '.condarc'),
        (Join-Path $env:USERPROFILE '.python-version'),
        (Join-Path $env:USERPROFILE '.python_history'),
        (Join-Path $env:USERPROFILE '.pypirc'),
        (Join-Path $env:USERPROFILE '.pydistutils.cfg'),
        (Join-Path $env:APPDATA 'pip\pip.ini'),
        (Join-Path $env:USERPROFILE 'pip\pip.ini'),
        (Join-Path $env:ProgramData 'pip\pip.ini')
    )

    $script:desktopPath = @(
        (Join-Path $env:USERPROFILE 'Desktop'),
        (Join-Path $env:PUBLIC 'Desktop')
    )

    $script:shortcutFilter = @('Python*.lnk', 'Anaconda*.lnk', 'Miniconda*.lnk', 'IDLE*.lnk')

    $script:tempLocation = @(
        @{ Path = $env:TEMP; Filter = 'pip-*'; AgeChecked = $true },
        @{ Path = $env:TEMP; Filter = 'easy_install-*'; AgeChecked = $true },
        @{ Path = $env:TEMP; Filter = 'Python*'; AgeChecked = $true },
        @{ Path = (Join-Path $env:LOCALAPPDATA 'Package Cache'); Filter = '*python*'; AgeChecked = $false }
    )

    $script:fileExtension = @(
        '.py', '.pyw', '.pyc', '.pyo', '.pyd', '.pyi',
        '.pyz', '.pyzw', '.pth', '.whl', '.ipynb'
    )

    $script:fileHandler = @(
        'py_auto_file', 'pyw_auto_file', 'pyc_auto_file', 'Python.File',
        'Python.CompiledFile', 'Python.NoConFile', 'Python.ArchiveFile',
        'Python.NoConArchiveFile'
    )

    $script:applicationName = @('python.exe', 'pythonw.exe', 'py.exe', 'pyw.exe', 'idle.exe')

    $script:coreRegistryKey = @(
        'HKCU:\Software\Python',
        'HKLM:\Software\Python',
        'HKCU:\Software\Wow6432Node\Python',
        'HKLM:\Software\Wow6432Node\Python',
        'HKCU:\Software\Python Software Foundation',
        'HKLM:\Software\Python Software Foundation',
        'HKLM:\Software\Wow6432Node\Python Software Foundation',
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
        'HKCU:\Software\pyenv',
        'HKLM:\Software\pyenv'
    )

    $script:associationKey = @(
        foreach ($hive in 'HKCU:\Software\Classes', 'HKLM:\SOFTWARE\Classes') {
            foreach ($extension in $script:fileExtension) { "$hive\$extension" }
            foreach ($handler in $script:fileHandler) { "$hive\$handler" }
            foreach ($application in $script:applicationName) { "$hive\Applications\$application" }
        }
    )

    $appPathRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths'
    $appPathWow = 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\App Paths'
    $script:appPathKey = @(
        foreach ($application in $script:applicationName) { "$appPathRoot\$application" }
        "$appPathWow\python.exe"
        "$appPathWow\pythonw.exe"
    )

    $fileExtRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts'
    $script:userChoiceKey = @(
        foreach ($extension in $script:fileExtension) { "$fileExtRoot\$extension" }
    )

    $script:uninstallRoot = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
    )

    $script:sharedDllKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\SharedDLLs'

    $script:profilePath = @(
        (Join-Path $env:USERPROFILE 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1'),
        (Join-Path $env:USERPROFILE 'Documents\PowerShell\profile.ps1'),
        (Join-Path $env:ProgramFiles 'PowerShell\7\Microsoft.PowerShell_profile.ps1'),
        (Join-Path $env:ProgramFiles 'PowerShell\7\profile.ps1'),
        (Join-Path $env:USERPROFILE 'Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1'),
        (Join-Path $env:USERPROFILE 'Documents\WindowsPowerShell\profile.ps1')
    )

    $script:verificationVariable = @('PYTHONPATH', 'PYTHONHOME', 'VIRTUAL_ENV', 'CONDA_PREFIX')

    $script:verificationRegistryKey = @(
        $script:coreRegistryKey | Where-Object { $_ -match '\\(Python|Anaconda|Miniconda)' }
    )

    $script:verificationGlob = $script:coreInstallGlob
}
#endregion

#region Logging
function Open-LogFile {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    foreach ($directory in @($script:config.LogDirectory, $env:TEMP)) {
        if ([string]::IsNullOrWhiteSpace($directory)) { continue }
        try {
            if (-not (Test-Path -LiteralPath $directory)) {
                $null = New-Item -Path $directory -ItemType Directory -Force -ErrorAction Stop
            }
            $target = Join-Path $directory (Split-Path $script:config.LogFile -Leaf)
            $writer = [System.IO.StreamWriter]::new($target, $true, [System.Text.UTF8Encoding]::new($false))
            $writer.AutoFlush = $true
            $script:state.LogWriter = $writer
            $script:config.LogFile = $target
            return $true
        }
        catch [System.IO.IOException] { continue }
        catch [System.UnauthorizedAccessException] { continue }
    }
    return $false
}

function Close-LogFile {
    [CmdletBinding()]
    param()

    if (-not $script:state.LogWriter) { return }
    try {
        $script:state.LogWriter.Flush()
        $script:state.LogWriter.Dispose()
    }
    catch [System.ObjectDisposedException] { $null = $_ }
    finally { $script:state.LogWriter = $null }
}

function Test-ColourSupport {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if (-not [string]::IsNullOrEmpty($env:NO_COLOR)) { return $false }
    if ([Console]::IsOutputRedirected) { return $false }
    if ($PSStyle -and $PSStyle.OutputRendering -eq 'PlainText') { return $false }
    return $true
}

function Write-LogEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[a-z][a-z0-9_]*$', Options = 'None')]
        [string]$Tag,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message,

        [ValidateSet('Section', 'Found', 'Info', 'Success', 'Warn', 'Error')]
        [string]$Level = 'Info'
    )

    $line = "[$Tag] $Message"

    if ($script:state.Transcript) { [void]$script:state.Transcript.AppendLine($line) }

    if ($script:state.LogWriter) {
        $stamp = [datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss.fff')
        try { $script:state.LogWriter.WriteLine("[$stamp][$($Level.ToUpperInvariant())]$line") }
        catch [System.IO.IOException] { $script:state.LogWriter = $null }
        catch [System.ObjectDisposedException] { $script:state.LogWriter = $null }
    }

    if ($script:useColour) {
        Write-Information "$($script:levelColour[$Level])$line$($script:ansi.Reset)"
    }
    else {
        Write-Information $line
    }
}

function Write-Section {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Tag,

        [Parameter(Mandatory)]
        [string]$Title
    )

    Write-Information ''
    if ($script:state.Transcript) { [void]$script:state.Transcript.AppendLine() }
    Write-LogEntry -Tag $Tag -Level Section -Message "=== $Title ==="
}

function Add-ManualAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Item,

        [Parameter(Mandatory)]
        [string]$Reason,

        [AllowEmptyString()]
        [string]$Command = ''
    )

    [void]$script:state.ManualAction.Add([pscustomobject]@{
            Item    = $Item
            Reason  = $Reason
            Command = $Command
        })
}
#endregion

#region Findings
function Add-Finding {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Type,

        [Parameter(Mandatory)]
        [string]$Name,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Path,

        [int64]$SizeBytes = 0
    )

    $finding = [pscustomobject]@{
        Type      = $Type
        Name      = $Name
        Path      = $Path
        Size      = Format-FileSize -Bytes $SizeBytes
        SizeBytes = $SizeBytes
        Status    = 'Found'
        Reason    = ''
        Timestamp = [datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss')
    }
    [void]$script:state.Findings.Add($finding)
    return $finding
}

function Get-FindingCount {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Found', 'Removed', 'Failed', 'Skipped')]
        [string]$Status
    )

    return @($script:state.Findings | Where-Object { $_.Status -eq $Status }).Count
}

function Get-FindingSize {
    [CmdletBinding()]
    [OutputType([int64])]
    param([string]$Status)

    $selected = if ($Status) {
        $script:state.Findings | Where-Object { $_.Status -eq $Status }
    }
    else {
        $script:state.Findings
    }
    $total = ($selected | Measure-Object -Property SizeBytes -Sum).Sum
    return [int64]($total ?? 0)
}
#endregion

#region Path Utilities
function Format-FileSize {
    [CmdletBinding()]
    [OutputType([string])]
    param([int64]$Bytes)

    if ($Bytes -le 0) { return '0 B' }
    $unit = @('B', 'KB', 'MB', 'GB', 'TB')
    $order = [Math]::Floor([Math]::Log($Bytes, 1024))
    $order = [Math]::Min([Math]::Max($order, 0), $unit.Count - 1)
    $value = [Math]::Round($Bytes / [Math]::Pow(1024, $order), 2)
    return "$value $($unit[$order])"
}

function Add-BlockedPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Reason
    )

    # An empty List is falsy in PowerShell, so this must be an explicit null test.
    if ($null -eq $script:state.BlockedPath) { return }
    if ($script:state.BlockedPath.Where({ $_.Path -eq $Path }, 'First').Count -gt 0) { return }

    [void]$script:state.BlockedPath.Add([pscustomobject]@{ Path = $Path; Reason = $Reason })
}

function Test-PathSafe {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }

    if ($Path -match '^[A-Za-z]:$') {
        Add-BlockedPath -Path $Path -Reason 'root drive'
        Write-LogEntry -Tag 'safety' -Level Warn -Message "blocked root drive: $Path"
        return $false
    }

    try {
        $normalised = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    }
    catch [System.ArgumentException] {
        Write-LogEntry -Tag 'safety' -Level Warn -Message "blocked malformed path: $Path"
        return $false
    }
    catch [System.NotSupportedException] {
        Write-LogEntry -Tag 'safety' -Level Warn -Message "blocked malformed path: $Path"
        return $false
    }

    if ($normalised -match '^[A-Za-z]:\\?$') {
        Add-BlockedPath -Path $normalised -Reason 'root drive'
        Write-LogEntry -Tag 'safety' -Level Warn -Message "blocked root drive: $normalised"
        return $false
    }

    # The Python Launcher installs py.exe and pyw.exe directly into the Windows directory, so an
    # exact-filename exception is the only way to reach them without weakening the prefix guard below.
    foreach ($allowed in $script:config.LauncherBinary) {
        if ($normalised.Equals($allowed.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    foreach ($protected in $script:protectedPath) {
        if ([string]::IsNullOrWhiteSpace($protected)) { continue }
        $trimmed = $protected.TrimEnd('\')
        $isChild = $normalised.StartsWith("$trimmed\", [StringComparison]::OrdinalIgnoreCase)
        $isSelf = $normalised.Equals($trimmed, [StringComparison]::OrdinalIgnoreCase)
        if ($isSelf -or $isChild) {
            Add-BlockedPath -Path $normalised -Reason "protected location: $trimmed"
            Write-LogEntry -Tag 'safety' -Level Warn -Message "blocked protected path: $normalised"
            return $false
        }
    }
    return $true
}

function Test-IsNetworkPath {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ($Path.StartsWith('\\')) { return $true }
    if ($Path -notmatch '^([A-Za-z]):') { return $false }

    $drive = Get-PSDrive -Name $Matches[1] -PSProvider FileSystem -ErrorAction Ignore
    return ($null -ne $drive -and $null -ne $drive.DisplayRoot -and $drive.DisplayRoot.StartsWith('\\'))
}

function Get-DirectoryStatistic {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path)

    $result = [pscustomobject]@{ Path = $Path; SizeBytes = [int64]0; FileCount = 0 }

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Ignore
    if (-not $item) { return $result }
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { return $result }

    if (-not $item.PSIsContainer) {
        $result.SizeBytes = [int64]$item.Length
        $result.FileCount = 1
        return $result
    }

    $measure = Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction Ignore |
        Measure-Object -Property Length -Sum
    $result.SizeBytes = [int64]($measure.Sum ?? 0)
    $result.FileCount = [int]$measure.Count
    return $result
}

function Get-DirectoryStatisticSet {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Path
    )

    $map = @{}
    if ($Path.Count -eq 0) { return $map }

    if ($Path.Count -eq 1) {
        $single = Get-DirectoryStatistic -Path $Path[0]
        $map[$single.Path] = $single
        return $map
    }

    $throttle = [Math]::Min($Path.Count, $script:config.MaxParallelism)
    $definition = ${function:Get-DirectoryStatistic}.ToString()
    $results = $Path | ForEach-Object -ThrottleLimit $throttle -Parallel {
        ${function:Get-DirectoryStatistic} = $using:definition
        Get-DirectoryStatistic -Path $_
    }
    foreach ($result in $results) { $map[$result.Path] = $result }
    return $map
}
#endregion

#region Environment Registry Access
function Open-EnvironmentKey {
    [CmdletBinding()]
    [OutputType([Microsoft.Win32.RegistryKey])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('User', 'Machine')]
        [string]$Scope,

        [switch]$Writable
    )

    $definition = $script:environmentKey[$Scope]
    $hive = [Microsoft.Win32.Registry]::$($definition.Hive)
    return $hive.OpenSubKey($definition.SubKey, [bool]$Writable)
}

function Get-EnvironmentEntry {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('User', 'Machine')]
        [string]$Scope,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $key = Open-EnvironmentKey -Scope $Scope
    if (-not $key) { return $null }
    try {
        $option = [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
        $raw = $key.GetValue($Name, $null, $option)
        if ($null -eq $raw) { return $null }
        return @{ Value = [string]$raw; Kind = $key.GetValueKind($Name).ToString() }
    }
    finally { $key.Dispose() }
}

function Set-EnvironmentEntry {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('User', 'Machine')]
        [string]$Scope,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value,

        [ValidateSet('String', 'ExpandString')]
        [string]$Kind = 'String'
    )

    if (-not $PSCmdlet.ShouldProcess("$Name ($Scope)", 'Set environment value')) { return $false }

    $key = Open-EnvironmentKey -Scope $Scope -Writable
    if (-not $key) { return $false }
    try {
        $key.SetValue($Name, $Value, [Microsoft.Win32.RegistryValueKind]::$Kind)
        return $true
    }
    finally { $key.Dispose() }
}

function Remove-EnvironmentEntry {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('User', 'Machine')]
        [string]$Scope,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if (-not $PSCmdlet.ShouldProcess("$Name ($Scope)", 'Remove environment value')) { return $false }

    $key = Open-EnvironmentKey -Scope $Scope -Writable
    if (-not $key) { return $false }
    try {
        $key.DeleteValue($Name, $false)
        return $true
    }
    finally { $key.Dispose() }
}

function Send-SettingChange {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if (-not $PSCmdlet.ShouldProcess('Running processes', 'Broadcast environment change')) { return }

    try {
        if (-not ('RemovePython.NativeMethod' -as [type])) {
            $signature = @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, UIntPtr wParam,
    string lParam, uint flags, uint timeout, out UIntPtr result);
'@
            Add-Type -Namespace 'RemovePython' -Name 'NativeMethod' -MemberDefinition $signature -ErrorAction Stop
        }
        $answer = [UIntPtr]::Zero
        $null = [RemovePython.NativeMethod]::SendMessageTimeout(
            [IntPtr]0xFFFF, 0x001A, [UIntPtr]::Zero, 'Environment', 0x0002, 5000, [ref]$answer)
        Write-LogEntry -Tag 'env_var' -Message 'broadcast environment change to running processes'
    }
    catch {
        Write-LogEntry -Tag 'env_var' -Level Warn -Message "environment broadcast failed: $($_.Exception.Message)"
    }
}
#endregion

#region Removal Primitives
function Add-SkippedFinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Type,

        [Parameter(Mandatory)]
        [string]$Name,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Reason,

        [int64]$SizeBytes = 0
    )

    $finding = Add-Finding -Type $Type -Name $Name -Path $Path -SizeBytes $SizeBytes
    $finding.Status = 'Skipped'
    $finding.Reason = $Reason
}

function Write-RemovalFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Finding,

        [Parameter(Mandatory)]
        [string]$Tag,

        [Parameter(Mandatory)]
        [string]$Target,

        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $Finding.Status = 'Failed'
    $type = $ErrorRecord.Exception.GetType().Name
    $Finding.Reason = "${type}: $($ErrorRecord.Exception.Message)"
    Write-LogEntry -Tag $Tag -Level Error -Message "remove failed: $Target - $($Finding.Reason)"
}

function Remove-ItemSafely {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Type,

        [Parameter(Mandatory)]
        [string]$Tag,

        [AllowNull()]
        [psobject]$Statistic
    )

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Ignore
    if (-not $item) { return }

    $knownSize = if ($Statistic) { [int64]$Statistic.SizeBytes } else { [int64]0 }

    if (-not (Test-PathSafe -Path $Path)) {
        Add-SkippedFinding -Type $Type -Name $Name -Path $Path -SizeBytes $knownSize `
            -Reason 'blocked by the protected path policy'
        return
    }

    if (-not $script:config.IncludeNetworkDrives -and (Test-IsNetworkPath -Path $Path)) {
        Write-LogEntry -Tag $Tag -Level Warn -Message "skipped network path: $Path"
        Add-SkippedFinding -Type $Type -Name $Name -Path $Path -SizeBytes $knownSize `
            -Reason 'network path excluded'
        return
    }

    if (-not $Statistic) { $Statistic = Get-DirectoryStatistic -Path $Path }
    $finding = Add-Finding -Type $Type -Name $Name -Path $Path -SizeBytes $Statistic.SizeBytes

    $detail = if ($Statistic.SizeBytes -gt 0) { " ($(Format-FileSize -Bytes $Statistic.SizeBytes))" } else { '' }
    Write-LogEntry -Tag $Tag -Level Found -Message "found: $Name$detail"

    if ($script:config.ScanOnly) { return }
    if (-not $PSCmdlet.ShouldProcess($Path, "Remove $Type")) { return }

    if ($Statistic.FileCount -gt $script:config.LargeDirectoryThreshold) {
        Write-LogEntry -Tag $Tag -Message "removing $($Statistic.FileCount) files; this may take a while"
    }

    try {
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            if ($item.PSIsContainer) {
                [System.IO.Directory]::Delete($Path, $false)
            }
            else {
                Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
            }
            $finding.Status = 'Removed'
            Write-LogEntry -Tag $Tag -Level Success -Message "removed reparse point: $Path"
            return
        }

        if (-not $item.PSIsContainer -and $item.IsReadOnly) { $item.IsReadOnly = $false }
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        $finding.Status = 'Removed'
        Write-LogEntry -Tag $Tag -Level Success -Message "removed: $Path"
    }
    catch [System.UnauthorizedAccessException] {
        if (-not (Clear-ReadOnlyAttribute -Path $Path)) {
            Write-RemovalFailure -Finding $finding -Tag $Tag -Target $Path -ErrorRecord $_
            return
        }
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            $finding.Status = 'Removed'
            Write-LogEntry -Tag $Tag -Level Success -Message "removed after clearing read-only flags: $Path"
        }
        catch {
            Write-RemovalFailure -Finding $finding -Tag $Tag -Target $Path -ErrorRecord $_
        }
    }
    catch {
        Write-RemovalFailure -Finding $finding -Tag $Tag -Target $Path -ErrorRecord $_
    }
}

function Clear-ReadOnlyAttribute {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Ignore
    if (-not $item -or -not $item.PSIsContainer) { return $false }

    $readOnly = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction Ignore |
            Where-Object { $_.IsReadOnly })
    foreach ($file in $readOnly) { $file.IsReadOnly = $false }
    return ($readOnly.Count -gt 0)
}

function Remove-FileSafely {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Type,

        [Parameter(Mandatory)]
        [string]$Tag
    )

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Ignore
    if (-not $item) { return }

    if (-not (Test-PathSafe -Path $Path)) {
        Add-SkippedFinding -Type $Type -Name $Name -Path $Path -Reason 'blocked by the protected path policy'
        return
    }

    $size = if ($item.PSIsContainer) { 0 } else { [int64]$item.Length }
    $finding = Add-Finding -Type $Type -Name $Name -Path $Path -SizeBytes $size
    Write-LogEntry -Tag $Tag -Level Found -Message "found: $Name"

    if ($script:config.ScanOnly) { return }
    if (-not $PSCmdlet.ShouldProcess($Path, "Remove $Type")) { return }

    try {
        if (-not $item.PSIsContainer -and $item.IsReadOnly) { $item.IsReadOnly = $false }
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        $finding.Status = 'Removed'
        Write-LogEntry -Tag $Tag -Level Success -Message "removed: $Path"
    }
    catch {
        Write-RemovalFailure -Finding $finding -Tag $Tag -Target $Path -ErrorRecord $_
    }
}

function Remove-RegistryKeySet {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Path,

        [Parameter(Mandatory)]
        [string]$Type,

        [Parameter(Mandatory)]
        [string]$Tag
    )

    foreach ($key in $Path) {
        if (-not (Test-Path -LiteralPath $key)) { continue }

        $finding = Add-Finding -Type $Type -Name $key -Path $key
        Write-LogEntry -Tag $Tag -Level Found -Message "found: $key"

        if ($script:config.ScanOnly) { continue }
        if (-not $PSCmdlet.ShouldProcess($key, "Remove $Type")) { continue }

        try {
            Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction Stop
            $finding.Status = 'Removed'
            Write-LogEntry -Tag $Tag -Level Success -Message "removed: $key"
        }
        catch {
            Write-RemovalFailure -Finding $finding -Tag $Tag -Target $key -ErrorRecord $_
        }
    }
}
#endregion

#region Pre-flight
function Test-RequiredEnvironment {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $required = @(
        'WINDIR', 'SystemDrive', 'SystemRoot', 'USERPROFILE', 'APPDATA',
        'LOCALAPPDATA', 'ProgramData', 'ProgramFiles', 'PUBLIC', 'TEMP'
    )

    $missing = @(
        foreach ($name in $required) {
            if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) { $name }
        }
    )

    if ($missing.Count -gt 0) {
        Write-LogEntry -Tag 'preflight' -Level Error `
            -Message "required environment variables are empty: $($missing -join ', ')"
        Write-LogEntry -Tag 'preflight' -Level Error `
            -Message 'refusing to run; unresolved paths would target unintended locations'
        return $false
    }

    Write-LogEntry -Tag 'preflight' -Message "validated $($required.Count) required environment variables"
    return $true
}

function Test-DiskSpace {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if ($script:config.SkipDiskCheck) { return $true }

    try {
        $drive = Get-PSDrive -Name $env:SystemDrive.TrimEnd(':') -PSProvider FileSystem -ErrorAction Stop
    }
    catch [System.Management.Automation.DriveNotFoundException] {
        Write-LogEntry -Tag 'preflight' -Level Warn -Message "unable to query $env:SystemDrive for free space"
        return $false
    }

    $freeGB = [Math]::Round($drive.Free / 1GB, 2)
    if ($freeGB -lt $script:config.MinFreeDiskSpaceGB) {
        Write-LogEntry -Tag 'preflight' -Level Warn `
            -Message "free space $freeGB GB is below the $($script:config.MinFreeDiskSpaceGB) GB restore point minimum"
        return $false
    }

    Write-LogEntry -Tag 'preflight' -Message "free space on $env:SystemDrive is $freeGB GB"
    return $true
}

function New-RestorePoint {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if ($script:config.SkipRestorePoint -or $script:config.ScanOnly) {
        Write-LogEntry -Tag 'restore_point' -Level Warn -Message 'restore point creation disabled'
        return
    }

    if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Create system restore point')) { return }

    Write-LogEntry -Tag 'restore_point' -Message 'creating system restore point'

    $enableArgs = @{ Drive = "$env:SystemDrive\"; WaitTillEnabled = $true }
    try {
        $null = Invoke-CimMethod -Namespace root/default -ClassName SystemRestore `
            -MethodName Enable -Arguments $enableArgs -ErrorAction Stop
    }
    catch [Microsoft.Management.Infrastructure.CimException] {
        Write-LogEntry -Tag 'restore_point' -Level Warn `
            -Message "unable to enable system restore: $($_.Exception.Message)"
    }

    $createArgs = @{
        Description      = "Python Removal v$($script:config.Version) - $([datetime]::Now.ToString('yyyy-MM-dd HH:mm'))"
        RestorePointType = [uint32]12
        EventType        = [uint32]100
    }

    try {
        $result = Invoke-CimMethod -Namespace root/default -ClassName SystemRestore `
            -MethodName CreateRestorePoint -Arguments $createArgs -ErrorAction Stop
    }
    catch [Microsoft.Management.Infrastructure.CimException] {
        Write-LogEntry -Tag 'restore_point' -Level Error -Message "restore point failed: $($_.Exception.Message)"
        Write-LogEntry -Tag 'restore_point' -Level Warn -Message 'continuing without a restore point'
        return
    }

    if ($result.ReturnValue -eq 0) {
        Write-LogEntry -Tag 'restore_point' -Level Success -Message 'restore point created'
        return
    }

    $reason = switch ([int]$result.ReturnValue) {
        1058 { 'the System Restore service is disabled' }
        1450 { 'insufficient system resources' }
        default { "provider returned $($result.ReturnValue)" }
    }
    Write-LogEntry -Tag 'restore_point' -Level Error -Message "restore point failed: $reason"
    Write-LogEntry -Tag 'restore_point' -Level Warn -Message 'continuing without a restore point'
}
#endregion

#region Process Handling
function Test-RunningProcess {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if ($script:config.SkipProcessCheck) { return }
    Write-Section -Tag 'process' -Title 'RUNNING PROCESSES'

    $running = @(Get-Process -ErrorAction Ignore | Where-Object {
            $_.ProcessName -match $script:pattern.ProcessName -and
            $_.Id -gt $script:config.MinimumSystemProcessId
        })

    if ($running.Count -eq 0) {
        Write-LogEntry -Tag 'process' -Message 'no Python processes running'
        return
    }

    Write-LogEntry -Tag 'process' -Level Warn -Message "found $($running.Count) Python process(es)"

    foreach ($process in $running) {
        $label = "$($process.ProcessName) (PID $($process.Id))"
        $finding = Add-Finding -Type 'Process' -Name $label -Path $process.Path

        if ($script:config.ScanOnly) { continue }
        if (-not $PSCmdlet.ShouldProcess($label, 'Stop process')) { continue }

        try {
            Stop-Process -Id $process.Id -Force -ErrorAction Stop
            $finding.Status = 'Removed'
            Write-LogEntry -Tag 'process' -Level Success -Message "terminated: $label"
        }
        catch {
            Write-RemovalFailure -Finding $finding -Tag 'process' -Target $label -ErrorRecord $_
        }
    }
}
#endregion

#region Installation Removal
function Uninstall-StorePython {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    Write-Section -Tag 'appx' -Title 'MICROSOFT STORE PACKAGES'

    $packages = @()
    try {
        $packages = @(Get-AppxPackage -AllUsers -ErrorAction Stop | Where-Object {
                $_.Name -like '*Python*' -or $_.PublisherDisplayName -eq 'Python Software Foundation'
            })
    }
    catch {
        Write-LogEntry -Tag 'appx' -Level Warn -Message "unable to enumerate Store packages: $($_.Exception.Message)"
    }

    foreach ($package in $packages) {
        $finding = Add-Finding -Type 'AppX' -Name $package.Name -Path $package.InstallLocation
        Write-LogEntry -Tag 'appx' -Level Found -Message "found: $($package.Name)"

        if ($script:config.ScanOnly) { continue }
        if (-not $PSCmdlet.ShouldProcess($package.Name, 'Remove Store package')) { continue }

        try {
            Remove-AppxPackage -Package $package.PackageFullName -AllUsers -ErrorAction Stop
            $finding.Status = 'Removed'
            Write-LogEntry -Tag 'appx' -Level Success -Message "removed: $($package.Name)"
        }
        catch {
            Write-RemovalFailure -Finding $finding -Tag 'appx' -Target $package.Name -ErrorRecord $_
        }
    }

    $provisioned = @()
    try {
        $provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop |
                Where-Object { $_.DisplayName -like '*Python*' })
    }
    catch {
        Write-LogEntry -Tag 'appx' -Level Warn `
            -Message "unable to enumerate provisioned packages: $($_.Exception.Message)"
    }

    foreach ($package in $provisioned) {
        $finding = Add-Finding -Type 'AppXProvisioned' -Name $package.DisplayName -Path $package.PackageName
        Write-LogEntry -Tag 'appx' -Level Found -Message "found provisioned package: $($package.DisplayName)"

        if ($script:config.ScanOnly) { continue }
        if (-not $PSCmdlet.ShouldProcess($package.DisplayName, 'Remove provisioned package')) { continue }

        try {
            $null = Remove-AppxProvisionedPackage -Online -PackageName $package.PackageName -ErrorAction Stop
            $finding.Status = 'Removed'
            Write-LogEntry -Tag 'appx' -Level Success -Message "removed provisioned package: $($package.DisplayName)"
        }
        catch {
            Write-RemovalFailure -Finding $finding -Tag 'appx' -Target $package.DisplayName -ErrorRecord $_
        }
    }

    if ($packages.Count -eq 0 -and $provisioned.Count -eq 0) {
        Write-LogEntry -Tag 'appx' -Message 'no Store or provisioned Python packages found'
    }
}

function Get-PythonInstallation {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    foreach ($root in $script:uninstallRoot) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $scope = if ($root.StartsWith('HKCU:')) { 'User' } else { 'Machine' }

        foreach ($entry in (Get-ChildItem -LiteralPath $root -ErrorAction Ignore)) {
            $properties = Get-ItemProperty -LiteralPath $entry.PSPath -ErrorAction Ignore
            if (-not $properties -or -not $properties.DisplayName) { continue }
            if ($properties.DisplayName -notmatch $script:pattern.InstallInclude) { continue }
            if ($properties.DisplayName -match $script:pattern.InstallExclude) { continue }

            [pscustomobject]@{
                DisplayName     = $properties.DisplayName
                InstallLocation = $properties.InstallLocation
                UninstallString = $properties.UninstallString
                RegistryPath    = $entry.PSPath
                Scope           = $scope
            }
        }
    }
}

function Get-UninstallExecutable {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$UninstallString)

    $command = $UninstallString.Trim()

    if ($command -match '^"([^"]+\.exe)"\s*(.*)$') {
        return @{ Path = $Matches[1]; Argument = $Matches[2].Trim() }
    }
    if ($command -match '^([^"\s]+\.exe)\s*(.*)$') {
        return @{ Path = $Matches[1]; Argument = $Matches[2].Trim() }
    }
    if ($command -match '^(.+?\.exe)\s*(.*)$') {
        return @{ Path = $Matches[1].Trim(); Argument = $Matches[2].Trim() }
    }
    return $null
}

function Invoke-MsiUninstall {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$ProductCode,

        [Parameter(Mandatory)]
        [string]$DisplayName
    )

    if (-not $PSCmdlet.ShouldProcess($DisplayName, 'Uninstall via Windows Installer')) { return $false }

    $lastExit = $null
    for ($attempt = 1; $attempt -le $script:config.MsiRetryCount; $attempt++) {
        Write-LogEntry -Tag 'uninstall' `
            -Message "msiexec /x $ProductCode (attempt $attempt/$($script:config.MsiRetryCount))"

        try {
            $process = Start-Process -FilePath 'MsiExec.exe' `
                -ArgumentList @('/X', $ProductCode, '/qn', '/norestart') `
                -PassThru -NoNewWindow -ErrorAction Stop
        }
        catch [System.ComponentModel.Win32Exception] {
            Write-LogEntry -Tag 'uninstall' -Level Error -Message "unable to start msiexec: $($_.Exception.Message)"
            return $false
        }

        if (-not $process.WaitForExit($script:config.TimeoutSeconds * 1000)) {
            $process.Kill($true)
            Write-LogEntry -Tag 'uninstall' -Level Error `
                -Message "msiexec timed out after $($script:config.TimeoutSeconds)s for $DisplayName"
            return $false
        }

        $lastExit = $process.ExitCode
        if ($lastExit -in @(0, 1605, 3010)) {
            Write-LogEntry -Tag 'uninstall' -Level Success -Message "uninstalled: $DisplayName (exit $lastExit)"
            return $true
        }
        if ($lastExit -ne 1618) { break }

        Write-LogEntry -Tag 'uninstall' -Level Warn `
            -Message "another installation is in progress; retrying in $($script:config.MsiRetryDelaySeconds)s"
        Start-Sleep -Seconds $script:config.MsiRetryDelaySeconds
    }

    $reason = switch ($lastExit) {
        1601 { 'the Windows Installer service is not accessible' }
        1602 { 'the operation was cancelled' }
        1603 { 'a fatal error occurred during uninstallation' }
        1618 { 'another installation remained in progress' }
        1619 { 'the installation package could not be opened' }
        1633 { 'the platform is not supported by this package' }
        default { 'the installer reported an unrecognised failure' }
    }
    Write-LogEntry -Tag 'uninstall' -Level Error -Message "uninstall failed: $DisplayName (exit $lastExit) - $reason"
    return $false
}

function Test-UninstallerTrust {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [ValidateSet('User', 'Machine')]
        [string]$Scope
    )

    $signature = Get-AuthenticodeSignature -FilePath $Path -ErrorAction Ignore
    $isValid = $null -ne $signature -and $signature.Status -eq 'Valid'
    $signer = if ($signature -and $signature.SignerCertificate) {
        $signature.SignerCertificate.Subject
    }
    else {
        'unsigned'
    }

    Write-LogEntry -Tag 'uninstall' -Message "uninstaller signature: $Path [$signer]"

    if ($Scope -eq 'Machine' -or $isValid) { return $true }

    Write-LogEntry -Tag 'uninstall' -Level Error `
        -Message 'refusing to run an unsigned uninstaller recorded under HKCU; that key is writable without elevation'
    Add-ManualAction -Item $Path `
        -Reason 'unsigned uninstaller recorded under HKCU; review it before running elevated' `
        -Command "& `"$Path`""
    return $false
}

function Invoke-ExeUninstall {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [AllowEmptyString()]
        [string]$Argument,

        [Parameter(Mandatory)]
        [string]$DisplayName,

        [Parameter(Mandatory)]
        [ValidateSet('User', 'Machine')]
        [string]$Scope
    )

    if (-not $PSCmdlet.ShouldProcess($DisplayName, 'Uninstall via vendor executable')) { return $false }
    if (-not (Test-UninstallerTrust -Path $Path -Scope $Scope)) { return $false }

    $base = $Argument.Trim()
    $attempts = @(
        if ($base -match '(?i)/uninstall') { "$base /quiet /norestart" }
        "$base /S".Trim()
        "$base /VERYSILENT /SUPPRESSMSGBOXES".Trim()
        $base
    ) | Where-Object { $_ } | Select-Object -Unique

    $timeoutMs = $script:config.ExeUninstallTimeoutSec * 1000

    foreach ($attempt in $attempts) {
        Write-LogEntry -Tag 'uninstall' -Message "running: `"$Path`" $attempt"

        try {
            $process = Start-Process -FilePath $Path -ArgumentList $attempt `
                -PassThru -NoNewWindow -ErrorAction Stop
        }
        catch [System.ComponentModel.Win32Exception] {
            Write-LogEntry -Tag 'uninstall' -Level Warn -Message "unable to start uninstaller: $($_.Exception.Message)"
            continue
        }

        if (-not $process.WaitForExit($timeoutMs)) {
            $process.Kill($true)
            Write-LogEntry -Tag 'uninstall' -Level Warn `
                -Message "uninstaller timed out after $($script:config.ExeUninstallTimeoutSec)s with: $attempt"
            continue
        }

        if ($process.ExitCode -in @(0, 3010)) {
            Write-LogEntry -Tag 'uninstall' -Level Success `
                -Message "uninstalled: $DisplayName (exit $($process.ExitCode))"
            return $true
        }

        Write-LogEntry -Tag 'uninstall' -Level Warn -Message "exit $($process.ExitCode) with: $attempt"
    }

    Write-LogEntry -Tag 'uninstall' -Level Error -Message "automatic uninstall failed: $DisplayName"
    Write-LogEntry -Tag 'uninstall' -Level Warn -Message "run manually: `"$Path`" $base"
    Add-ManualAction -Item $DisplayName -Reason 'every silent uninstall attempt failed' `
        -Command "& `"$Path`" $base"
    return $false
}

function Uninstall-TraditionalPython {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    Write-Section -Tag 'uninstall' -Title 'TRADITIONAL INSTALLATIONS'

    $installations = @(Get-PythonInstallation | Sort-Object DisplayName -Unique)
    if ($installations.Count -eq 0) {
        Write-LogEntry -Tag 'uninstall' -Message 'no registered Python installations found'
        return
    }

    if (-not $script:config.ScanOnly) {
        Write-LogEntry -Tag 'uninstall' `
            -Message 'component dependency failures are expected; leftovers are cleared by the registry phase'
    }

    foreach ($installation in $installations) {
        $finding = Add-Finding -Type 'Program' -Name $installation.DisplayName -Path $installation.InstallLocation
        Write-LogEntry -Tag 'uninstall' -Level Found `
            -Message "found: $($installation.DisplayName) [$($installation.Scope)]"

        if ($script:config.ScanOnly) { continue }

        if ([string]::IsNullOrWhiteSpace($installation.UninstallString)) {
            $finding.Status = 'Skipped'
            $finding.Reason = 'no uninstall command recorded'
            Add-ManualAction -Item $installation.DisplayName -Reason 'no uninstall command recorded'
            Write-LogEntry -Tag 'uninstall' -Level Warn `
                -Message "no uninstall command recorded for $($installation.DisplayName)"
            continue
        }

        $command = $installation.UninstallString.Trim()

        if ($command -match 'MsiExec' -and $command -match $script:pattern.MsiProductCode) {
            $succeeded = Invoke-MsiUninstall -ProductCode $Matches[0] -DisplayName $installation.DisplayName
            if (-not $WhatIfPreference) { $finding.Status = if ($succeeded) { 'Removed' } else { 'Failed' } }
            continue
        }

        $executable = Get-UninstallExecutable -UninstallString $command
        if (-not $executable) {
            $finding.Status = 'Skipped'
            $finding.Reason = 'unrecognised uninstall command'
            Add-ManualAction -Item $installation.DisplayName `
                -Reason 'unrecognised uninstall command' -Command $command
            Write-LogEntry -Tag 'uninstall' -Level Warn -Message "unrecognised uninstall command: $command"
            continue
        }

        if (-not (Test-Path -LiteralPath $executable.Path -PathType Leaf)) {
            $finding.Status = 'Skipped'
            $finding.Reason = "uninstaller executable missing: $($executable.Path)"
            Write-LogEntry -Tag 'uninstall' -Level Warn -Message "uninstaller missing: $($executable.Path)"
            continue
        }

        $succeeded = Invoke-ExeUninstall -Path $executable.Path -Argument $executable.Argument `
            -DisplayName $installation.DisplayName -Scope $installation.Scope
        if (-not $WhatIfPreference) { $finding.Status = if ($succeeded) { 'Removed' } else { 'Failed' } }
    }
}
#endregion

#region Environment Variables
function Backup-EnvironmentVariable {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param()

    if (-not $PSCmdlet.ShouldProcess($script:config.BackupFile, 'Write environment backup')) { return $false }

    $backup = [ordered]@{
        Timestamp = [datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss')
        Version   = $script:config.Version
        Path      = [ordered]@{}
        Variable  = [ordered]@{}
    }

    foreach ($scope in 'User', 'Machine') {
        $pathValue = Get-EnvironmentEntry -Scope $scope -Name 'Path'
        if ($pathValue) { $backup.Path[$scope] = $pathValue }

        $scoped = [ordered]@{}
        foreach ($name in $script:pythonVariable) {
            $value = Get-EnvironmentEntry -Scope $scope -Name $name
            if ($value) { $scoped[$name] = $value }
        }
        $backup.Variable[$scope] = $scoped
    }

    try {
        $backup | ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath $script:config.BackupFile -Encoding utf8 -ErrorAction Stop
        Write-LogEntry -Tag 'env_var' -Level Success -Message "backup written: $($script:config.BackupFile)"
        return $true
    }
    catch {
        Write-LogEntry -Tag 'env_var' -Level Error `
            -Message "backup failed: $($_.Exception.GetType().Name): $($_.Exception.Message)"
        return $false
    }
}

function Split-PathValue {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return [string[]]@() }
    return [string[]]@($Value -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Remove-EnvironmentVariable {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    Write-Section -Tag 'env_var' -Title 'ENVIRONMENT VARIABLES'

    if (-not $script:config.ScanOnly) { $null = Backup-EnvironmentVariable }

    $changed = $false

    foreach ($scope in 'User', 'Machine') {
        foreach ($name in $script:pythonVariable) {
            if (-not (Get-EnvironmentEntry -Scope $scope -Name $name)) { continue }

            $finding = Add-Finding -Type 'EnvironmentVariable' -Name "$name ($scope)" -Path $scope
            Write-LogEntry -Tag 'env_var' -Level Found -Message "found: $name ($scope)"

            if ($script:config.ScanOnly) { continue }

            try {
                if (Remove-EnvironmentEntry -Scope $scope -Name $name) {
                    $finding.Status = 'Removed'
                    $changed = $true
                    Write-LogEntry -Tag 'env_var' -Level Success -Message "removed: $name ($scope)"
                }
            }
            catch {
                Write-RemovalFailure -Finding $finding -Tag 'env_var' -Target "$name ($scope)" -ErrorRecord $_
            }
        }
    }

    if (Clear-PathVariable) { $changed = $true }
    if ($changed) { Send-SettingChange }
}

function Clear-PathVariable {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param()

    $changed = $false

    foreach ($scope in 'User', 'Machine') {
        $current = Get-EnvironmentEntry -Scope $scope -Name 'Path'
        if (-not $current) { continue }

        $entries = @(Split-PathValue -Value $current.Value)
        $retained = @($entries | Where-Object { $_ -notmatch $script:pattern.PathEntry })
        $removedCount = $entries.Count - $retained.Count
        $needsCompaction = $retained.Count -ne @($current.Value -split ';').Count

        if ($removedCount -eq 0 -and -not $needsCompaction) { continue }

        $finding = Add-Finding -Type 'Path' -Name "PATH ($scope): $removedCount entries" -Path $scope
        $reason = if ($removedCount -gt 0) {
            "$removedCount Python entr$(if ($removedCount -eq 1) { 'y' } else { 'ies' })"
        }
        else {
            'empty segments only'
        }
        Write-LogEntry -Tag 'path' -Level Found -Message "$scope PATH needs rewriting: $reason"

        foreach ($entry in ($entries | Where-Object { $_ -match $script:pattern.PathEntry })) {
            Write-LogEntry -Tag 'path' -Message "removing entry: $entry"
        }

        if ($script:config.ScanOnly) { continue }
        if (-not $PSCmdlet.ShouldProcess("PATH ($scope)", 'Remove Python entries')) { continue }

        $kind = if ($current.Kind -eq 'ExpandString') { 'ExpandString' } else { 'String' }
        try {
            if (Set-EnvironmentEntry -Scope $scope -Name 'Path' -Value ($retained -join ';') -Kind $kind) {
                $finding.Status = 'Removed'
                $changed = $true
                Write-LogEntry -Tag 'path' -Level Success -Message "$scope PATH rewritten as $kind"
            }
        }
        catch {
            Write-RemovalFailure -Finding $finding -Tag 'path' -Target "PATH ($scope)" -ErrorRecord $_
        }
    }

    return $changed
}

function Restore-EnvironmentVariable {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$BackupPath)

    Write-Section -Tag 'env_var' -Title 'ENVIRONMENT RESTORE'

    if (-not (Test-Path -LiteralPath $BackupPath -PathType Leaf)) {
        Write-LogEntry -Tag 'env_var' -Level Error -Message "backup not found: $BackupPath"
        return $false
    }

    try {
        $backup = Get-Content -LiteralPath $BackupPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch [System.ArgumentException] {
        Write-LogEntry -Tag 'env_var' -Level Error -Message "backup is not valid JSON: $BackupPath"
        return $false
    }
    catch [System.IO.IOException] {
        Write-LogEntry -Tag 'env_var' -Level Error -Message "unable to read backup: $($_.Exception.Message)"
        return $false
    }

    Write-LogEntry -Tag 'env_var' -Message "restoring from backup taken $($backup.Timestamp)"
    $restored = 0

    foreach ($scope in 'User', 'Machine') {
        $variables = $backup.Variable.$scope
        if ($variables) {
            foreach ($property in $variables.PSObject.Properties) {
                $kind = if ($property.Value.Kind -eq 'ExpandString') { 'ExpandString' } else { 'String' }
                if (Set-EnvironmentEntry -Scope $scope -Name $property.Name -Value $property.Value.Value -Kind $kind) {
                    $restored++
                    Write-LogEntry -Tag 'env_var' -Level Success -Message "restored: $($property.Name) ($scope)"
                }
            }
        }

        $pathEntry = $backup.Path.$scope
        if ($pathEntry) {
            $kind = if ($pathEntry.Kind -eq 'ExpandString') { 'ExpandString' } else { 'String' }
            if (Set-EnvironmentEntry -Scope $scope -Name 'Path' -Value $pathEntry.Value -Kind $kind) {
                $restored++
                Write-LogEntry -Tag 'env_var' -Level Success -Message "restored: PATH ($scope) as $kind"
            }
        }
    }

    Send-SettingChange
    Write-LogEntry -Tag 'env_var' -Level Success -Message "restore complete; $restored value(s) written"
    return $true
}
#endregion

#region Filesystem Removal
function Remove-PythonDirectory {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    Write-Section -Tag 'directory' -Title 'PYTHON DIRECTORIES'

    $matched = [System.Collections.Generic.List[string]]::new()
    foreach ($glob in $script:directoryGlob) {
        $parent = Split-Path -Path $glob -Parent
        $leaf = Split-Path -Path $glob -Leaf
        if (-not (Test-Path -LiteralPath $parent)) { continue }

        Get-ChildItem -LiteralPath $parent -Filter $leaf -Directory -Force -ErrorAction Ignore |
            ForEach-Object { if (-not $matched.Contains($_.FullName)) { $matched.Add($_.FullName) } }
    }

    if ($matched.Count -eq 0) {
        Write-LogEntry -Tag 'directory' -Message 'no Python directories found'
        return
    }

    Write-LogEntry -Tag 'directory' `
        -Message "sizing $($matched.Count) directories across $($script:config.MaxParallelism) workers"
    $statistics = Get-DirectoryStatisticSet -Path $matched.ToArray()

    foreach ($path in $matched) {
        Remove-ItemSafely -Path $path -Name (Split-Path -Path $path -Leaf) `
            -Type 'Directory' -Tag 'directory' -Statistic $statistics[$path]
    }
}

function Remove-PythonConfigFile {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    Write-Section -Tag 'config_file' -Title 'CONFIGURATION FILES'

    $found = 0
    foreach ($file in $script:configFile) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
        $found++
        Remove-FileSafely -Path $file -Name (Split-Path -Path $file -Leaf) -Type 'ConfigFile' -Tag 'config_file'
    }

    if ($found -eq 0) { Write-LogEntry -Tag 'config_file' -Message 'no Python configuration files found' }
}

function Remove-PythonShortcut {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    Write-Section -Tag 'shortcut' -Title 'DESKTOP SHORTCUTS'

    $found = 0
    foreach ($desktop in $script:desktopPath) {
        if (-not (Test-Path -LiteralPath $desktop)) { continue }

        foreach ($filter in $script:shortcutFilter) {
            foreach ($shortcut in (Get-ChildItem -LiteralPath $desktop -Filter $filter -File -ErrorAction Ignore)) {
                $found++
                Remove-FileSafely -Path $shortcut.FullName -Name $shortcut.Name -Type 'Shortcut' -Tag 'shortcut'
            }
        }
    }

    if ($found -eq 0) { Write-LogEntry -Tag 'shortcut' -Message 'no Python desktop shortcuts found' }
}

function Remove-PythonTempFile {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    Write-Section -Tag 'temp_cache' -Title 'TEMPORARY FILES AND CACHES'

    $cutoff = [datetime]::Now.AddDays(-$script:config.TempFileMinimumAgeDays)
    $found = 0

    foreach ($location in $script:tempLocation) {
        if ([string]::IsNullOrWhiteSpace($location.Path)) { continue }
        if (-not (Test-Path -LiteralPath $location.Path)) { continue }

        $items = Get-ChildItem -LiteralPath $location.Path -Filter $location.Filter -Force -ErrorAction Ignore
        foreach ($item in $items) {
            if ($location.AgeChecked -and $item.LastWriteTime -gt $cutoff) { continue }
            $found++
            Remove-ItemSafely -Path $item.FullName -Name $item.Name -Type 'TempFile' -Tag 'temp_cache'
        }
    }

    if ($found -eq 0) {
        Write-LogEntry -Tag 'temp_cache' `
            -Message "nothing to clear; items newer than $($script:config.TempFileMinimumAgeDays) day(s) are kept"
    }
}

function Get-ScanRootDirectory {
    [CmdletBinding()]
    [OutputType([System.IO.DirectoryInfo])]
    param([Parameter(Mandatory)][string]$Path)

    # Windows seeds the profile with legacy junctions such as "My Documents". Descending through them
    # would report every environment twice and double-count its size.
    $reparse = [System.IO.FileAttributes]::ReparsePoint
    return Get-ChildItem -LiteralPath $Path -Directory -Force -ErrorAction Ignore | Where-Object {
        -not ($_.Attributes -band $reparse) -and $_.FullName -notmatch $script:pattern.ScanExclusion
    }
}

function Remove-VirtualEnvironment {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    Write-Section -Tag 'venv' -Title 'VIRTUAL ENVIRONMENTS'

    $exclusion = $script:pattern.ScanExclusion
    $topLevel = @(Get-ScanRootDirectory -Path $env:USERPROFILE)

    Write-LogEntry -Tag 'venv' `
        -Message "scanning $env:USERPROFILE to depth $($script:config.MaxScanDepth) across $($topLevel.Count) subtrees"

    $childDepth = $script:config.MaxScanDepth - 1
    $throttle = [Math]::Max(1, [Math]::Min($topLevel.Count, $script:config.MaxParallelism))

    $descendants = @()
    if ($topLevel.Count -gt 0) {
        $descendants = @($topLevel.FullName | ForEach-Object -ThrottleLimit $throttle -Parallel {
                $found = Get-ChildItem -LiteralPath $_ -Directory -Recurse `
                    -Depth $using:childDepth -Force -ErrorAction Ignore
                foreach ($directory in $found) {
                    if ($directory.FullName -notmatch $using:exclusion) { $directory.FullName }
                }
            })
    }

    $candidates = @($topLevel.FullName) + $descendants
    Write-LogEntry -Tag 'venv' -Message "scanned $($candidates.Count) directories"

    $targets = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($path in $candidates) {
        $leaf = Split-Path -Path $path -Leaf
        if ($leaf -in @('.venv', 'venv', 'env')) {
            $scriptsActivate = Join-Path $path 'Scripts\activate'
            $binActivate = Join-Path $path 'bin\activate'
            if ((Test-Path -LiteralPath $scriptsActivate) -or (Test-Path -LiteralPath $binActivate)) {
                $targets.Add(@{ Path = $path; Type = 'VirtualEnv'; Name = "venv: $path" })
                continue
            }
        }
        if ((Test-Path -LiteralPath (Join-Path $path 'conda-meta')) -and $path -notmatch $script:pattern.CondaBaseEnv) {
            $targets.Add(@{ Path = $path; Type = 'CondaEnv'; Name = "conda: $leaf" })
        }
    }

    $poetryRoot = Join-Path $env:LOCALAPPDATA 'pypoetry\Cache\virtualenvs'
    if (Test-Path -LiteralPath $poetryRoot) {
        foreach ($item in (Get-ChildItem -LiteralPath $poetryRoot -Directory -ErrorAction Ignore)) {
            $targets.Add(@{ Path = $item.FullName; Type = 'PoetryEnv'; Name = "poetry: $($item.Name)" })
        }
    }

    $pipenvRoot = Join-Path $env:USERPROFILE '.local\share\virtualenvs'
    if (Test-Path -LiteralPath $pipenvRoot) {
        foreach ($item in (Get-ChildItem -LiteralPath $pipenvRoot -Directory -ErrorAction Ignore)) {
            $targets.Add(@{ Path = $item.FullName; Type = 'PipenvEnv'; Name = "pipenv: $($item.Name)" })
        }
    }

    if ($targets.Count -eq 0) {
        Write-LogEntry -Tag 'venv' -Message 'no virtual environments found'
        return
    }

    $summary = $targets | Group-Object { $_.Type } | ForEach-Object { "$($_.Count) $($_.Name)" }
    Write-LogEntry -Tag 'venv' -Message "found $($targets.Count) environment(s): $($summary -join ', ')"

    $statistics = Get-DirectoryStatisticSet -Path @($targets.Path)
    foreach ($target in $targets) {
        Remove-ItemSafely -Path $target.Path -Name $target.Name -Type $target.Type `
            -Tag 'venv' -Statistic $statistics[$target.Path]
    }
}

function Remove-AppExecutionAlias {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    Write-Section -Tag 'alias' -Title 'APP EXECUTION ALIASES'

    $aliasRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
    if (-not (Test-Path -LiteralPath $aliasRoot)) {
        Write-LogEntry -Tag 'alias' -Message 'no WindowsApps alias directory present'
        return
    }

    $found = 0
    foreach ($filter in @('python*.exe', 'pip*.exe')) {
        foreach ($alias in (Get-ChildItem -LiteralPath $aliasRoot -Filter $filter -File -ErrorAction Ignore)) {
            if ($alias.Length -gt 1KB) { continue }
            $found++
            Remove-FileSafely -Path $alias.FullName -Name $alias.Name -Type 'AppAlias' -Tag 'alias'
        }
    }

    if ($found -eq 0) { Write-LogEntry -Tag 'alias' -Message 'no Python app execution aliases found' }
}

function Remove-PythonLauncher {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    Write-Section -Tag 'launcher' -Title 'PYTHON LAUNCHER'

    $found = 0
    foreach ($binary in $script:config.LauncherBinary) {
        if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) { continue }
        $found++
        Remove-FileSafely -Path $binary -Name (Split-Path -Path $binary -Leaf) -Type 'Launcher' -Tag 'launcher'
    }

    if ($found -eq 0) { Write-LogEntry -Tag 'launcher' -Message 'no launcher binaries in the Windows directory' }
}
#endregion

#region Registry Cleanup
function Clear-Registry {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    Write-Section -Tag 'registry' -Title 'REGISTRY CLEANUP'

    Remove-RegistryKeySet -Path $script:coreRegistryKey -Type 'Registry' -Tag 'registry'
    Remove-RegistryKeySet -Path $script:associationKey -Type 'FileAssociation' -Tag 'registry'
    Remove-RegistryKeySet -Path $script:appPathKey -Type 'AppPath' -Tag 'registry'
    Remove-RegistryKeySet -Path $script:userChoiceKey -Type 'UserChoice' -Tag 'registry'

    Clear-OrphanedUninstallEntry
    Clear-SharedDllReference
}

function Test-InstallationPresent {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][psobject]$Installation)

    if (-not [string]::IsNullOrWhiteSpace($Installation.InstallLocation)) {
        return (Test-Path -LiteralPath $Installation.InstallLocation)
    }

    # Windows Installer owns its own registration, so an MSI entry with no install location cannot be
    # proven orphaned from here; treating it as present avoids stranding a still-registered product.
    if ([string]::IsNullOrWhiteSpace($Installation.UninstallString)) { return $true }
    if ($Installation.UninstallString -match 'MsiExec') { return $true }

    $executable = Get-UninstallExecutable -UninstallString $Installation.UninstallString
    if (-not $executable) { return $true }
    return (Test-Path -LiteralPath $executable.Path -PathType Leaf)
}

function Clear-OrphanedUninstallEntry {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $orphans = @(Get-PythonInstallation | Where-Object { -not (Test-InstallationPresent -Installation $_) })
    if ($orphans.Count -eq 0) {
        Write-LogEntry -Tag 'registry' -Message 'no orphaned uninstall entries found'
        return
    }

    foreach ($orphan in $orphans) {
        $finding = Add-Finding -Type 'OrphanedUninstall' -Name $orphan.DisplayName -Path $orphan.RegistryPath
        Write-LogEntry -Tag 'registry' -Level Found -Message "found orphaned uninstall entry: $($orphan.DisplayName)"

        if ($script:config.ScanOnly) { continue }
        if (-not $PSCmdlet.ShouldProcess($orphan.RegistryPath, 'Remove orphaned uninstall entry')) { continue }

        try {
            Remove-Item -LiteralPath $orphan.RegistryPath -Recurse -Force -ErrorAction Stop
            $finding.Status = 'Removed'
            Write-LogEntry -Tag 'registry' -Level Success -Message "removed orphaned entry: $($orphan.DisplayName)"
        }
        catch {
            Write-RemovalFailure -Finding $finding -Tag 'registry' -Target $orphan.RegistryPath -ErrorRecord $_
        }
    }
}

function Clear-SharedDllReference {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if (-not (Test-Path -LiteralPath $script:sharedDllKey)) { return }

    $properties = Get-ItemProperty -LiteralPath $script:sharedDllKey -ErrorAction Ignore
    if (-not $properties) {
        Write-LogEntry -Tag 'registry' -Level Warn -Message 'unable to read shared DLL references'
        return
    }

    $reserved = @('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider')
    $found = 0

    foreach ($property in $properties.PSObject.Properties) {
        if ($property.Name -in $reserved) { continue }
        if ($property.Name -notmatch $script:pattern.SharedDll) { continue }
        if (Test-Path -LiteralPath $property.Name) { continue }

        $found++
        $finding = Add-Finding -Type 'SharedDll' -Name (Split-Path -Path $property.Name -Leaf) -Path $property.Name
        Write-LogEntry -Tag 'registry' -Level Found -Message "found orphaned shared DLL reference: $($property.Name)"

        if ($script:config.ScanOnly) { continue }
        if (-not $PSCmdlet.ShouldProcess($property.Name, 'Remove shared DLL reference')) { continue }

        try {
            Remove-ItemProperty -LiteralPath $script:sharedDllKey -Name $property.Name -Force -ErrorAction Stop
            $finding.Status = 'Removed'
            Write-LogEntry -Tag 'registry' -Level Success -Message "removed shared DLL reference: $($property.Name)"
        }
        catch {
            Write-RemovalFailure -Finding $finding -Tag 'registry' -Target $property.Name -ErrorRecord $_
        }
    }

    if ($found -eq 0) { Write-LogEntry -Tag 'registry' -Message 'no orphaned shared DLL references found' }
}
#endregion

#region PowerShell Profiles
function Remove-ProfileBlock {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    Write-Section -Tag 'profile' -Title 'POWERSHELL PROFILES'

    $modified = 0

    foreach ($path in $script:profilePath) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }

        # This phase edits and deletes files directly, so it must consult the same gate the
        # filesystem primitives use; otherwise a protected location would still be modified.
        if (-not (Test-PathSafe -Path $path)) {
            Add-SkippedFinding -Type 'Profile' -Name (Split-Path -Path $path -Leaf) -Path $path `
                -Reason 'blocked by the protected path policy'
            continue
        }

        try {
            $content = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        }
        catch [System.IO.IOException] {
            Write-LogEntry -Tag 'profile' -Level Error -Message "unable to read $path - $($_.Exception.Message)"
            continue
        }

        if ([string]::IsNullOrWhiteSpace($content)) { continue }

        if ($content -match $script:pattern.CondaInitMarker) {
            $modified += Remove-CondaInitBlock -Path $path -Content $content
        }

        foreach ($line in (Get-ProfilePythonLine -Content $content)) {
            Write-LogEntry -Tag 'profile' -Level Warn -Message "manual review needed in ${path}: $line"
            Add-ManualAction -Item $path -Reason "Python-related profile line needs review - $line"
        }
    }

    if ($modified -eq 0) { Write-LogEntry -Tag 'profile' -Message 'no conda initialisation blocks found' }
}

function Get-ProfilePythonLine {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Content)

    $lines = $Content -split '\r?\n'
    $results = [System.Collections.Generic.List[string]]::new()

    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = $lines[$index].Trim()

        if ($line -match $script:pattern.CondaInitMarker) {
            while ($index -lt $lines.Count -and $lines[$index] -notmatch '#endregion') { $index++ }
            continue
        }
        if (-not $line -or $line -match '^\s*#') { continue }
        if ($line -match $script:pattern.ProfilePythonUse) { $results.Add("line $($index + 1): $line") }
    }

    return $results.ToArray()
}

function Remove-CondaInitBlock {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Content
    )

    $finding = Add-Finding -Type 'Profile' -Name 'conda initialisation block' -Path $Path
    Write-LogEntry -Tag 'profile' -Level Found -Message "found conda initialisation block: $Path"

    if ($script:config.ScanOnly) { return 0 }
    if (-not $PSCmdlet.ShouldProcess($Path, 'Remove conda initialisation block')) { return 0 }

    $backupPath = "$Path.bak_$([datetime]::Now.ToString('yyyyMMdd_HHmmss'))"

    try {
        Copy-Item -LiteralPath $Path -Destination $backupPath -Force -ErrorAction Stop
        $backupName = Split-Path -Path $backupPath -Leaf
        $null = Add-Finding -Type 'ProfileBackup' -Name $backupName -Path $backupPath
        Write-LogEntry -Tag 'profile' -Message "profile backed up: $backupPath"

        $updated = ($Content -replace $script:pattern.CondaInitBlock, '').Trim()
        if ($updated.Length -eq 0) {
            Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
            Write-LogEntry -Tag 'profile' -Level Success -Message "removed profile containing only conda init: $Path"
        }
        else {
            Set-Content -LiteralPath $Path -Value $updated -Encoding utf8 -ErrorAction Stop
            Write-LogEntry -Tag 'profile' -Level Success -Message "removed conda initialisation block: $Path"
        }

        $finding.Status = 'Removed'
        return 1
    }
    catch {
        Write-RemovalFailure -Finding $finding -Tag 'profile' -Target $Path -ErrorRecord $_
        return 0
    }
}
#endregion

#region Verification and Reporting
function Sync-ProcessPath {
    [CmdletBinding()]
    param()

    $parts = foreach ($scope in 'Machine', 'User') {
        $entry = Get-EnvironmentEntry -Scope $scope -Name 'Path'
        if ($entry) { $entry.Value }
    }

    $combined = ($parts | Where-Object { $_ }) -join ';'
    $env:Path = [Environment]::ExpandEnvironmentVariables($combined)
    Write-LogEntry -Tag 'verify' -Message 'refreshed the process PATH from the registry'
}

function Test-PostRemoval {
    [CmdletBinding()]
    param()

    Write-Section -Tag 'verify' -Title 'POST-REMOVAL VERIFICATION'
    Sync-ProcessPath

    foreach ($executable in @('python', 'py')) {
        $located = @(where.exe $executable 2>$null)
        if ($LASTEXITCODE -eq 0 -and $located.Count -gt 0) {
            foreach ($hit in $located) {
                $script:state.VerificationIssue.Add("$executable resolves to $hit")
                Write-LogEntry -Tag 'verify' -Level Error -Message "$executable still on PATH: $hit"
            }
        }
        else {
            Write-LogEntry -Tag 'verify' -Level Success -Message "$executable is not on PATH"
        }
    }

    foreach ($binary in $script:config.LauncherBinary) {
        if (Test-Path -LiteralPath $binary -PathType Leaf) {
            $script:state.VerificationIssue.Add("launcher binary remains: $binary")
            Write-LogEntry -Tag 'verify' -Level Error -Message "launcher binary remains: $binary"
            Write-LogEntry -Tag 'verify' -Level Warn `
                -Message "remove manually with: Remove-Item -LiteralPath '$binary' -Force"
            Add-ManualAction -Item $binary -Reason 'the launcher uninstaller did not remove this binary' `
                -Command "Remove-Item -LiteralPath '$binary' -Force"
        }
    }

    $remainingKeys = @($script:verificationRegistryKey | Where-Object { Test-Path -LiteralPath $_ })
    if ($remainingKeys.Count -eq 0) {
        Write-LogEntry -Tag 'verify' -Level Success `
            -Message "no registry keys remain ($(@($script:verificationRegistryKey).Count) checked)"
    }
    else {
        foreach ($key in $remainingKeys) {
            $script:state.VerificationIssue.Add("registry key remains: $key")
            Write-LogEntry -Tag 'verify' -Level Error -Message "registry key remains: $key"
        }
    }

    $remainingVariables = @(
        foreach ($name in $script:verificationVariable) {
            foreach ($scope in 'User', 'Machine') {
                if (Get-EnvironmentEntry -Scope $scope -Name $name) { "$name ($scope)" }
            }
        }
    )
    if ($remainingVariables.Count -eq 0) {
        Write-LogEntry -Tag 'verify' -Level Success `
            -Message "no environment variables remain ($($script:verificationVariable.Count) checked)"
    }
    else {
        foreach ($variable in $remainingVariables) {
            $script:state.VerificationIssue.Add("environment variable remains: $variable")
            Write-LogEntry -Tag 'verify' -Level Error -Message "environment variable remains: $variable"
        }
    }

    $remainingDirectories = @(
        foreach ($glob in $script:verificationGlob) {
            $parent = Split-Path -Path $glob -Parent
            $leaf = Split-Path -Path $glob -Leaf
            if (-not (Test-Path -LiteralPath $parent)) { continue }
            Get-ChildItem -LiteralPath $parent -Filter $leaf -Directory -ErrorAction Ignore |
                Select-Object -ExpandProperty FullName
        }
    )
    if ($remainingDirectories.Count -eq 0) {
        Write-LogEntry -Tag 'verify' -Level Success `
            -Message "no install directories remain ($(@($script:verificationGlob).Count) locations checked)"
    }
    else {
        foreach ($directory in $remainingDirectories) {
            $script:state.VerificationIssue.Add("directory remains: $directory")
            Write-LogEntry -Tag 'verify' -Level Error -Message "directory remains: $directory"
        }
    }

    if ($script:state.VerificationIssue.Count -eq 0) {
        Write-LogEntry -Tag 'verify' -Level Success -Message 'verification passed; the system is Python-free'
        return
    }

    Write-LogEntry -Tag 'verify' -Level Warn `
        -Message "verification failed with $($script:state.VerificationIssue.Count) remaining component(s)"
}

function New-Report {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if ($script:state.Findings.Count -eq 0) { return }
    if (-not $PSCmdlet.ShouldProcess($script:config.ReportFile, 'Write CSV report')) { return }

    try {
        $script:state.Findings |
            Export-Csv -LiteralPath $script:config.ReportFile -NoTypeInformation -Encoding utf8 -ErrorAction Stop
        Write-LogEntry -Tag 'report' -Level Success -Message "report written: $($script:config.ReportFile)"
    }
    catch {
        Write-LogEntry -Tag 'report' -Level Error `
            -Message "report failed: $($_.Exception.GetType().Name): $($_.Exception.Message)"
    }
}

function ConvertTo-MarkdownCell {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value,

        [int]$MaximumLength = 300
    )

    if ([string]::IsNullOrEmpty($Value)) { return '-' }

    $flat = ($Value -replace '\r?\n', ' ' -replace '\|', '\|').Trim()
    if ($flat.Length -eq 0) { return '-' }
    if ($flat.Length -gt $MaximumLength) { $flat = $flat.Substring(0, $MaximumLength - 3) + '...' }
    return $flat
}

function Get-ExitCodeDescription {
    [CmdletBinding()]
    [OutputType([string])]
    param([int]$ExitCode)

    switch ($ExitCode) {
        0 { 'completed with no failures' }
        1 { 'critical failure; the run was abandoned' }
        2 { 'completed, but one or more operations failed' }
        3 { 'completed, but verification found remaining components' }
        4 { 'cancelled at the confirmation prompt' }
        5 { 'pre-flight validation failed; nothing was changed' }
        default { 'unrecognised exit code' }
    }
}

function Get-RunMode {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ($script:config.RestoreMode) { return 'Restore' }
    if ($script:config.ScanOnly) { return 'Scan only (no changes)' }
    if ($WhatIfPreference) { return 'WhatIf preview (no changes)' }
    return 'Removal'
}

function Add-MarkdownFindingTable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Text.StringBuilder]$Builder,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Finding,

        [switch]$IncludeReason
    )

    $header = if ($IncludeReason) { '| Type | Name | Size | Reason |' } else { '| Type | Name | Size | Path |' }
    $divider = '| --- | --- | --- | --- |'
    [void]$Builder.AppendLine($header)
    [void]$Builder.AppendLine($divider)

    foreach ($item in ($Finding | Sort-Object Type, Name)) {
        $last = if ($IncludeReason) { $item.Reason } else { $item.Path }
        [void]$Builder.AppendLine(
            "| $(ConvertTo-MarkdownCell $item.Type) | $(ConvertTo-MarkdownCell $item.Name) | " +
            "$($item.Size) | $(ConvertTo-MarkdownCell $last) |")
    }
    [void]$Builder.AppendLine('')
}

function Write-MarkdownReport {
    [CmdletBinding()]
    [OutputType([void])]
    param()

    $builder = [System.Text.StringBuilder]::new()
    $findings = @($script:state.Findings)
    $elapsed = [Math]::Round(([datetime]::Now - $script:state.StartTime).TotalSeconds, 1)
    $removed = @($findings | Where-Object { $_.Status -eq 'Removed' })
    $failed = @($findings | Where-Object { $_.Status -eq 'Failed' })
    $skipped = @($findings | Where-Object { $_.Status -eq 'Skipped' })

    [void]$builder.AppendLine('# Python Removal Run Log')
    [void]$builder.AppendLine('')
    [void]$builder.AppendLine('## Summary')
    [void]$builder.AppendLine('')
    [void]$builder.AppendLine('| Key | Value |')
    [void]$builder.AppendLine('| --- | --- |')
    [void]$builder.AppendLine("| Script Version | $($script:config.Version) |")
    [void]$builder.AppendLine("| Generated | $([datetime]::Now.ToString('dd/MM/yyyy HH:mm:ss')) |")
    [void]$builder.AppendLine("| Mode | $(Get-RunMode) |")
    $exitCode = $script:state.ExitCode
    [void]$builder.AppendLine("| Exit Code | $exitCode - $(Get-ExitCodeDescription $exitCode) |")
    [void]$builder.AppendLine("| Runtime | ${elapsed}s |")
    [void]$builder.AppendLine("| Items Found | $($findings.Count) |")
    [void]$builder.AppendLine("| Items Removed | $($removed.Count) |")

    $failedCell = if ($failed.Count -gt 0) { "**$($failed.Count)** - see ``## Failures``" } else { '0' }
    [void]$builder.AppendLine("| Items Failed | $failedCell |")

    $skippedCell = if ($skipped.Count -gt 0) { "**$($skipped.Count)** - see ``## Skipped``" } else { '0' }
    [void]$builder.AppendLine("| Items Skipped | $skippedCell |")

    $skippedSize = Get-FindingSize -Status 'Skipped'
    if ($script:config.ScanOnly) {
        $reclaimable = (Get-FindingSize) - $skippedSize
        [void]$builder.AppendLine("| Reclaimable Size | $(Format-FileSize -Bytes $reclaimable) |")
    }
    else {
        [void]$builder.AppendLine("| Space Freed | $(Format-FileSize -Bytes (Get-FindingSize -Status 'Removed')) |")
    }
    if ($skippedSize -gt 0) {
        [void]$builder.AppendLine("| Left In Place By Skips | $(Format-FileSize -Bytes $skippedSize) |")
    }

    if ($script:state.VerificationIssue.Count -gt 0) {
        [void]$builder.AppendLine(
            "| **Verification** | **$($script:state.VerificationIssue.Count) component(s) remain** |")
    }
    if ($script:state.ManualAction.Count -gt 0) {
        $actionCount = $script:state.ManualAction.Count
        [void]$builder.AppendLine(
            "| **Manual Action** | **$actionCount item(s)** - see ``## Manual Action Required`` |")
    }
    [void]$builder.AppendLine("| Text Log | ``$($script:config.LogFile)`` |")
    [void]$builder.AppendLine("| CSV Report | ``$($script:config.ReportFile)`` |")
    if (Test-Path -LiteralPath $script:config.BackupFile) {
        [void]$builder.AppendLine("| Environment Backup | ``$($script:config.BackupFile)`` |")
        [void]$builder.AppendLine('| Undo Command | `.\RemovePython.ps1 -RestoreEnvironment <backup>` |')
    }
    [void]$builder.AppendLine('')

    [void]$builder.AppendLine('## Configuration')
    [void]$builder.AppendLine('')
    [void]$builder.AppendLine('| Setting | Value |')
    [void]$builder.AppendLine('| --- | --- |')
    foreach ($name in @(
            'ScanOnly', 'Force', 'SkipRestorePoint', 'SkipProcessCheck', 'SkipDiskCheck',
            'IncludeNetworkDrives', 'MinFreeDiskSpaceGB', 'TimeoutSeconds',
            'ExeUninstallTimeoutSec', 'MaxScanDepth', 'MaxParallelism')) {
        [void]$builder.AppendLine("| $name | $($script:config.$name) |")
    }
    [void]$builder.AppendLine("| LogDirectory | ``$($script:config.LogDirectory)`` |")
    [void]$builder.AppendLine('')

    [void]$builder.AppendLine('## Environment')
    [void]$builder.AppendLine('')
    [void]$builder.AppendLine('| Key | Value |')
    [void]$builder.AppendLine('| --- | --- |')
    [void]$builder.AppendLine("| Computer | $env:COMPUTERNAME |")
    [void]$builder.AppendLine("| PowerShell | $($PSVersionTable.PSVersion) |")
    [void]$builder.AppendLine("| OS | $([Environment]::OSVersion.VersionString) |")
    [void]$builder.AppendLine("| Processors | $([Environment]::ProcessorCount) |")
    [void]$builder.AppendLine("| System Drive | $env:SystemDrive |")
    [void]$builder.AppendLine('')

    if ($script:state.PhaseTiming.Count -gt 0) {
        [void]$builder.AppendLine('## Phase Timings')
        [void]$builder.AppendLine('')
        [void]$builder.AppendLine('| Phase | Duration | Items Found |')
        [void]$builder.AppendLine('| --- | --- | --- |')
        foreach ($phase in $script:state.PhaseTiming) {
            [void]$builder.AppendLine("| $($phase.Name) | $($phase.Seconds)s | $($phase.Findings) |")
        }
        [void]$builder.AppendLine('')
    }

    if ($findings.Count -gt 0) {
        [void]$builder.AppendLine('## Findings by Type')
        [void]$builder.AppendLine('')
        [void]$builder.AppendLine('| Type | Found | Removed | Failed | Skipped | Size |')
        [void]$builder.AppendLine('| --- | --- | --- | --- | --- | --- |')
        foreach ($group in ($findings | Group-Object Type | Sort-Object Name)) {
            $bytes = [int64](($group.Group | Measure-Object -Property SizeBytes -Sum).Sum ?? 0)
            $groupRemoved = @($group.Group | Where-Object { $_.Status -eq 'Removed' }).Count
            $groupFailed = @($group.Group | Where-Object { $_.Status -eq 'Failed' }).Count
            $groupSkipped = @($group.Group | Where-Object { $_.Status -eq 'Skipped' }).Count
            [void]$builder.AppendLine(
                "| $($group.Name) | $($group.Count) | $groupRemoved | $groupFailed | $groupSkipped | " +
                "$(Format-FileSize -Bytes $bytes) |")
        }
        [void]$builder.AppendLine('')
    }

    if ($failed.Count -gt 0) {
        [void]$builder.AppendLine('## Failures')
        [void]$builder.AppendLine('')
        [void]$builder.AppendLine('> Found, attempted, and the operation did not succeed.')
        [void]$builder.AppendLine('')
        foreach ($item in ($failed | Sort-Object Type, Name)) {
            [void]$builder.AppendLine("### $(ConvertTo-MarkdownCell $item.Name)")
            [void]$builder.AppendLine('')
            [void]$builder.AppendLine("- **Type:** $($item.Type)")
            [void]$builder.AppendLine("- **Path:** ``$($item.Path)``")
            [void]$builder.AppendLine("- **Reason:** $(ConvertTo-MarkdownCell $item.Reason -MaximumLength 2000)")
            [void]$builder.AppendLine('')
        }
    }

    if ($skipped.Count -gt 0) {
        [void]$builder.AppendLine('## Skipped')
        [void]$builder.AppendLine('')
        [void]$builder.AppendLine('> These items were found but deliberately left alone. Nothing was attempted.')
        [void]$builder.AppendLine('')
        Add-MarkdownFindingTable -Builder $builder -Finding $skipped -IncludeReason
    }

    if ($script:state.BlockedPath.Count -gt 0) {
        [void]$builder.AppendLine('## Paths Refused by the Safety Gate')
        [void]$builder.AppendLine('')
        [void]$builder.AppendLine('| Path | Reason |')
        [void]$builder.AppendLine('| --- | --- |')
        foreach ($blocked in ($script:state.BlockedPath | Sort-Object Path)) {
            [void]$builder.AppendLine(
                "| ``$(ConvertTo-MarkdownCell $blocked.Path)`` | $(ConvertTo-MarkdownCell $blocked.Reason) |")
        }
        [void]$builder.AppendLine('')
    }

    if ($removed.Count -gt 0) {
        [void]$builder.AppendLine('## Removed')
        [void]$builder.AppendLine('')
        [void]$builder.AppendLine('<details>')
        [void]$builder.AppendLine("<summary>$($removed.Count) item(s) removed</summary>")
        [void]$builder.AppendLine('')
        Add-MarkdownFindingTable -Builder $builder -Finding $removed
        [void]$builder.AppendLine('</details>')
        [void]$builder.AppendLine('')
    }

    if ($script:state.VerificationIssue.Count -gt 0) {
        [void]$builder.AppendLine('## Verification')
        [void]$builder.AppendLine('')
        [void]$builder.AppendLine('> Components still present after removal.')
        [void]$builder.AppendLine('')
        foreach ($issue in $script:state.VerificationIssue) {
            [void]$builder.AppendLine("- $(ConvertTo-MarkdownCell $issue)")
        }
        [void]$builder.AppendLine('')
    }

    if ($script:state.ManualAction.Count -gt 0) {
        [void]$builder.AppendLine('## Manual Action Required')
        [void]$builder.AppendLine('')
        foreach ($action in $script:state.ManualAction) {
            [void]$builder.AppendLine("- **$(ConvertTo-MarkdownCell $action.Item)**")
            [void]$builder.AppendLine("  - Reason: $(ConvertTo-MarkdownCell $action.Reason)")
            if ($action.Command) {
                [void]$builder.AppendLine("  - Command: ``$(ConvertTo-MarkdownCell $action.Command)``")
            }
        }
        [void]$builder.AppendLine('')
    }

    Add-MarkdownErrorSection -Builder $builder

    if ($script:state.Transcript.Length -gt 0) {
        [void]$builder.AppendLine('## Console Output')
        [void]$builder.AppendLine('')
        [void]$builder.AppendLine('<details>')
        [void]$builder.AppendLine('<summary>Full tagged transcript</summary>')
        [void]$builder.AppendLine('')
        [void]$builder.AppendLine('```')
        [void]$builder.Append($script:state.Transcript.ToString())
        [void]$builder.AppendLine('```')
        [void]$builder.AppendLine('')
        [void]$builder.AppendLine('</details>')
    }

    try {
        # Written with the .NET API rather than Set-Content: Set-Content honours ShouldProcess, so
        # -WhatIf would silently skip the report in the mode it is most useful for.
        [System.IO.File]::WriteAllText(
            $script:config.MarkdownFile, $builder.ToString(), [System.Text.UTF8Encoding]::new($false))
        Write-Information "[report] review written: $($script:config.MarkdownFile)"
    }
    catch {
        Write-Warning "[report] review write failed: $($_.Exception.GetType().Name): $($_.Exception.Message)"
    }
}

function Add-MarkdownErrorSection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Text.StringBuilder]$Builder
    )

    $newErrorCount = $Error.Count - $script:state.ErrorCountAtStart
    if ($newErrorCount -le 0) { return }

    [void]$Builder.AppendLine('## PowerShell Errors')
    [void]$Builder.AppendLine('')
    [void]$Builder.AppendLine("$newErrorCount error record(s) were raised during this run.")
    [void]$Builder.AppendLine('')
    [void]$Builder.AppendLine('```')

    $records = @($Error[0..($newErrorCount - 1)])
    [array]::Reverse($records)

    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($record in $records) {
        $line = $record.InvocationInfo.ScriptLineNumber
        $key = "${line}:$($record.Exception.Message)"
        if (-not $seen.Add($key)) { continue }

        [void]$Builder.AppendLine("$($record.Exception.GetType().Name) at line $line")
        [void]$Builder.AppendLine($record.Exception.Message)
        [void]$Builder.AppendLine('')
    }
    [void]$Builder.AppendLine('```')
    [void]$Builder.AppendLine('')
}

function Write-Summary {
    [CmdletBinding()]
    param()

    Write-Section -Tag 'main' -Title 'SUMMARY'

    $removed = Get-FindingCount -Status 'Removed'
    $failed = Get-FindingCount -Status 'Failed'
    $skipped = Get-FindingCount -Status 'Skipped'

    Write-LogEntry -Tag 'main' -Message "items found: $($script:state.Findings.Count)"
    Write-LogEntry -Tag 'main' -Level Success -Message "items removed: $removed"
    $failedLevel = if ($failed -gt 0) { 'Error' } else { 'Info' }
    $skippedLevel = if ($skipped -gt 0) { 'Warn' } else { 'Info' }
    Write-LogEntry -Tag 'main' -Level $failedLevel -Message "items failed: $failed"
    Write-LogEntry -Tag 'main' -Level $skippedLevel -Message "items skipped: $skipped"

    if ($removed + $failed -gt 0) {
        $rate = [Math]::Round(($removed / ($removed + $failed)) * 100, 1)
        Write-LogEntry -Tag 'main' -Message "success rate: $rate%"
    }

    $skippedSize = Get-FindingSize -Status 'Skipped'
    if ($script:config.ScanOnly) {
        $reclaimable = (Get-FindingSize) - $skippedSize
        Write-LogEntry -Tag 'main' -Message "reclaimable size: $(Format-FileSize -Bytes $reclaimable)"
    }
    else {
        Write-LogEntry -Tag 'main' -Message "space freed: $(Format-FileSize -Bytes (Get-FindingSize -Status 'Removed'))"
    }
    if ($skippedSize -gt 0) {
        Write-LogEntry -Tag 'main' -Message "size left in place by skips: $(Format-FileSize -Bytes $skippedSize)"
    }

    $elapsed = [Math]::Round(([datetime]::Now - $script:state.StartTime).TotalSeconds, 1)
    Write-LogEntry -Tag 'main' -Message "elapsed: ${elapsed}s"
    Write-LogEntry -Tag 'main' -Message "log file: $($script:config.LogFile)"
    Write-LogEntry -Tag 'main' -Message "review file: $($script:config.MarkdownFile)"
}

function Get-RunExitCode {
    [CmdletBinding()]
    [OutputType([int])]
    param()

    if ((Get-FindingCount -Status 'Failed') -gt 0) { return 2 }
    if ($script:state.VerificationIssue.Count -gt 0) { return 3 }
    return 0
}
#endregion

#region Confirmation
function Confirm-Removal {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if ($script:config.ScanOnly -or $script:config.Force -or $WhatIfPreference) { return $true }

    Write-LogEntry -Tag 'main' -Level Warn `
        -Message 'this permanently removes every Python installation and related file'
    Write-LogEntry -Tag 'main' `
        -Message 'installations: Microsoft Store, Python.org, Anaconda, Miniconda, Mambaforge, Miniforge'
    Write-LogEntry -Tag 'main' -Message 'environments: venv, conda, Poetry, Pipenv'
    Write-LogEntry -Tag 'main' -Message 'caches: pip, UV'
    Write-LogEntry -Tag 'main' -Message 'system: environment variables, PATH entries, registry keys, file associations'
    Write-LogEntry -Tag 'main' `
        -Message 'preserved: Poetry, PDM, Rye, Hatch, pipx and Jupyter binaries (Python reinstall required)'

    if ($script:config.SkipRestorePoint) {
        Write-LogEntry -Tag 'main' -Level Warn -Message 'no system restore point will be created'
    }
    else {
        Write-LogEntry -Tag 'main' -Message 'a system restore point will be created first'
    }

    $Host.UI.Write("`n[main] continue? [Y]es / [N]o: ")
    $answer = Read-Host

    if ($answer -notmatch '^[Yy]') {
        Write-LogEntry -Tag 'main' -Level Warn -Message 'cancelled at the confirmation prompt'
        return $false
    }
    return $true
}
#endregion

#region Main
$script:useColour = $false

try {
    Initialize-Configuration -ScanOnly:$ScanOnly -SkipRestorePoint:$SkipRestorePoint `
        -SkipProcessCheck:$SkipProcessCheck -SkipDiskCheck:$SkipDiskCheck `
        -IncludeNetworkDrives:$IncludeNetworkDrives -Force:$Force `
        -MinFreeDiskSpaceGB $MinFreeDiskSpaceGB -TimeoutSeconds $TimeoutSeconds `
        -MaxScanDepth $MaxScanDepth -LogDirectory $LogDirectory

    $script:useColour = Test-ColourSupport
    if (-not (Open-LogFile)) {
        Write-Warning 'Unable to open a log file; continuing with console output only.'
    }

    Write-LogEntry -Tag 'main' -Level Section -Message "=== PYTHON REMOVAL v$($script:config.Version) ==="

    if ($PSCmdlet.ParameterSetName -eq 'Restore') {
        $script:config.RestoreMode = $true
        $script:state.ExitCode = if (Restore-EnvironmentVariable -BackupPath $RestoreEnvironment) { 0 } else { 1 }
        exit $script:state.ExitCode
    }

    if (-not (Test-RequiredEnvironment)) {
        $script:state.ExitCode = 5
        exit 5
    }

    $null = Test-DiskSpace

    if (-not (Confirm-Removal)) {
        $script:state.ExitCode = 4
        exit 4
    }

    $phases = [ordered]@{
        'Restore point'        = { New-RestorePoint }
        'Running processes'    = { Test-RunningProcess }
        'Store packages'       = { Uninstall-StorePython }
        'Installations'        = { Uninstall-TraditionalPython }
        'Environment'          = { Remove-EnvironmentVariable }
        'Directories'          = { Remove-PythonDirectory }
        'Configuration files'  = { Remove-PythonConfigFile }
        'Shortcuts'            = { Remove-PythonShortcut }
        'Temporary files'      = { Remove-PythonTempFile }
        'Virtual environments' = { Remove-VirtualEnvironment }
        'App aliases'          = { Remove-AppExecutionAlias }
        'Python launcher'      = { Remove-PythonLauncher }
        'Registry'             = { Clear-Registry }
        'PowerShell profiles'  = { Remove-ProfileBlock }
    }

    $index = 0
    foreach ($phase in $phases.GetEnumerator()) {
        $percent = [Math]::Round(($index / $phases.Count) * 100)
        Write-Progress -Activity 'Python removal' -Status $phase.Key -PercentComplete $percent

        $findingsBefore = $script:state.Findings.Count
        $phaseTimer = [System.Diagnostics.Stopwatch]::StartNew()
        & $phase.Value
        $phaseTimer.Stop()

        [void]$script:state.PhaseTiming.Add([pscustomobject]@{
                Name     = $phase.Key
                Seconds  = [Math]::Round($phaseTimer.Elapsed.TotalSeconds, 2)
                Findings = $script:state.Findings.Count - $findingsBefore
            })
        $index++
    }
    Write-Progress -Activity 'Python removal' -Completed

    if (-not $script:config.ScanOnly -and -not $WhatIfPreference) { Test-PostRemoval }

    New-Report
    Write-Summary

    $script:state.ExitCode = Get-RunExitCode
    $mode = if ($script:config.ScanOnly) { 'scan' } else { 'cleanup' }
    Write-LogEntry -Tag 'main' -Level Success -Message "$mode complete (exit code $($script:state.ExitCode))"

    if (-not $script:config.ScanOnly) {
        Write-LogEntry -Tag 'main' -Level Warn -Message 'reboot to finish removing files that were in use'
    }

    exit $script:state.ExitCode
}
catch {
    if (Get-Command Write-LogEntry -ErrorAction Ignore) {
        Write-LogEntry -Tag 'main' -Level Error -Message "critical failure: $($_.Exception.Message)"
        Write-LogEntry -Tag 'main' -Level Error -Message $_.ScriptStackTrace
    }
    Write-Error "[main] critical failure: $($_.Exception.Message)"
    exit 1
}
finally {
    # Written unconditionally, including on a critical failure and under -WhatIf, because that is
    # exactly when a review artefact is worth having.
    if ($script:config -and $script:state) { Write-MarkdownReport }
    Close-LogFile
}
#endregion
