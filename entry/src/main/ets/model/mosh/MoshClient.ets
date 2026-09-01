import sshNative from 'libleantty_ssh.so'
import type {
  AuthEvent as NativeAuthEvent,
  AuthPromptEvent as NativeAuthPromptEvent,
  ControlEvent as NativeControlEvent,
  TransportEvent as NativeTransportEvent
} from 'libleantty_ssh.so'
import { Logger } from '../../common/logger/Logger'
import { SshConnectOptions } from '../../common/types/SshTypes'
import {
  AuthChallengeInfo,
  AuthPromptInfo,
  SshClient
} from '../ssh/SshClient'
import {
  HostKeyChangedInfo,
  SshControlEventPolicy
} from '../ssh/SshControlEventPolicy'
import { MoshPredictionMode } from './MoshPredictionMode'

export enum MoshErrorCode {
  NETWORK = 1,
  AUTH = 2,
  HOST_KEY = 3,
  SERVER = 4,
  PROTOCOL = 5,
  RESOURCE_LIMIT = 6,
  INTERNAL = 7,
  SESSION_CLOSED = 8
}

export class MoshError extends Error {
  code: MoshErrorCode
  detail: string
  stage: string

  constructor(code: MoshErrorCode, message: string, detail: string, stage: string) {
    super(message)
    this.code = code
    this.detail = detail
    this.stage = stage
  }
}

export enum MoshClientEvent {
  PASSWORD_PROMPT = 'PASSWORD_PROMPT',
  PRIVATE_KEY_PASSPHRASE_PROMPT = 'PRIVATE_KEY_PASSPHRASE_PROMPT',
  AUTH_BANNER = 'AUTH_BANNER',
  AUTH_CHALLENGE = 'AUTH_CHALLENGE',
  HOST_KEY_PROMPT = 'HOST_KEY_PROMPT',
  HOST_KEY_CHANGED = 'HOST_KEY_CHANGED',
  STATUS = 'STATUS',
  REACHABILITY = 'REACHABILITY',
  CONNECTED = 'CONNECTED',
  CLOSE = 'CLOSE',
  ERROR = 'ERROR'
}

export class MoshStatusInfo {
  stage: string = ''
  status: string = ''
}

export enum MoshReachability {
  AWAITING_PEER = 'awaiting_peer',
  RESPONSIVE = 'responsive',
  INTERRUPTED = 'interrupted'
}

export enum MoshInterruption {
  NONE = '',
  NO_RECENT_CONTACT = 'no_recent_contact',
  NO_RECENT_REPLY = 'no_recent_reply'
}

export class MoshReachabilityInfo {
  state: MoshReachability = MoshReachability.AWAITING_PEER
  reason: MoshInterruption = MoshInterruption.NONE
}

export class MoshClientMessage {
  kind: MoshClientEvent = MoshClientEvent.ERROR
  text: string = ''
  exitCode: number = -1
  error: MoshError | null = null
  hostKeyChanged: HostKeyChangedInfo | null = null
  status: MoshStatusInfo | null = null
  reachability: MoshReachabilityInfo | null = null

  static simple(kind: MoshClientEvent): MoshClientMessage {
    let message: MoshClientMessage = new MoshClientMessage()
    message.kind = kind
    return message
  }

  static withText(kind: MoshClientEvent, text: string): MoshClientMessage {
    let message: MoshClientMessage = MoshClientMessage.simple(kind)
    message.text = text
    return message
  }

  static withError(error: MoshError): MoshClientMessage {
    let message: MoshClientMessage = MoshClientMessage.simple(MoshClientEvent.ERROR)
    message.error = error
    return message
  }

  static withHostKeyChanged(info: HostKeyChangedInfo): MoshClientMessage {
    let message: MoshClientMessage = MoshClientMessage.simple(MoshClientEvent.HOST_KEY_CHANGED)
    message.hostKeyChanged = info
    return message
  }

