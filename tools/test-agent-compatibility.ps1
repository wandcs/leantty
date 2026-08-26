param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'rust-wsl.ps1')
. (Join-Path $PSScriptRoot 'agent-compatibility-policy.ps1')

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) { throw $Message }
}

$temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) (
    'leantty-agent-compat-test-' + [Guid]::NewGuid().ToString('N')
)
New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null
try {
    $strictPass = Resolve-LeanTTYAgentNotificationAssessment `
        -Agent codex -Mode direct `
        -NativeAttentionObserved $true `
        -SystemNotificationCompleted $true `
        -AgentChildExitCode 0
    Assert-True (
        $strictPass.status -eq 'passed' -and
        $strictPass.classification -eq 'verified' -and
        $strictPass.systemNotification -eq 'passed'
    ) 'Codex direct notification must remain a strict verified path'

    $strictFailure = Resolve-LeanTTYAgentNotificationAssessment `
        -Agent opencode -Mode direct `
        -NativeAttentionObserved $true `
        -SystemNotificationCompleted $false `
        -AgentChildExitCode 0 `
        -NotificationFailure '[product] Agent emitted native attention but LeanTTY did not publish it'
    Assert-True (
        $strictFailure.status -eq 'failed' -and
        $strictFailure.failureDomain -eq 'product'
    ) 'OpenCode direct must fail when an emitted native signal is not published'

    $openCodeTmux = Resolve-LeanTTYAgentNotificationAssessment `
        -Agent opencode -Mode tmux `
        -NativeAttentionObserved $false `
        -SystemNotificationCompleted $false `
        -AgentChildExitCode 0 `
        -NotificationFailure '[external-agent] Agent exited without native attention, childExitCode=0'
    Assert-True (
        $openCodeTmux.status -eq 'passed' -and
        $openCodeTmux.classification -eq 'not-emitted-by-agent' -and
        $openCodeTmux.nativeAttention -eq 'not-observed' -and
        $openCodeTmux.systemNotification -eq 'not-exercised'
    ) 'OpenCode tmux must record the upstream no-emission boundary without claiming notification pass'

    $openCodeTmuxCrash = Resolve-LeanTTYAgentNotificationAssessment `
        -Agent opencode -Mode tmux `
        -NativeAttentionObserved $false `
        -SystemNotificationCompleted $false `
        -AgentChildExitCode 1 `
        -NotificationFailure '[external-agent] Agent exited without native attention, childExitCode=1'
    Assert-True (
        $openCodeTmuxCrash.status -eq 'failed' -and
        $openCodeTmuxCrash.classification -eq 'unexpected-failure'
    ) 'OpenCode tmux no-emission classification must not hide an Agent process failure'

    foreach ($platformCase in @(
        @{ agent = 'pi'; mode = 'direct' },
        @{ agent = 'pi'; mode = 'tmux' },
        @{ agent = 'qwen'; mode = 'direct' }
    )) {
        $assessment = Resolve-LeanTTYAgentNotificationAssessment `
            -Agent $platformCase.agent -Mode $platformCase.mode `
            -NativeAttentionObserved $true `
            -SystemNotificationCompleted $false `
            -AgentChildExitCode 0 `
            -NotificationFailure '[product] Agent emitted native attention but LeanTTY did not publish it'
        Assert-True (
            $assessment.status -eq 'passed' -and
            $assessment.classification -eq 'platform-deferred' -and
            $assessment.nativeAttention -eq 'observed' -and
            $assessment.systemNotification -eq 'not-observed'
        ) "$($platformCase.agent) $($platformCase.mode) must preserve the background lifecycle limitation"
    }

    $missingPiSignal = Resolve-LeanTTYAgentNotificationAssessment `
        -Agent pi -Mode direct `
        -NativeAttentionObserved $false `
        -SystemNotificationCompleted $false `
        -AgentChildExitCode 0 `
        -NotificationFailure '[external-agent] Agent exited without native attention, childExitCode=0'
    Assert-True (
        $missingPiSignal.status -eq 'failed' -and
        $missingPiSignal.failureDomain -eq 'compatibility'
    ) 'Pi must still emit its expected native attention signal'

    $privacyFailure = Resolve-LeanTTYAgentNotificationAssessment `
        -Agent pi -Mode tmux `
        -NativeAttentionObserved $true `
        -SystemNotificationCompleted $false `
        -AgentChildExitCode 0 `
        -NotificationFailure '[privacy] Agent notification exposed source or workload information'
    Assert-True (
        $privacyFailure.status -eq 'failed' -and
        $privacyFailure.failureDomain -eq 'privacy'
    ) 'Applicability policy must not downgrade notification privacy failures'

    $sentinelPath = Join-Path $temporaryDirectory '.leantty-agent-compat'
    [IO.File]::WriteAllText(
        $sentinelPath,
        "controlled-pty-capture`n",
        [Text.UTF8Encoding]::new($false)
    )
    $inputPath = Join-Path $temporaryDirectory 'controlled.input'
    $outputPath = Join-Path $temporaryDirectory 'controlled.output'
    $resultPath = Join-Path $temporaryDirectory 'result.json'
    $inputFixture = [byte[]](0x1b,0x5b,0x32,0x30,0x30,0x7e,0xe4,0xb8,0xad,0xe6,0x96,0x87,
        0x1b,0x5b,0x32,0x30,0x31,0x7e,
        0x1b,0x5b,0x4f,0x1b,0x5b,0x49,0x0d)
    $escape = [char]27
    $inputFixture += [Text.Encoding]::ASCII.GetBytes(
        'leanttyime' + $escape + ']99;i=opentui-notifications:p=?;p=title,body' + $escape + '\'
    )
    [IO.File]::WriteAllBytes($inputPath, $inputFixture)
    $outputFixture = [byte[]](0x1b,0x5b,0x3f,0x31,0x30,0x34,0x39,0x68,
            0x1b,0x5d,0x39,0x3b,0x61,0x74,0x74,0x65,0x6e,0x74,0x69,0x6f,0x6e,0x07,
            0x1b,0x5d,0x35,0x32,0x3b,0x63,0x3b,0x59,0x51,0x3d,0x3d,0x07,
            0x07,
            0x1b,0x5b,0x3f,0x31,0x30,0x34,0x39,0x6c)
    $outputFixture += [Text.Encoding]::ASCII.GetBytes(
        $escape + ']99;i=query:p=?;' + $escape + '\'
    )
    $outputFixture += [Text.Encoding]::ASCII.GetBytes(
        $escape + ']99;i=opentui-1:p=title:e=1:d=0;VGl0bGU=' + $escape + '\'
    )
    $outputFixture += [Text.Encoding]::ASCII.GetBytes(
        $escape + ']99;i=opentui-1:p=body:e=1:d=1;UmVhZHk=' + $escape + '\'
    )
    $outputFixture += [Text.Encoding]::ASCII.GetBytes(
        $escape + ']8;;' + $escape + '\' +
        $escape + ']8;;https://example.invalid/agent-contract' + $escape + '\' +
        'Agent contract' +
        $escape + ']8;;' + $escape + '\'
    )
    $outputFixture += [Text.Encoding]::ASCII.GetBytes(
        $escape + 'Ptmux;' +
        $escape + $escape + ']8;;https://example.invalid/tmux-agent-contract' + [char]7 +
        'tmux Agent contract' +
        $escape + $escape + ']8;;' + [char]7 +
        $escape + '\'
    )
    [IO.File]::WriteAllBytes($outputPath, $outputFixture)

    $wslRoot = ConvertTo-LeanTTYWslPath -WindowsPath $temporaryDirectory
    $analyzer = ConvertTo-LeanTTYWslPath `
        -WindowsPath (Join-Path $PSScriptRoot 'agent-compatibility\analyze_capture.py')
    & wsl.exe --exec python3 $analyzer `
        --run-root $wslRoot `
        --name controlled `
        --input "$wslRoot/controlled.input" `
        --output "$wslRoot/controlled.output" `
        --result "$wslRoot/result.json" `
        --child-exit-code 0 `
        --delete-raw
    if ($LASTEXITCODE -ne 0) { throw 'Agent compatibility capture analyzer failed' }

    $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -Depth 20
    Assert-True ($result.input.containsCjkUtf8) 'Analyzer did not observe controlled CJK input'
    Assert-True (
        $result.input.bracketedPasteStartCount -eq 1 -and
        $result.input.bracketedPasteEndCount -eq 1
    ) 'Analyzer did not summarize bracketed paste input'
    Assert-True (
        $result.input.focusReporting.outCount -eq 1 -and
        $result.input.focusReporting.inCount -eq 1
    ) 'Analyzer did not summarize terminal focus-report input'
    Assert-True (
        $result.input.osc99CapabilityResponseCount -eq 1
    ) 'Analyzer did not summarize the content-free OSC 99 capability response'
    Assert-True (
        $result.input.containsControlledEnglishMarker
    ) 'Analyzer did not summarize controlled physical English input'
    Assert-True (
        $result.output.alternateScreen.enterCount -eq 1 -and
        $result.output.alternateScreen.exitCount -eq 1
    ) 'Analyzer did not summarize alternate-screen transitions'
    Assert-True (
        $result.output.oscCounts.'9' -eq 1 -and
        $result.output.oscCounts.'99' -eq 3 -and
        $result.output.osc99AttentionFrameCount -eq 1 -and
        $result.output.osc99IgnoredFrameCount -eq 2 -and
        $result.output.oscCounts.'8' -eq 5 -and
        $result.output.osc8HyperlinkCount -eq 2 -and
        $result.output.osc8ResetCount -eq 3 -and
        $result.output.osc52ClipboardCount -eq 1 -and
        $result.output.belCount -eq 1 -and
        $result.output.oscBelTerminatorCount -eq 4 -and
        $result.output.nativeAttentionSignalKinds -contains 'bel' -and
        $result.output.nativeAttentionSignalKinds -contains 'osc-9' -and
        $result.output.nativeAttentionSignalKinds -contains 'osc-99'
    ) 'Analyzer did not distinguish BEL, OSC 8 open/reset, OSC 9, complete OSC 99 and OSC 52'
    Assert-True (
        -not (Test-Path -LiteralPath $inputPath) -and
        -not (Test-Path -LiteralPath $outputPath) -and
        -not $result.privacy.rawInputRetained -and
        -not $result.privacy.rawOutputRetained
    ) 'Analyzer retained raw controlled PTY content'

    $wslHarness = ConvertTo-LeanTTYWslPath `
        -WindowsPath (Join-Path $PSScriptRoot 'agent-compatibility-wsl.sh')
    & wsl.exe --exec bash $wslHarness prepare $wslRoot
    if ($LASTEXITCODE -ne 0) { throw 'Agent compatibility PTY harness prepare failed' }
    $osc99ProbeTest = ConvertTo-LeanTTYWslPath `
        -WindowsPath (Join-Path $PSScriptRoot 'agent-compatibility\test_osc99_probe.py')
    & wsl.exe --exec python3 $osc99ProbeTest $wslHarness $wslRoot
    if ($LASTEXITCODE -ne 0) { throw 'OSC 99 capability response probe self-test failed' }
    $osc99ProbeResult = Get-Content -LiteralPath (
        Join-Path $temporaryDirectory 'results\osc99-capability-probe.json'
    ) -Raw | ConvertFrom-Json -Depth 10
    Assert-True (
        $osc99ProbeResult.plannedModelRequests -eq 0 -and
        $osc99ProbeResult.responseObserved -and
        $osc99ProbeResult.responseCount -eq 1 -and
        $osc99ProbeResult.inputIsTty -and
        $null -eq $osc99ProbeResult.errorKind -and
        -not $osc99ProbeResult.privacy.rawResponseRetained
    ) 'OSC 99 probe did not prove its zero-model, raw-free pseudo-terminal contract'
    & wsl.exe --exec env HTTP_PROXY=http://127.0.0.1:1 `
        bash $wslHarness environment $wslRoot
    if ($LASTEXITCODE -ne 0) { throw 'Agent compatibility network environment probe failed' }
    $networkResult = Get-Content -LiteralPath (
        Join-Path $temporaryDirectory 'results\network-environment.json'
    ) -Raw | ConvertFrom-Json -Depth 10
    Assert-True (
        $networkResult.variableNames -contains 'HTTP_PROXY' -and
        -not $networkResult.valuesIncludedInEvidence
    ) 'Agent compatibility evidence exposed or omitted the controlled proxy environment contract'
    & wsl.exe --exec env LEANTTY_AGENT_COMPAT_CONTROLLED_CAPTURE=1 `
        bash $wslHarness capture $wslRoot harness-probe -- `
        /usr/bin/printf controlled-probe | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Agent compatibility PTY harness probe failed' }
    $harnessResult = Get-Content -LiteralPath (
        Join-Path $temporaryDirectory 'results\harness-probe.json'
    ) -Raw | ConvertFrom-Json -Depth 20
    Assert-True (
        $harnessResult.childExitCode -eq 0 -and
        $harnessResult.output.bytes -gt 0 -and
        -not $harnessResult.output.nativeAttentionSignalObserved -and
        -not $harnessResult.privacy.rawInputRetained -and
        -not $harnessResult.privacy.rawOutputRetained
    ) 'Agent compatibility PTY harness did not produce a raw-free controlled summary'

    $wslScript = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'agent-compatibility-wsl.sh') -Raw
    Assert-True (
        $wslScript.Contains('LEANTTY_AGENT_COMPAT_CONTROLLED_CAPTURE') -and
        $wslScript.Contains('--delete-raw') -and
        $wslScript.Contains('--output-limit 16MiB') -and
        $wslScript.Contains('probe RUN_ROOT CAPTURE_NAME') -and
        $wslScript.Contains('termios-probe RUN_ROOT CAPTURE_NAME SAMPLE_NAME') -and
        $wslScript.Contains('"rawMode": not canonical and not echo') -and
        $wslScript.Contains('"rawTermiosRetained": False') -and
        $wslScript.Contains('^(notification|input|interaction|protocol)$') -and
        $wslScript.Contains('printf "%%s\\n" "$(tty)"') -and
        $wslScript.Contains('osc99-probe RUN_ROOT') -and
        $wslScript.Contains('osc99_capability_probe.py') -and
        $wslScript.Contains('environment RUN_ROOT') -and
        $wslScript.Contains('source "$run_root/agent-network.env"') -and
        $wslScript.Contains('tui.notification_method="bel"') -and
        $wslScript.Contains('project_root_markers=[]') -and
        $wslScript.Contains('projects={\"$run_root\"={trust_level=\"trusted\"}') -and
        $wslScript.Contains('for agent in codex opencode pi qwen') -and
        $wslScript.Contains('examples/extensions/notify.ts') -and
        $wslScript.Contains('--no-tools') -and
        $wslScript.Contains('--no-session') -and
        $wslScript.Contains('--thinking minimal') -and
        $wslScript.Contains('QWEN_CODE_SYSTEM_SETTINGS_PATH') -and
        $wslScript.Contains('qwen-protocol-settings.json') -and
        $wslScript.Contains('export FORCE_HYPERLINK=1') -and
        $wslScript.Contains('"useTerminalBuffer": true') -and
        $wslScript.Contains('"mouseTracking": false') -and
        $wslScript.Contains('[LeanTTY protocol](https://example.invalid/leantty-agent-protocol)') -and
        $wslScript.Contains('"terminalBell": true') -and
        $wslScript.Contains('"notificationMode": "all"') -and
        $wslScript.Contains('"chatRecording": false') -and
        $wslScript.Contains('touch .leantty-agent-done') -and
        $wslScript.Contains('set -g focus-events on') -and
        $wslScript.Contains('--max-tool-calls 1') -and
        $wslScript.Contains('--max-wall-time 60s') -and
        $wslScript.Contains('"attention"') -and
        $wslScript.Contains('export OPENCODE_CONFIG_DIR="$run_root/opencode-config"') -and
        $wslScript.Contains('"$run_root/opencode-config/tui.json"') -and
        $wslScript.Contains('unset OPENCODE_CONFIG OPENCODE_CONFIG_CONTENT') -and
        $wslScript.Contains('LEANTTY_OPENCODE_FORCE_OSC99_PROTOCOL') -and
        $wslScript.Contains('OPENTUI_NOTIFICATION_PROTOCOL=osc99') -and
        $wslScript.Contains('sleep 12') -and
        -not $wslScript.Contains('claude') -and
        -not $wslScript.Contains('gemini') -and
        -not $wslScript.Contains('printf ''\a''')
    ) 'WSL capture entry does not enforce controlled, content-free native-signal evidence'

    $deviceScript = Get-Content -LiteralPath (
        Join-Path $PSScriptRoot 'verify-agent-compatibility-pc.ps1'
    ) -Raw
    $deploymentIndex = $deviceScript.IndexOf("'dev-pc.ps1'")
    $publicKeyIndex = $deviceScript.IndexOf("id_ed25519.pub' 2>&1")
    Assert-True (
        $deploymentIndex -ge 0 -and
        $publicKeyIndex -gt $deploymentIndex
    ) 'Agent device fixture reads app state before deploying the exact diagnostic HAP'
    Assert-True (
        $deviceScript.Contains("Wait-File -Path `$shellReadyPath") -and
        $deviceScript.Contains('bash --noprofile --rcfile') -and
        $deviceScript.Contains("export LANG='C.UTF-8'") -and
        $deviceScript.Contains("export LC_ALL='C.UTF-8'") -and
        $deviceScript.Contains('locale charmap > ''$wslLocaleProbePath''') -and
        $deviceScript.Contains('Controlled SSH shell is not using a UTF-8 locale') -and
        $deviceScript.Contains("terminalLocale = 'pending'") -and
        $deviceScript.Contains('lat $Agent $Mode notification') -and
        $deviceScript.Contains('lat() {') -and
        $deviceScript.Contains('[switch]$Osc99CapabilityProbe') -and
        $deviceScript.Contains('[switch]$InteractionOnlyProbe') -and
        $deviceScript.Contains('[switch]$ProtocolInteractionProbe') -and
        $deviceScript.Contains('[switch]$OpenCodeForceOsc99Protocol') -and
        $deviceScript.Contains('[switch]$DiagnosticHap') -and
        $deviceScript.Contains('Resolve-LeanTTYRetainedCandidate') -and
        $deviceScript.Contains('Assert-LeanTTYCandidateHarnessCompatibility') -and
        $deviceScript.Contains('agent-compatibility-policy.ps1') -and
        $deviceScript.Contains('harnessDifferencePaths') -and
        $deviceScript.Contains('gitCommit') -and
        $deviceScript.Contains('gitTree') -and
        $deviceScript.Contains('gitDirty') -and
        $deviceScript.Contains("@('OPENTUI_NOTIFICATION_PROTOCOL=osc99')") -and
        $deviceScript.Contains('function Invoke-Osc99CapabilityProbeCheck') -and
        $deviceScript.Contains('function Invoke-AgentInteractionOnlyCheck') -and
        $deviceScript.Contains('function Invoke-AgentProtocolInteractionCheck') -and
        $deviceScript.Contains('function Wait-AgentOsc52ClipboardCapture') -and
        $deviceScript.Contains('sudo kill -TERM -- $wslSshdPid') -and
        $deviceScript.Contains('sudo kill -0 -- $wslSshdPid') -and
        $deviceScript.Contains('sudo kill -KILL -- $wslSshdPid') -and
        $deviceScript.Contains("-Text '/copy'") -and
        $deviceScript.Contains("-Text '!seq 1 120'") -and
        $deviceScript.Contains('OSC 52 clipboard write success=true') -and
        $deviceScript.Contains('Qwen PageUp did not visibly change') -and
        $deviceScript.Contains("'uinput -K -d 2072 -d 2082 -u 2082 -u 2072'") -and
        $deviceScript.Contains("ctrlEndRestoration = 'recorded-for-visual-review'") -and
        $deviceScript.Contains('function Invoke-AgentPhysicalImeProbe') -and
        $deviceScript.Contains('physical-harmony-ime-composition') -and
        $deviceScript.Contains('Physical English input did not reach the Agent PTY') -and
        $deviceScript.Contains('Physical HarmonyOS IME composition did not reach the Agent PTY') -and
        $deviceScript.Contains('function Get-AgentTermiosSample') -and
        $deviceScript.Contains('zero-model-agent-tui-raw-alternate-resize') -and
        $deviceScript.Contains('function Wait-AgentTuiReady') -and
        $deviceScript.Contains('-Name "$stage-interactive-prompt"') -and
        $deviceScript.Contains('sleep 12. Do not use any other tool.') -and
        $deviceScript.Contains("-Command 'lat_osc99_probe'") -and
        $deviceScript.Contains("'osc99-capability-response'") -and
        $deviceScript.Contains('plannedModelRequests = 0') -and
        -not $deviceScript.Contains('bash --noprofile --norc --rcfile')
    ) 'Agent device fixture can suppress its controlled Bash rcfile'
    Assert-True (
        $deviceScript.Contains('Agent exited without native attention') -and
        $deviceScript.Contains('Agent emitted native attention but LeanTTY did not publish it') -and
        $deviceScript.Contains("[ValidateSet('codex', 'opencode', 'pi', 'qwen')]") -and
        $deviceScript.Contains("'opencode' { return 'osc-99' }") -and
        $deviceScript.Contains("'pi' { return 'osc-777' }") -and
        $deviceScript.Contains("'qwen' { return 'bel' }") -and
        $deviceScript.Contains('Reset-AppAfterAgentFailure') -and
        $deviceScript.Contains('Restore-AgentAppForContinuation') -and
        $deviceScript.Contains('Save-CurrentAppLogs') -and
        $deviceScript.Contains('rawCaptureDeletedBeforeEvidenceCopy') -and
        $deviceScript.Contains("Invoke-AgentWorkspaceChord -Action 'new-tab'") -and
        $deviceScript.Contains("Invoke-AgentWorkspaceChord -Action 'close-active'") -and
        $deviceScript.Contains('Expected one active terminal input') -and
        $deviceScript.Contains('Temporary WSL sshd PID is missing or malformed') -and
        $deviceScript.Contains('Temporary WSL sshd identity did not match its run-scoped config') -and
        $deviceScript.Contains('Temporary WSL sshd remained alive after TERM and KILL') -and
        $deviceScript.Contains('Temporary WSL sshd TERM failed') -and
        $deviceScript.Contains('sudo kill -0 -- $wslSshdPid') -and
        $deviceScript.Contains("-Text '/exit'") -and
        $deviceScript.Contains('Stop-AgentTui -Agent $Agent') -and
        $deviceScript.Contains("'aa force-stop com.leantty.app'") -and
        $deviceScript.Contains("Join-Path `$EvidenceDirectory 'captures'") -and
        -not $deviceScript.Contains("'claude'") -and
        -not $deviceScript.Contains("'gemini'")
    ) 'Agent device fixture can lose the original failure or raw-free capture summary'
} finally {
    if (Test-Path -LiteralPath $temporaryDirectory) {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
    }
}

Write-Host 'Agent compatibility helper tests passed.'
