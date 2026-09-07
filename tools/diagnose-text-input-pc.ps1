<#
.SYNOPSIS
  Compare LeanTTY ordinary-text injection paths without submitting a command.
.DESCRIPTION
  Installs one exact signed diagnostic HAP, focuses the native command input,
  and compares focus-verified targeted UiTest inputText, focused UiTest text,
  and raw uinput key events. Every probe starts from a verified one-character
  baseline and reads the acceptance-only native command buffer. Enter is never
  injected.

  -Scenario pane-ownership instead exercises a disposable Tab through split,
  close-left, retained-right and split-again, then checks geometry and isolated
  native input buffers. It never changes the network or submits a command.

  -Scenario masked-input compares a public 32-character test vector at the idle
  prompt and in a disconnected acceptance-only password fixture. Only the
  fixture-start command is submitted; the test vector never is. This records
  lengths/equality and DOM/xterm counters, not credentials or event contents.
  This scenario runs one plain/masked pair; repeated fixture entry is not part
  of the input-delivery diagnostic.

  -Scenario ime-input checks physical English keys, system pinyin composition
  and repeated ASCII after composition in a disposable local Tab. No network,
  Agent, clipboard or Enter is used. It requires an English input-mode baseline.

  -Scenario input-order arms one content-free 20-second DOM/xterm trace in a
  disposable idle Tab. One public 31-character vector is injected, never
  submitted. Only the arming command uses Enter. No retry or network action.

  -Scenario input-attribution also observes xterm's original deferred callback.
  AttributionMode: 0=UiTest/plain textarea, 1=UiTest/xterm,
  2=real keyboard/plain textarea, 3=real keyboard/xterm,
  4=UiTest/xterm/Bridge/native chain (180 public characters). One vector only.
  5=post-window native summary, detailed IDLE logs on, Web trace off;
  6=same with detailed IDLE logs off; 7=same as 6 with Web chain trace on.
  Profiles 5-7 share one 23-second final oracle, never read logs during injection,
  and leave production/ACK logs enabled. They are not zero-overhead controls.
  Manual modes wait 60 seconds and never inject the vector on the operator's behalf.
  8=controlled synthetic DOM ordering, ten fixed sets of five single-character
  cases in the real ArkWeb/idle xterm; no UiTest vector or private-handler patch.

  This is diagnostic evidence, not product or release acceptance.
#>
[CmdletBinding()]
param(
    [string]$Target = '',
    [string]$HapPath = '',
    [string]$UnlockPasswordPath = '',
    [string]$EvidenceDirectory = '',
    [ValidateSet('ordinary-text', 'pane-ownership', 'masked-input', 'ime-input', 'input-order', 'input-attribution')][string]$Scenario = 'ordinary-text',
    [ValidateRange(0, 8)][int]$AttributionMode = 1,
    [ValidateRange(1, 30)][int]$Iterations = 10,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'hdc-common.ps1')
. (Join-Path $PSScriptRoot 'device-regression.ps1')
. (Join-Path $PSScriptRoot 'input-order-evidence.ps1')

function Get-TextInputMismatchIndex {
    param(
        [AllowEmptyString()][string]$Expected,
        [AllowEmptyString()][string]$Actual
    )

    $sharedLength = [Math]::Min($Expected.Length, $Actual.Length)
    for ($index = 0; $index -lt $sharedLength; $index++) {
        if ($Expected[$index] -cne $Actual[$index]) { return $index }
    }
    if ($Expected.Length -ne $Actual.Length) { return $sharedLength }
    return -1
}

function ConvertTo-LeanTTYRawTextKeyCommand {
    param([Parameter(Mandatory = $true)][string]$Text)

    $parts = [Collections.Generic.List[string]]::new()
    $parts.Add('uinput -K')
    foreach ($character in $Text.ToCharArray()) {
        $codePoint = [int][char]$character
        $keyCode = if ($character -ge 'a' -and $character -le 'z') {
            2017 + $codePoint - [int][char]'a'
        } elseif ($character -ge '0' -and $character -le '9') {
            2000 + $codePoint - [int][char]'0'
        } else {
            switch ($character) {
                ' ' { 2050 }
                '.' { 2044 }
                '-' { 2057 }
                '/' { 2064 }
                '@' { 2065 }
                default { throw "Unsupported raw diagnostic character: U+$($codePoint.ToString('X4'))" }
            }
        }
        $parts.Add("-d $keyCode -u $keyCode")
    }
    return $parts -join ' '
}

function Get-LastAcceptanceInputState {
    param([AllowEmptyString()][string]$Logs)

    $state = Get-LeanTTYAcceptanceIdleInputState -Logs $Logs
    if ($null -eq $state) { return $null }
    return $state.input
}

function Get-TextInputToolOutputClass {
    param([AllowEmptyString()][string]$Output)

    if ([string]::IsNullOrWhiteSpace($Output)) { return 'empty' }
    if ($Output -match '(?m)^Usage: uinput |(?m)^Usage: uitest ') { return 'usage' }
    if ($Output.Trim() -ceq 'No Error') { return 'no-error' }
    return 'other'
}

function Get-SingleFocusedDiagnosticInputNode {
    param([Parameter(Mandatory = $true)][object[]]$InputNodes)

    $focusedInputs = @($InputNodes | Where-Object {
            [string]$_.attributes.focused -eq 'true'
        })
    if ($focusedInputs.Count -ne 1) {
        throw '[environment] Diagnostic requires exactly one focused LeanTTY terminal input'
    }
    return $focusedInputs[0]
}

if ($SelfTest) {
    if ((Get-TextInputMismatchIndex -Expected 'abc' -Actual 'abc') -ne -1) {
        throw 'Exact text was reported as a mismatch'
    }
    if ((Get-TextInputMismatchIndex -Expected 'abc' -Actual 'ab') -ne 2) {
        throw 'Short write mismatch index is incorrect'
    }
    if ((Get-TextInputMismatchIndex -Expected 'abc' -Actual 'axc') -ne 1) {
        throw 'Substitution mismatch index is incorrect'
    }
    $rawCommand = ConvertTo-LeanTTYRawTextKeyCommand -Text 'a0 .-/@z'
    foreach ($expectedPart in @(
            '-d 2017 -u 2017', '-d 2000 -u 2000', '-d 2050 -u 2050',
            '-d 2044 -u 2044', '-d 2057 -u 2057', '-d 2064 -u 2064',
            '-d 2065 -u 2065', '-d 2042 -u 2042'
        )) {
        if (-not $rawCommand.Contains($expectedPart)) {
            throw "Raw key mapping is missing $expectedPart"
        }
    }
    $sampleLogs = @'
ACCEPTANCE_IDLE_RESULT kind=0,input=first,completionActive=false,menuActive=false
ACCEPTANCE_IDLE_RESULT kind=0,input=second value,completionActive=false,menuActive=false
'@
    if ((Get-LastAcceptanceInputState -Logs $sampleLogs) -cne 'second value') {
        throw 'Acceptance input parser did not return the last native buffer'
    }
    if ((Get-TextInputToolOutputClass -Output "Usage: uitest uiInput`nmore") -cne 'usage' -or
        (Get-TextInputToolOutputClass -Output 'No Error') -cne 'no-error' -or
        (Get-TextInputToolOutputClass -Output '') -cne 'empty') {
        throw 'Text input tool output classification is incorrect'
    }
    $focusedNode = [pscustomobject]@{ attributes = [pscustomobject]@{ focused = 'true' } }
    $unfocusedNode = [pscustomobject]@{ attributes = [pscustomobject]@{ focused = 'false' } }
    if ((Get-SingleFocusedDiagnosticInputNode -InputNodes @(
                $unfocusedNode, $focusedNode
            )) -ne $focusedNode) {
        throw 'Multi-pane diagnostic focus selection is incorrect'
    }
    & {
        $ast = [Management.Automation.Language.Parser]::ParseFile($PSCommandPath, [ref]$null, [ref]$null)
        $imeProbe = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Invoke-ImeInputProbe'
        }, $true)
        . ([scriptblock]::Create($imeProbe.Extent.Text))
        function Invoke-HdcChecked {
            param($Hdc, $Target, $Arguments, $Operation)
            $injectedCommands.Add([string]$Arguments[1])
        }
        function Clear-LeanTTYAppLogs { param($Hdc, $Target) }
        function Reset-LeanTTYDeviceCommandInput { param($Hdc, $Target, $ProcessId) }
        function Start-Sleep { param($Milliseconds) }
        function Wait-LeanTTYAcceptanceIdleInputState {
            param($Hdc, $Target, $ProcessId, $Expected, $TimeoutSeconds)
            return [pscustomobject]@{ input = $Expected; exact = -not ($failCjk -and $Expected -ceq '中文') }
        }
        foreach ($failCjk in @($false, $true)) {
            $injectedCommands = [Collections.Generic.List[string]]::new()
            $summary = [ordered]@{ attempts = @() }
            $failed = $false
            try { Invoke-ImeInputProbe -Summary $summary -InputNodeProvider { 'focused-controlled-node' } }
            catch { $failed = $true }
            if ($failed -ne $failCjk -or -not $summary.inputModeRestored -or
                @($injectedCommands | Where-Object { $_ -ceq 'uinput -K -d 2047 -u 2047' }).Count -ne 2 -or
                @($injectedCommands | Where-Object { $_ -match '\b2054\b' }).Count -ne 0 -or
                $summary.attempts.Count -ne $(if ($failCjk) { 2 } else { 3 })) {
                throw 'IME probe must stop on mismatch, restore mode and never inject Enter'
            }
        }
    }
    Write-Host 'Text input diagnostic self-test passed.' -ForegroundColor Green
    return
}

