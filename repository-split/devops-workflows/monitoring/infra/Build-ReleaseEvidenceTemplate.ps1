param([string]$OutputPath=(Join-Path $PSScriptRoot 'release-evidence.json'))
$ErrorActionPreference='Stop'
$template=Get-Content (Join-Path $PSScriptRoot 'execution-health.json') -Raw | ConvertFrom-Json
$schemas=[ordered]@{
 NWBReleaseEvidence_CL=[ordered]@{
  TimeGenerated='datetime';UpdatedAt='datetime';CompletedAt='datetime';Repository='string';Service='string';Environment='string';ResourceId='string';TargetType='string';ReleaseId='string';RelatedDeploymentId='string';Operation='string';Result='string';SourceVersion='string';TargetVersion='string';RevisionName='string';RunId='string';RunAttempt='int';RunUrl='string';Actor='string';CommitSha='string';RequiredChecks='dynamic';RequiredCheckCount='int';PassedCheckCount='int';Verification='string';EvidenceSource='string'
 }
 NWBVersionInventory_CL=[ordered]@{
  TimeGenerated='datetime';UpdatedAt='datetime';Repository='string';Service='string';Environment='string';ResourceId='string';Outcome='string';ActiveVersions='dynamic';RunId='string';RunUrl='string';EvidenceSource='string';DetailCode='string'
 }
}
$template.parameters.dcrName.defaultValue='prd-cicdobservability-release-evidence-dcr-eus2'
$tables=@($template.resources | Where-Object type -eq 'Microsoft.OperationalInsights/workspaces/tables')
$dcr=@($template.resources | Where-Object type -eq 'Microsoft.Insights/dataCollectionRules')[0]
$declarations=[ordered]@{};$flows=@();$dependencies=@();$index=0
foreach($name in $schemas.Keys) {
 $columns=@(foreach($field in $schemas[$name].Keys){[ordered]@{name=$field;type=$schemas[$name][$field]}})
 $tables[$index].name="[concat(parameters('workspaceName'), '/$name')]"
 $tables[$index].properties.schema.name=$name
 $tables[$index].properties.schema.columns=$columns
 $declarations["Custom-$name"]=@{columns=$columns}
 $flows+=@{streams=@("Custom-$name");destinations=@('workspace');transformKql='source';outputStream="Custom-$name"}
 $dependencies+="[resourceId('Microsoft.OperationalInsights/workspaces/tables', parameters('workspaceName'), '$name')]"
 $index++
}
$dcr.dependsOn=$dependencies
$dcr.properties.streamDeclarations=$declarations
$dcr.properties.dataFlows=$flows
[IO.File]::WriteAllText($OutputPath,($template | ConvertTo-Json -Depth 40)+"`n",[Text.UTF8Encoding]::new($false))
Write-Output "Created $OutputPath"
