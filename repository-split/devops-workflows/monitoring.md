# Northwest CI/CD monitoring

Updated: 26 October 2026

PR 7 follow-up: the workflow publisher now includes `SourceUpdatedAt` for alert recency. Add this datetime column to the existing workflow table and DCR before publishing the updated code. See [review fixes and schema update](monitoring/docs/PR-7-REVIEW-NOTES.md) for the copy list, Azure steps and verified-commit merge blocker.

This guide explains what we have built, where the files belong, and how to set up and run the monitoring. The first application repository is `northwest/doc_extraction`. The shared implementation lives in `northwest/devops-workflows`, and its `main` branch is the source of truth.

The scope is CI/CD monitoring. Chinchia owns the application pipeline, including builds, tests, security scans, ACR and Container Apps deployment. Our monitoring reads the delivery results and sends structured records to Azure.

For example, imagine the bank releases an update to the application that extracts information from loan documents. We want to know whether the delivery pipeline passed, which job failed, how long testing took, and whether the update was successfully deployed. This implementation provides the collection needed to answer those questions. Monitoring the application's response time or the accuracy of document extraction is separate work.

## 1. Current position

| Area | Current position |
| --- | --- |
| Azure resources | The workspace, DCE, managed identity, six custom tables and five DCRs have been created, based on the setup and deployment screenshots shared during implementation. |
| Shared collection code | Prepared locally, with workflow, job, step, deployment and collector-health collection. |
| Repository sharing | The organization access option has been selected for `devops-workflows`; confirm it was saved. |
| Live collection | A successful end-to-end run of the shared version has not been verified in this guide. Complete the preview and publication checks below. |
| Dashboards | Queries are included. A deployed dashboard is not included in this package. |
| Alerts | Three disabled alert templates are included. Enabling and testing them is still required. |
| DORA | Some supporting fields and tables exist. Complete DORA calculations and source integrations are still required. |
| ServiceNow | No ServiceNow ticket-creation integration has been implemented in this package. |

Local checks use mocked GitHub and Azure responses. They do not prove that the Northwest runner, federation, network or live ingestion is working. Update this section with the run link and validation date after the first successful rollout.

## 2. How the data reaches Azure

```text
Application workflow completes in doc_extraction
  -> doc_extraction/.github/workflows/nwb-cicd-collector.yml
  -> devops-workflows reusable collector workflow @main
  -> shared action @main and its PowerShell scripts
  -> GitHub APIs: run, jobs, steps and deployment statuses
  -> Azure Logs Ingestion API through our DCE
  -> DCR stream and transformation
  -> Log Analytics custom table
  -> KQL queries for reporting and alerts
```

The collection happens after an application workflow completes. It is not a live stream of console output. The `workflow_run` event supplies the run ID and attempt number. The scripts retrieve that attempt's results through GitHub APIs, apply the repository configuration, and construct JSON records.

When publication is enabled, `azure/login` signs in using OIDC federation and the monitoring managed identity. The scripts request an Azure Monitor access token and send the records to the Logs Ingestion API. The request identifies the DCR by its immutable ID and the stream by its name.

The DCE does not go to GitHub and collect anything. The scripts running on the GitHub runner perform that work. The DCE is the receiving address, the DCR describes and routes the records, and the workspace stores them. Microsoft describes this ingestion path in the [Logs Ingestion API overview](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/logs-ingestion-api-overview).

There is a second path for monitoring the collector itself:

```text
Scheduled health workflow in doc_extraction
  -> reusable health workflow in devops-workflows @main
  -> read recent completed collector runs from GitHub
  -> send collector outcomes and a heartbeat
  -> NWBCollectorHealth_CL
```

## 3. Files in each repository

Copy the contents of each local repository folder into the matching Northwest repository. Do not create a `repository-split` folder inside either repository.

| Local source folder | Destination repository |
| --- | --- |
| `monitoring-scripts-azure/repository-split/devops-workflows/` | `northwest/devops-workflows` |
| `monitoring-scripts-azure/repository-split/doc_extraction/` | `northwest/doc_extraction` |

The shared repository contains:

```text
devops-workflows/
  monitoring.md
  .github/workflows/
    nwb-cicd-collector-reusable.yml
    nwb-collector-health-reusable.yml
  actions/nwb-cicd-monitoring/
    action.yml
    scripts/                         shared PowerShell implementation
  monitoring/
    config/                          examples, not live application settings
    infra/                           table/DCR and disabled alert templates
    queries/                         verification and reporting queries
    tests/                           offline checks
    docs/                            additional setup notes
```

The application repository needs:

```text
doc_extraction/
  .github/workflows/
    nwb-cicd-collector.yml
    nwb-collector-health.yml
  config/nwb-observability/
    collector.json
```

Keep the application source, application workflows and `scripts/IL`. Preserve existing reviewed mappings in `collector.json`; do not replace them with the empty starter example.

