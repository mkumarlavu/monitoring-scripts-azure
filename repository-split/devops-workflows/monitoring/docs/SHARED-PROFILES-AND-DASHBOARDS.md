# Shared stage profiles and dashboards

This update keeps the scripts in `northwest/devops-workflows`. Application repositories choose a profile instead of copying the same job mappings. The Azure Workbook stays in place. A second dashboard definition is available for **Azure Monitor > Dashboards with Grafana**, inside the Azure portal.

## 1. Update devops-workflows first

Copy these paths from the local `repository-split/devops-workflows/` folder to the same paths in the Northwest `devops-workflows` repository:

- `actions/nwb-cicd-monitoring/profiles/stages.json` (new shared catalog)
- `actions/nwb-cicd-monitoring/scripts/NwbStageProfiles.ps1` (new resolver)
- `actions/nwb-cicd-monitoring/scripts/Invoke-CicdCollection.ps1` (updated collector)
- `monitoring/tests/Test-StageProfiles.ps1` and `monitoring/tests/Test-PipelineExecution.ps1`
- `monitoring/grafana/` (all files; dashboard JSON, generator, checks and instructions)
- Updated reference files under `monitoring/config/`, `monitoring/docs/`, `monitoring/workbooks/README.md`, and `monitoring.md`.

The reusable workflow YAML and composite `action.yml` do not need changes for this update. Do not copy the `repository-split` parent folder into Northwest.

Run the checks from the `devops-workflows` root, then review and merge the central changes into `main`:

```powershell
./monitoring/tests/Test-StageProfiles.ps1
./monitoring/tests/Test-PipelineExecution.ps1
./monitoring/tests/Test-CicdCollection.ps1
./monitoring/tests/Test-MultiRepository.ps1
./monitoring/tests/Test-Package.ps1
./monitoring/workbooks/Test-CicdWorkbook.ps1
./monitoring/grafana/Test-CicdGrafana.ps1
```

Offline checks do not sign in to Azure, execute KQL, or validate portal rendering.

## 2. Update doc_extraction

After the central change is merged, edit **`doc_extraction/config/nwb-observability/collector.json`** in the VDI.

Add this property alongside the existing configuration:

```json
"StageProfiles": {
  ".github/workflows/delivery.yml": "nwb-delivery"
}
```

The local application example already contains this selection. Preserve the VDI's existing `DefaultService` spelling, workflow/environment mappings, flags and any unrelated stage overrides. Only the five identical delivery rules can be removed from `StageMappings`, because the central profile now supplies them. If there are no remaining overrides, use `"StageMappings": {}`. Do not replace the whole live configuration with an example if Northwest has added other settings.

Merge this configuration into the application's default branch. Keep both existing caller workflows. No new workflow file, runner, table, DCR, DCE, or identity is needed for these stage labels.

## 3. Verify before publishing

1. Open `doc_extraction > Actions > NWB CI/CD collector > Run workflow`.
2. Use source run `323897996`, attempt `1`, if it is still available. Otherwise choose a recent completed delivery run.
3. Leave **Publish to Azure** unchecked. Start the run.
4. Confirm the log says `Using shared stage profile 'nwb-delivery'`. Matching job/step records should show labels such as `Build` or `Validation`.
5. Check exact job names against the application run. A skipped build must still show `skipped`. Unlisted jobs must still show `unmapped`.
6. Run once with **Publish to Azure** checked. Verify the records in Log Analytics, then refresh the Workbook.

Replays append observations. The dashboard selects the newest observation for each run attempt and job/step within its selected collection window. This update does not rewrite old rows. Environment remains `unclassified` until its separate mapping is reviewed.

## How the profile works

The collector resolves the workflow path supplied by GitHub. `StageProfiles` selects a named profile from the catalog bundled with the central action. No numeric workflow ID is required. A change to a workflow's ID does not change its path mapping; a renamed workflow file needs its profile selection updated.

The `nwb-delivery` profile contains the five complete job names previously observed for the pilot. It is suitable for repositories that use that same pipeline structure. It does not guess stages from arbitrary job names and does not claim complete coverage of the pilot's jobs. Add reviewed common names centrally as the shared application pipelines settle.

Local `StageMappings` remain optional:

- A local rule replaces a profile rule with the same exact `JobName` and `StepName` selector.
- A job-only rule supplies the label for that job and its steps. A specific step rule takes priority over a job-only rule, regardless of where it was defined.
- Unrelated profile rules remain available. An empty local array does not disable the profile; remove the `StageProfiles` entry to opt out.
- Selectors are case sensitive. Duplicate selectors in either layer and unknown selected profile names fail the execution component with a clear error.
- Workflows without a selected profile keep the previous behavior: local mappings if present, otherwise raw records with `unmapped` stages.

For another repository using the same delivery pipeline, select the same profile under its actual workflow path. Keep the two caller workflows and the repository's service setting. Runner access, repository access, environment variables and federated credentials still need to be configured once for that repository; a shared profile does not grant Azure access.

## 4. Keep the Azure Workbook

The existing Workbook already reads the workflow, execution and health tables. Its JSON and queries have not changed in this update. After publishing a mapped run, refresh it and check **Stage outcomes** and **Job/Step stage coverage**. Do not recreate the Workbook or tables.

Workbook source and installation steps remain in [monitoring/workbooks](../workbooks/README.md).

## 5. Add the Azure Monitor Grafana view

Use the [Grafana import steps](../grafana/README.md). This is an additional view of the same data, not a replacement collector. Only the generated Grafana JSON goes into the Grafana importer. The Workbook JSON belongs in the Workbook editor.

For rollback, remove `StageProfiles` and restore the reviewed local rules first. Existing rows remain in Azure. A central profile edit on `main` affects subsequent collection in all repositories selecting that profile, so review changes and validate the pilot before rolling them out.
