$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$script:passed=0
function Check($condition,$message){if(-not $condition){throw "FAILED: $message"};$script:passed++}
function Reject([scriptblock]$action,[string]$message){
    try{& $action | Out-Null}catch{Check ($_.Exception.Message -like "*$message*") "Expected $message, got $($_.Exception.Message)";return}
    throw "FAILED: expected $message"
}
$scripts=Join-Path $PSScriptRoot '../../actions/nwb-cicd-monitoring/scripts'
Import-Module (Join-Path $scripts 'PipelineRecord.psm1') -Force
Import-Module (Join-Path $scripts 'DeploymentRecord.psm1') -Force
. (Join-Path $scripts 'NwbTransport.ps1')
. (Join-Path $scripts 'CollectorHealth.ps1')
$names=@('GITHUB_REPOSITORY','GITHUB_API_URL','GITHUB_TOKEN','GITHUB_EVENT_NAME','AZURE_DCE_LOGS_ENDPOINT','AZURE_WORKFLOW_DCR_IMMUTABLE_ID','AZURE_DEPLOYMENT_DCR_IMMUTABLE_ID','AZURE_EXECUTION_DCR_IMMUTABLE_ID','AZURE_HEALTH_DCR_IMMUTABLE_ID')
$saved=@{};foreach($name in $names){$saved[$name]=[Environment]::GetEnvironmentVariable($name)}
$now=[datetimeoffset]::UtcNow
$run=[pscustomobject]@{id=123;run_attempt=2;workflow_id=42;status='completed';conclusion='success';name='App';path='.github/workflows/app.yml';head_sha=('a'*40);html_url='';repository=[pscustomobject]@{full_name=''}}
$job=[pscustomobject]@{id=5;run_id=123;run_attempt=2;name='Build';status='completed';conclusion='success';started_at=$now.AddMinutes(-2).ToString('o');completed_at=$now.AddMinutes(-1).ToString('o');steps=@()}
$deployment=[pscustomobject]@{id=8;sha=('a'*40);environment='dev';production_environment=$false;created_at=$now.AddMinutes(-3).ToString('o')}
$success=[pscustomobject]@{id=81;state='success';log_url='';created_at=$now.AddMinutes(-1).ToString('o')}
$map=[pscustomobject]@{Service='sample';Environment='development';Production=$false;SuccessMeansDeployed=$true}
$global:NwbMulti=@{posts=@();calls=@();run=$run;job=$job;deployment=$deployment;success=$success;healthMode=$false}
function Invoke-RestMethod {
    param($Uri,$Headers,$Method,$TimeoutSec,$MaximumRedirection,$ErrorAction,$Body,$ContentType)
    $s=$global:NwbMulti;$s.calls+=$Uri
    if($Method -eq 'Post'){$s.posts+=([Text.Encoding]::UTF8.GetString($Body)|ConvertFrom-Json);return}
    if($Uri -like '*/actions/workflows/*/runs?*'){return [pscustomobject]@{total_count=0;workflow_runs=@()}}
    if($Uri -like '*/jobs?*'){return [pscustomobject]@{total_count=1;jobs=@($s.job)}}
    if($Uri -like '*/deployments/8/statuses?*'){return @($s.success)}
    if($Uri -like '*/deployments?*'){return @($s.deployment)}
    if($Uri -match '/actions/runs/123/attempts/2$'){return $s.run}
    throw "Unexpected offline request: $Uri"
}
function az {$global:LASTEXITCODE=0;'offline-token'}
$configPath=Join-Path $PSScriptRoot ('multi-'+[guid]::NewGuid().ToString('N')+'.json')
try{
    $env:GITHUB_TOKEN='offline-token';$env:GITHUB_API_URL='https://api.northwest.ghe.com';$env:GITHUB_EVENT_NAME='workflow_dispatch'
    $env:AZURE_DCE_LOGS_ENDPOINT='https://test.eastus2-1.ingest.monitor.azure.com'
    foreach($name in $names | Where-Object {$_ -like '*DCR_IMMUTABLE_ID'}){[Environment]::SetEnvironmentVariable($name,'dcr-00000000000000000000000000000000')}
    $ids=@()
    foreach($repository in @('northwest/doc_extraction','northwest/second-service')){
        $env:GITHUB_REPOSITORY=$repository;$run.repository.full_name=$repository
        $run.html_url='https://northwest.ghe.com/'+$repository+'/actions/runs/123';$success.log_url=$run.html_url+'/job/5'
        $context=Get-NwbGitHubContext
        Check ($context.Base -ceq ('https://api.northwest.ghe.com/repos/'+$repository)) 'API base follows caller'
        $pipeline=@(ConvertTo-PipelineRecords -Run $run -Jobs @($job) -Service sample -Environment dev)
        Check ($pipeline[0].Repository -ceq $repository -and $pipeline[0].RunUrl -ceq $run.html_url) 'Pipeline metadata follows caller'
        $fact=ConvertTo-DeploymentRecord -Run $run -Deployment $deployment -SuccessStatus $success -Mapping $map
        Check ($fact.Repository -ceq $repository -and $fact.DeploymentId.StartsWith($repository+':')) 'Deployment identity contains caller repository'
        $ids+=$fact.DeploymentId
        Check ((New-NwbHealthRecord -Operation heartbeat -Outcome success).Repository -ceq $repository) 'Health record follows caller'
        $config=@{DefaultService='sample';CollectPipelineExecution=$true;PublishHealth=$true;WorkflowMappings=@{'42'=@{Service='sample';Environment='development';IsDeploymentPipeline=$true}};StageMappings=@{};DeploymentEnvironments=@{dev=$map}}
        $config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configPath -Encoding UTF8
        $global:NwbMulti.posts=@();$global:NwbMulti.calls=@()
        & (Join-Path $scripts 'Invoke-SharedAction.ps1') -Operation collect -RunId 123 -RunAttempt 2 -ConfigPath $configPath | Out-Null
        Check ($global:NwbMulti.posts.Count -eq 0) 'Composite entry preview never publishes'
        & (Join-Path $scripts 'Invoke-SharedAction.ps1') -Operation collect -RunId 123 -RunAttempt 2 -ConfigPath $configPath -Publish | Out-Null
        Check ($global:NwbMulti.posts.Count -eq 4 -and @($global:NwbMulti.posts | Where-Object {$_.Repository -cne $repository}).Count -eq 0) 'All four streams contain caller repository'
        Check (@($global:NwbMulti.calls | Where-Object {$_ -like 'https://api.*' -and -not $_.StartsWith($context.Base+'/')}).Count -eq 0) 'No API requests escape caller repository'
        $global:NwbMulti.posts=@()
        & (Join-Path $scripts 'Invoke-SharedAction.ps1') -Operation health -Publish | Out-Null
        Check ($global:NwbMulti.posts.Count -eq 1 -and $global:NwbMulti.posts[0].Repository -ceq $repository) 'Shared health entry observes caller'
    }
    Check ($ids[0] -cne $ids[1]) 'Identical numeric deployment IDs in separate repositories do not collide'
    $run.repository.full_name='northwest/doc_extraction'
    Reject {& (Join-Path $scripts 'Send-PipelineExecution.ps1') -Run $run -Service sample -Environment dev} 'does not match the caller'
    foreach($repository in @('outside/repo','northwest/../other','northwest/repo?token=x','northwest/..')){
        Reject {Get-NwbRepository -Repository $repository} 'Unexpected repository'
    }
    $env:GITHUB_API_URL='https://evil.invalid';Reject {Get-NwbGitHubContext} 'Unexpected GitHub API host'
}finally{
    foreach($name in $names){[Environment]::SetEnvironmentVariable($name,$saved[$name])}
    if(Test-Path -LiteralPath $configPath){Remove-Item -LiteralPath $configPath}
}
Write-Output "Passed $script:passed multi-repository checks. GitHub execution and Azure sign-in still require live validation."
