export class TerminalOutputBuffer {
  private detachedChunks: Uint8Array[] = []
  private detachedBytes: number = 0
  private bridgeBackpressured: boolean = false
  private detachedBackpressured: boolean = false
  private attached: boolean = false
  private snapshot: string = ''
  private snapshotStateSuffix: string = ''
  private sessionPageActive: boolean = false
  private sessionPageBaseSnapshot: string = ''
  private readonly hiddenHighWaterBytes: number

  constructor(hiddenHighWaterBytes: number = 768 * 1024) {
    this.hiddenHighWaterBytes = hiddenHighWaterBytes
  }

  append(data: Uint8Array): void {
    if (this.attached || data.byteLength === 0) {
      return
    }
    this.detachedChunks.push(data)
    this.detachedBytes += data.byteLength
    if (this.detachedBytes >= this.hiddenHighWaterBytes) {
      this.detachedBackpressured = true
    }
  }

  markAttached(): void {
    this.attached = true
    this.detachedBytes = 0
    this.detachedBackpressured = false
  }

  markDetached(): void {
    if (!this.attached) {
      return
    }
    this.attached = false
    this.detachedChunks = []
    this.detachedBytes = 0
    this.detachedBackpressured = false
    this.bridgeBackpressured = false
  }

  setBridgeBackpressured(paused: boolean): void {
    this.bridgeBackpressured = paused
  }

  isOutputPaused(): boolean {
    return this.bridgeBackpressured || this.detachedBackpressured
  }

  isBridgeBackpressured(): boolean {
    return this.bridgeBackpressured
  }

  isDetachedBackpressured(): boolean {
    return this.detachedBackpressured
  }

  takeDetachedChunks(): Uint8Array[] {
    let chunks: Uint8Array[] = this.detachedChunks
    this.detachedChunks = []
    this.detachedBytes = 0
    return chunks
  }

  getDetachedByteCount(): number {
    return this.detachedBytes
  }

  replaceSnapshot(snapshot: string): void {
    this.snapshot = snapshot
    this.snapshotStateSuffix = ''
  }

  beginSessionPage(): boolean {
    if (this.sessionPageActive) {
      return false
    }
    this.sessionPageBaseSnapshot = this.getSnapshot()
    this.sessionPageActive = true
    this.snapshot = ''
    this.snapshotStateSuffix = ''
    return true
  }

  isSessionPageActive(): boolean {
    return this.sessionPageActive
  }

  getSessionPageBaseSnapshot(): string {
    return this.sessionPageBaseSnapshot
  }

  endSessionPage(): string {
    if (!this.sessionPageActive) {
      return this.getSnapshot()
    }
    let originalSnapshot: string = this.sessionPageBaseSnapshot
    this.sessionPageActive = false
    this.sessionPageBaseSnapshot = ''
    this.snapshot = originalSnapshot
    this.snapshotStateSuffix = ''
    this.detachedChunks = []
    this.detachedBytes = 0
    this.detachedBackpressured = false
    return originalSnapshot
  }

  markSessionReset(resetSequence: string): void {
    this.snapshotStateSuffix = resetSequence
  }

  getSnapshot(): string {
    return this.snapshot + this.snapshotStateSuffix
  }

  releaseDisconnectedFlowControl(): void {
    this.bridgeBackpressured = false
    this.detachedBackpressured = false
  }
}
