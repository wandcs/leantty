import sshNative from 'libleantty_ssh.so'
import type {
  AuthEvent as NativeAuthEvent,
  AuthPromptEvent as NativeAuthPromptEvent,
  ControlEvent as NativeControlEvent,
  FileTransferEvent as NativeFileTransferEvent
} from 'libleantty_ssh.so'
import { Logger } from '../../common/logger/Logger'
import {
  AuthChallengeInfo,
  AuthPromptInfo,
  HostKeyChangedInfo,
  SshClient,
  SshClientEvent,
  SshClientMessage
} from '../ssh/SshClient'
import { SshControlEventPolicy } from '../ssh/SshControlEventPolicy'

export class FileTransferOptions {
  direction: string = ''
  host: string = ''
  port: number = 22
  username: string = ''
  privateKeyPath: string = ''
  privateKeyRequiresPassphrase: boolean = false
  knownHostsPath: string = ''
  connectTimeoutMs: number = 15000
  serverAliveIntervalSeconds: number = 30
  serverAliveCountMax: number = 3
  paneId: string = ''
  remotePath: string = ''
  localPath: string = ''
  localDescriptor: number = -1
}

export class FileTransferProgress {
  kind: string = ''
  transferId: string = ''
  paneId: string = ''
  generation: number = 0
  transferredBytes: number = 0
  totalBytes: number = 0
  code: string = ''
  detail: string = ''
}

export class FileTransferClient {
  private static nextGeneration: number = 1
  private transferId: string = ''
  private generation: number = 0
  private paneId: string = ''
  private waitingAuth: boolean = false
  private pendingLayer: string = ''
  private privateKeyPath: string = ''
  private pendingKnownHostLine: string = ''
  private pendingAuthChallenge: AuthChallengeInfo | null = null
  private eventCallback: ((message: SshClientMessage) => void) | null = null
  private progressCallback: ((event: FileTransferProgress) => void) | null = null
  private logger: Logger = new Logger('FileTransferClient')

  start(options: FileTransferOptions): void {
    if (this.transferId.length > 0) {
      throw new Error('A file transfer is already active')
    }
    this.generation = FileTransferClient.nextGeneration
    FileTransferClient.nextGeneration++
    if (FileTransferClient.nextGeneration > 4294967295) {
      FileTransferClient.nextGeneration = 1
    }
    this.paneId = options.paneId
    this.privateKeyPath = options.privateKeyPath
    this.transferId = sshNative.sshStartFileTransfer(
      options.direction,
      options.host,
      options.port,
      options.username,
      options.privateKeyPath,
      options.privateKeyRequiresPassphrase,
      options.knownHostsPath,
      options.connectTimeoutMs,
      options.serverAliveIntervalSeconds,
      options.serverAliveCountMax,
      this.generation,
      options.paneId,
      options.remotePath,
      options.localPath,
      options.localDescriptor,
      (event: NativeControlEvent) => { this.handleNativeControlEvent(event) },
      (event: NativeAuthEvent) => { this.handleNativeAuthEvent(event) },
      (event: NativeFileTransferEvent) => { this.handleNativeTransferEvent(event) }
    )
    this.logger.info('File transfer initiated, transferId=' + this.transferId)
  }

  onEvent(callback: (message: SshClientMessage) => void): void {
    this.eventCallback = callback
  }

  onProgress(callback: (event: FileTransferProgress) => void): void {
    this.progressCallback = callback
  }

  hasActiveTransfer(): boolean {
    return this.transferId.length > 0
  }

  getPendingLayer(): string {
    return this.pendingLayer
  }

  authPassword(password: string): boolean {
    if (!this.waitingAuth || this.transferId.length === 0 || this.pendingLayer !== 'target') {
      return false
    }
    try {
      sshNative.sshAuthPassword(this.transferId, this.generation, this.pendingLayer, password)
      this.waitingAuth = false
      this.pendingLayer = ''
      return true
    } catch (e) {
      this.logger.error('Transfer password response failed')
      return false
    }
  }

  authPrivateKeyPassphrase(passphrase: string): boolean {
    if (!this.waitingAuth || this.transferId.length === 0 || this.pendingLayer !== 'target') {
      return false
    }
    try {
      sshNative.sshAuthPrivateKeyPassphrase(
        this.transferId, this.generation, this.pendingLayer, passphrase
      )
      this.waitingAuth = false
      this.pendingLayer = ''
      return true
    } catch (e) {
      this.logger.error('Transfer key passphrase response failed')
      return false
    }
  }

  authKeyboardInteractiveResponses(roundId: number, responses: string[]): boolean {
    if (!this.waitingAuth || this.transferId.length === 0 || this.pendingLayer !== 'target') {
      return false
    }
    try {
      sshNative.sshAuthKeyboardInteractiveResponses(
        this.transferId, this.generation, this.pendingLayer, roundId, responses
      )
      this.waitingAuth = false
      this.pendingLayer = ''
      this.pendingAuthChallenge = null
      return true
    } catch (e) {
      this.logger.error('Transfer keyboard-interactive response failed')
      return false
    }
  }

