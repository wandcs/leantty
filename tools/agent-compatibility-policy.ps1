function Get-LeanTTYAgentCompatibilityContract {
    return [pscustomobject][ordered]@{
        agents = @('codex', 'opencode', 'pi', 'qwen')
        modes = @('direct', 'tmux')
        requestCount = 8
        automaticRetries = 0
    }
}

function New-LeanTTYAgentCompatibilityResult {
    param(
        [Parameter(Mandatory = $true)][string]$Scenario,
        [Parameter(Mandatory = $true)][DateTimeOffset]$StartedAt,
        [Parameter(Mandatory = $true)][string]$AttemptId,
        [AllowEmptyString()][string]$PreviousAttemptId = '',
        [Parameter(Mandatory = $true)]
        [ValidateSet('acceptance', 'diagnostic', 'readiness')]
        [string]$RunMode,
        [Parameter(Mandatory = $true)][bool]$ReleaseEligible,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][object]$Candidate,
        [Parameter(Mandatory = $true)][object]$Harness,
        [Parameter(Mandatory = $true)][object]$Server,
        [AllowNull()][object]$Inventory = $null,
        [string[]]$SelectedAgents = @(),
        [string[]]$SelectedModes = @(),
        [ValidateRange(0, 100)][int]$PlannedModelRequests = 0,
        [string[]]$DiagnosticOverrides = @(),
        [object[]]$Checks = @(),
        [AllowNull()][object]$CommandAutomation = $null,
        [AllowNull()][object]$Cleanup = $null,
        [ValidateSet('invalid/interrupted', 'blocked', 'partial', 'failed', 'passed')]
        [string]$Status = 'invalid/interrupted'
    )

    if ($null -eq $Cleanup) {
        $Cleanup = [ordered]@{ result = 'pending'; detail = '' }
    }
    return [pscustomobject][ordered]@{
        schemaVersion = 2
        scenario = $Scenario
        startedAt = $StartedAt.ToString('o')
        attemptId = $AttemptId
        previousAttemptId = $PreviousAttemptId
        runMode = $RunMode
        releaseEligible = $ReleaseEligible
        target = $Target
        candidate = $Candidate
        harness = $Harness
        server = $Server
        inventory = $Inventory
        selectedAgents = @($SelectedAgents)
        selectedModes = @($SelectedModes)
        plannedModelRequests = $PlannedModelRequests
        diagnosticOverrides = @($DiagnosticOverrides)
        checks = @($Checks)
        commandAutomation = $CommandAutomation
        cleanup = $Cleanup
        status = $Status
    }
}

function Write-LeanTTYAgentCompatibilityResult {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Result
    )

    Write-LeanTTYAtomicJson -Path $Path -Value $Result -Depth 20
    $resolvedPath = [IO.Path]::GetFullPath($Path)
    try {
        $json = [IO.File]::ReadAllText($resolvedPath, [Text.Encoding]::UTF8)
        $persisted = $json | ConvertFrom-Json -Depth 20
    } catch {
        throw "Agent compatibility result could not be read back: $($_.Exception.Message)"
    }
    foreach ($requiredProperty in @(
            'schemaVersion', 'scenario', 'attemptId', 'runMode', 'releaseEligible',
            'candidate', 'harness', 'server', 'selectedAgents', 'selectedModes',
            'plannedModelRequests', 'checks', 'cleanup', 'status', 'completedAt'
        )) {
        if ($persisted.PSObject.Properties.Name -notcontains $requiredProperty) {
            throw "Agent compatibility result lost required property: $requiredProperty"
        }
    }
    if ([int]$persisted.schemaVersion -ne 2 -or
        [string]$persisted.scenario -cne [string]$Result.scenario -or
        [string]$persisted.attemptId -cne [string]$Result.attemptId -or
        [string]$persisted.status -cne [string]$Result.status -or
        [int]$persisted.plannedModelRequests -ne [int]$Result.plannedModelRequests -or
        @($persisted.checks).Count -ne @($Result.checks).Count) {
        throw 'Agent compatibility result changed across its atomic JSON round trip'
    }
    return [pscustomobject][ordered]@{
        path = $resolvedPath
        byteLength = [Text.Encoding]::UTF8.GetByteCount($json)
        sha256 = (Get-FileHash -LiteralPath $resolvedPath -Algorithm SHA256).Hash.ToLowerInvariant()
        checkCount = @($persisted.checks).Count
        plannedModelRequests = [int]$persisted.plannedModelRequests
        result = $persisted
    }
}

