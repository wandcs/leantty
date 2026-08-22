import { SshErrorCode, SshError, SshConnectOptions } from '../../common/types/SshTypes'
import { Logger } from '../../common/logger/Logger'
import sshNative from 'libleantty_ssh.so'
import type {
  AuthEvent as NativeAuthEvent,
  AuthPromptEvent as NativeAuthPromptEvent,
  ControlEvent as NativeControlEvent,
  TransportEvent as NativeTransportEvent
} from 'libleantty_ssh.so'
import {
  HostKeyChangedInfo,
  SshControlEventPolicy
} from './SshControlEventPolicy'

export { SshErrorCode, SshError, SshConnectOptions } from '../../common/types/SshTypes'
export { HostKeyChangedInfo } from './SshControlEventPolicy'

export enum SshClientEvent {
  PASSWORD_PROMPT = 'PASSWORD_PROMPT',
  PRIVATE_KEY_PASSPHRASE_PROMPT = 'PRIVATE_KEY_PASSPHRASE_PROMPT',
  AUTH_BANNER = 'AUTH_BANNER',
  AUTH_CHALLENGE = 'AUTH_CHALLENGE',
  HOST_KEY_PROMPT = 'HOST_KEY_PROMPT',
  HOST_KEY_CHANGED = 'HOST_KEY_CHANGED',
  CONNECTED = 'CONNECTED',
  CLOSE = 'CLOSE',
  ERROR = 'ERROR',
  WARNING = 'WARNING',
  DIAGNOSTIC = 'DIAGNOSTIC'
}

export class AuthPromptInfo {
  text: string = ''
  echo: boolean = false
}

export class AuthChallengeInfo {
  roundId: number = 0
  name: string = ''
  instructions: string = ''
  prompts: AuthPromptInfo[] = []
}

export class SshDiagnosticInfo {
  layer: string = ''
  stage: string = ''
  status: string = ''
  reason: string = ''
}

export class SshClientMessage {
  kind: SshClientEvent = SshClientEvent.ERROR
  text: string = ''
  exitCode: number = -1
  error: SshError | null = null
  hostKeyChanged: HostKeyChangedInfo | null = null
  diagnostic: SshDiagnosticInfo | null = null

  static simple(kind: SshClientEvent): SshClientMessage {
    let message: SshClientMessage = new SshClientMessage()
    message.kind = kind
    return message
  }

  static withText(kind: SshClientEvent, text: string): SshClientMessage {
    let message: SshClientMessage = SshClientMessage.simple(kind)
    message.text = text
    return message
  }

  static withError(error: SshError): SshClientMessage {
    let message: SshClientMessage = SshClientMessage.simple(SshClientEvent.ERROR)
    message.error = error
    return message
  }

  static withHostKeyChanged(info: HostKeyChangedInfo): SshClientMessage {
    let message: SshClientMessage = SshClientMessage.simple(SshClientEvent.HOST_KEY_CHANGED)
    message.hostKeyChanged = info
    return message
  }

  static withDiagnostic(info: SshDiagnosticInfo): SshClientMessage {
    let message: SshClientMessage = SshClientMessage.simple(SshClientEvent.DIAGNOSTIC)
    message.diagnostic = info
    return message
  }

  static close(exitCode: number): SshClientMessage {
    let message: SshClientMessage = SshClientMessage.simple(SshClientEvent.CLOSE)
    message.exitCode = exitCode
    return message
  }
}

export class SshClient {
  private static nextGeneration: number = 1
  private sessionId: string = ''
  private generation: number = 0
  private connected: boolean = false
  private verbose: boolean = false
  private waitingAuth: boolean = false
  private pendingLayer: string = ''
  private pendingKnownHostLine: string = ''
  private privateKeyPath: string = ''
  private jumpPrivateKeyPath: string = ''
  private pendingAuthChallenge: AuthChallengeInfo | null = null
  private eventCallback: ((message: SshClientMessage) => void) | null = null
  private dataCallback: ((data: Uint8Array) => void) | null = null
  private logger: Logger = new Logger('SshClient')

  static isCurrentAuthEvent(
    expectedSessionId: string,
    expectedGeneration: number,
    eventSessionId: string,
    eventGeneration: number
  ): boolean {
    return expectedSessionId.length > 0 && eventSessionId === expectedSessionId &&
      eventGeneration === expectedGeneration
  }

