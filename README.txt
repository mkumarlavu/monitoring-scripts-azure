NORTHWEST CI/CD MONITORING - EXECUTION AND ALERT FOUNDATIONS
Updated: 20 October 2026

START HERE
For the shared devops-workflows architecture, use repository-split/MOVE-KEEP-CHANGE.txt.
That folder contains separate central-repository and application-repository file sets.
The scripts and templates at this top level remain the original standalone package.

This is a local source package for northwest/doc_extraction. Nothing in this
folder has been deployed to Northwest GitHub, Azure or ServiceNow.
Follow docs/INSTALLATION.txt in order. Existing infrastructure is reused.

WHAT IS INCLUDED
1. Automatic collection after a repository workflow completes:
   - workflow outcome, attempt, timing, commit and source link;
   - individual job and step outcomes, timing, runner and matrix job identity;
   - reviewed business-stage mappings, with unmapped coverage visible;
   - successful deployments only when linked GitHub deployment evidence exists;
   - a collection success/failure record after component processing.
2. A separate scheduled watchdog observes collector workflow outcomes and sends a
   heartbeat even when no application workflow runs. It can observe a collector
   failure that occurred before its script started, including Azure login failure.
3. Two additional table definitions and one DCR with two streams, using the
   existing workspace and endpoint. The existing four tables/DCRs are preserved.
4. Job/step dashboard queries and three disabled Azure log alert templates:
   missing heartbeat, failed collector, and selected application workflow failure.

FOLDER GUIDE
templates/github/                 Two workflow templates to install in the app repo
scripts/nwb-observability/         Runtime PowerShell scripts and modules
config/nwb-observability/          Runtime collector configuration
config/stage-mapping-example.json  Example only; replace with reviewed real names
infra/execution-health.json       Two tables and one additional DCR
infra/record-schemas.json         Payload column/type contract
infra/alerts-disabled.json        Three disabled scheduled-query rules
infra/Build-AlertTemplate.ps1      Regenerate alert JSON after changing query files
queries/                          Dashboard, verification and alert KQL
tests/                            Offline behavioral tests with mocked APIs
docs/INSTALLATION.txt             Files, variables, Azure setup and test sequence
docs/METRICS-AND-ALERTS.txt        Metrics, limitations and remaining team inputs

IMPORTANT BOUNDARIES
- Install both workflow templates in .github/workflows on the DEFAULT BRANCH of
  northwest/doc_extraction. GitHub workflow_run observes workflows in that same
  repository. Keeping this package in a separate monitoring repository alone does
  not monitor the application repository. Cross-repository collection is not built.
- Job and step observation does not require publishing code inside Chinchia's
  application jobs. Meaningful business-stage names and deployment facts still
  need his reviewed mappings and evidence agreement.
- Seeing a step named SonarQube or Snyk supplies its result and duration, not its
  vulnerability counts, coverage or quality-gate details. Those integrations are
  future work and require tool access and agreed identifiers.
- DORA change/incident collection, production failure classification, automatic
  ServiceNow creation, stage-specific alerts and a deployed dashboard are not
  implemented by this update. See the metrics and alerts guide.
- Defaults permit local preview. Repository automation/publish flags must be set
  explicitly; alert resources always start disabled.
- The earlier Word source document under nwb-observability is an older package.
  It does not contain these additions. Use this folder as the source for this update.

LOCAL VERIFICATION
Run from this folder in PowerShell:
  ./tests/Test-WorkflowCollector.ps1
  ./tests/Test-CicdCollection.ps1
  ./tests/Test-PipelineExecution.ps1
  ./tests/Test-Package.ps1

Offline tests do not validate Azure permissions, Azure KQL execution, GitHub
workflow acceptance, the actual Windows runner or network access. Complete the
controlled preview and publishing checks before switching on automatic operation.




NWBWorkflowRuns_CL
| where TimeGenerated > ago(24h)
| where RunId == "138375551"
| order by TimeGenerated desc



