$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$script:passed=0
function Check($ok,$message) { if (-not $ok) { throw "FAILED: $message" };$script:passed++ }
$dashboard=Get-Content (Join-Path $PSScriptRoot 'nwb-cicd-monitoring.grafana.json') -Raw | ConvertFrom-Json
$workbook=Get-Content (Join-Path $PSScriptRoot '../workbooks/nwb-cicd-monitoring.workbook.json') -Raw | ConvertFrom-Json
$queryPanels=@($dashboard.panels | Where-Object { $_.type -ne 'text' })
$workbookQueries=@($workbook.items | Where-Object type -eq 3)
Check ($queryPanels.Count -eq $workbookQueries.Count) 'Every Workbook query has a Grafana panel'
Check (@($dashboard.panels | Group-Object id | Where-Object Count -gt 1).Count -eq 0) 'Panel IDs are unique'
Check ($dashboard.timezone -eq 'utc' -and $dashboard.refresh -eq '') 'UTC and manual refresh by default'
Check ($dashboard.__inputs[0].pluginId -eq 'grafana-azure-monitor-datasource') 'Uses built-in Azure Monitor data source'
Check ($dashboard.title -cmatch '^[a-zA-Z][a-zA-Z0-9-]{0,28}[a-zA-Z0-9]$') 'Title is valid as an Azure dashboard resource name'
$index=0;$bottom=0
foreach ($panel in $dashboard.panels) {
    Check ($panel.gridPos.y -ge $bottom) 'Panel layout does not overlap'
    $bottom=$panel.gridPos.y+$panel.gridPos.h
    if ($panel.type -eq 'text') { continue }
    $target=$panel.targets[0];$query=$target.azureLogAnalytics.query
    Check ($target.queryType -eq 'Azure Log Analytics') 'Queries the existing Log Analytics tables'
    Check ($target.azureLogAnalytics.resources[0] -eq $workbook.fallbackResourceIds[0]) 'Same workspace as Workbook'
    Check ($query.Contains('$__timeFilter(TimeGenerated)')) 'Reporting window filters collection time'
    Check ($query -notmatch '\{TimeRange|:base64\}') 'No Workbook-only macros'
    Check ($query.Contains('arg_max(UpdatedAt, *)')) 'Latest observations deduplicated'
    Check ($query.Contains('@${Repository:sqlstring}')) 'Repository uses a quoted KQL verbatim literal'
    if ($workbookQueries[$index].name -like 'health-*') {
        Check ($query -notmatch '\$\{Workflow|\$\{Environment') 'Health ignores unsupported workflow/environment filters'
    } else {
        Check ($query.Contains('@${Workflow:sqlstring}') -and $query.Contains('@${Environment:sqlstring}')) 'Workflow and environment filters retained'
    }
    # Everything after the base scope must still be the source query, apart from time macros.
    $expected=$workbookQueries[$index].content.query
    foreach ($name in @('Repository','Workflow','Environment')) {
        $expected=$expected.Replace("base64_decode_tostring('{$($name):base64}')",('@${'+$name+':sqlstring}'))
    }
    $expected=$expected.Replace('TimeGenerated {TimeRange}','$__timeFilter(TimeGenerated)').Replace('{TimeRange:start}','$__timeFrom()').Replace('{TimeRange:end}','$__timeTo()')
    Check ($query -ceq $expected) 'Query definitions stay in sync with Workbook'
    $index++
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
Check (@($queryPanels | Where-Object type -eq stat).Count -eq 2) 'Both KPI sections retained'
foreach ($panel in @($queryPanels | Where-Object type -eq stat)) {
    Check ($panel.transformations[0].id -eq 'rowsToFields' -and $panel.options.colorMode -eq 'none') 'KPI rows become neutral tiles'
}
Check (($dashboard.panels | ConvertTo-Json -Depth 60) -match 'not yet validated') 'DORA readiness remains explicit'
Write-Output "Passed $script:passed Grafana definition checks. Portal import and live queries still need validation."
