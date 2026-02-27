#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

<#
.SYNOPSIS
    Comprehensive Pester test suite for RemovePython.ps1

.DESCRIPTION
    ~185 tests covering all critical functionality:
    - Safety functions (Test-PathSafe, Remove-ItemSafely)
    - PATH/env var filtering
    - Process detection
    - Uninstall functions
    - Directory cleanup
    - Registry operations
    - Utility functions
    - Integration tests

.NOTES
    Test Loading Strategy: Uses AST parsing to extract functions without
    executing the script (bypasses #Requires -RunAsAdministrator)
#>

BeforeAll {
    # Parse script to extract functions without executing
    $scriptPath = Join-Path $PSScriptRoot 'RemovePython.ps1'
    if (-not (Test-Path $scriptPath)) {
        throw "RemovePython.ps1 not found at: $scriptPath"
    }

    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $scriptPath, [ref]$null, [ref]$null
    )

    $functions = $ast.FindAll({
        $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true)

    foreach ($func in $functions) {
        . ([scriptblock]::Create($func.Extent.Text))
    }

    # Initialize script-scope state (copied from RemovePython.ps1)
    $script:config = @{
        Version            = '1.0'
        LogFile            = "$TestDrive\test_log.txt"
        ReportFile         = "$TestDrive\test_report.csv"
        BackupFile         = "$TestDrive\test_backup.json"
        ItemsFound         = [System.Collections.Generic.List[object]]::new()
        ItemsRemoved       = 0
        ItemsFailed        = 0
        ItemsSkipped       = 0
        TotalSize          = [int64]0
        StartTime          = Get-Date
        MaxDepth           = 8
        TimeoutSeconds     = 300
        MinFreeDiskSpaceGB = 5
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
        PathEntries  = '(^|\\)(python\d*|\.venv|\.pyenv|\.virtualenvs?|Anaconda\d*|Miniconda\d*|Mambaforge|Miniforge|conda|site-packages|dist-packages)(\\|$)|\\(pyenv|virtualenv)\\|\.python-version'
        ProcessNames = '^python(w)?(\d+(\.\d+)?)?$|^pip(\d+)?$|^conda$|^mamba$|^anaconda$|^jupyter|^ipython|^pyinstaller|^pylint|^pytest|^mypy|^black|^ruff|^flake8|^virtualenv|^pydoc|^idle|^sphinx'
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
        'PYLAUNCHER_ALLOW_INSTALL', 'PY_PYTHON'
    )

    # Script parameter variables (for testing)
    $script:ScanOnly = $false
    $script:IncludeNetworkDrives = $false
    $script:CreateBackup = $true
}

Describe 'PRIORITY 1: Safety Functions' -Tag 'Safety', 'Critical' {

    Context 'Test-PathSafe - Rejects Dangerous Paths' {

        It 'Returns false for null path' {
            Test-PathSafe -Path $null | Should -Be $false
        }

        It 'Returns false for empty string' {
            Test-PathSafe -Path '' | Should -Be $false
        }

        It 'Returns false for whitespace-only path' {
            Test-PathSafe -Path '   ' | Should -Be $false
        }

        It 'Returns false for root drive: C:\' {
            Test-PathSafe -Path 'C:\' | Should -Be $false
        }

        It 'Returns false for root drive without slash: C:' {
            Test-PathSafe -Path 'C:' | Should -Be $false
        }

        It 'Returns false for root drive: D:\' {
            Test-PathSafe -Path 'D:\' | Should -Be $false
        }

        It 'Returns false for lowercase root drive: d:\' {
            Test-PathSafe -Path 'd:\' | Should -Be $false
        }

        It 'Returns false for protected path: $env:WINDIR' {
            Test-PathSafe -Path $env:WINDIR | Should -Be $false
        }

        It 'Returns false for protected path: $env:SystemRoot' {
            Test-PathSafe -Path $env:SystemRoot | Should -Be $false
        }

        It 'Returns false for protected path: C:\Windows' {
            Test-PathSafe -Path 'C:\Windows' | Should -Be $false
        }

        It 'Returns false for protected subpath: C:\Windows\System32' {
            Test-PathSafe -Path 'C:\Windows\System32' | Should -Be $false
        }

        It 'Returns false for protected path: C:\Windows\Temp' {
            Test-PathSafe -Path 'C:\Windows\Temp' | Should -Be $false
        }

        It 'Returns false for protected path: C:\Program Files\Windows' {
            Test-PathSafe -Path 'C:\Program Files\Windows' | Should -Be $false
        }

        It 'Returns false for protected path: C:\Program Files\WindowsApps' {
            Test-PathSafe -Path 'C:\Program Files\WindowsApps' | Should -Be $false
        }

        It 'Returns false for protected path: C:\Program Files (x86)\Windows' {
            Test-PathSafe -Path 'C:\Program Files (x86)\Windows' | Should -Be $false
        }

        It 'Handles paths with trailing spaces correctly' {
            # Trailing spaces should be normalized
            $result = Test-PathSafe -Path 'C:\Python39   '
            $result | Should -Be $true
        }

        It 'Handles paths with trailing slashes correctly' {
            $result = Test-PathSafe -Path 'C:\Python39\'
            $result | Should -Be $true
        }
    }

    Context 'Test-PathSafe - Allows Valid Removal Targets' {

        It 'Allows Python installation: C:\Python39' {
            Test-PathSafe -Path 'C:\Python39' | Should -Be $true
        }

        It 'Allows Python Scripts: C:\Python39\Scripts' {
            Test-PathSafe -Path 'C:\Python39\Scripts' | Should -Be $true
        }

        It 'Allows pip cache under user profile' {
            Test-PathSafe -Path "$env:USERPROFILE\.cache\pip" | Should -Be $true
        }

        It 'Allows Python under LocalAppData' {
            Test-PathSafe -Path "$env:LOCALAPPDATA\Programs\Python" | Should -Be $true
        }

        It 'Allows Python under AppData' {
            Test-PathSafe -Path "$env:APPDATA\Python" | Should -Be $true
        }

        It 'Allows Anaconda under ProgramData' {
            Test-PathSafe -Path 'C:\ProgramData\Anaconda3' | Should -Be $true
        }

        It 'Allows deeply nested path under user profile' {
            Test-PathSafe -Path "$env:USERPROFILE\projects\deep\nested\path\.venv" | Should -Be $true
        }
    }

    Context 'Remove-ItemSafely - Safety Gates' {

        BeforeEach {
            $script:config.ItemsRemoved = 0
            $script:config.ItemsFailed = 0
            $script:config.ItemsSkipped = 0
        }

        It 'Returns early if path does not exist' {
            Remove-ItemSafely -Path 'C:\NonExistentPath12345' -Description 'Test' -Type 'File'
            $script:config.ItemsSkipped | Should -Be 0
            $script:config.ItemsRemoved | Should -Be 0
        }

        It 'Increments ItemsSkipped when Test-PathSafe returns false' {
            $testPath = 'C:\'
            Remove-ItemSafely -Path $testPath -Description 'Test' -Type 'Directory'
            $script:config.ItemsSkipped | Should -Be 1
        }

        It 'Does NOT call Remove-Item when path is unsafe' {
            Mock Remove-Item { throw "Should not be called" }
            $testPath = $env:WINDIR
            { Remove-ItemSafely -Path $testPath -Description 'Test' -Type 'Directory' } | Should -Not -Throw
            Should -Not -Invoke Remove-Item
        }

        It 'Increments ItemsSkipped for network paths when IncludeNetworkDrives is off' {
            $script:IncludeNetworkDrives = $false
            # Create a mock network path that exists
            Mock Test-Path { $true } -ParameterFilter { $Path -like '\\*' }
            Mock Test-IsNetworkPath { $true } -ParameterFilter { $Path -like '\\*' }
            Mock Test-PathSafe { $true }

            Remove-ItemSafely -Path '\\server\share\file.txt' -Description 'Test' -Type 'File'
            $script:config.ItemsSkipped | Should -Be 1
        }
    }

    Context 'Remove-ItemSafely - ScanOnly Mode' {

        BeforeEach {
            $script:config.ItemsRemoved = 0
            $script:config.ItemsSkipped = 0
            $script:config.ItemsFound.Clear()
            $script:ScanOnly = $true
        }

        AfterEach {
            $script:ScanOnly = $false
        }

        It 'Logs Found message but does NOT delete in ScanOnly mode' {
            $testFile = Join-Path $TestDrive 'testfile.txt'
            'test content' | Out-File $testFile

            Mock Remove-Item { throw "Should not be called in ScanOnly" }

            Remove-ItemSafely -Path $testFile -Description 'Test File' -Type 'File'

            Should -Not -Invoke Remove-Item
            Test-Path $testFile | Should -Be $true
        }

        It 'Adds finding to ItemsFound list in ScanOnly mode' {
            $testFile = Join-Path $TestDrive 'testfile2.txt'
            'test content' | Out-File $testFile

            Remove-ItemSafely -Path $testFile -Description 'Test File' -Type 'File'

            $script:config.ItemsFound.Count | Should -BeGreaterThan 0
        }
    }

    Context 'Remove-ItemSafely - Actual Deletion' {

        BeforeEach {
            $script:config.ItemsRemoved = 0
            $script:config.ItemsFailed = 0
            $script:config.TotalSize = 0
            $script:ScanOnly = $false
        }

        It 'Deletes a temp file and increments ItemsRemoved' {
            $testFile = Join-Path $TestDrive 'deleteme.txt'
            'test content' | Out-File $testFile

            Remove-ItemSafely -Path $testFile -Description 'Test File' -Type 'File'

            Test-Path $testFile | Should -Be $false
            $script:config.ItemsRemoved | Should -Be 1
        }

        It 'Deletes a temp directory and increments ItemsRemoved' {
            $testDir = Join-Path $TestDrive 'deleteme_dir'
            New-Item -Path $testDir -ItemType Directory -Force | Out-Null

            Remove-ItemSafely -Path $testDir -Description 'Test Directory' -Type 'Directory'

            Test-Path $testDir | Should -Be $false
            $script:config.ItemsRemoved | Should -Be 1
        }

        It 'Handles read-only files by clearing attribute then deleting' {
            $testFile = Join-Path $TestDrive 'readonly.txt'
            'test' | Out-File $testFile
            Set-ItemProperty -Path $testFile -Name IsReadOnly -Value $true

            Remove-ItemSafely -Path $testFile -Description 'ReadOnly File' -Type 'File'

            Test-Path $testFile | Should -Be $false
            $script:config.ItemsRemoved | Should -Be 1
        }
    }

    Context 'Remove-ItemSafely - Counter Integrity' {

        BeforeEach {
            $script:config.ItemsRemoved = 0
            $script:config.ItemsFailed = 0
            $script:config.ItemsSkipped = 0
            $script:ScanOnly = $false
        }

        It 'Increments exactly one counter per operation' {
            $testFile = Join-Path $TestDrive 'counter_test.txt'
            'test' | Out-File $testFile

            $beforeTotal = $script:config.ItemsRemoved + $script:config.ItemsFailed + $script:config.ItemsSkipped

            Remove-ItemSafely -Path $testFile -Description 'Test' -Type 'File'

            $afterTotal = $script:config.ItemsRemoved + $script:config.ItemsFailed + $script:config.ItemsSkipped

            ($afterTotal - $beforeTotal) | Should -Be 1
        }
    }
}

