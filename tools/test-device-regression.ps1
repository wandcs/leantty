param()

$ErrorActionPreference = 'Stop'
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

$printableAscii = -join (32..126 | ForEach-Object { [char]$_ })
$printableKeyCommand = ConvertTo-LeanTTYDeviceTextKeyCommand -Text $printableAscii
$unexpectedKeyTokens = @($printableKeyCommand -split ' ' | Where-Object {
    $_ -notmatch '^(?:uinput|-K|-d|-u|\d+)$'
})
Assert-True (
    $printableKeyCommand.StartsWith('uinput -K ') -and
    $unexpectedKeyTokens.Count -eq 0 -and
    $printableKeyCommand -notmatch 'uitest|uiInput'
) 'Device text key conversion did not cover the complete printable ASCII range'
Assert-Throws -Action {
    ConvertTo-LeanTTYDeviceTextKeyCommand -Text "line`nbreak"
} -Message 'Device text key conversion accepted non-printable input'

& {
    $script:capturedHdcCalls = [Collections.Generic.List[object]]::new()
    function Invoke-FakeHdc {
        $script:capturedHdcCalls.Add(@($args))
        $global:LASTEXITCODE = 0
    }

    Invoke-LeanTTYDeviceText `
        -Hdc 'Invoke-FakeHdc' `
        -Target 'regression-device' `
        -Text 'echo LTTY'
    $expectedFirstCommand = ConvertTo-LeanTTYDeviceTextKeyCommand `
        -Text 'echo LTT' `
        -IntervalMilliseconds 500
    $expectedSecondCommand = ConvertTo-LeanTTYDeviceTextKeyCommand `
        -Text 'Y' `
        -IntervalMilliseconds 500
    Assert-True (
        $script:capturedHdcCalls.Count -eq 2 -and
        $script:capturedHdcCalls[0].Count -eq 4 -and
        $script:capturedHdcCalls[0][0] -eq '-t' -and
        $script:capturedHdcCalls[0][1] -eq 'regression-device' -and
        $script:capturedHdcCalls[0][2] -eq 'shell' -and
        $script:capturedHdcCalls[0][3] -eq $expectedFirstCommand -and
        $script:capturedHdcCalls[1][3] -eq $expectedSecondCommand
    ) 'Device text injection did not use bounded device-paced raw-key commands'

    $script:capturedHdcCalls.Clear()
    $secretLengthText = 't' + ('a' * 23)
    Invoke-LeanTTYDeviceText `
        -Hdc 'Invoke-FakeHdc' `
        -Target 'regression-device' `
        -Text $secretLengthText
    Assert-True (
        $script:capturedHdcCalls.Count -eq 3 -and
        $script:capturedHdcCalls[0][3] -eq (
            ConvertTo-LeanTTYDeviceTextKeyCommand `
                -Text ('t' + ('a' * 7)) `
                -IntervalMilliseconds 500
        ) -and
        $script:capturedHdcCalls[1][3] -eq (
            ConvertTo-LeanTTYDeviceTextKeyCommand -Text ('a' * 8) -IntervalMilliseconds 500
        ) -and
        $script:capturedHdcCalls[2][3] -eq (
            ConvertTo-LeanTTYDeviceTextKeyCommand -Text ('a' * 8) -IntervalMilliseconds 500
        )
    ) 'Secret-length device text injection was not split below the observed physical uinput boundary'
}

