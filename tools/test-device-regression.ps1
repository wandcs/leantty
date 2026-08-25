param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'hdc-common.ps1')
. (Join-Path $PSScriptRoot 'device-regression.ps1')

& (Join-Path $PSScriptRoot 'diagnose-text-input-pc.ps1') -SelfTest

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

Assert-True (
    (Get-LeanTTYTerminalInputText -Layout $layout) -eq 'ssh-keygen -p -f regression_key'
) 'Terminal input text was not read from the accessibility layout'

$focusedTextLayout = @'
{
  "attributes":{"type":"root","focused":"true","bounds":"[0,0][100,100]"},
  "children":[
    {"attributes":{"type":"textField","hint":"Search text Find","focused":"true","bounds":"[10,10][50,30]"},"children":[]},
    {"attributes":{"type":"textField","hint":"Terminal input","focused":"false","bounds":"[10,60][50,80]"},"children":[]}
  ]
}
'@ | ConvertFrom-Json -Depth 20
$focusedTextInputs = @(Get-LeanTTYFocusedTextInputNodes -Layout $focusedTextLayout)
Assert-True (
    $focusedTextInputs.Count -eq 1 -and
    $focusedTextInputs[0].attributes.hint -eq 'Search text Find'
) 'Targeted text input did not select the unique focused text field'

& {
    $script:capturedHdcCalls = [Collections.Generic.List[object]]::new()
    function Invoke-FakeHdc {
        $script:capturedHdcCalls.Add(@($args))
        $global:LASTEXITCODE = 0
    }

    Invoke-LeanTTYDeviceText `
        -Hdc 'Invoke-FakeHdc' `
        -Target 'regression-device' `
        -Text 'ssh-keygen -p -f regression_key' `
        -InputNode ([pscustomobject]@{
            attributes = [pscustomobject]@{ bounds = '[10,20][110,70]' }
        })
    Assert-True (
        $script:capturedHdcCalls.Count -eq 1 -and
        $script:capturedHdcCalls[0].Count -eq 9 -and
        $script:capturedHdcCalls[0][0] -eq '-t' -and
        $script:capturedHdcCalls[0][1] -eq 'regression-device' -and
        $script:capturedHdcCalls[0][2] -eq 'shell' -and
        $script:capturedHdcCalls[0][3] -eq 'uitest' -and
        $script:capturedHdcCalls[0][4] -eq 'uiInput' -and
        $script:capturedHdcCalls[0][5] -eq 'inputText' -and
        $script:capturedHdcCalls[0][6] -eq 60 -and
        $script:capturedHdcCalls[0][7] -eq 45 -and
        $script:capturedHdcCalls[0][8] -eq 'ssh-keygen -p -f regression_key'
    ) 'Device text did not target the selected terminal input through UiTest inputText'
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

$deviceTextSource = (Get-Command Invoke-LeanTTYDeviceText).Definition
$submitCommandParameters = (Get-Command Submit-LeanTTYDeviceCommand).Parameters.Keys
$submitCommandSource = (Get-Command Submit-LeanTTYDeviceCommand).Definition
$automationSummarySource = (Get-Command Get-LeanTTYDeviceCommandAutomationSummary).Definition
Assert-True (
    -not $deviceTextSource.Contains("@('uiInput', 'text', `$Text)") -and
    $deviceTextSource.Contains("@('uiInput', 'inputText', `$center.x, `$center.y, `$Text)")
) 'Ordinary device text can still collide with the focused UiTest CLI text parser'
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
Assert-True (
    $authFixtureLauncherText.Contains('[ValidateRange(1, 7200)]')
) 'SSH authentication fixture does not allow the bounded full acceptance budget'
Assert-True (
    $deviceRegressionText -notmatch 'hilog\s+-x[^\r\n]*\s-z\s'
) 'Device log query combines mutually exclusive hilog exit and tail modes'
Assert-True (
    $deviceRegressionText.Contains(
        'EntryAbility,IndexPage,'
    ) -and
    $deviceRegressionText.Contains(
        'TerminalSurfaceController,TerminalBridge,AppViewModel,BackgroundBellNotification'
    ) -and
    -not $deviceRegressionText.Contains('EntryAbility,Index,IndexPage')
) 'Device log query omits the Pane attention state owner'
Assert-True (
    $deviceRegressionText -notmatch 'terminal-line cleanup|backspaceCount'
) 'Device input cleanup still uses inferred backspaces'
Assert-True (
    $deviceRegressionText.Contains("@('uiInput', 'inputText', `$center.x, `$center.y, `$Text)") -and
    -not $deviceRegressionText.Contains('ConvertTo-LeanTTYDeviceTextKeyCommand') -and
    $deviceRegressionText.Contains('Start-Sleep -Milliseconds 500')
) 'Ordinary device text does not use the targeted serialized UiTest path'
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
    )
) 'Device application log capture omits authentication or window lifecycle events'