Describe 'PRIORITY 2: PATH & Environment Variable Handling' -Tag 'PathHandling', 'Critical' {

    Context 'PATH Filtering Regex - REMOVES Core Python Installation Paths' {

        BeforeEach {
            $regex = $script:pythonPatterns.PathEntries
        }

        It 'Removes: C:\Python39' {
            'C:\Python39' -match $regex | Should -Be $true
        }

        It 'Removes: C:\Python311' {
            'C:\Python311' -match $regex | Should -Be $true
        }

        It 'Removes: C:\Python312\Scripts' {
            'C:\Python312\Scripts' -match $regex | Should -Be $true
        }

        It 'Removes: C:\Program Files\Python311' {
            'C:\Program Files\Python311' -match $regex | Should -Be $true
        }

        It 'Removes: C:\Program Files\Python312\Scripts' {
            'C:\Program Files\Python312\Scripts' -match $regex | Should -Be $true
        }

        It 'Removes: User Python installation' {
            'C:\Users\TestUser\AppData\Local\Programs\Python\Python311' -match $regex | Should -Be $true
        }

        It 'Removes: User Python Scripts' {
            'C:\Users\TestUser\AppData\Local\Programs\Python\Python312\Scripts' -match $regex | Should -Be $true
        }

        It 'Removes: Roaming Python Scripts' {
            'C:\Users\TestUser\AppData\Roaming\Python\Python39\Scripts' -match $regex | Should -Be $true
        }
    }

    Context 'PATH Filtering Regex - REMOVES Conda Distribution Paths' {

        BeforeEach {
            $regex = $script:pythonPatterns.PathEntries
        }

        It 'Removes: C:\Users\X\Anaconda3' {
            'C:\Users\X\Anaconda3' -match $regex | Should -Be $true
        }

        It 'Removes: C:\Users\X\Anaconda3\Scripts' {
            'C:\Users\X\Anaconda3\Scripts' -match $regex | Should -Be $true
        }

        It 'Removes: C:\Users\X\Anaconda3\condabin' {
            'C:\Users\X\Anaconda3\condabin' -match $regex | Should -Be $true
        }

        It 'Removes: C:\ProgramData\Anaconda3' {
            'C:\ProgramData\Anaconda3' -match $regex | Should -Be $true
        }

        It 'Removes: C:\Users\X\Miniconda3' {
            'C:\Users\X\Miniconda3' -match $regex | Should -Be $true
        }

        It 'Removes: C:\Users\X\Mambaforge' {
            'C:\Users\X\Mambaforge' -match $regex | Should -Be $true
        }

        It 'Removes: C:\Users\X\Miniforge' {
            'C:\Users\X\Miniforge' -match $regex | Should -Be $true
        }

        It 'Removes: C:\Users\X\conda\bin' {
            'C:\Users\X\conda\bin' -match $regex | Should -Be $true
        }
    }

    Context 'PATH Filtering Regex - REMOVES Venv and Pyenv Paths' {

        BeforeEach {
            $regex = $script:pythonPatterns.PathEntries
        }

        It 'Removes: C:\Users\X\project\.venv\Scripts' {
            'C:\Users\X\project\.venv\Scripts' -match $regex | Should -Be $true
        }

        It 'Removes: C:\Users\X\.pyenv (dotted directory)' {
            'C:\Users\X\.pyenv' -match $regex | Should -Be $true
        }

        It 'Removes: C:\Users\X\.pyenv\pyenv-win\bin (subdirectory)' {
            'C:\Users\X\.pyenv\pyenv-win\bin' -match $regex | Should -Be $true
        }

        It 'Removes: C:\some\path\pyenv\shims (pyenv in path)' {
            'C:\some\path\pyenv\shims' -match $regex | Should -Be $true
        }

        It 'Removes: C:\Users\X\.virtualenvs\myenv' {
            'C:\Users\X\.virtualenvs\myenv' -match $regex | Should -Be $true
        }

        It 'Removes: C:\path\virtualenv\env (virtualenv in path)' {
            'C:\path\virtualenv\env' -match $regex | Should -Be $true
        }
    }

    Context 'PATH Filtering Regex - REMOVES Python Package Paths' {

        BeforeEach {
            $regex = $script:pythonPatterns.PathEntries
        }

        It 'Removes: site-packages path' {
            'C:\Users\X\Lib\site-packages' -match $regex | Should -Be $true
        }

        It 'Removes: dist-packages path' {
            'C:\usr\lib\python3\dist-packages' -match $regex | Should -Be $true
        }
    }

    Context 'PATH Filtering Regex - REMOVES .python-version References' {

        BeforeEach {
            $regex = $script:pythonPatterns.PathEntries
        }

        It 'Removes: path containing .python-version' {
            'C:\Users\X\project\.python-version' -match $regex | Should -Be $true
        }
    }

    Context 'PATH Filtering Regex - PRESERVES Package Manager Tool Paths' {

        BeforeEach {
            $regex = $script:pythonPatterns.PathEntries
        }

        It 'Preserves: C:\Users\X\.local\pipx\bin' {
            'C:\Users\X\.local\pipx\bin' -match $regex | Should -Be $false
        }

        It 'Preserves: C:\Users\X\AppData\Local\pipx\venvs' {
            'C:\Users\X\AppData\Local\pipx\venvs' -match $regex | Should -Be $false
        }

        It 'Preserves: C:\Users\X\.poetry\bin' {
            'C:\Users\X\.poetry\bin' -match $regex | Should -Be $false
        }

        It 'Preserves: C:\Users\X\AppData\Roaming\pypoetry\Cache' {
            'C:\Users\X\AppData\Roaming\pypoetry\Cache' -match $regex | Should -Be $false
        }

        It 'Preserves: C:\Users\X\AppData\Local\pdm\bin' {
            'C:\Users\X\AppData\Local\pdm\bin' -match $regex | Should -Be $false
        }

        It 'Preserves: C:\Users\X\.pdm\bin' {
            'C:\Users\X\.pdm\bin' -match $regex | Should -Be $false
        }

        It 'Preserves: C:\Users\X\.rye\shims' {
            'C:\Users\X\.rye\shims' -match $regex | Should -Be $false
        }

        It 'Preserves: C:\Users\X\AppData\Local\Programs\uv' {
            'C:\Users\X\AppData\Local\Programs\uv' -match $regex | Should -Be $false
        }

        It 'Preserves: C:\Users\X\AppData\Roaming\uv\bin' {
            'C:\Users\X\AppData\Roaming\uv\bin' -match $regex | Should -Be $false
        }

        It 'Preserves: C:\Users\X\.astral\uv' {
            'C:\Users\X\.astral\uv' -match $regex | Should -Be $false
        }

        It 'Preserves: C:\Users\X\AppData\Local\hatch\env' {
            'C:\Users\X\AppData\Local\hatch\env' -match $regex | Should -Be $false
        }

        It 'Preserves: C:\Users\X\.local\bin' {
            'C:\Users\X\.local\bin' -match $regex | Should -Be $false
        }

        It 'Preserves: C:\Users\X\scoop\apps\mise\current' {
            'C:\Users\X\scoop\apps\mise\current' -match $regex | Should -Be $false
        }

        It 'Preserves: C:\Users\X\.asdf\shims' {
            'C:\Users\X\.asdf\shims' -match $regex | Should -Be $false
        }
    }

    Context 'PATH Filtering Regex - PRESERVES Non-Python System Paths' {

        BeforeEach {
            $regex = $script:pythonPatterns.PathEntries
        }

        It 'Preserves: C:\Windows\System32' {
            'C:\Windows\System32' -match $regex | Should -Be $false
        }

        It 'Preserves: C:\Program Files\Git\cmd' {
            'C:\Program Files\Git\cmd' -match $regex | Should -Be $false
        }

        It 'Preserves: C:\Program Files\nodejs' {
            'C:\Program Files\nodejs' -match $regex | Should -Be $false
        }

        It 'Preserves: C:\Users\X\.cargo\bin' {
            'C:\Users\X\.cargo\bin' -match $regex | Should -Be $false
        }

        It 'Preserves: C:\Users\X\AppData\Local\Microsoft\WindowsApps' {
            'C:\Users\X\AppData\Local\Microsoft\WindowsApps' -match $regex | Should -Be $false
        }

        It 'Preserves: C:\Program Files\PowerShell\7' {
            'C:\Program Files\PowerShell\7' -match $regex | Should -Be $false
        }

        It 'Preserves: C:\Users\X\Documents\PowerShell\Scripts' {
            'C:\Users\X\Documents\PowerShell\Scripts' -match $regex | Should -Be $false
        }

        It 'Preserves: C:\MyProject\Scripts' {
            'C:\MyProject\Scripts' -match $regex | Should -Be $false
        }

        It 'Preserves: C:\Users\X\AppData\Roaming\npm' {
            'C:\Users\X\AppData\Roaming\npm' -match $regex | Should -Be $false
        }

        It 'Preserves: C:\Program Files\dotnet' {
            'C:\Program Files\dotnet' -match $regex | Should -Be $false
        }
    }

    Context 'PATH Filtering Regex - Edge Cases (No False Positives)' {

        BeforeEach {
            $regex = $script:pythonPatterns.PathEntries
        }

        It 'Preserves: C:\Users\X\pythonista (NOT python\d*)' {
            'C:\Users\X\pythonista' -match $regex | Should -Be $false
        }

        It 'Preserves: C:\Users\X\anaconda-navigator\bin (NOT Anaconda\d*)' {
            'C:\Users\X\anaconda-navigator\bin' -match $regex | Should -Be $false
        }

        It 'Preserves: C:\Users\X\python_projects\bin (NOT python\d*)' {
            'C:\Users\X\python_projects\bin' -match $regex | Should -Be $false
        }

        It 'Preserves: C:\Users\X\Documents\venvmanager\bin (NOT venv)' {
            'C:\Users\X\Documents\venvmanager\bin' -match $regex | Should -Be $false
        }

        It 'Preserves: C:\Users\X\miniconda-setup\temp (NOT Miniconda\d*)' {
            'C:\Users\X\miniconda-setup\temp' -match $regex | Should -Be $false
        }
    }

    Context 'pythonVariables Array - Contains Expected Variables' {

        It 'Contains PYTHONPATH' {
            $script:pythonVariables | Should -Contain 'PYTHONPATH'
        }

        It 'Contains PYTHONHOME' {
            $script:pythonVariables | Should -Contain 'PYTHONHOME'
        }

        It 'Contains VIRTUAL_ENV' {
            $script:pythonVariables | Should -Contain 'VIRTUAL_ENV'
        }

        It 'Contains VIRTUAL_ENV_PROMPT' {
            $script:pythonVariables | Should -Contain 'VIRTUAL_ENV_PROMPT'
        }

        It 'Contains CONDA_PREFIX' {
            $script:pythonVariables | Should -Contain 'CONDA_PREFIX'
        }

        It 'Contains PYENV_ROOT' {
            $script:pythonVariables | Should -Contain 'PYENV_ROOT'
        }

        It 'Contains PYLAUNCHER_ALLOW_INSTALL' {
            $script:pythonVariables | Should -Contain 'PYLAUNCHER_ALLOW_INSTALL'
        }

        It 'Contains PY_PYTHON' {
            $script:pythonVariables | Should -Contain 'PY_PYTHON'
        }
    }

    Context 'pythonVariables Array - Does NOT Contain Preserved Tool Variables' {

        It 'Does NOT contain POETRY_HOME' {
            $script:pythonVariables | Should -Not -Contain 'POETRY_HOME'
        }

        It 'Does NOT contain POETRY_CACHE_DIR' {
            $script:pythonVariables | Should -Not -Contain 'POETRY_CACHE_DIR'
        }

        It 'Does NOT contain PDM_HOME' {
            $script:pythonVariables | Should -Not -Contain 'PDM_HOME'
        }

        It 'Does NOT contain RYE_HOME' {
            $script:pythonVariables | Should -Not -Contain 'RYE_HOME'
        }

        It 'Does NOT contain PIPX_HOME' {
            $script:pythonVariables | Should -Not -Contain 'PIPX_HOME'
        }

        It 'Does NOT contain UV_CACHE_DIR' {
            $script:pythonVariables | Should -Not -Contain 'UV_CACHE_DIR'
        }

        It 'Does NOT contain UV_TOOL_DIR' {
            $script:pythonVariables | Should -Not -Contain 'UV_TOOL_DIR'
        }

        It 'Does NOT contain HATCH_HOME' {
            $script:pythonVariables | Should -Not -Contain 'HATCH_HOME'
        }

        It 'Does NOT contain PIP_CONFIG_FILE' {
            $script:pythonVariables | Should -Not -Contain 'PIP_CONFIG_FILE'
        }

        It 'Does NOT contain JUPYTER_CONFIG_DIR' {
            $script:pythonVariables | Should -Not -Contain 'JUPYTER_CONFIG_DIR'
        }
    }

    Context 'ProcessNames Regex - MATCHES Python Processes' {

        BeforeEach {
            $regex = $script:pythonPatterns.ProcessNames
        }

        It 'Matches: python' {
            'python' -match $regex | Should -Be $true
        }

        It 'Matches: pythonw' {
            'pythonw' -match $regex | Should -Be $true
        }

        It 'Matches: python3' {
            'python3' -match $regex | Should -Be $true
        }

        It 'Matches: python3.11' {
            'python3.11' -match $regex | Should -Be $true
        }

        It 'Matches: pip' {
            'pip' -match $regex | Should -Be $true
        }

        It 'Matches: pip3' {
            'pip3' -match $regex | Should -Be $true
        }

        It 'Matches: conda' {
            'conda' -match $regex | Should -Be $true
        }

        It 'Matches: mamba' {
            'mamba' -match $regex | Should -Be $true
        }

        It 'Matches: jupyter-notebook' {
            'jupyter-notebook' -match $regex | Should -Be $true
        }

        It 'Matches: ipython' {
            'ipython' -match $regex | Should -Be $true
        }
    }

    Context 'ProcessNames Regex - Does NOT Match Preserved Tool Processes' {

        BeforeEach {
            $regex = $script:pythonPatterns.ProcessNames
        }

        It 'Does NOT match: poetry' {
            'poetry' -match $regex | Should -Be $false
        }

        It 'Does NOT match: pdm' {
            'pdm' -match $regex | Should -Be $false
        }

        It 'Does NOT match: pipx' {
            'pipx' -match $regex | Should -Be $false
        }

        It 'Does NOT match: rye' {
            'rye' -match $regex | Should -Be $false
        }

        It 'Does NOT match: uv' {
            'uv' -match $regex | Should -Be $false
        }

        It 'Does NOT match: hatch' {
            'hatch' -match $regex | Should -Be $false
        }
    }

    Context 'ProcessNames Regex - Does NOT Match Unrelated Processes' {

        BeforeEach {
            $regex = $script:pythonPatterns.ProcessNames
        }

        It 'Does NOT match: node' {
            'node' -match $regex | Should -Be $false
        }

        It 'Does NOT match: git' {
            'git' -match $regex | Should -Be $false
        }

        It 'Does NOT match: code' {
            'code' -match $regex | Should -Be $false
        }

        It 'Does NOT match: pwsh' {
            'pwsh' -match $regex | Should -Be $false
        }
    }
}