The old `scripts/nwb-observability` folder in the application repository becomes unnecessary for these shared callers. Remove it only after the shared workflows pass preview and Azure publication checks, and after confirming no other workflow still uses it. Do not leave older automatic monitoring workflows collecting the same runs alongside the new ones.

The top-level `monitoring-scripts-azure/templates/github` files belong to the earlier standalone package. Use the files under `repository-split` for this shared design.

## 4. What each workflow does

| Repository and file | Trigger and purpose |
| --- | --- |
| `doc_extraction/.github/workflows/nwb-cicd-collector.yml` | Receives completed workflow events and calls the shared collector. Also supports manual preview or replay of a completed run. |
| `doc_extraction/.github/workflows/nwb-collector-health.yml` | Schedules the shared health check at minutes 7, 22, 37 and 52 of each hour. Also supports manual execution. |
| `devops-workflows/.github/workflows/nwb-cicd-collector-reusable.yml` | Called through `workflow_call`. Selects the runner, reads caller configuration, signs in to Azure when publishing, and invokes the shared action. |
| `devops-workflows/.github/workflows/nwb-collector-health-reusable.yml` | Called through `workflow_call`. Signs in when publishing and runs the shared action in health mode. |

The collector listens for `workflow_run` with `types: [completed]` and `workflows: ["**"]`. It excludes the monitoring workflows themselves. The automatic job is controlled by a repository flag; completion events can still create skipped monitoring runs when collection is disabled.

The caller files must be on the application repository's default branch. A normal push to a feature branch is not a direct trigger for these monitoring workflows. Manual runs are also restricted to the default branch by our job condition. GitHub documents the default-branch requirement under [workflow events](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_run).

The health workflow checks collector runs updated within the last two hours, skips conclusions marked `skipped`, and records other completed outcomes. It publishes the heartbeat after its observations. Scheduling can be delayed by GitHub or runner availability.

A heartbeat proves that the health process could read GitHub and, when published successfully, reach the health stream. It does not prove that every application run was collected or that every other DCR is available. The health job shares runner and network dependencies with collection, so an Azure missing-heartbeat alert is needed to detect a complete stop.

## 5. Main is the source of truth

Both application callers reference the central reusable workflows at `@main`. Both central reusable workflows reference this action:

```yaml
uses: northwest/devops-workflows/actions/nwb-cicd-monitoring@main
```

The external actions use version tags: `actions/checkout@v4` and `azure/login@v2`. Our own monitoring workflows and action use `@main`. These are deliberate choices requested for this implementation; they do not satisfy Copilot's requests for immutable action references. If repository policy requires full commit SHAs, the maintainer must agree an exception or a different design before those findings can be resolved. Tags and branches can move, so a future run can execute updated code without a change to the caller YAML.

For a compatible script or workflow update, make a PR in `devops-workflows`, run the checks, and merge it into `main`. Future new monitoring runs use the updated central implementation. There is no action SHA or workflow SHA to update in every application repository.

Merging into the central repository does not itself start monitoring runs in the application repositories. Their existing events, schedules and manual triggers still control execution.

Keep workflow inputs and configuration compatible with existing callers. If an update introduces a required variable or mapping, the affected repositories still need that configuration change. Use review and checks on central `main`, because all onboarded repositories depend on it.

The workflow and action branch references resolve separately; they are not guaranteed to be one atomic snapshot if `main` changes during startup. Use a fresh run when validating a change, since rerunning a failed job can reuse an earlier reusable-workflow revision. Do not create a tag named `main`, because GitHub gives a same-named tag precedence over the branch. See [reusing workflows](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows).

## 6. Where the collection mechanism is in the code

All paths in this table are under [actions/nwb-cicd-monitoring/scripts](actions/nwb-cicd-monitoring/scripts).

| File | Responsibility |
| --- | --- |
| `Invoke-SharedAction.ps1` | Entry point used by the composite action. Selects collection or health and passes inputs to the appropriate script. |
| `Invoke-CicdCollection.ps1` | Reads the event or manual run ID, validates the run and attempt, reads configuration, and coordinates workflow, execution, deployment and health collection. |
| `Send-WorkflowRun.ps1` | Reads workflow/run information and jobs, builds the workflow record, and previews or publishes it. It has its own HTTP and publication code. |
| `WorkflowRecord.psm1` | Constructs the workflow-level record and execution duration from available job timestamps. |
| `Send-PipelineExecution.ps1` | Retrieves all pages of jobs for the selected attempt and sends job/step records. |
| `PipelineRecord.psm1` | Builds individual `Job` and `Step` records, applies stage mappings, and calculates available execution durations. |
| `Send-RunDeployments.ps1` | Retrieves deployments for the source commit and their statuses, then selects successful deployment evidence linked to the source run. |
| `DeploymentRecord.psm1` | Validates the deployment evidence and reviewed environment mapping, then constructs a deployment fact. |
| `Invoke-CollectorHealth.ps1` | Reads completed collector runs and creates recent outcome observations plus a heartbeat. |
| `CollectorHealth.ps1` | Builds health records with source and collector identifiers. |
| `NwbTransport.ps1` | Common GitHub context, pagination, limited HTTP retries and Azure publication functions. |
| `NwbRepository.ps1` | Validates the Northwest repository name used in records and API paths. |
| `Show-OidcClaims.ps1` | Prints issuer, subject and audience for federation setup. It does not print the JWT. |
| `Invoke-WorkflowEvent.ps1` | Legacy entry point retained for compatibility/tests. The current shared workflows do not call it. |
| `Initialize-PowerShell.ps1` | Finds and checks administrator-installed PowerShell 7, then adds its directory to the PATH for subsequent job steps. Never downloads or installs software. |

