import { pasteboard } from '@kit.BasicServicesKit'
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit'
import { Logger } from '../../common/logger/Logger'

const logger: Logger = new Logger('ClipboardManager')
const READ_PERMISSION: Permissions = 'ohos.permission.READ_PASTEBOARD'
export type ClipboardReadPermission = 'granted' | 'denied' | 'failed' | 'busy'

export class ClipboardManager {
  private static requestingReadPermission: boolean = false

  // Only a current local paste intent may call this. Do not cache grant state:
  // system settings own it, and another Pane must not queue behind the dialog.
  static async requestReadPermission(context: common.UIAbilityContext): Promise<ClipboardReadPermission> {
    if (ClipboardManager.requestingReadPermission) { return 'busy' }
    ClipboardManager.requestingReadPermission = true
    try {
      let manager = abilityAccessCtrl.createAtManager()
      if (manager.checkAccessTokenSync(context.applicationInfo.accessTokenId, READ_PERMISSION) ===
        abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) { return 'granted' }
      let result = await manager.requestPermissionsFromUser(context, [READ_PERMISSION])
      return result.authResults.length === 1 &&
        result.authResults[0] === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED ? 'granted' : 'denied'
    } catch (_) {
      logger.warn('Clipboard permission request failed')
      return 'failed'
    } finally {
      ClipboardManager.requestingReadPermission = false
    }
  }

  static async readText(): Promise<string | null> {
    try {
      let data = await pasteboard.getSystemPasteboard().getData()
      return data.getPrimaryText()
    } catch (_) {
      logger.warn('Clipboard read failed')
      return null
    }
  }
  static async writeText(text: string): Promise<boolean> {
    try {
      let pasteData: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text)
      let property: pasteboard.PasteDataProperty = pasteData.getProperty()
      property.shareOption = pasteboard.ShareOption.LOCALDEVICE
      pasteData.setProperty(property)
      let sysPasteboard: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard()
      await sysPasteboard.setData(pasteData)
      return true
    } catch (e) {
      logger.error('Clipboard write failed: ' + e)
      return false
    }
  }
}
