import terminal, { TerminalHandle } from 'libleantty_terminal.so'
import { ClipboardManager } from '../clipboard/ClipboardManager'
import { KeyCodeMap } from '../../common/constants/KeyCodeMap'
import util from '@ohos.util'

export class NativeCellMetrics {
  readonly fontPixels: number
  readonly insetPixels: number
  readonly cellWidth: number
  readonly cellHeight: number
  constructor(fontPixels: number, insetPixels: number, cellWidth: number, cellHeight: number) {
    this.fontPixels = fontPixels; this.insetPixels = insetPixels
    this.cellWidth = cellWidth; this.cellHeight = cellHeight
  }
}

class NativeCommand {
  kind: string
  bytes: Uint8Array
  owner: number
  completion: (() => void) | null
  constructor(kind: string, bytes: Uint8Array, owner: number, completion: (() => void) | null = null) {
    this.kind = kind
    this.bytes = bytes
    this.owner = owner
    this.completion = completion
  }
}

// The Pane owns this object across XComponent lifetimes. Admission, consumption,
// surface presentation and input ownership are deliberately separate signals.
export class NativeTerminalController {
  private handle: TerminalHandle
  private pending: NativeCommand[] = []
  private inflight: Map<number, NativeCommand> = new Map()
  private outstandingBytes: number = 0
  private paused: boolean = false
  private failed: boolean = false
  private closing: boolean = false
  private presented: boolean = false
  private attached: boolean = false
  private visible: boolean = true
  private firstReady: boolean = true
  private focused: boolean = false
  private imeAttached: boolean = false
  private focusConfirmed: boolean = false
  private inputMasked: boolean = false
  private inputOwner: number = 1
  private displayGeneration: number = 0
  private context: UIContext | null = null
  private surfaceId: string = ''
  private width: number = 0
  private height: number = 0
  private fontPixels: number = 28
  private fontSize: number = 14
  private insetPixels: number = 0
  private cellMetrics: NativeCellMetrics | null = null
  private watchdog: number = -1
  private lastProgress: number = Date.now()
  private cursorX: number = 0
  private cursorY: number = 0
  private cursorHeight: number = 28
  private visibleRows: number = 24
  private originX: number = 0
  private originY: number = 0
  private searchGeneration: number = 0
  private searching: boolean = false
  private attentionPending: boolean = false
  private lastSurfaceRecovery: number = 0
  private displayUnavailable: boolean = false
  onInput: (data: string) => void = () => {}
  onReply: (data: string, owner: number) => void = () => {}
  onResize: (cols: number, rows: number) => void = () => {}
  onReady: (recovered: boolean) => void = () => {}
  onPressure: (paused: boolean) => void = () => {}
  onBell: () => void = () => {}
  onFailure: () => void = () => {}
  onDisplayState: (available: boolean) => void = () => {}
  onRebuildDisplay: () => void = () => {}
  onRequestFocus: () => boolean = () => true
  onCopyResult: (success: boolean) => void = () => {}
  onAttentionAcknowledged: () => void = () => {}
  onSearchOpen: (open: boolean) => void = () => {}
  onSearchResult: (index: number, count: number) => void = () => {}
  onSearchError: (resource: string) => void = () => {}
  onGeometry: () => void = () => {}
  acceptsRemoteEffect: (owner: number) => boolean = () => false
  onOpenUrl: (url: string) => void = () => {}
  onLinkHover: (url: string) => void = () => {}
  private hoverSequence: number = 0
  onPreedit: (text: string, x: number, y: number) => void = () => {}

  constructor(regular: ArrayBuffer, bold: ArrayBuffer) {
    this.handle = terminal.create(regular, bold, (kind: string, sequence: number, owner: number, text: string) => {
      this.event(kind, sequence, owner, text)
    })
  }

  write(bytes: Uint8Array, owner: number): void {
    if (this.failed || this.closing || bytes.byteLength === 0) { return }
    if (bytes.byteLength + this.outstandingBytes > 2 * 1024 * 1024 ||
      this.pending.length + this.inflight.size + Math.ceil(bytes.byteLength / (256 * 1024)) > 1024) {
      this.fail(); return
    }
    for (let offset = 0; offset < bytes.byteLength; offset += 256 * 1024) {
      this.pending.push(new NativeCommand('write', bytes.slice(offset, offset + 256 * 1024), owner))
    }
    this.outstandingBytes += bytes.byteLength
    this.pump()
  }

