export enum UserGuideFileDecision {
  CREATE = 0,
  CURRENT = 1,
  REPLACE_OWNED = 2,
  CONFLICT = 3
}

export class UserGuidePolicy {
  static readonly FILE_NAME: string = 'LeanTTY-User-Guide.html'
  static readonly TEMP_FILE_NAME: string = '.LeanTTY-User-Guide.html.tmp'
  static readonly RAW_FILE_NAME: string = 'LeanTTY-User-Guide.html'
  static readonly OWNERSHIP_MARKER: string = '<!-- leantty-owned-user-guide -->'
  static readonly MAX_GUIDE_BYTES: number = 100 * 1024
  private static readonly MAX_URI_LENGTH: number = 4096
  private static readonly BUNDLE_NAME: RegExp = /^[A-Za-z0-9][A-Za-z0-9._-]*$/

  static validateBundleName(bundleName: string): boolean {
    return bundleName.length > 0 && bundleName.length <= 255 &&
      UserGuidePolicy.BUNDLE_NAME.test(bundleName) && bundleName !== '.' && bundleName !== '..'
  }

  static guideDirectory(downloadDirectory: string, bundleName: string): string {
    if (!UserGuidePolicy.validateBundleName(bundleName)) {
      throw new Error('Invalid application bundle name')
    }
    let root: string = UserGuidePolicy.trimTrailingSlashes(downloadDirectory)
    if (root.length === 0) {
      throw new Error('Downloads directory is unavailable')
    }
    return root + '/' + bundleName
  }

  static guidePath(downloadDirectory: string, bundleName: string): string {
    return UserGuidePolicy.guideDirectory(downloadDirectory, bundleName) + '/' + UserGuidePolicy.FILE_NAME
  }

  static tempPath(downloadDirectory: string, bundleName: string): string {
    return UserGuidePolicy.guideDirectory(downloadDirectory, bundleName) + '/' + UserGuidePolicy.TEMP_FILE_NAME
  }

  static decide(existing: Uint8Array | null, packaged: Uint8Array): UserGuideFileDecision {
    if (existing === null) {
      return UserGuideFileDecision.CREATE
    }
    if (UserGuidePolicy.bytesEqual(existing, packaged)) {
      return UserGuideFileDecision.CURRENT
    }
    if (UserGuidePolicy.hasOwnershipMarker(existing)) {
      return UserGuideFileDecision.REPLACE_OWNED
    }
    return UserGuideFileDecision.CONFLICT
  }

  static hasOwnershipMarker(content: Uint8Array): boolean {
    let marker: Uint8Array = UserGuidePolicy.asciiBytes(UserGuidePolicy.OWNERSHIP_MARKER)
    if (content.length < marker.length) {
      return false
    }
    let limit: number = Math.min(content.length - marker.length, 4096)
    for (let i: number = 0; i <= limit; i++) {
      let matches: boolean = true
      for (let j: number = 0; j < marker.length; j++) {
        if (content[i + j] !== marker[j]) {
          matches = false
          break
        }
      }
      if (matches) {
        return true
      }
    }
    return false
  }

  static bytesEqual(left: Uint8Array, right: Uint8Array): boolean {
    if (left.length !== right.length) {
      return false
    }
    for (let i: number = 0; i < left.length; i++) {
      if (left[i] !== right[i]) {
        return false
      }
    }
    return true
  }

  static isAllowedGuideUri(raw: string, expected: string): boolean {
    if (raw.length === 0 || raw.length > UserGuidePolicy.MAX_URI_LENGTH || raw !== expected ||
      raw.trim() !== raw || !raw.startsWith('file://')) {
      return false
    }
    for (let i: number = 0; i < raw.length; i++) {
      let code: number = raw.charCodeAt(i)
      if (code <= 32 || code === 127) {
        return false
      }
    }
    return raw.indexOf('?') < 0 && raw.indexOf('#') < 0 && raw.indexOf('\\') < 0 &&
      raw.toLowerCase().indexOf('%2e%2e') < 0 && raw.indexOf('/../') < 0
  }

  static localizedOpenUri(expected: string, chinese: boolean): string {
    if (!UserGuidePolicy.isAllowedGuideUri(expected, expected)) {
      throw new Error('Invalid user guide URI')
    }
    return expected + (chinese ? '#guide-zh' : '#guide-en')
  }

  static osc8Link(uri: string): string {
    return '\u001b]8;;' + uri + '\u001b\\' + UserGuidePolicy.FILE_NAME + '\u001b]8;;\u001b\\'
  }

  private static trimTrailingSlashes(path: string): string {
    let end: number = path.length
    while (end > 0 && (path.substring(end - 1, end) === '/' || path.substring(end - 1, end) === '\\')) {
      end--
    }
    return path.substring(0, end)
  }

  private static asciiBytes(text: string): Uint8Array {
    let result: Uint8Array = new Uint8Array(text.length)
    for (let i: number = 0; i < text.length; i++) {
      result[i] = text.charCodeAt(i)
    }
    return result
  }
}
