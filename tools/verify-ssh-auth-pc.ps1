<#
.SYNOPSIS
  Verify interactive SSH authentication on a HarmonyOS PC test package.
.DESCRIPTION
  Starts the repository-only SSH fixture with temporary credentials, maps one
  device loopback port to it, drives LeanTTY through raw keyboard events, and
  records non-secret behavior evidence. By default, the retained HAP is
  installed without rebuilding. -DiagnosticHap permits an explicit current
  test package without promoting its evidence to a retained release candidate.
  -VerifyPreferencesUnchanged compares an in-memory SHA-256 before and after
  the selected authentication stages without reading, exporting or persisting
  the Preferences content or digest.
  All temporary credentials and port mappings are removed.
#>
[CmdletBinding()]
param(
    [string]$Target = '',
    [string]$HapPath = '',
    [switch]$DiagnosticHap,
    [switch]$VerifyPreferencesUnchanged,
    [string]$EvidenceDirectory = '',
    [string]$CandidateBasePath = '',
    [string]$UnlockPasswordPath = '',
    [ValidateRange(1024, 65535)]
    [int]$FixturePort = 22222,
    [string]$Distribution = $env:LEANTTY_WSL_DISTRO,
    [ValidateSet(
        'password-success',
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
    )]
    [string[]]$Only = @(),
    [ValidatePattern('^[0-9a-f]{32}$')]
    [string]$PreviousAttemptId = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'candidate-store.ps1')
. (Join-Path $PSScriptRoot 'hdc-common.ps1')
. (Join-Path $PSScriptRoot 'device-regression.ps1')
. (Join-Path $PSScriptRoot 'rust-wsl.ps1')

$harnessStatus = @(git -C $repoRoot status --porcelain --untracked-files=all 2>&1)
if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect SSH authentication harness source state' }
if ($harnessStatus.Count -gt 0) { throw 'SSH authentication harness requires a clean committed tree' }
$harnessCommit = (& git -C $repoRoot rev-parse HEAD 2>&1).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve SSH authentication harness commit' }
$harnessTree = (& git -C $repoRoot rev-parse 'HEAD^{tree}' 2>&1).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve SSH authentication harness tree' }

$hdc = Resolve-Hdc
$Target = Resolve-LeanTTYRegressionTarget -Hdc $hdc -Target $Target
if ([string]::IsNullOrWhiteSpace($UnlockPasswordPath)) {
    $UnlockPasswordPath = Get-LeanTTYDeviceUnlockPasswordPath
}
Assert-LeanTTYCredentialPathOutsideRepository `
    -CredentialPath $UnlockPasswordPath `
    -RepositoryRoot $repoRoot

$candidateRoot = Get-LeanTTYCandidateRoot `
    -RepoRoot $repoRoot `
    -CandidateBasePath $CandidateBasePath
$candidateRecords = @(Get-LeanTTYCandidateRecords -CandidateRoot $candidateRoot)
$harnessDifferencePaths = @()
if ($DiagnosticHap) {
    if ([string]::IsNullOrWhiteSpace($HapPath)) {
        throw '-DiagnosticHap requires an explicit -HapPath'
    }
    $resolvedHap = [IO.Path]::GetFullPath($HapPath)
    if (-not (Test-Path -LiteralPath $resolvedHap -PathType Leaf)) {
        throw "Diagnostic HAP is missing: $resolvedHap"
    }
    $candidate = [pscustomobject][ordered]@{
        sha256 = (Get-FileHash -LiteralPath $resolvedHap -Algorithm SHA256).Hash.ToLowerInvariant()
        hapPath = $resolvedHap
        gitCommit = $null
        gitTree = $null
        gitDirty = $null
        retained = $false
        provenance = 'explicit-unretained-diagnostic-hap'
    }
} elseif ([string]::IsNullOrWhiteSpace($HapPath)) {
    $candidate = $candidateRecords | Select-Object -First 1
    if ($null -eq $candidate) { throw 'No retained candidate exists; run tools/verify-pc.ps1 first' }
} else {
    $resolvedHap = [IO.Path]::GetFullPath($HapPath)
    if (-not (Test-Path -LiteralPath $resolvedHap -PathType Leaf)) {
        throw "Candidate HAP is missing: $resolvedHap"
    }
    $requestedHash = (Get-FileHash -LiteralPath $resolvedHap -Algorithm SHA256).Hash.ToLowerInvariant()
    $candidate = $candidateRecords | Where-Object { $_.sha256 -eq $requestedHash } | Select-Object -First 1
    if ($null -eq $candidate) { throw 'The selected HAP is not a retained verified candidate' }
}
if (-not $DiagnosticHap) {
    if ($candidate.gitDirty) {
        throw 'SSH authentication evidence requires a clean committed candidate'
    }
    $harnessDifferencePaths = @(Assert-LeanTTYCandidateHarnessCompatibility `
        -RepoRoot $repoRoot `
        -Candidate $candidate `
        -AllowedHarnessPaths @(
            'tools/verify-ssh-auth-pc.ps1',
            'tools/verify-terminal-search-pc.ps1',
            'tools/device-regression.ps1',
            'tools/start-ssh-auth-fixture.ps1',
            'tools/test-device-regression.ps1',
            'tools/candidate-store.ps1',
            'tools/package-policy.ps1',
            'tools/test-build-workflows.ps1',
            'leantty_ssh/ssh-auth-fixture/src/main.rs',
            'docs/quality-strategy.md',
            'docs/design/ssh-authentication.md',
            'docs/design/terminal-search.md',
            'docs/next-work.md',
            'docs/dev-environment.md'
        ))
}

if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
    $EvidenceDirectory = Join-Path $repoRoot (
        'build\verification\device-ssh-auth-' +
        [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    )
}
$EvidenceDirectory = [IO.Path]::GetFullPath($EvidenceDirectory)
New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null
$evidencePath = Join-Path $EvidenceDirectory 'device-ssh-auth.json'
$liveStatusPath = Join-Path $EvidenceDirectory 'live-status.json'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'leantty-ssh-auth-device-' + [Guid]::NewGuid().ToString('N')
)
$fixtureControl = Join-Path $fixtureRoot 'control'
$fixtureStdout = Join-Path $fixtureRoot 'stdout.log'
$fixtureStderr = Join-Path $fixtureRoot 'stderr.log'
New-Item -ItemType Directory -Path $fixtureRoot | Out-Null

$checks = [Collections.Generic.List[object]]::new()
$startedAt = [DateTimeOffset]::UtcNow
$fixtureProcess = $null
$fixtureLinuxPid = 0
$mappingActive = $false
$awakeLeaseActive = $false
$awakeLeaseResult = 'not-acquired'
$awakeLeaseFailure = ''
$cleanupResult = 'not-started'
$cleanupFailure = ''
$deviceModel = ''
$deviceAbi = ''
$deviceTransport = ''
$deviceUnlockResult = 'not-attempted'
$appPid = ''
$credentials = @{}
$secrets = @()
$keyName = 'ltty_reg_' + [Guid]::NewGuid().ToString('N').Substring(0, 10)
$keyPassphrase = New-LeanTTYRegressionSecret
$keyCleanupRequired = $false
$keyDeletePathUsed = $false
$keyAbsenceAudited = $false
$fixtureProcessAbsent = $false
$failure = ''
$scenarioResult = 'failed'
$caughtError = $null
$preferencesDigestBefore = ''
$preferencesDigestAfter = ''
$preferencesDigestUnchanged = $null
$bellEvidence = [ordered]@{
    selected = $false
    activePaneStayedTransient = $null
    inactiveTabAttentionPersisted = $null
    inactiveTabAttentionClearedOnEntry = $null
    splitPaneSourcePersisted = $null
    splitPaneSourceClearedOnFocus = $null
    repeatedBellCallbacksCoalesced = $null
    screenshots = @()
}
$performanceEvidence = [ordered]@{
    selected = $false
    gpu = $null
    modes = @()
    restoredMode = $null
}
$stageStartedAt = $null
$currentStage = 'initialization'
$failureDomain = 'none'
$attemptId = [Guid]::NewGuid().ToString('N')
$runMode = if ($Only.Count -eq 0 -and -not $DiagnosticHap) { 'acceptance' } else { 'diagnostic' }
$availableStages = @(
    'password-success',
    'terminal-key-input',
    'transport-main-path',
    'performance-matrix',
    'bell-attention',
    'password-kbdint-mixed-echo',
    'multiround-wrong-answer-recovery',
    'generated-disposable-auth-key',
    'publickey-unencrypted',
    'publickey-then-password',
    'publickey-then-keyboard-interactive',
    'keyboard-interactive-zero-prompt',
    'unsupported-method-error-and-recovery',
    'ctrl-c-authentication-cancellation-and-recovery',
    'pane-close-during-hidden-prompt-and-recovery',
    'encrypted-disposable-auth-key',
    'publickey-encrypted-passphrase',
    'parallel-pane-authentication',
    'minimize-restore-hidden-prompt',
    'process-stop-during-hidden-prompt-cleanup',
    'deleted-disposable-auth-key'
)
$selectedStages = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase
)
if ($Only.Count -eq 0) {
    foreach ($name in $availableStages) { [void]$selectedStages.Add($name) }
} else {
    foreach ($name in $Only) { [void]$selectedStages.Add($name) }
    $keyStages = @(
        'publickey-unencrypted',
        'publickey-then-password',
        'publickey-then-keyboard-interactive',
        'publickey-encrypted-passphrase'
    )
    if (@($Only | Where-Object { $_ -in $keyStages }).Count -gt 0) {
        [void]$selectedStages.Add('generated-disposable-auth-key')
        [void]$selectedStages.Add('deleted-disposable-auth-key')
    }
    if ($Only -contains 'publickey-encrypted-passphrase') {
        [void]$selectedStages.Add('encrypted-disposable-auth-key')
    }
}
$selectedStageNames = @($availableStages | Where-Object { $selectedStages.Contains($_) })

function Test-AuthStageSelected {
    param([Parameter(Mandatory = $true)][string]$Name)
    return $selectedStages.Contains($Name)
}

function Get-LeanTTYFixtureStageBudgetSeconds {
    param([Parameter(Mandatory = $true)][string]$StageName)
    $budgets = @{
        'password-success' = 150
        'terminal-key-input' = 180
        'transport-main-path' = 300
        'performance-matrix' = 540
        'bell-attention' = 240
        'password-kbdint-mixed-echo' = 300
        'multiround-wrong-answer-recovery' = 420
        'generated-disposable-auth-key' = 60
        'publickey-unencrypted' = 60
        'publickey-then-password' = 150
        'publickey-then-keyboard-interactive' = 240
        'keyboard-interactive-zero-prompt' = 60
        'unsupported-method-error-and-recovery' = 150
        'ctrl-c-authentication-cancellation-and-recovery' = 300
        'pane-close-during-hidden-prompt-and-recovery' = 300
        'encrypted-disposable-auth-key' = 180
        'publickey-encrypted-passphrase' = 150
        'parallel-pane-authentication' = 480
        'minimize-restore-hidden-prompt' = 240
        'process-stop-during-hidden-prompt-cleanup' = 240
        'deleted-disposable-auth-key' = 90
    }
    if (-not $budgets.ContainsKey($StageName)) {
        throw "No fixture budget is declared for SSH authentication stage: $StageName"
    }
    return [int]$budgets[$StageName]
}

function Get-LeanTTYFixtureRunSeconds {
    param([Parameter(Mandatory = $true)][string[]]$StageNames)
    $runSeconds = 180
    foreach ($stageName in $StageNames) {
        $runSeconds += Get-LeanTTYFixtureStageBudgetSeconds -StageName $stageName
    }
    return [Math]::Max(300, $runSeconds)
}

$fixtureRunSeconds = Get-LeanTTYFixtureRunSeconds -StageNames $selectedStageNames

function Write-AuthLiveStatus {
    param(
        [Parameter(Mandatory = $true)][string]$State,
        [string]$Stage = $currentStage,
        [string]$Detail = ''
    )
    $status = [ordered]@{
        schemaVersion = 1
        attemptId = $attemptId
        previousAttemptId = $PreviousAttemptId
        retryCount = 0
        runMode = $runMode
        state = $State
        stage = $Stage
        completedChecks = @($checks | ForEach-Object { $_.name })
        updatedAt = [DateTimeOffset]::UtcNow.ToString('o')
        detail = $Detail
    }
    [IO.File]::WriteAllText(
        $liveStatusPath,
        (ConvertTo-Json -InputObject $status -Depth 4),
        [Text.UTF8Encoding]::new($false)
    )
}

function Resolve-AuthFailureDomain {
    param([Parameter(Mandatory = $true)][string]$Message)
    foreach ($domain in @('product', 'harness', 'environment', 'infrastructure', 'invalid')) {
        if ($Message.StartsWith("[$domain]", [StringComparison]::OrdinalIgnoreCase)) {
            return $domain
        }
    }
    if ($currentStage -eq 'fixture-and-device-preflight' -or $currentStage -eq 'initialization') {
        return 'infrastructure'
    }
    if ($Message -match '(?i)fixture|\bhdc\b|device target|reverse mapping|launcher process') {
        return 'infrastructure'
    }
    if ($Message -match '(?i)layout|selector|node|button|confirmation did not appear') {
        return 'harness'
    }
    if ($Message -match '(?i)focus|foreground|window|notification|minimize|restore') {
        return 'environment'
    }
    return 'product'
}

function Add-AuthCheck {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][long]$DurationMs
    )
    $checks.Add([pscustomobject]@{ name = $Name; result = 'passed'; durationMs = $DurationMs })
    Write-Host "[device-auth] PASS $Name ($DurationMs ms)" -ForegroundColor Green
}

function Start-AuthStage {
    param([Parameter(Mandatory = $true)][string]$Name)
    Write-Host "[device-auth] START $Name"
    $script:currentStage = $Name
    Write-AuthLiveStatus -State 'running' -Stage $Name
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    $script:stageStartedAt = [Diagnostics.Stopwatch]::StartNew()
}

function Assert-NoSecretExposure {
    param([Parameter(Mandatory = $true)][string]$LayoutName)
    $logs = Get-LeanTTYAppLogs -Hdc $hdc -Target $Target -ProcessId $appPid
    foreach ($secret in $secrets) {
        if (-not [string]::IsNullOrEmpty($secret) -and $logs.Contains($secret)) {
            throw 'HarmonyOS application logs exposed a temporary SSH fixture secret'
        }
    }
    $layout = Get-LeanTTYDeviceLayout `
        -Hdc $hdc `
        -Target $Target `
        -LocalPath (Join-Path $EvidenceDirectory $LayoutName)
    Assert-LeanTTYLayoutExcludesValues -Layout $layout -Values $secrets
}

function Complete-AuthStage {
    param([Parameter(Mandatory = $true)][string]$Name)
    Assert-NoSecretExposure -LayoutName ("layout-$Name.json")
    if ($null -eq $stageStartedAt) { throw 'SSH authentication stage timing was not started' }
    Add-AuthCheck -Name $Name -DurationMs $stageStartedAt.ElapsedMilliseconds
    $script:stageStartedAt = $null
    Write-AuthLiveStatus -State 'running' -Stage $Name -Detail 'passed'
}

function Wait-AuthLog {
    param(
        [Parameter(Mandatory = $true)][string]$Pattern,
        [int]$TimeoutSeconds = 20
    )
    Wait-LeanTTYAppLog `
        -Hdc $hdc `
        -Target $Target `
        -ProcessId $appPid `
        -Pattern $Pattern `
        -TimeoutSeconds $TimeoutSeconds | Out-Null
}

function Wait-FixtureLog {
    param(
        [Parameter(Mandatory = $true)][string]$Pattern,
        [int]$TimeoutSeconds = 30
    )
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if (Test-Path -LiteralPath $fixtureStderr -PathType Leaf) {
            $text = Read-FixtureLogText
            if ($text -match $Pattern) { return $text }
        }
        Start-Sleep -Milliseconds 200
    }
    throw "Timed out waiting for SSH fixture state: $Pattern"
}

function Read-FixtureLogText {
    $stream = [IO.File]::Open(
        $fixtureStderr,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::ReadWrite
    )
    try {
        $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false), $true)
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally {
        $stream.Dispose()
    }
}

function Get-FixtureLogMatchCount {
    param([Parameter(Mandatory = $true)][string]$Pattern)
    if (-not (Test-Path -LiteralPath $fixtureStderr -PathType Leaf)) { return 0 }
    return [regex]::Matches((Read-FixtureLogText), $Pattern).Count
}

function Wait-FixtureLogMatchCount {
    param(
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][int]$GreaterThan,
        [int]$TimeoutSeconds = 30
    )
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $count = Get-FixtureLogMatchCount -Pattern $Pattern
        if ($count -gt $GreaterThan) { return $count }
        Start-Sleep -Milliseconds 200
    }
    throw "Timed out waiting for a new SSH fixture event: $Pattern"
}

function Invoke-SerializedAuthText {
    param([Parameter(Mandatory = $true)][string]$Value)
    foreach ($character in $Value.ToCharArray()) {
        Invoke-LeanTTYDeviceText `
            -Hdc $hdc `
            -Target $Target `
            -Text ([string]$character)
    }
}

