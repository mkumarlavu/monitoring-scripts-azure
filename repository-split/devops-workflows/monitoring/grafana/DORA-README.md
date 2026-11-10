# DORA, post-deployment checks and run investigation

Import `nwb-dora-monitoring.grafana.json` for one dashboard containing all three.
The existing `nwb-cicd-monitoring` dashboard is unchanged. No new Grafana service is needed.

## What to update, in order

1. In Azure, open **Log Analytics workspaces > prd-cicdobservability-law-eus2 > Tables > NWBWorkflowRuns_CL > Edit schema**. Add `Actor`, `TriggeringActor` and `RunNumber`, all **String**. Keep the existing columns, including `SourceUpdatedAt`.
2. Update the existing **prd-cicdobservability-workflows-dcr-eus2** definition using your existing deployment process. Append those same three `string` columns to `properties.streamDeclarations.Custom-NWBWorkflowRuns_CL.columns`. Preserve its identity, endpoint, destinations and existing columns. `transformKql: "source"` carries them through; a transform using `project` must also include them. The fragment in `../infra/workflow-attribution-columns.json` lists only the additions: it is **not** a complete deployment template. Review and save the actual DCR update, not just a local exported JSON file.
3. Copy the changed `actions/nwb-cicd-monitoring/scripts/WorkflowRecord.psm1`, its updated test, and the new files under `monitoring/grafana` and `monitoring/infra` into Northwest's **devops-workflows** repository at the same relative paths. Merge through the normal PR process. The package's standalone `scripts/` and `tests/` copies are for local/standalone use, not additional files to copy into the bank repository.
4. Publish a recent completed application run with the collector. Verify the new attribution fields in Logs using the query below. Old rows without attribution remain **Not collected** until replayed. Do not change GitHub identity or Azure role assignments for these fields.
5. In Azure Portal, open **Monitor > Dashboards with Grafana > New > Import**. Import **only `nwb-dora-monitoring.grafana.json`**. Select the built-in Azure Monitor data source, **NWPROD-SUB**, **prd-cicdobservability-rg-eus2**, **East US 2**. Save as **nwb-dora-monitoring**. Do not import the `.ps1` files or Workbook JSON here.
6. Select the repository, service and source-event time range. Set `RunId` to `*` initially. For investigation, copy the **BuildRunId** from the run directory into `RunId`. That filter applies to workflow/job/step/verification panels; DORA totals still cover the selected repository, service and time window.
7. Refresh and verify the live dashboard against Logs. A Git merge does not update an already saved Azure dashboard: reimport the generated JSON after future layout/query changes.

```kusto
NWBWorkflowRuns_CL
| where TimeGenerated > ago(1d)
| where Repository == "northwest/doc_extraction"
| summarize arg_max(UpdatedAt, *) by Repository, RunId, RunAttempt
| project RunId, RunNumber, Actor, TriggeringActor, Conclusion, RunUrl
```

`RunId` is the unique GitHub run ID, used here as BuildRunId. `RunNumber` is the number shown for that workflow, which can repeat across workflows. Actor is the original initiator; TriggeringActor is the user who initiated the attempt, including a rerun. These are GitHub usernames, not a separate deployment approval audit.

## Post-deployment and smoke checks

The collector already retrieves job/step outcomes and durations. The new section presents them as verification checks when a reviewed stage mapping identifies them. It does not create or execute tests.

1. Ask the application pipeline owner to confirm which job/step checks the **deployed** application, what it tests, and how it reports failure. A typical banking example is a synthetic document-processing request after a Dev deployment, verifying the expected response without using customer data.
2. Use the exact names returned by GitHub, including reusable-workflow prefixes such as `dev / Verify release on Dev VM`. A name alone is not enough: confirm that the job really checks the deployed release. Do not label `deployment-contracts` or `Delivery check` as post-deployment checks merely because their names mention delivery.
3. In **devops-workflows**, edit `actions/nwb-cicd-monitoring/profiles/stages.json`. Append rules to the existing `nwb-delivery` profile's `Rules` array. Use the examples in `post-deployment-mapping-example.json`, replacing every placeholder. Do not replace the whole profile. Repositories using this profile then share the mapping; their `collector.json` does not need duplicate rules.
4. Use these exact stage labels: **Post-deployment verification**, **Smoke test**, **Rollback verification**. Map an entire dedicated verification job, or map a specific check step inside a mixed-purpose job. Keep any general job mapping; a matching step rule overrides it for that step.
5. Publish a new run or replay a completed run after merging. Confirm mapped results in the dashboard's **Post-deployment verification detail** panel. Old observations are not rewritten automatically.

