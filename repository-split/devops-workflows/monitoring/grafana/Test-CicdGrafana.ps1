$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$script:passed=0
function Check($ok,$message) { if (-not $ok) { throw "FAILED: $message" };$script:passed++ }
$dashboard=Get-Content (Join-Path $PSScriptRoot 'nwb-cicd-monitoring.grafana.json') -Raw | ConvertFrom-Json
$workbook=Get-Content (Join-Path $PSScriptRoot '../workbooks/nwb-cicd-monitoring.workbook.json') -Raw | ConvertFrom-Json
$detailRows=@($dashboard.panels | Where-Object { $_.type -eq 'row' -and $_.collapsed })
$detailPanels=@($detailRows | ForEach-Object { $_.panels })
$allPanels=@($dashboard.panels)+$detailPanels
$queryPanels=@($allPanels | Where-Object { $_.PSObject.Properties['targets'] })
$workbookQueries=@($workbook.items | Where-Object type -eq 3)
Check ($detailPanels.Count -eq $workbookQueries.Count) 'Every Workbook query is retained in expandable details'
Check (@($allPanels | Group-Object id | Where-Object Count -gt 1).Count -eq 0) 'Panel IDs are unique across overview and details'
Check ($dashboard.timezone -eq 'utc' -and $dashboard.refresh -eq '') 'UTC and manual refresh by default'
Check ($dashboard.__inputs[0].pluginId -eq 'grafana-azure-monitor-datasource') 'Uses built-in Azure Monitor data source'
Check ($dashboard.title -cmatch '^[a-zA-Z][a-zA-Z0-9-]{0,28}[a-zA-Z0-9]$') 'Title is valid as an Azure dashboard resource name'
function Check-Layout($Panels) {
    for ($i=0;$i -lt $Panels.Count;$i++) {
        $a=$Panels[$i].gridPos
        Check ($a.x -ge 0 -and $a.w -gt 0 -and $a.x+$a.w -le 24 -and $a.h -gt 0) 'Panel stays within the 24-column grid'
        for ($j=$i+1;$j -lt $Panels.Count;$j++) {
            $b=$Panels[$j].gridPos
            Check (-not ($a.x -lt $b.x+$b.w -and $a.x+$a.w -gt $b.x -and $a.y -lt $b.y+$b.h -and $a.y+$a.h -gt $b.y)) 'Visible panels do not overlap'
        }
    }
}
Check-Layout @($dashboard.panels)
foreach ($row in $detailRows) { Check-Layout @($row.panels) }
foreach ($panel in $queryPanels) {
    $target=$panel.targets[0];$query=$target.azureLogAnalytics.query
    Check ($target.queryType -eq 'Azure Log Analytics') 'Queries the existing Log Analytics tables'
    Check ($target.azureLogAnalytics.resources[0] -eq $workbook.fallbackResourceIds[0]) 'Same workspace as Workbook'
    Check ($query.Contains('$__timeFilter(TimeGenerated)')) 'Reporting window filters collection time'
    Check ($query -notmatch '\{TimeRange|:base64\}') 'No Workbook-only macros'
    Check ($query.Contains('arg_max(UpdatedAt, *)')) 'Latest observations deduplicated'
    Check ($query.Contains('@${Repository:sqlstring}')) 'Repository uses a quoted KQL verbatim literal'
    if ($query.Contains('let H = NWBCollectorHealth_CL')) {
        Check ($query -notmatch '\$\{Workflow|\$\{Environment') 'Health ignores unsupported workflow/environment filters'
    } else {
        Check ($query.Contains('@${Workflow:sqlstring}') -and $query.Contains('@${Environment:sqlstring}')) 'Workflow and environment filters retained'
    }
}
foreach ($item in $workbookQueries) {
    # Detailed panels preserve the full original query and all its metrics.
    $expected=$item.content.query
    foreach ($name in @('Repository','Workflow','Environment')) {
        $expected=$expected.Replace("base64_decode_tostring('{$($name):base64}')",('@${'+$name+':sqlstring}'))
    }
    $expected=$expected.Replace('TimeGenerated {TimeRange}','$__timeFilter(TimeGenerated)').Replace('{TimeRange:start}','$__timeFrom()').Replace('{TimeRange:end}','$__timeTo()')
    Check (@($detailPanels | Where-Object { $_.targets[0].azureLogAnalytics.query -ceq $expected }).Count -eq 1) 'Each original query appears exactly once in details'
}
# Model Grafana's documented single-value sqlstring formatter. This checks the
# resulting KQL literal boundary, not a live Grafana or Azure query execution.
$filterCases=@('northwest/doc_extraction','*','Validate and deliver through Dev',"Bank's workflow",'folder\name','a"b',"x'; print 1; //")
foreach ($value in $filterCases) {
    $formatted="'"+$value.Replace("'","''")+"'"
    $line=($queryPanels[0].targets[0].azureLogAnalytics.query -split "`n")[0]
    $line=$line.Replace('${Repository:sqlstring}',$formatted)
    Check ($line -cmatch "^let selectedRepository = @'((?:[^']|'')*)';\s*$") 'Interpolated repository remains one KQL string literal'
    Check ($Matches[1].Replace("''","'") -ceq $value) 'Literal preserves filter punctuation'
}
$trend=@($queryPanels | Where-Object type -eq 'timeseries')[0]
Check ($trend.targets[0].azureLogAnalytics.resultFormat -eq 'time_series') 'Trend returns time series'
Check ($trend.targets[0].azureLogAnalytics.query.Contains('default=0')) 'Zero-observation days preserved'
Check (@($detailPanels | Where-Object type -eq stat).Count -eq 2) 'Both complete KPI sections retained in details'
foreach ($panel in @($detailPanels | Where-Object type -eq stat)) {
    Check ($panel.transformations[0].id -eq 'rowsToFields' -and $panel.options.colorMode -eq 'none') 'KPI rows become neutral tiles'
}
Check (@($dashboard.panels | Where-Object type -eq table).Count -eq 1) 'Overview contains only one compact table'
Check (@($dashboard.panels | Where-Object type -eq bargauge).Count -eq 3) 'Bottlenecks and workflow comparison use bars'
Check ($detailRows.Count -eq 3) 'Investigation, metrics and mappings have expandable rows'
$stage=@($dashboard.panels | Where-Object type -eq barchart)[0]
Check ($stage.targets[0].azureLogAnalytics.query.Contains("RecordType == 'Job'")) 'Stage chart never mixes job and step counts'
Check ($stage.targets[0].azureLogAnalytics.query.Contains('Other=Observations-Succeeded-FailedOrTimedOut-Skipped')) 'Stage chart retains cancelled and other outcomes'
$heartbeat=@($dashboard.panels | Where-Object title -eq 'Last heartbeat | age in minutes')[0]
Check ($heartbeat.targets[0].azureLogAnalytics.query.Contains("Operation == 'heartbeat'")) 'Heartbeat card cannot substitute collection observations'
Check ($heartbeat.options.colorMode -eq 'none' -and $heartbeat.fieldConfig.defaults.noValue -eq 'No heartbeat') 'Absent heartbeat is not green or zero'
foreach ($panel in @($dashboard.panels | Where-Object type -eq bargauge)) {
    Check ($panel.options.reduceOptions.values -eq $true) 'Each bar represents a returned row'
    Check ($panel.targets[0].azureLogAnalytics.query.Contains('project Label=') -and $panel.targets[0].azureLogAnalytics.query.Contains('Value=')) 'Bars receive a label and one numeric value'
}
Check (($dashboard.panels | ConvertTo-Json -Depth 60) -match 'not yet validated') 'DORA readiness remains explicit'
Write-Output "Passed $script:passed Grafana definition checks. Portal import and live queries still need validation."