& {
    $script:injectedText = ''
    $script:submittedKeyCodes = [Collections.Generic.List[int]]::new()
    function Invoke-LeanTTYDeviceText {
        param($Hdc, $Target, $Text)
        $script:injectedText = $Text
    }
    function Invoke-LeanTTYDeviceKey {
        param($Hdc, $Target, $KeyCode)
        $script:submittedKeyCodes.Add($KeyCode)
    }

    Submit-LeanTTYDeviceCommand `
        -Hdc 'unused' `
        -Target 'unused' `
        -Command 'echo LEANTTY_SMOKE'
    Assert-True (
        $script:injectedText -eq 'echo LEANTTY_SMOKE' -and
        $script:submittedKeyCodes.Count -eq 1 -and
        $script:submittedKeyCodes[0] -eq 2054
    ) 'Device command submission did not inject raw text before pressing Enter'
}

$submitCommandParameters = (Get-Command Submit-LeanTTYDeviceCommand).Parameters.Keys
$submitCommandSource = (Get-Command Submit-LeanTTYDeviceCommand).Definition
Assert-True (
    $submitCommandParameters -notcontains 'LayoutPath' -and
    -not $submitCommandSource.Contains('Get-LeanTTYTerminalInputText')
) 'Device command submission still treats ArkWeb accessibility text as the native command buffer'

$keyPassphraseVerifier = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'verify-key-passphrase-pc.ps1'
) -Raw
Assert-True (
    $keyPassphraseVerifier.Contains("-Pattern 'ACCEPTANCE_IDLE_RESULT kind='") -and
    $keyPassphraseVerifier.Contains('completionActive=(?:true|false),menuActive=(?:true|false)') -and
    $keyPassphraseVerifier.Contains('$actualBuffer -ceq $Command') -and
    $keyPassphraseVerifier.Contains('ACCEPTANCE_IDLE_INTERRUPT cleared=true') -and
    $keyPassphraseVerifier.Contains('Physical key injection could not prepare the exact command buffer')
) 'Key-passphrase device commands are not verified before consequential submission'

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
$physicalKeySource = (Get-Command Invoke-LeanTTYDevicePhysicalKey).Definition
Assert-True (
    $appLogParameters -notcontains 'Pid' -and
    $waitLogParameters -notcontains 'Pid' -and
    $waitLogSource.Contains('[ValidateRange(1, 60)]')
) 'Device log helpers conflict with the read-only PowerShell PID automatic variable'
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
Assert-True (
    $deviceRegressionText -notmatch 'hilog\s+-x[^\r\n]*\s-z\s'
) 'Device log query combines mutually exclusive hilog exit and tail modes'
Assert-True (
    $deviceRegressionText.Contains('TerminalSurfaceController,TerminalBridge,AppViewModel')
) 'Device log query omits the Pane attention state owner'
Assert-True (
    $deviceRegressionText -notmatch 'terminal-line cleanup|backspaceCount'
) 'Device input cleanup still uses inferred backspaces'
Assert-True (
    $deviceRegressionText -match '-IntervalMilliseconds 500(?:\s|$)' -and
    $deviceRegressionText.Contains('$chunkLength = 8') -and
    $deviceRegressionText.Contains('$postInjectionSettleMilliseconds = 500') -and
    $deviceRegressionText.Contains('Start-Sleep -Milliseconds $postInjectionSettleMilliseconds')
) 'Device raw-key text injection does not preserve pacing and bounded batches'
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
{"attributes":{"bounds":"[0,0][3120,1955]","hint":""},"children":[{"attributes":{"bounds":"[127,495][145,536]","hint":"Terminal input","focused":"false"},"children":[]},{"attributes":{"bounds":"[1694,135][1712,176]","hint":"Terminal input","focused":"true"},"children":[]}]}
'@ | ConvertFrom-Json -Depth 20),
        (@'
{"attributes":{"bounds":"[0,0][3120,1955]","hint":""},"children":[{"attributes":{"bounds":"[127,495][145,536]","hint":"Terminal input","focused":"true"},"children":[]},{"attributes":{"bounds":"[1694,135][1712,176]","hint":"Terminal input","focused":"false"},"children":[]}]}
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
        $script:focusLayoutIndex -eq 3 -and
        $focusedNodes.Count -eq 1 -and
        $focusedNodes[0].attributes.bounds -eq '[127,495][145,536]'
    ) 'Terminal focus gate did not wait for two stable focused snapshots of the clicked input'
}

foreach ($scriptName in @(
    'device-regression.ps1',
    'verify-key-passphrase-pc.ps1',
    'verify-ssh-auth-pc.ps1',
    'verify-terminal-search-pc.ps1'
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
            $content.Contains('SSH authentication harness requires a clean committed tree') -and
            $content.Contains('Assert-LeanTTYCandidateHarnessCompatibility') -and
            $content.Contains('harness = [ordered]@{')
        ) 'SSH authentication evidence does not separate candidate and harness identity safely'
        Assert-True (
            $content.Contains('rport "tcp:$FixturePort"') -and
            $content.Contains('fport rm "tcp:$FixturePort" "tcp:$FixturePort"') -and
            $content.Contains('cleanup = [ordered]@{')
        ) 'SSH authentication fixture mapping is not paired with recorded cleanup'
        Assert-True (
            $content.Contains('Assert-LeanTTYLayoutExcludesValues') -and
            $content.Contains('HarmonyOS application logs exposed a temporary SSH fixture secret') -and
            $content.Contains("'failure-fixture-stderr.txt'") -and
            $content.Contains("'[REDACTED]'") -and
            -not $content.Contains('Device auth input delivery length mismatch') -and
            $content.Contains("SessionViewModel: D: 1 chars, mode=") -and
            $content.Contains('function Invoke-AcknowledgedAuthText') -and
            ([regex]::Matches($content, 'Invoke-AcknowledgedAuthText').Count -ge 6) -and
            $content.Contains('Authentication input character was not acknowledged after three attempts') -and
            $content.Contains('device-paced-runtime-generated-printable-ascii-with-per-character-nonsecret-ack') -and
            $content.Contains('ACCEPTANCE_INPUT_SUBMIT') -and
            $content.Contains('Submit-FocusedDeviceCommand') -and
            $content.Contains('[regex]::Escape($Command)') -and
            $content.Contains("'ltty-exit'") -and
            $content.Contains("'shell command=exit result=closed'") -and
            $content.Contains('Assert-AuthCommandLoopbackTarget') -and
            $content.Contains("'[environment] Device key injection changed the SSH command target'") -and
            $content.Contains('Activate-RegressionWindow') -and
            $content.Contains('Focus-ActiveCommandInput') -and
            $content.Contains('Set-LeanTTYTerminalInputFocus') -and
            $content.Contains('businessOutcomeRequired = $true') -and
            $content.Contains('fixedDelayUsedAsVerdict = $false') -and
            $content.Contains('deviceProgramIntervalMilliseconds = 500')
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
            $content.Contains('[switch]$DiagnosticHap') -and
            $content.Contains('[switch]$VerifyPreferencesUnchanged') -and
            $content.Contains('-DiagnosticHap requires an explicit -HapPath') -and
            $content.Contains("provenance = 'explicit-unretained-diagnostic-hap'") -and
            $content.Contains("`$runMode = if (`$Only.Count -eq 0 -and -not `$DiagnosticHap)") -and
            $content.Contains("runMode = `$runMode") -and
            $content.Contains("failureDomain = `$failureDomain") -and
            $content.Contains('attemptId = $attemptId') -and
            $content.Contains('resourceManifest = [ordered]@{') -and
            $content.Contains('Write-AuthLiveStatus') -and
            $content.Contains('Get-LeanTTYFixtureStageBudgetSeconds') -and
            $content.Contains('Get-LeanTTYFixtureRunSeconds') -and
            $content.Contains('selectedStageBudgetsSeconds') -and
            $content.Contains("'diagnostic'") -and
            $content.Contains("'acceptance'")
        ) 'SSH authentication harness lacks targeted diagnostics or auditable live evidence'
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
            $content.Contains("Wait-AuthLog -Pattern 'rust event: AUTH:target:authentication was rejected'") -and
            -not $content.Contains("Wait-AuthLog -Pattern 'rust event: AUTH:authentication was rejected'") -and
            $content.Contains("'publickey-unencrypted'") -and
            $content.Contains("'publickey-then-password'") -and
            $content.Contains("'publickey-then-keyboard-interactive'") -and
            $content.Contains("'keyboard-interactive-zero-prompt'") -and
            $content.Contains("'unsupported-method-error-and-recovery'") -and
            $content.Contains('AUTH:no supported authentication method is available') -and
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
            $content.Contains('LeanTTY process changed while activating its window') -and
            $content.Contains("'process-stop-during-hidden-prompt-cleanup'") -and
            $content.Contains("'tools/verify-terminal-search-pc.ps1'") -and
            $content.Contains("'docs/design/terminal-search.md'") -and
            $content.Contains("'docs/next-work.md'") -and
            $content.Contains('Device did not submit the focused command after three attempts')
        ) 'SSH authentication scenario does not declare its bounded physical coverage'
        Assert-True (
            $content.Contains("'transport-main-path'") -and
            $content.Contains("'ltty-input-check russhmain'") -and
            $content.Contains("'ltty-paste-prepare russhmain 1048576'") -and
            ([regex]::Matches($content, 'Submit-ConnectedInputUntilFixtureEvent').Count -ge 8) -and
            ([regex]::Matches($content, 'Submit-ConnectedInputUntilAuthEvent').Count -ge 2) -and
            $content.Contains('Device did not deliver connected input after three attempts') -and
            $content.Contains('Connected input did not produce the expected application event after three attempts') -and
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
            $content.Contains("'performance-matrix'") -and
            $content.Contains("@('Off', 'Low', 'Medium', 'High', 'Extreme')") -and
            $content.Contains('Invoke-AuthPerfSample -CaseId $caseId') -and
            $content.Contains("' bytes=\d+ state=prepared'") -and
            $content.Contains('Fixture did not accept the PERF prepare command') -and
            $content.Contains('Fixture did not accept the PERF run command') -and
            $content.Contains('commandAttempts') -and
            $content.Contains('renderSamples = @($renderSamples)') -and
            $content.Contains('memorySamples = @($memorySamples)') -and
            $content.Contains("hidumper -s 10 -a 'hitchs app0'") -and
            $content.Contains("hidumper -s 10 -a 'gles'") -and
            $content.Contains("Set-AuthTransparencyMode -Mode 'Medium'") -and
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
            $content.Contains("'^Search text'") -and
            $content.Contains('[AllowEmptyString()]') -and
            $content.Contains("'^No results$'") -and
            $content.Contains('wrappedForward = $true') -and
            $content.Contains('wrappedBackward = $true') -and
            $content.Contains("'TerminalBridge: PERF bridge reason=destroy'") -and
            $content.Contains("'TerminalBridge: Bridge initialized'") -and
            $content.Contains("'Acceptance: Rebuild Renderer'") -and
            $content.Contains("'EnhanceMinimizeBtn'") -and
            $content.Contains("Invoke-LocalTerminalCommand -Command 'help'") -and
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
            $content.Contains("'ACCEPTANCE_INPUT_SUBMIT sequence=\d+,kind=command'") -and
            $content.Contains("attributes.opacity -eq '1.000000'") -and
            $content.Contains("attributes.zIndex -eq '1'") -and
            $content.Contains('does not ') -and
            $content.Contains('satisfy physical-keyboard or Chinese/English IME acceptance') -and
            $content.Contains("'layout-search-open.json'") -and
            $content.Contains("'layout-search-closed.json'") -and
            $content.Contains("'explicit-unretained-diagnostic-hap'") -and
            $content.Contains('Assert-LeanTTYCandidateHarnessCompatibility') -and
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
}