  static withStatus(info: MoshStatusInfo): MoshClientMessage {
    let message: MoshClientMessage = MoshClientMessage.simple(MoshClientEvent.STATUS)
    message.status = info
    return message
  }

  static withReachability(info: MoshReachabilityInfo): MoshClientMessage {
    let message: MoshClientMessage = MoshClientMessage.simple(MoshClientEvent.REACHABILITY)
    message.reachability = info
    return message
  }

  static close(exitCode: number): MoshClientMessage {
    let message: MoshClientMessage = MoshClientMessage.simple(MoshClientEvent.CLOSE)
    message.exitCode = exitCode
    return message
  }
}

export class MoshClient {
  private static nextGeneration: number = 1
  private sessionId: string = ''
  private generation: number = 0
  private connected: boolean = false
  private waitingAuth: boolean = false
  private pendingLayer: string = ''
  private pendingKnownHostLine: string = ''
  private privateKeyPath: string = ''
  private pendingAuthChallenge: AuthChallengeInfo | null = null
  private eventCallback: ((message: MoshClientMessage) => void) | null = null
  private dataCallback: ((data: Uint8Array) => void) | null = null
  private disconnectCompletion: (() => void) | null = null
  private logger: Logger = new Logger('MoshClient')

  async connect(options: SshConnectOptions, serverPath: string,
    udpPortStart: number, udpPortEnd: number,
    predictionMode: MoshPredictionMode, columns: number, rows: number): Promise<void> {
    if (this.sessionId.length > 0) {
      this.reportError(new MoshError(
        MoshErrorCode.SESSION_CLOSED, 'Session already active', '', 'client'))
      return
    }
    if (options.jumpHost.length > 0) {
      this.reportError(new MoshError(
        MoshErrorCode.PROTOCOL, 'ProxyJump is not supported by Mosh', '', 'client'))
      return
    }
    try {
      this.generation = MoshClient.nextGeneration
      MoshClient.nextGeneration++
      if (MoshClient.nextGeneration > 4294967295) {
        MoshClient.nextGeneration = 1
      }
      this.privateKeyPath = options.privateKeyPath
      this.sessionId = sshNative.moshConnect(
        options.host,
        options.port,
        options.username,
        options.privateKeyPath,
        options.privateKeyRequiresPassphrase,
        options.knownHostsPath,
        options.connectTimeoutMs,
        options.serverAliveIntervalSeconds,
        options.serverAliveCountMax,
        serverPath,
        udpPortStart,
        udpPortEnd,
        predictionMode,
        columns,
        rows,
        this.generation,
        (event: NativeTransportEvent) => { this.handleNativeTransportEvent(event) },
        (event: NativeControlEvent) => { this.handleNativeControlEvent(event) },
        (event: NativeAuthEvent) => { this.handleNativeAuthEvent(event) }
      )
      this.logger.info('Mosh connect initiated, sessionId=' + this.sessionId)
    } catch (e) {
      this.logger.error('moshConnect N-API failed')
      throw new Error('Mosh connect failed: ' + e)
    }
  }

  authPassword(password: string): boolean {
    if (!this.canSubmitAuthentication()) {
      this.reportError(new MoshError(
        MoshErrorCode.SESSION_CLOSED, 'Not waiting for password', '', 'client'))
      return false
    }
    try {
      sshNative.sshAuthPassword(this.sessionId, this.generation, this.pendingLayer, password)
      this.finishAuthenticationSubmission()
      return true
    } catch (e) {
      this.reportError(new MoshError(
        MoshErrorCode.INTERNAL, 'Password authentication request failed', '' + e, 'client'))
      return false
    }
  }

  authPrivateKeyPassphrase(passphrase: string): boolean {
    if (!this.canSubmitAuthentication()) {
      this.reportError(new MoshError(
        MoshErrorCode.SESSION_CLOSED, 'Not waiting for a key passphrase', '', 'client'))
      return false
    }
    try {
      sshNative.sshAuthPrivateKeyPassphrase(
        this.sessionId, this.generation, this.pendingLayer, passphrase)
      this.finishAuthenticationSubmission()
      return true
    } catch (e) {
      this.reportError(new MoshError(
        MoshErrorCode.INTERNAL, 'Private-key passphrase request failed', '' + e, 'client'))
      return false
    }
  }

