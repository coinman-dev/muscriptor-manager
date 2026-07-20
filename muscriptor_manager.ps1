[CmdletBinding()]
param (
    [Alias('d')]
    [string]$Directory,

    [Alias('t')]
    [string]$Token,

    [Alias('m')]
    [ValidateSet('small', 'medium', 'large')]
    [string]$Model = 'large',

    [ValidateSet('auto', 'cpu', 'cuda')]
    [string]$Device = 'auto',

    [ValidateSet('auto', 'cpu', 'cu118', 'cu121', 'cu124', 'cu126', 'cu128', 'cu130')]
    [string]$TorchBackend = 'auto',

    [Alias('p')]
    [ValidateRange(1, 65535)]
    [int]$Port = 8222,

    [ValidateRange(1, 3600)]
    [int]$StartupTimeout = 180,

    [string]$BindAddress = '127.0.0.1',

    [Alias('h')]
    [Switch]$Help,

    [Switch]$Install,
    [Switch]$Update,
    [Switch]$Download,
    [Switch]$DownloadAll,
    [Switch]$ForceDownload,
    [Switch]$ListModels,
    [Switch]$GpuInfo,
    [Switch]$Start,
    [Switch]$Restart,
    [Switch]$Stop,
    [Switch]$Status,
    [Switch]$Uninstall,
    [Switch]$SaveToken,
    [Switch]$ClearSavedToken,
    [Switch]$NonInteractive,
    [Switch]$Pause
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ModelNames = @('small', 'medium', 'large')
$EnvPath = $null
$CachePath = $null
$LogPath = $null
$PidFile = $null
$StateFile = $null
$InstallMarker = $null
$PythonExe = $null
$MuscriptorExe = $null
$StdOutLog = $null
$StdErrLog = $null
$InstallationVariableName = 'Muscriptor'

function Write-Step {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "`n== $Message ==" -ForegroundColor Cyan
}

function Pause-IfRequested {
    if (-not $Pause -or -not [Environment]::UserInteractive) {
        return
    }

    Write-Host "`nPress any key to continue..." -ForegroundColor DarkGray
    [void][Console]::ReadKey($true)
}

function Enable-Utf8Runtime {
    # MuScriptor emits Unicode symbols while processing audio. Windows consoles
    # configured for a legacy code page (for example cp1251) otherwise crash Python's print().
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [Console]::OutputEncoding = $utf8
    $global:OutputEncoding = $utf8
    $env:PYTHONUTF8 = '1'
    $env:PYTHONIOENCODING = 'utf-8'
}

function Set-ManagerPaths {
    param([Parameter(Mandatory = $true)][string]$TargetDirectory)

    $script:Directory = $TargetDirectory.Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($script:Directory)) {
        throw 'The installation directory is empty. Specify -Directory explicitly.'
    }

    $script:EnvPath = Join-Path $script:Directory 'muscriptor_env'
    $script:CachePath = Join-Path $script:Directory 'HuggingFaceCache'
    $script:LogPath = Join-Path $script:Directory 'logs'
    $script:PidFile = Join-Path $script:Directory 'muscriptor.pid'
    $script:StateFile = Join-Path $script:Directory 'muscriptor.state.json'
    $script:InstallMarker = Join-Path $script:Directory '.muscriptor-manager'
    $script:PythonExe = Join-Path $script:EnvPath 'Scripts\python.exe'
    $script:MuscriptorExe = Join-Path $script:EnvPath 'Scripts\muscriptor.exe'
    $script:StdOutLog = Join-Path $script:LogPath 'muscriptor.out.log'
    $script:StdErrLog = Join-Path $script:LogPath 'muscriptor.err.log'
}

function Get-DefaultInstallationDirectory {
    if (Test-Path -LiteralPath 'D:\') {
        return 'D:\Muscriptor'
    }
    return 'C:\Muscriptor'
}

function Test-MuScriptorEnvironmentDirectory {
    param([string]$TargetDirectory)

    if ([string]::IsNullOrWhiteSpace($TargetDirectory)) {
        return $false
    }

    $cleanDirectory = $TargetDirectory.Trim().Trim('"')
    $python = Join-Path $cleanDirectory 'muscriptor_env\Scripts\python.exe'
    $executable = Join-Path $cleanDirectory 'muscriptor_env\Scripts\muscriptor.exe'
    return (Test-Path -LiteralPath $python -PathType Leaf) -and
        (Test-Path -LiteralPath $executable -PathType Leaf)
}