NWBPipelineExecution_CL
| where TimeGenerated > ago(24h)
| where RunId == "138375551"
| project TimeGenerated, RunId, RecordType,
          JobName, StepName, Conclusion, DurationSeconds
| order by TimeGenerated desc


NWBWorkflowRuns_CL
| where TimeGenerated > ago(24h)
| order by TimeGenerated desc
| take 20



Open Azure Portal → Log Analytics workspaces → prd-cicdobservability-law-eus2 → Logs.

1. Check the workflow summary

NWBWorkflowRuns_CL
| where TimeGenerated > ago(24h)
| where Repository == "northwest/doc_extraction"
| where RunId == "323897996"
| project TimeGenerated, PipelineName, Conclusion,
          DurationSeconds, Environment, IsDeploymentPipeline


2. Check its jobs and steps

NWBPipelineExecution_CL
| where TimeGenerated > ago(24h)
| where Repository == "northwest/doc_extraction"
| where RunId == "323897996"
| project RecordType, JobName, StepName, Stage,
          Conclusion, DurationSeconds
| order by JobName asc, RecordType asc

Allow a few minutes if the records do not appear immediately. Compare the results with the application run in GitHub.
After confirming those records, enable automatic collection in:

doc_extraction → Settings → Secrets and variables → Actions → Variables
Repository variable	Value
CICD_MONITOR_AUTOMATION_ENABLED	true
CICD_MONITOR_AUTO_PUBLISH	true


Then observe the next normal application workflow completion. The collector should start and publish automatically, without you entering a run ID.


NWBCollectorHealth_CL
| where TimeGenerated > ago(1h)
| where Repository == "northwest/doc_extraction"
| project TimeGenerated, Operation, Outcome, DetailCode
| order by TimeGenerated desc



NWBPipelineExecution_CL
| where TimeGenerated > ago(7d)
| where Repository == "northwest/doc_extraction"
| where RecordType == "Job"
| summarize arg_max(UpdatedAt, *) by WorkflowPath, JobName
| where StageMappingKnown == false
| project WorkflowPath, JobName
| order by WorkflowPath asc, JobName asc


NWBCollectorHealth_CL
| where TimeGenerated > ago(1h)
| where Repository == "northwest/doc_extraction"
| where Operation == "heartbeat"
| project TimeGenerated, Outcome, DetailCode
| order by TimeGenerated desc



/subscriptions/18af3db6-624c-4522-9319-35501eb3fac0/resourceGroups/prd-cicdobservability-rg-eus2/providers/Microsoft.Insights/dataCollectionEndpoints/prd-cicdobservability-dce-eus2


NWBVersionInventory_CL
| where Repository == "northwest/doc_extraction"
| summarize arg_max(UpdatedAt, *) by ResourceId
| project UpdatedAt, Environment, Outcome, ActiveVersions







You are continuing an existing Northwest CI/CD observability implementation.
Please inspect the existing implementation and continue it; do not rebuild it
from scratch or assume every dashboard panel already has a connected data source.

This handoff describes the state as of 17 November 2026.

1. OBJECTIVE

Provide Azure Monitor dashboards showing:
- GitHub workflow, job and step outcomes and durations.
- Deployment and rollback history.
- Actual deployed application versions.
- Smoke tests and post-deployment verification.
- Collector health and evidence freshness.
- Production DORA metrics when the required production/change/incident evidence exists.

The dashboard is partially working. The main remaining issue is connecting
evidence from the real application deployment pipeline.

IMPORTANT RECENT CORRECTION:
Chinchia, the application pipeline owner, confirmed that deployment is happening
to an ON-PREMISES SERVER.

We had configured Azure Container App inventory before confirming the actual
delivery target. That inventory works, but it describes the Azure Container App.
It does NOT establish what Chinchia deployed on-premises.

The actual on-prem server, OS, deployment method, environment and version-reading
commands still need confirmation from her pipeline.