$splitLayout = @'
{
  "attributes": {"bounds":"[0,0][3120,1955]","hint":""},
  "children": [
    {"attributes":{"bounds":"[127,495][145,536]","hint":"Terminal input","focused":"false"},"children":[]},
    {"attributes":{"bounds":"[1694,135][1712,176]","hint":"Terminal input","focused":"true"},"children":[]}
  ]
}
'@ | ConvertFrom-Json -Depth 20
$splitInputs = @(Get-LeanTTYTerminalInputNodes -Layout $splitLayout)
Assert-True (
    $splitInputs.Count -eq 2 -and
    $splitInputs[0].attributes.bounds -eq '[127,495][145,536]' -and
    $splitInputs[1].attributes.bounds -eq '[1694,135][1712,176]'
) 'Terminal input nodes are not sorted into stable left/right pane order'

& {
    $script:focusLayoutIndex = 0
    $script:focusClickCalls = [Collections.Generic.List[object]]::new()
    $focusLayouts = @(
        (@'
{"attributes":{"bounds":"[0,0][0,0]","hint":""},"children":[]}
'@ | ConvertFrom-Json -Depth 20),
        (@'
{"attributes":{"bounds":"[0,0][3120,1955]","hint":""},"children":[{"attributes":{"bounds":"[127,495][145,536]","hint":"Terminal input","focused":"true"},"children":[]},{"attributes":{"bounds":"[1694,135][1712,176]","hint":"Terminal input","focused":"false"},"children":[]}]}
'@ | ConvertFrom-Json -Depth 20)
    )
    function Invoke-FocusHdc {
        $script:focusClickCalls.Add(@($args))
        $global:LASTEXITCODE = 0
    }
    function Get-LeanTTYDeviceLayout {
        param($Hdc, $Target, $LocalPath)
        $layout = $focusLayouts[[Math]::Min($script:focusLayoutIndex, $focusLayouts.Count - 1)]
        $script:focusLayoutIndex++
        return $layout
    }

    $focusedLayout = Set-LeanTTYTerminalInputFocus `
        -Hdc 'Invoke-FocusHdc' `
        -Target 'regression-device' `
        -InputNode $splitInputs[0] `
        -LocalPath 'unused.json' `
        -TimeoutSeconds 2
    $focusedNodes = @(Get-LeanTTYTerminalInputNodes -Layout $focusedLayout | Where-Object {
        [string]$_.attributes.focused -eq 'true'
    })
    Assert-True (
        $script:focusClickCalls.Count -eq 1 -and
        ($script:focusClickCalls[0] -join ' ') -match 'uiInput click 136 516' -and
        $script:focusLayoutIndex -eq 2 -and
        $focusedNodes.Count -eq 1 -and
        $focusedNodes[0].attributes.bounds -eq '[127,495][145,536]'
    ) 'Terminal focus gate did not accept one focused post-click snapshot'
}

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
    'verify-terminal-search-pc.ps1',
    'verify-background-bell-notification-pc.ps1',
    'verify-background-bell-permission-pc.ps1',
    'verify-long-task-notification-pc.ps1',
    'verify-proxy-jump-pc.ps1'
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
            $content.Contains('harmony-uitest-targeted-inputText-runtime-generated-temporary-fixture-values') -and
            $content.Contains("method = 'harmony-uitest-text-and-raw-physical-special-keys'") -and
            $content.Contains("ordinaryTextInjection = 'harmony-uitest-targeted-inputText'") -and
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
            ([regex]::Matches($content, 'Submit-ConnectedInputUntilAuthEvent').Count -ge 2) -and
            $content.Contains("'connected-input-snapshot'") -and
            $content.Contains('function Wait-FixtureConnectedInputSnapshot') -and
            $content.Contains('for ($inputAttempt = 1; $inputAttempt -le 3; $inputAttempt++)') -and
            $content.Contains('connected input state=cleared') -and
            $content.Contains('Connected input could not be made exact before Enter') -and
            $content.Contains('Connected input outcome is unknown; the scenario must be restarted') -and
            $content.Contains('Connected input application outcome is unknown; the scenario must be restarted') -and
            -not $content.Contains("Submit-ConnectedInput -Text 'ltty-paste-prepare russhmain 1048576'") -and
            $content.Contains("'Clipboard paste ok,1048576'") -and
            $content.Contains("'D: 1048576 chars'") -and
            $content.Contains("'paste case=russhmain bytes=1048576 result=matched'") -and
            $content.Contains("'uitest uiInput keyEvent 2072 2045 2038'") -and
            $content.Contains("'uinput -K -u 2038 -u 2045 -u 2072'") -and
            $content.Contains("Invoke-AuthPerfSample -CaseId 'russhmain'") -and
            $content.Contains('"completenessPercent":100') -and
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
            $content.Contains("'Previous match, Shift+Enter'") -and
            $content.Contains('-RequireSearchInputFocus $false') -and
            -not $content.Contains("'uitest uiInput keyEvent 2072 2017'") -and
            $content.Contains('Clear-TerminalSearchQuery -CharacterCount $query.Length') -and
            $content.Contains('Clear-TerminalSearchQuery -CharacterCount $missingQuery.Length') -and
            $content.Contains("'LEANTTY_NO_RESULT_ZXQVK'") -and
            $content.Contains("'^(?:Find text|Search text|查找内容)'") -and
            $content.Contains('[AllowEmptyString()]') -and
            $content.Contains("'^(?:No results|未找到结果)$'") -and
            $content.Contains('wrappedForward = $true') -and
            $content.Contains('wrappedBackward = $true') -and
            $content.Contains("'TerminalBridge: PERF bridge reason=destroy'") -and
            $content.Contains("'TerminalBridge: Bridge initialized'") -and
            $content.Contains("'Acceptance: Rebuild Renderer'") -and
            $content.Contains("'EnhanceMinimizeBtn'") -and
            $content.Contains("Invoke-LocalTerminalCommand -Command 'help'") -and
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
            $content.Contains('$activePaneBounds') -and
            $content.Contains('[Collections.Generic.List[string]]::new()') -and
            $content.Contains('$activePaneBounds.Contains($bounds)') -and
            $content.Contains('Get-LeanTTYActiveTerminalInputNodes') -and
            $content.Contains('Get-LeanTTYActiveTerminalSurfaceNodes') -and
            $content.Contains('-RequireTerminalFocus $false') -and
            $content.Contains('terminalFocusRestoredByCommandSubmit') -and
            $content.Contains("attributes.opacity -eq '1.000000'") -and
            $content.Contains("attributes.zIndex -eq '1'") -and
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
    {"attributes":{"type":"Web","visible":"true","originalText":"resource:/RAWFILE/terminal.html","bounds":"[121,135][2926,1926]"},"children":[]}
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
      {"attributes":{"type":"Web","visible":"true","originalText":"resource:/RAWFILE/terminal.html","bounds":"[121,135][2926,1926]"},"children":[]}
    ]},
    {"attributes":{"type":"__Common__","opacity":"0.000000","zIndex":"0","bounds":"[121,135][2926,1926]"},"children":[
      {"attributes":{"type":"Web","visible":"true","originalText":"resource:/RAWFILE/terminal.html","bounds":"[121,135][2926,1926]"},"children":[]}
    ]}
  ]
}
'@ | ConvertFrom-Json -Depth 10
        $activeSurfaces = @(Get-LeanTTYActiveTerminalSurfaceNodes -Layout $rendererRebuiltLayout)
        Assert-True (
            $activeSurfaces.Count -eq 1 -and
            [string]$activeSurfaces[0].attributes.zIndex -eq '1'
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
    $sshMatrixVerifier.Contains('candidate.sha256') -and
    $sshMatrixVerifier.Contains('harness.gitTree') -and
    $sshMatrixVerifier.Contains("'ssh-matrix.json'") -and
    $sshMatrixVerifier.Contains('completedGroups')
) 'Formal SSH physical matrix does not enforce isolated fixed-order checkpoints'

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
    $deviceRegressionText.Contains("@('uiInput', 'inputText', `$center.x, `$center.y, `$Text)") -and
    $deviceRegressionText.Contains('Start-Sleep -Milliseconds 500')
) 'Device secret injection is not restricted to stable lowercase input with targeted UiTest delivery'

$repoRoot = Split-Path $PSScriptRoot -Parent
$sessionViewModel = Get-Content -LiteralPath (
    Join-Path $repoRoot 'entry\src\main\ets\viewmodel\SessionViewModel.ets'
) -Raw
$indexPage = Get-Content -LiteralPath (
    Join-Path $repoRoot 'entry\src\main\ets\pages\Index.ets'
) -Raw
$terminalPane = Get-Content -LiteralPath (
    Join-Path $repoRoot 'entry\src\main\ets\view\components\TerminalPane.ets'
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
    $terminalPane.Contains('.onInterceptKeyEvent') -and
    -not $terminalPane.Contains('.onKeyEventDispatch')
) 'Terminal Web owns unhandled key dispatch; the generic component dispatcher must not shadow it'
Assert-True (
    -not $sessionViewModel.Contains('ACCEPTANCE_INPUT_SUBMIT') -and
    $acceptanceSource.Contains("import { ACCEPTANCE_TESTS } from 'BuildProfile'") -and
    $acceptanceSource.Contains('ACCEPTANCE_INPUT_SUBMIT') -and
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
    'entry\src\main\ets\model\bridge\TerminalBridge.ets',
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
    $backgroundBellVerifier.Contains('notification-cancel-requested-by-visible-lifecycle') -and
    $backgroundBellVerifier.Contains('single-pane-confirmed') -and
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
    $longTaskVerifier.Contains('app-identity-unchanged')
) 'Long-task notification scenario lacks real workloads, notification return, privacy, or cleanup oracles'
Assert-True (
    $longTaskVerifier.Contains('cleanup-before-activation') -and
    $longTaskVerifier.Contains('if ($cleanupInputs.Count -eq 0)')
) 'Long-task notification cleanup must not toggle an already visible singleton window'

$backgroundBellPermissionVerifier = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'verify-background-bell-permission-pc.ps1'
) -Raw
Assert-True (
    $backgroundBellPermissionVerifier.Contains('originalEnabled') -and
    $backgroundBellPermissionVerifier.Contains("minimizeBounds.Groups['y2']") -and
    $backgroundBellPermissionVerifier.Contains('notifications are disabled') -and
    $backgroundBellPermissionVerifier.Contains('disabledNotificationCardCount') -and
    $backgroundBellPermissionVerifier.Contains('permissionPromptObserved') -and
    $backgroundBellPermissionVerifier.Contains('Handle disabled background BEL attention') -and
    $backgroundBellPermissionVerifier.Contains('Pane attention cleared: pane-') -and
    $backgroundBellPermissionVerifier.Contains('enabledPublished') -and
    $backgroundBellPermissionVerifier.Contains('enabledReturned') -and
    $backgroundBellPermissionVerifier.Contains('restore-original') -and
    $backgroundBellPermissionVerifier.Contains('original-notification-setting-restored') -and
    -not $backgroundBellPermissionVerifier.Contains('bm clean') -and
    -not $backgroundBellPermissionVerifier.Contains('uninstall')
) 'Background BEL permission scenario lacks disabled, enabled, return, or restoration oracles'

Write-Host 'Device regression helper tests passed.' -ForegroundColor Green