The GitHub API base is `https://api.northwest.ghe.com`. The important requests are:

```text
GET /repos/{owner}/{repo}/actions/runs/{run_id}/attempts/{attempt}
GET /repos/{owner}/{repo}/actions/runs/{run_id}/attempts/{attempt}/jobs
GET /repos/{owner}/{repo}/deployments?sha={commit_sha}
GET /repos/{owner}/{repo}/deployments/{deployment_id}/statuses
```

`Send-NwbRecords` in `NwbTransport.ps1` gets a Monitor token through Azure CLI and posts JSON arrays to:

```text
{DCE logs ingestion endpoint}/dataCollectionRules/{DCR immutable ID}
/streams/Custom-{table name}?api-version=2023-01-01
```

The actual URL is one line. Requests use bearer-token authentication. The common sender currently sends one record per request. HTTP 429 and server errors have limited retries; this is not a durable queue. A failure can leave some records already accepted, so replay is supported and reporting queries must deduplicate observations.

The collectors use PowerShell 7 (`pwsh`) on the Northwest Windows self-hosted runner. The Linux migration is deferred; keep the current Windows runner labels.

## 7. Azure resources and why we created them

| Setting | Pilot value |
| --- | --- |
| Subscription | `NWPROD-SUB` |
| Subscription ID | `18af3db6-624c-4522-9319-35501eb3fac0` |
| Resource group | `prd-cicdobservability-rg-eus2` |
| Region | East US 2 |
| Workspace | `prd-cicdobservability-law-eus2` |
| DCE | `prd-cicdobservability-dce-eus2` |
| Managed identity | `prd-cicdobservability-collector-mi-eus2` |

The resource names contain `prd`, but that does not mean every observed application deployment is production. Production classification comes from the reviewed deployment environment mapping.

### Workspace and tables

Portal navigation: **Resource groups > prd-cicdobservability-rg-eus2 > prd-cicdobservability-law-eus2 > Tables**.

The workspace is the central store for CI/CD records. Separate tables give each record type a clear schema.

| Table | Purpose and current collection |
| --- | --- |
| `NWBWorkflowRuns_CL` | Run results, source links, classification and timing. Implemented. |
| `NWBPipelineExecution_CL` | Job and step results, durations, runners and mapped stages. Implemented. |
| `NWBDeploymentFacts_CL` | Confirmed successful GitHub deployment facts. Implemented when required evidence exists. |
| `NWBCollectorHealth_CL` | Collection results, observed collector runs and heartbeats. Implemented. |
| `NWBChangeFacts_CL` | Change-to-deployment and lead-time information. Source integration remains to be implemented. |
| `NWBIncidentFacts_CL` | Deployment-related incidents and recovery information. Source integration remains to be implemented. |

In the loan-document example, workflow and execution records explain why a release failed. Deployment facts establish whether a release reached an environment. Future change and incident records will support delivery-performance reporting.

### Data Collection Endpoint

Portal navigation: **Search > Data Collection Endpoints > prd-cicdobservability-dce-eus2 > Overview**.

Copy **Logs Ingestion** for the runtime variable. Think of this as the receiving address for the records. The DCE does not store them and does not fetch them from GitHub.

The ARM resource ID is a different value, used when configuring the DCR:

```text
/subscriptions/18af3db6-624c-4522-9319-35501eb3fac0/resourceGroups/prd-cicdobservability-rg-eus2/providers/Microsoft.Insights/dataCollectionEndpoints/prd-cicdobservability-dce-eus2
```

Do not put this resource ID or the Configuration Access URL into `AZURE_DCE_LOGS_ENDPOINT`. Our setup uses a DCE; the Azure API also supports suitable DCR ingestion endpoints, but that is not the endpoint configured in these scripts.

### Data Collection Rules

Portal navigation: **Search > Data Collection Rules > select the rule > JSON View**.