2. PEOPLE AND RESPONSIBILITIES

- Chinchia: application delivery pipeline, real deployment target, deployed
  versions, rollback and post-deployment checks.
- Matt / Mike: Azure permissions and identity administration.
- Leo: stakeholder receiving architecture and monitoring documentation.
- Our scope: monitoring collection, evidence contracts, configuration and dashboards.


3. REPOSITORIES AND LOCAL PACKAGING

Real Northwest repositories:
- northwest/doc_extraction
- northwest/devops-workflows

GitHub:
- https://northwest.ghe.com
GitHub API:
- https://api.northwest.ghe.com

The local packaging repository is:
C:\mycode\monitoring-scripts-azure

Its two repository content folders are:
- repository-split/doc_extraction/
- repository-split/devops-workflows/

Those packaging prefixes must NOT be added inside the real Northwest repositories.
For example:
repository-split/devops-workflows/actions/...
maps to:
northwest/devops-workflows/actions/...

The packaging repository's Git state does not prove what is merged into the
Northwest repositories. Inspect the real repository branches before assuming
a local change has been deployed.

The established design uses central devops-workflows @main references.
Preserve the current reference strategy unless a change is explicitly agreed.


4. EXISTING ARCHITECTURE

Application repository caller workflow
  -> reusable workflow in devops-workflows
  -> shared composite action
  -> installed PowerShell 7 scripts on an approved Actions runner
  -> GitHub API or Azure Management API reads
  -> structured JSON records
  -> Azure Logs Ingestion API using the existing DCE endpoint
     and matching DCR immutable ID / stream
  -> custom Log Analytics tables
  -> KQL dashboard queries
  -> Azure Monitor Dashboards with Grafana

These scripts publish to AZURE MONITOR LOGS / LOG ANALYTICS.
They do not write custom Azure Metrics time series.

Counts, rates, percentiles and snapshot ages are calculated in dashboard queries.

Authentication:
- GitHub OIDC through azure/login@v2.
- Existing Azure managed identity.
- GitHub API calls use the workflow's GitHub token.
- No new client secret or personal access token is required by this design.

The collectors check installed PowerShell 7 on Windows.
They do not install PowerShell or other tools automatically.


5. AZURE RESOURCES AND IDENTITY

Observability resources:
- Subscription: NWPROD-SUB
- Resource group: prd-cicdobservability-rg-eus2
- Log Analytics workspace: prd-cicdobservability-law-eus2
- Location: East US 2
- Existing DCE: prd-cicdobservability-dce-eus2
- Release/inventory DCR:
  prd-cicdobservability-release-evidence-dcr-eus2

Collector identity:
- Existing managed identity name begins:
  prd-cicdobservability-collector-mi...
- The screenshot truncated the full name; do not invent its suffix.
- AZURE_CLIENT_ID:
  eb7f1418-0c89-46dc-b309-e3a0b7c941fd

A Client ID identifies the identity used for login. Do not confuse it with the
principal/object ID when constructing Azure RBAC assignments.

GitHub environment in the calling repository:
- cicd-observability

Existing variables include:
- AZURE_CLIENT_ID
- AZURE_TENANT_ID
- AZURE_SUBSCRIPTION_ID
- AZURE_DCE_LOGS_ENDPOINT
- AZURE_WORKFLOW_DCR_IMMUTABLE_ID
- AZURE_DEPLOYMENT_DCR_IMMUTABLE_ID
- AZURE_EXECUTION_DCR_IMMUTABLE_ID
- AZURE_HEALTH_DCR_IMMUTABLE_ID
- AZURE_RELEASE_DCR_IMMUTABLE_ID

Release DCR immutable ID:
dcr-4191d46ff2d94c59a5609385ec2dadc9

Keep these values in GitHub variables. Do not hardcode the DCR ID in the
PowerShell script or collector.json.

The prd- identity/resource names do not establish the environment of a monitored
application. The identity's actual access depends on its role assignments.


