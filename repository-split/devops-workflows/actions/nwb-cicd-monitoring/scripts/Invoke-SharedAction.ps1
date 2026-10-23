[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('collect','health')][string]$Operation,
    [string]$RunId,
    [ValidateRange(0,2147483647)][int]$RunAttempt=0,
    [string]$ConfigPath,
    [switch]$Publish,
    [switch]$ShowIdentity
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'NwbTransport.ps1')
$null=Get-NwbGitHubContext
if($ShowIdentity){ & (Join-Path $PSScriptRoot 'Show-OidcClaims.ps1') }
if($Operation -eq 'health'){
    & (Join-Path $PSScriptRoot 'Invoke-CollectorHealth.ps1') -Publish:$Publish
}else{
    if(-not $ConfigPath -or -not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)){
        throw 'Caller collector.json was not found at the checked-out configuration path.'
    }
    & (Join-Path $PSScriptRoot 'Invoke-CicdCollection.ps1') -RunId $RunId -RunAttempt $RunAttempt -ConfigPath $ConfigPath -Publish:$Publish
}
