# Northwest CI/CD dashboard

This is an Azure Workbook that reads the existing Northwest Log Analytics tables. You can import it now and see the workflow, job and step records already collected. It does not need changes to Chinchia's application pipeline to display those records.

The workbook is prepared locally. Importing it, saving it in Northwest Azure and checking the rendered queries are still required. No Azure resource has been created by the generator.

## Files to copy

Copy this folder into `northwest/devops-workflows/monitoring/workbooks/`:

| File | Use |
| --- | --- |
| `nwb-cicd-monitoring.workbook.json` | Ready to paste into the Azure Workbook Advanced Editor. This is the only file needed for portal import. |
| `Build-CicdWorkbook.ps1` | Source for generating the JSON, including all KQL queries. No Azure login or upload occurs. |
| `Test-CicdWorkbook.ps1` | Offline checks of the generated structure, parameter references and query safeguards. |
| `README.md` | Installation, metric definitions and acceptance checks. |

Nothing from this folder goes into `doc_extraction`. The application repository keeps its caller workflows and `config/nwb-observability/collector.json`.

## Create the dashboard in Azure

1. Open the JSON file as plain text on the Northwest machine and copy the entire contents.
2. In Azure Portal, open **Monitor > Workbooks**. Select **New** or the **Empty** workbook template.
3. Select **Edit** if needed, then **Advanced Editor** (`</>`).
4. Select **Gallery Template** as the template type if a selector appears. This JSON is workbook content, not an ARM deployment template.
5. Replace the editor contents with `nwb-cicd-monitoring.workbook.json`.
6. Select **Apply**. Review the results before saving. The queries explicitly target `prd-cicdobservability-law-eus2`; you do not need to select Application Insights.
7. Select **Save** and enter:
   - Name: **NWB CI/CD Monitoring**
   - Subscription: **NWPROD-SUB**
   - Resource group: **prd-cicdobservability-rg-eus2**
   - Location: **East US 2**, if prompted
8. Select **Done Editing**. Start with **Collected during = Last 7 days**, **Repository = northwest/doc_extraction**, and `*` for Workflow and Environment.
9. Use the workbook **Share** option to copy its link for the team. Viewers need access to the saved workbook and underlying workspace data; sharing a link does not grant either permission.
10. You can use the workbook's pin controls to put selected panels on an Azure portal dashboard if needed. The workbook itself is the complete monitoring dashboard and retains the filters and investigation tables.

Official references: [create a workbook](https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-create-workbook), [Advanced Editor and template formats](https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-automate), [workbook parameters](https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-parameters).

## What is on the dashboard

There are 20 summary tiles and 12 additional charts/tables:

| Section | What it shows |
| --- | --- |
| Workflow tiles (12) | Observed attempts, successes, failures, timeouts, cancellations, skips, other outcomes, success rate, P50 and P95 execution duration, missing durations and unclassified environments. |
| Workflow details | Daily trend by collection time, comparison by workflow/environment, latest attempts and failed/timed-out attempts. Run links open GitHub. |
| Execution tiles (8) | Job and step counts, failed/timed-out jobs and steps, skipped jobs, job and step stage coverage, and jobs without duration. |
| Execution details | Slowest jobs and steps, failed execution records, outcomes by stage and a mapping inventory with exact workflow/job/step names. |
| Collector health | Last observation by operation, age of that observation, failure-observation counts and recent details. Heartbeats remain distinct from collection results. |
| Deployment evidence | Confirmed deployment facts that have been collected, including actual deployment time, environment and production classification. |

No sample records or made-up values are included. Empty health or deployment sections are expected until those collection paths are exercised. Missing data is not a healthy status. All four tables must exist in the selected workspace: `NWBWorkflowRuns_CL`, `NWBPipelineExecution_CL`, `NWBCollectorHealth_CL`, `NWBDeploymentFacts_CL`. The workflow table must include `SourceUpdatedAt`.

## How the numbers are calculated

