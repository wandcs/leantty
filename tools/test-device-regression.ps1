param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'hdc-common.ps1')
. (Join-Path $PSScriptRoot 'device-regression.ps1')

& (Join-Path $PSScriptRoot 'test-native-device-harness.ps1')
& (Join-Path $PSScriptRoot 'test-command-completion.ps1')
& (Join-Path $PSScriptRoot 'diagnose-text-input-pc.ps1') -SelfTest
& (Join-Path $PSScriptRoot 'test-mosh-runtime-contract.ps1')
& (Join-Path $PSScriptRoot 'test-recovery-command-probes.ps1')
& (Join-Path $PSScriptRoot 'test-mosh-lifecycle-observation.ps1')
& (Join-Path $PSScriptRoot 'test-notification-regression.ps1')
& (Join-Path $PSScriptRoot 'test-put-get-mapping-preflight.ps1')
& (Join-Path $PSScriptRoot 'test-host-identity-cleanup.ps1')

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

& (Join-Path $PSScriptRoot 'test-auth-input-evidence.ps1')

$deleteKeyButtonTexts = @(Resolve-LeanTTYDialogButtonTexts -ButtonText 'Delete key')
Assert-True (
    $deleteKeyButtonTexts.Count -eq 2 -and
    $deleteKeyButtonTexts -contains 'Delete key' -and
    $deleteKeyButtonTexts -contains '删除密钥'
) 'Delete-key dialog matching does not cover the supported English and Chinese labels'

$closePaneButtonTexts = @(Resolve-LeanTTYDialogButtonTexts -ButtonText 'Close pane')
Assert-True (
    $closePaneButtonTexts.Count -eq 2 -and
    $closePaneButtonTexts -contains 'Close pane' -and
    $closePaneButtonTexts -contains '关闭分屏'
) 'Close-pane dialog matching does not cover the supported English and Chinese labels'

$unknownButtonTexts = @(Resolve-LeanTTYDialogButtonTexts -ButtonText 'Acceptance action')
Assert-True (
    $unknownButtonTexts.Count -eq 1 -and
    $unknownButtonTexts[0] -eq 'Acceptance action'
) 'Unknown dialog actions must keep exact matching'

$layout = @'
{
  "attributes": {"bounds":"[0,0][3120,2080]","text":"","originalText":"","hint":""},
  "children": [
    {
      "attributes": {
        "bounds":"[120,130][3000,1980]",
        "text":"ssh-keygen -p -f regression_key",
        "originalText":"ssh-keygen -p -f regression_key",
        "hint":"Terminal input"
      },
      "children": []
    },
    {
      "attributes": {
        "bounds":"[1900,1200][2200,1300]",
        "text":"Delete key",
        "originalText":"Delete key",
        "hint":""
      },
      "children": []
    }
  ]
}
'@ | ConvertFrom-Json -Depth 20

foreach ($focusCount in @(0, 5)) {
    & {
        function Get-HdcUiLayout {
            return @{ attributes = @{}; children = @(for ($index = 0; $index -lt $focusCount; $index++) {
                @{ attributes = @{ type = 'TextInput'; hint = 'private-hint'; focused = 'true';
                    hierarchy = "ROOT123,$index"; bounds = '[0,0][20,20]' }; children = @() }
            }) }
        }
        function Invoke-FakeHdc { throw 'Input must not be attempted for non-unique focus' }
        $focusFailure = $null
        try {
            Invoke-LeanTTYDeviceText -Hdc Invoke-FakeHdc -Target regression-device -Text private-value
        } catch { $focusFailure = $_.Exception.Data['LeanTTYTextInputFailure'] }
        Assert-True ($null -ne $focusFailure -and $focusFailure.focusedCount -eq $focusCount -and
            $focusFailure.targets.Count -eq [Math]::Min(4, $focusCount) -and
            $focusFailure.targetsTruncated -eq ($focusCount -gt 4) -and
            ($focusFailure | ConvertTo-Json -Depth 12) -notmatch 'ROOT123|private-hint|private-value') (
            'Non-unique focus failure lost its count, exceeded the evidence bound or leaked content'
        )
    }
}

& {
    function Get-HdcTargets {
        return @([pscustomobject]@{
                key = 'regression-device'; transport = 'USB'; status = 'Ready'; raw = ''
            })
    }
    Assert-True (
        (Assert-HdcTargetReady -Hdc 'unused' -Target 'regression-device').status -eq 'Ready'
    ) 'Ready USB HDC target was rejected by preflight'
}

& {
    function Invoke-FailingHdc {
        '[E001005] runtime-only-secret'
        $global:LASTEXITCODE = 0
    }
    $failureMessage = ''
    try {
        Invoke-HdcChecked `
            -Hdc 'Invoke-FailingHdc' `
            -Target 'regression-device' `
            -Arguments @('shell', 'probe') `
            -Operation 'bounded probe' | Out-Null
    } catch {
        $failureMessage = $_.Exception.Message
    }
    Assert-True (
        $failureMessage.Contains('hdcCode=E001005') -and
        -not $failureMessage.Contains('runtime-only-secret')
    ) 'Checked HDC failures either lost the standard code or exposed command output'
}

Assert-Throws -Action {
    Invoke-LeanTTYDeviceText -Hdc 'unused' -Target 'unused' -Text "line`nbreak"
} -Message 'Device text input accepted a command separator'

Assert-True (Test-HdcCommandFailure -Output '[E001005] target disconnected') (
    'HDC standard error code was not recognized as a failed command'
)
Assert-True (Test-HdcCommandFailure -Output 'Max tag count is 10 [CODE: -42]') (
    'HarmonyOS command error code was not recognized as a failed command'
)
Assert-True (-not (Test-HdcCommandFailure -Output 'Forwardport result:OK')) (
    'Successful HDC output was classified as a failure'
)

$helperTestRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'leantty-helper-' + [Guid]::NewGuid().ToString('N')
)
New-Item -ItemType Directory -Path $helperTestRoot | Out-Null
try {
    $controlDirectory = Join-Path $helperTestRoot 'fixture'
    New-Item -ItemType Directory -Path $controlDirectory | Out-Null
    Assert-True (
        $null -eq (Read-LeanTTYFixtureReadiness -ControlDirectory $controlDirectory)
    ) 'Missing fixture files were accepted as ready'
    [IO.File]::WriteAllText(
        (Join-Path $controlDirectory 'fixture-ready'),
        "address=127.0.0.1:22222`npid=4242`n",
        [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::WriteAllText(
        (Join-Path $controlDirectory 'server-credentials'),
        "password=temporary`naccount=fixture`n",
        [Text.UTF8Encoding]::new($false)
    )
    $fixtureReadiness = Read-LeanTTYFixtureReadiness `
        -ControlDirectory $controlDirectory `
        -RequiredCredentialNames @('password', 'account') `
        -ExpectedAddress '127.0.0.1:22222'
    Assert-True (
        $fixtureReadiness.linuxPid -eq 4242 -and
        $fixtureReadiness.credentials.password -eq 'temporary' -and
        $null -eq (Read-LeanTTYFixtureReadiness `
            -ControlDirectory $controlDirectory `
            -ExpectedAddress '127.0.0.1:33333')
    ) 'Fixture readiness parsing lost exact address, PID or credential validation'

    & {
        $script:confirmTransfer = $false
        function Invoke-FakeFileHdc {
            if ($args.Count -ge 6 -and $args[2] -eq 'file' -and $args[3] -eq 'recv') {
                [IO.File]::WriteAllText($args[5], '{"children":[]}', [Text.UTF8Encoding]::new($false))
                if ($script:confirmTransfer) { 'FileTransfer finish, Size:15, File count = 1' } else { 'done' }
            }
            $global:LASTEXITCODE = 0
        }
        $receivedPath = Join-Path $helperTestRoot 'received.json'
        Assert-Throws -Action {
            Receive-HdcFileChecked `
                -Hdc 'Invoke-FakeFileHdc' `
                -Target 'regression-device' `
                -RemotePath '/data/local/tmp/layout.json' `
                -LocalPath $receivedPath | Out-Null
        } -Message 'Device file receive accepted output without FileTransfer finish'
        $script:confirmTransfer = $true
        $confirmedPath = Receive-HdcFileChecked `
            -Hdc 'Invoke-FakeFileHdc' `
            -Target 'regression-device' `
            -RemotePath '/data/local/tmp/layout.json' `
            -LocalPath $receivedPath
        Assert-True (
            $confirmedPath -eq [IO.Path]::GetFullPath($receivedPath)
        ) 'Confirmed device file receive did not return the exact local file'
    }
} finally {
    if ((Test-Path -LiteralPath $helperTestRoot) -and
        [IO.Path]::GetFullPath($helperTestRoot).StartsWith(
            [IO.Path]::GetFullPath([IO.Path]::GetTempPath()),
            [StringComparison]::OrdinalIgnoreCase
        )) {
        Remove-Item -LiteralPath $helperTestRoot -Recurse -Force
    }
}

& {
    function Get-HdcTargets {
        return @([pscustomobject]@{
                key = 'regression-device'; transport = 'USB'; status = 'Offline'; raw = ''
            })
    }
    Assert-Throws -Action {
        Assert-HdcTargetReady -Hdc 'unused' -Target 'regression-device'
    } -Message 'Offline HDC target was accepted instead of stopping at preflight'
}

& {
    function Get-HdcTargets {
        return @([pscustomobject]@{
                key = 'regression-device'; transport = 'USB'; status = 'Offline'; raw = ''
            })
    }
    $message = ''
    try {
        Resolve-LeanTTYRegressionTarget -Hdc 'unused'
    } catch {
        $message = $_.Exception.Message
    }
    Assert-True ($message.StartsWith('[infrastructure]')) (
        'No ready device was not classified as an infrastructure stop'
    )
}

& {
    function Get-HdcTargets {
        return @(
            [pscustomobject]@{ key = 'device-a'; transport = 'USB'; status = 'Ready'; raw = '' },
            [pscustomobject]@{ key = 'device-b'; transport = 'USB'; status = 'Ready'; raw = '' }
        )
    }
    $message = ''
    try {
        Resolve-LeanTTYRegressionTarget -Hdc 'unused'
    } catch {
        $message = $_.Exception.Message
    }
    Assert-True ($message.StartsWith('[environment]')) (
        'Ambiguous ready targets were not classified as an environment stop'
    )
}

$devicePreflightPath = Join-Path $PSScriptRoot 'preflight-device.ps1'
Assert-True (Test-Path -LiteralPath $devicePreflightPath -PathType Leaf) (
    'Standalone device control preflight is missing'
)
$preflightTokens = $null
$preflightErrors = $null
[void][Management.Automation.Language.Parser]::ParseFile(
    $devicePreflightPath,
    [ref]$preflightTokens,
    [ref]$preflightErrors
)
Assert-True ($preflightErrors.Count -eq 0) 'Standalone device control preflight has invalid syntax'
$devicePreflightText = Get-Content -LiteralPath $devicePreflightPath -Raw
Assert-True (
    $devicePreflightText.Contains('Resolve-LeanTTYRegressionTarget') -and
    $devicePreflightText.Contains('Assert-HdcTargetReady') -and
    $devicePreflightText.Contains('Invoke-HdcChecked') -and
    $devicePreflightText.Contains('Get-LeanTTYDeviceLayout') -and
    $devicePreflightText.Contains("gate = 'device-control-preflight'") -and
    $devicePreflightText.Contains('acceptanceEligible = $false') -and
    $devicePreflightText.Contains('productBehaviorClaimed = $false') -and
    $devicePreflightText.Contains('Get-PreflightFailureDomain') -and
    -not $devicePreflightText.Contains('aa start') -and
    -not $devicePreflightText.Contains('power-shell wakeup') -and
    -not $devicePreflightText.Contains('Start-LeanTTYRegressionApp')
) 'Device preflight mutates product state, repairs the target, or claims product acceptance'

$idleState = Get-LeanTTYAcceptanceIdleInputState -Logs @'
ACCEPTANCE_IDLE_RESULT kind=0,input=partial,completionActive=false,menuActive=false
ACCEPTANCE_IDLE_RESULT kind=0,input=exact command,completionActive=false,menuActive=false
'@
Assert-True (
    $null -ne $idleState -and $idleState.input -ceq 'exact command' -and
    -not $idleState.completionActive -and -not $idleState.menuActive
) 'Acceptance input parser did not return the last native command-buffer state'

& {
    $script:injectedText = [Collections.Generic.List[string]]::new()
    $script:submittedKeyCodes = [Collections.Generic.List[int]]::new()
    $script:interruptCount = 0
    $script:bufferChecks = 0
    function Clear-LeanTTYAppLogs { param($Hdc, $Target) }
    function Invoke-LeanTTYDeviceCtrlC {
        param($Hdc, $Target)
        $script:interruptCount++
    }
    function Wait-LeanTTYAppLog {
        param($Hdc, $Target, $ProcessId, $Pattern, $TimeoutSeconds)
        if ($Pattern -match 'ACCEPTANCE_IDLE_INTERRUPT') { return 'cleared' }
        if ($Pattern -match 'ACCEPTANCE_INPUT_SUBMIT') {
            $logs = @'
ACCEPTANCE_INPUT_SUBMIT sequence=1,kind=command,input=echo LEANTTY_SMOKE
ACCEPTANCE_IDLE_RESULT kind=1,input=,completionActive=false,menuActive=false
'@
            if ($logs -notmatch $Pattern) { throw 'submission acknowledgement pattern did not match' }
            return $logs
        }
        throw "Unexpected log wait: $Pattern"
    }
    function Wait-LeanTTYAcceptanceIdleInputState {
        param($Hdc, $Target, $ProcessId, $Expected, $TimeoutSeconds)
        $script:bufferChecks++
        if ($script:bufferChecks -eq 1) {
            return [pscustomobject]@{ input = 'echo LEANTTY_SMOK'; exact = $false }
        }
        return [pscustomobject]@{ input = $Expected; exact = $true }
    }
    function Invoke-LeanTTYDeviceText {
        param($Hdc, $Target, $Text, $InputNode)
        Assert-True ($null -ne $InputNode) 'Verified command input was not coordinate-targeted'
        $script:injectedText.Add($Text)
    }
    function Invoke-LeanTTYDeviceKey {
        param($Hdc, $Target, $KeyCode)
        $script:submittedKeyCodes.Add($KeyCode)
    }

    $observations = [Collections.Generic.List[object]]::new()
    $result = Submit-LeanTTYDeviceCommand `
        -Hdc 'unused' `
        -Target 'unused' `
        -ProcessId '1234' `
        -Command 'echo LEANTTY_SMOKE' `
        -Stage 'short-write-retry' `
        -ObservationSink $observations `
        -InputNodeProvider { [pscustomobject]@{ attributes = @{ bounds = '[0,0][10,10]' } } }
    $summary = Get-LeanTTYDeviceCommandAutomationSummary `
        -Observations $observations `
        -BusinessVerdict 'passed' `
        -BusinessPostcondition 'fixture-observed-command-result'
    $summaryJson = ConvertTo-Json -InputObject $summary -Depth 8 -Compress
    Assert-True (
        $result.inputAttempts -eq 2 -and
        $script:injectedText.Count -eq 2 -and
        $script:interruptCount -eq 2 -and
        $script:submittedKeyCodes.Count -eq 1 -and
        $script:submittedKeyCodes[0] -eq 2054 -and
        $summary.businessVerdict -eq 'passed' -and
        $summary.harnessStability -eq 'flaky-harness' -and
        $summary.inputAttemptCount -eq 2 -and
        $summary.inputMismatchCount -eq 1 -and
        $summary.enterCount -eq 1 -and
        $summary.commands[0].stage -eq 'short-write-retry' -and
        $summary.commands[0].actualLength -eq 18 -and
        $summary.commands[0].lastProvenBoundary -eq 'submission-acknowledged' -and
        $summaryJson -notmatch 'LEANTTY_SMOKE'
    ) 'Verified command contract did not retry before Enter and submit exactly once'
}

& {
    function Clear-LeanTTYAppLogs { param($Hdc, $Target) }
    function Invoke-LeanTTYDeviceCtrlC { param($Hdc, $Target) }
    function Wait-LeanTTYAcceptanceIdleInputState {
        param($Hdc, $Target, $ProcessId, $Expected, $TimeoutSeconds)
        return [pscustomobject]@{ input = $Expected; exact = $true }
    }
    function Invoke-LeanTTYDeviceText { param($Hdc, $Target, $Text, $InputNode) }
    function Invoke-LeanTTYDeviceKey { param($Hdc, $Target, $KeyCode) }
    function Wait-LeanTTYAppLog {
        param($Hdc, $Target, $ProcessId, $Pattern, $TimeoutSeconds)
        if ($Pattern -match 'ACCEPTANCE_IDLE_INTERRUPT') { return 'cleared' }
        throw 'submission acknowledgement missing'
    }
    $message = ''
    $observations = [Collections.Generic.List[object]]::new()
    try {
        Submit-LeanTTYDeviceCommand `
            -Hdc 'unused' -Target 'unused' -ProcessId '1234' -Command 'key list' `
            -Stage 'missing-submit-ack' -ObservationSink $observations `
            -InputNodeProvider {
                [pscustomobject]@{ attributes = @{ bounds = '[0,0][10,10]' } }
            } | Out-Null
    } catch {
        $message = $_.Exception.Message
    }
    $summary = Get-LeanTTYDeviceCommandAutomationSummary `
        -Observations $observations `
        -BusinessVerdict 'unknown' `
        -BusinessPostcondition 'command-result-not-observable'
    Assert-True (
        $message -match 'unknown' -and
        $summary.businessVerdict -eq 'unknown' -and
        $summary.harnessStability -eq 'unknown' -and
        $summary.enterCount -eq 1 -and
        $summary.commands[0].failureDomain -eq 'unknown' -and
        $summary.commands[0].lastProvenBoundary -eq 'enter-dispatched'
    ) (
        'Missing post-Enter acknowledgement was not classified as an unknown outcome'
    )
}

$environmentSummary = Get-LeanTTYDeviceCommandAutomationSummary `
    -Observations @([pscustomobject]@{
        result = 'failed'
        failureDomain = 'environment'
        inputAttempts = 1
        inputMismatches = 0
        enterCount = 0
    }) `
    -BusinessVerdict 'failed' `
    -BusinessPostcondition 'not-reached'
Assert-True ($environmentSummary.harnessStability -eq 'not-assessed') (
    'Environment interruption was incorrectly classified as a harness failure'
)

& {
    $prepared = [pscustomobject]@{ command = $null }
    $script:dynamicEnterCount = 0
    function Clear-LeanTTYAppLogs { param($Hdc, $Target) }
    function Invoke-LeanTTYDeviceCtrlC { param($Hdc, $Target) }
    function Wait-LeanTTYAppLog {
        param($Hdc, $Target, $ProcessId, $Pattern, $TimeoutSeconds)
        return 'acknowledged'
    }
    function Wait-LeanTTYAcceptanceIdleInputState {
        param($Hdc, $Target, $ProcessId, $Expected, $TimeoutSeconds)
        return [pscustomobject]@{ input = $Expected; exact = $true }
    }
    function Invoke-LeanTTYDeviceKey {
        param($Hdc, $Target, $KeyCode)
        $script:dynamicEnterCount++
    }
    $result = Submit-LeanTTYDeviceCommand `
        -Hdc 'unused' -Target 'unused' -ProcessId '1234' `
        -InputNodeProvider {
            [pscustomobject]@{ attributes = @{ bounds = '[0,0][10,10]' } }
        } `
        -InputPreparer { param($inputNode, $inputAttempt) $prepared.command = 'completed command' } `
        -ExpectedCommandProvider { param($inputAttempt) $prepared.command }
    Assert-True (
        $result.expectedLength -eq 17 -and $script:dynamicEnterCount -eq 1
    ) 'Prepared Tab/Unicode command did not reuse the exact pre-submit contract'
}

& {
    $script:targetFailureResets = 0
    $script:targetFailureEnters = 0
    $observations = [Collections.Generic.List[object]]::new()
    function Reset-LeanTTYDeviceCommandInput { $script:targetFailureResets++ }
    function Clear-LeanTTYAppLogs {}
    function Invoke-LeanTTYDeviceKey { $script:targetFailureEnters++ }
    $expectedTarget = @{ attributes = @{ type='textField'; hint='private-hint'; hierarchy='ROOT9,0' } }
    $currentTarget = @{ attributes = @{ type='textField'; hint='private-hint'; hierarchy='ROOT9,1' } }
    $targetError = New-LeanTTYTextInputFailure -Message '[harness] Synthetic owner loss' -Phase after `
        -ExpectedNode $expectedTarget -CurrentNodes @($currentTarget)
    $caught = $null
    try {
        Submit-LeanTTYDeviceCommand -Hdc 'unused' -Target 'unused' -ProcessId '100' `
            -Command 'public-input' -Stage 'owner-loss-before-submit' -ObservationSink $observations `
            -InputNodeProvider { $expectedTarget } -InputPreparer { throw $targetError } | Out-Null
    } catch { $caught = $_.Exception }
    Assert-True ([object]::ReferenceEquals($caught, $targetError) -and $observations.Count -eq 1 -and
        $observations[0].result -eq 'failed' -and $observations[0].failureDomain -eq 'harness' -and
        $observations[0].textTargetFailure.phase -eq 'after' -and $observations[0].inputAttempts -eq 1 -and
        $observations[0].enterCount -eq 0 -and $script:targetFailureEnters -eq 0 -and
        $script:targetFailureResets -eq 1) 'Owner loss was not retained or triggered a retry, reset or Enter'
    Assert-True (($observations | ConvertTo-Json -Depth 12) -notmatch 'private-hint|ROOT9|public-input') (
        'Ordinary command failure evidence exposed target identifiers or input text'
    )
}

$deviceTextSource = (Get-Command Invoke-LeanTTYDeviceText).Definition
foreach ($evidenceOwner in @('verify-ssh-auth-pc.ps1', 'verify-key-passphrase-pc.ps1')) {
    $evidenceSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot $evidenceOwner) -Raw
    Assert-True ($evidenceSource.Contains('postInputSettleMilliseconds = 0')) (
        "$evidenceOwner still reports a fixed input delay that the shared helper no longer applies"
    )
}
$submitCommandParameters = (Get-Command Submit-LeanTTYDeviceCommand).Parameters.Keys
$submitCommandSource = (Get-Command Submit-LeanTTYDeviceCommand).Definition
$automationSummarySource = (Get-Command Get-LeanTTYDeviceCommandAutomationSummary).Definition
Assert-True (
    $deviceTextSource.Contains("'shell', 'uitest', 'uiInput', 'inputText', `$center.x, `$center.y, `$Text") -and
    -not $deviceTextSource.Contains("@('uiInput', 'text', `$Text)") -and
    $deviceTextSource.Contains('Get-HdcUiLayout') -and
    $deviceTextSource.Contains('[harness] Intended HarmonyOS text target is no longer uniquely focused')
) 'Ordinary device text does not atomically revalidate and target its intended focus node'
Assert-True (
    $submitCommandParameters -contains 'ProcessId' -and
    $submitCommandParameters -contains 'InputNodeProvider' -and
    $submitCommandParameters -contains 'ObservationSink' -and
    $submitCommandParameters -contains 'Stage' -and
    $submitCommandSource.Contains('Wait-LeanTTYAcceptanceIdleInputState') -and
    $submitCommandSource.Contains('ACCEPTANCE_INPUT_SUBMIT') -and
    -not $submitCommandSource.Contains('Get-LeanTTYTerminalInputText') -and
    $automationSummarySource.Contains("'flaky-harness'") -and
    $automationSummarySource.Contains('businessPostcondition') -and
    $automationSummarySource.Contains('inputMismatchCount')
) 'Device command submission does not enforce the native pre-submit buffer contract'

foreach ($ordinaryCommandOwner in @(
        'verify-key-passphrase-pc.ps1',
        'verify-ssh-auth-pc.ps1',
        'verify-terminal-search-pc.ps1',
        'verify-proxy-jump-pc.ps1',
        'verify-put-get-pc.ps1',
        'verify-startup-readiness-pc.ps1',
        'verify-startup-upgrade-pc.ps1'
    )) {
    $ownerText = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot $ordinaryCommandOwner)
    Assert-True (
        $ownerText.Contains('Submit-LeanTTYDeviceCommand') -and
        $ownerText.Contains('-ObservationSink') -and
        $ownerText.Contains('Get-LeanTTYDeviceCommandAutomationSummary')
    ) (
        "$ordinaryCommandOwner bypasses the observable ordinary command contract"
    )
}

$keyPassphraseVerifier = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'verify-key-passphrase-pc.ps1'
) -Raw
Assert-True (
    $keyPassphraseVerifier.Contains('Submit-LeanTTYDeviceCommand') -and
    -not $keyPassphraseVerifier.Contains("-Pattern 'ACCEPTANCE_IDLE_RESULT kind='")
) 'Key-passphrase verifier still duplicates the ordinary command submission contract'