6. FOUR DIFFERENT COLLECTION PATHS

A. CI/CD collector

Application caller:
.github/workflows/nwb-cicd-collector.yml

Central reusable workflow:
.github/workflows/nwb-cicd-collector-reusable.yml

Composite action:
actions/nwb-cicd-monitoring/action.yml

Runtime:
actions/nwb-cicd-monitoring/scripts/Invoke-SharedAction.ps1
actions/nwb-cicd-monitoring/scripts/Invoke-CicdCollection.ps1

Trigger:
- Completed application workflow event when automation is enabled.
- Manual replay using a completed application run ID and attempt.

Flags:
- CICD_MONITOR_AUTOMATION_ENABLED
- CICD_MONITOR_AUTO_PUBLISH

These flags' current remote values have not been verified in this handoff.

Reusable YAML sequence:
1. Check out approved caller configuration.
2. Sign in to Azure when publishing.
3. Call the shared action.
   - Check installed PowerShell 7.
   - Run the bundled monitoring scripts.

Internal collection sequence:
1. Validate the completed source run/attempt and mappings.
2. Send-WorkflowRun.ps1 reads run/jobs and creates a workflow record.
3. Send-PipelineExecution.ps1 reads jobs/steps and applies stage mappings,
   when CollectPipelineExecution is enabled.
4. Send-RunDeployments.ps1 reads GitHub deployment/status evidence.
5. Publish collection-health outcome when enabled.
6. Report accumulated component failures.

Each sender publishes its own records. There is no single combined upload after
all scripts finish. A collector job can fail after some records were accepted.

B. Collector health

Caller:
.github/workflows/nwb-collector-health.yml

Reusable:
.github/workflows/nwb-collector-health-reusable.yml

Runtime:
Invoke-CollectorHealth.ps1 and CollectorHealth.ps1

Configured schedule:
- 1 PM and 5 PM America/New_York.
- Also available manually.

Flags:
- CICD_MONITOR_HEALTH_ENABLED
- CICD_MONITOR_HEALTH_PUBLISH

The watchdog reads recent completed collector-run results and appends a heartbeat.
A heartbeat does not prove complete application collection or application health.

C. Azure Container App inventory

Caller:
.github/workflows/nwb-version-inventory.yml

Reusable:
.github/workflows/nwb-version-inventory-reusable.yml

Action:
actions/nwb-release-evidence/action.yml

Runtime:
Send-ReleaseEvidence.ps1 -Operation inventory

CURRENTLY MANUAL ONLY:
- workflow_dispatch
- publish defaults to false
- No inventory schedule or post-deployment automatic trigger has been added.

Preview still needs Azure login and resource read access.
It reads the configured Container App's revisions through Azure Management API.

It captures:
- Active revision/container names.
- Configured image references.
- Reported traffic weights.
- Reported health/running states.
- Snapshot timestamp, outcome, target identity and source-run link.

publish=false prints the snapshot.
publish=true sends it to NWBVersionInventory_CL.

It does not deploy, modify the app, run probes, read application documents,
or collect CPU, memory, request latency or application errors.

It remains Container Apps only. No on-prem server inventory adapter exists.

D. Actual release and check reports

Action:
actions/nwb-release-evidence/action.yml

Runtime:
Send-ReleaseEvidence.ps1 -Operation release
ReleaseEvidence.psm1

This accepts actual deployment/rollback/check evidence produced by the application
pipeline. The regular CI/CD collector and Azure inventory do not create it.

Real pipeline report integration is still pending.


7. TABLES AND WHAT THEY CONTAIN

NWBWorkflowRuns_CL
- Completed workflow outcome.
- Execution-window duration and timestamps.
- Run ID/number/attempt, actor, rerun actor, commit and source link.
- Source update time and reviewed workflow classification.

NWBPipelineExecution_CL
- Separate job and step records.
- Outcomes, start/completion times and duration.
- Exact job/step names, stage mapping and mapping-known flag.
- Runner identity and source-run information.

