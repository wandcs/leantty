# Diagnostic-only markers. Presented.sequence is the worker consumption watermark
# injected by native-display-acceptance-source.ps1 after successful swap.
function Add-LeanTTYNativeStartupSource {
    param([Parameter(Mandatory)][string]$RepoRoot, [ValidateSet('cold', 'warm')][string]$Mode)
    $nativeStartupPath = Join-Path $RepoRoot 'entry/src/main/ets/model/terminal/NativeTerminalController.ets'
    $nativeStartupText = [IO.File]::ReadAllText($nativeStartupPath)
    $nativeStartupText = Set-LeanTTYAcceptanceSourceText $nativeStartupText "import util from '@ohos.util'" @'
import { Logger as NativeStartupLogger } from '../../common/logger/Logger'
import { LocalCommandOutput } from './LocalCommandOutput'
import util from '@ohos.util'

const nativeStartupLogger: NativeStartupLogger = new NativeStartupLogger('NativeStartupPerformance')
'@
    $nativeStartupText = Set-LeanTTYAcceptanceSourceText $nativeStartupText '  private handle: TerminalHandle' @'
  private startupPromptSequence: number = 0
  private startupEchoSequence: number = 0
  private startupPromptPainted: boolean = false
  private startupAwaitingEcho: boolean = false
  private startupInputPainted: boolean = false
  private startupAttached: boolean = false
  private startupWarmArmed: boolean = false
  private handle: TerminalHandle
'@
    $nativeStartupText = Set-LeanTTYAcceptanceSourceText $nativeStartupText '        this.inflight.set(sequence, command)' @'
        this.inflight.set(sequence, command)
        if (command.kind === 'write' && command.owner === 0) {
          let prompt = new util.TextEncoder().encodeInto(LocalCommandOutput.prompt())
          let endsWithPrompt = command.bytes.length >= prompt.length
          for (let i = 0; endsWithPrompt && i < prompt.length; i++) {
            endsWithPrompt = command.bytes[command.bytes.length - prompt.length + i] === prompt[i]
          }
          if (!this.startupPromptPainted && endsWithPrompt) { this.startupPromptSequence = sequence }
          if (this.startupAwaitingEcho && command.bytes.indexOf(97) >= 0) {
            this.startupAwaitingEcho = false; this.startupEchoSequence = sequence
          }
        }
'@
    $nativeStartupText = Set-LeanTTYAcceptanceSourceText $nativeStartupText 'this.acknowledgeAttention(); this.onInput(text)' @'
this.acknowledgeAttention()
        if (text === 'a' && this.startupPromptPainted && !this.startupInputPainted) { this.startupAwaitingEcho = true }
        this.onInput(text)
'@
    $nativeStartupPaint = @'
      if (this.focused) {
        if (!this.startupPromptPainted && STARTUP_READY) {
          this.startupPromptPainted = true
          nativeStartupLogger.info('STARTUP_MARKER phase=T4')
        }
        if (this.startupPromptPainted && !this.startupInputPainted && this.startupEchoSequence > 0 &&
            sequence >= this.startupEchoSequence && !this.inflight.has(this.startupEchoSequence)) {
          this.startupInputPainted = true
          nativeStartupLogger.info('STARTUP_MARKER phase=T5')
        }
      }
'@
    if ($Mode -eq 'cold') {
        $nativeStartupPaint = $nativeStartupPaint.Replace('STARTUP_READY',
            'this.startupPromptSequence > 0 && sequence >= this.startupPromptSequence && !this.inflight.has(this.startupPromptSequence)').Replace('STARTUP_MARKER', 'STARTUP_PERF')
        $nativeStartupText = Set-LeanTTYAcceptanceSourceText $nativeStartupText '    this.context = context; this.surfaceId = id' @'
    if (!this.startupAttached && this.visible && this.focused) {
      this.startupAttached = true; nativeStartupLogger.info('STARTUP_PERF phase=T3')
    }
    this.context = context; this.surfaceId = id
'@
    } else {
        $nativeStartupPaint = $nativeStartupPaint.Replace('STARTUP_READY', 'this.startupWarmArmed').Replace('STARTUP_MARKER', 'PERF render STARTUP_WARM')
        $nativeStartupText = Set-LeanTTYAcceptanceSourceText $nativeStartupText '    this.visible = visible; this.presented = false' @'
    this.startupWarmArmed = visible
    this.startupPromptPainted = false; this.startupInputPainted = false
    this.startupAwaitingEcho = false; this.startupEchoSequence = 0
    this.visible = visible; this.presented = false
'@
    }
    $nativeStartupText = Set-LeanTTYAcceptanceSourceText $nativeStartupText `
        "    } else if (kind === 'surface-unavailable' && owner === this.displayGeneration) {" `
        ($nativeStartupPaint + "`n    } else if (kind === 'surface-unavailable' && owner === this.displayGeneration) {")
    [IO.File]::WriteAllText($nativeStartupPath, $nativeStartupText, [Text.UTF8Encoding]::new($false))
}
