import webview from '@ohos.web.webview'
import { BridgeProtocol, BridgeMessage } from './BridgeProtocol'
import { Logger } from '../../common/logger/Logger'

class PendingTerminalWrite {
  data: Uint8Array
  onWritten: ((written: boolean) => void) | null

  constructor(data: Uint8Array, onWritten: ((written: boolean) => void) | null) {
    this.data = data
    this.onWritten = onWritten
  }
}

export class TerminalBridge {
  private webCtrl: webview.WebviewController
  private msgPort: webview.WebMessagePort | null = null
  private onMessageHandler: ((msg: BridgeMessage) => void) | null = null
  private onReadyHandler: (() => void) | null = null
  private onBackpressureHandler: ((paused: boolean) => void) | null = null
  private ready: boolean = false
  private pendingData: PendingTerminalWrite[] = []
  private pendingDataHead: number = 0
  private pendingBytes: number = 0
  private pendingTheme: string = ''
  private pendingFontSize: number = 0
  private pendingLocalization: string = ''
  private inputMasked: boolean = false
  private pendingFit: boolean = false
  private pendingRestoreSnapshot: string = ''
  private pendingSnapshotRequestIds: number[] = []
  private pendingSearchOpen: boolean = false
  private awaitingRestoreComplete: boolean = false
  private sessionResetViewportCompletion: ((completed: boolean) => void) | null = null
  private sessionResetViewportSent: boolean = false
  private readyHandlerNotified: boolean = false
  private inFlightBytes: number = 0
  private inFlightMessages: number = 0
  private inFlightSequences: number[] = []
  private inFlightWrites: PendingTerminalWrite[] = []
  private nextSequence: number = 1
  private receivedBytes: number = 0
  private acknowledgedBytes: number = 0
  private droppedBytes: number = 0
  private backpressured: boolean = false
  private lastPongTime: number = 0
  private logger: Logger = new Logger('TerminalBridge')
  private static readonly HIGH_WATER_BYTES: number = 2 * 1024 * 1024
  private static readonly LOW_WATER_BYTES: number = 512 * 1024
  private static readonly MAX_PENDING_BYTES: number = 8 * 1024 * 1024
  private static readonly MAX_IN_FLIGHT_MESSAGES: number = 8
  private static readonly BINARY_HEADER_BYTES: number = 12
  private static readonly PONG_TIMEOUT_MS: number = 90000

  constructor(webCtrl: webview.WebviewController) {
    this.webCtrl = webCtrl
  }

  init(): void {
    try {
      let ports: webview.WebMessagePort[] = this.webCtrl.createWebMessagePorts()
      let port1: webview.WebMessagePort = ports[0]
      let port2: webview.WebMessagePort = ports[1]
      this.msgPort = port1
      port1.onMessageEvent((msg: string | ArrayBuffer) => {
        if (typeof msg === 'string') {
          this.handleRawMessage(msg)
        }
      })
      this.webCtrl.postMessage('initPort', [port2], '*')
      this.logger.info('Bridge initialized')
    } catch (e) {
      this.logger.error('Bridge init failed: ' + e)
    }
  }