  authKeyboardInteractiveResponses(roundId: number, responses: string[]): boolean {
    if (!this.canSubmitAuthentication()) {
      this.reportError(new MoshError(
        MoshErrorCode.SESSION_CLOSED, 'Not waiting for authentication responses', '', 'client'))
      return false
    }
    try {
      sshNative.sshAuthKeyboardInteractiveResponses(
        this.sessionId, this.generation, this.pendingLayer, roundId, responses)
      this.pendingAuthChallenge = null
      this.finishAuthenticationSubmission()
      return true
    } catch (e) {
      this.reportError(new MoshError(
        MoshErrorCode.INTERNAL, 'Authentication response request failed', '' + e, 'client'))
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
      this.reportError(new MoshError(
        MoshErrorCode.SESSION_CLOSED, 'Session not active', '', 'client'))
      return false
    }
    try {
      sshNative.sshVerifyHostKey(this.sessionId, this.generation, this.pendingLayer, accepted)
      this.pendingKnownHostLine = ''
      this.pendingLayer = ''
      return true
    } catch (e) {
      this.reportError(new MoshError(
        MoshErrorCode.HOST_KEY, 'Host key response failed', '' + e, 'client'))
      return false
    }
  }

  getPendingKnownHostLine(): string {
    return this.pendingKnownHostLine
  }

  write(data: string): void {
    if (!this.connected || this.sessionId.length === 0) { return }
    try {
      sshNative.moshWrite(this.sessionId, data)
    } catch (e) {
      this.logger.warn('Mosh write request rejected')
    }
  }

  resize(columns: number, rows: number): void {
    if (this.sessionId.length === 0) { return }
    try {
      sshNative.moshResize(this.sessionId, columns, rows)
    } catch (e) {
      this.logger.warn('Mosh resize request rejected')
    }
  }

  setOutputPaused(paused: boolean): void {
    if (this.sessionId.length === 0) { return }
    try {
      sshNative.moshSetOutputPaused(this.sessionId, paused)
    } catch (e) {
      this.logger.warn('Mosh output flow-control request rejected')
    }
  }

  async disconnect(): Promise<void> {
    if (this.sessionId.length === 0) { return }
    let completion: Promise<void> = new Promise<void>((resolve: () => void) => {
      this.disconnectCompletion = resolve
    })
    try {
      sshNative.moshDisconnect(this.sessionId)
    } catch (e) {
      this.logger.warn('Mosh disconnect request failed')
      this.clearSession()
      return
    }
    this.connected = false
    this.waitingAuth = false
    this.pendingLayer = ''
    await completion
  }