- **Reporting period:** the time picker filters `TimeGenerated`, which our collectors set to observation time. Replaying July's Copilot run in October makes it an October observation; it is not an October deployment. Actual workflow and deployment timestamps remain visible in detail tables.
- **Deduplication:** each panel selects the newest `UpdatedAt` within its collection window. Workflow key: Repository + RunId + RunAttempt. Execution key: Repository + RunId + RunAttempt + JobId + RecordType + StepNumber. Deployment key: Repository + DeploymentId. Health key: Repository + Collector + CheckId. The counts can differ across reporting windows if a run is collected in both windows; this is not an all-time deduplication store.
- **Reruns:** different attempt numbers remain separate. These are attempt success rates, not the final success rate after all retries. Latest-attempt-only reporting would be a separate metric.
- **Success rate:** successful attempts divided by all observed attempts in scope. Cancelled, skipped and other outcomes remain in the denominator and also have separate tiles. When there are no attempts, the rate displays `No data`.
- **Durations:** workflow duration is the span of available active job timing, not approval/queue time or total machine effort. P50/P95 use known durations only. Job and step timing are not added together. Null durations are never changed to zero. Percentiles with few records are descriptive, not performance targets.
- **Stage coverage:** known mappings divided by observed jobs or steps at that level. Job and step coverage are separate. Unknown labels stay `unmapped` until the application team confirms their meaning.
- **Health:** the sections ignore Workflow and Environment filters because these columns do not exist in health records. Failure counts represent deduplicated observations, not unique incidents. Watchdog observations may describe an older collector run; inspect `Operation`, source IDs and `DetailCode` before taking action. The age of the last observation is not an SLA or a configured missing-heartbeat alert.
- **Filters:** exact, case-sensitive names; `*` selects all. Repository defaults to `northwest/doc_extraction`. Text is base64-encoded by Workbook parameter formatting and decoded as a KQL string, so punctuation does not become query syntax.
- **Limits:** grids show the stated top 20/50/100/250 rows. Summary counts use all matching observations, not only those displayed rows. Data is limited to the workspace's retention and collected coverage.

## Verify it with the application run

The user verified these records in Azure on 3 November 2026: application run `323897996`, **Validate and deliver through Dev**, success, 331 seconds, and 68 job/step rows. Its environment was `unclassified` and stage labels were `unmapped`. Use this evidence as an initial check, not as a fixed dashboard value.

1. Set a collection time window that includes **3 November 2026, 17:46 UTC** and enter **Validate and deliver through Dev** in the Workflow filter.
2. In the latest-attempt table, find run `323897996`. Confirm its conclusion and 331-second duration against GitHub. Counts may be larger if other runs have since been collected.
3. Confirm successful and skipped job outcomes remain distinct. In the screenshot, the `build` job was skipped; this is not a collector error.
4. Use the mapping inventory to collect the actual `WorkflowPath`, `JobName` and `StepName`. Apply reviewed mappings in `doc_extraction/config/nwb-observability/collector.json`. Do not guess production classification from the workflow title.
5. Check that the GitHub run links open the intended repository and run.
6. Select a repository name that has no records. Counts should be zero, rates/durations should say `No data`, and detail panels should show the no-data message.
7. If a workflow was already replayed, compare the raw number of rows with the workbook's deduplicated attempts. Do not deliberately republish just to populate the dashboard.
8. Once automatic collection is enabled, let a normal application run finish and refresh the workbook after ingestion. Confirm the new run appears without manually starting the collector.

## What to do next with Chinchia

1. Validate automatic collection. In `doc_extraction` repository variables, set `CICD_MONITOR_AUTOMATION_ENABLED=true` and `CICD_MONITOR_AUTO_PUBLISH=true`. Observe the next normal CI run; monitoring should start after completion. Keep the monitoring caller on the default branch.
2. Confirm stage and environment labels together. Raw job/step collection already works without these labels.
3. Confirm GitHub deployment evidence: environment, commit, a success status tied to the run, and whether success means the Container App release actually completed. Our deployment collector does not infer a deployment from a successful build.
4. Test scheduled collector health separately before treating heartbeat absence as an incident.
5. Agree alert recipients, severity, suppression and genuine failure conditions; then test notification routing. ServiceNow creation is a later integration and is not enabled by importing a workbook.

DORA is not yet a completed dashboard section. Production deployment frequency needs verified production deployment evidence. Lead time needs linked changes and commit timestamps. Change failure, failed deployment recovery and rework need reliable incident/intervention/rework sources. Sonar/Snyk findings need their own results integration; a security job outcome alone is not a vulnerability count.

## Rebuild and check locally

Run from this folder in PowerShell:

```powershell
.\Build-CicdWorkbook.ps1
.\Test-CicdWorkbook.ps1
```

For a different workspace, pass its full resource ID:

```powershell
.\Build-CicdWorkbook.ps1 -WorkspaceResourceId '/subscriptions/SUBSCRIPTION/resourceGroups/GROUP/providers/Microsoft.OperationalInsights/workspaces/WORKSPACE'
```

Commit the generator and regenerated JSON together. The offline checks verify structure and query safeguards; they do not execute KQL or validate Azure portal rendering. Live query results and visual layout must be checked after import.
