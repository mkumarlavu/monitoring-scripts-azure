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
