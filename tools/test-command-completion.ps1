
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'device-regression.ps1')
function Assert($value, $message) { if (-not $value) { throw $message } }
& {
    $actualWait = (Get-Command Wait-LeanTTYKnownHostCommandCompletion).ScriptBlock
    function Wait-LeanTTYKnownHostCommandCompletion {
        param($Hdc,$Target,$ProcessId,$Command,$SubmissionLogs,$Observation)
        & $actualWait -Hdc $Hdc -Target $Target -ProcessId $ProcessId -Command $Command -SubmissionLogs $SubmissionLogs -Observation $Observation -TimeoutSeconds 1
    }
    function Reset-LeanTTYDeviceCommandInput {}
    function Clear-LeanTTYAppLogs {}
    function Invoke-LeanTTYDeviceText {}
    function Invoke-LeanTTYDeviceKey { $probe.enters++ }
    function Wait-LeanTTYAcceptanceIdleInputState { param($Expected) [pscustomobject]@{input=$Expected;exact=$true} }
    function Wait-LeanTTYAppLog { $probe.submission }
    function Get-LeanTTYAppLogs {
        $probe.reads++
        if ($mode -eq 'read-error') { throw '[infrastructure] injected log read failure' }
        if ($mode -eq 'delayed' -and $probe.reads -lt 3) { return '' }
        return $probe.completion
    }
    $command='ssh-keygen -R [192.0.2.1]:32123'
    $ack="ACCEPTANCE_COMMAND_OWNER pane=pane-a,generation=4 ACCEPTANCE_INPUT_SUBMIT sequence=9,kind=command,input=$command"
    $done='ACCEPTANCE_KNOWN_HOST_COMPLETE pane=pane-a,generation=4,sequence=9,result=completed'
    foreach ($mode in @('missing','immediate','delayed','wrong-pane','old-generation','cancelled','failed','read-error','ambiguous','legacy','conflicting','ordinary')) {
        $probe=@{enters=0;reads=0;submission=$ack;completion=$done}
        $expected='completed'; $expectedFailure=''
        switch ($mode) {
            'missing' { $probe.completion=''; $expected='missing'; $expectedFailure='unknown' }
            'immediate' { $probe.submission=$ack+"`n"+$done }
            'wrong-pane' { $probe.completion=$done.Replace('pane-a','pane-b'); $expected='missing'; $expectedFailure='unknown' }
            'old-generation' { $probe.completion=$done.Replace('generation=4','generation=3'); $expected='missing'; $expectedFailure='unknown' }
            'cancelled' { $probe.completion=$done.Replace('completed','cancelled'); $expected='cancelled'; $expectedFailure='unknown' }
            'failed' { $probe.completion=$done.Replace('completed','failed'); $expected='failed'; $expectedFailure='unknown' }
            'read-error' { $expected='observation-failed'; $expectedFailure='infrastructure' }
            'ambiguous' { $probe.submission=$ack+"`n"+$ack.Replace('pane-a','pane-b'); $expected='unknown-owner'; $expectedFailure='unknown' }
            'legacy' { $probe.submission=$ack.Substring($ack.IndexOf('ACCEPTANCE_INPUT_SUBMIT')); $expected='unknown-owner'; $expectedFailure='unknown' }
            'conflicting' { $probe.completion=$done+"`n"+$done.Replace('completed','failed'); $expected='conflicting'; $expectedFailure='unknown' }
        }
        $observations=[Collections.Generic.List[object]]::new(); $failure=''
        $inputCommand=if($mode -eq 'ordinary'){'help ssh'}else{$command}
        try { Submit-LeanTTYDeviceCommand -Hdc fixture -Target fixture -ProcessId 42 -Command $inputCommand -InputNodeProvider { @{id='fixture'} } -ObservationSink $observations | Out-Null }
        catch { $failure=$_.Exception.Message }
        Assert ($probe.enters -eq 1 -and $observations.Count -eq 1) "$mode resent Enter or lost observation"
        if($expectedFailure) {
            Assert ($failure.StartsWith("[$expectedFailure]")) "$mode failed incorrectly: $failure"
            Assert ($observations[0].result -ne 'passed') "$mode returned success without confirmed completion"
        } else { Assert (-not $failure -and $observations[0].result -eq 'passed') "$mode did not complete: $failure" }
        if($mode -eq 'ordinary') {
            Assert ($null -eq $observations[0].completion -and $probe.reads -eq 0) 'Barrier expanded to ordinary commands'
        } else { Assert ($observations[0].completion.status -eq $expected) "$mode lost completion classification" }
        if($mode -eq 'immediate'){Assert ($probe.reads -eq 0) 'Same-sample completion was lost and reread'}
        if($mode -eq 'delayed'){Assert ($probe.reads -eq 3) 'Delayed operation advanced early'}
    }
    foreach($caller in @(@{file='verify-mosh-pc.ps1';name='Submit-LocalCommand'},@{file='verify-ssh-auth-pc.ps1';name='Submit-FocusedDeviceCommand'})) {
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $caller.file),[ref]$null,[ref]$null)
        $owner=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $caller.name},$true)
        . ([scriptblock]::Create($owner.Extent.Text))
        $hdc='fixture';$Target='fixture';$targetId='fixture';$appPid='42';$currentStage='fixture';$FixturePort=32123
        function Focus-ActiveTerminalInput { @{id='fixture'} }
        function Focus-ActiveCommandInput { @{id='fixture'} }
        function Wait-LeanTTYDeviceKnownHostAbsent { $probe.absenceChecks++ }
        foreach($endpoint in @('127.0.0.1','192.0.2.1')) {
            $command='ssh-keygen -R [{0}]:32123' -f $endpoint
            $mode='missing';$probe=@{enters=0;reads=0;absenceChecks=0;submission=$ack.Replace('192.0.2.1',$endpoint);completion=''}
            $commandObservations=[Collections.Generic.List[object]]::new();$failure=''
            try { if($caller.name -eq 'Submit-LocalCommand'){Submit-LocalCommand -Command $command}else{Submit-FocusedDeviceCommand -Command $command -LayoutName fixture} } catch {$failure=$_.Exception.Message}
            Assert ($failure.StartsWith('[unknown]') -and $probe.enters -eq 1 -and $probe.absenceChecks -eq 0) "$($caller.name)/$endpoint advanced on ACK only: $failure; enters=$($probe.enters); absence=$($probe.absenceChecks)"
        }
    }
    Write-Host 'Command completion: 12 helper cases and 4 real-caller counterexamples passed.'
}
& {
    . (Join-Path $PSScriptRoot 'device-regression.ps1')
    $probe=@{reads=0;clears=0}
    function Get-LeanTTYAppLogs {
        $probe.reads++
        if($probe.reads -gt 1){throw '[infrastructure] injected read error'}
        'prefix ACCEPTANCE_IDLE_RESULT kind=1,input=secret敏感,completionActive=false,menuActive=false'
    }
    $observation=[ordered]@{phase='native-buffer'};$failure=''
    try { Wait-LeanTTYAcceptanceIdleInputState -Hdc fixture -Target fixture -ProcessId 42 -Expected 'secret-safe' -Observation $observation -TimeoutSeconds 1 | Out-Null } catch {$failure=$_.Exception.Message}
    $json=$observation | ConvertTo-Json -Depth 6
    Assert ($failure -match 'infrastructure' -and $observation.readStatus -eq 'failed') 'Read failure was hidden'
    Assert ($observation.parsed.exact -eq $false -and $observation.parsed.inputLength -eq 8) 'Actual parsed sample lost'
    Assert ($json -notmatch 'secret|敏感' -and $observation.records.nativeInput.nonAsciiCount -eq 2) 'Raw command leaked or mismatch category lost'
    $retained=$json
    function Clear-LeanTTYAppLogs {$probe.clears++}
    function Invoke-LeanTTYDeviceCtrlC {throw '[infrastructure] injected cleanup failure'}
    $cleanup=[ordered]@{phase='cleanup-reset';readStatus='not-observed'};$failure=''
    try{Reset-LeanTTYDeviceCommandInput -Hdc fixture -Target fixture -ProcessId 42 -Observation $cleanup}catch{$failure=$_.Exception.Message}
    Assert ($failure -match 'cleanup failure' -and $probe.clears -eq 1) 'Cleanup failure hidden'
    Assert (($observation | ConvertTo-Json -Depth 6) -ceq $retained) 'Cleanup replaced original decision evidence'
    Write-Host 'Failure evidence: actual sample, read error, redaction and cleanup preservation passed.'
}

