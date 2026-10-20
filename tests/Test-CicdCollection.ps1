$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$script:passed=0
function Check($condition,$message) { if (-not $condition) { throw "FAILED: $message" }; $script:passed++ }
function Reject([scriptblock]$action,[string]$message) {
    try { & $action | Out-Null } catch { Check ($_.Exception.Message -like "*$message*") "Expected $message; got $($_.Exception.Message)"; return }
    throw "FAILED: expected $message"
}
$root=Join-Path $PSScriptRoot '..'
Import-Module (Join-Path $root 'scripts/nwb-observability/DeploymentRecord.psm1') -Force
$run=[pscustomobject]@{id=123;run_attempt=2;workflow_id=42;status='completed';conclusion='success';name='Application release';path='.github/workflows/app.yml';head_sha=('a'*40);html_url='https://northwest.ghe.com/northwest/doc_extraction/actions/runs/123';repository=[pscustomobject]@{full_name='northwest/doc_extraction'}}
$deployment=[pscustomobject]@{id=8;sha=('a'*40);environment='dev';production_environment=$false;created_at='2026-10-16T10:00:00Z'}
$success=[pscustomobject]@{id=81;state='success';log_url=($run.html_url+'/job/5');created_at='2026-10-16T10:10:00Z'}
$map=[pscustomobject]@{Service='doc-extraction';Environment='development';Production=$false;SuccessMeansDeployed=$true}
$options=@{Deployment=$deployment;SuccessStatus=$success;Run=$run;Mapping=$map}
$record=ConvertTo-DeploymentRecord @options
Check ($record.DeploymentId -eq 'northwest/doc_extraction:github-deployment:8') 'Stable deployment identity'
Check (-not $record.ReachedProduction -and -not $record.ClassificationKnown -and -not $record.ReworkClassificationKnown) 'No invented production/failure/rework classification'
Check ($record.RevisionName -eq '' -and $record.ImageDigest -eq '') 'No fabricated Container Apps revision or ACR digest'
$success.state='failure';Reject {ConvertTo-DeploymentRecord @options} 'Only confirmed';$success.state='success'
$success.log_url=$run.html_url+'4';Reject {ConvertTo-DeploymentRecord @options} 'does not link';$success.log_url=$run.html_url+'/job/5'
$deployment.sha='b'*40;Reject {ConvertTo-DeploymentRecord @options} 'does not match';$deployment.sha='a'*40
$map.Production=$true;Reject {ConvertTo-DeploymentRecord @options} 'production flag';$map.Production=$false
$map.SuccessMeansDeployed=$false;Reject {ConvertTo-DeploymentRecord @options} 'reviewed';$map.SuccessMeansDeployed=$true
$success.created_at='2026-10-16T09:00:00Z';Reject {ConvertTo-DeploymentRecord @options} 'timestamp';$success.created_at='2026-10-16T10:10:00Z'

