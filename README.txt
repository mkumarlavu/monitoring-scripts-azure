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






1. Core DORA metrics
#	Metric	What it measures	How to source in GitHub
1	Deployment Frequency	How often you deploy to prod	deployment_status = success on the prd environment
2	Lead Time for Changes	Commit (or PR merge) to running in prod	First commit timestamp to prod deployment timestamp, per SHA
3	Change Failure Rate	% of prod deploys causing a failure (rollback, hotfix, incident)	Failed or rolled-back deploys ÷ total prod deploys; label hotfix PRs
4	Failed Deployment Recovery Time (formerly MTTR)	Time from a bad deploy to restored service	Incident open to resolved, or failed deploy to next good deploy
5	Rework Rate	% of deploys that are unplanned fixes	Hotfix/revert PRs ÷ total deploys. [Likely]: this was added in DORA’s 2024 report
–	Reliability (operational performance)	SLO attainment and availability	From Datadog/OTel, not GitHub. [Certain] DORA added it in 2021
2. Pipeline health (GitHub Actions)
Workflow success rate, per workflow and per branch
Workflow failure rate, split by cause: test, build, infra or runner, flaky
Mean and p95 pipeline duration
Queue time (waiting for a runner), which matters for self-hosted runners
Time per job and step, to find the slowest steps
Re-run rate (re-run count ÷ total runs), a proxy for flakiness
Flaky test count and trend
Cancelled run rate
Mean time to fix a broken main branch (red to green)
Main branch “red” duration, as % of time
Cache hit rate (actions/cache)
Artifact size and upload time
Runner utilization and idle time (self-hosted)
GitHub Actions minutes consumed and cost per repo or workflow
Concurrency limit hits
3. Deployment and release metrics
Deploys per environment (dev/qa/stg/prd), counted separately
Deployment success rate per environment
Deployment duration (pipeline start to rollout complete)
Rollback count and rollback rate
Revert commit count
Hotfix deploy count
Time from approval to deploy (environment protection rules)
Manual approval wait time
Promotion lead time (dev → qa → stg → prd)
Deploys outside the change window
Batch size: commits or PRs per deploy (smaller batches correlate with lower failure rates) [Likely]
4. Post-deployment checks (what your manager is asking about)
Smoke test pass/fail after each deploy
Health and readiness probe status after rollout (kubectl rollout status success)
Pod restarts or CrashLoopBackOff within N minutes of a deploy
Error rate delta, before vs after the deploy (5xx, exceptions)
Latency delta (p50/p95/p99), before vs after
Synthetic check results (Datadog Synthetics or similar)
Canary or blue-green analysis pass rate, if used
Alerts fired within 30 or 60 minutes of a deploy
Incidents linked to a deployment SHA
DB migration success or failure (EF Core migration step result)
Config drift detected after deploy
Time to detect a bad deploy (deploy to first alert)
5. Code flow and PR metrics (feed lead time)
PR cycle time (open → merge)
Time to first review
Review iterations per PR
PR size (lines changed)
PRs merged per week
Stale PRs (open more than N days)
Direct pushes to main (should be 0)
6. Quality and security gates
Test pass rate and test count trend
Code coverage trend
SAST findings per scan (CodeQL)
Dependency vulnerabilities (Dependabot), split by severity
Secret scanning alerts
Container image vulnerabilities (Trivy/Defender), by severity
Mean time to remediate critical vulnerabilities
Policy or gate failures that blocked a deploy
SBOM generated per release, as % of releases
