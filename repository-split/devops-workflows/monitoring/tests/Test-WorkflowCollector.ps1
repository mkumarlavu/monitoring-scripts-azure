$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../../actions/nwb-cicd-monitoring/scripts/WorkflowRecord.psm1') -Force
$script:passed = 0
function Check($condition, $message) {
    if (-not $condition) { throw "FAILED: $message" }
    $script:passed++
}
function Expect-Failure([scriptblock]$action, [string]$text) {
    try { & $action | Out-Null } catch {
        Check ($_.Exception.Message -like "*$text*") "Expected rejection: $text"
        return
    }
    throw "FAILED: expected rejection $text"
}
$run = [pscustomobject]@{
    id=123; run_attempt=2; status='completed'; conclusion='success'
    repository=[pscustomobject]@{full_name='northwest/doc_extraction'}
    html_url='https://northwest.ghe.com/northwest/doc_extraction/actions/runs/123'
    name='CI'; path='.github/workflows/ci.yml'; head_sha='synthetic-test'
}
$jobs = @(
    [pscustomobject]@{status='completed';conclusion='success';started_at='2026-10-16T10:00:00Z';completed_at='2026-10-16T10:10:00Z'},
    [pscustomobject]@{status='completed';conclusion='success';started_at='2026-10-16T10:01:00Z';completed_at='2026-10-16T10:05:00Z'}
)
$options=@{Run=$run; Jobs=$jobs; Repository='northwest/doc_extraction';Service='test';Environment='ci'}
$record=ConvertTo-WorkflowRecord @options
Check ($record.DurationSeconds -eq 600) 'Parallel jobs use elapsed execution window, not sum of durations'
Check ($record.RunAttempt -eq 2 -and $record.RunId -is [string]) 'Attempt and string run ID are preserved'
Check ($record.DurationSeconds -is [int] -and $record.RunAttempt -is [int]) 'Integer fields match the input stream'
Check ($null -eq $record.QueueSeconds) 'Unknown queue timing stays null'
$run.status='in_progress'
Expect-Failure {ConvertTo-WorkflowRecord @options} 'Only completed'
$run.status='completed';$run.repository.full_name='wrong/repo'
Expect-Failure {ConvertTo-WorkflowRecord @options} 'repository does not match'
$run.repository.full_name='northwest/doc_extraction';$run.html_url='https://wrong.invalid/run'
Expect-Failure {ConvertTo-WorkflowRecord @options} 'Unexpected source run URL'
$run.html_url='https://northwest.ghe.com/northwest/doc_extraction/actions/runs/123'
$jobs[0].completed_at='2026-10-16T09:59:00Z'
Expect-Failure {ConvertTo-WorkflowRecord @options} 'completion precedes'
$jobs[0].completed_at='2026-10-16T10:10:00Z'
$options.Jobs=@()
$empty=ConvertTo-WorkflowRecord @options
Check ($null -eq $empty.DurationSeconds -and $null -eq $empty.CompletedAt) 'No jobs does not invent zero duration'
$options.Jobs=@([pscustomobject]@{status='completed';conclusion='cancelled';started_at=$null;completed_at=$null})
$cancelled=ConvertTo-WorkflowRecord @options
Check ($null -eq $cancelled.DurationSeconds) 'Cancelled before execution keeps timing unknown'
$options.Jobs=@($jobs[0],[pscustomobject]@{status='completed';conclusion='skipped';started_at=$null;completed_at=$null})
Check ((ConvertTo-WorkflowRecord @options).DurationSeconds -eq 600) 'Skipped jobs do not invalidate other job timings'