if ($Scenario -in @('masked-input', 'ime-input', 'input-order', 'input-attribution')) {
    if ($PSBoundParameters.ContainsKey('Iterations') -and $Iterations -ne 1) {
        throw 'This bounded input diagnostic runs once; omit -Iterations or use 1'
    }
    $Iterations = 1
}

if ([string]::IsNullOrWhiteSpace($HapPath)) {
    throw '-HapPath is required and must identify one exact signed diagnostic HAP'
}
$HapPath = [IO.Path]::GetFullPath($HapPath)
if (-not (Test-Path -LiteralPath $HapPath -PathType Leaf)) {
    throw "Diagnostic HAP not found: $HapPath"
}
if ((Split-Path $HapPath -Leaf) -match 'unsigned') {
    throw 'The physical diagnostic requires a signed HAP'
}

$startedAt = [DateTimeOffset]::UtcNow
if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
    $EvidenceDirectory = Join-Path $repoRoot (
        'build\verification\text-input-diagnostic-' + $startedAt.ToString('yyyyMMddTHHmmssfffZ')
    )
} else {
    $EvidenceDirectory = [IO.Path]::GetFullPath($EvidenceDirectory)
}
New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null
$resultPath = Join-Path $EvidenceDirectory 'text-input-diagnostic.json'
$preflightPath = Join-Path $EvidenceDirectory 'device-preflight.json'
$readyLayoutPath = Join-Path $EvidenceDirectory 'ready.json'

$hdc = Resolve-Hdc
$resolvedTarget = ''
$appProcessId = ''
$deviceAwakeLease = $false
$appStarted = $false
$runResult = 'failed'
$failure = ''
$failureDomain = ''
$cleanup = 'not-started'
$attempts = [Collections.Generic.List[object]]::new()
$device = [ordered]@{}
$paneOwnership = $null
$maskedInput = $null
$imeInput = $null
$inputOrder = $null
$candidate = [ordered]@{
    hapPath = $HapPath
    sha256 = (Get-FileHash -LiteralPath $HapPath -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Wait-DiagnosticInputState {
    param(
        [Parameter(Mandatory = $true)][string]$Expected,
        [ValidateRange(1, 15)][int]$TimeoutSeconds = 8
    )

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $lastActual = $null
    $lastChangeAt = 0L
    $logs = ''
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $logs = Get-LeanTTYAppLogs -Hdc $hdc -Target $resolvedTarget -ProcessId $appProcessId
        $actual = Get-LastAcceptanceInputState -Logs $logs
        if ($null -ne $actual) {
            if ($actual -ceq $Expected) {
                return [pscustomobject]@{
                    actual = $actual
                    observationMs = [int]$stopwatch.ElapsedMilliseconds
                    inputEvents = @([regex]::Matches($logs, 'D: 1 chars, mode=')).Count
                    stable = $true
                }
            }
            if ($null -eq $lastActual -or $actual -cne $lastActual) {
                $lastActual = $actual
                $lastChangeAt = $stopwatch.ElapsedMilliseconds
            } elseif (($stopwatch.ElapsedMilliseconds - $lastChangeAt) -ge 1000) {
                return [pscustomobject]@{
                    actual = $actual
                    observationMs = [int]$stopwatch.ElapsedMilliseconds
                    inputEvents = @([regex]::Matches($logs, 'D: 1 chars, mode=')).Count
                    stable = $true
                }
            }
        }
        Start-Sleep -Milliseconds 200
    }
    return [pscustomobject]@{
        actual = $(if ($null -eq $lastActual) { '' } else { $lastActual })
        observationMs = [int]$stopwatch.ElapsedMilliseconds
        inputEvents = @([regex]::Matches($logs, 'D: 1 chars, mode=')).Count
        stable = $false
    }
}

function Invoke-TargetedDiagnosticText {
    param(
        [Parameter(Mandatory = $true)]$InputNode,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $center = Get-LeanTTYBoundsCenter -Bounds ([string]$InputNode.attributes.bounds)
    return Invoke-LeanTTYSerializedUiTest `
        -Hdc $hdc -Target $resolvedTarget `
        -Arguments @('uiInput', 'inputText', $center.x, $center.y, $Text) `
        -Operation 'targeted diagnostic text input'
}

function Set-DiagnosticBaseline {
    param([Parameter(Mandatory = $true)]$InputNode)

    $sentinel = 'q'
    for ($baselineAttempt = 1; $baselineAttempt -le 3; $baselineAttempt++) {
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $resolvedTarget
        Invoke-LeanTTYDeviceCtrlC -Hdc $hdc -Target $resolvedTarget
        try {
            Wait-LeanTTYAppLog `
                -Hdc $hdc -Target $resolvedTarget -ProcessId $appProcessId `
                -Pattern 'ACCEPTANCE_IDLE_INTERRUPT cleared=true' `
                -TimeoutSeconds 5 | Out-Null
        } catch {
            continue
        }
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $resolvedTarget
        Invoke-TargetedDiagnosticText -InputNode $InputNode -Text $sentinel | Out-Null
        $state = Wait-DiagnosticInputState -Expected $sentinel
        if ($state.actual -ceq $sentinel) {
            return [pscustomobject]@{
                text = $sentinel
                attempts = $baselineAttempt
                observationMs = $state.observationMs
            }
        }
    }
    throw '[harness] Unable to establish the verified diagnostic input baseline'
}

