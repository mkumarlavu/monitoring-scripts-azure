function New-NwbHealthRecord {
    param([ValidateSet('collection','heartbeat','collector-run')][string]$Operation,
        [ValidateSet('success','failure')][string]$Outcome,[string]$SourceRunId='',
        [int]$SourceRunAttempt=0,[string]$DetailCode='',[datetimeoffset]$SourceUpdatedAt=[datetimeoffset]::UtcNow)
    $observed=[datetimeoffset]::UtcNow
    $monitorRun=[string]$env:GITHUB_RUN_ID;$monitorAttempt=[string]$env:GITHUB_RUN_ATTEMPT
    if(-not $monitorRun){$monitorRun='local'};if(-not $monitorAttempt){$monitorAttempt='0'}
    [pscustomobject][ordered]@{
        TimeGenerated=$observed.UtcDateTime.ToString('o');UpdatedAt=$observed.UtcDateTime.ToString('o')
        Repository='northwest/doc_extraction';Collector='nwb-cicd';Operation=$Operation;Outcome=$Outcome
        CheckId=($Operation+':'+$monitorRun+':'+$monitorAttempt+':'+$SourceRunId+':'+$SourceRunAttempt)
        SourceRunId=$SourceRunId;SourceRunAttempt=$SourceRunAttempt
        SourceUpdatedAt=$SourceUpdatedAt.UtcDateTime.ToString('o')
        CollectorRunId=$monitorRun;DetailCode=$DetailCode
    }
}