function Get-RegisteredInstallationDirectory {
    foreach ($scope in @('Machine', 'User')) {
        $candidate = [Environment]::GetEnvironmentVariable($InstallationVariableName, $scope)
        if ((-not [string]::IsNullOrWhiteSpace($candidate)) -and
            (Test-MuScriptorEnvironmentDirectory -TargetDirectory $candidate)) {
            return [PSCustomObject]@{
                Directory = $candidate.Trim().Trim('"')
                Scope     = $scope
            }
        }
    }
    return $null
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Register-InstallationDirectory {
    Set-Content -LiteralPath $InstallMarker -Value 'Managed by MuScriptor Manager.' -Encoding Ascii
    $target = Get-NormalizedPathEntry -PathEntry $Directory
    $machineDirectory = [Environment]::GetEnvironmentVariable($InstallationVariableName, 'Machine')
    if ((-not [string]::IsNullOrWhiteSpace($machineDirectory)) -and
        (Get-NormalizedPathEntry -PathEntry $machineDirectory) -eq $target) {
        [Environment]::SetEnvironmentVariable($InstallationVariableName, $Directory, 'Process')
        return
    }

    $scope = 'Machine'
    if (-not (Test-IsAdministrator)) {
        $scope = 'User'
        $userDirectory = [Environment]::GetEnvironmentVariable($InstallationVariableName, 'User')
        if ((-not [string]::IsNullOrWhiteSpace($userDirectory)) -and
            (Get-NormalizedPathEntry -PathEntry $userDirectory) -eq $target) {
            [Environment]::SetEnvironmentVariable($InstallationVariableName, $Directory, 'Process')
            return
        }
        Write-Warning "Run PowerShell as Administrator to store $InstallationVariableName as a system variable. It will be stored for the current user instead."
    }

    [Environment]::SetEnvironmentVariable($InstallationVariableName, $Directory, $scope)
    [Environment]::SetEnvironmentVariable($InstallationVariableName, $Directory, 'Process')
    Write-Host "Registered $InstallationVariableName=$Directory ($scope environment)." -ForegroundColor Green
}

function Unregister-InstallationDirectory {
    $target = Get-NormalizedPathEntry -PathEntry $Directory
    foreach ($scope in @('Machine', 'User')) {
        $registeredDirectory = [Environment]::GetEnvironmentVariable($InstallationVariableName, $scope)
        if ([string]::IsNullOrWhiteSpace($registeredDirectory) -or
            (Get-NormalizedPathEntry -PathEntry $registeredDirectory) -ne $target) {
            continue
        }
        if ($scope -eq 'Machine' -and -not (Test-IsAdministrator)) {
            throw "Run PowerShell as Administrator to remove the system variable $InstallationVariableName."
        }
        [Environment]::SetEnvironmentVariable($InstallationVariableName, $null, $scope)
        Write-Host "Removed $InstallationVariableName from the $scope environment." -ForegroundColor Yellow
    }
    $processDirectory = [Environment]::GetEnvironmentVariable($InstallationVariableName, 'Process')
    if ((-not [string]::IsNullOrWhiteSpace($processDirectory)) -and
        (Get-NormalizedPathEntry -PathEntry $processDirectory) -eq $target) {
        [Environment]::SetEnvironmentVariable($InstallationVariableName, $null, 'Process')
    }
}

function Resolve-InstallationDirectory {
    if (-not [string]::IsNullOrWhiteSpace($Directory)) {
        Set-ManagerPaths -TargetDirectory $Directory
        return
    }

    $defaultDirectory = Get-DefaultInstallationDirectory
    $registeredInstallation = Get-RegisteredInstallationDirectory
    if ($registeredInstallation) {
        Set-ManagerPaths -TargetDirectory $registeredInstallation.Directory
        Write-Host "Existing installation detected: $Directory (registered in $($registeredInstallation.Scope) environment)." -ForegroundColor Green
        return
    }

    Set-ManagerPaths -TargetDirectory $defaultDirectory

    $needsInstallation = -not ($Status -or $Stop -or $Uninstall -or $ListModels -or $GpuInfo)
    if (-not $needsInstallation -or $NonInteractive) {
        if ($NonInteractive -and $needsInstallation) {
            Write-Host "Installation directory was not specified. Using: $defaultDirectory" -ForegroundColor Yellow
        }
        return
    }

    $selectedDirectory = Read-Host "Installation directory [$defaultDirectory]"
    if ([string]::IsNullOrWhiteSpace($selectedDirectory)) {
        $selectedDirectory = $defaultDirectory
    }
    Set-ManagerPaths -TargetDirectory $selectedDirectory
    Write-Host "Installation directory: $Directory" -ForegroundColor Cyan
}

function Show-HelpMessage {
    Write-Host @'
MuScriptor Manager for Windows

USAGE
  .\muscriptor_manager.ps1 [options]

RUN OPTIONS
  -Model small|medium|large   Model to run (default: large)
  -Device auto|cpu|cuda      Inference device (default: auto)
  -TorchBackend auto|cpu|cu118|cu121|cu124|cu126|cu128|cu130
                              PyTorch build used during installation; auto detects GPU
  -Port <1-65535>             Web UI port (default: 8222)
  -BindAddress <address>      Bind address (default: 127.0.0.1)
  -Start                      Start in the background
  -Restart                    Restart in the background
  -Stop                       Stop the managed server
  -Status                     Show server, environment, and model status

INSTALL AND MODEL OPTIONS
  -Install                    Install/repair the environment, then exit
  -Update                     Upgrade to the newest GPU-compatible PyTorch build
  -Download                   Download the selected model, then exit
  -DownloadAll                Download small, medium, and large, then exit
  -ForceDownload              Re-download files with -Download/-DownloadAll
  -ListModels                 Show which model variants are cached
  -GpuInfo                    Show GPU, driver, and recommended PyTorch CUDA build
  -Token <hf_...>             Hugging Face read token for this run
  -SaveToken                  Save the token in the user environment (plain text)
  -NonInteractive             Never prompt; fail if a required token is absent

MAINTENANCE OPTIONS
  -Directory <path>           Environment/cache directory; prompted on first install
  -Uninstall                  Remove the managed environment and model cache
  -ClearSavedToken            Also remove the user-level HF_TOKEN
  -StartupTimeout <seconds>   Background readiness timeout (default: 180)
  -Pause                      Wait for a key before the script closes
  -Help                       Show this help

EXAMPLES
  .\muscriptor_manager.ps1 -Model medium
  .\muscriptor_manager.ps1 -Model small -Device cpu -Start
  .\muscriptor_manager.ps1 -GpuInfo
  .\muscriptor_manager.ps1 -Update
  .\muscriptor_manager.ps1 -DownloadAll
  .\muscriptor_manager.ps1 -ListModels
  .\muscriptor_manager.ps1 -Status

Without an action switch, the script installs anything missing, downloads the
selected model if necessary, and runs the server in the current console.
'@ -ForegroundColor Gray
}

function Assert-Windows {
    if ($env:OS -ne 'Windows_NT') {
        throw 'This manager targets Windows PowerShell. Use the official uvx command on Linux or macOS.'
    }
}

function Initialize-ManagerDirectory {
    if ([string]::IsNullOrWhiteSpace($Directory)) {
        throw 'The installation directory is empty. Specify -Directory explicitly.'
    }

    if (-not (Test-Path -LiteralPath $Directory)) {
        [void](New-Item -ItemType Directory -Path $Directory -Force)
    }
    if (-not (Test-Path -LiteralPath $CachePath)) {
        [void](New-Item -ItemType Directory -Path $CachePath -Force)
    }

    # Keep the cache private to this manager instead of changing user-wide settings.
    $env:HF_HOME = $CachePath
    $env:HF_HUB_DISABLE_TELEMETRY = '1'
}

function Test-CanRemoveInstallationRoot {
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        return $false
    }

    $fullDirectory = [IO.Path]::GetFullPath($Directory).TrimEnd('\\')
    $rootDirectory = [IO.Path]::GetPathRoot($fullDirectory).TrimEnd('\\')
    if ($fullDirectory -eq $rootDirectory) {
        return $false
    }

    $managedNames = @('muscriptor_env', 'HuggingFaceCache', 'logs', 'muscriptor.pid', 'muscriptor.state.json', '.muscriptor-manager')
    $items = @(Get-ChildItem -LiteralPath $Directory -Force -ErrorAction Stop)
    if ($items.Count -eq 0) {
        return $false
    }
    return @($items | Where-Object { $_.Name -notin $managedNames }).Count -eq 0
}

function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [Parameter(Mandatory = $true)][string]$FailureMessage
    )

    & $FilePath @ArgumentList | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "$FailureMessage (exit code $LASTEXITCODE)."
    }
}

function Update-ProcessPath {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machinePath;$userPath"
}