$center = Get-LeanTTYBoundsCenter -Bounds '[1900,1200][2200,1300]'
Assert-True ($center.x -eq 2050 -and $center.y -eq 1250) (
    'Native-layout button coordinates were not calculated correctly'
)

Assert-LeanTTYLayoutExcludesValues -Layout $layout -Values @('runtime-only-secret')
Assert-Throws -Action {
    Assert-LeanTTYLayoutExcludesValues -Layout $layout -Values @('regression_key')
} -Message 'Layout secret detection did not reject an exposed value'

Assert-Throws -Action {
    Get-LeanTTYBoundsCenter -Bounds '[0,0][bad,20]'
} -Message 'Malformed device bounds were accepted'

$appLogParameters = (Get-Command Get-LeanTTYAppLogs).Parameters.Keys
$waitLogParameters = (Get-Command Wait-LeanTTYAppLog).Parameters.Keys
$waitLogSource = (Get-Command Wait-LeanTTYAppLog).Definition
$layoutCaptureSource = (Get-Command Get-LeanTTYDeviceLayout).Definition
$layoutCaptureParameters = (Get-Command Get-LeanTTYDeviceLayout).Parameters
$layoutPrimitiveSource = (Get-Command Get-HdcUiLayout).Definition
$physicalKeySource = (Get-Command Invoke-LeanTTYDevicePhysicalKey).Definition
Assert-True (
    $appLogParameters -notcontains 'Pid' -and
    $waitLogParameters -notcontains 'Pid' -and
    $waitLogSource.Contains('[ValidateRange(1, 60)]') -and
    $waitLogSource.Contains('Start-Sleep -Milliseconds 1000') -and
    -not $waitLogSource.Contains('Start-Sleep -Milliseconds 200')
) 'Device log helpers conflict with the read-only PowerShell PID automatic variable'
Assert-True (
    $layoutCaptureSource.Contains('for ($captureAttempt = 1; $captureAttempt -le 2; $captureAttempt++)') -and
    $layoutCaptureSource.Contains('HarmonyOS UI layout remained empty after two captures')
) 'Transient empty UiTest layouts are not handled by one bounded idempotent retry'
Assert-True (
    $layoutCaptureParameters.ContainsKey('BundleName') -and
    $layoutCaptureSource.Contains("[string]`$BundleName = 'com.leantty.app'") -and
    $layoutCaptureSource.Contains('Get-HdcUiLayout') -and
    $layoutPrimitiveSource.Contains("if (-not [string]::IsNullOrWhiteSpace(`$BundleName))") -and
    $layoutPrimitiveSource.Contains('Receive-HdcFileChecked') -and
    $devicePreflightText.Contains("-BundleName ''")
) 'Generic device preflight cannot request a global layout without launching LeanTTY'

$awakeLeaseParameter = (Get-Command Start-LeanTTYDeviceAwakeLease).Parameters['TimeoutMilliseconds']
Assert-True (
    $awakeLeaseParameter.Attributes.Where({ $_ -is [Management.Automation.ValidateRangeAttribute] }).MaxRange `
        -ge 7200000
) 'Device awake lease cannot cover the declared full-matrix budget'
Assert-True (
    $physicalKeySource.Contains('$process.WaitForExit(5000)') -and
    $physicalKeySource.Contains('$process.Kill($true)') -and
    $physicalKeySource.Contains('$attempt -le 2')
) 'Physical key injection can hang the device verification without a bounded retry'

$authenticationPattern = 'File transfer authentication prompt=(host-key|password)'
$liveOnlyObservation = Resolve-LeanTTYAuthenticationObservation `
    -SnapshotLogs '' `
    -LiveLogs 'File transfer authentication prompt=host-key' `
    -Pattern $authenticationPattern
$snapshotOnlyObservation = Resolve-LeanTTYAuthenticationObservation `
    -SnapshotLogs 'File transfer authentication prompt=password' `
    -LiveLogs '' `
    -Pattern $authenticationPattern
$dualObservation = Resolve-LeanTTYAuthenticationObservation `
    -SnapshotLogs 'File transfer authentication prompt=password' `
    -LiveLogs 'File transfer authentication prompt=password' `
    -Pattern $authenticationPattern
$missingObservation = Resolve-LeanTTYAuthenticationObservation `
    -SnapshotLogs '' -LiveLogs '' -Pattern $authenticationPattern
Assert-True (
    $liveOnlyObservation.liveObserved -and -not $liveOnlyObservation.snapshotObserved -and
    $snapshotOnlyObservation.snapshotObserved -and -not $snapshotOnlyObservation.liveObserved -and
    $dualObservation.snapshotObserved -and $dualObservation.liveObserved -and
    $null -eq $missingObservation
) 'Authentication observation does not distinguish snapshot loss from an unobserved product state'

$deviceRegressionText = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'device-regression.ps1'
) -Raw
$authFixtureLauncherText = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'start-ssh-auth-fixture.ps1'
) -Raw
$authFixtureSourceText = Get-Content -LiteralPath (
    Join-Path $repoRoot 'leantty_ssh\ssh-auth-fixture\src\main.rs'
) -Raw
Assert-True (
    $authFixtureLauncherText.Contains('[ValidateRange(1, 7200)]')
) 'SSH authentication fixture does not allow the bounded full acceptance budget'
Assert-True (
    $authFixtureLauncherText.Contains('[string]$MoshServerAddress') -and
    $authFixtureLauncherText.Contains('[int]$MoshServerPort = 0') -and
    $authFixtureLauncherText.Contains('MoshServerAddress must be one IPv4 address') -and
    $authFixtureLauncherText.Contains("channel-denied, mosh'")
) 'SSH authentication fixture launcher lacks the opt-in IPv4 Mosh endpoint contract'
Assert-True (
    $authFixtureSourceText.Contains(
        'const MOSH_FIXTURE_NETWORK_TIMEOUT_SECONDS: u64 = 30;'
    )
) 'Controlled Mosh fixture network timeout can no longer distinguish graceful close from fallback cleanup'
Assert-True (
    $authFixtureSourceText.Contains('const MOSH_SHELL_COMMAND: &str = "ltty-mosh-shell";') -and
    $authFixtureSourceText.Contains('const MOSH_TMUX_COMMAND: &str = "ltty-mosh-tmux";') -and
    $authFixtureSourceText.Contains('const MOSH_EDITOR_COMMAND: &str = "ltty-mosh-editor";') -and
    $authFixtureSourceText.Contains('const MOSH_RESIZE_COMMAND: &str = "ltty-mosh-resize";') -and
    $authFixtureSourceText.Contains('const MOSH_STREAM_INPUT_BYTES: usize = 512;') -and
    $authFixtureSourceText.Contains('parse_mosh_bootstrap_request') -and
    $authFixtureSourceText.Contains('mosh-server returned a port outside the requested range') -and
    $authFixtureSourceText.Contains('StdCommand::new("/bin/bash")') -and
    $authFixtureSourceText.Contains('StdCommand::new("tmux")') -and
    $authFixtureSourceText.Contains('bind -x') -and
    $authFixtureSourceText.Contains('\\C-g') -and
    $authFixtureSourceText.Contains('StdCommand::new("vim")') -and
    $authFixtureSourceText.Contains('control_directory.join("mosh-terminal-pid")') -and
    $authFixtureSourceText.Contains('control_directory.join("mosh-kernel-echo")') -and
    $authFixtureSourceText.Contains('.join("mosh-prediction-relay")') -and
    $authFixtureSourceText.Contains('.join("mosh-prediction-relay-paused")') -and
    $authFixtureSourceText.Contains('.join("mosh-prediction-relay-stats")') -and
    $authFixtureSourceText.Contains('control_directory.join("mosh-prediction-event")') -and
    $authFixtureSourceText.Contains('StdCommand::new("/bin/sh")') -and
    $authFixtureSourceText.Contains('.env("PS1", "MOSH_SESSION> ")') -and
    $authFixtureSourceText.Contains('.env("LTTY_MOSH_PREDICTION_EVENT", &prediction_event_path)') -and
    $authFixtureSourceText.Contains('rewrite_mosh_bootstrap_port') -and
    $authFixtureSourceText.Contains('MOSH_PREDICTION_RELAY_DELAY') -and
    $authFixtureSourceText.Contains('forward_mosh_prediction_client_datagrams') -and
    $authFixtureSourceText.Contains('forward_mosh_prediction_server_datagrams') -and
    $authFixtureSourceText.Contains('mosh_terminal_stty_args(kernel_echo)') -and
    -not $authFixtureSourceText.Contains('if prediction_echo_path.is_file()')
) 'Controlled Mosh fixture no longer launches the real shell, tmux, editor, resize and stream workloads'
Assert-True (
    $deviceRegressionText -notmatch 'hilog\s+-x[^\r\n]*\s-z\s'
) 'Device log query combines mutually exclusive hilog exit and tail modes'
Assert-True (
    $deviceRegressionText.Contains(
        'EntryAbility,IndexPage,'
    ) -and
    $deviceRegressionText.Contains(
        'TerminalSurfaceController,AppViewModel,BackgroundBellNotification'
    ) -and
    -not $deviceRegressionText.Contains('EntryAbility,Index,IndexPage')
) 'Device log query omits the Pane attention state owner'
Assert-True (
    $deviceRegressionText -notmatch 'terminal-line cleanup|backspaceCount'
) 'Device input cleanup still uses inferred backspaces'
Assert-True (
    $deviceRegressionText.Contains("'shell', 'uitest', 'uiInput', 'inputText', `$center.x, `$center.y, `$Text") -and
    -not $deviceRegressionText.Contains('ConvertTo-LeanTTYDeviceTextKeyCommand') -and
    $deviceRegressionText.Contains('HarmonyOS pre-input focus layout capture')
) 'Ordinary device text does not use the focus-verified targeted UiTest path'
Assert-True (
    $deviceRegressionText.Contains('function Invoke-LeanTTYSerializedUiTest') -and
    $deviceRegressionText.Contains('[Threading.Mutex]::new') -and
    $deviceRegressionText.Contains('$mutex.WaitOne(60000)')
) 'UiTest operations are not serialized across concurrent device harness processes'
Assert-True (
    $deviceRegressionText -notmatch 'shell\s+run-as\s+com\.leantty\.app' -and
    $deviceRegressionText -match 'shell\s+-b\s+com\.leantty\.app'
) 'Device key-state inspection does not use the HarmonyOS bundle shell'

$clearInputParameters = (Get-Command Clear-LeanTTYDeviceInput).Parameters.Keys
$clearInputSource = (Get-Command Clear-LeanTTYDeviceInput).Definition
Assert-True (
    $clearInputParameters -notcontains 'LayoutPath' -and
    $clearInputSource.Contains('Invoke-LeanTTYDeviceCtrlC') -and
    -not $clearInputSource.Contains('Get-LeanTTYTerminalInputText')
) 'Device input cleanup still accepts the non-authoritative ArkWeb layout readback'

& {
    $script:ctrlCCount = 0
    function Invoke-LeanTTYDeviceCtrlC {
        param($Hdc, $Target)
        $script:ctrlCCount++
    }
    Clear-LeanTTYDeviceInput -Hdc 'unused' -Target 'unused'
    Assert-True ($script:ctrlCCount -eq 1) (
        'Device input cleanup did not use the single application interrupt path'
    )
}

Assert-True (
    $null -ne (Get-Command Start-LeanTTYDeviceAwakeLease -ErrorAction SilentlyContinue) -and
    $null -ne (Get-Command Stop-LeanTTYDeviceAwakeLease -ErrorAction SilentlyContinue)
) 'Device regression has no reversible screen-timeout lease'

Assert-True (
    $null -ne (Get-Command ConvertTo-LeanTTYDevicePasswordKeyCommand -ErrorAction SilentlyContinue) -and
    $null -ne (Get-Command Assert-LeanTTYCredentialPathOutsideRepository -ErrorAction SilentlyContinue) -and
    $null -ne (Get-Command Start-LeanTTYRegressionApp -ErrorAction SilentlyContinue) -and
    $null -ne (Get-Command Wait-LeanTTYTerminalInputLayout -ErrorAction SilentlyContinue)
) 'Device regression has no conditional local-credential unlock helpers'
$passwordKeyCommand = ConvertTo-LeanTTYDevicePasswordKeyCommand -Password 'abc'
Assert-True (
    $passwordKeyCommand -eq (
        'uinput -K -d 2017 -u 2017 -d 2018 -u 2018 -d 2019 -u 2019 ' +
        '-d 2054 -u 2054'
    ) -and
    -not $passwordKeyCommand.Contains('abc')
) 'Device unlock command does not convert plaintext to the expected non-secret key events'
Assert-Throws -Action {
    ConvertTo-LeanTTYDevicePasswordKeyCommand -Password 'unsafe value'
} -Message 'Device unlock accepted an unsupported password alphabet'
Assert-Throws -Action {
    Assert-LeanTTYCredentialPathOutsideRepository `
        -CredentialPath (Join-Path $PSScriptRoot 'device-password.txt') `
        -RepositoryRoot (Split-Path $PSScriptRoot -Parent)
} -Message 'Device unlock accepted a credential file inside the repository'

