$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$script:passed=0
function Check($condition,$message){if(-not $condition){throw "FAILED: $message"};$script:passed++}
function Reject([scriptblock]$Action,[string]$Message){
    try{& $Action | Out-Null}catch{Check ($_.Exception.Message -like "*$Message*") "Expected $Message, got $($_.Exception.Message)";return}
    throw "FAILED: expected $Message"
}
$bootstrap=Join-Path $PSScriptRoot '../../actions/nwb-cicd-monitoring/scripts/Initialize-PowerShell.ps1'
. $bootstrap
$testRoot=Join-Path $PSScriptRoot ('bootstrap-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $testRoot
$pathFile=Join-Path $testRoot 'github-path.txt'
$savedOs=$env:RUNNER_OS;$savedArch=$env:RUNNER_ARCH
$script:fixture=@{existing=$null;downloads=0;expansions=0;mode='ok';uri='';hash='ce7484804c0f0ad4dda10c958e71acdaf7eebfb22505c1b480f89e0e9f1da94d'}
# These doubles prevent every download, extraction and native runtime execution.
function Find-NwbPowerShell7 { return $script:fixture.existing }
function Test-NwbPowerShell7 {param($Executable) return ($script:fixture.mode -ne 'launch-error')}
function Invoke-WebRequest {
    param([switch]$UseBasicParsing,$Uri,$OutFile,$TimeoutSec,$ErrorAction)
    $script:fixture.downloads++;$script:fixture.uri=$Uri
    if($script:fixture.mode -eq 'network-error'){throw 'Simulated blocked download'}
    [IO.File]::WriteAllText($OutFile,'offline archive placeholder')
}
function Get-FileHash {param($LiteralPath,$Algorithm) return [pscustomobject]@{Hash=$script:fixture.hash}}
function Expand-Archive {
    param($LiteralPath,$DestinationPath,$ErrorAction)
    $script:fixture.expansions++
    $null=New-Item -ItemType Directory -Path $DestinationPath
    [IO.File]::WriteAllText((Join-Path $DestinationPath 'pwsh.exe'),'offline executable placeholder')
}
try {
    $env:RUNNER_OS='Windows';$env:RUNNER_ARCH='X64'
    $script:fixture.existing=Join-Path $testRoot 'installed/pwsh.exe'
    Initialize-NwbPowerShell -RunnerTemp $testRoot -GitHubPathFile $pathFile
    Check ($script:fixture.downloads -eq 0 -and $script:fixture.expansions -eq 0) 'Existing runtime is used without network or extraction'
    Check (([IO.File]::ReadAllText($pathFile)).Trim() -eq (Split-Path $script:fixture.existing)) 'Existing runtime is exported to the next step PATH'
    $script:fixture.existing=$null
    [IO.File]::WriteAllText($pathFile,'')
    Initialize-NwbPowerShell -RunnerTemp $testRoot -GitHubPathFile $pathFile
    Check ($script:fixture.downloads -eq 1 -and $script:fixture.expansions -eq 1) 'Missing runtime downloads and extracts once'
    Check ($script:fixture.uri -ceq 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.9/PowerShell-7.6.9-win-x64.zip') 'Download uses the reviewed official release asset'
    $runtimePath=([IO.File]::ReadAllText($pathFile)).Trim()
    Check ($runtimePath.StartsWith($testRoot+[IO.Path]::DirectorySeparatorChar) -and (Test-Path -LiteralPath (Join-Path $runtimePath 'pwsh.exe'))) 'Portable installation stays under the job temp directory'
    $bytes=[IO.File]::ReadAllBytes($pathFile)
    Check (-not ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)) 'GITHUB_PATH uses UTF-8 without a BOM'

    [IO.File]::WriteAllText($pathFile,'')
    $script:fixture.hash='0'*64
    Reject {Initialize-NwbPowerShell -RunnerTemp $testRoot -GitHubPathFile $pathFile} 'SHA-256 mismatch'
    Check ($script:fixture.expansions -eq 1 -and [IO.File]::ReadAllText($pathFile) -eq '') 'Hash mismatch never extracts or enables the downloaded runtime'
    $script:fixture.hash='ce7484804c0f0ad4dda10c958e71acdaf7eebfb22505c1b480f89e0e9f1da94d'
    $script:fixture.mode='network-error'
    Reject {Initialize-NwbPowerShell -RunnerTemp $testRoot -GitHubPathFile $pathFile} 'approved HTTPS access'
    Check ($script:fixture.expansions -eq 1) 'Blocked download never reaches extraction'
    $script:fixture.mode='launch-error'
    Reject {Initialize-NwbPowerShell -RunnerTemp $testRoot -GitHubPathFile $pathFile} 'could not start'
    Check ([IO.File]::ReadAllText($pathFile) -eq '') 'A runtime that cannot start is not added to PATH'
    $env:RUNNER_ARCH='ARM64'
    Reject {Initialize-NwbPowerShell -RunnerTemp $testRoot -GitHubPathFile $pathFile} 'Windows X64 only'
    $env:RUNNER_OS='Linux'
    Reject {Initialize-NwbPowerShell -RunnerTemp $testRoot -GitHubPathFile $pathFile} 'Windows runners only'
    $env:RUNNER_OS='Windows';$env:RUNNER_ARCH='X64'
    Reject {Initialize-NwbPowerShell -RunnerTemp $testRoot -GitHubPathFile ''} 'GITHUB_PATH is required'
} finally {
    $env:RUNNER_OS=$savedOs;$env:RUNNER_ARCH=$savedArch
    # Only remove this test's unique directory beneath the tests directory.
    $resolved=[IO.Path]::GetFullPath($testRoot)
    $allowed=[IO.Path]::GetFullPath($PSScriptRoot)+[IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike 'bootstrap-*') {
        throw 'Unexpected test cleanup path'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Output "Passed $script:passed PowerShell bootstrap checks. Downloads and executable launch were mocked."
