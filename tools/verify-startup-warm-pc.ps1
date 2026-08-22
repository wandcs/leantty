<#
.SYNOPSIS
  Measure LeanTTY warm foreground startup to first-letter paint on a physical PC.
.DESCRIPTION
  Builds a test-signed diagnostic HAP from -SourceRoot, preserves installed app
  data during installation, preconditions one background/foreground cycle, and
  then measures real App Center icon clicks while requiring the process identity
  to remain stable. T5 is emitted only after the injected ASCII byte completes
  the production local-input round trip and xterm paint.
#>
param(
    [string]$Target = '',
    [ValidateRange(3, 100)][int]$SampleCount = 20,
    [string]$SourceRoot = '',
    [string]$EvidenceDirectory = '',
    [string]$VersionLabel = 'candidate',
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'hdc-common.ps1')
. (Join-Path $PSScriptRoot 'device-regression.ps1')
. (Join-Path $PSScriptRoot 'startup-warm-source.ps1')

if ([string]::IsNullOrWhiteSpace($SourceRoot)) { $SourceRoot = $repoRoot }
$sourceRoot = [IO.Path]::GetFullPath($SourceRoot)

function Invoke-WarmHdcShell {
    param([Parameter(Mandatory = $true)][string]$Command, [switch]$AllowEmpty)
    $output = @(& $script:hdc -t $script:target shell $Command 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "HarmonyOS shell command failed: $Command" }
    if (-not $AllowEmpty -and [string]::IsNullOrWhiteSpace($output)) {
        throw "HarmonyOS shell command returned no output: $Command"
    }
    return $output
}

function Get-WarmGlobalLayout {
    param([Parameter(Mandatory = $true)][string]$Name)
    $localPath = Join-Path $script:evidenceDirectory ($Name + '.json')
    return Get-HdcUiLayout `
        -Hdc $script:hdc `
        -Target $script:target `
        -LocalPath $localPath `
        -Operation 'HarmonyOS warm-start global UI layout capture'
}

function Get-WarmNodeCenter {
    param([Parameter(Mandatory = $true)]$Layout, [Parameter(Mandatory = $true)][string]$Id)
    $matches = @(Get-LeanTTYLayoutNodes -Node $Layout | Where-Object {
        [string]$_.attributes.id -eq $Id -and [string]$_.attributes.clickable -eq 'true'
    })
    if ($matches.Count -ne 1) { throw "Expected one clickable UI node '$Id', found $($matches.Count)" }
    return Get-LeanTTYBoundsCenter -Bounds ([string]$matches[0].attributes.bounds)
}

function Convert-WarmEpochToMilliseconds {
    param([Parameter(Mandatory = $true)][string]$Epoch)
    return [long][Math]::Round(([double]::Parse(
        $Epoch, [Globalization.CultureInfo]::InvariantCulture
    ) * 1000.0))
}

function Get-WarmMarkerTimes {
    param([Parameter(Mandatory = $true)][string]$Logs)
    $times = @{}
    foreach ($line in $Logs -split "`r?`n") {
        $match = [regex]::Match(
            $line,
            '^(?<epoch>\d+\.\d{3}) .*PERF render STARTUP_WARM phase=(?<phase>T[45])$'
        )
        if (-not $match.Success) { continue }
        $phase = $match.Groups['phase'].Value
        if ($times.ContainsKey($phase)) { throw "Duplicate warm startup marker: $phase" }
        $times[$phase] = Convert-WarmEpochToMilliseconds -Epoch $match.Groups['epoch'].Value
    }
    foreach ($phase in @('T4', 'T5')) {
        if (-not $times.ContainsKey($phase)) { throw "Warm startup marker is missing: $phase" }
    }
    return $times
}

function Get-WarmPercentile {
    param([Parameter(Mandatory = $true)][long[]]$Values, [Parameter(Mandatory = $true)][int]$Percentile)
    $sorted = @($Values | Sort-Object)
    $index = [Math]::Max(0, [Math]::Ceiling(($Percentile / 100.0) * $sorted.Count) - 1)
    return [long]$sorted[$index]
}

function Get-WarmStatistics {
    param([Parameter(Mandatory = $true)][long[]]$Values)
    $measure = $Values | Measure-Object -Minimum -Maximum -Average
    return [ordered]@{
        count = $Values.Count
        p50Ms = Get-WarmPercentile -Values $Values -Percentile 50
        p95Ms = Get-WarmPercentile -Values $Values -Percentile 95
        minMs = [long]$measure.Minimum
        maxMs = [long]$measure.Maximum
        averageMs = [Math]::Round([double]$measure.Average, 1)
    }
}

$script:hdc = Resolve-Hdc
$script:target = Resolve-LeanTTYRegressionTarget -Hdc $script:hdc -Target $Target
$transport = Get-HdcTargetTransport -Hdc $script:hdc -Target $script:target
if ($transport -ne 'usb') { throw "Warm startup measurement requires USB, got $transport" }