$keyPresenceCommand = Get-Command Test-LeanTTYDeviceKeyFilesPresent -ErrorAction SilentlyContinue
Assert-True ($null -ne $keyPresenceCommand) (
    'Device cleanup has no independent app-sandbox key-file verification helper'
)
$keyEnumerationCommand = Get-Command Get-LeanTTYDeviceRegressionKeyNames -ErrorAction SilentlyContinue
Assert-True ($null -ne $keyEnumerationCommand) (
    'Authentication matrix has no bounded disposable-key enumeration helper'
)
Assert-Throws -Action {
    Test-LeanTTYDeviceKeyFilesPresent `
        -Hdc 'unused' `
        -Target 'unused' `
        -KeyName '../unsafe'
} -Message 'Device key-file verification accepted an unsafe generated-key name'

$deviceRegressionSource = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'device-regression.ps1'
) -Raw
Assert-True (
    $deviceRegressionSource.Contains(
        '-T SessionViewModel,KeyCommandService,SshClient,FileTransferClient,EntryAbility,Index'
    ) -and
    $deviceRegressionSource.Contains('-T MoshClient')
) 'Device application log capture omits authentication or window lifecycle events'

Assert-True (
    $deviceRegressionSource.Contains(
        '[ValidateRange(1, 60)][int]$TimeoutSeconds = 30'
    )
) 'Terminal focus gate does not allow a slow HarmonyOS layout capture to retry'

foreach ($scriptName in @(
    'device-regression.ps1',
    'preflight-device.ps1',
    'verify-key-passphrase-pc.ps1',
    'verify-ssh-auth-pc.ps1',
    'verify-host-identity-pc.ps1',
    'verify-terminal-search-pc.ps1',
    'verify-background-bell-notification-pc.ps1',
    'verify-background-bell-permission-pc.ps1',
    'verify-long-task-notification-pc.ps1',
    'verify-proxy-jump-pc.ps1',
    'verify-mosh-pc.ps1',
    'verify-mosh-matrix-pc.ps1'
)) {
    $scriptPath = Join-Path $PSScriptRoot $scriptName
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        throw "Device regression script is missing: $scriptName"
    }
    $content = Get-Content -LiteralPath $scriptPath -Raw
    Assert-True ($content -notmatch '3QC[0-9A-Z]{8,}') (
        "$scriptName contains a fixed physical device identifier"
    )
    if ($scriptName -eq 'verify-key-passphrase-pc.ps1') {
        Assert-True (
            $content.Contains('Device behavior harness requires a clean committed tree') -and
            $content.Contains('harness = [ordered]@{')
        ) 'Device behavior evidence is not bound to a clean committed harness'
        Assert-True (
            $content.Contains('schemaVersion = 2') -and
            $content.Contains('cleanup = [ordered]@{') -and
            $content.Contains('durationMs =')
        ) 'Device behavior evidence does not record stage timing and cleanup outcome'
        Assert-True (
            $content.Contains("'device-harness-preflight'") -and
            $content.Contains('Test-LeanTTYDeviceKeyFilesPresent') -and
            $content.Contains('Disposable key files disappeared after rejected old passphrase') -and
            $content.Contains("'failure-app-logs.txt'") -and
            $content.Contains("'[REDACTED]'")
        ) 'Device scenario does not preflight telemetry and independently verify cleanup'
        Assert-True (
            $content.Contains('Start-LeanTTYDeviceAwakeLease') -and
            $content.Contains('Stop-LeanTTYDeviceAwakeLease')
        ) 'Device scenario does not acquire and restore a screen-timeout lease'
        Assert-True (
            $content.Contains('UnlockPasswordPath') -and
            $content.Contains('Start-LeanTTYRegressionApp') -and
            $content.Contains('Wait-LeanTTYTerminalInputLayout') -and
            $content.Contains('Set-LeanTTYTerminalInputFocus') -and
            $content.Contains('deviceUnlock = $deviceUnlockResult')
        ) 'Device scenario does not record conditional local-credential unlock behavior'
    }
    if ($scriptName -eq 'verify-ssh-auth-pc.ps1') {
        Assert-True (
            $content.Contains('$harnessDirty -and -not $DiagnosticHap') -and
            $content.Contains('Assert-LeanTTYCandidateHarnessCompatibility') -and
            $content.Contains("'tools/start-ssh-auth-fixture.ps1'") -and
            $content.Contains("'tools/hdc-common.ps1'") -and
            $content.Contains('harness = [ordered]@{')
        ) 'SSH authentication evidence does not separate candidate and harness identity safely'
        Assert-True (
            $content.Contains('rport "tcp:$FixturePort"') -and
            $content.Contains('fport rm "tcp:$FixturePort" "tcp:$FixturePort"') -and
            $content.Contains('Assert-AuthControlChannels') -and
            $content.Contains('Assert-HdcTargetReady') -and
            $content.Contains('cleanup = [ordered]@{')
        ) 'SSH authentication fixture mapping is not paired with recorded cleanup'
        Assert-True (
            $content.Contains('Assert-LeanTTYLayoutExcludesValues') -and
            $content.Contains('HarmonyOS application logs exposed a temporary SSH fixture secret') -and
            $content.Contains("'failure-fixture-stderr.txt'") -and
            $content.Contains("'[REDACTED]'") -and
            -not $content.Contains('Device auth input delivery length mismatch') -and
            -not $content.Contains('Get-AuthInputEventCount') -and
            -not $content.Contains('Authentication input character was not acknowledged after three attempts') -and
            -not $content.Contains('Invoke-AcknowledgedAuthText') -and
            -not $content.Contains('Invoke-SerializedAuthText') -and
            -not $content.Contains('Invoke-SecretKeyEventText') -and
            $content.Contains('function Invoke-AuthUiText') -and
            ([regex]::Matches($content, 'Invoke-AuthUiText').Count -ge 5) -and
            -not $content.Contains("'layout-auth-text-focus-' + [Guid]::NewGuid().ToString('N') + '.json'") -and
            $content.Contains('-Hdc $hdc -Target $Target -Text $Text -InputNode $InputNode') -and
            $content.Contains('function Invoke-TemporaryFixtureAuthText') -and
            ([regex]::Matches($content, 'Invoke-TemporaryFixtureAuthText').Count -ge 6) -and
            $content.Contains("'^[a-z0-9]+$'") -and
            $content.Contains('repository-only-test-values-not-user-or-production-credentials') -and
            $content.Contains('harmony-uitest-focus-verified-inputText-runtime-generated-temporary-fixture-values') -and
            $content.Contains("method = 'harmony-uitest-text-and-raw-physical-special-keys'") -and
            $content.Contains("ordinaryTextInjection = 'harmony-uitest-focus-verified-inputText'") -and
            $content.Contains("physicalKeyInjection = 'raw-key-events-special-keys-only'") -and
            $content.Contains('Submit-FocusedDeviceCommand') -and
            $content.Contains('Submit-LeanTTYDeviceCommand') -and
            $content.Contains('-ProcessId $appPid') -and
            $content.Contains('-InputNodeProvider') -and
            -not $content.Contains("-Pattern 'ACCEPTANCE_IDLE_RESULT kind='") -and
            $content.Contains("'ltty-exit'") -and
            $content.Contains("'shell command=exit result=closed'") -and
            $content.Contains('Assert-AuthCommandStarted') -and
            $content.Contains("'[environment] Device key injection did not start the SSH command'") -and
            -not $content.Contains('SSH connect initiated:') -and
            $content.Contains('Activate-RegressionWindow') -and
            $content.Contains('function Assert-RegressionProcessUnchanged') -and
            ([regex]::Matches($content, 'Assert-RegressionProcessUnchanged -Action').Count -eq 3) -and
            $content.Contains("process identity was unavailable while `$Action") -and
            $content.Contains('Focus-ActiveCommandInput') -and
            $content.Contains('Invoke-LeanTTYDeviceClick') -and
            $content.Contains('if ($focusedInputs.Count -eq 1)') -and
            $content.Contains('return $focusedInputs[0]') -and
            $content.Contains('businessOutcomeRequired = $true') -and
            $content.Contains('fixedDelayUsedAsVerdict = $false')
        ) 'SSH authentication scenario does not enforce the layout/log secret boundary'
        Assert-True (
            $content.Contains("'terminal-key-input'") -and
            $content.Contains("Start-AuthCommand -User 'navigation'") -and
            $content.Contains("left = 'navigation input hex=1b 5b 44'") -and
            $content.Contains("right = 'navigation input hex=1b 5b 43'") -and
            $content.Contains("ctrlP = 'navigation input hex=10'") -and
            $content.Contains("ctrlC = 'navigation input hex=03'") -and
            $content.Contains("tab = 'navigation input hex=09'") -and
            $content.Contains("ctrlVPaste = 'navigation input hex=6c 65 61 6e 74 74 79")
        ) 'SSH authentication scenario does not capture terminal key bytes at the server boundary'
        Assert-True (
            $content.Contains("Wait-AuthOutputMarker -Marker 'LTTY_DIRTY:escapealt'") -and
            $content.Contains("`$alternateLine = Wait-FixtureConnectedInputSnapshot -Expected ''") -and
            $content.Contains('Alternate-screen remote line boundary was not observed') -and
            -not $content.Contains('alternateFocusReportPattern')
        ) 'SSH alternate-screen escape coverage lacks its output and fresh remote line boundary'
        Assert-True (
            $content.Contains('[string[]]$Only') -and
            $content.Contains('[string]$Group') -and
            $content.Contains("'transport-performance'") -and
            $content.Contains("'authentication-methods'") -and
            $content.Contains("'lifecycle-recovery'") -and
            $content.Contains("'pane-focus-attention'") -and
            $content.Contains('$authGroupDefinitions') -and
            $content.Contains('Group cannot be combined with -Only') -and
            $content.Contains('[switch]$DiagnosticHap') -and
            $content.Contains('[switch]$VerifyPreferencesUnchanged') -and
            $content.Contains('-DiagnosticHap requires an explicit -HapPath') -and
            $content.Contains("provenance = 'explicit-unretained-diagnostic-hap'") -and
            $content.Contains("`$runMode = if (-not `$DiagnosticHap -and `$Only.Count -eq 0)") -and
            $content.Contains("runMode = `$runMode") -and
            $content.Contains('executionGroup = $executionGroup') -and
            $content.Contains('groupManifest = $selectedGroupManifest') -and
            $content.Contains('knownHostRemovalCommandCompleted = $knownHostCleanupCompleted') -and
            $content.Contains("'layout-known-host-finally-cleanup.json'") -and
            $content.Contains("failureDomain = `$failureDomain") -and
            $content.Contains('attemptId = $attemptId') -and
            $content.Contains('resourceManifest = [ordered]@{') -and
            $content.Contains('Write-AuthLiveStatus') -and
            $content.Contains('Get-LeanTTYFixtureStageBudgetSeconds') -and
            $content.Contains('Get-LeanTTYFixtureRunSeconds') -and
            $content.Contains('$awakeLeaseMilliseconds = ($fixtureRunSeconds + 300) * 1000') -and
            $content.Contains('-TimeoutMilliseconds $awakeLeaseMilliseconds') -and
            $content.Contains('selectedStageBudgetsSeconds') -and
            $content.Contains("'password-kbdint-mixed-echo' = 300") -and
            $content.Contains("'multiround-wrong-answer-recovery' = 420") -and
            $content.Contains("'parallel-pane-authentication' = 480") -and
            $content.Contains("'diagnostic'") -and
            $content.Contains("'acceptance'")
        ) 'SSH authentication harness lacks targeted diagnostics or auditable live evidence'
        Assert-True (
            $content.Contains("`$preferencesComparisonBoundary = 'all-selected-stages'") -and
            $content.Contains("`$preferencesAllowedMutation = 'none'") -and
            $content.Contains("'before-transparency-performance'") -and
            $content.Contains("'terminal-transparency-mode-restored'") -and
            $content.Contains("'preferences-unchanged-before-transparency-performance'") -and
            $content.Contains('comparisonBoundary = $preferencesComparisonBoundary') -and
            $content.Contains('allowedMutation = $preferencesAllowedMutation')
        ) 'SSH performance coverage can misclassify restored transparency as a Preferences change'
        $groupDefinitionStart = $content.IndexOf('$authGroupDefinitions = [ordered]@{')
        $groupDefinitionEnd = $content.IndexOf('$availableStages = @(', $groupDefinitionStart)
        Assert-True (
            $groupDefinitionStart -ge 0 -and $groupDefinitionEnd -gt $groupDefinitionStart
        ) 'SSH group definition boundary could not be inspected'
        $groupDefinitionText = $content.Substring(
            $groupDefinitionStart,
            $groupDefinitionEnd - $groupDefinitionStart
        )
        foreach ($groupedStage in @(
                'password-success',
                'ssh-diagnostics',
                'terminal-key-input',
                'transport-main-path',
                'performance-matrix',
                'bell-attention',
                'password-kbdint-mixed-echo',
                'multiround-wrong-answer-recovery',
                'publickey-unencrypted',
                'publickey-then-password',
                'publickey-then-keyboard-interactive',
                'keyboard-interactive-zero-prompt',
                'unsupported-method-error-and-recovery',
                'ctrl-c-authentication-cancellation-and-recovery',
                'pane-close-during-hidden-prompt-and-recovery',
                'publickey-encrypted-passphrase',
                'parallel-pane-authentication',
                'minimize-restore-hidden-prompt',
                'process-stop-during-hidden-prompt-cleanup'
            )) {
            Assert-True (
                ([regex]::Matches(
                    $groupDefinitionText,
                    [regex]::Escape("'$groupedStage'")
                )).Count -eq 1
            ) "SSH public stage is missing from or duplicated across groups: $groupedStage"
        }
        foreach ($internalStage in @(
                'generated-disposable-auth-key',
                'encrypted-disposable-auth-key',
                'deleted-disposable-auth-key'
            )) {
            Assert-True (-not $groupDefinitionText.Contains("'$internalStage'")) (
                "SSH internal dependency was incorrectly promoted to a public group stage: $internalStage"
            )
        }
        Assert-True (
            $content.Contains('Get-LeanTTYPreferencesDigest') -and
            $content.Contains('sha256sum $preferencesPath') -and
            $content.Contains('contentReadOrExported = $false') -and
            $content.Contains('digestPersisted = $false') -and
            $content.Contains('unchanged = $preferencesDigestUnchanged') -and
            -not $content.Contains('beforeDigest =') -and
            -not $content.Contains('afterDigest =')
        ) 'SSH authentication harness does not compare Preferences safely without persisting digests'
        Assert-True (
            $content.Contains("'password-success'") -and
            $content.Contains("'password-then-keyboard-interactive-mixed-echo'") -and
            $content.Contains("'keyboard-interactive-multi-round-wrong-answer-recovery'") -and
            $content.Contains(
                "Wait-AuthLog -Pattern 'native control event: error:target:authentication:auth'"
            ) -and
            -not $content.Contains(
                "Wait-AuthLog -Pattern 'native control event: error::authentication:auth'"
            ) -and
            $content.Contains("'publickey-unencrypted'") -and
            $content.Contains("'publickey-then-password'") -and
            $content.Contains("'publickey-then-keyboard-interactive'") -and
            $content.Contains("'keyboard-interactive-zero-prompt'") -and
            $content.Contains("'unsupported-method-error-and-recovery'") -and
            $content.Contains(
                "Wait-AuthLog -Pattern 'SSH error: target:no supported authentication method is available'"
            ) -and
            -not $content.Contains(
                "Wait-AuthLog -Pattern 'SSH error: no supported authentication method is available'"
            ) -and
            $content.Contains("'ctrl-c-authentication-cancellation-and-recovery'") -and
            $content.Contains('Invoke-LeanTTYDeviceCtrlC') -and
            $content.Contains("'pane-close-during-hidden-prompt-and-recovery'") -and
            $content.Contains("-ButtonText 'Close pane'") -and
            $content.Contains("'layout-close-auth-single-pane.json'") -and
            -not $content.Contains("'-RunSeconds', '1200'") -and
            $content.Contains("'publickey-encrypted-passphrase'") -and
            $content.Contains("'parallel-pane-independent-authentication'") -and
            $content.Contains("'minimize-restore-hidden-answer-continuity'") -and
            $content.Contains("'EnhanceMinimizeBtn'") -and
            $content.Contains('LeanTTY active-pane close button was not found') -and
            -not $content.Contains("Invoke-AuthShortcut -Action 'close-pane'") -and
            $content.Contains('LeanTTY process changed while $Action') -and
            $content.Contains("'process-stop-during-hidden-prompt-cleanup'") -and
            $content.Contains("'tools/verify-terminal-search-pc.ps1'") -and
            $content.Contains("'docs/design/terminal-search.md'") -and
            $content.Contains("'docs/next-work.md'") -and
            $content.Contains('Submit-LeanTTYDeviceCommand') -and
            -not $content.Contains('for ($commandAttempt = 1; $commandAttempt -le 3; $commandAttempt++)') -and
            -not $content.Contains("-Pattern 'ACCEPTANCE_IDLE_RESULT kind='")
        ) 'SSH authentication scenario does not declare its bounded physical coverage'
        Assert-True (
            $content.Contains("'transport-main-path'") -and
            $content.Contains("'ltty-input-check russhmain'") -and
            $content.Contains("'ltty-paste-prepare russhmain 1048576'") -and
            ([regex]::Matches($content, 'Submit-ConnectedInputUntilFixtureEvent').Count -ge 8) -and
            $content.Contains("Wait-AuthOutputMarker -Marker 'LTTY_PASTE_READY:russhmain:1048576'") -and
            $content.Contains("'connected-input-snapshot'") -and
            $content.Contains('function Wait-FixtureConnectedInputSnapshot') -and
            $content.Contains('for ($inputAttempt = 1; $inputAttempt -le 3; $inputAttempt++)') -and
            $content.Contains('connected input state=cleared') -and
            $content.Contains('Connected input could not be made exact before Enter') -and
            $content.Contains('Connected input outcome is unknown; the scenario must be restarted') -and
            $content.Contains('Expected terminal output marker was not observed') -and
            $content.Contains("Submit-ConnectedInput -Text 'ltty-paste-prepare russhmain 1048576'") -and
            -not $content.Contains('OSC 52 clipboard write success=') -and
            -not $content.Contains('Clipboard paste ok,') -and
            $content.Contains("'D: 1048576 chars'") -and
            $content.Contains("'paste case=russhmain bytes=1048576 result=matched'") -and
            $content.Contains("'uinput -K -d 2072 -d 2038 -u 2038 -u 2072'") -and
            $content.Contains("Invoke-AuthPerfSample -CaseId 'russhmain'") -and
            $content.Contains('NATIVE_OUTPUT_PROBE case=') -and
            $content.Contains("'resize cols=\d+ rows=\d+'") -and
            $content.Contains("'ltty-input-check afterperf'") -and
            $content.Contains("'input case=afterperf result=matched'") -and
            $content.Contains("'layout-transport-close-connected.json'") -and
            $content.Contains("'layout-transport-close-connected-dialog.json'") -and
            $content.Contains("'SSH closed, exitCode=-1'") -and
            $content.Contains("'ltty-input-check reconnect'") -and
            $content.Contains("'input case=reconnect result=matched'") -and
            $content.Contains('Wait-AuthPaneCount -Count 1')
        ) 'SSH transport main-path coverage is incomplete'
        Assert-True (
            $content.Contains("Wait-AuthLog -Pattern 'SSH error: target:SSH keepalive timed out'") -and
            -not $content.Contains("Wait-AuthLog -Pattern 'SSH error: SSH keepalive timed out'")
        ) 'SSH server-alive oracle does not match the structured target-layer error label'
        Assert-True (
            $content.Contains("'performance-matrix'") -and
            $content.Contains("@('Off', 'Low', 'Medium', 'High', 'Extreme')") -and
            $content.Contains("'Maximum' = 'Extreme'; '最高' = 'Extreme'") -and
            $content.Contains('Invoke-AuthPerfSample -CaseId $caseId') -and
            $content.Contains("' lines=12000 width=80 bytes=\d+ state=prepared'") -and
            $content.Contains('PERF prepare outcome is unknown') -and
            $content.Contains('PERF run outcome is unknown') -and
            $content.Contains('commandAttempts') -and
            $content.Contains('renderSamples = @($renderSamples)') -and
            $content.Contains('memorySamples = @($memorySamples)') -and
            $content.Contains("hidumper -s 10 -a 'hitchs app0'") -and
            $content.Contains("hidumper -s 10 -a 'gles'") -and
            $content.Contains('Get-AuthTransparencyMode') -and
            $content.Contains('-Mode $performanceInitialTransparencyMode') -and
            $content.Contains('$performanceTransparencyRestored = $true') -and
            -not $content.Contains('$screenshotName = "performance-$modeSlug.png"') -and
            -not $content.Contains('screenshot = $screenshotName') -and
            $content.Contains('performanceMatrix = $performanceEvidence')
        ) 'SSH five-mode performance matrix is incomplete'
        Assert-True (
            $content.Contains("'bell-attention'") -and
            $content.Contains("'ltty-bell active01 500'") -and
            $content.Contains("'ltty-bell inactive01 5000'") -and
            $content.Contains("'ltty-bell split01 5000'") -and
            $content.Contains("'ltty-bell flood01 5000'") -and
            $content.Contains("'ltty-bell flood02 5000'") -and
            $content.Contains('Repeated BEL did not coalesce to one pending attention transition') -and
            $content.Contains('bellAttention = $bellEvidence')
        ) 'SSH BEL attention matrix is incomplete'
    }
    if ($scriptName -eq 'verify-terminal-search-pc.ps1') {
        Assert-True (
            $content.Contains('Terminal-search device harness requires a clean committed tree') -and
            $content.Contains("'open-close-focus'") -and
            $content.Contains("'ascii-query-navigation'") -and
            $content.Contains("'pane-tab-ownership'") -and
            $content.Contains("'warm-tab-eviction'") -and
            $content.Contains("'window-renderer-lifecycle'") -and
            $content.Contains("'uitest uiInput keyEvent 2072 2045 2022'") -and
            -not $content.Contains("'uitest uiInput keyEvent 2047 2054'") -and
            $content.Contains("'^native-search-prev-pane-[0-9]+-[0-9]+$'") -and
            $content.Contains('-RequireSearchInputFocus $false') -and
            -not $content.Contains("'uitest uiInput keyEvent 2072 2017'") -and
            $content.Contains('Clear-TerminalSearchQuery -CharacterCount $query.Length') -and
            $content.Contains('Clear-TerminalSearchQuery -CharacterCount $missingQuery.Length') -and
            $content.Contains("'LEANTTY_NO_RESULT_ZXQVK'") -and
            $content.Contains("'^native-search-pane-[0-9]+-[0-9]+$'") -and
            $content.Contains('[AllowEmptyString()]') -and
            $content.Contains("'^0/0$'") -and
            $content.Contains('wrappedForward = $true') -and
            $content.Contains('wrappedBackward = $true') -and
            $content.Contains("'layout-warm-evicted.json'") -and
            $content.Contains("'Terminal ready, terminal output recovered'") -and
            $content.Contains("'Acceptance: Rebuild Renderer'") -and
            $content.Contains("'EnhanceMinimizeBtn'") -and
            $content.Contains("Invoke-LocalTerminalCommand -Command 'help mosh'") -and
            $content.Contains('function Invoke-LocalTerminalCommand') -and
            $content.Contains('Get-LeanTTYActiveTerminalInputNodes -Layout $layout') -and
            $content.Contains('$contentTop = Get-LeanTTYTerminalContentTop -Layout $Layout') -and
            -not $content.Contains('[int]$Matches.top -ge 100') -and
            $content.Contains('Submit-LeanTTYDeviceCommand') -and
            $content.Contains('-ProcessId $appPid') -and
            $content.Contains('-InputNodeProvider') -and
            $content.Contains("elseif (`$failure -match '^\[unknown\]')") -and
            -not $content.Contains('$actualBuffer -ceq $Command') -and
            $content.Contains('rightPaneRejectedLeftScrollbackQuery = $true') -and
            $content.Contains('secondTabRejectedFirstTabScrollbackQuery = $true') -and
            $content.Contains("'pane-scroll-after-focus-switch.png'") -and
            $content.Contains("'tab-scroll-first-return.png'") -and
            $content.Contains('singleTabSinglePaneRestored = $workspaceRestored') -and
            $content.Contains('$activePaneIds') -and
            $content.Contains('[Collections.Generic.List[string]]::new()') -and
            $content.Contains('$activePaneIds.Count') -and
            $content.Contains('Get-LeanTTYActiveTerminalInputNodes') -and
            $content.Contains('Get-LeanTTYActiveTerminalSurfaceNodes') -and
            $content.Contains('-RequireTerminalFocus $false') -and
            $content.Contains('terminalFocusRestoredByCommandSubmit') -and
            $content.Contains('does not ') -and
            $content.Contains('satisfy physical-keyboard or Chinese/English IME acceptance') -and
            $content.Contains("'layout-search-open.json'") -and
            $content.Contains("'layout-search-closed.json'") -and
            $content.Contains("'explicit-unretained-diagnostic-hap'") -and
            $content.Contains('$harnessDirty -and -not $DiagnosticHap') -and
            $content.Contains('gitDirty = $harnessDirty') -and
            $content.Contains('Assert-LeanTTYCandidateHarnessCompatibility') -and
            $content.Contains("'tools/start-ssh-auth-fixture.ps1'") -and
            $content.Contains("'retained-verified-candidate'") -and
            $content.Contains('Save-LeanTTYVerifiedCandidate') -and
            $content.Contains('harness = [ordered]@{') -and
            $content.Contains('failureDomain = $failureDomain') -and
            $content.Contains('transientSearchClosed = $searchClosed') -and
            $content.Contains('Stop-LeanTTYDeviceAwakeLease')
        ) 'Terminal-search physical scenario lacks identity, product routing, evidence, or cleanup'

        $tokens = $null
        $parseErrors = $null
        $syntaxTree = [Management.Automation.Language.Parser]::ParseFile(
            $scriptPath,
            [ref]$tokens,
            [ref]$parseErrors
        )
        Assert-True ($parseErrors.Count -eq 0) 'Terminal-search harness could not be parsed for layout tests'
        foreach ($functionName in @(
            'Get-LeanTTYTerminalContentTop',
            'Get-LeanTTYTabNodes',
            'Get-LeanTTYActiveTerminalSurfaceNodes'
        )) {
            $functionDefinition = $syntaxTree.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq $functionName
            }, $true) | Select-Object -First 1
            Assert-True ($null -ne $functionDefinition) "Missing terminal-search helper: $functionName"
            Invoke-Expression $functionDefinition.Extent.Text
        }
        $scaledChromeLayout = @'
{
  "attributes": {"type":"root","bounds":"[0,0][2926,1926]"},
  "children": [
    {"attributes":{"type":"Stack","clickable":"true","description":"active","bounds":"[143,67][470,135]"},"children":[]},
    {"attributes":{"type":"Stack","clickable":"true","description":"content decoy","bounds":"[143,300][470,368]"},"children":[]},
    {"attributes":{"type":"XComponent","visible":"true","id":"native-terminal-pane-1-1","bounds":"[121,135][2926,1926]"},"children":[]}
  ]
}
'@ | ConvertFrom-Json -Depth 10
        $scaledTabs = @(Get-LeanTTYTabNodes -Layout $scaledChromeLayout)
        Assert-True (
            $scaledTabs.Count -eq 1 -and
            [string]$scaledTabs[0].attributes.description -eq 'active'
        ) 'Terminal-search harness did not derive the scaled Chrome boundary from terminal content'

        $rendererRebuiltLayout = @'
{
  "attributes": {"type":"root","bounds":"[0,0][2926,1926]"},
  "children": [
    {"attributes":{"type":"__Common__","opacity":"1.000000","zIndex":"0","bounds":"[2584,67][2645,128]"},"children":[]},
    {"attributes":{"type":"__Common__","opacity":"1.000000","zIndex":"1","bounds":"[121,135][2926,1926]"},"children":[
      {"attributes":{"type":"XComponent","visible":"true","id":"native-terminal-pane-1-1","bounds":"[121,135][2926,1926]"},"children":[]}
    ]},
    {"attributes":{"type":"__Common__","opacity":"0.000000","zIndex":"0","bounds":"[121,135][2926,1926]"},"children":[
      {"attributes":{"type":"XComponent","visible":"true","id":"native-terminal-pane-1-1","bounds":"[121,135][2926,1926]"},"children":[]}
    ]}
  ]
}
'@ | ConvertFrom-Json -Depth 10
        $activeSurfaces = @(Get-LeanTTYActiveTerminalSurfaceNodes -Layout $rendererRebuiltLayout)
        Assert-True (
            $activeSurfaces.Count -eq 1 -and
            [string]$activeSurfaces[0].attributes.id -eq 'native-terminal-pane-1-1'
        ) 'Renderer-rebuilt layout did not retain one observable active terminal Surface'
    }
    if ($scriptName -eq 'verify-proxy-jump-pc.ps1') {
        Assert-True (
            $content.Contains('function Submit-ProxyCommand') -and
            $content.Contains('Submit-LeanTTYDeviceCommand') -and
            $content.Contains('-ProcessId $script:proxyAppPid') -and
            $content.Contains('-InputNodeProvider') -and
            $content.Contains('function Get-ProxyCommandInputText') -and
            $content.Contains('function Wait-ProxyCommandInputText') -and
            $content.Contains('Get-LeanTTYTerminalInputNodes -Layout $Layout') -and
            -not $content.Contains("-Pattern 'ACCEPTANCE_IDLE_RESULT kind='") -and
            -not $content.Contains('$actualBuffer -ceq $Command') -and
            $content.Contains("[string]`$HapPath = ''") -and
            $content.Contains('[IO.Path]::GetFullPath($HapPath)') -and
            $content.Contains('ProxyJump verification requires a signed HAP') -and
            $content.Contains('-HapPath $selectedHapPath') -and
            $content.Contains('$script:proxyHapPath = $selectedHapPath') -and
            $content.Contains('[ValidateRange(0, 3600)][int]$ServerAliveIntervalSeconds') -and
            $content.Contains('sameConnectionInputObserved = $true') -and
            $content.Contains('deviceTimeoutObserved = $false')
        ) 'ProxyJump physical scenario can submit an unverified command buffer'
    }
}

