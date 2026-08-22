import { common } from '@kit.AbilityKit'
import { Environment } from '@kit.CoreFileKit'
import {
  KeyAlgorithm, KeyPairInfo, KeyGenerationResult, algorithmFromSshName, algorithmToSshName, algorithmToString
} from '../../common/types/SshKeyTypes'
import { FileUtils } from '../../common/utils/FileUtils'
import { Logger } from '../../common/logger/Logger'
import { DurableStateManager } from '../persistence/DurableStateManager'
import { KeyCommentCommitPolicy } from '../persistence/KeyCommentCommitPolicy'
import { DownloadsAccessManager } from '../transfer/DownloadsAccessManager'
import sshNative from 'libleantty_ssh.so'

const logger: Logger = new Logger('SshKeyManager')
const DEFAULT_ALGOS: string[] = ['id_ed25519', 'id_ed25519_sk', 'id_rsa']
const VALID_KEY_NAME: RegExp = /^[A-Za-z0-9._-]+$/
const RESERVED_SSH_FILES: string[] = ['config', 'known_hosts', 'authorized_keys', 'rc', 'environment', 'moduli']

class PrivateKeyInspection {
  encrypted: boolean = false
  algorithm: KeyAlgorithm = KeyAlgorithm.ED25519
  fingerprint: string = ''
  publicKeyText: string = ''
}

export class SshKeyManager {
  static validateKeyName(name: string): string | null {
    if (name.length === 0 || name === '.' || name === '..') {
      return 'Key name must not be empty, "." or ".."'
    }
    if (name.includes('/') || name.includes('\\')) {
      return 'Key name must not contain path separators'
    }
    if (!VALID_KEY_NAME.test(name)) {
      return 'Key name can only contain letters, digits, ".", "_", "-"'
    }
    let lower: string = name.toLowerCase()
    if (lower.endsWith('.pub') || lower.endsWith('.pub.txt')) {
      return 'Key name must not end with .pub'
    }
    for (let i = 0; i < RESERVED_SSH_FILES.length; i++) {
      let reserved: string = RESERVED_SSH_FILES[i]
      if (lower === reserved || lower.startsWith(reserved + '.')) {
        return 'Key name conflicts with SSH control file: ' + reserved
      }
    }
    return null
  }

  static resolveSafeKeyPath(context: common.Context, name: string): string {
    let err: string | null = SshKeyManager.validateKeyName(name)
    if (err !== null) {
      throw new Error(err)
    }
    let sshDir: string = FileUtils.getSshDir(context)
    let resolved: string = sshDir + '/' + name
    if (!resolved.startsWith(sshDir + '/')) {
      throw new Error('Key path escapes .ssh directory')
    }
    return resolved
  }
  static async generateKeyPair(
    context: common.Context, algo: KeyAlgorithm, passphrase: string, requestedName: string = '', comment: string = ''
  ): Promise<KeyGenerationResult> {
    if (algo !== KeyAlgorithm.ED25519 && algo !== KeyAlgorithm.RSA4096) {
      throw new Error('ECDSA key generation is not supported; import an existing OpenSSH identity instead')
    }
    let sshDir: string = FileUtils.getSshDir(context)
    FileUtils.ensureDir(sshDir)
    let algoStr: string = algorithmToString(algo)
    let keyName: string = requestedName.length > 0 ? SshKeyManager.normalizeKeyReference(context, requestedName) :
      (algo === KeyAlgorithm.ED25519 ? 'id_ed25519' : 'id_rsa')
    let nameError: string | null = SshKeyManager.validateKeyName(keyName)
    if (nameError !== null) {
      throw new Error(nameError)
    }
    let targetPath: string = SshKeyManager.resolveSafeKeyPath(context, keyName)
    if (FileUtils.fileExists(targetPath) || FileUtils.fileExists(targetPath + '.pub')) {
      throw new Error('Key already exists: ' + keyName)
    }
    let json: string = await sshNative.sshGenerateKeyPair(algoStr, passphrase, sshDir, keyName, comment)
    let parsed: Record<string, string> = SshKeyManager.validateKeyGenResult(json)
    let result: KeyGenerationResult = new KeyGenerationResult()
    result.privateKey.algorithm = algo
    result.privateKey.filePath = parsed['privatePath']
    result.privateKey.pubPath = parsed['publicPath']
    result.privateKey.fingerprint = parsed['fingerprint']
    result.privateKey.hasPassphrase = passphrase.length > 0
    result.privateKey.publicKeyText = FileUtils.readTextFile(result.privateKey.pubPath)
    try {
      DurableStateManager.captureKeyPair(context, keyName)
    } catch (e) {
      FileUtils.removeFile(targetPath)
      FileUtils.removeFile(targetPath + '.pub')
      throw new Error('Failed to retain generated key pair: ' + e)
    }
    return result
  }

