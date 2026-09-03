function Resolve-LeanTTYGitSigningBackend {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $resolvedRepoRoot = [IO.Path]::GetFullPath($RepoRoot)
    $formatOutput = @(& git -C $resolvedRepoRoot config --get gpg.format 2>&1)
    $formatExitCode = $LASTEXITCODE
    $format = if ($formatExitCode -eq 0) {
        ($formatOutput -join "`n").Trim().ToLowerInvariant()
    } elseif ($formatExitCode -eq 1) {
        'openpgp'
    } else {
        throw 'Unable to resolve the Git signing format'
    }
    if ($format -ne 'openpgp') {
        throw "LeanTTY release tags require the OpenPGP signing backend, got $format"
    }

    $program = ''
    foreach ($key in @('gpg.openpgp.program', 'gpg.program')) {
        $programOutput = @(& git -C $resolvedRepoRoot config --path --get $key 2>&1)
        $programExitCode = $LASTEXITCODE
        if ($programExitCode -eq 0) {
            $program = ($programOutput -join "`n").Trim()
            break
        }
        if ($programExitCode -ne 1) {
            throw "Unable to resolve Git signing program from $key"
        }
    }
    if ([string]::IsNullOrWhiteSpace($program)) {
        $program = 'gpg.exe'
    }

    $command = Get-Command $program -CommandType Application -ErrorAction Stop |
        Select-Object -First 1
    [pscustomobject][ordered]@{
        format = $format
        configuredProgram = $program
        executablePath = [IO.Path]::GetFullPath($command.Source)
    }
}

function Assert-LeanTTYDeviceTestHapPath {
    param(
        [Parameter(Mandatory = $true)][string]$HapPath,
        [Parameter(Mandatory = $true)][string]$ParameterName
    )

    $resolvedPath = [IO.Path]::GetFullPath($HapPath)
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        throw "$ParameterName HAP is missing: $resolvedPath"
    }
    $leaf = Split-Path $resolvedPath -Leaf
    if ([IO.Path]::GetExtension($resolvedPath) -ne '.hap' -or $leaf -match '(?i)unsigned') {
        throw "$ParameterName requires a signed HAP"
    }
    if ($leaf -match '(?i)^LeanTTY-\d+\.\d+\.\d+-arm64-v8a-signed\.hap$') {
        throw (
            "$ParameterName received a production release-Profile HAP, which is identity " +
            'evidence and must not be installed by HDC; use the matching review-test HAP'
        )
    }
    return $resolvedPath
}

function Assert-LeanTTYPowerShellAutomaticVariableSafety {
    param([Parameter(Mandatory = $true)][string[]]$Path)

    $violations = [Collections.Generic.List[string]]::new()
    foreach ($scriptPath in $Path) {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $scriptPath,
            [ref]$tokens,
            [ref]$errors
        )
        if ($errors.Count -gt 0) {
            throw "PowerShell syntax check failed before automatic-variable audit: $scriptPath"
        }

        foreach ($assignment in @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.AssignmentStatementAst]
                }, $true))) {
            foreach ($target in @($assignment.GetAssignmentTargets())) {
                if ($target -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $target.VariablePath.UserPath -ieq 'PID') {
                    $violations.Add(
                        "$scriptPath`:$($target.Extent.StartLineNumber): assignment to automatic variable PID"
                    )
                }
            }
        }

        foreach ($parameter in @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.ParameterAst]
                }, $true))) {
            if ($parameter.Name.VariablePath.UserPath -ieq 'PID') {
                $violations.Add(
                    "$scriptPath`:$($parameter.Extent.StartLineNumber): parameter collides with automatic variable PID"
                )
            }
        }

        foreach ($statement in @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.ForEachStatementAst]
                }, $true))) {
            if ($statement.Variable.VariablePath.UserPath -ieq 'PID') {
                $violations.Add(
                    "$scriptPath`:$($statement.Variable.Extent.StartLineNumber): loop variable collides with automatic variable PID"
                )
            }
        }
    }

    if ($violations.Count -gt 0) {
        throw ('PowerShell automatic-variable collisions found:' + "`n" + ($violations -join "`n"))
    }
}

