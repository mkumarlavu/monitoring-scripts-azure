[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('release','inventory')][string]$Operation,
    [Parameter(Mandatory)][string]$ConfigPath,
    [string]$EvidencePath,
    [switch]$Publish
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'NwbTransport.ps1')
Import-Module (Join-Path $PSScriptRoot 'ReleaseEvidence.psm1') -Force
$config=Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
Assert-ReleaseConfig $config
if($Publish -and @($config.Targets | Where-Object {$_.ResourceId -match 'REPLACE-|00000000-0000-0000-0000-000000000000'}).Count -gt 0) { throw 'Replace example resource IDs before publishing.' }
$repo=Get-NwbRepository
if($env:GITHUB_SERVER_URL -cne 'https://northwest.ghe.com' -or $env:GITHUB_RUN_ID -notmatch '^\d+$' -or $env:GITHUB_RUN_ATTEMPT -notmatch '^\d+$') { throw 'Run this publisher from a Northwest GitHub Actions job.' }
$context=[pscustomobject]@{Repository=$repo;RunId=$env:GITHUB_RUN_ID;RunAttempt=[int]$env:GITHUB_RUN_ATTEMPT;RunUrl="$env:GITHUB_SERVER_URL/$repo/actions/runs/$env:GITHUB_RUN_ID";Actor=$env:GITHUB_ACTOR;CommitSha=$env:GITHUB_SHA}
if($Operation -eq 'release') {
    if(-not $EvidencePath) {throw 'EvidencePath is required for a release report.'}
    $evidence=Get-Content -LiteralPath $EvidencePath -Raw | ConvertFrom-Json
    $record=ConvertTo-ReleaseRecord $evidence $config $context
    if($Publish -and $record.ResourceId -match 'REPLACE-|00000000-0000-0000-0000-000000000000') { throw 'Replace example resource IDs before publishing.' }
    if($Publish) {Send-NwbRecords -Records @($record) -DcrId $env:AZURE_RELEASE_DCR_IMMUTABLE_ID -Table NWBReleaseEvidence_CL; Write-Output 'Azure accepted release evidence. Verify ingestion in Logs.'}
    else {$record | ConvertTo-Json -Depth 10}
    return
}

# Read-only Azure metadata inspection. Requires Reader on each configured target.
if(@($config.Targets).Count -eq 0) { throw 'Inventory needs explicit read targets. Evidence discovery does not scan subscriptions or clusters.' }
$token=& az account get-access-token --resource https://management.azure.com/ --query accessToken --output tsv --only-show-errors 2>$null
if($LASTEXITCODE -ne 0 -or -not $token) {throw 'Azure login is required for the inventory read, including preview.'}
$failed=0
try {
    foreach($target in $config.Targets) {
        $revisions=@();$outcome='success'
        try {
            if($target.ResourceId -notmatch '/providers/Microsoft.App/containerApps/[^/]+$') { throw 'Version inventory currently supports Container Apps only.' }
            $resourcePath=$target.ResourceId.TrimEnd('/')+'/revisions'
            $next='https://management.azure.com'+$resourcePath+'?api-version=2025-01-01'
            $visited=[System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
            for($page=0;$next;$page++) {
                $uri=[uri]$next
                if($page -ge 100 -or -not $visited.Add($next) -or $uri.Scheme -ne 'https' -or $uri.Host -ne 'management.azure.com' -or $uri.Port -ne 443 -or $uri.UserInfo -or $uri.Fragment -or $uri.AbsolutePath -ine $resourcePath) {throw 'Invalid or incomplete Azure revision pagination.'}
                $response=Invoke-SafeRequest -Uri $next -Headers @{Authorization="Bearer $token"}
                if(-not $response.PSObject.Properties['value']) {throw 'Revision response has no value array.'}
                $revisions+=@($response.value)
                $next=$null
                if($response.PSObject.Properties['nextLink']) {$next=$response.nextLink}
            }
            $record=ConvertTo-VersionRecord $target $revisions $context
        } catch {
            # A failure supersedes the last good snapshot, rather than displaying stale state as current.
            $outcome='failure';$failed++
            Write-Warning "Inventory read failed for configured target $($target.Service)/$($target.Environment). Check Reader access, resource ID and network."
            $record=ConvertTo-VersionRecord $target @() $context -Outcome $outcome
        }
        if($Publish) {Send-NwbRecords -Records @($record) -DcrId $env:AZURE_RELEASE_DCR_IMMUTABLE_ID -Table NWBVersionInventory_CL}
        else {$record | ConvertTo-Json -Depth 10}
    }
} finally {$token=$null}
if($failed -gt 0) {throw "$failed inventory target(s) failed. No current-version claim was made for those targets."}
Write-Output 'Inventory read completed. Published snapshots are observations, not continuous runtime verification.'