$deviceRegressionText = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'device-regression.ps1'
) -Raw
Assert-True (
    $deviceRegressionText.Contains("return 't' + [Guid]::NewGuid()") -and
    $deviceRegressionText.Contains('-IntervalMilliseconds 500')
) 'Device secret injection is not restricted to stable lowercase input with conservative pacing'

$repoRoot = Split-Path $PSScriptRoot -Parent
$sessionViewModel = Get-Content -LiteralPath (
    Join-Path $repoRoot 'entry\src\main\ets\viewmodel\SessionViewModel.ets'
) -Raw
$localCommandOutput = Get-Content -LiteralPath (
    Join-Path $repoRoot 'entry\src\main\ets\model\terminal\LocalCommandOutput.ets'
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
$downloadsAccessManager = Get-Content -LiteralPath (
    Join-Path $repoRoot 'entry\src\main\ets\model\transfer\DownloadsAccessManager.ets'
) -Raw
$transferFileManager = Get-Content -LiteralPath (
    Join-Path $repoRoot 'entry\src\main\ets\model\transfer\TransferFileManager.ets'
) -Raw
$commandBarViewModel = Get-Content -LiteralPath (
    Join-Path $repoRoot 'entry\src\main\ets\viewmodel\CommandBarViewModel.ets'
) -Raw
$terminalTextPolicy = Get-Content -LiteralPath (
    Join-Path $repoRoot 'entry\src\main\ets\common\security\TerminalTextPolicy.ets'
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
    $putGetVerifier.Contains('[switch]$AuthenticationMatrix') -and
    $putGetVerifier.Contains("'-SftpFault'") -and
    $putGetVerifier.Contains('[IO.FileShare]::ReadWrite') -and
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
    $putGetVerifier.Contains('Get-LeanTTYTerminalInputText -Layout $typedLayout') -and
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
    $putGetVerifier.Contains('-WindowStyle Hidden') -and
    $putGetVerifier.Contains('device-put-get.json')
) 'Production PUT/GET physical-PC verifier is incomplete'
Assert-True (
    $sessionViewModel.Contains("const width: number = 30") -and
    $sessionViewModel.Contains("'\r\u001b[2K' + SessionViewModel.styleTransferProgress") -and
    $localCommandOutput.Contains("GREEN + '●' + RESET") -and
    $sessionViewModel.Contains('FILE_TRANSFER progress=visible') -and
    $sessionViewModel.Contains('FILE_TRANSFER speed=visible') -and
    $sessionViewModel.Contains("FILE_TRANSFER stage=finalizing")
) 'Production PUT/GET terminal progress is not fixed-width, in-place, and stateful'
Assert-True (
    $indexPage.Contains('ApplicationCloseCoordinator.register(this.applicationCloseHandler)') -and
    $indexPage.Contains('ApplicationCloseCoordinator.unregister(this.applicationCloseHandler)') -and
    $indexPage.Contains('await this.disconnectAllRuntimes()') -and
    $entryAbility.Contains('await ApplicationCloseCoordinator.prepareTermination()') -and
    $entryAbility.Contains('ApplicationCloseCoordinator.resetPreparation()') -and
    $indexPage.Contains('ApplicationCloseCoordinator.resetPreparation()') -and
    $entryAbility.Contains('Application close preparation failed')
) 'Application termination does not await the same bounded Pane disconnect path'
Assert-True (
    $sessionViewModel.Contains('this.requestFileTransferCancellation()') -and
    $sessionViewModel.Contains('this.transferPreparationCancellation') -and
    $sessionViewModel.Contains('await this.transferCompletion') -and
    $transferFileManager.Contains('DownloadsAccessManager.ensure(context, cancellation)') -and
    $downloadsAccessManager.Contains('Promise.race<string>') -and
    $downloadsAccessManager.Contains('TRANSFER_CANCELLED')
) 'Downloads preparation cannot be released by the owning Pane cancellation path'
Assert-True (
    $transferFileManager.Contains('fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW') -and
    $transferFileManager.Contains('fs.OpenMode.READ_ONLY | fs.OpenMode.DIR | fs.OpenMode.NOFOLLOW') -and
    $transferFileManager.Contains('!stat.isFile() || stat.isSymbolicLink()') -and
    $transferFileManager.Contains('!stat.isDirectory() || stat.isSymbolicLink()') -and
    $transferFileManager.Contains('fs.moveFileSync(prepared.tempPath, prepared.finalPath, 1)') -and
    $transferFileManager.Contains('fs.moveFileSync(prepared.tempPath, candidatePath, 1)') -and
    $transferFileManager.Contains('index < TransferFileManager.MAX_AUTOMATIC_NAMES') -and
    $transferFileManager.Contains("throw new Error('LOCAL_CONFLICT: no available automatic Downloads name')") -and
    $transferFileManager.Contains("tempName: string = '.leantty-'") -and
    $transferFileManager.Contains("if (prepared.tempPath.length > 0)") -and
    $transferFileManager.Contains('fs.unlinkSync(prepared.tempPath)')
) 'Downloads transfer ownership, no-follow, no-replace, bounded numbering, or cleanup contract regressed'
Assert-True (
    $commandBarViewModel.Contains('safeCompletionValue') -and
    $commandBarViewModel.Contains('TerminalTextPolicy.isSafe(value)') -and
    $terminalTextPolicy.Contains('code === 0x1B || code < 0x20') -and
    $terminalTextPolicy.Contains('(code >= 0x7F && code <= 0x9F)') -and
    $terminalTextPolicy.Contains('codePoint >= 0x202A && codePoint <= 0x202E') -and
    $terminalTextPolicy.Contains('codePoint >= 0x2066 && codePoint <= 0x206F') -and
    $terminalTextPolicy.Contains('codePoint >= 0xE0020 && codePoint <= 0xE007F') -and
    $commandBarViewModel.Contains('fs.listFileSync(path)') -and
    $commandBarViewModel.Contains('private static readonly MAX_COMPLETIONS: number = 100') -and
    -not $commandBarViewModel.Contains('DownloadsAccessManager') -and
    -not $commandBarViewModel.Contains('FileTransferClient') -and
    -not $commandBarViewModel.Contains('SshClient')
) 'Tab completion can prompt, connect, recurse, inject controls, or exceed its candidate boundary'
Assert-True (
    $sessionViewModel -match (
        'private finishCancelledFileTransfer\(\): void \{[\s\S]*?' +
        "this\.logger\.info\('FILE_TRANSFER result=cancelled'\)"
    ) -and
    $sessionViewModel -notmatch (
        "if \(event\.kind === 'cancelled'\) \{\s*" +
        "this\.logger\.info\('FILE_TRANSFER result=cancelled'\)"
    )
) 'Cancelled transfer terminal telemetry is not emitted exactly from the shared finish path'

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

Write-Host 'Device regression helper tests passed.' -ForegroundColor Green
