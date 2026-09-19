# Transforms the debug acceptance source only; the common acceptance wrapper owns
# file restoration and release builds never inject this probe.
function Add-LeanTTYNativeOutputSourceText {
    param([Parameter(Mandatory)][string]$Text)
    $nativeOutputText = $Text
    $nativeOutputText = Set-LeanTTYAcceptanceSourceText $nativeOutputText "import util from '@ohos.util'" @'
import { Logger as NativeOutputLogger } from '../../common/logger/Logger'
import { ACCEPTANCE_TESTS as NATIVE_OUTPUT_TESTS } from 'BuildProfile'
import util from '@ohos.util'

const nativeOutputLogger: NativeOutputLogger = new NativeOutputLogger('NativeOutputPerformance')
'@
    $nativeOutputTemplate = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'native-terminal/output-probe.ets'))
    $nativeOutputText = Set-LeanTTYAcceptanceSourceText $nativeOutputText 'class NativeCommand {' ($nativeOutputTemplate + "`nclass NativeCommand {")
    $nativeOutputText = Set-LeanTTYAcceptanceSourceText $nativeOutputText '  private handle: TerminalHandle' `
        "  private outputProbe: NativeOutputProbe = new NativeOutputProbe()`n  private handle: TerminalHandle"
    $nativeOutputText = Set-LeanTTYAcceptanceSourceText $nativeOutputText 'this.onInput(text)' `
        'if (NATIVE_OUTPUT_TESTS) { this.outputProbe.input(text) }; this.onInput(text)'
    $nativeOutputText = Set-LeanTTYAcceptanceSourceText $nativeOutputText '  invalidateInput(): void {' `
        "  invalidateInput(): void {`n    if (NATIVE_OUTPUT_TESTS) { this.outputProbe.cancelInput() }"
    $nativeOutputText = Set-LeanTTYAcceptanceSourceText $nativeOutputText '        this.inflight.set(sequence, command)' @'
        this.inflight.set(sequence, command)
        if (NATIVE_OUTPUT_TESTS && command.kind === 'write' && command.owner !== 0) { this.outputProbe.observe(command.bytes, sequence) }
'@
    $nativeOutputText = Set-LeanTTYAcceptanceSourceText $nativeOutputText '        this.inflight.delete(sequence)' @'
        this.inflight.delete(sequence)
        if (NATIVE_OUTPUT_TESTS) { this.outputProbe.consumed(sequence) }
'@
    $nativeOutputText = Set-LeanTTYAcceptanceSourceText $nativeOutputText `
        "    } else if (kind === 'surface-unavailable' && owner === this.displayGeneration) {" @'
      if (NATIVE_OUTPUT_TESTS) { this.outputProbe.presented(sequence) }
    } else if (kind === 'surface-unavailable' && owner === this.displayGeneration) {
'@
    return $nativeOutputText
}