  static listKeys(context: common.Context): KeyPairInfo[] {
    let sshDir: string = FileUtils.getSshDir(context)
    let keys: KeyPairInfo[] = []
    try {
      let entries: string[] = FileUtils.listFiles(sshDir)
      for (let i = 0; i < entries.length; i++) {
        let name: string = entries[i]
        if (name.endsWith('.pub')) {
          continue
        }
        let key: KeyPairInfo | null = SshKeyManager.readKeyInfo(context, name)
        if (key !== null) {
          keys.push(key)
        }
      }
    } catch (e) {
      logger.warn('listKeys failed: ' + e)
    }
    return keys
  }

  static async importKey(
    context: common.Context, sourcePath: string, newName: string
  ): Promise<KeyPairInfo> {
    let nameError: string | null = SshKeyManager.validateKeyName(newName)
    if (nameError !== null) {
      throw new Error(nameError)
    }
    let sshDir: string = FileUtils.getSshDir(context)
    FileUtils.ensureDir(sshDir)
    let targetPath: string = SshKeyManager.resolveSafeKeyPath(context, newName)
    if (FileUtils.fileExists(targetPath) || FileUtils.fileExists(targetPath + '.pub')) {
      throw new Error('Key already exists: ' + newName)
    }
    FileUtils.copyFile(sourcePath, targetPath)
    let pubTarget: string = targetPath + '.pub'
    try {
      sshNative.sshProtectPrivateKey(targetPath)
      let inspected: PrivateKeyInspection = SshKeyManager.inspectPrivateKey(targetPath)
      FileUtils.writeTextFile(pubTarget, inspected.publicKeyText + '\n')
      let key: KeyPairInfo | null = SshKeyManager.readKeyInfo(context, newName)
      if (key === null) {
        throw new Error('Imported private key could not be verified')
      }
      DurableStateManager.captureKeyPair(context, newName)
      return key
    } catch (e) {
      FileUtils.removeFile(targetPath)
      FileUtils.removeFile(pubTarget)
      throw new Error('Invalid private key: ' + e)
    }
  }

  static deleteKey(context: common.Context, name: string): void {
    let key: KeyPairInfo | null = SshKeyManager.findKeyByName(context, name)
    if (key === null) {
      throw new Error('Key not found or invalid: ' + name)
    }
    let keyName: string = FileUtils.fileNameFromPath(key.filePath)
    try {
      DurableStateManager.deleteKeyPair(context, keyName)
    } catch (e) {
      try {
        SshKeyManager.protectKeyFile(context, keyName)
      } catch (protectError) {
        throw new Error('Key deletion failed and private-key protection recovery failed: ' + protectError)
      }
      throw new Error('Key deletion failed: ' + e)
    }
  }

  static async exportKeyPair(context: common.Context, keyName: string, exportFileName: string): Promise<void> {
    let key: KeyPairInfo | null = SshKeyManager.findKeyByName(context, keyName)
    if (key === null) {
      throw new Error('Key not found or invalid: ' + keyName)
    }
    let fileNameError: string | null = SshKeyManager.validateExportFileName(exportFileName)
    if (fileNameError !== null) {
      throw new Error(fileNameError)
    }
    try {
      await DownloadsAccessManager.ensure(context)
    } catch (e) {
      let detail: string = '' + e
      if (detail.includes('Downloads access was denied')) {
        throw new Error('Downloads access was not granted; no files were exported')
      }
      throw new Error('Cannot request Downloads access: ' + detail)
    }
    let downloadDir: string = ''
    try {
      downloadDir = Environment.getUserDownloadDir()
    } catch (e) {
      throw new Error('Downloads directory is unavailable: ' + e)
    }
    try {
      sshNative.sshExportKeyPair(key.filePath, key.pubPath, downloadDir, exportFileName)
    } catch (e) {
      let detail: string = '' + e
      if (detail.includes('destination already exists')) {
        throw new Error('Downloads already contains "' + exportFileName + '" or "' + exportFileName +
          '.pub". Try: key export ' + keyName + ' ' + exportFileName + '-copy')
      }
      throw new Error('Cannot write key pair to Downloads: ' + detail)
    }
  }