| DCR | Destination |
| --- | --- |
| `prd-cicdobservability-workflows-dcr-eus2` | `NWBWorkflowRuns_CL` |
| `prd-cicdobservability-deployments-dcr-eus2` | `NWBDeploymentFacts_CL` |
| `prd-cicdobservability-changes-dcr-eus2` | `NWBChangeFacts_CL` |
| `prd-cicdobservability-incidents-dcr-eus2` | `NWBIncidentFacts_CL` |
| `prd-cicdobservability-execution-health-dcr-eus2` | `NWBPipelineExecution_CL` and `NWBCollectorHealth_CL` |

The DCR defines the input columns, transformation and destination. Look at `streamDeclarations`, `dataFlows`, `destinations` and `immutableId`. The ingestion call uses the immutable ID beginning `dcr-`, not the resource name or ARM resource ID. These are ingestion rules, not alert rules.

### Managed identity and access

Portal navigation: **Search > Managed Identities > prd-cicdobservability-collector-mi-eus2**.

The identity represents the collector in Azure. Its client ID is `eb7f1418-0c89-46dc-b309-e3a0b7c941fd`. Do not substitute its object/principal ID for the client ID.

OIDC federation establishes which GitHub workload may use this identity. DCR role assignments authorize ingestion. Both are needed. `id-token: write` in YAML allows the job to request an OIDC token; it does not by itself give Azure access.

### Application Insights

Frontend and backend Application Insights resources were also created. They are for application telemetry and are not required in this CI/CD ingestion path. Creating the resources alone does not instrument the applications. Their instrumentation and application dashboards are outside the current collection scope.

## 8. Azure setup and checks

The pilot resources already exist. Do not recreate them just because the code moves to `devops-workflows`.

1. Open the resource group and confirm the workspace, DCE, identity and five DCRs are present.
2. Open workspace **Tables** and confirm all six custom tables are present.
3. Open each runtime DCR's JSON and confirm its stream and destination match the intended table.
4. Copy the DCE Logs Ingestion endpoint and the runtime DCR immutable IDs for GitHub configuration.
5. Check identity permissions and federation as described below.

For reference, the new execution/health tables and shared DCR were created using [monitoring/infra/execution-health.json](monitoring/infra/execution-health.json). To provision that extension in an approved target:

1. In Azure Portal, search for **Deploy a custom template**.
2. Select **Build your own template in the editor**, load the JSON and save it.
3. Select the intended subscription and resource group.
4. Enter the existing workspace name, location, DCR name and full DCE resource ID.
5. Review retention. This template defaults to 30 days for the two new tables; agree any different value before deployment.
6. Review and create. After deployment, check both tables and the DCR and copy the new immutable ID.

This template creates only the execution/health extension. It does not recreate the original workspace, identity, four original tables or their four DCRs. The [schema file](monitoring/infra/record-schemas.json) describes the two new payload schemas.

To assign ingestion access, an Azure administrator should:

1. Open the relevant DCR and select **Access control (IAM)**.
2. Select **Add > Add role assignment**.
3. Choose **Monitoring Metrics Publisher**.
4. Under members, choose **Managed identity**, then **Select members**.
5. Select `NWPROD-SUB`, user-assigned managed identity, and `prd-cicdobservability-collector-mi-eus2`.
6. Review and assign, then verify the identity under **Role assignments**.
7. Repeat for the DCRs the collector will use. The new execution/health DCR needs its own assignment; assignments on the original four do not cover it.

The role and ingestion checks follow the [Microsoft portal tutorial](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/tutorial-logs-ingestion-portal/).

## 9. GitHub prerequisites and variables

### Shared repository access and runner

In `devops-workflows`, go to **Settings > Actions > General > Access**. Select **Accessible from repositories in the northwest organization** and save. In the application repository, confirm the allowed-actions policy permits the central workflows/action, `actions/checkout@v4` and `azure/login@v2`. A policy requiring full commit SHAs will need to be addressed by the repository owner before this version-tag design can run.

The runner must be available to the calling application repository. Keep `CICD_MONITOR_RUNNER_LABELS` set to `["self-hosted","Windows","X64"]`. Both monitoring workflows use this repository variable.

The Windows runner needs Git, PowerShell 7 and Azure CLI for publishing. The shared action checks for PowerShell 7 on PATH and in the standard Program Files installation directory, then exposes the working runtime to subsequent steps using GITHUB_PATH. If it cannot find or start PowerShell 7, it fails with a message for the runner administrator. It does not download, install or upgrade software.

The runner needs access to Northwest GitHub and its API, Microsoft Entra authentication and the DCE ingestion endpoint. Installing tools on your VDI only helps if it hosts the runner service. Check `pwsh --version`, `git --version` and `az version` in the runner service environment.


### Repository variables in doc_extraction

Navigation: **Settings > Secrets and variables > Actions > Variables > New repository variable**.

