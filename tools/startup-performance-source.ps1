<#
.SYNOPSIS
  Temporarily inject startup performance markers into a diagnostic build.
.DESCRIPTION
  The injected markers observe T1-T5 without changing the production source
  tree. Every touched file is restored byte-for-byte after the wrapped action,
  including when the build fails.
#>

. (Join-Path $PSScriptRoot 'acceptance-source.ps1')

function Add-LeanTTYStartupPerformanceSource {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $files = [ordered]@{
        entryAbility = Join-Path $RepoRoot 'entry\src\main\ets\entryability\EntryAbility.ets'
        durableState = Join-Path $RepoRoot 'entry\src\main\ets\model\persistence\DurableStateManager.ets'
        terminalPane = Join-Path $RepoRoot 'entry\src\main\ets\view\components\TerminalPane.ets'
        bridgeProtocol = Join-Path $RepoRoot 'entry\src\main\ets\model\bridge\BridgeProtocol.ets'
        terminalBridge = Join-Path $RepoRoot 'entry\src\main\ets\model\bridge\TerminalBridge.ets'
        terminalHtml = Join-Path $RepoRoot 'entry\src\main\resources\rawfile\terminal.html'
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
            "import { Logger } from '../../common/logger/Logger'`n`n" +
            "const startupPerformanceLogger: Logger = new Logger('StartupPerformance')")
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

    $text.terminalPane = Set-LeanTTYAcceptanceSourceText $text.terminalPane `
        "import { TerminalMode } from '../../common/types/TerminalTypes'" `
        ("import { TerminalMode } from '../../common/types/TerminalTypes'`n" +
            "import { Logger } from '../../common/logger/Logger'`n`n" +
            "const startupPerformanceLogger: Logger = new Logger('StartupPerformance')")
    $text.terminalPane = Set-LeanTTYAcceptanceSourceText $text.terminalPane `
        "        .onPageEnd(() => {`n          this.onWebControllerReady(this.webCtrl)" `
        ("        .onPageEnd(() => {`n" +
            "          startupPerformanceLogger.info('STARTUP_PERF phase=T3')`n" +
            '          this.onWebControllerReady(this.webCtrl)')

    $text.bridgeProtocol = Set-LeanTTYAcceptanceSourceText $text.bridgeProtocol `
        "  static readonly KIND_PERF_RENDER: string = 'perfRender'" `
        ("  static readonly KIND_PERF_RENDER: string = 'perfRender'`n" +
            "  static readonly KIND_STARTUP_PERF: string = 'startupPerf'")
    $text.bridgeProtocol = Set-LeanTTYAcceptanceSourceText $text.bridgeProtocol `
        "    if (kind === BridgeProtocol.KIND_OPEN_URL &&" `
        ("    if (kind === BridgeProtocol.KIND_STARTUP_PERF && payload !== 'T4' && payload !== 'T5') {`n" +
            "      return null`n" +
            "    }`n" +
            '    if (kind === BridgeProtocol.KIND_OPEN_URL &&')
    $text.bridgeProtocol = Set-LeanTTYAcceptanceSourceText $text.bridgeProtocol `
        "      kind === BridgeProtocol.KIND_PERF_RENDER ||" `
        ("      kind === BridgeProtocol.KIND_PERF_RENDER ||`n" +
            '      kind === BridgeProtocol.KIND_STARTUP_PERF ||')

    $terminalBridgeAnchor = @'
    if (msg.channel === BridgeProtocol.CHANNEL_CONTROL && msg.kind === BridgeProtocol.KIND_PERF_RENDER) {
'@
    $terminalBridgeReplacement = @'
    if (msg.channel === BridgeProtocol.CHANNEL_CONTROL && msg.kind === BridgeProtocol.KIND_STARTUP_PERF) {
      this.logger.info('STARTUP_PERF phase=' + msg.payload)
      return
    }
    if (msg.channel === BridgeProtocol.CHANNEL_CONTROL && msg.kind === BridgeProtocol.KIND_PERF_RENDER) {
'@
    $text.terminalBridge = Set-LeanTTYAcceptanceSourceText `
        $text.terminalBridge $terminalBridgeAnchor $terminalBridgeReplacement

    $terminalVariablesAnchor = @'
    var perfPaintFrameScheduled = false;
    var bellAttentionGate = LeanTTYTerminalPolicy.createBellAttentionGate();
'@
    $terminalVariablesReplacement = @'
    var perfPaintFrameScheduled = false;
    var startupPromptPaintScheduled = false;
    var startupPromptPainted = false;
    var startupInputAwaitingEcho = false;
    var startupExpectedInputCode = 0;
    var startupInputPaintScheduled = false;
    var startupInputPainted = false;
    var startupPaintPhase = '';
    var bellAttentionGate = LeanTTYTerminalPolicy.createBellAttentionGate();
'@
    $text.terminalHtml = Set-LeanTTYAcceptanceSourceText `
        $text.terminalHtml $terminalVariablesAnchor $terminalVariablesReplacement

    $sendControlAnchor = @'
    function acknowledgeBellAttention() {
'@
    $sendControlReplacement = @'
    function scheduleStartupPaint(phase) {
      if (!term || startupPaintPhase.length > 0) return;
      startupPaintPhase = phase;
      term.refresh(0, term.rows - 1);
    }

    function reportStartupPaint() {
      if (startupPaintPhase.length === 0) return;
      var phase = startupPaintPhase;
      startupPaintPhase = '';
      if (phase === 'T4') {
        startupPromptPainted = true;
      } else if (phase === 'T5') {
        startupInputPainted = true;
      }
      sendBridgeControl('startupPerf', phase);
    }

    function acknowledgeBellAttention() {
'@
    $text.terminalHtml = Set-LeanTTYAcceptanceSourceText `
        $text.terminalHtml $sendControlAnchor $sendControlReplacement

    $terminalDataAnchor = @'
      term.onData(function(data) {
        if (!restoringSnapshot) {
          sendBridgeData('terminal', data);
        }
      });
'@
    $terminalDataReplacement = @'
      term.onData(function(data) {
        if (!restoringSnapshot) {
          if (data === 'a' && startupPromptPainted && !startupInputPainted && !startupInputPaintScheduled) {
            startupInputAwaitingEcho = true;
            startupExpectedInputCode = 97;
          }
          sendBridgeData('terminal', data);
        }
      });
'@
    $text.terminalHtml = Set-LeanTTYAcceptanceSourceText `
        $text.terminalHtml $terminalDataAnchor $terminalDataReplacement
    $text.terminalHtml = Set-LeanTTYAcceptanceSourceText $text.terminalHtml `
        "      term.onRender(function() {`n        reportPerfAfterPaint();" `
        ("      term.onRender(function() {`n" +
            "        reportStartupPaint();`n" +
            '        reportPerfAfterPaint();')

    $terminalWriteAnchor = @'
      term.write(terminalBytes, function() {
        sendBridgeControl('writeAck',
          terminalPacket.sequence.toString() + ',' + terminalBytes.byteLength.toString());
        onComplete();
        reportInteractiveReadyAfterPaint();
      });
'@
    $terminalWriteReplacement = @'
      term.write(terminalBytes, function() {
        if (!startupPromptPainted && !startupPromptPaintScheduled) {
          startupPromptPaintScheduled = true;
          scheduleStartupPaint('T4');
        } else if (startupInputAwaitingEcho && startupExpectedInputCode > 0 &&
            terminalBytes.indexOf(startupExpectedInputCode) >= 0 &&
            !startupInputPainted && !startupInputPaintScheduled) {
          startupInputAwaitingEcho = false;
          startupInputPaintScheduled = true;
          scheduleStartupPaint('T5');
        }
        sendBridgeControl('writeAck',
          terminalPacket.sequence.toString() + ',' + terminalBytes.byteLength.toString());
        onComplete();
        reportInteractiveReadyAfterPaint();
      });
'@
    $text.terminalHtml = Set-LeanTTYAcceptanceSourceText `
        $text.terminalHtml $terminalWriteAnchor $terminalWriteReplacement

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
        Join-Path $RepoRoot 'entry\src\main\ets\entryability\EntryAbility.ets'
        Join-Path $RepoRoot 'entry\src\main\ets\model\persistence\DurableStateManager.ets'
        Join-Path $RepoRoot 'entry\src\main\ets\view\components\TerminalPane.ets'
        Join-Path $RepoRoot 'entry\src\main\ets\model\bridge\BridgeProtocol.ets'
        Join-Path $RepoRoot 'entry\src\main\ets\model\bridge\TerminalBridge.ets'
        Join-Path $RepoRoot 'entry\src\main\resources\rawfile\terminal.html'
    )
    $backups = @{}
    foreach ($path in $paths) {
        $backups[$path] = [IO.File]::ReadAllBytes($path)
    }
    try {
        Add-LeanTTYStartupPerformanceSource -RepoRoot $RepoRoot | Out-Null
        & $Action
    } finally {
        foreach ($path in $paths) {
            Restore-LeanTTYAcceptanceSourceFile -Path $path -Bytes $backups[$path]
        }
    }
}