$moshParser = Get-Content -LiteralPath (
    Join-Path $repoRoot 'entry\src\main\ets\model\command\CommandParser.ets'
) -Raw
$moshClient = Get-Content -LiteralPath (
    Join-Path $repoRoot 'entry\src\main\ets\model\mosh\MoshClient.ets'
) -Raw
$moshSessionViewModel = Get-Content -LiteralPath (
    Join-Path $repoRoot 'entry\src\main\ets\viewmodel\SessionViewModel.ets'
) -Raw
$moshPaneRuntime = Get-Content -LiteralPath (
    Join-Path $repoRoot 'entry\src\main\ets\viewmodel\PaneRuntime.ets'
) -Raw
$moshTerminalSurface = Get-Content -LiteralPath (
    Join-Path $repoRoot 'entry\src\main\ets\model\terminal\TerminalSurfaceController.ets'
) -Raw
$moshIndexPage = Get-Content -LiteralPath (
    Join-Path $repoRoot 'entry\src\main\ets\pages\Index.ets'
) -Raw
$moshNativeTypes = Get-Content -LiteralPath (
    Join-Path $repoRoot 'entry\src\main\cpp\types\libleantty_ssh\index.d.ts'
) -Raw
$moshNative = Get-Content -LiteralPath (
    Join-Path $repoRoot 'leantty_ssh\src\lib.rs'
) -Raw
$moshManifest = Get-Content -LiteralPath (
    Join-Path $repoRoot 'leantty_ssh\Cargo.toml'
) -Raw
$acceptanceSource = Get-Content -LiteralPath (
    Join-Path $repoRoot 'tools\acceptance-source.ps1'
) -Raw
foreach ($predictionContract in @(
    @{ Source = $moshParser; Text = 'MoshPredictionMode.ADAPTIVE' },
    @{ Source = $moshParser; Text = "word.startsWith('--predict=')" },
    @{ Source = $moshParser; Text = 'Mosh prediction mode must be adaptive, always or never' },
    @{ Source = $moshClient; Text = 'predictionMode: MoshPredictionMode' },
    @{ Source = $moshClient; Text = 'predictionMode,' },
    @{ Source = $moshSessionViewModel; Text = 'predictionMode: MoshPredictionMode = this.moshPredictionMode' },
    @{ Source = $moshSessionViewModel; Text = 'result.moshServerPath, result.moshPredictionMode' },
    @{ Source = $moshNativeTypes; Text = 'predictionMode: string' },
    @{ Source = $moshNative; Text = 'connect_with_prediction_mode' },
    @{ Source = $moshNative; Text = 'mosh_prediction_mode(&prediction_mode)' },
    @{ Source = $moshManifest; Text = 'tag = "v0.1.1"' },
    @{ Source = $moshManifest; Text = 'version = "=0.1.1"' },
    @{ Source = $acceptanceSource; Text = 'ACCEPTANCE_MOSH_OUTPUT mode=' },
    @{ Source = ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'native-page-acceptance-source.ps1'))); Text = 'ACCEPTANCE_NATIVE_WRITE_CONSUMED pane=' },
    @{ Source = $moshIndexPage; Text = 'runtime.viewModel.getMode() === TerminalMode.IDLE' },
    @{ Source = $moshSessionViewModel; Text = 'if (this.requestRuntimeRecoveryBeforeIdleInput(sourceSurface))' },
    @{ Source = $moshSessionViewModel; Text = '!surface.ownsMoshSessionPage()' },
    @{ Source = $moshTerminalSurface; Text = 'return this.nativeMoshPage' },
    @{ Source = $moshIndexPage; Text = 'runtime.surface.ownsMoshSessionPage()' },
    @{ Source = $moshIndexPage; Text = 'this.recoverReclaimedRuntimeSessions(requestedPaneId)' },
    @{ Source = $moshSessionViewModel; Text = 'this.terminalResetPending' },
    @{ Source = $moshPaneRuntime; Text = 'this.surface.setPaneIdentity(id)' },
    @{ Source = $moshSessionViewModel; Text = 'Terminal input withheld for runtime recovery' },
    @{ Source = $moshIndexPage; Text = "@Watch('onRuntimeRecoveryRequested')" },
    @{ Source = $acceptanceSource; Text = "AppStorage.setOrCreate('activeRemotePaneIds', '')" }
)) {
    Assert-True ($predictionContract.Source.Contains($predictionContract.Text)) (
        "Mosh prediction pass-through omitted contract: $($predictionContract.Text)"
    )
}

$moshVerifierPath = Join-Path $PSScriptRoot 'verify-mosh-pc.ps1'
$moshVerifier = Get-Content -LiteralPath $moshVerifierPath -Raw
$moshVerifierTokens = $null
$moshVerifierParseErrors = $null
$moshVerifierAst = [Management.Automation.Language.Parser]::ParseFile(
    $moshVerifierPath,
    [ref]$moshVerifierTokens,
    [ref]$moshVerifierParseErrors
)
Assert-True ($moshVerifierParseErrors.Count -eq 0) 'Mosh verifier could not be parsed for helper tests'
& {
    # Run the actual focus, input, retry and Enter chain. Only device/PTY I/O
    # is replaced; the shared native-owner predicate remains real.
    foreach ($name in @('Focus-ActiveTerminalInput', 'Submit-MoshInput')) {
        $definition = $moshVerifierAst.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true)
        Invoke-Expression $definition.Extent.Text
    }
    function New-MoshOwnerTestLayout {
        $changed = $state.reads -ge $case.at
        $path = if ($changed -and $case.change -in @('reindex','virtual')) { 'ROOT1,1,0' } else { 'ROOT1,0,0' }
        $id = if ($changed -and $case.change -eq 'replacement') { 'other-component' } else { 'owner-component' }
        $windowId = if ($changed -and $case.change -eq 'window') { '2' } else { '1' }
        if ($changed -and $case.change -eq 'missing') { $id = '' }
        $leaf = [pscustomobject]@{ attributes = @{
            type = $(if ($changed -and $case.change -eq 'nonterminal') { 'TextInput' } else { 'XComponent' })
            id = 'native-terminal-pane-1-1'; focused = 'true'; hostWindowId = $windowId
            hierarchy = $path; accessibilityId = $id; bounds = '[10,10][30,30]'
        }; children = @() }
        $children = @([pscustomobject]@{ attributes=@{type='Stack'}; children=@($leaf) })
        if ($changed -and $case.change -in @('duplicate','two-focused','peer')) {
            $children += [pscustomobject]@{ attributes=@{type='Stack'}; children=@([pscustomobject]@{attributes=@{
                type='XComponent'; id=$(if ($case.change -eq 'duplicate') { 'native-terminal-pane-1-1' } else { 'native-terminal-pane-1-2' })
                accessibilityId=$(if ($case.change -eq 'duplicate') { $id } else { 'peer-component' })
                focused=$(if ($case.change -eq 'two-focused') { 'true' } else { 'false' })
                hostWindowId=$windowId; hierarchy='ROOT1,3,0'; bounds='[40,10][60,30]'
            };children=@()}) }
        }
        return [pscustomobject]@{ attributes=@{};children=$children }
    }
    $cases = @(
        @{ change='stable'; at=1; text=1; enter=1; cancel=0 },
        @{ change='reindex'; at=2; text=1; enter=1; cancel=0 },
        @{ change='reindex'; at=3; text=1; enter=1; cancel=0 },
        @{ change='reindex'; at=4; text=1; enter=1; cancel=0 },
        @{ change='virtual'; at=2; text=1; enter=1; cancel=0 },
        @{ change='virtual'; at=4; text=1; enter=1; cancel=0 },
        @{ change='peer'; at=1; text=1; enter=1; cancel=0 },
        @{ change='replacement'; at=2; text=0; enter=0; cancel=0 },
        @{ change='replacement'; at=3; text=1; enter=0; cancel=0 },
        @{ change='replacement'; at=4; text=1; enter=0; cancel=0 },
        @{ change='window'; at=4; text=1; enter=0; cancel=0 },
        @{ change='missing'; at=1; text=0; enter=0; cancel=0 },
        @{ change='missing'; at=4; text=1; enter=0; cancel=0 },
        @{ change='duplicate'; at=1; text=0; enter=0; cancel=0 },
        @{ change='duplicate'; at=4; text=1; enter=0; cancel=0 },
        @{ change='nonterminal'; at=1; text=0; enter=0; cancel=0 },
        @{ change='two-focused'; at=4; text=1; enter=0; cancel=0 },
        @{ change='reindex'; at=5; retry='once'; text=2; enter=1; cancel=1 },
        @{ change='replacement'; at=5; retry='once'; text=1; enter=0; cancel=1 },
        @{ change='stable'; at=1; retry='exhausted'; text=3; enter=0; cancel=2 },
        @{ change='stable'; at=1; retry='clear-failed'; text=1; enter=0; cancel=1 },
        @{ change='stable'; at=1; retry='local-prompt'; text=1; enter=0; cancel=0 }
    )
    foreach ($case in $cases) {
        $state = @{ reads=0; text=0; enter=0; cancel=0; snapshots=0 }
        $hdc = 'synthetic'; $targetId = 'synthetic'; $appPid = 1
        $EvidenceDirectory = [IO.Path]::GetTempPath(); $activeMoshControlDirectory = 'synthetic'
        $connectedInputObservations = [Collections.Generic.List[object]]::new()
        function Get-LeanTTYDeviceLayout {
            $state.reads++
            if ($state.reads -gt 12) { throw 'Synthetic layout sequence exhausted' }
            New-MoshOwnerTestLayout
        }
        function Get-HdcUiLayout { Get-LeanTTYDeviceLayout }
        function Invoke-LeanTTYSerializedUiTest { param($Action) & $Action }
        function Invoke-HdcChecked { $state.text++ }
        function Invoke-LeanTTYDeviceKey { $state.enter++ }
        function Invoke-LeanTTYDeviceCtrlC { $state.cancel++ }
        function Wait-MoshInputSnapshot {
            param($Expected)
            $state.snapshots++
            $mismatch = ($case.retry -and $state.snapshots -eq 1) -or
                ($case.retry -eq 'exhausted' -and $Expected -ne '') -or
                ($case.retry -eq 'clear-failed' -and $state.snapshots -eq 2)
            return @{ observed=$true; value=$(if ($mismatch) { 'wrong' } else { $Expected }) }
        }
        function Get-LeanTTYAppLogs { return '' }
        function Get-LeanTTYAcceptanceIdleInputState {
            if ($case.retry -eq 'local-prompt') { return @{ input='public-owner-probe' } }
            return $null
        }
        $failure = $null
        try { Submit-MoshInput -Text 'public-owner-probe' } catch { $failure = $_.Exception }
        $label = "$($case.change) at layout $($case.at), retry=$($case.retry)"
        Assert-True (($null -eq $failure) -eq ($case.enter -eq 1)) "Mosh native owner verdict failed: $label"
        Assert-True ($state.text -eq $case.text -and $state.enter -eq $case.enter -and
            $state.cancel -eq $case.cancel) "Mosh sent an unsafe input, retry or Enter: $label"
        Assert-True ($connectedInputObservations.Count -eq 1 -and
            $connectedInputObservations[0].enterCount -eq $case.enter -and
            $connectedInputObservations[0].result -eq $(if ($case.enter) { 'passed' } else { 'failed' })) (
            "Mosh command observation lost its verdict: $label"
        )
        if ($case.enter -eq 1) {
            Assert-True ($state.reads -eq (4 * $case.text)) "Owner matching added layout captures: $label"
        }
    }
    foreach ($change in @('stable', 'reindex', 'virtual', 'replacement')) {
        $case = @{ change=$change; at=2 }
        $state = @{ reads=0; focus=0 }
        function Get-LeanTTYDeviceLayout {
            $state.reads++
            $layout = New-MoshOwnerTestLayout
            if ($state.reads -eq 1) { $layout.children[0].children[0].attributes.focused = 'false' }
            return $layout
        }
        function Set-LeanTTYTerminalInputFocus { $state.focus++; Get-LeanTTYDeviceLayout }
        $failure = $null; $capture = $null
        try { $capture = Focus-ActiveTerminalInput -Name 'synthetic-focus.json' -IncludeLayout }
        catch { $failure = $_.Exception }
        Assert-True (($null -eq $failure) -eq ($change -ne 'replacement')) "Focus owner was not preserved: $change"
        if ($null -ne $capture) {
            $focused = @(Get-LeanTTYFocusedTextInputNodes -Layout $capture.layout)
            Assert-True ($focused.Count -eq 1 -and [object]::ReferenceEquals($focused[0], $capture.node)) (
                "Focus returned a stale pre-click node: $change"
            )
        }
        Assert-True ($state.reads -eq 2 -and $state.focus -eq 1) 'Focus capture added a read or a click'
    }
}
& {
    $timestampDefinition = $moshVerifierAst.FindAll({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'ConvertFrom-MoshHilogTimestamp'
    }, $true) | Select-Object -First 1
    Invoke-Expression $timestampDefinition.Extent.Text
    $definition = $moshVerifierAst.FindAll({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Get-MoshInputRejectionObservation'
    }, $true) | Select-Object -First 1
    Invoke-Expression $definition.Extent.Text
    $logs = @('09-06 23:03:16.554 6549 6549 I tag: ACCEPTANCE_MOSH_INPUT_REJECTION receivedBytes=42',
        '09-06 23:03:16.555 6549 6549 I tag: ACCEPTANCE_MOSH_INPUT_REJECTION kind=full',
        '09-06 23:03:16.557 6549 6549 I tag: ACCEPTANCE_NATIVE_WRITE_CONSUMED pane=pane-1-1 sequence=8 owner=17 bytes=42',
        '09-06 23:03:16.597 6549 6549 I tag: ACCEPTANCE_NATIVE_PAGE pane=pane-1-1 sequence=9 action=restored page=3 cols=71 rows=36 screen=0 viewport=0 total=36 hash=0123456789abcdef') -join "`n"
    $observation = Get-MoshInputRejectionObservation -Logs $logs
    Assert-True ($observation.nativeErrorKind -ceq 'Full' -and $observation.receivedOutputBytes -eq 42 -and
        $observation.outputAcknowledgedBeforeRestore) 'Input rejection lost its actual drain observations'
    $grouped = ($logs -split "`n")[@(0, 2, 3, 1)] -join "`n"
    $observation = Get-MoshInputRejectionObservation -Logs $grouped
    Assert-True $observation.outputAcknowledgedBeforeRestore (
        'Tag-grouped logs must use device event time, not concatenated file order'
    )
    foreach ($invalid in @('', $logs.Replace('kind=full', 'kind=unexpected'),
        $logs.Replace('bytes=42', 'bytes=0'), $logs.Replace('receivedBytes=42', 'receivedBytes=0'),
        ($logs + "`n" + $logs),
        $logs.Replace('23:03:16.557', '23:03:16.598'),
        $logs.Replace('23:03:16.557', '23:03:16.553'),
        $logs.Replace('23:03:16.555', '23:03:16.553'),
        $logs.Replace('23:03:16.555', '23:03:16.598'),
        $logs.Replace('09-06 23:03:16.555', 'missing timestamp'),
        $logs.Replace('23:03:16.597', '23:03:16.557'),
        ($logs + "`nACCEPTANCE_MOSH_INPUT_REJECTION state=precondition-failed"))) {
        Assert-Throws { Get-MoshInputRejectionObservation -Logs $invalid } (
            'Input rejection accepted missing, ambiguous, synthetic or out-of-order evidence'
        )
    }
}
& (Join-Path $PSScriptRoot 'test-native-mosh-evidence.ps1')
& {
    $focusFunction = $moshVerifierAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Focus-MoshPane'
    }, $true) | Select-Object -First 1
    Invoke-Expression $focusFunction.Extent.Text
    $paneLayout = [pscustomobject]@{ attributes=@{}; children=@(
        foreach ($number in 1..2) {
            [pscustomobject]@{ attributes=@{type='Stack'};children=@([pscustomobject]@{attributes=@{
                type='XComponent';id="native-terminal-pane-1-$number";accessibilityId="component-$number"
                hostWindowId='1';focused='false';bounds='[10,10][30,30]'
            };children=@()}) }
        }
    ) }
    $paneLayout.children[1].children[0].attributes.bounds = '[1541,749][1560,790]'
    $script:paneFocusLayoutsRead = 0
    $script:paneFocusShortcuts = [Collections.Generic.List[string]]::new()
    function Invoke-MoshFocusHdc {
        $script:paneFocusShortcuts.Add(($args -join ' '))
        $global:LASTEXITCODE = 0
    }
    function Get-LeanTTYDeviceLayout {
        param($Hdc, $Target, $LocalPath)
        $script:paneFocusLayoutsRead++
        if ($script:paneFocusLayoutsRead -gt 1) {
            throw 'Pane focus did not accept the first correct owner snapshot'
        }
        return $paneLayout
    }
    $hdc = 'Invoke-MoshFocusHdc'
    $targetId = 'unused'
    $EvidenceDirectory = 'unused'
    foreach ($side in @('left', 'right')) {
        $leftFocused = $side -ceq 'left'
        $paneLayout.children[0].children[0].attributes.focused = $leftFocused.ToString().ToLowerInvariant()
        $paneLayout.children[1].children[0].attributes.focused = (-not $leftFocused).ToString().ToLowerInvariant()
        $script:paneFocusLayoutsRead = 0
        Focus-MoshPane -Side $side -Name 'owner-order'
        Assert-True ($script:paneFocusLayoutsRead -eq 1) 'Mosh Pane focus retried a correct snapshot'
    }
    Assert-True (
        $script:paneFocusShortcuts.Count -eq 2 -and
        $script:paneFocusShortcuts[0].Contains('-d 2014 -u 2014') -and
        $script:paneFocusShortcuts[1].Contains('-d 2015 -u 2015')
    ) 'Mosh Pane focus did not send exactly one correct shortcut per side'
    $paneLayout.children[0].children[0].attributes.focused = 'true'
    $paneLayout.children[1].children[0].attributes.focused = 'true'
    $script:paneFocusLayoutsRead = 0
    Assert-Throws -Action {
        Focus-MoshPane -Side 'left' -Name 'ambiguous-focus'
    } -Message 'Mosh Pane focus accepted two focused owners'
}
foreach ($functionName in @(
    'ConvertTo-MoshIpv4Number',
    'Get-MoshEndpointRoute',
    'ConvertFrom-MoshWifiDeviceDump',
    'Get-MoshWifiToggle',
    'Get-MoshWifiPanelButton',
    'Get-MoshWifiPanelState',
    'Normalize-MoshWifiPanelClosed'
)) {
    $functionDefinition = $moshVerifierAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $functionName
    }, $true) | Select-Object -First 1
    Assert-True ($null -ne $functionDefinition) "Missing Mosh verifier helper: $functionName"
    Invoke-Expression $functionDefinition.Extent.Text
}
$connectedWifi = ConvertFrom-MoshWifiDeviceDump -Dump @'
WiFi active state: activated