NWBDeploymentFacts_CL
- Confirmed successful GitHub deployment evidence.
- Deployment ID/time, commit, service/environment and production mapping.
- Requires successful status linked to the source run and reviewed mapping.
- A successful workflow alone does not create a deployment fact.
- Current publisher leaves revision/image digest empty.
- Intervention/rework classifications remain unknown.

NWBCollectorHealth_CL
- Collection outcome.
- Collector-run outcomes.
- Heartbeat timestamp.
- Source/collector run identifiers and safe detail code.

NWBReleaseEvidence_CL
- Actual deploy/rollback operation and result.
- Release ID, target, versions and completion time.
- Original deployment linkage for rollback.
- Required-check outcomes/counts and verification status.
- Actor/commit/publishing-run attribution.

NWBVersionInventory_CL
- Azure Container App revision snapshots.
- Image, traffic, reported health/running state, read outcome and observation time.

Production DORA also queries:
- NWBChangeFacts_CL
- NWBIncidentFacts_CL

These workflows do NOT currently implement change/incident publishers.
Release reports do not automatically populate those tables.


8. WHAT WAS FIXED AND VERIFIED

A. Release action variable wiring

actions/nwb-release-evidence/action.yml passes:
- AZURE_DCE_LOGS_ENDPOINT
- AZURE_RELEASE_DCR_IMMUTABLE_ID

Send-ReleaseEvidence.ps1 reads:
$env:AZURE_RELEASE_DCR_IMMUTABLE_ID

The user confirmed adding the variable and merging the action change.

B. Missing inventory configuration

Inventory initially failed because:
config/nwb-observability/release-targets.json
could not be found.

The screenshot revealed the filename was misspelled:
release-tragets.json

It was corrected to:
release-targets.json

C. Azure inventory permission

Configuration checkout and Azure login succeeded, but the revision read failed.

Matt had already assigned Monitoring Metrics Publisher on the release-evidence DCR.
That permits publishing; it does not grant read access to the Container App.

Matt then added Reader for the same collector identity on the backend resource.
Afterward, the user confirmed the workflow worked and data appeared in Logs.

Do not claim the original hidden error was definitely HTTP 403; the original
warning did not expose its HTTP status.

D. Safer diagnostic warnings

Send-ReleaseEvidence.ps1 was updated to report:
- target-validation / revision-read / snapshot-conversion phase.
- Sanitized HTTP status and an actionable hint.
- No arbitrary exception bodies, credentials or raw Azure response text.

Diagnostic tests passed before the later on-prem changes.

E. Confirmed live success

The user confirmed:
- Inventory records were visible in Log Analytics.
- The dashboard showed the backend revision/image.
- The shown Azure snapshot was preprod, recent, with reported healthy/running state.

This verifies the Azure inventory path, not the on-prem release pipeline.


9. CURRENT AZURE INVENTORY TARGET

Container App:
doc-extraction-backend

Subscription:
NWPREPROD-SUB

Resource group:
NWPre-DocIntel-RG-EUS2

Resource ID:
/subscriptions/c5c30481-0141-4306-85ed-c2b607b48a17/resourceGroups/NWPre-DocIntel-RG-EUS2/providers/Microsoft.App/containerApps/doc-extraction-backend

Current configuration:
- Service: doc-extraction
- Environment: preprod
- RequiredChecks: []

RequiredChecks=[] means no required-check policy is configured.
It must never be interpreted as verified success.

Only this backend is configured for Azure inventory.
Frontend, Redis and worker apps are not automatically included.

Preserve this working configuration while its Azure resource remains in scope.
Do not replace its Azure ResourceId with an on-prem server name.


10. SEPARATE CI/CD COLLECTOR FAILURE STILL NEEDS RECONCILIATION

An earlier collector run logged:
- Azure accepted the workflow record.
- Azure accepted 95 job/step observations.
- Deployment collection failed:
  "Deployment ... has no reviewed environment mapping."