function Invoke-DiagnosticAttempt {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$CaseName,
        [Parameter(Mandatory = $true)][int]$Iteration,
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)]$InputNode
    )

    Assert-HdcTargetReady -Hdc $hdc -Target $resolvedTarget | Out-Null
    $baseline = Set-DiagnosticBaseline -InputNode $InputNode
    $currentLayoutPath = Join-Path ([IO.Path]::GetTempPath()) (
        'leantty-text-diagnostic-' + [Guid]::NewGuid().ToString('N') + '.json'
    )
    try {
        $currentLayout = Wait-LeanTTYTerminalInputLayout `
            -Hdc $hdc -Target $resolvedTarget -LocalPath $currentLayoutPath
        $currentInputNode = Get-SingleFocusedDiagnosticInputNode `
            -InputNodes @(Get-LeanTTYTerminalInputNodes -Layout $currentLayout)
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $resolvedTarget
        $expected = $baseline.text + $Text
        $toolOutput = ''
        $injectionStopwatch = [Diagnostics.Stopwatch]::StartNew()
        switch ($Method) {
            'focus-verified-inputText' {
                Invoke-LeanTTYDeviceText `
                    -Hdc $hdc -Target $resolvedTarget `
                    -InputNode $currentInputNode -Text $Text
                $toolOutput = 'No Error'
            }
            'focused-text' {
                $toolOutput = Invoke-LeanTTYSerializedUiTest `
                    -Hdc $hdc -Target $resolvedTarget `
                    -Arguments @('uiInput', 'text', $Text) `
                    -Operation 'focused diagnostic text input'
            }
            'raw-key-burst' {
                $toolOutput = Invoke-HdcChecked `
                    -Hdc $hdc -Target $resolvedTarget `
                    -Arguments @('shell', (ConvertTo-LeanTTYRawTextKeyCommand -Text $Text)) `
                    -Operation 'raw diagnostic keyboard input' `
                    -FailureDomain 'environment'
            }
            default { throw "Unknown diagnostic method: $Method" }
        }
        $injectionStopwatch.Stop()
    } finally {
        Remove-Item -LiteralPath $currentLayoutPath -Force -ErrorAction SilentlyContinue
    }
    $state = Wait-DiagnosticInputState -Expected $expected
    $mismatchIndex = Get-TextInputMismatchIndex -Expected $expected -Actual $state.actual
    $attempts.Add([pscustomobject]@{
            method = $Method
            case = $CaseName
            iteration = $Iteration
            expected = $expected
            actual = $state.actual
            expectedLength = $expected.Length
            actualLength = $state.actual.Length
            exact = ($mismatchIndex -eq -1)
            firstMismatchIndex = $mismatchIndex
            injectionMs = [int]$injectionStopwatch.ElapsedMilliseconds
            observationMs = $state.observationMs
            inputEvents = $state.inputEvents
            observationStable = $state.stable
            baselineAttempts = $baseline.attempts
            toolOutputClass = Get-TextInputToolOutputClass -Output $toolOutput
            toolOutputLength = $toolOutput.Length
        })
}

function Get-TextInputDiagnosticClassification {
    $groups = @($attempts | Group-Object method)
    $counts = @{}
    foreach ($group in $groups) {
        $counts[$group.Name] = @($group.Group | Where-Object { -not $_.exact }).Count
    }
    foreach ($requiredMethod in @(
            'focus-verified-inputText', 'focused-text', 'raw-key-burst'
        )) {
        if (-not $counts.ContainsKey($requiredMethod)) {
            return 'incomplete-method-coverage'
        }
    }
    $targetedFailures = [int]$counts['focus-verified-inputText']
    $focusedFailures = [int]$counts['focused-text']
    $rawFailures = [int]$counts['raw-key-burst']
    if ($rawFailures -eq 0 -and ($targetedFailures -gt 0 -or $focusedFailures -gt 0)) {
        return 'uitest-text-injection-boundary'
    }
    if ($targetedFailures -eq 0 -and $focusedFailures -eq 0 -and $rawFailures -eq 0) {
        return 'not-reproduced-in-controlled-probe'
    }
    if ($rawFailures -gt 0) {
        return 'below-uitest-or-raw-burst-artifact-unresolved'
    }
    return 'path-specific-unresolved'
}

function Invoke-InputOrderDiagnostic {
    $synthetic = $Scenario -eq 'input-attribution' -and $AttributionMode -eq 8
    $observer = $Scenario -eq 'input-attribution' -and $AttributionMode -ge 5
    $chain = $Scenario -eq 'input-attribution' -and $AttributionMode -in 4, 7, 8
    $sample = if ($synthetic) { 'a' * 40 } elseif ($chain -or $observer) { 'ssh-keygen -R [127.0.0.1]:2223' * 6 } else { '0123456789abcdefghijklmnopqrstu' }
    $token = (Get-Random -Minimum 1000000 -Maximum 10000000).ToString()
    $result = [ordered]@{ result = 'running'; token = $token; expectedUnits = $sample.Length;
        vectorSubmitted = $false; vectorAttempts = 0; networkChanged = $false; credentialUsed = $false;
        cleanup = 'not-started'; trace = $null }
    $ownedTabId = ''
    $targetLost = $false
    $armingObservations = [Collections.Generic.List[object]]::new()
    $attribution = $Scenario -eq 'input-attribution'
    $manual = $attribution -and $AttributionMode -in 2, 3
    $plain = $attribution -and $AttributionMode -in 0, 2
    $result['attributionMode'] = $(if ($attribution) { $AttributionMode } else { -1 })
    function Get-OrderInputNode {
        $layout = Wait-LeanTTYTerminalInputLayout -Hdc $hdc -Target $resolvedTarget `
            -LocalPath (Join-Path $EvidenceDirectory 'input-order-focus.json')
        return Get-SingleFocusedDiagnosticInputNode -InputNodes @(Get-LeanTTYTerminalInputNodes -Layout $layout)
    }
    try {
        Get-OrderInputNode | Out-Null
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $resolvedTarget
        Invoke-HdcChecked -Hdc $hdc -Target $resolvedTarget `
            -Arguments @('shell', 'uinput -K -d 2072 -d 2047 -d 2036 -u 2036 -u 2047 -u 2072') `
            -Operation 'Create disposable input order Tab' | Out-Null
        $createdLogs = Wait-LeanTTYAppLog -Hdc $hdc -Target $resolvedTarget -ProcessId $appProcessId `
            -Pattern 'Tab added: ' -TimeoutSeconds 5
        $ownedTabId = [regex]::Match($createdLogs, 'Tab added: (\S+) title=').Groups[1].Value
        $result['ownedTabId'] = $ownedTabId
        $result['processId'] = $appProcessId
        if ($ownedTabId.Length -eq 0) { throw '[harness] Input order Tab identity missing' }
        $armCommand = if ($attribution) { '__acceptance_input_attribution_' + $AttributionMode + '_' + $token }
            else { '__acceptance_input_trace_' + $token }
        Submit-LeanTTYDeviceCommand -Hdc $hdc -Target $resolvedTarget -ProcessId $appProcessId `
            -Command $armCommand -Stage 'input-order-arm' `
            -MaxInputAttempts 1 -ObservationSink $armingObservations -InputNodeProvider { Get-OrderInputNode } | Out-Null
        $readyPattern = if ($observer) { 'ACCEPTANCE_OBSERVER_READY ' + $token + ';' + $AttributionMode }
            else { 'ACCEPTANCE_INPUT_ORDER ' + $token + ';0;0;0;' }
        Wait-LeanTTYAppLog -Hdc $hdc -Target $resolvedTarget -ProcessId $appProcessId `
            -Pattern $readyPattern -TimeoutSeconds 5 | Out-Null
        if ($observer -and $chain) {
            Wait-LeanTTYAppLog -Hdc $hdc -Target $resolvedTarget -ProcessId $appProcessId `
                -Pattern ('ACCEPTANCE_INPUT_ORDER ' + $token + ';0;0;0;') -TimeoutSeconds 5 | Out-Null
        }
        # Synthetic cases start in ArkWeb after arming; clearing now could erase
        # their completed reports. Do not inject a second vector or poll per case.
        if (-not $synthetic) { Clear-LeanTTYAppLogs -Hdc $hdc -Target $resolvedTarget }
        if ($synthetic) {
            $result['synthetic'] = [ordered]@{ kind = 'controlled-dom-order-in-production-xterm';
                fixedRepeats = 10; casesPerRepeat = 5; trusted = $false; deviceCauseProven = $false;
                stateReset = 'public-textarea-value-between-cases'; privateHandlersPatched = $false }
        } elseif ($manual) {
            Write-Host ('MANUAL INPUT READY: ' + $(if ($plain) { 'plain textarea' } else { 'xterm' }) +
                ', type ' + $sample + ' once, no Enter, paste or corrections; capture closes in 60 seconds.')
            & (Join-Path $PSScriptRoot 'play-operator-alert.ps1')
            $result['manualInputRequested'] = $true
        } else {
            $inputNode = if ($plain) {
                $plainLayout = Get-LeanTTYDeviceLayout -Hdc $hdc -Target $resolvedTarget `
                    -LocalPath (Join-Path $EvidenceDirectory 'input-order-focus.json')
                $plainNodes = @(Get-LeanTTYFocusedTextInputNodes -Layout $plainLayout)
                if ($plainNodes.Count -ne 1 -or
                    [string]$plainNodes[0].attributes.hint -cne 'LeanTTY input attribution') {
                    throw '[harness] Plain attribution textarea is not uniquely focused'
                }
                $plainNodes[0]
            } else { Get-OrderInputNode }
            $result.vectorAttempts = 1
            $injectionClock = [Diagnostics.Stopwatch]::StartNew()
            Invoke-LeanTTYDeviceText -Hdc $hdc -Target $resolvedTarget -InputNode $inputNode -Text $sample
            $result['injectionWithFocusChecksMs'] = [int]$injectionClock.ElapsedMilliseconds
        }
        # Wait for the bounded collector's stop report, never use a sleep as a pass oracle.
        $maxChunks = if ($chain) { 256 } else { 16 }
        $lastChunkPattern = (@(1..$maxChunks | ForEach-Object { "$(($_ - 1));$_" }) -join '|')
        $finalPattern = if ($observer) { 'ACCEPTANCE_OBSERVER_FINAL ' + $token + ';' }
            else { 'ACCEPTANCE_INPUT_ORDER ' + $token + ';[1-4];(?:' + $lastChunkPattern + ');' }
        $logs = Wait-LeanTTYAppLog -Hdc $hdc -Target $resolvedTarget -ProcessId $appProcessId `
            -Pattern $finalPattern `
            -TimeoutSeconds $(if ($manual) { 60 } else { 25 })
        $result.trace = if ($observer -and -not $chain) { $null } elseif ($attribution) {
            ConvertFrom-LeanTTYInputAttributionEvidence -Logs $logs -Token $token -Mode $(if ($synthetic) { 8 } elseif ($observer) { 4 } else { $AttributionMode })
        } else { ConvertFrom-LeanTTYInputOrderEvidence -Logs $logs -Token $token }
        if ($chain) {
            $receipts = @([regex]::Matches($logs, '(?m)ACCEPTANCE_INPUT_CHAIN_NATIVE ' + $token + ';([0-9]+);([0-9]+)\s*$'))
            if ($receipts.Count -ne 1) { throw '[harness] Input chain Surface receipt missing or duplicated' }
            $result['bridgeReceived'] = [ordered]@{ packets = [int]$receipts[0].Groups[1].Value;
                units = [int]$receipts[0].Groups[2].Value }
            $result['nativeSteps'] = @([regex]::Matches($logs, '(?m)^.*ACCEPTANCE_IDLE_RESULT[^\r\n]*') | ForEach-Object {
                $state = Get-LastAcceptanceInputState -Logs $_.Value
                if ($null -ne $state) {
                    [ordered]@{ units = $state.Length; exactPrefix = $sample.StartsWith($state, [StringComparison]::Ordinal);
                        firstMismatchIndex = Get-TextInputMismatchIndex -Expected $sample -Actual $state }
                }
            })
        }
        $native = Get-LastAcceptanceInputState -Logs $logs
        if ($observer) {
            $result['native'] = ConvertFrom-LeanTTYObserverEvidence -Logs $logs -Token $token -Profile $AttributionMode
            $result['observationProfile'] = [ordered]@{ webTrace = $chain -and -not $synthetic;
                webCaseSummaries = $synthetic; detailedIdleLogs = $AttributionMode -eq 5;
                productionAndAckLogs = $true; logsPolledDuringInjection = $synthetic; zeroOverhead = $false }
        } elseif ($plain) {
            $result['native'] = [ordered]@{ observed = $null -ne $native; expectedInput = $false }
        } else {
            if ($null -eq $native) { throw '[harness] Input order native buffer observation missing' }
            $result['native'] = [ordered]@{ units = $native.Length; exact = $native -ceq $sample;
                firstMismatchIndex = Get-TextInputMismatchIndex -Expected $sample -Actual $native }
        }
        if (($null -ne $result.trace -and -not $result.trace.complete) -or ($null -eq $result.trace -and -not $observer)) {
            throw '[harness] Input order window ended early or was empty'
        }
        if ($synthetic) {
            $badCases = @($result.trace.syntheticCases | Where-Object { $_.name -eq 'xterm-delayed-input' })
            $controls = @($result.trace.syntheticCases | Where-Object { $_.name -ne 'xterm-delayed-input' })
            $result.synthetic['missingCases'] = @($badCases | Where-Object { $_.domExact -and $_.outputUnits -eq 0 -and $_.keyDownSeenBeforeInput }).Count
            $result.synthetic['exactControls'] = @($controls | Where-Object { $_.domExact -and $_.outputExact }).Count
            $result.synthetic['downstreamAgrees'] = $result.native.units -eq $result.trace.summary.actualUnits -and
                $result.bridgeReceived.units -eq $result.trace.summary.actualUnits -and
                $result.native.firstMismatchIndex -eq $(if ($result.native.exact) { -1 } else { $result.native.units })
            $result.synthetic['mechanismReproduced'] = $result.synthetic.missingCases -eq 10 -and
                $result.synthetic.exactControls -eq 40 -and $result.synthetic.downstreamAgrees
        }
        $result.result = 'completed'
    } catch {
        $result.result = 'failed'
        $result['failure'] = $_.Exception.Message
        $result['textTargetFailure'] = $_.Exception.Data['LeanTTYTextInputFailure']
        $targetLost = $null -ne $result.textTargetFailure
        if ($attribution -and -not $observer -and $result.vectorAttempts -gt 0 -and $null -eq $result.trace) {
            try {
                $failedLogs = Wait-LeanTTYAppLog -Hdc $hdc -Target $resolvedTarget -ProcessId $appProcessId `
                    -Pattern ('ACCEPTANCE_INPUT_ORDER ' + $token + ';[1-4];') -TimeoutSeconds 25
                $result.trace = ConvertFrom-LeanTTYInputAttributionEvidence -Logs $failedLogs -Token $token -Mode $AttributionMode
            } catch { $result['traceFailure'] = $_.Exception.Message }
        }
    } finally {
        $result['armingObservations'] = @($armingObservations)
        try {
            if ($ownedTabId.Length -eq 0 -or $targetLost) {
                throw '[harness] Input order ownership uncertain; no further keys sent'
            }
            Get-OrderInputNode | Out-Null
            Reset-LeanTTYDeviceCommandInput -Hdc $hdc -Target $resolvedTarget -ProcessId $appProcessId
            Clear-LeanTTYAppLogs -Hdc $hdc -Target $resolvedTarget
            Invoke-HdcChecked -Hdc $hdc -Target $resolvedTarget `
                -Arguments @('shell', 'uinput -K -d 2072 -d 2047 -d 2039 -u 2039 -u 2047 -u 2072') `
                -Operation 'Close disposable input order Tab' | Out-Null
            Wait-LeanTTYAppLog -Hdc $hdc -Target $resolvedTarget -ProcessId $appProcessId `
                -Pattern ('Tab removed: ' + [regex]::Escape($ownedTabId)) -TimeoutSeconds 5 | Out-Null
            $result.cleanup = 'passed'
        } catch {
            $result.cleanup = 'failed'
            $result.result = 'failed'
            $result['cleanupFailure'] = $_.Exception.Message
        }
        $traceLayoutPath = Join-Path $EvidenceDirectory 'input-order-focus.json'
        if (Test-Path -LiteralPath $traceLayoutPath -PathType Leaf) {
            Remove-Item -LiteralPath $traceLayoutPath -Force
        }
    }
    return $result
}

function Invoke-ImeInputProbe {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Summary,
        [Parameter(Mandatory = $true)][scriptblock]$InputNodeProvider
    )
    $imeToggled = $false
    try {
        foreach ($phase in @('english-baseline', 'pinyin-commit', 'post-composition-ascii')) {
            & $InputNodeProvider | Out-Null
            if ($phase -eq 'pinyin-commit') {
                Reset-LeanTTYDeviceCommandInput -Hdc $hdc -Target $resolvedTarget -ProcessId $appProcessId
                Invoke-HdcChecked -Hdc $hdc -Target $resolvedTarget `
                    -Arguments @('shell', 'uinput -K -d 2047 -u 2047') `
                    -Operation 'Switch controlled IME probe to Chinese' | Out-Null
                $imeToggled = $true
                Start-Sleep -Milliseconds 400
            } elseif ($phase -eq 'post-composition-ascii') {
                Invoke-HdcChecked -Hdc $hdc -Target $resolvedTarget `
                    -Arguments @('shell', 'uinput -K -d 2047 -u 2047') `
                    -Operation 'Restore controlled IME probe to English' | Out-Null
                $imeToggled = $false
                Start-Sleep -Milliseconds 400
            }
            $keys = switch ($phase) {
                'english-baseline' { 'leanttyime' }
                'pinyin-commit' { 'zhongwen ' }
                'post-composition-ascii' { 'aa11' }
            }
            $expected = switch ($phase) {
                'english-baseline' { 'leanttyime' }
                'pinyin-commit' { '中文' }
                'post-composition-ascii' { '中文aa11' }
            }
            Clear-LeanTTYAppLogs -Hdc $hdc -Target $resolvedTarget
            Invoke-HdcChecked -Hdc $hdc -Target $resolvedTarget `
                -Arguments @('shell', (ConvertTo-LeanTTYRawTextKeyCommand -Text $keys)) `
                -Operation "System keyboard IME probe: $phase" | Out-Null
            & $InputNodeProvider | Out-Null
            $state = Wait-LeanTTYAcceptanceIdleInputState -Hdc $hdc -Target $resolvedTarget `
                -ProcessId $appProcessId -Expected $expected -TimeoutSeconds 5
            $Summary.attempts += [ordered]@{
                phase = $phase; expectedUnits = $expected.Length; actualUnits = $state.input.Length
                exact = $state.exact; inputMethod = 'system-key-events'; enterCount = 0
            }
            if (-not $state.exact) {
                throw "[harness] IME probe $phase mismatch; inspect input-mode/candidate precondition before attribution"
            }
        }
    } finally {
        if ($imeToggled) {
            Invoke-HdcChecked -Hdc $hdc -Target $resolvedTarget `
                -Arguments @('shell', 'uinput -K -d 2047 -u 2047') `
                -Operation 'Restore input mode after interrupted IME probe' | Out-Null
        }
        $Summary['inputModeRestored'] = $true
    }
}

function Invoke-LocalInputCompatibilityDiagnostic {
    # Fixed public data, never a credential. One plain/masked pair; no repeated fixture entry.
    $sample = '0123456789abcdefghijklmnopqrstuv'
    $result = [ordered]@{ result = 'running'; networkChanged = $false;
        credentialUsed = $false; vectorSubmitted = $false; attempts = @(); cleanup = 'not-started' }
    $ownedTab = $false
    $ownedTabId = ''
    function Get-ProbeInputNode {
        $layout = Wait-LeanTTYTerminalInputLayout -Hdc $hdc -Target $resolvedTarget `
            -LocalPath (Join-Path $EvidenceDirectory 'masked-probe-focus.json')
        return Get-SingleFocusedDiagnosticInputNode -InputNodes @(
            Get-LeanTTYTerminalInputNodes -Layout $layout
        )
    }
    try {
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $resolvedTarget
        Invoke-HdcChecked -Hdc $hdc -Target $resolvedTarget `
            -Arguments @('shell', 'uinput -K -d 2072 -d 2047 -d 2036 -u 2036 -u 2047 -u 2072') `
            -Operation 'Create disposable input diagnostic Tab' | Out-Null
        $ownedTab = $true
        $createdLogs = Wait-LeanTTYAppLog -Hdc $hdc -Target $resolvedTarget -ProcessId $appProcessId `
            -Pattern 'Tab added: ' -TimeoutSeconds 5
        $ownedTabId = [regex]::Match($createdLogs, 'Tab added: (\S+) title=').Groups[1].Value
        if ($ownedTabId.Length -eq 0) { throw '[harness] Disposable input Tab identity was not observed' }
        Get-ProbeInputNode | Out-Null
        $result['ownedTabId'] = $ownedTabId
        $iteration = 1
        Reset-LeanTTYDeviceCommandInput -Hdc $hdc -Target $resolvedTarget -ProcessId $appProcessId
        if ($Scenario -eq 'ime-input') {
            Invoke-ImeInputProbe -Summary $result -InputNodeProvider { Get-ProbeInputNode }
            $result.result = 'completed'
        } else {
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $resolvedTarget
        Invoke-LeanTTYDeviceText -Hdc $hdc -Target $resolvedTarget -InputNode (Get-ProbeInputNode) -Text $sample
        $plain = Wait-LeanTTYAcceptanceIdleInputState -Hdc $hdc -Target $resolvedTarget `
            -ProcessId $appProcessId -Expected $sample -TimeoutSeconds 5
        $result.attempts += [ordered]@{ mode = 'plain'; method = 'whole-32'; iteration = $iteration;
            bufferUnits = $plain.input.Length; exact = $plain.exact }
        Reset-LeanTTYDeviceCommandInput -Hdc $hdc -Target $resolvedTarget -ProcessId $appProcessId
        $method = 'whole-32'
        $result['lastStage'] = "iteration=$iteration,method=$method,phase=fixture-start"
        Submit-LeanTTYDeviceCommand -Hdc $hdc -Target $resolvedTarget -ProcessId $appProcessId `
            -Command '__acceptance_input_probe' -Stage 'masked-input-fixture-start' `
            -MaxInputAttempts 1 -InputNodeProvider { Get-ProbeInputNode } | Out-Null
        Wait-LeanTTYAppLog -Hdc $hdc -Target $resolvedTarget -ProcessId $appProcessId `
            -Pattern 'ACCEPTANCE_INPUT_PROBE state=ready' -TimeoutSeconds 5 | Out-Null
        Wait-LeanTTYAppLog -Hdc $hdc -Target $resolvedTarget -ProcessId $appProcessId `
            -Pattern 'ACCEPTANCE_INPUT_WEB 0,0,0,0,0,0,0,0,0,0,0,0' -TimeoutSeconds 5 | Out-Null
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $resolvedTarget
        $result['lastStage'] = 'whole-32-input'
        Invoke-LeanTTYDeviceText -Hdc $hdc -Target $resolvedTarget `
            -InputNode (Get-ProbeInputNode) -Text $sample
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $previous = ''
        $settled = $false
        do {
            $logs = Get-LeanTTYAppLogs -Hdc $hdc -Target $resolvedTarget -ProcessId $appProcessId
            $nativeEvents = [regex]::Matches($logs,
                'ACCEPTANCE_INPUT_NATIVE receivedUnits=\d+,bufferUnits=(\d+),exact=(true|false)')
            $webEvents = [regex]::Matches($logs, 'ACCEPTANCE_INPUT_WEB (\d+(?:,\d+){11})')
            if ($nativeEvents.Count -gt 0 -and $webEvents.Count -gt 0) {
                $nativeState = $nativeEvents[$nativeEvents.Count - 1]
                $webState = $webEvents[$webEvents.Count - 1].Groups[1].Value
                $signature = $nativeState.Value + $webState
                if ($signature -ceq $previous) { $settled = $true; break }
                $previous = $signature
            }
            Start-Sleep -Milliseconds 400
        } while ($timer.Elapsed.TotalSeconds -lt 5)
        if (-not $settled) { throw '[harness] Masked input boundary counters did not settle' }
        $counts = @($webState.Split(',') | ForEach-Object { [int]$_ })
        $result.attempts += [ordered]@{ mode = 'masked'; method = $method; iteration = $iteration;
            bufferUnits = [int]$nativeState.Groups[1].Value;
            exact = $nativeState.Groups[2].Value -ceq 'true';
            web = [ordered]@{ printableKeydowns = $counts[0]; imeKeydowns = $counts[1];
                keypresses = $counts[2]; inputEvents = $counts[3]; inputUnits = $counts[4];
                compositionEvents = $counts[5]; dataPrintableUnits = $counts[6];
                dataDeletes = $counts[7]; dataOtherUnits = $counts[8]; clearCalls = $counts[9];
                nonemptyClears = $counts[10]; textareaUnits = $counts[11] } }
        Write-Host "[masked-input] iteration=$iteration method=$method bufferUnits=$($nativeState.Groups[1].Value) exact=$($nativeState.Groups[2].Value)"
        $result.result = 'completed'
        }
    } catch {
        $result.result = 'failed'
        $result.failure = $_.Exception.Message
        $result.textTargetFailure = $_.Exception.Data['LeanTTYTextInputFailure']
    } finally {
        if ($ownedTab) {
          try {
            if ($ownedTabId.Length -eq 0) { throw '[harness] Cannot close an unidentified diagnostic Tab' }
            Invoke-LeanTTYDeviceCtrlC -Hdc $hdc -Target $resolvedTarget
            Reset-LeanTTYDeviceCommandInput -Hdc $hdc -Target $resolvedTarget -ProcessId $appProcessId
            Clear-LeanTTYAppLogs -Hdc $hdc -Target $resolvedTarget
            Invoke-HdcChecked -Hdc $hdc -Target $resolvedTarget `
                -Arguments @('shell', 'uinput -K -d 2072 -d 2047 -d 2039 -u 2039 -u 2047 -u 2072') `
                -Operation 'Close disposable input diagnostic Tab' | Out-Null
            Wait-LeanTTYAppLog -Hdc $hdc -Target $resolvedTarget -ProcessId $appProcessId `
                -Pattern ('Tab removed: ' + [regex]::Escape($ownedTabId)) -TimeoutSeconds 5 | Out-Null
            $result.cleanup = 'passed'
          } catch {
            $result.cleanup = 'failed'
            $result.result = 'failed'
            $result.cleanupFailure = $_.Exception.Message
          }
        }
    }
    return $result
}