function Submit-AuthValue {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$LayoutName
    )
    Focus-ActiveCommandInput -LayoutName ($LayoutName + '.focus.json')
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Invoke-SerializedAuthText -Value $Value
    Assert-NoSecretExposure -LayoutName $LayoutName
    Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $Target -KeyCode 2054
    Wait-AuthLog -Pattern 'ACCEPTANCE_INPUT_SUBMIT' -TimeoutSeconds 10
}

function Focus-ActiveCommandInput {
    param([Parameter(Mandatory = $true)][string]$LayoutName)
    Activate-RegressionWindow
    $layoutPath = Join-Path $EvidenceDirectory $LayoutName
    $inputNode = $null
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $layout = Get-LeanTTYDeviceLayout `
            -Hdc $hdc `
            -Target $Target `
            -LocalPath $layoutPath
        $nodes = @(Get-LeanTTYTerminalInputNodes -Layout $layout)
        $focusedNodes = @($nodes | Where-Object { [string]$_.attributes.focused -eq 'true' })
        if ($focusedNodes.Count -eq 1) {
            $inputNode = $focusedNodes[0]
        } elseif ($nodes.Count -eq 1) {
            $inputNode = $nodes[0]
        }
        if ($null -eq $inputNode -and $stopwatch.Elapsed.TotalSeconds -lt 10) {
            Start-Sleep -Milliseconds 200
        }
    } while ($null -eq $inputNode -and $stopwatch.Elapsed.TotalSeconds -lt 10)
    if ($null -eq $inputNode) {
        throw '[environment] Unable to identify the active terminal input before command submission'
    }
    Set-LeanTTYTerminalInputFocus `
        -Hdc $hdc `
        -Target $Target `
        -InputNode $inputNode `
        -LocalPath $layoutPath `
        -TimeoutSeconds 10 | Out-Null
}

function Submit-FocusedDeviceCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$LayoutName
    )
    $submittedCommandPattern =
        'ACCEPTANCE_INPUT_SUBMIT.*kind=command,input=' + [regex]::Escape($Command)
    for ($commandAttempt = 1; $commandAttempt -le 3; $commandAttempt++) {
        Focus-ActiveCommandInput -LayoutName $LayoutName
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
        Invoke-LeanTTYDeviceText -Hdc $hdc -Target $Target -Text $Command
        Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $Target -KeyCode 2054
        try {
            Wait-AuthLog -Pattern $submittedCommandPattern -TimeoutSeconds 10
            return
        } catch {
            if ($commandAttempt -ge 3) {
                throw '[harness] Device did not submit the focused command after three attempts'
            }
            Invoke-LeanTTYDeviceCtrlC -Hdc $hdc -Target $Target
        }
    }
}

function Assert-AuthCommandLoopbackTarget {
    $logs = ''
    try {
        $logs = Wait-LeanTTYAppLog `
            -Hdc $hdc `
            -Target $Target `
            -ProcessId $appPid `
            -Pattern 'SSH connect initiated:' `
            -TimeoutSeconds 5
    } catch {
        throw '[environment] Device key injection changed the SSH command target'
    }
    $matches = [regex]::Matches($logs, 'SSH connect initiated:\s+(?<host>[^\s]+)')
    if ($matches.Count -eq 0 -or
        $matches[$matches.Count - 1].Groups['host'].Value -cne '127.0.0.1') {
        throw '[environment] Device key injection changed the SSH command target'
    }
}

function Start-AuthCommand {
    param(
        [Parameter(Mandatory = $true)][string]$User,
        [string]$Identity = ''
    )
    $identityOption = if ([string]::IsNullOrWhiteSpace($Identity)) { '' } else { " -i $Identity" }
    Submit-FocusedDeviceCommand `
        -Command "ssh -p $FixturePort$identityOption $User@127.0.0.1" `
        -LayoutName 'layout-command-focus.json'
    Assert-AuthCommandLoopbackTarget
}

function Close-FixtureShell {
    for ($exitAttempt = 1; $exitAttempt -le 3; $exitAttempt++) {
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
        Submit-ConnectedInput -Text 'ltty-exit'
        try {
            Wait-FixtureLog -Pattern 'shell command=exit result=closed' -TimeoutSeconds 10 | Out-Null
            break
        } catch {
            if ($exitAttempt -ge 3) {
                throw '[harness] Device did not submit the fixture exit command after three attempts'
            }
            Invoke-LeanTTYDeviceCtrlC -Hdc $hdc -Target $Target
        }
    }
    Wait-AuthLog -Pattern 'SSH closed, exitCode=0'
}

function Submit-ConnectedInput {
    param([Parameter(Mandatory = $true)][string]$Text)
    Invoke-LeanTTYDeviceText -Hdc $hdc -Target $Target -Text $Text
    Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $Target -KeyCode 2054
}

function Submit-ConnectedInputUntilFixtureEvent {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [ValidateRange(1, 60)][int]$TimeoutSeconds = 10
    )
    for ($inputAttempt = 1; $inputAttempt -le 3; $inputAttempt++) {
        $matchCount = Get-FixtureLogMatchCount -Pattern $Pattern
        Submit-ConnectedInput -Text $Text
        try {
            Wait-FixtureLogMatchCount `
                -Pattern $Pattern `
                -GreaterThan $matchCount `
                -TimeoutSeconds $TimeoutSeconds | Out-Null
            return
        } catch {
            if ($inputAttempt -ge 3) {
                throw '[harness] Device did not deliver connected input after three attempts'
            }
        }
    }
}

function Submit-ConnectedInputUntilAuthEvent {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [ValidateRange(1, 60)][int]$TimeoutSeconds = 10
    )
    for ($inputAttempt = 1; $inputAttempt -le 3; $inputAttempt++) {
        Submit-ConnectedInput -Text $Text
        try {
            Wait-AuthLog -Pattern $Pattern -TimeoutSeconds $TimeoutSeconds
            return
        } catch {
            if ($inputAttempt -ge 3) {
                throw '[harness] Connected input did not produce the expected application event after three attempts'
            }
        }
    }
}

function Invoke-LeanTTYPasteShortcut {
    # HAD-W32 does not synthesize a trusted ArkWeb paste event for a two-key
    # automation chord. Alt is ignored by the Web Ctrl+V route while allowing
    # the system UI injector to deliver the complete browser key event.
    & $hdc -t $Target shell 'uitest uiInput keyEvent 2072 2045 2038' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to invoke LeanTTY paste shortcut' }
    # The uitest chord can leave synthetic modifiers latched after ArkWeb has
    # accepted the trusted paste event. Release every member explicitly so the
    # next device-paced command is ordinary terminal input.
    & $hdc -t $Target shell 'uinput -K -u 2038 -u 2045 -u 2072' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to release LeanTTY paste shortcut modifiers' }
}