WiFi connection status: connected
  Connection.ssid: saved-network
  Connection.rssi: -48

Country Code: CN
'@
Assert-True (
    $connectedWifi.active -and $connectedWifi.connected -and
    $connectedWifi.ssid -ceq 'saved-network'
) 'Mosh Wi-Fi service dump parser did not return the current connected SSID'
$disconnectedWifi = ConvertFrom-MoshWifiDeviceDump -Dump @'
WiFi active state: activated

WiFi connection status: not connected

Country Code: CN
'@
Assert-True (
    $disconnectedWifi.active -and -not $disconnectedWifi.connected -and
    [string]::IsNullOrEmpty($disconnectedWifi.ssid)
) 'Mosh Wi-Fi service dump parser did not preserve a disconnected state'
$crlfWifiDump = @(
    'WiFi active state: activated',
    '',
    'WiFi connection status: connected',
    '  Connection.ssid: saved-network',
    ''
) -join "`r`n"
$crlfWifi = ConvertFrom-MoshWifiDeviceDump -Dump $crlfWifiDump
Assert-True (
    $crlfWifi.active -and $crlfWifi.connected -and
    $crlfWifi.ssid -ceq 'saved-network'
) 'Mosh Wi-Fi service dump parser rejected CRLF output'
Assert-Throws -Action {
    ConvertFrom-MoshWifiDeviceDump -Dump @'
WiFi active state: activated
WiFi connection status: connected
  Connection.ssid: first
  Connection.ssid: second
'@ | Out-Null
} -Message 'Mosh Wi-Fi service dump parser accepted an ambiguous SSID'
$wifiPanelOpenLayout = @'
{
  "attributes": {"id":"","type":"root","visible":"true","clickable":"false"},
  "children": [
    {"attributes":{"id":"PluginRootComponent_Stack_status_bar_wifi_panel","type":"Stack","visible":"true","clickable":"true"},"children":[]},
    {"attributes":{"id":"entry_toggle_wifi_switch","type":"Toggle","visible":"true","clickable":"true"},"children":[]}
  ]
}
'@ | ConvertFrom-Json -Depth 10
$wifiPanelClosedLayout = @'
{
  "attributes": {"id":"","type":"root","visible":"true","clickable":"false"},
  "children": [
    {"attributes":{"id":"PluginRootComponent_Stack_status_bar_wifi_panel","type":"Stack","visible":"true","clickable":"true"},"children":[]}
  ]
}
'@ | ConvertFrom-Json -Depth 10
$wifiPanelUnknownLayout = @'
{
  "attributes": {"id":"","type":"root","visible":"true","clickable":"false"},
  "children": []
}
'@ | ConvertFrom-Json -Depth 10
Assert-True (
    (Get-MoshWifiPanelState -Layout $wifiPanelOpenLayout) -ceq 'open' -and
    (Get-MoshWifiPanelState -Layout $wifiPanelClosedLayout) -ceq 'closed' -and
    (Get-MoshWifiPanelState -Layout $wifiPanelUnknownLayout) -ceq 'unknown'
) 'Mosh Wi-Fi panel state did not distinguish open, closed and unknown layouts'
$ambiguousWifiPanelLayout = @'
{
  "attributes": {"id":"","type":"root","visible":"true","clickable":"false"},
  "children": [
    {"attributes":{"id":"entry_toggle_wifi_switch","type":"Toggle","visible":"true","clickable":"true"},"children":[]},
    {"attributes":{"id":"entry_toggle_wifi_switch","type":"Toggle","visible":"true","clickable":"true"},"children":[]}
  ]
}
'@ | ConvertFrom-Json -Depth 10
Assert-Throws -Action {
    Get-MoshWifiPanelState -Layout $ambiguousWifiPanelLayout | Out-Null
} -Message 'Mosh Wi-Fi panel state accepted multiple toggle owners'
$script:wifiPanelNormalizeLayouts = [Collections.Generic.Queue[object]]::new()
$script:wifiPanelNormalizeLayouts.Enqueue($wifiPanelOpenLayout)
$script:wifiPanelNormalizeLayouts.Enqueue($wifiPanelClosedLayout)
$script:wifiPanelBackCount = 0
function Get-MoshWifiLayout {
    param([Parameter(Mandatory = $true)][string]$Name)
    if ($script:wifiPanelNormalizeLayouts.Count -gt 0) {
        return $script:wifiPanelNormalizeLayouts.Dequeue()
    }
    return $wifiPanelClosedLayout
}
function Invoke-LeanTTYDeviceKey {
    param(
        [string]$Hdc,
        [string]$Target,
        [int]$KeyCode
    )
    if ($KeyCode -ne 2070) { throw 'Unexpected Wi-Fi panel normalization key' }
    $script:wifiPanelBackCount++
}
$hdc = 'unused'
$targetId = 'unused'
$normalizedWifiPanel = Normalize-MoshWifiPanelClosed -Name 'regression'
Assert-True (
    (Get-MoshWifiPanelState -Layout $normalizedWifiPanel) -ceq 'closed' -and
    $script:wifiPanelBackCount -eq 1
) 'Mosh Wi-Fi panel normalization did not close one known open panel exactly once'
$route = Get-MoshEndpointRoute -Endpoint '192.168.1.4' -RouteTable @'
Destination Gateway Genmask Flags Metric Ref Use Iface
0.0.0.0 192.168.1.1 0.0.0.0 UG 0 0 0 wlan0
192.168.1.0 0.0.0.0 255.255.255.0 U 0 0 0 wlan0
'@
Assert-True ($null -ne $route -and
    $route.identity -ceq '192.168.1.0,0.0.0.0,255.255.255.0,wlan0') `
    'Mosh endpoint route helper did not select the longest matching prefix'
Assert-True ($moshVerifier.Contains("-Text 'x' -InputNode `$inputNode") -and
    $moshVerifier.Contains('Terminal input withheld for runtime recovery')) `
    'Mosh runtime-reclaim verifier does not exercise the post-visibility first-input guard'
$moshNetwork = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'configure-mosh-test-network.ps1'
) -Raw
foreach ($networkContract in @(
    "[ValidateSet('Enable', 'Status', 'Disable')]",
    '[int]$ExternalSshPort = 2223',
    '[int]$BackendSshPort = 32223',
    "`$udpPortRange = '60000-61000'",
    "'LeanTTY-Mosh-Test-SSH-2223'",
    "'LeanTTY-Mosh-Test-UDP-60000-61000'",
    "'LeanTTY-Mosh-Test-UDP-60042'",
    '$migratedLegacy',
    "'{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'",
    'Refusing to overwrite drifted Mosh test network state',
    'netsh interface portproxy add v4tov4',
    'netsh interface portproxy delete v4tov4',
    'New-NetFirewallRule',
    'New-NetFirewallHyperVRule',
    'existingSsh2222Untouched = $true'
)) {
    Assert-True ($moshNetwork.Contains($networkContract)) (
        "Persistent Mosh test network omitted contract: $networkContract"
    )
}
foreach ($moshContract in @(
    'real stock',
    "'start-ssh-auth-fixture.ps1'",
    "'leantty_ssh/ssh-auth-fixture/src/main.rs'",
    "'preflight-device.ps1'",
    "'dev-pc.ps1'",
    "'mosh-input-snapshot'",
    "'mosh-event'",
    "'server-input-exact-before-enter'",
    'function Invoke-MoshChildCheck',
    "'uinput -K -d 2072 -d 2023 -u 2023 -u 2072'",
    'Invoke-LeanTTYDevicePhysicalKey -Hdc $hdc -Target $targetId -KeyCode 2023',
    "'uinput -K -d 2047 -d 2023 -u 2023 -u 2047'",
    'Invoke-LeanTTYDevicePhysicalKey -Hdc $hdc -Target $targetId -KeyCode 2033',
    '$moshUdpPortMin = 60000',
    '$moshUdpPortMax = 61000',
    'Resolve-MoshRemoteScope',
    "'configure-mosh-test-network.ps1'",
    '-Mode Status',
    '[int]$FixtureBackendPort = 32223',
    "`$fixtureSshAddress = '127.0.0.1'",
    "rport `"tcp:`$FixturePort`" `"tcp:`$FixtureBackendPort`"",
    "fport rm `"tcp:`$FixturePort`" `"tcp:`$FixtureBackendPort`"",
    "sshBootstrapTransport = 'run-scoped-hdc-reverse'",
    "requiredPersistentBoundary = 'windows-and-hyper-v-udp-firewall'",
    'fixtureReverseMappingRemoved = $fixtureMappingRemoved',
    "'-MoshNetworkTimeoutSeconds', `$moshNetworkTimeoutSeconds",
    'serverNetworkTimeoutSeconds = $moshNetworkTimeoutSeconds',
    'FixtureBackendPort must differ from the external FixturePort',
    "[ValidateSet('compatibility', 'agent-tui', 'fixed-endpoint', 'server-path', 'prediction', 'surface-rebuild', 'page-rebuild', 'runtime-reclaim', 'abnormal-exit', 'input-rejection', 'process-recovery', 'pane-close', 'session-isolation', 'pause-recovery', 'wifi-pause-recovery', 'wifi-network-switch', 'suspend-recovery', 'operator-lock-recovery', 'operator-lid-recovery', 'server-disappearance')]",
    "'mosh-session-isolation'",
    'controlName=',
    'mosh-session-[1-9][0-9]*',
    'Clear-MoshLatestSessionMetadata',
    '-ControlDirectory $leftMoshControlDirectory',
    '-ControlDirectory $rightMoshControlDirectory',
    "Submit-MoshChildInput -Text 'ltty-exit' -Name 'ssh-mosh-ssh-exit'",
    'Initialize-MoshSinglePaneWorkspace',
    "Wait-MoshPaneCount -Count 1 -Name 'mosh-pane-close-before-split'",
    "'SSH session connected, pty resized to'",
    'Submit-MoshSshEchoProbe',
    'PERF ping id=',
    'Get-MoshFocusedPaneTerminalMode',
    "-Pattern 'D: 1 chars, mode=\d+'",
    "'pause-recovery', 'wifi-pause-recovery', 'wifi-network-switch', 'prediction'",
    'persistentStateMutatedByScenario = $false',
    'persistentNetworkPreserved = $networkStateReady',
    'localPromptReady = $localPromptReady',
    'uitest uiInput keyEvent 2072 2047 2006',
    'Assert-MoshTerminalSurfaceFocused',
    "'mosh-physical-key-focus.json'",
    '-KeyCode 2044',
    'Wait-WslProcessAbsent',
    '-LinuxPid $moshServerPid -TimeoutSeconds 8',
    'authenticatedGracefulClose = $authenticatedGracefulClose',
    'gracefulServerExitElapsedMs = $gracefulServerExitElapsedMs',
    '"stock-default-dynamic-$moshUdpPortMin-$moshUdpPortMax"',
    'mosh -p $fixedUdpPortStart`:$fixedUdpPortEnd $alias',
    'endpointMatchesRequest = $udpEndpointMatchesRequest',
    'controlled-mosh-fixed-udp-range-selected-and-disconnected',
    'mosh --server=/usr/bin/mosh-server $alias',
    'serverPathMatchesRequest = $serverPathMatchesRequest',
    'controlled-mosh-server-path-selected-and-disconnected',
    'mosh --predict=always $alias',
    'mosh --predict=never $alias',
    'alwaysVisibleBeforeAuthority = $predictionAlwaysVisibleBeforeAuthority',
    'neverHiddenBeforeAuthority = $predictionNeverHiddenBeforeAuthority',
    'normal-pty-kernel-echo-real-interactive-shell',
    'predictionRttBaselineMs =',
    'predictionConfirmationThresholdMs =',
    'controlledOneWayDelayMs =',
    'fixture-owned-bidirectional-40ms-udp-relay',
    'fixture-udp-relay-bidirectional-pause',
    'mosh-prediction-relay-paused',
    'mosh-prediction-relay-stats',
    'mosh-prediction-event',
    'Wait-MoshPredictionRelayDrop',
    'Submit-MoshCanonicalCommand',
    'predictionRelayDroppedPackets =',
    'predictionOutputLatencyMs =',
    'predictionConsumptionLatencyMs =',
    'predictionWarmupSamples =',
    "@('uiInput', 'text', `$Text)",
    'Prediction measurement was invalidated by a terminal resize',
    'actual-vt-output-below-measured-rtt',
    'one-printable-ascii-visible-before-udp-recovery',
    'bytes=[1-9][0-9]*',
    'controlled-mosh-prediction-modes-visible-and-isolated',
    'controlled-mosh-zero-model-real-codex-tui-completed',
    'representativeAgentTui = $agentCompatibilityPassed',
    "plannedModelRequests = 0",
    "'agent-compatibility-wsl.sh'",
    'codex-direct-interaction.json',
    'active-mosh-page-survived-native-surface-rebuild-and-restored-the-original-page',
    'Invoke-MoshSurfaceRebuild',
    'moshPageRetainedAfterRebuild = $surfaceRebuildPageRetained',
    'injected-mosh-session-error-restored-the-original-page-and-rejected-session-output',
    "-Pattern 'ACCEPTANCE_MOSH_ERROR state=injected'",
    'moshErrorObserved = $abnormalExitObserved',
    'originalPageRestored = $originalPageRestoredAfterSession',
    'moshPageDiscarded = $moshPageDiscardedAfterSession',
    'forced-client-process-exit-restored-only-the-local-workspace-without-session-content',
    'Test-MoshProcessWorkspaceRecovery',
    'remoteContentAbsent = $processRecoveryRemoteContentAbsent',
    'sessionNotRestored = $processRecoverySessionNotRestored',
    'runtimeReclaimed = $runtimeWorkspaceRecovered',
    'acceptance-only-runtime-state-reclaim',
    'ACCEPTANCE_RUNTIME_RECLAIM state=dropped',
    'Terminal input withheld for runtime recovery',
    'Runtime recovery request handled pane=.*recovered=true',
    'active-mosh-pane-closed-and-surviving-pane-started-an-isolated-session',
    'two-mosh-and-ssh-mosh-concurrent-sessions-kept-state-terminal-input-output-and-cleanup-isolated',
    'twoMoshKeysDistinct = $sessionIsolationKeysDistinct',
    'twoMoshOutputIsolated = $twoMoshOutputIsolated',
    'closingOneMoshPreservedTheOther = $twoMoshCloseIsolated',
    'sshMoshOutputIsolated = $sshMoshOutputIsolated',
    'closingMoshPreservedSsh = $sshMoshCloseIsolated',
    'Focus-MoshPane -Side',
    'Concurrent Mosh Panes reused one bootstrap encryption key',
    'closedPaneOutputAbsentFromSurvivor = $paneCloseOldOutputAbsent',
    'survivingPaneCommandPassed = $paneCloseSurvivorCommandPassed',
    'Close-ActiveMoshPane',
    'Wait-MoshPaneCount -Count 1',
    '-Query "LTTY_MOSH_CHECK_OK:$caseId" -ExpectMatch $false',
    "'pane-close-surviving-session-command-passed'",
    'selectedUdpPort = $moshServerPort',
    'realShell = $shellCompatibilityPassed',
    'tmux = $tmuxCompatibilityPassed',
    'basicEditor = $editorCompatibilityPassed',
    'Wait-ControlFile -Path $fixtureShellReady',
    'Wait-ControlFile -Path $fixtureTmuxReady',
    'Wait-ControlFile -Path $fixtureEditorReady',
    'remotePtyResize = $resizeCompatibilityPassed',
    'sustainedInputOutput = $streamCompatibilityPassed',
    'utf8WideAndCombiningOutput = $unicodeCompatibilityPassed',
    'unicodeScreenshotCaptured = (-not [string]::IsNullOrWhiteSpace($unicodeScreenshot))',
    'interactiveLargeOutputAndScrollback = $scrollbackCompatibilityPassed',
    'scrollbackBottomObservedInTerminal = $scrollbackBottomObserved',
    'scrollbackTopAbsentUnderMoshStateSync = $scrollbackTopAbsent',
    'realLess = $lessCompatibilityPassed',
    'lessFirstLineObservedAfterHome = $lessFirstLineObserved',
    'lessLastLineObservedAfterEnd = $lessLastLineObserved',
    'alternateScreenEnterExit = $alternateScreenCompatibilityPassed',
    'alternateScreenPriorContentSearchableAfterExit = $alternateScreenHistoryRetained',
    'mosh-alternate-active.png',
    'mosh-alternate-closed.png',
    "largeOutputContract = 'paced-terminal-state-output-with-observed-local-scrollback-boundary'",
    'bootstrapTextAbsentFromTerminal = $bootstrapTerminalAbsent',
    'preferencesUnchanged = $preferencesUnchanged',
    'streamInputBytes = 512',
    "tc qdisc add dev `$udpImpairmentInterface clsact",
    "tc qdisc del dev `$udpImpairmentInterface clsact",
    'flower ip_proto udp dst_port $moshServerPort action drop',
    'flower ip_proto udp src_port $moshServerPort action drop',
    "'PluginRootComponent_Stack_status_bar_wifi_panel'",
    "'entry_toggle_wifi_switch'",
    'Set-MoshDeviceWifi -Enabled $false',
    'Set-MoshDeviceWifi -Enabled $true',
    "'harmony-status-bar-wlan-toggle'",
    'wifiControlCleanupVerified = $wifiControlCleanupVerified',
    'physical-wifi-pause-reported-interrupted-then-recovered-with-remote-shell-preserved',
    '[string]$AlternateWifiSsid',
    'Get-MoshConnectedWifiSsid',
    "@('shell', 'hidumper', '-s', 'WifiDevice')",
    'ConvertFrom-MoshWifiDeviceDump',
    'Normalize-MoshWifiPanelClosed',
    "-LocalPath (Join-Path `$fixtureRoot `"`$Name.json`")",
    'Alternate Wi-Fi must be saved before automated network switching',
    'neither source address nor routing changed',
    "'harmony-status-bar-saved-wlan-network-selection'",
    'networkIdentityRetention = ''redacted''',
    'sameRemoteTerminalPreserved = $remoteShellAliveAfter',
    'outcome = $sshSwitchOutcome',
    'transportReachable = $sshSwitchTransportReachable',
    'Test-MoshDeviceTcpReachable',
    'reconnectFailed = $sshSwitchReconnectFailed',
    'reconnectTerminalMode = $sshSwitchReconnectTerminalMode',
    "`$sshSwitchOutcome = 'reconnect-failed'",
    'sessionPreserved = $sshSwitchSessionPreserved',
    "requiredUserAction = `$sshSwitchUserAction",
    "`$sshSwitchUserAction = 'reconnect'",
    "`$sshSwitchUserAction = 'disconnect-and-reconnect'",
    'Invoke-MoshSshDisconnectEscape',
    "-Pattern 'SSH escape action=disconnect'",
    "'network-switch-protocol.log'",
    "-Name 'network-switch-ssh-post-switch-command'",
    'physical-wifi-network-switch-mosh-ssh-comparison-passed',
    'Set-MoshWifiNetwork -Ssid $wifiOriginalSsid',
    '& wsl.exe @prefix --exec kill -KILL $moshServerPid',
    "-Pattern 'Mosh reachability state=interrupted reason=no_recent_contact'",
    "-Pattern 'Mosh reachability state=responsive transition=recovered'",
    "shell 'power-shell suspend'",
    "shell 'power-shell wakeup'",
    'sameAppProcessAfterResume = $sameAppProcessAfterResume',
    "processIdentityMethod = 'pid-plus-proc-stat-starttime'",
    'cat /proc/$processId/stat',
    'initialAppProcessStartTimeTicks = $initialAppProcessStartTimeTicks',
    'resumedAppProcessStartTimeTicks = $resumedAppProcessStartTimeTicks',
    "recoveryOutcome = `$operatorRecoveryOutcome",
    "`$operatorRecoveryOutcome = 'client-process-replaced-workspace-only'",
    "`$operatorRecoveryOutcome = 'client-process-and-session-preserved'",
    "`$workspaceOnlyLidRecovery =",
    "'operator-lid-client-process-replaced-workspace-only-recovered'",
    'initialAppProcessId = $initialAppProcessId',
    'resumedAppProcessId = $resumedAppProcessId',
    'remoteShellAliveAtProcessChange = $remoteShellAliveAtProcessChange',
    'serverAliveAtProcessChange = $serverAliveAtProcessChange',
    'preRecoveryCloseObserved = $operatorPreRecoveryCloseObserved',
    'preRecoveryErrorObserved = $operatorPreRecoveryErrorObserved',
    'preRecoveryCloseReason = $operatorPreRecoveryCloseReason',
    'remoteShellAliveBeforeRecoveryInput = $remoteShellAliveBeforeRecoveryInput',
    'serverAliveBeforeRecoveryInput = $serverAliveBeforeRecoveryInput',
    'terminalEofObservedBeforeRecoveryInput = $terminalEofObservedBeforeRecoveryInput',
    '"$operatorStage-pre-recovery-device-app.log"',
    '$operatorPreRecoveryLogs = Get-LeanTTYAppLogs',
    'if ($Scenario -in @(''operator-lock-recovery'', ''operator-lid-recovery''))',
    'recoveryInputMethod = $recoveryInputMethod',
    'systemSuspendMs = $systemSuspendMs',
    'resumeCommandElapsedMs = $resumeCommandElapsedMs',
    'operator-physical-lid-close-open-produced-session-preservation-or-workspace-only-recovery',
    'operator-physical-lid-close-open-then-manual-unlock',
    'physicalLidExercised =',
    'UnavailableCountsAsLocked',
    'Write-LiveStatus -Stage "await-$operatorStage-close"',
    'Write-LiveStatus -Stage "await-$operatorStage-open-unlock"',
    'OPERATOR ACTION REQUIRED:',
    "'lid_' + `$attemptId.Substring(0, 10)",
    "`$recoveryInputMethod = 'harmony-uitest-focus-verified-inputText'",
    'operatorLockObserved = $operatorLockObserved',
    'operatorUnlockObserved = $operatorUnlockObserved',
    'mosh-input-owner-$attempt.json',
    'Controlled Mosh input lost its original Pane; refusing retry or Enter',
    'Invoke-LeanTTYDeviceCtrlC -Hdc $hdc -Target $targetId',
    'interruptionObserved = $interruptionObserved',
    'interruptionReason = $interruptionReason',
    'recoveredStatusObserved = $recoveredStatusObserved',
    'recoveryCommandPassed = $recoveryCommandPassed',
    'remoteShellAliveAfter = $remoteShellAliveAfter',
    "'acceptance-only-ui-context-router-current-page-replacement'",
    'pageRebuildProcessPreserved =',
    'pageRebuildWorkspaceReused =',
    'pageRebuildPageRetained =',
    'pageRebuildCommandPassed =',
    "'page-rebuilt-with-process-session-and-command-preserved'",
    'userCloseRequired = $userCloseRequired',
    'localCloseElapsedMs = $localCloseElapsedMs',
    'impairmentCleanupVerified = $udpImpairmentCleanupVerified',
    "-Query 'MOSH CONNECT' -ExpectMatch `$false",
    "'failure-fixture-stderr.log'",
    "'failure-fixture-stdout.log'",
    "'failure-device-lifecycle.log'",
    "hilog -z 30000 | grep -E '`$remotePattern' | ",
    "grep -E 'Ability on|AppMgr|Process|Kill|Terminate|Fault|APP_CRASH|",
    'MOSH CONNECT\s+\d+\s+[A-Za-z0-9+/]{22}',
    "'1.6-mosh-physical-acceptance'",
    "acceptanceEligible = (`$Formal -and `$result -eq 'passed' -and `$cleanupPassed)",
    'Resolve-LeanTTYRetainedCandidate',
    'Assert-LeanTTYCandidateHarnessCompatibility',
    'previousAttemptId = $PreviousAttemptId',
    'result = $(if ($cleanupPassed)',
    'Write-LeanTTYAtomicJson -Path $evidencePath',
    'temporaryDirectoryRemoved'
)) {
    Assert-True ($moshVerifier.Contains($moshContract)) (
        "Mosh physical diagnostic omitted contract: $moshContract"
    )
}
Assert-True (-not $moshVerifier.Contains('已连接 WLAN')) `
    'Mosh Wi-Fi switching still infers connection state from localized system UI text'

Assert-True (
    $moshVerifier.Contains('function Get-MoshNativePageFingerprint') -and
    $moshVerifier.Contains('ACCEPTANCE_NATIVE_PAGE pane=') -and
    $moshVerifier.Contains('restoredBeforeLocalOutput = $restoredPageFingerprint') -and
    $moshVerifier.Contains('ACCEPTANCE_NATIVE_SEARCH_QUERY pane=') -and
    $moshVerifier.Contains('ACCEPTANCE_NATIVE_SEARCH_RESULT pane=') -and
    $moshVerifier.Contains('Intended terminal Search field lost focus before query delivery') -and
    -not $moshVerifier.Contains('ACCEPTANCE_SNAPSHOT_FINGERPRINT') -and
    -not $moshVerifier.Contains('Get-LeanTTYTerminalInputWebOwner')
) 'Mosh page restoration and native query generation must retain independent direct oracles'
Assert-True (
    $moshVerifier.Contains('function Get-MoshEndpointRoute') -and
    $moshVerifier.Contains('endpointRoute') -and
    $moshVerifier.Contains('endpointReachable') -and
    $moshVerifier.Contains('transitionHistory') -and
    $moshVerifier.Contains('mosh-environment-dirty-') -and
    $moshVerifier.Contains('if ($route.Count -ne 1) { return $null }') -and
    $moshVerifier.Contains('if ($linkActive)') -and
    -not $moshVerifier.Contains('if ($linkActive -and $null -ne $endpointRoute)') -and
    $moshVerifier.Contains("@('shell', 'hidumper', '-s', 'WifiDevice')") -and
    $moshVerifier.Contains('Normalize-MoshWifiPanelClosed') -and
    -not $moshVerifier.Contains('已连接 WLAN') -and
    $moshVerifier.Contains('if (-not [bool]$beforeState.active -or -not [bool]$beforeState.endpointReachable)') -and
    -not $moshVerifier.Contains('[string]::IsNullOrWhiteSpace([string]$beforeState.endpointRoute) -or') -and
    -not $moshVerifier.Contains('routeDigest')
) 'Mosh Wi-Fi switching lacks the system-state, direct-endpoint or dirty-state guards'
Assert-True (
    -not $moshVerifier.Contains('Submit-MoshVerifiedChildCommand') -and
    -not $moshVerifier.Contains('Get-MoshTerminalSearchMatch') -and
    -not $moshVerifier.Contains('Submit-MoshChildInput -Text "ltty-shell-check $caseId"') -and
    -not $moshVerifier.Contains("Submit-MoshChildInput -Text 'g' -Submit `$false") -and
    -not $moshVerifier.Contains("Submit-MoshChildInput -Text 'G' -Submit `$false") -and
    -not $moshVerifier.Contains("Submit-MoshChildInput -Text 'q' -Submit `$false")
) 'Mosh pager control keys still use unreliable UiTest text injection'
Assert-True (
    -not $moshVerifier.Contains('pane-output-and-xterm-write-ack-after-four-authoritative-warmup-characters')
) 'Mosh prediction verifier still treats a fixed warmup count as confirmed prediction evidence'
Assert-True (
    $moshVerifier.Contains("[string]`$_.attributes.bundleName -eq 'com.leantty.app'") -and
    $moshVerifier.Contains("[string]`$_.attributes.abilityName -eq 'EntryAbility'") -and
    $moshVerifier.Contains('[string]$_.attributes.hostWindowId -eq $leanTTYWindowId')
) 'Mosh window resize selector is not scoped to the focused LeanTTY host window'
Assert-True (
    -not $moshVerifier.Contains("@('uiInput', 'keyEvent', 2072, 2019)")
) 'Mosh input retry still uses a UiTest chord that does not reliably clear the remote line'
Assert-True (
    $moshVerifier.Contains('[string]$resumedProcessIdentity.key -ceq') -and
    -not $moshVerifier.Contains('$resumedPid -ceq $appPid')
) 'Mosh lifecycle verifier still treats a reusable numeric PID as process identity'
Assert-True (
    -not ($moshSessionViewModel -match 'this\.moshClient\.resize\(this\.lastCols, this\.lastRows\)')
) 'Mosh connected handling still repeats the initial terminal size and resets the prediction epoch'
Assert-True (
    $moshVerifier.Contains('Mosh prediction Ctrl+U injection') -and
    $moshVerifier.Contains("@('uiInput', 'keyEvent', 2072, 2037)") -and
    $moshVerifier.Contains('function Submit-MoshShellMarker') -and
    $moshVerifier.Contains('Submit-MoshCanonicalCommand -Text "touch -- $WslPath"') -and
    $moshVerifier.Contains("'^/[A-Za-z0-9_./-]+$'") -and
    $moshVerifier.Contains('Wait-ControlFile -Path $WindowsPath') -and
    $moshVerifier.Contains('-WslPath "$fixturePredictionEventWsl-main"')
) 'Mosh prediction verifier no longer reserves a shell-safe authoritative marker for post-recovery convergence'
Assert-True (
    $moshVerifier.Contains('controlled-mosh-terminal-compatibility-and-disconnect-completed') -and
    $moshVerifier.Contains('deviceStateRemoved = $deviceStateCleaned') -and
    $moshVerifier.Contains('fixtureProcessesAbsent = $fixtureCleaned') -and
    $moshVerifier.Contains('$script:deviceStateCleaned = $true') -and
    $moshVerifier.Contains('$script:fixtureCleaned = $true') -and
    -not $moshVerifier.Contains('New-NetFirewallRule') -and
    -not $moshVerifier.Contains('Remove-NetFirewallRule') -and
    -not $moshVerifier.Contains('portproxy add') -and
    -not $moshVerifier.Contains('portproxy delete') -and
    -not $moshVerifier.Contains("'-MoshServerPort'") -and
    -not $moshVerifier.Contains("-Pattern 'ACCEPTANCE_INPUT_SUBMIT'") -and
    -not $moshVerifier.Contains('MOSH_KEY=')
) 'Mosh physical diagnostic lacks a content-free verdict or paired cleanup contract'

