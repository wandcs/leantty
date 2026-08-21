param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'LeanTTY-build-workflow-test-' + [Guid]::NewGuid().ToString('N')
)

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$Message
    )

    try {
        & $Action
    } catch {
        return
    }
    throw $Message
}

function Wait-ForPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateRange(1, 30)][int]$TimeoutSeconds = 5
    )

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $Path)) {
        if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            throw "Timed out waiting for test signal: $Path"
        }
        Start-Sleep -Milliseconds 50
    }
}

New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
try {
    $candidateScript = Join-Path $PSScriptRoot 'candidate-store.ps1'
    Assert-True (Test-Path -LiteralPath $candidateScript -PathType Leaf) (
        "Candidate store helper is missing: $candidateScript"
    )
    . $candidateScript
    $candidateScriptText = Get-Content -LiteralPath $candidateScript -Raw
    Assert-True (
        $candidateScriptText.Contains('diff --name-only $candidateCommit HEAD') -and
        -not $candidateScriptText.Contains('diff --name-only --diff-filter=')
    ) 'Candidate reuse comparison could omit deleted or otherwise changed product paths'

    $packagePolicyScript = Join-Path $PSScriptRoot 'package-policy.ps1'
    Assert-True (Test-Path -LiteralPath $packagePolicyScript -PathType Leaf) (
        "Package policy helper is missing: $packagePolicyScript"
    )
    . $packagePolicyScript

    $releaseToolingScript = Join-Path $PSScriptRoot 'release-tooling.ps1'
    Assert-True (Test-Path -LiteralPath $releaseToolingScript -PathType Leaf) (
        "Release tooling helper is missing: $releaseToolingScript"
    )
    . $releaseToolingScript

    $fakeSigningRepo = Join-Path $testRoot 'git-signing-repo'
    New-Item -ItemType Directory -Path $fakeSigningRepo -Force | Out-Null
    & git -C $fakeSigningRepo init --quiet
    if ($LASTEXITCODE -ne 0) { throw 'Unable to initialize fake signing repository' }
    $fakeGpg = Join-Path $testRoot 'configured-gpg.cmd'
    [IO.File]::WriteAllText(
        $fakeGpg,
        "@echo off`r`nexit /b 0`r`n",
        [Text.ASCIIEncoding]::new()
    )
    & git -C $fakeSigningRepo config gpg.format openpgp
    & git -C $fakeSigningRepo config gpg.openpgp.program $fakeGpg
    if ($LASTEXITCODE -ne 0) { throw 'Unable to configure fake Git signing backend' }
    $resolvedSigningBackend = Resolve-LeanTTYGitSigningBackend -RepoRoot $fakeSigningRepo
    Assert-True (
        $resolvedSigningBackend.format -eq 'openpgp' -and
        $resolvedSigningBackend.executablePath -eq [IO.Path]::GetFullPath($fakeGpg)
    ) 'Git signing backend resolution ignored the executable configured for OpenPGP'

    $signReleaseTagPath = Join-Path $PSScriptRoot 'sign-release-tag.ps1'
    Assert-True (Test-Path -LiteralPath $signReleaseTagPath -PathType Leaf) (
        "Release tag helper is missing: $signReleaseTagPath"
    )
    $signReleaseTagText = Get-Content -LiteralPath $signReleaseTagPath -Raw
    Assert-True (
        ([regex]::Matches(
                $signReleaseTagText,
                [regex]::Escape('-c $backendConfig')
            )).Count -eq 2 -and
        -not $signReleaseTagText.Contains('& git -C $RepoRoot tag -v $Tag')
    ) 'Release tag creation and verification do not use one resolved GPG executable'

    $safeAutomaticVariableScript = Join-Path $testRoot 'safe-automatic-variable.ps1'
    [IO.File]::WriteAllText(
        $safeAutomaticVariableScript,
        "`$currentProcessId = `$PID`r`n",
        [Text.UTF8Encoding]::new($false)
    )
    Assert-LeanTTYPowerShellAutomaticVariableSafety -Path @($safeAutomaticVariableScript)
    foreach ($unsafeSource in @(
            'param([int]$pid)',
            '$pid = 1',
            'foreach ($pid in 1..2) { $pid }'
        )) {
        $unsafeAutomaticVariableScript = Join-Path $testRoot (
            'unsafe-automatic-variable-' + [Guid]::NewGuid().ToString('N') + '.ps1'
        )
        [IO.File]::WriteAllText(
            $unsafeAutomaticVariableScript,
            $unsafeSource,
            [Text.UTF8Encoding]::new($false)
        )
        Assert-Throws {
            Assert-LeanTTYPowerShellAutomaticVariableSafety `
                -Path @($unsafeAutomaticVariableScript)
        } 'PowerShell automatic-variable audit accepted a PID write collision'
    }
    $repositoryPowerShellScripts = @(
        Get-ChildItem -LiteralPath $PSScriptRoot -File -Filter '*.ps1' |
            Select-Object -ExpandProperty FullName
    )
    Assert-LeanTTYPowerShellAutomaticVariableSafety -Path $repositoryPowerShellScripts

    $productionHap = Join-Path $testRoot 'LeanTTY-1.4.0-arm64-v8a-signed.hap'
    $reviewHap = Join-Path $testRoot 'LeanTTY-1.4.0-review-test-signed.hap'
    $retainedHap = Join-Path $testRoot 'LeanTTY-test-signed.hap'
    foreach ($hap in @($productionHap, $reviewHap, $retainedHap)) {
        [IO.File]::WriteAllBytes($hap, [byte[]](1, 2, 3))
    }
    Assert-Throws {
        Assert-LeanTTYDeviceTestHapPath `
            -HapPath $productionHap `
            -ParameterName 'ReviewHapPath'
    } 'Review-HAP boundary accepted a production release-Profile HAP'
    Assert-True (
        (Assert-LeanTTYDeviceTestHapPath `
            -HapPath $reviewHap `
            -ParameterName 'ReviewHapPath') -eq [IO.Path]::GetFullPath($reviewHap)
    ) 'Review-HAP boundary rejected the named review-test package'
    Assert-True (
        (Assert-LeanTTYDeviceTestHapPath `
            -HapPath $retainedHap `
            -ParameterName 'ReviewHapPath') -eq [IO.Path]::GetFullPath($retainedHap)
    ) 'Review-HAP boundary rejected a retained verified test candidate'

    $startupUpgradeVerifierText = Get-Content -LiteralPath (
        Join-Path $PSScriptRoot 'verify-startup-upgrade-pc.ps1'
    ) -Raw
    Assert-True (
        $startupUpgradeVerifierText.Contains('$BaselineReviewHapPath') -and
        $startupUpgradeVerifierText.Contains('$CandidateReviewHapPath') -and
        $startupUpgradeVerifierText.Contains('Assert-LeanTTYDeviceTestHapPath')
    ) 'Startup-upgrade verifier does not expose explicit review-HAP parameters'
    $harnessQualifierText = Get-Content -LiteralPath (
        Join-Path $PSScriptRoot 'qualify-acceptance-harness-pc.ps1'
    ) -Raw
    Assert-True (
        $harnessQualifierText.Contains('Assert-LeanTTYDeviceTestHapPath')
    ) 'Harness qualification does not reject a production HAP before device setup'

    $acceptanceSourceScript = Join-Path $PSScriptRoot 'acceptance-source.ps1'
    Assert-True (Test-Path -LiteralPath $acceptanceSourceScript -PathType Leaf) (
        "Acceptance source helper is missing: $acceptanceSourceScript"
    )
    . $acceptanceSourceScript
    $startupPerformanceSourceScript = Join-Path $PSScriptRoot 'startup-performance-source.ps1'
    Assert-True (Test-Path -LiteralPath $startupPerformanceSourceScript -PathType Leaf) (
        "Startup performance source helper is missing: $startupPerformanceSourceScript"
    )
    . $startupPerformanceSourceScript
    $startupWarmSourceScript = Join-Path $PSScriptRoot 'startup-warm-source.ps1'
    Assert-True (Test-Path -LiteralPath $startupWarmSourceScript -PathType Leaf) (
        "Startup warm source helper is missing: $startupWarmSourceScript"
    )
    . $startupWarmSourceScript
    $durableStateProductionPath = Join-Path $repoRoot `
        'entry\src\main\ets\model\persistence\DurableStateManager.ets'
    $durableStateProductionText = Get-Content -LiteralPath $durableStateProductionPath -Raw
    $durableInitializeBlock = [regex]::Match(
        $durableStateProductionText,
        '(?s)  static initialize\(context: common\.UIAbilityContext\): void \{.*?\r?\n  \}'
    ).Value
    Assert-True (-not [string]::IsNullOrWhiteSpace($durableInitializeBlock)) (
        'Durable state initialize block is missing'
    )
    Assert-True (
        -not $durableInitializeBlock.Contains('.garbageCollect()') -and
        -not $durableInitializeBlock.Contains('restoreSshProjection') -and
        $durableStateProductionText.Contains('private static garbageCollectionCompleted: boolean = false') -and
        $durableStateProductionText.Contains('static collectGarbageOnce(): void') -and
        $durableStateProductionText.Contains('static async prepareSshProjection(') -and
        $durableStateProductionText.Contains('await DurableStateManager.requireStore().listPathsAsync()')
    ) 'Durable SSH projection or garbage collection still blocks startup'
    $durableAssetStoreText = Get-Content -LiteralPath (
        Join-Path $repoRoot 'entry\src\main\ets\model\persistence\DurableAssetStore.ets'
    ) -Raw
    Assert-True (
        $durableAssetStoreText.Contains('async readAsync(path: string): Promise<string | null>') -and
        $durableAssetStoreText.Contains('async listPathsAsync(): Promise<string[]>') -and
        $durableAssetStoreText.Contains('await asset.query(query)')
    ) 'SSH projection does not use the non-blocking Asset Store query path'
    $entryAbilityProductionText = Get-Content -LiteralPath (
        Join-Path $repoRoot 'entry\src\main\ets\entryability\EntryAbility.ets'
    ) -Raw
    Assert-True (
        $entryAbilityProductionText.Contains('windowStage.setWindowRectAutoSave(true)') -and
        -not $entryAbilityProductionText.Contains('restoreOrCaptureWindowRect') -and
        -not $entryAbilityProductionText.Contains("mainWindow.on('windowRectChange'") -and
        -not $durableStateProductionText.Contains('DurableWindowRect') -and
        -not $durableStateProductionText.Contains('WINDOW_RECT_PATH')
    ) 'System window auto-save is not the sole owner of restart window geometry'
    $onBackgroundBlock = [regex]::Match(
        $entryAbilityProductionText,
        '(?s)  onBackground\(\): void \{.*?\r?\n  \}'
    ).Value
    Assert-True (
        $onBackgroundBlock.Contains('DurableStateManager.collectGarbageOnce()') -and
        $onBackgroundBlock.Contains("logger.warn('Deferred durable garbage collection failed: '")
    ) 'Ability background lifecycle does not own recoverable deferred durable cleanup'
    $onCreateBlock = [regex]::Match(
        $entryAbilityProductionText,
        '(?s)  onCreate\(want: Want, launchParam: AbilityConstant\.LaunchParam\): void \{.*?\r?\n  \}'
    ).Value
    Assert-True (
        -not $onCreateBlock.Contains('SshKeyManager.listKeys') -and
        -not $onCreateBlock.Contains('finishLegacyMigration') -and
        -not $onCreateBlock.Contains('reconcileVerifiedKeys')
    ) 'SSH key projection maintenance still blocks Ability startup'
    $sshEnvironmentPath = Join-Path $repoRoot `
        'entry\src\main\ets\model\ssh\SshEnvironment.ets'
    Assert-True (Test-Path -LiteralPath $sshEnvironmentPath -PathType Leaf) (
        'Single-flight SSH environment owner is missing'
    )
    $sshEnvironmentText = Get-Content -LiteralPath $sshEnvironmentPath -Raw
    Assert-True (
        $sshEnvironmentText.Contains('SshEnvironmentReadiness') -and
        $sshEnvironmentText.Contains('DurableStateManager.prepareSshProjection') -and
        $sshEnvironmentText.Contains('DurableStateManager.reconcileVerifiedKeys')
    ) 'SSH environment owner does not contain the complete post-render preparation chain'
    $sessionViewModelText = Get-Content -LiteralPath (
        Join-Path $repoRoot 'entry\src\main\ets\viewmodel\SessionViewModel.ets'
    ) -Raw
    Assert-True (
        $sessionViewModelText.Contains('this.beginSshEnvironmentPreparation()') -and
        $sessionViewModelText.Contains('await this.ensureSshEnvironment()') -and
        $sessionViewModelText.Contains('CommandParser.requiresSshEnvironment(cmd)')
    ) 'Terminal readiness and command execution do not share the SSH environment gate'
    $bridgeProtocolText = Get-Content -LiteralPath (
        Join-Path $repoRoot 'entry\src\main\ets\model\bridge\BridgeProtocol.ets'
    ) -Raw
    $terminalHtmlText = Get-Content -LiteralPath (
        Join-Path $repoRoot 'entry\src\main\resources\rawfile\terminal.html'
    ) -Raw
    Assert-True (
        $bridgeProtocolText.Contains("KIND_INTERACTIVE_READY: string = 'interactiveReady'") -and
        $terminalHtmlText.Contains("sendBridgeControl('interactiveReady', '')") -and
        $terminalHtmlText.Contains('reportInteractiveReadyAfterPaint();')
    ) 'Post-paint SSH preparation trigger is missing from the terminal bridge'
    $lfTarget = "first`nsecond`n"
    $lfResult = Set-LeanTTYAcceptanceSourceText `
        -Text $lfTarget `
        -Anchor "first`r`nsecond" `
        -Replacement "alpha`r`nbeta"
    Assert-True ($lfResult -ceq "alpha`nbeta`n") (
        'Acceptance source replacement did not normalize a CRLF anchor to an LF target'
    )
    $crlfTarget = "first`r`nsecond`r`n"
    $crlfResult = Set-LeanTTYAcceptanceSourceText `
        -Text $crlfTarget `
        -Anchor "first`nsecond" `
        -Replacement "alpha`nbeta"
    Assert-True ($crlfResult -ceq "alpha`r`nbeta`r`n") (
        'Acceptance source replacement did not normalize an LF anchor to a CRLF target'
    )
    $acceptanceArkTsPaths = @(
        Join-Path $repoRoot 'entry\src\main\ets\pages\Index.ets'
        Join-Path $repoRoot 'entry\src\main\ets\model\bridge\TerminalBridge.ets'
        Join-Path $repoRoot 'entry\src\main\ets\model\terminal\TerminalSurfaceController.ets'
        Join-Path $repoRoot 'entry\src\main\ets\viewmodel\SessionViewModel.ets'
        Join-Path $repoRoot 'entry\src\main\ets\model\transfer\TransferFileManager.ets'
        Join-Path $repoRoot 'entry\src\main\ets\model\transfer\FileTransferClient.ets'
    )
    $acceptanceSourceHashes = @{}
    foreach ($path in $acceptanceArkTsPaths) {
        $acceptanceSourceHashes[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    }
    $startupPerformancePaths = @(
        Join-Path $repoRoot 'entry\src\main\ets\entryability\EntryAbility.ets'
        Join-Path $repoRoot 'entry\src\main\ets\model\persistence\DurableStateManager.ets'
        Join-Path $repoRoot 'entry\src\main\ets\view\components\TerminalPane.ets'
        Join-Path $repoRoot 'entry\src\main\ets\model\bridge\BridgeProtocol.ets'
        Join-Path $repoRoot 'entry\src\main\ets\model\bridge\TerminalBridge.ets'
        Join-Path $repoRoot 'entry\src\main\resources\rawfile\terminal.html'
    )
    $startupPerformanceHashes = @{}
    foreach ($path in $startupPerformancePaths) {
        $startupPerformanceHashes[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    }
    Invoke-WithLeanTTYStartupPerformanceSource -RepoRoot $repoRoot -Action {
        $startupPerformanceText = $startupPerformancePaths | ForEach-Object {
            Get-Content -LiteralPath $_ -Raw
        }
        Assert-True (($startupPerformanceText -join "`n").Contains('STARTUP_PERF phase=T1')) (
            'Startup performance injection omitted the Ability entry marker'
        )
        Assert-True (($startupPerformanceText -join "`n").Contains(
                'STARTUP_PERF segment=on-create-ready elapsedMs='
            )) 'Startup performance injection omitted the onCreate segment markers'
        Assert-True (($startupPerformanceText -join "`n").Contains(
                'STARTUP_PERF durable=initialized-read elapsedMs='
            )) 'Startup performance injection omitted the durable-state segment markers'
        Assert-True (-not (($startupPerformanceText -join "`n").Contains(
                'STARTUP_PERF durable=restore-projection elapsedMs='
            ))) 'Startup performance injection incorrectly treats SSH projection as startup work'
        Assert-True (($startupPerformanceText -join "`n").Contains('STARTUP_PERF phase=T3')) (
            'Startup performance injection omitted the ArkWeb page-end marker'
        )
        Assert-True (($startupPerformanceText -join "`n").Contains("sendBridgeControl('startupPerf', phase)")) (
            'Startup performance injection omitted the painted T4/T5 marker'
        )
        Assert-True (($startupPerformanceText -join "`n").Contains('startupExpectedInputCode = 97')) (
            'Startup performance injection did not gate T5 on the injected ASCII letter echo'
        )
        Assert-True (($startupPerformanceText -join "`n").Contains(
                "KIND_STARTUP_PERF: string = 'startupPerf'"
            )) 'Startup performance injection omitted the compile-time bridge kind'
    }
    foreach ($path in $startupPerformancePaths) {
        Assert-True (
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -eq $startupPerformanceHashes[$path]
        ) "Startup performance injection did not restore $path byte-for-byte"
    }
    $startupPerformanceVerifier = Join-Path $PSScriptRoot 'verify-startup-performance-pc.ps1'
    Assert-True (Test-Path -LiteralPath $startupPerformanceVerifier -PathType Leaf) (
        "Startup performance PC verifier is missing: $startupPerformanceVerifier"
    )
    $startupPerformanceVerifierText = Get-Content -LiteralPath $startupPerformanceVerifier -Raw
    Assert-True (
        $startupPerformanceVerifierText.Contains('[ValidateRange(3, 100)][int]$SampleCount = 20') -and
        $startupPerformanceVerifierText.Contains("'aa force-stop com.leantty.app'") -and
        $startupPerformanceVerifierText.Contains(
            "'AppCenterAppGrid_AppBubble_com.leantty.app'"
        ) -and
        $startupPerformanceVerifierText.Contains('STARTUP_PERF phase=T4') -and
        $startupPerformanceVerifierText.Contains('uinput -K -d 2017 -u 2017') -and
        -not $startupPerformanceVerifierText.Contains('dumpLayout -p $remotePath -a') -and
        $startupPerformanceVerifierText.Contains('t5RequiresMatchingAsciiEchoAndPaint = $true') -and
        $startupPerformanceVerifierText.Contains('maxT4ToInputInjectionMs = 250')
    ) 'Startup performance PC verifier no longer measures cold App Center click through painted input'
    $startupWarmPath = Join-Path $repoRoot 'entry\src\main\resources\rawfile\terminal.html'
    $startupWarmHash = (Get-FileHash -LiteralPath $startupWarmPath -Algorithm SHA256).Hash
    Invoke-WithLeanTTYStartupWarmSource -RepoRoot $repoRoot -Action {
        $startupWarmText = Get-Content -LiteralPath $startupWarmPath -Raw
        Assert-True (
            $startupWarmText.Contains("sendBridgeControl('perfRender', 'STARTUP_WARM phase=' + phase)") -and
            $startupWarmText.Contains("data === 'a'") -and
            $startupWarmText.Contains('terminalBytes.indexOf(97) >= 0') -and
            $startupWarmText.Contains("scheduleStartupWarmPaint('T4')") -and
            $startupWarmText.Contains("scheduleStartupWarmPaint('T5')")
        ) 'Warm startup injection no longer gates T4/T5 on foreground paint and echoed input'
    }
    Assert-True (
        (Get-FileHash -LiteralPath $startupWarmPath -Algorithm SHA256).Hash -eq $startupWarmHash
    ) 'Warm startup injection did not restore terminal.html byte-for-byte'
    $startupWarmVerifier = Join-Path $PSScriptRoot 'verify-startup-warm-pc.ps1'
    Assert-True (Test-Path -LiteralPath $startupWarmVerifier -PathType Leaf) (
        "Warm startup PC verifier is missing: $startupWarmVerifier"
    )
    $startupWarmVerifierText = Get-Content -LiteralPath $startupWarmVerifier -Raw
    Assert-True (
        $startupWarmVerifierText.Contains('[ValidateRange(3, 100)][int]$SampleCount = 20') -and
        $startupWarmVerifierText.Contains("'pidof com.leantty.app'") -and
        $startupWarmVerifierText.Contains("'AppCenterAppGrid_AppBubble_com.leantty.app'") -and
        $startupWarmVerifierText.Contains('STARTUP_WARM phase=T4') -and
        $startupWarmVerifierText.Contains('uinput -K -d 2017 -u 2017') -and
        -not $startupWarmVerifierText.Contains('dumpLayout -p $remotePath -a') -and
        $startupWarmVerifierText.Contains('processRetainedForAllSamples = $true')
    ) 'Warm startup PC verifier no longer measures retained-process foreground input readiness'
    foreach ($startupVerifierName in @(
        'verify-startup-upgrade-pc.ps1',
        'verify-startup-readiness-pc.ps1'
    )) {
        Assert-True (Test-Path -LiteralPath (Join-Path $PSScriptRoot $startupVerifierName) -PathType Leaf) (
            "Startup verification helper is missing: $startupVerifierName"
        )
    }
    Invoke-WithLeanTTYAcceptanceSource -RepoRoot $repoRoot -Enabled $true -Action {
        $injectedText = $acceptanceArkTsPaths | ForEach-Object {
            Get-Content -LiteralPath $_ -Raw
        }
        Assert-True (($injectedText -join "`n").Contains('ACCEPTANCE_INPUT_SUBMIT')) (
            'Debug acceptance source injection omitted input telemetry'
        )
        Assert-True (($injectedText -join "`n").Contains(
                "logAcceptanceInputSubmit('key-comment-passphrase')"
            ) -and ($injectedText -join "`n").Contains(
                "logAcceptanceInputSubmit('key-comment')"
            )) (
            'Debug acceptance source injection omitted key-comment input telemetry'
        )
        Assert-True (($injectedText -join "`n").Contains('ACCEPTANCE_LOCAL_CLEANUP_FAILURE')) (
            'Debug acceptance source injection omitted local cleanup failure control'
        )
        Assert-True (($injectedText -join "`n").Contains('ACCEPTANCE_DOWNLOADS_NOREPLACE')) (
            'Debug acceptance source injection omitted the Downloads no-replace probe'
        )
        Assert-True (($injectedText -join "`n").Contains('ACCEPTANCE_DOWNLOADS_MANAGER')) (
            'Debug acceptance source injection omitted the production Downloads manager probe'
        )
        Assert-True (-not ($injectedText -join "`n").Contains('ACCEPTANCE_DOWNLOADS_FD')) (
            'Routine debug acceptance injection included the native-only Downloads FD probe'
        )
        Assert-True (($injectedText -join "`n").Contains('Acceptance: Rebuild Renderer')) (
            'Debug acceptance source injection omitted renderer trigger'
        )
        Assert-True (($injectedText -join "`n").Contains('Acceptance: Downloads No-Replace')) (
            'Debug acceptance source injection omitted the Downloads probe menu action'
        )
        Assert-True (($injectedText -join "`n").Contains('Acceptance: Downloads Manager Boundary')) (
            'Debug acceptance source injection omitted the Downloads manager boundary action'
        )
        Assert-True (($injectedText -join "`n").Contains('ACCEPTANCE_TRANSFER_FIXTURE')) (
            'Debug acceptance source injection omitted transfer fixture telemetry'
        )
        Assert-True (($injectedText -join "`n").Contains('force-put-source.bin')) (
            'Debug acceptance source injection omitted the force-termination PUT source'
        )
        Assert-True (($injectedText -join "`n").Contains('ACCEPTANCE_FILE_TRANSFER_LATE_EVENT')) (
            'Debug acceptance source injection omitted stale transfer event control'
        )
        Assert-True (($injectedText -join "`n").Contains(
                'ACCEPTANCE_FILE_TRANSFER_PREPARATION waiting=true'
            )) (
            'Debug acceptance source injection omitted the stalled preparation trigger'
        )
        Assert-True (($injectedText -join "`n").Contains('Acceptance: Transfer Fixture')) (
            'Debug acceptance source injection omitted the transfer fixture action'
        )
        Assert-True (-not ($injectedText -join "`n").Contains('Acceptance: Downloads FD Boundary')) (
            'Routine debug acceptance injection included the native-only Downloads FD menu action'
        )
        Assert-True (-not ($injectedText -join "`n").Contains('Debug Material')) (
            'Debug acceptance source injection must not restore the retired material comparator'
        )
        Assert-True (-not ($injectedText -join "`n").Contains('Acceptance: Open Search')) (
            'Debug acceptance source injection must reuse the production Search action'
        )
        Assert-True (($injectedText -join "`n").Contains('pasteClipboardForAcceptance')) (
            'Debug acceptance source injection omitted clipboard paste trigger'
        )
    }
    foreach ($path in $acceptanceArkTsPaths) {
        Assert-True (
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -eq $acceptanceSourceHashes[$path]
        ) "Acceptance source injection did not restore $path byte-for-byte"
    }
    $nativeAcceptancePaths = @(
        Join-Path $repoRoot 'leantty_ssh\src\lib.rs'
        Join-Path $repoRoot 'entry\src\main\cpp\types\libleantty_ssh\index.d.ts'
    )
    $nativeAcceptanceHashes = @{}
    foreach ($path in $nativeAcceptancePaths) {
        $nativeAcceptanceHashes[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    }
    Invoke-WithLeanTTYNativeAcceptanceSource -RepoRoot $repoRoot -Action {
        $nativeInjectedText = $nativeAcceptancePaths | ForEach-Object {
            Get-Content -LiteralPath $_ -Raw
        }
        Assert-True (($nativeInjectedText -join "`n").Contains('ssh_acceptance_probe_file_descriptor')) (
            'Debug native acceptance injection omitted the FD boundary probe'
        )
        Assert-True (($nativeInjectedText -join "`n").Contains(
                'ACCEPTANCE_LOCAL_TEMP_CLEANUP_FAILURE'
            )) (
            'Debug native acceptance injection omitted the local temporary cleanup failure control'
        )
        Assert-True (($nativeInjectedText -join "`n").Contains(
                'ACCEPTANCE_FILE_TRANSFER_DROPPED'
            )) (
            'Debug native acceptance injection omitted the transfer callback backpressure metric'
        )
        $borrowedFdImportCount = ([regex]::Matches(
                [IO.File]::ReadAllText((Join-Path $repoRoot 'leantty_ssh\src\lib.rs')),
                '(?m)^use std::os::fd::BorrowedFd;$'
            )).Count
        Assert-True ($borrowedFdImportCount -eq 1) (
            'Debug native acceptance injection duplicated the production BorrowedFd import'
        )
        Assert-True (($nativeInjectedText -join "`n").Contains(
                "): AcceptanceFileDescriptorProbeResult`nexport interface KnownHostsQueryResult"
            )) 'Debug native type injection merged adjacent declarations'
        Invoke-WithLeanTTYAcceptanceSource -RepoRoot $repoRoot -Enabled $true -Action {
            $fdInjectedText = $acceptanceArkTsPaths | ForEach-Object {
                Get-Content -LiteralPath $_ -Raw
            }
            Assert-True (($fdInjectedText -join "`n").Contains('ACCEPTANCE_DOWNLOADS_FD')) (
                'Native-backed acceptance injection omitted the Downloads FD boundary probe'
            )
            Assert-True (($fdInjectedText -join "`n").Contains('Acceptance: Downloads FD Boundary')) (
                'Native-backed acceptance injection omitted the Downloads FD menu action'
            )
            Assert-True (($fdInjectedText -join "`n").Contains('ACCEPTANCE_DOWNLOADS_MANAGER')) (
                'Native-backed acceptance injection omitted the production Downloads manager probe'
            )
        }
    }
    foreach ($path in $nativeAcceptancePaths) {
        Assert-True (
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -eq $nativeAcceptanceHashes[$path]
        ) "Native acceptance source injection did not restore $path byte-for-byte"
    }

    $sshAuthHarnessText = [IO.File]::ReadAllText(
        (Join-Path $repoRoot 'tools\verify-ssh-auth-pc.ps1')
    )
    foreach ($requiredEcdsaHarnessContract in @(
        "'ecdsa-import-encrypted-and-restart'",
        'KEY_IMPORT result=success,algorithm=ecdsa-p256',
        'Install-LeanTTYEcdsaImportSource',
        'fingerprintAfterRestart',
        'independentEcdsaKeyAbsenceAudit',
        'independentEcdsaSourceAbsenceAudit'
    )) {
        Assert-True ($sshAuthHarnessText.Contains($requiredEcdsaHarnessContract)) (
            "SSH authentication harness omitted ECDSA contract: $requiredEcdsaHarnessContract"
        )
    }

    Assert-LeanTTYHarnessOnlyPaths `
        -ChangedPaths @('tools/verify-ssh-auth-pc.ps1', 'docs/quality-strategy.md') `
        -AllowedPaths @('tools/verify-ssh-auth-pc.ps1', 'docs/*.md')
    Assert-Throws -Action {
        Assert-LeanTTYHarnessOnlyPaths `
            -ChangedPaths @('entry/src/main/ets/pages/Index.ets') `
            -AllowedPaths @('tools/verify-ssh-auth-pc.ps1', 'docs/*.md')
    } -Message 'Candidate reuse accepted a product-source change'

    $safeHap = Join-Path $testRoot 'safe-release.hap'
    $unsafeHap = Join-Path $testRoot 'unsafe-release.hap'
    foreach ($archiveCase in @(
        @{ path = $safeHap; content = 'ordinary release bytecode' },
        @{ path = $unsafeHap; content = 'ACCEPTANCE_INPUT_SUBMIT must not ship' }
    )) {
        $archiveStream = [IO.File]::Open($archiveCase.path, [IO.FileMode]::Create)
        try {
            $zip = [IO.Compression.ZipArchive]::new(
                $archiveStream,
                [IO.Compression.ZipArchiveMode]::Create,
                $false
            )
            try {
                $entry = $zip.CreateEntry('modules.abc')
                $entryStream = $entry.Open()
                try {
                    $bytes = [Text.Encoding]::UTF8.GetBytes($archiveCase.content)
                    $entryStream.Write($bytes, 0, $bytes.Length)
                } finally {
                    $entryStream.Dispose()
                }
            } finally {
                $zip.Dispose()
            }
        } finally {
            $archiveStream.Dispose()
        }
    }
    Assert-LeanTTYReleasePackageExcludesAcceptanceMarkers -PackagePath $safeHap
    Assert-Throws -Action {
        Assert-LeanTTYReleasePackageExcludesAcceptanceMarkers -PackagePath $unsafeHap
    } -Message 'Release package policy accepted an acceptance-only marker'

    $qualificationPolicyScript = Join-Path $PSScriptRoot 'harness-qualification.ps1'
    Assert-True (Test-Path -LiteralPath $qualificationPolicyScript -PathType Leaf) (
        "Harness qualification policy helper is missing: $qualificationPolicyScript"
    )
    . $qualificationPolicyScript
    $qualificationSha = 'a' * 64
    $qualificationCommit = 'b' * 40
    $qualificationTree = 'c' * 40
    $validQualificationPhysicalEvidence = [pscustomobject][ordered]@{
        schemaVersion = 2
        scenario = 'ssh-interactive-authentication'
        result = 'passed'
        candidate = [ordered]@{ sha256 = $qualificationSha }
        harness = [ordered]@{
            gitCommit = $qualificationCommit
            gitTree = $qualificationTree
            gitDirty = $false
        }
        checks = @(
            [ordered]@{ name = 'fixture-and-device-preflight' },
            [ordered]@{ name = 'password-success' },
            [ordered]@{ name = 'preferences-unchanged-during-authentication' }
        )
        automation = [ordered]@{
            businessVerdict = 'passed'
            harnessStability = 'stable'
            commandCount = 2
            inputAttemptCount = 2
            inputMismatchCount = 0
            enterCount = 2
        }
        input = [ordered]@{
            secretInjection = 'harmony-uitest-targeted-inputText-runtime-generated-temporary-fixture-values'
        }
        cleanup = [ordered]@{
            result = 'passed'
            knownHostRemovalCommandCompleted = $true
            reverseMappingAbsenceAudit = $true
            fixtureProcessAbsenceAudit = $true
        }
        failureDomain = 'none'
    }
    $qualificationSummary = Assert-LeanTTYHarnessQualificationPhysicalEvidence `
        -Evidence $validQualificationPhysicalEvidence `
        -ReviewHapSha256 $qualificationSha `
        -HarnessCommit $qualificationCommit `
        -HarnessTree $qualificationTree `
        -RequireCleanHarness
    Assert-True (
        $qualificationSummary.ordinaryCommandCount -eq 2 -and
        $qualificationSummary.harnessStability -eq 'stable'
    ) 'Passing harness qualification evidence did not produce a stable summary'

    foreach ($invalidQualification in @(
        @{ name = 'review HAP mismatch'; mutate = { param($e) $e.candidate.sha256 = 'd' * 64 } },
        @{ name = 'flaky command channel'; mutate = { param($e) $e.automation.harnessStability = 'flaky-harness' } },
        @{ name = 'input mismatch'; mutate = { param($e) $e.automation.inputMismatchCount = 1 } },
        @{ name = 'cleanup failure'; mutate = { param($e) $e.cleanup.reverseMappingAbsenceAudit = $false } }
    )) {
        $invalidEvidence = $validQualificationPhysicalEvidence |
            ConvertTo-Json -Depth 8 | ConvertFrom-Json
        & $invalidQualification.mutate $invalidEvidence
        Assert-Throws -Action {
            Assert-LeanTTYHarnessQualificationPhysicalEvidence `
                -Evidence $invalidEvidence `
                -ReviewHapSha256 $qualificationSha `
                -HarnessCommit $qualificationCommit `
                -HarnessTree $qualificationTree `
                -RequireCleanHarness
        } -Message "Harness qualification accepted $($invalidQualification.name)"
    }

    $qualificationEntry = Join-Path $PSScriptRoot 'qualify-acceptance-harness-pc.ps1'
    Assert-True (Test-Path -LiteralPath $qualificationEntry -PathType Leaf) (
        "Harness qualification entry is missing: $qualificationEntry"
    )
    $qualificationEntryText = Get-Content -LiteralPath $qualificationEntry -Raw
    Assert-True (
        $qualificationEntryText.Contains('[Parameter(Mandatory = $true)][string]$ReviewHapPath') -and
        $qualificationEntryText.Contains("'test-acceptance-harness.ps1'") -and
        $qualificationEntryText.Contains("Only = @('password-success')") -and
        $qualificationEntryText.Contains('releaseEligible = (-not $Diagnostic -and -not $failure)') -and
        $qualificationEntryText.Contains('harness-commit-or-tree-change')
    ) 'Harness qualification no longer binds the explicit package, minimum scenario and freeze identity'

    $candidateBase = Join-Path $testRoot 'candidates'
    $latestSource = $null
    for ($index = 1; $index -le 7; $index++) {
        $source = Join-Path $testRoot "candidate-$index.hap"
        [IO.File]::WriteAllText(
            $source,
            "candidate-$index",
            [Text.UTF8Encoding]::new($false)
        )
        Save-LeanTTYVerifiedCandidate `
            -RepoRoot $repoRoot `
            -HapPath $source `
            -VerificationMode 'software' `
            -CandidateBasePath $candidateBase | Out-Null
        $latestSource = $source
        Start-Sleep -Milliseconds 10
    }

    $candidateRoot = Get-LeanTTYCandidateRoot `
        -RepoRoot $repoRoot `
        -CandidateBasePath $candidateBase
    $candidateDirectories = @(
        Get-ChildItem -LiteralPath $candidateRoot -Directory |
            Where-Object { $_.Name -match '^[0-9a-f]{64}$' }
    )
    Assert-True ($candidateDirectories.Count -eq 5) (
        "Expected exactly 5 retained candidates, found $($candidateDirectories.Count)"
    )

    $latestCandidate = Get-LeanTTYLatestVerifiedCandidate `
        -RepoRoot $repoRoot `
        -CandidateBasePath $candidateBase
    Assert-True ($null -ne $latestCandidate) 'Latest candidate was not returned'
    Assert-True (
        (Get-FileHash -LiteralPath $latestCandidate.hapPath -Algorithm SHA256).Hash -eq
        (Get-FileHash -LiteralPath $latestSource -Algorithm SHA256).Hash
    ) 'Latest candidate does not match the newest verified package'

    $behaviorEvidence = Join-Path $testRoot 'device-key-passphrase.json'
    [IO.File]::WriteAllText(
        $behaviorEvidence,
        '{"schemaVersion":1,"scenario":"ssh-keygen-passphrase","result":"passed"}',
        [Text.UTF8Encoding]::new($false)
    )
    Save-LeanTTYVerifiedCandidate `
        -RepoRoot $repoRoot `
        -HapPath $latestCandidate.hapPath `
        -VerificationMode 'device-behavior' `
        -EvidencePaths @($behaviorEvidence) `
        -CandidateBasePath $candidateBase | Out-Null
    $behaviorCandidate = Get-LeanTTYLatestVerifiedCandidate `
        -RepoRoot $repoRoot `
        -CandidateBasePath $candidateBase
    Assert-True ($behaviorCandidate.verificationMode -eq 'device-behavior') (
        'Device behavior evidence did not promote the retained candidate'
    )
    Assert-True ($behaviorCandidate.evidenceFiles.Count -eq 1) (
        'Device behavior evidence was not retained with the candidate'
    )
    Save-LeanTTYVerifiedCandidate `
        -RepoRoot $repoRoot `
        -HapPath $latestCandidate.hapPath `
        -VerificationMode 'software' `
        -CandidateBasePath $candidateBase | Out-Null
    $nonDowngradedCandidate = Get-LeanTTYLatestVerifiedCandidate `
        -RepoRoot $repoRoot `
        -CandidateBasePath $candidateBase
    Assert-True ($nonDowngradedCandidate.verificationMode -eq 'device-behavior') (
        'A later software-only save downgraded device behavior evidence'
    )

    $legacyManifestPath = Join-Path $candidateDirectories[0].FullName 'manifest.json'
    $legacyManifest = Get-Content -LiteralPath $legacyManifestPath -Raw | ConvertFrom-Json
    $legacyManifest.schemaVersion = 1
    $legacyManifest.verificationMode = 'device'
    $legacyManifest.PSObject.Properties.Remove('evidenceFiles')
    [IO.File]::WriteAllText(
        $legacyManifestPath,
        (ConvertTo-Json -InputObject $legacyManifest -Depth 4),
        [Text.UTF8Encoding]::new($false)
    )
    $legacyRecord = @(Get-LeanTTYCandidateRecords -CandidateRoot $candidateRoot |
        Where-Object { $_.manifestPath -eq $legacyManifestPath })
    Assert-True ($legacyRecord.Count -eq 1 -and
        $legacyRecord[0].verificationMode -eq 'device-deployed') (
        'Legacy device candidate mode was not normalized to device-deployed'
    )

    $wslScript = Join-Path $PSScriptRoot 'rust-wsl.ps1'
    . $wslScript
    Assert-True (
        (ConvertTo-LeanTTYWslPath -WindowsPath 'C:\src\project') -eq '/mnt/c/src/project'
    ) 'WSL repository path conversion is incorrect'
    Assert-True (
        (ConvertTo-LeanTTYWslPath -WindowsPath 'D:\SDK\native sysroot') -eq
        '/mnt/d/SDK/native sysroot'
    ) 'WSL path conversion did not preserve spaces'
    $mappedCargoPath = ConvertFrom-LeanTTYWslPathWithinRoot `
        -WslRoot '/home/test/.cargo' `
        -WindowsRoot '\\wsl.localhost\Ubuntu-26.04\home\test\.cargo' `
        -WslPath '/home/test/.cargo/registry/src/index.example/russh-0.62.5/Cargo.toml'
    Assert-True (
        $mappedCargoPath -eq
        '\\wsl.localhost\Ubuntu-26.04\home\test\.cargo\registry\src\index.example\russh-0.62.5\Cargo.toml'
    ) 'WSL Cargo path conversion did not preserve the path within Cargo home'
    Assert-Throws -Action {
        ConvertFrom-LeanTTYWslPathWithinRoot `
            -WslRoot '/home/test/.cargo' `
            -WindowsRoot '\\wsl.localhost\Ubuntu-26.04\home\test\.cargo' `
            -WslPath '/home/test/.cargo-foreign/registry/Cargo.toml'
    } -Message 'WSL Cargo path conversion accepted a path outside Cargo home'

    $devBuildText = Get-Content -LiteralPath (
        Join-Path $PSScriptRoot 'dev-build.ps1'
    ) -Raw
    Assert-True (
        $devBuildText.Contains('Invoke-WithLeanTTYBuildLock')
    ) 'dev-build.ps1 is not protected by the repository build lock'

    $devPcText = Get-Content -LiteralPath (
        Join-Path $PSScriptRoot 'dev-pc.ps1'
    ) -Raw
    Assert-True (
        $devPcText.Contains(". (Join-Path `$PSScriptRoot 'device-regression.ps1')") -and
        $devPcText.Contains('Start-LeanTTYRegressionApp') -and
        $devPcText.Contains('Get-LeanTTYDeviceUnlockPasswordPath')
    ) 'dev-pc.ps1 does not use the conditional regression-PC unlock flow'

    $verifyPcText = Get-Content -LiteralPath (
        Join-Path $PSScriptRoot 'verify-pc.ps1'
    ) -Raw
    Assert-True (
        $verifyPcText.Contains('[IO.Path]::GetTempPath()') -and
        -not $verifyPcText.Contains("Join-Path `$repoRoot 'build\verification'") -and
        $verifyPcText.Contains('verify-pc evidence directory must be outside the repository') -and
        $verifyPcText.Contains('$evidenceDirectoryFullPath.StartsWith(')
    ) 'verify-pc evidence would be deleted by its own clean build'
    Assert-True (
        $verifyPcText.Contains("'oh-package-lock.json5'") -and
        $verifyPcText.Contains("'entry/oh-package-lock.json5'") -and
        $verifyPcText.Contains('[IO.File]::ReadAllBytes($fullPath)') -and
        $verifyPcText.Contains('git -C $repoRoot hash-object -- $relativePath') -and
        $verifyPcText.Contains('[IO.File]::WriteAllBytes(') -and
        $verifyPcText.Contains('verify-pc build changed the committed formal-release candidate')
    ) 'verify-pc does not preserve generated OHPM lockfiles while rejecting content drift'

    $buildAllText = Get-Content -LiteralPath (
        Join-Path $PSScriptRoot 'build-all.ps1'
    ) -Raw
    Assert-True (
        $buildAllText.Contains('Assert-LeanTTYReleasePackageExcludesAcceptanceMarkers') -and
        $buildAllText.Contains("if (`$BuildMode -eq 'release')") -and
        $buildAllText.Contains('Invoke-WithLeanTTYAcceptanceSource')
    ) 'Formal release build does not reject acceptance-only package markers'
    Assert-True (
        $buildAllText.Contains("tools\ohpm\bin\ohpm.bat") -and
        $buildAllText.Contains('& $ohpm install --all --lockfile_stable_order') -and
        $buildAllText.Contains("entry\oh_modules\libleantty_ssh.so")
    ) 'Clean release build does not restore required OHPM dependencies'
    $projectBuildProfileText = Get-Content -LiteralPath (
        Join-Path $repoRoot 'build-profile.json5'
    ) -Raw
    Assert-True (
        $projectBuildProfileText.Contains('"x86_64/**"') -and
        -not (Test-Path -LiteralPath (Join-Path $repoRoot 'entry\libs\x86_64'))
    ) 'Project packaging no longer excludes the unsupported x86_64 native ABI'
    $arm64AbiGuard = '$nativeAbis.Count -ne 1 -or $nativeAbis[0] -ne ''arm64-v8a'''
    Assert-True (
        ([regex]::Matches(
            $buildAllText,
            [regex]::Escape($arm64AbiGuard)
        )).Count -ge 2 -and
        $buildAllText.Contains("entry\libs\arm64-v8a\libleantty_ssh.so") -and
        $buildAllText.Contains("abi = 'arm64-v8a'") -and
        $buildAllText.Contains("'--filter-platform', 'aarch64-unknown-linux-ohos'")
    ) 'Release packaging no longer enforces one ARM64 ABI across HAP, APP and metadata'
    Assert-True (
        $buildAllText.Contains("'THIRD_PARTY_NOTICES.md' =") -and
        $buildAllText.Contains('Unable to resolve locked ARM64 Rust dependencies for release notices') -and
        $buildAllText.Contains('Invoke-LeanTTYRustWsl') -and
        -not $buildAllText.Contains('& cargo metadata --locked --offline')
    ) 'Release artifacts no longer require locked dependency license notices'
    Assert-True (
        Test-Path -LiteralPath (Join-Path $PSScriptRoot 'test-acceptance-harness.ps1') -PathType Leaf
    ) 'Focused acceptance-harness regression command is missing'

    $softwareGateText = Get-Content -LiteralPath (
        Join-Path $PSScriptRoot 'test-regression.ps1'
    ) -Raw
    Assert-True (
        $softwareGateText.Contains("[string[]]`$Group = @()") -and
        $softwareGateText.Contains("'policy'") -and
        $softwareGateText.Contains("'tooling'") -and
        $softwareGateText.Contains("'ssh-flow'") -and
        $softwareGateText.Contains("'web'") -and
        $softwareGateText.Contains("'arkts'") -and
        $softwareGateText.Contains("'rust-core'") -and
        $softwareGateText.Contains("'rust-native'") -and
        $softwareGateText.Contains("'ssh-fixture'") -and
        $softwareGateText.Contains("gate = `$(if (`$script:regressionMode -eq 'full')") -and
        $softwareGateText.Contains(
            'releaseEligible = ($script:regressionMode -eq ''full'' -and $passed)'
        ) -and
        $softwareGateText.Contains("'software-focused'")
    ) 'Software gate does not distinguish explicit focused groups from the full release gate'
    Assert-True (
        ([regex]::Matches($softwareGateText, 'Invoke-RegressionCheck -Name')).Count -eq
            ([regex]::Matches($softwareGateText, 'Invoke-RegressionCheck -Name[^\r\n]+-Groups')).Count
    ) 'Software checks are not all owned by the single grouped regression registry'
    $verifyPcText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'verify-pc.ps1') -Raw
    Assert-True (
        $verifyPcText.Contains("'preflight-device.ps1'") -and
        $verifyPcText.Contains("'test-regression.ps1'") -and
        $verifyPcText.Contains("-EvidencePath `$softwareEvidencePath") -and
        -not $verifyPcText.Contains("-Group")
    ) 'Formal PC candidate gate no longer owns exactly one complete software gate'

    $workerPath = Join-Path $testRoot 'lock-worker.ps1'
    $workerSource = @'
param(
    [Parameter(Mandatory = $true)][string]$BuildLockScript,
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$AcquiredPath,
    [string]$ReleasePath
)
$ErrorActionPreference = 'Stop'
. $BuildLockScript
Invoke-WithLeanTTYBuildLock -RepoRoot $RepoRoot -Operation 'workflow-test' -Action {
    [IO.File]::WriteAllText($AcquiredPath, (Get-Date).ToString('o'))
    if ($ReleasePath) {
        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        while (-not (Test-Path -LiteralPath $ReleasePath)) {
            if ($stopwatch.Elapsed.TotalSeconds -ge 5) {
                throw "Timed out waiting for release signal: $ReleasePath"
            }
            Start-Sleep -Milliseconds 50
        }
    }
}
'@
    [IO.File]::WriteAllText(
        $workerPath,
        $workerSource,
        [Text.UTF8Encoding]::new($false)
    )

    $pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
    $firstAcquired = Join-Path $testRoot 'first-acquired'
    $secondAcquired = Join-Path $testRoot 'second-acquired'
    $releaseFirst = Join-Path $testRoot 'release-first'
    $firstProcess = Start-Process -FilePath $pwsh -WindowStyle Hidden -PassThru -ArgumentList @(
        '-NoProfile',
        '-File', $workerPath,
        '-BuildLockScript', (Join-Path $PSScriptRoot 'build-lock.ps1'),
        '-RepoRoot', $repoRoot,
        '-AcquiredPath', $firstAcquired,
        '-ReleasePath', $releaseFirst
    )
    Wait-ForPath -Path $firstAcquired

    $secondProcess = Start-Process -FilePath $pwsh -WindowStyle Hidden -PassThru -ArgumentList @(
        '-NoProfile',
        '-File', $workerPath,
        '-BuildLockScript', (Join-Path $PSScriptRoot 'build-lock.ps1'),
        '-RepoRoot', $repoRoot,
        '-AcquiredPath', $secondAcquired
    )
    Start-Sleep -Milliseconds 500
    Assert-True (-not (Test-Path -LiteralPath $secondAcquired)) (
        'Second build writer acquired the lock while the first still held it'
    )

    [IO.File]::WriteAllText($releaseFirst, 'release')
    Wait-ForPath -Path $secondAcquired
    [void]$firstProcess.WaitForExit(5000)
    [void]$secondProcess.WaitForExit(5000)
    Assert-True ($firstProcess.ExitCode -eq 0) 'First build-lock worker failed'
    Assert-True ($secondProcess.ExitCode -eq 0) 'Second build-lock worker failed'

    Write-Host 'Build workflow regression tests passed.' -ForegroundColor Green
} finally {
    $testRootFull = [IO.Path]::GetFullPath($testRoot)
    if ($testRootFull.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $testRootFull)) {
        Remove-Item -LiteralPath $testRootFull -Recurse -Force
    }
}