  takePendingAuthChallenge(): AuthChallengeInfo | null {
    let challenge: AuthChallengeInfo | null = this.pendingAuthChallenge
    this.pendingAuthChallenge = null
    return challenge
  }

  verifyHostKey(accepted: boolean): boolean {
    if (this.transferId.length === 0 || this.pendingLayer !== 'target') { return false }
    try {
      sshNative.sshVerifyHostKey(this.transferId, this.generation, this.pendingLayer, accepted)
      this.pendingKnownHostLine = ''
      this.pendingLayer = ''
      return true
    } catch (e) {
      this.logger.error('Transfer host-key response failed')
      return false
    }
  }

  getPendingKnownHostLine(): string {
    return this.pendingKnownHostLine
  }

  cancel(): void {
    if (this.transferId.length === 0) { return }
    try {
      sshNative.sshDisconnect(this.transferId)
    } catch (e) {
      this.logger.error('Transfer cancellation failed')
    }
  }

  private handleNativeControlEvent(event: NativeControlEvent): void {
    if (!SshControlEventPolicy.isCurrent(this.transferId, this.generation, event)) {
      this.logger.warn('Rejected stale transfer control event, kind=' + event.kind)
      return
    }
    this.logger.info(SshControlEventPolicy.safeLogLabel(event))
    if (event.layer !== 'target') {
      this.logger.warn('Rejected transfer control event for layer=' + event.layer)
      return
    }
    if (event.kind === 'host_key_prompt') {
      if (!SshControlEventPolicy.isHostKeyPrompt(event)) {
        this.logger.warn('Rejected invalid transfer host-key prompt')
        return
      }
      this.pendingLayer = event.layer
      this.pendingKnownHostLine = event.knownHostLine
      this.emitEvent(SshClientMessage.withText(SshClientEvent.HOST_KEY_PROMPT, event.fingerprint))
    } else if (event.kind === 'host_key_changed') {
      let info: HostKeyChangedInfo | null = SshControlEventPolicy.hostKeyChanged(event)
      if (info === null) {
        this.logger.warn('Rejected invalid changed transfer host key')
        return
      }
      this.emitEvent(SshClientMessage.withHostKeyChanged(info))
    } else if (event.kind === 'error') {
      let error = SshControlEventPolicy.error(event)
      if (error === null) {
        this.logger.warn('Rejected invalid transfer control error')
        return
      }
      this.emitEvent(SshClientMessage.withError(error))
    } else {
      this.logger.warn('Rejected unsupported transfer control event, kind=' + event.kind)
    }
  }

  private handleNativeAuthEvent(event: NativeAuthEvent): void {
    if (!SshClient.isCurrentAuthEvent(
      this.transferId, this.generation, event.sessionId, event.generation
    )) {
      this.logger.warn('Rejected stale transfer auth event, kind=' + event.kind)
      return
    }
    if (event.layer !== 'target') {
      this.logger.warn('Rejected transfer authentication event for layer=' + event.layer)
      return
    }
    if (event.kind === 'banner') {
      this.emitEvent(SshClientMessage.withText(SshClientEvent.AUTH_BANNER, event.text))
    } else if (event.kind === 'password') {
      this.pendingLayer = event.layer
      this.waitingAuth = true
      this.emitEvent(SshClientMessage.simple(SshClientEvent.PASSWORD_PROMPT))
    } else if (event.kind === 'private_key_passphrase') {
      this.pendingLayer = event.layer
      this.waitingAuth = true
      this.emitEvent(SshClientMessage.withText(
        SshClientEvent.PRIVATE_KEY_PASSPHRASE_PROMPT, this.privateKeyPath))
    } else if (event.kind === 'challenge') {
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
      this.emitEvent(SshClientMessage.simple(SshClientEvent.AUTH_CHALLENGE))
    }
  }

  private handleNativeTransferEvent(nativeEvent: NativeFileTransferEvent): void {
    if (nativeEvent.transferId !== this.transferId || nativeEvent.paneId !== this.paneId ||
      nativeEvent.generation !== this.generation) {
      this.logger.warn('Rejected stale file transfer event, kind=' + nativeEvent.kind)
      return
    }
    let event: FileTransferProgress = new FileTransferProgress()
    event.kind = nativeEvent.kind
    event.transferId = nativeEvent.transferId
    event.paneId = nativeEvent.paneId
    event.generation = nativeEvent.generation
    event.transferredBytes = Number(nativeEvent.transferredBytes)
    event.totalBytes = Number(nativeEvent.totalBytes)
    event.code = nativeEvent.code
    event.detail = nativeEvent.detail
    if (this.progressCallback !== null) {
      this.progressCallback(event)
    }
    if (event.kind === 'completed' || event.kind === 'failed' || event.kind === 'cancelled') {
      this.transferId = ''
      this.waitingAuth = false
      this.pendingLayer = ''
      this.pendingAuthChallenge = null
    }
  }

  private emitEvent(message: SshClientMessage): void {
    if (this.eventCallback !== null) {
      this.eventCallback(message)
    }
  }
}