  async connect(options: SshConnectOptions): Promise<void> {
    if (this.sessionId.length > 0) {
      this.reportError(new SshError(SshErrorCode.SessionClosed, 'Session already active', '', 'client'))
      return
    }

    try {
      this.generation = SshClient.nextGeneration
      SshClient.nextGeneration++
      if (SshClient.nextGeneration > 4294967295) {
        SshClient.nextGeneration = 1
      }
      this.privateKeyPath = options.privateKeyPath
      this.jumpPrivateKeyPath = options.jumpPrivateKeyPath
      this.verbose = options.verbose
      let id: string = sshNative.sshConnect(
        options.host,
        options.port,
        options.username,
        options.privateKeyPath,
        options.privateKeyRequiresPassphrase,
        options.jumpHost,
        options.jumpPort,
        options.jumpUsername,
        options.jumpPrivateKeyPath,
        options.jumpPrivateKeyRequiresPassphrase,
        options.jumpConnectTimeoutMs,
        options.jumpServerAliveIntervalSeconds,
        options.jumpServerAliveCountMax,
        options.knownHostsPath,
        options.connectTimeoutMs,
        options.serverAliveIntervalSeconds,
        options.serverAliveCountMax,
        options.verbose,
        this.generation,
        (event: NativeTransportEvent) => {
          this.handleNativeTransportEvent(event)
        },
        (event: NativeControlEvent) => {
          this.handleNativeControlEvent(event)
        },
        (event: NativeAuthEvent) => {
          this.handleNativeAuthEvent(event)
        }
      )
      this.sessionId = id
      this.logger.info('SSH connect initiated, sessionId=' + id)
    } catch (e) {
      this.verbose = false
      this.logger.error('sshConnect N-API failed')
      throw new Error('SSH connect failed: ' + e)
    }
  }

  authPassword(password: string): boolean {
    if (!this.waitingAuth || this.sessionId.length === 0 || this.pendingLayer.length === 0) {
      this.reportError(new SshError(SshErrorCode.SessionClosed, 'Not waiting for password', '', 'client'))
      return false
    }
    try {
      sshNative.sshAuthPassword(this.sessionId, this.generation, this.pendingLayer, password)
      this.waitingAuth = false
      this.pendingLayer = ''
      this.logger.info('Auth password sent')
      return true
    } catch (e) {
      this.logger.error('sshAuthPassword failed')
      this.reportError(new SshError(SshErrorCode.Internal, 'Password authentication request failed', '' + e, 'client'))
      return false
    }
  }

  authPrivateKeyPassphrase(passphrase: string): boolean {
    if (!this.waitingAuth || this.sessionId.length === 0 || this.pendingLayer.length === 0) {
      this.reportError(new SshError(SshErrorCode.SessionClosed, 'Not waiting for a key passphrase', '', 'client'))
      return false
    }
    try {
      sshNative.sshAuthPrivateKeyPassphrase(
        this.sessionId, this.generation, this.pendingLayer, passphrase
      )
      this.waitingAuth = false
      this.pendingLayer = ''
      this.logger.info('Private-key passphrase sent')
      return true
    } catch (e) {
      this.logger.error('sshAuthPrivateKeyPassphrase failed')
      this.reportError(new SshError(SshErrorCode.Internal, 'Private-key passphrase request failed', '' + e, 'client'))
      return false
    }
  }

  authKeyboardInteractiveResponses(roundId: number, responses: string[]): boolean {
    if (!this.waitingAuth || this.sessionId.length === 0 || this.pendingLayer.length === 0) {
      this.reportError(new SshError(SshErrorCode.SessionClosed, 'Not waiting for authentication responses', '', 'client'))
      return false
    }
    try {
      sshNative.sshAuthKeyboardInteractiveResponses(
        this.sessionId, this.generation, this.pendingLayer, roundId, responses
      )
      this.waitingAuth = false
      this.pendingLayer = ''
      this.pendingAuthChallenge = null
      this.logger.info('Keyboard-interactive responses sent, roundId=' + roundId.toString())
      return true
    } catch (e) {
      this.logger.error('sshAuthKeyboardInteractiveResponses failed')
      this.reportError(new SshError(SshErrorCode.Internal, 'Authentication response request failed', '' + e, 'client'))
      return false
    }
  }