if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
    $EvidenceDirectory = Join-Path $repoRoot (
        'build\verification\startup-warm-' + $VersionLabel + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    )
}
$script:evidenceDirectory = [IO.Path]::GetFullPath($EvidenceDirectory)
New-Item -ItemType Directory -Force -Path $script:evidenceDirectory | Out-Null

$awakeLease = $false
$samples = [Collections.Generic.List[object]]::new()
try {
    Start-LeanTTYDeviceAwakeLease -Hdc $script:hdc -Target $script:target
    $awakeLease = $true

    $hapPath = Join-Path $sourceRoot 'entry\build\default\outputs\default\entry-default-signed.hap'
    if (-not $SkipBuild) {
        Invoke-WithLeanTTYStartupWarmSource -RepoRoot $sourceRoot -Action {
            & (Join-Path $sourceRoot 'tools\build-all.ps1') -BuildMode debug
            if ($LASTEXITCODE -ne 0) { throw 'Warm startup diagnostic build failed' }
        }
    }
    if (-not (Test-Path -LiteralPath $hapPath -PathType Leaf)) { throw "Signed HAP is missing: $hapPath" }
    $installOutput = @(& $script:hdc -t $script:target install -r -d $hapPath 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $installOutput -match '(?i)\[Fail\]|error') {
        throw "Warm startup diagnostic install failed: $installOutput"
    }

    $model = (Invoke-WarmHdcShell -Command 'param get const.product.model').Trim()
    $abi = (Invoke-WarmHdcShell -Command 'param get const.product.cpu.abilist').Trim()
    $osVersion = (Invoke-WarmHdcShell -Command 'param get const.product.software.version').Trim()
    if ($abi -notmatch 'arm64-v8a') { throw "Target is not ARM64: $abi" }
    $gitCommit = (& git -C $sourceRoot rev-parse HEAD).Trim()
    $hapSha256 = (Get-FileHash -LiteralPath $hapPath -Algorithm SHA256).Hash.ToLowerInvariant()

    & $script:hdc -t $script:target shell 'aa force-stop com.leantty.app' | Out-Null
    Start-LeanTTYRegressionApp `
        -Hdc $script:hdc `
        -Target $script:target `
        -CredentialPath (Get-LeanTTYDeviceUnlockPasswordPath) `
        -RepositoryRoot $repoRoot | Out-Null
    Start-Sleep -Seconds 3
    $processId = (Invoke-WarmHdcShell -Command 'pidof com.leantty.app').Trim()
    if ($processId -notmatch '^\d+$') { throw "Invalid LeanTTY PID: $processId" }
    & $script:hdc -t $script:target shell 'uitest uiInput keyEvent Home' | Out-Null
    Start-Sleep -Seconds 2

    for ($sampleIndex = 1; $sampleIndex -le $SampleCount; $sampleIndex++) {
        $beforePid = (Invoke-WarmHdcShell -Command 'pidof com.leantty.app').Trim()
        if ($beforePid -ne $processId) { throw 'LeanTTY process changed before a warm sample' }

        $desktopLayout = Get-WarmGlobalLayout -Name ("sample-{0:D2}-desktop" -f $sampleIndex)
        $appCenter = Get-WarmNodeCenter -Layout $desktopLayout `
            -Id 'AppIconCommonView_com.ohos.sceneboard.com.ohos.sceneboard.appcenter.MainAbility'
        & $script:hdc -t $script:target shell "uitest uiInput click $($appCenter.x) $($appCenter.y)" | Out-Null
        Start-Sleep -Milliseconds 900
        $appCenterLayout = Get-WarmGlobalLayout -Name ("sample-{0:D2}-app-center" -f $sampleIndex)
        $leanTtyIcon = Get-WarmNodeCenter -Layout $appCenterLayout -Id 'AppCenterAppGrid_AppBubble_com.leantty.app'

        Clear-LeanTTYAppLogs -Hdc $script:hdc -Target $script:target
        $deviceCommand = 'sh -c ''(i=0; while ! hilog -x -t app -T TerminalBridge | ' +
            'grep -q "PERF render STARTUP_WARM phase=T4"; do i=$((i+1)); ' +
            'if [ $i -ge 500 ]; then printf WATCH_TIMEOUT=1; exit 1; fi; sleep 0.02; done; ' +
            'printf TIN=; date +%s%3N; uinput -K -d 2017 -u 2017; sleep 0.3) & ' +
            'sleep 0.1; printf T0=; date +%s%3N; uitest uiInput click ' +
            $leanTtyIcon.x + ' ' + $leanTtyIcon.y + '; wait'''
        $launchOutput = @(& $script:hdc -t $script:target shell $deviceCommand 2>&1) -join "`n"
        if ($LASTEXITCODE -ne 0 -or $launchOutput -match 'WATCH_TIMEOUT') {
            throw "Device-side warm watcher failed for sample ${sampleIndex}: $launchOutput"
        }
        $t0Match = [regex]::Match($launchOutput, '(?m)^T0=(?<time>\d{13})$')
        $inputMatch = [regex]::Match($launchOutput, '(?m)^TIN=(?<time>\d{13})$')
        if (-not $t0Match.Success -or -not $inputMatch.Success) {
            throw "Device timestamps are missing for sample ${sampleIndex}: $launchOutput"
        }
        $t0 = [long]$t0Match.Groups['time'].Value
        $inputAt = [long]$inputMatch.Groups['time'].Value
        Start-Sleep -Milliseconds 300

        $afterPid = (Invoke-WarmHdcShell -Command 'pidof com.leantty.app').Trim()
        if ($afterPid -ne $processId) { throw 'LeanTTY process changed during a warm sample' }
        $logs = @(& $script:hdc -t $script:target shell (
            "hilog -z 200 -t app -P $processId -T TerminalBridge -v epoch -v msec"
        ) 2>&1) -join "`n"
        if ($LASTEXITCODE -ne 0) { throw 'Unable to read warm startup logs' }
        $markerLines = @($logs -split "`r?`n" | Where-Object { $_ -match 'STARTUP_WARM' }) -join "`n"
        [IO.File]::WriteAllText(
            (Join-Path $script:evidenceDirectory ("sample-{0:D2}-startup.log" -f $sampleIndex)),
            $markerLines + "`n"
        )
        $markers = Get-WarmMarkerTimes -Logs $markerLines
        $injectionLag = $inputAt - [long]$markers.T4
        if ($injectionLag -lt 0 -or $injectionLag -gt 250) {
            throw "T4-to-input lag is outside 0-250 ms: $injectionLag"
        }
        $sample = [pscustomobject][ordered]@{
            index = $sampleIndex
            t0ClickEpochMs = $t0
            t4ForegroundPaintEpochMs = [long]$markers.T4
            inputInjectedEpochMs = $inputAt
            t5FirstLetterPaintEpochMs = [long]$markers.T5
            clickToForegroundPaintMs = [long]$markers.T4 - $t0
            t4ToInputInjectionMs = $injectionLag
            inputRoundTripPaintMs = [long]$markers.T5 - $inputAt
            clickToFirstLetterPaintMs = [long]$markers.T5 - $t0
        }
        $samples.Add($sample)
        Write-Host "Warm $VersionLabel $sampleIndex/${SampleCount}: T0-T5=$($sample.clickToFirstLetterPaintMs) ms" `
            -ForegroundColor Cyan
        if ($sampleIndex -eq 1) {
            Save-LeanTTYDeviceScreenshot -Hdc $script:hdc -Target $script:target `
                -LocalPath (Join-Path $script:evidenceDirectory 'sample-01-first-letter.png')
        }
        Invoke-LeanTTYDeviceCtrlC -Hdc $script:hdc -Target $script:target
        & $script:hdc -t $script:target shell 'uitest uiInput keyEvent Home' | Out-Null
        Start-Sleep -Milliseconds 500
    }

    $summary = [ordered]@{
        schemaVersion = 1
        capturedAt = (Get-Date).ToString('o')
        scenario = 'warm-foreground-from-system-app-center'
        versionLabel = $VersionLabel
        sampleCount = $samples.Count
        gitCommit = $gitCommit
        hapSha256 = $hapSha256
        device = [ordered]@{ target = $script:target; transport = $transport; model = $model; abi = $abi; osVersion = $osVersion }
        validity = [ordered]@{
            processRetainedForAllSamples = $true
            realAppCenterIconClick = $true
            preconditionedBackgroundMaintenance = $true
            t5RequiresMatchingAsciiEchoAndPaint = $true
            maxT4ToInputInjectionMs = 250
        }
        statistics = [ordered]@{
            clickToFirstLetterPaint = Get-WarmStatistics -Values @($samples | ForEach-Object { [long]$_.clickToFirstLetterPaintMs })
            clickToForegroundPaint = Get-WarmStatistics -Values @($samples | ForEach-Object { [long]$_.clickToForegroundPaintMs })
            inputRoundTripPaint = Get-WarmStatistics -Values @($samples | ForEach-Object { [long]$_.inputRoundTripPaintMs })
        }
        samples = @($samples)
    }
    $summaryPath = Join-Path $script:evidenceDirectory 'summary.json'
    [IO.File]::WriteAllText($summaryPath, (ConvertTo-Json $summary -Depth 10) + "`n")
    Write-Host "WARM STARTUP EVIDENCE: $summaryPath" -ForegroundColor Green
    Write-Host "Warm T0-T5 P50=$($summary.statistics.clickToFirstLetterPaint.p50Ms) ms, P95=$($summary.statistics.clickToFirstLetterPaint.p95Ms) ms" -ForegroundColor Green
} finally {
    & $script:hdc -t $script:target shell 'uitest uiInput keyEvent Home' 2>$null | Out-Null
    if ($awakeLease) { Stop-LeanTTYDeviceAwakeLease -Hdc $script:hdc -Target $script:target }
}
