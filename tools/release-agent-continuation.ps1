# Named cross-harness continuations require a complete independent prefix.
# This is not a general skip-stage or cleanup override.
function Read-LeanTTYPinnedReleaseJson {
    param([Parameter(Mandatory = $true)]$Reference)
    if ([string]$Reference.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
        -not (Test-Path -LiteralPath ([string]$Reference.path) -PathType Leaf)) {
        throw 'Continuation evidence reference is missing or malformed'
    }
    $hash = (Get-FileHash -LiteralPath $Reference.path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -cne [string]$Reference.sha256) { throw 'Continuation evidence hash changed' }
    Get-Content -LiteralPath $Reference.path -Raw | ConvertFrom-Json -Depth 40
}

function Assert-LeanTTYAgentContinuationPaths {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Paths)
    Assert-LeanTTYHarnessOnlyPaths -ChangedPaths $Paths -AllowedPaths @(
        'tools/verify-agent-compatibility-pc.ps1',
        'tools/agent-compatibility-policy.ps1',
        'AGENTS.md',
        'tools/test-agent-ssh-gate.ps1', 'tools/test-agent-compatibility.ps1',
        'tools/test-agent-attention-gate.ps1',
        'tools/agent-compatibility/capture_notification.sh',
        'tools/agent-compatibility/start_gate.py',
        'tools/agent-compatibility/test_start_gate.py',
        'tools/agent-compatibility/observe_attention.py',
        'tools/agent-compatibility/attention_observer_probe.py',
        'tools/agent-compatibility/test_observe_attention.py',
        'tools/agent-compatibility/test_observe_attention_pty.py',
        'tools/verify-release-pc.ps1', 'tools/release-agent-continuation.ps1',
        'tools/test-release-agent-continuation.ps1', 'tools/test-build-workflows.ps1',
        'tools/test-release-phases.ps1',
        'tools/verify-ssh-auth-pc.ps1',
        'tools/verify-mosh-pc.ps1', 'tools/verify-terminal-search-pc.ps1',
        'tools/verify-long-task-notification-pc.ps1',
        'docs/next-work.md', 'docs/quality-strategy.md',
        'docs/design/agent-exit-boundary-20260912.md',
        'docs/design/agent-notification-order-20260912.md'
    )
}

function Get-LeanTTYClipboardIndependentSource {
    param([Parameter(Mandatory = $true)][string]$Source)
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($Source, [ref]$null, [ref]$errors)
    if ($errors.Count -ne 0) { throw 'SSH clipboard source did not parse' }
    $owners = @($ast.FindAll({ param($node)
        ($node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -in @('Submit-ConnectedInputUntilAuthEvent', 'Wait-AuthPasteReady', 'Wait-AuthOutputMarker', 'Invoke-LeanTTYPasteShortcut')) -or
        ($node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses.Count -eq 1 -and
            $node.Clauses[0].Item1.Extent.Text -in @("Test-AuthStageSelected -Name 'terminal-key-input'",
                "Test-AuthStageSelected -Name 'transport-main-path'", "Test-AuthStageSelected -Name 'ssh-escape'"))
    }, $true))
    if ($owners.Count -ne 5) { throw 'SSH native terminal repair owners are ambiguous' }
    foreach ($owner in @($owners | Sort-Object { $_.Extent.StartOffset } -Descending)) {
        $role = if ($owner -is [Management.Automation.Language.IfStatementAst]) { $owner.Clauses[0].Item1.Extent.Text }
            elseif ($owner.Name -eq 'Invoke-LeanTTYPasteShortcut') { 'paste-shortcut' } else { 'clipboard-readiness' }
        $Source = $Source.Remove($owner.Extent.StartOffset, $owner.Extent.Text.Length).Insert($owner.Extent.StartOffset, "<$role>")
    }
    return $Source
}