  barrier(completion: () => void): void {
    this.control('barrier', completion)
  }

  positionSessionOutput(completion: () => void): void {
    this.control('position', completion)
  }

  page(begin: boolean, completion: (() => void) | null = null): void {
    this.closeSearch()
    this.control(begin ? 'begin' : 'end', completion)
  }

  private control(kind: string, completion: (() => void) | null): void {
    if (this.failed || this.closing) { return }
    if (this.pending.length + this.inflight.size >= 1024) { this.fail(); return }
    this.pending.push(new NativeCommand(kind, new Uint8Array(0), 0, completion))
    this.pump()
  }

  private pump(): void {
    try {
      while (!this.failed && !this.closing && this.pending.length > 0) {
        let command = this.pending[0]
        let sequence = command.kind === 'write' ? terminal.write(this.handle, command.bytes.buffer, command.owner) :
          command.kind === 'barrier' ? terminal.barrier(this.handle, 0) :
          command.kind === 'position' ? terminal.positionSessionOutput(this.handle) :
          terminal.page(this.handle, command.kind === 'begin', 0)
        if (sequence === 0) { break }
        this.pending.shift()
        this.inflight.set(sequence, command)
      }
      this.pressure()
      if (this.watchdog < 0 && (this.pending.length > 0 || this.inflight.size > 0)) {
        this.lastProgress = Date.now()
        this.watchdog = setInterval(() => {
          // A failed/full callback channel must not leave SSH paused forever.
          if (Date.now() - this.lastProgress > 10000) { this.fail() }
        }, 1000)
      }
    } catch (_) { this.fail() }
  }

  private pressure(): void {
    let commands = this.pending.length + this.inflight.size
    let paused = this.failed || (this.paused ? this.outstandingBytes > 256 * 1024 || commands > 128 :
      this.outstandingBytes >= 512 * 1024 || commands >= 512)
    if (paused !== this.paused) { this.paused = paused; this.onPressure(paused) }
  }

  isPaused(): boolean { return this.paused }
  isAttached(): boolean { return this.attached }

  getCellMetrics(fontPixels: number, insetPixels: number): NativeCellMetrics | null {
    let metrics = this.cellMetrics
    return !this.failed && !this.closing && this.attached && this.visible && !this.displayUnavailable &&
      metrics !== null && metrics.fontPixels === fontPixels && metrics.insetPixels === insetPixels ? metrics : null
  }

