<#
.SYNOPSIS
  Run focused LeanTTY software checks or the complete formal-release gate.
.DESCRIPTION
  With -Group, runs only the explicitly selected checks for routine work. With
  no group, runs the complete source policy, script workflow, Web terminal,
  trusted ArkTS and WSL Rust formal-release gate. Focused evidence is marked as
  non-release evidence. This script does not build, sign, install or claim
  physical-device behavior.
#>
[CmdletBinding()]
param(
    [string[]]$Group = @(),
    [string]$EvidencePath = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'rust-wsl.ps1')

$startedAt = [DateTimeOffset]::UtcNow
$script:regressionResults = [Collections.Generic.List[object]]::new()
$script:regressionDetail = ''
$validRegressionGroups = @(
    'policy',
    'tooling',
    'ssh-flow',
    'web',
    'arkts',
    'rust-core',
    'rust-native',
    'ssh-fixture'
)
$requestedRegressionGroups = @(
    foreach ($groupArgument in $Group) {
        foreach ($groupName in @($groupArgument -split ',')) {
            $trimmedGroupName = $groupName.Trim()
            if (-not [string]::IsNullOrWhiteSpace($trimmedGroupName)) {
                $trimmedGroupName
            }
        }
    }
)
$invalidRegressionGroups = @($requestedRegressionGroups | Where-Object {
    $validRegressionGroups -notcontains $_
})
if ($invalidRegressionGroups.Count -gt 0) {
    throw (
        'Unknown software test group(s): ' + ($invalidRegressionGroups -join ', ') +
        '. Valid groups: ' + ($validRegressionGroups -join ', ')
    )
}
$script:selectedRegressionGroups = @($requestedRegressionGroups | Sort-Object -Unique)
$script:regressionMode = if ($script:selectedRegressionGroups.Count -eq 0) {
    'full'
} else {
    'focused'
}

if ([string]::IsNullOrWhiteSpace($EvidencePath)) {
    $evidenceDirectory = Join-Path $repoRoot 'build\verification'
    $evidencePrefix = if ($script:regressionMode -eq 'full') { 'software-' } else { 'software-focused-' }
    $evidenceName = $evidencePrefix + $startedAt.ToString('yyyyMMddTHHmmssfffZ') + '.json'
    $EvidencePath = Join-Path $evidenceDirectory $evidenceName
} else {
    $EvidencePath = [IO.Path]::GetFullPath($EvidencePath)
    $evidenceDirectory = Split-Path $EvidencePath -Parent
}
New-Item -ItemType Directory -Path $evidenceDirectory -Force | Out-Null

function Get-GitValue {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = @(& git -C $repoRoot @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0 -or $output.Count -ne 1) {
        throw "Git identity query failed: git $($Arguments -join ' ')"
    }
    return [string]$output[0]
}

function Write-RegressionEvidence {
    param([string]$Failure = '')

    $status = @(git -C $repoRoot status --porcelain --untracked-files=all 2>&1)
    if ($LASTEXITCODE -ne 0) { throw 'Unable to record regression Git status' }
    $passed = [string]::IsNullOrWhiteSpace($Failure)
    $evidence = [ordered]@{
        schemaVersion = 1
        gate = $(if ($script:regressionMode -eq 'full') { 'software' } else { 'software-focused' })
        mode = $script:regressionMode
        selectedGroups = @($script:selectedRegressionGroups)
        releaseEligible = ($script:regressionMode -eq 'full' -and $passed)
        result = $(if ($passed) { 'passed' } else { 'failed' })
        startedAt = $startedAt.ToString('o')
        completedAt = [DateTimeOffset]::UtcNow.ToString('o')
        git = [ordered]@{
            commit = Get-GitValue -Arguments @('rev-parse', 'HEAD')
            tree = Get-GitValue -Arguments @('rev-parse', 'HEAD^{tree}')
            dirty = ($status.Count -gt 0)
        }
        checks = @($script:regressionResults)
        failure = $Failure
    }
    [IO.File]::WriteAllText(
        $EvidencePath,
        (ConvertTo-Json -InputObject $evidence -Depth 6),
        [Text.UTF8Encoding]::new($false)
    )
}

