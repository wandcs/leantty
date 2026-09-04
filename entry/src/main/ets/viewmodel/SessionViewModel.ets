import {
  AuthChallengeInfo,
  AuthPromptInfo,
  HostKeyChangedInfo,
  SshClient,
  SshClientEvent,
  SshClientMessage,
  SshDiagnosticInfo
} from '../model/ssh/SshClient'
import util from '@ohos.util'
import { SshConnectionSpec, SshConnectOptions, SshError, SshErrorCode } from '../common/types/SshTypes'
import { SshSession, SshSessionState } from '../model/ssh/SshSession'
import { SshKeyManager } from '../model/ssh/SshKeyManager'
import { SshEnvironment } from '../model/ssh/SshEnvironment'
import { KeyPairInfo } from '../common/types/SshKeyTypes'
import { BridgeProtocol, BridgeMessage } from '../model/bridge/BridgeProtocol'
import { CommandBarViewModel, CommandParseResult, KeyCommandResult } from './CommandBarViewModel'
import {
  CommandParser,
  ConnectionCommandProtocol,
  KeyCommandKind,
  TransferCommandResult,
  TransferDirection
} from '../model/command/CommandParser'
import {
  MoshClient,
  MoshClientEvent,
  MoshClientMessage,
  MoshError,
  MoshErrorCode,
  MoshReachability,
  MoshReachabilityInfo,
  MoshStatusInfo
} from '../model/mosh/MoshClient'
import {
  MoshEscapeEvent,
  MoshEscapeEventKind,
  MoshEscapeParser,
  MoshEscapeResult
} from '../model/mosh/MoshEscapeParser'
import { MoshPredictionMode } from '../model/mosh/MoshPredictionMode'
import { KeyCommandService, KeyCommandContext } from '../model/command/KeyCommandService'
import { Logger } from '../common/logger/Logger'
import { FileUtils } from '../common/utils/FileUtils'
import { DurableStateManager } from '../model/persistence/DurableStateManager'
import { TerminalInputAction, TerminalInputActionKind, TerminalInputParser } from '../model/terminal/TerminalInputParser'
import { TerminalMode } from '../common/types/TerminalTypes'
import { ConnectionControl } from '../model/ssh/ConnectionControl'
import {
  SshEscapeEvent,
  SshEscapeEventKind,
  SshEscapeParser,
  SshEscapeResult
} from '../model/ssh/SshEscapeParser'
import { TerminalSurfaceController } from '../model/terminal/TerminalSurfaceController'
import { LocalCommandLine } from '../model/terminal/LocalCommandLine'
import { LocalCommandOutput } from '../model/terminal/LocalCommandOutput'
import { common } from '@kit.AbilityKit'
import { KnownHostsManager } from '../model/ssh/KnownHostsManager'
import { UserGuideManager, UserGuideResult } from '../model/guide/UserGuideManager'
import { UserGuidePolicy } from '../model/guide/UserGuidePolicy'
import {
  FileTransferClient,
  FileTransferOptions,
  FileTransferProgress
} from '../model/transfer/FileTransferClient'
import { TransferFileManager, TransferLocalFile } from '../model/transfer/TransferFileManager'
import { FileTransferLifecycle, FileTransferPhase } from '../model/transfer/FileTransferLifecycle'
import { FileTransferFailurePresenter } from '../model/transfer/FileTransferFailure'
import { TerminalTextPolicy } from '../common/security/TerminalTextPolicy'
import {
  LocalCompletionEngine,
  LocalCompletionSet,
  LocalCompletionUpdate,
  LocalCompletionUpdateKind
} from '../model/terminal/LocalCompletionEngine'
import {
  LocalCompletionNavigation,
  LocalCompletionRenderer
} from '../model/terminal/LocalCompletionRenderer'

export { TerminalMode } from '../common/types/TerminalTypes'

enum KeyPassphraseChangeStage {
  NONE = 0,
  OLD_PASSPHRASE = 1,
  NEW_PASSPHRASE = 2,
  CONFIRM_NEW_PASSPHRASE = 3
}

enum KeyCommentChangeStage {
  NONE = 0,
  PASSPHRASE = 1,
  COMMENT = 2
}

export class SessionViewModel {
  private initialRecoveryNoticePending: boolean = false
  private session: SshSession = new SshSession()
  private sshClient: SshClient = new SshClient()
  private moshClient: MoshClient | null = null
  private moshReachability: MoshReachability = MoshReachability.AWAITING_PEER
  private moshUdpPortStart: number = 0
  private moshUdpPortEnd: number = 0
  private moshServerPath: string = ''
  private moshPredictionMode: MoshPredictionMode = MoshPredictionMode.ADAPTIVE
  private connectionProtocol: ConnectionCommandProtocol = ConnectionCommandProtocol.SSH
  private terminalSurface: TerminalSurfaceController | null = null
  private lastCols: number = 80
  private lastRows: number = 24
  private onStateChange: ((state: SshSessionState) => void) | null = null
  private onModeChange: ((mode: TerminalMode) => void) | null = null
  private onTitleChange: ((title: string) => void) | null = null
  private onLocalExit: (() => boolean) | null = null
  private onConfirmKeyDelete: ((name: string, fingerprint: string,
    onConfirm: () => void, onCancel: () => void) => void) | null = null
  private logger: Logger = new Logger('SessionViewModel')

  private mode: TerminalMode = TerminalMode.IDLE
  private sshEscapeParser: SshEscapeParser = new SshEscapeParser()
  private moshEscapeParser: MoshEscapeParser = new MoshEscapeParser()
  private commandLine: LocalCommandLine = new LocalCommandLine()
  private passwordBuffer: string = ''
  private hostKeyBuffer: string = ''
  private knownHostsPath: string = ''
  private commandBarVm: CommandBarViewModel = new CommandBarViewModel()
  private completionEngine: LocalCompletionEngine = new LocalCompletionEngine()
  private completionRenderer: LocalCompletionRenderer = new LocalCompletionRenderer()
  private heartbeatTimerId: number = -1
  private pendingKeyPath: string = ''
  private pendingKeyPassphrase: string = ''
  private keyPassphraseChangeStage: KeyPassphraseChangeStage = KeyPassphraseChangeStage.NONE
  private keyPassphraseChangeKeyName: string = ''
  private oldKeyPassphrase: string = ''
  private newKeyPassphrase: string = ''
  private confirmedKeyPassphrase: string = ''
  private keyCommentChangeStage: KeyCommentChangeStage = KeyCommentChangeStage.NONE
  private keyCommentChangeKeyName: string = ''
  private keyCommentPassphrase: string = ''
  private currentKeyComment: string = ''
  private newKeyComment: string = ''
  private authChallenge: AuthChallengeInfo | null = null
  private authPromptIndex: number = 0
  private authResponseBuffer: string = ''
  private authResponses: string[] = []
  private context: common.Context | null = null
  private pendingKeypush: boolean = false
  private perfInputBuffer: string = ''
  private perfPingId: string = ''
  private perfPingStartedMs: number = 0
  private perfOutputTail: string = ''
  private keypushKeyName: string = ''
  private keypushPublicKey: string = ''
  private keypushMarker: string = ''
  private keypushOutputTail: string = ''
  private keypushTimeoutId: number = -1
  private terminalFocused: boolean = false
  private outputObserverDecoder: util.TextDecoder = util.TextDecoder.create('utf-8')
  private localHelpPending: boolean = false
  private paneId: string = ''
  private fileTransferClient: FileTransferClient | null = null
  private transferCommand: TransferCommandResult | null = null
  private transferLocalFile: TransferLocalFile | null = null
  private transferLastProgressMs: number = 0
  private transferLastBytes: number = 0
  private transferProgressText: string = ''
  private transferProgressVisible: boolean = false
  private transferProgressObserved: boolean = false
  private transferSpeedObserved: boolean = false
  private transferStartedMs: number = 0
  private transferSpeedSampleMs: number = 0
  private transferSpeedSampleBytes: number = 0
  private transferSpeedBytesPerSecond: number = 0
  private transferCompletion: Promise<void> | null = null
  private resolveTransferCompletion: (() => void) | null = null
  private transferPreparationCancellation: Promise<void> | null = null
  private resolveTransferPreparationCancellation: (() => void) | null = null
  private transferLifecycle: FileTransferLifecycle = new FileTransferLifecycle()
  private transferCancellationRequested: boolean = false
  private transferControlFailureCode: string = ''
  private sshEnvironmentPreparation: Promise<void> | null = null
  private sshEnvironmentReady: boolean = false
  private sshEnvironmentCommandPending: boolean = false
  private acceptingSessionOutput: boolean = false
  private terminalResetPending: boolean = false
  private terminalBoundaryGeneration: number = 0
  private terminalResetWaiters: (() => void)[] = []

  getSession(): SshSession {
    return this.session
  }

  getSshClient(): SshClient {
    return this.sshClient
  }

  getMode(): TerminalMode {
    return this.mode
  }

  isMoshProtocol(): boolean {
    return this.connectionProtocol === ConnectionCommandProtocol.MOSH
  }

  static cancelOrphanedNativeSessions(): number {
    return MoshClient.cancelOrphanedNativeSessions()
  }

  recoverReclaimedRemoteSession(wasMosh: boolean): void {
    this.acceptingSessionOutput = false
    this.clearAuthChallenge()
    this.moshClient = null
    this.sshClient = new SshClient()
    this.session.markDisconnected()
    this.setMode(TerminalMode.IDLE)
    this.connectionProtocol = ConnectionCommandProtocol.SSH
    let writeNotice: () => void = (): void => {
      this.writeTerminal('\u001b[0m\r\n' + LocalCommandOutput.warning(
        'LeanTTY session state was reclaimed while the device was suspended. ' +
        'Workspace layout was kept; reconnect this pane to continue.') +
        '\r\n' + LocalCommandOutput.prompt())
    }
    if (wasMosh) {
      this.finishMoshTerminalOwnership(writeNotice)
    } else {
      this.finishSessionTerminalOwnership(writeNotice)
    }
    this.notifyStateChange()
  }

  setPaneIdentity(paneId: string): void {
    this.paneId = paneId
  }

  hasActiveTransfer(): boolean {
    return this.transferLifecycle.isActive()
  }

  getFileTransferPhase(): FileTransferPhase {
    return this.transferLifecycle.getPhase()
  }

  setOnStateChange(callback: (state: SshSessionState) => void): void {
    this.onStateChange = callback
  }

  setOnModeChange(callback: (mode: TerminalMode) => void): void {
    this.onModeChange = callback
  }

  setOnTitleChange(callback: (title: string) => void): void {
    this.onTitleChange = callback
  }

  setOnLocalExit(callback: () => boolean): void {
    this.onLocalExit = callback
  }

  setOnConfirmKeyDelete(
    callback: (name: string, fingerprint: string, onConfirm: () => void, onCancel: () => void) => void
  ): void {
    this.onConfirmKeyDelete = callback
  }

  loadSshConfig(context: common.Context): void {
    this.context = context
    this.knownHostsPath = FileUtils.getSshDir(context) + '/known_hosts'
  }

  bindTerminalSurface(surface: TerminalSurfaceController): void {
    this.terminalSurface = surface
    surface.setInputMasked(SessionViewModel.isSecretInputMode(this.mode))
    surface.setOnMessage((msg: BridgeMessage) => {
      this.handleBridgeMessage(msg)
    })
    surface.setOnReady((recoveredOutput: boolean) => {
      this.onBridgeReady(recoveredOutput)
    })
    surface.setOnOutputPauseChange((paused: boolean) => {
      this.applyOutputPause(paused)
    })
  }

  onTerminalSurfaceDetached(): void {
    this.stopHeartbeat()
    if (this.completionEngine.isActive()) {
      this.commandLine.setText(this.completionEngine.editingText())
    }
    this.completionRenderer.reset()
  }

  private onBridgeReady(recoveredOutput: boolean): void {
    if (this.mode === TerminalMode.IDLE && !recoveredOutput) {
      if (this.initialRecoveryNoticePending) {
        this.initialRecoveryNoticePending = false
        this.writeTerminal('\u001b[0m\r\n' + LocalCommandOutput.warning(
          'Previous LeanTTY process ended unexpectedly. Workspace layout was recovered; ' +
          'the remote session and terminal contents were not restored.') +
          '\r\n' + LocalCommandOutput.prompt())
      } else {
        this.writePrompt()
      }
    }
    this.requestTerminalFit()
    this.applyTerminalFocus()
    this.startHeartbeat()
    if (this.terminalSurface !== null) {
      this.terminalSurface.captureSnapshot()
    }
    this.logger.info(recoveredOutput ?
      'Bridge ready, terminal output recovered' : 'Bridge ready without recovered output')
  }

  writePrompt(): void {
    this.completionEngine.finishEditing()
    this.completionRenderer.reset()
    this.writeTerminal('\u001b[0m\r\n' + LocalCommandOutput.prompt())
  }

  setInitialRecoveryNotice(): void {
    this.initialRecoveryNoticePending = true
  }

  writeError(msg: string, guidance: string = ''): void {
    this.completionEngine.finishEditing()
    this.completionRenderer.reset()
    this.writeTerminal(LocalCommandOutput.error(
      SessionViewModel.terminalSafeMultilineText(msg),
      SessionViewModel.terminalSafeMultilineText(guidance)))
  }

  async connect(host: string, port: number, username: string, displayHost: string = ''): Promise<void> {
    let spec: SshConnectionSpec = new SshConnectionSpec()
    spec.host = host
    spec.port = port
    spec.username = username
    spec.displayHost = displayHost
    await this.connectResolved(spec)
  }

  private async connectResolved(spec: SshConnectionSpec): Promise<void> {
    let previousMoshClient: MoshClient | null = this.moshClient
    if (previousMoshClient !== null) {
      this.releaseMoshClient(previousMoshClient)
      await previousMoshClient.disconnect()
    }
    this.connectionProtocol = ConnectionCommandProtocol.SSH
    this.terminalBoundaryGeneration++
    this.terminalResetPending = false
    this.acceptingSessionOutput = true
    this.clearAuthChallenge()
    this.setMode(TerminalMode.CONNECTING)
    this.session.beginConnection()
    this.session.setConnectionSpec(spec)
    this.notifyStateChange()

    try {
      this.sshClient.onEvent((message: SshClientMessage) => {
        this.onSshEvent(message)
      })
      this.outputObserverDecoder = util.TextDecoder.create('utf-8')
      this.sshClient.onData((data: Uint8Array) => {
        this.onSessionData(data)
      })
      let opts: SshConnectOptions = SshConnectOptions.fromConnectionSpec(spec, this.knownHostsPath)
      if (!this.pendingKeypush) {
        let key: KeyPairInfo | null = this.resolvePrivateKey(spec.identityFile)
        if (key !== null) {
          opts.privateKeyPath = key.filePath
          opts.privateKeyRequiresPassphrase = key.hasPassphrase
        }
        if (spec.jumpHost.length > 0) {
          let jumpKey: KeyPairInfo | null = this.resolvePrivateKey(spec.jumpIdentityFile)
          if (jumpKey !== null) {
            opts.jumpPrivateKeyPath = jumpKey.filePath
            opts.jumpPrivateKeyRequiresPassphrase = jumpKey.hasPassphrase
          }
        }
      }
      await this.sshClient.connect(opts)
      this.logger.info('SSH connect initiated')
    } catch (e) {
      this.session.markFailed('' + e)
      this.setMode(TerminalMode.IDLE)
      this.logger.warn('SSH connection start failed')
      this.finishSessionTerminalOwnership(() => {
        this.writeError('The SSH connection could not start.',
          'Check the Host, network and credentials, then try again.')
      })
      this.notifyStateChange()
    }
  }