  takePendingAuthChallenge(): AuthChallengeInfo | null {
    let challenge: AuthChallengeInfo | null = this.pendingAuthChallenge
    this.pendingAuthChallenge = null
    return challenge
  }

  verifyHostKey(accepted: boolean): boolean {
    if (this.sessionId.length === 0 || this.pendingLayer.length === 0) {
      this.reportError(new SshError(SshErrorCode.SessionClosed, 'Session not active', '', 'client'))
      return false
    }
    try {
      sshNative.sshVerifyHostKey(this.sessionId, this.generation, this.pendingLayer, accepted)
      this.pendingKnownHostLine = ''
      this.pendingLayer = ''
      return true
    } catch (e) {
      this.reportError(new SshError(SshErrorCode.HostKey, 'Host key response failed', '' + e, 'client'))
      return false
    }
  }

  getPendingKnownHostLine(): string {
    return this.pendingKnownHostLine
  }

  write(data: string): void {
    if (!this.connected || this.sessionId.length === 0) {
      this.reportError(new SshError(SshErrorCode.SessionClosed, 'Session not active', '', 'client'))
      return
    }
    try {
      sshNative.sshWrite(this.sessionId, data)
    } catch (e) {
      this.logger.error('sshWrite failed')
      this.handleWarning('Write request rejected: ' + e)
    }
  }

  resize(cols: number, rows: number): void {
    if (!this.connected || this.sessionId.length === 0) {
      return
    }
    try {
      sshNative.sshResize(this.sessionId, cols, rows)
    } catch (e) {
      this.logger.error('sshResize failed')
      this.handleWarning('Resize request rejected: ' + e)
    }
  }

  setOutputPaused(paused: boolean): void {
    if (!this.connected || this.sessionId.length === 0) {
      return
    }
    try {
      sshNative.sshSetOutputPaused(this.sessionId, paused)
    } catch (e) {
      this.logger.error('sshSetOutputPaused failed')
      this.handleWarning('Output flow-control request rejected: ' + e)
    }
  }

  async disconnect(): Promise<void> {
    if (this.sessionId.length === 0) {
      return
    }
    try {
      this.emitDiagnostic('target', 'session', 'cancelled')
      sshNative.sshDisconnect(this.sessionId)
    } catch (e) {
      this.logger.error('sshDisconnect failed')
    }
    this.connected = false
    this.waitingAuth = false
    this.pendingLayer = ''
    this.pendingAuthChallenge = null
    this.sessionId = ''
    this.verbose = false
  }

  onEvent(callback: (message: SshClientMessage) => void): void {
    this.eventCallback = callback
  }

  onData(callback: (data: Uint8Array) => void): void {
    this.dataCallback = callback
  }

  isConnected(): boolean {
    return this.connected
  }

  hasActiveSession(): boolean {
    return this.sessionId.length > 0
  }

  isWaitingAuth(): boolean {
    return this.waitingAuth
  }

  getPendingLayer(): string {
    return this.pendingLayer
  }

  static parseDiagnosticInfo(event: NativeTransportEvent): SshDiagnosticInfo | null {
    let layers: string[] = ['jump', 'target']
    let stages: string[] = [
      'connect', 'host_key', 'authentication', 'tunnel', 'channel', 'pty', 'shell',
      'session', 'keepalive'
    ]
    let statuses: string[] = ['started', 'waiting', 'succeeded', 'failed', 'timed_out', 'cancelled', 'closed']
    let reasons: string[] = [
      '', 'name_resolution', 'tcp_refused', 'tcp_timeout', 'tcp_failed', 'ssh_version',
      'key_exchange', 'transport_failed'
    ]
    if (layers.indexOf(event.layer) < 0 || stages.indexOf(event.stage) < 0 ||
      statuses.indexOf(event.status) < 0 || reasons.indexOf(event.reason) < 0 ||
      (event.reason.length > 0 && (event.stage !== 'connect' || event.status !== 'failed'))) {
      return null
    }
    let info: SshDiagnosticInfo = new SshDiagnosticInfo()
    info.layer = event.layer
    info.stage = event.stage
    info.status = event.status
    info.reason = event.reason
    return info
  }

