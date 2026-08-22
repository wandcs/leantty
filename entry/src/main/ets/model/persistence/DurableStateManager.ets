import { common } from '@kit.AbilityKit'
import { FileUtils } from '../../common/utils/FileUtils'
import { DurableAssetStore } from './DurableAssetStore'
import { SshConfigCommitPolicy } from './SshConfigCommitPolicy'
import { KeyPairDeletionPolicy } from './KeyPairDeletionPolicy'

const INITIALIZED_PATH: string = '_meta/initialized'
const FONT_SIZE_PATH: string = 'settings/terminal-font-size'
const SSH_CONFIG_PATH: string = 'ssh/config'
const SSH_KNOWN_HOSTS_PATH: string = 'ssh/known-hosts'
const SSH_KEYPAIR_PREFIX: string = 'ssh/keypair/'

export class DurableStateManager {
  private static store: DurableAssetStore | null = null
  private static context: common.UIAbilityContext | null = null
  private static legacyMigrationPending: boolean = false
  private static garbageCollectionCompleted: boolean = false

  static initialize(context: common.UIAbilityContext): void {
    DurableStateManager.context = context
    DurableStateManager.store = new DurableAssetStore()
    DurableStateManager.legacyMigrationPending = DurableStateManager.requireStore().read(INITIALIZED_PATH) === null
  }

  static async prepareSshProjection(context: common.Context): Promise<void> {
    await DurableStateManager.restoreSshProjection(context)
  }

  static collectGarbageOnce(): void {
    if (DurableStateManager.garbageCollectionCompleted) {
      return
    }
    DurableStateManager.requireStore().garbageCollect()
    DurableStateManager.garbageCollectionCompleted = true
  }

  static isLegacyMigrationPending(): boolean {
    return DurableStateManager.legacyMigrationPending
  }

  static finishLegacyMigration(context: common.Context, verifiedKeyNames: string[]): void {
    if (!DurableStateManager.legacyMigrationPending) {
      return
    }
    DurableStateManager.captureLegacySshFile(context, 'config', SSH_CONFIG_PATH)
    DurableStateManager.captureLegacySshFile(context, 'known_hosts', SSH_KNOWN_HOSTS_PATH)
    for (let i = 0; i < verifiedKeyNames.length; i++) {
      DurableStateManager.captureKeyPair(context, verifiedKeyNames[i])
    }
    DurableStateManager.requireStore().write(INITIALIZED_PATH, '1')
    DurableStateManager.legacyMigrationPending = false
  }

  static async reconcileVerifiedKeys(context: common.Context, verifiedKeyNames: string[]): Promise<void> {
    if (DurableStateManager.legacyMigrationPending) {
      return
    }
    for (let i = 0; i < verifiedKeyNames.length; i++) {
      let name: string = verifiedKeyNames[i]
      if (await DurableStateManager.requireStore().readAsync(SSH_KEYPAIR_PREFIX + name) === null) {
        FileUtils.removeFileRequired(FileUtils.getSshDir(context) + '/' + name)
        FileUtils.removeFileRequired(FileUtils.getSshDir(context) + '/' + name + '.pub')
      }
    }
  }

  static readFontSize(): number | null {
    let value: string | null = DurableStateManager.requireStore().read(FONT_SIZE_PATH)
    if (value === null) {
      return null
    }
    let parsed: number = parseInt(value, 10)
    return isNaN(parsed) ? null : parsed
  }

  static writeFontSize(value: number): void {
    DurableStateManager.requireStore().write(FONT_SIZE_PATH, value.toString())
  }

  static commitSshConfig(context: common.Context, content: string): void {
    let store: DurableAssetStore = DurableStateManager.requireStore()
    let configPath: string = FileUtils.getSshDir(context) + '/config'
    let previous: string | null = store.read(SSH_CONFIG_PATH)
    SshConfigCommitPolicy.commit(previous, content,
      (projected: string): void => FileUtils.writeTextFile(configPath, projected),
      (durable: string): void => store.write(SSH_CONFIG_PATH, durable),
      (): void => FileUtils.removeFile(configPath))
  }

  static commitKnownHostLine(context: common.Context, line: string): void {
    if (line.length === 0 || line.length > 8192 || line.includes('\n') || line.includes('\r') ||
      line.trim().split(/\s+/).length < 3) {
      throw new Error('Invalid known_hosts entry')
    }
    let current: string | null = DurableStateManager.requireStore().read(SSH_KNOWN_HOSTS_PATH)
    let content: string = current ?? ''
    if (content.length > 0 && !content.endsWith('\n')) {
      content += '\n'
    }
    content += line + '\n'
    DurableStateManager.requireStore().write(SSH_KNOWN_HOSTS_PATH, content)
    FileUtils.writeTextFile(FileUtils.getSshDir(context) + '/known_hosts', content)
  }

  static readKnownHosts(): string {
    return DurableStateManager.requireStore().read(SSH_KNOWN_HOSTS_PATH) ?? ''
  }