  private async connectMoshResolved(spec: SshConnectionSpec,
    udpPortStart: number = this.moshUdpPortStart,
    udpPortEnd: number = this.moshUdpPortEnd,
    serverPath: string = this.moshServerPath,
    predictionMode: MoshPredictionMode = this.moshPredictionMode): Promise<void> {
    let previousMoshClient: MoshClient | null = this.moshClient
    if (previousMoshClient !== null) {
      this.releaseMoshClient(previousMoshClient)
      await previousMoshClient.disconnect()
    }
    this.connectionProtocol = ConnectionCommandProtocol.MOSH
    this.moshUdpPortStart = udpPortStart
    this.moshUdpPortEnd = udpPortEnd
    this.moshServerPath = serverPath
    this.moshPredictionMode = predictionMode
    this.resetMoshReachability()
    this.terminalBoundaryGeneration++
    this.terminalResetPending = false
    this.acceptingSessionOutput = true
    this.clearAuthChallenge()
    this.setMode(TerminalMode.CONNECTING)
    this.session.beginConnection()
    this.session.setConnectionSpec(spec)
    this.notifyStateChange()
    let client: MoshClient = new MoshClient()
    this.moshClient = client

    try {
      client.onEvent((message: MoshClientMessage) => {
        if (!SessionViewModel.isCurrentMoshClient(this.moshClient, client)) {
          this.logger.info('Ignored stale Mosh event')
          return
        }
        this.onMoshEvent(message)
      })
      client.onData((data: Uint8Array) => {
        if (!SessionViewModel.isCurrentMoshClient(this.moshClient, client)) {
          this.logger.info('Ignored stale Mosh output')
          return
        }
        this.onMoshData(data)
      })
      let opts: SshConnectOptions = SshConnectOptions.fromConnectionSpec(spec, this.knownHostsPath)
      let key: KeyPairInfo | null = this.resolvePrivateKey(spec.identityFile)
      if (key !== null) {
        opts.privateKeyPath = key.filePath
        opts.privateKeyRequiresPassphrase = key.hasPassphrase
      }
      await client.connect(opts, serverPath, udpPortStart, udpPortEnd, predictionMode,
        this.lastCols, this.lastRows)
      this.logger.info('Mosh connect initiated udpPortPolicy=' +
        (udpPortStart === 0 ? 'dynamic' : (udpPortStart === udpPortEnd ? 'fixed' : 'range')) +
        ' serverPolicy=' + (serverPath.length === 0 ? 'default' : 'custom') +
        ' predictionMode=' + predictionMode)
    } catch (e) {
      if (!SessionViewModel.isCurrentMoshClient(this.moshClient, client)) {
        this.logger.info('Ignored stale Mosh connection start failure')
        return
      }
      this.releaseMoshClient(client)
      this.session.markFailed('' + e)
      this.setMode(TerminalMode.IDLE)
      this.logger.warn('Mosh connection start failed')
      this.finishMoshTerminalOwnership(() => {
        this.writeError('The Mosh connection could not start.',
          'Check the Host, network, credentials and mosh-server, then try again.')
      })
      this.notifyStateChange()
    }
  }

  async disconnect(): Promise<void> {
    if (this.transferLifecycle.isActive()) {
      this.requestFileTransferCancellation()
      if (this.transferCompletion !== null) {
        await this.transferCompletion
      }
    }
    let moshClient: MoshClient | null = this.moshClient
    if (moshClient !== null) {
      if (moshClient.hasActiveSession()) {
        await moshClient.disconnect()
      }
      if (SessionViewModel.isCurrentMoshClient(this.moshClient, moshClient)) {
        this.releaseMoshClient(moshClient)
        this.session.markDisconnected()
        this.setMode(TerminalMode.IDLE)
        this.finishMoshTerminalOwnership(() => {})
        this.notifyStateChange()
      }
      await this.waitForTerminalReset()
      return
    } else if (this.sshClient.hasActiveSession()) {
      await this.sshClient.disconnect()
    }
    this.acceptingSessionOutput = false
    this.terminalResetPending = false
    this.terminalBoundaryGeneration++
    this.session.markDisconnected()
    this.clearAuthChallenge()
    let cancelledKeyPassphraseChange: boolean =
      this.keyPassphraseChangeStage !== KeyPassphraseChangeStage.NONE
    this.clearKeyPassphraseChangeState()
    if (cancelledKeyPassphraseChange) {
      this.logger.info('KEY_PASSPHRASE_CHANGE result=disconnected')
    }
    let cancelledKeyCommentChange: boolean = this.keyCommentChangeStage !== KeyCommentChangeStage.NONE
    this.clearKeyCommentChangeState()
    if (cancelledKeyCommentChange) {
      this.logger.info('KEY_COMMENT_CHANGE result=disconnected')
    }
    this.setMode(TerminalMode.IDLE)
    this.releaseDisconnectedFlowControl()
    this.notifyStateChange()
  }

  async reconnect(): Promise<void> {
    let spec: SshConnectionSpec = this.session.getConnectionSpec()
    if (this.connectionProtocol === ConnectionCommandProtocol.MOSH) {
      await this.disconnect()
      this.session.beginReconnect()
      await this.connectMoshResolved(spec)
      return
    }
    let previousClient: SshClient = this.sshClient
    previousClient.onEvent(() => {})
    previousClient.onData(() => {})
    await previousClient.disconnect()
    await new Promise<void>((resolve: () => void) => {
      this.finishSessionTerminalOwnership(resolve)
    })
    this.sshClient = new SshClient()
    this.session.beginReconnect()
    await this.connectResolved(spec)
  }

  private cancelPendingConnection(): void {
    if (this.transferLifecycle.isActive()) {
      this.passwordBuffer = ''
      this.hostKeyBuffer = ''
      this.pendingKeyPassphrase = ''
      this.clearAuthChallenge()
      this.requestFileTransferCancellation()
      this.setMode(TerminalMode.TRANSFERRING)
      this.clearTransferProgress()
      this.writeTerminal('^C\r\n' + LocalCommandOutput.status('Cancelling', 'file transfer...'))
      return
    }
    let moshClient: MoshClient | null = this.moshClient
    let cancellingMosh: boolean = moshClient !== null
    if (moshClient !== null) {
      this.releaseMoshClient(moshClient)
      moshClient.disconnect()
    } else {
      this.sshClient.disconnect()
    }
    this.passwordBuffer = ''
    this.hostKeyBuffer = ''
    this.pendingKeyPassphrase = ''
    this.clearAuthChallenge()
    this.clearKeypushState()
    this.session.markDisconnected()
    this.setMode(TerminalMode.IDLE)
    let writeCancellation: () => void = () => {
      this.writeTerminal('^C')
      this.writePrompt()
    }
    if (cancellingMosh) {
      this.finishMoshTerminalOwnership(writeCancellation)
    } else {
      this.finishSessionTerminalOwnership(writeCancellation)
    }
    this.notifyStateChange()
  }

  requestTerminalFit(): void {
    if (this.terminalSurface !== null) {
      this.terminalSurface.requestFit()
    }
  }

  requestFocus(): void {
    this.terminalFocused = true
    this.applyTerminalFocus()
  }

  requestBlur(): void {
    this.dismissCompletion()
    this.terminalFocused = false
    this.applyTerminalFocus()
  }

  private applyTerminalFocus(): void {
    if (this.terminalSurface !== null) {
      if (this.terminalFocused) {
        this.terminalSurface.focus()
      } else {
        this.terminalSurface.blur()
      }
    }
  }

  applyTerminalTheme(themeJson: string): void {
    if (this.terminalSurface !== null) {
      this.terminalSurface.sendTheme(themeJson)
    }
  }

  private setMode(newMode: TerminalMode): void {
    let returningToLocalPrompt: boolean = this.mode !== TerminalMode.IDLE &&
      newMode === TerminalMode.IDLE
    if (newMode !== TerminalMode.IDLE) {
      this.completionEngine.finishEditing()
      this.completionRenderer.reset()
    }
    if (this.mode !== newMode && (this.mode === TerminalMode.CONNECTED ||
      newMode === TerminalMode.CONNECTED)) {
      this.sshEscapeParser.reset()
      this.moshEscapeParser.reset()
    }
    this.mode = newMode
    if (this.terminalSurface !== null) {
      this.terminalSurface.setInputMasked(SessionViewModel.isSecretInputMode(newMode))
    }
    if (this.onModeChange !== null) {
      this.onModeChange(newMode)
    }
    if (returningToLocalPrompt) {
      this.notifyTitleChange('ltty')
    }
  }

  private static isSecretInputMode(mode: TerminalMode): boolean {
    return mode === TerminalMode.PASSWORD_INPUT ||
      mode === TerminalMode.KEY_PASSPHRASE_INPUT ||
      mode === TerminalMode.AUTH_CHALLENGE_INPUT ||
      mode === TerminalMode.KEY_PASSPHRASE_CHANGE_INPUT ||
      mode === TerminalMode.KEY_COMMENT_PASSPHRASE_INPUT
  }

  private onSshEvent(message: SshClientMessage): void {
    let previousState: SshSessionState = this.session.getState()
    if (!this.session.handleClientMessage(message)) {
      if (message.kind === SshClientEvent.CLOSE) {
        this.onSshClose(message.exitCode)
        return
      }
      this.logger.info('Ignored SSH lifecycle event kind=' + message.kind +
        ',state=' + previousState.toString())
      return
    }
    if (this.session.getState() !== previousState) {
      this.notifyStateChange()
    }
    switch (message.kind) {
      case SshClientEvent.PASSWORD_PROMPT:
        this.setMode(TerminalMode.PASSWORD_INPUT)
        this.passwordBuffer = ''
        this.writeTerminal(SessionViewModel.formatPasswordPrompt(
          this.pendingAuthenticationLayer(), this.session.getConnectionSpec().jumpHost.length > 0))
        break
      case SshClientEvent.PRIVATE_KEY_PASSPHRASE_PROMPT:
        this.pendingKeyPassphrase = ''
        this.setMode(TerminalMode.KEY_PASSPHRASE_INPUT)
        this.writeTerminal(SessionViewModel.formatPrivateKeyPassphrasePrompt(
          message.text, this.pendingAuthenticationLayer(), this.session.getConnectionSpec().jumpHost.length > 0))
        break
      case SshClientEvent.AUTH_BANNER:
        this.writeAuthenticationText(message.text)
        break
      case SshClientEvent.AUTH_CHALLENGE:
        this.beginAuthChallenge()
        break
      case SshClientEvent.HOST_KEY_PROMPT:
        this.hostKeyBuffer = ''
        this.setMode(TerminalMode.HOST_KEY_INPUT)
        this.writeTerminal(SessionViewModel.formatHostKeyPrompt(
          message.text, this.pendingAuthenticationLayer(), this.session.getConnectionSpec().jumpHost.length > 0))
        break
      case SshClientEvent.HOST_KEY_CHANGED:
        if (message.hostKeyChanged !== null) {
          this.onHostKeyChanged(message.hostKeyChanged)
        }
        break
      case SshClientEvent.CONNECTED:
        this.clearAuthChallenge()
        this.setMode(TerminalMode.CONNECTED)
        this.onSshConnected()
        break
      case SshClientEvent.CLOSE:
        this.onSshClose(message.exitCode)
        break
      case SshClientEvent.ERROR:
        if (message.error !== null) {
          this.onSshError(message.error)
        }
        break
      case SshClientEvent.WARNING:
        this.logger.warn('SSH warning')
        break
      case SshClientEvent.DIAGNOSTIC:
        if (message.diagnostic !== null) {
          this.writeTerminal('\r\n' + SessionViewModel.formatSshDiagnostic(message.diagnostic) + '\r\n')
        }
        break
    }
  }

  private onMoshEvent(message: MoshClientMessage): void {
    if (message.kind === MoshClientEvent.STATUS) {
      if (message.status !== null) { this.onMoshStatus(message.status) }
      return
    }
    if (message.kind === MoshClientEvent.REACHABILITY) {
      if (message.reachability !== null) { this.onMoshReachability(message.reachability) }
      return
    }
    let lifecycleMessage: SshClientMessage = SessionViewModel.moshLifecycleMessage(message)
    let previousState: SshSessionState = this.session.getState()
    if (!this.session.handleClientMessage(lifecycleMessage)) {
      if (message.kind === MoshClientEvent.CLOSE) { this.onMoshClose(message.exitCode) }
      return
    }
    if (this.session.getState() !== previousState) { this.notifyStateChange() }
    switch (message.kind) {
      case MoshClientEvent.PASSWORD_PROMPT:
        this.setMode(TerminalMode.PASSWORD_INPUT)
        this.passwordBuffer = ''
        this.writeTerminal(SessionViewModel.formatPasswordPrompt('target', false))
        break
      case MoshClientEvent.PRIVATE_KEY_PASSPHRASE_PROMPT:
        this.pendingKeyPassphrase = ''
        this.setMode(TerminalMode.KEY_PASSPHRASE_INPUT)
        this.writeTerminal(SessionViewModel.formatPrivateKeyPassphrasePrompt(message.text, 'target', false))
        break
      case MoshClientEvent.AUTH_BANNER:
        this.writeAuthenticationText(message.text)
        break
      case MoshClientEvent.AUTH_CHALLENGE:
        this.beginAuthChallenge()
        break
      case MoshClientEvent.HOST_KEY_PROMPT:
        this.hostKeyBuffer = ''
        this.setMode(TerminalMode.HOST_KEY_INPUT)
        this.writeTerminal(SessionViewModel.formatHostKeyPrompt(message.text, 'target', false))
        break
      case MoshClientEvent.HOST_KEY_CHANGED:
        if (message.hostKeyChanged !== null) { this.onMoshHostKeyChanged(message.hostKeyChanged) }
        break
      case MoshClientEvent.CONNECTED:
        this.clearAuthChallenge()
        this.setMode(TerminalMode.CONNECTED)
        this.onMoshConnected()
        break
      case MoshClientEvent.CLOSE:
        this.onMoshClose(message.exitCode)
        break
      case MoshClientEvent.ERROR:
        if (message.error !== null) { this.onMoshError(message.error) }
        break
    }
  }

  private static moshLifecycleMessage(message: MoshClientMessage): SshClientMessage {
    if (message.kind === MoshClientEvent.PASSWORD_PROMPT) {
      return SshClientMessage.simple(SshClientEvent.PASSWORD_PROMPT)
    }
    if (message.kind === MoshClientEvent.PRIVATE_KEY_PASSPHRASE_PROMPT) {
      return SshClientMessage.withText(SshClientEvent.PRIVATE_KEY_PASSPHRASE_PROMPT, message.text)
    }
    if (message.kind === MoshClientEvent.AUTH_BANNER) {
      return SshClientMessage.withText(SshClientEvent.AUTH_BANNER, message.text)
    }
    if (message.kind === MoshClientEvent.AUTH_CHALLENGE) {
      return SshClientMessage.simple(SshClientEvent.AUTH_CHALLENGE)
    }
    if (message.kind === MoshClientEvent.HOST_KEY_PROMPT) {
      return SshClientMessage.withText(SshClientEvent.HOST_KEY_PROMPT, message.text)
    }
    if (message.kind === MoshClientEvent.HOST_KEY_CHANGED && message.hostKeyChanged !== null) {
      return SshClientMessage.withHostKeyChanged(message.hostKeyChanged)
    }
    if (message.kind === MoshClientEvent.CONNECTED) {
      return SshClientMessage.simple(SshClientEvent.CONNECTED)
    }
    if (message.kind === MoshClientEvent.CLOSE) {
      return SshClientMessage.close(message.exitCode)
    }
    return SshClientMessage.withError(new SshError(
      SshErrorCode.Internal, 'Mosh session failed', '', 'target'))
  }

