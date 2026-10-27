function Get-NwbRepository {
    param([string]$Repository=$env:GITHUB_REPOSITORY)
    # Only validated caller repository names may be used to construct API URLs.
    # Repository access, runner access and Azure federation remain admin-controlled.
    if($Repository -cnotmatch '^northwest/[A-Za-z0-9_.-]+$' -or
        ($Repository -split '/')[1] -in @('.', '..')) {
        throw 'Unexpected repository; an approved northwest repository is required.'
    }
    return $Repository
}

function Get-NwbWorkflowMapping {
    param($Mappings, [Parameter(Mandatory)]$Run)
    if ($null -eq $Mappings) { return $null }
    # GitHub supplies both values. A file path remains usable when a workflow's
    # numeric ID changes. Exact path overrides take priority over legacy IDs.
    $path = ([string]$Run.path -split '@',2)[0]
    foreach ($key in @($path, [string]$Run.workflow_id)) {
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        foreach ($property in $Mappings.PSObject.Properties) {
            if ($property.Name -ceq $key) { return $property }
        }
    }
    return $null
}