Current local application collector.json is:

{
  "DefaultService": "doc-extraction",
  "CollectPipelineExecution": true,
  "PublishHealth": true,
  "WorkflowMappings": {},
  "StageProfiles": {
    ".github/workflows/delivery.yml": "nwb-delivery"
  },
  "StageMappings": {},
  "DeploymentEnvironments": {}
}

Inspect the real remote config; it may differ.

DeploymentEnvironments must be keyed by the EXACT GitHub deployment environment,
including capitalisation. This is not necessarily the same as an Azure
subscription name, an inventory label, or an on-prem target URI.

The reviewed mapping supplies:
- Service
- Environment
- Production: boolean
- SuccessMeansDeployed: boolean

Set SuccessMeansDeployed=true only when successful GitHub deployment status
actually follows completed application deployment.

Confirm the real on-prem environment before assigning Production.
Reconcile any conflict with GitHub's production_environment flag.
Do not mark nonproduction as production just to populate DORA.

This deployment mapping is separate from stage mappings and release-target policy.


11. WHY THE DASHBOARD IS INCOMPLETE

Dashboard:
monitoring/grafana/nwb-dora-monitoring.grafana.json

Generator:
monitoring/grafana/Build-DoraGrafana.ps1

Tests:
monitoring/grafana/Test-DoraGrafana.ps1

Existing CI dashboard:
monitoring/grafana/nwb-cicd-monitoring.grafana.json

Latest screenshots show:
- Azure Container App inventory populated.
- Release operation/history panels unavailable.
- Rollback/check panels unavailable.
- Verification-job cards unavailable.
- Production DORA unavailable.
- Production evidence coverage showed zero matching production deployments.

Interpret this as missing matching evidence in the selected scope.
It does not prove no deployments/checks ever occurred.
Inspect filters, source records, mappings, timestamps and ingestion.

Release panels need actual NWBReleaseEvidence_CL reports.
Verification panels need actual checks with reviewed stage mappings.
DORA needs confirmed production facts and its additional evidence.

Refreshing, reimporting JSON or changing colours does not create missing evidence.


12. CURRENT SHARED STAGE PROFILE

actions/nwb-cicd-monitoring/profiles/stages.json

Profile: nwb-delivery

Existing rules:
- changes -> Change detection
- build -> Build
- deployment-contracts -> Deployment validation
- Delivery check -> Delivery validation
- validate / Tests, quality and dependencies -> Validation

It currently contains no reviewed post-deployment/smoke/rollback verification rules.

Do not relabel deployment-contract validation or ordinary build tests as
post-deployment verification simply to populate the cards.

Get the exact actual check job/step names and confirm what they test.

Supported verification-stage labels:
- Post-deployment verification
- Smoke test
- Rollback verification

Step rules can override a job's general stage.

A helper query was added locally:
monitoring/queries/verification-mapping-inventory.kql

It lists retained exact job/step names and mappings for a selected source run.


13. NEW LOCAL ON-PREM SUPPORT: NOT YET CONFIRMED MERGED INTO NORTHWEST

The following changes are currently modified/untracked in the local packaging
repository. Do not assume they are already on Northwest devops-workflows main.

ReleaseEvidence.psm1 now accepts a reporting identity of the form:
onprem://site/server/application

It labels the report target:
On-premises application

This is a stable reporting identity, NOT a URL the collector connects to.
It requires explicit identifiers and rejects credentials, query strings,
fragments and traversal-like identities.

No remote execution, server polling or on-prem credentials were added.

These reports use the existing NWBReleaseEvidence_CL schema and release DCR.
No new table or DCR is needed just for this target identifier format.

Added example files:
- monitoring/config/onprem-release-targets.example.json
- monitoring/config/onprem-release-report.example.json

The examples contain REPLACE-* values and must not be published as real evidence.

