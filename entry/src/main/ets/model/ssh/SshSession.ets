import { SshSessionState } from '../../common/types/TerminalTypes'
import { SshConnectionSpec } from '../../common/types/SshTypes'
import { SshClientEvent, SshClientMessage } from './SshClient'

export { SshSessionState }

export class SshSession {
  private state: SshSessionState = SshSessionState.IDLE
  private connectionSpec: SshConnectionSpec = new SshConnectionSpec()
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

  getConnectionSpec(): SshConnectionSpec {
    return this.connectionSpec.copy()
  }

  setConnectionSpec(spec: SshConnectionSpec): void {
    this.connectionSpec = spec.copy()
  }

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
    let host: string = this.connectionSpec.displayHost.length > 0 ?
      this.connectionSpec.displayHost : this.connectionSpec.host
    if (host.length === 0) {
      return 'ltty'
    }
    return this.connectionSpec.username.length > 0 ? this.connectionSpec.username + '@' + host : host
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
