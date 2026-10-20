$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$script:passed=0
function Check($condition,$message){if(-not $condition){throw "FAILED: $message"};$script:passed++}
function Reject([scriptblock]$action,[string]$message){
    try{& $action | Out-Null}catch{Check ($_.Exception.Message -like "*$message*") "Expected $message, got $($_.Exception.Message)";return}
    throw "FAILED: expected $message"
}
$root=Join-Path $PSScriptRoot '..'
$scripts=Join-Path $root 'scripts/nwb-observability'
Import-Module (Join-Path $scripts 'PipelineRecord.psm1') -Force
$run=[pscustomobject]@{id=123;run_attempt=2;workflow_id=42;status='completed';conclusion='success';name='App';path='.github/workflows/app.yml';head_sha=('a'*40);html_url='https://northwest.ghe.com/northwest/doc_extraction/actions/runs/123';repository=[pscustomobject]@{full_name='northwest/doc_extraction'}}
$job=[pscustomobject]@{id=501;run_id=123;run_attempt=2;name='build (windows)';status='completed';conclusion='success';started_at='2026-10-20T10:00:00Z';completed_at='2026-10-20T10:01:00Z';runner_name='runner';runner_group_name='Default';steps=@(
    [pscustomobject]@{number=1;name='Compile';status='completed';conclusion='success';started_at='2026-10-20T10:00:00Z';completed_at='2026-10-20T10:00:30Z'},
    [pscustomobject]@{number=2;name='Scan';status='completed';conclusion='failure';started_at='2026-10-20T10:00:30Z';completed_at='2026-10-20T10:01:00Z'},
    [pscustomobject]@{number=3;name='Optional';status='completed';conclusion='skipped';started_at=$null;completed_at=$null}
)}
$mapping=[pscustomobject]@{'42'=@([pscustomobject]@{JobName='build (windows)';Stage='Build'},[pscustomobject]@{JobName='build (windows)';StepName='Scan';Stage='Security'})}
$options=@{Run=$run;Jobs=@($job);Service='doc-extraction';Environment='development';StageMappings=$mapping}
$records=@(ConvertTo-PipelineRecords @options)
Check ($records.Count -eq 4) 'One job and three step rows'
Check ($records[0].DurationSeconds -eq 60 -and $records[1].DurationSeconds -eq 30) 'Job and step durations are independent'
Check ($records[2].Stage -eq 'Security' -and $records[1].Stage -eq 'Build') 'Step override takes priority over exact job mapping'
Check ($records[2].Conclusion -eq 'failure' -and $records[0].Conclusion -eq 'success') 'Continue-on-error step conclusion is preserved without changing job result'
Check ($null -eq $records[3].DurationSeconds) 'Skipped execution duration stays unknown'
$unmapped=@(ConvertTo-PipelineRecords -Run $run -Jobs @($job) -Service test -Environment unknown)
Check (-not $unmapped[0].StageMappingKnown -and $unmapped[0].Stage -eq 'unmapped') 'Missing stage mapping is explicit'
$job.run_attempt=1;Reject {ConvertTo-PipelineRecords @options} 'different run/attempt';$job.run_attempt=2
$options.Jobs=@($job,$job);Reject {ConvertTo-PipelineRecords @options} 'duplicate job ID';$options.Jobs=@($job)
$job.steps[2].number=2;Reject {ConvertTo-PipelineRecords @options} 'duplicate step number';$job.steps[2].number=3
$job.steps[0].completed_at='2026-10-20T09:00:00Z';Reject {ConvertTo-PipelineRecords @options} 'precedes start';$job.steps[0].completed_at='2026-10-20T10:00:30Z'
$job.steps[0].status='in_progress';Reject {ConvertTo-PipelineRecords @options} 'Incomplete';$job.steps[0].status='completed'
$job.steps[0].completed_at=$null
Check ($null -eq @(ConvertTo-PipelineRecords @options)[1].DurationSeconds) 'Incomplete timing is not converted to zero'
$job.steps[0].completed_at='2026-10-20T10:00:30Z'
$second=$job | ConvertTo-Json -Depth 8 | ConvertFrom-Json;$second.id=502
$matrix=@(ConvertTo-PipelineRecords -Run $run -Jobs @($job,$second) -Service test -Environment dev)
Check (@($matrix | Where-Object RecordType -eq Job).Count -eq 2) 'Matrix jobs retain distinct IDs even with identical names'
$schemas=Get-Content (Join-Path $root 'infra/record-schemas.json') -Raw | ConvertFrom-Json
Check ((($records[0].PSObject.Properties.Name | Sort-Object) -join ',') -eq (($schemas.NWBPipelineExecution_CL.PSObject.Properties.Name | Sort-Object) -join ',')) 'Pipeline payload matches declared schema columns'

