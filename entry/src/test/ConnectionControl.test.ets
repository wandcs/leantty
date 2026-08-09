import { describe, it, expect } from '@ohos/hypium'
import { KeyCodeMap } from '../main/ets/common/constants/KeyCodeMap'
import { TerminalMode } from '../main/ets/common/types/TerminalTypes'
import { ConnectionControl } from '../main/ets/model/ssh/ConnectionControl'

export default function connectionControlTest() {
  describe('ConnectionControl', () => {
    it('ctrlCInterruptsAConnectingSession', 0, () => {
      let ctrlC: string = KeyCodeMap.toAnsi(KeyCodeMap.A + 2, true, false, false)
      expect(ConnectionControl.shouldInterrupt(TerminalMode.CONNECTING, ctrlC)).assertEqual(true)
    })

    it('otherInputDoesNotInterruptAConnectingSession', 0, () => {
      expect(ConnectionControl.shouldInterrupt(TerminalMode.CONNECTING, 'c')).assertEqual(false)
      expect(ConnectionControl.shouldInterrupt(TerminalMode.CONNECTED, '\u0003')).assertEqual(false)
    })

    it('ctrlCInterruptsAuthenticationPrompts', 0, () => {
      expect(ConnectionControl.shouldInterrupt(TerminalMode.PASSWORD_INPUT, '\u0003')).assertEqual(true)
      expect(ConnectionControl.shouldInterrupt(TerminalMode.HOST_KEY_INPUT, '\u0003')).assertEqual(true)
      expect(ConnectionControl.shouldInterrupt(TerminalMode.KEY_PASSPHRASE_INPUT, '\u0003')).assertEqual(true)
      expect(ConnectionControl.shouldInterrupt(TerminalMode.AUTH_CHALLENGE_INPUT, '\u0003')).assertEqual(true)
      expect(ConnectionControl.shouldInterrupt(TerminalMode.TRANSFERRING, '\u0003')).assertEqual(true)
    })

    it('describesCleanAndUnexpectedConnectionClose', 0, () => {
      expect(ConnectionControl.describeClose(0)).assertEqual('Connection closed (exit 0).')
      expect(ConnectionControl.describeClose(127)).assertEqual('Connection closed (exit 127).')
      expect(ConnectionControl.describeClose(-1)).assertEqual(
        'Connection lost unexpectedly. Check the network, then run the SSH command again.')
    })
  })
}