function Write-LeanTTYAtomicText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )

    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path $resolvedPath -Parent
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temporaryPath = Join-Path $parent ('.tmp-' + [Guid]::NewGuid().ToString('N'))
    $backupPath = Join-Path $parent ('.bak-' + [Guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($temporaryPath, $Content, [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $resolvedPath -PathType Leaf) {
            [IO.File]::Replace($temporaryPath, $resolvedPath, $backupPath, $true)
            Remove-Item -LiteralPath $backupPath -Force
        } else {
            [IO.File]::Move($temporaryPath, $resolvedPath)
        }
    } finally {
        foreach ($cleanupPath in @($temporaryPath, $backupPath)) {
            if (Test-Path -LiteralPath $cleanupPath -PathType Leaf) {
                Remove-Item -LiteralPath $cleanupPath -Force
            }
        }
    }
}

function Write-LeanTTYAtomicJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value,
        [ValidateRange(2, 20)][int]$Depth = 8
    )

    Write-LeanTTYAtomicText -Path $Path -Content (
        ConvertTo-Json -InputObject $Value -Depth $Depth
    )
}

function ConvertTo-LeanTTYPowerShellLiteral {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    return "'" + $Value.Replace("'", "''") + "'"
}

function Get-LeanTTYReleaseVerificationStages {
    function New-Stage {
        param(
            [Parameter(Mandatory = $true)][string]$Name,
            [Parameter(Mandatory = $true)][string]$Script,
            [Parameter(Mandatory = $true)][string]$ResultFile,
            [Parameter(Mandatory = $true)][string]$Kind,
            [int]$PlannedModelRequests = 0
        )

        return [pscustomobject][ordered]@{
            name = $Name
            script = $Script
            resultFile = $ResultFile
            plannedModelRequests = $PlannedModelRequests
            kind = $Kind
        }
    }

    return @(
        New-Stage -Name 'candidate' -Script 'verify-pc.ps1' `
            -ResultFile 'software.json' -Kind 'candidate'
        New-Stage -Name 'harness-qualification' -Script 'qualify-acceptance-harness-pc.ps1' `
            -ResultFile 'harness-qualification.json' -Kind 'harness'
        New-Stage -Name 'key-passphrase' -Script 'verify-key-passphrase-pc.ps1' `
            -ResultFile 'device-key-passphrase.json' -Kind 'key-passphrase'
        New-Stage -Name 'key-comment-restart' -Script 'verify-ssh-auth-pc.ps1' `
            -ResultFile 'device-ssh-auth.json' -Kind 'ssh-auth-key-comment'
        New-Stage -Name 'ecdsa-import-restart' -Script 'verify-ssh-auth-pc.ps1' `
            -ResultFile 'device-ssh-auth.json' -Kind 'ssh-auth-ecdsa'
        New-Stage -Name 'host-identity' -Script 'verify-host-identity-pc.ps1' `
            -ResultFile 'device-host-identity.json' -Kind 'host-identity'
        New-Stage -Name 'host-identity-openssh' -Script 'verify-host-identity-pc.ps1' `
            -ResultFile 'device-host-identity.json' -Kind 'host-identity-openssh'
        New-Stage -Name 'host-identity-default-ecdsa' -Script 'verify-host-identity-pc.ps1' `
            -ResultFile 'device-host-identity.json' -Kind 'host-identity-default-ecdsa'
        New-Stage -Name 'background-bell' -Script 'verify-background-bell-notification-pc.ps1' `
            -ResultFile 'result.json' -Kind 'background-bell'
        New-Stage -Name 'background-bell-suppression' `
            -Script 'verify-background-bell-notification-pc.ps1' `
            -ResultFile 'result.json' -Kind 'background-bell-suppression'
        New-Stage -Name 'background-bell-cold-stale' `
            -Script 'verify-background-bell-notification-pc.ps1' `
            -ResultFile 'result.json' -Kind 'background-bell-cold-stale'
        New-Stage -Name 'background-bell-late-handled' `
            -Script 'verify-background-bell-notification-pc.ps1' `
            -ResultFile 'result.json' -Kind 'background-bell-late-handled'
        New-Stage -Name 'background-bell-late-destroyed' `
            -Script 'verify-background-bell-notification-pc.ps1' `
            -ResultFile 'result.json' -Kind 'background-bell-late-destroyed'
        New-Stage -Name 'background-bell-manual-dismiss' `
            -Script 'verify-background-bell-notification-pc.ps1' `
            -ResultFile 'result.json' -Kind 'background-bell-manual-dismiss'
        New-Stage -Name 'background-bell-permission' `
            -Script 'verify-background-bell-permission-pc.ps1' `
            -ResultFile 'result.json' -Kind 'background-bell-permission'
        New-Stage -Name 'unexpected-recovery-uninstall' `
            -Script 'verify-unexpected-recovery-uninstall-pc.ps1' `
            -ResultFile 'result.json' -Kind 'unexpected-recovery-uninstall'
        New-Stage -Name 'mosh-formal-matrix' -Script 'verify-mosh-matrix-pc.ps1' `
            -ResultFile 'mosh-matrix.json' -Kind 'mosh-matrix'
        New-Stage -Name 'long-task-notification' -Script 'verify-long-task-notification-pc.ps1' `
            -ResultFile 'result.json' -Kind 'long-task' -PlannedModelRequests 1
        New-Stage -Name 'agent-compatibility' -Script 'verify-agent-compatibility-pc.ps1' `
            -ResultFile 'result.json' -Kind 'agent' -PlannedModelRequests 8
        New-Stage -Name 'ssh-physical-matrix' -Script 'verify-ssh-matrix-pc.ps1' `
            -ResultFile 'ssh-matrix.json' -Kind 'ssh-matrix'
    )
}

function Get-LeanTTYReleaseEvidenceMetadata {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$StageName
    )

    $resolvedPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        throw "Release stage '$StageName' did not write its required evidence: $resolvedPath"
    }
    try {
        $evidence = [IO.File]::ReadAllText($resolvedPath, [Text.Encoding]::UTF8) |
            ConvertFrom-Json -Depth 20
    } catch {
        throw "Release stage '$StageName' wrote unreadable JSON evidence: $($_.Exception.Message)"
    }

    $outcome = ''
    if ($evidence.PSObject.Properties.Name -contains 'result' -and
        $evidence.result -is [string]) {
        $outcome = [string]$evidence.result
    } elseif ($evidence.PSObject.Properties.Name -contains 'status' -and
        $evidence.status -is [string]) {
        $outcome = [string]$evidence.status
    }
    $cleanup = 'not-separately-reported'
    if ($evidence.PSObject.Properties.Name -contains 'cleanup') {
        if ($evidence.cleanup -is [string]) {
            $cleanup = if ([string]$evidence.cleanup -match '(?i)^failed') {
                'failed'
            } elseif ([string]$evidence.cleanup -match '(?i)^(pending|not-run)$') {
                'pending'
            } else {
                'passed'
            }
        } elseif ($null -ne $evidence.cleanup -and
            $evidence.cleanup.PSObject.Properties.Name -contains 'result') {
            $cleanup = [string]$evidence.cleanup.result
        } elseif ($null -ne $evidence.cleanup) {
            $booleanChecks = @($evidence.cleanup.PSObject.Properties |
                Where-Object { $_.Value -is [bool] })
            if ($booleanChecks.Count -gt 0) {
                $cleanup = if (@($booleanChecks | Where-Object { -not [bool]$_.Value }).Count -eq 0) {
                    'passed'
                } else { 'failed' }
            }
        }
    }
    $attemptId = if ($evidence.PSObject.Properties.Name -contains 'attemptId') {
        [string]$evidence.attemptId
    } else { '' }
    $previousAttemptId = if ($evidence.PSObject.Properties.Name -contains 'previousAttemptId') {
        [string]$evidence.previousAttemptId
    } else { '' }
    $actualModelRequests = 'unavailable'
    if ($evidence.PSObject.Properties.Name -contains 'actualModelRequests' -and
        $null -ne $evidence.actualModelRequests) {
        $actualModelRequests = [string]$evidence.actualModelRequests
    }

    return [pscustomobject][ordered]@{
        outcome = $outcome
        cleanup = $cleanup
        attemptId = $attemptId
        previousAttemptId = $previousAttemptId
        actualModelRequests = $actualModelRequests
        evidence = $evidence
    }
}

function Get-LeanTTYReleaseEvidenceSummary {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$StageName
    )

    $metadata = Get-LeanTTYReleaseEvidenceMetadata -Path $Path -StageName $StageName
    if ($metadata.outcome -ne 'passed') {
        throw "Release stage '$StageName' did not produce a passing result (got '$($metadata.outcome)')"
    }
    if ($metadata.cleanup -in @('failed', 'pending')) {
        throw "Release stage '$StageName' did not complete cleanup (got '$($metadata.cleanup)')"
    }
    return $metadata
}

function Get-LeanTTYReleaseSshResumeCommand {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$HapPath,
        [Parameter(Mandatory = $true)][string]$EvidenceDirectory,
        [string]$CandidateBasePath = '',
        [ValidateRange(1024, 65535)][int]$FixturePort = 22222,
        [string]$Distribution = ''
    )

    $parts = [Collections.Generic.List[string]]::new()
    $parts.Add('pwsh.exe -NoProfile -ExecutionPolicy Bypass -File')
    $parts.Add((ConvertTo-LeanTTYPowerShellLiteral -Value (
        Join-Path ([IO.Path]::GetFullPath($RepoRoot)) 'tools\verify-ssh-matrix-pc.ps1'
    )))
    $parts.Add('-Target')
    $parts.Add((ConvertTo-LeanTTYPowerShellLiteral -Value $Target))
    $parts.Add('-HapPath')
    $parts.Add((ConvertTo-LeanTTYPowerShellLiteral -Value ([IO.Path]::GetFullPath($HapPath))))
    if (-not [string]::IsNullOrWhiteSpace($CandidateBasePath)) {
        $parts.Add('-CandidateBasePath')
        $parts.Add((ConvertTo-LeanTTYPowerShellLiteral -Value (
            [IO.Path]::GetFullPath($CandidateBasePath)
        )))
    }
    $parts.Add('-FixturePort')
    $parts.Add([string]$FixturePort)
    if (-not [string]::IsNullOrWhiteSpace($Distribution)) {
        $parts.Add('-Distribution')
        $parts.Add((ConvertTo-LeanTTYPowerShellLiteral -Value $Distribution))
    }
    $parts.Add('-EvidenceDirectory')
    $parts.Add((ConvertTo-LeanTTYPowerShellLiteral -Value (
        [IO.Path]::GetFullPath($EvidenceDirectory)
    )))
    $parts.Add('-Resume')
    return $parts -join ' '
}

function Write-LeanTTYReleaseReportArtifacts {
    param(
        [Parameter(Mandatory = $true)][string]$EvidenceDirectory,
        [Parameter(Mandatory = $true)][object]$Report
    )

    $reportPath = Join-Path ([IO.Path]::GetFullPath($EvidenceDirectory)) 'release-report.json'
    $summaryPath = Join-Path ([IO.Path]::GetFullPath($EvidenceDirectory)) 'maintainer-summary.md'
    Write-LeanTTYAtomicJson -Path $reportPath -Value $Report -Depth 20

    $candidateSha = if ($null -ne $Report.candidate) {
        [string]$Report.candidate.sha256
    } else { 'not-created' }
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('# LeanTTY release verification summary')
    $lines.Add('')
    $lines.Add("- Result: **$($Report.result)**")
    $lines.Add("- Complete applicable physical matrix claimed: $($Report.completeApplicablePhysicalMatrixClaimed)")
    $lines.Add(('- Candidate SHA-256: `{0}`' -f $candidateSha))
    $lines.Add(('- Harness commit/tree: `{0}` / `{1}`' -f
            $Report.harness.gitCommit, $Report.harness.gitTree))
    $lines.Add("- Planned model requests: $($Report.modelUsage.plannedRequests)")
    $lines.Add("- Actual model requests: $($Report.modelUsage.actualRequests)")
    $lines.Add("- Automatic model retries: $($Report.modelUsage.automaticRetries)")
    $lines.Add('')
    $lines.Add('| Stage | Result | Attempts | Duration (ms) | Cleanup | Evidence |')
    $lines.Add('| --- | --- | ---: | ---: | --- | --- |')
    foreach ($stage in @($Report.stages)) {
        $lines.Add(
            "| $($stage.name) | $($stage.status) | $($stage.attemptCount) | " +
            "$($stage.durationMs) | $($stage.cleanup) | " +
            ('`{0}` |' -f $stage.resultPath)
        )
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Report.failure)) {
        $lines.Add('')
        $lines.Add("Failure: $($Report.failure)")
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Report.sshResumeCommand)) {
        $lines.Add('')
        $lines.Add('Exact SSH matrix resume command:')
        $lines.Add('')
        $lines.Add('```powershell')
        $lines.Add([string]$Report.sshResumeCommand)
        $lines.Add('```')
    }
    $lines.Add('')
    if ([bool]$Report.completeApplicablePhysicalMatrixClaimed) {
        $lines.Add('This report covers the complete registered 1.6 candidate and physical matrix.')
    } else {
        $lines.Add('This report does not claim the complete applicable 1.6 physical matrix.')
    }
    $lines.Add('Production/review artifacts, signing, publication and AppGallery remain separate.')
    Write-LeanTTYAtomicText -Path $summaryPath -Content (($lines -join "`n") + "`n")

    return [pscustomobject][ordered]@{
        reportPath = $reportPath
        summaryPath = $summaryPath
    }
}