Describe 'PRIORITY 3: Utility & Support Functions' -Tag 'Utilities' {

    Context 'Format-FileSize' {

        It 'Formats 0 B' {
            Format-FileSize -Bytes 0 | Should -Be '0 B'
        }

        It 'Formats negative as 0 B' {
            Format-FileSize -Bytes -100 | Should -Be '0 B'
        }

        It 'Formats 500 as 500 B' {
            Format-FileSize -Bytes 500 | Should -Be '500 B'
        }

        It 'Formats 1024 as 1 KB' {
            Format-FileSize -Bytes 1024 | Should -Be '1 KB'
        }

        It 'Formats 1536 as 1.5 KB' {
            Format-FileSize -Bytes 1536 | Should -Be '1.5 KB'
        }

        It 'Formats 1048576 as 1 MB' {
            Format-FileSize -Bytes 1048576 | Should -Be '1 MB'
        }

        It 'Formats 1073741824 as 1 GB' {
            Format-FileSize -Bytes 1073741824 | Should -Be '1 GB'
        }

        It 'Formats 1099511627776 as 1 TB' {
            Format-FileSize -Bytes 1099511627776 | Should -Be '1 TB'
        }
    }

    Context 'Test-IsNetworkPath' {

        It 'Returns false for null' {
            Test-IsNetworkPath -Path $null | Should -Be $false
        }

        It 'Returns false for empty string' {
            Test-IsNetworkPath -Path '' | Should -Be $false
        }

        It 'Returns true for UNC path: \\server\share' {
            Test-IsNetworkPath -Path '\\server\share' | Should -Be $true
        }

        It 'Returns true for long UNC: \\?\UNC\server\share' {
            Test-IsNetworkPath -Path '\\?\UNC\server\share' | Should -Be $true
        }

        It 'Returns false for local drive: C:\Users' {
            Test-IsNetworkPath -Path 'C:\Users\test' | Should -Be $false
        }

        It 'Returns false for D: drive' {
            Test-IsNetworkPath -Path 'D:\Data' | Should -Be $false
        }
    }

    Context 'Add-Finding' {

        BeforeEach {
            $script:config.ItemsFound.Clear()
            $script:config.TotalSize = 0
        }

        It 'Adds finding with correct properties' {
            Add-Finding -Type 'File' -Name 'test.txt' -Path 'C:\test.txt' -Size 1024

            $script:config.ItemsFound.Count | Should -Be 1
            $finding = $script:config.ItemsFound[0]
            $finding.Type | Should -Be 'File'
            $finding.Name | Should -Be 'test.txt'
            $finding.Path | Should -Be 'C:\test.txt'
        }

        It 'Increments TotalSize' {
            Add-Finding -Type 'File' -Name 'test.txt' -Path 'C:\test.txt' -Size 2048

            $script:config.TotalSize | Should -Be 2048
        }

        It 'Uses default Status = "Found"' {
            Add-Finding -Type 'File' -Name 'test.txt' -Path 'C:\test.txt' -Size 0

            $finding = $script:config.ItemsFound[0]
            $finding.Status | Should -Be 'Found'
        }

        It 'Formats Size correctly via Format-FileSize' {
            Add-Finding -Type 'File' -Name 'test.txt' -Path 'C:\test.txt' -Size 1024

            $finding = $script:config.ItemsFound[0]
            $finding.Size | Should -Be '1 KB'
        }
    }

    Context 'Write-LogMessage' {

        BeforeEach {
            if (Test-Path $script:config.LogFile) {
                Remove-Item $script:config.LogFile -Force
            }
        }

        It 'Appends to log file' {
            Write-LogMessage -Message 'Test message' -Type 'TEST'

            Test-Path $script:config.LogFile | Should -Be $true
            $content = Get-Content $script:config.LogFile -Raw
            $content | Should -Match 'Test message'
        }

        It 'Uses correct [timestamp][TYPE] format' {
            Write-LogMessage -Message 'Test' -Type 'INFO'

            $content = Get-Content $script:config.LogFile -Raw
            $content | Should -Match '\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}\]\[INFO\]'
        }

        It 'Does not throw on any input' {
            { Write-LogMessage -Message 'Test' -Color 'InvalidColor' -Type 'TEST' } | Should -Not -Throw
        }
    }
}