# Exercise the real orchestration script with offline API and Azure CLI doubles.
# No network or Azure writes occur in these tests.
$envNames=@('GITHUB_TOKEN','GITHUB_REPOSITORY','GITHUB_API_URL','AZURE_DCE_LOGS_ENDPOINT','AZURE_WORKFLOW_DCR_IMMUTABLE_ID','GITHUB_EVENT_NAME','GITHUB_EVENT_PATH')
$original=@{};foreach($name in $envNames){$original[$name]=[Environment]::GetEnvironmentVariable($name)}
$global:NwbOfflineState=@{posts=@();calls=@();mode='ok';run=$run;jobs=$jobs}
function Invoke-RestMethod {
    param($Uri,$Headers,$Method,$TimeoutSec,$MaximumRedirection,$ErrorAction,$Body,$ContentType)
    $global:NwbOfflineState.calls+= $Uri
    if($global:NwbOfflineState.mode -eq 'error'){throw 'sensitive upstream body must not be logged'}
    if($Method -eq 'Post'){$global:NwbOfflineState.posts+= [System.Text.Encoding]::UTF8.GetString($Body);return}
    if($Uri -match '/jobs\?'){
        if($Uri -match '&page=1$'){return [pscustomobject]@{total_count=101;jobs=@(1..100|ForEach-Object {$global:NwbOfflineState.jobs[0]})}}
        return [pscustomobject]@{total_count=101;jobs=@($global:NwbOfflineState.jobs[1])}
    }
    return $global:NwbOfflineState.run
}
function az { $global:LASTEXITCODE=0; 'offline-fake-token' }
$eventFixture=Join-Path $PSScriptRoot ('event-'+[guid]::NewGuid().ToString('N')+'.json')
$mappingFixture=Join-Path $PSScriptRoot ('mapping-'+[guid]::NewGuid().ToString('N')+'.json')
try {
    $env:GITHUB_TOKEN='offline-fake-token';$env:GITHUB_REPOSITORY='northwest/doc_extraction'
    $env:GITHUB_API_URL='https://api.northwest.ghe.com'
    $env:AZURE_DCE_LOGS_ENDPOINT='https://test.eastus2-1.ingest.monitor.azure.com'
    $env:AZURE_WORKFLOW_DCR_IMMUTABLE_ID='dcr-00000000000000000000000000000000'
    $entry=Join-Path $PSScriptRoot '../../actions/nwb-cicd-monitoring/scripts/Send-WorkflowRun.ps1'
    $preview=& $entry -RunId 123 -Service test -Environment ci
    Check ($global:NwbOfflineState.posts.Count -eq 0 -and $global:NwbOfflineState.calls.Count -eq 4) 'Preview reads both job pages and never publishes'
    $previewJson=$preview[-1] | ConvertFrom-Json
    Check ($preview[-1].StartsWith('[') -and $previewJson[0].RunAttempt -eq 2) 'Output is a JSON array with the selected attempt'
    & $entry -RunId 123 -RunAttempt 2 -Service test -Environment ci -Publish | Out-Null
    Check ($global:NwbOfflineState.posts.Count -eq 1 -and $global:NwbOfflineState.posts[0].StartsWith('[')) 'Publish sends an array'
    Check ($global:NwbOfflineState.calls[-1] -like '*/streams/Custom-NWBWorkflowRuns_CL?api-version=2023-01-01') 'Publish targets the correct stream'
    $env:AZURE_DCE_LOGS_ENDPOINT='https://evil.invalid'
    Expect-Failure {& $entry -RunId 123 -Service test -Environment ci -Publish} 'exact Azure public-cloud'
    $global:NwbOfflineState.mode='error'
    Expect-Failure {& $entry -RunId 123 -Service test -Environment ci} 'Request failed (HTTP 0'
    $global:NwbOfflineState.mode='ok';$global:NwbOfflineState.calls=@()
    $global:NwbOfflineState.run.conclusion='failure'
    $event=@{action='completed';repository=@{full_name='northwest/doc_extraction'};workflow_run=@{id=123;run_attempt=2;workflow_id=42;status='completed'}}
    $mapping=@{'42'=@{Service='mapped-service';Environment='ci';IsDeploymentPipeline=$false}}
    $event | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $eventFixture -Encoding UTF8
    $mapping | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $mappingFixture -Encoding UTF8
    $env:GITHUB_EVENT_NAME='workflow_run';$env:GITHUB_EVENT_PATH=$eventFixture
    $eventEntry=Join-Path $PSScriptRoot '../../actions/nwb-cicd-monitoring/scripts/Invoke-WorkflowEvent.ps1'
    $eventResult=& $eventEntry -MappingPath $mappingFixture
    $eventRecord=($eventResult[-1] | ConvertFrom-Json)[0]
    Check ($eventRecord.Conclusion -eq 'failure' -and $eventRecord.Service -eq 'mapped-service') 'Automatic collection includes failed attempts and reviewed service mapping'
    Check ($global:NwbOfflineState.calls.Count -eq 3 -and $global:NwbOfflineState.calls[0] -like '*/attempts/2') 'Automatic collection reads exact event attempt without fetching latest'
    $event.workflow_run.workflow_id=43
    $event | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $eventFixture -Encoding UTF8
    Expect-Failure {& $eventEntry -MappingPath $mappingFixture} 'No reviewed mapping'
    $event.workflow_run.workflow_id=42;$event.repository.full_name='another/repo'
    $event | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $eventFixture -Encoding UTF8
    Expect-Failure {& $eventEntry -MappingPath $mappingFixture} 'Unexpected event repository'
    $event.repository.full_name='northwest/doc_extraction'
    $event | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $eventFixture -Encoding UTF8
    $mapping['42'].IsDeploymentPipeline='false'
    $mapping | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $mappingFixture -Encoding UTF8
    Expect-Failure {& $eventEntry -MappingPath $mappingFixture} 'JSON boolean'
    $env:GITHUB_EVENT_NAME='push'
    Expect-Failure {& $eventEntry -MappingPath $mappingFixture} 'requires a workflow_run'
} finally {
    foreach($name in $envNames){[Environment]::SetEnvironmentVariable($name,$original[$name])}
    foreach($fixture in @($eventFixture,$mappingFixture)){if(Test-Path -LiteralPath $fixture){Remove-Item -LiteralPath $fixture}}
}
Write-Output "Passed $script:passed offline checks. No live GitHub or Azure connection tested."
