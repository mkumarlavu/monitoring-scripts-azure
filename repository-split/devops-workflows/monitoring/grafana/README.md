# CI/CD dashboard inside Azure Monitor

For the new **DORA, post-deployment checks and developer run investigation** dashboard,
follow [DORA-README.md](DORA-README.md). Import `nwb-dora-monitoring.grafana.json` for
all of those views together. The CI dashboard described below is unchanged.

For release history, rollback results, required smoke checks and observed versions across environments, follow [release monitoring setup](../docs/RELEASE-MONITORING.md). These panels require the additional tables and evidence publishers described there.

Use **Azure Monitor > Dashboards with Grafana**. Microsoft provides this dashboard experience inside the Azure portal at no additional dashboard charge. It does not require an Azure Managed Grafana instance. Log Analytics ingestion, retention and any applicable query or alert charges still apply. [Microsoft comparison](https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/visualize-grafana-overview), [Azure Monitor pricing](https://azure.microsoft.com/en-us/pricing/details/monitor/).

The first Northwest import exposed a query interpolation error (`SYN0002` at `northwest`). The generator now uses quoted KQL string literals for the text filters. This correction is checked offline; reimport and verify the live panels. The existing Azure Workbook remains usable during validation.

## Import step by step

1. Take **`nwb-cicd-monitoring.grafana.json`** to the VDI. This is the only file needed for import. Do not paste the Workbook JSON or PowerShell code into this importer.
2. In Azure Portal, open **Monitor > Dashboards with Grafana**.
3. Select **New > Import**, choose the JSON file, then select **Load**.
4. If asked for the `Azure Monitor` data source, select the built-in Azure Monitor source. The JSON has a data-source input for this binding; no client secret or collector identity should be entered.
5. Use the title **nwb-cicd-monitoring**, subscription **NWPROD-SUB**, resource group **prd-cicdobservability-rg-eus2**, and location **East US 2**. Complete the import/save prompts. The resource name cannot contain spaces or `/`. When replacing an existing dashboard, use the update/overwrite option if offered. Otherwise import as **nwb-cicd-monitoring-v2** to validate without deleting the existing dashboard.
6. Keep the time range at **Last 7 days**. Set Repository to `northwest/doc_extraction`, Workflow to `*`, and Environment to `*`. The text filters accept an exact value or `*` for all.
7. Confirm that workflow and execution records match the Workbook for the same filters and time window. Check the source run `323897996` if it is still in the selected collection window; otherwise use the latest published application run.
8. Check **Stage outcomes** after a new publication using the shared stage profile. `unmapped` means no matching label; it is not a collection failure.
9. Save the dashboard and share its Azure link. Viewers need read access to both the dashboard and its underlying Log Analytics data. Import/edit access requires dashboard write permission. Azure Monitor dashboards use the signed-in user's access, not our ingestion identity.

Microsoft's [portal import and sharing instructions](https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/visualize-use-grafana-dashboards) describe these controls. If the portal does not bind the data source during import, open a panel in Edit, select the built-in Azure Monitor source and confirm the Logs workspace is `prd-cicdobservability-law-eus2`. Capture the import/query error before changing ingestion configuration. If the feature is unavailable in Northwest's tenant, continue using the existing Workbook; no separate Grafana service needs to be purchased for the current dashboard.

## What the files do

The overview now shows workflow KPI cards, a daily stacked chart, an outcome donut,
slow-job and slow-step bars, stage outcomes, workflow success rates and heartbeat age.
Only a small collector activity table is visible initially. Expand **Investigate runs**,
**Detailed metrics**, or **Mappings, health and deployments** for the original tables
and complete metrics. Definitions are in panel information tooltips rather than long
paragraphs. The time window still means collection time, and production DORA remains
unvalidated.

After regenerating, import the updated JSON into Azure; a Git merge does not update
an already saved dashboard. Check the charts, filters and expandable rows in the
portal before sharing. Offline tests validate definitions and layout, not rendering
in Azure's embedded Grafana version.

| File | Purpose |
| --- | --- |
| `nwb-cicd-monitoring.grafana.json` | Generated Grafana dashboard for portal import. |
| `Build-CicdGrafana.ps1` | Reuses the Workbook query definitions, converts filters/time macros and writes the Grafana JSON locally. |
| `Test-CicdGrafana.ps1` | Checks query parity, workspace scope, deduplication, time filters and dashboard structure offline. |

Keep this entire folder in `devops-workflows/monitoring/grafana`. Nothing in this folder goes into `doc_extraction`.

To regenerate after changing the Workbook queries, run from the central repository root:

```powershell
./monitoring/workbooks/Build-CicdWorkbook.ps1
./monitoring/workbooks/Test-CicdWorkbook.ps1
./monitoring/grafana/Build-CicdGrafana.ps1
./monitoring/grafana/Test-CicdGrafana.ps1
```

For another workspace, pass its full resource ID to the Workbook generator first. The Grafana generator uses the workspace already embedded in that Workbook. Neither script publishes a dashboard or changes Azure infrastructure.

## What to verify in Azure

- Both KPI sections, tables and the daily chart load. Empty failure/deployment results are expected when no matching evidence was collected; an error is different from an empty result.
- Repository, workflow and environment filters work, including a filter returning no records. Test a workflow name containing punctuation if one is available.
- Summary values, repeated-run deduplication and job/step counts match the Workbook. Run links open the source GitHub run.
- The daily chart uses UTC collection time. A replayed historical run appears on its collection day, not its original run day. Zero-observation days do not prove no application activity.
- Health panels use only repository and collection-time filters. A collection observation does not establish that scheduled heartbeats are running.
- No data stays unknown; it is not shown as green/healthy. DORA is still marked unvalidated until production, change and incident evidence is collected.

Grafana alerts are not supported in this embedded Azure Monitor experience. Continue implementing alerts through **Azure Monitor alert rules and action groups**; ServiceNow integration remains separate work. Importing this dashboard creates neither alerts nor incidents.

The queries use Grafana's [Azure Monitor time macros](https://grafana.com/docs/grafana/latest/datasources/azure-monitor/query-editor/). Single-value text filters use [sqlstring formatting](https://grafana.com/docs/grafana/latest/visualizations/dashboards/variables/variable-syntax/#sqlstring) inside [KQL verbatim string literals](https://learn.microsoft.com/en-us/kusto/query/scalar-data-types/string). For example, `@${Repository:sqlstring}` should become `@'northwest/doc_extraction'`. Do not add extra quotes around the variable. The dashboard contains no credentials. Automatic refresh is off initially; refresh manually during validation.