function New-LeanTTYAgentCompatibilityReadinessFixture {
    param([Parameter(Mandatory = $true)][DateTimeOffset]$StartedAt)

    $contract = Get-LeanTTYAgentCompatibilityContract
    $checks = [Collections.Generic.List[object]]::new()
    $observations = [Collections.Generic.List[object]]::new()
    foreach ($agent in $contract.agents) {
        foreach ($mode in $contract.modes) {
            $stage = "$agent-$mode"
            $checks.Add([pscustomobject][ordered]@{
                agent = $agent
                mode = $mode
                status = 'passed'
                authentication = 'ready'
                expectedAttention = $(switch ($agent) {
                    'opencode' { 'osc-99' }
                    'pi' { 'osc-777' }
                    'qwen' { 'bel' }
                    default { 'bel' }
                })
                plannedModelRequests = 1
                tokenUsage = 'unavailable'
                nativeNotification = $true
                genericNotificationPayload = $true
                returnApplied = $true
                notificationAssessment = [ordered]@{
                    applicability = 'required'
                    status = 'passed'
                    classification = 'verified'
                    nativeAttention = 'observed'
                    systemNotification = 'passed'
                    agentChildExitCode = 0
                    failure = ''
                    failureDomain = 'none'
                }
                unicodeInput = 'harmony-uitest-semantic-unicode-not-physical-ime-composition'
                largeInputCharacters = 4096
                shiftEnter = 'physical-key-injected-captured-at-pty'
                search = $true
                reconnect = $true
                tmuxResume = $(if ($mode -eq 'tmux') { $true } else { $null })
                captureSummary = "results/$stage-notification.json"
                failure = ''
                failureDomain = 'none'
                recovery = 'not-required'
            })
            foreach ($phase in @('connect', 'launch', 'return', 'disconnect', 'reconnect')) {
                $observations.Add([pscustomobject][ordered]@{
                    stage = "$stage-$phase"
                    inputMethod = 'harmony-uitest-targeted-inputText'
                    result = 'passed'
                    failureDomain = 'none'
                    inputAttempts = 1
                    inputMismatches = 0
                    expectedLength = 48
                    actualLength = 48
                    firstMismatchIndex = $null
                    enterCount = 1
                    durationMs = 1250
                    lastProvenBoundary = 'submission-acknowledged'
                    mismatches = @()
                })
            }
        }
    }
    $inventory = [ordered]@{
        schemaVersion = 1
        environment = [ordered]@{
            distribution = 'synthetic-readiness'
            term = 'xterm-256color'
            colorterm = 'truecolor'
            locale = 'C.UTF-8'
        }
        tools = [ordered]@{}
        authenticationReady = [ordered]@{}
        models = [ordered]@{}
        usageAccounting = [ordered]@{
            plannedModelRequestsPerAgentMode = 1
            tokenUsage = 'not-invoked-by-zero-model-readiness'
        }
        privacy = [ordered]@{
            credentialContentRead = $false
            environmentSecretValuesRead = $false
        }
    }
    foreach ($agent in $contract.agents) {
        $inventory.tools[$agent] = [ordered]@{
            installed = $true
            path = "/synthetic/bin/$agent"
            version = "$agent synthetic-readiness"
            versionExitCode = 0
        }
        $inventory.authenticationReady[$agent] = $true
        $inventory.models[$agent] = 'release-contract-default'
    }
    $result = New-LeanTTYAgentCompatibilityResult `
        -Scenario 'synthetic-native-agent-tui-compatibility-result' `
        -StartedAt $StartedAt `
        -AttemptId ('readiness-' + [Guid]::NewGuid().ToString('N')) `
        -RunMode readiness `
        -ReleaseEligible $false `
        -Target 'synthetic-no-device' `
        -Candidate ([ordered]@{
            hapPath = 'synthetic-release-package.hap'
            sha256 = ('a' * 64)
            role = 'synthetic-readiness-input'
            gitCommit = ('b' * 40)
            gitTree = ('c' * 40)
            gitDirty = $false
            verificationMode = 'readiness'
            retained = $false
            reusedAcrossHarnessOnlyChanges = $false
        }) `
        -Harness ([ordered]@{
            gitCommit = ('b' * 40)
            gitTree = ('c' * 40)
            gitDirty = $false
            differencePathsFromCandidate = @()
        }) `
        -Server ([ordered]@{
            environment = 'synthetic-default-wsl-isolated-openssh'
            port = 39999
            authentication = 'synthetic-no-credential'
            terminalLocale = 'C.UTF-8'
            user = 'synthetic-user'
            networkEnvironment = [ordered]@{
                proxyVariableNames = @('HTTPS_PROXY', 'NO_PROXY')
                secretValuesRecorded = $false
            }
        }) `
        -Inventory $inventory `
        -SelectedAgents $contract.agents `
        -SelectedModes $contract.modes `
        -PlannedModelRequests $contract.requestCount `
        -Checks @($checks) `
        -CommandAutomation ([ordered]@{
            local = [ordered]@{
                schemaVersion = 1
                businessVerdict = 'passed'
                businessPostcondition = 'agent-compatibility-selected-checks'
                harnessStability = 'stable'
                inputMethod = 'harmony-uitest-targeted-inputText'
                commandCount = $observations.Count
                inputAttemptCount = $observations.Count
                inputMismatchCount = 0
                enterCount = $observations.Count
                commands = @($observations)
            }
            connected = [ordered]@{
                contract = 'controlled-bash-readline-snapshot-before-single-enter'
                observations = @($observations)
            }
        }) `
        -Cleanup ([ordered]@{
            result = 'passed'
            detail = 'synthetic-readiness-created-no-device-or-fixture-resources'
        }) `
        -Status passed
    $result | Add-Member -NotePropertyName completedAt `
        -NotePropertyValue $StartedAt.AddSeconds(1).ToString('o')
    return $result
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