& {
    . (Join-Path $PSScriptRoot 'device-regression.ps1')
    function Get-LeanTTYAppLogs { $sample }
    foreach($sample in @(
        'ACCEPTANCE_IDLE_RESULT input=public,completionActive=PUBLIC_REVIEW_SENTINEL,completionActive=false,menuActive=false',
        'ACCEPTANCE_IDLE_RESULT kind=1,input=secret,completionActive=false,moreSecret,completionActive=false,menuActive=false',
        "ACCEPTANCE_INPUT_SUBMIT sequence=1,kind=command,input=secret`nprivateBody",
        "ACCEPTANCE_IDLE_RESULT kind=1,input=secret ACCEPTANCE_KNOWN_HOST_COMPLETE pane=privateBody,generation=4,sequence=9,result=completed,completionActive=false,menuActive=false"
    )) {
        $observation=[ordered]@{}
        Get-LeanTTYObservedCommandLogs -Hdc fixture -Target fixture -ProcessId 42 -Observation $observation | Out-Null
        $json=$observation | ConvertTo-Json -Depth 8
        Assert ($json -notmatch 'secret|Secret|privateBody|PUBLIC_REVIEW_SENTINEL') 'Protocol-like command text leaked into retained evidence'
    }
    Write-Host 'Failure evidence: delimiter, newline and forged-marker privacy counterexamples passed.'
}
& {
    . (Join-Path $PSScriptRoot 'device-regression.ps1')
    $probe=@{reads=0}
    function Get-LeanTTYAppLogs {
        $probe.reads++
        if($probe.reads -eq 1){return 'ACCEPTANCE_IDLE_RESULT kind=1,input=partial,completionActive=false,menuActive=false'}
        return ''
    }
    $observation=[ordered]@{}
    $state=Wait-LeanTTYAcceptanceIdleInputState -Hdc fixture -Target fixture -ProcessId 42 -Expected complete -TimeoutSeconds 1 -Observation $observation
    Assert (-not $state.exact -and $state.input -ceq 'partial') 'Missing later samples falsely passed input'
    Assert ($observation.parsed.inputLength -eq 7 -and $observation.parsed.source -eq 'last-observed-state') 'Timeout decision lost its actual parsed input'
    Assert ($observation.lastNativeInput.inputLength -eq 7 -and $null -eq $observation.records.nativeInput) 'Last observed input was confused with final empty sample'
    Write-Host 'Failure evidence: timeout preserves the last state actually used for its decision.'
}
