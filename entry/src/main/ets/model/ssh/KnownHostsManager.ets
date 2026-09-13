import { common } from '@kit.AbilityKit'
import sshNative from 'libleantty_ssh.so'
import { DurableStateManager } from '../persistence/DurableStateManager'

export class KnownHostRemovalResult {
  target: string = ''
  removed: number = 0
}

export class KnownHostQueryResult {
  target: string = ''
  output: string = ''
  found: number = 0
}

export class KnownHostsManager {
  static formatTarget(host: string, port: number): string {
    return port === 22 ? host : '[' + host + ']:' + port.toString()
  }

  static async remove(context: common.Context, host: string, port: number): Promise<KnownHostRemovalResult> {
    let result: KnownHostRemovalResult = new KnownHostRemovalResult()
    result.target = KnownHostsManager.formatTarget(host, port)
    await DurableStateManager.updateKnownHosts(context, (current: string): string => {
      let nativeResult = sshNative.sshRemoveKnownHostEntries(current, host, port)
      result.removed = nativeResult.removed
      return result.removed > 0 ? nativeResult.content : current
    })
    return result
  }

  static async find(host: string, port: number): Promise<KnownHostQueryResult> {
    let nativeResult = sshNative.sshFindKnownHostEntries(
      await DurableStateManager.readKnownHosts(), host, port)
    let result: KnownHostQueryResult = new KnownHostQueryResult()
    result.target = KnownHostsManager.formatTarget(host, port)
    result.output = nativeResult.output
    result.found = nativeResult.found
    return result
  }
}
