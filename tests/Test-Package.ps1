$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$script:passed=0
function Check($condition,$message){if(-not $condition){throw "FAILED: $message"};$script:passed++}
$root=Join-Path $PSScriptRoot '..'
foreach($file in Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object {$_.Extension -in @('.ps1','.psm1')}){
    $tokens=$null;$errors=$null
    $null=[System.Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    Check ($errors.Count -eq 0) "PowerShell syntax: $($file.Name)"
}
foreach($file in Get-ChildItem -LiteralPath $root -Recurse -Filter '*.json' -File){
    $null=Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
    Check $true "JSON syntax: $($file.Name)"
}
$infra=Get-Content (Join-Path $root 'infra/execution-health.json') -Raw | ConvertFrom-Json
$schemas=Get-Content (Join-Path $root 'infra/record-schemas.json') -Raw | ConvertFrom-Json
$dcr=@($infra.resources | Where-Object type -eq 'Microsoft.Insights/dataCollectionRules')[0]
foreach($schema in $schemas.PSObject.Properties){
    $stream='Custom-'+$schema.Name
    $table=@($infra.resources | Where-Object {$_.type -eq 'Microsoft.OperationalInsights/workspaces/tables' -and $_.properties.schema.name -eq $schema.Name})[0]
    $expected=(@($schema.Value.PSObject.Properties | ForEach-Object {$_.Name+':'+$_.Value} | Sort-Object) -join ',')
    $tableColumns=(@($table.properties.schema.columns | ForEach-Object {$_.name+':'+$_.type} | Sort-Object) -join ',')
    $streamColumns=(@($dcr.properties.streamDeclarations.$stream.columns | ForEach-Object {$_.name+':'+$_.type} | Sort-Object) -join ',')
    Check ($expected -eq $tableColumns -and $expected -eq $streamColumns) "Payload, table and DCR types agree for $stream"
    $flow=@($dcr.properties.dataFlows | Where-Object outputStream -eq $stream)
    Check ($flow.Count -eq 1 -and $flow[0].streams[0] -eq $stream -and $flow[0].transformKql -eq 'source') "Stream routes unchanged typed records to $stream"
}
$alerts=Get-Content (Join-Path $root 'infra/alerts-disabled.json') -Raw | ConvertFrom-Json
Check (@($alerts.resources | Where-Object {$_.properties.enabled -ne $false}).Count -eq 0) 'All generated alert resources remain disabled'
Check ($alerts.parameters.selectedWorkflowPaths.defaultValue.Count -eq 0) 'Workflow alert allowlist defaults to empty'
Check ($alerts.parameters.actionGroupIds.defaultValue.Count -eq 0) 'No unreviewed notification destination'
foreach($pair in @(@('collector-heartbeat-missing','alert-heartbeat-missing.kql'),@('collector-failed','alert-collector-failed.kql'))){
    $rule=@($alerts.resources | Where-Object {$_.properties.displayName -eq ('NWB '+$pair[0])})[0]
    $query=[IO.File]::ReadAllText((Join-Path $root ('queries/'+$pair[1])))
    Check ($rule.properties.criteria.allOf[0].query -ceq $query) "Embedded query is current: $($pair[0])"
}
Write-Output "Passed $script:passed package checks. ARM/KQL/YAML require live platform validation."