function Test-RegressionGroupSelected {
    param([Parameter(Mandatory = $true)][string[]]$Groups)

    if ($script:regressionMode -eq 'full') { return $true }
    foreach ($candidate in $Groups) {
        if ($script:selectedRegressionGroups -contains $candidate) { return $true }
    }
    return $false
}

function Invoke-RegressionCheck {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string[]]$Groups,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )

    if (-not (Test-RegressionGroupSelected -Groups $Groups)) { return }
    $checkStartedAt = [DateTimeOffset]::UtcNow
    $script:regressionDetail = ''
    Write-Host "[regression] $Name" -ForegroundColor Cyan
    try {
        $global:LASTEXITCODE = 0
        & $Action
        $script:regressionResults.Add([pscustomobject]@{
            name = $Name
            result = 'passed'
            durationMs = [int]([DateTimeOffset]::UtcNow - $checkStartedAt).TotalMilliseconds
            detail = $script:regressionDetail
        })
    } catch {
        $message = $_.Exception.Message
        $script:regressionResults.Add([pscustomobject]@{
            name = $Name
            result = 'failed'
            durationMs = [int]([DateTimeOffset]::UtcNow - $checkStartedAt).TotalMilliseconds
            detail = $message
        })
        Write-RegressionEvidence -Failure "$Name`: $message"
        throw
    }
}

Invoke-RegressionCheck -Name 'public-source-policy' -Groups @('policy') -Action {
    & (Join-Path $PSScriptRoot 'check-public-source.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Public-source policy check failed' }
}

Invoke-RegressionCheck -Name 'build-workflow-regressions' -Groups @('tooling') -Action {
    & (Join-Path $PSScriptRoot 'test-build-workflows.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Build workflow regression tests failed' }
}

Invoke-RegressionCheck -Name 'device-regression-helpers' -Groups @('tooling') -Action {
    & (Join-Path $PSScriptRoot 'test-device-regression.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Device regression helper tests failed' }
}