function Get-LeanTTYReleaseContinuation {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)]$Candidate,
        [Parameter(Mandatory = $true)]$Invocation,
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [switch]$Recheck
    )
    if ($Manifest.schemaVersion -ne 1 -or $Manifest.scope -cnotin @('agent-exit-boundary-R2', 'agent-split-R2', 'ssh-native-clipboard-R2')) {
        throw 'Unsupported release continuation contract'
    }
    $old = Read-LeanTTYPinnedReleaseJson $Manifest.sourceReport
    $ssh = $Manifest.scope -ceq 'ssh-native-clipboard-R2'
    $recovery = if (-not $ssh) { Read-LeanTTYPinnedReleaseJson $Manifest.recovery } else { $null }
    $admission = Read-LeanTTYPinnedReleaseJson $Manifest.admission
    $split = $Manifest.scope -cne 'agent-exit-boundary-R2'
    $definitions = @(Get-LeanTTYReleaseVerificationStages -SplitOperator:$split)
    $names = @($definitions.name)
    $failedName = if ($ssh) { 'ssh-physical-matrix' } else { 'agent-compatibility' }
    $failedIndex = [Array]::IndexOf($names, $failedName)
    if ($old.schemaVersion -ne 1 -or $old.gate -cne 'registered-release-verification' -or
        $old.result -cne 'failed' -or $null -ne $old.continuation -or
        ($old.stageOrder -join '|') -cne ($names -join '|') -or
        @($old.stages).Count -ne $names.Count -or $failedIndex -lt 2 -or
        (-not $split -and ($names[-2..-1] -join '|') -cne 'agent-compatibility|ssh-physical-matrix') -or
        ($split -and ($names[-2..-1] -join '|') -cne 'mosh-operator-lock-recovery|mosh-operator-lid-recovery')) {
        throw 'Continuation requires an original failed checkpoint in the registered order'
    }
    if ($old.stages[0].name -cne 'candidate' -or $old.stages[0].status -cnotin @('passed','reused')) {
        throw 'Original candidate checkpoint is incomplete'
    }
    foreach ($field in @('gitCommit', 'gitTree', 'sha256')) {
        if ([string]::IsNullOrWhiteSpace([string]$Candidate.$field) -or
            [string]$old.candidate.$field -cne [string]$Candidate.$field) {
            throw 'Continuation candidate identity changed'
        }
    }
    if ($old.candidate.gitDirty -isnot [bool] -or $old.candidate.gitDirty -or
        $old.harness.gitDirty -isnot [bool] -or $old.harness.gitDirty -or $Candidate.gitDirty) {
        throw 'Continuation requires clean candidate and original harness identities'
    }
    foreach ($field in @('target', 'candidateBasePath', 'fixturePort', 'longTaskPort',
        'agentPort', 'moshAlternateWifiSsidIdentity', 'distribution')) {
        if ([string]$old.invocation.$field -cne [string]$Invocation.$field) {
            throw "Continuation invocation changed: $field"
        }
    }
    $oldCommit = [string]$old.harness.gitCommit
    if ($oldCommit -cnotmatch '^[a-f0-9]{40}$') { throw 'Invalid original harness commit' }
    & git -C $RepoRoot merge-base --is-ancestor $oldCommit HEAD 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Original harness is not an ancestor of this harness' }
    $oldTree = (& git -C $RepoRoot rev-parse ($oldCommit + '^{tree}')).Trim()
    if ($LASTEXITCODE -ne 0 -or $oldTree -cne $old.harness.gitTree) { throw 'Original harness tree changed' }
    $paths = @(& git -C $RepoRoot diff --name-only $oldCommit HEAD)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect continuation change scope' }
    if ($ssh) {
        Assert-LeanTTYHarnessOnlyPaths -ChangedPaths $paths -AllowedPaths @(
            'tools/verify-ssh-auth-pc.ps1', 'tools/test-device-regression.ps1',
            'tools/verify-release-pc.ps1', 'tools/release-agent-continuation.ps1',
            'tools/test-release-agent-continuation.ps1', 'tools/test-release-phases.ps1',
            'docs/next-work.md', 'docs/quality-strategy.md'
        )
        if ($paths -contains 'tools/verify-ssh-auth-pc.ps1') {
            $before = (& git -C $RepoRoot show ($oldCommit + ':tools/verify-ssh-auth-pc.ps1')) -join "`n"
            if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect original SSH verifier' }
            $after = (Get-Content -LiteralPath (Join-Path $RepoRoot 'tools/verify-ssh-auth-pc.ps1')) -join "`n"
            if ((Get-LeanTTYClipboardIndependentSource $before) -cne (Get-LeanTTYClipboardIndependentSource $after)) {
                throw 'SSH verifier changed outside native terminal owners; prefix reuse is not qualified'
            }
        }
    } else { Assert-LeanTTYAgentContinuationPaths -Paths $paths }
    # These independent owners may gain only reviewed candidate-admission paths;
    # every byte outside that AST-owned array must retain the original behavior.
    foreach ($admissionOwner in @('tools/verify-ssh-auth-pc.ps1', 'tools/verify-mosh-pc.ps1',
            'tools/verify-terminal-search-pc.ps1', 'tools/verify-long-task-notification-pc.ps1')) {
        if ($ssh -or $paths -notcontains $admissionOwner) { continue }
        $oldAuth = (& git -C $RepoRoot show ($oldCommit + ':' + $admissionOwner)) -join "`n"
        if ($LASTEXITCODE -ne 0) { throw "Cannot inspect original admission owner: $admissionOwner" }
        $newAuth = (Get-Content -LiteralPath (Join-Path $RepoRoot $admissionOwner)) -join "`n"
        $normalized = @($oldAuth, $newAuth) | ForEach-Object {
            $tokens = $null; $errors = $null
            $ast = [Management.Automation.Language.Parser]::ParseInput($_, [ref]$tokens, [ref]$errors)
            $calls = @($ast.FindAll({ param($node)
                $node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -ceq 'Assert-LeanTTYCandidateHarnessCompatibility'
            }, $true))
            if ($errors.Count -ne 0 -or $calls.Count -ne 1) { throw 'Candidate compatibility owner is ambiguous' }
            $arrays = @($calls[0].CommandElements | Where-Object {
                $_ -is [Management.Automation.Language.ArrayExpressionAst]
            })
            if ($arrays.Count -ne 1) { throw 'Candidate compatibility allowlist is ambiguous' }
            $_.Remove($arrays[0].Extent.StartOffset, $arrays[0].Extent.Text.Length).Insert($arrays[0].Extent.StartOffset, '<allowlist>')
        }
        if ($normalized[0] -cne $normalized[1]) { throw "Independent stage behavior changed; R3 required: $admissionOwner" }
    }

    $failed = $old.stages[$failedIndex]
    if ($failed.name -cne $failedName -or $failed.status -cne 'failed') {
        throw 'Continuation requires the named failed stage'
    }
    for ($index = $failedIndex + 1; $index -lt $names.Count; $index++) {
        if ($old.stages[$index].name -cne $names[$index] -or
            $old.stages[$index].status -cne 'pending' -or $old.stages[$index].attemptCount -ne 0) {
            throw 'Continuation requires the complete remaining suffix never started'
        }
    }
    if ($ssh) {
        $matrix = Get-Content -LiteralPath $failed.resultPath -Raw | ConvertFrom-Json -Depth 20
        $group = Read-LeanTTYPinnedReleaseJson $Manifest.failedGroup
        $expectedGroup = [IO.Path]::GetFullPath((Join-Path (Split-Path $failed.resultPath -Parent) 'transport-performance/device-ssh-auth.json'))
        if ([IO.Path]::GetFullPath($Manifest.failedGroup.path) -ine $expectedGroup -or
            $matrix.schemaVersion -ne 2 -or $matrix.scenario -cne 'ssh-physical-matrix' -or
            $matrix.result -cne 'failed' -or @($matrix.completedGroups).Count -ne 0 -or
            ($matrix.fixedOrder -join '|') -cne 'transport-performance|authentication-methods|lifecycle-recovery|pane-focus-attention' -or
            $group.result -cne 'failed' -or $group.runMode -cne 'acceptance' -or
            $group.executionGroup -cne 'transport-performance' -or $group.candidate.retained -ne $true -or
            $group.harness.gitDirty -ne $false -or $group.attemptId -cnotmatch '^[a-f0-9]{32}$' -or
            $group.cleanup.result -cne 'passed') { throw 'SSH continuation requires the original first-group failure and successful cleanup' }
        if (($group.checks.name -join '|') -cne 'fixture-and-device-preflight|ssh-diagnostics' -or
            @($group.checks | Where-Object result -cne 'passed').Count -ne 0 -or
            $group.performanceMatrix.selected -isnot [bool] -or $group.performanceMatrix.selected -or
            $group.preferences.allowedMutation -cne 'none') { throw 'SSH failure occurred outside the pre-performance clipboard boundary' }
        $expectedFailure = 'Timed out waiting for LeanTTY device state: OSC 52 clipboard write success=true,length=17'
        foreach ($failure in @($failed.failure, $matrix.failure, $group.failure)) {
            if ($failure -cne $expectedFailure) { throw 'SSH failure is outside the qualified clipboard repair' }
        }
        foreach ($record in @($matrix, $group)) {
            foreach ($field in @('gitCommit', 'gitTree', 'sha256')) {
                if ($record.candidate.$field -cne $Candidate.$field) { throw 'SSH failed candidate identity changed' }
            }
            if ($record.harness.gitCommit -cne $old.harness.gitCommit -or
                $record.harness.gitTree -cne $old.harness.gitTree) { throw 'SSH failed harness identity changed' }
        }
        foreach ($field in @('independentKeyAbsenceAudit', 'independentEcdsaKeyAbsenceAudit',
                'knownHostRemovalCommandCompleted', 'reverseMappingAbsenceAudit', 'fixtureProcessAbsenceAudit')) {
            if ($group.cleanup.$field -isnot [bool] -or -not $group.cleanup.$field) { throw "SSH cleanup is unproved: $field" }
        }
        $failedAttemptId = $group.attemptId
        if ($admission.gate -cne 'ssh-continuation-state-audit' -or
            $admission.failedGroupSha256 -cne $Manifest.failedGroup.sha256 -or
            $admission.failedMatrixSha256 -cne (Get-FileHash -LiteralPath $failed.resultPath -Algorithm SHA256).Hash.ToLowerInvariant()) {
            throw 'SSH continuation admission identity changed'
        }
    } else {
        $agent = Get-LeanTTYReleaseEvidenceMetadata -Path $failed.resultPath -StageName $failed.name
        $agentHash = (Get-FileHash -LiteralPath $failed.resultPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($failed.attemptId) -or
            $agent.attemptId -cne $failed.attemptId -or $agent.outcome -ceq 'passed' -or
            $agent.evidence.candidate.sha256 -cne $Candidate.sha256 -or
            $agent.evidence.runMode -cne 'acceptance' -or
            $agent.evidence.harness.gitCommit -cne $old.harness.gitCommit -or
            $agent.evidence.harness.gitTree -cne $old.harness.gitTree -or
            $agent.evidence.harness.gitDirty -ne $false) {
            throw 'Failed Agent evidence identity changed'
        }
        if ($split -and $agent.evidence.cleanup.result -cne 'passed') {
            throw 'Split continuation requires successful owned Agent cleanup'
        }
        if ($recovery.result -cne 'passed' -or $recovery.attemptId -cne $failed.attemptId -or
            $recovery.originalReleaseReportSha256 -ine $Manifest.sourceReport.sha256 -or
            $recovery.originalAgentReportSha256 -ine $agentHash -or
            $recovery.knownHostEndpoint -cne $agent.evidence.resources.knownHostEndpoint) {
            throw 'Independent recovery does not identify this failed Agent attempt'
        }
        foreach ($value in @($recovery.originalReportsUnchanged, $recovery.knownHostAbsent,
            $agent.evidence.resources.tabCleanup.ownedTabRemoved,
            $agent.evidence.resources.tabCleanup.originalTabsRestored,
            $agent.evidence.resources.tabCleanup.originalActiveTabRestored,
            $agent.evidence.resources.notificationPermission.restored)) {
            if ($value -isnot [bool] -or -not $value) { throw 'Agent restoration is unproved' }
        }
        if ($admission.gate -cne 'agent-continuation-state-audit' -or
            $admission.result -cne 'passed' -or $admission.sourceReportSha256 -cne $Manifest.sourceReport.sha256 -or
            $admission.failedAgentSha256 -cne $agentHash) { throw 'Agent continuation admission identity changed' }
        $failedAttemptId = $failed.attemptId
    }
    if ($admission.result -cne 'passed' -or $admission.sourceReportSha256 -cne $Manifest.sourceReport.sha256 -or
        $admission.candidateSha256 -cne $Candidate.sha256 -or
        $admission.target -cne $Invocation.target) { throw 'Continuation admission identity changed' }
    foreach ($field in @('readOnly', 'knownHostsAbsent', 'fixtureProcessesAbsent',
        'fixtureDirectoriesAbsent', 'listenersAbsent', 'hdcMappingsEmpty',
        'workspaceRestored', 'notificationRestored', 'platformUnchanged', 'prefixIndependent')) {
        if ($admission.$field -isnot [bool] -or -not $admission.$field) {
            throw "Continuation initial state is unproved: $field"
        }
    }
    if (-not $Recheck) {
        $age = [DateTimeOffset]::UtcNow - [DateTimeOffset]::Parse($admission.observedAt)
        if ($age.TotalMinutes -lt 0 -or $age.TotalMinutes -gt 10) { throw 'Continuation admission audit is stale' }
    }
    $ownerScript = if ($ssh) { 'tools/verify-ssh-auth-pc.ps1' } else { 'tools/verify-agent-compatibility-pc.ps1' }
    $ownerHash = (Get-FileHash -LiteralPath (Join-Path $RepoRoot $ownerScript) -Algorithm SHA256).Hash.ToLowerInvariant()
    $admittedHash = if ($ssh) { $admission.sshScriptSha256 } else { $admission.agentScriptSha256 }
    if ($admittedHash -cne $ownerHash) { throw 'Stage repair changed after admission' }

    $prefix = @()
    for ($index = 1; $index -lt $failedIndex; $index++) {
        $stage = $old.stages[$index]
        if ($stage.name -cne $names[$index] -or $stage.script -cne $definitions[$index].script -or
            $stage.status -cne 'passed') { throw 'Continuation prefix is incomplete or reordered' }
        $summary = Get-LeanTTYReleaseEvidenceSummary -Path $stage.resultPath -StageName $stage.name
        if ($ssh -and $stage.name -ceq 'agent-compatibility' -and
            $summary.evidence.runMode -cne 'acceptance') { throw 'Inherited Agent evidence was not formal acceptance' }
        if ($definitions[$index].kind -ne 'harness' -and
            [string]$summary.evidence.candidate.sha256 -ine [string]$Candidate.sha256) {
            throw 'Prefix stage candidate hash changed'
        }
        if ($null -ne $summary.evidence.harness -and
            ($summary.evidence.harness.gitCommit -cne $old.harness.gitCommit -or
             $summary.evidence.harness.gitTree -cne $old.harness.gitTree -or
             $summary.evidence.harness.gitDirty -eq $true)) {
            throw 'Prefix stage harness identity changed'
        }
        if ($definitions[$index].kind -in @('harness', 'mosh-matrix')) {
            $e = $summary.evidence
            if ($e.harness.gitCommit -cne $old.harness.gitCommit -or $e.harness.gitTree -cne $old.harness.gitTree) {
                throw 'Original prefix harness identity changed'
            }
            $sha = if ($definitions[$index].kind -eq 'harness') { $e.reviewTestHap.sha256 } else { $e.candidate.sha256 }
            if ($sha -cne $Candidate.sha256) { throw 'Original prefix candidate changed' }
        }
        if ($definitions[$index].kind -eq 'harness') {
            if ($summary.evidence.releaseEligible -ne $true -or $summary.evidence.runMode -cne 'formal') {
                throw 'Original qualification was not formal'
            }
            continue # A repaired harness always runs a new qualification.
        }
        if ($summary.cleanup -cne 'passed') { throw 'Prefix stage cleanup is unproved' }
        $prefix += [pscustomobject]@{
            index = $index
            stage = $stage
            sha256 = (Get-FileHash -LiteralPath $stage.resultPath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    [pscustomobject]@{ manifest = $Manifest; prefix = $prefix; failedAttemptId = $failedAttemptId;
        failedIndex = $failedIndex; newPlannedModelRequests = $(if ($ssh) { 0 } else { 8 }) }
}

function Assert-LeanTTYInheritedReleaseStages {
    param([Parameter(Mandatory = $true)]$Report, [Parameter(Mandatory = $true)]$Validated)
    foreach ($inherited in $Validated.prefix) {
        $stage = $Report.stages[$inherited.index]
        if ($stage.status -cne 'reused' -or $stage.name -cne $inherited.stage.name -or
            $stage.resultPath -cne $inherited.stage.resultPath -or
            $stage.sourceEvidenceSha256 -cne $inherited.sha256 -or $stage.cleanup -cne 'passed') {
            throw 'Inherited stage checkpoint or evidence changed after continuation'
        }
    }
}
