<#
.SYNOPSIS
  Temporarily inject a deterministic SSH readiness failure and delayed retry.
.DESCRIPTION
  The first SSH environment preparation attempt fails before reading assets.
  The second attempt waits 1500 ms, then follows the complete production path.
  Acceptance-only logs expose attempt boundaries without asset or command data.
  The production source file is restored byte-for-byte after the wrapped action.
#>

. (Join-Path $PSScriptRoot 'acceptance-source.ps1')

function Add-LeanTTYStartupReadinessSource {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $path = Join-Path $RepoRoot 'entry\src\main\ets\model\ssh\SshEnvironment.ets'
    $text = [IO.File]::ReadAllText($path)
    $text = Set-LeanTTYAcceptanceSourceText $text `
        "import { common } from '@kit.AbilityKit'" `
        ("import { common } from '@kit.AbilityKit'`n" +
            "import { ACCEPTANCE_TESTS } from 'BuildProfile'`n" +
            "import { Logger } from '../../common/logger/Logger'")
    $text = Set-LeanTTYAcceptanceSourceText $text `
        "import { SshKeyManager } from './SshKeyManager'" `
        ("import { SshKeyManager } from './SshKeyManager'`n`n" +
            "const startupReadinessLogger: Logger = new Logger('StartupReadinessAcceptance')")
    $text = Set-LeanTTYAcceptanceSourceText $text `
        '  private static readiness: SshEnvironmentReadiness = new SshEnvironmentReadiness()' `
        ("  private static readiness: SshEnvironmentReadiness = new SshEnvironmentReadiness()`n" +
            '  private static acceptancePreparationAttempt: number = 0')
    $text = Set-LeanTTYAcceptanceSourceText $text `
        '    return SshEnvironment.readiness.ensure(async (): Promise<void> => {' `
        ("    return SshEnvironment.readiness.ensure(async (): Promise<void> => {`n" +
            "      if (ACCEPTANCE_TESTS) {`n" +
            "        SshEnvironment.acceptancePreparationAttempt++`n" +
            "        let attempt: number = SshEnvironment.acceptancePreparationAttempt`n" +
            "        startupReadinessLogger.info('ACCEPTANCE_STARTUP_PREP attempt=' + attempt.toString() +`n" +
            "          ' state=started')`n" +
            "        if (attempt === 1) {`n" +
            "          startupReadinessLogger.info('ACCEPTANCE_STARTUP_PREP attempt=1 state=failed')`n" +
            "          throw new Error('Acceptance startup preparation failure')`n" +
            "        }`n" +
            "        if (attempt === 2) {`n" +
            "          await new Promise<void>((resolve: () => void) => {`n" +
            "            setTimeout(resolve, 1500)`n" +
            "          })`n" +
            "        }`n" +
            "      }")
    $text = Set-LeanTTYAcceptanceSourceText $text `
        "      for (let i = 0; i < keyNames.length; i++) {`n        SshKeyManager.protectKeyFile(context, keyNames[i])`n      }" `
        ("      for (let i = 0; i < keyNames.length; i++) {`n" +
            "        SshKeyManager.protectKeyFile(context, keyNames[i])`n" +
            "      }`n" +
            "      if (ACCEPTANCE_TESTS) {`n" +
            "        startupReadinessLogger.info('ACCEPTANCE_STARTUP_PREP attempt=' +`n" +
            "          SshEnvironment.acceptancePreparationAttempt.toString() + ' state=completed')`n" +
            "      }")
    [IO.File]::WriteAllText($path, $text)
    return $path
}

function Invoke-WithLeanTTYStartupReadinessSource {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )

    $path = Join-Path $RepoRoot 'entry\src\main\ets\model\ssh\SshEnvironment.ets'
    $bytes = [IO.File]::ReadAllBytes($path)
    try {
        Add-LeanTTYStartupReadinessSource -RepoRoot $RepoRoot | Out-Null
        & $Action
    } finally {
        Restore-LeanTTYAcceptanceSourceFile -Path $path -Bytes $bytes
    }
}
