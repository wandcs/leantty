import { SshErrorCode, SshError, SshConnectOptions } from '../../common/types/SshTypes'
import { Logger } from '../../common/logger/Logger'
import sshNative from 'libleantty_ssh.so'
import type {
  AuthEvent as NativeAuthEvent,
  AuthPromptEvent as NativeAuthPromptEvent,
  TransportEvent as NativeTransportEvent
} from 'libleantty_ssh.so'

export { SshErrorCode, SshError, SshConnectOptions } from '../../common/types/SshTypes'

export enum SshClientEvent {
  PASSWORD_PROMPT = 'PASSWORD_PROMPT',
  PRIVATE_KEY_PASSPHRASE_PROMPT = 'PRIVATE_KEY_PASSPHRASE_PROMPT',
  AUTH_BANNER = 'AUTH_BANNER',
  AUTH_CHALLENGE = 'AUTH_CHALLENGE',
  HOST_KEY_PROMPT = 'HOST_KEY_PROMPT',
  HOST_KEY_CHANGED = 'HOST_KEY_CHANGED',
  CONNECTED = 'CONNECTED',
  DATA = 'DATA',
  CLOSE = 'CLOSE',
  ERROR = 'ERROR',
  WARNING = 'WARNING'
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

export class HostKeyChangedInfo {
  layer: string = ''
  algorithm: string = ''
  oldFingerprint: string = ''
  newFingerprint: string = ''
  host: string = ''
  port: number = 22
}

export class SshClient {
  private static nextGeneration: number = 1
  private sessionId: string = ''
  private generation: number = 0
  private connected: boolean = false
  private waitingAuth: boolean = false
  private pendingLayer: string = ''
  private pendingKnownHostLine: string = ''
  private privateKeyPath: string = ''
  private jumpPrivateKeyPath: string = ''
  private pendingAuthChallenge: AuthChallengeInfo | null = null
  private eventCallback: ((event: SshClientEvent, data: string) => void) | null = null
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
        options.knownHostsPath,
        options.connectTimeoutMs,
        this.generation,
        (event: NativeTransportEvent) => {
          this.handleNativeTransportEvent(event)
        },
        (event: string) => {
          this.handleRustEvent(event)
        },
        (event: NativeAuthEvent) => {
          this.handleNativeAuthEvent(event)
        }
      )
      this.sessionId = id
      this.logger.info('SSH connect initiated, sessionId=' + id)
    } catch (e) {
      this.logger.error('sshConnect N-API failed: ' + e)
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
      this.logger.error('sshAuthPassword failed: ' + e)
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
      this.logger.error('sshAuthPrivateKeyPassphrase failed: ' + e)
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
      this.logger.error('sshAuthKeyboardInteractiveResponses failed: ' + e)
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
      this.logger.error('sshWrite failed: ' + e)
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
      this.logger.error('sshResize failed: ' + e)
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
      this.logger.error('sshSetOutputPaused failed: ' + e)
      this.handleWarning('Output flow-control request rejected: ' + e)
    }
  }

  async disconnect(): Promise<void> {
    if (this.sessionId.length === 0) {
      return
    }
    try {
      sshNative.sshDisconnect(this.sessionId)
    } catch (e) {
      this.logger.error('sshDisconnect failed: ' + e)
    }
    this.connected = false
    this.waitingAuth = false
    this.pendingLayer = ''
    this.pendingAuthChallenge = null
    this.sessionId = ''
  }

  onEvent(callback: (event: SshClientEvent, data: string) => void): void {
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

  static parseCloseError(closeResult: string): string | null {
    if (!closeResult.startsWith('ERROR:')) {
      return null
    }
    let detail: string = closeResult.substring(6).trim()
    return detail.length > 0 ? detail : 'SSH connection ended unexpectedly.'
  }

  static parseHostKeyChangedInfo(payload: string): HostKeyChangedInfo | null {
    let fields: string[] = payload.split('\t')
    if (fields.length !== 6) {
      return null
    }
    let port: number = parseInt(fields[5], 10)
    if ((fields[0] !== 'jump' && fields[0] !== 'target') || fields[1].length === 0 ||
      fields[2].length === 0 || fields[3].length === 0 || fields[4].length === 0 ||
      !/^\d+$/.test(fields[5]) || isNaN(port) || port < 1 || port > 65535) {
      return null
    }
    let info: HostKeyChangedInfo = new HostKeyChangedInfo()
    info.layer = fields[0]
    info.algorithm = fields[1]
    info.oldFingerprint = fields[2]
    info.newFingerprint = fields[3]
    info.host = fields[4]
    info.port = port
    return info
  }

  private handleRustEvent(event: string): void {
    this.logger.info('rust event: ' + event)
    if (event === 'CONNECTED') {
      this.waitingAuth = false
      this.pendingLayer = ''
      this.connected = true
      this.logger.info('SSH connected')
      this.emitEvent(SshClientEvent.CONNECTED, '')
    } else if (event.startsWith('HOST_KEY_PROMPT:')) {
      let payload: string = event.substring(16)
      let fields: string[] = payload.split('\t')
      if (fields.length !== 3 || (fields[0] !== 'jump' && fields[0] !== 'target') ||
        fields[1].length === 0 || fields[2].length === 0) {
        this.handleError('HOST_KEY:Invalid host key prompt payload')
        return
      }
      this.pendingLayer = fields[0]
      this.pendingKnownHostLine = fields[2]
      this.emitEvent(SshClientEvent.HOST_KEY_PROMPT, fields[1])
    } else if (event.startsWith('HOST_KEY_CHANGED:')) {
      let info: HostKeyChangedInfo | null = SshClient.parseHostKeyChangedInfo(event.substring(17))
      if (info === null) {
        this.handleError('HOST_KEY:Invalid changed host key payload')
        return
      }
      this.emitEvent(SshClientEvent.HOST_KEY_CHANGED, JSON.stringify(info))
    } else if (event.startsWith('HOST_KEY_ERROR:')) {
      this.handleError('HOST_KEY:' + event.substring(15))
    } else if (event.startsWith('RESIZE_ERROR:')) {
      this.handleWarning(event.substring(13))
    } else if (event.startsWith('OUTPUT_METRICS:')) {
      this.logger.info('PERF rust ' + event.substring(15))
    } else if (event.startsWith('CONNECT:') || event.startsWith('AUTH:') ||
               event.startsWith('KEY_ERROR:') ||
               event.startsWith('CHANNEL:') || event.startsWith('PTY:') ||
               event.startsWith('SHELL:') || event.startsWith('WRITE_ERROR:')) {
      this.handleError(event)
    }
  }

  private handleNativeAuthEvent(event: NativeAuthEvent): void {
    if (!SshClient.isCurrentAuthEvent(
      this.sessionId, this.generation, event.sessionId, event.generation
    )) {
      this.logger.warn('Rejected stale native auth event, kind=' + event.kind)
      return
    }
    this.logger.info('native auth event kind=' + event.kind + ', layer=' + event.layer)
    if (event.layer !== 'jump' && event.layer !== 'target') {
      this.handleError('AUTH:Invalid authentication layer')
      return
    }
    if (event.kind === 'banner') {
      this.emitEvent(SshClientEvent.AUTH_BANNER, event.text)
      return
    }
    if (event.kind === 'password') {
      this.pendingLayer = event.layer
      this.waitingAuth = true
      this.emitEvent(SshClientEvent.PASSWORD_PROMPT, '')
      return
    }
    if (event.kind === 'private_key_passphrase') {
      this.pendingLayer = event.layer
      this.waitingAuth = true
      let keyPath: string = event.layer === 'jump' ? this.jumpPrivateKeyPath : this.privateKeyPath
      this.emitEvent(SshClientEvent.PRIVATE_KEY_PASSPHRASE_PROMPT, keyPath)
      return
    }
    if (event.kind === 'challenge') {
      if (!Number.isInteger(event.roundId) || event.roundId < 1) {
        this.handleError('AUTH:Invalid keyboard-interactive round')
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
      this.emitEvent(SshClientEvent.AUTH_CHALLENGE, '')
      return
    }
    this.handleError('AUTH:Unknown native authentication event')
  }

  private handleNativeTransportEvent(event: NativeTransportEvent): void {
    if (event.kind === 'data') {
      if (this.dataCallback !== null) {
        this.dataCallback(event.data)
      }
      return
    }
    if (event.kind === 'close') {
      let closeError: string | null = SshClient.parseCloseError(event.result)
      if (closeError !== null) {
        this.handleError('CONNECT:' + closeError)
      } else {
        let exitCode: number = parseInt(event.result, 10)
        this.handleClose(isNaN(exitCode) ? -1 : exitCode)
      }
      return
    }
    this.handleError('CONNECT:Invalid native SSH transport event')
  }

  private emitEvent(event: SshClientEvent, data: string): void {
    if (this.eventCallback !== null) {
      this.eventCallback(event, data)
    }
  }

  private reportError(error: SshError): void {
    this.emitEvent(SshClientEvent.ERROR, error.detail)
  }

  private handleWarning(detail: string): void {
    this.logger.warn('Recoverable SSH warning: ' + detail)
    this.emitEvent(SshClientEvent.WARNING, detail)
  }

  private handleClose(exitCode: number): void {
    this.connected = false
    this.waitingAuth = false
    this.pendingLayer = ''
    this.pendingAuthChallenge = null
    this.sessionId = ''
    this.emitEvent(SshClientEvent.CLOSE, exitCode.toString())
  }

  private handleError(errorStr: string): void {
    this.connected = false
    this.waitingAuth = false
    this.pendingLayer = ''
    this.pendingAuthChallenge = null
    this.sessionId = ''
    let code: SshErrorCode = SshErrorCode.Internal
    let detail: string = errorStr
    if (errorStr.startsWith('CONNECT:')) {
      code = SshErrorCode.Network
      detail = errorStr.substring(8)
    } else if (errorStr.startsWith('AUTH:')) {
      code = SshErrorCode.Auth
      detail = errorStr.substring(5)
    } else if (errorStr.startsWith('KEY_ERROR:')) {
      code = SshErrorCode.Auth
      detail = errorStr.substring(10)
    } else if (errorStr.startsWith('CHANNEL:')) {
      code = SshErrorCode.Channel
      detail = errorStr.substring(8)
    } else if (errorStr.startsWith('PTY:')) {
      code = SshErrorCode.Protocol
      detail = errorStr.substring(4)
    } else if (errorStr.startsWith('SHELL:')) {
      code = SshErrorCode.Protocol
      detail = errorStr.substring(6)
    } else if (errorStr.startsWith('HOST_KEY:')) {
      code = SshErrorCode.HostKey
      detail = errorStr.substring(9)
    }
    this.emitEvent(SshClientEvent.ERROR, new SshError(code, detail, detail, 'rust').detail)
  }
}
