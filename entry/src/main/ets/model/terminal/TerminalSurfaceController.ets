import util from '@ohos.util'
import { NativeCellMetrics, NativeTerminalController } from './NativeTerminalController'

export class TerminalSurfaceController {
  private native: NativeTerminalController | null = null
  private onReplyHandler: ((data: string, owner: number) => void) | null = null
  private acceptsRemoteEffect: (owner: number) => boolean = () => false
  private onFailureHandler: (() => void) | null = null
  private nativeMoshPage: boolean = false
  private onInputHandler: ((data: string) => void) | null = null
  private onResizeHandler: ((cols: number, rows: number) => void) | null = null
  private onInteractiveReadyHandler: (() => void) | null = null
  private onReadyHandler: ((flushedDetachedOutput: boolean) => void) | null = null
  private onOutputPauseChangeHandler: ((paused: boolean) => void) | null = null
  private onCopyResultHandler: ((success: boolean) => void) | null = null
  private onBellAttentionHandler: (() => void) | null = null
  private onAttentionAcknowledgedHandler: (() => void) | null = null
  private onOpenUrlHandler: ((url: string) => void) | null = null
  private searchComposing: boolean = false
  private textEncoder: util.TextEncoder = new util.TextEncoder()
  private inputMasked: boolean = false
  private paneId: string = ''
  private static readonly SESSION_BOUNDARY_RESET_SEQUENCE: string = '\u001b[?1049l\u001b[?1047l\u001b[?47l\u001b[0m\u001b[?25h\u001b[5 q\u001b[?1l\u001b[?66l\u001b>\u001b[?2004l\u001b[?1004l\u001b[?9l\u001b[?1000l\u001b[?1002l\u001b[?1003l\u001b[?1005l\u001b[?1006l\u001b[?1015l\u001b[?1016l\u001b[4l\u001b[?6l\u001b[?7h\u001b[?45l\u001b[?5l\u001b[?69l\u001b[20l\u001b[r\u001b[?2026l\u001b(B\u001b)B\u001b]104\u0007\u001b]110\u0007\u001b]111\u0007\u001b]112\u0007\u001b[999;1H'

  setOnInput(handler: (data: string) => void): void {
    this.onInputHandler = handler
  }

  setOnReply(handler: (data: string, owner: number) => void): void { this.onReplyHandler = handler }

  setRemoteEffectOwner(handler: (owner: number) => boolean): void { this.acceptsRemoteEffect = handler }

  setOnFailure(handler: () => void): void { this.onFailureHandler = handler }

  initializeNative(regular: ArrayBuffer, bold: ArrayBuffer): NativeTerminalController {
    if (this.native !== null) { return this.native }
    let native = new NativeTerminalController(regular, bold)
    this.native = native
    native.setInputMasked(this.inputMasked)
    native.onInput = (data: string) => { if (this.onInputHandler !== null) { this.onInputHandler(data) } }
    native.onReply = (data: string, owner: number) => {
      if (this.onReplyHandler !== null) { this.onReplyHandler(data, owner) }
    }
    native.acceptsRemoteEffect = (owner: number) => this.acceptsRemoteEffect(owner)
    native.onOpenUrl = (url: string) => { if (this.onOpenUrlHandler !== null) { this.onOpenUrlHandler(url) } }
    native.onResize = (cols: number, rows: number) => {
      if (this.onResizeHandler !== null) { this.onResizeHandler(cols, rows) }
    }
    native.onReady = (recovered: boolean) => {
      if (this.onInteractiveReadyHandler !== null) { this.onInteractiveReadyHandler() }
      if (this.onReadyHandler !== null) { this.onReadyHandler(recovered) }
    }
    native.onPressure = (paused: boolean) => {
      if (this.onOutputPauseChangeHandler !== null) { this.onOutputPauseChangeHandler(paused) }
    }
    native.onBell = () => { if (this.onBellAttentionHandler !== null) { this.onBellAttentionHandler() } }
    native.onAttentionAcknowledged = () => {
      if (this.onAttentionAcknowledgedHandler !== null) { this.onAttentionAcknowledgedHandler() }
    }
    native.onCopyResult = (success: boolean) => {
      if (this.onCopyResultHandler !== null) { this.onCopyResultHandler(success) }
    }
    native.onFailure = () => { if (this.onFailureHandler !== null) { this.onFailureHandler() } }
    return native
  }

  invalidateNativeInput(): void {
    if (this.native !== null) { this.native.changeInputOwner() }
  }

