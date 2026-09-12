# The only cross-harness continuation is an Agent-local repair after a complete
# independent prefix. This is not a general skip-stage or cleanup override.
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
        'tools/verify-ssh-auth-pc.ps1',
        'docs/next-work.md', 'docs/quality-strategy.md',
        'docs/design/agent-exit-boundary-20260912.md'
    )
}

function Get-LeanTTYAgentReleaseContinuation {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)]$Candidate,
        [Parameter(Mandatory = $true)]$Invocation,
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [switch]$Recheck
    )
    if ($Manifest.schemaVersion -ne 1 -or $Manifest.scope -cne 'agent-exit-boundary-R2') {
        throw 'Unsupported release continuation contract'
    }
    $old = Read-LeanTTYPinnedReleaseJson $Manifest.sourceReport
    $recovery = Read-LeanTTYPinnedReleaseJson $Manifest.recovery
    $admission = Read-LeanTTYPinnedReleaseJson $Manifest.admission
    $definitions = @(Get-LeanTTYReleaseVerificationStages)
    $names = @($definitions.name)
    if ($old.schemaVersion -ne 1 -or $old.gate -cne 'registered-release-verification' -or
        $old.result -cne 'failed' -or $null -ne $old.continuation -or
        ($old.stageOrder -join '|') -cne ($names -join '|') -or
        @($old.stages).Count -ne $names.Count -or
        ($names[-2..-1] -join '|') -cne 'agent-compatibility|ssh-physical-matrix') {
        throw 'Continuation requires an original failed Agent checkpoint in the registered order'
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
    Assert-LeanTTYAgentContinuationPaths -Paths $paths
    # SSH auth ran in the old prefix. Only its formal admission array may change;
    # input, fixture, oracle and cleanup code must remain byte-identical.
    if ($paths -contains 'tools/verify-ssh-auth-pc.ps1') {
        $oldAuth = (& git -C $RepoRoot show ($oldCommit + ':tools/verify-ssh-auth-pc.ps1')) -join "`n"
        if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect original SSH owner' }
        $newAuth = (Get-Content -LiteralPath (Join-Path $RepoRoot 'tools/verify-ssh-auth-pc.ps1')) -join "`n"
        $normalized = @($oldAuth, $newAuth) | ForEach-Object {
            $tokens = $null; $errors = $null
            $ast = [Management.Automation.Language.Parser]::ParseInput($_, [ref]$tokens, [ref]$errors)
            $calls = @($ast.FindAll({ param($node)
                $node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -ceq 'Assert-LeanTTYCandidateHarnessCompatibility'
            }, $true))
            if ($errors.Count -ne 0 -or $calls.Count -ne 1) { throw 'SSH compatibility owner is ambiguous' }
            $arrays = @($calls[0].CommandElements | Where-Object {
                $_ -is [Management.Automation.Language.ArrayExpressionAst]
            })
            if ($arrays.Count -ne 1) { throw 'SSH compatibility allowlist is ambiguous' }
            $_.Remove($arrays[0].Extent.StartOffset, $arrays[0].Extent.Text.Length).Insert($arrays[0].Extent.StartOffset, '<allowlist>')
        }
        if ($normalized[0] -cne $normalized[1]) { throw 'SSH prefix behavior changed; R3 required' }
    }

    $failed = $old.stages[-2]
    if ($failed.name -cne 'agent-compatibility' -or $failed.status -cne 'failed' -or
        $old.stages[-1].status -cne 'pending' -or $old.stages[-1].attemptCount -ne 0) {
        throw 'Continuation requires Agent failed and SSH never started'
    }
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
        $admission.failedAgentSha256 -cne $agentHash -or
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
    $agentScriptHash = (Get-FileHash -LiteralPath (Join-Path $RepoRoot 'tools/verify-agent-compatibility-pc.ps1') -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($admission.agentScriptSha256 -cne $agentScriptHash) { throw 'Agent repair changed after admission' }

    $prefix = @()
    for ($index = 1; $index -lt $definitions.Count - 2; $index++) {
        $stage = $old.stages[$index]
        if ($stage.name -cne $names[$index] -or $stage.script -cne $definitions[$index].script -or
            $stage.status -cne 'passed') { throw 'Continuation prefix is incomplete or reordered' }
        $summary = Get-LeanTTYReleaseEvidenceSummary -Path $stage.resultPath -StageName $stage.name
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
    [pscustomobject]@{ manifest = $Manifest; prefix = $prefix; failedAttemptId = $failed.attemptId }
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