  private event(kind: string, sequence: number, owner: number, text: string): void {
    if (this.failed || this.closing) { return }
    if (kind === 'consumed') {
      let command = this.inflight.get(sequence)
      if (command !== undefined) {
        this.inflight.delete(sequence)
        this.outstandingBytes -= command.bytes.byteLength
        this.lastProgress = Date.now()
        if (command.completion !== null) { command.completion() }
      }
      this.pump()
      if (this.pending.length === 0 && this.inflight.size === 0 && this.watchdog >= 0) {
        clearInterval(this.watchdog); this.watchdog = -1
      }
    } else if (kind === 'input') {
      if (owner === this.inputOwner && this.focused && this.presented) { this.acknowledgeAttention(); this.onInput(text) }
    } else if (kind === 'preedit' && owner === this.inputOwner && this.focused && this.presented && !this.inputMasked) {
      this.onPreedit(text, this.cursorX, this.cursorY)
    } else if (kind === 'reply') {
      if (owner !== 0) { this.onReply(text, owner) }
    } else if (kind === 'metrics' && this.attached && owner === this.displayGeneration) {
      let values = text.split(',').map((value: string): number => Number(value))
      if (values.length === 4 && values.every((value: number): boolean => Number.isInteger(value) && value > 0) &&
        values[0] === this.fontPixels && values[1] === this.insetPixels) {
        this.cellMetrics = new NativeCellMetrics(values[0], values[1], values[2], values[3])
      }
    } else if (kind === 'resize') {
      let size = text.split(',')
      this.visibleRows = Number(size[1])
      this.onResize(Number(size[0]), Number(size[1]))
    } else if (kind === 'bell') {
      if ((owner === 0 || this.acceptsRemoteEffect(owner)) && !this.attentionPending) { this.attentionPending = true; this.onBell() }
    } else if (kind === 'clipboard' && this.acceptsRemoteEffect(owner)) {
      ClipboardManager.writeText(text).then((success: boolean) => {
        if (!this.closing && !this.failed && this.acceptsRemoteEffect(owner)) { this.onCopyResult(success) }
      })
    } else if (kind === 'link' && owner === this.inputOwner && this.focused && this.presented) {
      this.onOpenUrl(text)
    } else if (kind === 'link-hover' && owner === this.inputOwner && sequence >= this.hoverSequence &&
      this.focused && this.presented && !this.searching) {
      this.onLinkHover(text)
    } else if (kind === 'copy' && owner === this.inputOwner && this.focused && this.presented) {
      this.writeSelection(text, owner, sequence)
    } else if (kind === 'copy-too-large' && owner === this.inputOwner) {
      this.onCopyResult(false)
    } else if (kind === 'paste-request' && owner === this.inputOwner && this.focused && this.presented) {
      this.paste()
    } else if (kind === 'search' && this.searching && owner === this.searchGeneration) {
      let result = text.split(','); this.onSearchResult(Number(result[0]), Number(result[1]))
    } else if (kind === 'search-close' && this.searching && owner === this.searchGeneration) {
      this.closeSearch()
    } else if (kind === 'cursor' && this.attached && owner === this.displayGeneration) {
      let rect = text.split(',')
      this.cursorX = Number(rect[0]); this.cursorY = Number(rect[1]); this.cursorHeight = Number(rect[2])
      this.onGeometry(); this.updateCursor()
    } else if (kind === 'presented' && this.attached && this.visible && owner === this.displayGeneration) {
      if (!this.presented) {
        this.presented = true; this.displayUnavailable = false; this.onDisplayState(true)
        this.onReady(!this.firstReady); this.firstReady = false
        if (this.focused) { this.focus() }
      }
    } else if (kind === 'surface-unavailable' && owner === this.displayGeneration) {
      this.recoverDisplay()
    } else if (kind === 'failure' || kind === 'closed') { this.fail() }
  }

  attach(id: string, width: number, height: number, context: UIContext): void {
    if (this.failed || this.closing || width < 1 || height < 1) { return }
    if (!this.attached || id !== this.surfaceId) {
      this.displayGeneration++; this.presented = false; this.invalidateInput()
      this.cellMetrics = null
    }
    this.context = context; this.surfaceId = id
    this.fontPixels = Math.max(8, Math.min(96, Math.round(context.vp2px(this.fontSize))))
    this.insetPixels = Math.round(context.vp2px(8))
    if (this.cellMetrics?.fontPixels !== this.fontPixels || this.cellMetrics?.insetPixels !== this.insetPixels) {
      this.cellMetrics = null
    }
    this.width = Math.round(width); this.height = Math.round(height); this.attached = true
    try {
      if (terminal.attach(this.handle, id, this.width, this.height, this.fontPixels, this.displayGeneration,
        this.insetPixels, Math.max(1, Math.round(context.vp2px(1)))) === 0) { this.fail() }
    } catch (_) { this.fail() }
  }

  setFontSize(size: number): void {
    this.fontSize = size
    if (this.attached && this.context !== null) {
      this.attach(this.surfaceId, this.width, this.height, this.context)
    }
  }

  setVisible(visible: boolean): void {
    if (this.failed || this.closing || this.visible === visible) { return }
    this.visible = visible; this.presented = false
    if (!visible) { this.closeSearch(false); this.blur() }
    else {
      this.displayGeneration++; this.invalidateInput()
      // Revalidate an existing Surface before resuming. A failure callback from
      // the preceding generation may still be queued on the UI thread.
      if (this.attached && this.context !== null) {
        this.attach(this.surfaceId, this.width, this.height, this.context)
      }
    }
    try { this.admitted(terminal.visibility(this.handle, visible, this.displayGeneration)) }
    catch (_) { this.fail() }
    if (visible && this.displayUnavailable) { this.recoverDisplay() }
  }

  detach(surfaceId: string = ''): void {
    // A destroyed callback may arrive after the replacement has attached.
    if (surfaceId.length > 0 && surfaceId !== this.surfaceId) { return }
    if (this.searching) { this.search(''); this.searching = false; this.onSearchOpen(false) }
    this.displayGeneration++
    this.cellMetrics = null
    this.focusConfirmed = false
    this.attached = false; this.presented = false; this.invalidateInput(); this.context = null
    if (!this.failed && !this.closing) {
      try { if (terminal.detach(this.handle) === 0) { this.fail() } } catch (_) { this.fail() }
    }
  }