  static changeKeyPassphrase(
    context: common.Context, keyName: string, oldPassphrase: string, newPassphrase: string
  ): void {
    let key: KeyPairInfo | null = SshKeyManager.findKeyByName(context, keyName)
    if (key === null) {
      throw new Error('Key not found or invalid: ' + keyName)
    }
    sshNative.sshChangePrivateKeyPassphrase(key.filePath, oldPassphrase, newPassphrase)
    try {
      DurableStateManager.captureKeyPair(context, keyName)
    } catch (e) {
      try {
        sshNative.sshChangePrivateKeyPassphrase(key.filePath, newPassphrase, oldPassphrase)
      } catch (rollbackError) {
        throw new Error('Passphrase changed but durable retention and rollback failed: ' + rollbackError)
      }
      throw new Error('Failed to retain changed private key; the original passphrase remains active: ' + e)
    }
  }

  static readKeyComment(context: common.Context, keyName: string, passphrase: string): string {
    let key: KeyPairInfo | null = SshKeyManager.findKeyByName(context, keyName)
    if (key === null) {
      throw new Error('Key not found or invalid: ' + keyName)
    }
    return sshNative.sshReadKeyComment(key.filePath, passphrase)
  }

  static changeKeyComment(
    context: common.Context, keyName: string, passphrase: string, newComment: string
  ): string {
    let key: KeyPairInfo | null = SshKeyManager.findKeyByName(context, keyName)
    if (key === null) {
      throw new Error('Key not found or invalid: ' + keyName)
    }
    let keyPath: string = key.filePath
    return KeyCommentCommitPolicy.commit(
      (): string => { return sshNative.sshChangeKeyComment(keyPath, passphrase, newComment) },
      (): void => { DurableStateManager.captureKeyPair(context, keyName) },
      (oldComment: string): void => {
        sshNative.sshChangeKeyComment(keyPath, passphrase, oldComment)
      }
    )
  }

  private static validateExportFileName(name: string): string | null {
    if (name.length === 0 || name === '.' || name === '..') {
      return 'Export file name must not be empty, "." or ".."'
    }
    if (!VALID_KEY_NAME.test(name)) {
      return 'Export file name can only contain letters, digits, ".", "_", "-"'
    }
    if (name.toLowerCase().endsWith('.pub')) {
      return 'Export file name must not end with .pub'
    }
    return null
  }

  static protectKeyFile(context: common.Context, name: string): void {
    let privatePath: string = SshKeyManager.resolveSafeKeyPath(context, name)
    if (FileUtils.fileExists(privatePath)) {
      sshNative.sshProtectPrivateKey(privatePath)
    }
  }

  static readPublicKeyText(context: common.Context, name: string): string {
    let sshDir: string = FileUtils.getSshDir(context)
    let pubPath: string = sshDir + '/' + name + '.pub'
    return FileUtils.readTextFile(pubPath)
  }

  static findKeyByName(context: common.Context, name: string): KeyPairInfo | null {
    let normalizedName: string = SshKeyManager.normalizeKeyReference(context, name)
    let err: string | null = SshKeyManager.validateKeyName(normalizedName)
    if (err !== null) {
      return null
    }
    let keys: KeyPairInfo[] = SshKeyManager.listKeys(context)
    for (let i = 0; i < keys.length; i++) {
      let fileName: string = SshKeyManager.fileNameFromPath(keys[i].filePath)
      if (fileName === normalizedName) {
        return keys[i]
      }
    }
    return null
  }

  static findDefaultKey(context: common.Context): KeyPairInfo | null {
    let keys: KeyPairInfo[] = SshKeyManager.listKeys(context)
    for (let algoIndex = 0; algoIndex < DEFAULT_ALGOS.length; algoIndex++) {
      let algoName: string = DEFAULT_ALGOS[algoIndex]
      for (let keyIndex = 0; keyIndex < keys.length; keyIndex++) {
        let fileName: string = SshKeyManager.fileNameFromPath(keys[keyIndex].filePath)
        if (fileName === algoName) {
          return keys[keyIndex]
        }
      }
    }
    return null
  }

