export class BridgeMessage {
  direction: string
  channel: string
  kind: string
  payload: string

  constructor(direction: string, channel: string, kind: string, payload: string) {
    this.direction = direction
    this.channel = channel
    this.kind = kind
    this.payload = payload
  }

  serialize(): string {
    return BridgeProtocol.VERSION + '|' + this.direction + '|' + this.channel + '|' + this.kind + '|' + this.payload
  }
}

export class BridgeProtocol {
  static readonly VERSION: string = 'H2'
  static readonly DIRECTION_NATIVE_TO_WEB: string = 'N2W'
  static readonly DIRECTION_WEB_TO_NATIVE: string = 'W2N'
  static readonly CHANNEL_DATA: string = 'DATA'
  static readonly CHANNEL_CONTROL: string = 'CONTROL'

  static readonly KIND_TERMINAL: string = 'terminal'
  static readonly KIND_THEME: string = 'theme'
  static readonly KIND_FOCUS: string = 'focus'
  static readonly KIND_BLUR: string = 'blur'
  static readonly KIND_CLEAR_SELECTION: string = 'clearSelection'
  static readonly KIND_PING: string = 'ping'
  static readonly KIND_FIT: string = 'fit'
  static readonly KIND_FONT_SIZE: string = 'fontSize'
  static readonly KIND_LOCALIZATION: string = 'localization'
  static readonly KIND_INPUT_SECURITY: string = 'inputSecurity'
  static readonly KIND_SECONDARY_ACTION: string = 'secondaryAction'
  static readonly KIND_COPY_OR_INTERRUPT: string = 'copyOrInterrupt'
  static readonly KIND_SNAPSHOT_REQUEST: string = 'snapshotRequest'
  static readonly KIND_RESTORE_SNAPSHOT: string = 'restoreSnapshot'
  static readonly KIND_RESTORE_COMPLETE: string = 'restoreComplete'
  static readonly KIND_SESSION_OUTPUT_ANCHOR: string = 'sessionOutputAnchor'
  static readonly KIND_SESSION_OUTPUT_ANCHOR_COMPLETE: string = 'sessionOutputAnchorComplete'
  static readonly KIND_SESSION_RESET_VIEWPORT: string = 'sessionResetViewport'
  static readonly KIND_SESSION_RESET_COMPLETE: string = 'sessionResetComplete'
  static readonly KIND_SEARCH_OPEN: string = 'searchOpen'
  static readonly KIND_SEARCH_CLOSE: string = 'searchClose'
  static readonly KIND_SEARCH_STATE: string = 'searchState'

  static readonly KIND_READY: string = 'ready'
  static readonly KIND_INTERACTIVE_READY: string = 'interactiveReady'
  static readonly KIND_RESIZE: string = 'resize'
  static readonly KIND_BELL_ATTENTION: string = 'bellAttention'
  static readonly KIND_ATTENTION_ACKNOWLEDGED: string = 'attentionAcknowledged'
  static readonly KIND_COPY_SELECTION: string = 'copySelection'
  static readonly KIND_CLIPBOARD_WRITE: string = 'clipboardWrite'
  static readonly KIND_WRITE_ACK: string = 'writeAck'
  static readonly KIND_PONG: string = 'pong'
  static readonly KIND_CLIPBOARD_PASTE: string = 'clipboardPaste'
  static readonly KIND_PERF_RENDER: string = 'perfRender'
  static readonly KIND_RENDERER_STATE: string = 'rendererState'
  static readonly KIND_OPEN_URL: string = 'openUrl'
  static readonly KIND_SNAPSHOT: string = 'snapshot'
  static readonly MAX_URL_PAYLOAD_LENGTH: number = 4096
  static readonly MAX_LOCALIZATION_PAYLOAD_LENGTH: number = 8192
  static readonly MAX_SNAPSHOT_PAYLOAD_LENGTH: number = 4 * 1024 * 1024