  setNativeVisible(visible: boolean): void { this.native?.setVisible(visible) }

  getNativeCellMetrics(fontPixels: number, insetPixels: number): NativeCellMetrics | null {
    return this.native?.getCellMetrics(fontPixels, insetPixels) ?? null
  }

  sendNativeKey(code: number, modifiers: number, text: string): boolean {
    if (this.native === null) { return false }
    return this.native.key(code, modifiers, text)
  }

  setSearchComposing(composing: boolean): void { this.searchComposing = composing }

  async dispose(): Promise<void> {
    if (this.native !== null) { await this.native.dispose() }
  }

  setOnResize(handler: (cols: number, rows: number) => void): void {
    this.onResizeHandler = handler
  }

  setOnInteractiveReady(handler: () => void): void {
    this.onInteractiveReadyHandler = handler
  }

  setOnReady(handler: (flushedDetachedOutput: boolean) => void): void {
    this.onReadyHandler = handler
  }

  setOnOutputPauseChange(handler: (paused: boolean) => void): void {
    this.onOutputPauseChangeHandler = handler
  }

  setOnCopyResult(handler: (success: boolean) => void): void {
    this.onCopyResultHandler = handler
  }

  setOnBellAttention(handler: () => void): void {
    this.onBellAttentionHandler = handler
  }

  setOnAttentionAcknowledged(handler: () => void): void {
    this.onAttentionAcknowledgedHandler = handler
  }

  setOnOpenUrl(handler: (url: string) => void): void {
    this.onOpenUrlHandler = handler
  }

  setPaneIdentity(paneId: string): void {
    this.paneId = paneId
  }

  getPaneIdentity(): string {
    return this.paneId
  }

  write(data: string): void {
    this.writeBytes(this.textEncoder.encodeInto(data))
  }

  isSearchComposing(): boolean {
    return this.searchComposing
  }

  ownsMoshSessionPage(): boolean { return this.nativeMoshPage }

  detach(): void {
    this.searchComposing = false
    this.native?.detach()
  }

  isAttached(): boolean { return this.native?.isAttached() ?? false }

  writeBytes(data: Uint8Array, owner: number = 0): void { this.native?.write(data, owner) }

  beginMoshSessionPage(): void {
    if (this.native !== null && !this.nativeMoshPage) {
      this.nativeMoshPage = true
      this.native.page(true)
    }
  }

  writeMoshBytes(data: Uint8Array, owner: number = 0): void {
    if (data.byteLength === 0) { return }
    // The first frame can precede connected; isolate it before its reset bytes.
    this.beginMoshSessionPage()
    this.native?.write(data, owner)
  }

  endMoshSessionPage(writeLocalOutput: () => void, onComplete: () => void): void {
    if (this.nativeMoshPage) { this.native?.page(false); this.nativeMoshPage = false }
    this.barrier(() => { writeLocalOutput(); this.barrier(onComplete) })
  }

  resetSessionState(writeLocalOutput: () => void, onComplete: () => void): void {
    if (this.native === null) { writeLocalOutput(); onComplete(); return }
    this.native.write(this.textEncoder.encodeInto(TerminalSurfaceController.SESSION_BOUNDARY_RESET_SEQUENCE), 0)
    this.native.positionSessionOutput(() => { writeLocalOutput(); this.barrier(onComplete) })
  }

  // Wait for queued VT work; display detach keeps the Pane-owned terminal alive.
  barrier(onComplete: () => void): void {
    if (this.native === null) { onComplete(); return }
    this.native.barrier(onComplete)
  }

  isOutputPaused(): boolean { return this.native?.isPaused() ?? false }
  focus(): void { this.native?.focus() }
  openSearch(): void { this.native?.openSearch() }
  isSearchOpen(): boolean { return this.native?.isSearching() ?? false }
  closeSearch(): void {
    this.searchComposing = false
    this.native?.closeSearch()
  }
  blur(): void {
    this.native?.closeSearch(false)
    this.searchComposing = false
    this.native?.blur()
  }
  clearSelection(): void { this.native?.copy(3) }
  setFontSize(fontSize: number): void { this.native?.setFontSize(fontSize) }
  setInputMasked(masked: boolean): void {
    this.inputMasked = masked
    this.native?.setInputMasked(masked)
  }
  handleSecondaryAction(): void { this.native?.copy(2) }
  copyOrInterrupt(): void { this.native?.copy(1) }
  requestCopySelection(): void { this.native?.copy() }
}
