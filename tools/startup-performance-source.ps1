<#
.SYNOPSIS
  Temporarily inject startup performance markers into a diagnostic build.
.DESCRIPTION
  The injected markers observe T1-T5 without changing the production source
  tree. Every touched file is restored byte-for-byte after the wrapped action,
  including when the build fails.
#>

. (Join-Path $PSScriptRoot 'acceptance-source.ps1')
. (Join-Path $PSScriptRoot 'native-startup-source.ps1')

function Add-LeanTTYStartupPerformanceSource {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $files = [ordered]@{
        entryAbility = Join-Path $RepoRoot 'entry\src\main\ets\entryability\EntryAbility.ets'
        durableState = Join-Path $RepoRoot 'entry\src\main\ets\model\persistence\DurableStateManager.ets'
    }
    $text = @{}
    foreach ($name in $files.Keys) {
        $text[$name] = [IO.File]::ReadAllText($files[$name])
    }

    $text.entryAbility = Set-LeanTTYAcceptanceSourceText $text.entryAbility `
        '  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {' `
        ("  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {`n" +
            "    let startupPerformanceStartedAt: number = Date.now()`n" +
            "    logger.info('STARTUP_PERF phase=T1')")
    $text.entryAbility = Set-LeanTTYAcceptanceSourceText $text.entryAbility `
        '    DurableStateManager.initialize(this.context)' `
        ("    DurableStateManager.initialize(this.context)`n" +
            "    logger.info('STARTUP_PERF segment=durable elapsedMs=' + `n" +
            '      (Date.now() - startupPerformanceStartedAt).toString())')
    $text.entryAbility = Set-LeanTTYAcceptanceSourceText $text.entryAbility `
        ("    AppStorage.setOrCreate('hasActiveSshSession', false)`n" +
            "    AppStorage.setOrCreate('skipNextTerminateConfirmation', false)") `
        ("    AppStorage.setOrCreate('hasActiveSshSession', false)`n" +
            "    AppStorage.setOrCreate('skipNextTerminateConfirmation', false)`n" +
            "    logger.info('STARTUP_PERF segment=on-create-ready elapsedMs=' + `n" +
            '      (Date.now() - startupPerformanceStartedAt).toString())')
    $loadContentAnchor = @'
      logger.info('Succeeded in loading the content.');

      windowStage.getMainWindow((windowError, mainWindow: window.Window) => {
'@
    $loadContentReplacement = @'
      logger.info('Succeeded in loading the content.');
      logger.info('STARTUP_PERF phase=T2')

      windowStage.getMainWindow((windowError, mainWindow: window.Window) => {
'@
    $text.entryAbility = Set-LeanTTYAcceptanceSourceText `
        $text.entryAbility $loadContentAnchor $loadContentReplacement

    $text.durableState = Set-LeanTTYAcceptanceSourceText $text.durableState `
        "import { DurableAssetStore } from './DurableAssetStore'" `
        ("import { DurableAssetStore } from './DurableAssetStore'`n" +
            "import { Logger } from '../../common/logger/Logger'")
    $text.durableState = Set-LeanTTYAcceptanceSourceText $text.durableState `
        "const INITIALIZED_PATH: string = '_meta/initialized'" `
        ("const startupPerformanceLogger: Logger = new Logger('StartupPerformance')`n`n" +
            "const INITIALIZED_PATH: string = '_meta/initialized'")
    $durableInitializeAnchor = @'
  static initialize(context: common.UIAbilityContext): void {
    DurableStateManager.context = context
    DurableStateManager.store = new DurableAssetStore()
    DurableStateManager.legacyMigrationPending = DurableStateManager.requireStore().read(INITIALIZED_PATH) === null
  }
'@
    $durableInitializeReplacement = @'
  static initialize(context: common.UIAbilityContext): void {
    let startedAt: number = Date.now()
    DurableStateManager.context = context
    DurableStateManager.store = new DurableAssetStore()
    DurableStateManager.legacyMigrationPending = DurableStateManager.requireStore().read(INITIALIZED_PATH) === null
    startupPerformanceLogger.info('STARTUP_PERF durable=initialized-read elapsedMs=' +
      (Date.now() - startedAt).toString())
  }
'@
    $text.durableState = Set-LeanTTYAcceptanceSourceText `
        $text.durableState $durableInitializeAnchor $durableInitializeReplacement

    foreach ($name in $files.Keys) {
        [IO.File]::WriteAllText($files[$name], $text[$name])
    }
    return @($files.Values)
}

function Invoke-WithLeanTTYStartupPerformanceSource {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )

    $paths = @(
        Join-Path $RepoRoot 'entry/src/main/ets/model/terminal/NativeTerminalController.ets'
        Join-Path $RepoRoot 'entry\src\main\ets\entryability\EntryAbility.ets'
        Join-Path $RepoRoot 'entry\src\main\ets\model\persistence\DurableStateManager.ets'
    )
    $backups = @{}
    foreach ($path in $paths) {
        $backups[$path] = [IO.File]::ReadAllBytes($path)
    }
    try {
        Add-LeanTTYStartupPerformanceSource -RepoRoot $RepoRoot | Out-Null
        Add-LeanTTYNativeStartupSource -RepoRoot $RepoRoot -Mode cold
        & $Action
    } finally {
        foreach ($path in $paths) {
            Restore-LeanTTYAcceptanceSourceFile -Path $path -Bytes $backups[$path]
        }
    }
}