function Invoke-PaneOwnershipDiagnostic {
    # Use disposable idle Panes and real keyboard controls. Never submit text,
    # connect a Session, or change the network in this boundary diagnostic.
    $result = [ordered]@{ result = 'running'; networkChanged = $false; enterCount = 0;
        stages = @(); inputBuffers = @(); cleanup = 'not-started' }
    $ownedPanes = 0
    function Send-PaneDiagnosticKey([string]$Keys) {
        Invoke-HdcChecked -Hdc $hdc -Target $resolvedTarget `
            -Arguments @('shell', "uinput -K $Keys") -Operation 'Pane diagnostic shortcut' | Out-Null
    }
    function Read-PaneDiagnosticLayout([string]$Name, [int]$Count) {
        $timer = [Diagnostics.Stopwatch]::StartNew()
        do {
            $current = Get-LeanTTYDeviceLayout -Hdc $hdc -Target $resolvedTarget `
                -LocalPath (Join-Path $EvidenceDirectory "$Name.json")
            $inputs = @(Get-LeanTTYTerminalInputNodes -Layout $current)
            if ($inputs.Count -eq $Count) { return $current }
            Start-Sleep -Milliseconds 200
        } while ($timer.Elapsed.TotalSeconds -lt 10)
        throw "[harness] Pane diagnostic expected $Count active inputs, observed $($inputs.Count)"
    }
    function Focus-PaneDiagnosticInput([int]$Index, [string]$Name) {
        $key = if ($Index -eq 0) { 2014 } else { 2015 }
        Send-PaneDiagnosticKey "-d 2072 -d 2045 -d $key -u $key -u 2045 -u 2072"
        $current = Read-PaneDiagnosticLayout $Name 2
        $inputs = @(Get-LeanTTYTerminalInputNodes -Layout $current)
        if ($inputs[$Index].attributes.focused -ne 'true' -or
            $inputs[1 - $Index].attributes.focused -eq 'true') {
            throw '[harness] Pane diagnostic shortcut did not select the intended owner'
        }
        return $inputs[$Index]
    }
    function Record-PaneDiagnosticStage([string]$Name, [int]$Count) {
        $current = Read-PaneDiagnosticLayout $Name $Count
        $inputs = @(Get-LeanTTYTerminalInputNodes -Layout $current)
        $webs = @(Get-LeanTTYLayoutNodes -Node $current | Where-Object { $_.attributes.type -eq 'Web' })
        $owners = @(foreach ($diagnosticInput in $inputs) {
            $webOwners = @($webs | Where-Object {
                ([string]$diagnosticInput.attributes.hierarchy).StartsWith(([string]$_.attributes.hierarchy) + ',')
            })
            if ($webOwners.Count -ne 1) { throw '[harness] Pane diagnostic Web owner is ambiguous' }
            [ordered]@{ bounds = [string]$webOwners[0].attributes.bounds;
                inputBounds = [string]$diagnosticInput.attributes.bounds;
                focused = [string]$diagnosticInput.attributes.focused; hierarchy = [string]$diagnosticInput.attributes.hierarchy }
        })
        $result.stages += [ordered]@{ name=$Name; owners=$owners }
        Save-LeanTTYDeviceScreenshot -Hdc $hdc -Target $resolvedTarget `
            -LocalPath (Join-Path $EvidenceDirectory "$Name.png")
        return ,$owners
    }
    function Check-PaneDiagnosticBuffer([string]$Name, [string]$Expected, [int]$SuffixKey) {
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $resolvedTarget
        Send-PaneDiagnosticKey "-d $SuffixKey -u $SuffixKey"
        $state = Wait-LeanTTYAcceptanceIdleInputState -Hdc $hdc -Target $resolvedTarget `
            -ProcessId $appProcessId -Expected $Expected -TimeoutSeconds 5
        $result.inputBuffers += [ordered]@{ name=$Name; expected=$Expected; actual=$state.input; exact=$state.exact }
        if (-not $state.exact) { throw '[product] Pane diagnostic native buffer was not isolated or retained' }
    }
    try {
        Send-PaneDiagnosticKey '-d 2072 -d 2047 -d 2036 -u 2036 -u 2047 -u 2072'
        $ownedPanes = 1
        $full = Record-PaneDiagnosticStage 'pane-new-tab' 1
        Send-PaneDiagnosticKey '-d 2072 -d 2047 -d 2020 -u 2020 -u 2047 -u 2072'
        $ownedPanes = 2
        Record-PaneDiagnosticStage 'pane-first-split' 2 | Out-Null
        Focus-PaneDiagnosticInput 1 'pane-right-before-close' | Out-Null
        Check-PaneDiagnosticBuffer 'right-baseline' 'r' 2034
        Focus-PaneDiagnosticInput 0 'pane-close-left' | Out-Null
        Reset-LeanTTYDeviceCommandInput -Hdc $hdc -Target $resolvedTarget -ProcessId $appProcessId
        Send-PaneDiagnosticKey '-d 2072 -d 2047 -d 2039 -u 2039 -u 2047 -u 2072'
        $ownedPanes = 1
        $single = Record-PaneDiagnosticStage 'pane-retained-single' 1
        if ($single[0].bounds -cne $full[0].bounds) {
            throw '[product] Retained right Pane did not fill the workspace after its sibling closed'
        }
        Check-PaneDiagnosticBuffer 'retained-right' 'rs' 2035
        Send-PaneDiagnosticKey '-d 2072 -d 2047 -d 2020 -u 2020 -u 2047 -u 2072'
        $ownedPanes = 2
        $pair = Record-PaneDiagnosticStage 'pane-resplit' 2
        $leftBounds = [regex]::Match($pair[0].bounds, '^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$')
        $rightBounds = [regex]::Match($pair[1].bounds, '^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$')
        if (-not $leftBounds.Success -or -not $rightBounds.Success -or
            [int]$leftBounds.Groups[3].Value -gt [int]$rightBounds.Groups[1].Value) {
            throw '[product] Retained and new Pane overlap after splitting again'
        }
        $diagnosticInput = Focus-PaneDiagnosticInput 0 'pane-before-coordinate-input'
        Invoke-LeanTTYDeviceText -Hdc $hdc -Target $resolvedTarget -InputNode $diagnosticInput -Text 'probe'
        Record-PaneDiagnosticStage 'pane-after-coordinate-input' 2 | Out-Null
        Check-PaneDiagnosticBuffer 'left-after-input' 'rsprobex' 2040
        Focus-PaneDiagnosticInput 1 'pane-right-after-input' | Out-Null
        Check-PaneDiagnosticBuffer 'right-after-input' 'y' 2041
        $result.result = 'passed'
    } catch {
        $result.result = 'failed'
        $result.failure = $_.Exception.Message
    } finally {
        try {
            for ($remaining = $ownedPanes; $remaining -gt 0; $remaining--) {
                if ($remaining -eq 2) { Focus-PaneDiagnosticInput 1 'pane-cleanup-right' | Out-Null }
                Reset-LeanTTYDeviceCommandInput -Hdc $hdc -Target $resolvedTarget -ProcessId $appProcessId
                Send-PaneDiagnosticKey '-d 2072 -d 2047 -d 2039 -u 2039 -u 2047 -u 2072'
                if ($remaining -eq 2) { Read-PaneDiagnosticLayout 'pane-cleanup-single' 1 | Out-Null }
            }
            $result.cleanup = 'passed'
        } catch {
            $result.cleanup = 'failed'
            $result.cleanupFailure = $_.Exception.Message
            $result.result = 'failed'
        }
    }
    return $result
}