| Name | Initial value | Purpose |
| --- | --- | --- |
| `CICD_MONITOR_RUNNER_LABELS` | `["self-hosted","Windows","X64"]` | Current Windows runner labels. |
| `CICD_MONITOR_AUTOMATION_ENABLED` | `false` | Allows automatic completed-workflow collection when set to `true`. |
| `CICD_MONITOR_AUTO_PUBLISH` | `false` | Sends automatic collection results to Azure when set to `true`. |
| `CICD_MONITOR_HEALTH_ENABLED` | `false` | Allows scheduled health jobs when set to `true`. |
| `CICD_MONITOR_HEALTH_PUBLISH` | `false` | Sends scheduled health results to Azure when set to `true`. |

Use lowercase string values `true` and `false`. Manual runs use their own `publish` input and can publish even while these automatic flags are false.

### Environment variables in doc_extraction

Navigation: **Settings > Environments > cicd-observability > Environment variables > Add variable**. If the environment does not exist, an administrator should create it with that exact name. If **Environments** is unavailable to you, ask a repository administrator to do this.

| Name | Value or where to obtain it |
| --- | --- |
| `AZURE_CLIENT_ID` | `eb7f1418-0c89-46dc-b309-e3a0b7c941fd`; verify under the monitoring identity's Overview. |
| `AZURE_TENANT_ID` | Copy the monitoring identity's `properties.tenantId` from Azure JSON View, or the subscription's directory tenant ID. Confirm it rather than assuming the application identity uses the same tenant. |
| `AZURE_SUBSCRIPTION_ID` | `18af3db6-624c-4522-9319-35501eb3fac0` |
| `AZURE_DCE_LOGS_ENDPOINT` | Exact **Logs Ingestion** HTTPS URL from DCE Overview, without an added API path or query. |
| `AZURE_WORKFLOW_DCR_IMMUTABLE_ID` | `properties.immutableId` from `prd-cicdobservability-workflows-dcr-eus2`. |
| `AZURE_DEPLOYMENT_DCR_IMMUTABLE_ID` | `properties.immutableId` from `prd-cicdobservability-deployments-dcr-eus2`. |
| `AZURE_EXECUTION_DCR_IMMUTABLE_ID` | `dcr-9d940c01478540a2b1e9d68ac31f40dc`; verify against the execution/health DCR. |
| `AZURE_HEALTH_DCR_IMMUTABLE_ID` | Same execution/health DCR immutable ID as above. |

Keep these settings in the caller's environment. Do not duplicate them in `devops-workflows` just to host reusable code, and do not overwrite repository-level Azure variables used by the application's deployment identity. Environment approvals or branch restrictions can delay or prevent monitoring jobs; configure them deliberately with the administrator.

No client secret or manually supplied GitHub PAT is required by this implementation. GitHub supplies the caller token. Changes and incidents have no runtime DCR variables here because those integrations are not implemented yet.

### OIDC federation

1. Make the caller and central workflows available, keeping automatic flags false.
2. Run the collector manually with a completed source run ID, `publish=false` and `show_identity=true`.
3. Copy only the issuer, subject and audience displayed by the identity diagnostic.
4. In Azure, open the managed identity and **Settings > Federated credentials**.
5. Have the administrator create or verify the credential matching those exact claims. The configured audience is `api://AzureADTokenExchange`.
6. If the existing subject policy includes reusable-workflow identity, verify it permits the central workflow reference at `main`.
7. Test a controlled publishing run.

