Set-StrictMode -Version Latest

function Get-ReleaseField($Object, [string]$Name, $Default=$null) {
    if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}

function Get-ReleaseTargetType([string]$ResourceId) {
    if($ResourceId -cmatch '^k8s://[a-zA-Z0-9_.-]+/[a-z0-9.-]+/[a-zA-Z][a-zA-Z0-9]+/[a-z0-9.-]+$') { return 'Kubernetes workload' }
    if($ResourceId -notmatch '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[a-zA-Z0-9_.()-]+/providers/[a-zA-Z0-9.]+(/[a-zA-Z0-9_.()-]+/[a-zA-Z0-9_.()-]+)+$') { return 'unknown' }
    switch -Regex ($ResourceId) {
        '/providers/Microsoft.App/containerApps/[^/]+$' { return 'Container App' }
        '/providers/Microsoft.Compute/virtualMachines/[^/]+$' { return 'Virtual machine' }
        '/providers/Microsoft.Compute/virtualMachineScaleSets/[^/]+$' { return 'Virtual machine scale set' }
        '/providers/Microsoft.ContainerService/managedClusters/[^/]+$' { return 'AKS cluster' }
        default { return 'Other Azure resource' }
    }
}

function Get-ReleaseTarget($Config, [string]$Environment, [string]$ResourceId, $Evidence) {
    $knownTargets=@($Config.Targets | Where-Object { $_.ResourceId -ieq $ResourceId })
    $matches=@($knownTargets | Where-Object { $_.Environment -ceq $Environment })
    # Discovery must not bypass the reviewed policy for an already configured resource.
    if($knownTargets.Count -gt 0 -and $matches.Count -eq 0) {
        throw 'Release environment does not match the configured resource.'
    }
    if($matches.Count -eq 0 -and (Get-ReleaseField $Config 'AllowDiscoveredTargets' $false) -eq $true) {
        if([string]::IsNullOrWhiteSpace($Environment) -or $Environment -ceq 'unclassified') { throw 'Discovered release evidence needs its actual environment.' }
        if((Get-ReleaseTargetType $ResourceId) -eq 'unknown') { throw 'Discovered release evidence needs an Azure resource ID or k8s://cluster/namespace/kind/name identity.' }
        $service=[string](Get-ReleaseField $Evidence 'Service' (Get-ReleaseField $Config 'DefaultService' ''))
        if([string]::IsNullOrWhiteSpace($service)) { throw 'Discovered release evidence needs Service or DefaultService.' }
        return [pscustomobject]@{Environment=$Environment;ResourceId=$ResourceId;Service=$service;RequiredChecks=@(Get-ReleaseField $Config 'RequiredChecks' @())}
    }
    if($matches.Count -ne 1) { throw 'Release target must match exactly one configured environment and resource ID.' }
    return $matches[0]
}