$global:NwbCicdTest=@{run=$run;deployments=@($deployment);statuses=@($success);calls=@();posts=@();mode='ok';retry=0}
function Invoke-RestMethod {
    param($Uri,$Headers,$Method,$TimeoutSec,$MaximumRedirection,$ErrorAction,$Body,$ContentType)
    $state=$global:NwbCicdTest
    $state.calls+= $Uri
    if ($Method -eq 'Post') {
        if ($state.mode -eq 'workflow-post-error' -and $Uri -like '*Custom-NWBWorkflowRuns_CL*') { throw 'secret response body' }
        if ($state.mode -eq 'rate-limit' -and $state.retry -lt 2) {
            $state.retry++
            $exception=New-Object System.Exception 'do not print bearer token'
            $exception | Add-Member NoteProperty Response ([pscustomobject]@{StatusCode=429})
            throw $exception
        }
        $state.posts+= [pscustomobject]@{Uri=$Uri;Body=[System.Text.Encoding]::UTF8.GetString($Body)}
        return
    }
    if ($Uri -match '/deployments\?') {
        if ($state.mode -eq 'deployment-pages' -and $Uri -match '&page=1$') {
            return @(1..100 | ForEach-Object { [pscustomobject]@{id=(1000+$_);environment='cicd-observability'} })
        }
        return $state.deployments
    }
    if ($Uri -match '/deployments/8/statuses\?') { return $state.statuses }
    if ($Uri -match '/jobs\?') { return [pscustomobject]@{total_count=1;jobs=@([pscustomobject]@{status='completed';conclusion='success';started_at='2026-10-16T10:00:00Z';completed_at='2026-10-16T10:10:00Z'})} }
    if ($Uri -match '/actions/runs/123(/attempts/2)?$') { return $state.run }
    throw "Unexpected offline request: $Uri"
}
function az { $global:LASTEXITCODE=0; 'offline-token' }
function Start-Sleep { param($Seconds) }
$envNames=@('GITHUB_TOKEN','GITHUB_REPOSITORY','GITHUB_API_URL','GITHUB_EVENT_NAME','GITHUB_EVENT_PATH','AZURE_DCE_LOGS_ENDPOINT','AZURE_WORKFLOW_DCR_IMMUTABLE_ID','AZURE_DEPLOYMENT_DCR_IMMUTABLE_ID')
$saved=@{};foreach($name in $envNames){$saved[$name]=[Environment]::GetEnvironmentVariable($name)}
$configFile=Join-Path $PSScriptRoot ('config-'+[guid]::NewGuid().ToString('N')+'.json')
$eventFile=Join-Path $PSScriptRoot ('event-'+[guid]::NewGuid().ToString('N')+'.json')
$entry=Join-Path $root 'scripts/nwb-observability/Invoke-CicdCollection.ps1'
$config=@{DefaultService='doc-extraction';WorkflowMappings=@{'42'=@{Service='doc-extraction';Environment='mixed';IsDeploymentPipeline=$true}};DeploymentEnvironments=@{dev=$map}}
try {
    $env:GITHUB_TOKEN='offline-token';$env:GITHUB_REPOSITORY='northwest/doc_extraction';$env:GITHUB_API_URL='https://api.northwest.ghe.com'
    $env:GITHUB_EVENT_NAME='workflow_dispatch'
    $env:AZURE_DCE_LOGS_ENDPOINT='https://test.eastus2-1.ingest.monitor.azure.com'
    $env:AZURE_WORKFLOW_DCR_IMMUTABLE_ID='dcr-00000000000000000000000000000000'
    $env:AZURE_DEPLOYMENT_DCR_IMMUTABLE_ID='dcr-11111111111111111111111111111111'
    $config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configFile -Encoding UTF8
    $result=& $entry -RunId 123 -RunAttempt 2 -ConfigPath $configFile
    Check ($global:NwbCicdTest.posts.Count -eq 0 -and @($result | Where-Object { $_ -like '[[]*' }).Count -eq 2) 'Preview both tables without Azure writes'
    & $entry -RunId 123 -RunAttempt 2 -ConfigPath $configFile -Publish | Out-Null
    Check ($global:NwbCicdTest.posts.Count -eq 2) 'Publish workflow and deployment independently'
    Check ($global:NwbCicdTest.posts[1].Uri -like '*dcr-11111111111111111111111111111111/streams/Custom-NWBDeploymentFacts_CL*') 'Deployment uses its own DCR/stream'
    Check ($global:NwbCicdTest.posts[1].Body.StartsWith('[')) 'Azure deployment body is an array'
    $originalId=($global:NwbCicdTest.posts[1].Body | ConvertFrom-Json)[0].DeploymentId
    & $entry -RunId 123 -RunAttempt 2 -ConfigPath $configFile -Publish | Out-Null
    Check (($global:NwbCicdTest.posts[3].Body | ConvertFrom-Json)[0].DeploymentId -eq $originalId) 'Replay preserves deployment deduplication key'
    $global:NwbCicdTest.mode='deployment-pages';$global:NwbCicdTest.calls=@()
    & $entry -RunId 123 -RunAttempt 2 -ConfigPath $configFile | Out-Null
    Check (@($global:NwbCicdTest.calls | Where-Object { $_ -like '*/deployments?*&page=2' }).Count -eq 1) 'Deployment list pagination reaches second page'
    $global:NwbCicdTest.mode='ok'
    $env:AZURE_DCE_LOGS_ENDPOINT='https://untrusted.invalid';$global:NwbCicdTest.posts=@()
    Reject {& $entry -RunId 123 -RunAttempt 2 -ConfigPath $configFile -Publish} 'exact Azure public-cloud'
    Check ($global:NwbCicdTest.posts.Count -eq 0) 'Invalid ingestion destination receives no writes'
    $env:AZURE_DCE_LOGS_ENDPOINT='https://test.eastus2-1.ingest.monitor.azure.com'
    $global:NwbCicdTest.posts=@();$run.conclusion='failure'
    & $entry -RunId 123 -RunAttempt 2 -ConfigPath $configFile -Publish | Out-Null
    Check ($global:NwbCicdTest.posts.Count -eq 2) 'Successful deployment retained when later workflow job fails'
    $run.conclusion='success';$success.state='failure'
    Reject {& $entry -RunId 123 -RunAttempt 2 -ConfigPath $configFile} 'no linked successful deployment evidence'
    $success.state='success';$success.log_url=$run.html_url+'4'
    Reject {& $entry -RunId 123 -RunAttempt 2 -ConfigPath $configFile} 'no linked successful deployment evidence'
    $success.log_url=$run.html_url+'/job/5'
    $deployment.environment='unknown'
    Reject {& $entry -RunId 123 -RunAttempt 2 -ConfigPath $configFile} 'no reviewed environment mapping'
    $deployment.environment='dev'
    $inactive=[pscustomobject]@{id=82;state='inactive';log_url=$run.html_url;created_at='2026-10-17T10:00:00Z'}
    $global:NwbCicdTest.statuses=@($inactive,$success)
    $result=& $entry -RunId 123 -RunAttempt 2 -ConfigPath $configFile
    Check (($result -join '') -like '*2026-10-16T10:10:00*') 'Inactive later status does not erase original success'
    $run.workflow_id=43;$global:NwbCicdTest.deployments=@()
    $result=& $entry -RunId 123 -RunAttempt 2 -ConfigPath $configFile -WarningAction SilentlyContinue
    Check (($result -join '') -like '*"Environment":"unclassified"*') 'New workflows collected without inventing environment'
    $run.workflow_id=42;$global:NwbCicdTest.deployments=@($deployment)
    $global:NwbCicdTest.posts=@();$global:NwbCicdTest.mode='workflow-post-error'
    Reject {& $entry -RunId 123 -RunAttempt 2 -ConfigPath $configFile -Publish} 'Workflow collection: Request failed'
    Check ($global:NwbCicdTest.posts.Count -eq 1 -and $global:NwbCicdTest.posts[0].Uri -like '*NWBDeploymentFacts_CL*') 'Workflow publish failure does not suppress deployment ingestion'
    $global:NwbCicdTest.mode='rate-limit';$global:NwbCicdTest.posts=@()
    & $entry -RunId 123 -RunAttempt 2 -ConfigPath $configFile -Publish | Out-Null
    Check ($global:NwbCicdTest.retry -eq 2 -and $global:NwbCicdTest.posts.Count -eq 2) 'Transient rate limits retried'
    $global:NwbCicdTest.mode='ok'
    $env:GITHUB_EVENT_NAME='workflow_run';$env:GITHUB_EVENT_PATH=$eventFile
    @{action='completed';repository=@{full_name='northwest/doc_extraction'};workflow_run=@{id=123;run_attempt=2;status='completed'}} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $eventFile -Encoding UTF8
    $global:NwbCicdTest.calls=@()
    & $entry -ConfigPath $configFile | Out-Null
    Check ($global:NwbCicdTest.calls[0] -like '*/attempts/2') 'Event pins source attempt, not latest rerun'
    $run.path='.github/workflows/nwb-cicd-collector.yml';$global:NwbCicdTest.posts=@()
    & $entry -ConfigPath $configFile -Publish | Out-Null
    Check ($global:NwbCicdTest.posts.Count -eq 0) 'Collector cannot record itself as application delivery'
    $run.path='.github/workflows/app.yml';$env:GITHUB_REPOSITORY='wrong/repository'
    Reject {& $entry -ConfigPath $configFile} 'Unexpected repository'
} finally {
    foreach($name in $envNames){[Environment]::SetEnvironmentVariable($name,$saved[$name])}
    foreach($file in @($configFile,$eventFile)){if(Test-Path -LiteralPath $file){Remove-Item -LiteralPath $file}}
}
Write-Output "Passed $script:passed CI/CD offline checks. No live GitHub/Azure validation."
