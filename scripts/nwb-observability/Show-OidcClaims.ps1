# Show only the three trust settings; never print the JWT or request credential.
$ErrorActionPreference = 'Stop'
if (-not $env:ACTIONS_ID_TOKEN_REQUEST_URL -or -not $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN) {
    throw 'Run this inside GitHub Actions with id-token: write.'
}
$separator = if ($env:ACTIONS_ID_TOKEN_REQUEST_URL.Contains('?')) { '&' } else { '?' }
$url = $env:ACTIONS_ID_TOKEN_REQUEST_URL + $separator + 'audience=api%3A%2F%2FAzureADTokenExchange'
try {
    $response = Invoke-RestMethod -Uri $url -Headers @{Authorization="Bearer $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN"} -MaximumRedirection 0 -TimeoutSec 60
    $part = $response.value.Split('.')[1].Replace('-','+').Replace('_','/')
    $part = $part.PadRight($part.Length + ((4 - $part.Length % 4) % 4), '=')
    $claims = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part)) | ConvertFrom-Json
    [pscustomobject]@{issuer=$claims.iss; subject=$claims.sub; audience=$claims.aud} | ConvertTo-Json
} catch { throw 'Could not read OIDC trust claims. Check runner connectivity and GitHub OIDC permissions.' }
finally { $response=$null; $part=$null; $claims=$null }