  private onMoshStatus(info: MoshStatusInfo): void {
    if (this.mode !== TerminalMode.CONNECTING || info.status !== 'started') { return }
    if (info.stage === 'mosh_bootstrap') {
      this.writeTerminal(LocalCommandOutput.status('Mosh', 'Starting mosh-server...') + '\r\n')
    } else if (info.stage === 'mosh_udp') {
      this.writeTerminal(LocalCommandOutput.status('Mosh', 'Connecting UDP Session...') + '\r\n')
    }
  }

  private onMoshReachability(info: MoshReachabilityInfo): void {
    if (!this.acceptingSessionOutput || this.moshClient === null) { return }
    let previousReachability: MoshReachability = this.moshReachability
    this.moshReachability = info.state
    if (info.state === MoshReachability.AWAITING_PEER) {
      this.logger.info('Mosh reachability state=awaiting_peer')
      return
    }
    if (info.state === MoshReachability.INTERRUPTED) {
      let previousState: SshSessionState = this.session.getState()
      if (!this.session.markInterrupted()) {
        this.logger.info('Ignored Mosh reachability state=interrupted sessionState=' +
          previousState.toString())
        return
      }
      if (this.session.getState() !== previousState) { this.notifyStateChange() }
      this.logger.warn('Mosh reachability state=interrupted reason=' + info.reason)
      return
    }
    if (previousReachability === MoshReachability.INTERRUPTED) {
      let previousState: SshSessionState = this.session.getState()
      if (this.session.markResponsive() && this.session.getState() !== previousState) {
        this.notifyStateChange()
      }
      this.logger.info('Mosh reachability state=responsive transition=recovered')
      return
    }
    this.logger.info('Mosh reachability state=responsive')
  }

  private resetMoshReachability(): void {
    this.moshReachability = MoshReachability.AWAITING_PEER
  }

  private onMoshConnected(): void {
    let connectedTitle: string = this.session.getConnectionTitle()
    this.notifyTitleChange(connectedTitle)
    if (this.moshClient !== null) {
      this.moshClient.setOutputPaused(
        this.terminalSurface !== null && this.terminalSurface.isOutputPaused())
    }
    if (this.terminalSurface !== null) {
      this.terminalSurface.beginMoshSessionPage()
    }
    this.logger.info('Mosh Session connected')
  }

  private onSshConnected(): void {
    if (this.pendingKeypush) {
      this.executeKeypushCommand()
      return
    }
    let connectedTitle: string = this.session.getConnectionTitle()
    this.logger.info('SSH session connected')
    this.notifyTitleChange(connectedTitle)
    this.sshClient.resize(this.lastCols, this.lastRows)
    this.applyOutputPause(this.terminalSurface !== null && this.terminalSurface.isOutputPaused())
    this.logger.info('SSH session connected, pty resized to ' +
      this.lastCols.toString() + 'x' + this.lastRows.toString())
  }

  private writeTerminal(data: string): void {
    if (this.terminalSurface !== null) {
      this.terminalSurface.write(data)
    }
  }

  private writeTerminalBytes(data: Uint8Array): void {
    if (this.terminalSurface !== null) {
      this.terminalSurface.writeBytes(data)
    }
  }

  private releaseDisconnectedFlowControl(): void {
    if (this.terminalSurface !== null) {
      this.terminalSurface.releaseDisconnectedFlowControl()
    }
  }

  private finishSessionTerminalOwnership(onReset: () => void): void {
    this.acceptingSessionOutput = false
    this.releaseDisconnectedFlowControl()
    this.terminalBoundaryGeneration++
    let boundaryGeneration: number = this.terminalBoundaryGeneration
    this.terminalResetPending = true
    this.logger.info('SESSION_RESET stage=started generation=' + boundaryGeneration.toString())
    let completeReset: () => void = () => {
      if (boundaryGeneration !== this.terminalBoundaryGeneration) {
        this.logger.info('SESSION_RESET stage=ignored generation=' + boundaryGeneration.toString())
        return
      }
      this.terminalResetPending = false
      this.completeTerminalResetWaiters()
      this.logger.info('SESSION_RESET stage=completed generation=' + boundaryGeneration.toString())
    }
    if (this.terminalSurface === null) {
      this.logger.info('SESSION_RESET stage=surface-absent generation=' + boundaryGeneration.toString())
      onReset()
      completeReset()
      return
    }
    this.terminalSurface.resetSessionState(() => {
      if (boundaryGeneration === this.terminalBoundaryGeneration) {
        this.logger.info('SESSION_RESET stage=local-output generation=' + boundaryGeneration.toString())
        onReset()
      }
    }, completeReset)
  }

  private finishMoshTerminalOwnership(onReset: () => void): void {
    this.acceptingSessionOutput = false
    this.releaseDisconnectedFlowControl()
    this.terminalBoundaryGeneration++
    let boundaryGeneration: number = this.terminalBoundaryGeneration
    this.terminalResetPending = true
    let completeReset: () => void = () => {
      if (boundaryGeneration !== this.terminalBoundaryGeneration) {
        return
      }
      this.terminalResetPending = false
      this.completeTerminalResetWaiters()
      this.logger.info('MOSH_PAGE stage=ownership-released generation=' + boundaryGeneration.toString())
    }
    if (this.terminalSurface === null) {
      onReset()
      completeReset()
      return
    }
    this.terminalSurface.endMoshSessionPage(() => {
      if (boundaryGeneration === this.terminalBoundaryGeneration) {
        onReset()
      }
    }, completeReset)
  }

  private waitForTerminalReset(): Promise<void> {
    if (!this.terminalResetPending) {
      return Promise.resolve()
    }
    return new Promise<void>((resolve: () => void) => {
      this.terminalResetWaiters.push(resolve)
    })
  }

  private completeTerminalResetWaiters(): void {
    let waiters: (() => void)[] = this.terminalResetWaiters
    this.terminalResetWaiters = []
    for (let i = 0; i < waiters.length; i++) {
      waiters[i]()
    }
  }

  private applyOutputPause(paused: boolean): void {
    if (this.moshClient !== null) {
      this.moshClient.setOutputPaused(paused)
    } else {
      this.sshClient.setOutputPaused(paused)
    }
  }

  private onSessionData(data: Uint8Array): void {
    if (!this.acceptingSessionOutput) {
      return
    }
    this.observeSessionOutput(data, true)
    this.writeTerminalBytes(data)
  }

  private onMoshData(data: Uint8Array): void {
    if (!this.acceptingSessionOutput) {
      return
    }
    this.observeSessionOutput(data, false)
    if (this.terminalSurface !== null) {
      this.terminalSurface.writeMoshBytes(data)
    }
  }

  private observeSessionOutput(data: Uint8Array, includeKeypush: boolean): void {
    let observedText: string = this.outputObserverDecoder.decodeToString(data, { stream: true })
    this.observePerfOutput(observedText)
    if (includeKeypush) {
      this.observeKeypushOutput(observedText)
    }
  }

  private observePerfOutput(data: string): void {
    let combined: string = this.perfOutputTail + data
    if (this.perfPingId.length > 0 && combined.indexOf(this.perfPingId) >= 0) {
      let elapsed: number = Date.now() - this.perfPingStartedMs
      this.logger.info('PERF ping id=' + this.perfPingId + ' rttMs=' + elapsed.toString())
      this.perfPingId = ''
      this.perfPingStartedMs = 0
    }
    this.perfOutputTail = combined.length > 256 ? combined.substring(combined.length - 256) : combined
  }

  private observePerfInput(data: string): void {
    for (let i = 0; i < data.length; i++) {
      let ch: string = data.charAt(i)
      if (ch === '\r' || ch === '\n') {
        if (this.perfInputBuffer.startsWith('echo LTTY_PERF_PING_')) {
          this.perfPingId = this.perfInputBuffer.substring(5)
          this.perfPingStartedMs = Date.now()
          this.perfOutputTail = ''
        }
        this.perfInputBuffer = ''
      } else if (ch.charCodeAt(0) >= 32 && ch.charCodeAt(0) < 127) {
        this.perfInputBuffer += ch
        if (this.perfInputBuffer.length > 256) {
          this.perfInputBuffer = this.perfInputBuffer.substring(this.perfInputBuffer.length - 256)
        }
      }
    }
  }

  private onSshClose(exitCode: number): void {
    if (!this.acceptingSessionOutput) {
      this.logger.info('SSH closed, exitCode=' + exitCode.toString() +
        ', terminal ownership already released')
      return
    }
    this.clearAuthChallenge()
    if (this.pendingKeypush) {
      this.failKeypush('Connection closed before key installation completed.')
      return
    }
    this.pendingKeypush = false
    this.keypushPublicKey = ''
    this.setMode(TerminalMode.IDLE)
    this.finishSessionTerminalOwnership(() => {
      this.writeTerminal('\r\n' + ConnectionControl.describeClose(exitCode))
      this.writePrompt()
      if (this.terminalSurface !== null) {
        this.terminalSurface.captureSnapshot()
      }
    })
    this.logger.info('SSH closed, exitCode=' + exitCode.toString())
  }

  private onMoshClose(exitCode: number): void {
    if (!this.acceptingSessionOutput) { return }
    this.clearAuthChallenge()
    let client: MoshClient | null = this.moshClient
    if (client !== null) { this.releaseMoshClient(client) }
    this.setMode(TerminalMode.IDLE)
    this.finishMoshTerminalOwnership(() => {
      this.writeTerminal('\r\n' + LocalCommandOutput.status('Mosh',
        exitCode === 0 ? 'Session closed.' : 'Session ended unexpectedly.'))
      this.writePrompt()
      if (this.terminalSurface !== null) { this.terminalSurface.captureSnapshot() }
    })
    this.logger.info('Mosh Session closed')
  }

  private onMoshError(error: MoshError): void {
    if (!this.acceptingSessionOutput) { return }
    this.clearAuthChallenge()
    let client: MoshClient | null = this.moshClient
    if (client !== null) { this.releaseMoshClient(client) }
    this.setMode(TerminalMode.IDLE)
    this.logger.warn('Mosh error stage=' +
      (['authentication', 'mosh_bootstrap', 'mosh_udp', 'client'].indexOf(error.stage) >= 0 ?
        error.stage : 'rejected'))
    this.finishMoshTerminalOwnership(() => {
      this.writeError('The Mosh connection failed.',
        'Check the Host, network, credentials and mosh-server, then try again.')
      if (this.terminalSurface !== null) { this.terminalSurface.captureSnapshot() }
    })
  }

  private onInternalSessionError(detail: string): void {
    if (this.moshClient !== null) {
      this.onMoshError(new MoshError(MoshErrorCode.INTERNAL, detail, detail, 'client'))
    } else {
      this.onSshEvent(SshClientMessage.withError(
        new SshError(SshErrorCode.Internal, detail, detail, 'client')))
    }
  }

  private onSshError(error: SshError): void {
    if (!this.acceptingSessionOutput) {
      return
    }
    this.clearAuthChallenge()
    if (this.pendingKeypush) {
      this.logger.warn('Key installation SSH error')
      this.failKeypush('Key installation failed.\r\nCheck the Host, network and credentials, then try again.')
      return
    }
    this.pendingKeypush = false
    this.keypushPublicKey = ''
    this.setMode(TerminalMode.IDLE)
    this.logger.warn(SessionViewModel.safeSshErrorLogLabel(error))
    this.finishSessionTerminalOwnership(() => {
      this.writeError(SessionViewModel.sshFailureTitle(error.layer),
        'Check the Host, network and credentials, then try again.')
      if (this.terminalSurface !== null) {
        this.terminalSurface.captureSnapshot()
      }
    })
  }

  private onHostKeyChanged(info: HostKeyChangedInfo): void {
    this.clearKeypushState()
    let rejectedClient: SshClient = this.sshClient
    rejectedClient.onEvent(() => {})
    rejectedClient.onData(() => {})
    this.sshClient = new SshClient()
    this.setMode(TerminalMode.IDLE)
    this.finishSessionTerminalOwnership(() => {
      this.writeError(SessionViewModel.buildHostKeyChangedWarning(
        info.host, info.port, info.algorithm, info.oldFingerprint, info.newFingerprint,
        this.session.getConnectionSpec().jumpHost.length > 0 ? info.layer : ''))
    })
  }

  private onMoshHostKeyChanged(info: HostKeyChangedInfo): void {
    let rejectedClient: MoshClient | null = this.moshClient
    if (rejectedClient !== null) {
      this.releaseMoshClient(rejectedClient)
      rejectedClient.disconnect()
    }
    this.setMode(TerminalMode.IDLE)
    this.finishMoshTerminalOwnership(() => {
      this.writeError(SessionViewModel.buildHostKeyChangedWarning(
        info.host, info.port, info.algorithm, info.oldFingerprint, info.newFingerprint))
    })
  }

  private releaseMoshClient(client: MoshClient): void {
    client.onEvent(() => {})
    client.onData(() => {})
    if (SessionViewModel.isCurrentMoshClient(this.moshClient, client)) {
      this.moshClient = null
      this.resetMoshReachability()
    }
  }

  static isCurrentMoshClient(currentClient: MoshClient | null, sourceClient: MoshClient): boolean {
    return currentClient === sourceClient
  }

  static buildHostKeyChangedWarning(host: string, port: number, algorithm: string,
    oldFingerprint: string, newFingerprint: string, layer: string = ''): string {
    let target: string = KnownHostsManager.formatTarget(host, port)
    let layerLabel: string = layer === 'jump' ? 'Jump host' : (layer === 'target' ? 'Target host' : 'Remote host')
    return layerLabel + ' identification has changed.\r\n\r\n' +
      'Host: ' + target + '\r\n' +
      'Stored ' + algorithm + ' fingerprint:\r\n  ' + oldFingerprint + '\r\n\r\n' +
      'Received ' + algorithm + ' fingerprint:\r\n  ' + newFingerprint + '\r\n\r\n' +
      'The connection was stopped. The server may have been reinstalled,\r\n' +
      'or someone may be intercepting the connection.\r\n\r\n' +
      'Verify the new fingerprint through another trusted channel.\r\n\r\n' +
      'To remove the stored host key, run:\r\n  ssh-keygen -R ' + target + '\r\n\r\n' +
      'Then reconnect and confirm the new fingerprint.'
  }

  static sshFailureTitle(layer: string): string {
    if (layer === 'jump') {
      return 'The jump host connection failed.'
    }
    if (layer === 'target') {
      return 'The target host connection failed.'
    }
    return 'The SSH connection failed.'
  }

