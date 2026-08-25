import { common } from '@kit.AbilityKit'
import { i18n } from '@kit.LocalizationKit'

export class TerminalSearchText {
  language: string = 'en'
  findInTerminal: string = ''
  findText: string = ''
  placeholder: string = ''
  results: string = ''
  previousMatch: string = ''
  nextMatch: string = ''
  close: string = ''
  typeToFind: string = ''
  noResults: string = ''
}

export class UiText {
  static get(context: common.Context, name: string, ...args: Array<string | number>): string {
    return context.resourceManager.getStringByNameSync(name, ...args)
  }

  static terminalSearch(context: common.Context): TerminalSearchText {
    let text: TerminalSearchText = new TerminalSearchText()
    text.language = UiText.isChineseSystemLanguage() ? 'zh-CN' : 'en'
    text.findInTerminal = UiText.get(context, 'search_find_in_terminal')
    text.findText = UiText.get(context, 'search_find_text')
    text.placeholder = UiText.get(context, 'search_placeholder')
    text.results = UiText.get(context, 'search_results')
    text.previousMatch = UiText.get(context, 'search_previous_match')
    text.nextMatch = UiText.get(context, 'search_next_match')
    text.close = UiText.get(context, 'search_close')
    text.typeToFind = UiText.get(context, 'search_type_to_find')
    text.noResults = UiText.get(context, 'search_no_results')
    return text
  }

  static isChineseLanguage(language: string): boolean {
    let normalized: string = language.trim().toLowerCase()
    return normalized === 'zh' || normalized.startsWith('zh-') || normalized.startsWith('zh_')
  }

  static isChineseSystemLanguage(): boolean {
    return UiText.isChineseLanguage(i18n.System.getSystemLanguage())
  }
}
