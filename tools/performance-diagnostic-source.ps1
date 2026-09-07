# Maintainer-only diagnostics, inserted by the debug acceptance build and restored
# in its finally block. Production sources and packages contain none of these probes.
function Add-LeanTTYPerformanceDiagnosticSource {
    param([Parameter(Mandatory = $true)][hashtable]$Text)

    $sessionFields = @'
  private perfInputBuffer: string = ''
  private perfInputInvalid: boolean = false
  private perfPingId: string = ''
  private perfPingStartedMs: number = 0
  private perfOutputTail: string = ''
  private perfOutputDecoder: util.TextDecoder | null = null
'@
    $Text.session = Set-LeanTTYAcceptanceSourceText $Text.session `
        "  private pendingKeypush: boolean = false" `
        ("  private pendingKeypush: boolean = false`n" + $sessionFields)
    $sessionMethods = @'
  private resetPerfObservation(): void {
    this.perfInputBuffer = ''
    this.perfInputInvalid = false
    this.perfPingId = ''
    this.perfPingStartedMs = 0
    this.perfOutputTail = ''
    this.perfOutputDecoder = null
  }

  private observePerfOutput(data: Uint8Array): void {
    if (!ACCEPTANCE_TESTS || this.perfPingId.length === 0) { return }
    if (Date.now() - this.perfPingStartedMs > 30000) {
      this.resetPerfObservation()
      return
    }
    if (this.perfOutputDecoder === null) {
      this.perfOutputDecoder = util.TextDecoder.create('utf-8')
    }
    let combined: string = this.perfOutputTail +
      this.perfOutputDecoder.decodeToString(data, { stream: true })
    if (combined.indexOf(this.perfPingId) >= 0) {
      this.logger.info('PERF ping id=' + this.perfPingId +
        ' rttMs=' + (Date.now() - this.perfPingStartedMs).toString())
      this.resetPerfObservation()
      return
    }
    this.perfOutputTail = combined.length > 128 ? combined.substring(combined.length - 128) : combined
  }

  private observePerfInput(data: string): void {
    if (!ACCEPTANCE_TESTS) { return }
    for (let i = 0; i < data.length; i++) {
      let ch: string = data.charAt(i)
      if (ch === '\r' || ch === '\n') {
        if (!this.perfInputInvalid && /^echo LTTY_PERF_PING_[a-z0-9_]{1,64}$/.test(this.perfInputBuffer)) {
          this.perfPingId = this.perfInputBuffer.substring(5)
          this.perfPingStartedMs = Date.now()
          this.perfOutputTail = ''
          this.perfOutputDecoder = null
        }
        this.perfInputBuffer = ''
        this.perfInputInvalid = false
      } else if (!this.perfInputInvalid) {
        if (ch.charCodeAt(0) < 32 || ch.charCodeAt(0) >= 127 || this.perfInputBuffer.length >= 84) {
          this.perfInputInvalid = true
          this.perfInputBuffer = ''
        } else {
          this.perfInputBuffer += ch
          if (!'echo LTTY_PERF_PING_'.startsWith(this.perfInputBuffer) &&
            !this.perfInputBuffer.startsWith('echo LTTY_PERF_PING_')) {
            this.perfInputInvalid = true
            this.perfInputBuffer = ''
          }
        }
      }
    }
  }

'@
    $Text.session = Set-LeanTTYAcceptanceSourceText $Text.session `
        '  private onSshClose(exitCode: number): void {' `
        ($sessionMethods + '  private onSshClose(exitCode: number): void {')
    $Text.session = Set-LeanTTYAcceptanceSourceText $Text.session '    this.observeKeypushBytes(data)' `
        "    this.observePerfOutput(data)`n    this.observeKeypushBytes(data)"
    $moshOutputAnchor = @'
  private onMoshData(data: Uint8Array): void {
    if (!this.acceptingSessionOutput) {
      return
    }
'@
    $Text.session = Set-LeanTTYAcceptanceSourceText $Text.session $moshOutputAnchor `
        ($moshOutputAnchor + "`n    this.observePerfOutput(data)")
    $Text.session = Set-LeanTTYAcceptanceSourceText $Text.session `
        '        this.sshClient.write(event.data)' `
        ("        this.observePerfInput(event.data)`n        this.sshClient.write(event.data)")
    foreach ($boundary in @('  async disconnect(): Promise<void> {',
            '  onTerminalSurfaceDetached(): void {', '  private onSshClose(exitCode: number): void {')) {
        $Text.session = Set-LeanTTYAcceptanceSourceText $Text.session $boundary `
            ($boundary + "`n    this.resetPerfObservation()")
    }
    $Text.session = Set-LeanTTYAcceptanceSourceText $Text.session '      this.sshEscapeParser.reset()' `
        ("      this.sshEscapeParser.reset()`n      this.resetPerfObservation()")

    $Text.protocol = Set-LeanTTYAcceptanceSourceText $Text.protocol `
        "  static readonly KIND_RENDERER_STATE: string = 'rendererState'" `
        ("  static readonly KIND_PERF_RENDER: string = 'perfRender'`n" +
            "  static readonly KIND_RENDERER_STATE: string = 'rendererState'")
    $Text.protocol = Set-LeanTTYAcceptanceSourceText $Text.protocol `
        '      kind === BridgeProtocol.KIND_RENDERER_STATE ||' `
        ("      kind === BridgeProtocol.KIND_PERF_RENDER ||`n" +
            '      kind === BridgeProtocol.KIND_RENDERER_STATE ||')
    $bridgeProbe = @'
    if (msg.channel === BridgeProtocol.CHANNEL_CONTROL && msg.kind === BridgeProtocol.KIND_PERF_RENDER) {
      this.logger.info('PERF render ' + msg.payload)
      this.logMetrics('render')
      return
    }
'@
    $bridgeAnchor = '    if (msg.channel === BridgeProtocol.CHANNEL_CONTROL && msg.kind === BridgeProtocol.KIND_RENDERER_STATE) {'
    $Text.bridge = Set-LeanTTYAcceptanceSourceText $Text.bridge $bridgeAnchor ($bridgeProbe + "`n" + $bridgeAnchor)

    $webProbe = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'web-terminal/acceptance-performance.js'))
    $Text.terminal = Set-LeanTTYAcceptanceSourceText $Text.terminal '    var defaultTheme = {' `
        ($webProbe + "`n" + '    var defaultTheme = {')
    $Text.terminal = Set-LeanTTYAcceptanceSourceText $Text.terminal '      term.onRender(function() {' `
        ("      term.onRender(function() {`n        reportPerfAfterPaint();")
    $Text.terminal = Set-LeanTTYAcceptanceSourceText $Text.terminal '      var terminalBytes = terminalPacket.bytes;' `
        ("      var terminalBytes = terminalPacket.bytes;`n      var perfPacket = observePerfPacket(terminalBytes);")
    $Text.terminal = Set-LeanTTYAcceptanceSourceText $Text.terminal `
        "        onComplete();`n        reportInteractiveReadyAfterPaint();" `
        ("        onComplete();`n        reportInteractiveReadyAfterPaint();`n        perfPacketParsed(perfPacket);")
}