  static formatSshDiagnostic(info: SshDiagnosticInfo): string {
    let layer: string = info.layer === 'jump' ? 'Jump' : (info.layer === 'target' ? 'Target' : '')
    let stage: string = ''
    if (info.stage === 'connect') { stage = 'transport' }
    else if (info.stage === 'host_key') { stage = 'host key verification' }
    else if (info.stage === 'authentication') { stage = 'authentication' }
    else if (info.stage === 'tunnel') { stage = 'jump tunnel' }
    else if (info.stage === 'channel') { stage = 'session channel' }
    else if (info.stage === 'pty') { stage = 'PTY request' }
    else if (info.stage === 'shell') { stage = 'shell request' }
    else if (info.stage === 'session') { stage = 'session' }
    else if (info.stage === 'keepalive') { stage = 'keepalive' }
    let status: string = info.status.replace('_', ' ')
    let fixedFailure: string = ''
    if (info.reason === 'name_resolution') { fixedFailure = 'name resolution: failed.' }
    else if (info.reason === 'tcp_refused') { fixedFailure = 'TCP connection: refused.' }
    else if (info.reason === 'tcp_timeout') { fixedFailure = 'TCP connection: timed out.' }
    else if (info.reason === 'tcp_failed') { fixedFailure = 'TCP connection: failed.' }
    else if (info.reason === 'ssh_version') { fixedFailure = 'SSH version exchange: failed.' }
    else if (info.reason === 'key_exchange') { fixedFailure = 'key exchange: failed.' }
    else if (info.reason === 'transport_failed') { fixedFailure = 'transport: failed.' }
    if (fixedFailure.length > 0 && info.stage === 'connect' && info.status === 'failed' && layer.length > 0) {
      return LocalCommandOutput.status('SSH', layer + ' ' + fixedFailure)
    }
    if (layer.length === 0 || stage.length === 0 ||
      ['started', 'waiting', 'succeeded', 'failed', 'timed out', 'cancelled', 'closed'].indexOf(status) < 0 ||
      info.reason.length > 0) {
      return LocalCommandOutput.status('SSH', 'Diagnostic event rejected.')
    }
    return LocalCommandOutput.status('SSH', layer + ' ' + stage + ': ' + status + '.')
  }

  static safeSshErrorLogLabel(error: SshError): string {
    let safeFailures: RegExp = /^(authentication was rejected|no supported authentication method is available|connection timed out after \d+ ms|direct-tcpip failed|direct-tcpip timed out after \d+ ms|SSH keepalive timed out.*)$/
    if ((error.layer === 'jump' || error.layer === 'target') && safeFailures.test(error.detail)) {
      return 'SSH error: ' + error.layer + ':' + error.detail
    }
    return 'SSH error'
  }

  private notifyStateChange(): void {
    if (this.onStateChange !== null) {
      this.onStateChange(this.session.getState())
    }
  }

  private handleBridgeMessage(msg: BridgeMessage): void {
    switch (msg.kind) {
      case BridgeProtocol.KIND_TERMINAL:
        if (msg.channel !== BridgeProtocol.CHANNEL_DATA) {
          break
        }
        this.logger.info('D: ' + msg.payload.length.toString() + ' chars, mode=' + this.mode.toString())
        this.handleTerminalInput(msg.payload)
        break
      case BridgeProtocol.KIND_RESIZE:
        if (msg.channel !== BridgeProtocol.CHANNEL_CONTROL) {
          break
        }
        let dims: number[] = BridgeProtocol.parseResizePayload(msg.payload)
        if (dims.length === 2) {
          this.lastCols = dims[0]
          this.lastRows = dims[1]
          if (this.mode === TerminalMode.IDLE && this.completionEngine.isActive()) {
            this.redrawLocalCommandLine()
          }
          if (this.moshClient !== null && this.moshClient.isConnected()) {
            this.moshClient.resize(dims[0], dims[1])
            this.logger.info('Mosh terminal resized: ' + dims[0].toString() + 'x' + dims[1].toString())
          } else if (this.sshClient.isConnected()) {
            this.sshClient.resize(dims[0], dims[1])
            this.logger.info('Terminal resized: ' + dims[0].toString() + 'x' + dims[1].toString())
          }
        }
        break
      case BridgeProtocol.KIND_INTERACTIVE_READY:
        if (msg.channel === BridgeProtocol.CHANNEL_CONTROL && msg.payload.length === 0) {
          this.beginSshEnvironmentPreparation()
        }
        break
      default:
        break
    }
  }

  handleTerminalInput(data: string): void {
    if (this.requestRuntimeRecoveryBeforeIdleInput()) {
      return
    }
    if (this.terminalResetPending) {
      return
    }
    if (this.mode === TerminalMode.KEY_PASSPHRASE_CHANGE_INPUT && data === '\u0003') {
      this.cancelKeyPassphraseChange()
      return
    }
    if ((this.mode === TerminalMode.KEY_COMMENT_PASSPHRASE_INPUT ||
      this.mode === TerminalMode.KEY_COMMENT_INPUT) && data === '\u0003') {
      this.cancelKeyCommentChange()
      return
    }
    if (ConnectionControl.shouldInterrupt(this.mode, data)) {
      this.cancelPendingConnection()
      return
    }
    if (this.mode === TerminalMode.CONNECTED) {
      this.handleConnectedInput(data)
      return
    }

    if (this.mode === TerminalMode.IDLE) {
      this.handleIdleInput(data)
      return
    }

    if (this.mode === TerminalMode.PASSWORD_INPUT) {
      this.handlePasswordInput(data)
      return
    }

    if (this.mode === TerminalMode.HOST_KEY_INPUT) {
      this.handleHostKeyInput(data)
      return
    }

    if (this.mode === TerminalMode.KEY_PASSPHRASE_INPUT) {
      this.handleKeyPassphraseInput(data)
      return
    }

    if (this.mode === TerminalMode.AUTH_CHALLENGE_INPUT) {
      this.handleAuthChallengeInput(data)
      return
    }

    if (this.mode === TerminalMode.KEY_PASSPHRASE_CHANGE_INPUT) {
      this.handleKeyPassphraseChangeInput(data)
      return
    }

    if (this.mode === TerminalMode.KEY_COMMENT_PASSPHRASE_INPUT ||
      this.mode === TerminalMode.KEY_COMMENT_INPUT) {
      this.handleKeyCommentChangeInput(data)
      return
    }

    if (this.mode === TerminalMode.CONNECTING) {
      return
    }
  }

  private requestRuntimeRecoveryBeforeIdleInput(): boolean {
    if (this.mode !== TerminalMode.IDLE) {
      return false
    }
    let activePaneId: string = AppStorage.get<string>('activePaneId') ?? ''
    let expectedPaneIds: string = AppStorage.get<string>('activeRemotePaneIds') ?? ''
    if (activePaneId.length === 0 || this.paneId !== activePaneId ||
      expectedPaneIds.split('|').indexOf(activePaneId) < 0) {
      return false
    }
    let token: number = AppStorage.get<number>('runtimeRecoveryRequestToken') ?? 0
    AppStorage.setOrCreate('runtimeRecoveryRequestPaneId', activePaneId)
    this.logger.warn('Terminal input withheld for runtime recovery')
    AppStorage.setOrCreate('runtimeRecoveryRequestToken', token + 1)
    return true
  }

  private handleConnectedInput(data: string): void {
    if (this.moshClient !== null) {
      let result: MoshEscapeResult = this.moshEscapeParser.consume(data)
      for (let index: number = 0; index < result.events.length; index++) {
        let event: MoshEscapeEvent = result.events[index]
        if (event.kind === MoshEscapeEventKind.REMOTE_DATA) {
          this.moshClient.write(event.data)
        } else if (event.kind === MoshEscapeEventKind.DISCONNECT) {
          this.logger.info('Mosh escape action=disconnect')
          this.moshClient.disconnect()
          return
        } else if (event.kind === MoshEscapeEventKind.HELP) {
          this.writeTerminal('\r\nSupported Mosh escapes:\r\n' +
            '  Ctrl-^ .  Disconnect\r\n' +
            '  Ctrl-^ ?  Show this help\r\n' +
            '  Ctrl-^ Ctrl-^  Send a literal Ctrl-^\r\n')
        }
      }
      return
    }
    let result: SshEscapeResult = this.sshEscapeParser.consume(data)
    for (let index = 0; index < result.events.length; index++) {
      let event: SshEscapeEvent = result.events[index]
      if (event.kind === SshEscapeEventKind.REMOTE_DATA) {
        this.observePerfInput(event.data)
        this.sshClient.write(event.data)
      } else if (event.kind === SshEscapeEventKind.DISCONNECT) {
        this.logger.info('SSH escape action=disconnect')
        this.sshClient.disconnect()
        return
      } else if (event.kind === SshEscapeEventKind.HELP) {
        this.writeTerminal('\r\nSupported SSH escapes (after a newline):\r\n' +
          '  ~.  Disconnect\r\n' +
          '  ~?  Show this help\r\n' +
          '  ~I  Show connection information\r\n' +
          '  ~~  Send a literal ~\r\n')
        this.logger.info('SSH escape action=help')
      } else if (event.kind === SshEscapeEventKind.CONNECTION_INFO) {
        this.writeTerminal('\r\n' + this.sshConnectionInfo() + '\r\n')
        this.logger.info('SSH escape action=connection-info')
      }
    }
  }

  private sshConnectionInfo(): string {
    let spec: SshConnectionSpec = this.session.getConnectionSpec()
    let targetHost: string = spec.displayHost.length > 0 ? spec.displayHost : spec.host
    let jumpHost: string = spec.jumpDisplayHost.length > 0 ? spec.jumpDisplayHost : spec.jumpHost
    return SessionViewModel.formatSshConnectionInfo(
      spec.username, targetHost, spec.port, spec.jumpUsername, jumpHost, spec.jumpPort)
  }

  static formatSshConnectionInfo(targetUser: string, targetHost: string, targetPort: number,
    jumpUser: string = '', jumpHost: string = '', jumpPort: number = 22): string {
    let text: string = 'Target: ' + SessionViewModel.formatSshDisplayEndpoint(
      targetUser, targetHost, targetPort)
    if (jumpHost.length > 0) {
      text += '\r\nJump: ' + SessionViewModel.formatSshDisplayEndpoint(jumpUser, jumpHost, jumpPort)
    }
    return text + '\r\nState: connected'
  }

  private static formatSshDisplayEndpoint(user: string, host: string, port: number): string {
    let endpoint: string = host.indexOf(':') >= 0 ? '[' + host + ']:' + port.toString() :
      host + ':' + port.toString()
    return SessionViewModel.terminalSafeText(user + '@' + endpoint)
  }

  private handleIdleInput(data: string): void {
    if (this.localHelpPending || this.sshEnvironmentCommandPending) {
      return
    }
    let actions: TerminalInputAction[] = TerminalInputParser.parse(data, true)
    for (let i = 0; i < actions.length; i++) {
      let action: TerminalInputAction = actions[i]
      if (action.kind === TerminalInputActionKind.SUBMIT) {
        if (this.completionEngine.isMenuActive()) {
          this.commandLine.setText(this.completionEngine.accept().text)
          this.redrawLocalCommandLine()
        } else {
          this.dismissCompletion()
          this.completionEngine.finishEditing()
          this.executeCommandBuffer()
        }
      } else if (action.kind === TerminalInputActionKind.INTERRUPT) {
        this.dismissCompletion()
        this.commandLine.clear()
        this.completionRenderer.reset()
        this.writeTerminal('^C\r\n')
        this.writePrompt()
      } else if (action.kind === TerminalInputActionKind.BACKSPACE) {
        let completionWasActive: boolean = this.finishCompletionForEditing()
        if (this.commandLine.getCursor() === 0) {
          if (completionWasActive) { this.redrawLocalCommandLine() }
          continue
        }
        if (this.commandLine.backspace() !== null) {
          this.redrawLocalCommandLine()
        }
      } else if (action.kind === TerminalInputActionKind.DELETE) {
        let completionWasActive: boolean = this.finishCompletionForEditing()
        if (this.commandLine.getCursor() === this.commandLine.getText().length) {
          if (completionWasActive) { this.redrawLocalCommandLine() }
          continue
        }
        if (this.commandLine.delete() !== null) {
          this.redrawLocalCommandLine()
        }
      } else if (action.kind === TerminalInputActionKind.TAB) {
        this.tabComplete(1)
      } else if (action.kind === TerminalInputActionKind.REVERSE_TAB) {
        this.tabComplete(-1)
      } else if (action.kind === TerminalInputActionKind.ESCAPE) {
        this.dismissCompletion()
      } else if (action.kind === TerminalInputActionKind.HISTORY_PREVIOUS) {
        if (this.completionEngine.isMenuActive()) {
          this.navigateCompletion(LocalCompletionNavigation.UP)
        } else {
          this.dismissCompletion()
          this.navigateHistory(-1)
        }
      } else if (action.kind === TerminalInputActionKind.HISTORY_NEXT) {
        if (this.completionEngine.isMenuActive()) {
          this.navigateCompletion(LocalCompletionNavigation.DOWN)
        } else {
          this.dismissCompletion()
          this.navigateHistory(1)
        }
      } else if (action.kind === TerminalInputActionKind.CURSOR_LEFT) {
        if (this.completionEngine.isMenuActive()) {
          this.navigateCompletion(LocalCompletionNavigation.LEFT)
        } else {
          this.dismissCompletion()
          if (this.commandLine.moveLeft()) {
            this.redrawLocalCommandLine()
          }
        }
      } else if (action.kind === TerminalInputActionKind.CURSOR_RIGHT) {
        if (this.completionEngine.isMenuActive()) {
          this.navigateCompletion(LocalCompletionNavigation.RIGHT)
        } else {
          this.dismissCompletion()
          if (this.commandLine.moveRight()) {
            this.redrawLocalCommandLine()
          }
        }
      } else if (action.kind === TerminalInputActionKind.TEXT) {
        if (!this.consumeRepeatedDirectorySeparator(action.text)) {
          this.finishCompletionForEditing()
          this.commandLine.insert(action.text)
          this.redrawLocalCommandLine()
        }
      }
    }
  }

  private handlePasswordInput(data: string): void {
    this.handleBufferedInput(data, this.passwordBuffer, (v) => { this.passwordBuffer = v }, () => { this.submitPassword() }, '*')
  }

  private handleHostKeyInput(data: string): void {
    this.handleBufferedInput(data, this.hostKeyBuffer, (v) => { this.hostKeyBuffer = v }, () => { this.submitHostKeyDecision() }, '', (c: number) => c < 127)
  }

  private handleKeyPassphraseInput(data: string): void {
    this.handleBufferedInput(data, this.pendingKeyPassphrase, (v) => { this.pendingKeyPassphrase = v }, () => { this.submitKeyPassphrase() }, '*')
  }

  private handleAuthChallengeInput(data: string): void {
    if (this.authChallenge === null || this.authPromptIndex >= this.authChallenge.prompts.length) {
      this.onInternalSessionError('Invalid keyboard-interactive prompt state')
      return
    }
    let prompt: AuthPromptInfo = this.authChallenge.prompts[this.authPromptIndex]
    this.handleBufferedInput(
      data,
      this.authResponseBuffer,
      (value: string) => { this.authResponseBuffer = value },
      () => { this.submitAuthChallengeResponse() },
      prompt.echo ? '' : '*'
    )
  }