  recoverDisplay(): void {
    if (this.failed || this.closing || !this.attached) { return }
    this.displayUnavailable = true
    this.presented = false; this.closeSearch(false); this.invalidateInput(); this.onDisplayState(false)
    if (!this.visible) { return }
    // Reuse the Pane's normal Surface lifecycle; VT and protocol ownership stay
    // intact. Repeated driver failures must not create an endless remount loop.
    let now = Date.now()
    if (now - this.lastSurfaceRecovery < 30000) { return }
    this.lastSurfaceRecovery = now
    this.onRebuildDisplay()
  }

  canRetryDisplay(): boolean {
    return this.visible && this.displayUnavailable && this.attached && !this.failed && !this.closing
  }

  retryDisplay(): void {
    if (!this.canRetryDisplay()) { return }
    // Explicit user intent gets one attempt even inside the automatic cooldown.
    // Clear admission until the new Surface either presents or reports failure.
    this.displayUnavailable = false; this.onDisplayState(false)
    this.focused = true
    this.lastSurfaceRecovery = Date.now()
    this.onRebuildDisplay()
  }

  focus(): void {
    this.focused = true
    if (!this.presented) { return }
    this.focusConfirmed = this.onRequestFocus()
    if (this.focusConfirmed) { this.attachInput() }
  }
  focusedBySurface(): void {
    this.focused = true; this.focusConfirmed = true; this.attachInput()
    try { this.admitted(terminal.focus(this.handle, true)) } catch (_) { this.fail() }
  }
  blur(): void {
    this.focused = false; this.focusConfirmed = false; this.invalidateInput()
    if (!this.failed && !this.closing) {
      try { this.admitted(terminal.focus(this.handle, false)) } catch (_) { this.fail() }
    }
  }
  setInputMasked(masked: boolean): void { this.inputMasked = masked }
  invalidateInput(): void {
    this.hover(-1)
    this.onPreedit('', 0, 0)
    this.inputOwner++
    this.imeAttached = false
    if (!this.closing) { try { terminal.blur(this.handle) } catch (_) { this.fail() } }
  }
  changeInputOwner(): void { this.closeSearch(); this.invalidateInput(); this.attachInput() }
  private attachInput(): void {
    if (this.imeAttached || this.searching || !this.focused || !this.focusConfirmed || !this.presented || this.failed || this.closing || this.context === null) { return }
    this.onGeometry()
    try { terminal.ime(this.handle, this.context, this.inputOwner, Math.round(this.originX + this.cursorX),
      Math.round(this.originY + this.cursorY), this.cursorHeight, this.inputMasked); this.imeAttached = true }
    catch (_) { this.fail() }
  }

  key(code: number, modifiers: number, text: string = ''): boolean {
    if (this.failed || !this.focused || !this.presented) { return true }
    this.acknowledgeAttention()
    const unshifted = KeyCodeMap.toPrintable(code, false)
    try { if (terminal.key(this.handle, code, modifiers, this.inputOwner, text,
      unshifted.length > 0 ? unshifted.charCodeAt(0) : 0) === 0) { this.fail() } }
    catch (_) { this.fail() }
    return true
  }