$moshMatrixPath = Join-Path $PSScriptRoot 'verify-mosh-matrix-pc.ps1'
Assert-True (Test-Path -LiteralPath $moshMatrixPath -PathType Leaf) (
    'Formal Mosh physical matrix orchestrator is missing'
)
$moshMatrix = Get-Content -LiteralPath $moshMatrixPath -Raw
foreach ($formalMoshContract in @(
    'Get-LeanTTYMoshFormalScenarios',
    'Assert-LeanTTYMoshScenarioEvidence -Path $Path -Scenario $Scenario',
    'Formal = $true',
    'acceptanceEligible = ($matrixResult',
    'Assert-MoshScenarioEvidence',
    'Mosh completed checkpoints are not a valid fixed-order prefix',
    'Mosh failed-stage cleanup did not pass',
    'alternateWifiSsidIdentity = $alternateWifiSsidIdentity',
    'Write-LeanTTYAtomicJson -Path $matrixPath',
    'PreviousAttemptId = $previousAttemptId'
)) {
    Assert-True ($moshMatrix.Contains($formalMoshContract)) (
        "Formal Mosh matrix omitted contract: $formalMoshContract"
    )
}
Assert-True (
    -not $moshMatrix.Contains('Start-Job') -and
    -not $moshMatrix.Contains('ForEach-Object -Parallel')
) 'Formal Mosh matrix must control the physical PC serially'

$releaseTooling = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'release-tooling.ps1') -Raw
Assert-True ($releaseTooling.Contains('Assert-LeanTTYRuntimeReclaimEvidence -Evidence $evidence.runtimeReclaim')) (
    'Shared formal Mosh evidence validator omitted the runtime-reclaim contract'
)

$sshMatrixPath = Join-Path $PSScriptRoot 'verify-ssh-matrix-pc.ps1'
Assert-True (Test-Path -LiteralPath $sshMatrixPath -PathType Leaf) (
    'Formal SSH physical matrix orchestrator is missing'
)
$sshMatrixVerifier = Get-Content -Raw -LiteralPath $sshMatrixPath
Assert-True (
    $sshMatrixVerifier.Contains("'transport-performance'") -and
    $sshMatrixVerifier.Contains("'authentication-methods'") -and
    $sshMatrixVerifier.Contains("'lifecycle-recovery'") -and
    $sshMatrixVerifier.Contains("'pane-focus-attention'") -and
    $sshMatrixVerifier.Contains("'verify-ssh-auth-pc.ps1'") -and
    $sshMatrixVerifier.Contains('-Group $group') -and
    $sshMatrixVerifier.Contains('-VerifyPreferencesUnchanged') -and
    $sshMatrixVerifier.Contains("cleanup.result -ne 'passed'") -and
    $sshMatrixVerifier.Contains("runMode -ne 'acceptance'") -and
    $sshMatrixVerifier.Contains('candidate.retained') -and
    $sshMatrixVerifier.Contains('harness.gitDirty') -and
    $sshMatrixVerifier.Contains('preferences.unchanged') -and
    $sshMatrixVerifier.Contains("'before-transparency-performance'") -and
    $sshMatrixVerifier.Contains("'terminal-transparency-mode-restored'") -and
    $sshMatrixVerifier.Contains('performanceMatrix.initialMode') -and
    $sshMatrixVerifier.Contains('performanceMatrix.restoredMode') -and
    $sshMatrixVerifier.Contains('candidate.sha256') -and
    $sshMatrixVerifier.Contains('harness.gitTree') -and
    $sshMatrixVerifier.Contains("'ssh-matrix.json'") -and
    $sshMatrixVerifier.Contains('completedGroups') -and
    $sshMatrixVerifier.Contains('[switch]$Resume') -and
    $sshMatrixVerifier.Contains('Write-LeanTTYAtomicJson') -and
    $sshMatrixVerifier.Contains("'progress.json'") -and
    $sshMatrixVerifier.Contains('attemptId = [string]$groupEvidence.attemptId') -and
    $sshMatrixVerifier.Contains("throw 'R2: harness identity changed") -and
    $sshMatrixVerifier.Contains("throw 'R4: product candidate identity changed") -and
    $sshMatrixVerifier.Contains('contentRecorded = $false')
) 'Formal SSH physical matrix does not enforce isolated fixed-order checkpoints'