  private handleKeyPassphraseChangeInput(data: string): void {
    if (this.keyPassphraseChangeStage === KeyPassphraseChangeStage.OLD_PASSPHRASE) {
      this.handleBufferedInput(data, this.oldKeyPassphrase, (value: string) => {
        this.oldKeyPassphrase = value
      }, () => { this.submitKeyPassphraseChangeStage() }, null)
    } else if (this.keyPassphraseChangeStage === KeyPassphraseChangeStage.NEW_PASSPHRASE) {
      this.handleBufferedInput(data, this.newKeyPassphrase, (value: string) => {
        this.newKeyPassphrase = value
      }, () => { this.submitKeyPassphraseChangeStage() }, null)
    } else if (this.keyPassphraseChangeStage === KeyPassphraseChangeStage.CONFIRM_NEW_PASSPHRASE) {
      this.handleBufferedInput(data, this.confirmedKeyPassphrase, (value: string) => {
        this.confirmedKeyPassphrase = value
      }, () => { this.submitKeyPassphraseChangeStage() }, null)
    }
  }

  private handleKeyCommentChangeInput(data: string): void {
    if (this.keyCommentChangeStage === KeyCommentChangeStage.PASSPHRASE) {
      this.handleBufferedInput(data, this.keyCommentPassphrase, (value: string) => {
        this.keyCommentPassphrase = value
      }, () => { this.submitKeyCommentPassphrase() }, null)
    } else if (this.keyCommentChangeStage === KeyCommentChangeStage.COMMENT) {
      this.handleBufferedInput(data, this.newKeyComment, (value: string) => {
        this.newKeyComment = value
      }, () => { this.submitKeyCommentChange() }, '', (code: number): boolean => code >= 32 && code !== 127)
    }
  }

  private handleBufferedInput(
    data: string,
    buffer: string,
    setBuffer: (v: string) => void,
    onSubmit: () => void,
    echo: string | null,
    textFilter?: (code: number) => boolean
  ): void {
    let actions: TerminalInputAction[] = TerminalInputParser.parse(data, false)
    let currentBuffer: string = buffer
    for (let i = 0; i < actions.length; i++) {
      let action: TerminalInputAction = actions[i]
      if (action.kind === TerminalInputActionKind.SUBMIT) {
        onSubmit()
        return
      } else if (action.kind === TerminalInputActionKind.BACKSPACE) {
        if (currentBuffer.length > 0) {
          currentBuffer = currentBuffer.substring(0, currentBuffer.length - 1)
          setBuffer(currentBuffer)
          if (echo !== null) {
            this.writeTerminal('\b \b')
          }
        }
      } else if (action.kind === TerminalInputActionKind.TEXT) {
        let accepted: boolean = true
        if (textFilter !== undefined) {
          for (let textIndex: number = 0; textIndex < action.text.length; textIndex++) {
            if (!textFilter(action.text.charCodeAt(textIndex))) {
              accepted = false
              break
            }
          }
        }
        if (!accepted) { continue }
        currentBuffer += action.text
        setBuffer(currentBuffer)
        if (echo !== null) {
          this.writeTerminal(echo.length > 0 ? echo : action.text)
        }
      }
    }
  }

  private submitHostKeyDecision(): void {
    if (this.mode !== TerminalMode.HOST_KEY_INPUT) {
      return
    }
    let answer: string = this.hostKeyBuffer.trim().toLowerCase()
    this.hostKeyBuffer = ''
    this.writeTerminal(SessionViewModel.hostKeyDecisionSubmitOutput(answer))
    if (answer !== 'yes' && answer !== 'no') {
      return
    }
    let accepted: boolean = answer === 'yes'
    let transferClient: FileTransferClient | null = this.activeFileTransferClient()
    let moshClient: MoshClient | null = transferClient === null ? this.moshClient : null
    if (transferClient !== null && !accepted) {
      this.transferControlFailureCode = 'HOST_KEY_REJECTED'
    }
    if (accepted) {
      if (this.context === null) {
        if (transferClient !== null) {
          this.transferControlFailureCode = 'HOST_KEY_ERROR'
          transferClient.verifyHostKey(false)
          transferClient.cancel()
        } else if (moshClient !== null) {
          moshClient.verifyHostKey(false)
          this.onMoshError(new MoshError(
            MoshErrorCode.INTERNAL, 'Host key could not be retained', '', 'client'))
        } else {
          this.sshClient.verifyHostKey(false)
          this.onInternalSessionError(
            'Host key could not be retained because the application context is unavailable')
        }
        return
      }
      try {
        DurableStateManager.commitKnownHostLine(this.context, transferClient !== null ?
          transferClient.getPendingKnownHostLine() : (moshClient !== null ?
            moshClient.getPendingKnownHostLine() : this.sshClient.getPendingKnownHostLine()))
      } catch (e) {
        if (transferClient !== null) {
          this.transferControlFailureCode = 'HOST_KEY_ERROR'
          transferClient.verifyHostKey(false)
          transferClient.cancel()
        } else if (moshClient !== null) {
          moshClient.verifyHostKey(false)
          this.onMoshError(new MoshError(
            MoshErrorCode.INTERNAL, 'Host key could not be retained', '', 'client'))
        } else {
          this.sshClient.verifyHostKey(false)
          this.onInternalSessionError('Host key could not be retained: ' + e)
        }
        return
      }
    }
    if (transferClient !== null) {
      if (transferClient.verifyHostKey(accepted)) {
        this.setMode(TerminalMode.TRANSFERRING)
        this.session.resumeConnection()
        this.notifyStateChange()
      }
      return
    }
    if (moshClient !== null) {
      if (moshClient.verifyHostKey(accepted) && accepted) {
        this.setMode(TerminalMode.CONNECTING)
        this.session.resumeConnection()
        this.notifyStateChange()
        return
      }
      if (!accepted) {
        this.session.markFailed('The host key was not trusted.')
        this.setMode(TerminalMode.IDLE)
        this.finishMoshTerminalOwnership(() => {
          this.writeError('The host key was not trusted.',
            'Reconnect when you are ready to verify the fingerprint.')
        })
        this.notifyStateChange()
      }
      return
    }
    if (this.sshClient.verifyHostKey(accepted) && accepted) {
      this.setMode(TerminalMode.CONNECTING)
      this.session.resumeConnection()
      this.notifyStateChange()
      return
    }
    if (!accepted) {
      this.session.markFailed('The host key was not trusted.')
      this.setMode(TerminalMode.IDLE)
      this.finishSessionTerminalOwnership(() => {
        this.writeError('The host key was not trusted.',
          'Reconnect when you are ready to verify the fingerprint.')
      })
      this.notifyStateChange()
    }
  }

  static hostKeyDecisionSubmitOutput(answer: string): string {
    return answer === 'yes' || answer === 'no' ? '\r\n' : '\r\nPlease type yes or no: '
  }

  private async executeCommandBuffer(): Promise<void> {
    let cmd: string = this.commandLine.getText().trim()
    this.commandLine.clear()
    this.completionRenderer.reset()
    this.writeTerminal('\r\n')

    if (cmd.length === 0) {
      this.writePrompt()
      return
    }

    this.commandBarVm.addToHistory(cmd)
    if (CommandParser.requiresSshEnvironment(cmd)) {
      let showWaitingStatus: boolean = !SshEnvironment.isReady()
      this.sshEnvironmentCommandPending = true
      if (showWaitingStatus) {
        this.writeTerminal(LocalCommandOutput.status('Preparing', 'SSH environment...') + '\r\n')
      }
      try {
        await this.ensureSshEnvironment()
      } catch (e) {
        this.sshEnvironmentCommandPending = false
        this.logger.warn('SSH environment preparation failed')
        this.writeError('The SSH environment is unavailable.',
          'Try the command again. If the problem continues, restart LeanTTY.')
        return
      }
      this.sshEnvironmentCommandPending = false
    }
    let parsed: CommandParseResult | KeyCommandResult | TransferCommandResult | null =
      CommandParser.parseInput(cmd, this.commandBarVm.getSshConfig())
    if (parsed === null) {
      let summary: string = cmd.length > 80 ? cmd.substring(0, 80) + '...' : cmd
      this.writeError('Unknown command "' + summary + '".',
        'Try: help, ssh user@host, or mosh user@host.')
      return
    }
    if (parsed instanceof TransferCommandResult) {
      if (parsed.direction === TransferDirection.SCP_HINT) {
        this.writeError('The scp command is not available.', 'Try: put to upload or get to download.')
        return
      }
      if (!parsed.isValid) {
        this.writeError(parsed.errorMessage,
          parsed.errorMessage.startsWith('Usage: ') ? '' :
            'Try: help ' + (parsed.direction === TransferDirection.PUT ? 'put' : 'get'))
        return
      }
      this.startFileTransfer(parsed)
      return
    }
    if (parsed instanceof KeyCommandResult) {
      if (parsed.kind === KeyCommandKind.EXIT) {
        if (this.onLocalExit === null || !this.onLocalExit()) {
          this.writeError('This Pane still has a remote connection.',
            'Disconnect it before closing the Pane.')
        }
        return
      }
      this.executeKeyCommand(parsed)
      return
    }
    let result: CommandParseResult = parsed
    if (!result.isValid) {
      this.writeError(result.errorMessage,
        result.errorMessage.startsWith('Usage: ') ? '' :
          'Try: help ' + (result.protocol === ConnectionCommandProtocol.MOSH ? 'mosh' : 'ssh'))
      return
    }

    let host: string = result.host
    let port: number = result.port
    let username: string = result.username
    this.pendingKeyPath = result.identityFile
    this.pendingKeyPassphrase = ''
    if (result.protocol === ConnectionCommandProtocol.MOSH) {
      this.connectMoshResolved(result, result.moshUdpPortStart, result.moshUdpPortEnd,
        result.moshServerPath, result.moshPredictionMode)
    } else {
      this.connectResolved(result)
    }
  }

  private beginSshEnvironmentPreparation(): void {
    this.ensureSshEnvironment().catch((e: Error) => {
      this.logger.warn('Background SSH environment preparation failed')
    })
  }

  private ensureSshEnvironment(): Promise<void> {
    if (this.sshEnvironmentReady) {
      return Promise.resolve()
    }
    if (this.sshEnvironmentPreparation !== null) {
      return this.sshEnvironmentPreparation
    }
    if (this.context === null) {
      return Promise.reject(new Error('Pane context is unavailable'))
    }
    let context: common.Context = this.context
    this.sshEnvironmentPreparation = SshEnvironment.prepare(context).then(() => {
      this.commandBarVm.loadSshConfig(context)
      this.sshEnvironmentReady = true
      this.sshEnvironmentPreparation = null
    }, (e: Error) => {
      this.sshEnvironmentPreparation = null
      throw e
    })
    return this.sshEnvironmentPreparation
  }

  private async startFileTransfer(command: TransferCommandResult): Promise<void> {
    if (this.context === null || this.paneId.length === 0) {
      this.writeError('File transfer is unavailable in this Pane.',
        'Close and reopen the Pane, then try again.')
      return
    }
    if (!this.setFileTransferPhase(FileTransferPhase.PREPARING)) {
      this.writeError('This Pane already has a file transfer in progress.',
        'Cancel or finish it before starting another transfer.')
      return
    }
    this.transferCancellationRequested = false
    this.transferControlFailureCode = ''
    this.transferCompletion = new Promise<void>((resolve: () => void) => {
      this.resolveTransferCompletion = resolve
    })
    this.transferPreparationCancellation = new Promise<void>((resolve: () => void) => {
      this.resolveTransferPreparationCancellation = resolve
    })
    this.setMode(TerminalMode.TRANSFERRING)
    this.session.beginTransfer()
    this.notifyStateChange()
    this.writeTerminal(LocalCommandOutput.status('Preparing',
      (command.direction === TransferDirection.PUT ? 'upload' : 'download') + '...') + '\r\n')
    let prepared: TransferLocalFile | null = null
    try {
      prepared = command.direction === TransferDirection.PUT ?
        await TransferFileManager.preparePut(
          this.context, command.localPath, this.transferPreparationCancellation) :
        await TransferFileManager.prepareGet(
          this.context, command.remotePath, command.localPath, command.automaticLocalName,
          this.transferPreparationCancellation)
      if (this.transferCancellationRequested) {
        TransferFileManager.cleanup(prepared)
        prepared = null
        this.finishCancelledFileTransfer()
        return
      }
      if (command.direction === TransferDirection.GET && prepared.nameConflictExpected) {
        this.writeTerminal(LocalCommandOutput.warning('Downloads/' +
          SessionViewModel.terminalSafeText(prepared.localName) +
          ' already exists. A unique name will be chosen when the download finishes.') + '\r\n')
      }
      this.transferCommand = command
      this.transferLocalFile = prepared
      this.pendingKeyPath = command.identityFile
      let key: KeyPairInfo | null = this.resolvePrivateKey()
      let options: FileTransferOptions = new FileTransferOptions()
      options.direction = command.direction === TransferDirection.PUT ? 'put' : 'get'
      options.host = command.host
      options.port = command.port
      options.username = command.username
      options.knownHostsPath = this.knownHostsPath
      options.connectTimeoutMs = command.connectTimeoutMs
      options.serverAliveIntervalSeconds = command.serverAliveIntervalSeconds
      options.serverAliveCountMax = command.serverAliveCountMax
      options.paneId = this.paneId
      options.remotePath = command.remotePath
      if (key !== null) {
        options.privateKeyPath = key.filePath
        options.privateKeyRequiresPassphrase = key.hasPassphrase
      }
      if (command.direction === TransferDirection.PUT) {
        if (prepared.file === null) {
          throw new Error('LOCAL_OPEN: Downloads source descriptor is unavailable')
        }
        options.localDescriptor = prepared.file.fd
      } else {
        options.localPath = prepared.tempPath
      }
      let client: FileTransferClient = new FileTransferClient()
      client.onEvent((message: SshClientMessage) => {
        this.onTransferAuthEvent(message)
      })
      client.onProgress((event: FileTransferProgress) => {
        this.onFileTransferProgress(event)
      })
      this.fileTransferClient = client
      client.start(options)
      TransferFileManager.close(prepared)
      this.transferLastProgressMs = 0
      this.transferLastBytes = 0
      this.transferProgressText = ''
      this.transferProgressVisible = false
      this.transferProgressObserved = false
      this.transferSpeedObserved = false
      this.transferStartedMs = 0
      this.transferSpeedSampleMs = 0
      this.transferSpeedSampleBytes = 0
      this.transferSpeedBytesPerSecond = 0
    } catch (e) {
      let cleanupSucceeded: boolean = true
      try {
        TransferFileManager.cleanup(prepared)
      } catch (cleanupError) {
        cleanupSucceeded = false
        this.logger.warn('File transfer preparation cleanup failed: ' + cleanupError)
      }
      if (this.transferCancellationRequested) {
        this.finishCancelledFileTransfer()
      } else {
        this.finishFileTransferState(FileTransferPhase.FAILED)
        let message: string = this.fileTransferError('PREPARING', '' + e)
        if (!cleanupSucceeded) {
          message += '\r\n' + FileTransferFailurePresenter.cleanupWarning(true)
        }
        this.writeError(message)
      }
    }
  }