function Get-NormalizedPathEntry {
    param([Parameter(Mandatory = $true)][string]$PathEntry)

    $value = $PathEntry.Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($value)) {
        return ''
    }
    try {
        return [IO.Path]::GetFullPath($value).TrimEnd('\\').ToUpperInvariant()
    } catch {
        return $value.TrimEnd('\\').ToUpperInvariant()
    }
}

function Update-CurrentProcessPath {
    param([Parameter(Mandatory = $true)][string[]]$Entries)

    $env:Path = ($Entries -join ';')
}

function Add-InstallationDirectoryToUserPath {
    $target = Get-NormalizedPathEntry -PathEntry $Directory
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $entries = @($userPath -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $containsTarget = @($entries | Where-Object { (Get-NormalizedPathEntry -PathEntry $_) -eq $target }).Count -gt 0

    if (-not $containsTarget) {
        $entries += $Directory
        [Environment]::SetEnvironmentVariable('Path', ($entries -join ';'), 'User')
        Write-Host "Added installation directory to user PATH: $Directory" -ForegroundColor Green
    }

    $processEntries = @($env:Path -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if (@($processEntries | Where-Object { (Get-NormalizedPathEntry -PathEntry $_) -eq $target }).Count -eq 0) {
        Update-CurrentProcessPath -Entries @($processEntries + $Directory)
    }
}

function Remove-InstallationDirectoryFromUserPath {
    $target = Get-NormalizedPathEntry -PathEntry $Directory
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $entries = @($userPath -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $remainingEntries = @($entries | Where-Object { (Get-NormalizedPathEntry -PathEntry $_) -ne $target })

    if ($remainingEntries.Count -ne $entries.Count) {
        [Environment]::SetEnvironmentVariable('Path', ($remainingEntries -join ';'), 'User')
        Write-Host "Removed installation directory from user PATH: $Directory" -ForegroundColor Yellow
    }

    $processEntries = @($env:Path -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    Update-CurrentProcessPath -Entries @($processEntries | Where-Object {
            (Get-NormalizedPathEntry -PathEntry $_) -ne $target
        })
}

function Find-UvExecutable {
    $command = Get-Command 'uv.exe' -CommandType Application -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $candidates += Join-Path $env:USERPROFILE '.local\bin\uv.exe'
        $candidates += Join-Path $env:USERPROFILE '.cargo\bin\uv.exe'
    }
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $candidates += Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\uv.exe'
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    return $null
}

function Install-Uv {
    Write-Step 'Installing uv'
    Write-Host 'uv was not found. Installing it with the official Astral installer...' -ForegroundColor Yellow

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $temporaryInstaller = Join-Path ([IO.Path]::GetTempPath()) "uv-install-$([Guid]::NewGuid().ToString('N')).ps1"
    try {
        (New-Object Net.WebClient).DownloadFile('https://astral.sh/uv/install.ps1', $temporaryInstaller)
        $powerShellExecutable = Join-Path $PSHOME 'powershell.exe'
        if (-not (Test-Path -LiteralPath $powerShellExecutable -PathType Leaf)) {
            $powerShellExecutable = Join-Path $PSHOME 'pwsh.exe'
        }
        if (-not (Test-Path -LiteralPath $powerShellExecutable -PathType Leaf)) {
            throw 'Unable to locate the current PowerShell executable.'
        }
        Invoke-ExternalCommand -FilePath $powerShellExecutable `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $temporaryInstaller) `
            -FailureMessage 'The official uv installer failed'
    } catch {
        throw "Unable to install uv automatically: $($_.Exception.Message)"
    } finally {
        Remove-Item -LiteralPath $temporaryInstaller -Force -ErrorAction SilentlyContinue
    }

    Update-ProcessPath
    $uvExecutable = Find-UvExecutable
    if (-not $uvExecutable) {
        throw 'uv installation completed, but uv.exe was not found. Open a new terminal and run the script again.'
    }
    return $uvExecutable
}

function Get-UvExecutable {
    $uvExecutable = Find-UvExecutable
    if ($uvExecutable) {
        return $uvExecutable
    }
    return Install-Uv
}

function Test-EnvironmentInstalled {
    return (Test-Path -LiteralPath $PythonExe -PathType Leaf) -and
        (Test-Path -LiteralPath $MuscriptorExe -PathType Leaf)
}

function Get-MuScriptorVersion {
    if (-not (Test-Path -LiteralPath $PythonExe -PathType Leaf)) {
        return $null
    }

    try {
        $version = & $PythonExe -c "import importlib.metadata; print(importlib.metadata.version('muscriptor'))" 2>$null
        if ($LASTEXITCODE -eq 0) {
            return ($version | Select-Object -Last 1).Trim()
        }
    } catch {
        return $null
    }
    return $null
}

function Get-NvidiaGpuInfo {
    $nvidiaSmi = Get-Command 'nvidia-smi.exe' -CommandType Application -ErrorAction SilentlyContinue
    if (-not $nvidiaSmi) {
        $nvidiaSmi = Get-Command 'nvidia-smi' -CommandType Application -ErrorAction SilentlyContinue
    }
    if (-not $nvidiaSmi) {
        return @()
    }

    try {
        $rawOutput = & $nvidiaSmi.Source '--query-gpu=name,driver_version,compute_cap,memory.total' `
            '--format=csv,noheader,nounits' 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $rawOutput) {
            return @()
        }

        $devices = @()
        foreach ($row in ($rawOutput | ConvertFrom-Csv -Header 'Name', 'DriverVersion', 'ComputeCapability', 'MemoryMiB')) {
            try {
                $capability = [double]::Parse($row.ComputeCapability.Trim(), [Globalization.CultureInfo]::InvariantCulture)
                $driver = [Version]$row.DriverVersion.Trim()
                $memory = [int]$row.MemoryMiB.Trim()
                $devices += [PSCustomObject]@{
                    Name              = $row.Name.Trim()
                    DriverVersion     = $driver
                    ComputeCapability = $capability
                    MemoryMiB         = $memory
                }
            } catch {
                continue
            }
        }
        return $devices
    } catch {
        return @()
    }
}

function Get-RecommendedTorchBackend {
    param([object[]]$GpuInfo = @(Get-NvidiaGpuInfo))

    $devices = @($GpuInfo)
    if ($devices.Count -eq 0) {
        return [PSCustomObject]@{
            Backend                = 'cpu'
            MinimumDriver          = $null
            RequiresDriverUpgrade  = $false
            PreferredBackend       = 'cpu'
            PreferredDriver        = $null
            DriverUpgradeRecommended = $false
            Reason                 = 'No NVIDIA GPU was detected through nvidia-smi.'
        }
    }

    $primaryGpu = $devices[0]
    if ($primaryGpu.ComputeCapability -lt 5.0) {
        return [PSCustomObject]@{
            Backend                = 'cpu'
            MinimumDriver          = $null
            RequiresDriverUpgrade  = $false
            PreferredBackend       = 'cpu'
            PreferredDriver        = $null
            DriverUpgradeRecommended = $false
            Reason                 = "GPU compute capability $($primaryGpu.ComputeCapability) is unsupported by current PyTorch CUDA wheels."
        }
    }

    # PyTorch CUDA 12.6 is the newest binary line that still includes Pascal.
    # CUDA 12.8+ and CUDA 13 drop Pascal, while 12.6 supports Pascal through PyTorch 2.12.
    $candidateBackends = @()
    if ($primaryGpu.ComputeCapability -ge 10.0) {
        # RTX 50xx / Blackwell needs a wheel built with Blackwell support.
        # Native Windows cu128 builds have known kernel-launch failures on some
        # RTX 50xx cards, so require the current cu130 build instead.
        $candidateBackends += [PSCustomObject]@{ Name = 'cu130'; MinimumDriver = [Version]'580.65'; MinimumCapability = 10.0 }
    } elseif ($primaryGpu.ComputeCapability -ge 7.5) {
        # Turing (RTX 20xx), Ampere (30xx), and Ada (40xx).
        $candidateBackends += @(
            [PSCustomObject]@{ Name = 'cu130'; MinimumDriver = [Version]'580.65'; MinimumCapability = 7.5 },
            [PSCustomObject]@{ Name = 'cu126'; MinimumDriver = [Version]'560.76'; MinimumCapability = 5.0 },
            [PSCustomObject]@{ Name = 'cu124'; MinimumDriver = [Version]'551.61'; MinimumCapability = 5.0 },
            [PSCustomObject]@{ Name = 'cu121'; MinimumDriver = [Version]'531.14'; MinimumCapability = 5.0 },
            [PSCustomObject]@{ Name = 'cu118'; MinimumDriver = [Version]'520.06'; MinimumCapability = 5.0 }
        )
    } else {
        # Maxwell, Pascal, and Volta. cu126 is the newest PyTorch binary line
        # that retains native support for the older architectures.
        $candidateBackends += @(
            [PSCustomObject]@{ Name = 'cu126'; MinimumDriver = [Version]'560.76'; MinimumCapability = 5.0 },
            [PSCustomObject]@{ Name = 'cu124'; MinimumDriver = [Version]'551.61'; MinimumCapability = 5.0 },
            [PSCustomObject]@{ Name = 'cu121'; MinimumDriver = [Version]'531.14'; MinimumCapability = 5.0 },
            [PSCustomObject]@{ Name = 'cu118'; MinimumDriver = [Version]'520.06'; MinimumCapability = 5.0 }
        )
    }

    $selected = $candidateBackends | Where-Object {
        $primaryGpu.DriverVersion -ge $_.MinimumDriver -and $primaryGpu.ComputeCapability -ge $_.MinimumCapability
    } | Select-Object -First 1
    $preferred = $candidateBackends | Select-Object -First 1

    if ($selected) {
        return [PSCustomObject]@{
            Backend                = $selected.Name
            MinimumDriver          = $selected.MinimumDriver
            RequiresDriverUpgrade  = $false
            PreferredBackend       = $preferred.Name
            PreferredDriver        = $preferred.MinimumDriver
            DriverUpgradeRecommended = $selected.Name -ne $preferred.Name
            Reason                 = "GPU compute capability $($primaryGpu.ComputeCapability), NVIDIA driver $($primaryGpu.DriverVersion)."
        }
    }

    return [PSCustomObject]@{
        Backend                = 'cpu'
        MinimumDriver          = $preferred.MinimumDriver
        RequiresDriverUpgrade  = $true
        PreferredBackend       = $preferred.Name
        PreferredDriver        = $preferred.MinimumDriver
        DriverUpgradeRecommended = $true
        Reason                 = "NVIDIA driver $($primaryGpu.DriverVersion) is too old for supported PyTorch CUDA wheels."
    }
}

function Get-TorchBackendPlan {
    $gpuInfo = @(Get-NvidiaGpuInfo)
    $recommended = Get-RecommendedTorchBackend -GpuInfo $gpuInfo

    if ($Device -eq 'cpu' -or $TorchBackend -eq 'cpu') {
        return [PSCustomObject]@{
            Backend       = 'cpu'
            Recommended   = $recommended
            GpuInfo       = $gpuInfo
            IsManual      = $TorchBackend -ne 'auto'
        }
    }

    if ($TorchBackend -eq 'auto') {
        return [PSCustomObject]@{
            Backend       = $recommended.Backend
            Recommended   = $recommended
            GpuInfo       = $gpuInfo
            IsManual      = $false
        }
    }

    $minimumCapability = 5.0
    $minimumDriver = [Version]'520.06'
    switch ($TorchBackend) {
        'cu121' { $minimumDriver = [Version]'531.14' }
        'cu124' { $minimumDriver = [Version]'551.61' }
        'cu126' { $minimumDriver = [Version]'560.76' }
        'cu128' { $minimumDriver = [Version]'570.65'; $minimumCapability = 7.5 }
        'cu130' { $minimumDriver = [Version]'580.65'; $minimumCapability = 7.5 }
    }

    if ($gpuInfo.Count -gt 0) {
        $primaryGpu = $gpuInfo[0]
        if ($primaryGpu.ComputeCapability -ge 10.0 -and $TorchBackend -ne 'cu130') {
            throw "-TorchBackend $TorchBackend cannot run reliably on $($primaryGpu.Name) (compute capability $($primaryGpu.ComputeCapability)). RTX 50xx/Blackwell on Windows requires cu130."
        }
        if ($primaryGpu.ComputeCapability -lt $minimumCapability) {
            throw "-TorchBackend $TorchBackend is unsupported by $($primaryGpu.Name) (compute capability $($primaryGpu.ComputeCapability)). Use $($recommended.Backend), or update the NVIDIA driver and use cu126 for Pascal/Volta."
        }
        if ($primaryGpu.DriverVersion -lt $minimumDriver) {
            throw "-TorchBackend $TorchBackend requires NVIDIA driver $minimumDriver or newer; detected $($primaryGpu.DriverVersion)."
        }
    }

    return [PSCustomObject]@{
        Backend       = $TorchBackend
        Recommended   = $recommended
        GpuInfo       = $gpuInfo
        IsManual      = $true
    }
}

function Show-GpuStatus {
    $plan = Get-TorchBackendPlan
    if ($plan.GpuInfo.Count -eq 0) {
        Write-Host 'NVIDIA GPU: not detected through nvidia-smi' -ForegroundColor Yellow
        Write-Host 'Recommended PyTorch backend: cpu' -ForegroundColor Yellow
        return $plan
    }

    foreach ($gpu in $plan.GpuInfo) {
        $memoryGiB = $gpu.MemoryMiB / 1024
        Write-Host "NVIDIA GPU: $($gpu.Name) | compute capability $($gpu.ComputeCapability) | $($memoryGiB.ToString('N1')) GB VRAM" -ForegroundColor Green
        Write-Host "NVIDIA driver: $($gpu.DriverVersion)" -ForegroundColor Gray
    }

    Write-Host "Recommended PyTorch backend: $($plan.Recommended.Backend)" -ForegroundColor Cyan
    if ($plan.Recommended.Backend -eq 'cu126' -and $plan.GpuInfo[0].ComputeCapability -lt 7.5) {
        Write-Host 'cu126 is the newest supported PyTorch CUDA build for this Pascal/Volta-class GPU.' -ForegroundColor Gray
    }
    if ($plan.Recommended.DriverUpgradeRecommended -and -not $plan.Recommended.RequiresDriverUpgrade) {
        Write-Warning "Current driver supports $($plan.Recommended.Backend). Update the NVIDIA driver to $($plan.Recommended.PreferredDriver) or newer for $($plan.Recommended.PreferredBackend). Driver download: https://www.nvidia.com/Download/index.aspx"
    }
    if ($plan.Recommended.RequiresDriverUpgrade) {
        Write-Warning "Update the NVIDIA driver to $($plan.Recommended.MinimumDriver) or newer, then run -Update. Driver download: https://www.nvidia.com/Download/index.aspx"
    }
    return $plan
}

function Ensure-Environment {
    param([Switch]$Upgrade)

    $installedVersion = Get-MuScriptorVersion
    $environmentReady = (Test-EnvironmentInstalled) -and (-not [string]::IsNullOrWhiteSpace($installedVersion))
    if ($environmentReady -and -not $Upgrade) {
        Register-InstallationDirectory
        Add-InstallationDirectoryToUserPath
        Write-Host "Environment detected (MuScriptor $installedVersion)." -ForegroundColor Green
        return
    }

    $uvExecutable = Get-UvExecutable
    if (-not (Test-Path -LiteralPath $PythonExe -PathType Leaf)) {
        Write-Step 'Creating Python environment'
        $venvArguments = @('venv', '--python', '3.12')
        if (Test-Path -LiteralPath $EnvPath) {
            $venvArguments += '--clear'
        }
        $venvArguments += $EnvPath
        Invoke-ExternalCommand -FilePath $uvExecutable -ArgumentList $venvArguments `
            -FailureMessage 'Unable to create the Python 3.12 environment'
    }

    Write-Step 'Installing MuScriptor'
    $torchPlan = Get-TorchBackendPlan
    $effectiveBackend = $torchPlan.Backend
    Write-Host "Selected PyTorch backend: $effectiveBackend" -ForegroundColor Cyan
    if ($torchPlan.Recommended.RequiresDriverUpgrade) {
        Write-Warning "NVIDIA driver update required for CUDA. Installing the CPU build. Download: https://www.nvidia.com/Download/index.aspx"
    }

    $installArguments = @(
        'pip', 'install',
        '--python', $PythonExe,
        '--torch-backend', $effectiveBackend
    )
    if ($Upgrade) {
        $installArguments += '--upgrade'
    }
    $installArguments += 'muscriptor>=0.2.1'

    Invoke-ExternalCommand -FilePath $uvExecutable -ArgumentList $installArguments `
        -FailureMessage 'Unable to install MuScriptor'

    if (-not (Test-EnvironmentInstalled)) {
        throw 'Installation finished without creating the expected muscriptor.exe.'
    }

    $checkCode = 'import huggingface_hub, muscriptor, torch; print("torch=" + torch.__version__)'
    Invoke-ExternalCommand -FilePath $PythonExe -ArgumentList @('-c', $checkCode) `
        -FailureMessage 'The installed Python environment failed its import check'

    $version = Get-MuScriptorVersion
    Register-InstallationDirectory
    Add-InstallationDirectoryToUserPath
    Write-Host "MuScriptor $version is ready." -ForegroundColor Green
}

function Get-ModelState {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('small', 'medium', 'large')]
        [string]$Name
    )

    $repository = "MuScriptor/muscriptor-$Name"
    $repositoryCache = Join-Path $CachePath "hub\models--MuScriptor--muscriptor-$Name"
    $weightsPath = $null

    $mainReference = Join-Path $repositoryCache 'refs\main'
    if (Test-Path -LiteralPath $mainReference -PathType Leaf) {
        try {
            $revision = (Get-Content -LiteralPath $mainReference -Raw).Trim()
            if ($revision -match '^[0-9a-fA-F]+$') {
                $referencedWeights = Join-Path $repositoryCache "snapshots\$revision\model.safetensors"
                if (Test-Path -LiteralPath $referencedWeights -PathType Leaf) {
                    $weightsPath = $referencedWeights
                }
            }
        } catch {
            $weightsPath = $null
        }
    }

    if (-not $weightsPath) {
        $snapshotPath = Join-Path $repositoryCache 'snapshots'
        if (Test-Path -LiteralPath $snapshotPath -PathType Container) {
            $candidate = Get-ChildItem -LiteralPath $snapshotPath -Filter 'model.safetensors' `
                -File -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notlike '*.incomplete' -and $_.Length -gt 1024 } |
                Sort-Object LastWriteTimeUtc -Descending |
                Select-Object -First 1
            if ($candidate) {
                $weightsPath = $candidate.FullName
            }
        }
    }

    $cached = $false
    $sizeBytes = [int64]0
    $configPath = $null
    if ($weightsPath -and (Test-Path -LiteralPath $weightsPath -PathType Leaf)) {
        $weightItem = Get-Item -LiteralPath $weightsPath
        if ($weightItem.Length -gt 1024) {
            $cached = $true
            $sizeBytes = $weightItem.Length
            $possibleConfig = Join-Path $weightItem.DirectoryName 'config.json'
            if (Test-Path -LiteralPath $possibleConfig -PathType Leaf) {
                $configPath = $possibleConfig
            }
        }
    }

    return [PSCustomObject]@{
        Name       = $Name
        Repository = $repository
        Cached     = $cached
        Weights    = $weightsPath
        Config     = $configPath
        SizeBytes  = $sizeBytes
    }
}

function Show-ModelStatus {
    $rows = foreach ($name in $ModelNames) {
        $state = Get-ModelState -Name $name
        $size = '-'
        if ($state.Cached) {
            $size = '{0:N2} GB' -f ($state.SizeBytes / 1GB)
        }
        [PSCustomObject]@{
            Model  = $state.Name
            Status = $(if ($state.Cached) { 'downloaded' } else { 'not downloaded' })
            Size   = $size
        }
    }
    $rows | Format-Table -AutoSize | Out-Host
}

function Convert-SecureStringToText {
    param([Parameter(Mandatory = $true)][System.Security.SecureString]$SecureValue)

    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function Resolve-HuggingFaceToken {
    $resolvedToken = $Token
    if ([string]::IsNullOrWhiteSpace($resolvedToken)) {
        $resolvedToken = $env:HF_TOKEN
    }
    if ([string]::IsNullOrWhiteSpace($resolvedToken)) {
        $resolvedToken = [Environment]::GetEnvironmentVariable('HF_TOKEN', 'User')
    }
    if ([string]::IsNullOrWhiteSpace($resolvedToken) -and (Test-Path -LiteralPath $PythonExe -PathType Leaf)) {
        try {
            $hubToken = & $PythonExe -c 'from huggingface_hub import get_token; print(get_token() or "")' 2>$null
            if ($LASTEXITCODE -eq 0) {
                $resolvedToken = ($hubToken | Select-Object -Last 1).Trim()
            }
        } catch {
            $resolvedToken = $null
        }
    }

    if ([string]::IsNullOrWhiteSpace($resolvedToken)) {
        if ($NonInteractive) {
            throw 'HF_TOKEN is required to download a gated model, but -NonInteractive prevents prompting.'
        }

        Write-Host "`nThe model is gated on Hugging Face." -ForegroundColor Yellow
        Write-Host 'Accept its license in the browser, then enter a read token.' -ForegroundColor Yellow
        Write-Host 'Token page: https://huggingface.co/settings/tokens' -ForegroundColor Cyan
        $secureToken = Read-Host 'HF_TOKEN' -AsSecureString
        $resolvedToken = Convert-SecureStringToText -SecureValue $secureToken
    }

    if ([string]::IsNullOrWhiteSpace($resolvedToken)) {
        throw 'A non-empty Hugging Face token is required to download MuScriptor models.'
    }

    $resolvedToken = $resolvedToken.Trim()
    $env:HF_TOKEN = $resolvedToken
    if ($SaveToken) {
        [Environment]::SetEnvironmentVariable('HF_TOKEN', $resolvedToken, 'User')
        Write-Host 'HF_TOKEN was saved for the current Windows user.' -ForegroundColor Green
    }
    return $resolvedToken
}

function Invoke-ModelDownload {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('small', 'medium', 'large')]
        [string]$Name,
        [Switch]$Force
    )

    $repository = "MuScriptor/muscriptor-$Name"
    Write-Step "Downloading model '$Name'"
    Write-Host "License page: https://huggingface.co/$repository" -ForegroundColor Cyan

    $previousOfflineValue = $env:HF_HUB_OFFLINE
    $env:HF_HUB_OFFLINE = '0'
    $env:MUSCRIPTOR_DOWNLOAD_REPO = $repository
    $env:MUSCRIPTOR_FORCE_DOWNLOAD = $(if ($Force) { '1' } else { '0' })

    $downloadCode = @'
import os
from huggingface_hub import hf_hub_download

repo = os.environ["MUSCRIPTOR_DOWNLOAD_REPO"]
force = os.environ.get("MUSCRIPTOR_FORCE_DOWNLOAD") == "1"
for filename in ("config.json", "model.safetensors"):
    path = hf_hub_download(repo_id=repo, filename=filename, force_download=force)
    print(f"cached: {path}")
'@

    try {
        & $PythonExe -c $downloadCode | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "Download command exited with code $LASTEXITCODE."
        }
    } catch {
        throw "Unable to download '$Name'. Accept the license at https://huggingface.co/$repository and verify HF_TOKEN. $($_.Exception.Message)"
    } finally {
        Remove-Item Env:MUSCRIPTOR_DOWNLOAD_REPO -ErrorAction SilentlyContinue
        Remove-Item Env:MUSCRIPTOR_FORCE_DOWNLOAD -ErrorAction SilentlyContinue
        if ($null -eq $previousOfflineValue) {
            Remove-Item Env:HF_HUB_OFFLINE -ErrorAction SilentlyContinue
        } else {
            $env:HF_HUB_OFFLINE = $previousOfflineValue
        }
    }

    $state = Get-ModelState -Name $Name
    if (-not $state.Cached) {
        throw "The download command completed, but '$Name' was not found in the expected cache."
    }
    Write-Host "Model '$Name' is ready ($('{0:N2}' -f ($state.SizeBytes / 1GB)) GB)." -ForegroundColor Green
}

