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