  setScreenOrigin(x: number, y: number): void {
    this.originX = x; this.originY = y; this.updateCursor()
  }
  private updateCursor(): void {
    if (!this.imeAttached || this.failed || this.closing) { return }
    try { terminal.cursor(this.handle, this.inputOwner, Math.round(this.originX + this.cursorX),
      Math.round(this.originY + this.cursorY), this.cursorHeight) } catch (_) { this.fail() }
  }
  private acknowledgeAttention(): void {
    if (this.attentionPending) { this.attentionPending = false; this.onAttentionAcknowledged() }
  }
  private admitted(sequence: number): void { if (sequence === 0) { this.fail() } }
  pointer(action: number, button: number, x: number, y: number, modifiers: number): void {
    if (this.failed || this.closing || !this.presented) { return }
    if (this.searching) { if (action !== 0) { return }; this.closeSearch() }
    if (action === 0) { this.focus(); this.acknowledgeAttention() }
    try { this.admitted(terminal.pointer(this.handle, action, button, Math.round(x), Math.round(y), modifiers, this.inputOwner)) }
    catch (_) { this.fail() }
  }
  hover(modifiers: number): void {
    if (modifiers < 0) { this.onLinkHover('') }
    if (this.failed || this.closing || !this.presented || (modifiers >= 0 && this.searching)) { return }
    try { this.hoverSequence = terminal.hover(this.handle, modifiers, this.inputOwner); this.admitted(this.hoverSequence) }
    catch (_) { this.fail() }
  }
  scroll(lines: number, local: boolean = false): void {
    if (this.failed || this.closing || !this.presented) { return }
    try { this.admitted(terminal.scroll(this.handle, Math.max(-256, Math.min(256, lines)), this.inputOwner, local)) }
    catch (_) { this.fail() }
  }
  scrollPage(direction: number): void { this.scroll(direction * Math.max(1, this.visibleRows - 1), true) }
  getFontSize(): number { return this.fontSize }
  copy(action: number = 0): void {
    if (this.failed || this.closing || !this.presented || this.searching) { return }
    this.acknowledgeAttention()
    try { this.admitted(terminal.copy(this.handle, action, this.inputOwner, 0)) } catch (_) { this.fail() }
  }
  private async writeSelection(text: string, owner: number, revision: number): Promise<void> {
    let success = await ClipboardManager.writeText(text)
    if (this.failed || this.closing || owner !== this.inputOwner) { return }
    if (success) {
      try { this.admitted(terminal.copy(this.handle, 3, owner, revision)) } catch (_) { this.fail() }
    }
    this.onCopyResult(success)
  }
  async paste(): Promise<void> {
    if (this.failed || this.closing || !this.focused || !this.presented || this.searching) { return }
    let owner = this.inputOwner
    let text = await ClipboardManager.readText()
    if (this.failed || this.closing || !this.focused || !this.presented || owner !== this.inputOwner || text.length === 0) { return }
    if (new util.TextEncoder().encodeInto(text).byteLength > 1024 * 1024) { this.onCopyResult(false); return }
    this.acknowledgeAttention()
    try { this.admitted(terminal.paste(this.handle, text, owner)) } catch (_) { this.fail() }
  }
  openSearch(): void {
    if (this.failed || this.closing) { return }
    let alreadyOpen = this.searching
    this.searching = true; this.invalidateInput(); this.onSearchOpen(true)
    if (!alreadyOpen) { this.search('') }
  }
  search(needle: string, direction: number = 0): void {
    if (!this.searching || this.failed || this.closing) { return }
    this.searchGeneration++
    const tooLarge = needle.length > 1024 * 1024 ||
      (needle.length > 0 && new util.TextEncoder().encodeInto(needle).byteLength > 1024 * 1024)
    if (tooLarge) { this.onSearchResult(0, 0) }
    this.onSearchError(tooLarge ? 'search_query_too_large' : '')
    try {
      let accepted = terminal.search(this.handle, tooLarge ? '' : needle, direction, this.searchGeneration)
      if (accepted === 0 && !tooLarge && needle.length > 0) {
        // Output may occupy the shared byte budget. Search can be retried;
        // clear the previous query through the existing control reservation.
        this.onSearchError('search_busy')
        this.onSearchResult(0, 0)
        accepted = terminal.search(this.handle, '', 0, this.searchGeneration)
      }
      this.admitted(accepted)
    } catch (_) { this.fail() }
  }
  isSearching(): boolean { return this.searching }
  closeSearch(restoreFocus: boolean = true): void {
    if (!this.searching) { return }
    this.search(''); this.searching = false; this.onSearchOpen(false)
    if (restoreFocus) { this.focus() }
  }

  private fail(): void {
    if (this.failed || this.closing) { return }
    this.failed = true; this.presented = false
    this.invalidateInput()
    if (this.watchdog >= 0) { clearInterval(this.watchdog); this.watchdog = -1 }
    this.pending = []; this.inflight.clear(); this.outstandingBytes = 0
    this.pressure(); this.onDisplayState(false); this.onFailure()
  }

  async dispose(): Promise<void> {
    if (this.closing) { return }
    this.closing = true
    if (this.watchdog >= 0) { clearInterval(this.watchdog); this.watchdog = -1 }
    this.pending = []; this.inflight.clear()
    await terminal.close(this.handle)
  }
}
