[CmdletBinding()]
param([string]$Path=(Join-Path $PSScriptRoot 'nwb-cicd-monitoring.workbook.json'))
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$checks=0
function Assert([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:checks++
}
$w=Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
Assert ($w.version -eq 'Notebook/1.0') 'Wrong workbook version.'
$names=@($w.items | ForEach-Object {$_.name})
Assert (($names | Sort-Object -Unique).Count -eq $names.Count) 'Duplicate item names.'
$parameters=@($w.items | Where-Object type -eq 9 | ForEach-Object {$_.content.parameters})
$parameterNames=@($parameters | ForEach-Object {$_.name})
Assert ($parameterNames.Count -eq 4) 'Expected four dashboard filters.'
Assert (($parameters | Where-Object name -eq Repository).value -eq 'northwest/doc_extraction') 'Unexpected default repository.'
$queries=@($w.items | Where-Object type -eq 3)
Assert ($queries.Count -eq 14) 'Expected two tile panels and twelve other query panels.'
foreach ($item in $queries) {
    $c=$item.content
    Assert ($c.crossComponentResources[0] -eq $w.fallbackResourceIds[0]) "Wrong scope: $($item.name)"
    Assert ($c.timeContextFromParameter -eq 'TimeRange') "Missing time scope: $($item.name)"
    Assert ($c.query.Contains('where TimeGenerated {TimeRange}')) "Missing collection-time bound: $($item.name)"
    Assert ($c.query.Contains('summarize arg_max(UpdatedAt, *)')) "Missing observation deduplication: $($item.name)"
    Assert ($c.query.Contains("base64_decode_tostring('{Repository:base64}')")) "Unsafe repository substitution: $($item.name)"
    Assert (-not $c.query.Contains('REPLACE_')) "Placeholder in query: $($item.name)"
    foreach ($match in [regex]::Matches($c.query,'\{([A-Za-z]+)(?::[A-Za-z]+)?\}')) {
        Assert ($parameterNames -contains $match.Groups[1].Value) "Undefined parameter in $($item.name)"
    }
    if ($item.name -like 'health-*') {
        Assert (-not $c.query.Contains('{Workflow:')) 'Health must not filter on nonexistent workflow fields.'
        Assert (-not $c.query.Contains('{Environment:')) 'Health must not filter on nonexistent environment fields.'
    }
    if ($c.query.Contains('let E =')) {
        Assert ($c.query.Contains('by Repository, RunId, RunAttempt, JobId, RecordType, StepNumber')) 'Execution dedup key could merge records.'
    }
    if ($c.query.Contains('let W =')) {
        Assert ($c.query.Contains('by Repository, RunId, RunAttempt')) 'Workflow dedup key must preserve reruns and repositories.'
    }
}
$tilePanels=@($queries | Where-Object {$_.content.visualization -eq 'tiles'})
$tileCount=0
foreach ($panel in $tilePanels) { $tileCount += [regex]::Matches($panel.content.query,"bag_pack\('Metric'").Count }
Assert ($tileCount -eq 20) 'Expected 20 summary tiles.'
$summary=($queries | Where-Object name -eq 'workflow-kpis').content.query
Assert ($summary.Contains('Attempts == 0, real(null)')) 'Empty success-rate denominator must be guarded.'
Assert ($summary.Contains("'No data'")) 'Unknown rates/durations must be labelled.'
Assert (-not $summary.Contains('coalesce(DurationSeconds,0)')) 'Missing timing must not become zero.'

# Regeneration must reproduce the checked-in artifact; do not overwrite it during this check.
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('nwb-workbook-'+[guid]::NewGuid().ToString()+'.json')
try {
    & (Join-Path $PSScriptRoot 'Build-CicdWorkbook.ps1') -WorkspaceResourceId $w.fallbackResourceIds[0] -OutputPath $temporary | Out-Null
    # Hashtable property order is not stable across PowerShell processes, so compare canonical JSON trees.
    function Canonical($Value) {
        if ($null -eq $Value) { return 'null' }
        if ($Value -is [System.Management.Automation.PSCustomObject]) {
            $entries=@(foreach ($p in ($Value.PSObject.Properties | Sort-Object Name)) {
                ($p.Name | ConvertTo-Json -Compress)+':'+(Canonical $p.Value)
            })
            return '{'+($entries -join ',')+'}'
        }
        if ($Value -is [System.Array]) {
            $entries=@(foreach ($v in $Value) { Canonical $v })
            return '['+($entries -join ',')+']'
        }
        return ($Value | ConvertTo-Json -Compress)
    }
    $rebuilt=Get-Content -LiteralPath $temporary -Raw | ConvertFrom-Json
    Assert ((Canonical $w) -ceq (Canonical $rebuilt)) 'Workbook JSON differs from its generator. Rebuild it.'
} finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
}
Write-Output "Passed $checks offline checks. Live KQL execution and Azure rendering still require portal validation."
