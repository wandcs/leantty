import { common } from '@kit.AbilityKit'
import { FileUtils } from '../../common/utils/FileUtils'
import { KeyPairInfo } from '../../common/types/SshKeyTypes'
import { DurableStateManager } from '../persistence/DurableStateManager'
import { SshEnvironmentReadiness } from './SshEnvironmentReadiness'
import { SshKeyManager } from './SshKeyManager'

export class SshEnvironment {
  private static readiness: SshEnvironmentReadiness = new SshEnvironmentReadiness()

  static prepare(context: common.Context): Promise<void> {
    return SshEnvironment.readiness.ensure(async (): Promise<void> => {
      await DurableStateManager.prepareSshProjection(context)
      let keys: KeyPairInfo[] = SshKeyManager.listKeys(context)
      let keyNames: string[] = []
      for (let i = 0; i < keys.length; i++) {
        keyNames.push(FileUtils.fileNameFromPath(keys[i].filePath))
      }
      if (DurableStateManager.isLegacyMigrationPending()) {
        DurableStateManager.finishLegacyMigration(context, keyNames)
      } else {
        await DurableStateManager.reconcileVerifiedKeys(context, keyNames)
      }
      for (let i = 0; i < keyNames.length; i++) {
        SshKeyManager.protectKeyFile(context, keyNames[i])
      }
    })
  }

  static isReady(): boolean {
    return SshEnvironment.readiness.isReady()
  }
}
