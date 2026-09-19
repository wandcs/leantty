// Injected only into a dedicated diagnostic HAP. Bounded public fixture frames;
// never log terminal bytes, and never generate input from remote output.
class NativeOutputProbe {
  private pending: string = ''
  private caseId: string = ''
  private lines: number = 0
  private width: number = 0
  private actualLines: number = 0
  private actualBytes: number = 0
  private mismatches: number = 0
  private endSequence: number = 0
  private startedAt: number = 0
  private parsedAt: number = 0
  private observerMs: number = 0
  private inputStartedAt: number = 0
  private inputEchoSequence: number = 0
  private inputParsed: boolean = false
  private inputSamples: number = 0
  private inputEchoBytes: number = 0
  private inputInvalid: boolean = false
  private decoder: util.TextDecoder = util.TextDecoder.create('utf-8')

  input(text: string): void {
    if (text !== '?' || this.caseId.length === 0 || this.endSequence > 0) { return }
    if (this.inputStartedAt > 0 || this.inputSamples >= 40) { this.inputInvalid = true; return }
    this.inputStartedAt = Date.now(); this.inputEchoSequence = 0; this.inputParsed = false
  }

  cancelInput(): void {
    if (this.inputStartedAt > 0) { this.inputInvalid = true }
    this.inputStartedAt = 0; this.inputEchoSequence = 0; this.inputParsed = false
  }

  observe(bytes: Uint8Array, sequence: number): void {
    if (this.endSequence > 0) { return }
    let observedAt = Date.now()
    if (this.caseId.length > 0 && observedAt - this.startedAt > 30000) { this.reset(); return }
    if (this.caseId.length === 0 && this.pending.length === 0) {
      let offset = bytes.indexOf(27)
      if (offset < 0) { return }
      bytes = bytes.subarray(offset)
    }
    this.pending += this.decoder.decodeToString(bytes, { stream: true })
    if (this.caseId.length === 0) {
      let begin = /\x1b\]0;LTTY_PERF_BEGIN__:([a-z0-9_]{1,24}):([1-9][0-9]{0,4}):(48|49|[5-9][0-9]|1[0-5][0-9]|160)\x07/.exec(this.pending)
      if (begin === null || Number(begin[2]) > 12000) {
        let prefix = '\u001b]0;LTTY_PERF_BEGIN__:'
        let tail = this.pending.substring(this.pending.lastIndexOf('\u001b'))
        this.pending = tail.length <= 128 && (prefix.startsWith(tail) || tail.startsWith(prefix)) ? tail : ''
        return
      }
      this.caseId = begin[1]; this.lines = Number(begin[2]); this.width = Number(begin[3])
      this.actualLines = 0; this.actualBytes = 0; this.mismatches = 0
      this.startedAt = observedAt; this.parsedAt = 0; this.observerMs = 0
      this.inputSamples = 0; this.inputEchoBytes = 0; this.inputInvalid = false
      this.pending = this.pending.substring(begin.index + begin[0].length)
    }
    // The declared public fixture body has no '?'. Only a real accepted input
    // may account for its one remote echo; unsolicited/duplicate bytes fail.
    let echo = this.pending.indexOf('?')
    while (echo >= 0) {
      if (this.inputStartedAt === 0 || this.inputEchoSequence > 0) { this.mismatches++ }
      else { this.inputEchoSequence = sequence; this.inputEchoBytes++ }
      this.pending = this.pending.substring(0, echo) + this.pending.substring(echo + 1)
      echo = this.pending.indexOf('?')
    }
    let end = '\u001b]0;LTTY_PERF_END__:' + this.caseId + '\u0007'
    while (this.pending.length > 0) {
      if (this.pending.startsWith(end)) {
        this.endSequence = sequence; this.pending = ''; break
      }
      if (end.startsWith(this.pending)) { break }
      let newline = this.pending.indexOf('\n')
      if (newline < 0) { break }
      let line = this.pending.substring(0, newline + 1)
      this.pending = this.pending.substring(newline + 1)
      let prefix = 'LTTY_PERF_' + this.caseId + '_' + this.actualLines.toString().padStart(5, '0') + ' '
      let expected = prefix + 'X'.repeat(Math.max(0, this.width - prefix.length)) + '\r\n'
      this.actualBytes += new util.TextEncoder().encodeInto(line).length
      if (this.actualLines >= this.lines || line !== expected) { this.mismatches++ }
      this.actualLines++
    }
    if (this.pending.length > 4096) {
      this.mismatches++; this.endSequence = sequence; this.pending = ''
    }
    this.observerMs += Date.now() - observedAt
  }

  consumed(sequence: number): void {
    if (sequence === this.inputEchoSequence && sequence > 0) { this.inputParsed = true }
    if (sequence === this.endSequence && sequence > 0) { this.parsedAt = Date.now() }
  }

  presented(sequence: number): void {
    if (this.inputStartedAt > 0 && this.inputParsed && sequence >= this.inputEchoSequence) {
      this.inputSamples++
      nativeOutputLogger.info('NATIVE_INPUT_PROBE case=' + this.caseId + ' sample=' + this.inputSamples +
        ' inputToFrameMs=' + (Date.now() - this.inputStartedAt) + ' duringLoad=' + (this.endSequence === 0) +
        ' valid=' + !this.inputInvalid)
      this.inputStartedAt = 0; this.inputEchoSequence = 0; this.inputParsed = false
    }
    if (this.endSequence === 0 || this.parsedAt === 0 || sequence < this.endSequence) { return }
    let expectedBytes = (this.width + 2) * this.lines
    let ordered = this.mismatches === 0 && this.actualLines === this.lines && this.actualBytes === expectedBytes
    nativeOutputLogger.info('NATIVE_OUTPUT_PROBE case=' + this.caseId + ' expectedBytes=' + expectedBytes +
      ' actualBytes=' + this.actualBytes + ' expectedLines=' + this.lines + ' actualLines=' + this.actualLines +
      ' mismatches=' + this.mismatches + ' contentOrdered=' + ordered + ' parseMs=' + (this.parsedAt - this.startedAt) +
      ' paintMs=' + (Date.now() - this.startedAt) + ' observerMs=' + this.observerMs +
      ' inputSamples=' + this.inputSamples + ' inputEchoBytes=' + this.inputEchoBytes +
      ' inputValid=' + (!this.inputInvalid && this.inputStartedAt === 0))
    this.reset()
  }

  private reset(): void {
    this.pending = ''; this.caseId = ''; this.endSequence = 0; this.parsedAt = 0
    this.inputStartedAt = 0; this.inputEchoSequence = 0; this.inputParsed = false
    this.decoder = util.TextDecoder.create('utf-8')
  }
}
