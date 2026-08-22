import { SshSessionState } from '../../common/types/TerminalTypes'
import {
  DEFAULT_SSH_CONNECT_TIMEOUT_MS,
  DEFAULT_SSH_SERVER_ALIVE_INTERVAL_SECONDS,
  DEFAULT_SSH_SERVER_ALIVE_COUNT_MAX
} from '../../common/types/SshTypes'
import { SshClientEvent, SshClientMessage } from './SshClient'

export { SshSessionState }

export class SshSession {
  private state: SshSessionState = SshSessionState.IDLE
  private displayHost: string = ''
  private hostname: string = ''
  private port: number = 22
  private username: string = ''
  private identityFile: string = ''
  private jumpDisplayHost: string = ''
  private jumpHostname: string = ''
  private jumpPort: number = 22
  private jumpUsername: string = ''
  private jumpIdentityFile: string = ''
  private jumpConnectTimeoutMs: number = DEFAULT_SSH_CONNECT_TIMEOUT_MS
  private jumpServerAliveIntervalSeconds: number = DEFAULT_SSH_SERVER_ALIVE_INTERVAL_SECONDS
  private jumpServerAliveCountMax: number = DEFAULT_SSH_SERVER_ALIVE_COUNT_MAX
  private connectTimeoutMs: number = DEFAULT_SSH_CONNECT_TIMEOUT_MS
  private serverAliveIntervalSeconds: number = DEFAULT_SSH_SERVER_ALIVE_INTERVAL_SECONDS
  private serverAliveCountMax: number = DEFAULT_SSH_SERVER_ALIVE_COUNT_MAX
  private errorMessage: string = ''
  private exitCode: number = -1

  getState(): SshSessionState {
    return this.state
  }

  beginConnection(): boolean {
    return this.transitionFrom([
      SshSessionState.IDLE,
      SshSessionState.DISCONNECTED,
      SshSessionState.FAILED,
      SshSessionState.RECONNECTING
    ], SshSessionState.CONNECTING)
  }

  beginReconnect(): boolean {
    return this.transitionFrom([
      SshSessionState.IDLE,
      SshSessionState.CONNECTED,
      SshSessionState.DISCONNECTED,
      SshSessionState.FAILED
    ], SshSessionState.RECONNECTING)
  }

  beginTransfer(): boolean {
    return this.beginConnection()
  }

  resumeConnection(): boolean {
    if (this.state === SshSessionState.CONNECTING) { return true }
    return this.transitionFrom([
      SshSessionState.HOST_VERIFICATION_REQUIRED,
      SshSessionState.AUTHENTICATING
    ], SshSessionState.CONNECTING)
  }

  markDisconnected(exitCode: number = -1): boolean {
    if (!this.transitionFrom([
      SshSessionState.IDLE,
      SshSessionState.CONNECTING,
      SshSessionState.HOST_VERIFICATION_REQUIRED,
      SshSessionState.AUTHENTICATING,
      SshSessionState.CONNECTED,
      SshSessionState.RECONNECTING,
      SshSessionState.FAILED
    ], SshSessionState.DISCONNECTED)) {
      return false
    }
    this.exitCode = exitCode
    return true
  }

  markFailed(message: string): boolean {
    if (!this.transitionFrom([
      SshSessionState.IDLE,
      SshSessionState.CONNECTING,
      SshSessionState.HOST_VERIFICATION_REQUIRED,
      SshSessionState.AUTHENTICATING,
      SshSessionState.CONNECTED,
      SshSessionState.RECONNECTING
    ], SshSessionState.FAILED)) {
      return false
    }
    this.errorMessage = message
    return true
  }

  markOperationFailed(message: string): boolean {
    if (this.state === SshSessionState.DISCONNECTED || this.state === SshSessionState.FAILED) {
      this.state = SshSessionState.FAILED
      this.errorMessage = message
      return true
    }
    return this.markFailed(message)
  }

  handleClientMessage(message: SshClientMessage): boolean {
    switch (message.kind) {
      case SshClientEvent.PASSWORD_PROMPT:
      case SshClientEvent.PRIVATE_KEY_PASSPHRASE_PROMPT:
      case SshClientEvent.AUTH_BANNER:
      case SshClientEvent.AUTH_CHALLENGE:
        return this.authenticationRequired()
      case SshClientEvent.HOST_KEY_PROMPT:
        return this.hostVerificationRequired()
      case SshClientEvent.HOST_KEY_CHANGED:
        if (message.hostKeyChanged === null) { return false }
        return this.markFailed('Remote host identification has changed')
      case SshClientEvent.CONNECTED:
        return this.transitionFrom([
          SshSessionState.CONNECTING,
          SshSessionState.HOST_VERIFICATION_REQUIRED,
          SshSessionState.AUTHENTICATING,
          SshSessionState.RECONNECTING
        ], SshSessionState.CONNECTED)
      case SshClientEvent.CLOSE:
        return this.markDisconnected(message.exitCode)
      case SshClientEvent.ERROR:
        return message.error !== null && this.markFailed(message.error.detail)
      case SshClientEvent.WARNING:
      case SshClientEvent.DIAGNOSTIC:
        return this.isActive()
      default:
        return false
    }
  }