$hostIdentityVerifier = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'verify-host-identity-pc.ps1'
) -Raw
foreach ($hostIdentityContract in @(
    'Get-LeanTTYDeviceUnlockPasswordPath',
    "`$keyName = if (`$DefaultEcdsa)",
    "`$fixtureUser = 'key-install'",
    "'start-ssh-auth-fixture.ps1'",
    'Read-LeanTTYFixtureReadiness',
    '$fixtureLinuxPid',
    'native auth event kind=password, layer=target',
    'Assert-LeanTTYLayoutExcludesValues',
    'host add $hostAlias',
    'ssh-copy-id -i $keyName',
    'ssh $hostAlias',
    'Restart-HostIdentityApp',
    '-i none',
    'Wait-HostIdentityFixtureLog',
    'auth method=publickey scenario=KeyInstall fingerprint=',
    'key-install fingerprint=',
    'identity-removal-restored-password-fallback',
    'explicit-binding-recovery',
    'Invoke-LeanTTYDialogButton',
    'Controlled SSH fixture Linux process cleanup failed',
    "'failure-app.log'",
    "'fixture-stderr.log'",
    "scenario = 'host-identity-binding'"
)) {
    Assert-True ($hostIdentityVerifier.Contains($hostIdentityContract)) (
        "Host Identity physical verifier omitted contract: $hostIdentityContract"
    )
}
Assert-True (
    $hostIdentityVerifier.Contains('[switch]$OpenSshCompatibility') -and
    $hostIdentityVerifier.Contains('sudo -n useradd') -and
    $hostIdentityVerifier.Contains('sudo -n userdel -r') -and
    $hostIdentityVerifier.Contains('Disposable WSL OpenSSH account remained after cleanup') -and
    $hostIdentityVerifier.Contains('StandardInput.Write("$UserName`:$Password`n")') -and
    -not $hostIdentityVerifier.Contains('StandardInput.WriteLine("$UserName`:$Password")') -and
    $hostIdentityVerifier.Contains('System OpenSSH omitted the exact accepted public-key fingerprint') -and
    -not $hostIdentityVerifier.Contains('pgrep -u $temporaryWslUser -x sshd') -and
    -not $hostIdentityVerifier.Contains('/usr/sbin/sshd') -and
    $hostIdentityVerifier.Contains('/.ssh/authorized_keys')
) 'Host Identity OpenSSH compatibility mode lacks bounded account setup, proof, or cleanup'
Assert-True (
    $hostIdentityVerifier.Contains('[switch]$DefaultEcdsa') -and
    $hostIdentityVerifier.Contains('-DefaultEcdsa requires -OpenSshCompatibility') -and
    $hostIdentityVerifier.Contains("`$keyName = if (`$DefaultEcdsa) { 'id_ecdsa' }") -and
    $hostIdentityVerifier.Contains('key import $ecdsaImportPath $keyName') -and
    $hostIdentityVerifier.Contains('default-ecdsa-authenticated-before-restart') -and
    $hostIdentityVerifier.Contains('default-ecdsa-authenticated-after-restart') -and
    $hostIdentityVerifier.Contains('temporary-account-authorized-only-id-ecdsa') -and
    $hostIdentityVerifier.Contains('independentEcdsaSourceAbsenceAudit')
) 'Host Identity verifier lacks the isolated default id_ecdsa compatibility scenario'
Assert-True (
    $hostIdentityVerifier.Contains('function Test-HostIdentityDefaultKeyFilesPresent') -and
    $hostIdentityVerifier.Contains(
        "`$KeyName -notin @('id_ed25519', 'id_rsa', 'id_ecdsa')"
    ) -and
    $hostIdentityVerifier.Contains('Test-HostIdentityDefaultKeyFilesPresent')
) 'Host Identity default-key inspection bypasses the bounded standard-name guard'
Assert-True (
    $hostIdentityVerifier.Contains(
        "foreach (`$defaultName in @('id_ed25519', 'id_rsa', 'id_ecdsa'))"
    ) -and
    $hostIdentityVerifier.Contains(
        'Default Identity precondition is not isolated: $defaultName exists'
    )
) 'Host Identity default-key scenario does not require an isolated standard-name baseline'
Assert-True (
    $hostIdentityVerifier.Contains('[switch]$PreserveExistingEd25519') -and
    $hostIdentityVerifier.Contains('-PreserveExistingEd25519 requires -DefaultEcdsa') -and
    $hostIdentityVerifier.Contains('key export id_ed25519 $ed25519BackupName') -and
    $hostIdentityVerifier.Contains('key rm id_ed25519') -and
    $hostIdentityVerifier.Contains('key import $ed25519BackupPath id_ed25519') -and
    $hostIdentityVerifier.Contains('__acceptance_key_backup_$Action $ed25519BackupName') -and
    $hostIdentityVerifier.Contains(
        "-not (Test-HostIdentityDefaultKeyFilesPresent -KeyName 'id_ed25519')"
    ) -and
    $hostIdentityVerifier.Contains('ed25519ExportAttempted') -and
    $hostIdentityVerifier.Contains('ed25519ExportVerified') -and
    $hostIdentityVerifier.Contains('restoredEd25519Fingerprint') -and
    $hostIdentityVerifier.Contains('independentEd25519BackupAbsenceAudit') -and
    -not $hostIdentityVerifier.Contains('sha256sum $Path')
) 'Host Identity verifier lacks reversible product-path preservation for an existing id_ed25519'

# Execute the actual SSH caller with controlled submission/completion boundaries.
& {
    $source = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'verify-ssh-auth-pc.ps1') -Raw
    $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$null)
    $owner = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq 'Submit-FocusedDeviceCommand'
    }, $true)
    . ([scriptblock]::Create($owner.Extent.Text))
    $hdc='fixture'; $Target='fixture'; $appPid='42'; $FixturePort=32123; $currentStage='ssh-diagnostics'
    $commandObservations=[Collections.Generic.List[object]]::new()
    foreach ($mode in @('delayed', 'submit-failed', 'wait-failed', 'ordinary', 'other-endpoint')) {
        $probe=@{submitted=0;waited=0;pending=$false}
        function Submit-LeanTTYDeviceCommand {
            param($Hdc,$Target,$ProcessId,$Command,$Stage,$ObservationSink,$InputNodeProvider)
            $probe.submitted++
            if ($mode -eq 'submit-failed') { throw 'injected submission failure' }
            $probe.pending=$true
        }
        function Wait-LeanTTYDeviceKnownHostAbsent {
            param($Hdc,$Target,$Port)
            Assert-True ($probe.submitted -eq 1 -and $probe.pending -and $Port -eq $FixturePort) 'SSH completion wait lost its owned submission boundary'
            $probe.waited++
            if ($mode -eq 'wait-failed') { throw '[cleanup] injected removal failure' }
            $probe.pending=$false
        }
        $command = switch ($mode) {
            'ordinary' { 'help ssh' }
            'other-endpoint' { 'ssh-keygen -R [127.0.0.1]:32124' }
            default { "ssh-keygen -R [127.0.0.1]:$FixturePort" }
        }
        $failure=''
        try { Submit-FocusedDeviceCommand -Command $command -LayoutName 'fixture' }
        catch { $failure=$_.Exception.Message }
        Assert-True ($probe.submitted -eq 1) 'SSH command was resubmitted'
        if ($mode -eq 'submit-failed') {
            Assert-True ($failure -eq 'injected submission failure' -and $probe.waited -eq 0) 'SSH wait followed an unconfirmed submission'
        } elseif ($mode -in @('ordinary', 'other-endpoint')) {
            Assert-True (-not $failure -and $probe.waited -eq 0) 'SSH owned-endpoint completion rule expanded to another command'
        } elseif ($mode -eq 'wait-failed') {
            Assert-True ($failure -match '^\[harness\]' -and $probe.waited -eq 1 -and $probe.pending) 'SSH cleanup failure was hidden or mislabeled product'
        } else {
            Assert-True (-not $failure -and $probe.waited -eq 1 -and -not $probe.pending) 'SSH caller returned at submission ACK before durable known-host removal completed'
        }
    }
    Write-Host 'SSH known-host completion: 5 real-caller checks passed.'
}

# Execute the owning cleanup block, not a second implementation of its ordering.
& {
    $ast = [Management.Automation.Language.Parser]::ParseInput($hostIdentityVerifier, [ref]$null, [ref]$null)
    $block = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.IfStatementAst] -and
        $node.Clauses[0].Item1.Extent.Text -ceq '$mappingActive' -and
        $node.Extent.Text.Contains("-Stage 'cleanup-known-host'")
    }, $true)
    Assert-True ($null -ne $block) 'Missing Host Identity known-host cleanup owner'
    $cleanup = [scriptblock]::Create($block.Extent.Text)
    $hdc='fixture'; $Target='fixture'; $Port=32123
    foreach ($mode in @('delayed', 'wait-failed', 'not-owned')) {
        $probe=@{submitted=0;waited=0;pending=$false}
        $mappingActive=($mode -ne 'not-owned')
        $cleanupFailures=[Collections.Generic.List[string]]::new()
        function Submit-HostIdentityCommand {
            param($Command,$Stage)
            Assert-True ($Command -ceq 'ssh-keygen -R [127.0.0.1]:32123' -and $Stage -ceq 'cleanup-known-host') 'Cleanup expanded beyond the owned endpoint'
            $probe.submitted++; $probe.pending=$true
        }
        function Wait-LeanTTYDeviceKnownHostAbsent {
            param($Hdc,$Target,$Port)
            Assert-True ($probe.submitted -eq 1 -and $probe.pending -and $Port -eq 32123) 'Known-host wait lost its submitted-command boundary'
            $probe.waited++
            if($mode -eq 'wait-failed'){throw 'injected durable removal failure'}
            $probe.pending=$false
        }
        & $cleanup
        if($mode -eq 'not-owned') {
            Assert-True ($probe.submitted -eq 0 -and $probe.waited -eq 0) 'Unowned endpoint was touched'
        } else {
            Assert-True ($probe.submitted -eq 1 -and $probe.waited -eq 1) 'Host cleanup returned after submission without waiting for durable removal'
            if($mode -eq 'delayed') {
                Assert-True (-not $probe.pending -and $cleanupFailures.Count -eq 0) 'Key restoration can overtake known-host cleanup'
            } else {
                Assert-True ($cleanupFailures.Count -eq 1 -and $cleanupFailures[0] -eq 'Known-host cleanup failed') 'Unproved removal was silently accepted'
            }
        }
    }
    Write-Host 'Host Identity cleanup ordering passed: real owner; delayed, failed and unowned cases.'
}

$deviceRegressionText = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'device-regression.ps1'
) -Raw
$hdcCommonText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'hdc-common.ps1') -Raw
Assert-True (
    $deviceRegressionText.Contains('Get-HdcUiLayout') -and
    $hdcCommonText.Contains("@('shell', 'uitest', 'dumpLayout', '-p', `$remotePath)") -and
    -not $hdcCommonText.Contains("'dumpLayout', '-p', `$remotePath, '-a'")
) 'Routine device layouts still request unused UiTest extended visual attributes'
Assert-True (
    $deviceRegressionText.Contains("return 't' + [Guid]::NewGuid()") -and
    $deviceTextSource.Contains("'shell', 'uitest', 'uiInput', 'inputText', `$center.x, `$center.y, `$Text") -and
    -not $deviceTextSource.Contains('Start-Sleep -Milliseconds 500')
) 'Device secret injection is not restricted to stable lowercase input with focus-verified targeted UiTest delivery'

$sessionViewModel = Get-Content -LiteralPath (
    Join-Path $repoRoot 'entry\src\main\ets\viewmodel\SessionViewModel.ets'
) -Raw
$indexPage = Get-Content -LiteralPath (
    Join-Path $repoRoot 'entry\src\main\ets\pages\Index.ets'
) -Raw
$terminalPane = Get-Content -LiteralPath (
    Join-Path $repoRoot 'entry\src\main\ets\view\components\NativeTerminalPane.ets'
) -Raw
$entryAbility = Get-Content -LiteralPath (
    Join-Path $repoRoot 'entry\src\main\ets\entryability\EntryAbility.ets'
) -Raw
$transferFileManager = Get-Content -LiteralPath (
    Join-Path $repoRoot 'entry\src\main\ets\model\transfer\TransferFileManager.ets'
) -Raw
$commandBarViewModel = Get-Content -LiteralPath (
    Join-Path $repoRoot 'entry\src\main\ets\viewmodel\CommandBarViewModel.ets'
) -Raw
$acceptanceSource = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'acceptance-source.ps1'
) -Raw
$fileTransferVerifier = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'verify-file-transfer-pc.ps1'
) -Raw
$putGetVerifier = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'verify-put-get-pc.ps1'
) -Raw
$configVerifier = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'verify-config-import-export-pc.ps1'
) -Raw
Assert-True (
    $configVerifier.Contains("gate = 'config-import-export-physical-pc'") -and
    $configVerifier.Contains('Submit-LeanTTYDeviceCommand') -and
    $configVerifier.Contains('CONFIG_IMPORT result=success,replace=true') -and
    $configVerifier.Contains('CONFIG_EXPORT result=success') -and
    $configVerifier.Contains('Export conflict changed the existing Downloads file') -and
    $configVerifier.Contains('Restart did not reopen the imported durable config') -and
    $configVerifier.Contains('Product-path cleanup did not restore the original unmanaged config bytes') -and
    $configVerifier.Contains('__acceptance_config_') -and
    $configVerifier.Contains('ACCEPTANCE_CONFIG state=verified,passed=true') -and
    -not $configVerifier.Contains('/storage/Users/currentUser/Download') -and
    -not $configVerifier.Contains('file recv') -and
    $configVerifier.Contains('cleanupComplete = $cleanupComplete') -and
    $configVerifier.Contains("acceptanceEligible = `$false")
) 'Config import/export physical verifier lost input, persistence, conflict, evidence or cleanup controls'
Assert-True (
    $terminalPane.Contains('.onKeyPreIme') -and
    $terminalPane.Contains('.onKeyEvent') -and
    -not $terminalPane.Contains('.onKeyEventDispatch')
) 'Native terminal must route pre-IME and unconsumed IME keys through its owning key handler'
Assert-True (
    -not $sessionViewModel.Contains('ACCEPTANCE_INPUT_SUBMIT') -and
    $acceptanceSource.Contains("import { ACCEPTANCE_TESTS } from 'BuildProfile'") -and
    $acceptanceSource.Contains('ACCEPTANCE_INPUT_SUBMIT') -and
    $acceptanceSource.Contains('ACCEPTANCE_RUNTIME_RECLAIM state=dropped') -and
    $acceptanceSource.Contains('reclaimRuntimeStateForAcceptance') -and
    $acceptanceSource.Contains('Acceptance: Rebuild Renderer') -and
    $acceptanceSource.Contains('Acceptance: Downloads No-Replace') -and
    $acceptanceSource.Contains('Acceptance: Downloads FD Boundary') -and
    $acceptanceSource.Contains('Acceptance: Downloads Manager Boundary') -and
    $acceptanceSource.Contains('ACCEPTANCE_DOWNLOADS_NOREPLACE') -and
    $acceptanceSource.Contains('ACCEPTANCE_DOWNLOADS_FD') -and
    $acceptanceSource.Contains('ACCEPTANCE_DOWNLOADS_MANAGER') -and
    $acceptanceSource.Contains('ACCEPTANCE_CONFIG state=prepared') -and
    $acceptanceSource.Contains('ACCEPTANCE_CONFIG state=verified,passed=true') -and
    $acceptanceSource.Contains('__acceptance_config_') -and
    $acceptanceSource.Contains('ACCEPTANCE_KEY_BACKUP state=observed') -and
    $acceptanceSource.Contains('ACCEPTANCE_KEY_BACKUP state=verified') -and
    $acceptanceSource.Contains('__acceptance_key_backup_') -and
    $acceptanceSource.Contains('FileUtils.removeFileRequired(backupPrivate)') -and
    $acceptanceSource.Contains('FileUtils.removeFileRequired(backupPublic)') -and
    -not $acceptanceSource.Contains('Acceptance: Open Search') -and
    -not $acceptanceSource.Contains('Debug Material') -and
    $acceptanceSource.Contains('pasteClipboardForAcceptance') -and
    $acceptanceSource.Contains('ctrlKey && altKey && !shiftKey && event.keyCode === 2038') -and
    $acceptanceSource.Contains('ACCEPTANCE_LOCAL_DISK_FULL armed') -and
    $acceptanceSource.Contains('No space left on device (os error 28)') -and
    $acceptanceSource.Contains('Invoke-WithLeanTTYAcceptanceSource') -and
    $acceptanceSource.Contains('Invoke-WithLeanTTYNativeAcceptanceSource')
) 'Acceptance-only ArkTS is not isolated from the production source tree'
Assert-True (
    $fileTransferVerifier.Contains('Acceptance: Downloads No-Replace') -and
    $fileTransferVerifier.Contains('Acceptance: Downloads FD Boundary') -and
    $fileTransferVerifier.Contains('Acceptance: Downloads Manager Boundary') -and
    $fileTransferVerifier.Contains('ACCEPTANCE_DOWNLOADS_NOREPLACE passed=true') -and
    $fileTransferVerifier.Contains('ACCEPTANCE_DOWNLOADS_FD passed=true') -and
    $fileTransferVerifier.Contains('ACCEPTANCE_DOWNLOADS_MANAGER passed=true') -and
    $fileTransferVerifier.Contains('managerObservation') -and
    $fileTransferVerifier.Contains('device-downloads-capability.json') -and
    ([regex]::Matches($fileTransferVerifier, 'Start-Sleep -Milliseconds 1000').Count -ge 3) -and
    $fileTransferVerifier.Contains('Invoke-LeanTTYDeviceClick') -and
    $fileTransferVerifier.Contains('Get-LeanTTYDeviceLayout') -and
    $fileTransferVerifier.Contains('Start-LeanTTYRegressionApp')
) 'Focused file-transfer physical-PC gate is incomplete'
Assert-True (
    $putGetVerifier.Contains('get -p $FixturePort') -and
    $putGetVerifier.Contains('put -p $FixturePort') -and
    $putGetVerifier.Contains('completed direction=get,bytes=$expectedCompletionBytes|failed code=\S+') -and
    $putGetVerifier.Contains('completed direction=put,bytes=$expectedCompletionBytes|failed code=\S+') -and
    $putGetVerifier.Contains('GET completed without the FINALIZING stage') -and
    $putGetVerifier.Contains('PUT completed without the FINALIZING stage') -and
    $putGetVerifier.Contains('GET large-file progress completed without visible progress and live speed') -and
    $putGetVerifier.Contains('PUT large-file progress completed without visible progress and live speed') -and
    $putGetVerifier.Contains('FILE_TRANSFER progress=visible') -and
    $putGetVerifier.Contains('FILE_TRANSFER speed=visible') -and
    $putGetVerifier.Contains('GET then PUT changed the file SHA-256') -and
    $putGetVerifier.Contains('HarmonyOS application logs exposed the temporary fixture password') -and
    $putGetVerifier.Contains('[switch]$CancelGet') -and
    $putGetVerifier.Contains('[switch]$CloseApplication') -and
    $putGetVerifier.Contains('[switch]$ClosePane') -and
    $putGetVerifier.Contains('[switch]$StallPreparation') -and
    $putGetVerifier.Contains('[switch]$FailRemoteCleanup') -and
    $putGetVerifier.Contains('[switch]$FailLocalCleanup') -and
    $putGetVerifier.Contains('[switch]$LocalDiskFull') -and
    $putGetVerifier.Contains('[switch]$Backpressure') -and
    $putGetVerifier.Contains('[switch]$ForceTerminate') -and
    $putGetVerifier.Contains('[switch]$LateEvents') -and
    $putGetVerifier.Contains('[switch]$DisconnectGet') -and
    $putGetVerifier.Contains('[switch]$ServerAliveBlackhole') -and
    $putGetVerifier.Contains('[switch]$AuthenticationMatrix') -and
    $putGetVerifier.Contains("'-SftpFault'") -and
    $putGetVerifier.Contains('Read-LeanTTYSharedTextFile') -and
    $deviceRegressionText.Contains('[IO.FileShare]::ReadWrite') -and
    $putGetVerifier.Contains('FILE_TRANSFER result=failed code=REMOTE_CLEANUP') -and
    $putGetVerifier.Contains('Remote cleanup failure exposed the final remote file name') -and
    $putGetVerifier.Contains('device-put-remote-cleanup-failure.json') -and
    $putGetVerifier.Contains('device-get-local-cleanup-failure.json') -and
    $putGetVerifier.Contains('device-get-local-disk-full.json') -and
    $putGetVerifier.Contains('device-authentication-matrix.json') -and
    $putGetVerifier.Contains('File transfer authentication prompt=private-key-passphrase') -and
    $putGetVerifier.Contains('File transfer authentication prompt=keyboard-interactive') -and
    $putGetVerifier.Contains('explicit -i affected only its command') -and
    $putGetVerifier.Contains('Test-LeanTTYDeviceKeyFilesPresent') -and
    $putGetVerifier.Contains('Submit-LeanTTYDeviceCommand') -and
    $putGetVerifier.Contains('-ExpectedCommandProvider') -and
    $putGetVerifier.Contains('Wait-LeanTTYAcceptanceIdleInputState') -and
    -not $putGetVerifier.Contains('Wait-ExactAcceptanceCommandSubmit') -and
    $putGetVerifier.Contains('Submit-HiddenTransferValue -Value $script:secret') -and
    $putGetVerifier.Contains('Assert-LeanTTYLayoutExcludesValues') -and
    $putGetVerifier.Contains('Wait-AuthenticationMatrixKeyCreated') -and
    $putGetVerifier.Contains('device-put-get-backpressure.json') -and
    $putGetVerifier.Contains('device-put-get-force-termination.json') -and
    $putGetVerifier.Contains('device-put-get-late-events.json') -and
    $putGetVerifier.Contains('Rejected stale file transfer event, kind=completed') -and
    $putGetVerifier.Contains('function Wait-FileTransferAuthenticationState') -and
    $putGetVerifier.Contains('auth-observer-') -and
    $putGetVerifier.Contains('snapshotObserved') -and
    $putGetVerifier.Contains('liveObserved') -and
    $putGetVerifier.Contains('authentication-observation-timeout') -and
    $putGetVerifier.Contains('SessionViewModel,FileTransferClient') -and
    $putGetVerifier.Contains('aa force-stop com.leantty.app') -and
    $putGetVerifier.Contains('Application close preparation') -and
    $putGetVerifier.Contains('ACCEPTANCE_FILE_TRANSFER_DROPPED=[1-9]') -and
    $putGetVerifier.Contains('cleanupFailureFinalPresent=false') -and
    $putGetVerifier.Contains('temporaryCount=1') -and
    $putGetVerifier.Contains('device-get-disconnect.json') -and
    $putGetVerifier.Contains('device-get-server-alive.json') -and
    $putGetVerifier.Contains('FILE_TRANSFER result=failed code=KEEPALIVE_TIMEOUT') -and
    $putGetVerifier.Contains("'-EnableServerOutputDrop'") -and
    $putGetVerifier.Contains('host rm $serverAliveHostAlias') -and
    $putGetVerifier.Contains('[switch]$MinimizeGet') -and
    $putGetVerifier.Contains('[switch]$SelectionCopy') -and
    $putGetVerifier.Contains('[switch]$FileNameMatrix') -and
    $putGetVerifier.Contains('Submit-TerminalTextWithAcceptanceData') -and
    $putGetVerifier.Contains('device-put-get-file-name-matrix.json') -and
    $putGetVerifier.Contains("('l' * 220) + '.bin'") -and
    $putGetVerifier.Contains('Invoke-LeanTTYDeviceCtrlAltS') -and
    $putGetVerifier.Contains('Invoke-LeanTTYDeviceCtrlC') -and
    $putGetVerifier.Contains('Clipboard copy success=true,length=4') -and
    $putGetVerifier.Contains('Window visibility changed: visible=false') -and
    $putGetVerifier.Contains('transfer-restored-after-minimized-get.png') -and
    $putGetVerifier.Contains('FILE_TRANSFER result=failed code=NETWORK') -and
    $putGetVerifier.Contains('ACCEPTANCE_LOCAL_DISK_FULL armed') -and
    $putGetVerifier.Contains('ACCEPTANCE_FILE_TRANSFER_PREPARATION waiting=true') -and
    $putGetVerifier.Contains('device-put-get-pane-close-preparing.json') -and
    $putGetVerifier.Contains('device-put-get-application-close-preparing.json') -and
    $putGetVerifier.Contains('SftpDelayMilliseconds') -and
    $putGetVerifier.Contains('Invoke-LeanTTYDeviceCtrlC') -and
    $putGetVerifier.Contains('FILE_TRANSFER result=(cancelled|failed|completed)') -and
    $putGetVerifier.Contains("terminalMatches.Count -ne 1") -and
    $putGetVerifier.Contains('Application close preparation completed') -and
    $putGetVerifier.Contains('EnhanceCloseBtn') -and
    $putGetVerifier.Contains('device-put-get-application-close.json') -and
    $putGetVerifier.Contains('device-put-get-pane-close.json') -and
    $putGetVerifier.Contains('one Pane remained usable in the original application process') -and
    $putGetVerifier.Contains('temporaryPresent=false') -and
    $putGetVerifier.Contains('device-put-get-cancel.json') -and
    $putGetVerifier.Contains('fport rm "tcp:$FixturePort" "tcp:$FixturePort"') -and
    -not $putGetVerifier.Contains('rport rm "tcp:$FixturePort"') -and
    $putGetVerifier.Contains('$awakeLeaseMilliseconds = ($fixtureRunSeconds + 300) * 1000') -and
    $putGetVerifier.Contains('-TimeoutMilliseconds $awakeLeaseMilliseconds') -and
    $putGetVerifier.Contains('Invoke-LeanTTYDeviceClick') -and
    $putGetVerifier.Contains('-WindowStyle Hidden') -and
    $putGetVerifier.Contains('device-put-get.json')
) 'Production PUT/GET physical-PC verifier is incomplete'
Assert-True (
    $indexPage.Contains('ApplicationCloseCoordinator.register(this.applicationCloseHandler)') -and
    $indexPage.Contains('ApplicationCloseCoordinator.unregister(this.applicationCloseHandler)') -and
    $entryAbility.Contains('await ApplicationCloseCoordinator.prepareTermination()') -and
    $indexPage -match (
        'private async terminateApplication[\s\S]*?' +
        'await ApplicationCloseCoordinator\.prepareTermination\(\)[\s\S]*?' +
        'await context\.terminateSelf\(\)'
    ) -and
    $entryAbility.Contains('ApplicationCloseCoordinator.resetPreparation()') -and
    $indexPage.Contains('ApplicationCloseCoordinator.resetPreparation()') -and
    $entryAbility.Contains('Application close preparation failed')
) 'Application termination lost the public close-coordinator lifecycle wiring'
Assert-True (
    $transferFileManager.Contains('fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW') -and
    $transferFileManager.Contains('fs.OpenMode.READ_ONLY | fs.OpenMode.DIR | fs.OpenMode.NOFOLLOW') -and
    $transferFileManager.Contains('!stat.isFile() || stat.isSymbolicLink()') -and
    $transferFileManager.Contains('!stat.isDirectory() || stat.isSymbolicLink()') -and
    $transferFileManager.Contains('fs.moveFileSync(prepared.tempPath, prepared.finalPath, 1)') -and
    $transferFileManager.Contains('fs.moveFileSync(prepared.tempPath, candidatePath, 1)')
) 'Downloads transfer lost required no-follow, symlink rejection, or no-replace platform flags'
Assert-True (
    $commandBarViewModel.Contains('TerminalTextPolicy.isSafe(value)') -and
    -not $commandBarViewModel.Contains('DownloadsAccessManager') -and
    -not $commandBarViewModel.Contains('FileTransferClient') -and
    -not $commandBarViewModel.Contains('SshClient')
) 'Tab completion lost its text-safety or no-network dependency boundary'

