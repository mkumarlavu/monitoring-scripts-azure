# Runs under Windows PowerShell 5.1 before the composite action's pwsh step.
# Dot-source this file, then call Initialize-NwbPowerShell. No machine-wide install.
function Test-NwbPowerShell7 {
    param([string]$Executable)
    if (-not $Executable -or -not (Test-Path -LiteralPath $Executable -PathType Leaf)) { return $false }
    try {
        $major = & $Executable -NoLogo -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.Major' 2>$null
        return ($LASTEXITCODE -eq 0 -and ([string]$major).Trim() -eq '7')
    } catch { return $false }
}

function Find-NwbPowerShell7 {
    $command = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command -and (Test-NwbPowerShell7 -Executable $command.Source)) { return $command.Source }
    # A machine installation may exist even when the runner service PATH is stale.
    if ($env:ProgramFiles) {
        $standardPath = Join-Path $env:ProgramFiles 'PowerShell/7/pwsh.exe'
        if (Test-NwbPowerShell7 -Executable $standardPath) { return $standardPath }
    }
    return $null
}

function Initialize-NwbPowerShell {
    [CmdletBinding()]
    param(
        [string]$RunnerTemp = $env:RUNNER_TEMP,
        [string]$GitHubPathFile = $env:GITHUB_PATH
    )
    $ErrorActionPreference = 'Stop'
    if ($env:RUNNER_OS -ne 'Windows') { throw 'This portable PowerShell setup supports Windows runners only.' }
    if ([string]::IsNullOrWhiteSpace($GitHubPathFile)) { throw 'GITHUB_PATH is required to make PowerShell available to subsequent steps.' }

    $executable = Find-NwbPowerShell7
    if ($executable) {
        Write-Host 'Using PowerShell 7 already available on the runner.'
    } else {
        if ($env:RUNNER_ARCH -ne 'X64') { throw 'Automatic PowerShell download currently supports Windows X64 only. Install PowerShell 7 on this runner.' }
        if ([string]::IsNullOrWhiteSpace($RunnerTemp) -or -not (Test-Path -LiteralPath $RunnerTemp -PathType Container)) {
            throw 'An existing RUNNER_TEMP directory is required for portable PowerShell setup.'
        }
        # Official release asset and SHA-256 verified from the PowerShell release
        # API on 2026-10-26. Change version, URL and checksum together on upgrade.
        $version = '7.6.9'
        $downloadUrl = 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.9/PowerShell-7.6.9-win-x64.zip'
        $expectedHash = 'ce7484804c0f0ad4dda10c958e71acdaf7eebfb22505c1b480f89e0e9f1da94d'
        $tempRoot = (Resolve-Path -LiteralPath $RunnerTemp).ProviderPath
        $stage = Join-Path $tempRoot ('nwb-pwsh-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $stage
        $archive = Join-Path $stage 'powershell.zip'
        $runtime = Join-Path $stage 'runtime'
        Write-Host "PowerShell 7 was not found. Preparing portable PowerShell $version in the runner temporary directory."
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $downloadUrl -OutFile $archive -TimeoutSec 180 -ErrorAction Stop
        } catch {
            throw 'PowerShell download failed. The runner needs approved HTTPS access to GitHub release assets, or PowerShell 7 installed by the runner administrator.'
        }
        $actualHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
        if ($actualHash -ine $expectedHash) { throw 'PowerShell archive SHA-256 mismatch. The downloaded archive will not be extracted or executed.' }
        Expand-Archive -LiteralPath $archive -DestinationPath $runtime -ErrorAction Stop
        $executable = Join-Path $runtime 'pwsh.exe'
        if (-not (Test-NwbPowerShell7 -Executable $executable)) {
            throw 'Portable PowerShell could not start. Check runner OS prerequisites and application-control policy with the runner administrator.'
        }
    }
    # GITHUB_PATH is consumed by the runner before the next step resolves pwsh.
    # UTF-8 without BOM also works when this step runs under Windows PowerShell 5.1.
    $directory = Split-Path -Parent $executable
    [IO.File]::AppendAllText($GitHubPathFile, $directory + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    Write-Host 'PowerShell 7 is ready for subsequent steps in this job.'
}
