import { describe, it, expect } from '@ohos/hypium'
import { CommandParser } from '../main/ets/model/command/CommandParser'
import { SshEnvironmentReadiness } from '../main/ets/model/ssh/SshEnvironmentReadiness'
import { BridgeProtocol } from '../main/ets/model/bridge/BridgeProtocol'

export default function sshEnvironmentPreparationTest() {
  describe('SshEnvironmentPreparation', () => {
    it('keepsOnlyExplicitLocalCommandsOutsideThePreparationGate', 0, () => {
      for (let command of [
        'ssh prod', 'ssh -G prod', 'put file prod:/tmp/', 'get prod:/tmp/file',
        'ssh-keygen -l -f id_ed25519', 'ssh-copy-id -i id_ed25519 user@host',
        'key list', 'host list', 'key rm deploy', 'unknown'
      ]) {
        expect(CommandParser.requiresSshEnvironment(command)).assertEqual(true)
      }
      for (let command of ['', 'help', 'help ssh', 'ssh --help', 'scp file host:/tmp', 'exit']) {
        expect(CommandParser.requiresSshEnvironment(command)).assertEqual(false)
      }
    })

    it('acceptsOnlyAnEmptyInteractiveReadyControlMessage', 0, () => {
      expect(BridgeProtocol.parse('H2|W2N|CONTROL|interactiveReady|') !== null).assertEqual(true)
      expect(BridgeProtocol.parse('H2|W2N|CONTROL|interactiveReady|unexpected')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|N2W|CONTROL|interactiveReady|')).assertEqual(null)
    })

    it('sharesOnePreparationAcrossConcurrentCallers', 0, async () => {
      let readiness: SshEnvironmentReadiness = new SshEnvironmentReadiness()
      let calls: number = 0
      let release: () => void = () => {}
      let action = (): Promise<void> => {
        calls++
        return new Promise<void>((resolve: () => void) => { release = resolve })
      }
      let first: Promise<void> = readiness.ensure(action)
      let second: Promise<void> = readiness.ensure(action)
      expect(first === second).assertEqual(true)
      expect(calls).assertEqual(1)
      expect(readiness.isReady()).assertEqual(false)
      release()
      await first
      expect(readiness.isReady()).assertEqual(true)
      await readiness.ensure(action)
      expect(calls).assertEqual(1)
    })

    it('allowsARealRetryAfterPreparationFails', 0, async () => {
      let readiness: SshEnvironmentReadiness = new SshEnvironmentReadiness()
      let calls: number = 0
      let failed: boolean = false
      try {
        await readiness.ensure((): Promise<void> => {
          calls++
          return Promise.reject(new Error('not ready'))
        })
      } catch (e) {
        failed = true
      }
      expect(failed).assertEqual(true)
      expect(readiness.isReady()).assertEqual(false)
      await readiness.ensure((): Promise<void> => {
        calls++
        return Promise.resolve()
      })
      expect(calls).assertEqual(2)
      expect(readiness.isReady()).assertEqual(true)
    })
  })
}
