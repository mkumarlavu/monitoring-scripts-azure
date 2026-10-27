$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$script:passed=0
function Check($condition,$message){if(-not $condition){throw "FAILED: $message"};$script:passed++}
function Reject([scriptblock]$Action,[string]$Message){
    try{& $Action | Out-Null}catch{Check ($_.Exception.Message -like "*$Message*") "Expected $Message, got $($_.Exception.Message)";return}
    throw "FAILED: expected $Message"
}
. (Join-Path $PSScriptRoot '../../actions/nwb-cicd-monitoring/scripts/Initialize-PowerShell.ps1')
$pathFile=Join-Path $PSScriptRoot ('runtime-path-'+[guid]::NewGuid().ToString('N')+'.txt')
$savedOs=$env:RUNNER_OS
$script:existing=Join-Path $PSScriptRoot 'installed runtime/pwsh.exe'
$script:downloads=0
function Find-NwbPowerShell7 { return $script:existing }
function Invoke-WebRequest { $script:downloads++;throw 'Unexpected download' }
try {
    $env:RUNNER_OS='Windows'
    Initialize-NwbPowerShell -GitHubPathFile $pathFile
    Check (([IO.File]::ReadAllText($pathFile)).Trim() -eq (Split-Path $script:existing)) 'Installed runtime path with spaces is exported'
    $bytes=[IO.File]::ReadAllBytes($pathFile)
    Check (-not ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)) 'GITHUB_PATH uses UTF-8 without BOM'
    [IO.File]::WriteAllText($pathFile,'')
    $script:existing=$null
    Reject {Initialize-NwbPowerShell -GitHubPathFile $pathFile} 'Automatic installation is disabled'
    Check ([IO.File]::ReadAllText($pathFile) -eq '') 'Missing runtime does not change PATH'
    Check ($script:downloads -eq 0) 'No download when runtime is available or missing'
    Reject {Initialize-NwbPowerShell -GitHubPathFile ''} 'GITHUB_PATH is required'
    $env:RUNNER_OS='Linux'
    Reject {Initialize-NwbPowerShell -GitHubPathFile $pathFile} 'Windows runners only'
} finally {
    $env:RUNNER_OS=$savedOs
    if(Test-Path -LiteralPath $pathFile){Remove-Item -LiteralPath $pathFile -Force}
}
Write-Output "Passed $script:passed installed-runtime checks. Runtime discovery was mocked; no software was installed."