  private handleNativeControlEvent(event: NativeControlEvent): void {
    if (!SshControlEventPolicy.isCurrent(this.sessionId, this.generation, event)) {
      this.logger.warn('Rejected stale native control event, kind=' + event.kind)
      return
    }
    this.logger.info(SshControlEventPolicy.safeLogLabel(event))
    if (event.kind === 'connected') {
      this.waitingAuth = false
      this.pendingLayer = ''
      this.connected = true
      this.logger.info('SSH connected')
      this.emitEvent(SshClientMessage.simple(SshClientEvent.CONNECTED))
    } else if (event.kind === 'host_key_prompt') {
      if (!SshControlEventPolicy.isHostKeyPrompt(event)) {
        this.handleError(new SshError(
          SshErrorCode.HostKey, 'Invalid host key prompt payload', '', 'client'))
        return
      }
      this.pendingLayer = event.layer
      this.pendingKnownHostLine = event.knownHostLine
      this.emitEvent(SshClientMessage.withText(SshClientEvent.HOST_KEY_PROMPT, event.fingerprint))
    } else if (event.kind === 'host_key_changed') {
      let info: HostKeyChangedInfo | null = SshControlEventPolicy.hostKeyChanged(event)
      if (info === null) {
        this.handleError(new SshError(
          SshErrorCode.HostKey, 'Invalid changed host key payload', '', 'client'))
        return
      }
      this.emitEvent(SshClientMessage.withHostKeyChanged(info))
    } else if (event.kind === 'error') {
      let error: SshError | null = SshControlEventPolicy.error(event)
      if (error === null) {
        this.handleError(new SshError(
          SshErrorCode.Internal, 'Invalid native SSH control error', '', 'client'))
        return
      }
      this.handleError(error)
    } else if (event.kind === 'warning') {
      this.handleWarning(event.detail)
    } else if (event.kind === 'output_metrics') {
      this.logger.info('PERF rust ' + event.metrics)
    } else {
      this.handleError(new SshError(
        SshErrorCode.Internal, 'Invalid native SSH control event', '', 'client'))
    }
  }

  private handleNativeAuthEvent(event: NativeAuthEvent): void {
    if (!SshClient.isCurrentAuthEvent(
      this.sessionId, this.generation, event.sessionId, event.generation
    )) {
      this.logger.warn('Rejected stale native auth event, kind=' + event.kind)
      return
    }
    if (event.layer !== 'jump' && event.layer !== 'target') {
      this.handleError(new SshError(
        SshErrorCode.Auth, 'Invalid authentication layer', '', 'client'))
      return
    }
    let safeAuthKinds: string[] = ['banner', 'password', 'private_key_passphrase', 'challenge']
    if (safeAuthKinds.indexOf(event.kind) >= 0) {
      this.logger.info('native auth event kind=' + event.kind + ', layer=' + event.layer)
    } else {
      this.logger.info('native auth event rejected')
    }
    if (event.kind === 'banner') {
      this.emitDiagnostic(event.layer, 'authentication', 'waiting')
      this.emitEvent(SshClientMessage.withText(SshClientEvent.AUTH_BANNER, event.text))
      return
    }
    if (event.kind === 'password') {
      this.emitDiagnostic(event.layer, 'authentication', 'waiting')
      this.pendingLayer = event.layer
      this.waitingAuth = true
      this.emitEvent(SshClientMessage.simple(SshClientEvent.PASSWORD_PROMPT))
      return
    }
    if (event.kind === 'private_key_passphrase') {
      this.emitDiagnostic(event.layer, 'authentication', 'waiting')
      this.pendingLayer = event.layer
      this.waitingAuth = true
      let keyPath: string = event.layer === 'jump' ? this.jumpPrivateKeyPath : this.privateKeyPath
      this.emitEvent(SshClientMessage.withText(SshClientEvent.PRIVATE_KEY_PASSPHRASE_PROMPT, keyPath))
      return
    }
    if (event.kind === 'challenge') {
      this.emitDiagnostic(event.layer, 'authentication', 'waiting')
      if (!Number.isInteger(event.roundId) || event.roundId < 1) {
        this.handleError(new SshError(
          SshErrorCode.Auth, 'Invalid keyboard-interactive round', '', 'client'))
        return
      }
      let challenge: AuthChallengeInfo = new AuthChallengeInfo()
      challenge.roundId = event.roundId
      challenge.name = event.name
      challenge.instructions = event.instructions
      challenge.prompts = []
      for (let i = 0; i < event.prompts.length; i++) {
        let nativePrompt: NativeAuthPromptEvent = event.prompts[i]
        let prompt: AuthPromptInfo = new AuthPromptInfo()
        prompt.text = nativePrompt.text
        prompt.echo = nativePrompt.echo
        challenge.prompts.push(prompt)
      }
      this.pendingAuthChallenge = challenge
      this.pendingLayer = event.layer
      this.waitingAuth = true
      this.emitEvent(SshClientMessage.simple(SshClientEvent.AUTH_CHALLENGE))
      return
    }
    this.handleError(new SshError(
      SshErrorCode.Auth, 'Unknown native authentication event', '', 'client'))
  }

