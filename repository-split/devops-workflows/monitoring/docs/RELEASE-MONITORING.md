# Release monitoring across environments

This adds release, rollback and required-check evidence to the DORA dashboard. Environment names are configuration values: Dev, Test, UAT, Production and other environments use the same code. The existing workflow/job/step collector continues unchanged.

Two different sources answer two different questions:

| Question | Source |
| --- | --- |
| What did the pipeline deploy, roll back or verify? | A release report produced by the application pipeline |
| Which Container App revisions and images were active when checked? | A read-only Azure control-plane snapshot |

A successful workflow is not proof of a release. A snapshot is an observation, not continuous application monitoring. The dashboard shows multiple active revisions, traffic weights and snapshot age. Snapshots older than 24 hours are marked stale. A failed inventory read replaces the previous good view with a failure, rather than claiming its old version is current. A target with no snapshot has no row.

## 1. Update devops-workflows

Copy the contents under `repository-split/devops-workflows` into the matching paths in the Northwest `devops-workflows` repository. Include the new reusable workflow, `actions/nwb-release-evidence`, the three changed/new collector script files (`NwbTransport.ps1`, `ReleaseEvidence.psm1`, `Send-ReleaseEvidence.ps1`), and the monitoring files. Merge through the normal PR process. No application code is deployed by these scripts.

## 2. Create the Azure tables and rule

In Azure Portal, open **Deploy a custom template → Build your own template in the editor**. Load `monitoring/infra/release-evidence.json`. Use:

- Subscription: NWPROD-SUB.
- Resource group: prd-cicdobservability-rg-eus2.
- Workspace: prd-cicdobservability-law-eus2.
- Location: eastus2.
- DCR: prd-cicdobservability-release-evidence-dcr-eus2.
- Data Collection Endpoint ID: the full resource ID of the existing prd-cicdobservability-dce-eus2 endpoint.

Review and deploy. This adds `NWBReleaseEvidence_CL`, `NWBVersionInventory_CL` and one DCR; it does not recreate the workspace or existing tables. The resource names can remain as above even when records describe nonproduction environments.

Give the collector managed identity **Monitoring Metrics Publisher** on the new DCR. Copy its `immutableId` into the caller's `cicd-observability` environment variable **AZURE_RELEASE_DCR_IMMUTABLE_ID**. Retain the existing DCE URL and Azure login variables.

For version inventory, give this identity **Reader** on each configured Container App resource, including resources in other subscriptions as needed. No deployment/write permission is required. The runner needs access to Azure management, login and the existing ingestion endpoint. Existing GitHub federation must cover the caller repository's `cicd-observability` environment.

## 3. Configure each application repository

For repositories that deploy to changing targets, use `monitoring/config/release-discovery.example.json` as `config/nwb-observability/release-targets.json`. This enables target discovery from each real deployment report, without a predefined target list. The report must supply Service, Environment and ResourceId. Keep the shared check IDs consistent in delivery templates, or adjust the default RequiredChecks policy. Explicit Targets entries supply the policy for a known target; a different environment for that resource is rejected, even when discovery is enabled. Discovery applies only to resource IDs absent from Targets.

The publisher identifies Container Apps, VMs, VM scale sets and AKS clusters from their Azure resource type. For Kubernetes application releases, use `k8s://cluster-id/namespace/kind/name` with a stable cluster identifier, for example `k8s://nwb-uat/loans/Deployment/document-api`. An AKS cluster resource ID identifies the cluster, not an application within it. Other Azure types are labelled `Other Azure resource`; unsupported identities are rejected rather than guessed. Platform detection does not read credentials or execute arbitrary deployment commands.

Generate these fields once in the shared deployment templates from actual deployment outputs and target parameters. GitHub run/job names alone do not establish the deployed application version, target or environment. VM releases need their installed application version from the deployment/verification process; Kubernetes reports should use actual workload images/digests. A pipeline report describes that operation, not the currently running state. Independent VM and Kubernetes inventory adapters are not implemented yet.

Discovery is for release reports only. Container App inventory still needs explicit targets and Reader access. With an empty Targets list, inventory stops with an explanatory error rather than reporting success without checking anything.

If you prefer an explicit target list, use the following configuration instead.

Copy `monitoring/config/release-targets.example.json` to the application's `config/nwb-observability/release-targets.json`. Replace the example resource ID with the real Container App resource ID. Add one Targets entry per resource; set the correct Service and Environment for each. Multiple applications can share an environment name. Use the same spelling as the existing collector mappings.

Keep only the named checks the delivery owner agrees are required, and list whether each applies to deploy, rollback or both. These requirements make missing checks visible. Empty requirements produce `not_configured`, never a pass. No numeric workflow IDs are needed. Existing `collector.json` does not need a new key for this addition.