Invoke-RegressionCheck -Name 'ssh-transport-contract' -Groups @('ssh-flow') -Action {
    & (Join-Path $PSScriptRoot 'check-ssh-transport-flow.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'SSH generated transport contract check failed' }
}

Invoke-RegressionCheck -Name 'ssh-keygen-async-flow' -Groups @('ssh-flow') -Action {
    & (Join-Path $PSScriptRoot 'check-keygen-async-flow.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'SSH key-generation async flow check failed' }
}

$script:devecoPath = ''
$script:nodePath = ''
$script:hvigorPath = ''
$script:ohpmPath = ''
Invoke-RegressionCheck -Name 'deveco-environment' -Groups @('web', 'arkts') -Action {
    $resolvedDeveco = $env:DEVECO_HOME
    if (-not $resolvedDeveco) {
        foreach ($candidate in @(
                'C:\Program Files\Huawei\DevEco Studio',
                'D:\Program Files\Huawei\DevEco Studio'
            )) {
            if (Test-Path -LiteralPath $candidate) { $resolvedDeveco = $candidate; break }
        }
    }
    if (-not $resolvedDeveco) { throw 'DevEco Studio not found. Set DEVECO_HOME.' }
    $resolvedNode = Join-Path $resolvedDeveco 'tools\node\node.exe'
    $resolvedHvigor = Join-Path $resolvedDeveco 'tools\hvigor\bin\hvigorw.js'
    $resolvedOhpm = Join-Path $resolvedDeveco 'tools\ohpm\bin\ohpm.bat'
    foreach ($requiredTool in @($resolvedNode, $resolvedHvigor, $resolvedOhpm)) {
        if (-not (Test-Path -LiteralPath $requiredTool -PathType Leaf)) {
            throw "DevEco tool is missing: $requiredTool"
        }
    }
    $script:devecoPath = $resolvedDeveco
    $script:nodePath = $resolvedNode
    $script:hvigorPath = $resolvedHvigor
    $script:ohpmPath = $resolvedOhpm
}
$needsDevEco = Test-RegressionGroupSelected -Groups @('web', 'arkts')
if ($needsDevEco) {
    $deveco = $script:devecoPath
    $nodeExe = $script:nodePath
    $hvigorJs = $script:hvigorPath
    $ohpm = $script:ohpmPath
    $env:NODE_OPTIONS = ''
    $env:DEVECO_SDK_HOME = Join-Path $deveco 'sdk'
    $env:JAVA_HOME = Join-Path $deveco 'jbr'
    $env:PATH = (Join-Path $deveco 'jbr\bin') + ';' + $env:PATH
}

$hypiumPath = Join-Path $repoRoot 'oh_modules\@ohos\hypium'
if ((Test-RegressionGroupSelected -Groups @('arkts')) -and
    -not (Test-Path -LiteralPath $hypiumPath)) {
    Invoke-RegressionCheck -Name 'ohpm-lockfile-restore' -Groups @('arkts') -Action {
        Push-Location $repoRoot
        try {
            & $ohpm install --all --lockfile_stable_order
            if ($LASTEXITCODE -ne 0) { throw 'OHPM dependency restore failed' }
        } finally {
            Pop-Location
        }
        if (-not (Test-Path -LiteralPath $hypiumPath)) {
            throw 'Hypium dependency is still missing after OHPM restore'
        }
    }
}

Invoke-RegressionCheck -Name 'web-terminal-policy' -Groups @('web') -Action {
    & $nodeExe (Join-Path $repoRoot 'tools\web-terminal\test-terminal-policy.mjs')
    if ($LASTEXITCODE -ne 0) { throw 'Web terminal policy tests failed' }
}

Invoke-RegressionCheck -Name 'offline-user-guide' -Groups @('web') -Action {
    & $nodeExe (Join-Path $repoRoot 'tools\web-terminal\test-user-guide.mjs')
    if ($LASTEXITCODE -ne 0) { throw 'Offline user guide tests failed' }
}

Invoke-RegressionCheck -Name 'trusted-arkts-tests' -Groups @('arkts') -Action {
    Push-Location $repoRoot
    try {
        $arkTsTestStartedAt = Get-Date
        & $nodeExe $hvigorJs --mode module -p module=entry@default test
        if ($LASTEXITCODE -ne 0) { throw 'Trusted ArkTS unit tests failed' }
    } finally {
        Pop-Location
    }
    $resultPath = Join-Path $repoRoot 'entry\.test\default\intermediates\test\coverage_data\test_result.txt'
    if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
        throw "Trusted ArkTS unit test result not found: $resultPath"
    }
    if ((Get-Item -LiteralPath $resultPath).LastWriteTime -lt $arkTsTestStartedAt.AddSeconds(-1)) {
        throw 'Trusted ArkTS unit test result was not refreshed by the current run'
    }
    $summary = Get-Content -LiteralPath $resultPath -Raw
    $summaryMatch = [regex]::Match(
        $summary,
        '(?m)^Tests run: (?<run>\d+), Failure: (?<failure>\d+), Error: (?<error>\d+), Pass: (?<pass>\d+), Ignore: (?<ignore>\d+)\s*$'
    )
    if (-not $summaryMatch.Success) { throw 'Trusted ArkTS unit test summary is missing or malformed' }
    if ([int]$summaryMatch.Groups['failure'].Value -ne 0 -or
        [int]$summaryMatch.Groups['error'].Value -ne 0) {
        throw ('Trusted ArkTS unit tests failed: ' + $summaryMatch.Value.Trim())
    }
    $script:regressionDetail = $summaryMatch.Value.Trim()
}

Invoke-RegressionCheck -Name 'rust-format-wsl' -Groups @(
    'rust-core', 'rust-native', 'ssh-fixture'
) -Action {
    Invoke-LeanTTYRustWsl -RepoRoot $repoRoot -CargoArguments @(
        'fmt', '--manifest-path', './leantty_ssh/Cargo.toml', '--all', '--', '--check'
    )
}

Invoke-RegressionCheck -Name 'rust-clippy-wsl' -Groups @('rust-core') -Action {
    Invoke-LeanTTYRustWsl -RepoRoot $repoRoot -CargoArguments @(
        'clippy', '--locked', '--manifest-path', './leantty_ssh/Cargo.toml',
        '-p', 'leantty-ssh-core', '--all-targets', '--', '-D', 'warnings'
    )
}

Invoke-RegressionCheck -Name 'rust-native-clippy-wsl' -Groups @('rust-native') -Action {
    Invoke-LeanTTYRustWsl -RepoRoot $repoRoot -CargoArguments @(
        'clippy', '--locked', '--manifest-path', './leantty_ssh/Cargo.toml',
        '-p', 'leantty_ssh', '--all-targets', '--', '-D', 'warnings'
    )
}

Invoke-RegressionCheck -Name 'rust-native-test-isolation-wsl' -Groups @('rust-native') -Action {
    $wslRepoRoot = ConvertTo-LeanTTYWslPath -WindowsPath $repoRoot
    $wslPrefix = Get-LeanTTYWslPrefix
    $treeOutput = @(
        & wsl.exe @wslPrefix --cd $wslRepoRoot -- env RUSTUP_TOOLCHAIN=stable cargo tree `
            --locked --offline --manifest-path ./leantty_ssh/Cargo.toml -p leantty_ssh `
            -e normal,build -f '{p} {f}' 2>&1
    )
    if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect the production Rust feature tree' }
    $productionNapiLines = @($treeOutput | Where-Object { $_ -match 'napi-(ohos|sys-ohos)' })
    if ($productionNapiLines.Count -eq 0) { throw 'Production N-API feature tree is missing' }
    if (($productionNapiLines -join "`n") -match '(dyn-symbols|noop)') {
        throw 'Test-only N-API symbol features leaked into the production dependency tree'
    }
    $script:regressionDetail = 'production N-API tree excludes dyn-symbols and noop'
}

Invoke-RegressionCheck -Name 'rust-native-tests-wsl' -Groups @('rust-native') -Action {
    Invoke-LeanTTYRustWsl -RepoRoot $repoRoot -CargoArguments @(
        'test', '--locked', '--offline', '--manifest-path', './leantty_ssh/Cargo.toml',
        '-p', 'leantty_ssh'
    )
}

Invoke-RegressionCheck -Name 'rust-core-tests-wsl' -Groups @('rust-core') -Action {
    Invoke-LeanTTYRustWsl -RepoRoot $repoRoot -CargoArguments @(
        'test', '--locked', '--manifest-path', './leantty_ssh/Cargo.toml',
        '-p', 'leantty-ssh-core'
    )
}

Invoke-RegressionCheck -Name 'ssh-auth-fixture-tests-wsl' -Groups @('ssh-fixture') -Action {
    Invoke-LeanTTYRustWsl -RepoRoot $repoRoot -CargoArguments @(
        'test', '--locked', '--manifest-path', './leantty_ssh/Cargo.toml',
        '-p', 'leantty-ssh-auth-fixture'
    )
}

Invoke-RegressionCheck -Name 'ssh-auth-fixture-clippy-wsl' -Groups @('ssh-fixture') -Action {
    Invoke-LeanTTYRustWsl -RepoRoot $repoRoot -CargoArguments @(
        'clippy', '--locked', '--manifest-path', './leantty_ssh/Cargo.toml',
        '-p', 'leantty-ssh-auth-fixture', '--all-targets', '--', '-D', 'warnings'
    )
}

Invoke-RegressionCheck -Name 'ssh-auth-fixture-e2e-wsl' -Groups @('ssh-fixture') -Action {
    $wslRepoRoot = ConvertTo-LeanTTYWslPath -WindowsPath $repoRoot
    $wslPrefix = Get-LeanTTYWslPrefix
    & wsl.exe @wslPrefix --cd $wslRepoRoot -- env RUSTUP_TOOLCHAIN=stable bash ./leantty_ssh/ssh-auth-fixture/test-e2e.sh
    if ($LASTEXITCODE -ne 0) { throw 'SSH authentication fixture end-to-end tests failed' }
}

Invoke-RegressionCheck -Name 'git-diff-check' -Groups @('policy') -Action {
    & git -C $repoRoot diff --check
    if ($LASTEXITCODE -ne 0) { throw 'Unstaged diff check failed' }
    & git -C $repoRoot diff --cached --check
    if ($LASTEXITCODE -ne 0) { throw 'Staged diff check failed' }
}

Write-RegressionEvidence
$successLabel = if ($script:regressionMode -eq 'full') {
    'SOFTWARE REGRESSION SUCCESS'
} else {
    'SOFTWARE FOCUSED SUCCESS'
}
Write-Host "$successLabel`: $EvidencePath" -ForegroundColor Green