Plan for actual application configuration:
- Keep release-targets.json for the working Azure inventory.
- Use a separate config/nwb-observability/onprem-release-targets.json
  for real on-prem release reporting.

Dashboard changes:
- Added "Collection coverage | why panels are empty".
- Shows matching workflow, job/step, verification, release, Azure inventory
  and production evidence counts and next actions.
- "Records present" does not mean healthy or complete.
- Missing stat values use a gray null-value mapping.
- The overview explicitly distinguishes Azure inventory from on-prem deployment.

Documentation:
monitoring/docs/ONPREM-RELEASE-MONITORING.txt

Local modified/new files:
- actions/nwb-cicd-monitoring/scripts/ReleaseEvidence.psm1
- monitoring/tests/Test-ReleaseEvidence.ps1
- monitoring/config/onprem-release-targets.example.json
- monitoring/config/onprem-release-report.example.json
- monitoring/grafana/Build-DoraGrafana.ps1
- monitoring/grafana/Test-DoraGrafana.ps1
- monitoring/grafana/nwb-dora-monitoring.grafana.json
- monitoring/queries/verification-mapping-inventory.kql
- monitoring/docs/ONPREM-RELEASE-MONITORING.txt
- monitoring/docs/RELEASE-MONITORING.md
- monitoring/grafana/DORA-README.md

Prepared package:
C:\mycode\output\NWB-OnPrem-Release-Monitoring-Update.zip

Its paths are relative to the real devops-workflows repository.
If you cannot access these local changes/package, ask me to provide them before
assuming the current GitHub source already supports on-prem identifiers.


14. REAL RELEASE REPORT REQUIREMENTS

The pipeline must produce facts from actual deployment/check outputs:
- ReleaseId: stable for repeat publication of the same operation, unique for
  distinct operations, targets and delivery attempts.
- Environment: confirmed actual environment.
- ResourceId: confirmed stable on-prem application identity.
- Operation: deploy or rollback.
- Result: success, failure or cancelled.
- CompletedAt: actual operation completion in UTC with timezone.
- SourceVersion: actual previous version when available.
- TargetVersion: actual deployed/attempted target version.
- RelatedDeploymentId: original deployment linkage for rollback.
- Checks: actual check IDs and outcomes.

Check results support:
success, failure, timed_out, skipped, cancelled.

Deployment Result is separate from verification.
A successful deployment with a failed smoke check must preserve both facts.

RequiredChecks in target configuration defines the expected check policy.
Missing required reports become missing.
Empty requirements produce not_configured, not passed.

Use actual deployed Docker image evidence if deployment uses Docker.
Use actual installed build/version if it is an installed service/application.
Do not substitute the latest source commit for an unverified deployed version.

Publish through:
northwest/devops-workflows/actions/nwb-release-evidence@main

Inputs:
- operation: release
- config_path: config/nwb-observability/onprem-release-targets.json
- evidence_path: actual same-run report path
- publish: true

Use a trusted publishing job in the SAME delivery run, existing Azure login,
cicd-observability environment and the existing DCE/release DCR variables.

Ensure reporting can run after failed verification when a report exists,
while preserving the application's failure outcome.

Exact job dependencies, report generation commands and artifact paths cannot
be finalized until the real delivery YAML is inspected.


15. DORA LIMITS

On-prem hosting does not prevent production DORA.
However, the real environment and evidence must be confirmed.

- Deployment frequency: confirmed production deployments.
- Change lead time: linked commit-to-first-production evidence.
- Change fail rate: complete intervention classification for observed deployments.
- Recovery time: linked deployment-related incident onset/restoration evidence.
- Rework rate: complete unplanned incident-related rework classification.

The current GitHub deployment publisher leaves intervention/rework classification
unknown. It does not infer classification from CI failure or rollback alone.

Do not convert unavailable metrics to zero or show them as healthy.
Do not classify Dev/preprod as production to fill cards.
Do not perform unnecessary deployments/rollbacks merely to create dashboard data.


