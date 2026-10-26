SHARED NORTHWEST CI/CD MONITORING

Start with ../../monitoring.md from this folder (monitoring.md at the repository
root) for the complete setup, operation and troubleshooting guide.

This directory holds the shared configuration examples, queries, infrastructure
source and tests. Runtime code is in ../../actions/nwb-cicd-monitoring.
Reusable workflow entry points are in ../../.github/workflows.
The repository-split/MOVE-KEEP-CHANGE.txt source-package guide contains the first
migration sequence. Copy that guide into this documentation folder for distribution.

RUNTIME FLOW
Caller workflow_run/manual event -> reusable workflow -> composite action from main
-> bundled PowerShell scripts -> existing Azure ingestion endpoint and DCRs.
The scheduled caller invokes the reusable health workflow -> same action from main.
Execution still uses the caller's GitHub context, runner access and environment.
The central repo does not subscribe to all organization repositories on its own.
devops-workflows main is the source of truth: callers and the shared action use
@main. Compatible central updates reach future new runs without caller SHA edits.
Keep shared interfaces compatible and review/test changes before merging to main.

COLLECTION BEHAVIOR
Completed workflow attempts, individual jobs/steps, reviewed stages and confirmed
GitHub deployment evidence are collected. Scripts validate the enterprise host
and caller repository. Unknown stages remain unmapped. Missing/skipped timing
stays null. Successful builds are not inferred to be deployments. Step failure
does not necessarily mean job failure. Production and deployment-success meaning
require reviewed environment mappings. Data is append-only; supplied queries
deduplicate observations. Manual replay is supported; durable backfill is not.

Health records identify the caller repository. The watchdog reads recent collector
outcomes and publishes a heartbeat last. A heartbeat demonstrates its GitHub read
and health-stream write, not full application telemetry completeness. History
pagination is bounded and incomplete history fails instead of asserting success.

CURRENT LIMITS
No detailed SonarQube/Snyk findings, live queue monitoring, change/incident source
integration, automatic ServiceNow tickets or complete DORA calculations are added
by this refactor. Application Insights instrumentation remains outside this scope.

AZURE AND QUERIES
Existing tables already contain Repository and can hold multiple repos when their
access/retention requirements permit sharing. Do not redeploy execution-health.json
as part of moving code between repos; the pilot resources already exist.
Job, step and stage queries group by repository to avoid merging equal job names.
verify-*.kql files retain the pilot repository as an editable example.

Alerts are disabled templates, not deployed rules. Deploy one set per onboarded
repository with a UNIQUE namePrefix and its repository parameter, using the shared
workspaceResourceId. Supply reviewed actionGroupIds and selectedWorkflowPaths.
The queries use __NWB_REPOSITORY__; the ARM template substitutes the repository.
For manual KQL execution, replace that token with the actual repo name first.
Run infra/Build-AlertTemplate.ps1 after query edits. Review thresholds, ownership,
notification noise and resolution behavior before enabling any rule. Changes to
these source templates do not update an existing Azure alert automatically.

TESTS (run from the central repository root)
./monitoring/tests/Test-WorkflowCollector.ps1
./monitoring/tests/Test-CicdCollection.ps1
./monitoring/tests/Test-PipelineExecution.ps1
./monitoring/tests/Test-MultiRepository.ps1
./monitoring/tests/Test-ReviewFixes.ps1
./monitoring/tests/Test-Package.ps1

PR-7-REVIEW-NOTES.md records review fixes and the required additive SourceUpdatedAt
column in the existing workflow table/DCR. Apply that schema change before publishing
the updated workflow records. Alerts remain disabled and have not been deployed.

These use mocked GitHub and Azure responses and require no live credentials.
Do not treat their success as proof of GitHub workflow schema acceptance or Azure
permissions. Validate both callers in the pilot repository before wider rollout.

REFERENCES
https://docs.github.com/en/enterprise-cloud@latest/actions/how-tos/reuse-automations/reuse-workflows
https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations
https://docs.github.com/en/actions/tutorials/create-actions/create-a-composite-action
https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-with-reusable-workflows
