$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$script:passed=0
function Check($condition,$message){if(-not $condition){throw "FAILED: $message"};$script:passed++}
$scripts=Join-Path $PSScriptRoot '../../actions/nwb-cicd-monitoring/scripts'
. (Join-Path $scripts 'NwbTransport.ps1')

# Match Invoke-RestMethod's top-level JSON array behavior: one pipeline object.
$script:pageCalls=0
$script:pageMode='multiple'
function Invoke-RestMethod {
    param($Uri,$Headers,$Method,$TimeoutSec,$MaximumRedirection,$ErrorAction)
    $script:pageCalls++
    if($script:pageMode -eq 'empty'){return ,@()}
    if($script:pageMode -eq 'null'){return $null}
    if($script:pageMode -eq 'single'){return ,@([pscustomobject]@{id=1})}
    if($Uri -match 'page=1$'){return ,@(1..100 | ForEach-Object {[pscustomobject]@{id=$_}})}
    if($Uri -match 'page=2$'){return ,@([pscustomobject]@{id=101},[pscustomobject]@{id=102})}
    throw 'Unexpected third page'
}
$items=Get-NwbArrayPages -Uri 'https://api.northwest.ghe.com/repos/northwest/test/deployments?sha=test' -Headers @{}
Check ($items.Count -eq 102 -and $script:pageCalls -eq 2) 'Top-level REST arrays continue past a full 100-item page'
Check ($items[0].id -eq 1 -and $items[101].id -eq 102 -and $items[0] -isnot [array]) 'Pagination returns flat deployment/status objects in order'
foreach($mode in @('empty','null','single')){
    $script:pageMode=$mode;$script:pageCalls=0
    $items=Get-NwbArrayPages -Uri 'https://api.northwest.ghe.com/repos/northwest/test/deployments/1/statuses' -Headers @{}
    $expected=0;if($mode -eq 'single'){$expected=1}
    Check ($items.Count -eq $expected -and $script:pageCalls -eq 1) "REST $mode page terminates correctly"
}

Import-Module (Join-Path $scripts 'PipelineRecord.psm1') -Force
$run=[pscustomobject]@{id=123;run_attempt=2;workflow_id=42;status='completed';conclusion='failure';name='App';path='.github/workflows/app.yml';head_sha='test';html_url='https://northwest.ghe.com/northwest/test/actions/runs/123';repository=[pscustomobject]@{full_name='northwest/test'};updated_at='2026-10-20T10:01:00Z'}
$jobs=@(
    [pscustomobject]@{id=1;name='Build';status='completed';conclusion='failure';started_at=$null;completed_at=$null;steps=@()},
    [pscustomobject]@{id=2;name='build';status='completed';conclusion='success';started_at=$null;completed_at=$null;steps=@(
        [pscustomobject]@{number=1;name='Scan';status='completed';conclusion='success';started_at=$null;completed_at=$null},
        [pscustomobject]@{number=2;name='scan';status='completed';conclusion='success';started_at=$null;completed_at=$null}
    )}
)
$mapping=[pscustomobject]@{'42'=@(
    [pscustomobject]@{JobName='Build';Stage='UpperJob'},
    [pscustomobject]@{JobName='build';Stage='LowerJob'},
    [pscustomobject]@{JobName='build';StepName='Scan';Stage='UpperStep'},
    [pscustomobject]@{JobName='build';StepName='scan';Stage='LowerStep'}
)}
$records=@(ConvertTo-PipelineRecords -Run $run -Jobs $jobs -Service test -Environment ci -StageMappings $mapping)
Check (($records.Stage -join ',') -ceq 'UpperJob,LowerJob,UpperStep,LowerStep') 'Case-distinct job and step selectors remain distinct'
$mapping.'42'+=[pscustomobject]@{JobName='Build';Stage='Duplicate'}
$rejected=$false
try{ConvertTo-PipelineRecords -Run $run -Jobs $jobs -Service test -Environment ci -StageMappings $mapping | Out-Null}catch{if($_.Exception.Message -like '*Duplicate stage mapping*'){$rejected=$true}else{throw}}
Check $rejected 'Exactly duplicated selectors are still rejected'

Import-Module (Join-Path $scripts 'WorkflowRecord.psm1') -Force
$options=@{Run=$run;Repository='northwest/test';Service='test';Environment='ci';ObservedAt=[datetimeoffset]'2026-10-26T12:00:00Z'}
$empty=ConvertTo-WorkflowRecord @options -Jobs @()
Check ($null -eq $empty.CompletedAt -and $null -eq $empty.DurationSeconds) 'Failure before jobs does not invent execution timing'
Check ([datetimeoffset]$empty.SourceUpdatedAt -eq [datetimeoffset]$run.updated_at) 'Failure before jobs retains the source timestamp for alert recency'
$partial=ConvertTo-WorkflowRecord @options -Jobs $jobs
Check ($null -eq $partial.CompletedAt -and $partial.SourceUpdatedAt -eq $empty.SourceUpdatedAt) 'Incomplete job timing does not remove source recency'
$options.ObservedAt=[datetimeoffset]'2026-10-27T12:00:00Z'
$replay=ConvertTo-WorkflowRecord @options -Jobs @()
Check ($replay.SourceUpdatedAt -eq $empty.SourceUpdatedAt -and $replay.UpdatedAt -ne $empty.UpdatedAt) 'Replaying an old failure does not make its source timestamp current'
$run.PSObject.Properties.Remove('updated_at')
$missing=ConvertTo-WorkflowRecord @options -Jobs @()
Check ($null -eq $missing.SourceUpdatedAt) 'Missing source timestamp stays unknown rather than becoming collection time'
Write-Output "Passed $script:passed review regression checks. No live API requests."