function Save-SafeDiagnosticText {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$FileName
    )
    foreach ($secret in $secrets) {
        if (-not [string]::IsNullOrEmpty($secret)) {
            $Text = $Text.Replace($secret, '[REDACTED]')
        }
    }
    [IO.File]::WriteAllText(
        (Join-Path $EvidenceDirectory $FileName),
        $Text,
        [Text.UTF8Encoding]::new($false)
    )
}

function Invoke-AuthSplitShortcut {
    & $hdc -t $Target shell (
        'uinput -K -d 2072 -d 2047 -d 2020 -u 2020 -u 2047 -u 2072'
    ) | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to invoke LeanTTY split shortcut' }
}

function Invoke-AuthWorkspaceShortcut {
    param([Parameter(Mandatory = $true)][ValidateSet(
        'new-tab', 'close-active', 'next-tab', 'focus-left', 'focus-right'
    )][string]$Action)
    $command = switch ($Action) {
        'new-tab' { 'uinput -K -d 2072 -d 2047 -d 2036 -u 2036 -u 2047 -u 2072' }
        'close-active' { 'uinput -K -d 2072 -d 2047 -d 2039 -u 2039 -u 2047 -u 2072' }
        'next-tab' { 'uinput -K -d 2072 -d 2049 -u 2049 -u 2072' }
        'focus-left' { 'uinput -K -d 2072 -d 2045 -d 2014 -u 2014 -u 2045 -u 2072' }
        'focus-right' { 'uinput -K -d 2072 -d 2045 -d 2015 -u 2015 -u 2045 -u 2072' }
    }
    & $hdc -t $Target shell $command | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Unable to invoke LeanTTY workspace action: $Action" }
}

function Get-AuthTabNodes {
    param([Parameter(Mandatory = $true)]$Layout)
    $root = @(Get-LeanTTYLayoutNodes -Node $Layout | Where-Object {
        [string]$_.attributes.bundleName -eq 'com.leantty.app'
    } | Select-Object -First 1)
    if ($root.Count -ne 1 -or
        [string]$root[0].attributes.bounds -notmatch '^\[\d+,(?<top>\d+)\]\[\d+,\d+\]$') {
        throw '[harness] LeanTTY root bounds were not found'
    }
    $rootTop = [int]$Matches.top
    return @(Get-LeanTTYLayoutNodes -Node $Layout | Where-Object {
        if ([string]$_.attributes.type -ne 'Stack' -or
            [string]$_.attributes.clickable -ne 'true' -or
            [string]::IsNullOrWhiteSpace([string]$_.attributes.description)) {
            return $false
        }
        $bounds = [string]$_.attributes.bounds
        if ($bounds -notmatch '^\[\d+,(?<top>\d+)\]\[\d+,(?<bottom>\d+)\]$') { return $false }
        return [int]$Matches.top -eq $rootTop -and ([int]$Matches.bottom - $rootTop) -eq 76
    })
}

function Wait-AuthTabCount {
    param(
        [Parameter(Mandatory = $true)][ValidateRange(1, 2)][int]$Count,
        [Parameter(Mandatory = $true)][string]$LayoutName
    )
    $path = Join-Path $EvidenceDirectory $LayoutName
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $layout = Get-LeanTTYDeviceLayout -Hdc $hdc -Target $Target -LocalPath $path
        if (@(Get-AuthTabNodes -Layout $layout).Count -eq $Count) { return $layout }
        Start-Sleep -Milliseconds 200
    } while ($stopwatch.Elapsed.TotalSeconds -lt 20)
    throw "[harness] Timed out waiting for LeanTTY tab count: $Count"
}

function Invoke-AuthLayoutNodeClick {
    param([Parameter(Mandatory = $true)]$Node)
    $center = Get-LeanTTYBoundsCenter -Bounds ([string]$Node.attributes.bounds)
    & $hdc -t $Target shell "uitest uiInput click $($center.x) $($center.y)" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '[environment] HarmonyOS layout node click failed' }
}

function Open-AuthToolMenu {
    param([Parameter(Mandatory = $true)][string]$LayoutPrefix)
    $layout = Get-LeanTTYDeviceLayout -Hdc $hdc -Target $Target `
        -LocalPath (Join-Path $EvidenceDirectory "$LayoutPrefix-before-menu.json")
    $root = @(Get-LeanTTYLayoutNodes -Node $layout | Where-Object {
        [string]$_.attributes.bundleName -eq 'com.leantty.app'
    } | Select-Object -First 1)
    if ($root.Count -ne 1 -or
        [string]$root[0].attributes.bounds -notmatch '^\[\d+,(?<top>\d+)\]\[\d+,\d+\]$') {
        throw '[harness] LeanTTY root bounds were not found for the tool menu'
    }
    $contentTop = [int]$Matches.top + 76
    $candidates = @(Get-LeanTTYLayoutNodes -Node $layout | Where-Object {
        if ([string]$_.attributes.type -ne 'Stack' -or
            [string]$_.attributes.clickable -ne 'true' -or
            -not [string]::IsNullOrWhiteSpace([string]$_.attributes.text) -or
            -not [string]::IsNullOrWhiteSpace([string]$_.attributes.description) -or
            -not [string]::IsNullOrWhiteSpace([string]$_.attributes.id)) {
            return $false
        }
        $bounds = [string]$_.attributes.bounds
        if ($bounds -notmatch '^\[(?<left>\d+),(?<top>\d+)\]\[(?<right>\d+),(?<bottom>\d+)\]$') {
            return $false
        }
        $width = [int]$Matches.right - [int]$Matches.left
        $height = [int]$Matches.bottom - [int]$Matches.top
        return [int]$Matches.left -gt 1000 -and [int]$Matches.bottom -le $contentTop -and
            $width -ge 40 -and $width -le 90 -and $height -ge 40 -and $height -le 90
    })
    if ($candidates.Count -ne 1) { throw '[harness] LeanTTY tool menu button was not uniquely identified' }
    Invoke-AuthLayoutNodeClick -Node $candidates[0]

    $menuPath = Join-Path $EvidenceDirectory "$LayoutPrefix-menu.json"
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $menuLayout = Get-LeanTTYDeviceLayout -Hdc $hdc -Target $Target -LocalPath $menuPath
        $labels = @(Get-LeanTTYLayoutNodes -Node $menuLayout | Where-Object {
            [string]$_.attributes.type -eq 'Text' -and
            [string]$_.attributes.text -in @('Off', 'Low', 'Medium', 'High', 'Extreme')
        })
        if ($labels.Count -eq 1) { return $menuLayout }
        Start-Sleep -Milliseconds 200
    } while ($stopwatch.Elapsed.TotalSeconds -lt 10)
    throw '[environment] LeanTTY transparency menu row did not open'
}

function Set-AuthTransparencyMode {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Off', 'Low', 'Medium', 'High', 'Extreme')]
        [string]$Mode,
        [Parameter(Mandatory = $true)][string]$LayoutPrefix
    )
    $order = @('Off', 'Low', 'Medium', 'High', 'Extreme')
    for ($step = 0; $step -lt 6; $step++) {
        $layout = Open-AuthToolMenu -LayoutPrefix "$LayoutPrefix-$step"
        $labels = @(Get-LeanTTYLayoutNodes -Node $layout | Where-Object {
            [string]$_.attributes.type -eq 'Text' -and
            [string]$_.attributes.text -in $order
        })
        if ($labels.Count -ne 1) { throw '[harness] Transparency mode label was not unique' }
        $current = [string]$labels[0].attributes.text
        if ($current -eq $Mode) {
            Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $Target -KeyCode 2070
            return
        }
        $parent = ([string]$labels[0].attributes.hierarchy) -replace ',[^,]+$', ''
        $direction = if ([Array]::IndexOf($order, $Mode) -gt [Array]::IndexOf($order, $current)) {
            '+'
        } else {
            '−'
        }
        $buttons = @(Get-LeanTTYLayoutNodes -Node $layout | Where-Object {
            [string]$_.attributes.type -eq 'Text' -and
            [string]$_.attributes.text -eq $direction -and
            [string]$_.attributes.hierarchy -like "$parent,*" -and
            [string]$_.attributes.clickable -eq 'true' -and
            [string]$_.attributes.enabled -eq 'true'
        })
        if ($buttons.Count -ne 1) { throw "[harness] Transparency $direction button was not unique" }
        Invoke-AuthLayoutNodeClick -Node $buttons[0]
        Start-Sleep -Milliseconds 250
        Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $Target -KeyCode 2070
    }
    throw "[product] Transparency mode did not reach $Mode"
}

function Get-AuthProcessMemorySample {
    $processLines = @(& $hdc -t $Target shell 'ps -ef' 2>&1 | Where-Object {
        [string]$_ -match 'com\.leantty\.app(?::(?:gpu|render))?\s*$'
    })
    $processes = [Collections.Generic.List[object]]::new()
    foreach ($line in $processLines) {
        $fields = @(([string]$line).Trim() -split '\s+')
        if ($fields.Count -lt 8 -or $fields[1] -notmatch '^\d+$') { continue }
        $pidValue = [int]$fields[1]
        $status = @(& $hdc -t $Target shell "cat /proc/$pidValue/status" 2>&1) -join "`n"
        $rssMatch = [regex]::Match($status, '(?m)^VmRSS:\s+(?<kb>\d+)\s+kB$')
        $hwmMatch = [regex]::Match($status, '(?m)^VmHWM:\s+(?<kb>\d+)\s+kB$')
        $rsText = @(& $hdc -t $Target shell "hidumper -s 10 -a 'dumpExistPidMem $pidValue'" 2>&1) -join "`n"
        $gpuMatch = [regex]::Match($rsText, 'allGpuSize:\s*(?<bytes>\d+)')
        $processes.Add([pscustomobject][ordered]@{
            name = [string]$fields[-1]
            pid = $pidValue
            rssKb = $(if ($rssMatch.Success) { [int64]$rssMatch.Groups['kb'].Value } else { $null })
            highWaterKb = $(if ($hwmMatch.Success) { [int64]$hwmMatch.Groups['kb'].Value } else { $null })
            renderServiceGpuBytes = $(if ($gpuMatch.Success) { [int64]$gpuMatch.Groups['bytes'].Value } else { $null })
        })
    }
    return @($processes)
}

function Get-AuthHitchSample {
    $text = @(& $hdc -t $Target shell "hidumper -s 10 -a 'hitchs app0'" 2>&1) -join "`n"
    $over66 = [regex]::Match($text, 'more than 66 ms\s+(?<count>\d+)')
    $over33 = [regex]::Match($text, 'more than 33 ms\s+(?<count>\d+)')
    $over16 = [regex]::Match($text, 'more than 16\.67 ms\s+(?<count>\d+)')
    return [pscustomobject][ordered]@{
        over66Ms = $(if ($over66.Success) { [int]$over66.Groups['count'].Value } else { $null })
        over33Ms = $(if ($over33.Success) { [int]$over33.Groups['count'].Value } else { $null })
        over16_67Ms = $(if ($over16.Success) { [int]$over16.Groups['count'].Value } else { $null })
    }
}

function Get-AuthPerfRenderRecord {
    param([Parameter(Mandatory = $true)][string]$CaseId)
    $logs = Get-LeanTTYAppLogs -Hdc $hdc -Target $Target -ProcessId $appPid
    foreach ($match in [regex]::Matches($logs, 'PERF render (?<json>\{[^\r\n]+\})')) {
        try {
            $record = $match.Groups['json'].Value | ConvertFrom-Json
            if ([string]$record.caseId -eq $CaseId) { return $record }
        } catch {}
    }
    throw "[harness] PERF render record was not found for $CaseId"
}

