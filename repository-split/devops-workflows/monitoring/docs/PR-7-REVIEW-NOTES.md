# PR 7 review fixes and merge steps

These notes cover the findings shown in the review screenshots. The local shared package has been updated; the Northwest PR has not been changed from this workspace.

## What changed

| Review finding | Action |
| --- | --- |
| REST JSON arrays can stop pagination early | Fixed in `NwbTransport.ps1`. Assign the response first, then normalize its records before counting and appending. A regression test uses a non-enumerated 100-record response followed by another page. |
| Stage selectors compare differently when checking duplicates | Fixed in `PipelineRecord.psm1`. An ordinal dictionary now distinguishes `Build` from `build`, matching the existing case-sensitive selectors. Exact duplicates still fail. |
| Workflow alert ignores failures with no job timestamps | Added `SourceUpdatedAt` to workflow records, taken from the GitHub attempt's `updated_at`. The alert uses it for recency and leaves job execution timing nullable. Add the Azure column/stream field before publishing this version. |
| Checkout uses a movable tag | Kept `actions/checkout@v4` at the user's request. This is not a fix for the pinning finding; maintainer policy agreement is still needed. |
| Azure Login uses a movable tag | Kept `azure/login@v2` in both reusable workflows at the user's request. This is not a fix for the pinning finding; maintainer policy agreement is still needed. |
| Shared monitoring action uses main | Kept deliberately. The agreed design uses central main as the source of truth for future runs. This finding needs an explicit architecture/policy discussion with the reviewer, rather than claiming the reference is immutable. |

The selected version tags replace the full commit references previously suggested by Copilot. The private repository's full README and enforcement settings have not been inspected from this workspace. Confirm its action-reference policy with the owner. Do not report all review findings as fixed while the three pinning recommendations remain a deliberate design difference.

Suggested reply for the action-reference threads:

> We want devops-workflows/main to remain the shared source of truth, with checkout@v4 and azure/login@v2 for external actions. This intentionally uses movable references and does not implement the SHA-pinning recommendation. The collection bugs have been fixed separately. Please confirm whether these reference choices are allowed under the repository policy before we resolve the pinning threads.

## What is still required for a clean PR

1. Copy the local fixes to the Northwest branch and run the offline checks there.
2. Complete the workflow table/DCR schema addition below before publishing the new records.
3. Have the maintainer decide the three action-pinning findings. Version tags cannot simultaneously satisfy a requirement for immutable commit references. Do not disable signing checks or suppress review rules just to remove the warnings.
4. Correct the existing unsigned/unverified PR commits through the approved signing process.
5. Request a fresh Copilot review on the latest commit and address any additional findings. The screenshots alone do not establish the latest remote review status.
6. Resolve functional threads only after their corresponding fixes are present in the PR and verified. Record any accepted policy exception in the relevant thread.

## Azure schema update required before publication

The existing workflow stream does not yet declare the new field. This is a schema change, even though no new table or DCR is needed. Do it before merging/enabling the new publisher, because central main updates reach active callers.

1. Keep automatic collection/publication off during the pilot update, and do not run a manual publish until the schema is ready. For active repositories, deploy the additive schema change before merging the code.
2. Open Azure Portal > Log Analytics workspaces > `prd-cicdobservability-law-eus2` > Tables > `NWBWorkflowRuns_CL` > Manage schema.
3. Add `SourceUpdatedAt` with type `datetime` and save. Preserve all existing columns and retention settings. If Manage schema is unavailable, ask the Azure administrator to update the existing table schema through the table resource API or its deployment template.
4. Open Data Collection Rules > `prd-cicdobservability-workflows-dcr-eus2`. Export the current resource template or retrieve its current definition using the bank's normal IaC/API workflow. JSON View alone is a viewer.
5. Add the following entry to `properties.streamDeclarations["Custom-NWBWorkflowRuns_CL"].columns`, keeping every existing entry:

```json
{ "name": "SourceUpdatedAt", "type": "datetime" }
```

