# Dot-sourced by entry points so offline tests can replace HTTP and Azure CLI.
function Invoke-SafeRequest {
    param([string]$Uri, [hashtable]$Headers, [string]$Method = 'Get', [string]$Body)
    for ($try = 1; $try -le 4; $try++) {
        try {
            $request = @{Uri=$Uri;Headers=$Headers;Method=$Method;TimeoutSec=60;MaximumRedirection=0;ErrorAction='Stop'}
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
            throw "Request failed (HTTP $status, attempt $try). Check source access or DCR permissions/network."
        }
    }
}

function Get-NwbGitHubContext {
    if (-not $env:GITHUB_TOKEN) { throw 'GITHUB_TOKEN is required.' }
    if ($env:GITHUB_REPOSITORY -cne 'northwest/doc_extraction') { throw 'Unexpected repository; configured for northwest/doc_extraction.' }
    if (-not $env:GITHUB_API_URL -or $env:GITHUB_API_URL.TrimEnd('/') -ne 'https://api.northwest.ghe.com') { throw 'Unexpected GitHub API host.' }
    return @{
        Base = 'https://api.northwest.ghe.com/repos/northwest/doc_extraction'
        Headers = @{Authorization="Bearer $env:GITHUB_TOKEN";Accept='application/vnd.github+json';'X-GitHub-Api-Version'='2022-11-28'}
    }
}

function Get-NwbArrayPages {
    param([string]$Uri, [hashtable]$Headers)
    # Only constructed, approved GitHub URLs are passed here. Do not follow source URLs.
    $separator = '?'; if ($Uri.Contains('?')) { $separator = '&' }
    $items = @()
    for ($page=1; $page -le 100; $page++) {
        $batch = @(Invoke-SafeRequest -Uri "${Uri}${separator}per_page=100&page=$page" -Headers $Headers)
        $items += $batch
        if ($batch.Count -lt 100) { return ,$items }
    }
    throw 'GitHub pagination limit reached; collection is incomplete.'
}

function Send-NwbRecords {
    param([object[]]$Records, [string]$DcrId,
        [ValidateSet('NWBWorkflowRuns_CL','NWBDeploymentFacts_CL','NWBPipelineExecution_CL','NWBCollectorHealth_CL')][string]$Table)
    if ($Records.Count -eq 0) { return }
    if (-not $env:AZURE_DCE_LOGS_ENDPOINT) { throw 'Azure Logs ingestion endpoint is required.' }
    $endpoint = [uri]$env:AZURE_DCE_LOGS_ENDPOINT
    if (-not $endpoint.IsAbsoluteUri -or $endpoint.Scheme -ne 'https' -or
        -not $endpoint.Host.EndsWith('.ingest.monitor.azure.com') -or $endpoint.Port -ne 443 -or
        $endpoint.AbsolutePath -ne '/' -or $endpoint.Query -or $endpoint.Fragment -or $endpoint.UserInfo) {
        throw 'Use the exact Azure public-cloud DCE Logs ingestion endpoint, without a path or query.'
    }
    if ($DcrId -notmatch '^dcr-[0-9a-fA-F]{32}$') { throw 'Invalid DCR immutable ID.' }
    $token = & az account get-access-token --resource https://monitor.azure.com/ --query accessToken --output tsv --only-show-errors 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $token) { throw 'Azure login did not supply a Monitor access token.' }
    $uri = $endpoint.AbsoluteUri.TrimEnd('/') + '/dataCollectionRules/' + $DcrId + '/streams/Custom-' + $Table + '?api-version=2023-01-01'
    try {
        # Small batches keep requests below the ingestion API size limit.
        foreach ($record in $Records) {
            $body = ConvertTo-Json -InputObject @($record) -Depth 8 -Compress
            if ([System.Text.Encoding]::UTF8.GetByteCount($body) -gt 900000) { throw 'Record exceeds ingestion size budget.' }
            $null = Invoke-SafeRequest -Uri $uri -Headers @{Authorization="Bearer $token"} -Method Post -Body $body
        }
    } finally { $token = $null }
}