  private onTransferAuthEvent(message: SshClientMessage): void {
    let previousState: SshSessionState = this.session.getState()
    if (!this.session.handleClientMessage(message)) {
      this.logger.info('Ignored transfer lifecycle event kind=' + message.kind +
        ',state=' + previousState.toString())
      return
    }
    if (this.session.getState() !== previousState) {
      this.notifyStateChange()
    }
    switch (message.kind) {
      case SshClientEvent.PASSWORD_PROMPT:
        this.logger.info('File transfer authentication prompt=password')
        this.setMode(TerminalMode.PASSWORD_INPUT)
        this.passwordBuffer = ''
        this.writeTerminal('\r\nPassword: ')
        break
      case SshClientEvent.PRIVATE_KEY_PASSPHRASE_PROMPT:
        this.logger.info('File transfer authentication prompt=private-key-passphrase')
        this.pendingKeyPassphrase = ''
        this.setMode(TerminalMode.KEY_PASSPHRASE_INPUT)
        this.writeTerminal('\r\nThe key at ' + message.text + ' is encrypted.\r\nEnter passphrase: ')
        break
      case SshClientEvent.AUTH_BANNER:
        this.writeAuthenticationText(message.text)
        break
      case SshClientEvent.AUTH_CHALLENGE:
        this.logger.info('File transfer authentication prompt=keyboard-interactive')
        this.beginAuthChallenge()
        break
      case SshClientEvent.HOST_KEY_PROMPT:
        this.logger.info('File transfer authentication prompt=host-key')
        this.hostKeyBuffer = ''
        this.setMode(TerminalMode.HOST_KEY_INPUT)
        this.writeTerminal('\r\nThe authenticity of this host cannot be established.\r\n' +
          'Fingerprint: ' + message.text + '\r\nTrust this host key? Type yes or no: ')
        break
      case SshClientEvent.HOST_KEY_CHANGED:
        if (message.hostKeyChanged !== null) {
          this.transferControlFailureCode = 'HOST_KEY_CHANGED'
          this.writeTerminal('\r\n' + LocalCommandOutput.warning(
            SessionViewModel.terminalSafeMultilineText(
              this.transferHostKeyChangedWarning(message.hostKeyChanged))) + '\r\n')
          if (this.fileTransferClient !== null) { this.fileTransferClient.cancel() }
        }
        break
      case SshClientEvent.ERROR:
        this.transferControlFailureCode = 'HOST_KEY_ERROR'
        this.logger.warn('Transfer authentication control error')
        break
      default:
        break
    }
  }

  private transferHostKeyChangedWarning(info: HostKeyChangedInfo): string {
    return SessionViewModel.buildHostKeyChangedWarning(
      info.host, info.port, info.algorithm, info.oldFingerprint, info.newFingerprint)
  }

  private onFileTransferProgress(event: FileTransferProgress): void {
    if (event.kind === 'preparing') {
      this.setFileTransferPhase(FileTransferPhase.PREPARING)
      this.setMode(TerminalMode.TRANSFERRING)
      return
    }
    if (event.kind === 'transferring') {
      this.setFileTransferPhase(FileTransferPhase.TRANSFERRING)
      this.setMode(TerminalMode.TRANSFERRING)
      return
    }
    if (event.kind === 'progress') {
      this.transferLastBytes = event.transferredBytes
      this.renderTransferProgress(event.transferredBytes, event.totalBytes, false)
      return
    }
    if (event.kind === 'finalizing') {
      this.setFileTransferPhase(FileTransferPhase.FINALIZING)
      this.setMode(TerminalMode.TRANSFERRING)
      this.logger.info('FILE_TRANSFER stage=finalizing')
      this.renderTransferProgress(event.transferredBytes, event.totalBytes, true)
      return
    }
    if (event.kind === 'completed') {
      this.completeFileTransfer(event.transferredBytes)
      return
    }
    if (event.kind === 'cancelled') {
      if (this.transferControlFailureCode.length > 0) {
        let cleanupSucceeded: boolean = this.cleanupTransferLocalFile()
        let message: string = this.fileTransferError(this.transferControlFailureCode, '')
        if (!cleanupSucceeded) {
          message += '\r\n' + FileTransferFailurePresenter.cleanupWarning(true)
        }
        this.clearTransferProgress()
        this.finishFileTransferState(FileTransferPhase.FAILED)
        this.writeError(message)
        return
      }
      this.finishCancelledFileTransfer()
      return
    }
    if (event.kind === 'failed') {
      let effectiveCode: string = this.transferControlFailureCode.length > 0 ?
        this.transferControlFailureCode : event.code
      this.logger.warn('FILE_TRANSFER result=failed code=' + effectiveCode)
      let cleanupSucceeded: boolean = this.cleanupTransferLocalFile()
      let message: string = this.fileTransferError(effectiveCode, event.detail)
      if (!cleanupSucceeded && effectiveCode !== 'LOCAL_CLEANUP') {
        message += '\r\n' + FileTransferFailurePresenter.cleanupWarning(true)
      }
      this.clearTransferProgress()
      this.finishFileTransferState(FileTransferPhase.FAILED)
      this.writeError(message)
    }
  }

  private completeFileTransfer(bytes: number): void {
    let command: TransferCommandResult | null = this.transferCommand
    let prepared: TransferLocalFile | null = this.transferLocalFile
    if (command === null || prepared === null) {
      let cleanupSucceeded: boolean = this.cleanupTransferLocalFile()
      this.finishFileTransferState(FileTransferPhase.FAILED)
      let message: string = 'File transfer completed without a current Pane owner; no final file was exposed.'
      if (!cleanupSucceeded) { message += '\r\n' + FileTransferFailurePresenter.cleanupWarning(true) }
      this.writeError(message)
      return
    }
    try {
      this.clearTransferProgress()
      let summary: string
      if (command.direction === TransferDirection.GET) {
        this.setMode(TerminalMode.TRANSFERRING)
        let actualName: string = TransferFileManager.commitGet(prepared)
        summary = 'Downloaded ' + SessionViewModel.terminalSafeText(command.remotePath) +
          ' to Downloads/' + SessionViewModel.terminalSafeText(actualName)
        if (actualName !== prepared.localName) { summary += ' (Renamed)' }
      } else {
        summary = 'Uploaded Downloads/' + SessionViewModel.terminalSafeText(command.localPath) +
          ' to ' + SessionViewModel.terminalSafeText(command.remotePath)
      }
      let elapsedMs: number = this.transferStartedMs > 0 ?
        Math.max(0, Date.now() - this.transferStartedMs) : 0
      this.logger.info('FILE_TRANSFER result=completed direction=' +
        (command.direction === TransferDirection.GET ? 'get' : 'put') +
        ',bytes=' + Math.floor(bytes).toString() +
        ',durationMs=' + Math.floor(elapsedMs).toString())
      let transferStats: string = SessionViewModel.formatTransferCompletion(bytes, elapsedMs)
      this.finishFileTransferState(FileTransferPhase.SUCCEEDED)
      this.writeTerminal('\r\n' + LocalCommandOutput.success(summary +
        ' (' + transferStats + ').') + '\r\n' + LocalCommandOutput.prompt())
    } catch (e) {
      let cleanupSucceeded: boolean = this.cleanupTransferLocalFile()
      let message: string = this.fileTransferError('LOCAL_COMMIT', '' + e)
      if (!cleanupSucceeded) { message += '\r\n' + FileTransferFailurePresenter.cleanupWarning(true) }
      this.finishFileTransferState(FileTransferPhase.FAILED)
      this.writeError(message)
    }
  }

  private cleanupTransferLocalFile(): boolean {
    try {
      TransferFileManager.cleanup(this.transferLocalFile)
      return true
    } catch (e) {
      this.logger.warn('Owned transfer temporary file cleanup failed: ' + e)
      return false
    }
  }

  private renderTransferProgress(transferredBytes: number, totalBytes: number,
    finalizing: boolean): void {
    let now: number = Date.now()
    this.updateTransferSpeed(transferredBytes, now, finalizing)
    let text: string = SessionViewModel.formatTransferProgress(
      transferredBytes, totalBytes, this.transferSpeedBytesPerSecond, finalizing)
    if (!finalizing && this.transferProgressVisible &&
      (text === this.transferProgressText || now - this.transferLastProgressMs < 250)) {
      return
    }
    this.transferLastProgressMs = now
    this.transferProgressText = text
    this.transferProgressVisible = true
    if (!finalizing && transferredBytes > 0 && !this.transferProgressObserved) {
      this.transferProgressObserved = true
      this.logger.info('FILE_TRANSFER progress=visible')
    }
    if (this.transferSpeedBytesPerSecond > 0 && !this.transferSpeedObserved) {
      this.transferSpeedObserved = true
      this.logger.info('FILE_TRANSFER speed=visible')
    }
    this.writeTerminal('\r\u001b[2K' + SessionViewModel.styleTransferProgress(text, finalizing))
  }

  private updateTransferSpeed(transferredBytes: number, now: number, force: boolean): void {
    let transferred: number = Number.isFinite(transferredBytes) && transferredBytes > 0 ?
      Math.floor(transferredBytes) : 0
    if (this.transferStartedMs === 0 || transferred < this.transferSpeedSampleBytes) {
      this.transferStartedMs = now
      this.transferSpeedSampleMs = now
      this.transferSpeedSampleBytes = transferred
      this.transferSpeedBytesPerSecond = 0
      return
    }
    let elapsedMs: number = now - this.transferSpeedSampleMs
    if (elapsedMs <= 0 || (!force && elapsedMs < 1000)) { return }
    let sample: number = (transferred - this.transferSpeedSampleBytes) * 1000 / elapsedMs
    if (sample > 0) {
      this.transferSpeedBytesPerSecond = this.transferSpeedBytesPerSecond > 0 ?
        this.transferSpeedBytesPerSecond * 0.65 + sample * 0.35 : sample
    }
    this.transferSpeedSampleMs = now
    this.transferSpeedSampleBytes = transferred
  }

  private clearTransferProgress(): void {
    if (!this.transferProgressVisible) { return }
    this.writeTerminal('\r\u001b[2K')
    this.transferProgressText = ''
    this.transferProgressVisible = false
    this.transferProgressObserved = false
    this.transferSpeedObserved = false
  }

  private finishCancelledFileTransfer(): void {
    this.logger.info('FILE_TRANSFER result=cancelled')
    let cleanupSucceeded: boolean = this.cleanupTransferLocalFile()
    this.clearTransferProgress()
    this.finishFileTransferState(FileTransferPhase.CANCELLED)
    let cleanupWarning: string = cleanupSucceeded ? '' :
      '\r\n' + LocalCommandOutput.warning(FileTransferFailurePresenter.cleanupWarning(true))
    this.writeTerminal('\r\n' + LocalCommandOutput.cancelled() + cleanupWarning +
      '\r\n' + LocalCommandOutput.prompt())
  }

  private requestFileTransferCancellation(): void {
    this.transferCancellationRequested = true
    if (this.resolveTransferPreparationCancellation !== null) {
      this.resolveTransferPreparationCancellation()
      this.resolveTransferPreparationCancellation = null
    }
    if (this.fileTransferClient !== null && this.fileTransferClient.hasActiveTransfer()) {
      this.fileTransferClient.cancel()
    }
  }

  private setFileTransferPhase(phase: FileTransferPhase): boolean {
    let previous: FileTransferPhase = this.transferLifecycle.getPhase()
    if (!this.transferLifecycle.transition(phase)) {
      this.logger.warn('Rejected file transfer phase transition ' + previous.toString() +
        ' -> ' + phase.toString())
      return false
    }
    if (previous !== phase) {
      this.logger.info('FILE_TRANSFER phase=' + FileTransferPhase[phase])
    }
    return true
  }

  private finishFileTransferState(result: FileTransferPhase): void {
    if (!FileTransferLifecycle.isTerminalPhase(result) || !this.setFileTransferPhase(result)) {
      this.logger.warn('File transfer attempted to finish with an invalid lifecycle state')
    }
    this.pendingKeyPath = ''
    this.pendingKeyPassphrase = ''
    this.passwordBuffer = ''
    this.hostKeyBuffer = ''
    this.clearAuthChallenge()
    this.fileTransferClient = null
    this.transferCommand = null
    this.transferLocalFile = null
    this.transferLastProgressMs = 0
    this.transferLastBytes = 0
    this.transferProgressText = ''
    this.transferProgressVisible = false
    this.transferProgressObserved = false
    this.transferSpeedObserved = false
    this.transferStartedMs = 0
    this.transferSpeedSampleMs = 0
    this.transferSpeedSampleBytes = 0
    this.transferSpeedBytesPerSecond = 0
    this.transferCancellationRequested = false
    this.transferControlFailureCode = ''
    this.session.markDisconnected()
    this.setMode(TerminalMode.IDLE)
    this.notifyStateChange()
    if (this.resolveTransferCompletion !== null) {
      this.resolveTransferCompletion()
    }
    this.resolveTransferCompletion = null
    this.transferCompletion = null
    this.resolveTransferPreparationCancellation = null
    this.transferPreparationCancellation = null
    this.setFileTransferPhase(FileTransferPhase.IDLE)
  }

  private fileTransferError(code: string, detail: string): string {
    let direction: string = this.transferCommand !== null &&
      this.transferCommand.direction === TransferDirection.GET ? 'get' : 'put'
    return FileTransferFailurePresenter.describe(code, detail, direction).message
  }

  static formatTransferBytes(bytes: number): string {
    if (!Number.isFinite(bytes) || bytes < 0) { return '0 B' }
    if (bytes < 1024) { return Math.floor(bytes).toString() + ' B' }
    if (bytes < 1024 * 1024) { return (bytes / 1024).toFixed(1) + ' KiB' }
    if (bytes < 1024 * 1024 * 1024) { return (bytes / (1024 * 1024)).toFixed(1) + ' MiB' }
    return (bytes / (1024 * 1024 * 1024)).toFixed(1) + ' GiB'
  }

  static formatTransferRate(bytesPerSecond: number): string {
    if (!Number.isFinite(bytesPerSecond) || bytesPerSecond <= 0) { return '--' }
    return SessionViewModel.formatTransferBytes(bytesPerSecond) + '/s'
  }

  static formatTransferCompletion(bytes: number, elapsedMs: number): string {
    let safeElapsedMs: number = Number.isFinite(elapsedMs) && elapsedMs > 0 ? elapsedMs : 0
    let text: string = SessionViewModel.formatTransferBytes(bytes) + ' in ' +
      SessionViewModel.formatTransferClock(Math.round(safeElapsedMs / 1000))
    let averageSpeed: number = safeElapsedMs > 0 ? bytes * 1000 / safeElapsedMs : 0
    if (averageSpeed > 0) {
      text += ', avg ' + SessionViewModel.formatTransferRate(averageSpeed)
    }
    return text
  }

  static formatTransferClock(seconds: number): string {
    if (!Number.isFinite(seconds) || seconds < 0) { return '--:--' }
    let value: number = Math.floor(seconds)
    let hours: number = Math.floor(value / 3600)
    let minutes: number = Math.floor((value % 3600) / 60)
    let remainingSeconds: number = value % 60
    if (hours > 0) {
      return hours.toString() + ':' + minutes.toString().padStart(2, '0') + ':' +
        remainingSeconds.toString().padStart(2, '0')
    }
    return minutes.toString().padStart(2, '0') + ':' +
      remainingSeconds.toString().padStart(2, '0')
  }

