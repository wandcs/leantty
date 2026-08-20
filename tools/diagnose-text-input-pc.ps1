<#
.SYNOPSIS
  Compare LeanTTY ordinary-text injection paths without submitting a command.
.DESCRIPTION
  Installs one exact signed diagnostic HAP, focuses the native command input,
  and compares targeted UiTest inputText, focused UiTest text, and raw uinput
  key events. Every probe starts from a verified one-character baseline and
  reads the acceptance-only native command buffer. Enter is never injected.

  This is diagnostic evidence, not product or release acceptance.
#>
[CmdletBinding()]
param(
    [string]$Target = '',
    [string]$HapPath = '',
    [string]$UnlockPasswordPath = '',
    [string]$EvidenceDirectory = '',
    [ValidateRange(1, 30)][int]$Iterations = 10,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'hdc-common.ps1')
. (Join-Path $PSScriptRoot 'device-regression.ps1')

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
    Write-Host 'Text input diagnostic self-test passed.' -ForegroundColor Green
    return
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
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $resolvedTarget
    $expected = $baseline.text + $Text
    $toolOutput = ''
    $injectionStopwatch = [Diagnostics.Stopwatch]::StartNew()
    switch ($Method) {
        'targeted-inputText' {
            $toolOutput = Invoke-TargetedDiagnosticText -InputNode $InputNode -Text $Text
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
    foreach ($requiredMethod in @('targeted-inputText', 'focused-text', 'raw-key-burst')) {
        if (-not $counts.ContainsKey($requiredMethod)) {
            return 'incomplete-method-coverage'
        }
    }
    $targetedFailures = [int]$counts['targeted-inputText']
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

    $layout = Wait-LeanTTYTerminalInputLayout `
        -Hdc $hdc -Target $resolvedTarget -LocalPath $readyLayoutPath
    $inputNodes = @(Get-LeanTTYTerminalInputNodes -Layout $layout)
    if ($inputNodes.Count -ne 1) {
        throw '[environment] Diagnostic requires exactly one LeanTTY terminal input'
    }
    $layout = Set-LeanTTYTerminalInputFocus `
        -Hdc $hdc -Target $resolvedTarget -InputNode $inputNodes[0] `
        -LocalPath $readyLayoutPath
    $focusedInputs = @(Get-LeanTTYTerminalInputNodes -Layout $layout | Where-Object {
            [string]$_.attributes.focused -eq 'true'
        })
    if ($focusedInputs.Count -ne 1) {
        throw '[environment] Diagnostic could not prove one focused terminal input'
    }
    $inputNode = $focusedInputs[0]

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
    $methods = @('targeted-inputText', 'focused-text', 'raw-key-burst')
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
    $classification = if ($attempts.Count -eq 0) {
        'no-diagnostic-attempts'
    } else {
        Get-TextInputDiagnosticClassification
    }
    $evidence = [ordered]@{
        schemaVersion = 1
        diagnostic = 'ordinary-text-input-boundary'
        result = $runResult
        acceptanceEligible = $false
        productBehaviorClaimed = $false
        enterInjected = $false
        startedAt = $startedAt.ToString('o')
        completedAt = [DateTimeOffset]::UtcNow.ToString('o')
        durationMs = [int]([DateTimeOffset]::UtcNow - $startedAt).TotalMilliseconds
        candidate = $candidate
        device = $device
        iterations = $Iterations
        classification = $classification
        methodSummaries = $methodSummaries
        attempts = @($attempts)
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
    "$(Get-TextInputDiagnosticClassification), evidence=$resultPath"
) -ForegroundColor Green
