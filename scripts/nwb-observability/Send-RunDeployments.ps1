[CmdletBinding()]
param([Parameter(Mandatory)]$Run, [Parameter(Mandatory)]$EnvironmentMappings,
    [bool]$ExpectDeployment=$false, [switch]$Publish)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'NwbTransport.ps1')
Import-Module (Join-Path $PSScriptRoot 'DeploymentRecord.psm1') -Force
$context=Get-NwbGitHubContext
if ($Run.status -ne 'completed' -or $Run.repository.full_name -cne $env:GITHUB_REPOSITORY -or
    [string]$Run.id -notmatch '^[1-9][0-9]*$' -or [string]$Run.head_sha -notmatch '^[0-9a-fA-F]{40,64}$') { throw 'Invalid completed source run.' }
$sha=[uri]::EscapeDataString([string]$Run.head_sha)
$deployments=Get-NwbArrayPages -Uri "$($context.Base)/deployments?sha=$sha" -Headers $context.Headers
$records=@()
$runUrl='https://northwest.ghe.com/northwest/doc_extraction/actions/runs/' + [string]$Run.id
$pattern='^'+[regex]::Escape($runUrl)+'(/job/[0-9]+|/attempts/[0-9]+)?/?$'
foreach ($deployment in $deployments) {
    if ([string]$deployment.id -notmatch '^[1-9][0-9]*$') { throw 'Invalid deployment ID returned by GitHub.' }
    if ($deployment.environment -ceq 'cicd-observability') { continue }
    $statuses=Get-NwbArrayPages -Uri "$($context.Base)/deployments/$($deployment.id)/statuses" -Headers $context.Headers
    # Retain the earliest success even when a later release marked this deployment inactive.
    # Match the status to the run, not just the SHA: multiple runs can deploy the same commit.
    $success=@($statuses | Where-Object { $_.state -eq 'success' -and [string]$_.log_url -cmatch $pattern } |
        Sort-Object { [datetimeoffset]$_.created_at })
    if ($success.Count -eq 0) { continue }
    $mappingProperty=@($EnvironmentMappings.PSObject.Properties | Where-Object { $_.Name -ceq [string]$deployment.environment })
    if ($mappingProperty.Count -ne 1) { throw "Deployment $($deployment.id) has no reviewed environment mapping. Workflow record can still be stored; replay after configuring the mapping." }
    $records += ConvertTo-DeploymentRecord -Deployment $deployment -SuccessStatus $success[0] -Run $Run -Mapping $mappingProperty[0].Value
}
if ($records.Count -eq 0) {
    if ($ExpectDeployment -and $Run.conclusion -eq 'success') { throw 'Successful deployment pipeline has no linked successful deployment evidence. Check GitHub environment reporting and replay.' }
    Write-Output 'No confirmed deployment linked to this run. No deployment fact fabricated.'
    return
}
if ($Publish) {
    Send-NwbRecords -Records $records -DcrId $env:AZURE_DEPLOYMENT_DCR_IMMUTABLE_ID -Table NWBDeploymentFacts_CL
    Write-Output "Azure accepted $($records.Count) deployment observation(s). Verify storage in Log Analytics."
} else {
    Write-Output 'Deployment preview only. No Azure records sent.'
    ConvertTo-Json -InputObject @($records) -Depth 8 -Compress
}
