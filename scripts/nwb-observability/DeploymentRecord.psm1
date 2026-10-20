Set-StrictMode -Version Latest

function ConvertTo-DeploymentRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Deployment, [Parameter(Mandatory)]$SuccessStatus,
        [Parameter(Mandatory)]$Run, [Parameter(Mandatory)]$Mapping,
        [datetimeoffset]$ObservedAt = [datetimeoffset]::UtcNow)
    if ($SuccessStatus.state -ne 'success') { throw 'Only confirmed successful deployments become deployment facts.' }
    if ([string]$Deployment.id -notmatch '^[1-9][0-9]*$') { throw 'Invalid deployment ID.' }
    if ($Run.repository.full_name -cne 'northwest/doc_extraction' -or $Deployment.sha -cne $Run.head_sha) { throw 'Deployment repository/commit does not match the run.' }
    $expectedRun = 'https://northwest.ghe.com/northwest/doc_extraction/actions/runs/' + [string]$Run.id
    if ($Run.html_url -cne $expectedRun) { throw 'Unexpected source run URL.' }
    # The status must identify this run, optionally a job within it. A commit alone is not enough.
    $pattern = '^' + [regex]::Escape($expectedRun) + '(/job/[0-9]+|/attempts/[0-9]+)?/?$'
    if ([string]$SuccessStatus.log_url -cnotmatch $pattern) { throw 'Deployment status does not link to this workflow run.' }
    if ($Mapping.SuccessMeansDeployed -isnot [bool] -or -not $Mapping.SuccessMeansDeployed -or
        $Mapping.Production -isnot [bool] -or [string]::IsNullOrWhiteSpace($Mapping.Service) -or
        [string]::IsNullOrWhiteSpace($Mapping.Environment)) { throw 'Deployment environment needs a reviewed success/production/service mapping.' }
    if ($Deployment.PSObject.Properties['production_environment'] -and
        $Deployment.production_environment -ne $Mapping.Production) { throw 'GitHub production flag conflicts with the reviewed environment mapping.' }
    $deployedAt = [datetimeoffset]$SuccessStatus.created_at
    if ($deployedAt -gt $ObservedAt.AddMinutes(5) -or $deployedAt -lt [datetimeoffset]$Deployment.created_at) { throw 'Invalid deployment success timestamp.' }
    [pscustomobject][ordered]@{
        TimeGenerated=$ObservedAt.UtcDateTime.ToString('o'); UpdatedAt=$ObservedAt.UtcDateTime.ToString('o')
        Service=[string]$Mapping.Service; Environment=[string]$Mapping.Environment
        DeploymentId=('northwest/doc_extraction:github-deployment:' + [string]$Deployment.id)
        Repository='northwest/doc_extraction'; PipelineName=[string]$Run.name
        CommitSha=[string]$Deployment.sha; RevisionName=''; ImageDigest=''
        PromotionStage='github-deployment-success'; RunUrl=$expectedRun
        DeployedAt=$deployedAt.UtcDateTime.ToString('o'); ReachedProduction=[bool]$Mapping.Production
        # Successful release does not establish whether later intervention/rework was needed.
        ClassificationKnown=$false; RequiresIntervention=$false
        ReworkClassificationKnown=$false; IsRework=$false
    }
}
Export-ModuleMember -Function ConvertTo-DeploymentRecord
