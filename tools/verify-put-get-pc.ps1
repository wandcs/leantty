<#
.SYNOPSIS
  Verify the production PUT/GET event chain on a physical HarmonyOS PC.
.DESCRIPTION
  Builds and deploys the debug HAP, starts the repository-only SSH fixture with
  its bounded temporary SFTP root, maps a device loopback port, downloads one
  deterministic file into an existing Downloads subdirectory with an occupied
  basename, uploads the numbered result to an existing remote directory,
  compares SHA-256, and removes all disposable local and remote data.
#>
[CmdletBinding()]
param(
    [string]$Target = '',
    [ValidateRange(0, 65535)][int]$FixturePort = 0,
    [switch]$SkipBuild,
    [string]$EvidenceDirectory = '',
    [string]$SourceFile = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'hdc-common.ps1')
. (Join-Path $PSScriptRoot 'device-regression.ps1')

$hdc = Resolve-Hdc
$Target = Resolve-LeanTTYRegressionTarget -Hdc $hdc -Target $Target
if ($FixturePort -eq 0) { $FixturePort = Get-Random -Minimum 24000 -Maximum 48000 }
if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
    $EvidenceDirectory = Join-Path $repoRoot (
        'build\verification\put-get-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    )
}
$EvidenceDirectory = [IO.Path]::GetFullPath($EvidenceDirectory)
New-Item -ItemType Directory -Force -Path $EvidenceDirectory | Out-Null

$attemptToken = [Guid]::NewGuid().ToString('N')
$localDirectoryName = '.leantty-1-3-transfer-fixture'
$remoteGetName = 'source.bin'
$remoteDirectoryName = 'put-' + $attemptToken.Substring(0, 12)
$localExistingName = $localDirectoryName + '/' + $remoteGetName
$remoteStem = [IO.Path]::GetFileNameWithoutExtension($remoteGetName)
$remoteExtension = [IO.Path]::GetExtension($remoteGetName)
$localDownloadedName = $localDirectoryName + '/' + $remoteStem + ' (1)' + $remoteExtension
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('leantty-put-get-' + $attemptToken)
$fixtureReady = Join-Path $fixtureRoot 'fixture-ready'
$fixtureCredentials = Join-Path $fixtureRoot 'server-credentials'
$fixtureSftpRoot = Join-Path $fixtureRoot 'sftp-root'
$fixtureStdout = Join-Path $EvidenceDirectory 'fixture-stdout.log'
$fixtureStderr = Join-Path $EvidenceDirectory 'fixture-stderr.log'
$fixtureProcess = $null
$fixtureLinuxPid = 0
$reverseMapped = $false
$awakeLease = $false
$appProcessId = ''
$secret = ''
$sourceKind = 'generated-random'
$sourceBytesCount = 131089L
if (-not [string]::IsNullOrWhiteSpace($SourceFile)) {
    $SourceFile = [IO.Path]::GetFullPath($SourceFile)
    if (-not (Test-Path -LiteralPath $SourceFile -PathType Leaf)) {
        throw "PUT/GET source file does not exist: $SourceFile"
    }
    $sourceBytesCount = (Get-Item -LiteralPath $SourceFile).Length
    $sourceKind = 'caller-provided'
}

function Wait-FixtureReady {
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt 90) {
        if ($null -ne $fixtureProcess -and $fixtureProcess.HasExited) {
            throw "SFTP fixture exited before readiness (exit=$($fixtureProcess.ExitCode))"
        }
        if ((Test-Path -LiteralPath $fixtureReady -PathType Leaf) -and
            (Test-Path -LiteralPath $fixtureCredentials -PathType Leaf) -and
            (Test-Path -LiteralPath $fixtureSftpRoot -PathType Container)) {
            $readyText = [IO.File]::ReadAllText($fixtureReady)
            $pidMatch = [regex]::Match($readyText, '(?m)^pid=(?<pid>\d+)$')
            if ($pidMatch.Success) {
                $script:fixtureLinuxPid = [int]$pidMatch.Groups['pid'].Value
                return
            }
        }
        Start-Sleep -Milliseconds 200
    }
    throw 'Timed out waiting for the temporary SFTP fixture'
}

