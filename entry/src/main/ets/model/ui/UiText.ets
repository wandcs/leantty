import { common } from '@kit.AbilityKit'
import { i18n } from '@kit.LocalizationKit'

export class UiText {
  static get(context: common.Context, name: string, ...args: Array<string | number>): string {
    return context.resourceManager.getStringByNameSync(name, ...args)
  }


  static isChineseLanguage(language: string): boolean {
    let normalized: string = language.trim().toLowerCase()
    return normalized === 'zh' || normalized.startsWith('zh-') || normalized.startsWith('zh_')
  }

  static isChineseSystemLanguage(): boolean {
    return UiText.isChineseLanguage(i18n.System.getSystemLanguage())
  }
}