  static parse(raw: string): BridgeMessage | null {
    let versionEnd: number = raw.indexOf('|')
    if (versionEnd < 0 || raw.substring(0, versionEnd) !== BridgeProtocol.VERSION) {
      return null
    }
    let directionEnd: number = raw.indexOf('|', versionEnd + 1)
    let channelEnd: number = raw.indexOf('|', directionEnd + 1)
    let kindEnd: number = raw.indexOf('|', channelEnd + 1)
    if (directionEnd < 0 || channelEnd < 0 || kindEnd < 0) {
      return null
    }
    let direction: string = raw.substring(versionEnd + 1, directionEnd)
    let channel: string = raw.substring(directionEnd + 1, channelEnd)
    let kind: string = raw.substring(channelEnd + 1, kindEnd)
    if (!BridgeProtocol.isDirection(direction) || !BridgeProtocol.isChannel(channel) || kind.length === 0 ||
      !BridgeProtocol.isSupportedMessage(direction, channel, kind)) {
      return null
    }
    let payload: string = raw.substring(kindEnd + 1)
    if ((kind === BridgeProtocol.KIND_BELL_ATTENTION ||
      kind === BridgeProtocol.KIND_ATTENTION_ACKNOWLEDGED ||
      kind === BridgeProtocol.KIND_INTERACTIVE_READY) && payload.length > 0) {
      return null
    }
    if (kind === BridgeProtocol.KIND_OPEN_URL &&
      (payload.length === 0 || payload.length > BridgeProtocol.MAX_URL_PAYLOAD_LENGTH)) {
      return null
    }
    if (kind === BridgeProtocol.KIND_LOCALIZATION &&
      (payload.length === 0 || payload.length > BridgeProtocol.MAX_LOCALIZATION_PAYLOAD_LENGTH)) {
      return null
    }
    if (kind === BridgeProtocol.KIND_SNAPSHOT_REQUEST && !BridgeProtocol.isPositiveIntegerPayload(payload)) {
      return null
    }
    if ((kind === BridgeProtocol.KIND_RESTORE_COMPLETE ||
      kind === BridgeProtocol.KIND_SESSION_OUTPUT_ANCHOR ||
      kind === BridgeProtocol.KIND_SESSION_OUTPUT_ANCHOR_COMPLETE ||
      kind === BridgeProtocol.KIND_SESSION_RESET_VIEWPORT ||
      kind === BridgeProtocol.KIND_SESSION_RESET_COMPLETE) && payload.length > 0) {
      return null
    }
    if (kind === BridgeProtocol.KIND_SEARCH_OPEN && payload.length > 0) {
      return null
    }
    if (kind === BridgeProtocol.KIND_SEARCH_CLOSE && payload.length > 0) {
      return null
    }
    if (kind === BridgeProtocol.KIND_SEARCH_STATE && payload !== 'open' &&
      payload !== 'composing' && payload !== 'closed') {
      return null
    }
    if (kind === BridgeProtocol.KIND_INPUT_SECURITY && payload !== 'plain' && payload !== 'masked') {
      return null
    }
    if (kind === BridgeProtocol.KIND_COPY_OR_INTERRUPT && payload.length > 0) {
      return null
    }
    if ((kind === BridgeProtocol.KIND_RESTORE_SNAPSHOT || kind === BridgeProtocol.KIND_SNAPSHOT) &&
      payload.length > BridgeProtocol.MAX_SNAPSHOT_PAYLOAD_LENGTH) {
      return null
    }
    return new BridgeMessage(direction, channel, kind, payload)
  }

  private static nativeData(kind: string, payload: string): BridgeMessage {
    return new BridgeMessage(BridgeProtocol.DIRECTION_NATIVE_TO_WEB, BridgeProtocol.CHANNEL_DATA, kind, payload)
  }

  private static nativeControl(kind: string, payload: string = ''): BridgeMessage {
    return new BridgeMessage(BridgeProtocol.DIRECTION_NATIVE_TO_WEB, BridgeProtocol.CHANNEL_CONTROL, kind, payload)
  }

