import { describe, it, expect } from '@ohos/hypium'
import { SshError, SshErrorCode } from '../main/ets/common/types/SshTypes'
import {
  HostKeyChangedInfo,
  SshClientEvent,
  SshClientMessage
} from '../main/ets/model/ssh/SshClient'
import { SshSession, SshSessionState } from '../main/ets/model/ssh/SshSession'
import { MoshClient } from '../main/ets/model/mosh/MoshClient'
import { SessionViewModel } from '../main/ets/viewmodel/SessionViewModel'

export default function sshSessionLifecycleTest() {
  describe('SshSessionLifecycle', () => {
    it('ownsTheConnectionAuthenticationAndCloseEventChain', 0, () => {
      let session: SshSession = new SshSession()

      expect(session.beginConnection()).assertEqual(true)
      expect(session.getState()).assertEqual(SshSessionState.CONNECTING)
      expect(session.handleClientMessage(
        SshClientMessage.simple(SshClientEvent.PASSWORD_PROMPT))).assertEqual(true)
      expect(session.getState()).assertEqual(SshSessionState.AUTHENTICATING)
      expect(session.handleClientMessage(
        SshClientMessage.withText(SshClientEvent.HOST_KEY_PROMPT, 'SHA256:test'))).assertEqual(true)
      expect(session.getState()).assertEqual(SshSessionState.HOST_VERIFICATION_REQUIRED)
      expect(session.resumeConnection()).assertEqual(true)
      expect(session.handleClientMessage(
        SshClientMessage.simple(SshClientEvent.AUTH_CHALLENGE))).assertEqual(true)
      expect(session.handleClientMessage(
        SshClientMessage.simple(SshClientEvent.CONNECTED))).assertEqual(true)
      expect(session.getState()).assertEqual(SshSessionState.CONNECTED)
      expect(session.handleClientMessage(SshClientMessage.close(0))).assertEqual(true)
      expect(session.getState()).assertEqual(SshSessionState.DISCONNECTED)
      expect(session.getExitCode()).assertEqual(0)
    })

    it('ignoresRepeatedAndLateTerminalEvents', 0, () => {
      let session: SshSession = new SshSession()
      session.beginConnection()
      session.handleClientMessage(SshClientMessage.simple(SshClientEvent.CONNECTED))

      expect(session.handleClientMessage(
        SshClientMessage.simple(SshClientEvent.CONNECTED))).assertEqual(false)
      expect(session.handleClientMessage(SshClientMessage.close(23))).assertEqual(true)
      expect(session.handleClientMessage(SshClientMessage.close(99))).assertEqual(false)
      expect(session.handleClientMessage(
        SshClientMessage.simple(SshClientEvent.PASSWORD_PROMPT))).assertEqual(false)
      expect(session.handleClientMessage(SshClientMessage.withError(new SshError(
        SshErrorCode.Network, 'late error', 'late detail', 'target')))).assertEqual(false)
      expect(session.getState()).assertEqual(SshSessionState.DISCONNECTED)
      expect(session.getExitCode()).assertEqual(23)
      expect(session.getErrorMessage()).assertEqual('')
    })

    it('acceptsMoshCallbacksOnlyFromTheCurrentPaneOwner', 0, () => {
      let currentClient: MoshClient = new MoshClient()
      let staleClient: MoshClient = new MoshClient()

      expect(SessionViewModel.isCurrentMoshClient(currentClient, currentClient)).assertEqual(true)
      expect(SessionViewModel.isCurrentMoshClient(currentClient, staleClient)).assertEqual(false)
      expect(SessionViewModel.isCurrentMoshClient(null, currentClient)).assertEqual(false)
    })

    it('mapsHostKeyAndTransportFailuresIntoTheSession', 0, () => {
      let session: SshSession = new SshSession()
      let changed: HostKeyChangedInfo = new HostKeyChangedInfo()
      changed.host = 'server.example'
      changed.port = 22

      session.beginConnection()
      expect(session.handleClientMessage(
        SshClientMessage.withHostKeyChanged(changed))).assertEqual(true)
      expect(session.getState()).assertEqual(SshSessionState.FAILED)
      expect(session.getErrorMessage()).assertEqual('Remote host identification has changed')

      session.reset()
      session.beginConnection()
      expect(session.handleClientMessage(SshClientMessage.withError(new SshError(
        SshErrorCode.Auth, 'Authentication failed', 'server rejected key', 'target'))))
        .assertEqual(true)
      expect(session.getState()).assertEqual(SshSessionState.FAILED)
      expect(session.getErrorMessage()).assertEqual('server rejected key')
    })

    it('usesTheSameOwnerForReconnectAndTransferHandoff', 0, () => {
      let session: SshSession = new SshSession()
      session.beginConnection()
      session.handleClientMessage(SshClientMessage.simple(SshClientEvent.CONNECTED))
      expect(session.beginReconnect()).assertEqual(true)
      expect(session.getState()).assertEqual(SshSessionState.RECONNECTING)
      expect(session.beginConnection()).assertEqual(true)

      session.markDisconnected()
      expect(session.beginTransfer()).assertEqual(true)
      expect(session.handleClientMessage(
        SshClientMessage.withText(SshClientEvent.HOST_KEY_PROMPT, 'SHA256:transfer'))).assertEqual(true)
      expect(session.resumeConnection()).assertEqual(true)
      expect(session.handleClientMessage(
        SshClientMessage.simple(SshClientEvent.PRIVATE_KEY_PASSPHRASE_PROMPT))).assertEqual(true)
      expect(session.markDisconnected()).assertEqual(true)
      expect(session.getState()).assertEqual(SshSessionState.DISCONNECTED)
    })

    it('keepsMoshInterruptionSeparateFromSessionCompletion', 0, () => {
      let session: SshSession = new SshSession()
      session.beginConnection()
      session.handleClientMessage(SshClientMessage.simple(SshClientEvent.CONNECTED))

      expect(session.markInterrupted()).assertEqual(true)
      expect(session.getState()).assertEqual(SshSessionState.INTERRUPTED)
      expect(session.isActive()).assertEqual(true)
      expect(session.isConnected()).assertEqual(true)
      expect(session.markInterrupted()).assertEqual(true)
      expect(session.markResponsive()).assertEqual(true)
      expect(session.getState()).assertEqual(SshSessionState.CONNECTED)

      expect(session.markInterrupted()).assertEqual(true)
      expect(session.markDisconnected(0)).assertEqual(true)
      expect(session.getState()).assertEqual(SshSessionState.DISCONNECTED)
    })

    it('clearsTerminalEvidenceWhenThePaneResets', 0, () => {
      let session: SshSession = new SshSession()
      session.beginConnection()
      session.handleClientMessage(SshClientMessage.close(7))
      session.markOperationFailed('operation failed after close')
      expect(session.getState()).assertEqual(SshSessionState.FAILED)

      session.reset()
      expect(session.getState()).assertEqual(SshSessionState.IDLE)
      expect(session.getExitCode()).assertEqual(-1)
      expect(session.getErrorMessage()).assertEqual('')
    })
  })
}