  private handleNativeTransportEvent(event: NativeTransportEvent): void {
    if (event.kind === 'data') {
      if (this.dataCallback !== null) {
        this.dataCallback(event.data)
      }
      return
    }
    if (event.kind === 'close') {
      if (event.code.length === 0 && event.detail.length === 0 && event.layer.length === 0) {
        this.handleClose(event.exitCode)
      } else if (event.code === 'keepalive_timeout' && event.detail.length > 0 &&
        SshControlEventPolicy.isLayer(event.layer)) {
        this.handleError(new SshError(
          SshErrorCode.Network, event.detail, event.detail, event.layer))
      } else {
        this.handleError(new SshError(
          SshErrorCode.Network, 'Invalid native SSH close event', '', 'client'))
      }
      return
    }
    if (event.kind === 'diagnostic') {
      if (!this.verbose) { return }
      let info: SshDiagnosticInfo | null = SshClient.parseDiagnosticInfo(event)
      if (info === null) {
        this.logger.warn('Rejected invalid SSH diagnostic event')
        return
      }
      this.logDiagnostic(info)
      this.emitEvent(SshClientMessage.withDiagnostic(info))
      return
    }
    this.handleError(new SshError(
      SshErrorCode.Network, 'Invalid native SSH transport event', '', 'client'))
  }

  private emitDiagnostic(layer: string, stage: string, status: string): void {
    if (!this.verbose) { return }
    let nativeEvent: NativeTransportEvent = {
      kind: 'diagnostic', data: new Uint8Array(0), result: '', exitCode: -1, code: '', detail: '',
      layer: layer, stage: stage, status: status, reason: ''
    }
    let info: SshDiagnosticInfo | null = SshClient.parseDiagnosticInfo(nativeEvent)
    if (info !== null) {
      this.logDiagnostic(info)
      this.emitEvent(SshClientMessage.withDiagnostic(info))
    }
  }

  private logDiagnostic(info: SshDiagnosticInfo): void {
    this.logger.info('SSH diagnostic layer=' + info.layer + ', stage=' + info.stage +
      ', status=' + info.status + ', reason=' + (info.reason.length > 0 ? info.reason : 'none'))
  }

  private emitEvent(message: SshClientMessage): void {
    if (this.eventCallback !== null) {
      this.eventCallback(message)
    }
  }

  private reportError(error: SshError): void {
    this.emitEvent(SshClientMessage.withError(error))
  }

  private handleWarning(detail: string): void {
    this.logger.warn('Recoverable SSH warning')
    this.emitEvent(SshClientMessage.withText(SshClientEvent.WARNING, detail))
  }

  private handleClose(exitCode: number): void {
    this.connected = false
    this.waitingAuth = false
    this.pendingLayer = ''
    this.pendingAuthChallenge = null
    this.sessionId = ''
    this.verbose = false
    this.emitEvent(SshClientMessage.close(exitCode))
  }

  private handleError(error: SshError): void {
    this.connected = false
    this.waitingAuth = false
    this.pendingLayer = ''
    this.pendingAuthChallenge = null
    this.sessionId = ''
    this.verbose = false
    this.emitEvent(SshClientMessage.withError(error))
  }
}