  private authenticationRequired(): boolean {
    if (this.state === SshSessionState.AUTHENTICATING) { return true }
    return this.transitionFrom([
      SshSessionState.CONNECTING,
      SshSessionState.HOST_VERIFICATION_REQUIRED
    ], SshSessionState.AUTHENTICATING)
  }

  private hostVerificationRequired(): boolean {
    if (this.state === SshSessionState.HOST_VERIFICATION_REQUIRED) { return true }
    return this.transitionFrom([
      SshSessionState.CONNECTING,
      SshSessionState.AUTHENTICATING
    ], SshSessionState.HOST_VERIFICATION_REQUIRED)
  }

  private transitionFrom(allowed: SshSessionState[], next: SshSessionState): boolean {
    if (allowed.indexOf(this.state) < 0) { return false }
    this.state = next
    return true
  }

  getDisplayHost(): string {
    return this.displayHost
  }

  setDisplayHost(host: string): void {
    this.displayHost = host
  }

  getHostname(): string {
    return this.hostname
  }

  setHostname(host: string): void {
    this.hostname = host
  }

  getPort(): number {
    return this.port
  }

  setPort(p: number): void {
    this.port = p
  }

  getUsername(): string {
    return this.username
  }

  setUsername(u: string): void {
    this.username = u
  }

  getIdentityFile(): string {
    return this.identityFile
  }

  setIdentityFile(identityFile: string): void {
    this.identityFile = identityFile
  }

  getJumpDisplayHost(): string {
    return this.jumpDisplayHost
  }

  setJumpDisplayHost(host: string): void {
    this.jumpDisplayHost = host
  }

  getJumpHostname(): string {
    return this.jumpHostname
  }

  setJumpHostname(host: string): void {
    this.jumpHostname = host
  }

  getJumpPort(): number {
    return this.jumpPort
  }

  setJumpPort(port: number): void {
    this.jumpPort = port
  }

  getJumpUsername(): string {
    return this.jumpUsername
  }

  setJumpUsername(username: string): void {
    this.jumpUsername = username
  }

  getJumpIdentityFile(): string {
    return this.jumpIdentityFile
  }

  setJumpIdentityFile(identityFile: string): void {
    this.jumpIdentityFile = identityFile
  }

  getJumpConnectTimeoutMs(): number {
    return this.jumpConnectTimeoutMs
  }

  setJumpConnectTimeoutMs(connectTimeoutMs: number): void {
    this.jumpConnectTimeoutMs = connectTimeoutMs
  }

  getJumpServerAliveIntervalSeconds(): number { return this.jumpServerAliveIntervalSeconds }

  setJumpServerAliveIntervalSeconds(seconds: number): void { this.jumpServerAliveIntervalSeconds = seconds }

  getJumpServerAliveCountMax(): number { return this.jumpServerAliveCountMax }

  setJumpServerAliveCountMax(count: number): void { this.jumpServerAliveCountMax = count }

  getConnectTimeoutMs(): number {
    return this.connectTimeoutMs
  }

  setConnectTimeoutMs(connectTimeoutMs: number): void {
    this.connectTimeoutMs = connectTimeoutMs
  }

  getServerAliveIntervalSeconds(): number { return this.serverAliveIntervalSeconds }

  setServerAliveIntervalSeconds(seconds: number): void { this.serverAliveIntervalSeconds = seconds }

  getServerAliveCountMax(): number { return this.serverAliveCountMax }

  setServerAliveCountMax(count: number): void { this.serverAliveCountMax = count }

  getErrorMessage(): string {
    return this.errorMessage
  }

  getExitCode(): number {
    return this.exitCode
  }

  getDisplayTitle(): string {
    return this.getConnectionTitle()
  }

  getConnectionTitle(): string {
    let host: string = this.displayHost.length > 0 ? this.displayHost : this.hostname
    if (host.length === 0) {
      return 'ltty'
    }
    return this.username.length > 0 ? this.username + '@' + host : host
  }

  isConnected(): boolean {
    return this.state === SshSessionState.CONNECTED
  }

  isActive(): boolean {
    return this.state === SshSessionState.CONNECTING ||
      this.state === SshSessionState.HOST_VERIFICATION_REQUIRED ||
      this.state === SshSessionState.AUTHENTICATING ||
      this.state === SshSessionState.CONNECTED
  }

  reset(): void {
    this.state = SshSessionState.IDLE
    this.errorMessage = ''
    this.exitCode = -1
  }
}
