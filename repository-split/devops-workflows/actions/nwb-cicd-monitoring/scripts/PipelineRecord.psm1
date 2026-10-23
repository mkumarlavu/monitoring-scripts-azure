Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'NwbRepository.ps1')
function Get-NwbOptional($Object,[string]$Name,$Default=$null) {
    if($null -ne $Object -and $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}
function ConvertTo-PipelineRecords {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Run,[AllowEmptyCollection()][object[]]$Jobs=@(),
        [Parameter(Mandatory)][string]$Service,[Parameter(Mandatory)][string]$Environment,
        $StageMappings=[pscustomobject]@{},[datetimeoffset]$ObservedAt=[datetimeoffset]::UtcNow)
    $repository=Get-NwbRepository -Repository ([string]$Run.repository.full_name)
    if($Run.status -ne 'completed' -or
        [string]$Run.id -notmatch '^[1-9][0-9]*$' -or [int]$Run.run_attempt -lt 1) { throw 'Invalid completed run for pipeline records.' }
    $expectedUrl='https://northwest.ghe.com/'+$repository+'/actions/runs/'+[string]$Run.id
    if($Run.html_url -cne $expectedUrl){throw 'Unexpected source run URL.'}
    $mapping=Get-NwbOptional $StageMappings ([string]$Run.workflow_id) @()
    $rules=@($mapping)
    $keys=@{}
    foreach($rule in $rules){
        if([string]::IsNullOrWhiteSpace($rule.JobName) -or [string]::IsNullOrWhiteSpace($rule.Stage)){throw 'Stage mapping requires exact JobName and Stage.'}
        $stepName=Get-NwbOptional $rule 'StepName' ''
        $key=ConvertTo-Json -InputObject @([string]$rule.JobName,[string]$stepName) -Compress
        if($keys.ContainsKey($key)){throw 'Duplicate stage mapping selector.'};$keys[$key]=$true
    }
    $jobIds=@{}
    foreach($job in $Jobs){
        $jobId=[string]$job.id
        if($jobId -notmatch '^[1-9][0-9]*$' -or $jobIds.ContainsKey($jobId)){throw 'Missing or duplicate job ID.'};$jobIds[$jobId]=$true
        if((Get-NwbOptional $job 'run_id' $Run.id) -ne $Run.id -or
            (Get-NwbOptional $job 'run_attempt' $Run.run_attempt) -ne $Run.run_attempt){throw 'Job belongs to a different run/attempt.'}
        $entities=@([pscustomobject]@{Type='Job';Number=0;Item=$job})
        $stepNumbers=@{}
        foreach($step in @(Get-NwbOptional $job 'steps' @())){
            $number=[int]$step.number
            if($number -lt 1 -or $stepNumbers.ContainsKey($number)){throw 'Missing or duplicate step number.'};$stepNumbers[$number]=$true
            $entities += [pscustomobject]@{Type='Step';Number=$number;Item=$step}
        }
        foreach($entity in $entities){
            $item=$entity.Item
            if($item.status -ne 'completed'){throw 'Incomplete job/step in a completed run; retry later.'}
            $jobRule=@($rules | Where-Object { $_.JobName -ceq $job.name -and -not (Get-NwbOptional $_ 'StepName' '') })
            $rule=$null;if($jobRule.Count){$rule=$jobRule[0]}
            if($entity.Type -eq 'Step'){
                $stepRule=@($rules | Where-Object { $_.JobName -ceq $job.name -and (Get-NwbOptional $_ 'StepName' '') -ceq $item.name })
                if($stepRule.Count){$rule=$stepRule[0]}
            }
            $start=$null;$end=$null;$duration=$null
            # A skipped step has no execution duration, even if GitHub supplies equal timestamps.
            if($item.conclusion -ne 'skipped' -and $item.started_at -and $item.completed_at){
                $first=[datetimeoffset]$item.started_at;$last=[datetimeoffset]$item.completed_at
                if($last -lt $first){throw 'Step/job completion precedes start.'}
                $start=$first.UtcDateTime.ToString('o');$end=$last.UtcDateTime.ToString('o')
                $duration=[int][math]::Floor(($last-$first).TotalSeconds)
            }
            $stage='unmapped';if($null -ne $rule){$stage=[string]$rule.Stage}
            $stepName='';if($entity.Type -eq 'Step'){$stepName=[string]$item.name}
            [pscustomobject][ordered]@{
                TimeGenerated=$ObservedAt.UtcDateTime.ToString('o');UpdatedAt=$ObservedAt.UtcDateTime.ToString('o')
                Repository=$repository;Service=$Service;Environment=$Environment
                WorkflowId=[string]$Run.workflow_id;WorkflowPath=[string]$Run.path;PipelineName=[string]$Run.name
                RunId=[string]$Run.id;RunAttempt=[int]$Run.run_attempt;JobId=$jobId
                RecordType=[string]$entity.Type;StepNumber=[int]$entity.Number
                JobName=[string]$job.name;StepName=$stepName;Stage=$stage;StageMappingKnown=($null -ne $rule)
                Status=[string]$item.status;Conclusion=[string]$item.conclusion
                StartedAt=$start;CompletedAt=$end;DurationSeconds=$duration
                RunnerName=[string](Get-NwbOptional $job 'runner_name' '')
                RunnerGroupName=[string](Get-NwbOptional $job 'runner_group_name' '')
                CommitSha=[string]$Run.head_sha;RunUrl=$expectedUrl
            }
        }
    }
}
Export-ModuleMember -Function ConvertTo-PipelineRecords