function Assert-ReleaseConfig($Config) {
    $discovery=Get-ReleaseField $Config 'AllowDiscoveredTargets' $false
    if($discovery -isnot [bool]) { throw 'AllowDiscoveredTargets must be a boolean.' }
    if($Config.SchemaVersion -ne 1 -or (@($Config.Targets).Count -eq 0 -and -not $discovery)) { throw 'Release configuration needs SchemaVersion 1 and configured targets or enabled evidence discovery.' }
    $policies=@($Config.Targets)
    if($discovery) {
        # Reuse the same validation for the centrally agreed default check policy.
        $policies+= [pscustomobject]@{Environment='discovery-default';Service='discovery-default';ResourceId='k8s://policy/default/Deployment/default';RequiredChecks=@(Get-ReleaseField $Config 'RequiredChecks' @())}
    }
    $keys=[System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach($target in $policies) {
        if([string]::IsNullOrWhiteSpace($target.Environment) -or [string]::IsNullOrWhiteSpace($target.Service)) { throw 'Environment and Service are required.' }
        if((Get-ReleaseTargetType $target.ResourceId) -eq 'unknown') { throw 'Use a full Azure resource ID or k8s://cluster/namespace/kind/name identity.' }
        if(-not $keys.Add($target.ResourceId)) { throw 'A resource may occur only once in release configuration.' }
        $checkIds=[System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach($check in $target.RequiredChecks) {
            if([string]::IsNullOrWhiteSpace($check.Id) -or -not $checkIds.Add($check.Id)) { throw 'Required check IDs must be nonempty and unique per target.' }
            if($check.Kind -cnotin @('Smoke test','Post-deployment verification','Rollback verification','Quality gate','Security scan')) { throw 'Unsupported check kind.' }
            if(@($check.Operations).Count -eq 0) { throw 'Required checks need applicable Operations.' }
            foreach($operation in $check.Operations) { if($operation -cnotin @('deploy','rollback')) { throw 'Unsupported required-check operation.' } }
        }
    }
}

function ConvertTo-ReleaseRecord($Evidence, $Config, $Context, [datetime]$Now=[datetime]::UtcNow) {
    Assert-ReleaseConfig $Config
    $target=Get-ReleaseTarget $Config $Evidence.Environment $Evidence.ResourceId $Evidence
    if($Evidence.Operation -cnotin @('deploy','rollback') -or $Evidence.Result -cnotin @('success','failure','cancelled')) { throw 'Invalid release operation or result.' }
    if([string]::IsNullOrWhiteSpace($Evidence.ReleaseId)) { throw 'ReleaseId is required and must be stable across replays.' }
    if($Evidence.CompletedAt -is [datetime]) {
        if($Evidence.CompletedAt.Kind -eq [DateTimeKind]::Unspecified) { throw 'CompletedAt must include its UTC offset or Z.' }
        $completed=[datetimeoffset]$Evidence.CompletedAt
    } elseif($Evidence.CompletedAt -is [datetimeoffset]) {
        $completed=$Evidence.CompletedAt
    } else {
        if($Evidence.CompletedAt -notmatch '(Z|[+-]\d{2}:\d{2})$') { throw 'CompletedAt must include its UTC offset or Z.' }
        $completed=[datetimeoffset]::Parse($Evidence.CompletedAt)
    }
    if($completed.UtcDateTime -gt $Now.AddMinutes(5)) { throw 'Release completion cannot be in the future.' }
    $version=[string](Get-ReleaseField $Evidence 'TargetVersion' '')
    if($Evidence.Result -ceq 'success' -and [string]::IsNullOrWhiteSpace($version)) { throw 'A successful release needs TargetVersion (prefer an immutable image digest).' }
    if($Evidence.Operation -ceq 'rollback' -and [string]::IsNullOrWhiteSpace((Get-ReleaseField $Evidence 'RelatedDeploymentId' ''))) { throw 'Rollback needs the original deployment ID in RelatedDeploymentId.' }
    $reported=[System.Collections.Generic.Dictionary[string,object]]::new([System.StringComparer]::Ordinal)
    foreach($check in @(Get-ReleaseField $Evidence 'Checks' @())) {
        if($null -eq $check) { continue }
        if([string]::IsNullOrWhiteSpace($check.Id) -or $reported.ContainsKey($check.Id)) { throw 'Duplicate or empty reported check ID.' }
        if($check.Result -cnotin @('success','failure','timed_out','skipped','cancelled')) { throw 'Invalid check result.' }
        $reported.Add($check.Id,$check)
    }
    $checks=@(foreach($required in $target.RequiredChecks) {
        if($required.Operations -ccontains $Evidence.Operation) {
            $result='missing'
            if($reported.ContainsKey($required.Id)) { $result=$reported[$required.Id].Result }
            [pscustomobject]@{Id=$required.Id;Kind=$required.Kind;Result=$result}
        }
    })
    # Never derive a pass from absent/empty requirements or from workflow success.
    $verification='not_configured'
    if($checks.Count -gt 0) {
        $verification='passed'
        if(@($checks | Where-Object {$_.Result -cne 'success'}).Count -gt 0) { $verification='incomplete_or_failed' }
    }
    [pscustomobject][ordered]@{
        TimeGenerated=$Now.ToString('o'); UpdatedAt=$Now.ToString('o'); CompletedAt=$completed.UtcDateTime.ToString('o')
        Repository=$Context.Repository; Service=$target.Service; Environment=$target.Environment; ResourceId=$target.ResourceId
        TargetType=Get-ReleaseTargetType $target.ResourceId
        ReleaseId=[string]$Evidence.ReleaseId; RelatedDeploymentId=[string](Get-ReleaseField $Evidence 'RelatedDeploymentId' '')
        Operation=$Evidence.Operation; Result=$Evidence.Result; SourceVersion=[string](Get-ReleaseField $Evidence 'SourceVersion' '')
        TargetVersion=$version; RevisionName=[string](Get-ReleaseField $Evidence 'RevisionName' '')
        RunId=$Context.RunId; RunAttempt=$Context.RunAttempt; RunUrl=$Context.RunUrl; Actor=$Context.Actor; CommitSha=$Context.CommitSha
        RequiredChecks=$checks; RequiredCheckCount=$checks.Count; PassedCheckCount=@($checks | Where-Object {$_.Result -ceq 'success'}).Count
        Verification=$verification; EvidenceSource='pipeline-report'
    }
}

function ConvertTo-VersionRecord($Target, [object[]]$Revisions, $Context, [datetime]$Now=[datetime]::UtcNow, [string]$Outcome='success') {
    $rows=@(foreach($revision in $Revisions) {
        $p=$revision.properties
        if($null -eq $p.PSObject.Properties['active'] -or $p.active -isnot [bool]) { throw 'Revision response is missing a boolean active state.' }
        if($p.active -eq $true) {
            foreach($container in $p.template.containers) {
                # Whitelist only deployment metadata. Never send env vars or secret references.
                [pscustomobject]@{Revision=$revision.name;Container=$container.name;Image=$container.image;TrafficWeight=(Get-ReleaseField $p 'trafficWeight');HealthState=(Get-ReleaseField $p 'healthState' 'unknown');RunningState=(Get-ReleaseField $p 'runningState' 'unknown')}
            }
        }
    })
    [pscustomobject][ordered]@{
        TimeGenerated=$Now.ToString('o'); UpdatedAt=$Now.ToString('o'); Repository=$Context.Repository
        Service=$Target.Service; Environment=$Target.Environment; ResourceId=$Target.ResourceId
        Outcome=$Outcome; ActiveVersions=$rows; RunId=$Context.RunId; RunUrl=$Context.RunUrl
        EvidenceSource='azure-control-plane'; DetailCode=$(if($Outcome -eq 'success'){'complete-revision-snapshot'}else{'snapshot-read-failed'})
    }
}

Export-ModuleMember -Function Assert-ReleaseConfig,ConvertTo-ReleaseRecord,ConvertTo-VersionRecord
