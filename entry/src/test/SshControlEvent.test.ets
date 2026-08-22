import { describe, expect, it } from '@ohos/hypium'
import type { ControlEvent as NativeControlEvent } from 'libleantty_ssh.so'
import { SshErrorCode } from '../main/ets/common/types/SshTypes'
import { SshControlEventPolicy } from '../main/ets/model/ssh/SshControlEventPolicy'
import { SshDiagnosticInfo } from '../main/ets/model/ssh/SshClient'
import { SessionViewModel } from '../main/ets/viewmodel/SessionViewModel'

class SshControlEventRecord implements NativeControlEvent {
  kind: string = ''
  sessionId: string = ''
  generation: number = 0
  layer: string = ''
  stage: string = ''
  code: string = ''
  detail: string = ''
  fingerprint: string = ''
  knownHostLine: string = ''
  algorithm: string = ''
  oldFingerprint: string = ''
  newFingerprint: string = ''
  host: string = ''
  port: number = 0
  metrics: string = ''
}

export default function sshControlEventTest(): void {
  describe('SshControlEvent', () => {
    it('keepsErrorCodeAndLayerIndependentOfUntrustedDetailText', 0, () => {
      let event: SshControlEventRecord = new SshControlEventRecord()
      event.kind = 'error'
      event.sessionId = '41'
      event.generation = 7
      event.layer = 'jump'
      event.stage = 'authentication'
      event.code = 'auth'
      event.detail = 'target: opaque server detail'

      let error = SshControlEventPolicy.error(event)
      expect(error !== null).assertEqual(true)
      if (error !== null) {
        expect(error.code).assertEqual(SshErrorCode.Auth)
        expect(error.layer).assertEqual('jump')
        expect(error.detail).assertEqual('target: opaque server detail')
        expect(SessionViewModel.sshFailureTitle(error.layer))
          .assertEqual('The jump host connection failed.')
      }
    })

    it('mapsChangedHostKeyFieldsWithoutAJsonRoundTrip', 0, () => {
      let event: SshControlEventRecord = new SshControlEventRecord()
      event.kind = 'host_key_changed'
      event.sessionId = '42'
      event.generation = 8
      event.layer = 'target'
      event.algorithm = 'ssh-ed25519'
      event.oldFingerprint = 'SHA256:old'
      event.newFingerprint = 'SHA256:new'
      event.host = 'server.example.com'
      event.port = 2222

      let info = SshControlEventPolicy.hostKeyChanged(event)
      expect(info !== null).assertEqual(true)
      if (info !== null) {
        expect(info.layer).assertEqual('target')
        expect(info.algorithm).assertEqual('ssh-ed25519')
        expect(info.oldFingerprint).assertEqual('SHA256:old')
        expect(info.newFingerprint).assertEqual('SHA256:new')
        expect(info.host).assertEqual('server.example.com')
        expect(info.port).assertEqual(2222)
      }
    })

    it('logsOnlyWhitelistedControlMetadata', 0, () => {
      let event: SshControlEventRecord = new SshControlEventRecord()
      event.kind = 'host_key_prompt'
      event.layer = 'target'
      event.fingerprint = 'SHA256:secret'
      event.knownHostLine = '[private.example]:2222 ssh-ed25519 secret'
      let label: string = SshControlEventPolicy.safeLogLabel(event)
      expect(label).assertEqual('native control event: host_key_prompt:target')
      expect(label.includes('secret')).assertEqual(false)
      expect(label.includes('private.example')).assertEqual(false)
    })

    it('formatsValidatedDiagnosticObjectsWithoutParsingJson', 0, () => {
      let info: SshDiagnosticInfo = new SshDiagnosticInfo()
      info.layer = 'target'
      info.stage = 'connect'
      info.status = 'failed'
      info.reason = 'tcp_refused'
      let line: string = SessionViewModel.formatSshDiagnostic(info)
      expect(line.includes('Target TCP connection: refused.')).assertEqual(true)
    })
  })
}
