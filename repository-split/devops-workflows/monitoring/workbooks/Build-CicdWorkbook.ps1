[CmdletBinding()]
param(
    [string]$WorkspaceResourceId = '/subscriptions/18af3db6-624c-4522-9319-35501eb3fac0/resourceGroups/prd-cicdobservability-rg-eus2/providers/Microsoft.OperationalInsights/workspaces/prd-cicdobservability-law-eus2',
    [string]$OutputPath = (Join-Path $PSScriptRoot 'nwb-cicd-monitoring.workbook.json')
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($WorkspaceResourceId -notmatch '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.OperationalInsights/workspaces/[^/]+$') {
    throw 'Supply the full Log Analytics workspace resource ID.'
}
$items = [System.Collections.Generic.List[object]]::new()
function Add-Text([string]$Name, [string]$Text) {
    $items.Add(@{type=1; name=$Name; content=@{json=$Text}})
}
function Add-Query([string]$Name, [string]$Title, [string]$Query, [string]$Visual='table', [bool]$RunLinks=$false) {
    $content = [ordered]@{
        # Full/content height for grids and tiles avoids a fixed empty panel below short results.
        version='KqlItem/1.0'; title=$Title; query=$Query; size=3
        queryType=0; resourceType='microsoft.operationalinsights/workspaces'
        crossComponentResources=@($WorkspaceResourceId)
        timeContextFromParameter='TimeRange'; visualization=$Visual
        showRefreshButton=$true; showExportToExcel=$true
        noDataMessage='No matching observations. Check the filters and collection status; no data does not mean healthy.'
    }
    if ($Visual -eq 'timechart') { $content.size=0 }
    switch ($Name) {
        'failed-runs' { $content.noDataMessage='No failed or timed-out attempts in the collected records for these filters. Check Workflow attempts above to confirm there is data.' }
        'execution-failures' { $content.noDataMessage='No failed or timed-out jobs or steps in the collected records for these filters. Check the Jobs and Steps totals above.' }
        'deployments' { $content.noDataMessage='No confirmed deployment records in this selection. Validate deployment evidence and environment mappings with the application team.' }
        'health-summary' { $content.noDataMessage='No collector health observations in this selection. Scheduled heartbeat monitoring is not yet verified.' }
        'health-detail' { $content.noDataMessage='No collector health observations in this selection. Check health publication and the collection window.' }
    }
    if ($Visual -eq 'tiles') {
        $content.tileSettings=@{
            titleContent=@{columnMatch='Metric'}
            leftContent=@{columnMatch='Value'; formatter=12}
            subtitleContent=@{columnMatch='Detail'}
            showBorder=$true; size='auto'
        }
    }
    if ($RunLinks) {
        $content.gridSettings=@{formatters=@(@{
            columnMatch='RunUrl'; formatter=1
            formatOptions=@{linkTarget='Url'; linkLabel='Open in GitHub'}
        }); rowLimit=250; filter=$true}
    }
    $items.Add(@{type=3; name=$Name; content=$content; showPin=$true})
}

Add-Text 'intro' @'
# Northwest CI/CD monitoring
Workflow results, jobs and steps collected from GitHub. Start with the summary, then open a run in GitHub to investigate.

**Reporting window = collection time (UTC).** Historical runs replayed today appear today. Counts describe observed attempts, not all GitHub activity or production deployment frequency. Repeated observations are deduplicated within the selected window; separate rerun attempts remain separate.

The daily chart includes zero-observation days. Zero means nothing was collected for that day in this selection; it does not prove that no workflow ran. Review small samples before treating success rates or percentiles as a baseline.
'@
$parameters=@(
    @{id='time-range'; version='KqlParameterItem/1.0'; name='TimeRange'; label='Collected during'; type=4; isRequired=$true
      value=@{durationMs=604800000}; typeSettings=@{selectableValues=@(@{durationMs=3600000},@{durationMs=86400000},@{durationMs=604800000},@{durationMs=2592000000}); allowCustom=$true}},
    @{id='repository'; version='KqlParameterItem/1.0'; name='Repository'; label='Repository (exact name or *)'; type=1; isRequired=$true; value='northwest/doc_extraction'},
    @{id='workflow'; version='KqlParameterItem/1.0'; name='Workflow'; label='Workflow name (exact name or *)'; type=1; isRequired=$true; value='*'},
    @{id='environment'; version='KqlParameterItem/1.0'; name='Environment'; label='Environment (exact name or *)'; type=1; isRequired=$true; value='*'}
)
$items.Add(@{type=9; name='filters'; content=@{version='KqlParameterItem/1.0'; parameters=$parameters; style='above'; queryType=0; resourceType='microsoft.operationalinsights/workspaces'}})

# Base64 formatting keeps quotes and other user-entered text out of the KQL syntax.
$scope=@'
let selectedRepository = base64_decode_tostring('{Repository:base64}');
let selectedWorkflow = base64_decode_tostring('{Workflow:base64}');
let selectedEnvironment = base64_decode_tostring('{Environment:base64}');
'@
$filters=@'
| where selectedRepository == '*' or Repository == selectedRepository
| where selectedWorkflow == '*' or PipelineName == selectedWorkflow
| where selectedEnvironment == '*' or Environment == selectedEnvironment
'@
$workflowBase=$scope+@'

let W = NWBWorkflowRuns_CL
| where TimeGenerated {TimeRange}
| summarize arg_max(UpdatedAt, *) by Repository, RunId, RunAttempt
'@+"`n"+$filters+";`n"
$executionBase=$scope+@'

let E = NWBPipelineExecution_CL
| where TimeGenerated {TimeRange}
| summarize arg_max(UpdatedAt, *) by Repository, RunId, RunAttempt, JobId, RecordType, StepNumber
'@+"`n"+$filters+";`n"

Add-Text 'workflow-explanation' @'
## Workflow results
Success rate uses all collected attempts as its denominator, including cancelled, skipped and timed-out outcomes. Execution duration is the job execution window; it excludes queue and approval waiting before the first job. Unknown durations remain unknown.
'@
Add-Query 'workflow-kpis' 'Workflow summary' ($workflowBase+@'
W
| summarize Attempts=count(), Succeeded=countif(Conclusion == 'success'),
    Failed=countif(Conclusion == 'failure'), TimedOut=countif(Conclusion == 'timed_out'),
    Cancelled=countif(Conclusion == 'cancelled'), Skipped=countif(Conclusion == 'skipped'),
    Other=countif(Conclusion !in ('success','failure','timed_out','cancelled','skipped')),
    KnownDurations=countif(isnotnull(DurationSeconds)),
    P50=percentile(DurationSeconds,50), P95=percentile(DurationSeconds,95),
    Unclassified=countif(isempty(Environment) or Environment == 'unclassified')
| extend SuccessRate=iff(Attempts == 0, real(null), 100.0 * Succeeded / Attempts)
| project Tiles=pack_array(
    bag_pack('Metric','Workflow attempts','Value',tostring(Attempts),'Detail','Distinct run ID + attempt'),
    bag_pack('Metric','Succeeded','Value',tostring(Succeeded),'Detail','Successful attempts'),
    bag_pack('Metric','Failed','Value',tostring(Failed),'Detail','Failure conclusion'),
    bag_pack('Metric','Timed out','Value',tostring(TimedOut),'Detail','Timed-out conclusion'),
    bag_pack('Metric','Cancelled','Value',tostring(Cancelled),'Detail','Separate from failures'),
    bag_pack('Metric','Skipped','Value',tostring(Skipped),'Detail','Separate from successes'),
    bag_pack('Metric','Other outcomes','Value',tostring(Other),'Detail','Neutral, action required or other'),
    bag_pack('Metric','Success rate','Value',iff(isnull(SuccessRate),'No data',strcat(round(SuccessRate,1),'%')),'Detail','Succeeded / all observed attempts'),
    bag_pack('Metric','P50 execution seconds','Value',iff(isnull(P50),'No data',tostring(round(P50,1))),'Detail','Known job-window durations only'),
    bag_pack('Metric','P95 execution seconds','Value',iff(isnull(P95),'No data',tostring(round(P95,1))),'Detail','Small samples are not a baseline'),
    bag_pack('Metric','Missing durations','Value',tostring(Attempts-KnownDurations),'Detail','Not substituted with zero'),
    bag_pack('Metric','Unclassified environment','Value',tostring(Unclassified),'Detail','Repository mapping still needed'))
| mv-expand Tiles
| project Metric=tostring(Tiles.Metric), Value=tostring(Tiles.Value), Detail=tostring(Tiles.Detail)
'@) 'tiles'
Add-Query 'outcome-trend' 'Observed attempts by collection day and outcome (UTC)' ($workflowBase+@'
W
| make-series Attempts=count() default=0 on TimeGenerated
    from startofday({TimeRange:start}) to {TimeRange:end} step 1d by Conclusion
| mv-expand TimeGenerated to typeof(datetime), Attempts to typeof(long)
| order by TimeGenerated asc
'@) 'timechart'
Add-Query 'workflow-comparison' 'Workflow comparison' ($workflowBase+@'
W
| summarize Attempts=count(), Succeeded=countif(Conclusion == 'success'),
    FailedOrTimedOut=countif(Conclusion in ('failure','timed_out')),
    P50Seconds=percentile(DurationSeconds,50), P95Seconds=percentile(DurationSeconds,95)
    by Repository, PipelineName, Environment
| extend SuccessRatePercent=round(100.0 * Succeeded / Attempts,1)
| order by FailedOrTimedOut desc, Attempts desc
'@)
Add-Query 'recent-runs' 'Latest collected attempts (maximum 100)' ($workflowBase+@'
W
| top 100 by TimeGenerated desc
| project CollectedAt=TimeGenerated, Repository, PipelineName, Environment, RunId, RunAttempt,
    Conclusion, CompletedAt, DurationSeconds, RunUrl
'@) 'table' $true
Add-Query 'failed-runs' 'Failed or timed-out application attempts (maximum 100)' ($workflowBase+@'
W
| where Conclusion in ('failure','timed_out')
| top 100 by TimeGenerated desc
| project CollectedAt=TimeGenerated, Repository, PipelineName, Environment, RunId, RunAttempt,
    Conclusion, CompletedAt, DurationSeconds, RunUrl
'@) 'table' $true

Add-Text 'execution-explanation' @'
## Jobs, steps and stage coverage
Job and step records are separate levels: do not add their counts or durations together. Parallel job durations are not end-to-end workflow duration. Stage labels require reviewed mappings; `unmapped` is a data-quality gap, not a pipeline failure. A skipped job is not a failed job.
'@
Add-Query 'execution-kpis' 'Jobs and steps' ($executionBase+@'
E
| summarize Jobs=countif(RecordType == 'Job'), Steps=countif(RecordType == 'Step'),
    FailedJobs=countif(RecordType == 'Job' and Conclusion in ('failure','timed_out')),
    SkippedJobs=countif(RecordType == 'Job' and Conclusion == 'skipped'),
    FailedSteps=countif(RecordType == 'Step' and Conclusion in ('failure','timed_out')),
    MappedJobs=countif(RecordType == 'Job' and StageMappingKnown == true),
    MappedSteps=countif(RecordType == 'Step' and StageMappingKnown == true),
    MissingJobDurations=countif(RecordType == 'Job' and isnull(DurationSeconds))
| project Tiles=pack_array(
    bag_pack('Metric','Jobs','Value',tostring(Jobs),'Detail','Unique job per run attempt'),
    bag_pack('Metric','Steps','Value',tostring(Steps),'Detail','Unique step number per job'),
    bag_pack('Metric','Failed / timed-out jobs','Value',tostring(FailedJobs),'Detail','Job outcomes'),
    bag_pack('Metric','Skipped jobs','Value',tostring(SkippedJobs),'Detail','Not counted as failures'),
    bag_pack('Metric','Failed / timed-out steps','Value',tostring(FailedSteps),'Detail','May belong to the same failed job'),
    bag_pack('Metric','Job stage coverage','Value',iff(Jobs == 0,'No data',strcat(round(100.0*MappedJobs/Jobs,1),'%')),'Detail','Jobs with a known mapping'),
    bag_pack('Metric','Step stage coverage','Value',iff(Steps == 0,'No data',strcat(round(100.0*MappedSteps/Steps,1),'%')),'Detail','Steps with a known mapping'),
    bag_pack('Metric','Jobs without duration','Value',tostring(MissingJobDurations),'Detail','Includes skipped jobs with no timing'))
| mv-expand Tiles
| project Metric=tostring(Tiles.Metric), Value=tostring(Tiles.Value), Detail=tostring(Tiles.Detail)
'@) 'tiles'
Add-Query 'slow-jobs' 'Slowest jobs by P95 duration (seconds; top 20)' ($executionBase+@'
E
| where RecordType == 'Job' and isnotnull(DurationSeconds)
| summarize Observations=count(), P50Seconds=percentile(DurationSeconds,50),
    P95Seconds=percentile(DurationSeconds,95), MaxSeconds=max(DurationSeconds)
    by Repository, PipelineName, JobName
| top 20 by P95Seconds desc
'@)
Add-Query 'slow-steps' 'Slowest steps by P95 duration (seconds; top 20)' ($executionBase+@'
E
| where RecordType == 'Step' and isnotnull(DurationSeconds)
| summarize Observations=count(), P50Seconds=percentile(DurationSeconds,50),
    P95Seconds=percentile(DurationSeconds,95), MaxSeconds=max(DurationSeconds)
    by Repository, PipelineName, JobName, StepName
| top 20 by P95Seconds desc
'@)
Add-Query 'execution-failures' 'Failed or timed-out jobs and steps (maximum 100)' ($executionBase+@'
E
| where Conclusion in ('failure','timed_out')
| top 100 by TimeGenerated desc
| project Repository, PipelineName, RunId, RunAttempt, RecordType, JobName,
    StepName, Stage, Conclusion, DurationSeconds, RunUrl
'@) 'table' $true
Add-Query 'stage-results' 'Stage outcomes (jobs and steps reported separately)' ($executionBase+@'
E
| summarize Observations=count(), Succeeded=countif(Conclusion == 'success'),
    FailedOrTimedOut=countif(Conclusion in ('failure','timed_out')),
    Skipped=countif(Conclusion == 'skipped') by RecordType, Stage, StageMappingKnown
| order by RecordType asc, Stage asc
'@)
Add-Query 'mapping-inventory' 'Names available for stage mapping (maximum 250)' ($executionBase+@'
E
| summarize Observations=count() by WorkflowPath, RecordType, JobName, StepName, Stage, StageMappingKnown
| order by WorkflowPath asc, JobName asc, RecordType asc, StepName asc
| take 250
'@)

Add-Text 'health-explanation' @'
## Collector health
This section uses the repository and collection-time filters only. It intentionally ignores workflow and environment filters because the health schema has neither field. A recent collection result is not proof that scheduled heartbeats are enabled. No heartbeat data means not verified; it must not be displayed as healthy. The timestamp is the last observation in the selected window.
'@
$healthBase=@'
let selectedRepository = base64_decode_tostring('{Repository:base64}');
let H = NWBCollectorHealth_CL
| where TimeGenerated {TimeRange}
| summarize arg_max(UpdatedAt, *) by Repository, Collector, CheckId
| where selectedRepository == '*' or Repository == selectedRepository;
'@
Add-Query 'health-summary' 'Collector observations and freshness' ($healthBase+@'

H
| summarize LastObserved=max(TimeGenerated), Observations=count(), FailureObservations=countif(Outcome == 'failure')
    by Repository, Collector, Operation
| extend MinutesSinceLastObservation=datetime_diff('minute',now(),LastObserved)
| order by LastObserved desc
'@)
Add-Query 'health-detail' 'Latest collector observations (maximum 50)' ($healthBase+@'

H
| top 50 by TimeGenerated desc
| project TimeGenerated, Repository, Operation, Outcome, DetailCode, SourceRunId,
    SourceRunAttempt, CollectorRunId
'@)

Add-Text 'deployment-explanation' @'
## Confirmed deployments and DORA readiness
The table below shows deployment evidence already collected, deduplicated by repository and deployment ID. An empty result means no evidence in this scope; it does not prove that no deployment occurred. `IsDeploymentPipeline=false` on an unclassified workflow is not proof either.

Production deployment frequency, change lead time, change failure rate, failed deployment recovery time and rework metrics are **not yet validated**. They need reviewed production mappings, linked changes and incident/rework evidence. A successful build or Dev deployment alone does not establish these metrics. Detailed Sonar/Snyk findings and ServiceNow incident creation are also outside this dashboard's current data coverage.
'@
$deploymentBase=$scope+@'

let D = NWBDeploymentFacts_CL
| where TimeGenerated {TimeRange}
| summarize arg_max(UpdatedAt, *) by Repository, DeploymentId
'@+"`n"+$filters+";`n"
Add-Query 'deployments' 'Confirmed deployment facts collected in the window (maximum 100)' ($deploymentBase+@'
D
| top 100 by DeployedAt desc
| project DeployedAt, CollectedAt=TimeGenerated, Repository, Service, Environment,
    DeploymentId, PipelineName, ReachedProduction, ClassificationKnown,
    ReworkClassificationKnown, CommitSha, RunUrl
'@) 'table' $true
Add-Text 'footer' 'Missing data: confirm collection is enabled, publishing succeeded, the DCR routes to this workspace, and the selected collection window includes the records. This workbook reads existing data; it does not enable collection, create alerts or deploy applications.'

$workbook=[ordered]@{
    version='Notebook/1.0'; items=@($items.ToArray()); isLocked=$false
    fallbackResourceIds=@($WorkspaceResourceId)
    '$schema'='https://github.com/Microsoft/Application-Insights-Workbooks/blob/master/schema/workbook.json'
}
$json=$workbook | ConvertTo-Json -Depth 60
[System.IO.File]::WriteAllText($OutputPath, $json+"`n", [System.Text.UTF8Encoding]::new($false))
Write-Output "Created $OutputPath"
