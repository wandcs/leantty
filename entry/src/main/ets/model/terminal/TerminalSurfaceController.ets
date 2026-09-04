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
  private snapshotCommitFloor: number = 1
  private inputMasked: boolean = false
  private localizationJson: string = ''
  private snapshotCompletions: SnapshotCompletion[] = []
  private pendingSessionOutputAnchorCompletion: (() => void) | null = null
  private moshPageRequested: boolean = false
  private moshPageReady: boolean = false
  private moshPageEnding: boolean = false
  private moshPageCapturePending: boolean = false
  private moshPageReplacePending: boolean = false
  private moshPageGeneration: number = 0
  private pendingMoshOutput: Uint8Array[] = []
  private pendingMoshBytes: number = 0
  private pendingMoshEndLocalOutput: (() => void) | null = null
  private pendingMoshEndCompletion: (() => void) | null = null
  private pendingBridgeReadyCompletion: (() => void) | null = null
  private paneId: string = ''
  private static readonly SNAPSHOT_COMPLETION_TIMEOUT_MS: number = 2000
  private static readonly MOSH_PAGE_HIGH_WATER_BYTES: number = 768 * 1024
  private static readonly SESSION_BOUNDARY_RESET_SEQUENCE: string = '\u001b[?1049l\u001b[?1047l\u001b[?47l\u001b[0m\u001b[?25h\u001b[5 q\u001b[?1l\u001b[?66l\u001b>\u001b[?2004l\u001b[?1004l\u001b[?9l\u001b[?1000l\u001b[?1002l\u001b[?1003l\u001b[?1005l\u001b[?1006l\u001b[?1015l\u001b[?1016l\u001b[4l\u001b[?6l\u001b[?7h\u001b[?45l\u001b[?5l\u001b[?69l\u001b[20l\u001b[r\u001b[?2026l\u001b(B\u001b)B\u001b]104\u0007\u001b]110\u0007\u001b]111\u0007\u001b]112\u0007\u001b[999;1H'

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

  setPaneIdentity(paneId: string): void {
    this.paneId = paneId
  }

  getPaneIdentity(): string {
    return this.paneId
  }

  ownsMoshSessionPage(): boolean {
    return this.moshPageRequested || this.outputBuffer.isSessionPageActive()
  }

  attach(ctrl: webview.WebviewController): void {
    this.detach()
    let recoveredOutput: boolean = false
    let bridge: TerminalBridge = new TerminalBridge(ctrl)
    bridge.setOnMessage((msg: BridgeMessage) => {
      this.handleBridgeMessage(bridge, msg)
    })
    bridge.setOnReady(() => {
      this.pendingBridgeReadyCompletion = () => {
        if (this.onReadyHandler !== null) {
          this.onReadyHandler(recoveredOutput)
        }
      }
      this.resumeMoshPageTransition()
    })
    bridge.setOnBackpressure((paused: boolean) => {
      let previousPaused: boolean = this.isOutputPaused()
      this.outputBuffer.setBridgeBackpressured(paused)
      this.notifyOutputPauseChange(previousPaused)
    })
    this.bridge = bridge
    bridge.setInputMasked(this.inputMasked)
    if (this.localizationJson.length > 0) {
      bridge.setLocalization(this.localizationJson)
    }
    let snapshot: string = this.outputBuffer.getSnapshot()
    if (snapshot.length > 0) {
      bridge.restoreSnapshot(snapshot)
      recoveredOutput = true
    }
    let detachedChunks: Uint8Array[] = this.outputBuffer.takeDetachedChunks()
    recoveredOutput = recoveredOutput || detachedChunks.length > 0
    let previousPaused: boolean = this.isOutputPaused()
    this.outputBuffer.markAttached()
    for (let i = 0; i < detachedChunks.length; i++) {
      bridge.write(detachedChunks[i])
    }
    this.notifyOutputPauseChange(previousPaused)
    bridge.init()
    this.resumeSessionOutputAnchor()
  }

  detach(): void {
    let previousPaused: boolean = this.isOutputPaused()
    this.clearSnapshotCompletions()
    let detachedBridge: TerminalBridge | null = this.bridge
    this.bridge = null
    this.searchOpen = false
    this.searchComposing = false
    this.pendingBridgeReadyCompletion = null
    this.outputBuffer.markDetached()
    if (detachedBridge !== null) {
      detachedBridge.destroy()
    }
    this.notifyOutputPauseChange(previousPaused)
  }

  isAttached(): boolean {
    return this.bridge !== null
  }

  write(data: string): void {
    this.writeBytes(this.textEncoder.encodeInto(data))
  }

  writeBytes(data: Uint8Array): void {
    let previousPaused: boolean = this.isOutputPaused()
    this.outputBuffer.append(data)
    if (this.bridge !== null) {
      this.bridge.write(data)
    }
    this.notifyOutputPauseChange(previousPaused)
  }

  beginMoshSessionPage(): void {
    if (this.moshPageRequested || this.outputBuffer.isSessionPageActive()) {
      return
    }
    this.moshPageRequested = true
    this.moshPageReady = false
    this.moshPageEnding = false
    this.moshPageGeneration++
    this.closeSearch()
    this.logger.info('MOSH_PAGE stage=begin generation=' + this.moshPageGeneration.toString())
    this.resumeMoshPageTransition()
  }

  writeMoshBytes(data: Uint8Array): void {
    if (data.byteLength === 0 || this.moshPageEnding) {
      return
    }
    if (this.moshPageReady && this.outputBuffer.isSessionPageActive()) {
      this.writeBytes(data)
      return
    }
    let previousPaused: boolean = this.isOutputPaused()
    this.pendingMoshOutput.push(data)
    this.pendingMoshBytes += data.byteLength
    this.beginMoshSessionPage()
    this.notifyOutputPauseChange(previousPaused)
  }

  endMoshSessionPage(writeLocalOutput: () => void, onComplete: () => void): void {
    if (this.moshPageEnding) {
      return
    }
    if (!this.moshPageRequested && !this.outputBuffer.isSessionPageActive()) {
      writeLocalOutput()
      onComplete()
      return
    }
    this.moshPageEnding = true
    this.pendingMoshEndLocalOutput = writeLocalOutput
    this.pendingMoshEndCompletion = onComplete
    this.snapshotCommitFloor = this.nextSnapshotRequestId
    this.logger.info('MOSH_PAGE stage=end generation=' + this.moshPageGeneration.toString() +
      ' attached=' + (this.bridge !== null).toString())
    this.resumeMoshPageTransition()
  }

  private resumeMoshPageTransition(): void {
    if (this.moshPageEnding && this.bridge === null) {
      this.completeMoshPageEnd()
      return
    }
    if (!this.moshPageRequested && !this.outputBuffer.isSessionPageActive()) {
      this.notifyBridgeReadyAfterPageTransition()
      return
    }
    if (!this.moshPageReady) {
      this.resumeMoshPageBegin()
      return
    }
    if (this.moshPageEnding) {
      this.restoreOriginalMoshPage()
      return
    }
    this.notifyBridgeReadyAfterPageTransition()
  }

  private resumeMoshPageBegin(): void {
    if (this.bridge === null || this.moshPageCapturePending || this.moshPageReplacePending) {
      return
    }
    let generation: number = this.moshPageGeneration
    if (this.outputBuffer.isSessionPageActive()) {
      this.replaceMoshTerminalPage('', generation, () => {
        this.completeMoshPageBegin(generation)
      })
      return
    }
    this.moshPageCapturePending = true
    this.captureSnapshot((captured: boolean) => {
      this.moshPageCapturePending = false
      if (generation !== this.moshPageGeneration || !this.moshPageRequested) {
        return
      }
      if (!captured) {
        this.resumeMoshPageTransition()
        return
      }
      this.outputBuffer.beginSessionPage()
      this.replaceMoshTerminalPage('', generation, () => {
        this.completeMoshPageBegin(generation)
      })
    })
  }

  private completeMoshPageBegin(generation: number): void {
    if (generation !== this.moshPageGeneration || !this.outputBuffer.isSessionPageActive()) {
      return
    }
    this.moshPageReady = true
    let previousPaused: boolean = this.isOutputPaused()
    let output: Uint8Array[] = this.pendingMoshOutput
    this.pendingMoshOutput = []
    this.pendingMoshBytes = 0
    for (let i = 0; i < output.length; i++) {
      this.writeBytes(output[i])
    }
    this.notifyOutputPauseChange(previousPaused)
    this.logger.info('MOSH_PAGE stage=ready generation=' + generation.toString())
    this.resumeMoshPageTransition()
  }

  private restoreOriginalMoshPage(): void {
    if (this.moshPageReplacePending) {
      return
    }
    let generation: number = this.moshPageGeneration
    let originalSnapshot: string = this.outputBuffer.getSessionPageBaseSnapshot()
    this.replaceMoshTerminalPage(originalSnapshot, generation, () => {
      if (generation !== this.moshPageGeneration) {
        return
      }
      this.completeMoshPageEnd()
    })
  }

  private replaceMoshTerminalPage(snapshot: string, generation: number, onReplaced: () => void): void {
    let sourceBridge: TerminalBridge | null = this.bridge
    if (sourceBridge === null) {
      this.resumeMoshPageTransition()
      return
    }
    this.moshPageReplacePending = true
    let activeBridge: TerminalBridge = sourceBridge
    activeBridge.replaceTerminalPage(snapshot, (replaced: boolean) => {
      this.moshPageReplacePending = false
      if (generation !== this.moshPageGeneration) {
        return
      }
      if (replaced && this.bridge === activeBridge) {
        onReplaced()
        return
      }
      this.resumeMoshPageTransition()
    })
  }

  private completeMoshPageEnd(): void {
    let previousPaused: boolean = this.isOutputPaused()
    this.outputBuffer.endSessionPage()
    this.pendingMoshOutput = []
    this.pendingMoshBytes = 0
    this.moshPageRequested = false
    this.moshPageReady = false
    this.moshPageEnding = false
    this.moshPageCapturePending = false
    this.moshPageReplacePending = false
    let writeLocalOutput: (() => void) | null = this.pendingMoshEndLocalOutput
    let completion: (() => void) | null = this.pendingMoshEndCompletion
    this.pendingMoshEndLocalOutput = null
    this.pendingMoshEndCompletion = null
    if (writeLocalOutput !== null) {
      writeLocalOutput()
    }
    this.notifyOutputPauseChange(previousPaused)
    this.logger.info('MOSH_PAGE stage=restored generation=' + this.moshPageGeneration.toString())
    this.restoreSessionViewport(() => {
      if (completion !== null) {
        completion()
      }
      this.notifyBridgeReadyAfterPageTransition()
    })
  }

  private notifyBridgeReadyAfterPageTransition(): void {
    if (this.moshPageCapturePending || this.moshPageReplacePending || this.moshPageEnding ||
      (this.moshPageRequested && !this.moshPageReady)) {
      return
    }
    let completion: (() => void) | null = this.pendingBridgeReadyCompletion
    this.pendingBridgeReadyCompletion = null
    if (completion !== null) {
      completion()
    }
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
    let previousPaused: boolean = this.isOutputPaused()
    this.outputBuffer.releaseDisconnectedFlowControl()
    this.notifyOutputPauseChange(previousPaused)
  }

  resetSessionState(writeLocalOutput: () => void, onComplete: () => void): void {
    let resetBytes: Uint8Array = this.textEncoder.encodeInto(
      TerminalSurfaceController.SESSION_BOUNDARY_RESET_SEQUENCE)
    this.logger.info('SESSION_RESET stage=surface-start attached=' + (this.bridge !== null).toString())
    this.snapshotCommitFloor = this.nextSnapshotRequestId
    this.outputBuffer.markSessionReset(TerminalSurfaceController.SESSION_BOUNDARY_RESET_SEQUENCE)
    this.writeSessionReset(resetBytes, () => {
      this.logger.info('SESSION_RESET stage=reset-written')
      this.positionSessionOutput(() => {
        this.logger.info('SESSION_RESET stage=output-positioned')
        writeLocalOutput()
        this.restoreSessionViewport(() => {
          this.logger.info('SESSION_RESET stage=viewport-restored')
          onComplete()
        })
      })
    })
  }

  private writeSessionReset(resetBytes: Uint8Array, onReset: () => void): void {
    let sourceBridge: TerminalBridge | null = this.bridge
    if (sourceBridge === null) {
      onReset()
      return
    }
    let activeBridge: TerminalBridge = sourceBridge
    activeBridge.write(resetBytes, (written: boolean) => {
      if (written && this.bridge === activeBridge) {
        onReset()
        return
      }
      this.writeSessionReset(resetBytes, onReset)
    })
  }

  private restoreSessionViewport(onComplete: () => void): void {
    let sourceBridge: TerminalBridge | null = this.bridge
    if (sourceBridge === null) {
      onComplete()
      return
    }
    let activeBridge: TerminalBridge = sourceBridge
    activeBridge.restoreSessionViewport((restored: boolean) => {
      if (restored && this.bridge === activeBridge) {
        onComplete()
        return
      }
      if (this.bridge !== activeBridge) {
        this.restoreSessionViewport(onComplete)
        return
      }
      onComplete()
    })
  }

  private positionSessionOutput(onComplete: () => void): void {
    let sourceBridge: TerminalBridge | null = this.bridge
    if (sourceBridge === null) {
      this.pendingSessionOutputAnchorCompletion = onComplete
      return
    }
    let activeBridge: TerminalBridge = sourceBridge
    activeBridge.positionSessionOutput((positioned: boolean) => {
      if (positioned && this.bridge === activeBridge) {
        onComplete()
        return
      }
      if (this.bridge !== activeBridge) {
        this.positionSessionOutput(onComplete)
        return
      }
      onComplete()
    })
  }

  private resumeSessionOutputAnchor(): void {
    let completion: (() => void) | null = this.pendingSessionOutputAnchorCompletion
    if (completion === null) {
      return
    }
    this.pendingSessionOutputAnchorCompletion = null
    this.positionSessionOutput(completion)
  }

  isOutputPaused(): boolean {
    return this.outputBuffer.isOutputPaused() ||
      this.pendingMoshBytes >= TerminalSurfaceController.MOSH_PAGE_HIGH_WATER_BYTES
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

  setLocalization(localizationJson: string): void {
    this.localizationJson = localizationJson
    if (this.bridge !== null) {
      this.bridge.setLocalization(localizationJson)
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
        if (requestId >= this.snapshotCommitFloor && requestId >= this.lastCommittedSnapshotRequestId) {
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
    let paused: boolean = this.isOutputPaused()
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
