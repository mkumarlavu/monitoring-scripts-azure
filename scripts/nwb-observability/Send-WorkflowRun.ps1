[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[1-9][0-9]*$')][string]$RunId,
    [ValidateRange(0,2147483647)][int]$RunAttempt = 0,
    [Parameter(Mandatory)][string]$Service,
    [Parameter(Mandatory)][string]$Environment,
    [bool]$IsDeploymentPipeline = $false,
    [switch]$Publish
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'WorkflowRecord.psm1') -Force

function Invoke-SafeRequest {
    param([string]$Uri, [hashtable]$Headers, [string]$Method = 'Get', [string]$Body)
    for ($try = 1; $try -le 4; $try++) {
        try {
            $request = @{ Uri=$Uri; Headers=$Headers; Method=$Method; TimeoutSec=60; MaximumRedirection=0; ErrorAction='Stop' }
            if ($Method -eq 'Post') {
                $request.Body = [System.Text.Encoding]::UTF8.GetBytes($Body)
                $request.ContentType = 'application/json; charset=utf-8'
            }
            return Invoke-RestMethod @request
        } catch {
            $status = 0
            if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
            if (($status -eq 429 -or $status -ge 500) -and $try -lt 4) {
                Start-Sleep -Seconds ([math]::Pow(2,$try))
                continue
            }
            # Do not dump headers, credentials or response bodies to workflow logs.
            throw "Request failed (HTTP $status, attempt $try). Check source access or DCR permissions/network."
        }
    }
}

if (-not $env:GITHUB_TOKEN) { throw 'GITHUB_TOKEN is required.' }
if ($env:GITHUB_REPOSITORY -cne 'northwest/doc_extraction') { throw 'This starter is configured only for northwest/doc_extraction.' }
if ($env:GITHUB_API_URL.TrimEnd('/') -ne 'https://api.northwest.ghe.com') { throw 'Unexpected GitHub API host.' }
$api = $env:GITHUB_API_URL.TrimEnd('/')
$repository = $env:GITHUB_REPOSITORY
$headers = @{ Authorization="Bearer $env:GITHUB_TOKEN"; Accept='application/vnd.github+json'; 'X-GitHub-Api-Version'='2022-11-28' }
$runBase = "$api/repos/$repository/actions/runs/$RunId"
if ($RunAttempt -eq 0) {
    $latest = Invoke-SafeRequest -Uri $runBase -Headers $headers
    $RunAttempt = [int]$latest.run_attempt
}
$run = Invoke-SafeRequest -Uri "$runBase/attempts/$RunAttempt" -Headers $headers
if ([string]$run.id -ne $RunId -or [int]$run.run_attempt -ne $RunAttempt) { throw 'Run response does not match the requested attempt.' }
$jobs = @(); $expectedCount = $null
for ($page = 1; $page -le 100; $page++) {
    $result = Invoke-SafeRequest -Uri "$runBase/attempts/$RunAttempt/jobs?per_page=100&page=$page" -Headers $headers
    if ($null -eq $expectedCount) { $expectedCount = [int]$result.total_count }
    if ([int]$result.total_count -ne $expectedCount) { throw 'Job list changed while reading. Retry the completed attempt.' }
    $jobs += @($result.jobs)
    if ($jobs.Count -eq $expectedCount) { break }
    if (@($result.jobs).Count -eq 0 -or $jobs.Count -gt $expectedCount) { throw 'Incomplete or inconsistent job pagination.' }
}
if ($jobs.Count -ne $expectedCount) { throw 'Job pagination limit reached; no record published.' }
$record = ConvertTo-WorkflowRecord -Run $run -Jobs $jobs -Repository $repository -Service $Service -Environment $Environment -IsDeploymentPipeline $IsDeploymentPipeline
$body = ConvertTo-Json -InputObject @($record) -Depth 8 -Compress
if (-not $Publish) {
    Write-Output 'Preview only. No Azure records sent. Review job-window timing and environment mapping.'
    Write-Output $body
    return
}
if (-not $env:AZURE_DCE_LOGS_ENDPOINT -or -not $env:AZURE_WORKFLOW_DCR_IMMUTABLE_ID) { throw 'Azure endpoint and workflow DCR immutable ID are required.' }
$endpoint = [uri]$env:AZURE_DCE_LOGS_ENDPOINT
if (-not $endpoint.IsAbsoluteUri -or $endpoint.Scheme -ne 'https' -or
    -not $endpoint.Host.EndsWith('.ingest.monitor.azure.com') -or $endpoint.Port -ne 443 -or
    $endpoint.AbsolutePath -ne '/' -or $endpoint.Query -or $endpoint.Fragment -or $endpoint.UserInfo) {
    throw 'Use the exact Azure public-cloud DCE Logs ingestion endpoint, without a path or query.'
}
if ($env:AZURE_WORKFLOW_DCR_IMMUTABLE_ID -notmatch '^dcr-[0-9a-fA-F]{32}$') { throw 'Invalid workflow DCR immutable ID.' }
$token = & az account get-access-token --resource https://monitor.azure.com/ --query accessToken --output tsv --only-show-errors 2>$null
if ($LASTEXITCODE -ne 0 -or -not $token) { throw 'Azure login did not supply a Monitor access token.' }
$ingestionUri = $endpoint.AbsoluteUri.TrimEnd('/') + '/dataCollectionRules/' + $env:AZURE_WORKFLOW_DCR_IMMUTABLE_ID + '/streams/Custom-NWBWorkflowRuns_CL?api-version=2023-01-01'
try {
    $null = Invoke-SafeRequest -Uri $ingestionUri -Headers @{Authorization="Bearer $token"} -Method Post -Body $body
} finally { $token = $null }
Write-Output "Azure accepted workflow run $RunId attempt $RunAttempt. Verify it in Log Analytics; retries may append duplicate observations."