foreach ($productionSource in @(
    'entry\src\main\ets\pages\Index.ets',
    'entry\src\main\ets\model\terminal\NativeTerminalController.ets',
    'entry\src\main\ets\model\terminal\TerminalSurfaceController.ets',
    'entry\src\main\ets\viewmodel\SessionViewModel.ets'
)) {
    $productionText = Get-Content -LiteralPath (Join-Path $repoRoot $productionSource) -Raw
    Assert-True (
        $productionText -notmatch (
            'ACCEPTANCE_TESTS|Acceptance:|ForAcceptance|ACCEPTANCE_INPUT_SUBMIT'
        )
    ) "Production ArkTS contains acceptance-only source: $productionSource"
}

$backgroundBellVerifier = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'verify-background-bell-notification-pc.ps1'
) -Raw
$backgroundBellVerifier += Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'notification-regression.ps1'
) -Raw
Assert-True (
    $backgroundBellVerifier.Contains('notificationCardCount') -and
    $backgroundBellVerifier.Contains("minimizeBounds.Groups['y2']") -and
    $backgroundBellVerifier.Contains("'-HapPath is required") -and
    $backgroundBellVerifier.Contains('test-signed-diagnostic-hap') -and
    $backgroundBellVerifier.Contains('suppressedPaneId') -and
    $backgroundBellVerifier.Contains('resetPublished') -and
    $backgroundBellVerifier.Contains('Expected one notification after visible reset') -and
    $backgroundBellVerifier.Contains('notification suppressed for current background episode') -and
    $backgroundBellVerifier.Contains('A terminal needs your attention') -and
    $backgroundBellVerifier.Contains('终端有新提示') -and
    $backgroundBellVerifier.Contains('Background BEL return applied') -and
    $backgroundBellVerifier.Contains('Background BEL return ignored because the source is no longer pending') -and
    $backgroundBellVerifier.Contains('source-handled-first') -and
    $backgroundBellVerifier.Contains('source-pane-destroyed') -and
    $backgroundBellVerifier.Contains('notification-panel-after-manual-dismiss') -and
    $backgroundBellVerifier.Contains('notification-panel-after-dismiss-settle') -and
    $backgroundBellVerifier.Contains('Assert-NotificationCleanup') -and
    $backgroundBellVerifier.Contains('Restore-NotificationPermission') -and
    $backgroundBellVerifier.Contains('[privacy]')
) 'Background BEL notification scenario lacks suppression, return, privacy, or cleanup oracles'

$backgroundBellSource = Get-Content -LiteralPath (
    Join-Path $repoRoot 'entry\src\main\ets\model\ui\BackgroundBellNotification.ets'
) -Raw
Assert-True (
    $backgroundBellSource.Contains('autoDeletedTime: new Date().getTime() + NOTIFICATION_LIFETIME_MS') -and
    $backgroundBellSource.Contains('const NOTIFICATION_LIFETIME_MS: number = 24 * 60 * 60 * 1000') -and
    -not $backgroundBellSource.Contains('NotificationSubscriber') -and
    -not $backgroundBellSource.Contains('subscribeNotification')
) 'Background BEL expiration lost its bounded lifetime or introduced dismissal tracking'

$longTaskVerifier = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'verify-long-task-notification-pc.ps1'
) -Raw
Assert-True (
    $longTaskVerifier.Contains("ValidateSet('shell', 'tmux', 'codex')") -and
    $longTaskVerifier.Contains('Temporary WSL sshd') -and
    $longTaskVerifier.Contains('codex exec --sandbox read-only') -and
    $longTaskVerifier.Contains("tmux -L '") -and
    $longTaskVerifier.Contains("printf '\a'") -and
    $longTaskVerifier.Contains('Background BEL notification published') -and
    $longTaskVerifier.Contains('Background BEL return applied') -and
    $longTaskVerifier.Contains('genericPayload') -and
    $longTaskVerifier.Contains('fport rm "tcp:$Port" "tcp:$Port"') -and
    $longTaskVerifier.Contains('reverse mapping remained after cleanup') -and
    $longTaskVerifier.Contains('reverse-port-removed') -and
    $longTaskVerifier.Contains('app-identity-unchanged') -and
    $longTaskVerifier.Contains('Resolve-LeanTTYRetainedCandidate') -and
    $longTaskVerifier.Contains('harness = [ordered]@{') -and
    $longTaskVerifier.Contains('attemptId = $attemptId') -and
    $longTaskVerifier.Contains('previousAttemptId = $PreviousAttemptId') -and
    $longTaskVerifier.Contains('Write-LeanTTYAtomicJson') -and
    $longTaskVerifier.Contains('contentRecorded = $false')
) 'Long-task notification scenario lacks real workloads, notification return, privacy, or cleanup oracles'
Assert-True (
    $longTaskVerifier.Contains('Restore-NotificationPermission') -and
    $longTaskVerifier.Contains('Assert-NotificationCleanup')
) 'Long-task notification cleanup must not toggle an already visible singleton window'

$agentCompatibilityVerifier = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'verify-agent-compatibility-pc.ps1'
) -Raw
Assert-True (
    $agentCompatibilityVerifier.Contains('attemptId = $attemptId') -and
    $agentCompatibilityVerifier.Contains('previousAttemptId = $PreviousAttemptId') -and
    $agentCompatibilityVerifier.Contains('Write-AgentCompatibilityProgress') -and
    $agentCompatibilityVerifier.Contains('Write-LeanTTYAtomicJson') -and
    $agentCompatibilityVerifier.Contains('contentRecorded = $false')
) 'Agent compatibility groups lack atomic attempt checkpoints and content-free progress'

$backgroundBellPermissionVerifier = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'verify-background-bell-permission-pc.ps1'
) -Raw
$backgroundBellPermissionVerifier += Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'notification-regression.ps1'
) -Raw
Assert-True (
    $backgroundBellPermissionVerifier.Contains('originalEnabled') -and
    $backgroundBellPermissionVerifier.Contains("minimizeBounds.Groups['y2']") -and
    $backgroundBellPermissionVerifier.Contains('notifications are disabled') -and
    $backgroundBellPermissionVerifier.Contains('disabledNotificationCardCount') -and
    $backgroundBellPermissionVerifier.Contains('permissionPromptObserved') -and
    $backgroundBellPermissionVerifier.Contains('Handle disabled background BEL attention') -and
    $backgroundBellPermissionVerifier.Contains("'Pane attention cleared: ' + [regex]::Escape(") -and
    $backgroundBellPermissionVerifier.Contains('enabledPublished') -and
    $backgroundBellPermissionVerifier.Contains('enabledReturned') -and
    $backgroundBellPermissionVerifier.Contains('restore-original') -and
    $backgroundBellPermissionVerifier.Contains('original-notification-setting-verified') -and
    -not $backgroundBellPermissionVerifier.Contains('bm clean') -and
    -not $backgroundBellPermissionVerifier.Contains('uninstall')
) 'Background BEL permission scenario lacks disabled, enabled, return, or restoration oracles'

$unexpectedRecoveryUninstallVerifier = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'verify-unexpected-recovery-uninstall-pc.ps1'
) -Raw
Assert-True (
    $unexpectedRecoveryUninstallVerifier.Contains("@('uninstall', 'com.leantty.app')") -and
    -not $unexpectedRecoveryUninstallVerifier.Contains("@('uninstall', '-k'") -and
    $unexpectedRecoveryUninstallVerifier.Contains('Wait-WorkspaceState -TabCount 1 -PaneCount 1') -and
    $unexpectedRecoveryUninstallVerifier.Contains('-TabCount 2 -PaneCount 2') -and
    $unexpectedRecoveryUninstallVerifier.Contains(
        'Recovery run started: generation=1, unexpected=false') -and
    $unexpectedRecoveryUninstallVerifier.Contains('durableAssetStoreReadOrMutated = $false') -and
    $unexpectedRecoveryUninstallVerifier.Contains('exactCandidateReinstalled = $true')
) 'Unexpected-recovery uninstall scenario lost its fresh-install or durable-asset boundary'

& (Join-Path $PSScriptRoot 'test-native-performance-evidence.ps1')

# Run the actual native paste readiness observer without a device. A result for
# another Pane or another query must not authorize the one-shot paste action.
& {
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot 'verify-ssh-auth-pc.ps1'), [ref]$null, [ref]$null)
    foreach ($name in @('Wait-AuthOutputMarker', 'Invoke-LeanTTYPasteShortcut')) {
        $definition = $ast.FindAll({ param($n)
            $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name
        }, $true) | Select-Object -First 1
        Invoke-Expression $definition.Extent.Text
    }
    $hdc = 'Invoke-ClipboardFakeHdc'; $Target = 'unused'; $EvidenceDirectory = 'unused'
    function Invoke-ClipboardFakeHdc { $script:clipboardChord = $args[-1]; $global:LASTEXITCODE = 0 }
    function Invoke-LeanTTYDeviceText { param($Text) $script:clipboardQuery = $Text; $script:clipboardQueryCount++ }
    function Invoke-LeanTTYDeviceKey { param($KeyCode) Assert-True ($KeyCode -eq 2070) 'Readiness observer sent an unexpected key'; $script:clipboardEscapeCount++ }
    function Wait-LeanTTYTerminalInputLayout { $script:clipboardFocusRestored = $true }
    function Get-LeanTTYDeviceLayout {
        $query = $script:clipboardQuery
        $pane = if ($case -eq 'changed-pane' -and $query) { 'pane-2-1' } else { 'pane-1-1' }
        $resultPane = if ($case -eq 'unrelated-result') { 'pane-1-2' } else { $pane }
        $result = if ($case -eq 'missing-marker') { '0/0' } else { '1/1' }
        if ($case -eq 'wrong-query' -and $query) { $query = 'unrelated' }
        if ($case -eq 'stale-query') { $query = 'old-query' }
        return @{ attributes = @{}; children = @(
            @{attributes=@{type='TextInput';id="native-search-$pane";focused='true';visible='true';text=$query};children=@()},
            @{attributes=@{type='Text';id="native-search-result-$resultPane";visible='true';text=$result};children=@()}) }
    }
    foreach ($case in @('matched', 'missing-marker', 'unrelated-result', 'wrong-query', 'changed-pane', 'stale-query')) {
        $script:clipboardQuery = ''; $script:clipboardQueryCount = 0; $script:clipboardEscapeCount = 0
        $script:clipboardFocusRestored = $false; $failure = $null
        try { Wait-AuthOutputMarker -Marker 'LTTY_PASTE_READY:public:1048576' -TimeoutSeconds 1 }
        catch { $failure = $_.Exception }
        Assert-True (($null -eq $failure) -eq ($case -eq 'matched')) "Clipboard readiness misclassified $case"
        Assert-True ($script:clipboardQueryCount -le 1 -and $script:clipboardEscapeCount -eq 1) 'Readiness repeated input or failed to close search'
        Assert-True ($script:clipboardFocusRestored -eq ($case -eq 'matched')) 'Readiness passed without its output boundary'
    }
    Invoke-LeanTTYPasteShortcut
    Assert-True ($script:clipboardChord -ceq 'uinput -K -d 2072 -d 2038 -u 2038 -u 2072') 'Paste used the retired Web modifier workaround'
}

# Exercise the actual alternate-screen preparation, including stale/missing
# server snapshots. Only a newly observed empty line may reach the escape check.
& {
    $source = Get-Content (Join-Path $PSScriptRoot 'verify-ssh-auth-pc.ps1') -Raw
    $start = $source.IndexOf("    Wait-AuthOutputMarker -Marker 'LTTY_DIRTY:escapealt'")
    $end = $source.IndexOf('    Assert-SshEscapeLocalOnly', $start)
    Assert-True ($start -gt 0 -and $end -gt $start) 'Alternate-screen preparation owner missing'
    $prepare = [scriptblock]::Create($source.Substring($start, $end-$start))
    $hdc='unused'; $Target='unused'; $fixtureConnectedInputSnapshot='unused'
    function Wait-AuthOutputMarker { param($Marker)
        Assert-True ($Marker -ceq 'LTTY_DIRTY:escapealt') 'Wrong alternate-screen marker'
        if ($case -eq 'missing-output') { throw 'output not observed' }
        $events.Add('output')
    }
    function Remove-Item { $events.Add('discard-stale') }
    function Invoke-LeanTTYDeviceKey { param($KeyCode)
        Assert-True ($KeyCode -eq 2054) 'Preparation sent a non-newline key'
        $events.Add('newline')
    }
    function Wait-FixtureConnectedInputSnapshot { param($Expected)
        Assert-True ($Expected -ceq '') 'Expected a nonempty remote line'
        $events.Add('observe')
        return @{observed=($case -ne 'missing-snapshot');value=$(if($case -eq 'nonempty'){'[I'}else{''})}
    }
    foreach ($case in @('empty','missing-snapshot','nonempty','missing-output')) {
        $events=[Collections.Generic.List[string]]::new(); $failure=$null
        try { & $prepare } catch { $failure=$_.Exception }
        Assert-True (($null -eq $failure) -eq ($case -eq 'empty')) "Alternate line misclassified $case"
        $expectedEvents=if($case -eq 'missing-output'){''}else{'output|discard-stale|newline|observe'}
        Assert-True (($events -join '|') -ceq $expectedEvents) 'Alternate preparation reordered or repeated actions'
    }
}

# Recovery is a layout/lifecycle claim; removed user-visible warning text is not an oracle.
& {
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot 'verify-mosh-pc.ps1'), [ref]$null, [ref]$null)
    $reader = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Test-MoshProcessWorkspaceRecovery'
    }, $true)
    Assert-True ($null -ne $reader) 'Missing process workspace recovery observer'
    . ([scriptblock]::Create($reader.Extent.Text))
    $valid = 'Recovery run started: generation=2, unexpected=true'
    Assert-True (Test-MoshProcessWorkspaceRecovery -Logs $valid -PaneCount 1) 'Recovery without obsolete warning was rejected'
    foreach ($logs in @('', 'Workspace layout was recovered',
            $valid.Replace('true','false'), $valid.Replace('=2','=1'), "$valid`n$valid")) {
        Assert-True (-not (Test-MoshProcessWorkspaceRecovery -Logs $logs -PaneCount 1)) 'Missing, clean, first-generation or ambiguous recovery was accepted'
    }
    foreach ($count in @(0,2)) {
        Assert-True (-not (Test-MoshProcessWorkspaceRecovery -Logs $valid -PaneCount $count)) 'Unexpected Pane layout qualified as recovered'
    }
    $source = Get-Content (Join-Path $PSScriptRoot 'verify-mosh-pc.ps1') -Raw
    Assert-True (-not $source.Contains("-Query 'Workspace layout was recovered'")) 'Removed warning remains a process recovery oracle'
    Assert-True ($source.Contains("-Query 'Workspace layout was kept'")) 'Real runtime-reclaim warning was removed from its own check'
    Assert-True ([regex]::Matches($source, '-T UnexpectedExitRecoveryStore').Count -eq 2) 'Process recovery reads a log projection that omits its state owner'
}
Write-Host 'Device regression helper tests passed.' -ForegroundColor Green
