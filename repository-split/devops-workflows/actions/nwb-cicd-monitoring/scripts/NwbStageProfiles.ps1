Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'NwbRepository.ps1')

function Resolve-NwbStageMappings {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Run)

    $localMappings=$null
    if ($Config.PSObject.Properties['StageMappings']) { $localMappings=$Config.StageMappings }
    $selection=$null
    if ($Config.PSObject.Properties['StageProfiles']) {
        $selection=Get-NwbWorkflowMapping -Mappings $Config.StageProfiles -Run $Run
    }
    # Existing callers need no migration until they choose a shared profile.
    if ($null -eq $selection) {
        if ($null -eq $localMappings) { return [pscustomobject]@{} }
        return $localMappings
    }

    $profileName=$selection.Value
    if ($profileName -isnot [string] -or $profileName -cnotmatch '^[a-z][a-z0-9-]*$') {
        throw 'StageProfiles values must be a shared profile name, for example nwb-delivery.'
    }
    # Read only the catalog bundled with the action. Caller input is never a file path.
    $catalog=Get-Content -LiteralPath (Join-Path $PSScriptRoot '../profiles/stages.json') -Raw | ConvertFrom-Json
    if ($catalog.SchemaVersion -ne 1) { throw 'Unsupported shared stage profile schema.' }
    $profile=@($catalog.Profiles.PSObject.Properties | Where-Object Name -CEQ $profileName)
    if ($profile.Count -ne 1) { throw "Unknown shared stage profile: $profileName. Release the central profile before selecting it in a caller." }

    $local=Get-NwbWorkflowMapping -Mappings $localMappings -Run $Run
    $layers=@([pscustomobject]@{Rules=$profile[0].Value.Rules})
    if ($null -ne $local) { $layers+= [pscustomobject]@{Rules=$local.Value} }
    $merged=[System.Collections.Generic.Dictionary[string,object]]::new([System.StringComparer]::Ordinal)
    foreach ($layer in $layers) {
        if ($layer.Rules -isnot [array]) { throw 'Stage profile and override rules must be JSON arrays.' }
        $seen=[System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($rule in $layer.Rules) {
            if ($null -eq $rule -or -not $rule.PSObject.Properties['JobName'] -or
                -not $rule.PSObject.Properties['Stage'] -or
                $rule.JobName -isnot [string] -or $rule.Stage -isnot [string] -or
                [string]::IsNullOrWhiteSpace($rule.JobName) -or [string]::IsNullOrWhiteSpace($rule.Stage)) {
                throw 'Stage mapping requires exact JobName and Stage strings.'
            }
            $step=''
            if ($rule.PSObject.Properties['StepName']) {
                if ($rule.StepName -isnot [string]) { throw 'StepName must be a string.' }
                $step=$rule.StepName
            }
            $key=ConvertTo-Json -InputObject @($rule.JobName,$step) -Compress
            if (-not $seen.Add($key)) { throw 'Duplicate stage mapping selector within a profile or local override.' }
            # A local rule replaces the same exact job/step selector, not unrelated rules.
            $merged[$key]=$rule
        }
    }
    $path=([string]$Run.path -split '@',2)[0]
    $resolved=[pscustomobject]@{}
    $resolved | Add-Member -MemberType NoteProperty -Name $path -Value @($merged.Values)
    Write-Information "Using shared stage profile '$profileName' for '$path'." -InformationAction Continue
    return $resolved
}
