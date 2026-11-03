# CI/CD dashboard inside Azure Monitor

Use **Azure Monitor > Dashboards with Grafana**. Microsoft provides this dashboard experience inside the Azure portal at no additional dashboard charge. It does not require an Azure Managed Grafana instance. Log Analytics ingestion, retention and any applicable query or alert charges still apply. [Microsoft comparison](https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/visualize-grafana-overview), [Azure Monitor pricing](https://azure.microsoft.com/en-us/pricing/details/monitor/).

This dashboard is prepared locally and has passed offline definition checks. It has not yet been imported or tested in Northwest Azure. The existing Azure Workbook remains usable while this view is validated.

## Import step by step

1. Take **`nwb-cicd-monitoring.grafana.json`** to the VDI. This is the only file needed for import. Do not paste the Workbook JSON or PowerShell code into this importer.
2. In Azure Portal, open **Monitor > Dashboards with Grafana**.
3. Select **New > Import**, choose the JSON file, then select **Load**.
4. If asked for the `Azure Monitor` data source, select the built-in Azure Monitor source. The JSON has a data-source input for this binding; no client secret or collector identity should be entered.
5. Use the title **Northwest CI/CD monitoring**, subscription **NWPROD-SUB**, resource group **prd-cicdobservability-rg-eus2**, and location **East US 2**. Complete the import/save prompts.
6. Keep the time range at **Last 7 days**. Set Repository to `northwest/doc_extraction`, Workflow to `*`, and Environment to `*`. The text filters accept an exact value or `*` for all.
7. Confirm that workflow and execution records match the Workbook for the same filters and time window. Check the source run `323897996` if it is still in the selected collection window; otherwise use the latest published application run.
8. Check **Stage outcomes** after a new publication using the shared stage profile. `unmapped` means no matching label; it is not a collection failure.
9. Save the dashboard and share its Azure link. Viewers need read access to both the dashboard and its underlying Log Analytics data. Import/edit access requires dashboard write permission. Azure Monitor dashboards use the signed-in user's access, not our ingestion identity.

Microsoft's [portal import and sharing instructions](https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/visualize-use-grafana-dashboards) describe these controls. If the portal does not bind the data source during import, open a panel in Edit, select the built-in Azure Monitor source and confirm the Logs workspace is `prd-cicdobservability-law-eus2`. Capture the import/query error before changing ingestion configuration. If the feature is unavailable in Northwest's tenant, continue using the existing Workbook; no separate Grafana service needs to be purchased for the current dashboard.

## What the files do

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

The queries use Grafana's [Azure Monitor time macros](https://grafana.com/docs/grafana/latest/datasources/azure-monitor/query-editor/) and JSON-formatted text variables. The dashboard contains no credentials. Automatic refresh is off initially; refresh manually during validation.
