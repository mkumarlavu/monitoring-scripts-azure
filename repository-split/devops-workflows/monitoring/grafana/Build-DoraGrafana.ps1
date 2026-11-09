[CmdletBinding()]
param(
    [string]$WorkbookPath=(Join-Path $PSScriptRoot '../workbooks/nwb-cicd-monitoring.workbook.json'),
    [string]$OutputPath=(Join-Path $PSScriptRoot 'nwb-dora-monitoring.grafana.json')
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$workbook=Get-Content -LiteralPath $WorkbookPath -Raw | ConvertFrom-Json
$workspace=$workbook.fallbackResourceIds[0]
$source=@{type='grafana-azure-monitor-datasource';uid='${DS_AZURE_MONITOR}'}
$panels=[System.Collections.Generic.List[object]]::new()
$script:panelId=0

# Deduplicate BEFORE event-time filtering: later classifications update old deployments.
# All available retained observations are eligible. Retention still limits completeness.
$scope=@'
let repo = @${Repository:sqlstring};
let service = @${Service:sqlstring};
let windowStart = $__timeFrom();
let windowEnd = $__timeTo();
let days = max_of(1.0 / 24.0, (windowEnd - windowStart) / 1d);
'@
$deployments=$scope+@'

let D = materialize(NWBDeploymentFacts_CL
| summarize arg_max(UpdatedAt, *) by Repository, DeploymentId
| where (repo == '*' or Repository == repo) and (service == '*' or Service == service)
| where ReachedProduction == true
| where DeployedAt between (windowStart .. windowEnd));
'@
$changes=$deployments+@'

let C = materialize(NWBChangeFacts_CL
| summarize arg_max(UpdatedAt, *) by Service, Environment, ChangeId
| join kind=inner (D | project Repository, DeploymentId, Service, Environment, DeployedAt, RunUrl) on DeploymentId, Service, Environment
| where isnotempty(ChangeId) and isnotnull(CommitAt) and isnotnull(FirstDeployedAt)
| where FirstDeployedAt >= CommitAt and FirstDeployedAt between (windowStart .. windowEnd)
| extend LeadSeconds = (FirstDeployedAt - CommitAt) / 1s);
'@
$incidents=$deployments+@'

let I = materialize(NWBIncidentFacts_CL
| summarize arg_max(UpdatedAt, *) by Service, Environment, IncidentId
| where DeploymentRelated == true and isnotempty(IncidentId)
| join kind=inner (D | project Repository, DeploymentId, Service, Environment, DeployedAt, RunUrl) on DeploymentId, Service, Environment
| extend ValidRecovery = isnotnull(FailureStartedAt) and FailureStartedAt >= DeployedAt and isnotnull(RestoredAt) and RestoredAt >= FailureStartedAt and RestoredAt <= now()
| extend RecoverySecondsCalculated = iff(ValidRecovery, (RestoredAt - FailureStartedAt) / 1s, real(null)));
'@
$workflows=$scope+@'

let run = @${RunId:sqlstring};
let W = materialize(NWBWorkflowRuns_CL
| summarize arg_max(UpdatedAt, *) by Repository, RunId, RunAttempt
| where (repo == '*' or Repository == repo) and (service == '*' or Service == service)
| extend SourceTime = coalesce(CompletedAt, todatetime(column_ifexists('SourceUpdatedAt', datetime(null))), TimeGenerated)
| where SourceTime between (windowStart .. windowEnd)
| where run == '*' or RunId == run
| extend Actor = tostring(column_ifexists('Actor', '')), TriggeringActor = tostring(column_ifexists('TriggeringActor', '')), RunNumber = tostring(column_ifexists('RunNumber', '')));
'@
$execution=$scope+@'

let run = @${RunId:sqlstring};
let E = materialize(NWBPipelineExecution_CL
| summarize arg_max(UpdatedAt, *) by Repository, RunId, RunAttempt, JobId, RecordType, StepNumber
| where (repo == '*' or Repository == repo) and (service == '*' or Service == service)
| where run == '*' or RunId == run
| extend SourceTime = coalesce(CompletedAt, StartedAt, TimeGenerated)
| where SourceTime between (windowStart .. windowEnd));
'@
$verification=$execution+@'

let V = materialize(E
| where StageMappingKnown == true
| where Stage in ('Post-deployment verification', 'Smoke test', 'Rollback verification'));
'@
function Add-Panel([string]$Title,[string]$Type,[string]$Query,[int]$X,[int]$Y,[int]$Width,[int]$Height,[string]$Description='',[string]$Unit='none') {
    $script:panelId++
    $p=[ordered]@{id=$script:panelId;title=$Title;type=$Type;description=$Description;gridPos=@{x=$X;y=$Y;w=$Width;h=$Height};datasource=$source}
    $p.targets=@(@{refId='A';datasource=$source;queryType='Azure Log Analytics';azureLogAnalytics=@{query=$Query;resources=@($workspace);resultFormat='table';mode='raw';dashboardTime=$false}})
    $p.fieldConfig=@{defaults=@{unit=$Unit;noValue='Not available';color=@{mode='palette-classic'};custom=@{filterable=$true}};overrides=@()}
    if($Type -eq 'table') {
        $p.fieldConfig.overrides+=@{matcher=@{id='byName';options='Result'};properties=@(
            @{id='mappings';value=@(@{type='value';options=@{
                success=@{text='Passed';color='green'};failure=@{text='Failed';color='red'}
                timed_out=@{text='Timed out';color='red'};skipped=@{text='Skipped';color='gray'}
                cancelled=@{text='Cancelled';color='orange'};action_required=@{text='Action required';color='orange'}
            }})}
        )}
    }
    foreach($urlField in @('RunUrl','IncidentUrl')) {
        $p.fieldConfig.overrides+=@{matcher=@{id='byName';options=$urlField};properties=@(@{id='links';value=@(@{title='Open source';url='${__value.raw}';targetBlank=$true})})}
    }
    $p.options=@{showHeader=$true;cellHeight='sm';footer=@{show=$false}}
    if($Type -eq 'stat') {$p.options=@{reduceOptions=@{calcs=@('lastNotNull');fields='';values=$false};textMode='value';colorMode='value';graphMode='none';justifyMode='center'}}
    if($Type -eq 'barchart') {$p.options=@{orientation='vertical';showValue='auto';stacking='normal';legend=@{displayMode='list';placement='bottom'}}}
    $panels.Add($p)
}
function Add-Text([string]$Title,[string]$Text,[int]$Y,[int]$Height=3) {
    $script:panelId++
    $panels.Add(@{id=$script:panelId;type='text';title=$Title;gridPos=@{x=0;y=$Y;w=24;h=$Height};options=@{mode='markdown';content=$Text}})
}

Add-Text 'Northwest | DORA and release investigation' '**1. Choose a repository and service. 2. Review production delivery. 3. Copy a Build / run ID into the RunId filter to investigate jobs and steps.**

DORA uses confirmed production deployments. RunId filters investigation panels only. Missing evidence shows **Not available**; it is not zero failures. Select one service for a meaningful baseline. Metrics cover retained evidence, not guaranteed complete activity.' 0 4

Add-Panel 'Deployments / day' 'stat' ($deployments+"`nD | summarize Deployments=count() | project Value=iff(Deployments > 0, Deployments / days, real(null))") 0 4 4 5 'Observed confirmed production deployments divided by selected elapsed days. No deployment evidence remains unknown.' 'short'
Add-Panel 'Change lead time | P50' 'stat' ($changes+"`nC | summarize Value=percentile(LeadSeconds, 50)") 4 4 5 5 'Median commit-to-first-production time for linked changes. P50: half of measured changes took this long or less. See coverage below; partial evidence is not a complete baseline.' 's'
Add-Panel 'Change fail rate' 'stat' ($deployments+@'

D | summarize Total=count(), Known=countif(ClassificationKnown == true and isnotnull(RequiresIntervention)), Failed=countif(ClassificationKnown == true and RequiresIntervention == true)
| project Value=iff(Total > 0 and Known == Total, 100.0 * Failed / Total, real(null))
'@) 9 4 5 5 'Production deployments requiring intervention / production deployments. Only shown when every observed deployment is classified. CI job failures are not deployment failures.' 'percent'
Add-Panel 'Failed deployment recovery | P50' 'stat' ($incidents+"`nI | where ValidRecovery | summarize Value=percentile(RecoverySecondsCalculated, 50)") 14 4 5 5 'Median recovery time for resolved deployment-related incidents linked to the selected production deployment cohort. Open/invalid recoveries are excluded and counted below.' 's'
Add-Panel 'Deployment rework rate' 'stat' ($deployments+@'

D | summarize Total=count(), Known=countif(ReworkClassificationKnown == true and isnotnull(IsRework)), Rework=countif(ReworkClassificationKnown == true and IsRework == true)
| project Value=iff(Total > 0 and Known == Total, 100.0 * Rework / Total, real(null))
'@) 19 4 5 5 'Unplanned production deployments to address production incidents / production deployments. Requires explicit rework classification for every observed deployment.' 'percent'

Add-Panel 'Production delivery by day' 'barchart' ($deployments+@'

D | make-series Deployments=count() default=0 on DeployedAt from startofday(windowStart) to (windowEnd + 1d) step 1d
| mv-expand Day=DeployedAt to typeof(datetime), Deployments to typeof(long)
| where Day <= windowEnd
| project Day, Deployments
'@) 0 9 12 8 'UTC deployment date, not collection date. Zero means no confirmed deployments observed that day; partial days are included.'
Add-Panel 'Evidence coverage | check before reporting' 'table' ($changes+@'

let ChangeDeployments=toscalar(C | summarize by Repository, DeploymentId | count);
D | summarize Deployments=count(), FailureClassified=countif(ClassificationKnown == true and isnotnull(RequiresIntervention)), ReworkClassified=countif(ReworkClassificationKnown == true and isnotnull(IsRework))
| extend DeploymentsWithLinkedChanges=ChangeDeployments
| extend Status=case(Deployments == 0, 'Awaiting production deployment evidence', FailureClassified < Deployments or ReworkClassified < Deployments or ChangeDeployments < Deployments, 'Partial evidence - review missing inputs', 'Review change and incident completeness with owners')
'@) 12 9 12 8 'Coverage is within observed deployments only. A linked change does not prove that all commits were captured. All events are limited by source ingestion and retention.'

Add-Panel 'Production delivery by service' 'table' ($deployments+@'

D | summarize Deployments=count(), FailureClassified=countif(ClassificationKnown == true and isnotnull(RequiresIntervention)), Interventions=countif(ClassificationKnown == true and RequiresIntervention == true), ReworkClassified=countif(ReworkClassificationKnown == true and isnotnull(IsRework)), Rework=countif(ReworkClassificationKnown == true and IsRework == true) by Repository, Service, Environment
| extend DeploymentsPerDay=round(Deployments / days, 2), ChangeFailRate=iff(FailureClassified == Deployments, 100.0 * Interventions / Deployments, real(null)), ReworkRate=iff(ReworkClassified == Deployments, 100.0 * Rework / Deployments, real(null))
| order by Repository asc, Service asc
'@) 0 17 24 7 'Compare services separately. Blank rates mean classification is incomplete.'

Add-Text 'Follow a workflow from start to finish' 'These panels include CI and non-production runs as well as releases. **Build / run ID** is GitHub RunId; RunNumber is the workflow-local display number. Actor started the original run; TriggeringActor initiated the attempt. Workflow success alone does not prove a deployment or a smoke test passed.' 24 3
Add-Panel 'Workflow results | all selected attempts' 'barchart' ($workflows+"`nW | summarize Attempts=count() by Conclusion | order by Attempts desc") 0 27 8 7 'One count per repository, run and attempt. Failed attempts remain visible after a successful retry.'
Add-Panel 'Run directory | repo, build, actor and result' 'table' ($workflows+@'

W | top 200 by SourceTime desc
| project Repository, Service, BuildRunId=RunId, RunNumber=iff(isempty(RunNumber), 'Not collected', RunNumber), RunAttempt, PipelineName, Actor=iff(isempty(Actor), 'Not collected', Actor), TriggeringActor=iff(isempty(TriggeringActor), 'Not collected', TriggeringActor), Result=Conclusion, Environment, StartedAt, CompletedAt, DurationSeconds, CommitSha, RunUrl
'@) 8 27 16 7 'Latest 200 attempts in the event window. RunUrl opens the source workflow. Actor fields need the additive schema update and a fresh collection/replay. SourceTime falls back to source update then collection time when completion is missing.'
Add-Panel 'Failed runs | start investigation here' 'table' ($workflows+@'

W | where Conclusion in ('failure', 'timed_out', 'action_required')
| top 100 by SourceTime desc
| project Repository, BuildRunId=RunId, RunAttempt, PipelineName, Actor=iff(isempty(Actor), 'Not collected', Actor), Result=Conclusion, CompletedAt, RunUrl
'@) 0 34 24 7 'Failures, timeouts and action-required results from collected workflow attempts. Cancelled and skipped are separate outcomes in the chart.'
Add-Panel 'Jobs | selected build / run' 'table' ($execution+@'

E | where RecordType == 'Job'
| top 200 by SourceTime desc
| project Repository, BuildRunId=RunId, RunAttempt, PipelineName, JobId, JobName, Stage, StageMappingKnown, Result=Conclusion, StartedAt, CompletedAt, DurationSeconds, RunUrl
'@) 0 41 24 7 'Set RunId to narrow to one build. Parallel job durations must not be added to estimate workflow duration. Unmapped means no reviewed stage label.'
Add-Panel 'Steps | tests, scans, deployment and verification' 'table' ($execution+@'

E | where RecordType == 'Step'
| top 500 by SourceTime desc
| project Repository, BuildRunId=RunId, RunAttempt, JobName, StepNumber, StepName, Stage, Result=Conclusion, StartedAt, CompletedAt, DurationSeconds, RunUrl
| order by BuildRunId asc, RunAttempt asc, JobName asc, StepNumber asc
'@) 0 48 24 9 'Latest 500 step observations, ordered within each job. Smoke/post-deployment checks appear only if the application workflow executes them. Step outcome is not individual test-case or vulnerability detail.'

Add-Text 'Production evidence behind the DORA metrics' 'Dates below use source events. Deployment facts are deduplicated by repository and deployment ID. Change and incident facts must link to that deployment ID, service and environment. Replaying a run does not create a new deployment.' 57 3
Add-Panel 'Confirmed production deployments' 'table' ($deployments+@'

let WR=NWBWorkflowRuns_CL
| summarize arg_max(UpdatedAt, *) by Repository, RunId, RunAttempt
| summarize arg_max(UpdatedAt, *) by Repository, RunUrl
| project Repository, RunUrl, BuildRunId=RunId, Actor=tostring(column_ifexists('Actor', ''));
D | join kind=leftouter WR on Repository, RunUrl
| top 200 by DeployedAt desc
| project DeployedAt, Repository, Service, Environment, DeploymentId, BuildRunId, Actor=iff(isempty(Actor), 'Not collected', Actor), CommitSha, ClassificationKnown, RequiresIntervention, ReworkClassificationKnown, IsRework, RunUrl
'@) 0 60 24 8 'Successful deployment evidence, not just a successful workflow. Actor comes from the latest observed workflow attempt for the linked URL; it is not an independent deployment audit identity.'
Add-Panel 'Change lead time | P50 and P95 by service' 'table' ($changes+@'

C | summarize LinkedChanges=count(), P50Seconds=percentile(LeadSeconds, 50), P95Seconds=percentile(LeadSeconds, 95) by Repository, Service
| order by Repository asc, Service asc
'@) 0 68 12 6 'P50 is the median. P95 means 95% of measured changes were this fast or faster. Small samples are not a reliable performance baseline.'
Add-Panel 'Recovery evidence | resolved and incomplete' 'table' ($incidents+@'

I | summarize LinkedIncidents=count(), ValidResolved=countif(ValidRecovery), OpenOrInvalid=countif(ValidRecovery == false), P50Seconds=percentile(RecoverySecondsCalculated, 50), P95Seconds=percentile(RecoverySecondsCalculated, 95) by Repository, Service
'@) 12 68 12 6 'Selected deployment cohort, with any observed recovery through now. Multiple incidents are separate observations. Open, missing and invalid recovery timestamps are excluded from percentiles.'
Add-Panel 'Linked changes | commit to first production' 'table' ($changes+@'

C | top 200 by FirstDeployedAt desc
| project Repository, Service, Environment, ChangeId, DeploymentId, CommitSha, CommitAt, FirstDeployedAt, LeadSeconds, RunUrl
'@) 0 74 24 7 'Only validated timestamp pairs linked to selected production deployments. Lead time is recomputed from timestamps, not a stored duration.'
Add-Panel 'Linked incidents | recovery and follow-up' 'table' ($incidents+@'

I | top 200 by FailureStartedAt desc
| project Repository, Service, Environment, IncidentId, DeploymentId, State, FailureStartedAt, RestoredAt, ValidRecovery, RecoverySecondsCalculated, IncidentUrl, RunUrl
'@) 0 81 24 7 'Read-only incident evidence. This dashboard neither raises ServiceNow tickets nor runs smoke tests.'
Add-Text 'What is ready?' '**CI/CD drilldown:** uses collected runs, jobs and steps. **DORA:** requires production mapping, complete linked changes, intervention/rework classification and incident recovery data. The current successful CI ingestion test alone does not validate DORA. See DORA-README.md for onboarding and acceptance checks.' 88 3

# Place verification immediately after the run/step investigation, ahead of DORA evidence.
foreach($panel in $panels) { if($panel.gridPos.y -ge 57) {$panel.gridPos.y += 29} }
Add-Text 'Post-deployment checks | did the release pass verification?' 'Checks must run in the application pipeline and have a reviewed stage mapping. Cards count **jobs**, not individual test cases. Step-only checks appear in the detail panels. A skipped check did not pass; missing checks remain unknown. RunId filters this section.' 57 3
Add-Panel 'Verification jobs observed' 'stat' ($verification+"`nV | where RecordType == 'Job' | summarize Total=count() | project Value=iff(Total > 0, Total, long(null))") 0 60 6 5 'Post-deployment verification, smoke-test and rollback-verification jobs in the selected source-event window. Observation does not prove that a deployment happened.' 'short'
Add-Panel 'Verification jobs failed / timed out' 'stat' ($verification+"`nV | where RecordType == 'Job' | summarize Total=count(), Failed=countif(Conclusion in ('failure', 'timed_out')) | project Value=iff(Total > 0, Failed, long(null))") 6 60 6 5 'Job failures and timeouts. Not a DORA change fail rate. Zero is shown only when at least one mapped verification job was observed.' 'short'
Add-Panel 'Verification jobs skipped' 'stat' ($verification+"`nV | where RecordType == 'Job' | summarize Total=count(), Skipped=countif(Conclusion == 'skipped') | project Value=iff(Total > 0, Skipped, long(null))") 12 60 6 5 'Skipped verification jobs have not executed their checks. Review workflow conditions in GitHub.' 'short'
Add-Panel 'Smoke-test jobs passed' 'stat' ($verification+"`nV | where RecordType == 'Job' and Stage == 'Smoke test' | summarize Total=count(), Passed=countif(Conclusion == 'success') | project Value=iff(Total > 0, Passed, long(null))") 18 60 6 5 'Successful jobs explicitly mapped to Smoke test. This is a job result, not the number of assertions or test cases passed.' 'short'
Add-Panel 'Verification outcomes | jobs' 'barchart' ($verification+"`nV | where RecordType == 'Job' | summarize Jobs=count() by Stage, Conclusion | extend CheckOutcome=strcat(Stage, ' / ', Conclusion) | project CheckOutcome, Jobs") 0 65 10 7 'Separate smoke, post-deployment and rollback verification results. Cancelled/skipped results are retained.'
Add-Panel 'Checks needing attention | jobs and steps' 'table' ($verification+@'

V | where Conclusion in ('failure', 'timed_out', 'action_required', 'cancelled', 'skipped')
| top 100 by SourceTime desc
| project Repository, BuildRunId=RunId, RunAttempt, RecordType, Stage, JobName, StepName, Result=Conclusion, CompletedAt, RunUrl
'@) 10 65 14 7 'Job and step rows are different levels of the same execution. Do not add their counts. A step can inherit its job stage, including setup and cleanup steps.'
Add-Panel 'Post-deployment verification detail | open the source run' 'table' ($verification+@'

V | top 200 by SourceTime desc
| project Repository, BuildRunId=RunId, RunAttempt, Environment, RecordType, Stage, JobName, StepNumber, StepName, Result=Conclusion, StartedAt, CompletedAt, DurationSeconds, RunUrl
| order by BuildRunId asc, RunAttempt asc, JobName asc, StepNumber asc
'@) 0 72 24 9 'Includes successful checks and step-only mappings. Source workflow owns the checks and their pass/fail criteria. This dashboard observes their reported outcomes; it does not perform endpoint probes or continuously monitor the application.'
Add-Text 'If verification is missing' 'Use the shared stage profile to map the exact verification job or step to **Post-deployment verification**, **Smoke test** or **Rollback verification**. Pre-deployment validation is separate. Publish a fresh run or replay after merging the mapping. No data does not prove that a check passed or was required.' 81 5

$variables=@()
foreach($name in @('Repository','Service','RunId')) {
    $value='*';if($name -eq 'Repository'){$value='northwest/doc_extraction'}
    $variables+=@{name=$name;label="$name (exact or *)";type='textbox';query=$value;current=@{text=$value;value=$value};options=@(@{text=$value;value=$value;selected=$true});hide=0;skipUrlSync=$false}
}
$dashboard=[ordered]@{
    '__inputs'=@(@{name='DS_AZURE_MONITOR';label='Azure Monitor';description='Use the built-in Azure Monitor data source.';type='datasource';pluginId='grafana-azure-monitor-datasource';pluginName='Azure Monitor'})
    id=$null;uid='nwb-dora-monitoring';title='nwb-dora-monitoring';schemaVersion=39;version=1
    description='Production DORA evidence and developer run investigation. Unknown evidence is not zero. See panel descriptions for denominators and coverage.'
    tags=@('NWB','DORA','CI/CD');timezone='utc';editable=$true;refresh=''
    time=@{from='now-30d';to='now'};timepicker=@{refresh_intervals=@('5m','15m','1h')}
    templating=@{list=$variables};panels=@($panels.ToArray() | Sort-Object {$_.gridPos.y}, {$_.gridPos.x});annotations=@{list=@()};links=@()
}
[System.IO.File]::WriteAllText($OutputPath,($dashboard | ConvertTo-Json -Depth 60)+"`n",[System.Text.UTF8Encoding]::new($false))
Write-Output "Created $OutputPath"
