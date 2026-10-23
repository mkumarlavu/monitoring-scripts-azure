[CmdletBinding()]
param([Parameter(Mandatory)]$Run,[Parameter(Mandatory)][string]$Service,
    [Parameter(Mandatory)][string]$Environment,$StageMappings=[pscustomobject]@{},[switch]$Publish)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'NwbTransport.ps1')
Import-Module (Join-Path $PSScriptRoot 'PipelineRecord.psm1') -Force
$context=Get-NwbGitHubContext
if($Run.repository.full_name -cne $context.Repository){throw 'Source run repository does not match the caller.'}
if([string]$Run.id -notmatch '^[1-9][0-9]*$' -or [int]$Run.run_attempt -lt 1){throw 'Invalid run/attempt ID.'}
$jobs=@();$total=$null
for($page=1;$page -le 100;$page++){
    $uri="$($context.Base)/actions/runs/$($Run.id)/attempts/$($Run.run_attempt)/jobs?per_page=100&page=$page"
    $result=Invoke-SafeRequest -Uri $uri -Headers $context.Headers
    if($null -eq $total){$total=[int]$result.total_count}
    if($total -ne [int]$result.total_count){throw 'Job list changed during pagination.'}
    $batch=@($result.jobs);$jobs+=$batch
    if($jobs.Count -eq $total){break}
    if($batch.Count -eq 0 -or $jobs.Count -gt $total){throw 'Incomplete job pagination.'}
}
if($jobs.Count -ne $total){throw 'Job pagination limit reached.'}
$records=@(ConvertTo-PipelineRecords -Run $Run -Jobs $jobs -Service $Service -Environment $Environment -StageMappings $StageMappings)
if($records.Count -eq 0){Write-Output 'No executed job/step records available for this attempt.';return}
if($Publish){
    Send-NwbRecords -Records $records -DcrId $env:AZURE_EXECUTION_DCR_IMMUTABLE_ID -Table NWBPipelineExecution_CL
    Write-Output "Azure accepted $($records.Count) job/step observations."
}else{Write-Output 'Pipeline execution preview only.';ConvertTo-Json -InputObject @($records) -Depth 8 -Compress}
