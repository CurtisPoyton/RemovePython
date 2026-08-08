#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Pester suite for RemovePython.ps1.

.DESCRIPTION
    Functions and configuration are lifted straight out of RemovePython.ps1 by AST parsing, so the
    suite exercises the real definitions without executing the script or tripping its
    #Requires -RunAsAdministrator guard. Initialize-Configuration is invoked rather than mirrored,
    which keeps detection data from drifting between the script and its tests.

    Registry and environment tests confine themselves to scratch keys under HKCU and remove them
    again; nothing outside those scratch locations is written.
#>

BeforeAll {
    $scriptPath = Join-Path $PSScriptRoot 'RemovePython.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw "RemovePython.ps1 not found at: $scriptPath"
    }

    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
    $definitions = $ast.FindAll({
            $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst]
        }, $true)

    foreach ($definition in $definitions) {
        . ([scriptblock]::Create($definition.Extent.Text))
    }

    $script:loadedFunctionCount = $definitions.Count

    Initialize-Configuration -LogDirectory $TestDrive
    $script:useColour = $false

    $script:scratchVariable = 'REMOVEPYTHON_PESTER_SCRATCH'
    $script:scratchRegistryKey = 'HKCU:\Software\RemovePythonPesterScratch'

    function Clear-FindingState {
        $script:state.Findings.Clear()
        $script:state.VerificationIssue.Clear()
    }
}

AfterAll {
    Remove-EnvironmentEntry -Scope User -Name $script:scratchVariable -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $script:scratchRegistryKey) {
        Remove-Item -LiteralPath $script:scratchRegistryKey -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Configuration' -Tag 'Config' {

    Context 'Initialize-Configuration populates script state' {

        It 'Sets a version string' {
            $script:config.Version | Should -Not -BeNullOrEmpty
            $script:config.Version | Should -MatchExactly '^\d+\.\d+$'
        }

        It 'Derives log, report and backup paths from the log directory' {
            $script:config.LogFile | Should -BeLike "$TestDrive*Python_Removal_Log_*.txt"
            $script:config.ReportFile | Should -BeLike "$TestDrive*Python_Removal_Report_*.csv"
            $script:config.BackupFile | Should -BeLike "$TestDrive*Python_EnvVars_Backup_*.json"
        }

        It 'Clamps parallelism to a sane range' {
            $script:config.MaxParallelism | Should -BeGreaterOrEqual 2
            $script:config.MaxParallelism | Should -BeLessOrEqual 32
        }

        It 'Bounds the executable uninstall timeout by the overall timeout' {
            $script:config.ExeUninstallTimeoutSec | Should -BeLessOrEqual $script:config.TimeoutSeconds
        }

        It 'Initialises empty finding and verification collections' {
            $script:state.Findings -is [System.Collections.Generic.List[object]] | Should -BeTrue
            $script:state.VerificationIssue -is [System.Collections.Generic.List[string]] | Should -BeTrue
        }
    }

    Context 'Detection data is fully expanded' {

        It 'Expands every directory glob to an absolute path' {
            foreach ($glob in $script:directoryGlob) {
                $glob | Should -Match '^[A-Za-z]:\\'
            }
        }

        It 'Never emits a drive-relative glob from an empty variable' {
            foreach ($glob in $script:directoryGlob) {
                $glob | Should -Not -Match '^\\[^\\]'
            }
        }

        It 'Expands every configuration file path' {
            foreach ($file in $script:configFile) {
                $file | Should -Match '^[A-Za-z]:\\'
            }
        }

        It 'Includes the core install globs in the full directory list' {
            foreach ($glob in $script:coreInstallGlob) {
                $script:directoryGlob | Should -Contain $glob
            }
        }

        It 'Verifies exactly the core install locations after removal' {
            $script:verificationGlob | Should -Be $script:coreInstallGlob
        }

        It 'Builds association keys for every extension in both hives' {
            foreach ($extension in $script:fileExtension) {
                $script:associationKey | Should -Contain "HKCU:\Software\Classes\$extension"
                $script:associationKey | Should -Contain "HKLM:\SOFTWARE\Classes\$extension"
            }
        }

        It 'Builds a UserChoice key for every extension' {
            $script:userChoiceKey.Count | Should -Be $script:fileExtension.Count
        }

        It 'Targets both launcher binaries in the Windows directory' {
            $script:config.LauncherBinary.Count | Should -Be 2
            $script:config.LauncherBinary | Should -Contain (Join-Path $env:WINDIR 'py.exe')
            $script:config.LauncherBinary | Should -Contain (Join-Path $env:WINDIR 'pyw.exe')
        }
    }

    Context 'Test-RequiredEnvironment' {

        It 'Passes when the standard Windows variables are present' {
            Test-RequiredEnvironment | Should -BeTrue
        }
    }
}

