[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$MappingPath,
    [switch]$Publish
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'NwbRepository.ps1')
$repository=Get-NwbRepository
if ($env:GITHUB_EVENT_NAME -ne 'workflow_run' -or -not $env:GITHUB_EVENT_PATH) {
    throw 'This entry point requires a workflow_run event.'
}
$event = Get-Content -LiteralPath $env:GITHUB_EVENT_PATH -Raw | ConvertFrom-Json
if ($event.action -ne 'completed' -or $event.workflow_run.status -ne 'completed') {
    throw 'Only completed workflow_run events are supported.'
}
if ($event.repository.full_name -cne $repository) {
    throw 'Unexpected event repository.'
}
$workflowId = [string]$event.workflow_run.workflow_id
if ($workflowId -notmatch '^[1-9][0-9]*$') { throw 'Invalid source workflow ID.' }
$mappings = Get-Content -LiteralPath $MappingPath -Raw | ConvertFrom-Json
$property = $mappings.PSObject.Properties[$workflowId]
if ($null -eq $property) { throw "No reviewed mapping exists for workflow ID $workflowId." }
$mapping = $property.Value
if ([string]::IsNullOrWhiteSpace($mapping.Service) -or $mapping.Service -like 'REPLACE_*' -or
    [string]::IsNullOrWhiteSpace($mapping.Environment) -or $mapping.Environment -like 'REPLACE_*' -or
    $mapping.IsDeploymentPipeline -isnot [bool]) {
    throw 'Configure service, environment and a JSON boolean deployment-pipeline flag.'
}
$attempt = [int]$event.workflow_run.run_attempt
if ($attempt -lt 1) { throw 'Event does not identify a valid source attempt.' }
# Read source metadata only. Never check out or execute the source run's commit,
# download its artifacts, or evaluate values from its job names or logs as code.
$options = @{
    RunId = [string]$event.workflow_run.id
    RunAttempt = $attempt
    Service = [string]$mapping.Service
    Environment = [string]$mapping.Environment
    IsDeploymentPipeline = [bool]$mapping.IsDeploymentPipeline
    Publish = $Publish
}
& (Join-Path $PSScriptRoot 'Send-WorkflowRun.ps1') @options
