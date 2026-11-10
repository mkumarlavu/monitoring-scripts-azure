$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$scripts=Join-Path $PSScriptRoot '../../actions/nwb-cicd-monitoring/scripts'
Import-Module (Join-Path $scripts 'ReleaseEvidence.psm1') -Force
$script:checks=0
function Check($Condition,$Message) { if(-not $Condition){throw $Message}; $script:checks++ }
function Reject([scriptblock]$Action,$Message) { $caught=$false; try { & $Action | Out-Null } catch {$caught=$true}; Check $caught $Message }
function Config { Get-Content (Join-Path $PSScriptRoot '../config/release-targets.example.json') -Raw | ConvertFrom-Json }
function Report { Get-Content (Join-Path $PSScriptRoot '../config/release-report.example.json') -Raw | ConvertFrom-Json }
$now=[datetime]'2026-11-09T18:00:00Z'
$context=[pscustomobject]@{Repository='northwest/example';RunId='123';RunAttempt=2;RunUrl='https://northwest.ghe.com/northwest/example/actions/runs/123';Actor='tester';CommitSha='abc'}
$config=Config; $report=Report
$record=ConvertTo-ReleaseRecord $report $config $context -Now $now
Check ($record.TargetType -eq 'Container App') 'Container App identity detected'
$discovery=Get-Content (Join-Path $PSScriptRoot '../config/release-discovery.example.json') -Raw | ConvertFrom-Json
$mixedConfig=Config
$mixedConfig | Add-Member NoteProperty AllowDiscoveredTargets $true
$mixedConfig | Add-Member NoteProperty RequiredChecks @()
$mixedReport=Report
$mixedReport | Add-Member NoteProperty Service 'payments'
$mixedRecord=ConvertTo-ReleaseRecord $mixedReport $mixedConfig $context -Now $now
Check ($mixedRecord.RequiredCheckCount -eq 2) 'Known targets retain explicit checks when discovery defaults are empty'
$mixedReport.Environment='wrong-environment'
Reject { ConvertTo-ReleaseRecord $mixedReport $mixedConfig $context -Now $now } 'Discovery cannot bypass a known target policy through an environment mismatch'
$mixedReport.ResourceId=$mixedReport.ResourceId.ToUpperInvariant()
Reject { ConvertTo-ReleaseRecord $mixedReport $mixedConfig $context -Now $now } 'ARM resource casing cannot bypass the environment guard'
$mixedReport.ResourceId='k8s://bank-cluster/uat/Deployment/new-payments'
$mixedReport.Environment='uat'
$mixedRecord=ConvertTo-ReleaseRecord $mixedReport $mixedConfig $context -Now $now
Check ($mixedRecord.Environment -ceq 'uat' -and $mixedRecord.Verification -eq 'not_configured') 'Unknown resources still use discovery defaults alongside explicit targets'
$discoveredReport=Report
$discoveredReport | Add-Member NoteProperty Service 'payments'
foreach($item in @(
    @('/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1','Virtual machine'),
    @('/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/providers/Microsoft.ContainerService/managedClusters/cluster1','AKS cluster'),
    @('k8s://bank-cluster/uat/Deployment/payments','Kubernetes workload'),
    @('/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/providers/Microsoft.Web/sites/site1','Other Azure resource')
)) {
    $discoveredReport.ResourceId=$item[0]; $discoveredReport.Environment='uat'
    $detected=ConvertTo-ReleaseRecord $discoveredReport $discovery $context -Now $now
    Check ($detected.TargetType -eq $item[1] -and $detected.Service -eq 'payments' -and $detected.Environment -eq 'uat') 'Discovered identity and environment preserved'
    Check ($detected.RequiredCheckCount -eq 2) 'Discovered target uses default requirements'
}
$discoveredReport.ResourceId='deploy to production'
Reject { ConvertTo-ReleaseRecord $discoveredReport $discovery $context -Now $now } 'Job names cannot establish target identity'
$discoveredReport.ResourceId='k8s://bank-cluster/uat/Deployment/payments'
$discoveredReport.Environment=''
Reject { ConvertTo-ReleaseRecord $discoveredReport $discovery $context -Now $now } 'Discovery cannot infer environment from workload names'
$discovery.AllowDiscoveredTargets='true'
Reject { Assert-ReleaseConfig $discovery } 'Discovery setting must be boolean'
Check ($record.Result -eq 'success' -and $record.Verification -eq 'incomplete_or_failed') 'Successful deployment must not hide failed verification'
Check ($record.PassedCheckCount -eq 1 -and $record.RequiredCheckCount -eq 2) 'Only required applicable checks count'
foreach($environment in @('dev','test','uat','production','disaster-recovery')) {
    $config.Targets[0].Environment=$environment; $report.Environment=$environment
    $r=ConvertTo-ReleaseRecord $report $config $context -Now $now
    Check ($r.Environment -ceq $environment) "Environment $environment preserved"
}
$config=Config; $report=Report
foreach($outcome in @('failure','timed_out','skipped','cancelled')) {
    $report.Checks[1].Result=$outcome
    $r=ConvertTo-ReleaseRecord $report $config $context -Now $now
    Check ($r.Verification -eq 'incomplete_or_failed' -and $r.RequiredChecks[1].Result -eq $outcome) "$outcome is not a pass"
}
$report.Checks=@()
$r=ConvertTo-ReleaseRecord $report $config $context -Now $now
Check ($r.PassedCheckCount -eq 0 -and @($r.RequiredChecks | Where-Object Result -eq 'missing').Count -eq 2) 'Missing reports become missing checks'
$report=Report; $report.Checks[1].Result='success'
$r=ConvertTo-ReleaseRecord $report $config $context -Now $now
Check ($r.Verification -eq 'passed') 'Complete passing evidence verifies requirements'
$report.Operation='rollback'
Reject { ConvertTo-ReleaseRecord $report $config $context -Now $now } 'Rollback requires original deployment link'
$report.RelatedDeploymentId='original-release'
$r=ConvertTo-ReleaseRecord $report $config $context -Now $now
Check ($r.RequiredCheckCount -eq 3 -and $r.Verification -eq 'incomplete_or_failed') 'Rollback requires its own verification'
$config.Targets[0].RequiredChecks=@()
$r=ConvertTo-ReleaseRecord $report $config $context -Now $now
Check ($r.Verification -eq 'not_configured') 'Empty requirements never imply pass'
$config=Config; $report=Report
$report.Environment='wrong'
Reject { ConvertTo-ReleaseRecord $report $config $context -Now $now } 'Unconfigured target rejected'
$report=Report; $report.TargetVersion=''
Reject { ConvertTo-ReleaseRecord $report $config $context -Now $now } 'Successful release needs version'
$report=Report; $report.CompletedAt='2026-11-09T12:00:00'
Reject { ConvertTo-ReleaseRecord $report $config $context -Now $now } 'Timezone required'
$report.CompletedAt=[datetime]'2026-11-09T12:00:00Z'
$r=ConvertTo-ReleaseRecord $report $config $context -Now $now
Check ($r.CompletedAt -like '2026-11-09T12:00:00*') 'PowerShell 7 parsed DateTime supported'
$report.CompletedAt='2027-01-01T00:00:00Z'
Reject { ConvertTo-ReleaseRecord $report $config $context -Now $now } 'Future timestamps rejected'
$report=Report; $report.Checks=@($report.Checks[0],$report.Checks[0])
Reject { ConvertTo-ReleaseRecord $report $config $context -Now $now } 'Duplicate reported checks rejected'
$config.Targets=@($config.Targets[0],$config.Targets[0])
Reject { Assert-ReleaseConfig $config } 'Duplicate target rejected'
$config=Config
$revisions=@(foreach($name in @('blue','green','old')) {
    [pscustomobject]@{name=$name;properties=[pscustomobject]@{active=($name -ne 'old');trafficWeight=50;template=[pscustomobject]@{containers=@([pscustomobject]@{name='api';image="registry/api@$name";env=@{SECRET='must-not-leak'}})}}}
})
$inventory=ConvertTo-VersionRecord $config.Targets[0] $revisions $context -Now $now
Check ($inventory.ActiveVersions.Count -eq 2) 'Multiple active revisions retained, inactive excluded'
Check ($inventory.ActiveVersions[0].TrafficWeight -eq 50) 'Traffic split preserved'
Check (-not ($inventory | ConvertTo-Json -Depth 10).Contains('must-not-leak')) 'Only whitelisted revision metadata exported'
Check ($inventory.ActiveVersions[0].HealthState -eq 'unknown') 'Absent health remains unknown'
$revisions[0].properties.active='true'
Reject { ConvertTo-VersionRecord $config.Targets[0] $revisions $context -Now $now } 'Malformed active state rejected'
$failed=ConvertTo-VersionRecord $config.Targets[0] @() $context -Now $now -Outcome failure
Check ($failed.ActiveVersions.Count -eq 0 -and $failed.DetailCode -eq 'snapshot-read-failed') 'Failed reads produce explicit empty failure snapshot'
$template=Get-Content (Join-Path $PSScriptRoot '../infra/release-evidence.json') -Raw | ConvertFrom-Json
$dcr=@($template.resources | Where-Object type -eq 'Microsoft.Insights/dataCollectionRules')[0]
foreach($pair in @(@('NWBReleaseEvidence_CL',$record),@('NWBVersionInventory_CL',$inventory))) {
    $name=$pair[0]; $value=$pair[1]
    $table=@($template.resources | Where-Object {$_.type -eq 'Microsoft.OperationalInsights/workspaces/tables' -and $_.properties.schema.name -eq $name})[0]
    Check (-not (Compare-Object @($value.PSObject.Properties.Name | Sort-Object) @($table.properties.schema.columns.name | Sort-Object))) "Exact table columns for $name"
    $stream="Custom-$name"
    Check (-not (Compare-Object @($table.properties.schema.columns.name | Sort-Object) @($dcr.properties.streamDeclarations.$stream.columns.name | Sort-Object))) "DCR stream aligned for $name"
    Check (@($dcr.properties.dataFlows | Where-Object {$_.outputStream -eq $stream -and $_.transformKql -eq 'source'}).Count -eq 1) "DCR routing for $name"
}
# Exercise the real entry point and transport with offline CLI/HTTP replacements.
$temp=Join-Path ([IO.Path]::GetTempPath()) ('nwb-release-test-'+[guid]::NewGuid())
$null=New-Item -ItemType Directory -Path $temp
$saved=@{}
$envValues=@{GITHUB_REPOSITORY='northwest/example';GITHUB_SERVER_URL='https://northwest.ghe.com';GITHUB_RUN_ID='123';GITHUB_RUN_ATTEMPT='2';GITHUB_ACTOR='tester';GITHUB_SHA='abc';AZURE_DCE_LOGS_ENDPOINT='https://example.eastus2-1.ingest.monitor.azure.com';AZURE_RELEASE_DCR_IMMUTABLE_ID='dcr-11111111111111111111111111111111'}
foreach($key in $envValues.Keys){$saved[$key]=[Environment]::GetEnvironmentVariable($key);[Environment]::SetEnvironmentVariable($key,$envValues[$key])}
$global:releaseTestPosts=@();$global:releaseTestGets=0;$global:releaseTestBadLink=$false
function global:az { $global:LASTEXITCODE=0; 'offline-token' }
function global:Invoke-RestMethod {
    param($Uri,$Headers,$Method,$Body,$TimeoutSec,$MaximumRedirection,$ErrorAction,$ContentType)
    if($Method -eq 'Post') {
        $global:releaseTestPosts+=([Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json)
        return
    }
    $global:releaseTestGets++
    if($global:releaseTestBadLink){return [pscustomobject]@{value=@();nextLink='https://untrusted.example/revisions'}}
    if($global:releaseTestGets -eq 1){return [pscustomobject]@{value=@();nextLink=($Uri+'&page=2')}}
    return [pscustomobject]@{value=@([pscustomobject]@{name='revision-1';properties=[pscustomobject]@{active=$true;template=[pscustomobject]@{containers=@([pscustomobject]@{name='api';image='registry/api@sha256:123'})}}})}
}
try {
    $config=Config; $report=Report
    $config.Targets[0].ResourceId='/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/test/providers/Microsoft.App/containerApps/example'
    $report.ResourceId=$config.Targets[0].ResourceId; $report.CompletedAt=[datetime]::UtcNow.ToString('o')
    $cp=Join-Path $temp 'config.json';$ep=Join-Path $temp 'report.json'
    $config | ConvertTo-Json -Depth 10 | Set-Content $cp
    $report | ConvertTo-Json -Depth 10 | Set-Content $ep
    $sender=Join-Path $scripts 'Send-ReleaseEvidence.ps1'
    $preview=& $sender -Operation release -ConfigPath $cp -EvidencePath $ep | ConvertFrom-Json
    Check ($preview.Repository -eq 'northwest/example' -and $global:releaseTestPosts.Count -eq 0) 'Preview attributes caller without publishing'
    & $sender -Operation release -ConfigPath $cp -EvidencePath $ep -Publish | Out-Null
    Check ($global:releaseTestPosts.Count -eq 1) 'Release publishes via ingestion transport'
    & $sender -Operation inventory -ConfigPath $cp -Publish | Out-Null
    Check ($global:releaseTestGets -eq 2 -and $global:releaseTestPosts[-1].ActiveVersions.Count -eq 1) 'Inventory follows valid pagination before publishing'
    $global:releaseTestBadLink=$true;$global:releaseTestGets=0
    Reject { & $sender -Operation inventory -ConfigPath $cp -Publish -WarningAction SilentlyContinue } 'Untrusted pagination fails inventory job'
    Check ($global:releaseTestGets -eq 1 -and $global:releaseTestPosts[-1].Outcome -eq 'failure') 'Untrusted host never receives request; failure snapshot published'
} finally {
    foreach($key in $saved.Keys){[Environment]::SetEnvironmentVariable($key,$saved[$key])}
    Remove-Item Function:\az,Function:\Invoke-RestMethod
    Remove-Variable releaseTestPosts,releaseTestGets,releaseTestBadLink -Scope Global
    # This directory was created above with a random, task-specific name.
    Remove-Item -LiteralPath $temp -Recurse -Force
}
Write-Output "PASS: $script:checks release evidence, environment, publisher and schema checks (offline)."
