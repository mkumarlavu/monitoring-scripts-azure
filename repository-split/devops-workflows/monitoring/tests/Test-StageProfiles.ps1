$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$scripts=Join-Path $PSScriptRoot '../../actions/nwb-cicd-monitoring/scripts'
. (Join-Path $scripts 'NwbStageProfiles.ps1')
Import-Module (Join-Path $scripts 'PipelineRecord.psm1') -Force
$script:passed=0
function Check($ok,$message) { if (-not $ok) { throw "FAILED: $message" }; $script:passed++ }
function Reject([scriptblock]$action,$message) {
    try { & $action | Out-Null } catch { Check ($_.Exception.Message -like "*$message*") $_.Exception.Message; return }
    throw "FAILED: expected $message"
}
$run=[pscustomobject]@{id=123;run_attempt=1;workflow_id=42;status='completed';name='Delivery';path='.github/workflows/delivery.yml';html_url='https://northwest.ghe.com/northwest/doc_extraction/actions/runs/123';repository=[pscustomobject]@{full_name='northwest/doc_extraction'};head_sha=('a'*40)}
$config='{"StageProfiles":{".github/workflows/delivery.yml":"nwb-delivery"},"StageMappings":{}}' | ConvertFrom-Json
$job=[pscustomobject]@{id=501;name='build';status='completed';conclusion='success';started_at='2026-11-03T10:00:00Z';completed_at='2026-11-03T10:01:00Z';steps=@([pscustomobject]@{number=1;name='Scan';status='completed';conclusion='success';started_at='2026-11-03T10:00:00Z';completed_at='2026-11-03T10:00:30Z'})}
function Records($c=$config) {
    $resolved=Resolve-NwbStageMappings -Config $c -Run $run
    @(ConvertTo-PipelineRecords -Run $run -Jobs @($job) -Service test -Environment unclassified -StageMappings $resolved)
}
$rows=@(Records)
Check ($rows.Count -eq 2 -and $rows[0].Stage -ceq 'Build' -and $rows[1].Stage -ceq 'Build') 'Shared profile labels job and steps'
Check ($rows[0].Environment -eq 'unclassified') 'Stage profile does not invent environment'
$run.workflow_id=999;$run.path='.github/workflows/delivery.yml@refs/heads/main'
Check ((Records)[0].Stage -ceq 'Build') 'Workflow ID changes and ref suffix need no config edit'
$config.StageMappings='{".github/workflows/delivery.yml":[{"JobName":"build","Stage":"Compile"},{"JobName":"build","StepName":"Scan","Stage":"Security"},{"JobName":"Build","Stage":"Other build"}]}' | ConvertFrom-Json
$rows=@(Records)
Check ($rows[0].Stage -ceq 'Compile' -and $rows[1].Stage -ceq 'Security') 'Local job and step overrides take effect'
$job.name='changes';Check ((Records)[0].Stage -ceq 'Change detection') 'Override preserves unrelated profile rules'
$job.name='Build';Check ((Records)[0].Stage -ceq 'Other build') 'Selectors remain case sensitive'
$job.name='unknown';Check (-not (Records)[0].StageMappingKnown) 'Unknown job stays unmapped'
$job.name='build';$run.path='.github/workflows/copilot.yml'
Check (-not (Records)[0].StageMappingKnown) 'Profile is scoped to the selected workflow'
$run.path='.github/workflows/Delivery.yml'
Check (-not (Records)[0].StageMappingKnown) 'Profile path selection is case sensitive'
$run.path='.github/workflows/delivery.yml'
$legacy='{"StageMappings":{"42":[{"JobName":"build","Stage":"Legacy"}]}}' | ConvertFrom-Json
$run.workflow_id=42;Check ((Records $legacy)[0].Stage -ceq 'Legacy') 'Legacy caller without profile remains supported'
$config.StageProfiles.'.github/workflows/delivery.yml'='missing'
Reject { Records } 'Unknown shared stage profile'
$config.StageProfiles.'.github/workflows/delivery.yml'='../outside'
Reject { Records } 'shared profile name'
$config.StageProfiles.'.github/workflows/delivery.yml'='nwb-delivery'
$config.StageMappings='{".github/workflows/delivery.yml":[{"JobName":"build","Stage":"One"},{"JobName":"build","Stage":"Two"}]}' | ConvertFrom-Json
Reject { Records } 'Duplicate stage mapping selector'
$config.StageMappings='{".github/workflows/delivery.yml":{"JobName":"build","Stage":"One"}}' | ConvertFrom-Json
Reject { Records } 'JSON arrays'
Write-Output "Passed $script:passed shared-profile checks. No live API requests."