function Invoke-AuthPerfSample {
    param([Parameter(Mandatory = $true)][string]$CaseId)
    for ($commandAttempt = 1; $commandAttempt -le 3; $commandAttempt++) {
        $preparedPattern = 'perf case=' + [regex]::Escape($CaseId) + ' bytes=\d+ state=prepared'
        $preparedCount = Get-FixtureLogMatchCount -Pattern $preparedPattern
        Submit-ConnectedInput -Text "ltty-perf-prepare $CaseId 12000 80"
        try {
            Wait-FixtureLogMatchCount `
                -Pattern $preparedPattern `
                -GreaterThan $preparedCount `
                -TimeoutSeconds 15 | Out-Null
        } catch {
            if ($commandAttempt -lt 3) { continue }
            throw "[harness] Fixture did not accept the PERF prepare command for $CaseId after three attempts"
        }

        $runPattern = "perf case=$CaseId state=run"
        $runCount = Get-FixtureLogMatchCount -Pattern ([regex]::Escape($runPattern))
        Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
        Submit-ConnectedInput -Text "ltty-perf-run $CaseId"
        try {
            Wait-FixtureLogMatchCount `
                -Pattern ([regex]::Escape($runPattern)) `
                -GreaterThan $runCount `
                -TimeoutSeconds 8 | Out-Null
        } catch {
            if ($commandAttempt -lt 3) { continue }
            throw "[harness] Fixture did not accept the PERF run command for $CaseId after three attempts"
        }
        Wait-AuthLog `
            -Pattern ('PERF render .*"caseId":"' + $CaseId + '".*"completenessPercent":100') `
            -TimeoutSeconds 30
        $record = Get-AuthPerfRenderRecord -CaseId $CaseId
        $record | Add-Member -NotePropertyName commandAttempts -NotePropertyValue $commandAttempt
        return $record
    }
    throw "[harness] PERF sample did not complete for $CaseId"
}

function Wait-AuthPaneCount {
    param(
        [Parameter(Mandatory = $true)][ValidateRange(1, 2)][int]$Count,
        [Parameter(Mandatory = $true)][string]$LayoutName
    )
    return Wait-LeanTTYTerminalInputCount `
        -Hdc $hdc `
        -Target $Target `
        -LocalPath (Join-Path $EvidenceDirectory $LayoutName) `
        -Count $Count `
        -TimeoutSeconds 20
}

function Focus-AuthPane {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('left', 'right')][string]$Side,
        [Parameter(Mandatory = $true)][string]$LayoutName
    )
    $path = Join-Path $EvidenceDirectory $LayoutName
    $layout = Wait-AuthPaneCount -Count 2 -LayoutName $LayoutName
    $nodes = @(Get-LeanTTYTerminalInputNodes -Layout $layout)
    $index = if ($Side -eq 'left') { 0 } else { 1 }
    $center = Get-LeanTTYBoundsCenter -Bounds ([string]$nodes[$index].attributes.bounds)
    & $hdc -t $Target shell "uitest uiInput click $($center.x) $($center.y)" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "[environment] Unable to focus $Side LeanTTY pane" }

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $layout = Get-LeanTTYDeviceLayout -Hdc $hdc -Target $Target -LocalPath $path
        $nodes = @(Get-LeanTTYTerminalInputNodes -Layout $layout)
        if ($nodes.Count -eq 2 -and [string]$nodes[$index].attributes.focused -eq 'true' -and
            [string]$nodes[1 - $index].attributes.focused -ne 'true') {
            return
        }
        Start-Sleep -Milliseconds 200
    } while ($stopwatch.Elapsed.TotalSeconds -lt 10)
    throw "[environment] Timed out focusing $Side LeanTTY pane"
}

function Activate-RegressionWindow {
    & $hdc -t $Target shell 'aa start -a EntryAbility -b com.leantty.app' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to activate LeanTTY regression window' }
    $activatedPid = (@(& $hdc -t $Target shell 'pidof com.leantty.app' 2>&1) -join "`n").Trim()
    if ($activatedPid -ne $appPid) { throw '[environment] LeanTTY process changed while activating its window' }
}

function Invoke-ActivePaneCloseButton {
    param([Parameter(Mandatory = $true)][string]$LayoutName)
    $layout = Wait-AuthPaneCount -Count 2 -LayoutName $LayoutName
    $button = @(Get-LeanTTYLayoutNodes -Node $layout | Where-Object {
        [string]$_.attributes.text -eq '×' -and
        [string]$_.attributes.clickable -eq 'true' -and
        [string]$_.attributes.visible -eq 'true'
    } | Select-Object -First 1)
    if ($button.Count -ne 1) { throw '[harness] LeanTTY active-pane close button was not found' }
    $center = Get-LeanTTYBoundsCenter -Bounds ([string]$button[0].attributes.bounds)
    & $hdc -t $Target shell "uitest uiInput click $($center.x) $($center.y)" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to click the LeanTTY active-pane close button' }
}

function Ensure-SingleAuthPane {
    param([Parameter(Mandatory = $true)][string]$LayoutName)
    Activate-RegressionWindow
    $path = Join-Path $EvidenceDirectory $LayoutName
    $layout = Get-LeanTTYDeviceLayout -Hdc $hdc -Target $Target -LocalPath $path
    $count = @(Get-LeanTTYTerminalInputNodes -Layout $layout).Count
    if ($count -eq 1) { return }
    if ($count -ne 2) { throw "Unexpected LeanTTY pane count: $count" }
    Focus-AuthPane -Side 'right' -LayoutName $LayoutName
    Invoke-ActivePaneCloseButton -LayoutName $LayoutName
    Wait-AuthPaneCount -Count 1 -LayoutName $LayoutName | Out-Null
}

function Split-AuthPane {
    Invoke-AuthSplitShortcut
    Wait-AuthPaneCount -Count 2 -LayoutName 'layout-parallel-split.json' | Out-Null
}

function Minimize-RegressionWindow {
    $layoutName = 'layout-before-minimize.json'
    $layout = Get-LeanTTYDeviceLayout `
        -Hdc $hdc `
        -Target $Target `
        -LocalPath (Join-Path $EvidenceDirectory $layoutName)
    $button = @(Get-LeanTTYLayoutNodes -Node $layout | Where-Object {
        [string]$_.attributes.id -eq 'EnhanceMinimizeBtn'
    } | Select-Object -First 1)
    if ($button.Count -ne 1) { throw 'HarmonyOS system minimize button was not found' }
    $center = Get-LeanTTYBoundsCenter -Bounds ([string]$button[0].attributes.bounds)
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    & $hdc -t $Target shell "uitest uiInput click $($center.x) $($center.y)" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'HarmonyOS system minimize click failed' }
    Wait-AuthLog -Pattern 'Window visibility changed: visible=false'
    $minimizedPid = (@(& $hdc -t $Target shell 'pidof com.leantty.app' 2>&1) -join "`n").Trim()
    if ($minimizedPid -ne $appPid) { throw 'LeanTTY process changed while minimizing' }
}

function Restore-RegressionWindow {
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    & $hdc -t $Target shell 'aa start -a EntryAbility -b com.leantty.app' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to restore minimized LeanTTY window' }
    Wait-AuthLog -Pattern 'Window visibility changed: visible=true'
    $restoredPid = (@(& $hdc -t $Target shell 'pidof com.leantty.app' 2>&1) -join "`n").Trim()
    if ($restoredPid -ne $appPid) { throw 'LeanTTY process changed while restoring' }
    Wait-AuthPaneCount -Count 1 -LayoutName 'layout-after-restore.json' | Out-Null
}

function Restart-RegressionApp {
    & $hdc -t $Target shell 'aa force-stop com.leantty.app' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to stop LeanTTY between SSH authentication scenarios' }
    $start = Start-LeanTTYRegressionApp `
        -Hdc $hdc `
        -Target $Target `
        -CredentialPath $UnlockPasswordPath `
        -RepositoryRoot $repoRoot
    $script:appPid = $start.processId
    $script:deviceUnlockResult = $start.unlock
    Wait-LeanTTYTerminalInputLayout `
        -Hdc $hdc `
        -Target $Target `
        -LocalPath (Join-Path $EvidenceDirectory ('layout-restart-' + $appPid + '.json')) `
        -TimeoutSeconds 20 | Out-Null
    Ensure-SingleAuthPane -LayoutName ('layout-single-pane-' + $appPid + '.json')
}

