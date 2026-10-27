# Runs under Windows PowerShell 5.1 before the composite action's pwsh step.
# Finds an administrator-installed runtime. Never downloads or installs software.
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
        [string]$GitHubPathFile = $env:GITHUB_PATH
    )
    $ErrorActionPreference = 'Stop'
    if ($env:RUNNER_OS -ne 'Windows') { throw 'This PowerShell availability check supports Windows runners only.' }
    if ([string]::IsNullOrWhiteSpace($GitHubPathFile)) { throw 'GITHUB_PATH is required to make PowerShell available to subsequent steps.' }

    $executable = Find-NwbPowerShell7
    if (-not $executable) {
        throw 'PowerShell 7 was not found or could not start. Ask the runner administrator to check the installed runtime and the runner service PATH. Automatic installation is disabled.'
    }
    Write-Host 'Using PowerShell 7 already available on the runner.'
    # GITHUB_PATH is consumed by the runner before the next step resolves pwsh.
    # UTF-8 without BOM also works when this step runs under Windows PowerShell 5.1.
    $directory = Split-Path -Parent $executable
    [IO.File]::AppendAllText($GitHubPathFile, $directory + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    Write-Host 'PowerShell 7 is ready for subsequent steps in this job.'
}
