import webview from '@ohos.web.webview'
import { BridgeMessage, BridgeProtocol } from '../bridge/BridgeProtocol'
import { TerminalBridge } from '../bridge/TerminalBridge'
import { ClipboardManager } from '../clipboard/ClipboardManager'
import { Logger } from '../../common/logger/Logger'
import { TerminalOutputBuffer } from './TerminalOutputBuffer'
import util from '@ohos.util'

class SnapshotCompletion {
  requestId: number
  handler: (captured: boolean) => void
  timerId: number

  constructor(requestId: number, handler: (captured: boolean) => void, timerId: number) {
    this.requestId = requestId
    this.handler = handler
    this.timerId = timerId
  }
}

export class TerminalSurfaceController {
  private bridge: TerminalBridge | null = null
  private outputBuffer: TerminalOutputBuffer = new TerminalOutputBuffer()
  private onMessageHandler: ((msg: BridgeMessage) => void) | null = null
  private onReadyHandler: ((flushedDetachedOutput: boolean) => void) | null = null
  private onOutputPauseChangeHandler: ((paused: boolean) => void) | null = null
  private onCopyResultHandler: ((success: boolean) => void) | null = null
  private onBellAttentionHandler: (() => void) | null = null
  private onAttentionAcknowledgedHandler: (() => void) | null = null
  private onOpenUrlHandler: ((url: string) => void) | null = null
  private searchOpen: boolean = false
  private searchComposing: boolean = false
  private logger: Logger = new Logger('TerminalSurfaceController')
  private textEncoder: util.TextEncoder = new util.TextEncoder()
  private nextSnapshotRequestId: number = 1
  private lastCommittedSnapshotRequestId: number = 0
  private inputMasked: boolean = false
  private snapshotCompletions: SnapshotCompletion[] = []
  private static readonly SNAPSHOT_COMPLETION_TIMEOUT_MS: number = 2000