try {
    $resolvedTarget = Resolve-LeanTTYRegressionTarget -Hdc $hdc -Target $Target
    $transport = Get-HdcTargetTransport -Hdc $hdc -Target $resolvedTarget
    if ($transport -ne 'usb') {
        throw "[environment] Text input diagnostic requires the physical USB target, got $transport"
    }

    & (Join-Path $PSScriptRoot 'preflight-device.ps1') `
        -Target $resolvedTarget `
        -EvidencePath $preflightPath
    if ($LASTEXITCODE -ne 0) { throw '[infrastructure] Device control preflight failed' }

    $device = [ordered]@{
        target = $resolvedTarget
        transport = $transport
        model = (Invoke-HdcShell $hdc $resolvedTarget 'param get const.product.model').Trim()
        softwareVersion = (
            Invoke-HdcShell $hdc $resolvedTarget 'param get const.product.software.version'
        ).Trim()
        apiVersion = (Invoke-HdcShell $hdc $resolvedTarget 'param get const.ohos.apiversion').Trim()
        abi = (Invoke-HdcShell $hdc $resolvedTarget 'param get const.product.cpu.abilist').Trim()
        uiTestVersion = (Invoke-HdcShell $hdc $resolvedTarget 'uitest --version').Trim()
    }

    . (Join-Path $PSScriptRoot 'device-package.ps1')
    Assert-LeanTTYDeviceHap -HapPath $HapPath -Purpose acceptance | Out-Null
    $installOutput = @(& $hdc -t $resolvedTarget install -r $HapPath 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $installOutput -match '(?i)\[Fail\]|error') {
        throw '[infrastructure] Diagnostic HAP installation failed'
    }

    Start-LeanTTYDeviceAwakeLease `
        -Hdc $hdc -Target $resolvedTarget -TimeoutMilliseconds 1800000
    $deviceAwakeLease = $true
    if ([string]::IsNullOrWhiteSpace($UnlockPasswordPath)) {
        $UnlockPasswordPath = Get-LeanTTYDeviceUnlockPasswordPath
    }
    $start = Start-LeanTTYRegressionApp `
        -Hdc $hdc -Target $resolvedTarget `
        -CredentialPath $UnlockPasswordPath `
        -RepositoryRoot $repoRoot
    $appProcessId = [string]$start.processId
    $appStarted = $true
    $device['unlock'] = [string]$start.unlock

    if ($Scenario -in @('input-order', 'input-attribution')) {
        $inputOrder = Invoke-InputOrderDiagnostic
        if ($inputOrder.result -ne 'completed') {
            throw $(if ($inputOrder.failure) { $inputOrder.failure } else { '[harness] Input order cleanup failed' })
        }
    } elseif ($Scenario -eq 'ime-input') {
        $imeInput = Invoke-LocalInputCompatibilityDiagnostic
        if ($imeInput.result -ne 'completed') {
            throw $(if ($imeInput.failure) { $imeInput.failure } else { '[harness] IME probe cleanup failed' })
        }
    } elseif ($Scenario -eq 'masked-input') {
        $maskedInput = Invoke-LocalInputCompatibilityDiagnostic
        if ($maskedInput.result -ne 'completed') {
            throw $(if ($maskedInput.failure) { $maskedInput.failure } else { '[harness] Masked input cleanup failed' })
        }
    } elseif ($Scenario -eq 'pane-ownership') {
        Wait-LeanTTYTerminalInputLayout -Hdc $hdc -Target $resolvedTarget -LocalPath $readyLayoutPath | Out-Null
        $paneOwnership = Invoke-PaneOwnershipDiagnostic
        if ($paneOwnership.result -ne 'passed') {
            throw $(if ($paneOwnership.failure) { $paneOwnership.failure } else { '[harness] Pane diagnostic cleanup failed' })
        }
    } else {
        $layout = Wait-LeanTTYTerminalInputLayout `
            -Hdc $hdc -Target $resolvedTarget -LocalPath $readyLayoutPath
        $inputNodes = @(Get-LeanTTYTerminalInputNodes -Layout $layout)
        $focusedInputs = @($inputNodes | Where-Object {
                [string]$_.attributes.focused -eq 'true'
            })
        if ($focusedInputs.Count -eq 0 -and $inputNodes.Count -gt 0) {
            $layout = Set-LeanTTYTerminalInputFocus `
                -Hdc $hdc -Target $resolvedTarget -InputNode $inputNodes[0] `
                -LocalPath $readyLayoutPath
            $inputNodes = @(Get-LeanTTYTerminalInputNodes -Layout $layout)
        }
        $inputNode = Get-SingleFocusedDiagnosticInputNode -InputNodes $inputNodes

        $boundaryIterations = [Math]::Max(1, [int][Math]::Ceiling($Iterations / 3.0))
        $cases = @(
            [pscustomobject]@{ name = 'short'; text = 'help'; iterations = $Iterations },
            [pscustomobject]@{ name = 'repeat-32'; text = ('a' * 32); iterations = $Iterations },
            [pscustomobject]@{
                name = 'punctuation'; text = '0123456789-./@0123456789-./@'; iterations = $Iterations
            },
            [pscustomobject]@{
                name = 'ssh-shaped'; text = 'ssh -p 22222 password@127.0.0.1'; iterations = $Iterations
            },
            [pscustomobject]@{ name = 'length-199'; text = ('abc123-./@' * 19) + 'abc123-./'; iterations = $boundaryIterations },
            [pscustomobject]@{ name = 'length-201'; text = ('abc123-./@' * 20) + 'a'; iterations = $boundaryIterations }
        )
        $methods = @('focus-verified-inputText', 'focused-text', 'raw-key-burst')
        foreach ($case in $cases) {
            for ($iteration = 1; $iteration -le $case.iterations; $iteration++) {
                foreach ($method in $methods) {
                    Write-Host (
                        "[text-input] method=$method case=$($case.name) " +
                        "iteration=$iteration/$($case.iterations)"
                    )
                    Invoke-DiagnosticAttempt `
                        -Method $method -CaseName $case.name -Iteration $iteration `
                        -Text $case.text -InputNode $inputNode
                }
            }
        }
    }
    $runResult = 'completed'
} catch {
    $failure = $_.Exception.Message
    $domainMatch = [regex]::Match(
        $failure,
        '^\[(?<domain>product|harness|environment|infrastructure)\]'
    )
    $failureDomain = if ($domainMatch.Success) {
        $domainMatch.Groups['domain'].Value
    } else {
        'harness'
    }
} finally {
    if ($appStarted) {
        & $hdc -t $resolvedTarget shell 'aa force-stop com.leantty.app' 2>$null | Out-Null
    }
    if ($deviceAwakeLease) {
        try {
            Stop-LeanTTYDeviceAwakeLease -Hdc $hdc -Target $resolvedTarget
            $cleanup = 'passed'
        } catch {
            $cleanup = 'failed: ' + $_.Exception.Message
            if ($runResult -eq 'completed') {
                $runResult = 'failed'
                $failureDomain = 'infrastructure'
                $failure = 'Device screen-timeout restoration failed'
            }
        }
    } else {
        $cleanup = 'not-required'
    }

    if ($null -ne $inputOrder -and $inputOrder.cleanup -ne 'passed') {
        $cleanup = 'failed'
    }
    if ($null -ne $imeInput -and $imeInput.cleanup -ne 'passed') { $cleanup = 'failed' }
    $methodSummaries = @($attempts | Group-Object method | ForEach-Object {
            $methodAttempts = @($_.Group)
            [ordered]@{
                method = $_.Name
                attempts = $methodAttempts.Count
                exact = @($methodAttempts | Where-Object exact).Count
                mismatches = @($methodAttempts | Where-Object { -not $_.exact }).Count
                maxInjectionMs = ($methodAttempts | Measure-Object injectionMs -Maximum).Maximum
                maxObservationMs = ($methodAttempts | Measure-Object observationMs -Maximum).Maximum
            }
        })
    $classification = if ($null -ne $imeInput) {
        if ($imeInput.result -eq 'completed') { 'system-ime-input-exact' }
        else { 'incomplete-system-ime-probe' }
    } elseif ($null -ne $inputOrder) {
        if ($inputOrder.result -ne 'completed') { 'incomplete-input-order-probe' }
        elseif ($AttributionMode -eq 8 -and $Scenario -eq 'input-attribution') {
            if ($inputOrder.synthetic.mechanismReproduced) { 'synthetic-order-mechanism-reproduced' }
            else { 'different-controlled-synthetic-result' }
        }
        elseif (($Scenario -eq 'input-attribution' -and $null -ne $inputOrder.trace -and -not $inputOrder.trace.summary.exact) -or
            ($inputOrder.native.Contains('exact') -and -not $inputOrder.native.exact)) { 'input-mismatch-observed-see-event-order' }
        else { 'not-reproduced-in-single-input-order-probe' }
    } elseif ($null -ne $maskedInput) {
        if ($maskedInput.result -ne 'completed') {
            'incomplete-boundary-probe'
        } elseif (@($maskedInput.attempts | Where-Object { -not $_.exact }).Count -gt 0) {
            'input-mismatch-observed-see-boundary-counters'
        } else { 'not-reproduced-in-controlled-probe' }
    } elseif ($null -ne $paneOwnership) {
        'pane-ownership-' + $paneOwnership.result
    } elseif ($attempts.Count -eq 0) {
        'no-diagnostic-attempts'
    } else {
        Get-TextInputDiagnosticClassification
    }
    $evidence = [ordered]@{
        schemaVersion = 1
        diagnostic = 'ordinary-text-input-boundary'
        scenario = $Scenario
        result = $runResult
        acceptanceEligible = $false
        productBehaviorClaimed = $false
        enterInjected = $(if ($null -ne $inputOrder) {
                @($inputOrder.armingObservations | Where-Object { $_.enterCount -gt 0 }).Count -gt 0
            } else { $Scenario -eq 'masked-input' })
        startedAt = $startedAt.ToString('o')
        completedAt = [DateTimeOffset]::UtcNow.ToString('o')
        durationMs = [int]([DateTimeOffset]::UtcNow - $startedAt).TotalMilliseconds
        candidate = $candidate
        device = $device
        iterations = $Iterations
        classification = $classification
        methodSummaries = $methodSummaries
        attempts = @($attempts)
        paneOwnership = $paneOwnership
        maskedInput = $maskedInput
        imeInput = $imeInput
        inputOrder = $inputOrder
        probeCleanup = $(if ($null -ne $inputOrder) { $inputOrder.cleanup }
            elseif ($null -ne $imeInput) { $imeInput.cleanup } else { 'not-applicable' })
        cleanup = $cleanup
        failureDomain = $failureDomain
        failure = $failure
    }
    [IO.File]::WriteAllText(
        $resultPath,
        (ConvertTo-Json -InputObject $evidence -Depth 12),
        [Text.UTF8Encoding]::new($false)
    )
}

if ($runResult -ne 'completed') {
    throw "Text input diagnostic failed: $failure (evidence=$resultPath)"
}
Write-Host (
    "TEXT INPUT DIAGNOSTIC COMPLETE: classification=" +
    "$classification, evidence=$resultPath"
) -ForegroundColor Green