function Invoke-ExpectedAuthDialog {
    param(
        [Parameter(Mandatory = $true)][string]$ButtonText,
        [Parameter(Mandatory = $true)][string]$LayoutName,
        [Parameter(Mandatory = $true)][string]$Postcondition
    )
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt 10) {
        try {
            Invoke-LeanTTYDialogButton `
                -Hdc $hdc `
                -Target $Target `
                -ButtonText $ButtonText `
                -LayoutPath (Join-Path $EvidenceDirectory $LayoutName)
            Write-AuthLiveStatus `
                -State 'running' `
                -Stage $currentStage `
                -Detail "dialog=$ButtonText; expectedPostcondition=$Postcondition"
            return
        } catch {
            Start-Sleep -Milliseconds 200
        }
    }
    throw "[harness] Expected '$ButtonText' confirmation did not appear"
}

function Invoke-DeleteKeyDialog {
    param([Parameter(Mandatory = $true)][string]$LayoutName)
    Invoke-ExpectedAuthDialog `
        -ButtonText 'Delete key' `
        -LayoutName $LayoutName `
        -Postcondition 'KEY_DELETE result=success and key files absent'
}

function Invoke-ClosePaneDialog {
    param([Parameter(Mandatory = $true)][string]$LayoutName)
    Invoke-ExpectedAuthDialog `
        -ButtonText 'Close pane' `
        -LayoutName $LayoutName `
        -Postcondition 'one terminal pane remains and authentication secret is absent'
}

function Remove-DisposableAuthKey {
    param([Parameter(Mandatory = $true)][string]$LayoutPrefix)
    if (-not (Test-LeanTTYDeviceKeyFilesPresent `
        -Hdc $hdc `
        -Target $Target `
        -KeyName $keyName)) {
        return 'already-absent'
    }
    Clear-LeanTTYDeviceInput -Hdc $hdc -Target $Target
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Submit-FocusedDeviceCommand `
        -Command "key rm $keyName" `
        -LayoutName "$LayoutPrefix-focus.json"
    $script:keyDeletePathUsed = $true
    Invoke-DeleteKeyDialog -LayoutName "$LayoutPrefix-dialog.json"
    Wait-AuthLog -Pattern 'KEY_DELETE result=success'
    if (Test-LeanTTYDeviceKeyFilesPresent `
        -Hdc $hdc `
        -Target $Target `
        -KeyName $keyName) {
        throw 'Disposable SSH authentication key remains after deletion'
    }
    return 'verified-absent'
}

function Read-FixtureCredentials {
    $path = Join-Path $fixtureControl 'server-credentials'
    $readyPath = Join-Path $fixtureControl 'fixture-ready'
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt 90) {
        if ($null -ne $fixtureProcess -and $fixtureProcess.HasExited) {
            throw "SSH fixture exited before readiness (exit=$($fixtureProcess.ExitCode))"
        }
        if ((Test-Path -LiteralPath $path -PathType Leaf) -and
            (Test-Path -LiteralPath $readyPath -PathType Leaf)) {
            $readyText = [IO.File]::ReadAllText($readyPath)
            $readyMatch = [regex]::Match(
                $readyText,
                "(?m)^address=(?:0\.0\.0\.0|127\.0\.0\.1):$FixturePort`$[\r\n]+^pid=(?<pid>\d+)`$"
            )
            if ($readyMatch.Success) {
                $script:fixtureLinuxPid = [int]$readyMatch.Groups['pid'].Value
                $result = @{}
                foreach ($line in [IO.File]::ReadAllLines($path)) {
                    $parts = $line.Split('=', 2)
                    if ($parts.Count -ne 2) { throw 'SSH fixture credential file is malformed' }
                    $result[$parts[0]] = $parts[1]
                }
                foreach ($name in @('password', 'account', 'token', 'second_token')) {
                    if (-not $result.ContainsKey($name) -or [string]::IsNullOrEmpty($result[$name])) {
                        throw "SSH fixture credential is missing: $name"
                    }
                }
                return $result
            }
        }
        Start-Sleep -Milliseconds 200
    }
    throw 'Timed out waiting for the SSH authentication fixture'
}

function Write-AuthEvidence {
    $evidence = [ordered]@{
        schemaVersion = 2
        gate = $(if ($runMode -eq 'acceptance') { 'device-behavior' } else { 'diagnostic' })
        scenario = 'ssh-interactive-authentication'
        runMode = $runMode
        attemptId = $attemptId
        previousAttemptId = $PreviousAttemptId
        retryCount = 0
        result = $scenarioResult
        startedAt = $startedAt.ToString('o')
        completedAt = [DateTimeOffset]::UtcNow.ToString('o')
        durationMs = [long]([DateTimeOffset]::UtcNow - $startedAt).TotalMilliseconds
        candidate = [ordered]@{
            sha256 = $candidate.sha256
            gitCommit = $candidate.gitCommit
            gitTree = $candidate.gitTree
            gitDirty = $candidate.gitDirty
            retained = $(if ($DiagnosticHap) { $false } else { $true })
            provenance = $(if ($DiagnosticHap) {
                'explicit-unretained-diagnostic-hap'
            } else {
                'retained-verified-candidate'
            })
            reusedAcrossHarnessOnlyChanges = ($harnessDifferencePaths.Count -gt 0)
        }
        harness = [ordered]@{
            gitCommit = $harnessCommit
            gitTree = $harnessTree
            gitDirty = $false
            differencePathsFromCandidate = @($harnessDifferencePaths)
        }
        device = [ordered]@{
            model = $deviceModel
            abi = $deviceAbi
            transport = $deviceTransport
        }
        fixture = [ordered]@{
            endpoint = "127.0.0.1:$FixturePort"
            transport = 'hdc-reverse-to-repository-only-russh-server'
            credentials = 'runtime-generated-temporary-values'
            runSeconds = $fixtureRunSeconds
            selectedStageBudgetsSeconds = @($selectedStageNames | ForEach-Object {
                [ordered]@{
                    stage = $_
                    seconds = Get-LeanTTYFixtureStageBudgetSeconds -StageName $_
                }
            })
        }
        environment = [ordered]@{
            awakeLease = $awakeLeaseResult
            deviceUnlock = $deviceUnlockResult
            failure = $awakeLeaseFailure
        }
        input = [ordered]@{
            method = 'raw-physical-key-events'
            secretInjection = 'device-paced-runtime-generated-printable-ascii-serialized-per-character'
            textCommandCharacters = 'complete-value'
            deviceProgramIntervalMilliseconds = 500
            submitTelemetry = 'compile-time-acceptance-marker-with-sequence-and-kind-only'
            businessOutcomeRequired = $true
            fixedDelayUsedAsVerdict = $false
            paneRouting = 'sorted-terminal-input-accessibility-nodes'
            minimizeTrigger = 'HarmonyOS-EnhanceMinimizeBtn'
            pasteTrigger = 'HarmonyOS-uitest-Ctrl-Alt-V-trusted-browser-event'
        }
        preferences = [ordered]@{
            verificationRequested = [bool]$VerifyPreferencesUnchanged
            algorithm = 'SHA-256'
            contentReadOrExported = $false
            digestPersisted = $false
            beforeCaptured = (-not [string]::IsNullOrWhiteSpace($preferencesDigestBefore))
            afterCaptured = (-not [string]::IsNullOrWhiteSpace($preferencesDigestAfter))
            unchanged = $preferencesDigestUnchanged
        }
        coverage = @($checks | Where-Object { $_.name -ne 'fixture-and-device-preflight' } |
            ForEach-Object { $_.name })
        declaredCoverage = @(
            'password-success',
            'transport-main-path-input-large-paste-continuous-output-resize-disconnect-reconnect',
            'five-mode-transparency-continuous-output-render-memory-gpu-hitch-distributions',
            'bell-active-inactive-tab-split-pane-coalescing-and-clear',
            'password-then-keyboard-interactive-mixed-echo',
            'keyboard-interactive-multi-round-wrong-answer-recovery',
            'publickey-unencrypted',
            'publickey-then-password',
            'publickey-then-keyboard-interactive',
            'keyboard-interactive-zero-prompt',
            'unsupported-method-error-and-recovery',
            'ctrl-c-authentication-cancellation-and-recovery',
            'pane-close-during-hidden-prompt-and-recovery',
            'publickey-encrypted-passphrase',
            'parallel-pane-independent-authentication',
            'minimize-restore-hidden-answer-continuity',
            'process-stop-during-hidden-prompt-cleanup'
        )
        selectedStages = @($selectedStageNames)
        checks = @($checks)
        resourceManifest = [ordered]@{
            disposableKey = $keyName
            reversePort = $FixturePort
            fixtureDirectory = 'run-scoped-system-temporary-directory'
            knownHostEndpoint = "[127.0.0.1]:$FixturePort"
        }
        cleanup = [ordered]@{
            result = $cleanupResult
            failure = $cleanupFailure
            productDeletePathUsed = $keyDeletePathUsed
            independentKeyAbsenceAudit = $keyAbsenceAudited
            reverseMappingAbsenceAudit = (-not $mappingActive)
            fixtureProcessAbsenceAudit = $fixtureProcessAbsent
        }
        performanceMatrix = $performanceEvidence
        bellAttention = $bellEvidence
        failureDomain = $failureDomain
        failure = $failure
    }
    [IO.File]::WriteAllText(
        $evidencePath,
        (ConvertTo-Json -InputObject $evidence -Depth 7),
        [Text.UTF8Encoding]::new($false)
    )
}

function Get-LeanTTYPreferencesDigest {
    $preferencesPath = '/data/app/el2/100/base/com.leantty.app/haps/entry/preferences/leantty_settings'
    $output = @(
        & $hdc -t $Target shell -b com.leantty.app "sha256sum $preferencesPath" 2>&1
    )
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to compute the LeanTTY Preferences digest in the application sandbox'
    }
    $match = [regex]::Match(
        ($output -join "`n").Trim(),
        '^(?<digest>[0-9a-fA-F]{64})\s+/data/app/el2/100/base/com\.leantty\.app/haps/entry/preferences/leantty_settings$'
    )
    if (-not $match.Success) {
        throw 'Unexpected LeanTTY Preferences digest response'
    }
    return $match.Groups['digest'].Value.ToLowerInvariant()
}

