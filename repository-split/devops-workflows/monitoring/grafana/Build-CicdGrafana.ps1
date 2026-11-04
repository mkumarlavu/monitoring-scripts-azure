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
}
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