  static commitKnownHostsContent(context: common.Context, content: string): void {
    DurableStateManager.requireStore().write(SSH_KNOWN_HOSTS_PATH, content)
    FileUtils.writeTextFile(FileUtils.getSshDir(context) + '/known_hosts', content)
  }

  static captureKeyPair(context: common.Context, name: string): void {
    let privatePath: string = FileUtils.getSshDir(context) + '/' + name
    let publicPath: string = privatePath + '.pub'
    let privateText: string = FileUtils.readTextFile(privatePath)
    let publicText: string = FileUtils.readTextFile(publicPath)
    if (privateText.length === 0 || publicText.length === 0) {
      throw new Error('Cannot retain incomplete SSH key pair: ' + name)
    }
    let payload: string = privateText.length.toString() + '\n' + privateText + publicText
    DurableStateManager.requireStore().write(SSH_KEYPAIR_PREFIX + name, payload)
  }

  static deleteKeyPair(context: common.Context, name: string): void {
    let store: DurableAssetStore = DurableStateManager.requireStore()
    let durablePath: string = SSH_KEYPAIR_PREFIX + name
    let payload: string | null = store.read(durablePath)
    let privatePath: string = FileUtils.getSshDir(context) + '/' + name
    let removeProjection = (): void => {
      FileUtils.removeFileRequired(privatePath)
      FileUtils.removeFileRequired(privatePath + '.pub')
    }
    if (payload === null) {
      removeProjection()
      return
    }
    let retainedPayload: string = payload
    KeyPairDeletionPolicy.commit(
      removeProjection,
      (): void => store.remove(durablePath),
      (): void => DurableStateManager.writeKeyPairPayload(context, name, retainedPayload),
      (): void => store.write(durablePath, retainedPayload))
  }

  private static async restoreSshProjection(context: common.Context): Promise<void> {
    let paths: string[] = await DurableStateManager.requireStore().listPathsAsync()
    if (!DurableStateManager.legacyMigrationPending) {
      if (paths.indexOf(SSH_CONFIG_PATH) < 0) {
        FileUtils.removeFile(FileUtils.getSshDir(context) + '/config')
      }
      if (paths.indexOf(SSH_KNOWN_HOSTS_PATH) < 0) {
        FileUtils.removeFile(FileUtils.getSshDir(context) + '/known_hosts')
      }
    }
    for (let i = 0; i < paths.length; i++) {
      let path: string = paths[i]
      if (path === SSH_CONFIG_PATH) {
        await DurableStateManager.materializeText(context, 'config', path)
      } else if (path === SSH_KNOWN_HOSTS_PATH) {
        await DurableStateManager.materializeText(context, 'known_hosts', path)
      } else if (path.startsWith(SSH_KEYPAIR_PREFIX)) {
        await DurableStateManager.materializeKeyPair(context, path.substring(SSH_KEYPAIR_PREFIX.length), path)
      }
    }
  }

  private static async materializeText(context: common.Context, fileName: string, path: string): Promise<void> {
    let value: string | null = await DurableStateManager.requireStore().readAsync(path)
    if (value === null) {
      return
    }
    FileUtils.writeTextFile(FileUtils.getSshDir(context) + '/' + fileName, value)
  }

  private static async materializeKeyPair(
    context: common.Context,
    name: string,
    path: string
  ): Promise<void> {
    let payload: string | null = await DurableStateManager.requireStore().readAsync(path)
    if (payload === null) {
      return
    }
    DurableStateManager.writeKeyPairPayload(context, name, payload)
  }

  private static writeKeyPairPayload(context: common.Context, name: string, payload: string): void {
    let separator: number = payload.indexOf('\n')
    if (separator < 1) {
      throw new Error('Invalid durable SSH key pair: ' + name)
    }
    let privateLength: number = parseInt(payload.substring(0, separator), 10)
    let contentStart: number = separator + 1
    if (isNaN(privateLength) || privateLength < 1 || contentStart + privateLength > payload.length) {
      throw new Error('Invalid durable SSH key pair length: ' + name)
    }
    let privateText: string = payload.substring(contentStart, contentStart + privateLength)
    let publicText: string = payload.substring(contentStart + privateLength)
    let privatePath: string = FileUtils.getSshDir(context) + '/' + name
    FileUtils.writeTextFile(privatePath, privateText)
    FileUtils.writeTextFile(privatePath + '.pub', publicText)
  }

  private static captureLegacySshFile(context: common.Context, fileName: string, path: string): void {
    let filePath: string = FileUtils.getSshDir(context) + '/' + fileName
    if (!FileUtils.fileExists(filePath)) {
      return
    }
    DurableStateManager.requireStore().write(path, FileUtils.readTextFile(filePath))
  }

  private static requireStore(): DurableAssetStore {
    if (DurableStateManager.store === null || DurableStateManager.context === null) {
      throw new Error('Durable state is not initialized')
    }
    return DurableStateManager.store
  }
}
