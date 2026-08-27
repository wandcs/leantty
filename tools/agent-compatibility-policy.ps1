function Get-LeanTTYAgentCompatibilityContract {
    return [pscustomobject][ordered]@{
        agents = @('codex', 'opencode', 'pi', 'qwen')
        modes = @('direct', 'tmux')
        requestCount = 8
        automaticRetries = 0
    }
}

function Get-LeanTTYAgentNotificationFailureDomain {
    param([AllowEmptyString()][string]$Failure)

    if ([string]::IsNullOrWhiteSpace($Failure)) { return 'none' }
    foreach ($domain in @(
            'product',
            'harness',
            'environment',
            'infrastructure',
            'external-agent',
            'compatibility',
            'privacy'
        )) {
        if ($Failure -match ('^\[' + [regex]::Escape($domain) + '\]')) {
            return $domain
        }
    }
    return 'unknown'
}

function Resolve-LeanTTYAgentNotificationAssessment {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('codex', 'opencode', 'pi', 'qwen')]
        [string]$Agent,
        [Parameter(Mandatory = $true)]
        [ValidateSet('direct', 'tmux')]
        [string]$Mode,
        [Parameter(Mandatory = $true)][bool]$NativeAttentionObserved,
        [Parameter(Mandatory = $true)][bool]$SystemNotificationCompleted,
        [Parameter(Mandatory = $true)][int]$AgentChildExitCode,
        [AllowEmptyString()][string]$NotificationFailure = ''
    )

    $applicability = if ($Agent -eq 'opencode' -and $Mode -eq 'tmux') {
        'upstream-emission-dependent'
    } elseif ($Agent -eq 'pi' -or ($Agent -eq 'qwen' -and $Mode -eq 'direct')) {
        'background-best-effort'
    } else {
        'required'
    }
    $failureDomain = Get-LeanTTYAgentNotificationFailureDomain -Failure $NotificationFailure
    $assessment = [ordered]@{
        applicability = $applicability
        status = 'failed'
        classification = 'unexpected-failure'
        nativeAttention = $(if ($NativeAttentionObserved) { 'observed' } else { 'not-observed' })
        systemNotification = $(if ($SystemNotificationCompleted) { 'passed' } else { 'not-observed' })
        agentChildExitCode = $AgentChildExitCode
        failure = $NotificationFailure
        failureDomain = $failureDomain
    }

    if ($SystemNotificationCompleted) {
        if (-not $NativeAttentionObserved) {
            $assessment.classification = 'inconsistent-evidence'
            $assessment.failure = '[harness] System notification completed without captured native attention'
            $assessment.failureDomain = 'harness'
            return [pscustomobject]$assessment
        }
        $assessment.status = 'passed'
        $assessment.classification = 'verified'
        $assessment.failure = ''
        $assessment.failureDomain = 'none'
        return [pscustomobject]$assessment
    }

    if ($applicability -eq 'upstream-emission-dependent' -and
        -not $NativeAttentionObserved -and
        $AgentChildExitCode -eq 0 -and
        $failureDomain -eq 'external-agent') {
        $assessment.status = 'passed'
        $assessment.classification = 'not-emitted-by-agent'
        $assessment.systemNotification = 'not-exercised'
        $assessment.failure = ''
        $assessment.failureDomain = 'none'
        return [pscustomobject]$assessment
    }

    $expectedBackgroundDeferral =
        $NotificationFailure -eq '[product] Agent emitted native attention but LeanTTY did not publish it'
    if ($applicability -eq 'background-best-effort' -and
        $NativeAttentionObserved -and
        $expectedBackgroundDeferral) {
        $assessment.status = 'passed'
        $assessment.classification = 'platform-deferred'
        $assessment.failure = ''
        $assessment.failureDomain = 'none'
        return [pscustomobject]$assessment
    }

    if (-not $NativeAttentionObserved -and $applicability -ne 'upstream-emission-dependent') {
        $assessment.classification = 'required-native-signal-missing'
        $assessment.failure = '[compatibility] Agent PTY capture did not contain native attention'
        $assessment.failureDomain = 'compatibility'
    }
    return [pscustomobject]$assessment
}