  onEvent(callback: (message: MoshClientMessage) => void): void {
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

  getPendingLayer(): string {
    return this.pendingLayer
  }

  private canSubmitAuthentication(): boolean {
    return this.waitingAuth && this.sessionId.length > 0 && this.pendingLayer.length > 0
  }

  private finishAuthenticationSubmission(): void {
    this.waitingAuth = false
    this.pendingLayer = ''
  }

  private handleNativeControlEvent(event: NativeControlEvent): void {
    if (!SshControlEventPolicy.isCurrent(this.sessionId, this.generation, event)) {
      this.logger.warn('Rejected stale Mosh control event')
      return
    }
    if (event.kind === 'connected') {
      this.connected = true
      this.finishAuthenticationSubmission()
      this.emitEvent(MoshClientMessage.simple(MoshClientEvent.CONNECTED))
      return
    }
    if (event.kind === 'host_key_prompt' && SshControlEventPolicy.isHostKeyPrompt(event)) {
      this.pendingLayer = event.layer
      this.pendingKnownHostLine = event.knownHostLine
      this.logger.info('Mosh host key prompt')
      this.emitEvent(MoshClientMessage.withText(MoshClientEvent.HOST_KEY_PROMPT, event.fingerprint))
      return
    }
    if (event.kind === 'host_key_changed') {
      let info: HostKeyChangedInfo | null = SshControlEventPolicy.hostKeyChanged(event)
      if (info !== null) {
        this.emitEvent(MoshClientMessage.withHostKeyChanged(info))
        return
      }
    }
    if (event.kind === 'error') {
      this.handleError(MoshClient.parseControlError(event))
      return
    }
    this.handleError(new MoshError(
      MoshErrorCode.INTERNAL, 'Invalid native Mosh control event', '', 'client'))
  }

  static parseControlError(event: NativeControlEvent): MoshError {
    let code: MoshErrorCode = MoshErrorCode.INTERNAL
    if (event.code === 'network' || event.code === 'connection_timeout') {
      code = MoshErrorCode.NETWORK
    }
    else if (event.code === 'auth') { code = MoshErrorCode.AUTH }
    else if (event.code === 'host_key') { code = MoshErrorCode.HOST_KEY }
    else if (event.code === 'server' || event.code === 'channel') { code = MoshErrorCode.SERVER }
    else if (event.code === 'protocol' || event.code === 'terminal_size' ||
      event.code === 'input' || event.code === 'repaint') { code = MoshErrorCode.PROTOCOL }
    else if (event.code === 'resource_limit' || event.code === 'state_exhausted') {
      code = MoshErrorCode.RESOURCE_LIMIT
    }
    if (!SshControlEventPolicy.isLayer(event.layer) || event.stage.length === 0 ||
      event.detail.length === 0) {
      return new MoshError(
        MoshErrorCode.INTERNAL, 'Invalid native Mosh error', '', 'client')
    }
    return new MoshError(code, event.detail, event.detail, event.stage)
  }

  private handleNativeAuthEvent(event: NativeAuthEvent): void {
    if (!SshClient.isCurrentAuthEvent(
      this.sessionId, this.generation, event.sessionId, event.generation) ||
      event.layer !== 'target') {
      this.logger.warn('Rejected stale or invalid Mosh authentication event')
      return
    }
    if (event.kind === 'banner') {
      this.emitEvent(MoshClientMessage.withText(MoshClientEvent.AUTH_BANNER, event.text))
      return
    }
    if (event.kind === 'password') {
      this.pendingLayer = event.layer
      this.waitingAuth = true
      this.logger.info('Mosh auth event kind=password')
      this.emitEvent(MoshClientMessage.simple(MoshClientEvent.PASSWORD_PROMPT))
      return
    }
    if (event.kind === 'private_key_passphrase') {
      this.pendingLayer = event.layer
      this.waitingAuth = true
      this.emitEvent(MoshClientMessage.withText(
        MoshClientEvent.PRIVATE_KEY_PASSPHRASE_PROMPT, this.privateKeyPath))
      return
    }
    if (event.kind === 'challenge' && Number.isInteger(event.roundId) && event.roundId > 0) {
      let challenge: AuthChallengeInfo = new AuthChallengeInfo()
      challenge.roundId = event.roundId
      challenge.name = event.name
      challenge.instructions = event.instructions
      for (let index: number = 0; index < event.prompts.length; index++) {
        let nativePrompt: NativeAuthPromptEvent = event.prompts[index]
        let prompt: AuthPromptInfo = new AuthPromptInfo()
        prompt.text = nativePrompt.text
        prompt.echo = nativePrompt.echo
        challenge.prompts.push(prompt)
      }
      this.pendingAuthChallenge = challenge
      this.pendingLayer = event.layer
      this.waitingAuth = true
      this.emitEvent(MoshClientMessage.simple(MoshClientEvent.AUTH_CHALLENGE))
      return
    }
    this.handleError(new MoshError(
      MoshErrorCode.AUTH, 'Invalid native Mosh authentication event', '', 'authentication'))
  }

  private handleNativeTransportEvent(event: NativeTransportEvent): void {
    if (this.sessionId.length === 0) { return }
    if (event.kind === 'data') {
      if (this.dataCallback !== null) { this.dataCallback(event.data) }
      return
    }
    if (event.kind === 'diagnostic') {
      let status: MoshStatusInfo | null = MoshClient.parseStatus(event)
      if (status !== null) { this.emitEvent(MoshClientMessage.withStatus(status)) }
      return
    }
    if (event.kind === 'reachability') {
      let reachability: MoshReachabilityInfo | null = MoshClient.parseReachability(event)
      if (reachability === null) {
        this.handleError(new MoshError(
          MoshErrorCode.INTERNAL, 'Invalid native Mosh reachability event', '', 'client'))
      } else {
        this.emitEvent(MoshClientMessage.withReachability(reachability))
      }
      return
    }
    if (event.kind === 'close') {
      if (event.code.length > 0) {
        this.handleError(new MoshError(
          MoshErrorCode.NETWORK, event.detail, event.detail, 'mosh_udp'))
      } else {
        this.clearSession()
        this.emitEvent(MoshClientMessage.close(event.exitCode))
      }
      return
    }
    this.handleError(new MoshError(
      MoshErrorCode.INTERNAL, 'Invalid native Mosh transport event', '', 'client'))
  }

  static parseStatus(event: NativeTransportEvent): MoshStatusInfo | null {
    let stages: string[] = ['mosh_bootstrap', 'mosh_udp']
    let statuses: string[] = ['started', 'succeeded', 'failed', 'closed']
    if (event.kind !== 'diagnostic' || event.layer !== 'target' ||
      stages.indexOf(event.stage) < 0 || statuses.indexOf(event.status) < 0 ||
      event.reason.length > 0) {
      return null
    }
    let info: MoshStatusInfo = new MoshStatusInfo()
    info.stage = event.stage
    info.status = event.status
    return info
  }

  static parseReachability(event: NativeTransportEvent): MoshReachabilityInfo | null {
    if (event.kind !== 'reachability' || event.layer !== 'target' || event.stage !== 'mosh_udp') {
      return null
    }
    let info: MoshReachabilityInfo = new MoshReachabilityInfo()
    if (event.status === MoshReachability.AWAITING_PEER && event.reason.length === 0) {
      info.state = MoshReachability.AWAITING_PEER
      return info
    }
    if (event.status === MoshReachability.RESPONSIVE && event.reason.length === 0) {
      info.state = MoshReachability.RESPONSIVE
      return info
    }
    if (event.status === MoshReachability.INTERRUPTED &&
      (event.reason === MoshInterruption.NO_RECENT_CONTACT ||
      event.reason === MoshInterruption.NO_RECENT_REPLY)) {
      info.state = MoshReachability.INTERRUPTED
      info.reason = event.reason === MoshInterruption.NO_RECENT_CONTACT ?
        MoshInterruption.NO_RECENT_CONTACT : MoshInterruption.NO_RECENT_REPLY
      return info
    }
    return null
  }

  private emitEvent(message: MoshClientMessage): void {
    if (this.eventCallback !== null) { this.eventCallback(message) }
  }

  private reportError(error: MoshError): void {
    this.emitEvent(MoshClientMessage.withError(error))
  }

  private handleError(error: MoshError): void {
    this.clearSession()
    this.emitEvent(MoshClientMessage.withError(error))
  }

  private clearSession(): void {
    this.connected = false
    this.waitingAuth = false
    this.pendingLayer = ''
    this.pendingKnownHostLine = ''
    this.pendingAuthChallenge = null
    this.sessionId = ''
    let completion: (() => void) | null = this.disconnectCompletion
    this.disconnectCompletion = null
    if (completion !== null) {
      completion()
    }
  }
}
