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




$expectedRemoteHead = git rev-parse origin/feature/cicdmonitoring
$backupBranch = "backup/cicdmonitoring-before-signing-" + (Get-Date -Format "yyyyMMdd-HHmmss")

git branch $backupBranch

$signingBase = git merge-base origin/main HEAD

git log --oneline "$signingBase..HEAD"
git rev-list --merges "$signingBase..HEAD"




git rebase --force-rebase --gpg-sign $signingBase

git rebase --abort


git diff --exit-code $backupBranch HEAD
$LASTEXITCODE
git status



git push "--force-with-lease=refs/heads/feature/cicdmonitoring:$expectedRemoteHead" origin HEAD:refs/heads/feature/cicdmonitoring