function Ensure-Models {
    param(
        [Parameter(Mandatory = $true)][string[]]$Names,
        [Switch]$Force
    )

    $modelsToDownload = @()
    foreach ($name in $Names) {
        $state = Get-ModelState -Name $name
        if ($Force -or -not $state.Cached) {
            $modelsToDownload += $name
        } else {
            Write-Host "Model '$name' is already downloaded." -ForegroundColor Green
        }
    }

    if ($modelsToDownload.Count -eq 0) {
        return
    }

    [void](Resolve-HuggingFaceToken)
    foreach ($name in $modelsToDownload) {
        Invoke-ModelDownload -Name $name -Force:$Force
    }
}

function Read-RuntimeState {
    if (-not (Test-Path -LiteralPath $StateFile -PathType Leaf)) {
        return $null
    }
    try {
        return Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Get-SavedServerId {
    if (-not (Test-Path -LiteralPath $PidFile -PathType Leaf)) {
        return $null
    }
    try {
        $value = (Get-Content -LiteralPath $PidFile -Raw).Trim()
        $serverId = 0
        if ([int]::TryParse($value, [ref]$serverId) -and $serverId -gt 0) {
            return $serverId
        }
    } catch {
        return $null
    }
    return $null
}

function Get-MuScriptorProcess {
    $serverId = Get-SavedServerId
    if ($serverId) {
        $savedProcess = Get-Process -Id $serverId -ErrorAction SilentlyContinue
        if ($savedProcess) {
            try {
                if (-not $savedProcess.Path -or $savedProcess.Path.StartsWith($EnvPath, [StringComparison]::OrdinalIgnoreCase)) {
                    return $savedProcess
                }
            } catch {
                return $savedProcess
            }
        }
    }

    $processes = Get-Process -Name 'python', 'muscriptor' -ErrorAction SilentlyContinue
    foreach ($candidate in $processes) {
        try {
            if ($candidate.Path -and $candidate.Path.StartsWith($EnvPath, [StringComparison]::OrdinalIgnoreCase)) {
                return $candidate
            }
        } catch {
            continue
        }
    }
    return $null
}

function Remove-RuntimeFiles {
    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue
}

function Stop-MuScriptorServer {
    $serverProcess = Get-MuScriptorProcess
    if ($serverProcess) {
        Write-Host "Stopping MuScriptor (PID $($serverProcess.Id))..." -ForegroundColor Yellow
        Stop-Process -Id $serverProcess.Id -ErrorAction SilentlyContinue
        try {
            Wait-Process -Id $serverProcess.Id -Timeout 10 -ErrorAction Stop
        } catch {
            Stop-Process -Id $serverProcess.Id -Force -ErrorAction SilentlyContinue
        }
    }

    $remainingProcesses = Get-Process -Name 'python', 'muscriptor' -ErrorAction SilentlyContinue
    foreach ($candidate in $remainingProcesses) {
        try {
            if ($candidate.Path -and $candidate.Path.StartsWith($EnvPath, [StringComparison]::OrdinalIgnoreCase)) {
                Stop-Process -Id $candidate.Id -Force -ErrorAction SilentlyContinue
            }
        } catch {
            continue
        }
    }
    Remove-RuntimeFiles
}

function Show-MuScriptorStatus {
    Write-Step 'MuScriptor status'
    $serverProcess = Get-MuScriptorProcess
    $runtimeState = Read-RuntimeState
    if ($serverProcess) {
        $statusPort = $Port
        $statusAddress = $BindAddress
        $statusModel = 'unknown'
        $statusDevice = 'unknown'
        if ($runtimeState) {
            $statusPort = $runtimeState.Port
            $statusAddress = $runtimeState.BindAddress
            $statusModel = $runtimeState.Model
            $statusDevice = $runtimeState.Device
        }
        $browserAddress = $(if ($statusAddress -in @('0.0.0.0', '::')) { '127.0.0.1' } else { $statusAddress })
        Write-Host 'RUNNING' -ForegroundColor Green
        Write-Host "PID: $($serverProcess.Id)"
        Write-Host "Model: $statusModel"
        Write-Host "Device: $statusDevice"
        Write-Host "Web UI: http://${browserAddress}:$statusPort/" -ForegroundColor Cyan
    } else {
        Write-Host 'STOPPED' -ForegroundColor Yellow
        Remove-RuntimeFiles
    }

    $version = Get-MuScriptorVersion
    if ($version) {
        Write-Host "Environment: installed (MuScriptor $version)" -ForegroundColor Green
    } else {
        Write-Host 'Environment: not installed' -ForegroundColor Yellow
    }
    Write-Host ''
    [void](Show-GpuStatus)
    Write-Host ''
    Show-ModelStatus
}

function Test-TcpPortOpen {
    param(
        [Parameter(Mandatory = $true)][string]$Address,
        [Parameter(Mandatory = $true)][int]$TargetPort,
        [int]$TimeoutMilliseconds = 500
    )

    $connectAddress = $(if ($Address -in @('0.0.0.0', '::')) { '127.0.0.1' } else { $Address })
    $client = New-Object Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($connectAddress, $TargetPort)
        if (-not $task.Wait($TimeoutMilliseconds)) {
            return $false
        }
        return $client.Connected
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

function Get-TorchInfo {
    $code = @'
import json
import torch
print(json.dumps({
    "version": torch.__version__,
    "cuda_available": torch.cuda.is_available(),
    "cuda_version": torch.version.cuda,
    "device_name": torch.cuda.get_device_name(0) if torch.cuda.is_available() else None,
}))
'@
    $output = & $PythonExe -c $code
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to inspect the installed PyTorch runtime.'
    }
    return (($output | Select-Object -Last 1) | ConvertFrom-Json)
}

function Assert-DeviceAvailable {
    $torchInfo = Get-TorchInfo
    $torchPlan = Get-TorchBackendPlan
    Write-Host "PyTorch $($torchInfo.version)" -ForegroundColor Gray
    if ($torchInfo.cuda_available) {
        Write-Host "CUDA $($torchInfo.cuda_version): $($torchInfo.device_name)" -ForegroundColor Green
        if ($torchPlan.Recommended.Backend -ne 'cpu') {
            $installedBackend = "cu$($torchInfo.cuda_version.Replace('.', ''))"
            if ($installedBackend -ne $torchPlan.Recommended.Backend) {
                Write-Host "Newest compatible backend for this GPU/driver: $($torchPlan.Recommended.Backend). Run -Update to install it." -ForegroundColor Yellow
            }
        }
    } else {
        Write-Host 'CUDA is not available; automatic mode will use CPU.' -ForegroundColor Yellow
    }

    if ($Device -eq 'cuda' -and -not $torchInfo.cuda_available) {
        throw "-Device cuda was requested, but CUDA is unavailable. Use -Device cpu, or update the NVIDIA driver and run -Update."
    }
    if ($Model -eq 'large' -and $Device -eq 'cpu') {
        Write-Warning "The large model is very slow on CPU. Consider -Model small or -Device auto."
    }
}

function Write-RuntimeState {
    param([Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process)

    $state = [PSCustomObject]@{
        Pid         = $Process.Id
        Model       = $Model
        Device      = $Device
        Port        = $Port
        BindAddress = $BindAddress
        StartedUtc  = [DateTime]::UtcNow.ToString('o')
    }
    $Process.Id | Set-Content -LiteralPath $PidFile -Encoding Ascii
    $state | ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding UTF8
}

function Start-MuScriptorBackground {
    param([Parameter(Mandatory = $true)][string]$WeightsPath)

    if (-not (Test-Path -LiteralPath $LogPath)) {
        [void](New-Item -ItemType Directory -Path $LogPath -Force)
    }
    if (Test-TcpPortOpen -Address $BindAddress -TargetPort $Port) {
        throw "Port $Port is already in use on $BindAddress. Choose another value with -Port."
    }

    $escapedWeightsPath = $WeightsPath.Replace('"', '\"')
    $arguments = "-m muscriptor serve --model `"$escapedWeightsPath`" --device $Device --host $BindAddress --port $Port"
    Write-Step "Starting MuScriptor in the background"
    $process = Start-Process -FilePath $PythonExe -ArgumentList $arguments -WorkingDirectory $Directory `
        -RedirectStandardOutput $StdOutLog -RedirectStandardError $StdErrLog -PassThru
    Write-RuntimeState -Process $process

    $deadline = [DateTime]::UtcNow.AddSeconds($StartupTimeout)
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $process.Refresh()
        if ($process.HasExited) {
            $errorTail = ''
            if (Test-Path -LiteralPath $StdErrLog -PathType Leaf) {
                $errorTail = (Get-Content -LiteralPath $StdErrLog -Tail 30) -join "`n"
            }
            Remove-RuntimeFiles
            throw "MuScriptor exited during startup (exit code $($process.ExitCode)).`n$errorTail"
        }
        if (Test-TcpPortOpen -Address $BindAddress -TargetPort $Port) {
            $browserAddress = $(if ($BindAddress -in @('0.0.0.0', '::')) { '127.0.0.1' } else { $BindAddress })
            Write-Host "Server is ready (PID $($process.Id))." -ForegroundColor Green
            Write-Host "Web UI: http://${browserAddress}:$Port/" -ForegroundColor Cyan
            Write-Host "Logs: $StdOutLog and $StdErrLog" -ForegroundColor Gray
            return
        }
    }

    Write-Warning "The process is still running, but port $Port did not become ready within $StartupTimeout seconds. Check $StdErrLog."
}

function Start-MuScriptorConsole {
    param([Parameter(Mandatory = $true)][string]$WeightsPath)

    if (Test-TcpPortOpen -Address $BindAddress -TargetPort $Port) {
        throw "Port $Port is already in use on $BindAddress. Choose another value with -Port."
    }

    $browserAddress = $(if ($BindAddress -in @('0.0.0.0', '::')) { '127.0.0.1' } else { $BindAddress })
    Write-Step "Starting MuScriptor in the current console"
    Write-Host "Model: $Model | Device: $Device"
    Write-Host "Web UI: http://${browserAddress}:$Port/" -ForegroundColor Cyan
    Write-Host 'Press Ctrl+C to stop.' -ForegroundColor Yellow
    & $MuscriptorExe serve --model $WeightsPath --device $Device --host $BindAddress --port $Port
    if ($LASTEXITCODE -ne 0) {
        throw "MuScriptor exited with code $LASTEXITCODE."
    }
}

function Uninstall-MuScriptor {
    Write-Step 'Uninstalling MuScriptor'
    Stop-MuScriptorServer
    $removeInstallationRoot = Test-CanRemoveInstallationRoot
    Unregister-InstallationDirectory
    Remove-InstallationDirectoryFromUserPath

    if (Test-Path -LiteralPath $EnvPath) {
        Write-Host "Removing environment: $EnvPath" -ForegroundColor Yellow
        Remove-Item -LiteralPath $EnvPath -Recurse -Force
    }
    if (Test-Path -LiteralPath $CachePath) {
        Write-Host "Removing model cache: $CachePath" -ForegroundColor Yellow
        Remove-Item -LiteralPath $CachePath -Recurse -Force
    }
    if (Test-Path -LiteralPath $LogPath) {
        Remove-Item -LiteralPath $LogPath -Recurse -Force
    }
    Remove-RuntimeFiles

    if ($removeInstallationRoot -and (Test-Path -LiteralPath $Directory -PathType Container)) {
        Write-Host "Removing installation directory: $Directory" -ForegroundColor Yellow
        Remove-Item -LiteralPath $Directory -Recurse -Force
    } elseif (Test-Path -LiteralPath $Directory -PathType Container) {
        Write-Warning "Installation directory was retained because it contains files not managed by MuScriptor: $Directory"
    }

    if ($ClearSavedToken) {
        [Environment]::SetEnvironmentVariable('HF_TOKEN', $null, 'User')
        Write-Host 'User-level HF_TOKEN removed.' -ForegroundColor Yellow
    }
    Write-Host 'Uninstall complete.' -ForegroundColor Green
}

function Assert-ActionSelection {
    $actions = @(
        @(
            $Install.IsPresent,
            $Update.IsPresent,
            $Download.IsPresent,
            $DownloadAll.IsPresent,
            $ListModels.IsPresent,
            $GpuInfo.IsPresent,
            $Start.IsPresent,
            $Restart.IsPresent,
            $Stop.IsPresent,
            $Status.IsPresent,
            $Uninstall.IsPresent
        ) | Where-Object { $_ }
    )

    if ($actions.Count -gt 1) {
        throw 'Choose only one action: -Install, -Update, -Download, -DownloadAll, -ListModels, -GpuInfo, -Start, -Restart, -Stop, -Status, or -Uninstall.'
    }
    if ($ForceDownload -and -not ($Download -or $DownloadAll)) {
        throw '-ForceDownload can only be used with -Download or -DownloadAll.'
    }
    if ($ClearSavedToken -and -not $Uninstall) {
        throw '-ClearSavedToken can only be used with -Uninstall.'
    }
    if ($SaveToken -and $Uninstall) {
        throw '-SaveToken cannot be combined with -Uninstall.'
    }
}

function Invoke-Main {
    if ($Help) {
        Show-HelpMessage
        return 0
    }

    Assert-ActionSelection
    Assert-Windows
    Enable-Utf8Runtime
    Resolve-InstallationDirectory
    if (-not $Uninstall) {
        Initialize-ManagerDirectory
    }

    if ($SaveToken) {
        [void](Resolve-HuggingFaceToken)
    }

    if ($Uninstall) {
        Uninstall-MuScriptor
        return 0
    }
    if ($Stop) {
        Write-Step 'Stopping MuScriptor'
        Stop-MuScriptorServer
        Write-Host 'Server stopped.' -ForegroundColor Green
        return 0
    }
    if ($Status) {
        Show-MuScriptorStatus
        return 0
    }
    if ($ListModels) {
        Write-Step 'Downloaded models'
        Show-ModelStatus
        return 0
    }
    if ($GpuInfo) {
        Write-Step 'GPU and CUDA compatibility'
        [void](Show-GpuStatus)
        return 0
    }
    if ($Install) {
        Ensure-Environment
        return 0
    }
    if ($Update) {
        Ensure-Environment -Upgrade
        return 0
    }

    Ensure-Environment

    if ($DownloadAll) {
        Ensure-Models -Names $ModelNames -Force:$ForceDownload
        Write-Step 'Downloaded models'
        Show-ModelStatus
        return 0
    }
    if ($Download) {
        Ensure-Models -Names @($Model) -Force:$ForceDownload
        Show-ModelStatus
        return 0
    }

    $runningProcess = Get-MuScriptorProcess
    if ($runningProcess -and -not $Restart) {
        Write-Host "MuScriptor is already running (PID $($runningProcess.Id)). Use -Restart or -Stop." -ForegroundColor Yellow
        return 0
    }
    if ($Restart) {
        Stop-MuScriptorServer
    }

    Ensure-Models -Names @($Model)
    $modelState = Get-ModelState -Name $Model
    if (-not $modelState.Cached) {
        throw "Model '$Model' is not available after download."
    }

    Assert-DeviceAvailable
    if ($Start -or $Restart) {
        Start-MuScriptorBackground -WeightsPath $modelState.Weights
    } else {
        Start-MuScriptorConsole -WeightsPath $modelState.Weights
    }
    return 0
}

$exitCode = 1
try {
    $exitCode = Invoke-Main
} catch {
    Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
    if ($VerbosePreference -eq 'Continue') {
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    }
    $exitCode = 1
} finally {
    Pause-IfRequested
}

exit $exitCode
