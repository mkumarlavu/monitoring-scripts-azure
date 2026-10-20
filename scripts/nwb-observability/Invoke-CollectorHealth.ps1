[CmdletBinding()]
param([switch]$Publish)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'NwbTransport.ps1')
. (Join-Path $PSScriptRoot 'CollectorHealth.ps1')
$context=Get-NwbGitHubContext
$records=@();$runs=@();$total=$null
$workflow=[uri]::EscapeDataString('nwb-cicd-collector.yml')
# Watch completed collector runs, including login failures that occur before its scripts.
for($page=1;$page -le 100;$page++){
    $result=Invoke-SafeRequest -Uri "$($context.Base)/actions/workflows/$workflow/runs?status=completed&per_page=100&page=$page" -Headers $context.Headers
    $batch=@($result.workflow_runs)
    $runs += $batch
    if($null -eq $total){$total=[int]$result.total_count}
    if($runs.Count -ge $total){break}
    if($batch.Count -lt 100){throw 'Collector health history is truncated; no heartbeat will be published.'}
    # Do not stop on old creation dates: an old run can have a recent rerun.
    # This is bounded health observation, not application reconciliation/backfill.
    if($page -eq 100){throw 'Collector health history pagination limit reached.'}
}
foreach($run in $runs){
    if([datetimeoffset]$run.updated_at -lt [datetimeoffset]::UtcNow.AddHours(-2) -or $run.conclusion -eq 'skipped'){continue}
    if([string]$run.id -notmatch '^[1-9][0-9]*$' -or $run.repository.full_name -cne 'northwest/doc_extraction'){throw 'Unexpected collector run identity.'}
    $outcome='failure';if($run.conclusion -eq 'success'){$outcome='success'}
    $records+=New-NwbHealthRecord -Operation collector-run -Outcome $outcome -SourceRunId ([string]$run.id) -SourceRunAttempt ([int]$run.run_attempt) -SourceUpdatedAt ([datetimeoffset]$run.updated_at) -DetailCode ([string]$run.conclusion)
}
# Publish heartbeat last. It proves this watchdog reached GitHub and the health stream;
# it does not assert completeness of application telemetry or availability of other DCRs.
$records+=New-NwbHealthRecord -Operation heartbeat -Outcome success -DetailCode 'github-read-and-health-stream'
if($Publish){
    Send-NwbRecords -Records $records -DcrId $env:AZURE_HEALTH_DCR_IMMUTABLE_ID -Table NWBCollectorHealth_CL
    Write-Output "Azure accepted $($records.Count) health observations."
}else{Write-Output 'Health preview only.';ConvertTo-Json -InputObject @($records) -Depth 6 -Compress}