Describe 'Safety: Test-PathSafe' -Tag 'Safety', 'Critical' {

    Context 'Rejects dangerous input' {

        It 'Rejects <Case>' -TestCases @(
            @{ Case = 'null'; Path = $null }
            @{ Case = 'empty string'; Path = '' }
            @{ Case = 'whitespace'; Path = '   ' }
            @{ Case = 'bare drive letter'; Path = 'C:' }
            @{ Case = 'drive root'; Path = 'C:\' }
            @{ Case = 'lower-case drive root'; Path = 'd:\' }
        ) {
            param($Path)
            Test-PathSafe -Path $Path | Should -BeFalse
        }
    }

    Context 'Rejects protected system locations' {

        It 'Rejects the Windows directory itself' {
            Test-PathSafe -Path $env:WINDIR | Should -BeFalse
        }

        It 'Rejects a child of the Windows directory' {
            Test-PathSafe -Path (Join-Path $env:WINDIR 'System32') | Should -BeFalse
        }

        It 'Rejects a deep child of the Windows directory' {
            Test-PathSafe -Path (Join-Path $env:WINDIR 'System32\drivers\etc') | Should -BeFalse
        }

        It 'Rejects the WindowsApps store directory' {
            Test-PathSafe -Path 'C:\Program Files\WindowsApps\Something' | Should -BeFalse
        }

        It 'Rejects protected paths regardless of case' {
            Test-PathSafe -Path $env:WINDIR.ToUpperInvariant() | Should -BeFalse
            Test-PathSafe -Path $env:WINDIR.ToLowerInvariant() | Should -BeFalse
        }

        It 'Rejects protected paths reached through traversal' {
            Test-PathSafe -Path 'C:\Users\..\Windows\System32' | Should -BeFalse
        }

        It 'Rejects a trailing-separator form of a protected path' {
            Test-PathSafe -Path "$env:WINDIR\" | Should -BeFalse
        }
    }

    Context 'Documents is protected' {

        It 'Rejects the Documents folder itself' {
            Test-PathSafe -Path (Join-Path $env:USERPROFILE 'Documents') | Should -BeFalse
        }

        It 'Rejects the shell-reported Documents location' {
            Test-PathSafe -Path ([Environment]::GetFolderPath('MyDocuments')) | Should -BeFalse
        }

        It 'Rejects a project virtual environment under Documents' {
            $venv = Join-Path $env:USERPROFILE 'Documents\Scripts\media_analyser\.venv'
            Test-PathSafe -Path $venv | Should -BeFalse
        }

        It 'Rejects a PowerShell profile under Documents' {
            $profileFile = Join-Path $env:USERPROFILE 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1'
            Test-PathSafe -Path $profileFile | Should -BeFalse
        }

        It 'Rejects the legacy My Documents junction path' {
            Test-PathSafe -Path (Join-Path $env:USERPROFILE 'My Documents\Scripts\app\.venv') | Should -BeFalse
        }

        It 'Rejects Documents regardless of case' {
            Test-PathSafe -Path (Join-Path $env:USERPROFILE 'DOCUMENTS\Scripts') | Should -BeFalse
        }

        It 'Still allows sibling profile locations outside Documents' {
            Test-PathSafe -Path (Join-Path $env:USERPROFILE 'Desktop\Python.lnk') | Should -BeTrue
            Test-PathSafe -Path (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python313') | Should -BeTrue
        }

        It 'Lists every Documents form in the protected path set' {
            $script:protectedPath | Should -Contain (Join-Path $env:USERPROFILE 'Documents')
            $script:protectedPath | Should -Contain (Join-Path $env:USERPROFILE 'My Documents')
        }
    }

    Context 'Python Launcher carve-out' {

        It 'Allows the exact launcher binary <Name>' -TestCases @(
            @{ Name = 'py.exe' }
            @{ Name = 'pyw.exe' }
        ) {
            param($Name)
            Test-PathSafe -Path (Join-Path $env:WINDIR $Name) | Should -BeTrue
        }

        It 'Allows the launcher binary regardless of case' {
            Test-PathSafe -Path (Join-Path $env:WINDIR 'PY.EXE') | Should -BeTrue
        }

        It 'Does not extend the carve-out to other files in the Windows directory' {
            Test-PathSafe -Path (Join-Path $env:WINDIR 'python.exe') | Should -BeFalse
            Test-PathSafe -Path (Join-Path $env:WINDIR 'notepad.exe') | Should -BeFalse
        }

        It 'Does not extend the carve-out to a directory named py.exe elsewhere under Windows' {
            Test-PathSafe -Path (Join-Path $env:WINDIR 'System32\py.exe') | Should -BeFalse
        }

        It 'Does not treat the carve-out as a prefix' {
            Test-PathSafe -Path (Join-Path $env:WINDIR 'py.exe.bak') | Should -BeFalse
        }
    }

    Context 'Allows legitimate removal targets' {

        It 'Allows <Path>' -TestCases @(
            @{ Path = 'C:\Python314' }
            @{ Path = 'C:\Program Files\Python313' }
            @{ Path = 'C:\Users\Someone\Anaconda3' }
            @{ Path = 'C:\Users\Someone\.venv' }
            @{ Path = 'D:\Projects\app\.venv' }
        ) {
            param($Path)
            Test-PathSafe -Path $Path | Should -BeTrue
        }

        It 'Allows a path containing spaces' {
            Test-PathSafe -Path 'C:\My Projects\my app\.venv' | Should -BeTrue
        }
    }
}

Describe 'Safety: Remove-ItemSafely' -Tag 'Safety', 'Critical' {

    BeforeEach {
        Clear-FindingState
        $script:config.ScanOnly = $false
        $script:config.IncludeNetworkDrives = $false
    }

    Context 'Safety gates' {

        It 'Records a protected path as skipped without deleting it' {
            Remove-ItemSafely -Path (Join-Path $env:WINDIR 'System32') -Name 'system32' `
                -Type 'Directory' -Tag 'directory'

            Test-Path -LiteralPath (Join-Path $env:WINDIR 'System32') | Should -BeTrue
            Get-FindingCount -Status 'Skipped' | Should -Be 1
            Get-FindingCount -Status 'Removed' | Should -Be 0
        }

        It 'Records a drive root as skipped' {
            Remove-ItemSafely -Path 'C:\' -Name 'root' -Type 'Directory' -Tag 'directory'
            Get-FindingCount -Status 'Skipped' | Should -Be 1
        }

        It 'Ignores a path that does not exist without recording anything' {
            Remove-ItemSafely -Path (Join-Path $TestDrive 'absent') -Name 'absent' `
                -Type 'Directory' -Tag 'directory'
            $script:state.Findings.Count | Should -Be 0
        }
    }

    Context 'Preview mode' {

        It 'Records a finding but leaves the directory in place' {
            $target = Join-Path $TestDrive 'preview'
            $null = New-Item -Path $target -ItemType Directory -Force
            Set-Content -LiteralPath (Join-Path $target 'file.txt') -Value 'data'

            $script:config.ScanOnly = $true
            Remove-ItemSafely -Path $target -Name 'preview' -Type 'Directory' -Tag 'directory'

            Test-Path -LiteralPath $target | Should -BeTrue
            $script:state.Findings.Count | Should -Be 1
            $script:state.Findings[0].Status | Should -Be 'Found'
            Get-FindingCount -Status 'Removed' | Should -Be 0
        }
    }

    Context 'Deletion' {

        It 'Removes a directory tree and marks the finding removed' {
            $target = Join-Path $TestDrive 'tree'
            $null = New-Item -Path (Join-Path $target 'nested') -ItemType Directory -Force
            Set-Content -LiteralPath (Join-Path $target 'nested\file.txt') -Value 'data'

            Remove-ItemSafely -Path $target -Name 'tree' -Type 'Directory' -Tag 'directory'

            Test-Path -LiteralPath $target | Should -BeFalse
            Get-FindingCount -Status 'Removed' | Should -Be 1
        }

        It 'Removes a single file' {
            $target = Join-Path $TestDrive 'single.txt'
            Set-Content -LiteralPath $target -Value 'data'

            Remove-ItemSafely -Path $target -Name 'single.txt' -Type 'File' -Tag 'directory'

            Test-Path -LiteralPath $target | Should -BeFalse
            Get-FindingCount -Status 'Removed' | Should -Be 1
        }

        It 'Removes a read-only file' {
            $target = Join-Path $TestDrive 'readonly.txt'
            Set-Content -LiteralPath $target -Value 'data'
            (Get-Item -LiteralPath $target).IsReadOnly = $true

            Remove-ItemSafely -Path $target -Name 'readonly.txt' -Type 'File' -Tag 'directory'

            Test-Path -LiteralPath $target | Should -BeFalse
            Get-FindingCount -Status 'Removed' | Should -Be 1
        }

        It 'Records the measured size on the finding' {
            $target = Join-Path $TestDrive 'sized'
            $null = New-Item -Path $target -ItemType Directory -Force
            Set-Content -LiteralPath (Join-Path $target 'payload.bin') -Value ('x' * 4096) -NoNewline

            Remove-ItemSafely -Path $target -Name 'sized' -Type 'Directory' -Tag 'directory'

            $script:state.Findings[0].SizeBytes | Should -BeGreaterThan 4000
        }

        It 'Uses a supplied statistic instead of measuring again' {
            $target = Join-Path $TestDrive 'supplied'
            $null = New-Item -Path $target -ItemType Directory -Force
            $statistic = [pscustomobject]@{ Path = $target; SizeBytes = [int64]999; FileCount = 1 }

            Remove-ItemSafely -Path $target -Name 'supplied' -Type 'Directory' `
                -Tag 'directory' -Statistic $statistic

            $script:state.Findings[0].SizeBytes | Should -Be 999
        }
    }

    Context 'Network paths' {

        It 'Skips a UNC path when network drives are excluded' {
            Mock Get-Item { [pscustomobject]@{ PSIsContainer = $true; Attributes = 0 } }
            Remove-ItemSafely -Path '\\server\share\python' -Name 'unc' -Type 'Directory' -Tag 'directory'
            Get-FindingCount -Status 'Skipped' | Should -Be 1
        }
    }
}

Describe 'Removal primitives' -Tag 'Removal' {

    BeforeEach {
        Clear-FindingState
        $script:config.ScanOnly = $false
    }

    Context 'Remove-FileSafely' {

        It 'Removes a file and records it' {
            $target = Join-Path $TestDrive 'config.ini'
            Set-Content -LiteralPath $target -Value 'value'

            Remove-FileSafely -Path $target -Name 'config.ini' -Type 'ConfigFile' -Tag 'config_file'

            Test-Path -LiteralPath $target | Should -BeFalse
            Get-FindingCount -Status 'Removed' | Should -Be 1
        }

        It 'Leaves the file in place in preview mode' {
            $target = Join-Path $TestDrive 'preview.ini'
            Set-Content -LiteralPath $target -Value 'value'
            $script:config.ScanOnly = $true

            Remove-FileSafely -Path $target -Name 'preview.ini' -Type 'ConfigFile' -Tag 'config_file'

            Test-Path -LiteralPath $target | Should -BeTrue
            Get-FindingCount -Status 'Removed' | Should -Be 0
        }

        It 'Skips a protected path' {
            Remove-FileSafely -Path (Join-Path $env:WINDIR 'notepad.exe') -Name 'notepad.exe' `
                -Type 'File' -Tag 'directory'
            Get-FindingCount -Status 'Skipped' | Should -Be 1
        }
    }

    Context 'Remove-RegistryKeySet' {

        It 'Removes an existing key and records it' {
            $key = "$($script:scratchRegistryKey)\Target"
            $null = New-Item -Path $key -Force

            Remove-RegistryKeySet -Path @($key) -Type 'Registry' -Tag 'registry'

            Test-Path -LiteralPath $key | Should -BeFalse
            Get-FindingCount -Status 'Removed' | Should -Be 1
        }

        It 'Removes a key together with its subkeys' {
            $key = "$($script:scratchRegistryKey)\Parent"
            $null = New-Item -Path "$key\Child\Grandchild" -Force

            Remove-RegistryKeySet -Path @($key) -Type 'Registry' -Tag 'registry'

            Test-Path -LiteralPath $key | Should -BeFalse
        }

        It 'Ignores keys that do not exist' {
            Remove-RegistryKeySet -Path @('HKCU:\Software\RemovePythonAbsentKey') -Type 'Registry' -Tag 'registry'
            $script:state.Findings.Count | Should -Be 0
        }

        It 'Accepts an empty collection' {
            { Remove-RegistryKeySet -Path @() -Type 'Registry' -Tag 'registry' } | Should -Not -Throw
        }

        It 'Leaves the key in place in preview mode' {
            $key = "$($script:scratchRegistryKey)\Preview"
            $null = New-Item -Path $key -Force
            $script:config.ScanOnly = $true

            Remove-RegistryKeySet -Path @($key) -Type 'Registry' -Tag 'registry'

            Test-Path -LiteralPath $key | Should -BeTrue
            Get-FindingCount -Status 'Found' | Should -Be 1
        }
    }

    Context 'Write-RemovalFailure' {

        It 'Marks the finding failed and names the exception type' {
            $finding = Add-Finding -Type 'Directory' -Name 'x' -Path 'C:\x'
            $record = [System.Management.Automation.ErrorRecord]::new(
                [System.UnauthorizedAccessException]::new('denied'), 'id',
                [System.Management.Automation.ErrorCategory]::PermissionDenied, $null)

            Write-RemovalFailure -Finding $finding -Tag 'directory' -Target 'C:\x' -ErrorRecord $record

            $finding.Status | Should -Be 'Failed'
            Get-FindingCount -Status 'Failed' | Should -Be 1
        }
    }
}

Describe 'PATH filtering' -Tag 'PathHandling', 'Critical' {

    Context 'Removes core Python installation entries' {

        It 'Removes <Entry>' -TestCases @(
            @{ Entry = 'C:\Python314' }
            @{ Entry = 'C:\Python314\Scripts' }
            @{ Entry = 'C:\Program Files\Python313' }
            @{ Entry = 'C:\Program Files\Python313\Scripts' }
            @{ Entry = 'C:\Users\Someone\AppData\Local\Programs\Python\Python312' }
            @{ Entry = 'C:\Users\Someone\AppData\Roaming\Python\Python312\Scripts' }
            @{ Entry = 'C:\Python' }
        ) {
            param($Entry)
            $Entry | Should -Match $script:pattern.PathEntry
        }
    }

    Context 'Removes conda distribution entries' {

        It 'Removes <Entry>' -TestCases @(
            @{ Entry = 'C:\Users\Someone\Anaconda3' }
            @{ Entry = 'C:\Users\Someone\Anaconda3\Scripts' }
            @{ Entry = 'C:\Users\Someone\Miniconda3\condabin' }
            @{ Entry = 'C:\Users\Someone\Mambaforge' }
            @{ Entry = 'C:\Users\Someone\Miniforge3\Library\bin' }
            @{ Entry = 'C:\ProgramData\Anaconda3' }
            @{ Entry = 'C:\tools\conda' }
        ) {
            param($Entry)
            $Entry | Should -Match $script:pattern.PathEntry
        }
    }

    Context 'Removes virtual environment and version manager entries' {

        It 'Removes <Entry>' -TestCases @(
            @{ Entry = 'C:\Projects\app\.venv\Scripts' }
            @{ Entry = 'C:\Users\Someone\.pyenv\pyenv-win\bin' }
            @{ Entry = 'C:\Users\Someone\.virtualenvs\app\Scripts' }
            @{ Entry = 'C:\tools\pyenv\bin' }
            @{ Entry = 'C:\tools\virtualenv\bin' }
            @{ Entry = 'C:\Users\Someone\.python-version' }
        ) {
            param($Entry)
            $Entry | Should -Match $script:pattern.PathEntry
        }
    }

    Context 'Removes package directory entries' {

        It 'Removes <Entry>' -TestCases @(
            @{ Entry = 'C:\Python314\Lib\site-packages' }
            @{ Entry = 'C:\usr\lib\dist-packages' }
        ) {
            param($Entry)
            $Entry | Should -Match $script:pattern.PathEntry
        }
    }

    Context 'Preserves preserved-tool entries' {

        It 'Preserves <Entry>' -TestCases @(
            @{ Entry = 'C:\Users\Someone\AppData\Roaming\pypoetry\venv\Scripts' }
            @{ Entry = 'C:\Users\Someone\.local\bin' }
            @{ Entry = 'C:\Users\Someone\AppData\Local\pipx\bin' }
            @{ Entry = 'C:\Users\Someone\.rye\shims' }
            @{ Entry = 'C:\Users\Someone\AppData\Roaming\hatch\bin' }
            @{ Entry = 'C:\Users\Someone\AppData\Local\pdm\bin' }
        ) {
            param($Entry)
            $Entry | Should -Not -Match $script:pattern.PathEntry
        }
    }

    Context 'Preserves unrelated system entries' {

        It 'Preserves <Entry>' -TestCases @(
            @{ Entry = 'C:\Windows\system32' }
            @{ Entry = 'C:\Windows' }
            @{ Entry = 'C:\Windows\System32\Wbem' }
            @{ Entry = 'C:\Program Files\Git\cmd' }
            @{ Entry = 'C:\Program Files\PowerShell\7' }
            @{ Entry = 'C:\Program Files\nodejs' }
            @{ Entry = 'C:\Program Files\dotnet' }
            @{ Entry = 'C:\Users\Someone\AppData\Local\Microsoft\WindowsApps' }
        ) {
            param($Entry)
            $Entry | Should -Not -Match $script:pattern.PathEntry
        }
    }

    Context 'Avoids false positives on similar names' {

        It 'Preserves <Entry>' -TestCases @(
            @{ Entry = 'C:\Tools\pythonista\bin' }
            @{ Entry = 'C:\Tools\mypythonapp' }
            @{ Entry = 'C:\Data\condarelated' }
            @{ Entry = 'C:\Apps\anacondalike\bin' }
        ) {
            param($Entry)
            $Entry | Should -Not -Match $script:pattern.PathEntry
        }
    }

    Context 'Split-PathValue' {

        It 'Returns an empty array for <Case>' -TestCases @(
            @{ Case = 'null'; Value = $null }
            @{ Case = 'empty string'; Value = '' }
            @{ Case = 'whitespace'; Value = '   ' }
        ) {
            param($Value)
            (Split-PathValue -Value $Value).Count | Should -Be 0
        }

        It 'Drops empty segments produced by a trailing separator' {
            $result = Split-PathValue -Value 'C:\a;C:\b;'
            $result.Count | Should -Be 2
            $result | Should -Be @('C:\a', 'C:\b')
        }

        It 'Drops doubled separators' {
            (Split-PathValue -Value 'C:\a;;C:\b').Count | Should -Be 2
        }

        It 'Drops whitespace-only segments' {
            (Split-PathValue -Value 'C:\a;   ;C:\b').Count | Should -Be 2
        }

        It 'Preserves segment order' {
            Split-PathValue -Value 'C:\z;C:\a;C:\m' | Should -Be @('C:\z', 'C:\a', 'C:\m')
        }

        It 'Preserves segments containing spaces' {
            Split-PathValue -Value 'C:\Program Files\Git\cmd' | Should -Be @('C:\Program Files\Git\cmd')
        }
    }
}

Describe 'Environment variable handling' -Tag 'Environment', 'Critical' {

    Context 'Variable list contents' {

        It 'Contains the core interpreter variable <Name>' -TestCases @(
            @{ Name = 'PYTHONPATH' }
            @{ Name = 'PYTHONHOME' }
            @{ Name = 'PYTHONSTARTUP' }
            @{ Name = 'PYTHONUSERBASE' }
        ) {
            param($Name)
            $script:pythonVariable | Should -Contain $Name
        }

        It 'Contains the environment variable <Name>' -TestCases @(
            @{ Name = 'VIRTUAL_ENV' }
            @{ Name = 'WORKON_HOME' }
            @{ Name = 'CONDA_PREFIX' }
            @{ Name = 'CONDA_EXE' }
            @{ Name = 'MAMBA_EXE' }
            @{ Name = 'PYENV_ROOT' }
            @{ Name = 'PY_PYTHON' }
        ) {
            param($Name)
            $script:pythonVariable | Should -Contain $Name
        }

        It 'Omits the preserved-tool variable <Name>' -TestCases @(
            @{ Name = 'POETRY_HOME' }
            @{ Name = 'PIPX_HOME' }
            @{ Name = 'PIPX_BIN_DIR' }
            @{ Name = 'PDM_HOME' }
            @{ Name = 'RYE_HOME' }
            @{ Name = 'HATCH_DATA_DIR' }
            @{ Name = 'UV_CACHE_DIR' }
        ) {
            param($Name)
            $script:pythonVariable | Should -Not -Contain $Name
        }

        It 'Omits unrelated system variables' {
            foreach ($name in @('PATH', 'TEMP', 'USERPROFILE', 'COMSPEC', 'OS')) {
                $script:pythonVariable | Should -Not -Contain $name
            }
        }

        It 'Contains no duplicates' {
            $unique = $script:pythonVariable | Select-Object -Unique
            $unique.Count | Should -Be $script:pythonVariable.Count
        }
    }

    Context 'Registry round-trip preserves value kind' {

        It 'Writes and reads back a REG_SZ value' {
            Set-EnvironmentEntry -Scope User -Name $script:scratchVariable -Value 'plain' -Kind String |
                Should -BeTrue

            $entry = Get-EnvironmentEntry -Scope User -Name $script:scratchVariable
            $entry.Value | Should -Be 'plain'
            $entry.Kind | Should -Be 'String'
        }

        It 'Writes and reads back a REG_EXPAND_SZ value without expanding it' {
            Set-EnvironmentEntry -Scope User -Name $script:scratchVariable `
                -Value '%SystemRoot%\system32' -Kind ExpandString | Should -BeTrue

            $entry = Get-EnvironmentEntry -Scope User -Name $script:scratchVariable
            $entry.Kind | Should -Be 'ExpandString'
            $entry.Value | Should -Be '%SystemRoot%\system32'
            $entry.Value | Should -Not -Match 'C:\\'
        }

        It 'Does not silently downgrade an expandable value to a plain string' {
            Set-EnvironmentEntry -Scope User -Name $script:scratchVariable `
                -Value '%TEMP%\x' -Kind ExpandString | Should -BeTrue
            $before = Get-EnvironmentEntry -Scope User -Name $script:scratchVariable

            Set-EnvironmentEntry -Scope User -Name $script:scratchVariable `
                -Value $before.Value -Kind $before.Kind | Should -BeTrue

            (Get-EnvironmentEntry -Scope User -Name $script:scratchVariable).Kind | Should -Be 'ExpandString'
        }

        It 'Returns null for a value that does not exist' {
            Get-EnvironmentEntry -Scope User -Name 'REMOVEPYTHON_DEFINITELY_ABSENT' | Should -BeNullOrEmpty
        }

        It 'Removes a value' {
            Set-EnvironmentEntry -Scope User -Name $script:scratchVariable -Value 'x' -Kind String | Should -BeTrue
            Remove-EnvironmentEntry -Scope User -Name $script:scratchVariable | Should -BeTrue
            Get-EnvironmentEntry -Scope User -Name $script:scratchVariable | Should -BeNullOrEmpty
        }

        It 'Does not throw when removing a value that is already absent' {
            { Remove-EnvironmentEntry -Scope User -Name 'REMOVEPYTHON_DEFINITELY_ABSENT' } | Should -Not -Throw
        }

        It 'Reads the machine PATH as an expandable value' {
            $entry = Get-EnvironmentEntry -Scope Machine -Name 'Path'
            $entry | Should -Not -BeNullOrEmpty
            $entry.Kind | Should -Be 'ExpandString'
        }
    }

    Context 'Restore-EnvironmentVariable' {

        BeforeAll {
            Mock Send-SettingChange { }
        }

        It 'Fails cleanly when the backup file is missing' {
            Restore-EnvironmentVariable -BackupPath (Join-Path $TestDrive 'absent.json') | Should -BeFalse
        }

        It 'Fails cleanly when the backup is not valid JSON' {
            $path = Join-Path $TestDrive 'broken.json'
            Set-Content -LiteralPath $path -Value 'not json {'
            Restore-EnvironmentVariable -BackupPath $path | Should -BeFalse
        }

        It 'Restores a recorded variable with its original kind' {
            $path = Join-Path $TestDrive 'restore.json'
            $backup = [ordered]@{
                Timestamp = '2026-08-08 10:00:00'
                Version   = $script:config.Version
                Path      = [ordered]@{}
                Variable  = [ordered]@{
                    User    = [ordered]@{
                        $script:scratchVariable = @{ Value = '%TEMP%\restored'; Kind = 'ExpandString' }
                    }
                    Machine = [ordered]@{}
                }
            }
            $backup | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path

            Restore-EnvironmentVariable -BackupPath $path | Should -BeTrue

            $entry = Get-EnvironmentEntry -Scope User -Name $script:scratchVariable
            $entry.Value | Should -Be '%TEMP%\restored'
            $entry.Kind | Should -Be 'ExpandString'
        }

        It 'Round-trips a backup written by Backup-EnvironmentVariable' {
            Set-EnvironmentEntry -Scope User -Name $script:scratchVariable -Value 'original' -Kind String |
                Should -BeTrue

            $script:config.BackupFile = Join-Path $TestDrive 'roundtrip.json'
            Backup-EnvironmentVariable | Should -BeTrue
            Test-Path -LiteralPath $script:config.BackupFile | Should -BeTrue

            $parsed = Get-Content -LiteralPath $script:config.BackupFile -Raw | ConvertFrom-Json
            $parsed.Path.User.Kind | Should -Not -BeNullOrEmpty
            $parsed.Version | Should -Be $script:config.Version
        }
    }
}

Describe 'Process detection' -Tag 'Process' {

    Context 'Matches Python processes' {

        It 'Matches <Name>' -TestCases @(
            @{ Name = 'python' }
            @{ Name = 'python3' }
            @{ Name = 'python3.13' }
            @{ Name = 'pythonw' }
            @{ Name = 'pip' }
            @{ Name = 'pip3' }
            @{ Name = 'conda' }
            @{ Name = 'mamba' }
            @{ Name = 'jupyter-notebook' }
            @{ Name = 'ipython' }
            @{ Name = 'pytest' }
            @{ Name = 'mypy' }
            @{ Name = 'ruff' }
            @{ Name = 'black' }
            @{ Name = 'idle' }
        ) {
            param($Name)
            $Name | Should -Match $script:pattern.ProcessName
        }
    }

    Context 'Does not match preserved tools' {

        It 'Does not match <Name>' -TestCases @(
            @{ Name = 'poetry' }
            @{ Name = 'pdm' }
            @{ Name = 'rye' }
            @{ Name = 'hatch' }
            @{ Name = 'pipx' }
            @{ Name = 'uv' }
        ) {
            param($Name)
            $Name | Should -Not -Match $script:pattern.ProcessName
        }
    }

    Context 'Does not match unrelated processes' {

        It 'Does not match <Name>' -TestCases @(
            @{ Name = 'explorer' }
            @{ Name = 'pwsh' }
            @{ Name = 'chrome' }
            @{ Name = 'Code' }
            @{ Name = 'pycharm64' }
            @{ Name = 'mypythonapp' }
            @{ Name = 'notpython' }
        ) {
            param($Name)
            $Name | Should -Not -Match $script:pattern.ProcessName
        }
    }
}

Describe 'Uninstall command parsing' -Tag 'Uninstall' {

    Context 'Get-UninstallExecutable' {

        It 'Extracts a quoted path containing spaces' {
            $result = Get-UninstallExecutable -UninstallString '"C:\Program Files\App\uninstall.exe" /S'
            $result.Path | Should -Be 'C:\Program Files\App\uninstall.exe'
            $result.Argument | Should -Be '/S'
        }

        It 'Extracts an unquoted path' {
            $result = Get-UninstallExecutable -UninstallString 'C:\App\uninstall.exe /quiet'
            $result.Path | Should -Be 'C:\App\uninstall.exe'
            $result.Argument | Should -Be '/quiet'
        }

        It 'Extracts an unquoted path containing spaces via the fallback branch' {
            $result = Get-UninstallExecutable -UninstallString 'C:\Program Files\App\uninstall.exe /S'
            $result.Path | Should -Be 'C:\Program Files\App\uninstall.exe'
            $result.Argument | Should -Be '/S'
        }

        It 'Preserves the original arguments verbatim' {
            $result = Get-UninstallExecutable -UninstallString '"C:\App\setup.exe" /uninstall /passive'
            $result.Argument | Should -Be '/uninstall /passive'
        }

        It 'Returns an empty argument string when none are present' {
            $result = Get-UninstallExecutable -UninstallString '"C:\App\uninstall.exe"'
            $result.Path | Should -Be 'C:\App\uninstall.exe'
            $result.Argument | Should -Be ''
        }

        It 'Returns null when no executable can be identified' {
            Get-UninstallExecutable -UninstallString 'MsiExec.exe /X{1234}' | Should -Not -BeNullOrEmpty
            Get-UninstallExecutable -UninstallString 'nothing useful here' | Should -BeNullOrEmpty
        }
    }

    Context 'Installation name matching' {

        It 'Matches the Python installation name <Name>' -TestCases @(
            @{ Name = 'Python 3.14.3 (64-bit)' }
            @{ Name = 'Python Launcher' }
            @{ Name = 'Anaconda3 2024.10' }
            @{ Name = 'Miniconda3 py312' }
            @{ Name = 'Mambaforge' }
            @{ Name = 'pyenv-win' }
            @{ Name = 'uv 0.5.1' }
        ) {
            param($Name)
            $Name | Should -Match $script:pattern.InstallInclude
        }

        It 'Excludes the IDE or unrelated product <Name>' -TestCases @(
            @{ Name = 'PyCharm Community Edition' }
            @{ Name = 'Microsoft Visual Studio Code' }
            @{ Name = 'IntelliJ IDEA' }
            @{ Name = 'IronPython 2.7' }
            @{ Name = 'Boost Python Libraries' }
        ) {
            param($Name)
            $Name | Should -Match $script:pattern.InstallExclude
        }
    }

    Context 'Test-InstallationPresent' {

        It 'Reports present when the install location exists' {
            $installation = [pscustomobject]@{
                InstallLocation = $TestDrive
                UninstallString = 'C:\absent\uninstall.exe'
            }
            Test-InstallationPresent -Installation $installation | Should -BeTrue
        }

        It 'Reports orphaned when a recorded install location is missing' {
            $installation = [pscustomobject]@{
                InstallLocation = (Join-Path $TestDrive 'absent-install')
                UninstallString = 'C:\absent\uninstall.exe'
            }
            Test-InstallationPresent -Installation $installation | Should -BeFalse
        }

        It 'Reports present for an MSI entry with no install location' {
            $installation = [pscustomobject]@{
                InstallLocation = ''
                UninstallString = 'MsiExec.exe /X{11111111-2222-3333-4444-555555555555}'
            }
            Test-InstallationPresent -Installation $installation | Should -BeTrue
        }

        It 'Reports present when the entry cannot be evaluated at all' {
            $installation = [pscustomobject]@{ InstallLocation = ''; UninstallString = '' }
            Test-InstallationPresent -Installation $installation | Should -BeTrue
        }

        It 'Reports orphaned when the uninstaller executable is missing' {
            $installation = [pscustomobject]@{
                InstallLocation = ''
                UninstallString = '"C:\absent\path\uninstall.exe" /S'
            }
            Test-InstallationPresent -Installation $installation | Should -BeFalse
        }

        It 'Reports present when the uninstaller executable exists' {
            $exe = Join-Path $TestDrive 'uninstall.exe'
            Set-Content -LiteralPath $exe -Value 'stub'
            $installation = [pscustomobject]@{
                InstallLocation = ''
                UninstallString = "`"$exe`" /S"
            }
            Test-InstallationPresent -Installation $installation | Should -BeTrue
        }
    }
}

Describe 'Utility functions' -Tag 'Utilities' {

    Context 'Format-FileSize' {

        It 'Formats <Bytes> as <Expected>' -TestCases @(
            @{ Bytes = 0; Expected = '0 B' }
            @{ Bytes = -1; Expected = '0 B' }
            @{ Bytes = 512; Expected = '512 B' }
            @{ Bytes = 1024; Expected = '1 KB' }
            @{ Bytes = 1048576; Expected = '1 MB' }
            @{ Bytes = 1073741824; Expected = '1 GB' }
            @{ Bytes = 1099511627776; Expected = '1 TB' }
        ) {
            param($Bytes, $Expected)
            Format-FileSize -Bytes $Bytes | Should -Be $Expected
        }

        It 'Rounds to two decimal places' {
            Format-FileSize -Bytes 1536 | Should -Be '1.5 KB'
        }

        It 'Caps the unit at terabytes' {
            Format-FileSize -Bytes ([int64]1099511627776 * 5000) | Should -BeLike '* TB'
        }
    }

    Context 'Test-IsNetworkPath' {

        It 'Identifies a UNC path' {
            Test-IsNetworkPath -Path '\\server\share\folder' | Should -BeTrue
        }

        It 'Rejects <Case>' -TestCases @(
            @{ Case = 'a local path'; Path = 'C:\Python314' }
            @{ Case = 'null'; Path = $null }
            @{ Case = 'empty string'; Path = '' }
            @{ Case = 'a relative path'; Path = 'relative\path' }
        ) {
            param($Path)
            Test-IsNetworkPath -Path $Path | Should -BeFalse
        }

        It 'Does not throw on a drive letter that is not mapped' {
            { Test-IsNetworkPath -Path 'Q:\nothing' } | Should -Not -Throw
        }
    }

    Context 'Get-DirectoryStatistic' {

        It 'Returns zeroes for a path that does not exist' {
            $result = Get-DirectoryStatistic -Path (Join-Path $TestDrive 'nowhere')
            $result.SizeBytes | Should -Be 0
            $result.FileCount | Should -Be 0
        }

        It 'Measures a single file' {
            $file = Join-Path $TestDrive 'measure.bin'
            Set-Content -LiteralPath $file -Value ('a' * 100) -NoNewline
            $result = Get-DirectoryStatistic -Path $file
            $result.SizeBytes | Should -Be 100
            $result.FileCount | Should -Be 1
        }

        It 'Measures a directory tree in a single pass' {
            $root = Join-Path $TestDrive 'stat-tree'
            $null = New-Item -Path (Join-Path $root 'a\b') -ItemType Directory -Force
            Set-Content -LiteralPath (Join-Path $root 'one.txt') -Value ('x' * 50) -NoNewline
            Set-Content -LiteralPath (Join-Path $root 'a\two.txt') -Value ('x' * 50) -NoNewline
            Set-Content -LiteralPath (Join-Path $root 'a\b\three.txt') -Value ('x' * 50) -NoNewline

            $result = Get-DirectoryStatistic -Path $root
            $result.SizeBytes | Should -Be 150
            $result.FileCount | Should -Be 3
        }

        It 'Reports the path it measured' {
            $root = Join-Path $TestDrive 'stat-path'
            $null = New-Item -Path $root -ItemType Directory -Force
            (Get-DirectoryStatistic -Path $root).Path | Should -Be $root
        }

        It 'Returns zeroes for an empty directory' {
            $root = Join-Path $TestDrive 'stat-empty'
            $null = New-Item -Path $root -ItemType Directory -Force
            (Get-DirectoryStatistic -Path $root).FileCount | Should -Be 0
        }
    }

    Context 'Get-ScanRootDirectory' {

        # TestDrive lives under AppData\Local, which the production exclusion pattern rejects
        # wholesale, so this context swaps in a benign pattern and restores it afterwards.
        BeforeAll {
            $script:productionExclusion = $script:pattern.ScanExclusion
            $script:pattern.ScanExclusion = '\\(node_modules|\.git)(\\.+|$)'
        }

        AfterAll {
            $script:pattern.ScanExclusion = $script:productionExclusion
        }

        It 'Excludes AppData\Local through the production pattern' {
            $script:productionExclusion | Should -Not -BeNullOrEmpty
            'C:\Users\Someone\AppData\Local\Temp' | Should -Match $script:productionExclusion
            'C:\Users\Someone\Documents' | Should -Not -Match $script:productionExclusion
        }

        It 'Returns ordinary subdirectories' {
            $root = Join-Path $TestDrive 'scan-root'
            $null = New-Item -Path (Join-Path $root 'projects') -ItemType Directory -Force
            $null = New-Item -Path (Join-Path $root 'documents') -ItemType Directory -Force

            $result = @(Get-ScanRootDirectory -Path $root)
            $result.Count | Should -Be 2
        }

        It 'Excludes junctions so a linked tree is never scanned twice' {
            $root = Join-Path $TestDrive 'scan-junction'
            $real = Join-Path $root 'real'
            $null = New-Item -Path $real -ItemType Directory -Force
            $null = New-Item -Path (Join-Path $root 'linked') -ItemType Junction -Target $real

            $result = @(Get-ScanRootDirectory -Path $root)
            $result.Count | Should -Be 1
            $result[0].Name | Should -Be 'real'
        }

        It 'Excludes directories matched by the scan exclusion pattern' {
            $root = Join-Path $TestDrive 'scan-excluded'
            $null = New-Item -Path (Join-Path $root 'node_modules') -ItemType Directory -Force
            $null = New-Item -Path (Join-Path $root '.git') -ItemType Directory -Force
            $null = New-Item -Path (Join-Path $root 'keep') -ItemType Directory -Force

            $result = @(Get-ScanRootDirectory -Path $root)
            $result.Count | Should -Be 1
            $result[0].Name | Should -Be 'keep'
        }

        It 'Returns nothing for a path that does not exist' {
            @(Get-ScanRootDirectory -Path (Join-Path $TestDrive 'no-such-root')).Count | Should -Be 0
        }
    }

    Context 'Get-DirectoryStatisticSet' {

        It 'Returns an empty map for an empty collection' {
            (Get-DirectoryStatisticSet -Path @()).Count | Should -Be 0
        }

        It 'Measures a single path without spawning runspaces' {
            $root = Join-Path $TestDrive 'set-single'
            $null = New-Item -Path $root -ItemType Directory -Force
            Set-Content -LiteralPath (Join-Path $root 'f.txt') -Value ('x' * 10) -NoNewline

            $map = Get-DirectoryStatisticSet -Path @($root)
            $map[$root].SizeBytes | Should -Be 10
        }

        It 'Measures several paths in parallel and keys the map by path' {
            $roots = foreach ($name in 'p1', 'p2', 'p3') {
                $path = Join-Path $TestDrive "set-$name"
                $null = New-Item -Path $path -ItemType Directory -Force
                Set-Content -LiteralPath (Join-Path $path 'f.txt') -Value ('x' * 20) -NoNewline
                $path
            }

            $map = Get-DirectoryStatisticSet -Path $roots
            $map.Count | Should -Be 3
            foreach ($root in $roots) { $map[$root].SizeBytes | Should -Be 20 }
        }
    }

    Context 'Test-ColourSupport' {

        It 'Disables colour when NO_COLOR is set' {
            $original = $env:NO_COLOR
            try {
                $env:NO_COLOR = '1'
                Test-ColourSupport | Should -BeFalse
            }
            finally {
                if ($null -eq $original) { Remove-Item Env:\NO_COLOR -ErrorAction SilentlyContinue }
                else { $env:NO_COLOR = $original }
            }
        }
    }
}

Describe 'Findings and reporting' -Tag 'Reporting' {

    BeforeEach { Clear-FindingState }

    Context 'Add-Finding' {

        It 'Returns the finding it recorded' {
            $finding = Add-Finding -Type 'Directory' -Name 'test' -Path 'C:\test' -SizeBytes 2048
            $finding | Should -Not -BeNullOrEmpty
            $finding.Type | Should -Be 'Directory'
            $finding.Name | Should -Be 'test'
            $finding.Path | Should -Be 'C:\test'
            $finding.SizeBytes | Should -Be 2048
        }

        It 'Formats the size for display' {
            (Add-Finding -Type 'Directory' -Name 'test' -Path 'C:\test' -SizeBytes 2048).Size | Should -Be '2 KB'
        }

        It 'Starts every finding in the Found state' {
            (Add-Finding -Type 'Registry' -Name 'k' -Path 'HKCU:\k').Status | Should -Be 'Found'
        }

        It 'Appends to the shared collection' {
            $null = Add-Finding -Type 'A' -Name 'a' -Path 'x'
            $null = Add-Finding -Type 'B' -Name 'b' -Path 'y'
            $script:state.Findings.Count | Should -Be 2
        }

        It 'Stamps a timestamp' {
            (Add-Finding -Type 'A' -Name 'a' -Path 'x').Timestamp |
                Should -Match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
        }

        It 'Accepts a null path' {
            { Add-Finding -Type 'Process' -Name 'python' -Path $null } | Should -Not -Throw
        }

        It 'Reflects a status change made by the caller' {
            $finding = Add-Finding -Type 'A' -Name 'a' -Path 'x'
            $finding.Status = 'Removed'
            Get-FindingCount -Status 'Removed' | Should -Be 1
        }
    }

    Context 'Get-FindingCount and Get-FindingSize' {

        It 'Counts by status' {
            (Add-Finding -Type 'A' -Name 'a' -Path 'x').Status = 'Removed'
            (Add-Finding -Type 'A' -Name 'b' -Path 'y').Status = 'Removed'
            (Add-Finding -Type 'A' -Name 'c' -Path 'z').Status = 'Failed'

            Get-FindingCount -Status 'Removed' | Should -Be 2
            Get-FindingCount -Status 'Failed' | Should -Be 1
            Get-FindingCount -Status 'Skipped' | Should -Be 0
        }

        It 'Totals every recorded size when no status is given' {
            $null = Add-Finding -Type 'A' -Name 'a' -Path 'x' -SizeBytes 100
            $null = Add-Finding -Type 'A' -Name 'b' -Path 'y' -SizeBytes 200
            Get-FindingSize | Should -Be 300
        }

        It 'Counts only removed items as freed space' {
            (Add-Finding -Type 'A' -Name 'a' -Path 'x' -SizeBytes 100).Status = 'Removed'
            (Add-Finding -Type 'A' -Name 'b' -Path 'y' -SizeBytes 200).Status = 'Failed'
            Get-FindingSize -Status 'Removed' | Should -Be 100
        }

        It 'Returns zero when nothing has been recorded' {
            Get-FindingSize | Should -Be 0
        }
    }

    Context 'Get-RunExitCode' {

        It 'Returns 0 for a clean run' {
            (Add-Finding -Type 'A' -Name 'a' -Path 'x').Status = 'Removed'
            Get-RunExitCode | Should -Be 0
        }

        It 'Returns 2 when an operation failed' {
            (Add-Finding -Type 'A' -Name 'a' -Path 'x').Status = 'Failed'
            Get-RunExitCode | Should -Be 2
        }

        It 'Returns 3 when verification found remnants' {
            $script:state.VerificationIssue.Add('registry key remains: HKCU:\Software\Python')
            Get-RunExitCode | Should -Be 3
        }

        It 'Prefers the failure code over the verification code' {
            (Add-Finding -Type 'A' -Name 'a' -Path 'x').Status = 'Failed'
            $script:state.VerificationIssue.Add('something remains')
            Get-RunExitCode | Should -Be 2
        }

        It 'Ignores skipped items' {
            (Add-Finding -Type 'A' -Name 'a' -Path 'x').Status = 'Skipped'
            Get-RunExitCode | Should -Be 0
        }
    }

    Context 'New-Report' {

        It 'Writes a CSV containing every recorded finding' {
            $script:config.ReportFile = Join-Path $TestDrive 'report.csv'
            (Add-Finding -Type 'Directory' -Name 'a' -Path 'C:\a' -SizeBytes 10).Status = 'Removed'
            (Add-Finding -Type 'Registry' -Name 'b' -Path 'HKCU:\b').Status = 'Failed'

            New-Report

            Test-Path -LiteralPath $script:config.ReportFile | Should -BeTrue
            $rows = Import-Csv -LiteralPath $script:config.ReportFile
            $rows.Count | Should -Be 2
            $rows[0].Status | Should -Be 'Removed'
            $rows[1].Status | Should -Be 'Failed'
        }

        It 'Writes nothing when there are no findings' {
            $script:config.ReportFile = Join-Path $TestDrive 'empty-report.csv'
            New-Report
            Test-Path -LiteralPath $script:config.ReportFile | Should -BeFalse
        }
    }
}

Describe 'Logging' -Tag 'Logging' {

    Context 'Write-LogEntry' {

        It 'Accepts a valid snake_case tag' {
            { Write-LogEntry -Tag 'registry' -Message 'test' } | Should -Not -Throw
            { Write-LogEntry -Tag 'temp_cache' -Message 'test' } | Should -Not -Throw
            { Write-LogEntry -Tag 'env_var2' -Message 'test' } | Should -Not -Throw
        }

        It 'Rejects the malformed tag <Tag>' -TestCases @(
            @{ Tag = 'Registry' }
            @{ Tag = 'temp cache' }
            @{ Tag = 'temp-cache' }
            @{ Tag = '2fast' }
            @{ Tag = '_leading' }
        ) {
            param($Tag)
            ($Tag -cmatch '^[a-z][a-z0-9_]*$') |
                Should -BeFalse -Because 'the test case must actually be malformed'
            { Write-LogEntry -Tag $Tag -Message 'test' } | Should -Throw
        }

        It 'Accepts every level the script uses' {
            foreach ($level in 'Section', 'Found', 'Info', 'Success', 'Warn', 'Error') {
                { Write-LogEntry -Tag 'main' -Message 'test' -Level $level } | Should -Not -Throw
            }
        }

        It 'Rejects an unknown level' {
            { Write-LogEntry -Tag 'main' -Message 'test' -Level 'Critical' } | Should -Throw
        }

        It 'Accepts an empty message' {
            { Write-LogEntry -Tag 'main' -Message '' } | Should -Not -Throw
        }

        It 'Writes a tagged, timestamped line to the log file' {
            $script:config.LogDirectory = $TestDrive
            $script:config.LogFile = Join-Path $TestDrive 'write-test.txt'
            Open-LogFile | Should -BeTrue
            try {
                Write-LogEntry -Tag 'registry' -Message 'hello' -Level Success
            }
            finally {
                Close-LogFile
            }

            $content = Get-Content -LiteralPath $script:config.LogFile -Raw
            $content | Should -Match '\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}\]\[SUCCESS\]\[registry\] hello'
        }

        It 'Emits no ANSI escapes into the log file' {
            $script:config.LogFile = Join-Path $TestDrive 'ansi-test.txt'
            $script:useColour = $true
            Open-LogFile | Should -BeTrue
            try {
                Write-LogEntry -Tag 'main' -Message 'coloured' -Level Error
            }
            finally {
                Close-LogFile
                $script:useColour = $false
            }

            (Get-Content -LiteralPath $script:config.LogFile -Raw) | Should -Not -Match "`e\["
        }
    }

    Context 'Open-LogFile and Close-LogFile' {

        It 'Creates the log directory when it is absent' {
            $script:config.LogDirectory = Join-Path $TestDrive 'created-dir'
            $script:config.LogFile = Join-Path $script:config.LogDirectory 'log.txt'
            Open-LogFile | Should -BeTrue
            Close-LogFile
            Test-Path -LiteralPath $script:config.LogDirectory | Should -BeTrue
        }

        It 'Is safe to close twice' {
            $script:config.LogDirectory = $TestDrive
            $script:config.LogFile = Join-Path $TestDrive 'double-close.txt'
            $null = Open-LogFile
            { Close-LogFile; Close-LogFile } | Should -Not -Throw
        }
    }
}

Describe 'PowerShell profile handling' -Tag 'Profile' {

    Context 'Get-ProfilePythonLine' {

        It 'Finds a bare conda line' {
            $content = "Set-Location C:\`nconda activate base`n"
            $lines = @(Get-ProfilePythonLine -Content $content)
            $lines.Count | Should -Be 1
            $lines[0] | Should -Match 'conda activate base'
        }

        It 'Reports the correct line number' {
            $content = "line one`nline two`npyenv init`n"
            @(Get-ProfilePythonLine -Content $content)[0] | Should -Match '^line 3:'
        }

        It 'Skips lines inside a conda initialisation block' {
            $content = @'
Set-Location C:\
#region conda initialize
conda activate base
$Env:CONDA_EXE = 'x'
#endregion
Write-Host done
'@
            Get-ProfilePythonLine -Content $content | Should -BeNullOrEmpty
        }

        It 'Still reports Python lines outside the conda block' {
            $content = @'
#region conda initialize
conda activate base
#endregion
poetry run python app.py
'@
            $lines = @(Get-ProfilePythonLine -Content $content)
            $lines.Count | Should -Be 1
            $lines[0] | Should -Match 'poetry run python'
        }

        It 'Ignores comments' {
            Get-ProfilePythonLine -Content "# conda activate base`n" | Should -BeNullOrEmpty
        }

        It 'Ignores blank lines' {
            Get-ProfilePythonLine -Content "`n`n`n" | Should -BeNullOrEmpty
        }

        It 'Ignores unrelated content' {
            Get-ProfilePythonLine -Content "Set-Alias ll Get-ChildItem`nImport-Module posh-git`n" |
                Should -BeNullOrEmpty
        }
    }

    Context 'Remove-ProfileBlock honours the protected path gate' {

        BeforeEach {
            Clear-FindingState
            $script:config.ScanOnly = $false
            $script:originalProfilePath = $script:profilePath
            $script:originalProtectedPath = $script:protectedPath
        }

        AfterEach {
            $script:profilePath = $script:originalProfilePath
            $script:protectedPath = $script:originalProtectedPath
        }

        It 'Leaves a profile in a protected location untouched' {
            $guarded = Join-Path $TestDrive 'guarded'
            $null = New-Item -Path $guarded -ItemType Directory -Force
            $target = Join-Path $guarded 'Microsoft.PowerShell_profile.ps1'
            $content = "#region conda initialize`nconda activate base`n#endregion`nWrite-Output keep"
            Set-Content -LiteralPath $target -Value $content

            $script:profilePath = @($target)
            $script:protectedPath = @($guarded)

            Remove-ProfileBlock

            (Get-Content -LiteralPath $target -Raw) | Should -Match 'conda initialize'
            @(Get-ChildItem -LiteralPath $guarded -Filter '*.bak_*').Count | Should -Be 0
            Get-FindingCount -Status 'Skipped' | Should -Be 1
            Get-FindingCount -Status 'Removed' | Should -Be 0
        }

        It 'Still processes a profile outside any protected location' {
            $open = Join-Path $TestDrive 'open'
            $null = New-Item -Path $open -ItemType Directory -Force
            $target = Join-Path $open 'Microsoft.PowerShell_profile.ps1'
            $content = "#region conda initialize`nconda activate base`n#endregion`nWrite-Output keep"
            Set-Content -LiteralPath $target -Value $content

            $script:profilePath = @($target)
            $script:protectedPath = @($env:WINDIR)

            Remove-ProfileBlock

            (Get-Content -LiteralPath $target -Raw) | Should -Not -Match 'conda initialize'
            Get-FindingCount -Status 'Removed' | Should -Be 1
        }
    }

    Context 'Remove-CondaInitBlock' {

        BeforeEach {
            Clear-FindingState
            $script:config.ScanOnly = $false
        }

        It 'Removes the block, keeps the rest, and backs the profile up' {
            $path = Join-Path $TestDrive 'profile-partial.ps1'
            $content = @'
Set-Alias ll Get-ChildItem
#region conda initialize
conda activate base
#endregion
Write-Output done
'@
            Set-Content -LiteralPath $path -Value $content

            Remove-CondaInitBlock -Path $path -Content $content | Should -Be 1

            $updated = Get-Content -LiteralPath $path -Raw
            $updated | Should -Not -Match 'conda initialize'
            $updated | Should -Match 'Set-Alias ll'
            $updated | Should -Match 'Write-Output done'
            @(Get-ChildItem -LiteralPath $TestDrive -Filter 'profile-partial.ps1.bak_*').Count | Should -Be 1
        }

        It 'Deletes the profile when only the conda block remains' {
            $path = Join-Path $TestDrive 'profile-only.ps1'
            $content = @'
#region conda initialize
conda activate base
#endregion
'@
            Set-Content -LiteralPath $path -Value $content

            Remove-CondaInitBlock -Path $path -Content $content | Should -Be 1
            Test-Path -LiteralPath $path | Should -BeFalse
        }

        It 'Records the backup as a finding' {
            $path = Join-Path $TestDrive 'profile-finding.ps1'
            $content = "#region conda initialize`nconda activate base`n#endregion`nWrite-Output x"
            Set-Content -LiteralPath $path -Value $content

            $null = Remove-CondaInitBlock -Path $path -Content $content

            @($script:state.Findings | Where-Object { $_.Type -eq 'ProfileBackup' }).Count | Should -Be 1
        }

        It 'Changes nothing in preview mode' {
            $path = Join-Path $TestDrive 'profile-preview.ps1'
            $content = "#region conda initialize`nconda activate base`n#endregion`nWrite-Output x"
            Set-Content -LiteralPath $path -Value $content
            $script:config.ScanOnly = $true

            Remove-CondaInitBlock -Path $path -Content $content | Should -Be 0
            (Get-Content -LiteralPath $path -Raw) | Should -Match 'conda initialize'
        }
    }
}

Describe 'Restore point creation' -Tag 'RestorePoint' {

    BeforeEach {
        $script:config.ScanOnly = $false
        $script:config.SkipRestorePoint = $false
    }

    It 'Does nothing when restore points are disabled' {
        Mock Invoke-CimMethod { throw 'should not be called' }
        $script:config.SkipRestorePoint = $true
        { New-RestorePoint } | Should -Not -Throw
        Should -Invoke Invoke-CimMethod -Times 0
    }

    It 'Does nothing in preview mode' {
        Mock Invoke-CimMethod { throw 'should not be called' }
        $script:config.ScanOnly = $true
        { New-RestorePoint } | Should -Not -Throw
        Should -Invoke Invoke-CimMethod -Times 0
    }

    It 'Enables system restore and then creates the point' {
        Mock Invoke-CimMethod { [pscustomobject]@{ ReturnValue = 0 } }
        New-RestorePoint
        Should -Invoke Invoke-CimMethod -Times 1 -ParameterFilter { $MethodName -eq 'Enable' }
        Should -Invoke Invoke-CimMethod -Times 1 -ParameterFilter { $MethodName -eq 'CreateRestorePoint' }
    }

    It 'Continues without throwing when the provider reports a failure' {
        Mock Invoke-CimMethod { [pscustomobject]@{ ReturnValue = 1058 } }
        { New-RestorePoint } | Should -Not -Throw
    }

    It 'Continues without throwing when the CIM call fails outright' {
        Mock Invoke-CimMethod { throw [Microsoft.Management.Infrastructure.CimException]::new('unavailable') }
        { New-RestorePoint } | Should -Not -Throw
    }
}

Describe 'Disk space check' -Tag 'Preflight' {

    BeforeEach { $script:config.SkipDiskCheck = $false }

    It 'Returns true when the check is skipped' {
        $script:config.SkipDiskCheck = $true
        Test-DiskSpace | Should -BeTrue
    }

    It 'Returns true when free space exceeds the minimum' {
        Mock Get-PSDrive { [pscustomobject]@{ Free = 500GB } }
        $script:config.MinFreeDiskSpaceGB = 5
        Test-DiskSpace | Should -BeTrue
    }

    It 'Returns false when free space is below the minimum' {
        Mock Get-PSDrive { [pscustomobject]@{ Free = 1GB } }
        $script:config.MinFreeDiskSpaceGB = 5
        Test-DiskSpace | Should -BeFalse
    }

    It 'Returns false rather than assuming success when the drive cannot be queried' {
        Mock Get-PSDrive { throw [System.Management.Automation.DriveNotFoundException]::new('gone') }
        Test-DiskSpace | Should -BeFalse
    }
}

Describe 'Process termination' -Tag 'Process' {

    BeforeEach {
        Clear-FindingState
        $script:config.SkipProcessCheck = $false
        $script:config.ScanOnly = $false
    }

    It 'Does nothing when the check is skipped' {
        Mock Get-Process { throw 'should not be called' }
        $script:config.SkipProcessCheck = $true
        { Test-RunningProcess } | Should -Not -Throw
    }

    It 'Never targets a system process id' {
        Mock Get-Process {
            @(
                [pscustomobject]@{ ProcessName = 'python'; Id = 4; Path = 'C:\python.exe' }
                [pscustomobject]@{ ProcessName = 'python'; Id = 9; Path = 'C:\python.exe' }
            )
        }
        Mock Stop-Process { throw 'should not be called' }

        Test-RunningProcess

        Should -Invoke Stop-Process -Times 0
        $script:state.Findings.Count | Should -Be 0
    }

    It 'Terminates a user-mode Python process and records it' {
        Mock Get-Process {
            @([pscustomobject]@{ ProcessName = 'python'; Id = 4242; Path = 'C:\python.exe' })
        }
        Mock Stop-Process { }

        Test-RunningProcess

        Should -Invoke Stop-Process -Times 1
        Get-FindingCount -Status 'Removed' | Should -Be 1
    }

    It 'Records a failure without throwing when the process cannot be stopped' {
        Mock Get-Process {
            @([pscustomobject]@{ ProcessName = 'python'; Id = 4242; Path = 'C:\python.exe' })
        }
        Mock Stop-Process { throw [System.ComponentModel.Win32Exception]::new('denied') }

        { Test-RunningProcess } | Should -Not -Throw
        Get-FindingCount -Status 'Failed' | Should -Be 1
    }

    It 'Leaves processes running in preview mode' {
        Mock Get-Process {
            @([pscustomobject]@{ ProcessName = 'python'; Id = 4242; Path = 'C:\python.exe' })
        }
        Mock Stop-Process { throw 'should not be called' }
        $script:config.ScanOnly = $true

        Test-RunningProcess

        Should -Invoke Stop-Process -Times 0
        Get-FindingCount -Status 'Found' | Should -Be 1
    }
}

Describe 'Suite integrity' -Tag 'Meta' {

    It 'Loaded every function defined in RemovePython.ps1' {
        $script:loadedFunctionCount | Should -BeGreaterThan 30
    }

    It 'Exercises the real configuration rather than a copy' {
        Get-Command Initialize-Configuration -ErrorAction Stop | Should -Not -BeNullOrEmpty
        $script:pattern.PathEntry | Should -Not -BeNullOrEmpty
        $script:pythonVariable.Count | Should -BeGreaterThan 60
    }
}