  private static webControl(kind: string, payload: string = ''): BridgeMessage {
    return new BridgeMessage(BridgeProtocol.DIRECTION_WEB_TO_NATIVE, BridgeProtocol.CHANNEL_CONTROL, kind, payload)
  }

  static write(data: string): BridgeMessage {
    return BridgeProtocol.nativeData(BridgeProtocol.KIND_TERMINAL, data)
  }

  static theme(themeJson: string): BridgeMessage {
    return BridgeProtocol.nativeControl(BridgeProtocol.KIND_THEME, themeJson)
  }

  static ping(): BridgeMessage {
    return BridgeProtocol.nativeControl(BridgeProtocol.KIND_PING)
  }

  static focus(): BridgeMessage {
    return BridgeProtocol.nativeControl(BridgeProtocol.KIND_FOCUS)
  }

  static blur(): BridgeMessage {
    return BridgeProtocol.nativeControl(BridgeProtocol.KIND_BLUR)
  }

  static clearSelection(): BridgeMessage {
    return BridgeProtocol.nativeControl(BridgeProtocol.KIND_CLEAR_SELECTION)
  }

  static fit(): BridgeMessage {
    return BridgeProtocol.nativeControl(BridgeProtocol.KIND_FIT)
  }

  static fontSize(fontSize: number): BridgeMessage {
    return BridgeProtocol.nativeControl(BridgeProtocol.KIND_FONT_SIZE, fontSize.toString())
  }

  static localization(localizationJson: string): BridgeMessage {
    return BridgeProtocol.nativeControl(BridgeProtocol.KIND_LOCALIZATION, localizationJson)
  }

  static inputSecurity(masked: boolean): BridgeMessage {
    return BridgeProtocol.nativeControl(BridgeProtocol.KIND_INPUT_SECURITY, masked ? 'masked' : 'plain')
  }

  static secondaryAction(): BridgeMessage {
    return BridgeProtocol.nativeControl(BridgeProtocol.KIND_SECONDARY_ACTION)
  }

  static copyOrInterrupt(): BridgeMessage {
    return BridgeProtocol.nativeControl(BridgeProtocol.KIND_COPY_OR_INTERRUPT)
  }

  static snapshotRequest(requestId: number): BridgeMessage {
    return BridgeProtocol.nativeControl(BridgeProtocol.KIND_SNAPSHOT_REQUEST, requestId.toString())
  }

  static restoreSnapshot(snapshot: string): BridgeMessage {
    return BridgeProtocol.nativeControl(BridgeProtocol.KIND_RESTORE_SNAPSHOT, snapshot)
  }

  static sessionResetViewport(): BridgeMessage {
    return BridgeProtocol.nativeControl(BridgeProtocol.KIND_SESSION_RESET_VIEWPORT)
  }

  static sessionOutputAnchor(): BridgeMessage {
    return BridgeProtocol.nativeControl(BridgeProtocol.KIND_SESSION_OUTPUT_ANCHOR)
  }

  static searchOpen(): BridgeMessage {
    return BridgeProtocol.nativeControl(BridgeProtocol.KIND_SEARCH_OPEN)
  }

  static searchClose(): BridgeMessage {
    return BridgeProtocol.nativeControl(BridgeProtocol.KIND_SEARCH_CLOSE)
  }

  static copySelection(): BridgeMessage {
    return BridgeProtocol.nativeControl(BridgeProtocol.KIND_COPY_SELECTION)
  }

  static copySelectionResult(text: string): BridgeMessage {
    return BridgeProtocol.webControl(BridgeProtocol.KIND_COPY_SELECTION, text)
  }

  static clipboardWriteResult(text: string): BridgeMessage {
    return BridgeProtocol.webControl(BridgeProtocol.KIND_CLIPBOARD_WRITE, text)
  }