Use the actual issuer reported by Northwest's GitHub instance; do not guess a public GitHub issuer. A federation trust for `doc_extraction` does not automatically trust every other repository. See [GitHub's OIDC reference](https://docs.github.com/en/actions/reference/security/oidc).

## 10. Configure workflows, stages and environments

Edit `config/nwb-observability/collector.json` in the application repository. The following is an example only. Replace `.github/workflows/application.yml`, job names and the `dev` environment key with actual values before using it:

```json
{
  "DefaultService": "doc-extraction",
  "CollectPipelineExecution": true,
  "PublishHealth": true,
  "WorkflowMappings": {
    ".github/workflows/application.yml": {
      "Service": "doc-extraction",
      "Environment": "dev",
      "IsDeploymentPipeline": true
    }
  },
  "StageMappings": {
    ".github/workflows/application.yml": [
      { "JobName": "Build", "Stage": "Build" },
      { "JobName": "Test", "Stage": "Test" },
      { "JobName": "Quality", "StepName": "SonarQube scan", "Stage": "Security" },
      { "JobName": "Deploy", "Stage": "Deploy" }
    ]
  },
  "DeploymentEnvironments": {
    "dev": {
      "Service": "doc-extraction",
      "Environment": "dev",
      "Production": false,
      "SuccessMeansDeployed": true
    }
  }
}
```

GitHub supplies workflow IDs, names, paths, jobs and steps automatically. No numeric IDs need to be entered for basic collection. Leave WorkflowMappings and StageMappings empty to collect new workflows immediately. Optional overrides use the exact WorkflowPath from preview output (without an @ref suffix); paths take priority over legacy numeric-ID keys. A changed ID with the same path retains the override. A renamed file needs its optional override updated. Copy exact, case-sensitive job and step names, including matrix-expanded names. Step-specific stage rules take precedence over job rules.

Set `IsDeploymentPipeline` to true only where successful completion is expected to have deployment evidence. Set `SuccessMeansDeployed` to true only after confirming with the pipeline owner that the GitHub deployment status really represents completed deployment.

Unmapped workflows are still collected with an unclassified environment. Unmapped jobs and steps retain their raw names and have `StageMappingKnown=false`. Skipped or missing execution timing remains null; unknown duration is not zero.

### Deployment evidence required from the application pipeline

The current collector needs a GitHub deployment for the source commit, a successful deployment status, and a status `log_url` linked to the source workflow run. It also requires a reviewed environment mapping. It does not query Container Apps directly to discover deployments.

Agree these details with Chinchia:

- Which workflows deploy, and to which GitHub/Azure environments?
- Does the pipeline create GitHub deployment records and success statuses?
- Does the status link identify the exact workflow run?
- Which environments count as production?
- Do job and step names accurately identify build, test, scan and deploy work?

For a successful run marked as a deployment pipeline, missing qualifying deployment evidence causes collection to report a deployment error. A build-only workflow can legitimately produce no deployment facts. A pipeline spanning several environments still has one configured workflow-level environment; deployment facts use their own environment mappings.

## 11. First rollout, step by step

1. Keep the four automatic enable/publish flags false in `doc_extraction`.
2. Merge the central action, all 15 scripts, both reusable workflows and supporting monitoring files into `devops-workflows/main`.
3. Confirm shared repository access, runner access and allowed actions.
4. Replace the two monitoring files in `doc_extraction/.github/workflows` with the small `@main` callers. Preserve the reviewed configuration and old scripts for now.
5. Merge the caller files and configuration into the application repository's default branch.
6. In **Actions**, open a completed application workflow run. Copy its numeric run ID from `/actions/runs/{id}`. Do not choose a monitoring run.
7. Open **NWB CI/CD collector > Run workflow**, select the default branch and enter that run ID. Use `run_attempt=0` for the latest attempt, `publish=false`, and `show_identity=false` unless checking federation.
8. Check the preview. Confirm repository, run ID, attempt, job/step names, classifications and links. Missing deployment facts must be explained by the source evidence rather than guessed.
9. Run **NWB collector health** manually with `publish=false`. Inspect its preview records.
10. Complete the federation and DCR role checks. Run the collector again with `publish=true`, then run health with `publish=true`.
11. Verify records in Azure using the queries below. A successful API response alone is not the final check.
12. Set `CICD_MONITOR_AUTOMATION_ENABLED=true` and `CICD_MONITOR_AUTO_PUBLISH=true`. Complete an application workflow and verify automatic collection.
13. Set `CICD_MONITOR_HEALTH_ENABLED=true` and `CICD_MONITOR_HEALTH_PUBLISH=true`. Verify a scheduled health observation.
14. Remove unused old monitoring scripts in a separate cleanup PR after checking references. Keep the application scripts and a working rollback commit.

The job environment uses `deployment: false` so monitoring does not create its own application deployment records. The Azure settings still come from `cicd-observability`.

## 12. Verify records in Log Analytics

Open **Azure Portal > Log Analytics workspaces > prd-cicdobservability-law-eus2 > Logs**. Set the time range to include the collection time. Allow for ingestion delay, then refresh. Replace the example run ID below.

Workflow record:

```kusto
NWBWorkflowRuns_CL
| where Repository == "northwest/doc_extraction"
| where RunId == "REPLACE_WITH_ACTUAL_RUN_ID"
| summarize arg_max(UpdatedAt, *) by Repository, RunId, RunAttempt
| project PipelineName, RunId, RunAttempt, Conclusion,
          DurationSeconds, Environment, RunUrl
```

Job and step records:

```kusto
NWBPipelineExecution_CL
| where Repository == "northwest/doc_extraction"
| where RunId == "REPLACE_WITH_ACTUAL_RUN_ID"
| summarize arg_max(UpdatedAt, *)
    by Repository, RunId, RunAttempt, JobId, RecordType, StepNumber
| project JobName, StepName, RecordType, Stage, StageMappingKnown,
          Conclusion, DurationSeconds, RunAttempt
| order by JobName asc, StepNumber asc
```

Latest published heartbeat:

```kusto
NWBCollectorHealth_CL
| where Repository == "northwest/doc_extraction"
| where Operation == "heartbeat"
| summarize LastHeartbeat=max(TimeGenerated) by Repository
```

The pipeline record types are `Job` and `Step`, including their capitalization. A previous example using `RecordType == "job"` would not match these records.

Use [verify-deployments.kql](monitoring/queries/verify-deployments.kql) to inspect deployment facts. Keep the source run open in GitHub and compare the reported evidence. A successful run does not establish that a release reached production.

`TimeGenerated` and `UpdatedAt` represent observation/collection time. Execution and deployment timestamps describe the source event. Use source timestamps when reporting when delivery actually happened, especially after replaying older runs.

`SourceUpdatedAt` in workflow records comes from GitHub's attempt `updated_at`, even when no job timing exists. The selected-workflow failure alert uses this field for recency. It is not an exact completion timestamp. Missing values remain null; see the required schema update in the PR 7 notes before using this publisher.

Replaying appends observations. Deduplicate by stable identifiers before counting. For a per-attempt report keep `RunAttempt`; for a final-result-per-run report choose the latest attempt explicitly. Do not silently mix the two definitions.

## 13. Metrics, dashboards and DORA

The records support the following reporting once ingestion is validated:

| View | Useful measures |
| --- | --- |
| Workflow overview | Runs/attempts, successes, failures, cancellations, duration trends and source links. |
| Job and step detail | Failed jobs/steps, slow jobs/steps, median and 95th-percentile durations, runner names/groups. |
| Stages | Mapped build/test/security/deploy results and mapping coverage. |
| Deployments | Confirmed successful deployments by service and environment, with source commit and run link. |
| Collector health | Collection failures, observed collector failures and latest heartbeat. |
| Data completeness | Unclassified workflows, unmapped stages and missing deployment evidence. |

Query files are in [monitoring/queries](monitoring/queries). `pipeline-jobs.kql`, `pipeline-steps.kql`, `stage-coverage.kql` and `collector-health.kql` provide starting views. Dashboard implementation and agreed filters are still needed.

Agree whether success rates count attempts or final workflow results, and how cancellations/skips are treated. Do not add job durations to obtain wall-clock pipeline duration because jobs may run in parallel. Workflow duration currently uses the available job execution span; `QueueSeconds` is not populated. Job and step records overlap, so adding both double-counts execution. A failed step can also be tolerated by the application pipeline without failing the whole job.

For SonarQube and Snyk, current collection can show the result and duration of their GitHub jobs/steps. It does not collect code coverage, quality-gate details, vulnerability counts or finding severity. Those need explicit tool/API or report integrations.

DORA reporting is planned. Successful production deployment evidence can support deployment frequency. Change lead time needs commit/change-to-deployment linkage; change failure rate needs reliable deployment failure classification; failed-deployment recovery time needs incident and restoration evidence; rework reporting needs an agreed classification. The change and incident tables are preparation for this work, not evidence that these metrics are complete.

The deployment record's classification-known flags currently remain false. Do not treat an unknown classification as a healthy deployment or claim a zero change failure rate. A failed CI build alone is not a production change failure.

## 14. Alerts and ServiceNow

The package includes [monitoring/infra/alerts-disabled.json](monitoring/infra/alerts-disabled.json) and these source queries:

- `alert-selected-workflows.kql`: failures in an explicitly selected workflow allowlist.
- `alert-collector-failed.kql`: observed collector failures.
- `alert-heartbeat-missing.kql`: missing heartbeat for an expected repository, including when no heartbeat rows exist.

These rules are disabled by default. The workflow allowlist and action-group destinations start empty. They do not create ServiceNow incidents.

Before enabling alerts:

1. Validate ingestion and choose the repositories/workflows that require action.
2. Agree thresholds, severity, owners and expected response with the team.
3. Use a unique alert name prefix per repository and the correct workspace resource ID.
4. If editing source queries, regenerate the template using `monitoring/infra/Build-AlertTemplate.ps1` and review the result.
5. Configure the approved action group and notification destination, deploy, then test firing and recovery before enabling broadly.
6. If ServiceNow is required, implement and test the integration, authentication, assignment group, duplicate suppression and resolution behavior.

Portal navigation for deployed rules is **Azure Monitor > Alerts > Alert rules**. Source templates alone do not create or update deployed alerts.

A failed feature-branch experiment should not automatically create a bank incident. Escalation should reflect an agreed business impact, such as repeated failure of a critical delivery workflow. Collector failures must also be distinguishable from application delivery failures.

## 15. Troubleshooting

| What you see | What to check |
| --- | --- |
| No collector run after a push | There is no direct `push` trigger. Merge the caller to the default branch, check the automation flag, then complete an application workflow or start a manual run. |
| Workflow fails immediately, with no job graph | Read the workflow validation annotation/check details. Confirm YAML, `uses` paths, shared repo access and action policy. Do not assume this is an Azure failure. |
| Reusable workflow/action not found | Confirm the files exist on `devops-workflows/main`, names match, organization access was saved, and the caller permits the shared components. |
| Job stays queued | Confirm an online runner matches all three labels and its group permits the caller repository. |
| Job waits for approval | Check protection rules on the caller's `cicd-observability` environment. |
| `pwsh` not found on Windows | Check the installed-runtime step. Ask the runner administrator to verify PowerShell 7 can start under the service account, using PATH or the standard Program Files installation. No automatic installation is attempted. |
| `az` not found | Install/check Azure CLI in the runner service environment. The PowerShell setup step does not provide Azure CLI. |
| Azure login fails | Check monitoring client/tenant/subscription variables, `id-token: write`, and the exact federation issuer/subject/audience. |
| Azure ingestion returns 403 | Check Monitoring Metrics Publisher on the specific DCR used by the request, identity selection, and network restrictions. |
| Ingestion returns 400 or no expected table records | Check immutable ID, stream name, column names/types and DCR destination. Then check query time range and ingestion delay. |
| Jobs show `unmapped` | Optionally add exact job/step mappings under the workflow file path; raw job and step names are already collected. |
| Deployment table is empty | Confirm GitHub deployment/status evidence, exact run link and environment mapping. A green build or Azure deployment alone is insufficient for this collector. |
| Heartbeat is missing | Check health flags, runner availability, GitHub history read, Azure login, endpoint and health DCR permission. |
| Duplicate-looking rows | Replays append records. Use the latest observation per stable record key in reporting queries. |
| Health history/pagination error | The script refuses to claim complete observation when its bounded history read is incomplete. Investigate history size/API results and extend the design if needed. |
| New code does not appear during a rerun | Start a fresh run after confirming the central change is merged to `main`. |

Do not paste access tokens or JWTs into troubleshooting messages. The identity diagnostic is designed to print only the claims needed for federation checks.

## 16. Maintenance, tests and onboarding another repository

From the `devops-workflows` repository root, run the existing offline checks in PowerShell:

```powershell
./monitoring/tests/Test-WorkflowCollector.ps1
./monitoring/tests/Test-CicdCollection.ps1
./monitoring/tests/Test-PipelineExecution.ps1
./monitoring/tests/Test-MultiRepository.ps1
./monitoring/tests/Test-ReviewFixes.ps1
./monitoring/tests/Test-PowerShellBootstrap.ps1
./monitoring/tests/Test-Package.ps1
```


After changes to collection behavior, test preview and controlled publication in the pilot. The offline checks do not validate live GitHub YAML acceptance, OIDC, ARM deployment or KQL execution.

To onboard another Northwest repository:

1. Copy the two small caller workflows and create its own reviewed `collector.json`.
2. Keep the caller filenames unchanged; the health script looks up `nwb-cicd-collector.yml`.
3. Set runner labels and the four flags, initially false.
4. Create its `cicd-observability` environment and Azure variables.
5. Confirm shared workflow access, runner access and federation for that caller.
6. Agree whether it may use the existing workspace/DCRs/identity or needs separate resources. Do not assume organization membership grants Azure access.
7. Complete preview, publication and automatic-run checks. Verify the new repository and service values in Azure before enabling its alerts.

There is no need to copy the shared scripts into each application repository. The code currently validates the Northwest organization and the Northwest GitHub/API hosts; moving to another GitHub host would require a code change.

To stop automatic collection, set the four enable/publish flags to false. Manual runs remain available and can still publish if explicitly selected. For a central regression, revert the offending PR on `devops-workflows/main` and validate a fresh run. To undo the initial migration, restore the last working standalone caller/scripts together. Neither action deletes existing Azure records.

## 17. Short walkthrough for a team demo

1. Explain the loan-document release example and the division between application CI/CD and monitoring.
2. Open the two caller files in `doc_extraction/.github/workflows`. Show the completion event, health schedule and central `@main` references.
3. Open `config/nwb-observability/collector.json`. Explain workflow, stage and deployment mappings using actual names.
4. Open the two reusable workflows in `devops-workflows`. Show runner selection, the monitoring environment, Azure login and the shared action.
5. Open `Invoke-CicdCollection.ps1`, `Send-PipelineExecution.ps1` and `NwbTransport.ps1`. Point out the event run ID, GitHub jobs API and Azure POST.
6. In Azure, show the resource group, workspace tables, DCE Logs Ingestion address, a DCR JSON view and the managed identity's DCR role assignment.
7. Show a verification query and explain the intended dashboard views. If data has not been validated yet, present the query as the planned check.
8. Finish with the remaining work: live validation, reviewed mappings, dashboard implementation, alert tuning, complete DORA inputs and ServiceNow integration.

Keep the status clear: resources created, code prepared, and behavior verified are three different milestones. Record the first successful source run, collector run and Azure query evidence when validation is complete.