  static formatTransferAmount(transferred: number, total: number): string {
    if (total < 1024) {
      return Math.floor(transferred).toString() + '/' + Math.floor(total).toString() + ' B'
    }
    let divisor: number = 1024
    let unit: string = 'KiB'
    if (total >= 1024 * 1024 * 1024) {
      divisor = 1024 * 1024 * 1024
      unit = 'GiB'
    } else if (total >= 1024 * 1024) {
      divisor = 1024 * 1024
      unit = 'MiB'
    }
    return (transferred / divisor).toFixed(1) + '/' + (total / divisor).toFixed(1) + ' ' + unit
  }

  static formatTransferProgress(transferredBytes: number, totalBytes: number,
    speedBytesPerSecond: number, finalizing: boolean): string {
    const width: number = 30
    let transferred: number = Number.isFinite(transferredBytes) && transferredBytes > 0 ?
      Math.floor(transferredBytes) : 0
    let total: number = Number.isFinite(totalBytes) && totalBytes > 0 ? Math.floor(totalBytes) : 0
    let bar: string = '─'.repeat(width)
    let percentage: string = ' --%'
    let amount: string = SessionViewModel.formatTransferBytes(transferred)
    if (total > 0) {
      let ratio: number = Math.min(1, transferred / total)
      if (transferred >= total) {
        bar = '━'.repeat(width)
      } else {
        let filled: number = Math.min(width - 1, Math.floor(ratio * width))
        bar = '━'.repeat(filled) + '╸' + '─'.repeat(width - filled - 1)
      }
      percentage = Math.floor(ratio * 100).toString().padStart(3, ' ') + '%'
      amount = SessionViewModel.formatTransferAmount(transferred, total)
    } else if (finalizing) {
      bar = '━'.repeat(width)
      percentage = '100%'
    }
    let text: string = '[' + bar + '] ' + percentage + ' ' + amount + '  ' +
      SessionViewModel.formatTransferRate(speedBytesPerSecond)
    if (finalizing) { return text + '  Finalizing...' }
    let eta: string = '--:--'
    if (total > transferred && speedBytesPerSecond > 0) {
      eta = SessionViewModel.formatTransferClock(
        Math.ceil((total - transferred) / speedBytesPerSecond))
    }
    return text + '  ETA ' + eta
  }

  static styleTransferProgress(text: string, finalizing: boolean): string {
    let percentageEnd: number = text.indexOf(']') + 6
    if (percentageEnd < 6 || percentageEnd > text.length) { return text }
    let styled: string = LocalCommandOutput.progress(text.substring(0, percentageEnd)) +
      text.substring(percentageEnd)
    if (finalizing) {
      styled = styled.replace('Finalizing...', LocalCommandOutput.finalizing('Finalizing...'))
    }
    return styled
  }

  private submitPassword(): void {
    if (this.mode !== TerminalMode.PASSWORD_INPUT) {
      return
    }
    this.writeTerminal('\r\n')
    let pw: string = this.passwordBuffer
    this.passwordBuffer = ''
    let transferClient: FileTransferClient | null = this.activeFileTransferClient()
    let accepted: boolean = transferClient !== null ?
      transferClient.authPassword(pw) : (this.moshClient !== null ?
        this.moshClient.authPassword(pw) : this.sshClient.authPassword(pw))
    if (accepted) {
      this.setMode(transferClient !== null ? TerminalMode.TRANSFERRING : TerminalMode.CONNECTING)
      this.session.resumeConnection()
      this.notifyStateChange()
    }
  }

  private tabComplete(direction: number): void {
    if (this.completionEngine.isMenuActive()) {
      this.cycleCompletion(direction)
      return
    }
    let input: string = this.commandLine.getText()
    this.commandBarVm.setInputText(input)
    let set: LocalCompletionSet = this.commandBarVm.completionSet()
    let update: LocalCompletionUpdate = this.completionEngine.complete(input, set, direction)
    if (update.kind === LocalCompletionUpdateKind.COMPLETED ||
      update.kind === LocalCompletionUpdateKind.SELECTED) {
      this.commandLine.setText(update.text)
      this.redrawLocalCommandLine()
    } else if (update.kind === LocalCompletionUpdateKind.LISTED) {
      this.commandLine.setText(update.text)
      this.redrawLocalCommandLine()
    } else {
      this.redrawLocalCommandLine()
    }
  }

  private cycleCompletion(direction: number): void {
    this.commandLine.setText(this.completionEngine.cycle(direction).text)
    this.redrawLocalCommandLine()
  }

  private navigateCompletion(direction: LocalCompletionNavigation): void {
    let current: LocalCompletionUpdate = this.completionEngine.current()
    let nextIndex: number = LocalCompletionRenderer.moveSelection(
      current.selectedIndex, direction, current.displayValues.length,
      this.completionRenderer.getLastLayout())
    let update: LocalCompletionUpdate = this.completionEngine.select(nextIndex)
    if (update.kind === LocalCompletionUpdateKind.SELECTED) {
      this.commandLine.setText(update.text)
      this.redrawLocalCommandLine()
    }
  }

  private finishCompletionForEditing(): boolean {
    if (!this.completionEngine.isActive()) { return false }
    this.commandLine.setText(this.completionEngine.editingText())
    return true
  }

  private consumeRepeatedDirectorySeparator(text: string): boolean {
    if (text !== '/' || !this.completionEngine.isMenuActive() ||
      !this.completionEngine.selectedCandidate().endsWith('/')) {
      return false
    }
    this.commandLine.setText(this.completionEngine.editingText())
    this.redrawLocalCommandLine()
    return true
  }

  private dismissCompletion(): void {
    if (!this.completionEngine.isActive()) { return }
    this.commandLine.setText(this.completionEngine.cancel().text)
    this.redrawLocalCommandLine()
  }

  static formatCompletionCandidates(values: string[], terminalColumns: number): string {
    return LocalCompletionRenderer.formatPlain(values, terminalColumns)
  }

  static terminalCellWidth(value: string): number {
    return LocalCompletionRenderer.terminalCellWidth(value)
  }

  private static terminalSafeText(value: string): string {
    return TerminalTextPolicy.escape(value)
  }

  private static terminalSafeMultilineText(value: string): string {
    let normalized: string = value.replace(/\r\n/g, '\n').replace(/\r/g, '\n')
    let lines: string[] = normalized.split('\n')
    let safe: string = ''
    for (let index: number = 0; index < lines.length; index++) {
      if (index > 0) { safe += '\r\n' }
      safe += TerminalTextPolicy.escape(lines[index])
    }
    return safe
  }

  private navigateHistory(direction: number): void {
    this.commandBarVm.setInputText(this.commandLine.getText())
    let newCmd: string = this.commandBarVm.navigateHistory(direction)
    this.commandLine.setText(newCmd)
    this.redrawLocalCommandLine()
  }

  private redrawLocalCommandLine(): void {
    let completion: LocalCompletionUpdate = this.completionEngine.current()
    this.writeTerminal(this.completionRenderer.render(
      LocalCommandOutput.prompt(), this.commandLine.getText(), this.commandLine.getCursor(),
      completion.displayValues, completion.selectedIndex, completion.truncated,
      this.lastCols, this.lastRows))
  }

  private notifyTitleChange(title: string): void {
    if (this.onTitleChange !== null) {
      this.onTitleChange(title)
    }
  }

  private startHeartbeat(): void {
    if (this.heartbeatTimerId >= 0) {
      return
    }
    this.heartbeatTimerId = setInterval(() => {
      if (this.terminalSurface !== null) {
        this.terminalSurface.ping()
      }
    }, 30000)
  }
  private stopHeartbeat(): void {
    if (this.heartbeatTimerId >= 0) {
      clearInterval(this.heartbeatTimerId)
      this.heartbeatTimerId = -1
    }
  }

  private executeKeyCommand(result: KeyCommandResult): void {
    if (this.context === null) {
      this.writeError('Local commands are unavailable in this Pane.',
        'Close and reopen the Pane, then try again.')
      return
    }
    let ctx: KeyCommandContext = {
      context: this.context,
      sshConfig: this.commandBarVm.getSshConfig(),
      onConnect: (host: string, port: number, username: string) => {
        this.connect(host, port, username)
      },
      setPendingKeypush: (keyPath: string, pubText: string) => {
        this.pendingKeypush = true
        this.keypushKeyName = keyPath
        this.keypushPublicKey = pubText
      },
      writeError: (msg: string) => { this.writeError(msg) },
      writeOutput: (text: string) => { this.writeTerminal(text) },
      beginKeyPassphraseChange: (keyName: string) => { this.beginKeyPassphraseChange(keyName) },
      beginKeyCommentChange: (keyName: string, hasPassphrase: boolean) => {
        this.beginKeyCommentChange(keyName, hasPassphrase)
      },
      showTopLevelHelp: (helpText: string) => { this.showTopLevelHelp(helpText) },
      confirmKeyDelete: (name: string, fingerprint: string, onConfirm: () => void, onCancel: () => void) => {
        if (this.onConfirmKeyDelete === null) {
          this.writeError('Key deletion confirmation is unavailable.',
            'Close and reopen the Pane, then try again.')
          return
        }
        this.onConfirmKeyDelete(name, fingerprint, onConfirm, onCancel)
      }
    }
    KeyCommandService.execute(result, ctx)
  }

  private showTopLevelHelp(helpText: string): void {
    if (this.context === null || this.localHelpPending) {
      this.writeTerminal(helpText + LocalCommandOutput.warning(
        'The full user guide is unavailable because the application context is unavailable.') +
        '\r\n' + LocalCommandOutput.prompt())
      return
    }
    this.writeTerminal(helpText)
    this.localHelpPending = true
    let context: common.Context = this.context
    UserGuideManager.sync(context).then((result: UserGuideResult) => {
      if (result.available) {
        let link: string = UserGuidePolicy.osc8Link(result.uri)
        this.writeTerminal('Full user guide: ' + link + ' (Ctrl+Click to open)\r\n' +
          LocalCommandOutput.prompt())
      } else {
        this.writeTerminal(LocalCommandOutput.warning('The full user guide is unavailable: ' +
          SessionViewModel.terminalSafeText(result.errorMessage)) + '\r\n' + LocalCommandOutput.prompt())
      }
      this.localHelpPending = false
    }).catch(() => {
      this.writeTerminal(LocalCommandOutput.warning(
        'The full user guide is unavailable because LeanTTY could not create or update it.') +
        '\r\n' + LocalCommandOutput.prompt())
      this.localHelpPending = false
    })
  }

  private beginKeyPassphraseChange(keyName: string): void {
    this.clearKeyPassphraseChangeState()
    this.keyPassphraseChangeKeyName = keyName
    this.keyPassphraseChangeStage = KeyPassphraseChangeStage.OLD_PASSPHRASE
    this.setMode(TerminalMode.KEY_PASSPHRASE_CHANGE_INPUT)
    this.logger.info('KEY_PASSPHRASE_CHANGE stage=old')
    this.writeTerminal('\r\nOld passphrase (leave empty if none): ')
  }

  private submitKeyPassphraseChangeStage(): void {
    if (this.mode !== TerminalMode.KEY_PASSPHRASE_CHANGE_INPUT) {
      return
    }
    if (this.keyPassphraseChangeStage === KeyPassphraseChangeStage.OLD_PASSPHRASE) {
      this.keyPassphraseChangeStage = KeyPassphraseChangeStage.NEW_PASSPHRASE
      this.logger.info('KEY_PASSPHRASE_CHANGE stage=new')
      this.writeTerminal('\r\nNew passphrase (leave empty for none): ')
      return
    }
    if (this.keyPassphraseChangeStage === KeyPassphraseChangeStage.NEW_PASSPHRASE) {
      this.keyPassphraseChangeStage = KeyPassphraseChangeStage.CONFIRM_NEW_PASSPHRASE
      this.logger.info('KEY_PASSPHRASE_CHANGE stage=confirm')
      this.writeTerminal('\r\nConfirm new passphrase: ')
      return
    }
    if (this.keyPassphraseChangeStage !== KeyPassphraseChangeStage.CONFIRM_NEW_PASSPHRASE) {
      return
    }
    if (this.newKeyPassphrase !== this.confirmedKeyPassphrase) {
      this.clearKeyPassphraseChangeSecrets()
      this.keyPassphraseChangeStage = KeyPassphraseChangeStage.OLD_PASSPHRASE
      this.logger.info('KEY_PASSPHRASE_CHANGE result=mismatch stage=old')
      this.writeTerminal('\r\n' + LocalCommandOutput.warning(
        'Passphrases do not match. No changes were made.') + '\r\n' +
        'Old passphrase (leave empty if none): ')
      return
    }
    if (this.context === null) {
      this.clearKeyPassphraseChangeState()
      this.setMode(TerminalMode.IDLE)
      this.logger.warn('KEY_PASSPHRASE_CHANGE result=failure reason=context')
      this.writeError('The key passphrase could not be updated.',
        'Close and reopen the Pane, then try again.')
      return
    }
    let context: common.Context = this.context
    let keyName: string = this.keyPassphraseChangeKeyName
    let oldPassphrase: string = this.oldKeyPassphrase
    let newPassphrase: string = this.newKeyPassphrase
    this.clearKeyPassphraseChangeState()
    try {
      SshKeyManager.changeKeyPassphrase(context, keyName, oldPassphrase, newPassphrase)
      this.setMode(TerminalMode.IDLE)
      this.logger.info('KEY_PASSPHRASE_CHANGE result=success')
      this.writeTerminal('\r\n' + LocalCommandOutput.success('Passphrase updated for ' +
        SessionViewModel.terminalSafeText(keyName) + '.') + '\r\n' + LocalCommandOutput.prompt())
    } catch (e) {
      this.setMode(TerminalMode.IDLE)
      this.logger.warn('KEY_PASSPHRASE_CHANGE result=failure reason=native')
      this.logger.warn('Key passphrase change detail: ' + e)
      this.writeError('The key passphrase could not be updated.',
        'Check the current passphrase and try again.')
    }
    oldPassphrase = ''
    newPassphrase = ''
  }

  private cancelKeyPassphraseChange(): void {
    this.clearKeyPassphraseChangeState()
    this.setMode(TerminalMode.IDLE)
    this.logger.info('KEY_PASSPHRASE_CHANGE result=cancelled')
    this.writeTerminal('^C')
    this.writePrompt()
  }

  private clearKeyPassphraseChangeSecrets(): void {
    this.oldKeyPassphrase = ''
    this.newKeyPassphrase = ''
    this.confirmedKeyPassphrase = ''
  }

  private clearKeyPassphraseChangeState(): void {
    this.clearKeyPassphraseChangeSecrets()
    this.keyPassphraseChangeKeyName = ''
    this.keyPassphraseChangeStage = KeyPassphraseChangeStage.NONE
  }

  private beginKeyCommentChange(keyName: string, hasPassphrase: boolean): void {
    this.clearKeyCommentChangeState()
    this.keyCommentChangeKeyName = keyName
    if (hasPassphrase) {
      this.keyCommentChangeStage = KeyCommentChangeStage.PASSPHRASE
      this.setMode(TerminalMode.KEY_COMMENT_PASSPHRASE_INPUT)
      this.logger.info('KEY_COMMENT_CHANGE stage=passphrase')
      this.writeTerminal('\r\nEnter passphrase: ')
      return
    }
    if (!this.loadCurrentKeyComment('')) {
      this.clearKeyCommentChangeState()
      this.setMode(TerminalMode.IDLE)
      this.logger.warn('KEY_COMMENT_CHANGE result=failure reason=read')
      this.writeError('The key comment could not be read.',
        'Check the key pair and try again.')
      return
    }
    this.beginKeyCommentTextInput()
  }