16. OTHER IMPORTANT LIMITS

- Workflow duration is the job execution window, not complete queue-to-finish time.
- QueueSeconds currently remains null.
- Missing/skipped timing remains null, not zero.
- Job and step counts/durations must not be added together.
- GitHub outcomes do not constitute detailed test-case or vulnerability reports.
- Inventory image references are not automatically resolved from tags to digests.
- Manual inventory can miss changes and outages between observations.
- Inventory snapshots older than 24 hours are marked stale.
- No application CPU/memory/request latency/error collection is implemented by
  these CI/CD scripts.
- No detailed Sonar/Snyk findings or true runner queue measurements are collected.
- No ServiceNow change/incident ingestion or automatic ticket creation is connected.
- A monitoring managed identity does not grant SSH/WinRM/application access to
  an on-prem server. Use evidence produced by the existing delivery process.


17. VALIDATION AND DEPLOYMENT STATUS

Latest targeted local checks:
- Test-ReleaseEvidence.ps1: 83 checks passed.
- Test-DoraGrafana.ps1: 1,248 checks passed.

They cover publisher behavior with offline API replacements, schema alignment,
on-prem target validation, report handling, dashboard artifacts/query contracts
and layout.

They do NOT prove:
- Live on-prem version discovery.
- Actual pipeline report generation/publication.
- Live KQL execution for the new coverage query.
- Rendering of the new gray mapping in Azure's embedded Grafana version.

A broader Test-Package.ps1 run hit an unchanged alert-template CRLF/LF comparison
failure for collector-heartbeat-missing. The comparison matches after line-ending
normalization. The alert/template/check files were not changed by the on-prem work.
Do not report the entire test suite as passing.

A Git merge does NOT update the already saved Azure dashboard.
After code review/merge, import/update the generated Grafana JSON separately.

The user's existing Azure dashboard screenshots are from before the latest local
coverage/neutral-value improvements were confirmed imported.


18. SUPPORTING ARTIFACTS

Metric catalog:
C:\mycode\output\leo-monitoring-handoff\NWB-Metrics-Summary.csv
- 49 entries: published measurements/metadata and calculated dashboard summaries.

Exact published fields:
C:\mycode\output\leo-monitoring-handoff\NWB-Published-Fields.csv
- 123 entries including metadata and nested check/revision fields.

Existing editable architecture diagram:
C:\mycode\output\corrected-monitoring-flow\Corrected-Delivery-and-Monitoring.drawio

Treat actual deployment YAML as authoritative over diagram assumptions.
The diagram includes conceptual delivery targets, not proof of live routing.


19. WHAT I NEED YOU TO DO NEXT

1. Inspect the actual doc_extraction delivery YAML and every referenced reusable
   deployment/check workflow available to you.
2. Confirm actual on-prem target, OS, deployment method and environment.
3. Identify actual deployed-version outputs and actual verification checks.
4. Inspect current remote collector.json and resolve the missing deployment-
   environment mapping using the exact GitHub environment and reviewed semantics.
5. Review/apply the pending on-prem publisher and dashboard changes if not merged.
6. Integrate real release-report generation and same-run publication using actual
   pipeline outputs, including failure and rollback reporting where supported.
7. Add reviewed stage/check mappings without replacing existing mappings.
8. Validate Logs records against actual deployment/check results.
9. Regenerate/test/reimport the dashboard.
10. Report what is verified, what remains unavailable and exactly why.

Preserve the working Azure inventory and existing identity/DCR configuration.
Do not fabricate success records, production flags, image digests or test results.
Do not assume all unavailable panels are rendering bugs.

If required pipeline files or facts are unavailable, identify the exact missing
items and continue independent implementation/review work without guessing them.

Please start by giving me:
- A verified current-state assessment from the repositories you can inspect.
- The exact remaining source-to-table-to-panel gaps.
- A concrete file-by-file implementation plan.
- Then implement the authorized changes that can be completed from actual evidence.