  destroy(): void {
    this.logMetrics('destroy')
    let interruptedWrites: PendingTerminalWrite[] = this.inFlightWrites.concat(
      this.pendingData.slice(this.pendingDataHead))
    let interruptedViewportCompletion: ((completed: boolean) => void) | null =
      this.sessionResetViewportCompletion
    if (this.msgPort !== null) {
      try {
        this.msgPort.close()
      } catch (e) {
        this.logger.warn('Bridge port close failed: ' + e)
      }
    }
    this.msgPort = null
    this.ready = false
    this.onMessageHandler = null
    this.onReadyHandler = null
    this.onBackpressureHandler = null
    this.pendingData = []
    this.pendingDataHead = 0
    this.pendingBytes = 0
    this.pendingTheme = ''
    this.pendingFontSize = 0
    this.pendingLocalization = ''
    this.pendingFit = false
    this.pendingRestoreSnapshot = ''
    this.pendingSnapshotRequestIds = []
    this.pendingSearchOpen = false
    this.awaitingRestoreComplete = false
    this.sessionResetViewportCompletion = null
    this.sessionResetViewportSent = false
    this.readyHandlerNotified = false
    this.inFlightBytes = 0
    this.inFlightMessages = 0
    this.inFlightSequences = []
    this.inFlightWrites = []
    this.backpressured = false
    this.lastPongTime = 0
    for (let i = 0; i < interruptedWrites.length; i++) {
      let handler: ((written: boolean) => void) | null = interruptedWrites[i].onWritten
      if (handler !== null) {
        handler(false)
      }
    }
    if (interruptedViewportCompletion !== null) {
      interruptedViewportCompletion(false)
    }
  }

  ping(): void {
    this.send(BridgeProtocol.ping())
  }

  isAlive(): boolean {
    if (!this.ready) {
      return true
    }
    if (this.lastPongTime === 0) {
      return true
    }
    return Date.now() - this.lastPongTime < TerminalBridge.PONG_TIMEOUT_MS
  }

  setOnMessage(handler: (msg: BridgeMessage) => void): void {
    this.onMessageHandler = handler
  }

  setOnReady(handler: () => void): void {
    this.onReadyHandler = handler
  }

  setOnBackpressure(handler: (paused: boolean) => void): void {
    this.onBackpressureHandler = handler
  }

  write(data: Uint8Array, onWritten: ((written: boolean) => void) | null = null): void {
    this.receivedBytes += data.byteLength
    if (onWritten === null && this.pendingBytes + data.byteLength > TerminalBridge.MAX_PENDING_BYTES) {
      this.droppedBytes += data.byteLength
      this.setBackpressured(true)
      this.logger.error('PERF bridge overflow dropped=' + data.byteLength.toString() +
        ' buffered=' + this.pendingBytes.toString())
      return
    }
    this.queueData(new PendingTerminalWrite(data, onWritten))
    this.updateBackpressure()
    this.pumpPendingData()
  }

  sendTheme(themeJson: string): void {
    if (!this.ready) {
      this.pendingTheme = themeJson
      return
    }
    this.send(BridgeProtocol.theme(themeJson))
  }

  requestFit(): void {
    if (!this.ready) {
      this.pendingFit = true
      return
    }
    this.send(BridgeProtocol.fit())
  }

  focus(): void {
    this.send(BridgeProtocol.focus())
  }

  blur(): void {
    this.pendingSearchOpen = false
    this.send(BridgeProtocol.blur())
  }

  clearSelection(): void {
    this.send(BridgeProtocol.clearSelection())
  }

  setFontSize(fontSize: number): void {
    if (!this.ready) {
      this.pendingFontSize = fontSize
      return
    }
    this.send(BridgeProtocol.fontSize(fontSize))
  }

  setLocalization(localizationJson: string): void {
    if (!this.ready) {
      this.pendingLocalization = localizationJson
      return
    }
    this.send(BridgeProtocol.localization(localizationJson))
  }

  setInputMasked(masked: boolean): void {
    this.inputMasked = masked
    if (this.ready) {
      this.send(BridgeProtocol.inputSecurity(masked))
    }
  }

  handleSecondaryAction(): void {
    if (this.ready) {
      this.send(BridgeProtocol.secondaryAction())
    }
  }

  copyOrInterrupt(): void {
    if (this.ready) {
      this.send(BridgeProtocol.copyOrInterrupt())
    }
  }

  requestCopySelection(): void {
    if (this.ready) {
      this.send(BridgeProtocol.copySelection())
    }
  }

  openSearch(): void {
    this.pendingSearchOpen = true
    this.pumpSearchOpen()
  }

