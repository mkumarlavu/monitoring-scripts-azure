[CmdletBinding()]
param([string]$RunId, [ValidateRange(0,2147483647)][int]$RunAttempt=0,
    [string]$ConfigPath='./config/nwb-observability/collector.json', [switch]$Publish)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'NwbTransport.ps1')
$context=Get-NwbGitHubContext
if ($env:GITHUB_EVENT_NAME -eq 'workflow_run') {
    $event=Get-Content -LiteralPath $env:GITHUB_EVENT_PATH -Raw | ConvertFrom-Json
    if ($event.repository.full_name -cne $env:GITHUB_REPOSITORY -or $event.action -ne 'completed' -or $event.workflow_run.status -ne 'completed') { throw 'Invalid completed workflow event.' }
    $RunId=[string]$event.workflow_run.id
    $RunAttempt=[int]$event.workflow_run.run_attempt
    if ($RunAttempt -lt 1) { throw 'Invalid source attempt in event.' }
} elseif ($env:GITHUB_EVENT_NAME -ne 'workflow_dispatch') { throw 'Use workflow_run or manual workflow_dispatch.' }
if ($RunId -notmatch '^[1-9][0-9]*$') { throw 'Supply a numeric completed source run ID.' }
$runBase="$($context.Base)/actions/runs/$RunId"
if ($RunAttempt -eq 0) { $RunAttempt=[int](Invoke-SafeRequest -Uri $runBase -Headers $context.Headers).run_attempt }
$run=Invoke-SafeRequest -Uri "$runBase/attempts/$RunAttempt" -Headers $context.Headers
if ([string]$run.id -ne $RunId -or [int]$run.run_attempt -ne $RunAttempt -or $run.status -ne 'completed' -or $run.repository.full_name -cne $env:GITHUB_REPOSITORY) { throw 'Source run/attempt is not the requested completed run.' }
$excludedPaths=@('.github/workflows/nwb-cicd-collector.yml','.github/workflows/nwb-collector-health.yml','.github/workflows/nwb-workflow-monitor.yml','.github/workflows/nwb-workflow-monitor-auto.yml')
if (($run.path -split '@')[0] -in $excludedPaths) { Write-Output 'Monitoring workflow excluded from application metrics.'; return }
$config=Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($config.DefaultService)) { throw 'Configure DefaultService.' }
$workflowMappings=$null
if ($config.PSObject.Properties['WorkflowMappings']) { $workflowMappings=$config.WorkflowMappings }
$mapping=Get-NwbWorkflowMapping -Mappings $workflowMappings -Run $run
if ($null -eq $mapping) {
    # Every new workflow is still collected. Unknown does not mean production or CI.
    Write-Information "Discovered workflow '$($run.name)' ($($run.path)) from GitHub. No override configured; collecting raw workflow/job/step metadata with environment unclassified." -InformationAction Continue
    $service=[string]$config.DefaultService; $environment='unclassified'; $isDeployment=$false
} else {
    $value=$mapping.Value
    if ([string]::IsNullOrWhiteSpace($value.Service) -or [string]::IsNullOrWhiteSpace($value.Environment) -or $value.IsDeploymentPipeline -isnot [bool]) { throw 'Invalid workflow mapping: use service/environment and a JSON boolean.' }
    $service=[string]$value.Service; $environment=[string]$value.Environment; $isDeployment=[bool]$value.IsDeploymentPipeline
}
$failures=@()
$failedComponents=@()
foreach($flag in @('CollectPipelineExecution','PublishHealth')){
    if($config.PSObject.Properties[$flag] -and $config.$flag -isnot [bool]){throw "Configuration $flag must be a JSON boolean."}
}
# Try both independently: an Azure workflow-table failure must not suppress deployment collection.
try {
    & (Join-Path $PSScriptRoot 'Send-WorkflowRun.ps1') -RunId $RunId -RunAttempt $RunAttempt -Service $service -Environment $environment -IsDeploymentPipeline $isDeployment -Publish:$Publish
} catch { $failedComponents+='workflow';$failures+='Workflow collection: '+$_.Exception.Message }
if($config.PSObject.Properties['CollectPipelineExecution'] -and $config.CollectPipelineExecution){
    try {
        $stageMappings=[pscustomobject]@{}
        if($config.PSObject.Properties['StageMappings']){$stageMappings=$config.StageMappings}
        & (Join-Path $PSScriptRoot 'Send-PipelineExecution.ps1') -Run $run -Service $service -Environment $environment -StageMappings $stageMappings -Publish:$Publish
    } catch {$failedComponents+='execution';$failures+='Pipeline execution: '+$_.Exception.Message}
}
try {
    & (Join-Path $PSScriptRoot 'Send-RunDeployments.ps1') -Run $run -EnvironmentMappings $config.DeploymentEnvironments -ExpectDeployment $isDeployment -Publish:$Publish
} catch { $failedComponents+='deployment';$failures+='Deployment collection: '+$_.Exception.Message }
if($Publish -and $config.PSObject.Properties['PublishHealth'] -and $config.PublishHealth){
    try {
        . (Join-Path $PSScriptRoot 'CollectorHealth.ps1')
        $outcome='success';if($failures.Count){$outcome='failure'}
        $health=New-NwbHealthRecord -Operation collection -Outcome $outcome -SourceRunId $RunId -SourceRunAttempt $RunAttempt -DetailCode ($failedComponents -join ',')
        Send-NwbRecords -Records @($health) -DcrId $env:AZURE_HEALTH_DCR_IMMUTABLE_ID -Table NWBCollectorHealth_CL
    }catch{$failures+='Health publication: '+$_.Exception.Message}
}
if ($failures.Count -gt 0) { throw ($failures -join ' | ') }
Write-Output "Completed collection for run $RunId attempt $RunAttempt."
