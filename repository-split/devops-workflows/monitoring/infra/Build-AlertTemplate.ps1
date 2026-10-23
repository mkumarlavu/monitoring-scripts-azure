[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
# Generates a reviewable local template only. Does not connect to Azure.
$queryRoot=Join-Path $PSScriptRoot '../queries'
$definitions=@(
    @{Name='collector-heartbeat-missing';File='alert-heartbeat-missing.kql';Severity=2},
    @{Name='collector-failed';File='alert-collector-failed.kql';Severity=2},
    @{Name='selected-workflow-failed';File='alert-selected-workflows.kql';Severity=2}
)
$resources=@()
foreach($definition in $definitions){
    # Read a plain string: PS5.1 Get-Content adds provider metadata that can expand
    # recursively when the containing template is serialized at high depth.
    $query=[IO.File]::ReadAllText((Join-Path $queryRoot $definition.File))
    $escaped=$query.Replace("'","''")
    $expression="replace('$escaped', '__NWB_REPOSITORY__', parameters('repository'))"
    if($definition.Name -eq 'selected-workflow-failed'){
        # ARM inserts the reviewed workflow path array as a JSON dynamic literal.
        $expression="replace($expression, 'dynamic([])', concat('dynamic(', string(parameters('selectedWorkflowPaths')), ')'))"
    }
    $query="[$expression]"
    $resources+= [ordered]@{
        type='Microsoft.Insights/scheduledQueryRules';apiVersion='2023-12-01'
        name="[concat(parameters('namePrefix'), '-$($definition.Name)')]"
        location="[parameters('location')]";kind='LogAlert'
        properties=[ordered]@{
            displayName=('NWB '+$definition.Name)
            description='CI/CD monitoring draft. Review ownership, thresholds and routing before enabling.'
            enabled=$false;severity=$definition.Severity;autoMitigate=$true
            evaluationFrequency='PT5M';windowSize='PT1H';overrideQueryTimeRange='PT2H'
            scopes=@("[parameters('workspaceResourceId')]");skipQueryValidation=$false
            actions=@{actionGroups="[parameters('actionGroupIds')]"}
            criteria=@{allOf=@(@{query=$query;timeAggregation='Count';operator='GreaterThan';threshold=0
                failingPeriods=@{numberOfEvaluationPeriods=2;minFailingPeriodsToAlert=2}})}
        }
    }
}
$template=[ordered]@{
    '$schema'='https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
    contentVersion='1.0.0.0'
    parameters=[ordered]@{
        namePrefix=@{type='string';defaultValue='prd-cicdobservability-doc-extraction'}
        repository=@{type='string';defaultValue='northwest/doc_extraction'}
        location=@{type='string';defaultValue='eastus2'}
        workspaceResourceId=@{type='string'}
        actionGroupIds=@{type='array';defaultValue=@()}
        selectedWorkflowPaths=@{type='array';defaultValue=@()}
    }
    resources=$resources
}
$template | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'alerts-disabled.json') -Encoding UTF8
Write-Output 'Generated alerts-disabled.json. All three rules are disabled; nothing was deployed.'