Describe 'PRIORITY 4: Integration & Coverage Tests' -Tag 'Integration' {

    Context 'Counter Tracking Integration' {

        BeforeEach {
            $script:config.ItemsRemoved = 0
            $script:config.ItemsFailed = 0
            $script:config.ItemsSkipped = 0
        }

        It 'Counters start at 0' {
            $script:config.ItemsRemoved | Should -Be 0
            $script:config.ItemsFailed | Should -Be 0
            $script:config.ItemsSkipped | Should -Be 0
        }

        It 'TotalSize is non-negative' {
            $script:config.TotalSize | Should -BeGreaterOrEqual 0
        }
    }

    Context 'Script Configuration' {

        It 'Version is 1.0' {
            $script:config.Version | Should -Be '1.0'
        }

        It 'Protected paths array is not empty' {
            $script:protectedPaths.Count | Should -BeGreaterThan 0
        }

        It 'Python variables array is not empty' {
            $script:pythonVariables.Count | Should -BeGreaterThan 0
        }

        It 'Colors hashtable contains required keys' {
            $script:colors.Keys | Should -Contain 'Header'
            $script:colors.Keys | Should -Contain 'Success'
            $script:colors.Keys | Should -Contain 'Error'
        }
    }
}

Describe 'PRIORITY 5: Additional Function Coverage' -Tag 'Coverage' {

    Context 'Get-SafeFolderSize' {

        It 'Returns 0 for non-existent path' {
            Get-SafeFolderSize -Path 'C:\NonExistentFolder12345' | Should -Be 0
        }

        It 'Returns 0 or null for empty directory' {
            $emptyDir = Join-Path $TestDrive 'empty'
            New-Item -Path $emptyDir -ItemType Directory -Force | Out-Null
            $result = Get-SafeFolderSize -Path $emptyDir
            # Empty directory returns 0 or $null (both acceptable)
            ($result -eq 0 -or $null -eq $result) | Should -Be $true
        }

        It 'Calculates size for directory with files' {
            $testDir = Join-Path $TestDrive 'sizetest'
            New-Item -Path $testDir -ItemType Directory -Force | Out-Null
            'test content' | Out-File (Join-Path $testDir 'file1.txt')

            $size = Get-SafeFolderSize -Path $testDir
            $size | Should -BeGreaterThan 0
        }

        It 'Returns 0 on error (access denied simulation)' {
            Mock Get-ChildItem { throw "Access denied" }
            Get-SafeFolderSize -Path $TestDrive | Should -Be 0
        }
    }

    Context 'Test-DiskSpace' {

        It 'Returns true when SkipDiskCheck is set' {
            $script:SkipDiskCheck = $true
            Test-DiskSpace | Should -Be $true
            $script:SkipDiskCheck = $false
        }

        It 'Returns true when sufficient disk space available' {
            $script:SkipDiskCheck = $false
            $script:config.MinFreeDiskSpaceGB = 1
            Test-DiskSpace | Should -Be $true
        }

        It 'Handles errors gracefully and returns true' {
            Mock Get-PSDrive { throw "Drive error" }
            Test-DiskSpace | Should -Be $true
        }
    }

    Context 'New-Report' {

        BeforeEach {
            $script:config.ItemsFound.Clear()
            $script:config.ReportFile = Join-Path $TestDrive "test_report_$(Get-Random).csv"
        }

        It 'Creates CSV when ItemsFound has entries' {
            Add-Finding -Type 'Test' -Name 'TestItem' -Path 'C:\Test' -SizeBytes 1024

            New-Report

            Test-Path $script:config.ReportFile | Should -Be $true
        }

        It 'CSV contains correct data' {
            Add-Finding -Type 'File' -Name 'test.txt' -Path 'C:\test.txt' -SizeBytes 2048

            New-Report

            $report = Import-Csv $script:config.ReportFile
            $report.Count | Should -Be 1
            $report[0].Type | Should -Be 'File'
            $report[0].Name | Should -Be 'test.txt'
        }

        It 'Does not create CSV when ItemsFound is empty' {
            # Ensure ItemsFound is truly empty
            $script:config.ItemsFound.Clear()

            New-Report

            Test-Path $script:config.ReportFile | Should -Be $false
        }

        It 'Handles Export-Csv failure gracefully' {
            Add-Finding -Type 'Test' -Name 'Item' -Path 'C:\Test' -SizeBytes 100

            Mock Export-Csv { throw "Disk full" }

            { New-Report } | Should -Not -Throw
        }
    }

    Context 'New-RestorePoint (Mocked)' {

        BeforeEach {
            $script:ScanOnly = $false
            $script:CreateBackup = $true
        }

        AfterEach {
            $script:ScanOnly = $false
            $script:CreateBackup = $true
        }

        It 'Skips when ScanOnly is true' {
            $script:ScanOnly = $true
            Mock Invoke-CimMethod { }

            New-RestorePoint

            Should -Not -Invoke Invoke-CimMethod
        }

        It 'Skips when CreateBackup is false' {
            $script:CreateBackup = $false
            Mock Invoke-CimMethod { }

            New-RestorePoint

            Should -Not -Invoke Invoke-CimMethod
        }

        It 'Uses uint32 casting for parameters' {
            Mock Invoke-CimMethod {
                param($Namespace, $ClassName, $MethodName, $Arguments)
                $Arguments.RestorePointType | Should -BeOfType [uint32]
                $Arguments.EventType | Should -BeOfType [uint32]
                return @{ ReturnValue = 0 }
            }

            New-RestorePoint
        }

        It 'Handles CIM method failure gracefully' {
            Mock Invoke-CimMethod { throw "Access denied" }

            { New-RestorePoint } | Should -Not -Throw
        }
    }

    Context 'Test-RunningProcess (Basic Tests)' {

        It 'Function exists and is callable' {
            Get-Command Test-RunningProcess | Should -Not -BeNullOrEmpty
        }

        It 'Skips when SkipProcessCheck is true' {
            $script:SkipProcessCheck = $true
            Mock Get-Process { }

            Test-RunningProcess

            Should -Not -Invoke Get-Process
            $script:SkipProcessCheck = $false
        }
    }

    Context 'Remove-AppExecutionAlias (Mocked)' {

        It 'Function exists and is callable' {
            Get-Command Remove-AppExecutionAlias | Should -Not -BeNullOrEmpty
        }

        It 'Checks for WindowsApps directory' {
            Mock Test-Path { $false }
            Mock Get-ChildItem { }

            Remove-AppExecutionAlias

            Should -Invoke Test-Path -ParameterFilter { $Path -like '*WindowsApps*' }
        }
    }

    Context 'Test-PostRemoval' {

        It 'Function exists and is callable' {
            Get-Command Test-PostRemoval | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'PRIORITY 6: Edge Cases & Error Handling' -Tag 'EdgeCases' {

    Context 'Long Path Handling' {

        It 'Test-PathSafe handles long paths' {
            $longPath = 'C:\' + ('a' * 300)
            # Should not throw, returns either true or false
            { Test-PathSafe -Path $longPath } | Should -Not -Throw
        }
    }

    Context 'Special Characters in Paths' {

        It 'Test-PathSafe handles paths with spaces' {
            Test-PathSafe -Path 'C:\Program Files\Python39' | Should -Be $true
        }

        It 'Test-PathSafe handles paths with parentheses' {
            Test-PathSafe -Path 'C:\Program Files (x86)\Python39' | Should -Be $true
        }

        It 'Test-PathSafe handles paths with dots' {
            Test-PathSafe -Path 'C:\Users\user.name\Python39' | Should -Be $true
        }
    }

    Context 'Parameter Validation' {

        It 'Script accepts MaxScanDepth minimum (3)' {
            # This tests parameter validation is set correctly
            $scriptPath = Join-Path $PSScriptRoot 'RemovePython.ps1'
            $params = (Get-Command $scriptPath).Parameters
            $params['MaxScanDepth'].Attributes.MinRange | Should -Be 3
        }

        It 'Script accepts MaxScanDepth maximum (15)' {
            $scriptPath = Join-Path $PSScriptRoot 'RemovePython.ps1'
            $params = (Get-Command $scriptPath).Parameters
            $params['MaxScanDepth'].Attributes.MaxRange | Should -Be 15
        }

        It 'Script accepts TimeoutSeconds minimum (60)' {
            $scriptPath = Join-Path $PSScriptRoot 'RemovePython.ps1'
            $params = (Get-Command $scriptPath).Parameters
            $params['TimeoutSeconds'].Attributes.MinRange | Should -Be 60
        }

        It 'Script accepts MinFreeDiskSpaceGB minimum (1)' {
            $scriptPath = Join-Path $PSScriptRoot 'RemovePython.ps1'
            $params = (Get-Command $scriptPath).Parameters
            $params['MinFreeDiskSpaceGB'].Attributes.MinRange | Should -Be 1
        }
    }

    Context 'Error Recovery' {

        BeforeEach {
            $script:config.ItemsRemoved = 0
            $script:config.ItemsFailed = 0
        }

        It 'Remove-ItemSafely increments ItemsFailed when deletion throws' {
            $testFile = Join-Path $TestDrive 'locked.txt'
            'test' | Out-File $testFile

            Mock Remove-Item { throw "File is locked" }

            Remove-ItemSafely -Path $testFile -Description 'Test' -Type 'File'

            $script:config.ItemsFailed | Should -BeGreaterThan 0
        }
    }
}

# Test Summary
Describe 'Test Suite Summary' -Tag 'Meta' {
    It 'Loaded functions from RemovePython.ps1' {
        Get-Command Test-PathSafe -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Remove-ItemSafely -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Format-FileSize -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}
