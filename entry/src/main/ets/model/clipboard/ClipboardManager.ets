import { pasteboard } from '@kit.BasicServicesKit'
import { Logger } from '../../common/logger/Logger'

const logger: Logger = new Logger('ClipboardManager')

export class ClipboardManager {
  static async readText(): Promise<string> {
    try {
      let data = await pasteboard.getSystemPasteboard().getData()
      return data.getPrimaryText()
    } catch (_) {
      logger.warn('Clipboard read failed')
      return ''
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
