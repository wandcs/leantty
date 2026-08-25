import { common, Want, wantConstant } from '@kit.AbilityKit'
import url from '@ohos.url'
import { UserGuideManager } from '../guide/UserGuideManager'
import { UserGuidePolicy } from '../guide/UserGuidePolicy'
import { UiText } from '../ui/UiText'

export class BrowserLauncher {
  static readonly MAX_URL_LENGTH: number = 4096

  static normalizeHttpUrl(raw: string): string | null {
    if (raw.length === 0 || raw.length > BrowserLauncher.MAX_URL_LENGTH || raw.trim() !== raw) {
      return null
    }
    for (let i = 0; i < raw.length; i++) {
      let code: number = raw.charCodeAt(i)
      if (code <= 32 || code === 127) {
        return null
      }
    }
    let schemeEnd: number = raw.indexOf('://')
    if (schemeEnd < 0) {
      return null
    }
    let scheme: string = raw.substring(0, schemeEnd).toLowerCase()
    if (scheme !== 'http' && scheme !== 'https') {
      return null
    }
    let authorityStart: number = schemeEnd + 3
    let authorityEnd: number = raw.length
    for (let i = authorityStart; i < raw.length; i++) {
      let character: string = raw.substring(i, i + 1)
      if (character === '/' || character === '?' || character === '#') {
        authorityEnd = i
        break
      }
    }
    let authority: string = raw.substring(authorityStart, authorityEnd)
    if (authority.length === 0 || authority.indexOf('@') >= 0 || authority.indexOf('\\') >= 0 ||
      authority.indexOf('"') >= 0 || authority.indexOf('\'') >= 0 ||
      authority.indexOf('<') >= 0 || authority.indexOf('>') >= 0) {
      return null
    }
    let host: string = authority
    let port: string = ''
    if (authority.substring(0, 1) === '[') {
      let bracketEnd: number = authority.indexOf(']')
      if (bracketEnd <= 1) {
        return null
      }
      host = authority.substring(0, bracketEnd + 1)
      let suffix: string = authority.substring(bracketEnd + 1)
      if (suffix.length > 0) {
        if (suffix.substring(0, 1) !== ':') {
          return null
        }
        port = suffix.substring(1)
      }
    } else {
      if (authority.indexOf('[') >= 0 || authority.indexOf(']') >= 0) {
        return null
      }
      let firstColon: number = authority.indexOf(':')
      let lastColon: number = authority.lastIndexOf(':')
      if (firstColon >= 0) {
        if (firstColon !== lastColon) {
          return null
        }
        host = authority.substring(0, firstColon)
        port = authority.substring(firstColon + 1)
      }
    }
    if (host.length === 0) {
      return null
    }
    if (port.length > 0) {
      for (let i = 0; i < port.length; i++) {
        let code: number = port.charCodeAt(i)
        if (code < 48 || code > 57) {
          return null
        }
      }
      let portNumber: number = parseInt(port, 10)
      if (portNumber < 1 || portNumber > 65535) {
        return null
      }
    } else if (authority.substring(authority.length - 1) === ':') {
      return null
    }
    return scheme + raw.substring(schemeEnd)
  }

  static async open(context: common.UIAbilityContext, raw: string): Promise<boolean> {
    let safeUrl: string | null = BrowserLauncher.normalizeHttpUrl(raw)
    if (safeUrl === null) {
      return false
    }
    try {
      let parsed: url.URL = url.URL.parseURL(safeUrl)
      let protocol: string = parsed.protocol.toLowerCase()
      if ((protocol !== 'http:' && protocol !== 'https:' && protocol !== 'http' && protocol !== 'https') ||
        parsed.hostname.length === 0 || parsed.username.length > 0 || parsed.password.length > 0) {
        return false
      }
      await context.openLink(parsed.toString(), { appLinkingOnly: false })
      return true
    } catch (e) {
      return false
    }
  }

  static isAllowedUserGuideUrl(raw: string, expected: string): boolean {
    return UserGuidePolicy.isAllowedGuideUri(raw, expected)
  }

  static async openUserGuide(context: common.UIAbilityContext, raw: string): Promise<boolean> {
    let expected: string = ''
    try {
      expected = UserGuideManager.expectedUri(context)
    } catch (e) {
      return false
    }
    if (!BrowserLauncher.isAllowedUserGuideUrl(raw, expected)) {
      return false
    }
    try {
      let want: Want = {
        action: 'ohos.want.action.viewData',
        uri: UserGuidePolicy.localizedOpenUri(expected, UiText.isChineseSystemLanguage()),
        type: 'text/html',
        flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION
      }
      await context.startAbility(want)
      return true
    } catch (e) {
      return false
    }
  }
}