  private static readKeyInfo(context: common.Context, name: string): KeyPairInfo | null {
    let sshDir: string = FileUtils.getSshDir(context)
    let privPath: string = sshDir + '/' + name
    let pubPath: string = privPath + '.pub'
    if (!FileUtils.fileExists(privPath) || !FileUtils.fileExists(pubPath)) {
      return null
    }
    let key: KeyPairInfo = new KeyPairInfo()
    key.filePath = privPath
    key.pubPath = pubPath
    let inspected: PrivateKeyInspection
    try {
      inspected = SshKeyManager.inspectPrivateKey(privPath)
    } catch (e) {
      return null
    }
    key.algorithm = inspected.algorithm
    key.hasPassphrase = inspected.encrypted
    let pubText: string = ''
    try {
      pubText = FileUtils.readTextFile(pubPath).trim()
    } catch (e) {
      return null
    }
    let publicAlgorithmName: string = pubText.split(/\s+/)[0]
    if (publicAlgorithmName !== algorithmToSshName(inspected.algorithm)) {
      return null
    }
    key.algorithm = inspected.algorithm
    key.fingerprint = SshKeyManager.readFingerprint(pubPath)
    if (key.fingerprint.length === 0 || key.fingerprint !== inspected.fingerprint) {
      return null
    }
    key.publicKeyText = pubText
    return key
  }

  private static inspectPrivateKey(privatePath: string): PrivateKeyInspection {
    let raw: string = sshNative.sshInspectPrivateKey(privatePath)
    let lines: string[] = raw.split('\n')
    if (lines.length < 4) {
      throw new Error('Invalid private key inspection result')
    }
    let algorithm: KeyAlgorithm | null = algorithmFromSshName(lines[1])
    if (algorithm === null) {
      throw new Error('Unsupported private key algorithm')
    }
    let inspected: PrivateKeyInspection = new PrivateKeyInspection()
    inspected.encrypted = lines[0] === 'true'
    inspected.algorithm = algorithm
    inspected.fingerprint = lines[2]
    inspected.publicKeyText = lines.slice(3).join('\n').trim()
    if (inspected.fingerprint.length === 0 || inspected.publicKeyText.length === 0) {
      throw new Error('Private key inspection returned incomplete metadata')
    }
    return inspected
  }

  private static readFingerprint(pubPath: string): string {
    try {
      return sshNative.sshReadPublicKey(pubPath)
    } catch (e) {
      return ''
    }
  }

  private static fileNameFromPath(filePath: string): string {
    let lastSlash: number = filePath.lastIndexOf('/')
    if (lastSlash >= 0) {
      return filePath.substring(lastSlash + 1)
    }
    return filePath
  }

  private static normalizeKeyReference(context: common.Context, reference: string): string {
    let normalized: string = reference.trim().replace(/\\/g, '/')
    if (normalized.endsWith('.pub')) { normalized = normalized.substring(0, normalized.length - 4) }
    if (normalized.startsWith('~/.ssh/')) { normalized = normalized.substring(7) }
    let sshPrefix: string = FileUtils.getSshDir(context) + '/'
    if (normalized.startsWith(sshPrefix)) { normalized = normalized.substring(sshPrefix.length) }
    if (normalized.includes('/')) { return '' }
    return normalized
  }

  private static validateKeyGenResult(json: string): Record<string, string> {
    let parsed: Record<string, string> = JSON.parse(json)
    let required: string[] = ['privatePath', 'publicPath', 'fingerprint']
    for (let i = 0; i < required.length; i++) {
      let field: string = required[i]
      if (typeof parsed[field] !== 'string' || parsed[field].length === 0) {
        throw new Error('Invalid key generation result: missing ' + field)
      }
    }
    let sshDir: string = ''  // validated by caller
    let privPath: string = parsed['privatePath']
    if (privPath.includes('..') || privPath.includes('\\\\')) {
      throw new Error('Invalid key generation result: path traversal detected')
    }
    return parsed
  }
}