$global:NwbExecutionTest=@{posts=@();calls=@();jobs=@($job);run=$run;mode='ok';healthRuns=@()}
function Invoke-RestMethod {
    param($Uri,$Headers,$Method,$TimeoutSec,$MaximumRedirection,$ErrorAction,$Body,$ContentType)
    $state=$global:NwbExecutionTest;$state.calls+=$Uri
    if($Method -eq 'Post'){
        if($state.mode -eq 'execution-error' -and $Uri -like '*NWBPipelineExecution_CL*'){throw 'secret error body'}
        $state.posts+=[pscustomobject]@{Uri=$Uri;Data=([Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json)};return
    }
    if($Uri -like '*/actions/workflows/*/runs?*'){return [pscustomobject]@{total_count=$state.healthRuns.Count;workflow_runs=$state.healthRuns}}
    if($Uri -like '*/jobs?*'){
        if($state.mode -eq 'pagination'){
            if($Uri -like '*page=1'){return [pscustomobject]@{total_count=2;jobs=@($job)}}
            return [pscustomobject]@{total_count=2;jobs=@($second)}
        }
        if($state.mode -eq 'incomplete'){return [pscustomobject]@{total_count=1;jobs=@()}}
        return [pscustomobject]@{total_count=$state.jobs.Count;jobs=$state.jobs}
    }
    if($Uri -like '*/deployments?*'){return @()}
    if($Uri -match '/actions/runs/123/attempts/2$'){return $state.run}
    throw "Unexpected offline request: $Uri"
}
function az {$global:LASTEXITCODE=0;'offline-token'}
$names=@('GITHUB_TOKEN','GITHUB_REPOSITORY','GITHUB_API_URL','GITHUB_EVENT_NAME','AZURE_DCE_LOGS_ENDPOINT','AZURE_WORKFLOW_DCR_IMMUTABLE_ID','AZURE_DEPLOYMENT_DCR_IMMUTABLE_ID','AZURE_EXECUTION_DCR_IMMUTABLE_ID','AZURE_HEALTH_DCR_IMMUTABLE_ID')
$saved=@{};foreach($name in $names){$saved[$name]=[Environment]::GetEnvironmentVariable($name)}
try{
    $env:GITHUB_TOKEN='offline-token';$env:GITHUB_REPOSITORY='northwest/doc_extraction';$env:GITHUB_API_URL='https://api.northwest.ghe.com';$env:GITHUB_EVENT_NAME='workflow_dispatch'
    $env:AZURE_DCE_LOGS_ENDPOINT='https://test.eastus2-1.ingest.monitor.azure.com'
    foreach($name in @('AZURE_WORKFLOW_DCR_IMMUTABLE_ID','AZURE_DEPLOYMENT_DCR_IMMUTABLE_ID','AZURE_EXECUTION_DCR_IMMUTABLE_ID','AZURE_HEALTH_DCR_IMMUTABLE_ID')){[Environment]::SetEnvironmentVariable($name,'dcr-00000000000000000000000000000000')}
    $entry=Join-Path $scripts 'Send-PipelineExecution.ps1'
    & $entry -Run $run -Service test -Environment dev | Out-Null
    Check ($global:NwbExecutionTest.posts.Count -eq 0) 'Job/step preview does not publish'
    $global:NwbExecutionTest.mode='pagination'
    & $entry -Run $run -Service test -Environment dev -Publish | Out-Null
    Check ($global:NwbExecutionTest.posts.Count -eq 8 -and @($global:NwbExecutionTest.calls | Where-Object {$_ -like '*page=2'}).Count -eq 1) 'Job pagination publishes both pages'
    Check ($global:NwbExecutionTest.posts[0].Uri -like '*streams/Custom-NWBPipelineExecution_CL?*') 'Job/step records use execution stream'
    $global:NwbExecutionTest.mode='incomplete';Reject {& $entry -Run $run -Service test -Environment dev} 'Incomplete job pagination'
    $global:NwbExecutionTest.mode='ok';$global:NwbExecutionTest.posts=@()
    & (Join-Path $scripts 'Invoke-CicdCollection.ps1') -RunId 123 -RunAttempt 2 -ConfigPath (Join-Path $root 'config/nwb-observability/collector.json') -Publish -WarningAction SilentlyContinue | Out-Null
    Check ($global:NwbExecutionTest.posts.Count -eq 6) 'Integrated collector writes workflow, job/steps and collection health'
    $last=$global:NwbExecutionTest.posts[-1].Data[0]
    Check ($last.Operation -eq 'collection' -and $last.Outcome -eq 'success') 'Collection health reports component success'
    Check ((($last.PSObject.Properties.Name | Sort-Object) -join ',') -eq (($schemas.NWBCollectorHealth_CL.PSObject.Properties.Name | Sort-Object) -join ',')) 'Health payload matches declared schema columns'
    $global:NwbExecutionTest.mode='execution-error';$global:NwbExecutionTest.posts=@()
    Reject {& (Join-Path $scripts 'Invoke-CicdCollection.ps1') -RunId 123 -RunAttempt 2 -ConfigPath (Join-Path $root 'config/nwb-observability/collector.json') -Publish -WarningAction SilentlyContinue} 'Pipeline execution: Request failed'
    Check ($global:NwbExecutionTest.posts[-1].Data[0].Outcome -eq 'failure' -and $global:NwbExecutionTest.posts[-1].Data[0].DetailCode -eq 'execution') 'Partial ingestion failure still publishes failure health without error body'
    $global:NwbExecutionTest.mode='ok';$global:NwbExecutionTest.posts=@()
    $watchdog=Join-Path $scripts 'Invoke-CollectorHealth.ps1'
    & $watchdog | Out-Null
    Check ($global:NwbExecutionTest.posts.Count -eq 0) 'Watchdog preview does not publish'
    & $watchdog -Publish | Out-Null
    Check ($global:NwbExecutionTest.posts.Count -eq 1 -and $global:NwbExecutionTest.posts[0].Data[0].Operation -eq 'heartbeat') 'Quiet repository still gets watchdog heartbeat'
    $failed=[pscustomobject]@{id=999;run_attempt=1;repository=$run.repository;updated_at=[datetimeoffset]::UtcNow.ToString('o');conclusion='failure'}
    $skipped=[pscustomobject]@{id=998;run_attempt=1;repository=$run.repository;updated_at=[datetimeoffset]::UtcNow.ToString('o');conclusion='skipped'}
    $global:NwbExecutionTest.healthRuns=@($failed,$skipped);$global:NwbExecutionTest.posts=@()
    & $watchdog -Publish | Out-Null
    Check ($global:NwbExecutionTest.posts.Count -eq 2 -and $global:NwbExecutionTest.posts[0].Data[0].SourceRunId -eq '999') 'Watchdog catches failed collector runs and excludes skipped trigger runs'
    Check ($global:NwbExecutionTest.posts[-1].Data[0].Operation -eq 'heartbeat') 'Heartbeat publishes last'
    $env:GITHUB_API_URL='https://untrusted.invalid';Reject {& $watchdog} 'Unexpected GitHub API host'
}finally{foreach($name in $names){[Environment]::SetEnvironmentVariable($name,$saved[$name])}}
Write-Output "Passed $script:passed pipeline/health offline checks. No live API requests."