The cards count jobs. A job mapping also labels its steps, including setup and cleanup; those steps are not independent test cases. Step-only check mappings appear in details and the attention table, but do not invent a verification job for the cards. Job and step counts must never be added together.

Passed means the workflow reported success. Skipped means the check did not run. Missing data means no mapped observation in scope, not a healthy deployment. A workflow using `continue-on-error` or otherwise suppressing a failing check can report success: confirm the pipeline's failure-handling contract with its owner. GitHub outcome metadata is not a full test report, endpoint availability monitor or proof of deployment success. Continuous application monitoring, detailed test-case ingestion, alerts and ServiceNow ticket creation are separate work.

## Reading the DORA cards

| Card | Meaning | Evidence needed |
| --- | --- | --- |
| Deployments / day | Observed production deployments divided by elapsed days in the selected window. | Confirmed deployment facts, real deployment time and production mapping. |
| Change lead time P50 | Median time from commit to first production deployment. | Linked change records with valid commit and first-production timestamps. |
| Change fail rate | Percentage of observed production deployments that required intervention. | Every observed deployment must have explicit failure classification. A CI job failure is not this metric. |
| Failed deployment recovery P50 | Median failure-to-restoration time for resolved deployment-related incidents linked to selected production deployments. | Linked incident start and restoration timestamps. Open/invalid records are shown separately. |
| Deployment rework rate | Percentage of observed production deployments marked as unplanned incident-related rework. | Explicit rework classification for every observed deployment. |

P50 means half of measured observations took this long or less. P95 means 95% took this long or less. Small samples should not be presented as a performance baseline.

Rates are unavailable if classification is incomplete; lead/recovery statistics describe only the valid linked evidence and must be read with coverage. No production evidence gives **Not available**, not a 0% failure rate. A daily zero means no deployment observed that day, not proof of no deployments. The current CI ingestion success does not establish complete DORA coverage.

The selected window uses source-event time: production deployment time for the DORA cohort, completion time for workflow/job/step investigation. Missing completion falls back to source update or start where available, then collection time. This differs from the existing CI dashboard's collection-time window. Recovery panels include observed recoveries through now for the selected deployment cohort, including those completed after the selected window.

Keep the current payload contracts: `NWBDeploymentFacts_CL` identifies repository, deployment, service and environment; `NWBChangeFacts_CL` and `NWBIncidentFacts_CL` join to it by deployment ID, service and environment. Classification, linked changes and incident ingestion still need implementation/validation where unavailable. Facts are deduplicated before date filtering so later classifications can update older deployments. Only retained records are available; retention limits historical completeness. Select one service for meaningful comparisons.

Definitions: [DORA software delivery metrics](https://dora.dev/guides/dora-metrics/).

## Validation before sharing

- A known failed run appears with the correct actor, run ID, attempt, outcome and GitHub link. A successful retry retains the earlier failed attempt.
- A mapped successful, failed and skipped verification check shows the corresponding outcome. An unmapped or pre-deployment check is not included as a post-deployment check.
- RunId narrows investigation only. Repository and service filters narrow all panels. An empty selection does not show green health or fabricated percentages.
- Replaying the same attempt updates its latest observation without increasing the attempt/deployment count.
- Reconcile production deployment, change and incident evidence with the owning team before presenting DORA rates as complete.
- Confirm the live portal renders the charts, result labels and links. Local checks validate JSON, query construction and collector logic; they cannot execute KQL against Northwest's workspace or validate the portal's Grafana rendering.

From the **devops-workflows** repository root:

```powershell
./monitoring/tests/Test-WorkflowCollector.ps1
./monitoring/grafana/Build-DoraGrafana.ps1
./monitoring/grafana/Test-DoraGrafana.ps1
```

`Build-DoraGrafana.ps1` runs independently of the Workbook files and defaults to the Northwest CI/CD workspace. For another workspace, pass `-WorkspaceResourceId` with its full Azure resource ID. An explicit `-WorkbookPath` is also supported; use only one of these overrides. It writes JSON only. Copy the generated `nwb-dora-monitoring.grafana.json` unchanged into the NWB repository and import that JSON into Azure, not a YAML conversion. The collector uses the same Windows runner and OIDC identity.

Deployment frequency uses the actual selected elapsed time, including windows shorter than an hour. One deployment in five minutes is a normalized rate of 288 deployments/day, not a claim that 288 deployments occurred. Zero or reversed windows give an unavailable rate.
