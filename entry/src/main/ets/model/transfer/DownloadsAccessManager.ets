import { abilityAccessCtrl, common, PermissionRequestResult, Permissions } from '@kit.AbilityKit'
import { Logger } from '../../common/logger/Logger'

const DOWNLOAD_PERMISSION: Permissions = 'ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY'

export class DownloadsAccessManager {
  private static activeRequest: Promise<void> | null = null
  private static logger: Logger = new Logger('DownloadsAccessManager')

  static ensure(context: common.Context, cancellation: Promise<void> | null = null): Promise<void> {
    let request: Promise<void>
    if (DownloadsAccessManager.activeRequest !== null) {
      request = DownloadsAccessManager.activeRequest
    } else {
      request = DownloadsAccessManager.performRequest(context)
      DownloadsAccessManager.activeRequest = request
      request.then(() => {
        DownloadsAccessManager.clear(request)
      }).catch(() => {
        DownloadsAccessManager.clear(request)
      })
    }
    return DownloadsAccessManager.waitForRequest(request, cancellation)
  }

  static async waitForRequest(request: Promise<void>, cancellation: Promise<void> | null): Promise<void> {
    if (cancellation === null) {
      await request
      return
    }
    let outcome: string = await Promise.race<string>([
      request.then((): string => 'ready'),
      cancellation.then((): string => 'cancelled')
    ])
    if (outcome === 'cancelled') {
      throw new Error('TRANSFER_CANCELLED: Downloads preparation was cancelled')
    }
  }

  private static clear(request: Promise<void>): void {
    if (DownloadsAccessManager.activeRequest === request) {
      DownloadsAccessManager.activeRequest = null
    }
  }

  private static async performRequest(context: common.Context): Promise<void> {
    let manager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager()
    let result: PermissionRequestResult = await manager.requestPermissionsFromUser(context, [DOWNLOAD_PERMISSION])
    if (result.authResults.length === 1 &&
      result.authResults[0] === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
      return
    }
    let dialogWasShown: boolean = result.dialogShownResults !== undefined &&
      result.dialogShownResults.length === 1 && result.dialogShownResults[0]
    if (!dialogWasShown) {
      try {
        let settingResults: abilityAccessCtrl.GrantStatus[] =
          await manager.requestPermissionOnSetting(context, [DOWNLOAD_PERMISSION])
        if (settingResults.length === 1 &&
          settingResults[0] === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
          return
        }
      } catch (e) {
        DownloadsAccessManager.logger.warn('Downloads settings request failed: ' + e)
      }
    }
    throw new Error('Downloads access was denied')
  }
}
