import { abilityAccessCtrl, common, PermissionRequestResult, Permissions } from '@kit.AbilityKit'
import { Logger } from '../../common/logger/Logger'

const DOWNLOAD_PERMISSION: Permissions = 'ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY'

export class DownloadsAccessManager {
  private static activeRequest: Promise<void> | null = null
  private static logger: Logger = new Logger('DownloadsAccessManager')

  static ensure(context: common.Context): Promise<void> {
    if (DownloadsAccessManager.activeRequest !== null) {
      return DownloadsAccessManager.activeRequest
    }
    let request: Promise<void> = DownloadsAccessManager.performRequest(context)
    DownloadsAccessManager.activeRequest = request
    request.then(() => {
      DownloadsAccessManager.clear(request)
    }).catch(() => {
      DownloadsAccessManager.clear(request)
    })
    return request
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
