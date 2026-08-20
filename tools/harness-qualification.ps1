function Assert-LeanTTYHarnessQualificationPhysicalEvidence {
    param(
        [Parameter(Mandatory = $true)][object]$Evidence,
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[0-9a-fA-F]{64}$')]
        [string]$ReviewHapSha256,
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[0-9a-fA-F]{40}$')]
        [string]$HarnessCommit,
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[0-9a-fA-F]{40}$')]
        [string]$HarnessTree,
        [switch]$RequireCleanHarness
    )

    if ([int]$Evidence.schemaVersion -lt 2 -or
        [string]$Evidence.scenario -ne 'ssh-interactive-authentication' -or
        [string]$Evidence.result -ne 'passed') {
        throw 'Harness qualification physical scenario did not pass with the supported evidence schema'
    }
    if ([string]$Evidence.candidate.sha256 -ne $ReviewHapSha256.ToLowerInvariant()) {
        throw 'Harness qualification physical evidence does not identify the explicit review-test HAP'
    }
    if ([string]$Evidence.harness.gitCommit -ne $HarnessCommit.ToLowerInvariant() -or
        [string]$Evidence.harness.gitTree -ne $HarnessTree.ToLowerInvariant()) {
        throw 'Harness qualification physical evidence does not identify the current harness'
    }
    if ($RequireCleanHarness -and [bool]$Evidence.harness.gitDirty) {
        throw 'Formal harness qualification requires clean physical evidence'
    }

    $checkNames = @($Evidence.checks | ForEach-Object { [string]$_.name })
    foreach ($requiredCheck in @(
            'fixture-and-device-preflight',
            'password-success',
            'preferences-unchanged-during-authentication'
        )) {
        if ($requiredCheck -notin $checkNames) {
            throw "Harness qualification physical evidence is missing '$requiredCheck'"
        }
    }

    $automation = $Evidence.automation
    if ($null -eq $automation -or
        [string]$automation.businessVerdict -ne 'passed' -or
        [string]$automation.harnessStability -ne 'stable' -or
        [int]$automation.commandCount -lt 1 -or
        [int]$automation.inputAttemptCount -ne [int]$automation.commandCount -or
        [int]$automation.inputMismatchCount -ne 0 -or
        [int]$automation.enterCount -ne [int]$automation.commandCount) {
        throw 'Harness qualification ordinary-command channel was not stable and exact'
    }
    if ([string]::IsNullOrWhiteSpace([string]$Evidence.input.secretInjection) -or
        [string]$Evidence.input.secretInjection -notmatch 'runtime-generated-temporary') {
        throw 'Harness qualification secret-input channel was not exercised with temporary values'
    }
    if ([string]$Evidence.cleanup.result -ne 'passed' -or
        -not [bool]$Evidence.cleanup.knownHostRemovalCommandCompleted -or
        -not [bool]$Evidence.cleanup.reverseMappingAbsenceAudit -or
        -not [bool]$Evidence.cleanup.fixtureProcessAbsenceAudit) {
        throw 'Harness qualification cleanup audit did not pass'
    }
    if ([string]$Evidence.failureDomain -ne 'none') {
        throw 'Harness qualification retained a non-empty failure domain'
    }

    return [pscustomobject][ordered]@{
        ordinaryCommandCount = [int]$automation.commandCount
        ordinaryInputAttempts = [int]$automation.inputAttemptCount
        ordinaryInputMismatches = [int]$automation.inputMismatchCount
        ordinaryEnterCount = [int]$automation.enterCount
        harnessStability = [string]$automation.harnessStability
        secretInput = 'runtime-generated-temporary-non-echoing-value'
        layout = 'serialized-uitest-layout'
        logs = 'structured-app-and-fixture-events'
        controlledServer = 'repository-only-russh-fixture'
        cleanup = 'known-host-reverse-mapping-fixture-and-preferences-audited'
    }
}