  setOnMessage(handler: (msg: BridgeMessage) => void): void {
    this.onMessageHandler = handler
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

  attach(ctrl: webview.WebviewController): void {
    this.detach()
    let recoveredOutput: boolean = false
    let bridge: TerminalBridge = new TerminalBridge(ctrl)
    bridge.setOnMessage((msg: BridgeMessage) => {
      this.handleBridgeMessage(bridge, msg)
    })
    bridge.setOnReady(() => {
      if (this.onReadyHandler !== null) {
        this.onReadyHandler(recoveredOutput)
      }
    })
    bridge.setOnBackpressure((paused: boolean) => {
      let previousPaused: boolean = this.outputBuffer.isOutputPaused()
      this.outputBuffer.setBridgeBackpressured(paused)
      this.notifyOutputPauseChange(previousPaused)
    })
    this.bridge = bridge
    bridge.setInputMasked(this.inputMasked)
    let snapshot: string = this.outputBuffer.getSnapshot()
    if (snapshot.length > 0) {
      bridge.restoreSnapshot(snapshot)
      recoveredOutput = true
    }
    let detachedChunks: Uint8Array[] = this.outputBuffer.takeDetachedChunks()
    recoveredOutput = recoveredOutput || detachedChunks.length > 0
    let previousPaused: boolean = this.outputBuffer.isOutputPaused()
    this.outputBuffer.markAttached()
    for (let i = 0; i < detachedChunks.length; i++) {
      bridge.write(detachedChunks[i])
    }
    this.notifyOutputPauseChange(previousPaused)
    bridge.init()
  }

  detach(): void {
    let previousPaused: boolean = this.outputBuffer.isOutputPaused()
    this.clearSnapshotCompletions()
    if (this.bridge !== null) {
      this.bridge.destroy()
      this.bridge = null
    }
    this.searchOpen = false
    this.searchComposing = false
    this.outputBuffer.markDetached()
    this.notifyOutputPauseChange(previousPaused)
  }

  isAttached(): boolean {
    return this.bridge !== null
  }

  write(data: string): void {
    this.writeBytes(this.textEncoder.encodeInto(data))
  }

  writeBytes(data: Uint8Array): void {
    let previousPaused: boolean = this.outputBuffer.isOutputPaused()
    this.outputBuffer.append(data)
    if (this.bridge !== null) {
      this.bridge.write(data)
    }
    this.notifyOutputPauseChange(previousPaused)
  }

  sendTheme(themeJson: string): void {
    if (this.bridge !== null) {
      this.bridge.sendTheme(themeJson)
    }
  }

  requestFit(): void {
    if (this.bridge !== null) {
      this.bridge.requestFit()
    }
  }

  releaseDisconnectedFlowControl(): void {
    let previousPaused: boolean = this.outputBuffer.isOutputPaused()
    this.outputBuffer.releaseDisconnectedFlowControl()
    this.notifyOutputPauseChange(previousPaused)
  }

  isOutputPaused(): boolean {
    return this.outputBuffer.isOutputPaused()
  }

  focus(): void {
    if (this.bridge !== null) {
      this.bridge.focus()
    }
  }

  openSearch(): void {
    if (this.bridge !== null) {
      this.searchOpen = true
      this.searchComposing = false
      this.bridge.openSearch()
    }
  }

  isSearchOpen(): boolean {
    return this.searchOpen
  }

  isSearchComposing(): boolean {
    return this.searchComposing
  }

  closeSearch(): void {
    this.searchOpen = false
    this.searchComposing = false
    if (this.bridge !== null) {
      this.bridge.closeSearch()
    }
  }

  blur(): void {
    if (this.bridge !== null) {
      this.bridge.blur()
    }
  }

  clearSelection(): void {
    if (this.bridge !== null) {
      this.bridge.clearSelection()
    }
  }

  setFontSize(fontSize: number): void {
    if (this.bridge !== null) {
      this.bridge.setFontSize(fontSize)
    }
  }

  setInputMasked(masked: boolean): void {
    this.inputMasked = masked
    if (this.bridge !== null) {
      this.bridge.setInputMasked(masked)
    }
  }

  handleSecondaryAction(): void {
    if (this.bridge !== null) {
      this.bridge.handleSecondaryAction()
    }
  }

  copyOrInterrupt(): void {
    if (this.bridge !== null) {
      this.bridge.copyOrInterrupt()
    }
  }

  requestCopySelection(): void {
    if (this.bridge !== null) {
      this.bridge.requestCopySelection()
    }
  }

  ping(): void {
    if (this.bridge !== null) {
      this.bridge.ping()
    }
  }

  captureSnapshot(onCaptured: ((captured: boolean) => void) | null = null): void {
    if (this.bridge === null) {
      if (onCaptured !== null) {
        onCaptured(false)
      }
      return
    }
    let requestId: number = this.nextSnapshotRequestId
    this.nextSnapshotRequestId++
    if (onCaptured !== null) {
      let timerId: number = setTimeout(() => {
        this.logger.warn('Terminal snapshot timed out, requestId=' + requestId.toString())
        this.completeSnapshotRequest(requestId, false)
      }, TerminalSurfaceController.SNAPSHOT_COMPLETION_TIMEOUT_MS)
      this.snapshotCompletions.push(new SnapshotCompletion(requestId, onCaptured, timerId))
    }
    this.bridge.requestSnapshot(requestId)
  }

  private handleBridgeMessage(sourceBridge: TerminalBridge, msg: BridgeMessage): void {
    if (this.bridge === sourceBridge && msg.direction === BridgeProtocol.DIRECTION_WEB_TO_NATIVE &&
      msg.channel === BridgeProtocol.CHANNEL_CONTROL && msg.kind === BridgeProtocol.KIND_SEARCH_STATE) {
      this.searchOpen = msg.payload !== 'closed'
      this.searchComposing = msg.payload === 'composing'
      return
    }
    if (msg.direction === BridgeProtocol.DIRECTION_WEB_TO_NATIVE &&
      msg.channel === BridgeProtocol.CHANNEL_CONTROL && msg.kind === BridgeProtocol.KIND_BELL_ATTENTION) {
      if (this.onBellAttentionHandler !== null) {
        this.onBellAttentionHandler()
      }
      return
    }
    if (msg.direction === BridgeProtocol.DIRECTION_WEB_TO_NATIVE &&
      msg.channel === BridgeProtocol.CHANNEL_CONTROL && msg.kind === BridgeProtocol.KIND_ATTENTION_ACKNOWLEDGED) {
      if (this.onAttentionAcknowledgedHandler !== null) {
        this.onAttentionAcknowledgedHandler()
      }
      return
    }
    if (msg.direction === BridgeProtocol.DIRECTION_WEB_TO_NATIVE &&
      msg.channel === BridgeProtocol.CHANNEL_CONTROL && msg.kind === BridgeProtocol.KIND_COPY_SELECTION) {
      if (msg.payload.length === 0) {
        return
      }
      ClipboardManager.writeText(msg.payload).then((success: boolean) => {
        this.logger.info('Clipboard copy success=' + success.toString() +
          ',length=' + msg.payload.length.toString())
        if (success && this.bridge === sourceBridge) {
          sourceBridge.clearSelection()
        }
        if (this.onCopyResultHandler !== null) {
          this.onCopyResultHandler(success)
        }
      })
      return
    }
    if (msg.direction === BridgeProtocol.DIRECTION_WEB_TO_NATIVE &&
      msg.channel === BridgeProtocol.CHANNEL_CONTROL && msg.kind === BridgeProtocol.KIND_CLIPBOARD_WRITE) {
      ClipboardManager.writeText(msg.payload).then((success: boolean) => {
        this.logger.info('OSC 52 clipboard write success=' + success.toString() +
          ',length=' + msg.payload.length.toString())
        if (this.onCopyResultHandler !== null) {
          this.onCopyResultHandler(success)
        }
      })
      return
    }
    if (msg.direction === BridgeProtocol.DIRECTION_WEB_TO_NATIVE &&
      msg.channel === BridgeProtocol.CHANNEL_CONTROL && msg.kind === BridgeProtocol.KIND_OPEN_URL) {
      if (this.onOpenUrlHandler !== null) {
        this.onOpenUrlHandler(msg.payload)
      }
      return
    }
    if (msg.direction === BridgeProtocol.DIRECTION_WEB_TO_NATIVE &&
      msg.channel === BridgeProtocol.CHANNEL_CONTROL && msg.kind === BridgeProtocol.KIND_SNAPSHOT) {
      let separator: number = msg.payload.indexOf('|')
      let requestIdText: string = separator > 0 ? msg.payload.substring(0, separator) : ''
      let requestId: number = parseInt(requestIdText, 10)
      if (this.bridge === sourceBridge && separator > 0 && !isNaN(requestId) &&
        requestId > 0 && requestId.toString() === requestIdText) {
        if (requestId >= this.lastCommittedSnapshotRequestId) {
          this.outputBuffer.replaceSnapshot(msg.payload.substring(separator + 1))
          this.lastCommittedSnapshotRequestId = requestId
        }
        this.completeSnapshotRequest(requestId, true)
      }
      return
    }
    if (this.onMessageHandler !== null) {
      this.onMessageHandler(msg)
    }
  }

  private completeSnapshotRequest(requestId: number, captured: boolean): void {
    let remaining: SnapshotCompletion[] = []
    let completedHandler: ((captured: boolean) => void) | null = null
    for (let i = 0; i < this.snapshotCompletions.length; i++) {
      let completion: SnapshotCompletion = this.snapshotCompletions[i]
      if (completion.requestId === requestId) {
        clearTimeout(completion.timerId)
        completedHandler = completion.handler
      } else {
        remaining.push(completion)
      }
    }
    this.snapshotCompletions = remaining
    if (completedHandler !== null) {
      completedHandler(captured)
    }
  }

  private clearSnapshotCompletions(): void {
    let handlers: ((captured: boolean) => void)[] = []
    for (let i = 0; i < this.snapshotCompletions.length; i++) {
      clearTimeout(this.snapshotCompletions[i].timerId)
      handlers.push(this.snapshotCompletions[i].handler)
    }
    this.snapshotCompletions = []
    for (let i = 0; i < handlers.length; i++) {
      handlers[i](false)
    }
  }

  private notifyOutputPauseChange(previousPaused: boolean): void {
    let paused: boolean = this.outputBuffer.isOutputPaused()
    if (previousPaused === paused) {
      return
    }
    this.logger.info('PERF output paused=' + paused.toString() +
      ',bridge=' + this.outputBuffer.isBridgeBackpressured().toString() +
      ',hidden=' + this.outputBuffer.isDetachedBackpressured().toString())
    if (this.onOutputPauseChangeHandler !== null) {
      this.onOutputPauseChangeHandler(paused)
    }
  }
}