  private submitKeyCommentPassphrase(): void {
    if (this.mode !== TerminalMode.KEY_COMMENT_PASSPHRASE_INPUT ||
      this.keyCommentChangeStage !== KeyCommentChangeStage.PASSPHRASE) {
      return
    }
    if (!this.loadCurrentKeyComment(this.keyCommentPassphrase)) {
      if (this.mode !== TerminalMode.KEY_COMMENT_PASSPHRASE_INPUT) {
        return
      }
      this.keyCommentPassphrase = ''
      this.logger.info('KEY_COMMENT_CHANGE result=passphrase-rejected stage=passphrase')
      this.writeTerminal('\r\n' + LocalCommandOutput.warning(
        'The passphrase is incorrect. No changes were made.') + '\r\nEnter passphrase: ')
      return
    }
    this.beginKeyCommentTextInput()
  }

  private loadCurrentKeyComment(passphrase: string): boolean {
    if (this.context === null) {
      this.clearKeyCommentChangeState()
      this.setMode(TerminalMode.IDLE)
      this.logger.warn('KEY_COMMENT_CHANGE result=failure reason=context')
      this.writeError('The key comment could not be updated.',
        'Close and reopen the Pane, then try again.')
      return false
    }
    try {
      this.currentKeyComment = SshKeyManager.readKeyComment(
        this.context, this.keyCommentChangeKeyName, passphrase)
      return true
    } catch (e) {
      return false
    }
  }

  private beginKeyCommentTextInput(): void {
    this.keyCommentChangeStage = KeyCommentChangeStage.COMMENT
    this.newKeyComment = ''
    this.setMode(TerminalMode.KEY_COMMENT_INPUT)
    this.logger.info('KEY_COMMENT_CHANGE stage=comment')
    let displayed: string = this.currentKeyComment.length > 0 ?
      SessionViewModel.terminalSafeText(this.currentKeyComment) : '<none>'
    this.writeTerminal('\r\nCurrent comment: ' + displayed +
      '\r\nNew comment (leave empty to remove): ')
  }

  private submitKeyCommentChange(): void {
    if (this.mode !== TerminalMode.KEY_COMMENT_INPUT ||
      this.keyCommentChangeStage !== KeyCommentChangeStage.COMMENT) {
      return
    }
    if (this.context === null) {
      this.clearKeyCommentChangeState()
      this.setMode(TerminalMode.IDLE)
      this.logger.warn('KEY_COMMENT_CHANGE result=failure reason=context')
      this.writeError('The key comment could not be updated.',
        'Close and reopen the Pane, then try again.')
      return
    }
    let context: common.Context = this.context
    let keyName: string = this.keyCommentChangeKeyName
    let passphrase: string = this.keyCommentPassphrase
    let newComment: string = this.newKeyComment
    this.clearKeyCommentChangeState()
    try {
      SshKeyManager.changeKeyComment(context, keyName, passphrase, newComment)
      this.setMode(TerminalMode.IDLE)
      this.logger.info('KEY_COMMENT_CHANGE result=success')
      this.writeTerminal('\r\n' + LocalCommandOutput.success('Comment updated for ' +
        SessionViewModel.terminalSafeText(keyName) + '.') + '\r\n' + LocalCommandOutput.prompt())
    } catch (e) {
      this.setMode(TerminalMode.IDLE)
      this.logger.warn('KEY_COMMENT_CHANGE result=failure reason=commit')
      this.logger.warn('Key comment change detail: ' + e)
      this.writeError('The key comment could not be updated.',
        'Use at most 1023 UTF-8 bytes, without control characters, then try again.')
    }
    passphrase = ''
    newComment = ''
  }

  private cancelKeyCommentChange(): void {
    this.clearKeyCommentChangeState()
    this.setMode(TerminalMode.IDLE)
    this.logger.info('KEY_COMMENT_CHANGE result=cancelled')
    this.writeTerminal('^C')
    this.writePrompt()
  }

  private clearKeyCommentChangeState(): void {
    this.keyCommentPassphrase = ''
    this.currentKeyComment = ''
    this.newKeyComment = ''
    this.keyCommentChangeKeyName = ''
    this.keyCommentChangeStage = KeyCommentChangeStage.NONE
  }

  static buildKeypushMarker(): string {
    return '__LTTY_KEYPUSH_' + Date.now().toString()
  }

  static buildKeypushShellCommand(publicKey: string, marker: string): string {
    let safeKey: string = publicKey.replace(/'/g, "'\\''")
    return "mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && " +
      "(grep -qxF -- '" + safeKey + "' ~/.ssh/authorized_keys || printf '%s\\n' '" + safeKey +
      "' >> ~/.ssh/authorized_keys); " +
      "command_status=$?; printf '\\n%s:%s\\n' '" + marker + "' \"$command_status\"\n"
  }

  private executeKeypushCommand(): void {
    this.setMode(TerminalMode.CONNECTED)
    this.keypushMarker = SessionViewModel.buildKeypushMarker()
    this.keypushOutputTail = ''
    let cmd: string = SessionViewModel.buildKeypushShellCommand(this.keypushPublicKey, this.keypushMarker)
    this.sshClient.write(cmd)
    this.logger.info('Keypush command sent')
    this.keypushTimeoutId = setTimeout(() => {
      this.completeKeypush(-1)
    }, 15000)
  }

  static parseKeypushMarker(combinedOutput: string, marker: string): number | null {
    let markerIndex: number = combinedOutput.indexOf(marker + ':')
    if (markerIndex < 0) {
      return null
    }
    let statusStart: number = markerIndex + marker.length + 1
    let statusEnd: number = combinedOutput.indexOf('\n', statusStart)
    if (statusEnd < 0) {
      return null
    }
    let statusStr: string = combinedOutput.substring(statusStart, statusEnd).trim()
    let validStatus: RegExp = /^-?\d{1,10}$/
    if (!validStatus.test(statusStr)) {
      return null
    }
    let status: number = parseInt(statusStr, 10)
    if (isNaN(status)) {
      return null
    }
    return status
  }

  private observeKeypushOutput(data: string): void {
    if (!this.pendingKeypush || this.keypushMarker.length === 0) {
      return
    }
    let combined: string = this.keypushOutputTail + data
    let status: number | null = SessionViewModel.parseKeypushMarker(combined, this.keypushMarker)
    if (status !== null) {
      this.completeKeypush(status)
      return
    }
    this.keypushOutputTail = combined.length > 256 ? combined.substring(combined.length - 256) : combined
  }

  private async completeKeypush(status: number): Promise<void> {
    if (!this.pendingKeypush) {
      return
    }
    this.logger.info('Key installation completed, status=' + status.toString())
    let spec: SshConnectionSpec = this.session.getConnectionSpec()
    let username: string = spec.username
    let hostname: string = spec.host
    let keyPath: string = this.keypushKeyName
    this.clearKeypushState()
    let client: SshClient = this.sshClient
    client.onEvent(() => {})
    client.onData(() => {})
    await client.disconnect()
    this.sshClient = new SshClient()
    if (status === 0) {
      this.session.markDisconnected()
    } else {
      this.session.markFailed('Remote key installation did not complete successfully')
    }
    this.setMode(TerminalMode.IDLE)
    this.finishSessionTerminalOwnership(() => {
      if (status === 0) {
        this.writeTerminal('\r\n' + LocalCommandOutput.success('Key installed.') + '\r\n' +
          '  Verify with: ssh ' + SessionViewModel.terminalSafeText(username) + '@' +
          SessionViewModel.terminalSafeText(hostname) + ' -i ' +
          SessionViewModel.terminalSafeText(keyPath) + '\r\n' + LocalCommandOutput.prompt())
      } else if (status < 0) {
        this.writeError('The server did not confirm key installation before the timeout.',
          'Check the server before running ssh-copy-id again.')
      } else {
        this.writeError('Key installation failed with remote exit status ' + status.toString() + '.',
          'Check the remote ~/.ssh permissions, then try again.')
      }
    })
    this.notifyStateChange()
  }

  private failKeypush(message: string): void {
    this.clearKeypushState()
    this.session.markOperationFailed(message)
    this.setMode(TerminalMode.IDLE)
    this.finishSessionTerminalOwnership(() => {
      this.writeError(message)
    })
    this.notifyStateChange()
  }

  private clearKeypushState(): void {
    if (this.keypushTimeoutId >= 0) {
      clearTimeout(this.keypushTimeoutId)
      this.keypushTimeoutId = -1
    }
    this.pendingKeypush = false
    this.keypushKeyName = ''
    this.keypushPublicKey = ''
    this.keypushMarker = ''
    this.keypushOutputTail = ''
  }

  private resolvePrivateKey(identityFile: string = this.pendingKeyPath): KeyPairInfo | null {
    if (this.context === null) {
      return null
    }
    if (identityFile.length > 0) {
      return SshKeyManager.findKeyByName(this.context, identityFile)
    }
    return SshKeyManager.findDefaultKey(this.context)
  }

  private writeAuthenticationText(value: string): void {
    if (value.length === 0) {
      return
    }
    let normalized: string = value.replace(/\r?\n/g, '\r\n')
    this.writeTerminal('\r\n' + normalized)
    if (!normalized.endsWith('\r\n')) {
      this.writeTerminal('\r\n')
    }
  }

  private beginAuthChallenge(): void {
    let transferClient: FileTransferClient | null = this.activeFileTransferClient()
    let challenge: AuthChallengeInfo | null = transferClient !== null ?
      transferClient.takePendingAuthChallenge() : (this.moshClient !== null ?
        this.moshClient.takePendingAuthChallenge() : this.sshClient.takePendingAuthChallenge())
    if (challenge === null) {
      if (transferClient !== null) {
        transferClient.cancel()
      } else if (this.moshClient !== null) {
        this.onMoshError(new MoshError(
          MoshErrorCode.INTERNAL, 'Missing keyboard-interactive challenge', '', 'client'))
      } else {
        this.onInternalSessionError('Missing keyboard-interactive challenge')
      }
      return
    }
    this.clearAuthChallenge()
    this.authChallenge = challenge
    let heading: string = SessionViewModel.formatAuthenticationHeading(
      this.pendingAuthenticationLayer(), this.session.getConnectionSpec().jumpHost.length > 0)
    if (heading.length > 0) {
      this.writeAuthenticationText(heading)
    }
    this.writeAuthenticationText(challenge.name)
    this.writeAuthenticationText(challenge.instructions)
    if (challenge.prompts.length === 0) {
      this.submitCompletedAuthChallenge()
      return
    }
    this.setMode(TerminalMode.AUTH_CHALLENGE_INPUT)
    this.writeTerminal(challenge.prompts[0].text)
  }

  private submitAuthChallengeResponse(): void {
    if (this.authChallenge === null || this.authPromptIndex >= this.authChallenge.prompts.length) {
      this.onInternalSessionError('Invalid keyboard-interactive response state')
      return
    }
    this.authResponses.push(this.authResponseBuffer)
    this.authResponseBuffer = ''
    this.authPromptIndex++
    this.writeTerminal('\r\n')
    if (this.authPromptIndex < this.authChallenge.prompts.length) {
      this.writeTerminal(this.authChallenge.prompts[this.authPromptIndex].text)
      return
    }
    this.submitCompletedAuthChallenge()
  }

  private submitCompletedAuthChallenge(): void {
    if (this.authChallenge === null) {
      this.onInternalSessionError('Missing keyboard-interactive response context')
      return
    }
    let roundId: number = this.authChallenge.roundId
    let responses: string[] = this.authResponses
    this.authChallenge = null
    this.authPromptIndex = 0
    this.authResponseBuffer = ''
    this.authResponses = []
    let transferClient: FileTransferClient | null = this.activeFileTransferClient()
    let submitted: boolean = transferClient !== null ?
      transferClient.authKeyboardInteractiveResponses(roundId, responses) :
      (this.moshClient !== null ?
        this.moshClient.authKeyboardInteractiveResponses(roundId, responses) :
        this.sshClient.authKeyboardInteractiveResponses(roundId, responses))
    for (let i = 0; i < responses.length; i++) {
      responses[i] = ''
    }
    responses.length = 0
    if (submitted) {
      this.setMode(transferClient !== null ? TerminalMode.TRANSFERRING : TerminalMode.CONNECTING)
      this.notifyStateChange()
    }
  }

  private clearAuthChallenge(): void {
    this.authResponseBuffer = ''
    for (let i = 0; i < this.authResponses.length; i++) {
      this.authResponses[i] = ''
    }
    this.authResponses = []
    this.authPromptIndex = 0
    this.authChallenge = null
  }

  private submitKeyPassphrase(): void {
    if (this.mode !== TerminalMode.KEY_PASSPHRASE_INPUT) {
      return
    }
    this.writeTerminal('\r\n')
    let pass: string = this.pendingKeyPassphrase
    this.pendingKeyPassphrase = ''
    let transferClient: FileTransferClient | null = this.activeFileTransferClient()
    let accepted: boolean = transferClient !== null ?
      transferClient.authPrivateKeyPassphrase(pass) : (this.moshClient !== null ?
        this.moshClient.authPrivateKeyPassphrase(pass) :
        this.sshClient.authPrivateKeyPassphrase(pass))
    if (accepted) {
      this.setMode(transferClient !== null ? TerminalMode.TRANSFERRING : TerminalMode.CONNECTING)
      this.notifyStateChange()
    }
  }

  private activeFileTransferClient(): FileTransferClient | null {
    if (this.fileTransferClient === null || !this.fileTransferClient.hasActiveTransfer()) {
      return null
    }
    return this.fileTransferClient
  }

  private pendingAuthenticationLayer(): string {
    let transferClient: FileTransferClient | null = this.activeFileTransferClient()
    return transferClient !== null ? transferClient.getPendingLayer() : (this.moshClient !== null ?
      this.moshClient.getPendingLayer() : this.sshClient.getPendingLayer())
  }

  static formatPasswordPrompt(layer: string, hasJump: boolean): string {
    if (!hasJump) {
      return 'Password: '
    }
    return layer === 'jump' ? 'Jump host password: ' : 'Target host password: '
  }

  static formatPrivateKeyPassphrasePrompt(path: string, layer: string, hasJump: boolean): string {
    if (!hasJump) {
      return '\r\nThe key at ' + path + ' is encrypted.\r\nEnter passphrase: '
    }
    let name: string = layer === 'jump' ? 'jump' : 'target'
    return '\r\nThe ' + name + ' host key at ' + path + ' is encrypted.\r\nEnter ' +
      name + ' host key passphrase: '
  }

  static formatHostKeyPrompt(fingerprint: string, layer: string, hasJump: boolean): string {
    let hostName: string = !hasJump ? 'this host' :
      (layer === 'jump' ? 'this jump host' : 'this target host')
    return '\r\nThe authenticity of ' + hostName + ' cannot be established.\r\nFingerprint: ' +
      fingerprint + '\r\nTrust ' + hostName + ' key? Type yes or no: '
  }

  static formatAuthenticationHeading(layer: string, hasJump: boolean): string {
    if (!hasJump) {
      return ''
    }
    return layer === 'jump' ? 'Jump host authentication' : 'Target host authentication'
  }

}