6. Check the data flow for this stream. `source` or an existing `source | extend ...` normally retains the field. If the transformation uses `project` or another explicit output list, add `SourceUpdatedAt` to that list as a datetime. Do not replace the other transformations without reviewing them.
7. Update that existing DCR in place through the approved resource deployment/API process. Keep its name, endpoint, destinations and other streams. Do not delete/recreate it, and do not deploy a DCR containing only the new column. If working from an exported resource template, review the deployment so only the intended resource changes.
8. Reopen the table schema and DCR JSON to verify the new field. Confirm the existing immutable ID and role assignments remain intact.
9. Publish a recent completed test run. Query `SourceUpdatedAt`, `CompletedAt`, `UpdatedAt`, `RunId` and `RunAttempt` in `NWBWorkflowRuns_CL`. Compare `SourceUpdatedAt` with the source attempt's GitHub `updated_at`.
10. Validate an allowlisted recent failed run with no jobs or incomplete job timestamps: it should retain `SourceUpdatedAt` even though `CompletedAt` remains null. Also replay an old failure: observation time changes, but source recency must remain old.

`SourceUpdatedAt` is GitHub's last-update time for the retrieved attempt, not a guaranteed exact completion time. Missing source timestamps remain null. Older stored rows will have null in the new column and cannot support this alert until appropriate records are recollected; replay does not make an old failure recent. Do not substitute collection time to fill that gap.

The generated `monitoring/infra/alerts-disabled.json` now contains the updated source query. It remains disabled and was not deployed. Existing deployed rules will not update until their template/query is applied. The execution/health DCR and its schema are unchanged.

## Files to copy into the existing Northwest PR

Use paths relative to the local `repository-split/devops-workflows` folder:

```text
.github/workflows/nwb-cicd-collector-reusable.yml
.github/workflows/nwb-collector-health-reusable.yml
actions/nwb-cicd-monitoring/scripts/NwbTransport.ps1
actions/nwb-cicd-monitoring/scripts/PipelineRecord.psm1
actions/nwb-cicd-monitoring/scripts/WorkflowRecord.psm1
monitoring/queries/alert-selected-workflows.kql
monitoring/infra/alerts-disabled.json
monitoring/tests/Test-Package.ps1
monitoring/tests/Test-ReviewFixes.ps1
monitoring/docs/PR-7-REVIEW-NOTES.md
monitoring/docs/README.txt
monitoring/docs/MOVE-KEEP-CHANGE.txt
monitoring.md
```

The caller YAML files in `doc_extraction` do not need new references for these changes; they still use the central workflows at main. Copy any earlier local documentation updates not yet present in the PR as well.

Run all six test scripts under `monitoring/tests` in separate PowerShell processes. They use offline API doubles. Live PowerShell 7, GitHub, KQL and Azure schema/ingestion checks are still required.

## The current merge blocker: verified commit signatures

The screenshot shows an approving review and the separate message **Commits must have verified signatures**. Fixing the code or resolving review threads does not satisfy this branch requirement.

1. Open the PR's **Commits** tab and inspect each commit's verification status.
2. Ask the repository administrator to confirm the bank-approved signing method (GPG, SSH or S/MIME) and help configure it on the machine used to push.
3. Register the approved public signing key with the appropriate Northwest GitHub account and verify the commit identity/email as required by the chosen method.
4. Sign future changes. Existing unsigned commits also need to be recreated or re-signed using the team's approved process. Adding one signed follow-up commit does not sign earlier commits, and `Signed-off-by` is not a cryptographic signature.
5. If re-signing rewrites branch history, coordinate it with the branch owner and anyone sharing the branch. Do not rewrite main. This workspace has not rewritten or pushed any branch.
6. Confirm **Verified** on the PR commits, request another review of the fixes if needed, and let GitHub reevaluate the merge requirements.

Message to the administrator:

> Hi Mike, PR 7 has an approval, but GitHub is blocking the merge with “Commits must have verified signatures.” Can you please help me set up the approved commit-signing method and correct the existing commits on feature/cicdmonitoring? I will also push the collection fixes from the review. We need to satisfy the signing rule before merging.

References: [GitHub signed-commit requirements](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches), [signature verification](https://docs.github.com/en/authentication/managing-commit-signature-verification/about-commit-signature-verification), [checkout action](https://github.com/actions/checkout), [Azure Login action](https://github.com/Azure/login).
