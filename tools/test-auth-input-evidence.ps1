param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'hdc-common.ps1')
. (Join-Path $PSScriptRoot 'device-regression.ps1')
function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $threw = $false
    try { & $Action } catch { $threw = $true }
    if (-not $threw) { throw $Message }
}

& {
    $authAst = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot 'verify-ssh-auth-pc.ps1'), [ref]$null, [ref]$null)
    foreach ($name in @('Get-AuthFixturePasswordEvidence',
        'Save-AuthFixturePasswordEvidence', 'Submit-AuthValue', 'Assert-NoSecretExposure', 'Write-AuthEvidence')) {
        $definition = $authAst.FindAll({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true) | Select-Object -First 1
        Assert-True ($null -ne $definition) "Missing authentication evidence helper: $name"
        Invoke-Expression $definition.Extent.Text
    }
    $sampleLogs = 'irrelevant runtime-secret-value'
    $fixtureLogs = @(
        'auth method=password scenario=Password result=matched',
        'auth method=password scenario=Mosh result=reject expected_bytes=32 received_bytes=31 overlap_mismatches=23 length_delta=-1',
        'auth method=password scenario=runtime-secret-value result=matched',
        'auth method=password scenario=Password result=matched secret=runtime-secret-value'
    ) -join "`n"
    $fixture = Get-AuthFixturePasswordEvidence -Logs $fixtureLogs
    Assert-True ($fixture.status -eq 'observed' -and $fixture.events.Count -eq 2 -and
        $fixture.unparsedEventCount -eq 2 -and $fixture.events[0].exactCredentialMatch -eq $true -and
        $null -eq $fixture.events[0].receivedBytes -and $fixture.events[1].receivedBytes -eq 31 -and
        $fixture.events[1].lengthDelta -eq -1) 'Fixture evidence invented byte counts or accepted an unsafe log line'
    Assert-True (($fixture | ConvertTo-Json -Depth 12) -notmatch 'runtime-secret-value') (
        'Authentication evidence retained raw application or fixture text'
    )

    # Exercise real submission/audit functions; only external device boundaries are mocked.
    $hdc = 'unused'; $Target = 'unused'; $appPid = '100'
    $EvidenceDirectory = [IO.Path]::GetTempPath()
    $secrets = @('runtime-secret-value'); $currentStage = 'password-success'
    $authInputObservations = [Collections.Generic.List[object]]::new()
    function Focus-ActiveCommandInput { return @{ attributes = @{} } }
    function Clear-LeanTTYAppLogs {}
    function Get-LeanTTYAppLogs { return $sampleLogs.Replace('runtime-secret-value', 'redacted') }
    function Get-LeanTTYDeviceLayout { return @{ attributes = @{} } }
    function Wait-AuthLog {}
    $script:authEnterCalls = 0
    $script:rejectAuthTarget = $false
    function Invoke-TemporaryFixtureAuthText {
        if ($script:rejectAuthTarget) {
            throw (New-LeanTTYTextInputFailure -Phase after -ExpectedNode $null -CurrentNodes @() `
                -Message '[harness] synthetic target rejection')
        }
    }
    function Invoke-LeanTTYDeviceKey { $script:authEnterCalls++ }
    Submit-AuthValue -Value 'runtime-secret-value' -LayoutName 'password.json'
    Assert-True ($authInputObservations.Count -eq 1 -and
        $authInputObservations[0].submitAckObserved -and $authInputObservations[0].secretAuditPassed) (
        'Successful authentication submission lost pre-Enter secret audit'
    )
    $script:rejectAuthTarget = $true
    Assert-Throws { Submit-AuthValue -Value 'runtime-secret-value' -LayoutName 'password.json' } 'Target rejection was swallowed'
    Assert-True ($script:authEnterCalls -eq 1 -and $authInputObservations.Count -eq 2 -and
        $authInputObservations[1].result -eq 'failed' -and
        $authInputObservations[1].textTargetFailure.phase -eq 'after' -and
        -not $authInputObservations[1].secretAuditPassed) (
        'Failed authentication did not retain evidence before cleanup, or sent Enter after rejection'
    )
    function Get-LeanTTYAppLogs { throw 'synthetic unavailable logs' }
    Assert-Throws { Submit-AuthValue -Value 'runtime-secret-value' -LayoutName 'password.json' } 'Missing logs replaced the original failure'
    Assert-True (-not $authInputObservations[2].secretAuditPassed -and
        $authInputObservations[2].textTargetFailure.phase -eq 'after') 'Diagnostic read failure hid the original target failure'
    Assert-True (($authInputObservations | ConvertTo-Json -Depth 12) -notmatch 'runtime-secret-value') 'Submission record exposed credentials'
    $script:rejectAuthTarget = $false
    function Get-LeanTTYAppLogs { return '' }
    Submit-AuthValue -Value 'runtime-secret-value' -LayoutName 'password.json'
    Assert-True ($script:authEnterCalls -eq 2 -and $authInputObservations[3].submitAckObserved -and
        $authInputObservations[3].secretAuditPassed) (
        'Authentication without obsolete metrics lost the secret audit'
    )

    function Get-LeanTTYAppLogs { return 'runtime-secret-value' }
    Assert-Throws { Submit-AuthValue -Value 'runtime-secret-value' -LayoutName 'password.json' } 'Secret exposure did not stop submission'
    Assert-True ($script:authEnterCalls -eq 2 -and $authInputObservations[4].result -eq 'failed' -and
        -not $authInputObservations[4].enterAttempted) 'Privacy audit failure sent Enter'

    function Get-LeanTTYAppLogs { return '' }
    function Wait-AuthLog { throw 'synthetic ACK timeout' }
    Assert-Throws { Submit-AuthValue -Value 'runtime-secret-value' -LayoutName 'password.json' } 'Missing submission ACK was swallowed'
    Assert-True ($script:authEnterCalls -eq 3 -and $authInputObservations[5].enterAttempted -and
        -not $authInputObservations[5].submitAckObserved -and $authInputObservations[5].result -eq 'failed') (
        'Failed ACK was promoted to success or retried'
    )
    function Focus-ActiveCommandInput {
        throw (New-LeanTTYTextInputFailure -Phase before -ExpectedNode $null -CurrentNodes @() `
            -Message '[harness] synthetic pre-focus rejection')
    }
    $script:unscopedAuthRead = $false
    function Get-LeanTTYAppLogs { $script:unscopedAuthRead = $true; return $sampleLogs }
    Assert-Throws { Submit-AuthValue -Value 'runtime-secret-value' -LayoutName 'password.json' } 'Pre-focus rejection was swallowed'
    Assert-True ($script:authEnterCalls -eq 3 -and -not $script:unscopedAuthRead -and
        -not $authInputObservations[6].secretAuditPassed -and
        $authInputObservations[6].textTargetFailure.phase -eq 'before') (
        'Pre-focus failure captured unscoped logs or sent Enter'
    )

    $fixtureStderr = 'unused-fixture-path'
    function Test-Path { return $true }
    function Read-FixtureLogText { return $fixtureLogs }
    Save-AuthFixturePasswordEvidence
    $fixtureLogs = '' # Model cleanup after retention, for both successful and failed runs.
    Assert-True ($script:fixturePasswordEvidence.events.Count -eq 2) 'Fixture cleanup erased retained authentication outcomes'

    # Run the real final writer and read its JSON; no HDC, signing or fixture process.
    $startedAt = [DateTimeOffset]::UtcNow
    $scenarioResult = 'failed'; $runMode = 'diagnostic'; $DiagnosticHap = 'synthetic-no-device'
    $commandObservations = [Collections.Generic.List[object]]::new()
    $connectedInputObservations = [Collections.Generic.List[object]]::new()
    $checks = @(); $selectedStageNames = @(); $harnessDifferencePaths = @()
    $candidate = @{ sha256 = 'synthetic'; gitCommit = 'synthetic'; gitTree = 'synthetic'; gitDirty = $true }
    $textTargetFailure = $authInputObservations[6].textTargetFailure
    $evidencePath = Join-Path ([IO.Path]::GetTempPath()) ('leantty-auth-evidence-' + [Guid]::NewGuid().ToString('N') + '.json')
    try {
        Write-AuthEvidence
        $json = [IO.File]::ReadAllText($evidencePath)
        $saved = $json | ConvertFrom-Json -Depth 20
        Assert-True ($saved.result -eq 'failed' -and $saved.runMode -eq 'diagnostic' -and
            $saved.inputBoundary.submissions.Count -eq 7 -and
            $saved.inputBoundary.submissions[0].secretAuditPassed -and
            $saved.inputBoundary.submissions[3].secretAuditPassed -and
            $saved.inputBoundary.submissions[6].textTargetFailure.phase -eq 'before' -and
            $saved.inputBoundary.fixturePassword.events[1].receivedBytes -eq 31 -and
            $saved.inputBoundary.textTargetFailure.phase -eq 'before') (
            'Final authentication JSON lost nested failure, counters, nulls or fixture outcomes'
        )
        Assert-True ($saved.inputBoundary.targetScope -eq 'operation-local-native-component-identity' -and
            $saved.inputBoundary.fixtureScope -eq 'run-ordered-password-events-no-submission-correlation' -and
            $json -notmatch 'runtime-secret-value') 'Final authentication report lost scope labels or exposed input'
    } finally {
        if ([IO.File]::Exists($evidencePath)) { Remove-Item -LiteralPath $evidencePath -Force }
    }
    function Test-Path { return $false }
    Save-AuthFixturePasswordEvidence
    Assert-True ($script:fixturePasswordEvidence.status -eq 'missing' -and
        $script:fixturePasswordEvidence.events.Count -eq 0) 'Missing fixture log reused stale evidence'
    function Test-Path { return $true }
    function Read-FixtureLogText { throw 'synthetic unavailable fixture log' }
    Save-AuthFixturePasswordEvidence
    Assert-True ($script:fixturePasswordEvidence.status -eq 'unavailable' -and
        $script:fixturePasswordEvidence.events.Count -eq 0) 'Fixture read failure hid its status or reused stale evidence'
    $source = $authAst.Extent.Text
    Assert-True ($source.LastIndexOf('Save-AuthFixturePasswordEvidence') -lt
        $source.LastIndexOf('Remove-Item -LiteralPath $fixtureRoot') -and
        $source.Contains('inputBoundary = [ordered]@{')) 'Authentication report does not retain evidence before fixture cleanup'
}

Write-Host 'Authentication input evidence: privacy, target loss, submission and fixture outcomes passed.'