function Focus-TerminalInput {
    param([Parameter(Mandatory = $true)][string]$Name)

    $layoutPath = Join-Path $EvidenceDirectory ($Name + '.json')
    $layout = Wait-LeanTTYTerminalInputLayout `
        -Hdc $hdc -Target $Target -LocalPath $layoutPath -TimeoutSeconds 20
    $nodes = @(Get-LeanTTYTerminalInputNodes -Layout $layout)
    if ($nodes.Count -ne 1) { throw 'PUT/GET verifier requires exactly one terminal Pane' }
    Set-LeanTTYTerminalInputFocus `
        -Hdc $hdc -Target $Target -InputNode $nodes[0] -LocalPath $layoutPath | Out-Null
}

function Submit-TerminalText {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$LayoutName
    )

    Focus-TerminalInput -Name $LayoutName
    Invoke-LeanTTYDeviceText -Hdc $hdc -Target $Target -Text $Text
    Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $Target -KeyCode 2054
}

function Complete-TerminalTextWithTab {
    param(
        [Parameter(Mandatory = $true)][string]$Prefix,
        [string]$Suffix = '',
        [Parameter(Mandatory = $true)][string]$LayoutName
    )

    Focus-TerminalInput -Name $LayoutName
    Invoke-LeanTTYDeviceText -Hdc $hdc -Target $Target -Text $Prefix
    Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $Target -KeyCode 2049
    Start-Sleep -Milliseconds 300
    $tabLogs = Get-LeanTTYAppLogs -Hdc $hdc -Target $Target -ProcessId $appProcessId
    if ($tabLogs -match 'File transfer authentication prompt=|FILE_TRANSFER result=') {
        throw 'Tab completion unexpectedly started a transfer or remote authentication'
    }
    if (-not [string]::IsNullOrEmpty($Suffix)) {
        Invoke-LeanTTYDeviceText -Hdc $hdc -Target $Target -Text $Suffix
    }
    Invoke-LeanTTYDeviceKey -Hdc $hdc -Target $Target -KeyCode 2054
}

function Complete-PasswordAuthentication {
    param([Parameter(Mandatory = $true)][string]$Stage)

    $logs = Wait-LeanTTYAppLog `
        -Hdc $hdc -Target $Target -ProcessId $appProcessId `
        -Pattern 'File transfer authentication prompt=(host-key|password)|FILE_TRANSFER result=failed' `
        -TimeoutSeconds 30
    if ($logs -match 'FILE_TRANSFER result=failed') {
        throw "PUT/GET $Stage failed before authentication"
    }
    if ($logs -match 'File transfer authentication prompt=host-key') {
        Submit-TerminalText -Text 'yes' -LayoutName ($Stage + '-host-key')
        Wait-LeanTTYAppLog `
            -Hdc $hdc -Target $Target -ProcessId $appProcessId `
            -Pattern 'File transfer authentication prompt=password' -TimeoutSeconds 20 | Out-Null
    }
    Submit-TerminalText -Text $script:secret -LayoutName ($Stage + '-password')
}

function Invoke-TransferFixtureAction {
    param([Parameter(Mandatory = $true)][string]$Stage)

    $layoutPath = Join-Path $EvidenceDirectory ($Stage + '-before-menu.json')
    $layout = Get-LeanTTYDeviceLayout -Hdc $hdc -Target $Target -LocalPath $layoutPath
    $moreButton = @(Get-LeanTTYLayoutNodes -Node $layout | Where-Object {
        [string]$_.attributes.type -eq 'Stack' -and
        [string]$_.attributes.clickable -eq 'true' -and
        [string]$_.attributes.description -eq ''
    } | Sort-Object {
        (Get-LeanTTYBoundsCenter -Bounds ([string]$_.attributes.bounds)).x
    } -Descending | Select-Object -First 1)
    if ($moreButton.Count -ne 1) { throw 'LeanTTY four-dot menu button was not found' }
    $moreCenter = Get-LeanTTYBoundsCenter -Bounds ([string]$moreButton[0].attributes.bounds)
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    & $hdc -t $Target shell "uitest uiInput click $($moreCenter.x) $($moreCenter.y)" | Out-Null
    Start-Sleep -Milliseconds 300
    $menuPath = Join-Path $EvidenceDirectory ($Stage + '-menu.json')
    $menu = Get-LeanTTYDeviceLayout -Hdc $hdc -Target $Target -LocalPath $menuPath
    $label = 'Acceptance: Transfer Fixture'
    $node = @(Get-LeanTTYLayoutNodes -Node $menu | Where-Object {
        [string]$_.attributes.text -eq $label -or [string]$_.attributes.originalText -eq $label
    } | Select-Object -First 1)
    if ($node.Count -ne 1) { throw 'The debug package does not expose the transfer fixture action' }
    $center = Get-LeanTTYBoundsCenter -Bounds ([string]$node[0].attributes.bounds)
    & $hdc -t $Target shell "uitest uiInput click $($center.x) $($center.y)" | Out-Null
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $logs = ''
    do {
        $logs = (@(& $hdc -t $Target shell "hilog -z 1200 -t app -P $appProcessId" 2>&1) -join "`n")
        if ($logs -match 'ACCEPTANCE_TRANSFER_FIXTURE state=(prepared|cleaned|failed)') { break }
        Start-Sleep -Milliseconds 200
    } while ($stopwatch.Elapsed.TotalSeconds -lt 10)
    if ($logs -notmatch 'ACCEPTANCE_TRANSFER_FIXTURE state=(prepared|cleaned|failed)') {
        throw 'Timed out waiting for the transfer fixture action'
    }
    $line = @($logs -split "`n" | Where-Object {
        $_ -match 'ACCEPTANCE_TRANSFER_FIXTURE state='
    } | Select-Object -Last 1)
    if ($line.Count -ne 1 -or $line[0] -match 'state=failed') {
        throw 'The transfer fixture action failed'
    }
    return [string]$line[0]
}

