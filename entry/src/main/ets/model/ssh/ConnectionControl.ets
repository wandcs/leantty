import { TerminalMode } from '../../common/types/TerminalTypes'

export class ConnectionControl {
  static shouldInterrupt(mode: TerminalMode, input: string): boolean {
    let pending: boolean = mode === TerminalMode.CONNECTING ||
      mode === TerminalMode.PASSWORD_INPUT || mode === TerminalMode.HOST_KEY_INPUT ||
      mode === TerminalMode.KEY_PASSPHRASE_INPUT || mode === TerminalMode.AUTH_CHALLENGE_INPUT ||
      mode === TerminalMode.TRANSFERRING
    return pending && input === '\u0003'
  }

  static describeClose(exitCode: number): string {
    if (exitCode < 0) {
      return 'Connection lost unexpectedly. Check the network, then run the SSH command again.'
    }
    return 'Connection closed (exit ' + exitCode.toString() + ').'
  }
}
