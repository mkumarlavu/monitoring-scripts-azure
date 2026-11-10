$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$script:checks=0
function Check($Condition,[string]$Message) {
    if(-not $Condition) {throw "FAILED: $Message"}
    $script:checks++
}
function Query([string]$Title) {
    $matches=@($dashboard.panels | Where-Object title -eq $Title)
    Check ($matches.Count -eq 1) "Panel exists once: $Title"
    return $matches[0].targets[0].azureLogAnalytics.query
}
$artifact=Join-Path $PSScriptRoot 'nwb-dora-monitoring.grafana.json'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('nwb-dora-'+[guid]::NewGuid().ToString()+'.json')
$standalone=Join-Path ([IO.Path]::GetTempPath()) ('nwb-dora-'+[guid]::NewGuid().ToString()+'.ps1')
try {
    # Run away from the repository to catch accidental workbook/file dependencies.
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Build-DoraGrafana.ps1') -Destination $standalone
    & $standalone -OutputPath $temp | Out-Null
    $dashboard=Get-Content -LiteralPath $temp -Raw | ConvertFrom-Json
    # Hashtable property ordering can differ between PowerShell processes.
    function Canonical($Value) {
        if($null -eq $Value) {return 'null'}
        if($Value -is [pscustomobject]) {
            $parts=@(foreach($p in ($Value.PSObject.Properties | Sort-Object Name)) {
                ($p.Name | ConvertTo-Json -Compress)+':'+(Canonical $p.Value)
            })
            return '{'+($parts -join ',')+'}'
        }
        if($Value -is [array]) {
            $parts=@(foreach($v in $Value) {Canonical $v})
            return '['+($parts -join ',')+']'
        }
        return ($Value | ConvertTo-Json -Compress)
    }
    $saved=Get-Content -LiteralPath $artifact -Raw | ConvertFrom-Json
    Check ((Canonical $saved) -ceq (Canonical $dashboard)) 'Committed artifact matches generator'
    Check ($dashboard.uid -eq 'nwb-dora-monitoring') 'Separate stable dashboard UID'
    $ids=@($dashboard.panels | ForEach-Object id)
    Check (($ids | Sort-Object -Unique).Count -eq $ids.Count) 'Panel IDs are unique'
    foreach($p in $dashboard.panels) {
        $a=$p.gridPos
        Check ($a.x -ge 0 -and $a.w -gt 0 -and ($a.x+$a.w) -le 24 -and $a.h -gt 0) "Valid grid: $($p.title)"
        foreach($other in ($dashboard.panels | Where-Object {$_.id -gt $p.id})) {
            $b=$other.gridPos
            $overlap=$a.x -lt ($b.x+$b.w) -and $b.x -lt ($a.x+$a.w) -and $a.y -lt ($b.y+$b.h) -and $b.y -lt ($a.y+$a.h)
            Check (-not $overlap) "No overlap: $($p.title) / $($other.title)"
        }
        if($p.type -eq 'text') {continue}
        $q=$p.targets[0].azureLogAnalytics.query
        Check ($q.Contains('let repo = @${Repository:sqlstring};')) "Repository safely interpolated: $($p.title)"
        Check (-not $q.Contains("'"+'${Repository:sqlstring}'+"'")) 'No double quoting of Grafana variables'
        Check ($p.targets[0].azureLogAnalytics.resources[0] -like '*/workspaces/prd-cicdobservability-law-eus2') 'Workspace binding retained'
        Check ($p.fieldConfig.defaults.noValue -eq 'Not available') 'Missing values are not healthy zeros'
    }
    $frequency=Query 'Deployments / day'
    Check ($frequency.Contains('let days = iff(windowEnd > windowStart, (windowEnd - windowStart) / 1d, real(null));')) 'Frequency uses actual elapsed days and guards zero/reversed windows'
    Check (-not $frequency.Contains('max_of(1.0 / 24.0')) 'Short ranges are not clamped to an hour'
    $rate=Query 'Change fail rate'
    Check ($rate.Contains('ReachedProduction == true')) 'DORA excludes non-production deployments'
    Check ($rate.IndexOf('arg_max(UpdatedAt') -lt $rate.IndexOf('DeployedAt between')) 'Latest classifications selected before date filtering'
    Check ($rate.Contains('Known == Total') -and $rate.Contains('isnotnull(RequiresIntervention)') -and $rate.Contains('real(null)')) 'Incomplete failure classification does not become zero rate'
    $rework=Query 'Deployment rework rate'
    Check ($rework.Contains('Known == Total') -and $rework.Contains('isnotnull(IsRework)')) 'Rework requires complete explicit classification'
    $directory=Query 'Run directory | repo, build, actor and result'
    Check ($directory.Contains('by Repository, RunId, RunAttempt')) 'Retries remain separate while replays deduplicate'
    foreach($field in @('Actor','TriggeringActor','RunNumber')) {
        Check ($directory.Contains("column_ifexists('$field', '')")) "Old schemas supported for $field"
    }
    Check ($directory.Contains('BuildRunId=RunId') -and $directory.Contains('RunUrl')) 'Run ID and source link are available'
    $verify=Query 'Verification jobs failed / timed out'
    Check ($verify.Contains('StageMappingKnown == true')) 'Verification requires reviewed mapping'
    Check ($verify.Contains("Stage in ('Post-deployment verification', 'Smoke test', 'Rollback verification')")) 'Only explicit verification stages count'
    Check (-not $verify.Contains("'Deployment validation'")) 'Pre-deployment validation is not post-deployment evidence'
    Check ($verify.Contains("RecordType == 'Job'") -and $verify.Contains('long(null)')) 'Job totals exclude steps and empty data stays unavailable'
    $detail=Query 'Post-deployment verification detail | open the source run'
    Check ($detail.Contains('RecordType, Stage, JobName, StepNumber, StepName') -and $detail.Contains('RunUrl')) 'Step-only checks and GitHub drilldown remain available'
    $attention=Query 'Checks needing attention | jobs and steps'
    Check ($attention.Contains("'skipped'") -and $attention.Contains("'cancelled'")) 'Skipped and cancelled checks remain visible'
    $mapping=Get-Content (Join-Path $PSScriptRoot 'post-deployment-mapping-example.json') -Raw | ConvertFrom-Json
    Check (@($mapping.Rules).Count -gt 0) 'Onboarding mapping example parses'
    $release=Query 'Release history | version, actor and source run'
    Check ($release.Contains('Environment == environment') -and -not $release.Contains('ReachedProduction == true')) 'Operational release history supports every environment'
    Check ($release.IndexOf('arg_max(UpdatedAt') -lt $release.IndexOf('CompletedAt between')) 'Release replays deduplicate before window filtering'
    $inventory=Query 'Latest observed versions | Azure Container Apps'
    Check ($inventory.Contains('arg_max(UpdatedAt, *) by Repository, ResourceId')) 'Latest snapshot replaces previous version observations'
    Check ($inventory.Contains('Read failed') -and $inventory.Contains('Stale - refresh inventory')) 'Failed and stale inventory are visible'
    Check (-not $inventory.Contains('TimeGenerated between') -and -not $inventory.Contains('RunId ==')) 'Inventory not scoped to investigated run or event window'
    Check ((Query 'Required checks | failed, skipped or missing').Contains("tostring(Check.Result) != 'success'")) 'All non-passing required checks shown'
    Write-Output "PASS: $script:checks dashboard artifact, query-contract and layout checks (offline; KQL not executed)."
}
finally {
    if(Test-Path -LiteralPath $temp) {Remove-Item -LiteralPath $temp}
    if(Test-Path -LiteralPath $standalone) {Remove-Item -LiteralPath $standalone}
}