try {
    Start-LeanTTYDeviceAwakeLease -Hdc $hdc -Target $Target -TimeoutMilliseconds 900000
    $awakeLease = $true

    $deployArgs = @{ Target = $Target; NoLaunch = $true }
    if ($SkipBuild) { $deployArgs['SkipBuild'] = $true }
    & (Join-Path $PSScriptRoot 'dev-pc.ps1') @deployArgs
    if ($LASTEXITCODE -ne 0) { throw 'LeanTTY PUT/GET debug deployment failed' }

    $fixtureArguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
        (Join-Path $PSScriptRoot 'start-ssh-auth-fixture.ps1'),
        '-ListenAddress', "0.0.0.0:$FixturePort",
        '-RunSeconds', '900',
        '-ControlDirectory', $fixtureRoot
    )
    $fixtureProcess = Start-Process `
        -FilePath 'pwsh.exe' `
        -ArgumentList $fixtureArguments `
        -RedirectStandardOutput $fixtureStdout `
        -RedirectStandardError $fixtureStderr `
        -WindowStyle Hidden `
        -PassThru
    Wait-FixtureReady

    foreach ($line in [IO.File]::ReadAllLines($fixtureCredentials)) {
        if ($line.StartsWith('password=', [StringComparison]::Ordinal)) {
            $secret = $line.Substring('password='.Length)
            break
        }
    }
    if ([string]::IsNullOrWhiteSpace($secret)) { throw 'Fixture password is unavailable' }

    $remoteSourcePath = Join-Path $fixtureSftpRoot $remoteGetName
    $remoteUploadDirectory = Join-Path $fixtureSftpRoot $remoteDirectoryName
    New-Item -ItemType Directory -Path $remoteUploadDirectory | Out-Null
    $remoteUploadedPath = Join-Path $remoteUploadDirectory ($remoteStem + ' (1)' + $remoteExtension)
    if ($sourceKind -eq 'caller-provided') {
        Copy-Item -LiteralPath $SourceFile -Destination $remoteSourcePath
    } else {
        $sourceBytes = [byte[]]::new([int]$sourceBytesCount)
        [Security.Cryptography.RandomNumberGenerator]::Fill($sourceBytes)
        [IO.File]::WriteAllBytes($remoteSourcePath, $sourceBytes)
    }
    $sourceHash = (Get-FileHash -LiteralPath $remoteSourcePath -Algorithm SHA256).Hash
    $expectedCompletionBytes = [regex]::Escape($sourceBytesCount.ToString())

    $existingMappings = @(& $hdc -t $Target rport ls 2>&1) -join "`n"
    if ($existingMappings -match "tcp:$FixturePort\b") {
        throw "HDC reverse mapping already exists for fixture port $FixturePort"
    }
    & $hdc -t $Target rport "tcp:$FixturePort" "tcp:$FixturePort" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to create the PUT/GET reverse mapping' }
    $reverseMapped = $true

    $launch = Start-LeanTTYRegressionApp `
        -Hdc $hdc `
        -Target $Target `
        -CredentialPath (Get-LeanTTYDeviceUnlockPasswordPath) `
        -RepositoryRoot $repoRoot
    $appProcessId = $launch.processId
    Focus-TerminalInput -Name 'initial-input'
    $fixtureState = Invoke-TransferFixtureAction -Stage 'fixture-prepare'
    if ($fixtureState -match 'state=cleaned') {
        $fixtureState = Invoke-TransferFixtureAction -Stage 'fixture-prepare-retry'
    }
    if ($fixtureState -notmatch 'state=prepared') { throw 'Transfer fixture was not prepared' }
    Focus-TerminalInput -Name 'after-fixture-prepare'

    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Complete-TerminalTextWithTab `
        -Prefix "get -p $FixturePort password@127.0.0.1:/$remoteGetName $localDirectoryName" `
        -LayoutName 'get-command'
    Complete-PasswordAuthentication -Stage 'get'
    $getStopwatch = [Diagnostics.Stopwatch]::StartNew()
    $getResult = Wait-LeanTTYAppLog `
        -Hdc $hdc -Target $Target -ProcessId $appProcessId `
        -Pattern "FILE_TRANSFER result=(completed direction=get,bytes=$expectedCompletionBytes|failed code=\S+)" `
        -TimeoutSeconds 60
    $getStopwatch.Stop()
    if ($getResult -match 'FILE_TRANSFER result=failed code=(?<code>\S+)') {
        throw "GET failed with code $($Matches['code'])"
    }
    if ($getResult -notmatch 'FILE_TRANSFER stage=finalizing') {
        throw 'GET completed without the FINALIZING stage'
    }
    if ($sourceBytesCount -ge 1MB -and
        ($getResult -notmatch 'FILE_TRANSFER progress=visible' -or
        $getResult -notmatch 'FILE_TRANSFER speed=visible')) {
        throw 'GET large-file progress completed without visible progress and live speed'
    }
    Clear-LeanTTYAppLogs -Hdc $hdc -Target $Target
    Complete-TerminalTextWithTab `
        -Prefix "put -p $FixturePort $localDirectoryName/source\ (1).b" `
        -Suffix "password@127.0.0.1:/$remoteDirectoryName/" `
        -LayoutName 'put-command'
    Complete-PasswordAuthentication -Stage 'put'
    $putStopwatch = [Diagnostics.Stopwatch]::StartNew()
    $putResult = Wait-LeanTTYAppLog `
        -Hdc $hdc -Target $Target -ProcessId $appProcessId `
        -Pattern "FILE_TRANSFER result=(completed direction=put,bytes=$expectedCompletionBytes|failed code=\S+)" `
        -TimeoutSeconds 60
    $putStopwatch.Stop()
    if ($putResult -match 'FILE_TRANSFER result=failed code=(?<code>\S+)') {
        throw "PUT failed with code $($Matches['code'])"
    }
    if ($putResult -notmatch 'FILE_TRANSFER stage=finalizing') {
        throw 'PUT completed without the FINALIZING stage'
    }
    if ($sourceBytesCount -ge 1MB -and
        ($putResult -notmatch 'FILE_TRANSFER progress=visible' -or
        $putResult -notmatch 'FILE_TRANSFER speed=visible')) {
        throw 'PUT large-file progress completed without visible progress and live speed'
    }

    if (-not (Test-Path -LiteralPath $remoteUploadedPath -PathType Leaf)) {
        throw 'PUT completed without the expected remote final file'
    }
    $uploadedHash = (Get-FileHash -LiteralPath $remoteUploadedPath -Algorithm SHA256).Hash
    if ($uploadedHash -cne $sourceHash) { throw 'GET then PUT changed the file SHA-256' }
    $unexpectedRemote = @(Get-ChildItem -LiteralPath $fixtureSftpRoot -Recurse -File | Where-Object {
        $_.FullName -notin @($remoteSourcePath, $remoteUploadedPath)
    })
    if ($unexpectedRemote.Count -ne 0) { throw 'PUT/GET left an unexpected remote temporary file' }

    $allLogs = Get-LeanTTYAppLogs -Hdc $hdc -Target $Target -ProcessId $appProcessId
    if ($allLogs.Contains($secret, [StringComparison]::Ordinal)) {
        throw 'HarmonyOS application logs exposed the temporary fixture password'
    }
    $cleanupState = Invoke-TransferFixtureAction -Stage 'fixture-cleanup'
    if ($cleanupState -notmatch 'state=cleaned,originalPreserved=true,numberedPresent=true') {
        throw 'Transfer fixture cleanup did not prove original-file preservation and numbered download presence'
    }

    $evidence = [ordered]@{
        recordedAt = (Get-Date).ToString('o')
        gate = '1.3-production-put-get-event-chain'
        result = 'passed'
        bytes = $sourceBytesCount
        sha256 = $sourceHash.ToLowerInvariant()
        sourceKind = $sourceKind
        getDurationMs = [int]$getStopwatch.ElapsedMilliseconds
        putDurationMs = [int]$putStopwatch.ElapsedMilliseconds
        getMiBPerSecond = [Math]::Round(
            ($sourceBytesCount / 1MB) / $getStopwatch.Elapsed.TotalSeconds, 2
        )
        putMiBPerSecond = [Math]::Round(
            ($sourceBytesCount / 1MB) / $putStopwatch.Elapsed.TotalSeconds, 2
        )
        get = 'existing Downloads subdirectory target auto-numbered without overwriting the original file'
        put = 'opened a Downloads subdirectory source and derived the basename for a remote directory target'
        pathSemantics = 'existing local and remote directories were reused; neither command created a directory'
        completion = 'local directory and file completion were used; Tab did not start transfer authentication'
        progress = $(if ($sourceBytesCount -ge 1MB) {
                'TTY progress rendered positive bytes, live speed and FINALIZING for GET and PUT'
            } else {
                'FINALIZING observed; transfer completed inside the intermediate UI throttle interval'
            })
        remoteCleanup = 'no unowned or temporary fixture files observed'
        sourceDirty = (@(git -C $repoRoot status --short).Count -gt 0)
        sourceCommit = (git -C $repoRoot rev-parse HEAD)
        hapSha256 = (Get-FileHash -LiteralPath (
                Join-Path $repoRoot 'entry\build\default\outputs\default\entry-default-signed.hap'
            ) -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $evidence | ConvertTo-Json -Depth 6 | Set-Content `
        -LiteralPath (Join-Path $EvidenceDirectory 'device-put-get.json') -Encoding utf8NoBOM
    Write-Host 'PUT/GET PC GATE PASSED: production GET -> Downloads -> PUT, SHA-256 exact' -ForegroundColor Green
} finally {
    $secret = ''
    if (-not [string]::IsNullOrWhiteSpace($appProcessId) -and
        ($null -eq $cleanupState -or $cleanupState -notmatch 'state=cleaned')) {
        try {
            $cleanupState = Invoke-TransferFixtureAction -Stage 'fixture-finally-cleanup'
            if ($cleanupState -match 'state=prepared') {
                $cleanupState = Invoke-TransferFixtureAction -Stage 'fixture-finally-cleanup-retry'
            }
        } catch {
            Write-Warning "Disposable Downloads fixture may remain: $localDirectoryName"
        }
    }
    if ($reverseMapped) {
        & $hdc -t $Target rport rm "tcp:$FixturePort" 2>$null | Out-Null
    }
    if ($fixtureLinuxPid -gt 0) {
        & wsl.exe --exec kill -TERM $fixtureLinuxPid 2>$null | Out-Null
    }
    if ($null -ne $fixtureProcess -and -not $fixtureProcess.HasExited) {
        Wait-Process -Id $fixtureProcess.Id -Timeout 10 -ErrorAction SilentlyContinue
        $fixtureProcess.Refresh()
        if (-not $fixtureProcess.HasExited) { Stop-Process -Id $fixtureProcess.Id -Force }
    }
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') +
        [IO.Path]::DirectorySeparatorChar
    if ((Test-Path -LiteralPath $fixtureRoot) -and
        [IO.Path]::GetFullPath($fixtureRoot).StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
    }
    if ($awakeLease) {
        Stop-LeanTTYDeviceAwakeLease -Hdc $hdc -Target $Target
    }
}
