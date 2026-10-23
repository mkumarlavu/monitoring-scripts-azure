Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'NwbRepository.ps1')

function ConvertTo-WorkflowRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Run,
        [AllowEmptyCollection()][object[]]$Jobs = @(),
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Service,
        [Parameter(Mandatory)][string]$Environment,
        [bool]$IsDeploymentPipeline = $false,
        [datetimeoffset]$ObservedAt = [datetimeoffset]::UtcNow
    )
    $Repository=Get-NwbRepository -Repository $Repository
    if ($Run.status -ne 'completed') { throw 'Only completed workflow attempts are supported by this first version.' }
    if ([string]::IsNullOrWhiteSpace($Run.conclusion)) { throw 'Completed run has no conclusion.' }
    if ($Run.repository.full_name -cne $Repository) { throw 'Source repository does not match the configured repository.' }
    if ([string]$Run.id -notmatch '^[1-9][0-9]*$' -or [int]$Run.run_attempt -lt 1) { throw 'Invalid run or attempt ID.' }
    if ([string]::IsNullOrWhiteSpace($Service) -or [string]::IsNullOrWhiteSpace($Environment)) { throw 'Service and environment mapping must be configured.' }
    $runUri = [uri]$Run.html_url
    if ($runUri.Scheme -ne 'https' -or $runUri.Host -ne 'northwest.ghe.com' -or
        $runUri.AbsolutePath -ne "/$Repository/actions/runs/$($Run.id)" -or $runUri.UserInfo) {
        throw 'Unexpected source run URL.'
    }

    # This is the execution window across jobs in this attempt, NOT end-to-end
    # elapsed workflow time. Queue/approval waits before the first job are excluded.
    $started = $null; $completed = $null; $duration = $null
    $activeJobs = @($Jobs | Where-Object { $_.conclusion -ne 'skipped' })
    $completeTiming = $activeJobs.Count -gt 0
    $starts = @(); $ends = @()
    foreach ($job in $activeJobs) {
        if ($job.status -ne 'completed' -or -not $job.started_at -or -not $job.completed_at) {
            $completeTiming = $false
            continue
        }
        $start = [datetimeoffset]$job.started_at
        $end = [datetimeoffset]$job.completed_at
        if ($end -lt $start) { throw 'Job completion precedes job start.' }
        $starts += $start; $ends += $end
    }
    if ($completeTiming) {
        $first = $starts | Sort-Object | Select-Object -First 1
        $last = $ends | Sort-Object | Select-Object -Last 1
        $started = $first.UtcDateTime.ToString('o')
        $completed = $last.UtcDateTime.ToString('o')
        $duration = [int][math]::Floor(($last - $first).TotalSeconds)
    }
    return [pscustomobject][ordered]@{
        TimeGenerated = $ObservedAt.UtcDateTime.ToString('o')
        UpdatedAt = $ObservedAt.UtcDateTime.ToString('o')
        Service = $Service
        Environment = $Environment
        Repository = $Repository
        PipelineName = [string]$Run.name
        WorkflowPath = [string]$Run.path
        RunId = [string]$Run.id
        RunAttempt = [int]$Run.run_attempt
        CommitSha = [string]$Run.head_sha
        RunUrl = [string]$Run.html_url
        Conclusion = [string]$Run.conclusion
        StartedAt = $started
        CompletedAt = $completed
        DurationSeconds = $duration
        QueueSeconds = $null
        IsDeploymentPipeline = $IsDeploymentPipeline
    }
}
Export-ModuleMember -Function ConvertTo-WorkflowRecord