  closeSearch(): void {
    this.pendingSearchOpen = false
    if (this.ready) {
      this.send(BridgeProtocol.searchClose())
    }
  }

  restoreSnapshot(snapshot: string): void {
    if (snapshot.length === 0) {
      return
    }
    if (!this.ready) {
      this.pendingRestoreSnapshot = snapshot
      return
    }
    this.send(BridgeProtocol.restoreSnapshot(snapshot))
  }

  requestSnapshot(requestId: number): void {
    this.pendingSnapshotRequestIds.push(requestId)
    this.pumpSnapshotRequests()
  }

  restoreSessionViewport(onComplete: (completed: boolean) => void): void {
    if (!this.ready || this.sessionResetViewportCompletion !== null) {
      onComplete(false)
      return
    }
    this.sessionResetViewportCompletion = onComplete
    this.sessionResetViewportSent = false
    this.pumpSessionResetViewport()
  }

  private postTerminalPacket(data: Uint8Array): number {
    if (this.msgPort === null) {
      return 0
    }
    let sequence: number = this.nextSequence
    this.nextSequence = this.nextSequence >= 0xFFFFFFFF ? 1 : this.nextSequence + 1
    let packet: Uint8Array = new Uint8Array(TerminalBridge.BINARY_HEADER_BYTES + data.byteLength)
    packet[0] = 0x48
    packet[1] = 0x54
    packet[2] = 0x42
    packet[3] = 0x31
    this.writeUint32(packet, 4, sequence)
    this.writeUint32(packet, 8, data.byteLength)
    packet.set(data, TerminalBridge.BINARY_HEADER_BYTES)
    try {
      this.msgPort.postMessageEvent(packet.buffer)
      return sequence
    } catch (e) {
      this.logger.error('binary output send failed: ' + e)
      return 0
    }
  }

  private send(message: BridgeMessage): boolean {
    if (this.msgPort !== null) {
      try {
        this.msgPort.postMessageEvent(message.serialize())
        return true
      } catch (e) {
        this.logger.error('send failed: ' + e)
      }
    }
    return false
  }

  private writeUint32(target: Uint8Array, offset: number, value: number): void {
    target[offset] = value & 0xFF
    target[offset + 1] = (value >>> 8) & 0xFF
    target[offset + 2] = (value >>> 16) & 0xFF
    target[offset + 3] = (value >>> 24) & 0xFF
  }

