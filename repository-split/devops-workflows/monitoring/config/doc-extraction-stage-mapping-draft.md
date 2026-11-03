# Apply the initial delivery stage mappings

For the shared approach, follow [shared profiles and dashboard rollout](../docs/SHARED-PROFILES-AND-DASHBOARDS.md). The same five rules now live in the central `nwb-delivery` profile. The JSON beside this document remains a manual override/reference fragment; it is not needed when selecting that profile.

The adjacent `doc-extraction-stage-mapping-draft.json` is a proposed mapping based on complete job names shown in the user's Azure screenshots for run `323897996`. Review the labels with Chinchia. It is not loaded by the collector from this directory.

1. In Northwest `doc_extraction`, open `config/nwb-observability/collector.json` on a working branch.
2. Preserve the existing configuration. Merge the `.github/workflows/delivery.yml` entry from the draft into `StageMappings`. Do not replace the entire collector file with this fragment. Preserve any mappings already added in Northwest.
3. Confirm each exact job name, including capitalization and spaces, against the workbook's mapping inventory. Unlisted jobs remain `unmapped`; no numeric workflow ID is needed.
4. Review and merge the configuration into the repository's default branch. The collector reads its configuration from that branch.
5. In Actions, run **NWB CI/CD collector** against source run `323897996`, attempt `1`, with **Publish to Azure** unchecked. Check that the matching records contain the expected stage labels.
6. If correct, run once with publication enabled, or validate the next automatically collected application run. Refresh the workbook after ingestion. Replaying appends observations; the workbook selects the latest observation for each job/step within its selected window.

A job-level rule also labels its steps. A more specific rule containing both `JobName` and `StepName` overrides that label for the selected step. For example, the mixed tests/quality/dependencies job is labelled `Validation`; individual test and security steps can be classified separately once their exact names and purpose are confirmed.

This draft does not imply that the skipped build ran or that deployment validation deployed an application. It does not change workflow environment or deployment classification. Keep `WorkflowMappings` and `DeploymentEnvironments` as they are until those meanings are confirmed. The dependency download job is omitted because its full name was truncated in the screenshot. Coverage will therefore remain below 100%; the separate Copilot workflow also remains unmapped.

To retrieve full names in the workspace Logs page:

```kusto
NWBPipelineExecution_CL
| where TimeGenerated > ago(30d)
| where Repository == "northwest/doc_extraction" and RunId == "323897996"
| summarize arg_max(UpdatedAt, *) by Repository, RunId, RunAttempt, JobId, RecordType, StepNumber
| where RecordType == "Job"
| project WorkflowPath, JobName, Stage, Conclusion
| order by JobName asc
```

Use the collection window containing the run if it is older than 30 days.
