[CmdletBinding()]
param(
    [string]$WorkbookPath=(Join-Path $PSScriptRoot '../workbooks/nwb-cicd-monitoring.workbook.json'),
    [string]$OutputPath=(Join-Path $PSScriptRoot 'nwb-cicd-monitoring.grafana.json')
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
# Reuse the Workbook queries so counts and deduplication stay consistent.
# This writes a local dashboard file only; it creates no Azure resources.
$workbook=Get-Content -LiteralPath $WorkbookPath -Raw | ConvertFrom-Json
$source=@{type='grafana-azure-monitor-datasource';uid='${DS_AZURE_MONITOR}'}
$panels=[System.Collections.Generic.List[object]]::new()
$id=0;$y=0
$detailPanels=@{}
function Convert-WorkbookQuery([string]$Query) {
    foreach ($name in @('Repository','Workflow','Environment')) {
        # sqlstring supplies quotes and doubles apostrophes. KQL verbatim strings
        # use the same escaping and preserve literal backslashes in filter values.
        $Query=$Query.Replace("base64_decode_tostring('{$($name):base64}')",('@${'+$name+':sqlstring}'))
    }
    $Query=$Query.Replace('TimeGenerated {TimeRange}','$__timeFilter(TimeGenerated)')
    $Query=$Query.Replace('{TimeRange:start}','$__timeFrom()').Replace('{TimeRange:end}','$__timeTo()')
    if ($Query -match '\{TimeRange|:base64\}') { throw 'Unconverted Workbook query parameter.' }
    return $Query
}
foreach ($item in $workbook.items) {
    if ($item.type -eq 9) { continue }
    $id++
    $panel=[ordered]@{id=$id;title='';gridPos=@{x=0;y=$y;w=24;h=5}}
    if ($item.type -eq 1) {
        $panel.type='text'
        $panel.options=@{mode='markdown';content=$item.content.json.Replace('This workbook','This dashboard')}
        $height=5
        if ($item.name -eq 'intro') { $height=7 }
    } elseif ($item.type -eq 3) {
        $c=$item.content
        $panel.title=$c.title
        $panel.description=$c.noDataMessage
        $panel.datasource=$source
        $format='table';$height=9
        $panel.type='table'
        $panel.options=@{showHeader=$true;cellHeight='sm';footer=@{show=$false}}
        $panel.fieldConfig=@{defaults=@{noValue='No data';custom=@{filterable=$true}};overrides=@()}
        if ($c.visualization -eq 'timechart') {
            $panel.type='timeseries';$format='time_series';$height=8
            $panel.options=@{legend=@{displayMode='list';placement='bottom'};tooltip=@{mode='multi';sort='none'}}
            $panel.fieldConfig=@{defaults=@{min=0;unit='short';custom=@{drawStyle='bars';fillOpacity=70;lineWidth=0;spanNulls=$false}};overrides=@()}
        } elseif ($c.visualization -eq 'tiles') {
            $panel.type='stat';$height=6
            $panel.options=@{colorMode='none';graphMode='none';textMode='value_and_name';orientation='auto';justifyMode='auto';reduceOptions=@{values=$false;calcs=@('lastNotNull');fields='/.*/'}}
            # Metric -> display name, Value -> field value. Preserve 'No data' and % text.
            $panel.transformations=@(@{id='rowsToFields';options=@{mappings=@(@{fieldName='Metric';handlerKey='field.name'},@{fieldName='Value';handlerKey='field.value'})}})
            $panel.fieldConfig=@{defaults=@{noValue='No data'};overrides=@()}
        }
        $query=Convert-WorkbookQuery $c.query
        $panel.targets=@(@{refId='A';datasource=$source;queryType='Azure Log Analytics';azureLogAnalytics=@{query=$query;resources=@($c.crossComponentResources);resultFormat=$format;mode='raw';dashboardTime=$false}})
        if ($c.PSObject.Properties['gridSettings']) {
            $panel.fieldConfig.overrides=@(@{matcher=@{id='byName';options='RunUrl'};properties=@(@{id='links';value=@(@{title='Open in GitHub';url='${__value.raw}';targetBlank=$true})})})
        }
    } else { throw "Unsupported Workbook item type $($item.type)." }
    $panel.gridPos.h=$height
    $panels.Add($panel);$y+=$height
    if ($item.type -eq 3) { $detailPanels[$item.name]=$panel }
}
# Keep the original queries for investigation. Build a shorter visual overview
# from those same deduplicated records; no collection or metric semantics change.
$panels.Clear();$y=0
function Copy-QueryPanel([string]$Name,[string]$Title,[int]$X,[int]$Y,[int]$Width,[int]$Height) {
    $script:id++
    $copy=$detailPanels[$Name] | ConvertTo-Json -Depth 60 | ConvertFrom-Json
    $copy.id=$script:id;$copy.title=$Title
    $copy.gridPos.x=$X;$copy.gridPos.y=$Y;$copy.gridPos.w=$Width;$copy.gridPos.h=$Height
    return $copy
}
function New-Section([string]$Title,[int]$Y,[bool]$Collapsed=$false,[object[]]$Children=@()) {
    $script:id++
    return @{id=$script:id;type='row';title=$Title;collapsed=$Collapsed;panels=$Children;gridPos=@{x=0;y=$Y;w=24;h=1}}
}
function Set-OutcomeColors($Panel) {
    foreach ($entry in @(@('success','green'),@('Succeeded','green'),@('failure','red'),@('FailedOrTimedOut','red'),@('timed_out','orange'),@('cancelled','purple'),@('skipped','gray'),@('Skipped','gray'),@('Other','blue'))) {
        $Panel.fieldConfig.overrides+=@{matcher=@{id='byName';options=$entry[0]};properties=@(@{id='color';value=@{mode='fixed';fixedColor=$entry[1]}})}
    }
}
function Set-HorizontalBars($Panel,[string]$Unit) {
    $Panel.type='bargauge'
    $Panel.options=@{orientation='horizontal';displayMode='basic';showUnfilled=$false;minVizHeight=20;minVizWidth=0;reduceOptions=@{values=$true;calcs=@('lastNotNull');fields='/Value/';limit=8};text=@{titleSize=12;valueSize=18}}
    $Panel.fieldConfig=@{defaults=@{min=0;unit=$Unit;decimals=1;noValue='No data';color=@{mode='fixed';fixedColor='blue'}};overrides=@()}
}
$id++
$panels.Add(@{id=$id;type='text';title='';transparent=$true;gridPos=@{x=0;y=0;w=24;h=3};options=@{mode='markdown';content="## Northwest | CI/CD overview`nWorkflow results, bottlenecks and collector activity. **Times are UTC.** Filters accept an exact name or `*` for all."}})
$panels.Add((New-Section '01  Delivery overview' 3))
$p=Copy-QueryPanel 'workflow-kpis' 'Workflow results' 0 4 24 5
$p.targets[0].azureLogAnalytics.query+="`n| where Metric in ('Workflow attempts','Succeeded','Failed','Timed out','Success rate','P95 execution seconds')"
$p.options.orientation='horizontal';$p.options.colorMode='value'
$p.options | Add-Member -NotePropertyName text -NotePropertyValue @{titleSize=14;valueSize=32}
$p.fieldConfig.defaults=@{noValue='No data';color=@{mode='fixed';fixedColor='blue'}}
$p.description='Collected run attempts, not all GitHub activity. Success rate includes every outcome in its denominator. P95 is the 95th percentile execution window in seconds, excluding pre-job queue and approval waits. Small samples are not a baseline.'
$panels.Add($p)
$p=Copy-QueryPanel 'outcome-trend' 'Daily workflow activity' 0 9 16 8
$p.description='Attempts by collection day (UTC). Historical runs replayed today appear today. Zero means no observations collected, not proof that no workflows ran.'
$p.fieldConfig.defaults.custom | Add-Member -NotePropertyName stacking -NotePropertyValue @{mode='normal';group='outcomes'}
Set-OutcomeColors $p
$panels.Add($p)
$p=Copy-QueryPanel 'workflow-comparison' 'Workflow outcomes' 16 9 8 8
$scope=($detailPanels['workflow-kpis'].targets[0].azureLogAnalytics.query -split "`nW`n",2)[0]
$p.targets[0].azureLogAnalytics.query=$scope+"`nW`n| summarize Attempts=count() by Conclusion`n| order by Attempts desc"
$p.type='piechart'
$p.options=@{pieType='donut';displayLabels=@('percent');legend=@{displayMode='table';placement='bottom';values=@('value')};tooltip=@{mode='single';sort='none'};reduceOptions=@{values=$true;calcs=@('lastNotNull');fields='/Attempts/'}}
$p.fieldConfig=@{defaults=@{unit='short';noValue='No data';color=@{mode='palette-classic'}};overrides=@()}
Set-OutcomeColors $p
$p.description='Share of collected workflow attempts. Skipped and cancelled attempts are separate from failures.'
$panels.Add($p)
$panels.Add((New-Section '02  Jobs and bottlenecks' 17))
$p=Copy-QueryPanel 'execution-kpis' 'Execution coverage' 0 18 24 4
$p.targets[0].azureLogAnalytics.query+="`n| where Metric in ('Jobs','Steps','Job stage coverage','Step stage coverage')"
$p.options.orientation='horizontal'
$p.options | Add-Member -NotePropertyName text -NotePropertyValue @{titleSize=14;valueSize=28}
$p.description='Jobs and steps are separate levels; do not add their counts together. Stage coverage measures reviewed labels, not pipeline success. Missing data stays unknown.'
$panels.Add($p)
$p=Copy-QueryPanel 'slow-jobs' 'Slowest jobs | P95' 0 22 12 9
$p.targets[0].azureLogAnalytics.query+="`n| top 8 by P95Seconds desc`n| project Label=strcat(Repository, ' / ', PipelineName, ' / ', JobName), Value=P95Seconds"
Set-HorizontalBars $p 's'
$p.description='Eight slowest jobs by 95th percentile duration. Labels include repository and workflow. Parallel job durations must not be added into workflow duration; inspect sample counts in Detailed metrics.'
$panels.Add($p)
$p=Copy-QueryPanel 'slow-steps' 'Slowest steps | P95' 12 22 12 9
$p.targets[0].azureLogAnalytics.query+="`n| top 8 by P95Seconds desc`n| project Label=strcat(Repository, ' / ', PipelineName, ' / ', JobName, ' / ', StepName), Value=P95Seconds"
Set-HorizontalBars $p 's'
$p.fieldConfig.defaults.color.fixedColor='purple'
$p.description='Eight slowest steps by 95th percentile duration. Known durations only; sample counts and maximums are in Detailed metrics.'
$panels.Add($p)
$p=Copy-QueryPanel 'stage-results' 'Stage outcomes | jobs only' 0 31 12 9
$p.targets[0].azureLogAnalytics.query+="`n| where RecordType == 'Job'`n| extend Other=Observations-Succeeded-FailedOrTimedOut-Skipped`n| project Stage, Succeeded, FailedOrTimedOut, Skipped, Other"
$p.type='barchart'
$p.options=@{orientation='horizontal';xField='Stage';stacking='normal';showValue='auto';barWidth=0.75;groupWidth=0.7;legend=@{displayMode='list';placement='bottom'};tooltip=@{mode='multi';sort='none'}}
$p.fieldConfig=@{defaults=@{min=0;unit='short';color=@{mode='palette-classic'};custom=@{fillOpacity=85;lineWidth=0}};overrides=@()}
Set-OutcomeColors $p
$p.description='Job outcomes grouped by stage. Unmapped means no reviewed stage label; it is not a failure. Step results remain separate in Detailed metrics.'
$panels.Add($p)
$p=Copy-QueryPanel 'workflow-comparison' 'Workflow success rate' 12 31 12 9
$p.targets[0].azureLogAnalytics.query+="`n| top 8 by Attempts desc`n| project Label=strcat(Repository, ' / ', PipelineName, ' / ', Environment), Value=SuccessRatePercent"
Set-HorizontalBars $p 'percent'
$p.fieldConfig.defaults.max=100
$p.description='Eight most-observed workflow/environment groups. Successes divided by all observed attempts. Neutral bars show comparison, not an agreed service target.'
$panels.Add($p)
$panels.Add((New-Section '03  Collector activity' 40))
$p=Copy-QueryPanel 'health-summary' 'Last heartbeat | age in minutes' 0 41 10 7
$p.targets[0].azureLogAnalytics.query+="`n| where Operation == 'heartbeat'`n| project Label=strcat(Repository, ' / ', Collector), Value=MinutesSinceLastObservation"
$p.type='stat';$p.options=@{colorMode='none';graphMode='none';textMode='value_and_name';reduceOptions=@{values=$true;calcs=@('lastNotNull');fields='/Value/'};text=@{titleSize=14;valueSize=30}}
$p.fieldConfig=@{defaults=@{unit='none';decimals=0;noValue='No heartbeat'};overrides=@()}
$p.description='Age of the last heartbeat in the selected window, per repository and collector. No heartbeat is unknown, not healthy. A heartbeat does not prove complete workflow collection. Workflow and environment filters do not apply.'
$panels.Add($p)
$p=Copy-QueryPanel 'health-summary' 'Collector observations' 10 41 14 7
$p.targets[0].azureLogAnalytics.query+="`n| project Repository, Operation, LastObserved, FailureObservations"
$p.description='Observed collector activity in the selected window. Failure counts are observations, not unique incidents. Workflow and environment filters do not apply.'
$panels.Add($p)
# Collapsed rows retain every original query, including metrics hidden from the
# overview. Child panels are absolute grid positions, as in Grafana exports.
$groups=@(
    @{Title='04  Investigate runs | expand';Names=@('failed-runs','execution-failures','recent-runs')},
    @{Title='05  Detailed metrics | expand';Names=@('workflow-kpis','workflow-comparison','execution-kpis','slow-jobs','slow-steps','stage-results','outcome-trend')},
    @{Title='06  Mappings, health and deployments | expand';Names=@('mapping-inventory','health-summary','health-detail','deployments')}
)
$rowY=48
foreach ($group in $groups) {
    $children=@();$childY=$rowY+1
    foreach ($name in $group.Names) {
        $p=Copy-QueryPanel $name $detailPanels[$name].title 0 $childY 24 8
        $children+= $p;$childY+=8
    }
    $panels.Add((New-Section $group.Title $rowY $true $children));$rowY++
}
$id++
$panels.Add(@{id=$id;type='text';title='';transparent=$true;gridPos=@{x=0;y=$rowY;w=24;h=3};options=@{mode='markdown';content='**Reporting:** collection time, UTC; repeated observations deduplicated per attempt. **DORA:** not yet validated; production deployment, change and incident evidence is still required. Detailed Sonar/Snyk findings and ServiceNow integration are not included.'}})
$variables=@()
foreach ($name in @('Repository','Workflow','Environment')) {
    $value='*';if ($name -eq 'Repository') { $value='northwest/doc_extraction' }
    # Single-value text boxes are interpolated as KQL verbatim string literals.
    $variables+=@{name=$name;label="$name (exact name or *)";type='textbox';query=$value;current=@{text=$value;value=$value};options=@(@{text=$value;value=$value;selected=$true});hide=0;skipUrlSync=$false}
}
$dashboard=[ordered]@{
    '__inputs'=@(@{name='DS_AZURE_MONITOR';label='Azure Monitor';description='Select the built-in Azure Monitor data source in Azure Monitor dashboards with Grafana.';type='datasource';pluginId='grafana-azure-monitor-datasource';pluginName='Azure Monitor'})
    id=$null;uid='nwb-cicd-monitoring';title='nwb-cicd-monitoring';schemaVersion=39;version=1
    description='Workflow, job, step and collector observations from the existing Log Analytics workspace. Collection-time reporting; production DORA metrics are not yet validated.'
    tags=@('NWB','CI/CD');timezone='utc';editable=$true;refresh=''
    time=@{from='now-7d';to='now'};timepicker=@{refresh_intervals=@('5m','15m','1h')}
    templating=@{list=$variables};panels=@($panels.ToArray());annotations=@{list=@()};links=@()
}
[System.IO.File]::WriteAllText($OutputPath,($dashboard | ConvertTo-Json -Depth 60)+"`n",[System.Text.UTF8Encoding]::new($false))
Write-Output "Created $OutputPath"