  private handleRawMessage(raw: string): void {
    let msg: BridgeMessage | null = BridgeProtocol.parse(raw)
    if (msg === null) {
      this.logger.warn('Ignored malformed bridge message')
      return
    }
    if (msg.direction !== BridgeProtocol.DIRECTION_WEB_TO_NATIVE) {
      this.logger.warn('Ignored bridge message with invalid direction=' + msg.direction)
      return
    }
    if (msg.channel === BridgeProtocol.CHANNEL_CONTROL && msg.kind === BridgeProtocol.KIND_CLIPBOARD_PASTE) {
      this.logger.info('Clipboard paste ' + msg.payload)
      return
    }
    if (msg.channel === BridgeProtocol.CHANNEL_CONTROL && msg.kind === BridgeProtocol.KIND_PERF_RENDER) {
      this.logger.info('PERF render ' + msg.payload)
      this.logMetrics('render')
      return
    }
    if (msg.channel === BridgeProtocol.CHANNEL_CONTROL && msg.kind === BridgeProtocol.KIND_RENDERER_STATE) {
      this.logger.info('PERF renderer ' + msg.payload)
      return
    }
    if (msg.channel === BridgeProtocol.CHANNEL_CONTROL && msg.kind === BridgeProtocol.KIND_WRITE_ACK) {
      let ackParts: string[] = msg.payload.split(',')
      let sequence: number = ackParts.length === 2 ? parseInt(ackParts[0], 10) : 0
      let acknowledged: number = ackParts.length === 2 ? parseInt(ackParts[1], 10) : 0
      if (!isNaN(sequence) && sequence > 0 && !isNaN(acknowledged) && acknowledged > 0) {
        if (this.inFlightSequences.length === 0 || this.inFlightSequences[0] !== sequence) {
          this.logger.warn('Ignored output ACK sequence=' + sequence.toString())
          return
        }
        this.inFlightSequences.shift()
        let completedWrite: PendingTerminalWrite | undefined = this.inFlightWrites.shift()
        this.inFlightBytes = Math.max(0, this.inFlightBytes - acknowledged)
        this.inFlightMessages = Math.max(0, this.inFlightMessages - 1)
        if (completedWrite !== undefined && completedWrite.onWritten !== null) {
          completedWrite.onWritten(true)
        }
        this.pumpPendingData()
        this.pumpSessionResetViewport()
        this.pumpSnapshotRequests()
        this.acknowledgedBytes += acknowledged
        this.updateBackpressure()
      }
      return
    }
    if (msg.channel === BridgeProtocol.CHANNEL_CONTROL && msg.kind === BridgeProtocol.KIND_READY) {
      this.ready = true
      this.lastPongTime = Date.now()
      let pendingCount: number = this.pendingData.length - this.pendingDataHead
      if (this.pendingTheme.length > 0) {
        this.send(BridgeProtocol.theme(this.pendingTheme))
        this.pendingTheme = ''
      }
      if (this.pendingFontSize > 0) {
        this.send(BridgeProtocol.fontSize(this.pendingFontSize))
        this.pendingFontSize = 0
      }
      if (this.pendingLocalization.length > 0) {
        this.send(BridgeProtocol.localization(this.pendingLocalization))
        this.pendingLocalization = ''
      }
      this.send(BridgeProtocol.inputSecurity(this.inputMasked))
      if (this.pendingFit) {
        this.send(BridgeProtocol.fit())
        this.pendingFit = false
      }
      if (this.pendingRestoreSnapshot.length > 0) {
        this.awaitingRestoreComplete = this.send(BridgeProtocol.restoreSnapshot(this.pendingRestoreSnapshot))
        this.pendingRestoreSnapshot = ''
      }
      this.pumpPendingData()
      this.pumpSessionResetViewport()
      this.pumpSnapshotRequests()
      this.pumpSearchOpen()
      this.logger.info('Web terminal ready, flushed ' + pendingCount.toString() + ' pending chunks')
      if (!this.awaitingRestoreComplete) {
        this.notifyReadyHandler()
      }
      return
    }
    if (msg.channel === BridgeProtocol.CHANNEL_CONTROL && msg.kind === BridgeProtocol.KIND_RESTORE_COMPLETE) {
      if (this.awaitingRestoreComplete) {
        this.awaitingRestoreComplete = false
        this.pumpSnapshotRequests()
        this.pumpSearchOpen()
        this.notifyReadyHandler()
      }
      return
    }
    if (msg.channel === BridgeProtocol.CHANNEL_CONTROL &&
      msg.kind === BridgeProtocol.KIND_SESSION_RESET_COMPLETE) {
      let completion: ((completed: boolean) => void) | null = this.sessionResetViewportCompletion
      this.sessionResetViewportCompletion = null
      this.sessionResetViewportSent = false
      if (completion !== null) {
        completion(true)
      }
      return
    }
    if (msg.channel === BridgeProtocol.CHANNEL_CONTROL && msg.kind === BridgeProtocol.KIND_PONG) {
      this.lastPongTime = Date.now()
      return
    }
    if (this.onMessageHandler !== null) {
      this.onMessageHandler(msg)
    }
  }

  private notifyReadyHandler(): void {
    if (this.readyHandlerNotified) {
      return
    }
    this.readyHandlerNotified = true
    if (this.onReadyHandler !== null) {
      this.onReadyHandler()
    }
  }