try {
    Write-Host '[device-auth] START fixture-and-device-preflight'
    $currentStage = 'fixture-and-device-preflight'
    Write-AuthLiveStatus -State 'running' -Stage $currentStage
    $preflight = [Diagnostics.Stopwatch]::StartNew()
    $pwshPath = (Get-Process -Id $PID).Path
    $fixtureArguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
        (Join-Path $PSScriptRoot 'start-ssh-auth-fixture.ps1'),
        '-ListenAddress', "0.0.0.0:$FixturePort",
        '-RunSeconds', $fixtureRunSeconds.ToString(),
        '-ControlDirectory', $fixtureControl
    )
    if (-not [string]::IsNullOrWhiteSpace($Distribution)) {
        $fixtureArguments += @('-Distribution', $Distribution)
    }
    $fixtureProcess = Start-Process `
        -FilePath $pwshPath `
        -ArgumentList $fixtureArguments `
        -RedirectStandardOutput $fixtureStdout `
        -RedirectStandardError $fixtureStderr `
        -WindowStyle Hidden `
        -PassThru
    $credentials = Read-FixtureCredentials
    $secrets = @(
        $credentials.password,
        $credentials.account,
        $credentials.token,
        $credentials.second_token,
        $keyPassphrase
    )

    $existingMappings = @(& $hdc -t $Target fport ls 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect existing HDC port mappings' }
    if ($existingMappings -match "(?m)tcp:$FixturePort\s+tcp:$FixturePort\s+\[Reverse\]") {
        throw "HDC reverse mapping already exists for fixture port $FixturePort"
    }
    $mappingOutput = @(
        & $hdc -t $Target rport "tcp:$FixturePort" "tcp:$FixturePort" 2>&1
    ) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $mappingOutput -notmatch 'Forwardport result:OK') {
        throw "Unable to create HDC reverse mapping: $mappingOutput"
    }
    $mappingActive = $true
    Start-LeanTTYDeviceAwakeLease -Hdc $hdc -Target $Target
    $awakeLeaseActive = $true
    $awakeLeaseResult = 'acquired'
    & (Join-Path $PSScriptRoot 'dev-pc.ps1') `
        -Target $Target `
        -HapPath $candidate.hapPath `
        -SkipBuild `
        -NoLaunch
    if ($LASTEXITCODE -ne 0) { throw 'Exact candidate deployment failed' }
    Restart-RegressionApp
    $deviceModel = (Invoke-HdcShell $hdc $Target 'param get const.product.model').Trim()
    $deviceAbi = (Invoke-HdcShell $hdc $Target 'param get const.product.cpu.abilist').Trim()
    $deviceTransport = Get-HdcTargetTransport -Hdc $hdc -Target $Target
    if ($deviceAbi -notmatch 'arm64-v8a') { throw "Device is not ARM64: $deviceAbi" }
    Clear-LeanTTYDeviceInput -Hdc $hdc -Target $Target
    Submit-FocusedDeviceCommand `
        -Command "ssh-keygen -R [127.0.0.1]:$FixturePort" `
        -LayoutName 'layout-preflight-command-focus.json'
    if (-not (Test-AuthStageSelected -Name 'password-success')) {
        Start-AuthCommand -User 'password'
        Wait-AuthLog -Pattern 'rust event: HOST_KEY_PROMPT:'
        Invoke-LeanTTYDeviceText -Hdc $hdc -Target $Target -Text 'yes'
        Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $Target -KeyCode 2054
        Wait-AuthLog -Pattern 'native auth event kind=password'
        Invoke-LeanTTYDeviceCtrlC -Hdc $hdc -Target $Target
        Wait-LeanTTYTerminalInputLayout `
            -Hdc $hdc `
            -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory 'layout-preflight-trust-cancelled.json') `
            -TimeoutSeconds 10 | Out-Null
    }
    Add-AuthCheck -Name 'fixture-and-device-preflight' -DurationMs $preflight.ElapsedMilliseconds
    if ($VerifyPreferencesUnchanged) {
        $preferencesDigestBefore = Get-LeanTTYPreferencesDigest
    }

    if (Test-AuthStageSelected -Name 'password-success') {
    Start-AuthStage -Name 'password-success'
    Start-AuthCommand -User 'password'
    Wait-AuthLog -Pattern 'rust event: HOST_KEY_PROMPT:'
    Invoke-LeanTTYDeviceText -Hdc $hdc -Target $Target -Text 'yes'
    Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $Target -KeyCode 2054
    Wait-AuthLog -Pattern 'native auth event kind=password'
    Submit-AuthValue -Value $credentials.password -LayoutName 'layout-password-value.json'
    Wait-AuthLog -Pattern 'SSH session connected'
    Close-FixtureShell
    Complete-AuthStage -Name 'password-success'
    }

    if (Test-AuthStageSelected -Name 'terminal-key-input') {
    Start-AuthStage -Name 'terminal-key-input'
    Start-AuthCommand -User 'navigation'
    Wait-AuthLog -Pattern 'native auth event kind=password'
    Submit-AuthValue -Value $credentials.password -LayoutName 'layout-terminal-key-input-password.json'
    Wait-AuthLog -Pattern 'SSH session connected'
    Wait-AuthLog -Pattern 'OSC 52 clipboard write success=true,length=17'

    Invoke-LeanTTYDevicePhysicalKey -Hdc $hdc -Target $Target -KeyCode 2014
    Start-Sleep -Milliseconds 300
    Invoke-LeanTTYDevicePhysicalKey -Hdc $hdc -Target $Target -KeyCode 2015
    Start-Sleep -Milliseconds 300
    & $hdc -t $Target shell 'uinput -K -d 2072 -d 2032 -u 2032 -u 2072' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '[environment] Unable to inject Ctrl+P' }
    Start-Sleep -Milliseconds 300
    & $hdc -t $Target shell 'uinput -K -d 2072 -d 2019 -u 2019 -u 2072' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '[environment] Unable to inject Ctrl+C' }
    Start-Sleep -Milliseconds 300
    Invoke-LeanTTYDevicePhysicalKey -Hdc $hdc -Target $Target -KeyCode 2049
    Start-Sleep -Milliseconds 300
    & $hdc -t $Target shell 'uinput -K -d 2072 -d 2038 -u 2038 -u 2072' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '[environment] Unable to inject Ctrl+V' }
    Start-Sleep -Milliseconds 1000

    $terminalKeyLog = Read-FixtureLogText
    $terminalKeyLines = @($terminalKeyLog -split "`n" | Where-Object {
        $_ -match '^navigation input hex='
    })
    [IO.File]::WriteAllLines(
        (Join-Path $EvidenceDirectory 'terminal-key-input.txt'),
        $terminalKeyLines,
        [Text.UTF8Encoding]::new($false)
    )
    $expectedTerminalKeys = [ordered]@{
        left = 'navigation input hex=1b 5b 44'
        right = 'navigation input hex=1b 5b 43'
        ctrlP = 'navigation input hex=10'
        ctrlC = 'navigation input hex=03'
        tab = 'navigation input hex=09'
        ctrlVPaste = 'navigation input hex=6c 65 61 6e 74 74 79 2d 6b 65 79 2d 70 61 73 74 65'
    }
    $missingTerminalKeys = @($expectedTerminalKeys.GetEnumerator() | Where-Object {
        $terminalKeyLog -notmatch [regex]::Escape([string]$_.Value)
    } | ForEach-Object { [string]$_.Key })

    Restart-RegressionApp
    Wait-LeanTTYTerminalInputLayout `
        -Hdc $hdc `
        -Target $Target `
        -LocalPath (Join-Path $EvidenceDirectory 'layout-terminal-key-input-restarted.json') `
        -TimeoutSeconds 30 | Out-Null
    if ($missingTerminalKeys.Count -gt 0) {
        throw ('[product] Terminal key input was not delivered: ' + ($missingTerminalKeys -join ','))
    }
    Complete-AuthStage -Name 'terminal-key-input'
    }

    if (Test-AuthStageSelected -Name 'transport-main-path') {
    Start-AuthStage -Name 'transport-main-path'
    Start-AuthCommand -User 'password'
    Wait-AuthLog -Pattern 'native auth event kind=password'
    Submit-AuthValue -Value $credentials.password -LayoutName 'layout-transport-password.json'
    Wait-AuthLog -Pattern 'SSH session connected'

    Submit-ConnectedInputUntilFixtureEvent `
        -Text 'ltty-input-check russhmain' `
        -Pattern 'input case=russhmain result=matched'

    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Submit-ConnectedInputUntilAuthEvent `
        -Text 'ltty-paste-prepare russhmain 1048576' `
        -Pattern 'OSC 52 clipboard write success=true,length=1048576' `
        -TimeoutSeconds 30
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Invoke-LeanTTYPasteShortcut
    Wait-AuthLog -Pattern 'Clipboard paste ok,1048576' -TimeoutSeconds 30
    Wait-AuthLog -Pattern 'D: 1048576 chars' -TimeoutSeconds 30
    Wait-FixtureLog `
        -Pattern 'paste case=russhmain bytes=1048576 result=matched' `
        -TimeoutSeconds 30 | Out-Null

    Invoke-AuthPerfSample -CaseId 'russhmain' | Out-Null

    $resizeCount = Get-FixtureLogMatchCount -Pattern 'resize cols=\d+ rows=\d+'
    Split-AuthPane
    Wait-FixtureLogMatchCount `
        -Pattern 'resize cols=\d+ rows=\d+' `
        -GreaterThan $resizeCount `
        -TimeoutSeconds 30 | Out-Null
    Focus-AuthPane -Side 'left' -LayoutName 'layout-transport-left-connected.json'
    Submit-ConnectedInputUntilFixtureEvent `
        -Text 'ltty-input-check afterperf' `
        -Pattern 'input case=afterperf result=matched'

    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Invoke-ActivePaneCloseButton -LayoutName 'layout-transport-close-connected.json'
    Invoke-ClosePaneDialog -LayoutName 'layout-transport-close-connected-dialog.json'
    Wait-AuthLog -Pattern 'SSH closed, exitCode=-1'
    Wait-AuthPaneCount -Count 1 -LayoutName 'layout-transport-single-pane.json' | Out-Null

    Start-AuthCommand -User 'password'
    Wait-AuthLog -Pattern 'native auth event kind=password'
    Submit-AuthValue -Value $credentials.password -LayoutName 'layout-transport-reconnect-password.json'
    Wait-AuthLog -Pattern 'SSH session connected'
    Submit-ConnectedInputUntilFixtureEvent `
        -Text 'ltty-input-check reconnect' `
        -Pattern 'input case=reconnect result=matched'
    Close-FixtureShell
    Complete-AuthStage -Name 'transport-main-path'
    }

    if (Test-AuthStageSelected -Name 'performance-matrix') {
    Start-AuthStage -Name 'performance-matrix'
    $performanceEvidence.selected = $true
    Start-AuthCommand -User 'password'
    Wait-AuthLog -Pattern 'native auth event kind=password'
    Submit-AuthValue -Value $credentials.password -LayoutName 'layout-performance-password.json'
    Wait-AuthLog -Pattern 'SSH session connected'

    $gpuText = @(& $hdc -t $Target shell "hidumper -s 10 -a 'gles'" 2>&1) -join "`n"
    $gpuVendor = [regex]::Match($gpuText, '(?m)^GL_VENDOR:\s*(?<value>.+)$')
    $gpuRenderer = [regex]::Match($gpuText, '(?m)^GL_RENDERER:\s*(?<value>.+)$')
    $gpuVersion = [regex]::Match($gpuText, '(?m)^GL_VERSION:\s*(?<value>.+)$')
    $performanceEvidence.gpu = [ordered]@{
        vendor = $(if ($gpuVendor.Success) { $gpuVendor.Groups['value'].Value.Trim() } else { '' })
        renderer = $(if ($gpuRenderer.Success) { $gpuRenderer.Groups['value'].Value.Trim() } else { '' })
        version = $(if ($gpuVersion.Success) { $gpuVersion.Groups['value'].Value.Trim() } else { '' })
    }

    $modeNames = @('Off', 'Low', 'Medium', 'High', 'Extreme')
    for ($modeIndex = 0; $modeIndex -lt $modeNames.Count; $modeIndex++) {
        $modeName = $modeNames[$modeIndex]
        $modeSlug = $modeName.ToLowerInvariant()
        Set-AuthTransparencyMode -Mode $modeName -LayoutPrefix "performance-$modeSlug"
        $hitchBefore = Get-AuthHitchSample
        $renderSamples = [Collections.Generic.List[object]]::new()
        $memorySamples = [Collections.Generic.List[object]]::new()
        for ($sampleIndex = 1; $sampleIndex -le 3; $sampleIndex++) {
            $caseId = $modeSlug + '0' + $sampleIndex.ToString()
            $renderSamples.Add((Invoke-AuthPerfSample -CaseId $caseId))
            $memorySamples.Add([pscustomobject][ordered]@{
                sample = $sampleIndex
                processes = @(Get-AuthProcessMemorySample)
            })
        }
        $screenshotName = "performance-$modeSlug.png"
        Save-LeanTTYDeviceScreenshot -Hdc $hdc -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory $screenshotName)
        $performanceEvidence.modes += [pscustomobject][ordered]@{
            mode = $modeName
            renderSamples = @($renderSamples)
            memorySamples = @($memorySamples)
            hitchBefore = $hitchBefore
            hitchAfter = Get-AuthHitchSample
            screenshot = $screenshotName
        }
    }
    Set-AuthTransparencyMode -Mode 'Medium' -LayoutPrefix 'performance-restore-medium'
    $performanceEvidence.restoredMode = 'Medium'
    Close-FixtureShell
    Complete-AuthStage -Name 'performance-matrix'
    }

    if (Test-AuthStageSelected -Name 'bell-attention') {
    Start-AuthStage -Name 'bell-attention'
    $bellEvidence.selected = $true
    Start-AuthCommand -User 'password'
    Wait-AuthLog -Pattern 'native auth event kind=password'
    Submit-AuthValue -Value $credentials.password -LayoutName 'layout-bell-password.json'
    Wait-AuthLog -Pattern 'SSH session connected'

    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Submit-ConnectedInputUntilFixtureEvent `
        -Text 'ltty-bell active01 500' `
        -Pattern 'bell case=active01 delay_ms=500 state=scheduled'
    Start-Sleep -Milliseconds 1600
    $activeLogs = Get-LeanTTYAppLogs -Hdc $hdc -Target $Target -ProcessId $appPid
    Save-SafeDiagnosticText -Text $activeLogs -FileName 'bell-active-app-logs.txt'
    if ($activeLogs -match 'Pane attention set:') {
        throw '[product] Focused active-pane BEL incorrectly persisted attention'
    }
    Save-LeanTTYDeviceScreenshot -Hdc $hdc -Target $Target `
        -LocalPath (Join-Path $EvidenceDirectory 'bell-active-after-pulse.png')
    $bellEvidence.activePaneStayedTransient = $true
    $bellEvidence.screenshots += 'bell-active-after-pulse.png'

    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Submit-ConnectedInputUntilFixtureEvent `
        -Text 'ltty-bell inactive01 5000' `
        -Pattern 'bell case=inactive01 delay_ms=5000 state=scheduled'
    Invoke-AuthWorkspaceShortcut -Action 'new-tab'
    Wait-AuthTabCount -Count 2 -LayoutName 'layout-bell-inactive-new-tab.json' | Out-Null
    Wait-FixtureLog -Pattern 'bell case=inactive01 state=sent' -TimeoutSeconds 10 | Out-Null
    Wait-AuthLog -Pattern 'Pane attention set:' -TimeoutSeconds 15
    Save-LeanTTYDeviceScreenshot -Hdc $hdc -Target $Target `
        -LocalPath (Join-Path $EvidenceDirectory 'bell-inactive-tab-marker.png')
    $bellEvidence.inactiveTabAttentionPersisted = $true
    $bellEvidence.screenshots += 'bell-inactive-tab-marker.png'
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Invoke-AuthWorkspaceShortcut -Action 'next-tab'
    Wait-AuthLog -Pattern 'Pane attention cleared:' -TimeoutSeconds 10
    $bellEvidence.inactiveTabAttentionClearedOnEntry = $true
    Invoke-AuthWorkspaceShortcut -Action 'next-tab'
    Invoke-AuthWorkspaceShortcut -Action 'close-active'
    Wait-AuthTabCount -Count 1 -LayoutName 'layout-bell-inactive-tab-cleaned.json' | Out-Null

    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Submit-ConnectedInputUntilFixtureEvent `
        -Text 'ltty-bell split01 5000' `
        -Pattern 'bell case=split01 delay_ms=5000 state=scheduled'
    Split-AuthPane
    Wait-FixtureLog -Pattern 'bell case=split01 state=sent' -TimeoutSeconds 10 | Out-Null
    Wait-AuthLog -Pattern 'Pane attention set:' -TimeoutSeconds 15
    Save-LeanTTYDeviceScreenshot -Hdc $hdc -Target $Target `
        -LocalPath (Join-Path $EvidenceDirectory 'bell-split-pane-marker.png')
    $bellEvidence.splitPaneSourcePersisted = $true
    $bellEvidence.screenshots += 'bell-split-pane-marker.png'
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Invoke-AuthWorkspaceShortcut -Action 'focus-left'
    Wait-AuthLog -Pattern 'Pane attention cleared:' -TimeoutSeconds 10
    $bellEvidence.splitPaneSourceClearedOnFocus = $true

    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Submit-ConnectedInputUntilFixtureEvent `
        -Text 'ltty-bell flood01 5000' `
        -Pattern 'bell case=flood01 delay_ms=5000 state=scheduled'
    Submit-ConnectedInputUntilFixtureEvent `
        -Text 'ltty-bell flood02 5000' `
        -Pattern 'bell case=flood02 delay_ms=5000 state=scheduled'
    Invoke-AuthWorkspaceShortcut -Action 'focus-right'
    Wait-FixtureLog -Pattern 'bell case=flood01 state=sent' -TimeoutSeconds 10 | Out-Null
    Wait-FixtureLog -Pattern 'bell case=flood02 state=sent' -TimeoutSeconds 10 | Out-Null
    Wait-AuthLog -Pattern 'Pane attention set:' -TimeoutSeconds 15
    Start-Sleep -Milliseconds 1200
    $floodLogs = Get-LeanTTYAppLogs -Hdc $hdc -Target $Target -ProcessId $appPid
    Save-SafeDiagnosticText -Text $floodLogs -FileName 'bell-repeated-app-logs.txt'
    if ([regex]::Matches($floodLogs, 'Pane attention set:').Count -ne 1) {
        throw '[product] Repeated BEL did not coalesce to one pending attention transition'
    }
    $bellEvidence.repeatedBellCallbacksCoalesced = $true
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Invoke-AuthWorkspaceShortcut -Action 'focus-left'
    Wait-AuthLog -Pattern 'Pane attention cleared:' -TimeoutSeconds 10
    Invoke-AuthWorkspaceShortcut -Action 'focus-right'
    Invoke-ActivePaneCloseButton -LayoutName 'layout-bell-close-idle-pane.json'
    Wait-AuthPaneCount -Count 1 -LayoutName 'layout-bell-single-pane.json' | Out-Null
    Close-FixtureShell
    Complete-AuthStage -Name 'bell-attention'
    }

    if (Test-AuthStageSelected -Name 'password-kbdint-mixed-echo') {
    Start-AuthStage -Name 'password-kbdint-mixed-echo'
    Start-AuthCommand -User 'password-kbdint'
    Wait-AuthLog -Pattern 'native auth event kind=password'
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Submit-AuthValue -Value $credentials.password -LayoutName 'layout-password-kbdint-password.json'
    Wait-AuthLog -Pattern 'native auth event kind=challenge'
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Submit-AuthValue -Value $credentials.account -LayoutName 'layout-password-kbdint-account.json'
    Submit-AuthValue -Value $credentials.token -LayoutName 'layout-password-kbdint-token.json'
    Wait-AuthLog -Pattern 'SSH session connected'
    Close-FixtureShell
    Complete-AuthStage -Name 'password-kbdint-mixed-echo'
    }

    if (Test-AuthStageSelected -Name 'multiround-wrong-answer-recovery') {
    Start-AuthStage -Name 'multiround-wrong-answer-recovery'
    Start-AuthCommand -User 'kbdint-multiround'
    Wait-AuthLog -Pattern 'native auth event kind=challenge'
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Submit-AuthValue -Value $credentials.account -LayoutName 'layout-multiround-account-first.json'
    Wait-AuthLog -Pattern 'native auth event kind=challenge'
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    $wrongAnswer = New-LeanTTYRegressionSecret
    $secrets += $wrongAnswer
    Submit-AuthValue -Value $wrongAnswer -LayoutName 'layout-multiround-wrong.json'
    Wait-AuthLog -Pattern 'rust event: AUTH:target:authentication was rejected'
    Assert-NoSecretExposure -LayoutName 'layout-multiround-rejected.json'
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Start-AuthCommand -User 'kbdint-multiround'
    Wait-AuthLog -Pattern 'native auth event kind=challenge'
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Submit-AuthValue -Value $credentials.account -LayoutName 'layout-multiround-account-retry.json'
    Wait-AuthLog -Pattern 'native auth event kind=challenge'
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Submit-AuthValue -Value $credentials.second_token -LayoutName 'layout-multiround-token.json'
    Wait-AuthLog -Pattern 'SSH session connected'
    Close-FixtureShell
    Complete-AuthStage -Name 'multiround-wrong-answer-recovery'
    }

    if (Test-AuthStageSelected -Name 'generated-disposable-auth-key') {
    Start-AuthStage -Name 'generated-disposable-auth-key'
    $keyCleanupRequired = $true
    Submit-FocusedDeviceCommand `
        -Command "ssh-keygen -t ed25519 -f $keyName -C regression" `
        -LayoutName 'layout-key-generate-command-focus.json'
    Wait-AuthLog -Pattern 'Key generated:'
    Complete-AuthStage -Name 'generated-disposable-auth-key'
    }

    if (Test-AuthStageSelected -Name 'publickey-unencrypted') {
    Start-AuthStage -Name 'publickey-unencrypted'
    Start-AuthCommand -User 'publickey' -Identity $keyName
    Wait-AuthLog -Pattern 'SSH session connected'
    Close-FixtureShell
    Complete-AuthStage -Name 'publickey-unencrypted'
    }

    if (Test-AuthStageSelected -Name 'publickey-then-password') {
    Start-AuthStage -Name 'publickey-then-password'
    Start-AuthCommand -User 'publickey-password' -Identity $keyName
    Wait-AuthLog -Pattern 'native auth event kind=password'
    Submit-AuthValue -Value $credentials.password -LayoutName 'layout-publickey-password.json'
    Wait-AuthLog -Pattern 'SSH session connected'
    Close-FixtureShell
    Complete-AuthStage -Name 'publickey-then-password'
    }

    if (Test-AuthStageSelected -Name 'publickey-then-keyboard-interactive') {
    Start-AuthStage -Name 'publickey-then-keyboard-interactive'
    Start-AuthCommand -User 'publickey-kbdint' -Identity $keyName
    Wait-AuthLog -Pattern 'native auth event kind=challenge'
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Submit-AuthValue -Value $credentials.account -LayoutName 'layout-publickey-kbdint-account.json'
    Submit-AuthValue -Value $credentials.token -LayoutName 'layout-publickey-kbdint-token.json'
    Wait-AuthLog -Pattern 'SSH session connected'
    Close-FixtureShell
    Complete-AuthStage -Name 'publickey-then-keyboard-interactive'
    }

    if (Test-AuthStageSelected -Name 'keyboard-interactive-zero-prompt') {
    Start-AuthStage -Name 'keyboard-interactive-zero-prompt'
    Start-AuthCommand -User 'kbdint-zero'
    Wait-AuthLog -Pattern 'native auth event kind=challenge'
    Wait-AuthLog -Pattern 'SSH session connected'
    Close-FixtureShell
    Complete-AuthStage -Name 'keyboard-interactive-zero-prompt'
    }

    if (Test-AuthStageSelected -Name 'unsupported-method-error-and-recovery') {
    Start-AuthStage -Name 'unsupported-method-error-and-recovery'
    Start-AuthCommand -User 'unsupported'
    Wait-AuthLog -Pattern 'rust event: AUTH:target:no supported authentication method is available'
    Assert-NoSecretExposure -LayoutName 'layout-unsupported-method.json'
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Start-AuthCommand -User 'password'
    Wait-AuthLog -Pattern 'native auth event kind=password'
    Submit-AuthValue -Value $credentials.password -LayoutName 'layout-unsupported-recovery-password.json'
    Wait-AuthLog -Pattern 'SSH session connected'
    Close-FixtureShell
    Complete-AuthStage -Name 'unsupported-method-error-and-recovery'
    }

    if (Test-AuthStageSelected -Name 'ctrl-c-authentication-cancellation-and-recovery') {
    Start-AuthStage -Name 'ctrl-c-authentication-cancellation-and-recovery'
    Start-AuthCommand -User 'kbdint-multiround'
    Wait-AuthLog -Pattern 'native auth event kind=challenge'
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Submit-AuthValue -Value $credentials.account -LayoutName 'layout-cancel-auth-account.json'
    Wait-AuthLog -Pattern 'native auth event kind=challenge'
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Invoke-SerializedAuthText -Value $credentials.second_token
    Assert-NoSecretExposure -LayoutName 'layout-cancel-auth-hidden-token.json'
    Invoke-LeanTTYDeviceCtrlC -Hdc $hdc -Target $Target
    Assert-NoSecretExposure -LayoutName 'layout-cancel-auth-cleared.json'
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Start-AuthCommand -User 'password'
    Wait-AuthLog -Pattern 'native auth event kind=password'
    Submit-AuthValue -Value $credentials.password -LayoutName 'layout-cancel-auth-recovery-password.json'
    Wait-AuthLog -Pattern 'SSH session connected'
    Close-FixtureShell
    Complete-AuthStage -Name 'ctrl-c-authentication-cancellation-and-recovery'
    }

    if (Test-AuthStageSelected -Name 'pane-close-during-hidden-prompt-and-recovery') {
    Start-AuthStage -Name 'pane-close-during-hidden-prompt-and-recovery'
    Split-AuthPane
    Focus-AuthPane -Side 'right' -LayoutName 'layout-close-auth-right-prompt.json'
    Start-AuthCommand -User 'kbdint-multiround'
    Wait-AuthLog -Pattern 'native auth event kind=challenge'
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Submit-AuthValue -Value $credentials.account -LayoutName 'layout-close-auth-account.json'
    Wait-AuthLog -Pattern 'native auth event kind=challenge'
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Invoke-SerializedAuthText -Value $credentials.second_token
    Assert-NoSecretExposure -LayoutName 'layout-close-auth-hidden-token.json'
    Invoke-ActivePaneCloseButton -LayoutName 'layout-close-auth-button.json'
    Invoke-ClosePaneDialog -LayoutName 'layout-close-auth-dialog.json'
    Wait-AuthPaneCount -Count 1 -LayoutName 'layout-close-auth-single-pane.json' | Out-Null
    Assert-NoSecretExposure -LayoutName 'layout-close-auth-cleared.json'
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Start-AuthCommand -User 'password'
    Wait-AuthLog -Pattern 'native auth event kind=password'
    Submit-AuthValue -Value $credentials.password -LayoutName 'layout-close-auth-recovery-password.json'
    Wait-AuthLog -Pattern 'SSH session connected'
    Close-FixtureShell
    Complete-AuthStage -Name 'pane-close-during-hidden-prompt-and-recovery'
    }

    if (Test-AuthStageSelected -Name 'encrypted-disposable-auth-key') {
    Start-AuthStage -Name 'encrypted-disposable-auth-key'
    Submit-FocusedDeviceCommand `
        -Command "ssh-keygen -p -f $keyName" `
        -LayoutName 'layout-key-passphrase-command-focus.json'
    Wait-AuthLog -Pattern 'KEY_PASSPHRASE_CHANGE stage=old'
    Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $Target -KeyCode 2054
    Wait-AuthLog -Pattern 'KEY_PASSPHRASE_CHANGE stage=new'
    Submit-AuthValue -Value $keyPassphrase -LayoutName 'layout-key-passphrase-new.json'
    Wait-AuthLog -Pattern 'KEY_PASSPHRASE_CHANGE stage=confirm'
    Submit-AuthValue -Value $keyPassphrase -LayoutName 'layout-key-passphrase-confirm.json'
    Wait-AuthLog -Pattern 'KEY_PASSPHRASE_CHANGE result=success'
    Complete-AuthStage -Name 'encrypted-disposable-auth-key'
    }

    if (Test-AuthStageSelected -Name 'publickey-encrypted-passphrase') {
    Start-AuthStage -Name 'publickey-encrypted-passphrase'
    Start-AuthCommand -User 'publickey' -Identity $keyName
    Wait-AuthLog -Pattern 'native auth event kind=private_key_passphrase'
    Submit-AuthValue -Value $keyPassphrase -LayoutName 'layout-key-passphrase-auth.json'
    Wait-AuthLog -Pattern 'SSH session connected'
    Close-FixtureShell
    Complete-AuthStage -Name 'publickey-encrypted-passphrase'
    }

    if (Test-AuthStageSelected -Name 'parallel-pane-authentication') {
    Start-AuthStage -Name 'parallel-pane-authentication'
    Split-AuthPane
    Focus-AuthPane -Side 'right' -LayoutName 'layout-parallel-right-prompt.json'
    Start-AuthCommand -User 'kbdint-multiround'
    Wait-AuthLog -Pattern 'native auth event kind=challenge'
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Focus-AuthPane -Side 'left' -LayoutName 'layout-parallel-left-prompt.json'
    Start-AuthCommand -User 'password-kbdint'
    Wait-AuthLog -Pattern 'native auth event kind=password'
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Submit-AuthValue -Value $credentials.password -LayoutName 'layout-parallel-left-password.json'
    Wait-AuthLog -Pattern 'native auth event kind=challenge'
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Submit-AuthValue -Value $credentials.account -LayoutName 'layout-parallel-left-account.json'
    Submit-AuthValue -Value $credentials.token -LayoutName 'layout-parallel-left-token.json'
    Wait-AuthLog -Pattern 'SSH session connected'
    Close-FixtureShell
    Focus-AuthPane -Side 'right' -LayoutName 'layout-parallel-right-resume.json'
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Submit-AuthValue -Value $credentials.account -LayoutName 'layout-parallel-right-account.json'
    Wait-AuthLog -Pattern 'native auth event kind=challenge'
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Submit-AuthValue -Value $credentials.second_token -LayoutName 'layout-parallel-right-token.json'
    Wait-AuthLog -Pattern 'SSH session connected'
    Close-FixtureShell
    Complete-AuthStage -Name 'parallel-pane-authentication'
    Ensure-SingleAuthPane -LayoutName 'layout-parallel-cleanup.json'
    }

    if (Test-AuthStageSelected -Name 'minimize-restore-hidden-prompt') {
    Start-AuthStage -Name 'minimize-restore-hidden-prompt'
    Start-AuthCommand -User 'kbdint-multiround'
    Wait-AuthLog -Pattern 'native auth event kind=challenge'
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Submit-AuthValue -Value $credentials.account -LayoutName 'layout-minimize-account.json'
    Wait-AuthLog -Pattern 'native auth event kind=challenge'
    Invoke-SerializedAuthText -Value $credentials.second_token
    Assert-NoSecretExposure -LayoutName 'layout-minimize-hidden-token.json'
    Minimize-RegressionWindow
    Restore-RegressionWindow
    Assert-NoSecretExposure -LayoutName 'layout-minimize-restored-token.json'
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $Target -KeyCode 2054
    Wait-AuthLog -Pattern 'SSH session connected'
    Close-FixtureShell
    Complete-AuthStage -Name 'minimize-restore-hidden-prompt'
    }

    if (Test-AuthStageSelected -Name 'process-stop-during-hidden-prompt-cleanup') {
    Start-AuthStage -Name 'process-stop-during-hidden-prompt-cleanup'
    Start-AuthCommand -User 'kbdint-multiround'
    Wait-AuthLog -Pattern 'native auth event kind=challenge'
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Submit-AuthValue -Value $credentials.account -LayoutName 'layout-cancel-account.json'
    Wait-AuthLog -Pattern 'native auth event kind=challenge'
    Invoke-SerializedAuthText -Value $credentials.second_token
    Assert-NoSecretExposure -LayoutName 'layout-cancel-hidden-token.json'
    Restart-RegressionApp
    Assert-NoSecretExposure -LayoutName 'layout-cancel-restarted.json'
    Complete-AuthStage -Name 'process-stop-during-hidden-prompt-cleanup'
    }

    if (Test-AuthStageSelected -Name 'deleted-disposable-auth-key') {
    Start-AuthStage -Name 'deleted-disposable-auth-key'
    Remove-DisposableAuthKey -LayoutPrefix 'layout-key-cleanup' | Out-Null
    $keyCleanupRequired = $false
    Complete-AuthStage -Name 'deleted-disposable-auth-key'
    }

    Submit-FocusedDeviceCommand `
        -Command "ssh-keygen -R [127.0.0.1]:$FixturePort" `
        -LayoutName 'layout-final-known-hosts-command-focus.json'
    if ($VerifyPreferencesUnchanged) {
        $preferencesCheck = [Diagnostics.Stopwatch]::StartNew()
        $preferencesDigestAfter = Get-LeanTTYPreferencesDigest
        $preferencesDigestUnchanged = ($preferencesDigestBefore -ceq $preferencesDigestAfter)
        if (-not $preferencesDigestUnchanged) {
            throw 'LeanTTY Preferences changed during the selected SSH authentication stages'
        }
        Add-AuthCheck `
            -Name 'preferences-unchanged-during-authentication' `
            -DurationMs $preferencesCheck.ElapsedMilliseconds
    }
    $scenarioResult = 'passed'
} catch {
    $caughtError = $_
    $failure = $_.Exception.Message
    if ($null -ne $fixtureProcess -and $fixtureProcess.HasExited) {
        $failureDomain = 'infrastructure'
        $failure = "[infrastructure] SSH fixture exited before stage completed: $failure"
    } else {
        $failureDomain = Resolve-AuthFailureDomain -Message $failure
    }
    Write-AuthLiveStatus -State 'failed' -Stage $currentStage -Detail $failureDomain
    try {
        $failureLogs = Get-LeanTTYAppLogs -Hdc $hdc -Target $Target -ProcessId $appPid
        Save-SafeDiagnosticText -Text $failureLogs -FileName 'failure-hilog.txt'
    } catch {}
    try {
        Save-LeanTTYDeviceScreenshot `
            -Hdc $hdc `
            -Target $Target `
            -LocalPath (Join-Path $EvidenceDirectory 'failure.png')
    } catch {}
} finally {
    $cleanupFailures = [Collections.Generic.List[string]]::new()
    if ($keyCleanupRequired -and -not [string]::IsNullOrWhiteSpace($appPid)) {
        try {
            Restart-RegressionApp
            Remove-DisposableAuthKey -LayoutPrefix 'layout-key-finally-cleanup' | Out-Null
            $keyCleanupRequired = $false
        } catch {
            $cleanupFailures.Add('Disposable SSH authentication key cleanup failed')
        }
    }
    if ($mappingActive) {
        $removeOutput = @(
            & $hdc -t $Target fport rm "tcp:$FixturePort" "tcp:$FixturePort" 2>&1
        ) -join "`n"
        if ($LASTEXITCODE -ne 0 -or $removeOutput -notmatch 'Remove forward ruler success') {
            $cleanupFailures.Add('HDC reverse mapping cleanup failed')
        } else {
            $remainingMappings = @(& $hdc -t $Target fport ls 2>&1) -join "`n"
            if ($LASTEXITCODE -ne 0 -or
                $remainingMappings -match "(?m)tcp:$FixturePort\s+tcp:$FixturePort\s+\[Reverse\]") {
                $cleanupFailures.Add('HDC reverse mapping remained after cleanup')
            } else {
                $mappingActive = $false
            }
        }
    }
    if ($fixtureLinuxPid -gt 0) {
        try {
            $wslPrefix = Get-LeanTTYWslPrefix -Distribution $Distribution
            & wsl.exe @wslPrefix --exec kill -TERM $fixtureLinuxPid 2>$null
        } catch {}
    }
    if ($null -ne $fixtureProcess -and -not $fixtureProcess.HasExited) {
        Wait-Process -Id $fixtureProcess.Id -Timeout 10 -ErrorAction SilentlyContinue
        $fixtureProcess.Refresh()
        if (-not $fixtureProcess.HasExited) {
            Stop-Process -Id $fixtureProcess.Id -Force -ErrorAction SilentlyContinue
            Wait-Process -Id $fixtureProcess.Id -Timeout 5 -ErrorAction SilentlyContinue
            $fixtureProcess.Refresh()
        }
        if (-not $fixtureProcess.HasExited) {
            $cleanupFailures.Add('SSH fixture launcher process remained after cleanup')
        }
    }
    $fixtureProcessAbsent = ($null -eq $fixtureProcess -or $fixtureProcess.HasExited)
    try {
        if (Test-LeanTTYDeviceKeyFilesPresent `
            -Hdc $hdc `
            -Target $Target `
            -KeyName $keyName) {
            $cleanupFailures.Add('Disposable SSH authentication key remained after cleanup audit')
        } else {
            $keyAbsenceAudited = $true
        }
    } catch {
        $cleanupFailures.Add('Disposable SSH authentication key absence audit failed')
    }
    if (-not [string]::IsNullOrWhiteSpace($failure)) {
        foreach ($diagnostic in @(
            @{ source = $fixtureStdout; destination = 'failure-fixture-stdout.txt' },
            @{ source = $fixtureStderr; destination = 'failure-fixture-stderr.txt' }
        )) {
            try {
                if (Test-Path -LiteralPath $diagnostic.source -PathType Leaf) {
                    Save-SafeDiagnosticText `
                        -Text ([IO.File]::ReadAllText($diagnostic.source)) `
                        -FileName $diagnostic.destination
                }
            } catch {}
        }
    }
    if ($awakeLeaseActive) {
        try {
            Stop-LeanTTYDeviceAwakeLease -Hdc $hdc -Target $Target
            $awakeLeaseActive = $false
            $awakeLeaseResult = 'restored'
        } catch {
            $awakeLeaseResult = 'restore-failed'
            $awakeLeaseFailure = $_.Exception.Message
            $cleanupFailures.Add('HarmonyOS awake lease cleanup failed')
        }
    }
    if (Test-Path -LiteralPath $fixtureRoot) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $fixtureRoot) {
            $cleanupFailures.Add('SSH fixture temporary directory remained after cleanup')
        }
    }
    $credentials = @{}
    $secrets = @()
    $keyPassphrase = ''
    if ($cleanupFailures.Count -eq 0) {
        $cleanupResult = 'passed'
    } else {
        $cleanupResult = 'failed'
        $cleanupFailure = $cleanupFailures -join '; '
        if ([string]::IsNullOrWhiteSpace($failure)) { $failure = $cleanupFailure }
        $scenarioResult = 'failed'
    }
}

Write-AuthEvidence
if ($scenarioResult -ne 'passed') {
    if ($null -ne $caughtError) { throw $caughtError }
    throw $failure
}

Write-AuthLiveStatus -State 'passed' -Stage 'complete'
if ($runMode -eq 'acceptance') {
    Save-LeanTTYVerifiedCandidate `
        -RepoRoot $repoRoot `
        -HapPath $candidate.hapPath `
        -VerificationMode 'device-behavior' `
        -EvidencePaths @($evidencePath) `
        -CandidateBasePath $CandidateBasePath | Out-Null
    Write-Host (
        'DEVICE BEHAVIOR SUCCESS: ssh-interactive-authentication ' +
        "(SHA256=$($candidate.sha256), evidence=$evidencePath)"
    ) -ForegroundColor Green
} else {
    Write-Host (
        'DIAGNOSTIC SUCCESS: ssh-interactive-authentication ' +
        "(stages=$($selectedStageNames -join ','), evidence=$evidencePath; candidate not promoted)"
    ) -ForegroundColor Yellow
}