Release reports can use other Azure resource IDs, including VMs. The version-inventory adapter supports Container Apps only; other target types produce an explicit failed snapshot until their adapter is implemented. Do not enter invented Container App IDs. For mixed hosting, use a separate targets configuration containing only Container Apps for inventory (the reusable workflow accepts `config_path`).

## 4. Test version inventory

Copy `monitoring/config/nwb-version-inventory.example.yml` to the application repository as `.github/workflows/nwb-version-inventory.yml`. Merge the configuration and workflow into its default branch.

Run **Actions → NWB version inventory → Run workflow**. First leave publish unchecked to review the snapshot; Azure login is still needed for the read. Then run with publish checked. This workflow has no schedule by default. Run after deployments/rollbacks or agree a refresh schedule before treating the inventory as routinely refreshed. The existing twice-daily collector health schedule is unchanged.

## 5. Connect real release and test results

The application pipeline owner must produce a report with the shape in `monitoring/config/release-report.example.json` after deployment and verification. That file is documentation, not a test to publish. Create a real report for every target and attempt, including failed and cancelled outcomes when the pipeline can report them.

- ReleaseId must be stable for retries of publishing the same operation, but unique for a different release attempt/target. For example: repository + run ID + run attempt + resource name + operation.
- Set CompletedAt from the actual operation completion in UTC, with `Z` or an offset.
- SourceVersion and TargetVersion should contain immutable image digests/release identifiers from the deployment, not guesses from the latest commit. Record RevisionName when known.
- For rollback, use Operation `rollback`, record both versions, and set RelatedDeploymentId to the affected original deployment identifier used by your deployment evidence.
- Set Result from deployment/rollback execution. Report check outcomes separately. A successful deployment with a failed smoke test remains deployment success with failed verification.
- Checks IDs must match the agreed required checks. Use actual `success`, `failure`, `timed_out`, `skipped` or `cancelled` results. Missing required results become `missing`.
- Do not include banking documents, customer data, request payloads, tokens, connection strings or raw application logs.

In a trusted publishing job that has checked out the approved configuration, obtained the report artifact from that same source run and signed in to Azure, add this step. Bind the artifact to the correct run/target; never publish an arbitrary report from an untrusted PR.

```yaml
- name: Publish release and verification evidence
  uses: northwest/devops-workflows/actions/nwb-release-evidence@main
  with:
    operation: release
    config_path: config/nwb-observability/release-targets.json
    evidence_path: release-report.json
    publish: 'true'
  env:
    AZURE_DCE_LOGS_ENDPOINT: ${{ vars.AZURE_DCE_LOGS_ENDPOINT }}
    AZURE_RELEASE_DCR_IMMUTABLE_ID: ${{ vars.AZURE_RELEASE_DCR_IMMUTABLE_ID }}
```

Run that publishing job with `if: always()` after its prerequisite jobs, provided a report exists. The publishing job needs `contents: read`, `id-token: write`, the approved runner and the existing `cicd-observability` Azure login configuration. The action uses installed PowerShell 7 and Azure CLI. It never installs tools or executes smoke tests. Attribution is the publishing workflow's repository, run, attempt, actor and commit; keep publication in the delivery run so its link identifies the release.

## 6. Import and verify the dashboard

After creating the tables, import/update `monitoring/grafana/nwb-dora-monitoring.grafana.json` in **Monitor → Dashboards with Grafana**. This is the DORA/release dashboard; the existing `nwb-cicd-monitoring` dashboard remains available.

Select Repository, Service and Environment. `*` includes all values. RunId filters release/run/check investigation, but not inventory or aggregate DORA. Inventory always shows the latest retained snapshot. The production DORA panels retain their production-evidence rules; selecting Dev will not relabel Dev measurements as production DORA.

Check the new tables in the existing workspace:

```kusto
NWBReleaseEvidence_CL
| where TimeGenerated > ago(24h)
| project TimeGenerated, Repository, Environment, ReleaseId, Operation, Result, Verification, RequiredChecks, RunUrl
```

```kusto
NWBVersionInventory_CL
| summarize arg_max(UpdatedAt, *) by Repository, ResourceId
| project TimeGenerated, Repository, Environment, Outcome, ActiveVersions, DetailCode
```

Before calling this live, verify one deployment and one rollback against the application's actual revision/image, a failed smoke test, a missing required check, two different environments, a repeated publish (one latest release row), and a failed inventory read. Compare traffic weights with Azure. New reports do not automatically populate the existing DORA change/incident tables or create ServiceNow tickets. Those integrations remain separate.

## Local checks

Run `monitoring/tests/Test-ReleaseEvidence.ps1` and `monitoring/grafana/Test-DoraGrafana.ps1`. Regenerate infrastructure with `monitoring/infra/Build-ReleaseEvidenceTemplate.ps1` and the dashboard with `monitoring/grafana/Build-DoraGrafana.ps1`. Offline checks cannot prove Azure ingestion, API access or KQL execution; validate those in Northwest before rollout.