  private pumpSnapshotRequests(): void {
    if (!this.ready || this.awaitingRestoreComplete ||
      this.pendingDataHead < this.pendingData.length || this.inFlightMessages > 0) {
      return
    }
    for (let i = 0; i < this.pendingSnapshotRequestIds.length; i++) {
      this.send(BridgeProtocol.snapshotRequest(this.pendingSnapshotRequestIds[i]))
    }
    this.pendingSnapshotRequestIds = []
  }

  private pumpSessionResetViewport(): void {
    if (this.sessionResetViewportCompletion === null || this.sessionResetViewportSent || !this.ready ||
      this.awaitingRestoreComplete || this.pendingDataHead < this.pendingData.length || this.inFlightMessages > 0) {
      return
    }
    this.sessionResetViewportSent = this.send(BridgeProtocol.sessionResetViewport())
    if (!this.sessionResetViewportSent) {
      let completion: ((completed: boolean) => void) | null = this.sessionResetViewportCompletion
      this.sessionResetViewportCompletion = null
      if (completion !== null) {
        completion(false)
      }
    }
  }

  private pumpSearchOpen(): void {
    if (!this.pendingSearchOpen || !this.ready || this.awaitingRestoreComplete) {
      return
    }
    if (this.send(BridgeProtocol.searchOpen())) {
      this.pendingSearchOpen = false
    }
  }

  private compactPendingData(): void {
    if (this.pendingDataHead === this.pendingData.length) {
      this.pendingData = []
      this.pendingDataHead = 0
    } else if (this.pendingDataHead >= 128 && this.pendingDataHead * 2 >= this.pendingData.length) {
      this.pendingData = this.pendingData.slice(this.pendingDataHead)
      this.pendingDataHead = 0
    }
  }

  private pumpPendingData(): void {
    if (!this.ready) {
      return
    }
    while (this.pendingDataHead < this.pendingData.length &&
      this.inFlightBytes < TerminalBridge.HIGH_WATER_BYTES &&
      this.inFlightMessages < TerminalBridge.MAX_IN_FLIGHT_MESSAGES) {
      let pendingWrite: PendingTerminalWrite = this.pendingData[this.pendingDataHead]
      let sequence: number = this.postTerminalPacket(pendingWrite.data)
      if (sequence === 0) {
        return
      }
      this.pendingDataHead++
      this.pendingBytes -= pendingWrite.data.byteLength
      this.inFlightBytes += pendingWrite.data.byteLength
      this.inFlightMessages++
      this.inFlightSequences.push(sequence)
      this.inFlightWrites.push(pendingWrite)
    }
    this.compactPendingData()
    this.updateBackpressure()
  }

  private updateBackpressure(): void {
    let buffered: number = this.pendingBytes + this.inFlightBytes
    if (!this.backpressured && buffered >= TerminalBridge.HIGH_WATER_BYTES) {
      this.setBackpressured(true)
    } else if (this.backpressured && buffered <= TerminalBridge.LOW_WATER_BYTES) {
      this.setBackpressured(false)
    }
  }

  private queueData(pendingWrite: PendingTerminalWrite): void {
    this.pendingData.push(pendingWrite)
    this.pendingBytes += pendingWrite.data.byteLength
  }

  private setBackpressured(paused: boolean): void {
    if (this.backpressured === paused) {
      return
    }
    this.backpressured = paused
    this.logMetrics(paused ? 'high-water' : 'low-water')
    if (this.onBackpressureHandler !== null) {
      this.onBackpressureHandler(paused)
    }
  }

  private logMetrics(reason: string): void {
    this.logger.info('PERF bridge reason=' + reason +
      ',received=' + this.receivedBytes.toString() +
      ',queued=' + this.pendingBytes.toString() +
      ',inFlight=' + this.inFlightBytes.toString() +
      ',inFlightMessages=' + this.inFlightMessages.toString() +
      ',acked=' + this.acknowledgedBytes.toString() +
      ',dropped=' + this.droppedBytes.toString())
  }
}