  static parseResizePayload(payload: string): number[] {
    let parts: string[] = payload.split(',')
    if (parts.length !== 2) { return [80, 24] }
    let cols: number = parseInt(parts[0], 10)
    let rows: number = parseInt(parts[1], 10)
    if (isNaN(cols) || isNaN(rows) || cols < 1 || rows < 1) { return [80, 24] }
    return [cols, rows]
  }

  private static isDirection(direction: string): boolean {
    return direction === BridgeProtocol.DIRECTION_NATIVE_TO_WEB ||
      direction === BridgeProtocol.DIRECTION_WEB_TO_NATIVE
  }

  private static isChannel(channel: string): boolean {
    return channel === BridgeProtocol.CHANNEL_DATA || channel === BridgeProtocol.CHANNEL_CONTROL
  }

  private static isPositiveIntegerPayload(payload: string): boolean {
    let value: number = parseInt(payload, 10)
    return !isNaN(value) && value > 0 && value.toString() === payload
  }

  private static isSupportedMessage(direction: string, channel: string, kind: string): boolean {
    if (channel === BridgeProtocol.CHANNEL_DATA) {
      return kind === BridgeProtocol.KIND_TERMINAL
    }
    if (direction === BridgeProtocol.DIRECTION_NATIVE_TO_WEB) {
      return kind === BridgeProtocol.KIND_THEME ||
        kind === BridgeProtocol.KIND_FOCUS ||
        kind === BridgeProtocol.KIND_BLUR ||
        kind === BridgeProtocol.KIND_CLEAR_SELECTION ||
        kind === BridgeProtocol.KIND_PING ||
        kind === BridgeProtocol.KIND_FIT ||
        kind === BridgeProtocol.KIND_FONT_SIZE ||
        kind === BridgeProtocol.KIND_LOCALIZATION ||
        kind === BridgeProtocol.KIND_INPUT_SECURITY ||
        kind === BridgeProtocol.KIND_COPY_SELECTION ||
        kind === BridgeProtocol.KIND_SECONDARY_ACTION ||
        kind === BridgeProtocol.KIND_COPY_OR_INTERRUPT ||
        kind === BridgeProtocol.KIND_SNAPSHOT_REQUEST ||
        kind === BridgeProtocol.KIND_RESTORE_SNAPSHOT ||
        kind === BridgeProtocol.KIND_SESSION_OUTPUT_ANCHOR ||
        kind === BridgeProtocol.KIND_SESSION_RESET_VIEWPORT ||
        kind === BridgeProtocol.KIND_SEARCH_OPEN ||
        kind === BridgeProtocol.KIND_SEARCH_CLOSE
    }
    return kind === BridgeProtocol.KIND_READY ||
      kind === BridgeProtocol.KIND_INTERACTIVE_READY ||
      kind === BridgeProtocol.KIND_RESIZE ||
      kind === BridgeProtocol.KIND_BELL_ATTENTION ||
      kind === BridgeProtocol.KIND_ATTENTION_ACKNOWLEDGED ||
      kind === BridgeProtocol.KIND_COPY_SELECTION ||
      kind === BridgeProtocol.KIND_CLIPBOARD_WRITE ||
      kind === BridgeProtocol.KIND_WRITE_ACK ||
      kind === BridgeProtocol.KIND_PONG ||
      kind === BridgeProtocol.KIND_CLIPBOARD_PASTE ||
      kind === BridgeProtocol.KIND_PERF_RENDER ||
      kind === BridgeProtocol.KIND_RENDERER_STATE ||
      kind === BridgeProtocol.KIND_OPEN_URL ||
      kind === BridgeProtocol.KIND_RESTORE_COMPLETE ||
      kind === BridgeProtocol.KIND_SESSION_OUTPUT_ANCHOR_COMPLETE ||
      kind === BridgeProtocol.KIND_SESSION_RESET_COMPLETE ||
      kind === BridgeProtocol.KIND_SEARCH_STATE ||
      kind === BridgeProtocol.KIND_SNAPSHOT
  }
}
